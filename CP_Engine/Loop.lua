-- CP_Engine / Loop.lua — engine bridge (no UI)
--
-- THE ROUTER TRACK IS GONE (roadmap phase 6).
--
-- This module used to own a dedicated, armed, input-monitored REAPER track
-- carrying CP_MidiLooper.jsfx, plus one channel-filtered MIDI send per lane,
-- and it talked to that JSFX through a shared gmem block whose map both sides
-- kept by hand. All of it is replaced by CP_Native: the lanes live in the
-- extension, each writes into its OWN port — a permanent preview poured into
-- its destination track, pre-FX — and this file is the wire.
--
-- What that removes, and it is not only tidiness:
--
--   * a track appearing in someone's project because they opened a window;
--   * the FOUR-COLUMN CEILING, which never came from MAX_LANES: it came from
--     the budget of sixteen MIDI channels on one router track. Ports are not
--     channels, and the engine now serves 32 lanes;
--   * gmem as a protocol — two copies of one memory map, and a constant wrong
--     on one side looked exactly like a Lua bug;
--   * the whole arm/disarm dance. The router had to be the ONE armed thing so
--     live input would not double-trigger; with it gone, monitoring is
--     REAPER's own, on the destination track, at zero added latency.
--
-- THE SURFACE DID NOT CHANGE. Every window calls the same functions it always
-- called. That is deliberate: a backend swap that also moves the furniture is
-- two changes debugged as one.
--
-- WHERE STATE LIVES NOW. The router track carried the recall blob and the lane
-- destinations in its P_EXT. With no track to carry them they move to
-- ProjExtState — still inside the .RPP, still travelling with the project,
-- still readable by a REAPER that has none of this installed.

local Loop = {}
local r = reaper

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
-- A musical TRACK is a PAIR of lanes: the half you hear and a silent twin, so
-- a clip change lands exactly on the quantize boundary.
--
-- Eight lanes = four columns. THE ENGINE NO LONGER CONSTRAINS THIS — it serves
-- 32 — so this number is now a decision about the grid's shape and nothing
-- else. Raising it is one line here; what it costs is screen width, which is
-- the author's call and not the engine's.
Loop.MAX_LANES   = 8
Loop.MAX_NOTES   = 1024
Loop.NOTE_STRIDE = 4       -- start, length, pitch, vel (kept: callers use it)
Loop.TRACKS      = Loop.MAX_LANES // 2

-- Which port a column's MIDI goes out on. Sound cells hold ports 0..TRACKS-1
-- (Engine/Cells) and the shared audition holds 31, so the MIDI ports sit above
-- the audio ones with room to grow. BOTH halves of a pair use the same port:
-- a pair is one musical track, and a clip swap must not move the sound to
-- another instrument halfway through.
Loop.PORT_BASE = 8

-- 1.7 and not 1.6: this file now reads CP_ClockPos, and an engine that predates
-- it does not merely lack a function — it anchors the transport on the
-- what-you-hear position, which puts every note out late by the device's output
-- latency. Running against it would sound broken while claiming to work, so the
-- honest answer is to decline the engine.
local ABI_MIN = 1.7
local NATIVE  = false

local EXT_SEC    = "CP_Loop"
local DATA_KEY   = "data"
-- The mark the router track wore. It exists here for ONE reason: finding that
-- track in an old project so it can be read and then removed.
local LEGACY_TAG = "CP_LOOPER"

local Tracks  -- optional Engine/Tracks

-- ---------------------------------------------------------------------------
-- Lua-side note store
--
-- gmem used to BE the store: the JSFX played it and the editor wrote it. The
-- engine now holds a published copy it only ever reads, so the editable truth
-- has to live somewhere — here. Writing goes through publish(), which hands
-- the whole list over in one atomic swap; that is the contract the double
-- buffer needs, and it is what an editor does anyway.
-- ---------------------------------------------------------------------------
local notes = {}          -- [lane] = { s={}, l={}, p={}, v={}, n=0 }
local evtver = {}         -- [lane] = bumped on every change
local seen_recgen = {}    -- [lane] = the take generation we last acted on

local function store(lane)
    local t = notes[lane]
    if not t then
        t = { s = {}, l = {}, p = {}, v = {}, n = 0 }
        notes[lane] = t
    end
    return t
end

local function publish(lane)
    if not NATIVE then return end
    local t = store(lane)
    for i = 1, t.n do
        r.CP_LaneSetNote(lane, i - 1, t.s[i], t.l[i], t.p[i], t.v[i])
    end
    r.CP_LanePublish(lane, t.n)
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function Loop.init(reaper_api, tracks_module)
    r = reaper_api
    Tracks = tracks_module
    -- A CAPABILITY, and a minimum rather than an equality: ReaPack has no
    -- dependency mechanism (measured: 89 indexes, 5993 packages, zero
    -- dependency element), so a script can perfectly well be installed
    -- without the binary, or with one that does not speak this language.
    NATIVE = (r.CP_EngineABI ~= nil) and (r.CP_EngineABI() >= ABI_MIN)
             and (r.CP_LaneCount ~= nil)
    Loop.track = nil
    for lane = 0, Loop.MAX_LANES - 1 do
        notes[lane] = nil
        evtver[lane] = 0
        seen_recgen[lane] = nil
    end
    Loop.reconnect()
end

-- ---------------------------------------------------------------------------
-- Destinations
--
-- A lane's destination is a project track, remembered by GUID in ProjExtState.
-- It used to be remembered on the router; there is no router, and a GUID in
-- the project is a better place for it anyway — it survives the track being
-- moved, renamed, or the window never being opened.
-- ---------------------------------------------------------------------------
Loop.dest = {}    -- [lane] = resolved MediaTrack or nil (UI cache)

local function valid(tr) return tr and r.ValidatePtr2(0, tr, "MediaTrack*") end

local function destKey(lane) return "dest" .. lane end

local function getDestGUID(lane)
    local _, g = r.GetProjExtState(0, EXT_SEC, destKey(lane))
    return g or ""
end

local function setDestGUID(lane, guid)
    r.SetProjExtState(0, EXT_SEC, destKey(lane), guid or "")
end

-- resolveGUID vivait ici et parcourait tout le projet pour UN identifiant.
-- Appele une fois par lane, il faisait seize balayages complets a chaque
-- rafraichissement. Loop.RefreshDests construit desormais la carte une fois et
-- lit dedans — meme resultat, un balayage.

-- What each column's port is CURRENTLY bound to. Not a cache for speed: a
-- rebind detaches the preview, which cuts whatever it was carrying. Rebinding
-- on every poll would have cut the MIDI twice a second, and the symptom
-- (stuttering notes, no error anywhere) is the kind you chase for an evening.
local bound = {}

