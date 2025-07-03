-- @description PitchShiftSelector
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

if not r.APIExists("ImGui_CreateContext") then
    r.ShowMessageBox("This script requires js_ReaScriptAPI with ReaImGui. Please install it via ReaPack.", "Error", 0)
    return
end


local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Scripts/Various/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

local script_id = "CP_PitchShiftSelector_Instance"
if _G[script_id] then
    _G[script_id] = false
    return
end
_G[script_id] = true

local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

local ctx = r.ImGui_CreateContext('Pitch Shift Selector')

if style_loader then
  style_loader.applyFontsToContext(ctx)
end

function getStyleFont(font_name)
  if style_loader then
    return style_loader.getFont(ctx, font_name)
  end
  return nil
end

local ALGORITHMS = {
    { name = "Project Default", index = -1 },
    { name = "SoundTouch", index = 0 },
    { name = "Simple Windowed", index = 2 },
    { name = "Elastique 2 Pro", index = 6 },
    { name = "Elastique 2 Efficient", index = 7 },
    { name = "Elastique 2 Soloist", index = 8 },
    { name = "Elastique 3 Pro", index = 9 },
    { name = "Elastique 3 Efficient", index = 10 },
    { name = "Elastique 3 Soloist", index = 11 },
    { name = "Rubber Band Library", index = 13 },
    { name = "Rrreeeaaa", index = 14 },
    { name = "ReaReaRea", index = 15 }
}

math.randomseed(os.time())

local bitmask = {
  syn = 7,
  ano = 24,
  fft = 96,
  anw = 384,
  syw = 1536,
  rnd = 15,
  fdm = 1008,
  shp = 3072,
  snc = 8192,
}

local syn_to_slider = {
  [7] = 3, [0] = 4, [1] = 5, [2] = 6, [3] = 7, [4] = 8, [5] = 9, [6] = 10
}

local slider_to_syn = {
  [3] = 7, [4] = 0, [5] = 1, [6] = 2, [7] = 3, [8] = 4, [9] = 5, [10] = 6
}

local fft_to_slider = {
  [0] = 0, [32] = 1, [64] = 2, [96] = 3
}

local fft_names = {
  [0] = "FFT: 32768", [1] = "FFT: 16364", [2] = "FFT: 8192", [3] = "FFT: 4096"
}

local slider_to_fft = {
  [0] = 0, [1] = 32, [2] = 64, [3] = 96
}

local ano_to_slider = {
  [0] = 0, [8] = 1, [16] = 2, [24] = 3
}

local ano_names = {
  [0] = "1/2", [1] = "1/4", [2] = "1/6", [3] = "1/8"
}

local slider_to_ano = {
  [0] = 0, [1] = 8, [2] = 16, [3] = 24
}

local anw_to_slider = {
  [0] = 0, [128] = 1, [256] = 2, [384] = 3,
}

local anw_names = {
  [0] = "Blackman-Harris", [1] = "Hamming", [2] = "Blackman", [3] = "Rectangular"
}

local slider_to_anw = {
  [0] = 0, [1] = 128, [2] = 256, [3] = 384
}

local syw_to_slider = {
  [0] = 0, [512] = 1, [1024] = 2, [1536] = 3,
}

local syw_names = {
  [0] = "Blackman-Harris", [1] = "Hamming", [2] = "Blackman", [3] = "Triangular"
}

local slider_to_syw = {
  [0] = 0, [1] = 512, [2] = 1024, [3] = 1536
}

local rnd_names = {
  [0] = "0", [1] = "6", [2] = "12", [3] = "18", [4] = "25", [5] = "31", [6] = "37", [7] = "43",
  [8] = "50", [9] = "56", [10] = "62", [11] = "68", [12] = "75", [13] = "81", [14] = "87", [15] = "93"
}

local fdm_to_slider = {
  [912] = 0, [928] = 1, [944] = 2, [960] = 3, [976] = 4, [992] = 5, [1008] = 6, [0] = 7,
  [16] = 8, [32] = 9, [48] = 10, [64] = 11, [80] = 12, [96] = 13, [112] = 14, [128] = 15,
  [144] = 16, [160] = 17, [176] = 18, [192] = 19, [208] = 20, [224] = 21, [240] = 22, [256] = 23,
  [272] = 24, [288] = 25, [304] = 26, [320] = 27, [336] = 28, [352] = 29, [368] = 30, [384] = 31,
  [400] = 32, [416] = 33, [432] = 34, [448] = 35, [464] = 36, [480] = 37, [496] = 38, [512] = 39,
  [528] = 40, [544] = 41, [560] = 42, [576] = 43, [592] = 44, [608] = 45, [624] = 46, [640] = 47,
  [656] = 48, [672] = 49, [688] = 50, [704] = 51, [720] = 52, [736] = 53, [752] = 54, [768] = 55,
  [784] = 56, [800] = 57, [816] = 58, [832] = 59, [848] = 60, [864] = 61, [880] = 62, [896] = 63
}

