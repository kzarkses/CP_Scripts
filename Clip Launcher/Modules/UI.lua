local UI = {}

local r, Core, Engine, ClipManager, Transport, Sequencer, Persistence, MixerOverlay, TCPOverlay
local style_loader

-- Per-track overlay contexts
local overlay_contexts = {}

-- Rename state
local rename_col = -1
local rename_clip = -1
local rename_buf = ""

-- Cross-context drag state (for dragging between overlay windows)
local drag_source_col = -1
local drag_source_clip = -1
local drag_active = false

-- On-demand ImGui contexts (created when needed, destroyed when stale)
local scene_ctx = nil
local settings_ctx = nil
local tcp_ctx = nil

function UI.init(reaper_api, core, engine, clip_manager, transport, sequencer, persistence, mixer_overlay, tcp_overlay, sl)
    r = reaper_api
    Core = core
    Engine = engine
    ClipManager = clip_manager
    Transport = transport
    Sequencer = sequencer
    Persistence = persistence
    MixerOverlay = mixer_overlay
    TCPOverlay = tcp_overlay
    style_loader = sl

    UI.state = {
        show_settings = false,  -- main window hidden by default
    }
end

local function ApplyStyle(ctx)
    if style_loader then
        return style_loader.ApplyToContext(ctx)
    end
    return false, 0, 0
end

local function ClearStyle(ctx, colors, vars)
    if style_loader then
        style_loader.ClearStyles(ctx, colors, vars)
    end
end

-- ============================================================
-- TRANSPORT BAR
-- ============================================================

local function drawTransportBar(ctx)
    local ts = Transport.state

    local play_label = ts.is_playing and "PLAYING" or "STOPPED"
    r.ImGui_Text(ctx, string.format("%s | %s | %.0f BPM | %d/%d",
        play_label, Transport.formatPosition(), ts.tempo, ts.time_sig_num, ts.time_sig_denom))

    r.ImGui_SameLine(ctx)

    -- Quantize mode
    r.ImGui_SetNextItemWidth(ctx, 70)
    local changed, new_val = r.ImGui_Combo(ctx, "##quantize", Core.state.quantize_mode,
        "Free\0Beat\0Bar\0")
    if changed then
        Core.state.quantize_mode = new_val
    end

    r.ImGui_SameLine(ctx)

    -- Stop all
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xCC3333FF)
    if r.ImGui_Button(ctx, "STOP ALL") then
        Engine.stopAll()
    end
    r.ImGui_PopStyleColor(ctx, 1)

    -- Loading indicator
    if Engine.isLoading() then
        r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, 0xF39C12FF, Engine.getLoadingText() or "Loading...")
    end
end

-- ============================================================
-- CLIP SLOT (shared between standalone and overlay)
-- ============================================================

local function loadClipDialog(column_index, clip_index)
    local retval, filename = r.JS_Dialog_BrowseForOpenFiles(
        "Load Audio Clip", "", "",
        "Audio Files\0*.wav;*.mp3;*.ogg;*.flac;*.aif;*.aiff\0All Files\0*.*\0",
        false)
    if retval == 1 and filename and filename ~= "" then
        ClipManager.loadClip(column_index, clip_index, filename, Engine)
    end
end

