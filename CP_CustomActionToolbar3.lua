-- @description Improved Custom Action Toolbar
-- @version 1.5
-- @author Claude
-- @about
--   Customizable toolbar for REAPER actions with native REAPER icon support

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local extname = "CP_CUSTOM_ACTION_TOOLBAR 3"

-- Default settings
local settings = {
    -- UI positioning
    overlay_enabled = true,
    rel_pos_x = 1170,
    rel_pos_y = 4,
    widget_width = 330,
    widget_height = 36,
    show_background = true,
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
    adaptive_width = 50.0,
    
    -- Settings dialog state
    settings_open = false,
    section_states = {
        position = true,
        appearance = false,
        buttons = false,
        actions = true,
        import_export = false
    }
}

-- Variable to store temporary settings for the settings dialog
local temp_settings = nil

-- Flag to force position update when settings change
local force_position_update = false

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

-- Create context
local ctx = r.ImGui_CreateContext('Custom Action Toolbar 3')
local first_position_set = false

-- Font management
local font = nil
local font_needs_update = false

local previous_transport_pos = {x = 0, y = 0, w = 0, h = 0}

local window_flags = r.ImGui_WindowFlags_NoScrollbar() |
                     r.ImGui_WindowFlags_AlwaysAutoResize() |
                     r.ImGui_WindowFlags_NoTitleBar() |
                     r.ImGui_WindowFlags_NoFocusOnAppearing() |
                     r.ImGui_WindowFlags_NoDocking() |
                     r.ImGui_WindowFlags_NoSavedSettings()

-- Set up font before first frame
function InitFont()
    local flags = 0
    if settings.use_high_dpi_font then
        flags = r.ImGui_FontFlags_None()
    else
        -- Try to match REAPER's font rendering more closely
        flags = r.ImGui_FontFlags_NoHinting() + r.ImGui_FontFlags_NoAutoHint()
    end
    
    -- Make sure we're using Verdana if that's what we want
    if settings.current_font:lower() ~= "verdana" and settings.current_font ~= "Tahoma" then
        settings.current_font = "Verdana"
    end
    
    -- Try to load the font from system
    font = r.ImGui_CreateFont(settings.current_font, settings.font_size, flags)
    
    r.ImGui_Attach(ctx, font)
end

-- Mark font for update on next restart
function SetFontNeedsUpdate()
    font_needs_update = true
end

-- Save/Load settings
function SaveSettings()
    local state = {}
    for k, v in pairs(settings) do
        if type(v) == "table" then
            state[k] = {}
            for i, item in ipairs(v) do
                state[k][i] = item
            end
        else
            state[k] = v
        end
    end
    
    r.SetExtState(extname, "settings", r.serialize(state), true)
end

function LoadSettings()
    local state_str = r.GetExtState(extname, "settings")
    if state_str ~= "" then
        local success, loaded_state = pcall(function() return load("return " .. state_str)() end)
        if success and loaded_state then
            for k, v in pairs(loaded_state) do
                settings[k] = v
            end
        end
    end
    
    -- If no actions are set up, add default ones
    if #settings.actions == 0 then
        settings.actions = default_actions
    end
    
    -- Initialize section states if they don't exist
    if not settings.section_states then
        settings.section_states = {
            position = true,
            appearance = false,
            buttons = false,
            actions = true,
            import_export = false
        }
    end
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

-- Export actions to a file
function ExportActionsToFile()
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
        local json = r.serialize(settings.actions)
        
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

-- Import actions from a file
function ImportActionsFromFile()
    if not r.APIExists("JS_Dialog_BrowseForOpenFiles") then
        r.ShowMessageBox("The js_ReaScriptAPI extension is required for file import.", "Error", 0)
        return
    end
    if not temp_settings then temp_settings = shallow_copy(settings) end
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
                
                -- Convert to sequential array
                local imported_actions = {}
                for i = 0, #actions do
                    if actions[i] then
                        table.insert(imported_actions, actions[i])
                    end
                end
                
                if #imported_actions > 0 then
                    -- Ask if user wants to replace or append
                    local replace = r.ShowMessageBox("Do you want to replace the current actions or append the imported ones?", 
                                                "Import Actions", 1) == 1
                    
                    if replace then
                        temp_settings.actions = imported_actions
                    else
                        -- Append the imported actions
                        for _, action in ipairs(imported_actions) do
                            table.insert(temp_settings.actions, action)
                            
                        end
                    end
                    settings.actions = temp_settings.actions
SaveSettings()
ClearIconCaches()
                    r.ShowConsoleMsg("Actions imported successfully from ReaperMenu: " .. filename .. "\n")
                else
                    r.ShowMessageBox("No actions found in the imported ReaperMenu file.", "Error", 0)
                end
            else
                -- Process JSON format (old behavior)
                local content = file:read("*all")
                file:close()
                
                local success, imported_actions = pcall(function() return load("return " .. content)() end)
                if success and type(imported_actions) == 'table' then
                    if #imported_actions > 0 then
                        -- Ask if user wants to replace or append
                        local replace = r.ShowMessageBox("Do you want to replace the current actions or append the imported ones?", 
                                                    "Import Actions", 1) == 1
                        
                        if replace then
                            temp_settings.actions = imported_actions
                        else
                            -- Append the imported actions
                            for _, action in ipairs(imported_actions) do
                                table.insert(temp_settings.actions, action)
                            end
                        end
                        
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

