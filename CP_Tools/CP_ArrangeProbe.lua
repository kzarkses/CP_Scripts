-- @description Arrange Probe (CP) — can the arrange view be removed?
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   MEASURES whether REAPER's arrange view can be hidden, flattened or moved
--   out of the way, and whether the change SURVIVES a layout pass. Reports and
--   restores everything it touched. Changes nothing in the project.
--
--   Requires js_ReaScriptAPI.

-- ---------------------------------------------------------------------------
-- POURQUOI CE FICHIER EXISTE
-- ---------------------------------------------------------------------------
-- « On ne peut PAS retirer entierement l'arrangeur ? » J'ai repondu non, et
-- j'ai repondu en RAISONNANT : REAPER refait sa disposition, il remettra la
-- fenetre, et une fenetre invisible recevrait quand meme les clics. La
-- troisieme affirmation etait fausse — une fenetre masquee par ShowWindow ne
-- fait plus de hit-test — et les deux premieres n'avaient ete verifiees par
-- personne.
--
-- Le depot a une regle pour ca, et elle a ete ecrite le jour meme : c'est une
-- MESURE, pas une croyance. Ce script est la mesure.
--
-- ---------------------------------------------------------------------------
-- CE QU'IL FAIT, ET CE QU'IL NE FAIT PAS
-- ---------------------------------------------------------------------------
-- Il inventorie les fenetres filles de la fenetre principale, en choisit une
-- comme cible, et lui applique quatre gestes l'un apres l'autre. Apres chaque
-- geste il PROVOQUE une passe de disposition — deux fois, par deux chemins
-- differents — puis il remesure. La question n'est jamais « est-ce que ca a
-- marche » mais « est-ce que ca a TENU ».
--
-- Il ne touche a aucune piste, aucun item, aucun reglage de projet. Le seul
-- effet de bord est visuel, et il dure quelques secondes.
--
-- TROIS FILETS, parce qu'un script qui masque une fenetre de l'hote doit
-- pouvoir echouer sans laisser REAPER inutilisable :
--   · chaque etape restaure AVANT de passer a la suivante ;
--   · `atexit` restaure, donc tuer le script depuis la liste des actions suffit ;
--   · une echeance absolue restaure et s'arrete, meme si la machine a etats se
--     perd.
-- ---------------------------------------------------------------------------

local r = reaper

if not r.JS_Window_ArrayAllChild then
    r.MB("This probe needs js_ReaScriptAPI.\n\n"
         .. "Install it from ReaPack (js_ReaScriptAPI: API functions for ReaScripts), "
         .. "restart REAPER, and run again.", "Arrange Probe", 0)
    return
end

local MAIN = r.GetMainHwnd()
if not MAIN then return end

