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
loops TEMPO-MATCHED (native stretch) through that column's track. Drop
or write MIDI and it plays through the engine.

A sound plays THROUGH the column's track — its fader, its FX, and so
into the master and into anything you record. When that track holds an
instrument it cannot take audio (a synth replaces its input with its
own output), so the sound goes to the nearest thing downstream that
can: the folder it lives in, or the master.

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
SLOT opens CP_FX Browser (raised if it is running, started if not).
When the chain is longer than the slots on screen, the thin bar on the
right says so and the wheel walks it.

SENDS. Each row is the send itself: drag it to set its level, right-
click to mute or remove it. To create one, drag an EMPTY SLOT onto the
column you want to send TO — the gesture says from here to there.
Clicking it instead lists the destinations.

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
-- A sound cell lives in the SAME two states a MIDI clip does, because a track
-- has the same two halves whatever it plays: one sounding, one waiting for the
-- boundary. aplay is the live half, aqueue the twin — and every gesture below
-- is written against that pair so a sound answers a click exactly as a clip
-- does: launches queued, stops queued, swaps landing on one boundary, and a
-- second click taking back whichever of the two is still only queued.
local aplay  = {}  -- [t] = { s, c, at, prev, src, stop_at }  the sound heard
local aqueue = {}  -- [t] = { s, c, at }                      the sound waiting

local function audioStop(t)
    local a = aplay[t]
    if not a then return end
    if a.prev then pcall(r.CF_Preview_Stop, a.prev) end
    if a.src then r.PCM_Source_Destroy(a.src) end
    aplay[t] = nil
end

local function audioCancel(t) aqueue[t] = nil end

-- Give the preview back without forgetting the cell: what the transport took
-- away it can give back. Used when the clock follows a transport that stopped.
local function audioRelease(a)
    if not a then return end
    if a.prev then pcall(r.CF_Preview_Stop, a.prev) end
    if a.src then r.PCM_Source_Destroy(a.src) end
    a.prev, a.src, a.at, a.stop_at = nil, nil, nil, nil
end

-- WHERE A LAUNCH LANDS, on the engine's own clock (host beat when following,
-- the free clock otherwise). This is the JSFX's rule, copied on purpose: a
-- position within 0.05 beat past a boundary counts as ON it, anything else
-- waits for the next one. A sound and a MIDI clip launched together must land
-- together, and they only do if they answer the same question the same way.
local Q_SLOP = 0.05
local function launchBeat()
    local pb = Loop.EngineBeat()
    local q = Loop.GetLaunchQ() or 0
    if q <= 0.001 then return pb end
    local qph = pb - floor(pb / q) * q
    if qph < Q_SLOP then return pb - qph end
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

