-- @description Multi-Toolbar Manager
-- @version 2.1
-- @author Claude
-- @about
--   Create and manage multiple custom action toolbars

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local extname_base = "CP_MULTI_TOOLBAR"

-- Toolbar collection to store all toolbars
local toolbars = {}
local current_toolbar_index = 1
local show_toolbar_manager = false

-- Preset management
local presets = {}
local current_preset = "default"

-- Current action being edited (for icon browser)
local current_editing_action_index = nil

-- Create main ImGui context for settings - initialized to nil until needed
local main_ctx = nil
local main_font = nil

-- Function to create a shallow copy of a table
local function shallow_copy(orig)
    if type(orig) ~= "table" then
        return orig
    end
    
    local copy = {}
    for orig_key, orig_value in pairs(orig) do
        if type(orig_value) == "table" then
            copy[orig_key] = shallow_copy(orig_value)
        else
            copy[orig_key] = orig_value
        end
    end
    return copy
end

-- Default action setup
local default_actions = {
    { command_id = 1007, name = "Transport: Play/Stop", label = "Play/Stop", icon = "play.png" },
    { command_id = 1013, name = "Transport: Record", label = "Record", icon = "record.png" },
    { command_id = 40364, name = "View: Toggle metronome", label = "Metro", icon = "metronome.png" },
    { command_id = 1157, name = "Grid: Toggle snap to grid", label = "Grid", icon = "grid.png" },
}

-- Default toolbar template
local default_toolbar_template = {
    -- Toolbar identification
    id = "",
    name = "",
    is_enabled = true,
    
    -- UI positioning
    window_to_follow = "main", -- "main", "transport", "mixer", "media_explorer", "ruler", "arrange"
    docker_id = 0,  
    snap_to = "right", -- "left" or "right" - determines which side to align to
    use_responsive_layout = true, -- Whether to automatically wrap buttons to next line
    offset_x = 10,  -- Horizontal offset
    offset_y = 4,   -- Vertical offset
    widget_width = 330,
    widget_height = 36,
    last_pos_x = 1000,
    last_pos_y = 1000,
    
    -- Appearance
    font_size = 16,
    current_font = "Verdana",
    use_high_dpi_font = true,
    background_color = 0x1E1E1EFF,  -- Dark gray background
    text_color = 0xFFFFFFFF,        -- White text
    button_color = 0x1E1E1EFF,
    button_hover_color = 0x363636FF,
    button_active_color = 0x1E1E1EFF,
    border_color = 0x313131FF,
    border_size = 2.0,
    window_rounding = 20.0,
    frame_rounding = 20.0,
    popup_rounding = 6.0,
    grab_rounding = 6.0,
    grab_min_size = 8.0,
    button_border_size = 1.0,
    button_spacing = 0,
    show_background = true, -- Moved to appearance section
    
    -- Toolbar configuration
    actions = {},  -- Will store command IDs and custom names/icons
    button_width = 30,   -- Width of buttons
    button_height = 28,  -- Height of buttons
    icon_size = 30,      -- Size of icons within buttons
    preserve_icon_aspect_ratio = true, -- Whether to preserve icon aspect ratio
    show_icons = true,   -- Whether to show icons
    center_buttons = true, -- Whether to center buttons
    icon_path = "",      -- Custom path to icons
    show_tooltips = true, -- Whether to show tooltips
    use_reaper_icons = true, -- Whether to use REAPER's multi-state icons
    min_window_width = 1800,  -- Minimum width of REAPER window in pixels
    min_window_height = 200, -- Minimum height of REAPER window in pixels
    auto_hide = true,        -- Enable/disable auto-hide function
    adaptive_width = 50,
    
    -- Settings dialog state
    settings_open = false,
    section_states = {
        position = true,
        appearance = false,
        buttons = false,
        actions = true,
        import_export = false
    },
    
    -- Runtime state
    context = nil,
    font = nil,
    font_needs_update = false,
    force_position_update = false,
    first_position_set = false,
    icons = {},
    reaper_icon_states = {}
}

-- Load the style loader module
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
local style_loader = nil

local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

-- Fonction pour normaliser les chemins (à ajouter près du début du script)
function NormalizePath(path)
    if not path then return nil end
    
    -- Sous Windows, normaliser vers backslash
    if r.GetOS():match("Win") then
        return path:gsub("/", "\\")
    end
    
    -- Sous macOS/Linux, normaliser vers forward slash
    return path:gsub("\\", "/")
end

-- Define serialize function if it doesn't exist
if not r.serialize then
    function r.serialize(tbl)
        local res = "{"
        for k, v in pairs(tbl) do
            if type(k) == "string" then
                res = res .. '["' .. k .. '"]='
            else
                res = res .. "[" .. k .. "]="
            end
            if type(v) == "table" then
                res = res .. r.serialize(v)
            elseif type(v) == "string" then
                res = res .. string.format("%q", v)
            elseif type(v) == "number" or type(v) == "boolean" then
                res = res .. tostring(v)
            end
            res = res .. ","
        end
        return res .. "}"
    end
end

-- Save/Load settings
function SaveToolbars()
    -- First, save the toolbar list
    local toolbar_list = {}
    for i, tb in ipairs(toolbars) do
        toolbar_list[i] = {
            id = tb.id,
            name = tb.name,
            is_enabled = tb.is_enabled
        }
    end
    
    -- Save toolbar list
    r.SetExtState(extname_base, "toolbar_list", r.serialize(toolbar_list), true)
    
    -- Then save each toolbar's settings separately
    for _, tb in ipairs(toolbars) do
        -- Create a copy without runtime elements
        local tb_copy = shallow_copy(tb)
        tb_copy.context = nil
        tb_copy.font = nil
        tb_copy.font_needs_update = nil
        tb_copy.force_position_update = nil
        tb_copy.first_position_set = nil
        tb_copy.icons = {}
        tb_copy.reaper_icon_states = {}
        
        r.SetExtState(extname_base .. "_" .. tb.id, "settings", r.serialize(tb_copy), true)
    end
    
    -- Save current toolbar index
    r.SetExtState(extname_base, "current_toolbar", tostring(current_toolbar_index), true)
    
    -- Save current preset
    r.SetExtState(extname_base, "current_preset", current_preset, true)
end

function LoadToolbars()
    -- Load toolbar list
    local state_str = r.GetExtState(extname_base, "toolbar_list")
    if state_str ~= "" then
        local success, toolbar_list = pcall(function() return load("return " .. state_str)() end)
        if success and toolbar_list and #toolbar_list > 0 then
            -- Clear existing toolbars
            toolbars = {}
            
            -- Load each toolbar's settings
            for _, tb_info in ipairs(toolbar_list) do
                local toolbar_settings_str = r.GetExtState(extname_base .. "_" .. tb_info.id, "settings")
                local tb = shallow_copy(default_toolbar_template)
                
                if toolbar_settings_str ~= "" then
                    local success, loaded_settings = pcall(function() return load("return " .. toolbar_settings_str)() end)
                    if success and loaded_settings then
                        for k, v in pairs(loaded_settings) do
                            tb[k] = v
                        end
                    end
                end
                
                -- Ensure ID and name are preserved
                tb.id = tb_info.id
                tb.name = tb_info.name
                tb.is_enabled = tb_info.is_enabled
                
                -- Backward compatibility for older versions
                if tb.snap_to == "transport" or tb.snap_to == "mixer" or 
                   tb.snap_to == "media_explorer" or tb.snap_to == "ruler" or
                   tb.snap_to == "arrange" then
                    -- Convert old snap_to to window_to_follow format
                    tb.window_to_follow = tb.snap_to
                    tb.snap_to = "left" -- Default to left
                elseif not tb.window_to_follow then
                    -- If no window_to_follow but has snap_to, it's an older version
                    tb.window_to_follow = "main"
                end
                
                -- Set up runtime state for each toolbar
                tb.context = nil  -- Will be created on first use
                tb.font = nil
                tb.font_needs_update = true
                tb.force_position_update = true
                tb.first_position_set = false
                tb.icons = {}
                tb.reaper_icon_states = {}
                
                table.insert(toolbars, tb)
            end
        end
    end
    
    -- If no toolbars were loaded, create a default one
    if #toolbars == 0 then
        CreateNewToolbar("Default Toolbar")
    end
    
    -- Load current toolbar index
    local current_idx_str = r.GetExtState(extname_base, "current_toolbar")
    if current_idx_str ~= "" then
        current_toolbar_index = tonumber(current_idx_str) or 1
    end
    
    -- Ensure current_toolbar_index is valid
    if current_toolbar_index < 1 or current_toolbar_index > #toolbars then
        current_toolbar_index = 1
    end
    
    -- Load current preset
    local preset = r.GetExtState(extname_base, "current_preset")
    if preset ~= "" then
        current_preset = preset
    end
    
    -- Load presets
    LoadPresets()
end

-- Create a new toolbar
function CreateNewToolbar(name)
    local new_id = "toolbar_" .. os.time() .. "_" .. math.random(1000, 9999)
    local new_toolbar = shallow_copy(default_toolbar_template)
    
    new_toolbar.id = new_id
    new_toolbar.name = name or "New Toolbar"
    new_toolbar.actions = shallow_copy(default_actions)
    new_toolbar.context = nil -- Will be created on first use
    new_toolbar.font = nil
    new_toolbar.font_needs_update = true
    new_toolbar.force_position_update = true
    new_toolbar.first_position_set = false
    
    table.insert(toolbars, new_toolbar)
    
    -- Create the REAPER action for this toolbar
    CreateToolbarAction(new_toolbar)
    
    return #toolbars
end

-- Create REAPER actions for a toolbar (On and Off)
function CreateToolbarAction(toolbar)
    -- Create two action names - one for ON and one for OFF
    local action_name_on = "CP_CustomToolbars_" .. toolbar.name .. "_On"
    local action_name_off = "CP_CustomToolbars_" .. toolbar.name .. "_Off"
    
    local action_id_on = r.NamedCommandLookup("_" .. action_name_on)
    local action_id_off = r.NamedCommandLookup("_" .. action_name_off)
    
    -- Create ON script
    local action_path_on = r.GetResourcePath() .. "/Scripts/" .. action_name_on .. ".lua"
    local script_content_on = [[
-- Enable toolbar ]] .. toolbar.name .. [[

local r = reaper

function EnableToolbar()
    -- Enable toolbar
    r.SetExtState("CP_MULTI_TOOLBAR", "]] .. toolbar.id .. [[_state", "1", false)
    -- Force refresh on next frame
    r.SetExtState("CP_MULTI_TOOLBAR", "refresh_toolbars", "1", false)
end

EnableToolbar()
]]

    -- Create OFF script
    local action_path_off = r.GetResourcePath() .. "/Scripts/" .. action_name_off .. ".lua"
    local script_content_off = [[
-- Disable toolbar ]] .. toolbar.name .. [[

local r = reaper

function DisableToolbar()
    -- Disable toolbar
    r.SetExtState("CP_MULTI_TOOLBAR", "]] .. toolbar.id .. [[_state", "0", false)
    -- Force refresh on next frame
    r.SetExtState("CP_MULTI_TOOLBAR", "refresh_toolbars", "1", false)
end

DisableToolbar()
]]

    -- Write the ON script file
    local success_on = false
    local file_on = io.open(action_path_on, "w")
    if file_on then
        file_on:write(script_content_on)
        file_on:close()
        
        -- Register the action if it doesn't exist
        if action_id_on == 0 then
            r.AddRemoveReaScript(true, 0, action_path_on, true)
            action_id_on = r.NamedCommandLookup("_" .. action_name_on)
        end
        success_on = (action_id_on ~= 0)
    end
    
    -- Write the OFF script file
    local success_off = false
    local file_off = io.open(action_path_off, "w")
    if file_off then
        file_off:write(script_content_off)
        file_off:close()
        
        -- Register the action if it doesn't exist
        if action_id_off == 0 then
            r.AddRemoveReaScript(true, 0, action_path_off, true)
            action_id_off = r.NamedCommandLookup("_" .. action_name_off)
        end
        success_off = (action_id_off ~= 0)
    end
    
    return {
        success = success_on and success_off,
        on_id = action_id_on,
        off_id = action_id_off
    }
