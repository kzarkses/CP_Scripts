-- FXControl.lua — Cross-project XY pad FX parameter controller
local FXControl = {}
local r, C, H, W, S, ctx

function FXControl.init(reaper_api, constants, helpers, widgets, state, imgui_ctx)
    r = reaper_api
    C = constants
    H = helpers
    W = widgets
    S = state
    ctx = imgui_ctx
end

-- ============================================================================
-- STATE
-- ============================================================================
local fc = {
    -- XY pad
    pad_x = 0.5,
    pad_y = 0.5,
    pad_dragging = false,
    -- Scanned FX data: { fx_idx, fx_name, params = { { idx, name, value, base, sel_x, sel_y, range } } }
    fx_data = {},
    -- Track being controlled
    ctrl_track = nil,
    ctrl_track_guid = nil,
    -- Scan timer
    last_scan = 0,
    -- Figures
    figures_active = false,
    figures_mode = 0,   -- 0=circle, 1=square, 2=triangle, 3=lissajous
    figures_speed = 1.0,
    figures_time = 0,
}

local FIGURE_NAMES = { "Circle", "Square", "Triangle", "Lissajous" }
local PAD_SIZE = 200

-- ============================================================================
-- SCAN FX PARAMETERS from active project's selected track
-- ============================================================================
local function scanTrackFX()
    fc.fx_data = {}
    local track = fc.ctrl_track
    if not track then return end

    local fx_count = r.TrackFX_GetCount(track)
    for f = 0, fx_count - 1 do
        local _, fx_name = r.TrackFX_GetFXName(track, f, "")
        local clean = fx_name:gsub("^VST3?i?: ", ""):gsub("^JS: ", ""):gsub(" %(.+%)$", "")
        if #clean > 20 then clean = clean:sub(1, 19) .. "." end

        local params = {}
        local param_count = r.TrackFX_GetNumParams(track, f)
        for p = 0, param_count - 1 do
            local _, pname = r.TrackFX_GetParamName(track, f, p, "")
            local val = r.TrackFX_GetParam(track, f, p)
            if #pname > 18 then pname = pname:sub(1, 17) .. "." end
            params[#params + 1] = {
                idx = p,
                name = pname,
                value = val,
                base = val,
                sel_x = false,
                sel_y = false,
                range = 0.5,
            }
        end

        fc.fx_data[#fc.fx_data + 1] = {
            fx_idx = f,
            fx_name = clean,
            enabled = r.TrackFX_GetEnabled(track, f),
            params = params,
            collapsed = true,
        }
    end
end

-- ============================================================================
-- CAPTURE BASE VALUES — store current param values as gesture origin
-- ============================================================================
local function captureBase()
    local track = fc.ctrl_track
    if not track then return end
    for _, fx in ipairs(fc.fx_data) do
        for _, p in ipairs(fx.params) do
            p.base = r.TrackFX_GetParam(track, fx.fx_idx, p.idx)
        end
    end
end

-- ============================================================================
-- APPLY GESTURE — offset parameters based on XY delta from 0.5
-- ============================================================================
local function applyGesture()
    local track = fc.ctrl_track
    if not track then return end

    local dx = fc.pad_x - 0.5
    local dy = -(fc.pad_y - 0.5)  -- invert Y (up = positive)

    for _, fx in ipairs(fc.fx_data) do
        if fx.enabled then
            for _, p in ipairs(fx.params) do
                if p.sel_x or p.sel_y then
                    local offset = 0
                    if p.sel_x then offset = offset + dx * p.range * 2 end
                    if p.sel_y then offset = offset + dy * p.range * 2 end
                    local new_val = math.max(0, math.min(1, p.base + offset))
                    r.TrackFX_SetParam(track, fx.fx_idx, p.idx, new_val)
                end
            end
        end
    end
end

