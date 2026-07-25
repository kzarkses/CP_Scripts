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
local Tracks = dofile(cp_root .. "CP_Engine/Tracks.lua")
local Loop = dofile(cp_root .. "CP_Engine/Loop.lua")
Tracks.init(r)
Loop.init(r, Tracks)
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
-- Shared row model (melodic window / drum pitch-list) — same one CP_Editor
-- uses, so drum mode behaves identically in both editors.
local Rows = dofile(cp_root .. "CP_Engine/Rows.lua")
-- Clip + Bus: the lane ↔ CP_Editor round trip — open a lane over there,
-- hear its edits come back live (editor:apply).
local Clip = dofile(cp_root .. "CP_Engine/Clip.lua")
local DragBus = dofile(cp_root .. "CP_Toolkit/DragBus.lua")
local Bus = dofile(cp_root .. "CP_Engine/Bus.lua")
DragBus.init(r)
Bus.init(r, DragBus, Clip)

-- ---------------------------------------------------------------------------
-- Config / state
-- ---------------------------------------------------------------------------
local CONFIG_ID = "CP_Looper"   -- window geometry persists automatically via UI.Init

-- The engine now serves 8 lanes, but the Looper keeps showing FOUR: the
-- upper half is the Session view's swap space (one silent twin per track,
-- see ANALYSE_Ableton_Session.md §3.2), not something to record into by
-- hand. Raising this is a deliberate decision, not a consequence.
local LANES    = math.min(4, Loop.MAX_LANES)
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
    edit_lane = nil,      -- STRIP (track) open in the note editor, or nil —
                          -- its engine lane is resolved per use, see editLane()
    engine_checked = false,   -- one-shot "is the loaded engine current" probe
    snap_idx  = 3,        -- SNAP_OPTS index (1/16)
    edrag     = nil,      -- active note drag { note, kind, grab, start0 }
    ed_lo     = 48, ed_hi = 78,   -- editor pitch range (melodic window)
    ed_drum   = false,    -- drum rows (arbitrary pitch list) in the editor
    vel       = 100,      -- velocity for newly drawn notes
    aud_note  = nil,      -- pending audition note-off (pitch)
    aud_off_t = 0,
}

-- Editor rows (host-owned; Rows.Build re-keys it on version/window change)
local erows = { list = {}, map = {}, n = 0, drum = false, key = nil }

-- Audition through the edited lane's routed instrument: the router track is
-- armed on all MIDI inputs, so the VKB queue reaches it and the JSFX
-- re-channels the note onto the armed lane (enterEdit arms the edited one).
-- Same deferred-note-off scheme as CP_Editor.
local function auditionNote(pitch, vel)
    if state.aud_note then r.StuffMIDIMessage(0, 0x80, state.aud_note, 0) end
    r.StuffMIDIMessage(0, 0x90, pitch, vel or state.vel or 100)
    state.aud_note = pitch
    state.aud_off_t = r.time_precise() + 0.2
end