-- ---------------------------------------------------------------------------
-- Rapport
-- ---------------------------------------------------------------------------
local out = {}
local function say(s) out[#out + 1] = s or "" end
local function flush()
    r.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
    for i = #out, 1, -1 do out[i] = nil end
end

-- ---------------------------------------------------------------------------
-- Mesure
-- ---------------------------------------------------------------------------
local function rectOf(h)
    local ok, l, t, rt, b = r.JS_Window_GetRect(h)
    if not ok then return nil end
    return l, t, rt - l, b - t
end

-- ---------------------------------------------------------------------------
-- ⚠️ DEUX REPERES DIFFERENTS, ET LES CONFONDRE DEPLACE LA FENETRE
-- ---------------------------------------------------------------------------
-- `JS_Window_GetRect` rend des coordonnees ECRAN. `SetWindowPos` sur une
-- fenetre FILLE les attend relatives a la zone cliente du PARENT. Redonner a
-- une fille son rectangle ecran la deplacerait donc de l'origine de la fenetre
-- principale — c'est-a-dire que la « restauration » aurait ete le geste
-- destructeur. Sur un script dont tout l'interet est de pouvoir tout remettre,
-- c'etait la seule faute qui comptait vraiment.
local function parentOrigin()
    local ok, l, t = r.JS_Window_GetClientRect(MAIN)
    if not ok then return 0, 0 end
    return l, t
end

-- Le rectangle d'une fille, dans le repere ou on pourra le lui rendre.
local function relRectOf(h)
    local l, t, w, hh = rectOf(h)
    if not l then return nil end
    local ox, oy = parentOrigin()
    return l - ox, t - oy, w, hh
end

-- L'ETAT COMPLET D'UNE FENETRE EN UNE CHAINE. C'est ce qu'on compare avant et
-- apres une passe de disposition : une seule chaine, donc une seule chose a
-- lire, et aucune tolerance a choisir.
local function stateOf(h)
    local l, t, w, hh = rectOf(h)
    if not l then return "gone" end
    return string.format("%s %d,%d %dx%d",
        r.JS_Window_IsVisible(h) and "vis" or "HID", l, t, w, hh)
end

-- ---------------------------------------------------------------------------
-- Inventaire — les filles DIRECTES de la fenetre principale
-- ---------------------------------------------------------------------------
-- `ArrayAllChild` rend toute la descendance ; on garde celles dont le parent
-- est la fenetre principale, parce que c'est a ce niveau que REAPER pose sa
-- disposition.
local children = {}

local function inventory()
    local arr = r.new_array({}, 1024)
    local n = r.JS_Window_ArrayAllChild(MAIN, arr)
    if not n or n < 1 then return end
    local addr = arr.table(1, n)
    for i = 1, n do
        local h = r.JS_Window_HandleFromAddress(addr[i])
        if h and r.JS_Window_GetParent(h) == MAIN then
            local l, t, w, hh = rectOf(h)
            children[#children + 1] = {
                h = h,
                id = math.floor(r.JS_Window_GetLong(h, "ID") or 0),
                cls = r.JS_Window_GetClassName(h) or "?",
                title = r.JS_Window_GetTitle(h) or "",
                l = l or 0, t = t or 0, w = w or 0, hh = hh or 0,
                vis = r.JS_Window_IsVisible(h),
            }
        end
    end
    table.sort(children, function(a, b) return a.w * a.hh > b.w * b.hh end)
end

-- LA CIBLE SE CHOISIT SUR CE QU'ELLE EST, PAS SUR UN NUMERO APPRIS PAR COEUR.
-- Un identifiant de fenetre fille n'appartient pas a l'API des extensions : le
-- coder en dur marcherait aujourd'hui et mentirait a la prochaine version. On
-- prend donc la classe quand elle se nomme, et la plus grande fille visible
-- sinon — l'arrangeur est, par construction, ce qui occupe le plus de place.
local function pickTarget()
    for _, c in ipairs(children) do
        if c.vis and c.cls:find("TrackList") then return c, "class contains TrackList" end
    end
    for _, c in ipairs(children) do
        if c.vis and c.w > 200 and c.hh > 100 then
            return c, "largest visible child"
        end
    end
    return nil, "nothing plausible"
end

-- ---------------------------------------------------------------------------
-- Provoquer une passe de disposition
-- ---------------------------------------------------------------------------
-- Deux chemins DIFFERENTS, parce qu'ils ne passent pas par le meme code de
-- REAPER et qu'un geste peut survivre a l'un et pas a l'autre :
--   · `TrackList_AdjustWindows` demande explicitement la remise en place de la
--     liste de pistes — c'est le chemin interne ;
--   · afficher puis cacher le melangeur redimensionne la fenetre principale —
--     c'est le chemin par WM_SIZE, celui que tout redimensionnement emprunte.
local function nudgeInternal()
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
end

-- SYMETRIQUE PAR CONSTRUCTION. Comparer l'etat du basculement avant/apres
-- paraissait plus prudent, mais `GetToggleCommandState` peut rendre -1 quand il
-- ne sait pas : les deux lectures auraient alors ete egales, on n'aurait pas
-- rebascule, et le melangeur de Cedric serait reste ouvert a cause d'une sonde.
-- Un aller, un retour, sans rien interroger.
local function nudgeResizeBegin() r.Main_OnCommand(40078, 0) end   -- mixer
local function nudgeResizeEnd()   r.Main_OnCommand(40078, 0) end

-- ---------------------------------------------------------------------------
-- La cible, et son etat d'origine
-- ---------------------------------------------------------------------------
local T          = nil     -- la fille ciblee
local orig       = nil     -- { l, t, w, h, vis } — l,t RELATIFS au parent
local restored   = true

local function restore()
    if restored or not T or not orig then return end
    restored = true
    r.JS_Window_SetPosition(T.h, orig.l, orig.t, orig.w, orig.h)
    r.JS_Window_Show(T.h, orig.vis and "SHOW" or "HIDE")
    nudgeInternal()
end
r.atexit(restore)

-- ---------------------------------------------------------------------------
-- Les gestes a mettre a l'epreuve
-- ---------------------------------------------------------------------------
-- Chacun rend une phrase courte : c'est elle qui sera imprimee a cote du
-- verdict, donc elle doit dire le GESTE et non son intention.
local TRIALS = {
    { name = "ShowWindow HIDE",
      apply = function() r.JS_Window_Show(T.h, "HIDE") end },
    { name = "height set to 0",
      apply = function()
          r.JS_Window_SetPosition(T.h, orig.l, orig.t, orig.w, 0)
      end },
    { name = "moved off-screen",
      apply = function()
          r.JS_Window_SetPosition(T.h, -32000, -32000, orig.w, orig.h)
      end },
    { name = "HIDE + zero height",
      apply = function()
          r.JS_Window_SetPosition(T.h, orig.l, orig.t, orig.w, 0)
          r.JS_Window_Show(T.h, "HIDE")
      end },
}

-- ---------------------------------------------------------------------------
-- La machine a etats. Une etape par passage, avec des attentes REELLES entre
-- les gestes : une passe de disposition ne se produit pas dans la meme frame
-- que l'appel qui la demande, et mesurer trop tot rendrait « ca a tenu » pour
-- toutes les lignes.
-- ---------------------------------------------------------------------------
local HOLD    = 40         -- frames d'observation, pour que Cedric VOIE l'ecran
local SETTLE  = 12         -- frames apres une passe de disposition
local DEADLINE = 90        -- secondes : au-dela, on restaure et on s'arrete

local trial_i  = 0
local phase    = "next"
local wait     = 0
local applied, after_internal, after_resize = nil, nil, nil
local t_start  = r.time_precise()

local function beginTrial()
    trial_i = trial_i + 1
    local tr = TRIALS[trial_i]
    if not tr then return false end
    say(string.format("--- %d. %s", trial_i, tr.name))
    restored = false
    tr.apply()
    nudgeInternal()          -- on ne mesure pas un geste que rien n'a bouscule
    return true
end

local function verdict(before, now)
    if now == before then return "HELD" end
    return "reverted  (" .. now .. ")"
end

local function step()
    if r.time_precise() - t_start > DEADLINE then
        say("")
        say("!! deadline reached — restoring and stopping")
        restore()
        flush()
        return
    end

    if wait > 0 then wait = wait - 1 r.defer(step) return end

    if phase == "next" then
        if not beginTrial() then
            say("")
            say("Everything above was restored. The project was not touched.")
            flush()
            return
        end
        applied = stateOf(T.h)
        say("    applied      : " .. applied)
        phase, wait = "internal", HOLD

    elseif phase == "internal" then
        -- premiere passe : le chemin interne
        nudgeInternal()
        after_internal = nil
        phase, wait = "internal_read", SETTLE

    elseif phase == "internal_read" then
        after_internal = stateOf(T.h)
        say("    after relayout: " .. verdict(applied, after_internal))
        nudgeResizeBegin()
        phase, wait = "resize_read", SETTLE

    elseif phase == "resize_read" then
        after_resize = stateOf(T.h)
        nudgeResizeEnd()
        say("    after WM_SIZE : " .. verdict(applied, after_resize))
        restore()
        phase, wait = "next", SETTLE
    end

    r.defer(step)
end

-- ---------------------------------------------------------------------------
-- Depart
-- ---------------------------------------------------------------------------
r.ShowConsoleMsg("")
say("CP Arrange Probe")
say("================")
say("")

inventory()
say(string.format("Direct children of the main window: %d", #children))
say("")
say(string.format("%-6s %-30s %-22s %s", "id", "class", "rect", "state"))
for _, c in ipairs(children) do
    say(string.format("%-6d %-30s %-22s %s",
        c.id, c.cls:sub(1, 30),
        string.format("%d,%d %dx%d", c.l, c.t, c.w, c.hh),
        c.vis and "visible" or "hidden"))
end
say("")

local why
T, why = pickTarget()
if not T then
    say("No plausible target (" .. why .. "). Nothing was touched.")
    flush()
    return
end

-- Le rectangle est retenu dans le repere du PARENT : c'est celui dans lequel on
-- pourra le rendre. Voir l'avertissement au-dessus de `parentOrigin`.
local rl, rt, rw, rh = relRectOf(T.h)
if not rl then
    say("Could not read the target's rectangle. Nothing was touched.")
    flush()
    return
end
orig = { l = rl, t = rt, w = rw, h = rh, vis = T.vis }
say(string.format("Target: id %d, class %s  (%s)", T.id, T.cls, why))
say(string.format("Original: %s", stateOf(T.h)))
say("")
say("Each trial holds for about a second so you can SEE the screen, then a")
say("relayout is forced twice: once through REAPER's own track-list adjust,")
say("once by toggling the mixer (which resizes the main window).")
say("")
say("MOST DECISIVE THING YOU CAN DO: drag the REAPER window's edge while a")
say("trial is holding. That is the real WM_SIZE, and it is the one that")
say("settles the question. Whatever you see on screen counts as evidence;")
say("the table below only reports what the API could measure.")
say("")
flush()

r.defer(step)
