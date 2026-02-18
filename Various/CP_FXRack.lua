-- @description FXRack
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper
local extstate_id = "CP_FXRack"
local ctx = r.ImGui_CreateContext("FX Rack")
local style_loader = nil
local style_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_path) then
    local loader_func = dofile(style_path)
    if loader_func then
        style_loader = loader_func()
    end
end
local whitelist_fx = {
    {name = "JS: 1175 Compressor", category = "Dynamics"},
    {name = "JS: Compressor/Limiter", category = "Dynamics"},
    {name = "JS: Gate/Expander", category = "Dynamics"},
    {name = "JS: ReaEQ", category = "EQ"},
    {name = "JS: Parametric EQ", category = "EQ"},
    {name = "JS: High Pass Filter", category = "EQ"},
    {name = "JS: Low Pass Filter", category = "EQ"},
    {name = "JS: Chorus", category = "Modulation"},
    {name = "JS: Flanger", category = "Modulation"},
    {name = "JS: Phaser", category = "Modulation"},
    {name = "JS: Tremolo", category = "Modulation"},
    {name = "JS: Delay", category = "Delay/Reverb"},
    {name = "JS: Ping Pong Delay", category = "Delay/Reverb"},
    {name = "JS: ReaVerb", category = "Delay/Reverb"},
    {name = "JS: Tube Screamer", category = "Distortion"},
    {name = "JS: Distortion", category = "Distortion"},
    {name = "JS: Bit Crusher", category = "Distortion"},
    {name = "JS: Channel Mixer", category = "Utility"},
    {name = "JS: Stereo Width", category = "Utility"},
    {name = "JS: Volume/Pan Smoother", category = "Utility"},
    {name = "JS: LFO", category = "Utility"},
    {name = "VST: kHs Chorus", category = "Modulation"}
}
local whitelist_lookup = {}
for _, fx in ipairs(whitelist_fx) do
    whitelist_lookup[fx.name] = fx.category
end
local fx_modules = {}
local knob_size = 40
local knob_spacing = 8
local module_padding = 15
local module_header_height = 30
local module_width = knob_size * 3 + knob_spacing * 4 + module_padding * 2
local rows_per_page = 3
local knobs_per_row = 3
local selected_track = nil
local last_fx_count = 0
local last_track = nil
local window_flags = r.ImGui_WindowFlags_None()
local pushed_colors = 0
local pushed_vars = 0
local drag_state = {}
local knob_defaults = {}
local module_collapsed = {}
local module_bypass = {}
local module_solo = {}
local hovered_module = -1
local selected_module = -1
local drag_module_idx = -1
local scroll_offset = 0
local show_tooltips = true
local knob_mode = "Linear"
local context_menu_module = -1
local preset_name = ""
local presets = {}
local categories = {"All", "Dynamics", "EQ", "Modulation", "Delay/Reverb", "Distortion", "Utility"}
local selected_category = "All"
local search_filter = ""
local animation_values = {}
local last_time = r.time_precise()
local dock_id = 0
local window_width = 800
local window_height = 400
local first_frame = true
function LoadSettings()
    local saved_tooltips = r.GetExtState(extstate_id, "show_tooltips")
    if saved_tooltips ~= "" then
        show_tooltips = saved_tooltips == "1"
    end
    local saved_mode = r.GetExtState(extstate_id, "knob_mode")
    if saved_mode ~= "" then
        knob_mode = saved_mode
    end
    local saved_dock = r.GetExtState(extstate_id, "dock_id")
    if saved_dock ~= "" then
        dock_id = tonumber(saved_dock) or 0
    end
    local saved_width = r.GetExtState(extstate_id, "window_width")
    if saved_width ~= "" then
        window_width = tonumber(saved_width) or 800
    end
    local saved_height = r.GetExtState(extstate_id, "window_height")
    if saved_height ~= "" then
        window_height = tonumber(saved_height) or 400
    end
    LoadPresets()
