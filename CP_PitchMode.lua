-- @description Advanced Pitch Shift Mode Selector
-- @version 1.0
-- @author Claude
-- @about
--   Provides an intuitive interface to quickly switch between REAPER's pitch shifting algorithms
--   With detailed controls for Rrreeeaaa and ReaReaRea algorithms
--   Based on ReaStretch by Tadej Supukovic (tdspk)

local r = reaper

-- Check if js_ReaScriptAPI and ImGui are available
if not r.APIExists("ImGui_CreateContext") then
    r.ShowMessageBox("This script requires js_ReaScriptAPI with ReaImGui. Please install it via ReaPack.", "Error", 0)
    return
end

-- Style loader integration
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

-- Try to load style loader module
local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

-- Create ImGui context
local ctx = r.ImGui_CreateContext('Advanced Pitch Shift Selector')
local font = r.ImGui_CreateFont('sans-serif', 16)
r.ImGui_Attach(ctx, font)

-- Define all pitch shift algorithms with their actual indices
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

-- Define submodes - for basic algorithms
local MAX_SUBMODES = 60
local SUBMODES = {}

-- Initialize with placeholder submodes for each basic algorithm
for i = -1, 13 do
    SUBMODES[i] = {}
    for j = 0, MAX_SUBMODES - 1 do
        SUBMODES[i][j+1] = { name = "Option " .. j, index = j }
    end
end

-- Initialiser le générateur de nombres aléatoires
math.randomseed(os.time())

-- For Rrreeeaaa and ReaReaRea we'll use special controls instead of submodes

-- Bitmasks for advanced modes (from ReaStretch)
local bitmask = {
  -- Rrreeeaaa
  syn = 7,    -- 0000 0000 0111
  ano = 24,   -- 0000 0001 1000
  fft = 96,   -- 0000 0110 0000
  anw = 384,  -- 0001 0000 0000
  syw = 1536, -- 0110 0000 0000
  -- ReaReaRea
  rnd = 15,   -- 0000 0000 1111
  fdm = 1008,  -- 0011 1111 0000
  shp = 3072,  -- 1100 0000 0000
  snc = 8192, -- 0010 0000 0000 0000
}

-- Mapping Tables for Rrreeeaaa
-- Synthesis
local syn_to_slider = {
  [7] = 3,
  [0] = 4,
  [1] = 5,
  [2] = 6,
  [3] = 7,
  [4] = 8,
  [5] = 9,
  [6] = 10
}

local slider_to_syn = {
  [3] = 7,
  [4] = 0,
  [5] = 1,
  [6] = 2,
  [7] = 3,
  [8] = 4,
  [9] = 5,
  [10] = 6
}

-- FFT
local fft_to_slider = {
  [0] = 0,
  [32] = 1,
  [64] = 2,
  [96] = 3
}

local fft_names = {
  [0] = "FFT: 32768",
  [1] = "FFT: 16364",
  [2] = "FFT: 8192",
  [3] = "FFT: 4096"
}

local slider_to_fft = {
  [0] = 0,
  [1] = 32,
  [2] = 64,
  [3] = 96
}

-- analysis offset
local ano_to_slider = {
  [0] = 0,
  [8] = 1,
  [16] = 2,
  [24] = 3
}

local ano_names = {
  [0] = "1/2",
  [1] = "1/4",
  [2] = "1/6",
  [3] = "1/8"
}

local slider_to_ano = {
  [0] = 0,
  [1] = 8,
  [2] = 16,
  [3] = 24
}

-- Analysis Window
local anw_to_slider = {
  [0] = 0,
  [128] = 1,
  [256] = 2,
  [384] = 3,
}

local anw_names = {
  [0] = "Blackman-Harris",
  [1] = "Hamming",
  [2] = "Blackman",
  [3] = "Rectangular"
}

local slider_to_anw = {
  [0] = 0,
  [1] = 128,
  [2] = 256,
  [3] = 384
}

-- Synthesis Window
local syw_to_slider = {
  [0] = 0,
  [512] = 1,
  [1024] = 2,
  [1536] = 3,
}

local syw_names = {
  [0] = "Blackman-Harris",
  [1] = "Hamming",
  [2] = "Blackman",
  [3] = "Triangular"
}

local slider_to_syw = {
  [0] = 0,
  [1] = 512,
  [2] = 1024,
  [3] = 1536
}

