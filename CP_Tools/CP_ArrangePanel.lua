-- @description Arrange Panel (CP) — put OUR window where the arrange was
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   The integration spike. Hides the arrange band, reparents a gfx window into
--   REAPER's main window, and keeps it exactly on the rectangle REAPER still
--   computes for the (invisible) arrange. Draws, reads the mouse, reads keys,
--   reports what worked, restores everything.
--
--   Requires js_ReaScriptAPI. Touches no track, item or project setting.

-- ---------------------------------------------------------------------------
-- CE QUE LES DEUX SONDES PRECEDENTES ONT ETABLI
-- ---------------------------------------------------------------------------
--   1. Masquer les cinq fenetres de la bande MARCHE, et le reste de REAPER —
--      dockers, transport, barre d'outils — continue de fonctionner.
--   2. REAPER TIENT LE RECTANGLE A JOUR MEME MASQUE. Mesure : A 843,156
--      420x652 ; on retrecit la fenetre principale, B devient 935,255 0x427 ;
--      on la remet, C revient exactement a A. Et cent quarante-trois valeurs
--      distinctes pendant que Cedric tirait ses separateurs. C'est un oracle de
--      disposition : on le LIT, on ne l'ecrit jamais.
--   3. ⚠️ MAIS LA VISIBILITE N'EST PAS ACQUISE POUR TOUJOURS. Soixante-deux
--      remises en visibilite pendant vingt secondes d'usage — toutes pendant un
--      glissement de separateur. La premiere sonde disait « la visibilite n'est
--      pas reaffirmee » : c'etait vrai de ses DEUX declencheurs, et faux du
--      geste continu. Il faut donc une boucle gardienne. Elle coute cinq
--      lectures de visibilite par frame.
--
-- ---------------------------------------------------------------------------
-- CE QUE CELLE-CI MESURE — la derniere inconnue
-- ---------------------------------------------------------------------------
-- Une fenetre `gfx` reparentee dans la fenetre principale :
--   · se dessine-t-elle encore ?
--   · recoit-elle la SOURIS, et dans ses propres coordonnees ?
--   · recoit-elle le CLAVIER ?
--   · reste-t-elle en place quand REAPER refait sa disposition ?
--   · se referme-t-elle proprement ?
--
-- Si les cinq repondent oui, l'architecture entiere tient en Lua : pas
-- d'extension, pas de sous-classement, rien a intercepter.
--
-- ⚠️ LE CLAVIER PEUT NE PAS REPONDRE, et c'est justement une des questions. On
-- ne peut donc pas compter sur Echap pour sortir : l'echeance absolue est le
-- seul filet sur lequel on a le droit de s'appuyer, et il y a une zone STOP
-- bien visible pour la souris. `atexit` reste le dernier recours.
-- ---------------------------------------------------------------------------

local r = reaper

if not r.JS_Window_SetParent then
    r.MB("This spike needs js_ReaScriptAPI.", "Arrange Panel", 0)
    return
end

local MAIN = r.GetMainHwnd()
if not MAIN then return end

local TITLE  = "CP Arrange Panel Spike"
local HOLD_S = 30.0

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

-- Voir CP_ArrangeProbe : GetRect rend de l'ECRAN, SetWindowPos sur une fille
-- attend du RELATIF AU PARENT. Les confondre deplace ce qu'on croyait remettre.
local function parentOrigin()
    local ok, l, t = r.JS_Window_GetClientRect(MAIN)
    if not ok then return 0, 0 end
    return l, t
end

-- ---------------------------------------------------------------------------
-- La bande
-- ---------------------------------------------------------------------------
local victims = {}

