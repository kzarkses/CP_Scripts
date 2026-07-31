-- CP_Looper / Loop.lua — engine bridge (no UI)
--
-- Owns the looper track and talks to the CP_MidiLooper JSFX through the
-- shared gmem block. The JSFX is the real-time engine (phase-locked to the
-- host beat grid so it stays synced to an external clock); this module is
-- just the wire between the CP_Toolkit UI and that engine.
--
-- Indices below MUST stay identical to CP_JSFX/CP_MidiLooper.jsfx.

local Loop = {}
-- Bound at LOAD, not only in Loop.init. This module is initialised lazily on
-- purpose — its init rescans the project and re-syncs the router's sends, and
-- an editor opened on an audio item has no business doing that — but several
-- of its queries need nothing more than the REAPER API (Loop.KitViewOfTrack
-- reads track ext-state; it never touches gmem). Leaving `r` nil until init
-- turned every one of those into a crash for a caller that had done nothing
-- wrong. init still rebinds it, and still owns gmem and Tracks.
local r = reaper

-- ---------------------------------------------------------------------------
-- Layout (mirror of the JSFX)
-- ---------------------------------------------------------------------------
-- 8 lanes. The Session view spends them two per track (a playing buffer and
-- a silent twin) so a clip change lands exactly on the quantize boundary —
-- see ANALYSE_Ableton_Session.md §3.2. Verified to fit the gmem layout as
-- is: LANE_CTRL 100 + 8*8 = 164 < 200, LANE_STATE 200 + 8*8 = 264 < 3000,
-- notes 10000 + 8*1024*4 = 42768. Going past 8 would need those bases moved
-- AND the layout signature bumped.
Loop.MAX_LANES   = 8
Loop.MAX_NOTES   = 1024
Loop.NOTE_STRIDE = 4       -- start, length, pitch, vel (all in beats/0..127)

-- A musical TRACK is a PAIR of lanes: the half you hear and a silent twin.
-- Which half is sounding changes every time a clip swaps, so nothing above
-- this module may remember a lane number — hosts address a track and ask
-- Loop.LiveLane / Loop.LaneOfTag for the rest. That is the whole reason the
-- Session grid, the Looper and the Editor can no longer disagree about what
-- is playing.
Loop.TRACKS = Loop.MAX_LANES // 2

local G_CMD_W      = 9     -- command ring: write cursor (see sendCmd)
local G_CMDQ       = 400   -- command ring: stride 3 (cmd, lane, arg)
local CMDQ_SLOTS   = 32
local G_FREERUN    = 3     -- 0 = follow host transport, 1 = free internal clock
local G_ARMED      = 4     -- lane monitoring live input, or -1 for NOBODY
local G_LAUNCH_Q   = 6     -- launch quantize in beats (0 = immediate)
local G_AUDIO_RUN  = 8     -- 1 = a host is playing a sound cell (see SetAudioRun)
local G_LANE_CTRL  = 100   -- stride 8: +0 length_bars, +1 muted
local G_LANE_STATE = 200   -- stride 8: +0 mode,+1 nev(shared),+2 phase,+3 lenbeats,+4 evtver,+5 hascontent,+6 pending,+7 pend_target
local G_TRANSPORT  = 3000  -- +0 tempo,+1 play_state,+2 beat,+3 spb,+4 ts_num,+5 ts_denom,+6 srate
local G_INIT_COUNT = 3095  -- incremented by the JSFX @init: counts engine resets
local G_FREEBEAT   = 3096  -- free clock position (the engine's beat when free-running)
local G_ENG_LANES  = 3097  -- lanes the LOADED JSFX actually serves
local G_BUILD      = 3094  -- behaviour revision of the LOADED JSFX
local G_VERSION    = 3099

-- The behaviour revision this module expects. The .jsfx is only recopied into
-- REAPER's Effects folder on create/reload, so a project opened with an older
-- instance keeps running the old code — silently, and with symptoms that look
-- like Lua bugs (a shortened loop folding its later bars onto the first one
-- was exactly that). Bumping this makes Loop.Ensure refresh the engine, which
-- the loops survive; bumping the JSFX's LAYOUT_VER would wipe them.
Loop.ENGINE_BUILD = 6
local G_NOTE_BASE  = 10000

local GMEM_NAME  = "CP_MidiLooper"
local ADD_NAME   = "JS:CP_Scripts/CP_MidiLooper.jsfx"
local EXT_TAG    = "CP_LOOPER"

-- bound for speed (rebound in init once reaper is known)
local gread, gwrite

local attached = false        -- did gmem_attach succeed
local Tracks                  -- optional Engine/Tracks (CP folder + mark)

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function Loop.init(reaper_api, tracks_module)
    r = reaper_api
    Tracks = tracks_module
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

-- Re-select this module's gmem block. gmem_attach is GLOBAL to the script
-- — it switches the segment for every gmem_read in the process — and
-- Engine/Tempo re-attaches to its own block on every Tempo.Poll(). A host
-- that polls both must call this before its Loop reads each frame; a host
-- that only uses Loop never needs it (init attached once).
function Loop.Reattach()
    if attached then r.gmem_attach(GMEM_NAME) end
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

-- ---------------------------------------------------------------------------
-- THE SOUND CHANNEL. A column that plays a SOUND cell speaks on a channel of
-- its own, and its sampler is fed by a send filtered to that channel alone.
--
-- The whole point is that the column's INSTRUMENT never hears it. Every send
-- this module makes is already narrowed to one source channel, so keeping the
-- two apart is not a convention to remember — it is the wiring. A trigger note
-- aimed at the sampler is inaudible to the synth on the same column because it
-- is not on the wire that reaches it.
--
-- Lanes hold channels 1..8 and the suite's preview tag holds 16 (Kit.UI_CHAN,
-- mirrored in the engine, which swallows it), so 9..15 are free and the four
-- columns take 9..12. The engine computes the same number in lane_chan().
Loop.AUDIO_CH = 8          -- 0-based base; column c speaks on MIDI channel c+9

