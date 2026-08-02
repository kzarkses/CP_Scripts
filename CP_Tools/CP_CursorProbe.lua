-- @description CP Cursor Probe — voir les curseurs de REAPER, par leur nom
-- @version 1.1
-- @author Cedric Pamalio
--
-- ---------------------------------------------------------------------------
-- A QUOI CA SERT MAINTENANT
-- ---------------------------------------------------------------------------
-- La liste des noms est connue : REAPER la publie dans sa documentation de
-- theming (le dossier `Cursors` du chemin de ressources, ou un .cur du meme nom
-- remplace celui d'origine). On n'a donc plus rien a deviner.
--
-- Reste une chose qu'aucune liste ne dit : A QUOI ILS RESSEMBLENT. Un nom
-- n'apprend pas si `arrange_dd_copy` porte un « + » lisible a cette taille, ni
-- si `delete` se distingue de la fleche ordinaire sur un theme sombre. Et un
-- nom qui ne resout pas est SILENCIEUX : on obtient le curseur de repli sans
-- qu'un message ne le dise.
--
-- Cette fenetre les montre. On survole un nom, le curseur devient celui-la.
-- C'est la reference qu'on ouvre en choisissant un curseur pour un geste, et
-- c'est la meme discipline que le reste de la suite : se donner les moyens de
-- VOIR plutot que d'expliquer.
--
-- Les noms en gras sont ceux que CP_Editor utilise deja.

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root = script_path:match("(.*[\\/]).*[\\/]") or script_path

local UI = dofile(root .. "CP_Toolkit/CP_Toolkit.lua")
local r = reaper
local Core = UI.Core

-- Les noms de REAPER, groupes par famille. Repris de sa documentation de
-- theming ; l'ordre est celui de la lecture, pas celui du fichier.
local GROUPS = {
    { "Ce que CP_Editor utilise", {
        "arrange_dd_copy", "delete", "arrange_pencil", "arrange_rightstretch",
        "midi_note", "arrange_rightresize", "midi_move_horz", "midi_move_vert",
        "midi_kb", "midi_vel", "arrange_marquee", "arrange_handscroll",
        "ruler_timesel", "timesel_move",
    } },
    { "MIDI", {
        "midi_bg", "midi_gridhandle", "midi_vellane_size", "midi_vol",
        "arrange_timesel",
    } },
    { "Items et arrangement", {
        "arrange_move", "arrange_move_vert", "arrange_leftresize",
        "arrange_leftstretch", "arrange_dualedge", "arrange_dualstretch",
        "arrange_fadein", "arrange_fadeout", "arrange_slide",
        "arrange_snapoffs", "arrange_ibeam", "arrange_itemvol",
        "arrange_pan_adj", "arrange_pitch_adj", "arrange_scroll",
        "arrange_marqueezoom", "arrange_stretchmarker", "arrange_takemarker",
        "arrange_topresize", "arrange_bottomresize", "arrange_dd_tonew",
    } },
    { "Enveloppes", {
        "env_addpt", "env_pencil", "env_pt_bez", "env_pt_leftright",
        "env_pt_move", "env_pt_updown", "env_seg", "env_lane_updown",
    } },
    { "Regle, rasoir, comping", {
        "ruler_marker", "ruler_region", "ruler_regionedge", "ruler_scroll",
        "ruler_tsmarker", "razor", "razor_copy", "razor_move", "razor_env",
        "highlighter", "highlighter_move", "highlighter_select",
    } },
    { "Glisser-deposer, docks, divers", {
        "dragdrop", "dragdropmove", "fx_dd", "fx_dd_move", "fx_dd_no",
        "media_dd", "media_dd_no", "mcp_fx_dd", "mcp_routing_dd",
        "make_folder", "vertical_drag", "horizontal_drag",
        "dock_resize", "dock_resize_ew", "tcp_resize", "tcppane_resize",
        "fx_resize", "toolbar_resize", "sweep", "arrow",
        "xfade_curve", "xfade_move", "xfade_width",
        "fadein_curve", "fadeout_curve",
    } },
}

local S = { hover = nil, copied = "" }
local CELL_W, CELL_H = 178, 20

local function frame(theme)
    UI.SetWindowPadding(theme.pad_large or 10)
    local C = theme.colors
    local dim = C.text_mute or C.text_disabled
    local acc = C.accent

    UI.SetFontTitle()
    UI.Text("REAPER cursors")
    UI.SetFontBody()
    UI.Text("Hover a name to see that cursor. Click to copy it to the clipboard.")
    UI.Separator()
    UI.Spacing()

    local x, y = UI.Layout.GetCursorPos()
    local w = UI.GetAvailableWidth()
    local mx, my = Core.GetMousePos()
    local cols = math.max(1, math.floor(w / CELL_W))
    local cy = y
    S.hover = nil

    for gi = 1, #GROUPS do
        local title, names = GROUPS[gi][1], GROUPS[gi][2]
        Core.DrawText(title, x, cy, dim[1], dim[2], dim[3], 1)
        cy = cy + 18
        for i = 1, #names do
            local cx = x + ((i - 1) % cols) * CELL_W
            local ry = cy + math.floor((i - 1) / cols) * CELL_H
            local hot = mx >= cx and mx < cx + CELL_W - 4
                    and my >= ry and my < ry + CELL_H - 2
            if hot then
                Core.DrawRect(cx, ry, CELL_W - 4, CELL_H - 2,
                              acc[1], acc[2], acc[3], 0.28)
                -- LE SURVOL EST LA MESURE : la case ne fait rien d'autre que
                -- poser le curseur, et c'est en le voyant qu'on l'identifie.
                gfx.setcursor(0, names[i])
                S.hover = names[i]
                if Core.MouseClicked(1) then
                    if r.CF_SetClipboard then r.CF_SetClipboard(names[i]) end
                    S.copied = names[i]
                end
            end
            local col = hot and acc or C.text
            Core.DrawText(names[i], cx + 4, ry + 3, col[1], col[2], col[3], 1)
        end
        cy = cy + math.ceil(#names / cols) * CELL_H + 12
    end

    UI.Layout.AdvanceCursor(w, cy - y)
    UI.Spacing()
    UI.Separator()
    if S.hover then
        UI.TextColored("Under the pointer: " .. S.hover, acc[1], acc[2], acc[3], 1)
    else
        -- Le curseur reprend sa forme normale des qu'on quitte la grille,
        -- sinon celui de la derniere case resterait pose sur toute la fenetre.
        gfx.setcursor(32512)
        UI.Text("—")
    end
    if S.copied ~= "" then
        UI.Text("Copied: " .. S.copied)
    end
    UI.RequestRedraw()
end

UI.Init("CP Cursor Probe", 760, 700,
        { scale = 1.0, dock = 0, persist = "CP_CursorProbe" })
UI.Run(frame)
