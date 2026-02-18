-- @description TimeSelectionSync
-- @version 1.1
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_TimeSelectionSync"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('Time Selection Extension Config')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()

local window_follow_mouse = false
local window_x_offset = 35
local window_y_offset = 35
local window_width = 250
local window_height = 278

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

function GetFont(font_name)
    if style_loader then
        return style_loader.GetFont(ctx, font_name)
    end
    return nil
end

local header_font_size = GetStyleValue("fonts.header.size", 16)
local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
local window_padding_x = GetStyleValue("spacing.window_padding_x", 6)
local window_padding_y = GetStyleValue("spacing.window_padding_y", 6)

local config = {
    time_selection_extension = 0.0,
    sync_edit_cursor = false,
    sync_automation = false,
    sync_time_selection = true,
    playback_mode = "preview"
}

local state = {
    window_open = true,
    window_position_set = false,
    last_selected_item_guid = nil,
    mouse_down_time = 0,
    last_mouse_state = 0,
    mouse_down_start = 0,
    long_press_threshold = 0.15,
    is_dragging = false,
    last_track_guid = nil,
    last_refresh_time = 0,
    last_selected_items = {},
    last_item_positions = {},
    last_item_lengths = {},
    last_edit_cursor_pos = -1,
    last_envelope_count = {},
    last_item_rates = {},
    last_item_selection = {}
}

function ApplyStyle()
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then 
            pushed_colors = colors
            pushed_vars = vars
            return true
        end
    end
    return false
end

function ClearStyle()
    if style_loader then 
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end
end

function SaveSettings()
    for key, value in pairs(config) do
        local value_str = tostring(value)
        if type(value) == "boolean" then
            value_str = value and "1" or "0"
        end
        r.SetExtState(script_name, "config_" .. key, value_str, true)
    end
end

function LoadSettings()
    for key, default_value in pairs(config) do
        local saved_value = r.GetExtState(script_name, "config_" .. key)
        if saved_value ~= "" then
            if type(default_value) == "number" then
                config[key] = tonumber(saved_value) or default_value
            elseif type(default_value) == "boolean" then
                config[key] = saved_value == "1"
            else
                config[key] = saved_value
            end
        end
    end
end

function Approximately(a, b, tolerance)
    tolerance = tolerance or 0.000001
    return math.abs(a - b) < tolerance
end

function CalculateStretchMarkersHash(take)
    if not take then return "" end
    
    local hash = ""
    local stretch_marker_count = r.GetTakeNumStretchMarkers(take)
    
    for i = 0, stretch_marker_count - 1 do
        local retval, pos, srcpos = r.GetTakeStretchMarker(take, i)
        if retval >= 0 then
            hash = hash .. string.format("%.6f:%.6f;", pos, srcpos)
        end
    end
    
    return hash
end

function GetItemState(item)
    if not item then return nil end
    
    local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take = r.GetActiveTake(item)
    local rate = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
    
    local source_length = 0
    if take then
        local source = r.GetMediaItemTake_Source(take)
        if source then
            local source_length_val, length_is_qn = r.GetMediaSourceLength(source)
            if length_is_qn then
                local tempo = r.Master_GetTempo()
                source_length = source_length_val * 60 / tempo
            else
                source_length = source_length_val
            end
        end
    end
    
    local stretch_markers_hash = take and CalculateStretchMarkersHash(take) or ""
    
    return {
        position = pos,
        length = length,
        rate = rate,
        source_length = source_length,
        stretch_markers_hash = stretch_markers_hash
    }
end

function GetSelectedItemsRange()
    local start_pos = math.huge 
    local end_pos = -math.huge
    local num_items = r.CountSelectedMediaItems(0)
    
    for i = 0, num_items-1 do
        local item = r.GetSelectedMediaItem(0, i)
        local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_pos + item_length
        
        start_pos = math.min(start_pos, item_pos)
        end_pos = math.max(end_pos, item_end)
    end
    
    if start_pos == math.huge then return nil, nil end
    return start_pos, end_pos
end

function GetAutomationItemState(env, idx)
    local pos = r.GetSetAutomationItemInfo(env, idx, "D_POSITION", 0, false)
    local len = r.GetSetAutomationItemInfo(env, idx, "D_LENGTH", 0, false)
    local rate = r.GetSetAutomationItemInfo(env, idx, "D_PLAYRATE", 0, false)
    
    return {
        position = pos,
        length = len,
        rate = rate
    }
end

function DetectEnvelopeChanges(track)
    if not track then return false end
    
    local track_guid = r.GetTrackGUID(track)
    local current_env_count = r.CountTrackEnvelopes(track)
    
    if state.last_envelope_count[track_guid] ~= current_env_count then
        state.last_envelope_count[track_guid] = current_env_count
        return true
    end
    
    return false
end

