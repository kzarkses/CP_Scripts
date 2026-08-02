-- CP_Engine/KitFX.lua — parler a CP_KitSampler.jsfx
--
-- CE MODULE EST LE CONTRAT, et il est le SEUL a le connaitre. Les index de
-- gmem, la carte des champs d'un pad et les courbes qui traduisent une
-- position de bouton en millisecondes vivent ici et nulle part ailleurs. Kit
-- appelle des fonctions nommees ; il n'ecrit jamais dans gmem lui-meme.
--
-- POURQUOI GMEM ALORS QU'ON L'A TUE EN SESSION 20. Ce qu'on avait tue, c'est
-- gmem comme PROTOCOLE D'UN MOTEUR — une carte memoire recopiee des deux
-- cotes, ou une constante fausse d'un cote ressemble a un bug de l'autre. Ici
-- il n'y a qu'une carte, elle est dans ce fichier, et l'instrument est un
-- effet de REAPER : il n'existe pas d'autre canal pour lui passer une chaine.
-- Le moteur natif, lui, a une ABI et n'en a pas besoin.
--
-- CE QUI EST AUTORITAIRE, ET C'EST LA QUESTION QUI COMPTE. Le JSFX possede
-- l'etat qui fait le SON : ses reglages et ses chemins sont dans son
-- @serialize, donc dans le .RPP. Rouvrir un projet fait sonner le kit sans
-- qu'aucun script tourne — un instrument dont il faut ouvrir la fenetre pour
-- s'entendre n'est pas un instrument. Kit tient un miroir pour l'affichage :
-- s'ils divergent, le JSFX gagne, et le miroir se refait au prochain scan.

local KitFX = {}

local r          -- reaper, injecte
local attached = false

-- ---------------------------------------------------------------------------
-- La carte gmem. MIROIR EXACT de l'en-tete de CP_KitSampler.jsfx : toute
-- valeur changee ici doit l'etre la-bas dans le meme commit.
-- ---------------------------------------------------------------------------
local GM_NAME    = "CP_Kit"
local GM_BASE    = 16
local GM_SLOT_SZ = 12288
KitFX.SLOTS      = 16

local MB_WPOS, MB_RPOS = 0, 1
local MB_LSEQ, MB_LACK, MB_LPAD, MB_STATUS = 2, 3, 4, 5
-- Combien de fois l'instrument a du RECALER l'anneau. Zero est la seule reponse
-- normale ; autre chose designe deux compteurs qui se sont croises, donc des
-- reglages perdus — et c'est la seule trace qui restera de l'incident.
local MB_RESYNC = 8721
local MB_RING, RING_N, RING_SZ = 16, 2048, 4
local MB_STR   = 8208
local PATH_MAX = 255                 -- le JSFX reserve 256 slots, zero compris
local MB_PEAK, MB_NACT, MB_LOADED = 8464, 8528, 8592
local MB_NLOADED = 8656
local MB_HB = 8720

local OP_SET, OP_CLEAR, OP_CLEARALL = 1, 2, 3

KitFX.ST_READY, KitFX.ST_BUSY = 0, 1
KitFX.ST_FAILED, KitFX.ST_TRUNCATED = 2, 3

-- Champs d'un pad, dans l'ordre du JSFX -------------------------------------
KitFX.F = {
    VOL=5, PAN=6, TUNE=7, PLO=8, PHI=9, BEND=10, PORTA=11,
    ATT=12, DEC=13, SUS=14, REL=15, OBEY=16, ROFF=17, ROFFS=18,
    LOOP=19, LSTART=20, XFADE=21, SOFFS=22, EOFFS=23,
    NLO=24, NHI=25, VLO=26, VHI=27, MINVOL=28, CHAN=29,
    PROB=30, RR=31, CHOKE=33, MAXV=34, OUT=35, MUTE=36, SOLO=37,
    MODE=39, INTERP=40, ROOT=43,
}

