-- CP_Engine — SrcTempo
--
-- HOW FAST IS THIS FILE. One answer, for the whole suite.
--
-- The question was answered in three places that did not agree (roadmap
-- phase 3), and the disagreement was audible: the browser auditioned a loop
-- at one rate, the session grid played the same file at another, and a
-- sampler pad tuned it to a third. All three were "right" — they simply
-- knew different things about the same file.
--
--   the browser   asked REAPER (GetTempoMatchPlayRate), then fell back to a
--                 BPM written in the filename. It believed "808 Kick
--                 120bpm.wav" was a loop and repitched a one-shot.
--   the grid      preferred the tempo stored on the clip, then delegated to
--                 the browser — so it inherited that same fault.
--   the sampler   had a stricter filename reader, a guard that a file must
--                 be long enough to BE a loop at the tempo it claims, and an
--                 inference from length alone — and never asked REAPER at
--                 all, so an embedded tempo was invisible to it.
--
-- This module is the union, with each source ranked by how much it deserves
-- to be believed, and every guard kept:
--
--   1. DECLARED   a tempo the user or the project decided. Not a guess: it
--                 wins outright, and no guard applies to it.
--   2. ANALYSED   REAPER's own answer, which reads an embedded tempo when
--                 the file carries one. Kept ahead of the filename because
--                 that is the order the browser already used and the browser
--                 is the window this behaviour was tuned in.
--   3. NAMED      the filename says so — believed, but only if the file is
--                 long enough to be at least two beats at that tempo. This
--                 is the sampler's guard and it is the one that stops a kick
--                 from being repitched by 30 %.
--   4. INFERRED   from the length alone, and only when it is UNAMBIGUOUS: a
--                 3 s file is "4 beats at 80" and "8 beats at 160" at once,
--                 so a guess that fits two bar counts is not a guess, it is
--                 a coin toss. Trusted only within two semitones as well,
--                 because a large correction means the inference picked the
--                 wrong bar count far more often than it means a 174 BPM
--                 break landed in a 120 BPM project — which the filename
--                 would have declared.
--
-- Every caller gets the same answer AND the same reason for it, which is
-- what lets a window say "128 BPM (from the name)" instead of showing a
-- number nobody can account for.

local SrcTempo = {}

local r = reaper

-- Injected: the module that owns the PCM_source cache, so asking for a
-- file's tempo never opens the disk twice. Optional — without it this falls
-- back to creating and destroying a source, which is correct and slower.
local Src = nil

function SrcTempo.init(reaper_api, source_provider)
    r = reaper_api or r
    Src = source_provider or Src
end

-- ---------------------------------------------------------------------------
-- Sources of an answer, weakest guard first
-- ---------------------------------------------------------------------------

local function getSource(path)
    if Src and Src.GetSource then return Src.GetSource(path), false end
    if not path or path == "" then return nil, false end
    return r.PCM_Source_CreateFromFile(path), true
end

-- Audio length in seconds, or nil for MIDI / unreadable.
function SrcTempo.Length(path)
    local src, owned = getSource(path)
    if not src then return nil end
    local len, isQN = r.GetMediaSourceLength(src)
    if owned then r.PCM_Source_Destroy(src) end
    if isQN or not len or len <= 0 then return nil end
    return len
end

-- The filename readers, merged. The sampler's form wants a separator before
-- the digits (so "Loop_128bpm" matches and "SP1200bpm" does not) and the
-- browser's accepts a decimal point. Both are tried, strictest first.
function SrcTempo.FromName(path)
    if not path then return nil end
    local name = path:match("([^/\\]+)$") or path
    local bpm = name:match("[%s_%-%(%[](%d%d%d?%.?%d*)%s*[bB][pP][mM]")
             or name:match("^(%d%d%d?%.?%d*)%s*[bB][pP][mM]")
    if not bpm then
        -- a bare number between separators, in a plausible loop-tempo range.
        -- Deliberately narrower than the bpm-suffixed forms: nothing marks
        -- this number as a tempo except that it could be one.
        for n in name:gmatch("[%s_%-](%d%d%d?)[%s_%-%.]") do
            local v = tonumber(n)
            if v and v >= 60 and v <= 200 then bpm = n break end
        end
    end
    local v = tonumber(bpm)
    if v and v >= 40 and v <= 300 then return v end
    return nil
