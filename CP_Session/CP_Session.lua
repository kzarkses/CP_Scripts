-- @description Session (CP) — Ableton-style clip grid over the CP Looper engine
-- @version 0.2 (tracks × scenes)
-- @author Cedric Pamalio
-- @about
--   The session grid: one COLUMN per track, one ROW per scene, one clip per
--   cell. A track plays exactly one clip at a time — launching a cell stops
--   whatever that track was playing, which is the whole feel of a session
--   view (see ANALYSE_Ableton_Session.md).
--
--   The engine (gmem CP_MidiLooper) is untouched: each track owns TWO lanes,
--   a playing one and a silent twin. Launching writes the clip into the twin
--   (inaudible, so timing doesn't matter) then asks the engine for Play+Stop
--   — both quantized — so the swap lands exactly on the boundary.
--
--   Cells are edited ONLY in CP_Editor (double-click, or right-click → Edit):
--   they are stored as CPC1 descriptors in the project, and edits come back
--   live over the bus.
--
--   The engine is shared, and this window can create it: no other script has
--   to be opened first.

local r = reaper

-- ---------------------------------------------------------------------------
-- Toolkit + engine
-- ---------------------------------------------------------------------------
local cp_root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
local UI     = dofile(cp_root .. "CP_Toolkit/CP_Toolkit.lua")
local Tracks = dofile(cp_root .. "CP_Engine/Tracks.lua")
local Loop   = dofile(cp_root .. "CP_Engine/Loop.lua")
local Clip   = dofile(cp_root .. "CP_Engine/Clip.lua")
local Mix    = dofile(cp_root .. "CP_Engine/Mix.lua")
local DragBus = dofile(cp_root .. "CP_Toolkit/DragBus.lua")
local Bus    = dofile(cp_root .. "CP_Engine/Bus.lua")
Tracks.init(r)
Loop.init(r, Tracks)
Mix.init(r)
DragBus.init(r)
Bus.init(r, DragBus, Clip)

local Core = UI.Core
local sin, floor = math.sin, math.floor

-- One track = two engine lanes (playing + silent twin). That pairing is the
-- ENGINE's, not this window's: Loop.LiveLane / Loop.TwinLane answer for it,
-- so CP_Looper and CP_Editor see the same picture without a copy of the
-- rule living here to drift out of date.
local TRACKS = Loop.TRACKS
local SCENES = 8

local cells = {}     -- [t][s] = clip descriptor or nil
local cur   = {}     -- [t] = scene whose clip is loaded, or nil
local cdrag = nil    -- { t, s } source cell while a Ctrl-drag copy is in flight
for t = 0, TRACKS - 1 do cells[t] = {} end

local state = {
    flash_msg = "", flash_until = 0,
    recalled = false,      -- one-shot auto-recall after the first attach
    registered = false,    -- DragBus target registration
    grid = nil,            -- grid geometry (drop hit-testing)
    arow = nil,            -- audio-cell row geometry
    engine_checked = false,   -- one-shot "is the loaded engine current" probe
    engine_tried   = false,   -- one-shot auto-create (opening this window IS the ask)
}

local function flash(msg)
    state.flash_msg = msg
    state.flash_until = r.time_precise() + 2.5
end

-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## What a column is
A column is a LANE of the looper engine, and it plays into the REAPER
track it is routed to — the same routing CP_Looper edits. Click a
column's NAME to choose that track, make a new one, or unroute it. A
column that says "no track" plays into nothing yet.

## The grid
A column per track, a row per scene, one clip per cell. Every cell
carries the button that says what a click does: TRIANGLE launches,
SQUARE stops what is playing, CIRCLE records. Launching is QUANTIZED
(the Q button) and whatever that track was playing stops by itself —
a track only ever plays one clip.
The row of squares under the grid stops one track (or all of them,
the one on the left); the triangle beside a row launches that whole
scene, and tracks with no clip in it stop, as in Ableton.

## Recording into a cell
1. ARM the track — the circle in its header. One track at a time: the
   armed track is the one your playing is heard through, so arming is
   also how you choose which instrument you are playing.
2. Click the circle in any EMPTY cell of that track.
3. Play. A MIDI keyboard, or REAPER's virtual keyboard. Clicking pads in
   CP_Sampler does NOT record — those are previews, not playing.

The take does not start on your click: it waits for the next Q boundary,
and the cell counts the beats down so you can come in on time. It then
records for "Rec: N bars" and closes itself — there is nothing to press
to end it. A second click on the blinking button finalizes a take early,
or drops one that has not started.

With Clock: Follow and the transport stopped, the cell says PLAY: it is
armed and waiting for the transport. Press play and the take begins at
the next boundary. With Clock: Free the engine has its own clock, so it
starts without touching REAPER's transport.

## Editing
The button strip on the left of a cell is the transport; clicking
ANYWHERE ELSE in the cell opens it in CP_Editor (launched if needed) —
looking at a clip never changes what is playing, and launching is never
a side effect of wanting to edit. CP_Editor is the only place a cell is
edited: notes, loop length, playhead and transport live there, and the
edits come back here live. Right-click: edit, rename, COLOR, clear,
stop. A clip's colour is its own and travels with it — copy a cell and
the copy keeps it.

## Sound or MIDI, same cell
Any cell takes either. Drop a sound from the Media Explorer and it
loops TEMPO-MATCHED (native stretch), measure-aligned when the
transport runs, through that column's track. Drop or write MIDI and it
plays through the engine. A track still plays ONE thing at a time,
whichever kind — launching a sound stops the MIDI under it and the
other way round. A sound obeys the clock like everything else: with
Clock: Follow and the transport stopped it is ARMED and blinks, and it
starts when the transport does. (Sounds use the interim preview engine;
the sample-locked one comes later.)

## The mixer strip
The band under the grid (toggle it beside the "?") balances what you
are launching: per column, VOLUME, M and S, and a meter. It acts on
the track the column is routed to — so it is also the level of
whatever CP_Sampler or CP_Editor sends there. Drag the fader,
Shift for fine, double-click for 0 dB, wheel to step. Solo is
REAPER's solo: the arrangement goes quiet too, exactly as in Ableton.
Ctrl-click it for exclusive. Everything else a console has is a
keystroke away in REAPER's own mixer, which is better than anything
this window would draw.

## Clock
Free = clips play without the transport. Follow = REAPER transport,
locks to an external MIDI clock when slaved.

## One engine
This grid, CP_Looper and CP_Editor drive the SAME engine and read the
same state — a clip launched in one shows as playing in the others.
CP_Looper's lane N is this grid's column N, and CP_Editor's playhead is
that clip's own. Whichever window you opened first can create the
engine.
]]

-- ---------------------------------------------------------------------------
-- Lane pairing — resolved by the engine (Loop.Poll re-derives it each frame)
-- ---------------------------------------------------------------------------
local liveLane  = Loop.LiveLane
local twinLane  = Loop.TwinLane
local isRunning = Loop.IsRunning

-- Every cell carries a numeric identity, so the lane holding it can say so
-- and any window can find that clip again after the halves swapped. Numeric
-- form: no allocation, callable per cell per frame.
local cellTag = Clip.CellTag

-- Which scene of track t a lane is holding, straight from the engine's tag.
-- This is how the grid follows a launch fired from CP_Looper or CP_Editor
-- instead of arguing with it.
local function sceneOfLane(lane, t)
    local tt, ss = Clip.CellOfTag(Loop.GetLaneTag(lane))
    if tt ~= t then return nil end
    return ss
end

-- ---------------------------------------------------------------------------
-- Display caches (zero allocation per frame: strings rebuilt only when the
-- underlying fact changes)
-- ---------------------------------------------------------------------------
local track_name = {}   -- [t] = { tr = ptr|false, s = "name" }
local bars_lbl   = {}   -- [bars] = "N bars"
local cell_lbl   = {}   -- [t*SCENES+s] = { src = "name", w = width, s = "cut" }
for t = 0, TRACKS - 1 do track_name[t] = { tr = false, s = "Track " .. (t + 1) } end

