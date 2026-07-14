-- @description CP ChordLab — Suggest.lua unit tests (pure, no REAPER)
-- @author Cedric Pamalio

-- Loaded by run_tests.lua as: local T, M = ...
-- T = assertion helpers, M = wired modules (M.Suggest, M.Theory, ...).
-- Returns an array of { name, fn }.

local T, M = ...
local Suggest = M.Suggest
local Theory  = M.Theory

-- ---------------------------------------------------------------------------
-- Local helpers (pure; no dependency on iteration order for lookups)
-- ---------------------------------------------------------------------------

local C_MAJOR = { tonic = 0, mode = "major" }

-- Find a category table by key in a Suggest.For result, or nil.
local function cat_of(result, key)
    for i = 1, #result do
        if result[i].key == key then return result[i] end
    end
    return nil
end

-- True if any item in the category has the given label.
local function has_label(cat, label)
    if not cat then return false end
    for i = 1, #cat.items do
        if cat.items[i].label == label then return true end
    end
    return false
end

-- Return the detail string for the first item with the given label, or nil.
local function detail_of(cat, label)
    if not cat then return nil end
    for i = 1, #cat.items do
        if cat.items[i].label == label then return cat.items[i].detail end
    end
    return nil
end

-- Set of category keys present, as a lookup table.
local function key_set(result)
    local s = {}
    for i = 1, #result do s[result[i].key] = true end
    return s
end

-- Count keys present.
local function key_count(result)
    return #result
end

