-- @description CustomToolbars
-- @version 1.0.3
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_CustomToolbars"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local extname_base = "CP_CustomToolbars"
local toolbars = {}
local current_toolbar_index = 1
local show_toolbar_manager = false
local presets = {}
local current_preset = "default"
local current_editing_action_index = nil
local ctx = r.ImGui_CreateContext('Custom Toolbars Manager')
local cache_time = 0
local cache_interval = 1.0
local pushed_colors = 0
local pushed_vars = 0
local current_tab = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

local config = {
    window_width = 1200,
    window_height = 700,
    time_interval = 0.1
}

local state = {
    window_position_set = false,
    debug_info = ""
}

local available_windows = {
    { id = "main", name = "Main Window" },
    { id = "transport", name = "Transport" },
    { id = "mixer", name = "Mixer" },
    { id = "media_explorer", name = "Media Explorer" },
    { id = "ruler", name = "Ruler" },
    { id = "arrange", name = "Arrange View" },
    { id = "action_list", name = "Action List" },
    { id = "track_manager", name = "Track Manager" },
    { id = "region_manager", name = "Region/Marker Manager" },
    { id = "docker_0", name = "Docker 1 (Bottom)" },
    { id = "docker_1", name = "Docker 2 (Left)" },
    { id = "docker_2", name = "Docker 3 (Top)" },
    { id = "docker_3", name = "Docker 4 (Right)" },
    { id = "docker_4", name = "Docker 5 (Floating)" },
    { id = "docker_5", name = "Ruler" }
}

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

local main_font_size = GetStyleValue("fonts.main.size", 16)
local header_font_size = GetStyleValue("fonts.header.size", 16)
local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
local window_padding_y = GetStyleValue("spacing.window_padding_y", 8)
local frame_padding_x = GetStyleValue("spacing.frame_padding_x", 8)
local frame_padding_y = GetStyleValue("spacing.frame_padding_y", 8)

local button_height_style = main_font_size + 2 * frame_padding_y

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

function ShallowCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for orig_key, orig_value in pairs(orig) do
        if type(orig_value) == "table" then
            copy[orig_key] = ShallowCopy(orig_value)
        else
            copy[orig_key] = orig_value
        end
    end
    return copy
end

local default_actions = {
    { command_id = 1007, name = "Transport: Play/Stop",   label = "Play/Stop", icon = "play.png" },
    { command_id = 1013, name = "Transport: Record",      label = "Record",  icon = "record.png" },
    { command_id = 40364, name = "View: Toggle metronome", label = "Metro",  icon = "metronome.png" },
    { command_id = 1157, name = "Grid: Toggle snap to grid", label = "Grid", icon = "grid.png" },
}

local default_toolbar_template = {
    id = "",
    name = "",
    is_enabled = true,
    window_to_follow = "main",
    docker_id = 0,
    snap_to = "right",
    use_responsive_layout = true,
    offset_x = 10,
    offset_y = 4,
    widget_width = 330,
    widget_height = 36,
    original_widget_width = 330,
    original_widget_height = 36,
    last_pos_x = 1000,
    last_pos_y = 1000,
    font_size = 16,
    current_font = "Verdana",
    button_font = "Verdana",
    use_high_dpi_font = true,
    background_color = 0x1E1E1EFF,
    text_color = 0xFFFFFFFF,
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
    show_background = true,
    actions = {},
    button_width = 30,
    button_height = 28,
    icon_size = 30,
    preserve_icon_aspect_ratio = true,
    show_icons = true,
    center_buttons = true,
    icon_path = r.GetResourcePath() .. "/Data/toolbar_icons",
    show_tooltips = true,
    use_reaper_icons = true,
    min_window_width = 1800,
    min_window_height = 200,
    auto_hide_width = false,
    auto_hide_height = false,
    adaptive_width = false,
    adaptive_height = false,
    time_interval = 1.0,
    settings_open = false,
    section_states = {
        position = true,
        appearance = false,
        buttons = false,
        actions = true,
        import_export = false
    },
    context = nil,
    font = nil,
    font_needs_update = false,
    force_position_update = false,
    first_position_set = false,
    icons = {},
    reaper_icon_states = {},
    last_window_check = 0,
    last_invisible_check = 0,
    cached_target_rect = nil,
}

function NormalizePath(path)
    if not path then return nil end
    if r.GetOS():match("Win") then return path:gsub("/", "\\") end
    return path:gsub("\\", "/")
end

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

function CleanupToolbarResources(toolbar)
    if toolbar.icons then
        toolbar.icons = {}
    end
    
    if toolbar.reaper_icon_states then
        toolbar.reaper_icon_states = {}
    end
    
    if toolbar.font and r.ImGui_ValidatePtr(toolbar.font, "ImGui_Font*") then
        toolbar.font = nil
    end
    
    if toolbar.context and r.ImGui_ValidatePtr(toolbar.context, "ImGui_Context*") then
        toolbar.context = nil
    end
end

function SaveToolbars()
    local toolbar_list = {}
    for i, tb in ipairs(toolbars) do
        toolbar_list[i] = { id = tb.id, name = tb.name, is_enabled = tb.is_enabled }
    end
    r.SetExtState(extname_base, "toolbar_list", r.serialize(toolbar_list), true)
    for _, tb in ipairs(toolbars) do
        local tb_copy = ShallowCopy(tb)
        tb_copy.context = nil
        tb_copy.font = nil
        tb_copy.font_needs_update = nil
        tb_copy.force_position_update = nil
        tb_copy.first_position_set = nil
        tb_copy.icons = {}
        tb_copy.reaper_icon_states = {}
        tb_copy.last_window_check = nil
        tb_copy.last_invisible_check = nil
        tb_copy.cached_target_rect = nil
        r.SetExtState(extname_base .. "_" .. tb.id, "settings", r.serialize(tb_copy), true)
    end
    r.SetExtState(extname_base, "current_toolbar", tostring(current_toolbar_index), true)
    r.SetExtState(extname_base, "current_preset", current_preset, true)
end

function LoadToolbars()
    local state_str = r.GetExtState(extname_base, "toolbar_list")
    if state_str ~= "" then
        local success, toolbar_list = pcall(function() return load("return " .. state_str)() end)
        if success and toolbar_list and #toolbar_list > 0 then
            toolbars = {}
            for _, tb_info in ipairs(toolbar_list) do
                local toolbar_settings_str = r.GetExtState(extname_base .. "_" .. tb_info.id, "settings")
                local tb = ShallowCopy(default_toolbar_template)
                if toolbar_settings_str ~= "" then
                    local success, loaded_settings = pcall(function() return load("return " .. toolbar_settings_str)() end)
                    if success and loaded_settings then
                        for k, v in pairs(loaded_settings) do tb[k] = v end
                    end
                end
                tb.id = tb_info.id
                tb.name = tb_info.name
                tb.is_enabled = tb_info.is_enabled
                if tb.snap_to == "transport" or tb.snap_to == "mixer" or tb.snap_to == "media_explorer" or tb.snap_to == "ruler" or tb.snap_to == "arrange" then
                    tb.window_to_follow = tb.snap_to
                    tb.snap_to = "left"
                elseif not tb.window_to_follow then
                    tb.window_to_follow = "main"
                end
                
                if not tb.original_widget_width then
                    tb.original_widget_width = tb.widget_width
                end
                if not tb.original_widget_height then
                    tb.original_widget_height = tb.widget_height
                end
                
                if tb.auto_hide_width == nil then
                    tb.auto_hide_width = false
                end
                if tb.auto_hide_height == nil then
                    tb.auto_hide_height = false
                end
                
                if not tb.button_font then
                    tb.button_font = "Verdana"
                end
                
                if not tb.icon_path or tb.icon_path == "" then
                    tb.icon_path = NormalizePath(r.GetResourcePath() .. "/Data/toolbar_icons")
                end
                
                tb.context = nil
                tb.font = nil
                tb.font_needs_update = true
                tb.force_position_update = true
                tb.first_position_set = false
                tb.icons = {}
                tb.reaper_icon_states = {}
                tb.last_window_check = 0
                tb.last_invisible_check = 0
                tb.cached_target_rect = nil
                table.insert(toolbars, tb)
            end
        end
    end
    if #toolbars == 0 then CreateNewToolbar("Default Toolbar") end
    local current_idx_str = r.GetExtState(extname_base, "current_toolbar")
    if current_idx_str ~= "" then current_toolbar_index = tonumber(current_idx_str) or 1 end
    if current_toolbar_index < 1 or current_toolbar_index > #toolbars then current_toolbar_index = 1 end
    local preset = r.GetExtState(extname_base, "current_preset")
    if preset ~= "" then current_preset = preset end
    LoadPresets()
end

function CreateNewToolbar(name)
    local new_id = "toolbar_" .. os.time() .. "_" .. math.random(1000, 9999)
    local new_toolbar = ShallowCopy(default_toolbar_template)
    new_toolbar.id = new_id
    new_toolbar.name = name or "New Toolbar"
    new_toolbar.actions = ShallowCopy(default_actions)
    new_toolbar.icon_path = NormalizePath(r.GetResourcePath() .. "/Data/toolbar_icons")
    new_toolbar.context = nil
    new_toolbar.font = nil
    new_toolbar.font_needs_update = true
    new_toolbar.force_position_update = true
    new_toolbar.first_position_set = false
    table.insert(toolbars, new_toolbar)
    return #toolbars
end

