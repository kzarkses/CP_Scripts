--[[
@description Media Properties Toolbar Settings
@version 1.3
@author Claude
@about
  Customizes the appearance of the Media Properties Toolbar
]]

local r = reaper

-- Style loader integration
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

-- Try to load style loader module
local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

-- Create ImGui context
local ctx = r.ImGui_CreateContext('Media Properties Toolbar Settings')
local font = r.ImGui_CreateFont('sans-serif', 14)
r.ImGui_Attach(ctx, font)

-- Settings file path
local settings_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/MediaPropertiesToolbar_settings.ini"

-- Default settings - Ces noms doivent correspondre exactement aux noms utilisés dans CP_MediaPropertiesToolbar.lua
local default_settings = {
    -- Interface design
    font_name = "FiraSans-Regular",
    font_size = 14,
    entry_height = 20,
    name_width = 220,
    source_width = 220,
    
    -- Primary colors
    text_color = {0.70, 0.70, 0.70, 1.0},
    background_color = {0.155, 0.155, 0.155, 1.0},
    frame_color = {0.155, 0.155, 0.155, 1.0},
    frame_color_active = {0.21, 0.7, 0.63, 0.4},
    
    -- Value colors
    colors = {
        text_normal = {0.75, 0.75, 0.75, 1.0},
        text_modified = {0.0, 0.8, 0.6, 1.0},
        text_negative = {0.8, 0.4, 0.6, 1.0}
    }
}

-- Current settings
local settings = {}

-- Function to load settings from file
local function loadSettings()
    -- Start with default settings
    settings = table.deepcopy(default_settings)
    
    local file = io.open(settings_path, "r")
    if not file then
        return
    end
    
    -- Try to parse file
    local section = nil
    for line in file:lines() do
        -- Skip empty lines and comments
        if line:match("^%s*$") or line:match("^%s*;") then
            -- Do nothing
        elseif line:match("^%[(.+)%]$") then
            -- Section header
            section = line:match("^%[(.+)%]$")
        elseif line:match("^%s*(.-)%s*=%s*(.-)%s*$") then
            -- Key-value pair
            local key, value = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
            
            if section and section == "colors" then
                -- Handle colors subcategory
                if settings.colors[key] and value:match("^{.+}$") then
                    local values = {}
                    for v in value:sub(2, -2):gmatch("[^,]+") do
                        table.insert(values, tonumber(v) or 0)
                    end
                    if #values == 4 then
                        settings.colors[key] = values
                    end
                end
            else
                -- Handle top-level settings
                if key == "font_name" then
                    settings.font_name = value
                elseif key == "font_size" then
                    settings.font_size = tonumber(value) or settings.font_size
                elseif key == "entry_height" then
                    settings.entry_height = tonumber(value) or settings.entry_height
                elseif key == "name_width" then
                    settings.name_width = tonumber(value) or settings.name_width
                elseif key == "source_width" then
                    settings.source_width = tonumber(value) or settings.source_width
                elseif settings[key] and type(settings[key]) == "table" and value:match("^{.+}$") then
                    -- Parse array values like colors
                    local values = {}
                    for v in value:sub(2, -2):gmatch("[^,]+") do
                        table.insert(values, tonumber(v) or 0)
                    end
                    if #values == 4 then
                        settings[key] = values
                    end
                elseif tonumber(value) then
                    settings[key] = tonumber(value)
                end
            end
        end
    end
    
    file:close()
end

-- Function to save settings to file
local function saveSettings()
    local file = io.open(settings_path, "w")
    
    if not file then
        r.ShowMessageBox("Unable to save settings to file: " .. settings_path, "Error", 0)
        return
    end
    
    -- Write file header
    file:write("; Media Properties Toolbar Settings\n")
    file:write("; Generated by CP_MediaPropertiesToolbar_Settings.lua\n\n")
    
    -- Write top-level settings first
    for key, value in pairs(settings) do
        if key ~= "colors" and type(value) ~= "function" then
            local value_str = ""
            if type(value) == "table" then
                -- Format arrays/colors
                value_str = "{"
                for i, v in ipairs(value) do
                    value_str = value_str .. tostring(v)
                    if i < #value then
                        value_str = value_str .. ","
                    end
                end
                value_str = value_str .. "}"
            else
                value_str = tostring(value)
            end
            
            file:write(key .. " = " .. value_str .. "\n")
        end
    end
    
    file:write("\n")
    
    -- Write colors subcategory
    file:write("[colors]\n")
    for key, value in pairs(settings.colors) do
        local value_str = "{"
        for i, v in ipairs(value) do
            value_str = value_str .. tostring(v)
            if i < #value then
                value_str = value_str .. ","
            end
        end
        value_str = value_str .. "}"
        
        file:write(key .. " = " .. value_str .. "\n")
    end
    
    file:close()
    r.SetExtState("MediaPropertiesToolbar", "settings_changed", tostring(r.time_precise()), false)
end

-- Make a deep copy of a table
function table.deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[orig_key] = table.deepcopy(orig_value)
        end
    else
        copy = orig
    end
    return copy
end

-- Convert a color array to ImGui format
local function arrayToImGuiColor(color)
    if not color or #color < 3 then
        return 0x000000FF
    end
    
    local r = math.floor(color[1] * 255)
    local g = math.floor(color[2] * 255)
    local b = math.floor(color[3] * 255)
    
    -- Format pour ImGui_ColorEdit3: 0xXXRRGGBB (XX est ignoré)
    return (r << 16) | (g << 8) | b
