-- @description CP ChordLab — REAPER MIDI item analysis and segment write/replace
-- @author Cedric Pamalio

-- REAPER-side module. Reads MIDI notes from a take, groups them into Segments
-- (onset clustering or measure-anchored grid), and performs rhythm-preserving
-- chord replacement / block writes. Depends on the pure Theory + Voicing modules
-- injected via Init.
--
-- Lua 5.3 hazard: PPQ, project time and QN values from the API are ALWAYS
-- floats. Never string.format("%d", ...) them and never index tables with them
-- without math.floor. Note idx values from MIDI_GetNote are integers; any write
-- invalidates every stored idx (caller must re-Analyze after a mutation).

local r = reaper

local M = {}

local Theory, Voicing

function M.Init(theory, voicing)
    Theory = theory
    Voicing = voicing
end

-- ---------------------------------------------------------------------------
-- Time / PPQ wrappers
-- ---------------------------------------------------------------------------

function M.TimeToPpq(take, t)
    return r.MIDI_GetPPQPosFromProjTime(take, t)
end

function M.PpqToTime(take, ppq)
    return r.MIDI_GetProjTimeFromPPQPos(take, ppq)
end

-- ---------------------------------------------------------------------------
-- Target selection
-- ---------------------------------------------------------------------------

-- First selected item whose active take is MIDI. Uses CountMediaItems/GetMediaItem
-- + IsMediaItemSelected (the docs flag GetSelectedMediaItem as inefficient across
-- edits). Returns take, item | nil, nil.
function M.GetTarget()
    local proj = 0
    local n = r.CountMediaItems(proj)
    for i = 0, n - 1 do
        local item = r.GetMediaItem(proj, i)
        if item and r.IsMediaItemSelected(item) then
            local take = r.GetActiveTake(item)
            if take and r.TakeIsMIDI(take) then
                return take, item
            end
        end
    end
    return nil, nil
end

-- Notes-only hash; changes when the note content changes. "" on failure.
function M.Hash(take)
    if not take then return "" end
    local ok, hash = r.MIDI_GetHash(take, true)
    if ok and hash then return hash end
    return ""
end

-- ---------------------------------------------------------------------------
-- Note reading
-- ---------------------------------------------------------------------------

-- Read every note of the take into a dense array, caching the project-time and
-- QN conversions of each note's start/end so the analysis passes never re-convert.
-- Notes are returned sorted by (start_ppq asc, pitch asc) for determinism — the
-- API order is start-sorted but we make it total.
local function read_notes(take)
    local _, notecnt = r.MIDI_CountEvts(take)
    local notes = {}
    for idx = 0, notecnt - 1 do
        local retval, _, muted, sppq, eppq, chan, pitch, vel = r.MIDI_GetNote(take, idx)
        if retval and not muted then
            notes[#notes + 1] = {
                idx = idx,
                ppq = sppq,           -- float
                end_ppq = eppq,       -- float
                pitch = pitch,        -- integer 0..127
                vel = vel,            -- integer 1..127
                chan = chan,          -- integer 0..15
                start_time = r.MIDI_GetProjTimeFromPPQPos(take, sppq),
                end_time = r.MIDI_GetProjTimeFromPPQPos(take, eppq),
                start_qn = r.MIDI_GetProjQNFromPPQPos(take, sppq),
                end_qn = r.MIDI_GetProjQNFromPPQPos(take, eppq),
            }
        end
    end
    table.sort(notes, function(a, b)
        if a.ppq ~= b.ppq then return a.ppq < b.ppq end
        if a.pitch ~= b.pitch then return a.pitch < b.pitch end
        return a.idx < b.idx
    end)
    return notes
end

-- ---------------------------------------------------------------------------
-- Segment construction shared by both modes
-- ---------------------------------------------------------------------------

