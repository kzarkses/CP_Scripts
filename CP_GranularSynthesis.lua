-- @description Granular Synthesis with GUI
-- @version 1.0
-- @author Claude
-- @about
--   Script for granular synthesis processing of audio items

local r = reaper

-- Create context at script start
local ctx = r.ImGui_CreateContext('Granular Synthesis')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

-- Configuration variables
local config = {
    -- Processing parameters with defaults
    grain_mode = "fixed", -- "fixed" or "proportional"
    source_items = {}, -- Pour stocker les items sources
    grain_size = 0.1,    -- seconds for fixed mode
    grain_count = 10,    -- for proportional mode
    reverse_prob = 0.5,  -- probability of reversing a grain
    pitch_min = -12,     -- semitones
    pitch_max = 12,
    pitch_prob = 0.5,    -- probability of pitch shifting
    stretch_min = 0.5,   -- playrate
    stretch_max = 2.0,
    stretch_prob = 0.5,
    spacing_min = 0,     -- seconds
    spacing_max = 0.1,
    fade_length = 0.01,  -- seconds
    process_mode = "separate", -- "separate" or "combined"
    
    -- Window settings
    window_x = 100,
    window_y = 100,
    window_w = 400,
    window_h = 600
}

-- Persistent settings
local function SaveSettings()
    local settings = {
        grain_mode = config.grain_mode,
        grain_size = config.grain_size,
        grain_count = config.grain_count,
        reverse_prob = config.reverse_prob,
        pitch_min = config.pitch_min,
        pitch_max = config.pitch_max,
        pitch_prob = config.pitch_prob,
        stretch_min = config.stretch_min,
        stretch_max = config.stretch_max,
        stretch_prob = config.stretch_prob,
        spacing_min = config.spacing_min,
        spacing_max = config.spacing_max,
        fade_length = config.fade_length,
        process_mode = config.process_mode
    }
    
    for key, value in pairs(settings) do
        r.SetExtState("GranularSynthesis", key, tostring(value), true)
    end
end

local function LoadSettings()
    local settings = {
        grain_mode = r.GetExtState("GranularSynthesis", "grain_mode"),
        grain_size = tonumber(r.GetExtState("GranularSynthesis", "grain_size")),
        grain_count = tonumber(r.GetExtState("GranularSynthesis", "grain_count")),
        reverse_prob = tonumber(r.GetExtState("GranularSynthesis", "reverse_prob")),
        pitch_min = tonumber(r.GetExtState("GranularSynthesis", "pitch_min")),
        pitch_max = tonumber(r.GetExtState("GranularSynthesis", "pitch_max")),
        pitch_prob = tonumber(r.GetExtState("GranularSynthesis", "pitch_prob")),
        stretch_min = tonumber(r.GetExtState("GranularSynthesis", "stretch_min")),
        stretch_max = tonumber(r.GetExtState("GranularSynthesis", "stretch_max")),
        stretch_prob = tonumber(r.GetExtState("GranularSynthesis", "stretch_prob")),
        spacing_min = tonumber(r.GetExtState("GranularSynthesis", "spacing_min")),
        spacing_max = tonumber(r.GetExtState("GranularSynthesis", "spacing_max")),
        fade_length = tonumber(r.GetExtState("GranularSynthesis", "fade_length")),
        process_mode = r.GetExtState("GranularSynthesis", "process_mode")
    }
    
    -- Update config with saved values if they exist
    for key, value in pairs(settings) do
        if value and value ~= "" then
            config[key] = value
        end
    end
end

