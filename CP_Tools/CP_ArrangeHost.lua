-- @description Arrange Host (CP) — run CP_Session where the arrange view was
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   Hides REAPER's arrange band and gives the whole space to a CP window.
--   Run the action again to give REAPER its arrange back.
--
--   CP_Session must already be open and NOT docked. Requires js_ReaScriptAPI.

-- ---------------------------------------------------------------------------
-- CHANTIER 6, ETAPE 1 — ce que trois sondes ont rendu possible
-- ---------------------------------------------------------------------------
-- `CP_ArrangeProbe`, `CP_ArrangeBand` et `CP_ArrangePanel` ont mesure, dans cet
-- ordre : masquer la bande TIENT ; REAPER continue de CALCULER le rectangle de
-- l'arrangeur meme masque ; une fenetre gfx reparentee dans la fenetre
-- principale dessine, recoit la souris dans ses propres coordonnees, et recoit
-- le clavier des qu'on lui donne le focus.
--
-- D'ou la regle, qui est toute l'architecture :
--
--   ON NE TOUCHE JAMAIS A LA GEOMETRIE DE REAPER. On masque la bande, on LIT
--   le rectangle qu'il continue d'y calculer, et on y pose notre fenetre.
--   L'arrangeur invisible est l'ORACLE de disposition.
--
-- Il n'y a donc rien a intercepter, rien a ré-appliquer contre le gestionnaire
-- de disposition, et aucune extension a ecrire : on s'aligne sur lui.
--
-- ---------------------------------------------------------------------------
-- CE HOTE N'A PAS DE FENETRE, ET C'EST VOULU
-- ---------------------------------------------------------------------------
-- Toute la bande revient a l'application hebergee. Une fenetre de controle
-- prendrait de la place a la seule chose qu'on est venu agrandir, et il n'y a
-- rien a y afficher : ce script est un interrupteur. On le relance pour rendre
-- l'arrangeur — c'est le meme geste dans les deux sens, donc rien a apprendre.
--
-- ⚠️ ET C'EST LA QU'EST LE DANGER. Sans fenetre, il n'y a pas de bouton d'arret
-- et pas de touche a presser : si l'instance en cours mourait sans restaurer,
-- la bande resterait masquee et l'application resterait fille de la fenetre
-- principale, sans personne pour la placer. Quatre filets, donc :
--   · `atexit` restaure — donc tuer le script depuis la liste des actions suffit ;
--   · relancer l'action DEMANDE l'arret a l'instance vivante, qui restaure ;
--   · un battement dans l'ExtState dit si une instance est vivante, donc une
--     relance apres un plantage ne croit pas devoir parler a un fantome ;
--   · si la fenetre hebergee disparait sous nous, on restaure et on s'arrete.
-- Un plantage de REAPER lui-meme ne laisse rien : les fenetres se recreent au
-- demarrage suivant.
-- ---------------------------------------------------------------------------

local r = reaper

local SECTION = "CP_ArrangeHost"
local DEFAULT_TARGET = "CP Session"

if not r.JS_Window_SetParent then
    r.MB("This needs js_ReaScriptAPI.", "Arrange Host", 0)
    return
end

local MAIN = r.GetMainHwnd()
if not MAIN then return end

-- Publier notre action, comme toutes les fenetres de la suite. Ce sont les
-- boutons de vue qui la declenchent : sans cette cle ils sauraient quoi
-- demander mais pas a qui.
do
    local _, _, sec, cmd = r.get_action_context()
    if cmd and cmd ~= 0 and sec == 0 then
        local named = r.ReverseNamedCommandLookup(cmd)
        if named then r.SetExtState(SECTION, "cmd", "_" .. named, true) end
    end
end