-- Build a Segment covering [seg_start_time, seg_end_time) from the note list.
-- A note is a "start-inside" note when its start lies in [seg_start, seg_end);
-- a "held" note starts before seg_start but sounds into the window. Weight per
-- pc accumulates overlap_qn * (vel/127) over every overlapping note. empty=true
-- when nothing sounds in the window. flats controls candidate naming.
local function build_segment(take, notes, seg_start_time, seg_end_time, flats)
    local seg = {
        start_time = seg_start_time,
        end_time = seg_end_time,
        start_ppq = r.MIDI_GetPPQPosFromProjTime(take, seg_start_time),
        end_ppq = r.MIDI_GetPPQPosFromProjTime(take, seg_end_time),
        notes = {},
        held = {},
        pitches = {},
        weights = {},
        candidates = {},
        chord = nil,
        empty = false,
    }

    local seg_start_qn = r.TimeMap2_timeToQN(0, seg_start_time)
    local seg_end_qn = r.TimeMap2_timeToQN(0, seg_end_time)

    local pitch_set = {}       -- pitch -> true, distinct sounding pitches
    local lowest_pitch = nil
    local any = false

    for i = 1, #notes do
        local nt = notes[i]
        -- Overlap in project time; a note overlaps the window when it starts
        -- before the window ends and ends after it begins.
        if nt.start_time < seg_end_time and nt.end_time > seg_start_time then
            any = true
            pitch_set[nt.pitch] = true
            if lowest_pitch == nil or nt.pitch < lowest_pitch then
                lowest_pitch = nt.pitch
            end

            -- Overlap span in QN for weighting (clamp to the window).
            local ov_start_qn = nt.start_qn
            if ov_start_qn < seg_start_qn then ov_start_qn = seg_start_qn end
            local ov_end_qn = nt.end_qn
            if ov_end_qn > seg_end_qn then ov_end_qn = seg_end_qn end
            local overlap_qn = ov_end_qn - ov_start_qn
            if overlap_qn < 0 then overlap_qn = 0 end
            local pc = nt.pitch % 12
            seg.weights[pc] = (seg.weights[pc] or 0) + overlap_qn * (nt.vel / 127)

            -- Classify: start inside the window vs held from before.
            local rec = {
                idx = nt.idx,
                ppq = nt.ppq,
                end_ppq = nt.end_ppq,
                pitch = nt.pitch,
                vel = nt.vel,
                chan = nt.chan,
            }
            if nt.start_time >= seg_start_time then
                seg.notes[#seg.notes + 1] = rec
            else
                seg.held[#seg.held + 1] = rec
            end
        end
    end

    if not any then
        seg.empty = true
        return seg
    end

    -- Distinct sounding pitches, sorted ascending (deterministic, no pairs order).
    local plist = {}
    for p in pairs(pitch_set) do plist[#plist + 1] = p end
    table.sort(plist)
    seg.pitches = plist

    -- Detection: pc weights + bass pc of the lowest sounding pitch.
    local bass_pc = lowest_pitch % 12
    seg.candidates = Theory.DetectFromWeights(seg.weights, bass_pc, { flats = flats })
    if seg.candidates[1] then
        seg.chord = seg.candidates[1].chord
    end

    return seg
end

-- ---------------------------------------------------------------------------
-- Onset-mode clustering (project-time domain)
-- ---------------------------------------------------------------------------

-- Cluster note STARTS whose successive project-time gap <= onset_ms. Each cluster
-- spans from its own start to the next cluster's start; the last cluster runs to
-- the last note end. A trailing empty placement slot is appended when >= 1 QN of
-- room remains between the last note end and the item end.
local function analyze_onset(take, notes, opts, item_start_time, item_end_time, flats)
    local onset_gap = (opts.onset_ms or 80) / 1000.0
    local segments = {}

    if #notes == 0 then
        -- No notes: one empty slot covering the whole item if it spans >= 1 QN.
        local qn0 = r.TimeMap2_timeToQN(0, item_start_time)
        local qn1 = r.TimeMap2_timeToQN(0, item_end_time)
        if qn1 - qn0 >= 1.0 then
            local s = build_segment(take, notes, item_start_time, item_end_time, flats)
            s.empty = true
            segments[#segments + 1] = s
        end
        return segments
    end

    -- Cluster start times (notes already sorted by start ppq → start_time).
    local cluster_starts = {}
    local last_end_time = notes[1].end_time
    local prev_start = notes[1].start_time
    cluster_starts[1] = prev_start
    for i = 2, #notes do
        local st = notes[i].start_time
        if st - prev_start > onset_gap then
            cluster_starts[#cluster_starts + 1] = st
        end
        prev_start = st
        if notes[i].end_time > last_end_time then
            last_end_time = notes[i].end_time
        end
    end

    for c = 1, #cluster_starts do
        local seg_start = cluster_starts[c]
        local seg_end
        if c < #cluster_starts then
            seg_end = cluster_starts[c + 1]
        else
            seg_end = last_end_time
        end
        if seg_end > seg_start then
            segments[#segments + 1] = build_segment(take, notes, seg_start, seg_end, flats)
        end
    end

    -- Trailing empty slot from last note end to item end when >= 1 QN remains.
    if item_end_time > last_end_time then
        local qn_a = r.TimeMap2_timeToQN(0, last_end_time)
        local qn_b = r.TimeMap2_timeToQN(0, item_end_time)
        if qn_b - qn_a >= 1.0 then
            local s = build_segment(take, notes, last_end_time, item_end_time, flats)
            s.empty = true
            segments[#segments + 1] = s
        end
    end

    return segments
end

-- ---------------------------------------------------------------------------
-- Grid-mode slicing (measure-anchored)
-- ---------------------------------------------------------------------------

-- Boundaries every grid_qn quarter notes, anchored on the measure that contains
-- item_start. We walk QN from the measure start, emit slices clipped to the item
-- bounds. Slices with no sounding notes become empty=true placement slots.
local function analyze_grid(take, notes, opts, item_start_time, item_end_time, flats)
    local grid_qn = opts.grid_qn or 4.0
    if grid_qn <= 0 then grid_qn = 4.0 end
    local segments = {}

    -- Anchor on the measure start containing the item start. TimeMap_QNToMeasures
    -- returns the 1-based measure number AND that measure's QN start directly, so
    -- we read qnMeasureStart and avoid any 0/1-based measure-index ambiguity.
    -- TimeMap_GetMeasureInfo is queried as a fallback only if the QN start is nil.
    local item_start_qn = r.TimeMap2_timeToQN(0, item_start_time)
    local item_end_qn = r.TimeMap2_timeToQN(0, item_end_time)
    local meas_num, meas_qn_start = r.TimeMap_QNToMeasures(0, item_start_qn)
    if meas_qn_start == nil then
        local _, qn_start = r.TimeMap_GetMeasureInfo(0, (meas_num or 1) - 1)
        meas_qn_start = qn_start or item_start_qn
    end

    -- Advance the grid cursor from the measure QN start up to the item start, so
    -- the first slice boundary is the last grid line at or before item_start.
    local qn = meas_qn_start
    while qn + grid_qn <= item_start_qn do
        qn = qn + grid_qn
    end

    -- Emit slices [qn, qn+grid_qn) intersected with [item_start_qn, item_end_qn).
    -- Guard the loop with a large iteration cap in case of a degenerate tempo map.
    local guard = 0
    while qn < item_end_qn and guard < 100000 do
        guard = guard + 1
        local slice_start_qn = qn
        local slice_end_qn = qn + grid_qn

        local clip_start_qn = slice_start_qn
        if clip_start_qn < item_start_qn then clip_start_qn = item_start_qn end
        local clip_end_qn = slice_end_qn
        if clip_end_qn > item_end_qn then clip_end_qn = item_end_qn end

        if clip_end_qn > clip_start_qn then
            local s_time = r.TimeMap2_QNToTime(0, clip_start_qn)
            local e_time = r.TimeMap2_QNToTime(0, clip_end_qn)
            local seg = build_segment(take, notes, s_time, e_time, flats)
            -- build_segment already sets empty=true when nothing sounds.
            segments[#segments + 1] = seg
        end
        qn = slice_end_qn
    end

    return segments
end

-- ---------------------------------------------------------------------------
-- Analyze
-- ---------------------------------------------------------------------------

function M.Analyze(take, opts)
    opts = opts or {}
    local mode = opts.mode or "onset"
    local flats = opts.flats == true

    local item = r.GetMediaItemTake_Item(take)
    local item_start_time = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end_time = item_start_time + item_len

    local notes = read_notes(take)

    local segments
    if mode == "grid" then
        segments = analyze_grid(take, notes, opts, item_start_time, item_end_time, flats)
    else
        segments = analyze_onset(take, notes, opts, item_start_time, item_end_time, flats)
    end

    -- Key histogram: overlap-weighted pc mass over the whole item (every note's
    -- full duration in QN, scaled by velocity).
    local key_weights = {}
    for i = 1, #notes do
        local nt = notes[i]
        local dur_qn = nt.end_qn - nt.start_qn
        if dur_qn < 0 then dur_qn = 0 end
        local pc = nt.pitch % 12
        key_weights[pc] = (key_weights[pc] or 0) + dur_qn * (nt.vel / 127)
    end
    local key = Theory.DetectKey(key_weights)

    return {
        segments = segments,
        key = key,
        item_start_time = item_start_time,
        item_end_time = item_end_time,
        hash = M.Hash(take),
    }
end

-- ---------------------------------------------------------------------------
-- Mutations (each a single undo block, sort disabled across the batch)
-- ---------------------------------------------------------------------------

-- Rhythm-preserving chord swap under the segment's own onset notes (NOT held
-- notes, which belong to the previous segment). Only pitch changes; start/end/
-- vel/chan are preserved so arpeggios keep their rhythm.
function M.ReplaceSegment(take, segment, new_chord)
    if not take or not segment or not new_chord then return end
    local src = segment.notes
    if not src or #src == 0 then return end

    -- Distinct old pitches → new pitches via Voicing (deterministic map).
    local old_pitches = {}
    local seen = {}
    for i = 1, #src do
        local p = src[i].pitch
        if not seen[p] then
            seen[p] = true
            old_pitches[#old_pitches + 1] = p
        end
    end
    table.sort(old_pitches)

    local pitch_map = Voicing.MapNotes(old_pitches, new_chord)

    local old_name = Theory.ChordName(segment.chord)
    local new_name = Theory.ChordName(new_chord)

    r.Undo_BeginBlock()
    r.MIDI_DisableSort(take)
    for i = 1, #src do
        local nt = src[i]
        local np = pitch_map[nt.pitch]
        if np ~= nil and np ~= nt.pitch then
            -- Pitch-only edit: all other fields nil → unchanged; noSort=true.
            r.MIDI_SetNote(take, nt.idx, nil, nil, nil, nil, nil, np, nil, true)
        end
    end
    r.MIDI_Sort(take)
    r.Undo_EndBlock("ChordLab: " .. old_name .. " -> " .. new_name, -1)
    r.UpdateArrange()
end

-- Insert a block chord occupying [start_ppq, end_ppq]. Notes are unselected,
-- unmuted, channel 0. vel defaults to 96 when omitted.
function M.WriteChord(take, start_ppq, end_ppq, pitches, vel)
    if not take or not pitches or #pitches == 0 then return end
    vel = vel or 96

    r.Undo_BeginBlock()
    r.MIDI_DisableSort(take)
    for i = 1, #pitches do
        local p = pitches[i]
        if p ~= nil then
            r.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, p, vel, true)
        end
    end
    r.MIDI_Sort(take)
    r.Undo_EndBlock("ChordLab: write chord", -1)
    r.UpdateArrange()
end

-- Delete a segment's onset notes. Deletion shifts subsequent idx values, so we
-- delete in DESCENDING idx order to keep every stored idx valid until used.
function M.DeleteSegment(take, segment)
    if not take or not segment then return end
    local src = segment.notes
    if not src or #src == 0 then return end

    local idxs = {}
    for i = 1, #src do idxs[i] = src[i].idx end
    table.sort(idxs, function(a, b) return a > b end)

    r.Undo_BeginBlock()
    r.MIDI_DisableSort(take)
    for i = 1, #idxs do
        r.MIDI_DeleteNote(take, idxs[i])
    end
    r.MIDI_Sort(take)
    r.Undo_EndBlock("ChordLab: delete segment", -1)
    r.UpdateArrange()
end

-- Return the selected MIDI item's take/item if present; otherwise create a new
-- MIDI item on the first selected track (fallback: last touched track) at the
-- edit cursor, len_qn quarter notes long.
function M.EnsureItem(len_qn)
    local take, item = M.GetTarget()
    if take then return take, item end

    local track = r.GetSelectedTrack(0, 0)
    if not track then track = r.GetLastTouchedTrack() end
    if not track then return nil, nil end

    len_qn = len_qn or 4.0
    local cursor_time = r.GetCursorPosition()
    local start_qn = r.TimeMap2_timeToQN(0, cursor_time)
    local end_qn = start_qn + len_qn

    -- qnIn=true → start/end interpreted as QN positions.
    local new_item = r.CreateNewMIDIItemInProj(track, start_qn, end_qn, true)
    if not new_item then return nil, nil end
    local new_take = r.GetActiveTake(new_item)
    return new_take, new_item
end

return M
