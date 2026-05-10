-- @description CP_VideoKit — Inspector window
-- @version 0.2
-- @author Cedric Pamalio
--
-- Shows the parameter panel of the focused CP_VideoKit module on the
-- selected take. Companion to CP_VideoKit_Modules.lua, which manages the
-- module list and intercepts the Video Window.

local info = debug.getinfo(1, "S")
local SCRIPT_PATH = info.source:match("@?(.*[\\/])")

local UI       = dofile(SCRIPT_PATH .. "../CP_Toolkit/CP_Toolkit.lua")
local Core     = dofile(SCRIPT_PATH .. "Modules/Core.lua")
local Registry = dofile(SCRIPT_PATH .. "Modules/Registry.lua")
local Shared   = dofile(SCRIPT_PATH .. "Modules/Shared.lua")

Registry.load_all(SCRIPT_PATH .. "Effects/")

local SCRIPT_ID = Shared.script_id()

local active = Shared.new_state()

local function refresh_modules()
    if not active.take then
        active.modules = {}; active.focus_idx = nil; return
    end
    active.modules = Core.scan_modules(active.take, Registry)
    -- Inspector reads the focus saved by the Modules window each frame.
    local focus_by_take = Shared.load_focus(UI)
    local saved = focus_by_take[active.guid]
    if saved then
        for i, m in ipairs(active.modules) do
            if m.fx_idx == saved then active.focus_idx = i; return end
        end
    end
    active.focus_idx = #active.modules > 0 and 1 or nil
end

local function pull_focus_state()
    if not active.focus_idx then active.state = {}; return end
    local m   = active.modules[active.focus_idx]
    local def = Registry.find_by_id(m.module_id)
    if not def or not def.read_state then active.state = {}; return end
    active.state = def.read_state(Core, active.take, m.fx_idx)
end

local function refresh_take()
    local take = Core.get_selected_take()
    local guid = take and Shared.take_guid(take) or nil

    -- Refresh on take change OR focus change (the Modules window can
    -- update the saved focus while we're on the same take).
    local focus_changed = false
    if take == active.take then
        local fbt = Shared.load_focus(UI)
        local saved = fbt[active.guid]
        if saved and active.modules[active.focus_idx]
                and active.modules[active.focus_idx].fx_idx ~= saved then
            focus_changed = true
        end
    end

    if take ~= active.take or focus_changed then
        active.take, active.guid = take, guid
        refresh_modules()
        pull_focus_state()
    end
end

local function build_ctx()
    if not active.focus_idx then return nil end
    local m   = active.modules[active.focus_idx]
    local def = Registry.find_by_id(m.module_id)
    return {
        take    = active.take, fx_idx  = m.fx_idx,
        state   = active.state, session = active.session,
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
        modifiers = function()
            if Core.get_modifiers then return Core.get_modifiers() end
            return { ctrl = false, shift = false, alt = false }
        end,
        -- Helper modules expose convenience widgets to effect panels.
        Shared = Shared,
        script_path = SCRIPT_PATH,
    }
end

UI.Init("CP_VideoKit — Inspector", 380, 600,
        { scale = 1, persist = SCRIPT_ID .. "_Inspector" })

UI.Run(function(theme)
    refresh_take()

    if not active.take then
        UI.SetFontCaption()
        UI.Text("No item selected.")
        UI.SetFontBody()
        return
    end
    if not active.focus_idx then
        UI.SetFontCaption()
        UI.Text("No module focused. Open the Modules window to add one.")
        UI.SetFontBody()
        return
    end

    local m   = active.modules[active.focus_idx]
    local def = Registry.find_by_id(m.module_id)

    UI.SetFontH1()
    local bypassed = Core.is_bypassed(active.take, m.fx_idx)
    UI.Text((bypassed and "○ " or "● ") ..
            (m.display_name or m.name) ..
            (bypassed and "  (BYPASSED)" or ""))
    UI.SetFontBody()

    -- A/B compare: large toggle to flip the focus module on/off.
    local ab_label = bypassed and "A/B  ▶ Enable to compare" or "A/B  ▶ Bypass to compare"
    if UI.Button("ab_compare", ab_label, { width = -1, height = 28 }) then
        Core.set_bypassed(active.take, m.fx_idx, not bypassed)
    end

    -- Automation mode
    local item  = reaper.GetMediaItemTake_Item(active.take)
    local track = item and reaper.GetMediaItem_Track(item) or nil
    if track then
        local mode = reaper.GetMediaTrackInfo_Value(track, "I_AUTOMODE")
        local labels = { [0]="Trim", [1]="Read", [2]="Touch",
                         [3]="Write", [4]="Latch" }
        UI.SetFontCaption()
        UI.Text("Track automation: " .. (labels[mode] or "?"))
        UI.SetFontBody()
        if UI.Button("am_read",  "Read",  { width = 70 }) then
            reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 1) end
        UI.SameLine()
        if UI.Button("am_touch", "Touch", { width = 70 }) then
            reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 2) end
        UI.SameLine()
        if UI.Button("am_latch", "Latch", { width = 70 }) then
            reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 4) end
        UI.SameLine()
        if UI.Button("am_write", "Write", { width = 70 }) then
            reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 3) end
        UI.SameLine()
        if UI.Button("am_trim",  "Trim",  { width = 70 }) then
            reaper.SetMediaTrackInfo_Value(track, "I_AUTOMODE", 0) end
    end

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

    -- Continuously refresh the state from the FX so sliders reflect any
    -- automation playback and any drag happening in the Modules window.
    if def and def.read_state then
        active.state = def.read_state(Core, active.take, m.fx_idx)
    end

    local ctx = build_ctx()

    -- Preset row (save / load / delete)
    UI.SetFontCaption()
    UI.Text("Presets")
    UI.SetFontBody()
    local preset_list = Shared.preset_list(SCRIPT_PATH, def.id)
    table.insert(preset_list, 1, "(none)")
    local cur = preset_list[active.preset_choice or 1] and (active.preset_choice or 1) or 1
    local pch, pidx = UI.Combo("preset_pick", "Preset", cur, preset_list,
                               { width = -1 })
    if pch then
        active.preset_choice = pidx
        local name = preset_list[pidx]
        if name and name ~= "(none)" then
            local data = Shared.preset_load(SCRIPT_PATH, def.id, name)
            if data and ctx and def.params then
                for key, p_idx in pairs(def.params) do
                    if data[key] ~= nil then
                        ctx.set_param(p_idx, data[key])
                    end
                end
                if def.read_state then
                    active.state = def.read_state(Core, active.take, m.fx_idx)
                end
            end
        end
    end

    if UI.Button("preset_save", "Save…", { width = 80 }) then
        local ok, name = reaper.GetUserInputs("Save preset", 1,
            "Preset name,extrawidth=200", "")
        if ok and name and name ~= "" then
            local snap = def.read_state(Core, active.take, m.fx_idx)
            -- Strip non-automatable UI flags
            snap.show_frame = nil
            Shared.preset_save(SCRIPT_PATH, def.id, name, snap)
        end
    end
    UI.SameLine()
    if UI.Button("preset_del", "Delete", { width = 80 }) then
        local name = preset_list[active.preset_choice or 1]
        if name and name ~= "(none)" then
            Shared.preset_delete(SCRIPT_PATH, def.id, name)
            active.preset_choice = 1
        end
    end

    UI.Separator()

    if def and def.draw_panel and ctx then
        def.draw_panel(def, ctx, UI)
    end
end)