local fdm_names = {
  [0] = "2 ms", [1] = "4 ms", [2] = "6 ms", [3] = "8 ms", [4] = "12 ms", [5] = "24 ms", [6] = "36 ms", [7] = "48 ms",
  [8] = "60 ms", [9] = "72 ms", [10] = "84 ms", [11] = "96 ms", [12] = "108 ms", [13] = "120 ms", [14] = "132 ms", [15] = "144 ms",
  [16] = "156 ms", [17] = "168 ms", [18] = "180 ms", [19] = "192 ms", [20] = "204 ms", [21] = "216 ms", [22] = "228 ms", [23] = "240 ms",
  [24] = "252 ms", [25] = "264 ms", [26] = "276 ms", [27] = "288 ms", [28] = "300 ms", [29] = "312 ms", [30] = "324 ms", [31] = "336 ms",
  [32] = "348 ms", [33] = "360 ms", [34] = "372 ms", [35] = "384 ms", [36] = "396 ms", [37] = "408 ms", [38] = "420 ms", [39] = "432 ms",
  [40] = "448 ms", [41] = "472 ms", [42] = "496 ms", [43] = "520 ms", [44] = "544 ms", [45] = "568 ms", [46] = "592 ms", [47] = "616 ms",
  [48] = "640 ms", [49] = "664 ms", [50] = "688 ms", [51] = "712 ms", [52] = "736 ms", [53] = "760 ms", [54] = "784 ms", [55] = "808 ms",
  [56] = "832 ms", [57] = "856 ms", [58] = "880 ms", [59] = "904 ms", [60] = "928 ms", [61] = "952 ms", [62] = "976 ms", [63] = "1000 ms"
}

local slider_to_fdm = {
  [0] = 912, [1] = 928, [2] = 944, [3] = 960, [4] = 976, [5] = 992, [6] = 1008, [7] = 0,
  [8] = 16, [9] = 32, [10] = 48, [11] = 64, [12] = 80, [13] = 96, [14] = 112, [15] = 128,
  [16] = 144, [17] = 160, [18] = 176, [19] = 192, [20] = 208, [21] = 224, [22] = 240, [23] = 256,
  [24] = 272, [25] = 288, [26] = 304, [27] = 320, [28] = 336, [29] = 352, [30] = 368, [31] = 384,
  [32] = 400, [33] = 416, [34] = 432, [35] = 448, [36] = 464, [37] = 480, [38] = 496, [39] = 512,
  [40] = 528, [41] = 544, [42] = 560, [43] = 576, [44] = 592, [45] = 608, [46] = 624, [47] = 640,
  [48] = 656, [49] = 672, [50] = 688, [51] = 704, [52] = 720, [53] = 736, [54] = 752, [55] = 768,
  [56] = 784, [57] = 800, [58] = 816, [59] = 832, [60] = 848, [61] = 864, [62] = 880, [63] = 896
}

local shp_to_slider = {
  [0] = 0, [1024] = 1, [2048] = 2
}

local shp_names = {
  [0] = "sin", [1] = "linear", [2] = "rectangular"
}

local slider_to_shp = {
  [0] = 0, [1] = 1024, [2] = 2048
}

local snc_to_checkbox = {
  [0] = false, [8192] = true
}

local checkbox_to_snc = {
  [false] = 0, [true] = 8192
}

local fds_to_slider = {
  [0] = 0, [128] = 1, [256] = 2, [16] = 3, [144] = 4, [272] = 5, [32] = 6, [160] = 7, [288] = 8, [48] = 9, [176] = 10, [304] = 11,
  [64] = 12, [192] = 13, [320] = 14, [80] = 15, [208] = 16, [336] = 17, [96] = 18, [224] = 19, [352] = 20, [112] = 21, [240] = 22, [368] = 23
}

local fds_names = {
  [0] = "1/128", [1] = "1/128t", [2] = "1/128d", [3] = "1/64", [4] = "1/64t", [5] = "1/64d", [6] = "1/32", [7] = "1/32t", [8] = "1/32d",
  [9] = "1/16", [10] = "1/16t", [11] = "1/16d", [12] = "1/8", [13] = "1/8t", [14] = "1/8d", [15] = "1/4", [16] = "1/4t", [17] = "1/4d",
  [18] = "1/2", [19] = "1/2t", [20] = "1/2d", [21] = "1/1", [22] = "1/1t", [23] = "1/1d"
}

