-- CP_Toolkit Layout — Container system, child regions, scroll, positioning
-- Emulates ImGui-style layout: vertical stacking, SameLine, child windows

-- Localize math lib — avoids table lookup per call on hot paths.
local floor, min, max, abs, ceil = math.floor, math.min, math.max, math.abs, math.ceil

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

-- Containers are POOLED per id (audit P8: a fresh ~20-field table per
-- Begin/BeginChild per frame ≈ 150 KB/s of GC churn at 30 fps on a typical
-- UI). fill_container wipes then re-fills a persistent table: the wipe
-- guarantees no stale field survives, and steady state allocates nothing.
local function fill_container(c, id, x, y, w, h, pad_x, pad_y, spacing, scrollable, scrollable_x)
    for k in pairs(c) do c[k] = nil end
    c.id = id
    c.x = x
    c.y = y
    c.w = w
    c.h = h
    c.pad_x = pad_x or 8
    c.pad_y = pad_y or 8
    c.cursor_x = pad_x or 8
    c.cursor_y = pad_y or 8
    c.content_h = 0
    c.content_w = 0
    c.scroll_y = 0
    c.scroll_x = 0
    c.scrollable   = scrollable   or false  -- vertical scroll
    c.scrollable_x = scrollable_x or false  -- horizontal scroll
    c.same_line = false
    c.same_line_x = 0
    c.max_row_h = 0
    c.spacing = spacing or 4
    -- Indent tracking (separate from cursor_x so it persists across rows)
    c.indent_x = 0
    -- SameLine row pending: true when the last widget was on a SameLine row
    -- and cursor_y hasn't advanced past it yet
    c.sameline_pending = false
    -- Track last widget position for SameLine
    c.last_widget_end_x = pad_x or 8
    c.last_widget_y = pad_y or 8
    c.last_widget_h = 0
    return c
end

-- Minimal variant for column sub-containers (zero padding, fixed geometry)
local function fill_col_container(c, id, x, y, w, h, spacing)
    for k in pairs(c) do c[k] = nil end
    c.id = id
    c.x = x; c.y = y; c.w = w; c.h = h
    c.pad_x = 0; c.pad_y = 0
    c.cursor_x = 0; c.cursor_y = 0
    c.content_h = 0; c.scroll_y = 0
    c.scrollable = false
    c.same_line = false; c.same_line_x = 0
    c.max_row_h = 0; c.spacing = spacing
    c.indent_x = 0; c.sameline_pending = false
    c.last_widget_end_x = 0; c.last_widget_y = 0; c.last_widget_h = 0
    return c
end

-- ============================================================================
-- BEGIN / END WINDOW (root container)
-- ============================================================================
function Layout.Begin(id, theme, opts)
    opts = opts or {}
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

    -- Allow callers to disable root scrolling entirely (toolbars, status bars)
    local scrollable = opts.scrollable ~= false

    -- Get persistent scroll state for root
    local data = Core.GetWidgetSubData("root", id)
    if data._init == nil then
        data.scroll_y = 0
        data.content_h = 0
        data._init = true
    end

    local c = data.c
    if not c then c = {}; data.c = c end
    fill_container(c, id, 0, 0, w, h, pad, pad, spacing, scrollable)
    c.scroll_y = scrollable and data.scroll_y or 0
    c._no_scroll = not scrollable

    Core.PushContainer(c)
    Core.PushClipRect(0, 0, w, h)
end

