-- CP_SampleEditor — Ops
-- Non-destructive item/take operations + peaks-based audio analysis.
--
-- Analysis policy: everything reads PCM_Source_GetPeaks — one data path
-- that works for arrange items AND raw browser files (no take needed, no
-- AudioAccessor ambiguity about take volume). Peaks at 1000/s are exact
-- min/max envelopes (plenty for normalize + transient slicing); zero-cross
-- snapping reads a tiny window at the file samplerate (peakrate = sr gives
-- per-sample values).
--
-- All item ops mint their own undo points (item-scoped — these are pure
-- item/take property edits, no track changes).

local Ops = {}

local r     -- reaper, injected
local Wave  -- pooled array provider (Wave.Array)

function Ops.init(reaper_api, wave_module)
    r    = reaper_api
    Wave = wave_module
end

local ANALYSIS_RATE = 1000      -- peaks/s for scans (1ms resolution)
local MAX_SCAN      = 120000    -- cap: 2 minutes of audio per scan

-- ---------------------------------------------------------------------------
-- Scans (source domain, pre take-volume)
-- ---------------------------------------------------------------------------
-- Absolute peak in [a, b] seconds. Returns peak (0..1) or nil.
function Ops.PeakInRegion(src, a, b)
    local dur = b - a
    if not src or dur <= 0 then return nil end
    local count = math.floor(dur * ANALYSIS_RATE)
    if count < 16 then count = 16 end
    if count > MAX_SCAN then count = MAX_SCAN end
    local ch = r.GetMediaSourceNumChannels(src) or 1
    if ch < 1 then ch = 1 end
    if ch > 2 then ch = 2 end
    local buf = Wave.Array(count * ch * 2)
    buf.clear()
    local retval = r.PCM_Source_GetPeaks(src, count / dur, a, ch, count, 0, buf)
    local valid = retval and (retval & 0xfffff) or 0
    if valid <= 0 then return nil end
    local peak = 0
    local min_base = count * ch
    for i = 1, valid * ch do
        local v = buf[i]
        if v < 0 then v = -v end
        if v > peak then peak = v end
        v = buf[min_base + i]
        if v < 0 then v = -v end
        if v > peak then peak = v end
    end
    return peak
end