-- ---------------------------------------------------------------------------
-- Installation : le fichier voyage dans le depot, REAPER le lit dans Effects.
-- Meme mecanique que CP_TempoHub — une ligne de version en tete decide s'il
-- faut recopier, pour qu'un git pull mette a jour l'instrument tout seul.
-- ---------------------------------------------------------------------------
local SRC = "/Scripts/CP_Scripts/CP_JSFX/CP_KitSampler.jsfx"
local DST = "/Effects/CP_Scripts/CP_KitSampler.jsfx"
KitFX.ADD = "JS:CP_Scripts/CP_KitSampler.jsfx"

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function KitFX.Install()
    local res = r.GetResourcePath()
    local src = readAll(res .. SRC)
    if not src then return false, "source introuvable" end
    local dst = readAll(res .. DST)
    if dst == src then return true end
    r.RecursiveCreateDirectory(res .. "/Effects/CP_Scripts", 0)
    local f = io.open(res .. DST, "wb")
    if not f then return false, "ecriture refusee" end
    f:write(src)
    f:close()
    return true
end

function KitFX.init(reaper_api)
    r = reaper_api
    if not attached and r.gmem_attach then
        r.gmem_attach(GM_NAME)
        -- ON VERIFIE QUE C'EST ARRIVE. gmem_attach ne rend rien, et un
        -- attachement qui echoue laisse gmem_read rendre nil : Lua ecrivait
        -- alors dans le vide en croyant parler. Une ecriture suivie d'une
        -- relecture le prouve en deux lignes.
        r.gmem_write(0, 0x43504B31)
        attached = (r.gmem_read(0) == 0x43504B31)
    end
    KitFX.Install()
end


-- Sans gmem, l'instrument existe mais on ne peut pas lui parler. On le DIT au
-- lieu d'echouer en silence : c'est la meme regle que « cells: silent » dans
-- la Session — l'absence d'un moyen doit etre visible, pas devinable.
function KitFX.Ready() return attached == true end

-- ---------------------------------------------------------------------------
-- gmem_attach EST GLOBAL AU SCRIPT, ET C'EST LE PIEGE LE PLUS COUTEUX DU LOT
-- ---------------------------------------------------------------------------
-- Il ne rend pas une poignee : il choisit quel bloc nomme TOUS les gmem_read
-- et gmem_write du script touchent, jusqu'au prochain appel. CP_Sampler
-- charge Tempo, et Tempo.Poll() se rebranche sur « CP_Tempo » a CHAQUE
-- passage de la boucle. Attacher une fois a l'initialisation, comme on le
-- faisait, ne vaut donc que jusqu'au premier passage : ensuite, chaque
-- ecriture de KitFX partait dans la boite du hub de tempo, et chaque lecture
-- en revenait. L'instrument, lui, lit « CP_Kit » : la boite est vide de son
-- cote, et le peu qui marchait ne marchait que par la grace de l'ordre des
-- appels dans une frame — d'ou le « des fois oui, des fois non ».
--
-- Tempo.lua le documente depuis la session 20, en toutes lettres : « no app
-- loads both today; the trap is armed for the one that will ». C'est celle-ci.
-- On reselectionne donc avant chaque acces, comme Tempo le fait, et comme
-- Loop.Reattach le prevoit. Un gmem_attach est une ecriture de pointeur, pas
-- une ouverture : le cout est nul devant ce qu'il evite.
local function sel()
    if attached then r.gmem_attach(GM_NAME) end
    return attached
end

local function base(slot)
    return GM_BASE + (slot % KitFX.SLOTS) * GM_SLOT_SZ
end
-- Le battement : Lua l'avance a chaque passage, l'instrument l'affiche. S'il
-- reste a zero dans la fenetre du JSFX, les deux ne partagent pas la meme
-- memoire, et c'est la SEULE conclusion a en tirer.
local hb = 0
function KitFX.Heartbeat(slot)
    if not sel() then return end
    hb = hb + 1
    r.gmem_write(base(slot) + MB_HB, hb)
end

