-- ItemEditor.lua — Full item editor: waveform, zoom/scroll, trim, fades,
-- grid snap, stretch markers, selection, reverse/loop/warp, context menu, shortcuts
local ItemEditor = {}
local r, C, H, W, WF, BG, PS, S, ctx

function ItemEditor.init(reaper_api, constants, helpers, widgets, waveform, bargrid, pitchstretch, state, imgui_ctx)
    r = reaper_api
    C = constants
    H = helpers
    W = widgets
    WF = waveform
    BG = bargrid
    PS = pitchstretch
    S = state
    ctx = imgui_ctx
end

-- ============================================================================
-- EDITOR STATE (persistent across frames, reset on item change)
-- ============================================================================
local editor = {
    zoom = 1.0,
    scroll = 0.0,
    last_item_id = nil,
    -- Drag interaction
    drag_mode = nil,       -- nil, "trim_left", "trim_right", "fade_in", "fade_out", "sm", "selection", "scroll"
    drag_start_x = 0,
    drag_start_val = 0,
    drag_start_val2 = 0,
    drag_sm_idx = -1,
    drag_active = false,
    -- Selection
    sel_start = nil,       -- source-time
    sel_end = nil,
    -- Grid / Snap
    snap_enabled = true,
    grid_idx = 3,          -- index into GRID_RESOLUTIONS (default 1/4)
    -- Double-click timer for SM delete
    last_click_time = 0,
    last_click_sm = -1,
}

-- ============================================================================
-- VIEW COMPUTATION
-- ============================================================================
local function computeView(info)
    if not info then return 0, 1 end
    local item_rate = info.playrate or 1
    local item_src_len = (info.len or 1) * item_rate
    local source_len = info.source_len or item_src_len

    local visible_len = item_src_len / editor.zoom
    if visible_len > source_len then visible_len = source_len end

    local scroll_range = source_len - visible_len
    local view_start
    if scroll_range <= 0 then
        view_start = 0
    else
        view_start = editor.scroll * scroll_range
        view_start = math.max(0, math.min(scroll_range, view_start))
    end

    return view_start, visible_len
end

-- ============================================================================
-- SNAP HELPER — snap source-time to grid (via project-time conversion)
-- ============================================================================
local function snapSourceTime(src_time, info)
    if not editor.snap_enabled then return src_time end
    local proj = S.data.active_proj
    if not proj or not info then return src_time end

    local item_rate = info.playrate or 1
    local item_src_start = info.source_offset or 0
    -- Convert source-time to project-time
    local proj_time = info.pos + (src_time - item_src_start) / item_rate
    -- Snap in project-time
    local snapped_proj = BG.SnapToGrid(proj, proj_time, editor.grid_idx)
    -- Convert back to source-time
    return item_src_start + (snapped_proj - info.pos) * item_rate
end

-- ============================================================================
-- ZONE DETECTION — determine what the mouse is hovering over
-- ============================================================================
local function detectZone(mx, my, wx, wy, wf_w, wf_h, info, view_start, view_len)
    if not info then return "outside" end

    local item_rate = info.playrate or 1
    local item_src_start = info.source_offset or 0
    local item_src_end = item_src_start + (info.len or 0) * item_rate

    -- Pixel positions of item edges
    local left_px = WF.TimeToPixel(item_src_start, wx, wf_w, view_start, view_len)
    local right_px = WF.TimeToPixel(item_src_end, wx, wf_w, view_start, view_len)

    -- Fade pixel positions
    local fade_in_src = (info.fade_in or 0) * item_rate
    local fade_out_src = (info.fade_out or 0) * item_rate
    local fi_px = WF.TimeToPixel(item_src_start + fade_in_src, wx, wf_w, view_start, view_len)
    local fo_px = WF.TimeToPixel(item_src_end - fade_out_src, wx, wf_w, view_start, view_len)

    -- Stretch marker hit test
    if info.stretch_markers then
        for _, sm in ipairs(info.stretch_markers) do
            local sm_x = WF.TimeToPixel(sm.srcpos, wx, wf_w, view_start, view_len)
            if math.abs(mx - sm_x) <= C.SM_HIT_PX and my >= wy and my <= wy + wf_h then
                return "sm", sm.idx
            end
        end
    end

    -- Fade handles (top corners, within fade region)
    if my >= wy and my <= wy + C.FADE_HIT_H then
        -- Fade in handle
        if mx >= left_px and mx <= fi_px + C.EDGE_HIT_PX and fade_in_src > 0 then
            return "fade_in"
        end
        -- Fade out handle
        if mx >= fo_px - C.EDGE_HIT_PX and mx <= right_px and fade_out_src > 0 then
            return "fade_out"
        end
    end

    -- Edge hit detection (left/right borders)
    if math.abs(mx - left_px) <= C.EDGE_HIT_PX and my >= wy and my <= wy + wf_h then
        return "edge_left"
    end
    if math.abs(mx - right_px) <= C.EDGE_HIT_PX and my >= wy and my <= wy + wf_h then
        return "edge_right"
    end

    -- Inside item region
    if mx >= left_px and mx <= right_px and my >= wy and my <= wy + wf_h then
        return "inside"
    end

    -- Outside item but within waveform area
    if mx >= wx and mx <= wx + wf_w and my >= wy and my <= wy + wf_h then
        return "source"
    end

    return "outside"
end

