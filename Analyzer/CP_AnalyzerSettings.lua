local r = reaper

local script_name = "CP_AnalyzerSettings"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then
    local loader_func = dofile(style_loader_path)
    if loader_func then
        style_loader = loader_func()
    end
end

local ctx = r.ImGui_CreateContext('Analyzer Settings')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then
    style_loader.ApplyFontsToContext(ctx)
end

local config = {
    window_width = 400,
    window_height = 500,
}

local gonio_defaults = {
    show_grid = true,
    max_points = 1024,
    line_fade = true,
    color = "#33CCCC",
    grid_alpha = 0.2,
    line_alpha = 0.6,
}

local freq_defaults = {
    show_grid = true,
    show_fill = true,
    show_peak_hold = true,
    interpolation = 2,
    octave_smoothing = 0,
    main_color = "#1ABC98",
    fill_alpha = 1.0,
}

local gonio_settings = {}
local freq_settings = {}

local max_points_options = {256, 512, 1024}
local max_points_labels = {"256 (Fast)", "512 (Balanced)", "1024 (Quality)"}
local interpolation_options = {0, 2, 4}
local interpolation_labels = {"Off (Fast)", "Low (2 steps)", "High (4 steps)"}
local octave_labels = {"Off", "1/24 octave", "1/12 octave", "1/6 octave", "1/3 octave"}

local state = {
    current_tab = 0,
}

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

function ApplyStyle()
    if style_loader then
        local success, colors, vars = style_loader.ApplyToContext(ctx)
        if success then
            pushed_colors = colors
            pushed_vars = vars
            return true
        end
    end
    return false
end

function ClearStyle()
    if style_loader then
        style_loader.ClearStyles(ctx, pushed_colors, pushed_vars)
    end
end

function DeepCopy(orig)
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = v
    end
    return copy
end

function LoadGonioSettings()
    gonio_settings = DeepCopy(gonio_defaults)

    local extname = "CP_Goniometer_GFX"

    if r.HasExtState(extname, "show_grid") then
        gonio_settings.show_grid = r.GetExtState(extname, "show_grid") == "1"
    end
    if r.HasExtState(extname, "max_points") then
        gonio_settings.max_points = tonumber(r.GetExtState(extname, "max_points")) or gonio_defaults.max_points
    end
    if r.HasExtState(extname, "line_fade") then
        gonio_settings.line_fade = r.GetExtState(extname, "line_fade") == "1"
    end
    if r.HasExtState(extname, "color") then
        gonio_settings.color = r.GetExtState(extname, "color")
    end
    if r.HasExtState(extname, "grid_alpha") then
        gonio_settings.grid_alpha = tonumber(r.GetExtState(extname, "grid_alpha")) or gonio_defaults.grid_alpha
    end
    if r.HasExtState(extname, "line_alpha") then
        gonio_settings.line_alpha = tonumber(r.GetExtState(extname, "line_alpha")) or gonio_defaults.line_alpha
    end
end

function LoadFreqSettings()
    freq_settings = DeepCopy(freq_defaults)

    local extname = "CP_FrequencyAnalyzer_GFX"

    if r.HasExtState(extname, "show_grid") then
        freq_settings.show_grid = r.GetExtState(extname, "show_grid") == "1"
    end
    if r.HasExtState(extname, "show_fill") then
        freq_settings.show_fill = r.GetExtState(extname, "show_fill") == "1"
    end
    if r.HasExtState(extname, "show_peak_hold") then
        freq_settings.show_peak_hold = r.GetExtState(extname, "show_peak_hold") == "1"
    end
    if r.HasExtState(extname, "interpolation") then
        freq_settings.interpolation = tonumber(r.GetExtState(extname, "interpolation")) or freq_defaults.interpolation
    end
    if r.HasExtState(extname, "octave_smoothing") then
        freq_settings.octave_smoothing = tonumber(r.GetExtState(extname, "octave_smoothing")) or freq_defaults.octave_smoothing
    end
    if r.HasExtState(extname, "main_color") then
        freq_settings.main_color = r.GetExtState(extname, "main_color")
    end
    if r.HasExtState(extname, "fill_alpha") then
        freq_settings.fill_alpha = tonumber(r.GetExtState(extname, "fill_alpha")) or freq_defaults.fill_alpha
    end
end

function SaveGonioSettings()
    local extname = "CP_Goniometer_GFX"

    r.SetExtState(extname, "show_grid", gonio_settings.show_grid and "1" or "0", true)
    r.SetExtState(extname, "max_points", tostring(gonio_settings.max_points), true)
    r.SetExtState(extname, "line_fade", gonio_settings.line_fade and "1" or "0", true)
    r.SetExtState(extname, "color", gonio_settings.color, true)
    r.SetExtState(extname, "grid_alpha", tostring(gonio_settings.grid_alpha), true)
    r.SetExtState(extname, "line_alpha", tostring(gonio_settings.line_alpha), true)
    r.SetExtState(extname, "settings_changed", tostring(r.time_precise()), true)
