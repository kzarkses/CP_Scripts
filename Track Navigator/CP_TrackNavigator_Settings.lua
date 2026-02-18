-- @description TrackNavigator - Settings
-- @version 1.0.1
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_TrackNavigator"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('Track Navigator Settings')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

local default_config = {
    font_name = "Verdana",
    font_size = 14,
    background_color = 0x212121FF,
    text_color = 0xE0E0E0FF,
    text_highlight_color = 0xFFFFFFFF,
    highlight_color = 0x52A38DA0,
    default_track_color = 0xB0B0B0FF,
    always_visible_color = 0x52A38DA0,
    always_hidden_color = 0xA3526DA0,
    button_color = 0x444444FF,
    button_hover_color = 0x5A5A5AFF,
    button_active_color = 0x666666FF,
    color_intensity = 1.35,
    base_indent = 12,
    row_spacing = 18,
    window_width = 280,
    window_height = 500,
    always_visible_tracks = {},
    always_hidden_tracks = {},
    always_visible_filters = {},
    always_hidden_filters = {}
}

local config = {}

local state = {
    new_visible_filter = "",
    new_hidden_filter = "",
    script_running = false
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

function CopyTable(original)
    if type(original) ~= 'table' then 
        return original 
    end 
    local copy = {}
    for key, value in next, original, nil do 
        copy[CopyTable(key)] = CopyTable(value) 
    end 
    return copy
end

function SaveSettings()
    for key, value in pairs(config) do
        if type(value) == "table" then
            if key == "always_visible_tracks" or key == "always_hidden_tracks" or 
               key == "always_visible_filters" or key == "always_hidden_filters" then
                local table_string = table.concat(value, ",")
                r.SetExtState(script_name, key, table_string, true)
            end
        else
            local value_str = tostring(value)
            if type(value) == "boolean" then
                value_str = value and "1" or "0"
            elseif type(value) == "number" and (string.find(key, "color") and key ~= "color_intensity") then
                value_str = string.format("%08X", value)
            end
            r.SetExtState(script_name, "settings_" .. key, value_str, true)
        end
    end
    r.SetExtState(script_name, "settings_changed", tostring(r.time_precise()), false)
end

function LoadSettings()
    config = {}
    
    for key, default_value in pairs(default_config) do
        if type(default_value) == "table" then
            local saved_value = r.GetExtState(script_name, key)
            config[key] = {}
            if saved_value ~= "" then
                for item in saved_value:gmatch("[^,]+") do
                    table.insert(config[key], item)
                end
            end
        else
            local saved_value = r.GetExtState(script_name, "settings_" .. key)
            if saved_value ~= "" then
                if type(default_value) == "number" then
                    if string.find(key, "color") and key ~= "color_intensity" then
                        config[key] = tonumber(saved_value, 16) or default_value
                    else
                        config[key] = tonumber(saved_value) or default_value
                    end
                elseif type(default_value) == "boolean" then
                    config[key] = saved_value == "1"
                else
                    config[key] = saved_value
                end
            else
                config[key] = default_value
            end
        end
    end
end

function ResetToDefaults()
    config = CopyTable(default_config)
    for key, _ in pairs(default_config) do
        if type(default_config[key]) == "table" then
            r.DeleteExtState(script_name, key, true)
        else
            r.DeleteExtState(script_name, "settings_" .. key, true)
        end
    end
    SaveSettings()
end

function DrawColorEditor(label, key)
    local color = config[key]
    local changed, new_color = r.ImGui_ColorEdit4(ctx, label, color)
    if changed then 
        config[key] = new_color
        SaveSettings()
    end
end

function GetAllTracks()
    local tracks = {}
    local track_count = r.CountTracks(0)
    
    for i = 0, track_count - 1 do 
        local track = r.GetTrack(0, i)
        local _, track_name = r.GetTrackName(track)
        local depth = r.GetTrackDepth(track)
        local _, guid = r.GetSetMediaTrackInfo_String(track, "GUID", "", false)
        table.insert(tracks, {track = track, name = track_name, depth = depth, guid = guid})
    end 
    return tracks
end

function HasValue(tbl, value)
    for j, item in ipairs(tbl) do 
        if item == value then 
            return true, j 
        end 
    end 
    return false, nil
end

function DrawAppearanceTab()
    r.ImGui_Text(ctx, "Font Settings")
    r.ImGui_Separator(ctx)
    
    if r.ImGui_BeginCombo(ctx, "Font Family", config.font_name) then
        local fonts = {"Verdana", "Arial", "Times New Roman", "Courier New", "Consolas", "Segoe UI"}
        for _, font in ipairs(fonts) do 
            if r.ImGui_Selectable(ctx, font, config.font_name == font) then 
                config.font_name = font
                SaveSettings()
            end 
        end
        r.ImGui_EndCombo(ctx)
    end
    
    local changed, new_value = r.ImGui_SliderInt(ctx, "Font Size", config.font_size, 8, 32)
    if changed then 
        config.font_size = new_value
        SaveSettings()
    end
    
    -- r.ImGui_Spacing(ctx)
    -- r.ImGui_Text(ctx, "Window Settings")
    -- r.ImGui_Separator(ctx)
    
    -- changed, new_value = r.ImGui_SliderInt(ctx, "Default Width", config.window_width, 200, 600)
    -- if changed then 
    --     config.window_width = new_value
    --     SaveSettings()
    -- end
    
    -- changed, new_value = r.ImGui_SliderInt(ctx, "Default Height", config.window_height, 300, 800)
    -- if changed then 
    --     config.window_height = new_value
    --     SaveSettings()
    -- end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Layout Settings")
    r.ImGui_Separator(ctx)
    
    changed, new_value = r.ImGui_SliderInt(ctx, "Base Indent", config.base_indent, 4, 24)
    if changed then 
        config.base_indent = new_value
        SaveSettings()
    end
    
    changed, new_value = r.ImGui_SliderInt(ctx, "Row Spacing", config.row_spacing, 12, 48)
    if changed then 
        config.row_spacing = new_value
        SaveSettings()
    end
    
    local changed_float, new_float = r.ImGui_SliderDouble(ctx, "Color Intensity", config.color_intensity, 0.1, 1.5)
    if changed_float then 
        config.color_intensity = new_float
        SaveSettings()
    end
end

function DrawColorsTab()
    r.ImGui_Text(ctx, "Background & Text")
    r.ImGui_Separator(ctx)
    DrawColorEditor("Background Color", "background_color")
    DrawColorEditor("Text Color", "text_color")
    DrawColorEditor("Highlighted Text", "text_highlight_color")
    DrawColorEditor("Default Track Color", "default_track_color")
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Special Track Colors")
    r.ImGui_Separator(ctx)
    DrawColorEditor("Always Visible Color", "always_visible_color")
    DrawColorEditor("Always Hidden Color", "always_hidden_color")
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Selection & Buttons")
    r.ImGui_Separator(ctx)
    DrawColorEditor("Highlight Color", "highlight_color")
    DrawColorEditor("Button Color", "button_color")
    DrawColorEditor("Button Hover", "button_hover_color")
    DrawColorEditor("Button Active", "button_active_color")
end

function DrawTrackVisibilityTab()
    r.ImGui_Text(ctx, "Track Visibility Settings")
    r.ImGui_Separator(ctx)

    local _, available_height = r.ImGui_GetContentRegionAvail(ctx)
    local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
    local window_padding_y = GetStyleValue("spacing.window_padding_y", 8)
    local text_height = r.ImGui_GetTextLineHeight(ctx)
    
    local used_height = text_height * 2 + item_spacing_y
    local list_height = ((available_height - used_height) / 2) - window_padding_y

    r.ImGui_Text(ctx, "Always Visible Tracks:")
    r.ImGui_BeginChild(ctx, "AlwaysVisibleList", 0, list_height)
    local tracks = GetAllTracks()
    for _, track in ipairs(tracks) do 
        local indent = string.rep("  ", track.depth)
        local is_always_visible, index = HasValue(config.always_visible_tracks, track.guid)
        local label = string.format("%s%s", indent, track.name)
        local changed, checked = r.ImGui_Checkbox(ctx, label .. "##vis", is_always_visible)
        
        if changed then 
            if checked then 
                if not is_always_visible then 
                    table.insert(config.always_visible_tracks, track.guid)
                end
            else 
                if is_always_visible and index then 
                    table.remove(config.always_visible_tracks, index)
                end
            end 
            SaveSettings()
        end 
    end
    r.ImGui_EndChild(ctx)
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Always Hidden Tracks:")
    r.ImGui_BeginChild(ctx, "AlwaysHiddenList", 0, list_height)
    for _, track in ipairs(tracks) do 
        local indent = string.rep("  ", track.depth)
        local is_always_hidden, index = HasValue(config.always_hidden_tracks, track.guid)
        local label = string.format("%s%s", indent, track.name)
        local changed, checked = r.ImGui_Checkbox(ctx, label .. "##hid", is_always_hidden)
        
        if changed then 
            if checked then 
                if not is_always_hidden then 
                    table.insert(config.always_hidden_tracks, track.guid)
                end
            else 
                if is_always_hidden and index then 
                    table.remove(config.always_hidden_tracks, index)
                end
            end 
            SaveSettings()
        end 
    end
    r.ImGui_EndChild(ctx)
end

function DrawNameFiltersTab()
    r.ImGui_Text(ctx, "Automatic Track Filters by Name")
    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Tracks containing these words will be automatically marked.")
    r.ImGui_Spacing(ctx)
    
    r.ImGui_Text(ctx, "Always Visible Filters:")
    local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 8)
    
    r.ImGui_SetNextItemWidth(ctx, 300)
    local changed_visible
    changed_visible, state.new_visible_filter = r.ImGui_InputText(ctx, "##new_visible_filter", state.new_visible_filter)
    
    r.ImGui_SameLine(ctx, 0, item_spacing_x)
    if r.ImGui_Button(ctx, "Add##visible", 60) or (r.ImGui_IsItemFocused(ctx) and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())) then
        if state.new_visible_filter ~= "" and not HasValue(config.always_visible_filters, state.new_visible_filter) then
            table.insert(config.always_visible_filters, state.new_visible_filter)
            state.new_visible_filter = ""
            SaveSettings()
        end
    end
    
    if r.ImGui_BeginChild(ctx, "VisibleFiltersList", 0, 100) then
        for i, filter in ipairs(config.always_visible_filters) do
            r.ImGui_PushID(ctx, "vis_" .. i)
            r.ImGui_Text(ctx, filter)
            r.ImGui_SameLine(ctx)
            
            local header_font_size = GetStyleValue("fonts.header.size", 16)
            local button_size = header_font_size + 2
            
            if r.ImGui_Button(ctx, "R", button_size, button_size) then
                local ok, new_name = r.GetUserInputs("Rename Filter", 1, "Filter name:", filter)
                if ok and new_name ~= "" then
                    config.always_visible_filters[i] = new_name
                    SaveSettings()
                end
            end
            
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "X", button_size, button_size) then
                table.remove(config.always_visible_filters, i)
                SaveSettings()
            end
            
            r.ImGui_PopID(ctx)
        end
        r.ImGui_EndChild(ctx)
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Always Hidden Filters:")
    r.ImGui_SetNextItemWidth(ctx, 300)
    local changed_hidden
    changed_hidden, state.new_hidden_filter = r.ImGui_InputText(ctx, "##new_hidden_filter", state.new_hidden_filter)
    
    r.ImGui_SameLine(ctx, 0, item_spacing_x)
    if r.ImGui_Button(ctx, "Add##hidden", 60) or (r.ImGui_IsItemFocused(ctx) and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())) then
        if state.new_hidden_filter ~= "" and not HasValue(config.always_hidden_filters, state.new_hidden_filter) then
            table.insert(config.always_hidden_filters, state.new_hidden_filter)
            state.new_hidden_filter = ""
            SaveSettings()
        end
    end
    
    if r.ImGui_BeginChild(ctx, "HiddenFiltersList", 0, 100) then
        for i, filter in ipairs(config.always_hidden_filters) do
            r.ImGui_PushID(ctx, "hid_" .. i)
            r.ImGui_Text(ctx, filter)
            r.ImGui_SameLine(ctx)
            
            local header_font_size = GetStyleValue("fonts.header.size", 16)
            local button_size = header_font_size + 2
            
            if r.ImGui_Button(ctx, "R", button_size, button_size) then
                local ok, new_name = r.GetUserInputs("Rename Filter", 1, "Filter name:", filter)
                if ok and new_name ~= "" then
                    config.always_hidden_filters[i] = new_name
                    SaveSettings()
                end
            end
            
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "X", button_size, button_size) then
                table.remove(config.always_hidden_filters, i)
                SaveSettings()
            end
            
            r.ImGui_PopID(ctx)
        end
        r.ImGui_EndChild(ctx)
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Examples: 'Bass', 'Kick', 'FX', 'Send', 'MIDI'")
    r.ImGui_Text(ctx, "Filters are case-insensitive and match partial names.")