local slider_to_fds = {
  [0] = 0, [1] = 128, [2] = 256, [3] = 16, [4] = 144, [5] = 272, [6] = 32, [7] = 160, [8] = 288, [9] = 48, [10] = 176, [11] = 304,
  [12] = 64, [13] = 192, [14] = 320, [15] = 80, [16] = 208, [17] = 336, [18] = 96, [19] = 224, [20] = 352, [21] = 112, [22] = 240, [23] = 368
}

local algorithm_params = {
    [0] = {
        quality = 0,
        channel = 0
    },
    [2] = {
        ms_window = 6,
        fade_percent = 0
    },
    [6] = {
        preserve_formants = 0,
        synchronized = false,
        mid_side = false,
        channel = 0
    },
    [7] = {
        synchronized = false,
        mid_side = false,
        channel = 0
    },
    [8] = {
        mode = 0,
        mid_side = false,
        channel = 0
    },
    [9] = {
        preserve_formants = 0,
        synchronized = false,
        mid_side = false,
        channel = 0
    },
    [10] = {
        synchronized = false,
        mid_side = false,
        channel = 0
    },
    [11] = {
        mode = 0,
        mid_side = false,
        channel = 0
    }
}

local stretch_params = {
    fade_size = 2.0,
    mode = 0
}

local stretch_mode_names = {"Project default", "Balanced", "Tonal-optimized", "Transient-optimized", "No pre-echo reduction"}
local stretch_mode_actions = {-1, 42338, 41857, 42337, 42339}

local soundtouch_quality_names = {"Default settings", "High Quality", "Fast"}
local soundtouch_channel_names = {"Multichannel", "Multi-stereo", "Multi-mono"}

local simple_windowed_ms_names = {"50ms", "75ms", "100ms", "150ms", "225ms", "300ms", "40ms", "30ms", "20ms", "10ms", "5ms", "3ms"}
local simple_windowed_ms_display = {"3ms", "5ms", "10ms", "20ms", "30ms", "40ms", "50ms", "75ms", "100ms", "150ms", "225ms", "300ms"}
local simple_windowed_ms_mapping = {11, 10, 9, 8, 7, 6, 0, 1, 2, 3, 4, 5}
local simple_windowed_fade_names = {"50%", "33%", "20%", "14%"}

local elastique_preserve_formants_names = {"Normal", "Lowest Pitches", "Lower Pitches", "Lower Pitches", "Most Pitches", "High Pitches", "Higher Pitches", "Highest Pitches"}
local elastique_channel_names = {"Multichannel", "Multi-Stereo", "Multi-Mono"}

local elastique_soloist_mode_names = {"Monophonic", "Speech"}

local current_mode = 0
local current_submode = 0
local window_open = true

local rrreeeaaa_params = {
    syn = 0,
    ano = 0,
    fft = 0,
    anw = 0,
    syw = 0
}

local rearearea_params = {
    rnd = 0,
    fdm = 0,
    shp = 0,
    snc = 0,
    snc_checkbox = false
}

local function DecomposeSubmode(mode, submode)
    if mode == 0 then
        algorithm_params[0].channel = math.floor(submode / 3)
        algorithm_params[0].quality = submode % 3
    elseif mode == 2 then
        local real_ms_window = math.floor(submode / 4)
        local visual_ms_window = 0
        for i, real_idx in ipairs(simple_windowed_ms_mapping) do
            if real_idx == real_ms_window then
                visual_ms_window = i - 1
                break
            end
        end
        algorithm_params[2].ms_window = visual_ms_window
        algorithm_params[2].fade_percent = submode % 4
    elseif mode == 6 or mode == 9 then
        local base = submode % 8
        local flags = math.floor(submode / 8)
        
        algorithm_params[mode].preserve_formants = base
        algorithm_params[mode].synchronized = (flags & 2) ~= 0
        algorithm_params[mode].mid_side = (flags & 1) ~= 0
        algorithm_params[mode].channel = (flags & 12) >> 2
    elseif mode == 7 or mode == 10 then
        algorithm_params[mode].synchronized = (submode & 2) ~= 0
        algorithm_params[mode].mid_side = (submode & 1) ~= 0
        algorithm_params[mode].channel = (submode & 12) >> 2
    elseif mode == 8 or mode == 11 then
        algorithm_params[mode].mode = (submode & 2) ~= 0 and 1 or 0
        algorithm_params[mode].mid_side = (submode & 1) ~= 0
        algorithm_params[mode].channel = (submode & 12) >> 2
    end
end

