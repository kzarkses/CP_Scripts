-- CP_Toolkit Layout — Container system, child regions, scroll, positioning
-- Emulates ImGui-style layout: vertical stacking, SameLine, child windows

local Layout = {}
local Core  -- set via init

-- ============================================================================
-- INIT
-- ============================================================================
function Layout.Init(core)
    Core = core
end

-- ============================================================================
-- CONTAINER DEFINITION
-- ============================================================================
-- A container tracks a rectangular region and a layout cursor within it.
-- Widgets advance the cursor as they are placed.
--
-- Fields:
--   x, y          = top-left origin (screen coords)
--   w, h          = total size
--   pad_x, pad_y  = inner padding
--   cursor_x, cursor_y = current draw position (relative to x, y)
--   content_h     = total content height (for scroll)
--   scroll_y      = scroll offset
--   same_line     = flag for horizontal layout
--   same_line_x   = saved x after SameLine
--   max_row_h     = tallest widget on current row (for SameLine)
--   spacing       = vertical spacing between widgets
--   id            = container ID string

local function new_container(id, x, y, w, h, pad_x, pad_y, spacing, scrollable)
    return {
        id = id,
        x = x,
        y = y,
        w = w,
        h = h,
        pad_x = pad_x or 8,
        pad_y = pad_y or 8,
        cursor_x = pad_x or 8,
        cursor_y = pad_y or 8,
        content_h = 0,
        scroll_y = 0,
        scrollable = scrollable or false,
        same_line = false,
        same_line_x = 0,
        max_row_h = 0,
        spacing = spacing or 4,
        -- Indent tracking (separate from cursor_x so it persists across rows)
        indent_x = 0,
        -- SameLine row pending: true when the last widget was on a SameLine row
        -- and cursor_y hasn't advanced past it yet
        sameline_pending = false,
        -- Track last widget position for SameLine
        last_widget_end_x = pad_x or 8,
        last_widget_y = pad_y or 8,
        last_widget_h = 0,
    }
end

-- ============================================================================
-- BEGIN / END WINDOW (root container)
-- ============================================================================
function Layout.Begin(id, theme)
    local state = Core.GetState()
    local w, h = Core.GetWindowSize()
    local pad = theme and theme.window_padding or 8
    local spacing = theme and theme.item_spacing or 4

    -- Clear background
    if theme then
        local bg = theme.colors.window_bg
        Core.DrawRect(0, 0, w, h, bg[1], bg[2], bg[3], bg[4])
    else
        Core.DrawRect(0, 0, w, h, 0.13, 0.13, 0.13, 1)
    end

    -- Get persistent scroll state for root
    local data = Core.GetWidgetData("root_" .. id, { scroll_y = 0, content_h = 0 })

    local c = new_container(id, 0, 0, w, h, pad, pad, spacing, true)
    c.scroll_y = data.scroll_y

    Core.PushContainer(c)
    Core.PushClipRect(0, 0, w, h)
end

function Layout.End()
    local c = Core.CurrentContainer()
    if c then
        -- Calculate content height (cursor_y + last row)
        local content_h = c.cursor_y + c.max_row_h + c.pad_y
        -- Flush sameline pending
        if c.sameline_pending then
            content_h = c.cursor_y + c.max_row_h + c.spacing + c.pad_y
        end

        local data = Core.GetWidgetData("root_" .. c.id, {})
        data.content_h = content_h

        -- Scroll with mouse wheel when content overflows
        if content_h > c.h then
            local state = Core.GetState()
            if not Core.HasPopup() then
                local wheel = state.mouse_wheel
                if wheel ~= 0 then
                    local scroll_range = content_h - c.h
                    data.scroll_y = data.scroll_y - wheel * 30
                    data.scroll_y = math.max(0, math.min(data.scroll_y, scroll_range))
                end
            end

            -- Draw scrollbar
            Layout._DrawScrollbar(c, data)
        else
            data.scroll_y = 0
        end

        Core.SetWidgetData("root_" .. c.id, data)
    end

    Core.PopClipRect()
    Core.PopContainer()
end

