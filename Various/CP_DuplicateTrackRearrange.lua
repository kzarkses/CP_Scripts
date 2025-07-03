-- @description DuplicateTrackRearrange
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

-- Create context at script start
local ctx = r.ImGui_CreateContext('Track Duplication')

-- Style loader integration
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

-- Settings variables
local settings = {
    track_name = "",  -- Changed from item_name to track_name to be more explicit
    gap_before = 10,
    enable_before = true,
    gap_after = 10,
    enable_after = true,
    item_length = 1,
    zoom_to_item = true,
    keep_fx = false,  -- Setting for FX retention
    create_region = false  -- New setting for region creation
}

-- Try to load style loader module
local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

function LoadLastSettings()
    settings.track_name = r.GetExtState("DuplicateTrackScript", "track_name") or "New Track" -- Updated key name
    settings.gap_before = tonumber(r.GetExtState("DuplicateTrackScript", "gap_before")) or 10
    settings.enable_before = r.GetExtState("DuplicateTrackScript", "enable_before") == "1"
    settings.gap_after = tonumber(r.GetExtState("DuplicateTrackScript", "gap_after")) or 10
    settings.enable_after = r.GetExtState("DuplicateTrackScript", "enable_after") == "1"
    settings.item_length = tonumber(r.GetExtState("DuplicateTrackScript", "item_length")) or 1
    settings.zoom_to_item = r.GetExtState("DuplicateTrackScript", "zoom_to_item") == "1"
    settings.keep_fx = r.GetExtState("DuplicateTrackScript", "keep_fx") == "1"
    settings.create_region = r.GetExtState("DuplicateTrackScript", "create_region") == "1"
end

function SaveSettings()
    r.SetExtState("DuplicateTrackScript", "track_name", settings.track_name, true) -- Updated key name
    r.SetExtState("DuplicateTrackScript", "gap_before", tostring(settings.gap_before), true)
    r.SetExtState("DuplicateTrackScript", "enable_before", settings.enable_before and "1" or "0", true)
    r.SetExtState("DuplicateTrackScript", "gap_after", tostring(settings.gap_after), true)
    r.SetExtState("DuplicateTrackScript", "enable_after", settings.enable_after and "1" or "0", true)
    r.SetExtState("DuplicateTrackScript", "item_length", tostring(settings.item_length), true)
    r.SetExtState("DuplicateTrackScript", "zoom_to_item", settings.zoom_to_item and "1" or "0", true)
    r.SetExtState("DuplicateTrackScript", "keep_fx", settings.keep_fx and "1" or "0", true)
    r.SetExtState("DuplicateTrackScript", "create_region", settings.create_region and "1" or "0", true)
end

function main()
    r.Undo_BeginBlock()
    
    local selectedTrack = r.GetSelectedTrack(0, 0)
    if not selectedTrack then return end
    
    local lastItemPos = 0
    local itemCount = r.GetTrackNumMediaItems(selectedTrack)
    for i = 0, itemCount - 1 do
        local item = r.GetTrackMediaItem(selectedTrack, i)
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        if pos + length > lastItemPos then
            lastItemPos = pos + length
        end
    end
    
    -- Duplicate the track
    r.Main_OnCommand(40062, 0)
    local newTrack = r.GetSelectedTrack(0, 0)
    if newTrack then
        local ok, _ = r.GetSetMediaTrackInfo_String(newTrack, "P_NAME", settings.track_name, true)
        if not ok then
            r.ShowConsoleMsg("Failed to rename track\n")
        end
    end
    
    -- Function to check if a track is child of another track
    local function isChildTrack(parent, possibleChild)
        local child = r.GetParentTrack(possibleChild)
        while child do
            if child == parent then
                return true
            end
            child = r.GetParentTrack(child)
        end
        return false
    end

    -- Clean items and handle FX on the new track and its children
    local trackCount = r.CountTracks(0)
    for i = 0, trackCount - 1 do
        local track = r.GetTrack(0, i)
        if track == newTrack or isChildTrack(newTrack, track) then
            -- Clear track name for child tracks
            if track ~= newTrack then
                r.GetSetMediaTrackInfo_String(track, "P_NAME", "", true)
            end
            
            -- Remove items
            local itemCount = r.GetTrackNumMediaItems(track)
            for j = itemCount - 1, 0, -1 do
                local item = r.GetTrackMediaItem(track, j)
                r.DeleteTrackMediaItem(track, item)
            end
            
            -- Remove FX if not keeping them
            if not settings.keep_fx then
                while r.TrackFX_GetCount(track) > 0 do
                    r.TrackFX_Delete(track, 0)
                end
            end
        end
    end
    
    local midiItemPos = lastItemPos
    
    if settings.enable_before and settings.gap_before > 0 then
        r.GetSet_LoopTimeRange(true, false, lastItemPos, lastItemPos + settings.gap_before, false)
        r.Main_OnCommand(40200, 0)
        r.GetSet_LoopTimeRange(true, false, 0, 0, false)
        midiItemPos = lastItemPos + settings.gap_before
    end
    
    -- Create MIDI item without naming the take
    local emptyItem = r.CreateNewMIDIItemInProj(newTrack, midiItemPos, midiItemPos + settings.item_length)
    
    -- Create region if enabled with proper color
    if settings.create_region then
        -- Add a small delay to ensure track color is properly applied
        r.defer(function()
            -- Get the track color after the delay
            local trackColor = r.GetTrackColor(newTrack)
            
            -- Create the region with the same color as the track
            local region_idx = r.AddProjectMarker2(0, true, midiItemPos, midiItemPos + settings.item_length, settings.track_name, -1, trackColor)
        end)
    end
    
    if settings.enable_after and settings.gap_after > 0 then
        local timeSelStart = midiItemPos + settings.item_length
        r.GetSet_LoopTimeRange(true, false, timeSelStart, timeSelStart + settings.gap_after, false)
        r.Main_OnCommand(40200, 0)
        r.GetSet_LoopTimeRange(true, false, 0, 0, false)
    end
    
    -- Zoom to item and handle track visibility if enabled
    if settings.zoom_to_item then
        -- Set edit cursor and select the MIDI item
        r.SetEditCurPos(midiItemPos, true, false)
        r.SetMediaItemSelected(emptyItem, true)
        
        -- Use SWS horizontal zoom to items
        r.Main_OnCommand(r.NamedCommandLookup("_SWS_HZOOMITEMS"), 0)
        
        -- Hide all tracks except the new track and its children
        local trackCount = r.CountTracks(0)
        for i = 0, trackCount - 1 do
            local track = r.GetTrack(0, i)
            local shouldShow = track == newTrack or isChildTrack(newTrack, track)
            r.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", shouldShow and 1 or 0)
            r.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", shouldShow and 1 or 0)
        end
    end
    
    r.Undo_EndBlock("Duplicate track with gaps", -1)
