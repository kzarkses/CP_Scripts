-- @description SoundGenerator
-- @version 1.1
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_SoundGenerator"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('Sound Generator')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

local config = {
    tone_frequency = 440,
    tone_waveform = "sine",
    tone_amplitude_db = -6,
    noise_type = "white",
    noise_amplitude_db = -6,
    auto_close = false,
    window_width = 310,
    window_height = 310
}

local state = {
    window_open = true,
    noise = {
        pink = { b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0 },
        brown = { last = 0 }
    }
}

local defaults = {
    tone_frequency = 440,
    tone_amplitude_db = -6,
    noise_amplitude_db = -6
}

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

function GetFont(font_name)
    if style_loader then
        return style_loader.GetFont(ctx, font_name)
    end
    return nil
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

function DbToAmplitude(db)
    return 10 ^ (db / 20)
end

function AmplitudeToDb(amplitude)
    return 20 * math.log10(math.max(amplitude, 0.000001))
end

function GenerateWhiteNoise()
    return (math.random() * 2 - 1)
end

function GeneratePinkNoise()
    local white = GenerateWhiteNoise()
    state.noise.pink.b0 = 0.99886 * state.noise.pink.b0 + white * 0.0555179
    state.noise.pink.b1 = 0.99332 * state.noise.pink.b1 + white * 0.0750759
    state.noise.pink.b2 = 0.96900 * state.noise.pink.b2 + white * 0.1538520
    state.noise.pink.b3 = 0.86650 * state.noise.pink.b3 + white * 0.3104856
    state.noise.pink.b4 = 0.55000 * state.noise.pink.b4 + white * 0.5329522
    state.noise.pink.b5 = -0.7616 * state.noise.pink.b5 - white * 0.0168980
    local pink = state.noise.pink.b0 + state.noise.pink.b1 + state.noise.pink.b2 + state.noise.pink.b3 + state.noise.pink.b4 + state.noise.pink.b5 + state.noise.pink.b6 + white * 0.5362
    state.noise.pink.b6 = white * 0.115926
    return pink * 0.11
end

function GenerateBrownNoise()
    local white = GenerateWhiteNoise()
    state.noise.brown.last = (state.noise.brown.last + (0.02 * white)) / 1.02
    return state.noise.brown.last * 3.5
end

function GenerateTone(buffer_size, sample_rate)
    local samples = {}
    local phase = 0
    local phase_inc = 2 * math.pi * config.tone_frequency / sample_rate
    local amplitude = DbToAmplitude(config.tone_amplitude_db)
    
    for i = 1, buffer_size do
        local sample = 0
        
        if config.tone_waveform == "sine" then
            sample = math.sin(phase)
        elseif config.tone_waveform == "square" then
            sample = phase < math.pi and 1 or -1
        elseif config.tone_waveform == "triangle" then
            sample = 1 - 2 * math.abs((phase / math.pi) % 2 - 1)
        elseif config.tone_waveform == "sawtooth" then
            sample = 1 - (phase / math.pi % 2)
        end
        
        samples[i] = sample * amplitude
        phase = (phase + phase_inc) % (2 * math.pi)
    end
    
    return samples
end

function GenerateNoise(buffer_size, sample_rate)
    local samples = {}
    local amplitude = DbToAmplitude(config.noise_amplitude_db)
    
    for i = 1, buffer_size do
        local sample = 0
        
        if config.noise_type == "white" then
            sample = GenerateWhiteNoise()
        elseif config.noise_type == "pink" then
            sample = GeneratePinkNoise()
        elseif config.noise_type == "brown" then
            sample = GenerateBrownNoise()
        end
        
        samples[i] = sample * amplitude
    end
    
    return samples
end

function CreateAudioFile(generator_func)
    local start_time, end_time = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if start_time == end_time then return end

    local temp_path = r.GetProjectPath("") 
    if temp_path == "" then temp_path = os.getenv("TEMP") or "/tmp" end
    local filepath = temp_path .. "/tone_" .. os.time() .. ".wav"
    
    local sample_rate = 44100
    local success, rate = pcall(function() return r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false) end)
    if success and rate > 0 then
        sample_rate = rate
    end
    local duration = end_time - start_time
    local buffer_size = math.floor(duration * sample_rate)
    local samples = generator_func(buffer_size, sample_rate)
    
    local file = io.open(filepath, "wb")
    if file then
        file:write("RIFF")
        file:write(string.pack("<I4", 36 + buffer_size * 2))
        file:write("WAVEfmt ")
        file:write(string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16))
        file:write("data")
        file:write(string.pack("<I4", buffer_size * 2))
        
        for _, sample in ipairs(samples) do
            file:write(string.pack("<h", math.floor(sample * 32767)))
        end
        file:close()
        
        local track = r.GetSelectedTrack(0, 0) or r.GetLastTouchedTrack()
        if track then
            local item = r.AddMediaItemToTrack(track)
            r.SetMediaItemPosition(item, start_time, false)
            r.SetMediaItemLength(item, duration, false)
            local take = r.AddTakeToMediaItem(item)
            local source = r.PCM_Source_CreateFromFile(filepath)
            r.SetMediaItemTake_Source(take, source)
            r.UpdateItemInProject(item)
            r.SetMediaItemSelected(item, true)
            r.UpdateArrange()
            r.Main_OnCommand(40441, 0)
            os.remove(filepath)
            if config.auto_close then
                state.window_open = false
            end
        end
    end