local function drawClipSlot(ctx, column_index, clip_index, slot_width, slot_height)
    local column = Core.state.columns[column_index]
    if not column then return end

    local clip = column.clips[clip_index]
    local is_loaded = clip and clip.loaded
    local is_transferring = clip and clip.transferring
    local is_playing = column.playing_clip == clip_index
    local is_pending = column.pending_clip == clip_index
    local is_recording = column.is_recording and column.recording_clip == clip_index
    local is_renaming = rename_col == column_index and rename_clip == clip_index

    -- Layout: [action_btn][clip_btn]
    local spacing = 2
    local action_w = math.max(16, slot_height)
    local clip_w = slot_width - action_w - spacing

    -- Slot color for clip button
    local bg_color = Core.config.colors.empty_slot
    if is_transferring then
        bg_color = 0x4A3A1AFF
    elseif is_recording then
        bg_color = 0xFF000080
    elseif is_playing then
        bg_color = Core.config.colors.playing_slot
    elseif is_pending then
        bg_color = Core.config.colors.pending_slot
    elseif is_loaded then
        local track_color = Core.getTrackColor(column.track)
        if track_color then
            local r_val = ((track_color >> 24) & 0xFF)
            local g_val = ((track_color >> 16) & 0xFF)
            local b_val = ((track_color >> 8) & 0xFF)
            r_val = math.floor(r_val * 0.3)
            g_val = math.floor(g_val * 0.3)
            b_val = math.floor(b_val * 0.3)
            bg_color = (r_val << 24) | (g_val << 16) | (b_val << 8) | 0xFF
        else
            bg_color = Core.config.colors.loaded_slot
        end
    end

    -- Action button (left): invisible button + DrawList icon
    local action_color
    if is_recording then
        action_color = 0x333333FF
    elseif is_playing then
        action_color = 0x333333FF
    elseif is_loaded and not is_transferring then
        action_color = 0x333333FF
    else
        action_color = 0x222222FF
    end

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), action_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), action_color + 0x1A1A1A00)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), action_color + 0x33333300)

    local action_id = string.format("##act_%d_%d", column_index, clip_index)
    local launch_mode = column.launch_mode or Core.LAUNCH_TRIGGER
    local btn_pressed = r.ImGui_Button(ctx, action_id, action_w, slot_height)
    local btn_active = r.ImGui_IsItemActive(ctx)

    if launch_mode == Core.LAUNCH_GATE then
        -- Gate: play while pressed, stop on release
        if is_loaded and not is_transferring and not is_recording then
            if btn_active and not is_playing then
                Engine.playClip(column_index, clip_index)
            elseif not btn_active and is_playing and column.playing_clip == clip_index then
                Engine.stopColumn(column_index)
            end
        elseif is_recording and btn_pressed then
            Engine.stopRecording(column_index)
        elseif not is_loaded and not is_recording and btn_pressed then
            Engine.startRecording(column_index, clip_index)
        end
    elseif launch_mode == Core.LAUNCH_TOGGLE then
        -- Toggle: click = play, click again = stop
        if btn_pressed then
            if is_recording then
                Engine.stopRecording(column_index)
            elseif is_playing and column.playing_clip == clip_index then
                Engine.stopColumn(column_index)
            elseif is_loaded and not is_transferring then
                Engine.playClip(column_index, clip_index)
            else
                Engine.startRecording(column_index, clip_index)
            end
        end
    else
        -- Trigger (default): click = play/restart
        if btn_pressed then
            if is_recording then
                Engine.stopRecording(column_index)
            elseif is_playing then
                Engine.stopColumn(column_index)
            elseif is_loaded and not is_transferring then
                Engine.playClip(column_index, clip_index)
            else
                Engine.startRecording(column_index, clip_index)
            end
        end
    end

    r.ImGui_PopStyleColor(ctx, 3)

    -- Draw icon on top of action button using DrawList
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local ax1, ay1 = r.ImGui_GetItemRectMin(ctx)
    local ax2, ay2 = r.ImGui_GetItemRectMax(ctx)
    local acx = (ax1 + ax2) * 0.5
    local acy = (ay1 + ay2) * 0.5
    local icon_size = math.min(ax2 - ax1, ay2 - ay1) * 0.3

    if is_recording then
        -- Stop icon: filled square (white)
        local sq = icon_size * 0.8
        r.ImGui_DrawList_AddRectFilled(draw_list,
            acx - sq, acy - sq, acx + sq, acy + sq, 0xFFFFFFFF)
    elseif is_playing then
        -- Stop icon: filled square (white)
        local sq = icon_size * 0.8
        r.ImGui_DrawList_AddRectFilled(draw_list,
            acx - sq, acy - sq, acx + sq, acy + sq, 0xFFFFFFFF)
    elseif is_loaded and not is_transferring then
        -- Play icon: filled triangle pointing right (green)
        r.ImGui_DrawList_AddTriangleFilled(draw_list,
            acx - icon_size * 0.7, acy - icon_size,
            acx - icon_size * 0.7, acy + icon_size,
            acx + icon_size, acy,
            0x1ABC98FF)
    else
        -- Record icon: filled circle (red)
        r.ImGui_DrawList_AddCircleFilled(draw_list,
            acx, acy, icon_size, 0xCC3333FF, 16)
    end

    r.ImGui_SameLine(ctx, 0, spacing)

    -- Clip button (right): name / load / rename
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), bg_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), bg_color + 0x1A1A1A00)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), bg_color + 0x33333300)

    -- Rename mode
    if is_renaming then
        r.ImGui_PopStyleColor(ctx, 3)
        r.ImGui_SetNextItemWidth(ctx, clip_w)
        r.ImGui_SetKeyboardFocusHere(ctx)
        local changed, new_val = r.ImGui_InputText(ctx,
            string.format("##rename_%d_%d", column_index, clip_index),
            rename_buf, r.ImGui_InputTextFlags_EnterReturnsTrue() | r.ImGui_InputTextFlags_AutoSelectAll())
        if changed then
            if new_val ~= "" then
                clip.name = new_val
            end
            rename_col = -1
            rename_clip = -1
        elseif not r.ImGui_IsItemActive(ctx) and r.ImGui_IsItemDeactivated(ctx) then
            rename_col = -1
            rename_clip = -1
        end
        return
    end

    local label
    if is_transferring then
        label = "..."
    elseif is_recording then
        local out_srate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 44100
        if out_srate == 0 then out_srate = 44100 end
        local rec_sec = column.recording_samples / out_srate
        label = string.format("REC %.1fs", rec_sec)
    elseif is_loaded then
        label = clip.name
    else
        label = ""
    end

    local button_id = string.format("%s##clip_%d_%d", label, column_index, clip_index)
    if r.ImGui_Button(ctx, button_id, clip_w, slot_height) then
        if not is_loaded and not is_recording then
            loadClipDialog(column_index, clip_index)
        end
    end

    -- Double-click to rename
    if is_loaded and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, r.ImGui_MouseButton_Left()) then
        rename_col = column_index
        rename_clip = clip_index
        rename_buf = clip.name
    end

    -- Cross-context drag: start dragging (left mouse held on loaded clip)
    if is_loaded and clip.file_path and not is_transferring and not is_recording then
        if r.ImGui_IsItemActive(ctx) and r.ImGui_IsMouseDragging(ctx, r.ImGui_MouseButton_Left()) then
            drag_source_col = column_index
            drag_source_clip = clip_index
            drag_active = true
        end
    end

    -- Cross-context drag: highlight target + drop on release
    local is_drag_target = drag_active and r.ImGui_IsItemHovered(ctx, r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
        and (drag_source_col ~= column_index or drag_source_clip ~= clip_index)
    if is_drag_target then
        -- Highlight drop target
        local tx1, ty1 = r.ImGui_GetItemRectMin(ctx)
        local tx2, ty2 = r.ImGui_GetItemRectMax(ctx)
        r.ImGui_DrawList_AddRect(draw_list, tx1, ty1, tx2, ty2, 0x1ABC98FF, 0, 0, 2)
    end

    -- External file drop (still uses ImGui DragDrop for OS-level drops)
    if r.ImGui_BeginDragDropTarget(ctx) then
        local rv_file, count = r.ImGui_AcceptDragDropPayloadFiles(ctx)
        if rv_file then
            for fi = 0, count - 1 do
                local _, filepath = r.ImGui_GetDragDropPayloadFile(ctx, fi)
                if filepath and filepath ~= "" then
                    local target_clip = clip_index + fi
                    if target_clip <= Core.MAX_CLIPS_PER_COLUMN then
                        ClipManager.loadClip(column_index, target_clip, filepath, Engine)
                    end
                end
            end
        end
        r.ImGui_EndDragDropTarget(ctx)
    end

    -- Right-click menu on clip button
    if r.ImGui_IsItemClicked(ctx, r.ImGui_MouseButton_Right()) then
        r.ImGui_OpenPopup(ctx, string.format("clip_menu_%d_%d", column_index, clip_index))
    end

    if r.ImGui_BeginPopup(ctx, string.format("clip_menu_%d_%d", column_index, clip_index)) then
        if is_loaded then
            if r.ImGui_MenuItem(ctx, "Play (one-shot)") then
                Engine.playClip(column_index, clip_index, Core.PLAY_ONESHOT)
            end
            if r.ImGui_MenuItem(ctx, "Play (loop)") then
                Engine.playClip(column_index, clip_index, Core.PLAY_LOOP)
            end
            r.ImGui_Separator(ctx)

            if r.ImGui_MenuItem(ctx, "Rename") then
                rename_col = column_index
                rename_clip = clip_index
                rename_buf = clip.name
            end

            -- Probability slider
            local prob = column.probabilities[clip_index] or 1.0
            r.ImGui_SetNextItemWidth(ctx, 100)
            local prob_changed, new_prob = r.ImGui_SliderDouble(ctx, "Prob##" .. clip_index, prob * 100, 0, 100, "%.0f%%")
            if prob_changed then
                Sequencer.setProbability(column_index, clip_index, new_prob / 100)
            end

            -- Follow action submenu
            if r.ImGui_BeginMenu(ctx, "Follow Action") then
                local actions = {
                    { Core.FOLLOW_NONE, "None" },
                    { Core.FOLLOW_NEXT, "Next" },
                    { Core.FOLLOW_PREV, "Previous" },
                    { Core.FOLLOW_FIRST, "First" },
                    { Core.FOLLOW_LAST, "Last" },
                    { Core.FOLLOW_RANDOM, "Random" },
                    { Core.FOLLOW_STOP, "Stop" },
                }
                for _, a in ipairs(actions) do
                    if r.ImGui_MenuItem(ctx, a[2], nil, clip.follow_action == a[1]) then
                        clip.follow_action = a[1]
                        Core.state.dirty = true
                    end
                end
                r.ImGui_Separator(ctx)
                r.ImGui_SetNextItemWidth(ctx, 80)
                local fc, fv = r.ImGui_SliderInt(ctx, "Loops##fa", clip.follow_count, 1, 16)
                if fc then
                    clip.follow_count = fv
                    Core.state.dirty = true
                end
                r.ImGui_EndMenu(ctx)
            end

            r.ImGui_Separator(ctx)
            if r.ImGui_MenuItem(ctx, "Remove clip") then
                ClipManager.unloadClip(column_index, clip_index)
            end
        else
            if r.ImGui_MenuItem(ctx, "Load clip...") then
                loadClipDialog(column_index, clip_index)
            end

            -- Capture from selected item in arrangement
            local sel_item = r.GetSelectedMediaItem(0, 0)
            if sel_item then
                local take = r.GetActiveTake(sel_item)
                local item_name = "selected item"
                if take then
                    local _, tname = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                    if tname and tname ~= "" then item_name = tname end
                end
                if r.ImGui_MenuItem(ctx, "Capture: " .. item_name) then
                    ClipManager.loadFromItem(column_index, clip_index, sel_item, Engine)
                end
            end
        end
        r.ImGui_EndPopup(ctx)
    end

    r.ImGui_PopStyleColor(ctx, 3)

    -- Progress bar overlay
    if is_playing and is_loaded then
        local progress = Engine.getPlaybackProgress(column_index)
        local ix, iy = r.ImGui_GetItemRectMin(ctx)
        local iw, ih = r.ImGui_GetItemRectMax(ctx)
        r.ImGui_DrawList_AddRectFilled(draw_list, ix, ih - 3, ix + (iw - ix) * progress, ih, 0x1ABC98FF)
    end
end

-- ============================================================
-- COLUMN CONTEXT MENU (right-click on column title)
-- ============================================================

local function drawColumnContextMenu(ctx, column_index)
    local column = Core.state.columns[column_index]
    if not column then return end

    local popup_id = string.format("col_ctx_%d", column_index)

    if r.ImGui_BeginPopup(ctx, popup_id) then
        -- Play mode
        if r.ImGui_MenuItem(ctx, "One-shot mode", nil, column.play_mode == Core.PLAY_ONESHOT) then
            column.play_mode = Core.PLAY_ONESHOT
        end
        if r.ImGui_MenuItem(ctx, "Loop mode", nil, column.play_mode == Core.PLAY_LOOP) then
            column.play_mode = Core.PLAY_LOOP
        end

        r.ImGui_Separator(ctx)

        -- Launch mode
        local launch_labels = { "Trigger", "Gate", "Toggle" }
        local launch_modes = { Core.LAUNCH_TRIGGER, Core.LAUNCH_GATE, Core.LAUNCH_TOGGLE }
        for li, lm in ipairs(launch_modes) do
            if r.ImGui_MenuItem(ctx, launch_labels[li], nil, column.launch_mode == lm) then
                column.launch_mode = lm
                Core.state.dirty = true
            end
        end

        r.ImGui_Separator(ctx)

        -- Volume
        r.ImGui_SetNextItemWidth(ctx, 120)
        local vc, vv = r.ImGui_SliderDouble(ctx,
            string.format("Vol##cv_%d", column_index), column.volume * 100, 0, 100, "Vol: %.0f%%")
        if vc then column.volume = vv / 100 end

        r.ImGui_Separator(ctx)

        -- Sequencer
        local seq_label = column.sequencer_enabled and "Sequencer (ON)" or "Sequencer (OFF)"
        if r.ImGui_MenuItem(ctx, seq_label) then
            Sequencer.toggle(column_index)
        end

        if column.sequencer_enabled then
            r.ImGui_SetNextItemWidth(ctx, 120)
            local c1, v1 = r.ImGui_SliderDouble(ctx,
                string.format("##int_min_%d", column_index),
                column.sequencer_interval_min, 0.25, 16, "Min: %.1f b")
            if c1 then Sequencer.setInterval(column_index, v1, column.sequencer_interval_max) end

            r.ImGui_SetNextItemWidth(ctx, 120)
            local c2, v2 = r.ImGui_SliderDouble(ctx,
                string.format("##int_max_%d", column_index),
                column.sequencer_interval_max, 0.25, 16, "Max: %.1f b")
            if c2 then Sequencer.setInterval(column_index, column.sequencer_interval_min, v2) end
        end

        r.ImGui_Separator(ctx)

        -- Record
        if column.is_recording then
            local out_srate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 44100
            if out_srate == 0 then out_srate = 44100 end
            local rec_sec = column.recording_samples / out_srate
            if r.ImGui_MenuItem(ctx, string.format("Stop Recording (%.1fs)", rec_sec)) then
                Engine.stopRecording(column_index)
            end
        else
            if r.ImGui_MenuItem(ctx, "Record") then
                local slot = Engine.findEmptySlot(column_index)
                if slot then
                    Engine.startRecording(column_index, slot)
                end
            end
        end

        r.ImGui_EndPopup(ctx)
    end
end

-- ============================================================
-- OVERLAY COLUMN (compact, for mixer strip)
-- ============================================================

local function drawOverlayColumn(ctx, column_index, strip_w, strip_h)
    local column = Core.state.columns[column_index]
    if not column then return end

    local padding = 2
    local slot_width = strip_w - padding * 2
    local available_h = strip_h - padding * 2

    -- Calculate slot height: fit header row + clips only
    local header_h = 18
    local spacing = 2
    local clips_h = available_h - header_h - spacing
    local slot_height = math.max(16, math.floor((clips_h - spacing * (Core.MAX_CLIPS_PER_COLUMN - 1)) / Core.MAX_CLIPS_PER_COLUMN))

    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), spacing, spacing)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 2, 1)

    -- Header: track name (colored) + stop button (only when playing/recording)
    local track_name = Core.getTrackName(column.track)
    local track_color = Core.getTrackColor(column.track)
    local is_playing = column.playing_clip >= 1
    local is_recording = column.is_recording
    local seq_on = column.sequencer_enabled

    -- Determine how much space the title gets
    local stop_btn_w = 0
    local indicators = {}
    if is_playing or is_recording then
        stop_btn_w = 20
    end
    -- Build indicator string for seq/rec
    if seq_on then indicators[#indicators + 1] = "S" end
    if is_recording then indicators[#indicators + 1] = "R" end

    -- Title (clickable for context menu)
    local title_w = slot_width - (stop_btn_w > 0 and (stop_btn_w + spacing) or 0)

    if track_color then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), track_color)
    end

    -- Truncate title to fit
    local display_name = track_name
    if #indicators > 0 then
        display_name = table.concat(indicators, "") .. " " .. track_name
    end

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0xFFFFFF15)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0xFFFFFF25)
    r.ImGui_Button(ctx, string.format("%s##title_%d", display_name, column_index), title_w, header_h)
    r.ImGui_PopStyleColor(ctx, 3)

    -- Right-click on title opens context menu
    if r.ImGui_IsItemClicked(ctx, r.ImGui_MouseButton_Right()) then
        r.ImGui_OpenPopup(ctx, string.format("col_ctx_%d", column_index))
    end

    if track_color then
        r.ImGui_PopStyleColor(ctx, 1)
    end

    -- Stop button (only when playing or recording)
    if stop_btn_w > 0 then
        r.ImGui_SameLine(ctx)
        local stop_color = is_recording and 0xFF0000FF or 0xCC3333FF
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), stop_color)
        if r.ImGui_Button(ctx, string.format("X##stop_%d", column_index), stop_btn_w, header_h) then
            if is_recording then
                Engine.stopRecording(column_index)
            else
                Engine.stopColumn(column_index)
            end
        end
        r.ImGui_PopStyleColor(ctx, 1)
    end

    -- Column context menu
    drawColumnContextMenu(ctx, column_index)

    -- Clip slots
    for clip_idx = 1, Core.MAX_CLIPS_PER_COLUMN do
        drawClipSlot(ctx, column_index, clip_idx, slot_width, slot_height)
    end

    -- Beat/bar counter at bottom
    if is_recording then
        local out_srate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 44100
        if out_srate == 0 then out_srate = 44100 end
        local rec_sec = column.recording_samples / out_srate
        local min = math.floor(rec_sec / 60)
        local sec = rec_sec - min * 60
        r.ImGui_TextColored(ctx, 0xFF4444FF, string.format("%d:%04.1f", min, sec))
    elseif column.clip_bar and column.clip_beat then
        r.ImGui_TextColored(ctx, 0x1ABC98FF, string.format("%d.%d", column.clip_bar, column.clip_beat))
    end

    r.ImGui_PopStyleVar(ctx, 2)
