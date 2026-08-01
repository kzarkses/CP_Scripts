-- CP_Engine — Cells
--
-- UNE CASE AUDIO DEVIENT UNE VOIX. Le RS5K et sa piste enfant disparaissent.
--
-- ---------------------------------------------------------------------------
-- CE QUE CA REMPLACE, ET POURQUOI C'ETAIT LOURD
-- ---------------------------------------------------------------------------
-- Jusqu'ici, faire sonner un fichier dans une case demandait : une piste
-- ENFANT par colonne (« … smp »), DEUX RS5K dedans (un par moitie de lane, pour
-- qu'un echange en attente ne fasse pas jouer le nouveau fichier a l'ancien
-- clip), un envoi filtre depuis le routeur, un canal MIDI reserve, et un clip
-- MIDI d'UNE note synthetise a la volee dont la longueur porte la porte a 97 %.
--
-- Six pieces pour dire « joue ce fichier a partir de cette mesure ». Le moteur
-- natif le dit en un appel, et il le dit a l'echantillon pres.
--
-- Ce qui NE change pas : la lane reste la machine a etats. Le clip d'une note
-- continue d'exister, la file d'attente, l'echange sur la frontiere, le suivi,
-- l'arret — tout cela est deja bon et n'a aucune raison d'etre reecrit. Ce
-- module ne remplace que le PRODUCTEUR DE SON au bout de la chaine.
--
-- ---------------------------------------------------------------------------
-- LA PIECE QUI REND CA POSSIBLE : LE MOTEUR PUBLIE SA PROPRE FRONTIERE
-- ---------------------------------------------------------------------------
-- On ne PREDIT pas ou tombe un lancement quantifie. Le JSFX ecrit sa decision
-- dans gmem (`pend_target`, un beat), et Lua la lit puis la convertit en frame
-- absolu. Il n'y a donc pas deux horloges qui pourraient diverger : il y a une
-- decision, prise a un seul endroit, et une conversion.
--
-- C'est la meme discipline que le reste du moteur : demander a l'instrument
-- plutot que deduire. Une prediction Lua du « prochain multiple de Q » aurait
-- semble juste et se serait trompee exactement dans les cas ou ca compte —
-- horloge libre, changement de tempo, demarrage entre deux mesures.
--
-- Les passes suivantes se raccrochent a la PHASE de la lane, relue a chaque
-- frame. Aucun accumulateur, donc aucune derive possible : si le moteur et nous
-- ne sommes pas d'accord, le desaccord est corrige au tour suivant au lieu de
-- s'additionner.
--
-- ---------------------------------------------------------------------------
-- DEUX MOITIES, DEUX JEUX DE VOIX — pour la meme raison qu'il y avait deux RS5K
-- ---------------------------------------------------------------------------
-- Tant qu'un lancement est en attente, DEUX clips existent : celui qui sonne
-- encore et celui qui attend la frontiere. Avec un seul jeu de voix, armer la
-- case entrante chargerait son fichier tout de suite, et ce qui sonne encore
-- jouerait deja le NOUVEAU son. Chaque moitie de lane a donc les siennes.
--
-- Et deux voix par moitie, parce qu'une passe doit pouvoir etre armee pendant
-- que la precedente sonne encore : relancer la meme voix la couperait net.

local Cells = {}

local r, Voice, Loop
local TRACKS = 4

-- Combien de beats a l'avance on arme une passe. Une frame de defer vaut 16 a
-- 74 ms ; un beat en vaut 500 a 120 BPM. La marge est de deux ordres de
-- grandeur, et c'est exactement ce que le moteur natif rend possible : decider
-- tot, tomber juste.
local LOOKAHEAD_BEATS = 1.0

-- L'HORLOGE BAT-ELLE ? Relue UNE fois par frame dans Cells.Tick, parce que la
-- reponse traverse deux appels d'ABI et que `drive` passe huit fois.
local clock_on = true

-- EN DESSOUS DE CE RETARD, UN DEPART QU'ON N'A PAS VU VENIR A BEL ET BIEN
-- COMMENCE A LA PHASE ZERO — on ne l'a su qu'apres.
--
-- Le moteur lance parfois une lane IMMEDIATEMENT : quantize a zero, ou premier
-- lancement d'une session silencieuse, ou l'on tombe juste apres une
-- frontiere. Aucune cible en attente n'est alors publiee, donc Lua ne
-- l'apprend qu'a la frame suivante et passe par le rattrapage — qui entre dans
-- la MATIERE a la phase courante. Sur une boucle longue c'est exactement ce
-- qu'il faut ; sur un son percussif, ces 16 a 40 ms sont l'attaque, et on
-- l'entend disparaitre. Le symptome ressemble a un fondu d'entree ; ce n'en
-- est pas un, et c'est pourquoi on ne le trouvait pas du cote des fondus.
--
-- Le seuil vaut deux frames de defer, exprime en secondes parce que ce retard
-- est du temps mur et non de la musique.
local CATCHUP_SNAP_S = 0.080

