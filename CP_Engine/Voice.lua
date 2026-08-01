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
local ABI_MIN = 1.5

-- Resolue UNE fois a l'init plutot que testee par frame. Elle n'existe qu'a
-- partir de l'ABI 1.7 et ce module en accepte 1.5 : un moteur plus ancien est
-- parfaitement utilisable, il ne sait simplement pas dire a quelle vitesse le
-- projet defile — et sa reponse est alors « 1.0 », qui est vraie tant que
-- personne ne touche la reglette.
local PLAYRATE_FN = nil

-- CE QU'UNE FENETRE AFFICHE POUR DIRE QUI FAIT LE SON.
--
-- Construite UNE fois, a l'init, et pour deux raisons : elle part dans une
-- boucle de dessin (aucune concatenation par frame), et surtout elle doit dire
-- la VERSION du binaire charge. « le moteur est la » ne suffit pas quand la
-- question qu'on se pose est « est-ce que REAPER a bien repris la DLL que je
-- viens de construire ».
local LABEL = "off"

local NULL = 4294967295       -- kNullVoice cote moteur

Voice.NONE   = NULL
Voice.ONCE   = 0
Voice.LOOP   = 1

-- ---------------------------------------------------------------------------
-- LA CARTE DES PORTS — ecrite ICI, en un seul endroit
--
-- Un port est une sortie : un apercu permanent verse dans une piste (ou dans
-- la sortie materielle), pre-FX. Il y en a 32, et trois consommateurs se les
-- partagent. Deux qui se croiraient seuls se voleraient une sortie en silence,
-- alors la repartition est enoncee plutot que decouverte :
--
--   0 .. 7    LES SONS d'une colonne de session (CP_Engine/Cells : port = t)
--   8 .. 15   LE MIDI d'une colonne (CP_Engine/Loop : port = PORT_BASE + t) —
--             les DEUX moities d'une paire partagent le meme, parce qu'une
--             paire est une seule piste musicale
--   16 .. 30  libres
--   31        L'AUDITION, partagee par toute la suite. Une audition est une
--             capacite commune : le navigateur, l'editeur et le sampler
--             ecoutent le meme fichier de la meme facon, et il n'y a aucune
--             raison qu'ils s'ouvrent chacun une sortie.
-- ---------------------------------------------------------------------------
Voice.AUDITION_PORT = 31

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
        if ok and abi and abi >= ABI_MIN then
            NATIVE = true
            LABEL = "native " .. string.format("%.1f", abi)
        end
    end
    PLAYRATE_FN = (NATIVE and r.APIExists and r.APIExists("CP_PlayRate"))
                  and r.CP_PlayRate or nil

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

-- « native 1.7 » ou « off ». Courte, stable, prete a etre affichee.
function Voice.Label() return LABEL end

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

-- Sait-on transposer SANS changer la duree ? Non en natif, et c'est une
-- decision, pas un manque : l'etireur de REAPER coute 2,3 % du fil audio par
-- voix (mesure §12.12) et surtout il exige 85 a 139 ms d'amorcage. Une audition
-- doit sonner dans le meme tour de boucle que la touche qui la declenche ; un
-- dixieme de seconde de retard est exactement ce que ce navigateur refuse.
function Voice.CanPitchShift()
    return (not NATIVE) and Preview ~= nil and Preview.SetPitch ~= nil
end

-- Sait-on changer la duree SANS changer la hauteur ? Meme reponse, meme raison.
-- Le taux natif est un varispeed : il change les deux, comme un echantillonneur.
-- Sait-on jouer et boucler une PARTIE d'un fichier a l'echantillon (des
-- points de boucle en frames source) ? Le moteur oui ; CF_Preview ne boucle
-- que la source entiere, et la partie doit alors etre surveillee par frame.
function Voice.CanSection()
    return NATIVE
end

function Voice.CanTimeStretch()
    return (not NATIVE) and Preview ~= nil and Preview.SetRate ~= nil
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

