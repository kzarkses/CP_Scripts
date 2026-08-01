-- CP_Engine — Keymap
--
-- UNE LIAISON EST UNE DONNEE, PAS UN `if`.
--
-- ---------------------------------------------------------------------------
-- POURQUOI CE MODULE EXISTE
-- ---------------------------------------------------------------------------
-- « Rendre configurables tous les raccourcis et modificateurs, pour chaque
-- module de CP_Scripts. REAPER style, c'est dans son ADN. » La demande est
-- claire ; ce qui l'empechait ne l'etait pas.
--
-- Tant qu'un raccourci s'ecrit `if char == 113 then quantize()`, il n'y a rien
-- a configurer : la liaison n'existe nulle part, elle est DISSOUTE dans le
-- flot de controle. Une fenetre de reglages devrait alors reecrire du code.
--
-- Ce module fait donc l'operation qui manquait : il sort la liaison du code et
-- la met dans une table. Le code ne demande plus « la touche q est-elle
-- pressee », il demande « quelle ACTION l'utilisateur vient-il de declencher ».
-- La difference est tout ce qui separe un raccourci fige d'un raccourci qu'on
-- peut changer, et elle vaut aussi pour les modificateurs de souris — qui sont
-- exactement le meme probleme, avec quatre bits au lieu d'un code de touche.
--
-- ---------------------------------------------------------------------------
-- LE MODELE : UNE ACTION POSSEDE UN EMPLACEMENT
-- ---------------------------------------------------------------------------
-- On indexe par ACTION, pas par touche : `bind[action] = emplacement`. C'est
-- l'inverse de ce qu'on ecrirait spontanement, et c'est ce qui rend la fenetre
-- de reglages possible — elle liste des actions et demande « avec quoi ? »,
-- ce qui est la question de l'utilisateur. Le sens inverse (emplacement →
-- action), celui dont l'entree a besoin soixante fois par frame, est un index
-- reconstruit a chaque changement de liaison, donc jamais pendant un geste.
--
-- Deux familles d'emplacements, une seule mecanique :
--
--   SOURIS  { ctx = "note", g = "click", mods = mask }
--           ctx nomme la ZONE sous le pointeur (« note », « note_edge »,
--           « roll », « ruler », « lane », « vel »), g le GESTE brut
--           (« click », « drag », « rclick »).
--   CLAVIER { k = code, mods = mask }
--           le code est celui que `gfx.getchar` a REELLEMENT rendu. On ne le
--           deduit pas : Ctrl+A arrive en 1, la ponctuation se deplace selon
--           la disposition du clavier, et une deduction serait fausse
--           precisement sur les claviers qui ne sont pas le notre.
--
-- ---------------------------------------------------------------------------
-- LE MASQUE
-- ---------------------------------------------------------------------------
-- Ctrl 1, Shift 2, Alt 4, Win 8 — l'ordre de ce fichier, pas celui de
-- `mouse_cap`. Les bits de REAPER (4, 8, 16, 32) n'ont aucune raison de fuiter
-- dans un fichier que quelqu'un relira dans deux ans. `Core.Mods()` fait la
-- conversion, en un seul endroit.
--
-- ---------------------------------------------------------------------------
-- CE QUE CE MODULE NE FAIT PAS
-- ---------------------------------------------------------------------------
-- Il ne dessine rien et il n'appelle aucune action. Il repond « quelle action
-- pour ce geste » et « quel geste pour cette action », c'est tout. Une fenetre
-- qui l'utilise garde entierement la main sur ce que ses actions veulent dire,
-- et deux fenetres peuvent nommer la meme action sans se coordonner.

local Keymap = {}

local r, Core

-- ---------------------------------------------------------------------------
-- Le masque, et sa forme lisible
-- ---------------------------------------------------------------------------
Keymap.CTRL, Keymap.SHIFT, Keymap.ALT, Keymap.WIN = 1, 2, 4, 8

local MOD_NAMES = { { 1, "Ctrl" }, { 2, "Shift" }, { 4, "Alt" }, { 8, "Win" } }

-- « Ctrl+Shift », ou « (none) ». Sert au fichier de configuration ET a la
-- fenetre de reglages : une seule ecriture, donc aucune divergence possible
-- entre ce qu'on montre et ce qu'on stocke.
function Keymap.ModsLabel(mask)
    mask = mask or 0
    if mask == 0 then return "" end
    local out
    for i = 1, #MOD_NAMES do
        if (mask & MOD_NAMES[i][1]) ~= 0 then
            out = out and (out .. "+" .. MOD_NAMES[i][2]) or MOD_NAMES[i][2]
        end
    end
    return out or ""
end

function Keymap.ParseMods(s)
    if not s or s == "" then return 0 end
    local mask = 0
    for word in tostring(s):gmatch("[%a]+") do
        local w = word:lower()
        if     w == "ctrl"  or w == "c" then mask = mask | 1
        elseif w == "shift" or w == "s" then mask = mask | 2
        elseif w == "alt"   or w == "a" then mask = mask | 4
        elseif w == "win"   or w == "w" then mask = mask | 8 end
    end
    return mask
