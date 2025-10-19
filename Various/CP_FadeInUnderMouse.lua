-- @description CP_FadeInAllSelected_AtMouseCursor
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

local function GetMousePosition()
    local _, x = r.GetMousePosition()
    return r.BR_GetMouseCursorContext_Position()
end

local function ApplyFadeInAtPosition(item, fade_pos)
    local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_pos + item_length
    
    if fade_pos <= item_pos then
        r.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0.01)
    elseif fade_pos >= item_end then
        r.SetMediaItemInfo_Value(item, "D_FADEINLEN", item_length - 0.01)
    else
        local fade_length = fade_pos - item_pos
        r.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade_length)
    end
end

local function Main()
    local selected_count = r.CountSelectedMediaItems(0)
    if selected_count == 0 then
        r.ShowMessageBox("No items selected", "Error", 0)
        return
    end
    
    local window, segment, details = r.BR_GetMouseCursorContext()
    if not window or window ~= "arrange" then
        r.ShowMessageBox("Mouse cursor must be in arrange view", "Error", 0)
        return
    end
    
    local _, mouse_pos = r.BR_GetMouseCursorContext_Position()
    if not mouse_pos then
        r.ShowMessageBox("Could not get mouse position", "Error", 0)
        return
    end
    
    r.Undo_BeginBlock()
    
    for i = 0, selected_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        ApplyFadeInAtPosition(item, mouse_pos)
    end
    
    r.UpdateArrange()
    r.Undo_EndBlock("Apply fade-in to selected items at mouse position", -1)
end

if not r.BR_GetMouseCursorContext then
    r.ShowMessageBox("This script requires SWS extension", "Error", 0)
else
    Main()
end