end
function SaveSettings()
    r.SetExtState(extstate_id, "show_tooltips", show_tooltips and "1" or "0", true)
    r.SetExtState(extstate_id, "knob_mode", knob_mode, true)
    r.SetExtState(extstate_id, "dock_id", tostring(dock_id), true)
    r.SetExtState(extstate_id, "window_width", tostring(window_width), true)
    r.SetExtState(extstate_id, "window_height", tostring(window_height), true)
end
function LoadPresets()
    local saved = r.GetExtState(extstate_id, "presets")
    if saved ~= "" then
        local func = load("return " .. saved)
        if func then
            presets = func() or {}
        end
    end
end
function SavePresets()
    local str = SerializeTable(presets)
    r.SetExtState(extstate_id, "presets", str, true)
end
function SerializeTable(t)
    local function serialize(tbl, indent)
        indent = indent or ""
        local str = "{\n"
        for k, v in pairs(tbl) do
            str = str .. indent .. "  "
            if type(k) == "string" then
                str = str .. '["' .. k .. '"] = '
            else
                str = str .. "[" .. k .. "] = "
            end
            if type(v) == "table" then
                str = str .. serialize(v, indent .. "  ")
            elseif type(v) == "string" then
                str = str .. '"' .. v .. '"'
            else
                str = str .. tostring(v)
            end
            str = str .. ",\n"
        end
        str = str .. indent .. "}"
        return str
    end
    return serialize(t)
