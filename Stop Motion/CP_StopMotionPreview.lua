-- @description Stop Motion Preview - Unified Live/Playback with Onion Skin
-- @version 1.0
-- @author Claude

local r = reaper

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local SCRIPT_NAME = "StopMotionPreview"

local config = {
    window_width = 640,
    window_height = 480,

    -- Camera settings
    camera_device = "DroidCam Video",
    output_folder = "",
    frame_counter = 1,
    fps = 12,

    -- Preview settings
    mode = "live",  -- "live" or "play"
    auto_mode = true,  -- Auto switch based on transport state

    -- Onion skin
    onion_enabled = true,
    onion_opacity = 0.3,
    onion_frames = 2,

    -- Live capture (lower = better performance, FFmpeg has startup overhead)
    live_refresh_rate = 2,  -- FPS for live preview (2 fps is reasonable with FFmpeg)

    -- Project/Grid settings
    adjust_grid = true,  -- Automatically adjust grid to match FPS

    -- Internal
    preview_width = 0,
    preview_height = 0,
}

-- ============================================================================
-- STYLE LOADER INTEGRATION
-- ============================================================================

local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
local style_loader = nil
if r.file_exists(style_loader_path) then
    local loader_func = dofile(style_loader_path)
    if loader_func then style_loader = loader_func() end
end

local ctx = r.ImGui_CreateContext(SCRIPT_NAME)

-- Apply fonts ONCE at context creation
if style_loader then
    style_loader.ApplyFontsToContext(ctx)
end

local function GetStyleValue(path, default)
    if style_loader and style_loader.GetValue then
        return style_loader.GetValue(path, default)
    end
    return default
end

-- Simplified style handling - no push/pop for this prototype
local function ApplyStyle()
    -- Skip style pushing for now to avoid pop errors
end

local function ClearStyle()
    -- Skip style clearing for now
end

-- ============================================================================
-- STATE
-- ============================================================================

-- ============================================================================
-- DEBUG LOGGING
-- ============================================================================

local LOG_FILE = reaper.GetResourcePath() .. "/Scripts/CP_Scripts/Stop Motion/debug_log.txt"

local function Log(msg)
    local file = io.open(LOG_FILE, "a")
    if file then
        file:write(os.date("[%H:%M:%S] ") .. tostring(msg) .. "\n")
        file:close()
    end
end

local function ClearLog()
    local file = io.open(LOG_FILE, "w")
    if file then
        file:write("=== Stop Motion Debug Log ===\n")
        file:write("Started: " .. os.date() .. "\n\n")
        file:close()
    end
end

-- Clear log on script start
ClearLog()
Log("Script initialized")
Log("Temp dir: " .. (os.getenv("TEMP") or "nil"))

local state = {
    is_running = false,
    last_capture_time = 0,
    last_file_time = 0,  -- Last modification time of live file
    live_image = nil,
    live_image_path = "",
    live_capture_count = 0,
    frame_images = {},  -- Cache for timeline frames
    current_frame_idx = 0,
    current_frame_path = "",  -- Track current displayed frame path
    temp_dir = os.getenv("TEMP") or "/tmp",
    available_cameras = {},
    camera_scan_done = false,
    live_preview_active = false,  -- Is live preview running?
    ffmpeg_running = false,  -- Is continuous FFmpeg running?
    ffmpeg_pid_file = "",  -- File to track FFmpeg process
}

-- Forward declaration for image cache (used by capture functions)
local loaded_images = {}  -- {path = {image, width, height, load_time}}

-- Silent command execution using REAPER's ExecProcess (no window)
local function RunSilent(cmd, timeout_ms)
    timeout_ms = timeout_ms or 10000
    -- ExecProcess needs cmd /c to run commands
    local full_cmd = 'cmd /c ' .. cmd
    Log("RunSilent executing: " .. full_cmd:sub(1, 100))

    -- ExecProcess runs without showing a window
    -- Returns: retval (string with exit code + output) or nil on timeout
    local ret = r.ExecProcess(full_cmd, timeout_ms)
    if ret then
        -- Extract exit code from the return value (first line is exit code)
        local exit_code = ret:match("^(%d+)")
        Log("ExecProcess exit code: " .. tostring(exit_code))
        if exit_code ~= "0" then
            Log("ExecProcess output: " .. ret:sub(1, 200))
        end
        return exit_code == "0"
    else
        Log("ExecProcess returned nil (timeout?)")
        return false
    end
end

-- ============================================================================
-- CONTINUOUS FFMPEG CAPTURE (Background Process)
-- ============================================================================

