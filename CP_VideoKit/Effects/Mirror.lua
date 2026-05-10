-- CP_VideoKit / Effect: Mirror

local M = {
    id     = "mirror",
    name   = "Mirror",
    tag    = "CP_VideoKit_Mirror",
    preset = "Mirror.eel",
}

M.params = {
    mode       = 0,
    axis       = 1,
    branches   = 2,
    show_frame = 3,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        mode     = get(Core, take, fx_idx, M.params.mode,     0),
        axis     = get(Core, take, fx_idx, M.params.axis,     0.5),
        branches = get(Core, take, fx_idx, M.params.branches, 6),
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
    local mode_items = { "None", "Horizontal", "Vertical", "Quadrant", "Kaleido" }
    ch, v = UI.RadioGroup("mir_mode", "Mode", math.floor(st.mode) + 1, mode_items)
    if ch then st.mode = v - 1; set(M.params.mode, v - 1) end

    if st.mode == 1 or st.mode == 2 then
        ch, v = UI.SliderDouble("mir_axis", "Axis", st.axis, 0, 1)
        if ch then st.axis = v; set(M.params.axis, v) end
    end
    if st.mode == 4 then
        ch, v = UI.SliderInt("mir_n", "Branches",
                             math.floor(st.branches), 2, 16)
        if ch then st.branches = v; set(M.params.branches, v) end
    end
end

return M