-- ---------------------------------------------------------------------------
-- L'INTERRUPTEUR. Un battement, pas un simple drapeau : un drapeau laisse par
-- une instance morte ferait croire qu'elle est la, et la relance suivante lui
-- parlerait au lieu de demarrer. Une date se perime toute seule.
-- ---------------------------------------------------------------------------
local BEAT_STALE = 1.5

local function aliveElsewhere()
    local b = tonumber(r.GetExtState(SECTION, "beat") or "")
    return b and (r.time_precise() - b) < BEAT_STALE
end

-- ---------------------------------------------------------------------------
-- QUELLE VUE, ET POURQUOI CE N'EST PLUS UN SIMPLE INTERRUPTEUR
-- ---------------------------------------------------------------------------
-- L'hote ne connaissait qu'une fenetre, ecrite en dur. Avec un selecteur de
-- vue il en connait plusieurs, et « relancer l'action » ne veut plus dire la
-- meme chose selon ce qui est deja affiche :
--
--   meme vue que celle en place  -> c'est une BASCULE, on rend la bande ;
--   vue differente               -> c'est un CHANGEMENT, l'instance vivante
--                                   rend la fenetre en cours et prend l'autre,
--                                   SANS lacher la bande entre les deux.
--
-- Ce second cas doit etre fait par l'instance VIVANTE. La faire mourir puis en
-- lancer une autre marcherait aussi, mais entre les deux la bande reapparait,
-- l'arrangeur se redessine, et on verrait clignoter ce qu'on essaie justement
-- de ne plus voir. Une demande, pas une relance.
--
-- `want` est a USAGE UNIQUE : lu puis efface. Sinon lancer l'hote a la main
-- six mois plus tard rejouerait le dernier choix fait par un bouton, ce qui
-- est vrai mais imprevisible.
local TARGET = r.GetExtState(SECTION, "want")
if TARGET == nil or TARGET == "" then TARGET = DEFAULT_TARGET end
r.SetExtState(SECTION, "want", "", false)

if aliveElsewhere() then
    if r.GetExtState(SECTION, "target") == TARGET then
        r.SetExtState(SECTION, "stop", "1", false)
    else
        r.SetExtState(SECTION, "switch", TARGET, false)
    end
    return                       -- l'instance vivante fait le travail
end
r.SetExtState(SECTION, "stop", "", false)
r.SetExtState(SECTION, "switch", "", false)

-- ---------------------------------------------------------------------------
-- La cible
-- ---------------------------------------------------------------------------
local APP = r.JS_Window_Find(TARGET, true)
if not APP then
    r.MB("Open " .. TARGET .. " first, then run this again.\n\n"
         .. "It must be a floating window, not docked.", "Arrange Host", 0)
    return
end

-- UNE FENETRE DOCKEE APPARTIENT DEJA A QUELQU'UN. La reparenter la retirerait
-- du docker sans le lui dire, et REAPER continuerait a lui reserver son onglet.
-- On refuse en le DISANT, plutot que de la desamarrer dans son dos.
local dock_idx = r.DockIsChildOfDock and r.DockIsChildOfDock(APP) or -1
if dock_idx and dock_idx >= 0 then
    r.MB(TARGET .. " is docked.\n\nUndock it (drag it out, or its window menu),"
         .. " then run this again.", "Arrange Host", 0)
    return
end

-- ---------------------------------------------------------------------------
-- Geometrie
-- ---------------------------------------------------------------------------
local function rectOf(h)
    local ok, l, t, rt, b = r.JS_Window_GetRect(h)
    if not ok then return nil end
    return l, t, rt, b
end

-- GetRect rend de l'ECRAN ; SetWindowPos sur une fille attend du RELATIF AU
-- PARENT. Les confondre deplace ce qu'on croyait remettre — le piege a failli
-- coûter la restauration de la premiere sonde.
local function parentOrigin()
    local ok, l, t = r.JS_Window_GetClientRect(MAIN)
    if not ok then return 0, 0 end
    return l, t
end