-- Icon loading and caching
local icons = {}
local reaper_icon_states = {}  -- Store the three states of REAPER icons

-- Clear all icon caches to force reload
function ClearIconCaches()
    icons = {}
    reaper_icon_states = {}
end

-- Find the icon file
function FindIconFile(icon_path)
    if not icon_path or icon_path == "" then return nil end
    
    -- If already an absolute path and exists, use it
    if r.file_exists(icon_path) then
        return icon_path
    end
    
    -- Try various paths
    local paths_to_try = {
        script_path .. icon_path,
        settings.icon_path ~= "" and (settings.icon_path .. "/" .. icon_path) or nil,
        r.GetResourcePath() .. "/Data/toolbar_icons/" .. icon_path,
        r.GetResourcePath() .. "/Data/track_icons/" .. icon_path,
        r.GetResourcePath() .. "/Data/theme_icons/" .. icon_path,
        r.GetResourcePath() .. "/Data/icons/" .. icon_path,
        r.GetResourcePath() .. "/Plugins/FX/ReaPlugs/JS/icons/" .. icon_path
    }
    
    for i, path in ipairs(paths_to_try) do
        if path and r.file_exists(path) then
            return path
        end
    end
    
    -- Try to use file directly from the toolbar_icons folder as a last resort
    local direct_path = r.GetResourcePath() .. "/Data/toolbar_icons/" .. r.GetResourcePath():match("([^/\\]+)$") .. "_" .. icon_path
    if r.file_exists(direct_path) then
        return direct_path
    end
    
    return nil
end

-- Regular icon loading (basic single-state icons)
function LoadIcon(icon_path)
    if not icon_path or icon_path == "" then return nil end
    
    if icons[icon_path] then return icons[icon_path] end
    
    local full_path = FindIconFile(icon_path)
    if not full_path then return nil end
    
    -- Try to create image
    local success, texture = pcall(function() return r.ImGui_CreateImage(full_path) end)
    if success and texture then
        icons[icon_path] = texture
        return texture
    end
    
    return nil
end

-- Load REAPER's multi-state icons (normal, hover, active)
function LoadReaperIconStates(icon_path)
    if not icon_path or icon_path == "" then return nil, nil, nil end
    
    if reaper_icon_states[icon_path] then
        return reaper_icon_states[icon_path].normal,
               reaper_icon_states[icon_path].hover,
               reaper_icon_states[icon_path].active
    end
    
    local full_path = FindIconFile(icon_path)
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
        
        reaper_icon_states[icon_path] = {
            texture = texture,
            normal = {texture = texture, uv = normal_uv, width = cell_width, height = height},
            hover = {texture = texture, uv = hover_uv, width = cell_width, height = height},
            active = {texture = texture, uv = active_uv, width = cell_width, height = height}
        }
        
        return reaper_icon_states[icon_path].normal,
               reaper_icon_states[icon_path].hover,
               reaper_icon_states[icon_path].active
    else
        -- This is a single-state icon, use it for all states
        reaper_icon_states[icon_path] = {
            texture = texture,
            normal = {texture = texture, width = width, height = height},
            hover = {texture = texture, width = width, height = height},
            active = {texture = texture, width = width, height = height}
        }
        
        return reaper_icon_states[icon_path].normal,
               reaper_icon_states[icon_path].hover,
               reaper_icon_states[icon_path].active
    end
end

-- Function to check if REAPER's transport window is visible and get its position
function FollowTransport()
    if not r.APIExists("JS_Window_Find") then return false end
    
    local transport_hwnd = r.JS_Window_Find("transport", true)
    if not transport_hwnd then return false end
    
    local retval, orig_LEFT, orig_TOP, orig_RIGHT, orig_BOT = r.JS_Window_GetRect(transport_hwnd)
    if not retval then return false end
    
    -- Convert coordinates if necessary
    local LEFT, TOP, RIGHT, BOT = orig_LEFT, orig_TOP, orig_RIGHT, orig_BOT
    if r.APIExists("ImGui_PointConvertNative") then
        LEFT, TOP = r.ImGui_PointConvertNative(ctx, orig_LEFT, orig_TOP)
        RIGHT, BOT = r.ImGui_PointConvertNative(ctx, orig_RIGHT, orig_BOT)
    end
    
    local transport_width = RIGHT - LEFT
    local transport_height = BOT - TOP
    
    settings.adaptive_width = math.min(transport_width * 0.8, settings.widget_width)
    settings.widget_width = settings.adaptive_width

    local target_x = LEFT + settings.rel_pos_x
    local target_y = TOP + settings.rel_pos_y
    
    r.ImGui_SetNextWindowPos(ctx, target_x, target_y)
    r.ImGui_SetNextWindowSize(ctx, settings.widget_width, settings.widget_height)
    return true
end