function CreatePresetAction(preset_name)
    if preset_name == "default" then return { success = false } end
    
    local actions_dir = r.GetResourcePath() .. "/Scripts/CP_Scripts/Custom Toolbars/Actions/"
    os.execute('mkdir "' .. actions_dir .. '"')
    
    local safe_name = preset_name:gsub("[^%w%s-_]", ""):gsub("%s+", "_")
    local action_name_on = "CP_CustomToolbars_Preset_" .. safe_name .. "_On"
    local action_name_off = "CP_CustomToolbars_Preset_" .. safe_name .. "_Off"
    
    local action_id_on = r.NamedCommandLookup("_" .. action_name_on)
    local action_id_off = r.NamedCommandLookup("_" .. action_name_off)
    
    local action_path_on = actions_dir .. action_name_on .. ".lua"
    local script_content_on = [[local r=reaper
function EnablePreset()
    r.SetExtState("]] .. extname_base .. [[","current_preset","]] .. preset_name .. [[",true)
    r.SetExtState("]] .. extname_base .. [[","refresh_toolbars","1",false)
    r.SetExtState("]] .. extname_base .. [[","preset_changed","1",false)
end
EnablePreset()]]

    local action_path_off = actions_dir .. action_name_off .. ".lua"
    local script_content_off = [[local r=reaper
function DisablePreset()
    r.SetExtState("]] .. extname_base .. [[","current_preset","default",true)
    r.SetExtState("]] .. extname_base .. [[","refresh_toolbars","1",false)
    r.SetExtState("]] .. extname_base .. [[","preset_changed","1",false)
end
DisablePreset()]]

    local success_on = false
    local file_on = io.open(action_path_on, "w")
    if file_on then
        file_on:write(script_content_on)
        file_on:close()
        if action_id_on == 0 then
            r.AddRemoveReaScript(true, 0, action_path_on, true)
        end
        success_on = true
    end

    local success_off = false
    local file_off = io.open(action_path_off, "w")
    if file_off then
        file_off:write(script_content_off)
        file_off:close()
        if action_id_off == 0 then
            r.AddRemoveReaScript(true, 0, action_path_off, true)
        end
        success_off = true
    end

    return { success = success_on and success_off }
end

function CheckToolbarToggleState()
    local refresh_needed = false
    
    for _, tb in ipairs(toolbars) do
        local toggle_state = r.GetExtState(extname_base, tb.id .. "_state")
        if toggle_state ~= "" then
            local new_state = toggle_state == "1"
            if tb.is_enabled ~= new_state then
                tb.is_enabled = new_state
                refresh_needed = true
            end
            r.DeleteExtState(extname_base, tb.id .. "_state", false)
        end
    end
    
    local preset_changed = r.GetExtState(extname_base, "preset_changed")
    if preset_changed == "1" then
        LoadPresets()
        refresh_needed = true
        r.DeleteExtState(extname_base, "preset_changed", false)
    end
    
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
    if type(command_id) == "number" then
        if r.CF_GetCommandText then
            local name = r.CF_GetCommandText(0, command_id)
            if name and name ~= "" then return name end
        end
        if r.GetActionName then
            local _, name = r.GetActionName(0, command_id)
            if name and name ~= "" then return name end
        end
        return "Command ID: " .. tostring(command_id)
    else
        local cmd_id = 0
        pcall(function() cmd_id = r.NamedCommandLookup(command_id) end)
        if cmd_id and cmd_id ~= 0 then
            if r.CF_GetCommandText then
                local name = r.CF_GetCommandText(0, cmd_id)
                if name and name ~= "" then return name end
            end
            if r.GetActionName then
                local _, name = r.GetActionName(0, cmd_id)
                if name and name ~= "" then return name end
            end
            return "Command: " .. tostring(command_id) .. " (ID: " .. tostring(cmd_id) .. ")"
        else
            return "Command: " .. tostring(command_id)
        end
    end
end

function BrowseIconsDialog(toolbar, action_index)
    if not ctx or not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then return false end
    r.ImGui_SetNextWindowSize(ctx, 600, 400, r.ImGui_Cond_FirstUseEver())
    if r.ImGui_BeginPopupModal(ctx, "Icon Browser", true) then
        local base_path = toolbar.icon_path or ""
        if base_path == "" then
            base_path = NormalizePath(r.GetResourcePath() .. "/Data/toolbar_icons")
        end
        r.ImGui_Text(ctx, "Path:")
        local path_changed, new_path = r.ImGui_InputText(ctx, "##path", base_path, 256)
        if path_changed then toolbar.icon_path = new_path end
        local static_filter = r.GetExtState(extname_base, "icon_filter") or ""
        local filter_changed, new_filter = r.ImGui_InputText(ctx, "Filter", static_filter, 64)
        if filter_changed then
            r.SetExtState(extname_base, "icon_filter", new_filter, false)
            static_filter = new_filter
        end
        if static_filter ~= "" then
            r.ImGui_SameLine(ctx)
            r.ImGui_TextColored(ctx, 0x88FF88FF, "Filtering: " .. static_filter)
        end
        r.ImGui_Separator(ctx)
        local cell_size = 70
        local icon_display_size = 30
        local window_width = r.ImGui_GetContentRegionAvail(ctx)
        local columns = math.max(1, math.floor(window_width / cell_size))
        if r.ImGui_BeginChild(ctx, "IconGrid", -1, -40) then
            local all_files = {}
            local filtered_files = {}
            pcall(function()
                local i = 0
                local file = r.EnumerateFiles(base_path, i)
                while file do
                    if file:match("%.png$") or file:match("%.ico$") then
                        table.insert(all_files, file)
                        if static_filter == "" or string.lower(file):find(string.lower(static_filter), 1, true) then
                            table.insert(filtered_files, file)
                        end
                    end
                    i = i + 1
                    file = r.EnumerateFiles(base_path, i)
                end
            end)
            if static_filter ~= "" then
                r.ImGui_TextColored(ctx, 0x88FFFFFF,
                    string.format("Showing %d of %d icons", #filtered_files, #all_files))
                r.ImGui_Separator(ctx)
            end
            if #filtered_files == 0 then
                if #all_files > 0 then
                    r.ImGui_TextColored(ctx, 0xFFFF00FF, "No icons match your filter criteria.")
                    r.ImGui_Text(ctx, "Try a different filter term or clear the filter.")
                else
                    r.ImGui_TextColored(ctx, 0xFFFF00FF, "No icons found in this path.")
                    r.ImGui_Text(ctx, "Try setting the correct path to your REAPER icons folder.")
                    r.ImGui_Text(ctx, "Example: C:/Users/Username/AppData/Roaming/REAPER/Data/toolbar_icons")
                end
            else
                local current_col = 0
                for _, file in ipairs(filtered_files) do
                    if current_col > 0 then r.ImGui_SameLine(ctx) end
                    r.ImGui_BeginGroup(ctx)
                    local texture = nil
                    local icon_found = false
                    local normal_state = nil
                    if toolbar.use_reaper_icons then
                        pcall(function() normal_state, _, _ = LoadReaperIconStates(toolbar, file) end)
                    end
                    local padding_x = (cell_size - icon_display_size) / 2
                    r.ImGui_Dummy(ctx, padding_x, 0)
                    r.ImGui_SameLine(ctx)
                    local selected = false
                    if normal_state and normal_state.texture and r.ImGui_ValidatePtr(normal_state.texture, "ImGui_Image*") then
                        if normal_state.uv then
                            selected = r.ImGui_ImageButton(ctx, "##" .. file, normal_state.texture,
                                icon_display_size, icon_display_size,
                                normal_state.uv[1], normal_state.uv[2],
                                normal_state.uv[3], normal_state.uv[4])
                            icon_found = true
                        else
                            selected = r.ImGui_ImageButton(ctx, "##" .. file, normal_state.texture,
                                icon_display_size, icon_display_size)
                            icon_found = true
                        end
                    else
                        texture = LoadIcon(toolbar, file)
                        if texture and r.ImGui_ValidatePtr(texture, "ImGui_Image*") then
                            selected = r.ImGui_ImageButton(ctx, "##" .. file, texture,
                                icon_display_size, icon_display_size)
                            icon_found = true
                        else
                            selected = r.ImGui_Button(ctx, "?", icon_display_size, icon_display_size)
                        end
                    end
                    r.ImGui_EndGroup(ctx)
                    if r.ImGui_IsItemHovered(ctx) then
                        r.ImGui_BeginTooltip(ctx)
                        r.ImGui_Text(ctx, file)
                        r.ImGui_EndTooltip(ctx)
                    end
                    if selected then
                        if toolbar.actions[action_index] then
                            toolbar.actions[action_index].icon = file
                            toolbar.icons[file] = nil
                            toolbar.reaper_icon_states[file] = nil
                        end
                        r.ImGui_CloseCurrentPopup(ctx)
                        r.ImGui_EndChild(ctx)
                        r.ImGui_EndPopup(ctx)
                        return true
                    end
                    current_col = current_col + 1
                    if current_col >= columns then current_col = 0 end
                end
            end
            r.ImGui_EndChild(ctx)
        end
        r.ImGui_Separator(ctx)
        if r.ImGui_Button(ctx, "Cancel") then
            r.ImGui_CloseCurrentPopup(ctx)
        end
        r.ImGui_EndPopup(ctx)
        return false
    end
    return false
end

function InitFont(toolbar)
    if not toolbar.context or not r.ImGui_ValidatePtr(toolbar.context, "ImGui_Context*") then
        toolbar.context = r.ImGui_CreateContext('Toolbar_' .. toolbar.id)
        if style_loader then style_loader.ApplyFontsToContext(toolbar.context) end
        toolbar.font = nil
        toolbar.font_needs_update = true
    end
    
    if toolbar.font_needs_update and toolbar.context then
        local flags = 0
        if toolbar.use_high_dpi_font then
            flags = r.ImGui_FontFlags_None()
        else
            flags = r.ImGui_FontFlags_NoHinting() + r.ImGui_FontFlags_NoAutoHint()
        end
        
        if toolbar.current_font:lower() ~= "verdana" and toolbar.current_font ~= "Tahoma" then
            toolbar.current_font = "Verdana"
        end
        
        local font_to_use = toolbar.button_font or toolbar.current_font
        
        if toolbar.font and r.ImGui_ValidatePtr(toolbar.font, "ImGui_Font*") then
            toolbar.font = nil
        end
        
        toolbar.font = r.ImGui_CreateFont(font_to_use, flags)
        if toolbar.font and r.ImGui_ValidatePtr(toolbar.font, "ImGui_Font*") then
            r.ImGui_Attach(toolbar.context, toolbar.font)
        end
        toolbar.font_needs_update = false
    end
    
    return toolbar.font ~= nil and r.ImGui_ValidatePtr(toolbar.font, "ImGui_Font*")
end

function EnsureToolbarReady(toolbar)
    if not toolbar.context or not r.ImGui_ValidatePtr(toolbar.context, "ImGui_Context*") then
        CleanupToolbarResources(toolbar)
        toolbar.context = r.ImGui_CreateContext('Toolbar_' .. toolbar.id)
        if style_loader then style_loader.ApplyFontsToContext(toolbar.context) end
        toolbar.font = nil
        toolbar.font_needs_update = true
        ClearIconCaches(toolbar)
    end
    
    if toolbar.font_needs_update then
        InitFont(toolbar)
    end
    
    return toolbar.context ~= nil
end

function ClearIconCaches(toolbar)
    if toolbar.icons then
        toolbar.icons = {}
    end
    
    if toolbar.reaper_icon_states then
        toolbar.reaper_icon_states = {}
    end
end

function FindIconFile(toolbar, icon_path)
    if not icon_path or icon_path == "" then return nil end
    if r.file_exists(icon_path) then return icon_path end
    
    local default_icons_path = NormalizePath(r.GetResourcePath() .. "/Data/toolbar_icons/")
    local toolbar_icon_path = toolbar.icon_path or ""
    if toolbar_icon_path == "" then
        toolbar_icon_path = default_icons_path
    else
        toolbar_icon_path = NormalizePath(toolbar_icon_path .. "/")
    end
    
    local paths_to_try = {
        NormalizePath(default_icons_path .. icon_path),
        NormalizePath(toolbar_icon_path .. icon_path),
        NormalizePath(script_path .. "/" .. icon_path),
        NormalizePath(r.GetResourcePath() .. "/Data/track_icons/" .. icon_path),
        NormalizePath(r.GetResourcePath() .. "/Data/theme_icons/" .. icon_path),
        NormalizePath(r.GetResourcePath() .. "/Data/icons/" .. icon_path),
        NormalizePath(r.GetResourcePath() .. "/Plugins/FX/ReaPlugs/JS/icons/" .. icon_path)
    }
    
    for i, path in ipairs(paths_to_try) do
        if path and r.file_exists(path) then return path end
    end
    
    local direct_path = NormalizePath(default_icons_path .. r.GetResourcePath():match("([^/\\]+)$") .. "_" .. icon_path)
    if r.file_exists(direct_path) then return direct_path end
    
    return nil
end

function LoadIcon(toolbar, icon_path)
    if not icon_path or icon_path == "" then return nil end
    if toolbar.icons[icon_path] and r.ImGui_ValidatePtr(toolbar.icons[icon_path], "ImGui_Image*") then 
        return toolbar.icons[icon_path] 
    end
    local full_path = FindIconFile(toolbar, icon_path)
    if not full_path then return nil end
    local success, texture = pcall(function() return r.ImGui_CreateImage(full_path) end)
    if success and texture and r.ImGui_ValidatePtr(texture, "ImGui_Image*") then
        toolbar.icons[icon_path] = texture
        return texture
    end
    return nil
end

function LoadReaperIconStates(toolbar, icon_path)
    if not icon_path or icon_path == "" then return nil, nil, nil end
    if toolbar.reaper_icon_states[icon_path] then
        local states = toolbar.reaper_icon_states[icon_path]
        if states.texture and r.ImGui_ValidatePtr(states.texture, "ImGui_Image*") then
            return states.normal, states.hover, states.active
        else
            toolbar.reaper_icon_states[icon_path] = nil
        end
    end
    
    local full_path = FindIconFile(toolbar, icon_path)
    if not full_path then return nil, nil, nil end
    local success, texture = pcall(function() return r.ImGui_CreateImage(full_path) end)
    if not success or not texture or not r.ImGui_ValidatePtr(texture, "ImGui_Image*") then return nil, nil, nil end
    
    local width, height = r.ImGui_Image_GetSize(texture)
    local is_multi_state = (width % 3 == 0) or (math.abs(width / height - 3) < 0.1)
    if is_multi_state then
        local cell_width = width / 3
        local normal_uv = { 0, 0, cell_width / width, 1 }
        local hover_uv = { cell_width / width, 0, (cell_width * 2) / width, 1 }
        local active_uv = { (cell_width * 2) / width, 0, 1, 1 }
        toolbar.reaper_icon_states[icon_path] = {
            texture = texture,
            normal = { texture = texture, uv = normal_uv, width = cell_width, height = height },
            hover = { texture = texture, uv = hover_uv, width = cell_width, height = height },
            active = { texture = texture, uv = active_uv, width = cell_width, height = height }
        }
        return toolbar.reaper_icon_states[icon_path].normal,
            toolbar.reaper_icon_states[icon_path].hover,
            toolbar.reaper_icon_states[icon_path].active
    else
        toolbar.reaper_icon_states[icon_path] = {
            texture = texture,
            normal = { texture = texture, width = width, height = height },
            hover = { texture = texture, width = width, height = height },
            active = { texture = texture, width = width, height = height }
        }
        return toolbar.reaper_icon_states[icon_path].normal,
            toolbar.reaper_icon_states[icon_path].hover,
            toolbar.reaper_icon_states[icon_path].active
    end
end

function SetStyle(toolbar, toolbar_ctx)
    if not toolbar_ctx or not r.ImGui_ValidatePtr(toolbar_ctx, "ImGui_Context*") then return 0, 0 end
    
    local vars_pushed = 0
    local colors_pushed = 0
    
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_WindowRounding(), toolbar.window_rounding)
    vars_pushed = vars_pushed + 1
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_FrameRounding(), toolbar.frame_rounding)
    vars_pushed = vars_pushed + 1
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_PopupRounding(), toolbar.popup_rounding or toolbar.window_rounding)
    vars_pushed = vars_pushed + 1
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_GrabRounding(), toolbar.grab_rounding or toolbar.frame_rounding)
    vars_pushed = vars_pushed + 1
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_GrabMinSize(), toolbar.grab_min_size or 8)
    vars_pushed = vars_pushed + 1
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_FrameBorderSize(), 0)
    vars_pushed = vars_pushed + 1
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_WindowBorderSize(), toolbar.border_size or 1)
    vars_pushed = vars_pushed + 1
    
    r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_WindowBg(), toolbar.background_color)
    colors_pushed = colors_pushed + 1
    r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_Text(), toolbar.text_color)
    colors_pushed = colors_pushed + 1
    r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_Border(), toolbar.border_color)
    colors_pushed = colors_pushed + 1
    r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_Button(), toolbar.button_color)
    colors_pushed = colors_pushed + 1
    r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_ButtonHovered(), toolbar.button_hover_color)
    colors_pushed = colors_pushed + 1
    r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_ButtonActive(), toolbar.button_active_color)
    colors_pushed = colors_pushed + 1
    
    return vars_pushed, colors_pushed