end

-- Check if toolbar needs to be toggled
function CheckToolbarToggleState()
    local refresh_needed = false
    
    -- Check for each toolbar if its state changed
    for _, tb in ipairs(toolbars) do
        local toggle_state = r.GetExtState(extname_base, tb.id .. "_state")
        if toggle_state ~= "" then
            local new_state = toggle_state == "1"
            if tb.is_enabled ~= new_state then
                tb.is_enabled = new_state
                refresh_needed = true
            end
            -- Clear the state
            r.DeleteExtState(extname_base, tb.id .. "_state", false)
        end
    end
    
    -- Check if global refresh is requested
    local refresh_flag = r.GetExtState(extname_base, "refresh_toolbars")
    if refresh_flag == "1" then
        refresh_needed = true
        r.DeleteExtState(extname_base, "refresh_toolbars", false)
    end
    
    if refresh_needed then
        SaveToolbars()
    end
    
    return refresh_needed
end

function GetCommandName(command_id)
    if not command_id then return "Unknown" end
    
    -- For numeric commands, try CF_GetCommandText if available
    if type(command_id) == "number" then
        -- Try CF_GetCommandText first (SWS extension)
        if r.CF_GetCommandText then
            local name = r.CF_GetCommandText(0, command_id) -- 0 = main section
            if name and name ~= "" then
                return name
            end
        end
        
        -- Fallback to GetActionName if available
        if r.GetActionName then
            local _, name = r.GetActionName(0, command_id)
            if name and name ~= "" then
                return name
            end
        end
        
        -- If no name found, just return the ID
        return "Command ID: " .. tostring(command_id)
    else
        -- For named commands, try to look them up
        local cmd_id = 0
        pcall(function() cmd_id = r.NamedCommandLookup(command_id) end)
        
        if cmd_id and cmd_id ~= 0 then
            -- If we got an ID, try CF_GetCommandText
            if r.CF_GetCommandText then
                local name = r.CF_GetCommandText(0, cmd_id)
                if name and name ~= "" then
                    return name
                end
            end
            
            -- Fallback to GetActionName
            if r.GetActionName then
                local _, name = r.GetActionName(0, cmd_id)
                if name and name ~= "" then
                    return name
                end
            end
            
            return "Command: " .. tostring(command_id) .. " (ID: " .. tostring(cmd_id) .. ")"
        else
            return "Command: " .. tostring(command_id)
        end
    end
end

function BrowseIconsDialog(toolbar, action_index)
    -- If main context is not valid, do nothing
    if not main_ctx or not r.ImGui_ValidatePtr(main_ctx, "ImGui_Context*") then
        return false
    end
    
    -- Window size
    r.ImGui_SetNextWindowSize(main_ctx, 600, 400, r.ImGui_Cond_FirstUseEver())
    
    if r.ImGui_BeginPopupModal(main_ctx, "Icon Browser", true) then
        -- Default path if none is defined
        local base_path = toolbar.icon_path or ""
        if base_path == "" then
            -- Use REAPER's default toolbar icons path
            base_path = NormalizePath(r.GetResourcePath() .. "/Data/toolbar_icons")
        end
        
        -- Path selector
        r.ImGui_Text(main_ctx, "Path:")
        local path_changed, new_path = r.ImGui_InputText(main_ctx, "##path", base_path, 256)
        if path_changed then
            toolbar.icon_path = new_path
        end
        
        -- Filter/search
        local static_filter = r.GetExtState(extname_base, "icon_filter") or ""
        local filter_changed, new_filter = r.ImGui_InputText(main_ctx, "Filter", static_filter, 64)
        if filter_changed then
            r.SetExtState(extname_base, "icon_filter", new_filter, false)
            static_filter = new_filter
        end
        
        -- Show current filter for debugging
        if static_filter ~= "" then
            r.ImGui_SameLine(main_ctx)
            r.ImGui_TextColored(main_ctx, 0x88FF88FF, "Filtering: " .. static_filter)
        end
        
        r.ImGui_Separator(main_ctx)
        
        -- Grid configuration
        local cell_size = 70
        local icon_display_size = 30  -- Size adjusted to match toolbar size
        local window_width = r.ImGui_GetContentRegionAvail(main_ctx)
        local columns = math.max(1, math.floor(window_width / cell_size))
        
        -- Create a ScrollingArea for icons
        if r.ImGui_BeginChild(main_ctx, "IconGrid", -1, -40) then
            -- List files with filtering
            local all_files = {}
            local filtered_files = {}
            
            -- Use pcall to safely attempt file enumeration
            pcall(function()
                local i = 0
                local file = r.EnumerateFiles(base_path, i)
                while file do
                    if file:match("%.png$") or file:match("%.ico$") then
                        -- Add to all files
                        table.insert(all_files, file)
                        
                        -- Apply filter if set
                        if static_filter == "" or string.lower(file):find(string.lower(static_filter), 1, true) then
                            table.insert(filtered_files, file)
                        end
                    end
                    i = i + 1
                    file = r.EnumerateFiles(base_path, i)
                end
            end)
            
            -- Show filter stats if filtering is active
            if static_filter ~= "" then
                r.ImGui_TextColored(main_ctx, 0x88FFFFFF, string.format("Showing %d of %d icons", #filtered_files, #all_files))
                r.ImGui_Separator(main_ctx)
            end
            
            if #filtered_files == 0 then
                if #all_files > 0 then
                    r.ImGui_TextColored(main_ctx, 0xFFFF00FF, "No icons match your filter criteria.")
                    r.ImGui_Text(main_ctx, "Try a different filter term or clear the filter.")
                else
                    r.ImGui_TextColored(main_ctx, 0xFFFF00FF, "No icons found in this path.")
                    r.ImGui_Text(main_ctx, "Try setting the correct path to your REAPER icons folder.")
                    r.ImGui_Spacing(main_ctx)
                    r.ImGui_Text(main_ctx, "Example: C:/Users/Username/AppData/Roaming/REAPER/Data/toolbar_icons")
                end
            else
                -- Display icons in a manual grid
                local current_col = 0
                for _, file in ipairs(filtered_files) do
                    -- If not in first column, use SameLine
                    if current_col > 0 then
                        r.ImGui_SameLine(main_ctx)
                    end
                    
                    -- Create a group for each cell to center icon
                    r.ImGui_BeginGroup(main_ctx)
                    
                    -- Try to load the icon
                    local texture = nil
                    local icon_found = false
                    
                    -- First try to load as a multi-state icon
                    local normal_state = nil
                    if toolbar.use_reaper_icons then
                        pcall(function()
                            normal_state, _, _ = LoadReaperIconStates(toolbar, file)
                        end)
                    end
                    
                                                        -- Set up the display area with proper padding for cell centering
                    local padding_x = (cell_size - icon_display_size) / 2
                    r.ImGui_Dummy(main_ctx, padding_x, 0)
                    r.ImGui_SameLine(main_ctx)
                    
                    -- Display either an image button or text button
                    local selected = false
                    if normal_state and normal_state.texture and r.ImGui_ValidatePtr(normal_state.texture, "ImGui_Image*") then
                        -- For multi-state icons, only show the normal state at the proper size
                        if normal_state.uv then
                            -- For 90x30 icons, display just the proper 30x30 portion
                            selected = r.ImGui_ImageButton(main_ctx, "##" .. file, normal_state.texture, 
                                                  icon_display_size, icon_display_size,
                                                  normal_state.uv[1], normal_state.uv[2], 
                                                  normal_state.uv[3], normal_state.uv[4])
                            icon_found = true
                        else
                            selected = r.ImGui_ImageButton(main_ctx, "##" .. file, normal_state.texture, 
                                                         icon_display_size, icon_display_size)
                            icon_found = true
                        end
                    else
                        -- Try as regular icon
                        texture = LoadIcon(toolbar, file)
                        if texture and r.ImGui_ValidatePtr(texture, "ImGui_Image*") then
                            selected = r.ImGui_ImageButton(main_ctx, "##" .. file, texture, 
                                                        icon_display_size, icon_display_size)
                            icon_found = true
                        else
                            -- Just show a placeholder button
                            selected = r.ImGui_Button(main_ctx, "?", icon_display_size, icon_display_size)
                        end
                    end
                    
                    -- No more filename display as requested
                    
                    r.ImGui_EndGroup(main_ctx)
                    
                    -- Tooltips with filename
                    if r.ImGui_IsItemHovered(main_ctx) then
                        r.ImGui_BeginTooltip(main_ctx)
                        r.ImGui_Text(main_ctx, file)
                        r.ImGui_EndTooltip(main_ctx)
                    end
                    
                    -- If icon is selected
                    if selected then
                        -- Apply icon to current action
                        if toolbar.actions[action_index] then
                            toolbar.actions[action_index].icon = file
                            -- Clear icon caches to force reload
                            toolbar.icons[file] = nil
                            toolbar.reaper_icon_states[file] = nil
                        end
                        
                        r.ImGui_CloseCurrentPopup(main_ctx)
                        r.ImGui_EndChild(main_ctx)
                        r.ImGui_EndPopup(main_ctx)
                        return true
                    end
                    
                    -- Move to next column or next row
                    current_col = current_col + 1
                    if current_col >= columns then
                        current_col = 0
                    end
                end
            end
            
            r.ImGui_EndChild(main_ctx)
        end
        
        -- Bottom buttons
        r.ImGui_Separator(main_ctx)
        if r.ImGui_Button(main_ctx, "Cancel", 120, 0) then
            r.ImGui_CloseCurrentPopup(main_ctx)
        end
        
        r.ImGui_EndPopup(main_ctx)
        return false
    end
    
    return false
end

-- Initialize main font - with safety checking
function InitMainFont()
    -- Check if context exists, create if not
    if not main_ctx or not r.ImGui_ValidatePtr(main_ctx, "ImGui_Context*") then
        main_ctx = r.ImGui_CreateContext('Multi-Toolbar Manager')
        -- Reset font since context changed
        main_font = nil
    end
    
    -- Create font if needed and attach to context
    if main_ctx and (not main_font or not r.ImGui_ValidatePtr(main_font, "ImGui_Font*")) then
        main_font = r.ImGui_CreateFont("Verdana", 14)
        if main_font then
            r.ImGui_Attach(main_ctx, main_font)
        end
    end
    
    return main_ctx ~= nil and main_font ~= nil
end

-- Initialize font for a toolbar with safety checking
function InitFont(toolbar)
    -- Check if context exists, create if not
    if not toolbar.context or not r.ImGui_ValidatePtr(toolbar.context, "ImGui_Context*") then
        toolbar.context = r.ImGui_CreateContext('Toolbar_' .. toolbar.id)
        -- Reset font since context changed
        toolbar.font = nil
    end
    
    if toolbar.context then
        local flags = 0
        if toolbar.use_high_dpi_font then
            flags = r.ImGui_FontFlags_None()
        else
            -- Try to match REAPER's font rendering more closely
            flags = r.ImGui_FontFlags_NoHinting() + r.ImGui_FontFlags_NoAutoHint()
        end
        
        -- Make sure we're using Verdana if that's what we want
        if toolbar.current_font:lower() ~= "verdana" and toolbar.current_font ~= "Tahoma" then
            toolbar.current_font = "Verdana"
        end
        
        -- Create font if needed
        if not toolbar.font or not r.ImGui_ValidatePtr(toolbar.font, "ImGui_Font*") then
            -- Try to load the font from system
            toolbar.font = r.ImGui_CreateFont(toolbar.current_font, toolbar.font_size, flags)
            if toolbar.font then
                r.ImGui_Attach(toolbar.context, toolbar.font)
            end
        end
        
        toolbar.font_needs_update = false
        return toolbar.font ~= nil
    end
    
    return false
end

-- Clear all icon caches for a toolbar
function ClearIconCaches(toolbar)
    toolbar.icons = {}
    toolbar.reaper_icon_states = {}
end

-- Modifier la fonction FindIconFile 
function FindIconFile(toolbar, icon_path)
    if not icon_path or icon_path == "" then return nil end
    
    -- Si déjà un chemin absolu et existe, utilisez-le
    if r.file_exists(icon_path) then
        return icon_path
    end
    
    -- Définir le chemin par défaut des icônes (toolbar_icons)
    local default_icons_path = NormalizePath(r.GetResourcePath() .. "/Data/toolbar_icons/")  -- Ajout du slash final
    
    -- Essayer différents chemins
    local paths_to_try = {
        NormalizePath(script_path .. "/" .. icon_path),  -- Ajout du séparateur
        toolbar.icon_path ~= "" and NormalizePath(toolbar.icon_path .. "/" .. icon_path) or nil,
        NormalizePath(default_icons_path .. icon_path),
        NormalizePath(r.GetResourcePath() .. "/Data/track_icons/" .. icon_path),  -- Séparateurs ajoutés à tous les chemins
        NormalizePath(r.GetResourcePath() .. "/Data/theme_icons/" .. icon_path),
        NormalizePath(r.GetResourcePath() .. "/Data/icons/" .. icon_path),
        NormalizePath(r.GetResourcePath() .. "/Plugins/FX/ReaPlugs/JS/icons/" .. icon_path)
    }
    
    for i, path in ipairs(paths_to_try) do
        if path and r.file_exists(path) then
            return path
        end
    end
    
    -- Essayer d'utiliser le fichier directement depuis le dossier toolbar_icons en dernier recours
    local direct_path = NormalizePath(default_icons_path .. r.GetResourcePath():match("([^/\\]+)$") .. "_" .. icon_path)
    if r.file_exists(direct_path) then
        return direct_path
    end
    
    return nil
end

-- Regular icon loading (basic single-state icons)
function LoadIcon(toolbar, icon_path)
    if not icon_path or icon_path == "" then return nil end
    
    if toolbar.icons[icon_path] then return toolbar.icons[icon_path] end
    
    local full_path = FindIconFile(toolbar, icon_path)
    if not full_path then return nil end
    
    -- Try to create image
    local success, texture = pcall(function() return r.ImGui_CreateImage(full_path) end)
    if success and texture then
        toolbar.icons[icon_path] = texture
        return texture
    end
    
    return nil
end

-- Load REAPER's multi-state icons (normal, hover, active)
function LoadReaperIconStates(toolbar, icon_path)
    if not icon_path or icon_path == "" then return nil, nil, nil end
    
    if toolbar.reaper_icon_states[icon_path] then
        return toolbar.reaper_icon_states[icon_path].normal,
               toolbar.reaper_icon_states[icon_path].hover,
               toolbar.reaper_icon_states[icon_path].active
    end
    
    local full_path = FindIconFile(toolbar, icon_path)
    if not full_path then return nil, nil, nil end
    
    -- First, let's try to load the image
    local success, texture = pcall(function() return r.ImGui_CreateImage(full_path) end)
    if not success or not texture then return nil, nil, nil end
    
    -- Check if the image has dimensions that suggest it contains multiple states
    local width, height = r.ImGui_Image_GetSize(texture)
    
    -- In REAPER, multi-state icons often have width = 3*height (3 states side by side)
    -- But also check if it's divisible by 3 (for non-square icons)
    local is_multi_state = (width % 3 == 0) or (math.abs(width/height - 3) < 0.1)
    
    if is_multi_state then
        -- This is a multi-state icon, extract the three states
        local cell_width = width / 3
        
        -- Calculate UV coordinates for each state
        local normal_uv = {0, 0, cell_width / width, 1}
        local hover_uv = {cell_width / width, 0, (cell_width * 2) / width, 1}
        local active_uv = {(cell_width * 2) / width, 0, 1, 1}
        
        toolbar.reaper_icon_states[icon_path] = {
            texture = texture,
            normal = {texture = texture, uv = normal_uv, width = cell_width, height = height},
            hover = {texture = texture, uv = hover_uv, width = cell_width, height = height},
            active = {texture = texture, uv = active_uv, width = cell_width, height = height}
        }
        
        return toolbar.reaper_icon_states[icon_path].normal,
               toolbar.reaper_icon_states[icon_path].hover,
               toolbar.reaper_icon_states[icon_path].active
    else
        -- This is a single-state icon, use it for all states
        toolbar.reaper_icon_states[icon_path] = {
            texture = texture,
            normal = {texture = texture, width = width, height = height},
            hover = {texture = texture, width = width, height = height},
            active = {texture = texture, width = width, height = height}
        }
        
        return toolbar.reaper_icon_states[icon_path].normal,
               toolbar.reaper_icon_states[icon_path].hover,
               toolbar.reaper_icon_states[icon_path].active
    end
end

-- Style setup for a toolbar
function SetStyle(toolbar, ctx)
    if not ctx or not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then return false end
    
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), toolbar.window_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), toolbar.frame_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_PopupRounding(), toolbar.popup_rounding or toolbar.window_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(), toolbar.grab_rounding or toolbar.frame_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabMinSize(), toolbar.grab_min_size or 8)
    -- Remove button borders by setting FrameBorderSize to 0
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), toolbar.border_size or 1)
    
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), toolbar.background_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), toolbar.text_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), toolbar.border_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), toolbar.button_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), toolbar.button_hover_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), toolbar.button_active_color)
    
    return true
