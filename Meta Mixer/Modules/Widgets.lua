-- Widgets.lua — Custom ImGui widgets (Knob, VU meters)
local Widgets = {}
local r, C, H, ctx

function Widgets.init(reaper_api, constants, helpers, imgui_ctx)
    r = reaper_api
    C = constants
    H = helpers
    ctx = imgui_ctx
end

-- Shared knob drag state
local knob_drag = {
    id = nil,
    start_y = 0,
    start_val = 0,
}

-- ============================================================================
-- CUSTOM KNOB WIDGET
-- ============================================================================
function Widgets.DrawKnob(id, value, default_value, size)
    size = size or C.KNOB_SIZE
    local radius = size / 2
    local changed = false
    local new_value = value

    local sx, sy = r.ImGui_GetCursorScreenPos(ctx)
    local cx, cy = sx + radius, sy + radius

    r.ImGui_InvisibleButton(ctx, id, size, size)
    local is_active = r.ImGui_IsItemActive(ctx)
    local is_hovered = r.ImGui_IsItemHovered(ctx)

    -- Drag interaction
    if is_active then
        if knob_drag.id ~= id then
            knob_drag.id = id
            local _, mouse_y = r.ImGui_GetMousePos(ctx)
            knob_drag.start_y = mouse_y
            knob_drag.start_val = value
        else
            local _, mouse_y = r.ImGui_GetMousePos(ctx)
            local dy = mouse_y - knob_drag.start_y
            local sensitivity = 0.004
            new_value = knob_drag.start_val - dy * sensitivity
            new_value = math.max(0, math.min(1, new_value))
            if new_value ~= value then changed = true end
        end
    else
        if knob_drag.id == id then knob_drag.id = nil end
    end

    -- Double-click reset
    if is_hovered and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
        new_value = default_value
        changed = true
    end

    -- Drawing
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local display_val = changed and new_value or value

    -- Background circle
    r.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, radius, C.COL_KNOB_BG, 24)

    -- Track arc (full range, dim)
    local segments = 20
    local step_full = (C.KNOB_ANGLE_MAX - C.KNOB_ANGLE_MIN) / segments
    for i = 0, segments - 1 do
        local a1 = C.KNOB_ANGLE_MIN + step_full * i
        local a2 = C.KNOB_ANGLE_MIN + step_full * (i + 1)
        local ar = radius - 3
        r.ImGui_DrawList_AddLine(draw_list,
            cx + math.cos(a1) * ar, cy + math.sin(a1) * ar,
            cx + math.cos(a2) * ar, cy + math.sin(a2) * ar,
            C.COL_KNOB_TRACK, 2)
    end

    -- Value arc (bright)
    local angle_val = C.KNOB_ANGLE_MIN + (C.KNOB_ANGLE_MAX - C.KNOB_ANGLE_MIN) * display_val
    local val_segments = math.max(1, math.floor(segments * display_val))
    if display_val > 0.01 then
        local step_val = (angle_val - C.KNOB_ANGLE_MIN) / val_segments
        for i = 0, val_segments - 1 do
            local a1 = C.KNOB_ANGLE_MIN + step_val * i
            local a2 = C.KNOB_ANGLE_MIN + step_val * (i + 1)
            local ar = radius - 3
            r.ImGui_DrawList_AddLine(draw_list,
                cx + math.cos(a1) * ar, cy + math.sin(a1) * ar,
                cx + math.cos(a2) * ar, cy + math.sin(a2) * ar,
                C.COL_KNOB_VALUE, 3)
        end
    end

    -- Indicator line from center to edge
    local ind_len = radius - 6
    local ind_x = cx + math.cos(angle_val) * ind_len
    local ind_y = cy + math.sin(angle_val) * ind_len
    r.ImGui_DrawList_AddLine(draw_list, cx, cy, ind_x, ind_y, C.COL_KNOB_LINE, 2)

    -- Center dot
    r.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, 3, C.COL_KNOB_LINE, 12)

    return changed, new_value, is_hovered or is_active
end

-- ============================================================================
-- VERTICAL VU METER
-- ============================================================================
function Widgets.DrawVMeter(x, y, width, height, peak_l, peak_r)
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local half_w = math.floor(width / 2) - 1

    r.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + half_w, y + height, C.COL_METER_BG)
    r.ImGui_DrawList_AddRectFilled(draw_list, x + half_w + 1, y, x + width, y + height, C.COL_METER_BG)

    local h_l = H.PeakToHeight(peak_l, height)
    if h_l > 0 then
        r.ImGui_DrawList_AddRectFilled(draw_list, x, y + height - h_l, x + half_w, y + height, H.GetMeterColor(peak_l, C))
    end
    local h_r = H.PeakToHeight(peak_r, height)
    if h_r > 0 then
        r.ImGui_DrawList_AddRectFilled(draw_list, x + half_w + 1, y + height - h_r, x + width, y + height, H.GetMeterColor(peak_r, C))
    end
end

-- ============================================================================
-- HORIZONTAL VU METER
-- ============================================================================
function Widgets.DrawHMeter(x, y, width, height, peak_l, peak_r)
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local half_h = math.floor(height / 2) - 1

    r.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + half_h, C.COL_METER_BG)
    r.ImGui_DrawList_AddRectFilled(draw_list, x, y + half_h + 1, x + width, y + height, C.COL_METER_BG)

    local w_l = H.PeakToHeight(peak_l, width)
    if w_l > 0 then
        r.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + w_l, y + half_h, H.GetMeterColor(peak_l, C))
    end
    local w_r = H.PeakToHeight(peak_r, width)
    if w_r > 0 then
        r.ImGui_DrawList_AddRectFilled(draw_list, x, y + half_h + 1, x + w_r, y + height, H.GetMeterColor(peak_r, C))
    end
end

return Widgets
