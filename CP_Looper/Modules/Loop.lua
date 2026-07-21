-- CP_Looper / Loop.lua — engine bridge (no UI)
--
-- Owns the looper track and talks to the CP_MidiLooper JSFX through the
-- shared gmem block. The JSFX is the real-time engine (phase-locked to the
-- host beat grid so it stays synced to an external clock); this module is
-- just the wire between the CP_Toolkit UI and that engine.
--
-- Indices below MUST stay identical to CP_JSFX/CP_MidiLooper.jsfx.

local Loop = {}
local r

-- ---------------------------------------------------------------------------
-- Layout (mirror of the JSFX)
-- ---------------------------------------------------------------------------
Loop.MAX_LANES   = 4
Loop.MAX_NOTES   = 1024
Loop.NOTE_STRIDE = 4       -- start, length, pitch, vel (all in beats/0..127)

local G_CMD, G_CMD_LANE, G_CMD_ARG, G_CMD_SEQ = 0, 1, 2, 5
local G_FREERUN    = 3     -- 0 = follow host transport, 1 = free internal clock
local G_ARMED      = 4     -- lane index that live input is monitored on
local G_LANE_CTRL  = 100   -- stride 8: +0 length_bars, +1 muted
local G_LANE_STATE = 200   -- stride 8: +0 mode,+1 nev(shared),+2 phase,+3 lenbeats,+4 evtver,+5 hascontent
local G_TRANSPORT  = 3000  -- +0 tempo,+1 play_state,+2 beat,+3 spb,+4 ts_num,+5 ts_denom,+6 srate
local G_INIT_COUNT = 3095  -- incremented by the JSFX @init: counts engine resets
local G_VERSION    = 3099
local G_NOTE_BASE  = 10000

local GMEM_NAME  = "CP_MidiLooper"
local ADD_NAME   = "JS:CP_Scripts/CP_MidiLooper.jsfx"
local EXT_TAG    = "CP_LOOPER"

-- bound for speed (rebound in init once reaper is known)
local gread, gwrite

local seq = 0
local attached = false        -- did gmem_attach succeed

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function Loop.init(reaper_api)
    r = reaper_api
    -- gmem_attach connects this script to the JSFX's named shared block.
    -- Safe to call every run; only one block is used.
    if r.gmem_attach then
        r.gmem_attach(GMEM_NAME)
        attached = true
    end
    gread  = r.gmem_read
    gwrite = r.gmem_write
    Loop.track = nil
    Loop.reconnect()
end

-- ---------------------------------------------------------------------------
-- JSFX install (copy source -> Effects, on content change only)
-- ---------------------------------------------------------------------------
local function installJSFX()
    local src = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_JSFX/CP_MidiLooper.jsfx"
    local dstdir = r.GetResourcePath() .. "/Effects/CP_Scripts/"
    local dst = dstdir .. "CP_MidiLooper.jsfx"
    r.RecursiveCreateDirectory(dstdir, 0)

    local sf = io.open(src, "rb")
    if not sf then return false end
    local content = sf:read("*a"); sf:close()

    local df = io.open(dst, "rb")
    if df then
        local cur = df:read("*a"); df:close()
        if cur == content then return true end   -- up to date
    end
    df = io.open(dst, "wb")
    if not df then return false end
    df:write(content); df:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Track discovery / attach
-- ---------------------------------------------------------------------------
local function valid(tr) return tr and r.ValidatePtr2(0, tr, "MediaTrack*") end

-- TrackFX_GetFXName returns either (name) or (retval, name) across REAPER
-- versions — handle both.
local function fxName(tr, i)
    local a, b = r.TrackFX_GetFXName(tr, i, "")
    if type(a) == "string" then return a end
    return b
end

local function findLooperFX(tr)
    local n = r.TrackFX_GetCount(tr)
    for i = 0, n - 1 do
        local nm = fxName(tr, i)
        if nm and nm:find("CP_MidiLooper", 1, true) then return i end
    end
    return -1
end

-- Re-find the router track (marker "router") after a reload / new run.
function Loop.reconnect()
    if valid(Loop.track) then return Loop.track end
    Loop.track = nil
    local cnt = r.CountTracks(0)
    for i = 0, cnt - 1 do
        local tr = r.GetTrack(0, i)
        local _, v = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. EXT_TAG, "", false)
        if v == "router" then Loop.track = tr break end
    end
    if valid(Loop.track) then Loop.RefreshDests(); Loop.SyncSends() end
    return Loop.track