-- Style setup
function SetStyle()
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), settings.window_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), settings.frame_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_PopupRounding(), settings.popup_rounding or settings.window_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(), settings.grab_rounding or settings.frame_rounding)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabMinSize(), settings.grab_min_size or 8)
    -- Remove button borders by setting FrameBorderSize to 0
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), settings.border_size or 1)
    
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), settings.background_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), settings.text_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), settings.border_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), settings.button_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), settings.button_hover_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), settings.button_active_color)
end

-- Function to lookup command name from ID
function GetCommandName(command_id)
    if not command_id then return "Unknown" end
    
    if type(command_id) == "number" then
        local _, name = r.GetActionName(command_id)
        return name ~= "" and name or "Command ID: " .. command_id
    else
        -- Pour les commandes nommées (string), convertir d'abord en ID numérique
        local cmdId = r.NamedCommandLookup(command_id)
        if cmdId and cmdId ~= 0 then
            local _, name = r.GetActionName(cmdId)
            return name ~= "" and name or "Command: " .. command_id
        else
            return "Command: " .. command_id
        end
    end
end

-- Display toolbar with actions
function DisplayToolbar()
    -- Apply button styling
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), settings.button_spacing, settings.button_spacing)
    
    -- Calculate total buttons width for centering horizontally
    local total_width = 0
    for i = 1, #settings.actions do
        total_width = total_width + settings.button_width + (i > 1 and settings.button_spacing or 0)
    end
    
    -- Center buttons horizontally if enabled
    local x_offset = 0
    if settings.center_buttons and #settings.actions > 0 then
        local window_width = r.ImGui_GetWindowWidth(ctx)
        x_offset = (window_width - total_width) / 2
        if x_offset > 0 then
            r.ImGui_SetCursorPosX(ctx, x_offset)
        end
    end
    
    -- Center buttons vertically
    local window_height = r.ImGui_GetWindowHeight(ctx)
    local y_offset = (window_height - settings.button_height) / 2
    if y_offset > 0 then
        r.ImGui_SetCursorPosY(ctx, y_offset)
    end
    
    -- Display action buttons
    for i, action in ipairs(settings.actions) do
        if i > 1 then 
            r.ImGui_SameLine(ctx)
            -- Maintain vertical centering after SameLine
            if y_offset > 0 then
                r.ImGui_SetCursorPosY(ctx, y_offset)
            end
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
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), settings.button_active_color)
        else
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), settings.button_color)
        end
        
        local label = action.label or action.name or ("Action " .. i)
        if label == "" then label = "Action " .. i end
        
        -- Handle buttons based on icon settings
        local button_clicked = false
        
        -- Safer approach to handle icons
        if settings.show_icons and action.icon and action.icon ~= "" then
            -- Try to create a text button first in case all icon loading fails
            if settings.use_reaper_icons then
                -- Use a pcall to safely load REAPER icons
                local success, normal_state, hover_state, active_state = pcall(LoadReaperIconStates, action.icon)
                
                if success and normal_state and normal_state.texture then
                    -- Use the appropriate state based on the button state
                    local state_to_use = state == 1 and active_state or normal_state
                    
                    -- Set padding to center icon
                    local padding_x = (settings.button_width - settings.icon_size) / 2
                    local padding_y = (settings.button_height - settings.icon_size) / 2
                    
                    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                    
                    -- Safely use UV coords if available
                    if state_to_use.uv then
                        local display_width = settings.icon_size
                        local display_height = settings.icon_size
                        
                        if settings.preserve_icon_aspect_ratio and state_to_use.width and state_to_use.height then
                            local original_ratio = state_to_use.width / state_to_use.height
                            
                            if original_ratio > 1 then
                                display_width = settings.icon_size * original_ratio
                                display_height = settings.icon_size
                            elseif original_ratio < 1 then
                                display_width = settings.icon_size
                                display_height = settings.icon_size / original_ratio
                            end
                        end
                        
                        -- Safely create the image button
                        local success2, result = pcall(function()
                            return r.ImGui_ImageButton(ctx, label, state_to_use.texture, 
                                                  display_width, display_height,
                                                  state_to_use.uv[1], state_to_use.uv[2], 
                                                  state_to_use.uv[3], state_to_use.uv[4])
                        end)
                        
                        button_clicked = success2 and result or false
                    else
                        -- Safely create single texture button
                        local success2, result = pcall(function()
                            return r.ImGui_ImageButton(ctx, label, state_to_use.texture, 
                                                      settings.icon_size, settings.icon_size)
                        end)
                        
                        button_clicked = success2 and result or false
                    end
                    
                    r.ImGui_PopStyleVar(ctx)
                else
                    -- Fallback to trying regular icon
                    local success, icon_texture = pcall(LoadIcon, action.icon)
                    
                    if success and icon_texture then
                        -- Set padding to center icon
                        local padding_x = (settings.button_width - settings.icon_size) / 2
                        local padding_y = (settings.button_height - settings.icon_size) / 2
                        
                        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                        
                        -- Safely create the image button
                        local success2, result = pcall(function()
                            return r.ImGui_ImageButton(ctx, label, icon_texture, 
                                                     settings.icon_size, settings.icon_size)
                        end)
                        
                        button_clicked = success2 and result or false
                        
                        r.ImGui_PopStyleVar(ctx)
                    else
                        -- Fallback to text button if all icon loading fails
                        button_clicked = r.ImGui_Button(ctx, label, settings.button_width, settings.button_height)
                    end
                end
            else
                -- Regular icon loading (non-REAPER mode)
                local success, icon_texture = pcall(LoadIcon, action.icon)
                
                if success and icon_texture then
                    -- Set padding to center icon
                    local padding_x = (settings.button_width - settings.icon_size) / 2
                    local padding_y = (settings.button_height - settings.icon_size) / 2
                    
                    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                    
                    -- Safely create the image button
                    local success2, result = pcall(function()
                        return r.ImGui_ImageButton(ctx, label, icon_texture, 
                                                 settings.icon_size, settings.icon_size)
                    end)
                    
                    button_clicked = success2 and result or false
                    
                    r.ImGui_PopStyleVar(ctx)
                else
                    -- Fallback to text button if icon loading fails
                    button_clicked = r.ImGui_Button(ctx, label, settings.button_width, settings.button_height)
                end
            end
        else
            -- No icon, just create a text button
            button_clicked = r.ImGui_Button(ctx, label, settings.button_width, settings.button_height)
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
        if settings.show_tooltips and r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, action.name or ("Action " .. i))
            r.ImGui_EndTooltip(ctx)
        end
        
        -- Right-click to open settings
        if r.ImGui_IsItemClicked(ctx, 1) then
            settings.settings_open = true
            temp_settings = nil  -- Force recreation of temp settings
        end
    end
    
    r.ImGui_PopStyleVar(ctx)