local function findAudioSend(router, col)
    local want = Loop.AUDIO_CH + col + 1
    local n = r.GetTrackNumSends(router, 0)
    for i = 0, n - 1 do
        local mf = r.GetTrackSendInfo_Value(router, 0, i, "I_MIDIFLAGS")
        local sc = r.GetTrackSendInfo_Value(router, 0, i, "I_SRCCHAN")
        if (math.floor(mf) & 0x1F) == want and sc == -1 then return i end
    end
    return -1
end

-- Point column `col`'s sound channel at `track` (nil = nowhere). Idempotent:
-- an existing send to the same track is left alone, so calling this every time
-- a cell is armed costs a scan and nothing else, and never dirties the project.
function Loop.WireAudio(col, track)
    local router = Loop.track
    if not valid(router) then return false end
    local i = findAudioSend(router, col)
    if i >= 0 then
        local cur = r.GetTrackSendInfo_Value(router, 0, i, "P_DESTTRACK")
        if valid(track) and cur == track then return true end
        r.RemoveTrackSend(router, 0, i)
    end
    if not (valid(track) and track ~= router) then return false end
    local si = r.CreateTrackSend(router, track)
    if si < 0 then return false end
    r.SetTrackSendInfo_Value(router, 0, si, "I_SRCCHAN", -1)
    r.SetTrackSendInfo_Value(router, 0, si, "I_MIDIFLAGS", Loop.AUDIO_CH + col + 1)
    return true
end

function Loop.AudioDest(col)
    local router = Loop.track
    if not valid(router) then return nil end
    local i = findAudioSend(router, col)
    if i < 0 then return nil end
    local tr = r.GetTrackSendInfo_Value(router, 0, i, "P_DESTTRACK")
    return valid(tr) and tr or nil
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
    -- Heal the pairing first: a pair is ONE musical track, and the sounding
    -- half's destination is the truth. Projects routed before the pairing
    -- existed have a twin pointing nowhere, which is why they fell silent on
    -- every other launch — this is the one-time repair, and it costs nothing
    -- when the two already agree.
    local n = Loop.TRACKS
    for t = 0, n - 1 do
        local g = getDestGUID(t)
        if getDestGUID(t + n) ~= g then setDestGUID(t + n, g) end
    end
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

local function wireLane(router, lane, track)
    removeLaneSend(router, lane)
    if valid(track) and track ~= router then
        makeLaneSend(router, lane, track)
        setDestGUID(lane, r.GetTrackGUID(track))
        Loop.dest[lane] = track
    else
        setDestGUID(lane, "")
        Loop.dest[lane] = nil
    end
end

-- Route a TRACK to a destination instrument (nil = unroute), and disarm that
-- destination so live input only reaches it through the router (no double
-- trigger). BOTH halves of the lane pair are wired to the same instrument in
-- one gesture: routing only the sounding half looks fine until a clip swaps,
-- and then the track goes silent for no visible reason. Taking a lane number
-- here rather than a track index keeps CP_Looper's call site unchanged — the
-- pair is resolved from it.
function Loop.SetLaneDest(lane, track)
    local router = Loop.track
    if not valid(router) then return end
    local t = Loop.TrackOfLane(lane)
    r.Undo_BeginBlock2(0)
    wireLane(router, t, track)
    wireLane(router, t + Loop.TRACKS, track)
    if valid(track) and track ~= router then disarmDest(track) end
    r.Undo_EndBlock2(0, "CP Looper: route track " .. (t + 1), -1)
end

-- Cached destination pointer (zero-alloc per frame). Self-heals if the track was
-- deleted; does not re-read gmem/strings on the hot path.
function Loop.GetLaneDest(lane)
    local tr = Loop.dest[lane]
    if tr and not valid(tr) then Loop.dest[lane] = nil; return nil end
    return tr
end

-- ---------------------------------------------------------------------------
-- Kit view: the pads of the CP kit a lane is routed to, shaped like the Kit
-- module's surface (BASE/MAX/pads[note].fx/.name) so Rows.Build/Rows.Label
-- can consume either. Drum rows in the editor must mirror the INSTRUMENT
-- (one row per pad holding a sample), not just the pitches the clip already
-- uses — loading a sample onto a pad grows a row here on the next project
-- change. Read-only; rebuilt at most once per project state change.
-- ---------------------------------------------------------------------------
local kitview = { BASE = 0, MAX = 128, pads = {}, version = 0 }
local kv_change, kv_lane = -1, -1

-- The routed track may be the kit parent itself, its MIDI bus, or a pad
-- child: walk up the folder chain looking for the CP_KIT mark.
local function kitParentOf(tr)
    local hops = 0
    while tr and hops < 16 do
        local _, v = r.GetSetMediaTrackInfo_String(tr, "P_EXT:CP_KIT", "", false)
        if v and v ~= "" then return tr end
        tr = r.GetParentTrack(tr)
        hops = hops + 1
    end
    return nil
end

