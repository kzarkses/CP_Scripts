-- @description CP ChordLab — voicing, voice-leading and rhythm-preserving note remapping
-- @author Cedric Pamalio

-- PURE module: no reaper.*, gfx.*, os.*, io.*. Lua 5.3.
-- Pitches are MIDI 0..127 (60 = C4). Pitch classes are integers 0..11 (0 = C).
-- Determinism is a hard requirement: every routine that feeds returned ordering
-- iterates dense arrays or sorted key lists — never pairs() order. Ties in the
-- optimizers resolve by a fixed rule (documented at each site) so the same
-- input always yields the same output.

local M = {}

local Theory  -- injected via Init

function M.Init(theory)
    Theory = theory
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- Circular pitch-class distance, folded into 0..6.
local function pc_dist(a, b)
    local d = (a - b) % 12
    if d < 0 then d = d + 12 end
    if d > 6 then d = 12 - d end
    return d
end

-- Distinct pcs of a chord, ordered root-first then third then the remaining
-- chord tones in interval order. The root/third-first ordering drives the
-- "cover root+third first" priority in MapNotes; it is not musical spelling.
local function chord_pcs_prioritized(chord)
    local raw = Theory.ChordPcs(chord)          -- (root+iv)%12 in interval order
    local t = Theory.TYPE_BY_NAME[chord.type]
    local intervals = t and t.intervals or nil

    -- Locate the third (interval 3 or 4) and root (interval 0) positions.
    local root_i, third_i = nil, nil
    if intervals then
        for i = 1, #intervals do
            local iv = intervals[i] % 12
            if iv == 0 and not root_i then root_i = i end
            if (iv == 3 or iv == 4) and not third_i then third_i = i end
        end
    end
    if not root_i then root_i = 1 end

    local order = {}
    local seen = {}
    local function push(i)
        if not i then return end
        local pc = raw[i]
        if pc ~= nil and not seen[pc] then
            seen[pc] = true
            order[#order + 1] = pc
        end
    end
    push(root_i)
    push(third_i)
    for i = 1, #raw do push(i) end
    return order
end

-- Distinct sorted pitches from an input list (deterministic, dense output).
local function distinct_sorted_pitches(pitches)
    local seen = {}
    local out = {}
    for i = 1, #pitches do
        local p = math.floor(pitches[i] + 0.5)
        if not seen[p] then
            seen[p] = true
            out[#out + 1] = p
        end
    end
    table.sort(out)
    return out
end

-- Place pitch-class `pc` at the octave nearest to `ref` (MIDI). Ties (equidistant
-- above/below) resolve DOWNWARD, per contract. Result clamped to 0..127.
local function place_near(pc, ref)
    ref = math.floor(ref + 0.5)
    local base = pc % 12
    -- Candidate octave whose note is <= ref, and the one above.
    local lower = base + 12 * ((ref - base) // 12)
    while lower > ref do lower = lower - 12 end
    while lower + 12 <= ref do lower = lower + 12 end
    local upper = lower + 12
    local dl = ref - lower
    local du = upper - ref
    local chosen
    if du < dl then chosen = upper else chosen = lower end  -- tie (du==dl) → lower
    if chosen < 0 then chosen = chosen + 12 * ((-chosen) // 12 + 1) end
    while chosen > 127 do chosen = chosen - 12 end
    while chosen < 0 do chosen = chosen + 12 end
    return chosen
end

-- ---------------------------------------------------------------------------
-- Spell — realize an abstract chord as sorted MIDI pitches
-- ---------------------------------------------------------------------------
-- opts = { register = 48 (lowest-note target), inversion = 0, spread = "close"|"open" }
-- Root position stacks the chord tones ascending from the first tone at or above
-- `register`. Inversion rotates the low tones up an octave. "open" drops the
-- 2nd-highest voice one octave (drop-2) when there are >=4 tones. When
-- chord.bass is set and differs from the tones, it is placed as the lowest note.

function M.Spell(chord, opts)
    opts = opts or {}
    local register = opts.register or 48
    local inversion = opts.inversion or 0
    local spread = opts.spread or "close"

    local pcs = Theory.ChordPcs(chord)  -- interval order, distinct
    local n = #pcs
    if n == 0 then return {} end

    -- Rotate the pc list by `inversion` (each rotation lifts former bottom tones).
    inversion = inversion % n
    local order = {}
    for i = 1, n do
        order[i] = pcs[((i - 1 + inversion) % n) + 1]
    end

    -- Stack ascending: first tone at the lowest octave >= register, each next
    -- tone the next pc strictly above the previous pitch.
    local pitches = {}
    local first = place_near(order[1], register)
    if first < register then first = first + 12 end
    pitches[1] = first
    for i = 2, n do
        local prev = pitches[i - 1]
        local p = order[i] % 12
        -- smallest pitch of pc p that is strictly greater than prev
        local up = p + 12 * ((prev - p) // 12)
        while up <= prev do up = up + 12 end
        pitches[i] = up
    end

    -- Open voicing (drop-2): drop the 2nd-highest voice down an octave.
    if spread == "open" and n >= 4 then
        local idx = n - 1
        pitches[idx] = pitches[idx] - 12
    end

    -- Bass note: always the lowest sounding pitch when chord.bass is set and is
    -- distinct from the current bass pc.
    if chord.bass ~= nil then
        local bass_pc = chord.bass % 12
        local lowest = pitches[1]
        for i = 2, #pitches do if pitches[i] < lowest then lowest = pitches[i] end end
        if lowest % 12 ~= bass_pc then
            -- Place the bass just below the current lowest tone.
            local b = bass_pc + 12 * ((lowest - bass_pc) // 12)
            while b >= lowest do b = b - 12 end
            pitches[#pitches + 1] = b
        end
    end

    table.sort(pitches)

    -- Keep the whole voicing inside 0..127. Shift by octaves first (preserves
    -- the voicing's internal intervals), then clamp any residual outliers a wide
    -- chord can leave behind at the extremes.
    while pitches[#pitches] > 127 do
        for i = 1, #pitches do pitches[i] = pitches[i] - 12 end
    end
    while pitches[1] < 0 do
        for i = 1, #pitches do pitches[i] = pitches[i] + 12 end
    end
    for i = 1, #pitches do
        if pitches[i] > 127 then pitches[i] = pitches[i] - 12 end
        if pitches[i] < 0 then pitches[i] = pitches[i] + 12 end
    end

    return pitches
end

-- ---------------------------------------------------------------------------
-- Inversions — one voicing per rotation of the chord tones
-- ---------------------------------------------------------------------------

local INVERSION_LABELS = { "root", "1st", "2nd", "3rd", "4th", "5th", "6th" }

function M.Inversions(chord, register)
    register = register or 48
    local pcs = Theory.ChordPcs(chord)
    local n = #pcs
    local out = {}
    for inv = 0, n - 1 do
        out[#out + 1] = {
            pitches = M.Spell(chord, { register = register, inversion = inv }),
            label = INVERSION_LABELS[inv + 1] or (tostring(inv) .. "th"),
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- LeadFrom — voice-lead the chord from a previous voicing
-- ---------------------------------------------------------------------------
-- Enumerate candidate voicings of `chord` (each inversion × a small window of
-- octave shifts, all with the same cardinality as the chord tones) and pick the
-- one minimizing total |semitone| movement against prev_pitches. Greedy
-- nearest-pair pairing per candidate (deterministic). nil/empty prev → Spell.

-- Total movement of pairing `cand` (sorted) against `prev` (sorted), greedy
-- nearest-pair by the smaller list, each target usable once. Deterministic:
-- both lists are sorted ascending and consumed in order with nearest search.
local function pairing_cost(prev, cand)
    -- Greedy: for each prev pitch (ascending), take the nearest unused cand.
    local used = {}
    local total = 0
    for i = 1, #prev do
        local best_j, best_d = nil, nil
        for j = 1, #cand do
            if not used[j] then
                local d = math.abs(prev[i] - cand[j])
                if best_d == nil or d < best_d then
                    best_d = d; best_j = j
                elseif d == best_d and j < best_j then
                    best_j = j  -- lower index tiebreak (deterministic)
                end
            end
        end
        if best_j then
            used[best_j] = true
            total = total + best_d
        else
            -- more prev voices than cand voices: charge distance to nearest cand
            local nd = nil
            for j = 1, #cand do
                local d = math.abs(prev[i] - cand[j])
                if nd == nil or d < nd then nd = d end
            end
            total = total + (nd or 0)
        end
    end
    -- Also account for any cand voice not covered (movement into a new voice),
    -- charging its distance to the nearest prev — keeps symmetric cardinalities
    -- honest when cand has more voices than prev.
    for j = 1, #cand do
        if not used[j] then
            local nd = nil
            for i = 1, #prev do
                local d = math.abs(cand[j] - prev[i])
                if nd == nil or d < nd then nd = d end
            end
            total = total + (nd or 0)
        end
    end
    return total
end

function M.LeadFrom(prev_pitches, chord, opts)
    opts = opts or {}
    if not prev_pitches or #prev_pitches == 0 then
        return M.Spell(chord, opts)
    end

    local pcs = Theory.ChordPcs(chord)
    local n = #pcs
    if n == 0 then return {} end

    -- Anchor the octave search around the previous voicing's average pitch.
    local sum = 0
    for i = 1, #prev_pitches do sum = sum + prev_pitches[i] end
    local center = math.floor(sum / #prev_pitches + 0.5)

    -- Candidate registers: a few octaves around the previous center. The bass
    -- constraint is preserved by Spell (chord.bass placed lowest); to keep
    -- cardinality equal to the chord tones for pure voice-leading, temporarily
    -- ignore an explicit slash bass here and lead the chord-tone voicing.
    local lead_chord = { root = chord.root, type = chord.type, bass = nil }

    local best_pitches, best_cost = nil, nil
    -- Octave shift window: center-24 .. center+12 in octave steps, so the search
    -- brackets the previous voicing generously without exploding.
    for octoff = -24, 12, 12 do
        local register = center + octoff
        for inv = 0, n - 1 do
            local cand = M.Spell(lead_chord, { register = register, inversion = inv, spread = opts.spread })
            local cost = pairing_cost(prev_pitches, cand)
            if best_cost == nil or cost < best_cost then
                best_cost = cost; best_pitches = cand
            elseif cost == best_cost then
                -- Deterministic tiebreak: prefer the voicing whose lowest note is
                -- closer to the previous lowest, then the lexicographically-lower
                -- pitch list.
                local plow = prev_pitches[1]
                for i = 2, #prev_pitches do if prev_pitches[i] < plow then plow = prev_pitches[i] end end
                local a_low = best_pitches[1]
                local b_low = cand[1]
                local da = math.abs(a_low - plow)
                local db = math.abs(b_low - plow)
                if db < da then
                    best_pitches = cand
                elseif db == da then
                    -- lexicographic compare of the two sorted lists
                    local swap = false
                    for i = 1, math.min(#cand, #best_pitches) do
                        if cand[i] ~= best_pitches[i] then
                            swap = cand[i] < best_pitches[i]; break
                        end
                    end
                    if swap then best_pitches = cand end
                end
            end
        end
    end

    return best_pitches or M.Spell(chord, opts)
end

-- ---------------------------------------------------------------------------
-- MapNotes — rhythm-preserving pitch remap for a chord swap
-- ---------------------------------------------------------------------------
-- Returns { [old_pitch] = new_pitch } for every DISTINCT old pitch. Preserves
-- the rhythm/onset structure: only pitches change. Algorithm (per contract):
--   1. distinct old pcs are matched one-to-one to new_chord pcs minimizing total
--      circular pc distance (branch-and-bound over the injective assignment).
--   2. old pcs left unmatched (passing / non-chord tones) move by the same
--      semitone delta as their NEAREST matched old pc (parallel motion).
--   3. each old PITCH moves to its mapped pc at the octave nearest the original
--      pitch (ties: downward).
-- Coverage: when old has >= new distinct pcs, every new pc is used at least once;
-- when old has fewer, root+third are covered first.

-- Optimal injective assignment between the smaller side (rows) and larger side
-- (cols), minimizing summed circular distance. Branch-and-bound over rows,
-- picking a distinct col per row. Returns row->col map (1-based) and the total.
-- `dist[r][c]` precomputed. Deterministic: rows iterated in order; among equal
-- total costs the first-found (lowest col indices) wins by the strict `<` test.
local function best_injective(dist, n_rows, n_cols)
    local best_map, best_cost = nil, nil
    local cur = {}
    local used = {}

    -- Lower bound for remaining rows: sum of each remaining row's min available
    -- distance (ignores the distinctness constraint — a valid admissible bound).
    local function lower_bound(r0, acc)
        local lb = acc
        for r = r0, n_rows do
            local m = nil
            for c = 1, n_cols do
                if not used[c] then
                    local d = dist[r][c]
                    if m == nil or d < m then m = d end
                end
            end
            lb = lb + (m or 0)
        end
        return lb
    end

    local function recurse(r, acc)
        if best_cost ~= nil and lower_bound(r, acc) >= best_cost then
            return  -- prune: cannot beat the incumbent
        end
        if r > n_rows then
            if best_cost == nil or acc < best_cost then
                best_cost = acc
                best_map = {}
                for i = 1, n_rows do best_map[i] = cur[i] end
            end
            return
        end
        for c = 1, n_cols do
            if not used[c] then
                used[c] = true
                cur[r] = c
                recurse(r + 1, acc + dist[r][c])
                used[c] = nil
                cur[r] = nil
            end
        end
    end

    recurse(1, 0)

    -- Callers always pass n_cols >= n_rows, so a complete injective assignment
    -- always exists and best_map is set. Guard anyway (a future caller could
    -- violate the precondition): fall back to a greedy nearest-column matching
    -- so MapNotes never nil-indexes the result.
    if not best_map then
        best_map = {}
        local used2 = {}
        for r = 1, n_rows do
            local bc, bd = nil, nil
            for c = 1, n_cols do
                if not used2[c] and (bd == nil or dist[r][c] < bd) then
                    bd = dist[r][c]; bc = c
                end
            end
            best_map[r] = bc or 1
            if bc then used2[bc] = true end
        end
    end

    return best_map, best_cost
end

function M.MapNotes(old_pitches, new_chord)
    local map = {}
    if not old_pitches or #old_pitches == 0 then return map end

    local old_p = distinct_sorted_pitches(old_pitches)

    -- Distinct old pcs, sorted (deterministic), with a representative pitch each.
    local old_pcs = {}
    local seen_pc = {}
    for i = 1, #old_p do
        local pc = old_p[i] % 12
        if not seen_pc[pc] then
            seen_pc[pc] = true
            old_pcs[#old_pcs + 1] = pc
        end
    end
    table.sort(old_pcs)

    local new_pcs = chord_pcs_prioritized(new_chord)  -- root, third, then rest
    if #new_pcs == 0 then
        -- Degenerate chord: identity map.
        for i = 1, #old_p do map[old_p[i]] = old_p[i] end
        return map
    end

    local n_old = #old_pcs
    local n_new = #new_pcs

    -- Build the injective matching between old pcs and new pcs. The matched
    -- delta for an old pc is the SIGNED nearest move to its assigned new pc.
    -- assigned_delta[old_pc] = signed semitone delta (folded to -6..+6).
    -- matched[old_pc] = true when that pc participates in the matching.
    local assigned_delta = {}
    local matched = {}

    -- Signed nearest delta from pc a to pc b, folded to (-6..6], ties → downward.
    local function signed_delta(a, b)
        local up = (b - a) % 12       -- 0..11 : move up
        local down = up - 12          -- -12..-1 : move down (or 0)
        -- pick the smaller magnitude; tie (up==6) → downward (-6)
        if up == 0 then return 0 end
        if math.abs(down) < up then return down
        elseif math.abs(down) > up then return up
        else return down end          -- |up|==|down| (up==6) → downward
    end

    if n_old >= n_new then
        -- Cover every new pc: rows = new pcs (n_new <= 7), cols = old pcs.
        local dist = {}
        for r = 1, n_new do
            dist[r] = {}
            for c = 1, n_old do
                dist[r][c] = pc_dist(new_pcs[r], old_pcs[c])
            end
        end
        local m = best_injective(dist, n_new, n_old)  -- new row -> old col
        for r = 1, n_new do
            local c = m[r]
            local opc = old_pcs[c]
            matched[opc] = true
            assigned_delta[opc] = signed_delta(opc, new_pcs[r])
        end
    else
        -- Fewer old pcs than chord tones: match every old pc to a distinct new
        -- pc, biased to cover root(index1)+third(index2) first. rows = old pcs.
        -- Coverage bias folded into the cost: subtract a large bonus when a row
        -- lands on the root/third column so the optimizer prefers those columns,
        -- but the bonus is dominated by nothing else (it only re-weights columns,
        -- never rows), keeping the assignment injective and deterministic.
        local COVER_BONUS = 100
        local dist = {}
        for r = 1, n_old do
            dist[r] = {}
            for c = 1, n_new do
                local base = pc_dist(old_pcs[r], new_pcs[c])
                -- Prefer covering root (col 1) most, then third (col 2).
                local bias = 0
                if c == 1 then bias = -2 * COVER_BONUS
                elseif c == 2 then bias = -COVER_BONUS end
                dist[r][c] = base + bias
            end
        end
        local m = best_injective(dist, n_old, n_new)  -- old row -> new col
        for r = 1, n_old do
            local c = m[r]
            local opc = old_pcs[r]
            matched[opc] = true
            assigned_delta[opc] = signed_delta(opc, new_pcs[c])
        end
    end

    -- Unmatched old pcs (passing tones): move by the delta of the nearest matched
    -- old pc (parallel motion). Nearest by circular pc distance; ties → the
    -- lower pc (deterministic, old_pcs is sorted).
    for i = 1, n_old do
        local pc = old_pcs[i]
        if not matched[pc] then
            local best_src, best_d = nil, nil
            for j = 1, n_old do
                local q = old_pcs[j]
                if matched[q] then
                    local d = pc_dist(pc, q)
                    if best_d == nil or d < best_d then
                        best_d = d; best_src = q
                    end
                    -- tie: keep the first (lowest pc) — no update needed
                end
            end
            if best_src ~= nil then
                assigned_delta[pc] = assigned_delta[best_src]
            else
                assigned_delta[pc] = 0  -- no matched pc at all (should not happen)
            end
        end
    end

    -- Build the final old_pitch -> new_pitch map. Each old pitch is displaced by
    -- its pc's assigned delta, then snapped to the nearest octave of the TARGET
    -- pc relative to the original pitch (ties downward) via place_near — this
    -- keeps every note near its original register and preserves contour where the
    -- pc moves allow.
    for i = 1, #old_p do
        local p = old_p[i]
        local pc = p % 12
        local delta = assigned_delta[pc] or 0
        local target_pc = (pc + delta) % 12
        map[p] = place_near(target_pc, p)
    end

    return map
end

return M
