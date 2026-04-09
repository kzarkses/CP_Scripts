-- @description CP Theme Tweaker — Standalone live theme editor
-- @version 1.1
-- @author Cedric Pamalio
-- Launch alongside any CP_ script to edit colors/spacing/fonts in real time.
-- Saves to CP_Config/theme.lua — shared across ALL CP_ scripts.

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local UI = dofile(script_path .. "CP_Toolkit.lua")

UI.Init("CP Theme Tweaker", 380, 700, {
    scale = 1.0,
})

-- State
local active_tab = 1
local tabs = { "Presets", "Colors", "Layout", "Fonts", "Preview" }
local group_states = {}
local active_preset = 1
local save_name = "theme"
local eyedropper_target = nil  -- color key to set when eyedropper picks

-- Preview widget state (so values persist when interacting)
local pv = {
    toggle1 = true,
    toggle2 = false,
    cb1 = true,
    cb2 = false,
    radio = 2,
    slider = 0.65,
    combo = 1,
    input = "Sample text",
}

UI.Run(function()
    -- Tab bar
    local tc, nt = UI.TabBar("tw_tabs", tabs, active_tab)
    if tc then active_tab = nt end
    UI.Spacing(4)

    local t = UI.GetTheme()

    -- ================================================================
    -- PRESETS TAB
    -- ================================================================
    if active_tab == 1 then
        UI.Text("Built-in Presets")
        UI.Separator()
        UI.Spacing(4)

        local presets = UI.Theme.Presets()
        for i, preset in ipairs(presets) do
            local is_active = (i == active_preset)
            local toggled, _ = UI.ToggleButton("tw_preset_" .. i, preset.name, is_active)
            if toggled and not is_active then
                UI.ApplyPreset(preset.key)
                active_preset = i
            end
        end

        UI.Spacing(8)
        UI.Text("Save / Load")
        UI.Separator()
        UI.Spacing(4)

        -- Theme name input
        local nc, nv = UI.InputText("tw_savename", "Name  ", save_name, { hint = "theme name" })
        if nc then save_name = nv end

        UI.Spacing(4)

        -- Save / Save As
        if UI.Button("tw_save", "Save") then
            UI.SaveTheme(save_name)
        end
        UI.SameLine()
        if UI.Button("tw_saveas", "Save As...") then
            -- Save with current name (user changes name above first)
            if save_name ~= "" then
                UI.SaveTheme(save_name)
            end
        end

        UI.Spacing(6)

        -- List saved themes
        local saved = UI.Theme.ListSaved()
        if #saved > 0 then
            UI.Text("Saved themes:", { disabled = true })
            UI.Spacing(2)

            local items = {}
            for i, name in ipairs(saved) do
                items[i] = { label = name }
            end

            local clicked, action = UI.ActionList("tw_saved_list", items,
                { { icon = ">" }, { icon = "X" } },
                { max_visible = 6 })

            if clicked then
                if action == 1 then
                    -- Load
                    UI.LoadTheme(saved[clicked])
                    save_name = saved[clicked]
                elseif action == 2 then
                    -- Delete
                    local path = reaper.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Config/" .. saved[clicked] .. ".lua"
                    os.remove(path)
                end
            end
        end

    -- ================================================================
    -- COLORS TAB
    -- ================================================================
    elseif active_tab == 2 then
        local groups = UI.Theme.GetColorGroups()

        -- Eyedropper status
        if UI.IsEyedropperActive() then
            UI.Text("Pipette active — click anywhere to pick", { color = { 1, 0.8, 0.3, 1 } })
        elseif eyedropper_target then
            UI.Text("Color applied to: " .. eyedropper_target, { disabled = true })
        end

        UI.Spacing(4)

        for _, group in ipairs(groups) do
            local gid = "twg_" .. group.name
            if group_states[gid] == nil then group_states[gid] = false end

            local _, gopen = UI.CollapsingHeader(gid, group.name, group_states[gid])
            group_states[gid] = gopen

            if gopen then
                UI.Indent()
                for _, key in ipairs(group.keys) do
                    local label = UI.Theme.GetColorLabel(key)
                    local c = t.colors[key]
                    if c then
                        local changed, new_c = UI.ColorPicker("twc_" .. key, label, c)
                        if changed then
                            t.colors[key] = { new_c[1], new_c[2], new_c[3], c[4] or 1 }
                        end

                        -- Pipette button next to each color
                        UI.SameLine()
                        if UI.Button("twp_" .. key, "?") then
                            eyedropper_target = key
                            UI.StartEyedropper(function(color)
                                t.colors[key] = { color[1], color[2], color[3], c[4] or 1 }
                            end)
                        end
                    end
                end
                UI.Unindent()
            end
        end

    -- ================================================================
    -- LAYOUT TAB
    -- ================================================================
    elseif active_tab == 3 then
        UI.Text("Spacing")
        UI.Separator()
        UI.Spacing(4)

        local sc1, sv1 = UI.NumberInput("tw_winpad", "Window Pad  ", t.window_padding, 0, 40, { step = 1 })
        if sc1 then t.window_padding = sv1 end

        local sc2, sv2 = UI.NumberInput("tw_itemsp", "Item Space  ", t.item_spacing, 0, 20, { step = 1 })
        if sc2 then t.item_spacing = sv2 end

        local sc3, sv3 = UI.NumberInput("tw_fpx", "Frame Pad X ", t.frame_padding_x, 0, 20, { step = 1 })
        if sc3 then t.frame_padding_x = sv3 end

        local sc4, sv4 = UI.NumberInput("tw_fpy", "Frame Pad Y ", t.frame_padding_y, 0, 20, { step = 1 })
        if sc4 then t.frame_padding_y = sv4 end

        local sc5, sv5 = UI.NumberInput("tw_indent", "Indent      ", t.indent, 4, 40, { step = 1 })
        if sc5 then t.indent = sv5 end

        UI.Spacing(8)
        UI.Text("Widget Sizes")
        UI.Separator()
        UI.Spacing(4)

        local sc6, sv6 = UI.NumberInput("tw_cbsize", "Checkbox    ", t.checkbox_size, 8, 30, { step = 1 })
        if sc6 then t.checkbox_size = sv6 end

        local sc7, sv7 = UI.NumberInput("tw_slh", "Slider H    ", t.slider_height, 10, 40, { step = 1 })
        if sc7 then t.slider_height = sv7 end

        local sc8, sv8 = UI.NumberInput("tw_btnh", "Button H    ", t.button_height, 14, 40, { step = 1 })
        if sc8 then t.button_height = sv8 end

        local sc9, sv9 = UI.NumberInput("tw_tabh", "Tab H       ", t.tab_height, 16, 40, { step = 1 })
        if sc9 then t.tab_height = sv9 end

        local sc10, sv10 = UI.NumberInput("tw_cmbh", "Combo H     ", t.combo_height, 14, 40, { step = 1 })
        if sc10 then t.combo_height = sv10 end

        local sc11, sv11 = UI.NumberInput("tw_hdrh", "Header H    ", t.header_height, 20, 50, { step = 1 })
        if sc11 then t.header_height = sv11 end

    -- ================================================================
    -- FONTS TAB
    -- ================================================================
    elseif active_tab == 4 then
        UI.SetFontH1()
        UI.Text("Font Sizes")
        UI.SetFontBody()
        UI.Separator()
        UI.Spacing(4)

        UI.Text("Scroll or drag to adjust, double-click to type", { disabled = true })
        UI.Spacing(4)

        local fc0, fv0 = UI.NumberInput("tw_ftitle", "Title      ", t.fonts.title, 10, 36, { step = 1 })
        if fc0 then t.fonts.title = fv0; UI.Core.LoadFontSlots(t) end

        local fc1, fv1 = UI.NumberInput("tw_fh1", "H1         ", t.fonts.h1, 8, 32, { step = 1 })
        if fc1 then t.fonts.h1 = fv1; t.fonts.primary = fv1; UI.Core.LoadFontSlots(t) end

        local fc2, fv2 = UI.NumberInput("tw_fh2", "H2         ", t.fonts.h2, 8, 28, { step = 1 })
        if fc2 then t.fonts.h2 = fv2; UI.Core.LoadFontSlots(t) end

        local fc3, fv3 = UI.NumberInput("tw_fbody", "Body       ", t.fonts.body, 8, 24, { step = 1 })
        if fc3 then t.fonts.body = fv3; t.fonts.secondary = fv3; UI.Core.LoadFontSlots(t) end

        local fc4, fv4 = UI.NumberInput("tw_fcapt", "Caption    ", t.fonts.caption, 6, 20, { step = 1 })
        if fc4 then t.fonts.caption = fv4; t.fonts.tertiary = fv4; UI.Core.LoadFontSlots(t) end

        local fc5, fv5 = UI.NumberInput("tw_fmono", "Mono       ", t.fonts.mono_size, 8, 24, { step = 1 })
        if fc5 then t.fonts.mono_size = fv5; UI.Core.LoadFontSlots(t) end

        UI.Spacing(8)
        UI.Text("Font Faces")
        UI.Separator()
        UI.Spacing(4)

        local faces = { "Tahoma", "Arial", "Verdana", "Segoe UI", "Calibri", "Consolas" }
        local current_face_idx = 1
        for i, f in ipairs(faces) do
            if f == t.fonts.face then current_face_idx = i break end
        end

        local fcc, fci = UI.Combo("tw_face", "Main Font  ", current_face_idx, faces)
        if fcc then
            t.fonts.face = faces[fci]
            t.fonts.default_face = faces[fci]
            UI.Core.LoadFontSlots(t)
        end

        local mono_faces = { "Consolas", "Courier New", "Lucida Console" }
        local current_mono_idx = 1
        for i, f in ipairs(mono_faces) do
            if f == t.fonts.mono_face then current_mono_idx = i break end
        end

        local mcc, mci = UI.Combo("tw_monoface", "Mono Font  ", current_mono_idx, mono_faces)
        if mcc then
            t.fonts.mono_face = mono_faces[mci]
            UI.Core.LoadFontSlots(t)
        end

    -- ================================================================
    -- PREVIEW TAB
    -- ================================================================
    elseif active_tab == 5 then
        UI.SetFontH1()
        UI.Text("Font Hierarchy")
        UI.SetFontBody()
        UI.Separator()
        UI.Spacing(4)

        UI.SetFontTitle()
        UI.Text("Title — CP Inspector")
        UI.SetFontH1()
        UI.Text("H1 — Audio Settings")
        UI.SetFontH2()
        UI.Text("H2 — Pitch Algorithm")
        UI.SetFontH2Bold()
        UI.Text("H2 Bold — Section Label")
        UI.SetFontBody()
        UI.Text("Body — Default text for widgets and labels")
        UI.SetFontCaption()
        UI.Text("Caption — Hints, disabled text, small info")
        UI.SetFontMono()
        UI.Text("Mono — 0:12.345 | -3.2 dB | 120 BPM")
        UI.SetFontBody()

        UI.Spacing(6)
        UI.Text("Widgets")
        UI.Separator()
        UI.Spacing(4)

        UI.Button("tw_btn1", "Button")
        UI.SameLine()
        local tg1, tv1 = UI.ToggleButton("tw_tog", pv.toggle1 and "ON" or "OFF", pv.toggle1)
        if tg1 then pv.toggle1 = tv1 end
        UI.SameLine()
        local tg2, tv2 = UI.ToggleButton("tw_tog2", pv.toggle2 and "ON" or "OFF", pv.toggle2)
        if tg2 then pv.toggle2 = tv2 end

        UI.Spacing(4)
        local cb1, ncb1 = UI.Checkbox("tw_cb", "Checkbox A", pv.cb1)
        if cb1 then pv.cb1 = ncb1 end
        local cb2, ncb2 = UI.Checkbox("tw_cb2", "Checkbox B", pv.cb2)
        if cb2 then pv.cb2 = ncb2 end

        UI.Spacing(4)
        local sc, sv = UI.SliderDouble("tw_sl", "Slider ", pv.slider, 0, 1)
        if sc then pv.slider = sv end

        local cc, ci = UI.Combo("tw_cmb", "Combo  ", pv.combo, { "Option A", "Option B", "Option C" })
        if cc then pv.combo = ci end

        local ic, iv = UI.InputText("tw_inp", "Input  ", pv.input)
        if ic then pv.input = iv end

        UI.Spacing(4)
        local time = reaper.time_precise()
        UI.ProgressBar("tw_pb", (math.sin(time) + 1) / 2)

        UI.Spacing(6)
        UI.Text("Color Palette")
        UI.Separator()
        UI.Spacing(4)

        local palette = { "window_bg", "text", "accent", "button", "frame_bg", "header", "tab_active", "popup_bg", "border" }
        UI.BeginGrid("tw_palette", { cell_w = 80, cell_h = 22, gap = 4 })
        for _, key in ipairs(palette) do
            local c = t.colors[key]
            if c then
                local gx, gy, gw, gh = UI.GridCell("tw_palette")
                -- Color swatch
                UI.Core.DrawRect(gx, gy, 16, gh, c[1], c[2], c[3], c[4])
                UI.Core.DrawRect(gx, gy, 16, gh, 0.5, 0.5, 0.5, 0.2, false)
                -- Label
                UI.SetFontCaption()
                UI.Core.DrawText(key, gx + 20, gy + 4, t.colors.text[1], t.colors.text[2], t.colors.text[3], 0.6)
                UI.SetFontBody()
            end
        end
        UI.EndGrid("tw_palette")
    end

end)
