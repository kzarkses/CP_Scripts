-- CP_Inspector PitchStretch — Pitch algorithm selector + stretch marker settings
-- 1:1 port of CP_PitchShiftSelector.lua to CP_Toolkit

local PitchStretch = {}
local r = reaper

local SCRIPT_ID = "CP_PitchShiftSelector"  -- keep old key for ExtState compat

-- ============================================================================
-- CONFIG (persisted)
-- ============================================================================
PitchStretch.config = {
    stretch_fade_size = 2.0,
    stretch_mode = 0,
}

-- ============================================================================
-- STATE (live)
-- ============================================================================
PitchStretch.state = {
    current_mode = 0,
    current_submode = 0,
    rrreeeaaa_params = { syn = 0, ano = 0, fft = 0, anw = 0, syw = 0 },
    rearearea_params = { rnd = 0, fdm = 0, shp = 0, snc = 0, snc_checkbox = false },
    stretch_slope = 0.0,
}

-- Per-algorithm parameter state (for parametric modes: SoundTouch, Simple
-- Windowed, Elastique 2/3 Pro/Efficient/Soloist)
local algorithm_params = {
    [0]  = { quality = 0, channel = 0 },
    [2]  = { ms_window = 6, fade_percent = 0 },
    [6]  = { preserve_formants = 0, synchronized = false, mid_side = false, channel = 0 },
    [7]  = { synchronized = false, mid_side = false, channel = 0 },
    [8]  = { mode = 0, mid_side = false, channel = 0 },
    [9]  = { preserve_formants = 0, synchronized = false, mid_side = false, channel = 0 },
    [10] = { synchronized = false, mid_side = false, channel = 0 },
    [11] = { mode = 0, mid_side = false, channel = 0 },
}

-- ============================================================================
-- DATA TABLES — bitmasks + slider↔value mappings + display names
-- ============================================================================
local ALGORITHMS = {}  -- filled in Init() from core.PITCH_ALGORITHMS

local bitmask = {
    syn = 7, ano = 24, fft = 96, anw = 384, syw = 1536,
    rnd = 15, fdm = 1008, shp = 3072, snc = 8192,
}

local syn_to_slider = { [7]=3, [0]=4, [1]=5, [2]=6, [3]=7, [4]=8, [5]=9, [6]=10 }
local slider_to_syn = { [3]=7, [4]=0, [5]=1, [6]=2, [7]=3, [8]=4, [9]=5, [10]=6 }

local fft_to_slider = { [0]=0, [32]=1, [64]=2, [96]=3 }
local fft_names     = { [0]="FFT: 32768", [1]="FFT: 16364", [2]="FFT: 8192", [3]="FFT: 4096" }
local slider_to_fft = { [0]=0, [1]=32, [2]=64, [3]=96 }

local ano_to_slider = { [0]=0, [8]=1, [16]=2, [24]=3 }
local ano_names     = { [0]="1/2", [1]="1/4", [2]="1/6", [3]="1/8" }
local slider_to_ano = { [0]=0, [1]=8, [2]=16, [3]=24 }

local anw_to_slider = { [0]=0, [128]=1, [256]=2, [384]=3 }
local anw_names     = { [0]="Blackman-Harris", [1]="Hamming", [2]="Blackman", [3]="Rectangular" }
local slider_to_anw = { [0]=0, [1]=128, [2]=256, [3]=384 }

local syw_to_slider = { [0]=0, [512]=1, [1024]=2, [1536]=3 }
local syw_names     = { [0]="Blackman-Harris", [1]="Hamming", [2]="Blackman", [3]="Triangular" }
local slider_to_syw = { [0]=0, [1]=512, [2]=1024, [3]=1536 }

local rnd_names = {
    [0]="0", [1]="6", [2]="12", [3]="18", [4]="25", [5]="31", [6]="37", [7]="43",
    [8]="50", [9]="56", [10]="62", [11]="68", [12]="75", [13]="81", [14]="87", [15]="93",
}