-- ---------------------------------------------------------------------------
-- L'anneau des reglages
-- ---------------------------------------------------------------------------
-- Lua ecrit la commande PUIS avance l'index : tant que l'index n'a pas bouge,
-- le JSFX ne lit rien, et une commande a moitie ecrite n'existe pas pour lui.
-- UN ANNEAU PLEIN REFUSE, IL NE SE RATTRAPE PAS.
--
-- `push` avancait `wpos` sans jamais regarder `rpos`. Tant que le JSFX draine
-- (il vide tout l'anneau a chaque bloc), les 2048 cases sont largement de trop
-- et rien ne se voit. Mais le jour ou il ne draine pas — piste hors ligne,
-- effet contourne, rendu en cours, plugin en train de recharger — Lua fait le
-- tour et REECRIT DES CASES QUE LE PLUGIN N'A PAS ENCORE LUES.
--
-- Ce qu'on y perd n'est pas une commande, c'est la COHERENCE d'une commande :
-- le JSFX lit alors quatre mots dont deux appartiennent a l'ancienne et deux a
-- la nouvelle. Un OP_SET pour le pad 24 devient un OP_SET pour un autre pad, un
-- autre champ, une autre valeur — c'est-a-dire un reglage arbitraire ecrit dans
-- un pad arbitraire, et des pads qui se taisent sans qu'aucun geste ne les ait
-- touches.
--
-- Perdre une commande est un defaut visible et local : le bouton ne prend pas,
-- on le retourne. En corrompre une est invisible et lointaine. On refuse donc,
-- et on le DIT dans le journal, pour que la prochaine fois la question soit
-- deja repondue quand on l'ouvre.
local lapped = 0
local function push(slot, op, pad, field, value)
    if not sel() then return false end
    local b = base(slot)
    local w = r.gmem_read(b + MB_WPOS) or 0
    local rp = r.gmem_read(b + MB_RPOS) or 0
    if (w - rp) >= RING_N - 1 then
        -- On COMPTE plutot que de tracer : ce module n'a pas de journal, et lui
        -- en donner un le ferait dependre de la fenetre. Le rapport d'etat lit
        -- ce compteur a cote de wpos et rpos, la ou la question se pose.
        lapped = lapped + 1
        return false
    end
    local e = b + MB_RING + (w % RING_N) * RING_SZ
    r.gmem_write(e,     op)
    r.gmem_write(e + 1, pad or 0)
    r.gmem_write(e + 2, field or 0)
    r.gmem_write(e + 3, value or 0)
    r.gmem_write(b + MB_WPOS, w + 1)
    return true
end

-- Combien de commandes l'anneau a refusees depuis l'ouverture. Zero est la
-- reponse normale ; autre chose designe un plugin qui ne tourne pas.
function KitFX.Lapped() return lapped end

function KitFX.Set(slot, pad, field, value)
    return push(slot, OP_SET, pad, field, value)
end

-- Effacer, c'est l'affaire du JSFX : lui seul peut atteindre le chemin ET
-- les reglages du pad. Lua ne fait que le demander.
function KitFX.Clear(slot, pad)
    return push(slot, OP_CLEAR, pad, 0, 0)
end

function KitFX.ClearAll(slot)
    return push(slot, OP_CLEARALL, 0, 0, 0)
end

-- ---------------------------------------------------------------------------
-- Les chemins
-- ---------------------------------------------------------------------------
-- Un JSFX ne prend pas de parametre chaine : on depose les codes de
-- caracteres, termines par zero, et le plugin les recopie chez lui.
--
-- IL N'Y A QU'UN TAMPON PAR SLOT, pas un par pad — c'est un CRENEAU DE
-- TRANSIT, et le JSFX recopie son contenu dans le pad au moment ou il prend
-- la demande. La signature portait un `pad` qu'elle n'utilisait pas, et cette
-- promesse a rendu invisible un vrai defaut : KitFX.Clear avait l'air de
-- vider le chemin du pad, et ne vidait qu'un tampon partage. Le pad
-- ressuscitait a la reouverture du projet. C'est le JSFX qui efface le
-- chemin maintenant, dans OP_CLEAR.
function KitFX.SetPath(slot, path)
    if not sel() then return false end
    local b = base(slot) + MB_STR
    path = path or ""
    if #path > PATH_MAX then return false end
    for i = 1, #path do
        r.gmem_write(b + i - 1, path:byte(i))
    end
    r.gmem_write(b + #path, 0)
    return true
end

-- Demande de chargement. LE CHEMIN EST DEPOSE AVANT LE NUMERO DE PAD, et le
-- compteur en dernier : le JSFX ne voit la demande qu'une fois tout ecrit.
function KitFX.Load(slot, pad, path)
    if not sel() then return false end
    if not KitFX.SetPath(slot, path) then return false end
    local b = base(slot)
    r.gmem_write(b + MB_LPAD, pad)
    r.gmem_write(b + MB_STATUS, KitFX.ST_BUSY)
    r.gmem_write(b + MB_LSEQ, (r.gmem_read(b + MB_LSEQ) or 0) + 1)
    return true
end

-- « Le pad sonne-t-il ? » et non « l'ordre est-il parti ? ». Le JSFX
-- n'accuse reception qu'une fois le fichier LU. C'est la lecon du 1er aout,
-- et elle a coute des echantillons : un garde-fou qui verifie le geste et non
-- son resultat ne garde rien.
function KitFX.LoadIdle(slot)
    if not sel() then return true end
    local b = base(slot)
    return (r.gmem_read(b + MB_LSEQ) or 0) == (r.gmem_read(b + MB_LACK) or 0)
end

-- Voir MB_RESYNC. Rend -1 quand on ne voit pas l'instrument, pour qu'un zero
-- veuille dire « il a compte zero » et non « je n'ai pas pu demander ».
function KitFX.Resyncs(slot)
    if not sel() then return -1 end
    return r.gmem_read(base(slot) + MB_RESYNC) or -1
end

function KitFX.Status(slot)
    if not sel() then return KitFX.ST_READY end
    return r.gmem_read(base(slot) + MB_STATUS) or KitFX.ST_READY
end

-- ---------------------------------------------------------------------------
-- Ce que l'instrument publie
-- ---------------------------------------------------------------------------
-- Les mots bruts de la boite aux lettres, pour le journal. C'est la seule
-- facon de savoir si une ecriture est PARTIE, par opposition a « on a appele
-- la fonction qui ecrit ».
function KitFX.Raw(slot)
    if not sel() then return nil end
    local b = base(slot)
    return {
        base = b,
        wpos = r.gmem_read(b + MB_WPOS) or -1,
        rpos = r.gmem_read(b + MB_RPOS) or -1,
        lapped = lapped,
        lseq = r.gmem_read(b + MB_LSEQ) or -1,
        lack = r.gmem_read(b + MB_LACK) or -1,
        lpad = r.gmem_read(b + MB_LPAD) or -1,
        status = r.gmem_read(b + MB_STATUS) or -1,
        nloaded = r.gmem_read(b + MB_NLOADED) or -1,
        hb = r.gmem_read(b + MB_HB) or -1,
        resync = r.gmem_read(b + MB_RESYNC) or -1,
    }
end

function KitFX.Peak(slot, pad)
    if not sel() then return 0 end
    return r.gmem_read(base(slot) + MB_PEAK + pad) or 0
end

-- « CE PAD PORTE-T-IL DE LA MATIERE ». La question que la migration doit
-- poser, et la seule qui compte : l'instrument ne repond oui qu'apres avoir
-- lu le fichier et compte ses images.
function KitFX.Loaded(slot, pad)
    if not sel() then return false end
    return (r.gmem_read(base(slot) + MB_LOADED + pad) or 0) > 0.5
end

-- Combien de pads portent de la matiere, tout de suite. C'est le chiffre qui
-- transforme « je n'entends rien » en une question qu'on peut trancher : zero
-- veut dire que rien n'est charge, et le probleme est le chargement ; un
-- chiffre juste veut dire que le probleme est le routage MIDI ou la sortie.
function KitFX.LoadedCount(slot)
    if not sel() then return -1 end
    return r.gmem_read(base(slot) + MB_NLOADED) or 0
end

function KitFX.Active(slot, pad)
    if not sel() then return 0 end
    return r.gmem_read(base(slot) + MB_NACT + pad) or 0
end

-- ---------------------------------------------------------------------------
-- Les courbes : une position de bouton contre une valeur reelle
-- ---------------------------------------------------------------------------
-- Kit expose deux vues d'un reglage, et CP_Sampler se sert des deux : la
-- NORMALISEE 0..1 (la position du bouton) et la PLAINE (des dB, des ms, des
-- demi-tons). Le RS5K les reliait par son API de formatage ; ici c'est a nous,
-- et c'est tant mieux — on choisit des courbes qui donnent de la finesse la ou
-- l'oreille en demande, ce que le RS5K ne faisait pas.
local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b else return v end
end

-- Le temps : cubique. Une attaque va de 0 a 5 s, et l'essentiel du geste se
-- joue sous 100 ms — une droite y aurait donne trois pixels utiles.
local T_MAX = 5.0
local function normToTime(n) return (clamp(n, 0, 1) ^ 3) * T_MAX end
local function timeToNorm(s) return clamp(s / T_MAX, 0, 1) ^ (1 / 3) end

-- Le niveau : dB de -60 a +12, avec le zero a sa place.
local DB_LO, DB_HI = -60, 12
local function normToDb(n) return DB_LO + clamp(n, 0, 1) * (DB_HI - DB_LO) end
local function dbToNorm(d) return clamp((d - DB_LO) / (DB_HI - DB_LO), 0, 1) end
local function dbToLin(d) return (d <= DB_LO) and 0 or 10 ^ (d / 20) end
local function linToDb(v) return (v <= 0) and DB_LO or 20 * math.log(v, 10) end

-- LA HAUTEUR : PLUS OR MOINS VINGT-QUATRE DEMI-TONS, PAS QUATRE-VINGTS.
-- Le RS5K couvre ±80 st parce que son parametre le couvre ; recopier cette
-- echelle rendait le bouton inutilisable — deux pixels valaient une octave,
-- et pousser Tune au bout mettait l'echantillon a +80 st, soit cent fois trop
-- vite : trente mille images passent en sept millisecondes, et le pad devient
-- inaudible sans qu'aucun message ne le dise. Deux octaves dans chaque sens
-- couvrent tout ce qu'on fait musicalement d'un echantillon.
local ST_RANGE = 24
local function normToSt(n) return (clamp(n, 0, 1) - 0.5) * (ST_RANGE * 2) end
local function stToNorm(s) return clamp(0.5 + s / (ST_RANGE * 2), 0, 1) end

-- ---------------------------------------------------------------------------
-- La table : un identifiant de parametre -> un champ du JSFX + ses courbes
-- ---------------------------------------------------------------------------
-- LES IDENTIFIANTS DE 0 A 25 SONT CEUX DU RS5K, VOLONTAIREMENT. CP_Sampler
-- les nomme quarante-trois fois par Kit.P.* ; garder les memes numeros fait
-- que la fenetre marche sur les deux moteurs sans une ligne de changement, et
-- qu'un preset ecrit avant aujourd'hui se relit apres.
-- Au-dessus de 100 : ce que le RS5K n'avait pas et qui nous manquait.
local F = KitFX.F
KitFX.MAP = {
    [0]  = { f=F.VOL,    unit="dB", plain=normToDb, norm=dbToNorm,
             put=function(v) return dbToLin(normToDb(v)) end,
             get=function(x) return dbToNorm(linToDb(x)) end },
    [1]  = { f=F.PAN,    unit="",
             put=function(v) return clamp(v, 0, 1) * 2 - 1 end,
             get=function(x) return (clamp(x, -1, 1) + 1) / 2 end,
             plain=function(v) return clamp(v, 0, 1) * 2 - 1 end,
             norm=function(p) return (clamp(p, -1, 1) + 1) / 2 end },
    [3]  = { f=F.NLO,    unit="note", plain=function(v) return math.floor(v * 127 + 0.5) end,
             norm=function(p) return clamp(p / 127, 0, 1) end,
             put=function(v) return math.floor(v * 127 + 0.5) end,
             get=function(x) return clamp(x / 127, 0, 1) end },
    [4]  = { f=F.NHI,    unit="note", plain=function(v) return math.floor(v * 127 + 0.5) end,
             norm=function(p) return clamp(p / 127, 0, 1) end,
             put=function(v) return math.floor(v * 127 + 0.5) end,
             get=function(x) return clamp(x / 127, 0, 1) end },
    [8]  = { f=F.MAXV,   unit="voices",
             plain=function(v) return math.max(1, math.floor(v * 64 + 0.5)) end,
             norm=function(p) return clamp(p / 64, 0, 1) end,
             put=function(v) return math.max(1, math.floor(v * 64 + 0.5)) end,
             get=function(x) return clamp(x / 64, 0, 1) end },
    [9]  = { f=F.ATT,    unit="ms", plain=function(v) return normToTime(v) * 1000 end,
             norm=function(p) return timeToNorm(p / 1000) end,
             put=normToTime, get=timeToNorm },
    [10] = { f=F.REL,    unit="ms", plain=function(v) return normToTime(v) * 1000 end,
             norm=function(p) return timeToNorm(p / 1000) end,
             put=normToTime, get=timeToNorm },
    [11] = { f=F.OBEY,   unit="bool", bool=true },
    [12] = { f=F.LOOP,   unit="bool", bool=true },
    [13] = { f=F.SOFFS,  unit="%", direct=true },
    [14] = { f=F.EOFFS,  unit="%", direct=true },
    [15] = { f=F.TUNE,   unit="st", plain=normToSt, norm=stToNorm,
             put=normToSt, get=stToNorm },
    [17] = { f=F.VLO,    unit="vel", plain=function(v) return math.floor(v * 127 + 0.5) end,
             norm=function(p) return clamp(p / 127, 0, 1) end,
             put=function(v) return math.floor(v * 127 + 0.5) end,
             get=function(x) return clamp(x / 127, 0, 1) end },
    [18] = { f=F.VHI,    unit="vel", plain=function(v) return math.floor(v * 127 + 0.5) end,
             norm=function(p) return clamp(p / 127, 0, 1) end,
             put=function(v) return math.floor(v * 127 + 0.5) end,
             get=function(x) return clamp(x / 127, 0, 1) end },
    [23] = { f=F.LSTART, unit="%", direct=true },
    [24] = { f=F.DEC,    unit="ms", plain=function(v) return normToTime(v) * 1000 end,
             norm=function(p) return timeToNorm(p / 1000) end,
             put=normToTime, get=timeToNorm },
    [25] = { f=F.SUS,    unit="dB", plain=normToDb, norm=dbToNorm,
             put=function(v) return dbToLin(normToDb(v)) end,
             get=function(x) return dbToNorm(linToDb(x)) end },

    -- Ce que le RS5K n'exposait pas, ou pas a un pad
    [100] = { f=F.PORTA, unit="ms", plain=function(v) return normToTime(v) * 1000 end,
              norm=function(p) return timeToNorm(p / 1000) end,
              put=normToTime, get=timeToNorm },
    [101] = { f=F.ROFF,  unit="bool", bool=true },
    [102] = { f=F.ROFFS, unit="ms", plain=function(v) return normToTime(v) * 1000 end,
              norm=function(p) return timeToNorm(p / 1000) end,
              put=normToTime, get=timeToNorm },
    [103] = { f=F.BEND,  unit="st",
              plain=function(v) return clamp(v, 0, 1) * 24 end,
              norm=function(p) return clamp(p / 24, 0, 1) end,
              put=function(v) return clamp(v, 0, 1) * 24 end,
              get=function(x) return clamp(x / 24, 0, 1) end },
    [104] = { f=F.MUTE,  unit="bool", bool=true },
    [105] = { f=F.SOLO,  unit="bool", bool=true },
    [106] = { f=F.OUT,   unit="out",
              plain=function(v) return math.floor(clamp(v, 0, 1) * 7 + 0.5) end,
              norm=function(p) return clamp(p / 7, 0, 1) end,
              put=function(v) return math.floor(clamp(v, 0, 1) * 7 + 0.5) end,
              get=function(x) return clamp(x / 7, 0, 1) end },
    [107] = { f=F.PROB,  unit="%", direct=true },
    [108] = { f=F.RR,    unit="n",
              plain=function(v) return math.floor(clamp(v, 0, 1) * 8 + 0.5) end,
              norm=function(p) return clamp(p / 8, 0, 1) end,
              put=function(v) return math.floor(clamp(v, 0, 1) * 8 + 0.5) end,
              get=function(x) return clamp(x / 8, 0, 1) end },
    -- MIN VOL EST UN PLANCHER, PAS UN NIVEAU. C'est le gain a la velocite la
    -- plus basse, et il DOIT rester entre 0 et 1 : au-dessus de 1, la rampe
    -- de velocite s'inverse — frapper plus fort rend plus doux — et le pad
    -- depasse le plein niveau en saturant, pendant que l'affichage annonce
    -- sagement « +4.8 dB ». En dB il pouvait monter a +12. Il est donc
    -- lineaire, borne par construction, et affiche en pourcentage.
    [109] = { f=F.MINVOL, unit="%", direct=true },
    [110] = { f=F.CHAN,  unit="ch",
              plain=function(v) return math.floor(clamp(v, 0, 1) * 16 + 0.5) end,
              norm=function(p) return clamp(p / 16, 0, 1) end,
              put=function(v) return math.floor(clamp(v, 0, 1) * 16 + 0.5) end,
              get=function(x) return clamp(x / 16, 0, 1) end },
    [111] = { f=F.MODE,  unit="bool", bool=true },
    [112] = { f=F.ROOT,  unit="note",
              plain=function(v) return math.floor(v * 127 + 0.5) end,
              norm=function(p) return clamp(p / 127, 0, 1) end,
              put=function(v) return math.floor(v * 127 + 0.5) end,
              get=function(x) return clamp(x / 127, 0, 1) end },
    [113] = { f=F.XFADE, unit="ms", plain=function(v) return normToTime(v) * 1000 end,
              norm=function(p) return timeToNorm(p / 1000) end,
              put=normToTime, get=timeToNorm },
}

-- Un booleen ou une valeur deja en 0..1 n'a pas de courbe : la table le dit
-- plutot que de porter quatre fonctions identite.
local function conv(m, dir, v)
    if m.direct or m.bool then return v end
    local fn = m[dir]
    return fn and fn(v) or v
end

function KitFX.Field(pid)
    local m = KitFX.MAP[pid]
    return m and m.f or nil
end

-- normalise (position de bouton) -> valeur du JSFX
function KitFX.ToFX(pid, norm)
    local m = KitFX.MAP[pid]
    if not m then return nil end
    if m.bool then return (norm and norm > 0.5) and 1 or 0 end
    return conv(m, "put", norm)
end

-- valeur du JSFX -> normalise
function KitFX.FromFX(pid, v)
    local m = KitFX.MAP[pid]
    if not m then return nil end
    if m.bool then return (v and v > 0.5) and 1 or 0 end
    return conv(m, "get", v)
end

-- normalise -> valeur affichable, et le retour
function KitFX.ToPlain(pid, norm)
    local m = KitFX.MAP[pid]
    if not m then return nil end
    if m.bool or m.direct then return norm end
    return m.plain and m.plain(norm) or norm
end

function KitFX.FromPlain(pid, plain)
    local m = KitFX.MAP[pid]
    if not m then return nil end
    if m.bool or m.direct then return plain end
    return m.norm and m.norm(plain) or plain
end

-- Le texte sous un bouton. Anglais : c'est de l'interface.
function KitFX.Format(pid, norm)
    local m = KitFX.MAP[pid]
    if not m then return "" end
    local p = KitFX.ToPlain(pid, norm)
    if m.bool then return (norm > 0.5) and "on" or "off" end
    if m.unit == "dB" then
        return (p <= DB_LO) and "-inf dB" or string.format("%+.1f dB", p)
    elseif m.unit == "ms" then
        return (p < 1000) and string.format("%.0f ms", p)
                           or string.format("%.2f s", p / 1000)
    elseif m.unit == "st" then
        return string.format("%+.2f st", p)
    elseif m.unit == "%" then
        return string.format("%.1f %%", p * 100)
    elseif m.unit == "" then
        return string.format("%.2f", p)
    end
    return string.format("%d", math.floor(p + 0.5))
end

return KitFX
