-- @description CP Keymap — les raccourcis et les modificateurs de la suite
-- @version 1.0
-- @author Cedric Pamalio
--
-- ---------------------------------------------------------------------------
-- LA FENETRE QUI MANQUAIT, ET CE QU'IL A FALLU FAIRE AVANT
-- ---------------------------------------------------------------------------
-- Elle ne pouvait pas exister tant que les liaisons vivaient dans le flot de
-- controle des scripts : `if char == 113 then quantize()` n'est pas une donnee,
-- c'est du code, et une fenetre ne reecrit pas du code. Deux choses ont donc du
-- se faire d'abord — `CP_Engine/Keymap.lua`, qui fait d'une liaison une table,
-- et la sortie des vocabulaires dans `CP_Engine/Keymaps/<module>.lua`, parce
-- qu'une fenetre separee est un AUTRE etat Lua : ce qu'un script enregistre
-- chez lui, elle ne le voit pas.
--
-- ---------------------------------------------------------------------------
-- LA REGLE, ET ELLE N'EST PAS UN COMPROMIS
-- ---------------------------------------------------------------------------
-- Sur un GESTE DE SOURIS, seuls les MODIFICATEURS se changent. La zone et le
-- geste sont la NATURE de l'action : « effacer une note » se fait sur une note
-- et au clic — deplacer ca en ferait une autre action, pas la meme autrement
-- liee. REAPER lui-meme ne le permet pas, et pour la meme raison.
-- Sur une TOUCHE, le code ET les modificateurs se changent.
--
-- ---------------------------------------------------------------------------
-- LA CAPTURE MONTRE CE QU'ELLE A RECU
-- ---------------------------------------------------------------------------
-- `gfx.getchar` ne rend pas ce qu'on croit : Ctrl+A arrive en 1, la ponctuation
-- se deplace selon la disposition du clavier, et sur un clavier francais « + »
-- se tape Shift+= — donc le code 43 arrive AVEC le bit Shift leve. Une fenetre
-- qui afficherait ce qu'elle DEDUIT ferait donc regler des raccourcis qui ne se
-- declencheront jamais. Celle-ci affiche le code brut a cote du nom, et c'est
-- le code qui est stocke.

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root = script_path:match("(.*[\\/]).*[\\/]") or script_path

local UI     = dofile(root .. "CP_Toolkit/CP_Toolkit.lua")
local Keymap = dofile(root .. "CP_Engine/Keymap.lua")

local r = reaper
local Core = UI.Core
Keymap.init(r, Core, UI.Keys)

-- ---------------------------------------------------------------------------
-- LES MODULES CONNUS. Une ligne par vocabulaire ; en ajouter un est une ligne
-- ici et un fichier dans CP_Engine/Keymaps, jamais une modification de cette
-- fenetre.
-- ---------------------------------------------------------------------------
local MODULES = {
    { name = "editor", label = "CP Editor", file = "CP_Engine/Keymaps/editor.lua" },
}

local S = {
    mod = 1,
    filter = "",
    capture = nil,       -- action en attente d'une nouvelle liaison
    flash = "", flash_until = 0,
    dirty = false,
}

local function flash(msg)
    S.flash = msg
    S.flash_until = r.time_precise() + 3.0
    UI.RequestRedraw()
end

for i = 1, #MODULES do
    local m = MODULES[i]
    local ok, rows = pcall(dofile, root .. m.file)
    if ok and type(rows) == "table" then
        Keymap.Register(m.name, rows)
        m.loaded = true
    else
        m.loaded = false
    end
end

local function current() return MODULES[S.mod] end