end

-- ============================================================
-- GET/CREATE OVERLAY CONTEXT
-- ============================================================

local function getOverlayContext(column_index)
    local key = "overlay_" .. column_index
    local ctx = overlay_contexts[key]
    -- Validate existing context (may be stale from previous script run)
    if ctx and not r.ValidatePtr(ctx, "ImGui_Context*") then
        overlay_contexts[key] = nil
        ctx = nil
    end
    if not ctx then
        ctx = r.ImGui_CreateContext("CL_Overlay_" .. column_index)
        overlay_contexts[key] = ctx
    end
    return ctx
end

-- ============================================================
-- DRAW MIXER OVERLAYS
-- ============================================================

-- Process cross-context drag drop (called after all overlays rendered)
local function processCrossDrag()
    if not drag_active then return end

    -- Mouse released: check if we have a pending drop target
    if not r.GetMouseState then
        -- Fallback: use JS_Mouse if available, otherwise check each frame
        drag_active = false
        return
    end

    -- Check if left mouse is still held (bit 1)
    local mouse_state = r.JS_Mouse_GetState(1)
    if mouse_state == 0 then
        -- Mouse released — find which slot the mouse is over
        local mx, my = r.GetMousePosition()
        if drag_source_col >= 1 then
            local positions = MixerOverlay.getOverlayPositions()
            for col_idx, pos in pairs(positions) do
                if mx >= pos.x and mx < pos.x + pos.w and my >= pos.y and my < pos.y + pos.h then
                    -- Determine which clip slot based on Y position
                    local header_h = 18
                    local spacing = 2
                    local clips_h = pos.h - header_h - spacing
                    local slot_h = math.max(16, math.floor((clips_h - spacing * (Core.MAX_CLIPS_PER_COLUMN - 1)) / Core.MAX_CLIPS_PER_COLUMN))
                    local rel_y = my - pos.y - header_h - spacing
                    local target_clip = math.floor(rel_y / (slot_h + spacing)) + 1
                    target_clip = math.max(1, math.min(Core.MAX_CLIPS_PER_COLUMN, target_clip))

                    if col_idx ~= drag_source_col or target_clip ~= drag_source_clip then
                        local src_column = Core.state.columns[drag_source_col]
                        local src_clip = src_column and src_column.clips[drag_source_clip]
                        if src_clip and src_clip.file_path then
                            local file = src_clip.file_path
                            local name = src_clip.name
                            ClipManager.unloadClip(drag_source_col, drag_source_clip)
                            ClipManager.loadClip(col_idx, target_clip, file, Engine)
                            local dst_column = Core.state.columns[col_idx]
                            local dst_clip = dst_column and dst_column.clips[target_clip]
                            if dst_clip then dst_clip.name = name end
                        end
                    end
                    break
                end
            end
        end
        drag_active = false
        drag_source_col = -1
        drag_source_clip = -1
    end