end

-- Convert ImGui color to array format
local function imGuiColorToArray(color)
    local r = ((color >> 16) & 0xFF) / 255
    local g = ((color >> 8) & 0xFF) / 255
    local b = (color & 0xFF) / 255
    
    -- Conserver l'alpha à 1.0 par défaut
    return {r, g, b, 1.0}
end

-- Edit a color (returns true if changed)
local function editColor(label, color)
    local changed = false
    
    -- Convert to ImGui format for ColorEdit3
    local color_value = arrayToImGuiColor(color)
    
    -- Call ImGui_ColorEdit3 with the correct arguments
    local rv, new_color = r.ImGui_ColorEdit3(ctx, label, color_value)
    
    if rv then
        -- Convert back to array format
        local new_array = imGuiColorToArray(new_color)
        -- Preserve alpha
        if color[4] then
            new_array[4] = color[4]
        end
        
        -- Update the color array
        for i = 1, #new_array do
            color[i] = new_array[i]
        end
        
        changed = true
    end
    
    return changed
end

-- Main loop
-- Remplacer la fonction loop complète par ceci
function loop()
    -- Apply the global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end
    
    local visible, open = r.ImGui_Begin(ctx, 'Media Properties Toolbar Settings', true)
    
    if visible then
        -- Background and Frame Colors
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFDD88FF) -- Orange text
        r.ImGui_TextWrapped(ctx, "Main Colors")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_Separator(ctx)
        
        local changed = false
        changed = editColor("Background Color", settings.background_color) or changed
        changed = editColor("Frame Color", settings.frame_color) or changed
        changed = editColor("Text Color", settings.text_color) or changed
        
        if changed then
            saveSettings()
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Value Colors (live update)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x88FFFFFF) -- Light blue text
        r.ImGui_TextWrapped(ctx, "Value Colors")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_Separator(ctx)
        
        local color_changed = false
        color_changed = editColor("Normal Values", settings.colors.text_normal) or color_changed
        color_changed = editColor("Modified Values", settings.colors.text_modified) or color_changed
        color_changed = editColor("Negative Values", settings.colors.text_negative) or color_changed
        
        if color_changed then
            saveSettings()
            -- Signal for live update
            r.SetExtState("MediaPropertiesToolbar", "settings_changed", tostring(r.time_precise()), false)
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Font and Layout settings
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFDD88FF) -- Orange text
        r.ImGui_TextWrapped(ctx, "Font and Layout (requires restart)")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_Separator(ctx)
        
        local layout_changed = false
        
        -- Font selector
        r.ImGui_SetNextItemWidth(ctx, 200)
        if r.ImGui_BeginCombo(ctx, "Font Name", settings.font_name) then
            local fonts = {
                "Arial", "Verdana", "Tahoma", "Segoe UI", 
                "FiraSans-Regular", "Consolas", "Courier New",
                "Roboto", "sans-serif", "serif", "monospace"
            }
            
            for _, font_name in ipairs(fonts) do
                local is_selected = (settings.font_name == font_name)
                if r.ImGui_Selectable(ctx, font_name, is_selected) then
                    settings.font_name = font_name
                    layout_changed = true
                end
                
                if is_selected then
                    r.ImGui_SetItemDefaultFocus(ctx)
                end
            end
            
            r.ImGui_EndCombo(ctx)
        end
        
        -- Font size
        r.ImGui_SetNextItemWidth(ctx, 150)
        local rv, new_size = r.ImGui_SliderInt(ctx, "Font Size", settings.font_size, 8, 24)
        if rv then
            settings.font_size = new_size
            layout_changed = true
        end
        
        -- Layout
        r.ImGui_SetNextItemWidth(ctx, 150)
        local rv, new_height = r.ImGui_SliderInt(ctx, "Row Height", settings.entry_height, 16, 40)
        if rv then
            settings.entry_height = new_height
            layout_changed = true
        end
        
        r.ImGui_SetNextItemWidth(ctx, 150)
        local rv, new_width = r.ImGui_SliderInt(ctx, "Name Width", settings.name_width, 120, 400)
        if rv then
            settings.name_width = new_width
            layout_changed = true
        end
        
        r.ImGui_SetNextItemWidth(ctx, 150)
        local rv, new_width = r.ImGui_SliderInt(ctx, "Source Width", settings.source_width, 120, 400)
        if rv then
            settings.source_width = new_width
            layout_changed = true
        end
        
        if layout_changed then
            saveSettings()
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Reset and Apply buttons
        if r.ImGui_Button(ctx, "Reset to Defaults", 200, 30) then
            settings = table.deepcopy(default_settings)
            saveSettings()
            r.SetExtState("MediaPropertiesToolbar", "settings_changed", tostring(r.time_precise()), false)
            r.ShowMessageBox("Settings reset to defaults. Value colors will update immediately, other changes require restarting the toolbar.", "Settings Reset", 0)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Apply All & Restart Toolbar", 200, 30) then
            saveSettings()
            -- Signal restart request
            r.SetExtState("MediaPropertiesToolbar", "layout_changed", "1", false)
            r.ShowMessageBox("Settings applied! The toolbar will attempt to restart itself.", "Settings Applied", 0)
        end
        
        r.ImGui_End(ctx)
    end
    
    -- Clean up the styles we applied
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end
    
    if open then
        r.defer(loop)
    end
end

-- Load settings and start loop
loadSettings()
loop()