end

-- Settings dialog with collapsible sections
function ShowSettingsDialog()
    -- Permettre à la fenêtre d'être déplacée et redimensionnée
    local settings_flags = r.ImGui_WindowFlags_NoCollapse()
    
    -- Définir une position initiale pour la fenêtre des options
    r.ImGui_SetNextWindowPos(ctx, 200, 200, r.ImGui_Cond_FirstUseEver())
    r.ImGui_SetNextWindowSize(ctx, 600, 600, r.ImGui_Cond_FirstUseEver())
    
    local visible, open = r.ImGui_Begin(ctx, 'Toolbar Settings', true, settings_flags)
    
    if not visible then
        r.ImGui_End(ctx)
        return open
    end
    
    -- Position Settings Section
    local position_open = r.ImGui_CollapsingHeader(ctx, "Position Settings", settings.section_states.position and r.ImGui_TreeNodeFlags_DefaultOpen() or 0)
    settings.section_states.position = position_open
    
    if position_open then
        local rv, changed
        
        rv, changed = r.ImGui_Checkbox(ctx, "Follow transport", settings.overlay_enabled)
        if rv and changed ~= settings.overlay_enabled then
            settings.overlay_enabled = changed
            force_position_update = true
            first_position_set = false
            
            -- Clear icon caches when changing transport setting to avoid errors
            if settings.show_icons then
                ClearIconCaches()
            end
        end
        
        rv, changed = r.ImGui_Checkbox(ctx, "Show background", settings.show_background)
        if rv and changed ~= settings.show_background then
            settings.show_background = changed
            force_position_update = true
        end
        
        r.ImGui_Text(ctx, "Position within transport:")
        rv, changed = r.ImGui_SliderDouble(ctx, "X position", settings.rel_pos_x, 0.0, 2000.0, "%.2f")
        if rv and changed ~= settings.rel_pos_x then
            settings.rel_pos_x = changed
            force_position_update = true
        end
        
        rv, changed = r.ImGui_SliderDouble(ctx, "Y position", settings.rel_pos_y, -2000.0, 2000.0, "%.2f")
        if rv and changed ~= settings.rel_pos_y then
            settings.rel_pos_y = changed
            force_position_update = true
        end
        
        r.ImGui_Text(ctx, "Widget dimensions:")
        rv, changed = r.ImGui_SliderInt(ctx, "Width", settings.widget_width, 20, 1000)
        if rv and changed ~= settings.widget_width then
            settings.widget_width = changed
            force_position_update = true
        end
        
        rv, changed = r.ImGui_SliderInt(ctx, "Height", settings.widget_height, 14, 400)
        if rv and changed ~= settings.widget_height then
            settings.widget_height = changed
            force_position_update = true
        end
    end
    
    -- Appearance Settings Section
    local appearance_open = r.ImGui_CollapsingHeader(ctx, "Appearance Settings", settings.section_states.appearance and r.ImGui_TreeNodeFlags_DefaultOpen() or 0)
    settings.section_states.appearance = appearance_open
    
    if appearance_open then
        local rv
        rv, settings.window_rounding = r.ImGui_SliderDouble(ctx, "Window Rounding", settings.window_rounding, 0, 20)
        rv, settings.frame_rounding = r.ImGui_SliderDouble(ctx, "Frame Rounding", settings.frame_rounding, 0, 20)
        rv, settings.border_size = r.ImGui_SliderDouble(ctx, "Border Size", settings.border_size, 0, 5)
        rv, settings.background_color = r.ImGui_ColorEdit4(ctx, "Background Color", settings.background_color)
        rv, settings.text_color = r.ImGui_ColorEdit4(ctx, "Text Color", settings.text_color)
        rv, settings.button_color = r.ImGui_ColorEdit4(ctx, "Button Color", settings.button_color)
        rv, settings.button_hover_color = r.ImGui_ColorEdit4(ctx, "Button Hover", settings.button_hover_color)
        rv, settings.button_active_color = r.ImGui_ColorEdit4(ctx, "Button Active", settings.button_active_color)
        rv, settings.border_color = r.ImGui_ColorEdit4(ctx, "Border Color", settings.border_color)
        
        r.ImGui_Text(ctx, "Font Settings:")
        r.ImGui_SetNextItemWidth(ctx, 150)
        local font_changed
        font_changed, settings.font_size = r.ImGui_SliderInt(ctx, "Font Size", settings.font_size, 8, 32)
        
        if font_changed then
            SetFontNeedsUpdate()
        end
    end
    
    -- Button Settings Section
    local button_open = r.ImGui_CollapsingHeader(ctx, "Button Settings", settings.section_states.buttons and r.ImGui_TreeNodeFlags_DefaultOpen() or 0)
    settings.section_states.buttons = button_open
    
    if button_open then
        local rv, changed
        rv, settings.center_buttons = r.ImGui_Checkbox(ctx, "Center buttons", settings.center_buttons)
        
        rv, changed = r.ImGui_Checkbox(ctx, "Show icons", settings.show_icons)
        if rv and changed ~= settings.show_icons then
            settings.show_icons = changed
            ClearIconCaches()
        end
        
        rv, changed = r.ImGui_Checkbox(ctx, "Use REAPER native icons", settings.use_reaper_icons)
        if rv and changed ~= settings.use_reaper_icons then
            settings.use_reaper_icons = changed
            ClearIconCaches()
        end
        
        r.ImGui_SameLine(ctx)
        r.ImGui_TextDisabled(ctx, "(?)")
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "Enable to use REAPER's multi-state toolbar icons")
            r.ImGui_Text(ctx, "To use REAPER's native icons, specify only the filename in the icon field")
            r.ImGui_Text(ctx, "Example: 'transport_play.png' not the full path")
            r.ImGui_Text(ctx, "Icons are searched in REAPER's standard icon folders")
            r.ImGui_EndTooltip(ctx)
        end
        
        r.ImGui_SetNextItemWidth(ctx, 150)
        rv, settings.button_width = r.ImGui_SliderInt(ctx, "Button Width", settings.button_width, 20, 300)
        
        r.ImGui_SetNextItemWidth(ctx, 150)
        rv, settings.button_height = r.ImGui_SliderInt(ctx, "Button Height", settings.button_height, 16, 100)
        
        r.ImGui_SetNextItemWidth(ctx, 150)
        rv, settings.button_spacing = r.ImGui_SliderInt(ctx, "Button Spacing", settings.button_spacing, 0, 20)
        
        r.ImGui_SetNextItemWidth(ctx, 150)
        rv, settings.icon_size = r.ImGui_SliderInt(ctx, "Icon Size", settings.icon_size, 8, 96)
        
        rv, settings.preserve_icon_aspect_ratio = r.ImGui_Checkbox(ctx, "Preserve Icon Aspect Ratio", settings.preserve_icon_aspect_ratio)
        r.ImGui_SameLine(ctx)
        r.ImGui_TextDisabled(ctx, "(?)")
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "If enabled, icons will maintain their original width/height ratio")
            r.ImGui_Text(ctx, "Useful for non-square icons like 90x30 toolbar icons")
            r.ImGui_EndTooltip(ctx)
        end
        
        r.ImGui_SetNextItemWidth(ctx, 300)
        rv, changed = r.ImGui_InputText(ctx, "Custom Icon Path (folder only)", settings.icon_path or "", 256)
        if rv and changed ~= settings.icon_path then
            settings.icon_path = changed
            ClearIconCaches()
        end
        
        r.ImGui_SameLine(ctx)
        r.ImGui_TextDisabled(ctx, "(?)")
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "Specify a custom folder for your icons.")
            r.ImGui_Text(ctx, "This path should contain only the folder name, not the file name.")
            r.ImGui_Text(ctx, "Example: C:/My/Icons/Folder or /home/user/icons")
            r.ImGui_EndTooltip(ctx)
        end
    end
    
    -- Import/Export Section
    local import_export_open = r.ImGui_CollapsingHeader(ctx, "Import/Export", settings.section_states.import_export and r.ImGui_TreeNodeFlags_DefaultOpen() or 0)
    settings.section_states.import_export = import_export_open
    
    if import_export_open then
        r.ImGui_Text(ctx, "Action List Management:")
        
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x4C72B3FF) -- Blue button
        if r.ImGui_Button(ctx, "Export Actions") then
            ExportActionsToFile()
        end
        
        r.ImGui_SameLine(ctx)
        
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x72B34CFF) -- Green button
        if r.ImGui_Button(ctx, "Import Actions") then
            ImportActionsFromFile()
        end
        r.ImGui_PopStyleColor(ctx, 2)
        
        r.ImGui_Separator(ctx)
    end
    
    -- Actions Management Section
    local actions_open = r.ImGui_CollapsingHeader(ctx, "Actions Management", settings.section_states.actions and r.ImGui_TreeNodeFlags_DefaultOpen() or 0)
    settings.section_states.actions = actions_open
    
    if actions_open then
        -- Get available height for the action list
        local window_height = r.ImGui_GetWindowHeight(ctx)
        local current_y = r.ImGui_GetCursorPosY(ctx)
        local bottom_buttons_height = 40 -- Height for bottom buttons section
        local available_height = window_height - current_y - bottom_buttons_height - 20 -- 20px padding
        
        -- Actions title row with Add button
        r.ImGui_BeginGroup(ctx)
        r.ImGui_Text(ctx, "Actions:")
        r.ImGui_SameLine(ctx)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x4C72B3FF) -- Blue button for Add
        if r.ImGui_Button(ctx, "Add Action") then
            local retval, retvals = r.GetUserInputs("Add Action", 1, "Command ID or Name:,extrawidth=100", "")
            if retval and retvals ~= "" then
                local command_id = tonumber(retvals)
                if command_id then
                    -- Numeric command ID
                    local _, name = r.GetActionName(0, command_id) -- Ajout du premier paramètre 0
                    table.insert(settings.actions, {
                        command_id = command_id,
                        name = name ~= "" and name or "Command ID: " .. command_id,
                        label = name ~= "" and name:match("[^:]+$") or "Action " .. (#settings.actions + 1),
                        icon = ""
                    })
                else
                    -- Try as a named command (string ID)
                    local numeric_id = r.NamedCommandLookup(retvals)
                    if numeric_id and numeric_id ~= 0 then
                        -- Protected GetActionName call
                        local action_name = "Script Command: " .. retvals
                        
                        -- Use pcall to avoid crashes
                        local success, result = pcall(function()
                            local _, name = r.GetActionName(0, numeric_id)
                            return name
                        end)
                        
                        if success and result and result ~= "" then
                            action_name = result
                        end
                        
                        table.insert(settings.actions, {
                            command_id = retvals,  -- Store original string ID
                            name = action_name,
                            label = action_name:match("[^:]+$") or retvals:sub(1, 12),
                            icon = ""
                        })
                    else
                        -- Not a valid command
                        table.insert(settings.actions, {
                            command_id = retvals,
                            name = "Command: " .. retvals,
                            label = "Action " .. (#settings.actions + 1),
                            icon = ""
                        })
                    end
                end
            end
        end
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_EndGroup(ctx)
        
        -- Display and edit current actions
        if #settings.actions > 0 then
            local item_to_remove = nil 
            local item_to_move_up = nil
            local item_to_move_down = nil
            
            if r.ImGui_BeginChild(ctx, "Actions List", 0, available_height) then
                for i, action in ipairs(settings.actions) do
                    r.ImGui_PushID(ctx, i)
                    
                    -- Add spacing between items
                    if i > 1 then 
                        r.ImGui_Spacing(ctx)
                        r.ImGui_Spacing(ctx)
                    end
                    
                    -- Title and action name
                    r.ImGui_BeginGroup(ctx)
                    local title_text = i .. ": " .. (action.name or "Unknown")
                    r.ImGui_Text(ctx, title_text)
                    r.ImGui_EndGroup(ctx)
                    
                    -- Command ID field (on its own line)
                    r.ImGui_Text(ctx, "Command ID:")
                    r.ImGui_SameLine(ctx, 100)
                    local cmd_text = type(action.command_id) == "number" and tostring(action.command_id) or action.command_id or ""
                    r.ImGui_SetNextItemWidth(ctx, 280)
                    local cmd_changed, new_cmd = r.ImGui_InputText(ctx, "##cmd" .. i, cmd_text, 64)
                    
                    if cmd_changed then
                        local num_cmd = tonumber(new_cmd)
                        if num_cmd then
                            action.command_id = num_cmd
                            local _, name = r.GetActionName(num_cmd)
                            if name ~= "" then 
                                action.name = name
                            end
                        else
                            action.command_id = new_cmd
                            local cmdId = r.NamedCommandLookup(new_cmd)
                            if cmdId and cmdId ~= 0 then
                                local _, name = r.GetActionName(cmdId)
                                if name ~= "" then
                                    action.name = name
                                end
                            end
                        end
                    end
                    
                    -- Label field (on its own line)
                    r.ImGui_Text(ctx, "Label:")
                    r.ImGui_SameLine(ctx, 100)
                    r.ImGui_SetNextItemWidth(ctx, 280)
                    local label_changed, new_label = r.ImGui_InputText(ctx, "##label" .. i, action.label or "", 64)
                    if label_changed then
                        action.label = new_label
                    end
                    
                    -- Icon field and Browse button (on their own line)
                    r.ImGui_Text(ctx, "Icon:")
                    r.ImGui_SameLine(ctx, 100)
                    r.ImGui_SetNextItemWidth(ctx, 280)
                    local icon_changed, new_icon = r.ImGui_InputText(ctx, "##icon" .. i, action.icon or "", 64)
                    if icon_changed then
                        action.icon = new_icon
                        icons[action.icon] = nil
                        reaper_icon_states[action.icon] = nil
                    end
                    
                    r.ImGui_SameLine(ctx, 390)
                    if r.ImGui_Button(ctx, "Browse...##" .. i, 80, 22) then
                        if r.APIExists("JS_Dialog_BrowseForOpenFiles") then
                            local ret, files = r.JS_Dialog_BrowseForOpenFiles("Select Icon", "", "", "PNG files\0*.png\0Icon files\0*.ico\0All files\0*.*\0", false)
                            if ret and files ~= "" then
                                local filename = files:match("([^/\\]+)$")
                                if filename then
                                    action.icon = filename
                                    icons[action.icon] = nil
                                    reaper_icon_states[action.icon] = nil
                                end
                            end
                        else
                            r.ShowConsoleMsg("js_ReaScript API extension is required for file browsing dialog\n")
                        end
                    end
                    
                    -- Icon preview if available
                    if settings.show_icons and action.icon and action.icon ~= "" then
                        r.ImGui_SameLine(ctx, 480)
                        local icon_texture = nil
                        local normal_state = nil
                        
                        if settings.use_reaper_icons then
                            normal_state = select(1, LoadReaperIconStates(action.icon))
                        end
                        
                        if normal_state and normal_state.texture then
                            if normal_state.uv then
                                r.ImGui_Image(ctx, normal_state.texture, 24, 24, 
                                           normal_state.uv[1], normal_state.uv[2], 
                                           normal_state.uv[3], normal_state.uv[4])
                            else
                                r.ImGui_Image(ctx, normal_state.texture, 24, 24)
                            end
                        else
                            icon_texture = LoadIcon(action.icon)
                            if icon_texture then
                                r.ImGui_Image(ctx, icon_texture, 24, 24)
                            else
                                r.ImGui_Text(ctx, "(Icon not found)")
                            end
                        end
                    end
                    
                    -- Action controls (on their own line)
                    r.ImGui_Spacing(ctx)
                    r.ImGui_BeginGroup(ctx)
                    if r.ImGui_Button(ctx, "Up##up" .. i, 50, 22) and i > 1 then
                        item_to_move_up = i
                    end
                    
                    r.ImGui_SameLine(ctx, 0, 8)
                    if r.ImGui_Button(ctx, "Down##down" .. i, 50, 22) and i < #settings.actions then
                        item_to_move_down = i
                    end
                    
                    r.ImGui_SameLine(ctx, 0, 8)
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xB34C4CFF) -- Red for remove
                    if r.ImGui_Button(ctx, "Remove##" .. i, 70, 22) then
                        item_to_remove = i
                    end
                    r.ImGui_PopStyleColor(ctx)
                    r.ImGui_EndGroup(ctx)
                    
                    r.ImGui_Separator(ctx)
                    r.ImGui_PopID(ctx)
                end
                
                -- Process move/remove operations after the loop
                if item_to_remove then
                    table.remove(settings.actions, item_to_remove)
                end
                
                if item_to_move_up then
                    local temp = settings.actions[item_to_move_up]
                    settings.actions[item_to_move_up] = settings.actions[item_to_move_up - 1]
                    settings.actions[item_to_move_up - 1] = temp
                end
                
                if item_to_move_down then
                    local temp = settings.actions[item_to_move_down]
                    settings.actions[item_to_move_down] = settings.actions[item_to_move_down + 1]
                    settings.actions[item_to_move_down + 1] = temp
                end
                
                r.ImGui_EndChild(ctx)
            end
        else
            r.ImGui_Text(ctx, "No actions added yet.")
        end
    end
    
    -- Bottom buttons section - positioned at the bottom of the window
    local window_height = r.ImGui_GetWindowHeight(ctx)
    r.ImGui_SetCursorPosY(ctx, window_height - 40)
    r.ImGui_Separator(ctx)
    
    -- Bottom buttons with equal spacing
    local button_width = (r.ImGui_GetWindowWidth(ctx) - 24) / 3 -- 24px for spacing
    if r.ImGui_Button(ctx, "Save Settings", button_width) then
        SaveSettings()
    end
    
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Load Default Actions", button_width) then
        settings.actions = shallow_copy(default_actions)
        SaveSettings()
        ClearIconCaches()
    end
    
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Close", button_width) then
        settings.settings_open = false
    end
    
    r.ImGui_End(ctx)
    return open
end

-- Separate function to display toolbar widget
function DisplayToolbarWidget()
    -- Specific flags for the main toolbar
    local toolbar_flags = r.ImGui_WindowFlags_NoScrollbar() |
                         r.ImGui_WindowFlags_AlwaysAutoResize() |
                         r.ImGui_WindowFlags_NoTitleBar() |
                         r.ImGui_WindowFlags_NoFocusOnAppearing() |
                         r.ImGui_WindowFlags_NoDocking() |
                         r.ImGui_WindowFlags_NoSavedSettings()
    
    -- Add NoBackground flag if background is disabled
    if not settings.show_background then
        toolbar_flags = toolbar_flags | r.ImGui_WindowFlags_NoBackground()
    end
    
    -- Set window position and size for the toolbar
    if settings.overlay_enabled then
        -- Always follow transport when enabled
        local transport_hwnd = r.JS_Window_Find("transport", true)
        if transport_hwnd then
            local retval, LEFT, TOP, RIGHT, BOT = r.JS_Window_GetRect(transport_hwnd)
            if retval then
                if r.APIExists("ImGui_PointConvertNative") then
                    LEFT, TOP = r.ImGui_PointConvertNative(ctx, LEFT, TOP)
                end
                
                local target_x = LEFT + settings.rel_pos_x
                local target_y = TOP + settings.rel_pos_y
                
                -- Adaptive width based on transport width
                local transport_width = RIGHT - LEFT
                settings.adaptive_width = math.min(transport_width * 0.8, settings.widget_width)
                settings.widget_width = settings.adaptive_width
                
                r.ImGui_SetNextWindowPos(ctx, target_x, target_y)
                r.ImGui_SetNextWindowSize(ctx, settings.widget_width, settings.widget_height)
            end
        end
    else
        -- Fixed position when not following transport
        if not first_position_set then
            local pos_x = settings.last_pos_x or 100
            local pos_y = settings.last_pos_y or 100
            r.ImGui_SetNextWindowPos(ctx, pos_x, pos_y)
            r.ImGui_SetNextWindowSize(ctx, settings.widget_width, settings.widget_height)
            first_position_set = true
        end
    end
    
    -- Start the window
    local visible, open = r.ImGui_Begin(ctx, 'Custom Action Toolbar 3', true, toolbar_flags)
    
    if visible then
        DisplayToolbar()
        
        -- Save position if not in overlay mode
        if not settings.overlay_enabled then
            local window_pos_x, window_pos_y = r.ImGui_GetWindowPos(ctx)
            if window_pos_x ~= settings.last_pos_x or window_pos_y ~= settings.last_pos_y then
                settings.last_pos_x = window_pos_x
                settings.last_pos_y = window_pos_y
            end
        end
        
        -- Change right-click behavior to toggle settings window
        if r.ImGui_IsWindowHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 1) and not r.ImGui_IsAnyItemHovered(ctx) then
            settings.settings_open = true
            temp_settings = nil  -- Force recreation of temp settings
        end
        
        r.ImGui_End(ctx)
    end
    
    return open
