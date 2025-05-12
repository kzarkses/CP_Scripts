-- @description Project Soundboard Style Manager
-- @version 1.0
-- @author Claude
-- @about
--   Complete style manager for CP_ProjectSoundboard allowing full customization

local r = reaper

-- Create ImGui context for the style manager
local ctx = r.ImGui_CreateContext('Soundboard Style Manager')
local font = r.ImGui_CreateFont('sans-serif', 16)
r.ImGui_Attach(ctx, font)

-- Style loader integration - reuse existing code pattern from your scripts
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

-- Ajoutez cette fonction d'aide en haut de votre script, après les déclarations de variables
function getChildFlags(border)
    if border then
        -- Pas de WindowFlags_Border dans REAPER, utilisons None() à la place
        return r.ImGui_WindowFlags_None()
    else
        return 0 -- Pas de flags/pas de bordure
    end
end
local default_config = {
  -- Colors
  active_color = 0x0088AAFF,        -- Blue color for active items
  inactive_color = 0x323232FF,      -- Darker gray color for inactive items 
  first_column_color = 0x00AA88FF,  -- Teal color for first column (folder files)
  other_track_color = 0xFFFF00FF,   -- Yellow color for other tracks
  border_color = 0x444444FF,        -- Border color
  child_bg = 0x1E1E1EFF,            -- Background color for content areas
  window_bg = 0x181818FF,           -- Main window background color
  text_color = 0xDDDDDDFF,          -- Main text color
  muted_text_color = 0x888888FF,    -- Color for muted/disabled text
  header_separator_color = 0x444444FF, -- Color for header separators
  item_hover_color = 0x444444FF,    -- Color for button hover state
  
  -- Layout dimensions
  columns_per_page = 10,            -- Number of columns per page
  item_height = 26,                 -- Height of item buttons
  column_padding = 4,               -- Padding inside columns
  column_spacing = 14,              -- Spacing between columns
  title_height = 32,                -- Height of track title area
  section_spacing = 10,             -- Spacing after separators
  text_margin = 8,                  -- Margin for text elements
  
  -- Visual style
  button_rounding = 6,              -- Rounding for buttons
  child_rounding = 6,               -- Rounding for child windows
  window_rounding = 0,              -- Rounding for main window
  border_size = 1.0,                -- Size of borders
  header_height = 36,               -- Height of column headers
  scrollbar_size = 14,              -- Size of scrollbars
  
  -- Font settings
  font_name = "sans-serif",         -- Font name
  font_size = 16,                   -- Font size
  title_font_size = 18,             -- Font size for titles
  
  -- Behavior settings
  show_tooltips = true,             -- Whether to show tooltips
  compact_view = false,             -- More compact layout with smaller spacing
  
  -- Animations (new)
  enable_animations = true,         -- Enable smooth animations
  animation_speed = 0.3,            -- Animation speed (in seconds)
  
  -- Appearance variants (new)
  theme_variant = "dark",           -- Current theme variant ("dark", "light", "custom")
}

-- Current configuration (will be loaded from ExtState)
local config = {}

-- Make a deep copy of a table
function table.deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[table.deepcopy(orig_key)] = table.deepcopy(orig_value)
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