-- ---------------------------------------------------------------------------
-- La capture
-- ---------------------------------------------------------------------------
-- On lit la frappe AVANT que le toolkit ne la distribue a ses widgets : une
-- capture qui laisserait passer la touche verrait Echap fermer la fenetre et
-- Entree valider un champ, au lieu d'etre CAPTUREES comme n'importe quelle
-- autre. Tant qu'une capture est ouverte, la fenetre n'a plus de raccourcis a
-- elle — c'est la seule facon de pouvoir en assigner un a n'importe quoi.
local function pollCapture()
    local cap = S.capture
    if not cap then return end
    local m = current()

    -- L'echappatoire est la SOURIS, jamais une touche : toute touche doit
    -- pouvoir etre assignee, Echap comprise.
    if Core.MouseClicked(2) then
        S.capture = nil
        flash("Capture cancelled")
        return
    end

    local mods = Core.Mods()

    if cap.kind == "mouse" then
        -- On attend un CLIC sur la zone d'attente, modificateurs tenus. Le
        -- geste et la zone ne bougent pas — seuls les modificateurs.
        if Core.MouseClicked(1) and cap.armed then
            Keymap.Set(m.name, cap.act,
                       { ctx = cap.ctx, g = cap.g, mods = mods })
            S.capture = nil
            S.dirty = true
            flash(cap.act .. "  →  " .. Keymap.Label(m.name, cap.act))
        end
        -- Armee seulement a partir de la frame SUIVANTE : le clic qui a ouvert
        -- la capture ne doit pas etre celui qui la referme.
        cap.armed = true
        return
    end

    local ch = Core.GetChar()
    if ch and ch > 0 then
        UI.ConsumeChar()
        Keymap.Set(m.name, cap.act, { k = ch, mods = mods })
        S.capture = nil
        S.dirty = true
        flash(cap.act .. "  →  " .. Keymap.Label(m.name, cap.act)
              .. "   (code " .. ch .. ")")
    end
end

-- ---------------------------------------------------------------------------
-- Le tableau
-- ---------------------------------------------------------------------------
local function matches(row)
    if S.filter == "" then return true end
    local f = S.filter:lower()
    return (row.label or ""):lower():find(f, 1, true) ~= nil
        or (row.act or ""):lower():find(f, 1, true) ~= nil
        or (row.group or ""):lower():find(f, 1, true) ~= nil
end