local fdm_to_slider = {
    [912]=0,[928]=1,[944]=2,[960]=3,[976]=4,[992]=5,[1008]=6,[0]=7,
    [16]=8,[32]=9,[48]=10,[64]=11,[80]=12,[96]=13,[112]=14,[128]=15,
    [144]=16,[160]=17,[176]=18,[192]=19,[208]=20,[224]=21,[240]=22,[256]=23,
    [272]=24,[288]=25,[304]=26,[320]=27,[336]=28,[352]=29,[368]=30,[384]=31,
    [400]=32,[416]=33,[432]=34,[448]=35,[464]=36,[480]=37,[496]=38,[512]=39,
    [528]=40,[544]=41,[560]=42,[576]=43,[592]=44,[608]=45,[624]=46,[640]=47,
    [656]=48,[672]=49,[688]=50,[704]=51,[720]=52,[736]=53,[752]=54,[768]=55,
    [784]=56,[800]=57,[816]=58,[832]=59,[848]=60,[864]=61,[880]=62,[896]=63,
}
local fdm_names = {
    [0]="2 ms",[1]="4 ms",[2]="6 ms",[3]="8 ms",[4]="12 ms",[5]="24 ms",[6]="36 ms",[7]="48 ms",
    [8]="60 ms",[9]="72 ms",[10]="84 ms",[11]="96 ms",[12]="108 ms",[13]="120 ms",[14]="132 ms",[15]="144 ms",
    [16]="156 ms",[17]="168 ms",[18]="180 ms",[19]="192 ms",[20]="204 ms",[21]="216 ms",[22]="228 ms",[23]="240 ms",
    [24]="252 ms",[25]="264 ms",[26]="276 ms",[27]="288 ms",[28]="300 ms",[29]="312 ms",[30]="324 ms",[31]="336 ms",
    [32]="348 ms",[33]="360 ms",[34]="372 ms",[35]="384 ms",[36]="396 ms",[37]="408 ms",[38]="420 ms",[39]="432 ms",
    [40]="448 ms",[41]="472 ms",[42]="496 ms",[43]="520 ms",[44]="544 ms",[45]="568 ms",[46]="592 ms",[47]="616 ms",
    [48]="640 ms",[49]="664 ms",[50]="688 ms",[51]="712 ms",[52]="736 ms",[53]="760 ms",[54]="784 ms",[55]="808 ms",
    [56]="832 ms",[57]="856 ms",[58]="880 ms",[59]="904 ms",[60]="928 ms",[61]="952 ms",[62]="976 ms",[63]="1000 ms",
}
local slider_to_fdm = {
    [0]=912,[1]=928,[2]=944,[3]=960,[4]=976,[5]=992,[6]=1008,[7]=0,
    [8]=16,[9]=32,[10]=48,[11]=64,[12]=80,[13]=96,[14]=112,[15]=128,
    [16]=144,[17]=160,[18]=176,[19]=192,[20]=208,[21]=224,[22]=240,[23]=256,
    [24]=272,[25]=288,[26]=304,[27]=320,[28]=336,[29]=352,[30]=368,[31]=384,
    [32]=400,[33]=416,[34]=432,[35]=448,[36]=464,[37]=480,[38]=496,[39]=512,
    [40]=528,[41]=544,[42]=560,[43]=576,[44]=592,[45]=608,[46]=624,[47]=640,
    [48]=656,[49]=672,[50]=688,[51]=704,[52]=720,[53]=736,[54]=752,[55]=768,
    [56]=784,[57]=800,[58]=816,[59]=832,[60]=848,[61]=864,[62]=880,[63]=896,
}

local shp_to_slider = { [0]=0, [1024]=1, [2048]=2 }
local shp_names     = { [0]="sin", [1]="linear", [2]="rectangular" }
local slider_to_shp = { [0]=0, [1]=1024, [2]=2048 }

local snc_to_checkbox = { [0]=false, [8192]=true }
local checkbox_to_snc = { [false]=0, [true]=8192 }

