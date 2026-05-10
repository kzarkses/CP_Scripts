-- CP_VideoKit / Effect: Audio Zoom Punch

local M = {
    id     = "audio_zoom_punch",
    name   = "Audio Zoom Punch",
    tag    = "CP_VideoKit_AudioZoomPunch",
    preset = "AudioZoomPunch.eel",
}

M.params = {
    slot       = 0,
    amount     = 1,
    base_zoom  = 2,
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
        slot      = get(Core, take, fx_idx, M.params.slot,      0),
        amount    = get(Core, take, fx_idx, M.params.amount,    0.5),
        base_zoom = get(Core, take, fx_idx, M.params.base_zoom, 1),
        cx        = get(Core, take, fx_idx, M.params.cx,        0.5),
        cy        = get(Core, take, fx_idx, M.params.cy,        0.5),
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
    UI.SetFontCaption()
    UI.Text("Set the gmem slot to match an instance of CP_AudioReactive.jsfx")
    UI.Text("on the audio track of your choice.")
    UI.SetFontBody()
    local ch, v
    ch, v = UI.SliderInt("azp_slot", "gmem slot", math.floor(st.slot), 0, 31)
    if ch then st.slot = v; set(M.params.slot, v) end
    ch, v = UI.SliderDouble("azp_amount", "Punch amount", st.amount, 0, 2)
    if ch then st.amount = v; set(M.params.amount, v) end
    ch, v = UI.SliderDouble("azp_base", "Base zoom", st.base_zoom, 1, 4)
    if ch then st.base_zoom = v; set(M.params.base_zoom, v) end
    ch, v = UI.SliderDouble("azp_cx", "Center X", st.cx, 0, 1)
    if ch then st.cx = v; set(M.params.cx, v) end
    ch, v = UI.SliderDouble("azp_cy", "Center Y", st.cy, 0, 1)
    if ch then st.cy = v; set(M.params.cy, v) end
end

return M
