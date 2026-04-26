-- SessionView.lua — Session grid: tracks × items overview, subproject navigator
local SessionView = {}
local r, C, H, S, ctx

function SessionView.init(reaper_api, constants, helpers, state, imgui_ctx)
    r = reaper_api
    C = constants
    H = helpers
    S = state
    ctx = imgui_ctx
end

-- ============================================================================
-- STATE
-- ============================================================================
local sv = {
    track_data = {},        -- { track, name, color, items = { {item, name, pos, len, is_subproj, subproj_ptr, color} } }
    last_scan = 0,
    scroll_x = 0,
    zoom = 40,              -- pixels per second
    show_empty = false,     -- show tracks with no items
}

local CELL_H = 24
local TRACK_LABEL_W = 100
local MIN_CELL_W = 20

-- ============================================================================
-- SCAN ITEMS — collect all items on all tracks of active project
-- ============================================================================
local function scanItems()
    sv.track_data = {}
    local proj = S.data.active_proj
    if not proj then return end

    local track_count = r.CountTracks(proj)
    for t = 0, track_count - 1 do
        local track = r.GetTrack(proj, t)
        if not track then goto continue end

        local _, track_name = r.GetTrackName(track)
        local color = r.GetTrackColor(track)
        local item_count = r.CountTrackMediaItems(track)

        local items = {}
        for i = 0, item_count - 1 do
            local item = r.GetTrackMediaItem(track, i)
            if not item then goto next_item end

            local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
            local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            local take = r.GetActiveTake(item)
            local item_name = "Untitled"
            local is_subproj = false
            local subproj_ptr = nil
            local item_color = r.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")

            if take then
                local _, tname = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                if tname and tname ~= "" then item_name = tname end

                local source = r.GetMediaItemTake_Source(take)
                if source then
                    local src_type = r.GetMediaSourceType(source, "")
                    if src_type == "RPP_PROJECT" then
                        is_subproj = true
                        local _, src_fn = r.GetMediaSourceFileName(source, "")
                        if src_fn and src_fn ~= "" then
                            if item_name == "Untitled" then
                                item_name = src_fn:match("([^/\\]+)$") or "Subproject"
                                item_name = item_name:gsub("%.rpp$", ""):gsub("%.RPP$", "")
                            end
                            -- Find matching open project tab
                            local pidx = 0
                            while true do
                                local p, p_fn = r.EnumProjects(pidx)
                                if not p then break end
                                if p_fn and p_fn ~= "" then
                                    if src_fn:gsub("\\", "/"):lower() == p_fn:gsub("\\", "/"):lower() then
                                        subproj_ptr = p
                                        break
                                    end
                                end
                                pidx = pidx + 1
                            end
                        end
                    elseif item_name == "Untitled" then
                        local _, fn = r.GetMediaSourceFileName(source, "")
                        if fn and fn ~= "" then
                            item_name = fn:match("([^/\\]+)$") or "Untitled"
                        end
                    end
                end
            end

            if #item_name > 20 then item_name = item_name:sub(1, 19) .. "." end

            items[#items + 1] = {
                item = item,
                name = item_name,
                pos = pos,
                len = len,
                is_subproj = is_subproj,
                subproj_ptr = subproj_ptr,
                color = item_color,
                selected = r.IsMediaItemSelected(item),
            }

            ::next_item::
        end

        if #items > 0 or sv.show_empty then
            if #track_name > 12 then track_name = track_name:sub(1, 11) .. "." end
            sv.track_data[#sv.track_data + 1] = {
                track = track,
                name = track_name,
                color = color,
                items = items,
                index = t,
            }
        end

        ::continue::
    end
end

-- ============================================================================
-- COLOR HELPERS
-- ============================================================================
local function trackColorToU32(color)
    if not color or color == 0 then return 0x555555FF end
    local cr = ((color >> 0) & 0xFF) / 255
    local cg = ((color >> 8) & 0xFF) / 255
    local cb = ((color >> 16) & 0xFF) / 255
    return r.ImGui_ColorConvertDouble4ToU32(cr, cg, cb, 0.7)
end

local function itemColorToU32(color)
    if not color or color == 0 then return nil end
    -- REAPER custom color format: OS-native, bit 24 set = custom color
    if (color & 0x01000000) == 0 then return nil end
    local cr = ((color >> 0) & 0xFF) / 255
    local cg = ((color >> 8) & 0xFF) / 255
    local cb = ((color >> 16) & 0xFF) / 255
    return r.ImGui_ColorConvertDouble4ToU32(cr, cg, cb, 0.8)
end