end
function ScanTrackFX(track)
    if not track then
        fx_modules = {}
        return
    end
    local fx_count = r.TrackFX_GetCount(track)
    local new_modules = {}
    local old_states = {}
    for _, module in ipairs(fx_modules) do
        old_states[module.guid] = {
            collapsed = module_collapsed[module.fx_index],
            bypass = module_bypass[module.fx_index],
            solo = module_solo[module.fx_index]
        }
    end
    module_collapsed = {}
    module_bypass = {}
    module_solo = {}
    for i = 0, fx_count - 1 do
        local retval, fx_name = r.TrackFX_GetFXName(track, i)
        if retval then
            local guid = r.TrackFX_GetFXGUID(track, i)
            local clean_name = fx_name:match("^JS:%s*(.+)$") or fx_name:match("^(.+)$")
            local full_name = fx_name:match("^JS:") and fx_name or "JS: " .. clean_name
            if whitelist_lookup[full_name] then
                local module = {
                    fx_index = i,
                    fx_name = clean_name,
                    full_name = full_name,
                    category = whitelist_lookup[full_name],
                    guid = guid,
                    params = {},
                    page = 0,
                    total_pages = 0
                }
                local param_count = r.TrackFX_GetNumParams(track, i)
                for p = 0, param_count - 1 do
                    local retval, param_name = r.TrackFX_GetParamName(track, i, p)
                    if retval then
                        local value = r.TrackFX_GetParam(track, i, p)
                        local retval, minval, maxval = r.TrackFX_GetParam(track, i, p)
                        local retval, formatted = r.TrackFX_GetFormattedParamValue(track, i, p)
                        table.insert(
                            module.params,
                            {
                                index = p,
                                name = param_name:sub(1, 8),
                                full_name = param_name,
                                value = value,
                                min = minval,
                                max = maxval,
                                formatted = formatted or string.format("%.2f", value),
                                default = GetParamDefault(track, i, p)
                            }
                        )
                    end
                end
                module.total_pages = math.ceil(#module.params / (knobs_per_row * rows_per_page))
                table.insert(new_modules, module)
                if old_states[guid] then
                    module_collapsed[i] = old_states[guid].collapsed
                    module_bypass[i] = old_states[guid].bypass
                    module_solo[i] = old_states[guid].solo
                else
                    module_collapsed[i] = false
                    module_bypass[i] = r.TrackFX_GetEnabled(track, i) == false
                    module_solo[i] = false
                end
            end
        end
    end
    fx_modules = new_modules
end
function GetParamDefault(track, fx_idx, param_idx)
    if not knob_defaults[fx_idx] then
        knob_defaults[fx_idx] = {}
    end
    if not knob_defaults[fx_idx][param_idx] then
        local current = r.TrackFX_GetParam(track, fx_idx, param_idx)
        knob_defaults[fx_idx][param_idx] = current
    end
    return knob_defaults[fx_idx][param_idx]
end
function UpdateParams(track)
    for _, module in ipairs(fx_modules) do
        for _, param in ipairs(module.params) do
            local value = r.TrackFX_GetParam(track, module.fx_index, param.index)
            if math.abs(value - param.value) > 0.001 then
                param.value = value
                local retval, formatted = r.TrackFX_GetFormattedParamValue(track, module.fx_index, param.index)
                param.formatted = formatted or string.format("%.2f", value)
            end
        end
        module_bypass[module.fx_index] = r.TrackFX_GetEnabled(track, module.fx_index) == false
    end
end
function DrawKnob(id, label, value, min, max, size, formatted, is_bypassed, fx_idx, param_idx)
    local item_width = size + 10
    local item_height = size + 30
    local start_x = r.ImGui_GetCursorPosX(ctx)
    local start_y = r.ImGui_GetCursorPosY(ctx)
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local pos_x, pos_y = r.ImGui_GetCursorScreenPos(ctx)
    local center_x = pos_x + size / 2
    local center_y = pos_y + size / 2
    local radius = size / 2 - 4
    local angle_min = math.pi * 0.75
    local angle_max = math.pi * 2.25
    local t = (value - min) / (max - min)
    local angle = angle_min + t * (angle_max - angle_min)
    local bg_color = is_bypassed and 0x2F2F2FFF or 0x3F3F3FFF
    local ring_color = is_bypassed and 0x505050FF or 0x808080FF
    local pointer_color = is_bypassed and 0x808080FF or 0xFFFFFFFF
    local track_color = is_bypassed and 0x404040FF or 0x606060FF
    r.ImGui_DrawList_AddCircleFilled(draw_list, center_x, center_y, radius, bg_color)
    for i = 0, 10 do
        local a = angle_min + (angle_max - angle_min) * i / 10
        local x1 = center_x + math.cos(a) * (radius - 8)
        local x2 = center_x + math.cos(a) * (radius - 4)
        local y1 = center_y + math.sin(a) * (radius - 8)
        local y2 = center_y + math.sin(a) * (radius - 4)
        r.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, track_color, 1)
    end
    r.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, radius, ring_color, 32, 2)
    local knob_x = center_x + math.cos(angle) * radius * 0.7
    local knob_y = center_y + math.sin(angle) * radius * 0.7
    r.ImGui_DrawList_AddLine(draw_list, center_x, center_y, knob_x, knob_y, pointer_color, 2)
    r.ImGui_DrawList_AddCircleFilled(draw_list, center_x, center_y, 3, pointer_color)
    r.ImGui_SetCursorScreenPos(ctx, pos_x, pos_y)
    r.ImGui_InvisibleButton(ctx, id, size, size)
    local is_active = r.ImGui_IsItemActive(ctx)
    local is_hovered = r.ImGui_IsItemHovered(ctx)
    local changed = false
    local new_value = value
    if r.ImGui_IsItemClicked(ctx, 1) then
        new_value = knob_defaults[fx_idx] and knob_defaults[fx_idx][param_idx] or 0.5
        changed = true
    elseif is_active then
        if not drag_state[id] then
            drag_state[id] = {
                start_y = select(2, r.ImGui_GetMousePos(ctx)),
                start_value = value,
                fine = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift()) or
                    r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift())
            }
        end
        local _, mouse_y = r.ImGui_GetMousePos(ctx)
        local delta_y = drag_state[id].start_y - mouse_y
        local sensitivity = drag_state[id].fine and 0.001 or 0.005
        if knob_mode == "Exponential" then
            sensitivity = sensitivity * (1 + t * 2)
        end
        new_value = drag_state[id].start_value + delta_y * sensitivity * (max - min)
        new_value = math.max(min, math.min(max, new_value))
        changed = new_value ~= value
    else
        drag_state[id] = nil
    end
    if is_hovered and show_tooltips then
        r.ImGui_BeginTooltip(ctx)
        r.ImGui_Text(ctx, label)
        r.ImGui_Text(ctx, "Value: " .. formatted)
        r.ImGui_TextDisabled(ctx, "Right-click to reset")
        if not (r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift())) then
            r.ImGui_TextDisabled(ctx, "Hold Shift for fine control")
        end
        r.ImGui_EndTooltip(ctx)
    end
    local text_width = r.ImGui_CalcTextSize(ctx, label)
    r.ImGui_SetCursorScreenPos(ctx, pos_x + (size - text_width) / 2, pos_y + size + 2)
    if is_bypassed then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x808080FF)
    end
    r.ImGui_Text(ctx, label)
    if is_bypassed then
        r.ImGui_PopStyleColor(ctx)
    end
    local value_width = r.ImGui_CalcTextSize(ctx, formatted)
    r.ImGui_SetCursorScreenPos(ctx, pos_x + (size - value_width) / 2, pos_y + size + 14)
    r.ImGui_TextDisabled(ctx, formatted)
    r.ImGui_SetCursorPos(ctx, start_x, start_y)
    r.ImGui_Dummy(ctx, item_width, item_height)
    return changed, new_value
