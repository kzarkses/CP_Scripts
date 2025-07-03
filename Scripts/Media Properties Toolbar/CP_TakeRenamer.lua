--[[
@description CP_TakeRenamer
@version 1.0
@author Cedric Pamallo
--]]
local r = reaper

local sl = nil
local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp) then local lf = dofile(sp) if lf then sl = lf() end end

local script_id = "CP_TakeRenamer_Instance"
if _G[script_id] then
    _G[script_id] = false
    return
end
_G[script_id] = true

local ctx = r.ImGui_CreateContext('Take Renamer')
if sl then sl.applyFontsToContext(ctx) end

local pc, pv = 0, 0

function getStyleFont(font_name, context)
  if sl then
    return sl.getFont(context or ctx, font_name)
  end
  return nil
end

local renamer = {
    isOpen = true,
    name = "",
    base_name = "",
    wwise_prefix = "",
    prefix = "",
    suffix = "",
    numberFormat = "",
    use_prefix = true,
    use_suffix = true,
    use_numbering = true,
    selected_items = {},
    window_width = 360,
    window_height = 360,
    need_focus = true,
    window_position_set = false
}

function string.trim(str, char)
    char = char or "%s"
    return str:gsub("^" .. char .. "+", ""):gsub(char .. "+$", "")
end

local wildcards = {
    ["$track"] = function(item) 
        local track = r.GetMediaItemTrack(item)
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
        local track = r.GetMediaItemTrack(item)
        local parent = r.GetParentTrack(track)
        if parent then
            local _, name = r.GetTrackName(parent)
            return name or ""
        end
        return ""
    end,
 
    ["$region"] = function(item)
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
        local track = r.GetMediaItemTrack(item)
        local folder_names = {}
        
        while track do
            local _, trackName = r.GetTrackName(track)
            if trackName then
                trackName = trackName:gsub("%[%w+%]%s*", "")
                table.insert(folder_names, 1, trackName)
            end
            track = r.GetParentTrack(track)
        end
        
        return table.concat(folder_names, "_")
    end
}

function loadNamingPreferences()
    local prefs = {
        prefix = r.GetExtState("MediaPropertiesToolbar", "last_prefix") or "",
        suffix = r.GetExtState("MediaPropertiesToolbar", "last_suffix") or "",
        number_format = r.GetExtState("MediaPropertiesToolbar", "number_format") or "",
        use_prefix = r.GetExtState("MediaPropertiesToolbar", "use_prefix") == "1",
        use_suffix = r.GetExtState("MediaPropertiesToolbar", "use_suffix") == "1",
        use_numbering = r.GetExtState("MediaPropertiesToolbar", "use_numbering") == "1"
    }
    
    if r.GetExtState("MediaPropertiesToolbar", "use_prefix") == "" then prefs.use_prefix = true end
    if r.GetExtState("MediaPropertiesToolbar", "use_suffix") == "" then prefs.use_suffix = true end
    if r.GetExtState("MediaPropertiesToolbar", "use_numbering") == "" then prefs.use_numbering = true end
    
    return prefs
end

function saveNamingPreferences(prefs)
    r.SetExtState("MediaPropertiesToolbar", "last_prefix", prefs.prefix or "", true)
    r.SetExtState("MediaPropertiesToolbar", "last_suffix", prefs.suffix or "", true)
    r.SetExtState("MediaPropertiesToolbar", "number_format", prefs.number_format or "", true)
    r.SetExtState("MediaPropertiesToolbar", "use_prefix", prefs.use_prefix and "1" or "0", true)
    r.SetExtState("MediaPropertiesToolbar", "use_suffix", prefs.use_suffix and "1" or "0", true)
    r.SetExtState("MediaPropertiesToolbar", "use_numbering", prefs.use_numbering and "1" or "0", true)
end