end

local function drawMixerOverlays()
    if not MixerOverlay then return end

    local positions = MixerOverlay.getOverlayPositions()

    local overlay_flags = r.ImGui_WindowFlags_NoTitleBar()
        | r.ImGui_WindowFlags_NoResize()
        | r.ImGui_WindowFlags_NoMove()
        | r.ImGui_WindowFlags_NoScrollbar()
        | r.ImGui_WindowFlags_NoScrollWithMouse()
        | r.ImGui_WindowFlags_NoCollapse()
        | r.ImGui_WindowFlags_NoDocking()
        | r.ImGui_WindowFlags_NoFocusOnAppearing()
        | r.ImGui_WindowFlags_TopMost()

    for col_idx, pos in pairs(positions) do
        local ok = pcall(function()
            local ctx = getOverlayContext(col_idx)

            -- Convert screen coords to ImGui coords (handles DPI scaling)
            local imgui_x, imgui_y = MixerOverlay.convertToImGui(ctx, pos.x, pos.y)
            local imgui_r, imgui_b = MixerOverlay.convertToImGui(ctx, pos.x + pos.w, pos.y + pos.h)
            local imgui_w = imgui_r - imgui_x
            local imgui_h = imgui_b - imgui_y

            r.ImGui_SetNextWindowPos(ctx, imgui_x, imgui_y, r.ImGui_Cond_Always())
            r.ImGui_SetNextWindowSize(ctx, imgui_w, imgui_h, r.ImGui_Cond_Always())

            -- Semi-transparent background
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), 0x1E1E1EB0)
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), 2, 2)
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), 0)

            local visible, _ = r.ImGui_Begin(ctx, "##overlay_" .. col_idx, nil, overlay_flags)
            if visible then
                pcall(drawOverlayColumn, ctx, col_idx, imgui_w, imgui_h)
                r.ImGui_End(ctx)
            end

            r.ImGui_PopStyleVar(ctx, 2)
            r.ImGui_PopStyleColor(ctx, 1)
        end)
        if not ok then
            overlay_contexts["overlay_" .. col_idx] = nil
        end
    end