-- Custom presets
local presets = {
    ["Classic Dark"] = {
        theme_variant = "dark",
        active_color = 0x0088AAFF,
        inactive_color = 0x323232FF,
        first_column_color = 0x00AA88FF,
        child_bg = 0x1E1E1EFF,
    },
    ["Light Theme"] = {
        theme_variant = "light",
        active_color = 0x0077CCFF,
        inactive_color = 0xE0E0E0FF,
        first_column_color = 0x00AA88FF,
        other_track_color = 0x996600FF,
        border_color = 0xCCCCCCFF,
        child_bg = 0xF5F5F5FF,
        window_bg = 0xEEEEEEFF,
        text_color = 0x222222FF,
        muted_text_color = 0x777777FF,
        header_separator_color = 0xCCCCCCFF,
    },
    ["High Contrast"] = {
        theme_variant = "dark",
        active_color = 0x00FFFFFF,
        inactive_color = 0x202020FF,
        first_column_color = 0x00FFFFFF,
        other_track_color = 0xFFFF00FF,
        border_color = 0x00FFFFFF,
        child_bg = 0x000000FF,
        window_bg = 0x000000FF,
        text_color = 0xFFFFFFFF,
    },
    ["Colorful"] = {
        theme_variant = "dark",
        active_color = 0x00FFFFFF,
        inactive_color = 0x404080FF,
        first_column_color = 0xFF5050FF,
        other_track_color = 0x50FF50FF,
        border_color = 0x8080FFFF,
        child_bg = 0x202040FF,
        window_bg = 0x101030FF,
        button_rounding = 12,
        child_rounding = 12,
    },
    ["Minimalist"] = {
        theme_variant = "light",
        active_color = 0x444444FF,
        inactive_color = 0xEEEEEEFF,
        first_column_color = 0x444444FF,
        other_track_color = 0x444444FF,
        border_color = 0xDDDDDDFF,
        child_bg = 0xFFFFFFFF,
        window_bg = 0xFFFFFFFF,
        text_color = 0x333333FF,
        button_rounding = 0,
        child_rounding = 0,
        window_rounding = 0,
        border_size = 1.0,
    }
}

-- User-defined presets (loaded/saved from ExtState)
local user_presets = {}

-- Current preset name
local current_preset = "Custom"

-- New preset name (for saving)
local new_preset_name = "My Preset"

-- Current tab
local current_tab = 0

-- State for preview panel
local preview = {
    items = {
        { name = "Track Item 1", active = true },
        { name = "Track Item 2", active = false },
        { name = "Track Item with Long Name", active = false },
    },
    folders = {
        { name = "Music File 1.mp3", active = true },
        { name = "Music File 2.mp3", active = false },
    }
}

-- Load configuration from ExtState
function loadConfig()
    -- Start with default configuration
    config = table.deepcopy(default_config)
    
    -- Load values from ExtState
    local ext_state = r.GetExtState("CP_SoundboardStyle", "config")
    if ext_state ~= "" then
        local success, loaded_config = pcall(function() return load("return " .. ext_state)() end)
        if success and type(loaded_config) == "table" then
            -- Merge loaded config with defaults to ensure all properties exist
            for k, v in pairs(loaded_config) do
                config[k] = v
            end
        end
    end
    
    -- Load user presets
    local presets_state = r.GetExtState("CP_SoundboardStyle", "user_presets")
    if presets_state ~= "" then
        local success, loaded_presets = pcall(function() return load("return " .. presets_state)() end)
        if success and type(loaded_presets) == "table" then
            user_presets = loaded_presets
        end
    end
    
    -- Load current preset
    local preset_state = r.GetExtState("CP_SoundboardStyle", "current_preset")
    if preset_state ~= "" then
        current_preset = preset_state
    end
end

-- Save configuration to ExtState
function saveConfig()
    -- Serialize config to string
    local config_str = serializeTable(config)
    r.SetExtState("CP_SoundboardStyle", "config", config_str, true)
    
    -- Save to global soundboard config
    r.SetExtState("CP_ProjectSoundboard", "style_config", config_str, true)
    
    -- Serialize user presets
    local presets_str = serializeTable(user_presets)
    r.SetExtState("CP_SoundboardStyle", "user_presets", presets_str, true)
    
    -- Save current preset
    r.SetExtState("CP_SoundboardStyle", "current_preset", current_preset, true)
end

-- Apply preset to current config
function applyPreset(preset_name)
    if preset_name == "Default" then
        config = table.deepcopy(default_config)
        current_preset = "Default"
        return true
    end
    
    local preset = presets[preset_name] or user_presets[preset_name]
    if preset then
        -- Start with current config to preserve settings not in the preset
        local new_config = table.deepcopy(config)
        
        -- Apply preset settings
        for k, v in pairs(preset) do
            new_config[k] = v
        end
        
        config = new_config
        current_preset = preset_name
        return true
    end
    
    return false
end

-- Save current config as a preset
function saveAsPreset(name)
    if name == "" or name == "Default" then
        return false
    end
    
    -- Create a copy of current config for the preset
    user_presets[name] = table.deepcopy(config)
    current_preset = name
    
    -- Save to ExtState
    saveConfig()
    return true
end

