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
--   Needs the Looper engine (open CP_Looper once and "Create looper engine").

local r = reaper

-- ---------------------------------------------------------------------------
-- Toolkit + engine
-- ---------------------------------------------------------------------------
local cp_root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
local UI     = dofile(cp_root .. "CP_Toolkit/CP_Toolkit.lua")
local Tracks = dofile(cp_root .. "CP_Engine/Tracks.lua")
local Loop   = dofile(cp_root .. "CP_Engine/Loop.lua")
local Clip   = dofile(cp_root .. "CP_Engine/Clip.lua")
local DragBus = dofile(cp_root .. "CP_Toolkit/DragBus.lua")
local Bus    = dofile(cp_root .. "CP_Engine/Bus.lua")
Tracks.init(r)
Loop.init(r, Tracks)
DragBus.init(r)
Bus.init(r, DragBus, Clip)

local Core = UI.Core
local sin, floor = math.sin, math.floor

-- One track = two engine lanes (playing + silent twin). Track t owns lane t
-- and lane t + TRACKS; the low half is what CP_Looper shows, so a track's
-- "A" buffer is also its Looper lane.
local TRACKS = floor(Loop.MAX_LANES / 2)
if TRACKS > 4 then TRACKS = 4 end
local SCENES = 8

local cells = {}     -- [t][s] = clip descriptor or nil
local cur   = {}     -- [t] = scene whose clip is loaded, or nil
local buf   = {}     -- [t] = 0 | 1, which lane of the pair is the live one
for t = 0, TRACKS - 1 do cells[t] = {}; buf[t] = 0 end

local state = {
    flash_msg = "", flash_until = 0,
    recalled = false,      -- one-shot auto-recall after the first attach
    registered = false,    -- DragBus target registration
    grid = nil,            -- grid geometry (drop hit-testing)
    arow = nil,            -- audio-cell row geometry
    engine_warned = false,
}

local function flash(msg)
    state.flash_msg = msg
    state.flash_until = r.time_precise() + 2.5
end

-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## CP Session
A column per track, a row per scene, one clip per cell. Click a cell
to launch it — QUANTIZED (the Q button), and whatever that track was
playing stops by itself: a track only ever plays one clip. The square
under a column stops that track; the triangle on the left launches a
whole scene (tracks with no clip in that scene stop, as in Ableton).

## Editing
DOUBLE-CLICK any cell — even an empty one — and it opens in CP_Editor,
launched if needed. That is the ONLY way to edit a cell: notes, loop
length, playhead and transport all live there, and edits come back
here live. Right-click a cell for edit / clear / stop.

## Audio row (A)
Drop an audio file from the Media Explorer on an A cell: click loops
it TEMPO-MATCHED (native stretch), measure-aligned when the transport
runs, through the selected track's FX. Interim engine — the
sample-locked one comes later.

## Clock
Free = clips play without the transport. Follow = REAPER transport,
locks to an external MIDI clock when slaved. Record loops in
CP_Looper — it shows the same tracks' live lanes.
]]

-- ---------------------------------------------------------------------------
-- Lane pairing
-- ---------------------------------------------------------------------------
local function liveLane(t) return t + buf[t] * TRACKS end
local function twinLane(t) return t + (1 - buf[t]) * TRACKS end

local function isRunning(lane)
    local m = floor(Loop.Mode(lane) + 0.5)
    return m == 3 or m == 5 or m == 1
end

-- The engine is the truth: whichever twin is playing (or queued) IS the
-- live buffer. Re-deriving it every frame means an outside launch (from
-- CP_Editor, from CP_Looper) can never desync the grid.
local function syncBuffers()
    for t = 0, TRACKS - 1 do
        local la, lb = t, t + TRACKS
        local a_on = isRunning(la) or Loop.Pending(la) == 1
        local b_on = isRunning(lb) or Loop.Pending(lb) == 1
        if b_on and not a_on then buf[t] = 1
        elseif a_on and not b_on then buf[t] = 0 end
    end
end

-- ---------------------------------------------------------------------------
-- Display caches (zero allocation per frame: strings rebuilt only when the
-- underlying fact changes)
-- ---------------------------------------------------------------------------
local track_name = {}   -- [t] = { tr = ptr|false, s = "name" }
local bars_lbl   = {}   -- [bars] = "N bars"
local cell_lbl   = {}   -- [t*SCENES+s] = { src = "name", w = width, s = "cut" }
for t = 0, TRACKS - 1 do track_name[t] = { tr = false, s = "Track " .. (t + 1) } end