end

-- ============================================================
-- SCENE OVERLAY (snapped to right of mixer)
-- ============================================================

local function getSceneContext()
    if scene_ctx and not r.ValidatePtr(scene_ctx, "ImGui_Context*") then
        scene_ctx = nil
    end
    if not scene_ctx then
        scene_ctx = r.ImGui_CreateContext("CL_Scenes")
    end
    return scene_ctx
end

local function drawSceneOverlay()
    if not MixerOverlay then return end

    local pos = MixerOverlay.getSceneColumnPosition()
    if not pos then return end

    local ctx = getSceneContext()
    if not ctx then return end

    local ok = pcall(function()
        local imgui_x, imgui_y = MixerOverlay.convertToImGui(ctx, pos.x, pos.y)
        local imgui_r, imgui_b = MixerOverlay.convertToImGui(ctx, pos.x + pos.w, pos.y + pos.h)
        local imgui_w = imgui_r - imgui_x
        local imgui_h = imgui_b - imgui_y

        r.ImGui_SetNextWindowPos(ctx, imgui_x, imgui_y, r.ImGui_Cond_Always())
        r.ImGui_SetNextWindowSize(ctx, imgui_w, imgui_h, r.ImGui_Cond_Always())

        local overlay_flags = r.ImGui_WindowFlags_NoTitleBar()
            | r.ImGui_WindowFlags_NoResize()
            | r.ImGui_WindowFlags_NoMove()
            | r.ImGui_WindowFlags_NoScrollbar()
            | r.ImGui_WindowFlags_NoScrollWithMouse()
            | r.ImGui_WindowFlags_NoCollapse()
            | r.ImGui_WindowFlags_NoDocking()
            | r.ImGui_WindowFlags_NoFocusOnAppearing()
            | r.ImGui_WindowFlags_TopMost()

        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), 0x1E1E1EB0)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), 2, 2)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), 0)

        local visible = r.ImGui_Begin(ctx, "##scenes", nil, overlay_flags)
        if visible then
            pcall(function()
                local padding = 2
                local spacing = 2
                local btn_w = imgui_w - padding * 2
                local header_h = 18

                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), spacing, spacing)
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 2, 1)

                -- Header: "SCENES" (right-click for exit)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x00000000)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0xFFFFFF15)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0xFFFFFF25)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAFF)
                r.ImGui_Button(ctx, "SCENES##hdr", btn_w, header_h)
                r.ImGui_PopStyleColor(ctx, 4)

                if r.ImGui_IsItemClicked(ctx, r.ImGui_MouseButton_Right()) then
                    r.ImGui_OpenPopup(ctx, "scene_menu")
                end
                if r.ImGui_BeginPopup(ctx, "scene_menu") then
                    pcall(function()
                        if r.ImGui_MenuItem(ctx, "Settings") then
                            UI.state.show_settings = not UI.state.show_settings
                        end
                        r.ImGui_Separator(ctx)
                        if r.ImGui_MenuItem(ctx, "Exit Clip Launcher") then
                            Core.state.is_running = false
                        end
                    end)
                    r.ImGui_EndPopup(ctx)
                end

                -- Calculate slot height (same logic as overlay columns)
                local clips_h = imgui_h - padding * 2 - header_h - spacing
                local bottom_btns = 2
                local bottom_h = (header_h + spacing) * bottom_btns
                clips_h = clips_h - bottom_h
                local slot_height = math.max(16, math.floor((clips_h - spacing * (Core.MAX_CLIPS_PER_COLUMN - 1)) / Core.MAX_CLIPS_PER_COLUMN))

                -- Scene buttons 1-8
                for scene = 1, Core.MAX_CLIPS_PER_COLUMN do
                    local scene_active = false
                    for _, column in ipairs(Core.state.columns) do
                        if column.playing_clip == scene then
                            scene_active = true
                            break
                        end
                    end

                    local btn_color = scene_active and 0x1ABC9880 or 0x333333FF
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), btn_color)
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), btn_color + 0x1A1A1A00)
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), btn_color + 0x33333300)

                    if r.ImGui_Button(ctx, string.format("%d##scene", scene), btn_w, slot_height) then
                        Engine.launchScene(scene)
                    end

                    r.ImGui_PopStyleColor(ctx, 3)
                end

                -- STOP button
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xCC3333FF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0xDD4444FF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0xFF5555FF)
                if r.ImGui_Button(ctx, "STOP##sc", btn_w, header_h) then
                    Engine.stopScene()
                end
                r.ImGui_PopStyleColor(ctx, 3)

                -- Settings button
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x444444FF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x555555FF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x666666FF)
                if r.ImGui_Button(ctx, "SET##settings", btn_w, header_h) then
                    UI.state.show_settings = not UI.state.show_settings
                end
                r.ImGui_PopStyleColor(ctx, 3)

                r.ImGui_PopStyleVar(ctx, 2)
            end)
            r.ImGui_End(ctx)
        end

        r.ImGui_PopStyleVar(ctx, 2)
        r.ImGui_PopStyleColor(ctx, 1)
    end)
    if not ok then
        scene_ctx = nil
    end