-- Function to process a single item into grains
local function ProcessItem(item, total_items)
    if not item then return end
    
    local track = r.GetMediaItem_Track(item)
    local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take = r.GetActiveTake(item)
    
    if not take then return end
    
    -- Calculate grain parameters
    local grains = {}
    local current_pos = item_pos
    local grain_lengths = {}
    
    if config.grain_mode == "fixed" then
        while current_pos < item_pos + item_length do
            local remaining = (item_pos + item_length) - current_pos
            table.insert(grain_lengths, math.min(config.grain_size, remaining))
            current_pos = current_pos + config.grain_size
        end
    else
        local grain_size = item_length / config.grain_count
        for i = 1, config.grain_count do
            table.insert(grain_lengths, grain_size)
        end
    end
    
    -- Create grains
    current_pos = item_pos
    for i, length in ipairs(grain_lengths) do
        -- Create new item
        local new_item = r.AddMediaItemToTrack(track)
        r.SetMediaItemInfo_Value(new_item, "D_POSITION", current_pos)
        r.SetMediaItemInfo_Value(new_item, "D_LENGTH", length)
        
        -- Copy take properties
        local new_take = r.AddTakeToMediaItem(new_item)
        r.SetMediaItemTake_Source(new_take, r.GetMediaItemTake_Source(take))
        
        -- Set take properties
        local source_pos = current_pos - item_pos
        r.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", source_pos)
        
        -- Random processing
        -- Reverse
        if math.random() < config.reverse_prob then
            r.Main_OnCommand(41051, 0) -- Toggle item reverse
        end
        
        -- Pitch shift
        if math.random() < config.pitch_prob then
            local pitch = math.random() * (config.pitch_max - config.pitch_min) + config.pitch_min
            r.SetMediaItemTakeInfo_Value(new_take, "D_PITCH", pitch)
        end
        
        -- Stretch
        if math.random() < config.stretch_prob then
            local stretch = math.random() * (config.stretch_max - config.stretch_min) + config.stretch_min
            r.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", stretch)
            -- Adjust item length for stretch
            r.SetMediaItemInfo_Value(new_item, "D_LENGTH", length / stretch)
        end
        
        -- Add spacing
        local spacing = math.random() * (config.spacing_max - config.spacing_min) + config.spacing_min
        current_pos = current_pos + length + spacing
        
        -- Add fades
        r.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", config.fade_length)
        r.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", config.fade_length)
        
        table.insert(grains, new_item)
    end
    
    -- Delete original item
    r.DeleteTrackMediaItem(track, item)
    
    return grains
end

local function StoreSourceItems()
    config.source_items = {}
    local num_items = r.CountSelectedMediaItems(0)
    
    for i = 0, num_items-1 do
        local item = r.GetSelectedMediaItem(0, i)
        local item_data = {
            track = r.GetMediaItem_Track(item),
            position = r.GetMediaItemInfo_Value(item, "D_POSITION"),
            length = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
            take = r.GetActiveTake(item)
        }
        
        if item_data.take then
            item_data.source = r.GetMediaItemTake_Source(item_data.take)
            table.insert(config.source_items, item_data)
        end
    end
end

local function ResetValue(param)
    if param == "pitch_min" or param == "pitch_max" then return 0
    elseif param == "stretch_min" or param == "stretch_max" then return 1.0
    elseif param == "spacing_min" or param == "spacing_max" then return 0
    elseif param:match("_prob") then return 0.5
    elseif param == "fade_length" then return 0.01
    elseif param == "grain_size" then return 0.1
    elseif param == "grain_count" then return 10
    end
    return 0
end

local function ProcessItems()
    -- Si c'est le premier process, on stocke les items sources
    if #config.source_items == 0 then
        StoreSourceItems()
    end
    
    -- Utiliser les items sources au lieu des items sélectionnés
    local num_items = #config.source_items
    if num_items == 0 then return end
    
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    
    if config.process_mode == "separate" then
        -- Process each item separately
        for i = num_items-1, 0, -1 do
            local item = r.GetSelectedMediaItem(0, i)
            ProcessItem(item, 1)
        end
    else
        -- Combined mode: create sequence from all items
        -- Get first track
        local first_item = r.GetSelectedMediaItem(0, 0)
        local target_track = r.GetMediaItem_Track(first_item)
        
        -- Collect all source material
        local items = {}
        local total_length = 0
        for i = 0, num_items-1 do
            local item = r.GetSelectedMediaItem(0, i)
            table.insert(items, {
                item = item,
                length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            })
            total_length = total_length + r.GetMediaItemInfo_Value(item, "D_LENGTH")
        end
        
        -- Calculate grains
        if config.grain_mode == "fixed" then
            config.grain_count = math.ceil(total_length / config.grain_size)
        end
        
        -- Process each source item proportionally
        local current_pos = r.GetMediaItemInfo_Value(first_item, "D_POSITION")
        for _, item_data in ipairs(items) do
            local source_grains = ProcessItem(item_data.item, num_items)
            if source_grains then
                -- Update positions
                for _, grain in ipairs(source_grains) do
                    r.SetMediaItemInfo_Value(grain, "D_POSITION", current_pos)
                    current_pos = current_pos + r.GetMediaItemInfo_Value(grain, "D_LENGTH")
                end
            end
        end
    end
    
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.Undo_EndBlock("Granular Synthesis", -1)
end

