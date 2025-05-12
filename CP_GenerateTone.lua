local r = reaper

local ctx = r.ImGui_CreateContext('Tone Generator')
local config = {
    frequency = 440,
    waveform = "sine",
    amplitude = 0.5,
    window_open = true
}

function generateTone(buffer_size, sample_rate)
    local samples = {}
    local phase = 0
    local phase_inc = 2 * math.pi * config.frequency / sample_rate
    
    for i = 1, buffer_size do
        local sample = 0
        
        if config.waveform == "sine" then
            sample = math.sin(phase)
        elseif config.waveform == "square" then
            sample = phase < math.pi and 1 or -1
        elseif config.waveform == "triangle" then
            sample = 1 - 2 * math.abs((phase / math.pi) % 2 - 1)
        elseif config.waveform == "sawtooth" then
            sample = 1 - (phase / math.pi % 2)
        end
        
        samples[i] = sample * config.amplitude
        phase = (phase + phase_inc) % (2 * math.pi)
    end
    
    return samples
end

function createAudioFile()
    local start_time, end_time = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if start_time == end_time then return end

    local temp_path = r.GetProjectPath("") 
    if temp_path == "" then temp_path = os.getenv("TEMP") or "/tmp" end
    local filepath = temp_path .. "/tone_" .. os.time() .. ".wav"
    
    local sample_rate = 44100
    local duration = end_time - start_time
    local buffer_size = math.floor(duration * sample_rate)
    local samples = generateTone(buffer_size, sample_rate)
    
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
            os.remove(filepath)
            config.window_open = false
        end
    end
end

function Loop()
    if not config.window_open then
        Exit()
        return
    end
    
    local visible, open = r.ImGui_Begin(ctx, 'Tone Generator', true)
    
    if visible then
        local freq_changed
        freq_changed, config.frequency = r.ImGui_SliderInt(ctx, 'Frequency (Hz)', config.frequency, 20, 20000)
        
        local wave_options = {"sine", "square", "triangle", "sawtooth"}
        if r.ImGui_BeginCombo(ctx, 'Waveform', config.waveform) then
            for _, wave in ipairs(wave_options) do
                if r.ImGui_Selectable(ctx, wave, wave == config.waveform) then
                    config.waveform = wave
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        local amp_changed
        amp_changed, config.amplitude = r.ImGui_SliderDouble(ctx, 'Amplitude', config.amplitude, 0, 1)
        
        if r.ImGui_Button(ctx, 'Generate', -1, 30) then
            createAudioFile()
        end
        
        r.ImGui_End(ctx)
    end
    
    if open and config.window_open then
        r.defer(Loop)
    end
end

function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
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
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()
