local r = reaper

local script_name = "CP_AudioGranulator_GUI"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then
    local loader_func = dofile(style_loader_path)
    if loader_func then
        style_loader = loader_func()
    end
end

local ctx = r.ImGui_CreateContext('Audio Granulator')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then
    style_loader.ApplyFontsToContext(ctx)
end

local config = {
    window_width = 500,
    window_height = 600,

    grain_size_ms = 100,
    grain_size_random = 50,
    grain_count = 20,

    pitch_min = -12,
    pitch_max = 12,
    pitch_random = 100,

    reverse_probability = 25,

    position_jitter_ms = 100,
    position_mode = 0,

    stretch_min = 0.5,
    stretch_max = 2.0,
    stretch_random = 50,

    volume_min = -6,
    volume_max = 0,
    volume_random = 50,

    fade_duration = 10,

    overlap_percent = 50,

    mode = 0,

    output_mode = 1,
}

local state = {
    window_position_set = false,
    source_item = nil,
    source_item_name = "No item selected",
    generated_items = {},
    generation_track = nil,
    original_item_hidden = false,
    track_counter = 1,
    same_track_reference = nil,
    time_selection_start = 0,
    time_selection_end = 0,
    has_time_selection = false,
    generation_duration = 0,
}

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

function ApplyStyle()
    if style_loader then
        local success, colors, vars = style_loader.ApplyToContext(ctx)
        if success then
            pushed_colors = colors
            pushed_vars = vars
            return true
        end
    end
    return false
end

function ClearStyle()
    if style_loader then
        style_loader.ClearStyles(ctx, pushed_colors, pushed_vars)
    end
end

function SaveSettings()
    for key, value in pairs(config) do
        local value_str = tostring(value)
        if type(value) == "boolean" then
            value_str = value and "1" or "0"
        end
        r.SetExtState(script_name, "config_" .. key, value_str, true)
    end
end

function LoadSettings()
    for key, default_value in pairs(config) do
        local saved_value = r.GetExtState(script_name, "config_" .. key)
        if saved_value ~= "" then
            if type(default_value) == "number" then
                config[key] = tonumber(saved_value) or default_value
            elseif type(default_value) == "boolean" then
                config[key] = saved_value == "1"
            else
                config[key] = saved_value
            end
        end
    end
end

function UpdateSourceItem()
    local item = r.GetSelectedMediaItem(0, 0)
    if item then
        state.source_item = item
        local take = r.GetActiveTake(item)
        if take then
            local _, name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
            if name == "" then
                local source = r.GetMediaItemTake_Source(take)
                if source then
                    local _, filename = r.GetMediaSourceFileName(source, "")
                    name = filename:match("([^/\\]+)$") or "Unnamed"
                end
            end
            state.source_item_name = name
        else
            state.source_item_name = "Item (no take)"
        end
    else
        state.source_item = nil
        state.source_item_name = "No item selected"
    end
end

function UpdateTimeSelection()
    local ts_start, ts_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if ts_start ~= ts_end then
        state.has_time_selection = true
        state.time_selection_start = ts_start
        state.time_selection_end = ts_end
        state.generation_duration = ts_end - ts_start
    else
        state.has_time_selection = false
        state.time_selection_start = 0
        state.time_selection_end = 0
        state.generation_duration = 0
    end
end

function FormatTime(seconds)
    local minutes = math.floor(seconds / 60)
    local secs = seconds - (minutes * 60)
    return string.format("%d:%05.2f", minutes, secs)
end

function GetOrCreateTargetTrack()
    if config.output_mode == 0 then
        if not state.source_item then return nil end
        return r.GetMediaItem_Track(state.source_item)
    elseif config.output_mode == 1 then
        if state.same_track_reference and r.ValidatePtr(state.same_track_reference, "MediaTrack*") then
            return state.same_track_reference
        end
        local track_count = r.CountTracks(0)
        local new_track_index = track_count
        r.InsertTrackAtIndex(new_track_index, true)
        local new_track = r.GetTrack(0, new_track_index)
        r.GetSetMediaTrackInfo_String(new_track, "P_NAME", "Granulated", true)
        state.same_track_reference = new_track
        return new_track
    else
        local track_count = r.CountTracks(0)
        local new_track_index = track_count
        r.InsertTrackAtIndex(new_track_index, true)
        local new_track = r.GetTrack(0, new_track_index)
        r.GetSetMediaTrackInfo_String(new_track, "P_NAME", "Granulated " .. state.track_counter, true)
        state.track_counter = state.track_counter + 1
        return new_track
    end