end

-- Get window based on snap_to target for toolbar positioning
-- Modification de la fonction GetTargetWindow pour gérer les dockers et le snap to up/down
function GetTargetWindow(toolbar)
    if not r.APIExists("JS_Window_Find") then
        return nil
    end
    
    local hwnd = nil
    
    -- Utiliser window_to_follow pour déterminer quelle fenêtre suivre
    if toolbar.window_to_follow == "transport" then
        hwnd = r.JS_Window_Find("transport", true)
    elseif toolbar.window_to_follow == "mixer" then
        hwnd = r.JS_Window_Find("mixer", true)
    elseif toolbar.window_to_follow == "media_explorer" then
        hwnd = r.JS_Window_Find("Media Explorer", true)
    elseif toolbar.window_to_follow == "ruler" then
        hwnd = r.JS_Window_Find("ruler", true)
    elseif toolbar.window_to_follow == "arrange" then
        hwnd = r.JS_Window_Find("trackview", true)
    elseif toolbar.window_to_follow == "docker" and toolbar.docker_id then
        -- Support pour les dockers
        if r.APIExists("JS_Window_FindChildByID") then
            local docker_hwnd = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000 + toolbar.docker_id)
            if docker_hwnd then
                hwnd = docker_hwnd
            else
                -- Fallback sur la fenêtre principale si le docker n'est pas trouvé
                hwnd = r.GetMainHwnd()
            end
        else
            hwnd = r.GetMainHwnd()
        end
    else
        -- Default to main window
        hwnd = r.GetMainHwnd()
    end
    
    return hwnd
end