local function GetCurrentModeFromSelection()
    local selected_item = r.GetSelectedMediaItem(0, 0)
    if not selected_item then return false end
    
    local take = r.GetActiveTake(selected_item)
    if not take or r.TakeIsMIDI(take) then return false end
    
    local pitch_value = r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
    
    local mode = math.floor(pitch_value / 65536)
    local submode = pitch_value % 65536
    
    if mode == 14 then
        rrreeeaaa_params.syn = submode & bitmask.syn
        rrreeeaaa_params.ano = submode & bitmask.ano
        rrreeeaaa_params.fft = submode & bitmask.fft
        rrreeeaaa_params.anw = submode & bitmask.anw
        rrreeeaaa_params.syw = submode & bitmask.syw
    elseif mode == 15 then
        rearearea_params.rnd = submode & bitmask.rnd
        rearearea_params.fdm = submode & bitmask.fdm
        rearearea_params.shp = submode & bitmask.shp
        rearearea_params.snc = submode & bitmask.snc
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
    elseif algorithm_params[mode] then
        DecomposeSubmode(mode, submode)
    end
    
    current_mode = mode
    current_submode = submode
    return true
end

local function ComposeSubmode(mode)
    if mode == 0 then
        return algorithm_params[0].channel * 3 + algorithm_params[0].quality
    elseif mode == 2 then
        local visual_idx = algorithm_params[2].ms_window
        local real_ms_window = simple_windowed_ms_mapping[visual_idx + 1]
        return real_ms_window * 4 + algorithm_params[2].fade_percent
    elseif mode == 6 or mode == 9 then
        local flags = 0
        if algorithm_params[mode].mid_side then flags = flags | 1 end
        if algorithm_params[mode].synchronized then flags = flags | 2 end
        flags = flags | (algorithm_params[mode].channel << 2)
        return algorithm_params[mode].preserve_formants + (flags << 3)
    elseif mode == 7 or mode == 10 then
        local flags = 0
        if algorithm_params[mode].mid_side then flags = flags | 1 end
        if algorithm_params[mode].synchronized then flags = flags | 2 end
        flags = flags | (algorithm_params[mode].channel << 2)
        return flags
    elseif mode == 8 or mode == 11 then
        local flags = algorithm_params[mode].mid_side and 1 or 0
        if algorithm_params[mode].mode == 1 then flags = flags | 2 end
        flags = flags | (algorithm_params[mode].channel << 2)
        return flags
    end
    return 0
end

local function GetStretchMarkerSettings()
    local saved_fade = r.GetExtState("PitchShiftSelector", "stretch_fade")
    local saved_mode = r.GetExtState("PitchShiftSelector", "stretch_mode")
    
    stretch_params.fade_size = (saved_fade ~= "" and tonumber(saved_fade)) or 2.0
    stretch_params.mode = (saved_mode ~= "" and tonumber(saved_mode)) or 0
    
    if r.SNM_GetDoubleConfigVar then
        local fade_from_reaper = r.SNM_GetDoubleConfigVar("smfadesize", -1)
        if fade_from_reaper >= 0 then
            stretch_params.fade_size = fade_from_reaper * 1000
        end
    end
end

local function ApplyStretchMarkerSettings()
    r.SetExtState("PitchShiftSelector", "stretch_fade", tostring(stretch_params.fade_size), true)
    r.SetExtState("PitchShiftSelector", "stretch_mode", tostring(stretch_params.mode), true)
    
    if r.SNM_SetDoubleConfigVar then
        r.SNM_SetDoubleConfigVar("smfadesize", stretch_params.fade_size / 1000)
    end
    
    local action_id = stretch_mode_actions[stretch_params.mode + 1]
    if action_id and action_id > 0 then
        r.Main_OnCommand(action_id, 0)
    end
end

local function ApplyBasicPitchMode(mode_idx, submode_idx)
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    local pitch_value = (mode_idx * 65536) + submode_idx
    
    for i = 0, item_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    
    r.Undo_EndBlock("Set Pitch Shift Mode", -1)
    r.UpdateArrange()
    
    current_mode = mode_idx
    current_submode = submode_idx
end

local function ApplyParametricPitchMode(mode_idx)
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    local submode = ComposeSubmode(mode_idx)
    local pitch_value = (mode_idx * 65536) + submode
    
    for i = 0, item_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    
    r.Undo_EndBlock("Set Pitch Shift Parameters", -1)
    r.UpdateArrange()
    
    current_mode = mode_idx
    current_submode = submode
end

local function ApplyRrreeeaaaMode()
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    local submode = rrreeeaaa_params.syn + rrreeeaaa_params.ano + rrreeeaaa_params.fft + 
                    rrreeeaaa_params.anw + rrreeeaaa_params.syw
    
    local pitch_value = (14 * 65536) + submode
    
    for i = 0, item_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    
    r.Undo_EndBlock("Set Rrreeeaaa Parameters", -1)
    r.UpdateArrange()
    
    current_mode = 14
    current_submode = submode
