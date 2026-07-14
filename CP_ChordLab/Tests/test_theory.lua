-- @description CP ChordLab — Theory.lua unit tests (pinned product behavior)
-- @author Cedric Pamalio

-- Chunk contract: called as `chunk(T, M)` → returns array of {name, fn}.
-- T = assert helpers, M.Theory = module under test. No reaper global.

local T, M = ...
local Theory = M.Theory

-- Local helpers -------------------------------------------------------------

-- Name of the top-ranked detection for a set of MIDI pitches (C4 = 60).
local function best_name(pitches, opts)
    local r = Theory.Detect(pitches, opts)
    if #r == 0 then return "(none)" end
    return r[1].name
end

local function best_chord(pitches, opts)
    local r = Theory.Detect(pitches, opts)
    return r[1] and r[1].chord or nil
end

-- Build a pc-weight histogram from a list of pcs (counts as weight).
local function hist(pcs)
    local w = {}
    for i = 1, #pcs do w[pcs[i]] = (w[pcs[i]] or 0) + 1 end
    return w
end

-- Membership test on a dense pc array.
local function has_pc(arr, pc)
    for i = 1, #arr do if arr[i] == pc then return true end end
    return false
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- ---------------------------------------------------------------------------
-- Pinned detection expectations (one test per row of ARCHITECTURE.md table)
-- ---------------------------------------------------------------------------

test("detect: C4 E4 G4 -> C", function()
    T.assert_eq(best_name({ 60, 64, 67 }), "C")
end)

test("detect: E3 C4 E4 G4 -> C/E (first inversion slash)", function()
    T.assert_eq(best_name({ 52, 60, 64, 67 }), "C/E")
    local c = best_chord({ 52, 60, 64, 67 })
    T.assert_eq(c.root, 0, "root C")
    T.assert_eq(c.type, "maj", "triad")
    T.assert_eq(c.bass, 4, "bass E")
end)

test("detect: C3 Eb3 G3 Bb3 -> Cm7", function()
    T.assert_eq(best_name({ 48, 51, 55, 58 }), "Cm7")
end)

test("detect: A2 C3 E3 G3 -> Am7", function()
    T.assert_eq(best_name({ 45, 48, 52, 55 }), "Am7")
end)

test("detect: C3 E3 G3 A3 -> C6 (bass C beats Am7/C)", function()
    T.assert_eq(best_name({ 48, 52, 55, 57 }), "C6")
end)

test("detect: C3 E3 Bb3 -> C7 (missing 5th is cheap)", function()
    T.assert_eq(best_name({ 48, 52, 58 }), "C7")
    -- The 5th (G) must appear in `missing`, not sink the reading.
    local r = Theory.Detect({ 48, 52, 58 })
    T.assert_true(has_pc(r[1].missing, 7), "G is a missing 5th")
end)

test("detect: C3 F3 G3 -> Csus4", function()
    T.assert_eq(best_name({ 48, 53, 55 }), "Csus4")
end)

test("detect: C3 Eb3 Gb3 A3 -> Cdim7", function()
    T.assert_eq(best_name({ 48, 51, 54, 57 }), "Cdim7")
end)

test("detect: B2 D3 F3 A3 -> Bm7b5", function()
    T.assert_eq(best_name({ 47, 50, 53, 57 }), "Bm7b5")
end)

test("detect: C3 E3 G#3 -> Caug (root by bass preference)", function()
    T.assert_eq(best_name({ 48, 52, 56 }), "Caug")
end)

test("detect: G2 B2 D3 F3 -> G7", function()
    T.assert_eq(best_name({ 43, 47, 50, 53 }), "G7")
end)

test("detect: C3 D3 G3 -> Csus2 (bass tiebreak vs Gsus4/C)", function()
    T.assert_eq(best_name({ 48, 50, 55 }), "Csus2")
end)

-- ---------------------------------------------------------------------------
-- Detection robustness: 1 note, dyads, clusters, slash, rootless
-- ---------------------------------------------------------------------------

