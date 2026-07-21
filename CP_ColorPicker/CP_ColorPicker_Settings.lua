-- @description CP ColorPicker Settings — palette / favorites / spectrum / window
-- @version 1.0
-- @author Cedric Pamalio

-- Companion editor for CP_ColorPicker. Edits CP_Config/CP_ColorPicker.lua and
-- bumps an ExtState "settings_version" stamp so an already-open popup reloads
-- its colors live (CP_Inspector pattern). Auto-saves (dirty + 0.2s throttle)
-- plus a final save on close. Does NOT set toolbar toggle state (it's a dialog).

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI     = dofile(toolkit_path .. "CP_Toolkit.lua")
local Colors = dofile(script_path .. "Modules/Colors.lua")

local r = reaper
local CONFIG_ID = "CP_ColorPicker"

local S = {
    cfg = Colors.merge_defaults(UI.LoadConfig(CONFIG_ID) or {}),
    tab = 1,
    pal_sel = 1,
    fav_sel = 1,
    dirty = false,
    last_save = 0,
}

local TABS = { "Spectre", "Palette", "Favoris", "Fenêtre" }

-- ============================================================================
-- SAVE + cross-script live-sync stamp
-- ============================================================================
local function save_now()
    UI.SaveConfig(CONFIG_ID, S.cfg)
    local v = (tonumber(r.GetExtState(CONFIG_ID, "settings_version")) or 0) + 1
    r.SetExtState(CONFIG_ID, "settings_version", tostring(v), false)
    S.dirty = false
end

local function mark_dirty() S.dirty = true end

local function autosave()
    if not S.dirty then return end
    local now = r.time_precise()
    if now - S.last_save < 0.2 then return end
    S.last_save = now
    save_now()
end

-- ============================================================================
-- EDITABLE COLOR LIST (shared by Palette + Favoris tabs)
-- ============================================================================
local function color_list_editor(theme, gid, list, sel_key)
    local sel = S[sel_key]
    if #list == 0 then sel = 0
    elseif sel < 1 then sel = 1
    elseif sel > #list then sel = #list end
    S[sel_key] = sel

    if #list == 0 then
        UI.Text("Liste vide — « + Ajouter » pour créer une couleur.")
    else
        local sz = 22
        UI.BeginGrid(gid, { cell_w = sz, cell_h = sz, gap = 5 })
        for i, hex in ipairs(list) do
            local x, y, w, h = UI.GridCell(gid)
            local cr, cg, cb = Colors.hex_to_rgb(hex)
            local hov = UI.Core.MouseInClippedRect(x, y, w, h)
            UI.Core.DrawRect(x, y, w, h, cr, cg, cb, 1, true)
            local bc = theme.colors.border
            UI.Core.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], hov and 1 or 0.5, false)
            if i == sel then
                local ac = theme.colors.accent
                UI.Core.DrawRect(x - 2, y - 2, w + 4, h + 4, ac[1], ac[2], ac[3], 1, false)
            end
            if hov then
                UI.Core.SetHot(gid .. i)
                UI.Tooltip(hex)
                if UI.Core.MouseClicked(1) then S[sel_key] = i; sel = i end
            end
        end
        UI.EndGrid(gid)
    end

    UI.Spacing()

    -- Row of actions
    if UI.Button(gid .. "_add", "＋ Ajouter") then
        list[#list + 1] = "#808080"
        S[sel_key] = #list; sel = #list
        mark_dirty()
    end
    UI.SameLine()
    if UI.Button(gid .. "_dup", "Dupliquer") and sel >= 1 and list[sel] then
        table.insert(list, sel + 1, list[sel])
        S[sel_key] = sel + 1; sel = sel + 1
        mark_dirty()
    end
    UI.SameLine()
    if UI.Button(gid .. "_del", "Supprimer") and sel >= 1 and list[sel] then
        table.remove(list, sel)
        if S[sel_key] > #list then S[sel_key] = #list end
        sel = S[sel_key]
        mark_dirty()
    end
    UI.SameLine()
    if UI.Button(gid .. "_l", "◀") and sel > 1 then
        list[sel], list[sel - 1] = list[sel - 1], list[sel]
        S[sel_key] = sel - 1; sel = sel - 1; mark_dirty()
    end
    UI.SameLine()
    if UI.Button(gid .. "_r", "▶") and sel >= 1 and sel < #list then
        list[sel], list[sel + 1] = list[sel + 1], list[sel]
        S[sel_key] = sel + 1; sel = sel + 1; mark_dirty()
    end

    -- Editor for the selected color
    if sel >= 1 and list[sel] then
        UI.Separator()
        local cr, cg, cb = Colors.hex_to_rgb(list[sel])
        local edit = S[gid .. "_rgb"]
        if not edit then edit = {}; S[gid .. "_rgb"] = edit end
        edit[1], edit[2], edit[3] = cr, cg, cb

        local changed, nc = UI.ColorPicker(gid .. "_cp", "Couleur", edit)
        local picker_changed = false
        if changed then
            list[sel] = Colors.rgb_to_hex(nc[1], nc[2], nc[3])
            picker_changed = true
            mark_dirty()
        end

        UI.SameLine()
        local hk = gid .. "_hex"
        if S[hk .. "_for"] ~= sel or picker_changed then
            S[hk] = list[sel]; S[hk .. "_for"] = sel
        end
        local ch2, nt, submitted = UI.InputText(gid .. "_hexin", "Hex", S[hk] or "", { width = 90 })
        if ch2 then S[hk] = nt end
        if submitted then
            local clean = (nt or ""):gsub("#", "")
            if clean:match("^%x%x%x%x%x%x$") then
                list[sel] = "#" .. clean:upper()
                S[hk] = list[sel]
                mark_dirty()
            end
        end
    end
end

-- ============================================================================
-- TABS
-- ============================================================================
local function tab_palette(theme)
    UI.Text("Couleurs de la grille principale.")
    UI.Spacing()
    color_list_editor(theme, "pal", S.cfg.palette, "pal_sel")
end

local function tab_favoris(theme)
    UI.Text("Rangée de favoris (au-dessus de la grille).")
    UI.Spacing()
    color_list_editor(theme, "fav", S.cfg.favorites, "fav_sel")
end

local function tab_spectre(theme)
    local cfg = S.cfg
    UI.Text("Grille de teintes — l'affichage par défaut du popup.")
    UI.Spacing()

    local c1, v1 = UI.NumberInput("sp_cols", "Colonnes (teintes)", cfg.spectrum_cols, 1, 24, { step = 1 })
    if c1 then cfg.spectrum_cols = math.floor(v1 + 0.5); mark_dirty() end
    local c2, v2 = UI.NumberInput("sp_rows", "Lignes (luminosité)", cfg.spectrum_rows, 1, 6, { step = 1 })
    if c2 then cfg.spectrum_rows = math.floor(v2 + 0.5); mark_dirty() end

    local c3, v3 = UI.SliderDouble("sp_sat", "Saturation", cfg.spectrum_sat, 0.0, 1.0, { format = "%.2f" })
    if c3 then cfg.spectrum_sat = v3; mark_dirty() end
    local c4, v4 = UI.SliderDouble("sp_vt", "Luminosité (ligne du haut)", cfg.spectrum_val_top, 0.2, 1.0, { format = "%.2f" })
    if c4 then cfg.spectrum_val_top = v4; mark_dirty() end
    local c5, v5 = UI.SliderDouble("sp_vb", "Luminosité (ligne du bas)", cfg.spectrum_val_bottom, 0.1, 1.0, { format = "%.2f" })
    if c5 then cfg.spectrum_val_bottom = v5; mark_dirty() end

    local t1, tv1 = UI.Checkbox("sp_sl", "Slider de saturation dans le popup", cfg.show_saturation_slider)
    if t1 then cfg.show_saturation_slider = tv1; mark_dirty() end

    -- Live preview of the actual grid.
    UI.Spacing()
    UI.Text("Aperçu :")
    local cols = math.max(1, math.floor(cfg.spectrum_cols))
    local rows = math.max(1, math.floor(cfg.spectrum_rows))
    local sz, gap = 20, 4
    local x0, y0 = UI.GetCursorPos()
    for row = 0, rows - 1 do
        local v = (rows <= 1) and cfg.spectrum_val_top
                  or (cfg.spectrum_val_top + (cfg.spectrum_val_bottom - cfg.spectrum_val_top) * row / (rows - 1))
        for col = 0, cols - 1 do
            local cr, cg, cb = Colors.hsv_to_rgb(col / cols * 360, cfg.spectrum_sat, v)
            local x = x0 + col * (sz + gap)
            local yy = y0 + row * (sz + gap)
            UI.Core.DrawRect(x, yy, sz, sz, cr, cg, cb, 1, true)
            local bc = theme.colors.border
            UI.Core.DrawRect(x, yy, sz, sz, bc[1], bc[2], bc[3], 0.5, false)
        end
    end
    UI.Spacing(rows * (sz + gap) + 4)
end

local function tab_window(theme)
    local cfg = S.cfg

    UI.Text("Éléments optionnels du popup (désactivés par défaut).")
    UI.Spacing()
    local a1, av1 = UI.Checkbox("sh_pal", "Grille palette", cfg.show_palette)
    if a1 then cfg.show_palette = av1; mark_dirty() end
    local a2, av2 = UI.Checkbox("sh_fav", "Rangée de favoris", cfg.show_favorites)
    if a2 then cfg.show_favorites = av2; mark_dirty() end
    local a3, av3 = UI.Checkbox("sh_clr", "Pastille « sans couleur »", cfg.show_clear)
    if a3 then cfg.show_clear = av3; mark_dirty() end
    local a4, av4 = UI.Checkbox("sh_lbl", "Nom de la cible", cfg.show_target_label)
    if a4 then cfg.show_target_label = av4; mark_dirty() end

    UI.Separator()
    UI.Text("Position par rapport à la cible.")
    UI.Spacing()
    local side_idx = (cfg.anchor_side == "left") and 2 or 1
    local sc, si = UI.Combo("side", "Côté", side_idx, { "Droite du panneau TCP", "Gauche du panneau TCP" })
    if sc then cfg.anchor_side = (si == 2) and "left" or "right"; mark_dirty() end
    local ox, oxv = UI.NumberInput("ox", "Décalage X (px)", cfg.offset_x, -2000, 2000, { step = 1 })
    if ox then cfg.offset_x = math.floor(oxv + 0.5); mark_dirty() end
    local oy, oyv = UI.NumberInput("oy", "Décalage Y (px)", cfg.offset_y, -2000, 2000, { step = 1 })
    if oy then cfg.offset_y = math.floor(oyv + 0.5); mark_dirty() end

    UI.Separator()
    UI.Text("Dimensions.")
    UI.Spacing()
    local sc2, scv = UI.NumberInput("swz", "Taille pastille (px)", cfg.swatch_size, 10, 48, { step = 1 })
    if sc2 then cfg.swatch_size = math.floor(scv + 0.5); mark_dirty() end
    local gc, gcv = UI.NumberInput("gap", "Espacement (px)", cfg.gap, 0, 16, { step = 1 })
    if gc then cfg.gap = math.floor(gcv + 0.5); mark_dirty() end
    local pc, pcv = UI.NumberInput("pad", "Marge (px)", cfg.pad, 0, 24, { step = 1 })
    if pc then cfg.pad = math.floor(pcv + 0.5); mark_dirty() end
    local cc, ccv = UI.NumberInput("cols", "Colonnes palette", cfg.columns, 1, 16, { step = 1 })
    if cc then cfg.columns = math.floor(ccv + 0.5); mark_dirty() end
end

-- ============================================================================
-- FRAME
-- ============================================================================
local function frame(theme)
    UI.CheckThemeUpdates()

    UI.SetFontTitle()
    UI.Text("CP ColorPicker — Options")
    UI.SetFontBody()
    UI.Separator()

    local _, tab = UI.TabBar("tabs", TABS, S.tab)
    S.tab = tab
    UI.Spacing()

    if S.tab == 1 then tab_spectre(theme)
    elseif S.tab == 2 then tab_palette(theme)
    elseif S.tab == 3 then tab_favoris(theme)
    else tab_window(theme) end

    autosave()
end

-- ============================================================================
-- LAUNCH
-- ============================================================================
UI.Init("CP ColorPicker — Options", 420, 500, {
    scale = 1.0,
    dock = 0,
    persist = "CP_ColorPicker_Settings",
})

UI.Run(frame)

UI.OnClose(function()
    if S.dirty then save_now() end
end)