-- ============================================================================
-- BEGIN / END CHILD (scrollable sub-region)
-- ============================================================================
function Layout.BeginChild(id, w, h, opts)
    opts = opts or {}
    local parent = Core.CurrentContainer()
    if not parent then return end

    local theme = opts.theme
    local pad = opts.padding or 6
    local spacing = opts.spacing or (parent.spacing)
    local border = opts.border ~= false
    local scrollable = opts.scrollable ~= false

    -- Resolve position from parent cursor
    local abs_x = parent.x + parent.cursor_x
    local abs_y = parent.y + parent.cursor_y - (parent.scrollable and parent.scroll_y or 0)

    -- Auto-width: fill remaining space
    if not w or w <= 0 then
        w = parent.w - parent.cursor_x - parent.pad_x
    end
    if not h or h <= 0 then
        h = parent.h - parent.cursor_y - parent.pad_y
    end

    -- Get or create persistent scroll state
    local data = Core.GetWidgetData("child_" .. id, { scroll_y = 0, content_h = 0 })

    local c = new_container(id, abs_x, abs_y, w, h, pad, pad, spacing, scrollable)
    c.scroll_y = data.scroll_y

    -- Draw child background
    if opts.bg then
        Core.DrawRect(abs_x, abs_y, w, h, opts.bg[1], opts.bg[2], opts.bg[3], opts.bg[4] or 1)
    end

    -- Draw border
    if border and theme then
        local bc = theme.colors.border
        Core.DrawRect(abs_x, abs_y, w, h, bc[1], bc[2], bc[3], bc[4] or 0.4, false)
    elseif border then
        Core.DrawRect(abs_x, abs_y, w, h, 0.3, 0.3, 0.3, 0.4, false)
    end

    Core.PushContainer(c)
    Core.PushClipRect(abs_x, abs_y, w, h)
end

function Layout.EndChild()
    local c = Core.CurrentContainer()
    if not c then
        Core.PopClipRect()
        Core.PopContainer()
        return
    end

    -- Calculate total content height
    local content_h = c.cursor_y + c.max_row_h
    local data = Core.GetWidgetData("child_" .. c.id, {})
    data.content_h = content_h

    -- Handle scroll wheel inside child
    if c.scrollable and content_h > c.h then
        local state = Core.GetState()
        if Core.MouseInRect(c.x, c.y, c.w, c.h) and not Core.HasPopup() then
            local wheel = state.mouse_wheel
            if wheel ~= 0 then
                data.scroll_y = data.scroll_y - wheel * 20
                data.scroll_y = math.max(0, math.min(data.scroll_y, content_h - c.h + c.pad_y * 2))
            end
        end

        -- Draw scrollbar
        Layout._DrawScrollbar(c, data)
    else
        data.scroll_y = 0
    end

    Core.SetWidgetData("child_" .. c.id, data)
    Core.PopClipRect()
    Core.PopContainer()

    -- Advance parent cursor
    local parent = Core.CurrentContainer()
    if parent then
        Layout._AdvanceCursor(parent, c.w, c.h)
    end
end

-- ============================================================================
-- SCROLLBAR
-- ============================================================================
function Layout._DrawScrollbar(c, data)
    local bar_w = 6
    local bar_x = c.x + c.w - bar_w - 2
    local bar_y = c.y + 2
    local bar_h = c.h - 4

    local visible_ratio = c.h / data.content_h
    local thumb_h = math.max(20, bar_h * visible_ratio)
    local scroll_range = data.content_h - c.h + c.pad_y * 2
    local scroll_ratio = scroll_range > 0 and (data.scroll_y / scroll_range) or 0
    local thumb_y = bar_y + (bar_h - thumb_h) * scroll_ratio

    -- Track background
    Core.DrawRect(bar_x, bar_y, bar_w, bar_h, 0.2, 0.2, 0.2, 0.3)

    -- Thumb
    local hover = Core.MouseInRect(bar_x - 2, thumb_y, bar_w + 4, thumb_h)
    local drag_id = "scrollbar_" .. c.id

    if hover or Core.IsActive(drag_id) then
        Core.DrawRect(bar_x, thumb_y, bar_w, thumb_h, 0.5, 0.5, 0.5, 0.7)
    else
        Core.DrawRect(bar_x, thumb_y, bar_w, thumb_h, 0.4, 0.4, 0.4, 0.5)
    end

    -- Drag scrollbar thumb
    if hover and Core.MouseClicked(1) then
        Core.SetActive(drag_id)
    end
    if Core.IsActive(drag_id) then
        if Core.MouseDown(1) then
            local _, dy = Core.MouseDelta()
            if dy ~= 0 and bar_h > thumb_h then
                local scroll_per_pixel = scroll_range / (bar_h - thumb_h)
                data.scroll_y = data.scroll_y + dy * scroll_per_pixel
                data.scroll_y = math.max(0, math.min(data.scroll_y, scroll_range))
            end
        else
            Core.ClearActive()
        end
    end
end