-- Same thing addressed by TRACK: the editor needs the pads of the instrument
-- a clip plays into, and it does not always hold a lane (a plain MIDI item
-- sitting on a kit track deserves the same rows).
function Loop.KitViewOfTrack(tr)
    local c = r.GetProjectStateChangeCount(0)
    if c == kv_change and tr == kv_lane then
        return kitview.n > 0 and kitview or nil
    end
    kv_change, kv_lane = c, tr
    local pads, n = kitview.pads, 0
    for k in pairs(pads) do pads[k] = nil end
    local parent = kitParentOf(tr)
    if parent then
        local i = math.floor(r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER"))
        local depth, cnt = 1, r.CountTracks(0)
        while depth > 0 and i < cnt do
            local ch = r.GetTrack(0, i)
            local _, nv = r.GetSetMediaTrackInfo_String(ch, "P_EXT:CP_KIT_NOTE", "", false)
            local note = tonumber(nv or "")
            if note and note >= 0 and note <= 127
               and r.TrackFX_GetCount(ch) > 0 then
                local _, nm = r.GetSetMediaTrackInfo_String(ch, "P_NAME", "", false)
                pads[note] = { fx = true, name = nm }
                n = n + 1
            end
            depth = depth + r.GetMediaTrackInfo_Value(ch, "I_FOLDERDEPTH")
            i = i + 1
        end
    end
    kitview.n = n
    kitview.version = kitview.version + 1
    return n > 0 and kitview or nil
end

function Loop.KitView(lane)
    return Loop.KitViewOfTrack(Loop.GetLaneDest(lane))
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
    local t = Loop.TrackOfLane(lane)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "Track " .. (t + 1) .. " inst", true)
    wireLane(router, t, tr)                  -- both halves of the pair, or the
    wireLane(router, t + Loop.TRACKS, tr)    -- clip goes silent on the swap
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
    local tr
    if Tracks then
        -- Born inside the shared CP folder, with the common ownership mark.
        tr = Tracks.NewChild("looper", "router", "CP Looper")
    else
        local idx = r.CountTracks(0)
        r.InsertTrackAtIndex(idx, false)
        tr = r.GetTrack(0, idx)
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Looper", true)
    end
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
    Loop.SetArmedLane(nil)   -- nothing monitors until you arm something
    -- One bar, as in Ableton — and for the same reason: the launch quantize is
    -- what makes a clip swap, a scene and a TAKE land on the grid instead of
    -- wherever the mouse happened to be. Zero is a legitimate choice, but it
    -- is a terrible default: it makes the A/B twin buffer pointless and it
    -- starts a recording mid-bar.
    Loop.SetLaunchQ(Loop.TsNum())
    return router
end

-- Force the engine to reload from disk (picks up an edited .jsfx). The recorded
-- loops SURVIVE: they live in gmem and the JSFX @init only rebuilds per-instance
-- state. They are dropped only if the .jsfx changed its gmem layout (LAYOUT_VER),
-- which invalidates the block on purpose.
function Loop.ReloadEngine()
    local router = Loop.track
    if not valid(router) then return false end
    -- The loops themselves live in gmem and survive the swap; these three
    -- settings do not, so carry them across instead of resetting the user's
    -- clock and arm every time the engine is refreshed.
    local fr, arm, lq = Loop.GetFreeRun(), Loop.GetArmedLane(), Loop.GetLaunchQ()
    installJSFX()
    r.Undo_BeginBlock2(0)
    local old = findLooperFX(router)
    while old >= 0 do r.TrackFX_Delete(router, old); old = findLooperFX(router) end
    local fx = r.TrackFX_AddByName(router, ADD_NAME, false, -1)
    if fx > 0 then r.TrackFX_CopyToTrack(router, fx, router, 0, true); fx = 0 end
    r.TrackFX_Show(router, 0, 2); r.TrackFX_Show(router, 0, 0)
    r.Undo_EndBlock2(0, "CP Looper: reload engine", -1)
    Loop.SetFreeRun(fr)
    Loop.SetArmedLane(arm)
    Loop.SetLaunchQ(lq or 0)
    return true
end

-- Bring the engine up to what this build needs, from ANY window — the Session
-- and the Editor are as entitled to it as CP_Looper, and having to go open a
-- third script first was never a design, only an accident of history.
-- `create` gates the one step that touches the project (making the router
-- track): a window that merely wants to READ a lane must never conjure tracks
-- into someone's project. Returns ok, note.
function Loop.Ensure(create)
    if not attached then return false, "This REAPER build has no gmem." end
    if not valid(Loop.track) then Loop.reconnect() end
    if not valid(Loop.track) or not Loop.IsAttached() then
        if not create then return false, "No looper engine in this project." end
        local router, err = Loop.Setup()
        if not router then return false, err or "Could not create the engine." end
        return true, "Looper engine created"
    end
    -- The engine loaded in the chain can be OLDER than this build (the .jsfx
    -- is only recopied on create/reload), in three ways that all misbehave in
    -- silence: too few lanes, so every command aimed at the upper half is
    -- dropped (a clip that never starts, a column that stops instead of
    -- switching); an out-of-date behaviour revision; or NOT RUNNING AT ALL —
    -- a JSFX that failed to compile is still in the chain, still answers to
    -- its name, and says nothing at all. Refresh it; the loops live in gmem
    -- and survive the swap.
    --
    -- That last case used to be the one we did NOT refresh (the check was
    -- gated on the engine being alive), so the only way out of a bad build was
    -- to go and press a button in another window — which is precisely the
    -- situation where the suite has to repair itself. A silent engine reports
    -- zero lanes, so it now falls into the same branch as an old one.
    if Loop.EngineLanes() < Loop.MAX_LANES
       or Loop.EngineBuild() < Loop.ENGINE_BUILD then
        -- Builds before 3 had no "nobody armed": the arm sitting in gmem right
        -- now is the engine's own clamp, not a decision, and carrying it across
        -- the reload would leave a lane monitoring in every project that ever
        -- ran an older build. Upgrading is exactly when to drop it.
        local stale_arm = Loop.EngineBuild() < 3
        local ok = Loop.ReloadEngine()
        if stale_arm then Loop.SetArmedLane(nil) end
        if ok then return true, "Looper engine refreshed" end
        return false, "The loaded engine is out of date and would not reload."
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- Commands (payload first, cursor last — the engine drains on the bump)
-- ---------------------------------------------------------------------------
-- A RING, and the engine takes everything new on its next block. That is the
-- whole point: the gestures that matter are never one command. Swapping a
-- clip is two (stop this half, launch that one) and a scene is one pair per
-- track — and while they left one at a time, one per frame, they could land on
-- either side of a quantize boundary. Half a scene starting a bar before the
-- other half is not a quantize, it is a bug with good manners.
--
-- The cursor is read from gmem rather than kept here: the ring is shared by
-- every CP window, and a script counting on its own would write over another's
-- un-drained command. Reading it back makes the order global by construction.
local function sendCmd(cmd, lane, arg)
    if not attached then return end
    local w = gread(G_CMD_W) or 0
    local a = G_CMDQ + (w % CMDQ_SLOTS) * 3
    gwrite(a + 0, cmd)
    gwrite(a + 1, lane or 0)
    gwrite(a + 2, arg or 0)
    gwrite(G_CMD_W, w + 1)
