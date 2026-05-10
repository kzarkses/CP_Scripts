-- @description CP_VideoKit — Modular video FX cockpit for REAPER
-- @version 0.1
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local SCRIPT_PATH = info.source:match("@?(.*[\\/])")

local UI       = dofile(SCRIPT_PATH .. "../CP_Toolkit/CP_Toolkit.lua")
local Core     = dofile(SCRIPT_PATH .. "Modules/Core.lua")
local Registry = dofile(SCRIPT_PATH .. "Modules/Registry.lua")

-- ============================================================================
-- Setup
-- ============================================================================
if not reaper.JS_Window_FindEx then
    reaper.MB("CP_VideoKit requires the JS_ReaScriptAPI extension.", "CP_VideoKit", 0)
    return
end

Registry.load_all(SCRIPT_PATH .. "Effects/")
Core.ensure_video_window_open()

-- Persisted focus state, keyed by take GUID:
--   focus_by_take[take_guid] = fx_idx
-- Stored via SaveConfig (file-based) because LoadPersistent only handles
-- scalars (string/number/boolean), not tables.
local SCRIPT_ID = "CP_VideoKit"

local function load_focus()
    local data = UI.LoadConfig and UI.LoadConfig(SCRIPT_ID) or nil
    if type(data) == "table" and type(data.focus_by_take) == "table" then
        return data.focus_by_take
    end
    return {}
end

local focus_by_take = load_focus()

local function take_guid(take)
    if not take then return nil end
    if reaper.BR_GetMediaItemTakeGUID then
        return reaper.BR_GetMediaItemTakeGUID(take)
    end
    local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
    return guid
end

local function save_focus()
    if UI.SaveConfig then
        UI.SaveConfig(SCRIPT_ID, { focus_by_take = focus_by_take })
    end
end

-- ============================================================================
-- Per-take state, kept alive across frames
-- ============================================================================
local active = {
    take       = nil,           -- MediaItem_Take handle
    guid       = nil,           -- string
    modules    = {},            -- list from Core.scan_modules
    focus_idx  = nil,           -- index into modules[] of focus
    -- Per-fx live state — refreshed when focus changes:
    state      = {},            -- table from module.read_state
    session    = {},            -- scratch for drag anchors
}

-- Track which take GUIDs we've already refreshed VIDEO_CODE for in this
-- session, so each take is only updated once (avoids a write per frame).
local refreshed_takes = {}

local function refresh_modules()
    if not active.take then
        active.modules = {}
        active.focus_idx = nil
        return
    end
    active.modules = Core.scan_modules(active.take, Registry)

    -- On first encounter of a take in this session, rewrite the VIDEO_CODE
    -- of each module so iterations on the .eel files take effect.
    if active.guid and not refreshed_takes[active.guid] then
        refreshed_takes[active.guid] = true
        for _, m in ipairs(active.modules) do
            local def = Registry.find_by_id(m.module_id)
            if def then
                Core.update_module_code(active.take, m.fx_idx, def,
                                        SCRIPT_PATH .. "Presets/")
            end
        end
    end

    -- Resolve focus from persisted store, else first module.
    local saved = focus_by_take[active.guid]
    if saved then
        for i, m in ipairs(active.modules) do
            if m.fx_idx == saved then
                active.focus_idx = i
                return
            end
        end
    end
    active.focus_idx = #active.modules > 0 and 1 or nil
end

local function pull_focus_state()
    if not active.focus_idx then
        active.state = {}
        return
    end
    local m   = active.modules[active.focus_idx]
    local def = Registry.find_by_id(m.module_id)
    if not def or not def.read_state then
        active.state = {}
        return
    end
    active.state = def.read_state(Core, active.take, m.fx_idx)
    active.session = {}
end

local function refresh_take()
    local take = Core.get_selected_take()
    if take == active.take then return false end
    active.take = take
    active.guid = take and take_guid(take) or nil
    refresh_modules()
    pull_focus_state()
    return true
end

-- ============================================================================
-- Build a context object for module callbacks
-- ============================================================================
local function is_playing()
    return (reaper.GetPlayState() & 1) ~= 0
end

