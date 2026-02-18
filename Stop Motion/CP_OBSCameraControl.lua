-- @description Camera Control for Stop Motion
-- @version 1.5
-- @author Claude

local r = reaper

local ctx = r.ImGui_CreateContext('Camera Control')
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
    config.output_folder = r.GetExtState("CameraControl", "output_folder") or ""
    config.frame_counter = tonumber(r.GetExtState("CameraControl", "frame_counter")) or 1
    config.fps = tonumber(r.GetExtState("CameraControl", "fps")) or 24
end

function SaveSettings()
    r.SetExtState("CameraControl", "output_folder", config.output_folder, true)
    r.SetExtState("CameraControl", "frame_counter", tostring(config.frame_counter), true)
    r.SetExtState("CameraControl", "fps", tostring(config.fps), true)
end

function CapturePhoto()
    if config.output_folder == "" then
        local retval, folder = r.GetUserInputs("Select Output Folder", 1, "Folder Path:,extrawidth=200", "")
        if not retval then return false end
        config.output_folder = folder
    end

    if not r.file_exists(config.output_folder) then
        r.RecursiveCreateDirectory(config.output_folder, 0)
    end

    local filename = string.format("%s/frame_%04d.png", config.output_folder, config.frame_counter)
    
    local ffmpeg_cmd = string.format('ffmpeg -y -f dshow -i video="%s" -frames:v 1 "%s"', 
        config.virtual_camera_device, filename)
    
    local result = os.execute(ffmpeg_cmd)
    if not result then 
        r.ShowMessageBox("FFmpeg capture failed", "Error", 0)
        return false 
    end

    -- Wait for file to be created
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

    -- Find or create VIDEO track
    local track_count = r.CountTracks(0)
    local video_track = nil
    for i = 0, track_count - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetTrackName(track)
        if name == "VIDEO" then
            video_track = track
            break
        end
    end

    -- Create VIDEO track if not found
    if not video_track then
        video_track = r.AddTrackToProject(-1)
        r.GetSetMediaTrackInfo_String(video_track, "P_NAME", "VIDEO", true)
    end

    -- Calculate item length based on FPS
    local item_length = 1 / config.fps

    -- Add media item
    local item = r.AddMediaItemToTrack(video_track)
    local take = r.AddTakeToMediaItem(item)
    local source = r.PCM_Source_CreateFromFile(filename)
    
    if source then
        r.SetMediaItemTake_Source(take, source)
        
        -- Place at current cursor position
        local cursor_pos = r.GetCursorPosition()
        r.SetMediaItemInfo_Value(item, "D_POSITION", cursor_pos)
        r.SetMediaItemInfo_Value(item, "D_LENGTH", item_length)
        
        r.UpdateItemInProject(item)
        
        -- Move cursor to end of item
        r.SetEditCurPos(cursor_pos + item_length, false, false)
    end

    r.Undo_EndBlock("Capture Photo", -1)
    r.UpdateArrange()

    config.frame_counter = config.frame_counter + 1
    SaveSettings()

    return true
end

function Loop()
    if not config.window_position_set then
        r.ImGui_SetNextWindowSize(ctx, 400, 250)
        config.window_position_set = true
    end

    local visible, open = r.ImGui_Begin(ctx, 'Camera Control', true, WINDOW_FLAGS)
   
    if visible then
        r.ImGui_Text(ctx, "Output: " .. (config.output_folder ~= "" and config.output_folder or "None"))
        
        if r.ImGui_Button(ctx, 'Select Folder') then
            local retval, folder = r.GetUserInputs("Select Output Folder", 1, "Folder Path:,extrawidth=150", config.output_folder)
            if retval then 
                config.output_folder = folder 
                SaveSettings()
            end
        end
       
        r.ImGui_Spacing(ctx)
       
        local fps_changed
        fps_changed, config.fps = r.ImGui_SliderInt(ctx, 'Frames per Second', config.fps, 1, 60)
       
        local virtual_camera_changed
        virtual_camera_changed, config.virtual_camera_device = r.ImGui_InputText(ctx, 'Virtual Camera Device', config.virtual_camera_device)
       
        r.ImGui_Spacing(ctx)
       
        local counter_changed
        counter_changed, config.frame_counter = r.ImGui_InputInt(ctx, 'Next Frame Number', config.frame_counter)
       
        local increment_changed
        increment_changed, config.auto_increment = r.ImGui_Checkbox(ctx, "Auto Increment Frame Number", config.auto_increment)
       
        r.ImGui_Spacing(ctx)
       
        if r.ImGui_Button(ctx, 'Capture Photo', -1, 40) then
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