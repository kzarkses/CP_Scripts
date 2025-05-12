-- @description Add stretch markers with GUI interface
-- @version 1.0
-- @author Original: nvk, GUI: Claude
local r = reaper

-- Create context at script start
local ctx = r.ImGui_CreateContext('Stretch Markers Control')
local WINDOW_FLAGS = 0

local WINDOW_X_OFFSET = -235  -- Horizontal offset from mouse position in pixels
local WINDOW_Y_OFFSET = 35  -- Vertical offset from mouse position in pixels
local WINDOW_WIDTH = 200    -- Initial window width in pixels
local WINDOW_HEIGHT = 150   -- Initial window height in pixels

-- Settings variables
local window_position_set = false
local settings = {
    slope = 0,
    last_slope = 0  -- To track changes
}

-- Function to save selected items
function SaveSelectedItems()
    local items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(items, r.GetSelectedMediaItem(0, i))
    end
    return items
end

-- Main function to apply stretch markers
function ApplyStretchMarkers(slopeIn)
    local items = SaveSelectedItems()
    if #items == 0 then return end  -- Don't process if no items selected
    
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    
    r.Main_OnCommand(40796, 0) -- Clear take preserve pitch
    for i, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local itemLength = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
            local playrate = r.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
            
            -- Delete existing stretch markers
            r.DeleteTakeStretchMarkers(take, 0, r.GetTakeNumStretchMarkers(take))
            
            -- Add new stretch markers
            local idx = r.SetTakeStretchMarker(take, -1, 0)
            r.SetTakeStretchMarker(take, -1, itemLength * playrate)
            
            -- Calculate and set slope
            local slope = slopeIn
            if slope > 4 then
                slope = math.random() * math.min(4, (slope - 4)) / 4
                if math.random() > 0.5 then slope = slope * -1 end
            else
                slope = slope * 0.2499
            end
            r.SetTakeStretchMarkerSlope(take, idx, slope)
        end
    end
    
    r.Undo_EndBlock("Add Stretch Markers", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

function Loop()
    -- Set window position to mouse cursor on first open
    if not window_position_set then
        local mouse_x, mouse_y = r.GetMousePosition()
        r.ImGui_SetNextWindowPos(ctx, mouse_x + WINDOW_X_OFFSET, mouse_y + WINDOW_Y_OFFSET)
        r.ImGui_SetNextWindowSize(ctx, WINDOW_WIDTH, WINDOW_HEIGHT)
        window_position_set = true
    end

local visible, open = r.ImGui_Begin(ctx, 'Stretch Markers Control', true, WINDOW_FLAGS)
    
    if visible then
        -- Slope slider
        local slope_changed
        slope_changed, settings.slope = r.ImGui_SliderDouble(ctx, 'Slope', settings.slope, -4, 4, '%.2f')
        r.ImGui_Spacing(ctx)
        
        -- Preset buttons
        r.ImGui_Text(ctx, "Presets:")
        
        -- Negative presets row
        if r.ImGui_Button(ctx, "-2") then
            settings.slope = -4
            slope_changed = true
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "-1.75") then
            settings.slope = -3
            slope_changed = true
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "-1.50") then
            settings.slope = -2
            slope_changed = true
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "-1.25") then
            settings.slope = -1
            slope_changed = true
        end
        
        -- Positive presets row
        if r.ImGui_Button(ctx, "0") then
            settings.slope = 0
            slope_changed = true
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "1.25") then
            settings.slope = 1
            slope_changed = true
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "1.50") then
            settings.slope = 2
            slope_changed = true
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "1.75") then
            settings.slope = 3
            slope_changed = true
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "2") then
            settings.slope = 4
            slope_changed = true
        end
        
        -- Apply changes if slider moved or button pressed
        if slope_changed or settings.slope ~= settings.last_slope then
            ApplyStretchMarkers(settings.slope)
            settings.last_slope = settings.slope
        end
        
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(Loop)
    end
end

-- Script toggle function
function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        Loop()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
    end
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()