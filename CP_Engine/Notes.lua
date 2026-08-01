-- CP_Engine — Notes
--
-- JOUER UNE NOTE, MAINTENANT, DANS UNE PISTE, ET NULLE PART AILLEURS.
--
-- ---------------------------------------------------------------------------
-- CE QUE CE MODULE REMPLACE, ET POURQUOI IL A FALLU LE REMPLACER
-- ---------------------------------------------------------------------------
-- Toute la suite jouait ses notes d'apercu par `StuffMIDIMessage`, que le SDK
-- decrit lui-meme comme une ecriture dans la file du CLAVIER VIRTUEL. Une file
-- n'a pas de destinataire : ce qu'on y met part vers TOUTE piste armee en
-- monitoring, a la fois. Trois consequences, et ce sont exactement les trois
-- symptomes rapportes au premier vrai test d'ecoute :
--
--   · pour s'entendre, il fallait armer une piste — donc le sampler armait de
--     force la sienne, et la reaffirmait des que REAPER la desarmait ;
--   · comme il armait de force, il gagnait la course contre les pistes armees
--     a la main : « ca ne reagit pas avec les armed track de REAPER natif » ;
--   · un clic de pad sonnait aussi tout ce qui se trouvait arme ailleurs, d'ou
--     un canal reserve (Kit.UI_CHAN) invente pour que les autres apprennent a
--     ignorer nos apercus. Un timbre-poste sur une lettre sans adresse.
--
-- Ici l'adresse EST le message. Un port du moteur est verse dans une piste,
-- pre-FX ; ce qu'on y depose traverse la chaine d'effets de cette piste comme
-- s'il venait d'un item, et rien d'autre dans le projet ne l'entend. Aucun
-- armement n'entre en jeu : l'armement redevient ce que REAPER en dit, c'est-
-- a-dire « cette piste enregistre et se monitore », et plus « c'est par la que
-- le sampler s'entend ».
--
-- ---------------------------------------------------------------------------
-- LE REPLI, ET CE QU'IL COUTE
-- ---------------------------------------------------------------------------
-- Sans l'extension, il ne reste que le broadcast. On le garde — se taire
-- serait pire — mais on le NOMME : Label() rend « broadcast », les fenetres
-- l'affichent, et le lecteur d'un bug de routage sait en une seconde dans
-- lequel des deux mondes il se trouve.
--
-- ---------------------------------------------------------------------------
-- ZERO ALLOCATION
-- ---------------------------------------------------------------------------
-- On/Off partent d'un chemin de saisie : ils sont appeles au clic, parfois
-- plusieurs fois par frame (un accord, un glisse sur le clavier). Le registre
-- des notes tenues est preallouee une fois ; rien ici n'alloue.

local Notes = {}

local r
local Voice           -- CP_Engine/Voice, injecte (carte des ports + backend)

local NATIVE  = false
local port    = nil   -- le port de CE consommateur (voir Voice, carte des ports)
local track   = nil   -- la piste ou il est verse, nil = nulle part
local bound   = false -- le port est-il attache a `track`

-- Canal par defaut. ZERO, et c'est un changement de sens : une note d'apercu
-- ressemble desormais a n'importe quelle note, parce qu'elle n'a plus besoin de
-- se signaler aux autres. Le canal reserve n'existait que pour permettre a un
-- broadcast d'etre ignore.
Notes.CHAN = 0

-- Registre des notes TENUES : ce qui doit etre relache si le doigt part, si la
-- cible change, ou si la fenetre se ferme. Une note coincee ne demande pas la
-- permission — c'est le seul etat que ce module possede.
local MAXHOLD = 32
local h_note = {}
local h_chan = {}
local nhold  = 0

-- On demande une CAPACITE, jamais un backend : « sais-tu adresser une note a
-- une piste ». Le `if natif then` vit dans Voice et nulle part ailleurs, y
-- compris ici.
function Notes.init(reaper_api, voice_module, use_port)
    r = reaper_api
    Voice = voice_module
    port = use_port
    track, bound, nhold = nil, false, 0
    NATIVE = (Voice ~= nil and Voice.CanSendMidi and Voice.CanSendMidi()) or false
    for i = 1, MAXHOLD do h_note[i], h_chan[i] = 0, 0 end
    return NATIVE
end

