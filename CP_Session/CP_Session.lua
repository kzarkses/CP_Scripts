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
-- for its tempo-match routine ONLY: the browser decides how fast a file is,
-- and this grid must reach the same answer for the same file. Its playback
-- half is never used here (sound cells own their previews).
local Preview = dofile(cp_root .. "CP_Engine/Preview.lua")
Tracks.init(r)
Loop.init(r, Tracks)
Mix.init(r)
DragBus.init(r)
Bus.init(r, DragBus, Clip)
Preview.init(r)

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
-- Geometry of each mixer strip as it was last drawn. Declared up here because
-- the drop consumer runs before the strips do: what lands on a strip has to be
-- resolved against where that strip WAS, which is the only place it can be.
local mix_col = {}   -- [t] = { x, y, w, h, fx_y, fx_rows }
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
loops TEMPO-MATCHED through that column's track. Drop or write MIDI
and it plays through the engine.

## How a sound follows the tempo — right-click, Tempo
REPITCH is the default and it is the one that is IN TIME. The file is
read faster or slower, which moves its pitch with it, exactly as every
hardware sampler and every tracker has always done. Nothing is
buffered, so the first sample comes out on the beat.

STRETCH keeps the key. It runs the sound through REAPER's time
stretcher, and a stretcher cannot emit anything until it has filled its
analysis window: the sound is LATE by that window — a fixed few tens of
milliseconds — and no API reports it, so this window cannot correct for
it. Use it where the key matters more than the grid.

DON'T FOLLOW plays the file at its own tempo.

## The launch probe (the pulse icon, top right)
It logs every sound launch to REAPER's console: the boundary it was
given, both clocks as they read at that instant, every term of the
offset applied, and — one frame later and ten frames later — the START
ERROR: how far the preview's own read head is from where it must be to
be exactly in time. Signed, positive for a sound running ahead.

An error near zero means the launch is exact and anything still heard
late is DOWNSTREAM of this window: REAPER's mixing, the driver, or the
way the measurement itself is recorded. The line also prints REAPER's
own idea of its output latency (GetPlayPosition2 minus GetPlayPosition)
beside what the driver claims, which is where "everything is late by a
constant" usually comes from.

To tell a late LAUNCH from a late MEASUREMENT with no code at all: put
the same file as an ordinary item on the bar line, record what you
hear, and look at where THAT lands. Whatever it is off by is your
recording path, not this window. The difference between the two is
ours.

A sound plays THROUGH the column's track — its fader, its FX, and so
into the master and into anything you record. When that track holds an
instrument it cannot take audio (a synth replaces its input with its
own output), so the sound goes to the nearest thing downstream that
can: the folder it lives in, or the master.

That track is then marked LIVE (its performance options: no anticipative
FX, no media buffering) and stays marked. It has to be: REAPER normally
renders a track ahead of the play cursor and keeps the result in a
buffer, which is right for items — they carry their timeline position
with them — and wrong for a sound mixed in as it plays, which would come
out however far ahead REAPER had got. It is the same treatment REAPER
already gives a record-armed track, and the reason MIDI was never out of
time: the engine lives on one.

A sound answers a click exactly as a clip does, because it lives in the
same two halves: launching is QUEUED to the Q boundary and blinks until
it lands, STOPPING is queued too (a clip finishes its bar, it does not
stop under your finger), swapping one sound for another happens on ONE
boundary with no gap, and clicking again takes back whatever is still
only queued. A track plays ONE thing at a time whichever kind, so a
sound leaves on the boundary the MIDI arrives on, and the other way
round. With Clock: Follow and the transport stopped, a sound is ARMED
and waits for the transport, as everything else does.
(Sounds use the interim preview engine; the sample-locked one comes
later — one visible seam is left: after the transport stops and rolls
again, a sound restarts from its beginning where a clip resumes in
phase with the beat.)

## The mixer
The zone under the grid (toggle it beside the "?") is a channel strip
per column, acting on the track that column is routed to — so it is
also the level of whatever CP_Sampler or CP_Editor sends there.

DRAG ITS SEAM (the three dots) to say how tall you want it. The two
lists take exactly what they hold and never more than half the strip;
the FADER TAKES EVERYTHING ELSE, so a taller zone is mostly a taller
fader — which is what a console is.

Fader, meter, pan, M and S: Shift for fine, double-click for 0 dB (or
centre), wheel to step. Solo is REAPER's solo — the arrangement goes
quiet too, exactly as in Ableton. Ctrl-click it for exclusive.

FX CHAIN. Click a plugin to open it, Ctrl-click to bypass, Alt-click
to remove, right-click for all three. DRAG one to reorder it, or onto
another column to MOVE it there (Ctrl: copy). An FX dragged from the
Media Explorer lands in the strip you drop it on. Clicking an EMPTY
SLOT selects that column's track and opens REAPER's FX browser, so
what you pick lands in the slot you clicked; right-click it for
CP_FX Browser or the track's own chain. When the chain is longer than
the slots on screen, the thin bar on the right says so and the wheel
walks it.

SENDS. Each row is the send itself: DRAG it to set its level, CLICK it
to open REAPER's routing window (pre/post, channels, MIDI), right-
click to mute or remove it. To create one, drag an EMPTY SLOT onto the
column you want to send TO — the gesture says from here to there.
Clicking an empty slot instead lists the destinations.

## Clock, and what a launch waits for
The button says WHO OWNS THE CLOCK. Lit = FOLLOW: REAPER's transport,
which locks to an external MIDI clock when REAPER is slaved. Unlit =
FREE: the session runs on its own.

One rule, both clocks, and the whole of it:

STARTING needs a downbeat. Following a transport that is not running
there is none yet, so a launch WAITS FOR THE TRANSPORT — the cell says
so. The moment it rolls, the wait becomes an ordinary one: the launch
takes the next Q boundary from wherever the transport started. Press
play on a bar line with Q: Bar and it goes now; press it between two
bars and it waits for the next one, because that is what Q: Bar says.
Clips, sounds and takes all wait together, and all land together.

STOPPING needs no downbeat. On a running clock a clip finishes its bar;
with no clock there is nothing left to finish, so it stops now.

FREE RUN is the session's own transport, and it SITS STILL while the
session is silent. So the first thing you launch starts at once and is
itself the downbeat — a quantize is an agreement between clips, and it
costs nothing when there is no one to agree with. Everything launched
after it lands on the Q, against what is already playing.

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
-- A sound cell lives in the SAME two states a MIDI clip does, because a track
-- has the same two halves whatever it plays: one sounding, one waiting for the
-- boundary. aplay is the live half, aqueue the twin — and every gesture below
-- is written against that pair so a sound answers a click exactly as a clip
-- does: launches queued, stops queued, swaps landing on one boundary, and a
-- second click taking back whichever of the two is still only queued.
-- BOTH halves own real resources now: a waiting sound has its FILE open as
-- soon as it is armed, not when it fires (see audioOpen). So freeing is one
-- routine, and a cancelled launch frees exactly as a stopped one does.
local aplay  = {}  -- [t] = { s,c,at,prev,src,rt,slen,pdc,stop_at,t0,locked }
local aqueue = {}  -- [t] = { s,c,at, + the same, prepared but not playing }

local function freeAudio(a)
    if not a then return end
    if a.prev then pcall(r.CF_Preview_Stop, a.prev) end
    if a.src then r.PCM_Source_Destroy(a.src) end
    a.prev, a.src = nil, nil
end

local function audioStop(t)
    freeAudio(aplay[t])
    aplay[t] = nil
end

local function audioCancel(t)
    freeAudio(aqueue[t])
    aqueue[t] = nil
end

-- Give the preview back without forgetting the cell: what the transport took
-- away it can give back. Used when the clock follows a transport that stopped.
local function audioRelease(a)
    if not a then return end
    freeAudio(a)
    a.at, a.stop_at = nil, nil
end

-- What a display frame currently costs, averaged. Maintained by frameLead
-- further down; needed this early because the quantize tolerance is measured
-- in frames and the probe reports it.
local frame_s = 0.033

-- WHERE A LAUNCH LANDS, on the engine's own clock (host beat when following,
-- the free clock otherwise). This is the JSFX's rule, copied on purpose: a
-- position just past a boundary counts as ON it, anything else waits for the
-- next one. A sound and a MIDI clip launched together must land together, and
-- they only do if they answer the same question the same way.
--
-- AND "JUST PAST" IS A FRAME, NOT A CONSTANT. This is where a launch loses a
-- whole bar rather than a few milliseconds. The transport starts on the bar
-- line and this loop hears about it up to one frame later; quantizing from a
-- beat that is already a frame past the line, against a fixed 0.05-beat
-- tolerance, sends the launch to the NEXT bar whenever a frame runs long. At
-- 112 BPM a 30 ms frame is 0.056 beat — just over the old constant, which is
-- exactly how "press play on the bar" became "wait one more bar" on a slow
-- frame and not on a fast one.
--
-- The tolerance is therefore the frame itself, floored at the old constant and
-- capped at a quarter of the quantize: a Q that forgives a third of its own
-- period is not a Q any more.
--
-- WHAT THIS IS NOT is a way of pretending the launch was on time. The boundary
-- it returns is the BAR — an absolute position on the grid, not "wherever I
-- happened to look" — so `elapsed` measures the real lateness against it and
-- the sound skips exactly that far into itself. Deciding the target and
-- measuring the error against it stay two different questions, which is the
-- whole reason this works.
--
-- The engine holds its free clock at ZERO while the session is silent, so the
-- first launch of a silent session reads pb = 0 here and lands on 0: it starts
-- now, in phase, and it is what starts the clock. Nothing special is needed
-- for that case — it falls out of asking the same question.
local Q_SLOP = 0.05

local function qSlop(q)
    local bpm = Loop.Tempo() or 0
    local s = (bpm > 1) and (frame_s * 1.5 * bpm / 60) or Q_SLOP
    if s < Q_SLOP then s = Q_SLOP end
    local cap = q * 0.25
    if s > cap then s = cap end
    return s
end

local function launchBeat()
    local pb = Loop.EngineBeat()
    local q = Loop.GetLaunchQ() or 0
    if q <= 0.001 then return pb end
    local qph = pb - floor(pb / q) * q
    if qph < qSlop(q) then return pb - qph end
    return pb - qph + q
end

-- WHERE THE SOUND COMES OUT. A column's own track when it can take audio —
-- its fader, its FX, its place in the mixer, and it lands in anything you
-- record. When it cannot, the sound must still reach the mixer rather than
-- leave by the back door: a track whose chain holds an INSTRUMENT swallows
-- audio put into it (a synth replaces its input with its own output), so the
-- preview goes to the nearest thing downstream that has no instrument — the
-- folder the track lives in, and the master as the last resort.
--
-- This is also why a sound could be out of time with everything else: a
-- preview sent straight to the hardware skips the whole output path the
-- project is aligned on.
local function previewDest(tr)
    if not tr or not r.TrackFX_GetInstrument then return tr end
    local ok, ins = pcall(r.TrackFX_GetInstrument, tr)
    if not (ok and ins and ins >= 0) then return tr end
    local par = r.GetParentTrack and r.GetParentTrack(tr) or nil
    local guard = 0
    while par and guard < 8 do
        local ok2, i2 = pcall(r.TrackFX_GetInstrument, par)
        if not (ok2 and i2 and i2 >= 0) then return par end
        par = r.GetParentTrack(par)
        guard = guard + 1
    end
    return r.GetMasterTrack and r.GetMasterTrack(0) or nil
