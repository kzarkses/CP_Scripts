local r = reaper

local script_name = "CP_Goniometer_GFX"

r.gmem_attach("CP_Goniometer")

local config = {
    max_points = 1024,
    line_alpha = 0.6,
    fade_power = 0.2,
    canvas_margin = 60,
    color = "#33CCCC",
    grid_alpha = 0.2,
    grid_segments = 32,
    update_rate = 0.016
}

local state = {
    window_width = 600,
    window_height = 600,
    show_grid = true,
    dock_state = 0,
    points = {},
    has_new_data = false,
    grid_buffer = -1,
    needs_grid_redraw = true,
    last_update = 0
}

function HexToRGB(hex)
    hex = hex:gsub("#", "")
    local r = tonumber(hex:sub(1, 2), 16) / 255
    local g = tonumber(hex:sub(3, 4), 16) / 255
    local b = tonumber(hex:sub(5, 6), 16) / 255
    return r, g, b
end

function SaveSettings()
    r.SetExtState(script_name, "window_width", tostring(state.window_width), true)
    r.SetExtState(script_name, "window_height", tostring(state.window_height), true)
    r.SetExtState(script_name, "show_grid", state.show_grid and "1" or "0", true)
    r.SetExtState(script_name, "dock_state", tostring(state.dock_state), true)
end

function LoadSettings()
    if r.HasExtState(script_name, "window_width") then
        state.window_width = tonumber(r.GetExtState(script_name, "window_width")) or 600
    end
    if r.HasExtState(script_name, "window_height") then
        state.window_height = tonumber(r.GetExtState(script_name, "window_height")) or 600
    end
    if r.HasExtState(script_name, "show_grid") then
        state.show_grid = r.GetExtState(script_name, "show_grid") == "1"
    end
    if r.HasExtState(script_name, "dock_state") then
        state.dock_state = tonumber(r.GetExtState(script_name, "dock_state")) or 0
    end
end

function ResetSettings()
    r.DeleteExtState(script_name, "window_width", true)
    r.DeleteExtState(script_name, "window_height", true)
    r.DeleteExtState(script_name, "show_grid", true)
    r.DeleteExtState(script_name, "dock_state", true)
end

function ReadGoniometerData()
    local gmem_offset = 1000
    local write_pos = r.gmem_read(gmem_offset - 1)
    
    if not write_pos then
        state.points = {}
        state.has_new_data = false
        return
    end
    
    write_pos = math.floor(write_pos)
    state.points = {}
    
    local num_points = math.min(config.max_points, 4096)
    
    for i = 0, num_points - 1 do
        local idx = math.floor((write_pos - i) % 4096)
        if idx < 0 then idx = idx + 4096 end
        
        local lr = r.gmem_read(gmem_offset + idx * 2)
        local rr = r.gmem_read(gmem_offset + idx * 2 + 1)
        
        if lr and rr then
            local alpha = ((num_points - i) / num_points) ^ config.fade_power
            alpha = alpha * config.line_alpha
            table.insert(state.points, {x = lr, y = rr, alpha = alpha})
        end
    end
    
    state.has_new_data = #state.points > 0
end

function DrawGridToBuffer(center_x, center_y, radius)
    if state.grid_buffer == -1 then
        state.grid_buffer = 1
    end
    
    gfx.dest = state.grid_buffer
    gfx.setimgdim(state.grid_buffer, -1, -1)
    gfx.setimgdim(state.grid_buffer, gfx.w, gfx.h)
    
    gfx.set(0, 0, 0, 0)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    
    gfx.set(1, 1, 1, config.grid_alpha)
    
    gfx.line(center_x - radius, center_y, center_x + radius, center_y)
    gfx.line(center_x, center_y - radius, center_x, center_y + radius)
    
    local diag_offset = radius * 0.707
    gfx.line(center_x - diag_offset, center_y - diag_offset, center_x + diag_offset, center_y + diag_offset)
    gfx.line(center_x - diag_offset, center_y + diag_offset, center_x + diag_offset, center_y - diag_offset)
    
    for i = 0, config.grid_segments do
        local angle1 = (i / config.grid_segments) * 2 * math.pi
        local angle2 = ((i + 1) / config.grid_segments) * 2 * math.pi
        local x1 = center_x + math.cos(angle1) * radius
        local y1 = center_y + math.sin(angle1) * radius
        local x2 = center_x + math.cos(angle2) * radius
        local y2 = center_y + math.sin(angle2) * radius
        gfx.line(x1, y1, x2, y2)
    end
    
    gfx.dest = -1
    state.needs_grid_redraw = false
end

function DrawGoniometer()
    local canvas_width = gfx.w
    local canvas_height = gfx.h
    local canvas_size = math.min(canvas_width, canvas_height)
    
    local margin = config.canvas_margin
    local center_x = canvas_width / 2
    local center_y = canvas_height / 2
    local radius = (canvas_size / 2) - margin
    
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, canvas_width, canvas_height, 1)
    
    if state.show_grid then
        if state.needs_grid_redraw or state.grid_buffer == -1 then
            DrawGridToBuffer(center_x, center_y, radius)
        end
        gfx.blit(state.grid_buffer, 1.0, 0)
    end
    
    if #state.points > 1 then
        local skip = math.max(1, math.floor(#state.points / 2000))
        local color_r, color_g, color_b = HexToRGB(config.color)
        
        for i = skip + 1, #state.points, skip do
            local curr = state.points[i]
            local prev = state.points[i - skip]
            
            local x = center_x - radius * curr.x
            local y = center_y - radius * curr.y
            local prev_x = center_x - radius * prev.x
            local prev_y = center_y - radius * prev.y
            
            gfx.set(color_r, color_g, color_b, curr.alpha)
            gfx.line(prev_x, prev_y, x, y)
        end
    end
end

function MainLoop()
    local char = gfx.getchar()
    
    if char == -1 then
        return
    end
    
    if char == 103 then
        state.show_grid = not state.show_grid
        state.needs_grid_redraw = true
    end
    
    local current_time = r.time_precise()
    
    if current_time - state.last_update >= config.update_rate then
        ReadGoniometerData()
        state.last_update = current_time
    end
    
    if state.has_new_data then
        state.window_width = gfx.w
        state.window_height = gfx.h
        
        DrawGoniometer()
        gfx.update()
        
        state.has_new_data = false
    end
    
    r.defer(MainLoop)
end

function Init()
    LoadSettings()
    
    gfx.init("CP Goniometer", state.window_width, state.window_height, 0)
    
    if state.dock_state > 0 then
        gfx.dock(state.dock_state)
    end
    
    state.needs_grid_redraw = true
    state.last_update = r.time_precise()
end

function Exit()
    state.dock_state = gfx.dock(-1)
    SaveSettings()
    
    if state.grid_buffer ~= -1 then
        gfx.setimgdim(state.grid_buffer, 0, 0)
    end
end

r.atexit(Exit)
Init()
MainLoop()