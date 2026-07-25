-- CP_Engine — Mix
-- The three controls a session column needs, and the meter that makes them
-- readable: volume, mute, solo. Nothing else. A full console would be a
-- proprietary container re-implementing what REAPER already has — the whole
-- direction of the suite is that the value is the VIEW, not the format
-- (ANALYSE_Design.md §7, decision consignée ROADMAP_Autonomie session 7:
-- "Mixer: pas de console… le reste vit dans le mixer de REAPER").
--
-- Domain layer: this talks to REAPER tracks. The widgets that draw it live in
-- CP_Toolkit and know nothing about tracks. One direction only.
--
-- Every consumer works the same way: a column/pad/lane names its target track
-- and a stable KEY (its own index). The key is what carries the meter's
-- memory between frames; the track pointer can change under it without the
-- meter jumping.

local Mix = {}

local r  -- reaper, injected

local floor, log, huge = math.floor, math.log, math.huge
local INV_LN10 = 1 / math.log(10)

-- The fader's world. -60 dB is the floor (below it, silence), +6 the ceiling.
Mix.MIN_DB = -60
Mix.MAX_DB = 6
-- Where 0 dB sits on the travel. A fader linear in decibels from -60 to +6
-- would put unity at 0.91 — the range you actually mix in squeezed into the
-- last tenth of the widget. Hinging the scale at 0.8 is what every console
-- does, and it stays two straight segments, so the inverse is arithmetic and
-- no logarithm ever runs on the drag path.
Mix.UNITY = 0.8

function Mix.init(reaper_api)
    r = reaper_api
end

local function valid(tr)
    return tr and r.ValidatePtr2(0, tr, "MediaTrack*") and true or false
end
Mix.Valid = valid

-- ---------------------------------------------------------------------------
-- The scale
-- ---------------------------------------------------------------------------
function Mix.NormToDb(n)
    if n <= 0 then return -huge end
    if n < Mix.UNITY then return Mix.MIN_DB * (1 - n / Mix.UNITY) end
    if n >= 1 then return Mix.MAX_DB end
    return Mix.MAX_DB * ((n - Mix.UNITY) / (1 - Mix.UNITY))
end

function Mix.DbToNorm(db)
    if db <= Mix.MIN_DB then return 0 end
    if db < 0 then return Mix.UNITY * (1 - db / Mix.MIN_DB) end
    if db >= Mix.MAX_DB then return 1 end
    return Mix.UNITY + (1 - Mix.UNITY) * (db / Mix.MAX_DB)
end

local function dbToGain(db)
    if db <= Mix.MIN_DB then return 0 end
    return 10 ^ (db / 20)
end

local function gainToDb(g)
    if not g or g <= 0 then return -huge end
    return 20 * log(g) * INV_LN10
end

Mix.DbToGain = dbToGain
Mix.GainToDb = gainToDb

-- ---------------------------------------------------------------------------
-- Volume
-- ---------------------------------------------------------------------------
function Mix.GetNorm(tr)
    if not valid(tr) then return Mix.UNITY end
    return Mix.DbToNorm(gainToDb(r.GetMediaTrackInfo_Value(tr, "D_VOL")))
end

-- Written on every frame of a drag (REAPER is the storage, there is no local
-- copy to drift), and the undo point comes separately, once, at the release:
-- a gesture is one entry in the history, not sixty.
function Mix.SetNorm(tr, n)
    if not valid(tr) then return end
    if n < 0 then n = 0 elseif n > 1 then n = 1 end
    r.SetMediaTrackInfo_Value(tr, "D_VOL", dbToGain(Mix.NormToDb(n)))
end

function Mix.CommitVol()
    r.Undo_OnStateChangeEx2(0, "Change track volume", 1, -1)
end

-- The readout allocates (string.format), so it is rebuilt only when the value
-- it shows changes — a fader nobody is touching costs nothing per frame. One
-- decimal: more than a pixel of an 80-px fader can resolve is noise.
local lbl = {}   -- [key] = { q = <last tenth of a dB>, s = "-6.0" }
local Q_SILENT = -1e9

function Mix.DbLabel(key, n)
    local c = lbl[key]
    if not c then c = { q = 1e9, s = "" }; lbl[key] = c end
    local db = Mix.NormToDb(n)
    local q = (db == -huge) and Q_SILENT or floor(db * 10 + 0.5)
    if q ~= c.q then
        c.q = q
        c.s = (q == Q_SILENT) and "-inf" or string.format("%.1f", q / 10)
    end
    return c.s
end

-- ---------------------------------------------------------------------------
-- Mute / solo
-- ---------------------------------------------------------------------------
function Mix.IsMute(tr)
    if not valid(tr) then return false end
    return r.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0.5
end

