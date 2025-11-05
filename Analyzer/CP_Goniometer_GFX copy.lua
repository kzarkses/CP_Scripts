local r = reaper

local script_name = "CP_Goniometer_GFX"

r.gmem_attach("CP_Goniometer")

local config = {
    update_rate = 0.016,
    max_points = 4096,
    fade_alpha = 0.03,
    line_alpha = 0.15,
    canvas_margin = 60,
    main_color = "#33CCCC",
    curve_smoothness = 4,
    grid_alpha = 0.2
}

local state = {
    enable_smoothing = false,
    show_grid = true,
    dock_state = 0,
    window_width = 600,
    window_height = 600,
    points = {},
    last_update = 0,
    window_initialized = false
}

function HexToRGB(hex)
    hex = hex:gsub("#","")
    return tonumber("0x"..hex:sub(1,2))/255, 
           tonumber("0x"..hex:sub(3,4))/255, 
           tonumber("0x"..hex:sub(5,6))/255
end

function SaveState()
    r.SetExtState(script_name, "enable_smoothing", state.enable_smoothing and "1" or "0", true)
    r.SetExtState(script_name, "show_grid", state.show_grid and "1" or "0", true)
    r.SetExtState(script_name, "dock_state", tostring(state.dock_state), true)
    r.SetExtState(script_name, "window_width", tostring(state.window_width), true)
    r.SetExtState(script_name, "window_height", tostring(state.window_height), true)
end

function LoadState()
    if r.HasExtState(script_name, "enable_smoothing") then
        state.enable_smoothing = r.GetExtState(script_name, "enable_smoothing") == "1"
    end
    
    if r.HasExtState(script_name, "show_grid") then
        state.show_grid = r.GetExtState(script_name, "show_grid") == "1"
    end
    
    if r.HasExtState(script_name, "dock_state") then
        state.dock_state = tonumber(r.GetExtState(script_name, "dock_state")) or 0
    end
    
    if r.HasExtState(script_name, "window_width") then
        state.window_width = tonumber(r.GetExtState(script_name, "window_width")) or 600
    end
    
    if r.HasExtState(script_name, "window_height") then
        state.window_height = tonumber(r.GetExtState(script_name, "window_height")) or 600
    end
end

function CatmullRomSpline(t, p0, p1, p2, p3)
    local t2 = t * t
    local t3 = t2 * t
    
    local v0 = (p2 - p0) * 0.5
    local v1 = (p3 - p1) * 0.5
    
    return (2 * p1 - 2 * p2 + v0 + v1) * t3 +
           (-3 * p1 + 3 * p2 - 2 * v0 - v1) * t2 +
           v0 * t +
           p1
end

function GetSmoothPoints(points, segments_per_point)
    if #points < 2 then return points end
    
    local smooth = {}
    
    for i = 1, #points do
        local p0 = points[math.max(1, i - 1)]
        local p1 = points[i]
        local p2 = points[math.min(#points, i + 1)]
        local p3 = points[math.min(#points, i + 2)]
        
        if i == #points then
            table.insert(smooth, {x = p1.x, y = p1.y, alpha = p1.alpha})
        else
            for s = 0, segments_per_point - 1 do
                local t = s / segments_per_point
                local x = CatmullRomSpline(t, p0.x, p1.x, p2.x, p3.x)
                local y = CatmullRomSpline(t, p0.y, p1.y, p2.y, p3.y)
                local alpha = CatmullRomSpline(t, p0.alpha, p1.alpha, p2.alpha, p3.alpha)
                table.insert(smooth, {x = x, y = y, alpha = alpha})
            end
        end
    end
    
    return smooth
end

function ReadGoniometerData()
    local gmem_offset = 1000
    local write_pos = r.gmem_read(gmem_offset - 1)
    
    if not write_pos then
        state.points = {}
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
            local alpha = (num_points - i) / num_points
            alpha = alpha * config.line_alpha
            table.insert(state.points, {x = lr, y = rr, alpha = alpha})
        end
    end
end

function DrawGrid(center_x, center_y, radius)
    if not state.show_grid then return end
    
    gfx.set(1, 1, 1, config.grid_alpha)
    
    gfx.line(center_x - radius, center_y, center_x + radius, center_y)
    gfx.line(center_x, center_y - radius, center_x, center_y + radius)
    
    local diag_offset = radius * 0.707
    gfx.line(center_x - diag_offset, center_y - diag_offset, center_x + diag_offset, center_y + diag_offset)
    gfx.line(center_x - diag_offset, center_y + diag_offset, center_x + diag_offset, center_y - diag_offset)
    
    local circle_steps = 64
    for i = 0, circle_steps do
        local angle1 = (i / circle_steps) * 2 * math.pi
        local angle2 = ((i + 1) / circle_steps) * 2 * math.pi
        local x1 = center_x + math.cos(angle1) * radius
        local y1 = center_y + math.sin(angle1) * radius
        local x2 = center_x + math.cos(angle2) * radius
        local y2 = center_y + math.sin(angle2) * radius
        gfx.line(x1, y1, x2, y2)
    end
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
    
    DrawGrid(center_x, center_y, radius)
    
    if #state.points > 1 then
        local draw_points = state.enable_smoothing and GetSmoothPoints(state.points, config.curve_smoothness) or state.points
        
        local color_r, color_g, color_b = HexToRGB(config.main_color)
        
        for i = 2, #draw_points do
            local curr = draw_points[i]
            local prev = draw_points[i - 1]
            
            local x = center_x - radius * curr.x
            local y = center_y - radius * curr.y
            local prev_x = center_x - radius * prev.x
            local prev_y = center_y - radius * prev.y
            
            gfx.set(color_r, color_g, color_b, curr.alpha)
            gfx.line(prev_x, prev_y, x, y)
        end
    end
    
    gfx.set(0, 0, 0, config.fade_alpha)
    gfx.rect(0, 0, canvas_width, canvas_height, 1)
end

function MainLoop()
    local char = gfx.getchar()
    
    if char == -1 then
        return
    end
    
    if char == 32 then
        state.enable_smoothing = not state.enable_smoothing
    end
    
    if char == 103 then
        state.show_grid = not state.show_grid
    end
    
    local current_time = r.time_precise()
    
    if current_time - state.last_update >= config.update_rate then
        ReadGoniometerData()
        state.last_update = current_time
    end
    
    DrawGoniometer()
    gfx.update()
    
    r.defer(MainLoop)
end

function Init()
    LoadState()
    
    gfx.init("CP Goniometer", state.window_width, state.window_height, 0)
    
    if state.dock_state > 0 then
        gfx.dock(state.dock_state)
    end
    
    state.window_initialized = true
    state.last_update = r.time_precise()
end

function Exit()
    state.dock_state = gfx.dock(-1)
    state.window_width = gfx.w
    state.window_height = gfx.h
    SaveState()
end

r.atexit(Exit)
Init()
MainLoop()