local function bindPort(t, track, force)
    if not NATIVE then return false end
    if not force and bound[t] == (track or false) then return track ~= nil end
    local port = Loop.PORT_BASE + t
    -- Always DETACH first. The engine outlives the script, so a port left
    -- attached by a previous run would make the idempotent attach answer
    -- "already done" without rebinding — the same trap the audio cells fell
    -- into, and it costs an evening every time.
    r.CP_PortDetach(port)
    bound[t] = track or false
    if not valid(track) then
        r.CP_LaneBind(t, -1, 0)
        r.CP_LaneBind(t + Loop.TRACKS, -1, 0)
        return false
    end
    if not r.CP_PortAttach(track, port) then bound[t] = false return false end
    -- Channel 1 for every lane. Channels were how the router told lanes apart
    -- on ONE wire; each lane has its own wire now, so the channel goes back to
    -- meaning what a channel means — and an omni instrument hears it.
    r.CP_LaneBind(t, port, 0)
    r.CP_LaneBind(t + Loop.TRACKS, port, 0)
    return true
end

-- ---------------------------------------------------------------------------
-- A COLUMN IS A TRACK — and until now nothing said so.
--
-- A column used to exist whether or not anything was behind it: four of them,
-- always drawn, bound to nothing until someone opened a menu and routed them
-- by hand. Drop a sample into one and no sound came out, with no visible
-- reason. That is not a missing feature, it is a missing RELATION: the window
-- showed slots where the user reads tracks.
--
-- So the relation is stated. A column ADOPTS a project track, and remembers it
-- by GUID — the same `dest<lane>` key that already existed, because the storage
-- was never the problem. What is new is that an empty slot goes looking.
--
-- ADOPTION IS BY SLOT, DISPLAY IS BY TRACK ORDER. Two different things, and
-- keeping them apart is what makes this safe: a slot is a lane, it owns clips
-- and a port binding, so it must NOT move when the user reorders their tracks.
-- Only the drawing order follows the project. Reorder and nothing is cut;
-- delete a track and its slot is freed, the others keep their clips.
--
-- ELIGIBLE = a TOP-LEVEL track carrying no CP mark. A folder parent qualifies:
-- it has a fader, a chain and a meter, which is everything a destination needs.
-- A folder CHILD does not — it is that destination's internals, and audioDest
-- creates children itself, so accepting them would grow a column every time a
-- column played a sound. The suite's own infrastructure is excluded by its
-- mark, which Engine/Tracks declares the sole discovery authority.
-- ---------------------------------------------------------------------------
local order = {}          -- [i] = slot, sorted by project track order
local norder = 0

-- The suite's own tracks, for the ones that predate the shared mark. Engine
-- /Tracks is the discovery authority for everything born since, but a kit
-- built before it existed — or by a caller that had no Tracks module — is a
-- top-level, unmarked folder head, and it would walk straight into the grid as
-- a column. Three string reads per track, behind the same half-second debounce
-- as the rest of this.
local LEGACY_OWN = { "P_EXT:CP_KIT", "P_EXT:CP_KIT_INSTR", "P_EXT:" .. LEGACY_TAG }

local function eligible(tr)
    if r.GetParentTrack(tr) ~= nil then return false end
    if Tracks and Tracks.MarkOf and Tracks.MarkOf(tr) then return false end
    for i = 1, #LEGACY_OWN do
        local ok, v = r.GetSetMediaTrackInfo_String(tr, LEGACY_OWN[i], "", false)
        if ok and v ~= "" then return false end
    end
    return true
end

-- Rebuilt in place, every refresh. No table is created here: this runs behind a
-- half-second debounce, but it runs for the life of the window.
local claimed = {}
local function syncColumns()
    local n = Loop.TRACKS
    for k in pairs(claimed) do claimed[k] = nil end
    for t = 0, n - 1 do
        local tr = Loop.dest[t]
        if tr then claimed[tr] = t end
    end

    -- Fill free slots, lowest first, with unclaimed eligible tracks in project
    -- order. A track already held by a slot keeps it — that is the whole point.
    local slot = 0
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        if not claimed[tr] and eligible(tr) then
            while slot < n and Loop.dest[slot] do slot = slot + 1 end
            if slot >= n then break end
            local guid = r.GetTrackGUID(tr)
            setDestGUID(slot, guid)
            setDestGUID(slot + n, guid)
            Loop.dest[slot] = tr
            Loop.dest[slot + n] = tr
            claimed[tr] = slot
        end
    end

    -- The drawing order: occupied slots, sorted the way the project reads.
    -- Built from the SLOTS and not from the tracks, so that two columns
    -- deliberately pointed at the same instrument both keep a place — walking
    -- the tracks would have silently dropped one of them.
    norder = 0
    for t = 0, n - 1 do
        if Loop.dest[t] then norder = norder + 1 order[norder] = t end
    end
    -- Insertion sort: at most a handful of columns, behind a half-second
    -- debounce. Anything cleverer would cost more to read than it saves.
    for a = 2, norder do
        local v  = order[a]
        local kv = r.GetMediaTrackInfo_Value(Loop.dest[v], "IP_TRACKNUMBER")
        local b  = a - 1
        while b >= 1
              and r.GetMediaTrackInfo_Value(Loop.dest[order[b]], "IP_TRACKNUMBER") > kv do
            order[b + 1] = order[b]
            b = b - 1
        end
        order[b + 1] = v
    end
end

-- How many columns to draw, and which slot each one is. A window iterates
-- 1..ColumnCount() and asks ColumnAt(i) for the slot — the slot is what every
-- other call still takes, so nothing downstream learns a second vocabulary.
function Loop.ColumnCount() return norder end
function Loop.ColumnAt(i) return order[i] end

-- ONE PASS OVER THE PROJECT, NOT ONE PER LANE. resolveGUID walks every track
-- looking for one GUID; calling it for each of sixteen lanes made this
-- sixteen full sweeps, and it runs twice a second on a project the user is
-- editing. Building the map once turns 16xN into N.
local byguid = {}

function Loop.RefreshDests()
    for k in pairs(byguid) do byguid[k] = nil end
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        byguid[r.GetTrackGUID(tr)] = tr
    end
    for lane = 0, Loop.MAX_LANES - 1 do
        local g = getDestGUID(lane)
        Loop.dest[lane] = (g ~= "") and byguid[g] or nil
    end
    syncColumns()
    for t = 0, Loop.TRACKS - 1 do bindPort(t, Loop.dest[t]) end
end

-- Kept for callers: there are no sends left to synchronise, only ports to
-- point at the right track. Healing the pair is still worth doing — projects
-- routed before the pairing existed have a twin pointing nowhere, which is why
-- they fell silent on every other launch.
function Loop.SyncSends()
    local n = Loop.TRACKS
    for t = 0, n - 1 do
        local g = getDestGUID(t)
        if getDestGUID(t + n) ~= g then setDestGUID(t + n, g) end
    end
    Loop.RefreshDests()
end

function Loop.reconnect()
    Loop.RefreshDests()
    return nil
end

function Loop.Reattach() end   -- there is no gmem block to re-select any more

function Loop.GetLaneDest(lane)
    local tr = Loop.dest[lane]
    if tr and not valid(tr) then Loop.dest[lane] = nil return nil end
    return tr
end

function Loop.TrackName()
    return nil     -- there is no router track to name
end