end

-- A TRACK FED BY A PREVIEW IS A LIVE TRACK, and REAPER has to be told.
--
-- By default REAPER runs a track's FX AHEAD of the play cursor and keeps the
-- result in a buffer (anticipative processing, 200 ms by default) so a CPU
-- spike cannot cause a dropout. Items on that track are rendered at their
-- timeline position, so they come out on time. A preview is not: it is mixed
-- in at the moment the audio thread happens to be computing that track — which
-- is the position it will reach in 200 ms. The sound is therefore LATE by
-- whatever REAPER managed to render ahead.
--
-- Which is why the offset grew as the buffer SHRANK: 147 ms on a 3 ms ASIO
-- buffer, 67 ms on a 200 ms DirectSound one. Nothing downstream of the sound
-- can behave that way; only something that runs ahead of it can. And it is
-- exactly why MIDI was never affected — the engine lives on a record-armed,
-- input-monitored router track, and REAPER already runs those live.
--
-- I_PERFFLAGS is the per-track answer REAPER gives its own live tracks:
-- &1 no media buffering, &2 no anticipative FX. Set once, left set: a column
-- that plays sounds is a live column, and the flags are visible in the track's
-- own performance options if the user ever wants them back.
local PERF_LIVE = 3
local function liveTrack(tr)
    if not tr then return end
    local f = floor((r.GetMediaTrackInfo_Value(tr, "I_PERFFLAGS") or 0) + 0.5)
    if (f & PERF_LIVE) ~= PERF_LIVE then
        r.SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", f | PERF_LIVE)
    end
end

-- Half an audio block: the preview is picked up by the audio thread on its
-- NEXT block, so where it actually starts is somewhere in [now, now + block].
-- Read once — the device does not change under a running script.
-- A few milliseconds of fade at the start: SWS opens on a raw sample edge,
-- which clicks on anything that does not begin at zero — and it is also what
-- makes the one corrective seek of lockPhase inaudible.
local FADE_IN = 0.003

local block_s, srate_hz = nil, 48000
local function blockSlack()
    if block_s then return block_s end
    block_s = 0
    local ok, bs = r.GetAudioDeviceInfo("BSIZE", "")
    local ok2, sr = r.GetAudioDeviceInfo("SRATE", "")
    local b, s = tonumber(ok and bs or ""), tonumber(ok2 and sr or "")
    if s and s > 0 then srate_hz = s end
    if b and s and b > 0 and s > 0 then block_s = (b / s) * 0.5 end
    return block_s
end

-- The chain's own LATENCY, in seconds. REAPER compensates an item on a track
-- with plugin delay by rendering it that much earlier; a preview injected at
-- the track's input gets no such courtesy — it is simply late by the whole
-- chain, which is exactly how a sound stays out of time on a track that has
-- anything serious on it. We cannot feed it earlier, so we feed it FURTHER
-- IN: the sample handed over now is the one that must be heard after the
-- delay. Zero on a bare track, which is the common case.
local function chainLatency(tr)
    if not tr or not r.TrackFX_GetNamedConfigParm then return 0 end
    blockSlack()
    local n = r.TrackFX_GetCount(tr)
    local sum = 0
    for i = 0, n - 1 do
        local ok, rv, v = pcall(r.TrackFX_GetNamedConfigParm, tr, i, "pdc")
        if ok and rv then
            local s = tonumber(v)
            if s and s > 0 then sum = sum + s end
        end
    end
    local secs = sum / srate_hz
    if secs < 0 or secs > 0.5 then return 0 end
    return secs
end

-- HOW LONG the sound has been running, in seconds — the one question the
-- whole alignment rests on, and it has two answers because there are two
-- clocks. Both come from the AUDIO thread rather than from the frame we happen
-- to be drawing, which is what makes them usable at all:
--   * following the transport → the play position the audio thread is ABOUT
--     to render (GetPlayPosition2), measured from the time of the boundary.
--   * free-running → the engine's own beat, which the JSFX advances one audio
--     block at a time, measured from the beat of that boundary.
-- Nil when there is nothing to measure from yet.
local function elapsed(a)
    if a.t0 then
        local p = r.GetPlayPosition2()
        return p and (p - a.t0) or nil
    end
    if not a.at then return nil end
    local tempo = Loop.Tempo()
    if not tempo or tempo <= 1 then return nil end
    return (Loop.EngineBeat() - a.at) * (60 / tempo)
end

-- HOW FAST a sound must run to sit at the project's tempo, and whether that
-- rate is allowed to move its pitch. The clip's own announced tempo wins when
-- it carries one; otherwise the SAME routine the browser used to audition this
-- file decides. Two windows disagreeing about how fast a file is was one of the
-- ways a sound could be in time in the arrange and out of it here: the browser
-- falls back to the BPM written in the filename when REAPER's tempo-match
-- declines to guess, and this window did not.
--
-- One answer for the whole window: the launch asks it when it opens the file,
-- the cell menu asks it again when the mode changes under a sound that is
-- already playing. Costly (REAPER analyses the source), so it is asked once
-- per open and once per menu click, never per frame.
local function rateFor(c)
    local mode = c.tempo_mode or "repitch"
    if mode == "none" then return 1.0, false end
    local rt
    if c.src_bpm and c.src_bpm > 0 then
        local pb = r.Master_GetTempo()
        rt = (pb and pb > 0) and (pb / c.src_bpm) or 1.0
    else
        rt = Preview.TempoSyncRate(c.path, 1.0)
    end
    if not (rt and rt > 0.05 and rt < 20) then rt = 1.0 end
    return rt, (mode == "stretch")
end

-- OPEN THE FILE WHEN THE LAUNCH IS ARMED, NOT WHEN IT FIRES.
--
-- Two things here are slow, and neither of them is the launch: opening the WAV,
-- and asking REAPER for the tempo-match rate — which ANALYSES the source and is
-- the slower of the two. Both used to sit between "the boundary just passed"
-- and "the sound starts", so a launch cost however long they took.
--
-- Worse: the overshoot is measured after that work, so its cost was read as
-- musical time already elapsed and taken off the front of the sample —
-- multiplied by the playrate. That is why the offset GREW with the project
-- tempo (three measurements, 147/220/460 ms, all within a few percent of the
-- same number once divided by their rate) and why it was unstable: the price
-- of a disk read is not a constant.
--
-- What CANNOT be done in advance is the preview object itself: SWS reaps a
-- preview that was created and never started before the defer cycle ends (the
-- rule is written at the top of Engine/Preview). Made at arm time, it would be
-- dead by the boundary — and in Follow, where the wait is real, the sound
-- simply never came out. So: the SOURCE is opened early, the PREVIEW is built
-- and played in one tick. The expensive half is the half moved.
local function audioOpen(a)
    if not a or a.src or a.dead then return end
    local c = a.c
    local src = r.PCM_Source_CreateFromFile(c.path)
    if not src then
        a.dead = true
        flash("Cannot open: " .. (c.path or "?"))
        return
    end
    local rt, st = rateFor(c)
    a.src     = src
    a.rt      = rt
    a.stretch = st
    a.slen    = r.GetMediaSourceLength(src)
    -- HOW LONG ONE PASS TAKES TO PLAY — and the only length this window ever
    -- needs. A preview counts its position in the seconds it has been PLAYING,
    -- not in the seconds of the file it is reading: D_LENGTH comes back as the
    -- source over the rate, and D_POSITION advances at one second per second
    -- whatever the rate is. Both facts measured, not assumed (D_LENGTH 4.2857
    -- for a 4.5714 s source at 1.0667, and a read head that moved 0.2773 s
    -- while 0.2773 s of clock passed, three times running on two drivers).
    --
    -- Which means every position handed to a preview is simply REAL TIME, and
    -- the playrate has no business anywhere near it. It was in all of them:
    -- start, phase lock, re-anchor — each multiplying by the rate what it
    -- should have left alone, so every offset was rate times too big. At 400
    -- BPM against a 100 BPM loop that is four times, which is the shape of the
    -- 220 ms / 460 ms pair measured at 170 and 400 BPM.
    a.plen = (rt > 0) and (a.slen / rt) or a.slen
    -- The source's OWN tempo, derived rather than asked for again: the rate is
    -- the project's tempo over it. Keeping it is what lets a playing loop
    -- follow a tempo change with one division instead of a second analysis.
    -- Not matching means not following: a clip told to keep the file's own
    -- tempo has no BPM of its own to be re-rated against.
    local pb = r.Master_GetTempo() or 0
    a.bpm = (c.tempo_mode ~= "none" and pb > 1 and rt > 0) and (pb / rt) or nil
end

-- Build the preview and hand it its settings. Cheap — no disk, no analysis —
-- and it MUST happen in the tick that plays it.
--
-- REPITCH, NOT STRETCH — and this is where the last fixed offset was.
--
-- Preserving pitch across a rate change is not arithmetic on a read pointer:
-- it runs the sound through REAPER's TIME STRETCHER, and every time stretcher
-- works on a window it must fill before it can emit anything. That fill is a
-- LATENCY — tens of milliseconds, fixed for a given mode — and nothing in the
-- API reports it: D_POSITION reports where the stretcher is READING, which
-- keeps running ahead of what anyone hears. So the sound came out late by that
-- window, every single time, identically, whatever the Q and whatever the
-- clock. It is exactly why MIDI measured zero through the same track on the
-- same card: a sampler plays the file, it does not stretch it.
--
-- Resampling has no window. The read pointer moves at a different speed and
-- the sound comes out now — which is what every hardware sampler, every
-- tracker and every launcher's repitch mode has always done, and the only
-- rate change that can be sample-exact by construction.
--
-- Stretch stays available per clip, because a melodic loop that must not
-- change key is a real need. It is late by its stretcher's window and it
-- cannot be compensated from here, which the menu and the help both say.
local function audioBuild(a, t)
    local prev = r.CF_CreatePreview(a.src)
    if not prev then return nil end
    r.CF_Preview_SetValue(prev, "D_VOLUME", 1)
    if a.rt ~= 1.0 then
        r.CF_Preview_SetValue(prev, "D_PLAYRATE", a.rt)
        if a.stretch then r.CF_Preview_SetValue(prev, "B_PPITCH", 1) end
    end
    r.CF_Preview_SetValue(prev, "B_LOOP", 1)
    -- A few milliseconds of fade at the start: SWS opens on a raw sample edge,
    -- which clicks on anything that does not begin at zero.
    r.CF_Preview_SetValue(prev, "D_FADEINLEN", FADE_IN)
    -- No D_MEASUREALIGN. It holds EVERY loop pass to the bar grid, not only the
    -- first, so a sample that is not exactly N measures long waits at the end
    -- of each pass — the gap between two instances. And it can only align to a
    -- MEASURE, which is why a sound ignored the Q while every MIDI clip obeyed
    -- it. The boundary is ours to pick (launchBeat), on the engine's clock and
    -- by the engine's rule, so the launch is quantized and the loop runs.
    -- Route it through a TRACK, always. A preview with no output track goes
    -- straight to the hardware: not through the column's fader, not through
    -- the master, not into anything you record — the sound is audible and
    -- nowhere. previewDest finds the nearest thing downstream that can take
    -- audio, which for an ordinary column is the column's own track.
    local tr = previewDest(Loop.GetLaneDest(t))
    if tr and r.CF_Preview_SetOutputTrack then
        -- and that track stops being rendered ahead of the playhead, or the
        -- sound lands wherever REAPER had got to rather than where we put it
        liveTrack(tr)
        r.CF_Preview_SetOutputTrack(prev, 0, tr)
    end
    a.pdc = tr and chainLatency(tr) or 0
    return prev
