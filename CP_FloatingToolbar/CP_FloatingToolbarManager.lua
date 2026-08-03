-- @description CP Floating Toolbar Manager — configure floating toolbars
-- @version 0.2
-- @author Cedric Pamalio

local r = reaper

local script_path  = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local toolkit_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua"

local UI          = dofile(toolkit_path)
local Persistence = dofile(script_path .. "Modules/Persistence.lua")
local Actions     = dofile(script_path .. "Modules/Actions.lua")
local IconPicker  = dofile(script_path .. "Modules/IconPicker.lua")

Persistence.Init(UI)
IconPicker.Init(UI)

local picker_state = IconPicker.NewState()

local data = Persistence.Load()
if #data.toolbars == 0 then
    table.insert(data.toolbars, Persistence.NewToolbar("Default"))
    data.active_toolbar_id = data.toolbars[1].id
    Persistence.Save(data)
end

UI.Init("CP Floating Toolbar Manager", 760, 520, {
    persist = "CP_FloatingToolbarManager",
})

-- ---------------------------------------------------------------------------
-- UI state
-- ---------------------------------------------------------------------------
local search_text   = ""
local search_results = {}
local search_dirty   = true

-- (the list of toolkit glyphs lives in IconPicker now — it is the thing that
-- shows them, so it is the thing that should own the list)

local target_options = { "main", "mixer", "transport", "media_explorer", "arrange", "ruler" }
local direction_options = { "horizontal", "vertical" }
local snap_options = { "left", "right", "free" }
local style_options = { "panel", "chips", "none" }
local STYLE_HINT = {
    panel = "one rounded slab behind everything — a toolbar",
    chips = "one rounded chip per icon — detached buttons",
    none  = "nothing but the glyphs",
}

local function active_toolbar()
    return Persistence.GetActiveToolbar(data)
end

