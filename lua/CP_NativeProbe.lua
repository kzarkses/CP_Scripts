-- CP_NativeProbe — l'instrument de l'etape 1.
--
-- Elle ne fait pas de musique, elle rend des chiffres. Trois questions, et
-- chacune decide quelque chose dans ARCHI_MoteurNatif.md :
--
--   1. l'apercu tire-t-il notre PCM_source, et sans en manquer un seul ?
--      -> calls / blocks. S'il descend sous 1,000, le service d'apercu
--         s'affame comme CF_Preview s'affamait, et la route §3.1 ne tient pas
--         la performance live. C'est la seule inconnue qui puisse encore
--         invalider le plan.
--   2. l'hote demande-t-il de facon CONTIGUE ?  -> maxgap
--   3. le rendez-vous tombe-t-il ou on l'a demande ?  -> ecart d'attaque
--
-- Le calage se mesure SANS enregistrer : CP_VoiceState rend la position de
-- lecture en frames source, CP_ClockNow rend le frame absolu. Lus de facon
-- coherente, clock - pos EST le frame de depart reel.
--
-- Tout part dans un fichier, pas dans la console : ca defile trop vite pour
-- etre lu, et la console sature.

local r = reaper

local LOG = r.GetResourcePath() .. "/CP_NativeProbe.log"
local fh  = io.open(LOG, "w")

local function log(s)          -- fichier seul
    if fh then fh:write(tostring(s), "\n") end
end
local function both(s)         -- fichier + console
    log(s)
    r.ShowConsoleMsg(tostring(s) .. "\n")
end
local function fin()
    if fh then fh:close(); fh = nil end
end

-- ---------------------------------------------------------------------------
-- Le garde
-- ---------------------------------------------------------------------------
if not r.APIExists("CP_EngineABI") then
    r.MB("Le moteur CP_Native n'est pas charge.\n\nCopier reaper_cpclip.dll dans :\n"
         .. r.GetResourcePath() .. "\\UserPlugins\n\npuis redemarrer REAPER.",
         "CP_Native", 0)
    fin(); return
end

local ABI_ATTENDU = 1.0
if r.CP_EngineABI() ~= ABI_ATTENDU then
    r.MB(string.format("ABI incompatible : moteur %.1f, script %.1f",
                       r.CP_EngineABI(), ABI_ATTENDU), "CP_Native", 0)
    fin(); return
end

r.ClearConsole()
both("=== CP_NativeProbe ===")
both("journal : " .. LOG)
both("depart  : " .. r.CP_Diag())

local tr = r.GetSelectedTrack(0, 0)
if not tr then
    r.MB("Selectionne une piste d'abord.", "CP_Native", 0)
    fin(); return
end

-- ---------------------------------------------------------------------------
-- Le fichier
-- ---------------------------------------------------------------------------
local defaut = ""
local it = r.GetSelectedMediaItem(0, 0)
if it then
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
        defaut = r.GetMediaSourceFileName(r.GetMediaItemTake_Source(tk))
    end
end

local ok, path = r.GetUserInputs("CP_NativeProbe", 1, "Fichier audio (extrait,4096)", defaut)
if not ok or path == "" then fin(); return end

local t0 = r.time_precise()
local clip = r.CP_ClipLoad(path)
local dt = r.time_precise() - t0
if clip < 0 then
    both("ECHEC : fichier non decode -> " .. path)
    fin(); return
end

local _, frames, srate, nch = r.CP_ClipInfo(clip)
frames = frames or 0; srate = srate or 0; nch = nch or 0

both(string.format("fichier : %s", path))
both(string.format("clip %d : %d frames = %.3f s, %.0f Hz, %d canaux, %.2f Mo, decode en %.1f ms",
                   clip, frames, (srate > 0) and frames / srate or 0, srate, nch,
                   frames * nch * 4 / 1048576, dt * 1000))

-- Le controle de sanite qui aurait du exister des le premier jet : si le
-- fichier fait plusieurs secondes et que le clip en fait une fraction, c'est le
-- decodage qui tronque, et rien de ce qui suit n'a de sens.
local src = r.PCM_Source_CreateFromFile(path)
if src then
    local vraie_duree = r.GetMediaSourceLength(src)
    r.PCM_Source_Destroy(src)
    local duree_clip = (srate > 0) and frames / srate or 0
    both(string.format("source  : %.3f s attendues, %.3f s decodees  -> %s",
                       vraie_duree, duree_clip,
                       (math.abs(vraie_duree - duree_clip) < 0.01) and "OK"
                       or "*** DECODAGE TRONQUE ***"))
end

-- ---------------------------------------------------------------------------
-- Le port : un apercu permanent. Rien dans la chaine d'effets de la piste.
-- ---------------------------------------------------------------------------
if not r.CP_PortAttach(tr, 0) then
    both("ECHEC : PlayTrackPreview2Ex a refuse.")
    fin(); return
end
both("port 0  : " .. select(2, r.GetTrackName(tr)))

local v = r.CP_VoiceAlloc(0)
if v == 4294967295 then both("ECHEC : plus de voix"); fin(); return end