-- ---------------------------------------------------------------------------
-- La bande : ses fenetres se reconnaissent a ce qu'elles SONT
-- ---------------------------------------------------------------------------
-- Deux classes servent de reperes — l'arrangeur et le TCP — et definissent une
-- etendue horizontale ; tout ce qui tient dedans et n'est pas un docker en fait
-- partie. Aucun identifiant code en dur : un numero de fenetre fille
-- n'appartient pas a l'API des extensions, donc le coder marcherait aujourd'hui
-- et mentirait a la prochaine version.
local band = {}

local function findBand()
    local kids = {}
    local arr = r.new_array({}, 1024)
    local n = r.JS_Window_ArrayAllChild(MAIN, arr)
    if not n or n < 1 then return false end
    local addr = arr.table(1, n)
    for i = 1, n do
        local h = r.JS_Window_HandleFromAddress(addr[i])
        if h and h ~= APP and r.JS_Window_GetParent(h) == MAIN then
            local l, _, rt = rectOf(h)
            if l and rt and rt > l and r.JS_Window_IsVisible(h) then
                kids[#kids + 1] = { h = h, l = l, r = rt,
                                    cls = r.JS_Window_GetClassName(h) or "?" }
            end
        end
    end
    local arrange, tcp
    for _, c in ipairs(kids) do
        if c.cls == "REAPERTrackListWindow" then arrange = c end
        if c.cls == "REAPERTCPDisplay"       then tcp = c end
    end
    if not arrange then return false end
    local bl = math.min(arrange.l, tcp and tcp.l or arrange.l)
    local br = math.max(arrange.r, tcp and tcp.r or arrange.r)
    for _, c in ipairs(kids) do
        if c.cls ~= "#32770" and c.l >= bl - 8 and c.r <= br + 8 then
            band[#band + 1] = c
        end
    end
    return #band > 0
end

-- L'ORACLE : l'union des rectangles de la bande, relue a chaque frame. REAPER
-- la maintient masquee ou non — c'est ce que la deuxieme sonde a prouve — et on
-- se contente de la lire. Rendre nil quand rien n'est mesurable EST une
-- reponse : on ne bouge alors pas la fenetre, plutot que de la poser au hasard.
local function bandRect()
    local l, t, rt, b
    for _, c in ipairs(band) do
        local a1, a2, a3, a4 = rectOf(c.h)
        if a1 then
            l  = l  and math.min(l, a1)  or a1
            t  = t  and math.min(t, a2)  or a2
            rt = rt and math.max(rt, a3) or a3
            b  = b  and math.max(b, a4)  or a4
        end
    end
    if not l or rt - l < 16 or b - t < 16 then return nil end
    return l, t, rt - l, b - t
end

if not findBand() then
    r.MB("Could not identify REAPER's arrange band. Nothing was touched.",
         "Arrange Host", 0)
    return
end

-- ---------------------------------------------------------------------------
-- Prise de possession, et la remise en etat — point de passage UNIQUE
-- ---------------------------------------------------------------------------
local app_style  = nil
local app_rect   = nil
local taken      = false
local done       = false

-- RENDRE LA FENETRE, SANS RENDRE LA BANDE. Extrait de restoreAll parce qu'un
-- changement de vue fait exactement ce geste-la et rien d'autre : la bande
-- reste masquee pendant qu'une fenetre part et qu'une autre arrive.
local function releaseApp()
    if not taken then return end
    taken = false
    if r.JS_Window_IsWindow(APP) then
        -- L'ORDRE COMPTE. Le style redevient celui d'une fenetre de premier
        -- rang AVANT le detachement, sinon on detache une fenetre encore
        -- marquee CHILD ; et la place se repose EN DERNIER, parce qu'un
        -- rectangle d'ECRAN pose sur une fenetre encore fille la met a un
        -- endroit qui n'existe pas.
        if app_style then
            pcall(r.JS_Window_SetLong, APP, "STYLE", app_style)
        end
        -- La forme A UN SEUL ARGUMENT est celle que la documentation decrit
        -- pour rendre la fenetre au bureau ; la forme a `nil` explicite n'est
        -- pas garantie de passer le pont ReaScript. On essaie donc celle qui
        -- est ecrite, et on garde l'autre en second.
        if not pcall(r.JS_Window_SetParent, APP) then
            pcall(r.JS_Window_SetParent, APP, nil)
        end
        if app_rect then
            r.JS_Window_SetPosition(APP, app_rect.l, app_rect.t,
                                    app_rect.w, app_rect.h)
        end
        r.JS_Window_Show(APP, "SHOW")
    end
    app_style, app_rect = nil, nil
end

local function restoreAll()
    if done then return end
    done = true
    r.SetExtState(SECTION, "beat", "", false)
    r.SetExtState(SECTION, "stop", "", false)
    r.SetExtState(SECTION, "switch", "", false)
    r.SetExtState(SECTION, "target", "", false)
    releaseApp()
    for _, c in ipairs(band) do r.JS_Window_Show(c.h, "SHOW") end
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    if r.JS_Window_SetFocus then pcall(r.JS_Window_SetFocus, MAIN) end
end
r.atexit(restoreAll)

-- ---------------------------------------------------------------------------
-- ⚠️ LE STYLE SE REND EN CHIFFRES, PAS EN MOTS
-- ---------------------------------------------------------------------------
-- `JS_Window_SetStyle` prend une liste de noms et rend une chaine — mais la
-- documentation ne dit PAS si c'est l'ancien style ou le nouveau. Restaurer
-- avec cette chaine, c'est parier ; et si le pari est perdu on rend a Cedric
-- une fenetre CP_Session sans barre de titre, qu'il ne peut plus ni deplacer ni
-- fermer. Pire : la suite sait ouvrir ses fenetres SANS CADRE
-- (`Core.SetFrameless`), donc « remettre un cadre standard » n'est pas non plus
-- une reponse — ce serait defaire un reglage qu'il a choisi.
--
-- On lit donc le style NUMERIQUE avant d'y toucher, et on le repose tel quel.
-- Un aller-retour exact, sans interpretation.
local WS_CHILD     = 0x40000000
local WS_POPUP     = 0x80000000
local WS_CAPTION   = 0x00C00000
local WS_THICKFRAME = 0x00040000
local WS_SYSMENU   = 0x00080000

local applied = ""

-- ⚠️ `taken` SE POSE AVANT LE PREMIER GESTE, PAS APRES LE DERNIER.
-- Il etait mis a la fin du bloc, ce qui paraissait honnete — « on ne declare
-- possede que ce qu'on possede vraiment ». C'etait l'inverse d'un garde-fou :
-- si SetLong passait et que SetParent echouait, restoreAll sortait au test
-- `if taken` et NE REPOSAIT PAS LE STYLE. Cedric se retrouvait avec une
-- CP_Session sans barre de titre, sans bordure et sans menu systeme —
-- ni deplacable, ni fermable. Exactement ce que le long commentaire ci-dessus
-- cherchait a eviter, rate d'une ligne.
--
-- Le drapeau ne dit pas « j'ai reussi », il dit « j'ai commence a toucher ».
-- Reposer un style qu'on n'a pas modifie ne coute rien ; ne pas reposer celui
-- qu'on a modifie coute la fenetre.
local function takeApp(h)
    APP = h
    local l, t, rt, b = rectOf(APP)
    app_rect = l and { l = l, t = t, w = rt - l, h = b - t } or nil
    app_style = math.floor(r.JS_Window_GetLong(APP, "STYLE") or 0) & 0xFFFFFFFF
    taken = true
    -- CHILD, et pas seulement « fille par le parent ». Sans ce bit la fenetre
    -- reste une popup possedee : elle garde son cadre, elle flotte au-dessus, et
    -- elle n'est pas clippee par la fenetre principale. On retire du meme geste
    -- ce qui n'a plus de sens dans un panneau — cadre, bordure, menu systeme.
    local child = (app_style
                   & ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU))
                  | WS_CHILD
    r.JS_Window_SetLong(APP, "STYLE", child & 0xFFFFFFFF)
    r.JS_Window_SetParent(APP, MAIN)
    -- ON VERIFIE LE RESULTAT, PAS LE GESTE. SetParent peut ne rien faire sans
    -- rien dire ; on aurait alors une fenetre de premier rang portant le bit
    -- CHILD, c'est-a-dire cassee des deux cotes.
    if r.JS_Window_GetParent(APP) ~= MAIN then
        releaseApp()
        return false
    end
    applied = ""      -- la place se recalcule, l'ancienne ne veut plus rien dire
    r.SetExtState(SECTION, "target", TARGET, false)
    return true