-- Mapping Tables for ReaReaRea
-- Randomize
local rnd_names = {
  [0] = "0",
  [1] = "6",
  [2] = "12",
  [3] = "18",
  [4] = "25",
  [5] = "31",
  [6] = "37",
  [7] = "43",
  [8] = "50",
  [9] = "56",
  [10] = "62",
  [11] = "68",
  [12] = "75",
  [13] = "81",
  [14] = "87",
  [15] = "93"
}

-- ms Fades
local fdm_to_slider = {
  -- Shorter Fade Times
  [912] = 0,
  [928] = 1,
  [944] = 2,
  [960] = 3,
  [976] = 4,
  [992] = 5,
  [1008] = 6,
  [0] = 7,
  [16] = 8,
  [32] = 9,
  [48] = 10,
  [64] = 11,
  [80] = 12,
  [96] = 13,
  [112] = 14,
  [128] = 15,
  [144] = 16,
  [160] = 17,
  [176] = 18,
  [192] = 19,
  -- Longer Fade Times
  [208] = 20,
  [224] = 21,
  [240] = 22,
  [256] = 23,
  [272] = 24,
  [288] = 25,
  [304] = 26,
  [320] = 27,
  [336] = 28,
  [352] = 29,
  [368] = 30,
  [384] = 31,
  [400] = 32,
  [416] = 33,
  [432] = 34,
  [448] = 35,
  [464] = 36,
  [480] = 37,
  [496] = 38,
  [512] = 39,
  [528] = 40,
  [544] = 41,
  [560] = 42,
  [576] = 43,
  [592] = 44,
  [608] = 45,
  [624] = 46,
  [640] = 47,
  [656] = 48,
  [672] = 49,
  [688] = 50,
  [704] = 51,
  [720] = 52,
  [736] = 53,
  [752] = 54,
  [768] = 55,
  [784] = 56,
  [800] = 57,
  [816] = 58,
  [832] = 59,
  [848] = 60,
  [864] = 61,
  [880] = 62,
  [896] = 63
}

local fdm_names = {
  -- Shorter Fade times
  [0] = "2 ms",
  [1] = "4 ms",
  [2] = "6 ms",
  [3] = "8 ms",
  [4] = "12 ms",
  [5] = "24 ms",
  [6] = "36 ms",
  [7] = "48 ms",
  [8] = "60 ms",
  [9] = "72 ms",
  [10] = "84 ms",
  [11] = "96 ms",
  [12] = "108 ms",
  [13] = "120 ms",
  [14] = "132 ms",
  [15] = "144 ms",
  [16] = "156 ms",
  [17] = "168 ms",
  [18] = "180 ms",
  [19] = "192 ms",
  -- Longer Fade Times
  [20] = "204 ms",
  [21] = "216 ms",
  [22] = "228 ms",
  [23] = "240 ms",
  [24] = "252 ms",
  [25] = "264 ms",
  [26] = "276 ms",
  [27] = "288 ms",
  [28] = "300 ms",
  [29] = "312 ms",
  [30] = "324 ms",
  [31] = "336 ms",
  [32] = "348 ms",
  [33] = "360 ms",
  [34] = "372 ms",
  [35] = "384 ms",
  [36] = "396 ms",
  [37] = "408 ms",
  [38] = "420 ms",
  [39] = "432 ms",
  [40] = "448 ms",
  [41] = "472 ms",
  [42] = "496 ms",
  [43] = "520 ms",
  [44] = "544 ms",
  [45] = "568 ms",
  [46] = "592 ms",
  [47] = "616 ms",
  [48] = "640 ms",
  [49] = "664 ms",
  [50] = "688 ms",
  [51] = "712 ms",
  [52] = "736 ms",
  [53] = "760 ms",
  [54] = "784 ms",
  [55] = "808 ms",
  [56] = "832 ms",
  [57] = "856 ms",
  [58] = "880 ms",
  [59] = "904 ms",
  [60] = "928 ms",
  [61] = "952 ms",
  [62] = "976 ms",
  [63] = "1000 ms"
}

