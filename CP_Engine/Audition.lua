-- CP_Engine — Audition
--
-- FAIRE ENTENDRE UN FICHIER A QUELQU'UN. Une seule fois pour toute la suite.
--
-- Le navigateur, l'editeur et le sampler font exactement le meme geste — on
-- clique, ca sonne — et chacun l'ecrit a sa facon. C'est le premier defaut
-- recense dans ANALYSE_Ecosysteme, et ce module est la capacite qui manquait.
--
-- ---------------------------------------------------------------------------
-- DEUX MOTEURS, ET C'EST DELIBERE
-- ---------------------------------------------------------------------------
-- Ce module choisit, a chaque lancement, entre :
--
--   UNE VOIX CP        exacte a l'echantillon, ne s'affame jamais (mesure :
--                      15 009 appels pour 15 009 blocs a un tampon de 64), et
--                      elle sort d'une matiere deja en RAM.
--   CF_Preview (SWS)   sait transposer et etirer, et lit depuis le disque —
--                      donc pas de plafond de duree, pas de decodage a payer.
--
-- Le choix ne demande JAMAIS « es-tu natif ». Il demande des capacites :
-- sait-on transposer sans changer la duree, sait-on etirer sans changer la
-- hauteur. Le jour ou le moteur saura le faire, ce fichier n'a pas une ligne a
-- changer.
--
-- Pourquoi ne pas tout passer en natif : l'etireur de REAPER coute 2,3 % du fil
-- audio par voix et exige 85 a 139 ms d'amorcage (mesure §12.12). Une audition
-- doit sonner dans le meme tour de boucle que la touche qui la declenche. Un
-- dixieme de seconde de retard est precisement ce que ce navigateur refuse
-- depuis le premier jour.
--
-- Pourquoi ne pas tout laisser a CF_Preview : au meme tampon de 64, il lisait a
-- 0,54x de sa vitesse — il s'affamait, et se taisait a ce sujet.
--
-- ---------------------------------------------------------------------------
-- CE QUE CA COUTE, ECRIT PLUTOT QUE DECOUVERT
-- ---------------------------------------------------------------------------
-- Une voix CP joue depuis la RAM : il faut donc DECODER avant d'entendre.
-- Mesure : environ 3,4 ms par seconde de stereo. Un one-shot de deux secondes
-- coute 7 ms, une boucle de quatre secondes 14 ms — moins qu'une frame de
-- dessin. Un fichier de trente secondes couterait 100 ms, ce qui s'entend comme
-- une hesitation. D'ou le seuil ci-dessous, et d'ou le prechauffage des voisins.

local Audition = {}

local r
local Voice, Preview

-- ---------------------------------------------------------------------------
-- Les deux seuls reglages de politique, isoles pour qu'ils se deplacent en une
-- ligne apres une ecoute.
-- ---------------------------------------------------------------------------

-- Au-dela, le decodage se ferait entendre : on laisse CF_Preview lire le
-- fichier depuis le disque. 15 s x 3,4 ms/s = environ 50 ms au pire.
local NATIVE_MAX_S = 15.0

-- Plafond du vivier local. Les clips y restent decodes pour que rejouer un
-- fichier soit gratuit ; au-dela, on jette le plus ancien.
local MAX_BYTES = 96 * 1024 * 1024

-- Prechauffer les voisins d'une selection. Le navigateur ne prefetche que
-- DEUX fichiers par changement de selection, et il le fait APRES avoir lance le
-- son — la regle « le son d'abord, la decoration ensuite ». Le decodage tombe
-- donc entre deux frames, jamais avant l'attaque.
Audition.warm_prefetch = true

-- ---------------------------------------------------------------------------
-- Reglages persistants. Meme forme que CF_Preview, pour qu'une fenetre qui
-- migre n'ait pas a reapprendre un vocabulaire.
-- ---------------------------------------------------------------------------
Audition.available    = false
Audition.volume       = 1.0     -- lineaire
Audition.pitch        = 0       -- demi-tons, duree preservee
Audition.rate         = 1.0     -- duree, hauteur preservee
Audition.loop         = false
Audition.route_track  = false   -- suivre la piste selectionnee
Audition.out_track    = nil     -- piste epinglee : elle prime sur route_track
Audition.playing_path = nil