local function StartContinuousCapture()
    if state.ffmpeg_running then
        Log("FFmpeg already running, skipping start")
        return true
    end

    Log("=== StartContinuousCapture ===")

    local live_file = state.temp_dir .. "\\stopmotion_live.jpg"
    local batch_file = state.temp_dir .. "\\ffmpeg_continuous.bat"
    local vbs_file = state.temp_dir .. "\\ffmpeg_launcher.vbs"

    state.live_image_path = live_file

    -- Delete old live file to ensure fresh start
    os.remove(live_file)

    -- Create batch file that runs FFmpeg
    -- -update 1 overwrites the same file continuously
    -- Using JPEG for faster encoding than PNG
    local bat = io.open(batch_file, "w")
    if not bat then
        Log("ERROR: Could not create batch file")
        return false
    end

    -- FFmpeg command: capture from camera, output 10fps to a single file that gets overwritten
    local ffmpeg_cmd = string.format(
        'ffmpeg -y -f dshow -rtbufsize 100M -i video="%s" -r 10 -q:v 2 -f image2 -update 1 "%s"',
        config.camera_device,
        live_file
    )

    bat:write('@echo off\r\n')
    bat:write(ffmpeg_cmd .. '\r\n')
    bat:close()
    Log("Batch file created: " .. batch_file)
    Log("FFmpeg command: " .. ffmpeg_cmd)

    -- Create VBS script to launch batch file invisibly (no window at all)
    local vbs = io.open(vbs_file, "w")
    if not vbs then
        Log("ERROR: Could not create VBS file")
        return false
    end

    vbs:write('Set WshShell = CreateObject("WScript.Shell")\r\n')
    vbs:write('WshShell.Run """' .. batch_file:gsub("\\", "\\\\") .. '""", 0, False\r\n')
    vbs:close()
    Log("VBS launcher created: " .. vbs_file)

    -- Execute VBS to start FFmpeg in background (completely hidden)
    local ret = os.execute('wscript "' .. vbs_file .. '"')
    Log("VBS execution returned: " .. tostring(ret))

    state.ffmpeg_running = true
    state.last_file_time = 0

    -- Wait a moment for FFmpeg to start and create first frame
    Log("Waiting for FFmpeg to initialize...")

    return true
end

local function StopContinuousCapture()
    if not state.ffmpeg_running then
        return
    end

    Log("=== StopContinuousCapture ===")

    -- Kill FFmpeg processes
    -- Using taskkill to terminate ffmpeg.exe
    os.execute('taskkill /f /im ffmpeg.exe >nul 2>&1')

    state.ffmpeg_running = false
    Log("FFmpeg stopped")
end


-- ============================================================================
-- SETTINGS PERSISTENCE
-- ============================================================================

local function SaveSettings()
    local keys = {"camera_device", "output_folder", "frame_counter", "fps",
                  "mode", "auto_mode", "onion_enabled", "onion_opacity",
                  "onion_frames", "live_refresh_rate", "window_width", "window_height",
                  "adjust_grid"}

    for _, key in ipairs(keys) do
        local value = config[key]
        local value_str = tostring(value)
        if type(value) == "boolean" then
            value_str = value and "1" or "0"
        end
        r.SetExtState(SCRIPT_NAME, key, value_str, true)
    end
end

local function LoadSettings()
    local defaults = {
        camera_device = "DroidCam Video",
        output_folder = "",
        frame_counter = 1,
        fps = 12,
        mode = "live",
        auto_mode = true,
        onion_enabled = true,
        onion_opacity = 0.3,
        onion_frames = 2,
        live_refresh_rate = 2,
        window_width = 640,
        window_height = 480,
        adjust_grid = true,
    }

    for key, default in pairs(defaults) do
        local saved = r.GetExtState(SCRIPT_NAME, key)
        if saved ~= "" then
            if type(default) == "number" then
                config[key] = tonumber(saved) or default
            elseif type(default) == "boolean" then
                config[key] = saved == "1"
            else
                config[key] = saved
            end
        else
            config[key] = default
        end
    end
end

-- ============================================================================
-- CAMERA DETECTION
-- ============================================================================

