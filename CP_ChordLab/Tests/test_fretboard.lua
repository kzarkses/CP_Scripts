-- @description CP ChordLab — Fretboard module tests
-- @author Cedric Pamalio

-- Loaded by run_tests.lua as: chunk(T, M). Returns an array of {name, fn}.
-- Uses M.Fretboard (wired via Init(Theory)) and M.Theory.

local T, M = ...
local F = M.Fretboard
local Theory = M.Theory

-- --- helpers ----------------------------------------------------------------

-- Build a fresh state on the given tuning with an explicit fingers array.
local function state_with(tuning_idx, capo, fingers)
    local st = F.New(tuning_idx or 1)
    st.capo = capo or 0
    if fingers then
        for s = 1, 6 do st.fingers[s] = fingers[s] end
    end
    return st
end

-- Distinct sounding pcs of a fingering on the given tuning/capo.
local function fingering_pcs(tuning_idx, capo, fingers)
    local st = state_with(tuning_idx, capo, fingers)
    local pit = F.Pitches(st)
    local set = {}
    for i = 1, #pit do set[pit[i] % 12] = true end
    return set, pit
end

-- Chord pc membership set from Theory.
local function chord_pc_set(chord)
    local pcs = Theory.ChordPcs(chord)
    local set, n = {}, 0
    for i = 1, #pcs do
        local pc = pcs[i] % 12
        if not set[pc] then set[pc] = true; n = n + 1 end
    end
    return set, n
end

-- Count sounding strings + fretted span of a fingering.
local function sounding_and_span(fingers)
    local sounding, minf, maxf = 0, nil, nil
    for s = 1, 6 do
        local f = fingers[s]
        if f >= 0 then
            sounding = sounding + 1
            if f >= 1 then
                if minf == nil or f < minf then minf = f end
                if maxf == nil or f > maxf then maxf = f end
            end
        end
    end
    local span = 0
    if minf ~= nil then span = maxf - minf + 1 end
    return sounding, span
end