end

function Loop.IsAttached()
    return valid(Loop.track) and findLooperFX(Loop.track) >= 0
end

function Loop.TrackName()
    if not valid(Loop.track) then return nil end
    local _, nm = r.GetTrackName(Loop.track)
    return nm
end

-- ---------------------------------------------------------------------------
-- Per-lane routing
--
-- Each lane plays on its own MIDI channel (lane L -> ch L+1). A channel-filtered
-- MIDI send carries it from the router track to that lane's destination
-- instrument track, so different lanes drive different synths (FL/Ableton
-- style). The destination track's GUID is stored on the router (P_EXT) so it
-- survives reloads; the send is derived from it and identified by its channel
-- filter, so we never depend on reading a send's dest pointer back.
-- ---------------------------------------------------------------------------
Loop.dest = {}    -- [lane] = resolved destination MediaTrack (or nil) — UI cache

local function destKey(lane) return "P_EXT:" .. EXT_TAG .. "_DEST" .. lane end

local function getDestGUID(lane)
    if not valid(Loop.track) then return "" end
    local _, g = r.GetSetMediaTrackInfo_String(Loop.track, destKey(lane), "", false)
    return g or ""
end

local function setDestGUID(lane, guid)
    if valid(Loop.track) then
        r.GetSetMediaTrackInfo_String(Loop.track, destKey(lane), guid or "", true)
    end
end

-- Some CP tracks are INPUT BUSES that other apps need armed to work at all —
-- CP_Sampler's "CP Kit MIDI" bus is armed on purpose (its pad clicks go through
-- StuffMIDIMessage, which only reaches an armed+monitored track). Routing a lane
-- at one of those used to disarm it and silently break the sampler, so they are
-- exempt from the disarm below.
local function isInputBus(tr)
    if not valid(tr) then return false end
    local _, v = r.GetSetMediaTrackInfo_String(tr, "P_EXT:CP_KIT_MIDI", "", false)
    return v ~= nil and v ~= ""
end

-- Disarm a lane destination so live input only reaches it through the router
-- (no double-trigger) — unless it is such a bus.
local function disarmDest(tr)
    if isInputBus(tr) then return end
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", 0)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", 0)
end

local function resolveGUID(guid)
    if not guid or guid == "" then return nil end
    local cnt = r.CountTracks(0)
    for i = 0, cnt - 1 do
        local tr = r.GetTrack(0, i)
        if r.GetTrackGUID(tr) == guid then return tr end
    end
    return nil
end

-- the router's MIDI send that carries lane L: source-channel filter = L+1 and
-- audio disabled (our signature). Returns send index or -1.
local function findLaneSend(router, lane)
    local n = r.GetTrackNumSends(router, 0)
    for i = 0, n - 1 do
        local mf = r.GetTrackSendInfo_Value(router, 0, i, "I_MIDIFLAGS")
        local sc = r.GetTrackSendInfo_Value(router, 0, i, "I_SRCCHAN")
        if (math.floor(mf) & 0x1F) == (lane + 1) and sc == -1 then return i end
    end
    return -1
end

local function removeLaneSend(router, lane)
    local i = findLaneSend(router, lane)
    while i >= 0 do
        r.RemoveTrackSend(router, 0, i)
        i = findLaneSend(router, lane)
    end
end

-- create the MIDI-only, channel-filtered send router -> track for a lane.
local function makeLaneSend(router, lane, track)
    local si = r.CreateTrackSend(router, track)
    r.SetTrackSendInfo_Value(router, 0, si, "I_SRCCHAN", -1)          -- no audio
    r.SetTrackSendInfo_Value(router, 0, si, "I_MIDIFLAGS", lane + 1)  -- only ch L+1
    return si
end

-- resolve every lane's cached destination pointer from the stored GUIDs (called
-- on reconnect / after routing changes — never per frame).
function Loop.RefreshDests()
    for lane = 0, Loop.MAX_LANES - 1 do
        Loop.dest[lane] = resolveGUID(getDestGUID(lane))
    end
end

-- Ensure each lane's send matches its stored destination: create missing,
-- remove orphaned. Minimal — leaves correct sends untouched so a plain reconnect
-- doesn't dirty the project.
function Loop.SyncSends()
    local router = Loop.track
    if not valid(router) then return end
    for lane = 0, Loop.MAX_LANES - 1 do
        local tr  = resolveGUID(getDestGUID(lane))
        local has = findLaneSend(router, lane) >= 0
        if valid(tr) and tr ~= router then
            if not has then makeLaneSend(router, lane, tr) end
        else
            if has then removeLaneSend(router, lane) end
            if getDestGUID(lane) ~= "" then setDestGUID(lane, "") end
        end
        Loop.dest[lane] = valid(tr) and tr or nil
    end