-- ============================================================================
-- DRAW — main item editor panel
-- ============================================================================
function ItemEditor.Draw()
    local item = S.data.focused_item
    local take = S.data.focused_take
    local info = S.data.item_info
    if not item or not info then return end

    -- Detect item change → reset state
    local item_id = tostring(item)
    if editor.last_item_id ~= item_id then
        editor.zoom = 1.0
        local item_rate = (info.playrate or 1)
        local item_src_start = (info.source_offset or 0)
        local item_src_len = (info.len or 1) * item_rate
        local source_len = info.source_len or item_src_len
        local sr = source_len - item_src_len
        editor.scroll = (sr > 0) and (item_src_start / sr) or 0.5
        editor.scroll = math.max(0, math.min(1, editor.scroll))
        editor.last_item_id = item_id
        editor.drag_mode = nil
        editor.sel_start = nil
        editor.sel_end = nil
        WF.InvalidateCache()
    end

    r.ImGui_Separator(ctx)

    -- ===================== TOOLBAR =====================
    DrawToolbar(item, take, info)

    -- ===================== WAVEFORM + CONTROLS =====================
    if info.is_midi then
        DrawMidiPlaceholder()
        return
    end

    local avail_w = r.ImGui_GetContentRegionAvail(ctx)
    local wf_w = math.max(200, avail_w - C.CTRL_PANEL_W - 15)
    local view_start, view_len = computeView(info)
    local wx, wy = r.ImGui_GetCursorScreenPos(ctx)

    -- Get and draw peaks
    local peaks = WF.GetPeaks(item, take, wf_w, info.item_vol, info.take_vol,
        S.data.stereo_mode, view_start, view_len)
    WF.Draw(wx, wy, wf_w, C.WAVEFORM_H, peaks, S.data.stereo_mode,
        info, view_start, view_len)

    -- Draw overlays
    DrawGridOverlay(wx, wy, wf_w, info, view_start, view_len)
    DrawPlayCursor(wx, wy, wf_w, info, view_start, view_len)
    DrawStretchMarkers(wx, wy, wf_w, info, view_start, view_len)
    DrawSelection(wx, wy, wf_w, info, view_start, view_len)
    DrawFadeHandles(wx, wy, wf_w, info, view_start, view_len)

    -- Invisible button for mouse interactions
    r.ImGui_SetCursorScreenPos(ctx, wx, wy)
    r.ImGui_InvisibleButton(ctx, "##wf_interact", wf_w, C.WAVEFORM_H)
    local wf_hovered = r.ImGui_IsItemHovered(ctx)

    -- Handle all mouse interactions
    HandleMouseInteractions(wx, wy, wf_w, item, take, info, view_start, view_len, wf_hovered)

    -- Context menu
    HandleContextMenu(item, take, info, wx, wy, wf_w, view_start, view_len)

    -- Keyboard shortcuts
    HandleKeyboard(item, take, info, wx, wf_w, view_start, view_len, wf_hovered)

    -- ===================== ZOOM SLIDER =====================
    r.ImGui_SetNextItemWidth(ctx, wf_w)
    local zoom_log = math.log(editor.zoom, 2)
    local zoom_min_log = math.log(C.ZOOM_MIN, 2)
    local zoom_max_log = math.log(C.ZOOM_MAX, 2)
    local zoom_changed, zoom_new_log = r.ImGui_SliderDouble(ctx, "##zoom_slider",
        zoom_log, zoom_min_log, zoom_max_log, "Zoom: %.1f", r.ImGui_SliderFlags_NoInput())
    if zoom_changed then
        editor.zoom = 2 ^ zoom_new_log
        WF.InvalidateCache()
    end

    -- ===================== CONTROL PANEL (right side) =====================
    r.ImGui_SameLine(ctx, 0, 10)
    local ctrl_x, _ = r.ImGui_GetCursorScreenPos(ctx)
    r.ImGui_SetCursorScreenPos(ctx, ctrl_x, wy)
    DrawControlPanel(item, take, info)

    -- ===================== INFO BAR =====================
    DrawInfoBar(item, take, info)
end

-- ============================================================================
-- TOOLBAR
-- ============================================================================
function DrawToolbar(item, take, info)
    r.ImGui_BeginGroup(ctx)

    -- Snap toggle
    local snap_col = editor.snap_enabled and C.COL_SNAP_ACTIVE or C.COL_SNAP_INACTIVE
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), snap_col)
    if r.ImGui_SmallButton(ctx, "Snap##snap_toggle") then
        editor.snap_enabled = not editor.snap_enabled
    end
    r.ImGui_PopStyleColor(ctx)
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, editor.snap_enabled and "Snap ON (click to disable)" or "Snap OFF (click to enable)")
    end

    -- Grid resolution dropdown
    r.ImGui_SameLine(ctx, 0, 5)
    local grid_name = BG.GRID_RESOLUTIONS[editor.grid_idx] and BG.GRID_RESOLUTIONS[editor.grid_idx].name or "1/4"
    r.ImGui_SetNextItemWidth(ctx, 55)
    if r.ImGui_BeginCombo(ctx, "##grid_res", grid_name) then
        for gi, gres in ipairs(BG.GRID_RESOLUTIONS) do
            if r.ImGui_Selectable(ctx, gres.name .. "##grid_" .. gi, gi == editor.grid_idx) then
                editor.grid_idx = gi
            end
        end
        r.ImGui_EndCombo(ctx)
    end

    -- Stereo/Mono toggle
    r.ImGui_SameLine(ctx, 0, 10)
    if r.ImGui_SmallButton(ctx, (S.data.stereo_mode and "Stereo" or "Mono") .. "##stereo") then
        S.data.stereo_mode = not S.data.stereo_mode
        WF.InvalidateCache()
    end

    -- Warp toggle (playrate lock)
    if take and not info.is_midi then
        r.ImGui_SameLine(ctx, 0, 10)
        local rate = info.rate or 1
        local is_warped = math.abs(rate - 1.0) > 0.001
        local warp_col = is_warped and C.COL_TOGGLE_ON or C.COL_TOGGLE_OFF
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), warp_col)
        if r.ImGui_SmallButton(ctx, "Warp##warp") then
            if is_warped then
                r.Undo_BeginBlock()
                r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
                r.UpdateItemInProject(item)
                r.Undo_EndBlock("Reset playrate", -1)
                r.UpdateArrange()
                WF.InvalidateCache()
            end
        end
        r.ImGui_PopStyleColor(ctx)
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, is_warped and string.format("Warped: %.2fx (click to reset)", rate) or "Playrate: 1.00x")
        end
    end

    -- Loop toggle
    if item and not info.is_midi then
        r.ImGui_SameLine(ctx, 0, 10)
        local is_looped = PS.IsLooped(item)
        local loop_col = is_looped and C.COL_TOGGLE_ON or C.COL_TOGGLE_OFF
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), loop_col)
        if r.ImGui_SmallButton(ctx, "Loop##loop") then
            PS.ToggleLoop(item)
            WF.InvalidateCache()
        end
        r.ImGui_PopStyleColor(ctx)
    end

    -- Reverse
    if item and not info.is_midi then
        r.ImGui_SameLine(ctx, 0, 10)
        if r.ImGui_SmallButton(ctx, "Rev##reverse") then
            PS.ReverseItem(item)
            WF.InvalidateCache()
        end
    end

    -- Item name
    r.ImGui_SameLine(ctx, 0, 15)
    local display_name = info.name or "Untitled"
    if #display_name > 30 then display_name = display_name:sub(1, 29) .. "." end
    r.ImGui_Text(ctx, display_name)

    -- Duration + source info
    r.ImGui_SameLine(ctx, 0, 5)
    local chan_txt = info.n_chans == 2 and "St" or (info.n_chans == 1 and "Mo" or (info.n_chans .. "ch"))
    local sr_txt = info.sr > 0 and string.format("%.0fk", info.sr / 1000) or ""
    r.ImGui_TextDisabled(ctx, string.format("[%.2fs] %s %s", info.len, chan_txt, sr_txt))

    -- Subproject Dive
    if info.is_subproj then
        r.ImGui_SameLine(ctx, 0, 10)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), C.COL_DIVE)
        if r.ImGui_Button(ctx, "Dive##dive") then
            if info.subproj_ptr then r.SelectProjectInstance(info.subproj_ptr) end
        end
        r.ImGui_PopStyleColor(ctx)
    end

    -- Zoom controls
    r.ImGui_SameLine(ctx, 0, 15)
    r.ImGui_TextDisabled(ctx, string.format("%.0f%%", editor.zoom * 100))
    r.ImGui_SameLine(ctx, 0, 5)
    if r.ImGui_SmallButton(ctx, "Fit##fit") then
        editor.zoom = 1.0
        local ir = (info.playrate or 1)
        local isl = (info.len or 1) * ir
        local sl = info.source_len or isl
        local sr2 = sl - isl
        editor.scroll = (sr2 > 0) and ((info.source_offset or 0) / sr2) or 0.5
        editor.scroll = math.max(0, math.min(1, editor.scroll))
        WF.InvalidateCache()
    end
    if info.source_len and info.source_len > 0 then
        local item_rate = info.playrate or 1
        local item_src_len = info.len * item_rate
        if info.source_len > item_src_len * 1.05 then
            r.ImGui_SameLine(ctx, 0, 3)
            if r.ImGui_SmallButton(ctx, "Src##src") then
                editor.zoom = item_src_len / info.source_len
                editor.scroll = 0.5
                WF.InvalidateCache()
            end
        end
    end

    r.ImGui_EndGroup(ctx)