local fds_to_slider = {
    [0]=0,[128]=1,[256]=2,[16]=3,[144]=4,[272]=5,[32]=6,[160]=7,[288]=8,[48]=9,[176]=10,[304]=11,
    [64]=12,[192]=13,[320]=14,[80]=15,[208]=16,[336]=17,[96]=18,[224]=19,[352]=20,[112]=21,[240]=22,[368]=23,
}
local fds_names = {
    [0]="1/128",[1]="1/128t",[2]="1/128d",[3]="1/64",[4]="1/64t",[5]="1/64d",[6]="1/32",[7]="1/32t",[8]="1/32d",
    [9]="1/16",[10]="1/16t",[11]="1/16d",[12]="1/8",[13]="1/8t",[14]="1/8d",[15]="1/4",[16]="1/4t",[17]="1/4d",
    [18]="1/2",[19]="1/2t",[20]="1/2d",[21]="1/1",[22]="1/1t",[23]="1/1d",
}
local slider_to_fds = {
    [0]=0,[1]=128,[2]=256,[3]=16,[4]=144,[5]=272,[6]=32,[7]=160,[8]=288,[9]=48,[10]=176,[11]=304,
    [12]=64,[13]=192,[14]=320,[15]=80,[16]=208,[17]=336,[18]=96,[19]=224,[20]=352,[21]=112,[22]=240,[23]=368,
}

local soundtouch_quality_names = { "Default settings", "High Quality", "Fast" }
local soundtouch_channel_names = { "Multichannel", "Multi-stereo", "Multi-mono" }

local simple_windowed_ms_display = { "3ms","5ms","10ms","20ms","30ms","40ms","50ms","75ms","100ms","150ms","225ms","300ms" }
local simple_windowed_ms_mapping = { 11, 10, 9, 8, 7, 6, 0, 1, 2, 3, 4, 5 }
local simple_windowed_fade_names = { "50%", "33%", "20%", "14%" }

local elastique_preserve_formants_names = {
    "Normal","Lowest Pitches","Lower Pitches","Lower Pitches",
    "Most Pitches","High Pitches","Higher Pitches","Highest Pitches",
}
local elastique_channel_names = { "Multichannel", "Multi-Stereo", "Multi-Mono" }
local elastique_soloist_mode_names = { "Monophonic", "Speech" }

local stretch_mode_names = {
    "Project default", "Balanced", "Tonal-optimized",
    "Transient-optimized", "No pre-echo reduction",
}
local stretch_mode_actions = { -1, 42338, 41857, 42337, 42339 }

-- ============================================================================
-- SETTINGS PERSISTENCE
-- ============================================================================
local function SaveSettings()
    for key, value in pairs(PitchStretch.config) do
        local s = tostring(value)
        if type(value) == "boolean" then s = value and "1" or "0" end
        r.SetExtState(SCRIPT_ID, "config_" .. key, s, true)
    end
end

local function LoadSettings()
    for key, default in pairs(PitchStretch.config) do
        local saved = r.GetExtState(SCRIPT_ID, "config_" .. key)
        if saved ~= "" then
            if type(default) == "number" then
                PitchStretch.config[key] = tonumber(saved) or default
            elseif type(default) == "boolean" then
                PitchStretch.config[key] = saved == "1"
            else
                PitchStretch.config[key] = saved
            end
        end
    end
end

