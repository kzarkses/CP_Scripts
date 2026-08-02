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
--   2. EMBEDDED   the file's own header says so — an "acidised" WAV, an MP3
--                 with a TBPM frame, an annotated AIFF. WRITTEN, not fitted,
--                 so it is believed the way a declaration is.
--   3. NAMED      the filename says so — believed, but only if the file is
--                 long enough to be at least two beats at that tempo. This
--                 is the sampler's guard and it is the one that stops a kick
--                 from being repitched by 30 %.
--   4. ANALYSED   REAPER's own answer (GetTempoMatchPlayRate), under the same
--                 two-beat guard.
--   5. INFERRED   from the length alone, and only when it is UNAMBIGUOUS: a
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
--
-- ---------------------------------------------------------------------------
-- L'ORDRE A CHANGE, ET C'EST UNE CORRECTION
-- ---------------------------------------------------------------------------
-- ANALYSED etait en deuxieme position, et la raison ecrite ici etait « il lit
-- le tempo embarque quand le fichier en porte un ». C'etait vrai, et c'etait la
-- seule chose qui le justifiait devant le NOM du fichier : pour tout le reste,
-- GetTempoMatchPlayRate ne fait qu'AJUSTER un nombre de mesures a une duree —
-- exactement ce que fait INFERRED, qu'on classe dernier et sous garde.
--
-- Le tempo embarque a maintenant sa propre source, qui le lit explicitement.
-- Ce qui reste a ANALYSED est donc un ajustement, et un ajustement ne passe pas
-- devant un nombre qu'un humain a ECRIT dans le nom du fichier.

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

-- ---------------------------------------------------------------------------
-- ⚠️ UNE RECHERCHE QUI CONSOMME SON SEPARATEUR MANGE LE NOMBRE SUIVANT
-- ---------------------------------------------------------------------------
-- « SONNY_D_drum_loop_02_136.wav » porte son tempo EN CLAIR, et il n'etait pas
-- vu. Le motif etait `[%s_%-](%d%d%d?)[%s_%-%.]` : il exige un separateur
-- devant les chiffres ET derriere, donc il CONSOMME les deux. Sur « _02_136 »
-- il a lu « _02_ » en entier, et `gmatch` a repris la lecture a « 136 » — qui
-- n'a alors plus de separateur devant lui, puisqu'il vient d'etre avale.
--
-- Le numero de piste mangeait donc le tempo, systematiquement, et seulement
-- quand les deux se suivaient — c'est-a-dire dans la convention de nommage la
-- plus repandue des banques de samples. Une banque entiere ne se tempo-matchait
-- pas, et le nom du fichier le disait a chaque ligne.
--
-- On parcourt donc les groupes de chiffres avec `find`, qui REND leurs bornes
-- sans rien consommer, et on regarde ce qui les entoure separement.
--
-- DEUX REGLES DE BON SENS, qui valent mieux qu'un motif plus fin :
--   · un groupe de deux ou trois chiffres — « 1200 » n'est pas un tempo, et
--     l'ancien motif en tirait pourtant « 120 » ;
--   · pas de zero en tete — « 02 » est un NUMERO, jamais un tempo. Un index
--     est rembourre, un tempo ne l'est pas.
local SEP_BEFORE = "[%s_%-%(%[]"
local SEP_AFTER  = "[%s_%-%.%)%]]"