end

-- REC: clears + captures when the clock runs; ARMS (non-destructive, mode 4)
-- when it doesn't, and capture begins by itself on the first running block.
function Loop.Rec(lane)      sendCmd(1, lane) end
function Loop.Stop(lane)     sendCmd(2, lane) end  -- finalize recording -> playing
-- clearing empties the lane, so it no longer holds anyone's clip: drop the
-- occupancy tag with it or a window would keep following a lane gone empty
function Loop.Clear(lane)    Loop.SetLaneTag(lane, 0); sendCmd(3, lane) end
function Loop.Panic()        sendCmd(4, 0)    end  -- all playback notes off
function Loop.Play(lane)     sendCmd(5, lane) end  -- launch a stopped clip
function Loop.StopClip(lane) sendCmd(6, lane) end  -- halt a playing clip
function Loop.ClearAll()                          -- wipe every lane (explicit only)
    for l = 0, Loop.MAX_LANES - 1 do Loop.SetLaneTag(l, 0) end
    sendCmd(7, 0)
end
-- OVERDUB: capture INTO the playing loop — nothing cleared, no auto-stop,
-- layers stack until the next Overdub (or Stop) finalizes back to playing.
-- A second call while queued cancels; while overdubbing it punches out.
function Loop.Overdub(lane)  sendCmd(8, lane) end

-- REC button behaviour: recording/armed/overdubbing -> stop/cancel,
-- otherwise (re)record. A queued rec cancels on the second press (the JSFX
-- treats REC as a toggle while pending), so this maps straight to Rec.
function Loop.ToggleRec(lane)
    if Loop.Pending(lane) == 3 then Loop.Rec(lane) return end
    local m = Loop.Mode(lane)
    if m == 1 or m == 4 or m == 5 then Loop.Stop(lane) else Loop.Rec(lane) end
end

-- Play/Stop button: launch a stopped clip / halt a playing one. While a launch
-- or a stop is queued, the same button cancels it (the JSFX cancels a pending
-- play on STOP and a pending stop on PLAY).
function Loop.ToggleClip(lane)
    local p = Loop.Pending(lane)
    if p == 1 then Loop.StopClip(lane) return end
    if p == 2 then Loop.Play(lane) return end
    local m = Loop.Mode(lane)
    if m == 3 then Loop.StopClip(lane) elseif m == 2 then Loop.Play(lane) end
end

-- Launch quantize, in beats (0 = act immediately). The UI cycles Off / beat /
-- bar / 2 bars / 4 bars; the JSFX only sees beats so any grid works.
function Loop.SetLaunchQ(beats)
    if attached then gwrite(G_LAUNCH_Q, beats or 0) end
end
function Loop.GetLaunchQ()
    if not attached then return 0 end
    return gread(G_LAUNCH_Q) or 0
end

-- Global clock: follow the host transport (synced to an external clock when
-- slaved) or run free so clips launch with the transport stopped.
function Loop.SetFreeRun(on) if attached then gwrite(G_FREERUN, on and 1 or 0) end end
function Loop.GetFreeRun()   return attached and gread(G_FREERUN) >= 0.5 end

-- "Something of MINE is sounding" — said by a host that plays audio cells,
-- which the engine cannot see (they are CF previews, not lanes). The free
-- clock is the SESSION's transport and it sits at zero while the session is
-- silent, so a sample playing with no lane running would otherwise take its
-- phase reference with it. Written every frame while such a host runs, and
-- cleared when it closes: a flag that is only ever set is a clock that never
-- stops.
function Loop.SetAudioRun(on) if attached then gwrite(G_AUDIO_RUN, on and 1 or 0) end end
function Loop.GetAudioRun()   return attached and gread(G_AUDIO_RUN) >= 0.5 end

-- A queued launch with no date: it is waiting for the CLOCK itself (Follow,
-- with a transport that is not running) and fires with its first block. The
-- UI says so instead of counting down to a beat that has no date.
function Loop.PendingWaitsClock(lane)
    if not attached then return false end
    return (gread(G_LANE_STATE + lane * 8 + 7) or 0) < -1e8
end

-- Armed lane: the lane whose routed instrument you hear while playing live (the
-- JSFX re-channels incoming MIDI onto that lane's channel). NOBODY is a real
-- state — pass nil. It has to be, because the alternative is what the engine
-- used to do: clamp an unset arm to lane 0, so a project you had not touched
-- still fed every note the suite previewed into lane 0's instrument.
function Loop.SetArmedLane(lane) if attached then gwrite(G_ARMED, lane or -1) end end

-- Live MIDI listening. The router is armed on ALL inputs and fans your playing
-- out to each lane's instrument through channel-filtered sends — and a send
-- ignores the destination's arm state, which is why unarmed tracks sound. Turn
-- this off and the router stops receiving, so the keyboard is yours again.
-- It is a track property, so the choice is saved with the project.
function Loop.SetListen(on)
    if not valid(Loop.track) then return end
    r.SetMediaTrackInfo_Value(Loop.track, "I_RECARM", on and 1 or 0)
    r.SetMediaTrackInfo_Value(Loop.track, "I_RECMON", on and 1 or 0)
end

function Loop.GetListen()
    if not valid(Loop.track) then return false end
    return r.GetMediaTrackInfo_Value(Loop.track, "I_RECARM") == 1
       and r.GetMediaTrackInfo_Value(Loop.track, "I_RECMON") > 0
end
-- nil when nothing is armed — callers must handle it rather than fall back to
-- a lane, which is exactly the assumption that made the arm invisible.
function Loop.GetArmedLane()
    if not attached then return nil end
    local a = math.floor((gread(G_ARMED) or -1) + 0.5)
    if a < 0 or a >= Loop.MAX_LANES then return nil end
    return a
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

-- THIS LANE CARRIES A SOUND, so the engine speaks it on the column's sound
-- channel instead of the lane's own (see Loop.AUDIO_CH and lane_chan in the
-- .jsfx). Set on BOTH halves of a pair by the caller — a clip swap must not
-- move the sound to another sampler halfway through.
--
-- It lives in gmem, which belongs to the REAPER session and not to the project,
-- so a project reopened cold comes back with the flag CLEAR while its lanes may
-- be restored as playing. A host that owns sound cells must therefore re-stamp
-- the flag before anything can sound, or the first launch after a reload fires
-- a trigger note at the column's instrument.
function Loop.SetLaneAudio(lane, on)
    if attached then gwrite(G_LANE_CTRL + lane * 8 + 3, on and 1 or 0) end