-- Le sentinel du JSFX : « pas encore de date, j'attends une horloge ».
local WAIT_TEST = -1e8

local NATIVE = false

-- LA VITESSE DE LECTURE DU PROJET, relue une fois par frame et gardee ici.
--
-- Elle entre dans ce module par deux portes qu'il ne faut pas confondre :
--   · une passe DURE moins d'echantillons quand le projet va plus vite, donc
--     toute conversion secondes -> frames se divise par elle ;
--   · un son deja lance doit accelerer AVEC le projet, donc le taux de la voix
--     se multiplie par elle. C'est un varispeed, comme la reglette de REAPER
--     sans « preserve pitch » : la hauteur monte, et c'est le comportement
--     attendu d'un lanceur d'echantillons.
-- On garde la derniere valeur pour ne pousser un nouveau taux aux voix que
-- lorsqu'elle CHANGE : ecrire le meme taux a chaque frame serait une commande
-- par voix et par frame pour rien.
local prate      = 1.0
local prate_last = 1.0

-- Etat par colonne. Prealloue une fois : ce module est interroge a chaque frame.
local col = {}

local function newSlot()
    return {
        path = nil, clip = nil,
        rate = 1.0,
        loop = false,       -- la matiere se repete-t-elle dans sa passe
        v = { nil, nil }, vi = 1,
        armed = false,      -- une passe est deja armee pour la frontiere qui vient
        dated = false,      -- ce depart-la a ete date : ne pas le rattraper
        running = false,
        last_start = -1,    -- diagnostic : frame demande de la derniere passe
        last_real = -1,     -- diagnostic : frame reellement atteint (verite terrain)
    }
end

-- Un clip decode est garde tant que la case le reference. Deux cases sur le
-- meme fichier partagent le meme clip : le vivier du moteur est une ressource
-- globale, pas une propriete de colonne.
local clips = {}    -- [path] = { id, frames, srate, refs }

-- Ou verser le son d'une colonne. Fournie par la fenetre, parce que la reponse
-- est une decision de projet et non de moteur — voir SetDestResolver.
local dest_fn = nil

function Cells.init(reaper_api, voice_module, loop_module, ntracks)
    r = reaper_api
    Voice = voice_module
    Loop = loop_module
    TRACKS = ntracks or 4
    NATIVE = Voice.CanScheduleExact() and Voice.MaxVoices() > 1
    for t = 0, TRACKS - 1 do
        col[t] = { dest = false, half = { [0] = newSlot(), [1] = newSlot() } }
    end
    return NATIVE
end

-- Le moteur peut-il porter les cases audio ? Si non, l'appelant garde son
-- chemin RS5K, et il le sait d'avance au lieu de le decouvrir en silence.
function Cells.Available() return NATIVE end

-- OU VERSER LE SON, et c'est le point delicat de tout ce module.
--
-- Une piste dont la chaine contient un INSTRUMENT avale l'audio qu'on y verse :
-- l'instrument ecrit sa propre sortie par-dessus le tampon. Une colonne qui joue
-- des notes ne peut donc pas recevoir directement le son de ses cases — c'est
-- exactement pour ca que le montage RS5K passait par une piste enfant, et ce
-- n'etait pas un caprice.
--
-- La reponse depend du projet, pas du moteur : la fenetre la fournit. Une
-- colonne SANS instrument recoit directement et ne coute plus une seule piste ;
-- une colonne avec instrument garde un enfant, mais vide — plus de RS5K, plus de
-- fenetre de plugin qui s'ouvre, plus d'ecriture de parametre a chaque
-- armement.
function Cells.SetDestResolver(fn) dest_fn = fn end

-- ---------------------------------------------------------------------------
-- Matiere
-- ---------------------------------------------------------------------------
local function clipRef(path)
    local e = clips[path]
    if e then e.refs = e.refs + 1 return e end
    local id, why = Voice.Load(path)
    if not id then return nil, why end
    local dur, _, srate = Voice.ClipInfo(id)
    if not dur or not srate or srate <= 0 then Voice.Unload(id) return nil, "failed" end
    e = { id = id, frames = math.floor(dur * srate + 0.5), srate = srate, refs = 1 }
    clips[path] = e
    return e