end

function DrawSettingsManagementTab()
    r.ImGui_Spacing(ctx)
    
    if r.ImGui_Button(ctx, "Save Current Settings", 200) then 
        SaveSettings()
        r.ShowMessageBox("Settings saved successfully!", "Track Navigator Settings", 0)
    end
    
    r.ImGui_Spacing(ctx)
    
    if r.ImGui_Button(ctx, "Reset to Defaults", 200) then 
        ResetToDefaults()
        r.ShowMessageBox("Settings reset to defaults!", "Track Navigator Settings", 0)
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Note: Changes are applied immediately.")
    r.ImGui_Text(ctx, "Restart Track Navigator to see font changes.")
    r.ImGui_Text(ctx, "Name filters are applied automatically when tracks are scanned.")
end

function MainLoop()
    ApplyStyle()
    
    local header_font = GetFont("header")
    local main_font = GetFont("main")
    
    local window_width = GetStyleValue("window.width", 500)
    local window_height = GetStyleValue("window.height", 412)
    
    r.ImGui_SetNextWindowSize(ctx, window_width, window_height, r.ImGui_Cond_FirstUseEver())
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Track Navigator Settings', true, window_flags)
    
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Track Navigator Settings")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Track Navigator Settings")
        end
        
        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local close_button_size = header_font_size + 6
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end
        
        if style_loader and style_loader.PushFont(ctx, "main") then
        
        r.ImGui_Separator(ctx)
        
        if r.ImGui_BeginTabBar(ctx, "SettingsTabs") then
            if r.ImGui_BeginTabItem(ctx, "Appearance") then
                DrawAppearanceTab()
                r.ImGui_EndTabItem(ctx)
            end
            
            if r.ImGui_BeginTabItem(ctx, "Colors") then
                DrawColorsTab()
                r.ImGui_EndTabItem(ctx)
            end
            
            if r.ImGui_BeginTabItem(ctx, "Track Visibility") then
                DrawTrackVisibilityTab()
                r.ImGui_EndTabItem(ctx)
            end
            
            if r.ImGui_BeginTabItem(ctx, "Name Filters") then
                DrawNameFiltersTab()
                r.ImGui_EndTabItem(ctx)
            end
            
            if r.ImGui_BeginTabItem(ctx, "Settings Management") then 
                DrawSettingsManagementTab()
                r.ImGui_EndTabItem(ctx)
            end 
            
            r.ImGui_EndTabBar(ctx)
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
        state.script_running = false
        Cleanup()
    end
end

function ToggleScript()
    local _, _, section_id, command_id = r.get_action_context()
    
    if not state.script_running then
        r.SetToggleCommandState(section_id, command_id, 1)
        r.RefreshToolbar2(section_id, command_id)
        state.script_running = true
        Start()
    end
end

function Start()
    LoadSettings()
    MainLoop()
end

function Stop()
    SaveSettings()
    state.script_running = false
    Cleanup()
end

function Cleanup()
    local _, _, section_id, command_id = r.get_action_context()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end

function Exit()
    SaveSettings()
    state.script_running = false
    Cleanup()
end

r.atexit(Exit)
ToggleScript()