end
function DrawModuleHeader(module, width)
    local header_height = module_header_height
    local button_size = 20
    local spacing = 5
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 0, 0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), spacing, 0)
    local collapsed = module_collapsed[module.fx_index] or false
    local arrow = collapsed and ">" or "v"
    if r.ImGui_Button(ctx, arrow .. "##collapse" .. module.fx_index, button_size, button_size) then
        module_collapsed[module.fx_index] = not collapsed
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, module.fx_name)
    local pos_x = r.ImGui_GetCursorPosX(ctx)
    local avail_width = r.ImGui_GetContentRegionAvail(ctx)
    r.ImGui_SetCursorPosX(ctx, pos_x + avail_width - (button_size + spacing) * 3)
    local is_bypassed = module_bypass[module.fx_index] or false
    if is_bypassed then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x606060FF)
    end
    if r.ImGui_Button(ctx, "B##bypass" .. module.fx_index, button_size, button_size) then
        module_bypass[module.fx_index] = not is_bypassed
        r.TrackFX_SetEnabled(selected_track, module.fx_index, not module_bypass[module.fx_index])
    end
    if is_bypassed then
        r.ImGui_PopStyleColor(ctx)
    end
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, is_bypassed and "Enable FX" or "Bypass FX")
    end
    r.ImGui_SameLine(ctx)
    local is_solo = module_solo[module.fx_index] or false
    if is_solo then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xCB8C3FFF)
    end
    if r.ImGui_Button(ctx, "S##solo" .. module.fx_index, button_size, button_size) then
        module_solo[module.fx_index] = not is_solo
        if not module_solo[module.fx_index] then
            for i, m in ipairs(fx_modules) do
                r.TrackFX_SetEnabled(selected_track, m.fx_index, true)
                module_solo[m.fx_index] = false
            end
        else
            for i, m in ipairs(fx_modules) do
                if m.fx_index ~= module.fx_index then
                    r.TrackFX_SetEnabled(selected_track, m.fx_index, false)
                    module_solo[m.fx_index] = false
                else
                    r.TrackFX_SetEnabled(selected_track, m.fx_index, true)
                end
            end
        end
    end
    if is_solo then
        r.ImGui_PopStyleColor(ctx)
    end
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, "Solo FX")
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "X##remove" .. module.fx_index, button_size, button_size) then
        r.TrackFX_Delete(selected_track, module.fx_index)
        ScanTrackFX(selected_track)
    end
    if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, "Remove FX")
    end
    r.ImGui_PopStyleVar(ctx, 2)
    r.ImGui_Separator(ctx)
