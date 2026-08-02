-- CP_Engine — Mix
-- The channel strip of a session column: volume, mute, solo, pan, the meter
-- that makes them readable, and the two LISTS a strip is really about — the
-- FX chain and the sends.
--
-- This module used to stop at three controls, on the reasoning that a console
-- would re-implement what REAPER already has (ROADMAP session 7, "Mixer: pas
-- de console"). That was right about the FORMAT and wrong about the VIEW: what
-- a session needs is not a second mixer engine — everything below is REAPER's
-- own track state, written through REAPER's own API — but the chain and the
-- sends of the thing you are launching, next to the thing you are launching.
-- Reaching them meant leaving the window, and leaving the window is exactly
-- what a session view exists to avoid.
--
-- Nothing here is a copy of REAPER's state: every read goes to the track, and
-- the only things cached are the STRINGS (FX and send names allocate on every
-- call, and a strip draws thirty times a second) — keyed on the project's own
-- change counter, so a chain edited anywhere is a chain redrawn here.
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
-- Pan
-- ---------------------------------------------------------------------------
-- Held as 0..1 for the knob (0.5 = centre), stored as REAPER's -1..1.
function Mix.GetPan(tr)
    if not valid(tr) then return 0.5 end
    return (r.GetMediaTrackInfo_Value(tr, "D_PAN") + 1) * 0.5
end

function Mix.SetPan(tr, n)
    if not valid(tr) then return end
    if n < 0 then n = 0 elseif n > 1 then n = 1 end
    -- a detent AT centre, not near it: a pan knob that cannot be put back to
    -- the middle by hand is the oldest annoyance in the list
    if n > 0.485 and n < 0.515 then n = 0.5 end
    r.SetMediaTrackInfo_Value(tr, "D_PAN", n * 2 - 1)
end

function Mix.CommitPan()
    r.Undo_OnStateChangeEx2(0, "Change track pan", 1, -1)
end

local pan_lbl = {}   -- [key] = { q, s }

function Mix.PanLabel(key, n)
    local c = pan_lbl[key]
    if not c then c = { q = 1e9, s = "" }; pan_lbl[key] = c end
    local q = floor((n * 2 - 1) * 100 + 0.5)
    if q ~= c.q then
        c.q = q
        if q == 0 then c.s = "C"
        elseif q < 0 then c.s = tostring(-q) .. "L"
        else c.s = tostring(q) .. "R" end
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

-- ---------------------------------------------------------------------------
-- The two lists — FX chain and sends
-- ---------------------------------------------------------------------------
-- Names are the only thing kept: every count, every level, every bypass is
-- read live from the track. A name costs a string allocation per call, and a
-- strip asks for all of them every frame, so they are cached against the
-- project's change counter — the one number REAPER already bumps whenever
-- anything at all moves, wherever it was moved from.
-- One entry per track a strip actually draws — four to eight of them, so the
-- table is bounded by the view and never needs pruning.
local chain = {}     -- [guid] = { stamp, n, name[i], off[i] }
local sends = {}     -- [guid] = { stamp, n, name[i], dest[i] }

local function stamp()
    return r.GetProjectStateChangeCount(0)
end

local function guidOf(tr)
    local _, g = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
    return g
end

-- Shorten "VST3: Pro-Q 3 (FabFilter)" to "Pro-Q 3": the prefix says what
-- PLUGIN FORMAT it is, which is never what you are looking for in a chain,
-- and the vendor in brackets is the same for a whole shelf of them.
local function shortFx(n)
    if not n or n == "" then return "?" end
    -- VST:, VST3:, VST3i:, JS:, AU:, AUi:, CLAP:, LV2: — letters AND digits,
    -- because "VST3i" is the one that matters most and %u alone never matched
    -- it (the 3 stops the class), so the strip showed the format and cut the
    -- plugin's own name off the right edge.
    n = n:gsub("^[%u%d]+i?:%s*", "")
    n = n:gsub("%s*%b()%s*$", "")      -- trailing (Vendor)
    if n == "" then return "?" end
    return n
end
Mix.ShortFxName = shortFx

local function chainOf(tr)
    if not valid(tr) then return nil end
    local g = guidOf(tr)
    local c = chain[g]
    local st = stamp()
    if c and c.stamp == st then return c end
    if not c then c = { name = {}, off = {} }; chain[g] = c end
    c.stamp = st
    local n = r.TrackFX_GetCount(tr)
    c.n = n
    for i = 1, n do
        local ok, nm = r.TrackFX_GetFXName(tr, i - 1, "")
        c.name[i] = shortFx(ok and nm or nil)
        c.off[i]  = not r.TrackFX_GetEnabled(tr, i - 1)
    end
    for i = n + 1, #c.name do c.name[i] = nil c.off[i] = nil end
    return c
end

function Mix.FxCount(tr)
    local c = chainOf(tr)
    return c and c.n or 0
end

-- name, bypassed — for slot i (1-based).
function Mix.Fx(tr, i)
    local c = chainOf(tr)
    if not c or i < 1 or i > c.n then return nil end
    return c.name[i], c.off[i]
end

function Mix.FxToggle(tr, i)
    if not valid(tr) then return end
    local on = r.TrackFX_GetEnabled(tr, i - 1)
    r.TrackFX_SetEnabled(tr, i - 1, not on)
    r.Undo_OnStateChangeEx2(0, on and "Bypass FX" or "Un-bypass FX", 2, -1)
end

function Mix.FxShow(tr, i)
    if not valid(tr) then return end
    r.TrackFX_Show(tr, i - 1, 3)
end

function Mix.FxDelete(tr, i)
    if not valid(tr) then return end
    r.Undo_BeginBlock()
    r.TrackFX_Delete(tr, i - 1)
    r.Undo_EndBlock("Delete FX", 2)
end

function Mix.FxAdd(tr, name)
    if not valid(tr) or not name or name == "" then return -1 end
    r.Undo_BeginBlock()
    local fx = r.TrackFX_AddByName(tr, name, false, -1)
    r.Undo_EndBlock("Add FX", 2)
    return fx
end

-- Move (or copy) slot `from` of `src` to slot `to` of `dst`. `to` is where it
-- LANDS, 1-based, and may be one past the end. Same track = a reorder, and
-- REAPER's own CopyToTrack does both — no delete-then-insert, so an FX keeps
-- its parameters, its automation and its window.
function Mix.FxMove(src, from, dst, to, copy)
    if not valid(src) or not valid(dst) then return false end
    local n = r.TrackFX_GetCount(src)
    if from < 1 or from > n then return false end
    if to < 1 then to = 1 end
    r.Undo_BeginBlock()
    r.TrackFX_CopyToTrack(src, from - 1, dst, to - 1, not copy)
    r.Undo_EndBlock(copy and "Copy FX" or "Move FX", 2)
    return true
end

-- ---- sends -----------------------------------------------------------------
local function sendsOf(tr)
    if not valid(tr) then return nil end
    local g = guidOf(tr)
    local s = sends[g]
    local st = stamp()
    if s and s.stamp == st then return s end
    if not s then s = { name = {}, dest = {} }; sends[g] = s end
    s.stamp = st
    local n = r.GetTrackNumSends(tr, 0)
    s.n = n
    for i = 1, n do
        local d = r.GetTrackSendInfo_Value(tr, 0, i - 1, "P_DESTTRACK")
        s.dest[i] = d
        local nm = ""
        if d and valid(d) then
            local _, tn = r.GetTrackName(d)
            nm = tn
        end
        s.name[i] = (nm ~= "" and nm) or "send"
    end
    for i = n + 1, #s.name do s.name[i] = nil s.dest[i] = nil end
    return s
end

function Mix.SendCount(tr)
    local s = sendsOf(tr)
    return s and s.n or 0
end

-- name, destination track, level (0..1 on the FADER scale, so a send reads
-- against the same geometry as everything else in the strip).
function Mix.Send(tr, i)
    local s = sendsOf(tr)
    if not s or i < 1 or i > s.n then return nil end
    local v = r.GetTrackSendInfo_Value(tr, 0, i - 1, "D_VOL")
    return s.name[i], s.dest[i], Mix.DbToNorm(gainToDb(v))
end

function Mix.SetSendNorm(tr, i, n)
    if not valid(tr) then return end
    if n < 0 then n = 0 elseif n > 1 then n = 1 end
    r.SetTrackSendInfo_Value(tr, 0, i - 1, "D_VOL", dbToGain(Mix.NormToDb(n)))
end

function Mix.CommitSend()
    r.Undo_OnStateChangeEx2(0, "Change send level", 1, -1)
end

function Mix.SendMute(tr, i)
    if not valid(tr) then return false end
    return r.GetTrackSendInfo_Value(tr, 0, i - 1, "B_MUTE") > 0.5
end

function Mix.SetSendMute(tr, i, on)
    if not valid(tr) then return end
    r.SetTrackSendInfo_Value(tr, 0, i - 1, "B_MUTE", on and 1 or 0)
    r.Undo_OnStateChangeEx2(0, "Mute send", 1, -1)
end

function Mix.SendRemove(tr, i)
    if not valid(tr) then return end
    r.Undo_BeginBlock()
    r.RemoveTrackSend(tr, 0, i - 1)
    r.Undo_EndBlock("Remove send", 1)
end

-- A send from src to dst, refusing the two that cannot exist: to itself, and
-- one that already does. Returns the index (1-based) or nil.
-- Rend l'index de l'envoi ET s'il vient d'etre CREE.
--
-- Les deux reponses etaient confondues en une : un envoi qui existait deja
-- rendait son index, l'appelant y voyait un succes et annoncait « Send -> X ».
-- Le message est le seul retour de ce geste, donc il disait « c'est fait » a
-- quelqu'un qui venait de refaire ce qui etait deja la — et la fois d'apres, on
-- ne sait plus si les deux envois existent ou un seul.
function Mix.SendCreate(src, dst)
    if not valid(src) or not valid(dst) or src == dst then return nil end
    local n = r.GetTrackNumSends(src, 0)
    for i = 0, n - 1 do
        if r.GetTrackSendInfo_Value(src, 0, i, "P_DESTTRACK") == dst then
            return i + 1, false
        end
    end
    r.Undo_BeginBlock()
    local i = r.CreateTrackSend(src, dst)
    r.Undo_EndBlock("Create send", 1)
    if not i or i < 0 then return nil end
    return i + 1, true
end

return Mix