end
function Loop.GetLaneAudio(lane)
    return attached and gread(G_LANE_CTRL + lane * 8 + 3) >= 0.5
end

-- ---------------------------------------------------------------------------
-- Per-lane state (read)
-- ---------------------------------------------------------------------------
-- 0 empty · 1 recording · 2 stopped (has content) · 3 playing · 4 armed ·
-- 5 overdubbing (plays AND captures)
function Loop.Mode(lane)       return attached and gread(G_LANE_STATE + lane * 8 + 0) or 0 end
function Loop.NEv(lane)        return attached and gread(G_LANE_STATE + lane * 8 + 1) or 0 end
function Loop.Phase(lane)      return attached and gread(G_LANE_STATE + lane * 8 + 2) or 0 end
function Loop.LenBeats(lane)   local v = attached and gread(G_LANE_STATE + lane * 8 + 3) or 0; return v > 0 and v or 4 end
function Loop.EvtVersion(lane) return attached and gread(G_LANE_STATE + lane * 8 + 4) or 0 end
function Loop.HasContent(lane) return attached and gread(G_LANE_STATE + lane * 8 + 5) >= 0.5 end
-- queued launch: 0 none · 1 play · 2 stop · 3 rec · 4 stop-rec · 5 overdub
-- (fires at PendingTarget)
function Loop.Pending(lane)
    if not attached then return 0 end
    return math.floor((gread(G_LANE_STATE + lane * 8 + 6) or 0) + 0.5)
end
function Loop.PendingTarget(lane) return attached and gread(G_LANE_STATE + lane * 8 + 7) or 0 end

-- ---------------------------------------------------------------------------
-- Tracks = lane pairs (the layer every front-end talks to)
-- ---------------------------------------------------------------------------
-- Track t owns lane t and lane t + TRACKS. The ENGINE decides which of the
-- two is sounding; we re-derive it once per frame and hand it out. Nobody
-- caches a lane number across frames — a cached one goes stale the moment a
-- clip swaps, and a stale lane is a missing playhead, a wrong transport
-- button and an edit written into the clip you were NOT editing.
local live = {}
for t = 0, Loop.TRACKS - 1 do live[t] = t end

-- "This lane is sounding" — ONE definition, so no two windows can disagree
-- about what playing means. Recording and overdubbing count: both put notes
-- out. (Modes: 0 empty · 1 recording · 2 stopped · 3 playing · 4 armed ·
-- 5 overdubbing.)
function Loop.IsRunning(lane)
    if not attached then return false end
    local m = math.floor((gread(G_LANE_STATE + lane * 8 + 0) or 0) + 0.5)
    return m == 1 or m == 3 or m == 5
end

-- "busy" = sounding or about to: a queued launch already belongs to the half
-- that will play, otherwise the swap would flicker back for one frame.
-- ARMED (4) and a queued REC (pending 3) count for the same reason — a take
-- waiting on the transport, or on the next bar line, is the half the user is
-- looking at. Leaving them out let the live half flip to the twin between the
-- click and the first captured note, and everything watching the recording
-- then watched the wrong lane.
local function laneBusy(lane)
    local m = gread(G_LANE_STATE + lane * 8 + 0) or 0
    if m == 3 or m == 5 or m == 1 or m == 4 then return true end
    local p = gread(G_LANE_STATE + lane * 8 + 6) or 0
    return p == 1 or p == 3
end

local function resolveLive()
    if not attached then return end
    local n = Loop.TRACKS
    for t = 0, n - 1 do
        local a, b = t, t + n
        local ab, bb = laneBusy(a), laneBusy(b)
        -- neither busy: keep the last one, so a stopped clip stays where the
        -- user left it instead of snapping back to the A half
        if bb and not ab then live[t] = b
        elseif ab and not bb then live[t] = a end
    end
end

-- The lane of track t that is sounding (or was, when it is stopped).
function Loop.LiveLane(t) return live[t] or t end

-- The silent half: where a clip is staged before it swaps in.
function Loop.TwinLane(t)
    local n = Loop.TRACKS
    return (live[t] or t) == t and (t + n) or t
end

-- Any lane number -> the track it belongs to. Old clip descriptors stored a
-- raw lane, so this is also the migration path: lane 5 has always meant
-- track 1.
function Loop.TrackOfLane(lane) return (lane or 0) % Loop.TRACKS end

-- ---------------------------------------------------------------------------
-- Lane occupancy tag
-- ---------------------------------------------------------------------------
-- A small non-zero number saying WHICH clip a lane currently holds, written
-- by whoever loads the lane. It lets a second window find that clip again
-- after the halves swapped, without either window trusting its own memory.
-- Lives in the spare LANE_CTRL slots: gmem, so every script reads the same
-- value with no string traffic and no project dirtying, and the JSFX @init
-- leaves those slots alone so a plugin reset does not forget.
function Loop.SetLaneTag(lane, tag)
    if attached then gwrite(G_LANE_CTRL + lane * 8 + 2, tag or 0) end
end
function Loop.GetLaneTag(lane)
    if not attached then return 0 end
    return math.floor((gread(G_LANE_CTRL + lane * 8 + 2) or 0) + 0.5)