end

-- ============================================================================
-- GRID OVERLAY
-- ============================================================================
function DrawGridOverlay(wx, wy, wf_w, info, view_start, view_len)
    local proj = S.data.active_proj
    if not proj then return end

    local item_rate = info.playrate or 1
    local item_src_start = info.source_offset or 0

    local bar_lines = BG.GetBarLines(proj, info.pos, info.len, editor.grid_idx)
    if not bar_lines or #bar_lines == 0 then return end

    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    for _, line in ipairs(bar_lines) do
        local src_time = item_src_start + line.rel_time * item_rate
        local x = WF.TimeToPixel(src_time, wx, wf_w, view_start, view_len)
        if x >= wx and x <= wx + wf_w then
            if line.is_bar then
                r.ImGui_DrawList_AddLine(draw_list, x, wy, x, wy + C.WAVEFORM_H, C.COL_BAR_LINE, 1.0)
                r.ImGui_DrawList_AddText(draw_list, x + 2, wy + 1, C.COL_BAR_LABEL, tostring(line.measure))
            elseif line.level == 1 then
                r.ImGui_DrawList_AddLine(draw_list, x, wy, x, wy + C.WAVEFORM_H, C.COL_BEAT_LINE, 1.0)
            else
                r.ImGui_DrawList_AddLine(draw_list, x, wy, x, wy + C.WAVEFORM_H, C.COL_SUBDIV_LINE, 1.0)
            end
        end
    end
end

-- ============================================================================
-- PLAY CURSOR
-- ============================================================================
function DrawPlayCursor(wx, wy, wf_w, info, view_start, view_len)
    local proj = S.data.active_proj
    if not proj then return end

    local play_state = r.GetPlayStateEx(proj)
    if (play_state & 1) ~= 1 then return end

    local play_pos = r.GetPlayPositionEx(proj)
    if play_pos < info.pos or play_pos > info.pos + info.len then return end

    local item_rate = info.playrate or 1
    local item_src_start = info.source_offset or 0
    local play_rel = play_pos - info.pos
    local play_src = item_src_start + play_rel * item_rate
    local cursor_x = WF.TimeToPixel(play_src, wx, wf_w, view_start, view_len)
    if cursor_x >= wx and cursor_x <= wx + wf_w then
        local draw_list = r.ImGui_GetWindowDrawList(ctx)
        r.ImGui_DrawList_AddLine(draw_list, cursor_x, wy, cursor_x, wy + C.WAVEFORM_H, C.COL_CURSOR_LINE, 1.0)
    end
end

-- ============================================================================
-- STRETCH MARKERS
-- ============================================================================
function DrawStretchMarkers(wx, wy, wf_w, info, view_start, view_len)
    if not info.stretch_markers or #info.stretch_markers == 0 then return end
    local draw_list = r.ImGui_GetWindowDrawList(ctx)

    for _, sm in ipairs(info.stretch_markers) do
        local sm_x = WF.TimeToPixel(sm.srcpos, wx, wf_w, view_start, view_len)
        if sm_x >= wx and sm_x <= wx + wf_w then
            local col = (editor.drag_mode == "sm" and editor.drag_sm_idx == sm.idx)
                and C.COL_SM_DRAG or C.COL_STRETCH_MK
            r.ImGui_DrawList_AddLine(draw_list, sm_x, wy, sm_x, wy + C.WAVEFORM_H, col, 1.5)
            r.ImGui_DrawList_AddTriangleFilled(draw_list,
                sm_x - 4, wy, sm_x + 4, wy, sm_x, wy + 6, col)
        end
    end
end

