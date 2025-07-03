--[[
@description CP_TrackNavigator_Settings
@version 1.0
@author Cedric Pamallo
--]]
local reaper = reaper
local script_id = "CP_TrackNavigator"

local sl = nil
local sp = reaper.GetResourcePath() .. "/Scripts/CP_Scripts/Scripts/Various/CP_ImGuiStyleLoader.lua"
if reaper.file_exists(sp) then local lf = dofile(sp) if lf then sl = lf() end end

local ctx = reaper.ImGui_CreateContext('Track Navigator Settings')
local pc, pv = 0, 0

if sl then sl.applyFontsToContext(ctx) end

function getStyleFont(font_name)
    if sl then
        return sl.getFont(ctx, font_name)
    end
    return nil
end

local default_settings = {
    font_name = "Verdana",
    font_size = 14,
    background_color = 0x212121FF,
    text_color = 0xE0E0E0FF,
    text_highlight_color = 0xFFFFFFFF,
    highlight_color = 0x3D85C6FF,
    default_track_color = 0xB0B0B0FF,
    always_visible_color = 0x4CAF50FF,
    always_hidden_color = 0x757575FF,
    button_color = 0x444444FF,
    button_hover_color = 0x5A5A5AFF,
    button_active_color = 0x666666FF,
    color_intensity = 0.8,
    base_indent = 12,
    row_spacing = 18,
    window_width = 280,
    window_height = 500,
    always_visible_tracks = {},
    always_hidden_tracks = {},
    always_visible_filters = {},
    always_hidden_filters = {}
}

local settings = {}
local new_visible_filter = ""
local new_hidden_filter = ""

function copy_table(original)
    if type(original) ~= 'table' then 
        return original 
    end 
    local copy = {}
    for key, value in next, original, nil do 
        copy[copy_table(key)] = copy_table(value) 
    end 
    return copy
end

function load_settings()
    settings = copy_table(default_settings)
    
    local function get_setting(key, converter)
        local value = reaper.GetExtState(script_id, "settings_" .. key)
        if value ~= "" then 
            settings[key] = converter and converter(value) or value 
        end 
    end
    
    get_setting("font_name")
    get_setting("font_size", tonumber)
    get_setting("color_intensity", tonumber)
    get_setting("base_indent", tonumber)
    get_setting("row_spacing", tonumber)
    get_setting("window_width", tonumber)
    get_setting("window_height", tonumber)
    get_setting("background_color", function(v) return tonumber(v, 16) end)
    get_setting("text_color", function(v) return tonumber(v, 16) end)
    get_setting("text_highlight_color", function(v) return tonumber(v, 16) end)
    get_setting("highlight_color", function(v) return tonumber(v, 16) end)
    get_setting("default_track_color", function(v) return tonumber(v, 16) end)
    get_setting("always_visible_color", function(v) return tonumber(v, 16) end)
    get_setting("always_hidden_color", function(v) return tonumber(v, 16) end)
    get_setting("button_color", function(v) return tonumber(v, 16) end)
    get_setting("button_hover_color", function(v) return tonumber(v, 16) end)
    get_setting("button_active_color", function(v) return tonumber(v, 16) end)
    
    local always_visible_tracks = reaper.GetExtState(script_id, "always_visible_tracks")
    if always_visible_tracks ~= "" then 
        settings.always_visible_tracks = {}
        for guid in always_visible_tracks:gmatch("[^,]+") do 
            table.insert(settings.always_visible_tracks, guid) 
        end 
    end
    
    local always_hidden_tracks = reaper.GetExtState(script_id, "always_hidden_tracks")
    if always_hidden_tracks ~= "" then 
        settings.always_hidden_tracks = {}
        for guid in always_hidden_tracks:gmatch("[^,]+") do 
            table.insert(settings.always_hidden_tracks, guid) 
        end 
    end
    
    local always_visible_filters = reaper.GetExtState(script_id, "always_visible_filters")
    if always_visible_filters ~= "" then 
        settings.always_visible_filters = {}
        for filter in always_visible_filters:gmatch("[^,]+") do 
            table.insert(settings.always_visible_filters, filter) 
        end 
    end
    
    local always_hidden_filters = reaper.GetExtState(script_id, "always_hidden_filters")
    if always_hidden_filters ~= "" then 
        settings.always_hidden_filters = {}
        for filter in always_hidden_filters:gmatch("[^,]+") do 
            table.insert(settings.always_hidden_filters, filter) 
        end 
    end
end

