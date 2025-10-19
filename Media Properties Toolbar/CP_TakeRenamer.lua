-- @description TakeRenamer
-- @version 1.1
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_TakeRenamer"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local script_id = "CP_TakeRenamer_Instance"
if _G[script_id] then
    _G[script_id] = false
    return
end
_G[script_id] = true

local ctx = r.ImGui_CreateContext('Take Renamer')
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
    prefix = "",
    suffix = "",
    number_format = "",
    use_prefix = true,
    use_suffix = true,
    use_numbering = true,
    spacer_type = "none",
    base_name = "",
    window_width = 360,
    window_height = 400,
    batch_mode = false,
    auto_close = false
}

local state = {
    is_open = true,
    wwise_prefix = "",
    selected_items = {},
    need_focus = true,
    need_select_all = false,
    input_id_counter = 0,
    window_position_set = false,
    last_selection_count = 0,
    last_first_item = nil,
    need_window_focus = false,
    is_docked = false,
    force_select_docked = false
}

function FocusImGuiWindow()
    if state.need_window_focus then
        if not state.is_docked then
            r.ImGui_SetNextWindowFocus(ctx)
            
            if r.JS_Window_Find then
                r.defer(function()
                    local imgui_hwnd = r.JS_Window_Find("Take Renamer", true)
                    if imgui_hwnd then
                        r.JS_Window_SetFocus(imgui_hwnd)
                    end
                end)
            end
        end
        
        state.need_window_focus = false
    end
end