-- ============================================================================
-- SELECTION OVERLAY
-- ============================================================================
function DrawSelection(wx, wy, wf_w, _, view_start, view_len)
    if not editor.sel_start or not editor.sel_end then return end
    local s1 = math.min(editor.sel_start, editor.sel_end)
    local s2 = math.max(editor.sel_start, editor.sel_end)
    if s2 - s1 < 0.0001 then return end

    local px1 = WF.TimeToPixel(s1, wx, wf_w, view_start, view_len)
    local px2 = WF.TimeToPixel(s2, wx, wf_w, view_start, view_len)
    px1 = math.max(wx, math.min(wx + wf_w, px1))
    px2 = math.max(wx, math.min(wx + wf_w, px2))

    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRectFilled(draw_list, px1, wy, px2, wy + C.WAVEFORM_H, C.COL_SELECTION)
    r.ImGui_DrawList_AddLine(draw_list, px1, wy, px1, wy + C.WAVEFORM_H, C.COL_SELECTION_EDGE, 1.0)
    r.ImGui_DrawList_AddLine(draw_list, px2, wy, px2, wy + C.WAVEFORM_H, C.COL_SELECTION_EDGE, 1.0)
end

-- ============================================================================
-- FADE HANDLES (visual indicators at corners)
-- ============================================================================
function DrawFadeHandles(wx, wy, wf_w, info, view_start, view_len)
    local item_rate = info.playrate or 1
    local item_src_start = info.source_offset or 0
    local item_src_end = item_src_start + info.len * item_rate
    local draw_list = r.ImGui_GetWindowDrawList(ctx)

    -- Fade in handle dot
    local fade_in_src = (info.fade_in or 0) * item_rate
    if fade_in_src > 0 then
        local fi_x = WF.TimeToPixel(item_src_start + fade_in_src, wx, wf_w, view_start, view_len)
        if fi_x >= wx and fi_x <= wx + wf_w then
            r.ImGui_DrawList_AddCircleFilled(draw_list, fi_x, wy, 3, C.COL_FADE_HANDLE)
        end
    end

    -- Fade out handle dot
    local fade_out_src = (info.fade_out or 0) * item_rate
    if fade_out_src > 0 then
        local fo_x = WF.TimeToPixel(item_src_end - fade_out_src, wx, wf_w, view_start, view_len)
        if fo_x >= wx and fo_x <= wx + wf_w then
            r.ImGui_DrawList_AddCircleFilled(draw_list, fo_x, wy, 3, C.COL_FADE_HANDLE)
        end
    end
end

-- ============================================================================
-- MOUSE INTERACTIONS
-- ============================================================================
function HandleMouseInteractions(wx, wy, wf_w, item, take, info, view_start, view_len, wf_hovered)
    local mx, my = r.ImGui_GetMousePos(ctx)
    local item_rate = info.playrate or 1
    local item_src_start = info.source_offset or 0

    -- Mouse wheel zoom (always when hovered)
    if wf_hovered then
        local wheel = r.ImGui_GetMouseWheel(ctx)
        if wheel ~= 0 then
            local old_zoom = editor.zoom
            editor.zoom = math.max(C.ZOOM_MIN, math.min(C.ZOOM_MAX, editor.zoom * (1 + C.ZOOM_WHEEL_SPEED * wheel)))
            if editor.zoom ~= old_zoom then WF.InvalidateCache() end
        end
    end

    -- Middle mouse drag for scrolling (no drag_mode needed, always works)
    if wf_hovered and r.ImGui_IsMouseDragging(ctx, 2) then
        local dx, _ = r.ImGui_GetMouseDelta(ctx)
        if dx ~= 0 then
            editor.scroll = math.max(0, math.min(1, editor.scroll - dx / wf_w))
            WF.InvalidateCache()
        end
    end

    -- === DRAG STATE MACHINE ===
    local left_down = r.ImGui_IsMouseDown(ctx, 0)
    local left_clicked = r.ImGui_IsItemClicked(ctx, 0)

    -- Begin drag
    if left_clicked and not editor.drag_mode then
        local zone, zone_data = detectZone(mx, my, wx, wy, wf_w, C.WAVEFORM_H, info, view_start, view_len)
        editor.drag_start_x = mx
        editor.drag_active = false

        if zone == "sm" then
            -- Check double-click for SM delete
            local now = r.time_precise()
            if editor.last_click_sm == zone_data and (now - editor.last_click_time) < 0.35 then
                PS.DeleteStretchMarker(take, zone_data)
                editor.last_click_sm = -1
                editor.last_click_time = 0
                return
            end
            editor.last_click_sm = zone_data
            editor.last_click_time = now
            editor.drag_mode = "sm"
            editor.drag_sm_idx = zone_data
            -- Find initial srcpos for this SM
            for _, sm in ipairs(info.stretch_markers) do
                if sm.idx == zone_data then
                    editor.drag_start_val = sm.srcpos
                    break
                end
            end
        elseif zone == "edge_left" then
            editor.drag_mode = "trim_left"
            editor.drag_start_val = info.pos
            editor.drag_start_val2 = info.source_offset
            editor.last_click_sm = -1
        elseif zone == "edge_right" then
            editor.drag_mode = "trim_right"
            editor.drag_start_val = info.len
            editor.last_click_sm = -1
        elseif zone == "fade_in" then
            editor.drag_mode = "fade_in"
            editor.drag_start_val = info.fade_in or 0
            editor.last_click_sm = -1
        elseif zone == "fade_out" then
            editor.drag_mode = "fade_out"
            editor.drag_start_val = info.fade_out or 0
            editor.last_click_sm = -1
        elseif zone == "inside" or zone == "source" then
            local mods = r.ImGui_GetKeyMods(ctx)
            if mods == r.ImGui_Mod_Shift() then
                -- Shift+Click = add stretch marker
                local src_time = WF.PixelToTime(mx, wx, wf_w, view_start, view_len)
                local time_in_item = (src_time - item_src_start) / item_rate
                local pos_in_item = math.max(0, math.min(info.len, time_in_item))
                if editor.snap_enabled then
                    local snapped_src = snapSourceTime(src_time, info)
                    pos_in_item = math.max(0, math.min(info.len, (snapped_src - item_src_start) / item_rate))
                end
                PS.AddStretchMarker(take, item, pos_in_item)
                editor.last_click_sm = -1
            elseif mods == r.ImGui_Mod_Ctrl() then
                -- Ctrl+Click = split
                local src_time = WF.PixelToTime(mx, wx, wf_w, view_start, view_len)
                local time_in_item = (src_time - item_src_start) / item_rate
                if editor.snap_enabled then
                    local snapped_src = snapSourceTime(src_time, info)
                    time_in_item = (snapped_src - item_src_start) / item_rate
                end
                local pos_in_item = math.max(0, math.min(info.len, time_in_item))
                if pos_in_item > 0.001 and pos_in_item < info.len - 0.001 then
                    r.PreventUIRefresh(1)
                    r.Undo_BeginBlock()
                    r.SplitMediaItem(item, info.pos + pos_in_item)
                    r.Undo_EndBlock("Split item", -1)
                    r.PreventUIRefresh(-1)
                    r.UpdateArrange()
                end
                editor.last_click_sm = -1
            else
                -- Normal click: start selection or set cursor
                editor.drag_mode = "selection"
                local src_time = WF.PixelToTime(mx, wx, wf_w, view_start, view_len)
                editor.sel_start = src_time
                editor.sel_end = src_time
                -- Also set edit cursor
                local time_in_item = (src_time - item_src_start) / item_rate
                local pos_in_item = math.max(0, math.min(info.len, time_in_item))
                r.SetEditCurPos(info.pos + pos_in_item, false, false)
                editor.last_click_sm = -1
            end
        end
    end

    -- Continue drag
    if editor.drag_mode and left_down then
        local dx = mx - editor.drag_start_x
        if math.abs(dx) > 2 then editor.drag_active = true end

        if editor.drag_active then
            HandleDrag(mx, wx, wf_w, item, take, info, view_start, view_len, dx)
        end
    end

    -- End drag
    if editor.drag_mode and not left_down then
        if editor.drag_active and editor.drag_mode ~= "selection" then
            r.Undo_EndBlock("Item edit", -1)
            r.PreventUIRefresh(-1)
            r.UpdateArrange()
            WF.InvalidateCache()
        end
        -- If selection drag was tiny, clear it
        if editor.drag_mode == "selection" and not editor.drag_active then
            editor.sel_start = nil
            editor.sel_end = nil
        end
        editor.drag_mode = nil
        editor.drag_active = false
        editor._undo_started = nil
    end

    -- Mouse cursor adaptation
    if wf_hovered and not editor.drag_mode then
        local zone = detectZone(mx, my, wx, wy, wf_w, C.WAVEFORM_H, info, view_start, view_len)
        if zone == "edge_left" or zone == "edge_right" then
            r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_ResizeEW())
        elseif zone == "fade_in" or zone == "fade_out" then
            r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_ResizeEW())
        elseif zone == "sm" then
            r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_Hand())
        end
    end

    -- Tooltip
    if wf_hovered and not editor.drag_mode then
        local src_time = WF.PixelToTime(mx, wx, wf_w, view_start, view_len)
        local time_in_item = (src_time - item_src_start) / item_rate
        r.ImGui_SetTooltip(ctx, string.format("%.3fs", time_in_item))
    end