-- Serialize a result to a stable string for determinism comparison. Iterates
-- only dense arrays / declared fields — never pairs() over items.
local function serialize(result)
    local parts = {}
    for i = 1, #result do
        local cat = result[i]
        parts[#parts + 1] = cat.key .. ":" .. cat.title
        for j = 1, #cat.items do
            local it = cat.items[j]
            local root = it.chord and it.chord.root or -1
            local typ = it.chord and it.chord.type or "-"
            local bass = (it.chord and it.chord.bass) or -1
            parts[#parts + 1] = "  " .. it.label .. "|" .. it.detail
                .. "|" .. string.format("%d/%s/%d", root, typ, bass)
        end
    end
    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

local tests = {}

-- 1. No chord and no next → only diatonic + borrowed (both key-only categories).
tests[#tests + 1] = { name = "no chord no next → diatonic + borrowed only", fn = function()
    local r = Suggest.For{ chord = nil, key = C_MAJOR }
    local ks = key_set(r)
    T.assert_true(ks.diatonic, "diatonic must be present")
    T.assert_true(ks.borrowed, "borrowed must be present")
    T.assert_true(not ks["function"], "function needs a chord — must be absent")
    T.assert_true(not ks.subs, "subs needs a chord — must be absent")
    T.assert_true(not ks.negative, "negative needs a chord — must be absent")
    T.assert_true(not ks.passing, "passing needs next — must be absent")
    T.assert_true(not ks.exotic, "exotic needs a chord — must be absent")
    T.assert_eq(key_count(r), 2, "exactly two categories")
end }

-- 2. Chord present, no next → all categories except passing.
tests[#tests + 1] = { name = "chord without next → no passing", fn = function()
    local r = Suggest.For{ chord = { root = 7, type = "7" }, key = C_MAJOR }
    local ks = key_set(r)
    T.assert_true(ks.diatonic, "diatonic present")
    T.assert_true(ks["function"], "function present")
    T.assert_true(ks.subs, "subs present")
    T.assert_true(ks.borrowed, "borrowed present")
    T.assert_true(ks.negative, "negative present")
    T.assert_true(ks.exotic, "exotic present")
    T.assert_true(not ks.passing, "passing must be absent without next")
end }

-- 3. Full context → all seven categories present.
tests[#tests + 1] = { name = "full ctx → all seven categories", fn = function()
    local r = Suggest.For{
        chord = { root = 7, type = "7" }, key = C_MAJOR,
        prev = { root = 2, type = "m7" }, next = { root = 0, type = "maj7" },
    }
    local ks = key_set(r)
    for _, k in ipairs({ "diatonic", "function", "subs", "borrowed",
                          "negative", "passing", "exotic" }) do
        T.assert_true(ks[k], "category " .. k .. " must be present")
    end
    T.assert_eq(key_count(r), 7, "exactly seven categories")
end }

-- 4. Fixed category order in the returned array.
tests[#tests + 1] = { name = "categories returned in fixed order", fn = function()
    local r = Suggest.For{
        chord = { root = 7, type = "7" }, key = C_MAJOR,
        next = { root = 0, type = "maj7" },
    }
    local expect = { "diatonic", "function", "subs", "borrowed",
                     "negative", "passing", "exotic" }
    T.assert_eq(#r, #expect, "seven categories")
    for i = 1, #expect do
        T.assert_eq(r[i].key, expect[i], "order at index " .. i)
    end
end }

-- 5. No item equals the current chord (dedupe against ctx.chord).
tests[#tests + 1] = { name = "no item equals ctx.chord", fn = function()
    local cur = { root = 7, type = "7" }
    local r = Suggest.For{
        chord = cur, key = C_MAJOR, next = { root = 0, type = "maj7" },
    }
    for i = 1, #r do
        local cat = r[i]
        for j = 1, #cat.items do
            T.assert_true(not Theory.ChordEquals(cat.items[j].chord, cur),
                "item " .. cat.items[j].label .. " in " .. cat.key
                .. " equals the current chord")
        end
    end
end }

-- 6. No duplicate labels within any single category.
tests[#tests + 1] = { name = "no duplicate labels within a category", fn = function()
    local r = Suggest.For{
        chord = { root = 7, type = "7" }, key = C_MAJOR,
        next = { root = 0, type = "maj7" }, flats = true,
    }
    for i = 1, #r do
        local cat = r[i]
        local seen = {}
        for j = 1, #cat.items do
            local lbl = cat.items[j].label
            T.assert_true(not seen[lbl],
                "duplicate label '" .. lbl .. "' in category " .. cat.key)
            seen[lbl] = true
        end
    end
end }

-- 7. Every item is well-formed: chord table, non-empty label, non-empty detail.
tests[#tests + 1] = { name = "every item is {chord,label,detail} well-formed", fn = function()
    local r = Suggest.For{
        chord = { root = 7, type = "7" }, key = C_MAJOR,
        next = { root = 0, type = "maj7" },
    }
    for i = 1, #r do
        local cat = r[i]
        T.assert_true(type(cat.title) == "string" and #cat.title > 0,
            "category " .. cat.key .. " has a title")
        T.assert_true(#cat.items > 0, "category " .. cat.key .. " is non-empty")
        for j = 1, #cat.items do
            local it = cat.items[j]
            T.assert_true(type(it.chord) == "table", "item has a chord table")
            T.assert_true(type(it.chord.root) == "number", "chord.root is a pc")
            T.assert_true(type(it.chord.type) == "string", "chord.type is a name")
            T.assert_true(type(it.label) == "string" and #it.label > 0,
                "item has a non-empty label")
            T.assert_true(type(it.detail) == "string" and #it.detail > 0,
                "item has a non-empty detail")
            -- label must match Theory.ChordName exactly under the ctx's flats
            -- setting (this ctx uses sharps → flats = nil/false).
            T.assert_eq(it.label, Theory.ChordName(it.chord, false),
                "label equals Theory.ChordName for the item chord (sharps)")
        end
    end
end }

-- 8. Determinism: two identical calls yield structurally identical results.
tests[#tests + 1] = { name = "determinism: identical calls → identical structure", fn = function()
    local function ctx()
        return { chord = { root = 7, type = "7" }, key = C_MAJOR,
                 prev = { root = 2, type = "m7" }, next = { root = 0, type = "maj7" },
                 flats = true }
    end
    local a = serialize(Suggest.For(ctx()))
    local b = serialize(Suggest.For(ctx()))
    T.assert_eq(a, b, "two identical calls must serialize identically")
end }

-- 9. Diatonic category lists the 7 key sevenths (minus any equal to ctx.chord).
tests[#tests + 1] = { name = "diatonic content in C major (chord=G7)", fn = function()
    local r = Suggest.For{ chord = { root = 7, type = "7" }, key = C_MAJOR, flats = true }
    local dia = cat_of(r, "diatonic")
    T.assert_true(dia ~= nil, "diatonic present")
    -- G7 is diatonic V7 → deduped against the current chord: 6 remain.
    T.assert_eq(#dia.items, 6, "six diatonic items after removing the current G7")
    T.assert_true(has_label(dia, "Cmaj7"), "Cmaj7 present")
    T.assert_true(has_label(dia, "Dm7"), "Dm7 present")
    T.assert_true(has_label(dia, "Am7"), "Am7 present")
    T.assert_true(not has_label(dia, "G7"), "G7 removed (equals current chord)")
end }

-- 10. Subs contains the tritone sub Db7 in C major with chord = G7.
tests[#tests + 1] = { name = "subs contains Db7 tritone sub of G7", fn = function()
    local r = Suggest.For{ chord = { root = 7, type = "7" }, key = C_MAJOR, flats = true }
    local subs = cat_of(r, "subs")
    T.assert_true(subs ~= nil, "subs present")
    T.assert_true(has_label(subs, "Db7"), "Db7 tritone sub present")
    local d = detail_of(subs, "Db7")
    T.assert_true(d ~= nil and d:find("triton") ~= nil,
        "Db7 detail mentions the tritone substitution")
end }

-- 11. Negative harmony of C (major triad) in C major yields Cm.
tests[#tests + 1] = { name = "negative of C in C major contains Cm", fn = function()
    local r = Suggest.For{ chord = { root = 0, type = "maj" }, key = C_MAJOR, flats = true }
    local neg = cat_of(r, "negative")
    T.assert_true(neg ~= nil, "negative present")
    T.assert_true(has_label(neg, "Cm"), "Cm (negative mirror of C) present")
end }

-- 12. Passing toward F contains C7 labelled as V7/IV secondary dominant.
tests[#tests + 1] = { name = "passing toward F contains C7 as V7/IV", fn = function()
    local r = Suggest.For{
        chord = { root = 0, type = "maj7" }, key = C_MAJOR,
        next = { root = 5, type = "maj" }, flats = true,
    }
    local pass = cat_of(r, "passing")
    T.assert_true(pass ~= nil, "passing present")
    T.assert_true(has_label(pass, "C7"), "C7 (V7/IV) present")
    local d = detail_of(pass, "C7")
    T.assert_true(d ~= nil and d:find("V7/IV") ~= nil,
        "C7 detail names it V7/IV: got " .. tostring(d))
end }

-- 13. Passing depends on next, not on chord: chord=nil but next present → passing
--     appears (diatonic + borrowed + passing).
tests[#tests + 1] = { name = "passing appears with next even when chord is nil", fn = function()
    local r = Suggest.For{ chord = nil, key = C_MAJOR, next = { root = 5, type = "maj" } }
    local ks = key_set(r)
    T.assert_true(ks.diatonic, "diatonic present")
    T.assert_true(ks.borrowed, "borrowed present")
    T.assert_true(ks.passing, "passing present (needs only next)")
    T.assert_true(not ks["function"], "function still absent (no chord)")
    T.assert_true(not ks.subs, "subs still absent (no chord)")
    T.assert_true(not ks.negative, "negative still absent (no chord)")
    T.assert_true(not ks.exotic, "exotic still absent (no chord)")
end }

-- 14. Borrowed chords differ from the diatonic set of the key (contract:
--     "only those differing from diatonic set").
tests[#tests + 1] = { name = "borrowed items are non-diatonic", fn = function()
    local r = Suggest.For{ chord = { root = 0, type = "maj" }, key = C_MAJOR, flats = true }
    local borrowed = cat_of(r, "borrowed")
    T.assert_true(borrowed ~= nil, "borrowed present")
    -- Build the diatonic label set of C major.
    local dia = Theory.DiatonicChords(C_MAJOR, true)
    local dia_labels = {}
    for i = 1, #dia do dia_labels[Theory.ChordName(dia[i].chord, true)] = true end
    for i = 1, #borrowed.items do
        local lbl = borrowed.items[i].label
        T.assert_true(not dia_labels[lbl],
            "borrowed item '" .. lbl .. "' must not be in the diatonic set")
    end
end }

-- 15. Exotic: for a dominant 7th current chord, 7alt is offered and a quartal
--     recolor on the current root exists.
tests[#tests + 1] = { name = "exotic offers 7alt and quartal for a dominant", fn = function()
    local r = Suggest.For{ chord = { root = 7, type = "7" }, key = C_MAJOR, flats = true }
    local ex = cat_of(r, "exotic")
    T.assert_true(ex ~= nil, "exotic present")
    T.assert_true(has_label(ex, "G7alt"), "7alt recolor present for a dominant")
    -- Quartal label uses the '4ths' type label.
    T.assert_true(has_label(ex, "G4ths"), "quartal recolor on the current root present")
end }

-- 16. Function category uses the transition-table row for the current degree.
--     Current I (Cmaj7) in C major → targets {IV,V,vi,ii} = {Fmaj7,G7,Am7,Dm7}.
tests[#tests + 1] = { name = "function targets follow the degree table for I", fn = function()
    local r = Suggest.For{ chord = { root = 0, type = "maj7" }, key = C_MAJOR, flats = true }
    local fn = cat_of(r, "function")
    T.assert_true(fn ~= nil, "function present")
    for _, lbl in ipairs({ "Fmaj7", "G7", "Am7", "Dm7" }) do
        T.assert_true(has_label(fn, lbl),
            "I should resolve to include " .. lbl)
    end
    -- Cmaj7 itself (the current chord) must be deduped out.
    T.assert_true(not has_label(fn, "Cmaj7"), "current chord not repeated in function")
end }

-- 17. Non-diatonic current chord uses the nearest diatonic degree's row without
--     erroring, and still produces a non-empty function category.
tests[#tests + 1] = { name = "non-diatonic chord maps to nearest degree row", fn = function()
    -- Ab7 root pc 8: nearest C-major scale degrees are G(7) and A(9), tie → G (deg 5).
    local r = Suggest.For{ chord = { root = 8, type = "7" }, key = C_MAJOR, flats = true }
    local fn = cat_of(r, "function")
    T.assert_true(fn ~= nil and #fn.items > 0,
        "function category non-empty for a non-diatonic chord")
end }

-- 18. Minor key context works and diatonic uses the minor scale.
tests[#tests + 1] = { name = "minor key diatonic uses the minor scale", fn = function()
    local key = { tonic = 9, mode = "minor" } -- A minor
    local r = Suggest.For{ chord = nil, key = key, flats = false }
    local dia = cat_of(r, "diatonic")
    T.assert_true(dia ~= nil, "diatonic present in minor")
    -- A natural minor sevenths: Am7 Bm7b5 Cmaj7 Dm7 Em7 Fmaj7 G7.
    T.assert_true(has_label(dia, "Am7"), "i7 = Am7 present")
    T.assert_true(has_label(dia, "Cmaj7"), "III = Cmaj7 present")
    T.assert_true(has_label(dia, "G7"), "VII7 = G7 present")
end }

return tests
