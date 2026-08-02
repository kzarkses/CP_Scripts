-- @description CP Cursor Probe — voir les curseurs de REAPER, et les nommer
-- @version 1.0
-- @author Cedric Pamalio
--
-- ---------------------------------------------------------------------------
-- POURQUOI UNE SONDE PLUTOT QU'UNE TABLE
-- ---------------------------------------------------------------------------
-- REAPER porte toute une panoplie de curseurs — la gomme, la main qui copie,
-- l'etirement, le rasoir, les fondus — et `gfx.setcursor(id, nom)` sait les
-- poser. Mais NI les identifiants NI les noms ne sont documentes, et se
-- tromper est SILENCIEUX : on obtient le curseur de repli, et on conclut que
-- celui qu'on cherchait n'existe pas.
--
-- Une table de correspondances ecrite de memoire serait donc une table dont on
-- ne saurait jamais si elle est juste. Cette fenetre les MONTRE : on survole
-- une case, le curseur change, on lit le numero. C'est la meme discipline que
-- le reste de la suite — se donner les moyens de VOIR plutot que d'expliquer.
--
-- Ce qu'on trouve se pose ensuite avec `Core.SetCursorName(role, nom)`, depuis
-- la configuration : le toolkit ne doit pas porter des noms qu'il ne peut pas
-- verifier lui-meme.
--
-- ---------------------------------------------------------------------------
-- CE QUE LA SONDE NE PEUT PAS FAIRE
-- ---------------------------------------------------------------------------
-- Elle ne peut pas ENUMERER les curseurs : rien dans l'API ne rend la liste.
-- Elle balaie donc une plage d'identifiants — celle ou vivent les curseurs de
-- REAPER d'apres les scripts publics — et laisse l'oeil trancher. Un
-- identifiant vide rend le curseur par defaut, ce qui se voit aussi.

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root = script_path:match("(.*[\\/]).*[\\/]") or script_path

local UI = dofile(root .. "CP_Toolkit/CP_Toolkit.lua")
local r = reaper
local Core = UI.Core

-- La plage a balayer. Les curseurs de REAPER vivent au-dessus des identifiants
-- systeme (32512..32651) ; ceux-ci sont donc montres a part, en premier, pour
-- servir de point de comparaison — on reconnait la fleche et la main, donc on
-- sait que la fenetre marche.
local SYS = { 32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644,
              32645, 32646, 32648, 32649, 32650, 32651 }

local S = {
    lo = 100,          -- debut de la plage exploree
    span = 200,        -- combien on en montre a la fois
    found = {},        -- identifiants notes par Cedric
    note = "",
    hover = nil,
}

local CELL_W, CELL_H = 58, 26

local function drawGrid(theme, x, y, w, ids, label)
    local C = theme.colors
    local dim = C.text_mute or C.text_disabled
    local acc = C.accent
    Core.DrawText(label, x, y, dim[1], dim[2], dim[3], 1)
    y = y + 18
    local mx, my = Core.GetMousePos()
    local cols = math.max(1, math.floor(w / CELL_W))
    for i = 1, #ids do
        local cx = x + ((i - 1) % cols) * CELL_W
        local cy = y + math.floor((i - 1) / cols) * CELL_H
        local hot = mx >= cx and mx < cx + CELL_W - 2
                and my >= cy and my < cy + CELL_H - 2
        local id = ids[i]
        local noted = S.found[id]
        if hot then
            Core.DrawRect(cx, cy, CELL_W - 2, CELL_H - 2,
                          acc[1], acc[2], acc[3], 0.30)
            -- LE SURVOL EST LA MESURE : c'est en passant dessus qu'on voit le
            -- curseur, donc la case ne fait rien d'autre que le poser.
            gfx.setcursor(id)
            S.hover = id
            if Core.MouseClicked(1) then
                S.found[id] = not noted or nil
            end
        elseif noted then
            Core.DrawRect(cx, cy, CELL_W - 2, CELL_H - 2,
                          acc[1], acc[2], acc[3], 0.15)
        end
        local col = noted and acc or (C.text)
        Core.DrawText(tostring(id), cx + 6, cy + 5, col[1], col[2], col[3], 1)
    end
    return y + math.ceil(#ids / cols) * CELL_H + 10
end

local ids = {}
local function rebuild()
    for i = #ids, 1, -1 do ids[i] = nil end
    for k = 0, S.span - 1 do ids[k + 1] = S.lo + k end
end
rebuild()

local function frame(theme)
    UI.SetWindowPadding(theme.pad_large or 10)
    local C = theme.colors

    UI.SetFontTitle()
    UI.Text("Cursor probe")
    UI.SetFontBody()
    UI.Text("Hover a number to see that cursor. Click to mark it — the marked "
            .. "ones are listed at the bottom, ready to be copied out.")
    UI.Separator()
    UI.Spacing()

    local ch, lo = UI.NumberInput("lo", "First id", S.lo, 0, 100000)
    if ch then S.lo = math.floor(lo) rebuild() end
    UI.SameLine()
    local ch2, sp = UI.NumberInput("span", "How many", S.span, 20, 600)
    if ch2 then S.span = math.floor(sp) rebuild() end

    UI.Spacing()
    local x, y = UI.Layout.GetCursorPos()
    local w = UI.GetAvailableWidth()
    S.hover = nil
    local y2 = drawGrid(theme, x, y, w, SYS,
                        "Windows standard — the ones we already know")
    y2 = drawGrid(theme, x, y2, w, ids,
                  "REAPER range — " .. S.lo .. " to " .. (S.lo + S.span - 1))
    UI.Layout.AdvanceCursor(w, y2 - y)

    UI.Spacing()
    UI.Separator()
    local marked = {}
    for id in pairs(S.found) do marked[#marked + 1] = id end
    table.sort(marked)
    UI.Text(#marked == 0 and "Nothing marked yet."
            or ("Marked: " .. table.concat(marked, ", ")))
    if S.hover then
        local a = C.accent
        UI.TextColored("Under the pointer: " .. S.hover, a[1], a[2], a[3], 1)
    end
    UI.RequestRedraw()
end

UI.Init("CP Cursor Probe", 720, 640,
        { scale = 1.0, dock = 0, persist = "CP_CursorProbe" })
UI.Run(frame)