local slider_to_fdm = {
  -- Shorter Fade Times
  [0] = 912,
  [1] = 928,
  [2] = 944,
  [3] = 960,
  [4] = 976,
  [5] = 992,
  [6] = 1008,
  [7] = 0,
  [8] = 16,
  [9] = 32,
  [10] = 48,
  [11] = 64,
  [12] = 80,
  [13] = 96,
  [14] = 112,
  [15] = 128,
  [16] = 144,
  [17] = 160,
  [18] = 176,
  [19] = 192,
  -- Longer Fade Times
  [20] = 208,
  [21] = 224,
  [22] = 240,
  [23] = 256,
  [24] = 272,
  [25] = 288,
  [26] = 304,
  [27] = 320,
  [28] = 336,
  [29] = 352,
  [30] = 368,
  [31] = 384,
  [32] = 400,
  [33] = 416,
  [34] = 432,
  [35] = 448,
  [36] = 464,
  [37] = 480,
  [38] = 496,
  [39] = 512,
  [40] = 528,
  [41] = 544,
  [42] = 560,
  [43] = 576,
  [44] = 592,
  [45] = 608,
  [46] = 624,
  [47] = 640,
  [48] = 656,
  [49] = 672,
  [50] = 688,
  [51] = 704,
  [52] = 720,
  [53] = 736,
  [54] = 752,
  [55] = 768,
  [56] = 784,
  [57] = 800,
  [58] = 816,
  [59] = 832,
  [60] = 848,
  [61] = 864,
  [62] = 880,
  [63] = 896
}

-- shape
local shp_to_slider = {
  [0] = 0,
  [1024] = 1,
  [2048] = 2
}

local shp_names = {
  [0] = "sin",
  [1] = "linear",
  [2] = "rectangular"
}

local slider_to_shp = {
  [0] = 0,
  [1] = 1024,
  [2] = 2048
}

-- mapping table for tempo sync on/off
local snc_to_checkbox = {
  [0] = false,
  [8192] = true
}

local checkbox_to_snc = {
  [false] = 0,
  [true] = 8192
}

-- mapping table for tempo sync subdivisions
local fds_to_slider = {
  [0] = 0,
  [128] = 1,
  [256] = 2,
  [16] = 3,
  [144] = 4,
  [272] = 5,
  [32] = 6,
  [160] = 7,
  [288] = 8,
  [48] = 9,
  [176] = 10,
  [304] = 11,
  [64] = 12,
  [192] = 13,
  [320] = 14,
  [80] = 15,
  [208] = 16,
  [336] = 17,
  [96] = 18,
  [224] = 19,
  [352] = 20,
  [112] = 21,
  [240] = 22,
  [368] = 23
}

local fds_names = {
  [0] = "1/128",
  [1] = "1/128t",
  [2] = "1/128d",
  [3] = "1/64",
  [4] = "1/64t",
  [5] = "1/64d",
  [6] = "1/32",
  [7] = "1/32t",
  [8] = "1/32d",
  [9] = "1/16",
  [10] = "1/16t",
  [11] = "1/16d",
  [12] = "1/8",
  [13] = "1/8t",
  [14] = "1/8d",
  [15] = "1/4",
  [16] = "1/4t",
  [17] = "1/4d",
  [18] = "1/2",
  [19] = "1/2t",
  [20] = "1/2d",
  [21] = "1/1",
  [22] = "1/1t",
  [23] = "1/1d"
}

local slider_to_fds = {
  [0] = 0,
  [1] = 128,
  [2] = 256,
  [3] = 16,
  [4] = 144,
  [5] = 272,
  [6] = 32,
  [7] = 160,
  [8] = 288,
  [9] = 48,
  [10] = 176,
  [11] = 304,
  [12] = 64,
  [13] = 192,
  [14] = 320,
  [15] = 80,
  [16] = 208,
  [17] = 336,
  [18] = 96,
  [19] = 224,
  [20] = 352,
  [21] = 112,
  [22] = 240,
  [23] = 368
}

-- Initialize variables
local current_mode = 0
local current_submode = 0
local window_open = true
local dockstate = 0
local show_indices = false

-- Advanced mode parameters
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

