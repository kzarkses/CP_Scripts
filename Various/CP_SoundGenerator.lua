-- @description SoundGenerator
-- @version 2.0
-- @author Cedric Pamalio

local r = reaper

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")

local script_id = "CP_SoundGenerator"

local config = {
    tone_frequency = 440,
    tone_waveform = "sine",
    tone_amplitude_db = -6,
    noise_type = "white",
    noise_amplitude_db = -6,
}

local state = {
    noise = {
        pink = { b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0 },
        brown = { last = 0 },
    },
}

local WAVE_OPTIONS  = { "sine", "square", "triangle", "sawtooth" }
local NOISE_OPTIONS = { "white", "pink", "brown" }

local function index_of(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return 1
end

local function SaveSettings()
    for key, value in pairs(config) do
        r.SetExtState(script_id, "config_" .. key, tostring(value), true)
    end
end

local function LoadSettings()
    for key, default_value in pairs(config) do
        local saved_value = r.GetExtState(script_id, "config_" .. key)
        if saved_value ~= "" then
            if type(default_value) == "number" then
                config[key] = tonumber(saved_value) or default_value
            else
                config[key] = saved_value
            end
        end
    end
end

local function DbToAmplitude(db)
    return 10 ^ (db / 20)
end

local function GenerateWhiteNoise()
    return (math.random() * 2 - 1)
end

local function GeneratePinkNoise()
    local white = GenerateWhiteNoise()
    local p = state.noise.pink
    p.b0 = 0.99886 * p.b0 + white * 0.0555179
    p.b1 = 0.99332 * p.b1 + white * 0.0750759
    p.b2 = 0.96900 * p.b2 + white * 0.1538520
    p.b3 = 0.86650 * p.b3 + white * 0.3104856
    p.b4 = 0.55000 * p.b4 + white * 0.5329522
    p.b5 = -0.7616 * p.b5 - white * 0.0168980
    local pink = p.b0 + p.b1 + p.b2 + p.b3 + p.b4 + p.b5 + p.b6 + white * 0.5362
    p.b6 = white * 0.115926
    return pink * 0.11
end

local function GenerateBrownNoise()
    local white = GenerateWhiteNoise()
    state.noise.brown.last = (state.noise.brown.last + (0.02 * white)) / 1.02
    return state.noise.brown.last * 3.5
end

local function GenerateTone(buffer_size, sample_rate)
    local samples = {}
    local phase = 0
    local phase_inc = 2 * math.pi * config.tone_frequency / sample_rate
    local amplitude = DbToAmplitude(config.tone_amplitude_db)
    local wave = config.tone_waveform

    for i = 1, buffer_size do
        local sample = 0
        if wave == "sine" then
            sample = math.sin(phase)
        elseif wave == "square" then
            sample = phase < math.pi and 1 or -1
        elseif wave == "triangle" then
            sample = 1 - 2 * math.abs((phase / math.pi) % 2 - 1)
        elseif wave == "sawtooth" then
            sample = 1 - (phase / math.pi % 2)
        end
        samples[i] = sample * amplitude
        phase = (phase + phase_inc) % (2 * math.pi)
    end
    return samples
end

local function GenerateNoise(buffer_size)
    local samples = {}
    local amplitude = DbToAmplitude(config.noise_amplitude_db)
    local kind = config.noise_type

    for i = 1, buffer_size do
        local sample = 0
        if kind == "white" then
            sample = GenerateWhiteNoise()
        elseif kind == "pink" then
            sample = GeneratePinkNoise()
        elseif kind == "brown" then
            sample = GenerateBrownNoise()
        end
        samples[i] = sample * amplitude
    end
    return samples
end

local function CreateAudioFile(generator_func)
    local start_time, end_time = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if start_time == end_time then return end

    local temp_path = r.GetProjectPath("")
    if temp_path == "" then temp_path = os.getenv("TEMP") or "/tmp" end
    local filepath = temp_path .. "/tone_" .. os.time() .. ".wav"

    local sample_rate = 44100
    local success, rate = pcall(function() return r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false) end)
    if success and rate > 0 then sample_rate = rate end

    local duration = end_time - start_time
    local buffer_size = math.floor(duration * sample_rate)
    local samples = generator_func(buffer_size, sample_rate)

    local file = io.open(filepath, "wb")
    if not file then return end

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
    if not track then return end

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
end

LoadSettings()

local _, _, section_id, command_id = r.get_action_context()
r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

UI.Init("Sound Generator", 320, 240, {
    scale = 1.0,
    dock = 0,
})

UI.Run(function(theme)
    UI.SetFontH2()
    UI.Text("Sound Generator")
    UI.SetFontBody()
    UI.Separator()

    UI.BeginPanel("tone_panel", { style = "groupbox", title = "Tone" })

    local freq_changed, freq_value = UI.SliderInt(
        "tone_freq", "Frequency",
        config.tone_frequency, 20, 20000,
        { format = "%d Hz" }
    )
    if freq_changed then
        config.tone_frequency = freq_value
        SaveSettings()
    end

    local wave_changed, wave_idx = UI.Combo(
        "tone_wave", "Waveform",
        index_of(WAVE_OPTIONS, config.tone_waveform),
        WAVE_OPTIONS
    )
    if wave_changed then
        config.tone_waveform = WAVE_OPTIONS[wave_idx]
        SaveSettings()
    end

    local tone_amp_changed, tone_amp_value = UI.SliderDouble(
        "tone_amp", "Amplitude",
        config.tone_amplitude_db, -60, 0,
        { format = "%.1f dB" }
    )
    if tone_amp_changed then
        config.tone_amplitude_db = tone_amp_value
        SaveSettings()
    end

    if UI.Button("gen_tone", "Generate Tone", { width = -1 }) then
        CreateAudioFile(GenerateTone)
    end

    UI.EndPanel()

    UI.Spacing(theme.item_spacing)

    UI.BeginPanel("noise_panel", { style = "groupbox", title = "Noise" })

    local noise_changed, noise_idx = UI.Combo(
        "noise_type", "Type",
        index_of(NOISE_OPTIONS, config.noise_type),
        NOISE_OPTIONS
    )
    if noise_changed then
        config.noise_type = NOISE_OPTIONS[noise_idx]
        SaveSettings()
    end

    local noise_amp_changed, noise_amp_value = UI.SliderDouble(
        "noise_amp", "Amplitude",
        config.noise_amplitude_db, -60, 0,
        { format = "%.1f dB" }
    )
    if noise_amp_changed then
        config.noise_amplitude_db = noise_amp_value
        SaveSettings()
    end

    if UI.Button("gen_noise", "Generate Noise", { width = -1 }) then
        CreateAudioFile(GenerateNoise)
    end

    UI.EndPanel()
end)

UI.OnClose(function()
    SaveSettings()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end)