function Layout.End()
    local c = Core.CurrentContainer()
    if c then
        -- After _AdvanceCursor, cursor_y already points BELOW the last widget
        -- (it includes widget_h + item_spacing). So we subtract that trailing
        -- spacing and add the bottom pad. Without this, content_h overshoots
        -- by spacing + widget_h, causing a phantom scrollbar even when the
        -- content visually fits the window.
        -- A pending SameLine row hasn't been closed yet → cursor_y is still
        -- on the row's top, so we add max_row_h instead.
        local content_h
        if c.sameline_pending then
            content_h = c.cursor_y + c.max_row_h + c.pad_y
        else
            content_h = c.cursor_y - c.spacing + c.pad_y
        end
        if content_h < c.pad_y * 2 then content_h = c.pad_y * 2 end

        local data = Core.GetWidgetSubData("root", c.id)
        data.content_h = content_h

        -- Scroll with mouse wheel when content overflows (skipped when no_scroll).
        -- Notch-based step: one wheel tick scrolls by SCROLL_STEP pixels,
        -- independent of platform wheel-delta magnitude.
        if not c._no_scroll and content_h > c.h then
            local state = Core.GetState()
            local scroll_range = content_h - c.h
            if not Core.HasPopup() and not Core.IsWheelConsumed() then
                local wheel = state.mouse_wheel
                if wheel ~= 0 then
                    local SCROLL_STEP = 40  -- pixels per wheel notch
                    local dir = wheel > 0 and -1 or 1
                    data.scroll_y = data.scroll_y + dir * SCROLL_STEP
                end
            end
            -- Re-clamp every frame (audit B22: a section collapse that
            -- shrinks content used to leave the view stuck past the end)
            data.scroll_y = max(0, min(data.scroll_y, scroll_range))

            -- Draw scrollbar
            Layout._DrawScrollbar(c, data)
        else
            data.scroll_y = 0
        end
        -- data is a reference from GetWidgetData; field mutations persist without SetWidgetData.
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
    -- Horizontal scroll is opt-in. When enabled, content can extend past the
    -- right edge and the user scrolls with the scrollbar or Shift+wheel.
    local scrollable_x = opts.scrollable_x == true

    -- Resolve position from parent cursor
    local abs_x = parent.x + parent.cursor_x - (parent.scrollable_x and parent.scroll_x or 0)
    local abs_y = parent.y + parent.cursor_y - (parent.scrollable   and parent.scroll_y   or 0)

    -- Auto-width: fill remaining space
    if not w or w <= 0 then
        w = parent.w - parent.cursor_x - parent.pad_x
    end
    if not h or h <= 0 then
        h = parent.h - parent.cursor_y - parent.pad_y
    end

    -- Get or create persistent scroll state
    local data = Core.GetWidgetSubData("child", id)
    if data._init == nil then
        data.scroll_y = 0
        data.scroll_x = 0
        data.content_h = 0
        data.content_w = 0
        data._init = true
    end
    data.scroll_x = data.scroll_x or 0

    local c = data.c
    if not c then c = {}; data.c = c end
    fill_container(c, id, abs_x, abs_y, w, h, pad, pad, spacing, scrollable, scrollable_x)
    c.scroll_y = data.scroll_y
    c.scroll_x = data.scroll_x

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

    -- See Layout.End() — cursor_y already includes the trailing item_spacing,
    -- so subtract it to avoid a phantom scrollbar when content visually fits.
    local content_h
    if c.sameline_pending then
        content_h = c.cursor_y + c.max_row_h + c.pad_y
    else
        content_h = c.cursor_y - c.spacing + c.pad_y
    end
    if content_h < c.pad_y * 2 then content_h = c.pad_y * 2 end
    local content_w = (c.content_w or 0) + c.pad_x  -- + trailing padding
    local data = Core.GetWidgetSubData("child", c.id)
    data.content_h = content_h
    data.content_w = content_w

    -- Handle scroll wheel inside child. Notch-based step (see Layout.End).
    -- Shift+wheel scrolls horizontally when scrollable_x is enabled,
    -- regular wheel scrolls vertically when scrollable is enabled.
    local has_v_scroll = c.scrollable   and content_h > c.h
    local has_h_scroll = c.scrollable_x and content_w > c.w
    if (has_v_scroll or has_h_scroll) then
        local state = Core.GetState()
        -- Clipped hit-test (audit B21: a child partially scrolled out of an
        -- ancestor used to keep an invisible wheel/click zone alive)
        if Core.MouseInClippedRect(c.x, c.y, c.w, c.h) and not Core.HasPopup() and not Core.IsWheelConsumed() then
            local wheel = state.mouse_wheel
            if wheel ~= 0 then
                local SCROLL_STEP = 40
                local dir = wheel > 0 and -1 or 1
                local horizontal = Core.ModShift() and has_h_scroll
                if has_v_scroll and not horizontal then
                    data.scroll_y = data.scroll_y + dir * SCROLL_STEP
                    Core.ConsumeWheel()
                elseif has_h_scroll then
                    data.scroll_x = data.scroll_x + dir * SCROLL_STEP
                    Core.ConsumeWheel()
                end
            end
        end
        -- Unified range + per-frame re-clamp (audit B22: the wheel, the thumb
        -- drag and the root wheel each used a different max — the thumb could
        -- scroll pad*2 further, then the next wheel tick snapped back; and a
        -- shrinking content left the view past the end)
        if has_v_scroll then
            data.scroll_y = max(0, min(data.scroll_y, content_h - c.h))
            Layout._DrawScrollbar(c, data)
        end
        if has_h_scroll then
            data.scroll_x = max(0, min(data.scroll_x, content_w - c.w))
            Layout._DrawScrollbarH(c, data)
        end
    end
    if not has_v_scroll then data.scroll_y = 0 end
    if not has_h_scroll then data.scroll_x = 0 end
    -- data is a reference from GetWidgetData; mutations persist without SetWidgetData.
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
    local thumb_h = max(20, bar_h * visible_ratio)
    -- Same range as the wheel handlers (audit B22)
    local scroll_range = data.content_h - c.h
    local scroll_ratio = scroll_range > 0 and (data.scroll_y / scroll_range) or 0
    local thumb_y = bar_y + (bar_h - thumb_h) * scroll_ratio

    -- Track background
    Core.DrawRect(bar_x, bar_y, bar_w, bar_h, 0.2, 0.2, 0.2, 0.3)

    -- Thumb (clipped hit-test — audit B21; drag id cached — audit P9)
    local hover = Core.MouseInClippedRect(bar_x - 2, thumb_y, bar_w + 4, thumb_h)
    local drag_id = data._sb_id
    if not drag_id then
        drag_id = "scrollbar_" .. c.id
        data._sb_id = drag_id
    end

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
                data.scroll_y = max(0, min(data.scroll_y, scroll_range))
            end
        else
            Core.ClearActive()
        end
    end