function Mix.SetMute(tr, on)
    if not valid(tr) then return end
    r.SetMediaTrackInfo_Value(tr, "B_MUTE", on and 1 or 0)
    r.Undo_OnStateChangeEx2(0, on and "Mute track" or "Unmute track", 1, -1)
end

function Mix.IsSolo(tr)
    if not valid(tr) then return false end
    return r.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0.5
end

-- REAPER's solo is the PROJECT's, not the session's: soloing a column
-- silences the arrangement too. That is exactly what Ableton does, so it is
-- the right behaviour — it just has to be a known one, not a surprise.
-- `exclusive` (Ctrl-click) unsolos every other track, the gesture every mixer
-- in the world has.
function Mix.SetSolo(tr, on, exclusive)
    if not valid(tr) then return end
    if exclusive then
        for i = 0, r.CountTracks(0) - 1 do
            local t2 = r.GetTrack(0, i)
            if t2 ~= tr then r.SetMediaTrackInfo_Value(t2, "I_SOLO", 0) end
        end
    end
    r.SetMediaTrackInfo_Value(tr, "I_SOLO", on and 1 or 0)
    r.Undo_OnStateChangeEx2(0, on and "Solo track" or "Unsolo track", 1, -1)
end

-- "Is anything soloed" answers the question a muted-looking column raises:
-- am I silent because of ME, or because of someone else? Scanning every track
-- for it is a per-frame cost that buys nothing at 60 Hz — the answer changes
-- when a human clicks, so a fifth of a second late is not late.
local solo_any, solo_t = false, 0

function Mix.AnySolo()
    local now = r.time_precise()
    if now - solo_t < 0.2 then return solo_any end
    solo_t = now
    solo_any = false
    for i = 0, r.CountTracks(0) - 1 do
        if r.GetMediaTrackInfo_Value(r.GetTrack(0, i), "I_SOLO") > 0.5 then
            solo_any = true
            break
        end
    end
    return solo_any
end

-- ---------------------------------------------------------------------------
-- Metering
-- ---------------------------------------------------------------------------
-- The peak lands on the SAME scale as the fader, so unity is at the same 0.8
-- of the travel on both: how close a track is to 0 dB becomes something you
-- can see against its own fader instead of something you convert in your head.
function Mix.PeakNorm(p)
    if not p or p <= 0 then return 0 end
    local n = Mix.DbToNorm(gainToDb(p))
    return n > 1 and 1 or n
end

-- Two decays, both in scale-units per second: the LEVEL falls fast enough to
-- follow the music, the HOLD slowly enough that a transient is still on screen
-- when you look up. Without the hold, a meter this small shows nothing at all
-- of a drum hit — the peak is gone by the next frame.
local FALL       = 2.2
local HOLD_FALL  = 0.5
local HOLD_WAIT  = 0.8

local mtr = {}   -- [key] = { l, r, hl, hr, hlt, hrt, t }

local function fall(v, target, drop)
    if target >= v then return target end
    v = v - drop
    if v < target then v = target end
    return v > 0 and v or 0
end

local function holdOf(h, ht, lev, now, drop)
    if lev >= h then return lev, now end
    if (now - ht) > HOLD_WAIT then
        h = h - drop
        if h < lev then h = lev end
        if h < 0 then h = 0 end
    end
    return h, ht
end

-- Returns level_l, level_r, hold_l, hold_r — four numbers, no allocation.
function Mix.Meter(key, tr)
    local m = mtr[key]
    if not m then
        m = { l = 0, r = 0, hl = 0, hr = 0, hlt = 0, hrt = 0, t = 0 }
        mtr[key] = m
    end
    local now = r.time_precise()
    local dt = now - m.t
    -- first frame, or the window was hidden and came back: don't let a huge
    -- delta wipe the meter in one step
    if dt <= 0 or dt > 0.5 then dt = 1 / 30 end
    m.t = now

    local pl, pr = 0, 0
    if valid(tr) then
        pl = Mix.PeakNorm(r.Track_GetPeakInfo(tr, 0))
        pr = Mix.PeakNorm(r.Track_GetPeakInfo(tr, 1))
    end

    local drop = FALL * dt
    m.l = fall(m.l, pl, drop)
    m.r = fall(m.r, pr, drop)
    local hdrop = HOLD_FALL * dt
    m.hl, m.hlt = holdOf(m.hl, m.hlt, m.l, now, hdrop)
    m.hr, m.hrt = holdOf(m.hr, m.hrt, m.r, now, hdrop)

    return m.l, m.r, m.hl, m.hr
end

-- A column that loses its track (unrouted, deleted) must not keep a level
-- frozen on screen from the last thing it heard.
function Mix.ResetMeter(key)
    local m = mtr[key]
    if not m then return end
    m.l, m.r, m.hl, m.hr = 0, 0, 0, 0
end

return Mix