function extractBaseName(full_name)
    if not full_name then return "" end
    
    local base_name = full_name
    
    base_name = base_name:gsub("%.wav$", "")
    base_name = base_name:gsub("%s+", " ")
    
    local wwise_prefix = base_name:match("^%[%w+%]")
    if wwise_prefix then
        base_name = base_name:sub(#wwise_prefix + 1)
    end
    
    local prefs = loadNamingPreferences()
    
    if prefs.prefix and prefs.prefix ~= "" and prefs.use_prefix then
        local escaped_prefix = prefs.prefix:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        local prefix_pattern = "^" .. escaped_prefix
        base_name = base_name:gsub(prefix_pattern, "")
    end
    
    local number_removed = false
    local number_patterns = {
        {pattern = "%s+%d+%s*$"},
        {pattern = "_%d+%s*$"},
        {pattern = "%.%d+%s*$"},
        {pattern = "%(%d+%)%s*$"},
        {pattern = "%s+%-%-%s*%d+%s*$"},
    }
    
    for _, pat in ipairs(number_patterns) do
        local new_name = base_name:gsub(pat.pattern, "")
        if new_name ~= base_name then
            base_name = new_name
            number_removed = true
            break
        end
    end
    
    if prefs.suffix and prefs.suffix ~= "" and prefs.use_suffix then
        local escaped_suffix = prefs.suffix:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        local suffix_pattern = escaped_suffix .. "$"
        base_name = base_name:gsub(suffix_pattern, "")
    end
    
    base_name = base_name:match("^%s*(.-)%s*$") or ""
    base_name = base_name:gsub(",%s*$", "")
    
    return base_name, wwise_prefix
end

function processWildcards(name, item)
    if not item then return name end
    
    local processed_name = name
    processed_name = processed_name:gsub("%[%w+%]%s*", "")
    
    for pattern, func in pairs(wildcards) do
        local replacement = func(item)
        if replacement then
            local pattern_esc = pattern:gsub("([%%%^%$%(%)%[%]%*%+%-%?%.])", "%%%1")
            processed_name = processed_name:gsub(pattern_esc, replacement, nil, true)
        end
    end
    
    processed_name = processed_name:gsub("%s+", "_")
    processed_name = processed_name:gsub("_+", "_")
    processed_name = processed_name:trim("_")
    
    return processed_name
end

function buildFinalName(base_name, prefix, suffix, number_format, index, wwise_prefix, use_prefix, use_suffix, use_numbering)
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

function applyRenaming()
    local selected_count = #renamer.selected_items
    if selected_count == 0 then return end
    
    r.Undo_BeginBlock()
    
    local prefs = {
        prefix = renamer.prefix,
        suffix = renamer.suffix,
        number_format = renamer.numberFormat,
        use_prefix = renamer.use_prefix,
        use_suffix = renamer.use_suffix,
        use_numbering = renamer.use_numbering,
        base_name = renamer.base_name
    }
    
    saveNamingPreferences(prefs)
    
    for i, item in ipairs(renamer.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local new_name
            if prefs.use_numbering and selected_count > 1 and prefs.number_format ~= "" then
                new_name = buildFinalName(
                    prefs.base_name,
                    prefs.prefix,
                    prefs.suffix,
                    prefs.number_format,
                    i,
                    renamer.wwise_prefix,
                    prefs.use_prefix,
                    prefs.use_suffix,
                    prefs.use_numbering
                )
            else
                new_name = buildFinalName(
                    prefs.base_name,
                    prefs.prefix,
                    prefs.suffix,
                    nil,
                    nil,
                    renamer.wwise_prefix,
                    prefs.use_prefix,
                    prefs.use_suffix,
                    false
                )
            end
            
            new_name = processWildcards(new_name, item)
            r.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
        end
    end
    
    r.Undo_EndBlock("Rename media items", -1)
    r.UpdateArrange()
    r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
end

function MainLoop()
    if not _G[script_id] then return end
    if not renamer.isOpen then
        return
    end
    
    if sl then
        local success, colors, vars = sl.applyToContext(ctx)
        if success then
            pc, pv = colors, vars
        end
    end
    
    if not renamer.window_position_set then
        local main_x, main_y, main_w, main_h = 0, 0, 0, 0
        if r.JS_Window_Find then
            local main_hwnd = r.GetMainHwnd()
            local ret, left, top, right, bottom = r.JS_Window_GetRect(main_hwnd)
            if ret then
                main_x, main_y = left, top
                main_w, main_h = right - left, bottom - top
            end
        end
        
        local x = main_x + (main_w - renamer.window_width) / 2
        local y = main_y + (main_h - renamer.window_height) / 2
        
        r.ImGui_SetNextWindowPos(ctx, x, y, r.ImGui_Cond_FirstUseEver())
        r.ImGui_SetNextWindowSize(ctx, renamer.window_width, renamer.window_height, r.ImGui_Cond_FirstUseEver())
        renamer.window_position_set = true
    end
    
    -- local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoCollapse()
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, "Take Renamer", true, window_flags)
    
    if visible then
        local main_font = getStyleFont("main", ctx)
        if main_font then
            r.ImGui_PushFont(ctx, main_font)
        end
        
        local header_font = getStyleFont("header", ctx)
        if header_font then
            r.ImGui_PushFont(ctx, header_font)
            r.ImGui_Text(ctx, "Take Renamer")
            r.ImGui_PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Take Renamer")
        end
        
        r.ImGui_SameLine(ctx)
        local close_x = r.ImGui_GetWindowWidth(ctx) - 30
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", 22, 22) then
            open = false
        end
        
        if r.ImGui_BeginChild(ctx, "ScrollableContent", -1, -1) then

            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)
            
            r.ImGui_Text(ctx, "Base Name (without prefix/suffix/numbers):")
            
            if renamer.need_focus then
                r.ImGui_SetKeyboardFocusHere(ctx)
                renamer.need_focus = false
            end
            
            local rv, new_base_name = r.ImGui_InputText(ctx, "##basename", renamer.base_name)
            if rv then
                renamer.base_name = new_base_name
            end

            if r.ImGui_IsItemFocused(ctx) and 
            (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()) or 
                r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())) then
                applyRenaming()
                renamer.isOpen = false
                open = false
            end
            
            r.ImGui_Spacing(ctx)
            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)
            
            rv, renamer.use_prefix = r.ImGui_Checkbox(ctx, "Use Prefix", renamer.use_prefix)
            if renamer.use_prefix then
                r.ImGui_SameLine(ctx)
                r.ImGui_SetNextItemWidth(ctx, 200)
                rv, renamer.prefix = r.ImGui_InputText(ctx, "##prefix", renamer.prefix)
            end
            
            r.ImGui_Spacing(ctx)
            
            rv, renamer.use_suffix = r.ImGui_Checkbox(ctx, "Use Suffix", renamer.use_suffix)
            if renamer.use_suffix then
                r.ImGui_SameLine(ctx)
                r.ImGui_SetNextItemWidth(ctx, 200)
                rv, renamer.suffix = r.ImGui_InputText(ctx, "##suffix", renamer.suffix)
            end
            
            r.ImGui_Spacing(ctx)
            
            local multiple_items = #renamer.selected_items > 1
            rv, renamer.use_numbering = r.ImGui_Checkbox(ctx, "Use Numbering" .. (multiple_items and "" or " (multiple items only)"), 
                                                        renamer.use_numbering)
            
            if renamer.use_numbering then
                r.ImGui_Text(ctx, "Number Format:")
                
                local formats = {
                    { label = "1", value = " %d" },
                    { label = "01", value = "%02d" },
                    { label = "001", value = "%03d" },
                    { label = "(1)", value = "(%d)" },
                    { label = ".1", value = ".%d" }
                }
                
                for i, format in ipairs(formats) do
                    if i > 1 then r.ImGui_SameLine(ctx) end
                    
                    local is_selected = renamer.numberFormat == format.value
                    if r.ImGui_RadioButton(ctx, format.label, is_selected) and not is_selected then
                        renamer.numberFormat = format.value
                    end
                end
            end
            
            r.ImGui_Spacing(ctx)
            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)
            
            r.ImGui_Text(ctx, "Preview:")
            
            local preview_name
            if multiple_items then
                local example1 = buildFinalName(
                    renamer.base_name,
                    renamer.prefix,
                    renamer.suffix,
                    renamer.use_numbering and renamer.numberFormat or nil,
                    1,
                    renamer.wwise_prefix,
                    renamer.use_prefix,
                    renamer.use_suffix,
                    renamer.use_numbering
                )
                
                local example2 = buildFinalName(
                    renamer.base_name,
                    renamer.prefix,
                    renamer.suffix,
                    renamer.use_numbering and renamer.numberFormat or nil,
                    2,
                    renamer.wwise_prefix,
                    renamer.use_prefix,
                    renamer.use_suffix,
                    renamer.use_numbering
                )
                
                preview_name = example1 .. "\n" .. example2 .. "\n..."
            else
                preview_name = buildFinalName(
                    renamer.base_name,
                    renamer.prefix,
                    renamer.suffix,
                    nil,
                    nil,
                    renamer.wwise_prefix,
                    renamer.use_prefix,
                    renamer.use_suffix,
                    false
                )
            end
            
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAFFAAFF)
            r.ImGui_TextWrapped(ctx, preview_name)
            r.ImGui_PopStyleColor(ctx)
            
            r.ImGui_Spacing(ctx)
            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)
            
            r.ImGui_Text(ctx, "Available wildcards:")
            r.ImGui_Text(ctx, "$track $parent $region $marker $project $folders")
            
            r.ImGui_Spacing(ctx)
            
            local button_width = (r.ImGui_GetWindowWidth(ctx) - 20) / 2
            
            if r.ImGui_Button(ctx, "Apply", button_width) then
                applyRenaming()
                renamer.isOpen = false
                open = false
            end
            
            r.ImGui_SameLine(ctx)
            
            if r.ImGui_Button(ctx, "Cancel", button_width) then
                renamer.isOpen = false
                open = false
            end
            
            r.ImGui_EndChild(ctx)
        end
        if main_font then
                r.ImGui_PopFont(ctx)
        end
        r.ImGui_End(ctx)
    end
    
    if sl then
        sl.clearStyles(ctx, pc, pv)
    end
    
    if not open then
        _G[script_id] = false
        return
    end
    
    r.defer(MainLoop)

    -- if open and renamer.isOpen then
    --     r.defer(MainLoop)
    -- else
    --     renamer.isOpen = false
    -- end
end

local selected_count = r.CountSelectedMediaItems(0)
if selected_count == 0 then
    r.ShowMessageBox("No media items selected. Please select at least one item to rename.", "Item Renamer", 0)
    return
end

for i = 0, selected_count - 1 do
    table.insert(renamer.selected_items, r.GetSelectedMediaItem(0, i))
end

if #renamer.selected_items > 0 then
    local first_item = renamer.selected_items[1]
    local take = r.GetActiveTake(first_item)
    if take then
        local current_name = ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2] or ""
        local base_name, wwise_prefix = extractBaseName(current_name)
        renamer.base_name = base_name
        renamer.wwise_prefix = wwise_prefix
        
        local prefs = loadNamingPreferences()
        renamer.prefix = prefs.prefix
        renamer.suffix = prefs.suffix
        renamer.numberFormat = prefs.number_format
        renamer.use_prefix = prefs.use_prefix
        renamer.use_suffix = prefs.use_suffix
        renamer.use_numbering = prefs.use_numbering
    end
end

MainLoop()