-- ============================================================================
-- FIGURES — pre-programmed motion patterns
-- ============================================================================
local function updateFigures()
    if not fc.figures_active then return end
    local now = r.time_precise()
    fc.figures_time = fc.figures_time + (now - (fc._last_fig_time or now)) * fc.figures_speed
    fc._last_fig_time = now

    local t = fc.figures_time
    local x, y = 0.5, 0.5
    local mode = fc.figures_mode

    if mode == 0 then -- Circle
        x = 0.5 + 0.4 * math.cos(t)
        y = 0.5 + 0.4 * math.sin(t)
    elseif mode == 1 then -- Square
        local phase = (t % (2 * math.pi)) / (2 * math.pi)
        if phase < 0.25 then
            x = 0.1 + phase * 4 * 0.8; y = 0.1
        elseif phase < 0.5 then
            x = 0.9; y = 0.1 + (phase - 0.25) * 4 * 0.8
        elseif phase < 0.75 then
            x = 0.9 - (phase - 0.5) * 4 * 0.8; y = 0.9
        else
            x = 0.1; y = 0.9 - (phase - 0.75) * 4 * 0.8
        end
    elseif mode == 2 then -- Triangle
        local phase = (t % (2 * math.pi)) / (2 * math.pi)
        if phase < 1/3 then
            local f = phase * 3
            x = 0.5 + f * 0.4; y = 0.9 - f * 0.8
        elseif phase < 2/3 then
            local f = (phase - 1/3) * 3
            x = 0.9 - f * 0.8; y = 0.1 + f * 0.4
        else
            local f = (phase - 2/3) * 3
            x = 0.1 + f * 0.4; y = 0.5 + f * 0.4
        end
    elseif mode == 3 then -- Lissajous
        x = 0.5 + 0.4 * math.sin(t * 3)
        y = 0.5 + 0.4 * math.cos(t * 2)
    end

    fc.pad_x = x
    fc.pad_y = y
    applyGesture()
end

-- ============================================================================
-- DRAW XY PAD
-- ============================================================================
local function DrawXYPad()
    local wx, wy = r.ImGui_GetCursorScreenPos(ctx)
    local draw_list = r.ImGui_GetWindowDrawList(ctx)

    -- Background
    r.ImGui_DrawList_AddRectFilled(draw_list, wx, wy,
        wx + PAD_SIZE, wy + PAD_SIZE, 0x1A1A1AFF)
    r.ImGui_DrawList_AddRect(draw_list, wx, wy,
        wx + PAD_SIZE, wy + PAD_SIZE, 0x444444FF, 0, 0, 1.0)

    -- Grid lines
    for i = 1, 3 do
        local frac = i / 4
        local gx = wx + frac * PAD_SIZE
        local gy = wy + frac * PAD_SIZE
        r.ImGui_DrawList_AddLine(draw_list, gx, wy, gx, wy + PAD_SIZE, 0x333333FF, 1.0)
        r.ImGui_DrawList_AddLine(draw_list, wx, gy, wx + PAD_SIZE, gy, 0x333333FF, 1.0)
    end

    -- Center crosshair
    local cx = wx + PAD_SIZE / 2
    local cy = wy + PAD_SIZE / 2
    r.ImGui_DrawList_AddLine(draw_list, cx - 5, cy, cx + 5, cy, 0x555555FF, 1.0)
    r.ImGui_DrawList_AddLine(draw_list, cx, cy - 5, cx, cy + 5, 0x555555FF, 1.0)

    -- Position dot
    local px = wx + fc.pad_x * PAD_SIZE
    local py = wy + fc.pad_y * PAD_SIZE
    r.ImGui_DrawList_AddCircleFilled(draw_list, px, py, 6, C.COL_KNOB_VALUE, 16)
    r.ImGui_DrawList_AddCircle(draw_list, px, py, 6, 0xFFFFFFCC, 16, 1.5)

    -- Invisible button for interaction
    r.ImGui_SetCursorScreenPos(ctx, wx, wy)
    r.ImGui_InvisibleButton(ctx, "##xy_pad", PAD_SIZE, PAD_SIZE)

    if r.ImGui_IsItemClicked(ctx, 0) then
        fc.pad_dragging = true
        captureBase()
    end

    if fc.pad_dragging then
        if r.ImGui_IsMouseDown(ctx, 0) then
            local mx, my = r.ImGui_GetMousePos(ctx)
            fc.pad_x = math.max(0, math.min(1, (mx - wx) / PAD_SIZE))
            fc.pad_y = math.max(0, math.min(1, (my - wy) / PAD_SIZE))
            if not fc.figures_active then
                applyGesture()
            end
        else
            fc.pad_dragging = false
        end
    end

    -- Labels
    r.ImGui_DrawList_AddText(draw_list, wx + 2, wy + PAD_SIZE - 14, 0x666666AA, "X")
    r.ImGui_DrawList_AddText(draw_list, wx + PAD_SIZE - 10, wy + 2, 0x666666AA, "Y")