end

local function clipUnref(path)
    local e = clips[path]
    if not e then return end
    e.refs = e.refs - 1
    if e.refs > 0 then return end
    Voice.Unload(e.id)
    clips[path] = nil
end

-- ---------------------------------------------------------------------------
-- Sortie — une colonne, un port, la piste de la colonne
--
-- Le son entre PRE-FX : il traverse la chaine d'effets de la colonne, son
-- fader, son VU et ses envois. C'est exactement la place qu'occupait la piste
-- enfant, moins la piste enfant.
-- ---------------------------------------------------------------------------
local function ensurePort(t)
    if not NATIVE then return false end
    local c = col[t]
    local dest = dest_fn and dest_fn(t) or Loop.GetLaneDest(t)
    if not (dest and r.ValidatePtr2(0, dest, "MediaTrack*")) then return false end
    if c.dest == dest and Voice.OutputActive(t) then return true end

    -- LE MOTEUR SURVIT AU SCRIPT, et c'est le piege de cette fonction.
    --
    -- L'extension est chargee une fois par REAPER ; ce script meurt et repart
    -- vingt fois par soiree, et pas toujours par sa fermeture propre. Un port
    -- peut donc etre DEJA attache — a la piste d'une execution precedente, voire
    -- a une piste supprimee depuis. Et l'attache est idempotente : elle repond
    -- « oui, deja fait » sans rien rebrancher. On croirait tenir la bonne piste
    -- et on verserait le son dans l'ancienne, ou dans rien.
    --
    -- On detache donc TOUJOURS avant de brancher. Detacher un port inactif ne
    -- coute rien ; se tromper de piste coute une soiree a comprendre.
    do
        Voice.UnbindTrack(t)
        for h = 0, 1 do
            local s = c.half[h]
            s.v[1], s.v[2] = nil, nil
            s.armed, s.running = false, false
        end
    end
    if not Voice.BindTrack(t, dest) then return false end
    c.dest = dest
    return true
end

local function ensureVoices(t, slot)
    for i = 1, 2 do
        if not slot.v[i] then
            local h = Voice.Alloc(t)
            if not h then return false end
            -- Un fondu est une PROPRIETE de voix, et le moteur la garde d'un
            -- lancement a l'autre : kCmdVoicePlay ne remet a zero que les
            -- positions. Une case percussive n'en veut aucun, et le dire une
            -- fois a l'allocation vaut mieux que de l'esperer.
            Voice.Set(h, "fade_in", 0)
            slot.v[i] = h
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Armement d'une case dans une moitie de lane
-- ---------------------------------------------------------------------------
-- Appelee a chaque armement, donc IDEMPOTENTE et silencieuse : le fichier n'est
-- relu que lorsqu'il change reellement.
-- `loop` : la matiere se repete-t-elle pour remplir sa passe ? Faux par defaut,
-- parce que le defaut d'un fichier depose est d'etre joue une fois. Une vraie
-- boucle musicale n'a pas besoin du drapeau — elle remplit sa passe toute
-- seule ; le drapeau sert a celle qui est plus COURTE que sa passe et qui doit
-- quand meme tourner (un shaker d'un temps sous une case d'une mesure).
-- `offs`, `len`, `gain` : LA REGION ET LE NIVEAU, enfin lus. Ils voyagent dans
-- le format depuis le debut et n'avaient AUCUN consommateur — une selection de
-- deux mesures glissee depuis l'editeur jouait le fichier entier, et
-- l'aller-retour editeur/case mentait. Tout existait pourtant dessous : le
-- moteur porte loop_start / loop_end / pos / gain en frames source.
-- offs et len sont en SECONDES DE SOURCE (le contrat de Clip.lua) ; la
-- conversion en frames se fait au lancement, ou la frequence du fichier est
-- connue.
function Cells.Arm(t, lane, path, rate, loop, offs, len, gain)
    -- Chaque echec rend SA raison. « pas de son » sans raison coute une soiree ;
    -- la raison coute une chaine de caracteres.
    if not NATIVE or t < 0 or t >= TRACKS then return false, "no_engine" end
    if not ensurePort(t) then return false, "no_track" end
    local slot = col[t].half[(lane >= TRACKS) and 1 or 0]
    if not ensureVoices(t, slot) then return false, "no_voice" end

    if slot.path ~= path then
        -- LA MATIERE NE PART PAS SOUS UN SON EN COURS. Decharger un clip le
        -- rend invisible du fil audio des le bloc suivant : la voix n'a plus
        -- rien a lire et meurt SANS FONDU, ce qui s'entend comme un clic.
        -- Le pool est sur — il attend deux blocs avant de liberer, et get()
        -- ne rend plus rien des la mise au rebut — donc ce n'est pas une
        -- lecture apres liberation, c'est une coupure seche. On coupe donc
        -- proprement d'abord. Changer le mode tempo d'une case qui sonne
        -- passe exactement par ici.
        for i = 1, 2 do
            if slot.v[i] then Voice.Stop(slot.v[i], 0.008) end
        end
        if slot.path then clipUnref(slot.path) end
        local e, why = clipRef(path)
        if not e then slot.path, slot.clip = nil, nil return false, why end
        slot.path, slot.clip = path, e
        slot.armed = false
    end
    slot.rate = (rate and rate > 0.05 and rate < 20) and rate or 1.0
    slot.loop = loop and true or false
    slot.offs = (offs and offs > 0) and offs or 0
    slot.len  = (len and len > 0) and len or nil
    slot.gain = (gain and gain > 0) and gain or 1.0
    return true