end

-- Horizontal scrollbar (mirror of _DrawScrollbar). Drawn at the bottom of
-- the container; height = scrollbar_thickness from the theme (falls back
-- to the same 6 px the vertical bar uses).
function Layout._DrawScrollbarH(c, data)
    local bar_h = 6
    local bar_x = c.x + 2
    local bar_y = c.y + c.h - bar_h - 2
    local bar_w = c.w - 4

    local visible_ratio = c.w / data.content_w
    local thumb_w = max(20, bar_w * visible_ratio)
    -- Same range as the wheel handlers (audit B22)
    local scroll_range = data.content_w - c.w
    local scroll_ratio = scroll_range > 0 and (data.scroll_x / scroll_range) or 0
    local thumb_x = bar_x + (bar_w - thumb_w) * scroll_ratio

    -- Track background
    Core.DrawRect(bar_x, bar_y, bar_w, bar_h, 0.2, 0.2, 0.2, 0.3)

    -- Thumb (clipped hit-test — audit B21; drag id cached — audit P9)
    local hover = Core.MouseInClippedRect(thumb_x, bar_y - 2, thumb_w, bar_h + 4)
    local drag_id = data._sbh_id
    if not drag_id then
        drag_id = "scrollbar_h_" .. c.id
        data._sbh_id = drag_id
    end

    if hover or Core.IsActive(drag_id) then
        Core.DrawRect(thumb_x, bar_y, thumb_w, bar_h, 0.5, 0.5, 0.5, 0.7)
    else
        Core.DrawRect(thumb_x, bar_y, thumb_w, bar_h, 0.4, 0.4, 0.4, 0.5)
    end

    -- Drag scrollbar thumb
    if hover and Core.MouseClicked(1) then
        Core.SetActive(drag_id)
    end
    if Core.IsActive(drag_id) then
        if Core.MouseDown(1) then
            local dx, _ = Core.MouseDelta()
            if dx ~= 0 and bar_w > thumb_w then
                local scroll_per_pixel = scroll_range / (bar_w - thumb_w)
                data.scroll_x = data.scroll_x + dx * scroll_per_pixel
                data.scroll_x = max(0, min(data.scroll_x, scroll_range))
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

    -- Record the item rect for Core.IsItemHovered/IsItemClicked (F7).
    -- Single choke point: every widget passes through here.
    Core.SetLastItemRect(
        c.x + c.cursor_x - (c.scrollable_x and c.scroll_x or 0),
        c.y + c.cursor_y - (c.scrollable and c.scroll_y or 0),
        widget_w, widget_h)

    -- Track the rightmost X reached so horizontal-scrolling containers can
    -- compute content_w. We sample the widget's right edge regardless of
    -- the SameLine flag.
    if c.last_widget_end_x > (c.content_w or 0) then
        c.content_w = c.last_widget_end_x
    end

    if c.same_line then
        -- Horizontal: advance X, stay on same Y
        c.cursor_x = c.cursor_x + widget_w + c.spacing
        c.max_row_h = max(c.max_row_h, widget_h)
        c.same_line = false
        c.sameline_pending = true  -- row hasn't been "closed" yet
    else
        -- If a SameLine row just ended, advance past it first
        if c.sameline_pending then
            c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
            c.cursor_x = c.pad_x + c.indent_x
            c.sameline_pending = false
        end
        -- Vertical: advance by THIS widget's height (audit B20: the old
        -- max(c.max_row_h, widget_h) reused the PREVIOUS widget's height —
        -- a tall Canvas followed by a one-line Text left a phantom gap, and
        -- GetCursorPosAligned centered text against a stale row height).
        c.cursor_y = c.cursor_y + widget_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.max_row_h = 0
    end
end

function Layout.SameLine(spacing)
    local c = Core.CurrentContainer()
    if not c then return end
    -- Undo the vertical advance: go back to the row of the last widget
    c.cursor_y = c.last_widget_y
    c.cursor_x = c.last_widget_end_x + (spacing or c.spacing)
    c.same_line = true
    c.max_row_h = max(c.max_row_h, c.last_widget_h)
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
    c.indent_x = max(0, c.indent_x - amt)
    c.cursor_x = max(c.pad_x, c.cursor_x - amt)
end

