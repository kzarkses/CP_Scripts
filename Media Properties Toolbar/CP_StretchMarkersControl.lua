-- @description StretchMarkersControl
-- @version 1.0.2
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_StretchMarkersControl"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('Stretch Markers Control')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

function GetFont(font_name)
    if style_loader then
        return style_loader.GetFont(ctx, font_name)
    end
    return nil
end

local header_font_size = GetStyleValue("fonts.header.size", 16)
local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
local window_padding_x = GetStyleValue("spacing.window_padding_x", 6)
local window_padding_y = GetStyleValue("spacing.window_padding_y", 6)

local config = {
    slope = 0,
    window_x_offset = -235,
    window_y_offset = 35,
    window_width = 200,
    window_height = 76
}

local state = {
    last_slope = 0,
    window_position_set = false
}

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

function SaveSelectedItems()
    local items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(items, r.GetSelectedMediaItem(0, i))
    end
    return items
end

function ApplyStretchMarkers(slope_in)
    local items = SaveSelectedItems()
    if #items == 0 then return end  
    
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    
    for i, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local item_length = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
            local playrate = r.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
            
            r.DeleteTakeStretchMarkers(take, 0, r.GetTakeNumStretchMarkers(take))
            
            local idx = r.SetTakeStretchMarker(take, -1, 0)
            r.SetTakeStretchMarker(take, -1, item_length * playrate)
            
            local slope = slope_in
            if slope > 4 then
                slope = math.random() * math.min(4, (slope - 4)) / 4
                if math.random() > 0.5 then slope = slope * -1 end
            else
                slope = slope * 0.2499
            end
            r.SetTakeStretchMarkerSlope(take, idx, slope)
        end
    end
    
    r.Undo_EndBlock("Add Stretch Markers", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

function MainLoop()
    ApplyStyle()
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Stretch Markers Control', true, window_flags)
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Stretch Marker")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Stretch Marker")
        end

        r.ImGui_SameLine(ctx)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if style_loader and style_loader.PushFont(ctx, "main") then
        
        r.ImGui_Separator(ctx)
        
        local slope_changed
        slope_changed, config.slope = r.ImGui_SliderDouble(ctx, 'Slope', config.slope, -4, 4, '%.2f')
        
        if slope_changed or config.slope ~= state.last_slope then
            ApplyStretchMarkers(config.slope)
            state.last_slope = config.slope
        end

            style_loader.PopFont(ctx)
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