local function trackName(t)
    local c = track_name[t]
    local tr = Loop.GetLaneDest(t) or false
    if tr ~= c.tr then
        c.tr = tr
        if tr then
            local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            c.s = (nm and nm ~= "") and nm or ("Track " .. (t + 1))
        else
            c.s = "Track " .. (t + 1)
        end
    end
    return c.s
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

-- Launch-quantize label, cached on the raw q value (same cycle as the
-- Looper's toolbar button).
local qlbl = { q = -1, s = "" }
local function qLabel()
    local q = Loop.GetLaunchQ()
    if q ~= qlbl.q then
        qlbl.q = q
        local tsn = Loop.TsNum()
        if q <= 0 then qlbl.s = "Q: Off"
        elseif q == 1 then qlbl.s = "Q: Beat"
        elseif q == tsn then qlbl.s = "Q: Bar"
        elseif q == tsn * 2 then qlbl.s = "Q: 2 bars"
        elseif q == tsn * 4 then qlbl.s = "Q: 4 bars"
        else qlbl.s = "Q: " .. q .. " beats" end
    end
    return qlbl.s
end

local function cycleQ()
    local q, tsn = Loop.GetLaunchQ(), Loop.TsNum()
    local nq
    if q <= 0 then nq = 1
    elseif q == 1 then nq = tsn
    elseif q == tsn then nq = tsn * 2
    elseif q == tsn * 2 then nq = tsn * 4
    else nq = 0 end
    Loop.SetLaunchQ(nq)
    qlbl.q = -1
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
local function armLane(lane, c)
    Loop.ApplyClip(lane, c)
    Loop.SetLengthBars(lane, cellBars(c))
    if cellNotes(c) > 0 and floor(Loop.Mode(lane) + 0.5) == 0 then
        Loop.SetMode(lane, 2)
    end
end

local function stopTrack(t)
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
    if not c or cellNotes(c) == 0 then
        flash("Empty cell — double-click to write something in it")
        return
    end
    local live = liveLane(t)
    local busy = isRunning(live) or Loop.Pending(live) == 1
    if cur[t] == s then
        -- clicking the clip that is already queued to STOP takes it back
        if Loop.Pending(live) == 2 then Loop.Play(live) return end
        if busy then stopTrack(t) return end
        armLane(live, c)
        Loop.Play(live)
        return
    end
    if not busy then
        -- nothing to swap: load the live lane directly. This also keeps
        -- ordinary use on the low lanes — the ones CP_Looper shows.
        armLane(live, c)
        Loop.Play(live)
        cur[t] = s
        return
    end
    local twin = twinLane(t)
    armLane(twin, c)
    Loop.Play(twin)         -- queued to the next boundary…
    Loop.StopClip(live)     -- …and the outgoing one leaves on the same one
    buf[t] = 1 - buf[t]
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
    local lane
    if cur[t] == s and isRunning(liveLane(t)) then
        lane = liveLane(t)
    else
        lane = twinLane(t)
        armLane(lane, c)
    end
    c.origin = "looper:" .. lane
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
        if cur[t] == s then
            local live = liveLane(t)
            Loop.ApplyClip(live, ac)
            if ac.bars and ac.bars > 0 then Loop.SetLengthBars(live, ac.bars) end
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

local function clearCell(t, s)
    if not cells[t][s] then return end
    cells[t][s] = nil
    saveGrid()
    if cur[t] == s then
        stopTrack(t)
        cur[t] = nil
    end
end

local function cellMenu(t, s)
    UI.NativeMenu({
        { label = "Edit in CP_Editor", action = function() editCell(t, s) end },
        { label = "Stop this track", action = function() stopTrack(t) end },
        { separator = true },
        { label = "Clear cell", action = function() clearCell(t, s) end },
    })
end

-- ---------------------------------------------------------------------------
-- Audio cells (interim engine, spec P3): one CF_Preview per cell, tempo-
-- matched playrate (the native ME's GetTempoMatchPlayRate), looped,
-- measure-aligned start when the transport runs. Output goes through the
-- first SELECTED track (its FX) or the default hardware out. The sample-
-- locked JSFX engine is P4 — this is the "good enough to jam" face.
-- ---------------------------------------------------------------------------
local ACELLS = 4
local acell = {}   -- [i] = { path, name, src, prev, rate }
for i = 1, ACELLS do acell[i] = {} end
local HAS_CF = r.CF_CreatePreview ~= nil

local function acellStop(i)
    local c = acell[i]
    if c.prev then pcall(r.CF_Preview_Stop, c.prev) end
    c.prev = nil
end

-- Load (or clear with nil) a cell's file; persisted per project.
local function acellLoad(i, path)
    local c = acell[i]
    acellStop(i)
    if c.src then r.PCM_Source_Destroy(c.src) end
    c.src, c.path, c.name = nil, nil, nil
    if path and path ~= "" then
        local src = r.PCM_Source_CreateFromFile(path)
        if src then
            c.src, c.path = src, path
            c.name = path:match("([^/\\]+)$") or path
        end
    end
    r.SetProjExtState(0, "CP_Session", "audio" .. i, c.path or "")
end

local function acellToggle(i)
    local c = acell[i]
    if c.prev then acellStop(i) return end
    if not c.src then return end
    if not HAS_CF then flash("Audio cells need the SWS extension") return end
    local prev = r.CF_CreatePreview(c.src)
    if not prev then return end
    local ok, _, rate = pcall(r.GetTempoMatchPlayRate, c.src, 1.0, 0, 1.0)
    c.rate = (ok and rate and rate > 0.05 and rate < 20) and rate or 1.0
    r.CF_Preview_SetValue(prev, "D_VOLUME", 1)
    if c.rate ~= 1.0 then
        r.CF_Preview_SetValue(prev, "D_PLAYRATE", c.rate)
        r.CF_Preview_SetValue(prev, "B_PPITCH", 1)
    end
    r.CF_Preview_SetValue(prev, "B_LOOP", 1)
    if (r.GetPlayState() & 1) == 1 then
        -- transport runs: land on the next measure (native ME semantics);
        -- free-running has no measure to align to — immediate start
        r.CF_Preview_SetValue(prev, "D_MEASUREALIGN", 1)
    end
    local tr = r.GetSelectedTrack(0, 0)
    if tr and r.CF_Preview_SetOutputTrack then
        r.CF_Preview_SetOutputTrack(prev, 0, tr)
    end
    r.CF_Preview_Play(prev)
    c.prev = prev
end

-- restore what was saved with the project
for i = 1, ACELLS do
    local _, p = r.GetProjExtState(0, "CP_Session", "audio" .. i)
    if p and p ~= "" then acellLoad(i, p) end
end
loadGrid()

-- ---------------------------------------------------------------------------
-- DragBus: an audio file over the A row loads that cell; a MIDI clip over
-- a grid cell fills that cell (it does NOT launch — dropping is not playing).
-- ---------------------------------------------------------------------------
local function busConsume()
    if not state.registered then
        state.registered = DragBus.Register("session")
    end
    DragBus.RectSync("session")
    local clip, sx, sy = Bus.TakeDrop("session")
    if not clip then return end
    local cx, cy = Core.ScreenToClient(sx, sy)
    local ar = state.arow
    if clip.kind == "audio" and clip.path and ar
       and cy >= ar.y and cy < ar.y + ar.h and cx >= ar.x0 then
        local i = floor((cx - ar.x0) / (ar.cw + ar.gap)) + 1
        if i >= 1 and i <= ACELLS then
            acellLoad(i, clip.path)
            flash("Audio cell " .. i .. ": " .. (acell[i].name or "?"))
        end
        return
    end
    local g = state.grid
    if clip.kind == "midi" and clip.notes and g
       and cx >= g.x0 and cy >= g.y0 then
        local t = floor((cx - g.x0) / (g.cw + g.gap))
        local s = floor((cy - g.y0) / (g.ch + g.gap))
        if t >= 0 and t < TRACKS and s >= 0 and s < SCENES then
            clip.cell = t .. "," .. s
            cells[t][s] = clip
            saveGrid()
            flash("Clip -> " .. trackName(t) .. " / scene " .. (s + 1))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
local function drawCell(theme, t, s, x, y, w, h)
    local C = theme.colors
    local c = cells[t][s]
    local rad = theme.rounding_small or theme.rounding or 0
    local live = liveLane(t)
    local is_cur = (cur[t] == s)
    local mode = is_cur and floor(Loop.Mode(live) + 0.5) or 0
    local pend = is_cur and Loop.Pending(live) or 0
    local playing = is_cur and (mode == 3 or mode == 5)

    local br, bg_, bb = 0.15, 0.15, 0.17
    if playing then
        local a = C.accent
        br, bg_, bb = a[1] * 0.45, a[2] * 0.45, a[3] * 0.45
    elseif c then
        br, bg_, bb = 0.21, 0.21, 0.24
    end
    Core.DrawRoundRectFilled(x, y, w, h, rad, br, bg_, bb, 1)

    if c then
        -- queued launch / stop blinks, exactly as in the Looper
        if pend == 1 or pend == 2 then
            local a = 0.45 + 0.55 * math.abs(sin(r.time_precise() * 5))
            local pc = (pend == 2) and C.text or C.accent
            Core.DrawRect(x, y, w, h, pc[1], pc[2], pc[3], a, false)
            UI.RequestRedraw()
        end
        if playing then
            local ph = Loop.Phase(live)
            local L  = Loop.LenBeats(live)
            local a = C.accent
            if L > 0 then
                Core.DrawRect(x + 2, y + h - 4, (w - 4) * (ph / L), 2,
                              a[1], a[2], a[3], 0.9)
            end
            UI.RequestRedraw()
        end
        local tc = C.text
        local nm = (c.name and c.name ~= "") and c.name or "clip"
        Core.DrawText(cellLabel(t, s, nm, w - 10), x + 5, y + 3,
                      tc[1], tc[2], tc[3], 0.95)
        UI.SetFontCaption()
        local mc = C.text_mute or C.text_disabled
        Core.DrawText(barsLabel(cellBars(c)), x + 5, y + h - 13,
                      mc[1], mc[2], mc[3], 0.85)
        UI.SetFontBody()
    end

    if Core.MouseInRect(x, y, w, h) and not Core.HasPopup() then
        Core.DrawRect(x, y, w, h, 1, 1, 1, 0.05)
        if Core.MouseDoubleClicked() then
            editCell(t, s)
        elseif Core.MouseClicked(1) then
            launchCell(t, s)
        elseif Core.MouseClicked(2) then
            cellMenu(t, s)
        end
    end
end

-- Audio cell: name + phase sweep, click = loop/stop.
local function drawAudioCell(theme, i, x, y, w, h)
    local C = theme.colors
    local c = acell[i]
    local playing = c.prev ~= nil
    local rad = theme.rounding_small or theme.rounding or 0
    local br, bg_, bb = 0.15, 0.15, 0.17
    if playing then
        local a = C.accent
        br, bg_, bb = a[1] * 0.4, a[2] * 0.4, a[3] * 0.4
    elseif c.path then
        br, bg_, bb = 0.19, 0.19, 0.22
    end
    Core.DrawRoundRectFilled(x, y, w, h, rad, br, bg_, bb, 1)
    local tc = C.text
    local mc = C.text_mute or C.text_disabled
    if c.path then
        Core.DrawText(cellLabel(TRACKS + i, 0, c.name or "?", w - 10), x + 5, y + 4,
                      tc[1], tc[2], tc[3], 0.9)
        if playing then
            local ok, rv, pos = pcall(r.CF_Preview_GetValue, c.prev, "D_POSITION")
            local ok2, rv2, len = pcall(r.CF_Preview_GetValue, c.prev, "D_LENGTH")
            if ok and rv and ok2 and rv2 and len and len > 0 then
                local a = C.accent
                Core.DrawRect(x + 2, y + h - 4, (w - 4) * ((pos % len) / len), 2,
                              a[1], a[2], a[3], 0.9)
            end
            UI.RequestRedraw()
        end
    else
        Core.DrawText("drop audio", x + 5, y + 4, mc[1], mc[2], mc[3], 0.7)
    end
    if Core.MouseInRect(x, y, w, h) and not Core.HasPopup() then
        Core.DrawRect(x, y, w, h, 1, 1, 1, 0.05)
        if Core.MouseClicked(1) and c.path then
            acellToggle(i)
        elseif Core.MouseClicked(2) and c.path then
            UI.NativeMenu({
                { label = "Clear cell", action = function() acellLoad(i, nil) end },
            })
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

    -- toolbar
    UI.SetFontH2()
    UI.Text("Session")
    UI.SetFontBody()
    UI.SameLine(12)
    if attached then
        if UI.Button("clock", Loop.GetFreeRun() and "Clock: Free" or "Clock: Follow") then
            Loop.SetFreeRun(not Loop.GetFreeRun())
        end
        UI.SameLine()
        if UI.Button("q", qLabel()) then cycleQ() end
        UI.SameLine()
        if UI.Button("stopall", "Stop all") then stopAll() end
        UI.SameLine()
        if UI.Button("panic", "Panic") then Loop.Panic() end
        UI.SameLine()
        UI.HelpButton("help", HELP_TEXT)
    end
    UI.Spacing(4)

    if not attached then
        UI.SetFontCaption()
        UI.TextWrapped("No looper engine in this project yet. Open CP_Looper once and click \"Create looper engine\" — this window reconnects by itself.")
        UI.SetFontBody()
        return
    end

    -- The grid needs two lanes per track. A project whose chain still holds
    -- an older engine would swallow every write to the upper lanes, so say
    -- so ONCE instead of failing silently.
    if Loop.EngineLanes() < TRACKS * 2 and not state.engine_warned then
        state.engine_warned = true
        flash("Engine is older than this grid — click Reload in CP_Looper")
    end

    syncBuffers()

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

    -- ---- track headers: name + a stop square
    UI.SetFontCaption()
    for t = 0, TRACKS - 1 do
        local cx = x + scene_w + gap + t * (cell_w + gap)
        local mc = C.text_mute or C.text_disabled
        Core.DrawText(cellLabel(t, SCENES, trackName(t), cell_w - 20), cx + 2, y + 2,
                      mc[1], mc[2], mc[3], 0.9)
        -- stop square (a track-wide gesture, the Ableton column footer moved up)
        local sq = 9
        local sx2 = cx + cell_w - sq - 2
        -- filled while the track plays (there is something to stop),
        -- outlined when it is silent
        local running = isRunning(liveLane(t))
        Core.DrawRect(sx2, y + 4, sq, sq,
                      mc[1], mc[2], mc[3], running and 0.85 or 0.35, running)
        if Core.MouseInRect(sx2 - 2, y, sq + 4, head_h) and not Core.HasPopup() then
            if Core.MouseClicked(1) then stopTrack(t) end
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
        UI.DrawTriangle(x + 8, cy + cell_h * 0.5 - 5, x + 8, cy + cell_h * 0.5 + 5,
                        x + 17, cy + cell_h * 0.5, a[1], a[2], a[3], 0.85)
        if Core.MouseInRect(x, cy, scene_w, cell_h) and not Core.HasPopup() then
            Core.DrawRect(x, cy, scene_w, cell_h, 1, 1, 1, 0.06)
            if Core.MouseClicked(1) then sceneLaunch(s) end
        end
        for t = 0, TRACKS - 1 do
            local cx = x + scene_w + gap + t * (cell_w + gap)
            drawCell(theme, t, s, cx, cy, cell_w, cell_h)
        end
    end

    -- ---- audio row (interim engine)
    local ay = gy + SCENES * (cell_h + gap) + 6
    local ah = 26
    UI.SetFontCaption()
    do
        local mc = C.text_mute or C.text_disabled
        Core.DrawText("A", x + 9, ay + floor(ah / 2) - 6, mc[1], mc[2], mc[3], 0.8)
    end
    state.arow = state.arow or {}
    state.arow.x0, state.arow.y = x + scene_w + gap, ay
    state.arow.cw, state.arow.gap, state.arow.h = cell_w, gap, ah
    for i = 1, ACELLS do
        local cx = x + scene_w + gap + (i - 1) * (cell_w + gap)
        if i <= TRACKS then
            drawAudioCell(theme, i, cx, ay, cell_w, ah)
        end
    end
    UI.SetFontBody()
    UI.Layout.AdvanceCursor(w, head_h + SCENES * (cell_h + gap) + 6 + ah + 4)

    -- status
    UI.SetFontCaption()
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            UI.Text(state.flash_msg, { disabled = true })
        else
            state.flash_msg = ""
        end
    else
        UI.Text("Click = launch (one clip per track) · double-click = edit in CP_Editor · triangle = scene",
                { disabled = true })
    end
    UI.SetFontBody()

    if Loop.Playing() then UI.RequestRedraw() end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("CP Session", 580, 400, {
    persist    = "CP_Session",
    scrollable = false,
})

UI.OnClose(function()
    for i = 1, ACELLS do
        acellStop(i)
        if acell[i].src then r.PCM_Source_Destroy(acell[i].src) end
        acell[i].src = nil
    end
    if state.registered then pcall(DragBus.Unregister, "session") end
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