end

-- La region se change a la volee, comme le taux : redecouper une case ne doit
-- pas couter un rechargement de la matiere.
function Cells.Region(t, lane, offs, len, gain)
    if not NATIVE or t < 0 or t >= TRACKS then return end
    local slot = col[t].half[(lane >= TRACKS) and 1 or 0]
    slot.offs = (offs and offs > 0) and offs or 0
    slot.len  = (len and len > 0) and len or nil
    slot.gain = (gain and gain > 0) and gain or 1.0
end

-- Le taux se change a la volee : le tempo du projet peut avoir bouge depuis le
-- dernier lancement, et ca ne coute pas un rechargement.
function Cells.Retune(t, lane, rate)
    if not NATIVE or t < 0 or t >= TRACKS then return end
    local slot = col[t].half[(lane >= TRACKS) and 1 or 0]
    slot.rate = (rate and rate > 0.05 and rate < 20) and rate or 1.0
end

-- Cette moitie ne porte plus de son (la case est devenue MIDI, ou vide).
function Cells.Disarm(t, lane)
    if not NATIVE or t < 0 or t >= TRACKS then return end
    local slot = col[t].half[(lane >= TRACKS) and 1 or 0]
    for i = 1, 2 do if slot.v[i] then Voice.Stop(slot.v[i], 0.005) end end
    if slot.path then clipUnref(slot.path) end
    slot.path, slot.clip = nil, nil
    slot.armed, slot.running = false, false
end

-- ---------------------------------------------------------------------------
-- Conversion beat -> frame absolu
--
-- Deux cas, et il faut les distinguer : en suivi de transport le beat du moteur
-- EST la position QN du projet, donc la carte de tempo repond exactement, meme
-- avec un marqueur de tempo dans la fenetre. En horloge libre elle ne veut rien
-- dire — le transport est arrete — et seule la difference a maintenant a un
-- sens.
-- ---------------------------------------------------------------------------
local function beatToFrame(beat)
    if Loop.GetFreeRun() then
        local tempo = Loop.Tempo()
        if not tempo or tempo <= 0 then tempo = 120 end
        local d = (beat - Loop.EngineBeat()) * 60.0 / tempo
        -- Pas de division par prate ici, et c'est voulu : l'horloge libre est
        -- le transport de la SESSION. La reglette de vitesse est une propriete
        -- du transport de l'hote, et il n'y a pas d'hote quand on tourne libre.
        return Voice.Now() + math.floor(d * Voice.Srate() + 0.5)
    end
    return Voice.BeatToSample(beat)
end

-- ---------------------------------------------------------------------------
-- Le pilote
-- ---------------------------------------------------------------------------
local function stopSlot(slot, fade)
    for i = 1, 2 do if slot.v[i] then Voice.Stop(slot.v[i], fade or 0.005) end end
    slot.armed = false
    slot.dated = false
    slot.running = false
end