end

function GetTargetWindow(toolbar)
    local current_time = r.time_precise()
    local time_interval = toolbar.time_interval or 1.0
    
    if toolbar.cached_target_rect and (current_time - toolbar.last_window_check) < time_interval then
        if IsWindowVisible(toolbar.cached_target_rect.hwnd) then
            return toolbar.cached_target_rect.hwnd
        else
            toolbar.cached_target_rect = nil
            toolbar.last_invisible_check = current_time
        end
    end
    
    if toolbar.last_invisible_check > 0 and (current_time - toolbar.last_invisible_check) < (time_interval * 3) then
        return nil
    end

    if not r.APIExists("JS_Window_Find") then return r.GetMainHwnd() end
    
    local hwnd = nil
    local window_name = ""
    
    if toolbar.window_to_follow == "transport" then
        local success, result = pcall(function() return r.JS_Window_Find("transport", true) end)
        if success and result then hwnd = result end
        window_name = "transport"
    elseif toolbar.window_to_follow == "mixer" then
        local success, result = pcall(function() return r.JS_Window_Find("mixer", true) end)
        if success and result then hwnd = result end
        window_name = "mixer"
    elseif toolbar.window_to_follow == "media_explorer" then
        local success, result = pcall(function() return r.JS_Window_Find("Media Explorer", true) end)
        if success and result then hwnd = result end
        window_name = "Media Explorer"
    elseif toolbar.window_to_follow == "ruler" then
        local success, result = pcall(function() return r.JS_Window_Find("ruler", true) end)
        if success and result then hwnd = result end
        window_name = "ruler"
    elseif toolbar.window_to_follow == "arrange" then
        local success, result = pcall(function() return r.JS_Window_Find("trackview", true) end)
        if success and result then hwnd = result end
        window_name = "trackview"
    elseif toolbar.window_to_follow == "action_list" then
        local success, result = pcall(function() return r.JS_Window_Find("Actions", true) end)
        if success and result then hwnd = result end
        window_name = "Actions"
    elseif toolbar.window_to_follow == "track_manager" then
        local success, result = pcall(function() return r.JS_Window_Find("Track Manager", true) end)
        if success and result then hwnd = result end
        window_name = "Track Manager"
    elseif toolbar.window_to_follow == "region_manager" then
        local success, result = pcall(function() return r.JS_Window_Find("Region/Marker Manager", true) end)
        if success and result then hwnd = result end
        window_name = "Region/Marker Manager"
    elseif toolbar.window_to_follow:match("^docker_(%d+)$") then
        local docker_id = tonumber(toolbar.window_to_follow:match("^docker_(%d+)$"))
        if docker_id == 5 then
            local success, result = pcall(function() return r.JS_Window_Find("ruler", true) end)
            if success and result then
                hwnd = result
                window_name = "ruler"
            else
                hwnd = r.GetMainHwnd()
                window_name = "Main (Ruler not found)"
            end
        elseif r.APIExists("JS_Window_FindChildByID") and docker_id then
            local success, docker_hwnd = pcall(function() return r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000 + docker_id) end)
            if success and docker_hwnd then 
                hwnd = docker_hwnd 
                window_name = "Docker " .. (docker_id + 1)
            else 
                hwnd = r.GetMainHwnd() 
                window_name = "Main (Docker not found)"
            end
        else
            hwnd = r.GetMainHwnd()
            window_name = "Main"
        end
    else
        hwnd = r.GetMainHwnd()
        window_name = "Main"
    end

    if hwnd and IsWindowVisible(hwnd) then
        toolbar.last_invisible_check = 0
        
        local success, retval, LEFT, TOP, RIGHT, BOT = pcall(function() return r.JS_Window_GetRect(hwnd) end)
        if success and retval then
            local width = RIGHT - LEFT
            local height = BOT - TOP
            
            if not toolbar.original_widget_width then
                toolbar.original_widget_width = toolbar.widget_width
            end
            if not toolbar.original_widget_height then
                toolbar.original_widget_height = toolbar.widget_height
            end
            
            if toolbar.adaptive_width then
                toolbar.widget_width = width
            end
            if toolbar.adaptive_height then
                toolbar.widget_height = height
            end
            
            toolbar.cached_target_rect = { 
                hwnd = hwnd, 
                left = LEFT, 
                top = TOP, 
                right = RIGHT, 
                bottom = BOT,
                window_name = window_name
            }
            toolbar.last_window_check = current_time
        end
    else
        toolbar.cached_target_rect = nil
        toolbar.last_invisible_check = current_time
        return nil
    end

    return hwnd
