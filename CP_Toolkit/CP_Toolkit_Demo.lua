-- @description CP_Toolkit Demo — Showcase of all widgets
-- @version 0.2
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local UI = dofile(script_path .. "CP_Toolkit.lua")

-- scale: 1.0 = normal, 1.25 = 125%, 1.5 = 150%, 2.0 = 200%
UI.Init("CP Toolkit Demo", 520, 700, { scale = 1.5 })

-- ============================================================================
-- STATE
-- ============================================================================
local demo = {
    -- Buttons
    click_count = 0,

    -- Checkboxes
    cb_option_a = true,
    cb_option_b = false,
    cb_option_c = true,

    -- Sliders
    slider_int = 50,
    slider_vol = 0.75,
    slider_pan = 0.0,

    -- Combo
    combo_algo = 1,
    combo_items = { "elastique 3.3.3", "elastique Pro", "Re-Pitch", "SoundTouch", "Rubber Band" },

    combo_mode = 1,
    combo_modes = { "Mono", "Stereo", "Surround 5.1", "Surround 7.1" },

    -- Tabs
    active_tab = 1,
    tabs = { "General", "Audio", "Mixer", "Inputs", "Advanced", "Style" },

    -- Collapsing
    section_buttons = true,
    section_checks = true,
    section_style = false,

    -- Knobs
    knob_vol = 0.75,
    knob_pan = 0.5,
    knob_send = 0.0,
    knob_drive = 0.3,

    -- Tree
    tree_root = true,
    tree_fx = false,
    tree_sends = false,

    -- Meter animation
    meter_time = 0,

    -- Text inputs
    input_name = "My Track",
    input_note = "",
    input_search = "",

    -- Phase 3
    color_accent = { 0.35, 0.60, 0.85 },
    color_bg = { 0.13, 0.13, 0.14 },
    num_bpm = 120,
    num_gain = -3.5,
    note_text = "Session notes:\n- Recorded drums take 3\n- Bass needs re-amp\n- Mix ready for review",

    -- Radio
    radio_output = 1,
    radio_quality = 2,

    -- Progress
    progress = 0,
    progress_dir = 1,

    -- Table
    table_selected = nil,

    -- Modal
    show_modal = false,
    modal_result = "",

    -- Drag & Drop
    drag_items = { "Track 1", "Track 2", "Track 3", "Track 4" },
}

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
UI.Run(function(theme)

    UI.Header("CP Toolkit Demo v0.2")
    UI.Spacing(2)
    UI.Text("[F12] Log overlay  [F11] Console output", { disabled = true })
    UI.Spacing(6)

    -- ==== TABS ====
    local tab_changed, new_tab = UI.TabBar("demo_tabs", demo.tabs, demo.active_tab)
    if tab_changed then demo.active_tab = new_tab end
    UI.Spacing(6)

    -- ================================================================
    -- TAB 1: General
    -- ================================================================
    if demo.active_tab == 1 then

        -- Buttons
        local _, bopen = UI.CollapsingHeader("sec_buttons", "Buttons", demo.section_buttons)
        demo.section_buttons = bopen
        if demo.section_buttons then
            UI.Indent()

            if UI.Button("btn_click", "Click me!") then
                demo.click_count = demo.click_count + 1
            end
            UI.Tooltip("Increments the counter")
            UI.SameLine()
            if UI.Button("btn_reset", "Reset") then
                demo.click_count = 0
            end
            UI.Tooltip("Resets counter to 0")
            UI.SameLine()
            UI.Text("Clicks: " .. demo.click_count)

            UI.Spacing(4)
            UI.Button("btn_wide", "Full Width Button", { width = UI.Layout.GetAvailableWidth() })

            UI.Unindent()
        end

        UI.Spacing(4)

        -- Checkboxes
        local _, copen = UI.CollapsingHeader("sec_checks", "Checkboxes", demo.section_checks)
        demo.section_checks = copen
        if demo.section_checks then
            UI.Indent()

            local ta, na = UI.Checkbox("cb_a", "Option A (enabled)", demo.cb_option_a)
            if ta then demo.cb_option_a = na end

            local tb, nb = UI.Checkbox("cb_b", "Option B (disabled)", demo.cb_option_b)
            if tb then demo.cb_option_b = nb end

            local tc, nc = UI.Checkbox("cb_c", "Auto-crossfade", demo.cb_option_c)
            if tc then demo.cb_option_c = nc end

            UI.Unindent()
        end

        UI.Spacing(4)

        -- Tree Node demo
        local _, topen = UI.TreeNode("tree_track", "Track 1 — Master", demo.tree_root)
        demo.tree_root = topen
        if demo.tree_root then
            local _, fopen = UI.TreeNode("tree_fx", "FX Chain", demo.tree_fx)
            demo.tree_fx = fopen
            if demo.tree_fx then
                UI.Text("ReaEQ")
                UI.Text("ReaComp")
                UI.Text("ReaDelay")
                UI.TreePop()
            end

            local _, sopen = UI.TreeNode("tree_sends", "Sends", demo.tree_sends)
            demo.tree_sends = sopen
            if demo.tree_sends then
                UI.Text("Bus A (Pre-Fader)")
                UI.Text("Bus B (Post-Fader)")
                UI.TreePop()
            end

            UI.TreePop()
        end

    -- ================================================================
    -- TAB 2: Audio
    -- ================================================================
    elseif demo.active_tab == 2 then

        UI.Text("Sliders")
        UI.Separator()
        UI.Spacing(4)

        local ch1, v1 = UI.SliderInt("sl_buffer", "Buffer  ", demo.slider_int, 32, 2048)
        if ch1 then demo.slider_int = v1 end
        UI.Tooltip("Audio buffer size in samples")

        local ch2, v2 = UI.SliderDouble("sl_vol", "Volume  ", demo.slider_vol, 0.0, 1.0)
        if ch2 then demo.slider_vol = v2 end

        local ch3, v3 = UI.SliderDouble("sl_pan", "Pan     ", demo.slider_pan, -1.0, 1.0)
        if ch3 then demo.slider_pan = v3 end

        UI.Spacing(8)
        UI.Text("Dropdowns")
        UI.Separator()
        UI.Spacing(4)

        local cc1, ci1 = UI.Combo("cmb_algo", "Algorithm  ", demo.combo_algo, demo.combo_items)
        if cc1 then demo.combo_algo = ci1 end

        UI.Spacing(4)

        local cc2, ci2 = UI.Combo("cmb_mode", "Mode       ", demo.combo_mode, demo.combo_modes)
        if cc2 then demo.combo_mode = ci2 end

    -- ================================================================
    -- TAB 3: Mixer (Knobs + Meters)
    -- ================================================================
    elseif demo.active_tab == 3 then

        UI.Text("Knobs")
        UI.Separator()
        UI.Spacing(4)

        local kc1, kv1 = UI.Knob("knob_vol", "Vol", demo.knob_vol, 0.75)
        if kc1 then demo.knob_vol = kv1 end
        UI.Tooltip("Volume — double-click to reset")
        UI.SameLine()

        local kc2, kv2 = UI.Knob("knob_pan", "Pan", demo.knob_pan, 0.5)
        if kc2 then demo.knob_pan = kv2 end
        UI.SameLine()

        local kc3, kv3 = UI.Knob("knob_send", "Send", demo.knob_send, 0.0)
        if kc3 then demo.knob_send = kv3 end
        UI.SameLine()

        local kc4, kv4 = UI.Knob("knob_drive", "Drive", demo.knob_drive, 0.3, { size = 50 })
        if kc4 then demo.knob_drive = kv4 end

        UI.Spacing(12)
        UI.Text("VU Meters")
        UI.Separator()
        UI.Spacing(4)

        -- Animate meters with sine waves
        demo.meter_time = demo.meter_time + 0.03
        local t = demo.meter_time
        local peak_l = math.abs(math.sin(t * 1.1)) * 0.7 + math.random() * 0.1
        local peak_r = math.abs(math.sin(t * 0.9 + 0.5)) * 0.7 + math.random() * 0.1

        UI.Text("Vertical:")
        UI.Spacing(2)
        UI.VMeter("vm1", peak_l, peak_r, { width = 14, height = 80 })
        UI.SameLine()
        UI.VMeter("vm2", peak_l * 0.6, peak_r * 0.6, { width = 14, height = 80 })
        UI.SameLine()
        UI.VMeter("vm3", peak_l * 0.3, peak_r * 0.3, { width = 14, height = 80 })

        UI.Spacing(8)
        UI.Text("Horizontal:")
        UI.Spacing(2)
        UI.HMeter("hm1", peak_l, peak_r, { width = 200, height = 10 })

    -- ================================================================
    -- TAB 4: Inputs & Controls
    -- ================================================================
    elseif demo.active_tab == 4 then

        UI.Text("Text Input")
        UI.Separator()
        UI.Spacing(4)

        local ch1, v1 = UI.InputText("inp_name", "Name     ", demo.input_name)
        if ch1 then demo.input_name = v1 end

        local ch2, v2 = UI.InputText("inp_note", "Note     ", demo.input_note, { hint = "Type something..." })
        if ch2 then demo.input_note = v2 end

        UI.Spacing(8)
        UI.Text("Radio Buttons")
        UI.Separator()
        UI.Spacing(4)

        local rc1, ri1 = UI.RadioGroup("radio_out", "Output  ", demo.radio_output,
            { "Stereo", "Mono", "Multi" }, { horizontal = true })
        if rc1 then demo.radio_output = ri1 end

        local rc2, ri2 = UI.RadioGroup("radio_q", "Quality ", demo.radio_quality,
            { "Draft", "Normal", "High", "Ultra" })
        if rc2 then demo.radio_quality = ri2 end

        UI.Spacing(8)
        UI.Text("Progress Bar")
        UI.Separator()
        UI.Spacing(4)

        -- Animate progress
        demo.progress = demo.progress + 0.005 * demo.progress_dir
        if demo.progress >= 1 then demo.progress_dir = -1
        elseif demo.progress <= 0 then demo.progress_dir = 1 end

        UI.ProgressBar("pb1", demo.progress)
        UI.Spacing(2)
        UI.ProgressBar("pb2", 0.7, { label = "Rendering: 70%" })

        UI.Spacing(8)
        UI.Text("Context Menu", { disabled = true })
        UI.Text("Right-click anywhere on this tab for a context menu")

        -- Context menu for this tab area
        UI.ContextMenu("ctx_demo", {
            { label = "Cut",   shortcut = "Ctrl+X", action = function() end },
            { label = "Copy",  shortcut = "Ctrl+C", action = function() end },
            { label = "Paste", shortcut = "Ctrl+V", action = function() end },
            { separator = true },
            { label = "Select All", shortcut = "Ctrl+A", action = function() end },
            { separator = true },
            { label = "Disabled Item", disabled = true },
        })

    -- ================================================================
    -- TAB 5: Advanced
    -- ================================================================
    elseif demo.active_tab == 5 then

        -- Table
        UI.Text("Table / Grid")
        UI.Separator()
        UI.Spacing(4)

        local columns = {
            { header = "Track",  width = 120 },
            { header = "Type",   width = 60 },
            { header = "Volume" },
            { header = "Pan",    width = 50 },
        }
        local rows = {
            { "Master",    "Bus",   "0.0 dB",  "C" },
            { "Drums",     "Audio", "-3.2 dB",  "C" },
            { "Bass",      "Audio", "-6.0 dB",  "L15" },
            { "Keys",      "MIDI",  "-4.5 dB",  "R10" },
            { "Vocals",    "Audio", "-2.1 dB",  "C" },
            { "FX Return", "Bus",   "-8.0 dB",  "C" },
            { "Guitar L",  "Audio", "-5.0 dB",  "L40" },
            { "Guitar R",  "Audio", "-5.0 dB",  "R40" },
        }

        local clicked_row, clicked_col = UI.Table("tbl_tracks", columns, rows,
            { selected = demo.table_selected, max_rows = 6 })
        if clicked_row then demo.table_selected = clicked_row end

        if demo.table_selected then
            UI.Spacing(2)
            UI.Text("Selected: " .. rows[demo.table_selected][1], { disabled = true })
        end

        UI.Spacing(8)

        -- Modal Dialog
        UI.Text("Modal Dialog")
        UI.Separator()
        UI.Spacing(4)

        if UI.Button("btn_modal", "Open Modal") then
            demo.show_modal = true
        end
        UI.SameLine()
        if demo.modal_result ~= "" then
            UI.Text("Result: " .. demo.modal_result)
        end

        UI.Spacing(8)

        -- Drag & Drop
        UI.Text("Drag & Drop")
        UI.Separator()
        UI.Spacing(4)

        for i, item in ipairs(demo.drag_items) do
            local btn_id = "drag_" .. i
            UI.Button(btn_id, item)
            UI.BeginDragSource(btn_id, i, "track", item)
        end

        UI.Spacing(4)
        UI.Text("Drop zone:", { disabled = true })
        local drop_x, drop_y = UI.Layout.GetCursorPos()
        local drop_w = UI.Layout.GetAvailableWidth()
        local drop_h = 30
        UI.Core.DrawRect(drop_x, drop_y, drop_w, drop_h, 0.2, 0.2, 0.22, 1)
        UI.Core.DrawRect(drop_x, drop_y, drop_w, drop_h, 0.3, 0.3, 0.32, 0.4, false)
        local dropped = UI.BeginDropTarget(drop_x, drop_y, drop_w, drop_h, "track")
        if dropped then
            local moved = table.remove(demo.drag_items, dropped)
            table.insert(demo.drag_items, 1, moved)
        end
        UI.Layout.AdvanceCursor(drop_w, drop_h)

        -- Draw drag preview on top
        UI.DrawDragPreview()

        UI.Spacing(8)

        -- Style info
        local _, sopen = UI.CollapsingHeader("sec_style", "Style Info", demo.section_style)
        demo.section_style = sopen
        if demo.section_style then
            UI.Indent()
            local t = UI.GetTheme()
            UI.Text("Font: " .. t.fonts.default_face .. " " .. t.fonts.default_size .. "px")
            UI.Text("Window padding: " .. t.window_padding .. "px")
            UI.Text("Item spacing: " .. t.item_spacing .. "px")
            UI.Text("Scale: " .. t.scale .. "x")
            UI.TextColored("Accent color sample", t.colors.accent[1], t.colors.accent[2], t.colors.accent[3], 1)
            UI.Unindent()
        end

    -- ================================================================
    -- TAB 6: Style (Phase 3 widgets)
    -- ================================================================
    elseif demo.active_tab == 6 then

        -- Theme Editor
        local t = UI.GetTheme()
        local groups = UI.Theme.GetColorGroups()

        -- Save / Reset buttons
        if UI.Button("btn_save_theme", "Save Theme") then
            UI.SaveTheme()
        end
        UI.SameLine()
        if UI.Button("btn_reset_theme", "Reset Default") then
            UI.ResetTheme()
        end

        UI.Spacing(6)

        -- Color groups
        for _, group in ipairs(groups) do
            local _, gopen = UI.CollapsingHeader("tcg_" .. group.name, group.name,
                demo["tcg_" .. group.name] ~= false)  -- open by default
            demo["tcg_" .. group.name] = gopen
            if gopen then
                UI.Indent()
                for _, key in ipairs(group.keys) do
                    local label = UI.Theme.GetColorLabel(key)
                    local c = t.colors[key]
                    if c then
                        local changed, new_c = UI.ColorPicker("tc_" .. key, label, c)
                        if changed then
                            t.colors[key] = { new_c[1], new_c[2], new_c[3], c[4] or 1 }
                        end
                    end
                end
                UI.Unindent()
            end
        end

        UI.Spacing(8)

        -- Spacing controls
        local _, sp_open = UI.CollapsingHeader("tcg_spacing", "Spacing & Sizes",
            demo.tcg_spacing ~= false)
        demo.tcg_spacing = sp_open
        if sp_open then
            UI.Indent()

            local sc1, sv1 = UI.NumberInput("ts_winpad", "Window Pad ", t.window_padding, 0, 30, { step = 1 })
            if sc1 then t.window_padding = sv1 end

            local sc2, sv2 = UI.NumberInput("ts_itemsp", "Item Space ", t.item_spacing, 0, 20, { step = 1 })
            if sc2 then t.item_spacing = sv2 end

            local sc3, sv3 = UI.NumberInput("ts_fpx", "Frame Pad X", t.frame_padding_x, 0, 20, { step = 1 })
            if sc3 then t.frame_padding_x = sv3 end

            local sc4, sv4 = UI.NumberInput("ts_fpy", "Frame Pad Y", t.frame_padding_y, 0, 20, { step = 1 })
            if sc4 then t.frame_padding_y = sv4 end

            local sc5, sv5 = UI.NumberInput("ts_indent", "Indent     ", t.indent, 4, 40, { step = 1 })
            if sc5 then t.indent = sv5 end

            UI.Unindent()
        end
    end

    -- Modal (drawn on top of everything when open)
    if demo.show_modal then
        UI.BeginModal("modal_confirm", "Confirm Action", { width = 280, height = 130 })
        UI.Text("Are you sure you want to proceed?")
        UI.Spacing(8)
        if UI.Button("modal_ok", "OK") then
            demo.show_modal = false
            demo.modal_result = "OK"
        end
        UI.SameLine()
        if UI.Button("modal_cancel", "Cancel") then
            demo.show_modal = false
            demo.modal_result = "Cancelled"
        end
        UI.EndModal()
    end

    -- Footer
    UI.Spacing(8)
    UI.Separator()
    if UI.Button("btn_dock", UI.IsDocked() and "Undock" or "Dock") then
        UI.ToggleDock()
    end
    UI.SameLine()
    UI.Text("CP Toolkit v0.3 — gfx native, zero dependencies", { disabled = true })
end)
