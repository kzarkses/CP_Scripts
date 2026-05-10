-- CP_VideoKit / Effect: Picture-in-Picture
-- Drag interactions:
--   * inside        → move (px, py)
--   * corner        → resize uniform (locked aspect) from opposite corner
--   * Shift + corner→ resize free (psize_x/psize_y independent)
--   * edge          → resize one axis from opposite edge
--   * Alt + corner  → resize from center (both opposite sides move)

local M = {
    id     = "pip",
    name   = "Picture-in-Picture",
    tag    = "CP_VideoKit_PiP",
    preset = "PiP.eel",
}

M.params = {
    src_track  = 0,
    px         = 1,
    py         = 2,
    psize_x    = 3,
    psize_y    = 4,
    opacity    = 5,
    border     = 6,
    show_frame = 7,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    local v = Core.get_param(take, fx, idx)
    return v or def
end

function M.read_state(Core, take, fx_idx)
    return {
        src_track = get(Core, take, fx_idx, M.params.src_track, 0),
        px        = get(Core, take, fx_idx, M.params.px,        0.75),
        py        = get(Core, take, fx_idx, M.params.py,        0.25),
        psize_x   = get(Core, take, fx_idx, M.params.psize_x,   0.3),
        psize_y   = get(Core, take, fx_idx, M.params.psize_y,   0.3),
        opacity   = get(Core, take, fx_idx, M.params.opacity,   1),
        border    = get(Core, take, fx_idx, M.params.border,    4),
    }
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- ---------------------------------------------------------------------------
-- Geometry helpers — compute PiP rect in normalized canvas space.
-- The EEL preset uses base = min(project_w, project_h); since we don't
-- know the canvas pixel size here, we work in normalized [0..1] units
-- assuming a square base, then map back. The host normalizes mouse coords
-- by client width/height which differ from canvas, so we accept a small
-- inaccuracy on non-square outputs — drag still feels natural.
-- ---------------------------------------------------------------------------
local function rect(st)
    local hw = st.psize_x * 0.5
    local hh = st.psize_y * 0.5
    return st.px - hw, st.py - hh, st.px + hw, st.py + hh
end

local HANDLE_PX = 0.04  -- normalized handle radius, ≈ 4% of canvas

local function hit_handle(st, nx, ny)
    local x0, y0, x1, y1 = rect(st)
    local h = HANDLE_PX
    -- Corners
    if math.abs(nx - x0) < h and math.abs(ny - y0) < h then return "nw" end
    if math.abs(nx - x1) < h and math.abs(ny - y0) < h then return "ne" end
    if math.abs(nx - x0) < h and math.abs(ny - y1) < h then return "sw" end
    if math.abs(nx - x1) < h and math.abs(ny - y1) < h then return "se" end
    -- Edges (mid-side, slightly tighter zone)
    local me = h * 0.7
    if math.abs(ny - y0) < me and nx > x0 + h and nx < x1 - h then return "n" end
    if math.abs(ny - y1) < me and nx > x0 + h and nx < x1 - h then return "s" end
    if math.abs(nx - x0) < me and ny > y0 + h and ny < y1 - h then return "w" end
    if math.abs(nx - x1) < me and ny > y0 + h and ny < y1 - h then return "e" end
    -- Inside → move
    if nx > x0 and nx < x1 and ny > y0 and ny < y1 then return "move" end
    return nil
end

function M.hit_test(self, ctx, nx, ny)
    return hit_handle(ctx.state, nx, ny) ~= nil
end

-- ---------------------------------------------------------------------------
-- Mouse interaction
-- ---------------------------------------------------------------------------
function M.on_mouse_down(self, ctx, mx, my, w, h)
    if ctx.refresh_state then ctx.refresh_state() end
    local s  = ctx.session
    local st = ctx.state
    local nx = mx / w
    local ny = my / h
    s.handle      = hit_handle(st, nx, ny) or "move"
    s.anchor_mx   = mx
    s.anchor_my   = my
    s.anchor_px   = st.px
    s.anchor_py   = st.py
    s.anchor_sx   = st.psize_x
    s.anchor_sy   = st.psize_y
    -- Snapshot rect bounds for resize anchoring
    s.x0, s.y0, s.x1, s.y1 = rect(st)
end

function M.on_drag(self, ctx, mx, my, w, h)
    if w == 0 or h == 0 then return end
    local s   = ctx.session
    local st  = ctx.state
    local set = ctx.set_param
    local mods = (ctx.modifiers and ctx.modifiers()) or {}
    local nx, ny = mx / w, my / h
    local handle = s.handle or "move"

    if handle == "move" then
        -- Drag-from-anchor model: move the PiP by the cursor delta.
        local dx_n = (mx - s.anchor_mx) / w
        local dy_n = (my - s.anchor_my) / h
        st.px = clamp(s.anchor_px + dx_n, 0, 1)
        st.py = clamp(s.anchor_py + dy_n, 0, 1)
        set(M.params.px, st.px)
        set(M.params.py, st.py)
        return
    end

    -- Resize: compute new rect bounds based on which handle is dragged.
    -- The opposite corner/edge stays fixed (or center stays fixed if Alt).
    local x0, y0, x1, y1 = s.x0, s.y0, s.x1, s.y1
    local affect_l = (handle == "nw" or handle == "sw" or handle == "w")
    local affect_r = (handle == "ne" or handle == "se" or handle == "e")
    local affect_t = (handle == "nw" or handle == "ne" or handle == "n")
    local affect_b = (handle == "sw" or handle == "se" or handle == "s")

    if affect_l then x0 = clamp(nx, 0, x1 - 0.025) end
    if affect_r then x1 = clamp(nx, x0 + 0.025, 1) end
    if affect_t then y0 = clamp(ny, 0, y1 - 0.025) end
    if affect_b then y1 = clamp(ny, y0 + 0.025, 1) end

    local new_w = x1 - x0
    local new_h = y1 - y0

    -- Aspect lock for corners (no Shift). Edges stay one-axis regardless.
    local is_corner = (handle == "nw" or handle == "ne"
                    or handle == "sw" or handle == "se")
    if is_corner and not mods.shift then
        local ar = s.anchor_sx / s.anchor_sy
        if ar == 0 then ar = 1 end
        -- Drive one axis from the larger relative change, scale the other.
        local rx = new_w / s.anchor_sx
        local ry = new_h / s.anchor_sy
        if math.abs(rx - 1) > math.abs(ry - 1) then
            new_h = new_w / ar
            -- Re-anchor on the fixed edge:
            if affect_t then y0 = y1 - new_h else y1 = y0 + new_h end
        else
            new_w = new_h * ar
            if affect_l then x0 = x1 - new_w else x1 = x0 + new_w end
        end
    end

    if mods.alt then
        -- Mirror around the anchor center (resize from center).
        local cx = (s.x0 + s.x1) * 0.5
        local cy = (s.y0 + s.y1) * 0.5
        local hw = math.max(math.abs(nx - cx), 0.025)
        local hh = math.max(math.abs(ny - cy), 0.025)
        if is_corner and not mods.shift then
            local ar = s.anchor_sx / s.anchor_sy
            if hw / hh > ar then hh = hw / ar else hw = hh * ar end
        end
        x0 = clamp(cx - hw, 0, 1); x1 = clamp(cx + hw, 0, 1)
        y0 = clamp(cy - hh, 0, 1); y1 = clamp(cy + hh, 0, 1)
        new_w = x1 - x0
        new_h = y1 - y0
    end

    -- Commit
    st.psize_x = clamp(new_w, 0.05, 1)
    st.psize_y = clamp(new_h, 0.05, 1)
    st.px      = clamp((x0 + x1) * 0.5, 0, 1)
    st.py      = clamp((y0 + y1) * 0.5, 0, 1)
    set(M.params.psize_x, st.psize_x)
    set(M.params.psize_y, st.psize_y)
    set(M.params.px, st.px)
    set(M.params.py, st.py)
end

function M.on_wheel(self, ctx, delta)
    local mods  = (ctx.modifiers and ctx.modifiers()) or {}
    local mult  = mods.shift and 5 or (mods.ctrl and 0.2 or 1)
    local step  = 1 + delta * 0.1 * mult
    local st    = ctx.state
    st.psize_x  = clamp(st.psize_x * step, 0.05, 1)
    st.psize_y  = clamp(st.psize_y * step, 0.05, 1)
    ctx.set_param(M.params.psize_x, st.psize_x)
    ctx.set_param(M.params.psize_y, st.psize_y)
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

    UI.SetFontCaption()
    UI.Text("Source: video item on a track ABOVE this one.")
    UI.SetFontBody()

    ch, v = UI.SliderInt("vk_src", "Source track (above)",
                         math.floor(st.src_track), 0, 8)
    if ch then st.src_track = v; set(M.params.src_track, v) end

    ch, v = UI.SliderDouble("vk_px", "PiP center X", st.px, 0, 1)
    if ch then st.px = v; set(M.params.px, v) end

    ch, v = UI.SliderDouble("vk_py", "PiP center Y", st.py, 0, 1)
    if ch then st.py = v; set(M.params.py, v) end

    ch, v = UI.SliderDouble("vk_sx", "Width", st.psize_x, 0.05, 1)
    if ch then st.psize_x = v; set(M.params.psize_x, v) end

    ch, v = UI.SliderDouble("vk_sy", "Height", st.psize_y, 0.05, 1)
    if ch then st.psize_y = v; set(M.params.psize_y, v) end

    ch, v = UI.SliderDouble("vk_op", "Opacity", st.opacity, 0, 1)
    if ch then st.opacity = v; set(M.params.opacity, v) end

    ch, v = UI.SliderInt("vk_border", "Border (px)",
                         math.floor(st.border), 0, 32)
    if ch then st.border = v; set(M.params.border, v) end
end

return M