local function build_ctx()
    if not active.focus_idx then return nil end
    local m   = active.modules[active.focus_idx]
    local def = Registry.find_by_id(m.module_id)
    return {
        take    = active.take,
        fx_idx  = m.fx_idx,
        state   = active.state,
        session = active.session,
        -- Standard parameter write — used by drag interaction. Goes through
        -- the automation strategy described above.
        set_param = function(p_idx, val)
            Core.set_param(active.take, m.fx_idx, p_idx, val)
        end,
        -- UI-only parameter write — for sliders that should never end up in
        -- an envelope (e.g. show_frame). We force the affected envelope to
        -- stay empty regardless of the track's automation mode.
        write_ui_param = function(p_idx, val)
            Core.set_param(active.take, m.fx_idx, p_idx, val)
            local env = reaper.TakeFX_GetEnvelope(active.take, m.fx_idx, p_idx, false)
            if env then
                reaper.DeleteEnvelopePointRange(env, -1e10, 1e10)
            end
        end,
        refresh_state = function()
            if def and def.read_state then
                local fresh = def.read_state(Core, active.take, m.fx_idx)
                for k, v in pairs(fresh) do active.state[k] = v end
            end
        end,
        -- Live modifier snapshot (Shift/Ctrl/Alt) for handlers that need
        -- modifier-aware behavior (resize aspect lock, wheel step size…).
        modifiers = function() return Core.get_modifiers() end,
    }
end

-- ============================================================================
-- Mouse routing — feed Video Window events to the focus module
-- ============================================================================
local dragging = false

-- On mouse down, find the topmost module whose hit_test claims the click
-- and switch focus to it. PiP modules win over CropZoom (which always
-- returns false from hit_test), so clicking on a PiP inset focuses it
-- automatically without needing to switch in the side panel.
local function pick_focus_at(nx, ny)
    -- Iterate in reverse so modules drawn last (top of stack) get priority.
    for i = #active.modules, 1, -1 do
        local m   = active.modules[i]
        local def = Registry.find_by_id(m.module_id)
        if def and def.hit_test then
            -- Build a temporary ctx for this candidate (its own state).
            local tmp_state = def.read_state(Core, active.take, m.fx_idx)
            local tmp_ctx   = { state = tmp_state }
            if def.hit_test(def, tmp_ctx, nx, ny) then
                return i
            end
        end
    end
    return nil
end

-- Verify that active.focus_idx still points to a valid module on the take
-- and that its fx_idx still exists. Re-scans the FX chain if needed.
-- Returns true when focus is usable, false otherwise.
local function ensure_focus_valid()
    if not active.take or not active.focus_idx then return false end
    local m = active.modules[active.focus_idx]
    if not m then
        refresh_modules()
        return active.focus_idx ~= nil
    end
    -- Confirm the FX at fx_idx still exists and is still our module.
    local _, name = reaper.TakeFX_GetFXName(active.take, m.fx_idx)
    if not name or not name:lower():find("video processor", 1, true) then
        refresh_modules()
        pull_focus_state()
        return active.focus_idx ~= nil
    end
    local code = ({ reaper.TakeFX_GetNamedConfigParm(
        active.take, m.fx_idx, "VIDEO_CODE") })[2] or ""
    if not code:find(m.tag, 1, true) then
        -- The FX at this index changed (user re-ordered manually, etc.).
        -- Re-scan and try to find our tag again.
        refresh_modules()
        pull_focus_state()
        return active.focus_idx ~= nil
    end
    return true
end

local function route_events()
    if not ensure_focus_valid() then return end

    local ev   = Core.poll_events()
    local w, h = Core.client_size()

    -- Switch focus on click if another module owns this point.
    if ev.down and w > 0 and h > 0 then
        local nx, ny = ev.down.x / w, ev.down.y / h
        local hit = pick_focus_at(nx, ny)
        if hit and hit ~= active.focus_idx then
            active.focus_idx = hit
            focus_by_take[active.guid] = active.modules[hit].fx_idx
            save_focus()
            pull_focus_state()
        end
    end

    if not active.focus_idx or not active.modules[active.focus_idx] then return end
    local def = Registry.find_by_id(active.modules[active.focus_idx].module_id)
    if not def then return end
    local ctx = build_ctx()
    if not ctx then return end

    if ev.down then
        dragging = true
        if def.on_mouse_down then
            def.on_mouse_down(def, ctx, ev.down.x, ev.down.y, w, h)
        end
    end

    if ev.move and dragging and def.on_drag then
        def.on_drag(def, ctx, ev.move.x, ev.move.y, w, h)
    end

    if ev.up then
        dragging = false
        reaper.UpdateArrange()
    end

    if ev.wheel and def.on_wheel then
        def.on_wheel(def, ctx, ev.wheel)
    end

