-- @description CP ColorPicker — quick track/item color popup
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   Minimal, fluid color popup that opens NEXT TO its target (not the cursor):
--   a selected track (default), or a selected item when no track is selected.
--   Track wins over item; with several tracks the bottom-most anchors the
--   window and the WHOLE selection is colored. Left-click a swatch = apply +
--   close. Right-click / Esc / click-outside = cancel. All swatches, palette,
--   favorites and the hue spectrum are configured in CP_ColorPicker_Settings.
--   Pure custom-drawn UI on CP_Toolkit — zero widgets, minimal cost.

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI     = dofile(toolkit_path .. "CP_Toolkit.lua")
local Colors = dofile(script_path .. "Modules/Colors.lua")

local r = reaper
local CONFIG_ID = "CP_ColorPicker"

-- ============================================================================
-- STATE
-- ============================================================================
local S = {
    cfg = nil,
    palette = {},        -- { {r,g,b,hex}, ... }  precomputed from cfg.palette
    favorites = {},      -- { {r,g,b,hex}, ... }
    spectrum = {},       -- { {r,g,b}, ... }       rebuilt when saturation moves
    spectrum_hex = {},   -- lazy per-hover hex cache (parallel to spectrum)
    sat = 0.65,
    sat_dirty = true,
    target = nil,        -- { kind, tracks|items, anchor_track|anchor_item }
    label = nil,         -- target caption (built once)
    W = 200, H = 160,
    cfg_version = 0,
    last_ver_check = 0,
    dragging_sat = false,
}

-- ============================================================================
-- CONFIG
-- ============================================================================
local function precompute_list(hex_list, out)
    for i = #out, 1, -1 do out[i] = nil end
    for i, hex in ipairs(hex_list) do
        local cr, cg, cb = Colors.hex_to_rgb(hex)
        out[i] = { cr, cg, cb, hex }
    end
end

local function load_cfg()
    S.cfg = Colors.merge_defaults(UI.LoadConfig(CONFIG_ID) or {})
    precompute_list(S.cfg.palette, S.palette)
    precompute_list(S.cfg.favorites, S.favorites)
    -- Last-used saturation persists independently of the palette file so the
    -- hot path never rewrites the whole config (PERFORMANCE.md rule 1).
    local saved = tonumber(UI.LoadPersistent(CONFIG_ID, "spectrum_sat"))
    S.sat = saved or S.cfg.spectrum_sat or 0.65
    S.sat_dirty = true
end

-- Live sync: the Settings editor bumps this ExtState stamp on save. Poll it
-- (throttled) and reload colors so an open popup reflects edits. Geometry
-- (columns/size) changes apply on next open — the popup is transient.
local function check_updates()
    local now = r.time_precise()
    if now - S.last_ver_check < 0.4 then return end
    S.last_ver_check = now
    local v = tonumber(r.GetExtState(CONFIG_ID, "settings_version")) or 0
    if v ~= S.cfg_version then
        S.cfg_version = v
        S.cfg = Colors.merge_defaults(UI.LoadConfig(CONFIG_ID) or {})
        precompute_list(S.cfg.palette, S.palette)
        precompute_list(S.cfg.favorites, S.favorites)
        S.sat_dirty = true
        S.geom_dirty = true  -- frame() recomputes size + resizes (compute_size
                             -- is defined later, so defer the call to the loop)
    end
end