-- Display toolbar with actions
function DisplayToolbar(toolbar, ctx)
    if not ctx or not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then return end

    -- Apply button styling
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), toolbar.button_spacing, toolbar.button_spacing)
    
    -- Calculate total buttons width for centering horizontally
    local total_width = 0
    for i = 1, #toolbar.actions do
        if toolbar.actions[i].is_separator then
            total_width = total_width + (toolbar.actions[i].width or 10) + (i > 1 and toolbar.button_spacing or 0)
        else
            total_width = total_width + toolbar.button_width + (i > 1 and toolbar.button_spacing or 0)
        end
    end
    
    -- Center buttons horizontally if enabled
    local x_offset = 0
    if toolbar.center_buttons and #toolbar.actions > 0 then
        local window_width = r.ImGui_GetWindowWidth(ctx)
        x_offset = (window_width - total_width) / 2
        if x_offset > 0 then
            r.ImGui_SetCursorPosX(ctx, x_offset)
        end
    end
    
    -- Center buttons vertically
    local window_height = r.ImGui_GetWindowHeight(ctx)
    local y_offset = (window_height - toolbar.button_height) / 2
    if y_offset > 0 then
        r.ImGui_SetCursorPosY(ctx, y_offset)
    end
    
    -- Display action buttons
    local window_width = r.ImGui_GetContentRegionAvail(ctx)
    local current_line_width = 0
    local first_in_line = true

    for i, action in ipairs(toolbar.actions) do
        -- Calculer la largeur du bouton
        local btn_width = action.is_separator and (action.width or 10) or toolbar.button_width
        
        -- Vérifier s'il y a assez d'espace sur la ligne actuelle et si on utilise le layout responsive
        if toolbar.use_responsive_layout and (current_line_width + btn_width > window_width) and not first_in_line then
            -- Pas assez d'espace, passer à la ligne suivante
            current_line_width = 0
            first_in_line = true
        end
        
        -- Si ce n'est pas le premier élément sur la ligne, utilisez SameLine
        if not first_in_line then
            r.ImGui_SameLine(ctx)
            -- Maintain vertical centering after SameLine
            if y_offset > 0 then
                r.ImGui_SetCursorPosY(ctx, y_offset)
            end
        else
            first_in_line = false
        end
        
        -- Handle separators
        if action.is_separator then
            -- Draw a separator
            r.ImGui_Dummy(ctx, action.width or 10, toolbar.button_height)
            
            -- If right-clicked on separator, also open settings
            if r.ImGui_IsItemClicked(ctx, 1) then
                show_toolbar_manager = true
                current_toolbar_index = GetToolbarIndexById(toolbar.id)
            end
            
            -- Mettre à jour la largeur utilisée sur cette ligne
            current_line_width = current_line_width + (action.width or 10) + toolbar.button_spacing
            
            -- Skip the rest of the loop for separators
            goto continue
        end
        
        -- Get command state if available
        local state = -1
        if action.command_id then
            if type(action.command_id) == "number" then
                state = r.GetToggleCommandStateEx(0, action.command_id)
            else
                local cmd_id = r.NamedCommandLookup(action.command_id)
                if cmd_id ~= 0 then
                    state = r.GetToggleCommandStateEx(0, cmd_id)
                end
            end
        end
        
        -- Set button color based on state
        if state == 1 then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), toolbar.button_active_color)
        else
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), toolbar.button_color)
        end
        
        local label = action.label or action.name or ("Action " .. i)
        if label == "" then label = "Action " .. i end
        
        -- Handle buttons based on icon settings
        local button_clicked = false
        
        -- Safer approach for icon handling
        if toolbar.show_icons and action.icon and action.icon ~= "" then
            if toolbar.use_reaper_icons then
                -- Safely try to load icon states
                local success, normal_state, hover_state, active_state = pcall(function()
                    return LoadReaperIconStates(toolbar, action.icon)
                end)
                
                if success and normal_state and normal_state.texture and 
                r.ImGui_ValidatePtr(normal_state.texture, "ImGui_Image*") then
                    -- Use the appropriate state based on button state
                    local state_to_use = state == 1 and active_state or normal_state
                    
                    -- Set padding to center icon
                    local padding_x = (toolbar.button_width - toolbar.icon_size) / 2
                    local padding_y = (toolbar.button_height - toolbar.icon_size) / 2
                    
                    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                    
                    -- AJOUTER CETTE LIGNE pour le frame rounding
                    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), toolbar.frame_rounding)
                    
                    -- Safely use UV coords if available
                    if state_to_use.uv then
                        local display_width = toolbar.icon_size
                        local display_height = toolbar.icon_size
                        
                        if toolbar.preserve_icon_aspect_ratio and state_to_use.width and state_to_use.height then
                            local original_ratio = state_to_use.width / state_to_use.height
                            
                            if original_ratio > 1 then
                                display_width = toolbar.icon_size * original_ratio
                                display_height = toolbar.icon_size
                            elseif original_ratio < 1 then
                                display_width = toolbar.icon_size
                                display_height = toolbar.icon_size / original_ratio
                            end
                        end
                        
                        -- Safely create the image button
                        local button_success, button_result = pcall(function()
                            return r.ImGui_ImageButton(ctx, label, state_to_use.texture, 
                                              display_width, display_height,
                                              state_to_use.uv[1], state_to_use.uv[2], 
                                              state_to_use.uv[3], state_to_use.uv[4])
                        end)
                        
                        button_clicked = button_success and button_result or false
                    else
                        -- Safely create regular image button
                        local button_success, button_result = pcall(function()
                            return r.ImGui_ImageButton(ctx, label, state_to_use.texture, 
                                                      toolbar.icon_size, toolbar.icon_size)
                        end)
                        
                        button_clicked = button_success and button_result or false
                    end
                    
                    r.ImGui_PopStyleVar(ctx, 2)
                else
                    -- Fallback to regular icon
                    local icon_success, icon_texture = pcall(function()
                        return LoadIcon(toolbar, action.icon)
                    end)
                    
                    if icon_success and icon_texture and r.ImGui_ValidatePtr(icon_texture, "ImGui_Image*") then
                        -- Set padding to center icon
                        local padding_x = (toolbar.button_width - toolbar.icon_size) / 2
                        local padding_y = (toolbar.button_height - toolbar.icon_size) / 2
                        
                        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                        
                        -- Safely create the image button
                        local button_success, button_result = pcall(function()
                            return r.ImGui_ImageButton(ctx, label, icon_texture, 
                                                     toolbar.icon_size, toolbar.icon_size)
                        end)
                        
                        button_clicked = button_success and button_result or false
                        
                        r.ImGui_PopStyleVar(ctx)
                    else
                        -- Fallback to text button if all icon loading fails
                        button_clicked = r.ImGui_Button(ctx, label, toolbar.button_width, toolbar.button_height)
                    end
                end
            else
                -- Regular icon loading (non-REAPER mode)
                local icon_success, icon_texture = pcall(function()
                    return LoadIcon(toolbar, action.icon)
                end)
                
                if icon_success and icon_texture and r.ImGui_ValidatePtr(icon_texture, "ImGui_Image*") then
                    -- Set padding to center icon
                    local padding_x = (toolbar.button_width - toolbar.icon_size) / 2
                    local padding_y = (toolbar.button_height - toolbar.icon_size) / 2
                    
                    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                    
                    -- Safely create the image button
                    local button_success, button_result = pcall(function()
                        return r.ImGui_ImageButton(ctx, label, icon_texture, 
                                                 toolbar.icon_size, toolbar.icon_size)
                    end)
                    
                    button_clicked = button_success and button_result or false
                    
                    r.ImGui_PopStyleVar(ctx)
                else
                    -- Fallback to text button if icon loading fails
                    button_clicked = r.ImGui_Button(ctx, label, toolbar.button_width, toolbar.button_height)
                end
            end
        else
            -- No icon, just create a text button
            button_clicked = r.ImGui_Button(ctx, label, toolbar.button_width, toolbar.button_height)
        end
        
        -- Handle button click
        if button_clicked then
            if action.command_id then
                if type(action.command_id) == "number" then
                    r.Main_OnCommand(action.command_id, 0)
                else
                    local cmd_id = r.NamedCommandLookup(action.command_id)
                    if cmd_id ~= 0 then
                        r.Main_OnCommand(cmd_id, 0)
                    end
                end
            end
        end
        
        r.ImGui_PopStyleColor(ctx)
        
        -- Optional tooltip, only show if enabled
        if toolbar.show_tooltips and r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, action.name or ("Action " .. i))
            r.ImGui_EndTooltip(ctx)
        end
        
        -- Right-click to open settings
        if r.ImGui_IsItemClicked(ctx, 1) then
            show_toolbar_manager = true
            current_toolbar_index = GetToolbarIndexById(toolbar.id)
        end
        current_line_width = current_line_width + btn_width + (i > 1 and toolbar.button_spacing or 0)
        
        ::continue::
    end
    
    r.ImGui_PopStyleVar(ctx)
end

-- Get toolbar index by ID
function GetToolbarIndexById(id)
    for i, tb in ipairs(toolbars) do
        if tb.id == id then
            return i
        end
    end
    return 1
end

function ValidateToolbarResources(toolbar)
    -- Check if any icon textures are invalid
    local needs_reload = false
    
    -- Check regular icons
    for icon_path, texture in pairs(toolbar.icons) do
        if not r.ImGui_ValidatePtr(texture, "ImGui_Image*") then
            needs_reload = true
            break
        end
    end
    
    -- Check REAPER icon states
    if not needs_reload then
        for icon_path, states in pairs(toolbar.reaper_icon_states) do
            if states.texture and not r.ImGui_ValidatePtr(states.texture, "ImGui_Image*") then
                needs_reload = true
                break
            end
        end
    end
    
    -- Clear and reload if needed
    if needs_reload then
        ClearIconCaches(toolbar)
    end
    
    return needs_reload
end

-- Display toolbar widget for a specific toolbar
function DisplayToolbarWidget(toolbar)
    -- Validate context and resources
    if not toolbar.context or not r.ImGui_ValidatePtr(toolbar.context, "ImGui_Context*") then
        toolbar.context = r.ImGui_CreateContext('Toolbar_' .. toolbar.id)
        toolbar.font = nil
        toolbar.font_needs_update = true
        ClearIconCaches(toolbar)
    end
    
    -- Validate and refresh icons if needed
    ValidateToolbarResources(toolbar)
    
    -- if toolbar.font_needs_update then
    --     InitFont(toolbar)
    -- end

    if not toolbar.context then
        return false
    end
    
    -- Variables to track global style pushes
    local global_pushed_colors = 0
    local global_pushed_vars = 0
    
    -- Apply global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(toolbar.context)
        if success then
            global_pushed_colors, global_pushed_vars = colors, vars
        end
    end
    
    -- Specific flags for the main toolbar
    local toolbar_flags = r.ImGui_WindowFlags_NoScrollbar() |
                         r.ImGui_WindowFlags_AlwaysAutoResize() |
                         r.ImGui_WindowFlags_NoTitleBar() |
                         r.ImGui_WindowFlags_NoFocusOnAppearing() |
                         r.ImGui_WindowFlags_NoDocking() |
                         r.ImGui_WindowFlags_NoSavedSettings()
    
    -- Add NoBackground flag if background is disabled
    if not toolbar.show_background then
        toolbar_flags = toolbar_flags | r.ImGui_WindowFlags_NoBackground()
    end
    
    -- Get target window based on window_to_follow setting
    local target_hwnd = GetTargetWindow(toolbar)
    
    if target_hwnd then
        local retval, LEFT, TOP, RIGHT, BOT = r.JS_Window_GetRect(target_hwnd)
        if retval then
            -- Convert coordinates if necessary
            if r.APIExists("ImGui_PointConvertNative") then
                LEFT, TOP = r.ImGui_PointConvertNative(toolbar.context, LEFT, TOP)
                RIGHT, BOT = r.ImGui_PointConvertNative(toolbar.context, RIGHT, BOT)
            end
            
            -- Calculate position based on snap options
            local target_x, target_y
            
            if toolbar.snap_to == "topleft" or toolbar.snap_to == "left" then
                target_x = LEFT + toolbar.offset_x
                target_y = TOP + toolbar.offset_y
            elseif toolbar.snap_to == "topright" or toolbar.snap_to == "right" then
                target_x = RIGHT - toolbar.widget_width - toolbar.offset_x
                target_y = TOP + toolbar.offset_y
            elseif toolbar.snap_to == "bottomleft" or toolbar.snap_to == "up" then
                target_x = LEFT + toolbar.offset_x
                target_y = BOT - toolbar.widget_height - toolbar.offset_y
            elseif toolbar.snap_to == "bottomright" or toolbar.snap_to == "down" then
                target_x = RIGHT - toolbar.widget_width - toolbar.offset_x
                target_y = BOT - toolbar.widget_height - toolbar.offset_y
            else
                -- default à top left si non spécifié
                target_x = LEFT + toolbar.offset_x
                target_y = TOP + toolbar.offset_y
            end
            
            r.ImGui_SetNextWindowPos(toolbar.context, target_x, target_y)
            r.ImGui_SetNextWindowSize(toolbar.context, toolbar.widget_width, toolbar.widget_height)
            toolbar.first_position_set = true
        end
    else
        -- Custom position (fallback)
        if not toolbar.first_position_set or toolbar.force_position_update then
            local pos_x = toolbar.last_pos_x or 100
            local pos_y = toolbar.last_pos_y or 100
            r.ImGui_SetNextWindowPos(toolbar.context, pos_x, pos_y)
            r.ImGui_SetNextWindowSize(toolbar.context, toolbar.widget_width, toolbar.widget_height)
            toolbar.first_position_set = true
            toolbar.force_position_update = false
        end
    end
    
    -- Apply styling
    local styles_pushed = SetStyle(toolbar, toolbar.context)
    
    -- Push font with safety check
    local font_pushed = false
    if toolbar.font and r.ImGui_ValidatePtr(toolbar.font, "ImGui_Font*") then
        r.ImGui_PushFont(toolbar.context, toolbar.font)
        font_pushed = true
    end
    
    -- Start the window with the toolbar's name
    local visible, open = r.ImGui_Begin(toolbar.context, 'Toolbar: ' .. toolbar.name, true, toolbar_flags)
    
    if visible then
        DisplayToolbar(toolbar, toolbar.context)
        
        -- Save position if in custom mode (not snapped to any edge)
        if not toolbar.window_to_follow or toolbar.window_to_follow == "custom" then
            local window_pos_x, window_pos_y = r.ImGui_GetWindowPos(toolbar.context)
            if window_pos_x ~= toolbar.last_pos_x or window_pos_y ~= toolbar.last_pos_y then
                toolbar.last_pos_x = window_pos_x
                toolbar.last_pos_y = window_pos_y
            end
        end
        
        -- Change right-click behavior to toggle toolbar manager
        if r.ImGui_IsWindowHovered(toolbar.context) and r.ImGui_IsMouseClicked(toolbar.context, 1) and not r.ImGui_IsAnyItemHovered(toolbar.context) then
            show_toolbar_manager = true
            current_toolbar_index = GetToolbarIndexById(toolbar.id)
        end
        
        r.ImGui_End(toolbar.context)
    end
    
    -- Clean up
    if font_pushed then
        r.ImGui_PopFont(toolbar.context)
    end
    
    if styles_pushed then
        r.ImGui_PopStyleVar(toolbar.context, 7)
        r.ImGui_PopStyleColor(toolbar.context, 6)
    end
    
    -- Clean up global styles
    if style_loader then
        style_loader.clearStyles(toolbar.context, global_pushed_colors, global_pushed_vars)
    end
    
    return open