end

function DisplayToolbar(toolbar, toolbar_ctx)
    if not toolbar_ctx or not r.ImGui_ValidatePtr(toolbar_ctx, "ImGui_Context*") then return end
    r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_ItemSpacing(), toolbar.button_spacing, toolbar.button_spacing)
    
    local window_width = r.ImGui_GetContentRegionAvail(toolbar_ctx)
    local window_height = r.ImGui_GetWindowHeight(toolbar_ctx)
    
    local lines = {}
    local current_line = {}
    local current_line_width = 0
    local first_in_line = true
    
    for i, action in ipairs(toolbar.actions) do
        local btn_width = action.is_separator and (action.width or 10) or toolbar.button_width
        
        if toolbar.use_responsive_layout and (current_line_width + btn_width > window_width) and not first_in_line then
            table.insert(lines, current_line)
            current_line = {}
            current_line_width = 0
            first_in_line = true
        end
        
        table.insert(current_line, {action = action, index = i, width = btn_width})
        current_line_width = current_line_width + btn_width + (first_in_line and 0 or toolbar.button_spacing)
        first_in_line = false
    end
    
    if #current_line > 0 then
        table.insert(lines, current_line)
    end
    
    local total_height = #lines * toolbar.button_height + (#lines - 1) * toolbar.button_spacing
    local start_y = (window_height - total_height) / 2
    if start_y < 0 then start_y = 0 end
    
    r.ImGui_SetCursorPosY(toolbar_ctx, start_y)
    
    for line_idx, line in ipairs(lines) do
        if line_idx > 1 then
            r.ImGui_SetCursorPosY(toolbar_ctx, start_y + (line_idx - 1) * (toolbar.button_height + toolbar.button_spacing))
        end
        
        local line_width = 0
        for _, item in ipairs(line) do
            line_width = line_width + item.width
        end
        if #line > 1 then
            line_width = line_width + (#line - 1) * toolbar.button_spacing
        end
        
        local x_offset = 0
        if toolbar.center_buttons and #toolbar.actions > 0 then
            local window_width = r.ImGui_GetWindowWidth(toolbar_ctx)
            x_offset = (window_width - line_width) / 2
            if x_offset > 0 then r.ImGui_SetCursorPosX(toolbar_ctx, x_offset) end
        end
        
        for item_idx, item in ipairs(line) do
            local action = item.action
            local i = item.index
            
            if item_idx > 1 then
                r.ImGui_SameLine(toolbar_ctx)
            end
            
            if action.is_separator then
                r.ImGui_Dummy(toolbar_ctx, action.width or 10, toolbar.button_height)
                if r.ImGui_IsItemClicked(toolbar_ctx, 1) then
                    show_toolbar_manager = true
                    current_toolbar_index = GetToolbarIndexById(toolbar.id)
                end
                goto continue
            end
            
            local state = -1
            if action.command_id then
                if type(action.command_id) == "number" then
                    state = r.GetToggleCommandStateEx(0, action.command_id)
                else
                    local cmd_id = r.NamedCommandLookup(action.command_id)
                    if cmd_id ~= 0 then state = r.GetToggleCommandStateEx(0, cmd_id) end
                end
            end
            
            if state == 1 then
                r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_Button(), toolbar.button_active_color)
            else
                r.ImGui_PushStyleColor(toolbar_ctx, r.ImGui_Col_Button(), toolbar.button_color)
            end
            
            local label = action.label or action.name or ("Action " .. i)
            if label == "" then label = "Action " .. i end
            local button_clicked = false
            
            if toolbar.show_icons and action.icon and action.icon ~= "" then
                if toolbar.use_reaper_icons then
                    local success, normal_state, hover_state, active_state = pcall(function()
                        return LoadReaperIconStates(toolbar, action.icon)
                    end)
                    if success and normal_state and normal_state.texture and
                        r.ImGui_ValidatePtr(normal_state.texture, "ImGui_Image*") then
                        local state_to_use = state == 1 and active_state or normal_state
                        local padding_x = (toolbar.button_width - toolbar.icon_size) / 2
                        local padding_y = (toolbar.button_height - toolbar.icon_size) / 2
                        r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                        r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_FrameRounding(), toolbar.frame_rounding)
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
                            local button_success, button_result = pcall(function()
                                return r.ImGui_ImageButton(toolbar_ctx, label, state_to_use.texture,
                                    display_width, display_height,
                                    state_to_use.uv[1], state_to_use.uv[2],
                                    state_to_use.uv[3], state_to_use.uv[4])
                            end)
                            button_clicked = button_success and button_result or false
                        else
                            local button_success, button_result = pcall(function()
                                return r.ImGui_ImageButton(toolbar_ctx, label, state_to_use.texture,
                                    toolbar.icon_size, toolbar.icon_size)
                            end)
                            button_clicked = button_success and button_result or false
                        end
                        r.ImGui_PopStyleVar(toolbar_ctx, 2)
                    else
                        local icon_success, icon_texture = pcall(function()
                            return LoadIcon(toolbar, action.icon)
                        end)
                        if icon_success and icon_texture and r.ImGui_ValidatePtr(icon_texture, "ImGui_Image*") then
                            local padding_x = (toolbar.button_width - toolbar.icon_size) / 2
                            local padding_y = (toolbar.button_height - toolbar.icon_size) / 2
                            r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                            local button_success, button_result = pcall(function()
                                return r.ImGui_ImageButton(toolbar_ctx, label, icon_texture,
                                    toolbar.icon_size, toolbar.icon_size)
                            end)
                            button_clicked = button_success and button_result or false
                            r.ImGui_PopStyleVar(toolbar_ctx)
                        else
                            button_clicked = r.ImGui_Button(toolbar_ctx, label, toolbar.button_width, toolbar.button_height)
                        end
                    end
                else
                    local icon_success, icon_texture = pcall(function()
                        return LoadIcon(toolbar, action.icon)
                    end)
                    if icon_success and icon_texture and r.ImGui_ValidatePtr(icon_texture, "ImGui_Image*") then
                        local padding_x = (toolbar.button_width - toolbar.icon_size) / 2
                        local padding_y = (toolbar.button_height - toolbar.icon_size) / 2
                        r.ImGui_PushStyleVar(toolbar_ctx, r.ImGui_StyleVar_FramePadding(), padding_x, padding_y)
                        local button_success, button_result = pcall(function()
                            return r.ImGui_ImageButton(toolbar_ctx, label, icon_texture,
                                toolbar.icon_size, toolbar.icon_size)
                        end)
                        button_clicked = button_success and button_result or false
                        r.ImGui_PopStyleVar(toolbar_ctx)
                    else
                        button_clicked = r.ImGui_Button(toolbar_ctx, label, toolbar.button_width, toolbar.button_height)
                    end
                end
            else
                button_clicked = r.ImGui_Button(toolbar_ctx, label, toolbar.button_width, toolbar.button_height)
            end
            
            if button_clicked then
                if action.command_id then
                    if type(action.command_id) == "number" then
                        r.Main_OnCommand(action.command_id, 0)
                    else
                        local cmd_id = r.NamedCommandLookup(action.command_id)
                        if cmd_id ~= 0 then r.Main_OnCommand(cmd_id, 0) end
                    end
                end
            end
            
            r.ImGui_PopStyleColor(toolbar_ctx)
            
            if toolbar.show_tooltips and r.ImGui_IsItemHovered(toolbar_ctx) then
                r.ImGui_BeginTooltip(toolbar_ctx)
                r.ImGui_Text(toolbar_ctx, action.name or ("Action " .. i))
                r.ImGui_EndTooltip(toolbar_ctx)
            end
            
            if r.ImGui_IsItemClicked(toolbar_ctx, 1) then
                show_toolbar_manager = true
                current_toolbar_index = GetToolbarIndexById(toolbar.id)
            end
            
            ::continue::
        end
    end
    
    r.ImGui_PopStyleVar(toolbar_ctx)
end

function GetToolbarIndexById(id)
    for i, tb in ipairs(toolbars) do
        if tb.id == id then return i end
    end
    return 1
end

function IsWindowVisible(hwnd)
    if not hwnd then return false end
    if not r.APIExists("JS_Window_IsVisible") then return true end
    local success, result = pcall(function() return r.JS_Window_IsVisible(hwnd) end)
    if success then return result end
    return true
end