local function ScanAvailableCameras()
    Log("=== ScanAvailableCameras START ===")
    state.available_cameras = {}
    state.scan_output = ""

    local temp_file = state.temp_dir .. "\\ffmpeg_devices.txt"
    local batch_file = state.temp_dir .. "\\scan_cameras.bat"

    Log("temp_file: " .. temp_file)
    Log("batch_file: " .. batch_file)

    -- Delete old files first
    os.remove(temp_file)
    os.remove(batch_file)

    -- Create a batch file to run FFmpeg and capture output
    Log("Creating batch file...")
    local bat = io.open(batch_file, "w")
    if not bat then
        Log("ERROR: Could not create batch file")
        state.scan_output = "Could not create batch file"
        state.camera_scan_done = true
        return
    end

    bat:write('@echo off\r\n')
    bat:write('chcp 65001 >nul\r\n')  -- UTF-8 for unicode device names
    -- Redirect BOTH stdout and stderr to file (devices list is on stderr)
    bat:write('ffmpeg -hide_banner -list_devices true -f dshow -i dummy >"' .. temp_file .. '" 2>&1\r\n')
    bat:close()
    Log("Batch file created")

    -- Execute silently via REAPER's ExecProcess
    Log("Executing FFmpeg via ExecProcess...")
    local ret = r.ExecProcess('cmd /c "' .. batch_file .. '"', 10000)
    Log("ExecProcess returned: " .. tostring(ret))

    -- Check if output file exists
    Log("Checking for output file...")
    if r.file_exists(temp_file) then
        Log("Output file exists")
    else
        Log("ERROR: Output file does not exist")
        state.scan_output = "FFmpeg did not create output file. Check debug_log.txt"
        state.camera_scan_done = true
        return
    end

    -- Read the output file
    local file = io.open(temp_file, "r")
    if not file then
        Log("ERROR: Could not open output file")
        state.scan_output = "Could not read FFmpeg output."
        state.camera_scan_done = true
        return
    end

    local output = file:read("*a")
    file:close()
    Log("Output file size: " .. #output .. " bytes")
    Log("Output preview: " .. output:sub(1, 200))

    if not output or output == "" then
        Log("ERROR: Output is empty")
        state.scan_output = "FFmpeg returned empty output."
        state.camera_scan_done = true
        return
    end

    state.scan_output = output

    -- Parse output for video devices
    -- FFmpeg format: [dshow @ address] "Device Name" (video)
    Log("Parsing output...")
    for line in output:gmatch("[^\r\n]+") do
        -- Look for lines with (video) or (none) - video devices
        if line:match("%[dshow @") then
            local device_name = line:match('"([^"]+)"')
            local device_type = line:match("%((%w+)%)%s*$")
            Log("Line: " .. line:sub(1, 80))
            Log("  device_name: " .. tostring(device_name) .. ", type: " .. tostring(device_type))

            -- Include video devices and "none" type (like OBS Virtual Camera)
            if device_name and not line:match("Alternative name") then
                if device_type == "video" or device_type == "none" then
                    Log("Found video device: " .. device_name)
                    table.insert(state.available_cameras, device_name)
                end
            end
        end
    end

    Log("Total cameras found: " .. #state.available_cameras)
    Log("=== ScanAvailableCameras END ===")
    state.camera_scan_done = true
end

-- ============================================================================
-- VIDEO TRACK MANAGEMENT
-- ============================================================================

local function GetOrCreateVideoTrack()
    local track_count = r.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetTrackName(track)
        if name == "VIDEO" then
            return track
        end
    end

    -- Create new track at the end
    r.InsertTrackAtIndex(track_count, true)
    local track = r.GetTrack(0, track_count)
    r.GetSetMediaTrackInfo_String(track, "P_NAME", "VIDEO", true)
    return track
end

local function GetVideoTrackFrames()
    local frames = {}
    local track_count = r.CountTracks(0)

    for i = 0, track_count - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetTrackName(track)
        if name == "VIDEO" then
            local item_count = r.CountTrackMediaItems(track)
            for j = 0, item_count - 1 do
                local item = r.GetTrackMediaItem(track, j)
                local take = r.GetActiveTake(item)
                if take then
                    local source = r.GetMediaItemTake_Source(take)
                    if source then
                        local filename = r.GetMediaSourceFileName(source)
                        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
                        local length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
                        table.insert(frames, {
                            path = filename,
                            position = pos,
                            length = length,
                            item = item
                        })
                    end
                end
            end
            break
        end
    end

    -- Sort by position
    table.sort(frames, function(a, b) return a.position < b.position end)
    return frames
end

local function GetFrameAtPosition(pos, frames)
    for i, frame in ipairs(frames) do
        if pos >= frame.position and pos < frame.position + frame.length then
            return i, frame
        end
    end
    return nil, nil
end

-- ============================================================================
-- FPS / PROJECT GRID MANAGEMENT
-- ============================================================================

-- Apply FPS settings to the project (framerate, grid, BPM)
local function ApplyFPSToProject()
    if not config.adjust_grid then return end

    local item_length = 1 / config.fps

    -- Set project framerate using SWS extension
    -- This affects the ruler when set to "Frames" mode
    if r.SNM_SetDoubleConfigVar then
        r.SNM_SetDoubleConfigVar("projfrate", config.fps)
    end

    -- Set grid to 1/4 of frame length for finer control (matches original script)
    r.SetProjectGrid(0, item_length / 4)

    -- Set BPM to 60 for easier time calculations (1 beat = 1 second)
    r.SetCurrentBPM(0, 60, true)

    -- Force update
    r.UpdateTimeline()

    Log("Applied FPS to project: " .. config.fps .. " fps, grid=" .. (item_length/4))
end

-- Apply FPS to all items on the VIDEO track (reposition and resize)
local function ApplyFPSToItems()
    local track_count = r.CountTracks(0)
    local video_track = nil

    -- Find VIDEO track
    for i = 0, track_count - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetTrackName(track)
        if name == "VIDEO" then
            video_track = track
            break
        end
    end

    if not video_track then
        r.ShowMessageBox("No VIDEO track found", "Error", 0)
        return
    end

    local item_count = r.CountTrackMediaItems(video_track)
    if item_count == 0 then
        r.ShowMessageBox("No items on VIDEO track", "Error", 0)
        return
    end

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)

    -- Apply grid settings
    ApplyFPSToProject()

    -- Get first item's position as starting point
    local first_item = r.GetTrackMediaItem(video_track, 0)
    local position = r.GetMediaItemInfo_Value(first_item, "D_POSITION")
    local item_length = 1 / config.fps

    -- Reposition and resize all items
    for i = 0, item_count - 1 do
        local item = r.GetTrackMediaItem(video_track, i)
        r.SetMediaItemPosition(item, position, false)
        r.SetMediaItemLength(item, item_length, false)
        position = position + item_length
        r.UpdateItemInProject(item)
    end

    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.Undo_EndBlock("Apply FPS to Video Items", -1)

    Log("Applied FPS to " .. item_count .. " items at " .. config.fps .. " fps")
end

-- ============================================================================
-- FRAME CAPTURE (Save to Timeline)
-- ============================================================================

local function CaptureAndSaveFrame()
    Log("=== CaptureAndSaveFrame START ===")

    if config.output_folder == "" then
        -- Use REAPER's file browser for folder selection
        local retval, folder = r.JS_Dialog_BrowseForFolder("Select Output Folder", "")
        if retval == 1 and folder ~= "" then
            config.output_folder = folder
            SaveSettings()
            Log("Output folder set to: " .. config.output_folder)
        else
            -- Fallback to GetUserInputs if JS extension not available
            local ok, input_folder = r.GetUserInputs("Output Folder (FULL PATH)", 1,
                "Folder Path (e.g. C:\\Users\\You\\StopMotion):,extrawidth=300", "")
            if ok and input_folder ~= "" then
                folder = input_folder
                -- Ensure it's an absolute path
                if not folder:match("^%a:") then
                    -- Relative path - prepend project folder or temp
                    local proj_path = r.GetProjectPath()
                    if proj_path and proj_path ~= "" then
                        folder = proj_path .. "\\" .. folder
                    else
                        folder = state.temp_dir .. "\\" .. folder
                    end
                    Log("Converted to absolute path: " .. folder)
                end
                config.output_folder = folder
                SaveSettings()
                Log("Output folder set to: " .. config.output_folder)
            else
                Log("User cancelled folder selection")
                return false
            end
        end
    end

    if not r.file_exists(config.output_folder) then
        Log("Creating output folder: " .. config.output_folder)
        r.RecursiveCreateDirectory(config.output_folder, 0)
    end

    local filename = string.format("%s\\frame_%04d.png", config.output_folder, config.frame_counter)
    Log("Target filename: " .. filename)

    local capture_success = false

    -- If FFmpeg continuous is running, copy the current live file (faster, no camera conflict)
    if state.ffmpeg_running and state.live_image_path ~= "" and r.file_exists(state.live_image_path) then
        Log("Using live file as source: " .. state.live_image_path)
        -- Copy JPEG to PNG (or just copy if we keep JPEG)
        -- For simplicity, let's convert JPEG to PNG using FFmpeg (single fast operation)
        local cmd = string.format(
            'ffmpeg -y -hide_banner -loglevel error -i "%s" "%s"',
            state.live_image_path,
            filename
        )
        Log("Convert command: " .. cmd)
        local ret = RunSilent(cmd, 5000)
        capture_success = ret and r.file_exists(filename)
    else
        -- FFmpeg not running - capture directly from camera
        Log("Capturing directly from camera...")
        local cmd = string.format(
            'ffmpeg -y -hide_banner -loglevel error -f dshow -i video="%s" -frames:v 1 "%s"',
            config.camera_device,
            filename
        )
        Log("Command: " .. cmd)
        local ret = RunSilent(cmd, 10000)
        capture_success = ret and r.file_exists(filename)
    end

    -- Check if file was created
    if not capture_success or not r.file_exists(filename) then
        Log("ERROR: File not created!")
        r.ShowMessageBox("Capture failed. Make sure the camera is available.\n\nCheck debug_log.txt for details.", "Error", 0)
        return false
    end

    Log("File created successfully")

    -- Add to timeline
    r.Undo_BeginBlock()

    -- Ensure project grid is set up for the current FPS
    ApplyFPSToProject()

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

        config.frame_counter = config.frame_counter + 1
        SaveSettings()
    end

    r.Undo_EndBlock("Capture Stop Motion Frame", -1)
    return true
end

-- ============================================================================
-- IMAGE MANAGEMENT
-- ============================================================================

-- Check if JPEG data is complete (has valid start and end markers)
local function IsJpegComplete(data)
    if not data or #data < 100 then return false end

    -- JPEG must start with FFD8 (SOI - Start Of Image)
    local b1, b2 = data:byte(1, 2)
    if b1 ~= 0xFF or b2 ~= 0xD8 then return false end

    -- JPEG must end with FFD9 (EOI - End Of Image)
    local e1, e2 = data:byte(#data - 1, #data)
    if e1 ~= 0xFF or e2 ~= 0xD9 then return false end

    return true
end

-- Copy file to avoid race condition with FFmpeg writing
local function SafeCopyFile(src, dst)
    local src_file = io.open(src, "rb")
    if not src_file then return false end

    local content = src_file:read("*a")
    src_file:close()

    -- Validate JPEG is complete before copying
    if not IsJpegComplete(content) then
        return false  -- JPEG incomplete, skip this frame
    end

    local dst_file = io.open(dst, "wb")
    if not dst_file then return false end

    dst_file:write(content)
    dst_file:close()
    return true
end

-- Check if an image pointer is still valid (without throwing errors)
local function IsImageValid(img)
    if not img then return false end
    -- Use ValidatePtr if available (doesn't throw errors)
    if r.ImGui_ValidatePtr then
        return r.ImGui_ValidatePtr(img, 'ImGui_Image*')
    end
    -- Fallback: try pcall but suppress any output
    local ok, result = pcall(function()
        local w, h = r.ImGui_Image_GetSize(img)
        return w and w > 0
    end)
    return ok and result
end

local function LoadImage(path, force_reload, is_live_file)
    if not path or path == "" then return nil, 0, 0 end
    if not r.file_exists(path) then return nil, 0, 0 end

    -- For live files, copy to a temp file first to avoid race condition
    local load_path = path
    if is_live_file then
        local safe_path = state.temp_dir .. "\\stopmotion_safe_read.jpg"
        if SafeCopyFile(path, safe_path) then
            load_path = safe_path
        else
            -- Copy failed, return cached if available
            local cached = loaded_images[path]
            if cached and IsImageValid(cached.image) then
                return cached.image, cached.width, cached.height
            end
            return nil, 0, 0
        end
    end

    -- Check cache (don't reload unless forced)
    local cached = loaded_images[path]
    if cached and not force_reload then
        if IsImageValid(cached.image) then
            return cached.image, cached.width, cached.height
        else
            -- Cached image is invalid, clear it
            loaded_images[path] = nil
            cached = nil
        end
    end

    -- Try to load new image with error handling
    local ok, img = pcall(r.ImGui_CreateImage, load_path)
    if ok and img then
        -- Get size (wrap in pcall in case image is corrupt)
        local size_ok, w, h = pcall(function()
            return r.ImGui_Image_GetSize(img)
        end)
        if size_ok and w and w > 0 and h and h > 0 then
            -- Cache with original path as key
            loaded_images[path] = {image = img, width = w, height = h, load_time = os.time()}
            return img, w, h
        end
    end

    -- If loading failed, return cached version if available
    if cached and IsImageValid(cached.image) then
        return cached.image, cached.width, cached.height
    end

    return nil, 0, 0
end

local function CleanImageCache(keep_path)
    local now = os.time()
    local to_remove = {}
    for path, data in pairs(loaded_images) do
        -- Don't remove the live preview image or recent images
        if path ~= keep_path and now - data.load_time > 60 then
            table.insert(to_remove, path)
        end
    end
    for _, path in ipairs(to_remove) do
        loaded_images[path] = nil
    end
end

-- ============================================================================
-- RENDERING
-- ============================================================================

local function DrawPreviewArea(available_w, available_h)
    local frames = GetVideoTrackFrames()
    local play_state = r.GetPlayState()
    local cursor_pos = r.GetCursorPosition()

    if play_state == 1 then  -- Playing
        cursor_pos = r.GetPlayPosition()
    end

    -- Auto mode switching
    if config.auto_mode then
        if play_state == 1 then
            config.mode = "play"
        else
            config.mode = "live"
        end
    end

    local current_image = nil
    local img_w, img_h = 0, 0
    local onion_images = {}

    if config.mode == "live" then
        -- Live mode: show camera feed from continuous FFmpeg capture
        if state.live_preview_active and state.ffmpeg_running then
            local now = r.time_precise()
            -- Reload image at the configured refresh rate
            if now - state.last_capture_time > (1 / config.live_refresh_rate) then
                state.last_capture_time = now
                -- Force reload by clearing cache for this file
                if state.live_image_path ~= "" then
                    loaded_images[state.live_image_path] = nil
                end
            end
        end

        -- Show live preview image (continuously updated by FFmpeg)
        -- Use is_live_file=true to copy file before reading (avoids race condition)
        if state.live_image_path ~= "" and r.file_exists(state.live_image_path) then
            current_image, img_w, img_h = LoadImage(state.live_image_path, false, true)
        end

        -- Onion skin from previous frames on timeline
        if config.onion_enabled and #frames > 0 then
            local start_idx = math.max(1, #frames - config.onion_frames + 1)
            for i = start_idx, #frames do
                local img = LoadImage(frames[i].path)
                if img then
                    table.insert(onion_images, img)
                end
            end
        end

    else
        -- Play mode: show frame at cursor position
        local frame_idx, frame = GetFrameAtPosition(cursor_pos, frames)

        if frame then
            -- Clear cache when switching to a different frame to avoid stale handles
            if state.current_frame_path ~= frame.path then
                -- Clear old frame from cache
                if state.current_frame_path ~= "" then
                    loaded_images[state.current_frame_path] = nil
                end
                state.current_frame_path = frame.path
            end

            current_image, img_w, img_h = LoadImage(frame.path)
            state.current_frame_idx = frame_idx

            -- Onion skin from previous frames (but NOT during playback)
            if config.onion_enabled and play_state ~= 1 then
                local start_idx = math.max(1, frame_idx - config.onion_frames)
                for i = start_idx, frame_idx - 1 do
                    local img = LoadImage(frames[i].path)
                    if img then
                        table.insert(onion_images, img)
                    end
                end
            end
        else
            -- No frame at cursor - clear tracking
            if state.current_frame_path ~= "" then
                loaded_images[state.current_frame_path] = nil
                state.current_frame_path = ""
            end
        end
    end

    -- Calculate display size maintaining aspect ratio
    local display_w, display_h = available_w, available_h
    if img_w > 0 and img_h > 0 then
        local aspect = img_w / img_h
        local container_aspect = available_w / available_h

        if aspect > container_aspect then
            display_w = available_w
            display_h = available_w / aspect
        else
            display_h = available_h
            display_w = available_h * aspect
        end
    end

    -- Center the image
    local offset_x = (available_w - display_w) / 2
    local offset_y = (available_h - display_h) / 2

    local cursor_x, cursor_y = r.ImGui_GetCursorPos(ctx)

    -- Draw background
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local win_x, win_y = r.ImGui_GetWindowPos(ctx)
    local abs_x = win_x + cursor_x + offset_x
    local abs_y = win_y + cursor_y + offset_y

    r.ImGui_DrawList_AddRectFilled(draw_list,
        abs_x, abs_y,
        abs_x + display_w, abs_y + display_h,
        0x1A1A1AFF)

    -- Draw current frame FIRST (base layer)
    if current_image and IsImageValid(current_image) then
        r.ImGui_DrawList_AddImage(draw_list, current_image,
            abs_x, abs_y,
            abs_x + display_w, abs_y + display_h,
            0, 0, 1, 1, 0xFFFFFFFF)  -- Full opacity
    else
        -- No image placeholder
        r.ImGui_SetCursorPos(ctx, cursor_x + offset_x + display_w/2 - 50, cursor_y + offset_y + display_h/2)
        r.ImGui_Text(ctx, config.mode == "live" and "No Camera Feed" or "No Frame")
    end

    -- Draw onion skin layers ON TOP with transparency
    if #onion_images > 0 and config.onion_enabled then
        local base_alpha = math.floor(config.onion_opacity * 255)

        for idx, img in ipairs(onion_images) do
            if IsImageValid(img) then
                -- Fade older frames more (older = lower index = more transparent)
                local frame_alpha = math.floor(base_alpha * (idx / #onion_images))
                -- Red/orange tint to distinguish onion skin from current frame
                local frame_tint = 0xFFAAAA00 | frame_alpha
                pcall(r.ImGui_DrawList_AddImage, draw_list, img,
                    abs_x, abs_y,
                    abs_x + display_w, abs_y + display_h,
                    0, 0, 1, 1, frame_tint)
            end
        end
    end

    -- Reserve space with Dummy to properly set boundaries
    r.ImGui_SetCursorPos(ctx, cursor_x, cursor_y)
    r.ImGui_Dummy(ctx, available_w, available_h)
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================

local function MainLoop()
    ApplyStyle()

    local window_flags = r.ImGui_WindowFlags_NoCollapse()
    r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())

    local visible, open = r.ImGui_Begin(ctx, 'Stop Motion Preview###StopMotionPreview', true, window_flags)

    if visible then
        -- Header
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "STOP MOTION")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "STOP MOTION")
        end

        -- Close button
        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        r.ImGui_Separator(ctx)

        -- Main content
        if style_loader and style_loader.PushFont(ctx, "main") then
            DrawMainContent()
            style_loader.PopFont(ctx)
        else
            DrawMainContent()
        end

        r.ImGui_End(ctx)
    end

    ClearStyle()

    -- Periodic cache cleanup (keep current live image)
    if math.floor(r.time_precise()) % 10 == 0 then
        CleanImageCache(state.live_image_path)
    end

    if open then
        r.defer(MainLoop)
    else
        SaveSettings()
    end
end

function DrawMainContent()
    local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)

    -- Mode buttons
    local mode_width = 80
    local is_live = config.mode == "live"
    local is_play = config.mode == "play"

    if is_live then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xCC4444FF)
    end
    if r.ImGui_Button(ctx, "LIVE", mode_width) then
        config.mode = "live"
        config.auto_mode = false
    end
    if is_live then
        r.ImGui_PopStyleColor(ctx)
    end

    r.ImGui_SameLine(ctx)

    if is_play then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x44CC44FF)
    end
    if r.ImGui_Button(ctx, "PLAY", mode_width) then
        config.mode = "play"
        config.auto_mode = false
    end
    if is_play then
        r.ImGui_PopStyleColor(ctx)
    end

    r.ImGui_SameLine(ctx)
    local changed
    changed, config.auto_mode = r.ImGui_Checkbox(ctx, "Auto", config.auto_mode)

    r.ImGui_SameLine(ctx)
    r.ImGui_SetCursorPosX(ctx, r.ImGui_GetWindowWidth(ctx) - 280 - GetStyleValue("spacing.window_padding_x", 8))

    -- Live Preview toggle (starts/stops continuous FFmpeg)
    if state.live_preview_active and state.ffmpeg_running then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x44AA44FF)  -- Green when active
    else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x666666FF)
    end
    local live_label = state.ffmpeg_running and "LIVE ON" or "LIVE OFF"
    if r.ImGui_Button(ctx, live_label, 80) then
        if state.ffmpeg_running then
            -- Stop continuous capture
            StopContinuousCapture()
            state.live_preview_active = false
        else
            -- Start continuous capture
            state.live_preview_active = true
            StartContinuousCapture()
            state.last_capture_time = r.time_precise()
        end
    end
    r.ImGui_PopStyleColor(ctx)

    r.ImGui_SameLine(ctx)

    -- Status indicator
    if state.ffmpeg_running then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x44FF44FF)
        r.ImGui_Text(ctx, "REC")
        r.ImGui_PopStyleColor(ctx)
    else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x666666FF)
        r.ImGui_Text(ctx, "OFF")
        r.ImGui_PopStyleColor(ctx)
    end

    r.ImGui_SameLine(ctx)

    -- Capture button (save frame to project)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x4488CCFF)
    if r.ImGui_Button(ctx, "CAPTURE", 100) then
        CaptureAndSaveFrame()
    end
    r.ImGui_PopStyleColor(ctx)

    r.ImGui_Spacing(ctx)

    -- Preview area
    local avail_w = r.ImGui_GetContentRegionAvail(ctx)
    local preview_h = r.ImGui_GetContentRegionAvail(ctx) - 120  -- Leave space for controls
    if preview_h < 100 then preview_h = 100 end

    local child_flags_border = r.ImGui_ChildFlags_Border and r.ImGui_ChildFlags_Border() or 1
    r.ImGui_BeginChild(ctx, "preview_area", avail_w, preview_h, child_flags_border)
    local child_w = r.ImGui_GetContentRegionAvail(ctx)
    local child_h = preview_h - 10
    DrawPreviewArea(child_w, child_h)
    r.ImGui_EndChild(ctx)

    r.ImGui_Spacing(ctx)

    -- Controls
    if r.ImGui_CollapsingHeader(ctx, "Settings", r.ImGui_TreeNodeFlags_DefaultOpen()) then
        -- Camera selection - manual input with suggestions
        r.ImGui_Text(ctx, "Camera:")
        r.ImGui_SameLine(ctx)
        r.ImGui_SetNextItemWidth(ctx, 250)
        local cam_changed
        cam_changed, config.camera_device = r.ImGui_InputText(ctx, "##camera", config.camera_device)
        if cam_changed then SaveSettings() end

        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Scan") then
            state.camera_scan_done = false
            ScanAvailableCameras()
        end

        -- Show detected cameras as clickable suggestions
        if #state.available_cameras > 0 then
            r.ImGui_TextDisabled(ctx, "Detected:")
            r.ImGui_SameLine(ctx)
            for i, cam in ipairs(state.available_cameras) do
                if i > 1 then r.ImGui_SameLine(ctx) end
                if r.ImGui_SmallButton(ctx, cam) then
                    config.camera_device = cam
                    SaveSettings()
                end
            end
        elseif state.scan_output and state.scan_output ~= "" then
            -- Debug: show scan result if no cameras found
            r.ImGui_TextColored(ctx, 0xFF6666FF, "No cameras found. FFmpeg output:")
            r.ImGui_TextWrapped(ctx, state.scan_output:sub(1, 500))
        end

        -- FPS
        r.ImGui_SetNextItemWidth(ctx, 100)
        changed, config.fps = r.ImGui_SliderInt(ctx, "FPS", config.fps, 1, 60)
        if changed then
            SaveSettings()
            -- Auto-apply to project and items when FPS changes
            ApplyFPSToProject()
            -- Auto-apply to items if there are any
            local frames_on_track = GetVideoTrackFrames()
            if #frames_on_track > 0 then
                ApplyFPSToItems()
            end
        end

        r.ImGui_SameLine(ctx)
        r.ImGui_SetNextItemWidth(ctx, 100)
        changed, config.live_refresh_rate = r.ImGui_SliderInt(ctx, "Preview FPS", config.live_refresh_rate, 1, 30)
        if changed then SaveSettings() end

        r.ImGui_SameLine(ctx)
        changed, config.adjust_grid = r.ImGui_Checkbox(ctx, "Sync Grid", config.adjust_grid)
        if changed then
            SaveSettings()
            if config.adjust_grid then
                ApplyFPSToProject()
            end
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Synchronize project framerate and grid with FPS setting")
        end

        -- Onion skin
        r.ImGui_Spacing(ctx)
        changed, config.onion_enabled = r.ImGui_Checkbox(ctx, "Onion Skin", config.onion_enabled)
        if changed then SaveSettings() end

        if config.onion_enabled then
            r.ImGui_SameLine(ctx)
            r.ImGui_SetNextItemWidth(ctx, 100)
            changed, config.onion_opacity = r.ImGui_SliderDouble(ctx, "Opacity", config.onion_opacity, 0, 1, "%.2f")
            if changed then SaveSettings() end

            r.ImGui_SameLine(ctx)
            r.ImGui_SetNextItemWidth(ctx, 80)
            changed, config.onion_frames = r.ImGui_SliderInt(ctx, "Frames", config.onion_frames, 1, 5)
            if changed then SaveSettings() end
        end

        -- Frame info
        r.ImGui_Spacing(ctx)
        local frames = GetVideoTrackFrames()
        r.ImGui_Text(ctx, string.format("Timeline: %d frames | Next: frame_%04d", #frames, config.frame_counter))

        if config.output_folder ~= "" then
            r.ImGui_SameLine(ctx)
            r.ImGui_TextDisabled(ctx, "| " .. config.output_folder)
        end
    end
end

-- ============================================================================
-- INIT / EXIT
-- ============================================================================

local function Start()
    LoadSettings()
    ScanAvailableCameras()
    MainLoop()
end

local function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local current_state = r.GetToggleCommandState(cmdID)

    if current_state == -1 or current_state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        Start()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
    end
end

local function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
    SaveSettings()

    -- Stop FFmpeg if running
    if state.ffmpeg_running then
        Log("Stopping FFmpeg on exit...")
        StopContinuousCapture()
    end

    -- Cleanup temp files
    local temp_files = {
        state.temp_dir .. "\\stopmotion_live.jpg",
        state.temp_dir .. "\\stopmotion_safe_read.jpg",
        state.temp_dir .. "\\stopmotion_live_0.png",
        state.temp_dir .. "\\stopmotion_live_1.png",
        state.temp_dir .. "\\ffmpeg_continuous.bat",
        state.temp_dir .. "\\ffmpeg_launcher.vbs",
        state.temp_dir .. "\\file_attr.txt",
    }
    for _, temp_file in ipairs(temp_files) do
        if r.file_exists(temp_file) then
            os.remove(temp_file)
        end
    end

    Log("Script exited cleanly")
end

r.atexit(Exit)
ToggleScript()