local function bareTempo(name, strict)
    local pos = 1
    while true do
        local a, b, d = name:find("(%d+)", pos)
        if not a then return nil end
        pos = b + 1
        if #d >= 2 and #d <= 3 and d:sub(1, 1) ~= "0" then
            local ok = true
            if strict then
                -- Le debut du nom vaut un separateur ; sa fin aussi.
                local before = (a > 1) and name:sub(a - 1, a - 1) or " "
                local after  = (b < #name) and name:sub(b + 1, b + 1) or " "
                ok = before:match(SEP_BEFORE) ~= nil
                     and after:match(SEP_AFTER) ~= nil
            end
            if ok then
                local v = tonumber(d)
                if v and v >= 60 and v <= 200 then return v end
            end
        end
    end
end

-- The filename readers, merged. The sampler's form wants a separator before
-- the digits (so "Loop_128bpm" matches and "SP1200bpm" does not) and the
-- browser's accepts a decimal point. Both are tried, strictest first.
function SrcTempo.FromName(path)
    if not path then return nil end
    local name = path:match("([^/\\]+)$") or path
    local bpm = name:match("[%s_%-%(%[](%d%d%d?%.?%d*)%s*[bB][pP][mM]")
             or name:match("^(%d%d%d?%.?%d*)%s*[bB][pP][mM]")
    local v = tonumber(bpm)
    if v and v >= 40 and v <= 300 then return v end
    -- a bare number, in a plausible loop-tempo range. Deliberately narrower
    -- than the bpm-suffixed forms: nothing marks this number as a tempo except
    -- that it could be one. Un nombre ISOLE d'abord — c'est la forme qu'une
    -- banque emploie vraiment — puis un nombre colle a des lettres (« Loop128 »),
    -- que l'ancien motif refusait tout net.
    return bareTempo(name, true) or bareTempo(name, false)
end

-- ---------------------------------------------------------------------------
-- LE TEMPO ECRIT DANS LE FICHIER
-- ---------------------------------------------------------------------------
-- Un WAV « acidise » (Acid, Live, Battery, la moitie des banques commerciales),
-- un MP3 avec une trame TBPM, un AIFF annote : le tempo y est POSE, pas
-- ajuste. C'est la meilleure reponse qui existe apres celle d'un humain, et
-- personne ne la lisait — on passait par GetTempoMatchPlayRate, qui la lit
-- peut-etre, mais qui rend un TAUX, donc une reponse dont on ne sait pas si
-- elle vient de l'entete ou d'un ajustement sur la duree.
--
-- ON NE DEVINE PAS LE NOM DE LA CLE. REAPER rend la LISTE des identifiants du
-- fichier quand on lui en demande un vide : c'est la seule facon d'attraper a
-- la fois « ACID:tempo », « ID3:TBPM » et ce qu'un format qu'on ne connait pas
-- appellera autrement. Un tableau de noms codes en dur aurait vieilli, et
-- surtout il aurait eu tort en silence.
--
-- LE DRAPEAU « ONE-SHOT » A LE DERNIER MOT. Un fichier acidise porte souvent
-- les deux : un tempo (celui de la session qui l'a produit) ET la mention que
-- ce n'est pas une boucle. Croire le tempo d'un coup unique, c'est le
-- repitcher de trente pour cent — la faute exacte que ce module existe pour
-- empecher, et ici elle est ECRITE dans le fichier.
function SrcTempo.FromMetadata(path)
    if not r.GetMediaFileMetadata then return nil end
    local src, owned = getSource(path)
    if not src then return nil end
    local bpm = nil
    local n, list = r.GetMediaFileMetadata(src, "")
    if n and n > 0 and list and list ~= "" then
        for key in list:gmatch("[^\r\n]+") do
            -- La FEUILLE de l'identifiant, pas la chaine entiere : « ACID:tempo »
            -- est un tempo, « ACID:tempo_source » n'en est pas un.
            local leaf = key:lower():match("([^:]+)$") or ""
            if leaf == "oneshot" then
                local _, v = r.GetMediaFileMetadata(src, key)
                v = v and v:lower() or ""
                if v == "1" or v == "true" or v == "yes" then bpm = nil break end
            elseif leaf == "tempo" or leaf == "bpm" or leaf == "tbpm" then
                local _, v = r.GetMediaFileMetadata(src, key)
                local t = tonumber(v and v:match("%d+%.?%d*") or nil)
                if t and t >= 40 and t <= 300 then bpm = t end
            end
        end
    end
    if owned then r.PCM_Source_Destroy(src) end
    return bpm
end

-- REAPER's own tempo match — the routine the native Media Explorer uses. It
-- answers with a RATE, so the tempo it implies is the project's divided by
-- it. Guarded the way the browser always guarded it: a rate outside 0.05..20
-- is not a musical answer.
-- LE SECOND RETOUR DE getSource DIT « c'est a toi de la detruire », et il
-- etait ignore ici : chaque appel laissait une PCM_source derriere lui. Invisible
-- depuis CP_Session, qui injecte un cache de sources et ne possede donc jamais
-- celle qu'il rend ; bien reelle depuis Kit.lua, qui n'en injecte pas — un kit
-- de soixante-quatre pads en fuyait soixante-quatre au chargement.
--
-- Un seul point de sortie, parce que la fonction rend a quatre endroits et
-- qu'il en manquait quatre.
function SrcTempo.FromAnalysis(path)
    if not r.GetTempoMatchPlayRate then return nil end
    local src, owned = getSource(path)
    if not src then return nil end
    local bpm = nil
    local ok, retval, rate = pcall(r.GetTempoMatchPlayRate, src, 1.0, 0, 1.0)
    if ok and retval and rate and rate > 0.05 and rate < 20 then
        local pb = r.Master_GetTempo()
        if pb and pb > 0 then bpm = pb / rate end
    end
    if owned then r.PCM_Source_Destroy(src) end
    return bpm
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
-- Returns bpm, why — where `why` is "declared" | "embedded" | "named" |
-- "analysed" | "inferred", or nil, nil when nothing deserves belief. The
-- reason is part of the answer on purpose: a window that displays a tempo it
-- cannot account for is a window the user learns to distrust.
function SrcTempo.Bpm(path, declared)
    local d = tonumber(declared)
    if d and d > 0 then return d, "declared" end
    if not path or path == "" then return nil, nil end

    -- The length is read BEFORE the analysis, because the analysis needs the
    -- same guard the name does. GetTempoMatchPlayRate will happily hand back a
    -- rate for a 0.4 s kick — it is fitting a bar count to a duration, and a
    -- short duration fits something. Believing it repitches the kick, which is
    -- the exact mistake this module's header says it exists to prevent, and it
    -- also makes the length machinery upstream call that one-shot a loop.
    local len = SrcTempo.Length(path)

    -- ECRIT DANS L'ENTETE. Aucune garde : le fichier ne l'ajuste pas, il le
    -- declare, et son propre drapeau one-shot est deja la seule reserve qui
    -- vaille (voir FromMetadata).
    local e = SrcTempo.FromMetadata(path)
    if e and e > 0 then return e, "embedded" end

    local n = SrcTempo.FromName(path)
    if n then
        -- long enough to BE a loop at that tempo? Two beats is the floor: a
        -- kick named after the kit's tempo is not a bar of anything.
        if not len or len >= (60 / n) * 2 * 0.9 then return n, "named" end
    end

    local a = SrcTempo.FromAnalysis(path)
    if a and a > 0 then
        if not len or len >= (60 / a) * 2 * 0.9 then return a, "analysed" end
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