end

function DBToLinear(db)
    return 10^(db/20)
end

function GenerateGrains()
    if not state.source_item then
        r.ShowMessageBox("Please select a source item first", "Audio Granulator", 0)
        return
    end

    r.Undo_BeginBlock()

    local source_take = r.GetActiveTake(state.source_item)
    if not source_take then
        r.ShowMessageBox("Source item has no active take", "Audio Granulator", 0)
        r.Undo_EndBlock("Audio Granulator: Failed", -1)
        return
    end

    local source_pos = r.GetMediaItemInfo_Value(state.source_item, "D_POSITION")
    local source_length = r.GetMediaItemInfo_Value(state.source_item, "D_LENGTH")
    local source_offset = r.GetMediaItemTakeInfo_Value(source_take, "D_STARTOFFS")
    local source_rate = r.GetMediaItemTakeInfo_Value(source_take, "D_PLAYRATE")
    local source_pitch = r.GetMediaItemTakeInfo_Value(source_take, "D_PITCH")
    local source_vol = r.GetMediaItemInfo_Value(state.source_item, "D_VOL")
    local source_media = r.GetMediaItemTake_Source(source_take)

    local target_track = GetOrCreateTargetTrack()
    state.generation_track = target_track

    ClearGeneratedGrains()

    if config.output_mode == 0 then
        if not state.original_item_hidden then
            r.SetMediaItemInfo_Value(state.source_item, "B_MUTE", 1)
            state.original_item_hidden = true
        end
        -- r.Main_OnCommand(40507, 0)
    end

    UpdateTimeSelection()

    local grain_size_sec = config.grain_size_ms / 1000.0
    local position_jitter_sec = config.position_jitter_ms / 1000.0
    local fade_sec = config.fade_duration / 1000.0

    local output_pos_start, output_pos_end, generation_span

    if state.has_time_selection then
        output_pos_start = state.time_selection_start
        output_pos_end = state.time_selection_end
        generation_span = output_pos_end - output_pos_start
    else
        if config.mode == 0 then
            output_pos_start = source_pos
        else
            output_pos_start = r.GetCursorPosition()
        end
        local estimated_span = grain_size_sec * config.grain_count * (1 - config.overlap_percent / 100.0)
        output_pos_end = output_pos_start + estimated_span
        generation_span = estimated_span
    end

    for i = 1, config.grain_count do
        local grain_size = grain_size_sec
        if config.grain_size_random > 0 then
            local random_factor = (math.random() * 2 - 1) * (config.grain_size_random / 100.0)
            grain_size = grain_size * (1 + random_factor)
            grain_size = math.max(0.01, grain_size)
        end

        local source_start_offset
        if config.mode == 0 then
            local grid_step = source_length / config.grain_count
            source_start_offset = source_offset + (i - 1) * grid_step * source_rate
        else
            source_start_offset = source_offset + math.random() * (source_length * source_rate)
        end

        local item_pos
        if config.mode == 0 then
            local spacing = generation_span / config.grain_count
            item_pos = output_pos_start + (i - 1) * spacing
        else
            if state.has_time_selection then
                item_pos = output_pos_start + math.random() * generation_span
            else
                if config.position_mode == 0 then
                    item_pos = output_pos_start + math.random() * position_jitter_sec * config.grain_count
                else
                    item_pos = output_pos_start + (math.random() * 2 - 1) * position_jitter_sec
                end
            end
        end

        local new_item = r.AddMediaItemToTrack(target_track)
        r.SetMediaItemInfo_Value(new_item, "D_POSITION", item_pos)
        r.SetMediaItemInfo_Value(new_item, "D_LENGTH", grain_size)

        local new_take = r.AddTakeToMediaItem(new_item)
        r.SetMediaItemTake_Source(new_take, source_media)
        r.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", source_start_offset)

        local pitch_offset = 0
        if config.pitch_random > 0 then
            local pitch_range = (config.pitch_max - config.pitch_min) * (config.pitch_random / 100.0)
            pitch_offset = config.pitch_min * (config.pitch_random / 100.0) + math.random() * pitch_range
        end
        r.SetMediaItemTakeInfo_Value(new_take, "D_PITCH", source_pitch + pitch_offset)

        local should_reverse = (math.random() * 100) < config.reverse_probability
        if should_reverse then
            r.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", -source_rate)
        else
            r.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", source_rate)
        end

        local stretch_factor = 1.0
        if config.stretch_random > 0 then
            local stretch_range = config.stretch_max - config.stretch_min
            stretch_factor = config.stretch_min + math.random() * stretch_range * (config.stretch_random / 100.0)
        end
        if stretch_factor ~= 1.0 then
            local current_rate = r.GetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE")
            r.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", current_rate * stretch_factor)
        end

        local vol_db = config.volume_max
        if config.volume_random > 0 then
            local vol_range = config.volume_max - config.volume_min
            vol_db = config.volume_min + math.random() * vol_range * (config.volume_random / 100.0)
        end
        local vol_linear = DBToLinear(vol_db) * source_vol
        r.SetMediaItemInfo_Value(new_item, "D_VOL", vol_linear)

        r.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", fade_sec)
        r.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", fade_sec)
        r.SetMediaItemInfo_Value(new_item, "C_FADEINSHAPE", 0)
        r.SetMediaItemInfo_Value(new_item, "C_FADEOUTSHAPE", 0)

        r.UpdateItemInProject(new_item)
        table.insert(state.generated_items, new_item)
    end

    r.UpdateArrange()
    r.Undo_EndBlock("Audio Granulator: Generate Grains", -1)