end
function DrawModule(track, module, idx)
    local is_collapsed = module_collapsed[module.fx_index] or false
    local actual_width = is_collapsed and 60 or module_width
    local module_height = rows_per_page * (knob_size + 30) + module_header_height + module_padding * 2 + 40
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildBorderSize(), 1)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), is_collapsed and 5 or module_padding, module_padding)
    local is_hovered = hovered_module == idx
    if is_hovered then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), 0x808080FF)
    end
    r.ImGui_BeginChild(ctx, "Module_" .. module.fx_index, actual_width, module_height)
    if r.ImGui_IsWindowHovered(ctx, r.ImGui_HoveredFlags_ChildWindows()) then
        hovered_module = idx
    end
    if is_collapsed then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 0, 0)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 2, 0)
        local text_save = module.fx_name
        r.ImGui_PushTextWrapPos(ctx, r.ImGui_GetCursorPosX(ctx) + 50)
        local short_name = string.sub(module.fx_name, 1, 3)
        if r.ImGui_Button(ctx, ">##collapse" .. module.fx_index, 20, 20) then
            module_collapsed[module.fx_index] = false
        end
        r.ImGui_Text(ctx, short_name)
        r.ImGui_Separator(ctx)
        local is_bypassed = module_bypass[module.fx_index] or false
        if is_bypassed then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x606060FF)
        end
        if r.ImGui_Button(ctx, "B##bypass" .. module.fx_index, 20, 20) then
            module_bypass[module.fx_index] = not is_bypassed
            r.TrackFX_SetEnabled(selected_track, module.fx_index, not module_bypass[module.fx_index])
        end
        if is_bypassed then
            r.ImGui_PopStyleColor(ctx)
        end
        local is_solo = module_solo[module.fx_index] or false
        if is_solo then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xCB8C3FFF)
        end
        if r.ImGui_Button(ctx, "S##solo" .. module.fx_index, 20, 20) then
            module_solo[module.fx_index] = not is_solo
            if not module_solo[module.fx_index] then
                for i, m in ipairs(fx_modules) do
                    r.TrackFX_SetEnabled(selected_track, m.fx_index, true)
                    module_solo[m.fx_index] = false
                end
            else
                for i, m in ipairs(fx_modules) do
                    if m.fx_index ~= module.fx_index then
                        r.TrackFX_SetEnabled(selected_track, m.fx_index, false)
                        module_solo[m.fx_index] = false
                    else
                        r.TrackFX_SetEnabled(selected_track, m.fx_index, true)
                    end
                end
            end
        end
        if is_solo then
            r.ImGui_PopStyleColor(ctx)
        end
        if r.ImGui_Button(ctx, "X##remove" .. module.fx_index, 20, 20) then
            r.TrackFX_Delete(selected_track, module.fx_index)
            ScanTrackFX(selected_track)
        end
        r.ImGui_PopTextWrapPos(ctx)
        r.ImGui_PopStyleVar(ctx, 2)
    else
        DrawModuleHeader(module, actual_width)
        local is_bypassed = module_bypass[module.fx_index] or false
        local start_idx = module.page * knobs_per_row * rows_per_page
        local end_idx = math.min(start_idx + knobs_per_row * rows_per_page, #module.params)
        for row = 0, rows_per_page - 1 do
            for col = 0, knobs_per_row - 1 do
                local param_idx = start_idx + row * knobs_per_row + col + 1
                if param_idx <= #module.params then
                    local param = module.params[param_idx]
                    if col > 0 then
                        r.ImGui_SameLine(ctx, 0, knob_spacing)
                    end
                    local knob_id = string.format("knob_%d_%d", module.fx_index, param.index)
                    local changed, new_value =
                        DrawKnob(
                        knob_id,
                        param.name,
                        param.value,
                        param.min,
                        param.max,
                        knob_size,
                        param.formatted,
                        is_bypassed,
                        module.fx_index,
                        param.index
                    )
                    if changed then
                        r.TrackFX_SetParam(track, module.fx_index, param.index, new_value)
                        param.value = new_value
                        local retval, formatted = r.TrackFX_GetFormattedParamValue(track, module.fx_index, param.index)
                        param.formatted = formatted or string.format("%.2f", new_value)
                    end
                end
            end
        end
        if module.total_pages > 1 then
            r.ImGui_Separator(ctx)
            r.ImGui_SetCursorPosX(ctx, actual_width / 2 - 50)
            if r.ImGui_Button(ctx, "<", 20, 20) and module.page > 0 then
                module.page = module.page - 1
            end
            r.ImGui_SameLine(ctx)
            r.ImGui_Text(ctx, string.format("Page %d/%d", module.page + 1, module.total_pages))
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, ">", 20, 20) and module.page < module.total_pages - 1 then
                module.page = module.page + 1
            end
        end
    end
    r.ImGui_EndChild(ctx)
    if is_hovered then
        r.ImGui_PopStyleColor(ctx)
    end
    r.ImGui_PopStyleVar(ctx, 2)
    if r.ImGui_BeginDragDropSource(ctx) then
        drag_module_idx = idx
        r.ImGui_Text(ctx, "Moving: " .. module.fx_name)
        r.ImGui_EndDragDropSource(ctx)
    end
    if r.ImGui_BeginDragDropTarget(ctx) then
        if drag_module_idx >= 0 and drag_module_idx ~= idx then
            local from_idx = fx_modules[drag_module_idx + 1].fx_index
            local to_idx = fx_modules[idx + 1].fx_index
            r.TrackFX_CopyToTrack(track, from_idx, track, to_idx, true)
            ScanTrackFX(track)
        end
        r.ImGui_EndDragDropTarget(ctx)
    end
    if r.ImGui_IsItemClicked(ctx, 1) then
        context_menu_module = idx
        r.ImGui_OpenPopup(ctx, "ModuleContextMenu")
    end