-- Declic. Un depart et un arret sur une arete d'echantillon s'entendent sur
-- tout ce qui ne commence pas a zero, c'est-a-dire presque tout. 3 ms a
-- l'entree laissent un transitoire intact ; 8 ms a la sortie avalent la coupure.
Audition.fade_in  = 0.003
Audition.fade_out = 0.008

-- Derniere duree de decodage observee, en millisecondes. Diagnostic : c'est le
-- chiffre qui dit si NATIVE_MAX_S est au bon endroit sur CETTE machine.
Audition.last_load_ms = 0

-- ---------------------------------------------------------------------------
-- Etat interne
-- ---------------------------------------------------------------------------
local backend  = "none"   -- "native" | "preview" | "none"
local port     = nil
local bound_to = false    -- la sortie a laquelle le port est lie (false = aucune)
local vh       = nil      -- LA voix tenue : une audition, une voix, reutilisee
local cur      = nil      -- entree de vivier en cours de lecture

-- La section, quand c'est NOUS qui devons la tenir. Une voix native porte ses
-- points de boucle et n'a besoin de personne ; CF_Preview ne sait boucler que
-- la source entiere, donc le retour de boucle est surveille une fois par
-- frame (Audition.Poll). Ces deux champs ne servent qu'a ce second cas.
local sect_end   = nil
local sect_start = 0

-- Vivier local, indexe par chemin.
local clips      = {}
local clip_bytes = 0
local ctick      = 0

-- Table d'options reutilisee. Elle n'est pas dans un chemin par frame, mais la
-- regle de ce dossier est qu'on n'alloue pas pour parler au moteur.
local popts = {}

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function Audition.init(reaper_api)
    r = reaper_api
    local root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
    Preview = dofile(root .. "CP_Engine/Preview.lua")
    Voice   = dofile(root .. "CP_Engine/Voice.lua")
    Preview.init(r)
    Voice.init(r, Preview)
    -- « Quelque chose peut sonner » — pas « le moteur natif est la ». Les deux
    -- backends font entendre un fichier, et une fenetre qui annonce « aucun
    -- moteur d'audition » alors que SWS est installe ment a l'utilisateur.
    -- Le message que le navigateur affiche nomme d'ailleurs les deux.
    Audition.available = Voice.Available() or Preview.available
    return Audition.available
end

-- ---------------------------------------------------------------------------
-- Capacites — ce que l'appelant a le droit de demander
-- ---------------------------------------------------------------------------
function Audition.Backend() return backend end

function Audition.Diag()
    local n = 0
    for _ in pairs(clips) do n = n + 1 end
    return string.format("backend=%s clips=%d ram=%.1fMo decode=%.1fms exact=%s",
                         backend, n, clip_bytes / 1048576, Audition.last_load_ms,
                         tostring(Voice.CanScheduleExact()))
end

-- Un moteur de voix utilisable existe-t-il ? Trois capacites, aucune question
-- sur le backend : des voix multiples, un placement exact, et une sortie.
local function voicesUsable()
    return Voice.Available() and Voice.CanScheduleExact() and Voice.MaxVoices() > 1
end

-- ---------------------------------------------------------------------------
-- Sortie
-- ---------------------------------------------------------------------------
local function resolveOut()
    local out = Audition.out_track
    if out and not r.ValidatePtr2(0, out, "MediaTrack*") then
        out, Audition.out_track = nil, nil       -- la piste est morte
    end
    if not out and Audition.route_track then
        out = r.GetSelectedTrack(0, 0)
    end
    return out
end