function IsClickOnSelectedItem()
    local x, y = r.GetMousePosition()
    local item = r.GetItemFromPoint(x, y, false)
    if not item then return false end
    
    local is_selected = r.IsMediaItemSelected(item)
    if not is_selected then return false end
    
    local left_click = r.JS_Mouse_GetState(1) == 1
    local was_clicked = left_click and state.last_mouse_state == 0
    state.last_mouse_state = left_click and 1 or 0
    
    return was_clicked
end

function DetectChanges()
    local changes_detected = false
    
    if IsClickOnSelectedItem() then
        return true
    end
    
    local current_selection = {}
    local num_selected = r.CountSelectedMediaItems(0)
    for i = 0, num_selected - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local guid = r.BR_GetMediaItemGUID(item)
        current_selection[guid] = true
        
        if not state.last_item_selection[guid] then
            changes_detected = true
        end
    end
    
    for guid in pairs(state.last_item_selection) do
        if not current_selection[guid] then
            changes_detected = true
        end
    end
    
    state.last_item_selection = current_selection
    
    for i = 0, num_selected - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local guid = r.BR_GetMediaItemGUID(item)
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local take = r.GetActiveTake(item)
        local rate = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
        
        local track = r.GetMediaItem_Track(item)
        if DetectEnvelopeChanges(track) then
            changes_detected = true
        end
        
        if state.last_item_positions[guid] ~= pos or
           state.last_item_lengths[guid] ~= length or
           state.last_item_rates[guid] ~= rate then
            changes_detected = true
        end
        
        state.last_item_positions[guid] = pos
        state.last_item_lengths[guid] = length
        state.last_item_rates[guid] = rate
    end
    
    local cursor_pos = r.GetCursorPosition()
    if config.sync_edit_cursor and state.last_edit_cursor_pos ~= cursor_pos then
        changes_detected = true
    end
    
    return changes_detected
end

function IsMouseOverMediaItem()
    local x, y = r.GetMousePosition()
    local item, take = r.GetItemFromPoint(x, y, false)
    return item
end

function IsReaperWindowActive()
    local hwnd = r.GetMainHwnd()
    return r.JS_Window_GetForeground() == hwnd
end

function IsLeftClick()
    local current_mouse_state = r.JS_Mouse_GetState(1)
    local current_time = r.time_precise()
    
    if current_mouse_state == 1 and state.last_mouse_state == 0 then
        state.mouse_down_time = current_time
        state.mouse_down_start = current_time
        state.is_dragging = false
    end
    
    if current_mouse_state == 1 and state.last_mouse_state == 1 then
        if (current_time - state.mouse_down_start) > state.long_press_threshold then
            state.is_dragging = true
            if state.is_dragging and r.GetPlayState() == 1 then
                r.Main_OnCommand(1016, 0)
            end
        end
    end
    
    if current_mouse_state == 0 and state.last_mouse_state == 1 then
        local was_short_click = (current_time - state.mouse_down_start) < state.long_press_threshold and not state.is_dragging
        state.last_mouse_state = current_mouse_state
        return was_short_click
    end
    
    state.last_mouse_state = current_mouse_state
    return false
end

function SyncAutomationItems()
    local num_selected = r.CountSelectedMediaItems(0)
    if num_selected == 0 then return end
    
    local total_start, total_end = GetSelectedItemsRange()
    if not total_start then return end
    
    if config.sync_time_selection then
        local start_time = total_start
        local end_time = total_end + config.time_selection_extension
        r.GetSet_LoopTimeRange(true, false, start_time, end_time, false)
    end
    
    if config.sync_edit_cursor then
        r.SetEditCurPos(total_start, false, false)
        state.last_edit_cursor_pos = total_start
    end
    
    if config.sync_automation then
        for i = 0, num_selected - 1 do
            local item = r.GetSelectedMediaItem(0, i)
            local take = r.GetActiveTake(item)
            if not take then goto continue end
            
            local track = r.GetMediaItem_Track(item)
            local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
            local item_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            local item_rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
            
            local env_count = r.CountTrackEnvelopes(track)
            for k = 0, env_count - 1 do
                local env = r.GetTrackEnvelope(track, k)
                
                local br_env = r.BR_EnvAlloc(env, false)
                local _, _, _, _, _, visible = r.BR_EnvGetProperties(br_env)
                r.BR_EnvFree(br_env, false)
                if not visible then goto continue_env end
                
                local ai_count = r.CountAutomationItems(env)
                local ai_found = false
                
                for l = 0, ai_count - 1 do
                    local ai_pos = r.GetSetAutomationItemInfo(env, l, "D_POSITION", 0, false)
                    
                    if Approximately(ai_pos, item_pos) then
                        r.GetSetAutomationItemInfo(env, l, "D_LENGTH", math.max(item_length, 0.1), true)
                        r.GetSetAutomationItemInfo(env, l, "D_PLAYRATE", item_rate, true)
                        r.GetSetAutomationItemInfo(env, l, "D_LOOPLEN", item_length, true)
                        r.GetSetAutomationItemInfo(env, l, "D_POOL_LOOPLEN", item_length, true)
                        ai_found = true
                        break
                    end
                end
                
                if not ai_found then
                    local new_ai = r.InsertAutomationItem(env, -1, item_pos, math.max(item_length, 0.1))
                    r.GetSetAutomationItemInfo(env, new_ai, "D_PLAYRATE", item_rate, true)
                    r.GetSetAutomationItemInfo(env, new_ai, "D_LOOPLEN", item_length, true)
                    r.GetSetAutomationItemInfo(env, new_ai, "D_POOL_LOOPLEN", item_length, true)
                end
                
                ::continue_env::
            end
            
            ::continue::
        end
    end
    
    r.UpdateTimeline()