function save_settings()
    reaper.SetExtState(script_id, "settings_font_name", settings.font_name, true)
    reaper.SetExtState(script_id, "settings_font_size", tostring(settings.font_size), true)
    reaper.SetExtState(script_id, "settings_color_intensity", tostring(settings.color_intensity), true)
    reaper.SetExtState(script_id, "settings_base_indent", tostring(settings.base_indent), true)
    reaper.SetExtState(script_id, "settings_row_spacing", tostring(settings.row_spacing), true)
    reaper.SetExtState(script_id, "settings_window_width", tostring(settings.window_width), true)
    reaper.SetExtState(script_id, "settings_window_height", tostring(settings.window_height), true)
    
    for _, key in pairs({"background_color", "text_color", "text_highlight_color", "highlight_color", "default_track_color", "always_visible_color", "always_hidden_color", "button_color", "button_hover_color", "button_active_color"}) do
        reaper.SetExtState(script_id, "settings_" .. key, string.format("%08X", settings[key]), true)
    end
    
    reaper.SetExtState(script_id, "always_visible_tracks", table.concat(settings.always_visible_tracks, ","), true)
    reaper.SetExtState(script_id, "always_hidden_tracks", table.concat(settings.always_hidden_tracks, ","), true)
    reaper.SetExtState(script_id, "always_visible_filters", table.concat(settings.always_visible_filters, ","), true)
    reaper.SetExtState(script_id, "always_hidden_filters", table.concat(settings.always_hidden_filters, ","), true)
    reaper.SetExtState(script_id, "settings_changed", tostring(reaper.time_precise()), false)
end

function reset_to_defaults()
    settings = copy_table(default_settings)
    save_settings()
end

function draw_color_editor(label, key)
    local color = settings[key]
    local changed, new_color = reaper.ImGui_ColorEdit4(ctx, label, color)
    if changed then 
        settings[key] = new_color
        save_settings()
    end
end

function get_all_tracks()
    local tracks = {}
    local track_count = reaper.CountTracks(0)
    
    for i = 0, track_count - 1 do 
        local track = reaper.GetTrack(0, i)
        local _, track_name = reaper.GetTrackName(track)
        local depth = reaper.GetTrackDepth(track)
        local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
        table.insert(tracks, {track = track, name = track_name, depth = depth, guid = guid})
    end 
    return tracks
end

function has_value(tbl, value)
    for j, item in ipairs(tbl) do 
        if item == value then 
            return true, j 
        end 
    end 
    return false, nil
end

