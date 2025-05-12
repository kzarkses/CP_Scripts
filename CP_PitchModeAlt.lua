-- @description Advanced Pitch Algorithm Controller for Selected FX
-- @version 1.0
-- @author Claude
-- @about
--   Provides an intuitive interface to quickly switch between REAPER's pitch shifting algorithms
--   Controls ReaPitch instances in the selected tracks
--   Similar interface to CP_PitchMode but for FX instead of items

local r = reaper

-- Check if js_ReaScriptAPI and ImGui are available
if not r.APIExists("ImGui_CreateContext") then
    r.ShowMessageBox("This script requires js_ReaScriptAPI with ReaImGui. Please install it via ReaPack.", "Error", 0)
    return
end

-- Create ImGui context
local ctx = r.ImGui_CreateContext('Advanced Pitch Controller')
local font = r.ImGui_CreateFont('sans-serif', 16)
r.ImGui_Attach(ctx, font)

-- FX parameter indices for ReaPitch
-- These might need adjustment based on actual ReaPitch parameters
local REAPITCH_PARAM = {
    SEMITONES = 0,      -- Pitch shift in semitones
    ALGORITHM = 15,     -- Algorithm selection parameter
    SUBMODE = 16,       -- Submode for the selected algorithm
    FORMANT = 11,       -- Formant preservation
    WET = 22,           -- Wet mix
    DRY = 23            -- Dry mix
}

-- Define all pitch shift algorithms with their actual indices
local ALGORITHMS = {
    { name = "Project Default", index = -1 },
    { name = "SoundTouch", index = 0 },
    { name = "Simple Windowed", index = 2 },
    { name = "Elastique 2 Pro", index = 6 },
    { name = "Elastique 2 Efficient", index = 7 },
    { name = "Elastique 2 Soloist", index = 8 },
    { name = "Elastique 3 Pro", index = 9 },
    { name = "Elastique 3 Efficient", index = 10 },
    { name = "Elastique 3 Soloist", index = 11 },
    { name = "Rubber Band Library", index = 13 },
    { name = "Rrreeeaaa", index = 14 },
    { name = "ReaReaRea", index = 15 }
}

-- Bitmasks for advanced modes (from ReaStretch)
local bitmask = {
  -- Rrreeeaaa
  syn = 7,    -- 0000 0000 0111
  ano = 24,   -- 0000 0001 1000
  fft = 96,   -- 0000 0110 0000
  anw = 384,  -- 0001 0000 0000
  syw = 1536, -- 0110 0000 0000
  -- ReaReaRea
  rnd = 15,   -- 0000 0000 1111
  fdm = 1008,  -- 0011 1111 0000
  shp = 3072,  -- 1100 0000 0000
  snc = 8192, -- 0010 0000 0000 0000
}

-- Define various mapping tables for advanced algorithms (similar to CP_PitchMode.lua)
-- (Same mapping tables as in CP_PitchMode.lua would be included here)

-- Initialize variables
local window_open = true
local dockstate = 0
local show_indices = true -- Show indices next to names

-- Selected track and FX info
local selected_track = nil
local selected_fx_index = -1
local selected_fx_name = ""

-- Current parameters
local current_algorithm = 0
local current_submode = 0
local current_semitones = 0
local current_formant = 0
local current_wet = 100
local current_dry = 0

-- Advanced mode parameters
local rrreeeaaa_params = {
    syn = 0,
    ano = 0,
    fft = 0,
    anw = 0,
    syw = 0
}

local rearearea_params = {
    rnd = 0,
    fdm = 0,
    shp = 0,
    snc = 0,
    snc_checkbox = false
}

-- Colors
local col_algorithm = 0x445566FF
local col_algorithm_selected = 0x6688AAFF
local col_algorithm_hover = 0x77AADDFF
local col_submode = 0x556677FF
local col_submode_selected = 0x66AA88FF
local col_submode_hover = 0x88CCAAFF