local function drawRows(theme)
    local m = current()
    if not m.loaded then
        UI.Text("This module's vocabulary could not be loaded:")
        UI.Text(m.file)
        return
    end
    local rows = Keymap.Rows(m.name)
    if not rows then return end

    -- Les couleurs vivent sous `theme.colors`, et elles ont des NOMS : `text`,
    -- `text_mute`, `accent`, `danger`. Les prendre par leur nom plutot que de
    -- poser des nombres est ce qui fait qu'un changement de theme traverse
    -- cette fenetre comme les autres.
    local C    = theme.colors
    local col  = C.text
    local dim  = C.text_mute or C.text_disabled
    local acc  = C.accent
    local warn = C.danger

    local group = nil
    local shown = 0
    for i = 1, #rows do
        local row = rows[i]
        if matches(row) then
            if row.group ~= group then
                group = row.group
                UI.Spacing()
                UI.SetFontBold()
                UI.TextColored(tostring(group), dim[1], dim[2], dim[3], 1)
                UI.SetFontBody()
                UI.Separator()
            end
            shown = shown + 1

            local b = Keymap.Binding(m.name, row.act)
            local is_key = b and b.k ~= nil
            local capturing = S.capture and S.capture.act == row.act

            UI.BeginColumns("c" .. i, { 0.44, 0.28, 0.14, 0.14 })

            UI.Text(row.label)
            UI.NextColumn()

            -- La liaison, et le CODE brut quand c'est une touche : c'est lui
            -- qui est stocke, et c'est lui qui explique un raccourci qui ne
            -- part pas.
            if capturing then
                UI.SetFontBold()
                UI.TextColored(S.capture.kind == "mouse"
                               and "hold modifiers, then click here"
                               or "press a key…",
                               acc[1], acc[2], acc[3], 1)
                UI.SetFontBody()
            else
                local lbl = Keymap.Label(m.name, row.act)
                if is_key then lbl = lbl .. "   (" .. b.k .. ")" end
                local cf = Keymap.Conflicts(m.name, row.act)
                if cf and #cf > 0 then
                    UI.TextColored(lbl .. "  ⚠", warn[1], warn[2], warn[3], 1)
                    UI.Tooltip("Same slot as: " .. table.concat(cf, ", ")
                               .. "\nThe last one registered answers.")
                else
                    UI.TextColored(lbl, col[1], col[2], col[3], 1)
                end
            end
            UI.NextColumn()

            if UI.Button("set" .. i, capturing and "…" or "Set") then
                if capturing then
                    S.capture = nil
                else
                    S.capture = { act = row.act,
                                  kind = is_key and "key" or "mouse",
                                  ctx = b and b.ctx, g = b and b.g,
                                  armed = false }
                end
            end
            UI.NextColumn()

            if UI.Button("rst" .. i, "Default") then
                Keymap.Reset(m.name, row.act)
                S.dirty = true
                flash(row.act .. "  →  " .. Keymap.Label(m.name, row.act))
            end
            UI.EndColumns()
        end
    end
    if shown == 0 then
        UI.Spacing()
        UI.Text("Nothing matches “" .. S.filter .. "”.")
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------
local function frame(theme)
    -- AVANT TOUT LE RESTE : une capture ouverte mange la frappe, sinon les
    -- widgets la prennent et on ne peut plus assigner Echap ni Entree.
    pollCapture()

    UI.SetWindowPadding(theme.pad_large or 10)

    UI.SetFontTitle()
    UI.Text("Keyboard & mouse")
    UI.SetFontBody()
    UI.Text("Click Set, then press the key — or, for a mouse gesture, hold the "
            .. "modifiers and click. Right-click cancels.")
    UI.Separator()
    UI.Spacing()

    if #MODULES > 1 then
        local labels = {}
        for i = 1, #MODULES do labels[i] = MODULES[i].label end
        local ch, idx = UI.Combo("mod", "Module", S.mod, labels)
        if ch then S.mod = idx; S.capture = nil end
        UI.SameLine()
    end

    local fch, ftxt = UI.InputText("filter", "Filter", S.filter)
    if fch then S.filter = ftxt or "" end

    UI.Spacing()
    UI.Separator()

    -- SEULS LES MODIFICATEURS SE CHANGENT SUR UN GESTE. Dit ici plutot que
    -- decouvert en essayant de deplacer une action d'une zone a l'autre.
    UI.SetFontCaption()
    local d = theme.colors.text_mute or theme.colors.text_disabled
    UI.TextColored("On a mouse gesture only the MODIFIERS change — the zone and "
                   .. "the gesture are what the action IS.", d[1], d[2], d[3], 1)
    UI.SetFontBody()

    -- La liste prend toute la hauteur restante moins la barre du bas : c'est
    -- elle qui defile, pas la fenetre, sinon les boutons partiraient hors ecran
    -- des qu'on cherche une action loin dans la liste.
    local h = UI.GetAvailableHeight() - 58
    if h < 120 then h = 120 end
    UI.BeginChild("list", -1, h, { border = false })
    drawRows(theme)
    UI.EndChild()

    UI.Separator()
    UI.Spacing()

    if UI.Button("save", S.dirty and "Save *" or "Save") then
        if Keymap.Save(current().name) then
            S.dirty = false
            -- Le tampon dit aux fenetres deja ouvertes de relire. Sans lui il
            -- faudrait les fermer une par une, ce que personne ne fait.
            local v = (tonumber(r.GetExtState("CP_Keymap", "version")) or 0) + 1
            r.SetExtState("CP_Keymap", "version", tostring(v), false)
            flash("Saved to CP_Config/CP_Keymap.lua")
        else
            flash("Could not write CP_Config/CP_Keymap.lua")
        end
    end
    UI.SameLine()
    if UI.Button("reload", "Reload from file") then
        Keymap.Reload(current().name)
        S.dirty = false
        flash("Reloaded")
    end
    UI.SameLine()
    if UI.Button("resetall", "All defaults") then
        Keymap.Reset(current().name)
        S.dirty = true
        flash("Back to the defaults — not saved yet")
    end
    UI.SameLine()
    if UI.Button("export", "Write the map in full") then
        local ok, path = Keymap.Export(current().name)
        flash(ok and ("Written: " .. tostring(path)) or "Could not write")
    end

    if r.time_precise() < S.flash_until then
        UI.Spacing()
        local a = theme.colors.accent
        UI.TextColored(S.flash, a[1], a[2], a[3], 1)
        UI.RequestRedraw()
    end
end

UI.Init("CP Keymap", 760, 620, { scale = 1.0, dock = 0, persist = "CP_Keymap" })
UI.Run(frame)
UI.OnClose(function()
    -- ON N'ENREGISTRE PAS TOUT SEUL. Une carte de raccourcis est un reglage
    -- qu'on veut relire avant de le poser : un enregistrement automatique
    -- ecrirait une capture ratee sans qu'on ait eu le temps de la defaire.
end)