-- ============================================================================
-- GET WIDGET POSITION (resolves cursor + scroll into screen coords)
-- ============================================================================
-- Close any pending SameLine row so the next widget lands on a new line.
-- Called by GetCursorPos when not in a SameLine call. Without this, calling
-- a vertical widget right after a SameLine pair would draw it at the end of
-- the previous row (the pending row would only be closed by _AdvanceCursor
-- which runs AFTER the widget has already drawn).
local function _flush_pending_row(c)
    if c.sameline_pending and not c.same_line then
        c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.sameline_pending = false
        c.max_row_h = 0
    end
end

function Layout.GetCursorPos()
    local c = Core.CurrentContainer()
    if not c then return 0, 0 end
    _flush_pending_row(c)
    local x = c.x + c.cursor_x - (c.scrollable_x and c.scroll_x or 0)
    local y = c.y + c.cursor_y - (c.scrollable   and c.scroll_y or 0)
    return x, y
end

-- Returns Y position centered on the current SameLine row.
-- Use this when a widget (e.g. Text) needs to vertically align
-- with taller widgets (e.g. Buttons) on the same line.
function Layout.GetCursorPosAligned(widget_h)
    local c = Core.CurrentContainer()
    if not c then return 0, 0 end
    _flush_pending_row(c)
    local x = c.x + c.cursor_x - (c.scrollable_x and c.scroll_x or 0)
    local base_y = c.y + c.cursor_y - (c.scrollable and c.scroll_y or 0)
    -- If on a SameLine row with taller widgets, center vertically
    if c.max_row_h > widget_h then
        base_y = base_y + floor((c.max_row_h - widget_h) / 2)
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
    -- If inside a wrap context, use wrap logic instead
    if Layout.IsWrapping() then
        Layout.WrapItem(w, h)
        return
    end
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
    local pad = (theme and theme.separator_pad) or 4

    if theme then
        local sc = theme.colors.separator
        Core.DrawLine(x, y + pad, x + w, y + pad, sc[1], sc[2], sc[3], sc[4] or 0.5)
    else
        Core.DrawLine(x, y + pad, x + w, y + pad, 0.3, 0.3, 0.3, 0.5)
    end

    -- We want the *total* vertical advance to be (pad above + 1px line + pad below)
    -- regardless of theme.item_spacing. _AdvanceCursor always tacks on c.spacing
    -- after the widget — strip that here so Separator's footprint stays exactly
    -- pad*2+1. With pad=0 and spacing=5 the next widget now starts immediately
    -- after the line instead of 5px later.
    Layout.AdvanceCursor(w, pad * 2 + 1)
    c.cursor_y = c.cursor_y - c.spacing
end

-- ============================================================================
-- WRAP LAYOUT (auto-wrap like CSS flex-wrap)
-- ============================================================================
-- Widgets placed inside BeginWrap/EndWrap flow horizontally and wrap
-- to the next line when they exceed the available width.
-- Each widget calls Layout.WrapItem(w, h) instead of AdvanceCursor.
-- Descriptors are pooled per stack depth (audit P8: one table per
-- BeginWrap per frame).
local wrap_stack = {}
local wrap_pool = {}

function Layout.BeginWrap(id, opts)
    opts = opts or {}
    local c = Core.CurrentContainer()
    if not c then return end

    -- Flush pending SameLine
    if c.sameline_pending then
        c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.sameline_pending = false
        c.max_row_h = 0
    end

    local gap = opts.gap or c.spacing

    local depth = #wrap_stack + 1
    local wrap = wrap_pool[depth]
    if not wrap then wrap = {}; wrap_pool[depth] = wrap end
    wrap.id = id
    wrap.start_x = c.cursor_x
    wrap.start_y = c.cursor_y
    wrap.gap = gap
    wrap.row_h = 0
    wrap.max_x = c.w - c.pad_x  -- right edge (absolute within container)
    wrap_stack[depth] = wrap
end

