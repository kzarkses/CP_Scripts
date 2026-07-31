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

r.CP_ClockSync()
local maintenant = r.GetPlayPosition()
local cible_s    = maintenant + 1.0           -- dans une seconde pile
local cible_smp  = r.CP_TimeToSample(cible_s)

r.CP_VoicePlayAtSample(v, clip, cible_smp, 1, 1.0, 1.0)  -- 1 = boucle

msg("")
msg(string.format("rendez-vous  : t=%.6f s  ->  frame %.0f", cible_s, cible_smp))
msg("La boucle doit demarrer EXACTEMENT une seconde apres cet instant.")
msg("Pour mesurer : arme la piste en enregistrement, enregistre, et compare")
msg("l'attaque au clic du metronome dans l'editeur.")
msg("")
msg("Relance ce script pour arreter et tout liberer.")

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
        r.CP_VoiceRelease(v)
        r.CP_ClipUnload(clip)
        r.CP_PortDetach(0)
        msg("")
        msg("=== sonde terminee, tout libere ===")
    end
end

r.defer(boucle)
