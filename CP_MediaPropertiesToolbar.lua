-- CP_MediaPropertiesToolbar.lua
--[[
@description Media Properties Toolbar
@version 1.4
@author Claude
@about
  Display and edit media item properties in a toolbar
  With improved multi-item editing support and ImGui name dialog
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

-- Settings file path
local settings_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/MediaPropertiesToolbar_settings.ini"

-- Configuration variables
local config = {
    -- Interface
    font_name = "FiraSans-Regular",
    font_size = 15,
    entry_height = 20,
    entry_width = 60,
    name_width = 220,
    source_width = 220,
    text_color = {0.70, 0.70, 0.70, 1},
    background_color = {0.155, 0.155, 0.155, 1},
    frame_color = {0.155, 0.155, 0.155, 1},
    frame_color_active = {0.21, 0.7, 0.63, 0.4},

    colors = {
        text_normal = {0.75, 0.75, 0.75, 1.0},
        text_modified = {0.0, 0.8, 0.6, 1.0},
        text_negative = {0.8, 0.4, 0.6, 1.0},
        text_bool_on = {0.0, 0.8, 0.0, 1.0},
        text_bool_off = {0.8, 0.0, 0.0, 1.0}
    },

    tooltip_bg = {0.2, 0.2, 0.2, 0.95},
    tooltip_text = {0.9, 0.9, 0.9, 1.0},

    min_widget_width = 60,

    widget_priority = {
    "name", 
    "source", 
    "position", 
    "length", 
    "snap",
    "fadein", 
    "fadeout", 
    "volume", 
    "takevol", 
    "pitch", 
    "preserve_pitch",
    "pan", 
    "rate", 
    "mute"
    },

    widget_weights = {     -- Poids relatif de chaque widget pour le redimensionnement
    name = 2.5,                 -- La colonne "name" prendra 3x plus de place que les autres
    source = 2.5,               -- La colonne "source" également
    },

    mouse = {
        volume_sensitivity = 0.05,
        pitch_sensitivity = 0.1,
        pan_sensitivity = 0.01,
        rate_sensitivity = 0.01,
        time_sensitivity = 0.01
    },

    volume = {
        min_db = -120,
        max_db = 120,
        step_db = 1,
        drag_sensitivity = 0.05
    },

    pitch = {
        min = -96,
        max = 96,
        step = 1,
        drag_sensitivity = 0.1
    },

    pan = {
        min = -1,
        max = 1,
        step = 0.1,
        drag_sensitivity = 0.01
    },

    rate = {
        min = 0,
        max = 100,
        step = 0.1,
        drag_sensitivity = 0.01
    },

    time = {
        step = 1,
        drag_seconds = 0.01,
        drag_minutes = 0.6,
        drag_milliseconds = 0.001
    },

    db_to_linear = function(db)
        return 10^(db/20)
    end,
    
    linear_to_db = function(linear)
        if linear <= 0 then return -120 end
        return 20 * math.log(linear, 10)
    end,
   
    clamp = function(value, min, max)
        return math.max(min, math.min(max, value))
    end
}

state = {
    last_item = nil,
    last_mouse_cap = 0,
    last_mouse_x = 0,
    last_mouse_y = 0,
    drag_active = false,
    active_control = nil,
    window_x = 0,
    window_y = 0,
    dock_id = 0,
    is_docked = false,
    last_settings_update = "",
    last_click_time = 0,
    visible_widgets = {},
    double_click_handled = false, -- Nouvelle variable pour suivre le traitement des doubles clics
    double_click_cooldown = 0     -- Pour éviter les déclenchements multiples
}

-- Variables for the ImGui name dialog
local nameDialog = {
    ctx = nil,           -- ImGui context for name dialog
    isOpen = false,      -- Whether dialog is open
    name = "",           -- Current name
    prefix = "",         -- Prefix
    suffix = "",         -- Suffix
    numberFormat = "",   -- Number format
    use_prefix = true,   -- Whether to use prefix
    use_suffix = true,   -- Whether to use number suffix
    use_numbering = true, -- Whether to use numbering
    result = nil,        -- Result to return to main function
    selected_items = {}, -- Items to be renamed
    window_width = 400,  -- Dialog window width
    window_height = 300, -- Dialog window height
    need_focus = false   -- Flag to set focus on input field
}

local wildcards = 
{
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
                trackName = trackName:gsub("%[%w+%]%s*", "") -- Remove tags
                table.insert(folder_names, 1, trackName)
            end
            track = r.GetParentTrack(track)
        end
        
        return table.concat(folder_names, "_")
    end
}

-- Load settings from file
function loadSettings()
    local file = io.open(settings_path, "r")
    if not file then return end
    
    local section
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
            
            if section == "colors" then
                if value:match("^{.+}$") then
                    -- Parse color array
                    local values = {}
                    for v in value:sub(2, -2):gmatch("[^,]+") do
                        table.insert(values, tonumber(v) or 0)
                    end
                    if #values == 4 then
                        config.colors[key] = values
                    end
                end
            elseif section == "font" then
                if key == "name" then
                    config.font_name = value
                elseif key == "size" then
                    config.font_size = tonumber(value) or config.font_size
                end
            elseif section == "layout" then
                if key == "entry_height" then
                    config.entry_height = tonumber(value) or config.entry_height
                elseif key == "name_width" then
                    config.name_width = tonumber(value) or config.name_width
                elseif key == "source_width" then
                    config.source_width = tonumber(value) or config.source_width
                end
            -- Nouvelle condition pour gérer les entrées de couleur au niveau racine (sans section)
            elseif not section and (key == "background_color" or key == "text_color" or 
                   key == "frame_color" or key == "frame_color_active") then
                if value:match("^{.+}$") then
                    -- Parse color array
                    local values = {}
                    for v in value:sub(2, -2):gmatch("[^,]+") do
                        table.insert(values, tonumber(v) or 0)
                    end
                    if #values == 4 then
                        config[key] = values
                    end
                end
            end
        end
    end
    
    file:close()
end

function checkForSettingsUpdates()
    local last_change = r.GetExtState("MediaPropertiesToolbar", "settings_changed")
    local layout_changed = r.GetExtState("MediaPropertiesToolbar", "layout_changed") == "1"
    
    if (last_change ~= "" and last_change ~= state.last_settings_update) or layout_changed then
        state.last_settings_update = last_change
        loadSettings()
        
        -- Reset font and UI elements when layout changes
        if layout_changed then
            gfx.setfont(1, config.font_name, config.font_size)
            r.SetExtState("MediaPropertiesToolbar", "layout_changed", "0", false)
            -- Force a window refresh
            gfx.quit()
            init()
        end
        
        return true
    end
    return false
end
-- Load saved dock state
function loadDockState()
    state.dock_id = tonumber(r.GetExtState("MediaPropertiesToolbar", "dock_id")) or 0
    state.is_docked = r.GetExtState("MediaPropertiesToolbar", "is_docked") == "1"
end

-- Save dock state
function saveDockState()
    r.SetExtState("MediaPropertiesToolbar", "dock_id", tostring(state.dock_id), true)
    r.SetExtState("MediaPropertiesToolbar", "is_docked", state.is_docked and "1" or "0", true)
end

function resetPreferences()
    r.SetExtState("MediaPropertiesToolbar", "last_prefix", "", true)
    r.SetExtState("MediaPropertiesToolbar", "last_suffix", "", true)
    r.SetExtState("MediaPropertiesToolbar", "number_format", "", true)
    r.SetExtState("MediaPropertiesToolbar", "use_prefix", "1", true)
    r.SetExtState("MediaPropertiesToolbar", "use_suffix", "1", true)
    r.SetExtState("MediaPropertiesToolbar", "use_numbering", "1", true)
end

function init()
    loadSettings()
    loadDockState()
    
    local title = 'Media Properties Toolbar'
    local docked = state.is_docked and state.dock_id or 0
    local x, y = 100, 100
    local w = 1200  -- Increased width to accommodate parameters
    local h = config.entry_height * 2
    
    -- Initialize window without focus
    gfx.init(title, w, h, docked, x, y)
    gfx.setfont(1, config.font_name, config.font_size)
    
    -- Initialize name dialog context if needed
    if not nameDialog.ctx then
        nameDialog.ctx = r.ImGui_CreateContext('Media Properties Name Dialog')
    end
    
    -- Keep arrange window focused
    r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
end

function truncateString(str, maxWidth)
    local str_w = gfx.measurestr(str)
    if str_w <= maxWidth then return str end
    
    local ellipsis = "..."
    local ellipsis_w = gfx.measurestr(ellipsis)
    local available_w = maxWidth - ellipsis_w
    
    while str_w > available_w and #str > 1 do
        str = str:sub(2)
        str_w = gfx.measurestr(str)
    end
    
    return ellipsis .. str
end

function drawTooltip(text, x, y)
    local padding = 4
    local text_w, text_h = gfx.measurestr(text)
    
    gfx.set(table.unpack(config.tooltip_bg))
    gfx.rect(x, y - text_h - padding*2, text_w + padding*2, text_h + padding*2, 1)
    
    gfx.set(table.unpack(config.tooltip_text))
    gfx.x = x + padding
    gfx.y = y - text_h - padding
    gfx.drawstr(text)
end

function drawHeaderCell(text, x, y, w)
    gfx.set(table.unpack(config.frame_color))
    gfx.rect(x, y, w, config.entry_height)
    
    gfx.set(table.unpack(config.text_color))
    local str_w, str_h = gfx.measurestr(text)
    gfx.x = x + (w - str_w) / 2
    gfx.y = y + (config.entry_height - str_h) / 2
    gfx.drawstr(text)
    
    -- Return header cell coordinates for click detection
    return {
        x = x,
        y = y,
        w = w,
        h = config.entry_height,
        text = text
    }
end

function drawValueCell(value, x, y, w, is_active, param_type, param_name)
    -- Check if value is modified from default
    local is_negative = false
    if param_type == "volume" or param_type == "takevol" then
        local db = 20 * math.log(value, 10)
        is_negative = db < 0
    elseif param_type == "pitch" or param_type == "pan" then
        is_negative = value < 0
    elseif param_type == "rate" then  
        is_negative = value < 1.0
    end
    
    -- Then check for any modifications
    local is_modified = false
    if param_type == "volume" or param_type == "takevol" then
        is_modified = math.abs(value - 1.0) > 0.001
    elseif param_type == "pitch" or param_type == "pan" then 
        is_modified = math.abs(value) > 0.001
    elseif param_type == "rate" then
        is_modified = math.abs(value - 1.0) > 0.001
    elseif param_type == "time" and (param_name == "snap" or param_name == "fadein" or param_name == "fadeout") then
        is_modified = value > 0.001 
    end

    -- Special handling for boolean values
    if param_type == "bool" then
        is_modified = value
        is_negative = not value
        value = value and "ON" or "OFF"
    end

    -- Set color based on state
    if is_negative then
        gfx.set(table.unpack(config.colors.text_negative))
    elseif is_modified then
        gfx.set(table.unpack(config.colors.text_modified))
    else
        gfx.set(table.unpack(config.colors.text_normal))
    end

    local metrics = nil
    local display_value

    if param_type == "time" or param_name == "position" or param_name == "length" then
        -- Convert to minutes:seconds.milliseconds format
        local minutes = math.floor(value / 60)
        local seconds = math.floor(value % 60)
        local ms = math.floor((value % 1) * 1000)
        display_value = string.format("%d:%02d.%03d", minutes, seconds, ms)
    elseif param_type == "volume" or param_type == "takevol" then
        local db = 20 * math.log(value, 10)
        if db == math.abs(0) then db = 0 end
        display_value = string.format("%+.1f dB", db)
    elseif param_type == "pitch" then
        if value == 0 then 
            display_value = "0 st"
        else 
            display_value = string.format("%+.1f st", value)
        end
    elseif param_type == "pan" then
        if value == 0 then 
            display_value = "C"
        elseif value < 0 then 
            display_value = string.format("%d L", math.floor(math.abs(value * 100)))
        else 
            display_value = string.format("%d R", math.floor(value * 100))
        end
    elseif param_type == "rate" then
        display_value = string.format("%.3f x", value)
    elseif param_type == "bool" then
        display_value = value
    else
        display_value = tostring(value)
    end
    
    if param_type == "name" then
        local margin = 4
        display_value = truncateString(display_value, w - margin)
    end

    if param_type == "time" then
        local str_w = gfx.measurestr(display_value)
        local text_x = x + (w - str_w) / 2
        gfx.x = text_x
        gfx.y = y + (config.entry_height - select(2, gfx.measurestr(display_value))) / 2
        gfx.drawstr(display_value)
        metrics = getTimeStringMetrics(display_value, text_x)
    else
        local str_w, str_h = gfx.measurestr(display_value)
        gfx.x = x + (w - str_w) / 2
        gfx.y = y + (config.entry_height - str_h) / 2
        gfx.drawstr(display_value)
    end
    
    return {
        x = x, 
        y = y, 
        w = w, 
        h = config.entry_height,
        text_metrics = metrics,
        param_type = param_type,
        value = value
    }
end

function formatTimeString(time)
    local minutes = math.floor(time / 60)
    local seconds = math.floor(time % 60)
    local ms = math.floor((time % 1) * 1000)
    return string.format("%d:%02d.%03d", minutes, seconds, ms)
end

function getTimeStringMetrics(str, x)
    local parts = {}
    local minutes = str:match("^(%d+):")
    local seconds = str:match(":(%d+)%.")
    local ms = str:match("%.(%d+)$")
    
    local min_width = gfx.measurestr(minutes)
    local colon_width = gfx.measurestr(":")
    local sec_width = gfx.measurestr(seconds)
    local dot_width = gfx.measurestr(".")
    
    parts.min_end = x + min_width
    parts.sec_start = parts.min_end + colon_width
    parts.sec_end = parts.sec_start + sec_width
    parts.ms_start = parts.sec_end + dot_width
    
    return parts
end

function updateItemRate(item, take, rate)
    local original_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local original_rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    
    local new_length = original_length * (original_rate / rate)
    
    r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
    
    r.UpdateItemInProject(item)
end

-- Function to update selected items with a relative offset
-- Function to update selected items with a relative offset
function updateItemsWithOffset(item_data, param_name, change)
    local selected_items = {}
    local selected_values = {}
    
    -- Collect the current values from all selected items
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        local current_value
        
        if param_name == "volume" then
            current_value = r.GetMediaItemInfo_Value(item, "D_VOL")
        elseif param_name == "takevol" then
            current_value = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
        elseif param_name == "position" then
            current_value = r.GetMediaItemInfo_Value(item, "D_POSITION")
        elseif param_name == "length" then
            current_value = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        elseif param_name == "snap" then
            current_value = r.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
        elseif param_name == "fadein" then
            current_value = r.GetMediaItemInfo_Value(item, "D_FADEINLEN")
        elseif param_name == "fadeout" then
            current_value = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
        elseif param_name == "pitch" then
            current_value = r.GetMediaItemTakeInfo_Value(take, "D_PITCH")
        elseif param_name == "pan" then
            current_value = r.GetMediaItemTakeInfo_Value(take, "D_PAN")
        elseif param_name == "rate" then
            current_value = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        end
        
        if current_value then
            table.insert(selected_items, {item = item, take = take})
            table.insert(selected_values, current_value)
        end
    end
    
    if #selected_items == 0 then return end
    
    r.Undo_BeginBlock()
    
    -- Apply the offset to each item
    for i, data in ipairs(selected_items) do
        local item = data.item
        local take = data.take
        local current_value = selected_values[i]
        local new_value
        
        if param_name == "volume" or param_name == "takevol" then
            -- Handle volume (dB scale) specially
            local current_db = config.linear_to_db(current_value)
            local new_db = current_db + change
            
            -- Limit to -150dB minimum
            if new_db < -150 then new_db = -150 end
            
            new_value = config.db_to_linear(new_db)
            
            if param_name == "volume" then
                r.SetMediaItemInfo_Value(item, "D_VOL", new_value)
            else
                r.SetMediaItemTakeInfo_Value(take, "D_VOL", new_value)
            end
        else
            new_value = current_value + change
            
            -- Apply the limits based on parameter type
            if param_name == "snap" or param_name == "fadein" or param_name == "fadeout" then
                -- Prevent negative values
                if new_value < 0 then new_value = 0 end
            elseif param_name == "pitch" then
                -- Limit pitch to -60/+60
                if new_value < -60 then new_value = -60 end
                if new_value > 60 then new_value = 60 end
            elseif param_name == "pan" then
                -- Limit pan to -1/+1 (100L/100R)
                if new_value < -1 then new_value = -1 end
                if new_value > 1 then new_value = 1 end
            elseif param_name == "rate" then
                -- Limit rate to 0.01-40
                if new_value < 0.01 then new_value = 0.01 end
                if new_value > 40 then new_value = 40 end
            end
            
            -- Apply the new value
            if param_name == "position" then
                r.SetMediaItemInfo_Value(item, "D_POSITION", new_value)
            elseif param_name == "length" then
                r.SetMediaItemInfo_Value(item, "D_LENGTH", new_value)
            elseif param_name == "snap" then
                r.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", new_value)
            elseif param_name == "fadein" then
                r.SetMediaItemInfo_Value(item, "D_FADEINLEN", new_value)
            elseif param_name == "fadeout" then
                r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", new_value)
            elseif param_name == "pitch" then
                r.SetMediaItemTakeInfo_Value(take, "D_PITCH", new_value)
            elseif param_name == "pan" then
                r.SetMediaItemTakeInfo_Value(take, "D_PAN", new_value)
            elseif param_name == "rate" then
                updateItemRate(item, take, new_value)
            end
        end
        
        r.UpdateItemInProject(item)
    end
    
    r.Undo_EndBlock("Update item properties", -1)
end

function processWildcards(name, item)
    if not item then return name end
    
    -- Save original case by making a copy
    local original_name = name
    name = name:lower()
    
    -- Remove tags [x]
    name = name:gsub("%[%w+%]%s*", "")
    
    -- Build a map of lowercase to original case for wildcards
    local case_map = {}
    for pattern, _ in pairs(wildcards) do
        local lower_pattern = pattern:lower()
        case_map[lower_pattern] = pattern
    end
    
    -- Replace wildcards
    for pattern, func in pairs(wildcards) do
        local replacement = func(item)
        if replacement then
            name = name:gsub(pattern:lower(), replacement)
        end
    end
    
    -- Clean up
    name = name:gsub("%s+", "_")
    name = name:gsub("_+", "_")
    name = name:trim("_")
    
    return name
end

function string.trim(str, char)
    char = char or "%s"
    return str:gsub("^" .. char .. "+", ""):gsub(char .. "+$", "")
end

-- Function to handle value input for multiple items with absolute values
-- Function to handle value input for multiple items with absolute values
function handleValueInput(param_name, current_value)
    if param_name == "position" or param_name == "length" or 
       param_name == "fadein" or param_name == "fadeout" or
       param_name == "snap" then
       
        local min = math.floor(current_value / 60)
        local sec = math.floor(current_value % 60)
        local ms = math.floor((current_value % 1) * 1000)
        
        local retval, user_input = r.GetUserInputs(param_name, 3, 
            "Minutes,Seconds,Milliseconds", 
            string.format("%d,%d,%d", min, sec, ms))

        if not retval then return nil end
        
        local new_min, new_sec, new_ms = user_input:match("([^,]+),([^,]+),([^,]+)")
        if new_min and new_sec and new_ms then
            new_min = tonumber(new_min) or 0
            new_sec = tonumber(new_sec) or 0
            new_ms = tonumber(new_ms) or 0
            local new_value = new_min * 60 + new_sec + new_ms/1000
            
            -- Prevent negative values for certain parameters
            if (param_name == "snap" or param_name == "fadein" or param_name == "fadeout") and new_value < 0 then
                new_value = 0
            end
            
            return new_value
        end
        return current_value

    elseif param_name == "volume" or param_name == "takevol" then
        local current_db = 20 * math.log(current_value, 10)
        local retval, user_input = r.GetUserInputs(param_name, 1, 
            param_name == "volume" and "Item volume (dB):" or "Take volume (dB):", 
            string.format("%.1f", current_db))
        if not retval then return current_value end
        
        local new_db = tonumber(user_input)
        if new_db then
            -- Limit to -150dB
            if new_db < -150 then new_db = -150 end
            return 10^(new_db/20)
        end
        return current_value
        
    elseif param_name == "pan" then
        local pan_val = current_value * 100
        local retval, user_input = r.GetUserInputs(param_name, 1, 
            "Pan (-100=L, 0=C, 100=R):", string.format("%.0f", pan_val))
        if not retval then return current_value end
        local new_value = tonumber(user_input)
        if new_value then 
            -- Limit Pan to -100/+100
            if new_value < -100 then new_value = -100 end
            if new_value > 100 then new_value = 100 end
            return new_value/100 
        end
        return current_value
        
    elseif param_name == "pitch" then
        local retval, user_input = r.GetUserInputs(param_name, 1, 
            "Pitch (semitones):", string.format("%.1f", current_value))
        if not retval then return current_value end
        
        local new_value = tonumber(user_input)
        if new_value then
            -- Limit pitch to -60/+60
            if new_value < -60 then new_value = -60 end
            if new_value > 60 then new_value = 60 end
            return new_value
        end
        return current_value
        
    elseif param_name == "rate" then
        local retval, user_input = r.GetUserInputs(param_name, 1, 
            "Playback rate:", string.format("%.3f", current_value))
        if not retval then return current_value end
        
        local new_value = tonumber(user_input)
        if new_value then
            -- Limit rate to 0.01-40
            if new_value < 0.01 then new_value = 0.01 end
            if new_value > 40 then new_value = 40 end
            return new_value
        end
        return current_value
    end
    
    return current_value
end

-- Function to load naming preferences
function loadNamingPreferences()
    local prefs = {
        prefix = r.GetExtState("MediaPropertiesToolbar", "last_prefix") or "",
        suffix = r.GetExtState("MediaPropertiesToolbar", "last_suffix") or "",
        number_format = r.GetExtState("MediaPropertiesToolbar", "number_format") or "",
        use_prefix = r.GetExtState("MediaPropertiesToolbar", "use_prefix") == "1",
        use_suffix = r.GetExtState("MediaPropertiesToolbar", "use_suffix") == "1",
        use_numbering = r.GetExtState("MediaPropertiesToolbar", "use_numbering") == "1"
    }
    
    -- Set defaults if not set
    if prefs.use_prefix == nil then prefs.use_prefix = true end
    if prefs.use_suffix == nil then prefs.use_suffix = true end
    if prefs.use_numbering == nil then prefs.use_numbering = true end
    
    return prefs
end

-- Function to save naming preferences
function saveNamingPreferences(prefs)
    r.SetExtState("MediaPropertiesToolbar", "last_prefix", prefs.prefix or "", true)
    r.SetExtState("MediaPropertiesToolbar", "last_suffix", prefs.suffix or "", true)
    r.SetExtState("MediaPropertiesToolbar", "number_format", prefs.number_format or "", true)
    r.SetExtState("MediaPropertiesToolbar", "use_prefix", prefs.use_prefix and "1" or "0", true)
    r.SetExtState("MediaPropertiesToolbar", "use_suffix", prefs.use_suffix and "1" or "0", true)
    r.SetExtState("MediaPropertiesToolbar", "use_numbering", prefs.use_numbering and "1" or "0", true)
end

-- Extract base name from a full name
function extractBaseName(full_name)
    if not full_name then return "" end
    
    local base_name = full_name
    
    -- 1. First remove .wav extension
    base_name = base_name:gsub("%.wav$", "")
    
    -- Remove multiple spaces
    base_name = base_name:gsub("%s+", " ")
    
    -- 2. Extract Wwise prefix if it exists
    local wwise_prefix = base_name:match("^%[%w+%]")
    if wwise_prefix then
        base_name = base_name:sub(#wwise_prefix + 1)
    end
    
    -- 3. Load previous preferences
    local prefs = loadNamingPreferences()
    
    -- 4. Remove prefix if it exists and if prefix is not empty
    if prefs.prefix and prefs.prefix ~= "" and prefs.use_prefix then
        -- Escape any pattern characters in the prefix
        local escaped_prefix = prefs.prefix:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        local prefix_pattern = "^" .. escaped_prefix
        base_name = base_name:gsub(prefix_pattern, "")
    end
    
    -- 5. Search for and remove numbering according to specific patterns
    local number_removed = false
    local number_patterns = {
        {pattern = "%s+%d+%s*$"},         -- " 01"
        {pattern = "_%d+%s*$"},          -- "_01"
        {pattern = "%.%d+%s*$"},          -- ".01"
        {pattern = "%(%d+%)%s*$"},       -- "(01)"
        {pattern = "%s+%-%-%s*%d+%s*$"}, -- " -- 01"
    }
    
    for _, pat in ipairs(number_patterns) do
        local new_name = base_name:gsub(pat.pattern, "")
        if new_name ~= base_name then
            base_name = new_name
            number_removed = true
            break
        end
    end
    
    -- 6. Remove suffix if it exists and if suffix is not empty
    if prefs.suffix and prefs.suffix ~= "" and prefs.use_suffix then
        -- Escape any pattern characters in the suffix
        local escaped_suffix = prefs.suffix:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        local suffix_pattern = escaped_suffix .. "$"
        base_name = base_name:gsub(suffix_pattern, "")
    end
    
    -- 7. Final cleanup: remove spaces at beginning/end
    base_name = base_name:match("^%s*(.-)%s*$") or ""
    
    -- 8. Remove commas at the end of the string if present
    base_name = base_name:gsub(",%s*$", "")
    
    return base_name, wwise_prefix
end

-- Build a final filename based on components
function buildFinalName(base_name, prefix, suffix, number_format, index, wwise_prefix, use_prefix, use_suffix, use_numbering)
    local final_name = base_name or ""
    
    -- Add prefix if present and enabled - preserve case
    if prefix and prefix ~= "" and use_prefix then
        final_name = prefix .. final_name
    end
    
    -- Add suffix if present and enabled - preserve case
    if suffix and suffix ~= "" and use_suffix then
        final_name = final_name .. suffix
    end
    
    -- Add numbering if format specified, index provided, and enabled
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
    
    -- Restore Wwise prefix if it existed
    if wwise_prefix and wwise_prefix ~= "" then
        final_name = wwise_prefix .. final_name
    end
    
    return final_name
end

-- Update selected items to a specific value (no relative offset)
function updateItemValue(item_data, param_name, value)
    local selected_items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(selected_items, r.GetSelectedMediaItem(0, i))
    end
    
    if #selected_items == 0 then return end
    
    r.Undo_BeginBlock()
    
    if param_name == "name" then
        -- Special handling for name changes - will use the name dialog result
        if nameDialog.result then
            local prefs = nameDialog.result
            
            for i, item in ipairs(selected_items) do
                local take = r.GetActiveTake(item)
                if take then
                    local new_name
                    if prefs.use_numbering and #selected_items > 1 and prefs.number_format ~= "" then
                        -- Apply numbering for multiple items
                        new_name = buildFinalName(
                            prefs.base_name,
                            prefs.prefix,
                            prefs.suffix,
                            prefs.number_format,
                            i,
                            nil,
                            prefs.use_prefix,
                            prefs.use_suffix,
                            prefs.use_numbering
                        )
                    else
                        -- No numbering
                        new_name = buildFinalName(
                            prefs.base_name,
                            prefs.prefix,
                            prefs.suffix,
                            nil,
                            nil,
                            nil,
                            prefs.use_prefix,
                            prefs.use_suffix,
                            false
                        )
                    end
                    
                    -- Process wildcards if any
                    new_name = processWildcards(new_name, item)
                    
                    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
                end
            end
            
            nameDialog.result = nil  -- Clear the result
        elseif type(value) == "string" then
            -- Direct name setting
            for i, item in ipairs(selected_items) do
                local take = r.GetActiveTake(item)
                if take then
                    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", value, true)
                end
            end
        end
    else
        -- Handle all other parameters (non-name)
        for i, item in ipairs(selected_items) do
            local take = r.GetActiveTake(item)
            if take then
                -- Apply the same exact value to all items (no offset calculation)
                if param_name == "volume" then 
                    r.SetMediaItemInfo_Value(item, "D_VOL", value)
                elseif param_name == "takevol" then 
                    r.SetMediaItemTakeInfo_Value(take, "D_VOL", value)
                elseif param_name == "position" then 
                    r.SetMediaItemInfo_Value(item, "D_POSITION", value)
                elseif param_name == "length" then 
                    r.SetMediaItemInfo_Value(item, "D_LENGTH", value)
                elseif param_name == "snap" then 
                    r.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", value)
                elseif param_name == "fadein" then 
                    r.SetMediaItemInfo_Value(item, "D_FADEINLEN", value)
                elseif param_name == "fadeout" then 
                    r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", value)
                elseif param_name == "pitch" then 
                    r.SetMediaItemTakeInfo_Value(take, "D_PITCH", value)
                elseif param_name == "pan" then 
                    r.SetMediaItemTakeInfo_Value(take, "D_PAN", value)
                elseif param_name == "rate" then 
                    updateItemRate(item, take, value)
                elseif param_name == "preserve_pitch" then 
                    r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", value and 1 or 0)
                elseif param_name == "mute" then 
                    r.SetMediaItemInfo_Value(item, "B_MUTE", value and 1 or 0)
                end
                
                r.UpdateItemInProject(item)
            end
        end
    end
    
    r.Undo_EndBlock("Update media items", -1)
    r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
end

-- Initialize and run the name dialog
function openNameDialog(current_name, selected_items)
    -- Store the selected items for later use
    nameDialog.selected_items = selected_items or {}
    
    -- Initialize dialog data
    local prefs = loadNamingPreferences()
    nameDialog.name = current_name or ""
    nameDialog.prefix = prefs.prefix or ""
    nameDialog.suffix = prefs.suffix or ""
    nameDialog.numberFormat = prefs.number_format or ""
    nameDialog.use_prefix = prefs.use_prefix
    nameDialog.use_suffix = prefs.use_suffix
    nameDialog.use_numbering = prefs.use_numbering
    
    -- Calculate base name if needed
    local base_name, wwise_prefix = extractBaseName(current_name)
    nameDialog.base_name = base_name
    nameDialog.wwise_prefix = wwise_prefix
    nameDialog.need_focus = true -- Flag to set focus on first input
    
    -- Open the dialog
    nameDialog.isOpen = true
    
    -- Start the dialog loop
    nameDialogLoop()
end

-- Main loop for the name dialog
function nameDialogLoop()
    if not nameDialog.isOpen then
        return
    end
    
    -- Apply the global styles if available
    local pushed_dialog_colors = 0
    local pushed_dialog_vars = 0
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(nameDialog.ctx)
        if success then
            pushed_dialog_colors, pushed_dialog_vars = colors, vars
        end
    end
    
    -- Set up window position
    if not nameDialog.window_position_set then
        -- Center the dialog
        local main_x, main_y, main_w, main_h = 0, 0, 0, 0
        if r.JS_Window_Find then
            local main_hwnd = r.GetMainHwnd()
            local ret, left, top, right, bottom = r.JS_Window_GetRect(main_hwnd)
            if ret then
                main_x, main_y = left, top
                main_w, main_h = right - left, bottom - top
            end
        end
        
        local x = main_x + (main_w - nameDialog.window_width) / 2
        local y = main_y + (main_h - nameDialog.window_height) / 2
        
        r.ImGui_SetNextWindowPos(nameDialog.ctx, x, y, r.ImGui_Cond_FirstUseEver())
        r.ImGui_SetNextWindowSize(nameDialog.ctx, nameDialog.window_width, nameDialog.window_height, r.ImGui_Cond_FirstUseEver())
        nameDialog.window_position_set = true
    end
    
    -- Begin window
    local visible, open = r.ImGui_Begin(nameDialog.ctx, "Item Name Editor", true, r.ImGui_WindowFlags_NoCollapse())
    
    if visible then
        -- Main name input
        r.ImGui_Text(nameDialog.ctx, "Base Name (without prefix/suffix/numbers):")
        
        -- Auto-focus the base name input field the first time
        if nameDialog.need_focus then
            r.ImGui_SetKeyboardFocusHere(nameDialog.ctx)
            nameDialog.need_focus = false
        end
        
        local rv, new_base_name = r.ImGui_InputText(nameDialog.ctx, "##basename", nameDialog.base_name, r.ImGui_InputTextFlags_EnterReturnsTrue())
        if rv then
            nameDialog.base_name = new_base_name
            -- Apply when Enter is pressed
            local new_prefs = {
                prefix = nameDialog.prefix,
                suffix = nameDialog.suffix,
                number_format = nameDialog.numberFormat,
                use_prefix = nameDialog.use_prefix,
                use_suffix = nameDialog.use_suffix,
                use_numbering = nameDialog.use_numbering,
                base_name = nameDialog.base_name
            }
            
            saveNamingPreferences(new_prefs)
            nameDialog.result = new_prefs
            nameDialog.isOpen = false
            open = false
            
            -- Trigger the update in the main function
            updateItemValue(nil, "name", nil)
        end
        
        r.ImGui_Spacing(nameDialog.ctx)
        r.ImGui_Separator(nameDialog.ctx)
        r.ImGui_Spacing(nameDialog.ctx)
        
        -- Prefix options
        rv, nameDialog.use_prefix = r.ImGui_Checkbox(nameDialog.ctx, "Use Prefix", nameDialog.use_prefix)
        if nameDialog.use_prefix then
            r.ImGui_SameLine(nameDialog.ctx)
            r.ImGui_SetNextItemWidth(nameDialog.ctx, 200)
            rv, nameDialog.prefix = r.ImGui_InputText(nameDialog.ctx, "##prefix", nameDialog.prefix)
        end
        
        r.ImGui_Spacing(nameDialog.ctx)
        
        -- Suffix options
        rv, nameDialog.use_suffix = r.ImGui_Checkbox(nameDialog.ctx, "Use Suffix", nameDialog.use_suffix)
        if nameDialog.use_suffix then
            r.ImGui_SameLine(nameDialog.ctx)
            r.ImGui_SetNextItemWidth(nameDialog.ctx, 200)
            rv, nameDialog.suffix = r.ImGui_InputText(nameDialog.ctx, "##suffix", nameDialog.suffix)
        end
        
        r.ImGui_Spacing(nameDialog.ctx)
        
        -- Numbering options (only for multiple items)
        local multiple_items = #nameDialog.selected_items > 1
        rv, nameDialog.use_numbering = r.ImGui_Checkbox(nameDialog.ctx, "Use Numbering" .. (multiple_items and "" or " (multiple items only)"), 
                                                       nameDialog.use_numbering)
        
        if nameDialog.use_numbering then
            r.ImGui_Text(nameDialog.ctx, "Number Format:")
            
            local formats = {
                { label = "1", value = " %d" },
                { label = "01", value = "%02d" },
                { label = "001", value = "%03d" },
                { label = "(1)", value = "(%d)" },
                { label = ".1", value = ".%d" }
            }
            
            for i, format in ipairs(formats) do
                if i > 1 then r.ImGui_SameLine(nameDialog.ctx) end
                
                local is_selected = nameDialog.numberFormat == format.value
                if r.ImGui_RadioButton(nameDialog.ctx, format.label, is_selected) and not is_selected then
                    nameDialog.numberFormat = format.value
                end
            end
        end
        
        r.ImGui_Spacing(nameDialog.ctx)
        r.ImGui_Separator(nameDialog.ctx)
        r.ImGui_Spacing(nameDialog.ctx)
        
        -- Preview section
        r.ImGui_Text(nameDialog.ctx, "Preview:")
        
        local preview_name
        if multiple_items then
            -- Show first two examples
            local example1 = buildFinalName(
                nameDialog.base_name,
                nameDialog.prefix,
                nameDialog.suffix,
                nameDialog.use_numbering and nameDialog.numberFormat or nil,
                1,
                nameDialog.wwise_prefix,
                nameDialog.use_prefix,
                nameDialog.use_suffix,
                nameDialog.use_numbering
            )
            
            local example2 = buildFinalName(
                nameDialog.base_name,
                nameDialog.prefix,
                nameDialog.suffix,
                nameDialog.use_numbering and nameDialog.numberFormat or nil,
                2,
                nameDialog.wwise_prefix,
                nameDialog.use_prefix,
                nameDialog.use_suffix,
                nameDialog.use_numbering
            )
            
            preview_name = example1 .. "\n" .. example2 .. "\n..."
        else
            -- Show single example
            preview_name = buildFinalName(
                nameDialog.base_name,
                nameDialog.prefix,
                nameDialog.suffix,
                nil, -- No numbering for single items
                nil,
                nameDialog.wwise_prefix,
                nameDialog.use_prefix,
                nameDialog.use_suffix,
                false
            )
        end
        
        r.ImGui_PushStyleColor(nameDialog.ctx, r.ImGui_Col_Text(), 0xAAFFAAFF)
        r.ImGui_TextWrapped(nameDialog.ctx, preview_name)
        r.ImGui_PopStyleColor(nameDialog.ctx)
        
        r.ImGui_Spacing(nameDialog.ctx)
        r.ImGui_Separator(nameDialog.ctx)
        r.ImGui_Spacing(nameDialog.ctx)
        
        -- Wildcards info
        r.ImGui_Text(nameDialog.ctx, "Available wildcards:")
        r.ImGui_Text(nameDialog.ctx, "$track $parent $region $marker $project $folders")
        
        r.ImGui_Spacing(nameDialog.ctx)
        
        -- Bottom buttons
        local button_width = (r.ImGui_GetWindowWidth(nameDialog.ctx) - 20) / 2
        
        if r.ImGui_Button(nameDialog.ctx, "Apply", button_width) then
            -- Save the preferences
            local new_prefs = {
                prefix = nameDialog.prefix,
                suffix = nameDialog.suffix,
                number_format = nameDialog.numberFormat,
                use_prefix = nameDialog.use_prefix,
                use_suffix = nameDialog.use_suffix,
                use_numbering = nameDialog.use_numbering,
                base_name = nameDialog.base_name
            }
            
            saveNamingPreferences(new_prefs)
            
            -- Set the result and close the dialog
            nameDialog.result = new_prefs
            nameDialog.isOpen = false
            open = false
            
            -- Trigger the update in the main function
            updateItemValue(nil, "name", nil)
        end
        
        r.ImGui_SameLine(nameDialog.ctx)
        
        if r.ImGui_Button(nameDialog.ctx, "Cancel", button_width) then
            nameDialog.isOpen = false
            open = false
        end
        
        r.ImGui_End(nameDialog.ctx)
    end
    
    -- Clean up styles
    if style_loader then
        style_loader.clearStyles(nameDialog.ctx, pushed_dialog_colors, pushed_dialog_vars)
    end
    
    -- Continue or close
    if open and nameDialog.isOpen then
        r.defer(nameDialogLoop)
    else
        nameDialog.isOpen = false
    end
end

function handleMouseInput(item_data, mx, my, controls, header_cells)
    local mouse_cap = gfx.mouse_cap
    local mouse_wheel = gfx.mouse_wheel
    gfx.mouse_wheel = 0
    
    local current_time = r.time_precise()
    
    -- Vérifier si nous sommes en période de refroidissement après un double-clic
    if state.double_click_cooldown > 0 and current_time - state.double_click_cooldown < 0.3 then
        -- Ignorer les entrées de souris pendant le refroidissement
        state.last_mouse_cap = mouse_cap
        return
    else
        state.double_click_cooldown = 0
    end

    if mouse_cap == 0 then
        -- Réinitialiser le flag de traitement des doubles clics lorsque le bouton est relâché
        state.double_click_handled = false
        
        for id, ctrl in pairs(controls) do
            if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
               my >= ctrl.y and my < ctrl.y + ctrl.h then
                if id == "source" then
                    drawTooltip(ctrl.full_source, mx + 10, my)
                end
            end
        end
    end

    -- Handle click/double-click
    if mouse_cap == 1 and state.last_mouse_cap == 0 then
        local is_double_click = (current_time - state.last_click_time) < 0.3
        state.last_click_time = current_time
    
        if is_double_click and not state.double_click_handled then
            state.double_click_handled = true
            state.double_click_cooldown = current_time  -- Marquer le début du refroidissement
            
            -- Vérifier d'abord les clics sur les en-têtes
            for _, header in ipairs(header_cells or {}) do
                if mx >= header.x and mx < header.x + header.w and
                   my >= header.y and my < header.y + header.h then
                    -- Traitement spécial pour le header PresPitch
                    if header.text == "PresPitch" then
                        -- Lancer le script CP_PitchMode.lua avec l'ID de commande correct
                        local script_id = r.NamedCommandLookup("_RSbd553d355efb97c0e350e52672b0784f6b9b72e9")
                        if script_id ~= 0 then
                            r.Main_OnCommand(script_id, 0)
                        end
                        state.last_mouse_cap = mouse_cap
                        return -- Sortir de la fonction après avoir traité le clic sur l'en-tête
                    end
                    break
                end
            end
            
            -- Vérifier ensuite les contrôles normaux (comme avant)
            for id, ctrl in pairs(controls) do
                if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
                   my >= ctrl.y and my < ctrl.y + ctrl.h then
                    if id == "source" then
                        -- Méthode 1: Essayer le NamedCommandLookup (méthode la plus fiable)
                        local script_id = r.NamedCommandLookup("_RSbd325b208f4aef794a3a327ffce0d38473c64c52")
                        
                        if script_id ~= 0 then
                            -- Le script est enregistré comme action, l'exécuter directement
                            r.Main_OnCommand(script_id, 0)
                        end
                        
                        return -- Sortir de la fonction pour éviter d'autres traitements
                    elseif id == "name" then
                        -- Open the ImGui name dialog
                        local selected_items = {}
                        local selected_count = r.CountSelectedMediaItems(0)
                        for i = 0, selected_count - 1 do
                            table.insert(selected_items, r.GetSelectedMediaItem(0, i))
                        end
                        openNameDialog(ctrl.value, selected_items)
                    else
                        -- For non-name parameters
                        local new_value = handleValueInput(id, ctrl.value)
                        if new_value then
                            updateItemValue(item_data, id, new_value)
                        end
                    end
                    break
                end
            end
        else
            -- Clic simple - ne pas traiter les en-têtes ici, uniquement les contrôles
            for id, ctrl in pairs(controls) do
                if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
                   my >= ctrl.y and my < ctrl.y + ctrl.h then
                    if ctrl.param_type ~= "bool" then
                        if ctrl.param_type == "time" and ctrl.text_metrics then
                            local drag_zone
                            if mx <= ctrl.text_metrics.min_end then
                                drag_zone = "minutes"
                                r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
                            elseif mx <= ctrl.text_metrics.sec_end then
                                drag_zone = "seconds"
                                r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
                            else
                                drag_zone = "milliseconds"
                                r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
                            end
                            state.active_control = id .. "_" .. drag_zone
                        else
                            state.active_control = id
                        end
                        state.drag_active = true
                    else
                        updateItemValue(item_data, id, not ctrl.value)
                        r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
                    end
                    break
                end
            end
        end
    end
    
    -- Handle wheel - apply offset to all selected items
    if mouse_wheel ~= 0 then
        for id, ctrl in pairs(controls) do
            if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
               my >= ctrl.y and my < ctrl.y + ctrl.h then
                
                if id == "volume" or id == "takevol" then
                    local db_change = mouse_wheel > 0 and config.volume.step_db or -config.volume.step_db
                    updateItemsWithOffset(item_data, id, db_change)
                
                elseif id == "pitch" then
                    local change = mouse_wheel > 0 and config.pitch.step or -config.pitch.step
                    updateItemsWithOffset(item_data, id, change)
 
                elseif id == "pan" then
                    local change = mouse_wheel > 0 and config.pan.step or -config.pan.step
                    updateItemsWithOffset(item_data, id, change)
 
                elseif id == "rate" then
                    local change = mouse_wheel > 0 and config.rate.step or -config.rate.step
                    updateItemsWithOffset(item_data, id, change)
 
                elseif ctrl.param_type == "time" then
                    if ctrl.text_metrics then
                        local increment
                        if mx <= ctrl.text_metrics.min_end then
                            increment = 60  -- Minutes
                        elseif mx <= ctrl.text_metrics.sec_end then
                            increment = 1   -- Seconds
                        else
                            increment = 0.001  -- Milliseconds
                        end
                        local delta = mouse_wheel > 0 and increment or -increment
                        updateItemsWithOffset(item_data, id, delta)
                    end
                end
            end
        end
    end
    
    -- Handle drag
    if state.drag_active and state.active_control then
        local base_id = state.active_control:match("^([^_]+)")
        local ctrl = controls[base_id]
        if ctrl then
            if base_id == "volume" or base_id == "takevol" then
                local db_change = (mx - state.last_mouse_x) * config.mouse.volume_sensitivity
                updateItemsWithOffset(item_data, base_id, db_change)
                r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
    
            elseif base_id == "pitch" then
                local change = (mx - state.last_mouse_x) * config.mouse.pitch_sensitivity
                updateItemsWithOffset(item_data, base_id, change)
                r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
            elseif base_id == "pan" then
                local change = (mx - state.last_mouse_x) * config.mouse.pan_sensitivity
                updateItemsWithOffset(item_data, base_id, change)
                r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
            elseif base_id == "rate" then
                local change = (mx - state.last_mouse_x) * config.mouse.rate_sensitivity
                updateItemsWithOffset(item_data, base_id, change)
                r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)      
            elseif ctrl.param_type == "time" then
                if ctrl.text_metrics then
                    local drag_zone = state.active_control:match("_(%w+)$")
                    local drag_sensitivity
                    if drag_zone == "minutes" then
                        drag_sensitivity = config.time.drag_minutes
                    elseif drag_zone == "seconds" then
                        drag_sensitivity = config.time.drag_seconds
                    else
                        drag_sensitivity = config.time.drag_milliseconds
                    end
                    
                    local change = (mx - state.last_mouse_x) * drag_sensitivity
                    updateItemsWithOffset(item_data, base_id, change)
                end
            end
        end
    end

    -- Handle right-click reset for all selected items
    if mouse_cap == 2 and state.last_mouse_cap == 0 then
        for id, ctrl in pairs(controls) do
            if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
               my >= ctrl.y and my < ctrl.y + ctrl.h then
                local reset_value = nil
                if id == "volume" then reset_value = 1.0
                elseif id == "takevol" then reset_value = 1.0
                elseif id == "pitch" then reset_value = 0
                elseif id == "pan" then reset_value = 0
                elseif id == "rate" then reset_value = 1.0
                elseif id == "fadein" then reset_value = 0
                elseif id == "fadeout" then reset_value = 0
                elseif id == "snap" then reset_value = 0
                elseif id == "preserve_pitch" then reset_value = false
                elseif id == "mute" then reset_value = false
                end
                    
                if reset_value ~= nil then
                    updateItemValue(item_data, id, reset_value)
                end
                break
            end
        end
    end

    if mouse_cap == 0 then
        state.drag_active = false
        state.active_control = nil
    end
    
    state.last_mouse_cap = mouse_cap
    state.last_mouse_x = mx
    state.last_mouse_y = my
end

-- Function to determine visible widgets based on available space
function calculateWidgetWidths(available_width)
    local widget_widths = {}
    local visible_widgets = {}
    
    -- Toujours afficher nom et source si possible
    local min_required = config.min_widget_width * 2 -- Au minimum pour nom et source
    if available_width < min_required then
        -- Si pas assez de place, n'afficher que le nom
        if available_width >= config.min_widget_width then
            visible_widgets.name = true
            widget_widths.name = available_width
        end
        return visible_widgets, widget_widths
    end
    
    -- Commencer par déterminer quels widgets sont visibles
    local total_weight = 0
    local widget_count = 0
    
    -- Priorité 1 : Nom et source sont toujours visibles si possible
    visible_widgets.name = true
    visible_widgets.source = true
    total_weight = total_weight + (config.widget_weights.name or 1) + (config.widget_weights.source or 1)
    widget_count = widget_count + 2
    
    -- Ajouter les autres widgets par ordre de priorité
    for i = 3, #config.widget_priority do -- Commencer à 3 car nom et source sont déjà ajoutés
        local widget = config.widget_priority[i]
        
        -- Calculer la largeur minimale actuelle
        local current_min_width = config.min_widget_width * widget_count
        
        -- Vérifier si nous avons de la place pour un widget supplémentaire
        if current_min_width + config.min_widget_width <= available_width then
            visible_widgets[widget] = true
            total_weight = total_weight + (config.widget_weights[widget] or 1)
            widget_count = widget_count + 1
        else
            break -- Sortir dès que nous n'avons plus de place
        end
    end
    
    -- Maintenant calculer les largeurs basées sur les poids
    local width_unit = available_width / total_weight
    
    for widget in pairs(visible_widgets) do
        local weight = config.widget_weights[widget] or 1
        widget_widths[widget] = math.max(config.min_widget_width, math.floor(width_unit * weight))
    end
    
    -- Ajuster les largeurs pour utiliser précisément l'espace disponible (éviter les pixels perdus)
    local used_width = 0
    for _, width in pairs(widget_widths) do
        used_width = used_width + width
    end
    
    local remaining = available_width - used_width
    if remaining > 0 and widget_count > 0 then
        -- Distribuer les pixels restants équitablement
        local widgets_with_extra = math.min(widget_count, remaining)
        local i = 1
        
        for widget in pairs(visible_widgets) do
            if i <= widgets_with_extra then
                widget_widths[widget] = widget_widths[widget] + 1
                i = i + 1
            end
        end
    end
    
    return visible_widgets, widget_widths
end

-- Modifie la fonction drawInterface pour appliquer correctement la disparition des widgets
function drawInterface()
    local total_width = gfx.w
    
    -- Calculer quels widgets sont visibles et leurs largeurs
    local visible_widgets, widget_widths = calculateWidgetWidths(total_width)
    
    -- Préparer la liste des headers et paramètres de valeurs
    local headers = {}
    local value_params = {}
    local header_cells = {} -- Stocker les cellules de headers pour la détection de clic
    
    -- Fonction helper pour ajouter un paramètre
    local function addParam(key, name, type)
        if visible_widgets[key] then
            table.insert(headers, {name = name, width = widget_widths[key], type = type, key = key})
            table.insert(value_params, {key = key, type = type, width = widget_widths[key]})
        end
    end
    
    -- Ajouter les paramètres dans l'ordre de priorité
    for _, key in ipairs(config.widget_priority) do
        if key == "name" then
            addParam("name", "Name", "text")
        elseif key == "source" then
            addParam("source", "Source", "text")
        elseif key == "position" then
            addParam("position", "Position", "time")
        elseif key == "length" then
            addParam("length", "Length", "text")
        elseif key == "snap" then
            addParam("snap", "Snap", "time")
        elseif key == "fadein" then
            addParam("fadein", "FadeIn", "time")
        elseif key == "fadeout" then
            addParam("fadeout", "FadeOut", "time")
        elseif key == "volume" then
            addParam("volume", "Volume", "volume")
        elseif key == "takevol" then
            addParam("takevol", "TakeVol", "takevol")
        elseif key == "pitch" then
            addParam("pitch", "Pitch", "pitch")
        elseif key == "preserve_pitch" then
            addParam("preserve_pitch", "PresPitch", "bool")
        elseif key == "pan" then
            addParam("pan", "Pan", "pan")
        elseif key == "rate" then
            addParam("rate", "Rate", "rate")
        elseif key == "mute" then
            addParam("mute", "Mute", "bool")
        end
    end
    
    -- Dessiner les headers
    local x = 0
    for _, header in ipairs(headers) do
        local cell = drawHeaderCell(header.name, x, 0, header.width)
        cell.param_key = header.key
        table.insert(header_cells, cell)
        x = x + header.width
    end
    
    -- Obtenir les données de l'item sélectionné
    local item = r.GetSelectedMediaItem(0, 0)
    if not item then return end
    
    local take = r.GetActiveTake(item)
    if not take then return end
    
    -- Obtenir toutes les données
    local data = {
        name = take and ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2] or "",
        source = r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take), ""),
        position = r.GetMediaItemInfo_Value(item, "D_POSITION"),
        length = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
        snap = r.GetMediaItemInfo_Value(item, "D_SNAPOFFSET"),
        fadein = r.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
        fadeout = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
        volume = r.GetMediaItemInfo_Value(item, "D_VOL"),
        takevol = r.GetMediaItemTakeInfo_Value(take, "D_VOL"),
        pitch = r.GetMediaItemTakeInfo_Value(take, "D_PITCH"),
        pan = r.GetMediaItemTakeInfo_Value(take, "D_PAN"),
        rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
        preserve_pitch = r.GetMediaItemTakeInfo_Value(take, "B_PPITCH") == 1,
        mute = r.GetMediaItemInfo_Value(item, "B_MUTE") == 1
    }
    
    -- Dessiner les valeurs
    local controls = {}
    x = 0
    
    for _, param in ipairs(value_params) do
        if param.key == "source" then
            -- Traitement spécial pour la source
            local source_name = data.source
            local filename = source_name ~= "" and source_name:match("([^/\\]+)$") or "[No source]"
            
            controls.source = drawValueCell(truncateString(filename, param.width - 8), 
                                           x, config.entry_height, param.width)
            controls.source = {
                x = x, y = config.entry_height,
                w = param.width, h = config.entry_height,
                value = filename,
                full_source = source_name,
                param_type = "source"  -- Ajout important pour le type
            }
        else
            -- Traitement des autres valeurs
            controls[param.key] = drawValueCell(
                data[param.key],
                x, config.entry_height,
                param.width,
                state.active_control == param.key,
                param.type,
                param.key
            )
            controls[param.key].value = data[param.key]
        end
        
        x = x + param.width
    end
    
    -- Traiter les interactions de la souris
    handleMouseInput(data, gfx.mouse_x, gfx.mouse_y, controls, header_cells)
