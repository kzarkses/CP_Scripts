-- Import OBS Live Video
local r = reaper

-- Path to the temporary video file
local TEMP_VIDEO_PATH = os.getenv("TEMP") .. "\\obs_live_video.mp4"

function ImportOBSLiveVideo()
    -- Check if file exists
    local f = io.open(TEMP_VIDEO_PATH, "r")
    if not f then 
        r.ShowMessageBox("OBS live video not found!", "Error", 0)
        return 
    end
    f:close()

    -- Get selected track or create a new one
    local track = r.GetSelectedTrack(0, 0)
    if not track then
        r.InsertTrackAtIndex(r.CountTracks(0), false)
        track = r.GetTrack(0, r.CountTracks(0) - 1)
        r.GetSetMediaTrackInfo_String(track, "P_NAME", "OBS Live Video", true)
    end

    -- Import media file
    local item = r.AddMediaItemToTrack(track)
    local take = r.AddTakeToMediaItem(item)
    local source = r.PCM_Source_CreateFromFile(TEMP_VIDEO_PATH)
    
    if source then
        r.SetMediaItemTake_Source(take, source)
        r.UpdateItemInProject(item)
        r.Main_OnCommand(40289, 0) -- Unselect all items
        r.SetMediaItemSelected(item, true)
    else
        r.ShowMessageBox("Failed to create media source from video", "Error", 0)
    end
end

-- Add a toolbar/action for this script
ImportOBSLiveVideo()
