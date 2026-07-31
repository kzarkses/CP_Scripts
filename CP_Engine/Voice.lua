-- CP_Engine — Voice
--
-- LA SEULE FACON DE FAIRE DU SON DANS TOUTE LA SUITE.
--
-- Aujourd'hui, quatre fenetres font sonner un fichier de quatre manieres
-- differentes : CP_MediaExplorer par CF_Preview, CP_Session par un RS5K et une
-- lane, CP_Editor et CP_Sampler encore autrement. Aucune ne partage sa
-- capacite avec les autres, et c'est la premiere source de confusion recensee
-- dans ANALYSE_Ecosysteme. Ce module est la capacite commune qui leur manquait.
--
-- ---------------------------------------------------------------------------
-- TROIS REGLES, ET ELLES EXPLIQUENT TOUT LE FICHIER
-- ---------------------------------------------------------------------------
--
-- 1. ON INTERROGE UNE CAPACITE, PAS UN BACKEND.
--    Une fenetre ne demande jamais « es-tu natif ». Elle demande « sais-tu
--    dater un lancement a l'echantillon » (CanScheduleExact), « combien de voix
--    peux-tu tenir » (MaxVoices). Un appelant ecrit contre ce qu'il lui faut,
--    et le jour ou le moteur natif absent devient present, il en profite sans
--    changer d'une ligne. Un `if natif then` dans une fenetre serait la meme
--    faute que celle qu'on repare.
--
-- 2. LE `if natif then` VIT ICI, ET NULLE PART AILLEURS.
--    C'est tout l'interet de ce fichier. Le jour de la bascule, un seul endroit
--    change ; le jour d'un retour en arriere, un seul endroit revient.
--
-- 3. ZERO ALLOCATION DANS LES CHEMINS PAR FRAME.
--    Les handles sont des ENTIERS, jamais des tables. State() rend plusieurs
--    valeurs plutot qu'une table. Aucune concatenation de chaine hors des
--    messages d'erreur. Ce module est appele depuis des boucles de dessin.
--
-- ---------------------------------------------------------------------------
-- CE QUE LE MOTEUR SAIT, ET CE QU'IL NE SAURA JAMAIS
-- ---------------------------------------------------------------------------
-- Il connait des VOIX et des FRAMES ABSOLUS. Il ne connait ni scene, ni
-- colonne, ni cellule, ni beat, ni tempo. La carte de tempo reste ici, sur le
-- fil principal, ou TimeMap2_* est exact — la descendre dans le fil audio
-- serait remettre dans le binaire ce qu'on cherche a en sortir.
--
-- Une commande ne dit donc jamais « joue maintenant ». Elle dit « joue au frame
-- N ». La frontiere se DECIDE ici (c'est une decision musicale) et se TIRE dans
-- le fil audio (c'est de la physique).

local Voice = {}

local r        -- reaper, injecte
local Preview  -- CP_Engine/Preview, injecte (chemin de repli)

-- ---------------------------------------------------------------------------
-- Backends
-- ---------------------------------------------------------------------------
local NATIVE = false          -- reaper_cpclip charge et a la bonne ABI
local ABI_MIN = 1.4

local NULL = 4294967295       -- kNullVoice cote moteur

Voice.NONE   = NULL
Voice.ONCE   = 0
Voice.LOOP   = 1

-- Etats, alignes sur le moteur (cp_types.h)
Voice.IDLE      = 0
Voice.SCHEDULED = 1
Voice.PLAYING   = 2
Voice.STOPPING  = 3

-- ---------------------------------------------------------------------------
-- Registre local
--
-- Prealloue une fois. Le repli n'a qu'une voix audible (CF_Preview est un
-- singleton par construction) mais on garde la meme forme de registre dans les
-- deux cas : un appelant ne doit pas avoir deux facons de tenir ses handles.
-- ---------------------------------------------------------------------------
local MAXV = 256
local vst   = {}   -- handle -> etat local (nombre)
local vfree = {}   -- pile d'index libres (repli)
local nfree = 0

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
-- preview_module est optionnel : sans lui, le repli ne sait pas auditionner et
-- Available() rend false, ce qui est une reponse honnete plutot qu'un plantage.
function Voice.init(reaper_api, preview_module)
    r = reaper_api
    Preview = preview_module

    NATIVE = false
    if r.APIExists and r.APIExists("CP_EngineABI") then
        local ok, abi = pcall(r.CP_EngineABI)
        NATIVE = (ok and abi and abi >= ABI_MIN) or false
    end

    for i = 1, MAXV do
        vst[i] = Voice.IDLE
        vfree[i] = MAXV + 1 - i
    end
    nfree = MAXV

    return NATIVE
end

-- ---------------------------------------------------------------------------
-- CAPACITES — c'est par la qu'un appelant commence
-- ---------------------------------------------------------------------------
function Voice.Available()
    return NATIVE or (Preview ~= nil and Preview.available)
end

function Voice.Backend()
    return NATIVE and "native" or "preview"
end

-- Peut-on placer un depart a un instant PRECIS du projet, exact a
-- l'echantillon ? C'est la question qui separe une audition d'un lancement.
-- Sans elle, un appelant doit garder son propre chemin (CP_Session garde RS5K).
function Voice.CanScheduleExact()
    return NATIVE
end

-- Combien de sons simultanes. Le repli en tient UN : CF_Preview est un
-- singleton, et c'est une des raisons d'exister du moteur natif.
function Voice.MaxVoices()
    return NATIVE and MAXV or 1
end

-- Le son peut-il traverser la chaine d'effets d'une piste donnee ?
function Voice.CanRouteToTrack()
    return NATIVE or (Preview ~= nil and Preview.SetOutputTrack ~= nil)
end

function Voice.Diag()
    if NATIVE and r.CP_Diag then return r.CP_Diag() end
    return "backend=preview voix=1"
end

-- ---------------------------------------------------------------------------
-- HORLOGE
--
-- Sync() prend l'ancre entre le temps du projet et le temps du moteur : deux
-- lectures collees, dont l'ecart vaut quelques microsecondes et non une frame de
-- defer. A appeler UNE fois par frame, avant toute conversion.
-- ---------------------------------------------------------------------------
function Voice.Sync()
    if NATIVE then r.CP_ClockSync() end
end

-- Frame absolu courant, tel que le fil audio le compte.
function Voice.Now()
    if NATIVE then return r.CP_ClockNow() end
    return 0
end

function Voice.Srate()
    if NATIVE then return r.CP_Srate() end
    return 48000
end

-- Instant du projet (secondes) -> frame absolu. Passe par la derniere ancre.
--
-- ARRONDI ICI, et pas ailleurs. La conversion rend un fractionnaire ; le moteur
-- tronque ce qu'on lui donne. Laisser le fractionnaire circuler produit un
-- desaccord d'un echantillon entre ce que l'appelant croit avoir demande et ce
-- qui a ete place — un faux ecart, qui coute une soiree a diagnostiquer. Un
-- echantillon fractionnaire n'a de toute facon aucun sens : c'est la frontiere
-- de l'ABI qui doit trancher, une fois.
local function toFrame(x)
    return math.floor((x or 0) + 0.5)
end

function Voice.TimeToSample(t)
    if NATIVE then return toFrame(r.CP_TimeToSample(t)) end
    return 0
end

-- Beat -> frame absolu. LA conversion vit ici et pas dans le moteur : la carte
-- de tempo n'est pas lineaire des qu'il y a un marqueur, et TimeMap2_* la
-- resout exactement, sur le fil principal, ou c'est gratuit.
function Voice.BeatToSample(beat)
    if not NATIVE then return 0 end
    local t = r.TimeMap2_QNToTime(0, beat)
    return toFrame(r.CP_TimeToSample(t))
end

-- ---------------------------------------------------------------------------
-- MATIERE
--
-- Load rend un identifiant opaque. En natif c'est un slot du vivier, decode une
-- fois en RAM au taux du moteur ; en repli c'est le chemin lui-meme, garde tel
-- quel. Un appelant ne doit pas savoir lequel.
-- ---------------------------------------------------------------------------
function Voice.Load(path)
    if not path or path == "" then return nil end
    if NATIVE then
        local id = r.CP_ClipLoad(path)
        if not id or id < 0 then return nil end
        return id
    end
    if Preview and not Preview.GetSource(path) then return nil end
    return path
end

function Voice.Unload(clip)
    if clip == nil then return end
    if NATIVE then
        if type(clip) == "number" then r.CP_ClipUnload(clip) end
    elseif Preview and Preview.DropSource then
        Preview.DropSource(clip)
    end
end

-- Rend duree_secondes, canaux, taux — ou nil.
function Voice.ClipInfo(clip)
    if clip == nil then return nil end
    if NATIVE and type(clip) == "number" then
        local ok, frames, srate, nch = r.CP_ClipInfo(clip)
        if not ok or not srate or srate <= 0 then return nil end
        return frames / srate, nch, srate
    end
    if Preview then return Preview.Meta(clip) end
    return nil
end

-- ---------------------------------------------------------------------------
-- PORTS — une colonne, une piste
-- ---------------------------------------------------------------------------
-- Idempotent des deux cotes : appeler deux fois ne coute rien et ne casse rien.
function Voice.BindTrack(port, track)
    if NATIVE then
        if not track or not r.ValidatePtr2(0, track, "MediaTrack*") then return false end
        return r.CP_PortAttach(track, port) and true or false
    end
    if Preview and Preview.SetOutputTrack then
        Preview.SetOutputTrack(track)
        return true
    end
    return false
end

function Voice.UnbindTrack(port)
    if NATIVE then
        r.CP_PortDetach(port)
    elseif Preview and Preview.SetOutputTrack then
        Preview.SetOutputTrack(nil)
    end
end

-- ---------------------------------------------------------------------------
-- VOIX
-- ---------------------------------------------------------------------------
function Voice.Alloc(port)
    port = port or 0
    if NATIVE then
        local h = r.CP_VoiceAlloc(port)
        if not h or h == NULL then return nil end
        return h
    end
    if nfree < 1 then return nil end
    local h = vfree[nfree]
    nfree = nfree - 1
    vst[h] = Voice.IDLE
    return h
end

function Voice.Release(h)
    if h == nil then return end
    if NATIVE then
        r.CP_VoiceRelease(h)
        return
    end
    if vst[h] ~= Voice.IDLE then Voice.Stop(h) end
    vst[h] = Voice.IDLE
    nfree = nfree + 1
    vfree[nfree] = h
end

-- opts, toutes optionnelles : { rate, gain, loop, fade_in, fade_out, pan }
-- Aucune table n'est allouee ici ; opts est fournie par l'appelant, qui a tout
-- interet a la reutiliser en place s'il appelle par frame.
local function applyOpts(h, opts)
    if not opts or not NATIVE then return end
    if opts.pan then r.CP_VoiceSet(h, "pan", opts.pan) end
    if opts.fade_in then r.CP_VoiceSet(h, "fade_in", opts.fade_in) end
    if opts.fade_out then r.CP_VoiceSet(h, "fade_out", opts.fade_out) end
end

-- Lancement IMMEDIAT. C'est l'audition : on veut du son au plus vite, pas a un
-- instant precis.
function Voice.Play(h, clip, opts)
    if h == nil or clip == nil then return false end
    local rate = (opts and opts.rate) or 1.0
    local gain = (opts and opts.gain) or 1.0
    local mode = (opts and opts.loop) and Voice.LOOP or Voice.ONCE

    if NATIVE then
        applyOpts(h, opts)
        local at = r.CP_ClockNow()
        local ok = r.CP_VoicePlayAtSample(h, clip, at, mode, rate, gain)
        if ok then vst[h] = Voice.PLAYING end
        return ok and true or false
    end

    if not Preview then return false end
    Preview.SetLoop(mode == Voice.LOOP)
    Preview.SetVolume(gain)
    local ok = Preview.Play(clip, (rate ~= 1.0) and { rate_override = rate } or nil)
    if ok then vst[h] = Voice.PLAYING end
    return ok
end

-- Lancement DATE, exact a l'echantillon. Rend false si le backend ne sait pas
-- le faire — l'appelant doit alors garder son propre chemin, et il le sait
-- d'avance par CanScheduleExact().
--
-- Le pre-roll du warp (85 a 139 ms selon le taux, mesure §12.12) n'est PAS
-- gere ici : un clip etire demandera d'armer plus tot, et ce sera une decision
-- de l'appelant parce qu'elle est musicale.
function Voice.PlayAtSample(h, clip, at_sample, opts)
    if not NATIVE or h == nil or clip == nil then return false end
    applyOpts(h, opts)
    local rate = (opts and opts.rate) or 1.0
    local gain = (opts and opts.gain) or 1.0
    local mode = (opts and opts.loop) and Voice.LOOP or Voice.ONCE
    local ok = r.CP_VoicePlayAtSample(h, clip, at_sample, mode, rate, gain)
    if ok then vst[h] = Voice.SCHEDULED end
    return ok and true or false
end

function Voice.PlayAtTime(h, clip, project_time, opts)
    if not NATIVE then return false end
    return Voice.PlayAtSample(h, clip, r.CP_TimeToSample(project_time), opts)
end

function Voice.PlayAtBeat(h, clip, beat, opts)
    if not NATIVE then return false end
    return Voice.PlayAtSample(h, clip, Voice.BeatToSample(beat), opts)
end

-- Arret immediat, avec un fondu court par defaut. 5 ms : assez pour avaler la
-- coupure, assez court pour ne pas manger un transitoire.
function Voice.Stop(h, fade)
    if h == nil then return end
    if NATIVE then
        r.CP_VoiceStopAtSample(h, r.CP_ClockNow(), fade or 0.005)
        vst[h] = Voice.STOPPING
        return
    end
    if Preview then Preview.Stop() end
    vst[h] = Voice.IDLE
end

-- Arret DATE : c'est le cas musical (fin de boucle, frontiere de mesure), et il
-- doit tomber exactement sur le frame demande. fade 0 = coupure nette.
function Voice.StopAtSample(h, at_sample, fade)
    if not NATIVE or h == nil then return false end
    return r.CP_VoiceStopAtSample(h, at_sample, fade or 0) and true or false
end

-- Enchainement exact : la suivante demarre au frame ou celle-ci s'eteint. Ce
-- n'est PAS faisable depuis Lua — la fenetre vaut un bloc, soit 1,33 ms a 64
-- echantillons, quand une frame de defer en vaut 16 a 74. C'est pour ca que le
-- moteur possede un emplacement « suivant » par voix.
function Voice.QueueNext(h, next_h, xfade)
    if not NATIVE or h == nil or next_h == nil then return false end
    return r.CP_VoiceQueueNext(h, next_h, xfade or 0) and true or false
end

-- Reglage a la volee. En repli, seuls le volume et le taux existent.
function Voice.Set(h, param, value)
    if h == nil then return false end
    if NATIVE then return r.CP_VoiceSet(h, param, value) and true or false end
    if not Preview then return false end
    if param == "gain" then Preview.SetVolume(value) return true end
    if param == "rate" then Preview.SetRate(value) return true end
    return false
end

-- Rend etat, position_en_frames_source. Plusieurs valeurs et non une table :
-- appele par frame pour dessiner une tete de lecture.
function Voice.State(h)
    if h == nil then return Voice.IDLE, 0 end
    if NATIVE then
        local ok, pos, st = r.CP_VoiceState(h)
        if not ok then return Voice.IDLE, 0 end
        vst[h] = st
        return st, pos
    end
    if Preview and Preview.IsPlaying() and vst[h] == Voice.PLAYING then
        local _, pos = Preview.Progress()
        return Voice.PLAYING, pos or 0
    end
    if vst[h] == Voice.PLAYING then vst[h] = Voice.IDLE end
    return Voice.IDLE, 0
end

function Voice.IsPlaying(h)
    local st = Voice.State(h)
    return st == Voice.PLAYING or st == Voice.SCHEDULED
end

-- Frame absolu du PREMIER echantillon reellement audible, -1 si pas demarre.
-- Note par la voix elle-meme, donc sans course : une deduction externe
-- (horloge - position) se trompe d'un bloc selon le moment de la lecture.
function Voice.StartedAt(h)
    if not NATIVE or h == nil then return -1 end
    return r.CP_VoiceStartedAt(h)
end

-- ---------------------------------------------------------------------------
-- Arret d'urgence. Declenchable meme sans fenetre ouverte, parce qu'une note
-- coincee ne demande pas la permission.
-- ---------------------------------------------------------------------------
function Voice.Panic()
    if NATIVE then
        r.CP_Panic()
    elseif Preview then
        Preview.Stop()
    end
    for i = 1, MAXV do vst[i] = Voice.IDLE end
end

return Voice
