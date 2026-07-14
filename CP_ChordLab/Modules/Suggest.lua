-- @description CP ChordLab — chord suggestion engine (categories of related chords)
-- @author Cedric Pamalio

-- PURE module: no reaper.*, gfx.*, os.*, io.*. Lua 5.3.
-- Suggest.For(ctx) returns a fixed-order array of categories, each a small list
-- of related chords with a French explanatory detail. Only Theory is required;
-- Voicing is reserved for future voiced previews and may be nil.
--
-- Determinism is a hard requirement: categories are built in a fixed literal
-- order, every item list is produced by iterating dense arrays or explicit
-- sorted degree indices — never pairs() iteration order. Dedupe is by the
-- rendered label string (stable), against ctx.chord and within each category.

local M = {}

local Theory  -- injected
local Voicing -- injected (may be nil; not required)

function M.Init(theory, voicing)
    Theory = theory
    Voicing = voicing
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Fixed category order and French titles. Presence is decided per-category at
-- build time; a category that ends up empty is omitted entirely (never returned
-- with an empty items array).
local CATEGORY_ORDER = {
    { key = "diatonic", title = "Diatonique" },
    { key = "function", title = "Suite logique" },
    { key = "subs",     title = "Substitutions" },
    { key = "borrowed", title = "Emprunts modaux" },
    { key = "negative", title = "Harmonie négative" },
    { key = "passing",  title = "Passage" },
    { key = "exotic",   title = "Exotique" },
}

-- Data-driven roman-degree transition tables (1-based degree index → list of
-- target degree indices). The minor table mirrors major functional motion onto
-- the natural-minor degrees; both are indexed by degree number so the same
-- builder realizes the concrete chords via Theory.DiatonicChords per mode.
-- Major:  I→{IV,V,vi,ii}, ii→{V,vii°}, iii→{vi,IV}, IV→{V,I,ii},
--         V→{I,vi}, vi→{ii,IV,V}, vii°→{I}
local FUNCTION_MAJOR = {
    [1] = { 4, 5, 6, 2 },
    [2] = { 5, 7 },
    [3] = { 6, 4 },
    [4] = { 5, 1, 2 },
    [5] = { 1, 6 },
    [6] = { 2, 4, 5 },
    [7] = { 1 },
}
-- Minor (mirrored): i→{iv,v,VI,ii°}, ii°→{v,VII}, III→{VI,iv}, iv→{v,i,ii°},
--         v→{i,VI}, VI→{ii°,iv,v}, VII→{i}. Same degree-index structure.
local FUNCTION_MINOR = {
    [1] = { 4, 5, 6, 2 },
    [2] = { 5, 7 },
    [3] = { 6, 4 },
    [4] = { 5, 1, 2 },
    [5] = { 1, 6 },
    [6] = { 2, 4, 5 },
    [7] = { 1 },
}

-- Circular pitch-class distance (0..6).
local function pc_dist(a, b)
    local d = (a - b) % 12
    if d > 6 then d = 12 - d end
    return d
end

-- Nearest diatonic scale degree (1-based) to a pitch class, ties resolved to the
-- lower degree index for determinism.
local function nearest_degree(scale, pc)
    local best_i, best_d = 1, 13
    for i = 1, #scale do
        local d = pc_dist(scale[i], pc)
        if d < best_d then
            best_d = d
            best_i = i
        end
    end
    return best_i
end

-- French ordinal-ish degree word set for roman-numeral captions.
local FUNCTION_ROLE = {
    "tonique", "sous-dominante", "médiante", "sous-dominante",
    "dominante", "relatif mineur", "sensible",
}

-- ---------------------------------------------------------------------------
-- Category item collectors
-- Each returns a dense array of raw item candidates { chord, label, detail }.
-- The caller applies dedupe + skip-if-empty uniformly.
-- ---------------------------------------------------------------------------

-- diatonic — 7 sevenths of the key with roman-numeral details.
local function build_diatonic(ctx)
    local dia = Theory.DiatonicChords(ctx.key, true)
    local items = {}
    for i = 1, #dia do
        local entry = dia[i]
        local role = FUNCTION_ROLE[i] or "degré diatonique"
        items[i] = {
            chord = entry.chord,
            label = Theory.ChordName(entry.chord, ctx.flats),
            detail = entry.roman .. " — " .. role,
        }
    end
    return items
end

