-- @description Session (CP) — clip-grid view over the CP Looper engine
-- @version 0.1 (P1)
-- @author Cedric Pamalio
-- @about
--   The Ableton-style session grid, phase 1: one column per Looper lane,
--   one clip cell each. Cells launch and stop QUANTIZED through the same
--   engine the Looper drives (gmem CP_MidiLooper) — this window adds no
--   engine of its own, it is another face on loops that already run.
--   Click a cell to launch/stop; right-click for Edit-in-CP_Editor, mute,
--   clear; the scene button fires every non-empty lane together.
--
--   Needs the Looper engine to exist (open CP_Looper once and "Create
--   looper engine"); after that this window reconnects on its own.

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

local LANES = Loop.MAX_LANES

local state = {
    flash_msg = "", flash_until = 0,
    recalled = false,      -- one-shot auto-recall after the first attach
    registered = false,    -- DragBus target registration
    lrow = nil,            -- lane-cell row geometry (drop hit-testing)
    arow = nil,            -- audio-cell row geometry
}

local function flash(msg)
    state.flash_msg = msg
    state.flash_until = r.time_precise() + 2.5
end

-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## CP Session
The clip grid over the Looper engine: one column per lane. Click a
cell to launch or stop it QUANTIZED (the Q button; the cell blinks
while queued). DOUBLE-CLICK any cell — even empty — and it opens in
CP_Editor (launched if needed); edits come back live. The triangle
launches every full cell together. Right-click: edit / mute / clear.

## Audio row (A)
Drop an audio file from the Media Explorer on an A cell: click loops
it TEMPO-MATCHED (native stretch), measure-aligned when the
transport runs, through the selected track's FX. Interim engine —
the sample-locked one comes later.

## Clock
Free = clips play without the transport. Follow = REAPER transport,
locks to an external MIDI clock when slaved. Record and route lanes
in CP_Looper — both windows are faces on the same engine.
]]

-- ---------------------------------------------------------------------------
-- Per-lane display caches (zero allocation per frame: strings rebuilt only
-- when the underlying fact changes)
-- ---------------------------------------------------------------------------
local lane_name = {}   -- [lane] = { tr = track_ptr_or_false, s = "name" }
local bars_lbl  = {}   -- [bars] = "N bars"
for l = 0, LANES - 1 do lane_name[l] = { tr = false, s = "Lane " .. (l + 1) } end

local function laneName(lane)
    local c = lane_name[lane]
    local tr = Loop.GetLaneDest(lane) or false
    if tr ~= c.tr then
        c.tr = tr
        if tr then
            local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            c.s = (nm and nm ~= "") and nm or ("Lane " .. (lane + 1))
        else
            c.s = "Lane " .. (lane + 1)
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
-- Cell actions
-- ---------------------------------------------------------------------------
-- The universal edit gesture: even an empty cell opens (as a blank clip)
-- in CP_Editor — Bus.OpenEditor LAUNCHES the editor if it isn't running.
local function editInEditor(lane)
    local c = Loop.LaneToClip(lane)
    if not c then
        c = Clip.new("midi")
        c.notes = { s = {}, l = {}, p = {}, v = {} }
        c.bars = Loop.GetLengthBars(lane)
    end
    c.origin = "looper:" .. lane
    c.name = laneName(lane)
    Bus.OpenEditor(c)
    flash("Cell opened in CP_Editor")
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

-- restore the cells saved with the project
for i = 1, ACELLS do
    local _, p = r.GetProjExtState(0, "CP_Session", "audio" .. i)
    if p and p ~= "" then acellLoad(i, p) end
end

-- ---------------------------------------------------------------------------
-- DragBus: drops from the Media Explorer / other CP windows. An audio
-- file over the audio row loads that cell; a MIDI clip over a lane cell
-- loads that lane.
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
        local i = math.floor((cx - ar.x0) / (ar.cw + ar.gap)) + 1
        if i >= 1 and i <= ACELLS then
            acellLoad(i, clip.path)
            flash("Audio cell " .. i .. ": " .. (acell[i].name or "?"))
            return
        end
    end
    local lr = state.lrow
    if clip.kind == "midi" and clip.notes and lr
       and cy >= lr.y and cy < lr.y + lr.h and cx >= lr.x0 then
        local l = math.floor((cx - lr.x0) / (lr.cw + lr.gap))
        if l >= 0 and l < LANES then
            Loop.ClipToLane(l, clip)
            flash("Clip -> " .. laneName(l))
        end
    end