end

function MainLoop()
    ApplyStyle()
    
    local header_font = GetFont("header")
    local main_font = GetFont("main")
    
    r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Sound Generator', true, window_flags)
    
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Sound Generator")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Sound Generator")
        end
        
        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 8)
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local auto_button_size = header_font_size + 6
        local close_button_size = header_font_size + 6
        local buttons_width = auto_button_size + close_button_size + item_spacing_x
        local auto_x = r.ImGui_GetWindowWidth(ctx) - buttons_width - window_padding_x
        
        r.ImGui_SetCursorPosX(ctx, auto_x)
        local was_auto_close = config.auto_close
        if config.auto_close then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_ButtonActive()))
        end
        if r.ImGui_Button(ctx, "A", auto_button_size, auto_button_size) then
            config.auto_close = not config.auto_close
        end
        if was_auto_close then
            r.ImGui_PopStyleColor(ctx)
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Auto-close after generate")
        end
        
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end
        
        if style_loader and style_loader.PushFont(ctx, "main") then
        
        r.ImGui_Separator(ctx)
        
        r.ImGui_Text(ctx, "Tone Generator")
        
        local freq_flags = r.ImGui_SliderFlags_AlwaysClamp()
        if r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift()) then
            freq_flags = freq_flags | r.ImGui_SliderFlags_Logarithmic()
        end
        local freq_changed
        freq_changed, config.tone_frequency = r.ImGui_SliderInt(ctx, 'Frequency (Hz)', config.tone_frequency, 20, 20000, "%d Hz", freq_flags)
        if r.ImGui_IsItemClicked(ctx, 1) then
            config.tone_frequency = defaults.tone_frequency
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Shift+Drag for fine tuning\nRight-click to reset")
        end
        
        local wave_options = {"sine", "square", "triangle", "sawtooth"}
        if r.ImGui_BeginCombo(ctx, 'Waveform', config.tone_waveform) then
            for _, wave in ipairs(wave_options) do
                if r.ImGui_Selectable(ctx, wave, wave == config.tone_waveform) then
                    config.tone_waveform = wave
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        local tone_amp_flags = r.ImGui_SliderFlags_AlwaysClamp()
        local tone_amp_changed
        tone_amp_changed, config.tone_amplitude_db = r.ImGui_SliderDouble(ctx, 'Tone Amplitude (dB)', config.tone_amplitude_db, -60, 0, "%.1f dB", tone_amp_flags)
        if r.ImGui_IsItemClicked(ctx, 1) then
            config.tone_amplitude_db = defaults.tone_amplitude_db
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Shift+Drag for fine tuning\nRight-click to reset")
        end
        
        if r.ImGui_Button(ctx, 'Generate Tone', -1) then
            CreateAudioFile(GenerateTone)
        end
        
        r.ImGui_Separator(ctx)
        
        r.ImGui_Text(ctx, "Noise Generator")
        
        local noise_options = {"white", "pink", "brown"}
        if r.ImGui_BeginCombo(ctx, 'Noise Type', config.noise_type) then
            for _, noise in ipairs(noise_options) do
                if r.ImGui_Selectable(ctx, noise, noise == config.noise_type) then
                    config.noise_type = noise
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        local noise_amp_flags = r.ImGui_SliderFlags_AlwaysClamp()
        local noise_amp_changed
        noise_amp_changed, config.noise_amplitude_db = r.ImGui_SliderDouble(ctx, 'Noise Amplitude (dB)', config.noise_amplitude_db, -60, 0, "%.1f dB", noise_amp_flags)
        if r.ImGui_IsItemClicked(ctx, 1) then
            config.noise_amplitude_db = defaults.noise_amplitude_db
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Shift+Drag for fine tuning\nRight-click to reset")
        end
        
        if r.ImGui_Button(ctx, 'Generate Noise', -1) then
            CreateAudioFile(GenerateNoise)
        end
        
        style_loader.PopFont(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    ClearStyle()
    
    r.PreventUIRefresh(-1)
    
    if open and state.window_open then
        r.defer(MainLoop)
    else
        SaveSettings()
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
    LoadSettings()
    state.window_open = true
    MainLoop()
end

function Stop()
    SaveSettings()
    state.window_open = false
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
