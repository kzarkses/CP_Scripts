-- CP_VideoKit / Effect: RGB Shift (chromatic aberration)

local M = {
    id     = "rgb_shift",
    name   = "RGB Shift",
    tag    = "CP_VideoKit_RGBShift",
    preset = "RGBShift.eel",
}

M.params = {
    r_dx = 0, r_dy = 1,
    g_dx = 2, g_dy = 3,
    b_dx = 4, b_dy = 5,
    show_frame = 6,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        r_dx = get(Core, take, fx_idx, M.params.r_dx, 0),
        r_dy = get(Core, take, fx_idx, M.params.r_dy, 0),
        g_dx = get(Core, take, fx_idx, M.params.g_dx, 0),
        g_dy = get(Core, take, fx_idx, M.params.g_dy, 0),
        b_dx = get(Core, take, fx_idx, M.params.b_dx, 0),
        b_dy = get(Core, take, fx_idx, M.params.b_dy, 0),
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
    UI.SetFontH2(); UI.Text("Red"); UI.SetFontBody()
    ch, v = UI.SliderInt("rgb_rx", "R offset X", math.floor(st.r_dx), -100, 100)
    if ch then st.r_dx = v; set(M.params.r_dx, v) end
    ch, v = UI.SliderInt("rgb_ry", "R offset Y", math.floor(st.r_dy), -100, 100)
    if ch then st.r_dy = v; set(M.params.r_dy, v) end

    UI.SetFontH2(); UI.Text("Green"); UI.SetFontBody()
    ch, v = UI.SliderInt("rgb_gx", "G offset X", math.floor(st.g_dx), -100, 100)
    if ch then st.g_dx = v; set(M.params.g_dx, v) end
    ch, v = UI.SliderInt("rgb_gy", "G offset Y", math.floor(st.g_dy), -100, 100)
    if ch then st.g_dy = v; set(M.params.g_dy, v) end

    UI.SetFontH2(); UI.Text("Blue"); UI.SetFontBody()
    ch, v = UI.SliderInt("rgb_bx", "B offset X", math.floor(st.b_dx), -100, 100)
    if ch then st.b_dx = v; set(M.params.b_dx, v) end
    ch, v = UI.SliderInt("rgb_by", "B offset Y", math.floor(st.b_dy), -100, 100)
    if ch then st.b_dy = v; set(M.params.b_dy, v) end

    if UI.Button("rgb_reset", "Reset", { width = -1 }) then
        for k, p in pairs(M.params) do
            if k ~= "show_frame" then set(p, 0); st[k] = 0 end
        end
    end
end

return M