end

-- Which half of track t holds `tag`, or NIL when the engine no longer holds
-- that clip at all — the twin got reused for another cell, or a plugin reset
-- wiped the tags. Nil is the honest answer and the safe one: a window that
-- believed otherwise would draw a playhead for someone else's clip and, far
-- worse, write its edits over the clip that IS playing.
-- An untagged clip (a plain Looper loop) belongs to its track, so it resolves
-- to whichever half is live.
function Loop.LaneOfTag(t, tag)
    if not tag or tag == 0 then return Loop.LiveLane(t) end
    local n = Loop.TRACKS
    if Loop.GetLaneTag(t) == tag then return t end
    if Loop.GetLaneTag(t + n) == tag then return t + n end
    return nil
end

-- ---------------------------------------------------------------------------
-- Per-frame pump — the ONE call every host makes before reading anything
-- ---------------------------------------------------------------------------
-- Re-selects our gmem block (Engine/Tempo steals it) and re-derives the live
-- half of each pair. Hosts used to do these separately, or not at all, which
-- is precisely how they drifted apart.
-- Lane destinations live on the router (P_EXT GUIDs) and are resolved to
-- track pointers by a scan, so they are cached rather than re-read per frame.
-- But the cache MUST follow the project: another window routing a column
-- writes that GUID, and reconnect() — the only other place that refreshes —
-- early-returns as soon as the router is found, so a script that resolved
-- once would answer with the old destination for the rest of its life. That
-- is invisible until something reads the destination for real (the editor
-- naming its rows after the routed instrument), and then it is baffling.
-- Throttled: routing changes are rare, half a second of lag is not visible,
-- and the scan must not land on every frame of a note drag.
local dest_chg, dest_t = -1, 0
local function pollDests(c)
    if c == dest_chg then return end
    local now = r.time_precise()
    if now - dest_t < 0.5 then return end
    dest_chg, dest_t = c, now
    Loop.RefreshDests()
end