end

-- ============================================================================
-- Frame visibility — only the focus module shows its edit frame, and only
-- when not in playback. Called every frame so focus changes are reflected
-- immediately in the Video Window.
-- ============================================================================
local prev_frame_state = {}  -- module fx_idx → bool, dedupe SetParam calls

local function sync_frame_visibility()
    local hide_all = is_playing()
    for idx, m in ipairs(active.modules) do
        local def = Registry.find_by_id(m.module_id)
        if def and def.set_frame_visible then
            local visible = (not hide_all) and (idx == active.focus_idx)
            local key = m.fx_idx
            if prev_frame_state[key] ~= visible then
                prev_frame_state[key] = visible
                local ctx = {
                    take = active.take,
                    fx_idx = m.fx_idx,
                    state = {},
                    set_param = function(p_idx, val)
                        Core.set_param(active.take, m.fx_idx, p_idx, val)
                    end,
                    write_ui_param = function(p_idx, val)
                        Core.set_param(active.take, m.fx_idx, p_idx, val)
                        local env = reaper.TakeFX_GetEnvelope(
                            active.take, m.fx_idx, p_idx, false)
                        if env then
                            reaper.DeleteEnvelopePointRange(env, -1e10, 1e10)
                        end
                    end,
                }
                def.set_frame_visible(def, ctx, visible)
            end
        end
    end
end

-- ============================================================================
-- UI
-- ============================================================================
UI.Init("CP_VideoKit", 480, 600, { scale = 1, persist = SCRIPT_ID })