-- Main loop for GUI
function Loop()
    local visible, open = r.ImGui_Begin(ctx, 'Granular Synthesis', true, WINDOW_FLAGS)
    
    if visible then
        r.ImGui_Text(ctx, "Grain Settings")
        r.ImGui_Separator(ctx)
        
        local is_fixed = config.grain_mode == "fixed"
        if r.ImGui_RadioButton(ctx, "Fixed Size", is_fixed) then
            config.grain_mode = "fixed"
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_RadioButton(ctx, "Proportional", not is_fixed) then
            config.grain_mode = "proportional"
        end
        
        if config.grain_mode == "fixed" then
            local size_changed
            size_changed, config.grain_size = r.ImGui_SliderDouble(ctx, "Grain Size (s)", config.grain_size, 0.01, 1.0, "%.3f")
        else
            local count_changed
            count_changed, config.grain_count = r.ImGui_SliderInt(ctx, "Grain Count", config.grain_count, 2, 100)
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Processing Settings")
        r.ImGui_Separator(ctx)
        
        local rev_changed
        rev_changed, config.reverse_prob = r.ImGui_SliderDouble(ctx, "Reverse Probability", config.reverse_prob, 0, 1.0, "%.2f")
        
        local pitch_prob_changed
        pitch_prob_changed, config.pitch_prob = r.ImGui_SliderDouble(ctx, "Pitch Probability", config.pitch_prob, 0, 1.0, "%.2f")
        
        local pitch_min_changed, pitch_max_changed
        pitch_min_changed, config.pitch_min = r.ImGui_SliderInt(ctx, "Pitch Min (st)", config.pitch_min, -24, 24)
        pitch_max_changed, config.pitch_max = r.ImGui_SliderInt(ctx, "Pitch Max (st)", config.pitch_max, -24, 24)
        
        local stretch_prob_changed
        stretch_prob_changed, config.stretch_prob = r.ImGui_SliderDouble(ctx, "Stretch Probability", config.stretch_prob, 0, 1.0, "%.2f")
        
        local stretch_min_changed, stretch_max_changed
        stretch_min_changed, config.stretch_min = r.ImGui_SliderDouble(ctx, "Stretch Min", config.stretch_min, 0.25, 4.0, "%.2f")
        stretch_max_changed, config.stretch_max = r.ImGui_SliderDouble(ctx, "Stretch Max", config.stretch_max, 0.25, 4.0, "%.2f")
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Spacing and Fades")
        r.ImGui_Separator(ctx)
        
        local spacing_min_changed, spacing_max_changed
        spacing_min_changed, config.spacing_min = r.ImGui_SliderDouble(ctx, "Spacing Min (s)", config.spacing_min, 0, 1.0, "%.3f")
        spacing_max_changed, config.spacing_max = r.ImGui_SliderDouble(ctx, "Spacing Max (s)", config.spacing_max, 0, 1.0, "%.3f")
        
        local fade_changed
        fade_changed, config.fade_length = r.ImGui_SliderDouble(ctx, "Fade Length (s)", config.fade_length, 0.001, 0.1, "%.3f")
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Multi-Item Mode")
        r.ImGui_Separator(ctx)
        
        local is_separate = config.process_mode == "separate"
        if r.ImGui_RadioButton(ctx, "Separate", is_separate) then
            config.process_mode = "separate"
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_RadioButton(ctx, "Combined", not is_separate) then
            config.process_mode = "combined"
        end
        
        r.ImGui_Spacing(ctx)

        -- Bouton pour réinitialiser la sélection source
        if r.ImGui_Button(ctx, "Reset Source Items") then
            config.source_items = {}
            StoreSourceItems()
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Process", -1, 30) then
            ProcessItems()
            SaveSettings()
        end
        
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(Loop)
    end
end

-- Initialization
LoadSettings()

-- Script toggle functions
function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        LoadSettings()
        Loop()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
        SaveSettings()
    end
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
    SaveSettings()
end

r.atexit(Exit)
ToggleScript()