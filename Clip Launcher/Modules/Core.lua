local Core = {}

-- Constants
Core.MAX_COLUMNS = 16       -- max simultaneous columns (JSFX slots)
Core.MAX_CLIPS_PER_COLUMN = 8
Core.ENGINE_TRACK_NAME = "[CLIP ENGINE]"
Core.EXTSTATE_SECTION = "CP_ClipLauncher"

-- Quantize modes
Core.QUANTIZE_IMMEDIATE = 0
Core.QUANTIZE_BEAT = 1
Core.QUANTIZE_BAR = 2

-- Play modes
Core.PLAY_ONESHOT = 0
Core.PLAY_LOOP = 1

-- Launch modes
Core.LAUNCH_TRIGGER = 0  -- click = play/restart
Core.LAUNCH_GATE    = 1  -- press = play, release = stop
Core.LAUNCH_TOGGLE  = 2  -- click = play, click again = stop

-- Column state template
function Core.createColumn(track)
    return {
        track = track,
        track_guid = nil,
        jsfx_slot = -1,    -- stable 0-indexed slot in JSFX (decoupled from array position)
        clips = {},
        is_active = false,
        send_index = -1,
        -- Playback state (read from JSFX)
        playing_clip = -1,
        pending_clip = -1,
        play_mode = Core.PLAY_LOOP,
        launch_mode = Core.LAUNCH_TRIGGER,
        volume = 1.0,
        -- Recording state
        is_recording = false,
        recording_clip = -1,      -- clip slot being recorded into (1-indexed)
        recording_samples = 0,    -- samples recorded so far
        receive_index = -1,       -- REAPER receive index (track → engine)
        -- Sequencer state
        sequencer_enabled = false,
        sequencer_interval_min = 1,
        sequencer_interval_max = 4,
        sequencer_next_trigger = 0,
        probabilities = {},
    }
end

-- Follow action types
Core.FOLLOW_NONE    = "none"
Core.FOLLOW_NEXT    = "next"
Core.FOLLOW_PREV    = "prev"
Core.FOLLOW_FIRST   = "first"
Core.FOLLOW_LAST    = "last"
Core.FOLLOW_RANDOM  = "random"
Core.FOLLOW_STOP    = "stop"

-- Clip data template
function Core.createClip()
    return {
        file_path = nil,
        name = "",
        length_samples = 0,
        length_seconds = 0,
        sample_rate = 0,
        channels = 0,
        loaded = false,
        transferring = false,
        source = nil,       -- "file" or "recorded"
        -- Follow action
        follow_action = Core.FOLLOW_NONE,
        follow_count = 1,   -- loops before triggering follow action
    }
end

function Core.init(r, script_path, script_name, style_loader)
    Core.r = r
    Core.script_path = script_path
    Core.script_name = script_name
    Core.style_loader = style_loader

    -- Clip storage directory (inside project or fallback)
    local project_path = r.GetProjectPath()
    if project_path and project_path ~= "" then
        Core.clip_directory = project_path .. "/ClipLauncher/"
    else
        Core.clip_directory = script_path .. "Clips/"
    end

    Core.state = {
        columns = {},           -- contiguous array in track order, each has stable jsfx_slot
        jsfx_slots = {},        -- [slot_index] = true/nil (allocation tracking)
        engine_track = nil,
        quantize_mode = Core.QUANTIZE_BAR,
        is_running = true,
        frame_counter = 0,
        last_time = r.time_precise(),
        dirty = false,
    }

    Core.config = {
        window_width = 600,
        window_height = 400,
        clip_button_height = 40,
        column_width = 120,
        colors = {
            empty_slot = 0x2A2A2AFF,
            loaded_slot = 0x3A3A3AFF,
            playing_slot = 0x1ABC9880,
            pending_slot = 0xF39C1280,
            sequencer_on = 0x9B59B6FF,
        },
        -- Mixer overlay calibration (MCP)
        overlay = {
            offset_x = 0,       -- Horizontal offset (pixels)
            offset_y = 0,       -- Vertical offset from top of strip (pixels)
            height_ratio = 0.6, -- Height as ratio of strip height (0.1 - 1.0)
            enabled = true,     -- Overlay on/off
        },
        -- TCP overlay calibration
        tcp_overlay = {
            offset_x = 0,       -- Horizontal shift (neg=left, pos=right)
            offset_y = 0,       -- Vertical offset
            width_ratio = 0.3,  -- Clip area width as ratio of trackview width
            enabled = false,    -- TCP overlay on/off
            window_hwnd = 0,    -- Manual window handle (0 = auto-detect)
        },
    }
end

-- Utility: find track by name
function Core.findTrackByName(name)
    local r = Core.r
    for i = 0, r.CountTracks(0) - 1 do
        local track = r.GetTrack(0, i)
        local _, track_name = r.GetTrackName(track)
        if track_name == name then
            return track, i
        end
    end
    return nil, -1
end

-- Utility: find track by GUID
function Core.findTrackByGUID(guid)
    local r = Core.r
    if not guid then return nil end
    for i = 0, r.CountTracks(0) - 1 do
        local track = r.GetTrack(0, i)
        if r.GetTrackGUID(track) == guid then
            return track
        end
    end
    return nil
end

-- Utility: get track name safely
function Core.getTrackName(track)
    if not track or not Core.r.ValidatePtr(track, "MediaTrack*") then
        return "(invalid)"
    end
    local _, name = Core.r.GetTrackName(track)
    return name or "(unnamed)"
end

-- Utility: get track color as ImGui RGBA
function Core.getTrackColor(track)
    local color = Core.r.GetTrackColor(track)
    if color == 0 then return nil end
    local r_val = (color & 0xFF)
    local g_val = ((color >> 8) & 0xFF)
    local b_val = ((color >> 16) & 0xFF)
    return (r_val << 24) | (g_val << 16) | (b_val << 8) | 0xFF
end

return Core