end

-- ============================================================================
-- DRAG HANDLERS
-- ============================================================================
function HandleDrag(mx, wx, wf_w, item, take, info, view_start, view_len, dx)
    local item_rate = info.playrate or 1
    local item_src_start = info.source_offset or 0

    -- Begin undo block on first drag pixel (only once, not for selection)
    if not editor._undo_started and editor.drag_mode ~= "selection" then
        r.PreventUIRefresh(1)
        r.Undo_BeginBlock()
        editor._undo_started = true
    end

    if editor.drag_mode == "trim_left" then
        -- Convert pixel delta to time delta
        local time_per_px = view_len / wf_w
        local delta_src = dx * time_per_px
        local delta_time = delta_src / item_rate

        local old_pos = editor.drag_start_val
        local old_offs = editor.drag_start_val2
        local old_len = info.len + (info.pos - old_pos)  -- reconstruct original length

        local new_pos = old_pos + delta_time
        local new_len = old_len - delta_time
        local new_offs = old_offs + delta_src

        -- Clamp: can't go before source start
        if new_offs < 0 then
            local correction = -new_offs / item_rate
            new_pos = new_pos + correction
            new_len = new_len - correction
            new_offs = 0
        end
        -- Clamp: can't shrink to 0
        if new_len < 0.001 then
            new_len = 0.001
            new_pos = old_pos + old_len - 0.001
            new_offs = old_offs + (old_len - 0.001) * item_rate
        end

        r.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
        r.SetMediaItemInfo_Value(item, "D_LENGTH", new_len)
        r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_offs)
        r.UpdateItemInProject(item)

    elseif editor.drag_mode == "trim_right" then
        local time_per_px = view_len / wf_w
        local delta_src = dx * time_per_px
        local delta_time = delta_src / item_rate

        local new_len = editor.drag_start_val + delta_time

        -- Clamp: can't go past source end
        local max_len = ((info.source_len or info.len) - item_src_start) / item_rate
        new_len = math.max(0.001, math.min(max_len, new_len))

        r.SetMediaItemInfo_Value(item, "D_LENGTH", new_len)
        r.UpdateItemInProject(item)

    elseif editor.drag_mode == "fade_in" then
        local time_per_px = view_len / wf_w
        local delta_src = dx * time_per_px
        local delta_time = delta_src / item_rate

        local new_fade = math.max(0, editor.drag_start_val + delta_time)
        local max_fade = info.len - (info.fade_out or 0)
        new_fade = math.min(new_fade, max_fade)

        r.SetMediaItemInfo_Value(item, "D_FADEINLEN", new_fade)
        r.UpdateItemInProject(item)

    elseif editor.drag_mode == "fade_out" then
        local time_per_px = view_len / wf_w
        local delta_src = dx * time_per_px
        local delta_time = delta_src / item_rate

        -- Fade out: dragging right = less fade, left = more fade
        local new_fade = math.max(0, editor.drag_start_val - delta_time)
        local max_fade = info.len - (info.fade_in or 0)
        new_fade = math.min(new_fade, max_fade)

        r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", new_fade)
        r.UpdateItemInProject(item)

    elseif editor.drag_mode == "sm" then
        local src_time = WF.PixelToTime(mx, wx, wf_w, view_start, view_len)
        -- Convert to take-time (pos, not srcpos)
        local take_time = (src_time - item_src_start) / item_rate
        take_time = math.max(0, math.min(info.len, take_time))

        -- Snap
        if editor.snap_enabled then
            local snapped = snapSourceTime(src_time, info)
            take_time = math.max(0, math.min(info.len, (snapped - item_src_start) / item_rate))
        end

        PS.MoveStretchMarker(take, editor.drag_sm_idx, take_time)

    elseif editor.drag_mode == "selection" then
        local src_time = WF.PixelToTime(mx, wx, wf_w, view_start, view_len)
        -- Clamp to item bounds in source time
        local item_src_end = item_src_start + info.len * item_rate
        src_time = math.max(item_src_start, math.min(item_src_end, src_time))
        editor.sel_end = src_time
    end