local function findBand()
    local kids = {}
    local arr = r.new_array({}, 1024)
    local n = r.JS_Window_ArrayAllChild(MAIN, arr)
    if not n or n < 1 then return false end
    local addr = arr.table(1, n)
    for i = 1, n do
        local h = r.JS_Window_HandleFromAddress(addr[i])
        if h and r.JS_Window_GetParent(h) == MAIN then
            local l, t, rt, b = rectOf(h)
            if l and r.JS_Window_IsVisible(h) and rt > l then
                kids[#kids + 1] = { h = h, l = l, r = rt,
                                    cls = r.JS_Window_GetClassName(h) or "?" }
            end
        end
    end
    local arrange, tcp
    for _, c in ipairs(kids) do
        if c.cls == "REAPERTrackListWindow" then arrange = c end
        if c.cls == "REAPERTCPDisplay" then tcp = c end
    end
    if not arrange then return false end
    local bl = math.min(arrange.l, tcp and tcp.l or arrange.l)
    local br = math.max(arrange.r, tcp and tcp.r or arrange.r)
    for _, c in ipairs(kids) do
        if c.cls ~= "#32770" and c.l >= bl - 8 and c.r <= br + 8 then
            victims[#victims + 1] = c
        end
    end
    return #victims > 0
end

-- LE RECTANGLE DE LA BANDE EST L'UNION DE SES FENETRES, relue a chaque frame.
-- C'est l'oracle : REAPER le maintient, masque ou non, et on ne fait que le
-- lire. Rendre nil quand rien n'est mesurable est une reponse — on ne bouge
-- alors pas notre fenetre plutot que de la poser n'importe ou.
local function bandRect()
    local l, t, rt, b
    for _, c in ipairs(victims) do
        local a1, a2, a3, a4 = rectOf(c.h)
        if a1 then
            l  = l  and math.min(l, a1)  or a1
            t  = t  and math.min(t, a2)  or a2
            rt = rt and math.max(rt, a3) or a3
            b  = b  and math.max(b, a4)  or a4
        end
    end
    if not l or rt - l < 8 or b - t < 8 then return nil end
    return l, t, rt - l, b - t
end

-- ---------------------------------------------------------------------------
-- Etat, et la remise en place — point de passage UNIQUE
-- ---------------------------------------------------------------------------
local PANEL     = nil       -- notre fenetre, une fois trouvee
local old_style = nil
local band_hidden = false
local done      = false

local function restoreAll()
    if done then return end
    done = true
    -- LE FOCUS REVIENT A REAPER, quoi qu'il arrive. Une sonde qui rend la main
    -- en gardant le clavier laisserait le transport muet, et on chercherait du
    -- cote du transport.
    if r.JS_Window_SetFocus and MAIN then pcall(r.JS_Window_SetFocus, MAIN) end
    if PANEL then
        -- On rend la fenetre au bureau AVANT de la detruire : `gfx.quit` sur une
        -- fille reparentee n'a jamais ete mis a l'epreuve ici, et c'est
        -- exactement le genre de chose qu'on ne veut pas decouvrir en fermant.
        pcall(r.JS_Window_SetParent, PANEL, nil)
        if old_style then pcall(r.JS_Window_SetStyle, PANEL, old_style) end
    end
    if band_hidden then
        band_hidden = false
        for _, c in ipairs(victims) do r.JS_Window_Show(c.h, "SHOW") end
        r.TrackList_AdjustWindows(false)
        r.UpdateArrange()
    end
end
r.atexit(restoreAll)

-- ---------------------------------------------------------------------------
-- Depart
-- ---------------------------------------------------------------------------
r.ShowConsoleMsg("")
say("CP Arrange Panel — integration spike")
say("====================================")
say("")

if not findBand() then
    say("Could not identify the arrange band. Nothing was touched.")
    flush()
    return
end
say(string.format("Band: %d window(s)", #victims))
local bl, bt, bw, bh = bandRect()
say(string.format("Band rect at start: %d,%d %dx%d", bl or 0, bt or 0, bw or 0, bh or 0))
say("")
flush()

gfx.init(TITLE, 480, 260, 0, 150, 150)
gfx.setfont(1, "Arial", 15)

PANEL = r.JS_Window_Find(TITLE, true)
if not PANEL then
    say("Could not find our own gfx window by title. Nothing was hidden.")
    flush()
    gfx.quit()
    return
end

old_style = select(2, r.JS_Window_SetStyle(PANEL, "POPUP"))
-- CHILD, et pas seulement « fille par le parent ». Sans le style, la fenetre
-- reste une popup possedee : elle garde son cadre, elle flotte au-dessus, et
-- elle n'est pas clippee par la fenetre principale.
r.JS_Window_SetStyle(PANEL, "CHILD")
local prev_parent = r.JS_Window_SetParent(PANEL, MAIN)
local reparented = prev_parent ~= nil

for _, c in ipairs(victims) do r.JS_Window_Show(c.h, "HIDE") end
band_hidden = true
r.TrackList_AdjustWindows(false)

-- ---------------------------------------------------------------------------
-- Ce qu'on observe pendant le vol
-- ---------------------------------------------------------------------------
local t0        = r.time_precise()
local frames    = 0
local reshown   = 0
local moves     = 0          -- combien de fois on a suivi l'oracle
local drew      = false      -- gfx a-t-il rendu au moins une frame
local saw_mouse = false
local saw_key   = false
local last_key  = 0
local mx, my    = -1, -1
local last_rect = ""
local applied   = ""

-- ---------------------------------------------------------------------------
-- ⚠️ LE CLAVIER N'ARRIVAIT PAS, ET C'ETAIT LE SEUL NON DU PREMIER PASSAGE
-- ---------------------------------------------------------------------------
-- Une fenetre fille ne recoit pas les touches parce qu'elle n'a pas le FOCUS :
-- la fenetre principale le garde, et `gfx.getchar` ne voit donc jamais rien.
-- Ce n'est pas une limite du reparentage, c'est une consequence de Windows, et
-- elle a deux reponses qu'on mesure ensemble plutot que d'en choisir une :
--
--   · PRENDRE LE FOCUS quand la souris entre, le RENDRE quand elle sort. C'est
--     la politique « focus suit la souris », qui est exactement ce qu'un hote a
--     panneaux veut : le panneau sous le doigt recoit les touches, et REAPER
--     les reprend des qu'on en sort. `Focus.lua` existe deja dans le depot pour
--     departager quatre fenetres sur la barre d'espace ; ici la question
--     devient plus simple, pas plus compliquee.
--   · LIRE L'ETAT GLOBAL DU CLAVIER (`JS_VKeys_GetState`), qui ne depend
--     d'aucun focus. Ca marche toujours, mais ca rend des codes de touches
--     VIRTUELLES et non des caracteres, et ca voit ce qui se passe meme quand
--     on n'est pas concerne — donc c'est un repli, pas un choix.
--
-- Rendre le focus en sortant N'EST PAS UN DETAIL : sans ca, on volerait la
-- barre d'espace a REAPER pour toute la session, et le transport cesserait de
-- repondre partout ailleurs. La sonde le fait, et le rapport dit combien de
-- fois le focus a change de main.
local took_focus   = 0
local gave_focus   = 0
local had_focus    = false
local vkeys_seen   = false

local function focusPolicy(inside)
    local f = r.JS_Window_GetFocus()
    if inside and f ~= PANEL then
        r.JS_Window_SetFocus(PANEL)
        took_focus = took_focus + 1
        had_focus = true
    elseif not inside and had_focus and f == PANEL then
        r.JS_Window_SetFocus(MAIN)
        gave_focus = gave_focus + 1
        had_focus = false
    end
end

-- On ne regarde QUE la plage imprimable et les fleches : les modificateurs et
-- les boutons de souris ne sont pas fiables ici (la doc de js le dit), et les
-- compter ferait repondre « oui » a une sonde qui n'a rien vu.
local function vkeysDown()
    local st = r.JS_VKeys_GetState(-0.2)
    if not st then return false end
    for i = 0x20, 0x5A do
        if st:byte(i + 1) ~= 0 then return true end
    end
    return false
end

local STOP_W, STOP_H = 120, 26

local function follow()
    local l, t, w, h = bandRect()
    if not w then return end
    last_rect = string.format("%d,%d %dx%d", l, t, w, h)
    if last_rect == applied then return end
    applied = last_rect
    local ox, oy = parentOrigin()
    r.JS_Window_SetPosition(PANEL, l - ox, t - oy, w, h)
    moves = moves + 1
end

local function keeper()
    for _, c in ipairs(victims) do
        if r.JS_Window_IsVisible(c.h) then
            reshown = reshown + 1
            r.JS_Window_Show(c.h, "HIDE")
        end
    end
end

local function draw()
    local el  = r.time_precise() - t0
    local rem = HOLD_S - el
    drew = true
    gfx.set(0.10, 0.11, 0.13, 1); gfx.rect(0, 0, gfx.w, gfx.h, 1)
    -- Une mire, pas un aplat : un aplat uni ne dit pas si la fenetre est a la
    -- bonne taille ni si elle est clippee. Le cadre et la diagonale, si.
    gfx.set(0.30, 0.55, 0.85, 1)
    gfx.rect(0, 0, gfx.w, 2, 1); gfx.rect(0, gfx.h - 2, gfx.w, 2, 1)
    gfx.rect(0, 0, 2, gfx.h, 1); gfx.rect(gfx.w - 2, 0, 2, gfx.h, 1)
    gfx.line(0, 0, gfx.w, gfx.h); gfx.line(gfx.w, 0, 0, gfx.h)

    gfx.set(0.16, 0.17, 0.20, 1)
    gfx.rect(8, 8, 460, 150, 1)
    gfx.set(0.92, 0.92, 0.94, 1)
    gfx.x, gfx.y = 18, 16
    gfx.drawstr("OUR WINDOW, where the arrange used to be")
    gfx.set(0.72, 0.74, 0.78, 1)
    gfx.x, gfx.y = 18, 40
    gfx.drawstr(string.format("size %dx%d   ·   band %s", gfx.w, gfx.h, last_rect))
    gfx.x, gfx.y = 18, 60
    gfx.drawstr(string.format("followed %d times   ·   re-hidden %d   ·   %d frames",
                              moves, reshown, frames))
    gfx.x, gfx.y = 18, 80
    gfx.drawstr(string.format("mouse %s (%d,%d)   ·   getchar %s (%d)   ·   vkeys %s",
        saw_mouse and "YES" or "no", mx, my,
        saw_key and "YES" or "no", last_key, vkeys_seen and "YES" or "no"))
    gfx.set(0.98, 0.76, 0.30, 1)
    gfx.x, gfx.y = 18, 106
    gfx.drawstr("TYPE while the pointer is HERE, then type over REAPER.")
    gfx.set(0.55, 0.57, 0.62, 1)
    gfx.x, gfx.y = 18, 128
    gfx.drawstr(string.format("auto-stop in %.0f s", rem > 0 and rem or 0))

    -- La zone STOP, en grand et en rouge, parce que le clavier fait partie de
    -- ce qu'on teste et qu'on n'a donc pas le droit d'en dependre pour sortir.
    gfx.set(0.70, 0.22, 0.22, 1)
    gfx.rect(gfx.w - STOP_W - 8, gfx.h - STOP_H - 8, STOP_W, STOP_H, 1)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = gfx.w - STOP_W + 26, gfx.h - STOP_H - 2
    gfx.drawstr("STOP")
    gfx.update()
end

local function finish()
    restoreAll()
    local back = 0
    for _, c in ipairs(victims) do
        if r.JS_Window_IsVisible(c.h) then back = back + 1 end
    end
    say("--- result ---")
    say(string.format("reparented into the main window : %s",
                      reparented and "YES" or "NO"))
    say(string.format("gfx kept drawing as a child     : %s",
                      drew and "YES" or "NO"))
    say(string.format("mouse reached us                : %s",
                      saw_mouse and "YES" or "no (move the pointer over it)"))
    say(string.format("keyboard via gfx.getchar        : %s",
                      saw_key and "YES" or "no"))
    say(string.format("  focus taken / given back      : %d / %d",
                      took_focus, gave_focus))
    say(string.format("keyboard via JS_VKeys_GetState  : %s",
                      vkeys_seen and "YES" or "no"))
    if not saw_key and vkeys_seen then
        say("  -> focus alone is not enough; the global key state is the way in.")
    elseif saw_key then
        say("  -> focus-follows-mouse works: the pane under the pointer gets the")
        say("     keys, and REAPER takes them back when the pointer leaves.")
    end
    say(string.format("followed the oracle             : %d time(s)", moves))
    say(string.format("band windows re-hidden          : %d", reshown))
    say(string.format("frames                          : %d", frames))
    say("")
    say(string.format("restored: %d/%d band window(s) visible again",
                      back, #victims))
    if reparented and drew and saw_mouse then
        say("")
        say("  -> the architecture holds in pure Lua: hide the band, read the")
        say("     rectangle REAPER still maintains, and live in it.")
    end
    flush()
    gfx.quit()
end

local CLICK_GRACE = 0.6

local function loop()
    local ch = gfx.getchar()
    if ch < 0 then finish() return end
    frames = frames + 1
    if ch > 0 and ch ~= 27 then saw_key = true last_key = ch end
    keeper()
    follow()
    mx, my = gfx.mouse_x, gfx.mouse_y
    local inside = mx >= 0 and my >= 0 and mx < gfx.w and my < gfx.h
    if inside then saw_mouse = true end
    focusPolicy(inside)
    if vkeysDown() then vkeys_seen = true end
    draw()
    local el = r.time_precise() - t0
    local on_stop = mx >= gfx.w - STOP_W - 8 and my >= gfx.h - STOP_H - 8
    if ch == 27 or el >= HOLD_S
       or (el > CLICK_GRACE and on_stop and (gfx.mouse_cap & 1) == 1) then
        finish()
        return
    end
    r.defer(loop)
end

r.defer(loop)
