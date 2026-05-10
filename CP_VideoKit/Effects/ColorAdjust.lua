-- CP_VideoKit / Effect: Color Adjust

local M = {
    id     = "color_adjust",
    name   = "Color Adjust",
    tag    = "CP_VideoKit_ColorAdjust",
    preset = "ColorAdjust.eel",
}

M.params = {
    brightness = 0,
    contrast   = 1,
    saturation = 2,
    hue        = 3,
    gamma      = 4,
    show_frame = 5,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        brightness = get(Core, take, fx_idx, M.params.brightness, 0),
        contrast   = get(Core, take, fx_idx, M.params.contrast,   1),
        saturation = get(Core, take, fx_idx, M.params.saturation, 1),
        hue        = get(Core, take, fx_idx, M.params.hue,        0),
        gamma      = get(Core, take, fx_idx, M.params.gamma,      1),
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
    ch, v = UI.SliderDouble("ca_b", "Brightness", st.brightness, -1, 1)
    if ch then st.brightness = v; set(M.params.brightness, v) end
    ch, v = UI.SliderDouble("ca_c", "Contrast", st.contrast, 0, 4)
    if ch then st.contrast = v; set(M.params.contrast, v) end
    ch, v = UI.SliderDouble("ca_s", "Saturation", st.saturation, 0, 3)
    if ch then st.saturation = v; set(M.params.saturation, v) end
    ch, v = UI.SliderDouble("ca_h", "Hue rotate", st.hue, -180, 180)
    if ch then st.hue = v; set(M.params.hue, v) end
    ch, v = UI.SliderDouble("ca_g", "Gamma", st.gamma, 0.1, 4)
    if ch then st.gamma = v; set(M.params.gamma, v) end

    if UI.Button("ca_reset", "Reset", { width = -1 }) then
        st.brightness, st.contrast, st.saturation = 0, 1, 1
        st.hue, st.gamma = 0, 1
        set(M.params.brightness, 0)
        set(M.params.contrast, 1)
        set(M.params.saturation, 1)
        set(M.params.hue, 0)
        set(M.params.gamma, 1)
    end
end

return M