end

-- Route a lane to a destination instrument track (nil = unroute). Rebuilds the
-- lane's send and disarms the destination so live input only reaches it through
-- the router (no double-trigger).
function Loop.SetLaneDest(lane, track)
    local router = Loop.track
    if not valid(router) then return end
    r.Undo_BeginBlock2(0)
    removeLaneSend(router, lane)
    if valid(track) and track ~= router then
        makeLaneSend(router, lane, track)
        disarmDest(track)
        setDestGUID(lane, r.GetTrackGUID(track))
        Loop.dest[lane] = track
    else
        setDestGUID(lane, "")
        Loop.dest[lane] = nil
    end
    r.Undo_EndBlock2(0, "CP Looper: route lane " .. (lane + 1), -1)
end

-- Cached destination pointer (zero-alloc per frame). Self-heals if the track was
-- deleted; does not re-read gmem/strings on the hot path.
function Loop.GetLaneDest(lane)
    local tr = Loop.dest[lane]
    if tr and not valid(tr) then Loop.dest[lane] = nil; return nil end
    return tr
end

-- Create a fresh instrument track for a lane and route it there. Selects it so
-- the user can drop their synth on it. Returns the new track.
function Loop.NewDestTrack(lane)
    local router = Loop.track
    if not valid(router) then return nil end
    r.Undo_BeginBlock2(0)
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, true)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "Lane " .. (lane + 1) .. " inst", true)
    removeLaneSend(router, lane)
    makeLaneSend(router, lane, tr)
    setDestGUID(lane, r.GetTrackGUID(tr))
    Loop.dest[lane] = tr
    r.SetOnlyTrackSelected(tr)
    r.Undo_EndBlock2(0, "CP Looper: new instrument track", -1)
    return tr
end

-- ---------------------------------------------------------------------------
-- Router track lifecycle
-- ---------------------------------------------------------------------------
-- Find or create the dedicated router track that hosts the engine. Non-
-- destructive: an existing engine instance is left alone (its loops survive).
local function ensureRouterTrack()
    if valid(Loop.track) then
        if findLooperFX(Loop.track) < 0 then
            local fx = r.TrackFX_AddByName(Loop.track, ADD_NAME, false, -1)
            if fx > 0 then r.TrackFX_CopyToTrack(Loop.track, fx, Loop.track, 0, true) end
            r.TrackFX_Show(Loop.track, 0, 2); r.TrackFX_Show(Loop.track, 0, 0)
        end
        return Loop.track
    end
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Looper", true)
    r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. EXT_TAG, "router", true)
    local fx = r.TrackFX_AddByName(tr, ADD_NAME, false, -1)
    if fx > 0 then r.TrackFX_CopyToTrack(tr, fx, tr, 0, true); fx = 0 end
    r.TrackFX_Show(tr, 0, 2); r.TrackFX_Show(tr, 0, 0)
    -- arm for MIDI monitoring; no instrument, no master output, out of the mixer
    r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 4096 + (63 << 5))
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
    r.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
    Loop.track = tr
    return tr
end

-- Pull the engine off any track left tagged by the old inline design (marker
-- "1") and disarm it, so it doesn't double-trigger alongside the router.
local function cleanupLegacy(router)
    local cnt = r.CountTracks(0)
    for i = 0, cnt - 1 do
        local tr = r.GetTrack(0, i)
        if tr ~= router then
            local _, v = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. EXT_TAG, "", false)
            if v == "1" then
                local old = findLooperFX(tr)
                while old >= 0 do r.TrackFX_Delete(tr, old); old = findLooperFX(tr) end
                r.SetMediaTrackInfo_Value(tr, "I_RECARM", 0)
                r.SetMediaTrackInfo_Value(tr, "I_RECMON", 0)
                r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. EXT_TAG, "", true)
            end
        end
    end
end