local wildcards = {
    ["$track"] = function(item) 
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local track = r.GetMediaItemTrack(item)
        if not track then return "" end
        local _, name = r.GetTrackName(track)
        return name or ""
    end,
    ["$project"] = function() 
        local _, path = r.EnumProjects(-1)
        if path then
            return path:match("([^/\\]+)%.RPP$") or path:match("([^/\\]+)%.rpp$") or "Untitled"
        end
        return "Untitled"
    end,
    ["$parent"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local track = r.GetMediaItemTrack(item)
        if not track then return "" end
        local parent = r.GetParentTrack(track)
        if parent then
            local _, name = r.GetTrackName(parent)
            return name or ""
        end
        return ""
    end,
    ["$region"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local _, num_markers, num_regions = r.CountProjectMarkers(0)
        
        for i = 0, num_markers + num_regions - 1 do
            local _, isrgn, start, ending, name, _ = r.EnumProjectMarkers2(0, i)
            if isrgn and pos >= start and pos < ending then
                return name or ""
            end
        end
        return ""
    end,
    ["$marker"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local _, num_markers, num_regions = r.CountProjectMarkers(0)
        
        local closest_marker = nil
        local closest_dist = math.huge
        
        for i = 0, num_markers + num_regions - 1 do
            local _, isrgn, start, _, name, _ = r.EnumProjectMarkers2(0, i)
            if not isrgn then
                local dist = math.abs(start - pos)
                if dist < closest_dist then
                    closest_dist = dist
                    closest_marker = name
                end
            end
        end
        return closest_marker or ""
    end,
    ["$folders"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local track = r.GetMediaItemTrack(item)
        if not track then return "" end
        local folder_names = {}
        
        while track do
            local _, track_name = r.GetTrackName(track)
            if track_name then
                track_name = track_name:gsub("%[%w+%]%s*", "")
                table.insert(folder_names, 1, track_name)
            end
            track = r.GetParentTrack(track)
        end
        
        return table.concat(folder_names, "_")
    end
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

function LoadNamingPreferences()
    local prefs = {
        prefix = r.GetExtState("MediaPropertiesToolbar", "last_prefix") or "",
        suffix = r.GetExtState("MediaPropertiesToolbar", "last_suffix") or "",
        number_format = r.GetExtState("MediaPropertiesToolbar", "number_format") or "",
        use_prefix = r.GetExtState("MediaPropertiesToolbar", "use_prefix") == "1",
        use_suffix = r.GetExtState("MediaPropertiesToolbar", "use_suffix") == "1",
        use_numbering = r.GetExtState("MediaPropertiesToolbar", "use_numbering") == "1",
        spacer_type = r.GetExtState("MediaPropertiesToolbar", "spacer_type") or "none"
    }
    
    if r.GetExtState("MediaPropertiesToolbar", "use_prefix") == "" then prefs.use_prefix = true end
    if r.GetExtState("MediaPropertiesToolbar", "use_suffix") == "" then prefs.use_suffix = true end
    if r.GetExtState("MediaPropertiesToolbar", "use_numbering") == "" then prefs.use_numbering = true end
    if r.GetExtState("MediaPropertiesToolbar", "spacer_type") == "" then prefs.spacer_type = "none" end
    
    return prefs
end

function SaveNamingPreferences(prefs)
    r.SetExtState("MediaPropertiesToolbar", "last_prefix", prefs.prefix or "", true)
    r.SetExtState("MediaPropertiesToolbar", "last_suffix", prefs.suffix or "", true)
    r.SetExtState("MediaPropertiesToolbar", "number_format", prefs.number_format or "", true)
    r.SetExtState("MediaPropertiesToolbar", "use_prefix", prefs.use_prefix and "1" or "0", true)
    r.SetExtState("MediaPropertiesToolbar", "use_suffix", prefs.use_suffix and "1" or "0", true)
    r.SetExtState("MediaPropertiesToolbar", "use_numbering", prefs.use_numbering and "1" or "0", true)
    r.SetExtState("MediaPropertiesToolbar", "spacer_type", prefs.spacer_type or "none", true)
end

function StringTrim(str, char)
    char = char or "%s"
    return str:gsub("^" .. char .. "+", ""):gsub(char .. "+$", "")
end

function ExtractBaseName(full_name)
    if not full_name or full_name == "" then return "" end
    
    local base_name = full_name
    
    base_name = base_name:gsub("%.wav$", "")
    base_name = base_name:gsub("%.flac$", "")
    base_name = base_name:gsub("%.mp3$", "")
    base_name = base_name:gsub("%.aif+$", "")
    base_name = base_name:gsub("%s+", " ")
    
    local wwise_prefix = base_name:match("^(%[%w+%])")
    if wwise_prefix then
        base_name = base_name:sub(#wwise_prefix + 1)
        base_name = base_name:match("^%s*(.-)%s*$") or ""
    end
    
    local prefs = LoadNamingPreferences()
    
    if prefs.prefix and prefs.prefix ~= "" and prefs.use_prefix then
        local escaped_prefix = prefs.prefix:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        local prefix_pattern = "^" .. escaped_prefix
        base_name = base_name:gsub(prefix_pattern, "")
        base_name = base_name:match("^%s*(.-)%s*$") or ""
    end
    
    if prefs.suffix and prefs.suffix ~= "" and prefs.use_suffix then
        local escaped_suffix = prefs.suffix:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        local suffix_pattern = escaped_suffix .. "$"
        base_name = base_name:gsub(suffix_pattern, "")
        base_name = base_name:match("^%s*(.-)%s*$") or ""
    end
    
    local number_patterns = {
        "%s+%d+%s*$",
        "_%d+%s*$", 
        "%.%d+%s*$",
        "%-%d+%s*$",
        "%(%d+%)%s*$",
        "%s+%-%-%s*%d+%s*$"
    }
    
    for _, pattern in ipairs(number_patterns) do
        local new_name = base_name:gsub(pattern, "")
        if new_name ~= base_name then
            base_name = new_name
            break
        end
    end
    
    base_name = base_name:match("^%s*(.-)%s*$") or ""
    base_name = base_name:gsub("^[_%-,]+", "")
    base_name = base_name:gsub("[_%-,]+$", "")
    
    return base_name, wwise_prefix or ""
end

function ProcessWildcards(name, item, spacer_type)
    if not item or not r.ValidatePtr(item, "MediaItem*") then 
        return name 
    end
    
    local processed_name = name
    processed_name = processed_name:gsub("%[%w+%]%s*", "")
    
    for pattern, func in pairs(wildcards) do
        local replacement = func(item)
        if replacement then
            local pattern_esc = pattern:gsub("([%%%^%$%(%)%[%]%*%+%-%?%.])", "%%%1")
            processed_name = processed_name:gsub(pattern_esc, replacement, nil, true)
        end
    end
    
    if spacer_type == "underscore" then
        processed_name = processed_name:gsub("%s+", "_")
        processed_name = processed_name:gsub("_+", "_")
        processed_name = StringTrim(processed_name, "_")
    elseif spacer_type == "hyphen" then
        processed_name = processed_name:gsub("%s+", "-")
        processed_name = processed_name:gsub("%-+", "-")
        processed_name = StringTrim(processed_name, "-")
    end
    
    return processed_name
end

function BuildFinalName(base_name, prefix, suffix, number_format, index, wwise_prefix, use_prefix, use_suffix, use_numbering)
    local final_name = base_name or ""
    
    if prefix and prefix ~= "" and use_prefix then
        final_name = prefix .. final_name
    end
    
    if suffix and suffix ~= "" and use_suffix then
        final_name = final_name .. suffix
    end
    
    if number_format and number_format ~= "" and index and use_numbering then
        local number_str = ""
        
        if number_format == "%02d" then
            number_str = string.format("_%02d", index)
        elseif number_format == "%03d" then
            number_str = string.format("_%03d", index)
        elseif number_format == " %d" then
            number_str = string.format(" %d", index)
        elseif number_format == ".%d" then
            number_str = string.format(".%d", index)
        elseif number_format == "(%d)" then
            number_str = string.format("(%d)", index)
        end
        
        final_name = final_name .. number_str
    end
    
    if wwise_prefix and wwise_prefix ~= "" then
        final_name = wwise_prefix .. final_name
    end
    
    return final_name
end

function GroupTakesByBaseName(items)
    local groups = {}
    local group_order = {}
    
    for _, item in ipairs(items) do
        if item and r.ValidatePtr(item, "MediaItem*") then
            local take = r.GetActiveTake(item)
            if take and r.ValidatePtr(take, "MediaItemTake*") then
                local current_name = ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2] or ""
                local base_name, wwise_prefix = ExtractBaseName(current_name)
                
                if not groups[base_name] then
                    groups[base_name] = {
                        items = {},
                        wwise_prefix = wwise_prefix
                    }
                    table.insert(group_order, base_name)
                end
                
                table.insert(groups[base_name].items, item)
            end
        end
    end
    
    return groups, group_order
end

function ApplyRenaming()
    local selected_count = #state.selected_items
    if selected_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    local prefs = {
        prefix = config.prefix,
        suffix = config.suffix,
        number_format = config.number_format,
        use_prefix = config.use_prefix,
        use_suffix = config.use_suffix,
        use_numbering = config.use_numbering,
        spacer_type = config.spacer_type,
        base_name = config.base_name
    }
    
    SaveNamingPreferences(prefs)
    
    if config.batch_mode then
        local groups, group_order = GroupTakesByBaseName(state.selected_items)
        local global_index = 1
        
        for _, base_name in ipairs(group_order) do
            local group = groups[base_name]
            local group_size = #group.items
            
            for i, item in ipairs(group.items) do
                if item and r.ValidatePtr(item, "MediaItem*") then
                    local take = r.GetActiveTake(item)
                    if take and r.ValidatePtr(take, "MediaItemTake*") then
                        local current_name = ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2] or ""
                        local preserved_base_name = ExtractBaseName(current_name)
                        
                        local new_name
                        if prefs.use_numbering and group_size > 1 and prefs.number_format ~= "" then
                            new_name = BuildFinalName(
                                preserved_base_name,
                                prefs.prefix,
                                prefs.suffix,
                                prefs.number_format,
                                i,
                                group.wwise_prefix,
                                prefs.use_prefix,
                                prefs.use_suffix,
                                prefs.use_numbering
                            )
                        else
                            new_name = BuildFinalName(
                                preserved_base_name,
                                prefs.prefix,
                                prefs.suffix,
                                nil,
                                nil,
                                group.wwise_prefix,
                                prefs.use_prefix,
                                prefs.use_suffix,
                                false
                            )
                        end
                        
                        new_name = ProcessWildcards(new_name, item, config.spacer_type)
                        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
                    end
                end
            end
        end
    else
        for i, item in ipairs(state.selected_items) do
            if item and r.ValidatePtr(item, "MediaItem*") then
                local take = r.GetActiveTake(item)
                if take and r.ValidatePtr(take, "MediaItemTake*") then
                    local new_name
                    if prefs.use_numbering and selected_count > 1 and prefs.number_format ~= "" then
                        new_name = BuildFinalName(
                            prefs.base_name,
                            prefs.prefix,
                            prefs.suffix,
                            prefs.number_format,
                            i,
                            state.wwise_prefix,
                            prefs.use_prefix,
                            prefs.use_suffix,
                            prefs.use_numbering
                        )
                    else
                        new_name = BuildFinalName(
                            prefs.base_name,
                            prefs.prefix,
                            prefs.suffix,
                            nil,
                            nil,
                            state.wwise_prefix,
                            prefs.use_prefix,
                            prefs.use_suffix,
                            false
                        )
                    end
                    
                    new_name = ProcessWildcards(new_name, item, config.spacer_type)
                    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
                end
            end
        end
    end
    
    r.Undo_EndBlock("Rename media items", -1)
    r.UpdateArrange()
    r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
end

function CheckSelectionChanges()
    local current_selection_count = r.CountSelectedMediaItems(0)
    local current_first_item = current_selection_count > 0 and r.GetSelectedMediaItem(0, 0) or nil
    
    if current_selection_count ~= state.last_selection_count or 
       current_first_item ~= state.last_first_item then
        
        if current_selection_count > 0 then
            state.selected_items = {}
            for i = 0, current_selection_count - 1 do
                local item = r.GetSelectedMediaItem(0, i)
                if item and r.ValidatePtr(item, "MediaItem*") then
                    table.insert(state.selected_items, item)
                end
            end
            
            if #state.selected_items > 0 and not config.batch_mode then
                local first_item = state.selected_items[1]
                local take = r.GetActiveTake(first_item)
                if take and r.ValidatePtr(take, "MediaItemTake*") then
                    local current_name = ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2] or ""
                    local base_name, wwise_prefix = ExtractBaseName(current_name)
                    config.base_name = base_name
                    state.wwise_prefix = wwise_prefix
                    state.need_select_all = true
                    state.need_focus = true
                    state.need_window_focus = true
                    state.force_select_docked = true
                    state.input_id_counter = state.input_id_counter + 1 
                end
            else
                state.need_window_focus = true
            end
        else
            state.selected_items = {}
        end
        
        state.last_selection_count = current_selection_count
        state.last_first_item = current_first_item
    end
end

function InitializeSelectedItems()
    local selected_count = r.CountSelectedMediaItems(0)
    if selected_count == 0 then
        r.ShowMessageBox("No media items selected. Please select at least one item to rename.", "Item Renamer", 0)
        return false
    end

    state.selected_items = {}
    for i = 0, selected_count - 1 do
        table.insert(state.selected_items, r.GetSelectedMediaItem(0, i))
    end

    state.last_selection_count = selected_count
    state.last_first_item = state.selected_items[1]

    local prefs = LoadNamingPreferences()
    config.prefix = prefs.prefix
    config.suffix = prefs.suffix
    config.number_format = prefs.number_format
    config.use_prefix = prefs.use_prefix
    config.use_suffix = prefs.use_suffix
    config.use_numbering = prefs.use_numbering
    config.spacer_type = prefs.spacer_type

    if #state.selected_items > 0 and not config.batch_mode then
        local first_item = state.selected_items[1]
        local take = r.GetActiveTake(first_item)
        if take then
            local current_name = ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2] or ""
            local base_name, wwise_prefix = ExtractBaseName(current_name)
            config.base_name = base_name
            state.wwise_prefix = wwise_prefix
            state.need_select_all = true
            state.need_window_focus = true
            state.input_id_counter = state.input_id_counter + 1
        end
    else
        state.need_window_focus = true
    end
    
    return true
end

function MainLoop()
    if not _G[script_id] then return end
    if not state.is_open then return end
    
    CheckSelectionChanges()
    
    if not state.window_position_set then
        local main_x, main_y, main_w, main_h = 0, 0, 0, 0
        if r.JS_Window_Find then
            local main_hwnd = r.GetMainHwnd()
            local ret, left, top, right, bottom = r.JS_Window_GetRect(main_hwnd)
            if ret then
                main_x, main_y = left, top
                main_w, main_h = right - left, bottom - top
            end
        end
        
        local x = main_x + (main_w - config.window_width) / 2
        local y = main_y + (main_h - config.window_height) / 2
        
        r.ImGui_SetNextWindowPos(ctx, x, y, r.ImGui_Cond_FirstUseEver())
        r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())
        state.window_position_set = true
    end

    ApplyStyle()
    FocusImGuiWindow()
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Take Renamer', true, window_flags)
    if visible then
        state.is_docked = r.ImGui_IsWindowDocked(ctx)
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Take Renamer")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Take Renamer")
        end

        r.ImGui_SameLine(ctx)
        local auto_button_size = header_font_size + 6
        local close_button_size = header_font_size + 6
        local buttons_width = auto_button_size + close_button_size + item_spacing_x
        local auto_x = r.ImGui_GetWindowWidth(ctx) - buttons_width - window_padding_x

        r.ImGui_SetCursorPosX(ctx, auto_x)
        local was_auto_close = config.auto_close
        if config.auto_close then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_ButtonActive()))
        end
        if r.ImGui_Button(ctx, "A", auto_button_size, auto_button_size) then
            config.auto_close = not config.auto_close
        end
        if was_auto_close then
            r.ImGui_PopStyleColor(ctx)
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Auto-close after apply")
        end

        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if style_loader and style_loader.PushFont(ctx, "main") then

        if r.ImGui_BeginChild(ctx, "ScrollableContent", -1, -1) then
            r.ImGui_Separator(ctx)
            
            local rv, new_batch_mode = r.ImGui_Checkbox(ctx, "Batch Mode (preserve individual base names)", config.batch_mode)
            if rv then
                config.batch_mode = new_batch_mode
            end
            
            if config.batch_mode then
                r.ImGui_SameLine(ctx)
                local help_color = GetStyleValue("colors.text_disabled", 0xFF808080)
                r.ImGui_TextColored(ctx, help_color, "(?)")
                if r.ImGui_IsItemHovered(ctx) then
                    r.ImGui_BeginTooltip(ctx)
                    r.ImGui_Text(ctx, "When enabled, applies prefix/suffix/numbering")
                    r.ImGui_Text(ctx, "to all selected takes while preserving")
                    r.ImGui_Text(ctx, "their individual base names.")
                    r.ImGui_EndTooltip(ctx)
                end
            end
            
            r.ImGui_Separator(ctx)
            
            if not config.batch_mode then
                r.ImGui_Text(ctx, "Base Name (without prefix/suffix/numbers):")
                
                if state.need_focus or (state.is_docked and state.force_select_docked) then
                    r.ImGui_SetKeyboardFocusHere(ctx)
                    state.need_focus = false
                end
                
                local available_width = r.ImGui_GetContentRegionAvail(ctx)
                r.ImGui_SetNextItemWidth(ctx, available_width)
                local input_flags = 0
                if state.need_select_all or (state.is_docked and state.force_select_docked) then
                    input_flags = r.ImGui_InputTextFlags_AutoSelectAll()
                end
                local input_id = "##basename" .. state.input_id_counter
                rv, new_base_name = r.ImGui_InputText(ctx, input_id, config.base_name, input_flags)
                if rv then
                    config.base_name = new_base_name
                end
                
                state.need_select_all = false
                state.force_select_docked = false

                if r.ImGui_IsItemFocused(ctx) and 
                (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()) or 
                    r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())) then
                    ApplyRenaming()
                    if config.auto_close then
                        open = false
                    end
                end
                
                r.ImGui_Separator(ctx)
            end
            
            rv, config.use_prefix = r.ImGui_Checkbox(ctx, "Use Prefix", config.use_prefix)
            if config.use_prefix then
                r.ImGui_SameLine(ctx)
                local available_width = r.ImGui_GetContentRegionAvail(ctx)
                r.ImGui_SetNextItemWidth(ctx, available_width)
                rv, config.prefix = r.ImGui_InputText(ctx, "##prefix", config.prefix)
            end
            
            rv, config.use_suffix = r.ImGui_Checkbox(ctx, "Use Suffix", config.use_suffix)
            if config.use_suffix then
                r.ImGui_SameLine(ctx)
                local available_width = r.ImGui_GetContentRegionAvail(ctx)
                r.ImGui_SetNextItemWidth(ctx, available_width)
                rv, config.suffix = r.ImGui_InputText(ctx, "##suffix", config.suffix)
            end
            
            local multiple_items = #state.selected_items > 1
            rv, config.use_numbering = r.ImGui_Checkbox(ctx, "Use Numbering" .. (multiple_items and "" or " (multiple items only)"), 
                                                        config.use_numbering)

            r.ImGui_Separator(ctx)
            
            if config.use_numbering then
                r.ImGui_Text(ctx, "Number Format:")
                
                local formats = {
                    { label = "1", value = " %d" },
                    { label = "01", value = "%02d" },
                    { label = "001", value = "%03d" },
                    { label = "(1)", value = "(%d)" },
                    { label = ".1", value = ".%d" }
                }
                
                local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 8)
                for i, format in ipairs(formats) do
                    if i > 1 then r.ImGui_SameLine(ctx, 0, item_spacing_x) end
                    
                    local is_selected = config.number_format == format.value
                    if r.ImGui_RadioButton(ctx, format.label, is_selected) and not is_selected then
                        config.number_format = format.value
                    end
                end
            end
            
            r.ImGui_Separator(ctx)
            
            r.ImGui_Text(ctx, "Space Replacement:")
            
            local spacer_types = {
                { label = "None", value = "none" },
                { label = "Underscore (_)", value = "underscore" },
                { label = "Hyphen (-)", value = "hyphen" }
            }
            
            local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 8)
            for i, spacer in ipairs(spacer_types) do
                if i > 1 then r.ImGui_SameLine(ctx, 0, item_spacing_x) end
                
                local is_selected = config.spacer_type == spacer.value
                if r.ImGui_RadioButton(ctx, spacer.label, is_selected) and not is_selected then
                    config.spacer_type = spacer.value
                end
            end
            
            r.ImGui_Separator(ctx)
            
            r.ImGui_Text(ctx, "Preview:")
            
            local preview_name
            if config.batch_mode then
                if #state.selected_items > 0 then
                    local groups, group_order = GroupTakesByBaseName(state.selected_items)
                    local preview_lines = {}
                    
                    for i, base_name in ipairs(group_order) do
                        local group = groups[base_name]
                        local group_size = #group.items
                        
                        if group_size > 1 and config.use_numbering and config.number_format ~= "" then
                            local example_name = BuildFinalName(
                                base_name,
                                config.prefix,
                                config.suffix,
                                config.number_format,
                                1,
                                group.wwise_prefix,
                                config.use_prefix,
                                config.use_suffix,
                                config.use_numbering
                            )
                            example_name = ProcessWildcards(example_name, group.items[1], config.spacer_type)
                            table.insert(preview_lines, example_name .. " (" .. group_size .. " items)")
                        else
                            local example_name = BuildFinalName(
                                base_name,
                                config.prefix,
                                config.suffix,
                                nil,
                                nil,
                                group.wwise_prefix,
                                config.use_prefix,
                                config.use_suffix,
                                false
                            )
                            example_name = ProcessWildcards(example_name, group.items[1], config.spacer_type)
                            table.insert(preview_lines, example_name)
                        end
                        
                        if i >= 3 then
                            table.insert(preview_lines, "...")
                            break
                        end
                    end
                    
                    preview_name = table.concat(preview_lines, "\n")
                else
                    preview_name = "No items selected"
                end
            else
                if multiple_items then
                    local example1 = BuildFinalName(
                        config.base_name,
                        config.prefix,
                        config.suffix,
                        config.use_numbering and config.number_format or nil,
                        1,
                        state.wwise_prefix,
                        config.use_prefix,
                        config.use_suffix,
                        config.use_numbering
                    )
                    example1 = ProcessWildcards(example1, state.selected_items[1], config.spacer_type)
                    
                    local example2 = BuildFinalName(
                        config.base_name,
                        config.prefix,
                        config.suffix,
                        config.use_numbering and config.number_format or nil,
                        2,
                        state.wwise_prefix,
                        config.use_prefix,
                        config.use_suffix,
                        config.use_numbering
                    )
                    example2 = ProcessWildcards(example2, state.selected_items[2] or state.selected_items[1], config.spacer_type)
                    
                    preview_name = example1 .. "\n" .. example2 .. "\n..."
                else
                    preview_name = BuildFinalName(
                        config.base_name,
                        config.prefix,
                        config.suffix,
                        nil,
                        nil,
                        state.wwise_prefix,
                        config.use_prefix,
                        config.use_suffix,
                        false
                    )
                    preview_name = ProcessWildcards(preview_name, state.selected_items[1], config.spacer_type)
                end
            end
            
            local highlight_text_color = GetStyleValue("colors.slider_grab_active", 0xFF4444FF)
            r.ImGui_TextColored(ctx, highlight_text_color, preview_name)
            
            r.ImGui_Separator(ctx)

            r.ImGui_Text(ctx, "Available wildcards:")
            r.ImGui_Text(ctx, "$track $parent $region $marker $project $folders")
             
            local content_width = r.ImGui_GetContentRegionAvail(ctx)
            local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 8)
            local button_width = (content_width - item_spacing_x) / 2
            
            if r.ImGui_Button(ctx, "Apply", button_width) then
                ApplyRenaming()
                if config.auto_close then
                    open = false
                end
            end
            
            r.ImGui_SameLine(ctx, 0, item_spacing_x)
            
            if r.ImGui_Button(ctx, "Cancel", button_width) then
                state.is_open = false
                open = false
            end
            
            r.ImGui_EndChild(ctx)
        end
        
            style_loader.PopFont(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    ClearStyle()
    
    r.PreventUIRefresh(-1)
    
    if not open then
        _G[script_id] = false
        return
    end
    
    if open and state.is_open then
        r.defer(MainLoop)
    else
        state.is_open = false
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
    if not InitializeSelectedItems() then
        return
    end
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