-- Rend true si le port d'audition est pret et branche ou il faut.
local function ensurePort()
    if not voicesUsable() then return false end
    local want = resolveOut()

    if port and bound_to == want and Voice.OutputActive(port) then return true end

    -- On detache TOUJOURS avant de brancher, meme au premier passage. Le moteur
    -- survit au script : le port d'audition peut etre deja attache par une
    -- execution precedente, sur une autre sortie, et l'attache est idempotente —
    -- elle repondrait « deja fait » sans rien rebrancher. Rebrancher reprend
    -- aussi les voix du port, donc le handle qu'on tenait n'existe plus.
    port = Voice.AUDITION_PORT
    Voice.UnbindTrack(port)
    vh, cur, backend = nil, nil, "none"
    Audition.playing_path = nil

    local ok
    if want then ok = Voice.BindTrack(port, want)
    else         ok = Voice.BindOutput(port, 0) end
    if not ok then port = nil return false end
    bound_to = want
    return true
end

local function ensureVoice()
    if vh then return true end
    vh = Voice.Alloc(port)
    if not vh then return false end
    Voice.Set(vh, "fade_in", Audition.fade_in)
    Voice.Set(vh, "fade_out", Audition.fade_out)
    return true
end

-- ---------------------------------------------------------------------------
-- Vivier local
-- ---------------------------------------------------------------------------
local function evict(keep_path)
    while clip_bytes > MAX_BYTES do
        local old, old_tick = nil, math.huge
        for path, e in pairs(clips) do
            if e.id and path ~= keep_path and path ~= Audition.playing_path
               and e.tick < old_tick then
                old, old_tick = path, e.tick
            end
        end
        if not old then return end          -- plus rien de jetable
        local e = clips[old]
        Voice.Unload(e.id)
        clip_bytes = clip_bytes - e.bytes
        clips[old] = nil
    end
end

-- Rend l'entree de vivier, ou nil suivi d'une raison. Les echecs sont memorises
-- eux aussi : la bande de forme d'onde interroge le fichier selectionne a
-- chaque frame, et un fichier illisible ne doit pas rouvrir le disque a chaque
-- fois.
local function loadClip(path)
    ctick = ctick + 1
    local e = clips[path]
    if e then
        e.tick = ctick
        if not e.id then return nil, e.why end
        return e
    end

    -- Le MIDI n'a pas de chemin audio, et un fichier trop long se lit mieux
    -- depuis le disque. Les deux se decident sur l'en-tete, sans rien decoder.
    local len, _, sr = Preview.Meta(path)
    if not len or len <= 0 then
        clips[path] = { id = false, why = "unreadable", tick = ctick }
        return nil, "unreadable"
    end
    if sr == 0 then
        clips[path] = { id = false, why = "midi", tick = ctick }
        return nil, "midi"
    end
    if len > NATIVE_MAX_S then
        clips[path] = { id = false, why = "too_long", tick = ctick }
        return nil, "too_long"
    end

    local t0 = r.time_precise()
    local id, why = Voice.Load(path)
    Audition.last_load_ms = (r.time_precise() - t0) * 1000.0
    if not id then
        clips[path] = { id = false, why = why or "failed", tick = ctick }
        return nil, why
    end

    local dur, nch, srate = Voice.ClipInfo(id)
    if not dur or not srate or srate <= 0 then
        Voice.Unload(id)
        clips[path] = { id = false, why = "failed", tick = ctick }
        return nil, "failed"
    end

    local frames = math.floor(dur * srate + 0.5)
    e = {
        id = id, frames = frames, srate = srate, nch = nch or 2,
        len = dur, bytes = frames * (nch or 2) * 4, tick = ctick,
    }
    clips[path] = e
    clip_bytes = clip_bytes + e.bytes
    evict(path)
    return e
end