-- ---------------------------------------------------------------------------
-- Le rendez-vous, date sur l'horloge du moteur seule
-- ---------------------------------------------------------------------------
local sr    = r.CP_Srate()
local smp0  = r.CP_ClockNow()
local cible = smp0 + sr * 1.0        -- dans une seconde pile

r.CP_VoicePlayAtSample(v, clip, cible, 1, 1.0, 1.0)   -- 1 = boucle

r.CP_ClockSync()
local via_ancre = r.CP_TimeToSample(r.GetPlayPosition() + 1.0)

both(string.format("horloge : %.0f, srate %.0f", smp0, sr))
both(string.format("demande : frame %.0f", cible))
both(string.format("ancre   : frame %.0f  (ecart %.0f spl = %.2f ms — n'a de sens qu'en lecture)",
                   via_ancre, via_ancre - cible, (via_ancre - cible) / sr * 1000))
both("")
both("mesure en cours, 20 s... (tout part dans le journal)")

-- ---------------------------------------------------------------------------
-- La mesure
-- ---------------------------------------------------------------------------
local t_start   = r.time_precise()
local blocks0, calls0 = nil, nil
local wraps, pos_prec = 0, -1
local ecarts    = {}          -- frame de depart mesure - frame demande
local n_ech     = 0
local dernier_console = 0

local function nombres(d)     -- extrait blocks= et calls= de la ligne de diag
    local b = tonumber(d:match("blocks=(%d+)"))
    local c = tonumber(d:match("calls=(%d+)"))
    return b, c
end

local function boucle()
    local d = r.CP_Diag()
    log(d)

    local b, c = nombres(d)
    if b and c and not blocks0 then blocks0, calls0 = b, c end

    -- Lecture COHERENTE de (clock, pos) : on encadre la lecture de la position
    -- par deux lectures d'horloge. Si l'horloge n'a pas bouge entre les deux,
    -- les deux valeurs viennent du meme bloc et clock - pos est exact. Sinon on
    -- jette l'echantillon : mieux vaut moins de mesures que des fausses.
    local ck1 = r.CP_ClockNow()
    local okv, pos, st = r.CP_VoiceState(v)
    local ck2 = r.CP_ClockNow()

    if okv and st == 2 and ck1 == ck2 and frames > 0 then
        if pos_prec >= 0 and pos < pos_prec - 1 then wraps = wraps + 1 end
        pos_prec = pos
        local depart = ck1 - pos - wraps * frames
        n_ech = n_ech + 1
        ecarts[n_ech] = depart - cible
        log(string.format("  mesure %d : clock=%.0f pos=%.1f wraps=%d -> depart=%.0f ecart=%.0f spl",
                          n_ech, ck1, pos, wraps, depart, depart - cible))
    end

    local t = r.time_precise() - t_start
    if t - dernier_console > 2.0 then
        dernier_console = t
        r.ShowConsoleMsg(string.format("  %2.0f s  %s\n", t, d))
    end

    if t < 20.0 then
        r.defer(boucle)
        return
    end

    -- --- verdict -------------------------------------------------------------
    local b1, c1 = nombres(r.CP_Diag())
    both("")
    both("=========== VERDICT ===========")

    if b1 and blocks0 and b1 > blocks0 then
        local db, dc = b1 - blocks0, c1 - calls0
        local ratio = dc / db
        both(string.format("tirage   : %d appels pour %d blocs = %.4f", dc, db, ratio))
        both(ratio > 0.999
             and "           -> l'apercu ne manque AUCUN bloc. Route §3.1 tenue."
             or  "           -> *** IL EN MANQUE. L'apercu s'affame a ce tampon. ***")
    end

    local mg = tonumber(r.CP_Diag():match("maxgap=([%d%.]+)")) or -1
    both(string.format("contigu  : maxgap=%.6f  -> %s", mg,
                       (mg == 0) and "demandes contigues, compter est legitime"
                       or "*** l'hote saute, il faut se recaler sur time_s ***"))

    if n_ech > 0 then
        local mn, mx, somme = ecarts[1], ecarts[1], 0
        for i = 1, n_ech do
            if ecarts[i] < mn then mn = ecarts[i] end
            if ecarts[i] > mx then mx = ecarts[i] end
            somme = somme + ecarts[i]
        end
        both(string.format("attaque  : %d mesures, ecart min %.0f / max %.0f / moyen %.1f spl",
                           n_ech, mn, mx, somme / n_ech))
        both(string.format("           soit %.3f ms en moyenne", somme / n_ech / sr * 1000))
        both((math.abs(mn) <= 1 and math.abs(mx) <= 1)
             and "           -> EXACT A L'ECHANTILLON."
             or  "           -> ecart non nul : a expliquer avant d'aller plus loin.")
    else
        both("attaque  : aucune mesure coherente — la voix n'a jamais joue.")
    end

    both("etat     : " .. r.CP_Diag())
    both("===============================")

    r.CP_VoiceRelease(v)
    r.defer(function()
        r.CP_ClipUnload(clip)
        r.CP_PortDetach(0)
        log("apres demontage : " .. r.CP_Diag())
        both("journal complet : " .. LOG)
        fin()
    end)
end

r.defer(boucle)
