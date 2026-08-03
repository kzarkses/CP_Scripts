-- @description CP View — le moteur des boutons de vue (ne pas lancer directement)
-- @version 1.0
-- @author Cedric Pamalio
--
-- ---------------------------------------------------------------------------
-- CE QU'UN BOUTON DE VUE DOIT FAIRE, ET DANS QUEL ORDRE
-- ---------------------------------------------------------------------------
-- « Mets CP_Session a la place de l'arrangeur » est une phrase courte qui
-- recouvre quatre etats possibles, et les confondre donne un bouton qui marche
-- une fois sur deux :
--
--   1. la fenetre ne tourne pas          -> la lancer, ATTENDRE qu'elle existe,
--                                           puis demander la bande ;
--   2. elle tourne, la bande est libre   -> demarrer l'hote sur elle ;
--   3. elle tourne, l'hote affiche autre -> demander un CHANGEMENT a l'hote,
--                                           qui garde la bande masquee entre
--                                           les deux ;
--   4. elle est deja a l'ecran           -> ne rien faire. Surtout pas relancer
--                                           l'hote : sa relance est une bascule,
--                                           et le bouton « Session » aurait
--                                           rendu l'arrangeur.
--
-- Le cas 1 est la raison pour laquelle ce fichier defere. Lancer une action ne
-- fait pas apparaitre la fenetre dans la ligne suivante ; demander la bande
-- tout de suite echouerait sur une fenetre qui n'existe pas encore, et
-- l'echec serait silencieux.
--
-- ---------------------------------------------------------------------------
-- POURQUOI UN MOTEUR ET TROIS LANCEURS
-- ---------------------------------------------------------------------------
-- Un bouton de barre declenche une ACTION, et un fichier de script ne porte
-- qu'une action : trois boutons, trois fichiers. Mais pas trois copies de ce
-- raisonnement — les lanceurs disent seulement QUELLE vue, et chargent
-- celui-ci. C'est la meme forme que les lanceurs de barre flottante, pour la
-- meme raison : ce qui est duplique finit par diverger.
-- ---------------------------------------------------------------------------

local r = reaper

-- "arrange", ou { section = <cle ExtState de l'app>, title = <titre EXACT> }
local VIEW = rawget(_G, "CP_VIEW")
if not VIEW then
    r.MB("CP_View.lua is the engine behind the view buttons — it is not meant "
         .. "to be run on its own.\n\nRun CP_ViewArrange, CP_ViewSession or "
         .. "CP_ViewFX instead.", "CP View", 0)
    return
end

local HOST       = "CP_ArrangeHost"
local BEAT_STALE = 1.5     -- la meme peremption que l'hote s'applique a lui-meme
local APP_STALE  = 2.0     -- celle de Bus.FocusApp : battement de 0,5 s, trois rates tolerees
local WAIT_MAX   = 5.0     -- au-dela, l'application ne demarre pas et on le dit

-- ---------------------------------------------------------------------------
-- Lire l'etat, sans rien supposer
-- ---------------------------------------------------------------------------
local function fresh(section, key, stale)
    local t = tonumber(r.GetExtState(section, key) or "")
    return t and (r.time_precise() - t) < stale
end

-- La vue actuellement dans la bande, ou nil si la bande appartient a
-- l'arrangeur. On exige le BATTEMENT en plus de la cle : un hote tue depuis la
-- liste des actions laisse `target` derriere lui, et cette cle seule ferait
-- croire que la session est affichee alors que l'arrangeur est revenu.
local function currentView()
    if not fresh(HOST, "beat", BEAT_STALE) then return nil end
    local t = r.GetExtState(HOST, "target")
    return (t ~= "") and t or nil
end

local function runAction(named)
    if not named or named == "" then return false end
    local id = r.NamedCommandLookup(named)
    if not id or id == 0 then return false end
    r.Main_OnCommand(id, 0)
    return true
end

-- ---------------------------------------------------------------------------
-- Arrange : rendre la bande
-- ---------------------------------------------------------------------------
if VIEW == "arrange" then
    -- Si aucun hote ne tourne, l'arrangeur EST deja la : ne rien faire est la
    -- bonne reponse, pas une omission.
    if currentView() then r.SetExtState(HOST, "stop", "1", false) end
    return
end

-- ---------------------------------------------------------------------------
-- Une application : la faire exister, puis demander la bande
-- ---------------------------------------------------------------------------
local SECTION = VIEW.section
local TITLE   = VIEW.title

-- Deja a l'ecran : le seul geste juste est de ne pas en faire.
if currentView() == TITLE then return end

if not r.JS_Window_Find then
    r.MB("This needs js_ReaScriptAPI.", "CP View", 0)
    return
end

-- L'hote refuse une fenetre DOCKEE, et il a raison tant qu'on ne sait pas la
-- desamarrer de l'exterieur. Le dire ICI plutot que de laisser la demande
-- partir : dans le chemin « changement de vue » l'hote refuse en silence, et un
-- bouton qui ne fait rien sans rien dire est pire qu'un bouton qui explique.
local function refuseIfDocked(h)
    if not (r.DockIsChildOfDock and h) then return false end
    local idx = r.DockIsChildOfDock(h)
    if not idx or idx < 0 then return false end
    r.MB(TITLE .. " is docked.\n\nUndock it (drag it out, or use its window "
         .. "menu), then click this again.", "CP View", 0)
    return true
end

local function askHost()
    local h = r.JS_Window_Find(TITLE, true)
    if not h then
        r.MB("Could not find the " .. TITLE .. " window.", "CP View", 0)
        return
    end
    if refuseIfDocked(h) then return end
    if currentView() then
        -- Un hote tient deja la bande : lui demander de changer de contenu.
        -- Relancer son action ferait une BASCULE, donc rendrait l'arrangeur si
        -- par hasard il affichait deja ce qu'on veut — d'ou le test plus haut.
        r.SetExtState(HOST, "switch", TITLE, false)
        return
    end
    -- Personne ne tient la bande : on nomme la cible, puis on demarre l'hote.
    -- `want` est a usage unique, l'hote le lit et l'efface.
    r.SetExtState(HOST, "want", TITLE, false)
    if not runAction(r.GetExtState(HOST, "cmd")) then
        r.MB("CP_ArrangeHost is not registered as an action yet.\n\nRun it once "
             .. "from the Actions list, then this button will work.", "CP View", 0)
    end
end

if fresh(SECTION, "alive", APP_STALE) then
    askHost()
    return
end

-- Pas vivante. On la lance par l'action qu'elle publie elle-meme — le meme
-- registre que Bus.FocusApp utilise, et la meme limite : une application jamais
-- lancee comme action n'a rien publie, donc on ne peut pas la demarrer.
if not runAction(r.GetExtState(SECTION, "cmd")) then
    r.MB(TITLE .. " is not running, and it is not registered as an action yet."
         .. "\n\nRun it once from the Actions list — after that this button can "
         .. "start it.", "CP View", 0)
    return
end

-- ATTENDRE LA FENETRE, PAS LE SCRIPT. Une action qui demarre ne rend pas la
-- main quand la fenetre est prete ; c'est son existence qu'il faut voir.
local deadline = r.time_precise() + WAIT_MAX
local function wait()
    if r.JS_Window_Find(TITLE, true) then askHost() return end
    if r.time_precise() > deadline then
        r.MB(TITLE .. " did not open within " .. math.floor(WAIT_MAX)
             .. " seconds.", "CP View", 0)
        return
    end
    r.defer(wait)
end
r.defer(wait)