function DisplayToolbarWidget(toolbar)
    if not EnsureToolbarReady(toolbar) then
        return false
    end

    local target_hwnd = GetTargetWindow(toolbar)
    if not target_hwnd then
        return true
    end

    local pc, pv = 0, 0
    if style_loader then
        local success, colors, vars = style_loader.ApplyToContext(toolbar.context)
        if success then pc, pv = colors, vars end
    end

    local toolbar_flags = r.ImGui_WindowFlags_NoScrollbar()|
        r.ImGui_WindowFlags_AlwaysAutoResize()|
        r.ImGui_WindowFlags_NoTitleBar()|
        r.ImGui_WindowFlags_NoFocusOnAppearing()|
        r.ImGui_WindowFlags_NoDocking()|
        r.ImGui_WindowFlags_NoSavedSettings()

    if not toolbar.show_background then
        toolbar_flags = toolbar_flags|r.ImGui_WindowFlags_NoBackground()
    end

    if toolbar.cached_target_rect then
        local LEFT, TOP, RIGHT, BOT = toolbar.cached_target_rect.left, toolbar.cached_target_rect.top,
            toolbar.cached_target_rect.right, toolbar.cached_target_rect.bottom

        if r.APIExists("ImGui_PointConvertNative") then
            LEFT, TOP = r.ImGui_PointConvertNative(toolbar.context, LEFT, TOP)
            RIGHT, BOT = r.ImGui_PointConvertNative(toolbar.context, RIGHT, BOT)
        end

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
            target_x = LEFT + toolbar.offset_x
            target_y = TOP + toolbar.offset_y
        end

        r.ImGui_SetNextWindowPos(toolbar.context, target_x, target_y)
        r.ImGui_SetNextWindowSize(toolbar.context, toolbar.widget_width, toolbar.widget_height)
        toolbar.first_position_set = true
    else
        if not toolbar.first_position_set or toolbar.force_position_update then
            local pos_x = toolbar.last_pos_x or 100
            local pos_y = toolbar.last_pos_y or 100
            r.ImGui_SetNextWindowPos(toolbar.context, pos_x, pos_y)
            r.ImGui_SetNextWindowSize(toolbar.context, toolbar.widget_width, toolbar.widget_height)
            toolbar.first_position_set = true
            toolbar.force_position_update = false
        end
    end

    local vars_pushed, colors_pushed = SetStyle(toolbar, toolbar.context)
    local font_pushed = false
    if toolbar.font and r.ImGui_ValidatePtr(toolbar.font, "ImGui_Font*") then
        r.ImGui_PushFont(toolbar.context, toolbar.font, 0)
        font_pushed = true
    end

    local visible, open = r.ImGui_Begin(toolbar.context, 'Toolbar: ' .. toolbar.name, true, toolbar_flags)
    if visible then
        DisplayToolbar(toolbar, toolbar.context)

        if not toolbar.window_to_follow or toolbar.window_to_follow == "custom" then
            local window_pos_x, window_pos_y = r.ImGui_GetWindowPos(toolbar.context)
            if window_pos_x ~= toolbar.last_pos_x or window_pos_y ~= toolbar.last_pos_y then
                toolbar.last_pos_x = window_pos_x
                toolbar.last_pos_y = window_pos_y
            end
        end

        if r.ImGui_IsWindowHovered(toolbar.context) and r.ImGui_IsMouseClicked(toolbar.context, 1) and not r.ImGui_IsAnyItemHovered(toolbar.context) then
            show_toolbar_manager = true
            current_toolbar_index = GetToolbarIndexById(toolbar.id)
        end

        r.ImGui_End(toolbar.context)
    end

    if font_pushed then r.ImGui_PopFont(toolbar.context) end
    if vars_pushed > 0 then r.ImGui_PopStyleVar(toolbar.context, vars_pushed) end
    if colors_pushed > 0 then r.ImGui_PopStyleColor(toolbar.context, colors_pushed) end
    if style_loader then style_loader.ClearStyles(toolbar.context, pc, pv) end

    return open
end

