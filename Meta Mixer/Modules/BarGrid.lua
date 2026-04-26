-- BarGrid.lua — Bar/beat grid calculation, configurable resolution, snapping
local BarGrid = {}
local r, C, ctx

function BarGrid.init(reaper_api, constants, imgui_ctx)
    r = reaper_api
    C = constants
    ctx = imgui_ctx
end

-- ============================================================================
-- GRID RESOLUTIONS
-- ============================================================================
BarGrid.GRID_RESOLUTIONS = {
    { name = "1 Bar",  beats = nil, bars = 1 },
    { name = "1/2",    beats = 2 },
    { name = "1/4",    beats = 1 },
    { name = "1/8",    beats = 0.5 },
    { name = "1/16",   beats = 0.25 },
    { name = "1/32",   beats = 0.125 },
    { name = "1/4T",   beats = 2/3 },
    { name = "1/8T",   beats = 1/3 },
    { name = "1/4D",   beats = 1.5 },
    { name = "1/8D",   beats = 0.75 },
}

-- ============================================================================
-- GET BAR LINES — with configurable grid resolution
-- ============================================================================
function BarGrid.GetBarLines(proj, item_pos, item_len, grid_idx)
    if item_len <= 0 then return {} end
    local item_end = item_pos + item_len
    local res = grid_idx and BarGrid.GRID_RESOLUTIONS[grid_idx] or nil

    local _, start_measure = r.TimeMap2_timeToBeats(proj, item_pos)
    local lines = {}
    local measure = start_measure

    while true do
        local bar_time = r.TimeMap2_beatsToTime(proj, 0, measure)
        if bar_time >= item_end then break end

        if bar_time >= item_pos then
            lines[#lines + 1] = {
                time = bar_time,
                rel_time = bar_time - item_pos,
                measure = measure + 1,
                is_bar = true,
                level = 0,
            }
        end

        local _, ts_num = r.TimeMap_GetTimeSigAtTime(proj, bar_time)
        local next_bar = r.TimeMap2_beatsToTime(proj, 0, measure + 1)
        local bar_len = next_bar - bar_time

        if bar_len > 0 then
            local beat_len = bar_len / ts_num

            if res and res.beats then
                -- Grid resolution subdivisions
                local grid_interval = beat_len * res.beats
                local steps = math.floor(bar_len / grid_interval + 0.5)
                for s = 1, steps - 1 do
                    local t = bar_time + s * grid_interval
                    if t > item_pos and t < item_end then
                        -- Determine level: beat boundary or subdivision
                        local beat_frac = (s * grid_interval) / beat_len
                        local is_beat = math.abs(beat_frac - math.floor(beat_frac + 0.5)) < 0.01
                        lines[#lines + 1] = {
                            time = t,
                            rel_time = t - item_pos,
                            measure = measure + 1,
                            is_bar = false,
                            level = is_beat and 1 or 2,
                        }
                    end
                end
            elseif not res or res.bars then
                -- Default: show beat lines
                if ts_num > 1 then
                    for b = 1, ts_num - 1 do
                        local beat_time = bar_time + beat_len * b
                        if beat_time > item_pos and beat_time < item_end then
                            lines[#lines + 1] = {
                                time = beat_time,
                                rel_time = beat_time - item_pos,
                                measure = measure + 1,
                                is_bar = false,
                                level = 1,
                            }
                        end
                    end
                end
            end
        end

        measure = measure + 1
    end

    return lines
end

-- ============================================================================
-- SNAP TO GRID — snap a project-time position to nearest grid line
-- ============================================================================
function BarGrid.SnapToGrid(proj, time, grid_idx)
    local res = grid_idx and BarGrid.GRID_RESOLUTIONS[grid_idx] or nil

    -- Snap to nearest bar if no subdivisions
    if not res or (res.bars and not res.beats) then
        return BarGrid.GetNearestBarTime(proj, time)
    end

    -- Find current measure
    local _, measure = r.TimeMap2_timeToBeats(proj, time)
    local bar_time = r.TimeMap2_beatsToTime(proj, 0, measure)
    local _, ts_num = r.TimeMap_GetTimeSigAtTime(proj, bar_time)
    local next_bar = r.TimeMap2_beatsToTime(proj, 0, measure + 1)
    local bar_len = next_bar - bar_time

    if bar_len <= 0 then return time end

    local beat_len = bar_len / ts_num
    local grid_interval = beat_len * res.beats

    -- Snap within current bar
    local offset = time - bar_time
    local grid_pos = math.floor(offset / grid_interval + 0.5) * grid_interval
    local snapped = bar_time + grid_pos

    -- Might snap to next bar's first grid point
    if snapped >= next_bar then snapped = next_bar end

    return snapped
end

-- ============================================================================
-- DRAW — render grid lines (used by ItemEditor inline rendering now)
-- ============================================================================
function BarGrid.Draw(draw_x, draw_y, draw_w, draw_h, item_pos, item_len, bar_lines)
    if not bar_lines or #bar_lines == 0 then return end
    local draw_list = r.ImGui_GetWindowDrawList(ctx)

    for _, line in ipairs(bar_lines) do
        local x = draw_x + (line.rel_time / item_len) * draw_w
        if x >= draw_x and x <= draw_x + draw_w then
            if line.is_bar then
                r.ImGui_DrawList_AddLine(draw_list, x, draw_y, x, draw_y + draw_h, C.COL_BAR_LINE, 1.0)
                r.ImGui_DrawList_AddText(draw_list, x + 2, draw_y + 1, C.COL_BAR_LABEL, tostring(line.measure))
            elseif line.level == 1 then
                r.ImGui_DrawList_AddLine(draw_list, x, draw_y, x, draw_y + draw_h, C.COL_BEAT_LINE, 1.0)
            else
                r.ImGui_DrawList_AddLine(draw_list, x, draw_y, x, draw_y + draw_h, C.COL_SUBDIV_LINE, 1.0)
            end
        end
    end
end

-- ============================================================================
-- GET NEAREST BAR TIME
-- ============================================================================
function BarGrid.GetNearestBarTime(proj, time)
    local _, measure = r.TimeMap2_timeToBeats(proj, time)
    local this_bar = r.TimeMap2_beatsToTime(proj, 0, measure)
    local next_bar = r.TimeMap2_beatsToTime(proj, 0, measure + 1)

    if math.abs(time - this_bar) <= math.abs(time - next_bar) then
        return this_bar
    else
        return next_bar
    end
end

-- ============================================================================
-- SPLIT AT BARS
-- ============================================================================
function BarGrid.SplitItemAtBars(item)
    if not item then return end

    local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_pos + item_len
    local proj = r.EnumProjects(-1)

    local _, start_measure = r.TimeMap2_timeToBeats(proj, item_pos)

    local split_points = {}
    local measure = start_measure + 1
    while true do
        local bar_time = r.TimeMap2_beatsToTime(proj, 0, measure)
        if bar_time >= item_end - 0.001 then break end
        if bar_time > item_pos + 0.001 then
            split_points[#split_points + 1] = bar_time
        end
        measure = measure + 1
    end

    if #split_points == 0 then return end

    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    for i = #split_points, 1, -1 do
        r.SplitMediaItem(item, split_points[i])
    end
    r.Undo_EndBlock("Split item at bar boundaries", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

return BarGrid