end

-- Le nom lisible d'une touche. Uniquement pour l'affichage — la liaison, elle,
-- reste le CODE. Une table de noms qui se tromperait n'abimerait donc rien
-- d'autre qu'une etiquette, ce qui est exactement le niveau de confiance qu'on
-- peut accorder a une correspondance code → nom sur un clavier inconnu.
local KEY_NAMES = {
    [8] = "Backspace", [9] = "Tab", [13] = "Enter", [27] = "Esc", [32] = "Space",
    [6579564] = "Delete", [6579567] = "Down", [6579565] = "End", [6582632] = "Home",
    [6909555] = "Insert", [1818584692] = "Left", [1919379572] = "Right",
    [30064] = "PageUp", [1885828464] = "PageDown", [30362] = "Up",
}

function Keymap.KeyLabel(k, mask)
    if not k then return "—" end
    local base = KEY_NAMES[k]
    if not base then
        if k >= 1 and k <= 26 then
            -- Ctrl+lettre arrive en code de controle. On le rend lisible, mais
            -- on ne le CONVERTIT pas : la liaison reste ce que la machine a
            -- rendu.
            base = string.char(64 + k)
        elseif k >= 33 and k < 127 then
            base = string.char(k):upper()
        else
            base = "#" .. k
        end
    end
    local m = Keymap.ModsLabel(mask or 0)
    return m ~= "" and (m .. "+" .. base) or base
end

-- ---------------------------------------------------------------------------
-- Registre
-- ---------------------------------------------------------------------------
-- Un module (« editor », « session »...) declare son VOCABULAIRE : la liste de
-- ses actions, chacune avec sa liaison par defaut et un libelle. C'est cette
-- liste que la fenetre de reglages affiche, dans l'ordre ou elle est ecrite —
-- donc l'ordre est un choix de presentation, pas un hasard.
local mods_reg = {}     -- module -> { rows, bind, mouse_idx, key_idx, order }

local function blank(name)
    return { name = name, rows = {}, by_act = {}, bind = {},
             mouse = {}, keys = {}, dirty = true }
end

-- Reconstruit les deux index de lecture depuis les liaisons. Appele a
-- l'enregistrement et a chaque changement — jamais pendant un geste.
local function reindex(m)
    for k in pairs(m.mouse) do m.mouse[k] = nil end
    for k in pairs(m.keys)  do m.keys[k]  = nil end
    for i = 1, #m.rows do
        local row = m.rows[i]
        local b = m.bind[row.act]
        if b then
            if b.ctx then
                local c = m.mouse[b.ctx]
                if not c then c = {} m.mouse[b.ctx] = c end
                local g = c[b.g]
                if not g then g = {} c[b.g] = g end
                -- DERNIER INSCRIT GAGNE, et c'est volontaire : deux actions sur
                -- le meme emplacement est un conflit que l'utilisateur a cree,
                -- pas une erreur a refuser. La fenetre de reglages le montre ;
                -- l'entree, elle, a besoin d'une reponse et d'une seule.
                g[b.mods or 0] = row.act
            elseif b.k then
                local kk = m.keys[b.k]
                if not kk then kk = {} m.keys[b.k] = kk end
                kk[b.mods or 0] = row.act
            end
        end
    end
    m.dirty = false
end