-- function — data-driven transition table on the current chord's diatonic degree
-- (nearest diatonic root's row when the current chord is non-diatonic).
local function build_function(ctx)
    if not ctx.chord then return {} end
    local scale = Theory.Scale(ctx.key)
    local degree = nearest_degree(scale, ctx.chord.root % 12)
    local table_by_mode = (ctx.key.mode == "minor") and FUNCTION_MINOR or FUNCTION_MAJOR
    local targets = table_by_mode[degree] or {}
    local dia = Theory.DiatonicChords(ctx.key, true)
    local items = {}
    for i = 1, #targets do
        local tdeg = targets[i]
        local entry = dia[tdeg]
        if entry then
            items[#items + 1] = {
                chord = entry.chord,
                label = Theory.ChordName(entry.chord, ctx.flats),
                detail = entry.roman .. " — enchaînement naturel",
            }
        end
    end
    return items
end

-- subs — tritone sub, relative, parallel, 4 chromatic mediants, backdoor
-- dominant (bVII7), Neapolitan (bII maj).
local function build_subs(ctx)
    if not ctx.chord then return {} end
    local c = ctx.chord
    local items = {}
    local function add(chord, detail)
        if chord then
            items[#items + 1] = {
                chord = chord,
                label = Theory.ChordName(chord, ctx.flats),
                detail = detail,
            }
        end
    end

    add(Theory.TritoneSub(c), "substitution tritonique (bII7)")
    add(Theory.RelativeOf(c), "relatif — même fonction")
    add(Theory.ParallelOf(c), "parallèle — couleur inverse")

    local meds = Theory.ChromaticMediants(c)
    local med_detail = { "médiante chromatique (+3M)", "médiante chromatique (+3m)",
        "médiante chromatique (-3m)", "médiante chromatique (-3M)" }
    for i = 1, #meds do
        add(meds[i], med_detail[i] or "médiante chromatique")
    end

    -- Backdoor dominant: bVII7 relative to the current chord root.
    add({ root = (c.root + 10) % 12, type = "7", bass = nil },
        "dominante backdoor (bVII7)")
    -- Neapolitan: bII major relative to the current chord root.
    add({ root = (c.root + 1) % 12, type = "maj", bass = nil },
        "napolitaine (bII)")

    return items
end

-- borrowed — same-degree chords from parallel modes that differ from the
-- diatonic set of the current key.
local BORROW_MODES = {
    { mode = "minor",          label = "mineur parallèle" },
    { mode = "dorian",         label = "dorien" },
    { mode = "phrygian",       label = "phrygien" },
    { mode = "lydian",         label = "lydien" },
    { mode = "mixolydian",     label = "mixolydien" },
    { mode = "harmonic_minor", label = "mineur harmonique" },
    { mode = "melodic_minor",  label = "mineur mélodique" },
    { mode = "major",          label = "majeur parallèle" },
}

local function build_borrowed(ctx)
    local tonic = ctx.key.tonic
    local base = Theory.DiatonicChords(ctx.key, true)
    -- Set of diatonic labels of the current key, to reject non-borrowed matches.
    local base_labels = {}
    for i = 1, #base do
        base_labels[Theory.ChordName(base[i].chord, ctx.flats)] = true
    end
    local items = {}
    -- Iterate modes in fixed order, degrees 1..7 in order → deterministic.
    for m = 1, #BORROW_MODES do
        local spec = BORROW_MODES[m]
        -- Skip the current key's own mode (nothing to borrow from itself).
        if spec.mode ~= ctx.key.mode then
            local dia = Theory.DiatonicChords({ tonic = tonic, mode = spec.mode }, true)
            for deg = 1, #dia do
                local chord = dia[deg].chord
                local label = Theory.ChordName(chord, ctx.flats)
                if not base_labels[label] then
                    items[#items + 1] = {
                        chord = chord,
                        label = label,
                        detail = dia[deg].roman .. " emprunté au " .. spec.label,
                    }
                end
            end
        end
    end
    return items
end

-- negative — NegativeMirror of the current chord + of the next (if any).
local function build_negative(ctx)
    if not ctx.chord then return {} end
    local items = {}
    local mc = Theory.NegativeMirror(ctx.chord, ctx.key)
    if mc then
        items[#items + 1] = {
            chord = mc,
            label = Theory.ChordName(mc, ctx.flats),
            detail = "miroir négatif de l'accord courant",
        }
    end
    if ctx.next then
        local mn = Theory.NegativeMirror(ctx.next, ctx.key)
        if mn then
            items[#items + 1] = {
                chord = mn,
                label = Theory.ChordName(mn, ctx.flats),
                detail = "miroir négatif de l'accord suivant",
            }
        end
    end
    return items
end

-- passing — approach chords toward ctx.next: secondary dominant V7/next,
-- ii7 of next ("two-five into"), dim7 a half-step below next root, chromatic
-- approach (next type, root ±1 semitone).
local function build_passing(ctx)
    if not ctx.next then return {} end
    local nx = ctx.next
    local items = {}
    local function add(chord, detail)
        items[#items + 1] = {
            chord = chord,
            label = Theory.ChordName(chord, ctx.flats),
            detail = detail,
        }
    end

    -- Secondary dominant V7/next. Detail names the degree of next in the key.
    local sec = Theory.SecondaryDominant(nx)
    local next_roman = Theory.RomanNumeral(nx, ctx.key)
    local vlabel = (next_roman ~= "?") and ("V7/" .. next_roman) or "V7/x"
    add(sec, vlabel .. " — dominante secondaire")

    -- ii7 of next: root a whole tone above V7/next root (= a 5th below next... the
    -- ii of the temporary key of next). ii = next.root + 2.
    add({ root = (nx.root + 2) % 12, type = "m7", bass = nil },
        "ii7 — préparation ii-V vers " .. Theory.ChordName(nx, ctx.flats))

    -- Diminished 7th a half-step below next root (leading-tone approach).
    add({ root = (nx.root - 1) % 12, type = "dim7", bass = nil },
        "dim7 chromatique sous " .. Theory.ChordName(nx, ctx.flats))

    -- Chromatic approach chords: same type as next, root ±1 semitone.
    add({ root = (nx.root - 1) % 12, type = nx.type, bass = nil },
        "approche chromatique par en-dessous")
    add({ root = (nx.root + 1) % 12, type = nx.type, bass = nil },
        "approche chromatique par au-dessus")

    return items
end

-- exotic — quartal on current root, sus4/sus2 recolor, upper-structure triads
-- (maj triad on b6 / on 2 over current bass as slash chords), hexatonic pole,
-- 7alt when current is dominant.
local function build_exotic(ctx)
    if not ctx.chord then return {} end
    local c = ctx.chord
    local items = {}
    local function add(chord, detail)
        items[#items + 1] = {
            chord = chord,
            label = Theory.ChordName(chord, ctx.flats),
            detail = detail,
        }
    end

    add({ root = c.root, type = "quartal", bass = nil }, "quartal — empilement de 4tes")
    add({ root = c.root, type = "sus4", bass = nil }, "recoloration sus4")
    add({ root = c.root, type = "sus2", bass = nil }, "recoloration sus2")

    -- Upper-structure triads over the current bass (slash chords): a major triad
    -- rooted a minor sixth up (b6) and one a whole tone up (2).
    add({ root = (c.root + 8) % 12, type = "maj", bass = c.root },
        "structure supérieure majeure sur b6")
    add({ root = (c.root + 2) % 12, type = "maj", bass = c.root },
        "structure supérieure majeure sur 2")

    -- Hexatonic pole (P): opposite quality, shares ZERO common tones with the
    -- source. A major chord's pole is the minor chord a major third BELOW
    -- (root-4); a minor chord's pole is the major chord a major third ABOVE
    -- (root+4). e.g. C major -> Ab minor, C minor -> E major.
    local t = Theory.TYPE_BY_NAME[c.type]
    local is_min = t and t.set[3] == true and t.set[4] ~= true
    if is_min then
        add({ root = (c.root + 4) % 12, type = "maj", bass = nil },
            "pôle hexatonique (majeur)")
    else
        add({ root = (c.root - 4) % 12, type = "min", bass = nil },
            "pôle hexatonique (mineur)")
    end

    -- 7alt when the current chord is a dominant seventh (major 3rd + minor 7th).
    if t and t.set[4] == true and t.set[10] == true then
        add({ root = c.root, type = "7alt", bass = nil }, "dominante altérée (7alt)")
    end

    return items
end

-- ---------------------------------------------------------------------------
-- Assembly
-- ---------------------------------------------------------------------------

local BUILDERS = {
    diatonic = build_diatonic,
    ["function"] = build_function,
    subs = build_subs,
    borrowed = build_borrowed,
    negative = build_negative,
    passing = build_passing,
    exotic = build_exotic,
}

-- Dedupe a raw item list by rendered label, dropping anything equal to the
-- current chord. Preserves first-seen order (input order is already
-- deterministic). Returns a fresh dense array.
local function finalize_items(raw, ctx)
    local seen = {}
    local cur_label = ctx.chord and Theory.ChordName(ctx.chord, ctx.flats) or nil
    local out = {}
    for i = 1, #raw do
        local it = raw[i]
        local lbl = it.label
        -- Reject items identical to the current chord, and by structural equality
        -- (root/type/bass) in case naming differs from the current chord's render.
        local same_as_current = false
        if ctx.chord then
            if cur_label ~= nil and lbl == cur_label then
                same_as_current = true
            elseif Theory.ChordEquals(it.chord, ctx.chord) then
                same_as_current = true
            end
        end
        if not same_as_current and not seen[lbl] then
            seen[lbl] = true
            out[#out + 1] = it
        end
    end
    return out
end

function M.For(ctx)
    ctx = ctx or {}
    -- A key is always required to build diatonic/borrowed material; default to C
    -- major so the engine never errors on a partial context.
    if not ctx.key then ctx.key = { tonic = 0, mode = "major" } end

    local out = {}
    for i = 1, #CATEGORY_ORDER do
        local spec = CATEGORY_ORDER[i]
        local builder = BUILDERS[spec.key]
        local raw = builder(ctx)
        local items = finalize_items(raw, ctx)
        if #items > 0 then
            out[#out + 1] = { key = spec.key, title = spec.title, items = items }
        end
    end
    return out
end

return M
