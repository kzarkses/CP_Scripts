-- @description CP Dock Probe — peut-on desamarrer une fenetre de l'EXTERIEUR ?
-- @version 1.0
-- @author Cedric Pamalio
--
-- ---------------------------------------------------------------------------
-- CE QU'ON MESURE, ET POURQUOI CETTE SONDE NE TOUCHE RIEN A TOI
-- ---------------------------------------------------------------------------
-- `CP_ArrangeHost` REFUSE d'heberger une fenetre dockee. Ce refus n'a jamais
-- ete mesure : il repose sur deux affirmations que j'ai faites sans les
-- verifier — « seule une application peut se desamarrer elle-meme » et
-- « reparenter une fenetre dockee laisserait son onglet au docker ». La
-- premiere s'est deja revelee douteuse : `Dock_UpdateDockID(ident_str, dock)`
-- existe. Mais la documentation dit « on next OPEN », c'est-a-dire une
-- PREFERENCE et non un geste — ce qui, si c'est exact, ne desamarre rien de ce
-- qui est ouvert.
--
-- Trois questions, dans cet ordre :
--
--   A. une fenetre gfx de ReaScript possede-t-elle un ident_str exploitable ?
--      Teste en LECTURE SEULE avec GetConfigWantsDock, qui est le pendant en
--      lecture de Dock_UpdateDockID. Avec des temoins positifs : si aucun nom
--      connu de REAPER ne rend quoi que ce soit, c'est la mesure qui est
--      muette, pas la reponse qui est non.
--
--   B. Dock_UpdateDockID accepte-t-il d'ecrire pour un de ces noms, et la
--      valeur se relit-elle ? Ecrit puis REMET la valeur d'avant.
--
--   C. JS_Window_SetParent sort-il une fenetre dockee du docker, et le docker
--      garde-t-il son onglet ? C'est la question qui decide du refus.
--
-- LA SONDE EST SA PROPRE COBAYE. Elle ouvre une fenetre a elle, la docke, et
-- experimente dessus. Aucune de tes fenetres n'est touchee : le pire cas coute
-- une fenetre de script, pas une disposition de docker.
-- ---------------------------------------------------------------------------

local r = reaper

local TITLE = "CP Dock Probe"

if not r.JS_Window_Find then
    r.MB("This needs js_ReaScriptAPI.", TITLE, 0)
    return
end