-- Route a TRACK to a destination instrument (nil = unroute). BOTH halves of
-- the pair go to the same instrument in one gesture: routing only the sounding
-- half looks fine until a clip swaps, and then the track goes silent for no
-- visible reason.
function Loop.SetLaneDest(lane, track)
    local t = Loop.TrackOfLane(lane)
    local guid = valid(track) and r.GetTrackGUID(track) or ""
    r.Undo_BeginBlock2(0)
    setDestGUID(t, guid)
    setDestGUID(t + Loop.TRACKS, guid)
    Loop.dest[t] = valid(track) and track or nil
    Loop.dest[t + Loop.TRACKS] = Loop.dest[t]
    bindPort(t, Loop.dest[t], true)
    r.Undo_EndBlock2(0, "CP Looper: route track " .. (t + 1), -1)
end

-- Create a fresh instrument track for a lane and route it there. Selects it so
-- the user can drop their synth on it.
function Loop.NewDestTrack(lane)
    r.Undo_BeginBlock2(0)
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, true)
    local tr = r.GetTrack(0, idx)
    local t = Loop.TrackOfLane(lane)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "Track " .. (t + 1) .. " inst", true)
    local guid = r.GetTrackGUID(tr)
    setDestGUID(t, guid)
    setDestGUID(t + Loop.TRACKS, guid)
    Loop.dest[t] = tr
    Loop.dest[t + Loop.TRACKS] = tr
    bindPort(t, tr, true)
    r.SetOnlyTrackSelected(tr)
    r.Undo_EndBlock2(0, "CP Looper: new instrument track", -1)
    return tr
end

-- ---------------------------------------------------------------------------
-- Kit view: the pads of the CP kit a lane is routed to, shaped like the Kit
-- module's surface so Rows.Build / Rows.Label can consume either.
-- ---------------------------------------------------------------------------
local kitview = { BASE = 0, MAX = 128, pads = {}, version = 0, n = 0 }
local kv_change, kv_lane = -1, -1

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

-- ---------------------------------------------------------------------------
-- Engine lifecycle
--
-- There is nothing to install, nothing to copy into an Effects folder, no
-- plugin instance that can be out of date with the script that drives it, and
-- no track to create. `Ensure` therefore asks one question — is the binary
-- here and does it speak our language — and it is honest when the answer is no.
-- ---------------------------------------------------------------------------
function Loop.IsAttached() return NATIVE end
function Loop.EngineAlive() return NATIVE end
function Loop.EngineLanes() return NATIVE and r.CP_LaneCount() or 0 end
function Loop.EngineBuild() return NATIVE and r.CP_EngineABI() or 0 end
Loop.ENGINE_BUILD = ABI_MIN
function Loop.EngineCurrent() return NATIVE end
function Loop.InitCount() return 0 end
function Loop.ReloadEngine() return NATIVE end

-- ---------------------------------------------------------------------------
-- MIGRATION — a project from the router era must LOSE that track, not keep it
--
-- This is not tidiness. An old project still carries CP_MidiLooper.jsfx on an
-- armed router track, and that JSFX still plays its lanes out of gmem. Leave
-- it there and the same set plays twice, from two engines, a few milliseconds
-- apart — which sounds like a broken instrument rather than like a leftover.
--
-- So the router is read, then removed: its recall blob and its lane
-- destinations move to ProjExtState, and the track goes. The CP folder goes
-- with it when nothing else is left inside.
--
-- Returns true when something was actually migrated, so the caller can say so.
-- ---------------------------------------------------------------------------
function Loop.MigrateLegacy()
    local router, moved = nil, false
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        local _, mark = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. LEGACY_TAG, "", false)
        if mark == "router" then router = tr break end
    end
    if not valid(router) then return false end

    r.Undo_BeginBlock2(0)
    local _, blob = r.GetSetMediaTrackInfo_String(
        router, "P_EXT:" .. LEGACY_TAG .. "_DATA", "", false)
    local _, cur = r.GetProjExtState(0, EXT_SEC, DATA_KEY)
    if blob and blob ~= "" and (not cur or cur == "") then
        r.SetProjExtState(0, EXT_SEC, DATA_KEY, blob)
        moved = true
    end
    for lane = 0, Loop.MAX_LANES - 1 do
        local _, g = r.GetSetMediaTrackInfo_String(
            router, "P_EXT:" .. LEGACY_TAG .. "_DEST" .. lane, "", false)
        if g and g ~= "" and getDestGUID(lane) == "" then
            setDestGUID(lane, g)
            moved = true
        end
    end
    r.DeleteTrack(router)
    if Tracks and Tracks.DropFolderIfEmpty then Tracks.DropFolderIfEmpty() end
    r.Undo_EndBlock2(0, "CP: retire the router track", -1)
    return true, moved
end

function Loop.Setup()
    if not NATIVE then
        return nil, "The CP engine extension is missing (or older than ABI "
                    .. ABI_MIN .. ")."
    end
    Loop.MigrateLegacy()
    -- "Point every unrouted column at the selected track" used to live here. It
    -- is now the opposite of the rule: a free column adopts a project track by
    -- itself, in project order, and pouring four of them into whichever track
    -- happened to be selected would undo that on the first setup.
    Loop.RefreshDests()
    Loop.SetFreeRun(true)
    Loop.AdoptArmedLane(nil)   -- nothing monitors until YOU arm something
    -- One bar, as in Ableton, and for the same reason: the launch quantize is
    -- what makes a clip swap, a scene and a TAKE land on the grid instead of
    -- wherever the mouse happened to be.
    Loop.SetLaunchQ(Loop.TsNum())
    return true
end

function Loop.Ensure(create)
    if not NATIVE then
        return false, "The CP engine extension is missing — MIDI lanes need it."
    end
    if create then
        local ok, err = Loop.Setup()
        if not ok then return false, err end
        return true, "Looper engine ready"
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- Commands
--
-- Everything written before the next audio block is drained TOGETHER: one
-- gesture is one block. Swapping a clip is two commands (stop this half,
-- launch that one) and a scene is one pair per column — trickled out one per
-- frame they could land on either side of a quantize boundary, and half a
-- scene starting a bar before the other half is not a quantize, it is a bug
-- with good manners.
-- ---------------------------------------------------------------------------
local function cmd(c, lane, arg)
    if NATIVE then r.CP_LaneCmd(lane or 0, c, arg or 0) end
end

function Loop.Rec(lane)      cmd(1, lane) end
function Loop.Stop(lane)     cmd(2, lane) end
function Loop.Clear(lane)
    Loop.SetLaneTag(lane, 0)
    local t = store(lane); t.n = 0
    publish(lane)
    evtver[lane] = (evtver[lane] or 0) + 1
    cmd(3, lane)
end
function Loop.Panic()        if NATIVE then r.CP_LanesPanic() end end
function Loop.Play(lane)     cmd(5, lane) end
function Loop.StopClip(lane) cmd(6, lane) end
function Loop.ClearAll()
    for l = 0, Loop.MAX_LANES - 1 do
        Loop.SetLaneTag(l, 0)
        local t = store(l); t.n = 0
        publish(l)
        evtver[l] = (evtver[l] or 0) + 1
    end
    cmd(7, 0)
