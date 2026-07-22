-- @description Looper (CP) — session-view MIDI looper on a hidden JSFX engine
-- @version 0.1
-- @author Cedric Pamalio
-- @about
--   A live MIDI looper built on CP_Toolkit. The real-time engine is a hidden
--   JSFX (CP_MidiLooper) whose loops are phase-locked to the host beat grid —
--   so when REAPER is slaved to an external clock the loops stay in sync with
--   it (and with a friend's Ableton) for free.
--
--   Attach it to the track that holds your instrument (e.g. Vital): the engine
--   is inserted BEFORE the instrument and the track is armed for MIDI input
--   monitoring. Play with REAPER's own virtual keyboard or a MIDI device; hit
--   REC on a lane to capture a phrase — it loops on the grid. 4 independent
--   lanes, each with its own bar length, mute and clear. Loops are runtime-only
--   (a live performance tool), not saved with the project.

local r = reaper

-- ---------------------------------------------------------------------------
-- Toolkit + engine
-- ---------------------------------------------------------------------------
local cp_root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
local UI   = dofile(cp_root .. "CP_Toolkit/CP_Toolkit.lua")
local Loop = dofile(cp_root .. "CP_Engine/Loop.lua")
Loop.init(r)
-- FIRST-RUN default only: clips launch without the transport (Ableton-like).
-- Loop.LoadGlobals() runs on attach and overrides this with the project's saved
-- clock, so this line must never be read as "the clock is always Free".
Loop.SetFreeRun(true)

local Core = UI.Core
local Keys = UI.Keys

-- Live tool: never throttle to the idle heartbeat when unfocused — the playhead
-- must keep sweeping smoothly (clips run on a free clock, so "nothing changed"
-- from the toolkit's point of view is wrong here). Costs a steady ~30 fps.
Core.SetIdleThrottle(false)

-- Shared piano-roll MODEL (same one CP_Editor uses). We drive it with a loop
-- backend so its edit operations write notes straight into the gmem loop.
local Roll = dofile(cp_root .. "CP_Engine/Roll.lua")
Roll.init(r)
-- Shared command layer (keyboard map + transform menu) — same one CP_Editor
-- uses, so the two editors feel identical.
local RollUI = dofile(cp_root .. "CP_Engine/RollUI.lua")

-- ---------------------------------------------------------------------------
-- Config / state
-- ---------------------------------------------------------------------------
local CONFIG_ID = "CP_Looper"   -- window geometry persists automatically via UI.Init

local LANES    = Loop.MAX_LANES
local LEN_OPTS = { 1, 2, 4, 8 }        -- bar lengths cycled by the Len button
local SNAP_OPTS = {                    -- grid snap for the note editor (in beats)
    { label = "1/4",  beats = 1.0 },
    { label = "1/8",  beats = 0.5 },
    { label = "1/16", beats = 0.25 },
    { label = "1/32", beats = 0.125 },
    { label = "off",  beats = 0.0 },
}

local state = {
    flash_msg = "", flash_until = 0,
    edit_lane = nil,      -- lane index currently open in the note editor, or nil
    snap_idx  = 3,        -- SNAP_OPTS index (1/16)
    edrag     = nil,      -- active note drag { note, kind, grab, start0 }
    ed_lo     = 48, ed_hi = 78,   -- editor pitch range
    vel       = 100,      -- velocity for newly drawn notes
}

-- A Roll backend that reads/writes the gmem note list of one lane (cache unit
-- is beats). sort/undo are no-ops: gate playback and identity-sync don't need
-- ordering, and gmem loops aren't part of REAPER's undo.
local function makeLoopBackend(lane)
    return {
        readAll = function()
            local n = Loop.NoteCount(lane)
            for i = 1, n do
                local s, l, p, v = Loop.GetNote(lane, i - 1)
                Roll.starts[i], Roll.lens[i], Roll.pitches[i], Roll.vels[i] = s, l, p, v
            end
            return n
        end,
        insertNote = function(t, pitch, len, vel)
            local n = Loop.NoteCount(lane)
            if n >= Loop.MAX_NOTES then return end
            Loop.PutNote(lane, n, t, len, pitch, vel)
            Loop.SetNoteCount(lane, n + 1)
            Loop.BumpVer(lane)
        end,
        deleteNote = function(i)                     -- 1-based
            local n = Loop.NoteCount(lane)
            for k = i - 1, n - 2 do                  -- shift the tail down (0-based)
                local s, l, p, v = Loop.GetNote(lane, k + 1)
                Loop.PutNote(lane, k, s, l, p, v)
            end
            Loop.SetNoteCount(lane, n - 1)
            Loop.BumpVer(lane)
        end,
        setNote = function(i, t, len, pitch, vel)    -- 1-based, nil = keep
            local s, l, p, v = Loop.GetNote(lane, i - 1)
            if t     ~= nil then s = t end
            if len   ~= nil then l = len end
            if pitch ~= nil then p = pitch end
            if vel   ~= nil then v = vel end
            Loop.PutNote(lane, i - 1, s, l, p, v)
            Loop.BumpVer(lane)
        end,
        sort = function() end,
        undo = function() end,
    }
end

local roll_ver = -1     -- last loop version Roll was synced to

-- Set by anything worth persisting that is NOT lane content — the clock toggle,
-- the armed lane. pollPersist watches note versions and lane modes, which those
-- do not touch, so without this they were only ever written at close.
local persist_dirty = false

-- Per-lane visual cache. Tables allocated once and reused every frame (zero
-- allocation in the frame loop); note bars (bo start / bd length / bn pitch /
-- bv velocity) are refilled only when the lane's notes or length change.
local ev = {}
for l = 0, LANES - 1 do
    ev[l] = { bo = {}, bd = {}, bn = {}, bv = {}, bc = 0, ver = -1, lenB = -1, lo = 48, hi = 72 }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function flash(msg)
    state.flash_msg = msg or ""
    state.flash_until = r.time_precise() + 2.2
end

local function doSetup()
    local tr, err = Loop.Setup()
    if tr then flash("Looper engine ready — route each lane to a track")
    else flash(err or "Setup failed") end
end

local function nextLen(bars)
    for i = 1, #LEN_OPTS do
        if LEN_OPTS[i] == bars then return LEN_OPTS[(i % #LEN_OPTS) + 1] end
    end
    return 1
end

-- Refill the note-bar cache when the lane's notes or length changed. Storage
-- is already note objects (start, len, pitch, vel) — no pairing needed.
local function refreshLane(l)
    local e = ev[l]
    local ver  = Loop.EvtVersion(l)
    local lenB = Loop.LenBeats(l)
    if ver == e.ver and lenB == e.lenB then return end
    e.ver, e.lenB = ver, lenB

    e.bc = Loop.ReadNotes(l, e.bo, e.bd, e.bn, e.bv)   -- start, len, pitch, vel

    -- pitch range for the mini-roll
    local lo, hi = 127, 0
    for i = 1, e.bc do
        local n = e.bn[i]
        if n < lo then lo = n end
        if n > hi then hi = n end
    end
    if e.bc == 0 then lo, hi = 48, 72 end
    lo, hi = lo - 1, hi + 1
    if hi - lo < 12 then local m = (lo + hi) * 0.5; lo = math.floor(m - 6); hi = math.ceil(m + 6) end
    if lo < 0 then lo = 0 end
    if hi > 127 then hi = 127 end
    e.lo, e.hi = lo, hi
end

-- A compact hit-tested button (lane strips are absolutely positioned, so we
-- do not use the flow-layout UI.Button here). Returns true when clicked.
local function tinyBtn(x, y, w, h, label, cr, cg, cb, theme)
    local mx, my = Core.GetMousePos()
    local hover = mx >= x and mx < x + w and my >= y and my < y + h and not Core.HasPopup()
    local f = hover and 0.16 or 0
    Core.DrawRect(x, y, w, h, cr + (1 - cr) * f, cg + (1 - cg) * f, cb + (1 - cb) * f, 1)
    if hover then
        local a = theme.colors.accent
        Core.DrawRect(x, y, w, h, a[1], a[2], a[3], 0.9, false)
    end
    local tw, th = gfx.measurestr(label)
    local lum = (cr + cg + cb) / 3
    local tc = lum > 0.55 and 0.10 or 0.92
    Core.DrawText(label, x + (w - tw) * 0.5, y + (h - th) * 0.5, tc, tc, tc, 1)
    if hover then UI.SetCursor("hand") end
    return hover and Core.MouseClicked(1)
end

-- Trim a label with an ellipsis so it fits within maxpix.
local function truncPix(s, maxpix)
    if gfx.measurestr(s) <= maxpix then return s end
    local n = #s
    while n > 1 do
        n = n - 1
        local sub = s:sub(1, n) .. "…"
        if gfx.measurestr(sub) <= maxpix then return sub end
    end
    return "…"
end

-- gfx.showmenu treats | < > (and leading # !) specially; neutralize them so a
-- track name can't split the menu and break the index -> action mapping.
local function menuSafe(s)
    s = s:gsub("|", "/"); s = s:gsub("<", "("); s = s:gsub(">", ")")
    return s
end

-- Track picker for a lane's routing destination. Blocks briefly on gfx.showmenu
-- (only on click — not a hot-path allocation concern). No separators, so the
-- returned 1-based index maps straight onto the parallel action list.
local function pickLaneDest(lane)
    local router = Loop.track
    local menu, acts = {}, {}
    local function push(label, fn) menu[#menu + 1] = label; acts[#acts + 1] = fn end
    local cur = Loop.GetLaneDest(lane)
    push((cur == nil and "!" or "") .. "No track (silent)",
         function() Loop.SetLaneDest(lane, nil); flash("Lane " .. (lane + 1) .. " unrouted") end)
    local cnt = r.CountTracks(0)
    for i = 0, cnt - 1 do
        local tr = r.GetTrack(0, i)
        if tr ~= router then
            local _, nm = r.GetTrackName(tr)
            local disp = (nm ~= "" and nm or "Track " .. (i + 1))
            push(((cur == tr) and "!" or "") .. (i + 1) .. ": " .. menuSafe(disp),
                 function()
                     Loop.SetLaneDest(lane, tr)
                     flash("Lane " .. (lane + 1) .. " → " .. disp)
                 end)
        end
    end
    push("+ New instrument track", function()
        local tr = Loop.NewDestTrack(lane)
        if tr then flash("Lane " .. (lane + 1) .. " → new track (add your instrument)") end
    end)
    local sel = gfx.showmenu(table.concat(menu, "|"))
    if sel and sel > 0 and acts[sel] then acts[sel]() end
end

-- ---------------------------------------------------------------------------
-- Note editor helpers (beats <-> pixels, snap, enter/exit)
-- ---------------------------------------------------------------------------
local BLACK_KEY = { [1] = true, [3] = true, [6] = true, [8] = true, [10] = true }

-- C-row labels, built once: the row loop runs every frame under a forced
-- redraw, so building "C4" there would allocate in the hot draw path.
local OCT_LBL = {}
for p = 0, 127, 12 do OCT_LBL[p] = "C" .. (math.floor(p / 12) - 1) end

local function snapBeats() return SNAP_OPTS[state.snap_idx].beats end
local function snapFloor(t, s) if s <= 0 then return t end return math.floor(t / s + 1e-6) * s end
local function snapRound(t, s) if s <= 0 then return t end return math.floor(t / s + 0.5) * s end

local function xToPhase(mx, rx, rw, L)
    local ph = (mx - rx) / rw * L
    if ph < 0 then ph = 0 elseif ph >= L then ph = L - 1e-4 end
    return ph
end
local function phaseToX(ph, rx, rw, L) return rx + ph / L * rw end
local function pitchRowY(pitch, ry, rowh, hi) return ry + (hi - pitch) * rowh end
local function yToPitch(my, ry, rowh, lo, hi)
    local p = hi - math.floor((my - ry) / rowh)
    if p < lo then p = lo elseif p > hi then p = hi end
    return p
end

-- fit the editor pitch range to the lane's notes (+ margin, min ~2 octaves)
local function fitEditRange(lane)
    local lo, hi = 127, 0
    local n = Loop.NoteCount(lane)
    for i = 0, n - 1 do
        local _, _, p = Loop.GetNote(lane, i)
        if p < lo then lo = p end
        if p > hi then hi = p end
    end
    if n == 0 then lo, hi = 54, 78 end
    lo, hi = lo - 4, hi + 4
    if hi - lo < 24 then local m = math.floor((lo + hi) / 2); lo, hi = m - 12, m + 12 end
    if lo < 0 then lo = 0 end
    if hi > 127 then hi = 127 end
    state.ed_lo, state.ed_hi = lo, hi
end

-- Group-drag snapshot: original (start,pitch,len) of every selected note (a
-- drag-start event, so the per-note table churn is fine — not the frame path).
local move_snap = {}
local function snapshotSel()
    local n = 0
    for i in pairs(Roll.selset) do
        n = n + 1
        move_snap[n] = { i = i, s = Roll.starts[i], p = Roll.pitches[i], l = Roll.lens[i] }
    end
    for k = #move_snap, n + 1, -1 do move_snap[k] = nil end
    return n
end

local function loopGrid() local s = snapBeats(); return s > 0 and s or 1 end

-- Editor hint text, cached on the selection count: drawEditor forces a redraw
-- every frame, so building this string inline would allocate in the draw path.
local HINT_IDLE = "click/drag add · right-drag select · Ctrl+D/C/V · Q"
local hint_n, hint_s = -1, HINT_IDLE
local function selHint()
    local n = Roll.seln
    if n ~= hint_n then
        hint_n = n
        hint_s = (n > 1) and (n .. " selected") or HINT_IDLE
    end
    return hint_s
end

-- Context handed to the shared RollUI (keyboard map + transform menu). The
-- loop's cache unit is BEATS, so every amount here is in beats.
-- Bar length in beats, derived from the lane itself (loop beats / loop bars) so
-- it stays exact whatever the meter; TsNum is the fallback before a lane is open.
local function barBeats()
    local lane = state.edit_lane
    if lane then
        local bars = Loop.GetLengthBars(lane)
        local bts  = Loop.LenBeats(lane)
        if bars and bars > 0 and bts and bts > 0 then return bts / bars end
    end
    local n = Loop.TsNum()
    return (n and n > 0) and n or 4
end

local loopCtx = {
    Roll = Roll, Keys = Keys,
    Shift = Core.ModShift, Ctrl = Core.ModCtrl, Alt = Core.ModAlt,
    flash = flash,
    gridStep  = function() return loopGrid() end,
    snap      = function(t) return snapRound(t, snapBeats()) end,
    divToUnit = function(div) return div * 4 end,   -- whole-note division -> beats
    pasteAt   = function() return 0 end,             -- paste at the loop start
    -- loop phase 0 is bar-aligned by construction, so bars are pure arithmetic
    barFloor  = function(t) local b = barBeats(); return math.floor(t / b + 1e-6) * b end,
    barCeil   = function(t) local b = barBeats(); return math.ceil (t / b - 1e-6) * b end,
    -- the lane is a fixed canvas: a duplicate that would land past its end grows
    -- the loop instead of silently wrapping on top of the original
    fitLen    = function()
        return state.edit_lane and Loop.LenBeats(state.edit_lane) or nil
    end,
    grow      = function(need)
        local lane = state.edit_lane
        if not lane then return false end
        local b = barBeats(); if b <= 0 then return false end
        local want = math.ceil(need / b - 1e-6)
        for _, n in ipairs(LEN_OPTS) do
            if n >= want then Loop.SetLengthBars(lane, n); return true end
        end
        return false
    end,
    swingSnap = function(amt)
        return function(t)
            local s = snapBeats(); if s <= 0 then return t end
            local idx = math.floor(t / s + 0.5); local base = idx * s
            if idx % 2 == 1 then base = base + s * amt end
            return base < 0 and 0 or base
        end
    end,
}

-- Velocity preset picker for newly drawn notes.
local function pickVel()
    local presets = { 127, 110, 100, 90, 80, 64, 50, 40 }
    local menu = {}
    for _, v in ipairs(presets) do menu[#menu + 1] = (state.vel == v and "!" or "") .. v end
    local sel = gfx.showmenu(table.concat(menu, "|"))
    if sel and sel > 0 and presets[sel] then state.vel = presets[sel] end
end

local function enterEdit(lane)
    state.edit_lane = lane
    state.edrag = nil
    state.marquee = nil
    Loop.SetArmedLane(lane)          -- editing a lane arms it for live input
    Roll.SetBackend(makeLoopBackend(lane))
    roll_ver = Loop.EvtVersion(lane)
    fitEditRange(lane)
end

local function exitEdit()
    if state.edrag then Roll.Commit("loop edit"); state.edrag = nil end
    state.edit_lane = nil
    Roll.Detach()
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
local function drawToolbar(attached)
    UI.SetFontH2(); UI.Text("Looper"); UI.SetFontBody()
    UI.SameLine(12)
    UI.SetFontCaption()
    local bpm = Loop.Tempo()
    local playing = Loop.Playing()
    UI.Text(string.format("%s   %.1f BPM", playing and "PLAY" or "STOP", bpm or 0),
            { disabled = true })
    UI.SetFontBody()

    UI.SameLine()
    if attached then
        local free = Loop.GetFreeRun()
        if UI.Button("clock", free and "Clock: Free" or "Clock: Follow") then
            Loop.SetFreeRun(not free)
            persist_dirty = true
            flash(free and "Follow host transport" or "Free run (launch without transport)")
        end
        UI.SameLine()
        -- The router is armed on ALL MIDI inputs and fans your playing to each
        -- lane's instrument through sends — and a send ignores the destination's
        -- arm state, so those tracks sound even unarmed. This is the off switch:
        -- turn it off and the keyboard is free for whatever track you armed.
        local listen = Loop.GetListen()
        if listen then
            UI.PushStyleColor("button", 0.75, 0.30, 0.28)
        end
        if UI.Button("listen", listen and "Listen: on" or "Listen: off") then
            Loop.SetListen(not listen)
            flash(listen and "MIDI input released - lanes won't sound live"
                          or "Listening: your playing reaches the routed lanes")
        end
        if listen then UI.PopStyleColor() end

        UI.SameLine()
        if UI.Button("panic", "Panic") then Loop.Panic(); flash("All notes off") end
        UI.SameLine()
        if UI.Button("allsel", "Sound → sel") then
            local sel = r.GetSelectedTrack(0, 0)
            if sel and sel ~= Loop.track then
                for l = 0, LANES - 1 do Loop.SetLaneDest(l, sel) end
                local _, nm = r.GetTrackName(sel)
                flash("All lanes → " .. (nm ~= "" and nm or "track"))
            else
                flash("Select an instrument track first")
            end
        end
        UI.SameLine()
        if UI.Button("reload", "Reload") then
            -- no longer destructive: the loops live in gmem and survive the
            -- engine's @init (that is exactly the bug this replaced)
            Loop.ReloadEngine(); flash("Engine reloaded (loops kept)")
        end
        UI.SameLine()
        -- Explicit recall: the automatic one refuses to overwrite lanes that
        -- already hold notes, so this is how you get the project's copy back
        -- over a live set.
        if UI.Button("recall", "Recall") then
            if not Loop.HasSavedState() then
                flash("Nothing saved in this project yet")
            elseif r.MB("Recall the loops saved in this project?\n\nThis REPLACES every lane.",
                        "CP Looper", 4) == 6 then
                local ok, n = Loop.LoadState(true)
                for l = 0, LANES - 1 do ev[l].ver = -1 end
                roll_ver = -1
                flash(ok and (n .. " notes recalled") or "Recall failed")
            end
        end
        UI.SameLine()
        -- the ONLY way to lose every loop, so it asks
        if UI.Button("clearall", "Clear all") then
            if r.MB("Clear every recorded loop?", "CP Looper", 4) == 6 then
                Loop.ClearAll(); flash("All lanes cleared")
            end
        end
    else
        if UI.Button("attach", "Create looper engine") then doSetup() end
        UI.SameLine()
        if UI.Button("panic", "Panic") then Loop.Panic() end
    end
end

local function drawUnattached()
    UI.Spacing(20)
    UI.SetFontH2(); UI.Text("Looper not set up"); UI.SetFontBody()
    UI.Spacing(8)
    UI.Text("1.  (Optional) select the instrument track you want as the default sound.")
    UI.Text("2.  Click \"Create looper engine\" above.")
    UI.Spacing(6)
    UI.SetFontCaption()
    UI.Text("A \"CP Looper\" router track is created and armed for MIDI. Select it and", { disabled = true })
    UI.Text("play (virtual keyboard or a device). Route each lane to its own instrument", { disabled = true })
    UI.Text("track (FL/Ableton style) with the lane's \"→ track\" button, then REC a lane", { disabled = true })
    UI.Text("to capture a phrase — it loops on the beat grid (and to an external clock).", { disabled = true })
    UI.SetFontBody()
end

local function drawViz(theme, l, x, y, w, h, mode)
    local C = theme.colors
    local e = ev[l]
    -- backdrop
    Core.DrawRect(x, y, w, h, 0.11, 0.11, 0.12, 1)

    local lenB  = Loop.LenBeats(l)
    local tsnum = Loop.TsNum()

    -- beat / bar gridlines
    local nb = math.floor(lenB + 0.5)
    if nb < 1 then nb = 1 end
    for b = 0, nb do
        local gx = x + (b / lenB) * w
        local strong = (b % tsnum) == 0
        Core.DrawLine(gx, y, gx, y + h, C.border[1], C.border[2], C.border[3], strong and 0.55 or 0.18)
    end

    -- note bars
    local lo, hi = e.lo, e.hi
    local span = math.max(1, hi - lo)
    local acc = C.accent
    for i = 1, e.bc do
        local nx = x + (e.bo[i] / lenB) * w
        local nw = (e.bd[i] / lenB) * w
        if nw < 2 then nw = 2 end
        if nx + nw > x + w then nw = x + w - nx end
        local ny = y + (1 - (e.bn[i] - lo) / span) * (h - 4)
        local a = 0.45 + 0.55 * (e.bv[i] / 127)
        Core.DrawRect(nx, ny, nw, 3, acc[1], acc[2], acc[3], a)
    end

    -- playhead (only while the clip is actually playing)
    if mode == 3 then
        local ph = Loop.Phase(l)
        local px = x + (ph / lenB) * w
        Core.DrawLine(px, y, px, y + h, 1, 1, 1, 0.65)
    end

    -- recording tint (dimmer while merely armed)
    if mode == 1 then
        Core.DrawRect(x, y, w, h, C.danger[1], C.danger[2], C.danger[3], 0.07)
    elseif mode == 4 then
        Core.DrawRect(x, y, w, h, 0.85, 0.65, 0.25, 0.05)
    end
    -- empty hint
    if e.bc == 0 and mode ~= 1 then
        local msg = "empty"
        local tw = gfx.measurestr(msg)
        Core.DrawText(msg, x + (w - tw) * 0.5, y + h * 0.5 - 6,
                      C.text_mute[1], C.text_mute[2], C.text_mute[3], 0.8)
    end
end

local function drawLane(theme, l, x, y, w, h)
    local C = theme.colors
    refreshLane(l)
    local mode  = math.floor(Loop.Mode(l) + 0.5)   -- 0 empty,1 rec,2 stopped,3 playing,4 armed
    local muted = Loop.GetMute(l)
    local nev   = math.floor(Loop.NEv(l) + 0.5)

    -- panel
    Core.DrawRect(x, y, w, h, C.surface[1], C.surface[2], C.surface[3], 1)
    Core.DrawRect(x, y, w, h, C.border[1], C.border[2], C.border[3], C.border[4] or 0.5, false)

    local pad = 6
    -- header: the "Lane N" label doubles as the arm-for-live-input control
    local armed = (Loop.GetArmedLane() == l)
    local lbl = "Lane " .. (l + 1)
    local lblw = gfx.measurestr(lbl)
    local lr, lg, lb = C.text[1], C.text[2], C.text[3]
    if armed then lr, lg, lb = C.accent[1], C.accent[2], C.accent[3] end
    Core.DrawText(lbl, x + pad, y + 5, lr, lg, lb, 1)
    if armed then
        Core.DrawText("● IN", x + pad + lblw + 8, y + 5, C.accent[1], C.accent[2], C.accent[3], 0.95)
    end
    do
        local mx, my = Core.GetMousePos()
        if mx >= x + pad and mx < x + pad + lblw + 46 and my >= y + 3 and my < y + 19
           and not Core.HasPopup() then
            UI.SetCursor("hand")
            if Core.MouseClicked(1) then Loop.SetArmedLane(l) end
        end
    end
    -- status word (right)
    local sw, scr, scg, scb
    if mode == 1 then sw, scr, scg, scb = "REC", C.danger[1], C.danger[2], C.danger[3]
    elseif mode == 4 then sw, scr, scg, scb = "ARM", 0.85, 0.65, 0.25
    elseif mode == 3 then sw, scr, scg, scb = "PLAY", 0.30, 0.75, 0.40
    elseif mode == 2 then sw, scr, scg, scb = "STOP", C.text_mute[1], C.text_mute[2], C.text_mute[3]
    else sw, scr, scg, scb = "", C.text_mute[1], C.text_mute[2], C.text_mute[3] end
    if muted and mode ~= 1 and mode ~= 4 then sw = "MUTE"; scr, scg, scb = 0.85, 0.65, 0.25 end
    if sw ~= "" then
        local tw = gfx.measurestr(sw)
        Core.DrawText(sw, x + w - pad - tw, y + 5, scr, scg, scb, 1)
    end

    -- controls row
    local cy = y + 22
    local bh = 20
    local bx = x + pad

    -- REC (click while recording/armed = finish the take / cancel the arm)
    if mode == 1 then
        if tinyBtn(bx, cy, 46, bh, "REC", C.danger[1], C.danger[2], C.danger[3], theme) then
            Loop.Stop(l)
        end
    elseif mode == 4 then
        if tinyBtn(bx, cy, 46, bh, "ARM", 0.72, 0.55, 0.20, theme) then
            Loop.Stop(l); flash("Lane " .. (l + 1) .. ": arm cancelled")
        end
    else
        if tinyBtn(bx, cy, 46, bh, "REC", 0.30, 0.30, 0.32, theme) then
            Loop.SetArmedLane(l); Loop.Rec(l)
            -- with the clock stopped the engine arms instead of wiping the lane
            if Loop.GetFreeRun() or Loop.Playing() then
                flash("Lane " .. (l + 1) .. ": recording")
            else
                flash("Lane " .. (l + 1) .. ": armed - starts on play")
            end
        end
    end
    bx = bx + 50

    -- PLAY / STOP clip (only meaningful with content)
    if mode == 3 then
        if tinyBtn(bx, cy, 46, bh, "Stop", 0.28, 0.66, 0.38, theme) then Loop.StopClip(l) end
    elseif mode == 2 then
        if tinyBtn(bx, cy, 46, bh, "Play", 0.22, 0.30, 0.24, theme) then
            Loop.Play(l); flash("Lane " .. (l + 1) .. ": play")
        end
    else
        Core.DrawRect(bx, cy, 46, bh, 0.15, 0.15, 0.16, 1)   -- inert (empty / recording)
        Core.DrawText("Play", bx + (46 - gfx.measurestr("Play")) * 0.5, cy + 3,
                      C.text_disabled[1], C.text_disabled[2], C.text_disabled[3], 0.6)
    end
    bx = bx + 50

    -- CLEAR
    local clr = nev > 0
    if tinyBtn(bx, cy, 44, bh, "Clr",
               clr and 0.30 or 0.20, clr and 0.20 or 0.20, clr and 0.20 or 0.21, theme) then
        Loop.Clear(l); flash("Lane " .. (l + 1) .. " cleared")
    end
    bx = bx + 48

    -- MUTE
    if tinyBtn(bx, cy, 42, bh, "Mute",
               muted and 0.85 or 0.24, muted and 0.65 or 0.24, muted and 0.25 or 0.26, theme) then
        Loop.SetMute(l, not muted)
    end
    bx = bx + 46

    -- LENGTH
    local bars = math.floor(Loop.GetLengthBars(l) + 0.5)
    if bars < 1 then bars = 1 end
    if tinyBtn(bx, cy, 54, bh, bars .. (bars > 1 and " bars" or " bar"),
               0.20, 0.22, 0.26, theme) then
        Loop.SetLengthBars(l, nextLen(bars))
    end
    bx = bx + 58

    -- note count (far right)
    local cnt  = nev .. " nt"
    local cntw = gfx.measurestr(cnt)
    Core.DrawText(cnt, x + w - pad - cntw, cy + 4,
                  C.text_mute[1], C.text_mute[2], C.text_mute[3], 0.9)

    -- DEST routing — click to choose this lane's instrument track
    local dx2 = x + w - pad - cntw - 8
    local dxw = dx2 - bx
    if dxw >= 42 then
        local dst = Loop.GetLaneDest(l)
        local dname
        if dst then local _, nm = r.GetTrackName(dst); dname = "→ " .. (nm ~= "" and nm or "track")
        else dname = "→ no track" end
        if tinyBtn(bx, cy, dxw, bh, truncPix(dname, dxw - 8),
                   dst and 0.20 or 0.30, dst and 0.24 or 0.20, dst and 0.22 or 0.20, theme) then
            pickLaneDest(l)
        end
    end

    -- visualization fills the rest — click it to open the note editor
    local vx, vy = x + pad, y + 46
    local vw, vh = w - 2 * pad, (y + h - 5) - vy
    if vh > 8 then
        drawViz(theme, l, vx, vy, vw, vh, mode)
        local mx, my = Core.GetMousePos()
        if mx >= vx and mx < vx + vw and my >= vy and my < vy + vh and not Core.HasPopup() then
            UI.SetCursor("hand")
            if Core.MouseClicked(1) then enterEdit(l) end
            -- edit hint (bottom-right of the roll)
            local hint = "click to edit"
            Core.DrawText(hint, vx + vw - gfx.measurestr(hint) - 3, vy + vh - 13,
                          C.text_mute[1], C.text_mute[2], C.text_mute[3], 0.9)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Note editor (a full piano roll for one lane, on the shared Roll model)
-- ---------------------------------------------------------------------------
local function drawEditor(theme)
    local C = theme.colors
    local lane = state.edit_lane
    local L = Loop.LenBeats(lane)
    local tsnum = Loop.TsNum()

    -- keep Roll in sync with external changes, but NEVER mid-drag (stale index)
    if not state.edrag then
        local v = Loop.EvtVersion(lane)
        if v ~= roll_ver then Roll.Sync(); roll_ver = v end
    end

    local x, y = UI.GetCursorPos()
    local w = UI.GetAvailableWidth()
    local avail = UI.GetAvailableHeight()

    Core.SetFontCaption()
    local hbh = 20
    local hx, hy = x, y
    if tinyBtn(hx, hy, 60, hbh, "< Lanes", 0.24, 0.26, 0.32, theme) then exitEdit() return end
    hx = hx + 64
    local lnlbl = "Lane " .. (lane + 1)
    Core.DrawText(lnlbl, hx, hy + 4, C.text[1], C.text[2], C.text[3], 1)

    -- right-anchored controls: Snap, Length, Play/Stop
    local sxx = x + w - 64
    if tinyBtn(sxx, hy, 64, hbh, "Grid " .. SNAP_OPTS[state.snap_idx].label, 0.20, 0.22, 0.26, theme) then
        state.snap_idx = state.snap_idx % #SNAP_OPTS + 1
    end
    local lxx = sxx - 4 - 54
    local bars = math.floor(Loop.GetLengthBars(lane) + 0.5); if bars < 1 then bars = 1 end
    if tinyBtn(lxx, hy, 54, hbh, bars .. (bars > 1 and " bars" or " bar"), 0.20, 0.22, 0.26, theme) then
        Loop.SetLengthBars(lane, nextLen(bars))
    end
    local mode = math.floor(Loop.Mode(lane) + 0.5)
    local pxx = lxx - 4 - 46
    if mode == 3 then
        if tinyBtn(pxx, hy, 46, hbh, "Stop", 0.28, 0.66, 0.38, theme) then Loop.StopClip(lane) end
    elseif mode == 2 then
        if tinyBtn(pxx, hy, 46, hbh, "Play", 0.22, 0.30, 0.24, theme) then Loop.Play(lane) end
    end

    -- dest routing button, filling the gap between the label and the controls
    local dbx = hx + gfx.measurestr(lnlbl) + 12
    local dbw = (pxx - 8) - dbx
    if dbw >= 50 then
        local dst = Loop.GetLaneDest(lane)
        local dn
        if dst then local _, nm = r.GetTrackName(dst); dn = "→ " .. (nm ~= "" and nm or "track")
        else dn = "→ no track" end
        if tinyBtn(dbx, hy, dbw, hbh, truncPix(dn, dbw - 8),
                   dst and 0.20 or 0.30, dst and 0.24 or 0.20, dst and 0.22 or 0.20, theme) then
            pickLaneDest(lane)
        end
    end

    -- tools row (row 2): default velocity, transform menu, quantize + a hint
    local hy2 = hy + hbh + 3
    if tinyBtn(x, hy2, 52, hbh, "Vel " .. state.vel, 0.20, 0.22, 0.26, theme) then pickVel() end
    if tinyBtn(x + 56, hy2, 78, hbh, "Transform", 0.22, 0.26, 0.32, theme) then
        UI.NativeMenu(RollUI.TransformMenu(loopCtx))
    end
    if tinyBtn(x + 138, hy2, 64, hbh, "Quantize", 0.20, 0.22, 0.26, theme) then
        flash(Roll.Quantize(loopCtx.snap) .. " quantized")
    end
    Core.DrawText(selHint(), x + 210, hy2 + 5,
                  C.text_mute[1], C.text_mute[2], C.text_mute[3], 0.85)

    -- roll area: a note grid above a velocity lane
    local kbw = 24
    local VEL_H = 34
    local rx, ry = x + kbw, hy2 + hbh + 6
    local rw = w - kbw
    local grid_h = avail - (ry - y) - 2 - VEL_H - 4
    if grid_h < 24 then Core.SetFontBody() return end
    local lo, hi = state.ed_lo, state.ed_hi
    local rowh = grid_h / (hi - lo + 1)
    local vy = ry + grid_h + 4

    -- pitch rows + keyboard
    for p = lo, hi do
        local yy = pitchRowY(p, ry, rowh, hi)
        local blk = BLACK_KEY[p % 12]
        local sh = blk and 0.095 or 0.13
        if Roll.scale_on and not Roll.InScale(p) then sh = sh * 0.5 end   -- scale dim
        Core.DrawRect(rx, yy, rw, rowh + 0.5, sh, sh, sh + 0.006, 1)
        if p % 12 == 0 then
            Core.DrawLine(rx, yy, rx + rw, yy, C.border[1], C.border[2], C.border[3], 0.4)
        end
        local kc = blk and 0.16 or 0.80
        Core.DrawRect(x, yy, kbw - 1, rowh + 0.5, kc, kc, kc + 0.02, 1)
        if p % 12 == 0 and rowh >= 7 then
            Core.DrawText(OCT_LBL[p] or "C", x + 1, yy + rowh * 0.5 - 4, 0.2, 0.2, 0.2, 1)
        end
    end

    -- vertical grid: snap subdivisions (faint) + beats/bars
    local s = snapBeats()
    if s > 0 then
        local t = 0
        while t < L - 1e-6 do
            local gx = phaseToX(t, rx, rw, L)
            Core.DrawLine(gx, ry, gx, ry + grid_h, C.border[1], C.border[2], C.border[3], 0.10)
            t = t + s
        end
    end
    local nb = math.floor(L + 0.5); if nb < 1 then nb = 1 end
    for b = 0, nb do
        local gx = phaseToX(b, rx, rw, L)
        local strong = (b % tsnum) == 0
        Core.DrawLine(gx, ry, gx, ry + grid_h, C.border[1], C.border[2], C.border[3], strong and 0.55 or 0.22)
    end

    -- notes
    local acc = C.accent
    for i = 1, Roll.count do
        local p = Roll.pitches[i]
        if p >= lo and p <= hi then
            local nx = phaseToX(Roll.starts[i], rx, rw, L)
            local nw = Roll.lens[i] / L * rw
            if nw < 3 then nw = 3 end
            if nx + nw > rx + rw then nw = rx + rw - nx end
            local yy = pitchRowY(p, ry, rowh, hi)
            local sel = Roll.IsSel(i)
            local a = 0.5 + 0.5 * (Roll.vels[i] / 127)
            Core.DrawRect(nx, yy + 1, nw, math.max(2, rowh - 2),
                          sel and 1 or acc[1], sel and 0.85 or acc[2], sel and 0.35 or acc[3], a)
            if sel then Core.DrawRect(nx, yy + 1, nw, math.max(2, rowh - 2), 1, 1, 1, 0.9, false) end
        end
    end

    -- playhead
    if mode == 3 then
        local px = phaseToX(Loop.Phase(lane), rx, rw, L)
        Core.DrawLine(px, ry, px, ry + grid_h, 1, 1, 1, 0.6)
    end

    -- velocity lane: one stalk per note at its start, taller = louder
    Core.DrawRect(x, vy, kbw + rw, VEL_H, C.surface[1], C.surface[2], C.surface[3], 1)
    for i = 1, Roll.count do
        local st = Roll.starts[i]
        if st >= 0 and st <= L then
            local vx = phaseToX(st, rx, rw, L)
            local bh = (Roll.vels[i] / 127) * (VEL_H - 4)
            local sel = Roll.IsSel(i)
            Core.DrawRect(vx, vy + VEL_H - bh, 3, bh,
                          sel and 1 or acc[1], sel and 0.85 or acc[2], sel and 0.35 or acc[3],
                          sel and 1 or 0.7)
        end
    end

    -- ---- input ----
    local mx, my = Core.GetMousePos()
    local inGrid = mx >= rx and mx < rx + rw and my >= ry and my < ry + grid_h and not Core.HasPopup()
    local inVel  = mx >= rx and mx < rx + rw and my >= vy and my < vy + VEL_H and not Core.HasPopup()
    local add = Core.ModShift()

    -- wheel: scroll vertical (plain) / zoom vertical (Ctrl). The loop always
    -- fills the width, so horizontal (Shift/Alt) is a no-op here.
    if (inGrid or inVel) and not Core.ModShift() and not Core.ModAlt() then
        local wheel = Core.GetState().mouse_wheel
        if wheel and wheel ~= 0 then
            local notches = wheel / 120
            local span = hi - lo + 1
            if Core.ModCtrl() then                    -- vertical zoom about the mouse pitch
                local anchor = yToPitch(my, ry, rowh, lo, hi)
                local ns = math.floor(span * (notches > 0 and 1 / 1.2 or 1.2) + 0.5)
                if ns < 6 then ns = 6 elseif ns > 100 then ns = 100 end
                local frac = (anchor - lo) / math.max(1, span - 1)
                local nlo = math.floor(anchor - frac * (ns - 1) + 0.5)
                local nhi = nlo + ns - 1
                if nlo < 0 then nlo = 0; nhi = ns - 1 end
                if nhi > 127 then nhi = 127; nlo = math.max(0, 127 - ns + 1) end
                state.ed_lo, state.ed_hi = nlo, nhi
            else                                      -- vertical scroll (up = higher)
                local step = math.max(1, math.floor(span * 0.2))
                local d = (notches > 0) and step or -step
                local nlo, nhi = lo + d, hi + d
                if nlo < 0 then nhi = nhi - nlo; nlo = 0 end
                if nhi > 127 then nlo = nlo - (nhi - 127); nhi = 127 end
                if nlo < 0 then nlo = 0 end
                state.ed_lo, state.ed_hi = nlo, nhi
            end
            UI.ConsumeWheel()
        end
    end

    if state.edrag and (not state.edrag.note or state.edrag.note < 1 or state.edrag.note > Roll.count) then
        state.edrag = nil                    -- index went stale — drop the drag
    end

    -- piano-key column: click selects that whole pitch row (as in CP_Editor)
    if mx >= x and mx < rx and my >= ry and my < ry + grid_h and not Core.HasPopup()
       and not state.edrag and not state.marquee then
        UI.SetCursor("hand")
        if Core.MouseClicked(1) then
            flash(Roll.SelectPitch(yToPitch(my, ry, rowh, lo, hi), add) .. " selected")
        end
    end

    -- grid presses (only when no drag / marquee is already live)
    if inGrid and not state.edrag and not state.marquee then
        local ph  = xToPhase(mx, rx, rw, L)
        local pit = yToPitch(my, ry, rowh, lo, hi)
        local hit = Roll.At(ph, pit)
        if hit then
            local endx = phaseToX(Roll.starts[hit] + Roll.lens[hit], rx, rw, L)
            UI.SetCursor(math.abs(mx - endx) <= 5 and "size_we" or "size_all")
        else
            UI.SetCursor("cross")
        end
        if Core.MouseClicked(1) then
            if hit then
                if not Roll.IsSel(hit) then
                    if add then Roll.AddSel(hit) else Roll.SelectOnly(hit) end
                end
                local endx = phaseToX(Roll.starts[hit] + Roll.lens[hit], rx, rw, L)
                if math.abs(mx - endx) <= 5 then
                    state.edrag = { note = hit, kind = "resize", px = mx, py = my, moved = false,
                                    ol = Roll.lens[hit], multi = Roll.seln > 1 and snapshotSel() or nil }
                else
                    state.edrag = { note = hit, kind = "move", px = mx, py = my, moved = false,
                                    grab = ph - Roll.starts[hit], op = Roll.starts[hit],
                                    opp = Roll.pitches[hit], multi = Roll.seln > 1 and snapshotSel() or nil }
                end
            else
                -- draw-then-drag: insert a cell note, keep dragging to set length
                local t = snapFloor(ph, s)
                local len = (s > 0) and s or 0.5
                if t + len > L then len = L - t end
                if len > 0.001 then
                    Roll.Insert(t, pit, len, state.vel)
                    if Roll.sel then
                        state.edrag = { note = Roll.sel, kind = "resize", px = mx, py = my,
                                        moved = false, ol = Roll.lens[Roll.sel] }
                    end
                end
            end
        elseif Core.MouseClicked(2) then
            -- right-drag = marquee; a plain right-click deletes the note under it
            state.marquee = { x = mx, y = my, cx = mx, cy = my, t0 = ph, p0 = pit, moved = false }
        end
    end

    -- velocity-lane press: grab the nearest note bar
    if inVel and not state.edrag and Core.MouseClicked(1) and Roll.count > 0 then
        local best, bestd = nil, 6
        for i = 1, Roll.count do
            local d = math.abs(phaseToX(Roll.starts[i], rx, rw, L) - mx)
            if d < bestd then best, bestd = i, d end
        end
        if best then
            if not Roll.IsSel(best) then Roll.SelectOnly(best) end
            state.edrag = { note = best, kind = "vel", px = mx, py = my, moved = false,
                            multi = Roll.seln > 1 and snapshotSel() or nil }
        end
    end

    -- active drag (move / resize / velocity), single or group
    if state.edrag then
        local d  = state.edrag
        local ni = d.note
        local ph = xToPhase(mx, rx, rw, L)
        local free = Core.ModCtrl()          -- Ctrl bypasses snap (as in CP_Editor)
        if not d.moved and (math.abs(mx - d.px) > 3 or math.abs(my - d.py) > 3) then d.moved = true end
        if d.kind == "move" then
            if d.moved then
                local ln = Roll.lens[ni] or 0
                local nt = free and (ph - d.grab) or snapRound(ph - d.grab, s)
                if nt < 0 then nt = 0 elseif nt > L - ln then nt = math.max(0, L - ln) end
                local np = yToPitch(my, ry, rowh, lo, hi)
                if d.multi and d.multi > 1 then
                    local dt, dp = nt - d.op, np - d.opp
                    for k = 1, d.multi do
                        local e = move_snap[k]
                        local ns = e.s + dt; if ns < 0 then ns = 0 elseif ns > L - e.l then ns = math.max(0, L - e.l) end
                        local npp = e.p + dp; if npp < 0 then npp = 0 elseif npp > 127 then npp = 127 end
                        Roll.MoveLive(e.i, ns, npp)
                    end
                else
                    Roll.MoveLive(ni, nt, np)
                end
            end
            UI.SetCursor("size_all")
        elseif d.kind == "resize" then
            if d.moved then
                local minl = (s > 0) and s or 0.0625
                if d.multi and d.multi > 1 then
                    local nlen = free and (ph - Roll.starts[ni]) or snapRound(ph - Roll.starts[ni], s)
                    if nlen < minl then nlen = minl end
                    local dl = nlen - d.ol
                    for k = 1, d.multi do
                        local e = move_snap[k]
                        local nl = e.l + dl; if nl < minl then nl = minl end
                        if e.s + nl > L then nl = L - e.s end
                        Roll.ResizeLive(e.i, nl)
                    end
                else
                    local st0 = Roll.starts[ni] or 0
                    local nlen = free and (ph - st0) or snapRound(ph - st0, s)
                    if nlen < minl then nlen = minl end
                    if st0 + nlen > L then nlen = L - st0 end
                    Roll.ResizeLive(ni, nlen)
                end
            end
            UI.SetCursor("size_we")
        elseif d.kind == "vel" then
            local v = (vy + VEL_H - my) / VEL_H * 127
            if d.multi and d.multi > 1 then
                for k = 1, d.multi do Roll.SetVelLive(move_snap[k].i, v) end
            else
                Roll.SetVelLive(ni, v)
            end
            state.vel = Roll.vels[ni]
            d.moved = true
        end
        if Core.MouseReleased(1) then
            if d.moved then Roll.Commit("loop edit") end
            state.edrag = nil
        end
    end

    -- marquee (right-drag box select) / right-click delete
    if state.marquee then
        if Core.MouseDown(2) then
            state.marquee.cx, state.marquee.cy = mx, my
            if math.abs(mx - state.marquee.x) > 4 or math.abs(my - state.marquee.y) > 4 then
                state.marquee.moved = true
            end
        else
            local m = state.marquee
            if m.moved then
                local cph = xToPhase(mx, rx, rw, L)
                local ta, tb = math.min(m.t0, cph), math.max(m.t0, cph)
                local pa = yToPitch(math.max(m.y, my), ry, rowh, lo, hi)
                local pb = yToPitch(math.min(m.y, my), ry, rowh, lo, hi)
                local n = Roll.SelectBox(ta, tb, math.min(pa, pb), math.max(pa, pb), add)
                flash(n .. " selected")
            elseif m.p0 then
                local idx = Roll.At(m.t0, m.p0)
                if idx then Roll.Delete(idx) end
            end
            state.marquee = nil
        end
        -- draw the marquee box
        local m = state.marquee
        if m then
            local x0, x1 = math.min(m.x, m.cx), math.max(m.x, m.cx)
            local y0, y1 = math.min(m.y, m.cy), math.max(m.y, m.cy)
            Core.DrawRect(x0, y0, x1 - x0, y1 - y0, acc[1], acc[2], acc[3], 0.16)
            Core.DrawRect(x0, y0, x1 - x0, y1 - y0, acc[1], acc[2], acc[3], 0.8, false)
        end
    end

    Core.SetFontBody()
    UI.RequestRedraw()               -- editing is interactive; keep it live
    UI.Layout.AdvanceCursor(w, avail)
end

-- Keyboard for the note editor — the SAME map as CP_Editor (via RollUI), so the
-- shortcuts carry over. Blocked mid-drag so a Commit → Sync can't strand the
-- drag's indices (mirrors the drawEditor sync guard).
local function editorKeys()
    if state.edit_lane == nil or state.edrag or state.marquee then return end
    if Core.HasPopup() then return end
    local char = Core.GetChar()
    if not char or char <= 0 then return end
    if Core.GetState().focus then return end
    if RollUI.HandleKey(char, loopCtx) then
        roll_ver = Loop.EvtVersion(state.edit_lane)
        Core.ConsumeChar()
        return
    end
    if char == Keys.ESCAPE then exitEdit(); Core.ConsumeChar() end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------
local last_init = -1     -- engine reset counter, watched to invalidate caches

-- Session recall. Loops live in gmem (REAPER-session scoped); this mirrors them
-- into the router track's P_EXT so they are saved inside the project. Written on
-- a trailing debounce so a note drag doesn't rewrite the blob every frame.
local save_vers = {}     -- [lane] = last EvtVersion mirrored
local save_due  = 0      -- time_precise deadline, 0 = clean
local recalled  = false  -- one auto-recall per attach
local last_router = nil  -- router GUID, to notice a project switch
local force_recall = false

local function pollPersist(attached)
    if not attached then recalled = false; return end

    -- gmem is REAPER-session scoped, so switching project inside one session
    -- leaves the PREVIOUS project's loops loaded. Noticing the router change is
    -- what makes recall feel automatic instead of "why are these not mine?".
    -- Forced, because those lanes are full of the other project's take — whose
    -- own copy is safe in its own .rpp. Never forced on the first attach: there
    -- the engine may legitimately hold a live set the user just recorded.
    local guid = Loop.track and r.GetTrackGUID(Loop.track) or nil
    if guid ~= last_router then
        if last_router ~= nil then recalled = false; force_recall = true end
        last_router = guid
    end

    -- Recall once. Non-forced it only fills an engine that holds nothing, which
    -- is every fresh REAPER session (the JSFX cold-inits gmem).
    if not recalled then
        recalled = true
        -- Clock and armed lane first, and UNCONDITIONALLY: they are session
        -- settings, not lane content, so they must survive even when the note
        -- recall below declines because the lanes are already full (reopening
        -- the window mid-session). That decline is why the clock kept snapping
        -- back to the startup default.
        Loop.LoadGlobals()
        local ok, n = Loop.LoadState(force_recall)
        force_recall = false
        if ok and n and n > 0 then
            for l = 0, LANES - 1 do ev[l].ver = -1 end
            roll_ver = -1
            flash("Loops recalled from the project")
        end
        for l = 0, LANES - 1 do
            save_vers[l] = Loop.EvtVersion(l) * 8 + math.floor(Loop.Mode(l) + 0.5)
        end
        return
    end

    local now = r.time_precise()
    if persist_dirty then
        persist_dirty = false
        save_due = now + 0.4
    end
    for l = 0, LANES - 1 do
        -- mode too, not just note edits: launching or stopping a clip changes
        -- the state to restore but bumps no event version
        local v = Loop.EvtVersion(l) * 8 + math.floor(Loop.Mode(l) + 0.5)
        if v ~= save_vers[l] then
            save_vers[l] = v
            -- short: you may hit Ctrl+S right after an edit, and anything still
            -- pending would simply not be in the project file
            save_due = now + 0.4          -- trailing: bumped, not reset
        end
    end
    if save_due > 0 and now >= save_due and not state.edrag then
        save_due = 0
        Loop.SaveState()
    end
end

local function frame(theme)
    if not (Loop.track and r.ValidatePtr2(0, Loop.track, "MediaTrack*")) then
        Loop.reconnect()
    end
    local attached = Loop.IsAttached()

    -- The engine resets more often than it looks (REAPER re-inits a JSFX on
    -- transport start, samplerate change, FX reload). The loops now survive it,
    -- but every per-instance cache on this side must be re-read — and saying so
    -- out loud is what makes a reset visible instead of mysterious.
    local ic = Loop.InitCount()
    if ic ~= last_init then
        if last_init >= 0 then
            for l = 0, LANES - 1 do ev[l].ver = -1 end
            roll_ver = -1
            flash("Engine reset — loops kept")
        end
        last_init = ic
    end

    pollPersist(attached)

    -- leaving a valid attachment (or losing it) drops out of the editor
    if state.edit_lane ~= nil and not attached then exitEdit() end

    drawToolbar(attached)
    UI.Spacing(4)

    if not attached then
        drawUnattached()
    elseif state.edit_lane ~= nil then
        editorKeys()
        drawEditor(theme)
    else
        local x, y = UI.GetCursorPos()
        local w = UI.GetAvailableWidth()
        local avail = UI.GetAvailableHeight() - 16   -- reserve a status line
        Core.SetFontCaption()
        local gap = 3
        local lane_h = math.floor((avail - gap * (LANES - 1)) / LANES)
        if lane_h < 90 then lane_h = 90 end
        for l = 0, LANES - 1 do
            drawLane(theme, l, x, y + l * (lane_h + gap), w, lane_h)
        end
        Core.SetFontBody()
        UI.Layout.AdvanceCursor(w, lane_h * LANES + gap * (LANES - 1))
        -- loops keep moving: never let the window idle out while playing
        if Loop.Playing() then UI.RequestRedraw() end
    end

    -- status flash
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            UI.SetFontCaption()
            UI.Text(state.flash_msg, { disabled = true })
            UI.SetFontBody()
            UI.RequestRedraw()
        else
            state.flash_msg = ""
        end
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("Looper", 470, 620, {
    persist    = CONFIG_ID,
    scrollable = false,
})

UI.OnClose(function()
    -- the debounce would drop anything edited in the last 1.5 s
    pcall(Loop.SaveState)
    Loop.Panic()
end)

r.atexit(function()
    pcall(Loop.SaveState)
    pcall(Loop.Panic)
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