-- FAIRE SONNER UNE PASSE — et il n'y en a qu'une facon.
--
-- `at` est un frame absolu, `phase` la position DANS LA BOUCLE en beats. Les
-- deux sont necessaires et c'est le cœur de ce module : la phase d'une lane est
-- ancree sur le beat ZERO de la timeline, jamais sur l'instant du lancement.
-- Lancer a la mesure 2 une boucle de quatre mesures ne rejoue pas le fichier
-- depuis le debut — il entre a sa deuxieme mesure. C'est ce qui verrouille
-- toutes les boucles sur la meme grille, et c'est exactement ce que faisait le
-- clip d'une note. Le son doit faire pareil, sinon il flotte.
local function playAt(slot, at, phase, len_beats, gate, snap)
    if not slot.clip or not at or at < 0 then return end
    local tempo = Loop.Tempo()
    if not tempo or tempo <= 0 then tempo = 120 end
    local spb = 60.0 / tempo

    -- Un depart qu'on apprend avec deux frames de retard a commence a zero.
    -- Voir CATCHUP_SNAP_S : rabattre la phase AVANT de calculer ce qu'il reste,
    -- pour que la passe garde sa longueur entiere.
    if snap and phase > 0 and phase * spb < CATCHUP_SNAP_S then phase = 0 end

    -- BOUCLE OU ONE-SHOT — et par defaut, ONE-SHOT.
    --
    -- Ce module a essaye les deux mauvaises reponses avant celle-ci. Jouer la
    -- passe une seule fois donnait un kick suivi d'un long silence, parce que
    -- la passe durait quatre mesures ; faire boucler la MATIERE pour combler ce
    -- silence a remplace un trou par une mitraillette — un kick de 0,4 s sort
    -- cinq fois par mesure, a la duree du fichier, hors de toute grille. Un
    -- crash, un riser, un stab : inutilisables.
    --
    -- La bonne reponse n'etait ni l'une ni l'autre : c'est que la LONGUEUR DE
    -- PASSE doit venir du fichier (elle en vient depuis ce matin) et que le
    -- contenu doit dire s'il se repete. Un one-shot joue une fois par passe,
    -- point — et c'est ce que fait Ableton d'un clip dont la boucle est
    -- desactivee : « An unlooped clip will play from its start point to its end
    -- point or until it is stopped. »
    --
    -- `slot.loop` vient de la case (Clip.lmode, un champ qui existait dans le
    -- format depuis toujours et que personne ne lisait).
    local loop_m = slot.loop and true or false

    -- LA PASSE VA JUSQU'AU BOUT — et la porte de 97 % qui vivait ici etait un
    -- reliquat du RS5K.
    --
    -- Elle existait parce qu'UN sampler ne peut pas jouer deux fois le meme
    -- echantillon : il fallait que le son ait fini avant que la passe suivante
    -- le redeclenche. Ce module a DEUX voix par moitie, et son propre en-tete
    -- dit pourquoi : « une passe doit pouvoir etre armee pendant que la
    -- precedente sonne encore ». La contrainte n'existe plus ; la porte, si.
    --
    -- Ce qu'elle coutait : trois pour cent de chaque passe, tranches. Sur une
    -- boucle de quatre mesures a 115 BPM, 250 ms de queue coupee a chaque tour
    -- — le son s'arrete avant la frontiere, la boucle n'est pas fluide, et
    -- l'enregistrement de la piste le montre en un coup d'oeil face au fichier
    -- d'origine.
    --
    -- `gate` reste dans la signature : il decrit la note du clip d'une note que
    -- la lane porte encore (muette), pas la duree du son.
    local left = len_beats - phase
    if left <= 0.01 then return end

    local h = slot.v[slot.vi]
    slot.vi = (slot.vi == 1) and 2 or 1     -- l'autre voix pour la passe suivante
    if not h then return end

    local opts = slot.opts
    if not opts then opts = {} slot.opts = opts end
    -- Le taux du fichier fois celui du projet. Les deux se composent parce
    -- qu'ils disent la meme chose a deux echelles : « joue ce materiau plus
    -- vite ».
    opts.rate = slot.rate * prate
    opts.gain = slot.gain or 1.0
    opts.loop = loop_m

    -- LA REGION, EN FRAMES SOURCE. Le moteur boucle entre loop_start et
    -- loop_end ; sans eux il boucle sur le fichier entier, ce qu'il a fait
    -- jusqu'ici. Les bornes sont calculees ici et non a l'armement parce que
    -- c'est ici qu'on tient la frequence du fichier.
    local sr = slot.clip.srate or Voice.Srate()
    local f0 = math.floor((slot.offs or 0) * sr + 0.5)
    if f0 < 0 then f0 = 0 elseif f0 >= slot.clip.frames then f0 = 0 end
    local f1 = slot.len and math.floor(f0 + slot.len * sr + 0.5)
                        or slot.clip.frames
    if f1 > slot.clip.frames then f1 = slot.clip.frames end
    if f1 <= f0 then f1 = slot.clip.frames end
    opts.loop_start = f0
    opts.loop_end   = f1
    local reglen = f1 - f0
    -- ENTRER EN COURS DE PASSE N'A DE SENS QUE POUR UNE BOUCLE.
    --
    -- Une boucle de quatre mesures lancee a la mesure 2 doit entrer a sa
    -- deuxieme mesure : c'est ce qui verrouille toutes les boucles sur la meme
    -- grille. Un ONE-SHOT n'a pas de phase — on ne rejoint pas un kick au
    -- milieu. Et surtout : le calcul suivant sortait au-dela du fichier et la
    -- fonction rendait la main SANS RIEN JOUER. C'est le « le clip ne demarre
    -- pas » d'un lancement rejoint en retard sur un son court, et ca dependait
    -- du sample — ce qui le rendait incomprehensible.
    if loop_m and phase > 0 then
        -- La position dans la MATIERE, pas dans le temps. Et le taux du PROJET
        -- n'entre pas ici : `phase * spb` est deja une duree de projet, et une
        -- seconde de projet consomme toujours `srate_clip * slot.rate`
        -- echantillons source, quelle que soit la vitesse a laquelle elle
        -- passe. Multiplier par prate aurait fait entrer la boucle deux fois
        -- trop loin a vitesse 2 — l'erreur qui ressemble le plus a un bug de
        -- phase alors qu'elle est de conversion.
        local o = math.floor(phase * spb * sr * slot.rate + 0.5)
        -- Au-dela de la matiere, on replie plutot que de se taire : une boucle
        -- rejointe passe sa fin, elle ne disparait pas. Le repli se fait sur la
        -- REGION et non sur le fichier — c'est toute la difference entre une
        -- tranche de break qui tourne sur elle-meme et une qui repart au debut
        -- du fichier.
        if reglen > 0 then o = o % reglen end
        opts.offset = f0 + o
    else
        -- UN ONE-SHOT AUSSI COMMENCE A SA REGION. Laisser l'offset a nil le
        -- faisait partir a zero, donc jouer le debut du fichier au lieu de la
        -- tranche demandee : c'est precisement le defaut qu'on ferme.
        opts.offset = (f0 > 0) and f0 or nil
    end

    if Voice.PlayAtSample(h, slot.clip.id, at, opts) then
        slot.last_start = at
        -- `left * spb` est une duree de PROJET : a vitesse 2 elle se parcourt
        -- en deux fois moins d'echantillons.
        local dur = math.floor(left * spb * Voice.Srate() / prate + 0.5)
        -- LE FONDU COMMENCE A LA FRONTIERE, IL NE S'Y TERMINE PAS.
        --
        -- Le moteur fait atteindre zero au rendez-vous : demander l'arret A la
        -- frontiere ferait donc descendre le son AVANT elle, et rouvrirait en
        -- petit le trou qu'on vient de fermer. On decale le rendez-vous de la
        -- longueur du fondu : la voix sortante s'eteint pendant que l'entrante
        -- attaque, ce qui est un vrai fondu croise de cinq millisecondes — et
        -- c'est exactement pour ca qu'une moitie possede DEUX voix.
        local fade = 0.005
        Voice.StopAtSample(h, at + dur + math.floor(fade * Voice.Srate() + 0.5),
                           fade)
    end
