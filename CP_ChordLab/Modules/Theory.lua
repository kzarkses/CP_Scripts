-- @description CP ChordLab — pure music-theory engine (chords, detection, keys, transforms)
-- @author Cedric Pamalio

-- PURE module: no reaper.*, gfx.*, os.*, io.*. Lua 5.3.
-- All pitch classes are integers 0..11 (0 = C). Pitches are MIDI 0..127 (60 = C4).
-- Determinism is a hard requirement: nothing that feeds returned ordering may
-- depend on pairs() iteration order. Candidate roots are iterated over a sorted
-- pc list; chord types over the dense TYPES array.

local M = {}

-- ---------------------------------------------------------------------------
-- Note / pitch-class naming
-- ---------------------------------------------------------------------------

local SHARP_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local FLAT_NAMES  = { "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B" }

function M.PcName(pc, flats)
    pc = pc % 12
    if pc < 0 then pc = pc + 12 end
    -- +1: pc 0 maps to array index 1.
    return (flats and FLAT_NAMES or SHARP_NAMES)[pc + 1]
end

function M.NoteName(pitch, flats)
    -- MIDI 60 = C4. Octave = floor(pitch/12) - 1.
    pitch = math.floor(pitch + 0.5)
    local pc = pitch % 12
    local octave = (pitch // 12) - 1
    -- %d is safe here: pc, octave are integers after the floor above.
    return M.PcName(pc, flats) .. string.format("%d", octave)
end

-- ---------------------------------------------------------------------------
-- Chord dictionary
-- ---------------------------------------------------------------------------
-- Each entry: { name, intervals (root-first), label, family, rank }.
-- rank = commonness bonus used by the detector as a tiebreaker; higher = more
-- common / more strongly preferred. Triads and plain sevenths rank high,
-- altered / exotic chords rank low so the detector prefers e.g. Cmaj7 over an
-- Em/C reading and Am7 over C6/A when tone evidence is otherwise comparable.

local TYPE_DEFS = {
    -- Triads ------------------------------------------------------------------
    { name = "maj",   intervals = { 0, 4, 7 },          label = "",      family = "triad",     rank = 100 },
    { name = "min",   intervals = { 0, 3, 7 },          label = "m",     family = "triad",     rank = 98 },
    { name = "dim",   intervals = { 0, 3, 6 },          label = "dim",   family = "triad",     rank = 70 },
    { name = "aug",   intervals = { 0, 4, 8 },          label = "aug",   family = "triad",     rank = 62 },
    { name = "sus2",  intervals = { 0, 2, 7 },          label = "sus2",  family = "suspended", rank = 64 },
    { name = "sus4",  intervals = { 0, 5, 7 },          label = "sus4",  family = "suspended", rank = 66 },
    { name = "5",     intervals = { 0, 7 },             label = "5",     family = "power",     rank = 55 },
    -- Sixths ------------------------------------------------------------------
    { name = "6",     intervals = { 0, 4, 7, 9 },       label = "6",     family = "sixth",     rank = 84 },
    { name = "m6",    intervals = { 0, 3, 7, 9 },       label = "m6",    family = "sixth",     rank = 80 },
    { name = "69",    intervals = { 0, 4, 7, 9, 2 },    label = "6/9",   family = "sixth",     rank = 58 },
    -- Sevenths ----------------------------------------------------------------
    { name = "maj7",  intervals = { 0, 4, 7, 11 },      label = "maj7",  family = "seventh",   rank = 94 },
    { name = "7",     intervals = { 0, 4, 7, 10 },      label = "7",     family = "seventh",   rank = 96 },
    { name = "m7",    intervals = { 0, 3, 7, 10 },      label = "m7",    family = "seventh",   rank = 95 },
    { name = "mMaj7", intervals = { 0, 3, 7, 11 },      label = "mMaj7", family = "seventh",   rank = 60 },
    { name = "dim7",  intervals = { 0, 3, 6, 9 },       label = "dim7",  family = "seventh",   rank = 78 },
    { name = "m7b5",  intervals = { 0, 3, 6, 10 },      label = "m7b5",  family = "seventh",   rank = 82 },
    { name = "aug7",  intervals = { 0, 4, 8, 10 },      label = "aug7",  family = "seventh",   rank = 56 },
    { name = "augMaj7", intervals = { 0, 4, 8, 11 },    label = "augMaj7", family = "seventh", rank = 50 },
    { name = "7sus4", intervals = { 0, 5, 7, 10 },      label = "7sus4", family = "seventh",   rank = 68 },
    -- Extensions --------------------------------------------------------------
    { name = "add9",  intervals = { 0, 4, 7, 2 },       label = "add9",  family = "extension", rank = 72 },
    { name = "madd9", intervals = { 0, 3, 7, 2 },       label = "madd9", family = "extension", rank = 70 },
    { name = "maj9",  intervals = { 0, 4, 7, 11, 2 },   label = "maj9",  family = "extension", rank = 74 },
    { name = "9",     intervals = { 0, 4, 7, 10, 2 },   label = "9",     family = "extension", rank = 76 },
    { name = "m9",    intervals = { 0, 3, 7, 10, 2 },   label = "m9",    family = "extension", rank = 75 },
    { name = "11",    intervals = { 0, 4, 7, 10, 2, 5 },label = "11",    family = "extension", rank = 52 },
    { name = "m11",   intervals = { 0, 3, 7, 10, 2, 5 },label = "m11",   family = "extension", rank = 51 },
    { name = "13",    intervals = { 0, 4, 7, 10, 2, 9 },label = "13",    family = "extension", rank = 53 },
    { name = "maj13", intervals = { 0, 4, 7, 11, 2, 9 },label = "maj13", family = "extension", rank = 49 },
    { name = "m13",   intervals = { 0, 3, 7, 10, 2, 9 },label = "m13",   family = "extension", rank = 48 },
    -- Altered dominants -------------------------------------------------------
    { name = "7b9",   intervals = { 0, 4, 7, 10, 1 },   label = "7b9",   family = "altered",   rank = 46 },
    { name = "7#9",   intervals = { 0, 4, 7, 10, 3 },   label = "7#9",   family = "altered",   rank = 45 },
    { name = "7b5",   intervals = { 0, 4, 6, 10 },      label = "7b5",   family = "altered",   rank = 44 },
    { name = "7#5",   intervals = { 0, 4, 8, 10 },      label = "7#5",   family = "altered",   rank = 43 },
    { name = "7#11",  intervals = { 0, 4, 7, 10, 6 },   label = "7#11",  family = "altered",   rank = 42 },
    { name = "7alt",  intervals = { 0, 4, 8, 10, 1 },   label = "7alt",  family = "altered",   rank = 40 },
    -- Exotic ------------------------------------------------------------------
    { name = "quartal",  intervals = { 0, 5, 10 },      label = "4ths",  family = "exotic",    rank = 30 },
    { name = "quartal4", intervals = { 0, 5, 10, 3 },   label = "4ths4", family = "exotic",    rank = 28 },
}

M.TYPES = {}
M.TYPE_BY_NAME = {}
for i = 1, #TYPE_DEFS do
    local d = TYPE_DEFS[i]
    -- Precompute a pc-membership set and a sorted interval list for scoring.
    local set = {}
    for j = 1, #d.intervals do set[d.intervals[j] % 12] = true end
    local t = {
        name = d.name,
        intervals = d.intervals,
        label = d.label,
        family = d.family,
        rank = d.rank,
        set = set,            -- interval%12 -> true
        card = #d.intervals,  -- distinct tone count (intervals authored distinct)
    }
    M.TYPES[i] = t
    M.TYPE_BY_NAME[d.name] = t
end

-- ---------------------------------------------------------------------------
-- Modes / scales
-- ---------------------------------------------------------------------------

M.MODES = {
    major          = { 0, 2, 4, 5, 7, 9, 11 },
    minor          = { 0, 2, 3, 5, 7, 8, 10 }, -- natural minor / aeolian
    dorian         = { 0, 2, 3, 5, 7, 9, 10 },
    phrygian       = { 0, 1, 3, 5, 7, 8, 10 },
    lydian         = { 0, 2, 4, 6, 7, 9, 11 },
    mixolydian     = { 0, 2, 4, 5, 7, 9, 10 },
    locrian        = { 0, 1, 3, 5, 6, 8, 10 },
    harmonic_minor = { 0, 2, 3, 5, 7, 8, 11 },
    melodic_minor  = { 0, 2, 3, 5, 7, 9, 11 }, -- ascending
}

-- ---------------------------------------------------------------------------
-- Chord helpers
-- ---------------------------------------------------------------------------

function M.ChordPcs(chord)
    -- pcs of the abstract chord (bass NOT prepended): (root+iv)%12 per interval.
    local t = M.TYPE_BY_NAME[chord.type]
    local out = {}
    if not t then return out end
    for i = 1, #t.intervals do
        out[i] = (chord.root + t.intervals[i]) % 12
    end
    return out
end

function M.ChordName(chord, flats)
    if not chord then return "—" end
    local t = M.TYPE_BY_NAME[chord.type]
    local label = t and t.label or chord.type
    local name = M.PcName(chord.root, flats) .. label
    if chord.bass ~= nil and chord.bass ~= chord.root then
        name = name .. "/" .. M.PcName(chord.bass, flats)
    end
    return name
end

function M.ChordEquals(a, b)
    if a == nil or b == nil then return a == b end
    return a.root == b.root and a.type == b.type and (a.bass or a.root) == (b.bass or b.root)
end

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------
-- Scoring core shared by Detect / DetectFromWeights. Input is a pc-weight map
-- (weight > 0 = present) plus the bass pc. Every present pc is tried as root,
-- against every ChordType; the best (highest score) reading wins. type.rank
-- breaks ties. The scorer is the product's quality lever — the pinned
-- expectations in ARCHITECTURE.md pin its behavior; if you change weights,
-- re-run the tests.

-- Interval-importance weight for a matched chord tone. Root and 3rd carry the
-- chord's identity; the 5th is nearly free to omit (C7 no5 must still read C7).
local function tone_importance(iv)
    iv = iv % 12
    if iv == 0 then return 3.0 end            -- root
    if iv == 3 or iv == 4 then return 2.6 end -- 3rd (min / maj)
    if iv == 7 then return 1.0 end            -- perfect 5th (cheap to miss)
    if iv == 6 or iv == 8 then return 1.6 end -- altered 5th (identity-bearing)
    if iv == 10 or iv == 11 then return 1.8 end -- 7th
    if iv == 9 then return 1.5 end            -- 6th
    return 1.4                                -- extensions / tensions
end

-- Score constants (tuned against the pinned expectations table).
local BASS_ROOT_BONUS   = 6.0   -- bass == root: strongly prefer root-position reading
local BASS_TONE_BONUS   = 1.6   -- bass is a non-root chord tone: mild slash bonus
local MISS_ROOT_PEN     = 5.0   -- missing the root pc (rootless voicing) — costly
local MISS_THIRD_PEN    = 2.2   -- missing the 3rd
local MISS_FIFTH_PEN    = 0.35  -- missing the 5th — cheap
local MISS_OTHER_PEN    = 1.4   -- missing a 7th / extension
local EXTRA_PEN         = 3.2   -- present pc not in the chord — expensive
local RANK_SCALE        = 0.02  -- rank tiebreak: << any tone weight difference

local function miss_penalty(iv)
    iv = iv % 12
    if iv == 0 then return MISS_ROOT_PEN end
    if iv == 3 or iv == 4 then return MISS_THIRD_PEN end
    if iv == 7 then return MISS_FIFTH_PEN end
    return MISS_OTHER_PEN
end

-- Score one (root, type) reading against the present-pc weight map.
-- present_count = number of distinct present pcs (for extra-pc accounting).
local function score_reading(root, t, weights, present_count, bass_pc)
    local matched_w, missing_w = 0.0, 0.0
    local matched_pcs, missing_pcs = 0, 0
    local intervals = t.intervals
    for i = 1, #intervals do
        local iv = intervals[i]
        local pc = (root + iv) % 12
        if (weights[pc] or 0) > 0 then
            matched_w = matched_w + tone_importance(iv)
            matched_pcs = matched_pcs + 1
        else
            missing_w = missing_w + miss_penalty(iv)
            missing_pcs = missing_pcs + 1
        end
    end
    -- Extra pcs: present pcs that are not chord tones of this reading.
    local extra_pcs = present_count - matched_pcs

    local score = matched_w - missing_w - extra_pcs * EXTRA_PEN

    -- Bass handling.
    local is_chord_tone = t.set[(bass_pc - root) % 12] == true
    if bass_pc == root then
        score = score + BASS_ROOT_BONUS
    elseif is_chord_tone then
        score = score + BASS_TONE_BONUS
    end

    -- Commonness tiebreak.
    score = score + t.rank * RANK_SCALE

    return score, matched_pcs, missing_pcs, extra_pcs, is_chord_tone
end

-- Build ranked candidates from a pc-weight map + bass pc.
local function detect_core(weights, bass_pc, opts)
    opts = opts or {}
    -- Sorted, deduped present pc list — deterministic candidate-root order.
    local roots = {}
    for pc = 0, 11 do
        if (weights[pc] or 0) > 0 then roots[#roots + 1] = pc end
    end
    local present_count = #roots

    local results = {}

    if present_count == 0 then
        return results
    end

    -- Single pc: name the note, no chord.
    if present_count == 1 then
        local pc = roots[1]
        results[1] = {
            chord = nil,
            score = 0,
            name = M.PcName(pc, opts.flats),
            matched = { pc }, missing = {}, extra = {},
        }
        return results
    end

    -- Two pcs: power chord / dyad. Prefer a '5' reading when the interval is a
    -- perfect 5th (or its 4th inversion); otherwise report the interval name.
    if present_count == 2 then
        local a, b = roots[1], roots[2]
        local up = (b - a) % 12       -- 1..11
        local down = (a - b) % 12
        local iv = math.min(up, down) -- 1..6, folded interval
        if iv == 7 or iv == 5 then
            -- Perfect 5th / 4th: a real power chord. Root = lower of the fifth.
            -- If interval a->b is a 5th, root=a; if a 4th, root=b (b is a fifth
            -- below a's octave, i.e. b is the root).
            local root
            if up == 7 then root = a
            elseif up == 5 then root = b   -- a is the 5th above root b's fourth... actually b up a 4th=a
            else root = a end
            -- Bass preference: if the bass is the non-root member, name a slash.
            local slash = nil
            if bass_pc ~= root and (bass_pc == a or bass_pc == b) then
                slash = bass_pc
            end
            results[1] = {
                chord = { root = root, type = "5", bass = slash },
                score = 5,
                name = M.ChordName({ root = root, type = "5", bass = slash }, opts.flats),
                matched = { root, (root + 7) % 12 }, missing = {}, extra = {},
            }
            return results
        end
        -- Non-fifth dyad: report the interval name, no chord.
        local INTERVAL_NAMES = {
            [1] = "m2", [2] = "M2", [3] = "m3", [4] = "M3",
            [5] = "P4", [6] = "TT",
        }
        results[1] = {
            chord = nil,
            score = 0,
            name = M.PcName(a, opts.flats) .. " " .. (INTERVAL_NAMES[iv] or "?") .. " " .. M.PcName(b, opts.flats),
            matched = { a, b }, missing = {}, extra = {},
        }
        return results
    end

    -- 3+ pcs: full scoring over (present-pc root) × type.
    -- Deterministic: outer loop over sorted roots, inner over dense TYPES.
    for ri = 1, present_count do
        local root = roots[ri]
        for ti = 1, #M.TYPES do
            local t = M.TYPES[ti]
            -- Skip the pure power chord for 3+ pc sets (never the best full read).
            if t.card >= 2 then
                local score, mpcs = score_reading(root, t, weights, present_count, bass_pc)
                -- Require at least the root or third present to be a candidate at
                -- all, so we don't emit nonsense readings for dense clusters.
                if mpcs >= 2 then
                    local matched, missing, extra = {}, {}, {}
                    for i = 1, #t.intervals do
                        local pc = (root + t.intervals[i]) % 12
                        if (weights[pc] or 0) > 0 then matched[#matched + 1] = pc
                        else missing[#missing + 1] = pc end
                    end
                    -- Extra = present pcs not covered by this reading.
                    for i = 1, present_count do
                        local pc = roots[i]
                        if not t.set[(pc - root) % 12] then extra[#extra + 1] = pc end
                    end
                    local bass = nil
                    if bass_pc ~= root and t.set[(bass_pc - root) % 12] then
                        bass = bass_pc
                    end
                    results[#results + 1] = {
                        chord = { root = root, type = t.name, bass = bass },
                        score = score,
                        name = M.ChordName({ root = root, type = t.name, bass = bass }, opts.flats),
                        matched = matched, missing = missing, extra = extra,
                        _rank = t.rank,
                    }
                end
            end
        end
    end

    -- No scored reading (e.g. degenerate cluster) → best-effort: name the bass
    -- with a power chord fallback so we never return empty for 3+ notes.
    if #results == 0 then
        local root = bass_pc
        results[1] = {
            chord = { root = root, type = "5", bass = nil },
            score = 0,
            name = M.ChordName({ root = root, type = "5" }, opts.flats),
            matched = { root }, missing = {}, extra = {},
        }
        return results
    end

    -- Stable sort: score desc, then rank desc, then root asc, then name asc.
    table.sort(results, function(x, y)
        if x.score ~= y.score then return x.score > y.score end
        local xr = x._rank or 0
        local yr = y._rank or 0
        if xr ~= yr then return xr > yr end
        local xroot = x.chord and x.chord.root or -1
        local yroot = y.chord and y.chord.root or -1
        if xroot ~= yroot then return xroot < yroot end
        return x.name < y.name
    end)

    return results
end

function M.DetectFromWeights(weights, bass_pc, opts)
    -- weights: pc -> weight (>0 = present). bass_pc: pc of the lowest pitch.
    if bass_pc == nil then
        -- Fall back to the lowest present pc as bass.
        for pc = 0, 11 do
            if (weights[pc] or 0) > 0 then bass_pc = pc break end
        end
        bass_pc = bass_pc or 0
    end
    return detect_core(weights, bass_pc % 12, opts)
end

function M.Detect(pitches, opts)
    opts = opts or {}
    if not pitches or #pitches == 0 then return {} end
    -- Uniform weights over distinct pcs; bass = pc of the lowest pitch.
    local lowest = pitches[1]
    for i = 2, #pitches do
        if pitches[i] < lowest then lowest = pitches[i] end
    end
    local weights = {}
    for i = 1, #pitches do
        local pc = math.floor(pitches[i]) % 12
        weights[pc] = 1
    end
    -- Single distinct pitch → name the actual pitch (with octave), not just pc.
    local distinct = 0
    for _ in pairs(weights) do distinct = distinct + 1 end
    if distinct == 1 then
        return {
            {
                chord = nil,
                score = 0,
                name = M.NoteName(lowest, opts.flats),
                matched = { math.floor(lowest) % 12 }, missing = {}, extra = {},
            }
        }
    end
    return detect_core(weights, math.floor(lowest) % 12, opts)
end

-- ---------------------------------------------------------------------------
-- Key detection — Krumhansl-Schmuckler
-- ---------------------------------------------------------------------------
-- Correlate the 12-bin weight histogram against the 24 rotated Krumhansl-Kessler
-- major/minor profiles; best Pearson correlation wins.

local KK_MAJOR = { 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 }
local KK_MINOR = { 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 }

local function mean(v)
    local s = 0.0
    for i = 1, 12 do s = s + v[i] end
    return s / 12.0
end

-- Pearson correlation between a rotated profile and the histogram.
-- rot = candidate tonic. Profile index i is a scale degree (i=0 = tonic); it
-- must align with histogram bin for pc (rot+i), so tonic weight (i=0) lands on
-- hist[rot]. (A sign flip here silently maps A-minor onto Eb — regression-pinned.)
local function correlate(hist, hist_mean, profile, profile_mean, rot)
    local num, dh, dp = 0.0, 0.0, 0.0
    for i = 0, 11 do
        local h = hist[((i + rot) % 12) + 1] - hist_mean
        local p = profile[i + 1] - profile_mean
        num = num + h * p
        dh = dh + h * h
        dp = dp + p * p
    end
    local den = math.sqrt(dh * dp)
    if den <= 0 then return 0.0 end
    return num / den
end

function M.DetectKey(weights)
    -- Build a dense 12-bin histogram (1-based: bin[1] = pc 0).
    local hist = {}
    local total = 0.0
    for pc = 0, 11 do
        local w = weights[pc] or 0
        if w < 0 then w = 0 end
        hist[pc + 1] = w
        total = total + w
    end

    if total <= 0 then
        return { tonic = 0, mode = "major", confidence = 0, ranked = {} }
    end

    local hmean = mean(hist)
    local maj_mean = mean(KK_MAJOR)
    local min_mean = mean(KK_MINOR)

    -- Deterministic order: mode outer (major, minor), tonic inner 0..11.
    local ranked = {}
    for tonic = 0, 11 do
        ranked[#ranked + 1] = {
            tonic = tonic, mode = "major",
            corr = correlate(hist, hmean, KK_MAJOR, maj_mean, tonic),
        }
    end
    for tonic = 0, 11 do
        ranked[#ranked + 1] = {
            tonic = tonic, mode = "minor",
            corr = correlate(hist, hmean, KK_MINOR, min_mean, tonic),
        }
    end

    table.sort(ranked, function(a, b)
        if a.corr ~= b.corr then return a.corr > b.corr end
        -- Stable tiebreak: major before minor, then lower tonic.
        if a.mode ~= b.mode then return a.mode == "major" end
        return a.tonic < b.tonic
    end)

    local best = ranked[1]
    local second = ranked[2]
    -- Confidence = normalized gap between best and second correlation, mapped
    -- to 0..1. Correlations live in [-1,1]; a full 2.0 gap → 1.0.
    local gap = 0.0
    if second then gap = best.corr - second.corr end
    if gap < 0 then gap = 0 end
    local confidence = gap / 2.0
    if confidence > 1 then confidence = 1 end

    return {
        tonic = best.tonic,
        mode = best.mode,
        confidence = confidence,
        ranked = ranked,
    }
end

-- ---------------------------------------------------------------------------
-- Scales / diatonic harmony
-- ---------------------------------------------------------------------------

function M.Scale(key)
    local mode = M.MODES[key.mode] or M.MODES.major
    local out = {}
    for i = 1, #mode do
        out[i] = (key.tonic + mode[i]) % 12
    end
    return out
end

-- Roman-numeral degree tables. Uppercase = major-ish quality, lowercase =
-- minor-ish, "°" = diminished, "+" = augmented. Seventh flavor appended.
local ROMAN_UPPER = { "I", "II", "III", "IV", "V", "VI", "VII" }
local ROMAN_LOWER = { "i", "ii", "iii", "iv", "v", "vi", "vii" }

-- Classify a chord type into a quality bucket for roman-numeral casing/suffix.
-- Returns lower(bool), symbol("" | "°" | "+"), seventh_suffix("" | "7" | ...).
local function roman_quality(type_name)
    local t = M.TYPE_BY_NAME[type_name]
    if not t then return false, "", "" end
    local set = t.set
    local has_min3 = set[3]
    local has_maj3 = set[4]
    local has_dim5 = set[6]
    local has_aug5 = set[8]
    local has_min7 = set[10]
    local has_maj7 = set[11]
    local has_dim7 = set[9] and (has_min3 and has_dim5)

    local lower = has_min3 == true
    local symbol = ""
    if has_dim5 and has_min3 and not set[7] then symbol = "°"
    elseif has_aug5 and has_maj3 and not set[7] then symbol = "+" end

    -- Seventh flavor: keep it terse; product wants "plain degree + quality".
    local seventh = ""
    if has_dim7 then seventh = "7"       -- dim7
    elseif has_min7 then seventh = "7"
    elseif has_maj7 then seventh = "maj7" end

    return lower, symbol, seventh
end

function M.RomanNumeral(chord, key)
    if not chord or not key then return "?" end
    local scale = M.Scale(key)
    -- Find the scale degree of the chord root.
    local degree = nil
    for i = 1, #scale do
        if scale[i] == (chord.root % 12) then degree = i break end
    end
    if not degree then return "?" end

    local lower, symbol, seventh = roman_quality(chord.type)
    local base = lower and ROMAN_LOWER[degree] or ROMAN_UPPER[degree]
    -- m7b5 renders as vii° with a 7: "vii°" + "7" style. Keep symbol then 7.
    return base .. symbol .. seventh
end

function M.DiatonicChords(key, sevenths)
    local scale = M.Scale(key)
    local n = #scale
    local out = {}
    for deg = 1, n do
        local root = scale[deg]
        -- Stack thirds within the scale to build the triad / seventh.
        local third = scale[((deg - 1 + 2) % n) + 1]
        local fifth = scale[((deg - 1 + 4) % n) + 1]
        local i3 = (third - root) % 12
        local i5 = (fifth - root) % 12
        local type_name
        if sevenths then
            local seventh = scale[((deg - 1 + 6) % n) + 1]
            local i7 = (seventh - root) % 12
            type_name = M.matchTriadSeventh(i3, i5, i7)
        else
            type_name = M.matchTriad(i3, i5)
        end
        local chord = { root = root, type = type_name, bass = nil }
        out[deg] = { chord = chord, roman = M.RomanNumeral(chord, key) }
    end
    return out
end

-- Interval-pattern → chord type name for diatonic building.
function M.matchTriad(i3, i5)
    if i3 == 4 and i5 == 7 then return "maj" end
    if i3 == 3 and i5 == 7 then return "min" end
    if i3 == 3 and i5 == 6 then return "dim" end
    if i3 == 4 and i5 == 8 then return "aug" end
    return "maj"
end

function M.matchTriadSeventh(i3, i5, i7)
    if i3 == 4 and i5 == 7 and i7 == 11 then return "maj7" end
    if i3 == 4 and i5 == 7 and i7 == 10 then return "7" end
    if i3 == 3 and i5 == 7 and i7 == 10 then return "m7" end
    if i3 == 3 and i5 == 7 and i7 == 11 then return "mMaj7" end
    if i3 == 3 and i5 == 6 and i7 == 10 then return "m7b5" end
    if i3 == 3 and i5 == 6 and i7 == 9 then return "dim7" end
    if i3 == 4 and i5 == 8 and i7 == 11 then return "augMaj7" end
    if i3 == 4 and i5 == 8 and i7 == 10 then return "aug7" end
    return "maj7"
end

-- ---------------------------------------------------------------------------
-- Transformations
-- ---------------------------------------------------------------------------

function M.Transpose(chord, semitones)
    if not chord then return nil end
    local new_bass = nil
    if chord.bass ~= nil then new_bass = (chord.bass + semitones) % 12 end
    return {
        root = (chord.root + semitones) % 12,
        type = chord.type,
        bass = new_bass,
    }
end

function M.TritoneSub(chord)
    -- Root up a tritone, forced to a dominant 7th.
    if not chord then return nil end
    return { root = (chord.root + 6) % 12, type = "7", bass = nil }
end

-- Whether a chord type is "minor-ish" (minor 3rd, no major 3rd).
local function is_minor_triadish(type_name)
    local t = M.TYPE_BY_NAME[type_name]
    if not t then return false end
    return t.set[3] == true and t.set[4] ~= true
end

function M.RelativeOf(chord)
    -- Major → relative minor (root down m3); minor → relative major (root up m3).
    -- Preserve triad-vs-seventh flavor by swapping the type accordingly.
    if not chord then return nil end
    if is_minor_triadish(chord.type) then
        -- minor → relative major
        local new_root = (chord.root + 3) % 12
        local new_type = chord.type
        if chord.type == "min" then new_type = "maj"
        elseif chord.type == "m7" then new_type = "maj7"
        elseif chord.type == "m6" then new_type = "6" end
        return { root = new_root, type = new_type, bass = nil }
    else
        -- major (or default) → relative minor
        local new_root = (chord.root - 3) % 12
        local new_type = chord.type
        if chord.type == "maj" then new_type = "min"
        elseif chord.type == "maj7" then new_type = "m7"
        elseif chord.type == "6" then new_type = "m6"
        elseif chord.type == "7" then new_type = "m7" end
        return { root = new_root, type = new_type, bass = nil }
    end
end

function M.ParallelOf(chord)
    -- Same root, swap major<->minor quality (triad and seventh flavors).
    if not chord then return nil end
    local map = {
        maj = "min", min = "maj",
        maj7 = "m7", m7 = "maj7",
        ["6"] = "m6", m6 = "6",
        ["7"] = "m7",       -- dominant 7 -> minor 7 as the parallel-minor read
        maj9 = "m9", m9 = "maj9",
        add9 = "madd9", madd9 = "add9",
    }
    local new_type = map[chord.type] or chord.type
    return { root = chord.root, type = new_type, bass = nil }
end

function M.SecondaryDominant(target)
    -- V7 of the target's root: root up a perfect 5th, dominant 7th.
    if not target then return nil end
    return { root = (target.root + 7) % 12, type = "7", bass = nil }
end

function M.ChromaticMediants(chord)
    -- Four mediants at ±M3 / ±m3, quality preserved (same type).
    if not chord then return {} end
    local ty = chord.type
    return {
        { root = (chord.root + 4) % 12, type = ty, bass = nil }, -- up M3
        { root = (chord.root + 3) % 12, type = ty, bass = nil }, -- up m3
        { root = (chord.root - 3) % 12, type = ty, bass = nil }, -- down m3
        { root = (chord.root - 4) % 12, type = ty, bass = nil }, -- down M3
    }
end

-- ---------------------------------------------------------------------------
-- Negative harmony
-- ---------------------------------------------------------------------------

function M.MirrorPc(pc, key)
    -- Reflect across the tonic/dominant axis: pc' = (2*tonic + 7 - pc) mod 12.
    return (2 * key.tonic + 7 - pc) % 12
end

function M.NegativeMirror(chord, key)
    -- Mirror every chord pc, then re-detect. Bass = mirror of the original root
    -- (in negative harmony the root maps to a specific reflected pc, which we
    -- feed as the bass so the re-detection is anchored). Always returns a Chord.
    if not chord or not key then return nil end
    local pcs = M.ChordPcs(chord)
    local weights = {}
    for i = 1, #pcs do
        weights[M.MirrorPc(pcs[i], key)] = 1
    end
    local mirror_root_bass = M.MirrorPc(chord.root, key)
    local ranked = M.DetectFromWeights(weights, mirror_root_bass)
    -- Find the best candidate that actually carries a chord (skip pure note /
    -- interval readings, which only happen for <3 pcs).
    for i = 1, #ranked do
        if ranked[i].chord then
            -- Return the abstract negative-harmony chord: drop the slash bass
            -- (the mirrored-root anchor is a scoring aid, not part of the result;
            -- pin C major C -> Cm expects no slash).
            local c = ranked[i].chord
            return { root = c.root, type = c.type, bass = nil }
        end
    end
    -- Fallback (dyad / single pc mirror): build a power chord on the bass so we
    -- never return nil.
    return { root = mirror_root_bass, type = "5", bass = nil }
end

return M
