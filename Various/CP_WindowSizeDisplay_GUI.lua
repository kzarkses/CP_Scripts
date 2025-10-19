-- @description WindowSizeDisplay
-- @version 1.0.0
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_WindowSizeDisplay"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('Window Size Display')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

local config = {
    stay_on_top = true,
    auto_resize = true,
    show_content_size = true,
    show_position = true,
    precision = 0
}

local state = {
    window_width = 0,
    window_height = 0,
    content_width = 0,
    content_height = 0,
    window_pos_x = 0,
    window_pos_y = 0,
    initialized = false
}

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

function FormatNumber(num)
    if config.precision == 0 then
        return string.format("%.0f", num)
    else
        return string.format("%." .. config.precision .. "f", num)
    end
end

function MainLoop()
    ApplyStyle()
    
    local header_font = GetFont("header")
    local main_font = GetFont("main")
    local mono_font = GetFont("mono")
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    
    if config.stay_on_top then
        window_flags = window_flags | r.ImGui_WindowFlags_NoFocusOnAppearing()
    end
    
    if config.auto_resize then
        window_flags = window_flags | r.ImGui_WindowFlags_AlwaysAutoResize()
    end
    
    if not state.initialized then
        r.ImGui_SetNextWindowPos(ctx, 100, 100, r.ImGui_Cond_FirstUseEver())
        r.ImGui_SetNextWindowSize(ctx, 300, 200, r.ImGui_Cond_FirstUseEver())
        state.initialized = true
    end
    
    local visible, open = r.ImGui_Begin(ctx, 'Window Size Display', true, window_flags)
    if visible then
        if header_font then r.ImGui_PushFont(ctx, header_font) end
        r.ImGui_Text(ctx, "Window Size Display")
        if header_font then r.ImGui_PopFont(ctx) end

        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local close_button_size = header_font_size + 6
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if main_font then r.ImGui_PushFont(ctx, main_font) end
        
        r.ImGui_Separator(ctx)
        
        state.window_width = r.ImGui_GetWindowWidth(ctx)
        state.window_height = r.ImGui_GetWindowHeight(ctx)
        state.content_width = r.ImGui_GetContentRegionAvail(ctx)
        
        local cursor_start_y = r.ImGui_GetCursorPosY(ctx)
        r.ImGui_GetWindowPos(ctx)
        state.window_pos_x, state.window_pos_y = r.ImGui_GetWindowPos(ctx)
        
        r.ImGui_Text(ctx, "Window Dimensions:")
        if mono_font then r.ImGui_PushFont(ctx, mono_font) end
        r.ImGui_Text(ctx, "  Width:  " .. FormatNumber(state.window_width) .. " px")
        r.ImGui_Text(ctx, "  Height: " .. FormatNumber(state.window_height) .. " px")
        if mono_font then r.ImGui_PopFont(ctx) end
        
        if config.show_content_size then
            r.ImGui_Spacing(ctx)
            r.ImGui_Text(ctx, "Content Area:")
            if mono_font then r.ImGui_PushFont(ctx, mono_font) end
            local content_available = r.ImGui_GetContentRegionAvail(ctx)
            local cursor_current_y = r.ImGui_GetCursorPosY(ctx)
            local content_height_used = cursor_current_y - cursor_start_y
            local total_content_height = state.window_height - (2 * GetStyleValue("spacing.window_padding_y", 8)) - GetStyleValue("fonts.header.size", 16) - GetStyleValue("spacing.item_spacing_y", 6)
            
            r.ImGui_Text(ctx, "  Available: " .. FormatNumber(content_available) .. " px")
            r.ImGui_Text(ctx, "  Used:      " .. FormatNumber(content_height_used) .. " px")
            if mono_font then r.ImGui_PopFont(ctx) end
        end
        
        if config.show_position then
            r.ImGui_Spacing(ctx)
            r.ImGui_Text(ctx, "Window Position:")
            if mono_font then r.ImGui_PushFont(ctx, mono_font) end
            r.ImGui_Text(ctx, "  X: " .. FormatNumber(state.window_pos_x) .. " px")
            r.ImGui_Text(ctx, "  Y: " .. FormatNumber(state.window_pos_y) .. " px")
            if mono_font then r.ImGui_PopFont(ctx) end
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        r.ImGui_Text(ctx, "Options:")
        
        local changed, new_value = r.ImGui_Checkbox(ctx, "Stay on top", config.stay_on_top)
        if changed then config.stay_on_top = new_value end
        
        changed, new_value = r.ImGui_Checkbox(ctx, "Auto resize", config.auto_resize)
        if changed then config.auto_resize = new_value end
        
        changed, new_value = r.ImGui_Checkbox(ctx, "Show content size", config.show_content_size)
        if changed then config.show_content_size = new_value end
        
        changed, new_value = r.ImGui_Checkbox(ctx, "Show position", config.show_position)
        if changed then config.show_position = new_value end
        
        r.ImGui_Text(ctx, "Precision:")
        r.ImGui_SameLine(ctx)
        r.ImGui_SetNextItemWidth(ctx, 80)
        changed, new_value = r.ImGui_SliderInt(ctx, "##precision", config.precision, 0, 3, "%d decimals")
        if changed then config.precision = new_value end
        
        if main_font then r.ImGui_PopFont(ctx) end
        
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