-- A column is a LANE, and a lane plays into whatever track it is routed to
-- (CP_Looper's routing, shared). Saying "Track 1" when nothing is routed
-- would be a lie — an unrouted column plays into nothing, and the header
-- has to admit it.
local function trackName(t)
    local c = track_name[t]
    local tr = Loop.GetLaneDest(t) or false
    if tr ~= c.tr then
        c.tr = tr
        if tr then
            local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            if nm and nm ~= "" then
                c.s = nm
            else
                local n = math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
                c.s = "Track " .. n
            end
        else
            c.s = "no track"
        end
    end
    return c.s
end

-- Route this column: pick any project track, or make one. This is the same
-- routing CP_Looper edits — one truth, two windows.
local function trackMenu(t)
    local items = {}
    local n = r.CountTracks(0)
    local cur_tr = Loop.GetLaneDest(t)
    for i = 0, n - 1 do
        local tr = r.GetTrack(0, i)
        -- the router hosts the engine and sends nothing to itself: offering
        -- it would look like a choice and silently unroute the column
        if tr ~= Loop.track then
            local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            items[#items + 1] = {
                label = (i + 1) .. ": " .. ((nm and nm ~= "") and nm or "(unnamed)"),
                checked = (tr == cur_tr),
                action = function()
                    Loop.SetLaneDest(t, tr)      -- routes BOTH halves of the pair
                    track_name[t].tr = false     -- force the cached name to refresh
                end,
            }
        end
    end
    if #items > 0 then items[#items + 1] = { separator = true } end
    items[#items + 1] = { label = "New track for this column", action = function()
        Loop.NewDestTrack(t)
        track_name[t].tr = false
    end }
    if cur_tr then
        items[#items + 1] = { label = "Unroute", action = function()
            Loop.SetLaneDest(t, nil)
            track_name[t].tr = false
        end }
    end
    UI.NativeMenu(items)
end

local function barsLabel(bars)
    local s = bars_lbl[bars]
    if not s then
        s = bars == 1 and "1 bar" or (bars .. " bars")
        bars_lbl[bars] = s
    end
    return s
end

-- Truncation allocates, so the cut string is cached against (name, width).
local function cellLabel(t, s, name, w)
    local k = t * SCENES + s
    local c = cell_lbl[k]
    if not c then c = {}; cell_lbl[k] = c end
    if c.src ~= name or c.w ~= w then
        c.src, c.w = name, w
        c.s = (Core.TruncateText(name, w))
    end
    return c.s
end

-- Launch quantize and take length are CHOICES among a handful, not buttons
-- that cycle. As combos the wheel walks them, the current setting reads
-- without clicking, and you land on the one you want instead of pressing four
-- times. Both lists are stored in beats / bars so the engine never needs to
-- know about the words.
local Q_ITEMS = { "Q: Off", "Q: Beat", "Q: Bar", "Q: 2 bars", "Q: 4 bars" }
local Q_OPTS  = { w = 3 }
local TITLE_OPTS = { title = "Session" }

local function qIndex()
    local q, tsn = Loop.GetLaunchQ(), Loop.TsNum()
    if q <= 0 then return 1 end
    if q == 1 then return 2 end
    if q == tsn then return 3 end
    if q == tsn * 2 then return 4 end
    if q == tsn * 4 then return 5 end
    return 1
end

local function setQIndex(i)
    local tsn = Loop.TsNum()
    local nq = 0
    if i == 2 then nq = 1
    elseif i == 3 then nq = tsn
    elseif i == 4 then nq = tsn * 2
    elseif i == 5 then nq = tsn * 4 end
    Loop.SetLaunchQ(nq)
end

-- How long a take runs. The engine records for the lane's length and closes
-- the take itself (one click in, nothing to press to end it) — so unlike
-- Ableton, where a session recording is open-ended until you stop it, the
-- length has to be known BEFORE the take. Leaving it to whatever the lane
-- happened to hold made it unknowable; it is a stated setting now, next to
-- the quantize that says when the take starts. Saved with the project.
local REC_BARS  = { 1, 2, 4, 8 }
local REC_ITEMS = { "Rec: 1 bar", "Rec: 2 bars", "Rec: 4 bars", "Rec: 8 bars" }
local rec_bars = 1

local function recBarsIndex()
    for i = 1, #REC_BARS do
        if REC_BARS[i] == rec_bars then return i end
    end
    return 1
end

local function setRecBarsIndex(i)
    rec_bars = REC_BARS[i] or 1
    r.SetProjExtState(0, "CP_Session", "rec_bars", tostring(rec_bars))
end

-- The status line carries the transport, so it changes — but only when the
-- transport does. Cached on (playing, tempo): string.format in a frame path
-- allocates, and this one runs on every frame of a window that redraws
-- continuously while clips play.
local stat = { play = nil, bpm = -1, s = "" }
local STAT_HINT =
    "  ·  left strip = launch/stop/record · click the cell = edit in CP_Editor · triangle = scene"

local function statusLine()
    local playing = Loop.Playing() and true or false
    local bpm = Loop.Tempo() or 0
    if stat.play ~= playing or stat.bpm ~= bpm then
        stat.play, stat.bpm = playing, bpm
        stat.s = string.format("%s   %.1f BPM%s", playing and "PLAY" or "STOP",
                               bpm, STAT_HINT)
    end
    return stat.s
end

-- ---------------------------------------------------------------------------
-- The grid, stored with the project (CPC1 per cell, one per line — the
-- descriptor escapes newlines, so the split is safe)
-- ---------------------------------------------------------------------------
local function saveGrid()
    local out = {}
    for t = 0, TRACKS - 1 do
        for s = 0, SCENES - 1 do
            local c = cells[t][s]
            if c then
                out[#out + 1] = t .. ":" .. s .. ":" .. Clip.serialize(c)
            end
        end
    end
    r.SetProjExtState(0, "CP_Session", "grid", table.concat(out, "\n"))
end

local function loadGrid()
    local _, blob = r.GetProjExtState(0, "CP_Session", "grid")
    if not blob or blob == "" then return end
    for line in blob:gmatch("[^\n]+") do
        local t, s, body = line:match("^(%d+):(%d+):(.*)$")
        t, s = tonumber(t), tonumber(s)
        if t and s and t < TRACKS and s < SCENES and body then
            local c = Clip.deserialize(body)
            if c then cells[t][s] = c end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Audio cells. A cell holds EITHER a MIDI clip or a sound — same grid, same
-- gestures, interchangeable. MIDI goes through the JSFX lanes; audio goes
-- through CF_Preview, tempo-matched and looped (the interim engine, until
-- the sample-locked one exists). Exclusivity is enforced across both: a
-- track plays one thing, whatever its kind.
-- ---------------------------------------------------------------------------
local HAS_CF = r.CF_CreatePreview ~= nil
local aplay = {}   -- [t] = { prev, src, s } the sound this track is playing

local function audioStop(t)
    local a = aplay[t]
    if not a then return end
    if a.prev then pcall(r.CF_Preview_Stop, a.prev) end
    if a.src then r.PCM_Source_Destroy(a.src) end
    aplay[t] = nil
end

-- Give back the preview but KEEP the cell armed: what the transport took away
-- it can give back. Used when the clock follows a transport that stopped.
local function audioRelease(t)
    local a = aplay[t]
    if not a then return end
    if a.prev then pcall(r.CF_Preview_Stop, a.prev) end
    if a.src then r.PCM_Source_Destroy(a.src) end
    a.prev, a.src, a.align = nil, nil, nil
end

-- Actually make the sound. Split from audioPlay because a launch and the
-- moment it starts are two different things as soon as the clock follows.
local function audioStart(t)
    local a = aplay[t]
    if not a or a.prev then return end
    local c = a.c
    local src = r.PCM_Source_CreateFromFile(c.path)
    if not src then flash("Cannot open: " .. (c.path or "?")) aplay[t] = nil return end
    local prev = r.CF_CreatePreview(src)
    -- drop the cell rather than leave it armed: a start that cannot succeed
    -- would be retried on every frame, disk open included
    if not prev then r.PCM_Source_Destroy(src) aplay[t] = nil return end
    local ok, _, rate = pcall(r.GetTempoMatchPlayRate, src, 1.0, 0, 1.0)
    local rt = (ok and rate and rate > 0.05 and rate < 20) and rate or 1.0
    r.CF_Preview_SetValue(prev, "D_VOLUME", 1)
    if rt ~= 1.0 then
        r.CF_Preview_SetValue(prev, "D_PLAYRATE", rt)
        r.CF_Preview_SetValue(prev, "B_PPITCH", 1)
    end
    r.CF_Preview_SetValue(prev, "B_LOOP", 1)
    local align = false
    if (r.GetPlayState() & 1) == 1 then
        r.CF_Preview_SetValue(prev, "D_MEASUREALIGN", 1)
        align = true
    end
    -- Route through the track this column stands for, so its FX apply — but
    -- NOT when that track hosts a virtual instrument: a VSTi replaces its
    -- input with its own output, so the sound would simply vanish into it.
    -- And no falling back to "whatever track happens to be selected": that
    -- put a sound through an unrelated chain depending on where the user had
    -- last clicked.
    local tr = Loop.GetLaneDest(t)
    if tr and r.TrackFX_GetInstrument then
        local ok, ins = pcall(r.TrackFX_GetInstrument, tr)
        if ok and ins and ins >= 0 then tr = nil end
    end
    if tr and r.CF_Preview_SetOutputTrack then
        r.CF_Preview_SetOutputTrack(prev, 0, tr)
    end
    r.CF_Preview_Play(prev)
    a.prev, a.src, a.align = prev, src, align
end

-- Is the clock RUNNING? Free run has its own, which never stops; following
-- means there is nothing to follow until the transport rolls.
local function clockRolling()
    if Loop.GetFreeRun() then return true end
    return (r.GetPlayState() & 1) == 1
end

-- Launch a sound cell. With the clock free it starts on the spot; following a
-- stopped transport it is ARMED and starts when the transport does — which is
-- what following MEANS, and what the MIDI lanes have always done (the engine
-- advances on the host beat, so a launch queued on a stopped transport simply
-- waits). Sound cells used to ignore that and start immediately: the grid
-- showed a clip waiting for a transport, and the sound came out anyway.
local function audioPlay(t, s, c)
    audioStop(t)
    if not HAS_CF then flash("Audio cells need the SWS extension") return end
    aplay[t] = { s = s, c = c }
    if clockRolling() then audioStart(t) end
end

-- Per-frame reconciliation of the sound cells with the clock:
--   * armed + the clock rolling      → start (measure-aligned)
--   * playing + the transport left   → give the preview back, stay armed
--   * playing + still aligned        → release the align (see below)
--
-- CF_Preview's measure align holds EVERY loop pass to the grid, not only the
-- first. A sample that is not exactly N measures long therefore WAITS at the
-- end of each pass — the gap that appears with Clock: Follow and never with
-- Free (where the transport is stopped, so the align was never set).
-- So: align the START, then release it. The launch still lands on the bar, and
-- the loop runs seamlessly afterwards, which is what a session clip does
-- everywhere else. Released only once playback has actually begun — clearing
-- it while the preview is still waiting for the bar would start it on the spot.
local function pollAudio()
    local rolling = clockRolling()
    for t = 0, TRACKS - 1 do
        local a = aplay[t]
        if a then
            if not a.prev then
                if rolling then audioStart(t) end
            elseif not rolling then
                audioRelease(t)
            elseif a.align then
                local ok, rv, pos = pcall(r.CF_Preview_GetValue, a.prev, "D_POSITION")
                if ok and rv and pos and pos > 0 then
                    pcall(r.CF_Preview_SetValue, a.prev, "D_MEASUREALIGN", 0)
                    a.align = false
                end
            end
        end
    end
end

local function isAudio(c) return c and c.kind == "audio" and c.path end

local function cellBars(c)
    local b = c and c.bars or 4
    if not b or b < 1 then b = 4 end
    return floor(b + 0.5)
end

local function cellNotes(c)
    local n = c and c.notes
    return (n and n.s and #n.s) or 0
end

-- ---------------------------------------------------------------------------
-- Launching — the heart of the thing
-- ---------------------------------------------------------------------------
-- Write a clip into a lane WITHOUT playing it (the lane is the silent twin,
-- so the write timing is free) and leave it "stopped with content", which is
-- the state the engine can launch from.
local function armLane(lane, c, t, s)
    Loop.ApplyClip(lane, c)
    Loop.SetLengthBars(lane, cellBars(c))
    -- stamp WHICH cell this lane now holds: it is how CP_Editor finds the
    -- clip again after a swap moved it to the other half, and how it knows
    -- to stop writing when the lane got reused for something else
    Loop.SetLaneTag(lane, cellTag(t, s))
    if cellNotes(c) > 0 and floor(Loop.Mode(lane) + 0.5) == 0 then
        Loop.SetMode(lane, 2)
    end
end

local function stopTrack(t)
    audioStop(t)   -- a track plays ONE thing, whatever its kind
    local lane = liveLane(t)
    local m = floor(Loop.Mode(lane) + 0.5)
    if m == 3 or m == 5 then Loop.StopClip(lane)
    elseif Loop.Pending(lane) == 1 then Loop.StopClip(lane) end  -- cancel queue
end

-- Launch cell (t, s). Re-launching the cell that is already playing stops it
-- (Ableton's toggle on the same clip); launching a different one swaps the
-- buffers so the change happens on the boundary instead of mid-loop.
local function launchCell(t, s)
    local c = cells[t][s]
    if isAudio(c) then
        -- sound cell: same gestures, different engine. Re-launching the one
        -- that plays stops it, and starting it evicts whatever the track had.
        local a = aplay[t]
        if a and a.s == s then audioStop(t) return end
        stopTrack(t)
        audioPlay(t, s, c)
        cur[t] = s
        return
    end
    if not c or cellNotes(c) == 0 then
        flash("Empty cell — click the cell to write something in it")
        return
    end
    -- The lane holding THIS cell — which is the SILENT half while its launch
    -- is still queued. Asking the engine for it, instead of assuming the
    -- track's live lane, is what makes a second click cancel the right thing
    -- rather than cancel the outgoing clip's stop and leave two playing.
    local mine = Loop.LaneOfTag(t, cellTag(t, s))
    if mine then
        -- A queued swap arms BOTH halves: the outgoing one is queued to stop
        -- and the incoming one to play, on the same boundary. Cancelling one
        -- alone leaves the other's queue to fire — two clips on one track, or
        -- none. So every cancel here reconciles the pair.
        local twin = (mine == t) and (t + TRACKS) or t
        local p = Loop.Pending(mine)
        if p == 1 then                                  -- cancel the queued launch
            if Loop.Pending(twin) == 2 then Loop.Play(twin) end   -- …and keep the outgoing clip
            Loop.StopClip(mine)
            return
        end
        if p == 2 then                                  -- take the queued stop back
            if Loop.Pending(twin) == 1 then Loop.StopClip(twin) end -- …and drop the incoming one
            Loop.Play(mine)
            return
        end
        if isRunning(mine) then                         -- playing: this click stops it
            audioStop(t)
            Loop.StopClip(mine)
            return
        end
    end

    audioStop(t)   -- this track was playing a sound: it leaves
    local live = liveLane(t)
    -- a launch queued on the other half loses: a track plays ONE clip, and
    -- this click is what chose which
    local other = (live == t) and (t + TRACKS) or t
    if Loop.Pending(other) == 1 then Loop.StopClip(other) end
    local busy = isRunning(live) or Loop.Pending(live) == 1
    if not busy then
        -- nothing to swap: load the live lane directly. This also keeps
        -- ordinary use on the low lanes — the ones CP_Looper shows.
        armLane(live, c, t, s)
        Loop.Play(live)
        cur[t] = s
        return
    end
    local twin = twinLane(t)
    armLane(twin, c, t, s)
    Loop.Play(twin)         -- queued to the next boundary…
    Loop.StopClip(live)     -- …and the outgoing one leaves on the same one
    -- which half is live is re-derived from the engine (Loop.Poll), not
    -- flipped here: a launch fired from CP_Editor or CP_Looper would
    -- otherwise leave this window pointing at the wrong lane.
    cur[t] = s
end

-- A whole scene lands together: every track with a clip launches, every
-- track without one STOPS (Ableton's default — a scene is a full picture).
local function sceneLaunch(s)
    for t = 0, TRACKS - 1 do
        if cells[t][s] and cellNotes(cells[t][s]) > 0 then
            launchCell(t, s)
        else
            stopTrack(t)
        end
    end
end

local function stopAll()
    for t = 0, TRACKS - 1 do stopTrack(t) end
end

-- ---------------------------------------------------------------------------
-- Editing — CP_Editor only, and it must be able to PLAY what it edits
-- ---------------------------------------------------------------------------
-- A cell that is currently playing is edited THROUGH its live lane, so the
-- edits are heard as they are made. Any other cell is loaded into the silent
-- twin first: the editor then has a real lane to drive (playhead, launch)
-- without disturbing what is playing.
local function editCell(t, s)
    local c = cells[t][s]
    if not c then
        c = Clip.new("midi")
        c.notes = { s = {}, l = {}, p = {}, v = {} }
        c.bars = 4
        cells[t][s] = c
        saveGrid()
    end
    -- If the engine already holds this cell (playing, or staged by an
    -- earlier edit) keep that lane: writing anywhere else would edit one
    -- clip and hear another. Otherwise stage it in the silent half, so the
    -- editor gets a real lane to drive without disturbing what is playing.
    local tag = cellTag(t, s)
    if not Loop.LaneOfTag(t, tag) then
        armLane(twinLane(t), c, t, s)
    end
    -- The descriptor names the TRACK. WHICH half holds the clip changes
    -- under it as clips swap, so it is asked for again — never stored.
    c.origin = "looper:" .. t
    c.cell = t .. "," .. s
    c.name = (c.name and c.name ~= "") and c.name
             or (trackName(t) .. " · scene " .. (s + 1))
    Bus.OpenEditor(c)
    flash("Cell opened in CP_Editor")
end

-- Edits coming home. The cell coordinates travel with the clip, so the
-- descriptor lands back in the right cell even if the lanes have swapped
-- since; the live lane is refreshed too when that cell is the one playing.
local function applyEdit(ac)
    local t, s
    if ac.cell then t, s = ac.cell:match("^(%d+),(%d+)$") end
    t, s = tonumber(t), tonumber(s)
    if t and s and t < TRACKS and s < SCENES then
        cells[t][s] = ac
        saveGrid()
        -- refresh the lane that HOLDS this cell — playing or merely staged —
        -- and not whatever the track happens to be playing right now
        local lane = Loop.LaneOfTag(t, cellTag(t, s))
        if lane then
            Loop.ApplyClip(lane, ac)
            if ac.bars and ac.bars > 0 then Loop.SetLengthBars(lane, ac.bars) end
        end
        return true
    end
    -- no cell tag: a plain lane edit (CP_Looper's own clips)
    local ln = ac.origin and tonumber(ac.origin:match("^looper:(%d+)"))
    if ln and ln >= 0 and ln < Loop.MAX_LANES then
        Loop.ApplyClip(ln, ac)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Recording into a cell — the other half of a session view: an armed track
-- captures into an empty slot, and what comes out lands in that cell.
-- ---------------------------------------------------------------------------
local rec = nil   -- { t, s } while a capture is running

-- Armed is a TRACK fact, not a lane one: the pair swaps buffers as clips
-- change, and the arm must not appear to move with it.
local function isArmed(t)
    local a = Loop.GetArmedLane()
    if not a then return false end
    return (floor(a + 0.5) % TRACKS) == t
end

-- A toggle, and only one track can hold it. Arming is what opens the live
-- input path — the engine hands whatever you play to the armed track's
-- instrument — so being unable to close it again was never defensible: it
-- left every project monitoring something the user had not chosen.
local function armTrack(t)
    if isArmed(t) then
        Loop.SetArmedLane(nil)
        flash("Input off — nothing is monitored")
    else
        Loop.SetArmedLane(liveLane(t))
        flash("Playing goes to " .. trackName(t) .. " · record into an empty slot")
    end
end

-- Recording into an empty slot is a clip SWAP like any other: the track may
-- be playing something else, and that something has to leave on the same
-- boundary the take arrives on. So the take goes into the silent twin
-- whenever the live half is busy, exactly as launchCell does. Sending REC to
-- the live half instead would have cleared the clip the track was playing.
local function recCell(t, s)
    audioStop(t)                            -- a sound cell on this track leaves
    local live = liveLane(t)
    local other = (live == t) and (t + TRACKS) or t
    if Loop.Pending(other) == 1 then Loop.StopClip(other) end
    local busy = isRunning(live) or Loop.Pending(live) == 1
    local lane = busy and twinLane(t) or live
    Loop.SetArmedLane(lane)                 -- monitor the half that captures
    Loop.SetLaneTag(lane, cellTag(t, s))    -- the take lands in THIS cell
    Loop.SetLengthBars(lane, rec_bars)      -- stated, not inherited from the lane
    Loop.Rec(lane)                          -- quantized; auto-stops on the length
    if busy then Loop.StopClip(live) end    -- outgoing clip leaves on that boundary
    rec = { t = t, s = s, lane = lane, seen = false, t0 = r.time_precise() }
    cur[t] = s
end

-- The capture is the engine's business; we only watch for its end and keep
-- what it produced. Recording finishes into "playing" (the loop rolls on).
--
-- It watches the lane the command was SENT TO, never "the track's live lane":
-- the live half moves as clips swap, and following it made this poll read a
-- different clip halfway through a take.
--
-- `seen` is the other half of the same lesson. A command does not take effect
-- on the frame it is issued — the engine consumes one per audio block — so
-- for a few frames the lane is still mode 0, because the slot was empty.
-- Reading that as "cleared under us" dropped the recording before it had
-- started: the take ran, the notes were captured, the editor showed them, and
-- the grid never grew a clip because nothing was left watching. It also made
-- the red cell appear only when the timing happened to fall the other way,
-- which is what "once in two" was.
local REC_PICKUP_TIMEOUT = 3.0

local function pollRec()
    if not rec then return end
    local m = floor(Loop.Mode(rec.lane) + 0.5)
    if m == 1 or m == 4 or Loop.Pending(rec.lane) == 3 then
        rec.seen = true                     -- the engine has the command
        return
    end
    if not rec.seen then
        if r.time_precise() - rec.t0 < REC_PICKUP_TIMEOUT then return end
        rec = nil
        flash("The engine never took the record command")
        return
    end
    if m == 0 then rec = nil return end     -- cleared under us
    local c = Loop.LaneToClip(rec.lane)
    if c then
        c.cell = rec.t .. "," .. rec.s
        c.name = trackName(rec.t) .. " · " .. (rec.s + 1)
        cells[rec.t][rec.s] = c
        saveGrid()
        flash("Captured into " .. c.name)
    else
        flash("Nothing played — the slot stays empty")
    end
    rec = nil
end

-- Second click on a blinking record button, as in a session view: a take in
-- progress is FINALIZED (pollRec keeps what was played), one that has not
-- started yet is dropped. Without this the only way out of a capture you did
-- not mean to start was to wait for its auto-stop.
local function stopRec()
    if not rec then return end
    if floor(Loop.Mode(rec.lane) + 0.5) == 1 then
        Loop.Stop(rec.lane)
    else
        Loop.Clear(rec.lane)
        rec = nil
        flash("Recording cancelled")
    end
end

local function clearCell(t, s)
    if not cells[t][s] then return end
    -- empty the lane that holds it too (and only that one), or the engine
    -- would keep playing a clip the grid no longer has
    local lane = Loop.LaneOfTag(t, cellTag(t, s))
    cells[t][s] = nil
    saveGrid()
    if lane then Loop.Clear(lane) end
    if cur[t] == s then
        audioStop(t)
        cur[t] = nil
    end
end

-- Deep copy of a clip descriptor: the copy must own its notes, or editing one
-- cell would silently rewrite every cell it was ever duplicated from.
local function copyCell(c)
    local d = {}
    for k, v in pairs(c) do d[k] = v end
    local nt = c.notes
    if nt then
        local s, l, p, v = {}, {}, {}, {}
        for i = 1, #(nt.s or {}) do
            s[i], l[i], p[i], v[i] = nt.s[i], nt.l[i], nt.p[i], nt.v[i]
        end
        d.notes = { s = s, l = l, p = p, v = v }
    end
    d.cell, d.origin = nil, nil   -- it belongs to wherever it lands, not here
    return d
end

-- Drop a copy into (t, s), replacing what was there.
local function pasteCell(t, s, c)
    local d = copyCell(c)
    d.cell = t .. "," .. s
    if cells[t][s] then clearCell(t, s) end
    cells[t][s] = d
    saveGrid()
end

local function renameCell(t, s)
    local c = cells[t][s]
    if not c then return end
    local ok, v = r.GetUserInputs("Rename clip", 1, "Name:,extrawidth=180",
                                  c.name or "")
    if not ok then return end
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    c.name = (v ~= "") and v or nil
    saveGrid()
    -- the label cache is keyed on the old text
    cell_lbl[t * SCENES + s] = nil
end

-- The clip's colour is an index into the Engine's palette, so the cell, the
-- editor and anything else that ever shows this clip agree without agreeing
-- on anything. nil = none, which means "the theme's own ground", not black.
local function setCellColor(t, s, i)
    local c = cells[t][s]
    if not c then return end
    c.color = (i and i > 0) and i or nil
    saveGrid()
end

local function cellMenu(t, s)
    local c = cells[t][s]
    local has = c ~= nil
    local cur_col = has and c.color or nil
    local cols = {}
    for i = 1, #Clip.COLOR_NAMES do
        cols[i] = { label = Clip.COLOR_NAMES[i], checked = (cur_col == i),
                    action = function() setCellColor(t, s, i) end }
    end
    cols[#cols + 1] = { separator = true }
    cols[#cols + 1] = { label = "None", checked = (cur_col == nil),
                        action = function() setCellColor(t, s, nil) end }
    UI.NativeMenu({
        { label = "Edit in CP_Editor", action = function() editCell(t, s) end },
        { label = "Rename clip…", disabled = not has,
          action = function() renameCell(t, s) end },
        { label = "Color", disabled = not has, children = cols },
        { label = "Stop this track", action = function() stopTrack(t) end },
        { separator = true },
        { label = "Clear cell", disabled = not has,
          action = function() clearCell(t, s) end },
    })
end

loadGrid()

do
    local _, v = r.GetProjExtState(0, "CP_Session", "rec_bars")
    local n = tonumber(v)
    if n then
        for i = 1, #REC_BARS do
            if REC_BARS[i] == n then rec_bars = n break end
        end
    end
end

-- Migration: the old fixed "A" row (four sound slots under the grid) is
-- gone — a sound is a cell like any other now. Whatever was in it moves
-- into the first free scene of the matching column, once.
for i = 1, 4 do
    local _, p = r.GetProjExtState(0, "CP_Session", "audio" .. i)
    if p and p ~= "" then
        local t = i - 1
        if t < TRACKS then
            for s = 0, SCENES - 1 do
                if not cells[t][s] then
                    local c = Clip.new("audio")
                    c.path = p
                    c.name = p:match("([^/\\]+)$") or p
                    cells[t][s] = c
                    break
                end
            end
        end
        r.SetProjExtState(0, "CP_Session", "audio" .. i, "")
    end
end

-- ---------------------------------------------------------------------------
-- DragBus: a drop on a cell FILLS that cell — a sound or a MIDI clip, the
-- two are interchangeable. Dropping never launches; that is the button's job.
-- ---------------------------------------------------------------------------
local function busConsume()
    if not state.registered then
        state.registered = DragBus.Register("session")
    end
    DragBus.RectSync("session")
    local clip, sx, sy = Bus.TakeDrop("session")
    if not clip then return end
    local g = state.grid
    if not g then return end
    local cx, cy = Core.ScreenToClient(sx, sy)
    if cx < g.x0 or cy < g.y0 then return end
    local t = floor((cx - g.x0) / (g.cw + g.gap))
    local s = floor((cy - g.y0) / (g.ch + g.gap))
    if t < 0 or t >= TRACKS or s < 0 or s >= SCENES then return end
    if not ((clip.kind == "audio" and clip.path)
            or (clip.kind == "midi" and clip.notes)) then
        return
    end
    if cur[t] == s then stopTrack(t) end   -- replacing what plays there
    clip.cell = t .. "," .. s
    cells[t][s] = clip
    saveGrid()
    flash((clip.kind == "audio" and "Sound -> " or "Clip -> ")
          .. trackName(t) .. " / scene " .. (s + 1))
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
-- Every cell carries its own transport button, the way a session view is
-- meant to be read: a triangle to launch, a square to stop what is playing,
-- a circle to capture into an empty slot of an armed track. Icons come from
-- the toolkit (baked at 4x, so antialiased like everything else) — never
-- raw gfx primitives.
local BTN_W = 16

-- How far a cell's ground is pulled toward the clip's own colour. See the
-- comment at the mix itself: identity has to be visible without taking the
-- channel that carries state.
local CLIP_TINT = 0.30

-- Countdown labels, precomputed. The waiting cell redraws every frame and a
-- tostring() there would mint one string per frame for nothing.
local CD_LBL = {}
for i = 1, 128 do CD_LBL[i] = tostring(i) end

local function drawCell(theme, t, s, x, y, w, h)
    local C = theme.colors
    local c = cells[t][s]
    local rad = theme.rounding_small or theme.rounding or 0
    local audio = isAudio(c)
    -- A cell reads ITS OWN lane, located by the tag the engine holds — not
    -- "the track's live lane". While a launch is queued those are two
    -- different clips, and reading the live one blinks the wrong cell.
    -- Nil means the engine is not holding this clip at all: stopped, and
    -- honestly so.
    local lane
    if c and not audio then
        lane = Loop.LaneOfTag(t, cellTag(t, s))
        if not lane and cur[t] == s and Loop.GetLaneTag(liveLane(t)) == 0 then
            -- Untagged engine state: loops recalled from a project saved
            -- before lanes carried their cell. Nothing claims that lane, so
            -- trusting the grid's own memory cannot point at someone else's
            -- clip — and it keeps a set recalled from an old project visible
            -- instead of showing a silent grid over audible loops.
            lane = liveLane(t)
        end
    end
    local mode = lane and floor(Loop.Mode(lane) + 0.5) or 0
    local pend = lane and Loop.Pending(lane) or 0
    local playing
    if audio then
        local a = aplay[t]
        -- armed but not started (the clock follows a stopped transport) is
        -- the same state a queued MIDI launch is in, and wears its colour
        playing = (a ~= nil and a.s == s and a.prev ~= nil)
        if a and a.s == s and not a.prev then pend = 1 end
    else
        playing = (mode == 3 or mode == 5)
    end
    -- A capture ARMS first and turns into a take on the quantize boundary.
    -- Painting both red made a recording that had not started look exactly
    -- like one that had — so a cell could blink for a whole bar, capture
    -- nothing, and give no clue why. They are told apart now.
    -- And the wait says WHAT it waits for: beats counting down to the boundary,
    -- or the transport when the clock follows one that is not running. "Am I
    -- going to start at the right moment" should be answerable by looking.
    local capturing, waiting, cd_beats, cd_play = false, false, nil, false
    local rec_lane = (rec and rec.t == t and rec.s == s) and rec.lane or nil
    if rec_lane then
        local rm = floor(Loop.Mode(rec_lane) + 0.5)
        capturing = (rm == 1)
        waiting   = not capturing
        if waiting then
            if Loop.Pending(rec_lane) == 3 then
                local d = Loop.PendingTarget(rec_lane) - Loop.EngineBeat()
                if d > 0 then cd_beats = d end
            elseif rm == 4 then
                cd_play = true            -- armed: the clock has to run first
            end
        end
    end

    -- A cell is a canvas surface, and its state is that surface MIXED toward
    -- the role colour — never a hand-typed grey nor an accent multiplied down.
    -- The mix keeps the cell readable at any theme brightness, and the role
    -- (play / record / pending) stays the theme's to redefine.
    local base = c and C.canvas_row or C.canvas_row_dark
    local br, bg_, bb = base[1], base[2], base[3]
    -- The clip's own colour, mixed GENTLY into that ground. Gently on purpose:
    -- in this suite hue is the STATE channel (play, record, pending), and a
    -- cell painted at full saturation would spend it on identity, leaving the
    -- state nothing to speak with. At this strength eight clips are still told
    -- apart at a glance, and a playing one still reads as playing — helped by
    -- the two carriers state has besides the ground: the lit edge and the
    -- button's own glyph.
    local kr, kg, kb = Clip.ColorOf(c)
    if kr then
        br  = br  + (kr - br)  * CLIP_TINT
        bg_ = bg_ + (kg - bg_) * CLIP_TINT
        bb  = bb  + (kb - bb)  * CLIP_TINT
    end
    local role, k
    if capturing then role, k = C.record, 0.42
    elseif waiting then role, k = C.pending, 0.30
    elseif playing then role, k = C.play, 0.34 end
    if role then
        br = br + (role[1] - br) * k
        bg_ = bg_ + (role[2] - bg_) * k
        bb = bb + (role[3] - bb) * k
    end
    Core.DrawRoundRectFilled(x, y, w, h, rad, br, bg_, bb, 1)
    -- and a real edge, so a cell is an object on the grid rather than a
    -- slightly different shade of it
    local ec = C.border
    Core.DrawRect(x, y, w, h, ec[1], ec[2], ec[3], (ec[4] or 1) * 0.9, false)

    -- The transport button owns its own strip on the left. Clicking the REST
    -- of the cell opens it in CP_Editor — editing must never cost a play
    -- state, and launching must never be a side effect of wanting to look
    -- at the notes.
    local bw = BTN_W + 6
    local bx, by = x + 3, y + floor((h - BTN_W) / 2)
    local tc = C.text
    local mc = C.text_mute or C.text_disabled
    local btn_hot = Core.MouseInRect(x, y, bw, h) and not Core.HasPopup()
    if btn_hot then
        Core.DrawRoundRectFilled(x + 1, y + 1, bw - 1, h - 2,
                                 theme.rounding_small or 0, 1, 1, 1, 0.10)
    end
    local lit = playing or capturing or waiting or pend == 1
    if capturing or waiting then
        -- waiting blinks slower and dimmer than a take in progress: the button
        -- says "counting to the boundary", not "your playing is being kept"
        local a = 0.5 + 0.5 * math.abs(sin(r.time_precise() * (capturing and 5 or 2)))
        local d = C.danger or C.accent
        UI.Icons.Record(bx, by, BTN_W, d[1], d[2], d[3], capturing and a or a * 0.6)
        UI.RequestRedraw()
    elseif c then
        if playing or pend == 1 then
            UI.Icons.Stop(bx, by, BTN_W, tc[1], tc[2], tc[3], 1)
        else
            UI.Icons.Play(bx, by, BTN_W, tc[1], tc[2], tc[3],
                          btn_hot and 1 or 0.7)
        end
    elseif isArmed(t) then
        -- empty slot on the armed track: this is where a take lands
        local d = C.danger or C.accent
        UI.Icons.Record(bx, by, BTN_W, d[1], d[2], d[3], btn_hot and 0.9 or 0.5)
    end
    -- the lit state reads as a lit button, not only as a coloured cell
    if lit and not capturing then
        Core.DrawRect(x + 1, y + 1, 2, h - 2, C.accent[1], C.accent[2], C.accent[3], 0.9)
    end

    if c then
        -- queued launch / stop blinks, exactly as in the Looper
        if pend == 1 or pend == 2 then
            local a = 0.45 + 0.55 * math.abs(sin(r.time_precise() * 5))
            local pc = (pend == 2) and C.text or C.accent
            Core.DrawRect(x, y, w, h, pc[1], pc[2], pc[3], a, false)
            UI.RequestRedraw()
        end
        if playing then
            local a = C.accent
            local prog
            if audio then
                local ap = aplay[t]
                local ok, rv, pos = pcall(r.CF_Preview_GetValue, ap.prev, "D_POSITION")
                local ok2, rv2, len = pcall(r.CF_Preview_GetValue, ap.prev, "D_LENGTH")
                if ok and rv and ok2 and rv2 and len and len > 0 then
                    prog = (pos % len) / len
                end
            elseif lane then
                local L = Loop.LenBeats(lane)
                if L > 0 then prog = Loop.Phase(lane) / L end
            end
            if prog then
                Core.DrawRect(x + 2, y + h - 4, (w - 4) * prog, 2,
                              a[1], a[2], a[3], 0.9)
            end
            UI.RequestRedraw()
        end
        local nm = (c.name and c.name ~= "") and c.name or "clip"
        local tw = w - bw - 6
        Core.DrawText(cellLabel(t, s, nm, tw), x + bw + 2, y + 3,
                      tc[1], tc[2], tc[3], 0.95)
        UI.SetFontCaption()
        Core.DrawText(audio and "audio" or barsLabel(cellBars(c)),
                      x + bw + 2, y + h - 13, mc[1], mc[2], mc[3], 0.85)
        UI.SetFontBody()
    end

    -- What the queued take is waiting for, in the cell's own body.
    if capturing or waiting then
        local d = C.danger or C.accent
        local head, sub
        if cd_beats then
            -- beats remaining, rounded UP: it reads 4, 3, 2, 1 and the take
            -- starts as it would have said 0
            local n = floor(cd_beats) + 1
            if n < 1 then n = 1 elseif n > 128 then n = 128 end
            head = CD_LBL[n]
            sub  = "beats to go"
        elseif cd_play then
            head, sub = "PLAY", "waiting for the transport"
        elseif capturing then
            head, sub = "REC", barsLabel(Loop.GetLengthBars(rec_lane))
        else
            head, sub = "REC", "queued"
        end
        Core.DrawText(head, x + bw + 3, y + 3, d[1], d[2], d[3], 0.95)
        UI.SetFontCaption()
        Core.DrawText(sub, x + bw + 3, y + h - 13, d[1], d[2], d[3], 0.7)
        UI.SetFontBody()
        -- how much of the take is already in — the same strip a playing clip
        -- uses, so "is it running" reads the same way whatever the cell is doing
        if capturing then
            local L = Loop.LenBeats(rec_lane)
            if L > 0 then
                local p = Loop.Phase(rec_lane) / L
                if p > 0 then
                    Core.DrawRect(x + 2, y + h - 4, (w - 4) * p, 2,
                                  d[1], d[2], d[3], 0.9)
                end
            end
        end
    end

    -- Ctrl-drag copy: the cell being dragged FROM stays lit, the one under the
    -- cursor shows where it would land.
    if cdrag then
        if cdrag.t == t and cdrag.s == s then
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.5, false)
        elseif Core.MouseInRect(x, y, w, h) then
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.18)
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.9, false)
        end
    end

    if Core.MouseInRect(x, y, w, h) and not Core.HasPopup() then
        -- Alt+click deletes, anywhere on the cell. It is destructive but
        -- unambiguous, and the modifier keeps it out of the way of the two
        -- plain clicks (launch on the strip, edit on the content).
        if Core.ModAlt() and Core.MouseClicked(1) then
            clearCell(t, s)
        elseif Core.ModCtrl() and c and Core.MouseClicked(1) then
            cdrag = { t = t, s = s }
        elseif btn_hot then
            -- transport strip
            if Core.MouseClicked(1) then
                if capturing or waiting then
                    stopRec()
                elseif c then
                    launchCell(t, s)
                elseif isArmed(t) then
                    recCell(t, s)
                else
                    flash("Arm this track (circle in its header) to record here")
                end
            elseif Core.MouseClicked(2) then
                cellMenu(t, s)
            end
        else
            -- content: opening it must not touch what is playing
            Core.DrawRect(x + bw, y, w - bw, h, 1, 1, 1, 0.05)
            if Core.MouseClicked(1) then
                editCell(t, s)
            elseif Core.MouseClicked(2) then
                cellMenu(t, s)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The mixer strip
--
-- Three controls per column and the meter that makes them readable. Not a
-- console: what a session needs is to balance what it is launching, and
-- everything else is one keystroke away in REAPER's own mixer, which is better
-- than anything we would draw here.
--
-- A column mixes the track it is ROUTED TO — the same track its clips play
-- into, so this is also the level of whatever CP_Sampler or CP_Editor sends
-- there. A column with no destination has nothing to mix and says so by being
-- disabled, not by showing a fader that quietly does nothing.
-- ---------------------------------------------------------------------------
local MIX_H     = 18       -- control height
local MIX_PAD   = 4        -- so the zone is 26 px: the rhythm of a command bar
local MIX_BTN   = 18
local MIX_MET   = 7
local MIX_GAP   = 3
local MIX_MIN_F = 24       -- below this a fader is a decoration, not a control
local MIX_ZONE  = 2 + MIX_PAD * 2 + MIX_H   -- seam + ground

local mix_open  = Core.LoadPersistent("CP_Session", "mix", true)
local mix_moved = false    -- did the fader gesture in flight change anything
local mix_hot   = false    -- is any meter still above zero (so still falling)

-- Ids are identity, and identity must not be rebuilt every frame.
local mix_id = { v = {}, m = {}, s = {} }
for t = 0, TRACKS - 1 do
    mix_id.v[t] = "mixv" .. t
    mix_id.m[t] = "mixm" .. t
    mix_id.s[t] = "mixs" .. t
end

-- Shared option tables: every field is written on every call, so nothing
-- stale survives — and no table is built in a draw path.
local MIX_F_OPTS = { mark = Mix.UNITY, default = Mix.UNITY, text = nil,
                     disabled = false, accent = nil }
local MIX_M_OPTS = { accent = nil, tip = "Mute this column's track" }
local MIX_S_OPTS = { accent = nil,
    tip = "Solo — REAPER's solo, so the arrangement goes quiet too. Ctrl: exclusive" }

local function drawMix(theme, t, x, y, w)
    local C = theme.colors
    local tr = Loop.GetLaneDest(t)
    local live = Mix.Valid(tr)

    -- Widths, dropped from the right as the column narrows: a control that no
    -- longer fits is simply not placed, exactly as in a command bar.
    local bw = MIX_BTN * 2 + 1
    local fx = x + bw + MIX_GAP
    local fw = w - bw - MIX_GAP
    local mx
    if fw - MIX_MET - MIX_GAP >= MIX_MIN_F then
        fw = fw - MIX_MET - MIX_GAP
        mx = x + w - MIX_MET
    end
    if fw < MIX_MIN_F then fw = 0 end

    -- M and S. Letters, not glyphs: they are a PAIR, and the two universal
    -- letters of every console read at 18 px where two different picture
    -- families would only read as two different things.
    -- The colour is the point — `mute` and `solo` have been sitting in the
    -- theme since the palette work with nobody reading them.
    MIX_M_OPTS.accent = C.mute
    MIX_S_OPTS.accent = C.solo
    local muted = live and Mix.IsMute(tr)
    if UI.ChipAt(mix_id.m[t], x, y, MIX_BTN, MIX_H, nil, "M", muted, not live,
                 MIX_M_OPTS) then
        Mix.SetMute(tr, not muted)
    end
    local soloed = live and Mix.IsSolo(tr)
    if UI.ChipAt(mix_id.s[t], x + MIX_BTN + 1, y, MIX_BTN, MIX_H, nil, "S",
                 soloed, not live, MIX_S_OPTS) then
        Mix.SetSolo(tr, not soloed, Core.ModCtrl())
    end

    if fw > 0 then
        local n = Mix.GetNorm(tr)
        MIX_F_OPTS.text = live and Mix.DbLabel(t, n) or nil
        MIX_F_OPTS.disabled = not live
        -- A column can be silent for two reasons, and the second one is not
        -- on this column: its own mute, or somebody else's solo. The level
        -- wears the mute colour either way, so "which of these do I actually
        -- hear" is one glance rather than an audit of four buttons.
        MIX_F_OPTS.accent = (live and (muted or (Mix.AnySolo() and not soloed)))
                            and C.mute or nil
        local ch, nv, rel = UI.FaderAt(mix_id.v[t], fx, y, fw, MIX_H, n,
                                       MIX_F_OPTS)
        if ch then
            Mix.SetNorm(tr, nv)
            mix_moved = true
        end
        -- One undo point per gesture, and only if the gesture did something:
        -- a click that moved nothing should not enter the history.
        if rel then
            if mix_moved and live then Mix.CommitVol() end
            mix_moved = false
        end
    end

    if mx then
        if live then
            local ml, mr, hl, hr = Mix.Meter(t, tr)
            -- A meter still above zero is a meter still FALLING, and it needs
            -- frames to fall in. Without this the strip freezes lit the moment
            -- the transport stops, which reads as "still playing".
            if ml > 0 or mr > 0 or hl > 0 or hr > 0 then mix_hot = true end
            UI.MeterAt(mx, y, MIX_MET, MIX_H, ml, mr, true, hl, hr)
        else
            -- Unrouted: clear rather than fade, so nothing is left showing a
            -- level from a track this column no longer plays into.
            Mix.ResetMeter(t)
            UI.MeterAt(mx, y, MIX_MET, MIX_H, 0, 0, true)
        end
    end
end

local function frame(theme)
    local C = theme.colors
    if not (Loop.track and r.ValidatePtr2(0, Loop.track, "MediaTrack*")) then
        Loop.reconnect()
    end
    local attached = Loop.IsAttached()

    -- one-shot recall: if this window comes up first in the REAPER session
    -- and the engine is empty, pull the project's saved set (the Looper
    -- does the same; the recall never overwrites a live set)
    if attached and not state.recalled then
        state.recalled = true
        local empty = true
        for l = 0, Loop.MAX_LANES - 1 do
            if Loop.HasContent(l) then empty = false break end
        end
        if empty and Loop.HasSavedState() then Loop.LoadState(false) end
    end

    -- COMMAND ZONE. Same shape, same height, same right-hand rank as every
    -- other CP window: the point of a primitive is that this stops being a
    -- decision each app makes on its own.
    UI.BeginBar("cmd", TITLE_OPTS)
    UI.BarRight()
    if UI.BarIcon("help", "Help", "Help") then UI.ShowHelp("help", HELP_TEXT) end
    UI.BarSep()
    -- A view toggle, so it sits with the meta controls at the right end. The
    -- strip costs 28 px of height permanently, which on a short window is the
    -- last row of the grid: showing it has to stay a choice.
    if UI.BarToggle("mix", "Sliders", nil, mix_open,
                    "Mixer strip: volume, mute and solo per column") then
        mix_open = not mix_open
        Core.SavePersistent("CP_Session", "mix", mix_open)
    end
    UI.BarLeft()
    if attached then
        local free = Loop.GetFreeRun()
        if UI.BarToggle("clock", "Clock", nil, free,
                        free and "Free run: clips launch with the transport stopped"
                              or "Follow the host transport") then
            Loop.SetFreeRun(not free)
        end
        -- Q says WHEN a take starts, Rec says how long it runs. Together they
        -- are the whole answer to "will it start where I mean it to". Both are
        -- choices among a handful, so both are combos: the wheel walks them and
        -- the current setting is readable without clicking.
        local qch, qi = UI.BarCombo("q", qIndex(), Q_ITEMS, false, Q_OPTS)
        if qch then setQIndex(qi) end
        local rch, ri = UI.BarCombo("recbars", recBarsIndex(), REC_ITEMS, false, Q_OPTS)
        if rch then setRecBarsIndex(ri) end
        UI.BarSep()
        if UI.BarIcon("stopall", "Stop", "Stop every clip") then stopAll() end
        if UI.BarIcon("panic", "Mute", "Panic: all notes off") then Loop.Panic() end
    end
    UI.EndBar()
    UI.Spacing(4)

    -- This window IS the engine's front end — a grid with no engine can do
    -- nothing at all — so opening it IS the request. It builds the router
    -- itself, once, instead of sending the user to a third script for a step
    -- that holds no decision. The button below stays for the case where that
    -- failed.
    if not attached then
        if not state.engine_tried then
            state.engine_tried = true
            local _, note = Loop.Ensure(true)
            if note then flash(note) end
            attached = Loop.IsAttached()
        end
        if not attached then
            UI.SetFontCaption()
            UI.TextWrapped("No looper engine in this project, and it could not be created.")
            UI.SetFontBody()
            UI.Spacing(2)
            if UI.Button("mkengine", "Create looper engine") then
                state.engine_tried = false
            end
            return
        end
    end

    -- An engine loaded before the lanes grew DROPS every command aimed at the
    -- upper half — a clip swap would stop the outgoing clip and never start
    -- the incoming one, which looks exactly like "the column stops". Ensure
    -- refreshes it; the loops live in gmem and survive the swap.
    -- Once per window, never on a retry loop: if the refresh did not take,
    -- reloading the engine on every frame would be far worse than the banner
    -- below, which says so plainly and leaves the user in charge.
    if not state.engine_checked then
        state.engine_checked = true
        local _, note = Loop.Ensure(false)
        if note then flash(note) end
    end
    if not Loop.EngineCurrent() then
        UI.SetFontCaption()
        UI.TextWrapped("This project's looper engine is out of date and it would not refresh — open CP_Looper and click \"Reload engine\".")
        UI.SetFontBody()
        UI.Spacing(2)
    end

    -- one call: gmem re-selected, one queued command out, live halves
    -- re-derived. Everything below reads a coherent picture.
    Loop.Poll()
    -- Follow the engine rather than argue with it: a launch fired from
    -- CP_Looper or CP_Editor moves what a track plays, and the grid has to
    -- know. (Sound cells are this window's own business — skip those.)
    for t = 0, TRACKS - 1 do
        if not aplay[t] then
            local s = sceneOfLane(liveLane(t), t)
            if s and s ~= cur[t] then cur[t] = s end
        end
    end
    pollRec()
    pollAudio()

    -- edits coming home from CP_Editor (own channel: see the editor's
    -- flushApply — a shared one would let CP_Looper consume our cells)
    local ac = Bus.Recv("editor:apply:cell")
    if ac then applyEdit(ac) end

    -- drops from the Media Explorer / other CP windows
    busConsume()

    -- ---- geometry
    local x, y = UI.GetCursorPos()
    local w = UI.GetAvailableWidth()
    local gap = 3
    local scene_w = 24
    local head_h = 18
    local cell_w = floor((w - scene_w - gap * TRACKS) / TRACKS)
    local cell_h = 30

    -- ---- track headers: name + record arm (the engine monitors ONE track
    -- at a time, so arming is exclusive — clicking the lit one disarms)
    UI.SetFontCaption()
    for t = 0, TRACKS - 1 do
        local cx = x + scene_w + gap + t * (cell_w + gap)
        local mc = C.text_mute or C.text_disabled
        local routed = Loop.GetLaneDest(t) ~= nil
        Core.DrawText(cellLabel(t, SCENES, trackName(t), cell_w - 22), cx + 2, y + 2,
                      mc[1], mc[2], mc[3], routed and 0.9 or 0.45)
        local ax = cx + cell_w - 16
        local armed = isArmed(t)
        local d = C.danger or C.accent
        if armed then
            UI.Icons.Record(ax, y + 1, 14, d[1], d[2], d[3], 0.95)
        else
            UI.Icons.Record(ax, y + 1, 14, mc[1], mc[2], mc[3], 0.4)
        end
        if Core.MouseInRect(ax - 2, y, 18, head_h) and not Core.HasPopup()
           and Core.MouseClicked(1) then
            armTrack(t)
        end
        -- the name itself opens the routing: which track this column plays
        -- into should never be a mystery
        if Core.MouseInRect(cx, y, cell_w - 20, head_h) and not Core.HasPopup() then
            Core.DrawRect(cx, y, cell_w - 20, head_h, 1, 1, 1, 0.05)
            if Core.MouseClicked(1) or Core.MouseClicked(2) then trackMenu(t) end
        end
    end
    UI.SetFontBody()

    local gy = y + head_h
    state.grid = state.grid or {}
    state.grid.x0, state.grid.y0 = x + scene_w + gap, gy
    state.grid.cw, state.grid.ch, state.grid.gap = cell_w, cell_h, gap

    -- ---- scene launchers + cells
    for s = 0, SCENES - 1 do
        local cy = gy + s * (cell_h + gap)
        Core.DrawRoundRectFilled(x, cy, scene_w, cell_h,
                                 theme.rounding_small or 0, 0.17, 0.19, 0.17, 1)
        local a = C.accent
        UI.Icons.Play(x + 5, cy + floor((cell_h - 14) / 2), 14,
                      a[1], a[2], a[3], 0.85)
        if Core.MouseInRect(x, cy, scene_w, cell_h) and not Core.HasPopup() then
            Core.DrawRect(x, cy, scene_w, cell_h, 1, 1, 1, 0.06)
            if Core.MouseClicked(1) then sceneLaunch(s) end
        end
        for t = 0, TRACKS - 1 do
            local cx = x + scene_w + gap + t * (cell_w + gap)
            drawCell(theme, t, s, cx, cy, cell_w, cell_h)
        end
    end

    -- Ctrl-drag copy lands here: the grid geometry is known, so the target is
    -- read straight off the cursor. Releasing anywhere else just drops it.
    if cdrag and not Core.MouseDown(1) then
        local src = cells[cdrag.t] and cells[cdrag.t][cdrag.s]
        local mx, my = Core.GetMousePos()
        local dt = floor((mx - (x + scene_w + gap)) / (cell_w + gap))
        local ds = floor((my - gy) / (cell_h + gap))
        if src and dt >= 0 and dt < TRACKS and ds >= 0 and ds < SCENES
           and not (dt == cdrag.t and ds == cdrag.s) then
            pasteCell(dt, ds, src)
            flash("Copied to " .. trackName(dt) .. " / scene " .. (ds + 1))
        end
        cdrag = nil
    end

    -- ---- stop row: one square per track, plus the global one on the left
    -- (Ableton's "Stop Clips" footer — a big target, not a corner pixel)
    local sy = gy + SCENES * (cell_h + gap) + 2
    local sh = 16
    do
        local mc = C.text_mute or C.text_disabled
        Core.DrawRoundRectFilled(x, sy, scene_w, sh, theme.rounding_small or 0,
                                 0.17, 0.17, 0.19, 1)
        UI.Icons.Stop(x + 5, sy + 1, 14, mc[1], mc[2], mc[3], 0.8)
        if Core.MouseInRect(x, sy, scene_w, sh) and not Core.HasPopup() then
            Core.DrawRect(x, sy, scene_w, sh, 1, 1, 1, 0.06)
            if Core.MouseClicked(1) then stopAll() end
        end
        for t = 0, TRACKS - 1 do
            local cx = x + scene_w + gap + t * (cell_w + gap)
            local running = isRunning(liveLane(t))
            Core.DrawRoundRectFilled(cx, sy, cell_w, sh, theme.rounding_small or 0,
                                     0.17, 0.17, 0.19, 1)
            UI.Icons.Stop(cx + floor(cell_w / 2) - 7, sy + 1, 14,
                          mc[1], mc[2], mc[3], running and 0.9 or 0.35)
            if Core.MouseInRect(cx, sy, cell_w, sh) and not Core.HasPopup() then
                Core.DrawRect(cx, sy, cell_w, sh, 1, 1, 1, 0.06)
                if Core.MouseClicked(1) then stopTrack(t) end
            end
        end
    end

    -- ---- mixer zone. Its own ground and its own seam: it is not the grid,
    -- and a zone that shares its neighbour's ground is not a zone.
    local mix_h = 0
    mix_hot = false
    if mix_open then
        mix_h = MIX_ZONE
        local my = sy + sh + 4
        local win_w = Core.GetWindowSize()
        local surf = C.surface or C.frame_bg
        UI.SeamH(0, my, win_w)
        local zy = my + 2
        Core.DrawRect(0, zy, win_w, MIX_PAD * 2 + MIX_H, surf[1], surf[2], surf[3], 1)
        UI.SetFontCaption()
        for t = 0, TRACKS - 1 do
            local cx = x + scene_w + gap + t * (cell_w + gap)
            drawMix(theme, t, cx, zy + MIX_PAD, cell_w)
        end
        UI.SetFontBody()
    end

    UI.Layout.AdvanceCursor(w, head_h + SCENES * (cell_h + gap) + 2 + sh + 4 + mix_h)

    -- status zone
    local msg
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            msg = state.flash_msg
        else
            state.flash_msg = ""
        end
    end
    if not msg then msg = statusLine() end
    UI.AppStatus(msg)

    -- A meter that only moves when the mouse does is worse than no meter, so
    -- the strip asks for frames of its own whenever anything can be making
    -- sound — the engine, the transport, or a sound cell (which plays through
    -- CF_Preview and needs neither of the other two).
    local audio_on = false
    for t = 0, TRACKS - 1 do
        if aplay[t] then audio_on = true break end
    end
    if Loop.Playing() or mix_hot or audio_on then
        UI.RequestRedraw()
    elseif mix_open and (r.GetPlayState() & 1) == 1 then
        UI.RequestRedraw()
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("CP Session", 580, 400, {
    persist    = "CP_Session",
    scrollable = false,
})

UI.OnClose(function()
    for t = 0, TRACKS - 1 do audioStop(t) end
    if state.registered then pcall(DragBus.Unregister, "session") end
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