end

-- ============================================================
-- TCP OVERLAY (single-context, horizontal layout)
-- ============================================================

local function getTCPContext()
    if tcp_ctx and not r.ValidatePtr(tcp_ctx, "ImGui_Context*") then
        tcp_ctx = nil
    end
    if not tcp_ctx then
        tcp_ctx = r.ImGui_CreateContext("CL_TCP")
    end
    return tcp_ctx
end

-- Draw a horizontal clip slot (for TCP layout)
local function drawTCPClipSlot(ctx, column_index, clip_index, slot_w, slot_h)
    local column = Core.state.columns[column_index]
    if not column then return end

    local clip = column.clips[clip_index]
    local is_loaded = clip and clip.loaded
    local is_transferring = clip and clip.transferring
    local is_playing = column.playing_clip == clip_index
    local is_pending = column.pending_clip == clip_index
    local is_recording = column.is_recording and column.recording_clip == clip_index

    -- Slot color
    local bg_color = Core.config.colors.empty_slot
    if is_transferring then
        bg_color = 0x4A3A1AFF
    elseif is_recording then
        bg_color = 0xFF000080
    elseif is_playing then
        bg_color = Core.config.colors.playing_slot
    elseif is_pending then
        bg_color = Core.config.colors.pending_slot
    elseif is_loaded then
        local track_color = Core.getTrackColor(column.track)
        if track_color then
            local r_val = ((track_color >> 24) & 0xFF)
            local g_val = ((track_color >> 16) & 0xFF)
            local b_val = ((track_color >> 8) & 0xFF)
            r_val = math.floor(r_val * 0.3)
            g_val = math.floor(g_val * 0.3)
            b_val = math.floor(b_val * 0.3)
            bg_color = (r_val << 24) | (g_val << 16) | (b_val << 8) | 0xFF
        else
            bg_color = Core.config.colors.loaded_slot
        end
    end

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), bg_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), bg_color + 0x1A1A1A00)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), bg_color + 0x33333300)

    -- Button label: icon char or short name
    local label
    if is_recording then
        label = "R"
    elseif is_playing then
        label = "||"  -- stop icon
    elseif is_loaded and not is_transferring then
        label = ">"   -- play icon
    else
        label = ""
    end

    local btn_id = string.format("%s##tcp_%d_%d", label, column_index, clip_index)
    if r.ImGui_Button(ctx, btn_id, slot_w, slot_h) then
        if is_recording then
            Engine.stopRecording(column_index)
        elseif is_playing then
            Engine.stopColumn(column_index)
        elseif is_loaded and not is_transferring then
            Engine.playClip(column_index, clip_index)
        elseif not is_loaded then
            loadClipDialog(column_index, clip_index)
        end
    end

    -- Drag source (for intra-context drag & drop)
    if is_loaded and clip.file_path and not is_transferring and not is_recording then
        if r.ImGui_BeginDragDropSource(ctx) then
            r.ImGui_SetDragDropPayload(ctx, "DND_CLIP", string.format("%d,%d", column_index, clip_index))
            r.ImGui_Text(ctx, clip.name)
            r.ImGui_EndDragDropSource(ctx)
        end
    end

    -- Drop target
    if r.ImGui_BeginDragDropTarget(ctx) then
        -- Internal clip move
        local rv, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND_CLIP")
        if rv then
            local src_col, src_clip = payload:match("(%d+),(%d+)")
            src_col = tonumber(src_col)
            src_clip = tonumber(src_clip)
            if src_col and src_clip and (src_col ~= column_index or src_clip ~= clip_index) then
                local src_column = Core.state.columns[src_col]
                local src_c = src_column and src_column.clips[src_clip]
                if src_c and src_c.file_path then
                    local file = src_c.file_path
                    local name = src_c.name
                    ClipManager.unloadClip(src_col, src_clip)
                    ClipManager.loadClip(column_index, clip_index, file, Engine)
                    local dst_column = Core.state.columns[column_index]
                    local dst_clip = dst_column and dst_column.clips[clip_index]
                    if dst_clip then dst_clip.name = name end
                end
            end
        end
        -- External file drop
        local rv_file, count = r.ImGui_AcceptDragDropPayloadFiles(ctx)
        if rv_file then
            for fi = 0, count - 1 do
                local _, filepath = r.ImGui_GetDragDropPayloadFile(ctx, fi)
                if filepath and filepath ~= "" then
                    local target_clip = clip_index + fi
                    if target_clip <= Core.MAX_CLIPS_PER_COLUMN then
                        ClipManager.loadClip(column_index, target_clip, filepath, Engine)
                    end
                end
            end
        end
        r.ImGui_EndDragDropTarget(ctx)
    end

    -- Right-click context menu
    if r.ImGui_IsItemClicked(ctx, r.ImGui_MouseButton_Right()) then
        r.ImGui_OpenPopup(ctx, string.format("tcp_clip_%d_%d", column_index, clip_index))
    end

    if r.ImGui_BeginPopup(ctx, string.format("tcp_clip_%d_%d", column_index, clip_index)) then
        if is_loaded then
            if r.ImGui_MenuItem(ctx, "Play (one-shot)") then
                Engine.playClip(column_index, clip_index, Core.PLAY_ONESHOT)
            end
            if r.ImGui_MenuItem(ctx, "Play (loop)") then
                Engine.playClip(column_index, clip_index, Core.PLAY_LOOP)
            end
            r.ImGui_Separator(ctx)
            if r.ImGui_MenuItem(ctx, "Remove clip") then
                ClipManager.unloadClip(column_index, clip_index)
            end
        else
            if r.ImGui_MenuItem(ctx, "Load clip...") then
                loadClipDialog(column_index, clip_index)
            end
            local sel_item = r.GetSelectedMediaItem(0, 0)
            if sel_item then
                local take = r.GetActiveTake(sel_item)
                local item_name = "selected item"
                if take then
                    local _, tname = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                    if tname and tname ~= "" then item_name = tname end
                end
                if r.ImGui_MenuItem(ctx, "Capture: " .. item_name) then
                    ClipManager.loadFromItem(column_index, clip_index, sel_item, Engine)
                end
            end
        end
        r.ImGui_EndPopup(ctx)
    end

    r.ImGui_PopStyleColor(ctx, 3)

    -- Vertical progress bar (bottom to top)
    if is_playing and is_loaded then
        local progress = Engine.getPlaybackProgress(column_index)
        local draw_list = r.ImGui_GetWindowDrawList(ctx)
        local ix, iy = r.ImGui_GetItemRectMin(ctx)
        local _, ih = r.ImGui_GetItemRectMax(ctx)
        local bar_h = (ih - iy) * progress
        r.ImGui_DrawList_AddRectFilled(draw_list, ix, ih - bar_h, ix + 3, ih, 0x1ABC98FF)
    end