-- Actually make the sound, at the beat we have REACHED — which is a hair past
-- the boundary we aimed at, because a frame is 16 ms wide. Starting there and
-- then would leave the sound late by that hair for as long as it loops, so the
-- overshoot is taken off the FRONT of the sample instead: the clip lands in
-- phase, at the cost of a few ms of attack nobody hears. (A jump in the
-- transport can make the overshoot enormous; past a quarter second it is not
-- an overshoot any more, and the clip starts whole.)
local function audioStart(t, beat)
    local a = aplay[t]
    if not a or a.prev then return end
    local c = a.c
    local src = r.PCM_Source_CreateFromFile(c.path)
    if not src then flash("Cannot open: " .. (c.path or "?")) aplay[t] = nil return end
    local prev = r.CF_CreatePreview(src)
    -- drop the cell rather than leave it armed: a start that cannot succeed
    -- would be retried on every frame, disk open included
    if not prev then r.PCM_Source_Destroy(src) aplay[t] = nil return end
    -- HOW FAST. The clip's own announced tempo wins when it carries one;
    -- otherwise the SAME routine the browser used to audition this file
    -- decides. Two windows disagreeing about how fast a file is was one of the
    -- ways a sound could be in time in the arrange and out of it here: the
    -- browser falls back to the BPM written in the filename when REAPER's
    -- tempo-match declines to guess, and this window did not.
    local rt
    if c.src_bpm and c.src_bpm > 0 then
        local pb = r.Master_GetTempo()
        rt = (pb and pb > 0) and (pb / c.src_bpm) or 1.0
    else
        rt = Preview.TempoSyncRate(c.path, 1.0)
    end
    if not (rt and rt > 0.05 and rt < 20) then rt = 1.0 end
    r.CF_Preview_SetValue(prev, "D_VOLUME", 1)
    if rt ~= 1.0 then
        r.CF_Preview_SetValue(prev, "D_PLAYRATE", rt)
        r.CF_Preview_SetValue(prev, "B_PPITCH", 1)
    end
    r.CF_Preview_SetValue(prev, "B_LOOP", 1)
    -- A few milliseconds of fade at the start: SWS opens on a raw sample edge,
    -- which clicks on anything that does not begin at zero — and it is also
    -- what makes the one corrective seek below inaudible.
    r.CF_Preview_SetValue(prev, "D_FADEINLEN", FADE_IN)
    -- No D_MEASUREALIGN. It holds EVERY loop pass to the bar grid, not only the
    -- first, so a sample that is not exactly N measures long waits at the end
    -- of each pass — the gap between two instances. And it can only align to a
    -- MEASURE, which is why a sound ignored the Q while every MIDI clip obeyed
    -- it. The boundary is ours to pick now (launchBeat), on the engine's clock
    -- and by the engine's rule, so the launch is quantized and the loop runs.
    -- Route it through a TRACK, always. A preview with no output track goes
    -- straight to the hardware: not through the column's fader, not through
    -- the master, not into anything you record — the sound is audible and
    -- nowhere. previewDest finds the nearest thing downstream that can take
    -- audio, which for an ordinary column is the column's own track.
    local tr = previewDest(Loop.GetLaneDest(t))
    if tr and r.CF_Preview_SetOutputTrack then
        r.CF_Preview_SetOutputTrack(prev, 0, tr)
    end

    -- No D_MEASUREALIGN. It holds EVERY loop pass to the bar grid, not only the
    -- first, so a sample that is not exactly N measures long waits at the end
    -- of each pass — the gap between two instances. And it can only align to a
    -- MEASURE, which is why a sound ignored the Q while every MIDI clip obeyed
    -- it. The boundary is ours to pick now (launchBeat), on the engine's clock
    -- and by the engine's rule, so the launch is quantized and the loop runs.
    a.rt   = rt
    a.slen = r.GetMediaSourceLength(src)
    a.pdc  = tr and chainLatency(tr) or 0
    -- The position is a FORMULA from here on, not a one-off calculation: it
    -- started at the boundary and has run at `rt` ever since. lockPhase holds
    -- the preview to it, so what follows is only a good first guess.
    a.t0   = (not Loop.GetFreeRun()) and r.TimeMap2_QNToTime(0, a.at or 0) or nil
    a.lock = 0
    a.settled = false

    local skip = 0
    if a.at then
        if a.t0 then
            -- PROJECT TIME against the position the audio thread is about to
            -- render — GetPlayPosition2, not GetPlayPosition — plus half a
            -- block (the preview is picked up on the next one) and the chain's
            -- own latency.
            local p = r.GetPlayPosition2()
            if p then skip = (p - a.t0 + blockSlack() + a.pdc) * rt end
        else
            local tempo = Loop.Tempo()
            if beat and tempo and tempo > 1 then
                skip = (beat - a.at) * (60 / tempo) * rt
            end
        end
    end
    if skip < 0 or skip > 0.25 then skip = 0 end
    if skip > 0 then r.CF_Preview_SetValue(prev, "D_POSITION", skip) end

    r.CF_Preview_Play(prev)
    a.prev, a.src = prev, src
end

-- PHASE LOCK. Everything before this computed the start and hoped: how late
-- the call was, what the buffer did with it, whether the tempo match made a
-- loop of exactly the right length. Hope is not a clock — so the position is
-- now DERIVED from the transport on every pass and put back when it drifts:
--
--    position = ((play_position - launch_boundary) * rate) mod source_length
--
-- Nothing in that line can be late. The first check runs on the frame after
-- the launch with a 4 ms tolerance, which is where the whole start-up latency
-- lands and where correcting it is inaudible (a few ms into the attack, and
-- the preview fades in over 3). After that it is a drift watch: half a second
-- apart, 30 ms of slack, so a loop whose tempo match is a hair off is pulled
-- back onto the grid instead of walking away from it.
local function lockPhase(a, now)
    if not a.t0 or not a.slen or a.slen <= 0 or not a.prev then return end
    if now < a.lock then return end
    local p = r.GetPlayPosition2()
    if not p then return end
    -- + the chain's latency: the sample handed over now is the one that has to
    -- be HEARD after that delay, so the clip must already be that far ahead
    local want = (p - a.t0 + (a.pdc or 0)) * a.rt
    if want < 0 then return end
    want = want % a.slen
    local ok, rv, pos = pcall(r.CF_Preview_GetValue, a.prev, "D_POSITION")
    if not (ok and rv and pos) then return end
    local err = want - pos
    local half = a.slen * 0.5
    if err > half then err = err - a.slen elseif err < -half then err = err + a.slen end
    local tol = a.settled and 0.030 or 0.004
    if err > tol or err < -tol then
        pcall(r.CF_Preview_SetValue, a.prev, "D_POSITION", want)
    end
    a.settled = true
    a.lock = now + 0.5
