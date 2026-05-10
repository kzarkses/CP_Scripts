-- CP_VideoKit / Effect: Scanlines

local M = {
    id     = "scanlines",
    name   = "Scanlines",
    tag    = "CP_VideoKit_Scanlines",
    preset = "Scanlines.eel",
}

M.params = {
    spacing    = 0,
    thickness  = 1,
    darkness   = 2,
    orient     = 3,
    show_frame = 4,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        spacing   = get(Core, take, fx_idx, M.params.spacing,   4),
        thickness = get(Core, take, fx_idx, M.params.thickness, 1),
        darkness  = get(Core, take, fx_idx, M.params.darkness,  0.5),
        orient    = get(Core, take, fx_idx, M.params.orient,    0),
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
    ch, v = UI.SliderInt("sl_sp", "Spacing", math.floor(st.spacing), 1, 40)
    if ch then st.spacing = v; set(M.params.spacing, v) end
    ch, v = UI.SliderInt("sl_th", "Thickness", math.floor(st.thickness), 1, 20)
    if ch then st.thickness = v; set(M.params.thickness, v) end
    ch, v = UI.SliderDouble("sl_dk", "Darkness", st.darkness, 0, 1)
    if ch then st.darkness = v; set(M.params.darkness, v) end
    local items = { "Horizontal", "Vertical" }
    ch, v = UI.RadioGroup("sl_or", "Orientation",
                          math.floor(st.orient) + 1, items)
    if ch then st.orient = v - 1; set(M.params.orient, v - 1) end
end

return M
