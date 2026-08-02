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
-- LES CODES VIENNENT DE CP_Toolkit/Keys, PAS D'ICI. Une seconde table de
-- constantes recopiees a la main est une table qui finira par diverger, et on
-- ne s'en apercevrait que sur la touche qu'on n'a pas testee. L'hote passe la
-- sienne a l'init ; en son absence on n'affiche que « #code », ce qui est laid
-- mais jamais faux.
local KEY_NAMES = {}
local function buildNames(Keys)
    if type(Keys) ~= "table" then return end
    local pretty = {
        BACKSPACE = "Backspace", TAB = "Tab", ENTER = "Enter",
        ESCAPE = "Esc", SPACE = "Space", DELETE = "Delete",
        INSERT = "Insert", HOME = "Home", END = "End",
        PAGE_UP = "PageUp", PAGE_DOWN = "PageDown",
        UP = "Up", DOWN = "Down", LEFT = "Left", RIGHT = "Right",
    }
    for k, label in pairs(pretty) do
        if type(Keys[k]) == "number" then KEY_NAMES[Keys[k]] = label end
    end
    for i = 1, 12 do
        local v = Keys["F" .. i]
        if type(v) == "number" then KEY_NAMES[v] = "F" .. i end
    end
end

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
-- SUR UN CARACTERE IMPRIMABLE, SHIFT EST DEJA DANS LE CODE.
--
-- Le piege coute une touche entiere et ne se voit pas a la relecture : sur un
-- clavier francais, « + » se tape Shift+=. `gfx.getchar` rend donc 43 AVEC le
-- bit Shift leve, et une liaison declaree « 43, aucun modificateur » ne
-- correspond jamais. On tente donc l'accord exact d'abord — pour que
-- Shift+Fleche reste distinct de Fleche — puis, pour les caracteres
-- imprimables SEULEMENT, le meme code sans Shift. Les touches non imprimables
-- (fleches, Suppr, Espace) ne beneficient pas du repli : la, Shift veut dire
-- quelque chose.
function Keymap.Key(name, char, mask)
    local m = mods_reg[name]
    if not m or not char then return nil end
    if m.dirty then reindex(m) end
    local kk = m.keys[char]
    if not kk then return nil end
    mask = mask or Keymap.Mods()
    local a = kk[mask]
    if a then return a end
    if char > 32 and char < 127 and (mask & 2) ~= 0 then
        return kk[mask & ~2]
    end
    return nil
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
            -- Le fichier ecrit « Ctrl+Shift » parce qu'il se relit ; la table
            -- travaille en masque. Les deux entrent.
            local mask = type(v.mods) == "number" and v.mods
                         or Keymap.ParseMods(v.mods)
            m.bind[act] = { ctx = (v.ctx ~= "" and v.ctx) or nil,
                            g = (v.g ~= "" and v.g) or nil,
                            k = v.k, mods = mask }
        end
    end
    m.dirty = true
end

-- RELIRE LE FICHIER SANS RELANCER LE SCRIPT. C'est la moitie du confort d'un
-- fichier de configuration : on l'ouvre a cote, on change une ligne, on relit.
-- Sans ca il faut fermer et rouvrir la fenetre a chaque essai, et personne ne
-- fait trois essais dans ces conditions.
function Keymap.Reload(name)
    store = nil
    if name then
        Keymap.Reset(name)
        Keymap.ApplyOverrides(name)
        return true
    end
    for n in pairs(mods_reg) do
        Keymap.Reset(n)
        Keymap.ApplyOverrides(n)
    end
    return true
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

-- ---------------------------------------------------------------------------
-- LA CARTE, ECRITE EN CLAIR — la premiere forme de « configurable »
-- ---------------------------------------------------------------------------
-- REAPER a reaper-kb.ini bien avant d'avoir une fenetre pour le remplir, et
-- c'est le bon ordre : un fichier qu'on peut lire ET modifier vaut deja
-- l'essentiel, alors qu'une fenetre sur des liaisons qui n'existent pas ne vaut
-- rien. Celui-ci s'ecrit avec la carte COMPLETE, chaque action commentee de son
-- libelle, et se relit tel quel au demarrage.
--
-- SEULS LES MODIFICATEURS SE CHANGENT SUR UN GESTE DE SOURIS. La zone et le
-- geste sont la NATURE de l'action — « effacer une note » se fait sur une note
-- et au clic, sinon c'est une autre action — et REAPER lui-meme ne permet pas
-- de les deplacer. Sur une touche, le code ET les modificateurs se changent.
function Keymap.Export(name)
    local m = mods_reg[name]
    if not m then return false, "unknown module" end
    if m.dirty then reindex(m) end
    local out = {}
    local function w(l) out[#out + 1] = l end
    w("-- CP_Keymap — la carte des raccourcis et des modificateurs de CP_Scripts")
    w("--")
    w("-- Se modifie a la main. `mods` accepte \"Ctrl\", \"Shift\", \"Alt\", \"Win\",")
    w("-- separes par un +, ou une chaine vide pour aucun. `k` est le code que")
    w("-- gfx.getchar rend REELLEMENT (Ctrl+A arrive en 1) ; `ctx` et `g` sont la")
    w("-- nature du geste et ne se changent pas utilement.")
    w("--")
    w("-- Effacer une ligne rend son defaut a l'action. Effacer le fichier rend")
    w("-- tous les defauts.")
    w("return {")
    w("  [\"" .. name .. "\"] = {")
    local group
    for i = 1, #m.rows do
        local row = m.rows[i]
        local b = m.bind[row.act]
        if row.group ~= group then
            group = row.group
            w("")
            w("    -- ----- " .. tostring(group) .. " -----")
        end
        local slot
        if b.k then
            slot = string.format("k = %d, mods = %q", b.k, Keymap.ModsLabel(b.mods))
        else
            slot = string.format("ctx = %q, g = %q, mods = %q",
                                 b.ctx or "", b.g or "", Keymap.ModsLabel(b.mods))
        end
        w(string.format("    [%q] = { %s },   -- %s", row.act, slot, row.label))
    end
    w("  },")
    w("}")
    local path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Config/CP_Keymap.lua"
    local f = io.open(path, "w")
    if not f then return false, path end
    f:write(table.concat(out, "\n") .. "\n")
    f:close()
    return true, path
end

-- ---------------------------------------------------------------------------
-- LA CARTE A CHANGE AILLEURS — une fenetre ouverte doit l'apprendre
-- ---------------------------------------------------------------------------
-- La fenetre de reglages est un AUTRE script : elle ecrit le fichier, et les
-- fenetres deja ouvertes ne le savent pas. Les fermer une par une apres chaque
-- reglage est ce que personne ne fait — donc les reglages ne se testent jamais,
-- donc la fenetre ne sert a rien. Un tampon dans l'ExtState suffit : elle
-- l'incremente, les autres le lisent une fois par seconde et relisent le
-- fichier quand il bouge.
local sync_v, sync_t = nil, 0

function Keymap.PollSync(name)
    if not r then return false end
    local now = r.time_precise()
    if now < sync_t then return false end
    sync_t = now + 1.0
    local v = r.GetExtState("CP_Keymap", "version")
    if sync_v == nil then sync_v = v return false end
    if v == sync_v then return false end
    sync_v = v
    Keymap.Reload(name)
    return true
end

function Keymap.init(reaper_api, core, keys)
    r = reaper_api
    Core = core
    buildNames(keys)
    return Keymap
end

return Keymap
