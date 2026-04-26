-- @description CP Inspector Settings — visual tweaker (real-time, tabbed)
-- @version 1.1
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")
local InspCore = dofile(script_path .. "Modules/Core.lua")

InspCore.SetToolkit(UI)
InspCore.LoadSettings()

UI.Init("CP Inspector — Settings", 460, 540, {
    scale = 1.0,
    dock = 0,
    persist = "CP_Inspector_Settings",
})

local prefs = InspCore.state.prefs
local font_modes = { "mono", "body" }
local align_modes = { "left", "center", "right" }
local time_mode_labels = {}
for i, m in ipairs(InspCore.TIME_MODES) do time_mode_labels[i] = m.label end

local function find_index(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return 1
end

-- Auto-save: any value change marks dirty; throttled save bumps version
-- so the running Inspector picks up changes within ~100ms.
local dirty = false
local last_save_time = 0
local function mark() dirty = true end

local tabs = { "Layout", "Text", "Colors", "Time", "Properties" }
local active_tab = UI.LoadPersistent and UI.LoadPersistent("CP_Inspector_Settings", "tab", 1) or 1

-- ============================================================================
-- TAB CONTENT FUNCTIONS
-- ============================================================================
local function tab_layout()
    local changed, v

    changed, v = UI.SliderInt("row_h", "Row height", prefs.row_height, 14, 40)
    if changed then prefs.row_height = v; mark() end

    changed, v = UI.SliderInt("win_pad", "Window padding", prefs.window_padding, 0, 16)
    if changed then prefs.window_padding = v; mark() end

    changed, v = UI.SliderInt("top_pad", "Extra top padding", prefs.top_padding, 0, 40)
    if changed then prefs.top_padding = v; mark() end

    changed, v = UI.SliderInt("gap", "Header / value gap", prefs.gap, 0, 12)
    if changed then prefs.gap = v; mark() end

    changed, v = UI.SliderInt("col_gap", "Column gap", prefs.col_gap, 0, 20)
    if changed then prefs.col_gap = v; mark() end

    changed, v = UI.SliderInt("pad_x", "Cell padding X", prefs.cell_padding_x, 0, 16)
    if changed then prefs.cell_padding_x = v; mark() end

    UI.Spacing(6)
    local toggled, new_check = UI.Checkbox("show_h", "Show header row", prefs.show_header)
    if toggled then prefs.show_header = new_check; mark() end
end

local function tab_text()
    local font_idx = find_index(font_modes, prefs.font_value)
    local fchanged, fnew = UI.Combo("font_v", "Value font", font_idx, font_modes, { width = 220 })
    if fchanged then prefs.font_value = font_modes[fnew]; mark() end

    local align_idx = find_index(align_modes, prefs.text_align)
    local achanged, anew = UI.Combo("align", "Text align", align_idx, align_modes, { width = 220 })
    if achanged then prefs.text_align = align_modes[anew]; mark() end
end

local function tab_colors()
    local function color_row(id, label, c)
        local cc = { c[1], c[2], c[3] }
        local cch, cnew = UI.ColorPicker(id, label, cc)
        if cch then
            c[1], c[2], c[3] = cnew[1], cnew[2], cnew[3]
            mark()
        end
    end
    color_row("col_bg", "Background", prefs.col_bg)
    color_row("col_n",  "Normal",     prefs.col_normal)
    color_row("col_m",  "Modified",   prefs.col_modified)
    color_row("col_ng", "Negative",   prefs.col_negative)
    color_row("col_h",  "Header",     prefs.col_header)

    UI.Spacing(6)
    local hch, ha = UI.SliderDouble("hdr_a", "Header alpha",
        prefs.col_header[4] or 0.5, 0.1, 1.0)
    if hch then prefs.col_header[4] = ha; mark() end
end

local function tab_time()
    local tchanged, tnew = UI.Combo("tm", "Display format", InspCore.state.time_mode,
        time_mode_labels, { width = 280 })
    if tchanged then InspCore.state.time_mode = tnew; mark() end
end

local function tab_properties()
    UI.Text("Toggle visibility of property columns:", { disabled = true })
    UI.Spacing(4)
    for _, p in ipairs(InspCore.PROPERTIES) do
        local on = InspCore.state.visible_props[p.key]
        local ch, nv = UI.Checkbox("vis_" .. p.key, p.label, on)
        if ch then InspCore.state.visible_props[p.key] = nv; mark() end
    end
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
UI.Run(function()
    UI.CheckThemeUpdates()
    local tchanged, tnew = UI.TabBar("settings_tabs", tabs, active_tab)
    if tchanged then
        active_tab = tnew
        if UI.SavePersistent then
            UI.SavePersistent("CP_Inspector_Settings", "tab", active_tab)
        end
    end

    UI.Spacing(8)

    if active_tab == 1 then
        tab_layout()
    elseif active_tab == 2 then
        tab_text()
    elseif active_tab == 3 then
        tab_colors()
    elseif active_tab == 4 then
        tab_time()
    elseif active_tab == 5 then
        tab_properties()
    end

    -- Throttled auto-save (live updates without spamming ExtState)
    if dirty then
        local now = reaper.time_precise()
        if now - last_save_time > 0.10 then
            InspCore.SaveSettings()
            last_save_time = now
            dirty = false
        end
    end
end)

UI.OnClose(function()
    if dirty then InspCore.SaveSettings() end
end)