-- Function to get current pitch shift mode from selected item (if any)
local function GetCurrentModeFromSelection()
    local selected_item = r.GetSelectedMediaItem(0, 0)
    if not selected_item then return false end
    
    local take = r.GetActiveTake(selected_item)
    if not take or r.TakeIsMIDI(take) then return false end
    
    local pitch_value = r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
    
    -- Extract mode and submode from combined value
    local mode = math.floor(pitch_value / 65536) -- Divide by 2^16
    local submode = pitch_value % 65536
    
    -- For advanced modes, extract the parameter values
    if mode == 14 then -- Rrreeeaaa
        rrreeeaaa_params.syn = submode & bitmask.syn
        rrreeeaaa_params.ano = submode & bitmask.ano
        rrreeeaaa_params.fft = submode & bitmask.fft
        rrreeeaaa_params.anw = submode & bitmask.anw
        rrreeeaaa_params.syw = submode & bitmask.syw
    elseif mode == 15 then -- ReaReaRea
        rearearea_params.rnd = submode & bitmask.rnd
        rearearea_params.fdm = submode & bitmask.fdm
        rearearea_params.shp = submode & bitmask.shp
        rearearea_params.snc = submode & bitmask.snc
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
    end
    
    current_mode = mode
    current_submode = submode
    return true
end

-- Function to apply pitch shift mode for basic algorithms
local function ApplyBasicPitchMode(mode_idx, submode_idx)
    -- Only apply to selected audio items
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    -- Calculate combined value: mode << 16 | submode
    local pitch_value = (mode_idx * 65536) + submode_idx
    
    local applied_count = 0
    for i = 0, item_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
            applied_count = applied_count + 1
        end
    end
    
    r.Undo_EndBlock("Set Pitch Shift Mode", -1)
    r.UpdateArrange()
    
    current_mode = mode_idx
    current_submode = submode_idx
end

-- Apply Rrreeeaaa mode with specific parameters
local function ApplyRrreeeaaaMode()
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    -- Combine all the parameters
    local submode = rrreeeaaa_params.syn + rrreeeaaa_params.ano + rrreeeaaa_params.fft + 
                    rrreeeaaa_params.anw + rrreeeaaa_params.syw
    
    -- Calculate combined value with mode 14 (Rrreeeaaa)
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

-- Apply ReaReaRea mode with specific parameters
local function ApplyReaReaReaMode()
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    -- Combine all the parameters
    local submode = rearearea_params.rnd + rearearea_params.fdm + 
                   rearearea_params.shp + rearearea_params.snc
    
    -- Calculate combined value with mode 15 (ReaReaRea)
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

-- Function to get the maximum number of submodes for basic algorithm
local function GetMaxSubmodeCount(mode_idx)
    -- If we don't know for sure, return a reasonable number
    if mode_idx < -1 or mode_idx > 15 then
        return 5
    end
    
    -- Use the size of our SUBMODES table
    return #SUBMODES[mode_idx]
end

-- Function to render Rrreeeaaa controls
local function RenderRrreeeaaaControls()
    local changed = false
    local rv
    
    -- Get values from parameters
    local syn_slider = syn_to_slider[rrreeeaaa_params.syn]
    rv, syn_slider = r.ImGui_SliderInt(ctx, "Synthesis", syn_slider, 3, 10, "%dx")
    if rv then
        rrreeeaaa_params.syn = slider_to_syn[syn_slider]
        changed = true
    end
    
    r.ImGui_Text(ctx, "")
    
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
    
    -- Apply changes if needed
    if changed then
        ApplyRrreeeaaaMode()
    end
end

-- Function to render ReaReaRea controls
local function RenderReaReaReaControls()
    local changed = false
    local rv
    
    -- Tempo sync checkbox
    rv, rearearea_params.snc_checkbox = r.ImGui_Checkbox(ctx, "Tempo Synced", rearearea_params.snc_checkbox)
    if rv then
        rearearea_params.snc = checkbox_to_snc[rearearea_params.snc_checkbox]
        changed = true
    end
    
    -- Fade slider
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
    
    -- Randomize slider
    rv, rearearea_params.rnd = r.ImGui_SliderInt(ctx, "Randomize", rearearea_params.rnd, 0, 15, rnd_names[rearearea_params.rnd])
    if rv then
        changed = true
    end
    
    -- Shape slider
    local shp_slider = shp_to_slider[rearearea_params.shp]
    rv, shp_slider = r.ImGui_SliderInt(ctx, "Shape", shp_slider, 0, 2, shp_names[shp_slider])
    if rv then
        rearearea_params.shp = slider_to_shp[shp_slider]
        changed = true
    end
    
    -- Apply changes if needed
    if changed then
        ApplyReaReaReaMode()
    end
end

