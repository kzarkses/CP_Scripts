--[[
@description CP_TimeSelectionSync
@version 1.0
@author Cedric Pamallo
--]]
local r = reaper

local sl = nil
local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp) then local lf = dofile(sp) if lf then sl = lf() end end

local ctx = r.ImGui_CreateContext('Time Selection Extension Config')
local pc, pv = 0, 0

function getFont(font_name)
    if sl then
        return sl.getFont(ctx, font_name)
    end
    return nil
end

if sl then sl.applyFontsToContext(ctx) end

local WINDOW_FLAGS = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoCollapse()

local WINDOW_FOLLOW_MOUSE = false
local WINDOW_X_OFFSET = 35
local WINDOW_Y_OFFSET = 35
local WINDOW_WIDTH = 220
local WINDOW_HEIGHT = 278

local time_selection_extension = 0.0
local sync_edit_cursor = false
local sync_automation = false
local sync_time_selection = true
local auto_play = true
local playback_mode = "preview"
local window_open = true
local window_position_set = false

local last_selected_item_guid = nil
local mouse_down_time = 0
local last_mouse_state = 0
local CLICK_THRESHOLD = 0.15
local mouse_down_start = 0
local LONG_PRESS_THRESHOLD = 0.15
local is_dragging = false
local last_track_guid = nil

local last_refresh_time = 0
local lastSelectedItems = {}
local lastItemPositions = {}
local lastItemLengths = {}
local last_edit_cursor_pos = -1
local last_envelope_count = {}
local last_item_positions = {}
local last_item_lengths = {}
local last_item_rates = {}
local last_item_selection = {}

function SaveSettings()
    r.SetExtState("TimeSelectionSync", "playback_mode", playback_mode, true)
    r.SetExtState("TimeSelectionSync", "sync_edit_cursor", sync_edit_cursor and "1" or "0", true)
    r.SetExtState("TimeSelectionSync", "sync_automation", sync_automation and "1" or "0", true)
    r.SetExtState("TimeSelectionSync", "sync_time_selection", sync_time_selection and "1" or "0", true)
    r.SetExtState("TimeSelectionSync", "auto_play", auto_play and "1" or "0", true)
    r.SetExtState("TimeSelectionSync", "time_selection_extension", tostring(time_selection_extension), true)
end

function LoadSettings()
    local cursor = r.GetExtState("TimeSelectionSync", "sync_edit_cursor")
    local automation = r.GetExtState("TimeSelectionSync", "sync_automation")
    local time_sel = r.GetExtState("TimeSelectionSync", "sync_time_selection")
    local play = r.GetExtState("TimeSelectionSync", "auto_play")
    local ext = r.GetExtState("TimeSelectionSync", "time_selection_extension")
    local mode = r.GetExtState("TimeSelectionSync", "playback_mode")

    playback_mode = mode ~= "" and mode or "preview"
    sync_edit_cursor = cursor == "1"
    sync_automation = automation == "1"
    sync_time_selection = time_sel == "1"
    auto_play = play == "1"
    time_selection_extension = ext ~= "" and tonumber(ext) or 0.0
end

local function approximately(a, b, tolerance)
    tolerance = tolerance or 0.000001
    return math.abs(a - b) < tolerance
end

local function calculateStretchMarkersHash(take)
    if not take then return "" end
    
    local hash = ""
    local stretchMarkerCount = r.GetTakeNumStretchMarkers(take)
    
    for i = 0, stretchMarkerCount - 1 do
        local retval, pos, srcpos = r.GetTakeStretchMarker(take, i)
        if retval >= 0 then
            hash = hash .. string.format("%.6f:%.6f;", pos, srcpos)
        end
    end
    
    return hash
end

