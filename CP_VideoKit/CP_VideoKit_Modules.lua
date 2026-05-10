-- @description CP_VideoKit — Modules window
-- @version 0.2
-- @author Cedric Pamalio
--
-- Lists the CP_VideoKit modules installed on the selected take, lets the
-- user add/remove/reorder them, and intercepts mouse events on the Video
-- Window to drive the focused module.
--
-- Companion script: CP_VideoKit_Inspector.lua shows the parameter panel
-- and automation controls of the currently focused module.

local info = debug.getinfo(1, "S")
local SCRIPT_PATH = info.source:match("@?(.*[\\/])")

local UI       = dofile(SCRIPT_PATH .. "../CP_Toolkit/CP_Toolkit.lua")
local Core     = dofile(SCRIPT_PATH .. "Modules/Core.lua")
local Registry = dofile(SCRIPT_PATH .. "Modules/Registry.lua")
local Shared   = dofile(SCRIPT_PATH .. "Modules/Shared.lua")

if not reaper.JS_Window_FindEx then
    reaper.MB("CP_VideoKit requires the JS_ReaScriptAPI extension.", "CP_VideoKit", 0)
    return
end

Registry.load_all(SCRIPT_PATH .. "Effects/")
Core.ensure_video_window_open()

local SCRIPT_ID = Shared.script_id()
local focus_by_take = Shared.load_focus(UI)
local active = Shared.new_state()

-- ============================================================================
-- VIDEO_CODE rewrite cache (one-shot per take per session)
-- ============================================================================
local refreshed_takes = {}

local function refresh_modules()
    if not active.take then
        active.modules = {}
        active.focus_idx = nil
        return
    end
    active.modules = Core.scan_modules(active.take, Registry)

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
    active.guid = take and Shared.take_guid(take) or nil
    refresh_modules()
    pull_focus_state()
    return true
end

refresh_take()

-- ============================================================================
-- Re-validate that focus still points to a live module / FX
-- ============================================================================
local function ensure_focus_valid()
    if not active.take or not active.focus_idx then return false end
    local m = active.modules[active.focus_idx]
    if not m then
        refresh_modules(); return active.focus_idx ~= nil
    end
    local _, name = reaper.TakeFX_GetFXName(active.take, m.fx_idx)
    if not name or not name:lower():find("video processor", 1, true) then
        refresh_modules(); pull_focus_state()
        return active.focus_idx ~= nil
    end
    local code = ({ reaper.TakeFX_GetNamedConfigParm(
        active.take, m.fx_idx, "VIDEO_CODE") })[2] or ""
    if not code:find(m.tag, 1, true) then
        refresh_modules(); pull_focus_state()
        return active.focus_idx ~= nil
    end
    return true
end

-- ============================================================================
-- Build a context for module callbacks
-- ============================================================================
local function build_ctx()
    if not active.focus_idx then return nil end
    local m   = active.modules[active.focus_idx]
    local def = Registry.find_by_id(m.module_id)
    return {
        take    = active.take,
        fx_idx  = m.fx_idx,
        state   = active.state,
        session = active.session,
        set_param = function(p_idx, val)
            Core.set_param(active.take, m.fx_idx, p_idx, val)
        end,
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
        modifiers = function() return Core.get_modifiers() end,
    }
end

local function is_playing()
    return (reaper.GetPlayState() & 1) ~= 0
end

-- ============================================================================
-- Click-to-focus
-- ============================================================================
local function pick_focus_at(nx, ny)
    for i = #active.modules, 1, -1 do
        local m   = active.modules[i]
        local def = Registry.find_by_id(m.module_id)
        if def and def.hit_test then
            local tmp_state = def.read_state(Core, active.take, m.fx_idx)
            local tmp_ctx   = { state = tmp_state }
            if def.hit_test(def, tmp_ctx, nx, ny) then
                return i
            end
        end
    end
    return nil
end

-- ============================================================================
-- Mouse routing
-- ============================================================================
local dragging = false

local function route_events()
    if not ensure_focus_valid() then return end

    local ev   = Core.poll_events()
    local w, h = Core.client_size()

    if ev.down and w > 0 and h > 0 then
        local nx, ny = ev.down.x / w, ev.down.y / h
        local hit = pick_focus_at(nx, ny)
        if hit and hit ~= active.focus_idx then
            active.focus_idx = hit
            focus_by_take[active.guid] = active.modules[hit].fx_idx
            Shared.save_focus(UI, focus_by_take)
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
-- Frame visibility — only the focus module shows its frame
-- ============================================================================
local prev_frame_state = {}

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
                    take = active.take, fx_idx = m.fx_idx, state = {},
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
UI.Init("CP_VideoKit — Modules", 320, 480, { scale = 1, persist = SCRIPT_ID .. "_Modules" })