function draw_interface()
    if sl then
        local success, colors, vars = sl.applyToContext(ctx)
        if success then pc, pv = colors, vars end
    end
    
    reaper.ImGui_SetNextWindowSize(ctx, 500, 412, reaper.ImGui_Cond_Always())
    local window_flags = reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_NoCollapse()
    local visible, open = reaper.ImGui_Begin(ctx, 'Track Navigator Settings', true, window_flags)
    
    if visible then
        local main_font = getStyleFont("main")
        local header_font = getStyleFont("header")
        
        if header_font then reaper.ImGui_PushFont(ctx, header_font) end
        reaper.ImGui_Text(ctx, "Track Navigator Settings")
        if header_font then reaper.ImGui_PopFont(ctx) end
        if main_font then reaper.ImGui_PushFont(ctx, main_font) end
        
        reaper.ImGui_SameLine(ctx)
        local close_x = reaper.ImGui_GetWindowWidth(ctx) - 30
        reaper.ImGui_SetCursorPosX(ctx, close_x)
        if reaper.ImGui_Button(ctx, "X", 22, 22) then
            open = false
        end
        
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        
        if reaper.ImGui_BeginTabBar(ctx, "SettingsTabs") then
            if reaper.ImGui_BeginTabItem(ctx, "Appearance") then
                reaper.ImGui_Text(ctx, "Font Settings")
                reaper.ImGui_Separator(ctx)
                
                if reaper.ImGui_BeginCombo(ctx, "Font Family", settings.font_name) then
                    local fonts = {"Verdana", "Arial", "Times New Roman", "Courier New", "Consolas", "Segoe UI"}
                    for _, font in ipairs(fonts) do 
                        if reaper.ImGui_Selectable(ctx, font, settings.font_name == font) then 
                            settings.font_name = font
                            save_settings()
                        end 
                    end
                    reaper.ImGui_EndCombo(ctx)
                end
                
                local changed, new_value = reaper.ImGui_SliderInt(ctx, "Font Size", settings.font_size, 8, 32)
                if changed then 
                    settings.font_size = new_value
                    save_settings()
                end
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "Window Settings")
                reaper.ImGui_Separator(ctx)
                
                changed, new_value = reaper.ImGui_SliderInt(ctx, "Default Width", settings.window_width, 200, 600)
                if changed then 
                    settings.window_width = new_value
                    save_settings()
                end
                
                changed, new_value = reaper.ImGui_SliderInt(ctx, "Default Height", settings.window_height, 300, 800)
                if changed then 
                    settings.window_height = new_value
                    save_settings()
                end
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "Layout Settings")
                reaper.ImGui_Separator(ctx)
                
                changed, new_value = reaper.ImGui_SliderInt(ctx, "Base Indent", settings.base_indent, 4, 24)
                if changed then 
                    settings.base_indent = new_value
                    save_settings()
                end
                
                changed, new_value = reaper.ImGui_SliderInt(ctx, "Row Spacing", settings.row_spacing, 12, 48)
                if changed then 
                    settings.row_spacing = new_value
                    save_settings()
                end
                
                local changed_float, new_float = reaper.ImGui_SliderDouble(ctx, "Color Intensity", settings.color_intensity, 0.1, 2.0)
                if changed_float then 
                    settings.color_intensity = new_float
                    save_settings()
                end
                
                reaper.ImGui_EndTabItem(ctx)
            end
            
            if reaper.ImGui_BeginTabItem(ctx, "Colors") then
                reaper.ImGui_Text(ctx, "Background & Text")
                reaper.ImGui_Separator(ctx)
                draw_color_editor("Background Color", "background_color")
                draw_color_editor("Text Color", "text_color")
                draw_color_editor("Highlighted Text", "text_highlight_color")
                draw_color_editor("Default Track Color", "default_track_color")
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "Special Track Colors")
                reaper.ImGui_Separator(ctx)
                draw_color_editor("Always Visible Color", "always_visible_color")
                draw_color_editor("Always Hidden Color", "always_hidden_color")
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "Selection & Buttons")
                reaper.ImGui_Separator(ctx)
                draw_color_editor("Highlight Color", "highlight_color")
                draw_color_editor("Button Color", "button_color")
                draw_color_editor("Button Hover", "button_hover_color")
                draw_color_editor("Button Active", "button_active_color")
                
                reaper.ImGui_EndTabItem(ctx)
            end
            
            if reaper.ImGui_BeginTabItem(ctx, "Track Visibility") then
                reaper.ImGui_Text(ctx, "Track Visibility Settings")
                reaper.ImGui_Separator(ctx)
                
                reaper.ImGui_Text(ctx, "Always Visible Tracks:")
                reaper.ImGui_BeginChild(ctx, "AlwaysVisibleList", 0, 120)
                local tracks = get_all_tracks()
                for _, track in ipairs(tracks) do 
                    local indent = string.rep("  ", track.depth)
                    local is_always_visible, index = has_value(settings.always_visible_tracks, track.guid)
                    local label = string.format("%s%s", indent, track.name)
                    local changed, checked = reaper.ImGui_Checkbox(ctx, label .. "##vis", is_always_visible)
                    
                    if changed then 
                        if checked then 
                            if not is_always_visible then 
                                table.insert(settings.always_visible_tracks, track.guid)
                            end
                        else 
                            if is_always_visible and index then 
                                table.remove(settings.always_visible_tracks, index)
                            end
                        end 
                        save_settings()
                    end 
                end
                reaper.ImGui_EndChild(ctx)
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "Always Hidden Tracks:")
                reaper.ImGui_BeginChild(ctx, "AlwaysHiddenList", 0, 120)
                for _, track in ipairs(tracks) do 
                    local indent = string.rep("  ", track.depth)
                    local is_always_hidden, index = has_value(settings.always_hidden_tracks, track.guid)
                    local label = string.format("%s%s", indent, track.name)
                    local changed, checked = reaper.ImGui_Checkbox(ctx, label .. "##hid", is_always_hidden)
                    
                    if changed then 
                        if checked then 
                            if not is_always_hidden then 
                                table.insert(settings.always_hidden_tracks, track.guid)
                            end
                        else 
                            if is_always_hidden and index then 
                                table.remove(settings.always_hidden_tracks, index)
                            end
                        end 
                        save_settings()
                    end 
                end
                reaper.ImGui_EndChild(ctx)
                
                reaper.ImGui_EndTabItem(ctx)
            end
            
            if reaper.ImGui_BeginTabItem(ctx, "Name Filters") then
                reaper.ImGui_Text(ctx, "Automatic Track Filters by Name")
                reaper.ImGui_Separator(ctx)
                reaper.ImGui_Text(ctx, "Tracks containing these words will be automatically marked.")
                reaper.ImGui_Spacing(ctx)
                
                reaper.ImGui_Text(ctx, "Always Visible Filters:")
                reaper.ImGui_SetNextItemWidth(ctx, 300)
                local changed_visible
                changed_visible, new_visible_filter = reaper.ImGui_InputText(ctx, "##new_visible_filter", new_visible_filter)
                
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "Add##visible", 60, 0) or (reaper.ImGui_IsItemFocused(ctx) and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())) then
                    if new_visible_filter ~= "" and not has_value(settings.always_visible_filters, new_visible_filter) then
                        table.insert(settings.always_visible_filters, new_visible_filter)
                        new_visible_filter = ""
                        save_settings()
                    end
                end
                
                if reaper.ImGui_BeginChild(ctx, "VisibleFiltersList", 0, 100) then
                    for i, filter in ipairs(settings.always_visible_filters) do
                        reaper.ImGui_PushID(ctx, "vis_" .. i)
                        reaper.ImGui_Text(ctx, filter)
                        reaper.ImGui_SameLine(ctx)
                        
                        if reaper.ImGui_Button(ctx, "R", 22, 22) then
                            local ok, new_name = reaper.GetUserInputs("Rename Filter", 1, "Filter name:", filter)
                            if ok and new_name ~= "" then
                                settings.always_visible_filters[i] = new_name
                                save_settings()
                            end
                        end
                        
                        reaper.ImGui_SameLine(ctx)
                        if reaper.ImGui_Button(ctx, "X", 22, 22) then
                            table.remove(settings.always_visible_filters, i)
                            save_settings()
                        end
                        
                        reaper.ImGui_PopID(ctx)
                    end
                    reaper.ImGui_EndChild(ctx)
                end
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "Always Hidden Filters:")
                reaper.ImGui_SetNextItemWidth(ctx, 300)
                local changed_hidden
                changed_hidden, new_hidden_filter = reaper.ImGui_InputText(ctx, "##new_hidden_filter", new_hidden_filter)
                
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "Add##hidden", 60, 0) or (reaper.ImGui_IsItemFocused(ctx) and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())) then
                    if new_hidden_filter ~= "" and not has_value(settings.always_hidden_filters, new_hidden_filter) then
                        table.insert(settings.always_hidden_filters, new_hidden_filter)
                        new_hidden_filter = ""
                        save_settings()
                    end
                end
                
                if reaper.ImGui_BeginChild(ctx, "HiddenFiltersList", 0, 100) then
                    for i, filter in ipairs(settings.always_hidden_filters) do
                        reaper.ImGui_PushID(ctx, "hid_" .. i)
                        reaper.ImGui_Text(ctx, filter)
                        reaper.ImGui_SameLine(ctx)
                        
                        if reaper.ImGui_Button(ctx, "R", 22, 22) then
                            local ok, new_name = reaper.GetUserInputs("Rename Filter", 1, "Filter name:", filter)
                            if ok and new_name ~= "" then
                                settings.always_hidden_filters[i] = new_name
                                save_settings()
                            end
                        end
                        
                        reaper.ImGui_SameLine(ctx)
                        if reaper.ImGui_Button(ctx, "X", 22, 22) then
                            table.remove(settings.always_hidden_filters, i)
                            save_settings()
                        end
                        
                        reaper.ImGui_PopID(ctx)
                    end
                    reaper.ImGui_EndChild(ctx)
                end
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Separator(ctx)
                reaper.ImGui_Text(ctx, "Examples: 'Bass', 'Kick', 'FX', 'Send', 'MIDI'")
                reaper.ImGui_Text(ctx, "Filters are case-insensitive and match partial names.")
                
                reaper.ImGui_EndTabItem(ctx)
            end
            
            if reaper.ImGui_BeginTabItem(ctx, "Settings Management") then 
                reaper.ImGui_Spacing(ctx)
                
                if reaper.ImGui_Button(ctx, "Save Current Settings", 200, 30) then 
                    save_settings()
                    reaper.ShowMessageBox("Settings saved successfully!", "Track Navigator Settings", 0)
                end
                
                reaper.ImGui_Spacing(ctx)
                
                if reaper.ImGui_Button(ctx, "Reset to Defaults", 200, 30) then 
                    reset_to_defaults()
                    reaper.ShowMessageBox("Settings reset to defaults!", "Track Navigator Settings", 0)
                end
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Separator(ctx)
                reaper.ImGui_Text(ctx, "Note: Changes are applied immediately.")
                reaper.ImGui_Text(ctx, "Restart Track Navigator to see font changes.")
                reaper.ImGui_Text(ctx, "Name filters are applied automatically when tracks are scanned.")
                
                reaper.ImGui_EndTabItem(ctx)
            end 
            
            reaper.ImGui_EndTabBar(ctx)
        end 
        
        if main_font then reaper.ImGui_PopFont(ctx) end
        reaper.ImGui_End(ctx)
    end
    
    if sl then sl.clearStyles(ctx, pc, pv) end
    return open
end

load_settings()

local function main_loop()
    local open = draw_interface()
    if open then 
        reaper.defer(main_loop)
    end 
end

main_loop()