end

-- Is the clock RUNNING? Free run has its own, which never stops; following
-- means there is nothing to follow until the transport rolls.
local function clockRolling()
    if Loop.GetFreeRun() then return true end
    return (r.GetPlayState() & 1) == 1
end

-- The waiting half becomes the sounding one. Whatever the track was playing
-- leaves in the SAME call, so the swap is one boundary and not two.
local function audioFire(t, beat)
    local q = aqueue[t]
    if not q then return end
    if aplay[t] then audioStop(t) end
    aqueue[t] = nil
    aplay[t] = q
    audioStart(t, beat)
end

-- Queue a launch. It is ARMED here and fires on the Q boundary, exactly as a
-- MIDI clip is queued and fires on the boundary — with the clock following a
-- STOPPED transport there is no beat to land on, so it simply waits for one.
local function audioArm(t, s, c)
    if not HAS_CF then flash("Audio cells need the SWS extension") return end
    local q = { s = s, c = c }
    aqueue[t] = q
    -- Q: Off means NOW, and now is this frame — waiting for the next poll
    -- would put a frame of silence under every unquantized launch.
    if clockRolling() then
        q.at = launchBeat()
        local beat = Loop.EngineBeat()
        if beat >= q.at then audioFire(t, beat) end
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
local function pollAudio()
    local rolling = clockRolling()
    local beat = rolling and Loop.EngineBeat() or 0
    local now  = r.time_precise()
    for t = 0, TRACKS - 1 do
        local a, q = aplay[t], aqueue[t]
        if not rolling then
            if a then
                -- it becomes a sound WAITING, which is what it now is — unless
                -- a launch was already queued over it (the newer word), or it
                -- was on its way out anyway, in which case the transport
                -- stopping is simply where it goes
                local leaving = a.stop_at ~= nil
                audioRelease(a)
                if not q and not leaving then aqueue[t] = a end
                aplay[t] = nil
            end
            local w = aqueue[t]
            if w then w.at = nil end
        else
            if a and a.stop_at and beat >= a.stop_at then
                audioStop(t)
                a = nil
            end
            if q then
                if not q.at then q.at = launchBeat() end
                if beat >= q.at then audioFire(t, beat) end
            end
            -- and whatever is sounding is kept ON the transport, not merely
            -- started on it
            local live = aplay[t]
            if live and live.prev then lockPhase(live, now) end
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
            aqueue[t] = nil                       -- cancel the queued launch…
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
    if audio then
        -- The two halves say exactly what the engine's two say: a queued
        -- launch is pending 1, a queued stop pending 2, and a sound whose
        -- preview the transport took back is queued again — same states, same
        -- colours, whatever kind of thing the cell holds.
        local a, q = aplay[t], aqueue[t]
        playing = (a ~= nil and a.s == s and a.prev ~= nil)
        if q and q.s == s then pend = 1
        elseif a and a.s == s then
            if a.stop_at then pend = 2
            elseif not a.prev then pend = 1 end
        end
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
local MIX_ROW   = 15       -- one slot
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
    items[#items + 1] = { label = "Add FX… (opens the track's chain)",
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
        Core.DrawText(label, x + 7, iy + 1, ink[1], ink[2], ink[3], dim and 0.6 or 0.95)
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
                -- console: it opens the browser. CP_FXBrowser is that browser
                -- here — raised if it runs, started if it does not.
                slotRow(theme, x, ly, rw, nil, true, false, hot, true)
                if hot then
                    over_fx = row
                    if Core.MouseClicked(1) then
                        if not Bus.FocusApp("CP_FXBrowser", "FX Browser") then
                            r.TrackFX_Show(tr, 0, 1)   -- no browser: REAPER's own
                        end
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
                local ch, nv, rel = UI.FaderAt(mix_id.sd[t][i], x + 1, ly + 1,
                                               rw - 2, MIX_ROW - 2, lvl or 0,
                                               MIX_SD_OPTS)
                if ch then Mix.SetSendNorm(tr, i, nv) mix_moved = true end
                if rel then
                    if mix_moved then Mix.CommitSend() end
                    mix_moved = false
                end
                Core.DrawText(fitLabel(sd_lbl[t][row], nm or "send", rw - 10),
                              x + 5, ly + 2, C.text[1], C.text[2], C.text[3], 0.95)
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
                        free and "Free run: clips launch with the transport stopped"
                              or "Following the host transport") then
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
    if state.registered then pcall(DragBus.Unregister, "session") end
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