-- Set the looper up: ensure the router + engine exist, default-route any lane
-- that isn't routed yet to the selected instrument track, and seed live
-- defaults. Non-destructive to existing loops/routing. Returns router, err.
function Loop.Setup()
    if not installJSFX() then return nil, "Could not install CP_MidiLooper.jsfx." end
    local sel = r.GetSelectedTrack(0, 0)
    r.Undo_BeginBlock2(0)
    local router = ensureRouterTrack()
    cleanupLegacy(router)
    if valid(sel) and sel ~= router then
        for lane = 0, Loop.MAX_LANES - 1 do
            if not valid(Loop.dest[lane]) then
                removeLaneSend(router, lane)
                makeLaneSend(router, lane, sel)
                disarmDest(sel)
                setDestGUID(lane, r.GetTrackGUID(sel))
                Loop.dest[lane] = sel
            end
        end
    end
    r.Undo_EndBlock2(0, "CP Looper: set up", -1)
    Loop.SetFreeRun(true)
    Loop.SetArmedLane(0)
    return router
end

-- Force the engine to reload from disk (picks up an edited .jsfx). The recorded
-- loops SURVIVE: they live in gmem and the JSFX @init only rebuilds per-instance
-- state. They are dropped only if the .jsfx changed its gmem layout (LAYOUT_VER),
-- which invalidates the block on purpose.
function Loop.ReloadEngine()
    local router = Loop.track
    if not valid(router) then return end
    installJSFX()
    r.Undo_BeginBlock2(0)
    local old = findLooperFX(router)
    while old >= 0 do r.TrackFX_Delete(router, old); old = findLooperFX(router) end
    local fx = r.TrackFX_AddByName(router, ADD_NAME, false, -1)
    if fx > 0 then r.TrackFX_CopyToTrack(router, fx, router, 0, true); fx = 0 end
    r.TrackFX_Show(router, 0, 2); r.TrackFX_Show(router, 0, 0)
    r.Undo_EndBlock2(0, "CP Looper: reload engine", -1)
    Loop.SetFreeRun(true)
    Loop.SetArmedLane(0)
end

-- ---------------------------------------------------------------------------
-- Commands (payload first, seq last — the JSFX acts on the seq bump)
-- ---------------------------------------------------------------------------
local function sendCmd(cmd, lane, arg)
    if not attached then return end
    gwrite(G_CMD, cmd)
    gwrite(G_CMD_LANE, lane or 0)
    gwrite(G_CMD_ARG, arg or 0)
    seq = seq + 1
    gwrite(G_CMD_SEQ, seq)
end

-- REC: clears + captures when the clock runs; ARMS (non-destructive, mode 4)
-- when it doesn't, and capture begins by itself on the first running block.
function Loop.Rec(lane)      sendCmd(1, lane) end
function Loop.Stop(lane)     sendCmd(2, lane) end  -- finalize recording -> playing
function Loop.Clear(lane)    sendCmd(3, lane) end  -- -> empty, notes off
function Loop.Panic()        sendCmd(4, 0)    end  -- all playback notes off
function Loop.Play(lane)     sendCmd(5, lane) end  -- launch a stopped clip
function Loop.StopClip(lane) sendCmd(6, lane) end  -- halt a playing clip
function Loop.ClearAll()     sendCmd(7, 0)    end  -- wipe every lane (explicit only)

-- REC button behaviour: recording or armed -> stop/cancel, otherwise (re)record.
function Loop.ToggleRec(lane)
    local m = Loop.Mode(lane)
    if m == 1 or m == 4 then Loop.Stop(lane) else Loop.Rec(lane) end
end

-- Play/Stop button: launch a stopped clip / halt a playing one.
function Loop.ToggleClip(lane)
    local m = Loop.Mode(lane)
    if m == 3 then Loop.StopClip(lane) elseif m == 2 then Loop.Play(lane) end
end

-- Global clock: follow the host transport (synced to an external clock when
-- slaved) or run free so clips launch with the transport stopped.
function Loop.SetFreeRun(on) if attached then gwrite(G_FREERUN, on and 1 or 0) end end
function Loop.GetFreeRun()   return attached and gread(G_FREERUN) >= 0.5 end