local function getItemState(item)
    if not item then return nil end
    
    local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take = r.GetActiveTake(item)
    local rate = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
    
    local sourceLength = 0
    if take then
        local source = r.GetMediaItemTake_Source(take)
        if source then
            local source_length, lengthIsQN = r.GetMediaSourceLength(source)
            if lengthIsQN then
                local tempo = r.Master_GetTempo()
                sourceLength = source_length * 60 / tempo
            else
                sourceLength = source_length
            end
        end
    end
    
    local stretchMarkersHash = take and calculateStretchMarkersHash(take) or ""
    
    return {
        position = pos,
        length = length,
        rate = rate,
        sourceLength = sourceLength,
        stretchMarkersHash = stretchMarkersHash
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

local function getAutomationItemState(env, idx)
    local pos = r.GetSetAutomationItemInfo(env, idx, "D_POSITION", 0, false)
    local len = r.GetSetAutomationItemInfo(env, idx, "D_LENGTH", 0, false)
    local rate = r.GetSetAutomationItemInfo(env, idx, "D_PLAYRATE", 0, false)
    
    return {
        position = pos,
        length = len,
        rate = rate
    }
end

function detectEnvelopeChanges(track)
    if not track then return false end
    
    local track_guid = r.GetTrackGUID(track)
    local current_env_count = r.CountTrackEnvelopes(track)
    
    if last_envelope_count[track_guid] ~= current_env_count then
        last_envelope_count[track_guid] = current_env_count
        return true
    end
    
    return false
end

function isClickOnSelectedItem()
    local x, y = r.GetMousePosition()
    local item = r.GetItemFromPoint(x, y, false)
    if not item then return false end
    
    local is_selected = r.IsMediaItemSelected(item)
    if not is_selected then return false end
    
    local left_click = r.JS_Mouse_GetState(1) == 1
    local was_clicked = left_click and last_mouse_state == 0
    last_mouse_state = left_click and 1 or 0
    
    return was_clicked
end

function detectChanges()
    local changes_detected = false
    
    if isClickOnSelectedItem() then
        return true
    end
    
    local current_selection = {}
    local num_selected = r.CountSelectedMediaItems(0)
    for i = 0, num_selected - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local guid = r.BR_GetMediaItemGUID(item)
        current_selection[guid] = true
        
        if not last_item_selection[guid] then
            changes_detected = true
        end
    end
    
    for guid in pairs(last_item_selection) do
        if not current_selection[guid] then
            changes_detected = true
        end
    end
    
    last_item_selection = current_selection
    
    for i = 0, num_selected - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local guid = r.BR_GetMediaItemGUID(item)
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local take = r.GetActiveTake(item)
        local rate = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
        
        local track = r.GetMediaItem_Track(item)
        if detectEnvelopeChanges(track) then
            changes_detected = true
        end
        
        if last_item_positions[guid] ~= pos or
           last_item_lengths[guid] ~= length or
           last_item_rates[guid] ~= rate then
            changes_detected = true
        end
        
        last_item_positions[guid] = pos
        last_item_lengths[guid] = length
        last_item_rates[guid] = rate
    end
    
    local cursor_pos = r.GetCursorPosition()
    if sync_edit_cursor and last_edit_cursor_pos ~= cursor_pos then
        changes_detected = true
    end
    
    return changes_detected
end

function isMouseOverMediaItem()
    local x, y = r.GetMousePosition()
    local item, take = r.GetItemFromPoint(x, y, false)
    return item
end

function isReaperWindowActive()
    local hwnd = r.GetMainHwnd()
    return r.JS_Window_GetForeground() == hwnd
end

function isLeftClick()
    local current_mouse_state = r.JS_Mouse_GetState(1)
    local current_time = r.time_precise()
    
    if current_mouse_state == 1 and last_mouse_state == 0 then
        mouse_down_time = current_time
        mouse_down_start = current_time
        is_dragging = false
    end
    
    if current_mouse_state == 1 and last_mouse_state == 1 then
        if (current_time - mouse_down_start) > LONG_PRESS_THRESHOLD then
            is_dragging = true
            if is_dragging and r.GetPlayState() == 1 then
                r.Main_OnCommand(1016, 0)
            end
        end
    end
    
    if current_mouse_state == 0 and last_mouse_state == 1 then
        local was_short_click = (current_time - mouse_down_start) < LONG_PRESS_THRESHOLD and not is_dragging
        last_mouse_state = current_mouse_state
        return was_short_click
    end
    
    last_mouse_state = current_mouse_state
    return false
end

function PlaySelectedItem()
    if not (auto_play and isReaperWindowActive()) then 
        return 
    end

    local selected_item_count = r.CountSelectedMediaItems(0)
    local is_playing = r.GetPlayState() & 1 == 1
    local is_previewing = r.GetPlayState() & 4 == 4
    
    if selected_item_count == 0 and (is_playing or is_previewing) then
        if playback_mode == "preview" then
            r.Main_OnCommand(r.NamedCommandLookup("_BR_PREV_TAKE_CURSOR"), 0)
        else
            r.Main_OnCommand(1016, 0)
        end
        return
    end
    
    if selected_item_count == 0 then return end

    local clicked_item = isMouseOverMediaItem()
    if clicked_item and isLeftClick() then
        r.SetMediaItemSelected(clicked_item, true)
        local item_pos = r.GetMediaItemInfo_Value(clicked_item, "D_POSITION")
        r.SetEditCurPos(item_pos, false, false)
        if playback_mode == "preview" then
            r.Main_OnCommand(r.NamedCommandLookup("_BR_PREV_TAKE_CURSOR"), 0)
        else
            r.Main_OnCommand(1007, 0)
        end
    end
end

function SyncAutomationItems()
    local num_selected = r.CountSelectedMediaItems(0)
    if num_selected == 0 then return end
    
    local total_start, total_end = GetSelectedItemsRange()
    if not total_start then return end
    
    if sync_time_selection then
        local start_time = total_start
        local end_time = total_end + time_selection_extension
        r.GetSet_LoopTimeRange(true, false, start_time, end_time, false)
    end
    
    if sync_edit_cursor then
        r.SetEditCurPos(total_start, false, false)
        last_edit_cursor_pos = total_start
    end
    
    if sync_automation then
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
                    
                    if approximately(ai_pos, item_pos) then
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
    if not window_position_set then
        if WINDOW_FOLLOW_MOUSE then
            local mouse_x, mouse_y = r.GetMousePosition()
            r.ImGui_SetNextWindowPos(ctx, mouse_x + WINDOW_X_OFFSET, mouse_y + WINDOW_Y_OFFSET)
        end
        r.ImGui_SetNextWindowSize(ctx, WINDOW_WIDTH, WINDOW_HEIGHT)
        window_position_set = true
    end

    if sl then
        local success, colors, vars = sl.applyToContext(ctx)
        if success then pc, pv = colors, vars end
    end

    local header_font = getFont("header")
    local main_font = getFont("main")

    local visible, open = r.ImGui_Begin(ctx, 'Time Selection Config', true, WINDOW_FLAGS)
    if visible then
        if header_font then r.ImGui_PushFont(ctx, header_font) end
        r.ImGui_Text(ctx, "Time Selection Config")
        if header_font then r.ImGui_PopFont(ctx) end
        if main_font then r.ImGui_PushFont(ctx, main_font) end
        
        r.ImGui_SameLine(ctx)
        local close_x = r.ImGui_GetWindowWidth(ctx) - 30
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", 22, 22) then
            open = false
        end
        
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        r.ImGui_Text(ctx, "Options:")
        r.ImGui_Spacing(ctx)
        
        local time_sel_changed, cursor_changed, automation_changed, play_changed, extension_changed
        
        time_sel_changed, sync_time_selection = r.ImGui_Checkbox(ctx, "Sync Time Selection", sync_time_selection)
        r.ImGui_Spacing(ctx)
        
        cursor_changed, sync_edit_cursor = r.ImGui_Checkbox(ctx, "Sync Edit Cursor", sync_edit_cursor)
        r.ImGui_Spacing(ctx)
        
        automation_changed, sync_automation = r.ImGui_Checkbox(ctx, "Sync Automation", sync_automation)
        r.ImGui_Spacing(ctx)
        
        -- play_changed, auto_play = r.ImGui_Checkbox(ctx, "Auto-Play", auto_play)

        if sync_time_selection then
            r.ImGui_Spacing(ctx)
            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)
            
            r.ImGui_Text(ctx, "Time Selection Extension")
            r.ImGui_Spacing(ctx)
            
            extension_changed, time_selection_extension = r.ImGui_SliderDouble(ctx, 's', 
                                                                    time_selection_extension, 0.0, 5.0, '%.2f')
            r.ImGui_Spacing(ctx)
            
            r.ImGui_Text(ctx, "Presets:")
            if r.ImGui_Button(ctx, "0.0s") then
                time_selection_extension = 0.0
                extension_changed = true
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "0.1s") then
                time_selection_extension = 0.1
                extension_changed = true
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "0.3s") then
                time_selection_extension = 0.3
                extension_changed = true
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "0.5s") then
                time_selection_extension = 0.5
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

        if main_font then r.ImGui_PopFont(ctx) end
        
        r.ImGui_End(ctx)
    end

    if sl then sl.clearStyles(ctx, pc, pv) end

    if auto_play then 
        PlaySelectedItem() 
    end
    
    local current_time = r.time_precise()
    if current_time - last_refresh_time >= 0.025 then
        if detectChanges() then
            SyncAutomationItems()
        end
        last_refresh_time = current_time
    end
    
    r.PreventUIRefresh(-1)
    
    if open then
        r.defer(MainLoop)
    else
        SaveSettings()
    end
end

function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        Start()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
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
    window_open = false
    SaveSettings()
    
    if sl then sl.clearStyles(ctx, pc, pv) end
    
    r.UpdateArrange()
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    SaveSettings()
    
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
    
    if r.GetToggleCommandState(42213) == 1 then
        r.Main_OnCommand(42213, 0)
    end
end

r.atexit(Exit)
ToggleScript()


