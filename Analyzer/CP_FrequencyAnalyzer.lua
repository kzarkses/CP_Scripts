local r = reaper

local script_name = "CP_FrequencyAnalyzer_GFX"

r.gmem_attach("CP_FrequencyAnalyzer")

local config = {
    update_rate = 0.016,
    octave_smoothing = 0,
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
    log_min = math.log(20),
    log_max = 0,
    raw_fft_size = nil,
    raw_sample_rate = nil,
    raw_num_bins = nil,
    pixel_bins = nil,
    pixel_cache_w = 0,
    pixel_cache_sr = 0,
    pixel_cache_nb = 0,
    col_spec = {},
    col_peak = {}
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

function RebuildPixelMap(width)
    if width <= 0 then return end
    if state.pixel_cache_w == width
        and state.pixel_cache_sr == state.sample_rate
        and state.pixel_cache_nb == state.num_bins
        and state.pixel_bins then
        return
    end

    local pixel_bins = {}
    local log_min = state.log_min
    local log_range = state.log_max - state.log_min
    local nyquist = state.sample_rate / 2
    local num_bins = state.num_bins
    local inv_width = 1 / width
    local bins_per_hz = num_bins / nyquist

    for px = 0, width - 1 do
        local norm_center = (px + 0.5) * inv_width
        local freq_c = math.exp(log_min + norm_center * log_range)
        local bin_f = freq_c * bins_per_hz

        local norm_a = px * inv_width
        local norm_b = (px + 1) * inv_width
        local freq_a = math.exp(log_min + norm_a * log_range)
        local freq_b = math.exp(log_min + norm_b * log_range)
        local bin_a = math.floor(freq_a * bins_per_hz)
        local bin_b = math.floor(freq_b * bins_per_hz)
        if bin_a < 0 then bin_a = 0 end
        if bin_b >= num_bins then bin_b = num_bins - 1 end

        if bin_b - bin_a >= 1 then
            -- multiple bins per pixel: max
            pixel_bins[px + 1] = {mode = 0, a = bin_a, b = bin_b}
        else
            -- less than 1 bin per pixel: lerp between neighbors
            local i0 = math.floor(bin_f)
            if i0 < 0 then i0 = 0 end
            if i0 > num_bins - 2 then i0 = num_bins - 2 end
            local t = bin_f - i0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            pixel_bins[px + 1] = {mode = 1, i0 = i0, t = t}
        end
    end

    state.pixel_bins = pixel_bins
    state.pixel_cache_w = width
    state.pixel_cache_sr = state.sample_rate
    state.pixel_cache_nb = state.num_bins
    state.col_spec = {}
    state.col_peak = {}
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
        state.pixel_bins = nil
    end

    if new_num_bins ~= state.num_bins then
        state.num_bins = new_num_bins
        state.pixel_bins = nil
    end

    local width = gfx.w
    if width > 0 then
        RebuildPixelMap(width)
    end

    local pixel_bins = state.pixel_bins
    if not pixel_bins then return end

    local col_spec = state.col_spec
    local col_peak = state.col_peak
    local peak_base = gmem_offset + 3 + state.num_bins
    local spec_base = gmem_offset + 3
    local show_peak = state.show_peak_hold

    for px = 1, #pixel_bins do
        local pb = pixel_bins[px]
        if pb.mode == 0 then
            local bin_a, bin_b = pb.a, pb.b
            local max_s = -200
            local sum_s = 0
            local max_p = -200
            local sum_p = 0
            local cnt = 0
            for b = bin_a, bin_b do
                local s = r.gmem_read(spec_base + b) or -96
                if s > max_s then max_s = s end
                sum_s = sum_s + s
                if show_peak then
                    local p = r.gmem_read(peak_base + b) or -96
                    if p > max_p then max_p = p end
                    sum_p = sum_p + p
                end
                cnt = cnt + 1
            end
            col_spec[px] = max_s * 0.5 + (sum_s / cnt) * 0.5
            if show_peak then col_peak[px] = max_p * 0.5 + (sum_p / cnt) * 0.5 end
        else
            local i0, t = pb.i0, pb.t
            local im1 = i0 - 1; if im1 < 0 then im1 = 0 end
            local i2 = i0 + 2; if i2 >= state.num_bins then i2 = state.num_bins - 1 end
            local sm1 = r.gmem_read(spec_base + im1) or -96
            local s0 = r.gmem_read(spec_base + i0) or -96
            local s1 = r.gmem_read(spec_base + i0 + 1) or -96
            local s2 = r.gmem_read(spec_base + i2) or -96
            local t2 = t * t
            local t3 = t2 * t
            col_spec[px] = 0.5 * ((2 * s0) + (-sm1 + s1) * t + (2 * sm1 - 5 * s0 + 4 * s1 - s2) * t2 + (-sm1 + 3 * s0 - 3 * s1 + s2) * t3)
            if show_peak then
                local pm1 = r.gmem_read(peak_base + im1) or -96
                local p0 = r.gmem_read(peak_base + i0) or -96
                local p1 = r.gmem_read(peak_base + i0 + 1) or -96
                local p2 = r.gmem_read(peak_base + i2) or -96
                col_peak[px] = 0.5 * ((2 * p0) + (-pm1 + p1) * t + (2 * pm1 - 5 * p0 + 4 * p1 - p2) * t2 + (-pm1 + 3 * p0 - 3 * p1 + p2) * t3)
            end
        end
    end

    for i = #col_spec, #pixel_bins + 1, -1 do
        col_spec[i] = nil
        col_peak[i] = nil
    end

    -- 5-tap gaussian smoothing (kernel 1/4/6/4/1 / 16)
    local n = #col_spec
    if n >= 5 then
        local tmp = {}
        for i = 1, n do tmp[i] = col_spec[i] end
        for i = 3, n - 2 do
            col_spec[i] = (tmp[i-2] + tmp[i-1] * 4 + tmp[i] * 6 + tmp[i+1] * 4 + tmp[i+2]) * 0.0625
        end
        if show_peak then
            for i = 1, n do tmp[i] = col_peak[i] end
            for i = 3, n - 2 do
                col_peak[i] = (tmp[i-2] + tmp[i-1] * 4 + tmp[i] * 6 + tmp[i+1] * 4 + tmp[i+2]) * 0.0625
            end
        end
    end
end

function DBToY(db, canvas_y, canvas_height)
    if not db or db < -96 then db = -96 end
    if db > 0 then db = 0 end
    local norm = (db + 96) * 0.010416666666666666
    return canvas_y + canvas_height - (norm * canvas_height)
end

function FreqToXLog(freq, canvas_x, canvas_width)
    if freq < 20 then freq = 20 end
    local norm = (math.log(freq) - state.log_min) / (state.log_max - state.log_min)
    return canvas_x + norm * canvas_width
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

            local x = FreqToXLog(line_info.freq, canvas_x, canvas_width)
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

    local col_spec = state.col_spec
    local n = #col_spec
    if n < 2 then return end

    local bottom_y = canvas_y + canvas_height

    if state.show_fill then
        gfx.set(fill_r, fill_g, fill_b, config.fill_alpha)
        local prev_y = DBToY(col_spec[1], canvas_y, canvas_height)
        for px = 2, n do
            local y = DBToY(col_spec[px], canvas_y, canvas_height)
            local x1 = canvas_x + (px - 2)
            local x2 = canvas_x + (px - 1)
            gfx.triangle(x1, prev_y, x2, y, x2, bottom_y, x1, bottom_y)
            prev_y = y
        end
    end

    gfx.set(main_r, main_g, main_b, 1.0)
    local prev_y = DBToY(col_spec[1], canvas_y, canvas_height)
    for px = 2, n do
        local y = DBToY(col_spec[px], canvas_y, canvas_height)
        gfx.line(canvas_x + (px - 2), prev_y, canvas_x + (px - 1), y)
        prev_y = y
    end

    if state.show_peak_hold then
        local col_peak = state.col_peak
        if #col_peak >= 2 then
            gfx.set(peak_r, peak_g, peak_b, 1.0)
            local prev_py = DBToY(col_peak[1], canvas_y, canvas_height)
            for px = 2, n do
                local y = DBToY(col_peak[px], canvas_y, canvas_height)
                gfx.line(canvas_x + (px - 2), prev_py, canvas_x + (px - 1), y)
                prev_py = y
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