-- Armed lane: the lane whose routed instrument you hear while playing live (the
-- JSFX re-channels incoming MIDI onto that lane's channel).
function Loop.SetArmedLane(lane) if attached then gwrite(G_ARMED, lane) end end
function Loop.GetArmedLane()
    return attached and math.floor((gread(G_ARMED) or 0) + 0.5) or 0
end

-- ---------------------------------------------------------------------------
-- Per-lane control (direct write)
-- ---------------------------------------------------------------------------
function Loop.SetLengthBars(lane, bars)
    if attached then gwrite(G_LANE_CTRL + lane * 8 + 0, bars) end
end
function Loop.GetLengthBars(lane)
    if not attached then return 1 end
    local b = gread(G_LANE_CTRL + lane * 8 + 0)
    return (b and b > 0) and b or 1
end
function Loop.SetMute(lane, on)
    if attached then gwrite(G_LANE_CTRL + lane * 8 + 1, on and 1 or 0) end
end
function Loop.GetMute(lane)
    return attached and gread(G_LANE_CTRL + lane * 8 + 1) >= 0.5
end

-- ---------------------------------------------------------------------------
-- Per-lane state (read)
-- ---------------------------------------------------------------------------
-- 0 empty · 1 recording · 2 stopped (has content) · 3 playing · 4 armed
function Loop.Mode(lane)       return attached and gread(G_LANE_STATE + lane * 8 + 0) or 0 end
function Loop.NEv(lane)        return attached and gread(G_LANE_STATE + lane * 8 + 1) or 0 end
function Loop.Phase(lane)      return attached and gread(G_LANE_STATE + lane * 8 + 2) or 0 end
function Loop.LenBeats(lane)   local v = attached and gread(G_LANE_STATE + lane * 8 + 3) or 0; return v > 0 and v or 4 end
function Loop.EvtVersion(lane) return attached and gread(G_LANE_STATE + lane * 8 + 4) or 0 end
function Loop.HasContent(lane) return attached and gread(G_LANE_STATE + lane * 8 + 5) >= 0.5 end

-- ---------------------------------------------------------------------------
-- Transport (read)
-- ---------------------------------------------------------------------------
function Loop.Tempo()   return attached and gread(G_TRANSPORT + 0) or 0 end
function Loop.Playing()
    if not attached then return false end
    local ps = gread(G_TRANSPORT + 1) or 0
    return (math.floor(ps) & 1) == 1
end
function Loop.Beat()    return attached and gread(G_TRANSPORT + 2) or 0 end
function Loop.TsNum()   local v = attached and gread(G_TRANSPORT + 4) or 4; return v > 0 and v or 4 end
-- non-zero once the JSFX has run its @init at least once (engine alive)
function Loop.EngineAlive() return attached and gread(G_VERSION) >= 1 end

-- How many times the engine has been reset (REAPER re-runs @init on transport
-- start, samplerate change, FX reload…). The loops survive it now, but the UI
-- watches this to re-read its caches — and it is the field proof that a reset
-- happened at all, which is how the old loop-loss bug was pinned down.
function Loop.InitCount() return attached and (gread(G_INIT_COUNT) or 0) or 0 end

-- ---------------------------------------------------------------------------
-- Note storage (each note = start, length, pitch, vel — all in beats/0..127).
-- The gmem note list is the loop's single source of truth: the JSFX plays it
-- (gate) and captures into it; the editor writes it. `nev` (LANE_STATE+1) is
-- shared, owned by the JSFX while recording and by the UI otherwise.
-- ---------------------------------------------------------------------------
local function noteAddr(lane, i)   -- i is 0-based
    return G_NOTE_BASE + (lane * Loop.MAX_NOTES + i) * Loop.NOTE_STRIDE
end

function Loop.NoteCount(lane)
    if not attached then return 0 end
    local n = gread(G_LANE_STATE + lane * 8 + 1) or 0
    if n > Loop.MAX_NOTES then n = Loop.MAX_NOTES end
    return n
end

function Loop.SetNoteCount(lane, n)
    if attached then gwrite(G_LANE_STATE + lane * 8 + 1, n) end
end

function Loop.BumpVer(lane)
    if not attached then return end
    gwrite(G_LANE_STATE + lane * 8 + 4, (gread(G_LANE_STATE + lane * 8 + 4) or 0) + 1)
end

-- read note i (0-based) -> start, len, pitch, vel
function Loop.GetNote(lane, i)
    local a = noteAddr(lane, i)
    return gread(a + 0), gread(a + 1), gread(a + 2), gread(a + 3)
end

-- write note i (0-based). Does NOT touch the count (caller owns nev).
function Loop.PutNote(lane, i, start, len, pitch, vel)
    if not attached then return end
    local a = noteAddr(lane, i)
    gwrite(a + 0, start)
    gwrite(a + 1, len)
    gwrite(a + 2, pitch)
    gwrite(a + 3, vel)
end

-- Snapshot for visualization / editing (zero-alloc: fills caller arrays).
function Loop.ReadNotes(lane, out_start, out_len, out_pitch, out_vel)
    if not attached then return 0 end
    local n = Loop.NoteCount(lane)
    for i = 0, n - 1 do
        local a = noteAddr(lane, i)
        out_start[i + 1] = gread(a + 0)
        out_len[i + 1]   = gread(a + 1)
        out_pitch[i + 1] = gread(a + 2)
        out_vel[i + 1]   = gread(a + 3)
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Session recall
--
-- The loops live in gmem, which belongs to the REAPER session, not the project.
-- This mirrors them into the ROUTER TRACK's P_EXT state, so they are saved
-- inside the .rpp like any other track data — no side-car file, no format of
-- our own, and they travel with the project (copy the track, keep the loops).
--
-- Wire format, one string, printable separators only (P_EXT is one line of the
-- track chunk, so no newlines):
--   "1;<lane>;<lane>;<lane>;<lane>"            1 = format version
--   lane = "bars|muted|n|s,l,p,v|s,l,p,v|…"    starts/lengths in beats
-- ---------------------------------------------------------------------------
local DATA_KEY = "P_EXT:" .. EXT_TAG .. "_DATA"

local function num(v)          -- compact, still exact enough for beats
    return string.format("%.6g", v or 0)
end

function Loop.Serialize()
    if not attached then return "" end
    local out = { "1" }
    for lane = 0, Loop.MAX_LANES - 1 do
        local n = Loop.NoteCount(lane)
        local parts = { num(Loop.GetLengthBars(lane)),
                        Loop.GetMute(lane) and "1" or "0",
                        tostring(n) }
        for i = 0, n - 1 do
            local s, l, p, v = Loop.GetNote(lane, i)
            parts[#parts + 1] = num(s) .. "," .. num(l) .. ","
                             .. string.format("%d,%d", math.floor((p or 0) + 0.5),
                                                       math.floor((v or 100) + 0.5))
        end
        out[#out + 1] = table.concat(parts, "|")
    end
    return table.concat(out, ";")
end

-- Fill gmem from a serialized string. Notes are written BEFORE the count, so the
-- engine can never read a count that outruns the data it points at.
function Loop.Deserialize(str)
    if not attached or not str or str == "" then return false end
    local fields = {}
    for f in str:gmatch("[^;]+") do fields[#fields + 1] = f end
    if fields[1] ~= "1" then return false end
    local loaded = 0
    for lane = 0, Loop.MAX_LANES - 1 do
        local blk = fields[lane + 2]
        if blk then
            local t = {}
            for f in blk:gmatch("[^|]+") do t[#t + 1] = f end
            local bars  = tonumber(t[1]) or 1
            local muted = t[2] == "1"
            local n     = math.floor(tonumber(t[3]) or 0)
            if n > Loop.MAX_NOTES then n = Loop.MAX_NOTES end
            local written = 0
            for i = 1, n do
                local rec = t[3 + i]
                if rec then
                    local s, l, p, v = rec:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
                    if s then
                        Loop.PutNote(lane, written, tonumber(s) or 0, tonumber(l) or 0.25,
                                     tonumber(p) or 60, tonumber(v) or 100)
                        written = written + 1
                    end
                end
            end
            Loop.SetLengthBars(lane, bars)
            Loop.SetMute(lane, muted)
            Loop.SetNoteCount(lane, written)
            Loop.BumpVer(lane)
            loaded = loaded + written
        end
    end
    return true, loaded
end

function Loop.SaveState()
    if not valid(Loop.track) then return false end
    r.GetSetMediaTrackInfo_String(Loop.track, DATA_KEY, Loop.Serialize(), true)
    return true
end

function Loop.SavedState()
    if not valid(Loop.track) then return "" end
    local _, v = r.GetSetMediaTrackInfo_String(Loop.track, DATA_KEY, "", false)
    return v or ""
end

-- Recall into gmem. Refuses when any lane already holds notes unless forced: a
-- recall must never silently overwrite what is currently playing.
function Loop.LoadState(force)
    if not valid(Loop.track) then return false end
    if not force then
        for lane = 0, Loop.MAX_LANES - 1 do
            if Loop.NoteCount(lane) > 0 then return false end
        end
    end
    return Loop.Deserialize(Loop.SavedState())
end

function Loop.HasSavedState()
    return Loop.SavedState() ~= ""
end

return Loop