end
function Loop.Overdub(lane)  cmd(8, lane) end

function Loop.ToggleRec(lane)
    if Loop.Pending(lane) == 3 then Loop.Rec(lane) return end
    local m = Loop.Mode(lane)
    if m == 1 or m == 4 or m == 5 then Loop.Stop(lane) else Loop.Rec(lane) end
end

function Loop.ToggleClip(lane)
    local p = Loop.Pending(lane)
    if p == 1 then Loop.StopClip(lane) return end
    if p == 2 then Loop.Play(lane) return end
    local m = Loop.Mode(lane)
    if m == 3 then Loop.StopClip(lane) elseif m == 2 then Loop.Play(lane) end
end

-- ---------------------------------------------------------------------------
-- Session settings
-- ---------------------------------------------------------------------------
function Loop.SetLaunchQ(beats) if NATIVE then r.CP_SetLaunchQ(beats or 0) end end
function Loop.GetLaunchQ()      return NATIVE and r.CP_GetLaunchQ() or 0 end
function Loop.SetFreeRun(on)    if NATIVE then r.CP_SetFreeRun(on and 1 or 0) end end
function Loop.GetFreeRun()      return NATIVE and r.CP_GetFreeRun() or false end

-- "Something of MINE is sounding" — said by a host that plays audio cells,
-- which the lane engine cannot see. The free clock is the SESSION's transport
-- and it sits at zero while the session is silent, so a sample playing with no
-- lane running would otherwise take its phase reference with it.
local audio_run = false
function Loop.SetAudioRun(on)
    audio_run = on and true or false
    if NATIVE then r.CP_SetAudioRun(audio_run and 1 or 0) end
end
function Loop.GetAudioRun() return audio_run end

-- ---------------------------------------------------------------------------
-- Monitoring
--
-- THE ARM IS REAPER'S NOW. The router had to be the one armed thing so a note
-- would not reach an instrument twice — directly, and again through a lane
-- send. With no router there is no second path, so monitoring goes back to
-- being what REAPER does: arm the destination track, hear it with no added
-- latency and no defer frame in the way.
--
-- Capture does NOT depend on it. MIDI_GetRecentInputEvent reads the global
-- input history, so a take records whether or not anything is armed — which
-- is one fewer state to be in the wrong one of.
-- ---------------------------------------------------------------------------
local armed_lane = nil

local function setMonitor(tr, on)
    if not valid(tr) then return end
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", on and 1 or 0)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", on and 1 or 0)
end

-- UN GESTE, UNE ECRITURE. Cette fonction ecrit I_RECARM sur une piste du
-- projet : elle n'a donc le droit d'exister qu'au bout d'un clic. Tout ce qui
-- RESTITUE un etat (chargement de projet, relecture du blob) passe par
-- AdoptArmedLane et n'ecrit rien — meme discipline que le kit du sampler, et
-- pour la meme raison : un armement qu'on n'a pas demande est indistinguable
-- d'un armement qui se defend tout seul.
function Loop.SetArmedLane(lane)
    if armed_lane then setMonitor(Loop.GetLaneDest(armed_lane), false) end
    armed_lane = lane
    r.SetProjExtState(0, EXT_SEC, "armed", tostring(lane or -1))
    if lane then setMonitor(Loop.GetLaneDest(lane), true) end
end

-- Se SOUVENIR de la lane armee sans toucher a une seule piste. Ce que la
-- session avait note reste vrai si la piste l'est encore ; sinon la memoire est
-- simplement fausse, et une memoire fausse est moins couteuse qu'un projet qui
-- se rearme tout seul a l'ouverture.
function Loop.AdoptArmedLane(lane)
    armed_lane = nil
    if not lane then return end
    local tr = Loop.GetLaneDest(lane)
    if not valid(tr) then return end
    if r.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then armed_lane = lane end
end

function Loop.GetArmedLane()
    if armed_lane and armed_lane >= 0 and armed_lane < Loop.MAX_LANES then
        return armed_lane
    end
    return nil
end

-- Live listening is now a property of the armed track, so these two answer
-- from it. Kept because two windows drive them.
function Loop.SetListen(on)
    if not on then Loop.SetArmedLane(nil) end
end

function Loop.GetListen()
    local tr = armed_lane and Loop.GetLaneDest(armed_lane)
    if not valid(tr) then return false end
    return r.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
end

-- ---------------------------------------------------------------------------
-- Per-lane control
-- ---------------------------------------------------------------------------
function Loop.SetLengthBars(lane, bars)
    if NATIVE then r.CP_LaneSet(lane, "bars", bars or 1) end
end
function Loop.GetLengthBars(lane)
    if not NATIVE then return 1 end
    local b = r.CP_LaneGet(lane, "bars")
    return (b and b > 0) and b or 1
end
-- ATTENTION EN TOUCHANT A CECI. `mute` ne parle qu'au moteur de LANES : il
-- coupe le MIDI et laisse sonner la case AUDIO de la meme colonne, qui est une
-- voix et non une lane. Le defaut « une lane mutee dans le Looper coupe son
-- MIDI mais pas sa case audio » est donc reel — mais il ne se corrige PAS en
-- branchant les voix ici, parce que CP_Session se sert deja de ce meme mute
-- pour un autre sens : une case audio arme une lane d'une seule note et la
-- MUTE pour que cette note ne parte pas dans l'instrument de la colonne
-- (`Loop.SetMute(lane, audio)`). Taire la voix sur mute rendrait donc TOUTE
-- case audio silencieuse. Il faudra distinguer les deux intentions avant de
-- corriger — c'est note au registre, et non fait.
function Loop.SetMute(lane, on)
    if NATIVE then r.CP_LaneSet(lane, "mute", on and 1 or 0) end
end
function Loop.GetMute(lane)
    return NATIVE and r.CP_LaneGet(lane, "mute") >= 0.5
end

-- The sound channel is gone with the router: a sound cell is a CP voice on its
-- own port, and it never travelled a MIDI wire to begin with. These two stay
-- as no-ops so a window that still calls them is not punished for it.
function Loop.SetLaneAudio() end
function Loop.GetLaneAudio() return false end

-- ---------------------------------------------------------------------------
-- Per-lane state (read)
-- ---------------------------------------------------------------------------
-- 0 empty · 1 recording · 2 stopped · 3 playing · 4 armed · 5 overdubbing
function Loop.Mode(lane)       return NATIVE and r.CP_LaneGet(lane, "mode") or 0 end
function Loop.NEv(lane)        return store(lane).n end
function Loop.Phase(lane)      return NATIVE and r.CP_LaneGet(lane, "phase") or 0 end
function Loop.LenBeats(lane)
    local v = NATIVE and r.CP_LaneGet(lane, "lenbeats") or 0
    return v > 0 and v or 4
end
function Loop.EvtVersion(lane) return evtver[lane] or 0 end
function Loop.HasContent(lane) return store(lane).n > 0 end
-- queued launch: 0 none · 1 play · 2 stop · 3 rec · 4 stop-rec · 5 overdub
function Loop.Pending(lane)
    if not NATIVE then return 0 end
    return math.floor(r.CP_LaneGet(lane, "pending") + 0.5)