-- Assert that a solver result set is well-formed for `chord`.
local function assert_fingerings_valid(results, chord, opts, tuning_idx, capo, label)
    local cset, ncount = chord_pc_set(chord)
    local max_span = opts.max_span or 4
    local min_strings = opts.min_strings or 3
    T.assert_true(#results >= 1, label .. ": at least one fingering returned")
    for i = 1, #results do
        local f = results[i]
        local pcset, pit = fingering_pcs(tuning_idx, capo, f)
        -- 1. Realizes only chord pcs.
        for pc in pairs(pcset) do
            T.assert_true(cset[pc] == true,
                label .. " #" .. i .. ": pc " .. pc .. " is not a chord tone")
        end
        -- 2. Covers all chord pcs.
        local covered = 0
        for pc in pairs(cset) do
            if pcset[pc] then covered = covered + 1 end
        end
        T.assert_eq(covered, ncount, label .. " #" .. i .. ": all pcs covered")
        -- 3. Span within max_span, and enough sounding strings.
        local sounding, span = sounding_and_span(f)
        T.assert_true(span <= max_span,
            label .. " #" .. i .. ": span " .. span .. " <= " .. max_span)
        T.assert_true(sounding >= min_strings,
            label .. " #" .. i .. ": sounding " .. sounding .. " >= " .. min_strings)
    end
end

-- Deep-compare two fingerings arrays.
local function fingers_equal(a, b)
    for s = 1, 6 do
        if a[s] ~= b[s] then return false end
    end
    return true
end

-- --- tests ------------------------------------------------------------------

local tests = {}

-- 1. New() default state shape.
tests[#tests + 1] = { name = "New default state", fn = function()
    local st = F.New(1)
    T.assert_eq(st.tuning, 1, "tuning index")
    T.assert_eq(st.capo, 0, "capo starts at 0")
    T.assert_eq(#st.fingers, 6, "six strings")
    for s = 1, 6 do
        T.assert_eq(st.fingers[s], -1, "string " .. s .. " starts muted")
    end
end }

-- 2. Tuning table sanity: 6 strings each, ascending low->high, valid MIDI.
tests[#tests + 1] = { name = "Tuning tables sane", fn = function()
    T.assert_true(#F.TUNINGS >= 5, "at least 5 tunings (Standard, Drop D, DADGAD, Open G, Open D)")
    for i = 1, #F.TUNINGS do
        local tun = F.TUNINGS[i]
        T.assert_true(type(tun.name) == "string" and #tun.name > 0, "tuning " .. i .. " named")
        T.assert_eq(#tun.notes, 6, tun.name .. ": six strings")
        for s = 1, 6 do
            local n = tun.notes[s]
            T.assert_true(n >= 0 and n <= 127, tun.name .. " string " .. s .. " valid MIDI")
        end
        -- Ascending low -> high (non-decreasing; some open tunings repeat octaves
        -- but never descend).
        for s = 2, 6 do
            T.assert_true(tun.notes[s] > tun.notes[s - 1],
                tun.name .. ": string " .. s .. " higher than " .. (s - 1))
        end
    end
end }

-- 3. Named tunings present with expected roots.
tests[#tests + 1] = { name = "Named tunings present", fn = function()
    local byname = {}
    for i = 1, #F.TUNINGS do byname[F.TUNINGS[i].name] = F.TUNINGS[i] end
    T.assert_true(byname["Standard"] ~= nil, "Standard present")
    T.assert_true(byname["Drop D"] ~= nil, "Drop D present")
    T.assert_true(byname["DADGAD"] ~= nil, "DADGAD present")
    T.assert_true(byname["Open G"] ~= nil, "Open G present")
    T.assert_true(byname["Open D"] ~= nil, "Open D present")
    -- Standard low E = 40, high E = 64.
    T.assert_eq(byname["Standard"].notes[1], 40, "Standard low E")
    T.assert_eq(byname["Standard"].notes[6], 64, "Standard high E")
    -- Drop D lowers the low string to D2 = 38.
    T.assert_eq(byname["Drop D"].notes[1], 38, "Drop D low string")
end }

-- 4. Pitches: open + muted + fretted mix (standard tuning arithmetic).
tests[#tests + 1] = { name = "Pitches open/muted/fretted", fn = function()
    -- Low string open, next muted, third fret 3 on D string.
    local st = state_with(1, 0, { 0, -1, 3, -1, -1, -1 })
    local pit = F.Pitches(st)
    -- Expect: 40 (open low E) and 53 (D3=50 + 3). Sorted ascending.
    T.assert_eq(#pit, 2, "two sounding strings")
    T.assert_eq(pit[1], 40, "open low E = 40")
    T.assert_eq(pit[2], 53, "D string fret 3 = 53")
end }

-- 5. Pitches: pinned E-major open shape (fingers 0,2,2,1,0,0).
tests[#tests + 1] = { name = "Pitches E-major open shape", fn = function()
    local st = state_with(1, 0, { 0, 2, 2, 1, 0, 0 })
    local pit = F.Pitches(st)
    -- E2 B2 E3 G#3 B3 E4 = 40,47,52,56,59,64.
    T.assert_eq(#pit, 6, "six sounding strings")
    T.assert_eq(pit[1], 40, "40")
    T.assert_eq(pit[2], 47, "47")
    T.assert_eq(pit[3], 52, "52")
    T.assert_eq(pit[4], 56, "56")
    T.assert_eq(pit[5], 59, "59")
    T.assert_eq(pit[6], 64, "64")
    -- pcs are exactly E-major {4,8,11}.
    local set = fingering_pcs(1, 0, { 0, 2, 2, 1, 0, 0 })
    T.assert_true(set[4] and set[8] and set[11], "E major pcs present")
    for pc in pairs(set) do
        T.assert_true(pc == 4 or pc == 8 or pc == 11, "only E-major pcs")
    end
end }

-- 6. Pitches: pinned A-minor open shape (fingers -1,0,2,2,1,0).
tests[#tests + 1] = { name = "Pitches A-minor open shape", fn = function()
    local st = state_with(1, 0, { -1, 0, 2, 2, 1, 0 })
    local pit = F.Pitches(st)
    -- Muted low E; A2 E3 A3 C4 E4 = 45,52,57,60,64.
    T.assert_eq(#pit, 5, "five sounding strings (low E muted)")
    T.assert_eq(pit[1], 45, "45")
    T.assert_eq(pit[2], 52, "52")
    T.assert_eq(pit[3], 57, "57")
    T.assert_eq(pit[4], 60, "60")
    T.assert_eq(pit[5], 64, "64")
    local set = fingering_pcs(1, 0, { -1, 0, 2, 2, 1, 0 })
    T.assert_true(set[9] and set[0] and set[4], "A minor pcs present")
    for pc in pairs(set) do
        T.assert_true(pc == 9 or pc == 0 or pc == 4, "only A-minor pcs")
    end
end }

-- 7. Pitches: capo raises open strings but not fretted notes.
tests[#tests + 1] = { name = "Pitches capo semantics", fn = function()
    -- capo 2. Open low E now sounds 42; fret 5 on low E still sounds 45 (absolute).
    local open_state = state_with(1, 2, { 0, -1, -1, -1, -1, -1 })
    T.assert_eq(F.Pitches(open_state)[1], 42, "capo 2 raises open string to 42")
    local fret_state = state_with(1, 2, { 5, -1, -1, -1, -1, -1 })
    T.assert_eq(F.Pitches(fret_state)[1], 45, "fretted note is absolute (40+5), ignores capo")
end }

-- 8. SetFinger mutates and returns state.
tests[#tests + 1] = { name = "SetFinger", fn = function()
    local st = F.New(1)
    local r = F.SetFinger(st, 3, 5)
    T.assert_true(r == st, "returns same state")
    T.assert_eq(st.fingers[3], 5, "string 3 set to fret 5")
    F.SetFinger(st, 1, 0)
    T.assert_eq(st.fingers[1], 0, "string 1 set open")
    F.SetFinger(st, 6, -1)
    T.assert_eq(st.fingers[6], -1, "string 6 muted")
    -- Out-of-range strings are ignored (no crash).
    F.SetFinger(st, 0, 3)
    F.SetFinger(st, 7, 3)
    T.assert_eq(st.fingers[3], 5, "unchanged after out-of-range")
end }

-- 9. Clear mutes all strings.
tests[#tests + 1] = { name = "Clear", fn = function()
    local st = state_with(1, 0, { 0, 2, 2, 1, 0, 0 })
    local r = F.Clear(st)
    T.assert_true(r == st, "returns same state")
    for s = 1, 6 do T.assert_eq(st.fingers[s], -1, "string " .. s .. " muted") end
    T.assert_eq(#F.Pitches(st), 0, "no sounding pitches after Clear")
end }

-- 10. FromPitches C major — every fingering valid.
tests[#tests + 1] = { name = "FromPitches C major valid", fn = function()
    local chord = { root = 0, type = "maj" }
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local res = F.FromPitches(F.New(1), chord, opts)
    assert_fingerings_valid(res, chord, opts, 1, 0, "C major")
    -- prefer_bass: top result's lowest sounding pc should be the root (C=0).
    local _, pit = fingering_pcs(1, 0, res[1])
    T.assert_eq(pit[1] % 12, 0, "C major top voicing bass = C")
end }

-- 11. FromPitches G major — every fingering valid + bass.
tests[#tests + 1] = { name = "FromPitches G major valid", fn = function()
    local chord = { root = 7, type = "maj" }
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local res = F.FromPitches(F.New(1), chord, opts)
    assert_fingerings_valid(res, chord, opts, 1, 0, "G major")
    local _, pit = fingering_pcs(1, 0, res[1])
    T.assert_eq(pit[1] % 12, 7, "G major top voicing bass = G")
end }

-- 12. FromPitches A minor — every fingering valid + bass.
tests[#tests + 1] = { name = "FromPitches A minor valid", fn = function()
    local chord = { root = 9, type = "min" }
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local res = F.FromPitches(F.New(1), chord, opts)
    assert_fingerings_valid(res, chord, opts, 1, 0, "A minor")
    local _, pit = fingering_pcs(1, 0, res[1])
    T.assert_eq(pit[1] % 12, 9, "A minor top voicing bass = A")
end }

-- 13. FromPitches: E major returns the textbook open shape as a candidate.
tests[#tests + 1] = { name = "FromPitches E major finds open shape", fn = function()
    local chord = { root = 4, type = "maj" }
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local res = F.FromPitches(F.New(1), chord, opts)
    assert_fingerings_valid(res, chord, opts, 1, 0, "E major")
    -- The open E-major shape 0,2,2,1,0,0 is the lowest-position full voicing;
    -- it must be the top-ranked result.
    T.assert_true(fingers_equal(res[1], { 0, 2, 2, 1, 0, 0 }),
        "E major top result is the open shape 0,2,2,1,0,0")
end }

-- 14. FromPitches: max_span is honored when tightened.
tests[#tests + 1] = { name = "FromPitches respects max_span", fn = function()
    local chord = { root = 0, type = "maj" }
    local opts = { max_results = 8, max_span = 3, min_strings = 3, prefer_bass = true }
    local res = F.FromPitches(F.New(1), chord, opts)
    assert_fingerings_valid(res, chord, opts, 1, 0, "C major span 3")
    for i = 1, #res do
        local _, span = sounding_and_span(res[i])
        T.assert_true(span <= 3, "fingering " .. i .. " span <= 3")
    end
end }

-- 15. FromPitches: min_strings floor is honored.
tests[#tests + 1] = { name = "FromPitches respects min_strings", fn = function()
    local chord = { root = 7, type = "maj" }
    local opts = { max_results = 6, max_span = 4, min_strings = 5, prefer_bass = true }
    local res = F.FromPitches(F.New(1), chord, opts)
    for i = 1, #res do
        local sounding = sounding_and_span(res[i])
        T.assert_true(sounding >= 5, "fingering " .. i .. " has >= 5 sounding strings")
    end
end }

-- 16. FromPitches: determinism — same input, byte-identical output.
tests[#tests + 1] = { name = "FromPitches deterministic", fn = function()
    local chord = { root = 0, type = "maj" }
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local a = F.FromPitches(F.New(1), chord, opts)
    local b = F.FromPitches(F.New(1), chord, opts)
    T.assert_eq(#a, #b, "same result count")
    for i = 1, #a do
        T.assert_true(fingers_equal(a[i], b[i]),
            "result " .. i .. " identical across runs")
    end
end }

-- 17. FromPitches: max_results caps the output count.
tests[#tests + 1] = { name = "FromPitches respects max_results", fn = function()
    local chord = { root = 0, type = "maj" }
    local res = F.FromPitches(F.New(1), chord,
        { max_results = 2, max_span = 4, min_strings = 3, prefer_bass = true })
    T.assert_true(#res <= 2, "at most 2 results")
    T.assert_true(#res >= 1, "at least 1 result")
end }

-- 18. FromPitches: capo interaction — fretted values stay above the capo and
--     the solver still covers the chord.
tests[#tests + 1] = { name = "FromPitches with capo", fn = function()
    local chord = { root = 0, type = "maj" }
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local st = F.New(1)
    st.capo = 2
    local res = F.FromPitches(st, chord, opts)
    assert_fingerings_valid(res, chord, opts, 1, 2, "C major capo 2")
    for i = 1, #res do
        for s = 1, 6 do
            local f = res[i][s]
            -- Fretted notes must be strictly above the capo (a fret at/below the
            -- capo is unplayable); open (0) and mute (-1) are always allowed.
            if f >= 1 then
                T.assert_true(f > st.capo,
                    "result " .. i .. " string " .. s .. " fret " .. f .. " > capo")
            end
        end
    end
end }

-- 19. FromPitches: a slash chord's bass lands on the lowest sounding string.
tests[#tests + 1] = { name = "FromPitches slash bass on lowest string", fn = function()
    -- C/E: root C (0), bass E (4). Prefer the E in the bass.
    local chord = { root = 0, type = "maj", bass = 4 }
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local res = F.FromPitches(F.New(1), chord, opts)
    assert_fingerings_valid(res, chord, opts, 1, 0, "C/E")
    local _, pit = fingering_pcs(1, 0, res[1])
    T.assert_eq(pit[1] % 12, 4, "C/E top voicing bass = E")
end }

-- 20. FromPitches on an alternate tuning still yields valid chord fingerings.
tests[#tests + 1] = { name = "FromPitches on Drop D tuning", fn = function()
    local chord = { root = 2, type = "maj" }  -- D major on Drop D
    local opts = { max_results = 5, max_span = 4, min_strings = 3, prefer_bass = true }
    local res = F.FromPitches(F.New(2), chord, opts)
    assert_fingerings_valid(res, chord, opts, 2, 0, "D major Drop D")
    local _, pit = fingering_pcs(2, 0, res[1])
    T.assert_eq(pit[1] % 12, 2, "D major top voicing bass = D on Drop D")
end }

return tests