end

-- Preset management functions
function SavePreset(name)
    -- Create a copy of all current toolbars without runtime elements
    local toolbars_copy = {}
    for i, tb in ipairs(toolbars) do
        local tb_copy = shallow_copy(tb)
        tb_copy.context = nil
        tb_copy.font = nil
        tb_copy.font_needs_update = nil
        tb_copy.force_position_update = nil
        tb_copy.first_position_set = nil
        tb_copy.icons = {}
        tb_copy.reaper_icon_states = {}
        
        toolbars_copy[i] = tb_copy
    end
    
    -- Save the preset
    r.SetExtState(extname_base .. "_PRESET_" .. name, "toolbars", r.serialize(toolbars_copy), true)
    
    -- Save preset list if it's a new preset
    if not presets[name] then
        presets[name] = true
        
        -- Save updated preset list
        local preset_list = {}
        for preset_name in pairs(presets) do
            table.insert(preset_list, preset_name)
        end
        
        r.SetExtState(extname_base, "preset_list", r.serialize(preset_list), true)
    end
    
    -- Update current preset
    current_preset = name
    r.SetExtState(extname_base, "current_preset", name, true)
end

function LoadPreset(name)
    -- Load the preset data
    local preset_data = r.GetExtState(extname_base .. "_PRESET_" .. name, "toolbars")
    if preset_data == "" then
        return false
    end
    
    -- Parse the preset data
    local success, loaded_toolbars = pcall(function() return load("return " .. preset_data)() end)
    if not success or not loaded_toolbars or #loaded_toolbars == 0 then
        return false
    end
    
    -- Apply preset data to current toolbars
    for i, tb_data in ipairs(loaded_toolbars) do
        if i <= #toolbars then
            -- Update existing toolbar
            local tb = toolbars[i]
            
            -- Preserve the ID and runtime state
            local id = tb.id
            local context = tb.context
            local font = tb.font
            
            -- Copy all settings from preset
            for k, v in pairs(tb_data) do
                if k ~= "id" and k ~= "context" and k ~= "font" then
                    tb[k] = v
                end
            end
            
            -- Restore ID and runtime state
            tb.id = id
            tb.context = context
            tb.font = font
            tb.font_needs_update = true
            tb.force_position_update = true
            tb.first_position_set = false
            tb.icons = {}
            tb.reaper_icon_states = {}
        else
            -- Create new toolbar if the preset has more toolbars
            local new_tb = shallow_copy(tb_data)
            new_tb.id = "toolbar_" .. os.time() .. "_" .. math.random(1000, 9999)
            new_tb.context = nil
            new_tb.font = nil
            new_tb.font_needs_update = true
            new_tb.force_position_update = true
            new_tb.first_position_set = false
            new_tb.icons = {}
            new_tb.reaper_icon_states = {}
            
            table.insert(toolbars, new_tb)
            
            -- Create REAPER action for the new toolbar
            CreateToolbarAction(new_tb)
        end
    end
    
    -- Update current preset
    current_preset = name
    r.SetExtState(extname_base, "current_preset", name, true)
    
    return true
end

function LoadPresets()
    -- Load preset list
    local preset_list_data = r.GetExtState(extname_base, "preset_list")
    if preset_list_data ~= "" then
        local success, preset_list = pcall(function() return load("return " .. preset_list_data)() end)
        if success and preset_list then
            presets = {}
            for _, name in ipairs(preset_list) do
                presets[name] = true
            end
        end
    end
    
    -- Ensure default preset exists
    if not presets["default"] then
        presets["default"] = true
        SavePreset("default")
    end
end

-- Import actions from a file for a toolbar
function ImportActionsFromFile(toolbar)
    if not r.APIExists("JS_Dialog_BrowseForOpenFiles") then
        r.ShowMessageBox("The js_ReaScriptAPI extension is required for file import.", "Error", 0)
        return
    end
    
    local ret, filename = r.JS_Dialog_BrowseForOpenFiles("Import Actions", "", "", "REAPER Menu Files (*.ReaperMenu)\0*.ReaperMenu\0JSON Files (*.json)\0*.json\0All Files\0*.*\0", false)
    
    if ret and filename ~= "" then
        local file = io.open(filename, "r")
        if file then
            -- Check file extension to determine format
            if filename:match("%.ReaperMenu$") then
                -- Process ReaperMenu format
                local icons = {}
                local actions = {}
                local content = file:read("*all")
                file:close()
                
                -- Parse ReaperMenu file
                for line in content:gmatch("[^\r\n]+") do
                    -- Extract icon definitions
                    local icon_index, icon_file = line:match("icon_(%d+)=([^\r\n]+)")
                    if icon_index and icon_file then
                        icons[tonumber(icon_index)] = icon_file
                    end
                    
                    -- Extract action definitions
                    local item_index, command_info = line:match("item_(%d+)=([^\r\n]+)")
                    if item_index and command_info then
                        local idx = tonumber(item_index)
                        
                        -- Check if it's a separator (standard format is "-1")
                        if command_info == "-1" or command_info == "" or command_info == "0" or command_info == "0 " then
                            actions[idx] = {
                                is_separator = true,
                                width = 10 -- Default separator width
                            }
                        else
                            local command_id, command_name = command_info:match("(%S+)%s+(.*)")
                            
                            if command_id then
                                -- If it's a numeric command
                                if command_id:match("^%d+$") then
                                    actions[idx] = {
                                        command_id = tonumber(command_id),
                                        name = command_name,
                                        label = command_name:match("[^:]+$") or command_name,
                                        icon = icons[idx] or ""
                                    }
                                else
                                    -- If it's a script or named command
                                    actions[idx] = {
                                        command_id = command_id,
                                        name = command_name,
                                        label = command_name:match("[^:]+$") or command_name,
                                        icon = icons[idx] or ""
                                    }
                                end
                            end
                        end
                    end
                end
                
                -- Convert to sequential array
                local imported_actions = {}
                for i = 0, 100 do -- Use a reasonable upper limit for action indexes
                    if actions[i] then
                        table.insert(imported_actions, actions[i])
                    end
                end
                
                if #imported_actions > 0 then
                    -- Ask if user wants to replace or append
                    local replace = r.ShowMessageBox("Do you want to replace the current actions or append the imported ones?", 
                                                "Import Actions", 1) == 1
                    
                    if replace then
                        toolbar.actions = imported_actions
                    else
                        -- Append the imported actions
                        for _, action in ipairs(imported_actions) do
                            table.insert(toolbar.actions, action)
                        end
                    end
                    ClearIconCaches(toolbar)
                    r.ShowConsoleMsg("Actions imported successfully from ReaperMenu: " .. filename .. "\n")
                else
                    r.ShowMessageBox("No actions found in the imported ReaperMenu file.", "Error", 0)
                end
            else
                -- Process JSON format
                local content = file:read("*all")
                file:close()
                
                local success, imported_actions = pcall(function() return load("return " .. content)() end)
                if success and type(imported_actions) == 'table' then
                    if #imported_actions > 0 then
                        -- Ask if user wants to replace or append
                        local replace = r.ShowMessageBox("Do you want to replace the current actions or append the imported ones?", 
                                                    "Import Actions", 1) == 1
                        
                        if replace then
                            toolbar.actions = imported_actions
                        else
                            -- Append the imported actions
                            for _, action in ipairs(imported_actions) do
                                table.insert(toolbar.actions, action)
                            end
                        end
                        ClearIconCaches(toolbar)
                        r.ShowConsoleMsg("Actions imported successfully from: " .. filename .. "\n")
                    else
                        r.ShowMessageBox("No actions found in the imported file.", "Error", 0)
                    end
                else
                    r.ShowMessageBox("Failed to parse the imported file.", "Error", 0)
                end
            end
        else
            r.ShowMessageBox("Failed to open file: " .. filename, "Error", 0)
        end
    end
end

-- Export actions from a toolbar to a file
function ExportActionsToFile(toolbar)
    if not r.APIExists("JS_Dialog_BrowseForSaveFile") then
        r.ShowMessageBox("The js_ReaScriptAPI extension is required for file export.", "Error", 0)
        return
    end
    
    local ret, filename = r.JS_Dialog_BrowseForSaveFile("Export Actions", "", "Actions.json", "JSON Files (*.json)\0*.json\0All Files\0*.*\0")
    
    if ret and filename ~= "" then
        -- Add .json extension if missing
        if not filename:match("%.json$") then
            filename = filename .. ".json"
        end
        
        -- Create JSON for actions
        local json = r.serialize(toolbar.actions)
        
        -- Write to file
        local file = io.open(filename, "w")
        if file then
            file:write(json)
            file:close()
            r.ShowConsoleMsg("Actions exported successfully to: " .. filename .. "\n")
        else
            r.ShowMessageBox("Failed to write to file: " .. filename, "Error", 0)
        end
    end
end