-- Fonction pour sélectionner un algorithme aléatoire
function RandomizeAlgorithm()
    -- Ne pas randomizer si aucun item n'est sélectionné
    if r.CountSelectedMediaItems(0) == 0 then return end
    
    -- Sélectionner un algorithme au hasard
    local random_index = math.random(1, #ALGORITHMS)
    local algo = ALGORITHMS[random_index]
    
    -- Appliquer l'algorithme choisi (mais garder le même sous-mode si possible)
    if algo.index == 14 then -- Rrreeeaaa
        -- Pour Rrreeeaaa, générer des paramètres aléatoires
        rrreeeaaa_params.syn = slider_to_syn[math.random(3, 10)]
        rrreeeaaa_params.fft = slider_to_fft[math.random(0, 3)]
        rrreeeaaa_params.ano = slider_to_ano[math.random(0, 3)]
        rrreeeaaa_params.anw = slider_to_anw[math.random(0, 3)]
        rrreeeaaa_params.syw = slider_to_syw[math.random(0, 3)]
        ApplyRrreeeaaaMode()
    elseif algo.index == 15 then -- ReaReaRea
        -- Pour ReaReaRea, générer des paramètres aléatoires
        rearearea_params.rnd = math.random(0, 15)
        rearearea_params.fdm = slider_to_fdm[math.random(0, 63)]
        rearearea_params.shp = slider_to_shp[math.random(0, 2)]
        rearearea_params.snc = checkbox_to_snc[math.random(0, 1) == 1]
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
        ApplyReaReaReaMode()
    else
        -- Pour les algorithmes de base, appliquer avec le sous-mode 0
        ApplyBasicPitchMode(algo.index, 0)
    end
end

-- Fonction pour sélectionner un sous-mode aléatoire de l'algorithme actuel
function RandomizeSubmode()
    -- Ne pas randomizer si aucun item n'est sélectionné
    if r.CountSelectedMediaItems(0) == 0 then return end

    if current_mode == 14 then -- Rrreeeaaa
        -- Pour Rrreeeaaa, randomizer uniquement les paramètres
        rrreeeaaa_params.syn = slider_to_syn[math.random(3, 10)]
        rrreeeaaa_params.fft = slider_to_fft[math.random(0, 3)]
        rrreeeaaa_params.ano = slider_to_ano[math.random(0, 3)]
        rrreeeaaa_params.anw = slider_to_anw[math.random(0, 3)]
        rrreeeaaa_params.syw = slider_to_syw[math.random(0, 3)]
        ApplyRrreeeaaaMode()
    elseif current_mode == 15 then -- ReaReaRea
        -- Pour ReaReaRea, randomizer uniquement les paramètres
        rearearea_params.rnd = math.random(0, 15)
        
        -- Use a valid index from the table instead of random direct value
        local fdm_indices = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
        local random_fdm_index = fdm_indices[math.random(1, #fdm_indices)]
        rearearea_params.fdm = slider_to_fdm[random_fdm_index]
        
        -- For shape (shp)
        local shp_indices = {0, 1, 2}
        local random_shp_index = shp_indices[math.random(1, #shp_indices)]
        rearearea_params.shp = slider_to_shp[random_shp_index]
        
        -- For sync (snc) - directly use one of the valid values
        local snc_values = {0, 8192}
        rearearea_params.snc = snc_values[math.random(1, 2)]
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
        
        ApplyReaReaReaMode()
    else
        -- Pour les algorithmes de base, choisir un sous-mode aléatoire
        local max_submodes = GetMaxSubmodeCount(current_mode)
        if max_submodes > 0 then
            local random_submode = math.random(0, max_submodes - 1)
            ApplyBasicPitchMode(current_mode, random_submode)
        end
    end
end

-- Fonction pour une randomisation complète (algorithme + sous-mode)
function RandomizeFull()
    -- Ne pas randomizer si aucun item n'est sélectionné
    if r.CountSelectedMediaItems(0) == 0 then return end
    
    -- Choisir un algorithme au hasard
    local random_index = math.random(1, #ALGORITHMS)
    local algo = ALGORITHMS[random_index]
    
    -- Appliquer l'algorithme avec des paramètres aléatoires
    if algo.index == 14 then -- Rrreeeaaa
        rrreeeaaa_params.syn = slider_to_syn[math.random(3, 10)]
        rrreeeaaa_params.fft = slider_to_fft[math.random(0, 3)]
        rrreeeaaa_params.ano = slider_to_ano[math.random(0, 3)]
        rrreeeaaa_params.anw = slider_to_anw[math.random(0, 3)]
        rrreeeaaa_params.syw = slider_to_syw[math.random(0, 3)]
        ApplyRrreeeaaaMode()
    elseif algo.index == 15 then -- ReaReaRea
        rearearea_params.rnd = math.random(0, 15)
        rearearea_params.fdm = slider_to_fdm[math.random(0, 63)]
        rearearea_params.shp = slider_to_shp[math.random(0, 2)]
        rearearea_params.snc = checkbox_to_snc[math.random(0, 1) == 1]
        rearearea_params.snc_checkbox = snc_to_checkbox[rearearea_params.snc]
        ApplyReaReaReaMode()
    else
        -- Pour les algorithmes de base, choisir un sous-mode aléatoire
        local max_submodes = GetMaxSubmodeCount(algo.index)
        local random_submode = 0
        if max_submodes > 0 then
            random_submode = math.random(0, max_submodes - 1)
        end
        ApplyBasicPitchMode(algo.index, random_submode)
    end
end

-- Load stored settings
local function LoadSettings()
    dockstate = tonumber(r.GetExtState("PitchShiftSelector", "dock")) or 0
    
    local last_mode = tonumber(r.GetExtState("PitchShiftSelector", "lastmode"))
    local last_submode = tonumber(r.GetExtState("PitchShiftSelector", "lastsubmode"))
    
    if last_mode and last_mode >= -1 then current_mode = last_mode end
    if last_submode and last_submode >= 0 then current_submode = last_submode end
    
    show_indices = r.GetExtState("PitchShiftSelector", "show_indices") == "1"
end

-- Save settings
local function SaveSettings()
    r.SetExtState("PitchShiftSelector", "dock", tostring(dockstate), true)
    r.SetExtState("PitchShiftSelector", "lastmode", tostring(current_mode), true)
    r.SetExtState("PitchShiftSelector", "lastsubmode", tostring(current_submode), true)
    r.SetExtState("PitchShiftSelector", "show_indices", show_indices and "1" or "0", true)
end

-- Initialize
LoadSettings()

-- Try to get current mode from selection
GetCurrentModeFromSelection()

-- Main loop
local function loop()
    if not window_open then return end
    
    r.defer(loop)
    
    -- Check if selection has changed and update current mode if needed
    GetCurrentModeFromSelection()
    
    -- Apply the global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end
    
    -- Set docking - IMPORTANT: Make sure this is working
    if dockstate ~= 0 then
        r.ImGui_SetNextWindowDockID(ctx, dockstate, r.ImGui_Cond_FirstUseEver())
    end
    
    -- Vérifier si nous essayons activement d'undocker
    local mouse_cap = r.JS_Mouse_GetState(1)
    local is_dragging_title_bar = false

    -- Set up window with the proper flags for docking
    local window_flags = r.ImGui_WindowFlags_None()
    
    local visible, open = r.ImGui_Begin(ctx, 'Advanced Pitch Shift Selector', true, window_flags)
    window_open = open
    
    -- Make sure we're capturing the dock state correctly
    local new_dock_state = r.ImGui_GetWindowDockID(ctx)
    if new_dock_state ~= dockstate then
        dockstate = new_dock_state
        SaveSettings()
    end
    
    if visible then
        local window_width = r.ImGui_GetWindowWidth(ctx)
        
        -- Header section with font
        r.ImGui_PushFont(ctx, font)
        r.ImGui_Text(ctx, "Pitch Shift Algorithms")
        r.ImGui_PopFont(ctx)
        
        -- Selected items info
        local item_count = r.CountSelectedMediaItems(0)
        if item_count == 0 then
            r.ImGui_TextColored(ctx, 0xFF7777FF, "No items selected")
        else
            local audio_items = 0
            for i = 0, item_count - 1 do
                local item = r.GetSelectedMediaItem(0, i)
                local take = r.GetActiveTake(item)
                if take and not r.TakeIsMIDI(take) then
                    audio_items = audio_items + 1
                end
            end
            
            if audio_items == 0 then
                r.ImGui_TextColored(ctx, 0xFF7777FF, "No audio items selected")
            else
                r.ImGui_TextColored(ctx, 0x77FF77FF, audio_items .. " audio item(s) selected")
            end
        end
        
        -- Random buttons section
        r.ImGui_Separator(ctx)
        
        -- Calculer la largeur disponible pour les boutons
        local content_width = r.ImGui_GetContentRegionAvail(ctx)
        local random_button_width = (content_width / 3) - 8 -- Même formule que pour les boutons algo
        
        if r.ImGui_Button(ctx, "Random Algorithm", random_button_width, 30) then
            RandomizeAlgorithm()
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Random Submode", random_button_width, 30) then
            RandomizeSubmode()
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Full Random", random_button_width, 30) then
            RandomizeFull()
        end
        
        r.ImGui_Separator(ctx)
        
        -- Display the algorithms section
        r.ImGui_Text(ctx, "Algorithm:")
        
        -- Create a layout for algorithms with 3 columns that stretch properly
        local algorithms_per_row = 3
        local algo_child_height = 160 -- Hauteur fixe pour la section algorithmes
        
        if r.ImGui_BeginChild(ctx, "algorithms_section", -1, algo_child_height, 0) then
            local child_width = r.ImGui_GetContentRegionAvail(ctx)
            local algo_button_width = (child_width / algorithms_per_row) - 8
            local algo_button_height = 36
            
            for i, algo in ipairs(ALGORITHMS) do
                -- Only add SameLine after first item in each row
                if (i-1) % algorithms_per_row ~= 0 and i > 1 then
                    r.ImGui_SameLine(ctx)
                end
                
                local is_selected = (algo.index == current_mode)
                
                -- Highlight selected algorithm with just ImGui's built-in highlighting
                if is_selected then
                    -- Utiliser le style par défaut du loader ImGui pour les éléments sélectionnés
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_ButtonActive()))
                end
                
                -- Format button label without index
                local button_label = algo.name
                
                -- Create the algorithm button
                if r.ImGui_Button(ctx, button_label, algo_button_width, algo_button_height) then
                    -- Apply the algorithm based on its type
                    if algo.index == 14 then -- Rrreeeaaa
                        ApplyRrreeeaaaMode()
                    elseif algo.index == 15 then -- ReaReaRea
                        ApplyReaReaReaMode()
                    else
                        -- Basic algorithm - apply with first submode
                        ApplyBasicPitchMode(algo.index, 0)
                    end
                end
                
                if is_selected then
                    r.ImGui_PopStyleColor(ctx)
                end
            end
            
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_Separator(ctx)
        
        -- Advanced settings section
        r.ImGui_Text(ctx, "Options for current algorithm:")
        
        -- Create a scrollable area for options
        if r.ImGui_BeginChild(ctx, "options_section", -1, 180, 0) then
            
            -- Select the appropriate controls based on the current mode
            if current_mode == 14 then -- Rrreeeaaa
                RenderRrreeeaaaControls()
            elseif current_mode == 15 then -- ReaReaRea
                RenderReaReaReaControls() 
            else
                -- For basic algorithms, show standard submodes
                local max_submodes = GetMaxSubmodeCount(current_mode)
                
                if max_submodes > 0 then
                    -- Calculate available space and fit 4 submodes per row comfortably
                    local child_width = r.ImGui_GetContentRegionAvail(ctx)
                    local submodes_per_row = 4
                    local submode_button_width = (child_width / submodes_per_row) - 8
                    local submode_button_height = 36
                    
                    -- Display submodes for basic algorithms
                    for i = 0, max_submodes - 1 do
                        -- Only add SameLine after first item in each row
                        if i % submodes_per_row ~= 0 and i > 0 then
                            r.ImGui_SameLine(ctx)
                        end
                        
                        local is_selected = (i == current_submode)
                        
                        -- Highlight selected submode with built-in ImGui highlighting
                        if is_selected then
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_ButtonActive()))
                        end
                        
                        -- Create button label
                        local button_label = "Option " .. i
                        
                        -- Create the submode button
                        if r.ImGui_Button(ctx, button_label, submode_button_width, submode_button_height) then
                            ApplyBasicPitchMode(current_mode, i)
                        end
                        
                        if is_selected then
                            r.ImGui_PopStyleColor(ctx)
                        end
                    end
                else
                    r.ImGui_Text(ctx, "No submodes available for this algorithm")
                end
            end
            
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_Separator(ctx)
        
        r.ImGui_End(ctx)
    end
    
    -- Clean up the styles we applied
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end
end

-- Start the loop
loop()

-- Register a function to run when the script is terminated
local function exit()
    SaveSettings()
end

r.atexit(exit)