end

function MainLoop()
    if not state.window_position_set then
        if window_follow_mouse then
            local mouse_x, mouse_y = r.GetMousePosition()
            r.ImGui_SetNextWindowPos(ctx, mouse_x + window_x_offset, mouse_y + window_y_offset)
        end
        r.ImGui_SetNextWindowSize(ctx, window_width, window_height, r.ImGui_Cond_FirstUseEver())
        state.window_position_set = true
    end

    ApplyStyle()

    local visible, open = r.ImGui_Begin(ctx, 'Time Selection Config', true, window_flags)
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Time Selection Config")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Time Selection Config")
        end

        r.ImGui_SameLine(ctx)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if style_loader and style_loader.PushFont(ctx, "main") then
        
        r.ImGui_Separator(ctx)
        
        r.ImGui_Text(ctx, "Options:")
        
        local time_sel_changed, cursor_changed, automation_changed, play_changed, extension_changed
        time_sel_changed, config.sync_time_selection = r.ImGui_Checkbox(ctx, "Sync Time Selection", config.sync_time_selection)
        cursor_changed, config.sync_edit_cursor = r.ImGui_Checkbox(ctx, "Sync Edit Cursor", config.sync_edit_cursor)  
        automation_changed, config.sync_automation = r.ImGui_Checkbox(ctx, "Sync Automation", config.sync_automation)

        if config.sync_time_selection then
            r.ImGui_Separator(ctx)
            
            r.ImGui_Text(ctx, "Time Selection Extension")
            local content_width = r.ImGui_GetContentRegionAvail(ctx)
            local font_size = 16
            if style_loader then
                local styles = style_loader.getStyleValues()
                if styles and styles.fonts and styles.fonts.main and styles.fonts.main.size then
                    font_size = styles.fonts.main.size
                end
            end
            r.ImGui_SetNextItemWidth(ctx, content_width - font_size)
            extension_changed, config.time_selection_extension = r.ImGui_SliderDouble(ctx, 's', 
                                                                    config.time_selection_extension, 0.0, 5.0, '%.2f')
            
            r.ImGui_Text(ctx, "Presets:")
            if r.ImGui_Button(ctx, "0.0s") then
                config.time_selection_extension = 0.0
                extension_changed = true
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "0.1s") then
                config.time_selection_extension = 0.1
                extension_changed = true
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "0.3s") then
                config.time_selection_extension = 0.3
                extension_changed = true
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "0.5s") then
                config.time_selection_extension = 0.5
                extension_changed = true
            end
            
            if extension_changed then
                SyncAutomationItems()
                SaveSettings()
            end
        end
        
        if time_sel_changed or cursor_changed or automation_changed or play_changed then
            SaveSettings()
        end

        style_loader.PopFont(ctx)

        end
        
        r.ImGui_End(ctx)
    end

    ClearStyle()
    
    local current_time = r.time_precise()
    if current_time - state.last_refresh_time >= 0.015 then
        if DetectChanges() then
            SyncAutomationItems()
        end
        state.last_refresh_time = current_time
    end
    
    r.PreventUIRefresh(-1)
    
    if open then
        r.defer(MainLoop)
    else
        SaveSettings()
    end
end

function ToggleScript()
    local _, _, section_id, command_id = r.get_action_context()
    local script_state = r.GetToggleCommandState(command_id)
    
    if script_state == -1 or script_state == 0 then
        r.SetToggleCommandState(section_id, command_id, 1)
        r.RefreshToolbar2(section_id, command_id)
        Start()
    else
        r.SetToggleCommandState(section_id, command_id, 0)
        r.RefreshToolbar2(section_id, command_id)
        Stop()
    end
end

function Start()
    LoadSettings()
    MainLoop()
end

function Stop()
    local selected_item = r.GetSelectedMediaItem(0, 0)
    if selected_item then
        SyncAutomationItems()
    end
    state.window_open = false
    SaveSettings()
    
    ClearStyle()
    
    r.UpdateArrange()
end

function Exit()
    local _, _, section_id, command_id = r.get_action_context()
    SaveSettings()
    
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
    
    if r.GetToggleCommandState(42213) == 1 then
        r.Main_OnCommand(42213, 0)
    end
end

r.atexit(Exit)
ToggleScript()