-- Show toolbar manager dialog
function ShowToolbarManager()
    -- Ensure we have a valid context
    if not InitMainFont() then
        r.ShowMessageBox("Failed to initialize ImGui context for toolbar manager.", "Error", 0)
        show_toolbar_manager = false
        return false
    end
    
    -- Variables to track global style pushes
    local global_pushed_colors = 0
    local global_pushed_vars = 0
    
    -- Apply global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(main_ctx)
        if success then
            global_pushed_colors, global_pushed_vars = colors, vars
        end
    end
    
    -- Only try to use font if it exists
    local font_pushed = false
    if main_font and r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
        r.ImGui_PushFont(main_ctx, main_font)
        font_pushed = true
    end
    
    -- Set initial position
    r.ImGui_SetNextWindowPos(main_ctx, 200, 200, r.ImGui_Cond_FirstUseEver())
    r.ImGui_SetNextWindowSize(main_ctx, 800, 600, r.ImGui_Cond_FirstUseEver())
    
    local manager_flags = r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(main_ctx, 'Toolbar Manager', true, manager_flags)
    
    -- Handle close button (X) - This is the fix to ensure it saves when closed
    if not open then
        SaveToolbars()
        show_toolbar_manager = false
    end
    
    if visible then
        -- Preset management section
        r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_ChildBg(), 0x303030FF)
        -- Create appropriate border flag
        local child_flags = 0
        if r.ImGui_WindowFlags_Border then -- Only if function exists
            child_flags = r.ImGui_WindowFlags_Border()
        end
        
        if r.ImGui_BeginChild(main_ctx, "preset_section", -1, 60, child_flags) then
            r.ImGui_Text(main_ctx, "Preset:")
            
            -- Preset dropdown
            r.ImGui_SetNextItemWidth(main_ctx, 200)
            if r.ImGui_BeginCombo(main_ctx, "##preset_selector", current_preset) then
                -- List all available presets
                for preset_name in pairs(presets) do
                    local is_selected = (preset_name == current_preset)
                    if r.ImGui_Selectable(main_ctx, preset_name, is_selected) then
                        -- Load the selected preset
                        if LoadPreset(preset_name) then
                            current_preset = preset_name
                        end
                    end
                end
                r.ImGui_EndCombo(main_ctx)
            end
            
            r.ImGui_SameLine(main_ctx)
            
            -- Save preset button
            if r.ImGui_Button(main_ctx, "Save", 80, 22) then
                SavePreset(current_preset)
            end
            
            r.ImGui_SameLine(main_ctx)
            
            -- Save As... button
            if r.ImGui_Button(main_ctx, "Save As...", 100, 22) then
                local retval, new_name = r.GetUserInputs("Save Preset As", 1, "Preset Name:,extrawidth=100", "")
                if retval and new_name ~= "" then
                    SavePreset(new_name)
                end
            end
            
            r.ImGui_SameLine(main_ctx)
            
            -- Reset to saved button
            if r.ImGui_Button(main_ctx, "Reset", 80, 22) then
                LoadPreset(current_preset)
            end
            
            r.ImGui_SameLine(main_ctx)

            -- Close button with equal spacing
            if r.ImGui_Button(main_ctx, "Close", 80, 22) then
                SaveToolbars()
                show_toolbar_manager = false
            end

            r.ImGui_EndChild(main_ctx)
        end
        r.ImGui_PopStyleColor(main_ctx)
        
        r.ImGui_Separator(main_ctx)
        
        -- Toolbar selector and management section
        r.ImGui_Text(main_ctx, "Toolbars:")
        
        -- Toolbar list with Add and Remove buttons
        local child_visible = r.ImGui_BeginChild(main_ctx, "toolbars_list", -1, 150)
        
        if child_visible then
            for i, tb in ipairs(toolbars) do
                r.ImGui_PushID(main_ctx, i)
                
                -- Create a row for better layout control
                r.ImGui_BeginGroup(main_ctx)
                
                -- Enabled checkbox - draw this first, separately from the selectable
                local enabled_changed, is_enabled = r.ImGui_Checkbox(main_ctx, "##enabled" .. i, tb.is_enabled)
                if enabled_changed then
                    tb.is_enabled = is_enabled
                end
                
                -- Put name in a separate group
                r.ImGui_SameLine(main_ctx)
                
                -- Calculate width for the selectable (full width minus checkbox width)
                local content_width = r.ImGui_GetContentRegionAvail(main_ctx)
                
                -- Name with selection highlighting
                local is_selected = (i == current_toolbar_index)
                if is_selected then
                    r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Text(), 0xFFFF00FF)
                end
                
                -- Use selectable WITHOUT SpanAllColumns flag
                if r.ImGui_Selectable(main_ctx, tb.name, is_selected, 0, content_width) then
                    current_toolbar_index = i
                end
                
                if is_selected then
                    r.ImGui_PopStyleColor(main_ctx)
                end
                
                r.ImGui_EndGroup(main_ctx)
                r.ImGui_PopID(main_ctx)
            end
            
            r.ImGui_EndChild(main_ctx)  -- Important: This should only be called if BeginChild succeeded
        end
        
        -- Toolbar management buttons
        r.ImGui_BeginGroup(main_ctx)
        
        if r.ImGui_Button(main_ctx, "Add Toolbar", 100, 24) then
            local retval, name = r.GetUserInputs("New Toolbar", 1, "Toolbar Name:,extrawidth=100", "New Toolbar")
            if retval and name ~= "" then
                CreateNewToolbar(name)
                current_toolbar_index = #toolbars
            end
        end
        
        r.ImGui_SameLine(main_ctx)
        
        if r.ImGui_Button(main_ctx, "Rename", 100, 24) and current_toolbar_index <= #toolbars then
            local tb = toolbars[current_toolbar_index]
            local retval, name = r.GetUserInputs("Rename Toolbar", 1, "Toolbar Name:,extrawidth=100", tb.name)
            if retval and name ~= "" then
                tb.name = name
                
                -- Update action for renamed toolbar
                CreateToolbarAction(tb)
            end
        end
        
        r.ImGui_SameLine(main_ctx)
        
        r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Button(), 0xB34C4CFF) -- Red for remove
        local can_remove = #toolbars > 1 and current_toolbar_index <= #toolbars
        if not can_remove then
            r.ImGui_BeginDisabled(main_ctx)
        end
        
        if r.ImGui_Button(main_ctx, "Remove", 100, 24) and can_remove then
            local result = r.ShowMessageBox("Are you sure you want to remove this toolbar?", "Confirm Removal", 4)
            if result == 6 then -- Yes
                table.remove(toolbars, current_toolbar_index)
                if current_toolbar_index > #toolbars then
                    current_toolbar_index = #toolbars
                end
            end
        end
        
        if not can_remove then
            r.ImGui_EndDisabled(main_ctx)
        end
        r.ImGui_PopStyleColor(main_ctx)
        
        r.ImGui_SameLine(main_ctx)
        
        if r.ImGui_Button(main_ctx, "Duplicate", 100, 24) and current_toolbar_index <= #toolbars then
            local tb = toolbars[current_toolbar_index]
            local new_tb = shallow_copy(tb)
            new_tb.id = "toolbar_" .. os.time() .. "_" .. math.random(1000, 9999)
            new_tb.name = tb.name .. " (Copy)"
            new_tb.context = nil -- Will be created on first use
            new_tb.font = nil
            new_tb.font_needs_update = true
            new_tb.force_position_update = true
            new_tb.first_position_set = false
            new_tb.icons = {}
            new_tb.reaper_icon_states = {}
            
            table.insert(toolbars, new_tb)
            current_toolbar_index = #toolbars
            
            -- Create action for the new toolbar
            CreateToolbarAction(new_tb)
        end
        
        r.ImGui_SameLine(main_ctx)

        if r.ImGui_Button(main_ctx, "Create Actions", 100, 24) and current_toolbar_index <= #toolbars then
            local tb = toolbars[current_toolbar_index]
            local result = CreateToolbarAction(tb)
    
            if result.success then
                r.ShowMessageBox("REAPER actions created successfully:\n- CP_CustomToolbars_" .. tb.name .. "_On\n- CP_CustomToolbars_" .. tb.name .. "_Off", "Success", 0)
            else
                if result.on_id ~= 0 and result.off_id ~= 0 then
                    -- Actions exist but there was a problem
                    r.ShowMessageBox("Actions exist but there was an issue with creation process.", "Partial Success", 0)
                else
                    r.ShowMessageBox("Failed to create one or both actions.", "Error", 0)
                end
            end
        end

        r.ImGui_EndGroup(main_ctx)
        
        r.ImGui_Separator(main_ctx)
        
        -- Toolbar settings editor for the selected toolbar
        if current_toolbar_index <= #toolbars then
            local tb = toolbars[current_toolbar_index]
            
            -- Position Settings - No close button on header
            if r.ImGui_CollapsingHeader(main_ctx, "Position Settings") then
                local rv, changed
                
                -- SECTION: Follow Window
                r.ImGui_Text(main_ctx, "Follow Window:")
                
                -- Transport
                local is_transport = tb.window_to_follow == "transport" 
                rv = r.ImGui_RadioButton(main_ctx, "Transport", is_transport)
                if rv and not is_transport then
                    tb.window_to_follow = "transport"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_SameLine(main_ctx)
                
                -- Mixer
                local is_mixer = tb.window_to_follow == "mixer"
                rv = r.ImGui_RadioButton(main_ctx, "Mixer", is_mixer)
                if rv and not is_mixer then
                    tb.window_to_follow = "mixer"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_SameLine(main_ctx)
                
                -- Media Explorer
                local is_media = tb.window_to_follow == "media_explorer"
                rv = r.ImGui_RadioButton(main_ctx, "Media Explorer", is_media)
                if rv and not is_media then
                    tb.window_to_follow = "media_explorer"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_Spacing(main_ctx)
                
                -- Ruler
                local is_ruler = tb.window_to_follow == "ruler"
                rv = r.ImGui_RadioButton(main_ctx, "Ruler", is_ruler)
                if rv and not is_ruler then
                    tb.window_to_follow = "ruler"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_SameLine(main_ctx)
                
                -- Arrange
                local is_arrange = tb.window_to_follow == "arrange"
                rv = r.ImGui_RadioButton(main_ctx, "Arrange", is_arrange)
                if rv and not is_arrange then
                    tb.window_to_follow = "arrange"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_SameLine(main_ctx)
                
                -- Main (default)
                local is_main = tb.window_to_follow == "main"
                rv = r.ImGui_RadioButton(main_ctx, "Main Window", is_main)
                if rv and not is_main then
                    tb.window_to_follow = "main"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_Spacing(main_ctx)
                
                -- Docker (NOUVELLE OPTION)
                local is_docker = tb.window_to_follow == "docker"
                rv = r.ImGui_RadioButton(main_ctx, "Docker", is_docker)
                if rv and not is_docker then
                    tb.window_to_follow = "docker"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                -- Docker ID (seulement si Docker est sélectionné)
                if tb.window_to_follow == "docker" then
                    r.ImGui_SameLine(main_ctx)
                    r.ImGui_SetNextItemWidth(main_ctx, 120)
                    local docker_id_changed, new_docker_id = r.ImGui_InputInt(main_ctx, "Docker ID", tb.docker_id or 0)
                    if docker_id_changed then
                        tb.docker_id = new_docker_id
                        tb.force_position_update = true
                    end
                end
                
                -- SECTION SÉPARÉE : Snap To 
                r.ImGui_Spacing(main_ctx)
                r.ImGui_Text(main_ctx, "Snap To:")

                -- Top Left
                local is_topleft = tb.snap_to == "topleft"
                rv = r.ImGui_RadioButton(main_ctx, "Top Left", is_topleft)
                if rv and not is_topleft then
                    tb.snap_to = "topleft"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end

                r.ImGui_SameLine(main_ctx)

                -- Top Right
                local is_topright = tb.snap_to == "topright"
                rv = r.ImGui_RadioButton(main_ctx, "Top Right", is_topright)
                if rv and not is_topright then
                    tb.snap_to = "topright"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end

                r.ImGui_SameLine(main_ctx)

                -- Bottom Left
                local is_bottomleft = tb.snap_to == "bottomleft"
                rv = r.ImGui_RadioButton(main_ctx, "Bottom Left", is_bottomleft)
                if rv and not is_bottomleft then
                    tb.snap_to = "bottomleft"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end

                r.ImGui_SameLine(main_ctx)

                -- Bottom Right
                local is_bottomright = tb.snap_to == "bottomright"
                rv = r.ImGui_RadioButton(main_ctx, "Bottom Right", is_bottomright)
                if rv and not is_bottomright then
                    tb.snap_to = "bottomright"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_Spacing(main_ctx)
                rv, changed = r.ImGui_Checkbox(main_ctx, "Use responsive layout (wrap buttons)", tb.use_responsive_layout)
                if rv and changed ~= tb.use_responsive_layout then
                    tb.use_responsive_layout = changed
                end

                r.ImGui_Spacing(main_ctx)
                
                -- Position Offsets (reste inchangé)
                r.ImGui_Text(main_ctx, "Position Offsets:")
                rv, changed = r.ImGui_SliderDouble(main_ctx, "X Offset", tb.offset_x, 0.0, 1000.0, "%.2f")
                if rv and changed ~= tb.offset_x then
                    tb.offset_x = changed
                    tb.force_position_update = true
                end
                
                rv, changed = r.ImGui_SliderDouble(main_ctx, "Y Offset", tb.offset_y, 0.0, 100.0, "%.2f")
                if rv and changed ~= tb.offset_y then
                    tb.offset_y = changed
                    tb.force_position_update = true
                end
                
                -- Widget dimensions (reste inchangé)
                r.ImGui_Text(main_ctx, "Widget dimensions:")
                rv, changed = r.ImGui_SliderInt(main_ctx, "Width", math.floor(tb.widget_width), 20, 1000)
                if rv and changed ~= tb.widget_width then
                    tb.widget_width = changed
                    tb.force_position_update = true
                end
                
                rv, changed = r.ImGui_SliderInt(main_ctx, "Height", math.floor(tb.widget_height), 14, 400)
                if rv and changed ~= tb.widget_height then
                    tb.widget_height = changed
                    tb.force_position_update = true
                end
                
                r.ImGui_Spacing(main_ctx)
                r.ImGui_Text(main_ctx, "Auto-hide settings:")
                
                rv, changed = r.ImGui_Checkbox(main_ctx, "Enable auto-hide", tb.auto_hide)
                if rv and changed ~= tb.auto_hide then
                    tb.auto_hide = changed
                end
                
                r.ImGui_SetNextItemWidth(main_ctx, 200)
                rv, changed = r.ImGui_SliderInt(main_ctx, "Min window width for auto-hide", tb.min_window_width, 500, 3000)
                if rv and changed ~= tb.min_window_width then
                    tb.min_window_width = changed
                end
                
                r.ImGui_SetNextItemWidth(main_ctx, 200)
                rv, changed = r.ImGui_SliderInt(main_ctx, "Min window height for auto-hide", tb.min_window_height, 100, 2000)
                if rv and changed ~= tb.min_window_height then
                    tb.min_window_height = changed
                end
            end
            
            -- Appearance Settings
            if r.ImGui_CollapsingHeader(main_ctx, "Appearance Settings") then
                local rv, changed
                
                -- Show background option
                rv, changed = r.ImGui_Checkbox(main_ctx, "Show background", tb.show_background)
                if rv and changed ~= tb.show_background then
                    tb.show_background = changed
                    tb.force_position_update = true
                end

                r.ImGui_Spacing(main_ctx)

                rv, tb.window_rounding = r.ImGui_SliderDouble(main_ctx, "Window Rounding", tb.window_rounding, 0, 20)
                rv, tb.frame_rounding = r.ImGui_SliderDouble(main_ctx, "Frame Rounding", tb.frame_rounding, 0, 20)
                rv, tb.border_size = r.ImGui_SliderDouble(main_ctx, "Border Size", tb.border_size, 0, 5)
                rv, tb.background_color = r.ImGui_ColorEdit4(main_ctx, "Background Color", tb.background_color)
                rv, tb.text_color = r.ImGui_ColorEdit4(main_ctx, "Text Color", tb.text_color)
                rv, tb.button_color = r.ImGui_ColorEdit4(main_ctx, "Button Color", tb.button_color)
                rv, tb.button_hover_color = r.ImGui_ColorEdit4(main_ctx, "Button Hover", tb.button_hover_color)
                rv, tb.button_active_color = r.ImGui_ColorEdit4(main_ctx, "Button Active", tb.button_active_color)
                rv, tb.border_color = r.ImGui_ColorEdit4(main_ctx, "Border Color", tb.border_color)
                
                r.ImGui_Text(main_ctx, "Font Settings:")
                r.ImGui_SetNextItemWidth(main_ctx, 150)
                local font_changed
                font_changed, tb.font_size = r.ImGui_SliderInt(main_ctx, "Font Size", tb.font_size, 8, 32)
                
                if font_changed then
                    tb.font_needs_update = true
                end
            end
            
            -- Button Settings
            if r.ImGui_CollapsingHeader(main_ctx, "Button Settings") then
                local rv, changed
                rv, tb.center_buttons = r.ImGui_Checkbox(main_ctx, "Center buttons", tb.center_buttons)
                
                rv, changed = r.ImGui_Checkbox(main_ctx, "Show icons", tb.show_icons)
                if rv and changed ~= tb.show_icons then
                    tb.show_icons = changed
                    ClearIconCaches(tb)
                end
                
                rv, changed = r.ImGui_Checkbox(main_ctx, "Use REAPER native icons", tb.use_reaper_icons)
                if rv and changed ~= tb.use_reaper_icons then
                    tb.use_reaper_icons = changed
                    ClearIconCaches(tb)
                end
                
                r.ImGui_SetNextItemWidth(main_ctx, 150)
                rv, tb.button_width = r.ImGui_SliderInt(main_ctx, "Button Width", tb.button_width, 20, 300)
                
                r.ImGui_SetNextItemWidth(main_ctx, 150)
                rv, tb.button_height = r.ImGui_SliderInt(main_ctx, "Button Height", tb.button_height, 16, 100)
                
                r.ImGui_SetNextItemWidth(main_ctx, 150)
                rv, tb.button_spacing = r.ImGui_SliderInt(main_ctx, "Button Spacing", tb.button_spacing, 0, 20)
                
                r.ImGui_SetNextItemWidth(main_ctx, 150)
                rv, tb.icon_size = r.ImGui_SliderInt(main_ctx, "Icon Size", tb.icon_size, 8, 96)
                
                rv, tb.preserve_icon_aspect_ratio = r.ImGui_Checkbox(main_ctx, "Preserve Icon Aspect Ratio", tb.preserve_icon_aspect_ratio)
                
                r.ImGui_SetNextItemWidth(main_ctx, 300)
                rv, changed = r.ImGui_InputText(main_ctx, "Custom Icon Path (folder only)", tb.icon_path or "", 256)
                if rv and changed ~= tb.icon_path then
                    tb.icon_path = changed
                    ClearIconCaches(tb)
                end
            end

