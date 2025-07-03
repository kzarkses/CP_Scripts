--[[
Description: CP_SoundGenerator
Version: 1.0
Author: Cedric Pamallo
--]]
local r = reaper

local sl = nil
local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp) then local lf = dofile(sp) if lf then sl = lf() end end

local ctx = r.ImGui_CreateContext('Tone Generator')
local pc, pv = 0, 0

if sl then sl.applyFontsToContext(ctx) end

function getStyleFont(font_name)
    if sl then
        return sl.getFont(ctx, font_name)
    end
    return nil
end

function dbToAmplitude(db)
    return 10 ^ (db / 20)
end

function amplitudeToDb(amplitude)
    return 20 * math.log10(math.max(amplitude, 0.000001))
end

local noise_state = {
    pink = { b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0 },
    brown = { last = 0 }
}

function generateWhiteNoise()
    return (math.random() * 2 - 1)
end

function generatePinkNoise()
    local white = generateWhiteNoise()
    noise_state.pink.b0 = 0.99886 * noise_state.pink.b0 + white * 0.0555179
    noise_state.pink.b1 = 0.99332 * noise_state.pink.b1 + white * 0.0750759
    noise_state.pink.b2 = 0.96900 * noise_state.pink.b2 + white * 0.1538520
    noise_state.pink.b3 = 0.86650 * noise_state.pink.b3 + white * 0.3104856
    noise_state.pink.b4 = 0.55000 * noise_state.pink.b4 + white * 0.5329522
    noise_state.pink.b5 = -0.7616 * noise_state.pink.b5 - white * 0.0168980
    local pink = noise_state.pink.b0 + noise_state.pink.b1 + noise_state.pink.b2 + noise_state.pink.b3 + noise_state.pink.b4 + noise_state.pink.b5 + noise_state.pink.b6 + white * 0.5362
    noise_state.pink.b6 = white * 0.115926
    return pink * 0.11
end

function generateBrownNoise()
    local white = generateWhiteNoise()
    noise_state.brown.last = (noise_state.brown.last + (0.02 * white)) / 1.02
    return noise_state.brown.last * 3.5
end

local config = {
    tone_frequency = 440,
    tone_waveform = "sine",
    tone_amplitude_db = -6,
    noise_type = "white",
    noise_amplitude_db = -6,
    window_open = true,
    auto_close = false
}

-- Valeurs par dÃ©faut pour reset
local defaults = {
    tone_frequency = 440,
    tone_amplitude_db = -6,
    noise_amplitude_db = -6
}

function generateTone(buffer_size, sample_rate)
    local samples = {}
    local phase = 0
    local phase_inc = 2 * math.pi * config.tone_frequency / sample_rate
    local amplitude = dbToAmplitude(config.tone_amplitude_db)
    
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

function generateNoise(buffer_size, sample_rate)
    local samples = {}
    local amplitude = dbToAmplitude(config.noise_amplitude_db)
    
    for i = 1, buffer_size do
        local sample = 0
        
        if config.noise_type == "white" then
            sample = generateWhiteNoise()
        elseif config.noise_type == "pink" then
            sample = generatePinkNoise()
        elseif config.noise_type == "brown" then
            sample = generateBrownNoise()
        end
        
        samples[i] = sample * amplitude
    end
    
    return samples
end

function createAudioFile(generator_func)
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
                config.window_open = false
            end
        end
    end
end

function Loop()
    if not config.window_open then
        Exit()
        return
    end
    
    if sl then
        local success, colors, vars = sl.applyToContext(ctx)
        if success then pc, pv = colors, vars end
    end
    
    r.ImGui_SetNextWindowSize(ctx, 310, 310, r.ImGui_Cond_Always())
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Tone Generator', true, window_flags)
    
    if visible then
        local header_font = getStyleFont("header")
        local main_font = getStyleFont("main")
        
        if header_font then r.ImGui_PushFont(ctx, header_font) end
        r.ImGui_Text(ctx, "Sound Generator")
        if header_font then r.ImGui_PopFont(ctx) end
        if main_font then r.ImGui_PushFont(ctx, main_font) end
        
        r.ImGui_SameLine(ctx)
        local auto_x = r.ImGui_GetWindowWidth(ctx) - 60
        r.ImGui_SetCursorPosX(ctx, auto_x)
        local was_auto_close = config.auto_close  -- Sauvegarder l'Ã©tat avant le bouton
        if config.auto_close then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_ButtonActive()))
        end
        if r.ImGui_Button(ctx, "A", 22, 22) then
            config.auto_close = not config.auto_close
        end
        if was_auto_close then  -- Utiliser l'ancien Ã©tat pour le pop
            r.ImGui_PopStyleColor(ctx)
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Auto-close after generate")
        end
        
        r.ImGui_SameLine(ctx)
        local close_x = r.ImGui_GetWindowWidth(ctx) - 30
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", 22, 22) then
            open = false
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- SECTION TONE
        r.ImGui_Text(ctx, "Tone Generator")
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Frequency slider with fine tuning
        local freq_flags = r.ImGui_SliderFlags_AlwaysClamp()
        if r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift()) then
            freq_flags = freq_flags | r.ImGui_SliderFlags_Logarithmic()
        end
        local freq_changed
        freq_changed, config.tone_frequency = r.ImGui_SliderInt(ctx, 'Frequency (Hz)', config.tone_frequency, 20, 20000, "%d Hz", freq_flags)
        if r.ImGui_IsItemClicked(ctx, 1) then -- Right click to reset
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
        
        if r.ImGui_Button(ctx, 'Generate Tone', -1, 30) then
            createAudioFile(generateTone)
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Spacing(ctx)
        
        -- SECTION NOISE
        r.ImGui_Text(ctx, "Noise Generator")
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        local noise_options = {"white", "pink", "brown"}
        if r.ImGui_BeginCombo(ctx, 'Noise Type', config.noise_type) then
            for _, noise in ipairs(noise_options) do
                if r.ImGui_Selectable(ctx, noise, noise == config.noise_type) then
                    config.noise_type = noise
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        -- Noise amplitude slider with fine tuning
        local noise_amp_flags = r.ImGui_SliderFlags_AlwaysClamp()
        local noise_amp_changed
        noise_amp_changed, config.noise_amplitude_db = r.ImGui_SliderDouble(ctx, 'Noise Amplitude (dB)', config.noise_amplitude_db, -60, 0, "%.1f dB", noise_amp_flags)
        if r.ImGui_IsItemClicked(ctx, 1) then -- Right click to reset
            config.noise_amplitude_db = defaults.noise_amplitude_db
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Shift+Drag for fine tuning\nRight-click to reset")
        end
        
        if r.ImGui_Button(ctx, 'Generate Noise', -1, 30) then
            createAudioFile(generateNoise)
        end
        
        if main_font then r.ImGui_PopFont(ctx) end
        r.ImGui_End(ctx)
    end
    
    if sl then sl.clearStyles(ctx, pc, pv) end
    
    if not open then
        config.window_open = false
    end
    
    if open and config.window_open then
        r.defer(Loop)
    end
end

function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    local auto_close_state = r.GetExtState("CP_GenerateTone", "auto_close")
    if auto_close_state ~= "" then
        config.auto_close = auto_close_state == "1"
    end
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        config.window_open = true
        Loop()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
        config.window_open = false
    end
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetExtState("CP_GenerateTone", "auto_close", config.auto_close and "1" or "0", true)
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()



