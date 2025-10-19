-- @description Stop Motion Camera Control with Preview
-- @version 1.0
-- @author Claude

local r = reaper

local ctx = r.ImGui_CreateContext('Stop Motion Camera')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()
local config = {
    output_folder = "",
    fps = 24,
    auto_increment = true,
    frame_counter = 1,
    window_position_set = false,
    virtual_camera_device = "OBS Virtual Camera"
}

function LoadSettings()
    config.output_folder = r.GetExtState("StopMotionCamera", "output_folder") or ""
    config.frame_counter = tonumber(r.GetExtState("StopMotionCamera", "frame_counter")) or 1
    config.fps = tonumber(r.GetExtState("StopMotionCamera", "fps")) or 24
end

function SaveSettings()
    r.SetExtState("StopMotionCamera", "output_folder", config.output_folder, true)
    r.SetExtState("StopMotionCamera", "frame_counter", tostring(config.frame_counter), true)
    r.SetExtState("StopMotionCamera", "fps", tostring(config.fps), true)
end

function GetOrCreateVideoTrack()
    local track_count = r.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetTrackName(track)
        if name == "VIDEO" then
            return track
        end
    end
    
    local track = r.AddTrackToProject(-1)
    r.GetSetMediaTrackInfo_String(track, "P_NAME", "VIDEO", true)
    return track
end

function UpdateProjectFrameRate()
    -- Set project framerate
    r.SNM_SetIntConfigVar("projfrbase", config.fps)
    r.SNM_SetIntConfigVar("projfrdenom", 1)
    r.UpdateTimeline()
    
    -- Set grid to frame
    local frame_length = 1 / config.fps
    r.SetProjectGrid(0, frame_length)
    
    -- Set timebase to time
    r.Main_OnCommand(40904, 0)  -- Set project timebase to time
end

function CapturePhoto()
    if config.output_folder == "" then
        local browse_cmd = 'powershell -command "& {Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.FolderBrowserDialog; $f.ShowDialog(); $f.SelectedPath}"'
        local handle = io.popen(browse_cmd)
        local result = handle:read("*a")
        handle:close()
        
        if result and result:match("%S") then
            config.output_folder = result:gsub("[\r\n]+", "")
            SaveSettings()
        else
            return false
        end
    end

    if not r.file_exists(config.output_folder) then
        r.RecursiveCreateDirectory(config.output_folder, 0)
    end

    local filename = string.format("%s/frame_%04d.png", config.output_folder, config.frame_counter)
    local ffmpeg_cmd = string.format('ffmpeg -y -f dshow -i video="%s" -frames:v 1 "%s"', 
        config.virtual_camera_device:gsub('"', '\\"'), filename)

    local result = os.execute(ffmpeg_cmd)
    if not result then 
        r.ShowMessageBox("FFmpeg capture failed", "Error", 0)
        return false 
    end

    local timeout = 50
    while not r.file_exists(filename) and timeout > 0 do
        r.defer(function() end)
        timeout = timeout - 1
    end

    if not r.file_exists(filename) then
        r.ShowMessageBox("Photo capture timed out", "Error", 0)
        return false
    end

    r.Undo_BeginBlock()
    
    local video_track = GetOrCreateVideoTrack()
    local item_length = 1 / config.fps
    local last_pos = 0
    local item_count = r.CountTrackMediaItems(video_track)
    
    if item_count > 0 then
        local last_item = r.GetTrackMediaItem(video_track, item_count - 1)
        last_pos = r.GetMediaItemInfo_Value(last_item, "D_POSITION") + 
                  r.GetMediaItemInfo_Value(last_item, "D_LENGTH")
    end

    local item = r.AddMediaItemToTrack(video_track)
    local take = r.AddTakeToMediaItem(item)
    local source = r.PCM_Source_CreateFromFile(filename)
    
    if source then
        r.SetMediaItemTake_Source(take, source)
        r.SetMediaItemInfo_Value(item, "D_POSITION", last_pos)
        r.SetMediaItemInfo_Value(item, "D_LENGTH", item_length)
        r.UpdateItemInProject(item)
        
        r.SetEditCurPos(last_pos + item_length, true, false)

        if config.auto_increment then
            config.frame_counter = config.frame_counter + 1
            SaveSettings()
        end
    end

    r.Undo_EndBlock("Capture Stop Motion Frame", -1)
    reaper.gmem_write(0, config.frame_counter)
    return true
end

function ApplyFPS()
    local video_track = GetOrCreateVideoTrack()
    local items = {}
    local item_count = r.CountTrackMediaItems(video_track)
    for i = 0, item_count - 1 do
        items[#items + 1] = r.GetTrackMediaItem(video_track, i)
    end

    if #items == 0 then return end

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)

    local item_length = 1 / config.fps
    UpdateProjectFrameRate()

    local position = 0
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
        r.ImGui_SetNextWindowSize(ctx, 400, 300)
        config.window_position_set = true
    end

    local visible, open = r.ImGui_Begin(ctx, 'Stop Motion Camera', true, WINDOW_FLAGS)

    if visible then
        r.ImGui_Text(ctx, "Output: " .. (config.output_folder ~= "" and config.output_folder or "None"))
        
        if r.ImGui_Button(ctx, 'Select Folder') then
            local retval, folder = r.GetUserInputs("Select Output Folder", 1, 
                "Folder Path:,extrawidth=150", config.output_folder)
            if retval then 
                config.output_folder = folder 
                SaveSettings()
            end
        end

        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)

        local fps_changed
        fps_changed, config.fps = r.ImGui_SliderInt(ctx, 'Frames per Second', config.fps, 1, 60)
        if fps_changed then
            ApplyFPS()
        end

        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)

        counter_changed, config.frame_counter = r.ImGui_InputInt(ctx, 'Next Frame Number', config.frame_counter)
        increment_changed, config.auto_increment = r.ImGui_Checkbox(ctx, "Auto Increment Frame Number", config.auto_increment)
        
        r.ImGui_Spacing(ctx)
        
        if r.ImGui_Button(ctx, 'Capture Frame', -1, 40) then
            CapturePhoto()
        end

        r.ImGui_End(ctx)
    end

    if open then
        r.defer(Loop)
    else
        SaveSettings()
    end
end

function Start()
    LoadSettings()
    UpdateProjectFrameRate()
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
