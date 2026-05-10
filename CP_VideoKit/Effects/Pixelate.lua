-- CP_VideoKit / Effect: Pixelate

local M = {
    id     = "pixelate",
    name   = "Pixelate",
    tag    = "CP_VideoKit_Pixelate",
    preset = "Pixelate.eel",
}

M.params = {
    size       = 0,
    show_frame = 1,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        size = get(Core, take, fx_idx, M.params.size, 16),
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

function M.on_wheel(self, ctx, delta)
    local mods = (ctx.modifiers and ctx.modifiers()) or {}
    local mult = mods.shift and 5 or (mods.ctrl and 0.2 or 1)
    local s = ctx.state.size + delta * mult
    if s < 1 then s = 1 elseif s > 200 then s = 200 end
    ctx.state.size = s
    ctx.set_param(M.params.size, s)
end

function M.draw_panel(self, ctx, UI)
    local set, st = ctx.set_param, ctx.state
    local ch, v = UI.SliderInt("px_size", "Pixel size",
                               math.floor(st.size), 1, 200)
    if ch then st.size = v; set(M.params.size, v) end
end

return M