-- Modification de la structure de la section Actions Management pour corriger l'erreur de PushID/PopID
            if r.ImGui_CollapsingHeader(main_ctx, "Actions Management") then
                -- Import/Export buttons
                r.ImGui_Text(main_ctx, "Action List Management:")
                
                r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Button(), 0x4C72B3FF) -- Blue button
                if r.ImGui_Button(main_ctx, "Export Actions") then
                    ExportActionsToFile(tb)
                end
                
                r.ImGui_SameLine(main_ctx)
                
                r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Button(), 0x72B34CFF) -- Green button
                if r.ImGui_Button(main_ctx, "Import Actions") then
                    ImportActionsFromFile(tb)
                end
                r.ImGui_PopStyleColor(main_ctx, 2)
                
                r.ImGui_Separator(main_ctx)
                
                -- Actions title row with Add button and Add Separator button
                r.ImGui_BeginGroup(main_ctx)
                r.ImGui_Text(main_ctx, "Actions:")
                r.ImGui_SameLine(main_ctx)
                
                r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Button(), 0x4C72B3FF) -- Blue button for Add
                if r.ImGui_Button(main_ctx, "Add Action") then
                    local retval, retvals = r.GetUserInputs("Add Action", 1, "Command ID or Name:,extrawidth=100", "")
                    if retval and retvals ~= "" then
                        local command_id = tonumber(retvals)
                        if command_id then
                            -- Numeric command ID, get name from REAPER
                            local name = GetCommandName(command_id)
                            table.insert(tb.actions, {
                                command_id = command_id,
                                name = name ~= "" and name or "Command ID: " .. command_id,
                                label = name ~= "" and name:match("[^:]+$") or "Action " .. (#tb.actions + 1),
                                icon = ""
                            })
                        else
                            -- Try as a named command (string ID)
                            local cmdId = r.NamedCommandLookup(retvals)
                            if cmdId and cmdId ~= 0 then
                                -- Valid named command
                                local name = GetCommandName(cmdId)
                                table.insert(tb.actions, {
                                    command_id = retvals,
                                    name = name ~= "" and name or "Command: " .. retvals,
                                    label = name ~= "" and name:match("[^:]+$") or retvals,
                                    icon = ""
                                })
                            else
                                -- Not a valid command, use as-is
                                table.insert(tb.actions, {
                                    command_id = retvals,
                                    name = "Command: " .. retvals,
                                    label = "Action " .. (#tb.actions + 1),
                                    icon = ""
                                })
                            end
                        end
                    end
                end
                
                r.ImGui_SameLine(main_ctx)
                r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Button(), 0x72B34CFF) -- Green button for separator
                if r.ImGui_Button(main_ctx, "Add Separator") then
                    table.insert(tb.actions, {
                        is_separator = true,
                        width = 10 -- Default separator width
                    })
                end
                r.ImGui_PopStyleColor(main_ctx, 2) -- Pop both button colors
                r.ImGui_EndGroup(main_ctx)
                
                -- Display and edit current actions
                if #tb.actions > 0 then
                    local item_to_remove = nil 
                    local item_to_move_up = nil
                    local item_to_move_down = nil
                    
                    -- NOTE: Au lieu de BeginChild/EndChild, nous utilisons juste un groupe
                    r.ImGui_BeginGroup(main_ctx)
                    
                    for i, action in ipairs(tb.actions) do
                        r.ImGui_PushID(main_ctx, i)
                        
                        -- Add spacing between items
                        if i > 1 then 
                            r.ImGui_Spacing(main_ctx)
                            r.ImGui_Spacing(main_ctx)
                        end
                        
                        -- Special handling for separators
                        if action.is_separator then
                            r.ImGui_Text(main_ctx, i .. ": Separator")
                            r.ImGui_Spacing(main_ctx)
                            
                            r.ImGui_Text(main_ctx, "Width:")
                            r.ImGui_SameLine(main_ctx, 100)
                            r.ImGui_SetNextItemWidth(main_ctx, 280)
                            local width_changed, new_width = r.ImGui_SliderInt(main_ctx, "##width" .. i, action.width or 10, 1, 100)
                            if width_changed then
                                action.width = new_width
                            end
                            
                            -- Action controls for separator
                            r.ImGui_Spacing(main_ctx)
                            r.ImGui_BeginGroup(main_ctx)
                            if r.ImGui_Button(main_ctx, "Up##up" .. i, 50, 22) and i > 1 then
                                item_to_move_up = i
                            end
                            
                            r.ImGui_SameLine(main_ctx, 0, 8)
                            if r.ImGui_Button(main_ctx, "Down##down" .. i, 50, 22) and i < #tb.actions then
                                item_to_move_down = i
                            end
                            
                            r.ImGui_SameLine(main_ctx, 0, 8)
                            r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Button(), 0xB34C4CFF) -- Red for remove
                            if r.ImGui_Button(main_ctx, "Remove##" .. i, 70, 22) then
                                item_to_remove = i
                            end
                            r.ImGui_PopStyleColor(main_ctx)
                            r.ImGui_EndGroup(main_ctx)
                            
                            r.ImGui_Separator(main_ctx)
                            r.ImGui_PopID(main_ctx)
                            goto continue
                        end
                        
                        -- Title and action name
                        r.ImGui_BeginGroup(main_ctx)
                        local title_text = i .. ": " .. (action.name or "Unknown")
                        r.ImGui_Text(main_ctx, title_text)
                        r.ImGui_EndGroup(main_ctx)
                        
                        -- Command ID field (on its own line)
                        r.ImGui_Text(main_ctx, "Command ID:")
                        r.ImGui_SameLine(main_ctx, 100)
                        local cmd_text = type(action.command_id) == "number" and tostring(action.command_id) or action.command_id or ""
                        r.ImGui_SetNextItemWidth(main_ctx, 280)
                        local cmd_changed, new_cmd = r.ImGui_InputText(main_ctx, "##cmd" .. i, cmd_text, 64)
                        
                        if cmd_changed then
                            local num_cmd = tonumber(new_cmd)
                            if num_cmd then
                                action.command_id = num_cmd
                                local name = GetCommandName(num_cmd)
                                if name ~= "" then 
                                    action.name = name
                                end
                            else
                                action.command_id = new_cmd
                                local cmdId = r.NamedCommandLookup(new_cmd)
                                if cmdId and cmdId ~= 0 then
                                    local name = GetCommandName(cmdId)
                                    if name ~= "" then
                                        action.name = name
                                    end
                                end
                            end
                        end
                        
                        -- Label field (on its own line)
                        r.ImGui_Text(main_ctx, "Label:")
                        r.ImGui_SameLine(main_ctx, 100)
                        r.ImGui_SetNextItemWidth(main_ctx, 280)
                        local label_changed, new_label = r.ImGui_InputText(main_ctx, "##label" .. i, action.label or "", 64)
                        if label_changed then
                            action.label = new_label
                        end
                        
                        -- Icon field and Browse button (on their own line)
                        r.ImGui_Text(main_ctx, "Icon:")
                        r.ImGui_SameLine(main_ctx, 100)
                        r.ImGui_SetNextItemWidth(main_ctx, 280)
                        local icon_changed, new_icon = r.ImGui_InputText(main_ctx, "##icon" .. i, action.icon or "", 64)
                        if icon_changed then
                            action.icon = new_icon
                            tb.icons[action.icon] = nil
                            tb.reaper_icon_states[action.icon] = nil
                        end
                        
                        r.ImGui_SameLine(main_ctx, 390)

                        -- Use custom icon browser instead of file dialog
                        if r.ImGui_Button(main_ctx, "Browse...##" .. i, 80, 22) then
                            r.ImGui_OpenPopup(main_ctx, "Icon Browser")
                            current_editing_action_index = i
                        end
                        
                        -- Show icon preview if available
                        if action.icon and action.icon ~= "" then
                            r.ImGui_SameLine(main_ctx, 480)
                            local icon_texture = nil
                            local normal_state = nil
                            
                            if tb.use_reaper_icons then
                                normal_state = select(1, LoadReaperIconStates(tb, action.icon))
                            end
                            
                            if normal_state and normal_state.texture then
                                if normal_state.uv then
                                    r.ImGui_Image(main_ctx, normal_state.texture, 24, 24, 
                                            normal_state.uv[1], normal_state.uv[2], 
                                            normal_state.uv[3], normal_state.uv[4])
                                else
                                    r.ImGui_Image(main_ctx, normal_state.texture, 24, 24)
                                end
                            else
                                icon_texture = LoadIcon(tb, action.icon)
                                if icon_texture then
                                    r.ImGui_Image(main_ctx, icon_texture, 24, 24)
                                else
                                    r.ImGui_Text(main_ctx, "(Icon not found)")
                                end
                            end
                        end
                        
                        -- Process the icon browser popup if open
                        if current_editing_action_index == i then
                            BrowseIconsDialog(tb, i)
                        end
                            
                        -- Action controls (on their own line)
                        r.ImGui_Spacing(main_ctx)
                        r.ImGui_BeginGroup(main_ctx)
                        if r.ImGui_Button(main_ctx, "Up##up" .. i, 50, 22) and i > 1 then
                            item_to_move_up = i
                        end
                        
                        r.ImGui_SameLine(main_ctx, 0, 8)
                        if r.ImGui_Button(main_ctx, "Down##down" .. i, 50, 22) and i < #tb.actions then
                            item_to_move_down = i
                        end
                        
                        r.ImGui_SameLine(main_ctx, 0, 8)
                        r.ImGui_PushStyleColor(main_ctx, r.ImGui_Col_Button(), 0xB34C4CFF) -- Red for remove
                        if r.ImGui_Button(main_ctx, "Remove##" .. i, 70, 22) then
                            item_to_remove = i
                        end
                        r.ImGui_PopStyleColor(main_ctx)
                        r.ImGui_EndGroup(main_ctx)
                        
                        r.ImGui_Separator(main_ctx)
                        r.ImGui_PopID(main_ctx)
                        
                        ::continue::
                    end
                    
                    r.ImGui_EndGroup(main_ctx)
                    
                    -- Process move/remove operations after the loop
                    if item_to_remove then
                        table.remove(tb.actions, item_to_remove)
                    end
                    
                    if item_to_move_up then
                        local temp = tb.actions[item_to_move_up]
                        tb.actions[item_to_move_up] = tb.actions[item_to_move_up - 1]
                        tb.actions[item_to_move_up - 1] = temp
                    end
                    
                    if item_to_move_down then
                        local temp = tb.actions[item_to_move_down]
                        tb.actions[item_to_move_down] = tb.actions[item_to_move_down + 1]
                        tb.actions[item_to_move_down + 1] = temp
                    end
                else
                    r.ImGui_Text(main_ctx, "No actions added yet.")
                end
            end
        end
        
        r.ImGui_End(main_ctx)
    end
    
    if font_pushed then
        r.ImGui_PopFont(main_ctx)
    end
    
    -- Clean up global styles
    if style_loader then
        style_loader.clearStyles(main_ctx, global_pushed_colors, global_pushed_vars)
    end
    
    return open
