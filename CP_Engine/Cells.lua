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

-- Le sentinel du JSFX : « pas encore de date, j'attends une horloge ».
local WAIT_TEST = -1e8

local NATIVE = false

-- Etat par colonne. Prealloue une fois : ce module est interroge a chaque frame.
local col = {}

local function newSlot()
    return {
        path = nil, clip = nil,
        rate = 1.0,
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
function Cells.Arm(t, lane, path, rate)
    -- Chaque echec rend SA raison. « pas de son » sans raison coute une soiree ;
    -- la raison coute une chaine de caracteres.
    if not NATIVE or t < 0 or t >= TRACKS then return false, "no_engine" end
    if not ensurePort(t) then return false, "no_track" end
    local slot = col[t].half[(lane >= TRACKS) and 1 or 0]
    if not ensureVoices(t, slot) then return false, "no_voice" end

    if slot.path ~= path then
        if slot.path then clipUnref(slot.path) end
        local e, why = clipRef(path)
        if not e then slot.path, slot.clip = nil, nil return false, why end
        slot.path, slot.clip = path, e
        slot.armed = false
    end
    slot.rate = (rate and rate > 0.05 and rate < 20) and rate or 1.0
    return true
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
local function playAt(slot, at, phase, len_beats, gate)
    if not slot.clip or not at or at < 0 then return end
    local tempo = Loop.Tempo()
    if not tempo or tempo <= 0 then tempo = 120 end
    local spb = 60.0 / tempo

    -- Ce qu'il reste a jouer avant la porte. La porte existe pour la meme raison
    -- qu'avec le RS5K : le son doit finir avant la passe suivante, sinon la voix
    -- suivante commence pendant que celle-ci sonne encore.
    local left = (len_beats * (gate or 0.97)) - phase
    if left <= 0.01 then return end

    local h = slot.v[slot.vi]
    slot.vi = (slot.vi == 1) and 2 or 1     -- l'autre voix pour la passe suivante
    if not h then return end

    local opts = slot.opts
    if not opts then opts = {} slot.opts = opts end
    opts.rate = slot.rate
    opts.gain = 1.0
    opts.loop = false
    if phase > 0 then
        -- La position dans la MATIERE, pas dans le temps : la voix avance de
        -- rate * srate_clip echantillons source par seconde de sortie.
        opts.offset = math.floor(phase * spb * slot.clip.srate * slot.rate + 0.5)
        if opts.offset >= slot.clip.frames then return end
    else
        opts.offset = nil                   -- la table est reutilisee : effacer
    end

    if Voice.PlayAtSample(h, slot.clip.id, at, opts) then
        slot.last_start = at
        Voice.StopAtSample(h, at + math.floor(left * spb * Voice.Srate() + 0.5), 0.005)
    end
end

-- Une moitie de lane, une frame.
local function drive(t, half, gate)
    local slot = col[t].half[half]
    if not slot.clip then return end

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
            -- passe plutot que d'attendre la suivante.
            if slot.dated then slot.dated = false
            else playAt(slot, Voice.Now(), phase, lenb, gate) end
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
    Voice.Sync()
    for t = 0, TRACKS - 1 do
        drive(t, 0, gate)
        drive(t, 1, gate)
    end
end

-- ---------------------------------------------------------------------------
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
    if not NATIVE then return "cells=rs5k" end
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
