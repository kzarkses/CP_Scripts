-- CP_Engine — Bake
-- Destructive audio, done honestly (refonte chantier 9): render what is
-- heard into a real file on disk. Three layers, each usable alone:
--
--   1. A pure-Lua streaming WAV writer (WavOpen / WavWrite / WavClose) —
--      RIFF little-endian, 32-bit float (default, bit-exact from Lua
--      doubles) or 16-bit PCM. No dependency, works on any REAPER.
--   2. AudioAccessor plumbing: RegionToWav reads a TAKE as it would play
--      (take properties applied, take FX included) and streams it to disk;
--      FileRegionToWav does the same for a bare FILE by parking it on a
--      throwaway track for the duration of the read (one undo step, no
--      visible flicker).
--   3. Selection-safe wrappers over the two native destructive renders —
--      Apply FX (40209) and Glue (40362) — for consumers that live in the
--      arrange view and want REAPER's own render path.
--
-- Everything here is event-driven and offline: allocations are fine, and
-- nothing below may ever run per frame.

local Bake = {}
local r

function Bake.init(reaper_api)
    r = reaper_api
end

-- ---------------------------------------------------------------------------
-- WAV writer (streaming; header sizes patched on close)
--
-- Layout: RIFF(12) fmt(24) [fact(12) float only] data(8) payload.
-- Payload starts at 44 (PCM) or 56 (float).
-- ---------------------------------------------------------------------------
local BATCH = 128
local FMT16 = "<" .. string.rep("i2", BATCH)
local FMT32 = "<" .. string.rep("f", BATCH)
local tmp = {}