end

-- ============================================================================
-- CONTEXT MENU (right-click)
-- ============================================================================
function HandleContextMenu(item, take, info, wx, _, wf_w, view_start, view_len)
    if r.ImGui_IsItemClicked(ctx, 1) then
        -- Store mouse position for context actions
        local mx, _ = r.ImGui_GetMousePos(ctx)
        local src_time = WF.PixelToTime(mx, wx, wf_w, view_start, view_len)
        local item_rate = info.playrate or 1
        local item_src_start = info.source_offset or 0
        editor._ctx_time_in_item = (src_time - item_src_start) / item_rate
        r.ImGui_OpenPopup(ctx, "##item_ctx_menu")
    end

    if r.ImGui_BeginPopup(ctx, "##item_ctx_menu") then
        local time_in_item = editor._ctx_time_in_item or 0

        if r.ImGui_MenuItem(ctx, "Split at cursor") then
            if time_in_item > 0.001 and time_in_item < info.len - 0.001 then
                r.PreventUIRefresh(1)
                r.Undo_BeginBlock()
                r.SplitMediaItem(item, info.pos + time_in_item)
                r.Undo_EndBlock("Split item", -1)
                r.PreventUIRefresh(-1)
                r.UpdateArrange()
            end
        end

        if r.ImGui_MenuItem(ctx, "Add stretch marker") then
            local pos = math.max(0, math.min(info.len, time_in_item))
            PS.AddStretchMarker(take, item, pos)
        end

        r.ImGui_Separator(ctx)

        if r.ImGui_MenuItem(ctx, "Reverse") then
            PS.ReverseItem(item)
            WF.InvalidateCache()
        end

        local is_looped = PS.IsLooped(item)
        if r.ImGui_MenuItem(ctx, "Loop source", nil, is_looped) then
            PS.ToggleLoop(item)
        end

        r.ImGui_Separator(ctx)

        if r.ImGui_MenuItem(ctx, "Split at bars") then
            BG.SplitItemAtBars(item)
        end

        if info.stretch_markers and #info.stretch_markers > 0 then
            if r.ImGui_MenuItem(ctx, "Clear stretch markers") then
                PS.ClearStretchMarkers(take)
            end
        end

        -- Selection-based operations
        if editor.sel_start and editor.sel_end then
            local s1 = math.min(editor.sel_start, editor.sel_end)
            local s2 = math.max(editor.sel_start, editor.sel_end)
            if s2 - s1 > 0.0001 then
                r.ImGui_Separator(ctx)
                local item_rate = info.playrate or 1
                local item_src_start = info.source_offset or 0
                local sel_start_item = (s1 - item_src_start) / item_rate
                local sel_end_item = (s2 - item_src_start) / item_rate
                local sel_dur = sel_end_item - sel_start_item

                r.ImGui_TextDisabled(ctx, string.format("Selection: %.3fs", sel_dur))

                if r.ImGui_MenuItem(ctx, "Crop to selection") then
                    CropToSelection(item, take, info, sel_start_item, sel_end_item)
                    editor.sel_start = nil
                    editor.sel_end = nil
                end

                if r.ImGui_MenuItem(ctx, "Delete selection") then
                    DeleteSelection(item, take, info, sel_start_item, sel_end_item)
                    editor.sel_start = nil
                    editor.sel_end = nil
                end
            end
        end

        r.ImGui_EndPopup(ctx)
    end
end

-- ============================================================================
-- SELECTION OPERATIONS
-- ============================================================================
function CropToSelection(item, take, info, sel_start_item, sel_end_item)
    if not item or not take then return end
    sel_start_item = math.max(0, sel_start_item)
    sel_end_item = math.min(info.len, sel_end_item)
    if sel_end_item - sel_start_item < 0.001 then return end

    local item_rate = info.playrate or 1
    local old_offs = info.source_offset or 0

    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()

    local new_pos = info.pos + sel_start_item
    local new_len = sel_end_item - sel_start_item
    local new_offs = old_offs + sel_start_item * item_rate

    r.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", new_len)
    r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_offs)

    r.Undo_EndBlock("Crop to selection", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    WF.InvalidateCache()
end

function DeleteSelection(item, _, info, sel_start_item, sel_end_item)
    if not item then return end
    sel_start_item = math.max(0, sel_start_item)
    sel_end_item = math.min(info.len, sel_end_item)
    if sel_end_item - sel_start_item < 0.001 then return end

    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()

    -- Split at both edges, then delete middle
    local split_end = info.pos + sel_end_item
    local split_start = info.pos + sel_start_item

    -- Split at end first (so item pointer stays valid for start split)
    if sel_end_item < info.len - 0.001 then
        r.SplitMediaItem(item, split_end)
    end

    -- Split at start
    local middle_item = nil
    if sel_start_item > 0.001 then
        middle_item = r.SplitMediaItem(item, split_start)
    else
        middle_item = item
    end

    -- Delete the middle piece
    if middle_item then
        local track = r.GetMediaItemTrack(middle_item)
        if track then
            r.DeleteTrackMediaItem(track, middle_item)
        end
    end

    r.Undo_EndBlock("Delete selection", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    WF.InvalidateCache()
    editor.last_item_id = nil  -- force editor reset
end

-- ============================================================================
-- KEYBOARD SHORTCUTS
-- ============================================================================
function HandleKeyboard(item, take, info, _, _, _, _, wf_hovered)  -- wx, wf_w, view_start, view_len unused
    if not wf_hovered then return end

    -- Escape = clear selection
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        editor.sel_start = nil
        editor.sel_end = nil
    end

    -- S = split at edit cursor position
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_S()) then
        local cursor_pos = r.GetCursorPosition()
        if cursor_pos > info.pos and cursor_pos < info.pos + info.len then
            r.PreventUIRefresh(1)
            r.Undo_BeginBlock()
            r.SplitMediaItem(item, cursor_pos)
            r.Undo_EndBlock("Split item at cursor", -1)
            r.PreventUIRefresh(-1)
            r.UpdateArrange()
        end
    end

    -- M = add stretch marker at edit cursor
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_M()) then
        local cursor_pos = r.GetCursorPosition()
        local time_in_item = cursor_pos - info.pos
        if time_in_item > 0 and time_in_item < info.len then
            PS.AddStretchMarker(take, item, time_in_item)
        end
    end

    -- R = reverse
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_R()) then
        PS.ReverseItem(item)
        WF.InvalidateCache()
    end

    -- L = toggle loop
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_L()) then
        PS.ToggleLoop(item)
    end

    -- Delete = delete selection or item
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Delete()) then
        if editor.sel_start and editor.sel_end then
            local s1 = math.min(editor.sel_start, editor.sel_end)
            local s2 = math.max(editor.sel_start, editor.sel_end)
            if s2 - s1 > 0.0001 then
                local item_rate = info.playrate or 1
                local item_src_start = info.source_offset or 0
                local sel_s = (s1 - item_src_start) / item_rate
                local sel_e = (s2 - item_src_start) / item_rate
                DeleteSelection(item, take, info, sel_s, sel_e)
                editor.sel_start = nil
                editor.sel_end = nil
            end
        end
    end

    -- + / - = zoom in/out
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Equal()) then  -- +/= key
        editor.zoom = math.min(C.ZOOM_MAX, editor.zoom * 1.3)
        WF.InvalidateCache()
    end
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Minus()) then
        editor.zoom = math.max(C.ZOOM_MIN, editor.zoom / 1.3)
        WF.InvalidateCache()
    end
