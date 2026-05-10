-- CP_VideoKit / Effect: Strobe

local M = {
    id     = "strobe",
    name   = "Strobe",
    tag    = "CP_VideoKit_Strobe",
    preset = "Strobe.eel",
}

M.params = {
    rate       = 0,
    duty       = 1,
    sync_qn    = 2,
    qn_div     = 3,
    flash_r    = 4,
    flash_g    = 5,
    flash_b    = 6,
    show_frame = 7,
}

local function get(Core, take, fx, idx, def)
    if not take or not fx then return def end
    return Core.get_param(take, fx, idx) or def
end

function M.read_state(Core, take, fx_idx)
    return {
        rate    = get(Core, take, fx_idx, M.params.rate,    8),
        duty    = get(Core, take, fx_idx, M.params.duty,    0.5),
        sync_qn = get(Core, take, fx_idx, M.params.sync_qn, 0),
        qn_div  = get(Core, take, fx_idx, M.params.qn_div,  0.5),
        flash_r = get(Core, take, fx_idx, M.params.flash_r, 0),
        flash_g = get(Core, take, fx_idx, M.params.flash_g, 0),
        flash_b = get(Core, take, fx_idx, M.params.flash_b, 0),
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

    local toggled, sync = UI.ToggleButton("st_sync",
        st.sync_qn > 0.5 and "Sync to tempo" or "Free rate",
        st.sync_qn > 0.5, { width = -1 })
    if toggled then
        st.sync_qn = sync and 1 or 0
        set(M.params.sync_qn, st.sync_qn)
    end

    if st.sync_qn > 0.5 then
        ch, v = UI.SliderDouble("st_qn", "Beats per cycle",
                                st.qn_div, 0.0625, 8)
        if ch then st.qn_div = v; set(M.params.qn_div, v) end
    else
        ch, v = UI.SliderDouble("st_rate", "Rate (Hz)", st.rate, 0.1, 30)
        if ch then st.rate = v; set(M.params.rate, v) end
    end

    ch, v = UI.SliderDouble("st_duty", "Duty (visible ratio)",
                            st.duty, 0, 1)
    if ch then st.duty = v; set(M.params.duty, v) end

    UI.SetFontCaption(); UI.Text("Flash color"); UI.SetFontBody()
    ch, v = UI.SliderDouble("st_fr", "R", st.flash_r, 0, 1)
    if ch then st.flash_r = v; set(M.params.flash_r, v) end
    ch, v = UI.SliderDouble("st_fg", "G", st.flash_g, 0, 1)
    if ch then st.flash_g = v; set(M.params.flash_g, v) end
    ch, v = UI.SliderDouble("st_fb", "B", st.flash_b, 0, 1)
    if ch then st.flash_b = v; set(M.params.flash_b, v) end
end

return M
