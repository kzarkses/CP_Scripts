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

-- Live view: the phase bars sweep while clips play — never idle-throttle.
Core.SetIdleThrottle(false)

local LANES = Loop.MAX_LANES

local state = {
    flash_msg = "", flash_until = 0,
    recalled = false,      -- one-shot auto-recall after the first attach
}

local function flash(msg)
    state.flash_msg = msg
    state.flash_until = r.time_precise() + 2.5
end

-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## CP Session
The clip grid over the Looper engine: one column per lane, one cell
each (phase 1). Click a cell to launch or stop it QUANTIZED (the Q
button sets the boundary; the cell blinks while queued). The
triangle launches every full cell together — they land on the same
boundary. Right-click a cell: Edit in CP_Editor (edits come back
live), Mute, Clear.

## Clock
Free = clips play without the transport (session style). Follow =
REAPER transport, locks to an external MIDI clock when slaved.

Record and route lanes in CP_Looper — this window is another face
on the same loops, both stay in sync through the shared engine.
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
local function editInEditor(lane)
    local c = Loop.LaneToClip(lane)
    if not c then flash("Empty cell") return end
    c.origin = "looper:" .. lane
    c.name = laneName(lane)
    Bus.Send("editor:open", c)
    flash("Cell sent to CP_Editor")
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

    -- interaction
    if Core.MouseInRect(x, y, w, h) and not Core.HasPopup() then
        Core.DrawRect(x, y, w, h, 1, 1, 1, 0.05)
        if Core.MouseClicked(1) then
            if has or mode == 3 or mode == 5 then
                Loop.ToggleClip(lane)
            end
        elseif Core.MouseClicked(2) then
            cellMenu(lane)
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

    -- grid: header row (column = lane) + one scene row of cells (P1)
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

    for l = 0, LANES - 1 do
        local cx = x + scene_w + gap + l * (cell_w + gap)
        drawCell(theme, l, cx, y, cell_w, cell_h)
    end
    UI.Layout.AdvanceCursor(w, cell_h + 4)

    -- status
    UI.SetFontCaption()
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            UI.Text(state.flash_msg, { disabled = true })
        else
            state.flash_msg = ""
        end
    else
        UI.Text("Click = launch/stop (quantized) · right-click = edit/mute/clear · triangle = scene",
                { disabled = true })
    end
    UI.SetFontBody()

    if Loop.Playing() then UI.RequestRedraw() end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("CP Session", 560, 150, {
    persist    = "CP_Session",
    scrollable = false,
})

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
