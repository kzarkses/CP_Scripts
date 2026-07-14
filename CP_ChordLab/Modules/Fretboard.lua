-- @description CP ChordLab — fretboard model and fingering <-> pitches solver
-- @author Cedric Pamalio

-- PURE module: no reaper.*, gfx.*, os.*, io.*. Lua 5.3.
-- Tuning notes are MIDI numbers ordered LOW string -> HIGH string (string 1 =
-- low E in standard). Determinism is a hard requirement: the reverse solver's
-- output ordering must never depend on pairs() iteration order — chord pc sets
-- are read from Theory.ChordPcs (a dense array) and results are stably sorted.

local M = {}

local Theory = nil

function M.Init(theory)
    Theory = theory
    return M
end

-- ---------------------------------------------------------------------------
-- Tunings
-- ---------------------------------------------------------------------------
-- notes low string -> high string, MIDI numbers.
-- Standard: E2 A2 D3 G3 B3 E4. Others are common alternate tunings.

M.TUNINGS = {
    { name = "Standard", notes = { 40, 45, 50, 55, 59, 64 } }, -- E A D G B E
    { name = "Drop D",   notes = { 38, 45, 50, 55, 59, 64 } }, -- D A D G B E
    { name = "DADGAD",   notes = { 38, 45, 50, 55, 57, 62 } }, -- D A D G A D
    { name = "Open G",   notes = { 38, 43, 50, 55, 59, 62 } }, -- D G D G B D
    { name = "Open D",   notes = { 38, 45, 50, 54, 57, 62 } }, -- D A D F# A D
    { name = "Open E",   notes = { 40, 47, 52, 56, 59, 64 } }, -- E B E G# B E
    { name = "Open C",   notes = { 36, 43, 48, 55, 60, 64 } }, -- C G C G C E
}

-- Number of strings on a standard guitar; all tunings above share this.
local STRINGS = 6

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- state = { tuning=idx, capo=0, fingers={-1,-1,-1,-1,-1,-1} }
--   fingers[s]: -1 = muted, 0 = open, n>=1 = absolute fret n (ignores capo).
--   String 1 = LOW string.

function M.New(tuning_index)
    tuning_index = tuning_index or 1
    if not M.TUNINGS[tuning_index] then tuning_index = 1 end
    local fingers = {}
    for s = 1, STRINGS do fingers[s] = -1 end
    return { tuning = tuning_index, capo = 0, fingers = fingers }
end

-- Resolve the tuning notes array for a state (falls back to Standard).
local function tuning_notes(state)
    local t = M.TUNINGS[state.tuning] or M.TUNINGS[1]
    return t.notes
end

-- ---------------------------------------------------------------------------
-- Pitch resolution
-- ---------------------------------------------------------------------------

