local r = reaper

local script_name = "CP_FrequencyAnalyzer_GFX"

r.gmem_attach("CP_FrequencyAnalyzer")

local config = {
    update_rate = 0.016,
    octave_smoothing = 0,
    interpolation_steps = 4,
    main_color = "#1ABC98",
    peak_color = "#1ABC98",
    fill_color = "#1ABC98",
    fill_alpha = 1,
    grid_alpha = 0.05,
    label_alpha = 0.1,
}

local state = {
    debug_mode = false,
    show_peak_hold = true,
    show_grid = true,
    show_fill = true,
    dock_state = 0,
    window_width = 800,
    window_height = 400,
    num_bins = 1024,
    spectrum_data = {},
    peak_data = {},
    last_update = 0,
    fft_size = 4096,
    sample_rate = 48000,
    x_cache = {},
    log_min = math.log(20),
    log_max = 0,
    raw_fft_size = nil,
    raw_sample_rate = nil,
    raw_num_bins = nil
}

local main_r, main_g, main_b
local peak_r, peak_g, peak_b
local fill_r, fill_g, fill_b

function HexToRGB(hex)
    hex = hex:gsub("#","")
    return tonumber("0x"..hex:sub(1,2))/255, 
           tonumber("0x"..hex:sub(3,4))/255, 
           tonumber("0x"..hex:sub(5,6))/255
end

function SaveState()
    r.SetExtState(script_name, "show_peak_hold", state.show_peak_hold and "1" or "0", true)
    r.SetExtState(script_name, "show_grid", state.show_grid and "1" or "0", true)
    r.SetExtState(script_name, "show_fill", state.show_fill and "1" or "0", true)
    r.SetExtState(script_name, "dock_state", tostring(state.dock_state), true)
    r.SetExtState(script_name, "window_width", tostring(state.window_width), true)
    r.SetExtState(script_name, "window_height", tostring(state.window_height), true)
end

function LoadState()
    if r.HasExtState(script_name, "show_peak_hold") then
        state.show_peak_hold = r.GetExtState(script_name, "show_peak_hold") == "1"
    end
    
    if r.HasExtState(script_name, "show_grid") then
        state.show_grid = r.GetExtState(script_name, "show_grid") == "1"
    end
    
    if r.HasExtState(script_name, "show_fill") then
        state.show_fill = r.GetExtState(script_name, "show_fill") == "1"
    end
    
    if r.HasExtState(script_name, "dock_state") then
        state.dock_state = tonumber(r.GetExtState(script_name, "dock_state")) or 0
    end
    
    if r.HasExtState(script_name, "window_width") then
        state.window_width = tonumber(r.GetExtState(script_name, "window_width")) or 800
    end
    
    if r.HasExtState(script_name, "window_height") then
        state.window_height = tonumber(r.GetExtState(script_name, "window_height")) or 400
    end
end

function ReadFFTData()
    local gmem_offset = 0
    
    local raw_fft_size = r.gmem_read(gmem_offset)
    local raw_sample_rate = r.gmem_read(gmem_offset + 1)
    local raw_num_bins = r.gmem_read(gmem_offset + 2)
    
    state.raw_fft_size = raw_fft_size
    state.raw_sample_rate = raw_sample_rate
    state.raw_num_bins = raw_num_bins
    
    state.fft_size = raw_fft_size or 4096
    local new_sample_rate = raw_sample_rate or 48000
    local new_num_bins = raw_num_bins or 1024
    
    if new_sample_rate ~= state.sample_rate then
        state.sample_rate = new_sample_rate
        state.log_max = math.log(state.sample_rate / 2)
        state.x_cache = {}
    end
    
    if new_num_bins ~= state.num_bins then
        state.num_bins = new_num_bins
        state.x_cache = {}
        
        state.spectrum_data = {}
        state.peak_data = {}
        
        for i = 1, state.num_bins do
            state.spectrum_data[i] = -96
            state.peak_data[i] = -96
        end
    end
    
    if #state.spectrum_data == 0 then
        for i = 1, state.num_bins do
            state.spectrum_data[i] = -96
            state.peak_data[i] = -96
        end
    end
    
    for i = 0, state.num_bins - 1 do
        local mag_db = r.gmem_read(gmem_offset + 3 + i) or -96
        local peak_db = r.gmem_read(gmem_offset + 3 + state.num_bins + i) or -96
        
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
    
    for i = 1, state.num_bins do
        local bin_index = i - 1
        local center_freq = (bin_index / state.num_bins) * (state.sample_rate / 2)
        
        if center_freq < 20 then center_freq = 20 end
        
        local bandwidth = center_freq * (2^(1/octave_fraction) - 2^(-1/octave_fraction))
        local freq_low = center_freq - bandwidth / 2
        local freq_high = center_freq + bandwidth / 2
        
        local sum_mag = 0
        local sum_peak = 0
        local count = 0
        
        for j = 1, state.num_bins do
            local j_bin_index = j - 1
            local j_freq = (j_bin_index / state.num_bins) * (state.sample_rate / 2)
            
            if j_freq >= freq_low and j_freq <= freq_high then
                local mag_val = state.spectrum_data[j]
                local peak_val = state.peak_data[j]
                
                if mag_val and peak_val then
                    sum_mag = sum_mag + mag_val
                    sum_peak = sum_peak + peak_val
                    count = count + 1
                end
            end
        end
        
        if count > 0 then
            smoothed_spectrum[i] = sum_mag / count
            smoothed_peaks[i] = sum_peak / count
        else
            smoothed_spectrum[i] = state.spectrum_data[i] or -96
            smoothed_peaks[i] = state.peak_data[i] or -96
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
    
    local freq = (bin_index / state.num_bins) * (state.sample_rate / 2)
    if freq < 20 then freq = 20 end
    
    local log_freq = math.log(freq)
    local norm = (log_freq - state.log_min) / (state.log_max - state.log_min)
    
    state.x_cache[bin_index] = norm
    return canvas_x + norm * canvas_width