-- ============================================================================
-- DRAW
-- ============================================================================
function SessionView.Draw()
    local proj = S.data.active_proj
    if not proj then
        r.ImGui_TextDisabled(ctx, "No active project")
        return
    end

    -- Periodic scan
    local now = r.time_precise()
    if now - sv.last_scan > 0.5 then
        scanItems()
        sv.last_scan = now
    end

    -- === TOOLBAR ===
    r.ImGui_Text(ctx, "Session View")
    r.ImGui_SameLine(ctx, 0, 15)

    -- Zoom
    r.ImGui_SetNextItemWidth(ctx, 100)
    local zc, zv = r.ImGui_SliderInt(ctx, "##sv_zoom", sv.zoom, 10, 200, "Zoom: %d")
    if zc then sv.zoom = zv end

    r.ImGui_SameLine(ctx, 0, 10)
    local _, show_empty = r.ImGui_Checkbox(ctx, "Empty##sv_empty", sv.show_empty)
    sv.show_empty = show_empty

    -- Project tabs overview
    r.ImGui_SameLine(ctx, 0, 20)
    for _, pd in ipairs(S.data.projects) do
        local col = pd.is_active and C.COL_PLAY or 0x666666FF
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col)
        if r.ImGui_SmallButton(ctx, pd.name .. "##proj_" .. pd.idx) then
            r.SelectProjectInstance(pd.ptr)
        end
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_SameLine(ctx, 0, 5)
    end
    r.ImGui_NewLine(ctx)

    r.ImGui_Separator(ctx)

    -- === GRID ===
    if #sv.track_data == 0 then
        r.ImGui_TextDisabled(ctx, "No items in active project")
        return
    end

    -- Find time range
    local proj_len = 0
    for _, td in ipairs(sv.track_data) do
        for _, item in ipairs(td.items) do
            local item_end = item.pos + item.len
            if item_end > proj_len then proj_len = item_end end
        end
    end
    if proj_len < 1 then proj_len = 10 end

    local avail_w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
    local grid_w = math.max(200, avail_w - 10)
    local grid_h = math.max(100, avail_h - 10)

    if r.ImGui_BeginChild(ctx, "##sv_grid", grid_w, grid_h) then
        local wx, wy = r.ImGui_GetCursorScreenPos(ctx)
        local draw_list = r.ImGui_GetWindowDrawList(ctx)
        local timeline_w = grid_w - TRACK_LABEL_W

        -- Background
        r.ImGui_DrawList_AddRectFilled(draw_list, wx, wy,
            wx + grid_w, wy + #sv.track_data * CELL_H, 0x1A1A1AFF)

        -- Time ruler (top)
        local ruler_h = 16
        r.ImGui_DrawList_AddRectFilled(draw_list, wx + TRACK_LABEL_W, wy,
            wx + grid_w, wy + ruler_h, 0x222222FF)

        -- Bar markers on ruler
        local _, start_measure = r.TimeMap2_timeToBeats(proj, 0)
        local measure = start_measure
        while true do
            local bar_time = r.TimeMap2_beatsToTime(proj, 0, measure)
            if bar_time > proj_len then break end
            local bar_x = wx + TRACK_LABEL_W + (bar_time / proj_len) * timeline_w * (sv.zoom / 40)
            bar_x = bar_x - sv.scroll_x
            if bar_x >= wx + TRACK_LABEL_W and bar_x <= wx + grid_w then
                r.ImGui_DrawList_AddLine(draw_list, bar_x, wy, bar_x, wy + ruler_h, 0x444444FF, 1.0)
                r.ImGui_DrawList_AddText(draw_list, bar_x + 2, wy + 1, 0x888888FF, tostring(measure + 1))
            end
            measure = measure + 1
        end

        -- Playback cursor
        local play_state = r.GetPlayStateEx(proj)
        if (play_state & 1) == 1 then
            local play_pos = r.GetPlayPositionEx(proj)
            local cur_x = wx + TRACK_LABEL_W + (play_pos / proj_len) * timeline_w * (sv.zoom / 40) - sv.scroll_x
            if cur_x >= wx + TRACK_LABEL_W and cur_x <= wx + grid_w then
                r.ImGui_DrawList_AddLine(draw_list, cur_x, wy,
                    cur_x, wy + ruler_h + #sv.track_data * CELL_H, C.COL_CURSOR_LINE, 1.0)
            end
        end

        -- Track rows
        local y_offset = wy + ruler_h
        for ti, td in ipairs(sv.track_data) do
            local row_y = y_offset + (ti - 1) * CELL_H

            -- Track label
            local label_col = trackColorToU32(td.color)
            r.ImGui_DrawList_AddRectFilled(draw_list,
                wx, row_y, wx + TRACK_LABEL_W, row_y + CELL_H, 0x222222FF)
            r.ImGui_DrawList_AddText(draw_list, wx + 4, row_y + 4, label_col, td.name)

            -- Row separator
            r.ImGui_DrawList_AddLine(draw_list,
                wx, row_y + CELL_H, wx + grid_w, row_y + CELL_H, 0x333333FF, 1.0)

            -- Items as colored blocks
            for _, item in ipairs(td.items) do
                local x1 = wx + TRACK_LABEL_W + (item.pos / proj_len) * timeline_w * (sv.zoom / 40) - sv.scroll_x
                local x2 = x1 + math.max(MIN_CELL_W, (item.len / proj_len) * timeline_w * (sv.zoom / 40))

                -- Clamp to visible area
                if x2 > wx + TRACK_LABEL_W and x1 < wx + grid_w then
                    x1 = math.max(wx + TRACK_LABEL_W, x1)
                    x2 = math.min(wx + grid_w, x2)

                    -- Cell color
                    local cell_col = itemColorToU32(item.color) or label_col
                    if item.is_subproj then cell_col = C.COL_DIVE end
                    if item.selected then cell_col = C.COL_KNOB_VALUE end

                    r.ImGui_DrawList_AddRectFilled(draw_list,
                        x1, row_y + 1, x2, row_y + CELL_H - 1, cell_col)
                    r.ImGui_DrawList_AddRect(draw_list,
                        x1, row_y + 1, x2, row_y + CELL_H - 1, 0x00000044, 0, 0, 1.0)

                    -- Item name (if cell wide enough)
                    if x2 - x1 > 30 then
                        local name = item.name
                        local max_chars = math.floor((x2 - x1 - 6) / 7)
                        if #name > max_chars then name = name:sub(1, max_chars) end
                        r.ImGui_DrawList_AddText(draw_list, x1 + 3, row_y + 4, 0xFFFFFFDD, name)
                    end

                    -- Subproject indicator
                    if item.is_subproj then
                        r.ImGui_DrawList_AddText(draw_list, x2 - 10, row_y + 4, 0xFFFFFFAA, "S")
                    end
                end
            end
        end

        -- Mouse interaction
        local total_h = ruler_h + #sv.track_data * CELL_H
        r.ImGui_SetCursorScreenPos(ctx, wx, wy)
        r.ImGui_InvisibleButton(ctx, "##sv_interact", grid_w, math.max(total_h, grid_h))

        if r.ImGui_IsItemHovered(ctx) then
            -- Scroll with mouse wheel
            local wheel = r.ImGui_GetMouseWheel(ctx)
            if wheel ~= 0 then
                local mods = r.ImGui_GetKeyMods(ctx)
                if mods == r.ImGui_Mod_Ctrl() then
                    -- Ctrl+Wheel = zoom
                    sv.zoom = math.max(10, math.min(200, sv.zoom + wheel * 5))
                else
                    -- Wheel = scroll
                    sv.scroll_x = math.max(0, sv.scroll_x - wheel * 30)
                end
            end

            -- Click = select item
            if r.ImGui_IsItemClicked(ctx, 0) then
                local mx, my = r.ImGui_GetMousePos(ctx)
                local track_idx = math.floor((my - y_offset) / CELL_H) + 1
                if track_idx >= 1 and track_idx <= #sv.track_data then
                    local td = sv.track_data[track_idx]
                    local clicked_item = nil
                    for _, item in ipairs(td.items) do
                        local x1 = wx + TRACK_LABEL_W + (item.pos / proj_len) * timeline_w * (sv.zoom / 40) - sv.scroll_x
                        local x2 = x1 + math.max(MIN_CELL_W, (item.len / proj_len) * timeline_w * (sv.zoom / 40))
                        if mx >= x1 and mx <= x2 then
                            clicked_item = item
                            break
                        end
                    end

                    if clicked_item then
                        -- Select this item in REAPER
                        r.Main_OnCommand(40289, 0)  -- Unselect all items
                        r.SetMediaItemSelected(clicked_item.item, true)
                        r.UpdateArrange()

                        -- If subproject, double-click to dive
                        if clicked_item.is_subproj and clicked_item.subproj_ptr then
                            if r.ImGui_IsMouseDoubleClicked(ctx, 0) then
                                r.SelectProjectInstance(clicked_item.subproj_ptr)
                            end
                        end
                    end
                end
            end

            -- Tooltip
            local mx, my = r.ImGui_GetMousePos(ctx)
            local track_idx = math.floor((my - y_offset) / CELL_H) + 1
            if track_idx >= 1 and track_idx <= #sv.track_data then
                local td = sv.track_data[track_idx]
                for _, item in ipairs(td.items) do
                    local x1 = wx + TRACK_LABEL_W + (item.pos / proj_len) * timeline_w * (sv.zoom / 40) - sv.scroll_x
                    local x2 = x1 + math.max(MIN_CELL_W, (item.len / proj_len) * timeline_w * (sv.zoom / 40))
                    if mx >= x1 and mx <= x2 then
                        local tip = item.name .. string.format("\n%.1fs (%.1f-%.1fs)", item.len, item.pos, item.pos + item.len)
                        if item.is_subproj then tip = tip .. "\nSubproject (double-click to dive)" end
                        r.ImGui_SetTooltip(ctx, tip)
                        break
                    end
                end
            end
        end

        r.ImGui_EndChild(ctx)
    end
end

return SessionView