end

-- ============================================================================
-- CONTROL PANEL (right column)
-- ============================================================================
function DrawControlPanel(item, take, info)
    r.ImGui_BeginGroup(ctx)

    -- Pitch knob
    r.ImGui_Text(ctx, "Pitch")
    r.ImGui_SameLine(ctx, 40)
    local pitch = info.pitch or 0
    local pitch_norm = (pitch + 24) / 48
    pitch_norm = math.max(0, math.min(1, pitch_norm))
    local pitch_changed, pitch_new = W.DrawKnob("##ed_pitch", pitch_norm, 0.5, C.KNOB_SIZE_SM)
    if pitch_changed and take then
        r.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch_new * 48 - 24)
        r.UpdateItemInProject(item)
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_TextDisabled(ctx, string.format("%.1fst", pitch))

    -- Rate knob
    r.ImGui_Text(ctx, "Rate")
    r.ImGui_SameLine(ctx, 40)
    local rate = info.rate or 1
    local rate_norm = (math.log(rate, 2) + 2) / 4
    rate_norm = math.max(0, math.min(1, rate_norm))
    local rate_changed, rate_new = W.DrawKnob("##ed_rate", rate_norm, 0.5, C.KNOB_SIZE_SM)
    if rate_changed and take then
        r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 2 ^ (rate_new * 4 - 2))
        r.UpdateItemInProject(item)
        WF.InvalidateCache()
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_TextDisabled(ctx, string.format("%.2fx", rate))

    -- Volume knob
    r.ImGui_Text(ctx, "Vol")
    r.ImGui_SameLine(ctx, 40)
    local item_vol = info.item_vol or 1
    local vol_norm = H.VolToNorm(item_vol)
    local vol_changed, vol_new = W.DrawKnob("##ed_vol", vol_norm, H.VolToNorm(1.0), C.KNOB_SIZE_SM)
    if vol_changed then
        r.SetMediaItemInfo_Value(item, "D_VOL", H.NormToVol(vol_new))
        r.UpdateItemInProject(item)
        WF.InvalidateCache()
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_TextDisabled(ctx, H.FormatDb(item_vol) .. "dB")

    -- Fades display
    r.ImGui_TextDisabled(ctx, string.format("In:%.0fms Out:%.0fms",
        (info.fade_in or 0) * 1000, (info.fade_out or 0) * 1000))

    r.ImGui_EndGroup(ctx)
end

-- ============================================================================
-- INFO BAR (below waveform/controls)
-- ============================================================================
function DrawInfoBar(item, take, info)
    if not take then return end

    -- Algorithm bar
    PS.DrawInline(take, info)

    -- Take FX chain display (inline)
    DrawTakeFX(item, take, info)

    -- Selection info
    if editor.sel_start and editor.sel_end then
        local s1 = math.min(editor.sel_start, editor.sel_end)
        local s2 = math.max(editor.sel_start, editor.sel_end)
        if s2 - s1 > 0.0001 then
            local item_rate = info.playrate or 1
            local item_src_start = info.source_offset or 0
            local sel_s = (s1 - item_src_start) / item_rate
            local sel_e = (s2 - item_src_start) / item_rate
            local sel_dur = sel_e - sel_s

            r.ImGui_SameLine(ctx, 0, 20)
            r.ImGui_TextDisabled(ctx, string.format("Sel: %.3fs", sel_dur))

            r.ImGui_SameLine(ctx, 0, 8)
            if r.ImGui_SmallButton(ctx, "Crop##crop_sel") then
                CropToSelection(item, take, info, sel_s, sel_e)
                editor.sel_start = nil
                editor.sel_end = nil
            end
            r.ImGui_SameLine(ctx, 0, 4)
            if r.ImGui_SmallButton(ctx, "Del##del_sel") then
                DeleteSelection(item, take, info, sel_s, sel_e)
                editor.sel_start = nil
                editor.sel_end = nil
            end
        end
    end

    -- Clip actions row (subproject, glue, apply FX, export)
    DrawClipActions(item, take, info)
end

