-- CP_VideoKit / Effect: Audio Shake

local M = {
    id     = "audio_shake",
    name   = "Audio Shake",
    tag    = "CP_VideoKit_AudioShake",
    preset = "AudioShake.eel",
}

M.params = {
    slot       = 0,
    amplitude  = 1,
    rotation   = 2,
    show_frame = 3,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        slot      = get(Core, take, fx_idx, M.params.slot,      0),
        amplitude = get(Core, take, fx_idx, M.params.amplitude, 30),
        rotation  = get(Core, take, fx_idx, M.params.rotation,  0),
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
    UI.SetFontCaption()
    UI.Text("Match slot to a CP_AudioReactive.jsfx instance.")
    UI.SetFontBody()
    ch, v = UI.SliderInt("as_slot", "gmem slot", math.floor(st.slot), 0, 31)
    if ch then st.slot = v; set(M.params.slot, v) end
    ch, v = UI.SliderDouble("as_amp", "Max shake (px)", st.amplitude, 0, 200)
    if ch then st.amplitude = v; set(M.params.amplitude, v) end
    ch, v = UI.SliderDouble("as_rot", "Max rotation (deg)", st.rotation, 0, 30)
    if ch then st.rotation = v; set(M.params.rotation, v) end
end

return M