end

-- ---------------------------------------------------------------------------
-- THE LAUNCH PROBE — the "Activity" toggle in the bar.
--
-- A timing argument cannot be settled from a waveform: a recording shows where
-- a sound LANDED, never which of the dozen quantities between the click and the
-- card was wrong. This logs, per launch, every one of them, and then answers the
-- one question that matters:
--
--     AT WHAT INSTANT, ON THE PROJECT'S OWN TIMELINE, DID THE SOUND START?
--
-- It is answered without believing anything we computed. On a later frame the
-- preview is asked where its read head is (D_POSITION) and REAPER is asked where
-- the transport is (GetPlayPosition2). Where the head SHOULD be, if the sound
-- were exactly in time, is `now - boundary` — real seconds, because a preview
-- counts the seconds it has been PLAYING. The gap between the two is the error
-- in milliseconds, signed, positive for a sound running ahead.
--
-- The probe found that units question in this window's own arithmetic before it
-- found anything else, which is the argument for having built it.
--
--   err = 0        the launch is exact and anything still heard late is
--                  DOWNSTREAM of us: REAPER's mixing, the driver, or the way
--                  the measurement itself is recorded.
--   err < 0        the sound really did start late, by that much, and the log
--                  line above it says which term is responsible.
--
-- It also prints GetPlayPosition2 minus GetPlayPosition — REAPER's own opinion
-- of its output latency — beside what the driver claims. Two numbers that
-- disagree there explain an entire class of "everything is late" reports.
--
-- Off by default and it costs one boolean test per frame; nothing is formatted,
-- allocated or read unless it is on.
-- ---------------------------------------------------------------------------
local diag_on = Core.LoadPersistent("CP_Session", "diag", false)

local function diagLaunch(a, t, e, off, clamped, pos)
    local tempo = r.Master_GetTempo() or 0
    local beat  = Loop.EngineBeat()
    local pp2   = r.GetPlayPosition2() or 0
    local pp    = r.GetPlayPosition() or 0
    local olat  = r.GetOutputLatency and (r.GetOutputLatency() or 0) or -1
    local _, bs = r.GetAudioDeviceInfo("BSIZE", "")
    local _, sr = r.GetAudioDeviceInfo("SRATE", "")
    -- how far the FIRE was from the boundary, on the engine's own clock
    local fire = (tempo > 1) and ((beat - (a.at or 0)) * 60 / tempo * 1000) or 0
    r.ShowConsoleMsg(string.format(
        "[CP_Session] LAUNCH tr=%d clock=%s bpm=%.2f rt=%.4f slen=%.3f\n" ..
        "   frame=%.1fms\n" ..
        "   at=%.4f beat=%.4f fire=%+.1fms | t0=%s pp2=%.4f pp=%.4f pp2-pp=%+.1fms" ..
        " outlat=%.1fms bsize=%s sr=%s\n" ..
        "   e=%s halfblock=%.1fms(unused) pdc=%+.1fms off=%+.1fms clamped=%d pos=%.4f\n",
        t, Loop.GetFreeRun() and "FREE" or "FOLLOW", tempo, a.rt or 0, a.slen or 0,
        frame_s * 1000,
        a.at or 0, beat, fire,
        a.t0 and string.format("%.4f", a.t0) or "-", pp2, pp, (pp2 - pp) * 1000,
        olat * 1000, bs or "?", sr or "?",
        e and string.format("%+.1fms", e * 1000) or "nil",
        blockSlack() * 1000, (a.pdc or 0) * 1000, off * 1000,
        clamped and 1 or 0, pos))
    -- WHICH SECONDS D_POSITION COUNTS. The one thing the whole alignment rests
    -- on and the one thing never verified: a position handed to a preview that
    -- plays at 1.07x is either a place in the SOURCE or a duration of PLAYBACK,
    -- and the two differ by exactly the rate. D_LENGTH answers it in one line —
    -- it is the source's own length if the first, the source over the rate if
    -- the second — and the answer decides whether the launch must multiply by
    -- the rate or divide by it.
    local okl, rvl, plen = pcall(r.CF_Preview_GetValue, a.prev, "D_LENGTH")
    r.ShowConsoleMsg(string.format(
        "   D_LENGTH=%s  source=%.4f  source/rate=%.4f\n",
        (okl and rvl and plen) and string.format("%.4f", plen) or "?",
        a.slen or 0, (a.slen or 0) / ((a.rt and a.rt > 0) and a.rt or 1)))
    a.dg = { pos = pos, n = 0 }
end

-- Two samples: the frame after the launch, and two seconds in. One says whether
-- the START was in time, the other whether the SPEED is.
--
-- Two seconds, not ten frames, because D_POSITION is reported a whole audio
-- block at a time: over a third of a second a 1024-sample buffer is worth 6% of
-- the answer, which reads as a drift that is not there. Over two seconds it is
-- worth 1%, and a preview that is genuinely starved shows up as what it is.
local DIAG_LATE = 60
local function diagFollow(a)
    local dg = a.dg
    dg.n = dg.n + 1
    if dg.n ~= 1 and dg.n ~= DIAG_LATE then return end
    local ok, rv, pos = pcall(r.CF_Preview_GetValue, a.prev, "D_POSITION")
    if not (ok and rv and pos) then a.dg = nil return end
    local plen = (a.plen and a.plen > 0) and a.plen or 1
    -- where the read head must be for the sound to be exactly in time
    local ref  = a.t0 and ((r.GetPlayPosition2() or 0) - a.t0)
                      or ((Loop.EngineBeat() - (a.at or 0))
                          * 60 / math.max(Loop.Tempo() or 120, 1))
    local want = ref % plen
    local err  = pos - want
    local half = plen * 0.5
    if err > half then err = err - plen elseif err < -half then err = err + plen end
    -- The loop's own DOWNBEAT, on the project's timeline: the read head IS how
    -- long ago it last crossed zero. Put the edit cursor on the bar line and
    -- this number is directly comparable to what the ruler says — no recording,
    -- no driver, no compensation in between.
    local down = a.t0 and ((r.GetPlayPosition2() or 0) - pos) or nil
    r.ShowConsoleMsg(string.format(
        "[CP_Session] +%-2dF ref=%+.4fs pos=%.4f want=%.4f  START ERROR=%+.1fms%s\n",
        dg.n, ref, pos, want, err * 1000,
        down and string.format("  (loop zero at %.4f, boundary %.4f)", down, a.t0) or ""))
    -- THE SLOPE, WHICH IS WORTH MORE THAN EITHER POINT. A preview counts the
    -- seconds it has been PLAYING, so its head must move at exactly one second
    -- per second whatever the rate. Below that it is being STARVED — the audio
    -- thread cannot feed it — and that is a machine fact, not an arithmetic
    -- one: 0.53x on a 64-sample ASIO buffer, 1.0000x on 1024.
    if dg.n == 1 then
        dg.ref1, dg.pos1 = ref, pos
    elseif dg.ref1 then
        local dref = ref - dg.ref1
        if dref > 0.05 then
            -- the head has looped in between, so the raw difference is short by
            -- whole passes: put them back, the count being however many fit in
            -- the real time that went by
            local dpos = (pos - dg.pos1) % plen
            dpos = dpos + plen * floor((dref - dpos) / plen + 0.5)
            local sp = dpos / dref
            r.ShowConsoleMsg(string.format(
                "[CP_Session]      read speed = %.4f x real time (wanted 1.0000)%s\n",
                sp, (sp < 0.95) and "   *** STARVED: the audio thread cannot"
                                .. " feed this preview at this buffer size ***" or ""))
        end
    end
    if dg.n == DIAG_LATE then a.dg = nil end
end

-- START IT EARLY, IN THE TAIL OF ITS OWN LOOP.
--
-- The engine fires a clip on an AUDIO BLOCK — three milliseconds wide. This
-- window fires a sound on a DISPLAY FRAME, thirty. That one difference is the
-- whole of the 21-41 ms that was left, and no amount of arithmetic after the
-- fact can recover it: by the time we know the boundary has passed, it has.
--
-- So we stop arriving after it. The launch happens up to LEAD seconds BEFORE
-- the boundary, and the preview is positioned that far from the END of its
-- source: it loops, so it reaches its own zero exactly ON the beat. What is
-- heard in between is the loop's own tail — which is what a loop sounds like,
-- and it is at most a frame of it.
--
-- The position is then one formula for both sides of the boundary, because
-- `elapsed` is signed: negative before it (the tail), positive after (the
-- overshoot, taken off the front as it always was).
--
--     position = (elapsed * rate) mod source_length
--
-- OFF_MAX is the sanity bound. Beyond it the reference is not something to
-- believe, and moving the sound on its word is worse than starting it whole.
-- A quarter of a second, not a tenth: now that a boundary taken at a transport
-- start is the moment the transport REALLY started (see TS), a launch can be
-- honestly late by more than a frame — a slow frame, a project loading its
-- first buffer — and skipping that far in is the right answer, not a reason to
-- disbelieve the reference. TS itself is what bounds the nonsense, at half a
-- second, and it does it where the number is still meaningful.
local LEAD    = 0.045
local OFF_MAX = 0.250