end

function Loop()
    -- Apply the global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end

    local visible, open = r.ImGui_Begin(ctx, 'Track Duplication Settings', true, WINDOW_FLAGS)
    
    if visible then
        -- Handle Enter key
        if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()) or 
           r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter()) then
            SaveSettings()
            main()
            open = false
        end
        
        -- Track Name
        local name_changed
        name_changed, settings.track_name = r.ImGui_InputText(ctx, 'Track Name', settings.track_name) -- Updated label
        r.ImGui_Spacing(ctx)
        
        -- Gap Before settings
        local before_changed
        before_changed, settings.gap_before = r.ImGui_InputDouble(ctx, 'Gap Before (s)', settings.gap_before, 0.1, 1.0, "%.1f")
        local enable_before_changed
        enable_before_changed, settings.enable_before = r.ImGui_Checkbox(ctx, 'Enable Gap Before', settings.enable_before)
        r.ImGui_Spacing(ctx)
        
        -- Gap After settings
        local after_changed
        after_changed, settings.gap_after = r.ImGui_InputDouble(ctx, 'Gap After (s)', settings.gap_after, 0.1, 1.0, "%.1f")
        local enable_after_changed
        enable_after_changed, settings.enable_after = r.ImGui_Checkbox(ctx, 'Enable Gap After', settings.enable_after)
        r.ImGui_Spacing(ctx)
        
        -- Item Length
        local length_changed
        length_changed, settings.item_length = r.ImGui_InputDouble(ctx, 'MIDI Item Length (s)', settings.item_length, 0.1, 1.0, "%.1f")
        r.ImGui_Spacing(ctx)
        
        -- Zoom setting
        local zoom_changed
        zoom_changed, settings.zoom_to_item = r.ImGui_Checkbox(ctx, 'Zoom to Created Item', settings.zoom_to_item)
        r.ImGui_Spacing(ctx)

        -- FX retention setting
        local fx_changed
        fx_changed, settings.keep_fx = r.ImGui_Checkbox(ctx, 'Keep FX on Tracks', settings.keep_fx)
        r.ImGui_Spacing(ctx)

        -- Region option
        local region_changed
        region_changed, settings.create_region = r.ImGui_Checkbox(ctx, 'Create Region', settings.create_region)
        r.ImGui_Spacing(ctx)
        
        -- Create button
        if r.ImGui_Button(ctx, 'Create Duplicate Track', -1, 30) then
            SaveSettings()
            main()
            open = false
        end
        
        -- Show Enter key hint
        r.ImGui_Spacing(ctx)
        r.ImGui_TextDisabled(ctx, "Press Enter to confirm")
        
        -- Save settings if any value changed
        if name_changed or before_changed or enable_before_changed or 
           after_changed or enable_after_changed or length_changed or
           zoom_changed or fx_changed or region_changed then
            SaveSettings()
        end
        
        r.ImGui_End(ctx)
    end
    
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end

    if open then
        r.defer(Loop)
    end
end

LoadLastSettings()
r.defer(Loop)