function ShowAppearanceTab(ctx, tb)
    local col1_width = 260 + main_font_size * 5
    local col2_width = 320 + main_font_size * 6
    local col3_width = 320 + main_font_size * 5
    
    local total_width = col1_width + col2_width + col3_width + (item_spacing_x * 2) + (window_padding_x * 2)
    
    r.ImGui_SetNextWindowContentSize(ctx, total_width, 0)
    if r.ImGui_BeginChild(ctx, "appearance_scroll", -1, -1, 0, r.ImGui_WindowFlags_HorizontalScrollbar()) then
        if r.ImGui_BeginChild(ctx, "column1", col1_width, -1, 0, r.ImGui_WindowFlags_NoScrollbar()) then
            r.ImGui_Text(ctx, "Follow Window:")
            r.ImGui_SetNextItemWidth(ctx, -1)
            local current_index = 1
            for i, window in ipairs(available_windows) do
                if window.id == tb.window_to_follow then
                    current_index = i
                    break
                end
            end
            if r.ImGui_BeginCombo(ctx, "##window_selector", available_windows[current_index].name) then
                for i, window in ipairs(available_windows) do
                    local is_selected = (window.id == tb.window_to_follow)
                    if r.ImGui_Selectable(ctx, window.name, is_selected) then
                        if window.id ~= tb.window_to_follow then
                            tb.window_to_follow = window.id
                            tb.force_position_update = true
                            tb.first_position_set = false
                            tb.cached_target_rect = nil
                        end
                    end
                end
                r.ImGui_EndCombo(ctx)
            end
            
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Snap To:")
            
            local snap_child_width = (col1_width - item_spacing_x) / 2
            local snap_child_height = button_height_style * 2 + item_spacing_y * 3
            
            if r.ImGui_BeginChild(ctx, "snap_left", snap_child_width, snap_child_height, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                local is_topleft = tb.snap_to == "topleft"
                local rv = r.ImGui_RadioButton(ctx, "Top Left", is_topleft)
                if rv and not is_topleft then
                    tb.snap_to = "topleft"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                local is_bottomleft = tb.snap_to == "bottomleft"
                rv = r.ImGui_RadioButton(ctx, "Down Left", is_bottomleft)
                if rv and not is_bottomleft then
                    tb.snap_to = "bottomleft"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                r.ImGui_EndChild(ctx)
            end   

            r.ImGui_SameLine(ctx)

            if r.ImGui_BeginChild(ctx, "snap_right", snap_child_width, snap_child_height, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                local is_topright = tb.snap_to == "topright"
                rv = r.ImGui_RadioButton(ctx, "Top Right", is_topright)
                if rv and not is_topright then
                    tb.snap_to = "topright"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                local is_bottomright = tb.snap_to == "bottomright"
                rv = r.ImGui_RadioButton(ctx, "Down Right", is_bottomright)
                if rv and not is_bottomright then
                    tb.snap_to = "bottomright"
                    tb.force_position_update = true
                    tb.first_position_set = false
                end
                
                r.ImGui_EndChild(ctx)
            end

            r.ImGui_Separator(ctx)

            r.ImGui_Text(ctx, "Position Offsets:")
            local temp_offset_x = math.floor(tb.offset_x / 2) * 2
            rv, temp_offset_x = r.ImGui_SliderInt(ctx, "X Offset", temp_offset_x, 0, 1600, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            if rv then 
                tb.offset_x = math.floor(temp_offset_x / 2) * 2
                tb.force_position_update = true 
            end
            
            local temp_offset_y = math.floor(tb.offset_y / 2) * 2
            rv, temp_offset_y = r.ImGui_SliderInt(ctx, "Y Offset", temp_offset_y, 0, 1000, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            if rv then 
                tb.offset_y = math.floor(temp_offset_y / 2) * 2
                tb.force_position_update = true 
            end

            r.ImGui_Separator(ctx)

            r.ImGui_Text(ctx, "Auto-hide settings:")
            
            local width_changed, width_enabled = r.ImGui_Checkbox(ctx, "Auto-hide Width", tb.auto_hide_width)
            if width_changed then tb.auto_hide_width = width_enabled end
            
            if tb.auto_hide_width then
                local temp_min_width = math.floor(tb.min_window_width / 2) * 2
                rv, temp_min_width = r.ImGui_SliderInt(ctx, "Min Width", temp_min_width, 500, 3000, "%d", r.ImGui_SliderFlags_AlwaysClamp())
                if rv then tb.min_window_width = math.floor(temp_min_width / 2) * 2 end
            end
            
            local height_changed, height_enabled = r.ImGui_Checkbox(ctx, "Auto-hide Height", tb.auto_hide_height)
            if height_changed then tb.auto_hide_height = height_enabled end
            
            if tb.auto_hide_height then
                local temp_min_height = math.floor(tb.min_window_height / 2) * 2
                rv, temp_min_height = r.ImGui_SliderInt(ctx, "Min Height", temp_min_height, 100, 2000, "%d", r.ImGui_SliderFlags_AlwaysClamp())
                if rv then tb.min_window_height = math.floor(temp_min_height / 2) * 2 end
            end
            
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Dimensions:")
            
            local adaptive_child_width = (col1_width - item_spacing_x) / 2
            
            if r.ImGui_BeginChild(ctx, "adaptive_left", adaptive_child_width, 30, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                rv, tb.adaptive_width = r.ImGui_Checkbox(ctx, "Adaptive Width", tb.adaptive_width or false)
                if rv then
                    if not tb.adaptive_width and tb.original_widget_width then
                        tb.widget_width = tb.original_widget_width
                    end
                    tb.force_position_update = true
                end
                r.ImGui_EndChild(ctx)
            end
            
            r.ImGui_SameLine(ctx)
            
            if r.ImGui_BeginChild(ctx, "adaptive_right", adaptive_child_width, 30, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                rv, tb.adaptive_height = r.ImGui_Checkbox(ctx, "Adaptive Height", tb.adaptive_height or false)
                if rv then
                    if not tb.adaptive_height and tb.original_widget_height then
                        tb.widget_height = tb.original_widget_height
                    end
                    tb.force_position_update = true
                end
                r.ImGui_EndChild(ctx)
            end
            
            if not tb.adaptive_width then
                local temp_widget_width = math.floor(tb.widget_width / 2) * 2
                rv, temp_widget_width = r.ImGui_SliderInt(ctx, "Width", temp_widget_width, 20, 1000, "%d", r.ImGui_SliderFlags_AlwaysClamp())
                if rv then
                    tb.widget_width = math.floor(temp_widget_width / 2) * 2
                    tb.original_widget_width = tb.widget_width
                    tb.force_position_update = true
                end
            end
            
            if not tb.adaptive_height then
                local temp_widget_height = math.floor(tb.widget_height / 2) * 2
                rv, temp_widget_height = r.ImGui_SliderInt(ctx, "Height", temp_widget_height, 14, 400, "%d", r.ImGui_SliderFlags_AlwaysClamp())
                if rv then
                    tb.widget_height = math.floor(temp_widget_height / 2) * 2
                    tb.original_widget_height = tb.widget_height
                    tb.force_position_update = true
                end
            end
            
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_BeginChild(ctx, "column2", col2_width, -1, 0, r.ImGui_WindowFlags_NoScrollbar()) then
            r.ImGui_Text(ctx, "Layout:")

            rv, tb.show_background = r.ImGui_Checkbox(ctx, "Show background", tb.show_background)
            if rv then tb.force_position_update = true end
            
            rv, tb.window_rounding = r.ImGui_SliderInt(ctx, "Window Rounding", math.floor(tb.window_rounding), 0, 40, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            rv, tb.frame_rounding = r.ImGui_SliderInt(ctx, "Frame Rounding", math.floor(tb.frame_rounding), 0, 40, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            rv, tb.border_size = r.ImGui_SliderInt(ctx, "Border Size", math.floor(tb.border_size), 0, 10, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Colors:")

            rv, tb.background_color = r.ImGui_ColorEdit4(ctx, "Background##bg", tb.background_color)
            rv, tb.border_color = r.ImGui_ColorEdit4(ctx, "Border##brd", tb.border_color)
            rv, tb.text_color = r.ImGui_ColorEdit4(ctx, "Text##txt", tb.text_color)
            rv, tb.button_color = r.ImGui_ColorEdit4(ctx, "Button##btn", tb.button_color)
            rv, tb.button_hover_color = r.ImGui_ColorEdit4(ctx, "Button Hover##hovr", tb.button_hover_color)
            rv, tb.button_active_color = r.ImGui_ColorEdit4(ctx, "Button Active##actv", tb.button_active_color)
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_BeginChild(ctx, "column3", -1, -1, 0, r.ImGui_WindowFlags_NoScrollbar()) then
            r.ImGui_Text(ctx, "Button Settings:")

            local button_child_width = (col3_width - item_spacing_x) / 2
            local button_child_height = button_height_style * 2 + item_spacing_y * 3

            if r.ImGui_BeginChild(ctx, "button_child_left", button_child_width, button_child_height, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                rv, tb.center_buttons = r.ImGui_Checkbox(ctx, "Center buttons", tb.center_buttons)
                rv, tb.use_responsive_layout = r.ImGui_Checkbox(ctx, "Wrap Buttons", tb.use_responsive_layout)
                r.ImGui_EndChild(ctx)
            end

            r.ImGui_SameLine(ctx)

            if r.ImGui_BeginChild(ctx, "button_child_right", button_child_width, button_child_height, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                rv, tb.show_icons = r.ImGui_Checkbox(ctx, "Show icons", tb.show_icons)
                if rv then ClearIconCaches(tb) end
                rv, tb.use_reaper_icons = r.ImGui_Checkbox(ctx, "Use REAPER icons", tb.use_reaper_icons)
                if rv then ClearIconCaches(tb) end
                r.ImGui_EndChild(ctx)
            end

            r.ImGui_Separator(ctx)
            
            local temp_button_width = math.floor(tb.button_width / 2) * 2
            rv, temp_button_width = r.ImGui_SliderInt(ctx, "Button Width", temp_button_width, 20, 300, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            if rv then tb.button_width = math.floor(temp_button_width / 2) * 2 end
            
            local temp_button_height = math.floor(tb.button_height / 2) * 2
            rv, temp_button_height = r.ImGui_SliderInt(ctx, "Button Height", temp_button_height, 16, 100, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            if rv then tb.button_height = math.floor(temp_button_height / 2) * 2 end
            
            local temp_button_spacing = math.floor(tb.button_spacing / 2) * 2
            rv, temp_button_spacing = r.ImGui_SliderInt(ctx, "Button Spacing", temp_button_spacing, 0, 20, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            if rv then tb.button_spacing = math.floor(temp_button_spacing / 2) * 2 end
            
            local temp_icon_size = math.floor(tb.icon_size / 2) * 2
            rv, temp_icon_size = r.ImGui_SliderInt(ctx, "Icon Size", temp_icon_size, 8, 96, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            if rv then tb.icon_size = math.floor(temp_icon_size / 2) * 2 end
            
            r.ImGui_Text(ctx, "Custom Icon Path:")
            rv, tb.icon_path = r.ImGui_InputText(ctx, "##icon_path", tb.icon_path or "", 256)
            if rv then ClearIconCaches(tb) end
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Font Settings:")
            local font_changed
            font_changed, tb.font_size = r.ImGui_SliderInt(ctx, "Font Size", tb.font_size, 8, 32, "%d", r.ImGui_SliderFlags_AlwaysClamp())
            if font_changed then tb.font_needs_update = true end
            
            r.ImGui_SetNextItemWidth(ctx, -1)
            if r.ImGui_BeginCombo(ctx, "##button_font", tb.button_font or "Verdana") then
                local available_fonts = {"Verdana", "Arial", "Tahoma", "Consolas", "Courier New", "Times New Roman"}
                for _, font_name in ipairs(available_fonts) do
                    local is_selected = (tb.button_font == font_name)
                    if r.ImGui_Selectable(ctx, font_name, is_selected) then
                        tb.button_font = font_name
                        tb.font_needs_update = true
                    end
                end
                r.ImGui_EndCombo(ctx)
            end
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_EndChild(ctx)
    end
end

function ShowActionsTab(ctx, tb)
    r.ImGui_Text(ctx, "Action List Management:")
    if r.ImGui_Button(ctx, "Export Actions") then ExportActionsToFile(tb) end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Import Actions") then ImportActionsFromFile(tb) end
    r.ImGui_Separator(ctx)
    
    if #tb.actions > 0 then
        local item_to_remove = nil
        local item_to_move_up = nil
        local item_to_move_down = nil
        local item_to_add_action = nil
        local item_to_add_separator = nil
        
        for i, action in ipairs(tb.actions) do
            r.ImGui_PushID(ctx, i)
            
            if action.is_separator then
                r.ImGui_Text(ctx, i .. ": Separator")
                r.ImGui_Text(ctx, "Width:")
                r.ImGui_SameLine(ctx, 100)
                r.ImGui_SetNextItemWidth(ctx, 280)
                local width_changed, new_width = r.ImGui_SliderInt(ctx, "##width" .. i, action.width or 10, 1, 100, "%d", r.ImGui_SliderFlags_AlwaysClamp())
                if width_changed then action.width = new_width end
                
                r.ImGui_BeginGroup(ctx)
                if r.ImGui_Button(ctx, "Add Action##add_action" .. i) then item_to_add_action = i end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Add Separator##add_sep" .. i) then item_to_add_separator = i end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Up##up" .. i) and i > 1 then item_to_move_up = i end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Down##down" .. i) and i < #tb.actions then item_to_move_down = i end
                r.ImGui_SameLine(ctx)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xB34C4CFF)
                if r.ImGui_Button(ctx, "Remove##" .. i) then item_to_remove = i end
                r.ImGui_PopStyleColor(ctx)
                r.ImGui_EndGroup(ctx)
            else
                r.ImGui_BeginGroup(ctx)
                local title_text = i .. ": " .. (action.name or "Unknown")
                r.ImGui_Text(ctx, title_text)
                r.ImGui_EndGroup(ctx)
                
                r.ImGui_Text(ctx, "Command ID:")
                r.ImGui_SameLine(ctx, 100)
                local cmd_text = type(action.command_id) == "number" and tostring(action.command_id) or action.command_id or ""
                r.ImGui_SetNextItemWidth(ctx, 280)
                local cmd_changed, new_cmd = r.ImGui_InputText(ctx, "##cmd" .. i, cmd_text, 64)
                if cmd_changed then
                    local num_cmd = tonumber(new_cmd)
                    if num_cmd then
                        action.command_id = num_cmd
                        local name = GetCommandName(num_cmd)
                        if name ~= "" then action.name = name end
                    else
                        action.command_id = new_cmd
                        local cmdId = r.NamedCommandLookup(new_cmd)
                        if cmdId and cmdId ~= 0 then
                            local name = GetCommandName(cmdId)
                            if name ~= "" then action.name = name end
                        end
                    end
                end
                
                r.ImGui_Text(ctx, "Label:")
                r.ImGui_SameLine(ctx, 100)
                r.ImGui_SetNextItemWidth(ctx, 280)
                local label_changed, new_label = r.ImGui_InputText(ctx, "##label" .. i, action.label or "", 64)
                if label_changed then action.label = new_label end
                
                r.ImGui_Text(ctx, "Icon:")
                r.ImGui_SameLine(ctx, 100)
                r.ImGui_SetNextItemWidth(ctx, 280)
                local icon_changed, new_icon = r.ImGui_InputText(ctx, "##icon" .. i, action.icon or "", 64)
                if icon_changed then
                    action.icon = new_icon
                    tb.icons[action.icon] = nil
                    tb.reaper_icon_states[action.icon] = nil
                end
                
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Browse...##" .. i) then
                    r.ImGui_OpenPopup(ctx, "Icon Browser")
                    current_editing_action_index = i
                end
                
                if action.icon and action.icon ~= "" then
                    r.ImGui_SameLine(ctx)
                    local icon_texture = nil
                    local normal_state = nil
                    if tb.use_reaper_icons then
                        normal_state = select(1, LoadReaperIconStates(tb, action.icon))
                    end
                    if normal_state and normal_state.texture and r.ImGui_ValidatePtr(normal_state.texture, "ImGui_Image*") then
                        if normal_state.uv then
                            r.ImGui_Image(ctx, normal_state.texture, 24, 24,
                                normal_state.uv[1], normal_state.uv[2],
                                normal_state.uv[3], normal_state.uv[4])
                        else
                            r.ImGui_Image(ctx, normal_state.texture, 24, 24)
                        end
                    else
                        icon_texture = LoadIcon(tb, action.icon)
                        if icon_texture and r.ImGui_ValidatePtr(icon_texture, "ImGui_Image*") then
                            r.ImGui_Image(ctx, icon_texture, 24, 24)
                        else
                            r.ImGui_Text(ctx, "(Icon not found)")
                        end
                    end
                end
                
                if current_editing_action_index == i then BrowseIconsDialog(tb, i) end
                
                r.ImGui_BeginGroup(ctx)
                if r.ImGui_Button(ctx, "Add Action##add_action" .. i) then item_to_add_action = i end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Add Separator##add_sep" .. i) then item_to_add_separator = i end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Up##up" .. i) and i > 1 then item_to_move_up = i end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Down##down" .. i) and i < #tb.actions then item_to_move_down = i end
                r.ImGui_SameLine(ctx)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xB34C4CFF)
                if r.ImGui_Button(ctx, "Remove##" .. i) then item_to_remove = i end
                r.ImGui_PopStyleColor(ctx)
                r.ImGui_EndGroup(ctx)
            end
            
            r.ImGui_Separator(ctx)
            r.ImGui_PopID(ctx)
        end
        
        if item_to_add_action then
            local retval, retvals = r.GetUserInputs("Add Action", 1, "Command ID or Name:,extrawidth=100", "")
            if retval and retvals ~= "" then
                local command_id = tonumber(retvals)
                local new_action
                if command_id then
                    local name = GetCommandName(command_id)
                    new_action = {
                        command_id = command_id,
                        name = name ~= "" and name or "Command ID: " .. command_id,
                        label = name ~= "" and name:match("[^:]+$") or "Action " .. (item_to_add_action + 1),
                        icon = ""
                    }
                else
                    local cmdId = r.NamedCommandLookup(retvals)
                    if cmdId and cmdId ~= 0 then
                        local name = GetCommandName(cmdId)
                        new_action = {
                            command_id = retvals,
                            name = name ~= "" and name or "Command: " .. retvals,
                            label = name ~= "" and name:match("[^:]+$") or retvals,
                            icon = ""
                        }
                    else
                        new_action = {
                            command_id = retvals,
                            name = "Command: " .. retvals,
                            label = "Action " .. (item_to_add_action + 1),
                            icon = ""
                        }
                    end
                end
                table.insert(tb.actions, item_to_add_action + 1, new_action)
            end
        end
        
        if item_to_add_separator then
            table.insert(tb.actions, item_to_add_separator + 1, { is_separator = true, width = 10 })
        end
        
        if item_to_remove then table.remove(tb.actions, item_to_remove) end
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
        r.ImGui_Text(ctx, "No actions added yet.")
        if r.ImGui_Button(ctx, "Add First Action") then
            local retval, retvals = r.GetUserInputs("Add Action", 1, "Command ID or Name:,extrawidth=100", "")
            if retval and retvals ~= "" then
                local command_id = tonumber(retvals)
                if command_id then
                    local name = GetCommandName(command_id)
                    table.insert(tb.actions, {
                        command_id = command_id,
                        name = name ~= "" and name or "Command ID: " .. command_id,
                        label = name ~= "" and name:match("[^:]+$") or "Action 1",
                        icon = ""
                    })
                else
                    local cmdId = r.NamedCommandLookup(retvals)
                    if cmdId and cmdId ~= 0 then
                        local name = GetCommandName(cmdId)
                        table.insert(tb.actions, {
                            command_id = retvals,
                            name = name ~= "" and name or "Command: " .. retvals,
                            label = name ~= "" and name:match("[^:]+$") or retvals,
                            icon = ""
                        })
                    else
                        table.insert(tb.actions, {
                            command_id = retvals,
                            name = "Command: " .. retvals,
                            label = "Action 1",
                            icon = ""
                        })
                    end
                end
            end
        end
    end
end

function ShowOptionsTab(ctx, tb)
    r.ImGui_Text(ctx, "Update Settings:")
    
    local rv, changed = r.ImGui_SliderDouble(ctx, "Time Interval (seconds)", tb.time_interval or 0.1, 0.05, 1.0, "%.3f")
    if rv and changed ~= tb.time_interval then 
        tb.time_interval = changed
        cache_interval = changed
    end
    
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_BeginTooltip(ctx)
        r.ImGui_Text(ctx, "How often to check for window position updates")
        r.ImGui_Text(ctx, "Lower values = more responsive but higher CPU usage")
        r.ImGui_EndTooltip(ctx)
    end
    
    r.ImGui_Separator(ctx)
    
    if tb.cached_target_rect then
        r.ImGui_Text(ctx, "Current Target: " .. (tb.cached_target_rect.window_name or "Unknown"))
        r.ImGui_Text(ctx, string.format("Window Size: %dx%d", 
            tb.cached_target_rect.right - tb.cached_target_rect.left,
            tb.cached_target_rect.bottom - tb.cached_target_rect.top))
    else
        r.ImGui_Text(ctx, "Target Window: Not found or not visible")
    end
end

function ShowTabBar(ctx, tb)
    if r.ImGui_BeginTabBar(ctx, "SettingsTabs") then
        if r.ImGui_BeginTabItem(ctx, "Appearance") then
            current_tab = 0
            r.ImGui_EndTabItem(ctx)
        end
        if r.ImGui_BeginTabItem(ctx, "Actions") then
            current_tab = 1
            r.ImGui_EndTabItem(ctx)
        end
        if r.ImGui_BeginTabItem(ctx, "Options") then
            current_tab = 2
            r.ImGui_EndTabItem(ctx)
        end
        r.ImGui_EndTabBar(ctx)
    end
end

function SavePreset(name)
    local toolbars_copy = {}
    for i, tb in ipairs(toolbars) do
        local tb_copy = ShallowCopy(tb)
        tb_copy.context = nil
        tb_copy.font = nil
        tb_copy.font_needs_update = nil
        tb_copy.force_position_update = nil
        tb_copy.first_position_set = nil
        tb_copy.icons = {}
        tb_copy.reaper_icon_states = {}
        tb_copy.last_window_check = nil
        tb_copy.last_invisible_check = nil
        tb_copy.cached_target_rect = nil
        toolbars_copy[i] = tb_copy
    end
    r.SetExtState(extname_base .. "_PRESET_" .. name, "toolbars", r.serialize(toolbars_copy), true)
    if not presets[name] then
        presets[name] = true
        local preset_list = {}
        for preset_name in pairs(presets) do
            table.insert(preset_list, preset_name)
        end
        r.SetExtState(extname_base, "preset_list", r.serialize(preset_list), true)
    end
    current_preset = name
    r.SetExtState(extname_base, "current_preset", name, true)
end

function LoadPreset(name)
    local preset_data = r.GetExtState(extname_base .. "_PRESET_" .. name, "toolbars")
    if preset_data == "" then return false end
    local success, loaded_toolbars = pcall(function() return load("return " .. preset_data)() end)
    if not success or not loaded_toolbars or #loaded_toolbars == 0 then return false end
    for i, tb_data in ipairs(loaded_toolbars) do
        if i <= #toolbars then
            local tb = toolbars[i]
            local id = tb.id
            local context = tb.context
            local font = tb.font
            for k, v in pairs(tb_data) do
                if k ~= "id" and k ~= "context" and k ~= "font" then tb[k] = v end
            end
            tb.id = id
            tb.context = context
            tb.font = font
            tb.font_needs_update = true
            tb.force_position_update = true
            tb.first_position_set = false
            tb.icons = {}
            tb.reaper_icon_states = {}
            tb.last_window_check = 0
            tb.last_invisible_check = 0
            tb.cached_target_rect = nil
        else
            local new_tb = ShallowCopy(tb_data)
            new_tb.id = "toolbar_" .. os.time() .. "_" .. math.random(1000, 9999)
            new_tb.context = nil
            new_tb.font = nil
            new_tb.font_needs_update = true
            new_tb.force_position_update = true
            new_tb.first_position_set = false
            new_tb.icons = {}
            new_tb.reaper_icon_states = {}
            new_tb.last_window_check = 0
            new_tb.last_invisible_check = 0
            new_tb.cached_target_rect = nil
            table.insert(toolbars, new_tb)
        end
    end
    current_preset = name
    r.SetExtState(extname_base, "current_preset", name, true)
    return true
end

function LoadPresets()
    local preset_list_data = r.GetExtState(extname_base, "preset_list")
    if preset_list_data ~= "" then
        local success, preset_list = pcall(function() return load("return " .. preset_list_data)() end)
        if success and preset_list then
            presets = {}
            for _, name in ipairs(preset_list) do presets[name] = true end
        end
    end
    if not presets["default"] then
        presets["default"] = true
        SavePreset("default")
    end
end

function ImportActionsFromFile(toolbar)
    if not r.APIExists("JS_Dialog_BrowseForOpenFiles") then
        r.ShowMessageBox("The js_ReaScriptAPI extension is required for file import.", "Error", 0)
        return
    end
    local ret, filename = r.JS_Dialog_BrowseForOpenFiles("Import Actions", "", "",
        "REAPER Menu Files (*.ReaperMenu)\0*.ReaperMenu\0JSON Files (*.json)\0*.json\0All Files\0*.*\0", false)
    if ret and filename ~= "" then
        local file = io.open(filename, "r")
        if file then
            if filename:match("%.ReaperMenu$") then
                local icons = {}
                local actions = {}
                local content = file:read("*all")
                file:close()
                for line in content:gmatch("[^\r\n]+") do
                    local icon_index, icon_file = line:match("icon_(%d+)=([^\r\n]+)")
                    if icon_index and icon_file then icons[tonumber(icon_index)] = icon_file end
                    local item_index, command_info = line:match("item_(%d+)=([^\r\n]+)")
                    if item_index and command_info then
                        local idx = tonumber(item_index)
                        if command_info == "-1" or command_info == "" or command_info == "0" or command_info == "0 " then
                            actions[idx] = { is_separator = true, width = 10 }
                        else
                            local command_id, command_name = command_info:match("(%S+)%s+(.*)")
                            if command_id then
                                if command_id:match("^%d+$") then
                                    actions[idx] = {
                                        command_id = tonumber(command_id),
                                        name = command_name,
                                        label = command_name:match("[^:]+$") or command_name,
                                        icon = icons[idx] or ""
                                    }
                                else
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
                local imported_actions = {}
                for i = 0, 100 do
                    if actions[i] then table.insert(imported_actions, actions[i]) end
                end
                if #imported_actions > 0 then
                    local replace = r.ShowMessageBox(
                        "Do you want to replace the current actions or append the imported ones?",
                        "Import Actions", 1) == 1
                    if replace then
                        toolbar.actions = imported_actions
                    else
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
                local content = file:read("*all")
                file:close()
                local success, imported_actions = pcall(function() return load("return " .. content)() end)
                if success and type(imported_actions) == 'table' then
                    if #imported_actions > 0 then
                        local replace = r.ShowMessageBox(
                            "Do you want to replace the current actions or append the imported ones?",
                            "Import Actions", 1) == 1
                        if replace then
                            toolbar.actions = imported_actions
                        else
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

function ExportActionsToFile(toolbar)
    if not r.APIExists("JS_Dialog_BrowseForSaveFile") then
        r.ShowMessageBox("The js_ReaScriptAPI extension is required for file export.", "Error", 0)
        return
    end
    local ret, filename = r.JS_Dialog_BrowseForSaveFile("Export Actions", "", "Actions.json",
        "JSON Files (*.json)\0*.json\0All Files\0*.*\0")
    if ret and filename ~= "" then
        if not filename:match("%.json$") then filename = filename .. ".json" end
        local json = r.serialize(toolbar.actions)
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

function ShowToolbarManager()
    if not ctx or not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then
        ctx = r.ImGui_CreateContext('Custom Toolbars Manager')
        if style_loader then style_loader.ApplyFontsToContext(ctx) end
    end
    
    ApplyStyle()
    
    local header_font = GetFont("header")
    local main_font = GetFont("main")
    
    if not state.window_position_set then
        r.ImGui_SetNextWindowPos(ctx, 200, 200, r.ImGui_Cond_FirstUseEver())
        r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())
        state.window_position_set = true
    end
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Custom Toolbars Manager', true, window_flags)

    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Custom Toolbars Manager")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Custom Toolbars Manager")
        end

        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end
        
        if style_loader and style_loader.PushFont(ctx, "main") then

        r.ImGui_Separator(ctx)
        
        local content_width = r.ImGui_GetContentRegionAvail(ctx)
        local left_panel_width = 350
        
        if r.ImGui_BeginChild(ctx, "left_panel", left_panel_width, 0, 0, r.ImGui_WindowFlags_NoScrollbar()) then
            r.ImGui_SetNextItemWidth(ctx, -1)
            if r.ImGui_BeginCombo(ctx, "##preset_selector", current_preset) then
                for preset_name in pairs(presets) do
                    local is_selected = (preset_name == current_preset)
                    if r.ImGui_Selectable(ctx, preset_name, is_selected) then
                        if LoadPreset(preset_name) then current_preset = preset_name end
                    end
                end
                r.ImGui_EndCombo(ctx)
            end

            local button_width = (left_panel_width - item_spacing_x * 3) / 4
            
            if r.ImGui_Button(ctx, "Save", button_width * 0.75) then SavePreset(current_preset) end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Save As...", button_width) then
                local retval, new_name = r.GetUserInputs("Save Preset As", 1, "Preset Name:,extrawidth=100", "")
                if retval and new_name ~= "" then SavePreset(new_name) end
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Reset", button_width) then LoadPreset(current_preset) end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Create Action", button_width * 1.25) then
                local result = CreatePresetAction(current_preset)
                if result.success then
                    state.debug_info = "Action created for preset: " .. current_preset
                else
                    state.debug_info = "Failed to create action for default preset"
                end
            end
            
            r.ImGui_Separator(ctx)
            
            if r.ImGui_BeginChild(ctx, "toolbars_list", -1, -button_height_style -window_padding_y, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                for i, tb in ipairs(toolbars) do
                    r.ImGui_PushID(ctx, i)
                    r.ImGui_BeginGroup(ctx)
                    local enabled_changed, is_enabled = r.ImGui_Checkbox(ctx, "##enabled" .. i, tb.is_enabled)
                    if enabled_changed then tb.is_enabled = is_enabled end
                    r.ImGui_SameLine(ctx)
                    local content_width = r.ImGui_GetContentRegionAvail(ctx)
                    local is_selected = (i == current_toolbar_index)
                    if is_selected then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFF00FF) end
                    if r.ImGui_Selectable(ctx, tb.name, is_selected, 0, content_width) then
                        current_toolbar_index = i
                    end
                    if is_selected then r.ImGui_PopStyleColor(ctx) end
                    r.ImGui_EndGroup(ctx)
                    r.ImGui_PopID(ctx)
                end
                r.ImGui_EndChild(ctx)
            end
            
            if r.ImGui_Button(ctx, "Add Toolbar", button_width * 1.2) then
                local retval, name = r.GetUserInputs("New Toolbar", 1, "Toolbar Name:,extrawidth=100", "New Toolbar")
                if retval and name ~= "" then
                    CreateNewToolbar(name)
                    current_toolbar_index = #toolbars
                end
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Rename", button_width * 0.9) and current_toolbar_index <= #toolbars then
                local tb = toolbars[current_toolbar_index]
                local retval, name = r.GetUserInputs("Rename Toolbar", 1, "Toolbar Name:,extrawidth=100", tb.name)
                if retval and name ~= "" then
                    tb.name = name
                end
            end
            r.ImGui_SameLine(ctx)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xB34C4CFF)
            local can_remove = #toolbars > 1 and current_toolbar_index <= #toolbars
            if not can_remove then r.ImGui_BeginDisabled(ctx) end
            if r.ImGui_Button(ctx, "Remove", button_width * 0.9) and can_remove then
                local result = r.ShowMessageBox("Are you sure you want to remove this toolbar?", "Confirm Removal", 4)
                if result == 6 then
                    local deleted_toolbar = toolbars[current_toolbar_index]
                    CleanupToolbarResources(deleted_toolbar)
                    r.DeleteExtState(extname_base .. "_" .. deleted_toolbar.id, "settings", true)
                    table.remove(toolbars, current_toolbar_index)
                    if current_toolbar_index > #toolbars then current_toolbar_index = #toolbars end
                end
            end
            if not can_remove then r.ImGui_EndDisabled(ctx) end
            r.ImGui_PopStyleColor(ctx)
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Duplicate", button_width) and current_toolbar_index <= #toolbars then
                local tb = toolbars[current_toolbar_index]
                local new_tb = ShallowCopy(tb)
                new_tb.id = "toolbar_" .. os.time() .. "_" .. math.random(1000, 9999)
                new_tb.name = tb.name .. " (Copy)"
                new_tb.context = nil
                new_tb.font = nil
                new_tb.font_needs_update = true
                new_tb.force_position_update = true
                new_tb.first_position_set = false
                new_tb.icons = {}
                new_tb.reaper_icon_states = {}
                new_tb.last_window_check = 0
                new_tb.last_invisible_check = 0
                new_tb.cached_target_rect = nil
                table.insert(toolbars, new_tb)
                current_toolbar_index = #toolbars
            end
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_BeginChild(ctx, "right_panel", -1, -1, 0, r.ImGui_WindowFlags_NoScrollbar()) then
            if current_toolbar_index <= #toolbars then
                local tb = toolbars[current_toolbar_index]
                
                if r.ImGui_BeginChild(ctx, "tabs_section", -1, 32, 0, r.ImGui_WindowFlags_NoScrollbar()) then
                    ShowTabBar(ctx, tb)
                    r.ImGui_EndChild(ctx)
                end
                
                if r.ImGui_BeginChild(ctx, "tab_content", -1, -1) then
                    if current_tab == 0 then
                        ShowAppearanceTab(ctx, tb)
                    elseif current_tab == 1 then
                        ShowActionsTab(ctx, tb)
                    elseif current_tab == 2 then
                        ShowOptionsTab(ctx, tb)
                    end
                    r.ImGui_EndChild(ctx)
                end
            end
            r.ImGui_EndChild(ctx)
        end
        
            style_loader.PopFont(ctx)
        end
        
        if state.debug_info ~= "" then
            r.ImGui_Text(ctx, state.debug_info)
        end
        
        r.ImGui_End(ctx)
    end
    
    ClearStyle()
    
    return open
end

function MainLoop()
    local current_time = r.time_precise()
    
    for i, tb in ipairs(toolbars) do
        if tb.is_enabled then
            if tb.font_needs_update then 
                EnsureToolbarReady(tb)
            end
            
            if tb.force_position_update then
                tb.cached_target_rect = nil
                tb.last_window_check = 0
                tb.force_position_update = false
            end
        end
    end
    
    CheckToolbarToggleState()
    
    local open_manager = r.GetExtState(extname_base, "open_manager")
    if open_manager == "1" then
        show_toolbar_manager = true
        r.DeleteExtState(extname_base, "open_manager", false)
    end
    
    for i, tb in ipairs(toolbars) do
        if tb.is_enabled then
            local should_display = true
            if (tb.auto_hide_width or tb.auto_hide_height) and not show_toolbar_manager then
                local target_hwnd = GetTargetWindow(tb)
                if target_hwnd and tb.cached_target_rect then
                    local left, top, right, bottom = tb.cached_target_rect.left, tb.cached_target_rect.top,
                        tb.cached_target_rect.right, tb.cached_target_rect.bottom
                    local window_width = right - left
                    local window_height = bottom - top
                    local hide_for_width = (tb.auto_hide_width and window_width < tb.min_window_width)
                    local hide_for_height = (tb.auto_hide_height and window_height < tb.min_window_height)
                    if hide_for_width or hide_for_height then
                        should_display = false
                    end
                else
                    local main_hwnd = r.GetMainHwnd()
                    if main_hwnd then
                        local retval, main_LEFT, main_TOP, main_RIGHT, main_BOT = r.JS_Window_GetRect(main_hwnd)
                        if retval then
                            local main_width = main_RIGHT - main_LEFT
                            local main_height = main_BOT - main_TOP
                            local hide_for_width = (tb.auto_hide_width and main_width < tb.min_window_width)
                            local hide_for_height = (tb.auto_hide_height and main_height < tb.min_window_height)
                            if hide_for_width or hide_for_height then
                                should_display = false
                            end
                        end
                    end
                end
            end
            if show_toolbar_manager then should_display = true end
            if should_display then DisplayToolbarWidget(tb) end
        end
    end
    
    if show_toolbar_manager then
        if not ShowToolbarManager() then 
            show_toolbar_manager = false 
        end
    end
    
    r.defer(MainLoop)
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
    if not ctx or not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then
        ctx = r.ImGui_CreateContext('Custom Toolbars Manager')
        if style_loader then style_loader.ApplyFontsToContext(ctx) end
    end
    r.SetExtState(extname_base, "running", "1", false)
    LoadToolbars()
    MainLoop()
end

function Stop()
    SaveSettings()
    SaveToolbars()
    
    for _, tb in ipairs(toolbars) do
        CleanupToolbarResources(tb)
    end
    
    Cleanup()
end

function Cleanup()
    local _, _, section_id, command_id = r.get_action_context()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
    r.SetExtState(extname_base, "running", "0", false)
end

function Exit()
    SaveSettings()
    SaveToolbars()
    
    for _, tb in ipairs(toolbars) do
        CleanupToolbarResources(tb)
    end
    
    Cleanup()
end

r.atexit(Exit)
ToggleScript()