end

-- Draw a full horizontal clip row for a track
local function drawTCPClipRow(ctx, column_index, row_w, row_h)
    local column = Core.state.columns[column_index]
    if not column then return end

    local spacing = 2
    local header_w = 20
    local clips_w = row_w - header_w - spacing
    local slot_w = math.max(12, math.floor((clips_w - spacing * (Core.MAX_CLIPS_PER_COLUMN - 1)) / Core.MAX_CLIPS_PER_COLUMN))
    local slot_h = row_h

    -- Header: stop button (small)
    local is_playing = column.playing_clip >= 1
    local is_recording = column.is_recording

    local hdr_color = (is_playing or is_recording) and 0xCC3333FF or 0x222222FF
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), hdr_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), hdr_color + 0x1A1A1A00)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), hdr_color + 0x33333300)

    local hdr_label = (is_playing or is_recording) and "X" or ""
    if r.ImGui_Button(ctx, string.format("%s##tcp_hdr_%d", hdr_label, column_index), header_w, slot_h) then
        if is_recording then
            Engine.stopRecording(column_index)
        elseif is_playing then
            Engine.stopColumn(column_index)
        end
    end
    r.ImGui_PopStyleColor(ctx, 3)

    -- Right-click on header for column context menu
    if r.ImGui_IsItemClicked(ctx, r.ImGui_MouseButton_Right()) then
        r.ImGui_OpenPopup(ctx, string.format("tcp_col_%d", column_index))
    end
    if r.ImGui_BeginPopup(ctx, string.format("tcp_col_%d", column_index)) then
        if r.ImGui_MenuItem(ctx, "One-shot mode", nil, column.play_mode == Core.PLAY_ONESHOT) then
            column.play_mode = Core.PLAY_ONESHOT
        end
        if r.ImGui_MenuItem(ctx, "Loop mode", nil, column.play_mode == Core.PLAY_LOOP) then
            column.play_mode = Core.PLAY_LOOP
        end
        r.ImGui_Separator(ctx)
        local launch_labels = { "Trigger", "Gate", "Toggle" }
        local launch_modes = { Core.LAUNCH_TRIGGER, Core.LAUNCH_GATE, Core.LAUNCH_TOGGLE }
        for li, lm in ipairs(launch_modes) do
            if r.ImGui_MenuItem(ctx, launch_labels[li], nil, column.launch_mode == lm) then
                column.launch_mode = lm
                Core.state.dirty = true
            end
        end
        r.ImGui_EndPopup(ctx)
    end

    -- Clip slots (horizontal)
    for clip_idx = 1, Core.MAX_CLIPS_PER_COLUMN do
        r.ImGui_SameLine(ctx, 0, spacing)
        drawTCPClipSlot(ctx, column_index, clip_idx, slot_w, slot_h)
    end
end

local function drawTCPOverlay()
    if not TCPOverlay then return end

    local bounds = TCPOverlay.getOverlayBounds()
    if not bounds then return end

    local ctx = getTCPContext()
    if not ctx then return end

    local ok = pcall(function()
        local imgui_x, imgui_y = TCPOverlay.convertToImGui(ctx, bounds.x, bounds.y)
        local imgui_r, imgui_b = TCPOverlay.convertToImGui(ctx, bounds.x + bounds.w, bounds.y + bounds.h)
        local imgui_w = imgui_r - imgui_x
        local imgui_h = imgui_b - imgui_y

        r.ImGui_SetNextWindowPos(ctx, imgui_x, imgui_y, r.ImGui_Cond_Always())
        r.ImGui_SetNextWindowSize(ctx, imgui_w, imgui_h, r.ImGui_Cond_Always())

        local overlay_flags = r.ImGui_WindowFlags_NoTitleBar()
            | r.ImGui_WindowFlags_NoResize()
            | r.ImGui_WindowFlags_NoMove()
            | r.ImGui_WindowFlags_NoScrollbar()
            | r.ImGui_WindowFlags_NoScrollWithMouse()
            | r.ImGui_WindowFlags_NoCollapse()
            | r.ImGui_WindowFlags_NoDocking()
            | r.ImGui_WindowFlags_NoFocusOnAppearing()
            | r.ImGui_WindowFlags_TopMost()
            | r.ImGui_WindowFlags_NoBackground()

        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), 0, 0)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), 0)

        local visible = r.ImGui_Begin(ctx, "##tcp_overlay", nil, overlay_flags)
        if visible then
            pcall(function()
                local positions = TCPOverlay.getTrackPositions(bounds)

                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 2, 2)
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 1, 1)

                for col_idx, pos in pairs(positions) do
                    r.ImGui_SetCursorPos(ctx, pos.x, pos.y)
                    drawTCPClipRow(ctx, col_idx, pos.w, pos.h)
                end

                r.ImGui_PopStyleVar(ctx, 2)
            end)
            r.ImGui_End(ctx)
        end

        r.ImGui_PopStyleVar(ctx, 2)
    end)
    if not ok then
        tcp_ctx = nil
    end
end

-- ============================================================
-- SETTINGS CONTEXT (on-demand)
-- ============================================================

local function getSettingsContext()
    if settings_ctx and not r.ValidatePtr(settings_ctx, "ImGui_Context*") then
        settings_ctx = nil
    end
    if not settings_ctx then
        settings_ctx = r.ImGui_CreateContext("CL_Settings")
        if style_loader then
            style_loader.ApplyFontsToContext(settings_ctx)
        end
    end
    return settings_ctx
end

-- ============================================================
-- MAIN DRAW
-- ============================================================

