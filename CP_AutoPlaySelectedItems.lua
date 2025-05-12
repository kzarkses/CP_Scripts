-- @description Auto Play Selected Items
-- @version 1.0
-- @author Claude
-- @about
--   Auto play items when clicking on them

local r = reaper

-- Configuration
local PLAYBACK_MODE = "preview"  -- "preview" ou "play" 
local CLICK_THRESHOLD = 0.15
local LONG_PRESS_THRESHOLD = 0.15

-- Variables d'état
local mouse_down_time = 0
local last_mouse_state = 0
local mouse_down_start = 0
local is_dragging = false

function isMouseOverMediaItem()
    local x, y = r.GetMousePosition()
    local item = r.GetItemFromPoint(x, y, false)
    return item
end

function isReaperWindowActive()
    local hwnd = r.GetMainHwnd()
    return r.JS_Window_GetForeground() == hwnd
end

function isLeftClick()
    local current_mouse_state = r.JS_Mouse_GetState(1)
    local current_time = r.time_precise()
    
    -- Début de l'appui
    if current_mouse_state == 1 and last_mouse_state == 0 then
        mouse_down_time = current_time
        mouse_down_start = current_time
        is_dragging = false
    end
    
    -- Pendant l'appui, vérifier si c'est un appui long
    if current_mouse_state == 1 and last_mouse_state == 1 then
        if (current_time - mouse_down_start) > LONG_PRESS_THRESHOLD then
            is_dragging = true
            -- Stop le transport si on commence à déplacer un item
            if is_dragging and r.GetPlayState() == 1 then
                r.Main_OnCommand(1016, 0) -- Transport: Stop
            end
        end
    end
    
    -- Relâchement du clic
    if current_mouse_state == 0 and last_mouse_state == 1 then
        local was_short_click = (current_time - mouse_down_start) < LONG_PRESS_THRESHOLD and not is_dragging
        last_mouse_state = current_mouse_state
        return was_short_click
    end
    
    last_mouse_state = current_mouse_state
    return false
end

function ProcessAutoPlay()
    if not isReaperWindowActive() then return end

    local selected_item_count = r.CountSelectedMediaItems(0)
    local is_playing = r.GetPlayState() & 1 == 1
    local is_previewing = r.GetPlayState() & 4 == 4
    
    -- Stop any current playback when no items are selected
    if selected_item_count == 0 and (is_playing or is_previewing) then
        if PLAYBACK_MODE == "preview" then
            r.Main_OnCommand(r.NamedCommandLookup("_BR_PREV_TAKE_CURSOR"), 0)
        else
            r.Main_OnCommand(1016, 0)  -- Stop
        end
        return
    end
    
    if selected_item_count == 0 then return end

    local clicked_item = isMouseOverMediaItem()
    if clicked_item and isLeftClick() then
        -- Select the clicked item
        r.SetMediaItemSelected(clicked_item, true)
        
        -- Play based on selected mode
        if PLAYBACK_MODE == "preview" then
            r.Main_OnCommand(r.NamedCommandLookup("_BR_PREV_TAKE_CURSOR"), 0)
        else
            -- In play mode, we still want to set the cursor position
            local item_pos = r.GetMediaItemInfo_Value(clicked_item, "D_POSITION")
            r.SetEditCurPos(item_pos, false, false)
            r.Main_OnCommand(1007, 0)  -- Play
        end
    end
end

function MainLoop()
    ProcessAutoPlay()
    r.defer(MainLoop)
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
    MainLoop()
end

function Stop()
    r.UpdateArrange()
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()