local function index_of(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return 1
end

local function dirty()
    Persistence.RequestSave()
end

local notice, notice_until = nil, 0
local function flash(msg)
    notice = msg
    notice_until = r.time_precise() + 8
end

-- ---------------------------------------------------------------------------
-- Le lanceur d'une barre
-- ---------------------------------------------------------------------------
-- Une barre affichee = une ACTION de REAPER, et un fichier de script ne porte
-- qu'une action. Afficher deux barres demande donc deux fichiers — mais pas
-- deux copies du programme : le lanceur DIT quelle barre afficher, puis charge
-- le seul et unique CP_FloatingToolbar.lua. Trois lignes qui ne peuvent pas
-- diverger de ce qu'elles lancent.
--
-- Il est enregistre comme action dans la foulee. Sans ca le bouton n'aurait
-- servi qu'a ecrire un fichier, et il aurait fallu aller le chercher a la main
-- dans la liste des actions — c'est-a-dire le vrai travail, laisse a faire.
local INSTANCE_DIR = script_path .. "Instances"

local function make_launcher(tb)
    r.RecursiveCreateDirectory(INSTANCE_DIR, 0)
    -- Le NOM de fichier est ce que la liste des actions de REAPER affiche
    -- (« Script: CP_Toolbar_Views.lua »), donc il prend le nom de la barre et
    -- pas son id. L'id, lui, est dans le fichier : renommer la barre plus tard
    -- ne casse rien, ca laisse juste un lanceur au nom d'avant.
    local safe = (tb.name or "Toolbar"):gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if safe == "" then safe = "Toolbar" end
    local path = INSTANCE_DIR .. "/CP_Toolbar_" .. safe .. ".lua"
    local f = io.open(path, "wb")
    if not f then return nil, nil end
    f:write(
        "-- @description CP Floating Toolbar — " .. (tb.name or "?") .. "\n" ..
        "-- @author Cedric Pamalio\n" ..
        "--\n" ..
        "-- GENERE par CP_FloatingToolbarManager, bouton « Launcher action ».\n" ..
        "-- Ce fichier ne contient aucun programme : il nomme la barre a afficher\n" ..
        "-- puis charge CP_FloatingToolbar.lua. Une barre = une action = un\n" ..
        "-- raccourci, et un titre de fenetre unique — ce dernier point n'est pas\n" ..
        "-- cosmetique : le toolkit retrouve sa fenetre PAR SON TITRE.\n" ..
        "\n" ..
        "CP_TOOLBAR_ID = " .. string.format("%q", tb.id) .. "\n" ..
        "dofile(reaper.GetResourcePath() ..\n" ..
        "       \"/Scripts/CP_Scripts/CP_FloatingToolbar/CP_FloatingToolbar.lua\")\n"
    )
    f:close()
    local cmd = r.AddRemoveReaScript(true, 0, path, true)
    return path, (cmd and cmd ~= 0) and cmd or nil
end

local function refresh_search()
    search_results = Actions.Search(search_text, 200)
    search_dirty = false
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------
local function draw_toolbar_list_section()
    UI.SetFontH2()
    UI.Text("Toolbars")
    UI.SetFontBody()
    UI.Spacing(4)

    local items = {}
    for _, tb in ipairs(data.toolbars) do
        items[#items + 1] = { label = (tb.enabled and "[ON]  " or "[off] ") .. tb.name }
    end

    local actions_col = {
        { icon = "X", tooltip = "Delete" },
    }

    local selected_idx = 1
    for i, tb in ipairs(data.toolbars) do
        if tb.id == data.active_toolbar_id then selected_idx = i; break end
    end

    local clicked, action_idx = UI.ActionList("toolbar_list", items, actions_col, {
        selected = selected_idx,
        max_visible = 6,
    })

    if clicked then
        data.active_toolbar_id = data.toolbars[clicked].id
        dirty()
    end

    if action_idx == 1 and clicked then
        if #data.toolbars > 1 then
            table.remove(data.toolbars, clicked)
            data.active_toolbar_id = data.toolbars[1].id
            dirty()
        end
    end

    -- "+ New" and the enabled toggle moved into the command bar at the top,
    -- where they belong: they act on the window's whole state, not on the list
    -- they were sitting under.

    -- Le lanceur, en revanche, agit sur LA BARRE SELECTIONNEE et nulle part
    -- ailleurs : sa place est sous la liste qui la designe.
    local sel = data.toolbars[selected_idx]
    if sel then
        UI.Spacing(4)
        if UI.Button("tb_launcher", "Launcher action for \"" .. (sel.name or "?") .. "\"",
                     { width = 260 }) then
            Persistence.FlushSave(data)   -- l'id doit exister sur DISQUE avant qu'on l'y pointe
            local path, cmd = make_launcher(sel)
            if not path then
                flash("Could not write the launcher file. Is the Scripts folder read-only?")
            elseif cmd then
                flash("Registered: Script: " .. path:match("[^/\\]+$") ..
                      "  —  bind it in Actions, or drop it on a toolbar.")
            else
                flash("Written: " .. path ..
                      "  —  add it yourself in the Actions list (REAPER refused to register it).")
            end
        end
        UI.SetFontCaption()
        UI.Text("One action per toolbar — that is what lets two of them run at once.",
                { disabled = true })
        UI.SetFontBody()
    end
end

local function draw_anchor_section(tb)
    UI.SetFontH2(); UI.Text("Anchor"); UI.SetFontBody()
    UI.Spacing(4)

    local changed_name, new_name = UI.InputText("tb_name", "Name", tb.name, { width = 240 })
    if changed_name then tb.name = new_name; dirty() end

    local cur_target = index_of(target_options, tb.anchor.target or "main")
    local target_changed, new_target_idx = UI.Combo("tb_target", "Target window", cur_target, target_options, { width = 240 })
    if target_changed then tb.anchor.target = target_options[new_target_idx]; dirty() end

    -- Snap mode: simplifies positioning. left/right snap to the target's
    -- corresponding edge (offset_x is then a positive inward distance);
    -- free uses the proportional anchor.x.
    local cur_snap = index_of(snap_options, tb.anchor.snap or "left")
    local snap_changed, new_snap_idx = UI.Combo("tb_snap", "Snap to edge", cur_snap, snap_options, { width = 240 })
    if snap_changed then tb.anchor.snap = snap_options[new_snap_idx]; dirty() end

    -- Anchor X is only meaningful in "free" mode
    if (tb.anchor.snap or "left") == "free" then
        local cx, nx = UI.SliderDouble("tb_anchor_x", "Anchor X (0-1)", tb.anchor.x or 0, 0, 1)
        if cx then tb.anchor.x = nx; dirty() end
    end
    local cy, ny = UI.SliderDouble("tb_anchor_y", "Anchor Y (0-1)", tb.anchor.y or 0, 0, 1)
    if cy then tb.anchor.y = ny; dirty() end

    local cox, nox = UI.NumberInput("tb_offset_x", "Offset X (px)", tb.anchor.offset_x or 0, -4000, 4000, { step = 1, format = "%d" })
    if cox then tb.anchor.offset_x = nox; dirty() end
    local coy, noy = UI.NumberInput("tb_offset_y", "Offset Y (px)", tb.anchor.offset_y or 0, -4000, 4000, { step = 1, format = "%d" })
    if coy then tb.anchor.offset_y = noy; dirty() end

    local hide_changed, hide_on = UI.Checkbox("tb_hide", "Hide when target window is hidden",
        tb.anchor.hide_when_target_hidden ~= false)
    if hide_changed then tb.anchor.hide_when_target_hidden = hide_on; dirty() end

    -- Auto-hide thresholds (mirrors CP_CustomToolbars). 0 = disabled.
    local cmw, nmw = UI.NumberInput("tb_min_w", "Auto-hide if target W <",
        tb.anchor.auto_hide_min_width or 0, 0, 8000, { step = 50, format = "%d px" })
    if cmw then tb.anchor.auto_hide_min_width = nmw; dirty() end
    local cmh, nmh = UI.NumberInput("tb_min_h", "Auto-hide if target H <",
        tb.anchor.auto_hide_min_height or 0, 0, 8000, { step = 50, format = "%d px" })
    if cmh then tb.anchor.auto_hide_min_height = nmh; dirty() end
end

local function draw_layout_section(tb)
    UI.SetFontH2(); UI.Text("Layout"); UI.SetFontBody()
    UI.Spacing(4)

    local cur_dir = index_of(direction_options, tb.layout.direction or "horizontal")
    local dir_changed, new_dir = UI.Combo("tb_dir", "Direction", cur_dir, direction_options, { width = 200 })
    if dir_changed then tb.layout.direction = direction_options[new_dir]; dirty() end

    -- Tie the icon size to the toolkit's control height, so the strip grows
    -- and shrinks with every other CP window when the size is changed in the
    -- Theme Tweaker. A toolbar that stays 30 px while the rest moves to 28
    -- stops belonging to the same product.
    local follow = (tb.layout.icon_size_mode == "theme")
    local cf, nf = UI.Checkbox("tb_icon_follow", "Icon size follows the theme", follow)
    if cf then
        tb.layout.icon_size_mode = nf and "theme" or "custom"
        dirty()
    end
    if follow then
        local th = UI.GetTheme()
        UI.SetFontCaption()
        UI.Text("currently " .. (th and th.button_height or 24) .. " px (theme control height)",
                { disabled = true })
        UI.SetFontBody()
    else
        local cs, ns = UI.SliderInt("tb_icon_size", "Icon size", tb.layout.icon_size or 24, 12, 64)
        if cs then tb.layout.icon_size = ns; dirty() end
    end

    -- Les glyphes du toolkit se posent a cote de PNG de REAPER, pas sur un
    -- fond de fenetre : c'est le voisinage qui decide de leur couleur, pas le
    -- theme. Coche par defaut ; decoche pour la couleur de texte de la suite.
    local cp_ink = (tb.layout.builtin_ink or "reaper") == "reaper"
    local ci, ni = UI.Checkbox("tb_builtin_ink", "CP icons use REAPER's icon grey", cp_ink)
    if ci then
        tb.layout.builtin_ink = ni and "reaper" or "theme"
        dirty()
    end

    local cg, ng = UI.SliderInt("tb_spacing", "Spacing", tb.layout.spacing or 4, 0, 32)
    if cg then tb.layout.spacing = ng; dirty() end

    local cp, np = UI.SliderInt("tb_padding", "Padding", tb.layout.padding or 0, 0, 32)
    if cp then tb.layout.padding = np; dirty() end

    -- What sits UNDER the icons. This is the setting that decides whether the
    -- strip reads as a toolbar, as a row of detached buttons, or as icons
    -- floating over the arrange.
    local cur_style = index_of(style_options, tb.layout.style or "panel")
    local st_changed, st_idx = UI.Combo("tb_style", "Ground", cur_style,
                                        style_options, { width = 200 })
    if st_changed then tb.layout.style = style_options[st_idx]; dirty() end
    UI.SetFontCaption()
    UI.Text(STYLE_HINT[tb.layout.style or "panel"], { disabled = true })
    UI.SetFontBody()

    -- Keying makes the unpainted pixels of the window transparent AND
    -- click-through. It is what "chips" and "none" need to exist at all, and
    -- it is why the window's size stops mattering.
    local ct, nt = UI.Checkbox("tb_transp", "Transparent background (experimental)",
        tb.layout.transparent == true)
    if ct then tb.layout.transparent = nt; dirty() end

    local style = tb.layout.style or "panel"

    if style == "panel" then
        local color = tb.layout.bg_color or { 0.12, 0.12, 0.14 }
        local cc, nc = UI.ColorPicker("tb_bg_color", "Panel color", color)
        if cc then tb.layout.bg_color = { nc[1], nc[2], nc[3] }; dirty() end
        -- Pipette, like the Theme Tweaker has next to every colour. It is the
        -- only practical way to make the strip match a REAPER theme: sample
        -- the pixel instead of guessing three numbers.
        UI.SameLine()
        if UI.Button("tb_bg_pick", "Pick") then
            UI.StartEyedropper(function(picked)
                tb.layout.bg_color = { picked[1], picked[2], picked[3] }
                dirty()
            end)
        end

        local cr, nr = UI.SliderInt("tb_bg_radius", "Panel corner",
            tb.layout.bg_radius or 0, 0, 24)
        if cr then tb.layout.bg_radius = nr; dirty() end

        local cb, nb = UI.Checkbox("tb_bg_border", "Panel border",
            tb.layout.bg_border == true)
        if cb then tb.layout.bg_border = nb; dirty() end
    end

    if style == "chips" then
        local ccol = tb.layout.chip_color or UI.GetTheme().colors.button
        local ccc, ncc = UI.ColorPicker("tb_chip_color", "Chip color", ccol)
        if ccc then tb.layout.chip_color = { ncc[1], ncc[2], ncc[3] }; dirty() end
        UI.SameLine()
        if UI.Button("tb_chip_pick", "Pick") then
            UI.StartEyedropper(function(picked)
                tb.layout.chip_color = { picked[1], picked[2], picked[3] }
                dirty()
            end)
        end

        local ccr, ncr = UI.SliderInt("tb_chip_radius", "Chip corner",
            tb.layout.chip_radius or 4, 0, 16)
        if ccr then tb.layout.chip_radius = ncr; dirty() end

        local ccb, ncb = UI.Checkbox("tb_chip_border", "Chip border",
            tb.layout.chip_border == true)
        if ccb then tb.layout.chip_border = ncb; dirty() end
    end

    -- Only meaningful without the key: with it, "see-through" is the gaps
    -- being genuinely absent rather than the whole strip being faded.
    if not tb.layout.transparent then
        local co, no = UI.SliderDouble("tb_opacity", "Opacity (whole strip)",
            tb.layout.opacity or 1, 0.2, 1)
        if co then tb.layout.opacity = no; dirty() end
    end
end

-- A row's icon, whatever its source, as something we can actually show.
-- Cached on the action like the toolbar does, so a row costs one table lookup
-- per frame and not a file probe.
local function preview_image(act)
    if act._prev_img == false then return nil end
    if act._prev_img then return act._prev_img end
    local path
    if act.icon and act.icon ~= "" and r.file_exists(act.icon) then
        path = act.icon
    elseif act.native_icon and act.native_icon ~= "" then
        local p = r.GetResourcePath() .. "/Data/toolbar_icons/" .. act.native_icon
        if r.file_exists(p) then path = p end
    end
    if path then
        local img = UI.LoadImage(path)
        act._prev_img = img or false
        return img
    end
    act._prev_img = false
    return nil
end

-- REAPER packs 2 or 3 button states side by side in one PNG. Show the first.
local function first_state(img)
    local ratio = (img.h > 0) and (img.w / img.h) or 1
    if ratio > 2.5 and ratio < 3.5 then
        return 0, 0, math.floor(img.w / 3), img.h
    elseif ratio > 1.6 and ratio < 2.4 then
        return 0, 0, math.floor(img.w / 2), img.h
    end
    return 0, 0, img.w, img.h
end

-- A square button at an ABSOLUTE position, because the row is a grid and the
-- layout cursor does not run it. Four states, like everything else.
local function icon_btn(id, icon, x, y, size, rad, disabled, tip)
    local theme = UI.GetTheme()
    local c = theme.colors
    local hovered = (not disabled)
        and UI.Core.MouseInClippedRect(x, y, size, size) and not UI.Core.HasPopup()
    local down = hovered and UI.Core.MouseDown(1)
    local bg
    if disabled then bg = c.button
    elseif down then bg = c.button_active
    elseif hovered then bg = c.button_hovered
    else bg = c.button end
    UI.Core.DrawRoundRectFilled(x, y, size, size, rad,
                                bg[1], bg[2], bg[3], disabled and 0.4 or 1)
    local ink = disabled and c.text_disabled or c.text
    local draw = UI.Icons[icon]
    if draw then
        local pad = 3
        draw(x + pad, y + pad, size - pad * 2, ink[1], ink[2], ink[3], 1)
    end
    if hovered then
        UI.Core.SetHot(id)
        if tip then UI.Tooltip(tip) end
        return UI.Core.MouseClicked(1)
    end
    return false
end

-- One door to the icon, not three. The old row offered a combo of toolkit
-- glyphs, a "PNG…" button and a "Native…" button side by side and never said
-- which of the three was actually in effect.
local function open_icon_picker(act)
    IconPicker.Open(picker_state, {
        target  = act,
        search  = "",
        on_pick = function(fname)
            act.native_icon = fname
            act.builtin_icon = nil
            act.icon = nil
            act._cached_image, act._prev_img = nil, nil
            dirty()
        end,
        on_pick_cp = function(name)
            act.builtin_icon = name
            act.native_icon = nil
            act.icon = nil
            act._cached_image, act._prev_img = nil, nil
            dirty()
        end,
        on_clear = function()
            act.native_icon, act.builtin_icon, act.icon = nil, nil, nil
            act._cached_image, act._prev_img = nil, nil
            dirty()
        end,
    })
end

-- Per-row widget ids, memoised. Built with a concat ONCE per index and then
-- reused forever, instead of "up_" .. i on every frame of every row.
local row_ids = {}
local function row_id(kind, i)
    local t = row_ids[kind]
    if not t then t = {}; row_ids[kind] = t end
    local v = t[i]
    if not v then v = kind .. "_" .. i; t[i] = v end
    return v
end

-- Row numbers, same reason.
local row_num = {}
local function num_label(i)
    local v = row_num[i]
    if not v then v = i .. "."; row_num[i] = v end
    return v
end

-- FIXED COLUMNS. This is the whole point of the rewrite: every row used to be
-- laid out from the width of its own name, so no two rows had their buttons in
-- the same place and the list read as debris. Now the row is a grid — the
-- number, the icon, the name, then three square buttons hard against the right
-- edge — and everything lines up down the column whatever the names are.
local ROW_H     = 24
local COL_NUM_W = 24     -- "12."
-- L'encre des icones de REAPER, mesuree sur leurs PNG — la meme valeur que
-- REAPER_INK dans CP_FloatingToolbar.lua. Dupliquee plutot que partagee : les
-- deux scripts ne se chargent pas l'un l'autre, et un module tiers pour deux
-- nombres couterait plus cher a lire qu'a ecrire deux fois.
local PREVIEW_INK = { 0.506, 0.537, 0.537 }
local COL_ICO_W = 24     -- what this button will actually look like
local BTN_W     = 22     -- up / down / remove
local BTN_N     = 3

local function draw_actions_section(tb)
    UI.SetFontH2(); UI.Text("Actions in this toolbar"); UI.SetFontBody()
    UI.Spacing(4)

    if #tb.actions == 0 then
        UI.TextColored("(none yet — add one from the list below)", 0.6, 0.6, 0.6, 1)
        return
    end

    local theme = UI.GetTheme()
    local tc    = theme.colors.text
    local tm    = theme.colors.text_mute or theme.colors.text_disabled
    local rad   = theme.rounding_small or 0
    local remove_at = nil

    for i, act in ipairs(tb.actions) do
        local x, y = UI.GetCursorPos()
        local w = UI.GetAvailableWidth()
        local row_hovered = UI.Core.MouseInClippedRect(x, y, w, ROW_H)
                            and not UI.Core.HasPopup()
        if row_hovered then
            local hc = theme.colors.list_hover
            UI.Core.DrawRect(x, y, w, ROW_H, hc[1], hc[2], hc[3], hc[4] or 1)
        end

        -- 1. the rank
        local nl = num_label(i)
        local nw, nh = UI.Core.MeasureText(nl)
        UI.Core.DrawText(nl, x + COL_NUM_W - nw - 6, y + math.floor((ROW_H - nh) / 2),
                         tm[1], tm[2], tm[3], 1)

        -- 2. a PREVIEW of the icon. The list said "Native: AI_Function_F.."
        -- and you still had to imagine it; showing the glyph answers the only
        -- question the row is really asking.
        local ix = x + COL_NUM_W
        local isz = ROW_H - 6
        local iy = y + 3
        if act.builtin_icon and UI.Icons[act.builtin_icon] then
            -- Meme encre que la barre : la vignette repond a « de quoi ca aura
            -- l'air », donc elle ment si elle prend la couleur de texte de la
            -- liste pendant que la barre prend le gris de REAPER.
            local pk = ((tb and tb.layout.builtin_ink) or "reaper") == "reaper"
                       and PREVIEW_INK or tc
            UI.Icons[act.builtin_icon](ix, iy, isz, pk[1], pk[2], pk[3], 1)
        else
            local img = preview_image(act)
            if img then
                local sx, sy, sw, sh = first_state(img)
                gfx.set(1, 1, 1, 1)
                gfx.blit(img.buffer, 1, 0, sx, sy, sw, sh, ix, iy, isz, isz)
            else
                UI.Core.DrawRect(ix, iy, isz, isz, tm[1], tm[2], tm[3], 0.18)
            end
        end

        -- 3. the name, truncated to whatever is left before the buttons
        local btn_zone = BTN_N * (BTN_W + 2) + 4
        local name_x = x + COL_NUM_W + COL_ICO_W + 4
        local name_w = w - (name_x - x) - btn_zone
        if name_w > 20 then
            local name = Actions.GetName(act.command_id)
            local nmw, nmh = UI.Core.MeasureText(name)
            if nmw > name_w then name = UI.Core.TruncateText(name, name_w) end
            UI.Core.DrawText(name, name_x, y + math.floor((ROW_H - nmh) / 2),
                             tc[1], tc[2], tc[3], 1)
        end

        -- 4. the three buttons, right-aligned, always in the same column
        local bx = x + w - btn_zone + 4
        if icon_btn(row_id("up", i), "TriangleUp", bx, y + 1, BTN_W, rad,
                    i == 1, "Move up") and i > 1 then
            tb.actions[i - 1], tb.actions[i] = tb.actions[i], tb.actions[i - 1]
            dirty()
        end
        if icon_btn(row_id("dn", i), "TriangleDown", bx + BTN_W + 2, y + 1, BTN_W, rad,
                    i == #tb.actions, "Move down") and i < #tb.actions then
            tb.actions[i + 1], tb.actions[i] = tb.actions[i], tb.actions[i + 1]
            dirty()
        end
        if icon_btn(row_id("rm", i), "Close", bx + (BTN_W + 2) * 2, y + 1, BTN_W, rad,
                    false, "Remove") then
            remove_at = i
        end

        -- Clicking the row (outside the buttons) opens the icon picker. ONE
        -- door instead of three controls fighting for the same job — the old
        -- row offered a combo, a PNG button and a Native button side by side
        -- and never said which one was actually in effect.
        local mx = UI.Core.GetMousePos()
        if row_hovered and UI.Core.MouseClicked(1) and mx < bx then
            open_icon_picker(act)
        end

        UI.Layout.AdvanceCursor(w, ROW_H)
    end

    if remove_at then
        table.remove(tb.actions, remove_at)
        dirty()
    end

    UI.Spacing(4)
    UI.TextColored("click a row to change its icon", 0.55, 0.55, 0.55, 1)
end

local function draw_action_picker(tb)
    UI.SetFontH2(); UI.Text("Add an action"); UI.SetFontBody()
    UI.Spacing(4)

    local changed, new_text = UI.InputText("search", "Search", search_text, {
        hint = "Type to filter REAPER actions",
        width = -1,
    })
    if changed then
        search_text = new_text
        search_dirty = true
    end

    if search_dirty then refresh_search() end

    local items = {}
    for i = 1, math.min(#search_results, 200) do
        items[i] = { label = search_results[i].name }
    end

    local clicked = UI.ActionList("search_results", items, { { icon = "+", tooltip = "Add" } }, {
        max_visible = 12,
    })

    if clicked and search_results[clicked] then
        local a = search_results[clicked]
        table.insert(tb.actions, Persistence.NewAction(a.id))
        dirty()
    end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local TITLE_OPTS  = { title = "Floating Toolbar" }
local PICKER_OPTS = { cell = 32, gap = 4, height = 380, columns = 16 }
local HELP_TEXT = [[
## What this is
A strip of REAPER actions that floats over a REAPER window and follows
it. Run CP_FloatingToolbar.lua to show the active one; edits made here
reach it within about a second, without restarting anything.

## Moving it
Ctrl+drag anywhere on the strip. The position is saved as an offset
from the window it is anchored to, so it stays put when that window
moves or resizes.

## Icons
Click a row to pick its icon. Two sources: REAPER's own toolbar icons
(the big set, the ones you already know) and the CP pack — drawn
rather than loaded, so those follow the theme's colour.

## Transparency
"Background alpha" is the WINDOW's opacity, icons included. A gfx
window has no per-pixel transparency, so a panel painted at 30 % over
an opaque window fades nothing — this is the real thing.
]]

UI.Run(function()
    -- Same chrome as every other CP window: a command bar with a ground and a
    -- seam, and a status line anchored to the bottom edge.
    UI.BeginBar("cmd", TITLE_OPTS)
    UI.BarRight()
    if UI.BarIcon("help", "Help", "Help") then UI.ShowHelp("help", HELP_TEXT) end
    UI.BarSep()
    UI.BarLeft()
    if UI.BarIcon("add_toolbar", "Plus", "New toolbar") then
        local nt = Persistence.NewToolbar("Toolbar " .. (#data.toolbars + 1))
        table.insert(data.toolbars, nt)
        data.active_toolbar_id = nt.id
        dirty()
    end
    local atb = active_toolbar()
    if atb then
        local hit = UI.BarToggle("tb_enabled", "Eye", "EyeOff", atb.enabled,
                                 atb.enabled and "Enabled" or "Disabled")
        if hit then atb.enabled = not atb.enabled; dirty() end
    end
    UI.EndBar()

    local STATUS_H = 20
    local body_h = UI.GetAvailableHeight() - STATUS_H

    -- Icon picker takes over the whole content area when open. This avoids
    -- cramming a 600-thumbnail grid into a column.
    if picker_state.open then
        IconPicker.Draw(picker_state, PICKER_OPTS)
    else
        UI.BeginChild("body", -1, body_h, { border = false, padding = 0 })
        UI.BeginColumns("main_cols", { 0.42, 0.58 })

        -- LEFT: toolbar list + anchor + layout
        draw_toolbar_list_section()
        UI.Separator()

        local tb = active_toolbar()
        if tb then
            draw_anchor_section(tb)
            UI.Separator()
            draw_layout_section(tb)
        end

        UI.NextColumn()

        -- RIGHT: actions list + picker
        if tb then
            draw_actions_section(tb)
            UI.Separator()
            draw_action_picker(tb)
        end

        UI.EndColumns()
        UI.EndChild()

        UI.AppStatus((notice and r.time_precise() < notice_until) and notice
            or "Ctrl+drag the strip to move it · edits reach the toolbar within ~1s")
    end

    Persistence.ProcessSaveQueue(data)
end)

UI.OnClose(function()
    Persistence.FlushSave(data)
end)