end

-- REAPER's own tempo match — the routine the native Media Explorer uses. It
-- answers with a RATE, so the tempo it implies is the project's divided by
-- it. Guarded the way the browser always guarded it: a rate outside 0.05..20
-- is not a musical answer.
function SrcTempo.FromAnalysis(path)
    if not r.GetTempoMatchPlayRate then return nil end
    local src = getSource(path)
    if not src then return nil end
    local ok, retval, rate = pcall(r.GetTempoMatchPlayRate, src, 1.0, 0, 1.0)
    if not (ok and retval and rate and rate > 0.05 and rate < 20) then return nil end
    local pb = r.Master_GetTempo()
    if not pb or pb <= 0 then return nil end
    return pb / rate
end

-- From the length alone. Returns nil unless exactly one plausible bar count
-- lands near the project tempo — see the header on why ambiguity is not a
-- weaker answer but no answer at all.
function SrcTempo.FromLength(len)
    if not len or len < 1.2 then return nil end   -- a one-shot: no guess
    local ref = r.Master_GetTempo() or 120
    if ref <= 0 then ref = 120 end
    local lo, hi = ref / 1.5, ref * 1.5
    local best, n = nil, 0
    for _, beats in ipairs({ 4, 8, 16, 32 }) do
        local bpm = 60 * beats / len
        if bpm >= lo and bpm <= hi then n = n + 1; best = bpm end
    end
    if n ~= 1 then return nil end
    return best
end

-- ---------------------------------------------------------------------------
-- THE ANSWER
-- ---------------------------------------------------------------------------
-- Returns bpm, why — where `why` is "declared" | "analysed" | "named" |
-- "inferred", or nil, nil when nothing deserves belief. The reason is part of
-- the answer on purpose: a window that displays a tempo it cannot account for
-- is a window the user learns to distrust.
function SrcTempo.Bpm(path, declared)
    local d = tonumber(declared)
    if d and d > 0 then return d, "declared" end
    if not path or path == "" then return nil, nil end

    local a = SrcTempo.FromAnalysis(path)
    if a and a > 0 then return a, "analysed" end

    local len = SrcTempo.Length(path)

    local n = SrcTempo.FromName(path)
    if n then
        -- long enough to BE a loop at that tempo? Two beats is the floor: a
        -- kick named after the kit's tempo is not a bar of anything.
        if not len or len >= (60 / n) * 2 * 0.9 then return n, "named" end
    end

    local i = SrcTempo.FromLength(len)
    if i then
        local ref = r.Master_GetTempo()
        if ref and ref > 0 and math.abs(12 * math.log(ref / i, 2)) <= 2 then
            return i, "inferred"
        end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- The rate that puts this file at the project tempo.
--
-- opts: { declared = a stored bpm, mult = the ×0.5 / ×1 / ×2 the browser
-- offers, ref = a target tempo other than the project's }.
-- Returns rate, bpm, why. Rate is 1.0 whenever no tempo deserved belief —
-- "leave it alone" is the only safe thing to do with a file we cannot date.
-- ---------------------------------------------------------------------------
function SrcTempo.Rate(path, opts)
    local declared = opts and opts.declared
    local mult     = (opts and opts.mult) or 1.0
    local ref      = (opts and opts.ref) or r.Master_GetTempo()
    local bpm, why = SrcTempo.Bpm(path, declared)
    if not bpm or not ref or ref <= 0 then return 1.0, nil, nil end
    local rate = (ref / bpm) * mult
    if not (rate > 0.05 and rate < 20) then return 1.0, bpm, why end
    return rate, bpm, why
end

-- The interval, in semitones, between a file's tempo and the project's —
-- what a vinyl-style repitch has to apply. Same answer as Rate, expressed
-- the way a tuning control needs it.
function SrcTempo.Semitones(path, opts)
    local rate, bpm, why = SrcTempo.Rate(path, opts)
    if not bpm then return 0, nil, nil end
    local st = 12 * math.log(rate, 2)
    if st > 80 then st = 80 elseif st < -80 then st = -80 end
    return st, bpm, why
end

return SrcTempo
