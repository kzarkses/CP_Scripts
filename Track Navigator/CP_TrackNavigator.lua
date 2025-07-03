-- @description TrackNavigator
-- @version 1.0
-- @author Cedric Pamalio

local reaper = reaper
local script_id = "CP_TrackNavigator"
local style_loader = nil
local style_path = reaper.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"

if reaper.file_exists(style_path) then 
    local loader_func = dofile(style_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local colors = {
    window_width = 280,
    window_height = 500,
    base_indent = 12,
    row_spacing = 18,
    font_size = 14,
    color_intensity = 0.8,
    background = {0.13, 0.13, 0.13, 1},
    text = {0.88, 0.88, 0.88, 1},
    selected = {0.24, 0.52, 0.78, 1},
    always_visible = {0.3, 0.69, 0.31, 1},
    always_hidden = {0.46, 0.46, 0.46, 1},
    button = {0.27, 0.27, 0.27, 1}
}

local state = {
    dock_id = 0,
    focused_tracks = {},
    font_name = "Verdana",
    last_click = 0,
    right_click = 0,
    fold_only = false,
    auto_zoom = true,
    always_visible = {},
    always_hidden = {},
    list_y = 0,
    last_change = "",
    scroll_index = 0,
    popup = nil,
    popup_x = 0,
    popup_y = 0,
    popup_width = 120,
    popup_height = 80,
    scroll_dragging = false,
    hover_button = -1,
    hover_popup = -1,
    hidden_tracks = {},
    collapse_level = -1,
    always_visible_filters = {},
    always_hidden_filters = {}
}

local _, _, section_id, command_id = reaper.get_action_context()
reaper.SetToggleCommandState(section_id, command_id, 1)
reaper.RefreshToolbar2(section_id, command_id)

local function load_settings()
    local function get_setting(key, default_value, converter, ext_key)
        local value = reaper.GetExtState(script_id, ext_key or ("settings_" .. key))
        return value ~= "" and (converter and converter(value) or value) or default_value
    end
    
    colors.window_width = get_setting("window_width", colors.window_width, tonumber)
    colors.window_height = get_setting("window_height", colors.window_height, tonumber)
    colors.base_indent = get_setting("base_indent", colors.base_indent, tonumber)
    colors.row_spacing = get_setting("row_spacing", colors.row_spacing, tonumber)
    colors.font_size = get_setting("font_size", colors.font_size, tonumber)
    colors.color_intensity = get_setting("color_intensity", colors.color_intensity, tonumber)
    state.font_name = get_setting("font_name", state.font_name)
    state.dock_id = get_setting("dock_id", 0, tonumber, "dock_id")
    
    local bg_color = get_setting("background_color", 0x212121FF, function(v) return tonumber(v, 16) end)
    colors.background = {((bg_color >> 24) & 0xFF) / 255, ((bg_color >> 16) & 0xFF) / 255, ((bg_color >> 8) & 0xFF) / 255, (bg_color & 0xFF) / 255}
    
    local sel_color = get_setting("highlight_color", 0x3D85C6FF, function(v) return tonumber(v, 16) end)
    colors.selected = {((sel_color >> 24) & 0xFF) / 255, ((sel_color >> 16) & 0xFF) / 255, ((sel_color >> 8) & 0xFF) / 255, (sel_color & 0xFF) / 255}
    
    local vis_color = get_setting("always_visible_color", 0x4CAF50FF, function(v) return tonumber(v, 16) end)
    colors.always_visible = {((vis_color >> 24) & 0xFF) / 255, ((vis_color >> 16) & 0xFF) / 255, ((vis_color >> 8) & 0xFF) / 255, (vis_color & 0xFF) / 255}
    
    local hid_color = get_setting("always_hidden_color", 0x757575FF, function(v) return tonumber(v, 16) end)
    colors.always_hidden = {((hid_color >> 24) & 0xFF) / 255, ((hid_color >> 16) & 0xFF) / 255, ((hid_color >> 8) & 0xFF) / 255, (hid_color & 0xFF) / 255}
    
    local btn_color = get_setting("button_color", 0x444444FF, function(v) return tonumber(v, 16) end)
    colors.button = {((btn_color >> 24) & 0xFF) / 255, ((btn_color >> 16) & 0xFF) / 255, ((btn_color >> 8) & 0xFF) / 255, (btn_color & 0xFF) / 255}
    
    local av_tracks = get_setting("always_visible_tracks", "", nil, "always_visible_tracks")
    if av_tracks ~= "" then 
        state.always_visible = {}
        for guid in av_tracks:gmatch("[^,]+") do 
            table.insert(state.always_visible, guid) 
        end 
    end
    
    local ah_tracks = get_setting("always_hidden_tracks", "", nil, "always_hidden_tracks")
    if ah_tracks ~= "" then 
        state.always_hidden = {}
        for guid in ah_tracks:gmatch("[^,]+") do 
            table.insert(state.always_hidden, guid) 
        end 
    end
    
    local av_filters = get_setting("always_visible_filters", "", nil, "always_visible_filters")
    if av_filters ~= "" then 
        state.always_visible_filters = {}
        for filter in av_filters:gmatch("[^,]+") do 
            table.insert(state.always_visible_filters, filter) 
        end 
    end
    
    local ah_filters = get_setting("always_hidden_filters", "", nil, "always_hidden_filters")
    if ah_filters ~= "" then 
        state.always_hidden_filters = {}
        for filter in ah_filters:gmatch("[^,]+") do 
            table.insert(state.always_hidden_filters, filter) 
        end 
    end
end

local function load_interface_settings()
    local function get_setting(key, default_value, converter, ext_key)
        local value = reaper.GetExtState(script_id, ext_key or key)
        return value ~= "" and (converter and converter(value) or value) or default_value
    end
    
    state.fold_only = get_setting("fold_only", "0", function(v) return v == "1" end)
    state.auto_zoom = get_setting("auto_zoom", "1", function(v) return v == "1" end)
end

local function save_settings()
    reaper.SetExtState(script_id, "fold_only", state.fold_only and "1" or "0", true)
    reaper.SetExtState(script_id, "auto_zoom", state.auto_zoom and "1" or "0", true)
    reaper.SetExtState(script_id, "dock_id", tostring(state.dock_id), true)
    reaper.SetExtState(script_id, "always_visible_tracks", table.concat(state.always_visible, ","), true)
    reaper.SetExtState(script_id, "always_hidden_tracks", table.concat(state.always_hidden, ","), true)
    reaper.SetExtState(script_id, "always_visible_filters", table.concat(state.always_visible_filters, ","), true)
    reaper.SetExtState(script_id, "always_hidden_filters", table.concat(state.always_hidden_filters, ","), true)
end

local function has_value(tbl, value)
    for i, item in ipairs(tbl) do 
        if item == value then 
            return true, i 
        end 
    end 
    return false 
end

local function add_value(tbl, value)
    if not has_value(tbl, value) then 
        table.insert(tbl, value) 
    end
end

local function remove_value(tbl, value)
    local _, index = has_value(tbl, value)
    if index then 
        table.remove(tbl, index) 
    end
end

local function matches_filter(track_name, filters)
    if not track_name or track_name == "" then 
        return false 
    end
    
    local lower_name = track_name:lower()
    for _, filter in ipairs(filters) do
        if filter ~= "" and lower_name:find(filter:lower(), 1, true) then 
            return true 
        end
    end
    return false
end

local function sync_focused_tracks()
    state.focused_tracks = {}
    for i = 0, reaper.CountTracks(0) - 1 do 
        local track = reaper.GetTrack(0, i)
        if reaper.IsTrackVisible(track, false) then 
            table.insert(state.focused_tracks, track) 
        end 
    end 
end

local function inherit_hierarchy()
    for i = 0, reaper.CountTracks(0) - 1 do 
        local track = reaper.GetTrack(0, i)
        local depth = reaper.GetTrackDepth(track)
        
        if depth > 0 then 
            local _, track_guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
            local parent_found = false
            
            for j = i - 1, 0, -1 do 
                local parent_track = reaper.GetTrack(0, j)
                local parent_depth = reaper.GetTrackDepth(parent_track)
                
                if parent_depth < depth then 
                    local _, parent_guid = reaper.GetSetMediaTrackInfo_String(parent_track, "GUID", "", false)
                    
                    if has_value(state.always_visible, parent_guid) then 
                        if not has_value(state.always_visible, track_guid) then 
                            add_value(state.always_visible, track_guid)
                            parent_found = true 
                        end
                    elseif has_value(state.always_hidden, parent_guid) then 
                        if not has_value(state.always_hidden, track_guid) then 
                            add_value(state.always_hidden, track_guid)
                            parent_found = true 
                        end
                    end 
                    break 
                end 
            end
            
            if parent_found then 
                save_settings() 
            end
        end 
    end 
end

local function apply_name_filters()
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local _, track_name = reaper.GetTrackName(track)
        local _, track_guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
        
        if matches_filter(track_name, state.always_visible_filters) and not has_value(state.always_visible, track_guid) then
            add_value(state.always_visible, track_guid)
            save_settings()
        elseif matches_filter(track_name, state.always_hidden_filters) and not has_value(state.always_hidden, track_guid) then
            add_value(state.always_hidden, track_guid)
            save_settings()
        end
    end
end

local function get_tracks_data()
    local tracks = {}
    local track_count = reaper.CountTracks(0)
    local hidden_depths = {}
    
    for i = 0, track_count - 1 do 
        local track = reaper.GetTrack(0, i)
        local _, track_name = reaper.GetTrackName(track)
        local depth = reaper.GetTrackDepth(track)
        local track_color = reaper.GetTrackColor(track)
        local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0 
        local is_collapsed = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT") > 0
        local _, track_guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
        local is_hidden = false
        
        for hidden_depth in pairs(hidden_depths) do 
            if depth > hidden_depth then 
                is_hidden = true
                break 
            end 
        end
        
        if is_folder and is_collapsed then 
            hidden_depths[depth] = true 
        elseif depth <= (next(hidden_depths) or math.huge) then 
            for hidden_depth in pairs(hidden_depths) do 
                if depth <= hidden_depth then 
                    hidden_depths[hidden_depth] = nil 
                end 
            end 
        end
        
        table.insert(tracks, {
            track = track,
            name = track_name,
            depth = depth,
            color = track_color,
            is_folder = is_folder,
            is_collapsed = is_collapsed,
            is_hidden = is_hidden,
            guid = track_guid
        })
    end 
    return tracks
end

local function calculate_track_color(track_color)
    if not track_color or track_color == 0 then 
        return {0.69 * colors.color_intensity, 0.69 * colors.color_intensity, 0.69 * colors.color_intensity, 1}
    end
    
    local red = (track_color & 0xFF) / 255 * colors.color_intensity 
    local green = ((track_color & 0xFF00) >> 8) / 255 * colors.color_intensity 
    local blue = ((track_color & 0xFF0000) >> 16) / 255 * colors.color_intensity 
    return {red, green, blue, 1}
end

local function get_media_range()
    if #state.focused_tracks == 0 then 
        return nil, nil 
    end 
    
    local min_time, max_time = nil, nil
    
    for _, track in ipairs(state.focused_tracks) do 
        local item_count = reaper.CountTrackMediaItems(track)
        for i = 0, item_count - 1 do 
            local item = reaper.GetTrackMediaItem(track, i)
            local start_time = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local end_time = start_time + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            
            if not min_time or start_time < min_time then 
                min_time = start_time 
            end 
            if not max_time or end_time > max_time then 
                max_time = end_time 
            end 
        end 
    end 
    return min_time, max_time
end

local function auto_zoom_to_content()
    if not state.auto_zoom or #state.focused_tracks == 0 then 
        return 
    end 
    
    local start_time, end_time = get_media_range()
    if start_time and end_time and start_time < end_time then 
        local margin = (end_time - start_time) * 0.05 
        reaper.GetSet_ArrangeView2(0, true, 0, 0, start_time - margin, end_time + margin)
    end
end

local function get_descendant_tracks(track)
    local descendants = {}
    local track_index = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1 
    local track_depth = reaper.GetTrackDepth(track)
    local track_count = reaper.CountTracks(0)
    
    for i = track_index + 1, track_count - 1 do 
        local child_track = reaper.GetTrack(0, i)
        if reaper.GetTrackDepth(child_track) <= track_depth then 
            break 
        end 
        table.insert(descendants, child_track)
    end 
    return descendants
end

local function focus_tracks(tracks, add_to_existing)
    if not add_to_existing then 
        state.focused_tracks = {}
        for i = 0, reaper.CountTracks(0) - 1 do 
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "B_SHOWINTCP", 0)
        end 
    end
    
    for i = 0, reaper.CountTracks(0) - 1 do 
        reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SOLO", 0)
    end
    
    for _, track in ipairs(tracks) do 
        if not add_to_existing or not has_value(state.focused_tracks, track) then 
            table.insert(state.focused_tracks, track)
        end 
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
        
        local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0 
        local _, folder_guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
        local folder_hidden = has_value(state.always_hidden, folder_guid)
        
        if is_folder then 
            for _, descendant in ipairs(get_descendant_tracks(track)) do 
                local _, child_guid = reaper.GetSetMediaTrackInfo_String(descendant, "GUID", "", false)
                local child_hidden = has_value(state.always_hidden, child_guid)
                local child_visible = has_value(state.always_visible, child_guid)
                
                if child_visible or (not child_hidden and not folder_hidden) then 
                    reaper.SetMediaTrackInfo_Value(descendant, "B_SHOWINTCP", 1)
                    if not add_to_existing or not has_value(state.focused_tracks, descendant) then 
                        table.insert(state.focused_tracks, descendant)
                    end 
                else
                    reaper.SetMediaTrackInfo_Value(descendant, "B_SHOWINTCP", 1)
                    if not add_to_existing or not has_value(state.focused_tracks, descendant) then 
                        table.insert(state.focused_tracks, descendant)
                    end
                end 
            end 
        end 
    end
    
    for _, guid in ipairs(state.always_visible) do 
        for i = 0, reaper.CountTracks(0) - 1 do 
            local track = reaper.GetTrack(0, i)
            local _, track_guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
            if track_guid == guid then 
                reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
                if not has_value(state.focused_tracks, track) then 
                    table.insert(state.focused_tracks, track)
                end
            end 
        end 
    end
    
    for _, guid in ipairs(state.always_hidden) do 
        local should_hide = true 
        for _, track in ipairs(tracks) do 
            local _, folder_guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
            if folder_guid == guid then 
                should_hide = false
                break 
            end
            
            local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0
            if is_folder then 
                for _, descendant in ipairs(get_descendant_tracks(track)) do 
                    local _, desc_guid = reaper.GetSetMediaTrackInfo_String(descendant, "GUID", "", false)
                    if desc_guid == guid then 
                        should_hide = false
                        break 
                    end 
                end 
                if not should_hide then 
                    break 
                end 
            end 
        end
        
        if should_hide then 
            for i = 0, reaper.CountTracks(0) - 1 do 
                local track = reaper.GetTrack(0, i)
                local _, track_guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
                if track_guid == guid and not has_value(state.always_visible, track_guid) then 
                    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
                    remove_value(state.focused_tracks, track)
                end 
            end 
        end 
    end
    
    reaper.TrackList_AdjustWindows(true)
    reaper.UpdateArrange()
    reaper.CSurf_OnScroll(0, -3000)
    reaper.Main_OnCommand(reaper.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
    auto_zoom_to_content()
end

local function show_all_tracks()
    state.focused_tracks = {}
    for i = 0, reaper.CountTracks(0) - 1 do 
        local track = reaper.GetTrack(0, i)
        local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
        local is_hidden = has_value(state.always_hidden, guid)
        local is_visible = has_value(state.always_visible, guid)
        
        if is_visible or not is_hidden then 
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
            table.insert(state.focused_tracks, track)
        else 
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
        end 
        reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
    end 
    
    reaper.TrackList_AdjustWindows(true)
    reaper.UpdateArrange()
    reaper.CSurf_OnScroll(0, -3000)
    reaper.Main_OnCommand(reaper.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
    auto_zoom_to_content()
end

local function hide_track(track)
    local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
    if not has_value(state.hidden_tracks, guid) then 
        add_value(state.hidden_tracks, guid)
    end
    
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
    
    local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0
    if is_folder then 
        for _, descendant in ipairs(get_descendant_tracks(track)) do 
            reaper.SetMediaTrackInfo_Value(descendant, "B_SHOWINTCP", 0)
        end 
    end
    
    remove_value(state.focused_tracks, track)
    reaper.TrackList_AdjustWindows(true)
    reaper.UpdateArrange()
end

local function show_track(track)
    local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
    remove_value(state.hidden_tracks, guid)
    
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
    
    local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0
    if is_folder then 
        for _, descendant in ipairs(get_descendant_tracks(track)) do 
            reaper.SetMediaTrackInfo_Value(descendant, "B_SHOWINTCP", 1)
            if not has_value(state.focused_tracks, descendant) then
                table.insert(state.focused_tracks, descendant)
            end
        end 
    end
    
    if not has_value(state.focused_tracks, track) then
        table.insert(state.focused_tracks, track)
    end
    
    reaper.TrackList_AdjustWindows(true)
    reaper.UpdateArrange()
end

local function toggle_folder(track)
    for i = 0, reaper.CountTracks(0) - 1 do
        reaper.SetTrackSelected(reaper.GetTrack(0, i), false)
    end
    reaper.SetTrackSelected(track, true)
    reaper.Main_OnCommand(1042, 0)
    reaper.TrackList_AdjustWindows(true)
    reaper.UpdateArrange()
end

local function get_max_depth()
    local max_depth = 0
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local depth = reaper.GetTrackDepth(track)
        if depth > max_depth then 
            max_depth = depth 
        end
    end
    return max_depth
end

local function expand_all_by_level()
    local collapsed_folders = {}
    
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local depth = reaper.GetTrackDepth(track)
        local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0
        local is_collapsed = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT") > 0
        
        if is_folder and is_collapsed then
            table.insert(collapsed_folders, {track = track, depth = depth})
        end
    end
    
    if #collapsed_folders == 0 then return end
    
    local min_depth = math.huge
    for _, folder in ipairs(collapsed_folders) do
        if folder.depth < min_depth then
            min_depth = folder.depth
        end
    end
    
    for _, folder in ipairs(collapsed_folders) do
        if folder.depth == min_depth then
            for j = 0, reaper.CountTracks(0) - 1 do
                reaper.SetTrackSelected(reaper.GetTrack(0, j), false)
            end
            reaper.SetTrackSelected(folder.track, true)
            reaper.Main_OnCommand(1042, 0)
        end
    end
    
    reaper.TrackList_AdjustWindows(true)
    reaper.UpdateArrange()
end

local function collapse_all_by_level()
    local expanded_folders = {}
    
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local depth = reaper.GetTrackDepth(track)
        local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0
        local is_expanded = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT") == 0
        
        if is_folder and is_expanded then
            table.insert(expanded_folders, {track = track, depth = depth})
        end
    end
    
    if #expanded_folders == 0 then return end
    
    local max_depth = -1
    for _, folder in ipairs(expanded_folders) do
        if folder.depth > max_depth then
            max_depth = folder.depth
        end
    end
    
    for _, folder in ipairs(expanded_folders) do
        if folder.depth == max_depth then
            for j = 0, reaper.CountTracks(0) - 1 do
                reaper.SetTrackSelected(reaper.GetTrack(0, j), false)
            end
            reaper.SetTrackSelected(folder.track, true)
            reaper.Main_OnCommand(1042, 0)
        end
    end
    
    reaper.TrackList_AdjustWindows(true)
    reaper.UpdateArrange()
end

local function open_settings()
    local settings_script = reaper.GetResourcePath() .. "/Scripts/CP_Scripts/Track Navigator/CP_TrackNavigator_Settings.lua"
    if reaper.file_exists(settings_script) then 
        dofile(settings_script) 
    end 
end

local function toggle_auto_zoom()
    state.auto_zoom = not state.auto_zoom
    save_settings()
end

local function toggle_fold_only()
    state.fold_only = not state.fold_only
    state.scroll_index = 0
    save_settings()
end

local function check_settings_changes()
    local change_marker = reaper.GetExtState(script_id, "settings_changed")
    if change_marker ~= "" and change_marker ~= state.last_change then 
        state.last_change = change_marker 
        load_settings()
        gfx.setfont(1, state.font_name, colors.font_size)
    end 
    sync_focused_tracks()
    inherit_hierarchy()
    apply_name_filters()
end

local function draw_popup_menu(track_data)
    local menu_items = {}
    
    if track_data.is_folder then 
        table.insert(menu_items, track_data.is_collapsed and "Expand" or "Collapse")
    end
    table.insert(menu_items, "Hide")
    table.insert(menu_items, "Visible")
    table.insert(menu_items, "Rename")
    
    local is_always_visible = has_value(state.always_visible, track_data.guid)
    table.insert(menu_items, is_always_visible and "Unmark Visible" or "Always Visible")
    
    local is_always_hidden = has_value(state.always_hidden, track_data.guid)
    table.insert(menu_items, is_always_hidden and "Unmark Hidden" or "Always Hidden")
    
    state.popup_height = (#menu_items * 18) + 16
    
    gfx.set(table.unpack(colors.background))
    gfx.rect(state.popup_x, state.popup_y, state.popup_width, state.popup_height, 1)
    gfx.set(0.6, 0.6, 0.6, 1)
    gfx.rect(state.popup_x, state.popup_y, state.popup_width, state.popup_height, 0)
    
    local y = state.popup_y + 8 
    gfx.set(table.unpack(colors.text))
    
    for i, item_text in ipairs(menu_items) do
        local action_index = i - 1
        if state.hover_popup == action_index then 
            gfx.set(0.4, 0.4, 0.4, 1)
            gfx.rect(state.popup_x + 7, y - 1, state.popup_width - 14, 18, 1)
            gfx.set(table.unpack(colors.text))
        end
        gfx.x, gfx.y = state.popup_x + 12, y 
        gfx.drawstr(item_text)
        y = y + 18 
    end
end

local function draw_interface()
    gfx.set(table.unpack(colors.background))
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    local y = 5 
    
    local button_width = (gfx.w - 20) / 3 
    local button_spacing = (gfx.w - button_width * 3) / 4 
    local button_height = 22
    
    local top_buttons = {
        {text = "ALL", func = show_all_tracks, color = colors.button},
        {text = "COL", func = collapse_all_by_level, color = colors.button},
        {text = "EXP", func = expand_all_by_level, color = colors.button}
    }
    
    for i, button in ipairs(top_buttons) do 
        local x = button_spacing + (i - 1) * (button_width + button_spacing)
        
        if state.hover_button == i then 
            gfx.set(0.5, 0.5, 0.5, 1)
        else 
            gfx.set(table.unpack(button.color))
        end
        gfx.rect(x, y, button_width, button_height, 1)
        gfx.set(table.unpack(colors.text))
        
        local text_width = gfx.measurestr(button.text)
        gfx.x, gfx.y = x + (button_width - text_width) / 2, y + (button_height - colors.font_size) / 2 
        gfx.drawstr(button.text)
    end 
    y = y + button_height + 5
    
    local bottom_buttons = {
        {text = "SET", func = open_settings, color = colors.button},
        {text = "ZOOM", func = toggle_auto_zoom, color = state.auto_zoom and colors.always_visible or colors.button},
        {text = "FOLD", func = toggle_fold_only, color = state.fold_only and colors.always_visible or colors.button}
    }
    
    for i, button in ipairs(bottom_buttons) do 
        local x = button_spacing + (i - 1) * (button_width + button_spacing)
        
        if state.hover_button == i + 3 then 
            gfx.set(0.5, 0.5, 0.5, 1)
        else 
            gfx.set(table.unpack(button.color))
        end
        gfx.rect(x, y, button_width, button_height, 1)
        gfx.set(table.unpack(colors.text))
        
        local text_width = gfx.measurestr(button.text)
        gfx.x, gfx.y = x + (button_width - text_width) / 2, y + (button_height - colors.font_size) / 2 
        gfx.drawstr(button.text)
    end 
    y = y + button_height + 10
    
    gfx.set(0.4, 0.4, 0.4, 1)
    gfx.line(5, y, gfx.w - 5, y)
    y = y + 5 
    state.list_y = y 
    
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.rect(5, y, gfx.w - 10, gfx.h - y - 5, 0)
    local list_y_offset = y + 3 
    local list_height = gfx.h - y - 8 
    local list_width = gfx.w - 25
    
    local tracks = get_tracks_data()
    local total_visible = 0 
    for _, track in ipairs(tracks) do 
        if not track.is_hidden and (not state.fold_only or track.is_folder) then 
            total_visible = total_visible + 1 
        end 
    end
    
    local max_visible = math.floor(list_height / colors.row_spacing)
    local needs_scroll = total_visible > max_visible
    
    if needs_scroll then
        local max_scroll = total_visible - max_visible 
        if state.scroll_index < 0 then 
            state.scroll_index = 0 
        elseif state.scroll_index > max_scroll then 
            state.scroll_index = max_scroll 
        end
        
        local scroll_x = gfx.w - 18 
        local scroll_height = list_height * (max_visible / total_visible)
        local scroll_y = list_y_offset + (state.scroll_index / max_scroll) * (list_height - scroll_height)
        
        gfx.set(0.4, 0.4, 0.4, 1)
        gfx.rect(scroll_x, list_y_offset, 10, list_height, 1)
        gfx.set(0.6, 0.6, 0.6, 1)
        gfx.rect(scroll_x, scroll_y, 10, scroll_height, 1)
    end
    
    local drawn = 0
    local index = 0 
    for _, track in ipairs(tracks) do 
        if track.is_hidden or (state.fold_only and not track.is_folder) then 
            goto skip 
        end
        
        if index >= state.scroll_index and drawn < max_visible then
            local track_y = list_y_offset + drawn * colors.row_spacing
            
            local is_focused = has_value(state.focused_tracks, track.track)
            local is_always_visible = has_value(state.always_visible, track.guid)
            local is_always_hidden = has_value(state.always_hidden, track.guid)
            
            if is_focused then 
                gfx.set(table.unpack(colors.selected))
            elseif is_always_visible then 
                gfx.set(table.unpack(colors.always_visible))
            elseif is_always_hidden then 
                gfx.set(table.unpack(colors.always_hidden))
            else 
                gfx.set(table.unpack(colors.background))
            end 
            
            if is_focused or is_always_visible or is_always_hidden then 
                gfx.rect(8, track_y, list_width, colors.row_spacing, 1)
            end
            
            local indent = track.depth * colors.base_indent + 15 
            gfx.x = indent 
            gfx.y = track_y + colors.row_spacing / 2 - colors.font_size / 2
            
            if track.is_folder then 
                gfx.set(table.unpack(colors.text))
                gfx.drawstr(track.is_collapsed and ">" or "v")
                gfx.x = indent + 15 
            else 
                gfx.x = indent + 15 
            end
            
            gfx.set(table.unpack(calculate_track_color(track.color)))
            local track_name = track.name 
            local name_width = gfx.measurestr(track_name)
            local max_width = list_width - indent - 15
            
            if name_width > max_width then 
                local chars = #track_name 
                while name_width > max_width and chars > 1 do 
                    chars = chars - 1 
                    track_name = track.name:sub(1, chars) .. "..." 
                    name_width = gfx.measurestr(track_name)
                end 
            end
            
            gfx.drawstr(track_name)
            track.y = track_y 
            track.height = colors.row_spacing 
            track.x = 8 
            track.width = list_width 
            drawn = drawn + 1
        end 
        index = index + 1 
        ::skip::
    end
    
    if state.popup then 
        draw_popup_menu(state.popup) 
    end 
    gfx.update()
    return tracks, top_buttons, bottom_buttons, needs_scroll, total_visible, max_visible
end

local function handle_mouse_input(tracks, top_buttons, bottom_buttons, needs_scroll, total_visible, max_visible)
    local mouse_cap = gfx.mouse_cap 
    local mouse_x, mouse_y = gfx.mouse_x, gfx.mouse_y
    
    local ctrl_pressed = mouse_cap & 4 ~= 0 
    state.hover_button, state.hover_popup = -1, -1
    
    if mouse_cap & 1 ~= 0 and state.last_click == 0 then 
        local button_width = (gfx.w - 20) / 3 
        local button_spacing = (gfx.w - button_width * 3) / 4 
        
        if mouse_y >= 5 and mouse_y <= 27 then 
            for i, button in ipairs(top_buttons) do 
                local x = button_spacing + (i - 1) * (button_width + button_spacing)
                if mouse_x >= x and mouse_x <= x + button_width then 
                    button.func()
                    break 
                end 
            end 
        elseif mouse_y >= 32 and mouse_y <= 54 then 
            for i, button in ipairs(bottom_buttons) do 
                local x = button_spacing + (i - 1) * (button_width + button_spacing)
                if mouse_x >= x and mouse_x <= x + button_width then 
                    button.func()
                    break 
                end 
            end 
        elseif state.popup and mouse_x >= state.popup_x and mouse_x <= state.popup_x + state.popup_width and mouse_y >= state.popup_y and mouse_y <= state.popup_y + state.popup_height then
            local action_y = (mouse_y - state.popup_y - 8) / 18 
            local action_index = math.floor(action_y)
            
            local current_action = 0
            
            if state.popup.is_folder then
                if action_index == current_action then 
                    toggle_folder(state.popup.track)
                    state.popup = nil
                end
                current_action = current_action + 1
            end
            
            if action_index == current_action then 
                hide_track(state.popup.track)
                state.popup = nil
            end
            current_action = current_action + 1
            
            if action_index == current_action then 
                show_track(state.popup.track)
                state.popup = nil
            end
            current_action = current_action + 1
            
            if action_index == current_action then
                local ok, name = reaper.GetUserInputs("Rename", 1, "Name:", state.popup.name)
                if ok then 
                    reaper.GetSetMediaTrackInfo_String(state.popup.track, "P_NAME", name, true)
                end
                state.popup = nil
            end
            current_action = current_action + 1
            
            if action_index == current_action then 
                local is_always_visible = has_value(state.always_visible, state.popup.guid)
                if is_always_visible then 
                    remove_value(state.always_visible, state.popup.guid)
                else 
                    add_value(state.always_visible, state.popup.guid)
                    remove_value(state.always_hidden, state.popup.guid)
                end
                
                if state.popup.is_folder then 
                    for _, descendant in ipairs(get_descendant_tracks(state.popup.track)) do 
                        local _, desc_guid = reaper.GetSetMediaTrackInfo_String(descendant, "GUID", "", false)
                        if is_always_visible then 
                            remove_value(state.always_visible, desc_guid)
                        else 
                            add_value(state.always_visible, desc_guid)
                            remove_value(state.always_hidden, desc_guid)
                        end 
                    end 
                end 
                save_settings()
                state.popup = nil
            end
            current_action = current_action + 1
            
            if action_index == current_action then 
                local is_always_hidden = has_value(state.always_hidden, state.popup.guid)
                if is_always_hidden then 
                    remove_value(state.always_hidden, state.popup.guid)
                else 
                    add_value(state.always_hidden, state.popup.guid)
                    remove_value(state.always_visible, state.popup.guid)
                end
                
                if state.popup.is_folder then 
                    for _, descendant in ipairs(get_descendant_tracks(state.popup.track)) do 
                        local _, desc_guid = reaper.GetSetMediaTrackInfo_String(descendant, "GUID", "", false)
                        if is_always_hidden then 
                            remove_value(state.always_hidden, desc_guid)
                        else 
                            add_value(state.always_hidden, desc_guid)
                            remove_value(state.always_visible, desc_guid)
                        end 
                    end 
                end 
                save_settings()
                state.popup = nil
            end
        elseif needs_scroll and mouse_x >= gfx.w - 18 then 
            state.scroll_dragging = true
        elseif state.popup and not (mouse_x >= state.popup_x and mouse_x <= state.popup_x + state.popup_width and mouse_y >= state.popup_y and mouse_y <= state.popup_y + state.popup_height) then 
            state.popup = nil
        elseif mouse_y >= state.list_y then 
            for _, track in ipairs(tracks) do
                if track.y and mouse_y >= track.y and mouse_y < track.y + track.height then 
                    if track.is_folder and mouse_x >= track.depth * colors.base_indent + 15 and mouse_x <= track.depth * colors.base_indent + 30 then 
                        toggle_folder(track.track)
                    else 
                        focus_tracks({track.track}, ctrl_pressed)
                    end 
                    break 
                end 
            end
        else 
            state.popup = nil 
        end
    elseif mouse_cap & 2 ~= 0 and state.right_click == 0 and mouse_y >= state.list_y then 
        for _, track in ipairs(tracks) do
            if track.y and mouse_y >= track.y and mouse_y < track.y + track.height then 
                state.popup = track 
                state.popup_x, state.popup_y = mouse_x, mouse_y 
                state.popup_width = 120 
                
                local menu_items = {}
                if track.is_folder then 
                    table.insert(menu_items, "Expand/Collapse")
                end
                table.insert(menu_items, "Hide")
                table.insert(menu_items, "Visible")
                table.insert(menu_items, "Rename")
                table.insert(menu_items, "Always Visible")
                table.insert(menu_items, "Always Hidden")
                
                state.popup_height = (#menu_items * 18) + 16
                
                if state.popup_x + state.popup_width > gfx.w then 
                    state.popup_x = gfx.w - state.popup_width 
                end 
                if state.popup_y + state.popup_height > gfx.h then 
                    state.popup_y = gfx.h - state.popup_height 
                end 
                break 
            end 
        end
    elseif mouse_cap & 1 == 0 and mouse_cap & 2 == 0 and state.popup then
        local dx, dy = mouse_x - state.popup_x, mouse_y - state.popup_y 
        local distance = math.sqrt(dx * dx + dy * dy)
        if distance > 300 then 
            state.popup = nil 
            state.scroll_dragging = false 
        end 
    end
    
    if mouse_y >= 5 and mouse_y <= 27 then 
        local button_width = (gfx.w - 20) / 3 
        local button_spacing = (gfx.w - button_width * 3) / 4 
        for i, button in ipairs(top_buttons) do 
            local x = button_spacing + (i - 1) * (button_width + button_spacing)
            if mouse_x >= x and mouse_x <= x + button_width then 
                state.hover_button = i 
                break 
            end 
        end 
    end
    
    if mouse_y >= 32 and mouse_y <= 54 then 
        local button_width = (gfx.w - 20) / 3 
        local button_spacing = (gfx.w - button_width * 3) / 4 
        for i, button in ipairs(bottom_buttons) do 
            local x = button_spacing + (i - 1) * (button_width + button_spacing)
            if mouse_x >= x and mouse_x <= x + button_width then 
                state.hover_button = i + 3 
                break 
            end 
        end 
    end
    
    if state.popup and mouse_x >= state.popup_x and mouse_x <= state.popup_x + state.popup_width and mouse_y >= state.popup_y and mouse_y <= state.popup_y + state.popup_height then
        local action_y = (mouse_y - state.popup_y - 8) / 18 
        state.hover_popup = math.floor(action_y)
    end
    
    if state.scroll_dragging and mouse_cap & 1 ~= 0 then
        local list_y_offset = state.list_y + 3 
        local list_height = gfx.h - state.list_y - 8 
        local max_scroll = total_visible - max_visible
        local scroll_height = list_height * (max_visible / total_visible)
        local ratio = (mouse_y - list_y_offset - scroll_height / 2) / (list_height - scroll_height)
        state.scroll_index = math.floor(ratio * max_scroll + 0.5)
        
        if state.scroll_index < 0 then 
            state.scroll_index = 0 
        elseif state.scroll_index > max_scroll then 
            state.scroll_index = max_scroll 
        end
    end
    
    if state.scroll_dragging and mouse_cap & 1 == 0 then 
        state.scroll_dragging = false 
    end
    
    local mouse_wheel = gfx.mouse_wheel 
    if mouse_wheel ~= 0 and needs_scroll then 
        state.scroll_index = state.scroll_index - (mouse_wheel > 0 and 1 or -1)
        local max_scroll = total_visible - max_visible 
        if state.scroll_index < 0 then 
            state.scroll_index = 0 
        elseif state.scroll_index > max_scroll then 
            state.scroll_index = max_scroll 
        end 
        gfx.mouse_wheel = 0 
    end
    
    state.last_click = mouse_cap & 1 
    state.right_click = mouse_cap & 2
end

local function initialize()
    load_settings()
    load_interface_settings()
    gfx.init("Track Navigator", colors.window_width, colors.window_height, state.dock_id, 100, 100)
    gfx.setfont(1, state.font_name, colors.font_size)
end

local function main_loop()
    if reaper.GetToggleCommandState(section_id, command_id) == 0 then
        gfx.quit()
        return
    end
    
    check_settings_changes()
    local tracks, top_buttons, bottom_buttons, needs_scroll, total_visible, max_visible = draw_interface()
    handle_mouse_input(tracks, top_buttons, bottom_buttons, needs_scroll, total_visible, max_visible)
    
    local dock_state = gfx.dock(-1)
    if dock_state ~= state.dock_id then 
        state.dock_id = dock_state
        save_settings()
    end
    
    if gfx.getchar() >= 0 then 
        reaper.defer(main_loop)
    end 
end 

reaper.atexit(function()
    reaper.SetToggleCommandState(section_id, command_id, 0)
    reaper.RefreshToolbar2(section_id, command_id)
end)

initialize()
main_loop()









