-- CP_VideoKit / Effect: Audio Strobe

local M = {
    id     = "audio_strobe",
    name   = "Audio Strobe",
    tag    = "CP_VideoKit_AudioStrobe",
    preset = "AudioStrobe.eel",
}

M.params = {
    slot       = 0,
    threshold  = 1,
    hold_ms    = 2,
    flash_r    = 3,
    flash_g    = 4,
    flash_b    = 5,
    show_frame = 6,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        slot      = get(Core, take, fx_idx, M.params.slot,      0),
        threshold = get(Core, take, fx_idx, M.params.threshold, 0.5),
        hold_ms   = get(Core, take, fx_idx, M.params.hold_ms,   60),
        flash_r   = get(Core, take, fx_idx, M.params.flash_r,   1),
        flash_g   = get(Core, take, fx_idx, M.params.flash_g,   1),
        flash_b   = get(Core, take, fx_idx, M.params.flash_b,   1),
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
    ch, v = UI.SliderInt("ats_slot", "gmem slot", math.floor(st.slot), 0, 31)
    if ch then st.slot = v; set(M.params.slot, v) end
    ch, v = UI.SliderDouble("ats_th", "Trigger threshold", st.threshold, 0, 1)
    if ch then st.threshold = v; set(M.params.threshold, v) end
    ch, v = UI.SliderDouble("ats_hold", "Hold (ms)", st.hold_ms, 0, 500)
    if ch then st.hold_ms = v; set(M.params.hold_ms, v) end
    ch, v = UI.SliderDouble("ats_fr", "Flash R", st.flash_r, 0, 1)
    if ch then st.flash_r = v; set(M.params.flash_r, v) end
    ch, v = UI.SliderDouble("ats_fg", "Flash G", st.flash_g, 0, 1)
    if ch then st.flash_g = v; set(M.params.flash_g, v) end
    ch, v = UI.SliderDouble("ats_fb", "Flash B", st.flash_b, 0, 1)
    if ch then st.flash_b = v; set(M.params.flash_b, v) end
end

return M
