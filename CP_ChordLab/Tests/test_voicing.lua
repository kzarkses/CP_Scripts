-- @description CP ChordLab — Voicing.lua unit tests (pinned voice-leading & remap behavior)
-- @author Cedric Pamalio

-- Chunk contract: called as `chunk(T, M)` → returns array of {name, fn}.
-- T = assert helpers; M.Voicing = module under test (already Init'd with Theory),
-- M.Theory = the wired Theory module. No reaper global.

local T, M = ...
local Voicing = M.Voicing
local Theory  = M.Theory

-- Local helpers -------------------------------------------------------------

local function is_sorted_asc(arr)
    for i = 2, #arr do
        if arr[i] <= arr[i - 1] then return false end
    end
    return true
end

local function pc_set(arr)
    local s = {}
    for i = 1, #arr do s[arr[i] % 12] = true end
    return s
end

local function subset_of(arr, allowed_pcs)
    local allow = {}
    for i = 1, #allowed_pcs do allow[allowed_pcs[i]] = true end
    for i = 1, #arr do
        if not allow[arr[i] % 12] then return false, arr[i] % 12 end
    end
    return true
end

local function contains(arr, val)
    for i = 1, #arr do if arr[i] == val then return true end end
    return false
end

local function eq_arr(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- Greedy nearest-pair total |semitone| movement (same metric LeadFrom optimizes).
local function move_cost(prev, cand)
    local used, total = {}, 0
    for i = 1, #prev do
        local bj, bd = nil, nil
        for j = 1, #cand do
            if not used[j] then
                local d = math.abs(prev[i] - cand[j])
                if bd == nil or d < bd then bd = d; bj = j end
            end
        end
        if bj then used[bj] = true; total = total + bd end
    end
    return total
end

-- Brute-force optimal voice-leading movement into a chord's tones across a small
-- octave window (independent reference implementation for optimality tests).
local function brute_min_cost(prev, chord_pcs, octlo, octhi)
    local n = #chord_pcs
    local best = math.huge
    -- Enumerate an octave choice per tone (n small: triads/sevenths).
    local octs = {}
    local function rec(i)
        if i > n then
            local cand = {}
            for k = 1, n do cand[k] = chord_pcs[k] + 12 * octs[k] end
            table.sort(cand)
            local c = move_cost(prev, cand)
            if c < best then best = c end
            return
        end
        for o = octlo, octhi do
            octs[i] = o
            rec(i + 1)
        end
    end
    rec(1)
    return best
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- ---------------------------------------------------------------------------
-- Spell — sorted, correct pcs, inversions rotate, bass lowest, open = drop-2
-- ---------------------------------------------------------------------------

test("spell: C major root position is C E G, sorted ascending", function()
    local v = Voicing.Spell({ root = 0, type = "maj" }, { register = 48 })
    T.assert_true(is_sorted_asc(v), "sorted ascending")
    T.assert_deep_eq(v, { 48, 52, 55 }, "C3 E3 G3")
end)

test("spell: pcs equal the chord's pcs (Cmaj7)", function()
    local v = Voicing.Spell({ root = 0, type = "maj7" }, { register = 48 })
    local got = pc_set(v)
    for _, pc in ipairs({ 0, 4, 7, 11 }) do
        T.assert_true(got[pc] == true, "pc present: " .. pc)
    end
    T.assert_true(is_sorted_asc(v), "sorted")
end)

test("spell: register raises the whole voicing by an octave", function()
    local lo = Voicing.Spell({ root = 0, type = "maj" }, { register = 48 })
    local hi = Voicing.Spell({ root = 0, type = "maj" }, { register = 60 })
    T.assert_deep_eq(lo, { 48, 52, 55 })
    T.assert_deep_eq(hi, { 60, 64, 67 })
end)

test("spell: inversions rotate the chord tones", function()
    local root = Voicing.Spell({ root = 0, type = "maj" }, { register = 48, inversion = 0 })
    local inv1 = Voicing.Spell({ root = 0, type = "maj" }, { register = 48, inversion = 1 })
    local inv2 = Voicing.Spell({ root = 0, type = "maj" }, { register = 48, inversion = 2 })
    T.assert_deep_eq(root, { 48, 52, 55 }, "root pos C E G")
    T.assert_deep_eq(inv1, { 52, 55, 60 }, "1st inv E G C")
    T.assert_deep_eq(inv2, { 55, 60, 64 }, "2nd inv G C E")
    -- Every inversion carries the same pc set.
    for _, v in ipairs({ root, inv1, inv2 }) do
        local s = pc_set(v)
        T.assert_true(s[0] and s[4] and s[7], "same triad pcs")
    end
end)

test("spell: open voicing is drop-2 (2nd-highest voice down an octave)", function()
    -- Close Cmaj7 = {48,52,55,59}. drop-2 drops G(55) → 43.
    local open = Voicing.Spell({ root = 0, type = "maj7" }, { register = 48, spread = "open" })
    T.assert_true(is_sorted_asc(open), "still sorted")
    T.assert_deep_eq(open, { 43, 48, 52, 59 }, "G2 C3 E3 B3")
    -- Same pc content as the close voicing.
    local s = pc_set(open)
    T.assert_true(s[0] and s[4] and s[7] and s[11], "all four tones present")
end)

test("spell: open on a triad (<4 tones) is unchanged", function()
    local close = Voicing.Spell({ root = 0, type = "maj" }, { register = 48 })
    local open  = Voicing.Spell({ root = 0, type = "maj" }, { register = 48, spread = "open" })
    T.assert_deep_eq(open, close, "no drop-2 with only 3 voices")
end)

test("spell: slash bass is always the lowest sounding note", function()
    -- Am7/G : G must be below A, C, E, G.
    local v = Voicing.Spell({ root = 9, type = "m7", bass = 7 }, { register = 48 })
    T.assert_true(is_sorted_asc(v), "sorted")
    T.assert_eq(v[1] % 12, 7, "lowest pc is the bass G")
    for i = 2, #v do
        T.assert_true(v[i] > v[1], "bass strictly lowest")
    end
end)

test("spell: bass == root does not add a duplicate note", function()
    local a = Voicing.Spell({ root = 0, type = "maj" }, { register = 48 })
    local b = Voicing.Spell({ root = 0, type = "maj", bass = 0 }, { register = 48 })
    T.assert_deep_eq(b, a, "explicit root bass changes nothing")
end)

-- ---------------------------------------------------------------------------
-- Inversions — one voicing per rotation, labeled
-- ---------------------------------------------------------------------------

test("inversions: triad yields 3 labeled rotations", function()
    local invs = Voicing.Inversions({ root = 0, type = "maj" }, 48)
    T.assert_eq(#invs, 3, "three rotations for a triad")
    T.assert_eq(invs[1].label, "root")
    T.assert_eq(invs[2].label, "1st")
    T.assert_eq(invs[3].label, "2nd")
    T.assert_deep_eq(invs[1].pitches, { 48, 52, 55 })
    T.assert_deep_eq(invs[2].pitches, { 52, 55, 60 })
    for i = 1, #invs do
        T.assert_true(is_sorted_asc(invs[i].pitches), "rotation " .. i .. " sorted")
    end
end)

test("inversions: seventh chord yields 4 rotations, all same pc set", function()
    local invs = Voicing.Inversions({ root = 0, type = "maj7" }, 48)
    T.assert_eq(#invs, 4, "four rotations for a seventh")
    for i = 1, #invs do
        local s = pc_set(invs[i].pitches)
        T.assert_true(s[0] and s[4] and s[7] and s[11], "rotation " .. i .. " covers all tones")
    end
end)

-- ---------------------------------------------------------------------------
-- LeadFrom — determinism + minimal total movement
-- ---------------------------------------------------------------------------

test("leadfrom: nil / empty prev falls back to Spell", function()
    local spelled = Voicing.Spell({ root = 9, type = "min" }, { register = 48 })
    T.assert_deep_eq(Voicing.LeadFrom(nil, { root = 9, type = "min" }, { register = 48 }), spelled,
        "nil prev == Spell")
    T.assert_deep_eq(Voicing.LeadFrom({}, { root = 9, type = "min" }, { register = 48 }), spelled,
        "empty prev == Spell")
end)

test("leadfrom: deterministic — same input twice yields identical output", function()
    local prev = { 60, 64, 67 }
    local a = Voicing.LeadFrom(prev, { root = 5, type = "maj" })
    local b = Voicing.LeadFrom(prev, { root = 5, type = "maj" })
    T.assert_deep_eq(a, b, "F voicing stable")
    local c = Voicing.LeadFrom(prev, { root = 7, type = "7" })
    local d = Voicing.LeadFrom(prev, { root = 7, type = "7" })
    T.assert_deep_eq(c, d, "G7 voicing stable")
end)

test("leadfrom: same cardinality as the chord tones", function()
    local prev = { 60, 64, 67 }
    local f = Voicing.LeadFrom(prev, { root = 5, type = "maj" })
    T.assert_eq(#f, 3, "triad → 3 voices")
    local g7 = Voicing.LeadFrom(prev, { root = 7, type = "7" })
    T.assert_eq(#g7, 4, "dominant 7 → 4 voices")
end)

test("leadfrom: Am → F is movement-optimal vs brute-force", function()
    -- Previous voicing: A minor triad around A3.
    local prev = Voicing.Spell({ root = 9, type = "min" }, { register = 57 })
    local lead = Voicing.LeadFrom(prev, { root = 5, type = "maj" })
    local got = move_cost(prev, lead)
    local opt = brute_min_cost(prev, Theory.ChordPcs({ root = 5, type = "maj" }), 3, 7)
    T.assert_eq(got, opt, "LeadFrom equals brute-force minimum for Am→F")
    T.assert_true(is_sorted_asc(lead), "sorted")
end)

test("leadfrom: C → G7 is movement-optimal vs brute-force", function()
    local prev = { 60, 64, 67 }
    local lead = Voicing.LeadFrom(prev, { root = 7, type = "7" })
    local got = move_cost(prev, lead)
    local opt = brute_min_cost(prev, Theory.ChordPcs({ root = 7, type = "7" }), 3, 7)
    T.assert_eq(got, opt, "LeadFrom equals brute-force minimum for C→G7")
    T.assert_true(is_sorted_asc(lead), "sorted")
end)

test("leadfrom: C → F moves little (voice-leading stays near register)", function()
    local prev = { 60, 64, 67 }               -- C4 E4 G4
    local lead = Voicing.LeadFrom(prev, { root = 5, type = "maj" })
    -- Nearest F triad to C4-E4-G4 is C4 F4 A4 = total 3 semitones.
    T.assert_eq(move_cost(prev, lead), 3, "minimal common-tone motion")
    T.assert_true(pc_set(lead)[5] and pc_set(lead)[9] and pc_set(lead)[0], "F A C tones")
end)

-- ---------------------------------------------------------------------------
-- MapNotes — the pinned C-arpeggio → Am case + edge cases
-- ---------------------------------------------------------------------------

test("mapnotes: C major arpeggio → Am (pinned contract case)", function()
    -- {C4,E4,G4,C5,E5} → pcs ⊆ {A,C,E}, each move ≤ 6, contour preserved.
    local old = { 60, 64, 67, 72, 76 }
    local map = Voicing.MapNotes(old, { root = 9, type = "min" })
    -- Build the remapped sequence in the original order.
    local mapped = {}
    for i = 1, #old do
        T.assert_true(map[old[i]] ~= nil, "every old pitch mapped: " .. old[i])
        mapped[i] = map[old[i]]
    end
    -- (a) result pcs are a subset of {A(9), C(0), E(4)}.
    local ok, bad = subset_of(mapped, { 9, 0, 4 })
    T.assert_true(ok, "result pcs ⊆ {A,C,E}, offending pc " .. tostring(bad))
    -- (b) every old pitch moves ≤ 6 semitones.
    for i = 1, #old do
        T.assert_true(math.abs(mapped[i] - old[i]) <= 6, "small move for " .. old[i])
    end
    -- (c) contour (pairwise order) preserved where movement allows: the strictly
    -- ascending arpeggio stays non-descending after remap.
    for i = 2, #mapped do
        T.assert_true(mapped[i] >= mapped[i - 1], "contour preserved at index " .. i)
    end
    -- (d) at least one note lands on A (the new root is reachable).
    T.assert_true(pc_set(mapped)[9] == true, "A (new root) is covered")
end)

test("mapnotes: distinct-pc coverage — every new pc reachable when old ≥ new", function()
    -- Old has 3 distinct pcs (C E G), new Am has 3 (A C E) → all covered.
    local old = { 48, 52, 55 }
    local map = Voicing.MapNotes(old, { root = 9, type = "min" })
    local mapped = {}
    for i = 1, #old do mapped[i] = map[old[i]] end
    local s = pc_set(mapped)
    T.assert_true(s[9] and s[0] and s[4], "A, C and E all present")
end)

test("mapnotes: single pitch maps to the new chord's root", function()
    -- Fewer old pcs than the chord → root+third covered first; a lone note → root.
    local map = Voicing.MapNotes({ 60 }, { root = 9, type = "min" })
    T.assert_true(map[60] ~= nil, "mapped")
    T.assert_eq(map[60] % 12, 9, "C → A (new root)")
    T.assert_true(math.abs(map[60] - 60) <= 6, "nearest-octave placement")
end)

test("mapnotes: old fewer pcs than new chord covers root then third", function()
    -- {C, E} (2 pcs) → Gmaj7 (G B D F#, 4 tones): must cover root G and third B.
    local old = { 60, 64 }
    local map = Voicing.MapNotes(old, { root = 7, type = "maj7" })
    local mapped = {}
    for i = 1, #old do mapped[i] = map[old[i]] end
    local s = pc_set(mapped)
    T.assert_true(s[7] == true, "root G covered")
    T.assert_true(s[11] == true, "third B covered")
end)

test("mapnotes: chromatic passing tones move in parallel with chord tones", function()
    -- Chromatic run C C# D D# E → to F major. Non-chord tones (passing) shift by
    -- the same delta as their nearest matched chord tone (parallel motion), so the
    -- run stays a monotonic line, no octave jumps.
    local old = { 60, 61, 62, 63, 64 }
    local map = Voicing.MapNotes(old, { root = 5, type = "maj" })
    local mapped = {}
    for i = 1, #old do
        T.assert_true(map[old[i]] ~= nil, "passing tone mapped: " .. old[i])
        mapped[i] = map[old[i]]
    end
    -- The line remains non-descending (contour intact through passing tones).
    for i = 2, #mapped do
        T.assert_true(mapped[i] >= mapped[i - 1], "monotone through passing tones at " .. i)
    end
    -- No note leaps more than an octave from its source.
    for i = 1, #old do
        T.assert_true(math.abs(mapped[i] - old[i]) <= 12, "no big leap for " .. old[i])
    end
end)

test("mapnotes: old pitches spanning four octaves stay in their own register", function()
    -- C1..C6 (all pc C) → D minor. Each C should land on a Dm tone in its own
    -- octave (nearest-octave placement), preserving the wide layout.
    local old = { 36, 48, 60, 72, 84 }
    local map = Voicing.MapNotes(old, { root = 2, type = "min" })
    local mapped = {}
    for i = 1, #old do mapped[i] = map[old[i]] end
    -- (a) each maps to a Dm pc.
    local ok = subset_of(mapped, { 2, 5, 9 })
    T.assert_true(ok, "all pcs ∈ Dm {D,F,A}")
    -- (b) each within an octave of its source (register preserved).
    for i = 1, #old do
        T.assert_true(math.abs(mapped[i] - old[i]) <= 6, "near source for " .. old[i])
    end
    -- (c) the wide span is preserved (strictly ascending sources → non-descending).
    for i = 2, #mapped do
        T.assert_true(mapped[i] >= mapped[i - 1], "span preserved at " .. i)
    end
end)

test("mapnotes: new chord with more distinct pcs than old input never crashes", function()
    -- 1 old pc → 6-tone 11 chord. Must return a map and cover the root.
    local map = Voicing.MapNotes({ 60 }, { root = 0, type = "11" })
    T.assert_true(map[60] ~= nil, "single note mapped against a dense chord")
    T.assert_eq(map[60] % 12, 0, "covers the root C first")
end)

test("mapnotes: deterministic — same input twice yields identical maps", function()
    local old = { 60, 64, 67, 72, 76 }
    local a = Voicing.MapNotes(old, { root = 9, type = "min" })
    local b = Voicing.MapNotes(old, { root = 9, type = "min" })
    for i = 1, #old do
        T.assert_eq(a[old[i]], b[old[i]], "stable mapping for " .. old[i])
    end
end)

test("mapnotes: empty input returns an empty map", function()
    local map = Voicing.MapNotes({}, { root = 0, type = "maj" })
    local count = 0
    for _ in pairs(map) do count = count + 1 end
    T.assert_eq(count, 0, "no entries for empty input")
end)

test("mapnotes: duplicate old pitches collapse to one mapping key", function()
    -- Repeated pitches (same arpeggio note struck twice) map consistently.
    local old = { 60, 60, 64, 64 }
    local map = Voicing.MapNotes(old, { root = 5, type = "maj" })
    T.assert_true(map[60] ~= nil and map[64] ~= nil, "both distinct pitches mapped")
    -- Mapping is by pitch value, so both 60 entries share one target.
    local ok = subset_of({ map[60], map[64] }, { 5, 9, 0 })
    T.assert_true(ok, "targets are F-major tones")
end)

return tests