-- Delete a user preset
function deletePreset(name)
    if user_presets[name] then
        user_presets[name] = nil
        
        -- If current preset was deleted, reset to Default
        if current_preset == name then
            current_preset = "Default"
            applyPreset("Default")
        end
        
        -- Save changes to ExtState
        saveConfig()
        return true
    end
    
    return false
end

-- Serialize a table to string
function serializeTable(tbl)
    local result = "{\n"
    
    for k, v in pairs(tbl) do
        if type(k) == "string" then
            result = result .. '  ["' .. k .. '"] = '
        else
            result = result .. "  [" .. k .. "] = "
        end
        
        if type(v) == "table" then
            result = result .. serializeTable(v)
        elseif type(v) == "string" then
            result = result .. string.format("%q", v)
        else
            result = result .. tostring(v)
        end
        
        result = result .. ",\n"
    end
    
    return result .. "}"
end

-- Draw color editor control with label and return true if changed
function drawColorEditor(label, color_var)
    r.ImGui_AlignTextToFramePadding(ctx)
    r.ImGui_Text(ctx, label .. ":")
    r.ImGui_SameLine(ctx, 180)
    r.ImGui_PushItemWidth(ctx, 300)
    
    local changed, new_color
    
    -- Note: Dans REAPER ImGui, ColorEdit3/4 attend une seule valeur entière
    -- au format 0xRRGGBB ou 0xRRGGBBAA, pas des composantes individuelles
    if r.ImGui_ColorEdit4 then
        changed, new_color = r.ImGui_ColorEdit4(ctx, "##" .. label, color_var)
    else
        -- Fallback to ColorEdit3 if ColorEdit4 isn't available
        -- Note: ColorEdit3 ignore l'alpha dans REAPER
        changed, new_color = r.ImGui_ColorEdit3(ctx, "##" .. label, color_var)
    end
    
    r.ImGui_PopItemWidth(ctx)
    
    if changed then
        -- Appliquer immédiatement au Soundboard en sauvegardant
        config[label:gsub(" ", "_"):lower()] = new_color
        r.SetExtState("CP_ProjectSoundboard", "style_config", serializeTable(config), true)
        return true, new_color
    end
    
    return false, color_var
end

-- Draw a slider control with label
function drawSlider(label, value, min, max, format)
    format = format or "%.0f"
    
    r.ImGui_AlignTextToFramePadding(ctx)
    r.ImGui_Text(ctx, label .. ":")
    r.ImGui_SameLine(ctx, 180)
    r.ImGui_PushItemWidth(ctx, 240) -- Réduit pour avoir de la place pour l'affichage de la valeur
    
    local changed, new_value
    -- Try to use the right function based on value type
    if type(value) == "number" then
        if math.floor(value) == value then
            changed, new_value = r.ImGui_SliderInt(ctx, "##" .. label, value, min, max, format)
        else
            changed, new_value = r.ImGui_SliderDouble(ctx, "##" .. label, value, min, max, format)
        end
    end
    
    r.ImGui_PopItemWidth(ctx)
    
    -- Afficher la valeur actuelle
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, string.format(format, value))
    
    if changed then
        -- Appliquer immédiatement au Soundboard en sauvegardant
        r.SetExtState("CP_ProjectSoundboard", "style_config", serializeTable(config), true)
        return true, new_value
    end
    
    return false, value
end

-- Draw a checkbox control
function drawCheckbox(label, value)
    r.ImGui_AlignTextToFramePadding(ctx)
    
    local changed, new_value = r.ImGui_Checkbox(ctx, label, value)
    
    if changed then
        return true, new_value
    end
    
    return false, value
end

-- Draw a combo box
function drawCombo(label, current_item, items)
    r.ImGui_AlignTextToFramePadding(ctx)
    r.ImGui_Text(ctx, label .. ":")
    r.ImGui_SameLine(ctx, 180)
    r.ImGui_PushItemWidth(ctx, 300)
    
    local changed = false
    local new_item = current_item
    
    if r.ImGui_BeginCombo(ctx, "##" .. label, current_item) then
        for _, item in ipairs(items) do
            local is_selected = (item == current_item)
            if r.ImGui_Selectable(ctx, item, is_selected) then
                new_item = item
                changed = true
            end
            
            if is_selected then
                r.ImGui_SetItemDefaultFocus(ctx)
            end
        end
        r.ImGui_EndCombo(ctx)
    end
    
    r.ImGui_PopItemWidth(ctx)
    
    return changed, new_item