function UI.draw()
    -- Check external toggle (from CP_ClipLauncher_Settings.lua)
    local ext_toggle = r.GetExtState(Core.EXTSTATE_SECTION, "toggle_settings")
    if ext_toggle == "1" then
        r.DeleteExtState(Core.EXTSTATE_SECTION, "toggle_settings", false)
        UI.state.show_settings = not UI.state.show_settings
    end

    -- Always draw mixer overlays and scene column
    drawMixerOverlays()
    drawSceneOverlay()
    processCrossDrag()

    -- TCP overlay (single-context)
    drawTCPOverlay()

    -- Settings window (hidden by default, toggled via scene column button)
    if UI.state.show_settings then
        local ctx = getSettingsContext()
        if ctx then
            local ok = pcall(function()
                local _, colors_pushed, vars_pushed = ApplyStyle(ctx)

                local window_flags = r.ImGui_WindowFlags_NoCollapse()
                r.ImGui_SetNextWindowSize(ctx, 500, 160, r.ImGui_Cond_FirstUseEver())

                local visible, open = r.ImGui_Begin(ctx, "Clip Launcher Settings", true, window_flags)
                if visible then
                    -- Protected content (ensures End is always called even on error)
                    pcall(function()
                        local draw_fn = function()
                            drawTransportBar(ctx)
                            r.ImGui_Separator(ctx)

                            -- MCP Overlay calibration
                            local ov = Core.config.overlay
                            local ov_changed, ov_val = r.ImGui_Checkbox(ctx, "MCP Overlay", ov.enabled)
                            if ov_changed then ov.enabled = ov_val end

                            if ov.enabled then
                                r.ImGui_SameLine(ctx)
                                r.ImGui_SetNextItemWidth(ctx, 60)
                                local c1, v1 = r.ImGui_DragInt(ctx, "X##ov_ox", ov.offset_x, 1, -500, 500)
                                if c1 then ov.offset_x = v1 end

                                r.ImGui_SameLine(ctx)
                                r.ImGui_SetNextItemWidth(ctx, 60)
                                local c2, v2 = r.ImGui_DragInt(ctx, "Y##ov_oy", ov.offset_y, 1, -500, 500)
                                if c2 then ov.offset_y = v2 end

                                r.ImGui_SameLine(ctx)
                                r.ImGui_SetNextItemWidth(ctx, 80)
                                local c3, v3 = r.ImGui_SliderDouble(ctx, "H##ov_hr", ov.height_ratio * 100, 10, 100, "%.0f%%")
                                if c3 then ov.height_ratio = v3 / 100 end
                            end

                            -- TCP overlay calibration
                            local tcp = Core.config.tcp_overlay
                            local tcp_changed, tcp_val = r.ImGui_Checkbox(ctx, "TCP Overlay", tcp.enabled)
                            if tcp_changed then tcp.enabled = tcp_val end

                            if tcp.enabled then
                                r.ImGui_SameLine(ctx)
                                r.ImGui_SetNextItemWidth(ctx, 60)
                                local t1, tv1 = r.ImGui_DragInt(ctx, "X##tcp_ox", tcp.offset_x, 1, -500, 500)
                                if t1 then tcp.offset_x = tv1 end

                                r.ImGui_SameLine(ctx)
                                r.ImGui_SetNextItemWidth(ctx, 60)
                                local t2, tv2 = r.ImGui_DragInt(ctx, "Y##tcp_oy", tcp.offset_y, 1, -500, 500)
                                if t2 then tcp.offset_y = tv2 end

                                r.ImGui_SameLine(ctx)
                                r.ImGui_SetNextItemWidth(ctx, 80)
                                local t3, tv3 = r.ImGui_SliderDouble(ctx, "W##tcp_wr", tcp.width_ratio * 100, 10, 100, "%.0f%%")
                                if t3 then tcp.width_ratio = tv3 / 100 end

                                if TCPOverlay then
                                    -- Diagnostic info
                                    local info = TCPOverlay.getDetectedInfo()
                                    r.ImGui_TextColored(ctx, 0x888888FF, "Win: " .. info)

                                    local bounds = TCPOverlay.getOverlayBounds()
                                    if bounds then
                                        r.ImGui_TextColored(ctx, 0x88FF88FF,
                                            string.format("Bounds: %d,%d %dx%d | Cols: %d",
                                                math.floor(bounds.x), math.floor(bounds.y),
                                                math.floor(bounds.w), math.floor(bounds.h),
                                                #Core.state.columns))
                                    else
                                        r.ImGui_TextColored(ctx, 0xFF8888FF,
                                            string.format("No bounds (cols: %d)", #Core.state.columns))
                                    end

                                    -- Window picker button
                                    if r.ImGui_Button(ctx, "Browse windows##tcp_pick") then
                                        r.ImGui_OpenPopup(ctx, "tcp_win_picker")
                                    end

                                    -- Window picker popup (protected: EndPopup always called)
                                    if r.ImGui_BeginPopup(ctx, "tcp_win_picker") then
                                        pcall(function()
                                            local wins = TCPOverlay.listChildWindows()
                                            for wi, w in ipairs(wins) do
                                                local addr_int = math.floor(w.addr or 0)
                                                local label = string.format("[%s] %s (%s) 0x%X##w%d",
                                                    (w.class ~= "" and w.class) or "?",
                                                    (w.title ~= "" and w.title) or "-",
                                                    w.size or "?",
                                                    addr_int, wi)
                                                if r.ImGui_MenuItem(ctx, label) then
                                                    TCPOverlay.setManualHwnd(w.addr)
                                                end
                                            end
                                            if #wins == 0 then
                                                r.ImGui_Text(ctx, "No child windows found (JS extension?)")
                                            end
                                            r.ImGui_Separator(ctx)
                                            if r.ImGui_MenuItem(ctx, "Auto-detect (reset)") then
                                                TCPOverlay.setManualHwnd(0)
                                            end
                                        end)
                                        r.ImGui_EndPopup(ctx)
                                    end
                                end
                            end
                        end

                        -- Font-safe drawing
                        if style_loader and style_loader.PushFont(ctx, "main") then
                            pcall(draw_fn)
                            style_loader.PopFont(ctx)
                        else
                            draw_fn()
                        end
                    end)

                    r.ImGui_End(ctx)
                end

                ClearStyle(ctx, colors_pushed, vars_pushed)

                if not open then
                    UI.state.show_settings = false
                end
            end)
            if not ok then
                settings_ctx = nil
            end
        end
    else
        if settings_ctx then
            settings_ctx = nil
        end
    end

    return Core.state.is_running
end

return UI