function Bake.WavOpen(path, srate, nch, bits)
    bits = (bits == 16) and 16 or 32
    local float = bits == 32
    local f = io.open(path, "wb")
    if not f then return nil end
    local ba = nch * (bits // 8)
    f:write("RIFF", string.pack("<I4", 0), "WAVE")
    f:write("fmt ", string.pack("<I4I2I2I4I4I2I2",
                                16, float and 3 or 1, nch, srate,
                                srate * ba, ba, bits))
    if float then f:write("fact", string.pack("<I4I4", 4, 0)) end
    f:write("data", string.pack("<I4", 0))
    return { f = f, nch = nch, bits = bits, float = float, frames = 0 }
end

-- Append n interleaved samples from buf (reaper.array or plain table,
-- 1-based, values in -1..1 — floats are written as-is, PCM is clamped).
function Bake.WavWrite(h, buf, n)
    local float = h.float
    local out, o = {}, 0
    local i = 1
    while i <= n do
        local m = n - i + 1
        if m > BATCH then m = BATCH end
        if float then
            for k = 1, m do tmp[k] = buf[i + k - 1] end
        else
            for k = 1, m do
                local v = buf[i + k - 1]
                if v > 1 then v = 1 elseif v < -1 then v = -1 end
                tmp[k] = math.floor(v * 32767 + (v >= 0 and 0.5 or -0.5))
            end
        end
        local fmt
        if m == BATCH then fmt = float and FMT32 or FMT16
        else fmt = "<" .. string.rep(float and "f" or "i2", m) end
        o = o + 1
        out[o] = string.pack(fmt, table.unpack(tmp, 1, m))
        i = i + m
    end
    h.f:write(table.concat(out))
    h.frames = h.frames + n / h.nch
end

function Bake.WavClose(h)
    local f = h.f
    local frames = math.floor(h.frames + 0.5)
    local ba = h.nch * (h.bits // 8)
    local dsz = frames * ba
    local data0 = h.float and 56 or 44
    f:seek("set", 4)
    f:write(string.pack("<I4", data0 + dsz - 8))
    if h.float then
        f:seek("set", 44); f:write(string.pack("<I4", frames))
        f:seek("set", 52); f:write(string.pack("<I4", dsz))
    else
        f:seek("set", 40); f:write(string.pack("<I4", dsz))
    end
    f:close()
    return frames
end

-- First free "<dir><name>_<tag>N.wav" next to the source file. The output
-- is always a .wav regardless of what the source was.
function Bake.NextPath(path, tag)
    local base = path:match("^(.*)%.[^.\\/]+$") or path
    tag = tag or "bake"
    local i = 1
    while true do
        local p = string.format("%s_%s%d.wav", base, tag, i)
        local f = io.open(p, "rb")
        if not f then return p end
        f:close()
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Take -> file
-- ---------------------------------------------------------------------------
local CHUNK = 32768

-- Render [t0, t1) of a take (seconds, relative to the take's item start) to
-- path. The accessor hears the take as it plays: take properties and take
-- FX apply, track FX do not. opts: bits (16|32), srate, nch — default to
-- the source's own format so nothing is resampled without asking.
-- Returns frames written, or nil + error.
function Bake.RegionToWav(take, t0, t1, path, opts)
    opts = opts or {}
    local src = r.GetMediaItemTake_Source(take)
    if not src then return nil, "take has no source" end
    local srate = opts.srate or r.GetMediaSourceSampleRate(src)
    if not srate or srate <= 0 then srate = 44100 end
    local nch = opts.nch or r.GetMediaSourceNumChannels(src)
    if not nch or nch < 1 then nch = 2 end
    local len = (t1 or 0) - (t0 or 0)
    if len <= 0 then return nil, "empty range" end
    local acc = r.CreateTakeAudioAccessor(take)
    if not acc then return nil, "no audio accessor" end
    local h = Bake.WavOpen(path, srate, nch, opts.bits)
    if not h then
        r.DestroyAudioAccessor(acc)
        return nil, "cannot write " .. path
    end
    local buf = r.new_array(CHUNK * nch)
    local total = math.floor(len * srate + 0.5)
    local done = 0
    while done < total do
        local m = total - done
        if m > CHUNK then m = CHUNK end
        buf.clear()
        r.GetAudioAccessorSamples(acc, srate, nch, t0 + done / srate, m, buf)
        Bake.WavWrite(h, buf, m * nch)
        done = done + m
    end
    r.DestroyAudioAccessor(acc)
    return Bake.WavClose(h)
end

-- Render [s0, s1) of an audio FILE (seconds into the file) to dstpath —
-- the "drag region out" primitive. The file is parked on a throwaway track
-- for the read; the project is left exactly as found, in one undo step.
-- opts adds, on top of RegionToWav's bits/srate/nch:
--   rate      D_PLAYRATE for the take — 1.0 leaves the region alone
--   preserve  keep the KEY while the rate changes (B_PPITCH). Default true
--             when a rate is given, because a rate that moves the pitch is a
--             repitch, and a repitch does not need a render at all: the
--             engine does it for free by reading faster.
--   pitchmode I_PITCHMODE — REAPER's stretching algorithm, as (mode<<16)|sub.
--             nil / -1 = the project's own default, which is the right answer
--             unless the caller has a reason.
--
-- THE STRETCH IS PRINTED BY THE ACCESSOR, not by us: RegionToWav reads the
-- take AS IT PLAYS, so a playrate with preserve-pitch on is already the
-- stretched signal by the time it reaches the writer. That is why this costs
-- three lines rather than a resampler.
--
-- The rendered length is the region divided by the rate: at 1.25x the take
-- consumes four seconds of source in 3.2 seconds of project time.
function Bake.FileRegionToWav(srcpath, s0, s1, dstpath, opts)
    opts = opts or {}
    local psrc = r.PCM_Source_CreateFromFile(srcpath)
    if not psrc then return nil, "cannot open " .. srcpath end
    local slen = r.GetMediaSourceLength(psrc)
    s0 = math.max(0, s0 or 0)
    if not s1 or s1 <= 0 or s1 > slen then s1 = slen end
    if s1 <= s0 then
        r.PCM_Source_Destroy(psrc)
        return nil, "empty range"
    end
    local rate = opts.rate or 1.0
    if not (rate > 0.01 and rate < 100) then rate = 1.0 end
    local out_len = (s1 - s0) / rate

    r.PreventUIRefresh(1)
    r.Undo_BeginBlock2(0)
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    local item = r.AddMediaItemToTrack(tr)
    local take = r.AddTakeToMediaItem(item)
    r.SetMediaItemTake_Source(take, psrc)          -- the take owns psrc now
    r.SetMediaItemInfo_Value(item, "D_LENGTH", out_len)
    r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", s0)
    if rate ~= 1.0 then
        r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
        local preserve = (opts.preserve ~= false)
        r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", preserve and 1 or 0)
        if opts.pitchmode then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", opts.pitchmode)
        end
    end
    local frames, err = Bake.RegionToWav(take, 0, out_len, dstpath, opts)
    r.DeleteTrack(tr)
    r.Undo_EndBlock2(0, "Bake: render sample region", -1)
    r.PreventUIRefresh(-1)
    return frames, err
end

-- ---------------------------------------------------------------------------
-- Native destructive renders (arrange-view consumers)
-- ---------------------------------------------------------------------------
local function withOnlyItemSelected(item, fn)
    local sel, n = {}, r.CountSelectedMediaItems(0)
    for i = 0, n - 1 do sel[i + 1] = r.GetSelectedMediaItem(0, i) end
    r.SelectAllMediaItems(0, false)
    r.SetMediaItemSelected(item, true)
    fn()
    -- the action may have replaced items; restore what still exists
    r.SelectAllMediaItems(0, false)
    for i = 1, #sel do
        if r.ValidatePtr2(0, sel[i], "MediaItem*") then
            r.SetMediaItemSelected(sel[i], true)
        end
    end
end

-- Apply track/take FX to the item as a NEW TAKE (native 40209) — the old
-- take stays underneath, so this is reversible by deleting the new take.
function Bake.ApplyFXItem(item)
    if not r.ValidatePtr2(0, item, "MediaItem*") then return false end
    withOnlyItemSelected(item, function()
        r.Main_OnCommand(40209, 0)
    end)
    return true
end

-- Glue the item in place (native 40362): FX, fades and take properties are
-- printed into a new file. Returns the glued item (the pointer changes).
function Bake.GlueItem(item)
    if not r.ValidatePtr2(0, item, "MediaItem*") then return nil end
    local glued
    withOnlyItemSelected(item, function()
        r.Main_OnCommand(40362, 0)
        glued = r.GetSelectedMediaItem(0, 0)
    end)
    return glued
end

return Bake
