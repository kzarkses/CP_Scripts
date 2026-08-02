-- CP_Engine — KeymapUI
--
-- LE PANNEAU DE RACCOURCIS, DESSINE UNE FOIS ET OUVERT DE PARTOUT.
--
-- ---------------------------------------------------------------------------
-- UN MODULE, ET UNE FENETRE A PART
-- ---------------------------------------------------------------------------
-- Chaque script ouvre la configuration de SES raccourcis depuis ses propres
-- options — c'est la bonne porte : on regle l'outil qu'on a sous la main. Mais
-- elle s'ouvre dans une FENETRE A PART, jamais par-dessus la fenetre qui
-- l'ouvre : regler un raccourci se fait en regardant l'editeur, pas a sa
-- place, et une page qui remplace ce qu'on est en train d'editer oblige a
-- fermer pour verifier, puis a rouvrir pour corriger.
--
-- Ce fichier est donc le PANNEAU, pas la fenetre : `CP_Tools/CP_Keymap.lua`
-- l'heberge, et chaque script l'ouvre en lui disant quel module montrer. Une
-- seule mise en oeuvre — sinon les cinq divergeront, ce qui est la seule chose
-- dont on soit sur.
--
-- ---------------------------------------------------------------------------
-- LA LISTE EST DESSINEE, PAS EMPILEE
-- ---------------------------------------------------------------------------
-- La premiere version empilait des widgets du toolkit (colonnes, boutons) et
-- l'affichage sautait : des trous d'une demi-fenetre, des groupes vides, des
-- boutons fantomes. Un tableau de trente-huit lignes n'est pas un empilement de
-- controles, c'est un DESSIN — c'est ce que fait le piano roll d'a cote, et
-- c'est pour la meme raison : on veut decider de la hauteur d'une ligne, de son
-- survol, de sa zone cliquable, et ne rien devoir a la mise en page de
-- quelqu'un d'autre.
--
-- Rien n'alloue par frame ici : les colonnes sont des fractions calculees en
-- entier, les libelles sont tronques par le cache du toolkit, et la seule
-- boucle balaie les lignes visibles.
--
-- ---------------------------------------------------------------------------
-- LA REGLE, QUI N'EST PAS UN COMPROMIS
-- ---------------------------------------------------------------------------
-- Sur un GESTE DE SOURIS, seuls les MODIFICATEURS se changent : la zone et le
-- geste sont la NATURE de l'action. « Effacer une note » se fait sur une note
-- et au clic ; deplacer ca en ferait une autre action, pas la meme autrement
-- liee. REAPER ne le permet pas non plus. Sur une TOUCHE, le code ET les
-- modificateurs.

local KeymapUI = {}

local r, Core, Keymap

local ROW_H   = 22
local HEAD_H  = 26
local PAD     = 8

function KeymapUI.init(reaper_api, core, keymap)
    r, Core, Keymap = reaper_api, core, keymap
    return KeymapUI
end

-- L'etat d'un panneau. L'appelant le tient : deux fenetres peuvent en montrer
-- un chacune sans se marcher dessus.
function KeymapUI.NewState(module)
    return { module = module, filter = "", scroll = 0, capture = nil,
             hover = nil, flash = "", flash_until = 0 }
end

local function flash(S, msg)
    S.flash = msg
    S.flash_until = r.time_precise() + 3.0
end

-- ---------------------------------------------------------------------------
-- La capture
-- ---------------------------------------------------------------------------
-- L'ECHAPPATOIRE EST LA SOURIS, JAMAIS UNE TOUCHE. Toute touche doit pouvoir
-- etre assignee, Echap comprise — lui reserver l'annulation reviendrait a
-- decreter qu'elle ne servira jamais a rien d'autre.
--
-- Et la frappe est lue AVANT que l'hote ne la distribue : sinon Entree
-- validerait un champ et Echap fermerait la fenetre, au lieu d'etre capturees.
function KeymapUI.PollCapture(S)
    local cap = S.capture
    if not cap then return false end

    if Core.MouseClicked(2) then
        S.capture = nil
        flash(S, "Cancelled")
        return true
    end

    local mods = Core.Mods()

    if cap.kind == "mouse" then
        -- Armee a la frame SUIVANTE : le clic qui ouvre la capture ne doit pas
        -- etre celui qui la referme.
        if cap.armed and Core.MouseClicked(1) then
            Keymap.Set(S.module, cap.act, { ctx = cap.ctx, g = cap.g, mods = mods })
            S.capture = nil
            S.dirty = true
            flash(S, cap.act .. "  ->  " .. Keymap.Label(S.module, cap.act))
        end
        cap.armed = true
        return true
    end

    local ch = Core.GetChar()
    if ch and ch > 0 then
        Core.ConsumeChar()
        Keymap.Set(S.module, cap.act, { k = ch, mods = mods })
        S.capture = nil
        S.dirty = true
        flash(S, cap.act .. "  ->  " .. Keymap.Label(S.module, cap.act)
                 .. "   (code " .. ch .. ")")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Le modele d'affichage : la liste APLATIE, en-tetes compris