-- ============================================================================
-- SUBMODE CODEC
-- ============================================================================
local function DecomposeSubmode(mode, submode)
    if mode == 0 then
        algorithm_params[0].channel = math.floor(submode / 3)
        algorithm_params[0].quality = submode % 3
    elseif mode == 2 then
        local real_ms = math.floor(submode / 4)
        local visual = 0
        for i, real_idx in ipairs(simple_windowed_ms_mapping) do
            if real_idx == real_ms then visual = i - 1 break end
        end
        algorithm_params[2].ms_window = visual
        algorithm_params[2].fade_percent = submode % 4
    elseif mode == 6 or mode == 9 then
        local base  = submode % 8
        local flags = math.floor(submode / 8)
        local p = algorithm_params[mode]
        p.preserve_formants = base
        p.synchronized = (flags & 2) ~= 0
        p.mid_side     = (flags & 1) ~= 0
        p.channel      = (flags & 12) >> 2
    elseif mode == 7 or mode == 10 then
        local p = algorithm_params[mode]
        p.synchronized = (submode & 2) ~= 0
        p.mid_side     = (submode & 1) ~= 0
        p.channel      = (submode & 12) >> 2
    elseif mode == 8 or mode == 11 then
        local p = algorithm_params[mode]
        p.mode     = (submode & 2) ~= 0 and 1 or 0
        p.mid_side = (submode & 1) ~= 0
        p.channel  = (submode & 12) >> 2
    end
end

local function ComposeSubmode(mode)
    if mode == 0 then
        return algorithm_params[0].channel * 3 + algorithm_params[0].quality
    elseif mode == 2 then
        local visual = algorithm_params[2].ms_window
        local real_ms = simple_windowed_ms_mapping[visual + 1]
        return real_ms * 4 + algorithm_params[2].fade_percent
    elseif mode == 6 or mode == 9 then
        local p = algorithm_params[mode]
        local flags = 0
        if p.mid_side     then flags = flags | 1 end
        if p.synchronized then flags = flags | 2 end
        flags = flags | (p.channel << 2)
        return p.preserve_formants + (flags << 3)
    elseif mode == 7 or mode == 10 then
        local p = algorithm_params[mode]
        local flags = 0
        if p.mid_side     then flags = flags | 1 end
        if p.synchronized then flags = flags | 2 end
        flags = flags | (p.channel << 2)
        return flags
    elseif mode == 8 or mode == 11 then
        local p = algorithm_params[mode]
        local flags = p.mid_side and 1 or 0
        if p.mode == 1 then flags = flags | 2 end
        flags = flags | (p.channel << 2)
        return flags
    end
    return 0
end

-- ============================================================================
-- SELECTION POLLING
-- ============================================================================
local function GetCurrentModeFromSelection()
    local item = r.GetSelectedMediaItem(0, 0)
    if not item then return false end
    local take = r.GetActiveTake(item)
    if not take or r.TakeIsMIDI(take) then return false end

    local pitch_value = r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
    if pitch_value < 0 then
        PitchStretch.state.current_mode = -1
        PitchStretch.state.current_submode = 0
        return true
    end

    local mode = math.floor(pitch_value / 65536)
    local submode = pitch_value % 65536

    if mode == 14 then
        local p = PitchStretch.state.rrreeeaaa_params
        p.syn = submode & bitmask.syn
        p.ano = submode & bitmask.ano
        p.fft = submode & bitmask.fft
        p.anw = submode & bitmask.anw
        p.syw = submode & bitmask.syw
    elseif mode == 15 then
        local p = PitchStretch.state.rearearea_params
        p.rnd = submode & bitmask.rnd
        p.fdm = submode & bitmask.fdm
        p.shp = submode & bitmask.shp
        p.snc = submode & bitmask.snc
        p.snc_checkbox = snc_to_checkbox[p.snc] or false
    elseif algorithm_params[mode] then
        DecomposeSubmode(mode, submode)
    end

    PitchStretch.state.current_mode = mode
    PitchStretch.state.current_submode = submode
    return true
end

-- ============================================================================
-- STRETCH MARKER SETTINGS (SNM config vars)
-- ============================================================================
local function GetStretchMarkerSettings()
    if r.SNM_GetDoubleConfigVar then
        local fade = r.SNM_GetDoubleConfigVar("smfadesize", -1)
        if fade >= 0 then
            PitchStretch.config.stretch_fade_size = fade * 1000
        end
    end
end