-- ============================================================================
-- LAYOUT CURSOR MANAGEMENT
-- ============================================================================
function Layout._AdvanceCursor(c, widget_w, widget_h)
    -- Save widget end position BEFORE advancing (for SameLine)
    c.last_widget_end_x = c.cursor_x + widget_w
    c.last_widget_y = c.cursor_y
    c.last_widget_h = widget_h

    if c.same_line then
        -- Horizontal: advance X, stay on same Y
        c.cursor_x = c.cursor_x + widget_w + c.spacing
        c.max_row_h = math.max(c.max_row_h, widget_h)
        c.same_line = false
        c.sameline_pending = true  -- row hasn't been "closed" yet
    else
        -- If a SameLine row just ended, advance past it first
        if c.sameline_pending then
            c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
            c.cursor_x = c.pad_x + c.indent_x
            c.sameline_pending = false
            c.max_row_h = 0
        end
        -- Vertical: advance Y, reset X
        local row_h = math.max(c.max_row_h, widget_h)
        c.cursor_y = c.cursor_y + row_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.max_row_h = widget_h
    end
end

function Layout.SameLine(spacing)
    local c = Core.CurrentContainer()
    if not c then return end
    -- Undo the vertical advance: go back to the row of the last widget
    c.cursor_y = c.last_widget_y
    c.cursor_x = c.last_widget_end_x + (spacing or c.spacing)
    c.same_line = true
    c.max_row_h = math.max(c.max_row_h, c.last_widget_h)
end

function Layout.NewLine()
    local c = Core.CurrentContainer()
    if not c then return end
    -- Flush pending SameLine row
    if c.sameline_pending then
        c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
        c.sameline_pending = false
    end
    c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
    c.cursor_x = c.pad_x + c.indent_x
    c.max_row_h = 0
    c.same_line = false
end

function Layout.Spacing(amount)
    local c = Core.CurrentContainer()
    if not c then return end
    -- Flush pending SameLine row
    if c.sameline_pending then
        c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.sameline_pending = false
        c.max_row_h = 0
    end
    c.cursor_y = c.cursor_y + (amount or c.spacing)
end

function Layout.Indent(amount)
    local c = Core.CurrentContainer()
    if not c then return end
    local amt = amount or 16
    c.indent_x = c.indent_x + amt
    c.cursor_x = c.cursor_x + amt
end

function Layout.Unindent(amount)
    local c = Core.CurrentContainer()
    if not c then return end
    local amt = amount or 16
    c.indent_x = math.max(0, c.indent_x - amt)
    c.cursor_x = math.max(c.pad_x, c.cursor_x - amt)
end

-- ============================================================================
-- GET WIDGET POSITION (resolves cursor + scroll into screen coords)
-- ============================================================================
function Layout.GetCursorPos()
    local c = Core.CurrentContainer()
    if not c then return 0, 0 end
    local x = c.x + c.cursor_x
    local y = c.y + c.cursor_y - (c.scrollable and c.scroll_y or 0)
    return x, y
end

-- Returns Y position centered on the current SameLine row.
-- Use this when a widget (e.g. Text) needs to vertically align
-- with taller widgets (e.g. Buttons) on the same line.
function Layout.GetCursorPosAligned(widget_h)
    local c = Core.CurrentContainer()
    if not c then return 0, 0 end
    local x = c.x + c.cursor_x
    local base_y = c.y + c.cursor_y - (c.scrollable and c.scroll_y or 0)
    -- If on a SameLine row with taller widgets, center vertically
    if c.max_row_h > widget_h then
        base_y = base_y + math.floor((c.max_row_h - widget_h) / 2)
    end
    return x, base_y
end

function Layout.GetAvailableWidth()
    local c = Core.CurrentContainer()
    if not c then return 0 end
    return c.w - c.cursor_x - c.pad_x
end

function Layout.GetAvailableHeight()
    local c = Core.CurrentContainer()
    if not c then return 0 end
    return c.h - c.cursor_y - c.pad_y
end

function Layout.AdvanceCursor(w, h)
    local c = Core.CurrentContainer()
    if not c then return end
    Layout._AdvanceCursor(c, w, h)
end

-- ============================================================================
-- SEPARATOR (convenience — also in Widgets, but layout-aware)
-- ============================================================================
function Layout.Separator(theme)
    local c = Core.CurrentContainer()
    if not c then return end

    local x, y = Layout.GetCursorPos()
    local w = Layout.GetAvailableWidth()

    if theme then
        local sc = theme.colors.separator
        Core.DrawLine(x, y + 2, x + w, y + 2, sc[1], sc[2], sc[3], sc[4] or 0.5)
    else
        Core.DrawLine(x, y + 2, x + w, y + 2, 0.3, 0.3, 0.3, 0.5)
    end

    Layout.AdvanceCursor(w, 5)
end

return Layout
