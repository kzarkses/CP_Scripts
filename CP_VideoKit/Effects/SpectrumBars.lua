-- CP_VideoKit / Effect: Spectrum Bars

local M = {
    id     = "spectrum_bars",
    name   = "Spectrum Bars",
    tag    = "CP_VideoKit_SpectrumBars",
    preset = "SpectrumBars.eel",
}

M.params = {
    base_slot  = 0,
    n_bars     = 1,
    height_pct = 2,
    opacity    = 3,
    color_r    = 4,
    color_g    = 5,
    color_b    = 6,
    y_anchor   = 7,
    show_frame = 8,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        base_slot  = get(Core, take, fx_idx, M.params.base_slot,  0),
        n_bars     = get(Core, take, fx_idx, M.params.n_bars,     8),
        height_pct = get(Core, take, fx_idx, M.params.height_pct, 30),
        opacity    = get(Core, take, fx_idx, M.params.opacity,    0.7),
        color_r    = get(Core, take, fx_idx, M.params.color_r,    0.2),
        color_g    = get(Core, take, fx_idx, M.params.color_g,    0.9),
        color_b    = get(Core, take, fx_idx, M.params.color_b,    1),
        y_anchor   = get(Core, take, fx_idx, M.params.y_anchor,   1),
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
    UI.Text("Reads N consecutive gmem slots starting at base_slot.")
    UI.Text("Set up multiple CP_AudioReactive.jsfx with different sources")
    UI.Text("on slots base..base+N-1 (e.g. low/mid/high band per slot).")
    UI.SetFontBody()

    ch, v = UI.SliderInt("sb_base", "Base slot",
                         math.floor(st.base_slot), 0, 24)
    if ch then st.base_slot = v; set(M.params.base_slot, v) end
    ch, v = UI.SliderInt("sb_n", "Number of bars",
                         math.floor(st.n_bars), 1, 16)
    if ch then st.n_bars = v; set(M.params.n_bars, v) end
    ch, v = UI.SliderDouble("sb_h", "Height (%)", st.height_pct, 0, 100)
    if ch then st.height_pct = v; set(M.params.height_pct, v) end
    ch, v = UI.SliderDouble("sb_op", "Opacity", st.opacity, 0, 1)
    if ch then st.opacity = v; set(M.params.opacity, v) end
    ch, v = UI.SliderDouble("sb_r", "Color R", st.color_r, 0, 1)
    if ch then st.color_r = v; set(M.params.color_r, v) end
    ch, v = UI.SliderDouble("sb_g", "Color G", st.color_g, 0, 1)
    if ch then st.color_g = v; set(M.params.color_g, v) end
    ch, v = UI.SliderDouble("sb_b", "Color B", st.color_b, 0, 1)
    if ch then st.color_b = v; set(M.params.color_b, v) end
    local items = { "Top", "Bottom" }
    ch, v = UI.RadioGroup("sb_anchor", "Anchor",
        math.floor(st.y_anchor) + 1, items, { horizontal = true })
    if ch then st.y_anchor = v - 1; set(M.params.y_anchor, v - 1) end
end

return M
