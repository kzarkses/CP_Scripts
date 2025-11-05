local r = reaper

local script_name = "CP_Goniometer_GUI"

local ctx = r.ImGui_CreateContext('CP_Goniometer')

r.gmem_attach("CP_Goniometer")

local config = {
    window_width = 600,
    window_height = 600,
    max_points = 4096,
    fade_alpha = 0.03,
    line_thickness = 1.0,
    line_alpha = 0.15,
    canvas_margin = 120,
    color_r = 0x33,
    color_g = 0xCC,
    color_b = 0xCC,
    update_rate = 0.016,
    curve_smoothness = 4,
    enable_smoothing = false
}

local state = {
    points = {},
    last_update = 0
}

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

function DrawGoniometer()
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local canvas_pos_x, canvas_pos_y = r.ImGui_GetCursorScreenPos(ctx)
    
    local window_width, window_height = r.ImGui_GetWindowSize(ctx)
    local canvas_width = window_width
    local canvas_height = window_height
    local canvas_size = math.min(canvas_width, canvas_height)
    
    local margin = config.canvas_margin
    local center_x = canvas_pos_x + canvas_width / 2
    local center_y = canvas_pos_y + canvas_height / 2
    local radius = (canvas_size / 2) - margin
    
    local bg_color = 0xFF000000
    r.ImGui_DrawList_AddRectFilled(draw_list, canvas_pos_x, canvas_pos_y, 
        canvas_pos_x + canvas_width, canvas_pos_y + canvas_height, bg_color)
    
    if #state.points > 1 then
        local draw_points = config.enable_smoothing and GetSmoothPoints(state.points, config.curve_smoothness) or state.points
        
        for i = 2, #draw_points do
            local curr = draw_points[i]
            local prev = draw_points[i - 1]
            
            local x = center_x - radius * curr.x
            local y = center_y - radius * curr.y
            local prev_x = center_x - radius * prev.x
            local prev_y = center_y - radius * prev.y
            
            local alpha = math.floor(curr.alpha * 255)
            local color = (alpha << 24) | (config.color_b << 16) | (config.color_g << 8) | config.color_r
            
            r.ImGui_DrawList_AddLine(draw_list, prev_x, prev_y, x, y, color, config.line_thickness)
        end
    end
    
    local fade_alpha = math.floor(config.fade_alpha * 255)
    local fade_color = (fade_alpha << 24) | 0x00000000
    r.ImGui_DrawList_AddRectFilled(draw_list, canvas_pos_x, canvas_pos_y,
        canvas_pos_x + canvas_width, canvas_pos_y + canvas_height, fade_color)
    
    r.ImGui_Dummy(ctx, canvas_width, canvas_height)
end

function MainLoop()
    local current_time = r.time_precise()
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | 
                        r.ImGui_WindowFlags_NoScrollbar() |
                        r.ImGui_WindowFlags_NoCollapse()
    
    r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())
    
    local visible, open = r.ImGui_Begin(ctx, 'CP Simple Goniometer', true, window_flags)
    
    if visible then
        if current_time - state.last_update >= config.update_rate then
            ReadGoniometerData()
            state.last_update = current_time
        end
        DrawGoniometer()
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(MainLoop)
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
    MainLoop()
end

function Stop()
    Cleanup()
end

function Cleanup()
    local _, _, section_id, command_id = r.get_action_context()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end

function Exit()
    Cleanup()
end

r.atexit(Exit)
ToggleScript()