end
function ShowAddFXMenu(track)
    if r.ImGui_BeginPopup(ctx, "AddFXPopup") then
        r.ImGui_Text(ctx, "Add FX")
        r.ImGui_Separator(ctx)
        r.ImGui_SetNextItemWidth(ctx, 200)
        local changed, new_filter = r.ImGui_InputText(ctx, "Search", search_filter)
        if changed then
            search_filter = new_filter
        end
        r.ImGui_SetNextItemWidth(ctx, 200)
        if r.ImGui_BeginCombo(ctx, "Category", selected_category) then
            for _, cat in ipairs(categories) do
                if r.ImGui_Selectable(ctx, cat, cat == selected_category) then
                    selected_category = cat
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        r.ImGui_Separator(ctx)
        r.ImGui_BeginChild(ctx, "FXList", 250, 300)
        for _, fx in ipairs(whitelist_fx) do
            local show = true
            if selected_category ~= "All" and fx.category ~= selected_category then
                show = false
            end
            if search_filter ~= "" and not fx.name:lower():find(search_filter:lower(), 1, true) then
                show = false
            end
            if show then
                if r.ImGui_Selectable(ctx, fx.name) then
                    local fx_idx = r.TrackFX_AddByName(track, fx.name, false, -1000)
                    if fx_idx >= 0 then
                        r.TrackFX_SetOpen(track, fx_idx, false)
                    end
                    last_fx_count = r.TrackFX_GetCount(track)
                    ScanTrackFX(track)
                    r.ImGui_CloseCurrentPopup(ctx)
                end
            end
        end
        r.ImGui_EndChild(ctx)
        r.ImGui_EndPopup(ctx)
    end
