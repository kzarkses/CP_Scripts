-- CP_VideoKit / Effect: Frame Freeze

local M = {
    id     = "frame_freeze",
    name   = "Frame Freeze",
    tag    = "CP_VideoKit_FrameFreeze",
    preset = "FrameFreeze.eel",
}

M.params = {
    freeze     = 0,
    show_frame = 1,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        freeze = get(Core, take, fx_idx, M.params.freeze, 0),
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
    local toggled, new_state = UI.ToggleButton("ff_freeze",
        st.freeze > 0.5 and "FROZEN" or "Freeze", st.freeze > 0.5,
        { width = -1 })
    if toggled then
        st.freeze = new_state and 1 or 0
        set(M.params.freeze, st.freeze)
    end
    UI.SetFontCaption()
    UI.Text("Freeze captures the current frame. Toggle off to resume.")
    UI.SetFontBody()
end

return M