end

local function ApplyReaReaReaMode()
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    local submode = rearearea_params.rnd + rearearea_params.fdm + 
                   rearearea_params.shp + rearearea_params.snc
    
    local pitch_value = (15 * 65536) + submode
    
    for i = 0, item_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    
    r.Undo_EndBlock("Set ReaReaRea Parameters", -1)
    r.UpdateArrange()
    
    current_mode = 15
    current_submode = submode
end

function RandomizeAlgorithm()
    if r.CountSelectedMediaItems(0) == 0 then return end
    
    local random_index = math.random(1, #ALGORITHMS)
    local algo = ALGORITHMS[random_index]
    
    if algo.index == 14 then
        rrreeeaaa_params.syn = slider_to_syn[math.random(3, 10)]
        rrreeeaaa_params.fft = slider_to_fft[math.random(0, 3)]
        rrreeeaaa_params.ano = slider_to_ano[math.random(0, 3)]
        rrreeeaaa_params.anw = slider_to_anw[math.random(0, 3)]
        rrreeeaaa_params.syw = slider_to_syw[math.random(0, 3)]
        ApplyRrreeeaaaMode()
    elseif algo.index == 15 then
        rearearea_params.rnd = math.random(0, 15)
        rearearea_params.fdm = slider_to_fdm[math.random(0, 63)]
        rearearea_params.shp = slider_to_shp[math.random(0, 2)]
        rearearea_params.snc = checkbox_to_snc[math.random(0, 1) == 1]
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
        ApplyReaReaReaMode()
    elseif algorithm_params[algo.index] then
        if algo.index == 0 then
            algorithm_params[0].channel = math.random(0, 2)
            algorithm_params[0].quality = math.random(0, 2)
        elseif algo.index == 2 then
            algorithm_params[2].ms_window = math.random(0, 11)
            algorithm_params[2].fade_percent = math.random(0, 3)
        elseif algo.index == 6 or algo.index == 9 then
            algorithm_params[algo.index].preserve_formants = math.random(0, 7)
            algorithm_params[algo.index].synchronized = math.random(0, 1) == 1
            algorithm_params[algo.index].mid_side = math.random(0, 1) == 1
            algorithm_params[algo.index].channel = math.random(0, 2)
        elseif algo.index == 7 or algo.index == 10 then
            algorithm_params[algo.index].synchronized = math.random(0, 1) == 1
            algorithm_params[algo.index].mid_side = math.random(0, 1) == 1
            algorithm_params[algo.index].channel = math.random(0, 2)
        elseif algo.index == 8 or algo.index == 11 then
            algorithm_params[algo.index].mode = math.random(0, 1)
            algorithm_params[algo.index].mid_side = math.random(0, 1) == 1
            algorithm_params[algo.index].channel = math.random(0, 2)
        end
        ApplyParametricPitchMode(algo.index)
    else
        ApplyBasicPitchMode(algo.index, 0)
    end
end

function RandomizeSubmode()
    if r.CountSelectedMediaItems(0) == 0 then return end

    if current_mode == 14 then
        rrreeeaaa_params.syn = slider_to_syn[math.random(3, 10)]
        rrreeeaaa_params.fft = slider_to_fft[math.random(0, 3)]
        rrreeeaaa_params.ano = slider_to_ano[math.random(0, 3)]
        rrreeeaaa_params.anw = slider_to_anw[math.random(0, 3)]
        rrreeeaaa_params.syw = slider_to_syw[math.random(0, 3)]
        ApplyRrreeeaaaMode()
    elseif current_mode == 15 then
        rearearea_params.rnd = math.random(0, 15)
        local fdm_indices = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
        local random_fdm_index = fdm_indices[math.random(1, #fdm_indices)]
        rearearea_params.fdm = slider_to_fdm[random_fdm_index]
        local shp_indices = {0, 1, 2}
        local random_shp_index = shp_indices[math.random(1, #shp_indices)]
        rearearea_params.shp = slider_to_shp[random_shp_index]
        local snc_values = {0, 8192}
        rearearea_params.snc = snc_values[math.random(1, 2)]
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
        ApplyReaReaReaMode()
    elseif algorithm_params[current_mode] then
        if current_mode == 0 then
            algorithm_params[0].channel = math.random(0, 2)
            algorithm_params[0].quality = math.random(0, 2)
        elseif current_mode == 2 then
            algorithm_params[2].ms_window = math.random(0, 11)
            algorithm_params[2].fade_percent = math.random(0, 3)
        elseif current_mode == 6 or current_mode == 9 then
            algorithm_params[current_mode].preserve_formants = math.random(0, 7)
            algorithm_params[current_mode].synchronized = math.random(0, 1) == 1
            algorithm_params[current_mode].mid_side = math.random(0, 1) == 1
            algorithm_params[current_mode].channel = math.random(0, 2)
        elseif current_mode == 7 or current_mode == 10 then
            algorithm_params[current_mode].synchronized = math.random(0, 1) == 1
            algorithm_params[current_mode].mid_side = math.random(0, 1) == 1
            algorithm_params[current_mode].channel = math.random(0, 2)
        elseif current_mode == 8 or current_mode == 11 then
            algorithm_params[current_mode].mode = math.random(0, 1)
            algorithm_params[current_mode].mid_side = math.random(0, 1) == 1
            algorithm_params[current_mode].channel = math.random(0, 2)
        end
        ApplyParametricPitchMode(current_mode)
    end
end

function RandomizeFull()
    if r.CountSelectedMediaItems(0) == 0 then return end
    
    local random_index = math.random(1, #ALGORITHMS)
    local algo = ALGORITHMS[random_index]
    
    if algo.index == 14 then
        rrreeeaaa_params.syn = slider_to_syn[math.random(3, 10)]
        rrreeeaaa_params.fft = slider_to_fft[math.random(0, 3)]
        rrreeeaaa_params.ano = slider_to_ano[math.random(0, 3)]
        rrreeeaaa_params.anw = slider_to_anw[math.random(0, 3)]
        rrreeeaaa_params.syw = slider_to_syw[math.random(0, 3)]
        ApplyRrreeeaaaMode()
    elseif algo.index == 15 then
        rearearea_params.rnd = math.random(0, 15)
        rearearea_params.fdm = slider_to_fdm[math.random(0, 63)]
        rearearea_params.shp = slider_to_shp[math.random(0, 2)]
        rearearea_params.snc = checkbox_to_snc[math.random(0, 1) == 1]
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
        ApplyReaReaReaMode()
    elseif algorithm_params[algo.index] then
        if algo.index == 0 then
            algorithm_params[0].channel = math.random(0, 2)
            algorithm_params[0].quality = math.random(0, 2)
        elseif algo.index == 2 then
            algorithm_params[2].ms_window = math.random(0, 11)
            algorithm_params[2].fade_percent = math.random(0, 3)
        elseif algo.index == 6 or algo.index == 9 then
            algorithm_params[algo.index].preserve_formants = math.random(0, 7)
            algorithm_params[algo.index].synchronized = math.random(0, 1) == 1
            algorithm_params[algo.index].mid_side = math.random(0, 1) == 1
            algorithm_params[algo.index].channel = math.random(0, 2)
        elseif algo.index == 7 or algo.index == 10 then
            algorithm_params[algo.index].synchronized = math.random(0, 1) == 1
            algorithm_params[algo.index].mid_side = math.random(0, 1) == 1
            algorithm_params[algo.index].channel = math.random(0, 2)
        elseif algo.index == 8 or algo.index == 11 then
            algorithm_params[algo.index].mode = math.random(0, 1)
            algorithm_params[algo.index].mid_side = math.random(0, 1) == 1
            algorithm_params[algo.index].channel = math.random(0, 2)
        end
        ApplyParametricPitchMode(algo.index)
    else
        ApplyBasicPitchMode(algo.index, 0)
    end
end

local function RenderRrreeeaaaControls()
    local changed = false
    local rv
    
    local syn_slider = syn_to_slider[rrreeeaaa_params.syn]
    rv, syn_slider = r.ImGui_SliderInt(ctx, "Synthesis", syn_slider, 3, 10, "%dx")
    if rv then
        rrreeeaaa_params.syn = slider_to_syn[syn_slider]
        changed = true
    end
    
    local fft_slider = fft_to_slider[rrreeeaaa_params.fft]
    rv, fft_slider = r.ImGui_SliderInt(ctx, "FFT", fft_slider, 0, 3, fft_names[fft_slider])
    if rv then
        rrreeeaaa_params.fft = slider_to_fft[fft_slider]
        changed = true
    end
    
    local ano_slider = ano_to_slider[rrreeeaaa_params.ano]
    rv, ano_slider = r.ImGui_SliderInt(ctx, "Analysis Offset", ano_slider, 0, 3, ano_names[ano_slider])
    if rv then
        rrreeeaaa_params.ano = slider_to_ano[ano_slider]
        changed = true
    end
    
    local anw_slider = anw_to_slider[rrreeeaaa_params.anw]
    rv, anw_slider = r.ImGui_SliderInt(ctx, "Analysis Window", anw_slider, 0, 3, anw_names[anw_slider])
    if rv then
        rrreeeaaa_params.anw = slider_to_anw[anw_slider]
        changed = true
    end
    
    local syw_slider = syw_to_slider[rrreeeaaa_params.syw]
    rv, syw_slider = r.ImGui_SliderInt(ctx, "Synthesis Window", syw_slider, 0, 3, syw_names[syw_slider])
    if rv then
        rrreeeaaa_params.syw = slider_to_syw[syw_slider]
        changed = true
    end
    
    if changed then
        ApplyRrreeeaaaMode()
    end
end

local function RenderReaReaReaControls()
    local changed = false
    local rv
    
    rv, rearearea_params.snc_checkbox = r.ImGui_Checkbox(ctx, "Tempo Synced", rearearea_params.snc_checkbox)
    if rv then
        rearearea_params.snc = checkbox_to_snc[rearearea_params.snc_checkbox]
        changed = true
    end
    
    if rearearea_params.snc_checkbox then
        local fds_slider = fds_to_slider[rearearea_params.fdm]
        rv, fds_slider = r.ImGui_SliderInt(ctx, "Fade", fds_slider, 0, 23, fds_names[fds_slider])
        if rv then
            rearearea_params.fdm = slider_to_fds[fds_slider]
            changed = true
        end
    else
        local fdm_slider = fdm_to_slider[rearearea_params.fdm]
        rv, fdm_slider = r.ImGui_SliderInt(ctx, "Fade", fdm_slider, 0, 63, fdm_names[fdm_slider])
        if rv then
            rearearea_params.fdm = slider_to_fdm[fdm_slider]
            changed = true
        end
    end
    
    rv, rearearea_params.rnd = r.ImGui_SliderInt(ctx, "Randomize", rearearea_params.rnd, 0, 15, rnd_names[rearearea_params.rnd])
    if rv then
        changed = true
    end
    
    local shp_slider = shp_to_slider[rearearea_params.shp]
    rv, shp_slider = r.ImGui_SliderInt(ctx, "Shape", shp_slider, 0, 2, shp_names[shp_slider])
    if rv then
        rearearea_params.shp = slider_to_shp[shp_slider]
        changed = true
    end
    
    if changed then
        ApplyReaReaReaMode()
    end
end

local function RenderAlgorithmControls(mode)
    if not algorithm_params[mode] then return end
    
    local params = algorithm_params[mode]
    local changed = false
    local rv
    
    if mode == 0 then
        rv, params.quality = r.ImGui_SliderInt(ctx, "Quality", params.quality, 0, 2, soundtouch_quality_names[params.quality + 1])
        if rv then changed = true end
        
        rv, params.channel = r.ImGui_SliderInt(ctx, "Channel", params.channel, 0, 2, soundtouch_channel_names[params.channel + 1])
        if rv then changed = true end
        
    elseif mode == 2 then
        rv, params.ms_window = r.ImGui_SliderInt(ctx, "ms window", params.ms_window, 0, 11, simple_windowed_ms_display[params.ms_window + 1])
        if rv then changed = true end
        
        rv, params.fade_percent = r.ImGui_SliderInt(ctx, "% fade", params.fade_percent, 0, 3, simple_windowed_fade_names[params.fade_percent + 1])
        if rv then changed = true end
        
    elseif mode == 6 or mode == 9 then
        rv, params.preserve_formants = r.ImGui_SliderInt(ctx, "Preserve Formants", params.preserve_formants, 0, 7, elastique_preserve_formants_names[params.preserve_formants + 1])
        if rv then changed = true end
        
        rv, params.synchronized = r.ImGui_Checkbox(ctx, "Synchronized", params.synchronized)
        if rv then changed = true end
        
        rv, params.mid_side = r.ImGui_Checkbox(ctx, "Mid/Side", params.mid_side)
        if rv then changed = true end
        
        rv, params.channel = r.ImGui_SliderInt(ctx, "Channel", params.channel, 0, 2, elastique_channel_names[params.channel + 1])
        if rv then changed = true end
        
    elseif mode == 7 or mode == 10 then
        rv, params.synchronized = r.ImGui_Checkbox(ctx, "Synchronized", params.synchronized)
        if rv then changed = true end
        
        rv, params.mid_side = r.ImGui_Checkbox(ctx, "Mid/Side", params.mid_side)
        if rv then changed = true end
        
        rv, params.channel = r.ImGui_SliderInt(ctx, "Channel", params.channel, 0, 2, elastique_channel_names[params.channel + 1])
        if rv then changed = true end
        
    elseif mode == 8 or mode == 11 then
        rv, params.mode = r.ImGui_SliderInt(ctx, "Mode", params.mode, 0, 1, elastique_soloist_mode_names[params.mode + 1])
        if rv then changed = true end
        
        rv, params.mid_side = r.ImGui_Checkbox(ctx, "Mid/Side", params.mid_side)
        if rv then changed = true end
        
        rv, params.channel = r.ImGui_SliderInt(ctx, "Channel", params.channel, 0, 2, elastique_channel_names[params.channel + 1])
        if rv then changed = true end
    end
    
    if changed then
        ApplyParametricPitchMode(mode)
    end
end

GetCurrentModeFromSelection()
GetStretchMarkerSettings()

local function loop()
    if not _G[script_id] then return end
    if not window_open then return end
    
    r.defer(loop)
    
    GetCurrentModeFromSelection()
    
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoCollapse()
    
    r.ImGui_SetNextWindowSize(ctx, 500, 408, r.ImGui_Cond_Always())
    local visible, open = r.ImGui_Begin(ctx, 'Pitch Shift Selector', true, window_flags)
    window_open = open
    
    if visible then
        local header_font = getStyleFont("header")
        local main_font = getStyleFont("main")
        
        if header_font then r.ImGui_PushFont(ctx, header_font) end
        r.ImGui_Text(ctx, "Pitch Shift Selector")
        if header_font then r.ImGui_PopFont(ctx) end
        if main_font then r.ImGui_PushFont(ctx, main_font) end
        
        r.ImGui_SameLine(ctx)
        local close_x = r.ImGui_GetWindowWidth(ctx) - 30
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", 22, 22) then
            window_open = false
        end
        
        r.ImGui_Separator(ctx)
        
        local content_width = r.ImGui_GetContentRegionAvail(ctx)
        local button_width = (content_width / 3) - 2
        
        if r.ImGui_Button(ctx, "Random Algorithm", button_width, 22) then
            RandomizeAlgorithm()
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Random Submode", button_width, 22) then
            RandomizeSubmode()
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Full Random", button_width, 22) then
            RandomizeFull()
        end
        
        r.ImGui_Separator(ctx)
        
        if r.ImGui_BeginChild(ctx, "main_layout", 0, 0) then
            local child_width = r.ImGui_GetContentRegionAvail(ctx)
            local left_column_width = button_width
            
            if r.ImGui_BeginChild(ctx, "algorithms", left_column_width, 0) then
                r.ImGui_Text(ctx, "Algorithm:")
                r.ImGui_Separator(ctx)
                
                for i, algo in ipairs(ALGORITHMS) do
                    local is_selected = (algo.index == current_mode)
                    
                    if is_selected then
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_ButtonActive()))
                    end
                    
                    if r.ImGui_Button(ctx, algo.name, button_width, 22) then
                        if algo.index == 14 then
                            ApplyRrreeeaaaMode()
                        elseif algo.index == 15 then
                            ApplyReaReaReaMode()
                        elseif algorithm_params[algo.index] then
                            ApplyParametricPitchMode(algo.index)
                        else
                            ApplyBasicPitchMode(algo.index, 0)
                        end
                    end
                    
                    if is_selected then
                        r.ImGui_PopStyleColor(ctx)
                    end
                end
                
                r.ImGui_EndChild(ctx)
            end
            
            r.ImGui_SameLine(ctx)
            
            if r.ImGui_BeginChild(ctx, "right_panel", 0, 0) then
                if r.ImGui_BeginChild(ctx, "options", 0, 256) then
                    r.ImGui_Text(ctx, "Options for current algorithm:")
                    r.ImGui_Separator(ctx)
                    
                    if current_mode == 14 then
                        RenderRrreeeaaaControls()
                    elseif current_mode == 15 then
                        RenderReaReaReaControls()
                    elseif algorithm_params[current_mode] then
                        RenderAlgorithmControls(current_mode)
                    else
                        r.ImGui_Text(ctx, "No specific options for this algorithm")
                    end
                    
                    r.ImGui_EndChild(ctx)
                end
                
                r.ImGui_Text(ctx, "Stretch Markers:")
                r.ImGui_Separator(ctx)
                
                GetStretchMarkerSettings()
                
                local rv
                
                rv, stretch_params.fade_size = r.ImGui_SliderDouble(ctx, "Fade Size (ms)", stretch_params.fade_size, 0.1, 100.0, "%.1f ms")
                if rv then
                    ApplyStretchMarkerSettings()
                end
                
                rv, stretch_params.mode = r.ImGui_SliderInt(ctx, "Mode", stretch_params.mode, 0, 4, stretch_mode_names[stretch_params.mode + 1])
                if rv then
                    ApplyStretchMarkerSettings()
                end
                
                r.ImGui_EndChild(ctx)
            end
            
            r.ImGui_EndChild(ctx)
        end
        
        if main_font then r.ImGui_PopFont(ctx) end
        r.ImGui_End(ctx)
    end
    
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end

    -- if not open then
    --     _G[script_id] = false
    --     return
    -- end
    
    -- r.defer(loop)
end

loop()