local log = {}
local function say(s) log[#log + 1] = s end

-- ---------------------------------------------------------------------------
-- Notre cobaye : notre propre fenetre, dockee
-- ---------------------------------------------------------------------------
-- dock=1 : le bit 1 dit « dockee », le reste designe le docker. On prend celui
-- par defaut ; le but n'est pas de choisir un emplacement mais d'EN AVOIR un.
gfx.init(TITLE, 360, 120, 1, 200, 200)
gfx.setfont(1, "Arial", 14)

local SELF = r.JS_Window_Find(TITLE, true)
if not SELF then
    gfx.quit()
    r.MB("Could not find my own window by title. Nothing was measured.", TITLE, 0)
    return
end

local MAIN = r.GetMainHwnd()

-- ---------------------------------------------------------------------------
-- A + B : l'ident_str, en lecture d'abord
-- ---------------------------------------------------------------------------
-- Les quatre premiers sont des TEMOINS : ce sont des fenetres de REAPER qui ont
-- forcement un ident_str. S'ils rendent tous la meme chose que nos candidats,
-- la fonction ne distingue rien et la mesure ne prouve rien.
local CANDIDATES = {
    { "mixer",            "temoin REAPER" },
    { "midiedit",         "temoin REAPER" },
    { "actions",          "temoin REAPER" },
    { "explorer",         "temoin REAPER" },
    { TITLE,              "notre titre gfx" },
    { "CP Dock Probe",    "notre titre, ecrit en clair" },
    { "CP_DockProbe",     "un identifiant sans espaces" },
    { "reascript",        "au cas ou gfx partagerait un nom commun" },
}

local function readWants()
    if not r.GetConfigWantsDock then
        say("GetConfigWantsDock ABSENT de cette version de REAPER — A et B sautes.")
        return nil
    end
    say("A. GetConfigWantsDock (lecture seule)")
    local seen = {}
    for _, c in ipairs(CANDIDATES) do
        local v = r.GetConfigWantsDock(c[1])
        seen[c[1]] = v
        say(("   %-18s -> %-6s  (%s)"):format(c[1], tostring(v), c[2]))
    end
    return seen
end

-- ---------------------------------------------------------------------------
-- C : le reparentage d'une fenetre dockee
-- ---------------------------------------------------------------------------
local dock_before, float_before = -1, false
local parent_before = nil
local moved = false

local function measureDock(when)
    local idx, isfloat = -1, false
    if r.DockIsChildOfDock then idx, isfloat = r.DockIsChildOfDock(SELF) end
    local par = r.JS_Window_GetParent(SELF)
    say(("   %-8s dock=%-4s flottant=%-5s parent=%s"):format(
        when, tostring(idx), tostring(isfloat),
        par == MAIN and "MAIN" or (par and "autre" or "aucun")))
    return idx, isfloat, par
end

-- ---------------------------------------------------------------------------
-- Le deroule, en pas separes par des frames : REAPER doit avoir le temps de
-- redessiner entre « on a bouge » et « qu'est-ce que ca a donne ».
-- ---------------------------------------------------------------------------
local step, t_next = 0, 0
local done = false

local function restore()
    if done then return end
    done = true
    if moved and r.JS_Window_IsWindow(SELF) then
        -- On remet le parent d'origine. Meme si ca echoue, la fenetre est a
        -- nous : elle disparaitra avec le script.
        if parent_before then pcall(r.JS_Window_SetParent, SELF, parent_before)
        else pcall(r.JS_Window_SetParent, SELF) end
    end
end
r.atexit(function()
    restore()
    if #log > 0 then
        r.ShowConsoleMsg("\n===== CP Dock Probe =====\n"
                         .. table.concat(log, "\n") .. "\n=========================\n")
    end
end)

local function draw()
    gfx.set(0.11, 0.11, 0.12, 1); gfx.rect(0, 0, gfx.w, gfx.h, 1)
    gfx.set(0.85, 0.86, 0.86, 1)
    gfx.x, gfx.y = 10, 10
    gfx.drawstr("CP Dock Probe — step " .. step .. "/5")
    gfx.x, gfx.y = 10, 34
    gfx.drawstr("Close this window to finish.")
    gfx.x, gfx.y = 10, 58
    gfx.drawstr("The report goes to the ReaScript console.")
    gfx.update()
end

local function loop()
    if gfx.getchar() < 0 then return end   -- fenetre fermee : atexit fait le reste
    draw()

    local now = r.time_precise()
    if now < t_next then r.defer(loop) return end
    t_next = now + 0.6

    if step == 0 then
        say("Sonde du " .. os.date("%Y-%m-%d %H:%M"))
        say("")
        readWants()
        say("")
        say("C. Etat de depart de NOTRE fenetre")
        dock_before, float_before, parent_before = measureDock("depart")
        if dock_before < 0 then
            say("   -> Notre fenetre n'est PAS dockee. REAPER a ignore le dockstate")
            say("      demande a gfx.init. La question C ne peut pas etre posee ;")
            say("      docke cette fenetre a la main et relance la sonde.")
            step = 99
        end

    elseif step == 1 then
        say("")
        say("B. Dock_UpdateDockID (ecriture, puis remise en etat)")
        if r.Dock_UpdateDockID and r.GetConfigWantsDock then
            for _, c in ipairs(CANDIDATES) do
                local was = r.GetConfigWantsDock(c[1])
                local probe_val = ((was or 0) == 3) and 1 or 3
                r.Dock_UpdateDockID(c[1], probe_val)
                local now_v = r.GetConfigWantsDock(c[1])
                local took = (now_v == probe_val)
                say(("   %-18s ecrit=%s relu=%s -> %s"):format(
                    c[1], tostring(probe_val), tostring(now_v),
                    took and "ACCEPTE" or "ignore"))
                r.Dock_UpdateDockID(c[1], was or 0)      -- on repose ce qu'on a pris
            end
        else
            say("   Dock_UpdateDockID absent.")
        end

    elseif step == 2 then
        say("")
        say("   effet immediat sur NOTRE fenetre :")
        measureDock("apres B")

    elseif step == 3 then
        say("")
        say("C. JS_Window_SetParent(notre fenetre, MAIN)")
        moved = true
        local ok = pcall(r.JS_Window_SetParent, SELF, MAIN)
        say("   l'appel a " .. (ok and "passe" or "LEVE une erreur"))

    elseif step == 4 then
        measureDock("apres C")
        say("")
        say("   REGARDE LE DOCKER MAINTENANT, c'est la vraie question :")
        say("   l'onglet « CP Dock Probe » y est-il encore, vide ?")
        say("   - onglet parti      -> le reparentage desamarre vraiment,")
        say("                          et le refus de CP_ArrangeHost est a lever.")
        say("   - onglet fantome    -> le refus est juste, il faut passer par")
        say("                          l'application elle-meme.")

    elseif step == 5 then
        restore()
        say("")
        say("   remis en place :")
        measureDock("restaure")
        say("")
        say("Ferme la fenetre pour ecrire le rapport dans la console.")
    end

    if step ~= 99 then step = step + 1 end
    if step > 5 then step = 5; t_next = now + 3600 end
    r.defer(loop)
end

r.defer(loop)