-- ---------------------------------------------------------------------------
-- La decision, en une fonction et une seule
-- ---------------------------------------------------------------------------
-- Une transformation demandee que le moteur de voix ne sait pas rendre renvoie
-- le lancement a CF_Preview. C'est une question de CAPACITE, jamais de backend.
-- Les surcharges ponctuelles comptent AUTANT que les reglages persistants.
-- Un pad d'instrument demande sa transposition dans opts (une touche = un
-- intervalle), et ne lire que le reglage du module aurait laisse la voix
-- native jouer la note de reference a la place de celle qu'on a pressee —
-- silencieusement, et pour toutes les touches sauf une.
local function needsPreview(opts)
    local pitch = (opts and opts.pitch) or Audition.pitch
    if pitch and pitch ~= 0 and not Voice.CanPitchShift() then return true end
    local rate = (opts and (opts.rate or opts.rate_override)) or Audition.rate
    if rate and math.abs(rate - 1.0) > 1e-9 and not Voice.CanTimeStretch() then
        return true
    end
    -- Une PARTIE de fichier bouclee : le moteur porte des points de boucle, le
    -- repli ne boucle que la source entiere et se fait surveiller.
    if opts and opts.end_s and not Voice.CanSection() then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Lecture
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- opts, toutes optionnelles — la reunion de ce que les trois fenetres
-- demandaient chacune de leur cote :
--
--   position / start_s   ou la lecture commence, en secondes source
--   end_s, loop_start    LA SECTION : ou elle finit, ou une boucle revient
--   loop                 revenir a la fin de section au lieu de s'arreter
--   vol, pitch, rate     surcharges ponctuelles des reglages persistants
--   ppitch               0 = un changement de taux transpose (defaut : non)
--   fade_in, fade_out    les fondus de l'item, plutot que l'anti-clic
--   out_track            passer par la chaine FX et le fader de cette piste
--   rate_override        l'ancien nom de `rate` (l'accord tempo du navigateur)
--
-- Ce que le moteur ne sait pas rendre renvoie a CF_Preview, et c'est toujours
-- une question de CAPACITE : `Voice.CanSection` decide de la section comme
-- `CanPitchShift` decide de la transposition.
-- ---------------------------------------------------------------------------
function Audition.Play(path, opts)
    if not path then return false end
    Audition.Stop()

    local section = opts and opts.end_s

    if not needsPreview(opts) and ensurePort() then
        local e = loadClip(path)
        if e and ensureVoice() then
            local start_s = opts and (opts.start_s or opts.position)
            local offset = 0
            if start_s and start_s > 0 then
                offset = math.floor(start_s * e.srate + 0.5)
                if offset >= e.frames then offset = 0 end
            end
            popts.rate   = 1.0
            popts.gain   = (opts and opts.vol) or Audition.volume
            popts.loop   = (opts and opts.loop) or Audition.loop
            popts.offset = offset
            popts.fade_in  = opts and opts.fade_in or nil
            popts.fade_out = opts and opts.fade_out or nil
            -- La section, en frames : le retour de boucle tombe a
            -- l'echantillon, sans surveillance par frame.
            if section then
                local ls = (opts.loop_start or start_s or 0) * e.srate
                popts.loop_start = math.floor(ls + 0.5)
                popts.loop_end   = math.floor(section * e.srate + 0.5)
            else
                popts.loop_start, popts.loop_end = nil, nil
            end
            if Voice.Play(vh, e.id, popts) then
                backend = "native"
                cur = e
                sect_end, sect_start = nil, nil   -- le moteur la tient lui-meme
                Audition.playing_path = path
                return true
            end
        end
    end

    -- Repli. Il n'est pas un pis-aller : il sait trois choses que le moteur ne
    -- sait pas, la transposition, la lecture disque, et jouer une PCM_source
    -- qu'on lui tend sans fichier derriere.
    if not Preview.available then return false end
    local ok = Audition.playThrough(function() return Preview.Play(path, opts) end,
                                    opts)
    if ok then Audition.playing_path = path end
    return ok
end

-- Les reglages persistants de ce module descendent dans CF_Preview avant le
-- lancement, et la section — celle qu'IL ne sait pas tenir — remonte ici.
-- Deux chemins l'appellent (par chemin, par source) et c'etait la seule chose
-- qu'ils avaient en commun.
function Audition.playThrough(start, opts)
    Preview.volume   = Audition.volume
    Preview.pitch    = Audition.pitch
    Preview.rate     = Audition.rate
    Preview.loop     = Audition.loop
    Preview.fade_in  = Audition.fade_in
    Preview.fade_out = Audition.fade_out
    Preview.out_track   = Audition.out_track
    Preview.route_track = Audition.route_track
    if not start() then return false end
    backend = "preview"
    sect_end   = opts and opts.end_s or nil
    sect_start = (opts and (opts.loop_start or opts.start_s or opts.position)) or 0
    return true
end