end

function ClearGeneratedGrains()
    if config.output_mode == 2 then
        state.generated_items = {}
        return
    end

    if #state.generated_items > 0 then
        for _, item in ipairs(state.generated_items) do
            if r.ValidatePtr(item, "MediaItem*") then
                local track = r.GetMediaItem_Track(item)
                r.DeleteTrackMediaItem(track, item)
            end
        end
        state.generated_items = {}
        r.UpdateArrange()
    end
end

function RestoreOriginalItem()
    if state.source_item and r.ValidatePtr(state.source_item, "MediaItem*") then
        r.Undo_BeginBlock()

        ClearGeneratedGrains()

        r.SetMediaItemInfo_Value(state.source_item, "B_MUTE", 0)
        state.original_item_hidden = false

        r.UpdateArrange()
        r.Undo_EndBlock("Audio Granulator: Restore Original", -1)
    end
end

function ClearAllGrains()
    if #state.generated_items > 0 then
        r.Undo_BeginBlock()
        for _, item in ipairs(state.generated_items) do
            if r.ValidatePtr(item, "MediaItem*") then
                local track = r.GetMediaItem_Track(item)
                r.DeleteTrackMediaItem(track, item)
            end
        end
        state.generated_items = {}
        r.UpdateArrange()
        r.Undo_EndBlock("Audio Granulator: Clear Grains", -1)
    end
end

function RandomizeAll()
    config.grain_size_ms = 50 + math.random() * 200
    config.grain_size_random = math.random() * 100
    config.grain_count = 10 + math.floor(math.random() * 40)

    config.pitch_min = -24 + math.random() * 24
    config.pitch_max = math.random() * 24
    config.pitch_random = math.random() * 100

    config.reverse_probability = math.random() * 100

    config.position_jitter_ms = math.random() * 500

    config.stretch_min = 0.25 + math.random() * 0.75
    config.stretch_max = 1.0 + math.random() * 2.0
    config.stretch_random = math.random() * 100

    config.volume_min = -12 + math.random() * 6
    config.volume_max = -6 + math.random() * 6
    config.volume_random = math.random() * 100

    config.overlap_percent = math.random() * 100

    config.mode = math.random() > 0.5 and 1 or 0
end

