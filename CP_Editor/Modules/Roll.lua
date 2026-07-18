-- CP_Editor — Roll
-- MIDI layer for the piano roll: note cache + edit operations on a take.
--
-- Time domain: ITEM-RELATIVE seconds (the editor view's 0..len), converted
-- through MIDI_GetProjTimeFromPPQPos / MIDI_GetPPQPosFromProjTime so tempo
-- changes are always respected. The cache is structure-of-arrays (starts/
-- lens/pitches/vels), reused in place — Sync() is event-driven only.
--
-- Edit protocol: interactive drags call *Live() writers (MIDI_SetNote with
-- noSort — indices stay stable mid-drag), then ONE Commit() at release
-- sorts, re-reads and mints the undo point. Structural edits (insert/
-- delete) sort + sync + undo immediately.

local Roll = {}

local r  -- reaper, injected

Roll.take, Roll.item = nil, nil
Roll.count   = 0
Roll.starts  = {}   -- item-relative seconds
Roll.lens    = {}   -- seconds
Roll.pitches = {}   -- 0..127
Roll.vels    = {}   -- 1..127
Roll.sel     = nil  -- primary selected note (1-based index) or nil
Roll.selset  = {}   -- multi-selection: set { [idx] = true }
Roll.seln    = 0    -- count in selset
Roll.version = 0    -- bumped on every Sync (UI cache key)

local item_pos = 0

function Roll.init(reaper_api)
    r = reaper_api
end

local function ppq(t_rel)
    return r.MIDI_GetPPQPosFromProjTime(Roll.take, item_pos + t_rel)
end

function Roll.Attach(take, item)
    Roll.take, Roll.item = take, item
    Roll.sel = nil
    Roll.Sync()
end

function Roll.Detach()
    Roll.take, Roll.item = nil, nil
    Roll.count, Roll.sel = 0, nil
end

-- Re-read every note from the take (arrays reused, no per-frame use).
-- The selection is preserved BY IDENTITY (pitch + start): indices shift on
-- every re-read, so a raw index set would point at the wrong notes.
local sel_keep = {}
function Roll.Sync()
    local take = Roll.take
    if not take then
        Roll.count = 0
        Roll.ClearSel()
        return
    end
    -- snapshot the selection as (pitch, start) pairs
    local nkeep = 0
    for i in pairs(Roll.selset) do
        if Roll.pitches[i] then
            nkeep = nkeep + 1
            sel_keep[nkeep] = Roll.pitches[i] * 100000 + math.floor(Roll.starts[i] * 1000 + 0.5)
        end
    end

    item_pos = r.GetMediaItemInfo_Value(Roll.item, "D_POSITION")
    local _, notecnt = r.MIDI_CountEvts(take)
    for i = 0, notecnt - 1 do
        local _, _, _, sppq, eppq, _, pitch, vel = r.MIDI_GetNote(take, i)
        local t0 = r.MIDI_GetProjTimeFromPPQPos(take, sppq) - item_pos
        local t1 = r.MIDI_GetProjTimeFromPPQPos(take, eppq) - item_pos
        local j = i + 1
        Roll.starts[j]  = t0
        Roll.lens[j]    = t1 - t0
        Roll.pitches[j] = pitch
        Roll.vels[j]    = vel
    end
    Roll.count = notecnt

    -- re-select by identity
    Roll.ClearSel()
    if nkeep > 0 then
        for i = 1, notecnt do
            local key = Roll.pitches[i] * 100000 + math.floor(Roll.starts[i] * 1000 + 0.5)
            for k = 1, nkeep do
                if sel_keep[k] == key then Roll.AddSel(i) break end
            end
        end
        for k = nkeep, 1, -1 do sel_keep[k] = nil end
    end
    Roll.version = Roll.version + 1
end

-- ---------------------------------------------------------------------------
-- Selection set
-- ---------------------------------------------------------------------------
function Roll.ClearSel()
    local s = Roll.selset
    for k in pairs(s) do s[k] = nil end
    Roll.seln, Roll.sel = 0, nil
end

function Roll.SelectOnly(i)
    Roll.ClearSel()
    if i then Roll.selset[i] = true Roll.seln = 1 Roll.sel = i end
end

function Roll.AddSel(i)
    if i and not Roll.selset[i] then
        Roll.selset[i] = true
        Roll.seln = Roll.seln + 1
        Roll.sel = i
    end
end

function Roll.IsSel(i) return Roll.selset[i] == true end

-- Select every note whose start falls in [ta, tb] and pitch in [plo, phi].
function Roll.SelectBox(ta, tb, plo, phi, additive)
    if not additive then Roll.ClearSel() end
    for i = 1, Roll.count do
        local p = Roll.pitches[i]
        if p >= plo and p <= phi
           and Roll.starts[i] <= tb and Roll.starts[i] + Roll.lens[i] >= ta then
            Roll.AddSel(i)
        end
    end
    return Roll.seln
end

-- Select every note of a given pitch (drum-row header click).
function Roll.SelectPitch(pitch, additive)
    if not additive then Roll.ClearSel() end
    for i = 1, Roll.count do
        if Roll.pitches[i] == pitch then Roll.AddSel(i) end
    end
    return Roll.seln
end

-- Delete every selected note (right-to-left so indices stay valid).
function Roll.DeleteSel()
    if not Roll.take or Roll.seln == 0 then return end
    for i = Roll.count, 1, -1 do
        if Roll.selset[i] then r.MIDI_DeleteNote(Roll.take, i - 1) end
    end
    r.MIDI_Sort(Roll.take)
    Roll.Sync()
    Roll.ClearSel()
    r.Undo_OnStateChange("MIDI: delete notes")
end

-- Note under (t, pitch), topmost = last in order. Returns index or nil.
function Roll.At(t, pitch)
    for i = Roll.count, 1, -1 do
        if Roll.pitches[i] == pitch
           and t >= Roll.starts[i] and t < Roll.starts[i] + Roll.lens[i] then
            return i
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Structural edits (immediate undo point)
-- ---------------------------------------------------------------------------
function Roll.Insert(t, pitch, len, vel)
    if not Roll.take or len <= 0 then return end
    r.MIDI_InsertNote(Roll.take, false, false, ppq(t), ppq(t + len),
                      0, pitch, vel, false)
    r.MIDI_Sort(Roll.take)
    Roll.Sync()
    Roll.ClearSel()
    for i = 1, Roll.count do
        if Roll.pitches[i] == pitch and math.abs(Roll.starts[i] - t) < 0.001 then
            Roll.SelectOnly(i)
            break
        end
    end
    r.Undo_OnStateChange("MIDI: insert note")
end

function Roll.Delete(i)
    if not Roll.take or i < 1 or i > Roll.count then return end
    r.MIDI_DeleteNote(Roll.take, i - 1)
    r.MIDI_Sort(Roll.take)
    Roll.Sync()
    Roll.ClearSel()
    r.Undo_OnStateChange("MIDI: delete note")
end

-- ---------------------------------------------------------------------------
-- Live drag edits (no sort — indices stay stable) + Commit on release
-- ---------------------------------------------------------------------------
function Roll.MoveLive(i, t, pitch)
    if not Roll.take or i < 1 or i > Roll.count then return end
    r.MIDI_SetNote(Roll.take, i - 1, nil, nil,
                   ppq(t), ppq(t + Roll.lens[i]), nil, pitch, nil, true)
    Roll.starts[i], Roll.pitches[i] = t, pitch
end

function Roll.ResizeLive(i, len)
    if not Roll.take or i < 1 or i > Roll.count or len <= 0 then return end
    r.MIDI_SetNote(Roll.take, i - 1, nil, nil,
                   nil, ppq(Roll.starts[i] + len), nil, nil, nil, true)
    Roll.lens[i] = len
end

function Roll.SetVelLive(i, vel)
    if not Roll.take or i < 1 or i > Roll.count then return end
    if vel < 1 then vel = 1 elseif vel > 127 then vel = 127 end
    vel = math.floor(vel + 0.5)
    r.MIDI_SetNote(Roll.take, i - 1, nil, nil, nil, nil, nil, nil, vel, true)
    Roll.vels[i] = vel
end

function Roll.Commit(desc)
    if not Roll.take then return end
    r.MIDI_Sort(Roll.take)
    Roll.Sync()
    r.Undo_OnStateChange(desc or "MIDI edit")
end

-- Replace the notes of `pitch` inside [a, b) by n equal notes filling the
-- span (trap-roll subdivision: 1 → 2 → 4 → 8…). One undo point.
function Roll.Subdivide(a, b, pitch, vel, n)
    if not Roll.take or n < 1 or b <= a then return end
    for i = Roll.count, 1, -1 do
        if Roll.pitches[i] == pitch
           and Roll.starts[i] >= a - 0.0005 and Roll.starts[i] < b - 0.0005 then
            r.MIDI_DeleteNote(Roll.take, i - 1)
        end
    end
    local len = (b - a) / n
    for k = 0, n - 1 do
        local t0 = a + k * len
        r.MIDI_InsertNote(Roll.take, false, false, ppq(t0), ppq(t0 + len),
                          0, pitch, vel, true)
    end
    r.MIDI_Sort(Roll.take)
    Roll.Sync()
    Roll.sel = nil
    r.Undo_OnStateChange("MIDI: subdivide note")
end

-- ---------------------------------------------------------------------------
-- Batch
-- ---------------------------------------------------------------------------
-- Snap note starts through snap_fn (t → t'), lengths preserved. Acts on
-- the selected note when there is one, else on everything. Returns the
-- number of notes that moved.
function Roll.Quantize(snap_fn)
    if not Roll.take or Roll.count == 0 then return 0 end
    -- selection if any, else everything
    local function q(i)
        local t = snap_fn(Roll.starts[i])
        if math.abs(t - Roll.starts[i]) > 0.0005 then
            r.MIDI_SetNote(Roll.take, i - 1, nil, nil,
                           ppq(t), ppq(t + Roll.lens[i]), nil, nil, nil, true)
            return true
        end
        return false
    end
    local moved = 0
    if Roll.seln > 0 then
        for i in pairs(Roll.selset) do if q(i) then moved = moved + 1 end end
    else
        for i = 1, Roll.count do if q(i) then moved = moved + 1 end end
    end
    if moved > 0 then Roll.Commit("MIDI: quantize") end
    return moved
end

return Roll