end

-- Une moitie de lane, une frame.
local function drive(t, half, gate)
    local slot = col[t].half[half]
    if not slot.clip then return end

    -- L'HORLOGE S'EST ARRETEE : ON TAIT LE SON, ON NE TOUCHE PAS A L'ETAT.
    --
    -- Une lane arretee ne sonne plus d'elle-meme — elle n'a plus de beat qui
    -- avance. Une VOIX, si : elle a recu une date de depart et une duree en
    -- frames, et l'appareil continue de tourner. C'est pour la faire taire que
    -- Loop demandait l'arret de la lane a chaque stop du transport, et c'est
    -- ce detour qui coutait l'etat de lecture de toute la grille.
    --
    -- On coupe donc ici, ou est le probleme. `stopSlot` remet `running` a faux,
    -- ce qui suffit a faire repartir la passe au retour du transport : `drive`
    -- verra mode 3 sans voix qui tourne et rentrera en cours de passe, sur la
    -- phase que le moteur publie. Suspendre et reprendre, plutot qu'eteindre.
    if not clock_on then
        if slot.running or slot.armed then stopSlot(slot) end
        return
    end

    local lane = (half == 0) and t or (t + TRACKS)
    local mode = math.floor((Loop.Mode(lane) or 0) + 0.5)
    local pend = Loop.Pending(lane) or 0
    local tgt  = Loop.PendingTarget(lane) or 0
    local lenb = Loop.LenBeats(lane) or 4
    if lenb <= 0 then lenb = 4 end

    -- LE LANCEMENT. On lit la decision du moteur, on ne la refait pas. Un
    -- sentinel (« j'attends une horloge ») n'est pas une date : on repasse.
    if pend == 1 then
        if tgt > WAIT_TEST and not slot.armed then
            -- On part a la frontiere que le moteur a choisie, PAS a la fin de
            -- boucle suivante — et decale de la phase qu'aura la lane a cet
            -- instant. C'etait la faute : un lancement quantifie entrait au
            -- prochain multiple de la longueur, et depuis le debut du fichier.
            playAt(slot, beatToFrame(tgt), tgt - math.floor(tgt / lenb) * lenb,
                   lenb, gate)
            slot.armed = true
            slot.dated = true    -- ce depart est date : rien a rattraper
        end
        return
    end

    -- L'ARRET DATE. Il ne coupe rien tout de suite : la lane continue de tourner
    -- jusqu'a sa frontiere, et le son doit continuer avec elle. On se contente de
    -- ne plus armer de passe AU-DELA de la date — couper maintenant tronquerait
    -- la mesure en cours, ce qu'un arret quantifie promet precisement de ne pas
    -- faire. Une quantification longue (quatre mesures sur une boucle d'une)
    -- passe donc plusieurs fois ici avant de s'arreter.
    local stop_beat = (pend == 2 and tgt > WAIT_TEST) and tgt or nil

    if mode == 3 or mode == 5 then
        local phase = Loop.Phase(lane) or 0
        if not slot.running then
            slot.running = true
            -- Personne ne nous avait annonce ce depart : on entre en cours de
            -- passe plutot que d'attendre la suivante. C'est le SEUL appel qui
            -- demande le rabat de phase — les deux autres partent d'une date que
            -- le moteur a choisie, donc d'une phase exacte.
            if slot.dated then slot.dated = false
            else playAt(slot, Voice.Now(), phase, lenb, gate, true) end
        end
        -- LES PASSES SUIVANTES SE RACCROCHENT A LA PHASE DU MOTEUR, relue a
        -- chaque frame. Pas d'accumulateur, donc pas de derive : un desaccord
        -- est corrige au tour suivant au lieu de s'additionner.
        local to_next = lenb - phase
        -- L'avance ne peut pas depasser une demi-passe : sur une boucle plus
        -- courte que l'avance, la condition serait vraie en permanence et une
        -- seule passe serait jamais armee.
        local look = LOOKAHEAD_BEATS
        if look > lenb * 0.5 then look = lenb * 0.5 end
        if to_next <= look then
            if not slot.armed then
                local at = Loop.EngineBeat() + to_next
                if not (stop_beat and at >= stop_beat - 1e-6) then
                    -- Une frontiere de passe : la phase y vaut zero.
                    playAt(slot, beatToFrame(at), 0, lenb, gate)
                end
                slot.armed = true
            end
        elseif to_next > look then
            slot.armed = false
        end
        return
    end

    -- Ni en attente, ni en train de jouer : cette moitie est silencieuse.
    if slot.running or slot.armed then stopSlot(slot) end
end

-- A appeler UNE fois par frame, apres Loop.Poll().
function Cells.Tick(gate)
    if not NATIVE then return end
    clock_on = Loop.ClockRunning()
    Voice.Sync()
    prate = Voice.PlayRate()

    -- LA REGLETTE A BOUGE PENDANT QUE CA SONNE. Les passes futures partiront au
    -- bon taux toutes seules — elles le lisent au lancement. Ce qui sonne DEJA,
    -- non : sa voix garde le taux qu'elle avait, et le son se separerait du
    -- projet jusqu'a la fin de la passe. On le pousse donc a la volee, ce que
    -- le moteur accepte sans faire repartir la lecture du debut.
    --
    -- Et on DEFAIT ce qui etait en file sans encore sonner : sa date de depart
    -- a ete calculee a l'ancienne vitesse et ne vaut plus rien. On l'annule
    -- plutot que de la laisser tomber a cote — une passe pas encore audible
    -- s'annule sans bruit, c'est le seul moment ou c'est gratuit — et on rend
    -- son emplacement de voix pour que drive() la reprogramme dans la MEME,
    -- sans quoi les deux voix de la moitie finiraient armees sur la meme passe
    -- et on l'entendrait deux fois.
    --
    -- Ce qui SONNE deja n'est pas touche : sa date de fin est desormais un peu
    -- fausse, mais la passe suivante se raccroche a la phase publiee par le
    -- moteur, donc la grille se rattrape en une passe. Couper ce qu'on entend
    -- pour corriger sa queue serait payer une coupure pour un detail de queue.
    if prate ~= prate_last then
        prate_last = prate
        for t = 0, TRACKS - 1 do
            for h = 0, 1 do
                local slot = col[t].half[h]
                if slot.clip then
                    for i = 1, 2 do
                        if slot.v[i] then
                            Voice.Set(slot.v[i], "rate", slot.rate * prate)
                        end
                    end
                    if slot.armed then
                        local qi = (slot.vi == 1) and 2 or 1   -- la derniere armee
                        if slot.v[qi] then Voice.Stop(slot.v[qi], 0.002) end
                        slot.vi = qi
                        slot.armed = false
                        slot.dated = false
                    end
                end
            end
        end
    end

    for t = 0, TRACKS - 1 do
        drive(t, 0, gate)
        drive(t, 1, gate)
    end
end

-- ---------------------------------------------------------------------------
-- OU EN EST LE SON, entre 0 et 1 de sa matiere.
--
-- La barre de progression d'une case affichait la PHASE DE LA LANE, qui est une
-- position sur la grille : « ou en est la mesure », pas « ou en est le fichier ».
-- Les deux ne coincident que si la matiere remplit exactement sa passe — c'est
---a-dire presque jamais pour un one-shot, qui se tait pendant que la barre
-- continue d'avancer. La voix publie sa propre position depuis toujours
-- (Voice.State rend etat ET position) et personne ne la lisait.
--
-- Rend nil quand rien ne sonne : l'appelant retombe alors sur la phase, qui
-- reste la bonne reponse pour une lane MIDI.
function Cells.Progress(t)
    if not NATIVE then return nil end
    local c = col[t]
    if not c then return nil end
    for h = 0, 1 do
        local slot = c.half[h]
        if slot.running and slot.clip and slot.clip.frames > 0 then
            local hv = slot.v[slot.vi]
            if hv then
                local st, pos = Voice.State(hv)
                if st == Voice.PLAYING and pos then
                    local f = pos / slot.clip.frames
                    if f < 0 then f = 0 elseif f > 1 then f = 1 end
                    return f
                end
            end
        end
    end
    return nil
end

-- Diagnostic — l'ecart entre ce qu'on a demande et ce qui a ete joue
--
-- La lecon de la campagne du moteur : ne pas expliquer un ecart, se donner les
-- moyens de le voir. StartedAt est note par la voix elle-meme, donc sans course.
-- ---------------------------------------------------------------------------
function Cells.LastOnsetError(t, lane)
    if not NATIVE then return nil end
    local slot = col[t] and col[t].half[(lane >= TRACKS) and 1 or 0]
    if not slot or slot.last_start < 0 then return nil end
    local h = slot.v[(slot.vi == 1) and 2 or 1]
    if not h then return nil end
    local real = Voice.StartedAt(h)
    if not real or real < 0 then return nil end
    return real - slot.last_start
end

function Cells.Diag()
    -- « cells=rs5k » etait la reponse d'avant : ce module n'a plus de chemin
    -- RS5K du tout, et repondre un backend qui n'existe pas est pire que ne
    -- rien repondre.
    if not NATIVE then return "cells: silent (no engine)" end
    local n, c = 0, 0
    for t = 0, TRACKS - 1 do
        for h = 0, 1 do
            if col[t].half[h].clip then n = n + 1 end
            if col[t].half[h].running then c = c + 1 end
        end
    end
    local nc = 0
    for _ in pairs(clips) do nc = nc + 1 end
    return string.format("voices armed=%d sounding=%d clips=%d", n, c, nc)
end

-- Y a-t-il quelque chose a dire ? Sert a n'occuper la zone de statut que quand
-- le diagnostic apporte reellement une information.
function Cells.Armed()
    if not NATIVE then return false end
    for t = 0, TRACKS - 1 do
        if col[t].half[0].clip or col[t].half[1].clip then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Fermeture. Les voix et les ports sont rendus ; les clips aussi. La fenetre
-- peut mourir et revenir sans rien laisser derriere elle.
-- ---------------------------------------------------------------------------
function Cells.Destroy()
    if not NATIVE then return end
    for t = 0, TRACKS - 1 do
        local c = col[t]
        for h = 0, 1 do
            local slot = c.half[h]
            for i = 1, 2 do if slot.v[i] then Voice.Release(slot.v[i]) end end
            if slot.path then clipUnref(slot.path) end
            c.half[h] = newSlot()
        end
        if c.dest then Voice.UnbindTrack(t) c.dest = false end
    end
    for path, e in pairs(clips) do
        Voice.Unload(e.id)
        clips[path] = nil
    end
end

return Cells