UI.Run(function(theme)
    refresh_take()
    Core.refresh_intercept()
    route_events()
    sync_frame_visibility()

    -- ---------- Header: take info ----------
    UI.SetFontH1()
    if active.take then
        local _, tname = reaper.GetSetMediaItemTakeInfo_String(
            active.take, "P_NAME", "", false)
        UI.Text("Take: " .. (tname or "(unnamed)"))
    else
        UI.Text("Take: (no item selected)")
    end
    UI.SetFontBody()

    -- ---------- Intercept status ----------
    local i = Core.get_intercept_state()
    UI.SetFontCaption()
    if i.intercepted then
        UI.TextColored("Video Window: intercept ON",
            theme.colors.value_modified[1], theme.colors.value_modified[2],
            theme.colors.value_modified[3], 1)
    else
        UI.TextColored("Video Window: " .. (i.video_hwnd and "armed (off)" or "not found"),
            theme.colors.value_negative[1], theme.colors.value_negative[2],
            theme.colors.value_negative[3], 1)
        if i.status ~= "" then UI.Text("  → " .. i.status) end
    end
    UI.SetFontBody()

    UI.Separator()

    -- ---------- Modules list ----------
    UI.SetFontH2()
    UI.Text("Modules on this take")
    UI.SetFontBody()

    if not active.take then
        UI.SetFontCaption()
        UI.Text("Select a media item to begin.")
        UI.SetFontBody()
    elseif #active.modules == 0 then
        UI.SetFontCaption()
        UI.Text("No CP_VideoKit modules installed.")
        UI.SetFontBody()
    else
        for idx, m in ipairs(active.modules) do
            local is_focus = (idx == active.focus_idx)
            local label = (is_focus and "▶ " or "  ") .. m.name
            local btn_label = label .. "   [fx " .. m.fx_idx .. "]"
            -- Selection button
            if UI.Button("modsel_" .. idx, btn_label, { width = -1 }) then
                active.focus_idx = idx
                pull_focus_state()
                focus_by_take[active.guid] = m.fx_idx
                save_focus()
            end
            -- Reorder + remove row (small buttons)
            if UI.Button("up_" .. idx, "↑", { width = 32 }) and idx > 1 then
                Core.move_module(active.take, m.fx_idx, m.fx_idx - 1)
                refresh_modules()
                pull_focus_state()
            end
            UI.SameLine()
            if UI.Button("dn_" .. idx, "↓", { width = 32 }) and idx < #active.modules then
                Core.move_module(active.take, m.fx_idx, m.fx_idx + 1)
                refresh_modules()
                pull_focus_state()
            end
            UI.SameLine()
            if UI.Button("rm_" .. idx, "× Remove", { width = 100 }) then
                Core.remove_module(active.take, m.fx_idx)
                if focus_by_take[active.guid] == m.fx_idx then
                    focus_by_take[active.guid] = nil
                    save_focus()
                end
                refresh_modules()
                pull_focus_state()
            end
        end
    end

    UI.Separator()

    -- ---------- Add menu ----------
    if active.take then
        UI.SetFontH2()
        UI.Text("Add module")
        UI.SetFontBody()
        for _, def in ipairs(Registry.list()) do
            if UI.Button("add_" .. def.id, "+ " .. def.name, { width = -1 }) then
                local idx = Core.install_module(active.take, def, SCRIPT_PATH .. "Presets/")
                if idx then
                    refresh_modules()
                    -- Focus the newly added module
                    for i2, m in ipairs(active.modules) do
                        if m.fx_idx == idx then
                            active.focus_idx = i2
                            focus_by_take[active.guid] = idx
                            save_focus()
                            pull_focus_state()
                            break
                        end
                    end
                end
            end
        end
    end

    UI.Separator()

    -- ---------- Focus module panel ----------
    if active.focus_idx then
        local m   = active.modules[active.focus_idx]
        local def = Registry.find_by_id(m.module_id)
        UI.SetFontH2()
        UI.Text("● " .. m.name)
        UI.SetFontBody()

        -- Automation mode for the take's track. When set to Touch/Latch/Write,
        -- SetParam during playback records into the parameter envelope.
        local item = reaper.GetMediaItemTake_Item(active.take)
        local track = item and reaper.GetMediaItem_Track(item) or nil
        if track then
            local mode = reaper.GetMediaTrackInfo_Value(track, "I_AUTOMODE")
            local labels = { [0]="Trim", [1]="Read", [2]="Touch",
                             [3]="Write", [4]="Latch" }
            UI.SetFontCaption()
            UI.Text("Track automation: " .. (labels[mode] or "?"))
            UI.SetFontBody()
            if UI.Button("automode_read", "Read", { width = 70 }) then
                reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 1)
            end
            UI.SameLine()
            if UI.Button("automode_touch", "Touch", { width = 70 }) then
                reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 2)
            end
            UI.SameLine()
            if UI.Button("automode_latch", "Latch", { width = 70 }) then
                reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 4)
            end
            UI.SameLine()
            if UI.Button("automode_write", "Write", { width = 70 }) then
                reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 3)
            end
            UI.SameLine()
            if UI.Button("automode_trim", "Trim", { width = 70 }) then
                reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 0)
            end
        end

        -- Envelope reset row
        UI.SetFontCaption()
        UI.Text("Envelopes for this module")
        UI.SetFontBody()
        if UI.Button("env_clear_all", "Clear all", { width = 110 }) then
            reaper.Undo_BeginBlock()
            Core.clear_fx_envelopes(active.take, m.fx_idx)
            reaper.Undo_EndBlock("CP_VideoKit: clear envelopes (" .. m.name .. ")", -1)
            reaper.UpdateArrange()
        end
        UI.SameLine()
        if UI.Button("env_clear_sel", "Clear in time selection", { width = 200 }) then
            local s, e = Core.get_time_selection()
            if s and e then
                reaper.Undo_BeginBlock()
                Core.clear_fx_envelopes(active.take, m.fx_idx, s, e)
                reaper.Undo_EndBlock("CP_VideoKit: clear envelopes in selection", -1)
                reaper.UpdateArrange()
            end
        end

        UI.Separator()

        local ctx = build_ctx()
        if def and def.draw_panel and ctx then
            def.draw_panel(def, ctx, UI)
        end
    end
end)

local function cleanup()
    Core.cleanup()
end
UI.OnClose(cleanup)
reaper.atexit(cleanup)