local function ApplyStretchMarkerSettings()
    if r.SNM_SetDoubleConfigVar then
        r.SNM_SetDoubleConfigVar("smfadesize", PitchStretch.config.stretch_fade_size / 1000)
    end
    local action = stretch_mode_actions[PitchStretch.config.stretch_mode + 1]
    if action and action > 0 then
        r.Main_OnCommand(action, 0)
    end
    -- Settings persisted on script close via UI.OnClose, not here (avoid hot-path ExtState writes).
end

-- ============================================================================
-- APPLY PITCH MODE
-- ============================================================================
local function ApplyBasicPitchMode(mode_idx, submode_idx)
    local count = r.CountSelectedMediaItems(0)
    if count == 0 then return end
    r.Undo_BeginBlock()
    local pitch_value = (mode_idx == -1) and -1 or (mode_idx * 65536 + submode_idx)
    for i = 0, count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    r.Undo_EndBlock("Set Pitch Shift Mode", -1)
    r.UpdateArrange()
    PitchStretch.state.current_mode = mode_idx
    PitchStretch.state.current_submode = submode_idx
end

local function ApplyParametricPitchMode(mode_idx)
    local count = r.CountSelectedMediaItems(0)
    if count == 0 then return end
    r.Undo_BeginBlock()
    local submode = ComposeSubmode(mode_idx)
    local pitch_value = mode_idx * 65536 + submode
    for i = 0, count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    r.Undo_EndBlock("Set Pitch Shift Parameters", -1)
    r.UpdateArrange()
    PitchStretch.state.current_mode = mode_idx
    PitchStretch.state.current_submode = submode
end

local function ApplyRrreeeaaaMode()
    local count = r.CountSelectedMediaItems(0)
    if count == 0 then return end
    r.Undo_BeginBlock()
    local p = PitchStretch.state.rrreeeaaa_params
    local submode = p.syn + p.ano + p.fft + p.anw + p.syw
    local pitch_value = 14 * 65536 + submode
    for i = 0, count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    r.Undo_EndBlock("Set Rrreeeaaa Parameters", -1)
    r.UpdateArrange()
    PitchStretch.state.current_mode = 14
    PitchStretch.state.current_submode = submode
end

local function ApplyReaReaReaMode()
    local count = r.CountSelectedMediaItems(0)
    if count == 0 then return end
    r.Undo_BeginBlock()
    local p = PitchStretch.state.rearearea_params
    local submode = p.rnd + p.fdm + p.shp + p.snc
    local pitch_value = 15 * 65536 + submode
    for i = 0, count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    r.Undo_EndBlock("Set ReaReaRea Parameters", -1)
    r.UpdateArrange()
    PitchStretch.state.current_mode = 15
    PitchStretch.state.current_submode = submode
end

local function ApplyAlgorithmByIndex(algo_idx)
    if algo_idx == 14 then
        ApplyRrreeeaaaMode()
    elseif algo_idx == 15 then
        ApplyReaReaReaMode()
    elseif algorithm_params[algo_idx] then
        ApplyParametricPitchMode(algo_idx)
    else
        ApplyBasicPitchMode(algo_idx, 0)
    end
end

-- ============================================================================
-- RANDOMIZE
-- ============================================================================
local function RandomizeParamsForAlgo(algo_idx)
    if algo_idx == 14 then
        local p = PitchStretch.state.rrreeeaaa_params
        p.syn = slider_to_syn[math.random(3, 10)]
        p.fft = slider_to_fft[math.random(0, 3)]
        p.ano = slider_to_ano[math.random(0, 3)]
        p.anw = slider_to_anw[math.random(0, 3)]
        p.syw = slider_to_syw[math.random(0, 3)]
    elseif algo_idx == 15 then
        local p = PitchStretch.state.rearearea_params
        p.rnd = math.random(0, 15)
        p.fdm = slider_to_fdm[math.random(0, 63)]
        p.shp = slider_to_shp[math.random(0, 2)]
        local snc_bool = math.random(0, 1) == 1
        p.snc = checkbox_to_snc[snc_bool]
        p.snc_checkbox = snc_bool
    elseif algorithm_params[algo_idx] then
        local p = algorithm_params[algo_idx]
        if algo_idx == 0 then
            p.channel = math.random(0, 2); p.quality = math.random(0, 2)
        elseif algo_idx == 2 then
            p.ms_window = math.random(0, 11); p.fade_percent = math.random(0, 3)
        elseif algo_idx == 6 or algo_idx == 9 then
            p.preserve_formants = math.random(0, 7)
            p.synchronized = math.random(0, 1) == 1
            p.mid_side     = math.random(0, 1) == 1
            p.channel      = math.random(0, 2)
        elseif algo_idx == 7 or algo_idx == 10 then
            p.synchronized = math.random(0, 1) == 1
            p.mid_side     = math.random(0, 1) == 1
            p.channel      = math.random(0, 2)
        elseif algo_idx == 8 or algo_idx == 11 then
            p.mode     = math.random(0, 1)
            p.mid_side = math.random(0, 1) == 1
            p.channel  = math.random(0, 2)
        end
    end