UI.Run(function(theme)
    refresh_take()
    Core.refresh_intercept()
    route_events()
    sync_frame_visibility()

    UI.SetFontH1()
    if active.take then
        local _, tname = reaper.GetSetMediaItemTakeInfo_String(
            active.take, "P_NAME", "", false)
        UI.Text("Take: " .. (tname or "(unnamed)"))
    else
        UI.Text("Take: (no item selected)")
    end
    UI.SetFontBody()

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
            local prefix = is_focus and "▶ " or "  "
            local bypass_mark = m.bypassed and " (bypassed)" or ""
            local label = prefix .. (m.display_name or m.name) ..
                          "   [fx " .. m.fx_idx .. "]" .. bypass_mark
            if UI.Button("modsel_" .. idx, label, { width = -1 }) then
                active.focus_idx = idx
                pull_focus_state()
                focus_by_take[active.guid] = m.fx_idx
                Shared.save_focus(UI, focus_by_take)
            end

            -- Action row: bypass | solo | rename | reorder | remove
            local bp_lbl = m.bypassed and "ON" or "off"
            if UI.Button("bp_" .. idx, "B:" .. bp_lbl, { width = 50 }) then
                Core.set_bypassed(active.take, m.fx_idx, not m.bypassed)
                refresh_modules()
            end
            UI.SameLine()
            if UI.Button("solo_" .. idx, "Solo", { width = 50 }) then
                -- Solo = bypass everything else, un-bypass this one.
                for _, other in ipairs(active.modules) do
                    Core.set_bypassed(active.take, other.fx_idx,
                                      other.fx_idx ~= m.fx_idx)
                end
                refresh_modules()
            end
            UI.SameLine()
            if UI.Button("rn_" .. idx, "Rename", { width = 70 }) then
                local ok, str = reaper.GetUserInputs(
                    "CP_VideoKit", 1, "New name (empty to clear),extrawidth=200",
                    m.custom_name or "")
                if ok then
                    Core.set_custom_name(active.take, m.fx_idx, str)
                    refresh_modules()
                end
            end
            UI.SameLine()
            if UI.Button("up_" .. idx, "↑", { width = 24 }) and idx > 1 then
                Core.move_module(active.take, m.fx_idx, m.fx_idx - 1)
                refresh_modules(); pull_focus_state()
            end
            UI.SameLine()
            if UI.Button("dn_" .. idx, "↓", { width = 24 }) and idx < #active.modules then
                Core.move_module(active.take, m.fx_idx, m.fx_idx + 1)
                refresh_modules(); pull_focus_state()
            end
            UI.SameLine()
            if UI.Button("rm_" .. idx, "×", { width = 24 }) then
                Core.remove_module(active.take, m.fx_idx)
                if focus_by_take[active.guid] == m.fx_idx then
                    focus_by_take[active.guid] = nil
                    Shared.save_focus(UI, focus_by_take)
                end
                refresh_modules(); pull_focus_state()
            end
        end

        -- "Un-solo" button: if any module is bypassed, restore all
        local any_bypassed = false
        for _, m in ipairs(active.modules) do
            if m.bypassed then any_bypassed = true; break end
        end
        if any_bypassed then
            if UI.Button("unsolo", "Enable all", { width = -1 }) then
                for _, m in ipairs(active.modules) do
                    Core.set_bypassed(active.take, m.fx_idx, false)
                end
                refresh_modules()
            end
        end
    end

    UI.Separator()

    if active.take then
        UI.SetFontH2()
        UI.Text("Add module")
        UI.SetFontBody()
        for _, group in ipairs(Registry.list_grouped()) do
            UI.SetFontCaption()
            UI.Text(group.name)
            UI.SetFontBody()
            for _, def in ipairs(group.modules) do
                if UI.Button("add_" .. def.id, "+ " .. def.name, { width = -1 }) then
                    local idx = Core.install_module(active.take, def,
                                                    SCRIPT_PATH .. "Presets/")
                    if idx then
                        refresh_modules()
                        for i2, m in ipairs(active.modules) do
                            if m.fx_idx == idx then
                                active.focus_idx = i2
                                focus_by_take[active.guid] = idx
                                Shared.save_focus(UI, focus_by_take)
                                pull_focus_state()
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    UI.Separator()

    -- ---------- Render shortcuts ----------
    UI.SetFontH2()
    UI.Text("Render")
    UI.SetFontBody()
    if UI.Button("render_dialog", "Open render dialog…", { width = -1 }) then
        reaper.Main_OnCommand(40015, 0)  -- File: Render project (queue)
    end
    if UI.Button("render_now", "Render last settings", { width = -1 }) then
        reaper.Main_OnCommand(41824, 0)  -- File: Render project, using the most recent settings
    end

    UI.Separator()

    -- ---------- Module clipboard ----------
    if active.take and active.focus_idx then
        UI.SetFontH2()
        UI.Text("Clipboard")
        UI.SetFontBody()
        if UI.Button("clip_copy", "Copy focused module", { width = -1 }) then
            local m   = active.modules[active.focus_idx]
            local def = Registry.find_by_id(m.module_id)
            if def and def.read_state then
                local params = def.read_state(Core, active.take, m.fx_idx)
                params.show_frame = nil
                Shared.clipboard_set(SCRIPT_PATH, {
                    module_id   = m.module_id,
                    params      = params,
                    custom_name = m.custom_name,
                    bypassed    = m.bypassed,
                })
            end
        end
        if Shared.clipboard_get(SCRIPT_PATH) then
            if UI.Button("clip_paste", "Paste here", { width = 130 }) then
                local entry = Shared.clipboard_get(SCRIPT_PATH)
                local def   = Registry.find_by_id(entry.module_id)
                if def then
                    local idx = Core.install_module(active.take, def,
                                                    SCRIPT_PATH .. "Presets/")
                    if idx and entry.params and def.params then
                        for k, p in pairs(def.params) do
                            if entry.params[k] ~= nil then
                                Core.set_param(active.take, idx, p, entry.params[k])
                            end
                        end
                    end
                    if idx and entry.custom_name then
                        Core.set_custom_name(active.take, idx, entry.custom_name)
                    end
                    if idx and entry.bypassed then
                        Core.set_bypassed(active.take, idx, true)
                    end
                    refresh_modules(); pull_focus_state()
                end
            end
            UI.SameLine()
            if UI.Button("clip_paste_all", "Paste to all selected items",
                         { width = 200 }) then
                local entry = Shared.clipboard_get(SCRIPT_PATH)
                local def   = Registry.find_by_id(entry.module_id)
                if def then
                    local n = reaper.CountSelectedMediaItems(0)
                    for i = 0, n - 1 do
                        local item = reaper.GetSelectedMediaItem(0, i)
                        local tk   = reaper.GetActiveTake(item)
                        if tk then
                            local idx = Core.install_module(tk, def,
                                                            SCRIPT_PATH .. "Presets/")
                            if idx and entry.params and def.params then
                                for k, p in pairs(def.params) do
                                    if entry.params[k] ~= nil then
                                        Core.set_param(tk, idx, p, entry.params[k])
                                    end
                                end
                            end
                            if idx and entry.custom_name then
                                Core.set_custom_name(tk, idx, entry.custom_name)
                            end
                            if idx and entry.bypassed then
                                Core.set_bypassed(tk, idx, true)
                            end
                        end
                    end
                    refresh_modules(); pull_focus_state()
                end
            end
        end
    end

    UI.Separator()

    -- ---------- Looks (saved chains) ----------
    if active.take then
        UI.SetFontH2()
        UI.Text("Looks")
        UI.SetFontBody()
        local looks = Shared.look_list(SCRIPT_PATH)
        table.insert(looks, 1, "(none)")
        local lch, lidx = UI.Combo("look_pick", "Look",
            active.look_choice or 1, looks, { width = -1 })
        if lch then
            active.look_choice = lidx
            local name = looks[lidx]
            if name and name ~= "(none)" then
                local data = Shared.look_load(SCRIPT_PATH, name)
                if data then
                    Shared.look_apply(Core, Registry, active.take, data,
                                      SCRIPT_PATH .. "Presets/")
                    refresh_modules()
                    pull_focus_state()
                end
            end
        end

        if UI.Button("look_save", "Save Look…", { width = 110 }) then
            local ok, name = reaper.GetUserInputs("Save Look", 1,
                "Look name,extrawidth=200", "")
            if ok and name and name ~= "" then
                local snap = Shared.look_capture(Core, Registry, active.take)
                Shared.look_save(SCRIPT_PATH, name, snap)
            end
        end
        UI.SameLine()
        if UI.Button("look_del", "Delete", { width = 80 }) then
            local name = looks[active.look_choice or 1]
            if name and name ~= "(none)" then
                Shared.look_delete(SCRIPT_PATH, name)
                active.look_choice = 1
            end
        end
    end
end)

local function cleanup() Core.cleanup() end
UI.OnClose(cleanup)
reaper.atexit(cleanup)
