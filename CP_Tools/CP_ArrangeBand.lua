-- @description Arrange Band (CP) — hide the whole arrange band and hold
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   Hides EVERY window of REAPER's arrange band — TCP, ruler, track view and
--   the two strips around them — holds them hidden while you use REAPER, then
--   restores and reports. Measures whether REAPER keeps computing the arrange
--   rectangle while it is invisible.
--
--   Requires js_ReaScriptAPI. Touches no track, item or project setting.

-- ---------------------------------------------------------------------------
-- CE QUE LA PREMIERE SONDE A RENDU, ET POURQUOI CELLE-CI EXISTE
-- ---------------------------------------------------------------------------
-- Quatre gestes, deux passes de disposition chacun, un motif net :
--
--     ShowWindow HIDE      relayout: HELD      WM_SIZE: HELD
--     height set to 0      relayout: HELD      WM_SIZE: reverted
--     moved off-screen     relayout: HELD      WM_SIZE: reverted
--     HIDE + zero height   relayout: HELD      WM_SIZE: reverted (HID)
--
-- REAPER REMET LA GEOMETRIE, PAS LA VISIBILITE. La quatrieme ligne le prouve
-- deux fois : il a rendu ses 578x652 a la fenetre TOUT EN LA LAISSANT masquee.
--
-- Ce n'est pas un demi-succes, c'est le meilleur resultat possible. Les lignes
-- deux et trois disent que REAPER continue de CALCULER le rectangle de
-- l'arrangeur ; la ligne une dit qu'on peut le rendre invisible pour toujours.
-- Donc : on ne touche jamais a sa geometrie, on la LIT, et on pose notre propre
-- fenetre dessus. L'arrangeur invisible devient l'oracle de disposition, et
-- toute la classe « il faut ré-appliquer sans arret » disparait.
--
-- ---------------------------------------------------------------------------
-- CE QUE CELLE-CI MESURE, ET CE QU'ELLE NE PEUT PAS MESURER SEULE
-- ---------------------------------------------------------------------------
--   1. Les QUATRE AUTRES fenetres de la bande tiennent-elles aussi le masquage ?
--      La premiere sonde n'en avait teste qu'une.
--   2. REAPER met-il A JOUR le rectangle de l'arrangeur pendant qu'il est
--      masque ? C'est le pivot de l'architecture ci-dessus, et ca ne se mesure
--      qu'en le regardant sur la duree.
--   3. Qu'est-ce qui casse FONCTIONNELLEMENT — lecture, actions, onglets de
--      projet, screensets ? Ca, aucune API ne le repond : il faut s'en servir.
--      D'ou le maintien de vingt secondes, pendant lesquelles REAPER est a toi.
--
-- ⚠️ LE POINT 2 NE SE MESURE PAS TOUT SEUL. Si rien ne bouge pendant le
-- maintien, le rectangle ne bougera pas non plus, et le rapport dira « aucun
-- changement » — ce qui ne prouve RIEN. Il faut REDIMENSIONNER la fenetre de
-- REAPER pendant que ca tient. La fenetre de controle le redit a l'ecran,
-- parce qu'une mesure qu'on peut rater sans le savoir n'en est pas une.
--
-- ---------------------------------------------------------------------------
-- LES FILETS
-- ---------------------------------------------------------------------------
-- Masquer la moitie de l'interface de l'hote demande plus qu'un espoir :
--   · la liste de ce qui va etre masque est IMPRIMEE avant de l'etre, donc elle
--     existe meme si la suite tourne mal ;
--   · un clic, Echap, ou fermer la fenetre de controle restaure tout de suite ;
--   · une echeance absolue restaure sans qu'on demande rien ;
--   · `atexit` restaure, donc tuer le script depuis la liste des actions suffit ;
--   · la restauration est VERIFIEE, fenetre par fenetre, et le rapport le dit.
--     Un « c'est remis » qu'on n'a pas relu est exactement le genre de garde
--     qui controle le geste au lieu du resultat.
-- ---------------------------------------------------------------------------

local r = reaper

if not r.JS_Window_ArrayAllChild then
    r.MB("This probe needs js_ReaScriptAPI.\n\n"
         .. "Install it from ReaPack, restart REAPER, and run again.",
         "Arrange Band", 0)
    return
end

local MAIN = r.GetMainHwnd()
if not MAIN then return end

local HOLD_S = 20.0