end
function ShowContextMenu()
    if r.ImGui_BeginPopup(ctx, "ModuleContextMenu") then
        local module = fx_modules[context_menu_module + 1]
        if module then
            r.ImGui_Text(ctx, module.fx_name)
            r.ImGui_Separator(ctx)
            if r.ImGui_MenuItem(ctx, "Open FX Window") then
                r.TrackFX_SetOpen(selected_track, module.fx_index, true)
            end
            if r.ImGui_MenuItem(ctx, "Bypass", nil, module_bypass[module.fx_index]) then
                module_bypass[module.fx_index] = not module_bypass[module.fx_index]
                r.TrackFX_SetEnabled(selected_track, module.fx_index, not module_bypass[module.fx_index])
            end
            r.ImGui_Separator(ctx)
            if r.ImGui_MenuItem(ctx, "Reset All Parameters") then
                for _, param in ipairs(module.params) do
                    local default = param.default or 0.5
                    r.TrackFX_SetParam(selected_track, module.fx_index, param.index, default)
                end
            end
            r.ImGui_Separator(ctx)
            if r.ImGui_MenuItem(ctx, "Remove") then
                r.TrackFX_Delete(selected_track, module.fx_index)
                ScanTrackFX(selected_track)
            end
        end
        r.ImGui_EndPopup(ctx)
    end
end
function ShowSettingsWindow()
    if r.ImGui_Begin(ctx, "FX Rack Settings", true, r.ImGui_WindowFlags_AlwaysAutoResize()) then
        r.ImGui_Text(ctx, "Display Settings")
        r.ImGui_Separator(ctx)
        local changed, new_tooltips = r.ImGui_Checkbox(ctx, "Show Tooltips", show_tooltips)
        if changed then
            show_tooltips = new_tooltips
            SaveSettings()
        end
        r.ImGui_Text(ctx, "Knob Mode:")
        r.ImGui_SameLine(ctx)
        if r.ImGui_RadioButton(ctx, "Linear", knob_mode == "Linear") then
            knob_mode = "Linear"
            SaveSettings()
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_RadioButton(ctx, "Exponential", knob_mode == "Exponential") then
            knob_mode = "Exponential"
            SaveSettings()
        end
        r.ImGui_Separator(ctx)
        r.ImGui_Text(ctx, "Presets")
        r.ImGui_SetNextItemWidth(ctx, 200)
        local changed, new_name = r.ImGui_InputText(ctx, "Name", preset_name)
        if changed then
            preset_name = new_name
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Save Preset") and preset_name ~= "" then
            SaveCurrentAsPreset(preset_name)
            preset_name = ""
        end
        if #presets > 0 then
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Load Preset:")
            for name, _ in pairs(presets) do
                if r.ImGui_Button(ctx, name) then
                    LoadPreset(name)
                end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "X##del" .. name) then
                    presets[name] = nil
                    SavePresets()
                end
            end
        end
        r.ImGui_End(ctx)
    end
end
function SaveCurrentAsPreset(name)
    local preset = {
        fx = {},
        timestamp = os.time()
    }
    for _, module in ipairs(fx_modules) do
        local fx_preset = {
            name = module.full_name,
            params = {}
        }
        for _, param in ipairs(module.params) do
            fx_preset.params[param.index] = param.value
        end
        table.insert(preset.fx, fx_preset)
    end
    presets[name] = preset
    SavePresets()
end
function LoadPreset(name)
    local preset = presets[name]
    if not preset or not selected_track then
        return
    end
    for i = r.TrackFX_GetCount(selected_track) - 1, 0, -1 do
        r.TrackFX_Delete(selected_track, i)
    end
    for _, fx_data in ipairs(preset.fx) do
        local fx_idx = r.TrackFX_AddByName(selected_track, fx_data.name, false, 1)
        if fx_idx >= 0 then
            for param_idx, value in pairs(fx_data.params) do
                r.TrackFX_SetParam(selected_track, fx_idx, param_idx, value)
            end
        end
    end
    ScanTrackFX(selected_track)
