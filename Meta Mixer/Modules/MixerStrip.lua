-- MixerStrip.lua — Unified vertical strip for masters and tracks
local MixerStrip = {}
local r, C, H, W, ctx

function MixerStrip.init(reaper_api, constants, helpers, widgets, imgui_ctx)
    r = reaper_api
    C = constants
    H = helpers
    W = widgets
    ctx = imgui_ctx
end

-- ============================================================================
-- DRAW STRIP — single vertical column (master or track)
-- ============================================================================
function MixerStrip.Draw(opts)
    -- opts: id, name, vol, pan, mute, solo, peak_l, peak_r, color,
    --       fx, sends, is_master, is_active, track_ptr, proj_ptr,
    --       is_playing, play_pos, cursor_pos

    r.ImGui_BeginGroup(ctx)

    -- === NAME ===
    local name = opts.name or "?"
    if #name > 9 then name = name:sub(1, 8) .. "." end

    -- Color indicator for tracks
    if opts.color and opts.color ~= 0 then
        local cr = ((opts.color >> 0) & 0xFF) / 255
        local cg = ((opts.color >> 8) & 0xFF) / 255
        local cb = ((opts.color >> 16) & 0xFF) / 255
        local col32 = r.ImGui_ColorConvertDouble4ToU32(cr, cg, cb, 1.0)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col32)
    end

    if opts.is_master then
        local clicked = r.ImGui_Selectable(ctx, name .. "##n" .. opts.id, opts.is_active, 0, C.STRIP_W, 0)
        if clicked and opts.proj_ptr then
            r.SelectProjectInstance(opts.proj_ptr)
        end
    else
        r.ImGui_Text(ctx, name)
    end

    if opts.color and opts.color ~= 0 then r.ImGui_PopStyleColor(ctx) end

    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, opts.name or "")
    end

    -- === TRANSPORT (masters only) ===
    if opts.is_master and opts.proj_ptr then
        local is_playing = opts.is_playing
        local play_col = is_playing and C.COL_PLAY or nil
        if play_col then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), play_col) end
        local btn_w = math.floor((C.STRIP_W - 4) / 2)
        if r.ImGui_Button(ctx, (is_playing and "||" or ">") .. "##tp" .. opts.id, btn_w, 0) then
            if is_playing then r.OnPauseButtonEx(opts.proj_ptr)
            else r.OnPlayButtonEx(opts.proj_ptr) end
        end
        if play_col then r.ImGui_PopStyleColor(ctx) end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "X##ts" .. opts.id, btn_w, 0) then
            r.OnStopButtonEx(opts.proj_ptr)
        end

        -- Time
        local pos = is_playing and opts.play_pos or opts.cursor_pos
        if pos then
            local t = H.FormatTime(pos)
            local tw = r.ImGui_CalcTextSize(ctx, t)
            r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + (C.STRIP_W - tw) / 2)
            r.ImGui_TextDisabled(ctx, t)
        end
    end

    -- === FX CHAIN ===
    if opts.fx and #opts.fx > 0 then
        for _, fx in ipairs(opts.fx) do
            local col = fx.enabled and C.COL_FX_ENABLED or C.COL_FX_BYPASSED
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col)
            r.ImGui_Text(ctx, fx.name)
            r.ImGui_PopStyleColor(ctx)
            if r.ImGui_IsItemClicked(ctx) and opts.track_ptr then
                r.TrackFX_SetEnabled(opts.track_ptr, fx.idx, not fx.enabled)
            end
            if r.ImGui_IsItemHovered(ctx) then
                r.ImGui_SetTooltip(ctx, (fx.enabled and "Bypass" or "Enable") .. ": " .. fx.name)
            end
        end
    elseif not opts.is_master then
        r.ImGui_TextDisabled(ctx, "--")
    end

    -- === SENDS ===
    if opts.sends and #opts.sends > 0 then
        for _, send in ipairs(opts.sends) do
            local scol = send.muted and 0x555555FF or 0x6699BBFF
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), scol)
            r.ImGui_Text(ctx, ">" .. send.name)
            r.ImGui_PopStyleColor(ctx)
            if r.ImGui_IsItemClicked(ctx) and opts.track_ptr then
                local cur = r.GetTrackSendInfo_Value(opts.track_ptr, 0, send.idx, "B_MUTE")
                r.SetTrackSendInfo_Value(opts.track_ptr, 0, send.idx, "B_MUTE", cur == 1 and 0 or 1)
            end
            if r.ImGui_IsItemHovered(ctx) then
                r.ImGui_SetTooltip(ctx, (send.muted and "Unmute" or "Mute") .. " send: " .. send.name)
            end
        end
    end

    r.ImGui_Spacing(ctx)

    -- === VOLUME KNOB ===
    local vol_norm = H.VolToNorm(opts.vol or 1)
    local v_changed, v_new, v_hover = W.DrawKnob("##v" .. opts.id, vol_norm, H.VolToNorm(1.0), C.KNOB_SIZE)
    if v_changed and opts.track_ptr then
        r.SetMediaTrackInfo_Value(opts.track_ptr, "D_VOL", H.NormToVol(v_new))
    end
    local db_text = H.FormatDb(opts.vol or 1)
    local dbw = r.ImGui_CalcTextSize(ctx, db_text)
    r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + (C.KNOB_SIZE - dbw) / 2)
    r.ImGui_TextDisabled(ctx, db_text)
    if v_hover then r.ImGui_SetTooltip(ctx, db_text .. " dB") end

    -- === PAN KNOB ===
    local pan_norm = H.PanToNorm(opts.pan or 0)
    local p_changed, p_new, p_hover = W.DrawKnob("##p" .. opts.id, pan_norm, 0.5, C.KNOB_SIZE)
    if p_changed and opts.track_ptr then
        r.SetMediaTrackInfo_Value(opts.track_ptr, "D_PAN", H.NormToPan(p_new))
    end
    local pan_val = p_changed and H.NormToPan(p_new) or (opts.pan or 0)
    local pan_text = "C"
    if pan_val < -0.01 then pan_text = string.format("L%d", math.floor(-pan_val * 100 + 0.5))
    elseif pan_val > 0.01 then pan_text = string.format("R%d", math.floor(pan_val * 100 + 0.5)) end
    local pw = r.ImGui_CalcTextSize(ctx, pan_text)
    r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + (C.KNOB_SIZE - pw) / 2)
    r.ImGui_TextDisabled(ctx, pan_text)
    if p_hover then r.ImGui_SetTooltip(ctx, "Pan: " .. pan_text) end

    -- === VU METER (vertical) ===
    local vx, vy = r.ImGui_GetCursorScreenPos(ctx)
    W.DrawVMeter(vx, vy, C.METER_W, C.METER_H_TRACK, opts.peak_l or 0, opts.peak_r or 0)
    r.ImGui_Dummy(ctx, C.METER_W, C.METER_H_TRACK)

    -- === MUTE / SOLO ===
    local btn_w = math.floor((C.STRIP_W - 4) / 2)

    if opts.mute then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), C.COL_MUTE)
    end
    if r.ImGui_Button(ctx, "M##m" .. opts.id, btn_w, 0) then
        if opts.track_ptr then
            r.SetMediaTrackInfo_Value(opts.track_ptr, "B_MUTE", opts.mute and 0 or 1)
        end
    end
    if opts.mute then r.ImGui_PopStyleColor(ctx) end

    r.ImGui_SameLine(ctx)

    if opts.solo then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), C.COL_SOLO)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x000000FF)
    end
    if r.ImGui_Button(ctx, "S##s" .. opts.id, btn_w, 0) then
        if opts.track_ptr then
            local param = opts.is_master and "B_MUTE" or "I_SOLO"
            local new_val = opts.solo and 0 or 2
            if opts.is_master then new_val = opts.solo and 0 or 1 end
            r.SetMediaTrackInfo_Value(opts.track_ptr, param, new_val)
        end
    end
    if opts.solo then r.ImGui_PopStyleColor(ctx, 2) end

    r.ImGui_EndGroup(ctx)
end

return MixerStrip