end

function checkForRestart()
    local restart_flag = r.GetExtState("MediaPropertiesToolbar", "force_restart")
    local need_restart = r.GetExtState("MediaPropertiesToolbar", "need_restart") == "1"
    
    if restart_flag ~= "" and restart_flag ~= state.last_restart_check or need_restart then
        state.last_restart_check = restart_flag
        r.SetExtState("MediaPropertiesToolbar", "need_restart", "0", false)
        
        -- Force complete restart
        gfx.quit()
        
        -- Use defer to reopen after a short delay
        r.defer(function()
            loadSettings() -- Reload settings first
            init() -- Reinitialize completely
            r.defer(loop) -- Restart main loop
        end)
        
        return true
    end
    return false
end

function loop()
    if checkForRestart() then
        return -- Skip rest of frame if we're restarting
    end
    -- Apply global style if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(nameDialog.ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end

    -- Clear background
    gfx.set(table.unpack(config.background_color))
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    
    -- Draw interface
    checkForSettingsUpdates()
    drawInterface()
    
    -- Check dock state
    local dock_state = gfx.dock(-1)
    if dock_state ~= state.dock_id or 
       (dock_state > 0) ~= state.is_docked then
        state.dock_id = dock_state
        state.is_docked = dock_state > 0
        saveDockState()
    end
    
    -- Handle window state
    local char = gfx.getchar()
    if char >= 0 then
        r.defer(loop)
    end
    
    -- Clean up styles
    if style_loader then
        style_loader.clearStyles(nameDialog.ctx, pushed_colors, pushed_vars)
    end
    
    gfx.update()
end

init()
loop()