-- ---------------------------------------------------------------------------
-- JOUER UNE SOURCE QU'ON NOUS TEND
--
-- Un item de l'editeur n'a pas toujours de fichier : une prise inversee ou une
-- SECTION est une PCM_source construite par REAPER, sans chemin, et c'est la
-- seule facon d'entendre exactement ce que la fenetre dessine.
--
-- Le moteur ne sait pas la jouer — il decode DEPUIS un fichier — et c'est une
-- capacite manquante, pas un backend a interroger : CanPlaySource repond non,
-- et l'appelant n'a rien d'autre a savoir. L'appelant possede la source et
-- doit la garder en vie tant qu'elle sonne.
-- ---------------------------------------------------------------------------
function Audition.CanPlaySource()
    return Preview.available and true or false
end

function Audition.PlaySource(src, opts)
    if not src then return false end
    Audition.Stop()
    if not Preview.available then return false end
    local ok = Audition.playThrough(function() return Preview.PlaySource(src, opts) end,
                                    opts)
    if ok then Audition.playing_path = nil end
    return ok
end

function Audition.Stop()
    if backend == "native" then
        if vh then Voice.Stop(vh, Audition.fade_out) end
    elseif backend == "preview" then
        Preview.Stop()
    end
    backend = "none"
    cur = nil
    sect_end = nil
    Audition.playing_path = nil
end

-- Remet a zero l'etat visible quand la lecture s'est terminee d'elle-meme.
local function finished()
    backend = "none"
    cur = nil
    sect_end = nil
    Audition.playing_path = nil
end

function Audition.IsPlaying()
    if backend == "native" then
        if not vh then finished() return false end
        local st = Voice.State(vh)
        if st == Voice.IDLE then finished() return false end
        return true
    elseif backend == "preview" then
        if not Preview.IsPlaying() then finished() return false end
        return true
    end
    return false
end

-- Rend fraction (0..1), position en secondes, duree en secondes — ou nil.
function Audition.Progress()
    if backend == "native" then
        if not vh or not cur then return nil end
        local st, pos = Voice.State(vh)
        if st == Voice.IDLE then finished() return nil end
        local frac = (cur.frames > 0) and (pos / cur.frames) or 0
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        return frac, pos / cur.srate, cur.len
    elseif backend == "preview" then
        local f, p, l = Preview.Progress()
        if not f then finished() end
        return f, p, l
    end
    return nil
end

function Audition.SeekFrac(frac)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    if backend == "native" then
        if vh and cur then Voice.Seek(vh, math.floor(frac * cur.frames)) end
    elseif backend == "preview" then
        Preview.SeekFrac(frac)
    end
end

-- ---------------------------------------------------------------------------
-- Reglages a la volee
--
-- Ils changent le reglage persistant ET la lecture en cours quand le moteur
-- courant sait le faire. Le pitch et le taux ne s'appliquent pas a une voix
-- native en cours : ils feront basculer le PROCHAIN lancement vers CF_Preview,
-- ce qui est le comportement honnete — plutot que de faire semblant.
-- ---------------------------------------------------------------------------
function Audition.SetVolume(v)
    Audition.volume = v
    if backend == "native" then
        if vh then Voice.Set(vh, "gain", v) end
    elseif backend == "preview" then
        Preview.SetVolume(v)
    end
end

function Audition.SetPitch(st)
    Audition.pitch = st
    if backend == "preview" then Preview.SetPitch(st) end
end

function Audition.SetRate(rate)
    Audition.rate = rate
    if backend == "preview" then Preview.SetRate(rate) end
end

function Audition.SetLoop(on)
    Audition.loop = on and true or false
    if backend == "native" then
        if vh then Voice.SetLoop(vh, Audition.loop) end
    elseif backend == "preview" then
        Preview.SetLoop(Audition.loop)
    end
end