-- Exactly one thing may monitor live input. This router is armed on every input
-- so a keyboard can be captured into a loop; the sampler's kit bus is armed so
-- its pads sound. Both hear the same virtual-keyboard queue — so with a column
-- routed to the kit, one key press reached it TWICE (direct, and again through
-- this router's lane send). Two identical notes at the same sample offset sum
-- coherently: the kit came out at exactly +6 dB, which is what made it visible.
--
-- The rule: while the router really monitors an armed lane, it is the one
-- input, and the kit bus narrows to the suite's own preview channel. Drop the
-- arm or close the engine and the bus widens back, so a sampler used on its own
-- still plays from a keyboard. Values mirror Kit.INPUT_ALL / Kit.INPUT_UI_ONLY —
-- kept literal here because this module deliberately does not depend on Kit.
local KIT_INPUT_ALL = 4096 + (63 << 5)         -- MIDI, any channel, any input
local KIT_INPUT_UI  = 4096 + 16 + (62 << 5)    -- MIDI, channel 16, virtual keyboard
local kit_want, kit_chg = nil, -1
local function pollKitInput(c)
    local want = (Loop.GetListen() and Loop.GetArmedLane())
                 and KIT_INPUT_UI or KIT_INPUT_ALL
    -- arming writes gmem, not the project, so the change count alone would miss it
    if want == kit_want and c == kit_chg then return end
    kit_want, kit_chg = want, c
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        if isInputBus(tr) and r.GetMediaTrackInfo_Value(tr, "I_RECINPUT") ~= want then
            r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", want)
        end
    end
end

function Loop.Poll()
    if not attached then return end
    r.gmem_attach(GMEM_NAME)
    resolveLive()
    local c = r.GetProjectStateChangeCount(0)
    pollDests(c)
    pollKitInput(c)
end

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

-- The clock the ENGINE is actually on: the host's beat when following it, its
-- own free-running beat otherwise. PendingTarget is expressed on THIS
-- timeline, so a countdown built on Loop.Beat() would be wrong precisely when
-- the transport is stopped — which is when a countdown is worth the most.
function Loop.EngineBeat()
    if not attached then return 0 end
    if Loop.GetFreeRun() then return gread(G_FREEBEAT) or 0 end
    return gread(G_TRANSPORT + 2) or 0
end
function Loop.TsNum()   local v = attached and gread(G_TRANSPORT + 4) or 4; return v > 0 and v or 4 end
-- non-zero once the JSFX has run its @init at least once (engine alive)
function Loop.EngineAlive() return attached and gread(G_VERSION) >= 1 end

-- How many lanes the RUNNING JSFX serves. A project loaded before the
-- engine grew still has the old binary in its chain until it is reloaded,
-- and writing to a lane it doesn't scan would be silent nonsense — callers
-- that need more than four lanes must ask first. 0 = unknown (pre-8 build).
function Loop.EngineLanes()
    if not attached then return 0 end
    local n = gread(G_ENG_LANES) or 0
    if n >= 1 then return math.floor(n + 0.5) end
    return Loop.EngineAlive() and 4 or 0
end

-- How many times the engine has been reset (REAPER re-runs @init on transport
-- start, samplerate change, FX reload…). The loops survive it now, but the UI
-- watches this to re-read its caches — and it is the field proof that a reset
-- happened at all, which is how the old loop-loss bug was pinned down.
function Loop.InitCount() return attached and (gread(G_INIT_COUNT) or 0) or 0 end

-- Behaviour revision of the RUNNING engine (0 = older than the field existed).
function Loop.EngineBuild()
    if not attached then return 0 end
    return math.floor((gread(G_BUILD) or 0) + 0.5)
end

-- Is the loaded engine the one this build expects, in lanes AND behaviour?
function Loop.EngineCurrent()
    return Loop.EngineLanes() >= Loop.MAX_LANES
       and Loop.EngineBuild() >= Loop.ENGINE_BUILD
end

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

-- Restore a lane's playing state on recall (0 empty · 2 stopped · 3 playing).
function Loop.SetMode(lane, m)
    if attached then gwrite(G_LANE_STATE + lane * 8 + 0, m) end
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
-- Clip adapters (refonte chantier 6 — the Engine/Clip descriptor): a lane
-- IS a MIDI clip. These translate both ways without owning any
-- serialization — a Clip is a plain table; Engine/Clip.serialize turns it
-- into a string only when it has to travel. Note times are beats/QN on
-- both sides, no conversion. The P_EXT v2 recall blob is untouched: it
-- predates the descriptor, it is tested, and it stays the storage format.
-- ---------------------------------------------------------------------------
function Loop.LaneToClip(lane)
    if not attached then return nil end
    local n = Loop.NoteCount(lane)
    if n <= 0 then return nil end
    local s, l, p, v = {}, {}, {}, {}
    Loop.ReadNotes(lane, s, l, p, v)
    return {
        kind  = "midi",
        name  = "Lane " .. (lane + 1),
        notes = { s = s, l = l, p = p, v = v },
        bars  = Loop.GetLengthBars(lane),
        q     = "bar",
        lmode = "loop",
    }
end

-- Load a MIDI clip into a lane: replaces its content, leaves it STOPPED
-- and ready to launch (never yanks a playing set). False when the clip
-- overflows the engine's note cap.
-- Live-apply an edited clip into a lane: notes + length only — the mode is
-- NOT touched, so a playing lane keeps playing (the JSFX reconciles the
-- sounding notes against the new list every block). This is the
-- editor:apply consumer's path; ClipToLane below stays the cold "load a
-- clip here" that also settles the stopped/empty mode.
function Loop.ApplyClip(lane, clip)
    if not attached or not clip or clip.kind ~= "midi" then return false end
    local nt = clip.notes
    local n = (nt and nt.s and #nt.s) or 0
    if n > Loop.MAX_NOTES then return false end
    for i = 1, n do
        Loop.PutNote(lane, i - 1, nt.s[i], nt.l[i], nt.p[i], nt.v[i])
    end
    Loop.SetNoteCount(lane, n)
    if clip.bars and clip.bars > 0
       and clip.bars ~= Loop.GetLengthBars(lane) then
        Loop.SetLengthBars(lane, clip.bars)
    end
    Loop.BumpVer(lane)
    return true
end

function Loop.ClipToLane(lane, clip)
    if not attached or not clip or clip.kind ~= "midi" then return false end
    local nt = clip.notes
    local n = (nt and nt.s and #nt.s) or 0
    if n > Loop.MAX_NOTES then return false end
    for i = 1, n do
        Loop.PutNote(lane, i - 1, nt.s[i], nt.l[i], nt.p[i], nt.v[i])
    end
    Loop.SetNoteCount(lane, n)
    if clip.bars and clip.bars > 0 then Loop.SetLengthBars(lane, clip.bars) end
    Loop.SetMode(lane, n > 0 and 2 or 0)
    Loop.BumpVer(lane)
    return true
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
--   "3;<global>;<lane>;<lane>;<lane>;<lane>"        3 = format version
--   global = "freerun|armedlane|launchq"            launchq in beats, 0 = off
--   lane   = "bars|muted|mode|n|s,l,p,v|s,l,p,v|…"  starts/lengths in beats
--
-- v2 (no launchq) and v1 (no global block, no per-lane mode) are still read:
-- loops saved before the format grew come back stopped, which is the safe
-- interpretation, and the quantize simply stays where it was.
-- ---------------------------------------------------------------------------
local DATA_KEY = "P_EXT:" .. EXT_TAG .. "_DATA"

local function num(v)          -- compact, still exact enough for beats
    return string.format("%.6g", v or 0)
end

-- A launch quantize stored before v4 cannot have been an informed "off": a
-- queued take had no visible waiting state to choose against, and off also
-- makes the A/B twin buffer — which exists only so a swap lands on the
-- boundary — do nothing at all. So an older zero becomes one bar; from v4 on,
-- a zero is a decision and is restored as written.
local function migrateQ(ver, q)
    if ver ~= "4" and (q or 0) <= 0 then return Loop.TsNum() end
    return q or 0
end

function Loop.Serialize()
    if not attached then return "" end
    local out = { "4",
                  (Loop.GetFreeRun() and "1" or "0") .. "|" .. (Loop.GetArmedLane() or -1)
                  .. "|" .. num(Loop.GetLaunchQ()) }
    for lane = 0, Loop.MAX_LANES - 1 do
        local n = Loop.NoteCount(lane)
        local m = math.floor(Loop.Mode(lane) + 0.5)
        -- an in-flight recording (1), arm (4) or overdub (5) is not a state
        -- to restore: store what the lane actually holds
        if m == 1 or m == 4 or m == 5 then m = (n > 0) and 3 or 0 end
        local parts = { num(Loop.GetLengthBars(lane)),
                        Loop.GetMute(lane) and "1" or "0",
                        tostring(m),
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
    local ver = fields[1]
    if ver ~= "1" and ver ~= "2" and ver ~= "3" and ver ~= "4" then return false end
    local v2 = (ver ~= "1")

    -- lane blocks start after the version, and after the global block in v2+
    local base = v2 and 2 or 1
    if v2 and fields[2] then
        local fr, arm, lq = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)$")
        if not fr then fr, arm = fields[2]:match("^([^|]*)|([^|]*)$") end
        if fr then
            Loop.SetFreeRun(fr == "1")
            -- Before v4 the arm was not a choice: the engine clamped it to a
            -- lane, so EVERY older save carries 0 whether or not anyone armed
            -- anything. Restoring it would re-arm lane 0 in every existing
            -- project — exactly the leak this replaced — so it is dropped.
            local a = (ver == "4") and math.floor(tonumber(arm) or -1) or -1
            Loop.SetArmedLane(a >= 0 and a or nil)
            if lq then Loop.SetLaunchQ(migrateQ(ver, tonumber(lq))) end
        end
    end

    local loaded = 0
    for lane = 0, Loop.MAX_LANES - 1 do
        local blk = fields[base + lane + 1]
        if blk then
            local t = {}
            for f in blk:gmatch("[^|]+") do t[#t + 1] = f end
            local bars  = tonumber(t[1]) or 1
            local muted = t[2] == "1"
            local mode  = v2 and math.floor(tonumber(t[3]) or 0) or nil
            local hdr   = v2 and 4 or 3          -- fields before the notes
            local n     = math.floor(tonumber(t[hdr]) or 0)
            if n > Loop.MAX_NOTES then n = Loop.MAX_NOTES end
            local written = 0
            for i = 1, n do
                local rec = t[hdr + i]
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
            -- mode last: it is what makes the lane sound, so nothing may be
            -- playing off a half-written note list. v1 data has no mode, and an
            -- empty lane can only be empty.
            if written == 0 then
                Loop.SetMode(lane, 0)
            elseif mode == 3 then
                Loop.SetMode(lane, 3)          -- it was playing: launch it back
            else
                Loop.SetMode(lane, 2)          -- has content, stopped
            end
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

-- ---------------------------------------------------------------------------
-- AUTOSAVE
--
-- Persistence is a property of the STATE, not of one window. It used to live
-- privately inside CP_Looper — so a set built entirely in CP_Session was lost
-- when REAPER closed, because nobody called SaveState. That kind of defect is
-- invisible while you work and obvious the next morning, which is the worst
-- possible way to find out.
--
-- It lives here now: any window that touches lanes calls AutoSave() once per
-- frame and the question stops being asked.
--
-- The state itself still goes where it always went — a track extension string,
-- so it travels inside the .RPP with the router track. Nothing is written to
-- the project file by us: REAPER owns that format, and a project must open on a
-- machine that has none of this.
-- ---------------------------------------------------------------------------
local save_vers = {}
local save_due  = 0
local save_hold = false
local adopted   = false
local adopted_router = nil
local last_router    = nil

-- Returns true ONCE when the router track changes under us — never on the first
-- observation, which is just this window learning where it is.
--
-- gmem belongs to the REAPER session, not to the project, so switching projects
-- inside one session leaves the PREVIOUS project's loops loaded. That was
-- already why recall had to be forced; now that lane state is also WRITTEN
-- back, it is why a window must never assume what it finds is its own.
function Loop.RouterChanged()
    local guid = valid(Loop.track) and r.GetTrackGUID(Loop.track) or nil
    if guid == last_router then return false end
    local first = (last_router == nil)
    last_router = guid
    return not first
end

function Loop.IsAdopted() return adopted end

-- A window mid-edit asks for a reprieve: saving in the middle of a note drag
-- would write a state nobody asked for.
function Loop.HoldAutoSave(on) save_hold = on and true or false end

-- A change no event version reports (session setting, lane tag, clock mode).
function Loop.MarkDirty() if adopted then save_due = -1 end end

-- ADOPT the current state without saving it. Call this right after a recall:
-- otherwise the restore declares itself a modification, and the first save
-- writes over exactly what was just read back.
function Loop.AdoptState()
    for lane = 0, Loop.MAX_LANES - 1 do
        save_vers[lane] = Loop.EvtVersion(lane) * 8 + math.floor(Loop.Mode(lane) + 0.5)
    end
    save_due = 0
    adopted = true
    adopted_router = valid(Loop.track) and r.GetTrackGUID(Loop.track) or nil
end

function Loop.AutoSave()
    -- Until someone has adopted, we cannot know whether what sits in gmem is
    -- worth more than what sits in the project. So we do not guess: we wait.
    if not adopted or not attached or not valid(Loop.track) then return end

    -- The router moved since we adopted: what is in gmem belongs to a project
    -- that is no longer open. Writing here would put one project's set into
    -- another project's file. We DISARM rather than guess — the window will
    -- adopt again after its recall. Making the mistake impossible beats
    -- detecting it.
    if r.GetTrackGUID(Loop.track) ~= adopted_router then
        adopted = false
        return
    end

    local now = r.time_precise()
    if save_due < 0 then save_due = now + 0.4 end
    for lane = 0, Loop.MAX_LANES - 1 do
        -- Mode counts as much as notes do: launching or stopping a clip changes
        -- the state to restore while bumping no event version at all.
        local v = Loop.EvtVersion(lane) * 8 + math.floor(Loop.Mode(lane) + 0.5)
        if v ~= save_vers[lane] then
            save_vers[lane] = v
            -- Short: you may hit Ctrl+S right after an edit, and anything still
            -- pending would simply not be in the project file.
            save_due = now + 0.4
        end
    end
    if save_due > 0 and now >= save_due and not save_hold then
        save_due = 0
        Loop.SaveState()
    end
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

-- Clock mode and armed lane are SESSION settings, not lane content, so they are
-- restored unconditionally — unlike the notes, which decline to overwrite lanes
-- that already hold something. Reopening the window mid-session used to leave
-- the clock forced back to Free for exactly that reason: the startup default ran
-- first and the note recall, which carried the saved clock, then declined.
function Loop.LoadGlobals()
    if not attached then return false end
    local str = Loop.SavedState()
    if str == "" then return false end
    local fields = {}
    for f in str:gmatch("[^;]+") do fields[#fields + 1] = f end
    if fields[1] == "1" or not fields[2] then return false end   -- v1 had none
    local fr, arm, lq = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)$")
    if not fr then fr, arm = fields[2]:match("^([^|]*)|([^|]*)$") end
    if not fr then return false end
    Loop.SetFreeRun(fr == "1")
    -- see Deserialize: an arm stored before v4 was the engine's clamp, not a
    -- decision, and re-arming lane 0 from it would reopen the preview leak
    local a = (fields[1] == "4") and math.floor(tonumber(arm) or -1) or -1
    Loop.SetArmedLane(a >= 0 and a or nil)
    if lq then Loop.SetLaunchQ(migrateQ(fields[1], tonumber(lq))) end
    return true
end

return Loop