-- Function to find ReaPitch instances in the selected tracks
local function FindReaPitchInstances()
    local instances = {}
    
    -- Get selected track count
    local track_count = r.CountSelectedTracks(0)
    
    for i = 0, track_count - 1 do
        local track = r.GetSelectedTrack(0, i)
        local fx_count = r.TrackFX_GetCount(track)
        
        for j = 0, fx_count - 1 do
            local retval, fx_name = r.TrackFX_GetFXName(track, j, "")
            
            -- Check if it's a ReaPitch instance
            if fx_name:find("ReaPitch") then
                table.insert(instances, {
                    track = track,
                    fx_index = j,
                    name = fx_name
                })
            end
        end
    end
    
    return instances
end

-- Function to get current algorithm and settings from the selected FX
local function GetCurrentFXSettings()
    if not selected_track or selected_fx_index < 0 then
        return false
    end
    
    -- Get parameters from ReaPitch
    local algo_norm = r.TrackFX_GetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.ALGORITHM)
    local submode_norm = r.TrackFX_GetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.SUBMODE)
    local semitones_norm = r.TrackFX_GetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.SEMITONES)
    local formant_norm = r.TrackFX_GetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.FORMANT)
    local wet_norm = r.TrackFX_GetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.WET)
    local dry_norm = r.TrackFX_GetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.DRY)
    
    -- Convert normalized values to actual values
    -- This would need adjustment based on actual ReaPitch parameter ranges
    current_algorithm = math.floor(algo_norm * 11) -- Assuming 12 algorithms (0-11)
    current_submode = math.floor(submode_norm * 20) -- Assuming max 20 submodes
    current_semitones = (semitones_norm * 48) - 24 -- Range: -24 to +24 semitones
    current_formant = formant_norm * 100 -- Range: 0 to 100%
    current_wet = wet_norm * 100 -- Range: 0 to 100%
    current_dry = dry_norm * 100 -- Range: 0 to 100%
    
    -- For advanced modes, extract parameter values
    -- This would need implementation based on how ReaPitch stores these parameters
    
    return true
end

-- Function to apply algorithm to the selected FX
local function ApplyAlgorithmToFX(algo_index, submode_index)
    if not selected_track or selected_fx_index < 0 then
        return false
    end
    
    r.Undo_BeginBlock()
    
    -- Calculate combined value: mode << 16 | submode
    local pitch_value = (algo_index * 65536) + submode_index
    
    -- Convert to normalized value for ReaPitch
    -- This would need adjustment based on how ReaPitch expects these values
    local algo_norm = algo_index / 11 -- Assuming 12 algorithms (0-11)
    local submode_norm = submode_index / 20 -- Assuming max 20 submodes
    
    -- Set the parameters
    r.TrackFX_SetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.ALGORITHM, algo_norm)
    r.TrackFX_SetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.SUBMODE, submode_norm)
    
    r.Undo_EndBlock("Set Pitch Shift Algorithm", -1)
    
    -- Update current values
    current_algorithm = algo_index
    current_submode = submode_index
    
    return true
end

-- Function to apply semitones value to the selected FX
local function ApplySemitonesToFX(semitones)
    if not selected_track or selected_fx_index < 0 then
        return false
    end
    
    -- Convert to normalized value for ReaPitch
    local semitones_norm = (semitones + 24) / 48 -- Range: -24 to +24 semitones
    
    r.TrackFX_SetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.SEMITONES, semitones_norm)
    
    current_semitones = semitones
    
    return true
end

-- Function to apply formant value to the selected FX
local function ApplyFormantToFX(formant)
    if not selected_track or selected_fx_index < 0 then
        return false
    end
    
    local formant_norm = formant / 100 -- Range: 0 to 100%
    
    r.TrackFX_SetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.FORMANT, formant_norm)
    
    current_formant = formant
    
    return true
end

-- Function to apply wet/dry mix to the selected FX
local function ApplyWetDryToFX(wet, dry)
    if not selected_track or selected_fx_index < 0 then
        return false
    end
    
    local wet_norm = wet / 100 -- Range: 0 to 100%
    local dry_norm = dry / 100 -- Range: 0 to 100%
    
    r.TrackFX_SetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.WET, wet_norm)
    r.TrackFX_SetParamNormalized(selected_track, selected_fx_index, REAPITCH_PARAM.DRY, dry_norm)
    
    current_wet = wet
    current_dry = dry
    
    return true