-- ---------------------------------------------------------------------------
-- LA SECTION, DEPLACEE PENDANT QU'ELLE SONNE
--
-- Bouger la selection en cours de lecture doit bouger ce qu'on entend, pas
-- attendre la prochaine touche — et relancer pour l'appliquer ferait sauter la
-- position en arriere. Les deux moteurs savent le faire, chacun a sa facon :
-- la voix porte des points de boucle, CF_Preview se fait surveiller.
-- ---------------------------------------------------------------------------
function Audition.SetSection(on, end_s, start_s)
    Audition.loop = on and true or false
    if backend == "native" then
        if vh and cur then
            if end_s then
                Voice.Set(vh, "loop_end", math.floor(end_s * cur.srate + 0.5))
            end
            if start_s then
                Voice.Set(vh, "loop_start", math.floor(start_s * cur.srate + 0.5))
            end
            Voice.SetLoop(vh, Audition.loop)
        end
    elseif backend == "preview" then
        if end_s   then sect_end   = end_s   end
        if start_s then sect_start = start_s end
        Preview.SetSection(Audition.loop, end_s, start_s)
    end
end

-- Position en secondes source, et la duree — ou nil a l'arret. Progress()
-- repond a la meme question en fraction ; un appelant qui compare a une
-- selection exprimee en secondes veut celle-ci, et devait sinon multiplier par
-- une duree qu'il n'avait pas.
function Audition.Position()
    local _, pos, len = Audition.Progress()
    return pos, len
end

-- Prend effet au PROCHAIN lancement. Rebrancher une sortie coupe le son dans
-- les deux moteurs ; autant que ce soit a un moment choisi.
function Audition.SetOutputTrack(track)
    Audition.out_track = track
    Preview.SetOutputTrack(track)
end

-- ---------------------------------------------------------------------------
-- Prechauffage — la ruse qui rend la navigation aux fleches instantanee
-- ---------------------------------------------------------------------------
function Audition.Prefetch(path)
    if not path then return end
    Preview.Prefetch(path)
    if Audition.warm_prefetch and voicesUsable() and not clips[path] then
        loadClip(path)
    end
end

-- ---------------------------------------------------------------------------
-- Metadonnees et sources — deleguees, pour qu'une fenetre n'ait qu'un module
-- ---------------------------------------------------------------------------
function Audition.Meta(path)           return Preview.Meta(path) end
function Audition.SourceType(path)     return Preview.SourceType(path) end
function Audition.GetSource(path)      return Preview.GetSource(path) end
function Audition.TempoSyncRate(p, m)  return Preview.TempoSyncRate(p, m) end

function Audition.DropSource(path)
    local e = clips[path]
    if e then
        if e.id then
            Voice.Unload(e.id)
            clip_bytes = clip_bytes - e.bytes
        end
        clips[path] = nil
    end
    Preview.DropSource(path)
end

-- ---------------------------------------------------------------------------
-- Battement. A appeler une fois par frame par la fenetre hote : c'est lui qui
-- tient l'ancre horloge<->projet et qui rend la memoire des clips retires.
-- ---------------------------------------------------------------------------
function Audition.Tick()
    Voice.Sync()
    -- La section, quand c'est CF_Preview qui joue : il ne sait boucler que la
    -- source entiere, donc le retour appartient a cette boucle-ci. La voix
    -- native n'a besoin de rien — ses points de boucle sont dans le moteur, et
    -- son retour tombe a l'echantillon.
    if backend == "preview" and sect_end then Preview.Poll() end
end

-- Ancien nom du battement, garde parce que deux fenetres l'appelaient sur
-- l'autre module d'audition. Un seul battement par frame, quel que soit le
-- nom par lequel on le demande.
function Audition.Poll() Audition.Tick() end

-- ---------------------------------------------------------------------------
-- Fermeture
-- ---------------------------------------------------------------------------
function Audition.Destroy()
    Audition.Stop()
    if vh then Voice.Release(vh) vh = nil end
    for path, e in pairs(clips) do
        if e.id then Voice.Unload(e.id) end
        clips[path] = nil
    end
    clip_bytes = 0
    -- On rend la sortie. Une autre fenetre qui auditionne la reprendra a son
    -- prochain lancement : ensurePort() est appelee a chaque fois, justement
    -- pour que ce cas ne demande aucune coordination entre scripts.
    if port then Voice.UnbindTrack(port) port = nil end
    bound_to = false
    Preview.Destroy()
end

return Audition