-- Transient onsets in [a, b]. sens 0..1 (higher = more markers). Appends
-- source-times to `out` (caller-owned array, cleared here). Returns count.
local env = {}   -- pooled envelope lane
function Ops.DetectTransients(src, a, b, sens, out)
    for i = #out, 1, -1 do out[i] = nil end
    local dur = b - a
    if not src or dur <= 0 then return 0 end
    local count = math.floor(dur * ANALYSIS_RATE)
    if count < 32 then return 0 end
    if count > MAX_SCAN then count = MAX_SCAN end
    local rate = count / dur
    local ch = r.GetMediaSourceNumChannels(src) or 1
    if ch < 1 then ch = 1 end
    if ch > 2 then ch = 2 end
    local buf = Wave.Array(count * ch * 2)
    buf.clear()
    local retval = r.PCM_Source_GetPeaks(src, rate, a, ch, count, 0, buf)
    local valid = retval and (retval & 0xfffff) or 0
    if valid <= 0 then return 0 end

    -- mono envelope = max |lane| across channels
    local min_base = count * ch
    for px = 1, valid do
        local e = 0
        local base = (px - 1) * ch
        for c = 1, ch do
            local v = buf[base + c]
            if v < 0 then v = -v end
            if v > e then e = v end
            v = buf[min_base + base + c]
            if v < 0 then v = -v end
            if v > e then e = v end
        end
        env[px] = e
    end

    -- onset = envelope jumps over a slow-moving average, floor-gated,
    -- refractory 30ms; the marker backs up to the local rise start.
    local floor_lvl = 0.015 + (1 - sens) * 0.06
    local ratio     = 1.6 + (1 - sens) * 2.4
    local gap       = math.floor(rate * 0.03)
    local avg       = env[1] or 0
    local last      = -gap
    for i = 2, valid do
        local e = env[i]
        if e > floor_lvl and e > avg * ratio and (i - last) > gap then
            local j = i
            while j > 2 and env[j - 1] < env[j] and (i - j) < gap do
                j = j - 1
            end
            out[#out + 1] = a + (j - 1) / rate
            last = i
        end
        avg = avg + (e - avg) * 0.02
    end
    return #out
end

-- Nearest zero crossing to t (±10ms window at file samplerate).
function Ops.SnapZero(src, t)
    if not src then return t end
    local sr = r.GetMediaSourceSampleRate(src)
    if not sr or sr <= 0 then return t end
    local W = 0.01
    local a = t - W
    if a < 0 then a = 0 end
    local count = math.floor((t + W - a) * sr)
    if count < 4 then return t end
    if count > 4096 then count = 4096 end
    local buf = Wave.Array(count * 2)   -- 1 channel
    buf.clear()
    local retval = r.PCM_Source_GetPeaks(src, sr, a, 1, count, 0, buf)
    local valid = retval and (retval & 0xfffff) or 0
    if valid < 4 then return t end
    local center = (t - a) * sr
    local best, best_d = nil, math.huge
    local prev = buf[1]
    for i = 2, valid do
        local v = buf[i]
        if (prev <= 0 and v >= 0) or (prev >= 0 and v <= 0) then
            local d = (i - 1) - center
            if d < 0 then d = -d end
            if d < best_d then best, best_d = i - 1, d end
        end
        prev = v
    end
    if not best then return t end
    return a + best / sr
end

-- ---------------------------------------------------------------------------
-- Item helpers
-- ---------------------------------------------------------------------------
-- Active source region of an item, in source seconds.
function Ops.ItemRegion(item, take)
    local soffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local rate  = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local len   = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    if rate <= 0 then rate = 1 end
    return soffs, soffs + len * rate, rate
end

function Ops.VolDB(take)
    local v = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
    if v < 0 then v = -v end
    if v < 0.0000001 then return -150 end
    return 20 * math.log(v, 10)
end

local function setVolKeepPolarity(take, lin)
    local cur = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
    if cur < 0 then lin = -lin end
    r.SetMediaItemTakeInfo_Value(take, "D_VOL", lin)
end

-- ---------------------------------------------------------------------------
-- Non-destructive edits (each = one undo point)
-- ---------------------------------------------------------------------------
-- Normalize the [a, b] source region to target_db (default 0dBFS). The scan
-- is source-domain (pre take-vol) so the result is absolute, not relative.
function Ops.Normalize(item, take, src, a, b, target_db)
    local peak = Ops.PeakInRegion(src, a, b)
    if not peak or peak < 0.00001 then return false end
    local target = 10 ^ ((target_db or 0) / 20)
    setVolKeepPolarity(take, target / peak)
    r.UpdateItemInProject(item)
    r.Undo_OnStateChange("Sample Editor: normalize")
    return true
end

function Ops.SetVolDB(item, take, db)
    setVolKeepPolarity(take, 10 ^ (db / 20))
    r.UpdateItemInProject(item)
    r.Undo_OnStateChange("Sample Editor: item gain")
end

-- Toggle take reverse (native action — REAPER wraps the source in a
-- reversed section; the editor re-reads the new source and the waveform
-- flips accordingly). Preserves the user's item selection.
local sel_backup = {}
function Ops.Reverse(item)
    local n = r.CountSelectedMediaItems(0)
    for i = #sel_backup, 1, -1 do sel_backup[i] = nil end
    for i = 0, n - 1 do
        sel_backup[i + 1] = r.GetSelectedMediaItem(0, i)
    end
    r.SelectAllMediaItems(0, false)
    r.SetMediaItemSelected(item, true)
    r.Main_OnCommand(41051, 0)   -- Item properties: toggle take reverse
    r.SetMediaItemSelected(item, false)
    for i = 1, #sel_backup do
        if r.ValidatePtr2(0, sel_backup[i], "MediaItem*") then
            r.SetMediaItemSelected(sel_backup[i], true)
        end
    end
    r.UpdateArrange()
end

function Ops.SetPitch(take, item, semis)
    r.SetMediaItemTakeInfo_Value(take, "D_PITCH", semis)
    r.UpdateItemInProject(item)
    r.Undo_OnStateChange("Sample Editor: pitch")
end

-- Change playrate keeping the SAME source region covered (item length
-- follows — Ableton clip semantics). preserve=true keeps pitch (stretch).
function Ops.SetRate(item, take, new_rate, preserve)
    if new_rate <= 0.01 then return end
    local a, b = Ops.ItemRegion(item, take)
    r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", new_rate)
    r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", preserve and 1 or 0)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", (b - a) / new_rate)
    r.UpdateItemInProject(item)
    r.Undo_OnStateChange("Sample Editor: playrate")
end

function Ops.SetFades(item, fin, fout)
    if fin  then r.SetMediaItemInfo_Value(item, "D_FADEINLEN", fin) end
    if fout then r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fout) end
    r.UpdateArrange()
end

function Ops.CommitFades()
    r.Undo_OnStateChange("Sample Editor: fades")
end

-- Crop the item to the [a, b] source region (position preserved).
function Ops.TrimToSel(item, take, a, b)
    local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if rate <= 0 then rate = 1 end
    r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", a)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", (b - a) / rate)
    r.UpdateItemInProject(item)
    r.Undo_OnStateChange("Sample Editor: trim to selection")
end

-- Split the item at the given SOURCE times (sorted ascending). Right-to-
-- left so the original item pointer stays the left part throughout.
function Ops.SplitAt(item, take, times)
    local pos   = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local a, b, rate = Ops.ItemRegion(item, take)
    r.Undo_BeginBlock()
    local made = 0
    for i = #times, 1, -1 do
        local t = times[i]
        if t > a + 0.0005 and t < b - 0.0005 then
            local tl = pos + (t - a) / rate
            if r.SplitMediaItem(item, tl) then made = made + 1 end
        end
    end
    r.Undo_EndBlock("Sample Editor: split at transients", -1)
    r.UpdateArrange()
    return made
end

return Ops