end

-- ============================================================================
-- DRAW FX PARAMETER LIST
-- ============================================================================
local function DrawParamList()
    if #fc.fx_data == 0 then
        r.ImGui_TextDisabled(ctx, "No FX on selected track")
        return
    end

    local child_h = r.ImGui_GetContentRegionAvail(ctx) - 4
    if child_h < 50 then child_h = 200 end

    if r.ImGui_BeginChild(ctx, "##fx_params", 0, child_h) then
        for fi, fx in ipairs(fc.fx_data) do
            -- FX header (collapsible)
            local fx_flags = fx.collapsed and r.ImGui_TreeNodeFlags_None()
                or r.ImGui_TreeNodeFlags_DefaultOpen()
            local open = r.ImGui_TreeNode(ctx, fx.fx_name .. "##fx_" .. fi, fx_flags)

            -- Track collapsed state
            if open ~= (not fx.collapsed) then
                fx.collapsed = not open
            end

            if open then
                -- Quick assign buttons
                if r.ImGui_SmallButton(ctx, "All X##ax_" .. fi) then
                    for _, p in ipairs(fx.params) do p.sel_x = true end
                    captureBase()
                end
                r.ImGui_SameLine(ctx, 0, 4)
                if r.ImGui_SmallButton(ctx, "All Y##ay_" .. fi) then
                    for _, p in ipairs(fx.params) do p.sel_y = true end
                    captureBase()
                end
                r.ImGui_SameLine(ctx, 0, 4)
                if r.ImGui_SmallButton(ctx, "None##an_" .. fi) then
                    for _, p in ipairs(fx.params) do p.sel_x = false; p.sel_y = false end
                end

                for pi, p in ipairs(fx.params) do
                    local uid = fi .. "_" .. pi

                    -- X checkbox
                    local x_changed, x_new = r.ImGui_Checkbox(ctx, "X##x_" .. uid, p.sel_x)
                    if x_changed then p.sel_x = x_new; captureBase() end

                    -- Y checkbox
                    r.ImGui_SameLine(ctx, 0, 4)
                    local y_changed, y_new = r.ImGui_Checkbox(ctx, "Y##y_" .. uid, p.sel_y)
                    if y_changed then p.sel_y = y_new; captureBase() end

                    -- Param name + current value
                    r.ImGui_SameLine(ctx, 0, 6)
                    local col = (p.sel_x or p.sel_y) and 0xCCCCCCFF or 0x777777FF
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col)
                    r.ImGui_Text(ctx, p.name)
                    r.ImGui_PopStyleColor(ctx)

                    -- Range slider (only if assigned)
                    if p.sel_x or p.sel_y then
                        r.ImGui_SameLine(ctx, 0, 8)
                        r.ImGui_SetNextItemWidth(ctx, 60)
                        local rc, rv = r.ImGui_SliderDouble(ctx, "##rng_" .. uid,
                            p.range, 0.05, 1.0, "%.2f", r.ImGui_SliderFlags_NoInput())
                        if rc then p.range = rv end
                    end
                end

                r.ImGui_TreePop(ctx)
            end
        end
        r.ImGui_EndChild(ctx)
    end