end

function SaveFreqSettings()
    local extname = "CP_FrequencyAnalyzer_GFX"

    r.SetExtState(extname, "show_grid", freq_settings.show_grid and "1" or "0", true)
    r.SetExtState(extname, "show_fill", freq_settings.show_fill and "1" or "0", true)
    r.SetExtState(extname, "show_peak_hold", freq_settings.show_peak_hold and "1" or "0", true)
    r.SetExtState(extname, "interpolation", tostring(freq_settings.interpolation), true)
    r.SetExtState(extname, "octave_smoothing", tostring(freq_settings.octave_smoothing), true)
    r.SetExtState(extname, "main_color", freq_settings.main_color, true)
    r.SetExtState(extname, "fill_alpha", tostring(freq_settings.fill_alpha), true)
    r.SetExtState(extname, "settings_changed", tostring(r.time_precise()), true)
end

function ResetGonioToDefaults()
    gonio_settings = DeepCopy(gonio_defaults)
    SaveGonioSettings()
end

function ResetFreqToDefaults()
    freq_settings = DeepCopy(freq_defaults)
    SaveFreqSettings()
end

function HexToImGuiColor(hex)
    hex = hex:gsub("#", "")
    local r_val = tonumber(hex:sub(1, 2), 16) or 0
    local g_val = tonumber(hex:sub(3, 4), 16) or 0
    local b_val = tonumber(hex:sub(5, 6), 16) or 0
    return (r_val << 24) | (g_val << 16) | (b_val << 8) | 0xFF
end

function ImGuiColorToHex(color)
    local r_val = (color >> 24) & 0xFF
    local g_val = (color >> 16) & 0xFF
    local b_val = (color >> 8) & 0xFF
    return string.format("#%02X%02X%02X", r_val, g_val, b_val)
end

function FindIndexInTable(tbl, value)
    for i, v in ipairs(tbl) do
        if v == value then return i end
    end
    return 1
end