-- A QUELLE VITESSE LA LIGNE DE TEMPS DU PROJET DEFILE-T-ELLE.
--
-- Ce n'est pas un tempo : le tempo ne bouge pas, c'est le projet entier qui va
-- plus vite. Pour un producteur de son, cela veut dire deux choses distinctes
-- et il faut les tenir separees :
--   · une DUREE de projet vaut moins d'echantillons — diviser par ce taux ;
--   · un son deja lance doit ACCELERER — multiplier son taux de lecture.
-- La valeur vient de l'ancre, donc c'est la meme que celle avec laquelle le
-- moteur a date ce qu'il a date.
function Voice.PlayRate()
    if PLAYRATE_FN then
        local v = PLAYRATE_FN()
        if v and v > 0.0001 then return v end
    end
    return 1.0
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
-- Rend l'identifiant, ou nil suivi d'une RAISON. « trop long » et « illisible »
-- ne sont pas la meme phrase : un appelant qui ne peut pas les distinguer finit
-- par dire « fichier illisible » a propos d'un fichier parfaitement lisible.
function Voice.Load(path)
    if not path or path == "" then return nil, "no_path" end
    if NATIVE then
        local id = r.CP_ClipLoad(path)
        if not id then return nil, "failed" end
        if id == -2 then return nil, "too_long" end   -- plafond de 64 s
        if id < 0 then return nil, "failed" end
        return id
    end
    if Preview and not Preview.GetSource(path) then return nil, "failed" end
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

-- Sortie MATERIELLE, sans piste : le comportement par defaut d'un navigateur,
-- qui ecoute avant de choisir une piste. Sans elle, une fenetre d'audition ne
-- pourrait pas se passer de CF_Preview.
function Voice.BindOutput(port, outchan)
    if NATIVE then
        return r.CP_PortAttachOut(port, outchan or 0) and true or false
    end
    if Preview and Preview.SetOutputTrack then
        Preview.SetOutputTrack(nil)
        return true
    end
    return false
end

-- Ce port a-t-il une sortie ? Une voix ne peut etre allouee que la.
function Voice.OutputActive(port)
    if NATIVE then return r.CP_PortActive(port) and true or false end
    return Preview ~= nil and Preview.available == true
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

-- opts, toutes optionnelles :
--   { rate, gain, loop, fade_in, fade_out, pan, offset,
--     loop_start, loop_end }   -- en FRAMES source
-- Aucune table n'est allouee ici ; opts est fournie par l'appelant, qui a tout
-- interet a la reutiliser en place s'il appelle par frame.
--
-- loop_start / loop_end sont LA SECTION : jouer une partie d'un fichier comme
-- si elle etait le fichier. Le moteur les tient nativement, donc le retour de
-- boucle tombe a l'echantillon — la ou CF_Preview ne sait boucler que la
-- source entiere et oblige a surveiller la position une fois par frame.
local function applyOpts(h, opts)
    if not opts or not NATIVE then return end
    if opts.pan then r.CP_VoiceSet(h, "pan", opts.pan) end
    if opts.fade_in then r.CP_VoiceSet(h, "fade_in", opts.fade_in) end
    if opts.fade_out then r.CP_VoiceSet(h, "fade_out", opts.fade_out) end
    if opts.loop_start then r.CP_VoiceSet(h, "loop_start", opts.loop_start) end
    if opts.loop_end then r.CP_VoiceSet(h, "loop_end", opts.loop_end) end
end

-- `offset` se pose APRES le lancement, et c'est volontaire : l'anneau de
-- commandes est FIFO, donc les deux tombent dans le meme bloc audio, dans
-- l'ordre d'ecriture. Le lancement remet la tete au debut, le deplacement la
-- pose ou on veut — et le premier echantillon audible est deja le bon.
local function applyOffset(h, opts)
    if not NATIVE or not opts or not opts.offset then return end
    r.CP_VoiceSet(h, "pos", opts.offset)
end

-- Deplace la tete de lecture, en frames source. Un clic dans une forme d'onde.
function Voice.Seek(h, pos_frames)
    if not NATIVE or h == nil then return false end
    return r.CP_VoiceSet(h, "pos", pos_frames or 0) and true or false
end

-- Boucle A LA VOLEE : la voix ne repart pas du debut, seule sa fin de matiere
-- change de comportement.
function Voice.SetLoop(h, on)
    if h == nil then return false end
    if NATIVE then return r.CP_VoiceSet(h, "loop", on and 1 or 0) and true or false end
    if Preview then Preview.SetLoop(on and true or false) return true end
    return false
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
        if ok then
            applyOffset(h, opts)
            vst[h] = Voice.PLAYING
        end
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
    if ok then
        applyOffset(h, opts)
        vst[h] = Voice.SCHEDULED
    end
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
