-- CP_VideoKit / Effect: Crop
-- Crops the picture from each side, with optional repositioning of the
-- cropped result within the canvas.
--
-- Drag interactions:
--   * inside the cropped rect → move (pos_x, pos_y)
--   * edge handle             → that side moves inward/outward
--   * corner handle           → both adjacent sides move
--   * Shift + corner          → aspect locked to current ratio
--   * Alt + edge or corner    → mirrored (opposite side moves equally)

local M = {
    id     = "cropzoom",
    name   = "Crop",
    tag    = "CP_VideoKit_CropZoom",
    preset = "CropZoom.eel",
}

M.params = {
    crop_l     = 0,
    crop_t     = 1,
    crop_r     = 2,
    crop_b     = 3,
    pos_x      = 4,
    pos_y      = 5,
    stretch_x  = 6,
    stretch_y  = 7,
    rot        = 8,
    flip       = 9,
    show_frame = 10,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    local v = Core.get_param(take, fx, idx)
    return v or def
end

function M.read_state(Core, take, fx_idx)
    return {
        crop_l    = get(Core, take, fx_idx, M.params.crop_l,    0),
        crop_t    = get(Core, take, fx_idx, M.params.crop_t,    0),
        crop_r    = get(Core, take, fx_idx, M.params.crop_r,    0),
        crop_b    = get(Core, take, fx_idx, M.params.crop_b,    0),
        pos_x     = get(Core, take, fx_idx, M.params.pos_x,     0),
        pos_y     = get(Core, take, fx_idx, M.params.pos_y,     0),
        stretch_x = get(Core, take, fx_idx, M.params.stretch_x, 1),
        stretch_y = get(Core, take, fx_idx, M.params.stretch_y, 1),
        rot       = get(Core, take, fx_idx, M.params.rot,       0),
        flip      = get(Core, take, fx_idx, M.params.flip,      0),
    }
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- ---------------------------------------------------------------------------
-- Visible rectangle in normalized canvas coords [0..1].
-- Bounds shift by pos_x/pos_y (translation of the cropped image).
-- ---------------------------------------------------------------------------
local function visible_rect(s)
    local px = s.pos_x * 0.5
    local py = s.pos_y * 0.5
    return s.crop_l + px, s.crop_t + py,
           1 - s.crop_r + px, 1 - s.crop_b + py
end

-- ---------------------------------------------------------------------------
-- Handle hit test. Generous tolerance so handles are easy to grab even
-- when the OS Video Window adds its own letterbox margins.
-- ---------------------------------------------------------------------------
-- Hit tolerances. Edges along the side use a wider band so the user can
-- grab a side from anywhere on the long axis. The corner zone is large
-- enough that diagonal grabs don't accidentally fall through to "move".
local CORNER  = 0.08
local EDGE    = 0.06

local function hit_handle(s, nx, ny)
    local x0, y0, x1, y1 = visible_rect(s)

    -- Corners first (priority over edges/inside).
    if math.abs(nx - x0) < CORNER and math.abs(ny - y0) < CORNER then return "nw" end
    if math.abs(nx - x1) < CORNER and math.abs(ny - y0) < CORNER then return "ne" end
    if math.abs(nx - x0) < CORNER and math.abs(ny - y1) < CORNER then return "sw" end
    if math.abs(nx - x1) < CORNER and math.abs(ny - y1) < CORNER then return "se" end

    -- Edges. Choose the closest side to the click; this avoids ambiguity
    -- when the click is near a corner but outside the corner zone (the
    -- order of if-tests previously favored top/bottom over left/right).
    local in_x = (nx > x0 - EDGE and nx < x1 + EDGE)
    local in_y = (ny > y0 - EDGE and ny < y1 + EDGE)
    local d_w  = math.abs(nx - x0)
    local d_e  = math.abs(nx - x1)
    local d_n  = math.abs(ny - y0)
    local d_s  = math.abs(ny - y1)
    local best = math.huge
    local pick
    if in_y and d_w < EDGE and d_w < best then best = d_w; pick = "w" end
    if in_y and d_e < EDGE and d_e < best then best = d_e; pick = "e" end
    if in_x and d_n < EDGE and d_n < best then best = d_n; pick = "n" end
    if in_x and d_s < EDGE and d_s < best then best = d_s; pick = "s" end
    if pick then return pick end

    if nx > x0 and nx < x1 and ny > y0 and ny < y1 then return "move" end
    return nil
end

function M.hit_test(self, ctx, nx, ny)
    return true   -- catch-all: any click on the canvas focuses Crop
end

-- ---------------------------------------------------------------------------
-- Mouse interaction
-- ---------------------------------------------------------------------------
function M.on_mouse_down(self, ctx, mx, my, w, h)
    if ctx.refresh_state then ctx.refresh_state() end
    local s   = ctx.session
    local st  = ctx.state
    local nx, ny = mx / w, my / h
    s.handle = hit_handle(st, nx, ny) or "move"
    s.anchor_mx = mx
    s.anchor_my = my
    s.anchor_l, s.anchor_t = st.crop_l, st.crop_t
    s.anchor_r, s.anchor_b = st.crop_r, st.crop_b
    s.anchor_px, s.anchor_py = st.pos_x, st.pos_y
    s.anchor_sx, s.anchor_sy = st.stretch_x, st.stretch_y
    s.x0, s.y0, s.x1, s.y1 = visible_rect(st)
    -- Debug exposed to the side panel
    M._last_debug = string.format("hit=%s nx=%.3f ny=%.3f rect=[%.2f,%.2f,%.2f,%.2f]",
        s.handle, nx, ny, s.x0, s.y0, s.x1, s.y1)
end

function M.on_drag(self, ctx, mx, my, w, h)
    if w == 0 or h == 0 then return end
    local s    = ctx.session
    local st   = ctx.state
    local set  = ctx.set_param
    local mods = (ctx.modifiers and ctx.modifiers()) or {}
    local handle = s.handle or "move"

    -- MOVE: relative drag of the cropped image within the canvas.
    if handle == "move" then
        local dnx = (mx - s.anchor_mx) / w
        local dny = (my - s.anchor_my) / h
        -- pos_x range is [-1..1] mapped to ±half canvas, so a 1-unit
        -- normalized cursor shift = 2 in pos_x.
        local px = clamp(s.anchor_px + dnx * 2, -1, 1)
        local py = clamp(s.anchor_py + dny * 2, -1, 1)
        st.pos_x, st.pos_y = px, py
        set(M.params.pos_x, px)
        set(M.params.pos_y, py)
        return
    end

    -- RESIZE: sides move based on cursor position. Account for current
    -- pos_x/pos_y so the handle math stays consistent.
    local nx, ny = mx / w, my / h
    local crop_nx = nx - st.pos_x * 0.5
    local crop_ny = ny - st.pos_y * 0.5

    local affect_l = (handle == "nw" or handle == "sw" or handle == "w")
    local affect_r = (handle == "ne" or handle == "se" or handle == "e")
    local affect_t = (handle == "nw" or handle == "ne" or handle == "n")
    local affect_b = (handle == "sw" or handle == "se" or handle == "s")

    -- Ctrl + drag handle = CROP + SCALE-DOWN. The crop rect shrinks but
    -- the source content visible inside stays the same — i.e. the image
    -- doesn't lose anything at the edges, it just becomes smaller in the
    -- canvas. Achieved by adjusting stretch_* in lockstep with crop_*.
    if mods.ctrl then
        -- Apply the regular crop change first so the rect follows the cursor.
        local cl, ct, cr, cb = st.crop_l, st.crop_t, st.crop_r, st.crop_b
        if affect_l then cl = clamp(crop_nx,     0, 0.49) end
        if affect_r then cr = clamp(1 - crop_nx, 0, 0.49) end
        if affect_t then ct = clamp(crop_ny,     0, 0.49) end
        if affect_b then cb = clamp(1 - crop_ny, 0, 0.49) end

        if cl + cr > 0.98 then
            local excess = (cl + cr - 0.98) * 0.5
            cl = cl - excess; cr = cr - excess
        end
        if ct + cb > 0.98 then
            local excess = (ct + cb - 0.98) * 0.5
            ct = ct - excess; cb = cb - excess
        end

        -- Compensate stretch so the source area in pixels stays unchanged.
        -- new_visible / orig_visible × anchor_stretch = new_stretch
        local orig_w = 1 - s.anchor_l - s.anchor_r
        local orig_h = 1 - s.anchor_t - s.anchor_b
        local new_w  = 1 - cl - cr
        local new_h  = 1 - ct - cb
        local sx_ = orig_w > 0 and clamp(s.anchor_sx * new_w / orig_w, 0.1, 8) or s.anchor_sx
        local sy_ = orig_h > 0 and clamp(s.anchor_sy * new_h / orig_h, 0.1, 8) or s.anchor_sy

        if cl ~= st.crop_l   then st.crop_l = cl;     set(M.params.crop_l, cl) end
        if cr ~= st.crop_r   then st.crop_r = cr;     set(M.params.crop_r, cr) end
        if ct ~= st.crop_t   then st.crop_t = ct;     set(M.params.crop_t, ct) end
        if cb ~= st.crop_b   then st.crop_b = cb;     set(M.params.crop_b, cb) end
        if sx_ ~= st.stretch_x then st.stretch_x = sx_; set(M.params.stretch_x, sx_) end
        if sy_ ~= st.stretch_y then st.stretch_y = sy_; set(M.params.stretch_y, sy_) end
        return
    end

    local cl, ct, cr, cb = st.crop_l, st.crop_t, st.crop_r, st.crop_b
    if affect_l then cl = clamp(crop_nx,     0, 0.49) end
    if affect_r then cr = clamp(1 - crop_nx, 0, 0.49) end
    if affect_t then ct = clamp(crop_ny,     0, 0.49) end
    if affect_b then cb = clamp(1 - crop_ny, 0, 0.49) end

    if mods.alt then
        if affect_l then cr = cl end
        if affect_r then cl = cr end
        if affect_t then cb = ct end
        if affect_b then ct = cb end
    end

    local is_corner = (handle == "nw" or handle == "ne"
                    or handle == "sw" or handle == "se")
    if is_corner and mods.shift then
        local orig_w = (1 - s.anchor_l - s.anchor_r)
        local orig_h = (1 - s.anchor_t - s.anchor_b)
        if orig_w > 0 and orig_h > 0 then
            local ar = orig_w / orig_h
            local new_w = (1 - cl - cr)
            local new_h = (1 - ct - cb)
            local rx = math.abs(new_w - orig_w)
            local ry = math.abs(new_h - orig_h)
            if rx > ry then
                local target_h = new_w / ar
                local diff = (1 - target_h) - (ct + cb)
                if affect_t then ct = clamp(ct + diff, 0, 0.49)
                else            cb = clamp(cb + diff, 0, 0.49)
                end
            else
                local target_w = new_h * ar
                local diff = (1 - target_w) - (cl + cr)
                if affect_l then cl = clamp(cl + diff, 0, 0.49)
                else            cr = clamp(cr + diff, 0, 0.49)
                end
            end
        end
    end

    if cl + cr > 0.98 then
        local excess = (cl + cr - 0.98) * 0.5
        cl = cl - excess; cr = cr - excess
    end
    if ct + cb > 0.98 then
        local excess = (ct + cb - 0.98) * 0.5
        ct = ct - excess; cb = cb - excess
    end

    if cl ~= st.crop_l then st.crop_l = cl; set(M.params.crop_l, cl) end
    if cr ~= st.crop_r then st.crop_r = cr; set(M.params.crop_r, cr) end
    if ct ~= st.crop_t then st.crop_t = ct; set(M.params.crop_t, ct) end
    if cb ~= st.crop_b then st.crop_b = cb; set(M.params.crop_b, cb) end
end

function M.on_wheel(self, ctx, delta)
    local mods = (ctx.modifiers and ctx.modifiers()) or {}
    local mult = mods.shift and 5 or (mods.ctrl and 0.2 or 1)
    local step = -delta * 0.02 * mult
    local st   = ctx.state
    local cl   = clamp(st.crop_l + step, 0, 0.49)
    local cr   = clamp(st.crop_r + step, 0, 0.49)
    local ct   = clamp(st.crop_t + step, 0, 0.49)
    local cb   = clamp(st.crop_b + step, 0, 0.49)
    st.crop_l, st.crop_r, st.crop_t, st.crop_b = cl, cr, ct, cb
    ctx.set_param(M.params.crop_l, cl)
    ctx.set_param(M.params.crop_r, cr)
    ctx.set_param(M.params.crop_t, ct)
    ctx.set_param(M.params.crop_b, cb)
end

function M.set_frame_visible(self, ctx, visible)
    if ctx.write_ui_param then
        ctx.write_ui_param(M.params.show_frame, visible and 1 or 0)
    else
        ctx.set_param(M.params.show_frame, visible and 1 or 0)
    end
end

-- ---------------------------------------------------------------------------
-- Side panel
-- ---------------------------------------------------------------------------
function M.draw_panel(self, ctx, UI)
    local set, st = ctx.set_param, ctx.state
    local ch, v

    if M._last_debug then
        UI.SetFontCaption()
        UI.Text("DBG: " .. M._last_debug)
        UI.SetFontBody()
    end

    ch, v = UI.SliderDouble("vk_cl", "Crop left",   st.crop_l, 0, 0.49)
    if ch then st.crop_l = v; set(M.params.crop_l, v) end
    ch, v = UI.SliderDouble("vk_cr", "Crop right",  st.crop_r, 0, 0.49)
    if ch then st.crop_r = v; set(M.params.crop_r, v) end
    ch, v = UI.SliderDouble("vk_ct", "Crop top",    st.crop_t, 0, 0.49)
    if ch then st.crop_t = v; set(M.params.crop_t, v) end
    ch, v = UI.SliderDouble("vk_cb", "Crop bottom", st.crop_b, 0, 0.49)
    if ch then st.crop_b = v; set(M.params.crop_b, v) end

    ch, v = UI.SliderDouble("vk_px", "Position X", st.pos_x, -1, 1)
    if ch then st.pos_x = v; set(M.params.pos_x, v) end
    ch, v = UI.SliderDouble("vk_py", "Position Y", st.pos_y, -1, 1)
    if ch then st.pos_y = v; set(M.params.pos_y, v) end

    ch, v = UI.SliderDouble("vk_sx", "Stretch X", st.stretch_x, 0.1, 8)
    if ch then st.stretch_x = v; set(M.params.stretch_x, v) end
    ch, v = UI.SliderDouble("vk_sy", "Stretch Y", st.stretch_y, 0.1, 8)
    if ch then st.stretch_y = v; set(M.params.stretch_y, v) end

    ch, v = UI.SliderDouble("vk_rot", "Rotate", st.rot, -180, 180)
    if ch then st.rot = v; set(M.params.rot, v) end

    local flip_items = { "None", "H", "V", "Both" }
    ch, v = UI.RadioGroup("vk_flip", "Flip", math.floor(st.flip) + 1,
                          flip_items, { horizontal = true })
    if ch then st.flip = v - 1; set(M.params.flip, v - 1) end

    if UI.Button("vk_reset", "Reset", { width = -1 }) then
        st.crop_l, st.crop_r, st.crop_t, st.crop_b = 0, 0, 0, 0
        st.pos_x, st.pos_y = 0, 0
        st.stretch_x, st.stretch_y = 1, 1
        st.rot, st.flip = 0, 0
        set(M.params.crop_l, 0); set(M.params.crop_r, 0)
        set(M.params.crop_t, 0); set(M.params.crop_b, 0)
        set(M.params.pos_x, 0);  set(M.params.pos_y, 0)
        set(M.params.stretch_x, 1); set(M.params.stretch_y, 1)
        set(M.params.rot, 0); set(M.params.flip, 0)
    end
end

return M