function MainLoop()
    ApplyStyle()

    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())

    local visible, open = r.ImGui_Begin(ctx, 'Audio Granulator', true, window_flags)
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Audio Granulator")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Audio Granulator")
        end

        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if style_loader and style_loader.PushFont(ctx, "main") then

            r.ImGui_Separator(ctx)

            r.ImGui_Text(ctx, "Source: " .. state.source_item_name)
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Get Selected Item") then
                UpdateSourceItem()
            end

            UpdateTimeSelection()

            if state.has_time_selection then
                r.ImGui_Text(ctx, "Time Selection: " .. FormatTime(state.generation_duration))
                r.ImGui_SameLine(ctx)
                r.ImGui_TextColored(ctx, 1, "(Active - defines grain boundaries)")
            else
                r.ImGui_TextColored(ctx, 1, "No Time Selection (using auto-calculation)")
            end

            r.ImGui_Separator(ctx)

            r.ImGui_Text(ctx, "Generation Mode")
            local mode_changed, new_mode = r.ImGui_Combo(ctx, "##mode", config.mode, "Grid (Sequential)\0Chaos (Random)\0")
            if mode_changed then
                config.mode = new_mode
            end

            r.ImGui_Text(ctx, "Output Mode")
            local output_mode_changed, new_output_mode = r.ImGui_Combo(ctx, "##outputmode", config.output_mode, "Replace Item (Mute Original)\0Same Track (Replace Each Time)\0New Track (Keep History)\0")
            if output_mode_changed then
                config.output_mode = new_output_mode
                if config.output_mode == 0 and state.original_item_hidden then
                    RestoreOriginalItem()
                end
            end

            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Grain Settings")

            local grain_size_changed, new_grain_size = r.ImGui_SliderDouble(ctx, "Grain Size (ms)", config.grain_size_ms, 10, 1000, "%.1f")
            if grain_size_changed then
                config.grain_size_ms = new_grain_size
            end

            local grain_random_changed, new_grain_random = r.ImGui_SliderDouble(ctx, "Size Randomness (%)", config.grain_size_random, 0, 100, "%.0f")
            if grain_random_changed then
                config.grain_size_random = new_grain_random
            end

            local grain_count_changed, new_grain_count = r.ImGui_SliderInt(ctx, "Grain Count", config.grain_count, 1, 100)
            if grain_count_changed then
                config.grain_count = new_grain_count
            end

            local overlap_changed, new_overlap = r.ImGui_SliderDouble(ctx, "Overlap (%)", config.overlap_percent, 0, 100, "%.0f")
            if overlap_changed then
                config.overlap_percent = new_overlap
            end

            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Pitch")

            local pitch_min_changed, new_pitch_min = r.ImGui_SliderDouble(ctx, "Min Pitch", config.pitch_min, -24, 24, "%.1f st")
            if pitch_min_changed then
                config.pitch_min = new_pitch_min
            end

            local pitch_max_changed, new_pitch_max = r.ImGui_SliderDouble(ctx, "Max Pitch", config.pitch_max, -24, 24, "%.1f st")
            if pitch_max_changed then
                config.pitch_max = new_pitch_max
            end

            local pitch_random_changed, new_pitch_random = r.ImGui_SliderDouble(ctx, "Pitch Randomness (%)", config.pitch_random, 0, 100, "%.0f")
            if pitch_random_changed then
                config.pitch_random = new_pitch_random
            end

            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Time & Position")

            local reverse_changed, new_reverse = r.ImGui_SliderDouble(ctx, "Reverse Probability (%)", config.reverse_probability, 0, 100, "%.0f")
            if reverse_changed then
                config.reverse_probability = new_reverse
            end

            local jitter_changed, new_jitter = r.ImGui_SliderDouble(ctx, "Position Jitter (ms)", config.position_jitter_ms, 0, 1000, "%.0f")
            if jitter_changed then
                config.position_jitter_ms = new_jitter
            end

            local stretch_min_changed, new_stretch_min = r.ImGui_SliderDouble(ctx, "Min Stretch", config.stretch_min, 0.25, 4.0, "%.2fx")
            if stretch_min_changed then
                config.stretch_min = new_stretch_min
            end

            local stretch_max_changed, new_stretch_max = r.ImGui_SliderDouble(ctx, "Max Stretch", config.stretch_max, 0.25, 4.0, "%.2fx")
            if stretch_max_changed then
                config.stretch_max = new_stretch_max
            end

            local stretch_random_changed, new_stretch_random = r.ImGui_SliderDouble(ctx, "Stretch Randomness (%)", config.stretch_random, 0, 100, "%.0f")
            if stretch_random_changed then
                config.stretch_random = new_stretch_random
            end

            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Volume & Fade")

            local vol_min_changed, new_vol_min = r.ImGui_SliderDouble(ctx, "Min Volume (dB)", config.volume_min, -60, 12, "%.1f dB")
            if vol_min_changed then
                config.volume_min = new_vol_min
            end

            local vol_max_changed, new_vol_max = r.ImGui_SliderDouble(ctx, "Max Volume (dB)", config.volume_max, -60, 12, "%.1f dB")
            if vol_max_changed then
                config.volume_max = new_vol_max
            end

            local vol_random_changed, new_vol_random = r.ImGui_SliderDouble(ctx, "Volume Randomness (%)", config.volume_random, 0, 100, "%.0f")
            if vol_random_changed then
                config.volume_random = new_vol_random
            end

            local fade_changed, new_fade = r.ImGui_SliderDouble(ctx, "Fade Duration (ms)", config.fade_duration, 0, 100, "%.1f")
            if fade_changed then
                config.fade_duration = new_fade
            end

            r.ImGui_Separator(ctx)

            if r.ImGui_Button(ctx, "GENERATE GRAINS", -1) then
                GenerateGrains()
            end

            local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)

            if config.output_mode == 0 then
                local button_width = (r.ImGui_GetContentRegionAvail(ctx) - item_spacing_x * 2) / 3

                if r.ImGui_Button(ctx, "Restore Original", button_width) then
                    RestoreOriginalItem()
                end

                r.ImGui_SameLine(ctx, 0, item_spacing_x)

                if r.ImGui_Button(ctx, "Clear All", button_width) then
                    ClearAllGrains()
                end

                r.ImGui_SameLine(ctx, 0, item_spacing_x)

                if r.ImGui_Button(ctx, "Randomize All", button_width) then
                    RandomizeAll()
                end
            else
                local button_width = (r.ImGui_GetContentRegionAvail(ctx) - item_spacing_x) / 2

                if r.ImGui_Button(ctx, "Clear All", button_width) then
                    ClearAllGrains()
                end

                r.ImGui_SameLine(ctx, 0, item_spacing_x)

                if r.ImGui_Button(ctx, "Randomize All", button_width) then
                    RandomizeAll()
                end
            end

            style_loader.PopFont(ctx)
        else

            r.ImGui_Separator(ctx)

            r.ImGui_Text(ctx, "Source: " .. state.source_item_name)
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Get Selected Item") then
                UpdateSourceItem()
            end

            UpdateTimeSelection()

            if state.has_time_selection then
                r.ImGui_Text(ctx, "Time Selection: " .. FormatTime(state.generation_duration))
                r.ImGui_Text(ctx, "(Active - defines grain boundaries)")
            else
                r.ImGui_Text(ctx, "No Time Selection (using auto-calculation)")
            end

            r.ImGui_Separator(ctx)

            r.ImGui_Text(ctx, "Output Mode")
            local output_mode_changed, new_output_mode = r.ImGui_Combo(ctx, "##outputmode", config.output_mode, "Replace Item (Mute Original)\0Same Track (Replace Each Time)\0New Track (Keep History)\0")
            if output_mode_changed then
                config.output_mode = new_output_mode
            end

            r.ImGui_Separator(ctx)

            if r.ImGui_Button(ctx, "GENERATE GRAINS", -1) then
                GenerateGrains()
            end

            if config.output_mode == 0 then
                if r.ImGui_Button(ctx, "Restore Original", -1) then
                    RestoreOriginalItem()
                end
            end

            if r.ImGui_Button(ctx, "Clear All", -1) then
                ClearAllGrains()
            end

            if r.ImGui_Button(ctx, "Randomize All", -1) then
                RandomizeAll()
            end

        end

        r.ImGui_End(ctx)
    end

    ClearStyle()

    r.PreventUIRefresh(-1)

    if open then
        r.defer(MainLoop)
    else
        SaveSettings()
    end
end

function ToggleScript()
    local _, _, section_id, command_id = r.get_action_context()
    local script_state = r.GetToggleCommandState(command_id)

    if script_state == -1 or script_state == 0 then
        r.SetToggleCommandState(section_id, command_id, 1)
        r.RefreshToolbar2(section_id, command_id)
        Start()
    else
        r.SetToggleCommandState(section_id, command_id, 0)
        r.RefreshToolbar2(section_id, command_id)
        Stop()
    end
end

function Start()
    LoadSettings()
    UpdateSourceItem()
    MainLoop()
end

function Stop()
    SaveSettings()
    Cleanup()
end

function Cleanup()
    local _, _, section_id, command_id = r.get_action_context()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end

function Exit()
    SaveSettings()
    Cleanup()
end

r.atexit(Exit)
ToggleScript()