-- ---------------------------------------------------------------------------
-- Rapport
-- ---------------------------------------------------------------------------
local out = {}
local function say(s) out[#out + 1] = s or "" end
local function flush()
    if #out == 0 then return end
    r.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
    for i = #out, 1, -1 do out[i] = nil end
end

local function rectOf(h)
    local ok, l, t, rt, b = r.JS_Window_GetRect(h)
    if not ok then return nil end
    return l, t, rt, b
end

local function stateOf(h)
    local l, t, rt, b = rectOf(h)
    if not l then return "gone" end
    return string.format("%s %d,%d %dx%d",
        r.JS_Window_IsVisible(h) and "vis" or "HID", l, t, rt - l, b - t)
end

-- ---------------------------------------------------------------------------
-- Inventaire et choix de la bande
-- ---------------------------------------------------------------------------
-- LA BANDE SE DEFINIT PAR SON ETENDUE HORIZONTALE, et rien d'autre. La barre
-- d'outils principale traverse toute la fenetre, les dockers ont leur propre
-- classe : une fenetre dont la largeur tient DANS celle du couple TCP +
-- arrangeur, et qui n'est pas un docker, appartient a la bande. La regle ne
-- nomme aucune classe au-dela des deux reperes, donc elle attrapera aussi ce
-- que je n'ai pas vu dans le premier inventaire.
local kids = {}

local function inventory()
    local arr = r.new_array({}, 1024)
    local n = r.JS_Window_ArrayAllChild(MAIN, arr)
    if not n or n < 1 then return end
    local addr = arr.table(1, n)
    for i = 1, n do
        local h = r.JS_Window_HandleFromAddress(addr[i])
        if h and r.JS_Window_GetParent(h) == MAIN then
            local l, t, rt, b = rectOf(h)
            if l then
                kids[#kids + 1] = { h = h, l = l, t = t, r = rt, b = b,
                                    cls = r.JS_Window_GetClassName(h) or "?",
                                    id = math.floor(r.JS_Window_GetLong(h, "ID") or 0),
                                    vis = r.JS_Window_IsVisible(h) }
            end
        end
    end
end

local function findClass(name)
    for _, c in ipairs(kids) do
        if c.vis and c.cls == name and c.r > c.l then return c end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Ce qu'on masque, et sa restauration
-- ---------------------------------------------------------------------------
local victims = {}
local arrange = nil
local hidden  = false

local function restoreAll()
    if not hidden then return end
    hidden = false
    for _, c in ipairs(victims) do r.JS_Window_Show(c.h, "SHOW") end
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
end
r.atexit(restoreAll)

-- ---------------------------------------------------------------------------
-- Depart : on dit ce qu'on va faire AVANT de le faire
-- ---------------------------------------------------------------------------
r.ShowConsoleMsg("")
say("CP Arrange Band")
say("===============")
say("")

inventory()
arrange = findClass("REAPERTrackListWindow")
local tcp = findClass("REAPERTCPDisplay")
if not arrange then
    say("No visible REAPERTrackListWindow. Nothing was touched.")
    flush()
    return
end

local bl = math.min(arrange.l, tcp and tcp.l or arrange.l)
local br = math.max(arrange.r, tcp and tcp.r or arrange.r)
say(string.format("Band: x %d..%d  (arrange%s)", bl, br,
                  tcp and " + TCP" or ", no visible TCP"))
say("")

for _, c in ipairs(kids) do
    if c.vis and c.cls ~= "#32770" and c.r > c.l
       and c.l >= bl - 8 and c.r <= br + 8 then
        victims[#victims + 1] = c
    end
end

if #victims == 0 then
    say("Nothing inside the band. Nothing was touched.")
    flush()
    return
end

say(string.format("%d window(s) about to be hidden:", #victims))
for _, c in ipairs(victims) do
    say(string.format("    id %-5d %-24s %d,%d %dx%d",
        c.id, c.cls:sub(1, 24), c.l, c.t, c.r - c.l, c.b - c.t))
end
say("")
flush()   -- IMPRIME MAINTENANT : cette liste doit exister meme si la suite rate

-- ---------------------------------------------------------------------------
-- La fenetre de controle. Volontairement sans le toolkit : une sonde qui
-- depend de la moitie du depot ne peut plus servir a diagnostiquer le depot.
-- ---------------------------------------------------------------------------
gfx.init("CP Arrange Band — hold", 460, 172, 0, 120, 120)
gfx.setfont(1, "Arial", 15)

for _, c in ipairs(victims) do r.JS_Window_Show(c.h, "HIDE") end
hidden = true
r.TrackList_AdjustWindows(false)

-- ---------------------------------------------------------------------------
-- L'ECHANTILLONNAGE, qui est la vraie mesure
-- ---------------------------------------------------------------------------
-- On releve le rectangle de l'arrangeur a chaque frame et on compte les valeurs
-- DISTINCTES. Une seule valeur au bout de vingt secondes ne veut pas dire que
-- REAPER a cesse de calculer : ca veut dire que rien ne lui a demande de
-- recalculer. C'est pour ca que l'ecran reclame un redimensionnement.
local seen, nseen = {}, 0
local first_rect, last_rect = nil, nil

local function sample()
    local s = stateOf(arrange.h)
    last_rect = s
    if not first_rect then first_rect = s end
    if not seen[s] then seen[s] = true nseen = nseen + 1 end
end

local t0 = r.time_precise()

local function finish()
    restoreAll()
    -- LA RESTAURATION SE VERIFIE. Le rapport dit ce qui est revenu, pas ce
    -- qu'on a demande.
    local back = 0
    for _, c in ipairs(victims) do
        if r.JS_Window_IsVisible(c.h) then back = back + 1 end
    end
    say("")
    say("--- result ---")
    say(string.format("arrange rect, first : %s", first_rect or "?"))
    say(string.format("arrange rect, last  : %s", last_rect or "?"))
    say(string.format("distinct rects seen : %d", nseen))
    if nseen > 1 then
        say("  -> REAPER KEPT RECOMPUTING the arrange rectangle while it was")
        say("     hidden. It can serve as the layout oracle: read it, never")
        say("     write it, and put our own window where it says.")
    else
        say("  -> only one value. This proves NOTHING on its own: nothing asked")
        say("     REAPER to relayout. Run again and drag the window's edge.")
    end
    say("")
    say(string.format("restored: %d/%d window(s) visible again", back, #victims))
    if back < #victims then
        say("  !! some did not come back — list them and restart REAPER if needed")
    end
    flush()
    gfx.quit()
end

local function draw()
    local el  = r.time_precise() - t0
    local rem = HOLD_S - el
    gfx.set(0.11, 0.12, 0.14, 1); gfx.rect(0, 0, gfx.w, gfx.h, 1)
    gfx.set(0.90, 0.90, 0.92, 1)
    gfx.x, gfx.y = 14, 12
    gfx.drawstr("Arrange band hidden — " .. #victims .. " windows")
    gfx.set(0.98, 0.76, 0.30, 1)
    gfx.x, gfx.y = 14, 40
    gfx.drawstr("NOW: drag the REAPER window's edge.")
    gfx.set(0.72, 0.74, 0.78, 1)
    gfx.x, gfx.y = 14, 62
    gfx.drawstr("That is what this measures. Also try play, tabs, a screenset.")
    gfx.x, gfx.y = 14, 90
    gfx.drawstr(string.format("rect now: %s   ·   %d distinct", last_rect or "?", nseen))
    gfx.set(0.55, 0.57, 0.62, 1)
    gfx.x, gfx.y = 14, 122
    gfx.drawstr(string.format("Click, Escape or close to restore   ·   auto in %.0f s",
                              rem > 0 and rem or 0))
    -- La barre de temps restant : un chiffre qui descend se lit moins vite
    -- qu'une longueur qui raccourcit.
    gfx.set(0.35, 0.60, 0.90, 1)
    gfx.rect(14, 146, math.floor((gfx.w - 28) * (rem > 0 and rem or 0) / HOLD_S), 6, 1)
    gfx.update()
end

-- LE CLIC NE COMPTE PAS TOUT DE SUITE. On lance ce script en double-cliquant
-- dans la liste des actions : le bouton peut etre encore enfonce quand la
-- fenetre s'ouvre et prend le focus, et le maintien s'arreterait a la premiere
-- frame — sans qu'on comprenne pourquoi, et en donnant « une seule valeur
-- distincte » comme resultat.
local CLICK_GRACE = 0.5

local function loop()
    local ch = gfx.getchar()
    if ch < 0 then finish() return end            -- fenetre fermee
    sample()
    draw()
    local el = r.time_precise() - t0
    if ch == 27 or el >= HOLD_S
       or (el > CLICK_GRACE and (gfx.mouse_cap & 1) == 1) then
        finish()
        return
    end
    r.defer(loop)
end

r.defer(loop)