end

-- Draw the preview panel to show how settings will look
function drawPreviewPanel()
    -- Push settings colors for the preview
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), config.window_bg)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), config.text_color)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), config.window_rounding)
    
    -- Create a preview container
    if r.ImGui_BeginChild(ctx, "preview_window", -1, 250, getChildFlags(true)) then
        -- Row for column headers
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), config.column_spacing, 0)
        
        -- First column - Music Files (folder)
        local column_width = (r.ImGui_GetContentRegionAvail(ctx) - config.column_spacing) / 2
        
        -- First column background
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), config.child_bg)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), config.border_color)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildRounding(), config.child_rounding)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildBorderSize(), config.border_size)
        
        if r.ImGui_BeginChild(ctx, "preview_folder", column_width, 0, getChildFlags(true)) then
            -- Column header
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 12, 12)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), config.first_column_color)
            
            r.ImGui_Dummy(ctx, 0, 6)
            r.ImGui_Text(ctx, "Music")
            r.ImGui_SameLine(ctx)
            r.ImGui_SetCursorPosX(ctx, column_width - 85)
            
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x3D78B4FF)
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), config.button_rounding)
            r.ImGui_Button(ctx, "Browse...")
            r.ImGui_PopStyleVar(ctx)
            r.ImGui_PopStyleColor(ctx)
            
            r.ImGui_Dummy(ctx, 0, 6)
            r.ImGui_PopStyleColor(ctx)
            r.ImGui_PopStyleVar(ctx)
            
            r.ImGui_Separator(ctx)
            r.ImGui_Dummy(ctx, 0, config.section_spacing)
            
            -- Folder items
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), config.column_padding, config.column_padding)
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), config.button_rounding)
            
            for i, file in ipairs(preview.folders) do
                if file.active then
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), config.active_color)
                else
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), config.inactive_color)
                end
                
                r.ImGui_Button(ctx, file.name, r.ImGui_GetContentRegionAvail(ctx), config.item_height)
                r.ImGui_PopStyleColor(ctx)
            end
            
            r.ImGui_PopStyleVar(ctx, 2)
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_PopStyleVar(ctx, 2)
        r.ImGui_PopStyleColor(ctx, 2)
        
        -- Second column - Track items
        r.ImGui_SameLine(ctx)
        
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), config.child_bg)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), config.border_color)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildRounding(), config.child_rounding)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildBorderSize(), config.border_size)
        
        if r.ImGui_BeginChild(ctx, "preview_track", column_width, 0, getChildFlags(true)) then
            -- Column header
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 12, 12)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), config.other_track_color)
            
            r.ImGui_Dummy(ctx, 0, 6)
            
            -- Center track name
            local text_width = r.ImGui_CalcTextSize(ctx, "Track Name")
            local content_width = column_width
            r.ImGui_SetCursorPosX(ctx, (content_width - text_width) / 2)
            
            r.ImGui_Text(ctx, "Track Name")
            r.ImGui_Dummy(ctx, 0, 6)
            
            r.ImGui_PopStyleColor(ctx)
            r.ImGui_PopStyleVar(ctx)
            
            r.ImGui_Separator(ctx)
            r.ImGui_Dummy(ctx, 0, config.section_spacing)
            
            -- Track items
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), config.column_padding, config.column_padding)
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), config.button_rounding)
            
            for i, item in ipairs(preview.items) do
                if item.active then
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), config.active_color)
                else
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), config.inactive_color)
                end
                
                r.ImGui_Button(ctx, item.name, r.ImGui_GetContentRegionAvail(ctx), config.item_height)
                r.ImGui_PopStyleColor(ctx)
            end
            
            r.ImGui_PopStyleVar(ctx, 2)
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_PopStyleVar(ctx, 2)
        r.ImGui_PopStyleColor(ctx, 2)
        
        r.ImGui_PopStyleVar(ctx) -- ItemSpacing
        
        r.ImGui_EndChild(ctx)
    end
    
    r.ImGui_PopStyleVar(ctx)
    r.ImGui_PopStyleColor(ctx, 2)