end

-- ============================================================================
-- DRAW — main FX Control view (called from CP_MetaMixer when FX tab active)
-- ============================================================================
function FXControl.Draw()
    local proj = S.data.active_proj
    if not proj then
        r.ImGui_TextDisabled(ctx, "No active project")
        return
    end

    -- Determine controlled track: last selected track or master
    local sel_track = r.GetSelectedTrack(proj, 0)
    local track = sel_track or r.GetMasterTrack(proj)
    local track_guid = track and tostring(track) or nil

    -- Track changed → rescan
    if track_guid ~= fc.ctrl_track_guid then
        fc.ctrl_track = track
        fc.ctrl_track_guid = track_guid
        scanTrackFX()
        fc.pad_x = 0.5
        fc.pad_y = 0.5
    end

    -- Periodic param value refresh (don't rescan, just update values)
    local now = r.time_precise()
    if now - fc.last_scan > 0.5 and not fc.pad_dragging and not fc.figures_active then
        if track then
            for _, fx in ipairs(fc.fx_data) do
                fx.enabled = r.TrackFX_GetEnabled(track, fx.fx_idx)
                for _, p in ipairs(fx.params) do
                    p.value = r.TrackFX_GetParam(track, fx.fx_idx, p.idx)
                end
            end
        end
        fc.last_scan = now
    end

    -- Update figures motion
    updateFigures()

    -- === TOOLBAR ===
    local _, track_name = r.GetTrackName(track)
    r.ImGui_Text(ctx, "Track: " .. (track_name or "?"))

    r.ImGui_SameLine(ctx, 0, 15)
    if r.ImGui_SmallButton(ctx, "Rescan##rescan_fx") then
        scanTrackFX()
    end

    r.ImGui_SameLine(ctx, 0, 10)
    if r.ImGui_SmallButton(ctx, "Reset##reset_pad") then
        fc.pad_x = 0.5
        fc.pad_y = 0.5
        fc.figures_active = false
        applyGesture()
    end

    -- Figures controls
    r.ImGui_SameLine(ctx, 0, 15)
    local fig_col = fc.figures_active and C.COL_TOGGLE_ON or C.COL_TOGGLE_OFF
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), fig_col)
    if r.ImGui_SmallButton(ctx, "Figures##fig_toggle") then
        fc.figures_active = not fc.figures_active
        if fc.figures_active then
            captureBase()
            fc._last_fig_time = r.time_precise()
        end
    end
    r.ImGui_PopStyleColor(ctx)

    if fc.figures_active then
        r.ImGui_SameLine(ctx, 0, 5)
        r.ImGui_SetNextItemWidth(ctx, 90)
        local fig_name = FIGURE_NAMES[fc.figures_mode + 1] or "?"
        if r.ImGui_BeginCombo(ctx, "##fig_mode", fig_name) then
            for i, name in ipairs(FIGURE_NAMES) do
                if r.ImGui_Selectable(ctx, name .. "##fig_" .. i, fc.figures_mode == i - 1) then
                    fc.figures_mode = i - 1
                end
            end
            r.ImGui_EndCombo(ctx)
        end

        r.ImGui_SameLine(ctx, 0, 5)
        r.ImGui_SetNextItemWidth(ctx, 80)
        local sc, sv = r.ImGui_SliderDouble(ctx, "##fig_speed",
            fc.figures_speed, 0.1, 5.0, "%.1fx", r.ImGui_SliderFlags_NoInput())
        if sc then fc.figures_speed = sv end
    end

    -- === LAYOUT: XY Pad (left) + Param List (right) ===
    r.ImGui_Separator(ctx)

    DrawXYPad()
    r.ImGui_SameLine(ctx, 0, 15)

    -- Parameter list in remaining space
    r.ImGui_BeginGroup(ctx)
    r.ImGui_Text(ctx, "Parameters")
    r.ImGui_Separator(ctx)
    DrawParamList()
    r.ImGui_EndGroup(ctx)
end

return FXControl