-- ============================================================================
-- TAKE FX CHAIN DISPLAY
-- ============================================================================
function DrawTakeFX(_, take, info)  -- item unused
    if not take or not info or not info.take_fx then return end

    local has_fx = #info.take_fx > 0

    r.ImGui_SameLine(ctx, 0, 15)
    r.ImGui_Text(ctx, "TakeFX:")
    r.ImGui_SameLine(ctx, 0, 3)

    if not has_fx then
        r.ImGui_TextDisabled(ctx, "None")
    else
        for fi, fx in ipairs(info.take_fx) do
            if fi > 1 then r.ImGui_SameLine(ctx, 0, 3) end
            local col = fx.enabled and C.COL_FX_ENABLED or C.COL_FX_BYPASSED
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col)
            r.ImGui_Text(ctx, fx.name)
            r.ImGui_PopStyleColor(ctx)

            -- Click to bypass/enable
            if r.ImGui_IsItemClicked(ctx, 0) then
                r.TakeFX_SetEnabled(take, fx.idx, not fx.enabled)
            end
            -- Double-click to open FX window
            if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
                r.TakeFX_Show(take, fx.idx, 3) -- 3 = show floating
            end
            if r.ImGui_IsItemHovered(ctx) then
                r.ImGui_SetTooltip(ctx,
                    (fx.enabled and "Click: bypass" or "Click: enable") ..
                    " | Double-click: open\n" .. fx.name)
            end
        end
    end

    -- Add Take FX button
    r.ImGui_SameLine(ctx, 0, 5)
    if r.ImGui_SmallButton(ctx, "+##add_takefx") then
        r.ImGui_OpenPopup(ctx, "##add_takefx_popup")
    end
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, "Take FX actions")
    end
    if r.ImGui_BeginPopup(ctx, "##add_takefx_popup") then
        if r.ImGui_MenuItem(ctx, "Open FX chain...") then
            r.TakeFX_Show(take, 0, 1) -- 1 = show chain
        end
        if has_fx then
            r.ImGui_Separator(ctx)
            if r.ImGui_MenuItem(ctx, "Bypass all") then
                for _, fx in ipairs(info.take_fx) do
                    r.TakeFX_SetEnabled(take, fx.idx, false)
                end
            end
            if r.ImGui_MenuItem(ctx, "Enable all") then
                for _, fx in ipairs(info.take_fx) do
                    r.TakeFX_SetEnabled(take, fx.idx, true)
                end
            end
        end
        r.ImGui_EndPopup(ctx)
    end
end

-- ============================================================================
-- CLIP ACTIONS — subproject, bounce, export
-- ============================================================================
function DrawClipActions(item, _, info)  -- take unused
    if not item or not info then return end

    -- Auto-subproject: create subproject from item
    if not info.is_subproj then
        if r.ImGui_SmallButton(ctx, "Subproj##create_subproj") then
            r.Main_OnCommand(40289, 0) -- Unselect all items
            r.SetMediaItemSelected(item, true)
            r.UpdateArrange()
            r.PreventUIRefresh(1)
            r.Undo_BeginBlock()
            r.Main_OnCommand(41997, 0) -- Create subproject from selected items
            r.Undo_EndBlock("Create subproject from item", -1)
            r.PreventUIRefresh(-1)
            r.UpdateArrange()
            WF.InvalidateCache()
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Create subproject from this item")
        end
        r.ImGui_SameLine(ctx, 0, 5)
    end

    -- Glue (bounce in-place)
    if r.ImGui_SmallButton(ctx, "Glue##glue_item") then
        r.Main_OnCommand(40289, 0) -- Unselect all items
        r.SetMediaItemSelected(item, true)
        r.UpdateArrange()
        r.PreventUIRefresh(1)
        r.Undo_BeginBlock()
        r.Main_OnCommand(40362, 0) -- Item: Glue items
        r.Undo_EndBlock("Glue item", -1)
        r.PreventUIRefresh(-1)
        r.UpdateArrange()
        WF.InvalidateCache()
        editor.last_item_id = nil -- force editor reset
    end
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, "Glue item (flatten with all FX)")
    end

    -- Apply FX as new take
    if info.take_fx and #info.take_fx > 0 then
        r.ImGui_SameLine(ctx, 0, 5)
        if r.ImGui_SmallButton(ctx, "Apply FX##apply_fx") then
            r.Main_OnCommand(40289, 0) -- Unselect all items
            r.SetMediaItemSelected(item, true)
            r.UpdateArrange()
            r.PreventUIRefresh(1)
            r.Undo_BeginBlock()
            r.Main_OnCommand(40209, 0) -- Item: Apply FX to items as new take
            r.Undo_EndBlock("Apply take FX", -1)
            r.PreventUIRefresh(-1)
            r.UpdateArrange()
            WF.InvalidateCache()
            editor.last_item_id = nil
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Render take FX to new take (non-destructive)")
        end
    end

    -- Export item to file
    r.ImGui_SameLine(ctx, 0, 5)
    if r.ImGui_SmallButton(ctx, "Export##export_item") then
        r.Main_OnCommand(40289, 0) -- Unselect all items
        r.SetMediaItemSelected(item, true)
        r.UpdateArrange()
        r.PreventUIRefresh(1)
        r.Undo_BeginBlock()
        r.Main_OnCommand(41823, 0) -- Item: Render items to new file
        r.Undo_EndBlock("Export item", -1)
        r.PreventUIRefresh(-1)
        r.UpdateArrange()
    end
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, "Render item to new audio file")
    end
end

-- ============================================================================
-- MIDI PLACEHOLDER
-- ============================================================================
function DrawMidiPlaceholder()
    local avail_w = r.ImGui_GetContentRegionAvail(ctx)
    local wx2, wy2 = r.ImGui_GetCursorScreenPos(ctx)
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRectFilled(draw_list, wx2, wy2,
        wx2 + avail_w, wy2 + C.WAVEFORM_H, C.COL_WAVEFORM_BG)
    r.ImGui_DrawList_AddRect(draw_list, wx2, wy2,
        wx2 + avail_w, wy2 + C.WAVEFORM_H, 0x555555FF, 0, 0, 1.0)
    local txt = "MIDI Item"
    local tw = r.ImGui_CalcTextSize(ctx, txt)
    r.ImGui_DrawList_AddText(draw_list, wx2 + (avail_w - tw) / 2,
        wy2 + C.WAVEFORM_H / 2 - 7, 0x888888FF, txt)
    r.ImGui_Dummy(ctx, avail_w, C.WAVEFORM_H)
end

return ItemEditor