end

function IsContextValid(context)
    -- Basic check if context is not nil and appears to be a valid pointer
    return context ~= nil and type(context) == "userdata"
end

-- Main loop
function MainLoop()
    -- Recréer complètement le contexte ImGui si nécessaire
    if not ctx or r.ImGui_ValidatePtr(ctx, "ImGui_Context*") == false then
        ctx = r.ImGui_CreateContext('Custom Action Toolbar 3')
        -- Réinitialiser les ressources
        font = nil
        InitFont()
        ClearIconCaches()
        font_needs_update = false
        force_position_update = true
        first_position_set = false
    end

    if font_needs_update then
        InitFont()
        font_needs_update = false
    end

    -- Force position update if settings have changed
    if force_position_update then
        first_position_set = false
        force_position_update = false
    end
    
    -- Determine if the widget should be displayed
    local should_display = true
    
    -- Check window size for auto-hide feature
    if settings.auto_hide and not settings.settings_open then
        local main_hwnd = r.GetMainHwnd()
        if main_hwnd then
            local retval, main_LEFT, main_TOP, main_RIGHT, main_BOT = r.JS_Window_GetRect(main_hwnd)
            
            if retval then
                local main_width = main_RIGHT - main_LEFT
                local main_height = main_BOT - main_TOP
                
                if main_width < settings.min_window_width or main_height < settings.min_window_height then
                    should_display = false
                end
            end
        end
    end

    -- If we shouldn't display and settings are closed, reschedule for next frame
    if not should_display and not settings.settings_open then
        r.defer(MainLoop)
        return
    end
    
    -- Apply common styles
    SetStyle()
    
    r.ImGui_PushFont(ctx, font)
    
    local widget_open = true
    
    -- Display the toolbar widget if needed
    if should_display then
        widget_open = DisplayToolbarWidget()
    end
    
    -- Display settings dialog in a separate step to avoid interference
    local settings_open = true
    if settings.settings_open then
        settings_open = ShowSettingsDialog()
        if not settings_open then
            settings.settings_open = false
        end
    end
    
    r.ImGui_PopFont(ctx)
    r.ImGui_PopStyleVar(ctx, 7)
    r.ImGui_PopStyleColor(ctx, 6)
    
    -- Continue if widget is open or settings are open
    if (should_display and widget_open) or settings.settings_open then
        r.defer(MainLoop)
    else
        SaveSettings()
    end
end

-- Initialize
LoadSettings()
InitFont()
settings.min_window_width = 1850 -- Minimum width of REAPER window in pixels
settings.min_window_height = 900 -- Minimum height of REAPER window in pixels
settings.auto_hide = true        -- Enable/disable auto-hide function

-- Start 
local _, _, section_id, command_id = r.get_action_context()
r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

function Exit()
    SaveSettings()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end

r.atexit(Exit)
MainLoop()