end
function Loop.PendingTarget(lane)
    return NATIVE and r.CP_LaneGet(lane, "target") or 0
end

-- A queued launch with no date: it is waiting for the CLOCK itself and fires
-- with its first block. The UI says so instead of counting down to a beat that
-- has no date.
function Loop.PendingWaitsClock(lane)
    return NATIVE and r.CP_LaneGet(lane, "target") < -1e8
end

-- ---------------------------------------------------------------------------
-- Tracks = lane pairs
-- ---------------------------------------------------------------------------
local live = {}
for t = 0, Loop.TRACKS - 1 do live[t] = t end

function Loop.IsRunning(lane)
    if not NATIVE then return false end
    local m = math.floor(r.CP_LaneGet(lane, "mode") + 0.5)
    return m == 1 or m == 3 or m == 5
end

-- "busy" = sounding or about to: a queued launch already belongs to the half
-- that will play, otherwise the swap would flicker back for one frame. ARMED
-- and a queued REC count for the same reason — a take waiting on the transport
-- is the half the user is looking at.
local function laneBusy(lane)
    local m = r.CP_LaneGet(lane, "mode")
    if m == 3 or m == 5 or m == 1 or m == 4 then return true end
    local p = r.CP_LaneGet(lane, "pending")
    return p == 1 or p == 3
end

local function resolveLive()
    if not NATIVE then return end
    local n = Loop.TRACKS
    for t = 0, n - 1 do
        local a, b = t, t + n
        local ab, bb = laneBusy(a), laneBusy(b)
        if bb and not ab then live[t] = b
        elseif ab and not bb then live[t] = a end
    end
end

function Loop.LiveLane(t) return live[t] or t end
function Loop.TwinLane(t)
    local n = Loop.TRACKS
    return (live[t] or t) == t and (t + n) or t
end
function Loop.TrackOfLane(lane) return (lane or 0) % Loop.TRACKS end

-- ---------------------------------------------------------------------------
-- Lane occupancy tag — WHICH clip a lane currently holds
-- ---------------------------------------------------------------------------
function Loop.SetLaneTag(lane, tag)
    if NATIVE then r.CP_LaneSet(lane, "tag", tag or 0) end
end
function Loop.GetLaneTag(lane)
    if not NATIVE then return 0 end
    return math.floor(r.CP_LaneGet(lane, "tag") + 0.5)
end

