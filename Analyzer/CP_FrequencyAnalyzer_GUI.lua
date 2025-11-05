local r = reaper

local script_name = "CP_FrequencyAnalyzer_GUI"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('CP Frequency Analyzer')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

r.gmem_attach("CP_FrequencyAnalyzer")

local config = {
    update_rate = 0.033,
    num_bins = 256,
    color_r = 0x00,
    color_g = 0xCC,
    color_b = 0xCC,
    peak_color_r = 0x33,
    peak_color_g = 0xCC,
    peak_color_b = 0xCC,
    fill_color_r = 0x33,
    fill_color_g = 0xCC,
    fill_color_b = 0xCC,
    line_thickness = 1.0,
    peak_line_thickness = 1.0,
    show_peak_hold = false,
    show_grid = false,
    show_fill = true,
    smooth_fill = false,
    octave_smoothing = 2
}

local state = {
    spectrum_data = {},
    peak_data = {},
    last_update = 0,
    fft_size = 4096,
    sample_rate = 48000,
    x_cache = {},
    log_min = math.log(20),
    log_max = 0,
    freq_bin_ratio = 0
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

function SaveSettings()
    for key, value in pairs(config) do
        local value_str = tostring(value)
        if type(value) == "boolean" then
            value_str = value and "1" or "0"
        end
        r.SetExtState(script_name, "config_" .. key, value_str, true)
    end
end

function LoadSettings()
    for key, default_value in pairs(config) do
        local saved_value = r.GetExtState(script_name, "config_" .. key)
        if saved_value ~= "" then
            if type(default_value) == "number" then
                config[key] = tonumber(saved_value) or default_value
            elseif type(default_value) == "boolean" then
                config[key] = saved_value == "1"
            else
                config[key] = saved_value
            end
        end
    end
end

function ReadFFTData()
    local gmem_offset = 0
    
    state.fft_size = r.gmem_read(gmem_offset) or 4096
    local new_sample_rate = r.gmem_read(gmem_offset + 1) or 48000
    
    if new_sample_rate ~= state.sample_rate then
        state.sample_rate = new_sample_rate
        state.log_max = math.log(state.sample_rate / 2)
        state.freq_bin_ratio = (state.sample_rate / 2) / config.num_bins
        state.x_cache = {}
    end
    
    if #state.spectrum_data == 0 then
        for i = 1, config.num_bins do
            state.spectrum_data[i] = -96
            state.peak_data[i] = -96
        end
    end
    
    for i = 0, config.num_bins - 1 do
        local mag_db = r.gmem_read(gmem_offset + 3 + i) or -96
        local peak_db = r.gmem_read(gmem_offset + 3 + config.num_bins + i) or -96
        
        state.spectrum_data[i + 1] = mag_db
        state.peak_data[i + 1] = peak_db
    end
    
    if config.octave_smoothing > 0 then
        ApplyOctaveSmoothing()
    end
end

function ApplyOctaveSmoothing()
    local smoothing_factors = {0, 24, 12, 6, 3}
    local octave_fraction = smoothing_factors[config.octave_smoothing + 1]
    
    if octave_fraction == 0 then return end
    
    local smoothed_spectrum = {}
    local smoothed_peaks = {}
    
    for i = 1, #state.spectrum_data do
        local bin_index = i - 1
        local center_freq = (bin_index / config.num_bins) * (state.sample_rate / 2)
        
        if center_freq < 20 then center_freq = 20 end
        
        local bandwidth = center_freq * (2^(1/octave_fraction) - 2^(-1/octave_fraction))
        local freq_low = center_freq - bandwidth / 2
        local freq_high = center_freq + bandwidth / 2
        
        local sum_mag = 0
        local sum_peak = 0
        local count = 0
        
        for j = 1, #state.spectrum_data do
            local j_bin_index = j - 1
            local j_freq = (j_bin_index / config.num_bins) * (state.sample_rate / 2)
            
            if j_freq >= freq_low and j_freq <= freq_high then
                sum_mag = sum_mag + state.spectrum_data[j]
                sum_peak = sum_peak + state.peak_data[j]
                count = count + 1
            end
        end
        
        if count > 0 then
            smoothed_spectrum[i] = sum_mag / count
            smoothed_peaks[i] = sum_peak / count
        else
            smoothed_spectrum[i] = state.spectrum_data[i]
            smoothed_peaks[i] = state.peak_data[i]
        end
    end
    
    state.spectrum_data = smoothed_spectrum
    state.peak_data = smoothed_peaks
end

function FreqToX(bin_index, canvas_x, canvas_width)
    local cached = state.x_cache[bin_index]
    if cached then
        return canvas_x + cached * canvas_width
    end
    
    local freq = (bin_index / config.num_bins) * (state.sample_rate / 2)
    if freq < 20 then freq = 20 end
    
    local log_freq = math.log(freq)
    local norm = (log_freq - state.log_min) / (state.log_max - state.log_min)
    
    state.x_cache[bin_index] = norm
    return canvas_x + norm * canvas_width
end

function DBToY(db, canvas_y, canvas_height)
    local min_db = -96
    local max_db = 0
    
    if db < min_db then db = min_db end
    if db > max_db then db = max_db end
    
    local norm = (db - min_db) / (max_db - min_db)
    
    return canvas_y + canvas_height - (norm * canvas_height)
end

function DrawGrid(draw_list, canvas_x, canvas_y, canvas_width, canvas_height)
    if not config.show_grid then return end
    
    local grid_color = 0x30CCCC10
    
    local db_lines = {0, -12, -24, -48, -72, -96}
    for _, db in ipairs(db_lines) do
        local y = DBToY(db, canvas_y, canvas_height)
        r.ImGui_DrawList_AddLine(draw_list, canvas_x, y, canvas_x + canvas_width, y, grid_color, 1)
    end
    
    local freq_lines = {100, 200, 500, 1000, 2000, 5000, 10000, 20000}
    for _, freq in ipairs(freq_lines) do
        if freq < state.sample_rate / 2 then
            local x = FreqToX(freq, canvas_x, canvas_width)
            r.ImGui_DrawList_AddLine(draw_list, x, canvas_y, x, canvas_y + canvas_height, grid_color, 1)
        end
    end
end

function DrawSpectrum()
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    
    local window_width, window_height = r.ImGui_GetWindowSize(ctx)
    local canvas_width = window_width
    local canvas_height = window_height
    
    local canvas_pos_x, canvas_pos_y = r.ImGui_GetCursorScreenPos(ctx)
    
    local plot_x = canvas_pos_x
    local plot_y = canvas_pos_y
    local plot_width = canvas_width
    local plot_height = canvas_height
    
    local bg_color = 0xFF000000
    r.ImGui_DrawList_AddRectFilled(draw_list, canvas_pos_x, canvas_pos_y, 
        canvas_pos_x + canvas_width, canvas_pos_y + canvas_height, bg_color)
    
    DrawGrid(draw_list, plot_x, plot_y, plot_width, plot_height)
    
    local bottom_y = plot_y + plot_height
    local num_points = #state.spectrum_data
    
    if num_points < 2 then
        r.ImGui_Dummy(ctx, canvas_width, canvas_height)
        return
    end
    
    if config.show_fill then
        local fill_alpha = 0x30
        local fill_color = (fill_alpha << 24) | (config.fill_color_b << 16) | (config.fill_color_g << 8) | config.fill_color_r
        
        r.ImGui_DrawList_PathClear(draw_list)
        
        for i = 1, num_points do
            local bin_index = i - 1
            local x = FreqToX(bin_index, plot_x, plot_width)
            local y = DBToY(state.spectrum_data[i], plot_y, plot_height)
            r.ImGui_DrawList_PathLineTo(draw_list, x, y)
        end
        
        r.ImGui_DrawList_PathLineTo(draw_list, FreqToX(num_points - 1, plot_x, plot_width), bottom_y)
        r.ImGui_DrawList_PathLineTo(draw_list, FreqToX(0, plot_x, plot_width), bottom_y)
        r.ImGui_DrawList_PathFillConvex(draw_list, fill_color)
    end
    
    local line_color = 0xFFCCCC00
    r.ImGui_DrawList_PathClear(draw_list)
    
    for i = 1, num_points do
        local bin_index = i - 1
        local x = FreqToX(bin_index, plot_x, plot_width)
        local y = DBToY(state.spectrum_data[i], plot_y, plot_height)
        r.ImGui_DrawList_PathLineTo(draw_list, x, y)
    end
    
    r.ImGui_DrawList_PathStroke(draw_list, line_color, 0, config.line_thickness)
    
    if config.show_peak_hold then
        local peak_alpha = 0xFF
        local peak_color = (peak_alpha << 24) | (config.fill_color_b << 16) | (config.fill_color_g << 8) | config.fill_color_r
        
        r.ImGui_DrawList_PathClear(draw_list)
        
        for i = 1, num_points do
            if state.peak_data[i] > -90 then
                local bin_index = i - 1
                local x = FreqToX(bin_index, plot_x, plot_width)
                local y = DBToY(state.peak_data[i], plot_y, plot_height)
                r.ImGui_DrawList_PathLineTo(draw_list, x, y)
            end
        end
        
        r.ImGui_DrawList_PathStroke(draw_list, peak_color, 0, config.peak_line_thickness)
    end
    
    r.ImGui_Dummy(ctx, canvas_width, canvas_height)
end

function MainLoop()
    -- ApplyStyle()
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | 
                        r.ImGui_WindowFlags_NoCollapse() |
                        r.ImGui_WindowFlags_NoScrollbar()
    r.ImGui_SetNextWindowSize(ctx, 800, 400, r.ImGui_Cond_FirstUseEver())
    
    local visible, open = r.ImGui_Begin(ctx, 'CP Frequency Analyzer', true, window_flags)
    if visible then
        if style_loader and style_loader.PushFont(ctx, "main") then
            local current_time = r.time_precise()
            if current_time - state.last_update >= config.update_rate then
                ReadFFTData()
                state.last_update = current_time
            end
            
            DrawSpectrum()
            
            style_loader.PopFont(ctx)
        else
            local current_time = r.time_precise()
            if current_time - state.last_update >= config.update_rate then
                ReadFFTData()
                state.last_update = current_time
            end
            
            DrawSpectrum()
        end
        
        r.ImGui_End(ctx)
    end
    
    ClearStyle()
    
    r.PreventUIRefresh(-1)
    
    if open then
        r.defer(MainLoop)
    else
        SaveSettings()
        Cleanup()
    end
end

function ToggleScript()
    local _, _, section_id, command_id = r.get_action_context()
    local script_state = r.GetToggleCommandState(command_id)
    
    if script_state == -1 or script_state == 0 then
        r.SetToggleCommandState(section_id, command_id, 1)
        r.RefreshToolbar2(section_id, command_id)
        Start()
    else
        r.SetToggleCommandState(section_id, command_id, 0)
        r.RefreshToolbar2(section_id, command_id)
        Stop()
    end
end

function Start()
    state.log_max = math.log(state.sample_rate / 2)
    state.freq_bin_ratio = (state.sample_rate / 2) / config.num_bins
    MainLoop()
end

function Stop()
    SaveSettings()
    Cleanup()
end

function Cleanup()
    local _, _, section_id, command_id = r.get_action_context()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end

function Exit()
    SaveSettings()
    Cleanup()
end

r.atexit(Exit)
ToggleScript()