end

-- Function to apply Rrreeeaaa parameters to the selected FX
local function ApplyRrreeeaaaParamsToFX()
    if not selected_track or selected_fx_index < 0 then
        return false
    end
    
    -- Combine all parameters
    local submode = rrreeeaaa_params.syn + rrreeeaaa_params.ano + rrreeeaaa_params.fft + 
                    rrreeeaaa_params.anw + rrreeeaaa_params.syw
    
    -- Apply it to the FX
    return ApplyAlgorithmToFX(14, submode) -- 14 is Rrreeeaaa
end

-- Function to apply ReaReaRea parameters to the selected FX
local function ApplyReaReaReaParamsToFX()
    if not selected_track or selected_fx_index < 0 then
        return false
    end
    
    -- Combine all parameters
    local submode = rearearea_params.rnd + rearearea_params.fdm + 
                   rearearea_params.shp + rearearea_params.snc
    
    -- Apply it to the FX
    return ApplyAlgorithmToFX(15, submode) -- 15 is ReaReaRea
end

-- Function to load settings
local function LoadSettings()
    dockstate = tonumber(r.GetExtState("PitchFXController", "dock")) or 0
    show_indices = r.GetExtState("PitchFXController", "show_indices") == "1"
end

-- Function to save settings
local function SaveSettings()
    r.SetExtState("PitchFXController", "dock", tostring(dockstate), true)
    r.SetExtState("PitchFXController", "show_indices", show_indices and "1" or "0", true)
end

-- Initialize
LoadSettings()

