-- CP_Toolkit Widgets — Button, Text, Checkbox, Slider, Separator, Combo
-- Immediate-mode: call each frame, returns state

local Widgets = {}
local Core, Layout, Theme, Log, Icons, Keys  -- set via init

function Widgets.Init(core, layout, theme_mod)
    Core = core
    Layout = layout
    Theme = theme_mod
end

function Widgets.SetKeys(keys_mod)
    Keys = keys_mod
end

function Widgets.SetLog(log_mod)
    Log = log_mod
end

function Widgets.SetIcons(icons_mod)
    Icons = icons_mod
end

-- ============================================================================
-- TEXT
-- ============================================================================
function Widgets.Text(text, theme, opts)
    opts = opts or {}
    local color = opts.color or theme.colors.text
    local disabled = opts.disabled

    if disabled then color = theme.colors.text_disabled end

    if opts.font_size then
        Core.SetFont(opts.font_size, theme.fonts.default_face)
    end

    local tw, th = Core.MeasureText(text)

    -- Use aligned position (centers vertically on SameLine rows)
    local x, y = Layout.GetCursorPosAligned(th)

    if Core.IsVisible(x, y, tw, th) then
        Core.DrawText(text, x, y, color[1], color[2], color[3], color[4] or 1)
    end

    -- Restore default font
    if opts.font_size then
        Core.SetFont(theme.fonts.default_size, theme.fonts.default_face)
    end

    Layout.AdvanceCursor(tw, th)
end

function Widgets.TextColored(text, r, g, b, a, theme)
    Widgets.Text(text, theme, { color = { r, g, b, a or 1 } })
end

function Widgets.Header(text, theme)
    Core.SetFont(theme.fonts.header_size, theme.fonts.default_face, 66) -- 'B' = bold
    Widgets.Text(text, theme)
    Core.SetFont(theme.fonts.default_size, theme.fonts.default_face)
end