-- Called automatically by AdvanceCursor when inside a wrap context.
function Layout.WrapItem(w, h)
    local wrap = wrap_stack[#wrap_stack]
    if not wrap then return end

    local c = Core.CurrentContainer()
    if not c then return end

    -- Save last widget info
    c.last_widget_end_x = c.cursor_x + w
    c.last_widget_y = c.cursor_y
    c.last_widget_h = h

    -- Item rect for Core.IsItemHovered/IsItemClicked (F7)
    Core.SetLastItemRect(
        c.x + c.cursor_x - (c.scrollable_x and c.scroll_x or 0),
        c.y + c.cursor_y - (c.scrollable and c.scroll_y or 0),
        w, h)

    wrap.row_h = max(wrap.row_h, h)

    -- Advance X for the next widget
    c.cursor_x = c.cursor_x + w + wrap.gap
    c.max_row_h = wrap.row_h
end

-- Called by GetCursorPos: pre-check if the next widget would overflow, wrap BEFORE drawing
function Layout.WrapPreCheck(estimated_w)
    local wrap = wrap_stack[#wrap_stack]
    if not wrap then return end

    local c = Core.CurrentContainer()
    if not c then return end

    -- If current cursor_x + estimated widget width exceeds the max, wrap first
    if c.cursor_x + estimated_w > wrap.max_x and c.cursor_x > wrap.start_x then
        c.cursor_y = c.cursor_y + wrap.row_h + wrap.gap
        c.cursor_x = wrap.start_x
        wrap.row_h = 0
    end
end

function Layout.EndWrap()
    local wrap = wrap_stack[#wrap_stack]
    if not wrap then return end
    wrap_stack[#wrap_stack] = nil

    local c = Core.CurrentContainer()
    if not c then return end

    -- Advance past the last wrap row
    c.cursor_y = c.cursor_y + wrap.row_h + c.spacing
    c.cursor_x = c.pad_x + c.indent_x
    c.max_row_h = 0
    c.sameline_pending = false
end

-- Check if we're currently inside a wrap context
function Layout.IsWrapping()
    return #wrap_stack > 0
end

-- ============================================================================
-- COLUMNS (proportional or fixed widths)
-- ============================================================================
-- ratios = {0.3, 0.7} for 30%/70%, or {120, 0} for 120px fixed + fill rest
-- Negative values = fixed pixel, positive <= 1 = ratio, > 1 = fixed pixel
local column_stack = {}

function Layout.BeginColumns(id, ratios, opts)
    opts = opts or {}
    local c = Core.CurrentContainer()
    if not c then return end

    -- Flush pending SameLine
    if c.sameline_pending then
        c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.sameline_pending = false
        c.max_row_h = 0
    end

    local avail_w = c.w - c.cursor_x - c.pad_x
    local gap = opts.gap or c.spacing

    -- Pooled descriptor + column containers + pre-built ids (audit P8: this
    -- was the biggest remaining per-frame allocator in Layout — ~6 tables
    -- and one string concat per column per frame).
    local cd = Core.GetWidgetSubData("columns", id)
    if cd.ncols ~= #ratios then
        cd.ncols = #ratios
        local ids = cd.ids
        if not ids then ids = {}; cd.ids = ids end
        for i = 1, #ratios do ids[i] = id .. "_col" .. i end
        for i = #ratios + 1, #ids do ids[i] = nil end
    end
    if not cd.desc then
        cd.desc = { widths = {}, positions = {}, pool = {} }
    end
    local cols = cd.desc
    local col_widths = cols.widths
    local col_positions = cols.positions
    for i = #ratios + 1, #col_widths do
        col_widths[i] = nil
        col_positions[i] = nil
    end

    -- Calculate column widths
    local total_fixed = 0
    local total_ratio = 0
    local gaps_total = (#ratios - 1) * gap

    for i, r in ipairs(ratios) do
        if r > 1 then
            col_widths[i] = r  -- fixed pixel
            total_fixed = total_fixed + r
        elseif r > 0 then
            col_widths[i] = r  -- ratio (will be resolved)
            total_ratio = total_ratio + r
        else
            col_widths[i] = 0  -- auto-fill
            total_ratio = total_ratio + 1
        end
    end

    local remaining = avail_w - total_fixed - gaps_total
    for i, r in ipairs(ratios) do
        if r <= 1 then
            local share = (r > 0) and r or 1
            col_widths[i] = floor(remaining * share / total_ratio)
        end
    end

    -- Calculate absolute X positions (account for any horizontal scroll on
    -- the parent container; scroll_y is applied separately on col_y).
    local abs_x = c.x + c.cursor_x - (c.scrollable_x and c.scroll_x or 0)
    for i = 1, #ratios do
        col_positions[i] = abs_x
        abs_x = abs_x + col_widths[i] + gap
    end

    cols.id = id
    cols.count = #ratios
    cols.gap = gap
    cols.current = 1
    cols.start_y = c.cursor_y
    cols.max_h = 0  -- tallest column content
    cols.parent_cursor_x = c.cursor_x
    cols.parent_cursor_y = c.cursor_y
    cols.ids = cd.ids

    column_stack[#column_stack + 1] = cols

    -- Push first column as a pooled child container (no border, no scroll)
    local col_x = col_positions[1]
    local col_w = col_widths[1]
    local col_y = c.y + c.cursor_y - (c.scrollable and c.scroll_y or 0)
    local col_h = c.h - c.cursor_y - c.pad_y  -- max height from current pos

    local col_c = cols.pool[1]
    if not col_c then col_c = {}; cols.pool[1] = col_c end
    fill_col_container(col_c, cols.ids[1], col_x, col_y, col_w, col_h, c.spacing)

    Core.PushContainer(col_c)
    Core.PushClipRect(col_x, col_y, col_w, col_h)
end

function Layout.NextColumn()
    local cols = column_stack[#column_stack]
    if not cols then return end

    -- Pop current column container. Same logic as EndColumns: cursor_y
    -- already includes a trailing spacing after the last widget — strip it
    -- so cols.max_h matches the visible content height.
    local old_c = Core.CurrentContainer()
    if old_c then
        local col_content_h
        if old_c.sameline_pending then
            col_content_h = old_c.cursor_y + old_c.max_row_h
        else
            col_content_h = old_c.cursor_y - (old_c.spacing or 0)
        end
        if col_content_h < 0 then col_content_h = 0 end
        cols.max_h = max(cols.max_h, col_content_h)
    end
    Core.PopClipRect()
    Core.PopContainer()

    -- Advance to next column
    cols.current = cols.current + 1
    if cols.current > cols.count then return end

    local parent = Core.CurrentContainer()
    if not parent then return end

    local col_x = cols.positions[cols.current]
    local col_w = cols.widths[cols.current]
    local col_y = parent.y + cols.start_y - (parent.scrollable and parent.scroll_y or 0)
    local col_h = parent.h - cols.start_y - parent.pad_y

    local col_c = cols.pool[cols.current]
    if not col_c then col_c = {}; cols.pool[cols.current] = col_c end
    fill_col_container(col_c, cols.ids[cols.current], col_x, col_y, col_w, col_h, parent.spacing)

    Core.PushContainer(col_c)
    Core.PushClipRect(col_x, col_y, col_w, col_h)
end

function Layout.EndColumns()
    local cols = column_stack[#column_stack]
    if not cols then return end

    -- Pop last column. After _AdvanceCursor, the column's cursor_y already
    -- sits at "past the last widget + trailing spacing", so the content end
    -- is cursor_y minus the trailing spacing the helper appended. When a
    -- SameLine row is still pending, cursor_y didn't advance for that row
    -- yet — we add max_row_h to account for it.
    local old_c = Core.CurrentContainer()
    if old_c then
        local col_content_h
        if old_c.sameline_pending then
            col_content_h = old_c.cursor_y + old_c.max_row_h
        else
            col_content_h = old_c.cursor_y - (old_c.spacing or 0)
        end
        if col_content_h < 0 then col_content_h = 0 end
        cols.max_h = max(cols.max_h, col_content_h)
    end
    Core.PopClipRect()
    Core.PopContainer()

    column_stack[#column_stack] = nil

    -- Advance parent cursor past the tallest column. Parent gets one
    -- spacing unit (matches the post-widget cadence of _AdvanceCursor so
    -- the row of widgets that follows lines up consistently).
    local parent = Core.CurrentContainer()
    if parent then
        parent.cursor_y = cols.start_y + cols.max_h + parent.spacing
        parent.cursor_x = parent.pad_x + parent.indent_x
        parent.max_row_h = 0
    end
end

-- ============================================================================
-- WEIGHTED ROW (responsive, auto-hide narrow columns)
-- ============================================================================
-- weights = { {key="name", weight=2.5, min_w=60}, {key="vol", weight=1.0, min_w=40}, ... }
-- Returns: widths table {key = pixel_width}, visible table {key = bool}
function Layout.BeginWeightedRow(id, weights, opts)
    opts = opts or {}
    local c = Core.CurrentContainer()
    if not c then return {}, {} end

    -- Flush pending SameLine
    if c.sameline_pending then
        c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.sameline_pending = false
        c.max_row_h = 0
    end

    local avail_w = c.w - c.cursor_x - c.pad_x
    local gap = opts.gap or c.spacing
    local row_h = opts.height or 0  -- 0 = auto

    -- All working tables live on the persistent row_data and are re-filled
    -- in place (audit P8: this function allocated 3 tables + 1 closure per
    -- row per frame despite its "Reuse persistent table" comment — a mixer
    -- with 30 rows churned ~120 allocations per frame).
    local row_data = Core.GetWidgetSubData("wrow", id)
    local visible = row_data.visible
    if not visible then visible = {}; row_data.visible = visible end
    for k in pairs(visible) do visible[k] = nil end
    local widths = row_data.widths
    if not widths then widths = {}; row_data.widths = widths end
    for k in pairs(widths) do widths[k] = nil end
    local pos = row_data.pos
    if not pos then pos = {}; row_data.pos = pos end
    for k in pairs(pos) do pos[k] = nil end

    -- First pass: all columns visible
    for _, w in ipairs(weights) do
        visible[w.key] = true
    end

    -- Auto-hide from right if too narrow. Inline min-width total (audit P8:
    -- calc_total_min was a per-frame closure).
    local gaps_needed = max(0, #weights - 1)
    for i = #weights, 1, -1 do
        local total = gaps_needed * gap
        for _, w in ipairs(weights) do
            if visible[w.key] then total = total + (w.min_w or 40) end
        end
        if total <= avail_w then break end
        if i > 1 then
            visible[weights[i].key] = false
        end
    end

    -- Second pass: calculate widths for visible columns
    local total_weight = 0
    local visible_count = 0
    for _, w in ipairs(weights) do
        if visible[w.key] then
            total_weight = total_weight + w.weight
            visible_count = visible_count + 1
        end
    end

    local gaps_total = max(0, visible_count - 1) * gap
    local distributable = avail_w - gaps_total
    for _, w in ipairs(weights) do
        if visible[w.key] then
            widths[w.key] = max(w.min_w or 40,
                floor(distributable * w.weight / total_weight))
        else
            widths[w.key] = 0
        end
    end

    -- Store row state for cell placement
    local abs_x = c.x + c.cursor_x
    local abs_y = c.y + c.cursor_y - (c.scrollable and c.scroll_y or 0)

    -- Precompute each cell's X once (audit P21: WeightedCell used to rescan
    -- the weights list per cell — O(n²) per row per frame).
    local cx = abs_x
    for _, w in ipairs(weights) do
        if visible[w.key] then
            pos[w.key] = cx
            cx = cx + widths[w.key] + gap
        end
    end

    row_data.id = id
    row_data.weights = weights
    row_data.gap = gap
    row_data.start_x = abs_x
    row_data.start_y = abs_y
    row_data.current_x = abs_x
    row_data.height = row_h
    row_data.parent_cursor_y = c.cursor_y
    return widths, visible
end

-- Get position and size for a specific cell in the weighted row
-- Returns: x, y, w, h (screen coords), or nil if not visible
function Layout.WeightedCell(id, key)
    local row = Core.GetWidgetSubData("wrow", id)
    local cell_x = row.pos and row.pos[key]
    if not cell_x then return nil end
    return cell_x, row.start_y, row.widths[key], row.height
end

function Layout.EndWeightedRow(id)
    local row = Core.GetWidgetSubData("wrow", id)
    if not row.widths then return end

    local c = Core.CurrentContainer()
    if not c then return end

    local h = row.height > 0 and row.height or c.spacing
    c.cursor_y = row.parent_cursor_y + h + c.spacing
    c.cursor_x = c.pad_x + c.indent_x
    c.max_row_h = h
end

-- ============================================================================
-- GRID LAYOUT (auto-wrapping cells)
-- ============================================================================
-- Returns: cell_count visible in current row
function Layout.BeginGrid(id, opts)
    opts = opts or {}
    local c = Core.CurrentContainer()
    if not c then return end

    -- Flush pending SameLine
    if c.sameline_pending then
        c.cursor_y = c.cursor_y + c.max_row_h + c.spacing
        c.cursor_x = c.pad_x + c.indent_x
        c.sameline_pending = false
        c.max_row_h = 0
    end

    local cell_w = opts.cell_w or 60
    local cell_h = opts.cell_h or 60
    local gap = opts.gap or c.spacing
    local avail_w = c.w - c.cursor_x - c.pad_x

    local cols = max(1, floor((avail_w + gap) / (cell_w + gap)))

    -- Reuse persistent table to avoid per-frame allocation.
    local grid = Core.GetWidgetSubData("grid", id)
    grid.id = id
    grid.cell_w = cell_w
    grid.cell_h = cell_h
    grid.gap = gap
    grid.cols = cols
    grid.index = 0
    grid.start_cursor_y = c.cursor_y
end

-- Call for each cell. Returns x, y, w, h in screen coords.
function Layout.GridCell(id)
    local grid = Core.GetWidgetSubData("grid", id)
    if not grid.cols then return 0, 0, 0, 0 end

    local c = Core.CurrentContainer()
    if not c then return 0, 0, 0, 0 end

    local col = grid.index % grid.cols
    local row = floor(grid.index / grid.cols)

    local cell_x = c.x + c.pad_x + c.indent_x + col * (grid.cell_w + grid.gap)
    local cell_y = c.y + grid.start_cursor_y + row * (grid.cell_h + grid.gap)
           - (c.scrollable and c.scroll_y or 0)

    grid.index = grid.index + 1
    -- grid is a reference from GetWidgetData; mutation persists without SetWidgetData.
    return cell_x, cell_y, grid.cell_w, grid.cell_h
end

function Layout.EndGrid(id)
    local grid = Core.GetWidgetSubData("grid", id)
    if not grid.cols then return end

    local c = Core.CurrentContainer()
    if not c then return end

    local total_rows = ceil(grid.index / grid.cols)
    local total_h = total_rows * (grid.cell_h + grid.gap) - grid.gap

    c.cursor_y = grid.start_cursor_y + total_h + c.spacing
    c.cursor_x = c.pad_x + c.indent_x
    c.max_row_h = 0
end

-- ============================================================================
-- LIST CLIPPER (virtualization — F1, ImGuiListClipper equivalent)
-- ============================================================================
-- For custom fixed-height rows inside the current container (typically a
-- scrollable BeginChild). Returns the 1-based range of rows that intersect
-- the viewport and positions the cursor at the first one; EndListClipper
-- places the cursor after the whole virtual list. Layout/logic cost becomes
-- O(visible), independent of count — the difference between "usable" and
-- "unplayable" for a 2000-plugin browser on the 2005 target.
--
-- Contract: each row must advance the cursor by exactly row_h (plus the
-- container's item spacing), e.g. widgets of height row_h.
--
-- Usage:
--   UI.BeginChild("list", 0, 0)
--   local first, last = UI.ListClipper(#rows, row_h)
--   for i = first, last do
--       -- draw row i (height row_h)
--   end
--   UI.EndListClipper(#rows, row_h)
--   UI.EndChild()
function Layout.ListClipper(count, row_h)
    local c = Core.CurrentContainer()
    if not c then return 1, count end
    _flush_pending_row(c)

    local step = row_h + c.spacing
    local start_y = c.cursor_y
    local scroll = c.scrollable and c.scroll_y or 0

    -- Visible content band: [scroll, scroll + c.h]
    local first = floor((scroll - start_y) / step) + 1
    if first < 1 then first = 1 end
    local last = ceil((scroll + c.h - start_y) / step)
    if last > count then last = count end
    if last < first then last = first - 1 end  -- nothing visible

    -- Jump the cursor to the first visible row; the skipped rows above cost
    -- nothing (no layout, no measure, no draw).
    c.cursor_y = start_y + (first - 1) * step
    c._clipper_start_y = start_y
    return first, last
end

function Layout.EndListClipper(count, row_h)
    local c = Core.CurrentContainer()
    if not c then return end
    local step = row_h + c.spacing
    local start_y = c._clipper_start_y or c.cursor_y
    -- Place the cursor after the full virtual list so content_h (and the
    -- scrollbar) reflect all rows, drawn or not.
    c.cursor_y = start_y + count * step
    c.cursor_x = c.pad_x + c.indent_x
    c.max_row_h = 0
    c.sameline_pending = false
    c._clipper_start_y = nil
end

-- ============================================================================
-- SPLITTER (horizontal or vertical resizable divider)
-- ============================================================================
-- Returns: size_a (pixels for the first panel)
function Layout.Splitter(id, direction, total_size, default_ratio, opts)
    opts = opts or {}
    local c = Core.CurrentContainer()
    if not c then return floor(total_size * (default_ratio or 0.5)) end

    local thickness = opts.thickness or 6
    local min_a = opts.min_a or 50
    local min_b = opts.min_b or 50

    local data = Core.GetWidgetSubData("splitter", id)
    if data.ratio == nil then
        data.ratio = default_ratio or 0.5
    end
    -- Drag id cached once (audit P9/P22)
    local drag_id = data._drag_id
    if not drag_id then
        drag_id = "splitter_drag_" .. id
        data._drag_id = drag_id
    end

    local size_a = floor(total_size * data.ratio)
    size_a = max(min_a, min(total_size - min_b - thickness, size_a))

    -- Splitter bar position
    local x, y = Layout.GetCursorPos()
    local bar_x, bar_y, bar_w, bar_h

    if direction == "horizontal" then
        bar_x = x + size_a
        bar_y = y
        bar_w = thickness
        bar_h = opts.length or Layout.GetAvailableHeight()
    else
        bar_x = x
        bar_y = y + size_a
        bar_w = opts.length or Layout.GetAvailableWidth()
        bar_h = thickness
    end

    -- Visibility first (audit P22 / PERFORMANCE.md rule 6): a splitter
    -- scrolled out of view pays no hit-test and leaves no invisible click
    -- zone — unless its drag is already in progress.
    if not Core.IsVisible(bar_x, bar_y, bar_w, bar_h) and not Core.IsActive(drag_id) then
        return size_a
    end

    -- Interaction (clipped hit-test — audit B21)
    local hovered = Core.MouseInClippedRect(bar_x - 2, bar_y - 2, bar_w + 4, bar_h + 4)

    if hovered and Core.MouseClicked(1) then
        Core.SetActive(drag_id)
    end

    if Core.IsActive(drag_id) then
        if Core.MouseDown(1) then
            local dx, dy = Core.MouseDelta()
            local delta = (direction == "horizontal") and dx or dy
            if delta ~= 0 then
                data.ratio = data.ratio + delta / total_size
                data.ratio = max(min_a / total_size,
                    min(1 - (min_b + thickness) / total_size, data.ratio))
                size_a = floor(total_size * data.ratio)
            end
        else
            Core.ClearActive()
        end
    end

    -- Draw splitter bar
    if Core.IsVisible(bar_x, bar_y, bar_w, bar_h) then
        local color = (hovered or Core.IsActive(drag_id)) and 0.45 or 0.25
        Core.DrawRect(bar_x, bar_y, bar_w, bar_h, color, color, color, 0.5)
    end
    -- data is a reference from GetWidgetData; ratio mutation persists without SetWidgetData.
    return size_a
end

return Layout
