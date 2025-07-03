-- @description MediaPropertiesToolbar
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
local sl = nil
local pc = 0
local pv = 0

local file = io.open(sp, "r")
if file then
  file:close()
  local loader_func = dofile(sp)
  if loader_func then
    sl = loader_func()
  end
end

local settings_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Media Properties Toolbar/MediaPropertiesToolbar_settings.ini"

local config = {
    font_name = "Verdana",
    font_size = 14,
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
        text_hovered = {0.85, 0.85, 0.85, 1.0},
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
        "itemvol", 
        "takevol", 
        "pitch", 
        "preserve_pitch",
        "pan", 
        "rate", 
        "mute"
    },

    widget_weights = {     
        name = 2.5,                 
        source = 2.5,               
    },

    mouse = {
        itemvol_sensitivity = 0.05,
        pitch_sensitivity = 0.1,
        pan_sensitivity = 0.01,
        rate_sensitivity = 0.01,
        time_sensitivity = 0.01
    },

    itemvol = {
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

    undo = {
        wheel_timeout = 0.3,
        drag_timeout = 0.1
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
    double_click_handled = false, 
    double_click_cooldown = 0,
    undo_active = false,
    last_wheel_time = 0,
    current_undo_desc = "",
    drag_start_time = 0,
    wheel_undo_active = false,
    show_pan_dropdown = false,
    pan_dropdown_y = 0,
    header_buttons = {},
    hover_button = nil
}

local _,_,sid,cid=r.get_action_context()
r.SetToggleCommandState(sid,cid,1)
r.RefreshToolbar2(sid,cid)

function loadSettings()
    local file = io.open(settings_path, "r")
    if not file then return end
    
    local section
    for line in file:lines() do
        if line:match("^%s*$") or line:match("^%s*;") then
        elseif line:match("^%[(.+)%]$") then
            section = line:match("^%[(.+)%]$")
        elseif line:match("^%s*(.-)%s*=%s*(.-)%s*$") then
            local key, value = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
            
            if section == "colors" then
                if value:match("^{.+}$") then
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
            else
                if key == "font_name" then
                    config.font_name = value
                elseif key == "font_size" then
                    config.font_size = tonumber(value) or config.font_size
                elseif key == "entry_height" then
                    config.entry_height = tonumber(value) or config.entry_height
                elseif key == "name_width" then
                    config.name_width = tonumber(value) or config.name_width
                elseif key == "source_width" then
                    config.source_width = tonumber(value) or config.source_width
                elseif (key == "background_color" or key == "text_color" or 
                       key == "frame_color" or key == "frame_color_active") and value:match("^{.+}$") then
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
        
        if layout_changed then
            gfx.setfont(1, config.font_name, config.font_size)
            r.SetExtState("MediaPropertiesToolbar", "layout_changed", "0", false)
            
            gfx.quit()
            init()
        end
        
        return true
    end
    return false
end

function loadDockState()
    state.dock_id = tonumber(r.GetExtState("MediaPropertiesToolbar", "dock_id")) or 0
    state.is_docked = r.GetExtState("MediaPropertiesToolbar", "is_docked") == "1"
end

function saveDockState()
    r.SetExtState("MediaPropertiesToolbar", "dock_id", tostring(state.dock_id), true)
    r.SetExtState("MediaPropertiesToolbar", "is_docked", state.is_docked and "1" or "0", true)
end

function beginUndo(description)
    if not state.undo_active then
        r.Undo_BeginBlock()
        state.undo_active = true
        state.current_undo_desc = description
    end
end

function endUndo()
    if state.undo_active then
        r.Undo_EndBlock(state.current_undo_desc, -1)
        state.undo_active = false
        state.current_undo_desc = ""
    end
end

function getUndoDescription(param_name)
    local descriptions = {
        itemvol = "Adjust item volume",
        takevol = "Adjust take volume", 
        pitch = "Adjust item pitch",
        pan = "Adjust item pan",
        rate = "Adjust playback rate",
        position = "Move item position",
        length = "Change item length",
        fadein = "Adjust fade in",
        fadeout = "Adjust fade out",
        snap = "Adjust snap offset",
        preserve_pitch = "Toggle preserve pitch",
        mute = "Toggle item mute"
    }
    return descriptions[param_name] or "Edit item property"
end

function getResetDescription(param_name)
    local descriptions = {
        itemvol = "Reset item volume",
        takevol = "Reset take volume", 
        pitch = "Reset item pitch",
        pan = "Reset item pan",
        rate = "Reset playback rate",
        fadein = "Reset fade in",
        fadeout = "Reset fade out",
        snap = "Reset snap offset",
        preserve_pitch = "Reset preserve pitch",
        mute = "Reset item mute",
        length = "Reset item length"
    }
    return descriptions[param_name] or "Reset item property"
end

-- function drawExtraHeaderButtons(header, data)
--     -- Debug : vÃ©rifier si la fonction est appelÃ©e
--     r.ShowConsoleMsg("drawExtraHeaderButtons called for: " .. header.text .. "\n")
    
--     local buttons = {}
    
--     -- Force dessiner quelque chose de trÃ¨s visible n'importe oÃ¹
--     gfx.set(1, 0, 0, 1)  -- Rouge vif
--     gfx.rect(0, 0, 50, 50, 1)  -- Coin supÃ©rieur gauche
    
--     if header.text == "Pan" then
--         local button_w = 30  -- Plus gros
--         local button_h = 15  -- Plus haut
--         local button_x = 100  -- Position fixe complÃ¨tement diffÃ©rente
--         local button_y = 25   -- Position fixe complÃ¨tement diffÃ©rente
        
--         -- Force une couleur trÃ¨s visible
--         gfx.set(1, 0, 1, 1)  -- Magenta vif
--         gfx.rect(button_x, button_y, button_w, button_h, 1)
        
--         gfx.set(1, 1, 1, 1)  -- Blanc
--         gfx.x = button_x + 10
--         gfx.y = button_y + 5
--         gfx.drawstr("PAN")
        
--         buttons.pan_dropdown = {
--             x = button_x,
--             y = button_y,
--             w = button_w,
--             h = button_h
--         }
        
--     elseif header.text == "Length" then
--         local button_w = 30  -- Plus gros  
--         local button_h = 15  -- Plus haut
--         local button_x = 200  -- Position fixe complÃ¨tement diffÃ©rente
--         local button_y = 25   -- Position fixe complÃ¨tement diffÃ©rente
        
--         -- Force une couleur trÃ¨s visible
--         gfx.set(0, 1, 1, 1)  -- Cyan vif
--         gfx.rect(button_x, button_y, button_w, button_h, 1)
        
--         gfx.set(0, 0, 0, 1)  -- Noir
--         gfx.x = button_x + 8
--         gfx.y = button_y + 5
--         gfx.drawstr("LOOP")
        
--         buttons.loop_toggle = {
--             x = button_x,
--             y = button_y,
--             w = button_w,
--             h = button_h
--         }
--     end
    
--     return buttons
-- end

function showPanDropdownMenu(button_x, button_y, button_h)
    local screen_x = button_x + 5
    local screen_y = button_y + 20
    
    gfx.x = screen_x
    gfx.y = screen_y
    
    local current_chanmode = 0
    local item = r.GetSelectedMediaItem(0, 0)
    if item then
        local take = r.GetActiveTake(item)
        if take then
            current_chanmode = r.GetMediaItemTakeInfo_Value(take, "I_CHANMODE")
        end
    end
    
    local menu_items = {
        "Normal",
        "Reverse Stereo", 
        "Mono (Mix L+R)",
        "Mono (Left)",
        "Mono (Right)"
    }
    
    for i = 1, #menu_items do
        if i - 1 == current_chanmode then
            menu_items[i] = "!" .. menu_items[i]
        end
    end
    
    local menu_str = table.concat(menu_items, "|")
    local selection = gfx.showmenu(menu_str)
    
    if selection > 0 then
        local commands = {40176, 40177, 40178, 40179, 40180}
        r.Main_OnCommand(commands[selection], 0)
    end
end

function drawPanDropdown(x, y)
    return {x = x, y = y, w = 0, h = 0}
end

function toggleLoopSource()
    local selected_count = r.CountSelectedMediaItems(0)
    if selected_count == 0 then return end
    
    beginUndo("Toggle loop source")
    
    for i = 0, selected_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        if item then
            local current_state = r.GetMediaItemInfo_Value(item, "B_LOOPSRC")
            local new_state = current_state == 1 and 0 or 1
            r.SetMediaItemInfo_Value(item, "B_LOOPSRC", new_state)
            r.UpdateItemInProject(item)
        end
    end
    
    endUndo()
    r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
end

function showEnvelope(param_name)
    local commands = {
        takevol = 40693,
        pan = 40694,
        pitch = 41612,
        mute = 40695
    }
    
    local cmd = commands[param_name]
    if cmd then
        r.Main_OnCommand(cmd, 0)
    end
end

function init()
    loadSettings()
    loadDockState()
    
    local title = 'Media Properties Toolbar'
    local docked = state.is_docked and state.dock_id or 0
    local x, y = 100, 100
    local w = 1200  
    local h = config.entry_height * 2
    
    gfx.init(title, w, h, docked, x, y)
    gfx.setfont(1, config.font_name, config.font_size)
    
    r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
end

function truncateString(str, maxWidth)
    local str_w = gfx.measurestr(str)
    if str_w <= maxWidth then return str end
    
    local ellipsis = "..."
    local ellipsis_w = gfx.measurestr(ellipsis)
    local available_w = maxWidth - ellipsis_w - 4 
    
    while str_w > available_w and #str > 1 do
        local mid = math.floor(#str / 2)
        str = str:sub(1, mid-1) .. str:sub(mid+1)
        str_w = gfx.measurestr(str)
    end
    
    if #str > 6 then
        local mid = math.floor(#str / 2)
        return str:sub(1, mid-1) .. ellipsis .. str:sub(mid)
    else
        return str .. ellipsis 
    end
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
    
    return {
        x = x,
        y = y,
        w = w,
        h = config.entry_height,
        text = text
    }
end

function drawExtraHeaderButtons(header, data)
    local buttons = {}
    
    if header.text == "Pan" then
        local button_w = 12
        local button_h = 12
        local button_x = header.x + header.w - button_w - 10
        local button_y = header.y + 4
        
        local mx, my = gfx.mouse_x, gfx.mouse_y
        local is_hovered = mx >= button_x and mx < button_x + button_w and
                          my >= button_y and my < button_y + button_h
        
        -- if is_hovered then
        --     gfx.set(0.5, 0.5, 0.5, 1.0)
        -- else
        --     gfx.set(0.3, 0.3, 0.3, 1.0)
        -- end
        -- gfx.rect(button_x, button_y, button_w, button_h, 1)
        
        if is_hovered then
            gfx.set(table.unpack(config.colors.text_hovered))
        else
            gfx.set(table.unpack(config.colors.text_normal))
        end

        gfx.x = button_x
        gfx.y = button_y
        gfx.drawstr("â–¼")
        
        buttons.pan_dropdown = {
            x = button_x,
            y = button_y,
            w = button_w,
            h = button_h
        }
        
    elseif header.text == "Length" then
        local button_w = 10
        local button_h = 10
        local button_x = header.x + header.w - button_w - 5
        local button_y = header.y + 6
        
        local is_loop = false
        if data and state.last_item then
            is_loop = r.GetMediaItemInfo_Value(state.last_item, "B_LOOPSRC") == 1
        end
        
        local mx, my = gfx.mouse_x, gfx.mouse_y
        local is_hovered = mx >= button_x and mx < button_x + button_w and
                          my >= button_y and my < button_y + button_h
        
        if is_loop then
            gfx.set(table.unpack(config.colors.text_modified))
        elseif is_hovered then
            gfx.set(0.5, 0.5, 0.5, 1.0)
        else
            gfx.set(0.3, 0.3, 0.3, 1.0)
        end
        gfx.rect(button_x, button_y, button_w, button_h, 1)
        
        buttons.loop_toggle = {
            x = button_x,
            y = button_y,
            w = button_w,
            h = button_h
        }
    end
    
    return buttons
end

function drawValueCell(value, x, y, w, is_active, param_type, param_name)
    local is_negative = false
    local is_modified = false
    
    if param_type == "itemvol" or param_type == "takevol" then
        local db = 20 * math.log(value, 10)
        is_negative = db < 0
    elseif param_type == "pitch" or param_type == "pan" then
        is_negative = value < 0
    elseif param_type == "rate" then  
        is_negative = value < 1.0
    elseif param_type == "time" and param_name == "length" then
        local item = r.GetSelectedMediaItem(0, 0)
        if item then
            local take = r.GetActiveTake(item)
            if take then
                local is_midi = r.TakeIsMIDI(take)
                
                if is_midi then
                    is_negative = false
                    is_modified = false
                else
                    local source = r.GetMediaItemTake_Source(take)
                    local source_length = r.GetMediaSourceLength(source)
                    local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
                    local original_length = source_length / playrate
                    is_negative = value < original_length * 0.99 
                    is_modified = math.abs(value - original_length) > original_length * 0.01
                end
            end
        end
    end
    
    local is_modified = false
    if param_type == "itemvol" or param_type == "takevol" then
        is_modified = math.abs(value - 1.0) > 0.001
    elseif param_type == "pitch" or param_type == "pan" then 
        is_modified = math.abs(value) > 0.001
    elseif param_type == "rate" then
        is_modified = math.abs(value - 1.0) > 0.001
    elseif param_type == "time" and (param_name == "snap" or param_name == "fadein" or param_name == "fadeout") then
        is_modified = value > 0.001 
    elseif param_name == "length" then
        local original_length = nil
        if state.last_item then
            local take = r.GetActiveTake(state.last_item)
            if take then
                local is_midi = r.TakeIsMIDI(take)
                
                if not is_midi then
                    local source = r.GetMediaItemTake_Source(take)
                    local source_length = r.GetMediaSourceLength(source)
                    local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
                    original_length = source_length / playrate
                end
            end
        end
        
        if original_length then
            is_modified = math.abs(value - original_length) > (original_length * 0.01)
        else
            is_modified = false
        end
    end

    if param_type == "bool" then
        is_modified = value
        is_negative = not value
        value = value and "ON" or "OFF"
    end

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
        local minutes = math.floor(value / 60)
        local seconds = math.floor(value % 60)
        local ms = math.floor((value % 1) * 1000)
        display_value = string.format("%d:%02d.%03d", minutes, seconds, ms)
    elseif param_type == "itemvol" or param_type == "takevol" then
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

function updateItemsWithOffset(item_data, param_name, change)
    local selected_items = {}
    local selected_values = {}
    
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        local current_value
        
        if param_name == "itemvol" then
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
    
    for i, data in ipairs(selected_items) do
        local item = data.item
        local take = data.take
        local current_value = selected_values[i]
        local new_value
        
        if param_name == "itemvol" or param_name == "takevol" then
            local current_db = config.linear_to_db(current_value)
            local new_db = current_db + change
            
            if new_db < -150 then new_db = -150 end
            
            new_value = config.db_to_linear(new_db)
            
            if param_name == "itemvol" then
                r.SetMediaItemInfo_Value(item, "D_VOL", new_value)
            else
                r.SetMediaItemTakeInfo_Value(take, "D_VOL", new_value)
            end
        else
            new_value = current_value + change
            
            if param_name == "snap" or param_name == "fadein" or param_name == "fadeout" then
                if new_value < 0 then new_value = 0 end
            elseif param_name == "pitch" then
                if new_value < -60 then new_value = -60 end
                if new_value > 60 then new_value = 60 end
            elseif param_name == "pan" then
                if new_value < -1 then new_value = -1 end
                if new_value > 1 then new_value = 1 end
            elseif param_name == "rate" then
                if new_value < 0.01 then new_value = 0.01 end
                if new_value > 40 then new_value = 40 end
            end
            
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
end

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
            
            if (param_name == "snap" or param_name == "fadein" or param_name == "fadeout") and new_value < 0 then
                new_value = 0
            end
            
            return new_value
        end
        return current_value

    elseif param_name == "itemvol" or param_name == "takevol" then
        local current_db = 20 * math.log(current_value, 10)
        local retval, user_input = r.GetUserInputs(param_name, 1, 
            param_name == "itemvol" and "Item Volume (dB):" or "Take Volume (dB):", 
            string.format("%.1f", current_db))
        if not retval then return current_value end
        
        local new_db = tonumber(user_input)
        if new_db then
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
            if new_value < 0.01 then new_value = 0.01 end
            if new_value > 40 then new_value = 40 end
            return new_value
        end
        return current_value
    end
    
    return current_value
end

function updateItemValue(item_data, param_name, value)
    local selected_items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(selected_items, r.GetSelectedMediaItem(0, i))
    end
    
    if #selected_items == 0 then return end
    
    if param_name == "name" then
        local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Media Properties Toolbar/CP_TakeRenamer.lua"
        if r.file_exists(script_path) then
            dofile(script_path)
        end
    else
        for i, item in ipairs(selected_items) do
            local take = r.GetActiveTake(item)
            if take then
                if param_name == "itemvol" then 
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
    
    r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
end

function handleMouseInput(item_data, mx, my, controls, header_cells)
    local mouse_cap = gfx.mouse_cap
    local mouse_wheel = gfx.mouse_wheel
    gfx.mouse_wheel = 0
    
    local current_time = r.time_precise()
    
    if state.double_click_cooldown > 0 and current_time - state.double_click_cooldown < 0.3 then
        state.last_mouse_cap = mouse_cap
        return
    else
        state.double_click_cooldown = 0
    end

    if mouse_cap == 0 then
        state.double_click_handled = false
        
        if state.drag_active then
            endUndo()
            state.drag_active = false
            state.active_control = nil
        end
        
        for id, ctrl in pairs(controls) do
            if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
               my >= ctrl.y and my < ctrl.y + ctrl.h then
                if id == "source" then
                    drawTooltip(ctrl.full_source, mx + 10, my)
                end
            end
        end
    end

    if mouse_cap == 1 and state.last_mouse_cap == 0 then
        local is_double_click = (current_time - state.last_click_time) < 0.3
        state.last_click_time = current_time
    
        if is_double_click and not state.double_click_handled then
            state.double_click_handled = true
            state.double_click_cooldown = current_time  
            
            for _, header in ipairs(header_cells or {}) do
                if mx >= header.x and mx < header.x + header.w and
                   my >= header.y and my < header.y + header.h then
                    if header.text == "Pres Pitch" then
                        local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Media Properties Toolbar/CP_PitchShiftSelector.lua"
                        if r.file_exists(script_path) then
                            dofile(script_path)
                        end
                    elseif header.text == "Rate" then
                        local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Media Properties Toolbar/CP_StretchMarkersControl.lua"
                        if r.file_exists(script_path) then
                            dofile(script_path)
                        end
                    elseif header.text == "TakeVol" then
                        r.Main_OnCommand(42460, 0)
                        state.last_mouse_cap = mouse_cap
                        return
                    end
                    break
                end
            end
            
            for id, ctrl in pairs(controls) do
                if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
                   my >= ctrl.y and my < ctrl.y + ctrl.h then
                    if id == "source" then
                        local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Media Properties Toolbar/CP_SourceManager.lua"
                        if r.file_exists(script_path) then
                            dofile(script_path)
                        end
                    elseif id == "name" then
                        updateItemValue(item_data, id, nil)
                    else
                        local new_value = handleValueInput(id, ctrl.value)
                        if new_value then
                            beginUndo(getUndoDescription(id))
                            updateItemValue(item_data, id, new_value)
                            endUndo()
                        end
                    end
                    break
                end
            end
        else
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
                        state.drag_start_time = current_time
                        beginUndo(getUndoDescription(id))
                    else
                        beginUndo(getUndoDescription(id))
                        updateItemValue(item_data, id, not ctrl.value)
                        endUndo()
                        r.Main_OnCommand(r.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND"), 0)
                    end
                    break
                end
            end
            for button_name, button in pairs(state.header_buttons) do
                if mx >= button.x and mx < button.x + button.w and
                my >= button.y and my < button.y + button.h then
                    if button_name == "pan_dropdown" then
                        showPanDropdownMenu(button.x, button.y, button.h)
                    elseif button_name == "loop_toggle" then
                        toggleLoopSource()
                    end
                    break
                end
            end
        end
    end

    if mouse_cap == 2 and state.last_mouse_cap == 0 then
        for _, header in ipairs(header_cells or {}) do
            if mx >= header.x and mx < header.x + header.w and
               my >= header.y and my < header.y + header.h then
                
                local param_map = {
                    TakeVol = "takevol", 
                    Pan = "pan",
                    Pitch = "pitch",
                    Mute = "mute"
                }
                
                local param = param_map[header.text]
                if param then
                    showEnvelope(param)
                end
                
                state.last_mouse_cap = mouse_cap
                return
            end
        end
        
        for id, ctrl in pairs(controls) do
            if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
               my >= ctrl.y and my < ctrl.y + ctrl.h then
                local reset_value = nil
                if id == "itemvol" then reset_value = 1.0
                elseif id == "takevol" then reset_value = 1.0
                elseif id == "pitch" then reset_value = 0
                elseif id == "pan" then reset_value = 0
                elseif id == "rate" then reset_value = 1.0
                elseif id == "fadein" then reset_value = 0
                elseif id == "fadeout" then reset_value = 0
                elseif id == "snap" then reset_value = 0
                elseif id == "preserve_pitch" then reset_value = false
                elseif id == "mute" then reset_value = false
                elseif id == "length" then
                    beginUndo(getResetDescription("length"))
                    for i = 0, r.CountSelectedMediaItems(0) - 1 do
                        local item = r.GetSelectedMediaItem(0, i)
                        if item then
                            local take = r.GetActiveTake(item)
                            if take then
                                local is_midi = r.TakeIsMIDI(take)
                                
                                if not is_midi then
                                    local source = r.GetMediaItemTake_Source(take)
                                    local source_length = r.GetMediaSourceLength(source)
                                    local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
                                    local original_length = source_length / playrate
                                    r.SetMediaItemInfo_Value(item, "D_LENGTH", original_length)
                                    r.UpdateItemInProject(item)
                                end
                            end
                        end
                    end
                    endUndo()
                    return 
                end
                    
                if reset_value ~= nil then
                    beginUndo(getResetDescription(id))
                    updateItemValue(item_data, id, reset_value)
                    endUndo()
                end
                break
            end
        end
    end
    
    if mouse_wheel ~= 0 then
        local current_time = r.time_precise()
        
        for id, ctrl in pairs(controls) do
            if mx >= ctrl.x and mx < ctrl.x + ctrl.w and
               my >= ctrl.y and my < ctrl.y + ctrl.h then
                
                if not state.wheel_undo_active then
                    beginUndo(getUndoDescription(id))
                    state.wheel_undo_active = true
                    state.last_wheel_time = current_time
                end
                
                state.last_wheel_time = current_time
                
                if id == "itemvol" or id == "takevol" then
                    local db_change = mouse_wheel > 0 and config.itemvol.step_db or -config.itemvol.step_db
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
                            increment = 60  
                        elseif mx <= ctrl.text_metrics.sec_end then
                            increment = 1   
                        else
                            increment = 0.001  
                        end
                        local delta = mouse_wheel > 0 and increment or -increment
                        updateItemsWithOffset(item_data, id, delta)
                    end
                end
                break
            end
        end
    end
    
    if state.drag_active and state.active_control then
        local base_id = state.active_control:match("^([^_]+)")
        local ctrl = controls[base_id]
        if ctrl then
            if base_id == "itemvol" or base_id == "takevol" then
                local db_change = (mx - state.last_mouse_x) * config.mouse.itemvol_sensitivity
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

    state.last_mouse_cap = mouse_cap
    state.last_mouse_x = mx
    state.last_mouse_y = my
end

function calculateWidgetWidths(available_width)
    local widget_widths = {}
    local visible_widgets = {}
    
    widget_widths.name = config.name_width
    widget_widths.source = config.source_width
    
    local total_space_needed = widget_widths.name + widget_widths.source
    
    if available_width < total_space_needed then
        if available_width >= config.min_widget_width then
            visible_widgets.name = true
            widget_widths.name = available_width
        end
        return visible_widgets, widget_widths
    end
    
    visible_widgets.name = true
    visible_widgets.source = true
    
    local remaining_width = available_width - total_space_needed
    local other_widgets_count = 0
    
    for i = 3, #config.widget_priority do 
        if remaining_width >= config.min_widget_width then
            other_widgets_count = other_widgets_count + 1
            remaining_width = remaining_width - config.min_widget_width
        else
            break
        end
    end
    
    remaining_width = available_width - total_space_needed  
    if other_widgets_count > 0 then
        local width_per_widget = remaining_width / other_widgets_count
        
        for i = 3, #config.widget_priority do
            if i - 2 <= other_widgets_count then
                local widget = config.widget_priority[i]
                visible_widgets[widget] = true
                widget_widths[widget] = math.max(config.min_widget_width, math.floor(width_per_widget))
            end
        end
    end
    
    return visible_widgets, widget_widths
end

function drawInterface()
    local total_width = gfx.w
    
    local visible_widgets, widget_widths = calculateWidgetWidths(total_width)
    
    state.visible_widgets = visible_widgets
    state.widget_widths = widget_widths
    
    local headers = {}
    local value_params = {}
    local header_cells = {} 
    
    local function addParam(key, name, type)
        if visible_widgets[key] then
            table.insert(headers, {name = name, width = widget_widths[key], type = type, key = key})
            table.insert(value_params, {key = key, type = type, width = widget_widths[key]})
        end
    end
    
    for _, key in ipairs(config.widget_priority) do
        if key == "name" then
            addParam("name", "TakeName", "name")
        elseif key == "source" then
            addParam("source", "Source", "source")
        elseif key == "position" then
            addParam("position", "Position", "time")
        elseif key == "length" then
            addParam("length", "Length", "time") 
        elseif key == "snap" then
            addParam("snap", "Snap", "time")
        elseif key == "fadein" then
            addParam("fadein", "FadeIn", "time")
        elseif key == "fadeout" then
            addParam("fadeout", "FadeOut", "time")
        elseif key == "itemvol" then
            addParam("itemvol", "ItemVol", "itemvol")
        elseif key == "takevol" then
            addParam("takevol", "TakeVol", "takevol")
        elseif key == "pitch" then
            addParam("pitch", "Pitch", "pitch")
        elseif key == "preserve_pitch" then
            addParam("preserve_pitch", "Pres Pitch", "bool")
        elseif key == "pan" then
            addParam("pan", "Pan", "pan")
        elseif key == "rate" then
            addParam("rate", "Rate", "rate")
        elseif key == "mute" then
            addParam("mute", "Mute", "bool")
        end
    end
    
    local x = 0
    for _, header in ipairs(headers) do
        local cell = drawHeaderCell(header.name, x, 0, header.width)
        cell.param_key = header.key
        table.insert(header_cells, cell)
        x = x + header.width
    end
    
    local item = r.GetSelectedMediaItem(0, 0)
    if not item then return end
    
    state.last_item = item
    
    local take = r.GetActiveTake(item)
    if not take then return end
    
    local data = {
        name = take and ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2] or "",
        source = r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take), ""),
        position = r.GetMediaItemInfo_Value(item, "D_POSITION"),
        length = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
        snap = r.GetMediaItemInfo_Value(item, "D_SNAPOFFSET"),
        fadein = r.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
        fadeout = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
        itemvol = r.GetMediaItemInfo_Value(item, "D_VOL"),
        takevol = r.GetMediaItemTakeInfo_Value(take, "D_VOL"),
        pitch = r.GetMediaItemTakeInfo_Value(take, "D_PITCH"),
        pan = r.GetMediaItemTakeInfo_Value(take, "D_PAN"),
        rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
        preserve_pitch = r.GetMediaItemTakeInfo_Value(take, "B_PPITCH") == 1,
        mute = r.GetMediaItemInfo_Value(item, "B_MUTE") == 1
    }
    
    local controls = {}
    x = 0
    
    for _, param in ipairs(value_params) do
        if param.key == "source" then
            local source_name = data.source
            local filename = source_name ~= "" and source_name:match("([^/\\]+)$") or "[No source]"
            
            local cell = drawValueCell(
                truncateString(filename, param.width - 8),
                x, config.entry_height, 
                param.width,
                state.active_control == param.key,
                "source",
                param.key
            )
            
            controls.source = {
                x = x, 
                y = config.entry_height,
                w = param.width, 
                h = config.entry_height,
                value = filename,
                full_source = source_name,
                param_type = "source"
            }
        elseif param.key == "name" then
            local cell = drawValueCell(
                truncateString(data[param.key], param.width - 8),
                x, config.entry_height,
                param.width,
                state.active_control == param.key,
                "name",
                param.key
            )
            
            controls[param.key] = {
                x = x, 
                y = config.entry_height,
                w = param.width, 
                h = config.entry_height,
                value = data[param.key],
                param_type = "name"
            }
        else
            local cell = drawValueCell(
                data[param.key],
                x, config.entry_height,
                param.width,
                state.active_control == param.key,
                param.type,
                param.key
            )
            
            controls[param.key] = {
                x = x, 
                y = config.entry_height,
                w = param.width, 
                h = config.entry_height,
                value = data[param.key],
                param_type = param.type,
                text_metrics = cell.text_metrics
            }
        end
        
        x = x + param.width
    end
        state.header_buttons = {}
    for _, header in ipairs(header_cells) do
        local buttons = drawExtraHeaderButtons(header, data)
        for button_name, button_data in pairs(buttons) do
            state.header_buttons[button_name] = button_data
        end
    end
    handleMouseInput(data, gfx.mouse_x, gfx.mouse_y, controls, header_cells)
end

function checkForRestart()
    local restart_flag = r.GetExtState("MediaPropertiesToolbar", "force_restart")
    local need_restart = r.GetExtState("MediaPropertiesToolbar", "need_restart") == "1"
    
    if restart_flag ~= "" and restart_flag ~= state.last_restart_check or need_restart then
        state.last_restart_check = restart_flag
        r.SetExtState("MediaPropertiesToolbar", "need_restart", "0", false)
        
        gfx.quit()
        
        r.defer(function()
            loadSettings() 
            init() 
            r.defer(loop) 
        end)
        
        return true
    end
    return false
end

function loop()
    if r.GetToggleCommandState(sid,cid)==0 then
        gfx.quit()
        return
    end
    if checkForRestart() then
        return 
    end
    
    local current_time = r.time_precise()
    if state.wheel_undo_active and current_time - state.last_wheel_time > config.undo.wheel_timeout then
        endUndo()
        state.wheel_undo_active = false
    end
    
    gfx.set(table.unpack(config.background_color))
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    
    checkForSettingsUpdates()
    drawInterface()
    
    local dock_state = gfx.dock(-1)
    if dock_state ~= state.dock_id or 
       (dock_state > 0) ~= state.is_docked then
        state.dock_id = dock_state
        state.is_docked = dock_state > 0
        saveDockState()
    end
    
    local char = gfx.getchar()
    if char >= 0 then
        r.defer(loop)
    end
    
    gfx.update()
end

r.atexit(function()
  r.SetToggleCommandState(sid,cid,0)
  r.RefreshToolbar2(sid,cid)
end)

init()
loop()









