-- @description Dynamic FPS Control
-- @version 1.0
-- @author Claude

local r = reaper

-- Create ImGui context
local ctx = r.ImGui_CreateContext('FPS Control')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

-- Configuration
local config = {
    fps = 24,
    track_name = "VIDEO",
    window_position_set = false,
    adjust_grid = true -- New setting for grid adjustment
}

-- Load/Save settings
function LoadSettings()
    config.fps = tonumber(r.GetExtState("FPSControl", "fps")) or 24
    config.adjust_grid = r.GetExtState("FPSControl", "adjust_grid") == "1"
end

function SaveSettings()
    r.SetExtState("FPSControl", "fps", tostring(config.fps), true)
    r.SetExtState("FPSControl", "adjust_grid", config.adjust_grid and "1" or "0", true)
end

-- Get video track and its items
function GetVideoTrackItems()
    local track_count = r.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetTrackName(track)
        if name == config.track_name then
            local items = {}
            local item_count = r.CountTrackMediaItems(track)
            for j = 0, item_count - 1 do
                local item = r.GetTrackMediaItem(track, j)
                table.insert(items, item)
            end
            return items
        end
    end
    return {}
end

-- Apply FPS
function ApplyFPS()
    local items = GetVideoTrackItems()
    if #items == 0 then 
        r.ShowMessageBox("No items found on VIDEO track", "Error", 0)
        return 
    end

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)

    -- Set grid size to match frame length if enabled
    local item_length = 1 / config.fps
    if config.adjust_grid then
        r.SetProjectGrid(0, item_length/4)
        reaper.SetCurrentBPM(0, 60, true)
    end
    
    -- Adjust items
    local position = r.GetMediaItemInfo_Value(items[1], "D_POSITION")
    
    for _, item in ipairs(items) do
        r.SetMediaItemPosition(item, position, false)
        r.SetMediaItemLength(item, item_length, false)
        position = position + item_length
        r.UpdateItemInProject(item)
    end

    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.Undo_EndBlock("Apply FPS to Video Items", -1)
end

function Loop()
    if not config.window_position_set then
        r.ImGui_SetNextWindowSize(ctx, 400, 130)
        config.window_position_set = true
    end

    local visible, open = r.ImGui_Begin(ctx, 'FPS Control', true, WINDOW_FLAGS)
    
    if visible then
        local fps_changed
        fps_changed, config.fps = r.ImGui_SliderInt(ctx, 'Frames per Second', config.fps, 1, 60)
        
        local grid_changed
        grid_changed, config.adjust_grid = r.ImGui_Checkbox(ctx, "Adjust Grid to FPS", config.adjust_grid)
        
        r.ImGui_Spacing(ctx)
        if r.ImGui_Button(ctx, 'Apply', -1, 30) then
            ApplyFPS()
            SaveSettings()
        end
        
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(Loop)
    end
end

function Start()
    LoadSettings()
    Loop()
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
    end
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()
