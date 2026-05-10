-- CP_VideoKit / Effect: Invert

local M = {
    id     = "invert",
    name   = "Invert",
    tag    = "CP_VideoKit_Invert",
    preset = "Invert.eel",
}

M.params = {
    mode       = 0,
    amount     = 1,
    show_frame = 2,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        mode   = get(Core, take, fx_idx, M.params.mode,   1),
        amount = get(Core, take, fx_idx, M.params.amount, 1),
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
    local items = { "None", "Invert RGB", "Invert luma" }
    ch, v = UI.RadioGroup("inv_mode", "Mode", math.floor(st.mode) + 1, items)
    if ch then st.mode = v - 1; set(M.params.mode, v - 1) end
    ch, v = UI.SliderDouble("inv_amt", "Amount", st.amount, 0, 1)
    if ch then st.amount = v; set(M.params.amount, v) end
end

return M