end

if not takeApp(APP) then
    r.MB("Could not reparent " .. TARGET .. ". Nothing was changed.", "Arrange Host", 0)
    return
end

for _, c in ipairs(band) do r.JS_Window_Show(c.h, "HIDE") end
r.TrackList_AdjustWindows(false)

-- ---------------------------------------------------------------------------
-- La boucle
-- ---------------------------------------------------------------------------

-- LA BOUCLE GARDIENNE EST OBLIGATOIRE, et on ne l'a su qu'en regardant
-- quelqu'un se servir de REAPER : la visibilite n'est pas reaffirmee par une
-- passe de disposition, mais elle l'est pendant un GLISSEMENT DE SEPARATEUR —
-- cent soixante-seize fois en vingt secondes. Cinq lectures par frame.
local function keeper()
    for _, c in ipairs(band) do
        if r.JS_Window_IsVisible(c.h) then r.JS_Window_Show(c.h, "HIDE") end
    end
end

local function follow()
    local l, t, w, h = bandRect()
    if not w then return end
    local key = l .. "," .. t .. "," .. w .. "," .. h
    if key == applied then return end
    applied = key
    local ox, oy = parentOrigin()
    r.JS_Window_SetPosition(APP, l - ox, t - oy, w, h)
end

-- ---------------------------------------------------------------------------
-- LE FOCUS SE PREND AU CLIC, PAS AU SURVOL
-- ---------------------------------------------------------------------------
-- La sonde a valide « le focus suit la souris », et c'est agreable — mais ici
-- la bande occupe presque tout l'ecran : le pointeur la traverse sans arret, et
-- REAPER perdrait la barre d'espace chaque fois qu'on passe dessus. On
-- chercherait alors du cote du transport un defaut qui vient d'ailleurs.
--
-- ---------------------------------------------------------------------------
-- ⚠️ « DANS LE RECTANGLE » N'EST PAS « SUR NOTRE FENETRE »
-- ---------------------------------------------------------------------------
-- La premiere version comparait la position du pointeur au RECTANGLE de la
-- bande. Or la bande occupe presque tout l'ecran : n'importe quelle fenetre
-- posee par-dessus — la liste des actions, un navigateur d'effets, une boite de
-- dialogue — tombe dedans. On lui volait donc le focus a chaque clic, et elle
-- devenait inutilisable : on tape, rien n'arrive, et la fenetre a l'air de
-- clignoter sans raison.
--
-- La geometrie ne repond pas a la question « qui est sous le doigt ». Seul le
-- gestionnaire de fenetres le sait, et il le dit : `JS_Window_FromPoint`. On
-- remonte ensuite la chaine des parents, parce qu'un clic tombe sur une
-- fenetre INTERNE a l'application, pas sur elle.
--
-- Et une garde avant tout le reste : si la fenetre de PREMIER PLAN n'est pas
-- celle de REAPER, quelqu'un d'autre a la main et on ne touche a rien. Notre
-- fenetre etant fille de la principale, le premier plan reste REAPER quand elle
-- a le focus — la garde ne coute donc rien au cas normal.
--
-- ENFIN, ON NE REPREND PAS LE FOCUS A LA PLACE DE REAPER. Rendre le clavier a
-- la fenetre principale des qu'on clique ailleurs paraissait symetrique, mais
-- « ailleurs » inclut les fenetres DOCKEES — le navigateur, l'editeur — qui
-- prennent le focus toutes seules et a qui on l'aurait aussitot repris. On ne
-- le rend donc explicitement que pour un clic sur la fenetre principale
-- ELLE-MEME ; partout ailleurs, REAPER fait deja ce qu'il faut.
local HOVER_FOCUS = false
local was_down = false

