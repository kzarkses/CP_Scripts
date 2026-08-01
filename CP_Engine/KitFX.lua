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
local MB_RING, RING_N, RING_SZ = 16, 2048, 4
local MB_STR   = 8208
local PATH_MAX = 255                 -- le JSFX reserve 256 slots, zero compris
local MB_PEAK, MB_NACT, MB_LOADED = 8464, 8528, 8592

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
        attached = true
    end
    KitFX.Install()
end

-- Sans gmem, l'instrument existe mais on ne peut pas lui parler. On le DIT au
-- lieu d'echouer en silence : c'est la meme regle que « cells: silent » dans
-- la Session — l'absence d'un moyen doit etre visible, pas devinable.
function KitFX.Ready() return attached == true end

local function base(slot)
    return GM_BASE + (slot % KitFX.SLOTS) * GM_SLOT_SZ
end

-- ---------------------------------------------------------------------------
-- L'anneau des reglages
-- ---------------------------------------------------------------------------
-- Lua ecrit la commande PUIS avance l'index : tant que l'index n'a pas bouge,
-- le JSFX ne lit rien, et une commande a moitie ecrite n'existe pas pour lui.
local function push(slot, op, pad, field, value)
    if not attached then return false end
    local b = base(slot)
    local w = r.gmem_read(b + MB_WPOS) or 0
    local e = b + MB_RING + (w % RING_N) * RING_SZ
    r.gmem_write(e,     op)
    r.gmem_write(e + 1, pad or 0)
    r.gmem_write(e + 2, field or 0)
    r.gmem_write(e + 3, value or 0)
    r.gmem_write(b + MB_WPOS, w + 1)
    return true
end

function KitFX.Set(slot, pad, field, value)
    return push(slot, OP_SET, pad, field, value)
end

function KitFX.Clear(slot, pad)
    -- Le chemin part aussi, sinon le pad se rechargerait a la reouverture du
    -- projet : le JSFX relit tout pad dont le chemin n'est pas vide.
    KitFX.SetPath(slot, pad, "")
    return push(slot, OP_CLEAR, pad, 0, 0)
end

function KitFX.ClearAll(slot)
    for pad = 0, 63 do KitFX.SetPath(slot, pad, "") end
    return push(slot, OP_CLEARALL, 0, 0, 0)
end

-- ---------------------------------------------------------------------------
-- Les chemins
-- ---------------------------------------------------------------------------
-- Un JSFX ne prend pas de parametre chaine : on depose les codes de
-- caracteres, terminés par zero, et le plugin les recopie chez lui.
function KitFX.SetPath(slot, pad, path)
    if not attached then return false end
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
    if not attached then return false end
    if not KitFX.SetPath(slot, pad, path) then return false end
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
    if not attached then return true end
    local b = base(slot)
    return (r.gmem_read(b + MB_LSEQ) or 0) == (r.gmem_read(b + MB_LACK) or 0)
end

function KitFX.Status(slot)
    if not attached then return KitFX.ST_READY end
    return r.gmem_read(base(slot) + MB_STATUS) or KitFX.ST_READY
end

-- ---------------------------------------------------------------------------
-- Ce que l'instrument publie
-- ---------------------------------------------------------------------------
function KitFX.Peak(slot, pad)
    if not attached then return 0 end
    return r.gmem_read(base(slot) + MB_PEAK + pad) or 0
end

-- « CE PAD PORTE-T-IL DE LA MATIERE ». La question que la migration doit
-- poser, et la seule qui compte : l'instrument ne repond oui qu'apres avoir
-- lu le fichier et compte ses images.
function KitFX.Loaded(slot, pad)
    if not attached then return false end
    return (r.gmem_read(base(slot) + MB_LOADED + pad) or 0) > 0.5
end

function KitFX.Active(slot, pad)
    if not attached then return 0 end
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

-- La hauteur : la meme echelle que le RS5K (0,5 = 0 st, ±80 st), pour qu'un
-- kit migre sans que le bouton saute.
local function normToSt(n) return (clamp(n, 0, 1) - 0.5) * 160 end
local function stToNorm(s) return clamp(0.5 + s / 160, 0, 1) end

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
    [109] = { f=F.MINVOL, unit="dB", plain=normToDb, norm=dbToNorm,
              put=function(v) return dbToLin(normToDb(v)) end,
              get=function(x) return dbToNorm(linToDb(x)) end },
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