end

local function cellMenu(lane)
    UI.NativeMenu({
        { label = "Edit in CP_Editor", action = function() editInEditor(lane) end },
        { label = "Mute", checked = Loop.GetMute(lane),
          action = function() Loop.SetMute(lane, not Loop.GetMute(lane)) end },
        { separator = true },
        { label = "Clear cell", action = function() Loop.Clear(lane) end },
    })
end

-- Scene: launch every non-empty stopped lane (they land together on the
-- next quantize boundary); the stop square halts every playing one.
local function sceneLaunch()
    for l = 0, LANES - 1 do
        if Loop.HasContent(l) and Loop.Mode(l) == 2 then Loop.Play(l) end
    end
end

local function sceneStop()
    for l = 0, LANES - 1 do
        local m = Loop.Mode(l)
        if m == 3 or m == 5 then Loop.StopClip(l) end
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------
local sin, floor = math.sin, math.floor

local function drawCell(theme, lane, x, y, w, h)
    local C = theme.colors
    local mode = Loop.Mode(lane)        -- 0 empty 1 rec 2 stopped 3 play 4 armed 5 overdub
    local has  = Loop.HasContent(lane)
    local pend = Loop.Pending(lane)     -- 0 none 1 play 2 stop 3 rec 4 stoprec 5 ovr
    local muted = Loop.GetMute(lane)
    local rad = theme.rounding or 0

    -- surface by state
    local br, bg_, bb, ba = 0.16, 0.16, 0.18, 1
    if mode == 1 or mode == 5 then
        local d = C.danger
        br, bg_, bb = d[1] * 0.55, d[2] * 0.35, d[3] * 0.35
    elseif mode == 3 then
        local a = C.accent
        br, bg_, bb = a[1] * 0.45, a[2] * 0.45, a[3] * 0.45
    elseif has then
        br, bg_, bb = 0.21, 0.21, 0.24
    end
    Core.DrawRoundRectFilled(x, y, w, h, rad, br, bg_, bb, ba)

    -- pending blink frame (queued launch/stop — same language as the Looper)
    if pend > 0 then
        local a = 0.45 + 0.55 * math.abs(sin(r.time_precise() * 5))
        local pc = (pend == 2 or pend == 4) and C.text or C.accent
        Core.DrawRect(x, y, w, h, pc[1], pc[2], pc[3], a, false)
    end

    -- phase sweep while playing / capturing
    if mode == 3 or mode == 1 or mode == 5 then
        local ph = Loop.Phase(lane)
        local a = C.accent
        Core.DrawRect(x + 2, y + h - 5, (w - 4) * ph, 3, a[1], a[2], a[3], 0.9)
    end

    -- labels: name + length (or state word)
    local tc = C.text
    -- parens: TruncateText returns (text, width) — only the text goes here
    Core.DrawText((Core.TruncateText(laneName(lane), w - 12)), x + 6, y + 5,
                  tc[1], tc[2], tc[3], muted and 0.4 or 0.95)
    UI.SetFontCaption()
    local sub
    if mode == 1 then sub = "REC"
    elseif mode == 5 then sub = "OVER"
    elseif mode == 4 then sub = "ARM"
    elseif has then sub = barsLabel(Loop.GetLengthBars(lane))
    else sub = "empty" end
    local mc = C.text_mute or C.text_disabled
    Core.DrawText(sub, x + 6, y + 21, mc[1], mc[2], mc[3], 0.9)
    if muted then
        Core.DrawText("M", x + w - 16, y + 5, tc[1], tc[2], tc[3], 0.5)
    end
    UI.SetFontBody()

    -- pending blink and phase sweep move on their own — keep drawing
    if pend > 0 or mode == 1 or mode == 3 or mode == 5 then
        UI.RequestRedraw()
    end

    -- interaction: click = launch/stop, double-click = THE editor
    if Core.MouseInRect(x, y, w, h) and not Core.HasPopup() then
        Core.DrawRect(x, y, w, h, 1, 1, 1, 0.05)
        if Core.MouseDoubleClicked() then
            editInEditor(lane)
        elseif Core.MouseClicked(1) then
            if has or mode == 3 or mode == 5 then
                Loop.ToggleClip(lane)
            end
        elseif Core.MouseClicked(2) then
            cellMenu(lane)
        end
    end