local function isDescendant(w, of)
    local hops = 0
    while w and hops < 24 do
        if w == of then return true end
        w = r.JS_Window_GetParent(w)
        hops = hops + 1
    end
    return false
end

local function focusPolicy()
    local ms = r.JS_Mouse_GetState(1)
    local down = (ms & 1) == 1
    local edge = down and not was_down
    was_down = down
    if not (edge or HOVER_FOCUS) then return end
    if r.JS_Window_GetForeground() ~= MAIN then return end
    local mx, my = r.GetMousePosition()
    local under = r.JS_Window_FromPoint(mx, my)
    if not under then return end
    if isDescendant(under, APP) then
        if r.JS_Window_GetFocus() ~= APP then r.JS_Window_SetFocus(APP) end
    elseif under == MAIN then
        if r.JS_Window_GetFocus() == APP then r.JS_Window_SetFocus(MAIN) end
    end
end

-- CHANGER DE VUE SANS RENDRE LA BANDE. La fenetre demandee doit exister : les
-- boutons de vue la remontent ou la lancent AVANT de demander, precisement
-- pour que ce chemin-ci n'ait jamais a ouvrir une boite de dialogue depuis une
-- boucle differee. Si elle n'est pas la, ou si elle est dockee, on garde ce
-- qu'on affiche — refuser en silence vaut mieux que rendre l'ecran a
-- l'arrangeur pour une demande qu'on n'a pas pu satisfaire.
local function switchTo(title)
    if title == TARGET then return true end
    local h = r.JS_Window_Find(title, true)
    if not h or h == APP then return true end
    if r.DockIsChildOfDock and (r.DockIsChildOfDock(h) or -1) >= 0 then return true end
    local prev_app, prev_target = APP, TARGET
    releaseApp()
    TARGET = title
    if not takeApp(h) then
        -- La reprise a echoue : on remet celle d'avant plutot que de laisser la
        -- bande masquee devant rien. Sauf si elle a disparu entre-temps — on
        -- vient de la rendre au bureau, elle a pu etre fermee dans l'intervalle,
        -- et reprendre un handle mort ferait de la panne un plantage.
        if not r.JS_Window_IsWindow(prev_app) then return false end
        TARGET = prev_target
        return takeApp(prev_app)
    end
    return true
end

local function loop()
    if r.GetExtState(SECTION, "stop") == "1" then restoreAll() return end
    local sw = r.GetExtState(SECTION, "switch")
    if sw ~= "" then
        r.SetExtState(SECTION, "switch", "", false)
        if not switchTo(sw) then restoreAll() return end
    end
    -- LA FENETRE HEBERGEE PEUT MOURIR SOUS NOUS — l'application se ferme, le
    -- script est tue. Continuer a la placer viserait un handle mort, et laisser
    -- la bande masquee donnerait un ecran vide sans rien pour l'expliquer.
    if not r.JS_Window_IsWindow(APP) then restoreAll() return end
    r.SetExtState(SECTION, "beat", tostring(r.time_precise()), false)
    keeper()
    follow()
    focusPolicy()
    r.defer(loop)
end

r.defer(loop)