-- ============================================================================
-- TARGET RESOLUTION
-- ============================================================================
-- Track selection wins over item selection. Anchor = bottom-most VISIBLE
-- entry (max I_TCPY among strips with I_TCPH > 0); if all are hidden, the
-- last-indexed one (index order == top-to-bottom TCP order in REAPER).
local function resolve_target()
    local nt = r.CountSelectedTracks(0)
    if nt > 0 then
        local tracks, anchor, anchor_y = {}, nil, -math.huge
        for i = 0, nt - 1 do
            local tr = r.GetSelectedTrack(0, i)
            tracks[#tracks + 1] = tr
            if r.GetMediaTrackInfo_Value(tr, "I_TCPH") > 0 then
                local ty = r.GetMediaTrackInfo_Value(tr, "I_TCPY")
                if ty > anchor_y then anchor_y = ty; anchor = tr end
            end
        end
        anchor = anchor or tracks[#tracks]
        local label
        if #tracks == 1 then
            local _, nm = r.GetTrackName(anchor)
            label = "Track: " .. (nm or "?")
        else
            label = string.format("%d pistes", #tracks)
        end
        return { kind = "track", tracks = tracks, anchor_track = anchor, label = label }
    end

    local ni = r.CountSelectedMediaItems(0)
    if ni > 0 then
        local items, anchor, anchor_y = {}, nil, -math.huge
        for i = 0, ni - 1 do
            local it = r.GetSelectedMediaItem(0, i)
            items[#items + 1] = it
            local tr = r.GetMediaItem_Track(it)
            if tr and r.GetMediaTrackInfo_Value(tr, "I_TCPH") > 0 then
                local ty = r.GetMediaTrackInfo_Value(tr, "I_TCPY")
                if ty > anchor_y then anchor_y = ty; anchor = it end
            end
        end
        anchor = anchor or items[#items]
        local label = ni == 1 and "Item" or string.format("%d items", ni)
        return { kind = "item", items = items, anchor_item = anchor, label = label }
    end

    return { kind = "none", label = "Aucune cible sélectionnée" }
end

-- ============================================================================
-- COLOR APPLICATION
-- ============================================================================
-- cr,cg,cb 0-1 floats; pass nil to clear (I_CUSTOMCOLOR = 0 = "no color").
local function apply_color(cr, cg, cb)
    local native = 0
    if cr ~= nil then
        local R, G, B = Colors.rgb_to_255(cr, cg, cb)
        native = r.ColorToNative(R, G, B) | 0x1000000
    end
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    local t = S.target
    if t and t.kind == "track" then
        for _, tr in ipairs(t.tracks) do
            if r.ValidatePtr(tr, "MediaTrack*") then
                r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", native)
            end
        end
    elseif t and t.kind == "item" then
        for _, it in ipairs(t.items) do
            if r.ValidatePtr(it, "MediaItem*") then
                r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", native)
            end
        end
    end
    r.Undo_EndBlock("CP ColorPicker: apply color", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.TrackList_AdjustWindows(false)
end

-- ============================================================================
-- WINDOW POSITIONING (screen coords)
-- ============================================================================
local function has_js()
    return r.APIExists("JS_Window_FindChildByID") and r.APIExists("JS_Window_GetRect")
end

-- Arrange/trackview window (child id 1000) screen rect, plus the main hwnd.
local function arrange_rect()
    if not has_js() then return nil end
    local main = r.GetMainHwnd()
    if not main then return nil end
    local ok, hwnd = pcall(r.JS_Window_FindChildByID, main, 1000)
    if not ok or not hwnd then return nil end
    local ok2, ret, l, t, rt, b = pcall(r.JS_Window_GetRect, hwnd)
    if not ok2 or not ret then return nil end
    return { left = l, top = t, right = rt, bottom = b }, main
end

-- X of the TCP/arrange divider (right edge of the track panels). child-1000
-- semantics vary by build/theme: on some it spans TCP+arrange, on others it is
-- the arrange only. Disambiguate at runtime by how far its left sits from the
-- main window's left, and fall back to arrange.left. offset_x nudges the rest.
local function divider_x(arrange, main)
    local panel_w
    if r.APIExists("SNM_GetIntConfigVar") then
        local w = r.SNM_GetIntConfigVar("leftpanewid", -1)
        if w and w > 0 then panel_w = w end
    end
    if not panel_w or not main then return arrange.left end
    local mok, mret, ml = pcall(r.JS_Window_GetRect, main)
    if mok and mret and (arrange.left - ml) < panel_w * 0.5 then
        return arrange.left + panel_w   -- child-1000 includes the TCP panel
    end
    return arrange.left                 -- child-1000 left already IS the divider
end

local function clamp_to_viewport(x, y, w, h)
    if r.APIExists("JS_Window_GetViewportFromRect") then
        local ok, l, t, rt, b = pcall(r.JS_Window_GetViewportFromRect, x, y, x + w, y + h, true)
        if ok and l and rt and rt > l and b > t then
            if x + w > rt then x = rt - w end
            if y + h > b  then y = b - h end
            if x < l then x = l end
            if y < t then y = t end
        end
    end
    return x, y
end

-- Returns screen x,y for the popup's top-left, anchored to the target.
local function compute_position()
    local t = S.target
    local arrange, main = arrange_rect()
    local x, y

    if arrange and t and t.kind ~= "none" then
        local div = divider_x(arrange, main)
        if t.kind == "track" and r.ValidatePtr(t.anchor_track, "MediaTrack*") then
            local tr = t.anchor_track
            local tcph = r.GetMediaTrackInfo_Value(tr, "I_TCPH")
            if tcph > 0 then
                local ty = arrange.top + r.GetMediaTrackInfo_Value(tr, "I_TCPY")
                if ty < arrange.bottom and ty + tcph > arrange.top then  -- visible
                    x = (S.cfg.anchor_side == "left") and (div - S.W) or div
                    y = ty
                end
            end
        elseif t.kind == "item" and r.ValidatePtr(t.anchor_item, "MediaItem*") then
            local it = t.anchor_item
            local tr = r.GetMediaItem_Track(it)
            local tcph = tr and r.GetMediaTrackInfo_Value(tr, "I_TCPH") or 0
            if tcph > 0 then
                local ttop = arrange.top + r.GetMediaTrackInfo_Value(tr, "I_TCPY")
                if ttop < arrange.bottom and ttop + tcph > arrange.top then  -- visible
                    local iy = ttop + r.GetMediaItemInfo_Value(it, "I_LASTY")
                    local ix = div
                    local vs, ve = r.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
                    if ve > vs then
                        local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
                        ix = div + (pos - vs) / (ve - vs) * (arrange.right - div)
                        if ix < div then ix = div elseif ix > arrange.right then ix = arrange.right end
                    end
                    x = (S.cfg.anchor_side == "left") and (ix - S.W) or ix
                    y = iy
                end
            end
        end
    end

    if x then
        x = x + (S.cfg.offset_x or 0)
        y = y + (S.cfg.offset_y or 0)
    else
        -- Fallback: no JS API, or target hidden/off-screen → near the mouse.
        local mx, my = r.GetMousePosition()
        x, y = mx + 10, my + 10
    end

    return clamp_to_viewport(math.floor(x), math.floor(y), S.W, S.H)
end

-- ============================================================================
-- GEOMETRY
-- ============================================================================
local ROW_GAP  = 6
local LABEL_H  = 15
local SAT_H    = 12

local function compute_size()
    local cfg = S.cfg
    local sz, gap, pad = cfg.swatch_size, cfg.gap, cfg.pad

    local show_label  = cfg.show_target_label or (S.target and S.target.kind == "none")
    local show_pal    = cfg.show_palette and #S.palette > 0
    local show_fav    = cfg.show_favorites and #S.favorites > 0
    local show_fav_row = show_fav or cfg.show_clear
    local show_spec   = cfg.show_spectrum and cfg.spectrum_cols > 0 and cfg.spectrum_rows > 0
    local show_slider = show_spec and cfg.show_saturation_slider

    local function row_w(cells) return cells > 0 and (cells * sz + (cells - 1) * gap) or 0 end
    local pal_cols = math.min(#S.palette, math.max(1, cfg.columns))

    -- Content width = widest enabled row.
    local content_w = 0
    if show_spec then content_w = math.max(content_w, row_w(cfg.spectrum_cols)) end
    if show_pal  then content_w = math.max(content_w, row_w(pal_cols)) end
    if show_fav_row then
        local favc = (show_fav and #S.favorites or 0) + (cfg.show_clear and 1 or 0)
        content_w = math.max(content_w, row_w(favc))
    end
    if content_w == 0 then content_w = row_w(1) end
    S.W = content_w + 2 * pad

    -- Height = stack of enabled rows (ROW_GAP only *between* rows).
    local h, first = pad, true
    local function add(rh) if not first then h = h + ROW_GAP end; h = h + rh; first = false end
    if show_label then add(LABEL_H) end
    if show_fav_row then add(sz) end
    if show_pal then
        local prows = math.ceil(#S.palette / pal_cols)
        add(prows * sz + (prows - 1) * gap)
    end
    if show_spec then add(cfg.spectrum_rows * sz + (cfg.spectrum_rows - 1) * gap) end
    if show_slider then add(SAT_H) end
    h = h + pad
    S.H = math.max(sz + 2 * pad, h)

    S._show_label   = show_label
    S._show_pal     = show_pal
    S._show_fav     = show_fav
    S._show_fav_row = show_fav_row
    S._show_spec    = show_spec
    S._show_slider  = show_slider
end

-- ============================================================================
-- DRAW HELPERS (window-local coords: 0,0 = window top-left)
-- ============================================================================
local pick_r, pick_g, pick_b, pick_clear, has_pick

-- Draws one swatch; returns true if hovered. Sets has_pick on left-click.
local function swatch(theme, x, y, sz, cr, cg, cb, id, is_clear, hex)
    local hov = UI.Core.MouseInRect(x, y, sz, sz)
    if is_clear then
        UI.Core.DrawRect(x, y, sz, sz, 0.16, 0.16, 0.17, 1, true)
        UI.Core.DrawLine(x + 3, y + sz - 3, x + sz - 3, y + 3, 0.85, 0.35, 0.35, 1)
    else
        UI.Core.DrawRect(x, y, sz, sz, cr, cg, cb, 1, true)
    end
    local bc = theme.colors.border
    UI.Core.DrawRect(x, y, sz, sz, bc[1], bc[2], bc[3], hov and 1 or 0.55, false)
    if hov then
        UI.Core.DrawRect(x - 1, y - 1, sz + 2, sz + 2, 1, 1, 1, 0.9, false)
        UI.Core.SetHot(id)
        if hex then UI.Tooltip(hex) end
        if UI.Core.MouseClicked(1) then
            has_pick = true
            if is_clear then
                pick_clear = true
            else
                pick_r, pick_g, pick_b, pick_clear = cr, cg, cb, false
            end
        end
    end
    return hov
end

-- ============================================================================
-- FRAME
-- ============================================================================
local function frame(theme)
    check_updates()
    if S.geom_dirty then
        compute_size()
        UI.SetSize(S.W, S.H)
        S.geom_dirty = false
    end

    -- Opaque background every frame (frameless windows paint their own).
    local bg = theme.colors.window_bg
    UI.Core.DrawRect(0, 0, S.W, S.H, bg[1], bg[2], bg[3], 1, true)

    local cfg = S.cfg
    local sz, gap, pad = cfg.swatch_size, cfg.gap, cfg.pad
    has_pick, pick_clear = false, false

    local y = pad

    -- Target label (optional / forced when no target).
    if S._show_label and S.target then
        UI.Core.DrawText(UI.Core.TruncateText(S.target.label, S.W - 2 * pad),
                         pad, y, 0.72, 0.72, 0.74, 1)
        y = y + LABEL_H + ROW_GAP
    end

    -- Favorites row (+ clear chip, right-aligned). Both optional.
    if S._show_fav_row then
        local x = pad
        if S._show_fav then
            for i, c in ipairs(S.favorites) do
                swatch(theme, x, y, sz, c[1], c[2], c[3], "fav" .. i, false, c[4])
                x = x + sz + gap
            end
        end
        if cfg.show_clear then
            swatch(theme, S.W - pad - sz, y, sz, 0, 0, 0, "clear", true, nil)
        end
        y = y + sz + ROW_GAP
    end

    -- Palette grid. Optional.
    if S._show_pal then
        local cols = math.min(#S.palette, math.max(1, cfg.columns))
        local prows = math.ceil(#S.palette / cols)
        for i, c in ipairs(S.palette) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            swatch(theme, pad + col * (sz + gap), y + row * (sz + gap), sz,
                   c[1], c[2], c[3], "pal" .. i, false, c[4])
        end
        y = y + prows * sz + (prows - 1) * gap + ROW_GAP
    end

    -- Hue-spectrum GRID (the default UI): spectrum_cols hues across x
    -- spectrum_rows brightness levels down, at the current saturation.
    if S._show_spec then
        if S.sat_dirty then
            local sat = cfg.show_saturation_slider and S.sat or cfg.spectrum_sat
            Colors.fill_spectrum_grid(S.spectrum, cfg.spectrum_cols, cfg.spectrum_rows,
                                      sat, cfg.spectrum_val_top, cfg.spectrum_val_bottom)
            for i = #S.spectrum_hex, 1, -1 do S.spectrum_hex[i] = nil end
            S.sat_dirty = false
        end
        local cols = cfg.spectrum_cols
        for i, c in ipairs(S.spectrum) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local hov = swatch(theme, pad + col * (sz + gap), y + row * (sz + gap), sz,
                               c[1], c[2], c[3], "spec" .. i, false, nil)
            if hov then
                local hex = S.spectrum_hex[i]
                if not hex then hex = Colors.rgb_to_hex(c[1], c[2], c[3]); S.spectrum_hex[i] = hex end
                UI.Tooltip(hex)
            end
        end
        y = y + cfg.spectrum_rows * sz + (cfg.spectrum_rows - 1) * gap + ROW_GAP
    end

    -- Saturation slider (hand-drawn gradient track + grab). Optional.
    if S._show_slider then
        local sx, sw = pad, S.W - 2 * pad
        local grabx = sx + S.sat * sw
        local ac = theme.colors.accent
        UI.DrawGradientRect(sx, y, sw, SAT_H, 0.55, 0.55, 0.55, 1, ac[1], ac[2], ac[3], 1, false)
        local bc = theme.colors.border
        UI.Core.DrawRect(sx, y, sw, SAT_H, bc[1], bc[2], bc[3], 0.6, false)
        UI.Core.DrawRect(grabx - 2, y - 1, 4, SAT_H + 2, 1, 1, 1, 1, true)

        local over = UI.Core.MouseInRect(sx, y - 2, sw, SAT_H + 4)
        if over and UI.Core.MouseClicked(1) then S.dragging_sat = true end
        if S.dragging_sat then
            if UI.Core.MouseDown(1) then
                local mx = UI.Core.GetMousePos()
                local nv = (mx - sx) / sw
                nv = nv < 0 and 0 or (nv > 1 and 1 or nv)
                if nv ~= S.sat then S.sat = nv; S.sat_dirty = true end
                UI.RequestRedraw()
            else
                S.dragging_sat = false
            end
        end
        y = y + SAT_H + ROW_GAP
    end

    -- Apply + close on a swatch pick.
    if has_pick then
        if pick_clear then apply_color(nil)
        else apply_color(pick_r, pick_g, pick_b) end
        UI.Core.RequestClose()
        return
    end

    -- Cancel: right-click anywhere, or left-click outside the window.
    if UI.Core.MouseClicked(2) then
        UI.Core.RequestClose()
        return
    end
    if UI.Core.MouseClicked(1) and not S.dragging_sat then
        local hwnd = UI.Core.GetHWND()
        if hwnd then
            local ok, ret, l, t, rt, b = pcall(r.JS_Window_GetRect, hwnd)
            if ok and ret then
                local mx, my = r.GetMousePosition()
                if mx < l or mx >= rt or my < t or my >= b then
                    UI.Core.RequestClose()
                end
            end
        end
    end
end

-- ============================================================================
-- LAUNCH
-- ============================================================================
load_cfg()
S.cfg_version = tonumber(r.GetExtState(CONFIG_ID, "settings_version")) or 0
S.target = resolve_target()
compute_size()
local win_x, win_y = compute_position()

-- Toolbar toggle state.
local _, _, section_id, command_id = r.get_action_context()
r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

UI.Init("CP ColorPicker", S.W, S.H, {
    frameless = true,
    topmost = true,
    scrollable = false,
    padding = 0,
    x = win_x,
    y = win_y,
})
UI.SetPosition(win_x, win_y)  -- pixel-exact (SetFrameless keeps the frame corner)

UI.Run(frame)

UI.OnClose(function()
    UI.SavePersistent(CONFIG_ID, "spectrum_sat", tostring(S.sat))
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end)
