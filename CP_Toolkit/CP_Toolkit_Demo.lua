-- @description CP_Toolkit Demo — Complete widget showcase
-- @version 0.3
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local UI = dofile(script_path .. "CP_Toolkit.lua")

UI.Init("CP Toolkit Demo", 560, 750, { scale = 1 })

-- ============================================================================
-- STATE
-- ============================================================================
local s = {
    tab = 1,
    tabs = { "Widgets", "Layout", "Controls", "Icons", "Advanced" },

    -- Widgets tab
    click_count = 0,
    cb_a = true, cb_b = false,
    toggle_a = true, toggle_b = false,
    slider_int = 72, slider_dbl = 0.65,
    range_min = 0.2, range_max = 0.8,
    combo = 1, combo_items = { "Option A", "Option B", "Option C", "Option D" },
    radio = 2,
    input_text = "Hello World",
    num_val = 120,

    -- Layout tab
    sec_wrap = true, sec_columns = true, sec_grid = true,

    -- Controls tab
    knob_a = 0.75, knob_b = 0.5, knob_c = 0.0, knob_d = 0.3,
    meter_time = 0,
    progress = 0, progress_dir = 1,
    tree_root = true, tree_a = false, tree_b = false,
    sec_tree = true,
    note_text = "Session notes:\n- Drums take 3\n- Bass re-amp needed",

    -- Advanced tab
    table_sel = nil,
    show_modal = false, modal_result = "",
    drag_items = { "Track 1", "Track 2", "Track 3", "Track 4" },
    canvas_x = 0.5, canvas_y = 0.5,
    sec_style = false,
    reorder = nil,
}

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
UI.Run(function(theme)
    -- Header
    UI.SetFontTitle()
    UI.Text("CP Toolkit Demo")
    UI.SetFontBody()
    UI.Text("[F12] Log  [F11] Console", { disabled = true })
    UI.Spacing(4)

    -- Tabs
    local tc, nt = UI.TabBar("tabs", s.tabs, s.tab)
    if tc then s.tab = nt end
    UI.Spacing(4)

    -- ================================================================
    -- TAB 1: WIDGETS
    -- ================================================================
    if s.tab == 1 then

        -- Fonts
        UI.SetFontH1()
        UI.Text("Font Hierarchy")
        UI.SetFontBody()
        UI.Spacing(2)
        UI.SetFontH2()
        UI.Text("H2 — Sub-section")
        UI.SetFontCaption()
        UI.Text("Caption — small hint text")
        UI.SetFontMono()
        UI.Text("Mono — 0:12.345 | -3.2 dB | 120 BPM")
        UI.SetFontBody()

        UI.Spacing(6)
        UI.Separator()
        UI.Spacing(4)

        -- Buttons
        UI.SetFontH1()
        UI.Text("Buttons & Toggles")
        UI.SetFontBody()
        UI.Spacing(2)

        if UI.Button("btn_a", "Click me") then s.click_count = s.click_count + 1 end
        UI.SameLine()
        if UI.Button("btn_b", "Reset") then s.click_count = 0 end
        UI.SameLine()
        UI.Text("Count: " .. s.click_count)

        UI.Spacing(2)
        local ta, va = UI.ToggleButton("tog_a", s.toggle_a and "ON" or "OFF", s.toggle_a)
        if ta then s.toggle_a = va end
        UI.SameLine()
        local tb, vb = UI.ToggleButton("tog_b", s.toggle_b and "ON" or "OFF", s.toggle_b)
        if tb then s.toggle_b = vb end

        UI.Spacing(4)
        local ca, na = UI.Checkbox("cb_a", "Checkbox enabled", s.cb_a)
        if ca then s.cb_a = na end
        local cb2, nb = UI.Checkbox("cb_b", "Checkbox disabled", s.cb_b)
        if cb2 then s.cb_b = nb end

        UI.Spacing(4)
        local rc, ri = UI.RadioGroup("radio", "Mode ", s.radio,
            { "Draft", "Normal", "High" }, { horizontal = true })
        if rc then s.radio = ri end

        UI.Spacing(6)
        UI.Separator()
        UI.Spacing(4)

        -- Sliders & Inputs
        UI.SetFontH1()
        UI.Text("Sliders & Inputs")
        UI.SetFontBody()
        UI.Spacing(2)

        local si, vi = UI.SliderInt("sl_int", "Buffer  ", s.slider_int, 32, 2048)
        if si then s.slider_int = vi end

        local sd, vd = UI.SliderDouble("sl_dbl", "Volume  ", s.slider_dbl, 0, 1)
        if sd then s.slider_dbl = vd end

        UI.Spacing(2)
        local rsc, rv1, rv2 = UI.RangeSlider("rng", "Range   ", s.range_min, s.range_max, 0, 1)
        if rsc then s.range_min = rv1; s.range_max = rv2 end

        UI.Spacing(2)
        local nc, nv = UI.NumberInput("num", "BPM     ", s.num_val, 20, 300, { step = 1 })
        if nc then s.num_val = nv end

        UI.Spacing(2)
        local ic, iv = UI.InputText("inp", "Text    ", s.input_text)
        if ic then s.input_text = iv end

        UI.Spacing(2)
        local cc, ci = UI.Combo("cmb", "Algo    ", s.combo, s.combo_items)
        if cc then s.combo = ci end

    -- ================================================================
    -- TAB 2: LAYOUT
    -- ================================================================
    elseif s.tab == 2 then

        -- Wrap
        local _, wopen = UI.CollapsingHeader("sec_wrap", "BeginWrap — Auto-flow", s.sec_wrap)
        s.sec_wrap = wopen
        if s.sec_wrap then
            UI.Indent()
            UI.BeginWrap("demo_wrap", { gap = 4 })
            for i = 1, 12 do
                UI.Button("wr_" .. i, "Item " .. i)
            end
            UI.EndWrap()
            UI.Unindent()
        end

        UI.Spacing(4)

        -- Columns
        local _, copen = UI.CollapsingHeader("sec_cols", "BeginColumns — 30/70", s.sec_columns)
        s.sec_columns = copen
        if s.sec_columns then
            UI.Indent()
            UI.BeginColumns("demo_cols", { 0.3, 0.7 })

            UI.Text("Left column")
            UI.Text("30% width")
            UI.Button("col_btn_l", "Button L")

            UI.NextColumn()

            UI.Text("Right column")
            UI.Text("70% width")
            UI.SliderDouble("col_sl", "Slider ", 0.5, 0, 1)

            UI.EndColumns()
            UI.Unindent()
        end

        UI.Spacing(4)

        -- Grid
        local _, gopen = UI.CollapsingHeader("sec_grid", "BeginGrid — Auto cells", s.sec_grid)
        s.sec_grid = gopen
        if s.sec_grid then
            UI.Indent()
            UI.BeginGrid("demo_grid", { cell_w = 70, cell_h = 50, gap = 4 })
            for i = 1, 8 do
                local gx, gy, gw, gh = UI.GridCell("demo_grid")
                -- Draw cell background
                local c = (i % 2 == 0) and theme.colors.frame_bg or theme.colors.header
                UI.Core.DrawRect(gx, gy, gw, gh, c[1], c[2], c[3], c[4])
                UI.Core.DrawRect(gx, gy, gw, gh, theme.colors.border[1], theme.colors.border[2], theme.colors.border[3], 0.3, false)
                -- Cell label
                UI.SetFontCaption()
                local tw = UI.Core.MeasureText("Cell " .. i)
                UI.Core.DrawText("Cell " .. i, gx + (gw - tw) / 2, gy + gh / 2 - 5,
                    theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 0.7)
                UI.SetFontBody()
            end
            UI.EndGrid("demo_grid")
            UI.Unindent()
        end

        UI.Spacing(4)

        -- Scrollable child
        UI.SetFontH1()
        UI.Text("Scrollable Child Region")
        UI.SetFontBody()
        UI.Spacing(2)

        UI.BeginChild("scroll", 0, 120, { scrollable = true, border = true })
        for i = 1, 20 do
            UI.Text("Scrollable item " .. i)
        end
        UI.EndChild()

    -- ================================================================
    -- TAB 3: CONTROLS
    -- ================================================================
    elseif s.tab == 3 then

        -- This tab displays animated VU meters and a moving progress bar.
        -- Without this call, idle throttle would freeze them when the mouse
        -- is still. RequestRedraw keeps the loop in active mode each frame.
        UI.RequestRedraw()

        -- Knobs
        UI.SetFontH1()
        UI.Text("Knobs")
        UI.SetFontBody()
        UI.Spacing(2)

        UI.BeginWrap("knobs", { gap = 8 })
        local ka, va = UI.Knob("k_vol", "Vol", s.knob_a, 0.75)
        if ka then s.knob_a = va end
        local kb, vbb = UI.Knob("k_pan", "Pan", s.knob_b, 0.5)
        if kb then s.knob_b = vbb end
        local kc, vc = UI.Knob("k_send", "Send", s.knob_c, 0.0)
        if kc then s.knob_c = vc end
        local kd, vdd = UI.Knob("k_drive", "Drive", s.knob_d, 0.3, { size = 50 })
        if kd then s.knob_d = vdd end
        UI.EndWrap()

        UI.Spacing(6)

        -- VU Meters
        UI.SetFontH1()
        UI.Text("VU Meters")
        UI.SetFontBody()
        UI.Spacing(2)

        s.meter_time = s.meter_time + 0.03
        local t = s.meter_time
        local pl = math.abs(math.sin(t * 1.1)) * 0.7 + math.random() * 0.1
        local pr = math.abs(math.sin(t * 0.9 + 0.5)) * 0.7 + math.random() * 0.1

        UI.VMeter("vm1", pl, pr, { width = 14, height = 60 })
        UI.SameLine()
        UI.VMeter("vm2", pl * 0.6, pr * 0.6, { width = 14, height = 60 })
        UI.SameLine()
        UI.VMeter("vm3", pl * 0.3, pr * 0.3, { width = 14, height = 60 })

        UI.Spacing(4)
        UI.HMeter("hm1", pl, pr, { width = 200, height = 10 })

        UI.Spacing(6)

        -- Progress
        UI.SetFontH1()
        UI.Text("Progress Bar")
        UI.SetFontBody()
        UI.Spacing(2)

        s.progress = s.progress + 0.005 * s.progress_dir
        if s.progress >= 1 then s.progress_dir = -1 elseif s.progress <= 0 then s.progress_dir = 1 end
        UI.ProgressBar("pb1", s.progress)

        UI.Spacing(6)

        -- Tree
        local _, topen = UI.CollapsingHeader("sec_tree", "Tree Nodes", s.sec_tree)
        s.sec_tree = topen
        if s.sec_tree then
            local _, ra = UI.TreeNode("t_root", "Master Track", s.tree_root)
            s.tree_root = ra
            if s.tree_root then
                local _, fa = UI.TreeNode("t_fx", "FX Chain", s.tree_a)
                s.tree_a = fa
                if s.tree_a then
                    UI.Text("ReaEQ")
                    UI.Text("ReaComp")
                    UI.TreePop()
                end
                local _, fb = UI.TreeNode("t_sends", "Sends", s.tree_b)
                s.tree_b = fb
                if s.tree_b then
                    UI.Text("Bus A")
                    UI.Text("Bus B")
                    UI.TreePop()
                end
                UI.TreePop()
            end
        end

        UI.Spacing(6)

        -- Multi-line text
        UI.SetFontH1()
        UI.Text("Multi-line Text Edit")
        UI.SetFontBody()
        UI.Spacing(2)

        local ntc, ntv = UI.TextEdit("notes", s.note_text, { height = 80 })
        if ntc then s.note_text = ntv end

    -- ================================================================
    -- TAB 4: ICONS
    -- ================================================================
    elseif s.tab == 4 then

        UI.SetFontH1()
        UI.Text("Icon Library")
        UI.SetFontBody()
        UI.Spacing(4)

        local icon_size = 28
        local icon_list = {
            -- Arrows
            { name = "ChevronDown", fn = UI.Icons.ChevronDown },
            { name = "ChevronUp", fn = UI.Icons.ChevronUp },
            { name = "ChevronLeft", fn = UI.Icons.ChevronLeft },
            { name = "ChevronRight", fn = UI.Icons.ChevronRight },
            { name = "TriangleDown", fn = UI.Icons.TriangleDown },
            { name = "TriangleUp", fn = UI.Icons.TriangleUp },
            { name = "TriangleLeft", fn = UI.Icons.TriangleLeft },
            { name = "TriangleRight", fn = UI.Icons.TriangleRight },
            -- UI
            { name = "Close", fn = UI.Icons.Close },
            { name = "Check", fn = UI.Icons.Check },
            { name = "Plus", fn = UI.Icons.Plus },
            { name = "Minus", fn = UI.Icons.Minus },
            { name = "Search", fn = UI.Icons.Search },
            { name = "Settings", fn = UI.Icons.Settings },
            { name = "Refresh", fn = UI.Icons.Refresh },
            -- Transport
            { name = "Play", fn = UI.Icons.Play },
            { name = "Pause", fn = UI.Icons.Pause },
            { name = "Stop", fn = UI.Icons.Stop },
            { name = "Record", fn = UI.Icons.Record },
            { name = "SkipFwd", fn = UI.Icons.SkipForward },
            { name = "SkipBwd", fn = UI.Icons.SkipBackward },
            { name = "Loop", fn = UI.Icons.Loop },
            -- Actions
            { name = "Undo", fn = UI.Icons.Undo },
            { name = "Redo", fn = UI.Icons.Redo },
            { name = "Delete", fn = UI.Icons.Delete },
            { name = "Copy", fn = UI.Icons.Copy },
            { name = "Save", fn = UI.Icons.Save },
            -- State
            { name = "Lock", fn = UI.Icons.Lock },
            { name = "Unlock", fn = UI.Icons.Unlock },
            { name = "Eye", fn = UI.Icons.Eye },
            { name = "EyeOff", fn = UI.Icons.EyeOff },
            { name = "Mute", fn = UI.Icons.Mute },
            { name = "Volume", fn = UI.Icons.Volume },
            { name = "Solo", fn = UI.Icons.Solo },
            -- Audio
            { name = "Waveform", fn = UI.Icons.Waveform },
            { name = "MIDI", fn = UI.Icons.MIDI },
            { name = "FX", fn = UI.Icons.FX },
            -- Files
            { name = "Folder", fn = UI.Icons.Folder },
            { name = "File", fn = UI.Icons.File },
            -- Tools
            { name = "Crosshair", fn = UI.Icons.Crosshair },
            { name = "Pipette", fn = UI.Icons.Pipette },
        }

        UI.BeginGrid("icons_grid", { cell_w = 90, cell_h = icon_size + 18, gap = 4 })
        for _, icon in ipairs(icon_list) do
            local gx, gy, gw, gh = UI.GridCell("icons_grid")

            -- Background on hover
            local hovered = UI.Core.MouseInRect(gx, gy, gw, gh)
            if hovered then
                UI.Core.DrawRect(gx, gy, gw, gh, theme.colors.header_hovered[1], theme.colors.header_hovered[2], theme.colors.header_hovered[3], 0.3)
            end
            UI.Core.DrawRect(gx, gy, gw, gh, theme.colors.border[1], theme.colors.border[2], theme.colors.border[3], 0.15, false)

            -- Icon centered
            local icon_x = gx + (gw - icon_size) / 2
            icon.fn(icon_x, gy + 2, icon_size, theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 0.9)

            -- Label centered below
            UI.SetFontCaption()
            local tw = UI.Core.MeasureText(icon.name)
            UI.Core.DrawText(icon.name, gx + (gw - tw) / 2, gy + icon_size + 3,
                theme.colors.text_disabled[1], theme.colors.text_disabled[2], theme.colors.text_disabled[3], 0.8)
            UI.SetFontBody()
        end
        UI.EndGrid("icons_grid")

        UI.Spacing(4)
        UI.SetFontCaption()
        UI.Text(#icon_list .. " icons available", { disabled = true })
        UI.SetFontBody()

    -- ================================================================
    -- TAB 5: ADVANCED
    -- ================================================================
    elseif s.tab == 5 then

        -- Canvas
        UI.SetFontH1()
        UI.Text("Canvas / Draw Area")
        UI.SetFontBody()
        UI.Spacing(2)

        local cv = UI.Canvas("canvas", { height = 120, crosshair = true, grid = 4 })
        if cv.dragging and cv.norm_x then
            s.canvas_x = cv.norm_x
            s.canvas_y = cv.norm_y
        end
        -- Draw a dot at the tracked position
        local dot_x = cv.x + s.canvas_x * cv.w
        local dot_y = cv.y + s.canvas_y * cv.h
        UI.DrawCircle(dot_x, dot_y, 6, theme.colors.accent[1], theme.colors.accent[2], theme.colors.accent[3], 1, true)

        UI.Spacing(6)

        -- Table
        UI.SetFontH1()
        UI.Text("Table / Grid")
        UI.SetFontBody()
        UI.Spacing(2)

        local columns = {
            { header = "Track", width = 100 },
            { header = "Type", width = 50 },
            { header = "Volume" },
            { header = "Pan", width = 40 },
        }
        local rows = {
            { "Master", "Bus", "0.0 dB", "C" },
            { "Drums", "Audio", "-3.2 dB", "C" },
            { "Bass", "Audio", "-6.0 dB", "L15" },
            { "Keys", "MIDI", "-4.5 dB", "R10" },
            { "Vocals", "Audio", "-2.1 dB", "C" },
        }
        local cr, cc = UI.Table("tbl", columns, rows, { selected = s.table_sel, max_rows = 5 })
        if cr then s.table_sel = cr end

        UI.Spacing(6)

        -- Modal
        UI.SetFontH1()
        UI.Text("Modal Dialog")
        UI.SetFontBody()
        UI.Spacing(2)

        if UI.Button("btn_modal", "Open Modal") then s.show_modal = true end
        UI.SameLine()
        if s.modal_result ~= "" then UI.Text("Result: " .. s.modal_result) end

        UI.Spacing(6)

        -- Context menu
        UI.Text("Right-click for context menu", { disabled = true })
        UI.ContextMenu("ctx", {
            { label = "Cut", shortcut = "Ctrl+X" },
            { label = "Copy", shortcut = "Ctrl+C" },
            { label = "Paste", shortcut = "Ctrl+V" },
            { separator = true },
            { label = "Select All", shortcut = "Ctrl+A" },
        })

        UI.Spacing(6)

        -- Style info
        local _, sopen = UI.CollapsingHeader("sec_style", "Style Info", s.sec_style)
        s.sec_style = sopen
        if s.sec_style then
            UI.Indent()
            local t = UI.GetTheme()
            UI.SetFontCaption()
            UI.Text("Font: " .. t.fonts.face .. " | Body: " .. t.fonts.body .. "px | Scale: " .. t.scale .. "x")
            UI.Text("Padding: " .. t.window_padding .. " | Spacing: " .. t.item_spacing .. " | Indent: " .. t.indent)
            UI.SetFontBody()
            UI.Unindent()
        end
    end

    -- Modal (drawn on top)
    if s.show_modal then
        UI.BeginModal("modal", "Confirm Action", { width = 280, height = 120 })
        UI.Text("Are you sure?")
        UI.Spacing(6)
        if UI.Button("m_ok", "OK") then s.show_modal = false; s.modal_result = "OK" end
        UI.SameLine()
        if UI.Button("m_cancel", "Cancel") then s.show_modal = false; s.modal_result = "Cancelled" end
        UI.EndModal()
    end

    -- Footer
    UI.Spacing(6)
    UI.Separator()
    if UI.Button("btn_dock", UI.IsDocked() and "Undock" or "Dock") then UI.ToggleDock() end
    UI.SameLine()
    UI.Text("CP Toolkit v0.3", { disabled = true })
end)