end
function AnimateValue(current, target, speed)
    local delta = target - current
    if math.abs(delta) < 0.001 then
        return target
    end
    return current + delta * speed
end
function Main()
    local current_time = r.time_precise()
    local dt = current_time - last_time
    last_time = current_time
    if style_loader and style_loader.applyToContext then
        local ok, colors, vars = style_loader.applyToContext(ctx)
        if ok then
            pushed_colors = colors
            pushed_vars = vars
        end
    end
    if first_frame then
        r.ImGui_SetNextWindowSize(ctx, window_width, window_height)
        if dock_id > 0 then
            r.ImGui_SetNextWindowDockID(ctx, dock_id)
        end
        first_frame = false
    end
    local visible, open = r.ImGui_Begin(ctx, "FX Rack", true, window_flags)
    if visible then
        window_width, window_height = r.ImGui_GetWindowSize(ctx)
        local new_dock = r.ImGui_GetWindowDockID(ctx)
        if new_dock ~= dock_id then
            dock_id = new_dock
            SaveSettings()
        end
        selected_track = r.GetSelectedTrack(0, 0)
        if selected_track ~= last_track then
            ScanTrackFX(selected_track)
            last_track = selected_track
            last_fx_count = selected_track and r.TrackFX_GetCount(selected_track) or 0
        elseif selected_track then
            local fx_count = r.TrackFX_GetCount(selected_track)
            if fx_count ~= last_fx_count then
                ScanTrackFX(selected_track)
                last_fx_count = fx_count
            else
                UpdateParams(selected_track)
            end
        end
        if selected_track then
            local _, track_name = r.GetTrackName(selected_track)
            r.ImGui_Text(ctx, "Track: " .. track_name)
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "+") then
                r.ImGui_OpenPopup(ctx, "AddFXPopup")
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Settings") then
                r.ImGui_OpenPopup(ctx, "SettingsWindow")
            end
            ShowAddFXMenu(selected_track)
            if r.ImGui_BeginPopup(ctx, "SettingsWindow") then
                ShowSettingsWindow()
                r.ImGui_EndPopup(ctx)
            end
            r.ImGui_Separator(ctx)
            if #fx_modules > 0 then
                r.ImGui_BeginChild(ctx, "ModulesArea", 0, 0)
                hovered_module = -1
                for i, module in ipairs(fx_modules) do
                    if i > 1 then
                        r.ImGui_SameLine(ctx)
                    end
                    DrawModule(selected_track, module, i - 1)
                end
                r.ImGui_EndChild(ctx)
            else
                r.ImGui_SetCursorPosY(ctx, r.ImGui_GetWindowHeight(ctx) / 2 - 20)
                r.ImGui_SetCursorPosX(ctx, r.ImGui_GetWindowWidth(ctx) / 2 - 100)
                r.ImGui_Text(ctx, "No supported FX found on this track.")
                r.ImGui_SetCursorPosX(ctx, r.ImGui_GetWindowWidth(ctx) / 2 - 80)
                r.ImGui_Text(ctx, "Click + to add a supported FX.")
            end
        else
            r.ImGui_SetCursorPosY(ctx, r.ImGui_GetWindowHeight(ctx) / 2 - 10)
            r.ImGui_SetCursorPosX(ctx, r.ImGui_GetWindowWidth(ctx) / 2 - 50)
            r.ImGui_Text(ctx, "No track selected")
        end
        ShowContextMenu()
        r.ImGui_End(ctx)
    end
    if style_loader and style_loader.clearStyles then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end
    if open then
        r.defer(Main)
    else
        SaveSettings()
    end
end
LoadSettings()
Main()