-- « natif 1.8 » n'apporte rien de plus qu'une fenetre ne sache deja : ce qui
-- compte ici est le MODE DE LIVRAISON, parce que c'est lui qui explique un
-- routage surprenant.
function Notes.Label()
    return NATIVE and "targeted" or "broadcast"
end

function Notes.Available()
    return NATIVE or (r ~= nil and r.StuffMIDIMessage ~= nil)
end

-- La note atteint-elle UNIQUEMENT la piste visee ? C'est la question qu'une
-- fenetre pose avant de promettre quoi que ce soit a l'utilisateur.
function Notes.IsTargeted() return NATIVE end

local function valid(tr)
    return tr ~= nil and r.ValidatePtr2(0, tr, "MediaTrack*")
end

-- ---------------------------------------------------------------------------
-- La cible
-- ---------------------------------------------------------------------------
-- Un port est IDEMPOTENT a l'attache : le rattacher a une AUTRE piste ne fait
-- rien du tout tant que l'ancien n'est pas retire. Ce module est donc le seul
-- endroit qui connaisse la piste courante, et le detachement est explicite.
local function unbind()
    if bound and NATIVE and port then Voice.UnbindTrack(port) end
    bound = false
end

function Notes.SetTrack(tr)
    if not valid(tr) then tr = nil end
    if tr == track then return end
    Notes.AllOff()          -- ce qui sonnait sonnait LA-BAS : on le relache la-bas
    unbind()
    track = tr
end

function Notes.Track() return track end

-- Attache paresseuse : tant que personne ne joue, aucun apercu n'est installe
-- sur la piste de l'utilisateur. Rend false quand il n'y a pas de sortie —
-- l'appelant ne doit alors PAS inscrire la note comme tenue.
local function ensureBound()
    if not NATIVE or not port then return false end
    if bound then return true end
    if not valid(track) then return false end
    bound = Voice.BindTrack(port, track) and true or false
    return bound
end

-- ---------------------------------------------------------------------------
-- Jouer
-- ---------------------------------------------------------------------------
local function send(status, d1, d2)
    if NATIVE then
        if not ensureBound() then return false end
        -- -1 = MAINTENANT. Le moteur date au bloc que le fil audio traite, pas
        -- au frame ou Lua l'a ecrite : entre les deux il y a une frame de
        -- defer, et une date deja passee redevient un evenement en retard.
        return Voice.SendMidi(port, -1, status, d1, d2)
    end
    if not r.StuffMIDIMessage then return false end
    r.StuffMIDIMessage(0, status, d1, d2)
    return true
end

local function hold(note, chan)
    for i = 1, nhold do
        if h_note[i] == note and h_chan[i] == chan then return end
    end
    if nhold >= MAXHOLD then return end
    nhold = nhold + 1
    h_note[nhold] = note
    h_chan[nhold] = chan
end

local function unhold(note, chan)
    for i = 1, nhold do
        if h_note[i] == note and h_chan[i] == chan then
            h_note[i], h_chan[i] = h_note[nhold], h_chan[nhold]
            nhold = nhold - 1
            return
        end
    end
end

function Notes.On(note, vel, chan)
    if note == nil then return false end
    chan = chan or Notes.CHAN
    if not send(0x90 + (chan & 0x0F), note & 0x7F, (vel or 100) & 0x7F) then
        return false
    end
    hold(note & 0x7F, chan & 0x0F)
    return true
end

function Notes.Off(note, chan)
    if note == nil then return false end
    chan = chan or Notes.CHAN
    unhold(note & 0x7F, chan & 0x0F)
    return send(0x80 + (chan & 0x0F), note & 0x7F, 0)
end

-- Tout relacher. Les note-offs nommes d'abord (un instrument peut compter ses
-- voix), puis « all notes off » par canal comme filet — un CC ne reveille rien
-- et rattrape ce qu'un plantage de script aurait laisse tenu.
function Notes.AllOff()
    if nhold == 0 then return end
    local seen = 0
    for i = nhold, 1, -1 do
        send(0x80 + h_chan[i], h_note[i], 0)
        if h_chan[i] == 0 then seen = 1 end
    end
    nhold = 0
    if seen == 1 then send(0xB0, 123, 0) end
end

function Notes.Held() return nhold end

-- Rendre la sortie. A appeler a la fermeture : un apercu permanent laisse sur
-- la piste de l'utilisateur survivrait au script.
function Notes.Close()
    Notes.AllOff()
    unbind()
    track = nil
end

return Notes