test("detect: single pitch names the note, chord = nil", function()
    local r = Theory.Detect({ 60 })
    T.assert_eq(#r, 1)
    T.assert_eq(r[1].name, "C4")
    T.assert_true(r[1].chord == nil, "no chord for a single note")
end)

test("detect: perfect-fifth dyad -> power chord '5'", function()
    local r = Theory.Detect({ 60, 67 })   -- C4 G4
    T.assert_eq(r[1].name, "C5")
    T.assert_eq(r[1].chord.type, "5", "power chord type")
    T.assert_eq(r[1].chord.root, 0, "root C")
end)

test("detect: non-fifth dyad -> interval name, chord = nil", function()
    local r = Theory.Detect({ 60, 64 })   -- C4 E4 (major third)
    T.assert_true(r[1].chord == nil, "no chord for a bare third")
    T.assert_eq(r[1].name, "C M3 E")
end)

test("detect: 9-note cluster never crashes, returns best effort", function()
    local r = Theory.Detect({ 60, 62, 63, 64, 65, 67, 69, 70, 71 })
    T.assert_true(#r >= 1, "at least one reading")
    T.assert_true(r[1].chord ~= nil, "a chord is proposed for a dense cluster")
end)

test("detect: slash naming Am7/G", function()
    -- G2 A2 C3 E3 G3 : Am7 with G in the bass.
    T.assert_eq(best_name({ 43, 45, 48, 52, 55 }), "Am7/G")
end)

test("detect: rootless E-G-B reads as a real triad (Em)", function()
    -- Rootless voicings must still yield a reasonable chord (not nil, not junk).
    local c = best_chord({ 64, 67, 71 })
    T.assert_true(c ~= nil, "rootless voicing still detected")
    T.assert_eq(c.type, "min", "E-G-B is an E minor triad")
    T.assert_eq(c.root, 4, "root E")
end)

test("detect: flats option spells with flats", function()
    -- Eb3 G3 Bb3 -> Eb major-ish; assert the accidental spelling honors flats.
    local r = Theory.Detect({ 51, 55, 58 }, { flats = true })
    T.assert_eq(r[1].name:sub(1, 2), "Eb", "flat spelling")
end)

-- ---------------------------------------------------------------------------
-- Key detection (Krumhansl-Schmuckler)
-- ---------------------------------------------------------------------------

test("key: C-major histogram -> C major", function()
    -- C major scale, tonic-triad emphasized.
    local w = hist({ 0, 2, 4, 5, 7, 9, 11, 0, 4, 7, 0, 7 })
    local k = Theory.DetectKey(w)
    T.assert_eq(k.tonic, 0, "tonic C")
    T.assert_eq(k.mode, "major")
    T.assert_true(k.confidence > 0, "positive confidence")
end)

test("key: A-natural-minor histogram -> A minor", function()
    -- A minor: tonic A, dominant E, minor third C emphasized (bare diatonic set
    -- is ambiguous with C major, so KK needs the tonic weighting — expected).
    local w = hist({ 9, 11, 0, 2, 4, 5, 7, 9, 9, 0, 0, 4, 4 })
    local k = Theory.DetectKey(w)
    T.assert_eq(k.tonic, 9, "tonic A")
    T.assert_eq(k.mode, "minor")
end)

test("key: empty histogram -> C major, confidence 0", function()
    local k = Theory.DetectKey({})
    T.assert_eq(k.tonic, 0)
    T.assert_eq(k.mode, "major")
    T.assert_eq(k.confidence, 0)
end)

test("key: ranked list has all 24 keys, confidence in [0,1]", function()
    local w = hist({ 0, 2, 4, 5, 7, 9, 11 })
    local k = Theory.DetectKey(w)
    T.assert_eq(#k.ranked, 24, "12 tonics x 2 modes")
    T.assert_true(k.confidence >= 0 and k.confidence <= 1, "confidence normalized")
end)

-- ---------------------------------------------------------------------------
-- Roman numerals (exact label format pinned)
-- ---------------------------------------------------------------------------

local Ckey = { tonic = 0, mode = "major" }

test("roman: C major diatonic sevenths render with pinned labels", function()
    local RN = function(root, ty) return Theory.RomanNumeral({ root = root, type = ty }, Ckey) end
    T.assert_eq(RN(0, "maj7"), "Imaj7", "I")
    T.assert_eq(RN(2, "m7"), "ii7", "ii (minor seventh -> lowercase + 7)")
    T.assert_eq(RN(4, "m7"), "iii7", "iii")
    T.assert_eq(RN(5, "maj7"), "IVmaj7", "IV")
    T.assert_eq(RN(7, "7"), "V7", "V (dominant seventh -> uppercase + 7)")
    T.assert_eq(RN(9, "m7"), "vi7", "vi")
    T.assert_eq(RN(11, "m7b5"), "vii°7", "vii half-diminished -> vii°7")
end)

test("roman: non-diatonic root -> '?'", function()
    T.assert_eq(Theory.RomanNumeral({ root = 8, type = "maj" }, Ckey), "?", "Ab not in C major")
end)

test("roman: DiatonicChords(C, sevenths) matches the diatonic set", function()
    local dc = Theory.DiatonicChords(Ckey, true)
    T.assert_eq(#dc, 7)
    T.assert_eq(Theory.ChordName(dc[2].chord), "Dm7")
    T.assert_eq(dc[2].roman, "ii7")
    T.assert_eq(Theory.ChordName(dc[5].chord), "G7")
    T.assert_eq(dc[5].roman, "V7")
    T.assert_eq(Theory.ChordName(dc[7].chord), "Bm7b5")
    T.assert_eq(dc[7].roman, "vii°7")
end)

test("scale: C major and D dorian pcs", function()
    T.assert_deep_eq(Theory.Scale(Ckey), { 0, 2, 4, 5, 7, 9, 11 })
    T.assert_deep_eq(Theory.Scale({ tonic = 2, mode = "dorian" }), { 2, 4, 5, 7, 9, 11, 0 })
end)

-- ---------------------------------------------------------------------------
-- Naming: PcName / NoteName / ChordName nil-safety + slash
-- ---------------------------------------------------------------------------

test("naming: PcName sharps vs flats", function()
    T.assert_eq(Theory.PcName(1, false), "C#")
    T.assert_eq(Theory.PcName(1, true), "Db")
    T.assert_eq(Theory.PcName(0, false), "C")
    T.assert_eq(Theory.PcName(-1, false), "B", "negative pc wraps")
    T.assert_eq(Theory.PcName(13, false), "C#", "pc > 11 wraps")
end)

test("naming: NoteName octave mapping (C4 = 60)", function()
    T.assert_eq(Theory.NoteName(60), "C4")
    T.assert_eq(Theory.NoteName(69), "A4")
    T.assert_eq(Theory.NoteName(0), "C-1")
    T.assert_eq(Theory.NoteName(61, true), "Db4", "flats honored")
end)

test("naming: ChordName nil-safe -> em dash", function()
    T.assert_eq(Theory.ChordName(nil), "—")
end)

test("naming: ChordName slash + flats", function()
    T.assert_eq(Theory.ChordName({ root = 9, type = "m7", bass = 7 }), "Am7/G")
    T.assert_eq(Theory.ChordName({ root = 6, type = "m7b5" }), "F#m7b5")
    -- bass == root is NOT a slash.
    T.assert_eq(Theory.ChordName({ root = 0, type = "maj", bass = 0 }), "C")
end)

-- ---------------------------------------------------------------------------
-- ChordPcs / ChordEquals
-- ---------------------------------------------------------------------------

test("ChordPcs: Cmaj7 = {0,4,7,11}, bass not prepended", function()
    T.assert_deep_eq(Theory.ChordPcs({ root = 0, type = "maj7", bass = 4 }), { 0, 4, 7, 11 })
end)

test("ChordEquals: compares root/type/effective-bass", function()
    T.assert_true(Theory.ChordEquals({ root = 0, type = "maj" }, { root = 0, type = "maj", bass = 0 }),
        "nil bass == root bass")
    T.assert_true(not Theory.ChordEquals({ root = 0, type = "maj" }, { root = 0, type = "min" }))
    T.assert_true(not Theory.ChordEquals({ root = 0, type = "maj", bass = 4 }, { root = 0, type = "maj" }),
        "slash differs from root position")
end)

-- ---------------------------------------------------------------------------
-- Transforms
-- ---------------------------------------------------------------------------

test("Transpose: preserves type, moves root and bass", function()
    local t = Theory.Transpose({ root = 0, type = "maj" }, 2)
    T.assert_eq(Theory.ChordName(t), "D")
    local s = Theory.Transpose({ root = 9, type = "m7", bass = 7 }, 3)
    T.assert_eq(s.root, 0, "A+3 = C")
    T.assert_eq(s.bass, 10, "G+3 = Bb")
    T.assert_eq(s.type, "m7")
end)

test("TritoneSub: G7 -> Db7 (root+6, forced dominant 7)", function()
    local t = Theory.TritoneSub({ root = 7, type = "7" })
    T.assert_eq(t.root, 1, "G + tritone = Db")
    T.assert_eq(t.type, "7")
end)

test("RelativeOf: major <-> relative minor, seventh flavor preserved", function()
    T.assert_eq(Theory.ChordName(Theory.RelativeOf({ root = 0, type = "maj" })), "Am")
    T.assert_eq(Theory.ChordName(Theory.RelativeOf({ root = 9, type = "min" })), "C")
    T.assert_eq(Theory.ChordName(Theory.RelativeOf({ root = 0, type = "maj7" })), "Am7")
end)

test("ParallelOf: same root, quality swap", function()
    T.assert_eq(Theory.ChordName(Theory.ParallelOf({ root = 0, type = "maj" })), "Cm")
    T.assert_eq(Theory.ChordName(Theory.ParallelOf({ root = 0, type = "min" })), "C")
    T.assert_eq(Theory.ChordName(Theory.ParallelOf({ root = 9, type = "m7" })), "Amaj7")
end)

test("SecondaryDominant: V7 of target (root up P5, dominant 7)", function()
    local v = Theory.SecondaryDominant({ root = 2, type = "m7" }) -- V7/ii in C
    T.assert_eq(v.root, 9, "D + P5 = A")
    T.assert_eq(v.type, "7")
end)

test("ChromaticMediants: four mediants at +/-M3, +/-m3, quality preserved", function()
    local cm = Theory.ChromaticMediants({ root = 0, type = "maj" })
    T.assert_eq(#cm, 4)
    -- Roots: +M3=E(4), +m3=Eb(3), -m3=A(9), -M3=Ab(8). All keep type "maj".
    T.assert_eq(cm[1].root, 4); T.assert_eq(cm[1].type, "maj")
    T.assert_eq(cm[2].root, 3)
    T.assert_eq(cm[3].root, 9)
    T.assert_eq(cm[4].root, 8)
end)

-- ---------------------------------------------------------------------------
-- Negative harmony
-- ---------------------------------------------------------------------------

test("MirrorPc: reflection about tonic/dominant axis in C major", function()
    local key = { tonic = 0, mode = "major" }
    T.assert_eq(Theory.MirrorPc(0, key), 7, "C -> G")
    T.assert_eq(Theory.MirrorPc(4, key), 3, "E -> Eb")
    T.assert_eq(Theory.MirrorPc(7, key), 0, "G -> C")
    -- Involution: mirroring twice is the identity.
    for pc = 0, 11 do
        T.assert_eq(Theory.MirrorPc(Theory.MirrorPc(pc, key), key), pc, "involution")
    end
end)

test("NegativeMirror: C major -> Cm (pinned)", function()
    local nm = Theory.NegativeMirror({ root = 0, type = "maj" }, Ckey)
    T.assert_eq(Theory.ChordName(nm), "Cm")
end)

test("NegativeMirror: G7 -> Dm7b5 (documented enharmonic of Fm6)", function()
    -- G7 = {G,B,D,F} mirrors to pc set {0,2,5,8}. That 4-note set is BOTH Fm6
    -- (F Ab C D) and Dm7b5 (D F Ab C) — same pitches, different roots. Classic
    -- negative harmony calls it Fm6; the dictionary scorer prefers Dm7b5 because
    -- rank(m7b5)=82 > rank(m6)=80 with an otherwise identical full match, so we
    -- PIN the scorer's choice (Dm7b5) as the contract permits. It is the correct
    -- enharmonic reading of the negative-harmony set.
    local nm = Theory.NegativeMirror({ root = 7, type = "7" }, Ckey)
    local name = Theory.ChordName(nm)
    T.assert_true(name == "Dm7b5" or name == "Fm6",
        "negative-mirror of G7 is the Fm6/Dm7b5 set, got " .. tostring(name))
    T.assert_eq(name, "Dm7b5", "scorer's pinned choice")
    -- Whatever the name, the pc set must be the mirrored G7 set {0,2,5,8}.
    local pcs = Theory.ChordPcs(nm)
    for _, pc in ipairs({ 0, 2, 5, 8 }) do
        T.assert_true(has_pc(pcs, pc), "mirror set contains pc " .. pc)
    end
end)

test("NegativeMirror: always returns a Chord (never nil) for a triad", function()
    local nm = Theory.NegativeMirror({ root = 7, type = "min" }, Ckey)
    T.assert_true(nm ~= nil and nm.type ~= nil, "returns a concrete chord")
end)

-- ---------------------------------------------------------------------------
-- Dictionary integrity
-- ---------------------------------------------------------------------------

test("dictionary: TYPES dense + TYPE_BY_NAME covers every listed type", function()
    T.assert_true(#Theory.TYPES >= 30, "full dictionary present")
    for _, nm in ipairs({ "maj", "min", "dim", "aug", "sus2", "sus4", "5",
        "6", "m6", "69", "maj7", "7", "m7", "mMaj7", "dim7", "m7b5", "aug7",
        "augMaj7", "7sus4", "add9", "madd9", "maj9", "9", "m9", "11", "m11",
        "13", "maj13", "m13", "7b9", "7#9", "7b5", "7#5", "7#11", "7alt",
        "quartal", "quartal4" }) do
        local t = Theory.TYPE_BY_NAME[nm]
        T.assert_true(t ~= nil, "type present: " .. nm)
        T.assert_true(t.label ~= nil and t.family ~= nil and t.rank ~= nil,
            "type " .. nm .. " has label/family/rank")
    end
    T.assert_eq(Theory.TYPE_BY_NAME["quartal"].label, "4ths", "quartal label")
end)

test("dictionary: MODES has all nine listed scales", function()
    for _, nm in ipairs({ "major", "minor", "dorian", "phrygian", "lydian",
        "mixolydian", "locrian", "harmonic_minor", "melodic_minor" }) do
        T.assert_true(Theory.MODES[nm] ~= nil, "mode present: " .. nm)
        T.assert_eq(#Theory.MODES[nm], 7, "mode " .. nm .. " has 7 degrees")
    end
end)

return tests