function DrawGonioSettings()
    local changed = false

    local ret_grid, new_grid = r.ImGui_Checkbox(ctx, "Show Grid", gonio_settings.show_grid)
    if ret_grid then
        gonio_settings.show_grid = new_grid
        changed = true
    end

    local ret_fade, new_fade = r.ImGui_Checkbox(ctx, "Line Fade", gonio_settings.line_fade)
    if ret_fade then
        gonio_settings.line_fade = new_fade
        changed = true
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Max Points")
    local current_points_idx = FindIndexInTable(max_points_options, gonio_settings.max_points)
    r.ImGui_SetNextItemWidth(ctx, -1)
    if r.ImGui_BeginCombo(ctx, "##max_points", max_points_labels[current_points_idx]) then
        for i, label in ipairs(max_points_labels) do
            local is_selected = (current_points_idx == i)
            if r.ImGui_Selectable(ctx, label, is_selected) then
                gonio_settings.max_points = max_points_options[i]
                changed = true
            end
        end
        r.ImGui_EndCombo(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Line Alpha")
    r.ImGui_SetNextItemWidth(ctx, -1)
    local ret_line_alpha, new_line_alpha = r.ImGui_SliderDouble(ctx, "##line_alpha", gonio_settings.line_alpha, 0.1, 1.0, "%.2f")
    if ret_line_alpha then
        gonio_settings.line_alpha = new_line_alpha
        changed = true
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Grid Alpha")
    r.ImGui_SetNextItemWidth(ctx, -1)
    local ret_grid_alpha, new_grid_alpha = r.ImGui_SliderDouble(ctx, "##grid_alpha", gonio_settings.grid_alpha, 0.05, 0.5, "%.2f")
    if ret_grid_alpha then
        gonio_settings.grid_alpha = new_grid_alpha
        changed = true
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Color")
    local current_color = HexToImGuiColor(gonio_settings.color)
    local ret_color, new_color = r.ImGui_ColorEdit3(ctx, "##gonio_color", current_color, r.ImGui_ColorEditFlags_NoInputs())
    if ret_color then
        gonio_settings.color = ImGuiColorToHex(new_color)
        changed = true
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Spacing(ctx)

    if r.ImGui_Button(ctx, "Reset to Defaults##gonio", -1) then
        ResetGonioToDefaults()
        changed = false
    end

    if changed then
        SaveGonioSettings()
    end
end

function DrawFreqSettings()
    local changed = false

    local ret_grid, new_grid = r.ImGui_Checkbox(ctx, "Show Grid", freq_settings.show_grid)
    if ret_grid then
        freq_settings.show_grid = new_grid
        changed = true
    end

    local ret_fill, new_fill = r.ImGui_Checkbox(ctx, "Show Fill", freq_settings.show_fill)
    if ret_fill then
        freq_settings.show_fill = new_fill
        changed = true
    end

    local ret_peak, new_peak = r.ImGui_Checkbox(ctx, "Show Peak Hold", freq_settings.show_peak_hold)
    if ret_peak then
        freq_settings.show_peak_hold = new_peak
        changed = true
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Interpolation (Performance Impact)")
    local current_interp_idx = FindIndexInTable(interpolation_options, freq_settings.interpolation)
    r.ImGui_SetNextItemWidth(ctx, -1)
    if r.ImGui_BeginCombo(ctx, "##interpolation", interpolation_labels[current_interp_idx]) then
        for i, label in ipairs(interpolation_labels) do
            local is_selected = (current_interp_idx == i)
            if r.ImGui_Selectable(ctx, label, is_selected) then
                freq_settings.interpolation = interpolation_options[i]
                changed = true
            end
        end
        r.ImGui_EndCombo(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Octave Smoothing (High Performance Impact)")
    r.ImGui_SetNextItemWidth(ctx, -1)
    if r.ImGui_BeginCombo(ctx, "##octave_smoothing", octave_labels[freq_settings.octave_smoothing + 1]) then
        for i, label in ipairs(octave_labels) do
            local is_selected = (freq_settings.octave_smoothing == i - 1)
            if r.ImGui_Selectable(ctx, label, is_selected) then
                freq_settings.octave_smoothing = i - 1
                changed = true
            end
        end
        r.ImGui_EndCombo(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Fill Alpha")
    r.ImGui_SetNextItemWidth(ctx, -1)
    local ret_fill_alpha, new_fill_alpha = r.ImGui_SliderDouble(ctx, "##fill_alpha", freq_settings.fill_alpha, 0.1, 1.0, "%.2f")
    if ret_fill_alpha then
        freq_settings.fill_alpha = new_fill_alpha
        changed = true
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Color")
    local current_color = HexToImGuiColor(freq_settings.main_color)
    local ret_color, new_color = r.ImGui_ColorEdit3(ctx, "##freq_color", current_color, r.ImGui_ColorEditFlags_NoInputs())
    if ret_color then
        freq_settings.main_color = ImGuiColorToHex(new_color)
        changed = true
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Spacing(ctx)

    if r.ImGui_Button(ctx, "Reset to Defaults##freq", -1) then
        ResetFreqToDefaults()
        changed = false
    end

    if changed then
        SaveFreqSettings()
    end
end

function MainLoop()
    ApplyStyle()

    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())

    local visible, open = r.ImGui_Begin(ctx, 'Analyzer Settings', true, window_flags)
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Analyzer Settings")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Analyzer Settings")
        end

        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if style_loader and style_loader.PushFont(ctx, "main") then

            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)

            if r.ImGui_BeginTabBar(ctx, "AnalyzerTabs") then
                if r.ImGui_BeginTabItem(ctx, "Goniometer") then
                    r.ImGui_Spacing(ctx)
                    DrawGonioSettings()
                    r.ImGui_EndTabItem(ctx)
                end

                if r.ImGui_BeginTabItem(ctx, "Frequency Analyzer") then
                    r.ImGui_Spacing(ctx)
                    DrawFreqSettings()
                    r.ImGui_EndTabItem(ctx)
                end

                r.ImGui_EndTabBar(ctx)
            end

            style_loader.PopFont(ctx)
        else

            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)

            if r.ImGui_BeginTabBar(ctx, "AnalyzerTabs") then
                if r.ImGui_BeginTabItem(ctx, "Goniometer") then
                    r.ImGui_Spacing(ctx)
                    DrawGonioSettings()
                    r.ImGui_EndTabItem(ctx)
                end

                if r.ImGui_BeginTabItem(ctx, "Frequency Analyzer") then
                    r.ImGui_Spacing(ctx)
                    DrawFreqSettings()
                    r.ImGui_EndTabItem(ctx)
                end

                r.ImGui_EndTabBar(ctx)
            end

        end

        r.ImGui_End(ctx)
    end

    ClearStyle()

    if open then
        r.defer(MainLoop)
    end
end

function Start()
    LoadGonioSettings()
    LoadFreqSettings()
    MainLoop()
end

function Exit()
end

r.atexit(Exit)
Start()
