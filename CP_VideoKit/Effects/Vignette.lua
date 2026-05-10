-- CP_VideoKit / Effect: Vignette

local M = {
    id     = "vignette",
    name   = "Vignette",
    tag    = "CP_VideoKit_Vignette",
    preset = "Vignette.eel",
}

M.params = {
    size       = 0,
    softness   = 1,
    strength   = 2,
    cx         = 3,
    cy         = 4,
    show_frame = 5,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        size     = get(Core, take, fx_idx, M.params.size,     0.7),
        softness = get(Core, take, fx_idx, M.params.softness, 0.4),
        strength = get(Core, take, fx_idx, M.params.strength, 1),
        cx       = get(Core, take, fx_idx, M.params.cx,       0.5),
        cy       = get(Core, take, fx_idx, M.params.cy,       0.5),
    }
end

function M.hit_test(self, ctx, nx, ny) return false end

function M.set_frame_visible(self, ctx, visible)
    if ctx.write_ui_param then
        ctx.write_ui_param(M.params.show_frame, visible and 1 or 0)
    else
        ctx.set_param(M.params.show_frame, visible and 1 or 0)
    end
end

function M.draw_panel(self, ctx, UI)
    local set, st = ctx.set_param, ctx.state
    local ch, v
    ch, v = UI.SliderDouble("vg_size", "Size", st.size, 0, 1)
    if ch then st.size = v; set(M.params.size, v) end
    ch, v = UI.SliderDouble("vg_soft", "Softness", st.softness, 0, 1)
    if ch then st.softness = v; set(M.params.softness, v) end
    ch, v = UI.SliderDouble("vg_str", "Strength", st.strength, 0, 1)
    if ch then st.strength = v; set(M.params.strength, v) end
    ch, v = UI.SliderDouble("vg_cx", "Center X", st.cx, 0, 1)
    if ch then st.cx = v; set(M.params.cx, v) end
    ch, v = UI.SliderDouble("vg_cy", "Center Y", st.cy, 0, 1)
    if ch then st.cy = v; set(M.params.cy, v) end
end

return M
