local r = reaper

local ctx = r.ImGui_CreateContext('Stop Motion Onion Skin')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

local config = {
    live_preview = true,
    opacity = 0.5,
    num_frames = 3,
    window_position_set = false
}

function SaveSettings()
    r.SetExtState("StopMotionOnionSkin", "live_preview", config.live_preview and "1" or "0", true)
    r.SetExtState("StopMotionOnionSkin", "opacity", tostring(config.opacity), true)
    r.SetExtState("StopMotionOnionSkin", "num_frames", tostring(config.num_frames), true)
end

function LoadSettings()
    config.live_preview = r.GetExtState("StopMotionOnionSkin", "live_preview") == "1"
    config.opacity = tonumber(r.GetExtState("StopMotionOnionSkin", "opacity")) or 0.5
    config.num_frames = tonumber(r.GetExtState("StopMotionOnionSkin", "num_frames")) or 3
end

function ApplyOnionSkinSettings()
    -- Assuming the Video Processor plugin is loaded on a track or video item
    for track_idx = 0, r.CountTracks(0) - 1 do
        local track = r.GetTrack(0, track_idx)
        local fx_count = r.TrackFX_GetCount(track)
        
        for fx_idx = 0, fx_count - 1 do
            local retval, fx_name = r.TrackFX_GetFXName(track, fx_idx)
            if fx_name:find("Video Processor") then
                r.TrackFX_SetParam(track, fx_idx, 0, config.live_preview and 1 or 0)
                r.TrackFX_SetParam(track, fx_idx, 1, config.opacity)
                r.TrackFX_SetParam(track, fx_idx, 2, config.num_frames)
            end
        end
    end
end

function Loop()
    if not config.window_position_set then
        r.ImGui_SetNextWindowSize(ctx, 300, 200)
        config.window_position_set = true
    end

    local visible, open = r.ImGui_Begin(ctx, 'Stop Motion Onion Skin', true, WINDOW_FLAGS)
    
    if visible then
        local live_changed
        live_changed, config.live_preview = r.ImGui_Checkbox(ctx, 'Live Preview', config.live_preview)
        
        local opacity_changed
        opacity_changed, config.opacity = r.ImGui_SliderDouble(ctx, 'Opacity', config.opacity, 0, 1, '%.2f')
        
        local frames_changed
        frames_changed, config.num_frames = r.ImGui_SliderInt(ctx, 'Frames to Show', config.num_frames, 1, 10)
        
        if live_changed or opacity_changed or frames_changed then
            SaveSettings()
            ApplyOnionSkinSettings()
        end
        
        r.ImGui_End(ctx)
    end

    if open then
        r.defer(Loop)
    end
end

function Start()
    LoadSettings()
    ApplyOnionSkinSettings()
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
