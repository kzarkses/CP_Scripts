function CapturePhoto()
    if config.output_folder == "" then return false end

    local filename = string.format("%s/frame_%04d.png", config.output_folder, config.frame_counter)
    
    -- Capture directement depuis OBS Virtual Camera avec FFmpeg
    local ffmpeg_cmd = string.format('ffmpeg -f dshow -i video="OBS Virtual Camera" -frames:v 1 "%s"', filename)
    os.execute(ffmpeg_cmd)

    -- Ajouter à REAPER
    local track = GetVideoTrack()
    if track then
        local item = r.AddMediaItemToTrack(track)
        local take = r.AddTakeToMediaItem(item)
        local source = r.PCM_Source_CreateFromFile(filename)
        r.SetMediaItemTake_Source(take, source)
        r.UpdateItemInProject(item)
    end

    if config.auto_increment then
        config.frame_counter = config.frame_counter + 1
        SaveSettings()
    end
    
    return true
end