-- AND THE LEAD MUST COVER A FRAME, WHATEVER A FRAME COSTS TODAY.
--
-- 45 ms was a guess at what a display frame is worth, and a guess is exactly
-- what it must not be: the measured delay tracks the FRAME, not the audio
-- block. Shrinking the audio buffer does not shorten the wait, it lengthens it
-- — a smaller buffer means more callbacks per second, a machine closer to the
-- edge, and a defer loop that slows to a crawl. 64 samples measured 182 ms and
-- 1024 measured 30 ms on the same machine and the same file, and 30 ms is one
-- frame. So the lead is the frame itself, measured, with the old constant as
-- its floor.
--
-- A ceiling too, because the lead is played from the loop's own tail: an eighth
-- of a second of tail is still a loop, half a second is a different sound.
-- Beyond the ceiling the launch is simply late and `off` skips it into phase,
-- which costs the attack but never the grid.
local LEAD_MAX = 0.150
local last_tp  = nil

local function frameLead()
    local now = r.time_precise()
    if last_tp then
        local d = now - last_tp
        -- averaged, so one stalled frame sets no policy and one fast one
        -- does not undo the caution either
        if d > 0 and d < 0.5 then frame_s = frame_s + (d - frame_s) * 0.25 end
    end
    last_tp = now
    local l = frame_s * 1.5
    if l < LEAD then return LEAD end
    if l > LEAD_MAX then return LEAD_MAX end
    return l
end

local function audioStart(t)
    local a = aplay[t]
    if not a then return end
    audioOpen(a)                          -- normally already done, so free
    if not a.src then aplay[t] = nil return end
    local prev = audioBuild(a, t)
    if not prev then aplay[t] = nil return end
    -- Where the boundary is, in the terms of whichever clock we are on: a
    -- project TIME when we follow the transport, a beat on the engine's own
    -- clock when we do not. `elapsed` reads one or the other from this.
    a.t0     = (not Loop.GetFreeRun()) and r.TimeMap2_QNToTime(0, a.at or 0) or nil
    a.locked = false

    -- Where the boundary stands relative to us — behind (we are late) or ahead
    -- (we fired early, on purpose) — plus the chain's own latency.
    --
    -- NO HALF-BLOCK. It was there because the preview is picked up on the next
    -- audio block, so its first sample would land half a block late on average.
    -- But the reference it is being added to is GetPlayPosition2, which IS the
    -- next block: the two are the same instant, and adding the block to itself
    -- put every launch that far ahead of its own boundary. The probe reads it
    -- back as exactly that, +10.7 ms on a 1024-sample buffer.
    local e = elapsed(a)
    local off = (e or 0) + a.pdc
    local clamped = false
    if off > OFF_MAX or off < -OFF_MAX then off = 0 clamped = true end
    local pos = 0
    if a.plen and a.plen > 0 then
        -- REAL SECONDS, signed, and the modulo does the rest: past the boundary
        -- it takes the overshoot off the front, before it lands in the tail.
        pos = off % a.plen
        r.CF_Preview_SetValue(prev, "D_POSITION", pos)
    end

    -- The session starts sounding HERE, not when the cell was clicked. Said
    -- any earlier, the engine's free clock would leave zero while we were
    -- still opening the file — and the sound would then have to skip the
    -- opening of its own file to stay in phase with a clock that had started
    -- without it. Zero of that clock and the first sample of this sound are
    -- now the same instant, which is exactly what a downbeat is.
    Loop.SetAudioRun(true)
    r.CF_Preview_Play(prev)
    a.prev = prev
    if diag_on then diagLaunch(a, t, e, off, clamped, pos) end
end

-- ONE correction, on the frame after the launch, and never again.
--
-- The alignment that matters happens BEFORE the sound starts: D_POSITION is
-- set on a preview that has not begun, which costs nothing and is the only
-- moment a position can be chosen freely. This is the single catch-up for what
-- that calculation could not know — how long the file took to open, where the
-- audio buffer actually picked the preview up — measured one frame later, when
-- the sound has barely begun.
--
--    position = (elapsed_since_the_boundary * rate) mod source_length
--
-- WHAT IT NO LONGER DOES is police the sound for the rest of its life. Seeking
-- a preview that is already playing is not a free operation: SWS re-primes its
-- buffer, and a correction every half-second is a hole in the music every
-- half-second — which is exactly what a drift watch with a 30 ms slack was
-- doing to every tempo-matched loop. A loop and the project run off the SAME
-- sound card clock, so there is no drift to catch; what looked like drift was
-- the watch itself. If a loop really does walk away, its tempo match is wrong
-- and the fix belongs there, not in a sound chopped twice a second to hide it.
--
-- 20 ms of tolerance: under that, correcting costs more than it is worth.
-- And a ceiling, because a correction bigger than a start-up latency is not a
-- correction — it is a reference we should not have believed, and moving the
-- sound a quarter second on its word would be worse than leaving it alone.
local LOCK_TOL = 0.020
local LOCK_MAX = 0.250

local function lockPhase(a)
    if a.locked or not a.prev or not a.plen or a.plen <= 0 then return end
    local e = elapsed(a)
    -- A sound launched EARLY has not reached its boundary yet: there is nothing
    -- to check against, and burning the one correction here would spend it on a
    -- question that has no answer. Wait for the beat to arrive.
    if not e or e < 0 then return end
    a.locked = true                    -- once, whatever comes of it
    -- + the chain's latency: the sample handed over now is the one that has to
    -- be HEARD after that delay, so the clip must already be that far ahead.
    -- Real seconds, like every other position: see a.plen.
    local want = (e + (a.pdc or 0)) % a.plen
    local ok, rv, pos = pcall(r.CF_Preview_GetValue, a.prev, "D_POSITION")
    if not (ok and rv and pos) then return end
    local err = want - pos
    local half = a.plen * 0.5
    if err > half then err = err - a.plen elseif err < -half then err = err + a.plen end
    if (err > LOCK_TOL or err < -LOCK_TOL)
       and err < LOCK_MAX and err > -LOCK_MAX then
        pcall(r.CF_Preview_SetValue, a.prev, "D_POSITION", want)
    end
end

-- Is the clock RUNNING? Free run has its own, which never stops; following
-- means there is nothing to follow until the transport rolls.
local function clockRolling()
    if Loop.GetFreeRun() then return true end
    return (r.GetPlayState() & 1) == 1
end

-- A sound that has been replaced, still playing out its last frame. A launch
-- fires up to one frame EARLY (see LEAD), so stopping the outgoing one there
-- would cut it a frame short of the boundary it was told to leave on. It is
-- stashed instead and released on the next frame — the two overlap for exactly
-- the span between the early start and the beat, which is what a swap sounds
-- like on a console rather than a hole.
local dying = {}

local function reapDying()
    for i = #dying, 1, -1 do
        freeAudio(dying[i])
        dying[i] = nil
    end
end

