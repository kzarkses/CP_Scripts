-- CP_NativeProbe — la sonde de l'etape 1.
--
-- Elle ne sert pas a faire de la musique. Elle repond, avec des chiffres, aux
-- questions ouvertes du dossier ARCHI_MoteurNatif.md :
--   * l'extension se charge-t-elle et la surface CP_* existe-t-elle ?
--   * un apercu de piste tire-t-il notre PCM_source, et de facon CONTIGUE ?
--     (c'est le point §12.5.1 : `time_s` est un temps DEMANDE, pas un compteur)
--   * un rendez-vous date tombe-t-il ou on l'a demande, a 64 echantillons ?
--
-- Mode d'emploi : selectionner une piste, lancer le script, donner un chemin de
-- fichier audio. Le son sort SUR LA PISTE, sans aucun objet dans sa chaine
-- d'effets — c'est tout l'interet de la route apercu.

local r = reaper

local function msg(s) r.ShowConsoleMsg(tostring(s) .. "\n") end

-- ---------------------------------------------------------------------------
-- 1. Le garde. ReaPack n'a aucun mecanisme de dependance : un script peut tres
--    bien s'installer sans le binaire. Il doit le dire, pas exploser.
-- ---------------------------------------------------------------------------
if not r.APIExists("CP_EngineABI") then
    r.MB("Le moteur CP_Native n'est pas charge.\n\n" ..
         "Copier reaper_cpclip.dll dans :\n" ..
         r.GetResourcePath() .. "\\UserPlugins\n\n" ..
         "puis redemarrer REAPER.", "CP_Native", 0)
    return
end

local ABI_ATTENDU = 1.0
local abi = r.CP_EngineABI()
if abi ~= ABI_ATTENDU then
    r.MB(string.format("Version d'ABI incompatible : moteur %.1f, script %.1f",
                       abi, ABI_ATTENDU), "CP_Native", 0)
    return
end

r.ClearConsole()
msg("=== CP_NativeProbe ===")
msg("ABI          : " .. abi)
msg("srate moteur : " .. r.CP_Srate())
msg("etat         : " .. r.CP_Diag())

-- ---------------------------------------------------------------------------
-- 2. La piste
-- ---------------------------------------------------------------------------
local tr = r.GetSelectedTrack(0, 0)
if not tr then
    r.MB("Selectionne une piste d'abord.", "CP_Native", 0)
    return
end

-- ---------------------------------------------------------------------------
-- 3. Le fichier. Par defaut, la source de l'item selectionne.
-- ---------------------------------------------------------------------------
local defaut = ""
local it = r.GetSelectedMediaItem(0, 0)
if it then
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
        defaut = r.GetMediaSourceFileName(r.GetMediaItemTake_Source(tk))
    end
end

local ok, path = r.GetUserInputs("CP_NativeProbe", 1,
                                 "Fichier audio (extrait,4096)", defaut)
if not ok or path == "" then return end

-- ---------------------------------------------------------------------------
-- 4. Chargement en RAM, via les PCM_source de REAPER : aucun format n'est perdu
-- ---------------------------------------------------------------------------
local t0 = r.time_precise()
local clip = r.CP_ClipLoad(path)
local dt = r.time_precise() - t0

if clip < 0 then
    msg("ECHEC : le fichier n'a pas pu etre decode -> " .. path)
    return
end

local _, frames, srate, nch = r.CP_ClipInfo(clip)
msg(string.format("clip %d  : %d frames, %.0f Hz, %d canaux  (decode en %.1f ms)",
                  clip, frames or 0, srate or 0, nch or 0, dt * 1000))
msg(string.format("           %.1f Mo en RAM", (frames or 0) * (nch or 0) * 4 / 1048576))

-- ---------------------------------------------------------------------------
-- 5. Le port : un apercu permanent sur la piste. Rien dans sa chaine d'effets.
-- ---------------------------------------------------------------------------
if not r.CP_PortAttach(tr, 0) then
    msg("ECHEC : PlayTrackPreview2Ex a refuse. C'est LA question de la sonde.")
    return
end
msg("port 0 attache a : " .. select(2, r.GetTrackName(tr)))

-- ---------------------------------------------------------------------------
-- 6. Le rendez-vous. C'est le cœur de la mesure.
--
--    CP_ClockSync colle deux lectures — la position du projet et le compteur
--    d'echantillons du fil audio. L'erreur vaut le temps entre les deux
--    (des microsecondes), et non une frame de defer (16 a 74 ms).
-- ---------------------------------------------------------------------------
local v = r.CP_VoiceAlloc(0)
if v == 4294967295 then msg("ECHEC : plus de voix"); return end

-- Premier tir : date sur l'horloge du MOTEUR seule. Elle tourne des que la
-- carte son tourne, transport a l'arret compris — donc ce tir ne depend
-- d'aucune hypothese sur le projet. Si rien ne sort ici, le probleme est la
-- route apercu, et pas le calage.
local smp0 = r.CP_ClockNow()
local sr   = r.CP_Srate()
if smp0 == 0 then
    msg("")
    msg("ATTENTION : l'horloge est a zero. Soit le hook materiel ne tourne pas,")
    msg("soit le moteur du son est ferme. Regarde 'hook=' ci-dessous.")
end

local cible_smp = smp0 + sr          -- dans une seconde pile, en temps moteur
r.CP_VoicePlayAtSample(v, clip, cible_smp, 1, 1.0, 1.0)  -- 1 = boucle

-- Et, pour comparaison seulement, ce que l'ancre projet<->moteur en dit. Les
-- deux doivent concorder quand le transport roule ; c'est la verification de
-- l'ancre, pas du moteur.
r.CP_ClockSync()
local via_ancre = r.CP_TimeToSample(r.GetPlayPosition() + 1.0)

msg("")
msg(string.format("horloge      : %.0f  (srate %.0f)", smp0, sr))
msg(string.format("rendez-vous  : frame %.0f, soit dans 1,000 s pile", cible_smp))
msg(string.format("via l'ancre  : frame %.0f  (ecart %.0f echantillons = %.2f ms)",
                  via_ancre, via_ancre - cible_smp, (via_ancre - cible_smp) / sr * 1000))
msg("")
msg("Ce qu'il faut regarder dans les lignes qui suivent :")
msg("  calls=   monte -> l'apercu TIRE bien notre source. Reste a 0 -> la route")
msg("           apercu ne marche pas, et c'est la seule chose qui compte.")
msg("  maxgap=  reste a 0.000000 -> l'hote demande de facon CONTIGUE, donc")
msg("           compter les echantillons est legitime. Saute -> il faut se")
msg("           recaler sur time_s a chaque bloc.")
msg("  hook=1   le hook materiel bat. hook=0 -> un port fait office d'horloge.")
msg("")
msg("Pour mesurer le calage : arme la piste, enregistre, et compare l'attaque")
msg("a un kick MIDI lance sur la meme frontiere.")

-- ---------------------------------------------------------------------------
-- 7. Suivi : une frame de defer, pour observer sans jamais bloquer
-- ---------------------------------------------------------------------------
local t_start = r.time_precise()
local dernier = ""

local function boucle()
    r.CP_ClockSync()                        -- l'ancre se reprend a chaque frame
    local d = r.CP_Diag()
    if d ~= dernier then
        dernier = d
        msg(d)
    end
    if r.time_precise() - t_start < 20.0 then
        r.defer(boucle)
    else
        -- Demontage en deux temps. Liberer la voix puis detacher le port dans
        -- la MEME frame ne marche pas : la commande d'extinction n'a pas encore
        -- ete drainee, et le port cesse de rendre avant de l'avoir vue. Le
        -- moteur reprend desormais ses voix lui-meme dans CP_PortDetach, mais on
        -- laisse quand meme au fondu le temps de sortir proprement.
        r.CP_VoiceRelease(v)
        r.defer(function()
            r.CP_ClipUnload(clip)
            r.CP_PortDetach(0)
            msg("")
            msg("etat final : " .. r.CP_Diag())
            msg("=== sonde terminee, tout libere ===")
        end)
    end
end

r.defer(boucle)