end

-- Audio cell: name + rate tag, phase sweep, click = loop/stop.
local function drawAudioCell(theme, i, x, y, w, h)
    local C = theme.colors
    local c = acell[i]
    local playing = c.prev ~= nil
    local rad = theme.rounding or 0
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
        Core.DrawText((Core.TruncateText(c.name or "?", w - 12)), x + 6, y + 4,
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
        Core.DrawText("drop audio", x + 6, y + 4, mc[1], mc[2], mc[3], 0.7)
    end
    if Core.MouseInRect(x, y, w, h) and not Core.HasPopup() then
        Core.DrawRect(x, y, w, h, 1, 1, 1, 0.05)
        if Core.MouseClicked(1) and c.path then
            acellToggle(i)
        elseif Core.MouseClicked(2) and c.path then
            UI.NativeMenu({
                { label = "Clear cell",
                  action = function() acellLoad(i, nil) end },
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
        for l = 0, LANES - 1 do
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
        if UI.Button("stopall", "Stop all") then sceneStop() end
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

    -- edits coming home from CP_Editor (a cell opened there): apply
    -- without touching the lane's mode, so a playing loop keeps playing.
    -- Whoever of Looper/Session reads the mail first applies it — both
    -- UIs refresh off the same engine version counters.
    local ac = Bus.Recv("editor:apply")
    if ac and ac.origin then
        local ln = tonumber(ac.origin:match("^looper:(%d+)"))
        if ln and ln >= 0 and ln < LANES then Loop.ApplyClip(ln, ac) end
    end

    -- drops from the Media Explorer / other CP windows
    busConsume()

    -- grid: one scene row of lane cells + one row of audio cells (P1+P3)
    local x, y = UI.GetCursorPos()
    local w = UI.GetAvailableWidth()
    local gap = 4
    local scene_w = 26
    local cell_w = floor((w - scene_w - gap * LANES) / LANES)
    local cell_h = 64

    -- scene button: fire the whole row together
    local sy = y
    Core.DrawRoundRectFilled(x, sy, scene_w, cell_h, theme.rounding or 0,
                             0.18, 0.20, 0.18, 1)
    do
        local a = C.accent
        UI.DrawTriangle(x + 8, sy + cell_h / 2 - 7, x + 8, sy + cell_h / 2 + 7,
                        x + 20, sy + cell_h / 2, a[1], a[2], a[3], 0.9)
        if Core.MouseInRect(x, sy, scene_w, cell_h) and not Core.HasPopup() then
            Core.DrawRect(x, sy, scene_w, cell_h, 1, 1, 1, 0.05)
            if Core.MouseClicked(1) then sceneLaunch() end
        end
    end

    -- drop hit-testing geometry (client coords, rebuilt each frame)
    state.lrow = state.lrow or {}
    state.lrow.x0, state.lrow.y = x + scene_w + gap, y
    state.lrow.cw, state.lrow.gap, state.lrow.h = cell_w, gap, cell_h

    for l = 0, LANES - 1 do
        local cx = x + scene_w + gap + l * (cell_w + gap)
        drawCell(theme, l, cx, y, cell_w, cell_h)
    end

    -- audio row (interim engine): drop a file on a cell, click to loop it
    local ay = y + cell_h + gap
    local ah = 34
    Core.DrawRoundRectFilled(x, ay, scene_w, ah, theme.rounding or 0,
                             0.15, 0.16, 0.15, 1)
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
        drawAudioCell(theme, i, cx, ay, cell_w, ah)
    end
    UI.SetFontBody()
    UI.Layout.AdvanceCursor(w, cell_h + gap + ah + 4)

    -- status
    UI.SetFontCaption()
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            UI.Text(state.flash_msg, { disabled = true })
        else
            state.flash_msg = ""
        end
    else
        UI.Text("Click = launch/stop (quantized) · double-click = edit in CP_Editor · drop audio on the A row",
                { disabled = true })
    end
    UI.SetFontBody()

    if Loop.Playing() then UI.RequestRedraw() end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("CP Session", 560, 190, {
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