end

local function RandomizeAlgorithm()
    if r.CountSelectedMediaItems(0) == 0 then return end
    local algo = ALGORITHMS[math.random(1, #ALGORITHMS)]
    RandomizeParamsForAlgo(algo.index)
    ApplyAlgorithmByIndex(algo.index)
end

local function RandomizeSubmode()
    if r.CountSelectedMediaItems(0) == 0 then return end
    local mode = PitchStretch.state.current_mode
    if mode < 0 then return end
    RandomizeParamsForAlgo(mode)
    ApplyAlgorithmByIndex(mode)
end

local function RandomizeFull()
    RandomizeAlgorithm()
end

-- ============================================================================
-- PER-ALGORITHM CONTROL RENDERING
-- ============================================================================
local function RenderAlgorithmControls(UI, theme, mode)
    local p = algorithm_params[mode]
    if not p then return end
    local changed = false
    local rv, nv

    if mode == 0 then
        rv, nv = UI.SliderInt("pst_st_q", "Quality", p.quality, 0, 2,
            { format = soundtouch_quality_names[p.quality + 1] })
        if rv then p.quality = nv; changed = true end
        rv, nv = UI.SliderInt("pst_st_c", "Channel", p.channel, 0, 2,
            { format = soundtouch_channel_names[p.channel + 1] })
        if rv then p.channel = nv; changed = true end

    elseif mode == 2 then
        rv, nv = UI.SliderInt("pst_sw_ms", "ms window", p.ms_window, 0, 11,
            { format = simple_windowed_ms_display[p.ms_window + 1] })
        if rv then p.ms_window = nv; changed = true end
        rv, nv = UI.SliderInt("pst_sw_fd", "% fade", p.fade_percent, 0, 3,
            { format = simple_windowed_fade_names[p.fade_percent + 1] })
        if rv then p.fade_percent = nv; changed = true end

    elseif mode == 6 or mode == 9 then
        rv, nv = UI.SliderInt("pst_el_pf_"..mode, "Preserve Formants", p.preserve_formants, 0, 7,
            { format = elastique_preserve_formants_names[p.preserve_formants + 1] })
        if rv then p.preserve_formants = nv; changed = true end
        rv, nv = UI.Checkbox("pst_el_sync_"..mode, "Synchronized", p.synchronized)
        if rv then p.synchronized = nv; changed = true end
        rv, nv = UI.Checkbox("pst_el_ms_"..mode, "Mid/Side", p.mid_side)
        if rv then p.mid_side = nv; changed = true end
        rv, nv = UI.SliderInt("pst_el_ch_"..mode, "Channel", p.channel, 0, 2,
            { format = elastique_channel_names[p.channel + 1] })
        if rv then p.channel = nv; changed = true end

    elseif mode == 7 or mode == 10 then
        rv, nv = UI.Checkbox("pst_el_sync_"..mode, "Synchronized", p.synchronized)
        if rv then p.synchronized = nv; changed = true end
        rv, nv = UI.Checkbox("pst_el_ms_"..mode, "Mid/Side", p.mid_side)
        if rv then p.mid_side = nv; changed = true end
        rv, nv = UI.SliderInt("pst_el_ch_"..mode, "Channel", p.channel, 0, 2,
            { format = elastique_channel_names[p.channel + 1] })
        if rv then p.channel = nv; changed = true end

    elseif mode == 8 or mode == 11 then
        rv, nv = UI.SliderInt("pst_sl_m_"..mode, "Mode", p.mode, 0, 1,
            { format = elastique_soloist_mode_names[p.mode + 1] })
        if rv then p.mode = nv; changed = true end
        rv, nv = UI.Checkbox("pst_sl_ms_"..mode, "Mid/Side", p.mid_side)
        if rv then p.mid_side = nv; changed = true end
        rv, nv = UI.SliderInt("pst_sl_ch_"..mode, "Channel", p.channel, 0, 2,
            { format = elastique_channel_names[p.channel + 1] })
        if rv then p.channel = nv; changed = true end
    end

    if changed then ApplyParametricPitchMode(mode) end
end

local function RenderRrreeeaaaControls(UI, theme)
    local p = PitchStretch.state.rrreeeaaa_params
    local changed = false
    local rv, nv

    local syn_s = syn_to_slider[p.syn] or 3
    rv, nv = UI.SliderInt("pst_rr_syn", "Synthesis", syn_s, 3, 10, { format = syn_s .. "x" })
    if rv then p.syn = slider_to_syn[nv]; changed = true end

    local fft_s = fft_to_slider[p.fft] or 0
    rv, nv = UI.SliderInt("pst_rr_fft", "FFT", fft_s, 0, 3, { format = fft_names[fft_s] })
    if rv then p.fft = slider_to_fft[nv]; changed = true end

    local ano_s = ano_to_slider[p.ano] or 0
    rv, nv = UI.SliderInt("pst_rr_ano", "Analysis Offset", ano_s, 0, 3, { format = ano_names[ano_s] })
    if rv then p.ano = slider_to_ano[nv]; changed = true end

    local anw_s = anw_to_slider[p.anw] or 0
    rv, nv = UI.SliderInt("pst_rr_anw", "Analysis Window", anw_s, 0, 3, { format = anw_names[anw_s] })
    if rv then p.anw = slider_to_anw[nv]; changed = true end

    local syw_s = syw_to_slider[p.syw] or 0
    rv, nv = UI.SliderInt("pst_rr_syw", "Synthesis Window", syw_s, 0, 3, { format = syw_names[syw_s] })
    if rv then p.syw = slider_to_syw[nv]; changed = true end

    if changed then ApplyRrreeeaaaMode() end
end

local function RenderReaReaReaControls(UI, theme)
    local p = PitchStretch.state.rearearea_params
    local changed = false
    local rv, nv

    rv, nv = UI.Checkbox("pst_re_snc", "Tempo Synced", p.snc_checkbox)
    if rv then
        p.snc_checkbox = nv
        p.snc = checkbox_to_snc[nv]
        changed = true
    end

    if p.snc_checkbox then
        local fds_s = fds_to_slider[p.fdm] or 0
        rv, nv = UI.SliderInt("pst_re_fds", "Fade", fds_s, 0, 23, { format = fds_names[fds_s] })
        if rv then p.fdm = slider_to_fds[nv]; changed = true end
    else
        local fdm_s = fdm_to_slider[p.fdm] or 0
        rv, nv = UI.SliderInt("pst_re_fdm", "Fade", fdm_s, 0, 63, { format = fdm_names[fdm_s] })
        if rv then p.fdm = slider_to_fdm[nv]; changed = true end
    end

    rv, nv = UI.SliderInt("pst_re_rnd", "Randomize", p.rnd, 0, 15, { format = rnd_names[p.rnd] })
    if rv then p.rnd = nv; changed = true end

    local shp_s = shp_to_slider[p.shp] or 0
    rv, nv = UI.SliderInt("pst_re_shp", "Shape", shp_s, 0, 2, { format = shp_names[shp_s] })
    if rv then p.shp = slider_to_shp[nv]; changed = true end

    if changed then ApplyReaReaReaMode() end
end

-- ============================================================================
-- INIT
-- ============================================================================
function PitchStretch.Init(core)
    for i, algo in ipairs(core.PITCH_ALGORITHMS) do
        ALGORITHMS[i] = { name = algo.name, index = algo.index }
    end
    math.randomseed(os.time())
    LoadSettings()
    GetStretchMarkerSettings()
end

-- ============================================================================
-- MAIN DRAW (3-panel layout matching old MPT version)
-- ============================================================================
function PitchStretch.Draw(UI, theme)
    -- Poll current state from selection every frame (for external changes)
    GetCurrentModeFromSelection()
    GetStretchMarkerSettings()

    local s = PitchStretch.state
    local cfg = PitchStretch.config
    local spacing = theme.item_spacing
    local avail_w = UI.Layout.GetAvailableWidth()
    local btn_w   = math.floor((avail_w - 2 * spacing) / 3)

    -- ---- TOP: 3 random buttons ----
    if UI.Button("pst_rand_algo", "Random Algorithm", { width = btn_w }) then
        RandomizeAlgorithm()
    end
    UI.SameLine()
    if UI.Button("pst_rand_sub", "Random Submode", { width = btn_w }) then
        RandomizeSubmode()
    end
    UI.SameLine()
    if UI.Button("pst_rand_full", "Full Random", { width = btn_w }) then
        RandomizeFull()
    end

    UI.Spacing(2)
    UI.Separator()
    UI.Spacing(2)

    -- ---- MAIN LAYOUT: left column (algo list) + right column (options+stretch) ----
    local left_w = btn_w  -- 1/3 of window width
    local avail_h = UI.Layout.GetAvailableHeight and UI.Layout.GetAvailableHeight() or 0

    UI.BeginChild("pst_left", left_w, avail_h, { border = false, scrollable = false })
    UI.Text("Algorithm:")
    UI.Spacing(2)
    UI.Separator()
    UI.Spacing(2)
    for i, algo in ipairs(ALGORITHMS) do
        local selected = (algo.index == s.current_mode)
        if UI.Button("pst_algo_" .. i, algo.name, { width = left_w - 12, selected = selected }) then
            ApplyAlgorithmByIndex(algo.index)
        end
    end
    UI.EndChild()

    UI.SameLine()

    UI.BeginChild("pst_right", 0, avail_h, { border = false, scrollable = false })
    UI.Text("Options for current algorithm:")
    UI.Spacing(2)
    UI.Separator()
    UI.Spacing(2)

    if s.current_mode == 14 then
        RenderRrreeeaaaControls(UI, theme)
    elseif s.current_mode == 15 then
        RenderReaReaReaControls(UI, theme)
    elseif algorithm_params[s.current_mode] then
        RenderAlgorithmControls(UI, theme, s.current_mode)
    else
        UI.Text("No specific options for this algorithm", { disabled = true })
    end

    UI.Spacing(12)
    UI.Text("Stretch Marker Settings:")
    UI.Spacing(2)
    UI.Separator()
    UI.Spacing(2)

    local sc, sv = UI.SliderDouble("pst_sm_fade", "Fade Size (ms)", cfg.stretch_fade_size, 0.1, 100.0,
        { format = string.format("%.1f ms", cfg.stretch_fade_size) })
    if sc then
        cfg.stretch_fade_size = sv
        ApplyStretchMarkerSettings()
    end

    local mc, mv = UI.SliderInt("pst_sm_mode", "Mode", cfg.stretch_mode, 0, 4,
        { format = stretch_mode_names[cfg.stretch_mode + 1] })
    if mc then
        cfg.stretch_mode = mv
        ApplyStretchMarkerSettings()
    end

    UI.EndChild()
end

-- Save settings when script closes (caller should hook UI.OnClose)
PitchStretch.SaveSettings = SaveSettings

return PitchStretch