-- Which half of track t holds `tag`, or NIL when the engine no longer holds
-- that clip at all. Nil is the honest answer and the safe one: a window that
-- believed otherwise would draw a playhead for someone else's clip and, far
-- worse, write its edits over the clip that IS playing.
-- QUELLE LANE TIENT CE CLIP. Rend nil quand plus personne ne le tient — et
-- c'est le contrat, ecrit dans le commentaire d'origine, que le code ne tenait
-- pas : un tag 0 (« pas d'identite ») rendait la moitie VIVANTE de la paire.
-- L'edition d'un clip sans identite atterrissait donc dans la lane jumelle,
-- par-dessus les notes d'un autre clip. Zero n'est pas une identite, c'est
-- l'absence d'identite, et la reponse honnete est « je ne sais pas ».
function Loop.LaneOfTag(t, tag)
    if not tag or tag == 0 then return nil end
    local n = Loop.TRACKS
    if Loop.GetLaneTag(t) == tag then return t end
    if Loop.GetLaneTag(t + n) == tag then return t + n end
    return nil
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------
function Loop.Tempo() return r.Master_GetTempo() or 120 end
function Loop.Playing() return (r.GetPlayState() & 1) == 1 end

local function nowPos()
    return Loop.Playing() and r.GetPlayPosition() or r.GetCursorPosition()
end

function Loop.Beat() return r.TimeMap2_timeToQN(0, nowPos()) end

function Loop.TsNum()
    local n = r.TimeMap_GetTimeSigAtTime(0, nowPos())
    return (n and n > 0) and n or 4
end

-- The clock the ENGINE is on: the host's beat when following it, its own
-- free-running beat otherwise. PendingTarget is expressed on THIS timeline, so
-- a countdown built on Loop.Beat() would be wrong precisely when the transport
-- is stopped — which is when a countdown is worth the most.
function Loop.EngineBeat() return NATIVE and r.CP_EngineBeat() or 0 end

-- ---------------------------------------------------------------------------
-- Note storage
-- ---------------------------------------------------------------------------
function Loop.NoteCount(lane)
    local n = store(lane).n
    return (n > Loop.MAX_NOTES) and Loop.MAX_NOTES or n
end

function Loop.SetNoteCount(lane, n)
    local t = store(lane)
    t.n = math.floor((n or 0) + 0.5)
    if t.n < 0 then t.n = 0 end
    if t.n > Loop.MAX_NOTES then t.n = Loop.MAX_NOTES end
    publish(lane)
end

-- Restore a lane's playing state on recall (0 empty · 2 stopped · 3 playing).
function Loop.SetMode(lane, m) cmd(9, lane, m or 0) end

-- "The notes of this lane changed" — and therefore also the moment to hand the
-- list to the engine. Every editing path already calls this exactly once at
-- the end of a gesture, which is precisely the granularity the double buffer
-- wants: publishing per NOTE would have made a delete O(n^2) in ABI calls, and
-- publishing never would have made a note drag inaudible.
function Loop.BumpVer(lane)
    evtver[lane] = (evtver[lane] or 0) + 1
    publish(lane)
end

function Loop.GetNote(lane, i)
    local t = store(lane)
    local k = i + 1
    return t.s[k], t.l[k], t.p[k], t.v[k]
end

-- Write note i (0-based). Does NOT publish: the caller owns the count, and
-- publishing per note would hand the engine a half-written list once per note
-- instead of a whole one once.
function Loop.PutNote(lane, i, start, len, pitch, vel)
    local t = store(lane)
    local k = i + 1
    t.s[k], t.l[k], t.p[k], t.v[k] = start, len, pitch, vel
end

function Loop.ReadNotes(lane, out_start, out_len, out_pitch, out_vel)
    local t = store(lane)
    local n = Loop.NoteCount(lane)
    for i = 1, n do
        out_start[i] = t.s[i]
        out_len[i]   = t.l[i]
        out_pitch[i] = t.p[i]
        out_vel[i]   = t.v[i]
    end
    return n
end

-- ---------------------------------------------------------------------------
-- LIVE CAPTURE
--
-- The router was armed and monitored so the JSFX could see incoming MIDI in
-- its audio block. There is no router; MIDI_GetRecentInputEvent reads REAPER's
-- global input history from the main thread, and — this is the part that makes
-- it better rather than merely equivalent — every event arrives ALREADY
-- STAMPED in samples relative to now. A defer frame polls late; it does not
-- record late.
--
-- Consequences worth stating:
--   * capture no longer depends on anything being armed. One fewer state to
--     be in the wrong one of;
--   * it sees every device, exactly as the router (armed on all inputs) did;
--   * the suite's own preview notes are tagged on UI_CHAN and swallowed here,
--     so a sampler pad clicked during a take does not land in the take.
-- ---------------------------------------------------------------------------
local UI_CHAN = 15          -- mirror of Kit.UI_CHAN
-- Two tables, not one keyed cleverly: a single table holding both the start
-- phase and the velocity has to encode which is which, and closeHeld would
-- then walk the velocities as though they were pitches — inventing notes at
-- negative pitch out of an iteration order.
local held_st  = {}         -- [lane][pitch] = start phase
local held_vel = {}         -- [lane][pitch] = velocity
local last_seq = nil

local function heldOf(lane)
    local a = held_st[lane]
    if not a then a = {} held_st[lane] = a end
    local b = held_vel[lane]
    if not b then b = {} held_vel[lane] = b end
    return a, b
end

-- Append a finished note to the lane, clamped to its loop.
local function addNote(lane, start, len, pitch, vel)
    local t = store(lane)
    if t.n >= Loop.MAX_NOTES then return end
    local Lb = Loop.LenBeats(lane)
    if len < 0 then len = len + Lb end
    if len < 0.02 then len = 0.05 end
    if len > Lb then len = Lb end
    t.n = t.n + 1
    t.s[t.n], t.l[t.n], t.p[t.n], t.v[t.n] = start, len, pitch, vel
end

-- Close every note still held on this lane, at `phase`.
local function closeHeld(lane, phase)
    local a = held_st[lane]
    if not a then return false end
    local b = held_vel[lane] or {}
    local any = false
    for pitch, st in pairs(a) do
        addNote(lane, st, phase - st, pitch, b[pitch] or 100)
        any = true
    end
    held_st[lane], held_vel[lane] = nil, nil
    return any
end

-- Which lanes are capturing right now, and the engine's beat for each.
local function pollCapture()
    if not NATIVE then return end

    -- A take that just STARTED wipes the lane: the engine says so by bumping
    -- its take generation. It never touches the notes itself — that is the
    -- whole ownership rule — so this is where "REC clears the lane" happens.
    local capturing = false
    for lane = 0, Loop.MAX_LANES - 1 do
        local g = math.floor(r.CP_LaneGet(lane, "recgen") + 0.5)
        if seen_recgen[lane] ~= g then
            if seen_recgen[lane] ~= nil then
                local t = store(lane)
                t.n = 0
                held_st[lane], held_vel[lane] = nil, nil
                publish(lane)
                evtver[lane] = (evtver[lane] or 0) + 1
            end
            seen_recgen[lane] = g
        end
        local m = math.floor(r.CP_LaneGet(lane, "mode") + 0.5)
        if m == 1 or m == 5 then
            capturing = true
        elseif held_st[lane] then
            -- The take ended (auto-stop, boundary, transport stop): close what
            -- was still held so the last note is KEPT rather than lost. A take
            -- that stops mid-note used to strand it in the JSFX's local heap
            -- and lose it entirely.
            local Lb = Loop.LenBeats(lane)
            local ph = r.CP_LaneGet(lane, "phase")
            if closeHeld(lane, (ph > 0) and ph or Lb) then
                Loop.BumpVer(lane)
            end
        end
    end

    if not r.MIDI_GetRecentInputEvent then return end

    -- idx = 0 also latches the list, so it must be asked for even when nothing
    -- is capturing — otherwise the first take would receive everything played
    -- since the window opened.
    local seq0, buf0, ts0 = r.MIDI_GetRecentInputEvent(0)
    if not seq0 or seq0 == 0 then return end
    if not capturing then last_seq = seq0 return end

    local tempo = Loop.Tempo()
    if not tempo or tempo <= 0 then tempo = 120 end
    local srate = 48000
    if r.CP_Srate then
        local s = r.CP_Srate()
        if s and s > 1 then srate = s end
    end
    local bps = tempo / (60.0 * srate)      -- beats per sample
    local now_beat = r.CP_EngineBeat()

    -- Walk BACK from the newest to the last one we handled, then replay them
    -- oldest-first so a note-on precedes its note-off.
    local pending, idx = {}, 0
    local seq, buf, ts = seq0, buf0, ts0
    while seq and seq ~= 0 and idx < 128 do
        if last_seq and seq <= last_seq then break end
        pending[#pending + 1] = { seq = seq, buf = buf, ts = ts }
        idx = idx + 1
        seq, buf, ts = r.MIDI_GetRecentInputEvent(idx)
    end
    last_seq = seq0

    local changed = {}
    for k = #pending, 1, -1 do
        local ev = pending[k]
        local b = ev.buf
        if b and #b >= 3 then
            local st = b:byte(1)
            local hi = st & 0xF0
            local ch = st & 0x0F
            if ch ~= UI_CHAN and (hi == 0x90 or hi == 0x80) then
                local pitch = b:byte(2)
                local vel   = b:byte(3)
                local on    = (hi == 0x90 and vel > 0)
                -- `ts` is in samples relative to NOW, and negative for the
                -- past. This is the whole reason the capture is not late.
                local beat = now_beat + (ev.ts or 0) * bps
                for lane = 0, Loop.MAX_LANES - 1 do
                    local m = math.floor(r.CP_LaneGet(lane, "mode") + 0.5)
                    if m == 1 or m == 5 then
                        local Lb = Loop.LenBeats(lane)
                        local ph = beat - math.floor(beat / Lb) * Lb
                        local hs, hv = heldOf(lane)
                        if on then
                            -- a new note-on closes any pending note of the
                            -- same pitch first
                            if hs[pitch] then
                                addNote(lane, hs[pitch], ph - hs[pitch], pitch,
                                        hv[pitch] or 100)
                                changed[lane] = true
                            end
                            hs[pitch] = ph
                            hv[pitch] = vel
                        elseif hs[pitch] then
                            addNote(lane, hs[pitch], ph - hs[pitch], pitch,
                                    hv[pitch] or 100)
                            hs[pitch] = nil
                            hv[pitch] = nil
                            changed[lane] = true
                        end
                    end
                end
            end
        end
    end
    for lane in pairs(changed) do Loop.BumpVer(lane) end
end

-- ---------------------------------------------------------------------------
-- Per-frame pump — the ONE call every host makes before reading anything
-- ---------------------------------------------------------------------------
local dest_chg, dest_t = -1, 0
local was_playing = false

-- THE HOST'S TRANSPORT IS THE MASTER — when we have chosen to follow it.
--
-- A launch and a stop asked for FROM the grid wait for the quantize: that is
-- the whole point of a quantize. The transport's own stop is not one of those.
-- Pressing stop means stop, and until now it meant "carry on to the end of the
-- pass" — the note flush happened in the audio thread but the audio cells kept
-- their scheduled pass, so a bar could go by. Nobody presses stop and means
-- "in a bar".
--
-- The queued stop is the right instrument even so: `stop_target` already
-- returns NOW when no clock runs (cp_lanes.cpp, "rien ne sonne, donc il ne
-- reste rien a finir"), and by this point the transport has stopped, so
-- `active` is false. One command per playing lane, on the frame the transport
-- falls, and Cells stops its voices on the next one when it sees mode 2.
--
-- In FREE RUN nothing happens here, and that is the point of free run: the
-- session is its own transport and REAPER's has no authority over it.
local function followHostStop()
    if Loop.GetFreeRun() then was_playing = false return end
    local playing = Loop.Playing()
    if was_playing and not playing then
        for lane = 0, Loop.MAX_LANES - 1 do
            -- Playing and overdub only. A take in progress is already closed by
            -- the engine on the same falling edge (cp_lanes.cpp, "le transport
            -- s'arrete : une prise en cours se ferme sur ce qu'elle a"), and a
            -- queued stop would not have handled it anyway.
            local m = math.floor((Loop.Mode(lane) or 0) + 0.5)
            if m == 3 or m == 5 then Loop.StopClip(lane) end
        end
    end
    was_playing = playing
end

function Loop.Poll()
    if not NATIVE then return end
    -- THE ANCHOR, first, and it is taken by the ENGINE — CP_ClockSync pairs the
    -- audio clock with the position of the block being PROCESSED, retrying until
    -- the two readings fall inside the same block.
    --
    -- We then build the beat from THAT position rather than from a fresh
    -- GetPlayPosition(). The difference is not cosmetic: GetPlayPosition is the
    -- latency-compensated what-you-hear position, so a beat derived from it
    -- describes an instant that the audio thread produced milliseconds ago, and
    -- every note the engine dates from it lands late by the device's output
    -- latency. Measured before this line existed: up to 28 ms behind the
    -- metronome, constant, no drift.
    r.CP_ClockSync()
    local pos = Loop.Playing() and r.CP_ClockPos() or r.GetCursorPosition()
    r.CP_TransportSync(Loop.Tempo(), r.TimeMap2_timeToQN(0, pos),
                       Loop.Playing() and 1 or 0, Loop.TsNum())
    resolveLive()
    -- AFTER the anchor and resolveLive, BEFORE anything reads a mode: the stop
    -- must be visible to the same frame that draws.
    followHostStop()
    pollCapture()
    local c = r.GetProjectStateChangeCount(0)
    if c ~= dest_chg then
        local now = r.time_precise()
        if now - dest_t >= 0.5 then
            dest_chg, dest_t = c, now
            Loop.RefreshDests()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Clip adapters — a lane IS a MIDI clip
-- ---------------------------------------------------------------------------
-- UN CLIP SANS IDENTITE N'EN EST PAS UN. Le descripteur partait sans `id` ni
-- `cell` : cote editeur `Ident.TagOf` rendait 0, et l'edition ne savait plus
-- revenir a sa lane. On lui donne le tag que la lane porte deja — et on en pose
-- un si elle n'en avait pas, ce qui est le seul moment ou on le peut.
function Loop.LaneToClip(lane)
    local n = Loop.NoteCount(lane)
    if n <= 0 then return nil end
    local s, l, p, v = {}, {}, {}, {}
    Loop.ReadNotes(lane, s, l, p, v)
    local tag = math.floor(Loop.GetLaneTag(lane) or 0)
    if tag == 0 then
        -- Un identifiant qui ne peut collisionner avec aucun autre de la grille
        -- (ceux-ci viennent d'Ident) : le numero de lane, decale tres haut.
        tag = 1000000 + lane
        Loop.SetLaneTag(lane, tag)
    end
    return {
        kind  = "midi",
        id    = tag,
        name  = "Lane " .. (lane + 1),
        notes = { s = s, l = l, p = p, v = v },
        bars  = Loop.GetLengthBars(lane),
        q     = "bar",
        lmode = "loop",
    }
end

-- Live-apply an edited clip into a lane: notes + length only — the mode is NOT
-- touched, so a playing lane keeps playing (the engine reconciles the sounding
-- notes against the new list every block).
function Loop.ApplyClip(lane, clip)
    if not NATIVE or not clip or clip.kind ~= "midi" then return false end
    local nt = clip.notes
    local n = (nt and nt.s and #nt.s) or 0
    if n > Loop.MAX_NOTES then return false end
    local t = store(lane)
    for i = 1, n do
        t.s[i], t.l[i], t.p[i], t.v[i] = nt.s[i], nt.l[i], nt.p[i], nt.v[i]
    end
    t.n = n
    publish(lane)
    if clip.bars and clip.bars > 0
       and clip.bars ~= Loop.GetLengthBars(lane) then
        Loop.SetLengthBars(lane, clip.bars)
    end
    Loop.BumpVer(lane)
    return true
end

function Loop.ClipToLane(lane, clip)
    if not Loop.ApplyClip(lane, clip) then return false end
    if clip.bars and clip.bars > 0 then Loop.SetLengthBars(lane, clip.bars) end
    Loop.SetMode(lane, store(lane).n > 0 and 2 or 0)
    return true
end

-- ---------------------------------------------------------------------------
-- Session recall
--
-- The state used to be mirrored into the router track's P_EXT, so it travelled
-- inside the .RPP with that track. With no track it goes to ProjExtState —
-- still inside the .RPP, still travelling with the project, and now it does
-- not depend on a track surviving a copy-paste.
--
-- Wire format, one string, printable separators only:
--   "5;<global>;<lane>;<lane>;…"                    5 = format version
--   global = "freerun|armedlane|launchq"
--   lane   = "bars|muted|mode|n|s,l,p,v|s,l,p,v|…"
-- v1..v4 (the router-track era) are still read: a project saved before this
-- change opens with its loops.
-- ---------------------------------------------------------------------------
local function num(v) return string.format("%.6g", v or 0) end

local function migrateQ(ver, q)
    if (tonumber(ver) or 0) < 4 and (q or 0) <= 0 then return Loop.TsNum() end
    return q or 0
end

function Loop.Serialize()
    -- FORMAT 6 : le TAG DE LANE entre dans le bloc de chaque lane.
    --
    -- Il n'etait pas serialise, et c'etait une perte silencieuse : le tag est
    -- ce qui relie une case de la grille au clip que le moteur tient. Apres
    -- reouverture, les lanes rejouaient et la grille montrait tout arrete,
    -- parce que plus personne ne savait quelle case correspondait a quelle
    -- lane. Un lecteur ancien ignore le champ (les champs inconnus sont
    -- ignores), un lecteur neuf sur un projet ancien lit 0 — ce qui est
    -- exactement ce que le tag valait avant.
    local out = { "6",
                  (Loop.GetFreeRun() and "1" or "0") .. "|"
                  .. (Loop.GetArmedLane() or -1) .. "|" .. num(Loop.GetLaunchQ()) }
    for lane = 0, Loop.MAX_LANES - 1 do
        local n = Loop.NoteCount(lane)
        local m = math.floor(Loop.Mode(lane) + 0.5)
        -- an in-flight recording (1), arm (4) or overdub (5) is not a state to
        -- restore: store what the lane actually holds
        if m == 1 or m == 4 or m == 5 then m = (n > 0) and 3 or 0 end
        local parts = { num(Loop.GetLengthBars(lane)),
                        Loop.GetMute(lane) and "1" or "0",
                        tostring(m),
                        string.format("%d", math.floor(Loop.GetLaneTag(lane) or 0)),
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

function Loop.Deserialize(str)
    if not NATIVE or not str or str == "" then return false end
    local fields = {}
    for f in str:gmatch("[^;]+") do fields[#fields + 1] = f end
    local ver = fields[1]
    if not ver or not ver:match("^[1-6]$") then return false end
    local v2 = (ver ~= "1")

    local base = v2 and 2 or 1
    if v2 and fields[2] then
        local fr, arm, lq = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)$")
        if not fr then fr, arm = fields[2]:match("^([^|]*)|([^|]*)$") end
        if fr then
            Loop.SetFreeRun(fr == "1")
            -- Before v4 the arm was not a choice: the engine clamped it to a
            -- lane, so EVERY older save carries 0 whether or not anyone armed
            -- anything. Restoring it would re-arm lane 0 in every existing
            -- project, so it is dropped.
            local a = ((tonumber(ver) or 0) >= 4) and math.floor(tonumber(arm) or -1) or -1
            -- ADOPTE, n'arme pas. Restaurer un etat n'est pas un geste de
            -- l'utilisateur : ouvrir un projet ne doit armer aucune piste.
            Loop.AdoptArmedLane(a >= 0 and a or nil)
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
            -- v6 glisse le TAG entre le mode et le nombre de notes. Avant lui,
            -- le tag n'etait nulle part : zero est donc la reponse juste pour
            -- un projet ancien, et c'est ce que la lane valait deja.
            local v6   = (ver == "6")
            local tag  = v6 and math.floor(tonumber(t[4]) or 0) or 0
            local hdr  = v6 and 5 or (v2 and 4 or 3)
            local n     = math.floor(tonumber(t[hdr]) or 0)
            if n > Loop.MAX_NOTES then n = Loop.MAX_NOTES end
            local written = 0
            for i = 1, n do
                local rec = t[hdr + i]
                if rec then
                    local s, l, p, v = rec:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
                    if s then
                        Loop.PutNote(lane, written, tonumber(s) or 0,
                                     tonumber(l) or 0.25, tonumber(p) or 60,
                                     tonumber(v) or 100)
                        written = written + 1
                    end
                end
            end
            Loop.SetLengthBars(lane, bars)
            Loop.SetMute(lane, muted)
            Loop.SetLaneTag(lane, tag)            -- qui joue quoi, apres reouverture
            Loop.SetNoteCount(lane, written)      -- publishes
            -- mode last: it is what makes the lane sound, so nothing may be
            -- playing off a half-written note list
            if written == 0 then Loop.SetMode(lane, 0)
            elseif mode == 3 then Loop.SetMode(lane, 3)
            else Loop.SetMode(lane, 2) end
            Loop.BumpVer(lane)
            loaded = loaded + written
        end
    end
    return true, loaded
end

function Loop.SavedState()
    local _, v = r.GetProjExtState(0, EXT_SEC, DATA_KEY)
    if v and v ~= "" then return v end
    -- A project written in the router era: the blob is on whatever track still
    -- carries the marker. Read it once — this is the migration, and it costs a
    -- scan on a project that has no CP state at all.
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        local _, mark = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. LEGACY_TAG, "", false)
        if mark == "router" then
            local _, old = r.GetSetMediaTrackInfo_String(
                tr, "P_EXT:" .. LEGACY_TAG .. "_DATA", "", false)
            if old and old ~= "" then return old end
        end
    end
    return ""
end

-- SANS LE MOTEUR, ON N'ECRIT PAS. Serialize interroge le moteur pour chaque
-- lane ; sans lui il rend huit lanes vides, et les ecrire par-dessus l'etat du
-- projet EFFACE le travail de l'utilisateur — a la fermeture de la fenetre,
-- sans un mot. `Deserialize` refusait deja quand `not NATIVE` : la lecture
-- etait protegee, l'ecriture ne l'etait pas. Trois lignes.
function Loop.SaveState()
    if not NATIVE then return false end
    r.SetProjExtState(0, EXT_SEC, DATA_KEY, Loop.Serialize())
    return true
end

function Loop.HasSavedState() return Loop.SavedState() ~= "" end

-- Recall. Refuses when any lane already holds notes unless forced: a recall
-- must never silently overwrite what is currently playing.
function Loop.LoadState(force)
    if not force then
        for lane = 0, Loop.MAX_LANES - 1 do
            if Loop.NoteCount(lane) > 0 then return false end
        end
    end
    return Loop.Deserialize(Loop.SavedState())
end

-- Clock mode and armed lane are SESSION settings, not lane content, so they
-- are restored unconditionally — unlike the notes, which decline to overwrite
-- lanes that already hold something.
function Loop.LoadGlobals()
    if not NATIVE then return false end
    local str = Loop.SavedState()
    if str == "" then return false end
    local fields = {}
    for f in str:gmatch("[^;]+") do fields[#fields + 1] = f end
    if fields[1] == "1" or not fields[2] then return false end
    local fr, arm, lq = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)$")
    if not fr then fr, arm = fields[2]:match("^([^|]*)|([^|]*)$") end
    if not fr then return false end
    Loop.SetFreeRun(fr == "1")
    local a = ((tonumber(fields[1]) or 0) >= 4)
              and math.floor(tonumber(arm) or -1) or -1
    Loop.AdoptArmedLane(a >= 0 and a or nil)
    if lq then Loop.SetLaunchQ(migrateQ(fields[1], tonumber(lq))) end
    return true
end

-- ---------------------------------------------------------------------------
-- AUTOSAVE
--
-- Persistence is a property of the STATE, not of one window. It used to live
-- privately inside CP_Looper, so a set built entirely in CP_Session was lost
-- when REAPER closed — invisible while you work, obvious the next morning.
--
-- The cross-project hazard that came with it is GONE rather than guarded: the
-- lanes lived in gmem, which belongs to the REAPER session and not to the
-- project, so switching projects left the previous project's loops loaded and
-- an autosave would have written one project's set into another's file. The
-- notes now live in this module — one instance per script, per project — and
-- ProjExtState is the project's own. There is nothing left to detect.
-- ---------------------------------------------------------------------------
local save_vers = {}
local save_due  = 0
local save_hold = false
local adopted   = false

-- Kept because two windows call it. It answers false now, and that is not a
-- stub: the condition it detected cannot arise any more (see above).
function Loop.RouterChanged() return false end

function Loop.IsAdopted() return adopted end
function Loop.HoldAutoSave(on) save_hold = on and true or false end
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
end

function Loop.AutoSave()
    if not adopted or not NATIVE then return end
    local now = r.time_precise()
    if save_due < 0 then save_due = now + 0.4 end
    for lane = 0, Loop.MAX_LANES - 1 do
        -- Mode counts as much as notes do: launching or stopping a clip changes
        -- the state to restore while bumping no event version at all.
        local v = Loop.EvtVersion(lane) * 8 + math.floor(Loop.Mode(lane) + 0.5)
        if v ~= save_vers[lane] then
            save_vers[lane] = v
            save_due = now + 0.4
        end
    end
    if save_due > 0 and now >= save_due and not save_hold then
        save_due = 0
        Loop.SaveState()
    end
end

return Loop