end

-- Draw the main interface
function loop()
    -- Apply the global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end
    
    -- Set next window size on first open
    r.ImGui_SetNextWindowSize(ctx, 800, 600, r.ImGui_Cond_FirstUseEver())
    
    -- Start the main window
    local visible, open = r.ImGui_Begin(ctx, 'Soundboard Style Manager', true)
    
    if visible then
        -- Use the font if available
        if font then
            r.ImGui_PushFont(ctx, font)
        end
        
        -- Top section with presets management
        r.ImGui_BeginGroup(ctx)
        
        r.ImGui_Text(ctx, "Preset:")
        r.ImGui_SameLine(ctx, 70)
        r.ImGui_PushItemWidth(ctx, 200)
        
        -- Create a list of all presets
        local all_presets = {"Default", "Custom"}
        for name, _ in pairs(presets) do
            table.insert(all_presets, name)
        end
        for name, _ in pairs(user_presets) do
            table.insert(all_presets, name)
        end
        table.sort(all_presets)
        
        -- Preset selection combo
        if r.ImGui_BeginCombo(ctx, "##preset_selector", current_preset) then
            for _, name in ipairs(all_presets) do
                local is_selected = (name == current_preset)
                if r.ImGui_Selectable(ctx, name, is_selected) then
                    applyPreset(name)
                end
                
                if is_selected then
                    r.ImGui_SetItemDefaultFocus(ctx)
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        r.ImGui_PopItemWidth(ctx)
        
        -- Save As button
        r.ImGui_SameLine(ctx, 300)
        if r.ImGui_Button(ctx, "Save As...") then
            r.ImGui_OpenPopup(ctx, "Save Preset")
        end
        
        -- Delete preset button
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Delete Preset") and current_preset ~= "Default" and current_preset ~= "Custom" then
            r.ImGui_OpenPopup(ctx, "Delete Preset")
        end
        
        -- Reset to default button
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Reset to Default") then
            applyPreset("Default")
        end
        
        -- Apply to soundboard button
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Apply to Soundboard") then
            saveConfig()
            r.ShowMessageBox("Settings applied to Soundboard. Restart the Soundboard script to see changes.", "Settings Applied", 0)
        end
        
        r.ImGui_EndGroup(ctx)
        
        r.ImGui_Separator(ctx)
        
        -- Main tabbed interface
        if r.ImGui_BeginTabBar(ctx, "StyleTabs") then
            -- Colors tab
            if r.ImGui_BeginTabItem(ctx, "Colors") then
                -- Column for color controls
                r.ImGui_BeginChild(ctx, "colors_panel", 500, 0, 0)
                
                r.ImGui_Text(ctx, "Main Colors")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                -- Window background & text
                local changed, new_value
                
                changed, new_value = drawColorEditor("Window Background", config.window_bg)
                if changed then config.window_bg = new_value end
                
                changed, new_value = drawColorEditor("Text Color", config.text_color)
                if changed then config.text_color = new_value end
                
                changed, new_value = drawColorEditor("Muted Text Color", config.muted_text_color)
                if changed then config.muted_text_color = new_value end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Column & Item Colors")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                changed, new_value = drawColorEditor("Child Background", config.child_bg)
                if changed then config.child_bg = new_value end
                
                changed, new_value = drawColorEditor("Border Color", config.border_color)
                if changed then config.border_color = new_value end
                
                changed, new_value = drawColorEditor("Header Separator", config.header_separator_color)
                if changed then config.header_separator_color = new_value end
                
                changed, new_value = drawColorEditor("First Column Color", config.first_column_color)
                if changed then config.first_column_color = new_value end
                
                changed, new_value = drawColorEditor("Track Column Color", config.other_track_color)
                if changed then config.other_track_color = new_value end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Button Colors")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                changed, new_value = drawColorEditor("Active Item", config.active_color)
                if changed then config.active_color = new_value end
                
                changed, new_value = drawColorEditor("Inactive Item", config.inactive_color)
                if changed then config.inactive_color = new_value end
                
                changed, new_value = drawColorEditor("Hover Color", config.item_hover_color)
                if changed then config.item_hover_color = new_value end
                
                r.ImGui_EndChild(ctx)
                
                -- Preview panel on the right
                r.ImGui_SameLine(ctx)
                r.ImGui_BeginGroup(ctx)
                r.ImGui_Text(ctx, "Preview")
                drawPreviewPanel()
                r.ImGui_EndGroup(ctx)
                
                r.ImGui_EndTabItem(ctx)
            end
            
            -- Layout tab
            if r.ImGui_BeginTabItem(ctx, "Layout") then
                -- Column for layout controls
                r.ImGui_BeginChild(ctx, "layout_panel", 500, 0, 0)
                
                r.ImGui_Text(ctx, "Dimensions")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                local changed, new_value
                
                changed, new_value = drawSlider("Columns Per Page", config.columns_per_page, 1, 20)
                if changed then config.columns_per_page = new_value end
                
                changed, new_value = drawSlider("Item Height", config.item_height, 16, 50)
                if changed then config.item_height = new_value end
                
                changed, new_value = drawSlider("Title Height", config.title_height, 20, 50)
                if changed then config.title_height = new_value end
                
                changed, new_value = drawSlider("Header Height", config.header_height, 20, 60)
                if changed then config.header_height = new_value end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Spacing")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                changed, new_value = drawSlider("Column Padding", config.column_padding, 0, 20)
                if changed then config.column_padding = new_value end
                
                changed, new_value = drawSlider("Column Spacing", config.column_spacing, 0, 40)
                if changed then config.column_spacing = new_value end
                
                changed, new_value = drawSlider("Section Spacing", config.section_spacing, 0, 30)
                if changed then config.section_spacing = new_value end
                
                changed, new_value = drawSlider("Text Margin", config.text_margin, 0, 20)
                if changed then config.text_margin = new_value end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Style")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                changed, new_value = drawSlider("Window Rounding", config.window_rounding, 0, 20)
                if changed then config.window_rounding = new_value end
                
                changed, new_value = drawSlider("Child Rounding", config.child_rounding, 0, 20)
                if changed then config.child_rounding = new_value end
                
                changed, new_value = drawSlider("Button Rounding", config.button_rounding, 0, 20)
                if changed then config.button_rounding = new_value end
                
                changed, new_value = drawSlider("Border Size", config.border_size, 0, 5, "%.1f")
                if changed then config.border_size = new_value end
                
                changed, new_value = drawSlider("Scrollbar Size", config.scrollbar_size, 5, 25)
                if changed then config.scrollbar_size = new_value end
                
                r.ImGui_EndChild(ctx)
                
                -- Preview panel on the right
                r.ImGui_SameLine(ctx)
                r.ImGui_BeginGroup(ctx)
                r.ImGui_Text(ctx, "Preview")
                drawPreviewPanel()
                r.ImGui_EndGroup(ctx)
                
                r.ImGui_EndTabItem(ctx)
            end
            
            -- Fonts & Behavior tab
            if r.ImGui_BeginTabItem(ctx, "Fonts & Behavior") then
                -- Columns layout for this tab
                r.ImGui_BeginChild(ctx, "font_behavior_panel", 500, 0, 0)
                
                r.ImGui_Text(ctx, "Fonts")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                local changed, new_value
                
                local font_names = {"sans-serif", "serif", "monospace", "Arial", "Verdana", "Tahoma", "Georgia", "FiraSans-Regular"}
                changed, new_value = drawCombo("Font Name", config.font_name, font_names)
                if changed then config.font_name = new_value end
                
                changed, new_value = drawSlider("Font Size", config.font_size, 8, 32)
                if changed then config.font_size = new_value end
                
                changed, new_value = drawSlider("Title Font Size", config.title_font_size, 10, 36)
                if changed then config.title_font_size = new_value end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Note: Font changes require restarting the Soundboard script")
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Behavior")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                changed, new_value = drawCheckbox("Show Tooltips", config.show_tooltips)
                if changed then config.show_tooltips = new_value end
                
                changed, new_value = drawCheckbox("Compact View", config.compact_view)
                if changed then 
                    config.compact_view = new_value 
                    -- If compact view is enabled, adjust spacing and padding
                    if new_value then
                        config.item_height = 22
                        config.column_padding = 2
                        config.section_spacing = 5
                        config.text_margin = 4
                    else
                        -- Reset to default spacing
                        config.item_height = default_config.item_height
                        config.column_padding = default_config.column_padding
                        config.section_spacing = default_config.section_spacing
                        config.text_margin = default_config.text_margin
                    end
                end
                
                changed, new_value = drawCheckbox("Enable Animations", config.enable_animations)
                if changed then config.enable_animations = new_value end
                
                if config.enable_animations then
                    r.ImGui_Indent(ctx, 20)
                    changed, new_value = drawSlider("Animation Speed", config.animation_speed, 0.1, 1.0, "%.1f s")
                    if changed then config.animation_speed = new_value end
                    r.ImGui_Unindent(ctx, 20)
                end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Theme Variant")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                local theme_variants = {"dark", "light", "custom"}
                changed, new_value = drawCombo("Theme Variant", config.theme_variant, theme_variants)
                if changed then 
                    config.theme_variant = new_value 
                    -- Apply base theme colors
                    if new_value == "dark" then
                        config.window_bg = 0x181818FF
                        config.text_color = 0xDDDDDDFF
                        config.child_bg = 0x1E1E1EFF
                        config.border_color = 0x444444FF
                    elseif new_value == "light" then
                        config.window_bg = 0xF5F5F5FF
                        config.text_color = 0x222222FF
                        config.child_bg = 0xFFFFFFFF
                        config.border_color = 0xCCCCCCFF
                    end
                end
                
                r.ImGui_EndChild(ctx)
                
                -- Preview panel on the right
                r.ImGui_SameLine(ctx)
                r.ImGui_BeginGroup(ctx)
                r.ImGui_Text(ctx, "Preview")
                drawPreviewPanel()
                r.ImGui_EndGroup(ctx)
                
                r.ImGui_EndTabItem(ctx)
            end
            
            -- Advanced tab
            if r.ImGui_BeginTabItem(ctx, "Advanced") then
                -- Export/import settings section
                r.ImGui_Text(ctx, "Export/Import Settings")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                -- Export button
                if r.ImGui_Button(ctx, "Export Settings", 200, 30) then
                    if r.APIExists("JS_Dialog_BrowseForSaveFile") then
                        local rv, filename = r.JS_Dialog_BrowseForSaveFile("Export Soundboard Style", "", "Soundboard Style.json", "JSON files (*.json)\0*.json\0All files\0*.*\0")
                        if rv and filename ~= "" then
                            -- Add .json extension if not present
                            if not filename:match("%.json$") then
                                filename = filename .. ".json"
                            end
                            
                            -- Write settings to file
                            local file = io.open(filename, "w")
                            if file then
                                file:write(serializeTable(config))
                                file:close()
                                r.ShowMessageBox("Settings successfully exported to " .. filename, "Export Complete", 0)
                            else
                                r.ShowMessageBox("Failed to write to file " .. filename, "Export Error", 0)
                            end
                        end
                    else
                        r.ShowMessageBox("This feature requires JS_ReaScriptAPI extension", "Missing Extension", 0)
                    end
                end
                
                -- Import button
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Import Settings", 200, 30) then
                    if r.APIExists("JS_Dialog_BrowseForOpenFiles") then
                        local rv, filename = r.JS_Dialog_BrowseForOpenFiles("Import Soundboard Style", "", "JSON files (*.json)\0*.json\0All files\0*.*\0", false)
                        if rv and filename ~= "" then
                            -- Read settings from file
                            local file = io.open(filename, "r")
                            if file then
                                local content = file:read("*all")
                                file:close()
                                
                                -- Parse JSON
                                local success, imported_config = pcall(function() return load("return " .. content)() end)
                                if success and type(imported_config) == "table" then
                                    -- Apply imported settings
                                    for k, v in pairs(imported_config) do
                                        config[k] = v
                                    end
                                    current_preset = "Custom"
                                    r.ShowMessageBox("Settings successfully imported", "Import Complete", 0)
                                else
                                    r.ShowMessageBox("Failed to parse settings file", "Import Error", 0)
                                end
                            else
                                r.ShowMessageBox("Failed to read file " .. filename, "Import Error", 0)
                            end
                        end
                    else
                        r.ShowMessageBox("This feature requires JS_ReaScriptAPI extension", "Missing Extension", 0)
                    end
                end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Spacing(ctx)
                
                -- Direct configuration editor
                r.ImGui_Text(ctx, "Expert Mode: Direct Configuration")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                r.ImGui_TextWrapped(ctx, "You can edit specific configuration values directly by entering the key and value below.")
                r.ImGui_Spacing(ctx)
                
                -- Static variables for this editor
                local key_input = ""
                local value_input = ""
                
                r.ImGui_PushItemWidth(ctx, 200)
                local k_changed, new_key = r.ImGui_InputText(ctx, "Key", key_input)
                if k_changed then key_input = new_key end
                
                r.ImGui_SameLine(ctx)
                local v_changed, new_value = r.ImGui_InputText(ctx, "Value", value_input)
                if v_changed then value_input = new_value end
                
                r.ImGui_PopItemWidth(ctx)
                
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Set Value") and key_input ~= "" then
                    -- Try to convert the value
                    local value
                    local num_value = tonumber(value_input)
                    
                    if value_input == "true" then
                        value = true
                    elseif value_input == "false" then
                        value = false
                    elseif num_value then
                        value = num_value
                    else
                        value = value_input
                    end
                    
                    -- Set the value in config
                    config[key_input] = value
                    key_input = ""
                    value_input = ""
                    
                    -- Update current preset
                    current_preset = "Custom"
                end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Current Configuration:")
                r.ImGui_BeginChild(ctx, "config_dump", -1, 300, getChildFlags(true))
                
                -- Display current config as text
                local config_text = "config = " .. serializeTable(config)
                r.ImGui_TextWrapped(ctx, config_text)
                
                r.ImGui_EndChild(ctx)
                
                r.ImGui_EndTabItem(ctx)
            end
            
            r.ImGui_EndTabBar(ctx)
        end
        
        -- Pop the font if it was pushed
        if font then
            r.ImGui_PopFont(ctx)
        end
        
        -- Handle popups
        
        -- Save preset popup
        if r.ImGui_BeginPopupModal(ctx, "Save Preset", nil, r.ImGui_WindowFlags_AlwaysAutoResize()) then
            r.ImGui_Text(ctx, "Enter preset name:")
            r.ImGui_Spacing(ctx)
            
            r.ImGui_PushItemWidth(ctx, 300)
            local name_changed, new_name = r.ImGui_InputText(ctx, "##preset_name", new_preset_name)
            if name_changed then new_preset_name = new_name end
            r.ImGui_PopItemWidth(ctx)
            
            r.ImGui_Spacing(ctx)
            
            if r.ImGui_Button(ctx, "Save", 120, 0) and new_preset_name ~= "" then
                saveAsPreset(new_preset_name)
                new_preset_name = "My Preset"
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            r.ImGui_SameLine(ctx)
            
            if r.ImGui_Button(ctx, "Cancel", 120, 0) then
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            r.ImGui_EndPopup(ctx)
        end
        
        -- Delete preset popup
        if r.ImGui_BeginPopupModal(ctx, "Delete Preset", nil, r.ImGui_WindowFlags_AlwaysAutoResize()) then
            r.ImGui_Text(ctx, "Are you sure you want to delete preset '" .. current_preset .. "'?")
            r.ImGui_Spacing(ctx)
            
            if r.ImGui_Button(ctx, "Yes", 120, 0) then
                deletePreset(current_preset)
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            r.ImGui_SameLine(ctx)
            
            if r.ImGui_Button(ctx, "No", 120, 0) then
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            r.ImGui_EndPopup(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    -- Clean up the styles we applied
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end
    
    -- Continue the loop if window is open
    if open then
        r.defer(loop)
    else
        -- Save configuration on close
        saveConfig()
    end
end

-- Initialize
function init()
    -- Load configuration
    loadConfig()
    
    -- Initialize style_loader's fonts
    if style_loader then
        style_loader.applyFontsToContext(ctx)
    end
    
    -- Start the main loop
    loop()
end

-- Script entry point
init()