-- ============================================================================
-- BUTTON
-- ============================================================================
function Widgets.Button(id, label, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local fp_x = theme.frame_padding_x
    local fp_y = theme.frame_padding_y

    local tw, th = Core.MeasureText(label)
    local w = opts.width or (tw + fp_x * 2)
    local h = opts.height or (th + fp_y * 2)

    local clicked = false
    local hovered = Core.MouseInClippedRect(x, y, w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        if Core.MouseClicked(1) then
            Core.SetActive(id)
            if Log then Log.WidgetClicked(id, "Button", string.format("pos=(%d,%d) size=(%d,%d)", x, y, w, h)) end
        end
    end

    if Core.IsActive(id) and Core.MouseReleased(1) then
        if hovered then clicked = true end
        Core.ClearActive()
    end

    -- Colors
    local bg
    if Core.IsActive(id) and hovered then
        bg = theme.colors.button_active
    elseif hovered then
        bg = theme.colors.button_hovered
    else
        bg = theme.colors.button
    end

    -- Draw
    if Core.IsVisible(x, y, w, h) then
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        -- Center text
        local tx = x + math.floor((w - tw) / 2)
        local ty = y + math.floor((h - th) / 2)
        local tc = theme.colors.text
        Core.DrawText(label, tx, ty, tc[1], tc[2], tc[3], tc[4])
    end

    Layout.AdvanceCursor(w, h)
    return clicked
end

-- ============================================================================
-- CHECKBOX
-- ============================================================================
function Widgets.Checkbox(id, label, checked, theme)
    local x, y = Layout.GetCursorPos()
    local size = theme.checkbox_size
    local tw, th = Core.MeasureText(label)
    local total_w = size + 6 + tw
    local h = math.max(size, th)

    local toggled = false
    local hovered = Core.MouseInClippedRect(x, y, total_w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        if Core.MouseClicked(1) then
            toggled = true
            if Log then Log.WidgetChanged(id, "Checkbox", tostring(checked), tostring(not checked)) end
        end
    end

    local new_checked = toggled and not checked or (not toggled and checked)

    -- Draw box
    if Core.IsVisible(x, y, total_w, h) then
        local box_y = y + math.floor((h - size) / 2)
        local bg = hovered and theme.colors.frame_hovered or theme.colors.frame_bg
        Core.DrawRect(x, box_y, size, size, bg[1], bg[2], bg[3], bg[4])

        -- Border
        local bc = theme.colors.border
        Core.DrawRect(x, box_y, size, size, bc[1], bc[2], bc[3], bc[4], false)

        -- Filled square (accent color)
        if new_checked then
            local ac = theme.colors.accent
            local m = 3
            Core.DrawRect(x + m, box_y + m, size - m * 2, size - m * 2, ac[1], ac[2], ac[3], ac[4])
        end

        -- Label
        local tc = theme.colors.text
        local lx = x + size + 6
        local ly = y + math.floor((h - th) / 2)
        Core.DrawText(label, lx, ly, tc[1], tc[2], tc[3], tc[4])
    end

    Layout.AdvanceCursor(total_w, h)
    return toggled, new_checked
end

-- ============================================================================
-- SLIDER (horizontal)
-- ============================================================================
function Widgets.SliderInt(id, label, value, min_val, max_val, theme, opts)
    local changed, new_val = Widgets._Slider(id, label, value, min_val, max_val, theme, opts, true)
    return changed, new_val
end

function Widgets.SliderDouble(id, label, value, min_val, max_val, theme, opts)
    local changed, new_val = Widgets._Slider(id, label, value, min_val, max_val, theme, opts, false)
    return changed, new_val
end

function Widgets._Slider(id, label, value, min_val, max_val, theme, opts, is_int)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()

    local tw, th = Core.MeasureText(label)
    local slider_w = opts.width or math.max(100, avail_w - tw - 12)
    local h = theme.slider_height
    local total_w = slider_w + tw + 12

    local changed = false
    local new_value = value

    -- Slider track area
    local sx = x + tw + 8
    local sy = y + math.floor((math.max(h, th) - h) / 2)

    local hovered = Core.MouseInClippedRect(sx, sy, slider_w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        if Core.MouseClicked(1) then
            Core.SetActive(id)
            if Log then Log.WidgetClicked(id, "Slider", string.format("val=%s range=[%s,%s]", tostring(value), tostring(min_val), tostring(max_val))) end
        end
    end

    if Core.IsActive(id) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local ratio = math.max(0, math.min(1, (mx - sx) / slider_w))
            new_value = min_val + ratio * (max_val - min_val)
            if is_int then new_value = math.floor(new_value + 0.5) end
            if new_value ~= value then changed = true end
        else
            Core.ClearActive()
            if Log and changed then Log.WidgetChanged(id, "Slider", tostring(value), tostring(new_value)) end
        end
    end

    -- Draw
    if Core.IsVisible(x, y, total_w, math.max(h, th)) then
        -- Label
        local tc = theme.colors.text
        local ly = y + math.floor((math.max(h, th) - th) / 2)
        Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])

        -- Track
        local track_bg = hovered and theme.colors.frame_hovered or theme.colors.frame_bg
        Core.DrawRect(sx, sy, slider_w, h, track_bg[1], track_bg[2], track_bg[3], track_bg[4])

        -- Filled portion
        local display_val = changed and new_value or value
        local ratio = (display_val - min_val) / (max_val - min_val)
        ratio = math.max(0, math.min(1, ratio))
        local fill_w = math.floor(slider_w * ratio)
        local ac = theme.colors.accent
        if fill_w > 0 then
            Core.DrawRect(sx, sy, fill_w, h, ac[1], ac[2], ac[3], ac[4])
        end

        -- Grab handle
        local grab_w = 8
        local grab_x = sx + fill_w - math.floor(grab_w / 2)
        grab_x = math.max(sx, math.min(sx + slider_w - grab_w, grab_x))
        local grab_c = Core.IsActive(id) and theme.colors.accent_active or
                        (hovered and theme.colors.accent_hovered or theme.colors.accent)
        Core.DrawRect(grab_x, sy, grab_w, h, grab_c[1], grab_c[2], grab_c[3], grab_c[4])

        -- Value text (on top of slider)
        local val_str
        if is_int then
            val_str = tostring(math.floor(display_val))
        else
            val_str = string.format("%.2f", display_val)
        end
        local vw, vh = Core.MeasureText(val_str)
        local vx = sx + math.floor((slider_w - vw) / 2)
        local vy = sy + math.floor((h - vh) / 2)
        Core.DrawText(val_str, vx, vy, tc[1], tc[2], tc[3], tc[4])
    end

    Layout.AdvanceCursor(total_w, math.max(h, th))
    return changed, is_int and math.floor(new_value + 0.5) or new_value
end

-- ============================================================================
-- SEPARATOR
-- ============================================================================
function Widgets.Separator(theme)
    Layout.Separator(theme)
end

-- ============================================================================
-- COMBO / DROPDOWN
-- ============================================================================
function Widgets.Combo(id, label, current_index, items, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()

    local tw, th = Core.MeasureText(label)
    local combo_w = opts.width or math.max(120, avail_w - tw - 12)
    local h = theme.combo_height
    local total_w = combo_w + tw + 12

    -- Check for pending selection from popup (set on previous frame)
    local data = Core.GetWidgetData("combo_" .. id, { pending = nil })
    local selected = current_index
    local changed = false
    if data.pending ~= nil then
        selected = data.pending
        changed = true
        data.pending = nil
        Core.SetWidgetData("combo_" .. id, data)
    end

    -- Combo button area
    local cx = x + tw + 8
    local cy = y

    -- Block when ANY popup is open (prevents click-through)
    local hovered = Core.MouseInClippedRect(cx, cy, combo_w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
    end

    -- Toggle popup on click
    if hovered and Core.MouseClicked(1) then
        if Log then Log.Popup("Combo opening: " .. id, string.format("pos=(%d,%d) items=%d", cx, cy, #items)) end
        -- Open popup
        local popup_items = items
        local popup_x = cx
        local popup_y = cy + h + 1
        local popup_w = combo_w
        local item_h = h
        local popup_h = #items * item_h
        local popup_current = current_index
        local combo_data_id = "combo_" .. id

        -- Clamp popup to window
        local _, win_h = Core.GetWindowSize()
        if popup_y + popup_h > win_h - 4 then
            popup_h = math.min(popup_h, win_h - popup_y - 4)
        end

        Core.SetPopup(id, function()
            -- Skip close logic on the same frame popup was opened
            local is_new = Core.IsPopupNewThisFrame()

            -- Background
            local pbg = theme.colors.popup_bg
            Core.DrawRect(popup_x, popup_y, popup_w, popup_h, pbg[1], pbg[2], pbg[3], pbg[4])

            -- Border
            local pbc = theme.colors.border
            Core.DrawRect(popup_x, popup_y, popup_w, popup_h, pbc[1], pbc[2], pbc[3], pbc[4], false)

            -- Items
            local visible_count = math.floor(popup_h / item_h)
            for i = 1, math.min(#popup_items, visible_count) do
                local iy = popup_y + (i - 1) * item_h
                local item_hovered = Core.MouseInRect(popup_x, iy, popup_w, item_h)

                if item_hovered then
                    local hc = theme.colors.header_hovered
                    Core.DrawRect(popup_x + 1, iy, popup_w - 2, item_h, hc[1], hc[2], hc[3], hc[4])
                end

                if i == popup_current then
                    local ac = theme.colors.accent
                    Core.DrawRect(popup_x + 1, iy, 3, item_h, ac[1], ac[2], ac[3], ac[4])
                end

                local tc = theme.colors.text
                local text_y = iy + math.floor((item_h - th) / 2)
                Core.DrawText(popup_items[i], popup_x + 8, text_y, tc[1], tc[2], tc[3], tc[4])

                -- Select item on click (not on the open frame)
                if not is_new and item_hovered and Core.MouseClicked(1) then
                    if Log then Log.WidgetChanged(id, "Combo", tostring(popup_current), tostring(i) .. "=" .. popup_items[i]) end
                    -- Store selection in widget_data (read next frame by Combo)
                    local d = Core.GetWidgetData(combo_data_id, {})
                    d.pending = i
                    Core.SetWidgetData(combo_data_id, d)
                    Core.ClearPopup(id)
                    return  -- stop processing popup this frame
                end
            end

            -- Close popup on click outside (not on the open frame)
            if not is_new and Core.MouseClicked(1)
               and not Core.MouseInRect(popup_x, popup_y, popup_w, popup_h) then
                if Log then Log.Popup("Combo close-outside: " .. id) end
                Core.ClearPopup(id)
            end
        end)
    end

    -- Draw combo button
    if Core.IsVisible(x, y, total_w, h) then
        -- Label
        local tc = theme.colors.text
        local ly = y + math.floor((h - th) / 2)
        Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])

        -- Button background
        local bg = (hovered and not Core.HasPopup()) and theme.colors.frame_hovered or theme.colors.frame_bg
        Core.DrawRect(cx, cy, combo_w, h, bg[1], bg[2], bg[3], bg[4])

        -- Border
        local bc = theme.colors.border
        Core.DrawRect(cx, cy, combo_w, h, bc[1], bc[2], bc[3], bc[4], false)

        -- Current value text
        local display_idx = changed and selected or current_index
        local val_text = items[display_idx] or ""
        Core.DrawText(val_text, cx + 6, ly, tc[1], tc[2], tc[3], tc[4])

        -- Arrow icon
        if Icons then
            local icon_size = h
            local icon_x = cx + combo_w - icon_size
            if Core.HasPopup(id) then
                Icons.ChevronUp(icon_x, cy, icon_size, tc[1], tc[2], tc[3], 0.6)
            else
                Icons.ChevronDown(icon_x, cy, icon_size, tc[1], tc[2], tc[3], 0.6)
            end
        else
            local arrow = Core.HasPopup(id) and "^" or "v"
            local aw = Core.MeasureText(arrow)
            Core.DrawText(arrow, cx + combo_w - aw - 6, ly, tc[1], tc[2], tc[3], 0.6)
        end
    end

    Layout.AdvanceCursor(total_w, h)
    return changed, selected
end

-- ============================================================================
-- TABS
-- ============================================================================
function Widgets.TabBar(id, tabs, active_tab, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local h = theme.tab_height
    local new_active = active_tab
    local changed = false

    local tab_x = x
    for i, tab_label in ipairs(tabs) do
        local tw, th = Core.MeasureText(tab_label)
        local tab_w = tw + theme.frame_padding_x * 2
        local is_active = (i == active_tab)
        local hovered = Core.MouseInClippedRect(tab_x, y, tab_w, h) and not Core.HasPopup()

        if hovered and Core.MouseClicked(1) then
            new_active = i
            changed = true
            if Log then Log.WidgetChanged(id, "Tab", tostring(active_tab), tostring(i) .. "=" .. tab_label) end
        end

        -- Draw tab
        if Core.IsVisible(tab_x, y, tab_w, h) then
            local bg
            if is_active then
                bg = theme.colors.tab_active
            elseif hovered then
                bg = theme.colors.tab_hovered
            else
                bg = theme.colors.tab
            end
            Core.DrawRect(tab_x, y, tab_w, h, bg[1], bg[2], bg[3], bg[4])

            -- Active indicator (bottom line)
            if is_active then
                local ac = theme.colors.accent
                Core.DrawRect(tab_x, y + h - 2, tab_w, 2, ac[1], ac[2], ac[3], ac[4])
            end

            -- Text
            local tc = theme.colors.text
            local tx = tab_x + math.floor((tab_w - tw) / 2)
            local ty = y + math.floor((h - th) / 2)
            Core.DrawText(tab_label, tx, ty, tc[1], tc[2], tc[3], is_active and tc[4] or 0.7)
        end

        tab_x = tab_x + tab_w + 2
    end

    -- Underline full width
    local avail_w = Layout.GetAvailableWidth()
    local sc = theme.colors.separator
    Core.DrawLine(x, y + h - 1, x + avail_w, y + h - 1, sc[1], sc[2], sc[3], 0.3)

    Layout.AdvanceCursor(avail_w, h)
    return changed, new_active
end

-- ============================================================================
-- COLLAPSING HEADER / TREE NODE
-- ============================================================================
function Widgets.CollapsingHeader(id, label, is_open, theme)
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local tw, th = Core.MeasureText(label)
    local h = th + theme.frame_padding_y * 2
    local toggled = false

    local hovered = Core.MouseInClippedRect(x, y, avail_w, h) and not Core.HasPopup()

    if hovered and Core.MouseClicked(1) then
        toggled = true
    end

    local new_open = (toggled and (not is_open)) or ((not toggled) and is_open)
    if toggled and Log then Log.WidgetChanged(id, "CollapsingHeader", tostring(is_open), tostring(new_open)) end

    -- Draw
    if Core.IsVisible(x, y, avail_w, h) then
        local bg
        if hovered then
            bg = theme.colors.header_hovered
        else
            bg = theme.colors.header
        end
        Core.DrawRect(x, y, avail_w, h, bg[1], bg[2], bg[3], bg[4])

        -- Arrow icon + label
        local tc = theme.colors.text
        local ty = y + theme.frame_padding_y
        local icon_size = h
        if Icons then
            if new_open then
                Icons.TriangleDown(x + theme.frame_padding_x, y, icon_size, tc[1], tc[2], tc[3], 0.7)
            else
                Icons.TriangleRight(x + theme.frame_padding_x, y, icon_size, tc[1], tc[2], tc[3], 0.7)
            end
            Core.DrawText(label, x + theme.frame_padding_x + icon_size, ty, tc[1], tc[2], tc[3], tc[4])
        else
            local arrow = new_open and "v " or "> "
            Core.DrawText(arrow .. label, x + theme.frame_padding_x, ty, tc[1], tc[2], tc[3], tc[4])
        end
    end

    Layout.AdvanceCursor(avail_w, h)
    return toggled, new_open
end

-- ============================================================================
-- TOOLTIP
-- ============================================================================
-- Call AFTER the widget you want to attach the tooltip to.
-- Shows on hover with a small delay.
function Widgets.Tooltip(text, theme)
    local state = Core.GetState()
    if not state.hot then return end

    -- Track hover time
    local data = Core.GetWidgetData("_tooltip", { hot_id = nil, hover_start = 0, visible = false })
    local now = reaper.time_precise()

    if state.hot ~= data.hot_id then
        data.hot_id = state.hot
        data.hover_start = now
        data.visible = false
    elseif not data.visible and (now - data.hover_start) > 0.4 then
        data.visible = true
    end

    Core.SetWidgetData("_tooltip", data)

    if not data.visible then return end

    -- Defer drawing to tooltip layer (rendered last, on top of everything)
    local mx, my = Core.GetMousePos()
    Core.SetTooltip(function()
        local pad = 4
        local tw, th = Core.MeasureText(text)
        local tip_w = tw + pad * 2
        local tip_h = th + pad * 2
        local tip_x = mx + 12
        local tip_y = my - tip_h - 4

        -- Clamp to window
        local win_w, win_h = Core.GetWindowSize()
        if tip_x + tip_w > win_w then tip_x = mx - tip_w - 4 end
        if tip_y < 0 then tip_y = my + 18 end

        -- Background with slight shadow effect
        Core.DrawRect(tip_x + 1, tip_y + 1, tip_w, tip_h, 0, 0, 0, 0.3)
        local bg = theme.colors.popup_bg
        Core.DrawRect(tip_x, tip_y, tip_w, tip_h, bg[1], bg[2], bg[3], 1)
        local bc = theme.colors.border
        Core.DrawRect(tip_x, tip_y, tip_w, tip_h, bc[1], bc[2], bc[3], 0.6, false)
        local tc = theme.colors.text
        Core.DrawText(text, tip_x + pad, tip_y + pad, tc[1], tc[2], tc[3], tc[4])
    end)
end

-- ============================================================================
-- TREE NODE (hierarchical, with indent)
-- ============================================================================
function Widgets.TreeNode(id, label, is_open, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local tw, th = Core.MeasureText(label)
    local h = th + 2
    local indent = theme.indent or 16
    local toggled = false

    -- Icon + label area
    local icon_w = h  -- square icon area matching line height
    local hit_w = icon_w + tw + 4
    local hovered = Core.MouseInClippedRect(x, y, hit_w, h) and not Core.HasPopup()

    if hovered and Core.MouseClicked(1) then
        toggled = true
        if Log then Log.WidgetChanged(id, "TreeNode", tostring(is_open), tostring(not is_open)) end
    end

    local new_open = (toggled and (not is_open)) or ((not toggled) and is_open)

    -- Draw
    if Core.IsVisible(x, y, hit_w, h) then
        -- Hover highlight
        if hovered then
            local hc = theme.colors.header_hovered
            Core.DrawRect(x, y, Layout.GetAvailableWidth(), h, hc[1], hc[2], hc[3], 0.3)
        end

        local tc = theme.colors.text
        if Icons then
            if new_open then
                Icons.TriangleDown(x, y, icon_w, tc[1], tc[2], tc[3], 0.7)
            else
                Icons.TriangleRight(x, y, icon_w, tc[1], tc[2], tc[3], 0.7)
            end
            Core.DrawText(label, x + icon_w, y, tc[1], tc[2], tc[3], tc[4])
        else
            local arrow = new_open and "v " or "> "
            Core.DrawText(arrow .. label, x, y, tc[1], tc[2], tc[3], tc[4])
        end
    end

    Layout.AdvanceCursor(hit_w, h)

    -- If open, indent for children. Caller must call TreePop() after children.
    if new_open then
        Layout.Indent(indent)
    end

    return toggled, new_open
end

function Widgets.TreePop(theme)
    local indent = theme and theme.indent or 16
    Layout.Unindent(indent)
end

-- ============================================================================
-- KNOB (rotary control — based on Meta Mixer DrawKnob)
-- ============================================================================
function Widgets.Knob(id, label, value, default_value, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local size = opts.size or 40
    local radius = size / 2
    local sensitivity = opts.sensitivity or 0.004

    local changed = false
    local new_value = value

    -- Hit area
    local hovered = Core.MouseInClippedRect(x, y, size, size + 14) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
    end

    -- Drag interaction
    if hovered and Core.MouseClicked(1) then
        Core.SetActive(id)
    end

    if Core.IsActive(id) then
        if Core.MouseDown(1) then
            local _, dy = Core.MouseDelta()
            if dy ~= 0 then
                new_value = new_value - dy * sensitivity
                new_value = math.max(0, math.min(1, new_value))
                if new_value ~= value then changed = true end
            end
        else
            Core.ClearActive()
        end
    end

    -- Double-click reset
    if hovered and Core.MouseDoubleClicked() then
        new_value = default_value or 0.5
        changed = true
    end

    -- Draw
    if Core.IsVisible(x, y, size, size + 14) then
        local cx, cy = x + radius, y + radius
        local display_val = changed and new_value or value

        -- Background circle
        local bg = theme.colors.frame_bg
        Core.DrawRect(cx - radius, cy - radius, size, size, bg[1], bg[2], bg[3], bg[4])

        -- Arc angles
        local angle_min = math.pi * 0.75
        local angle_max = math.pi * 2.25
        local segments = 20

        -- Track arc (full range, dim)
        local track_c = theme.colors.border
        local ar = radius - 4
        for i = 0, segments - 1 do
            local a1 = angle_min + (angle_max - angle_min) * (i / segments)
            local a2 = angle_min + (angle_max - angle_min) * ((i + 1) / segments)
            Core.DrawLine(
                cx + math.cos(a1) * ar, cy + math.sin(a1) * ar,
                cx + math.cos(a2) * ar, cy + math.sin(a2) * ar,
                track_c[1], track_c[2], track_c[3], 0.4)
        end

        -- Value arc (bright)
        local angle_val = angle_min + (angle_max - angle_min) * display_val
        local val_segments = math.max(1, math.floor(segments * display_val))
        if display_val > 0.01 then
            local ac = theme.colors.accent
            for i = 0, val_segments - 1 do
                local a1 = angle_min + (angle_val - angle_min) * (i / val_segments)
                local a2 = angle_min + (angle_val - angle_min) * ((i + 1) / val_segments)
                Core.DrawLine(
                    cx + math.cos(a1) * ar, cy + math.sin(a1) * ar,
                    cx + math.cos(a2) * ar, cy + math.sin(a2) * ar,
                    ac[1], ac[2], ac[3], ac[4])
            end
        end

        -- Indicator line
        local ind_len = radius - 7
        local ind_x = cx + math.cos(angle_val) * ind_len
        local ind_y = cy + math.sin(angle_val) * ind_len
        local lc = theme.colors.text
        Core.DrawLine(cx, cy, ind_x, ind_y, lc[1], lc[2], lc[3], 0.9)

        -- Label below
        if label then
            local lw, lh = Core.MeasureText(label)
            local lx = x + math.floor((size - lw) / 2)
            local ly = y + size + 1
            local tc = theme.colors.text_disabled
            Core.DrawText(label, lx, ly, tc[1], tc[2], tc[3], tc[4])
        end
    end

    Layout.AdvanceCursor(size, size + 14)
    return changed, new_value
end

-- ============================================================================
-- VU METER (vertical)
-- ============================================================================
function Widgets.VMeter(id, peak_l, peak_r, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local width = opts.width or 12
    local height = opts.height or 80
    local half_w = math.floor(width / 2) - 1

    if Core.IsVisible(x, y, width, height) then
        -- Background
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, half_w, height, bg[1], bg[2], bg[3], bg[4])
        Core.DrawRect(x + half_w + 1, y, width - half_w - 1, height, bg[1], bg[2], bg[3], bg[4])

        -- Meter colors based on level
        local function meter_color(peak)
            if peak > 0.9 then return 0.9, 0.2, 0.2, 1  -- red
            elseif peak > 0.7 then return 0.9, 0.8, 0.2, 1  -- yellow
            else return 0.3, 0.75, 0.4, 1 end  -- green
        end

        -- Left channel
        local h_l = math.floor(math.max(0, math.min(1, peak_l)) * height)
        if h_l > 0 then
            local r, g, b, a = meter_color(peak_l)
            Core.DrawRect(x, y + height - h_l, half_w, h_l, r, g, b, a)
        end

        -- Right channel
        local h_r = math.floor(math.max(0, math.min(1, peak_r)) * height)
        if h_r > 0 then
            local r, g, b, a = meter_color(peak_r)
            Core.DrawRect(x + half_w + 1, y + height - h_r, width - half_w - 1, h_r, r, g, b, a)
        end
    end

    Layout.AdvanceCursor(width, height)
end

-- ============================================================================
-- VU METER (horizontal)
-- ============================================================================
function Widgets.HMeter(id, peak_l, peak_r, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local width = opts.width or 120
    local height = opts.height or 12
    local half_h = math.floor(height / 2) - 1

    if Core.IsVisible(x, y, width, height) then
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, width, half_h, bg[1], bg[2], bg[3], bg[4])
        Core.DrawRect(x, y + half_h + 1, width, height - half_h - 1, bg[1], bg[2], bg[3], bg[4])

        local function meter_color(peak)
            if peak > 0.9 then return 0.9, 0.2, 0.2, 1
            elseif peak > 0.7 then return 0.9, 0.8, 0.2, 1
            else return 0.3, 0.75, 0.4, 1 end
        end

        local w_l = math.floor(math.max(0, math.min(1, peak_l)) * width)
        if w_l > 0 then
            local r, g, b, a = meter_color(peak_l)
            Core.DrawRect(x, y, w_l, half_h, r, g, b, a)
        end

        local w_r = math.floor(math.max(0, math.min(1, peak_r)) * width)
        if w_r > 0 then
            local r, g, b, a = meter_color(peak_r)
            Core.DrawRect(x, y + half_h + 1, w_r, height - half_h - 1, r, g, b, a)
        end
    end

    Layout.AdvanceCursor(width, height)
end

-- ============================================================================
-- IMAGE SYSTEM
-- ============================================================================
-- Buffer management: gfx has buffers 0-1023
-- Reserve 200-899 for user images
local img_next_buffer = 200
local img_cache = {}  -- path → { buffer=N, w=W, h=H }

function Widgets.LoadImage(path)
    -- Check cache first
    if img_cache[path] then return img_cache[path] end

    -- Resolve relative paths from REAPER resource path
    local full_path = path
    if not path:match("^[A-Z]:") and not path:match("^/") then
        full_path = reaper.GetResourcePath() .. "/" .. path
    end

    -- Allocate buffer
    local buf = img_next_buffer
    if buf > 899 then
        if Log then Log.Warn("WIDGET", "Image buffer limit reached") end
        return nil
    end
    img_next_buffer = img_next_buffer + 1

    -- Load image
    local ok = gfx.loadimg(buf, full_path)
    if ok < 0 then
        if Log then Log.Warn("WIDGET", "Failed to load image: " .. full_path) end
        return nil
    end

    -- Get dimensions
    local w, h = gfx.getimgdim(buf)

    local img = { buffer = buf, w = w, h = h, path = full_path }
    img_cache[path] = img
    return img
end

function Widgets.UnloadImage(img)
    if img and img.buffer then
        gfx.setimgdim(img.buffer, 0, 0)
        if img_cache[img.path] then img_cache[img.path] = nil end
    end
end

-- Display an image
function Widgets.Image(img, theme, opts)
    if not img then return end
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local w = opts.width or img.w
    local h = opts.height or img.h

    if Core.IsVisible(x, y, w, h) then
        gfx.blit(img.buffer, 1, 0, 0, 0, img.w, img.h, x, y, w, h)
    end

    Layout.AdvanceCursor(w, h)
end

-- Clickable image button
function Widgets.ImageButton(id, img, theme, opts)
    if not img then return false end
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local pad = opts.padding or 2
    local img_size = opts.size or math.max(img.w, img.h)
    local w = img_size + pad * 2
    local h = img_size + pad * 2

    local clicked = false
    local hovered = Core.MouseInClippedRect(x, y, w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        if Core.MouseClicked(1) then Core.SetActive(id) end
    end

    if Core.IsActive(id) and Core.MouseReleased(1) then
        if hovered then clicked = true end
        Core.ClearActive()
    end

    if Core.IsVisible(x, y, w, h) then
        -- Background on hover/active
        if Core.IsActive(id) and hovered then
            local bg = theme.colors.button_active
            Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        elseif hovered then
            local bg = theme.colors.button_hovered
            Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        end

        -- Draw image centered in button
        local ix = x + pad + math.floor((img_size - math.min(img_size, img.w)) / 2)
        local iy = y + pad + math.floor((img_size - math.min(img_size, img.h)) / 2)
        local draw_w = math.min(img_size, img.w)
        local draw_h = math.min(img_size, img.h)

        -- Scale to fit if image is larger than size
        if img.w > img_size or img.h > img_size then
            local scale = math.min(img_size / img.w, img_size / img.h)
            draw_w = math.floor(img.w * scale)
            draw_h = math.floor(img.h * scale)
            ix = x + pad + math.floor((img_size - draw_w) / 2)
            iy = y + pad + math.floor((img_size - draw_h) / 2)
        end

        gfx.blit(img.buffer, 1, 0, 0, 0, img.w, img.h, ix, iy, draw_w, draw_h)
    end

    Layout.AdvanceCursor(w, h)
    return clicked
end

-- ============================================================================
-- COLOR PICKER
-- ============================================================================
-- HSV to RGB helper (module-level for reuse)
local function hsv_to_rgb(h_val, s, v)
    if s == 0 then return v, v, v end
    local i = math.floor(h_val * 6)
    local f = h_val * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    else return v, p, q end
end

-- color = {r, g, b} in 0-1 range
-- Returns: changed, new_color {r,g,b}
function Widgets.ColorPicker(id, label, color, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()

    local tw, th = 0, 0
    if label and label ~= "" then
        tw, th = Core.MeasureText(label)
    end

    local preview_size = theme.combo_height
    local total_w = (tw > 0 and (tw + 8) or 0) + preview_size
    local h = preview_size

    local px = x + (tw > 0 and (tw + 8) or 0)
    local py = y

    -- Persistent state
    local data = Core.GetWidgetData("color_" .. id, {
        hue = 0, sat = 1, val = 1,
        initialized = false,
        pending = nil,  -- pending color from popup
    })

    -- Check for pending color from popup (set on previous frames)
    local changed = false
    local new_color = { color[1], color[2], color[3] }
    if data.pending then
        new_color = data.pending
        changed = true
        -- Keep pending alive while popup is open (live update)
        if not Core.HasPopup(id) then
            data.pending = nil
        end
    end

    -- Initialize HSV from current color
    if not data.initialized then
        local cr, cg, cb = new_color[1], new_color[2], new_color[3]
        local max_c = math.max(cr, cg, cb)
        local min_c = math.min(cr, cg, cb)
        local delta = max_c - min_c
        data.val = max_c
        data.sat = max_c > 0 and (delta / max_c) or 0
        if delta == 0 then
            data.hue = 0
        elseif max_c == cr then
            data.hue = ((cg - cb) / delta) % 6
        elseif max_c == cg then
            data.hue = (cb - cr) / delta + 2
        else
            data.hue = (cr - cg) / delta + 4
        end
        data.hue = data.hue / 6
        if data.hue < 0 then data.hue = data.hue + 1 end
        data.initialized = true
    end

    -- Click preview to open picker (only when no popup)
    local hovered = Core.MouseInClippedRect(px, py, preview_size, preview_size) and not Core.HasPopup()
    if hovered then Core.SetHot(id) end

    if hovered and Core.MouseClicked(1) and not Core.HasPopup(id) then
        -- Open popup ONCE
        local picker_w = 180
        local picker_h = 160
        local picker_x = px
        local picker_y = py + preview_size + 2
        local win_w, win_h = Core.GetWindowSize()
        if picker_y + picker_h > win_h then picker_y = py - picker_h - 2 end

        local color_data_id = "color_" .. id

        Core.SetPopup(id, function()
            local is_new = Core.IsPopupNewThisFrame()
            local d = Core.GetWidgetData(color_data_id, {})

            -- Background
            local pbg = theme.colors.popup_bg
            Core.DrawRect(picker_x, picker_y, picker_w, picker_h, pbg[1], pbg[2], pbg[3], 1)
            local pbc = theme.colors.border
            Core.DrawRect(picker_x, picker_y, picker_w, picker_h, pbc[1], pbc[2], pbc[3], 0.6, false)

            local sq_x = picker_x + 6
            local sq_y = picker_y + 6
            local sq_size = picker_h - 32
            local hue_bar_x = sq_x + sq_size + 8
            local hue_bar_w = 16

            -- Draw SV gradient
            for row = 0, sq_size - 1 do
                local v = 1 - row / sq_size
                for col = 0, sq_size - 1, 3 do
                    local s = col / sq_size
                    local cr, cg, cb = hsv_to_rgb(d.hue or 0, s, v)
                    gfx.set(cr, cg, cb, 1)
                    gfx.rect(sq_x + col, sq_y + row, 3, 1, 1)
                end
            end

            -- Draw hue bar
            for row = 0, sq_size - 1 do
                local hv = row / sq_size
                local cr, cg, cb = hsv_to_rgb(hv, 1, 1)
                gfx.set(cr, cg, cb, 1)
                gfx.rect(hue_bar_x, sq_y + row, hue_bar_w, 1, 1)
            end

            -- SV cursor
            gfx.set(1, 1, 1, 0.9)
            gfx.rect(sq_x + math.floor((d.sat or 0) * sq_size) - 2,
                     sq_y + math.floor((1 - (d.val or 1)) * sq_size) - 2, 5, 5, 0)

            -- Hue cursor
            gfx.set(1, 1, 1, 0.9)
            gfx.rect(hue_bar_x - 1, sq_y + math.floor((d.hue or 0) * sq_size) - 1, hue_bar_w + 2, 3, 0)

            -- Drag SV square
            local in_sv = Core.MouseInRect(sq_x, sq_y, sq_size, sq_size)
            if Core.MouseDown(1) and in_sv then
                local mx, my = Core.GetMousePos()
                d.sat = math.max(0, math.min(1, (mx - sq_x) / sq_size))
                d.val = math.max(0, math.min(1, 1 - (my - sq_y) / sq_size))
                local nr, ng, nb = hsv_to_rgb(d.hue, d.sat, d.val)
                d.pending = { nr, ng, nb }
                d.initialized = false
                Core.SetWidgetData(color_data_id, d)
            end

            -- Drag hue bar
            local in_hue = Core.MouseInRect(hue_bar_x, sq_y, hue_bar_w, sq_size)
            if Core.MouseDown(1) and in_hue then
                local _, my = Core.GetMousePos()
                d.hue = math.max(0, math.min(1, (my - sq_y) / sq_size))
                local nr, ng, nb = hsv_to_rgb(d.hue, d.sat, d.val)
                d.pending = { nr, ng, nb }
                d.initialized = false
                Core.SetWidgetData(color_data_id, d)
            end

            -- Preview + hex
            local prev_y = sq_y + sq_size + 4
            local cr, cg, cb = hsv_to_rgb(d.hue or 0, d.sat or 1, d.val or 1)
            Core.DrawRect(sq_x, prev_y, 30, 16, cr, cg, cb, 1)
            local hex_str = string.format("#%02X%02X%02X",
                math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255))
            local tc = theme.colors.text
            Core.DrawText(hex_str, sq_x + 36, prev_y + 1, tc[1], tc[2], tc[3], tc[4])

            -- Close: click outside picker, right-click, or Escape
            local in_picker = Core.MouseInRect(picker_x, picker_y, picker_w, picker_h)
            if not is_new and Core.MouseClicked(1) and not in_picker then
                Core.ClearPopup(id)
            end
            if Core.MouseClicked(2) then
                Core.ClearPopup(id)
            end
        end)
    end

    -- Draw label + preview swatch
    if Core.IsVisible(x, y, total_w, h) then
        if tw > 0 then
            local tc = theme.colors.text
            local ly = y + math.floor((h - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        -- Show current color (including pending changes)
        local display = changed and new_color or color
        Core.DrawRect(px, py, preview_size, preview_size, display[1], display[2], display[3], 1)
        local bc = theme.colors.border
        Core.DrawRect(px, py, preview_size, preview_size, bc[1], bc[2], bc[3], 0.5, false)
    end

    Core.SetWidgetData("color_" .. id, data)

    Layout.AdvanceCursor(total_w, h)
    return changed, new_color
end

-- ============================================================================
-- NUMBER INPUT (value + drag to adjust)
-- ============================================================================
function Widgets.NumberInput(id, label, value, min_val, max_val, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()

    local tw, th = 0, 0
    if label and label ~= "" then
        tw, th = Core.MeasureText(label)
    end

    local input_w = opts.width or 80
    local h = theme.combo_height
    local total_w = input_w + (tw > 0 and (tw + 8) or 0)
    local step = opts.step or 1
    local format = opts.format or (step < 1 and "%.2f" or "%d")
    local speed = opts.speed or step

    local ix = x + (tw > 0 and (tw + 8) or 0)
    local iy = y

    local data = Core.GetWidgetData("numinput_" .. id, { editing = false, edit_buf = "", blink_time = 0 })
    local changed = false
    local new_value = value

    local hovered = Core.MouseInClippedRect(ix, iy, input_w, h) and not Core.HasPopup()
    local is_focused = Core.IsFocused(id)

    -- If we were editing but lost focus, submit and exit edit mode
    if data.editing and not is_focused then
        local num = tonumber(data.edit_buf)
        if num then
            new_value = num
            if min_val then new_value = math.max(min_val, new_value) end
            if max_val then new_value = math.min(max_val, new_value) end
            changed = true
        end
        data.editing = false
    end

    if hovered then Core.SetHot(id) end

    -- Double-click to enter edit mode
    if hovered and Core.MouseDoubleClicked() then
        Core.SetFocus(id)
        data.editing = true
        data.edit_buf = string.format(format, value):match("^%s*(.-)%s*$")  -- trim
        data.blink_time = reaper.time_precise()
        is_focused = true
    end

    -- Drag to adjust value
    if not data.editing then
        if hovered and Core.MouseClicked(1) then
            Core.SetActive(id)
        end

        if Core.IsActive(id) then
            if Core.MouseDown(1) then
                local dx = Core.MouseDelta()
                if dx ~= 0 then
                    new_value = value + dx * speed
                    if min_val then new_value = math.max(min_val, new_value) end
                    if max_val then new_value = math.min(max_val, new_value) end
                    if step >= 1 then new_value = math.floor(new_value + 0.5) end
                    if new_value ~= value then changed = true end
                end
            else
                Core.ClearActive()
            end
        end
    end

    -- Keyboard input in edit mode
    if data.editing and is_focused and Keys then
        local char = Core.GetChar()
        if char == Keys.ENTER or char == Keys.TAB then
            -- Submit
            local num = tonumber(data.edit_buf)
            if num then
                new_value = num
                if min_val then new_value = math.max(min_val, new_value) end
                if max_val then new_value = math.min(max_val, new_value) end
                changed = true
            end
            data.editing = false
            Core.SetFocus(nil)
        elseif char == Keys.ESCAPE then
            data.editing = false
            Core.SetFocus(nil)
        elseif char == Keys.BACKSPACE then
            if #data.edit_buf > 0 then
                data.edit_buf = data.edit_buf:sub(1, -2)
                data.blink_time = reaper.time_precise()
            end
        elseif char > 0 and char < 256 then
            local c = string.char(char)
            if c:match("[0-9%.%-]") then
                data.edit_buf = data.edit_buf .. c
                data.blink_time = reaper.time_precise()
            end
        end
    end

    Core.SetWidgetData("numinput_" .. id, data)

    -- Draw
    if Core.IsVisible(x, y, total_w, h) then
        if tw > 0 then
            local tc = theme.colors.text
            local ly = y + math.floor((h - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        local bg = data.editing and theme.colors.frame_active or
                   (hovered and theme.colors.frame_hovered or theme.colors.frame_bg)
        Core.DrawRect(ix, iy, input_w, h, bg[1], bg[2], bg[3], bg[4])
        local bc = data.editing and theme.colors.accent or theme.colors.border
        Core.DrawRect(ix, iy, input_w, h, bc[1], bc[2], bc[3], data.editing and 0.8 or 0.4, false)

        local display = data.editing and data.edit_buf or string.format(format, changed and new_value or value)
        local dtw, dth = Core.MeasureText(display)
        local tx = ix + math.floor((input_w - dtw) / 2)
        local ty = iy + math.floor((h - dth) / 2)
        local tc = theme.colors.text
        Core.DrawText(display, tx, ty, tc[1], tc[2], tc[3], tc[4])

        -- Blinking cursor when editing
        if data.editing and is_focused then
            local elapsed = reaper.time_precise() - data.blink_time
            if elapsed % 1.0 < 0.55 then
                local cursor_x = tx + dtw
                Core.DrawRect(cursor_x + 1, iy + 3, 1, h - 6, tc[1], tc[2], tc[3], 0.9)
            end
        end
    end

    Layout.AdvanceCursor(total_w, h)
    return changed, changed and new_value or value
end

-- ============================================================================
-- MULTI-LINE TEXT EDIT
-- ============================================================================
function Widgets.TextEdit(id, text, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local w = opts.width or avail_w
    local h = opts.height or 120
    local pad = theme.frame_padding_x

    local data = Core.GetWidgetData("textedit_" .. id, {
        cursor = #text,
        scroll_y = 0,
        blink_time = 0,
    })

    local changed = false
    local new_text = text
    local is_focused = Core.IsFocused(id)
    local hovered = Core.MouseInClippedRect(x, y, w, h) and not Core.HasPopup()

    if hovered then Core.SetHot(id) end

    if hovered and Core.MouseClicked(1) then
        Core.SetFocus(id)
        is_focused = true
        data.blink_time = reaper.time_precise()

        -- Calculate cursor position from click
        local mx, my = Core.GetMousePos()
        local click_x = mx - x - pad
        local click_y = my - y - 2 + data.scroll_y
        local _, line_h = Core.MeasureText("M")
        local row_h = line_h + 2

        -- Split text into lines
        local lines = {}
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end

        -- Find clicked line
        local clicked_line = math.max(1, math.min(#lines, math.floor(click_y / row_h) + 1))

        -- Find clicked character in that line
        local line_text = lines[clicked_line] or ""
        local char_in_line = 0
        for i = 1, #line_text do
            if Core.MeasureText(line_text:sub(1, i)) > click_x then break end
            char_in_line = i
        end

        -- Convert line + char to absolute cursor position
        local abs_pos = 0
        for i = 1, clicked_line - 1 do
            abs_pos = abs_pos + #(lines[i] or "") + 1  -- +1 for \n
        end
        data.cursor = abs_pos + char_in_line
    end

    -- Keyboard input
    if is_focused and Keys then
        local char = Core.GetChar()

        if char == Keys.BACKSPACE and data.cursor > 0 then
            new_text = text:sub(1, data.cursor - 1) .. text:sub(data.cursor + 1)
            data.cursor = data.cursor - 1
            changed = true
            data.blink_time = reaper.time_precise()

        elseif char == Keys.DELETE and data.cursor < #text then
            new_text = text:sub(1, data.cursor) .. text:sub(data.cursor + 2)
            changed = true
            data.blink_time = reaper.time_precise()

        elseif char == Keys.LEFT and data.cursor > 0 then
            data.cursor = data.cursor - 1
            data.blink_time = reaper.time_precise()

        elseif char == Keys.RIGHT and data.cursor < #text then
            data.cursor = data.cursor + 1
            data.blink_time = reaper.time_precise()

        elseif char == Keys.HOME then
            data.cursor = 0
            data.blink_time = reaper.time_precise()

        elseif char == Keys.END then
            data.cursor = #text
            data.blink_time = reaper.time_precise()

        elseif char == Keys.ENTER then
            -- Insert newline
            local before = text:sub(1, data.cursor)
            local after = text:sub(data.cursor + 1)
            new_text = before .. "\n" .. after
            data.cursor = data.cursor + 1
            changed = true
            data.blink_time = reaper.time_precise()

        elseif char == Keys.TAB then
            Core.SetFocus(nil)
            is_focused = false

        elseif char == 22 then  -- Ctrl+V
            if reaper.CF_GetClipboard then
                local clip = reaper.CF_GetClipboard("")
                if clip and clip ~= "" then
                    local before = text:sub(1, data.cursor)
                    local after = text:sub(data.cursor + 1)
                    new_text = before .. clip .. after
                    data.cursor = data.cursor + #clip
                    changed = true
                end
            end
            data.blink_time = reaper.time_precise()

        elseif char > 0 and char >= 32 and char < 256 then
            local before = text:sub(1, data.cursor)
            local after = text:sub(data.cursor + 1)
            new_text = before .. string.char(char) .. after
            data.cursor = data.cursor + 1
            changed = true
            data.blink_time = reaper.time_precise()
        end
    end

    -- Scroll
    local display_text = changed and new_text or text
    local lines = {}
    for line in (display_text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local _, line_h = Core.MeasureText("M")
    local content_h = #lines * (line_h + 2)

    if hovered and not Core.HasPopup() then
        local wheel = Core.GetState().mouse_wheel
        if wheel ~= 0 then
            data.scroll_y = data.scroll_y - wheel * (line_h + 2) * 2
            data.scroll_y = math.max(0, math.min(data.scroll_y, math.max(0, content_h - h + pad * 2)))
        end
    end

    Core.SetWidgetData("textedit_" .. id, data)

    -- Draw using offscreen buffer for clipping
    if Core.IsVisible(x, y, w, h) then
        local bg = is_focused and theme.colors.frame_active or theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        local bc = is_focused and theme.colors.accent or theme.colors.border
        Core.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], is_focused and 0.8 or 0.4, false)

        -- Render into buffer
        local buf_id = 901
        local vis_w = w - pad * 2
        local vis_h = h - 4
        gfx.dest = buf_id
        gfx.setimgdim(buf_id, vis_w, vis_h)
        gfx.set(bg[1], bg[2], bg[3], 1)
        gfx.rect(0, 0, vis_w, vis_h, 1)

        local tc = theme.colors.text
        gfx.set(tc[1], tc[2], tc[3], tc[4])

        local draw_y = 2 - data.scroll_y
        local char_pos = 0
        for _, line in ipairs(lines) do
            if draw_y + line_h > 0 and draw_y < vis_h then
                gfx.x, gfx.y = 0, draw_y
                gfx.drawstr(line)
            end

            -- Cursor in this line?
            if is_focused and data.cursor >= char_pos and data.cursor <= char_pos + #line then
                local elapsed = reaper.time_precise() - data.blink_time
                if elapsed % 1.0 < 0.55 then
                    local cx = Core.MeasureText(line:sub(1, data.cursor - char_pos))
                    gfx.set(tc[1], tc[2], tc[3], 0.9)
                    gfx.rect(cx, draw_y, 1, line_h, 1)
                    gfx.set(tc[1], tc[2], tc[3], tc[4])
                end
            end

            char_pos = char_pos + #line + 1  -- +1 for \n
            draw_y = draw_y + line_h + 2
        end

        -- Blit to screen
        gfx.dest = -1
        gfx.blit(buf_id, 1, 0, 0, 0, vis_w, vis_h, x + pad, y + 2)

        -- Scrollbar
        if content_h > h then
            local bar_x = x + w - 6
            local bar_h = h - 4
            local thumb_h = math.max(10, bar_h * (h / content_h))
            local scroll_range = content_h - h + pad * 2
            local ratio = scroll_range > 0 and (data.scroll_y / scroll_range) or 0
            local thumb_y = y + 2 + (bar_h - thumb_h) * ratio
            Core.DrawRect(bar_x, y + 2, 4, bar_h, 0.2, 0.2, 0.2, 0.3)
            Core.DrawRect(bar_x, thumb_y, 4, thumb_h, 0.4, 0.4, 0.4, 0.5)
        end
    end

    Layout.AdvanceCursor(w, h)
    return changed, changed and new_text or text
end

-- ============================================================================
-- RADIO BUTTON
-- ============================================================================
-- Returns: changed (bool), new_index (int)
-- items = { "Option A", "Option B", "Option C" }
-- horizontal = true to lay out side by side
function Widgets.RadioGroup(id, label, current_index, items, theme, opts)
    opts = opts or {}
    local horizontal = opts.horizontal or false
    local changed = false
    local new_index = current_index

    if label and label ~= "" then
        Widgets.Text(label, theme)
    end

    if horizontal then Layout.SameLine() end

    for i, item_label in ipairs(items) do
        local item_id = id .. "_" .. i
        local x, y = Layout.GetCursorPos()
        local size = theme.checkbox_size
        local item_tw, item_th = Core.MeasureText(item_label)
        local total_w = size + 6 + item_tw
        local h = math.max(size, item_th)
        local is_selected = (i == current_index)

        local item_hovered = Core.MouseInClippedRect(x, y, total_w, h) and not Core.HasPopup()

        if item_hovered then
            Core.SetHot(item_id)
            if Core.MouseClicked(1) and not is_selected then
                new_index = i
                changed = true
                if Log then Log.WidgetChanged(id, "Radio", tostring(current_index), tostring(i) .. "=" .. item_label) end
            end
        end

        -- Draw
        if Core.IsVisible(x, y, total_w, h) then
            local circle_y = y + math.floor((h - size) / 2)
            local bg = item_hovered and theme.colors.frame_hovered or theme.colors.frame_bg

            -- Outer ring
            local bc = theme.colors.border
            gfx.set(bg[1], bg[2], bg[3], bg[4])
            gfx.rect(x, circle_y, size, size, 1)
            gfx.set(bc[1], bc[2], bc[3], bc[4])
            gfx.rect(x, circle_y, size, size, 0)

            -- Filled dot if selected
            if is_selected or (changed and new_index == i) then
                local ac = theme.colors.accent
                local m = 4
                gfx.set(ac[1], ac[2], ac[3], ac[4])
                gfx.rect(x + m, circle_y + m, size - m * 2, size - m * 2, 1)
            end

            -- Label
            local tc = theme.colors.text
            local lx = x + size + 6
            local ly = y + math.floor((h - item_th) / 2)
            Core.DrawText(item_label, lx, ly, tc[1], tc[2], tc[3], tc[4])
        end

        Layout.AdvanceCursor(total_w, h)
        if horizontal and i < #items then Layout.SameLine() end
    end

    return changed, new_index
end

-- ============================================================================
-- PROGRESS BAR
-- ============================================================================
function Widgets.ProgressBar(id, fraction, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local w = opts.width or avail_w
    local h = opts.height or theme.combo_height  -- taller than slider for better text readability
    local label = opts.label  -- nil = show percentage, string = custom, "" = none

    fraction = math.max(0, math.min(1, fraction))

    if Core.IsVisible(x, y, w, h) then
        -- Background
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])

        -- Filled portion
        local fill_w = math.floor(w * fraction)
        if fill_w > 0 then
            local ac = theme.colors.accent
            Core.DrawRect(x, y, fill_w, h, ac[1], ac[2], ac[3], ac[4])
        end

        -- Text overlay
        local display_text
        if label == nil then
            display_text = string.format("%d%%", math.floor(fraction * 100))
        elseif label ~= "" then
            display_text = label
        end

        if display_text then
            local tw, th = Core.MeasureText(display_text)
            -- Only draw if text fits with padding
            if tw + 8 <= w then
                local tx = x + math.floor((w - tw) / 2)
                local ty = y + math.floor((h - th) / 2)
                local tc = theme.colors.text
                Core.DrawText(display_text, tx, ty, tc[1], tc[2], tc[3], tc[4])
            end
        end
    end

    Layout.AdvanceCursor(w, h)
end

-- ============================================================================
-- TABLE / GRID
-- ============================================================================
-- columns = { {header="Name", width=120}, {header="Value", width=80}, {header="Type"} }
--   width = fixed pixel width, or nil for auto-fill remaining space
-- rows = { {"Track 1", "0.5", "Audio"}, {"Track 2", "1.0", "MIDI"}, ... }
-- Returns: clicked_row (int or nil), clicked_col (int or nil)
function Widgets.Table(id, columns, rows, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local row_h = opts.row_height or theme.combo_height
    local header_h = row_h
    local max_visible = opts.max_rows or 10
    local show_header = opts.header ~= false
    local selected_row = opts.selected  -- highlight this row index

    -- Calculate column widths
    local total_fixed = 0
    local auto_count = 0
    for _, col in ipairs(columns) do
        if col.width then
            total_fixed = total_fixed + col.width
        else
            auto_count = auto_count + 1
        end
    end
    local auto_width = auto_count > 0 and math.floor((avail_w - total_fixed) / auto_count) or 0

    local col_widths = {}
    for i, col in ipairs(columns) do
        col_widths[i] = col.width or auto_width
    end

    -- Total height
    local visible_rows = math.min(#rows, max_visible)
    local total_h = (show_header and header_h or 0) + visible_rows * row_h

    -- Scroll state
    local data = Core.GetWidgetData("table_" .. id, { scroll_y = 0 })
    local scroll_offset = math.floor(data.scroll_y)

    local clicked_row, clicked_col = nil, nil

    if Core.IsVisible(x, y, avail_w, total_h) then
        local draw_y = y

        -- Header
        if show_header then
            local hbg = theme.colors.header
            Core.DrawRect(x, draw_y, avail_w, header_h, hbg[1], hbg[2], hbg[3], hbg[4])

            local col_x = x
            for i, col in ipairs(columns) do
                local tw, th = Core.MeasureText(col.header or "")
                local tx = col_x + 6
                local ty = draw_y + math.floor((header_h - th) / 2)
                local tc = theme.colors.text
                Core.DrawText(col.header or "", tx, ty, tc[1], tc[2], tc[3], tc[4])

                -- Column separator
                if i < #columns then
                    local sep_x = col_x + col_widths[i]
                    local sc = theme.colors.separator
                    Core.DrawLine(sep_x, draw_y, sep_x, draw_y + header_h, sc[1], sc[2], sc[3], 0.3)
                end

                col_x = col_x + col_widths[i]
            end

            draw_y = draw_y + header_h
        end

        -- Rows
        for row_idx = 1 + scroll_offset, math.min(#rows, visible_rows + scroll_offset) do
            local row = rows[row_idx]
            local row_y = draw_y + (row_idx - 1 - scroll_offset) * row_h
            local is_selected = (row_idx == selected_row)

            -- Row hover / selection
            local row_hovered = Core.MouseInClippedRect(x, row_y, avail_w, row_h) and not Core.HasPopup()

            if row_hovered then
                local hc = theme.colors.header_hovered
                Core.DrawRect(x, row_y, avail_w, row_h, hc[1], hc[2], hc[3], 0.4)
                if Core.MouseClicked(1) then
                    clicked_row = row_idx
                end
            end

            if is_selected then
                local ac = theme.colors.accent
                Core.DrawRect(x, row_y, avail_w, row_h, ac[1], ac[2], ac[3], 0.2)
            end

            -- Alternating row bg
            if not is_selected and not row_hovered and row_idx % 2 == 0 then
                Core.DrawRect(x, row_y, avail_w, row_h, 1, 1, 1, 0.02)
            end

            -- Cell values
            local col_x = x
            for col_idx, cell_value in ipairs(row) do
                if col_idx <= #columns then
                    local cw = col_widths[col_idx]
                    local tc = theme.colors.text
                    local _, cell_th = Core.MeasureText(tostring(cell_value))
                    local tx = col_x + 6
                    local ty = row_y + math.floor((row_h - cell_th) / 2)
                    Core.DrawText(tostring(cell_value), tx, ty, tc[1], tc[2], tc[3], tc[4])

                    -- Track clicked column
                    if row_hovered and Core.MouseClicked(1) then
                        if Core.MouseInRect(col_x, row_y, cw, row_h) then
                            clicked_col = col_idx
                        end
                    end

                    -- Column separator
                    if col_idx < #columns then
                        local sep_x = col_x + cw
                        local sc = theme.colors.separator
                        Core.DrawLine(sep_x, row_y, sep_x, row_y + row_h, sc[1], sc[2], sc[3], 0.15)
                    end

                    col_x = col_x + cw
                end
            end

            -- Row bottom separator
            local sc = theme.colors.separator
            Core.DrawLine(x, row_y + row_h - 1, x + avail_w, row_y + row_h - 1, sc[1], sc[2], sc[3], 0.1)
        end

        -- Scroll with wheel
        if #rows > max_visible then
            local wheel_area = Core.MouseInRect(x, y, avail_w, total_h)
            if wheel_area and not Core.HasPopup() then
                local state = Core.GetState()
                if state.mouse_wheel ~= 0 then
                    data.scroll_y = data.scroll_y - state.mouse_wheel * 2
                    data.scroll_y = math.max(0, math.min(data.scroll_y, #rows - visible_rows))
                end
            end
        else
            data.scroll_y = 0
        end

        Core.SetWidgetData("table_" .. id, data)

        -- Border
        local bc = theme.colors.border
        Core.DrawRect(x, y, avail_w, total_h, bc[1], bc[2], bc[3], 0.3, false)
    end

    Layout.AdvanceCursor(avail_w, total_h)
    return clicked_row, clicked_col
end

-- ============================================================================
-- MODAL DIALOG
-- ============================================================================
-- Usage:
--   if show_modal then
--     UI.BeginModal("confirm", "Delete Track?", { width = 300, height = 120 })
--     UI.Text("Are you sure?")
--     if UI.Button("ok", "OK") then show_modal = false; do_delete() end
--     UI.SameLine()
--     if UI.Button("cancel", "Cancel") then show_modal = false end
--     UI.EndModal()
--   end
function Widgets.BeginModal(id, title, theme, opts)
    opts = opts or {}
    local win_w, win_h = Core.GetWindowSize()
    local w = opts.width or 300
    local h = opts.height or 150
    local mx = math.floor((win_w - w) / 2)
    local my = math.floor((win_h - h) / 2)
    local pad = theme.window_padding

    -- Dim background overlay
    Core.DrawRect(0, 0, win_w, win_h, 0, 0, 0, 0.5)

    -- Modal window background
    local bg = theme.colors.popup_bg
    Core.DrawRect(mx, my, w, h, bg[1], bg[2], bg[3], 1)
    local bc = theme.colors.border
    Core.DrawRect(mx, my, w, h, bc[1], bc[2], bc[3], 0.6, false)

    -- Title bar
    if title then
        local hbg = theme.colors.header
        Core.DrawRect(mx, my, w, theme.tab_height, hbg[1], hbg[2], hbg[3], hbg[4])
        local tc = theme.colors.text
        local tw, th = Core.MeasureText(title)
        Core.DrawText(title, mx + pad, my + math.floor((theme.tab_height - th) / 2),
            tc[1], tc[2], tc[3], tc[4])
        my = my + theme.tab_height
        h = h - theme.tab_height
    end

    -- Push a container for modal content
    local c = {
        id = "modal_" .. id,
        x = mx, y = my, w = w, h = h,
        pad_x = pad, pad_y = pad,
        cursor_x = pad, cursor_y = pad,
        content_h = 0, scroll_y = 0,
        scrollable = false,
        same_line = false, same_line_x = 0,
        max_row_h = 0, spacing = theme.item_spacing,
        indent_x = 0, sameline_pending = false,
        last_widget_end_x = pad, last_widget_y = pad, last_widget_h = 0,
    }
    Core.PushContainer(c)
    Core.PushClipRect(mx, my, w, h)
end

function Widgets.EndModal()
    Core.PopClipRect()
    Core.PopContainer()
end

-- ============================================================================
-- DRAG & DROP
-- ============================================================================
local drag_state = {
    active = false,
    dropping = false,  -- true on the frame mouse is released (drop pending)
    payload = nil,
    type = nil,
    text = "",
}

function Widgets.BeginDragSource(id, payload, drag_type, display_text)
    -- Start drag when widget is active and mouse moves enough
    if Core.IsActive(id) and Core.MouseDown(1) then
        local dx, dy = Core.MouseDelta()
        if not drag_state.active and (math.abs(dx) > 3 or math.abs(dy) > 3) then
            drag_state.active = true
            drag_state.dropping = false
            drag_state.payload = payload
            drag_state.type = drag_type or "default"
            drag_state.text = display_text or tostring(payload)
            if Log then Log.Info("WIDGET", "Drag started: " .. id, "type=" .. drag_state.type) end
        end
    end

    -- On release: mark as dropping (don't clear yet — let DropTarget read it)
    if drag_state.active and not drag_state.dropping and Core.MouseReleased(1) then
        drag_state.dropping = true
    end

    return drag_state.active and drag_state.payload == payload
end

-- Drop target: returns payload if dropped here this frame
function Widgets.BeginDropTarget(x, y, w, h, accept_type, theme)
    if not drag_state.active then return nil end
    if accept_type and drag_state.type ~= accept_type then return nil end

    local is_over = Core.MouseInRect(x, y, w, h)

    -- Draw drop highlight
    if is_over then
        local ac = theme.colors.accent
        Core.DrawRect(x, y, w, h, ac[1], ac[2], ac[3], 0.15)
        Core.DrawRect(x, y, w, h, ac[1], ac[2], ac[3], 0.5, false)
    end

    -- Accept drop
    if is_over and drag_state.dropping then
        local payload = drag_state.payload
        if Log then Log.Info("WIDGET", "Drop accepted", "type=" .. (drag_state.type or "?")) end
        -- Clear drag state
        drag_state.active = false
        drag_state.dropping = false
        drag_state.payload = nil
        return payload
    end

    return nil
end

-- Draw drag preview — deferred to tooltip layer (on top of everything)
function Widgets.DrawDragPreview(theme)
    if not drag_state.active then return end

    -- Clean up if dropping but nothing accepted (missed drop)
    if drag_state.dropping then
        drag_state.active = false
        drag_state.dropping = false
        drag_state.payload = nil
        return
    end

    -- Defer to tooltip layer so it draws on top
    local text = drag_state.text
    Core.SetTooltip(function()
        local mx, my = Core.GetMousePos()
        local pad = 4
        local tw, th = Core.MeasureText(text)
        local bw = tw + pad * 2
        local bh = th + pad * 2

        Core.DrawRect(mx + 10, my + 10, bw, bh, 0, 0, 0, 0.3)
        local bg = theme.colors.popup_bg
        Core.DrawRect(mx + 8, my + 8, bw, bh, bg[1], bg[2], bg[3], 0.9)
        local bc = theme.colors.accent
        Core.DrawRect(mx + 8, my + 8, bw, bh, bc[1], bc[2], bc[3], 0.6, false)
        local tc = theme.colors.text
        Core.DrawText(text, mx + 8 + pad, my + 8 + pad, tc[1], tc[2], tc[3], 0.9)
    end)
end

function Widgets.IsDragging(drag_type)
    if drag_type then
        return drag_state.active and drag_state.type == drag_type
    end
    return drag_state.active
end

function Widgets.GetDragPayload()
    return drag_state.payload
end

-- ============================================================================
-- CONTEXT MENU (right-click popup)
-- ============================================================================
-- Call after a widget or area. Shows on right-click.
-- items = { {label="Cut", action=fn}, {label="Copy"}, {separator=true}, ... }
-- Returns: true if an item was clicked (action already called)
function Widgets.ContextMenu(id, items, theme)
    -- Open on right-click
    if Core.MouseClicked(2) then
        local mx, my = Core.GetMousePos()
        local item_h = theme.combo_height
        local menu_w = 0

        -- Calculate menu width (label + gap + shortcut + padding)
        for _, item in ipairs(items) do
            if not item.separator then
                local label_w = Core.MeasureText(item.label or "")
                local shortcut_w = item.shortcut and Core.MeasureText(item.shortcut) or 0
                local gap = shortcut_w > 0 and 32 or 0  -- gap between label and shortcut
                menu_w = math.max(menu_w, label_w + gap + shortcut_w + 20)
            end
        end

        -- Count visible items
        local visible_items = 0
        for _, item in ipairs(items) do
            visible_items = visible_items + (item.separator and 0.3 or 1)
        end
        local menu_h = math.floor(visible_items * item_h)

        -- Clamp to window
        local win_w, win_h = Core.GetWindowSize()
        if mx + menu_w > win_w then mx = win_w - menu_w - 4 end
        if my + menu_h > win_h then my = win_h - menu_h - 4 end

        local popup_x, popup_y = mx, my

        Core.SetPopup(id, function()
            local is_new = Core.IsPopupNewThisFrame()

            -- Background
            local pbg = theme.colors.popup_bg
            Core.DrawRect(popup_x, popup_y, menu_w, menu_h, pbg[1], pbg[2], pbg[3], pbg[4])
            local pbc = theme.colors.border
            Core.DrawRect(popup_x, popup_y, menu_w, menu_h, pbc[1], pbc[2], pbc[3], 0.6, false)

            -- Items
            local iy = popup_y
            for _, item in ipairs(items) do
                if item.separator then
                    -- Separator line
                    local sep_h = math.floor(item_h * 0.3)
                    local sc = theme.colors.separator
                    Core.DrawLine(popup_x + 4, iy + sep_h / 2, popup_x + menu_w - 4, iy + sep_h / 2,
                        sc[1], sc[2], sc[3], sc[4] or 0.5)
                    iy = iy + sep_h
                else
                    local item_hovered = Core.MouseInRect(popup_x, iy, menu_w, item_h)
                    local disabled = item.disabled

                    if item_hovered and not disabled then
                        local hc = theme.colors.header_hovered
                        Core.DrawRect(popup_x + 1, iy, menu_w - 2, item_h, hc[1], hc[2], hc[3], hc[4])
                    end

                    local tc = disabled and theme.colors.text_disabled or theme.colors.text
                    local _, text_h = Core.MeasureText(item.label)
                    local text_y = iy + math.floor((item_h - text_h) / 2)
                    Core.DrawText(item.label, popup_x + 8, text_y, tc[1], tc[2], tc[3], tc[4])

                    -- Shortcut hint (right-aligned)
                    if item.shortcut then
                        local sw = Core.MeasureText(item.shortcut)
                        Core.DrawText(item.shortcut, popup_x + menu_w - sw - 8, text_y,
                            tc[1], tc[2], tc[3], 0.5)
                    end

                    -- Click item
                    if not is_new and item_hovered and not disabled and Core.MouseClicked(1) then
                        Core.ClearPopup(id)
                        if item.action then item.action() end
                        return
                    end

                    iy = iy + item_h
                end
            end

            -- Close on click outside
            if not is_new and Core.MouseClicked(1)
               and not Core.MouseInRect(popup_x, popup_y, menu_w, menu_h) then
                Core.ClearPopup(id)
            end

            -- Close on right-click outside
            if not is_new and Core.MouseClicked(2)
               and not Core.MouseInRect(popup_x, popup_y, menu_w, menu_h) then
                Core.ClearPopup(id)
            end
        end)
    end
end

-- ============================================================================
-- TEXT INPUT
-- ============================================================================
-- Clipboard helpers (require SWS extension)
local function clipboard_set(str)
    if reaper.CF_SetClipboard then reaper.CF_SetClipboard(str) end
end

local function clipboard_get()
    if reaper.CF_GetClipboard then
        local buf = reaper.CF_GetClipboard("")
        return buf or ""
    end
    return ""
end

-- Buffer ID for text clipping (gfx offscreen buffer)
local INPUT_BUFFER_ID = 900

function Widgets.InputText(id, label, text, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()

    local tw, th = 0, 0
    if label and label ~= "" then
        tw, th = Core.MeasureText(label)
    end
    local input_w = opts.width or math.max(100, avail_w - tw - 12)
    local h = theme.combo_height
    local total_w = input_w + (tw > 0 and (tw + 8) or 0)
    local pad = theme.frame_padding_x

    local ix = x + (tw > 0 and (tw + 8) or 0)
    local iy = y

    local data = Core.GetWidgetData("input_" .. id, {
        cursor = #text,
        sel_start = nil,
        scroll_x = 0,
        blink_time = 0,
    })

    local changed = false
    local new_text = text
    local is_focused = Core.IsFocused(id)
    local current_text = text  -- track working copy

    -- Click to focus
    local hovered = Core.MouseInClippedRect(ix, iy, input_w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        if Core.MouseClicked(1) then
            Core.SetFocus(id)
            Core.SetActive(id)
            is_focused = true
            local click_x = Core.GetState().mouse_x - ix + data.scroll_x - pad
            local pos = 0
            for i = 1, #text do
                if Core.MeasureText(text:sub(1, i)) > click_x then break end
                pos = i
            end
            data.cursor = pos
            data.sel_start = nil
            data.blink_time = reaper.time_precise()
        end
    end

    -- Double-click to select all
    if hovered and Core.MouseDoubleClicked() and is_focused then
        data.sel_start = 0
        data.cursor = #text
    end

    -- Drag to select
    if Core.IsActive(id) and Core.MouseDown(1) and is_focused then
        local click_x = Core.GetState().mouse_x - ix + data.scroll_x - pad
        local pos = 0
        for i = 1, #text do
            if Core.MeasureText(text:sub(1, i)) > click_x then break end
            pos = i
        end
        if data.sel_start == nil then data.sel_start = data.cursor end
        data.cursor = pos
    end

    if Core.IsActive(id) and Core.MouseReleased(1) then
        Core.ClearActive()
        if data.sel_start == data.cursor then data.sel_start = nil end
    end

    -- Keyboard input
    if is_focused and Keys then
        local char = Core.GetChar()

        local function get_sel()
            if data.sel_start == nil then return nil, nil end
            return math.min(data.sel_start, data.cursor), math.max(data.sel_start, data.cursor)
        end

        local function get_sel_text()
            local s, e = get_sel()
            if s then return current_text:sub(s + 1, e) end
            return ""
        end

        local function del_sel()
            local s, e = get_sel()
            if s then
                new_text = current_text:sub(1, s) .. current_text:sub(e + 1)
                current_text = new_text
                data.cursor = s
                data.sel_start = nil
                changed = true
                return true
            end
            return false
        end

        local function insert_text(str)
            del_sel()
            local before = current_text:sub(1, data.cursor)
            local after = current_text:sub(data.cursor + 1)
            new_text = before .. str .. after
            current_text = new_text
            data.cursor = data.cursor + #str
            changed = true
        end

        if char == Keys.BACKSPACE then
            if not del_sel() and data.cursor > 0 then
                new_text = current_text:sub(1, data.cursor - 1) .. current_text:sub(data.cursor + 1)
                current_text = new_text
                data.cursor = data.cursor - 1
                changed = true
            end
            data.blink_time = reaper.time_precise()

        elseif char == Keys.DELETE then
            if not del_sel() and data.cursor < #current_text then
                new_text = current_text:sub(1, data.cursor) .. current_text:sub(data.cursor + 2)
                current_text = new_text
                changed = true
            end
            data.blink_time = reaper.time_precise()

        elseif char == Keys.LEFT then
            data.sel_start = nil
            if data.cursor > 0 then data.cursor = data.cursor - 1 end
            data.blink_time = reaper.time_precise()

        elseif char == Keys.RIGHT then
            data.sel_start = nil
            if data.cursor < #current_text then data.cursor = data.cursor + 1 end
            data.blink_time = reaper.time_precise()

        elseif char == Keys.HOME then
            data.sel_start = nil
            data.cursor = 0
            data.blink_time = reaper.time_precise()

        elseif char == Keys.END then
            data.sel_start = nil
            data.cursor = #current_text
            data.blink_time = reaper.time_precise()

        elseif char == Keys.ENTER or char == Keys.TAB then
            Core.SetFocus(nil)
            is_focused = false

        elseif char == 1 then  -- Ctrl+A
            data.sel_start = 0
            data.cursor = #current_text

        elseif char == 3 then  -- Ctrl+C
            local sel_text = get_sel_text()
            if sel_text ~= "" then clipboard_set(sel_text) end

        elseif char == 24 then  -- Ctrl+X
            local sel_text = get_sel_text()
            if sel_text ~= "" then
                clipboard_set(sel_text)
                del_sel()
            end
            data.blink_time = reaper.time_precise()

        elseif char == 22 then  -- Ctrl+V
            local clip = clipboard_get()
            if clip ~= "" then
                -- Remove newlines from pasted text
                clip = clip:gsub("[\r\n]", " ")
                insert_text(clip)
            end
            data.blink_time = reaper.time_precise()

        elseif char > 0 and char >= 32 and char < 256 then
            insert_text(string.char(char))
            data.blink_time = reaper.time_precise()
        end
    end

    -- Auto-scroll to keep cursor visible
    local display_text = changed and new_text or text
    if is_focused then
        local cursor_px = Core.MeasureText(display_text:sub(1, data.cursor))
        local visible_w = input_w - pad * 2
        if cursor_px - data.scroll_x > visible_w then
            data.scroll_x = cursor_px - visible_w + 10
        elseif cursor_px - data.scroll_x < 0 then
            data.scroll_x = math.max(0, cursor_px - 10)
        end
    else
        data.scroll_x = 0  -- reset scroll when not focused
    end

    Core.SetWidgetData("input_" .. id, data)

    -- Draw
    if Core.IsVisible(x, y, total_w, h) then
        -- Label
        if tw > 0 then
            local tc = theme.colors.text
            local ly = y + math.floor((h - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        -- Input background
        local bg = is_focused and theme.colors.frame_active or
                   (hovered and theme.colors.frame_hovered or theme.colors.frame_bg)
        Core.DrawRect(ix, iy, input_w, h, bg[1], bg[2], bg[3], bg[4])

        -- Border
        local bc = is_focused and theme.colors.accent or theme.colors.border
        Core.DrawRect(ix, iy, input_w, h, bc[1], bc[2], bc[3], is_focused and 0.8 or 0.4, false)

        -- Render text content into offscreen buffer for proper clipping
        local vis_w = input_w - pad * 2
        local vis_h = h
        local _, char_h = Core.MeasureText("M")
        local text_y_off = math.floor((vis_h - char_h) / 2)

        -- Setup offscreen buffer
        gfx.dest = INPUT_BUFFER_ID
        gfx.setimgdim(INPUT_BUFFER_ID, vis_w, vis_h)
        gfx.set(0, 0, 0, 1)
        gfx.rect(0, 0, vis_w, vis_h, 1)

        -- Redraw background in buffer
        gfx.set(bg[1], bg[2], bg[3], bg[4])
        gfx.rect(0, 0, vis_w, vis_h, 1)

        -- Draw selection highlight in buffer
        if is_focused and data.sel_start ~= nil then
            local s = math.min(data.sel_start, data.cursor)
            local e = math.max(data.sel_start, data.cursor)
            local sel_x1 = Core.MeasureText(display_text:sub(1, s)) - data.scroll_x
            local sel_x2 = Core.MeasureText(display_text:sub(1, e)) - data.scroll_x
            local ac = theme.colors.accent
            gfx.set(ac[1], ac[2], ac[3], 0.35)
            gfx.rect(sel_x1, 2, sel_x2 - sel_x1, vis_h - 4, 1)
        end

        -- Draw text in buffer
        local show_text = (#display_text > 0) and display_text or (opts.hint or "")
        local tc = (#display_text > 0) and theme.colors.text or theme.colors.text_disabled
        gfx.set(tc[1], tc[2], tc[3], tc[4])
        gfx.x = -data.scroll_x
        gfx.y = text_y_off
        gfx.drawstr(show_text)

        -- Draw cursor in buffer
        if is_focused then
            local elapsed = reaper.time_precise() - data.blink_time
            if elapsed % 1.0 < 0.55 then
                local cursor_px = Core.MeasureText(display_text:sub(1, data.cursor)) - data.scroll_x
                gfx.set(tc[1], tc[2], tc[3], 0.9)
                gfx.rect(cursor_px, 3, 1, vis_h - 6, 1)
            end
        end

        -- Blit buffer to screen (this clips perfectly)
        gfx.dest = -1
        gfx.blit(INPUT_BUFFER_ID, 1, 0, 0, 0, vis_w, vis_h, ix + pad, iy)
    end

    Layout.AdvanceCursor(total_w, h)
    return changed, changed and new_text or text
end

-- ============================================================================
-- CANVAS / DRAW AREA (free drawing zone)
-- ============================================================================
-- Returns: x, y, w, h of the canvas area + interaction state
-- The caller draws whatever they want inside using Core.DrawRect/Line/Text
function Widgets.Canvas(id, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local w = opts.width or avail_w
    local h = opts.height or 200

    local hovered = Core.MouseInClippedRect(x, y, w, h) and not Core.HasPopup()
    local mouse_x, mouse_y = Core.GetMousePos()

    -- Normalize mouse position to 0-1 within canvas
    local norm_x = hovered and math.max(0, math.min(1, (mouse_x - x) / w)) or nil
    local norm_y = hovered and math.max(0, math.min(1, (mouse_y - y) / h)) or nil

    local clicked = hovered and Core.MouseClicked(1)
    local dragging = false
    local right_clicked = hovered and Core.MouseClicked(2)

    if hovered then Core.SetHot(id) end

    if clicked then Core.SetActive(id) end

    if Core.IsActive(id) then
        if Core.MouseDown(1) then
            dragging = true
        else
            Core.ClearActive()
        end
    end

    -- Draw background
    if Core.IsVisible(x, y, w, h) then
        local bg = opts.bg or theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])

        -- Border
        local bc = opts.border_color or theme.colors.border
        Core.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], bc[4] or 0.4, false)

        -- Crosshairs if option set
        if opts.crosshair then
            local sc = theme.colors.separator
            Core.DrawLine(x + w/2, y, x + w/2, y + h, sc[1], sc[2], sc[3], 0.2)
            Core.DrawLine(x, y + h/2, x + w, y + h/2, sc[1], sc[2], sc[3], 0.2)
        end

        -- Grid if option set
        if opts.grid and opts.grid > 1 then
            local sc = theme.colors.separator
            local step_x = w / opts.grid
            local step_y = h / opts.grid
            for i = 1, opts.grid - 1 do
                Core.DrawLine(x + i * step_x, y, x + i * step_x, y + h, sc[1], sc[2], sc[3], 0.1)
                Core.DrawLine(x, y + i * step_y, x + w, y + i * step_y, sc[1], sc[2], sc[3], 0.1)
            end
        end
    end

    Layout.AdvanceCursor(w, h)

    return {
        x = x, y = y, w = w, h = h,
        hovered = hovered,
        clicked = clicked,
        right_clicked = right_clicked,
        dragging = dragging,
        norm_x = norm_x,
        norm_y = norm_y,
        mouse_x = mouse_x,
        mouse_y = mouse_y,
    }
end

-- ============================================================================
-- TOGGLE BUTTON (ON/OFF visual, distinct from checkbox)
-- ============================================================================
function Widgets.ToggleButton(id, label, is_on, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()

    local tw, th = Core.MeasureText(label)
    local fp_x = theme.frame_padding_x
    local fp_y = theme.frame_padding_y
    local w = opts.width or (tw + fp_x * 2)
    local h = opts.height or (th + fp_y * 2)

    local toggled = false
    local hovered = Core.MouseInClippedRect(x, y, w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        if Core.MouseClicked(1) then
            toggled = true
        end
    end

    local new_on = (toggled and (not is_on)) or ((not toggled) and is_on)

    -- Draw
    if Core.IsVisible(x, y, w, h) then
        local bg
        if new_on then
            bg = hovered and theme.colors.accent_hovered or theme.colors.accent
        else
            bg = hovered and theme.colors.button_hovered or theme.colors.button
        end
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])

        -- Text
        local tc = new_on and { 1, 1, 1, 1 } or theme.colors.text
        local tx = x + math.floor((w - tw) / 2)
        local ty = y + math.floor((h - th) / 2)
        Core.DrawText(label, tx, ty, tc[1], tc[2], tc[3], tc[4])
    end

    Layout.AdvanceCursor(w, h)
    return toggled, new_on
end

-- ============================================================================
-- RANGE SLIDER (dual thumb for min/max)
-- ============================================================================
function Widgets.RangeSlider(id, label, val_min, val_max, range_min, range_max, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()

    local tw, th = 0, 0
    if label and label ~= "" then
        tw, th = Core.MeasureText(label)
    end

    local slider_w = opts.width or math.max(100, avail_w - tw - 12)
    local h = theme.slider_height
    local total_w = slider_w + (tw > 0 and (tw + 8) or 0)

    local sx = x + (tw > 0 and (tw + 8) or 0)
    local sy = y + math.floor((math.max(h, th) - h) / 2)

    local changed = false
    local new_min = val_min
    local new_max = val_max

    -- Two grab handles
    local range = range_max - range_min
    local ratio_min = (val_min - range_min) / range
    local ratio_max = (val_max - range_min) / range
    local grab_w = 8

    local min_px = sx + math.floor(ratio_min * slider_w)
    local max_px = sx + math.floor(ratio_max * slider_w)

    local hovered = Core.MouseInClippedRect(sx, sy, slider_w, h) and not Core.HasPopup()
    if hovered then Core.SetHot(id) end

    -- Determine which handle to drag
    local drag_id_min = id .. "_min"
    local drag_id_max = id .. "_max"

    if hovered and Core.MouseClicked(1) then
        local mx = Core.GetState().mouse_x
        local dist_min = math.abs(mx - min_px)
        local dist_max = math.abs(mx - max_px)
        if dist_min <= dist_max then
            Core.SetActive(drag_id_min)
        else
            Core.SetActive(drag_id_max)
        end
    end

    -- Drag min handle
    if Core.IsActive(drag_id_min) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local ratio = math.max(0, math.min(ratio_max, (mx - sx) / slider_w))
            new_min = range_min + ratio * range
            if new_min ~= val_min then changed = true end
        else
            Core.ClearActive()
        end
    end

    -- Drag max handle
    if Core.IsActive(drag_id_max) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local ratio = math.max(ratio_min, math.min(1, (mx - sx) / slider_w))
            new_max = range_min + ratio * range
            if new_max ~= val_max then changed = true end
        else
            Core.ClearActive()
        end
    end

    -- Recalc positions after potential change
    if changed then
        ratio_min = (new_min - range_min) / range
        ratio_max = (new_max - range_min) / range
        min_px = sx + math.floor(ratio_min * slider_w)
        max_px = sx + math.floor(ratio_max * slider_w)
    end

    -- Draw
    if Core.IsVisible(x, y, total_w, math.max(h, th)) then
        -- Label
        if tw > 0 then
            local tc = theme.colors.text
            local ly = y + math.floor((math.max(h, th) - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        -- Track
        local track_bg = hovered and theme.colors.frame_hovered or theme.colors.frame_bg
        Core.DrawRect(sx, sy, slider_w, h, track_bg[1], track_bg[2], track_bg[3], track_bg[4])

        -- Filled range between handles
        local ac = theme.colors.accent
        local fill_x = min_px
        local fill_w = max_px - min_px
        if fill_w > 0 then
            Core.DrawRect(fill_x, sy, fill_w, h, ac[1], ac[2], ac[3], 0.5)
        end

        -- Min handle
        local min_grab_x = math.max(sx, min_px - grab_w / 2)
        local mc = Core.IsActive(drag_id_min) and theme.colors.accent_active or
                   (hovered and theme.colors.accent_hovered or theme.colors.accent)
        Core.DrawRect(min_grab_x, sy, grab_w, h, mc[1], mc[2], mc[3], mc[4])

        -- Max handle
        local max_grab_x = math.min(sx + slider_w - grab_w, max_px - grab_w / 2)
        local xc = Core.IsActive(drag_id_max) and theme.colors.accent_active or
                   (hovered and theme.colors.accent_hovered or theme.colors.accent)
        Core.DrawRect(max_grab_x, sy, grab_w, h, xc[1], xc[2], xc[3], xc[4])

        -- Value display
        local format = opts.format or "%.1f"
        local val_str = string.format(format .. " - " .. format, changed and new_min or val_min, changed and new_max or val_max)
        local vw, vh = Core.MeasureText(val_str)
        local vx = sx + math.floor((slider_w - vw) / 2)
        local vy = sy + math.floor((h - vh) / 2)
        local tc = theme.colors.text
        Core.DrawText(val_str, vx, vy, tc[1], tc[2], tc[3], tc[4])
    end

    Layout.AdvanceCursor(total_w, math.max(h, th))
    return changed, changed and new_min or val_min, changed and new_max or val_max
end

-- ============================================================================
-- ACTION LIST (scrollable list with per-row action buttons)
-- ============================================================================
-- items = { {label="Preset 1", data=...}, {label="Preset 2"}, ... }
-- actions = { {icon="X", tooltip="Delete"}, {icon="E", tooltip="Edit"} }
-- Returns: clicked_item_index, clicked_action_index (both nil if no click)
function Widgets.ActionList(id, items, actions, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local w = opts.width or avail_w
    local item_h = opts.item_height or theme.combo_height
    local max_visible = opts.max_visible or 8
    local visible_count = math.min(#items, max_visible)
    local h = visible_count * item_h
    local selected = opts.selected

    local data = Core.GetWidgetData("alist_" .. id, { scroll = 0 })

    local clicked_item, clicked_action = nil, nil

    -- Calculate action buttons total width
    local action_total_w = 0
    if actions then
        for _, act in ipairs(actions) do
            local aw = Core.MeasureText(act.icon or "?") + theme.frame_padding_x * 2
            action_total_w = action_total_w + aw + 2
        end
    end

    if Core.IsVisible(x, y, w, h) then
        -- Background
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])

        -- Border
        local bc = theme.colors.border
        Core.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], 0.3, false)

        -- Items
        local scroll_offset = math.floor(data.scroll)
        for i = 1 + scroll_offset, math.min(#items, visible_count + scroll_offset) do
            local item = items[i]
            local iy = y + (i - 1 - scroll_offset) * item_h
            local is_selected = (i == selected)

            local row_hovered = Core.MouseInRect(x, iy, w, item_h) and not Core.HasPopup()

            -- Hover highlight
            if row_hovered then
                local hc = theme.colors.header_hovered
                Core.DrawRect(x + 1, iy, w - 2, item_h, hc[1], hc[2], hc[3], 0.4)
            end

            -- Selection highlight
            if is_selected then
                local ac = theme.colors.accent
                Core.DrawRect(x + 1, iy, w - 2, item_h, ac[1], ac[2], ac[3], 0.2)
            end

            -- Label
            local tc = theme.colors.text
            local _, lh = Core.MeasureText(item.label)
            local ly = iy + math.floor((item_h - lh) / 2)
            Core.DrawText(item.label, x + 6, ly, tc[1], tc[2], tc[3], tc[4])

            -- Click on label area
            if row_hovered and Core.MouseClicked(1) then
                -- Check if click is on action buttons or label
                local mx = Core.GetState().mouse_x
                if mx < x + w - action_total_w - 4 then
                    clicked_item = i
                end
            end

            -- Action buttons (right-aligned)
            if actions and (row_hovered or is_selected) then
                local btn_x = x + w - action_total_w - 4
                for ai, act in ipairs(actions) do
                    local aw = Core.MeasureText(act.icon or "?") + theme.frame_padding_x * 2
                    local btn_hovered = Core.MouseInRect(btn_x, iy + 2, aw, item_h - 4)

                    -- Button background
                    if btn_hovered then
                        local hbc = theme.colors.button_hovered
                        Core.DrawRect(btn_x, iy + 2, aw, item_h - 4, hbc[1], hbc[2], hbc[3], hbc[4])
                    end

                    -- Button label
                    local atc = btn_hovered and theme.colors.text or theme.colors.text_disabled
                    local atw, ath = Core.MeasureText(act.icon or "?")
                    Core.DrawText(act.icon or "?",
                        btn_x + math.floor((aw - atw) / 2),
                        iy + math.floor((item_h - ath) / 2),
                        atc[1], atc[2], atc[3], atc[4])

                    -- Click action button
                    if btn_hovered and Core.MouseClicked(1) then
                        clicked_item = i
                        clicked_action = ai
                    end

                    btn_x = btn_x + aw + 2
                end
            end

            -- Row separator
            local sc = theme.colors.separator
            Core.DrawLine(x, iy + item_h - 1, x + w, iy + item_h - 1, sc[1], sc[2], sc[3], 0.1)
        end

        -- Scroll
        if #items > max_visible then
            local in_list = Core.MouseInRect(x, y, w, h)
            if in_list and not Core.HasPopup() then
                local wheel = Core.GetState().mouse_wheel
                if wheel ~= 0 then
                    data.scroll = data.scroll - wheel * 2
                    data.scroll = math.max(0, math.min(data.scroll, #items - visible_count))
                end
            end
        else
            data.scroll = 0
        end
    end

    Core.SetWidgetData("alist_" .. id, data)
    Layout.AdvanceCursor(w, h)
    return clicked_item, clicked_action
end

-- ============================================================================
-- COLLAPSIBLE PANEL (horizontal, with vertical text when collapsed)
-- ============================================================================
-- Returns: is_open (bool)
function Widgets.CollapsiblePanel(id, label, is_open, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()

    local expanded_w = opts.width or 160
    local collapsed_w = opts.collapsed_width or 20
    local panel_h = opts.height or Layout.GetAvailableHeight()
    local w = is_open and expanded_w or collapsed_w

    local toggled = false

    -- Click to toggle
    if not is_open then
        -- Collapsed: click on the thin bar
        local hovered = Core.MouseInClippedRect(x, y, collapsed_w, panel_h) and not Core.HasPopup()
        if hovered then Core.SetHot(id) end
        if hovered and Core.MouseClicked(1) then toggled = true end
    end

    local new_open = (toggled and (not is_open)) or ((not toggled) and is_open)

    if Core.IsVisible(x, y, w, panel_h) then
        if not new_open then
            -- Collapsed: draw vertical text
            local bg = theme.colors.header
            local hovered = Core.MouseInRect(x, y, collapsed_w, panel_h)
            if hovered then bg = theme.colors.header_hovered end
            Core.DrawRect(x, y, collapsed_w, panel_h, bg[1], bg[2], bg[3], bg[4])

            -- Vertical text (character by character)
            local tc = theme.colors.text
            local _, char_h = Core.MeasureText("M")
            local text_start_y = y + 8
            for ci = 1, #label do
                local ch = label:sub(ci, ci)
                local cw = Core.MeasureText(ch)
                local cx = x + math.floor((collapsed_w - cw) / 2)
                if text_start_y + char_h < y + panel_h then
                    Core.DrawText(ch, cx, text_start_y, tc[1], tc[2], tc[3], tc[4])
                    text_start_y = text_start_y + char_h + 1
                end
            end
        else
            -- Expanded: draw header with close button
            local header_h = theme.tab_height
            local hbg = theme.colors.header
            Core.DrawRect(x, y, expanded_w, header_h, hbg[1], hbg[2], hbg[3], hbg[4])

            -- Label
            local tc = theme.colors.text
            local ltw, lth = Core.MeasureText(label)
            Core.DrawText(label, x + 6, y + math.floor((header_h - lth) / 2), tc[1], tc[2], tc[3], tc[4])

            -- Collapse button (< arrow)
            local btn_x = x + expanded_w - header_h
            local btn_hovered = Core.MouseInRect(btn_x, y, header_h, header_h)
            if btn_hovered then
                local bhc = theme.colors.header_hovered
                Core.DrawRect(btn_x, y, header_h, header_h, bhc[1], bhc[2], bhc[3], bhc[4])
            end
            if Icons then
                Icons.ChevronLeft(btn_x, y, header_h, tc[1], tc[2], tc[3], 0.7)
            end
            if btn_hovered and Core.MouseClicked(1) then
                toggled = true
                new_open = false
            end

            -- Panel body background
            local pbg = theme.colors.popup_bg
            Core.DrawRect(x, y + header_h, expanded_w, panel_h - header_h, pbg[1], pbg[2], pbg[3], 0.5)
        end
    end

    -- If expanded, push a child container for panel content
    if new_open then
        local header_h = theme.tab_height
        local content_x = x
        local content_y = y + header_h
        local content_w = expanded_w
        local content_h = panel_h - header_h

        local c = {
            id = "cpanel_" .. id,
            x = content_x, y = content_y, w = content_w, h = content_h,
            pad_x = 4, pad_y = 4,
            cursor_x = 4, cursor_y = 4,
            content_h = 0, scroll_y = 0,
            scrollable = false,
            same_line = false, same_line_x = 0,
            max_row_h = 0, spacing = theme.item_spacing,
            indent_x = 0, sameline_pending = false,
            last_widget_end_x = 4, last_widget_y = 4, last_widget_h = 0,
        }
        Core.PushContainer(c)
        Core.PushClipRect(content_x, content_y, content_w, content_h)
    end

    -- Don't advance cursor here - the caller manages the panel width
    -- The EndCollapsiblePanel will handle cleanup
    return new_open, w
end

function Widgets.EndCollapsiblePanel()
    -- Pop the content container if it was pushed
    Core.PopClipRect()
    Core.PopContainer()
end

-- ============================================================================
-- REORDERABLE LIST (drag to sort)
-- ============================================================================
-- items = list of strings or {label=..., data=...}
-- Returns: changed (bool), new_order (table of indices), dragging_index
function Widgets.ReorderableList(id, items, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local w = opts.width or avail_w
    local item_h = opts.item_height or theme.combo_height
    local h = #items * item_h

    local data = Core.GetWidgetData("reorder_" .. id, {
        drag_index = nil,
        drag_y = 0,
        order = nil,
    })

    -- Initialize order if needed
    if not data.order or #data.order ~= #items then
        data.order = {}
        for i = 1, #items do data.order[i] = i end
    end

    local changed = false
    local selected = opts.selected

    if Core.IsVisible(x, y, w, h) then
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])

        for display_i, real_i in ipairs(data.order) do
            local item = items[real_i]
            local label = type(item) == "table" and item.label or tostring(item)
            local iy = y + (display_i - 1) * item_h
            local is_dragging = (data.drag_index == display_i)

            -- Skip drawing the dragged item in its original position
            if not is_dragging then
                local row_hovered = Core.MouseInRect(x, iy, w, item_h) and not Core.HasPopup()

                if row_hovered then
                    local hc = theme.colors.header_hovered
                    Core.DrawRect(x + 1, iy, w - 2, item_h, hc[1], hc[2], hc[3], 0.3)
                end

                if display_i == selected then
                    local ac = theme.colors.accent
                    Core.DrawRect(x + 1, iy, w - 2, item_h, ac[1], ac[2], ac[3], 0.2)
                end

                -- Drag handle (left side)
                local handle_w = 16
                local tc_dim = theme.colors.text_disabled
                Core.DrawText("=", x + 4, iy + math.floor((item_h - 14) / 2),
                    tc_dim[1], tc_dim[2], tc_dim[3], tc_dim[4])

                -- Label
                local tc = theme.colors.text
                local _, lh = Core.MeasureText(label)
                Core.DrawText(label, x + handle_w + 4, iy + math.floor((item_h - lh) / 2),
                    tc[1], tc[2], tc[3], tc[4])

                -- Start drag
                if row_hovered and Core.MouseClicked(1) and Core.MouseInRect(x, iy, 20, item_h) then
                    data.drag_index = display_i
                    data.drag_y = Core.GetState().mouse_y
                end

                -- Row separator
                local sc = theme.colors.separator
                Core.DrawLine(x, iy + item_h - 1, x + w, iy + item_h - 1, sc[1], sc[2], sc[3], 0.1)
            end
        end

        -- Draw dragged item on top
        if data.drag_index then
            if Core.MouseDown(1) then
                local my = Core.GetState().mouse_y
                local drag_display_y = my - item_h / 2
                local real_i = data.order[data.drag_index]
                local item = items[real_i]
                local label = type(item) == "table" and item.label or tostring(item)

                -- Draw dragged item
                local ac = theme.colors.accent
                Core.DrawRect(x, drag_display_y, w, item_h, ac[1], ac[2], ac[3], 0.3)
                local tc = theme.colors.text
                local _, lh = Core.MeasureText(label)
                Core.DrawText(label, x + 20, drag_display_y + math.floor((item_h - lh) / 2),
                    tc[1], tc[2], tc[3], tc[4])

                -- Calculate drop position
                local target_i = math.max(1, math.min(#items,
                    math.floor((my - y) / item_h) + 1))

                -- Draw insertion indicator
                local ind_y = y + (target_i - 1) * item_h
                if target_i > data.drag_index then ind_y = ind_y + item_h end
                Core.DrawRect(x + 2, ind_y - 1, w - 4, 2, ac[1], ac[2], ac[3], ac[4])
            else
                -- Drop: reorder
                local my = Core.GetState().mouse_y
                local target_i = math.max(1, math.min(#items,
                    math.floor((my - y) / item_h) + 1))

                if target_i ~= data.drag_index then
                    local moving = table.remove(data.order, data.drag_index)
                    local insert_at = target_i
                    if target_i > data.drag_index then insert_at = insert_at end
                    insert_at = math.max(1, math.min(#data.order + 1, insert_at))
                    table.insert(data.order, insert_at, moving)
                    changed = true
                end

                data.drag_index = nil
            end
        end

        -- Border
        local bc = theme.colors.border
        Core.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], 0.3, false)
    end

    Core.SetWidgetData("reorder_" .. id, data)
    Layout.AdvanceCursor(w, h)
    return changed, data.order, data.drag_index
end

-- ============================================================================
-- INTERACTIVE TABLE v2 (custom cell render via callback)
-- ============================================================================
-- columns = { {key="name", header="Name", width=120 or nil (auto), weight=2.5}, ... }
-- row_count = number of rows
-- cell_render = function(row, col_key, x, y, w, h, theme) — draw cell content
-- header_render = function(col_key, x, y, w, h, theme) — optional custom header (nil = default text)
-- Returns: clicked_row, clicked_col_key, hovered_row
function Widgets.InteractiveTable(id, columns, row_count, cell_render, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()
    local row_h = opts.row_height or theme.combo_height
    local header_h = opts.header ~= false and row_h or 0
    local max_visible = opts.max_rows or row_count
    local visible_rows = math.min(row_count, max_visible)
    local total_h = header_h + visible_rows * row_h
    local gap = opts.col_gap or 0
    local selected_row = opts.selected
    local header_render = opts.header_render

    -- Calculate column widths (weight-based)
    local total_weight = 0
    local total_fixed = 0
    for _, col in ipairs(columns) do
        if col.width then
            total_fixed = total_fixed + col.width
        else
            total_weight = total_weight + (col.weight or 1)
        end
    end

    local gaps_total = math.max(0, #columns - 1) * gap
    local distributable = avail_w - total_fixed - gaps_total
    local col_widths = {}
    local col_positions = {}
    local cx = x
    for i, col in ipairs(columns) do
        col_positions[i] = cx
        if col.width then
            col_widths[i] = col.width
        else
            col_widths[i] = math.floor(distributable * (col.weight or 1) / total_weight)
        end
        cx = cx + col_widths[i] + gap
    end

    -- Scroll
    local data = Core.GetWidgetData("itable_" .. id, { scroll = 0 })
    local scroll_offset = math.floor(data.scroll)

    local clicked_row, clicked_col_key, hovered_row = nil, nil, nil

    if Core.IsVisible(x, y, avail_w, total_h) then
        -- Header
        if header_h > 0 then
            local hbg = theme.colors.header
            Core.DrawRect(x, y, avail_w, header_h, hbg[1], hbg[2], hbg[3], hbg[4])

            for i, col in ipairs(columns) do
                if header_render then
                    header_render(col.key or col.header, col_positions[i], y, col_widths[i], header_h, theme)
                else
                    local tc = theme.colors.text
                    local hw, hh = Core.MeasureText(col.header or "")
                    Core.DrawText(col.header or "",
                        col_positions[i] + 4,
                        y + math.floor((header_h - hh) / 2),
                        tc[1], tc[2], tc[3], tc[4])
                end

                -- Column separator
                if i < #columns then
                    local sep_x = col_positions[i] + col_widths[i]
                    local sc = theme.colors.separator
                    Core.DrawLine(sep_x, y, sep_x, y + header_h, sc[1], sc[2], sc[3], 0.3)
                end
            end
        end

        -- Rows
        local draw_y = y + header_h
        for row_idx = 1 + scroll_offset, math.min(row_count, visible_rows + scroll_offset) do
            local ry = draw_y + (row_idx - 1 - scroll_offset) * row_h
            local is_selected = (row_idx == selected_row)
            local row_hovered = Core.MouseInClippedRect(x, ry, avail_w, row_h) and not Core.HasPopup()

            if row_hovered then
                hovered_row = row_idx
                local hc = theme.colors.header_hovered
                Core.DrawRect(x, ry, avail_w, row_h, hc[1], hc[2], hc[3], 0.3)
            end

            if is_selected then
                local ac = theme.colors.accent
                Core.DrawRect(x, ry, avail_w, row_h, ac[1], ac[2], ac[3], 0.15)
            end

            -- Alternating row
            if not is_selected and not row_hovered and row_idx % 2 == 0 then
                Core.DrawRect(x, ry, avail_w, row_h, 1, 1, 1, 0.015)
            end

            -- Cells
            for i, col in ipairs(columns) do
                local col_key = col.key or col.header
                -- Custom cell render callback
                cell_render(row_idx, col_key, col_positions[i], ry, col_widths[i], row_h, theme)

                -- Click detection per cell
                if row_hovered and Core.MouseClicked(1) then
                    if Core.MouseInRect(col_positions[i], ry, col_widths[i], row_h) then
                        clicked_row = row_idx
                        clicked_col_key = col_key
                    end
                end

                -- Column separator
                if i < #columns then
                    local sep_x = col_positions[i] + col_widths[i]
                    local sc = theme.colors.separator
                    Core.DrawLine(sep_x, ry, sep_x, ry + row_h, sc[1], sc[2], sc[3], 0.1)
                end
            end

            -- Row separator
            local sc = theme.colors.separator
            Core.DrawLine(x, ry + row_h - 1, x + avail_w, ry + row_h - 1, sc[1], sc[2], sc[3], 0.08)
        end

        -- Scroll with wheel
        if row_count > max_visible then
            local in_table = Core.MouseInRect(x, y, avail_w, total_h)
            if in_table and not Core.HasPopup() then
                local wheel = Core.GetState().mouse_wheel
                if wheel ~= 0 then
                    data.scroll = data.scroll - wheel * 2
                    data.scroll = math.max(0, math.min(data.scroll, row_count - visible_rows))
                end
            end
        else
            data.scroll = 0
        end

        -- Border
        local bc = theme.colors.border
        Core.DrawRect(x, y, avail_w, total_h, bc[1], bc[2], bc[3], 0.3, false)
    end

    Core.SetWidgetData("itable_" .. id, data)
    Layout.AdvanceCursor(avail_w, total_h)
    return clicked_row, clicked_col_key, hovered_row
end

return Widgets
