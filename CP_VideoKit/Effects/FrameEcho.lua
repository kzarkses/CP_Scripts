-- CP_VideoKit / Effect: Frame Echo

local M = {
    id     = "frame_echo",
    name   = "Frame Echo",
    tag    = "CP_VideoKit_FrameEcho",
    preset = "FrameEcho.eel",
}

M.params = {
    decay      = 0,
    offset_x   = 1,
    offset_y   = 2,
    show_frame = 3,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        decay    = get(Core, take, fx_idx, M.params.decay,    0.85),
        offset_x = get(Core, take, fx_idx, M.params.offset_x, 0),
        offset_y = get(Core, take, fx_idx, M.params.offset_y, 0),
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
    ch, v = UI.SliderDouble("fe_decay", "Decay", st.decay, 0, 1)
    if ch then st.decay = v; set(M.params.decay, v) end
    ch, v = UI.SliderDouble("fe_dx", "Drift X (px)", st.offset_x, -20, 20)
    if ch then st.offset_x = v; set(M.params.offset_x, v) end
    ch, v = UI.SliderDouble("fe_dy", "Drift Y (px)", st.offset_y, -20, 20)
    if ch then st.offset_y = v; set(M.params.offset_y, v) end
end

return M