-- ---------------------------------------------------------------------------
-- Recalculee seulement quand le filtre ou la carte changent. Un tableau
-- reconstruit par frame allouerait trente-huit tables dans une boucle de
-- dessin, ce que cette suite ne fait nulle part.
local function rebuild(S)
    S.flat = S.flat or {}
    local flat = S.flat
    for i = #flat, 1, -1 do flat[i] = nil end

    local rows = Keymap.Rows(S.module)
    if not rows then S.key = "none" return end

    local f = (S.filter or ""):lower()
    local group = nil
    for i = 1, #rows do
        local row = rows[i]
        local keep = (f == "")
            or (row.label or ""):lower():find(f, 1, true) ~= nil
            or (row.act or ""):lower():find(f, 1, true) ~= nil
            or (row.group or ""):lower():find(f, 1, true) ~= nil
        if keep then
            if row.group ~= group then
                group = row.group
                flat[#flat + 1] = { head = tostring(group) }
            end
            flat[#flat + 1] = { row = row }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Le dessin
-- ---------------------------------------------------------------------------
-- x, y, w, h : le rectangle qu'on nous donne. On ne demande rien de plus a
-- l'hote — pas de layout, pas de curseur, pas de pile de conteneurs. C'est ce
-- qui permet a ce panneau de vivre dans une fenetre entiere comme dans un
-- coin d'une autre.
function KeymapUI.Draw(S, theme, x, y, w, h)
    local C = theme.colors
    local col_text  = C.text
    local col_dim   = C.text_mute or C.text_disabled
    local col_acc   = C.accent
    local col_warn  = C.danger
    local col_row   = C.list_alt_bg or C.surface
    local col_hover = C.list_selected or C.accent_dim
    local col_edge  = C.border

    local ver = (Keymap.Version and Keymap.Version(S.module)) or 0
    local key = (S.filter or "") .. "|" .. tostring(ver)
    if S.key ~= key then S.key = key rebuild(S) end
    local flat = S.flat or {}

    -- Les quatre colonnes, en pixels entiers : une fraction arrondie a chaque
    -- ligne ferait vibrer le texte d'un pixel selon la largeur.
    local x_lbl = x + PAD
    local x_bind = x + math.floor(w * 0.50)
    local x_act  = x + w - PAD - 64
    local w_lbl  = x_bind - x_lbl - PAD
    local w_bind = x_act - x_bind - PAD

    -- Defilement : la molette sur le panneau, bornee au contenu.
    local mx, my = Core.GetMousePos()
    local inside = mx >= x and mx < x + w and my >= y and my < y + h
    local total = 0
    for i = 1, #flat do total = total + (flat[i].head and HEAD_H or ROW_H) end
    local max_scroll = total - h
    if max_scroll < 0 then max_scroll = 0 end
    if inside then
        local wheel = Core.GetState().mouse_wheel
        if wheel and wheel ~= 0 then
            S.scroll = S.scroll - (wheel / 120) * ROW_H * 3
            Core.ConsumeWheel()
        end
    end
    if S.scroll > max_scroll then S.scroll = max_scroll end
    if S.scroll < 0 then S.scroll = 0 end

    local clicked = inside and Core.MouseClicked(1)
    local cy = y - S.scroll
    S.hover = nil

    for i = 1, #flat do
        local e = flat[i]
        local rh = e.head and HEAD_H or ROW_H
        -- Seules les lignes VISIBLES sont dessinees. Sur trente-huit c'est un
        -- detail ; sur la carte complete de cinq modules ce ne le sera plus, et
        -- la boucle n'aura pas a etre reecrite.
        if cy + rh > y and cy < y + h then
            if e.head then
                Core.DrawText(e.head, x_lbl, cy + 8,
                              col_dim[1], col_dim[2], col_dim[3], 1)
                Core.DrawRect(x_lbl, cy + rh - 1, w - PAD * 2, 1,
                              col_edge[1], col_edge[2], col_edge[3], 0.6)
            else
                local row = e.row
                local b = Keymap.Binding(S.module, row.act)
                local is_key = b and b.k ~= nil
                local hot = inside and my >= cy and my < cy + rh
                local capturing = S.capture and S.capture.act == row.act

                if hot then
                    S.hover = row.act
                    Core.DrawRect(x + 2, cy, w - 4, rh - 1,
                                  col_hover[1], col_hover[2], col_hover[3], 0.35)
                elseif i % 2 == 0 then
                    Core.DrawRect(x + 2, cy, w - 4, rh - 1,
                                  col_row[1], col_row[2], col_row[3], 0.35)
                end

                Core.DrawText(Core.TruncateText(row.label, w_lbl),
                              x_lbl, cy + 5,
                              col_text[1], col_text[2], col_text[3], 1)

                if capturing then
                    local msg = (S.capture.kind == "mouse")
                        and "hold the modifiers, then click"
                        or  "press any key…"
                    Core.DrawText(msg, x_bind, cy + 5,
                                  col_acc[1], col_acc[2], col_acc[3], 1)
                else
                    local lbl = Keymap.Label(S.module, row.act)
                    if is_key and b.k then lbl = lbl .. "   (" .. b.k .. ")" end
                    local cf = Keymap.Conflicts(S.module, row.act)
                    local cc = (cf and #cf > 0) and col_warn or col_text
                    if cf and #cf > 0 then lbl = lbl .. "  !" end
                    Core.DrawText(Core.TruncateText(lbl, w_bind), x_bind, cy + 5,
                                  cc[1], cc[2], cc[3], 1)
                end

                -- « Default » n'apparait que sur la ligne survolee : trente-huit
                -- boutons permanents font un mur, et celui qu'on cherche est
                -- toujours sous le pointeur.
                if hot and not capturing then
                    local on_def = mx >= x_act
                    Core.DrawText("default", x_act, cy + 5,
                                  col_dim[1], col_dim[2], col_dim[3],
                                  on_def and 1 or 0.6)
                    if clicked and on_def then
                        Keymap.Reset(S.module, row.act)
                        S.dirty = true
                        S.key = nil
                        flash(S, row.act .. "  ->  "
                                 .. Keymap.Label(S.module, row.act))
                        clicked = false
                    end
                end

                -- LA LIGNE ENTIERE OUVRE LA CAPTURE. Un bouton « Set » de
                -- quarante pixels a cote d'une ligne de sept cents est une
                -- cible qu'on rate ; la ligne, non.
                if clicked and hot then
                    S.capture = { act = row.act,
                                  kind = is_key and "key" or "mouse",
                                  ctx = b and b.ctx, g = b and b.g,
                                  armed = false }
                    clicked = false
                end
            end
        end
        cy = cy + rh
    end

    -- L'ascenseur, dessine seulement s'il y a de quoi defiler.
    if max_scroll > 0 then
        local th = math.max(24, h * (h / total))
        local ty = y + (h - th) * (S.scroll / max_scroll)
        Core.DrawRect(x + w - 4, y, 3, h,
                      col_edge[1], col_edge[2], col_edge[3], 0.4)
        Core.DrawRect(x + w - 4, ty, 3, th,
                      col_dim[1], col_dim[2], col_dim[3], 0.8)
    end
end

-- ---------------------------------------------------------------------------
-- LE PANNEAU COMPLET, en trois lignes chez l'hote
-- ---------------------------------------------------------------------------
-- L'en-tete, le filtre, la liste, la barre du bas. Un hote qui l'ouvre chez lui
-- n'ecrit pas une mise en page : il dit ou et combien de place. C'est ce qui
-- fait que CP_Session et CP_Sampler l'auront pour le meme prix — et qu'aucun
-- des trois ne pourra deriver des autres.
--
-- Rend true tant que le panneau demande a rester ouvert.
function KeymapUI.Panel(UI, S, theme, h)
    local C = theme.colors
    local dim = C.text_mute or C.text_disabled

    UI.SetFontTitle()
    UI.Text("Keyboard & mouse  —  " .. tostring(S.module))
    UI.SetFontBody()
    UI.Text("Click a row, then press the key — or, for a mouse gesture, hold "
            .. "the modifiers and click. Right-click cancels.")
    UI.SetFontCaption()
    UI.TextColored("On a mouse gesture only the MODIFIERS change: the zone and "
                   .. "the gesture are what the action IS.",
                   dim[1], dim[2], dim[3], 1)
    UI.SetFontBody()
    UI.Spacing()

    local fch, ftxt = UI.InputText("km_filter", "Filter", S.filter or "")
    if fch then S.filter = ftxt or "" end
    UI.Spacing()

    local x, y = UI.Layout.GetCursorPos()
    local w = UI.GetAvailableWidth()
    local lh = h or (UI.GetAvailableHeight() - 40)
    if lh < 120 then lh = 120 end
    KeymapUI.Draw(S, theme, x, y, w, lh)
    UI.Layout.AdvanceCursor(w, lh)
    UI.Spacing()

    local keep = true
    if UI.Button("km_save", S.dirty and "Save *" or "Save") then
        if Keymap.Save(S.module) then
            S.dirty = false
            -- Le tampon dit aux AUTRES fenetres de relire. Sans lui il faudrait
            -- les fermer une par une, ce que personne ne fait — donc les
            -- reglages ne se testeraient jamais.
            local v = (tonumber(r.GetExtState("CP_Keymap", "version")) or 0) + 1
            r.SetExtState("CP_Keymap", "version", tostring(v), false)
            flash(S, "Saved to CP_Config/CP_Keymap.lua")
        else
            flash(S, "Could not write CP_Config/CP_Keymap.lua")
        end
    end
    UI.SameLine()
    if UI.Button("km_reload", "Reload from file") then
        Keymap.Reload(S.module) S.dirty = false S.key = nil
        flash(S, "Reloaded")
    end
    UI.SameLine()
    if UI.Button("km_defaults", "All defaults") then
        Keymap.Reset(S.module) S.dirty = true S.key = nil
        flash(S, "Back to the defaults — not saved yet")
    end
    UI.SameLine()
    if UI.Button("km_close", "Close") then keep = false end

    local msg = KeymapUI.Flash(S)
    if msg then
        UI.SameLine()
        local a = C.accent
        UI.TextColored("   " .. msg, a[1], a[2], a[3], 1)
        UI.RequestRedraw()
    end
    return keep
end

-- ---------------------------------------------------------------------------
-- OUVRIR LA FENETRE DEPUIS N'IMPORTE QUEL SCRIPT
-- ---------------------------------------------------------------------------
-- `AddRemoveReaScript` enregistre le script s'il ne l'est pas et rend son
-- identifiant de commande — idempotent, donc appelable a chaque fois sans rien
-- accumuler. C'est le seul moyen honnete de lancer un autre script : le
-- charger ici en ferait une PAGE de celui-ci, ce qu'on vient precisement de
-- refuser.
--
-- Le module a montrer voyage par l'ExtState : la fenetre le lit a son
-- demarrage. Un argument de ligne de commande n'existe pas pour un ReaScript,
-- et poser un fichier pour trois caracteres serait pire.
function KeymapUI.OpenWindow(module)
    if module then
        r.SetExtState("CP_Keymap", "open_module", tostring(module), false)
    end
    local path = r.GetResourcePath()
                 .. "/Scripts/CP_Scripts/CP_Tools/CP_Keymap.lua"
    local id = r.AddRemoveReaScript(true, 0, path, true)
    if id and id ~= 0 then
        r.Main_OnCommand(id, 0)
        return true
    end
    return false
end

function KeymapUI.Flash(S)
    if r.time_precise() < (S.flash_until or 0) then return S.flash end
    return nil
end

return KeymapUI