-- The waiting half becomes the sounding one. Whatever the track was playing
-- leaves in the SAME call, so the swap is one boundary and not two.
local function audioFire(t)
    local q = aqueue[t]
    if not q then return end
    local out = aplay[t]
    if out then dying[#dying + 1] = out end
    aqueue[t] = nil
    aplay[t] = q
    audioStart(t)
end

-- Queue a launch. It is ARMED here and fires on the Q boundary, exactly as a
-- MIDI clip is queued and fires on the boundary — with the clock following a
-- STOPPED transport there is no beat to land on, so it simply waits for one.
local function audioArm(t, s, c)
    if not HAS_CF then flash("Audio cells need the SWS extension") return end
    audioCancel(t)
    local q = { s = s, c = c }
    aqueue[t] = q
    -- Opened and tempo-matched NOW, while there is time to spare: a boundary
    -- must never cost a disk read nor REAPER's tempo analysis. The boundary
    -- itself is asked for AFTER that work, so it is the clock as it is when the
    -- launch is really armed.
    audioOpen(q)
    -- Q: Off means NOW, and now is this frame — waiting for the next poll
    -- would put a frame of silence under every unquantized launch.
    if clockRolling() then
        q.at = launchBeat()
        if Loop.EngineBeat() >= q.at then audioFire(t) end
    end
end

-- Queue the stop of what sounds. A clip does not stop under your finger — it
-- finishes on the boundary — and a sound has no reason to be the exception.
local function audioQueueStop(t)
    local a = aplay[t]
    if not a or a.stop_at then return end
    if not clockRolling() then audioStop(t) return end
    a.stop_at = launchBeat()
    if Loop.EngineBeat() >= a.stop_at then audioStop(t) end
end

-- Everything this track sounds LEAVES on the next boundary: what is queued
-- simply drops, what sounds is queued to stop. The MIDI half of the same move
-- is Loop.StopClip, which the engine has always honoured on the boundary.
local function audioYield(t)
    audioCancel(t)
    audioQueueStop(t)
end

-- THE CLOCK CHANGED UNDER A SOUND THAT IS PLAYING. Every beat we were holding
-- was a position on the OTHER clock and means nothing on this one — so the
-- reference moves and the SOUND DOES NOT: where it is now becomes where it was
-- launched, minus what it has already played. The engine does the same thing
-- for its lanes (it re-anchors every record start by the same jump), and for
-- the same reason: a clock is a way of counting, not a thing to be dragged by.
local function reanchor(a)
    if not a.prev then return end
    local ok, rv, pos = pcall(r.CF_Preview_GetValue, a.prev, "D_POSITION")
    -- already real seconds — no division by the rate, see a.plen
    local played = (ok and rv and pos) and (pos - (a.pdc or 0)) or 0
    if Loop.GetFreeRun() then
        local tempo = Loop.Tempo() or 0
        a.t0 = nil
        a.at = Loop.EngineBeat() - ((tempo > 1) and (played * tempo / 60) or 0)
    else
        a.at = Loop.EngineBeat()
        a.t0 = (r.GetPlayPosition2() or 0) - played
    end
    -- the reference was moved TO the sound, so there is nothing to correct:
    -- the one catch-up stays spent
    a.locked = true
end

-- Per-frame reconciliation of the sound cells with the clock:
--   * clock stopped                 → give the preview back, keep the cell
--   * sounding + a stop queued      → stop it on the boundary
--   * waiting + its boundary passed → fire (which evicts the sounding one)
--
-- Targets are dropped whenever the clock is not rolling and taken again when
-- it is. A boundary computed on a frozen playhead is a beat number in a past
-- the transport is about to leave: pressing play would either fire the clip at
-- once or, worse, leave it waiting for a beat that will not come round for
-- another minute.
local last_free = nil
local last_bpm  = nil

local function pollAudio()
    reapDying()      -- whatever was replaced last frame has now had its beat
    local free = Loop.GetFreeRun()
    if free ~= last_free then
        if last_free ~= nil then
            for t = 0, TRACKS - 1 do
                local a, q = aplay[t], aqueue[t]
                if q and q.at then q.at = launchBeat() end
                if a then
                    if a.stop_at then a.stop_at = launchBeat() end
                    reanchor(a)
                end
            end
        end
        last_free = free
    end

    -- THE PROJECT TEMPO CHANGED, AND A SOUND IS PLAYING AT THE OLD ONE.
    -- The rate was decided when the file was opened, so a running loop kept the
    -- tempo it was launched at until it was stopped and relaunched by hand. It
    -- follows now: the source's own BPM was derived at open time (tempo over
    -- rate, exact and free), so the new rate is one division — no reopening, no
    -- second analysis. The reference moves with it rather than the sound, as it
    -- does on a clock change.
    local bpm = r.Master_GetTempo() or 0
    if bpm ~= last_bpm then
        if last_bpm and bpm > 1 then
            for t = 0, TRACKS - 1 do
                local a = aplay[t] or aqueue[t]
                if a and a.bpm and a.bpm > 0 then
                    a.rt = bpm / a.bpm
                    -- a pass now takes a different time to play; every position
                    -- this window holds is measured against it
                    a.plen = (a.slen and a.rt > 0) and (a.slen / a.rt) or a.plen
                    if a.prev then
                        pcall(r.CF_Preview_SetValue, a.prev, "D_PLAYRATE", a.rt)
                        reanchor(a)
                    end
                end
            end
        end
        last_bpm = bpm
    end

    local rolling = clockRolling()
    local beat = rolling and Loop.EngineBeat() or 0
    -- How far ahead of a boundary we are allowed to fire, in beats. A sound
    -- starts EARLY and lands on the beat from inside its own tail; see LEAD.
    -- Called every frame whether or not anything is queued, because it is also
    -- what measures the frame.
    local lead = frameLead()
    local lead_beats = (bpm > 1) and (lead * bpm / 60) or 0
    local any  = false
    for t = 0, TRACKS - 1 do
        local a, q = aplay[t], aqueue[t]
        if not rolling then
            if a then
                -- it becomes a sound WAITING, which is what it now is — unless
                -- a launch was already queued over it (the newer word), or it
                -- was on its way out anyway, in which case the transport
                -- stopping is simply where it goes
                local leaving = a.stop_at ~= nil
                audioRelease(a)          -- frees; the cell itself is kept
                if not q and not leaving then aqueue[t] = a end
                aplay[t] = nil
            end
            local w = aqueue[t]
            if w then
                w.at = nil
                -- and its file is reopened while the transport is stopped, so
                -- the moment it rolls there is nothing left to read
                audioOpen(w)
            end
        else
            if a and a.stop_at and beat >= a.stop_at then
                audioStop(t)
                a = nil
            end
            if q then
                -- No target means it was queued with no clock to land on. The
                -- clock is here now, so it takes a real boundary — the same
                -- one the engine gives its lanes at the same moment, which is
                -- the whole reason a sound and a clip launched together arrive
                -- together. The transport rolling mid-bar is not a bar line —
                -- but a transport that started ON one, and was heard about a
                -- frame later, IS: that is what qSlop is for.
                if not q.at then
                    q.at = launchBeat()
                    -- The one decision the probe could not see, and the only
                    -- place a launch can lose a whole bar rather than a few
                    -- milliseconds: how far past a boundary still counts as on
                    -- it, against how far past we actually are.
                    if diag_on then
                        local qv = Loop.GetLaunchQ() or 0
                        r.ShowConsoleMsg(string.format(
                            "[CP_Session] QUEUE tr=%d Q=%.3f beats  beat=%.4f"
                         .. "  phase=%.4f slop=%.4f -> target=%.4f  (%+.0f ms away)\n",
                            t, qv, beat,
                            (qv > 0.001) and (beat - floor(beat / qv) * qv) or 0,
                            (qv > 0.001) and qSlop(qv) or 0,
                            q.at,
                            (bpm > 1) and ((q.at - beat) * 60 / bpm * 1000) or 0))
                    end
                end
                -- EARLY, by up to one display frame: firing on the boundary
                -- means firing after it, because that is when we learn it has
                -- passed. The preview starts inside its own tail and reaches
                -- its zero on the beat.
                if beat >= q.at - lead_beats then audioFire(t) end
            end
        end
        -- Whatever is sounding is kept ON the clock, not merely started on it
        -- — and it is what the flag below reports. SOUNDING, not merely
        -- queued: a launch still waiting for a clock must not be what starts
        -- the clock it is waiting for.
        local live = aplay[t]
        if live and live.prev then
            if rolling then lockPhase(live) end
            if live.dg then diagFollow(live) end
            any = true
        end
    end
    -- The engine cannot see a CF preview, so it is told: its free clock is the
    -- session's transport, and a sound cell is as much of a session as a lane.
    Loop.SetAudioRun(any)
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
    audioYield(t)  -- a track plays ONE thing, whatever its kind
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
        -- Sound cell: different engine, SAME grammar. The three answers a clip
        -- gives to a click are the three this gives — cancel what is only
        -- queued, queue the stop of what plays, or queue a launch and let the
        -- outgoing one leave on that same boundary.
        local q = aqueue[t]
        if q and q.s == s then
            audioCancel(t)                        -- cancel the queued launch…
            local a = aplay[t]
            if a then a.stop_at = nil end         -- …and keep what was playing
            local live = liveLane(t)              -- MIDI outgoing: same rescue
            if Loop.Pending(live) == 2 then Loop.Play(live) end
            return
        end
        local a = aplay[t]
        if a and a.s == s then
            if a.stop_at then a.stop_at = nil     -- take the queued stop back
            else audioQueueStop(t) end
            return
        end
        stopTrack(t)                              -- whatever plays leaves on the boundary
        audioArm(t, s, c)
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
            audioYield(t)
            Loop.StopClip(mine)
            return
        end
    end

    audioYield(t)  -- a sound on this track leaves on the same boundary
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
        -- a sound counts as a clip here: asking for the NOTES of an audio cell
        -- answers zero, and a scene holding sounds stopped those tracks
        local c = cells[t][s]
        if c and (isAudio(c) or cellNotes(c) > 0) then
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
    audioYield(t)                           -- on the boundary the take arrives on
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
    if m == 0 then
        -- The engine settles an empty take back to "no clip". Saying so
        -- matters: with Rec: 1 bar the whole thing is over two seconds after
        -- the transport rolls, and a cell that simply stopped blinking read as
        -- "the recording was deleted" rather than "nothing was played into it".
        rec = nil
        flash("Nothing played — the slot stays empty")
        return
    end
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
    -- a deleted clip stops NOW, boundary or not: there is nothing left to
    -- finish, and waiting would play a cell the grid no longer has
    local a, q = aplay[t], aqueue[t]
    if a and a.s == s then audioStop(t) end
    if q and q.s == s then audioCancel(t) end
    if cur[t] == s then cur[t] = nil end
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

-- HOW A SOUND FOLLOWS THE PROJECT'S TEMPO — and it is a real choice, not a
-- preference, because the two answers are two different machines:
--   repitch  the read pointer moves faster. No window, no latency, exact.
--   stretch  REAPER's time stretcher. Keeps the key, and is late by the
--            window that stretcher must fill before it can emit anything —
--            fixed, tens of milliseconds, and reported by no API.
--   none     the file plays at its own tempo.
-- Repitch is the default because a launcher's job is to be in time.
--
-- A running sound takes a new RATE immediately (it is a number). It does not
-- change ENGINE under itself: turning stretch on or off waits for the next
-- launch, which is one boundary away.
local function applyTempoMode(a, c)
    if not a or a.c ~= c or not a.src then return end
    local rt, st = rateFor(c)
    if a.prev and st ~= a.stretch then return end
    local pb = r.Master_GetTempo() or 0
    a.rt      = rt
    a.stretch = st
    a.plen    = (a.slen and rt > 0) and (a.slen / rt) or a.plen
    a.bpm     = (c.tempo_mode ~= "none" and pb > 1 and rt > 0) and (pb / rt) or nil
    if a.prev then
        pcall(r.CF_Preview_SetValue, a.prev, "D_PLAYRATE", rt)
        reanchor(a)
    end
end