end

function DBToY(db, canvas_y, canvas_height)
    local min_db = -96
    local max_db = 0
    
    if not db then db = -96 end
    if db < min_db then db = min_db end
    if db > max_db then db = max_db end
    
    local norm = (db - min_db) / (max_db - min_db)
    
    return canvas_y + canvas_height - (norm * canvas_height)
end

function CatmullRomInterpolate(t, p0, p1, p2, p3)
    local t2 = t * t
    local t3 = t2 * t
    
    return 0.5 * (
        (2 * p1) +
        (-p0 + p2) * t +
        (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
        (-p0 + 3 * p1 - 3 * p2 + p3) * t3
    )
end

function DrawDebugInfo()
    if not state.debug_mode then return end
    
    gfx.set(1, 1, 1, 0.8)
    gfx.setfont(1, "Arial", 14)
    
    local debug_x = 10
    local debug_y = 10
    local line_height = 18
    
    gfx.x = debug_x
    gfx.y = debug_y
    gfx.drawstr(string.format("FFT Size: %d", state.fft_size))
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height
    gfx.drawstr(string.format("Sample Rate: %.0f Hz", state.sample_rate))
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height * 2
    gfx.drawstr(string.format("Num Bins: %d", state.num_bins))
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height * 3
    local raw_fft = state.raw_fft_size and string.format("%.1f", state.raw_fft_size) or "NIL"
    gfx.drawstr(string.format("RAW gmem[0] (FFT): %s", raw_fft))
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height * 4
    local raw_bins = state.raw_num_bins and string.format("%.1f", state.raw_num_bins) or "NIL"
    gfx.drawstr(string.format("RAW gmem[2] (Bins): %s", raw_bins))
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height * 5
    gfx.drawstr(string.format("Spectrum Data Length: %d", #state.spectrum_data))
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height * 6
    gfx.drawstr(string.format("Peak Data Length: %d", #state.peak_data))
    
    if gfx.mouse_x > 0 and gfx.mouse_x < gfx.w then
        local norm_x = gfx.mouse_x / gfx.w
        local log_freq = state.log_min + norm_x * (state.log_max - state.log_min)
        local freq = math.exp(log_freq)
        
        gfx.x = debug_x
        gfx.y = debug_y + line_height * 7
        gfx.drawstr(string.format("Mouse Freq: %.1f Hz", freq))
        
        local bin = (freq / (state.sample_rate / 2)) * state.num_bins
        gfx.x = debug_x
        gfx.y = debug_y + line_height * 8
        gfx.drawstr(string.format("Mouse Bin: %.1f / %d", bin, state.num_bins))
    end
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height * 9
    gfx.drawstr(string.format("Bin[1] (0Hz): %.1f dB", state.spectrum_data[1] or -999))
    
    gfx.x = debug_x
    gfx.y = debug_y + line_height * 10
    gfx.drawstr(string.format("Bin[%d] (Nyquist): %.1f dB", state.num_bins, state.spectrum_data[state.num_bins] or -999))
end

function DrawGrid(canvas_x, canvas_y, canvas_width, canvas_height)
    if not state.show_grid then return end
    
    local db_lines = {
        {db = 0, is_main = true},
        {db = -6, is_main = false},
        {db = -12, is_main = true},
        {db = -18, is_main = false},
        {db = -24, is_main = true},
        {db = -36, is_main = false},
        {db = -48, is_main = true},
        {db = -60, is_main = false},
        {db = -72, is_main = false},
        {db = -96, is_main = false}
    }
    
    for _, line_info in ipairs(db_lines) do
        local alpha = line_info.is_main and config.grid_alpha * 1.5 or config.grid_alpha * 0.5
        gfx.set(1, 1, 1, alpha)
        
        local y = DBToY(line_info.db, canvas_y, canvas_height)
        gfx.line(canvas_x, y, canvas_x + canvas_width, y)
        
        if line_info.is_main then
            gfx.set(1, 1, 1, config.label_alpha)
            gfx.x = canvas_x + 5
            gfx.y = y + 2
            gfx.drawstr(line_info.db .. " dB")
        end
    end
    
    local freq_lines = {
        {freq = 20, label = "20", is_main = false},
        {freq = 50, label = "", is_main = false},
        {freq = 100, label = "100", is_main = true},
        {freq = 200, label = "", is_main = false},
        {freq = 500, label = "", is_main = false},
        {freq = 1000, label = "1k", is_main = true},
        {freq = 2000, label = "", is_main = false},
        {freq = 5000, label = "", is_main = false},
        {freq = 10000, label = "10k", is_main = true},
        {freq = 20000, label = "20k", is_main = false}
    }
    
    for _, line_info in ipairs(freq_lines) do
        if line_info.freq < state.sample_rate / 2 then
            local alpha = line_info.is_main and config.grid_alpha * 1.5 or config.grid_alpha * 0.5
            gfx.set(1, 1, 1, alpha)
            
            local bin_index = (line_info.freq / (state.sample_rate / 2)) * state.num_bins
            local x = FreqToX(bin_index, canvas_x, canvas_width)
            gfx.line(x, canvas_y, x, canvas_y + canvas_height)
            
            if line_info.label ~= "" then
                gfx.set(1, 1, 1, config.label_alpha)
                gfx.x = x + 3
                gfx.y = canvas_y + canvas_height - 15
                gfx.drawstr(line_info.label)
            end
        end
    end
end

function DrawSpectrum()
    local canvas_width = gfx.w
    local canvas_height = gfx.h
    
    local canvas_x = 0
    local canvas_y = 0
    
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, canvas_width, canvas_height, 1)
    
    DrawGrid(canvas_x, canvas_y, canvas_width, canvas_height)
    
    local num_points = state.num_bins
    
    if num_points < 2 then
        return
    end
    
    if state.show_fill then
        local bottom_y = canvas_y + canvas_height
        
        if config.interpolation_steps == 0 then
            for i = 1, num_points - 1 do
                local bin1 = i - 1
                local bin2 = i
                
                local x1 = FreqToX(bin1, canvas_x, canvas_width)
                local y1 = DBToY(state.spectrum_data[i], canvas_y, canvas_height)
                local x2 = FreqToX(bin2, canvas_x, canvas_width)
                local y2 = DBToY(state.spectrum_data[i + 1], canvas_y, canvas_height)
                
                gfx.set(fill_r, fill_g, fill_b, config.fill_alpha)
                gfx.triangle(x1, y1, x2, y2, x1, bottom_y, 1)
                gfx.triangle(x2, y2, x2, bottom_y, x1, bottom_y, 1)
            end
        else
            for i = 1, num_points - 1 do
                local db0 = state.spectrum_data[math.max(1, i - 1)] or -96
                local db1 = state.spectrum_data[i] or -96
                local db2 = state.spectrum_data[i + 1] or -96
                local db3 = state.spectrum_data[math.min(num_points, i + 2)] or -96
                
                local bin1 = i - 1
                local bin2 = i
                
                local x1 = FreqToX(bin1, canvas_x, canvas_width)
                local x2 = FreqToX(bin2, canvas_x, canvas_width)
                
                local prev_x, prev_y
                
                for step = 0, config.interpolation_steps do
                    local t = step / config.interpolation_steps
                    
                    local x = x1 + (x2 - x1) * t
                    local db_interp = CatmullRomInterpolate(t, db0, db1, db2, db3)
                    local y = DBToY(db_interp, canvas_y, canvas_height)
                    
                    if step > 0 then
                        gfx.set(fill_r, fill_g, fill_b, config.fill_alpha)
                        gfx.triangle(prev_x, prev_y, x, y, prev_x, bottom_y, 1)
                        gfx.triangle(x, y, x, bottom_y, prev_x, bottom_y, 1)
                    end
                    
                    prev_x = x
                    prev_y = y
                end
            end
        end
    end
    
    gfx.set(main_r, main_g, main_b, 1.0)
    
    if config.interpolation_steps == 0 then
        for i = 1, num_points - 1 do
            local bin1 = i - 1
            local bin2 = i
            
            local x1 = FreqToX(bin1, canvas_x, canvas_width)
            local y1 = DBToY(state.spectrum_data[i], canvas_y, canvas_height)
            local x2 = FreqToX(bin2, canvas_x, canvas_width)
            local y2 = DBToY(state.spectrum_data[i + 1], canvas_y, canvas_height)
            
            gfx.line(x1, y1, x2, y2)
        end
    else
        for i = 1, num_points - 1 do
            local db0 = state.spectrum_data[math.max(1, i - 1)] or -96
            local db1 = state.spectrum_data[i] or -96
            local db2 = state.spectrum_data[i + 1] or -96
            local db3 = state.spectrum_data[math.min(num_points, i + 2)] or -96
            
            local bin1 = i - 1
            local bin2 = i
            
            local x1 = FreqToX(bin1, canvas_x, canvas_width)
            local x2 = FreqToX(bin2, canvas_x, canvas_width)
            
            local prev_x, prev_y
            
            for step = 0, config.interpolation_steps do
                local t = step / config.interpolation_steps
                
                local x = x1 + (x2 - x1) * t
                local db_interp = CatmullRomInterpolate(t, db0, db1, db2, db3)
                local y = DBToY(db_interp, canvas_y, canvas_height)
                
                if step > 0 then
                    gfx.line(prev_x, prev_y, x, y)
                end
                
                prev_x = x
                prev_y = y
            end
        end
    end
    
    if state.show_peak_hold then
        gfx.set(peak_r, peak_g, peak_b, 1.0)
        
        if config.interpolation_steps == 0 then
            for i = 1, num_points - 1 do
                local bin1 = i - 1
                local bin2 = i
                
                local x1 = FreqToX(bin1, canvas_x, canvas_width)
                local y1 = DBToY(state.peak_data[i], canvas_y, canvas_height)
                local x2 = FreqToX(bin2, canvas_x, canvas_width)
                local y2 = DBToY(state.peak_data[i + 1], canvas_y, canvas_height)
                
                gfx.line(x1, y1, x2, y2)
            end
        else
            for i = 1, num_points - 1 do
                local db0 = state.peak_data[math.max(1, i - 1)] or -96
                local db1 = state.peak_data[i] or -96
                local db2 = state.peak_data[i + 1] or -96
                local db3 = state.peak_data[math.min(num_points, i + 2)] or -96
                
                local bin1 = i - 1
                local bin2 = i
                
                local x1 = FreqToX(bin1, canvas_x, canvas_width)
                local x2 = FreqToX(bin2, canvas_x, canvas_width)
                
                local prev_x, prev_y
                
                for step = 0, config.interpolation_steps do
                    local t = step / config.interpolation_steps
                    
                    local x = x1 + (x2 - x1) * t
                    local db_interp = CatmullRomInterpolate(t, db0, db1, db2, db3)
                    local y = DBToY(db_interp, canvas_y, canvas_height)
                    
                    if step > 0 then
                        gfx.line(prev_x, prev_y, x, y)
                    end
                    
                    prev_x = x
                    prev_y = y
                end
            end
        end
    end
    
    DrawDebugInfo()
end

function MainLoop()
    local char = gfx.getchar()
    
    if char == -1 then
        return
    end
    
    if char == 112 then
        state.show_peak_hold = not state.show_peak_hold
    end
    
    if char == 103 then
        state.show_grid = not state.show_grid
    end
    
    if char == 102 then
        state.show_fill = not state.show_fill
    end
    
    if char == 100 then
        state.debug_mode = not state.debug_mode
    end
    
    local current_time = r.time_precise()
    
    if current_time - state.last_update >= config.update_rate then
        ReadFFTData()
        state.last_update = current_time
    end
    
    DrawSpectrum()
    gfx.update()
    
    r.defer(MainLoop)
end

function Init()
    LoadState()
    
    state.log_max = math.log(state.sample_rate / 2)
    
    main_r, main_g, main_b = HexToRGB(config.main_color)
    peak_r, peak_g, peak_b = HexToRGB(config.peak_color)
    fill_r, fill_g, fill_b = HexToRGB(config.fill_color)
    
    gfx.init("CP Frequency Analyzer", state.window_width, state.window_height, 0)
    
    if state.dock_state > 0 then
        gfx.dock(state.dock_state)
    end
    
    state.last_update = r.time_precise()
end

function Exit()
    state.dock_state = gfx.dock(-1)
    state.window_width = gfx.w
    state.window_height = gfx.h
    SaveState()
end

r.atexit(Exit)
Init()
MainLoop()