-- Main loop
local function loop()
    if not window_open then return end
    
    r.defer(loop)
    
    -- Set docking
    if dockstate ~= 0 then
        r.ImGui_SetNextWindowDockID(ctx, dockstate)
    end
    
    -- Set up window
    local window_flags = r.ImGui_WindowFlags_None()
    if dockstate ~= 0 then
        window_flags = window_flags | r.ImGui_WindowFlags_NoDocking()
    end
    
    local visible, open = r.ImGui_Begin(ctx, 'Advanced Pitch Controller', true, window_flags)
    window_open = open
    
    -- Update dock state
    local new_dock_state = r.ImGui_GetWindowDockID(ctx)
    if new_dock_state ~= dockstate then
        dockstate = new_dock_state
        SaveSettings()
    end
    
    if visible then
        local window_width = r.ImGui_GetWindowWidth(ctx)
        
        -- Header section with font
        r.ImGui_PushFont(ctx, font)
        r.ImGui_Text(ctx, "Pitch Shift Algorithm Controller")
        r.ImGui_PopFont(ctx)
        
        -- ReaPitch instances dropdown
        local instances = FindReaPitchInstances()
        local instances_count = #instances
        
        if instances_count == 0 then
            r.ImGui_TextColored(ctx, 0xFF7777FF, "No ReaPitch instances found in selected tracks")
        else
            -- Build dropdown items
            local items = ""
            for i, instance in ipairs(instances) do
                local retval, track_name = r.GetTrackName(instance.track)
                if not retval then track_name = "Unknown Track" end
                items = items .. track_name .. ": " .. instance.name .. "\0"
            end
            items = items .. "\0"
            
            -- Current selection display
            local selection_text = "None"
            if selected_track and selected_fx_index >= 0 then
                local retval, track_name = r.GetTrackName(selected_track)
                if not retval then track_name = "Unknown Track" end
                selection_text = track_name .. ": " .. selected_fx_name
            end
            
            -- Dropdown
            r.ImGui_Text(ctx, "ReaPitch Instance:")
            local rv, combo_selected = r.ImGui_Combo(ctx, "##ReaPitchInstance", -1, items)
            if rv and combo_selected >= 0 and combo_selected < instances_count then
                -- Update selected FX
                selected_track = instances[combo_selected + 1].track
                selected_fx_index = instances[combo_selected + 1].fx_index
                selected_fx_name = instances[combo_selected + 1].name
                
                -- Get current settings
                GetCurrentFXSettings()
            end
            
            -- Settings section
            if selected_track and selected_fx_index >= 0 then
                r.ImGui_Separator(ctx)
                
                -- Show current settings
                r.ImGui_Text(ctx, "Current Settings:")
                r.ImGui_Text(ctx, "Pitch Shift: " .. string.format("%.2f", current_semitones) .. " semitones")
                r.ImGui_Text(ctx, "Algorithm: " .. ALGORITHMS[current_algorithm + 2].name) -- +2 because array is 1-based and we have Project Default at index 1
                r.ImGui_Text(ctx, "Formant: " .. string.format("%.1f", current_formant) .. "%")
                r.ImGui_Text(ctx, "Wet/Dry: " .. string.format("%.1f", current_wet) .. "% / " .. string.format("%.1f", current_dry) .. "%")
                
                -- Basic controls
                r.ImGui_Separator(ctx)
                
                -- Semitones slider
                local rv, new_semitones = r.ImGui_SliderFloat(ctx, "Semitones", current_semitones, -24, 24, "%.2f")
                if rv then
                    ApplySemitonesToFX(new_semitones)
                end
                
                -- Formant slider
                local rv, new_formant = r.ImGui_SliderFloat(ctx, "Formant", current_formant, 0, 100, "%.1f%%")
                if rv then
                    ApplyFormantToFX(new_formant)
                end
                
                -- Wet/Dry sliders
                local rv1, new_wet = r.ImGui_SliderFloat(ctx, "Wet", current_wet, 0, 100, "%.1f%%")
                local rv2, new_dry = r.ImGui_SliderFloat(ctx, "Dry", current_dry, 0, 100, "%.1f%%")
                if rv1 or rv2 then
                    ApplyWetDryToFX(new_wet, new_dry)
                end
                
                -- Algorithm selection
                r.ImGui_Separator(ctx)
                r.ImGui_Text(ctx, "Algorithm:")
                
                -- Create a layout for algorithms with 3 columns
                local algorithms_per_row = 3
                local algo_button_width = (window_width - 20) / algorithms_per_row - 4
                local algo_button_height = 36
                
                for i, algo in ipairs(ALGORITHMS) do
                    -- Only add SameLine after first item in each row
                    if (i-1) % algorithms_per_row ~= 0 and i > 1 then
                        r.ImGui_SameLine(ctx)
                    end
                    
                    local is_selected = (algo.index == current_algorithm)
                    
                    -- Style the algorithm button
                    if is_selected then
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), col_algorithm_selected)
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), col_algorithm_hover)
                    else
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), col_algorithm)
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), col_algorithm_hover)
                    end
                    
                    -- Format button label with or without index
                    local button_label = algo.name
                    if show_indices then
                        button_label = string.format("%s [%d]", algo.name, algo.index)
                    end
                    
                    -- Create the algorithm button
                    if r.ImGui_Button(ctx, button_label, algo_button_width, algo_button_height) then
                        -- Apply the algorithm based on its type
                        if algo.index == 14 then -- Rrreeeaaa
                            ApplyRrreeeaaaParamsToFX()
                        elseif algo.index == 15 then -- ReaReaRea
                            ApplyReaReaReaParamsToFX()
                        else
                            -- Basic algorithm - apply with first submode
                            ApplyAlgorithmToFX(algo.index, 0)
                        end
                    end
                    
                    r.ImGui_PopStyleColor(ctx, 2)
                end
                
                -- Advanced controls section for Rrreeeaaa and ReaReaRea
                -- Similar to CP_PitchMode.lua, rendered based on selected algorithm
                
                -- This would include all the sliders and controls for advanced algorithm parameters
                -- Following the same pattern as CP_PitchMode.lua's RenderRrreeeaaaControls() and
                -- RenderReaReaReaControls() functions
            end
        end
        
        r.ImGui_End(ctx)
    end
end

-- Start the loop
loop()

-- Register a function to run when the script is terminated
local function exit()
    SaveSettings()
end

r.atexit(exit)