-- rows : liste de { act, label, ctx, g, mods } ou { act, label, k, mods }.
-- `mods` s'ecrit en clair (« Ctrl+Shift ») ou en masque ; les deux sont acceptes
-- pour que la declaration se relise sans decoder.
function Keymap.Register(name, rows)
    local m = blank(name)
    for i = 1, #rows do
        local d = rows[i]
        local mask = type(d.mods) == "number" and d.mods
                     or Keymap.ParseMods(d.mods)
        local row = { act = d.act, label = d.label or d.act,
                      group = d.group,
                      def = { ctx = d.ctx, g = d.g, k = d.k, mods = mask } }
        m.rows[#m.rows + 1] = row
        m.by_act[d.act] = row
        m.bind[d.act] = { ctx = d.ctx, g = d.g, k = d.k, mods = mask }
    end
    mods_reg[name] = m
    Keymap.ApplyOverrides(name)
    return m
end

-- ---------------------------------------------------------------------------
-- Lecture — ce que l'entree appelle
-- ---------------------------------------------------------------------------
-- Le masque courant, calcule UNE fois par frame. `Mouse` est appelee plusieurs
-- fois par zone et par frame ; quatre tests de bits n'ont jamais coute cher,
-- mais un cache sur le numero de frame coute encore moins et dit au lecteur
-- que ce chemin est chaud.
local mods_frame, mods_cache = -1, 0

function Keymap.Mods()
    local f = Core and Core.GetState and Core.GetState().frame or 0
    if f ~= mods_frame then
        mods_frame = f
        mods_cache = Core.Mods()
    end
    return mods_cache
end

-- L'action liee a ce geste dans cette zone, avec les modificateurs tenus MAINTENANT.
function Keymap.Mouse(name, ctx, gesture, mask)
    local m = mods_reg[name]
    if not m then return nil end
    if m.dirty then reindex(m) end
    local c = m.mouse[ctx]
    if not c then return nil end
    local g = c[gesture]
    if not g then return nil end
    return g[mask or Keymap.Mods()]
end

-- L'action liee a cette touche. Le code ET le masque viennent de la machine :
-- on ne reconstruit ni l'un ni l'autre.
function Keymap.Key(name, char, mask)
    local m = mods_reg[name]
    if not m or not char then return nil end
    if m.dirty then reindex(m) end
    local kk = m.keys[char]
    if not kk then return nil end
    return kk[mask or Keymap.Mods()]
end

-- ---------------------------------------------------------------------------
-- Lecture — ce que la fenetre de reglages appelle
-- ---------------------------------------------------------------------------
function Keymap.Rows(name)
    local m = mods_reg[name]
    return m and m.rows or nil
end

function Keymap.Binding(name, act)
    local m = mods_reg[name]
    return m and m.bind[act] or nil
end

-- « Avec quoi declenche-t-on cette action », en toutes lettres.
function Keymap.Label(name, act)
    local b = Keymap.Binding(name, act)
    if not b then return "—" end
    if b.k then return Keymap.KeyLabel(b.k, b.mods) end
    if not b.ctx then return "—" end
    local mm = Keymap.ModsLabel(b.mods)
    local g = (b.g == "click" and "click") or (b.g == "rclick" and "right-click")
              or (b.g == "drag" and "drag") or b.g
    return (mm ~= "" and (mm .. "+") or "") .. g
end

-- Les actions qui partagent l'emplacement de celle-ci. Une fenetre de reglages
-- doit pouvoir le DIRE : un conflit silencieux est un raccourci qui ne marche
-- pas, et on cherche la raison ailleurs pendant une heure.
function Keymap.Conflicts(name, act)
    local m = mods_reg[name]
    if not m then return nil end
    local b = m.bind[act]
    if not b then return nil end
    local out
    for other, ob in pairs(m.bind) do
        if other ~= act and ob.mods == b.mods
           and ((b.k and ob.k == b.k) or
                (b.ctx and ob.ctx == b.ctx and ob.g == b.g)) then
            out = out or {}
            out[#out + 1] = other
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Ecriture
-- ---------------------------------------------------------------------------
function Keymap.Set(name, act, slot)
    local m = mods_reg[name]
    if not m or not m.by_act[act] then return false end
    m.bind[act] = { ctx = slot.ctx, g = slot.g, k = slot.k,
                    mods = slot.mods or 0 }
    m.dirty = true
    return true
end

function Keymap.Reset(name, act)
    local m = mods_reg[name]
    if not m then return false end
    if act then
        local row = m.by_act[act]
        if not row then return false end
        m.bind[act] = { ctx = row.def.ctx, g = row.def.g, k = row.def.k,
                        mods = row.def.mods }
    else
        for i = 1, #m.rows do
            local row = m.rows[i]
            m.bind[row.act] = { ctx = row.def.ctx, g = row.def.g,
                                k = row.def.k, mods = row.def.mods }
        end
    end
    m.dirty = true
    return true
end

-- ---------------------------------------------------------------------------
-- Persistance — un fichier Lua lisible dans CP_Config, comme le reste
-- ---------------------------------------------------------------------------
-- ON N'ECRIT QUE CE QUI DIFFERE DU DEFAUT. Un fichier qui recopie l'integralite
-- de la table geerait la premiere fois qu'on ajoute une action : elle
-- n'existerait dans aucun fichier deja ecrit, et l'utilisateur ne la verrait
-- jamais apparaitre. En n'ecrivant que les ecarts, une action nouvelle arrive
-- avec son defaut chez tout le monde.
local CONFIG_ID = "CP_Keymap"
local store = nil

local function loadStore()
    if store then return store end
    store = (Core and Core.LoadConfig and Core.LoadConfig(CONFIG_ID)) or {}
    return store
end

function Keymap.ApplyOverrides(name)
    local m = mods_reg[name]
    if not m then return end
    local s = loadStore()[name]
    if type(s) ~= "table" then m.dirty = true return end
    for act, v in pairs(s) do
        if m.by_act[act] and type(v) == "table" then
            m.bind[act] = { ctx = v.ctx, g = v.g, k = v.k,
                            mods = v.mods or 0 }
        end
    end
    m.dirty = true
end

function Keymap.Save(name)
    local m = mods_reg[name]
    if not m then return false end
    local s = loadStore()
    local out = {}
    for i = 1, #m.rows do
        local row = m.rows[i]
        local b, d = m.bind[row.act], row.def
        if b.ctx ~= d.ctx or b.g ~= d.g or b.k ~= d.k or b.mods ~= d.mods then
            out[row.act] = { ctx = b.ctx, g = b.g, k = b.k, mods = b.mods }
        end
    end
    if next(out) then s[name] = out else s[name] = nil end
    return Core.SaveConfig(CONFIG_ID, s) and true or false
end

function Keymap.init(reaper_api, core)
    r = reaper_api
    Core = core
    return Keymap
end

return Keymap