function M.Pitches(state)
    -- Sounding pitches, sorted ascending:
    --   fingers[s] == -1 -> silent
    --   fingers[s] == 0  -> open string sounds tuning[s] + capo
    --   fingers[s] == n  -> fretted note sounds tuning[s] + n (capo ignored,
    --                       n is absolute; UI keeps n > capo)
    local notes = tuning_notes(state)
    local capo = state.capo or 0
    local out = {}
    for s = 1, STRINGS do
        local f = state.fingers[s]
        if f ~= nil and f >= 0 then
            local pitch
            if f == 0 then pitch = notes[s] + capo
            else pitch = notes[s] + f end
            out[#out + 1] = pitch
        end
    end
    table.sort(out)
    return out
end

function M.SetFinger(state, s, fret)
    if s >= 1 and s <= STRINGS then
        state.fingers[s] = fret
    end
    return state
end

function M.Clear(state)
    for s = 1, STRINGS do state.fingers[s] = -1 end
    return state
end

-- ---------------------------------------------------------------------------
-- Reverse solver: chord pc set -> fingering candidates
-- ---------------------------------------------------------------------------
-- Window scan. For each start fret p in 0..12, each string offers a small set
-- of options: {mute, open (only if the open pc is a chord pc), fretted frets in
-- [p, p+span-1] whose pc is a chord pc}. We enumerate assignments greedily
-- (each string independently picks between mute and the reachable chord tones),
-- then score whole fingerings by:
--   1. all chord pcs covered      (dominant term)
--   2. bass correct on the lowest sounding string
--   3. more strings sounding
--   4. lower fret position
-- Dedupe identical fingerings, return the top N as fingers arrays.
--
-- The enumeration is bounded: <=13 windows * per-string option product, but we
-- prune aggressively (a window rarely offers more than ~3 options per string
-- for a triad) and reuse scratch buffers across windows to stay allocation-light
-- so it feels instant even though it runs on user demand.

-- Reusable scratch buffers (module-level; the solver is single-threaded and
-- never re-entrant within a frame). Cleared at the start of each solve.
local sc_pc_in_chord = {}   -- pc -> true membership set for the current chord
local sc_options = {}       -- [string] -> dense array of candidate frets (incl -1 mute, 0 open)
local sc_choice = {}        -- [string] -> current chosen fret during recursion

-- Build the per-string option lists for a given window start fret p.
-- Fills sc_options[s] with a dense array of candidate fret values for string s.
-- Always includes -1 (mute). Includes 0 (open) only when the open pc is a chord
-- pc. Includes fretted values in [max(p,1), p+span-1] whose pc is a chord pc.
local function build_options(notes, capo, p, span, pc_in_chord)
    for s = 1, STRINGS do
        local opts = sc_options[s]
        if not opts then opts = {}; sc_options[s] = opts end
        local n = 0
        -- Mute always available.
        n = n + 1; opts[n] = -1
        -- Open string.
        local open_pc = (notes[s] + capo) % 12
        if pc_in_chord[open_pc] then
            n = n + 1; opts[n] = 0
        end
        -- Fretted notes inside the window. Frets are absolute and must be >= 1
        -- and > capo (a fretted note below the capo cannot be played).
        local lo = p
        if lo < 1 then lo = 1 end
        if lo <= capo then lo = capo + 1 end
        local hi = p + span - 1
        for f = lo, hi do
            local pc = (notes[s] + f) % 12
            if pc_in_chord[pc] then
                n = n + 1; opts[n] = f
            end
        end
        -- Truncate stale entries from a previous (longer) window.
        for i = n + 1, #opts do opts[i] = nil end
    end
end

-- Score a completed fingering (sc_choice). Returns a single comparable number
-- plus components; higher is better. bass_pc is the desired lowest pc (chord
-- root, or explicit bass). num_pcs = distinct chord pc count.
local function score_fingering(notes, capo, bass_pc, num_pcs, span_dummy)
    -- Covered pcs, sounding-string count, lowest sounding pitch, min/max fret.
    local covered = {}          -- pc -> true
    local covered_count = 0
    local sounding = 0
    local lowest_pitch = nil
    local min_fret, max_fret = nil, nil
    for s = 1, STRINGS do
        local f = sc_choice[s]
        if f >= 0 then
            local pitch
            if f == 0 then pitch = notes[s] + capo else pitch = notes[s] + f end
            local pc = pitch % 12
            if not covered[pc] then covered[pc] = true; covered_count = covered_count + 1 end
            sounding = sounding + 1
            if lowest_pitch == nil or pitch < lowest_pitch then lowest_pitch = pitch end
            if f >= 1 then
                if min_fret == nil or f < min_fret then min_fret = f end
                if max_fret == nil or f > max_fret then max_fret = f end
            end
        end
    end
    if sounding == 0 then return nil end

    local all_covered = (covered_count >= num_pcs) and 1 or 0
    local bass_ok = (lowest_pitch ~= nil and (lowest_pitch % 12) == bass_pc) and 1 or 0
    local position = min_fret or 0   -- 0 for all-open shapes (lowest possible)

    -- Weighted lexicographic score. Weights are chosen so each criterion strictly
    -- dominates the next: all_covered >> bass_ok >> more strings >> lower position.
    -- position penalized (higher fret = worse) with a small coefficient.
    local score = all_covered * 100000
        + bass_ok * 10000
        + sounding * 500
        - position * 10

    return score, covered_count, sounding, all_covered, bass_ok, position
end

-- Serialize a fingering into a stable dedupe key.
local function fingering_key(fingers)
    -- fingers values are small ints (>= -1). Build a compact deterministic key.
    local parts = {}
    for s = 1, STRINGS do parts[s] = tostring(fingers[s]) end
    return table.concat(parts, ",")
end

function M.FromPitches(state, chord, opts)
    opts = opts or {}
    local max_results = opts.max_results or 5
    local span = opts.max_span or 4
    local min_strings = opts.min_strings or 3
    local prefer_bass = opts.prefer_bass
    if prefer_bass == nil then prefer_bass = true end
    if span < 1 then span = 1 end

    if not chord or not Theory then return {} end

    local notes = tuning_notes(state)
    local capo = state.capo or 0

    -- Chord pc set (dense array from Theory; then a membership map).
    local pcs = Theory.ChordPcs(chord)
    if #pcs == 0 then return {} end
    for pc = 0, 11 do sc_pc_in_chord[pc] = false end
    local num_pcs = 0
    for i = 1, #pcs do
        local pc = pcs[i] % 12
        if not sc_pc_in_chord[pc] then
            sc_pc_in_chord[pc] = true
            num_pcs = num_pcs + 1
        end
    end

    -- Desired bass pc: explicit slash bass if set, else the chord root.
    local bass_pc = chord.root % 12
    if prefer_bass and chord.bass ~= nil then bass_pc = chord.bass % 12 end

    -- Accumulator of unique candidate fingerings.
    local seen = {}                -- key -> index into results
    local results = {}             -- { fingers, score, sounding, position, covered, all_covered, bass_ok }

    -- Enumerate one window (start fret p). Options are already built in
    -- sc_options. We recurse string by string choosing among that string's
    -- options; each completed assignment is scored and (if it meets the minimum
    -- sounding-string floor) recorded.
    local function recurse(s)
        if s > STRINGS then
            local score, covered, sounding, all_covered, bass_ok, position =
                score_fingering(notes, capo, bass_pc, num_pcs)
            if score == nil then return end
            if sounding < min_strings then return end
            -- Snapshot the choice into a fresh fingers array.
            local fingers = {}
            for k = 1, STRINGS do fingers[k] = sc_choice[k] end
            local key = fingering_key(fingers)
            local existing = seen[key]
            if existing == nil then
                results[#results + 1] = {
                    fingers = fingers,
                    score = score,
                    covered = covered,
                    sounding = sounding,
                    all_covered = all_covered,
                    bass_ok = bass_ok,
                    position = position,
                }
                seen[key] = #results
            end
            return
        end
        local opts_s = sc_options[s]
        for i = 1, #opts_s do
            sc_choice[s] = opts_s[i]
            recurse(s + 1)
        end
    end

    for p = 0, 12 do
        build_options(notes, capo, p, span, sc_pc_in_chord)
        for s = 1, STRINGS do sc_choice[s] = -1 end
        recurse(1)
    end

    -- Stable ordering: score desc, then covered desc, then sounding desc, then
    -- position asc, then lexicographic fingers ascending (fully deterministic).
    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.covered ~= b.covered then return a.covered > b.covered end
        if a.sounding ~= b.sounding then return a.sounding > b.sounding end
        if a.position ~= b.position then return a.position < b.position end
        -- Deterministic final tiebreak: compare fingers element by element.
        for s = 1, STRINGS do
            if a.fingers[s] ~= b.fingers[s] then return a.fingers[s] < b.fingers[s] end
        end
        return false
    end)

    -- Emit the top N as plain fingers arrays.
    local out = {}
    for i = 1, math.min(max_results, #results) do
        out[i] = results[i].fingers
    end
    return out
end

return M