-- A Roll backend that reads/writes the gmem note list of one lane (cache unit
-- is beats). sort/undo are no-ops: gate playback and identity-sync don't need
-- ordering, and gmem loops aren't part of REAPER's undo.
-- `strip` is a TRACK, and its two lanes swap under the editor as clips
-- change. Every closure resolves the lane at the moment it writes, so a swap
-- mid-edit moves the pen with the clip instead of leaving it on the one that
-- just left.
local function makeLoopBackend(strip)
    local LL = Loop.LiveLane
    return {
        readAll = function()
            local lane = LL(strip)
            local n = Loop.NoteCount(lane)
            for i = 1, n do
                local s, l, p, v = Loop.GetNote(lane, i - 1)
                Roll.starts[i], Roll.lens[i], Roll.pitches[i], Roll.vels[i] = s, l, p, v
            end
            return n
        end,
        insertNote = function(t, pitch, len, vel)
            local lane = LL(strip)
            local n = Loop.NoteCount(lane)
            if n >= Loop.MAX_NOTES then return end
            Loop.PutNote(lane, n, t, len, pitch, vel)
            Loop.SetNoteCount(lane, n + 1)
            Loop.BumpVer(lane)
        end,
        deleteNote = function(i)                     -- 1-based
            local lane = LL(strip)
            local n = Loop.NoteCount(lane)
            for k = i - 1, n - 2 do                  -- shift the tail down (0-based)
                local s, l, p, v = Loop.GetNote(lane, k + 1)
                Loop.PutNote(lane, k, s, l, p, v)
            end
            Loop.SetNoteCount(lane, n - 1)
            Loop.BumpVer(lane)
        end,
        setNote = function(i, t, len, pitch, vel)    -- 1-based, nil = keep
            local lane = LL(strip)
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
-- "Lane N" is drawn every frame for every strip: build the strings once, or
-- the label alone allocates four times per frame forever.
local LANE_LBL = {}
for l = 0, LANES - 1 do
    ev[l] = { bo = {}, bd = {}, bn = {}, bv = {}, bc = 0, ver = -1, lenB = -1,
              lane = -1, lo = 48, hi = 72 }
    LANE_LBL[l] = "Lane " .. (l + 1)
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
-- `l` is the strip (track) the cache belongs to; `el` the engine lane it
-- currently reads. The lane is part of the key: a swap can land on a version
-- number the cache already saw, and the strip would keep drawing the notes
-- of the clip that just left.
local function refreshLane(l, el)
    local e = ev[l]
    local ver  = Loop.EvtVersion(el)
    local lenB = Loop.LenBeats(el)
    if ver == e.ver and lenB == e.lenB and el == e.lane then return end
    e.ver, e.lenB, e.lane = ver, lenB, el

    e.bc = Loop.ReadNotes(el, e.bo, e.bd, e.bn, e.bv)  -- start, len, pitch, vel

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
-- (row↔pitch math lives in Engine/Rows now — shared with CP_Editor)

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

-- Export a lane as a real MIDI item in the arrange — the jam no longer
-- dies in the looper. Lands on the lane's routed instrument track
-- (fallback: the selected track), at the edit cursor, one loop long;
-- note times are beats, so QN mapping keeps tempo maps honest.
local function exportLaneToItem(lane)
    local n = Loop.NoteCount(lane)
    if n <= 0 then flash("Nothing to export") return end
    local tr = Loop.GetLaneDest(lane) or r.GetSelectedTrack(0, 0)
    if not tr then flash("Route the lane (or select a track) first") return end
    local pos = r.GetCursorPosition()
    local qn0 = r.TimeMap2_timeToQN(0, pos)
    local Lb = Loop.LenBeats(lane)
    r.Undo_BeginBlock2(0)
    local item = r.CreateNewMIDIItemInProj(tr, pos, r.TimeMap2_QNToTime(0, qn0 + Lb), false)
    local take = item and r.GetActiveTake(item)
    if not take then
        r.Undo_EndBlock2(0, "CP Looper: lane to MIDI item", -1)
        flash("Item creation failed")
        return
    end
    for i = 0, n - 1 do
        local s, l, p, v = Loop.GetNote(lane, i)
        local e = s + l
        if e > Lb then e = Lb end               -- the item is one loop long
        r.MIDI_InsertNote(take, false, false,
            r.MIDI_GetPPQPosFromProjQN(take, qn0 + s),
            r.MIDI_GetPPQPosFromProjQN(take, qn0 + e),
            0, math.floor((p or 60) + 0.5), math.floor((v or 100) + 0.5), true)
    end
    r.MIDI_Sort(take)
    r.Undo_EndBlock2(0, "CP Looper: lane to MIDI item", -1)
    r.UpdateArrange()
    flash("Lane " .. (lane + 1) .. " -> MIDI item")
end

-- Native item drag from the ARRANGE onto a lane: REAPER holds the mouse
-- capture during an item drag, so we poll the OS cursor. Arm on a press
-- that starts over the arrange with a selected item; on release over a
-- lane, the item's MIDI becomes that lane's clip. Non-destructive: the
-- item never moves (REAPER cancels its own drag outside the arrange).
local lane_geom = { x = 0, y0 = 0, w = 0, h = 0, gap = 3, valid = false }
local arr = { armed = false, was_down = false }

local function laneAt(cx, cy)
    if not lane_geom.valid then return nil end
    local step = lane_geom.h + lane_geom.gap
    local i = math.floor((cy - lane_geom.y0) / step)
    if i < 0 or i >= LANES then return nil end
    if (cy - lane_geom.y0) - i * step > lane_geom.h then return nil end
    if cx < lane_geom.x or cx >= lane_geom.x + lane_geom.w then return nil end
    return i
end

-- The take's MIDI, loaded into a lane (event-driven; allocations fine).
-- Note times become beats relative to the item start; notes at/after the
-- loop end are dropped rather than silently never playing.
local function takeToLane(take, lane)
    local item = r.GetMediaItemTake_Item(take)
    local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local qn0 = r.TimeMap2_timeToQN(0, pos)
    local _, ncnt = r.MIDI_CountEvts(take)
    if not ncnt or ncnt == 0 then return false end
    local len_qn = r.TimeMap2_timeToQN(0,
        pos + r.GetMediaItemInfo_Value(item, "D_LENGTH")) - qn0
    local tsn = Loop.TsNum()
    local bars = math.max(1, math.floor(len_qn / tsn + 0.5))
    local lim = bars * tsn
    local s, l, p, v = {}, {}, {}, {}
    for i = 0, ncnt - 1 do
        if #s >= Loop.MAX_NOTES then break end
        local _, _, _, sppq, eppq, _, pitch, vel = r.MIDI_GetNote(take, i)
        local sq = r.MIDI_GetProjQNFromPPQPos(take, sppq) - qn0
        local eq = r.MIDI_GetProjQNFromPPQPos(take, eppq) - qn0
        if sq >= 0 and sq < lim then
            s[#s + 1] = sq
            l[#l + 1] = math.max(0.05, math.min(eq, lim) - sq)
            p[#p + 1] = pitch
            v[#v + 1] = vel
        end
    end
    if #s == 0 then return false end
    return Loop.ClipToLane(lane, {
        kind = "midi", notes = { s = s, l = l, p = p, v = v }, bars = bars,
    })
end

local function arrangeDropPoll()
    if not (r.JS_Mouse_GetState and r.JS_Window_FromPoint) then return end
    if state.edit_lane ~= nil then arr.armed = false end
    local down = (r.JS_Mouse_GetState(1) & 1) == 1
    local sx, sy = r.GetMousePosition()
    local cx, cy = Core.ScreenToClient(sx, sy)
    local over_us = cx >= 0 and cy >= 0 and cx < gfx.w and cy < gfx.h
    if down and not arr.was_down then
        arr.armed = false
        if not over_us and r.CountSelectedMediaItems(0) > 0 then
            local w = r.JS_Window_FromPoint(sx, sy)
            if w and r.JS_Window_GetClassName(w) == "REAPERTrackListWindow" then
                arr.armed = true
            end
        end
    elseif not down and arr.was_down then
        if arr.armed and over_us then
            local lane = laneAt(cx, cy)
            local item = r.GetSelectedMediaItem(0, 0)
            local take = item and r.GetActiveTake(item)
            if lane and take and r.TakeIsMIDI(take) then
                if takeToLane(take, lane) then
                    ev[lane].ver = -1
                    flash("Item -> lane " .. (lane + 1))
                else
                    flash("Nothing usable in that item")
                end
            end
        end
        arr.armed = false
    end
    if arr.armed and down and over_us then UI.RequestRedraw() end
    arr.was_down = down
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
-- state.edit_lane names the STRIP being edited; this is the engine lane it
-- currently maps to. Always go through it — never through the raw field.
local function editLane()
    local t = state.edit_lane
    return t and Loop.LiveLane(t) or nil
end

local function barBeats()
    local lane = editLane()
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
    audition = function(p, v) auditionNote(p, v) end,
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
        local lane = editLane()
        return lane and Loop.LenBeats(lane) or nil
    end,
    grow      = function(need)
        local lane = editLane()
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

local function enterEdit(strip)
    state.edit_lane = strip          -- the STRIP; the lane is resolved per use
    state.edrag = nil
    state.marquee = nil
    local lane = Loop.LiveLane(strip)
    Loop.SetArmedLane(lane)          -- editing a lane arms it for live input
    Roll.SetBackend(makeLoopBackend(strip))
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
-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## CP Looper
4 lanes loop against the beat grid (an external clock follows for
free). REC captures; click again to lock — the clip plays. Shift+
click REC = OVERDUB: layer into the playing loop, the red OVR button
punches out. Q queues launch/stop on the grid (the status blinks
until the boundary; clicking again cancels).

## Lanes
Play/Stop launch clips Ableton-style; Length cycles bars; the Lane
label arms what you hear; each lane routes to its own instrument
track (-> track). Drag an item from the arrange onto a lane to load
its MIDI.

## Editor
Click a mini-roll: draw, drag, marquee, velocity lane — same keys as
CP_Editor. Keys/Drum switches rows (drum rows = the routed kit's
pads, named). "To item" exports to the arrange; "Editor" opens the
lane in CP_Editor and its edits come back live.

## Clock
Free = internal clock, clips play with the transport stopped.
Follow = REAPER transport (locks to an external MIDI clock).
]]

local function drawToolbar(attached)
    UI.SetFontH2(); UI.Text("Looper"); UI.SetFontBody()
    UI.SameLine(6)
    UI.HelpButton("help", HELP_TEXT)
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
        -- Launch quantize (Ableton-style): commands wait for the next boundary.
        -- Cycles Off -> beat -> bar -> 2 bars -> 4 bars; stored in beats so the
        -- engine never needs to know about bars.
        local q   = Loop.GetLaunchQ()
        local tsn = Loop.TsNum()
        local qlbl
        if q <= 0 then                            qlbl = "Q: Off"
        elseif math.abs(q - 1) < 0.01 then        qlbl = "Q: Beat"
        elseif math.abs(q - tsn) < 0.01 then      qlbl = "Q: Bar"
        elseif math.abs(q - 2 * tsn) < 0.01 then  qlbl = "Q: 2 bars"
        elseif math.abs(q - 4 * tsn) < 0.01 then  qlbl = "Q: 4 bars"
        else                                      qlbl = string.format("Q: %g bt", q) end
        if UI.Button("launchq", qlbl) then
            local nq
            if q <= 0 then                            nq = 1
            elseif math.abs(q - 1) < 0.01 then        nq = tsn
            elseif math.abs(q - tsn) < 0.01 then      nq = 2 * tsn
            elseif math.abs(q - 2 * tsn) < 0.01 then  nq = 4 * tsn
            else                                      nq = 0 end
            Loop.SetLaunchQ(nq)
            persist_dirty = true
            flash(nq <= 0 and "Launch quantize off" or
                  string.format("Launch quantize: %g beat%s", nq, nq > 1 and "s" or ""))
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

-- `l` names the strip (its note cache), `el` the engine lane it reads.
local function drawViz(theme, l, el, x, y, w, h, mode)
    local C = theme.colors
    local e = ev[l]
    -- backdrop
    Core.DrawRect(x, y, w, h, 0.11, 0.11, 0.12, 1)

    local lenB  = Loop.LenBeats(el)
    local tsnum = Loop.TsNum()

    -- beat / bar gridlines, same ranking and colour as the note editor (this
    -- strip is too short for subdivisions, so it stops at the first two tiers)
    local A = RollUI.GRID_ALPHA
    local gcol = C.text_mute or C.text_disabled
    local nb = math.floor(lenB + 0.5)
    if nb < 1 then nb = 1 end
    for b = 0, nb do
        local gx = x + (b / lenB) * w
        Core.DrawLine(gx, y, gx, y + h, gcol[1], gcol[2], gcol[3],
                      A[(b % tsnum) == 0 and 1 or 2])
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

    -- playhead (while the clip is playing — overdub plays too)
    if mode == 3 or mode == 5 then
        local ph = Loop.Phase(el)
        local px = x + (ph / lenB) * w
        Core.DrawLine(px, y, px, y + h, 1, 1, 1, 0.65)
    end

    -- recording tint (dimmer while merely armed; overdub = capture too)
    if mode == 1 or mode == 5 then
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
    -- A strip here is a TRACK, and the engine gives a track TWO lanes: the
    -- one you hear and a silent twin the Session stages clips through. Which
    -- is which changes under us, so it is asked for — every frame, from the
    -- engine — instead of assumed. That is why this window now shows the
    -- clip the grid is actually playing.
    local el = Loop.LiveLane(l)
    refreshLane(l, el)
    local mode  = math.floor(Loop.Mode(el) + 0.5)   -- 0 empty,1 rec,2 stopped,3 playing,4 armed
    local muted = Loop.GetMute(el)
    local nev   = math.floor(Loop.NEv(el) + 0.5)
    local pend  = Loop.Pending(el)                  -- 0 none,1 play,2 stop,3 rec,4 stop-rec

    -- panel
    Core.DrawRect(x, y, w, h, C.surface[1], C.surface[2], C.surface[3], 1)
    Core.DrawRect(x, y, w, h, C.border[1], C.border[2], C.border[3], C.border[4] or 0.5, false)

    local pad = 6
    -- header: the "Lane N" label doubles as the arm-for-live-input control.
    -- Arming is a TRACK fact: the engine monitors one lane, and the pair
    -- swaps under it — comparing the track keeps the light on the strip the
    -- user armed instead of making it hop to its twin.
    local armed = (Loop.TrackOfLane(Loop.GetArmedLane()) == l)
    local lbl = LANE_LBL[l]
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
            if Core.MouseClicked(1) then Loop.SetArmedLane(el) end
        end
    end
    -- status word (right)
    local sw, scr, scg, scb
    if mode == 1 then sw, scr, scg, scb = "REC", C.danger[1], C.danger[2], C.danger[3]
    elseif mode == 5 then sw, scr, scg, scb = "OVER", C.danger[1], C.danger[2], C.danger[3]
    elseif mode == 4 then sw, scr, scg, scb = "ARM", 0.85, 0.65, 0.25
    elseif mode == 3 then sw, scr, scg, scb = "PLAY", 0.30, 0.75, 0.40
    elseif mode == 2 then sw, scr, scg, scb = "STOP", C.text_mute[1], C.text_mute[2], C.text_mute[3]
    else sw, scr, scg, scb = "", C.text_mute[1], C.text_mute[2], C.text_mute[3] end
    if muted and mode ~= 1 and mode ~= 4 then sw = "MUTE"; scr, scg, scb = 0.85, 0.65, 0.25 end
    -- a queued launch outranks the mode word, and blinks until it fires
    local sa = 1
    if pend > 0 then
        if pend == 1 then sw = "> PLAY"
        elseif pend == 2 then sw = "> STOP"
        elseif pend == 3 then sw = "> REC"
        elseif pend == 5 then sw = "> OVR"
        else sw = "> END" end
        scr, scg, scb = 0.85, 0.65, 0.25
        sa = 0.45 + 0.55 * math.abs(math.sin(r.time_precise() * 5))
    end
    if sw ~= "" then
        local tw = gfx.measurestr(sw)
        Core.DrawText(sw, x + w - pad - tw, y + 5, scr, scg, scb, sa)
    end

    -- controls row
    local cy = y + 22
    local bh = 20
    local bx = x + pad

    -- REC (click while recording/armed = finish the take / cancel the arm;
    -- click while a rec is queued = cancel the queue)
    if pend == 3 then
        if tinyBtn(bx, cy, 46, bh, "REC", 0.85, 0.65, 0.25, theme) then
            Loop.Rec(el); flash("Lane " .. (l + 1) .. ": queued rec cancelled")
        end
    elseif pend == 5 then
        if tinyBtn(bx, cy, 46, bh, "OVR", 0.85, 0.65, 0.25, theme) then
            Loop.Overdub(el); flash("Lane " .. (l + 1) .. ": queued overdub cancelled")
        end
    elseif mode == 1 then
        if tinyBtn(bx, cy, 46, bh, "REC", C.danger[1], C.danger[2], C.danger[3], theme) then
            Loop.Stop(el)
        end
    elseif mode == 5 then
        -- overdubbing: click punches out (finalize, keep playing)
        if tinyBtn(bx, cy, 46, bh, "OVR", C.danger[1], C.danger[2], C.danger[3], theme) then
            Loop.Overdub(el); flash("Lane " .. (l + 1) .. ": overdub off")
        end
    elseif mode == 4 then
        if tinyBtn(bx, cy, 46, bh, "ARM", 0.72, 0.55, 0.20, theme) then
            Loop.Stop(el); flash("Lane " .. (l + 1) .. ": arm cancelled")
        end
    else
        -- Shift+click on a lane with content = OVERDUB (layer into the loop);
        -- plain click = the destructive re-record
        if tinyBtn(bx, cy, 46, bh, "REC", 0.30, 0.30, 0.32, theme) then
            if Core.ModShift() and nev > 0 and (Loop.GetFreeRun() or Loop.Playing()) then
                Loop.SetArmedLane(el); Loop.Overdub(el)
                flash("Lane " .. (l + 1) .. ": overdub - play over the loop")
            else
                Loop.SetArmedLane(el); Loop.Rec(el)
                -- with the clock stopped the engine arms instead of wiping the lane
                if Loop.GetFreeRun() or Loop.Playing() then
                    flash("Lane " .. (l + 1)
                          .. (Loop.GetLaunchQ() > 0 and ": rec queued" or ": recording"))
                else
                    flash("Lane " .. (l + 1) .. ": armed - starts on play")
                end
            end
        end
    end
    bx = bx + 50

    -- PLAY / STOP clip (only meaningful with content). While queued, the same
    -- button cancels: the engine treats the opposite command as the cancel.
    if pend == 1 then
        if tinyBtn(bx, cy, 46, bh, "Play", 0.85, 0.65, 0.25, theme) then
            Loop.StopClip(el); flash("Lane " .. (l + 1) .. ": launch cancelled")
        end
    elseif pend == 2 then
        if tinyBtn(bx, cy, 46, bh, "Stop", 0.85, 0.65, 0.25, theme) then
            Loop.Play(el); flash("Lane " .. (l + 1) .. ": stop cancelled")
        end
    elseif mode == 3 or mode == 5 then
        if tinyBtn(bx, cy, 46, bh, "Stop", 0.28, 0.66, 0.38, theme) then Loop.StopClip(el) end
    elseif mode == 2 then
        if tinyBtn(bx, cy, 46, bh, "Play", 0.22, 0.30, 0.24, theme) then
            Loop.Play(el)
            flash("Lane " .. (l + 1)
                  .. ((Loop.GetLaunchQ() > 0 and (Loop.GetFreeRun() or Loop.Playing()))
                      and ": launch queued" or ": play"))
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
        Loop.Clear(el); flash("Lane " .. (l + 1) .. " cleared")
    end
    bx = bx + 48

    -- MUTE
    if tinyBtn(bx, cy, 42, bh, "Mute",
               muted and 0.85 or 0.24, muted and 0.65 or 0.24, muted and 0.25 or 0.26, theme) then
        Loop.SetMute(el, not muted)
    end
    bx = bx + 46

    -- LENGTH
    local bars = math.floor(Loop.GetLengthBars(el) + 0.5)
    if bars < 1 then bars = 1 end
    if tinyBtn(bx, cy, 54, bh, bars .. (bars > 1 and " bars" or " bar"),
               0.20, 0.22, 0.26, theme) then
        Loop.SetLengthBars(el, nextLen(bars))
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
        drawViz(theme, l, el, vx, vy, vw, vh, mode)
        local mx, my = Core.GetMousePos()
        if mx >= vx and mx < vx + vw and my >= vy and my < vy + vh and not Core.HasPopup() then
            UI.SetCursor("hand")
            if Core.MouseClicked(1) then
                -- THE editor gets the click (Ableton semantics): the lane
                -- opens in CP_Editor — launched if it isn't running — and
                -- its edits come back live. Alt+click keeps the embedded
                -- quick editor.
                if Core.ModAlt() then
                    enterEdit(l)
                else
                    local c = Loop.LaneToClip(el)
                    if not c then
                        c = Clip.new("midi")
                        c.notes = { s = {}, l = {}, p = {}, v = {} }
                        c.bars = Loop.GetLengthBars(el)
                    end
                    -- the TRACK, not the lane: which half holds the clip is
                    -- the engine's answer and the editor asks it per frame
                    c.origin = "looper:" .. l
                    c.name = LANE_LBL[l]
                    Bus.OpenEditor(c)
                end
            end
            -- edit hint (bottom-right of the roll)
            local hint = "click: CP_Editor · Alt: quick edit"
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
    local strip = state.edit_lane
    local lane = Loop.LiveLane(strip)   -- resolved per frame: the pair swaps
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
    local lnlbl = LANE_LBL[strip] or "Lane"
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
        -- routing is a TRACK fact (both halves of the pair go to the same
        -- instrument), so it is addressed by the strip
        local dst = Loop.GetLaneDest(strip)
        local dn
        if dst then local _, nm = r.GetTrackName(dst); dn = "→ " .. (nm ~= "" and nm or "track")
        else dn = "→ no track" end
        if tinyBtn(dbx, hy, dbw, hbh, truncPix(dn, dbw - 8),
                   dst and 0.20 or 0.30, dst and 0.24 or 0.20, dst and 0.22 or 0.20, theme) then
            pickLaneDest(strip)
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
    if tinyBtn(x + 206, hy2, 52, hbh, state.ed_drum and "Drum" or "Keys",
               state.ed_drum and 0.26 or 0.20, state.ed_drum and 0.30 or 0.22, 0.26, theme) then
        state.ed_drum = not state.ed_drum
    end
    if tinyBtn(x + 262, hy2, 56, hbh, "To item", 0.22, 0.26, 0.32, theme) then
        exportLaneToItem(lane)
    end
    -- hand the lane to CP_Editor (universal editor): it edits the clip and
    -- its editor:apply messages land back in this lane live
    if tinyBtn(x + 322, hy2, 52, hbh, "Editor", 0.22, 0.26, 0.32, theme) then
        local c = Loop.LaneToClip(lane)
        if c then
            c.origin = "looper:" .. lane
            Bus.Send("editor:open", c)
            flash("Lane sent to CP_Editor")
        else
            flash("Empty lane")
        end
    end
    Core.DrawText(selHint(), x + 384, hy2 + 5,
                  C.text_mute[1], C.text_mute[2], C.text_mute[3], 0.85)

    -- roll area: a note grid above a velocity lane. Rows come from the
    -- shared model — melodic window (ed_lo..ed_hi) or drum pitch list.
    -- Drum rows mirror the routed kit's pads (one row per loaded sample,
    -- labeled with the pad name), plus whatever pitches the clip already
    -- uses — not just the clip, which collapsed to the first drawn note.
    local kv = state.ed_drum and Loop.KitView(lane) or nil
    local rows = Rows.Build(erows, {
        drum = state.ed_drum, roll = Roll, kit = kv,
        view_hi = state.ed_hi, view_rows = state.ed_hi - state.ed_lo + 1,
    })
    if not rows.drum then
        state.ed_hi = rows.view_hi
        state.ed_lo = rows.view_hi - rows.view_rows + 1
    end
    local kbw = rows.drum and 56 or 24
    local VEL_H = 34
    local rx, ry = x + kbw, hy2 + hbh + 6
    local rw = w - kbw
    local grid_h = avail - (ry - y) - 2 - VEL_H - 4
    if grid_h < 24 or rows.n < 1 then Core.SetFontBody() return end
    local rowh = grid_h / rows.n
    local vy = ry + grid_h + 4

    -- pitch rows + label column (piano keys / drum note names)
    for i = 1, rows.n do
        local p = rows.list[i]
        local yy = ry + (i - 1) * rowh
        local blk = BLACK_KEY[p % 12]
        local sh
        if rows.drum then
            sh = (i % 2 == 0) and 0.125 or 0.10
        else
            sh = blk and 0.095 or 0.13
            if Roll.scale_on and not Roll.InScale(p) then sh = sh * 0.5 end   -- scale dim
        end
        Core.DrawRect(rx, yy, rw, rowh + 0.5, sh, sh, sh + 0.006, 1)
        if not rows.drum and p % 12 == 0 then
            Core.DrawLine(rx, yy, rx + rw, yy, C.border[1], C.border[2], C.border[3], 0.4)
        end
        if rows.drum then
            Core.DrawRect(x, yy, kbw - 1, rowh + 0.5, 0.17, 0.17, 0.19, 1)
            if rowh >= 8 then
                Core.DrawText(Rows.Label(rows, p, kv), x + 3, yy + rowh * 0.5 - 5,
                              C.text[1], C.text[2], C.text[3], 0.9)
            end
        else
            local kc = blk and 0.16 or 0.80
            Core.DrawRect(x, yy, kbw - 1, rowh + 0.5, kc, kc, kc + 0.02, 1)
            if p % 12 == 0 and rowh >= 7 then
                Core.DrawText(OCT_LBL[p] or "C", x + 1, yy + rowh * 0.5 - 4, 0.2, 0.2, 0.2, 1)
            end
        end
    end

    -- Vertical grid, drawn weakest-first so the strongest weight wins wherever
    -- lines coincide: subdivisions, eighths, then beats and barlines together.
    -- Ranked through the shared RollUI table, so a barline looks like a
    -- barline in this roll and in CP_Editor alike. The loop axis is beats and
    -- phase 0 is bar-aligned by construction, so all of it is arithmetic.
    local A = RollUI.GRID_ALPHA
    -- text_mute, the same key CP_Editor's roll reads: these two used to pull
    -- from different colours, so a barline changed shade between windows
    local gcol = C.text_mute or C.text_disabled
    local br, bgc, bbc = gcol[1], gcol[2], gcol[3]
    local s = snapBeats()
    if s > 0 and s < 1 then                      -- the snap's own subdivisions
        for i = 0, math.floor(L / s + 1e-6) do
            local gx = phaseToX(i * s, rx, rw, L)
            Core.DrawLine(gx, ry, gx, ry + grid_h, br, bgc, bbc, A[4])
        end
    end
    if s > 0 and s <= 0.5 + 1e-9 then            -- eighths, once we work that fine
        for i = 0, math.floor(L * 2 + 1e-6) do
            local gx = phaseToX(i * 0.5, rx, rw, L)
            Core.DrawLine(gx, ry, gx, ry + grid_h, br, bgc, bbc, A[3])
        end
    end
    for b = 0, math.floor(L + 1e-6) do           -- beats, barlines stronger
        local gx = phaseToX(b, rx, rw, L)
        Core.DrawLine(gx, ry, gx, ry + grid_h, br, bgc, bbc,
                      A[(b % tsnum) == 0 and 1 or 2])
    end

    -- notes
    local acc = C.accent
    for i = 1, Roll.count do
        local yy = Rows.YOfPitch(rows, Roll.pitches[i], ry, rowh)
        if yy then
            local nx = phaseToX(Roll.starts[i], rx, rw, L)
            local nw = Roll.lens[i] / L * rw
            if nw < 3 then nw = 3 end
            if nx + nw > rx + rw then nw = rx + rw - nx end
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
    -- fills the width, so horizontal (Shift/Alt) is a no-op here — and drum
    -- rows are a fixed list, so the wheel only drives the melodic window.
    if (inGrid or inVel) and not Core.ModShift() and not Core.ModAlt()
       and not rows.drum then
        local wheel = Core.GetState().mouse_wheel
        if wheel and wheel ~= 0 then
            local lo, hi = state.ed_lo, state.ed_hi
            local notches = wheel / 120
            local span = hi - lo + 1
            if Core.ModCtrl() then                    -- vertical zoom about the mouse pitch
                local anchor = Rows.PitchAtY(rows, my, ry, rowh)
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

    -- label column: click selects that whole pitch row (as in CP_Editor),
    -- right-click auditions it through the lane's routed instrument
    if mx >= x and mx < rx and my >= ry and my < ry + grid_h and not Core.HasPopup()
       and not state.edrag and not state.marquee then
        UI.SetCursor("hand")
        if Core.MouseClicked(1) then
            flash(Roll.SelectPitch(Rows.PitchAtY(rows, my, ry, rowh), add) .. " selected")
        elseif Core.MouseClicked(2) then
            auditionNote(Rows.PitchAtY(rows, my, ry, rowh), state.vel)
        end
    end

    -- grid presses (only when no drag / marquee is already live)
    if inGrid and not state.edrag and not state.marquee then
        local ph  = xToPhase(mx, rx, rw, L)
        local pit = Rows.PitchAtY(rows, my, ry, rowh)
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
                    auditionNote(pit, state.vel)
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
                local np = Rows.PitchAtY(rows, my, ry, rowh)
                if d.multi and d.multi > 1 then
                    -- group move: the vertical delta is in ROWS, not semitones —
                    -- drum rows are an arbitrary pitch list where one row can be
                    -- a 7-semitone jump, and a pitch delta would throw every
                    -- other note between the pads. Melodic rows are contiguous,
                    -- where the two deltas are the same thing.
                    local dt = nt - d.op
                    if rows.drum then
                        local drow = (rows.map[np] or 0) - (rows.map[d.opp] or 0)
                        for k = 1, d.multi do
                            local e = move_snap[k]
                            local ns = e.s + dt; if ns < 0 then ns = 0 elseif ns > L - e.l then ns = math.max(0, L - e.l) end
                            Roll.MoveLive(e.i, ns, Rows.Shift(rows, e.p, drow))
                        end
                    else
                        local dp = np - d.opp
                        for k = 1, d.multi do
                            local e = move_snap[k]
                            local ns = e.s + dt; if ns < 0 then ns = 0 elseif ns > L - e.l then ns = math.max(0, L - e.l) end
                            local npp = e.p + dp; if npp < 0 then npp = 0 elseif npp > 127 then npp = 127 end
                            Roll.MoveLive(e.i, ns, npp)
                        end
                    end
                else
                    if np ~= Roll.pitches[ni] then auditionNote(np, Roll.vels[ni]) end
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
                -- rows → pitch range: the list is sorted, so every pitch
                -- between the extremes of the spanned rows belongs to one
                -- of them — a numeric SelectBox stays row-accurate
                local ra = Rows.AtY(rows, math.min(m.y, my), ry, rowh)
                local rb = Rows.AtY(rows, math.max(m.y, my), ry, rowh)
                local plo, phi = 127, 0
                for rr = ra, rb do
                    local pp = rows.list[rr]
                    if pp then
                        if pp < plo then plo = pp end
                        if pp > phi then phi = pp end
                    end
                end
                local n = (phi >= plo) and Roll.SelectBox(ta, tb, plo, phi, add) or 0
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
        roll_ver = Loop.EvtVersion(editLane())
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
    -- Once per window: an engine loaded before this build silently drops
    -- every command aimed at the lanes it does not scan. The loops live in
    -- gmem and survive the refresh.
    if attached and not state.engine_checked then
        state.engine_checked = true
        local _, note = Loop.Ensure(false)
        if note then flash(note) end
    end
    -- one call: gmem re-selected, one queued command out, and the live half
    -- of each lane pair re-derived. Everything below reads one picture — the
    -- same one the Session grid and CP_Editor read.
    Loop.Poll()

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

    -- edits coming home from CP_Editor (a lane opened there via the "Editor"
    -- button): apply notes + length WITHOUT touching the lane's mode, so a
    -- playing loop keeps playing through the edit.
    if attached then
        local ac = Bus.Recv("editor:apply")
        if ac and ac.origin then
            local ln = tonumber(ac.origin:match("^looper:(%d+)"))
            if ln then
                -- origin names a track (older descriptors named a raw lane;
                -- lane 5 has always meant track 1). The edit goes to the half
                -- actually HOLDING the clip, so it never lands on the twin.
                local st = Loop.TrackOfLane(ln)
                local el = Loop.LaneOfTag(st, Clip.CellTag(ac.cell))
                if el and st < LANES and Loop.ApplyClip(el, ac) then
                    ev[st].ver = -1
                    roll_ver = -1
                end
            end
        end
    end

    -- leaving a valid attachment (or losing it) drops out of the editor
    if state.edit_lane ~= nil and not attached then exitEdit() end

    -- deferred audition note-off (editor clicks through the router's live thru)
    if state.aud_note and r.time_precise() >= state.aud_off_t then
        r.StuffMIDIMessage(0, 0x80, state.aud_note, 0)
        state.aud_note = nil
    end

    drawToolbar(attached)
    UI.Spacing(4)

    if not attached then
        drawUnattached()
    elseif state.edit_lane ~= nil then
        lane_geom.valid = false
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
        lane_geom.x, lane_geom.y0, lane_geom.w = x, y, w
        lane_geom.h, lane_geom.gap, lane_geom.valid = lane_h, gap, true
        arrangeDropPoll()
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
    if state.aud_note then r.StuffMIDIMessage(0, 0x80, state.aud_note, 0) end
    Loop.Panic()
end)

r.atexit(function()
    pcall(Loop.SaveState)
    if state.aud_note then pcall(r.StuffMIDIMessage, 0, 0x80, state.aud_note, 0) end
    pcall(Loop.Panic)
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