end

-- Main loop
function MainLoop()
    -- Mettre à jour les polices avant de commencer les frames
    for i, tb in ipairs(toolbars) do
        if tb.is_enabled and tb.font_needs_update then
            InitFont(tb)
        end
    end
    
    -- Ensuite, vérifiez si les états des toolbars ont changé
    CheckToolbarToggleState()

    -- Check if we need to open the toolbar manager
    local open_manager = r.GetExtState(extname_base, "open_manager")
    if open_manager == "1" then
        show_toolbar_manager = true
        r.DeleteExtState(extname_base, "open_manager", false)
    end

    -- Process all active toolbars
    for i, tb in ipairs(toolbars) do
        if tb.is_enabled then
            -- Determine if the toolbar should be displayed
            local should_display = true
            
            -- Check window size for auto-hide feature
            if tb.auto_hide and not show_toolbar_manager then
                -- Obtenir la fenêtre cible en fonction de window_to_follow
                local target_hwnd = GetTargetWindow(tb)
                
                if target_hwnd then
                    local retval, left, top, right, bottom = r.JS_Window_GetRect(target_hwnd)
                    
                    if retval then
                        local window_width = right - left
                        local window_height = bottom - top
                        
                        if window_width < tb.min_window_width or window_height < tb.min_window_height then
                            should_display = false
                        end
                    end
                else
                    -- Si on ne peut pas obtenir la fenêtre cible, utiliser la fenêtre principale comme fallback
                    local main_hwnd = r.GetMainHwnd()
                    if main_hwnd then
                        local retval, main_LEFT, main_TOP, main_RIGHT, main_BOT = r.JS_Window_GetRect(main_hwnd)
                        
                        if retval then
                            local main_width = main_RIGHT - main_LEFT
                            local main_height = main_BOT - main_TOP
                            
                            if main_width < tb.min_window_width or main_height < tb.min_window_height then
                                should_display = false
                            end
                        end
                    end
                end
            end

            -- Assurez-vous que les toolbars sont toujours visibles quand le toolbar manager est ouvert
            if show_toolbar_manager then
                should_display = true
            end
            
            if should_display then
                DisplayToolbarWidget(tb)
            end
        end
    end
    
    -- Show toolbar manager when needed
    if show_toolbar_manager then
        if not ShowToolbarManager() then
            show_toolbar_manager = false
        end
    end
    
    r.defer(MainLoop)
end

-- Initialize
function Init()
    -- Create main context if needed
    if not main_ctx or not r.ImGui_ValidatePtr(main_ctx, "ImGui_Context*") then
        main_ctx = r.ImGui_CreateContext('Multi-Toolbar Manager')
        -- Reset font since context changed
        main_font = nil
    end
    
    -- Initialize main font
    InitMainFont()
    
    -- Apply global font styles if available
    if style_loader then
        style_loader.applyFontsToContext(main_ctx)
    end
    
    -- Indicate that the script is running
    r.SetExtState(extname_base, "running", "1", false)

    -- Load existing toolbars or create a default one
    LoadToolbars()
    
    -- Start the main loop
    MainLoop()
end

-- Start 
local _, _, section_id, command_id = r.get_action_context()
r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

function Exit()
    SaveToolbars()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)

    -- Indicate that the script is no longer running
    r.SetExtState(extname_base, "running", "0", false)
end

r.atexit(Exit)
Init()