local function setCellTempoMode(t, s, mode)
    local c = cells[t][s]
    if not c then return end
    c.tempo_mode = (mode ~= "repitch") and mode or nil
    saveGrid()
    applyTempoMode(aplay[t], c)
    applyTempoMode(aqueue[t], c)
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
    local snd = has and c.kind ~= "midi" and c.path ~= nil
    local tm  = snd and (c.tempo_mode or "repitch") or nil
    local tmodes = snd and {
        { label = "Repitch (in time)", checked = (tm == "repitch"),
          action = function() setCellTempoMode(t, s, "repitch") end },
        { label = "Stretch (keeps the key, plays late)", checked = (tm == "stretch"),
          action = function() setCellTempoMode(t, s, "stretch") end },
        { separator = true },
        { label = "Don't follow the tempo", checked = (tm == "none"),
          action = function() setCellTempoMode(t, s, "none") end },
    } or nil
    UI.NativeMenu({
        { label = "Edit in CP_Editor", action = function() editCell(t, s) end },
        { label = "Rename clip…", disabled = not has,
          action = function() renameCell(t, s) end },
        { label = "Color", disabled = not has, children = cols },
        { label = "Tempo", disabled = not snd, children = tmodes },
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
    local clip, sx, sy, kind, payload, fsx, fsy = Bus.TakeDrop("session")
    -- An FX dragged from the Media Explorer or the FX browser is not a clip
    -- and never was: it lands in the CHAIN of the strip it was dropped on,
    -- which is the only thing "here" can mean over a mixer.
    if not clip and kind == "fx" and payload and payload ~= "" then
        local cx, cy = Core.ScreenToClient(fsx, fsy)
        for t = 0, TRACKS - 1 do
            local g = mix_col[t]
            if g and g.y and cx >= g.x and cx < g.x + g.w
               and cy >= g.y and cy < g.y + g.h then
                local tr = Loop.GetLaneDest(t)
                if Mix.Valid(tr) and Mix.FxAdd(tr, payload) >= 0 then
                    flash("FX -> " .. trackName(t))
                else
                    flash("This column has no track to put an FX on")
                end
                break
            end
        end
        return
    end
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
    -- A queue with no boundary yet: it is waiting for the CLOCK, not for a
    -- beat. The cell has to say which, or "queued" looks like "stuck".
    local wait_clock = false
    if audio then
        -- The two halves say exactly what the engine's two say: a queued
        -- launch is pending 1, a queued stop pending 2, and a sound whose
        -- preview the transport took back is queued again — same states, same
        -- colours, whatever kind of thing the cell holds.
        local a, q = aplay[t], aqueue[t]
        playing = (a ~= nil and a.s == s and a.prev ~= nil)
        if q and q.s == s then
            pend = 1
            wait_clock = (q.at == nil)
        elseif a and a.s == s then
            if a.stop_at then pend = 2
            elseif not a.prev then pend = 1; wait_clock = true end
        end
    else
        playing = (mode == 3 or mode == 5)
        if pend == 1 and lane then wait_clock = Loop.PendingWaitsClock(lane) end
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
        if wait_clock then
            -- it is not late, it is early: the clock it was launched against
            -- has not started yet, and it will start with it
            local pc = C.pending or C.accent
            Core.DrawText("waiting for the transport",
                          x + bw + 2, y + h - 13, pc[1], pc[2], pc[3], 0.9)
        else
            Core.DrawText(audio and "audio" or barsLabel(cellBars(c)),
                          x + bw + 2, y + h - 13, mc[1], mc[2], mc[3], 0.85)
        end
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
-- The mixer — a real channel strip per column
--
-- This started as three controls on the reasoning that a console would
-- re-implement what REAPER already has. That was right about the FORMAT and
-- wrong about the VIEW. Nothing below is a second mixer engine: every value is
-- REAPER's own track state, read and written through REAPER's own API, and the
-- FX chain window that opens is REAPER's. What the session needed was the
-- CHAIN and the SENDS of the thing it is launching, beside the thing it is
-- launching — reaching them meant leaving the window, and not leaving the
-- window is what a session view is for.
--
-- A column mixes the track it is ROUTED TO — the same track its clips play
-- into, so this is also the level of whatever CP_Sampler or CP_Editor sends
-- there. A column with no destination has nothing to mix and says so by being
-- disabled, not by showing a fader that quietly does nothing.
--
-- The zone's HEIGHT is the only control over how much of the strip you see:
-- drag its seam. Short, it is the fader block alone (what it always was);
-- taller, the sends appear, then the chain. No sub-toggles — the height IS
-- the answer, and it is one gesture instead of three checkboxes.
-- ---------------------------------------------------------------------------
local MIX_H     = 18       -- the M/S row
local MIX_PAD   = 4
local MIX_BTN   = 18
local MIX_MET   = 11       -- meter width beside the vertical fader
local MIX_GAP   = 3
local SEC_GAP   = 6        -- BETWEEN sections: FX | sends | fader block
local MIX_FADW  = 21       -- the fader's own width (cap included)
-- One slot. The caption font is 10 px and REAPER reports it about 13 tall, so
-- a 16-px slot leaves a pixel of air above and below the glyphs — text that
-- touches its own border reads as text that overflowed, even when it did not.
local MIX_ROW   = 16
local MIX_BAR   = 5        -- the scroll bar of a list that overflows
local MIX_PAN   = 12       -- the pan bar
local MIX_DB    = 11       -- the level readout, on a line of its own
local MIX_SENDS = 4        -- most send slots shown before the list scrolls
local MIX_FADMIN = 30
local MIX_ROWS  = 24       -- most rows a list will ever draw (id/label tables)
-- How much of a strip the two LISTS may take. The fader gets everything else:
-- it is the control you reach for a hundred times an hour, and on a console it
-- is the tallest thing in the strip for exactly that reason. A list that grew
-- at its expense would be a directory with a fader stapled to it.
local MIX_LISTS = 0.55
-- The shortest the zone can be: pan + a usable fader + M/S + the padding.
local MIX_MIN   = MIX_PAD * 2 + MIX_H + MIX_GAP + MIX_PAN + MIX_GAP
                  + MIX_DB + MIX_FADMIN
-- …and what it opens at: enough for a chain, a couple of sends and a fader
-- worth grabbing. It was opening at its MINIMUM, which showed the strip at its
-- least useful and left the seam to be discovered before anything worked.
local MIX_DEF   = 300
local MIX_MAX   = 620
local SEAM_GRAB = 5        -- the band of the seam that resizes the zone

local mix_open  = Core.LoadPersistent("CP_Session", "mix", true)
-- new key on purpose: the old one holds "as small as it goes" for everyone who
-- opened the window before the strip had anything in it
local mix_h     = Core.LoadPersistent("CP_Session", "mixh2", MIX_DEF)
local mix_moved = false    -- did the fader gesture in flight change anything
local mix_hot   = false    -- is any meter still above zero (so still falling)
local mix_seam  = nil      -- { y0, h0 } while the seam is being dragged
local fxdrag    = nil      -- { tr, i, t, x, y } an FX being carried
local snddrag   = nil      -- { t } a send being drawn from this column
if type(mix_h) ~= "number" then mix_h = MIX_MIN end
if mix_h < MIX_MIN then mix_h = MIX_MIN elseif mix_h > MIX_MAX then mix_h = MIX_MAX end

-- Ids are identity, and identity must not be rebuilt every frame.
local mix_id = { v = {}, m = {}, s = {}, p = {}, sd = {} }
for t = 0, TRACKS - 1 do
    mix_id.v[t] = "mixv" .. t
    mix_id.m[t] = "mixm" .. t
    mix_id.s[t] = "mixs" .. t
    mix_id.p[t] = "mixp" .. t
    local row = {}
    for i = 1, MIX_ROWS do row[i] = "mixsd" .. t .. "_" .. i end
    mix_id.sd[t] = row
end

-- Truncation caches, one slot per (column, row): a name is cut once for a
-- width and stays cut until one of the two changes. Built here, never in the
-- draw path — the strip redraws thirty times a second.
local fx_lbl, sd_lbl = {}, {}
local mix_scroll = {}      -- [t] = { fx, sd } first row shown in each list
for t = 0, TRACKS - 1 do
    local a, b = {}, {}
    for i = 1, MIX_ROWS do a[i] = {} b[i] = {} end
    fx_lbl[t], sd_lbl[t] = a, b
    mix_scroll[t] = { fx = 0, sd = 0 }
end

local function fitLabel(cache, s, w)
    if cache.src ~= s or cache.w ~= w then
        cache.src, cache.w = s, w
        cache.s = Core.TruncateText(s, w)
    end
    return cache.s
end

-- Shared option tables: every field is written on every call, so nothing
-- stale survives — and no table is built in a draw path.
local MIX_F_OPTS = { mark = Mix.UNITY, default = Mix.UNITY,
                     disabled = false, accent = nil,
                     tip = "Volume — Shift: fine, double-click: 0 dB, wheel: step" }
local MIX_P_OPTS = { mark = 0.5, default = 0.5, text = nil,
                     disabled = false, accent = nil,
                     tip = "Pan — double-click: centre" }
local MIX_M_OPTS = { accent = nil, tip = "Mute this column's track" }
local MIX_S_OPTS = { accent = nil,
    tip = "Solo — REAPER's solo, so the arrangement goes quiet too. Ctrl: exclusive" }
local MIX_SD_OPTS = { mark = Mix.UNITY, default = Mix.UNITY, accent = nil,
                      disabled = false }

local function fxMenu(tr, i)
    local items = {}
    if i then
        local nm = Mix.Fx(tr, i)
        items[#items + 1] = { label = "Open " .. (nm or "FX"),
                              action = function() Mix.FxShow(tr, i) end }
        items[#items + 1] = { label = "Bypass",
                              checked = select(2, Mix.Fx(tr, i)) and true or false,
                              action = function() Mix.FxToggle(tr, i) end }
        items[#items + 1] = { label = "Delete",
                              action = function() Mix.FxDelete(tr, i) end }
        items[#items + 1] = { separator = true }
    end
    items[#items + 1] = { label = "FX browser (REAPER)",
                          action = function()
                              r.SetOnlyTrackSelected(tr)
                              r.Main_OnCommand(40271, 0)
                          end }
    items[#items + 1] = { label = "CP_FX Browser",
                          action = function()
                              if not Bus.FocusApp("CP_FXBrowser", "FX Browser") then
                                  flash("CP_FX Browser is not registered as an action yet")
                              end
                          end }
    items[#items + 1] = { label = "Open this track's FX chain",
                          action = function() r.TrackFX_Show(tr, 0, 1) end }
    UI.NativeMenu(items)
end

local function sendMenu(t, tr, i)
    local items = {}
    if i then
        items[#items + 1] = { label = "Mute send", checked = Mix.SendMute(tr, i),
                              action = function()
                                  Mix.SetSendMute(tr, i, not Mix.SendMute(tr, i))
                              end }
        items[#items + 1] = { label = "Remove send",
                              action = function() Mix.SendRemove(tr, i) end }
        items[#items + 1] = { separator = true }
    end
    -- Every OTHER column is a candidate: those are the destinations this
    -- window actually knows about, and the ones a session sends to.
    local any = false
    for d = 0, TRACKS - 1 do
        local dtr = (d ~= t) and Loop.GetLaneDest(d) or nil
        if dtr and Mix.Valid(dtr) and dtr ~= tr then
            any = true
            items[#items + 1] = { label = "Send to " .. trackName(d),
                                  action = function()
                                      if Mix.SendCreate(tr, dtr) then
                                          flash("Send -> " .. trackName(d))
                                      end
                                  end }
        end
    end
    if not any then
        items[#items + 1] = { label = "(route another column to a track first)",
                              disabled = true }
    end
    UI.NativeMenu(items)
end

-- ONE SLOT — filled or empty, and both are a real object with a border, the
-- way a console's chain reads. The row IS the hit target (no widget id): slots
-- come and go with the chain, and an id that changes meaning between frames is
-- worse than no id at all. An empty one is drawn hollow: a place where
-- something can go, not a thing that is missing.
local function slotRow(theme, x, y, w, label, dim, lit, hot, empty)
    local C = theme.colors
    local iy, ih = y + 1, MIX_ROW - 2
    if empty then
        local bd = C.border
        Core.DrawRect(x + 2, iy, w - 4, ih, bd[1], bd[2], bd[3],
                      (bd[4] or 1) * (hot and 0.85 or 0.35), false)
        if hot then Core.DrawRect(x + 2, iy, w - 4, ih, 1, 1, 1, 0.07) end
        return
    end
    local sf = C.frame_bg
    Core.DrawRect(x + 2, iy, w - 4, ih, sf[1], sf[2], sf[3], dim and 0.5 or 1)
    if hot then Core.DrawRect(x + 2, iy, w - 4, ih, 1, 1, 1, 0.08) end
    if lit then
        Core.DrawRect(x + 2, iy, 2, ih, C.accent[1], C.accent[2], C.accent[3], 0.9)
    end
    if label then
        local ink = dim and (C.text_disabled or C.text_mute) or C.text
        -- centred in the box it lives in, measured rather than guessed: the
        -- glyph height is the font's business and it changes with the theme
        local _, th = Core.MeasureText(label)
        local ty = iy + floor((ih - th) / 2)
        if ty < iy then ty = iy end
        Core.DrawText(label, x + 7, ty, ink[1], ink[2], ink[3], dim and 0.6 or 0.95)
    end
end

local function drawMix(theme, t, x, y, w, h)
    local C = theme.colors
    local tr = Loop.GetLaneDest(t)
    local live = Mix.Valid(tr)
    local g = mix_col[t]
    if not g then g = {}; mix_col[t] = g end
    g.x, g.w, g.y, g.h = x, w, y, h

    local muted  = live and Mix.IsMute(tr)
    local soloed = live and Mix.IsSolo(tr)
    -- A column can be silent for two reasons, and the second one is not on
    -- this column: its own mute, or somebody else's solo. The level wears the
    -- mute colour either way, so "which of these do I actually hear" is one
    -- glance rather than an audit of four buttons.
    local dulled = live and (muted or (Mix.AnySolo() and not soloed))

    -- ---- geometry. Three sections, each with its own ground and a real gap
    -- between them: FX, then sends, then the fader block. A strip whose parts
    -- touch is a strip you have to decode before you can use it.
    local ms_y  = y + h - MIX_H
    local pan_y = ms_y - MIX_GAP - MIX_PAN
    local db_y  = pan_y - MIX_GAP - MIX_DB       -- the readout has its own line
    local avail = db_y - SEC_GAP - y             -- lists + fader

    local nfx  = live and Mix.FxCount(tr) or 0
    local nsnd = live and Mix.SendCount(tr) or 0
    -- The lists never take more than MIX_LISTS of the strip and the FADER TAKES
    -- EVERYTHING ELSE. Within their share the sends ask for what they hold plus
    -- one empty slot (capped: a session sends to a handful of places, not to
    -- twenty) and the chain takes the rest — as SLOTS, filled or not, exactly
    -- as a console does. What does not fit is reachable by scrolling the list,
    -- which is what the thin bar on its right edge is for.
    local cap = floor(avail * MIX_LISTS)
    if avail - cap < MIX_FADMIN + SEC_GAP then cap = avail - MIX_FADMIN - SEC_GAP end
    if cap < 0 then cap = 0 end
    local fx_rows, sd_rows = 0, 0
    if cap >= MIX_ROW * 2 + SEC_GAP then
        local want_s = nsnd + 1
        if want_s > MIX_SENDS then want_s = MIX_SENDS end
        local room = floor((cap - SEC_GAP) / MIX_ROW)
        sd_rows = want_s
        if sd_rows > room - 1 then sd_rows = room - 1 end
        if sd_rows < 1 then sd_rows = 1 end
        fx_rows = room - sd_rows
    elseif cap >= MIX_ROW then
        fx_rows = floor(cap / MIX_ROW)
    end
    local fx_h = fx_rows * MIX_ROW
    local sd_h = sd_rows * MIX_ROW
    local sd_y = y + fx_h + (sd_rows > 0 and SEC_GAP or 0)
    local fad_h = db_y - SEC_GAP - (sd_y + sd_h)
    if fad_h < MIX_FADMIN then fad_h = MIX_FADMIN end
    local fad_y = db_y - fad_h

    local sc = mix_scroll[t]
    -- clamp the scroll to what the list can actually show, so a chain that
    -- shrank does not leave the view parked past its end
    if sc.fx > nfx - fx_rows + 1 then sc.fx = nfx - fx_rows + 1 end
    if sc.fx < 0 then sc.fx = 0 end
    if sc.sd > nsnd - sd_rows + 1 then sc.sd = nsnd - sd_rows + 1 end
    if sc.sd < 0 then sc.sd = 0 end

    -- where a carried FX can be dropped, remembered for pollMixDrag
    g.fx_y = (fx_rows > 0) and y or nil
    g.fx_rows = fx_rows
    g.fx_scroll = sc.fx

    local mxp, myp = Core.GetMousePos()

    -- ---- the chain, as SLOTS
    local over_fx = nil
    if fx_rows > 0 then
        local bar = (nfx > fx_rows) and MIX_BAR or 0
        local rw = w - bar
        local bg = C.list_bg or C.frame_bg
        local bd = C.border
        Core.DrawRect(x, y, w, fx_h, bg[1], bg[2], bg[3], live and 1 or 0.5)
        local inlist = live and not Core.HasPopup()
            and mxp >= x and mxp < x + w and myp >= y and myp < y + fx_h
        for row = 1, fx_rows do
            local ly = y + (row - 1) * MIX_ROW
            local i  = sc.fx + row
            local hot = inlist and myp >= ly and myp < ly + MIX_ROW
            if i <= nfx then
                local nm, off = Mix.Fx(tr, i)
                slotRow(theme, x, ly, rw, fitLabel(fx_lbl[t][row], nm or "?", rw - 9),
                        off, not off, hot, false)
                if hot then
                    over_fx = row
                    if Core.MouseClicked(1) then
                        if Core.ModAlt() then Mix.FxDelete(tr, i)
                        elseif Core.ModCtrl() then Mix.FxToggle(tr, i)
                        else
                            fxdrag = { tr = tr, i = i, t = t,
                                       x = mxp, y = myp, moved = false }
                        end
                    elseif Core.MouseClicked(2) then
                        fxMenu(tr, i)
                    end
                end
            else
                -- an EMPTY SLOT, and it does what an empty slot does on every
                -- console: it opens the FX browser. REAPER's own — and the
                -- column's track is SELECTED first, because that browser
                -- inserts into the selection, so without it the gesture would
                -- open a browser aimed at whatever was clicked last.
                slotRow(theme, x, ly, rw, nil, true, false, hot, true)
                if hot then
                    over_fx = row
                    if Core.MouseClicked(1) then
                        r.SetOnlyTrackSelected(tr)
                        r.Main_OnCommand(40271, 0)   -- View: Show FX browser
                    elseif Core.MouseClicked(2) then
                        fxMenu(tr, nil)
                    end
                end
            end
        end
        -- the scroll bar, and the wheel that goes with it
        if bar > 0 then
            local th = floor(fx_h * fx_rows / nfx)
            if th < 10 then th = 10 end
            local span = fx_h - th
            local den  = nfx - fx_rows
            local ty = y + ((den > 0) and floor(span * sc.fx / den) or 0)
            local ac = C.text_mute or C.text_disabled
            Core.DrawRect(x + rw + 1, y, bar - 1, fx_h, 0, 0, 0, 0.25)
            Core.DrawRect(x + rw + 1, ty, bar - 1, th, ac[1], ac[2], ac[3], 0.65)
        end
        if inlist and not Core.IsWheelConsumed() then
            local wh = Core.GetState().mouse_wheel
            if wh ~= 0 then
                sc.fx = sc.fx - ((wh > 0) and 1 or -1)
                if sc.fx < 0 then sc.fx = 0 end
                if sc.fx > nfx - fx_rows then sc.fx = nfx - fx_rows end
                if sc.fx < 0 then sc.fx = 0 end
                Core.ConsumeWheel()
            end
        end
        Core.DrawRect(x, y, w, fx_h, bd[1], bd[2], bd[3], (bd[4] or 1) * 0.7, false)
        -- where a carried FX would land
        if fxdrag and fxdrag.moved and over_fx then
            local iy = y + (over_fx - 1) * MIX_ROW
            Core.DrawRect(x, iy, w, 2, C.accent[1], C.accent[2], C.accent[3], 1)
        end
    end

    -- ---- the sends, same grammar
    if sd_rows > 0 then
        local bar = (nsnd > sd_rows) and MIX_BAR or 0
        local rw = w - bar
        local bg = C.list_bg or C.frame_bg
        local bd = C.border
        Core.DrawRect(x, sd_y, w, sd_h, bg[1], bg[2], bg[3], live and 1 or 0.5)
        local inlist = live and not Core.HasPopup()
            and mxp >= x and mxp < x + w and myp >= sd_y and myp < sd_y + sd_h
        for row = 1, sd_rows do
            local ly = sd_y + (row - 1) * MIX_ROW
            local i  = sc.sd + row
            local hot = inlist and myp >= ly and myp < ly + MIX_ROW
            if i <= nsnd and i <= MIX_ROWS then
                local nm, _, lvl = Mix.Send(tr, i)
                MIX_SD_OPTS.accent = Mix.SendMute(tr, i) and C.mute or C.mod
                MIX_SD_OPTS.disabled = not live
                -- The send IS its level: the row is a fader with the
                -- destination written on it, so reading and setting are the
                -- same object rather than a name and a number somewhere else.
                local ch, nv, rel = UI.FaderAt(mix_id.sd[t][i], x + 2, ly + 1,
                                               rw - 4, MIX_ROW - 2, lvl or 0,
                                               MIX_SD_OPTS)
                if ch then Mix.SetSendNorm(tr, i, nv) mix_moved = true end
                if rel then
                    -- A DRAG set the level; a CLICK — released without having
                    -- moved anything — opens REAPER's routing window, which is
                    -- where a send's real parameters live (pre/post, channels,
                    -- MIDI). One gesture each, told apart by what happened
                    -- between press and release.
                    if mix_moved then
                        Mix.CommitSend()
                    else
                        r.SetOnlyTrackSelected(tr)
                        r.Main_OnCommand(40293, 0)   -- Track: routing and I/O
                    end
                    mix_moved = false
                end
                local lbl = fitLabel(sd_lbl[t][row], nm or "send", rw - 12)
                local _, th = Core.MeasureText(lbl)
                Core.DrawText(lbl, x + 6, ly + 1 + floor((MIX_ROW - 2 - th) / 2),
                              C.text[1], C.text[2], C.text[3], 0.95)
                if hot and Core.MouseClicked(2) then sendMenu(t, tr, i) end
            else
                slotRow(theme, x, ly, rw, nil, true, false, hot, true)
                if hot then
                    -- click asks where to, DRAG draws the send to the column
                    -- you drop it on — the gesture says "from here to there",
                    -- which is what a send is
                    if Core.MouseClicked(1) then
                        snddrag = { t = t, tr = tr, x = mxp, y = myp, moved = false }
                    elseif Core.MouseClicked(2) then
                        sendMenu(t, tr, nil)
                    end
                end
            end
        end
        if bar > 0 then
            local th = floor(sd_h * sd_rows / nsnd)
            if th < 10 then th = 10 end
            local span = sd_h - th
            local den  = nsnd - sd_rows
            local ty = sd_y + ((den > 0) and floor(span * sc.sd / den) or 0)
            local ac = C.text_mute or C.text_disabled
            Core.DrawRect(x + rw + 1, sd_y, bar - 1, sd_h, 0, 0, 0, 0.25)
            Core.DrawRect(x + rw + 1, ty, bar - 1, th, ac[1], ac[2], ac[3], 0.65)
        end
        if inlist and not Core.IsWheelConsumed() then
            local wh = Core.GetState().mouse_wheel
            if wh ~= 0 then
                sc.sd = sc.sd - ((wh > 0) and 1 or -1)
                if sc.sd < 0 then sc.sd = 0 end
                if sc.sd > nsnd - sd_rows then sc.sd = nsnd - sd_rows end
                if sc.sd < 0 then sc.sd = 0 end
                Core.ConsumeWheel()
            end
        end
        Core.DrawRect(x, sd_y, w, sd_h, bd[1], bd[2], bd[3], (bd[4] or 1) * 0.7, false)
    end

    -- ---- pan
    if live then
        local pn = Mix.GetPan(tr)
        MIX_P_OPTS.text = Mix.PanLabel(t, pn)
        MIX_P_OPTS.disabled = false
        MIX_P_OPTS.accent = dulled and C.mute or C.mod
        local ch, nv, rel = UI.FaderAt(mix_id.p[t], x, pan_y, w, MIX_PAN, pn,
                                       MIX_P_OPTS)
        if ch then Mix.SetPan(tr, nv) mix_moved = true end
        if rel then
            if mix_moved then Mix.CommitPan() end
            mix_moved = false
        end
    else
        MIX_P_OPTS.text, MIX_P_OPTS.disabled, MIX_P_OPTS.accent = nil, true, nil
        UI.FaderAt(mix_id.p[t], x, pan_y, w, MIX_PAN, 0.5, MIX_P_OPTS)
    end

    -- ---- fader + meter, side by side as on any console
    local fw = MIX_FADW
    local met_w = MIX_MET
    if fw + MIX_GAP + met_w > w then met_w = w - fw - MIX_GAP end
    if met_w < 4 then met_w = 0 end
    local fx0 = x + floor((w - fw - (met_w > 0 and (met_w + MIX_GAP) or 0)) / 2)
    local n = Mix.GetNorm(tr)
    MIX_F_OPTS.disabled = not live
    MIX_F_OPTS.accent = dulled and C.mute or nil
    local ch, nv, rel = UI.VFaderAt(mix_id.v[t], fx0, fad_y, fw, fad_h, n,
                                    MIX_F_OPTS)
    if ch then
        Mix.SetNorm(tr, nv)
        mix_moved = true
    end
    -- One undo point per gesture, and only if the gesture did something: a
    -- click that moved nothing should not enter the history.
    if rel then
        if mix_moved and live then Mix.CommitVol() end
        mix_moved = false
    end
    if met_w > 0 then
        local mx = fx0 + fw + MIX_GAP
        if live then
            local ml, mr, hl, hr = Mix.Meter(t, tr)
            -- A meter still above zero is a meter still FALLING, and it needs
            -- frames to fall in. Without this the strip freezes lit the moment
            -- the transport stops, which reads as "still playing".
            if ml > 0 or mr > 0 or hl > 0 or hr > 0 then mix_hot = true end
            UI.MeterAt(mx, fad_y, met_w, fad_h, ml, mr, true, hl, hr)
        else
            -- Unrouted: clear rather than fade, so nothing is left showing a
            -- level from a track this column no longer plays into.
            Mix.ResetMeter(t)
            UI.MeterAt(mx, fad_y, met_w, fad_h, 0, 0, true)
        end
    end
    -- The number, on a LINE OF ITS OWN under the fader: a strip says its level
    -- in decibels or it is a guess — and it had been sharing a line with the
    -- sends, which is how two readable things become one unreadable one.
    if live then
        local s = Mix.DbLabel(t, n)
        local tw = Core.MeasureText(s)
        local ink = dulled and C.mute or C.text_mute or C.text
        Core.DrawText(s, x + floor((w - tw) / 2), db_y,
                      ink[1], ink[2], ink[3], 0.85)
    end

    -- ---- M and S. Letters, not glyphs: they are a PAIR, and the two
    -- universal letters of every console read at 18 px where two different
    -- picture families would only read as two different things.
    MIX_M_OPTS.accent = C.mute
    MIX_S_OPTS.accent = C.solo
    local bw = floor((w - 1) / 2)
    if bw > MIX_BTN + 6 then bw = MIX_BTN + 6 end
    local bx = x + floor((w - bw * 2 - 1) / 2)
    if UI.ChipAt(mix_id.m[t], bx, ms_y, bw, MIX_H, nil, "M", muted, not live,
                 MIX_M_OPTS) then
        Mix.SetMute(tr, not muted)
    end
    if UI.ChipAt(mix_id.s[t], bx + bw + 1, ms_y, bw, MIX_H, nil, "S",
                 soloed, not live, MIX_S_OPTS) then
        Mix.SetSolo(tr, not soloed, Core.ModCtrl())
    end

    -- what a carried thing would land on
    if (fxdrag and fxdrag.moved and fxdrag.t ~= t)
       or (snddrag and snddrag.moved and snddrag.t ~= t) then
        if mxp >= x and mxp < x + w and myp >= y and myp < y + h then
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.10)
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.9, false)
        end
    end
end

-- The two carries, resolved once per frame after every strip has drawn (each
-- one knows its own rect by then). A drag only becomes a drag past a few
-- pixels: a click that wandered is still a click.
local function pollMixDrag()
    local mx, my = Core.GetMousePos()
    if fxdrag then
        if not fxdrag.moved then
            local dx, dy = mx - fxdrag.x, my - fxdrag.y
            if dx * dx + dy * dy > 16 then fxdrag.moved = true end
        end
        if fxdrag.moved then UI.SetCursor("hand") UI.RequestRedraw() end
        if not Core.MouseDown(1) then
            if fxdrag.moved then
                for t = 0, TRACKS - 1 do
                    local g = mix_col[t]
                    if g and mx >= g.x and mx < g.x + g.w then
                        local dst = Loop.GetLaneDest(t)
                        if Mix.Valid(dst) then
                            local to = Mix.FxCount(dst) + 1
                            if g.fx_y and my >= g.fx_y then
                                -- the row under the cursor, offset by what the
                                -- list is scrolled to: the slot you see is the
                                -- slot it lands in
                                local row = floor((my - g.fx_y) / MIX_ROW) + 1
                                if row >= 1 and row <= (g.fx_rows or 0) then
                                    local k = (g.fx_scroll or 0) + row
                                    if k >= 1 and k <= to then to = k end
                                end
                            end
                            if Mix.FxMove(fxdrag.tr, fxdrag.i, dst, to,
                                          Core.ModCtrl()) then
                                flash(Core.ModCtrl() and "FX copied" or "FX moved")
                            end
                        end
                        break
                    end
                end
            elseif fxdrag.tr then
                Mix.FxShow(fxdrag.tr, fxdrag.i)   -- a plain click OPENS it
            end
            fxdrag = nil
        end
    end
    if snddrag then
        if not snddrag.moved then
            local dx, dy = mx - snddrag.x, my - snddrag.y
            if dx * dx + dy * dy > 16 then snddrag.moved = true end
        end
        if snddrag.moved then UI.SetCursor("hand") UI.RequestRedraw() end
        if not Core.MouseDown(1) then
            if snddrag.moved then
                for t = 0, TRACKS - 1 do
                    local g = mix_col[t]
                    if g and t ~= snddrag.t and mx >= g.x and mx < g.x + g.w then
                        local dst = Loop.GetLaneDest(t)
                        if Mix.Valid(dst) and Mix.SendCreate(snddrag.tr, dst) then
                            flash("Send -> " .. trackName(t))
                        end
                        break
                    end
                end
            else
                sendMenu(snddrag.t, snddrag.tr, nil)   -- a plain click asks
            end
            snddrag = nil
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
    -- The launch probe. It stays in the bar rather than in a hidden switch:
    -- an engine whose timing is the whole point owes an answer to "prove it".
    if UI.BarToggle("diag", "Activity", nil, diag_on,
                    "Log every sound launch to the console: the boundary, the "
                 .. "clocks, the offset applied, and the START ERROR measured "
                 .. "one frame later") then
        diag_on = not diag_on
        Core.SavePersistent("CP_Session", "diag", diag_on)
        if diag_on then
            r.ShowConsoleMsg("[CP_Session] launch probe ON — launch a sound cell.\n")
        end
    end
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
        -- LIT = there is a clock and we follow it. A button called "Clock" that
        -- lights up to mean "no clock, we run free" says the opposite of its
        -- own name, and the eye reads the light before the tooltip.
        local free = Loop.GetFreeRun()
        if UI.BarToggle("clock", "Clock", nil, not free,
                        free and "Free run: the session is its own clock — the first launch starts it"
                              or "Following the host transport: a launch waits for it, then starts with it") then
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

    -- one call: gmem re-selected, live halves re-derived. Everything below
    -- reads a coherent picture.
    Loop.Poll()
    -- Follow the engine rather than argue with it: a launch fired from
    -- CP_Looper or CP_Editor moves what a track plays, and the grid has to
    -- know. (Sound cells are this window's own business — skip those.)
    for t = 0, TRACKS - 1 do
        if not aplay[t] and not aqueue[t] then
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
    -- and a zone that shares its neighbour's ground is not a zone. Its seam is
    -- also its GRIP: the height decides how much of a strip is on screen, from
    -- the fader alone to the whole channel, and one drag says which.
    local zone_h = 0
    mix_hot = false
    if mix_open then
        local my = sy + sh + 4
        local win_w, win_h = Core.GetWindowSize()
        local room = win_h - my - 2 - 22        -- the status zone keeps its own
        if room > MIX_MAX then room = MIX_MAX end
        if room < MIX_MIN then room = MIX_MIN end
        if mix_h > room then mix_h = room end
        zone_h = 2 + mix_h
        local surf = C.surface or C.frame_bg
        UI.SeamH(0, my, win_w)
        local zy = my + 2
        Core.DrawRect(0, zy, win_w, mix_h, surf[1], surf[2], surf[3], 1)

        local _, smy = Core.GetMousePos()
        local on_seam = (not Core.HasPopup())
            and smy >= my - SEAM_GRAB and smy < my + SEAM_GRAB
        if on_seam or mix_seam then UI.SetCursor("size_ns") end
        if on_seam and Core.MouseClicked(1) then
            mix_seam = { y0 = smy, h0 = mix_h }
        end
        if mix_seam then
            if Core.MouseDown(1) then
                local nh = mix_seam.h0 + (mix_seam.y0 - smy)
                if nh < MIX_MIN then nh = MIX_MIN elseif nh > room then nh = room end
                mix_h = nh
                UI.RequestRedraw()
            else
                mix_seam = nil
                Core.SavePersistent("CP_Session", "mixh2", mix_h)
            end
        end
        -- The seam RESIZES, so it says so: three dots is what a grip looks
        -- like everywhere, and a line that can be dragged without looking
        -- draggable is a feature nobody finds.
        local gx = floor(win_w * 0.5) - 7
        local gc = C.text_mute or C.text_disabled
        for i = 0, 2 do
            Core.DrawRect(gx + i * 6, my - 1, 3, 2, gc[1], gc[2], gc[3],
                          (on_seam or mix_seam) and 0.95 or 0.5)
        end

        UI.SetFontCaption()
        for t = 0, TRACKS - 1 do
            local cx = x + scene_w + gap + t * (cell_w + gap)
            drawMix(theme, t, cx, zy + MIX_PAD, cell_w, mix_h - MIX_PAD * 2)
        end
        UI.SetFontBody()
        pollMixDrag()
    end

    UI.Layout.AdvanceCursor(w, head_h + SCENES * (cell_h + gap) + 2 + sh + 4 + zone_h)

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
        if aplay[t] or aqueue[t] then audio_on = true break end
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
    for t = 0, TRACKS - 1 do audioStop(t) audioCancel(t) end
    reapDying()
    -- our sounds leave with us, so the engine's clock must not keep running
    -- for them: a flag that is only ever set is a clock that never stops
    Loop.SetAudioRun(false)
    if state.registered then pcall(DragBus.Unregister, "session") end
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
