-- CP_Toolkit Widgets — Button, Text, Checkbox, Slider, Separator, Combo
-- Immediate-mode: call each frame, returns state

-- Localize math lib to avoid table lookup per call on hot paths.
local floor, min, max, abs, ceil = math.floor, math.min, math.max, math.abs, math.ceil
local pi, sin, cos, sqrt = math.pi, math.sin, math.cos, math.sqrt

local Widgets = {}
local Core, Layout, Theme, Log, Icons, Keys  -- set via init

-- ============================================================================
-- SHARED OFFSCREEN BUFFERS (module-level — visible to all widgets below)
-- ============================================================================

-- ColorPicker gradient buffers. Only one picker popup is open at a time,
-- so two shared global buffers suffice. Re-render only when hue or size
-- changes — a 128x128 SV gradient = ~5.5k gfx.rect calls saved per frame.
local colorpicker_gradient = {
    sv_buf_id = 902,
    hue_buf_id = 903,
    sv_hue = -1,
    sv_size = 0,
    hue_size = 0,
    hue_w = 0,
}

-- Shared text-input buffers (900 = InputText, 901 = TextEdit). Their REAL
-- dimensions are tracked here, per buffer — audit B1: the old code guarded
-- gfx.setimgdim with per-widget fields, so two fields of different sizes
-- each believed "their" buffer was current and both skipped the resize,
-- rendering into a buffer sized for the other one (permanent corruption).
local input_buf_w, input_buf_h = -1, -1        -- buffer 900
local textedit_buf_w, textedit_buf_h = -1, -1  -- buffer 901

-- UTF-8 boundary helpers (audit B13). Cursor positions are byte offsets;
-- these snap moves/deletes to codepoint boundaries so multi-byte characters
-- (é, à, …) are never split.
local function utf8_prev(text, pos)
    pos = pos - 1
    while pos > 0 do
        local b = text:byte(pos + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        pos = pos - 1
    end
    if pos < 0 then pos = 0 end
    return pos
end

local function utf8_next(text, pos)
    local len = #text
    pos = pos + 1
    while pos < len do
        local b = text:byte(pos + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        pos = pos + 1
    end
    if pos > len then pos = len end
    return pos
end

-- Encode a gfx.getchar() printable code as a UTF-8 string. Codes < 128 are
-- plain ASCII; above that gfx reports the Unicode codepoint — string.char
-- would emit an invalid Latin-1 byte (audit B13: typing "é" broke the text).
local function char_to_utf8(char)
    if char < 128 then return string.char(char) end
    return utf8.char(char)
end

-- ----------------------------------------------------------------------------
-- Word-wrap cache — shared by Tooltip and TextWrapped. Keyed by
-- (font slot, text, floor(max_w)); rebuilt only on a miss, bounded with a
-- full wipe, self-invalidates when Core reloads the font slots. Measures use
-- raw gfx.measurestr so probe strings never pollute the measure cache.
-- ----------------------------------------------------------------------------
local _wrap_cache = {}
local _wrap_cache_size = 0
local WRAP_CACHE_MAX = 500
local _wrap_font_version = -1

local function wrap_text(text, max_w)
    local fv = Core.GetFontVersion()
    if fv ~= _wrap_font_version then
        for k in pairs(_wrap_cache) do _wrap_cache[k] = nil end
        _wrap_cache_size = 0
        _wrap_font_version = fv
    end
    local slot = Core.GetCurrentFontSlot()
    local wkey = floor(max_w)
    local sc = _wrap_cache[slot]
    local pt = sc and sc[text]
    local hit = pt and pt[wkey]
    if hit then return hit end

    -- Build: explicit newlines are hard breaks, then greedy word wrap.
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        local line = nil
        for word in para:gmatch("%S+") do
            local candidate = line and (line .. " " .. word) or word
            if line and gfx.measurestr(candidate) > max_w then
                lines[#lines + 1] = line
                line = word
            else
                line = candidate
            end
        end
        lines[#lines + 1] = line or ""
    end
    -- Drop a single trailing empty line produced by the sentinel "\n"
    if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end

    local block_w = 0
    local line_h = select(2, gfx.measurestr("Mg"))
    for i = 1, #lines do
        local lw = gfx.measurestr(lines[i])
        if lw > block_w then block_w = lw end
    end
    local entry = {
        lines = lines,
        w = block_w,
        line_h = line_h,
        h = #lines * (line_h + 2) - 2,
    }

    if _wrap_cache_size >= WRAP_CACHE_MAX then
        for k in pairs(_wrap_cache) do _wrap_cache[k] = nil end
        _wrap_cache_size = 0
        sc = nil
    end
    if not sc then
        sc = _wrap_cache[slot]
        if not sc then sc = {}; _wrap_cache[slot] = sc end
    end
    pt = sc[text]
    if not pt then pt = {}; sc[text] = pt end
    pt[wkey] = entry
    _wrap_cache_size = _wrap_cache_size + 1
    return entry
end

-- Knob background (bg circle + track arc) cache. Keyed by size; re-rendered
-- if theme colors change. For a Mixer with N same-size knobs, turns
-- N × (1 circle + tw arcs) into N blits + 1 bake.
local knob_bg_cache = {}
local knob_next_buf_id = 910
local KNOB_MAX_BUF = 925

-- Knob sweep: gfx.arc angles are 0 = up, clockwise. The classic 270° knob
-- runs from -135° (bottom-LEFT) to +135° (bottom-RIGHT) through the top.
-- NEGATIVE angles are the required idiom here: expressing the same sweep
-- as 225°..495° puts the top of the dial on the 2π wrap boundary, and
-- gfx.arc renders arcs crossing that boundary as their complement (a 15%
-- excursion arc near mid-travel exploded to almost the full dial).
local KNOB_ANGLE_MIN = -pi * 0.75
local KNOB_ANGLE_MAX = pi * 0.75

local function get_knob_bg_buffer(size, bg_r, bg_g, bg_b, trk_r, trk_g, trk_b, tw)
    local entry = knob_bg_cache[size]
    if entry and entry.bg_r == bg_r and entry.bg_g == bg_g and entry.bg_b == bg_b
       and entry.trk_r == trk_r and entry.trk_g == trk_g and entry.trk_b == trk_b
       and entry.tw == tw then
        return entry.buf_id
    end
    local buf_id
    if entry then
        buf_id = entry.buf_id
    else
        if knob_next_buf_id > KNOB_MAX_BUF then return nil end
        buf_id = knob_next_buf_id
        knob_next_buf_id = knob_next_buf_id + 1
        entry = {}
        knob_bg_cache[size] = entry
    end
    local cx, cy = size / 2, size / 2
    local radius = size / 2
    local ar = radius - 3
    gfx.dest = buf_id
    -- Force a real clear (audit B9): setimgdim with unchanged dims does NOT
    -- clear the buffer and drawing a rect at alpha 0 is a no-op — re-bakes
    -- after a theme change used to blend the new colors over the old pixels
    -- (permanent ghosting). Resizing to 0×0 and back wipes the pixels.
    gfx.setimgdim(buf_id, 0, 0)
    gfx.setimgdim(buf_id, size, size)
    gfx.set(bg_r, bg_g, bg_b, 0.5)
    gfx.circle(cx, cy, radius - 1, 1, 1)
    gfx.set(trk_r, trk_g, trk_b, 0.25)
    for i = 0, tw - 1 do
        gfx.arc(cx, cy, ar - i, KNOB_ANGLE_MIN, KNOB_ANGLE_MAX, 1)
    end
    gfx.dest = -1
    entry.buf_id = buf_id
    entry.bg_r = bg_r; entry.bg_g = bg_g; entry.bg_b = bg_b
    entry.trk_r = trk_r; entry.trk_g = trk_g; entry.trk_b = trk_b
    entry.tw = tw
    return buf_id
end

-- Shared color constants — hot paths must not allocate {r,g,b,a} literals
-- per frame (PERFORMANCE.md rule 1).
local COLOR_WHITE = { 1, 1, 1, 1 }
local COLOR_ICON_HOVER = { 1, 1, 1, 0.9 }

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
-- SHARED BEVEL HELPER — Win32-style 3D edge for widget_style == "windows"
-- ============================================================================
-- mode: "raised" (buttons) — light top/left, dark bottom/right
--       "sunken" (inputs)  — dark top/left, light bottom/right
-- Draws: 1px outer border + 1px inner bevel. Requires the fill to be already drawn.
local function draw_win32_bevel(x, y, w, h, theme, mode)
    if theme.widget_style ~= "windows" then return end
    local border = theme.colors.border

    if mode == "raised" then
        -- RAISED (buttons): full outer border is OK because the button fill
        -- is close to the window bg — the contrast is low, no bracket effect.
        Core.DrawRect(x, y, w, h, border[1], border[2], border[3], border[4] or 1, false)
        -- Inner: light top/left, dark bottom/right
        Core.DrawLine(x + 1, y + 1, x + w - 2, y + 1, 1, 1, 1, 0.55)
        Core.DrawLine(x + 1, y + 1, x + 1, y + h - 2, 1, 1, 1, 0.55)
        local sh = border[1] * 0.6
        Core.DrawLine(x + 1, y + h - 2, x + w - 2, y + h - 2, sh, sh, sh, 0.4)
        Core.DrawLine(x + w - 2, y + 1, x + w - 2, y + h - 2, sh, sh, sh, 0.4)
    else
        -- SUNKEN (inputs): NO full rectangle (white fill vs gray bg creates
        -- bracket [] artifacts on left/right edges). Instead draw individual
        -- edges: dark top + left (outer shadow), light bottom + right (outer
        -- highlight), then inner bevel 1px inside.
        local dk = border[1] * 0.7
        -- Outer shadow: top + left
        Core.DrawLine(x, y, x + w - 1, y, dk, dk, dk, 0.7)            -- top
        Core.DrawLine(x, y, x, y + h - 1, dk, dk, dk, 0.5)            -- left
        -- Outer highlight: bottom + right
        Core.DrawLine(x, y + h - 1, x + w - 1, y + h - 1, 1, 1, 1, 0.25) -- bottom
        Core.DrawLine(x + w - 1, y, x + w - 1, y + h - 1, 1, 1, 1, 0.18) -- right
        -- Inner shadow: top + left (darker, 1px inside)
        Core.DrawLine(x + 1, y + 1, x + w - 2, y + 1, dk, dk, dk, 0.35)
        Core.DrawLine(x + 1, y + 1, x + 1, y + h - 2, dk, dk, dk, 0.25)
    end
end

-- ============================================================================
-- CUSTOM WINDOW CHROME (BeginWindow / EndWindow)
-- ============================================================================
-- Draws a custom title bar with drag-to-move and close button.
-- Use with frameless=true in UI.Init for full effect.
-- opts: closable (true), draggable (true), title_align ("left"|"center")
local window_chrome = { dragging = false }

function Widgets.BeginWindow(title, theme, opts)
    opts = opts or {}
    local closable = opts.closable ~= false
    local draggable = opts.draggable ~= false
    local title_align = opts.title_align or "left"

    local win_w, win_h = Core.GetWindowSize()
    local h = theme.header_height
    local closed = false

    -- Title bar background
    local tb = theme.colors.title_bar
    Core.DrawRect(0, 0, win_w, h, tb[1], tb[2], tb[3], tb[4])

    -- Bottom border line
    local ac = theme.colors.accent
    Core.DrawRect(0, h - 1, win_w, 1, ac[1], ac[2], ac[3], 0.4)

    -- Title text
    Core.SetFontPrimaryBold()
    local tw, th = Core.MeasureText(title)
    local tc = theme.colors.title_text
    local tx
    if title_align == "center" then
        tx = floor((win_w - tw) / 2)
    else
        tx = theme.window_padding
    end
    local ty = floor((h - th) / 2)
    Core.DrawText(title, tx, ty, tc[1], tc[2], tc[3], tc[4])
    Core.SetFontSecondary()  -- restore default font

    -- Settings button (before close, if requested)
    local settings_clicked = false
    if opts.on_settings then
        local sbtn_size = h
        local sbtn_x = win_w - (closable and h * 2 or h)
        local sbtn_hovered = Core.MouseInRect(sbtn_x, 0, sbtn_size, h)

        if sbtn_hovered then
            Core.DrawRect(sbtn_x, 0, sbtn_size, h, 1, 1, 1, 0.08)
        end

        if Icons then
            local ic = sbtn_hovered and COLOR_ICON_HOVER or theme.colors.title_text
            Icons.Settings(sbtn_x, 0, sbtn_size, ic[1], ic[2], ic[3], ic[4])
        end

        if sbtn_hovered and Core.MouseClicked(1) then
            settings_clicked = true
        end
    end

    -- Close button (right side)
    if closable then
        local btn_size = h
        local btn_x = win_w - btn_size
        local btn_hovered = Core.MouseInRect(btn_x, 0, btn_size, h)

        if btn_hovered then
            local hc = theme.colors.close_btn_hover
            Core.DrawRect(btn_x, 0, btn_size, h, hc[1], hc[2], hc[3], hc[4])
        end

        -- X icon
        if Icons then
            local ic = btn_hovered and COLOR_WHITE or theme.colors.title_text
            Icons.Close(btn_x, 0, btn_size, ic[1], ic[2], ic[3], ic[4])
        else
            local xc = btn_hovered and COLOR_WHITE or theme.colors.title_text
            local xw = Core.MeasureText("X")
            Core.DrawText("X", btn_x + floor((btn_size - xw) / 2), ty, xc[1], xc[2], xc[3], xc[4])
        end

        if btn_hovered and Core.MouseClicked(1) then
            closed = true
        end
    end

    -- Drag to move (on title bar area, excluding close button)
    -- Uses JS_Window_ClientToScreen for accurate screen coordinates
    if draggable and reaper.JS_Window_ClientToScreen then
        local drag_w = closable and (win_w - h) or win_w
        if opts.on_settings then drag_w = drag_w - h end
        local title_hovered = Core.MouseInRect(0, 0, drag_w, h)

        if title_hovered and Core.MouseClicked(1) then
            Core.SetActive("_window_drag")
            local hwnd = Core.GetHWND()
            if hwnd then
                -- Convert gfx mouse to screen coords (precise, no approximation)
                local smx, smy = reaper.JS_Window_ClientToScreen(hwnd, gfx.mouse_x, gfx.mouse_y)
                local ok, wl, wt = reaper.JS_Window_GetRect(hwnd)
                if ok then
                    window_chrome.start_smx = smx
                    window_chrome.start_smy = smy
                    window_chrome.start_wx = wl
                    window_chrome.start_wy = wt
                end
            end
        end

        if Core.IsActive("_window_drag") then
            if Core.MouseDown(1) then
                local hwnd = Core.GetHWND()
                if hwnd and window_chrome.start_smx then
                    local smx, smy = reaper.JS_Window_ClientToScreen(hwnd, gfx.mouse_x, gfx.mouse_y)
                    local new_x = window_chrome.start_wx + (smx - window_chrome.start_smx)
                    local new_y = window_chrome.start_wy + (smy - window_chrome.start_smy)
                    reaper.JS_Window_Move(hwnd, new_x, new_y)
                end
            else
                Core.ClearActive()
                window_chrome.start_smx = nil
            end
        end
    end

    -- Offset the layout container to start below the title bar
    local c = Core.CurrentContainer()
    if c and c.cursor_y < h then
        c.cursor_y = h + theme.window_padding
        c.pad_y = h + theme.window_padding
    end

    return closed, settings_clicked
end

function Widgets.EndWindow()
    -- Nothing to clean up (the container is managed by Layout.Begin/End)
end

-- ============================================================================
-- PANEL — Windows-style content container (filled / groupbox / inset)
-- ============================================================================
-- Wraps content in a visual sub-region with bg/border/title. Auto-fits to
-- the content height: BeginPanel draws the bg with the maximum available
-- height, the content draws on top, EndPanel measures the actual content
-- height and erases the excess with the parent's bg color.
--
-- Three styles (opts.style):
--   "filled"   — solid bg + 1px border + optional title (default)
--   "groupbox" — no fill, 1px border with the title text inset on the top edge
--   "inset"    — sunken look (light bottom/right edge, dark top/left edge)
--                like a Win32 read-only display surface
-- ============================================================================
function Widgets.BeginPanel(id, theme, opts)
    opts = opts or {}
    local parent = Core.CurrentContainer()
    if not parent then return end

    local style = opts.style or "filled"
    -- Asymmetric padding by default: horizontal stays generous for breathing
    -- room, vertical is tight (matches the Win32 GroupBox feel — no wasted
    -- space above/below the content). Caller can override with opts.padding
    -- (symmetric) or opts.padding_x / opts.padding_y (per-axis).
    local pad_x = opts.padding_x or opts.padding or theme.frame_padding_x
    local pad_y = opts.padding_y or opts.padding or theme.frame_padding_y
    local title = opts.title

    -- Position relative to parent cursor (mirror both scroll axes)
    local abs_x = parent.x + parent.cursor_x - (parent.scrollable_x and parent.scroll_x or 0)
    local abs_y = parent.y + parent.cursor_y - (parent.scrollable   and parent.scroll_y   or 0)

    -- Auto-width: fill remaining width unless explicit
    local w = opts.width
    if not w or w <= 0 then
        w = parent.w - parent.cursor_x - parent.pad_x
    end

    -- Max possible height (used to draw the bg before content height is known)
    local max_h = parent.h - parent.cursor_y - parent.pad_y
    if max_h < 1 then max_h = 1 end

    -- Resolve background color
    local bg
    if type(opts.bg) == "table" then
        bg = opts.bg
    elseif opts.bg == "window" then
        bg = theme.colors.window_bg
    else
        bg = theme.colors.frame_bg
    end

    -- Title text width (for groupbox border break)
    local title_w, title_h = 0, 0
    if title and title ~= "" then
        title_w, title_h = Core.MeasureText(title)
    end

    -- Persistent panel data: pooled container table + cached id string +
    -- last frame's measured height (audit P7/P8 — this widget used to
    -- allocate a ~30-field table + one string concat per panel per frame,
    -- AND fill the whole remaining parent height only to erase the excess
    -- in EndPanel: up to 2-3× full-window fillrate on stacked panels).
    local pd = Core.GetWidgetSubData("panel", id)
    if not pd.cid then
        pd.cid = "panel_" .. id
        pd.c = {}
    end

    -- ---- Draw the bg at last frame's real height ----
    -- First frame (or after growth) falls back to max_h; EndPanel stores the
    -- measured height and requests a redraw when the content grew, so the
    -- bg is correct again on the next frame.
    local drawn_h = pd.last_h or max_h
    if drawn_h > max_h then drawn_h = max_h end
    if drawn_h < 1 then drawn_h = 1 end
    if style == "filled" or style == "inset" then
        Core.DrawRect(abs_x, abs_y, w, drawn_h, bg[1], bg[2], bg[3], bg[4] or 1)
    end
    -- "groupbox" has no fill — content sits on parent bg with a labeled border

    -- Reserve room for the title in the content area:
    --   filled  → title is rendered INSIDE the panel, content starts below
    --   groupbox → title overlaps the top border, content starts below border
    local title_offset = 0
    if title and title ~= "" then
        if style == "filled" then
            title_offset = title_h + 4
        elseif style == "groupbox" then
            title_offset = floor(title_h / 2) + 2
        end
    end

    -- Push a pooled child container scoped to the panel area. Wipe-then-fill
    -- keeps the table identity stable (zero allocation) while guaranteeing no
    -- stale field survives from the previous frame.
    local c = pd.c
    for k in pairs(c) do c[k] = nil end
    c.id            = pd.cid
    c.x             = abs_x
    c.y             = abs_y
    c.w             = w
    c.h             = max_h
    c.pad_x         = pad_x
    c.pad_y         = pad_y
    c.cursor_x      = pad_x
    c.cursor_y      = pad_y + title_offset
    c.content_h     = 0
    c.spacing       = theme.item_spacing  -- use theme's own spacing, not parent's
    c.max_row_h     = 0
    c.same_line     = false
    c.same_line_x   = 0
    c.sameline_pending = false
    c.indent_x      = 0
    c.last_widget_end_x = pad_x
    c.last_widget_y     = pad_y + title_offset
    c.last_widget_h     = 0
    c.scrollable    = false
    c.scroll_y      = 0
    -- Stash for EndPanel
    c._is_panel     = true
    c._panel_style  = style
    c._panel_bg     = bg
    c._panel_title  = title
    c._panel_title_w = title_w
    c._panel_title_h = title_h
    c._panel_max_h  = max_h
    c._panel_drawn_h = drawn_h
    c._panel_parent_bg = parent._panel_bg or theme.colors.window_bg
    c._panel_pd     = pd

    Core.PushContainer(c)
    Core.PushClipRect(abs_x, abs_y, w, max_h)
end

function Widgets.EndPanel(theme)
    local c = Core.CurrentContainer()
    if not c or not c._is_panel then
        Core.PopClipRect()
        Core.PopContainer()
        return
    end

    -- Compute actual content end (relative to panel top).
    -- After _AdvanceCursor, cursor_y already points BELOW the last widget
    -- (it includes widget_h + item_spacing). So we just subtract the trailing
    -- spacing — except when a SameLine row is still pending, in which case
    -- cursor_y is back on the row's top and we add max_row_h.
    local content_end_y
    if c.sameline_pending then
        content_end_y = c.cursor_y + c.max_row_h
    else
        content_end_y = c.cursor_y - (c.spacing or 0)
    end
    if content_end_y < c.pad_y then content_end_y = c.pad_y end

    local actual_h = content_end_y + c.pad_y

    Core.PopClipRect()
    Core.PopContainer()

    local x = c.x
    local y = c.y
    local w = c.w
    local style = c._panel_style
    local title = c._panel_title

    -- ---- Reconcile drawn bg height with the real content height ----
    -- Shrunk: erase only the strip between the new and the previously drawn
    -- height (opaque — blending with a translucent bg does not erase).
    -- Grew: the bg under the new strip is missing for this one frame; store
    -- the height and request a redraw so the next frame paints it correctly.
    local pd = c._panel_pd
    if style == "filled" or style == "inset" then
        local drawn_h = c._panel_drawn_h or c._panel_max_h
        if actual_h < drawn_h then
            local pbg = c._panel_parent_bg
            Core.DrawRect(x, y + actual_h, w, drawn_h - actual_h,
                pbg[1], pbg[2], pbg[3], 1)
        elseif actual_h > drawn_h then
            Core.RequestRedraw()
        end
    end
    if pd then pd.last_h = actual_h end

    -- ---- Draw title (must come AFTER bg, BEFORE border for filled style) ----
    if title and title ~= "" then
        local tc = theme.colors.text
        if style == "filled" then
            -- Inside the panel, top-left, with the same x padding as content
            Core.DrawText(title, x + c.pad_x, y + c.pad_y - 2, tc[1], tc[2], tc[3], tc[4] or 1)
        end
        -- groupbox title is drawn during border drawing below
    end

    -- ---- Draw border ----
    if style == "filled" then
        local bc = theme.colors.border
        Core.DrawRect(x, y, w, actual_h, bc[1], bc[2], bc[3], bc[4] or 1, false)

    elseif style == "groupbox" then
        local bc = theme.colors.border
        local title_y = y + floor(c._panel_title_h / 2)
        if title and title ~= "" then
            -- Top border with a gap for the title
            local gap_x1 = x + 6
            local gap_x2 = gap_x1 + c._panel_title_w + 6
            Core.DrawLine(x, title_y, gap_x1, title_y, bc[1], bc[2], bc[3], bc[4] or 1)
            Core.DrawLine(gap_x2, title_y, x + w, title_y, bc[1], bc[2], bc[3], bc[4] or 1)
            -- Title text in the gap
            local tc = theme.colors.text
            Core.DrawText(title, gap_x1 + 3, y, tc[1], tc[2], tc[3], tc[4] or 1)
        else
            Core.DrawLine(x, title_y, x + w, title_y, bc[1], bc[2], bc[3], bc[4] or 1)
        end
        -- Side and bottom borders
        Core.DrawLine(x, title_y, x, y + actual_h, bc[1], bc[2], bc[3], bc[4] or 1)
        Core.DrawLine(x + w - 1, title_y, x + w - 1, y + actual_h, bc[1], bc[2], bc[3], bc[4] or 1)
        Core.DrawLine(x, y + actual_h - 1, x + w, y + actual_h - 1, bc[1], bc[2], bc[3], bc[4] or 1)

    elseif style == "inset" then
        -- Sunken look: dark top/left edge, light bottom/right edge
        local dark  = theme.colors.border
        local light = theme.colors.frame_hovered or { 1, 1, 1, 0.6 }
        -- Top
        Core.DrawLine(x, y, x + w - 1, y, dark[1], dark[2], dark[3], (dark[4] or 1) * 0.9)
        -- Left
        Core.DrawLine(x, y, x, y + actual_h - 1, dark[1], dark[2], dark[3], (dark[4] or 1) * 0.9)
        -- Bottom
        Core.DrawLine(x, y + actual_h - 1, x + w - 1, y + actual_h - 1,
            light[1], light[2], light[3], (light[4] or 1) * 0.6)
        -- Right
        Core.DrawLine(x + w - 1, y, x + w - 1, y + actual_h - 1,
            light[1], light[2], light[3], (light[4] or 1) * 0.6)
    end

    -- Advance parent cursor past the panel (use AdvanceCursor so item_spacing
    -- is added like any other widget — but pad_y is already inside actual_h)
    local parent = Core.CurrentContainer()
    if parent then
        Layout._AdvanceCursor(parent, w, actual_h)
    end
end

-- ============================================================================
-- TEXT
-- ============================================================================
function Widgets.Text(text, theme, opts)
    opts = opts or {}
    local color = opts.color or theme.colors.text
    local disabled = opts.disabled or Core.IsDisabled()

    if disabled then color = theme.colors.text_disabled end

    if opts.font_size then
        Core.SetFont(opts.font_size, theme.fonts.default_face)
    end

    -- Truncation (opt-out via opts.truncate=false). Default behavior keeps
    -- text inside the current container's remaining width — long paths/status
    -- strings can't spill past the window padding. opts.max_width for a
    -- specific cap instead of auto.
    if opts.max_width then
        text = Core.TruncateText(text, opts.max_width)
    elseif opts.truncate ~= false then
        text = Core.TruncateText(text, Layout.GetAvailableWidth())
    end

    local tw, th = Core.MeasureText(text)

    -- Use aligned position (centers vertically on SameLine rows)
    local x, y = Layout.GetCursorPosAligned(th)

    if Core.IsVisible(x, y, tw, th) then
        Core.DrawText(text, x, y, color[1], color[2], color[3], color[4] or 1)
    end

    -- Restore default font via the preloaded body slot (audit B5b: restoring
    -- through Core.SetFont redefined the legacy slot with alternating params
    -- every frame, thrashing its measure cache).
    if opts.font_size then
        Core.SetFontBody()
    end

    Layout.AdvanceCursor(tw, th)
end

-- Word-wrapped multi-line text (F9). The wrap layout is cached per
-- (font, text, width) — see wrap_text — so steady-state cost is N DrawText
-- calls, zero measurement.
-- opts: {color = {r,g,b,a}, max_width = px (default: available width)}
function Widgets.TextWrapped(text, theme, opts)
    opts = opts or {}
    local color = opts.color or theme.colors.text
    if opts.disabled or Core.IsDisabled() then color = theme.colors.text_disabled end
    local max_w = opts.max_width or Layout.GetAvailableWidth()
    if max_w <= 0 then max_w = 1 end

    local wrapped = wrap_text(text, max_w)
    local x, y = Layout.GetCursorPos()

    if Core.IsVisible(x, y, wrapped.w, wrapped.h) then
        local lines = wrapped.lines
        local ly = y
        for i = 1, #lines do
            Core.DrawText(lines[i], x, ly, color[1], color[2], color[3], color[4] or 1)
            ly = ly + wrapped.line_h + 2
        end
    end

    Layout.AdvanceCursor(wrapped.w, wrapped.h)
end

function Widgets.TextColored(text, r, g, b, a, _theme)
    -- Auto-truncate to remaining row width so colored text can't overflow
    -- past window padding either.
    text = Core.TruncateText(text, Layout.GetAvailableWidth())
    local tw, th = Core.MeasureText(text)
    local x, y = Layout.GetCursorPosAligned(th)
    if Core.IsVisible(x, y, tw, th) then
        Core.DrawText(text, x, y, r, g, b, a or 1)
    end
    Layout.AdvanceCursor(tw, th)
end

function Widgets.Header(text, theme)
    Core.SetFont(theme.fonts.header_size, theme.fonts.default_face, 66) -- 'B' = bold
    Widgets.Text(text, theme)
    Core.SetFontBody()  -- restore via preloaded slot (see Text)
end

-- ============================================================================
-- BUTTON
-- ============================================================================
function Widgets.Button(id, label, theme, opts)
    opts = opts or {}
    local fp_x = theme.frame_padding_x

    local tw, th = Core.MeasureText(label)
    local w = opts.width or (tw + fp_x * 2)
    -- width = -1 → fill the available width of the parent container/column
    -- (matches the ImGui idiom). Resolved here so callers don't have to
    -- query Layout.GetAvailableWidth() everywhere.
    if w == -1 then w = Layout.GetAvailableWidth() end
    local h = opts.height or theme.button_height

    -- Pre-check wrap before getting position
    if Layout.IsWrapping() then Layout.WrapPreCheck(w) end

    local x, y = Layout.GetCursorPos()

    local clicked = false
    local disabled = opts.disabled or Core.IsDisabled()
    local hovered = (not disabled)
        and Core.MouseInClippedRect(x, y, w, h)
        and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        if Core.MouseClicked(1) then
            Core.SetActive(id)
            -- %.0f, not %d: layout coordinates are floats (fractional
            -- column widths) and %d errors on them in Lua 5.3.
            if Log then Log.WidgetClicked(id, "Button", string.format("pos=(%.0f,%.0f) size=(%.0f,%.0f)", x, y, w, h)) end
        end
    end

    if Core.IsActive(id) and Core.MouseReleased(1) then
        if hovered then clicked = true end
        Core.ClearActive()
    end

    -- Colors — opts.selected forces the "active" look to mark the current
    -- choice in button-group selectors (e.g., algorithm list).
    local bg
    if Core.IsActive(id) and hovered then
        bg = theme.colors.button_active
    elseif hovered then
        bg = theme.colors.button_hovered
    elseif opts.selected then
        bg = theme.colors.button_active
    else
        bg = theme.colors.button
    end

    -- Draw
    if Core.IsVisible(x, y, w, h) then
        local alpha_mul = disabled and 0.5 or 1.0
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], (bg[4] or 1) * alpha_mul)

        -- Windows-style 3D bevel (raised for buttons, sunken when pressed or selected)
        local pressed = (Core.IsActive(id) and hovered) or opts.selected
        if not disabled then
            draw_win32_bevel(x, y, w, h, theme, pressed and "sunken" or "raised")
        end

        -- Truncate the label if it doesn't fit the button width (reserving
        -- frame padding on both sides). Standard pattern used by toolbars
        -- and menus: keep the button width, shorten the text with "..".
        local text_budget = w - fp_x * 2
        local draw_label, draw_tw = label, tw
        if tw > text_budget then
            draw_label, draw_tw = Core.TruncateText(label, text_budget)
        end

        -- Center text (offset by 1px when pressed for the "click" feeling)
        local press_offset = 0
        if theme.widget_style == "windows" and pressed and not disabled then
            press_offset = 1
        end
        local tx = x + floor((w - draw_tw) / 2) + press_offset
        local ty = y + floor((h - th) / 2) + press_offset
        local tc = disabled and theme.colors.text_disabled or theme.colors.text
        Core.DrawText(draw_label, tx, ty, tc[1], tc[2], tc[3], (tc[4] or 1) * alpha_mul)
    end

    Layout.AdvanceCursor(w, h)
    return clicked
end

-- ============================================================================
-- CHECKBOX
-- ============================================================================
function Widgets.Checkbox(id, label, checked, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    -- opts.size lets the caller align the box on a taller row (e.g. matching
    -- a sibling button's height). Defaults to theme.checkbox_size.
    local size = opts.size or theme.checkbox_size
    -- Truncate label so the widget (box + gap + label) never overflows the
    -- container's remaining width. Label-less widgets are untouched.
    local avail_w = Layout.GetAvailableWidth()
    local tw, th = Core.MeasureText(label)
    local max_label_w = max(0, avail_w - size - 6)
    if tw > max_label_w then
        label, tw = Core.TruncateText(label, max_label_w)
    end
    local total_w = size + 6 + tw
    local h = max(size, th)

    local toggled = false
    local disabled = opts.disabled or Core.IsDisabled()
    local hovered = (not disabled)
        and Core.MouseInClippedRect(x, y, total_w, h)
        and not Core.HasPopup()

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
        local box_y = y + floor((h - size) / 2)
        local bg = hovered and theme.colors.frame_hovered or theme.colors.frame_bg
        Core.DrawRect(x, box_y, size, size, bg[1], bg[2], bg[3], bg[4])

        draw_win32_bevel(x, box_y, size, size, theme, "sunken")

        -- Filled square (accent color)
        if new_checked then
            local ac = theme.colors.accent
            local dim = disabled and 0.5 or 1
            if theme.widget_style == "windows" then
                -- Asymmetric: 2px bevel top/left vs 1px bottom/right → shift fill 1px toward bottom-right
                Core.DrawRect(x + 3, box_y + 3, size - 5, size - 5, ac[1], ac[2], ac[3], (ac[4] or 1) * dim)
            else
                local m = 3
                Core.DrawRect(x + m, box_y + m, size - m * 2, size - m * 2, ac[1], ac[2], ac[3], (ac[4] or 1) * dim)
            end
        end

        -- Label
        local tc = disabled and theme.colors.text_disabled or theme.colors.text
        local lx = x + size + 6
        local ly = y + floor((h - th) / 2)
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

    -- width = -1 → fill (alias for nil). Sliders always default to fill.
    local fixed_w = opts.width
    if fixed_w == -1 then fixed_w = nil end

    -- Truncate label first so the widget (label + gap + control) can never
    -- overflow the container. Reserved control width = opts.width if set,
    -- else 40px (min usable slider track).
    local tw, th = Core.MeasureText(label)
    local has_label = label and label ~= ""
    local label_gap = has_label and 8 or 0
    local reserved_w = fixed_w or 40
    local max_label_w = max(0, avail_w - reserved_w - label_gap)
    if tw > max_label_w then
        label, tw = Core.TruncateText(label, max_label_w)
    end
    local slider_w = fixed_w or max(20, avail_w - tw - label_gap)
    local h = opts.height or theme.slider_height
    local total_w = slider_w + (has_label and (tw + label_gap) or 0)

    local changed = false
    local new_value = value
    local disabled = opts.disabled or Core.IsDisabled()
    local sd = Core.GetWidgetSubData("slider", id)

    -- Slider track area (no leading gap when there's no label).
    local sx = x + (has_label and (tw + label_gap) or 0)
    local sy = y + floor((max(h, th) - h) / 2)

    local hovered = (not disabled)
        and Core.MouseInClippedRect(sx, sy, slider_w, h)
        and not Core.HasPopup()

    -- Inline value entry (F5, ImGui idiom): Ctrl+click or double-click on the
    -- track types an exact value. Enter commits (clamped), Esc cancels,
    -- losing focus cancels. Reuses the NumberInput interaction model.
    if hovered and not sd.editing
       and ((Core.ModCtrl() and Core.MouseClicked(1)) or Core.MouseDoubleClicked()) then
        sd.editing = true
        sd.edit_buf = is_int and tostring(floor(value + 0.5))
                              or string.format("%.3f", value)
        sd.blink_time = reaper.time_precise()
        Core.SetFocus(id)
        Core.ClearActive()  -- a double-click's first click may have started a drag
    end

    if sd.editing then
        if not Core.IsFocused(id) then
            -- Focus stolen (click elsewhere, Tab) → cancel silently
            sd.editing = false
        elseif Keys then
            local char = Core.GetChar()
            if char == Keys.ENTER or char == Keys.TAB then
                local num = tonumber(sd.edit_buf)
                if num then
                    if is_int then num = floor(num + 0.5) end
                    new_value = max(min_val, min(max_val, num))
                    if new_value ~= value then changed = true end
                end
                sd.editing = false
                Core.SetFocus(nil)
                Core.ConsumeChar()
            elseif char == Keys.ESCAPE then
                sd.editing = false
                Core.SetFocus(nil)
                Core.ConsumeChar()
            elseif char == Keys.BACKSPACE then
                if #sd.edit_buf > 0 then
                    sd.edit_buf = sd.edit_buf:sub(1, -2)
                    sd.blink_time = reaper.time_precise()
                end
                Core.ConsumeChar()
            elseif char > 31 and char < 256 then
                local c = string.char(char)
                if c:match("[0-9%.%-]") then
                    sd.edit_buf = sd.edit_buf .. c
                    sd.blink_time = reaper.time_precise()
                end
                Core.ConsumeChar()
            end
            -- Keep the idle loop waking exactly at the next caret-blink edge
            if sd.editing then Core.ScheduleBlinkRedraw(sd.blink_time) end
        end
    end

    if hovered and not sd.editing then
        Core.SetHot(id)
        if Core.MouseClicked(1) and not Core.ModCtrl() then
            Core.SetActive(id)
            if Log then Log.WidgetClicked(id, "Slider", string.format("val=%s range=[%s,%s]", tostring(value), tostring(min_val), tostring(max_val))) end
        end
    end

    if Core.IsActive(id) and not sd.editing then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local ratio = max(0, min(1, (mx - sx) / slider_w))
            new_value = min_val + ratio * (max_val - min_val)
            if is_int then new_value = floor(new_value + 0.5) end
            if new_value ~= value then changed = true end
        else
            Core.ClearActive()
            if Log and changed then Log.WidgetChanged(id, "Slider", tostring(value), tostring(new_value)) end
        end
    end

    -- Draw
    if Core.IsVisible(x, y, total_w, max(h, th)) then
        -- Label
        local tc = disabled and theme.colors.text_disabled or theme.colors.text
        local ly = y + floor((max(h, th) - th) / 2)
        Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])

        if sd.editing then
            -- Inline edit box over the track area
            local fb = theme.colors.frame_active or theme.colors.frame_bg
            Core.DrawRect(sx, sy, slider_w, h, fb[1], fb[2], fb[3], fb[4])
            draw_win32_bevel(sx, sy, slider_w, h, theme, "sunken")
            local ac = theme.colors.accent
            Core.DrawRect(sx, sy, slider_w, h, ac[1], ac[2], ac[3], ac[4] or 1, false)
            local bw, bh = Core.MeasureText(sd.edit_buf)
            local bx = sx + floor((slider_w - bw) / 2)
            local by = sy + floor((h - bh) / 2)
            Core.DrawText(sd.edit_buf, bx, by, tc[1], tc[2], tc[3], tc[4])
            -- Caret
            local elapsed = reaper.time_precise() - sd.blink_time
            if (elapsed % Core.BLINK_PERIOD) < Core.BLINK_ON then
                Core.DrawRect(bx + bw + 1, by, 1, bh, tc[1], tc[2], tc[3], tc[4])
            end
        else
            -- Track
            local track_bg = hovered and theme.colors.frame_hovered or theme.colors.frame_bg
            Core.DrawRect(sx, sy, slider_w, h, track_bg[1], track_bg[2], track_bg[3], track_bg[4])
            draw_win32_bevel(sx, sy, slider_w, h, theme, "sunken")

            -- Filled portion (inset in windows mode so it doesn't overpaint bevel)
            -- Asymmetric: 2px bevel top/left, 1px bottom/right → top inset 2, bottom inset 1
            local s_top = (theme.widget_style == "windows") and 2 or 0
            local s_bot = (theme.widget_style == "windows") and 1 or 0
            local display_val = changed and new_value or value
            local ratio = (display_val - min_val) / (max_val - min_val)
            ratio = max(0, min(1, ratio))
            local fill_w = floor((slider_w - s_top - s_bot) * ratio)
            local ac = theme.colors.accent
            local dim = disabled and 0.5 or 1
            if fill_w > 0 then
                Core.DrawRect(sx + s_top, sy + s_top, fill_w, h - s_top - s_bot,
                    ac[1], ac[2], ac[3], (ac[4] or 1) * dim)
            end

            -- Grab handle
            local grab_w = 8
            local grab_x = sx + fill_w - floor(grab_w / 2)
            grab_x = max(sx, min(sx + slider_w - grab_w, grab_x))
            local grab_c = Core.IsActive(id) and theme.colors.accent_active or
                            (hovered and theme.colors.accent_hovered or theme.colors.accent)
            Core.DrawRect(grab_x, sy, grab_w, h, grab_c[1], grab_c[2], grab_c[3], (grab_c[4] or 1) * dim)
            draw_win32_bevel(grab_x, sy, grab_w, h, theme, Core.IsActive(id) and "sunken" or "raised")

            -- Value text (on top of slider) — formatted string is cached in
            -- widget_data so we only re-format when display_val actually changes.
            -- opts.format is a printf-style template ("%d Hz", "%.1f dB", ...).
            -- A plain string with no % directive is used verbatim (lookup labels).
            local val_str
            local fmt = opts.format
            if sd.fv_val == display_val and sd.fv_fmt == fmt and sd.fv_str then
                val_str = sd.fv_str
            else
                if fmt then
                    if fmt:find("%%[%-+ 0#]*%d*%.?%d*[dixXoufgGeEcs]") then
                        val_str = string.format(fmt, is_int and floor(display_val) or display_val)
                    else
                        val_str = fmt
                    end
                elseif is_int then
                    val_str = tostring(floor(display_val))
                else
                    val_str = string.format("%.2f", display_val)
                end
                sd.fv_val = display_val
                sd.fv_fmt = fmt
                sd.fv_str = val_str
            end
            local vw, vh = Core.MeasureText(val_str)
            local vx = sx + floor((slider_w - vw) / 2)
            local vy = sy + floor((h - vh) / 2)
            Core.DrawText(val_str, vx, vy, tc[1], tc[2], tc[3], tc[4])
        end
    end

    Layout.AdvanceCursor(total_w, max(h, th))
    return changed, is_int and floor(new_value + 0.5) or new_value
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

    -- Width handling. Default behavior = fill the remaining width after the
    -- label. `opts.width = -1` is an explicit alias for "fill". A positive
    -- number = fixed width.
    local fixed_w = opts.width
    if fixed_w == -1 then fixed_w = nil end

    -- Empty label → no gap reserved
    local tw, th = Core.MeasureText(label)
    local has_label = label and label ~= ""
    local label_gap = has_label and 8 or 0

    -- Truncate label if combo would otherwise overflow.
    local reserved_w = fixed_w or 50
    local max_label_w = max(0, avail_w - reserved_w - label_gap)
    if tw > max_label_w then
        label, tw = Core.TruncateText(label, max_label_w)
    end
    -- Combo fills the remaining width by default. Total widget width never
    -- exceeds avail_w (so it lines up edge-to-edge with neighbouring fill
    -- widgets like Button(width=-1)).
    local combo_w = fixed_w or max(20, avail_w - tw - label_gap)
    local h = opts.height or theme.combo_height
    local total_w = combo_w + (has_label and (tw + label_gap) or 0)

    -- Check for pending selection from popup (set on previous frame)
    local data = Core.GetWidgetSubData("combo", id)
    local selected = current_index
    local changed = false
    if data.pending ~= nil then
        selected = data.pending
        changed = true
        data.pending = nil
        -- (data is already a reference to the stored table; mutation persists)
    end

    -- Combo button area (no leading offset when label is empty)
    local cx = x + (has_label and (tw + label_gap) or 0)
    local cy = y

    -- Block when ANY popup is open (prevents click-through)
    local disabled = opts.disabled or Core.IsDisabled()
    local hovered = (not disabled)
        and Core.MouseInClippedRect(cx, cy, combo_w, h)
        and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
    end

    -- Toggle popup on click
    if hovered and Core.MouseClicked(1) then
        if Log then Log.Popup("Combo opening: " .. id, string.format("pos=(%.0f,%.0f) items=%d", cx, cy, #items)) end
        -- Open popup
        local popup_items = items
        local popup_x = cx
        local popup_y = cy + h + 1
        local popup_w = combo_w
        local item_h = h
        local popup_h = #items * item_h
        local popup_current = current_index

        -- Clamp popup to window
        local _, win_h = Core.GetWindowSize()
        if popup_y + popup_h > win_h - 4 then
            popup_h = min(popup_h, win_h - popup_y - 4)
        end

        -- Scroll + keyboard nav state (audit B11/F2: items past the window
        -- clamp used to be plain unreachable, and the popup was mouse-only).
        local visible_count = max(1, floor(popup_h / item_h))
        data.nav = current_index
        -- Start scrolled so the current selection is visible (centered-ish)
        data.scroll = max(0, min(#items - visible_count,
                                 current_index - 1 - floor(visible_count / 2)))

        Core.SetPopup(id, function()
            -- Skip close logic on the same frame popup was opened
            local is_new = Core.IsPopupNewThisFrame()
            local count = #popup_items
            local max_scroll = max(0, count - visible_count)

            -- Keyboard navigation: Up/Down move, Enter selects, Esc closes.
            if Keys then
                local char = Core.GetChar()
                if char == Keys.UP or char == Keys.DOWN then
                    local nav = data.nav or popup_current
                    nav = nav + (char == Keys.DOWN and 1 or -1)
                    data.nav = max(1, min(count, nav))
                    -- Keep the highlighted item in view
                    if data.nav - 1 < data.scroll then
                        data.scroll = data.nav - 1
                    elseif data.nav > data.scroll + visible_count then
                        data.scroll = data.nav - visible_count
                    end
                    Core.ConsumeChar()
                elseif char == Keys.ENTER then
                    data.pending = data.nav or popup_current
                    Core.ClearPopup(id)
                    Core.ConsumeChar()
                    return
                elseif char == Keys.ESCAPE then
                    Core.ClearPopup(id)
                    Core.ConsumeChar()
                    return
                end
            end

            -- Wheel scroll inside the popup
            local wheel = Core.GetState().mouse_wheel
            if wheel ~= 0 and not Core.IsWheelConsumed()
               and Core.MouseInRect(popup_x, popup_y, popup_w, popup_h) then
                local dir = wheel > 0 and -1 or 1
                data.scroll = max(0, min(max_scroll, data.scroll + dir))
                Core.ConsumeWheel()
            end
            local scroll = max(0, min(max_scroll, data.scroll or 0))
            data.scroll = scroll

            -- Background
            local pbg = theme.colors.popup_bg
            Core.DrawRect(popup_x, popup_y, popup_w, popup_h, pbg[1], pbg[2], pbg[3], pbg[4])

            -- Border
            local pbc = theme.colors.border
            Core.DrawRect(popup_x, popup_y, popup_w, popup_h, pbc[1], pbc[2], pbc[3], pbc[4], false)

            -- Items (windowed: only the visible rows are laid out and drawn)
            for vis = 1, min(count, visible_count) do
                local i = vis + scroll
                local iy = popup_y + (vis - 1) * item_h
                local item_hovered = Core.MouseInRect(popup_x, iy, popup_w, item_h)

                if item_hovered or i == data.nav then
                    local hc = theme.colors.header_hovered
                    Core.DrawRect(popup_x + 1, iy, popup_w - 2, item_h, hc[1], hc[2], hc[3], hc[4])
                end

                if i == popup_current then
                    local ac = theme.colors.accent
                    Core.DrawRect(popup_x + 1, iy, 3, item_h, ac[1], ac[2], ac[3], ac[4])
                end

                local tc = theme.colors.text
                local item_text = popup_items[i]
                -- Vertical centering uses the item text's own height, NOT
                -- the label's th (which is 0 when the combo has no label).
                local item_tw, item_th = Core.MeasureText(item_text)
                local text_y = iy + floor((item_h - item_th) / 2)
                local item_tx = popup_x + floor((popup_w - item_tw) / 2)
                if item_tx < popup_x + 6 then item_tx = popup_x + 6 end
                Core.DrawText(item_text, item_tx, text_y, tc[1], tc[2], tc[3], tc[4])

                -- Select item on click (not on the open frame)
                if not is_new and item_hovered and Core.MouseClicked(1) then
                    if Log then Log.WidgetChanged(id, "Combo", tostring(popup_current), tostring(i) .. "=" .. popup_items[i]) end
                    -- Store selection in widget_data (read next frame by Combo)
                    data.pending = i
                    Core.ClearPopup(id)
                    return  -- stop processing popup this frame
                end
            end

            -- Thin scrollbar when the list overflows
            if max_scroll > 0 then
                local sb_w = max(3, floor(theme.scrollbar_width / 2))
                local sb_x = popup_x + popup_w - sb_w - 1
                local track_h = popup_h - 2
                local thumb_h = max(8, floor(track_h * visible_count / count))
                local thumb_y = popup_y + 1
                    + floor((track_h - thumb_h) * (scroll / max_scroll))
                local sg = theme.colors.scrollbar_grab
                Core.DrawRect(sb_x, thumb_y, sb_w, thumb_h, sg[1], sg[2], sg[3], sg[4] or 1)
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
        local tc = theme.colors.text

        -- Label baseline (only meaningful if a label is present)
        if has_label then
            local ly = y + floor((h - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        -- Button background
        local bg = (hovered and not Core.HasPopup()) and theme.colors.frame_hovered or theme.colors.frame_bg
        Core.DrawRect(cx, cy, combo_w, h, bg[1], bg[2], bg[3], bg[4])

        draw_win32_bevel(cx, cy, combo_w, h, theme, "sunken")

        -- Current value text — centered inside the combo button (the arrow
        -- on the right takes h pixels, so the text region is combo_w - h).
        -- Vertical centering uses the value text's own height, NOT the
        -- (possibly empty) label's height.
        local display_idx = changed and selected or current_index
        local val_text = items[display_idx] or ""
        local vw, vh = Core.MeasureText(val_text)
        local text_region = max(8, combo_w - h)
        local text_x = cx + floor((text_region - vw) / 2)
        if text_x < cx + 4 then text_x = cx + 4 end  -- min left padding
        local val_ly = cy + floor((h - vh) / 2)
        Core.DrawText(val_text, text_x, val_ly, tc[1], tc[2], tc[3], tc[4])

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
            -- Audit B15: this fallback used to read `ly`, a local scoped to
            -- the has_label branch above (nil without a label → Lua error).
            local arrow = Core.HasPopup(id) and "^" or "v"
            local aw, ah = Core.MeasureText(arrow)
            local arrow_y = cy + floor((h - ah) / 2)
            Core.DrawText(arrow, cx + combo_w - aw - 6, arrow_y, tc[1], tc[2], tc[3], 0.6)
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
    local disabled = opts.disabled or Core.IsDisabled()
    for i, tab_label in ipairs(tabs) do
        local tw, th = Core.MeasureText(tab_label)
        local tab_w = tw + theme.frame_padding_x * 2
        local is_active = (i == active_tab)
        local hovered = (not disabled)
            and Core.MouseInClippedRect(tab_x, y, tab_w, h)
            and not Core.HasPopup()

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

            if theme.widget_style == "windows" then
                -- Windows-style: active tab = raised, inactive = flat
                if is_active then
                    draw_win32_bevel(tab_x, y, tab_w, h, theme, "raised")
                else
                    -- Subtle border on inactive tabs
                    local bc = theme.colors.border
                    Core.DrawRect(tab_x, y, tab_w, h, bc[1], bc[2], bc[3], 0.3, false)
                end
            else
                -- Flat: accent underline for active
                if is_active then
                    local ac = theme.colors.accent
                    Core.DrawRect(tab_x, y + h - 2, tab_w, 2, ac[1], ac[2], ac[3], ac[4])
                end
            end

            -- Text
            local tc = theme.colors.text
            local tx = tab_x + floor((tab_w - tw) / 2)
            local ty = y + floor((h - th) / 2)
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
    local h = theme.combo_height
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
        local ty = y + floor((h - th) / 2)
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
-- Tooltip draw state + module-level layer function (audit P9: the old
-- implementation allocated a default table on EVERY call — even on cache
-- hits — plus a fresh closure for each visible frame).
local _tip_text, _tip_x, _tip_y, _tip_theme = nil, 0, 0, nil

local function _draw_tooltip_layer()
    local theme = _tip_theme
    local text = _tip_text
    if not text or not theme then return end
    local pad = 4
    local max_w = theme.tooltip_max_w or 320
    local wrapped = wrap_text(text, max_w)
    local tip_w = wrapped.w + pad * 2
    local tip_h = wrapped.h + pad * 2
    local tip_x = _tip_x + 12
    local tip_y = _tip_y - tip_h - 4

    -- Clamp to window
    local win_w, _ = Core.GetWindowSize()
    if tip_x + tip_w > win_w then tip_x = _tip_x - tip_w - 4 end
    if tip_y < 0 then tip_y = _tip_y + 18 end

    -- Background with slight shadow effect
    Core.DrawRect(tip_x + 1, tip_y + 1, tip_w, tip_h, 0, 0, 0, 0.3)
    local bg = theme.colors.popup_bg
    Core.DrawRect(tip_x, tip_y, tip_w, tip_h, bg[1], bg[2], bg[3], 1)
    local bc = theme.colors.border
    Core.DrawRect(tip_x, tip_y, tip_w, tip_h, bc[1], bc[2], bc[3], 0.6, false)
    local tc = theme.colors.text
    local ty = tip_y + pad
    local lines = wrapped.lines
    for i = 1, #lines do
        Core.DrawText(lines[i], tip_x + pad, ty, tc[1], tc[2], tc[3], tc[4])
        ty = ty + wrapped.line_h + 2
    end
end

function Widgets.Tooltip(text, theme)
    local state = Core.GetState()
    if not state.hot then return end

    -- Track hover time
    local data = Core.GetWidgetData("_tooltip")
    local now = reaper.time_precise()
    local delay = theme.tooltip_delay or 0.4

    if state.hot ~= data.hot_id then
        data.hot_id = state.hot
        data.hover_start = now
        data.visible = false
    elseif not data.visible and (now - data.hover_start) > delay then
        data.visible = true
    end

    if not data.visible then
        -- Wake the idle loop exactly when the delay elapses, so the tooltip
        -- appears on time even with the mouse perfectly still.
        Core.RequestRedrawAt(data.hover_start + delay)
        return
    end

    -- Defer drawing to the tooltip layer (rendered last, on top of
    -- everything). Module-level function + stashed params: no per-frame
    -- closure allocation.
    _tip_text = text
    _tip_theme = theme
    _tip_x, _tip_y = Core.GetMousePos()
    Core.SetTooltip(_draw_tooltip_layer)
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
    local size = opts.size or 40
    if Layout.IsWrapping() then Layout.WrapPreCheck(size) end
    local x, y = Layout.GetCursorPos()
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
                new_value = max(0, min(1, new_value))
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

    -- Cursor
    if hovered then Core.SetCursor("size_ns") end

    -- Draw. Strict visibility: the knob renders through gfx.blit/gfx.arc
    -- which bypass the software clip — a partially scrolled knob would
    -- bleed over its container's neighbours (audit B3 companion fix).
    if Core.IsFullyVisible(x, y, size, size + 14) then
        local cx, cy = x + radius, y + radius
        local display_val = changed and new_value or value

        -- Classic 270° sweep, gap at the bottom: 0 at bottom-left, max at
        -- bottom-right (KNOB_ANGLE_MIN/MAX).
        local angle_min = KNOB_ANGLE_MIN
        local angle_max = KNOB_ANGLE_MAX
        local angle_val = angle_min + (angle_max - angle_min) * display_val
        local ar = radius - 3                                    -- arc radius
        local tw = max(2, floor(radius * 0.1))        -- track thickness

        -- Background (circle + track arc) — baked into shared buffer per size.
        local bg = theme.colors.frame_bg
        local trk = theme.colors.border
        local knob_buf = get_knob_bg_buffer(size,
            bg[1], bg[2], bg[3], trk[1], trk[2], trk[3], tw)
        if knob_buf then
            gfx.blit(knob_buf, 1, 0, 0, 0, size, size, x, y, size, size)
        else
            gfx.set(bg[1], bg[2], bg[3], 0.5)
            gfx.circle(cx, cy, radius - 1, 1, 1)
            gfx.set(trk[1], trk[2], trk[3], 0.25)
            for i = 0, tw - 1 do
                gfx.arc(cx, cy, ar - i, angle_min, angle_max, 1)
            end
        end

        -- Value arc (from min to current value)
        if display_val > 0.005 then
            local ac = theme.colors.accent
            if Core.IsActive(id) then ac = theme.colors.accent_active
            elseif hovered then ac = theme.colors.accent_hovered end
            gfx.set(ac[1], ac[2], ac[3], ac[4])
            for i = 0, tw - 1 do
                gfx.arc(cx, cy, ar - i, angle_min, angle_val, 1)
            end
        end

        -- (no indicator — clean arc only)

        -- Label below knob
        if label then
            Core.SetFontCaption()
            local lw = Core.MeasureText(label)
            local lx = x + floor((size - lw) / 2)
            local ly = y + size + 1
            local lc = theme.colors.text_disabled
            Core.DrawText(label, lx, ly, lc[1], lc[2], lc[3], lc[4])
            Core.SetFontBody()
        end
    end

    Layout.AdvanceCursor(size, size + 14)
    return changed, new_value
end

-- ============================================================================
-- MOD KNOB (knob + modulation overlay, Bitwig-style)
-- ============================================================================
-- A knob whose value is the BASE of a modulated parameter, with the
-- modulation drawn on top:
--   • base value arc (accent) on the outer track, like Knob
--   • excursion arc on an inner ring: [base − |depth|/2, base + |depth|/2]
--     (the modulation model is value = base + (source − 0.5) × depth) —
--     accent-tinted, value_negative-tinted when depth < 0 (inverted)
--   • a live dot riding the ring at the current modulated value
-- Interactions: drag = base, Alt+drag = depth (−1..1), double-click resets
-- the base to `default`, Alt+double-click resets the depth to 0.
-- Returns: base_changed, new_base, depth_changed, new_depth
function Widgets.ModKnob(id, label, base, depth, live, theme, opts)
    opts = opts or {}
    local size = opts.size or 40
    if Layout.IsWrapping() then Layout.WrapPreCheck(size) end
    local x, y = Layout.GetCursorPos()
    local radius = size / 2
    local sensitivity = opts.sensitivity or 0.004
    local depth_sensitivity = opts.depth_sensitivity or 0.008

    base = base or 0.5
    depth = depth or 0

    local base_changed, depth_changed = false, false
    local new_base, new_depth = base, depth

    local hovered = Core.MouseInClippedRect(x, y, size, size + 14) and not Core.HasPopup()
    if hovered then Core.SetHot(id) end
    if hovered and Core.MouseClicked(1) then Core.SetActive(id) end

    if Core.IsActive(id) then
        if Core.MouseDown(1) then
            local _, dy = Core.MouseDelta()
            if dy ~= 0 then
                if Core.ModAlt() then
                    new_depth = max(-1, min(1, new_depth - dy * depth_sensitivity))
                    if new_depth ~= depth then depth_changed = true end
                else
                    new_base = max(0, min(1, new_base - dy * sensitivity))
                    if new_base ~= base then base_changed = true end
                end
            end
        else
            Core.ClearActive()
        end
    end

    if hovered and Core.MouseDoubleClicked() then
        if Core.ModAlt() then
            new_depth = 0
            depth_changed = true
        else
            new_base = opts.default or 0.5
            base_changed = true
        end
    end

    if hovered then Core.SetCursor("size_ns") end

    -- Strict visibility guard: gfx.blit/gfx.arc bypass the software clip
    -- (same constraint as Knob).
    if Core.IsFullyVisible(x, y, size, size + 14) then
        local cx, cy = x + radius, y + radius
        local d_base = base_changed and new_base or base
        local d_depth = depth_changed and new_depth or depth

        -- Classic 270° sweep, gap at the bottom (KNOB_ANGLE_MIN/MAX);
        -- gfx.arc angles are 0 = up, clockwise.
        local angle_min = KNOB_ANGLE_MIN
        local angle_max = KNOB_ANGLE_MAX
        local sweep = angle_max - angle_min
        local function angleOf(v) return angle_min + sweep * max(0, min(1, v)) end
        local ar = radius - 3                       -- outer arc radius
        local tw = max(2, floor(radius * 0.1))      -- track thickness
        local mr = ar - tw - 1                      -- modulation ring radius

        local bg = theme.colors.frame_bg
        local trk = theme.colors.border
        local knob_buf = get_knob_bg_buffer(size,
            bg[1], bg[2], bg[3], trk[1], trk[2], trk[3], tw)
        if knob_buf then
            gfx.blit(knob_buf, 1, 0, 0, 0, size, size, x, y, size, size)
        else
            gfx.set(bg[1], bg[2], bg[3], 0.5)
            gfx.circle(cx, cy, radius - 1, 1, 1)
            gfx.set(trk[1], trk[2], trk[3], 0.25)
            for i = 0, tw - 1 do
                gfx.arc(cx, cy, ar - i, angle_min, angle_max, 1)
            end
        end

        -- Base value arc
        if d_base > 0.005 then
            local ac = theme.colors.accent
            if Core.IsActive(id) then ac = theme.colors.accent_active
            elseif hovered then ac = theme.colors.accent_hovered end
            gfx.set(ac[1], ac[2], ac[3], ac[4])
            for i = 0, tw - 1 do
                gfx.arc(cx, cy, ar - i, angle_min, angleOf(d_base), 1)
            end
        end

        -- Modulation excursion arc on the inner ring
        local half = math.abs(d_depth) * 0.5
        if half > 0.003 then
            local lo = angleOf(d_base - half)
            local hi = angleOf(d_base + half)
            local mc = d_depth < 0 and (theme.colors.value_negative or theme.colors.accent)
                or theme.colors.accent
            gfx.set(mc[1], mc[2], mc[3], 0.45)
            for i = 0, tw - 1 do
                gfx.arc(cx, cy, mr - i, lo, hi, 1)
            end
        end

        -- Live dot riding the modulation ring
        if live then
            local la = angleOf(live)
            local dot_r = max(2, floor(radius * 0.09))
            local dx = cx + math.sin(la) * (mr - tw * 0.5)
            local dy2 = cy - math.cos(la) * (mr - tw * 0.5)
            local tc = theme.colors.text
            gfx.set(tc[1], tc[2], tc[3], 1)
            gfx.circle(dx, dy2, dot_r, 1, 1)
        end

        if label then
            Core.SetFontCaption()
            local lw = Core.MeasureText(label)
            local lc = theme.colors.text_disabled
            Core.DrawText(label, x + floor((size - lw) / 2), y + size + 1,
                lc[1], lc[2], lc[3], lc[4])
            Core.SetFontBody()
        end
    end

    Layout.AdvanceCursor(size, size + 14)
    return base_changed, new_base, depth_changed, new_depth
end

-- ============================================================================
-- VU METER (vertical)
-- ============================================================================
-- Level → color, module-level (audit P9: VMeter/HMeter declared this closure
-- inside their per-frame draw block — one allocation per meter per frame,
-- and meters run continuously in a mixer).
local function meter_color(peak)
    if peak > 0.9 then return 0.9, 0.2, 0.2, 1      -- red
    elseif peak > 0.7 then return 0.9, 0.8, 0.2, 1  -- yellow
    else return 0.3, 0.75, 0.4, 1 end               -- green
end

function Widgets.VMeter(id, peak_l, peak_r, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local width = opts.width or 12
    local height = opts.height or 80
    local half_w = floor(width / 2) - 1

    if Core.IsVisible(x, y, width, height) then
        -- Background
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, half_w, height, bg[1], bg[2], bg[3], bg[4])
        Core.DrawRect(x + half_w + 1, y, width - half_w - 1, height, bg[1], bg[2], bg[3], bg[4])

        -- Left channel
        local h_l = floor(max(0, min(1, peak_l)) * height)
        if h_l > 0 then
            local r, g, b, a = meter_color(peak_l)
            Core.DrawRect(x, y + height - h_l, half_w, h_l, r, g, b, a)
        end

        -- Right channel
        local h_r = floor(max(0, min(1, peak_r)) * height)
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
    local half_h = floor(height / 2) - 1

    if Core.IsVisible(x, y, width, height) then
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, width, half_h, bg[1], bg[2], bg[3], bg[4])
        Core.DrawRect(x, y + half_h + 1, width, height - half_h - 1, bg[1], bg[2], bg[3], bg[4])

        local w_l = floor(max(0, min(1, peak_l)) * width)
        if w_l > 0 then
            local r, g, b, a = meter_color(peak_l)
            Core.DrawRect(x, y, w_l, half_h, r, g, b, a)
        end

        local w_r = floor(max(0, min(1, peak_r)) * width)
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
-- Reserve 200-899 for user images. Freed buffer ids go to a free-list and
-- are reused (audit B16: load/unload cycles used to consume an id forever —
-- ~700 cycles exhausted the whole range for the rest of the session).
local img_next_buffer = 200
local img_cache = {}       -- cache key (path as passed) → { buffer=N, w=W, h=H }
local img_free_bufs = {}   -- stack of released buffer ids
local img_free_n = 0

function Widgets.LoadImage(path)
    -- Check cache first
    if img_cache[path] then return img_cache[path] end

    -- Resolve relative paths from REAPER resource path
    local full_path = path
    if not path:match("^[A-Z]:") and not path:match("^/") then
        full_path = reaper.GetResourcePath() .. "/" .. path
    end

    -- Allocate buffer: reuse a freed id first
    local buf
    if img_free_n > 0 then
        buf = img_free_bufs[img_free_n]
        img_free_n = img_free_n - 1
    else
        buf = img_next_buffer
        if buf > 899 then
            if Log then Log.Warn("WIDGET", "Image buffer limit reached") end
            return nil
        end
        img_next_buffer = img_next_buffer + 1
    end

    -- Load image
    local ok = gfx.loadimg(buf, full_path)
    if ok < 0 then
        if Log then Log.Warn("WIDGET", "Failed to load image: " .. full_path) end
        -- Return the id to the pool — nothing was loaded into it
        img_free_n = img_free_n + 1
        img_free_bufs[img_free_n] = buf
        return nil
    end

    -- Get dimensions
    local w, h = gfx.getimgdim(buf)

    -- cache_key = the path as passed by the caller (audit B16: eviction used
    -- to look up img.path — the RESOLVED path — so relative-path entries were
    -- never removed and a later LoadImage returned a freed buffer).
    local img = { buffer = buf, w = w, h = h, path = full_path, cache_key = path }
    img_cache[path] = img
    return img
end

function Widgets.UnloadImage(img)
    if img and img.buffer then
        gfx.setimgdim(img.buffer, 0, 0)
        img_cache[img.cache_key or img.path] = nil
        img_free_n = img_free_n + 1
        img_free_bufs[img_free_n] = img.buffer
        img.buffer = nil  -- guard against double-unload re-freeing the id
    end
end

-- Display an image
function Widgets.Image(img, theme, opts)
    if not img then return end
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local w = opts.width or img.w
    local h = opts.height or img.h

    -- Strict visibility: gfx.blit bypasses the software clip (see Knob)
    if Core.IsFullyVisible(x, y, w, h) then
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
    local img_size = opts.size or max(img.w, img.h)
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

    -- Strict visibility: gfx.blit bypasses the software clip (see Knob)
    if Core.IsFullyVisible(x, y, w, h) then
        -- Background on hover/active
        if Core.IsActive(id) and hovered then
            local bg = theme.colors.button_active
            Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        elseif hovered then
            local bg = theme.colors.button_hovered
            Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        end

        -- Draw image centered in button
        local ix = x + pad + floor((img_size - min(img_size, img.w)) / 2)
        local iy = y + pad + floor((img_size - min(img_size, img.h)) / 2)
        local draw_w = min(img_size, img.w)
        local draw_h = min(img_size, img.h)

        -- Scale to fit if image is larger than size
        if img.w > img_size or img.h > img_size then
            local scale = min(img_size / img.w, img_size / img.h)
            draw_w = floor(img.w * scale)
            draw_h = floor(img.h * scale)
            ix = x + pad + floor((img_size - draw_w) / 2)
            iy = y + pad + floor((img_size - draw_h) / 2)
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
    local i = floor(h_val * 6)
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

-- ============================================================================
-- EYEDROPPER — screen-wide color picker (anywhere on the desktop)
--   Uses JS_ReaScriptAPI to:
--     - poll the global mouse position (works outside the script window)
--     - poll the global mouse button state (catches clicks anywhere)
--     - blit 1px from the desktop DC to a LICE bitmap, read RGB
--   Live preview drawn at the top-left of the script window each frame.
-- ============================================================================
local eyedropper = {
    active = false,
    callback = nil,
    prev_lmb = false,
    lmb_was_up = false,  -- set true once we observe LMB released after arming
    last_color = nil,
}


local function _has_js_api()
    return reaper.JS_LICE_CreateBitmap
       and reaper.JS_LICE_DestroyBitmap
       and reaper.JS_LICE_GetPixel
       and reaper.JS_LICE_GetDC
       and reaper.JS_GDI_Blit
       and reaper.JS_GDI_ReleaseDC
       and reaper.JS_Mouse_GetState
end

-- Resolve a desktop hwnd / screen DC by trying the various function names
-- exposed by different JS_ReaScriptAPI versions. Returns (hwnd, dc) or (nil).
local function _get_desktop_dc()
    -- Path 1: dedicated screen-DC accessor
    if reaper.JS_GDI_GetScreenDC then
        local dc = reaper.JS_GDI_GetScreenDC()
        if dc then return nil, dc end  -- nil hwnd → release with nil
    end
    -- Path 2: explicit desktop window getter (indirect lookup so the linter
    -- doesn't yell about a function it doesn't know — JS_ReaScriptAPI exposes
    -- different names depending on its version)
    local desktop
    local r_get_desktop = (rawget and rawget(reaper, "JS_Window_GetDesktopWindow"))
                       or rawget(reaper, "JS_Window_GetDesktop")
    if r_get_desktop then
        desktop = r_get_desktop()
    end
    if desktop and reaper.JS_GDI_GetWindowDC then
        local dc = reaper.JS_GDI_GetWindowDC(desktop)
        if dc then return desktop, dc end
    end
    -- Path 3: GetWindowDC(nil) — on Windows, NULL hwnd returns the desktop DC
    if reaper.JS_GDI_GetWindowDC then
        local dc = reaper.JS_GDI_GetWindowDC(nil)
        if dc then return nil, dc end
    end
    return nil, nil
end

-- GDI/LICE resources are acquired ONCE per eyedropper session and released
-- when it ends (audit P16: a 1×1 LICE bitmap + the desktop DC used to be
-- created and destroyed EVERY frame while the eyedropper was active — GDI
-- object churn measured in ms on old hardware).
local function eyedropper_acquire()
    if eyedropper.bm then return true end
    if not _has_js_api() then return false end
    local hwnd, dc = _get_desktop_dc()
    if not dc then return false end
    local bm = reaper.JS_LICE_CreateBitmap(true, 1, 1)
    if not bm then
        reaper.JS_GDI_ReleaseDC(hwnd, dc)
        return false
    end
    local bm_dc = reaper.JS_LICE_GetDC(bm)
    if not bm_dc then
        reaper.JS_LICE_DestroyBitmap(bm)
        reaper.JS_GDI_ReleaseDC(hwnd, dc)
        return false
    end
    eyedropper.bm, eyedropper.bm_dc = bm, bm_dc
    eyedropper.dc_hwnd, eyedropper.dc = hwnd, dc
    return true
end

local function eyedropper_release()
    if eyedropper.bm then reaper.JS_LICE_DestroyBitmap(eyedropper.bm) end
    if eyedropper.dc then reaper.JS_GDI_ReleaseDC(eyedropper.dc_hwnd, eyedropper.dc) end
    eyedropper.bm, eyedropper.bm_dc = nil, nil
    eyedropper.dc, eyedropper.dc_hwnd = nil, nil
end

-- Sample one pixel from the desktop at SCREEN coordinates (sx, sy) using the
-- session resources. Returns {r, g, b} in 0-1 range (a reused table — copy
-- if you need to keep it), or nil on failure.
local function sample_screen_pixel(sx, sy)
    if not eyedropper.bm then return nil end
    reaper.JS_GDI_Blit(eyedropper.bm_dc, 0, 0, eyedropper.dc, sx, sy, 1, 1)
    local pixel = reaper.JS_LICE_GetPixel(eyedropper.bm, 0, 0)
    if not pixel then return nil end
    local c = eyedropper.sample
    if not c then c = {}; eyedropper.sample = c end
    c[1] = ((pixel >> 16) & 0xFF) / 255
    c[2] = ((pixel >> 8) & 0xFF) / 255
    c[3] = (pixel & 0xFF) / 255
    return c
end

function Widgets.StartEyedropper(callback)
    if not eyedropper_acquire() then return false end
    eyedropper.active = true
    eyedropper.callback = callback
    eyedropper.lmb_was_up = false
    eyedropper.prev_lmb = true   -- assume the arming click is still down
    eyedropper.last_color = nil
    eyedropper.rgb_str = nil
    return true
end

-- Overlay drawn via the tooltip layer. Module-level function reading the
-- eyedropper table — the old per-frame closure captured color/theme and
-- string.format'd the RGB readout on every frame.
local function _draw_eyedropper_overlay()
    local theme = eyedropper.theme
    local color = eyedropper.last_color
    local hw, hh = 220, 38
    local hx, hy = 6, 6
    local pbg = (theme and theme.colors.popup_bg) or { 0.1, 0.1, 0.1, 0.95 }
    Core.DrawRect(hx, hy, hw, hh, pbg[1], pbg[2], pbg[3], pbg[4] or 0.95)
    local bc = (theme and theme.colors.border) or { 0.6, 0.6, 0.6, 1 }
    Core.DrawRect(hx, hy, hw, hh, bc[1], bc[2], bc[3], bc[4] or 1, false)

    local sw_x = hx + 4
    local sw_y = hy + 4
    local sw_size = hh - 8
    if color then
        Core.DrawRect(sw_x, sw_y, sw_size, sw_size, color[1], color[2], color[3], 1)
        Core.DrawRect(sw_x, sw_y, sw_size, sw_size, 0.5, 0.5, 0.5, 0.6, false)
        local tc = (theme and theme.colors.text) or COLOR_WHITE
        -- Re-format the readout only when the sampled color changed
        if eyedropper.rgb_r ~= color[1] or eyedropper.rgb_g ~= color[2]
           or eyedropper.rgb_b ~= color[3] or not eyedropper.rgb_str then
            eyedropper.rgb_str = string.format("R %d  G %d  B %d",
                floor(color[1] * 255 + 0.5),
                floor(color[2] * 255 + 0.5),
                floor(color[3] * 255 + 0.5))
            eyedropper.rgb_r, eyedropper.rgb_g, eyedropper.rgb_b =
                color[1], color[2], color[3]
        end
        Core.DrawText(eyedropper.rgb_str, sw_x + sw_size + 8, hy + 4, tc[1], tc[2], tc[3], 1)
        Core.DrawText("Click to pick — Esc / R-click to cancel",
                              sw_x + sw_size + 8, hy + 18, tc[1], tc[2], tc[3], 0.7)
    else
        Core.DrawText("Eyedropper failed (JS_ReaScriptAPI missing?)",
                      sw_x, hy + 12, 1, 0.5, 0.5, 1)
    end
end

-- Called each frame from UI.Run.
function Widgets.UpdateEyedropper(theme)
    if not eyedropper.active then return end

    -- Keep the script redrawing even while the mouse is elsewhere on screen
    Core.RequestRedraw()

    -- Global mouse position (works regardless of focus)
    local sx, sy = reaper.GetMousePosition()
    local color = sample_screen_pixel(sx, sy)
    if color then eyedropper.last_color = color end

    -- Live preview overlay drawn in the top-left of the script window.
    -- Uses the tooltip layer so it renders on top of everything this frame.
    eyedropper.theme = theme
    Core.SetTooltip(_draw_eyedropper_overlay)

    -- Global mouse button state (independent of script window focus)
    local mstate = reaper.JS_Mouse_GetState(0xFF)
    local lmb_now = (mstate & 1) ~= 0
    local rmb_now = (mstate & 2) ~= 0

    -- Commit on down→up edge, but ONLY if lmb_was_up was already set on a
    -- PREVIOUS frame. This prevents the arming click's release from firing
    -- immediately (the old code set lmb_was_up and checked it in the same
    -- frame iteration, so the very first release always triggered commit).
    if eyedropper.lmb_was_up and eyedropper.prev_lmb and not lmb_now then
        if color and eyedropper.callback then
            eyedropper.callback(color)
        end
        eyedropper.active = false
        eyedropper.callback = nil
        eyedropper_release()
        return
    end

    -- Update lmb_was_up AFTER the edge check (not before)
    if not lmb_now then eyedropper.lmb_was_up = true end
    eyedropper.prev_lmb = lmb_now

    -- Right-click or Escape cancels (the consumed ESC must not bubble up to
    -- Core.Run's close handling — audit B2)
    if rmb_now or Core.GetChar() == 27 then
        if Core.GetChar() == 27 then Core.ConsumeChar() end
        eyedropper.active = false
        eyedropper.callback = nil
        eyedropper_release()
    end
end

function Widgets.IsEyedropperActive()
    return eyedropper.active
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
    local data = Core.GetWidgetSubData("color", id)
    if data._init == nil then
        data.hue = 0
        data.sat = 1
        data.val = 1
        data.initialized = false
        data.pending = nil
        data._init = true
    end

    -- Check for pending color from popup. `changed` is only reported on the
    -- frame(s) where the popup actually wrote a new value (audit B6: it used
    -- to stay true for the whole popup lifetime — callers doing
    -- `if changed then save end` wrote to disk/REAPER ~30×/s).
    local changed = false
    local new_color = color
    if data.pending then
        new_color = data.pending
        if data.pending_frame and Core.GetFrame() <= data.pending_frame + 1 then
            changed = true
            -- Track the value we just handed to the caller so the external-
            -- change resync below doesn't mistake it for an outside edit.
            data.sync_r, data.sync_g, data.sync_b =
                new_color[1], new_color[2], new_color[3]
        end
        -- Keep pending alive while popup is open (live swatch display)
        if not Core.HasPopup(id) then
            data.pending = nil
        end
    end

    -- Resync HSV when the caller's color changed externally — preset load,
    -- theme switch (audit B7: hue/sat/val kept the values captured at the
    -- first init forever; the popup then reopened on a stale color).
    if data.initialized and not data.pending
       and (color[1] ~= data.sync_r or color[2] ~= data.sync_g
            or color[3] ~= data.sync_b) then
        data.initialized = false
    end

    -- Initialize HSV from current color
    if not data.initialized then
        local cr, cg, cb = new_color[1], new_color[2], new_color[3]
        local max_c = max(cr, cg, cb)
        local min_c = min(cr, cg, cb)
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
        data.sync_r, data.sync_g, data.sync_b = cr, cg, cb
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
        local _, win_h = Core.GetWindowSize()
        if picker_y + picker_h > win_h then picker_y = py - picker_h - 2 end

        data.open_frame = Core.GetState().frame
        data.pending = nil

        Core.SetPopup(id, function()
            local d = Core.GetWidgetSubData("color", id)
            local frame_now = Core.GetState().frame
            local input_ready = frame_now > (d.open_frame or 0)

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

            -- Draw SV gradient — render into buffer once per (hue, size);
            -- blit each frame. Saves ~5.5k gfx.rect calls when hue is stable.
            local gb = colorpicker_gradient
            local cur_hue = d.hue or 0
            if gb.sv_hue ~= cur_hue or gb.sv_size ~= sq_size then
                gfx.dest = gb.sv_buf_id
                gfx.setimgdim(gb.sv_buf_id, sq_size, sq_size)
                for row = 0, sq_size - 1 do
                    local v = 1 - row / sq_size
                    for col = 0, sq_size - 1, 3 do
                        local s = col / sq_size
                        local cr, cg, cb = hsv_to_rgb(cur_hue, s, v)
                        gfx.set(cr, cg, cb, 1)
                        gfx.rect(col, row, 3, 1, 1)
                    end
                end
                gfx.dest = -1
                gb.sv_hue = cur_hue
                gb.sv_size = sq_size
            end
            gfx.blit(gb.sv_buf_id, 1, 0, 0, 0, sq_size, sq_size, sq_x, sq_y, sq_size, sq_size)

            -- Draw hue bar — depends only on size, not hue. Render once, blit.
            if gb.hue_size ~= sq_size or gb.hue_w ~= hue_bar_w then
                gfx.dest = gb.hue_buf_id
                gfx.setimgdim(gb.hue_buf_id, hue_bar_w, sq_size)
                for row = 0, sq_size - 1 do
                    local hv = row / sq_size
                    local cr, cg, cb = hsv_to_rgb(hv, 1, 1)
                    gfx.set(cr, cg, cb, 1)
                    gfx.rect(0, row, hue_bar_w, 1, 1)
                end
                gfx.dest = -1
                gb.hue_size = sq_size
                gb.hue_w = hue_bar_w
            end
            gfx.blit(gb.hue_buf_id, 1, 0, 0, 0, hue_bar_w, sq_size, hue_bar_x, sq_y, hue_bar_w, sq_size)

            -- SV cursor
            gfx.set(1, 1, 1, 0.9)
            gfx.rect(sq_x + floor((d.sat or 0) * sq_size) - 2,
                     sq_y + floor((1 - (d.val or 1)) * sq_size) - 2, 5, 5, 0)

            -- Hue cursor
            gfx.set(1, 1, 1, 0.9)
            gfx.rect(hue_bar_x - 1, sq_y + floor((d.hue or 0) * sq_size) - 1, hue_bar_w + 2, 3, 0)

            if input_ready then
                local mx, my = Core.GetMousePos()
                -- Drag SV square
                local in_sv = Core.MouseInRect(sq_x, sq_y, sq_size, sq_size)
                if Core.MouseDown(1) and in_sv then
                    d.sat = max(0, min(1, (mx - sq_x) / sq_size))
                    d.val = max(0, min(1, 1 - (my - sq_y) / sq_size))
                    local nr, ng, nb = hsv_to_rgb(d.hue, d.sat, d.val)
                    d.pending = { nr, ng, nb }
                    d.pending_frame = Core.GetFrame()
                end

                -- Drag hue bar
                local in_hue = Core.MouseInRect(hue_bar_x, sq_y, hue_bar_w, sq_size)
                if Core.MouseDown(1) and in_hue then
                    d.hue = max(0, min(1, (my - sq_y) / sq_size))
                    local nr, ng, nb = hsv_to_rgb(d.hue, d.sat, d.val)
                    d.pending = { nr, ng, nb }
                    d.pending_frame = Core.GetFrame()
                end
            end

            -- Preview + hex
            local prev_y = sq_y + sq_size + 4
            local cr, cg, cb = hsv_to_rgb(d.hue or 0, d.sat or 1, d.val or 1)
            Core.DrawRect(sq_x, prev_y, 30, 16, cr, cg, cb, 1)
            local hex_str = string.format("#%02X%02X%02X",
                floor(cr * 255), floor(cg * 255), floor(cb * 255))
            local tc = theme.colors.text
            Core.DrawText(hex_str, sq_x + 36, prev_y + 1, tc[1], tc[2], tc[3], tc[4])

            -- Close: click outside picker (only after input lockout), right-click, or Escape
            if input_ready then
                local in_picker = Core.MouseInRect(picker_x, picker_y, picker_w, picker_h)
                if Core.MouseClicked(1) and not in_picker then
                    Core.ClearPopup(id)
                end
                if Core.MouseClicked(2) then
                    Core.ClearPopup(id)
                elseif Core.GetChar() == 27 then
                    Core.ClearPopup(id)
                    Core.ConsumeChar()
                end
            end
        end)
    end

    -- Draw label + preview swatch
    if Core.IsVisible(x, y, total_w, h) then
        if tw > 0 then
            local tc = theme.colors.text
            local ly = y + floor((h - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        -- Show current color (new_color already tracks a live pending value)
        local display = new_color
        Core.DrawRect(px, py, preview_size, preview_size, display[1], display[2], display[3], 1)
        local bc = theme.colors.border
        Core.DrawRect(px, py, preview_size, preview_size, bc[1], bc[2], bc[3], 0.5, false)
    end

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

    -- Truncate label if the total widget won't fit the container.
    local input_w = opts.width or 80
    if tw > 0 then
        local max_label_w = max(0, avail_w - input_w - 8)
        if tw > max_label_w then
            label, tw = Core.TruncateText(label, max_label_w)
        end
    end
    local h = theme.combo_height
    local total_w = input_w + (tw > 0 and (tw + 8) or 0)
    local step = opts.step or 1
    local format = opts.format or (step < 1 and "%.2f" or "%d")
    local speed = opts.speed or step

    local ix = x + (tw > 0 and (tw + 8) or 0)
    local iy = y

    local data = Core.GetWidgetSubData("numinput", id)
    if data._init == nil then
        data.editing = false
        data.edit_buf = ""
        data.blink_time = 0
        data._init = true
    end
    local changed = false
    local new_value = value
    local disabled = opts.disabled or Core.IsDisabled()

    local hovered = (not disabled)
        and Core.MouseInClippedRect(ix, iy, input_w, h)
        and not Core.HasPopup()
    local is_focused = Core.IsFocused(id)

    -- If we were editing but lost focus, submit and exit edit mode
    if data.editing and not is_focused then
        local num = tonumber(data.edit_buf)
        if num then
            new_value = num
            if min_val then new_value = max(min_val, new_value) end
            if max_val then new_value = min(max_val, new_value) end
            changed = true
        end
        data.editing = false
    end

    if hovered then
        Core.SetHot(id)
        -- Ibeam in edit mode (text entry); horizontal-resize cursor otherwise
        -- to signal the drag-to-adjust-value behaviour.
        Core.SetCursor(data.editing and "ibeam" or "size_we")
    end

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
                    if min_val then new_value = max(min_val, new_value) end
                    if max_val then new_value = min(max_val, new_value) end
                    if step >= 1 then new_value = floor(new_value + 0.5) end
                    if new_value ~= value then changed = true end
                end
            else
                Core.ClearActive()
            end
        end

        -- Mouse wheel to increment/decrement. Consumed (audit B4): otherwise
        -- the same tick also scrolls the parent child-container.
        if hovered and not Core.HasPopup() and not Core.IsWheelConsumed() then
            local wheel = Core.GetState().mouse_wheel
            if wheel ~= 0 then
                local dir = wheel > 0 and 1 or -1
                new_value = value + dir * step
                if min_val then new_value = max(min_val, new_value) end
                if max_val then new_value = min(max_val, new_value) end
                if step >= 1 then new_value = floor(new_value + 0.5) end
                if new_value ~= value then changed = true end
                Core.ConsumeWheel()
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
                if min_val then new_value = max(min_val, new_value) end
                if max_val then new_value = min(max_val, new_value) end
                changed = true
            end
            data.editing = false
            Core.SetFocus(nil)
            Core.ConsumeChar()
        elseif char == Keys.ESCAPE then
            -- Cancel edit. Consuming is essential (audit B2): otherwise
            -- Core.Run sees an unhandled ESC with no focus left and closes
            -- the whole window.
            data.editing = false
            Core.SetFocus(nil)
            Core.ConsumeChar()
        elseif char == Keys.BACKSPACE then
            if #data.edit_buf > 0 then
                data.edit_buf = data.edit_buf:sub(1, -2)
                data.blink_time = reaper.time_precise()
            end
            Core.ConsumeChar()
        elseif char > 31 and char < 256 then
            local c = string.char(char)
            if c:match("[0-9%.%-]") then
                data.edit_buf = data.edit_buf .. c
                data.blink_time = reaper.time_precise()
            end
            Core.ConsumeChar()
        end
        -- Wake the idle loop exactly at the next caret-blink edge instead of
        -- keeping full-rate redraws while a field merely has focus (audit P2)
        if data.editing then Core.ScheduleBlinkRedraw(data.blink_time) end
    end

    -- Draw
    if Core.IsVisible(x, y, total_w, h) then
        if tw > 0 then
            local tc = theme.colors.text
            local ly = y + floor((h - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        local bg = data.editing and theme.colors.frame_active or
                   (hovered and theme.colors.frame_hovered or theme.colors.frame_bg)
        Core.DrawRect(ix, iy, input_w, h, bg[1], bg[2], bg[3], bg[4])

        draw_win32_bevel(ix, iy, input_w, h, theme, "sunken")

        -- Format value with cache (only re-format when display value changes)
        local display
        if data.editing then
            display = data.edit_buf
        else
            local display_val = changed and new_value or value
            if data.fv_val == display_val and data.fv_fmt == format and data.fv_str then
                display = data.fv_str
            else
                display = string.format(format, display_val)
                data.fv_val = display_val
                data.fv_fmt = format
                data.fv_str = display
            end
        end
        local dtw, dth = Core.MeasureText(display)
        local tx = ix + floor((input_w - dtw) / 2)
        local ty = iy + floor((h - dth) / 2)
        local tc = theme.colors.text
        Core.DrawText(display, tx, ty, tc[1], tc[2], tc[3], tc[4])

        -- Blinking cursor when editing
        if data.editing and is_focused then
            local elapsed = reaper.time_precise() - data.blink_time
            if elapsed % Core.BLINK_PERIOD < Core.BLINK_ON then
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

    local data = Core.GetWidgetSubData("textedit", id)
    if data._init == nil then
        data.cursor = #text
        data.scroll_y = 0
        data.blink_time = 0
        data._init = true
    end

    local changed = false
    local new_text = text
    local is_focused = Core.IsFocused(id)
    local hovered = Core.MouseInClippedRect(x, y, w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        Core.SetCursor("ibeam")
    end

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

        -- Reuse cached line split when possible (render path populates cache).
        local lines
        if data._cached_text == text and data._cached_lines then
            lines = data._cached_lines
        else
            lines = {}
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                lines[#lines + 1] = line
            end
            data._cached_text = text
            data._cached_lines = lines
        end

        -- Find clicked line
        local clicked_line = max(1, min(#lines, floor(click_y / row_h) + 1))

        -- Find clicked character in that line (raw gfx.measurestr: these
        -- one-shot prefix probes must not fill the measure cache)
        local line_text = lines[clicked_line] or ""
        local char_in_line = 0
        for i = 1, #line_text do
            if gfx.measurestr(line_text:sub(1, i)) > click_x then break end
            char_in_line = i
        end

        -- Convert line + char to absolute cursor position
        local abs_pos = 0
        for i = 1, clicked_line - 1 do
            abs_pos = abs_pos + #(lines[i] or "") + 1  -- +1 for \n
        end
        data.cursor = abs_pos + char_in_line
    end

    -- Keyboard input (byte offsets snapped to UTF-8 boundaries — audit B13)
    if is_focused and Keys then
        local char = Core.GetChar()

        if char == Keys.BACKSPACE and data.cursor > 0 then
            local p = utf8_prev(text, data.cursor)
            new_text = text:sub(1, p) .. text:sub(data.cursor + 1)
            data.cursor = p
            changed = true
            data.blink_time = reaper.time_precise()

        elseif char == Keys.DELETE and data.cursor < #text then
            local n = utf8_next(text, data.cursor)
            new_text = text:sub(1, data.cursor) .. text:sub(n + 1)
            changed = true
            data.blink_time = reaper.time_precise()

        elseif char == Keys.LEFT and data.cursor > 0 then
            data.cursor = utf8_prev(text, data.cursor)
            data.blink_time = reaper.time_precise()

        elseif char == Keys.RIGHT and data.cursor < #text then
            data.cursor = utf8_next(text, data.cursor)
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

        elseif char >= 32 and char < 0x2000 then
            -- Printable range; REAPER's named keys (arrows, F-keys, 'pgup'…)
            -- are multi-char int codes far above 0x2000.
            local s = char_to_utf8(char)
            local before = text:sub(1, data.cursor)
            local after = text:sub(data.cursor + 1)
            new_text = before .. s .. after
            data.cursor = data.cursor + #s
            changed = true
            data.blink_time = reaper.time_precise()
        end

        -- Keys handled here must not reach Core.Run's close logic; an
        -- unconsumed ESC intentionally falls through (Core unfocuses on it).
        if char > 0 and char ~= 27 then Core.ConsumeChar() end

        -- Schedule the caret-blink wakeups (audit P2: focus no longer keeps
        -- the loop at full rate — blink redraws are deadline-scheduled).
        Core.ScheduleBlinkRedraw(data.blink_time)
    end

    -- Scroll (cache line split when text unchanged)
    local display_text = changed and new_text or text
    if data._cached_text ~= display_text then
        data._cached_text = display_text
        local l = {}
        for line in (display_text .. "\n"):gmatch("([^\n]*)\n") do
            l[#l + 1] = line
        end
        data._cached_lines = l
    end
    local lines = data._cached_lines
    local _, line_h = Core.MeasureText("M")
    local content_h = #lines * (line_h + 2)

    if hovered and not Core.HasPopup() and not Core.IsWheelConsumed() then
        local wheel = Core.GetState().mouse_wheel
        if wheel ~= 0 then
            -- 3 lines per notch, independent of platform wheel-delta magnitude.
            local dir = wheel > 0 and -1 or 1
            data.scroll_y = max(0, min(data.scroll_y + dir * (line_h + 2) * 3,
                max(0, content_h - h + pad * 2)))
            -- Consumed (audit B4): otherwise the parent container scrolls too
            Core.ConsumeWheel()
        end
    end

    -- Draw using offscreen buffer for clipping
    if Core.IsVisible(x, y, w, h) then
        local bg = is_focused and theme.colors.frame_active or theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        draw_win32_bevel(x, y, w, h, theme, "sunken")

        -- Render into buffer — only resize when the SHARED buffer's real
        -- dimensions change (audit B1: tracked per-buffer, not per-widget).
        local buf_id = 901
        local vis_w = w - pad * 2
        local vis_h = h - 4
        gfx.dest = buf_id
        if textedit_buf_w ~= vis_w or textedit_buf_h ~= vis_h then
            gfx.setimgdim(buf_id, vis_w, vis_h)
            textedit_buf_w = vis_w
            textedit_buf_h = vis_h
        end
        gfx.set(bg[1], bg[2], bg[3], 1)
        gfx.rect(0, 0, vis_w, vis_h, 1)

        local tc = theme.colors.text
        gfx.set(tc[1], tc[2], tc[3], tc[4])

        -- Windowed iteration (audit P12): only the visible rows are walked —
        -- the old loop iterated ALL document lines each frame, O(#lines) for
        -- a handful of visible ones.
        local row_h = line_h + 2
        local first = max(1, floor(data.scroll_y / row_h) + 1)
        local last = min(#lines, first + ceil(vis_h / row_h) + 1)
        -- Byte offset of the first visible line (O(first) integer adds; only
        -- while the editor is visible and being redrawn)
        local char_pos = 0
        for i = 1, first - 1 do
            char_pos = char_pos + #lines[i] + 1  -- +1 for \n
        end

        for li = first, last do
            local line = lines[li]
            local draw_y = 2 - data.scroll_y + (li - 1) * row_h
            gfx.x, gfx.y = 0, draw_y
            gfx.drawstr(line)

            -- Cursor in this line?
            if is_focused and data.cursor >= char_pos and data.cursor <= char_pos + #line then
                local elapsed = reaper.time_precise() - data.blink_time
                if elapsed % Core.BLINK_PERIOD < Core.BLINK_ON then
                    local cx = gfx.measurestr(line:sub(1, data.cursor - char_pos))
                    gfx.set(tc[1], tc[2], tc[3], 0.9)
                    gfx.rect(cx, draw_y, 1, line_h, 1)
                    gfx.set(tc[1], tc[2], tc[3], tc[4])
                end
            end

            char_pos = char_pos + #line + 1  -- +1 for \n
        end

        -- Blit to screen
        gfx.dest = -1
        gfx.blit(buf_id, 1, 0, 0, 0, vis_w, vis_h, x + pad, y + 2)

        -- Scrollbar
        if content_h > h then
            local bar_x = x + w - 6
            local bar_h = h - 4
            local thumb_h = max(10, bar_h * (h / content_h))
            local scroll_range = content_h - h + pad * 2
            local ratio = scroll_range > 0 and (data.scroll_y / scroll_range) or 0
            local thumb_y = y + 2 + (bar_h - thumb_h) * ratio
            local sbg = theme.colors.scrollbar_bg
            local sgr = theme.colors.scrollbar_grab
            Core.DrawRect(bar_x, y + 2, 4, bar_h, sbg[1], sbg[2], sbg[3], (sbg[4] or 1) * 0.5)
            Core.DrawRect(bar_x, thumb_y, 4, thumb_h, sgr[1], sgr[2], sgr[3], sgr[4] or 1)
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
    local disabled = opts.disabled or Core.IsDisabled()

    if label and label ~= "" then
        Widgets.Text(label, theme)
    end

    if horizontal then Layout.SameLine() end

    -- Per-item ids cached once (audit P9: `id .. "_" .. i` allocated one
    -- string per item per FRAME — the exact pattern PERFORMANCE.md forbids).
    local rd = Core.GetWidgetSubData("radio", id)
    local item_ids = rd.item_ids
    if not item_ids or rd.item_count ~= #items then
        item_ids = {}
        for i = 1, #items do item_ids[i] = id .. "_" .. i end
        rd.item_ids = item_ids
        rd.item_count = #items
    end

    for i, item_label in ipairs(items) do
        local item_id = item_ids[i]
        local size = theme.checkbox_size
        local item_tw, item_th = Core.MeasureText(item_label)
        local total_w = size + 6 + item_tw

        -- In horizontal mode: wrap to next line when the next item would
        -- overflow the container's remaining width. Keeps the whole row
        -- inside the window padding even when the window is narrow.
        if horizontal and i > 1 then
            local avail = Layout.GetAvailableWidth()
            if total_w > avail then Layout.NewLine() end
        end

        local x, y = Layout.GetCursorPos()
        local h = max(size, item_th)
        local is_selected = (i == current_index)

        local item_hovered = (not disabled)
            and Core.MouseInClippedRect(x, y, total_w, h)
            and not Core.HasPopup()

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
            local circle_y = y + floor((h - size) / 2)
            local bg = item_hovered and theme.colors.frame_hovered or theme.colors.frame_bg

            -- Box fill (+ top shadow in windows mode only)
            gfx.set(bg[1], bg[2], bg[3], bg[4])
            gfx.rect(x, circle_y, size, size, 1)
            draw_win32_bevel(x, circle_y, size, size, theme, "sunken")

            -- Filled dot if selected
            if is_selected or (changed and new_index == i) then
                local ac = theme.colors.accent
                gfx.set(ac[1], ac[2], ac[3], ac[4])
                if theme.widget_style == "windows" then
                    -- Asymmetric: 2px bevel top/left vs 1px bottom/right
                    gfx.rect(x + 4, circle_y + 4, size - 7, size - 7, 1)
                else
                    local m = 4
                    gfx.rect(x + m, circle_y + m, size - m * 2, size - m * 2, 1)
                end
            end

            -- Label
            local tc = disabled and theme.colors.text_disabled or theme.colors.text
            local lx = x + size + 6
            local ly = y + floor((h - item_th) / 2)
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

    fraction = max(0, min(1, fraction))

    if Core.IsVisible(x, y, w, h) then
        -- Background
        local bg = theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
        draw_win32_bevel(x, y, w, h, theme, "sunken")

        -- Filled portion — asymmetric inset: 2px top/left (bevel shadow), 1px bottom/right
        local s_top = (theme.widget_style == "windows") and 2 or 0
        local s_bot = (theme.widget_style == "windows") and 1 or 0
        local fill_w = floor((w - s_top - s_bot) * fraction)
        if fill_w > 0 then
            local ac = theme.colors.accent
            Core.DrawRect(x + s_top, y + s_top, fill_w, h - s_top - s_bot, ac[1], ac[2], ac[3], ac[4])
        end

        -- Text overlay — percentage string is cached so we only re-format
        -- when the integer percent value actually changes (sub-pixel
        -- fraction changes don't invalidate).
        local display_text
        if label == nil then
            local pct = floor(fraction * 100)
            local pd = Core.GetWidgetSubData("progressbar", id)
            if pd.fv_pct == pct and pd.fv_str then
                display_text = pd.fv_str
            else
                display_text = string.format("%d%%", pct)
                pd.fv_pct = pct
                pd.fv_str = display_text
            end
        elseif label ~= "" then
            display_text = label
        end

        if display_text then
            local tw, th = Core.MeasureText(display_text)
            -- Only draw if text fits with padding
            if tw + 8 <= w then
                local tx = x + floor((w - tw) / 2)
                local ty = y + floor((h - th) / 2)
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

    -- Scroll state
    local data = Core.GetWidgetSubData("table", id)
    if data._init == nil then
        data.scroll_y = 0
        data._cells = {}   -- row_idx -> { col_idx -> {raw, str, th} }
        data._hdr = {}     -- col_idx -> {raw, th}
        data._col_widths = {}
        data._init = true
    end

    -- Calculate column widths into a REUSED table (audit 1.3 leftover:
    -- col_widths = {} allocated per frame on stable data)
    local total_fixed = 0
    local auto_count = 0
    for _, col in ipairs(columns) do
        if col.width then
            total_fixed = total_fixed + col.width
        else
            auto_count = auto_count + 1
        end
    end
    local auto_width = auto_count > 0 and floor((avail_w - total_fixed) / auto_count) or 0

    local col_widths = data._col_widths
    for i, col in ipairs(columns) do
        col_widths[i] = col.width or auto_width
    end
    for i = #columns + 1, #col_widths do col_widths[i] = nil end

    -- Purge cell caches of rows that no longer exist (audit P11: after a
    -- dataset shrink — search filter, refresh — the stale row caches kept
    -- their strings alive for the whole session)
    local nrows = #rows
    if data._last_nrows and nrows < data._last_nrows then
        local cells = data._cells
        for i = nrows + 1, data._last_nrows do cells[i] = nil end
    end
    data._last_nrows = nrows

    -- Total height
    local visible_rows = min(nrows, max_visible)
    local total_h = (show_header and header_h or 0) + visible_rows * row_h

    -- Re-clamp scroll every frame (audit B14: when the row count shrinks —
    -- filtered list — the view stayed past the end, showing a blank list
    -- until the next wheel tick)
    data.scroll_y = max(0, min(data.scroll_y, max(0, nrows - visible_rows)))
    local scroll_offset = floor(data.scroll_y)

    local clicked_row, clicked_col = nil, nil

    if Core.IsVisible(x, y, avail_w, total_h) then
        local draw_y = y

        -- Header — measure once per column, re-measure only if header text changes.
        if show_header then
            local hbg = theme.colors.header
            Core.DrawRect(x, draw_y, avail_w, header_h, hbg[1], hbg[2], hbg[3], hbg[4])

            local col_x = x
            local hdr_cache = data._hdr
            for i, col in ipairs(columns) do
                local h_text = col.header or ""
                local he = hdr_cache[i]
                local th
                if he and he.raw == h_text then
                    th = he.th
                else
                    local _, m_th = Core.MeasureText(h_text)
                    th = m_th
                    if he then he.raw = h_text; he.th = th
                    else hdr_cache[i] = { raw = h_text, th = th } end
                end
                local tx = col_x + 6
                local ty = draw_y + floor((header_h - th) / 2)
                local tc = theme.colors.text
                Core.DrawText(h_text, tx, ty, tc[1], tc[2], tc[3], tc[4])

                -- Sort indicator (F8): opts.sort = { col = idx, dir = "asc"|"desc" }.
                -- The toolkit only DRAWS the indicator and reports header
                -- clicks (clicked_row == 0) — sorting the data is the
                -- caller's job (event-driven, never per frame).
                if opts.sort and opts.sort.col == i then
                    local asc = opts.sort.dir ~= "desc"
                    local isz = min(header_h - 4, 12)
                    local ix2 = col_x + col_widths[i] - isz - 2
                    local iy2 = draw_y + floor((header_h - isz) / 2)
                    local ac = theme.colors.accent
                    if Icons then
                        if asc then
                            Icons.TriangleUp(ix2, iy2, isz, ac[1], ac[2], ac[3], ac[4] or 1)
                        else
                            Icons.TriangleDown(ix2, iy2, isz, ac[1], ac[2], ac[3], ac[4] or 1)
                        end
                    else
                        Core.DrawText(asc and "^" or "v", ix2, ty, ac[1], ac[2], ac[3], ac[4] or 1)
                    end
                end

                -- Header click → reported as clicked_row = 0 + clicked_col
                if show_header and Core.MouseInClippedRect(col_x, draw_y, col_widths[i], header_h)
                   and not Core.HasPopup() and Core.MouseClicked(1) then
                    clicked_row = 0
                    clicked_col = i
                end

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

        -- List color aliases (fallback to generic theme colors if list_* not set)
        local list_bg   = theme.colors.list_bg or theme.colors.frame_bg
        local list_text = theme.colors.list_text or theme.colors.text
        local list_alt  = theme.colors.list_alt_bg
        local list_sel  = theme.colors.list_selected or theme.colors.accent
        local list_sel_t = theme.colors.list_selected_text or COLOR_WHITE
        local list_hov  = theme.colors.list_hover or theme.colors.header_hovered
        local list_grid = theme.colors.list_grid

        -- List background (behind all rows)
        local body_h = visible_rows * row_h
        Core.DrawRect(x, draw_y, avail_w, body_h, list_bg[1], list_bg[2], list_bg[3], list_bg[4])

        -- Rows
        for row_idx = 1 + scroll_offset, min(#rows, visible_rows + scroll_offset) do
            local row = rows[row_idx]
            local row_y = draw_y + (row_idx - 1 - scroll_offset) * row_h
            local is_selected = (row_idx == selected_row)
            local vis_row = row_idx - scroll_offset

            -- Row hover / selection
            local row_hovered = Core.MouseInClippedRect(x, row_y, avail_w, row_h) and not Core.HasPopup()

            local inset = (theme.widget_style == "windows") and 2 or 0

            -- Alternating row background
            if list_alt and vis_row % 2 == 0 and not is_selected then
                Core.DrawRect(x + inset, row_y, avail_w - inset * 2, row_h, list_alt[1], list_alt[2], list_alt[3], list_alt[4])
            end

            -- Selection highlight (full row)
            if is_selected then
                Core.DrawRect(x + inset, row_y, avail_w - inset * 2, row_h, list_sel[1], list_sel[2], list_sel[3], list_sel[4])
            end

            -- Hover highlight
            if row_hovered and not is_selected then
                Core.DrawRect(x + inset, row_y, avail_w - inset * 2, row_h, list_hov[1], list_hov[2], list_hov[3], list_hov[4] or 0.5)
            end

            if row_hovered and Core.MouseClicked(1) then
                clicked_row = row_idx
            end

            -- Grid line (bottom of row)
            if list_grid then
                Core.DrawLine(x, row_y + row_h - 1, x + avail_w, row_y + row_h - 1,
                    list_grid[1], list_grid[2], list_grid[3], list_grid[4] or 0.3)
            end

            -- Cell values — cache tostring + MeasureText per (row, col).
            -- Invalidated per-cell when raw value changes.
            local col_x = x
            local tc = is_selected and list_sel_t or list_text
            local cell_cache = data._cells
            local row_cache = cell_cache[row_idx]
            if not row_cache then
                row_cache = {}
                cell_cache[row_idx] = row_cache
            end
            for col_idx, cell_value in ipairs(row) do
                if col_idx <= #columns then
                    local cw = col_widths[col_idx]
                    local ce = row_cache[col_idx]
                    local cell_str, cell_th
                    if ce and ce.raw == cell_value then
                        cell_str = ce.str
                        cell_th = ce.th
                    else
                        cell_str = type(cell_value) == "string" and cell_value or tostring(cell_value)
                        local _, m_th = Core.MeasureText(cell_str)
                        cell_th = m_th
                        if ce then ce.raw = cell_value; ce.str = cell_str; ce.th = cell_th
                        else row_cache[col_idx] = { raw = cell_value, str = cell_str, th = cell_th } end
                    end
                    local tx = col_x + 6
                    local ty = row_y + floor((row_h - cell_th) / 2)
                    Core.DrawText(cell_str, tx, ty, tc[1], tc[2], tc[3], tc[4])

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

        end

        -- Sunken bevel (drawn AFTER items so highlights don't overwrite edges)
        draw_win32_bevel(x, y, avail_w, total_h, theme, "sunken")

        -- Fallback border for flat mode (bevel is no-op when not "windows")
        if theme.widget_style ~= "windows" then
            local bc = theme.colors.border
            Core.DrawRect(x, y, avail_w, total_h, bc[1], bc[2], bc[3], 0.3, false)
        end

        -- Scroll with wheel — notch-based step (opts.scroll_step rows per notch)
        if #rows > max_visible then
            local wheel_area = Core.MouseInRect(x, y, avail_w, total_h)
            if wheel_area and not Core.HasPopup() and not Core.IsWheelConsumed() then
                local state = Core.GetState()
                if state.mouse_wheel ~= 0 then
                    local step = opts.scroll_step or 3
                    local dir = state.mouse_wheel > 0 and -1 or 1
                    data.scroll_y = max(0, min(data.scroll_y + dir * step, #rows - visible_rows))
                    -- Consumed (audit B4): otherwise the parent scrolls too
                    Core.ConsumeWheel()
                end
            end
        else
            data.scroll_y = 0
        end
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
    local mx = floor((win_w - w) / 2)
    local my = floor((win_h - h) / 2)
    local pad = theme.window_padding

    -- Block input to everything outside the modal (audit B12: widgets behind
    -- the dimmed overlay used to stay clickable). Core fails hit-tests
    -- outside the Enter/Leave scope for this frame and the next one.
    Core.EnterModalScope()

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
        Core.DrawText(title, mx + pad, my + floor((theme.tab_height - th) / 2),
            tc[1], tc[2], tc[3], tc[4])
        my = my + theme.tab_height
        h = h - theme.tab_height
    end

    -- Push a pooled container for modal content (audit P8: a ~20-field table
    -- plus an id concat used to be allocated every frame the modal was open)
    local md = Core.GetWidgetSubData("modal", id)
    if not md.cid then
        md.cid = "modal_" .. id
        md.c = {}
    end
    local c = md.c
    for k in pairs(c) do c[k] = nil end
    c.id = md.cid
    c.x = mx; c.y = my; c.w = w; c.h = h
    c.pad_x = pad; c.pad_y = pad
    c.cursor_x = pad; c.cursor_y = pad
    c.content_h = 0; c.scroll_y = 0
    c.scrollable = false
    c.same_line = false; c.same_line_x = 0
    c.max_row_h = 0; c.spacing = theme.item_spacing
    c.indent_x = 0; c.sameline_pending = false
    c.last_widget_end_x = pad; c.last_widget_y = pad; c.last_widget_h = 0
    Core.PushContainer(c)
    Core.PushClipRect(mx, my, w, h)
end

function Widgets.EndModal()
    Core.PopClipRect()
    Core.PopContainer()
    Core.LeaveModalScope()
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
        if not drag_state.active and (abs(dx) > 3 or abs(dy) > 3) then
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

-- Drag ghost drawn via the tooltip layer. Module-level function + stashed
-- theme: no closure allocation per drag frame.
local function _draw_drag_preview()
    local theme = drag_state.theme
    if not theme then return end
    local text = drag_state.text
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
    drag_state.theme = theme
    Core.SetTooltip(_draw_drag_preview)
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

-- Reused rect for ContextMenu's "item" scope (no per-call table)
local _cm_rect = { 0, 0, 0, 0 }

-- ============================================================================
-- CONTEXT MENU (right-click popup)
-- ============================================================================
-- Call after a widget or area. Shows on right-click.
-- items = { {label="Cut", action=fn}, {label="Copy"}, {separator=true}, ... }
-- Returns: true if an item was clicked (action already called)
-- opts (audit B10):
--   rect = {x, y, w, h} → only open when the right-click lands inside
--   scope = "item"      → only open on the last submitted widget's rect
--   (default: whole window, previous behavior)
-- item.shortcut is DISPLAY-ONLY — dispatching the key combo is the caller's
-- job (the toolkit has no global accelerator table).
function Widgets.ContextMenu(id, items, theme, opts)
    -- Open on right-click. Never over an already-open popup (the old code
    -- hijacked/overwrote any live popup, and the click that closed the menu
    -- immediately reopened it).
    if Core.MouseClicked(2) and not Core.HasPopup() then
        if opts then
            local r
            if opts.rect then
                r = opts.rect
            elseif opts.scope == "item" then
                local ix, iy, iw, ih = Core.GetLastItemRect()
                if iw > 0 then
                    _cm_rect[1], _cm_rect[2], _cm_rect[3], _cm_rect[4] = ix, iy, iw, ih
                    r = _cm_rect
                end
            end
            if r and not Core.MouseInRect(r[1], r[2], r[3], r[4]) then
                return
            end
        end
        local mx, my = Core.GetMousePos()
        local item_h = theme.combo_height
        local menu_w = 0

        -- Calculate menu width (label + gap + shortcut + padding)
        for _, item in ipairs(items) do
            if not item.separator then
                local label_w = Core.MeasureText(item.label or "")
                local shortcut_w = item.shortcut and Core.MeasureText(item.shortcut) or 0
                local gap = shortcut_w > 0 and 32 or 0  -- gap between label and shortcut
                menu_w = max(menu_w, label_w + gap + shortcut_w + 20)
            end
        end

        -- Count visible items
        local visible_items = 0
        for _, item in ipairs(items) do
            visible_items = visible_items + (item.separator and 0.3 or 1)
        end
        local menu_h = floor(visible_items * item_h)

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
                    local sep_h = floor(item_h * 0.3)
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
                    local text_y = iy + floor((item_h - text_h) / 2)
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

            -- Close on Escape (consumed so the window doesn't close too)
            if Core.GetChar() == 27 then
                Core.ClearPopup(id)
                Core.ConsumeChar()
            end
        end)
    end
end

-- ============================================================================
-- NATIVE MENU (gfx.showmenu wrapper — F11)
-- ============================================================================
-- Nested submenus, checkmarks and disabled items for free via the OS menu
-- (zero per-frame render cost, blocking while open). The pragmatic choice
-- for deep menus; ContextMenu stays the theme-styled flat alternative.
--
-- items = {
--   { label = "Cut", action = fn },
--   { label = "Paste", disabled = true },
--   { separator = true },
--   { label = "Send to", children = { { label = "Bus 1" }, ... } },
--   { label = "Enabled", checked = true },
-- }
-- Returns: selected item table (or nil). Runs item.action() when present.
function Widgets.NativeMenu(items, x, y)
    local parts = {}
    local flat = {}  -- selectable-slot index → item (leaves + disabled leaves)

    local function emit(list)
        for _, it in ipairs(list) do
            if it.separator then
                parts[#parts + 1] = ""
            elseif it.children then
                local prefix = it.disabled and "#>" or ">"
                parts[#parts + 1] = prefix .. (it.label or "")
                emit(it.children)
                -- "<" closes the submenu: it prefixes the submenu's LAST entry
                parts[#parts] = "<" .. parts[#parts]
            else
                local prefix = ""
                if it.disabled then prefix = prefix .. "#" end
                if it.checked then prefix = prefix .. "!" end
                parts[#parts + 1] = prefix .. (it.label or "")
                flat[#flat + 1] = it
            end
        end
    end
    emit(items)

    gfx.x = x or gfx.mouse_x
    gfx.y = y or gfx.mouse_y
    local sel = gfx.showmenu(table.concat(parts, "|"))
    if sel and sel > 0 then
        local it = flat[sel]
        if it then
            if it.action then it.action() end
            return it
        end
    end
    return nil
end

-- Simple horizontal menu bar built on NativeMenu.
-- menus = { { label = "File", items = {NativeMenu items} }, ... }
-- Returns: selected item table (or nil), menu index
function Widgets.MenuBar(id, menus, theme)
    local x, y = Layout.GetCursorPos()
    local h = theme.tab_height
    local avail_w = Layout.GetAvailableWidth()
    local result, result_menu = nil, nil

    -- Bar background
    local hbg = theme.colors.header
    Core.DrawRect(x, y, avail_w, h, hbg[1], hbg[2], hbg[3], hbg[4])

    local mx = x
    local disabled = Core.IsDisabled()
    for i, menu in ipairs(menus) do
        local tw, th = Core.MeasureText(menu.label)
        local bw = tw + theme.frame_padding_x * 2
        local hovered = (not disabled)
            and Core.MouseInClippedRect(mx, y, bw, h)
            and not Core.HasPopup()

        if hovered then
            local hc = theme.colors.header_hovered
            Core.DrawRect(mx, y, bw, h, hc[1], hc[2], hc[3], hc[4])
        end

        local tc = disabled and theme.colors.text_disabled or theme.colors.text
        Core.DrawText(menu.label, mx + theme.frame_padding_x,
            y + floor((h - th) / 2), tc[1], tc[2], tc[3], tc[4])

        if hovered and Core.MouseClicked(1) then
            result = Widgets.NativeMenu(menu.items, mx, y + h)
            result_menu = i
        end

        mx = mx + bw
    end

    Layout.AdvanceCursor(avail_w, h)
    return result, result_menu
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

-- Selection helpers, module-level (audit P13: these were declared as four
-- closures INSIDE InputText on every focused frame).
local function input_get_sel(data)
    if data.sel_start == nil then return nil end
    return min(data.sel_start, data.cursor), max(data.sel_start, data.cursor)
end

-- Delete the selection from `text`. Returns the new text, or nil if there
-- was no selection.
local function input_del_sel(data, text)
    local s, e = input_get_sel(data)
    if not s then return nil end
    local out = text:sub(1, s) .. text:sub(e + 1)
    data.cursor = s
    data.sel_start = nil
    return out
end

-- Insert `str` at the cursor (replacing any selection). Returns the new text.
local function input_insert(data, text, str)
    local deleted = input_del_sel(data, text)
    if deleted then text = deleted end
    local out = text:sub(1, data.cursor) .. str .. text:sub(data.cursor + 1)
    data.cursor = data.cursor + #str
    return out
end

-- Undo snapshot (F12: Ctrl+Z / Ctrl+Y): push the CURRENT state before a
-- mutation. Coalesced by time so a burst of typing forms one undo step;
-- bounded stack. Event-driven — runs only on keystrokes.
local function input_push_undo(data, text)
    local now = reaper.time_precise()
    local stack = data._undo
    if not stack then stack = {}; data._undo = stack end
    if data._undo_time and (now - data._undo_time) < 0.4 and #stack > 0 then
        data._undo_time = now
        return  -- coalesce with the previous snapshot
    end
    data._undo_time = now
    if #stack >= 64 then table.remove(stack, 1) end
    stack[#stack + 1] = { text, data.cursor }
    data._redo = nil  -- a new edit invalidates the redo chain
end

function Widgets.InputText(id, label, text, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()

    -- width = -1 → fill (alias for nil). Positive number = fixed width.
    local fixed_w = opts.width
    if fixed_w == -1 then fixed_w = nil end

    local tw, th = 0, 0
    if label and label ~= "" then
        tw, th = Core.MeasureText(label)
    end
    local label_gap = (tw > 0) and 8 or 0
    -- Truncate label so widget never overflows container.
    if tw > 0 then
        local reserved_w = fixed_w or 40
        local max_label_w = max(0, avail_w - reserved_w - label_gap)
        if tw > max_label_w then
            label, tw = Core.TruncateText(label, max_label_w)
        end
    end
    local input_w = fixed_w or max(20, avail_w - tw - label_gap)
    local h = opts.height or theme.combo_height
    local total_w = input_w + (tw > 0 and (tw + label_gap) or 0)
    local pad = theme.frame_padding_x

    local ix = x + (tw > 0 and (tw + 8) or 0)
    local iy = y

    local data = Core.GetWidgetSubData("input", id)
    if data._init == nil then
        data.cursor = #text
        data.sel_start = nil
        data.scroll_x = 0
        data.blink_time = 0
        data._init = true
    end

    local disabled = opts.disabled or Core.IsDisabled()
    local changed = false
    local submitted = false  -- true on the frame Enter is pressed
    local new_text = text
    local is_focused = not disabled and Core.IsFocused(id)
    local current_text = text  -- track working copy

    -- Track focus across frames (Core.Run clears state.focus on every click
    -- before widgets run, so Core.IsFocused is unreliable for "was I focused
    -- BEFORE this click?" — we need our own per-widget tracking).
    local was_focused_prev = data._was_focused or false

    -- Click to focus
    local hovered = not disabled and Core.MouseInClippedRect(ix, iy, input_w, h) and not Core.HasPopup()

    if hovered then
        Core.SetHot(id)
        Core.SetCursor("ibeam")
        if Core.MouseClicked(1) then
            Core.SetFocus(id)
            Core.SetActive(id)
            is_focused = true

            if not was_focused_prev and opts.select_all_on_focus ~= false then
                -- First click on unfocused input → select all (Windows native)
                data.sel_start = 0
                data.cursor = #text
                data._focus_click = true  -- block drag until mouse released
            else
                -- Already focused → position cursor normally. Raw
                -- gfx.measurestr: one-shot prefix probes must not fill the
                -- measure cache (audit P13).
                local click_x = Core.GetState().mouse_x - ix + data.scroll_x - pad
                local pos = 0
                for i = 1, #text do
                    if gfx.measurestr(text:sub(1, i)) > click_x then break end
                    pos = i
                end
                data.cursor = pos
                data.sel_start = nil
                data._focus_click = false
            end
            data.blink_time = reaper.time_precise()
        end
    end

    -- Double-click to select all
    if hovered and Core.MouseDoubleClicked() and is_focused then
        data.sel_start = 0
        data.cursor = #text
    end

    -- Drag to select (blocked on the focus-gaining click to preserve
    -- select-all). Only recompute the character hit when the mouse actually
    -- moved (audit P13: this O(#text) prefix loop used to run every frame of
    -- a held button, even with the mouse perfectly still).
    if Core.IsActive(id) and Core.MouseDown(1) and is_focused and not data._focus_click then
        local mx = Core.GetState().mouse_x
        if mx ~= data._drag_mx then
            data._drag_mx = mx
            local click_x = mx - ix + data.scroll_x - pad
            local pos = 0
            for i = 1, #text do
                if gfx.measurestr(text:sub(1, i)) > click_x then break end
                pos = i
            end
            if data.sel_start == nil then data.sel_start = data.cursor end
            data.cursor = pos
        end
    end

    if Core.IsActive(id) and Core.MouseReleased(1) then
        Core.ClearActive()
        data._focus_click = false
        if data.sel_start == data.cursor then data.sel_start = nil end
    end

    -- Keyboard input. Selection/undo helpers are module-level (audit P13);
    -- text mutations go through a small undo stack (F12: Ctrl+Z / Ctrl+Y).
    if is_focused and Keys then
        local char = Core.GetChar()

        if char == Keys.BACKSPACE then
            input_push_undo(data, current_text)
            local d = input_del_sel(data, current_text)
            if d then
                new_text = d; current_text = d; changed = true
            elseif data.cursor > 0 then
                local p = utf8_prev(current_text, data.cursor)
                new_text = current_text:sub(1, p) .. current_text:sub(data.cursor + 1)
                current_text = new_text
                data.cursor = p
                changed = true
            end
            data.blink_time = reaper.time_precise()

        elseif char == Keys.DELETE then
            input_push_undo(data, current_text)
            local d = input_del_sel(data, current_text)
            if d then
                new_text = d; current_text = d; changed = true
            elseif data.cursor < #current_text then
                local n = utf8_next(current_text, data.cursor)
                new_text = current_text:sub(1, data.cursor) .. current_text:sub(n + 1)
                current_text = new_text
                changed = true
            end
            data.blink_time = reaper.time_precise()

        elseif char == Keys.LEFT then
            data.sel_start = nil
            if data.cursor > 0 then data.cursor = utf8_prev(current_text, data.cursor) end
            data.blink_time = reaper.time_precise()

        elseif char == Keys.RIGHT then
            data.sel_start = nil
            if data.cursor < #current_text then data.cursor = utf8_next(current_text, data.cursor) end
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
            -- Enter is treated as "submit"; Tab as "next field". Both clear focus.
            if char == Keys.ENTER then submitted = true end
            Core.SetFocus(nil)
            is_focused = false
            data.was_focused = false

        elseif char == 1 then  -- Ctrl+A
            data.sel_start = 0
            data.cursor = #current_text

        elseif char == 3 then  -- Ctrl+C
            local s, e = input_get_sel(data)
            if s then clipboard_set(current_text:sub(s + 1, e)) end

        elseif char == 24 then  -- Ctrl+X
            local s, e = input_get_sel(data)
            if s then
                clipboard_set(current_text:sub(s + 1, e))
                input_push_undo(data, current_text)
                local d = input_del_sel(data, current_text)
                if d then new_text = d; current_text = d; changed = true end
            end
            data.blink_time = reaper.time_precise()

        elseif char == 22 then  -- Ctrl+V
            local clip = clipboard_get()
            if clip ~= "" then
                -- Remove newlines from pasted text
                clip = clip:gsub("[\r\n]", " ")
                input_push_undo(data, current_text)
                data._undo_time = nil  -- don't coalesce typing into a paste
                new_text = input_insert(data, current_text, clip)
                current_text = new_text
                changed = true
            end
            data.blink_time = reaper.time_precise()

        elseif char == 26 then  -- Ctrl+Z (undo)
            local stack = data._undo
            if stack and #stack > 0 then
                local snap = table.remove(stack)
                local redo = data._redo
                if not redo then redo = {}; data._redo = redo end
                redo[#redo + 1] = { current_text, data.cursor }
                new_text = snap[1]
                current_text = new_text
                data.cursor = min(snap[2], #new_text)
                data.sel_start = nil
                changed = true
                data._undo_time = nil
            end
            data.blink_time = reaper.time_precise()

        elseif char == 25 then  -- Ctrl+Y (redo)
            local redo = data._redo
            if redo and #redo > 0 then
                local snap = table.remove(redo)
                local stack = data._undo
                if not stack then stack = {}; data._undo = stack end
                stack[#stack + 1] = { current_text, data.cursor }
                new_text = snap[1]
                current_text = new_text
                data.cursor = min(snap[2], #new_text)
                data.sel_start = nil
                changed = true
                data._undo_time = nil
            end
            data.blink_time = reaper.time_precise()

        elseif char >= 32 and char < 0x2000 then
            -- Printable range; REAPER's named keys are int codes ≥ 0x2000.
            -- UTF-8 encode (audit B13: string.char broke accented input).
            input_push_undo(data, current_text)
            new_text = input_insert(data, current_text, char_to_utf8(char))
            current_text = new_text
            changed = true
            data.blink_time = reaper.time_precise()
        end

        -- Keys handled here must not reach Core.Run's close logic; an
        -- unconsumed ESC intentionally falls through (Core unfocuses on it).
        if char > 0 and char ~= 27 then Core.ConsumeChar() end

        -- Schedule caret-blink wakeups (audit P2: focus no longer blocks the
        -- idle throttle — redraws are deadline-scheduled instead)
        Core.ScheduleBlinkRedraw(data.blink_time)
    end

    -- Auto-scroll to keep cursor visible. The cursor's pixel offset is
    -- cached per (text, cursor) — audit P13: this prefix measurement used to
    -- run every focused frame and leak prefixes into the measure cache.
    local display_text = changed and new_text or text
    local cursor_px = 0
    if is_focused then
        if data._cpx_text == display_text and data._cpx_cur == data.cursor then
            cursor_px = data._cpx
        else
            cursor_px = gfx.measurestr(display_text:sub(1, data.cursor))
            data._cpx_text = display_text
            data._cpx_cur = data.cursor
            data._cpx = cursor_px
        end
        local visible_w = input_w - pad * 2
        if cursor_px - data.scroll_x > visible_w then
            data.scroll_x = cursor_px - visible_w + 10
        elseif cursor_px - data.scroll_x < 0 then
            data.scroll_x = max(0, cursor_px - 10)
        end
    else
        data.scroll_x = 0  -- reset scroll when not focused
    end

    -- Draw
    if Core.IsVisible(x, y, total_w, h) then
        -- Label
        if tw > 0 then
            local lc = disabled and theme.colors.text_disabled or theme.colors.text
            local ly = y + floor((h - th) / 2)
            Core.DrawText(label, x, ly, lc[1], lc[2], lc[3], lc[4])
        end

        -- Input background
        local bg
        if disabled then
            bg = theme.colors.window_bg
        elseif is_focused then
            bg = theme.colors.frame_active
        elseif hovered then
            bg = theme.colors.frame_hovered
        else
            bg = theme.colors.frame_bg
        end
        Core.DrawRect(ix, iy, input_w, h, bg[1], bg[2], bg[3], bg[4])

        -- Sunken bevel (windows) or nothing (flat)
        draw_win32_bevel(ix, iy, input_w, h, theme, "sunken")

        -- Render text content into offscreen buffer for proper clipping
        local vis_w = input_w - pad * 2
        local vis_h = h - 4  -- leave 2px top + 2px bottom for bevel edges
        local _, char_h = Core.MeasureText("M")
        local text_y_off = floor((vis_h - char_h) / 2)

        -- Setup offscreen buffer — resize only when the SHARED buffer's real
        -- dimensions change (audit B1: the guard used to live in per-widget
        -- data, corrupting rendering with two inputs of different sizes).
        gfx.dest = INPUT_BUFFER_ID
        if input_buf_w ~= vis_w or input_buf_h ~= vis_h then
            gfx.setimgdim(INPUT_BUFFER_ID, vis_w, vis_h)
            input_buf_w = vis_w
            input_buf_h = vis_h
        end
        -- Single opaque background fill (audit P14: an opaque black fill was
        -- painted first and immediately covered by this one — pure fillrate
        -- waste). Alpha forced to 1: the buffer must start fully opaque.
        gfx.set(bg[1], bg[2], bg[3], 1)
        gfx.rect(0, 0, vis_w, vis_h, 1)

        -- Draw selection highlight in buffer (raw gfx.measurestr: selection
        -- prefixes are transient, they must not fill the measure cache)
        if is_focused and data.sel_start ~= nil then
            local s = min(data.sel_start, data.cursor)
            local e = max(data.sel_start, data.cursor)
            local sel_x1 = gfx.measurestr(display_text:sub(1, s)) - data.scroll_x
            local sel_x2 = gfx.measurestr(display_text:sub(1, e)) - data.scroll_x
            local ac = theme.colors.accent
            gfx.set(ac[1], ac[2], ac[3], 0.35)
            gfx.rect(sel_x1, 2, sel_x2 - sel_x1, vis_h - 4, 1)
        end

        -- Draw text in buffer
        local show_text = (#display_text > 0) and display_text or (opts.hint or "")
        local tc = disabled and theme.colors.text_disabled
                   or ((#display_text > 0) and theme.colors.text or theme.colors.text_disabled)
        gfx.set(tc[1], tc[2], tc[3], tc[4])
        gfx.x = -data.scroll_x
        gfx.y = text_y_off
        gfx.drawstr(show_text)

        -- Draw cursor in buffer (cursor_px cached above)
        if is_focused then
            local elapsed = reaper.time_precise() - data.blink_time
            if elapsed % Core.BLINK_PERIOD < Core.BLINK_ON then
                gfx.set(tc[1], tc[2], tc[3], 0.9)
                gfx.rect(cursor_px - data.scroll_x, 3, 1, vis_h - 6, 1)
            end
        end

        -- Blit buffer to screen (this clips perfectly)
        gfx.dest = -1
        gfx.blit(INPUT_BUFFER_ID, 1, 0, 0, 0, vis_w, vis_h, ix + pad, iy + 2)

        -- Windows-style focus accent line at bottom edge
        if is_focused and theme.widget_style == "windows" then
            local ac = theme.colors.accent
            Core.DrawRect(ix, iy + h - 2, input_w, 2, ac[1], ac[2], ac[3], ac[4])
        end
    end

    data._was_focused = is_focused

    Layout.AdvanceCursor(total_w, h)
    return changed, changed and new_text or text, submitted
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

    -- Normalize mouse position to 0-1 (clamped, even when dragging outside canvas)
    local norm_x, norm_y
    if hovered or dragging then
        norm_x = max(0, min(1, (mouse_x - x) / w))
        norm_y = max(0, min(1, (mouse_y - y) / h))
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

    -- Reused result table (audit P9: a fresh 12-field table per frame for a
    -- widget that is typically always on screen). The table is owned by the
    -- widget and overwritten on the next call — copy fields if you keep it.
    local cd = Core.GetWidgetSubData("canvas", id)
    local res = cd.result
    if not res then res = {}; cd.result = res end
    res.x = x; res.y = y; res.w = w; res.h = h
    res.hovered = hovered
    res.clicked = clicked
    res.right_clicked = right_clicked
    res.dragging = dragging
    res.norm_x = norm_x
    res.norm_y = norm_y
    res.mouse_x = mouse_x
    res.mouse_y = mouse_y
    return res
end

-- ============================================================================
-- TOGGLE BUTTON (ON/OFF visual, distinct from checkbox)
-- ============================================================================
function Widgets.ToggleButton(id, label, is_on, theme, opts)
    opts = opts or {}
    local tw, th = Core.MeasureText(label)
    local fp_x = theme.frame_padding_x
    local w = opts.width or (tw + fp_x * 2)
    if w == -1 then w = Layout.GetAvailableWidth() end
    local h = opts.height or theme.button_height

    if Layout.IsWrapping() then Layout.WrapPreCheck(w) end
    local x, y = Layout.GetCursorPos()

    local toggled = false
    local disabled = opts.disabled or Core.IsDisabled()
    local hovered = (not disabled)
        and Core.MouseInClippedRect(x, y, w, h)
        and not Core.HasPopup()

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
        local dim = disabled and 0.5 or 1
        Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], (bg[4] or 1) * dim)

        -- Bevel: ON = sunken (pressed), OFF = raised (like a button)
        if not disabled then
            draw_win32_bevel(x, y, w, h, theme, new_on and "sunken" or "raised")
        end

        -- Text
        local tc
        if disabled then tc = theme.colors.text_disabled
        elseif new_on then tc = COLOR_WHITE
        else tc = theme.colors.text end
        local tx = x + floor((w - tw) / 2)
        local ty = y + floor((h - th) / 2)
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

    -- width = -1 → fill (alias for nil).
    local fixed_w = opts.width
    if fixed_w == -1 then fixed_w = nil end

    local tw, th = 0, 0
    if label and label ~= "" then
        tw, th = Core.MeasureText(label)
    end
    local has_label = tw > 0
    local label_gap = has_label and 8 or 0

    -- Truncate label so range slider never overflows container.
    if has_label then
        local reserved_w = fixed_w or 40
        local max_label_w = max(0, avail_w - reserved_w - label_gap)
        if tw > max_label_w then
            label, tw = Core.TruncateText(label, max_label_w)
        end
    end
    local slider_w = fixed_w or max(20, avail_w - tw - label_gap)
    local h = opts.height or theme.slider_height
    local total_w = slider_w + (has_label and (tw + label_gap) or 0)

    local sx = x + (has_label and (tw + label_gap) or 0)
    local sy = y + floor((max(h, th) - h) / 2)

    local changed = false
    local new_min = val_min
    local new_max = val_max

    -- Two grab handles + middle drag zone (translate the whole range).
    local range = range_max - range_min
    local ratio_min = (val_min - range_min) / range
    local ratio_max = (val_max - range_min) / range
    local grab_w = 8
    local edge_zone = grab_w  -- pixels around each handle that count as "grab handle"

    local min_px = sx + floor(ratio_min * slider_w)
    local max_px = sx + floor(ratio_max * slider_w)

    local hovered = Core.MouseInClippedRect(sx, sy, slider_w, h) and not Core.HasPopup()
    if hovered then Core.SetHot(id) end

    -- Cache the click anchor for middle-drag so the range translates by the
    -- absolute mouse delta from press, not relative to the current position
    -- (avoids drift when clamped against 0 or 1).
    local rd = Core.GetWidgetSubData("rslider", id)

    -- Three drag modes: min handle, max handle, middle (translate both).
    -- Ids cached once (audit P9: three string concats per frame).
    if not rd.id_min then
        rd.id_min = id .. "_min"
        rd.id_max = id .. "_max"
        rd.id_mid = id .. "_mid"
    end
    local drag_id_min = rd.id_min
    local drag_id_max = rd.id_max
    local drag_id_mid = rd.id_mid

    if hovered and Core.MouseClicked(1) then
        local mx = Core.GetState().mouse_x
        local dist_min = abs(mx - min_px)
        local dist_max = abs(mx - max_px)
        local in_middle = (mx > min_px + edge_zone) and (mx < max_px - edge_zone)
            and (max_px - min_px > edge_zone * 2)

        if in_middle then
            Core.SetActive(drag_id_mid)
            rd.drag_anchor_mx = mx
            rd.drag_anchor_min = val_min
            rd.drag_anchor_max = val_max
        elseif dist_min <= dist_max then
            Core.SetActive(drag_id_min)
        else
            Core.SetActive(drag_id_max)
        end
    end

    -- Drag min handle
    if Core.IsActive(drag_id_min) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local ratio = max(0, min(ratio_max, (mx - sx) / slider_w))
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
            local ratio = max(ratio_min, min(1, (mx - sx) / slider_w))
            new_max = range_min + ratio * range
            if new_max ~= val_max then changed = true end
        else
            Core.ClearActive()
        end
    end

    -- Drag middle: translate both endpoints by the same amount, clamped to
    -- [range_min, range_max]. The width (max - min) is preserved.
    if Core.IsActive(drag_id_mid) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local anchor_mx = rd.drag_anchor_mx or mx
            local anchor_min = rd.drag_anchor_min or val_min
            local anchor_max = rd.drag_anchor_max or val_max
            local span = anchor_max - anchor_min
            local delta_ratio = (mx - anchor_mx) / slider_w
            local delta_val = delta_ratio * range
            local target_min = anchor_min + delta_val
            -- Clamp without shrinking the span.
            if target_min < range_min then target_min = range_min end
            if target_min + span > range_max then target_min = range_max - span end
            local target_max = target_min + span
            if target_min ~= val_min or target_max ~= val_max then
                new_min = target_min
                new_max = target_max
                changed = true
            end
        else
            Core.ClearActive()
            rd.drag_anchor_mx = nil
            rd.drag_anchor_min = nil
            rd.drag_anchor_max = nil
        end
    end

    -- Recalc positions after potential change
    if changed then
        ratio_min = (new_min - range_min) / range
        ratio_max = (new_max - range_min) / range
        min_px = sx + floor(ratio_min * slider_w)
        max_px = sx + floor(ratio_max * slider_w)
    end

    -- Cursor feedback while hovering or dragging.
    if hovered or Core.IsActive(drag_id_min) or Core.IsActive(drag_id_max)
       or Core.IsActive(drag_id_mid) then
        if Core.IsActive(drag_id_mid) then
            Core.SetCursor("size_all")
        elseif hovered and not Core.IsActive(drag_id_min) and not Core.IsActive(drag_id_max) then
            local mx = Core.GetState().mouse_x
            local in_middle = (mx > min_px + edge_zone) and (mx < max_px - edge_zone)
                and (max_px - min_px > edge_zone * 2)
            Core.SetCursor(in_middle and "size_all" or "size_we")
        else
            Core.SetCursor("size_we")
        end
    end

    -- Draw
    if Core.IsVisible(x, y, total_w, max(h, th)) then
        -- Label
        if tw > 0 then
            local tc = theme.colors.text
            local ly = y + floor((max(h, th) - th) / 2)
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
        local min_grab_x = max(sx, min_px - grab_w / 2)
        local mc = Core.IsActive(drag_id_min) and theme.colors.accent_active or
                   (hovered and theme.colors.accent_hovered or theme.colors.accent)
        Core.DrawRect(min_grab_x, sy, grab_w, h, mc[1], mc[2], mc[3], mc[4])

        -- Max handle
        local max_grab_x = min(sx + slider_w - grab_w, max_px - grab_w / 2)
        local xc = Core.IsActive(drag_id_max) and theme.colors.accent_active or
                   (hovered and theme.colors.accent_hovered or theme.colors.accent)
        Core.DrawRect(max_grab_x, sy, grab_w, h, xc[1], xc[2], xc[3], xc[4])

        -- Value display — cache compound format and final string in widget data
        -- (only re-format when min/max values or format change).
        local format = opts.format or "%.1f"
        if rd._fmt_src ~= format then
            rd._fmt_src = format
            rd._fmt = format .. " - " .. format
        end
        local disp_min = changed and new_min or val_min
        local disp_max = changed and new_max or val_max
        local val_str
        -- Format is part of the cache key (audit: switching opts.format at
        -- runtime — dB/Hz toggle — used to show the stale string forever)
        if rd.fv_min == disp_min and rd.fv_max == disp_max
           and rd.fv_fmt == format and rd.fv_str then
            val_str = rd.fv_str
        else
            val_str = string.format(rd._fmt, disp_min, disp_max)
            rd.fv_min = disp_min
            rd.fv_max = disp_max
            rd.fv_fmt = format
            rd.fv_str = val_str
        end
        local vw, vh = Core.MeasureText(val_str)
        local vx = sx + floor((slider_w - vw) / 2)
        local vy = sy + floor((h - vh) / 2)
        local tc = theme.colors.text
        Core.DrawText(val_str, vx, vy, tc[1], tc[2], tc[3], tc[4])
    end

    Layout.AdvanceCursor(total_w, max(h, th))
    return changed, changed and new_min or val_min, changed and new_max or val_max
end

-- Normalized-position helpers for ValueRangeSlider, module-level (audit P9:
-- two closures used to be created per widget per frame).
local function vrs_ratio(v, range_min, span)
    return (v - range_min) / span
end
local function vrs_unratio(r, range_min, span)
    if r < 0 then r = 0 elseif r > 1 then r = 1 end
    return range_min + r * span
end

-- ============================================================================
-- VALUE RANGE SLIDER (range window + a draggable current-value point)
-- ============================================================================
-- A dual-thumb range slider with an additional "value" marker drawn as a
-- filled circle inside the range window. The value is constrained to the
-- range [val_min, val_max] (handles cannot pass through the value, and the
-- value is clamped if the range narrows around it).
--
-- Use cases:
--   • FX parameter rows where you want to see the live value AND the
--     randomization window in a single compact widget.
--
-- Interaction zones (priority left → right):
--   • Click on the value point  → drag the value (writes through callback).
--   • Click near min handle      → drag min only (cannot cross value).
--   • Click near max handle      → drag max only (cannot cross value).
--   • Click in the middle (away from value/handles) → translate the whole
--     range (value moves with it; span preserved, clamped to slider bounds).
--
-- Returns:
--   value_changed (bool), new_value,
--   range_changed (bool), new_val_min, new_val_max
function Widgets.ValueRangeSlider(id, label, value, val_min, val_max,
                                  range_min, range_max, theme, opts)
    opts = opts or {}
    local x, y = Layout.GetCursorPos()
    local avail_w = Layout.GetAvailableWidth()

    local fixed_w = opts.width
    if fixed_w == -1 then fixed_w = nil end

    local tw, th = 0, 0
    if label and label ~= "" then
        tw, th = Core.MeasureText(label)
    end
    local has_label = tw > 0
    local label_gap = has_label and 8 or 0

    if has_label then
        local reserved_w = fixed_w or 40
        local max_label_w = max(0, avail_w - reserved_w - label_gap)
        if tw > max_label_w then
            label, tw = Core.TruncateText(label, max_label_w)
        end
    end
    local slider_w = fixed_w or max(20, avail_w - tw - label_gap)
    local h = opts.height or theme.slider_height
    local total_w = slider_w + (has_label and (tw + label_gap) or 0)

    local sx = x + (has_label and (tw + label_gap) or 0)
    local sy = y + floor((max(h, th) - h) / 2)

    -- Sanitize and clamp the model
    local span = range_max - range_min
    if span <= 0 then span = 1 end

    -- Force the invariants val_min ≤ value ≤ val_max
    if val_min > val_max then val_min, val_max = val_max, val_min end
    if value < val_min then value = val_min end
    if value > val_max then value = val_max end

    local r_min  = (val_min - range_min) / span
    local r_max  = (val_max - range_min) / span
    local r_val  = (value - range_min) / span

    local new_min   = val_min
    local new_max   = val_max
    local new_value = value

    local value_changed = false
    local range_changed = false

    local handle_w   = 8                 -- min/max grab handle width
    local edge_zone  = handle_w          -- pixel zone counted as "on the handle"
    -- Small dot — just a marker for the current value, not a grab knob.
    -- The dot stays out of the way so the user can still read the min/max
    -- range fill underneath.
    local value_r    = max(2, floor(h * 0.18))

    local min_px = sx + floor(r_min * slider_w)
    local max_px = sx + floor(r_max * slider_w)
    local val_px = sx + floor(r_val * slider_w)

    local hovered = Core.MouseInClippedRect(sx, sy, slider_w, h)
                    and not Core.HasPopup()
    if hovered then Core.SetHot(id) end

    local rd = Core.GetWidgetSubData("vrslider", id)

    -- Drag IDs (one per interaction zone), cached once (audit P9: four
    -- string concats per widget per frame)
    if not rd.id_min then
        rd.id_min = id .. "_min"
        rd.id_max = id .. "_max"
        rd.id_mid = id .. "_mid"
        rd.id_val = id .. "_val"
    end
    local id_min = rd.id_min
    local id_max = rd.id_max
    local id_mid = rd.id_mid
    local id_val = rd.id_val

    -- ---- Click → pick the right interaction --------------------------------
    if hovered and Core.MouseClicked(1) then
        local mx = Core.GetState().mouse_x

        -- Priority: value dot first. Hit test is generous (5 px around the
        -- dot) so the user can grab it even though the visual is tiny.
        local value_hit = max(value_r, 5)
        local on_value = abs(mx - val_px) <= value_hit
        local on_min   = abs(mx - min_px) <= edge_zone
        local on_max   = abs(mx - max_px) <= edge_zone

        if on_value then
            Core.SetActive(id_val)
        elseif on_min and (not on_max or abs(mx - min_px) <= abs(mx - max_px)) then
            Core.SetActive(id_min)
        elseif on_max then
            Core.SetActive(id_max)
        else
            -- Empty zone inside the range → translate the whole window
            local in_middle = (mx > min_px + edge_zone) and (mx < max_px - edge_zone)
                              and (max_px - min_px > edge_zone * 2)
            if in_middle then
                Core.SetActive(id_mid)
                rd.drag_anchor_mx  = mx
                rd.drag_anchor_min = val_min
                rd.drag_anchor_max = val_max
                rd.drag_anchor_val = value
            else
                -- Clicked in the empty track outside the range → snap nearest
                -- handle to the click (matches RangeSlider behaviour).
                local dist_min = abs(mx - min_px)
                local dist_max = abs(mx - max_px)
                if dist_min <= dist_max then
                    Core.SetActive(id_min)
                else
                    Core.SetActive(id_max)
                end
            end
        end
    end

    -- ---- Drag value -------------------------------------------------------
    if Core.IsActive(id_val) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local target = vrs_unratio((mx - sx) / slider_w, range_min, span)
            -- Clamp inside [val_min, val_max] (the range stays still)
            if target < val_min then target = val_min end
            if target > val_max then target = val_max end
            if target ~= value then
                new_value = target
                value_changed = true
            end
        else
            Core.ClearActive()
        end
    end

    -- ---- Drag min handle --------------------------------------------------
    if Core.IsActive(id_min) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local target = vrs_unratio((mx - sx) / slider_w, range_min, span)
            -- Min cannot cross the value (so the value never falls outside
            -- the range mid-drag).
            if target > value then target = value end
            if target < range_min then target = range_min end
            if target ~= val_min then
                new_min = target
                range_changed = true
            end
        else
            Core.ClearActive()
        end
    end

    -- ---- Drag max handle --------------------------------------------------
    if Core.IsActive(id_max) then
        if Core.MouseDown(1) then
            local mx = Core.GetState().mouse_x
            local target = vrs_unratio((mx - sx) / slider_w, range_min, span)
            if target < value then target = value end
            if target > range_max then target = range_max end
            if target ~= val_max then
                new_max = target
                range_changed = true
            end
        else
            Core.ClearActive()
        end
    end

    -- ---- Drag middle (translate range + value together) ------------------
    if Core.IsActive(id_mid) then
        if Core.MouseDown(1) then
            local mx       = Core.GetState().mouse_x
            local anc_mx   = rd.drag_anchor_mx  or mx
            local anc_min  = rd.drag_anchor_min or val_min
            local anc_max  = rd.drag_anchor_max or val_max
            local anc_val  = rd.drag_anchor_val or value
            local span_mm  = anc_max - anc_min
            local delta_v  = ((mx - anc_mx) / slider_w) * span
            local target_min = anc_min + delta_v
            -- Clamp without shrinking
            if target_min < range_min then target_min = range_min end
            if target_min + span_mm > range_max then
                target_min = range_max - span_mm
            end
            local target_max = target_min + span_mm
            local target_val = anc_val + (target_min - anc_min)  -- value follows

            if target_min ~= val_min or target_max ~= val_max then
                new_min, new_max = target_min, target_max
                range_changed = true
            end
            if target_val ~= value then
                new_value = target_val
                value_changed = true
            end
        else
            Core.ClearActive()
            rd.drag_anchor_mx, rd.drag_anchor_min = nil, nil
            rd.drag_anchor_max, rd.drag_anchor_val = nil, nil
        end
    end

    -- Recompute pixel positions if anything changed
    if value_changed or range_changed then
        r_min = vrs_ratio(new_min, range_min, span)
        r_max = vrs_ratio(new_max, range_min, span)
        r_val = vrs_ratio(new_value, range_min, span)
        min_px = sx + floor(r_min * slider_w)
        max_px = sx + floor(r_max * slider_w)
        val_px = sx + floor(r_val * slider_w)
    end

    -- ---- Cursor feedback --------------------------------------------------
    if hovered or Core.IsActive(id_min) or Core.IsActive(id_max)
       or Core.IsActive(id_mid) or Core.IsActive(id_val) then
        if Core.IsActive(id_val) then
            Core.SetCursor("size_we")
        elseif Core.IsActive(id_mid) then
            Core.SetCursor("size_all")
        elseif hovered then
            local mx = Core.GetState().mouse_x
            local value_hit = max(value_r, 5)
            if abs(mx - val_px) <= value_hit then
                Core.SetCursor("hand")
            elseif abs(mx - min_px) <= edge_zone or abs(mx - max_px) <= edge_zone then
                Core.SetCursor("size_we")
            else
                local in_middle = (mx > min_px + edge_zone) and (mx < max_px - edge_zone)
                                  and (max_px - min_px > edge_zone * 2)
                Core.SetCursor(in_middle and "size_all" or "size_we")
            end
        else
            Core.SetCursor("size_we")
        end
    end

    -- ---- Draw -------------------------------------------------------------
    if Core.IsVisible(x, y, total_w, max(h, th)) then
        -- Label
        if has_label then
            local tc = theme.colors.text
            local ly = y + floor((max(h, th) - th) / 2)
            Core.DrawText(label, x, ly, tc[1], tc[2], tc[3], tc[4])
        end

        -- Track
        local track_bg = hovered and theme.colors.frame_hovered or theme.colors.frame_bg
        Core.DrawRect(sx, sy, slider_w, h, track_bg[1], track_bg[2], track_bg[3], track_bg[4])
        draw_win32_bevel(sx, sy, slider_w, h, theme, "sunken")

        -- Range fill (translucent accent between handles)
        local ac = theme.colors.accent
        local fill_w = max_px - min_px
        if fill_w > 0 then
            Core.DrawRect(min_px, sy, fill_w, h, ac[1], ac[2], ac[3], 0.35)
        end

        -- Min / max handles
        local min_grab_x = max(sx, min_px - handle_w / 2)
        local max_grab_x = min(sx + slider_w - handle_w, max_px - handle_w / 2)
        local mc = Core.IsActive(id_min) and theme.colors.accent_active or
                   (hovered and theme.colors.accent_hovered or theme.colors.accent)
        Core.DrawRect(min_grab_x, sy, handle_w, h, mc[1], mc[2], mc[3], mc[4])
        local Mc = Core.IsActive(id_max) and theme.colors.accent_active or
                   (hovered and theme.colors.accent_hovered or theme.colors.accent)
        Core.DrawRect(max_grab_x, sy, handle_w, h, Mc[1], Mc[2], Mc[3], Mc[4])

        -- Value dot (drawn last so it sits on top of the range fill).
        -- Outline for contrast against the accent fill.
        local dot_y = sy + floor(h / 2)
        local dot_col = Core.IsActive(id_val) and theme.colors.text or
                        (hovered and theme.colors.text or theme.colors.text)
        local outline = theme.colors.window_bg
        Core.DrawCircle(val_px, dot_y, value_r + 1,
            outline[1], outline[2], outline[3], 1, true)
        Core.DrawCircle(val_px, dot_y, value_r,
            dot_col[1], dot_col[2], dot_col[3], 1, true)

        -- Value text — caller can override via opts.format (literal string).
        local format = opts.format
        if format then
            local vw, vh = Core.MeasureText(format)
            local vx = sx + floor((slider_w - vw) / 2)
            local vy = sy + floor((h - vh) / 2)
            local tc = theme.colors.text
            Core.DrawText(format, vx, vy, tc[1], tc[2], tc[3], tc[4])
        end
    end

    Layout.AdvanceCursor(total_w, max(h, th))
    return value_changed, value_changed and new_value or value,
           range_changed, range_changed and new_min or val_min,
           range_changed and new_max or val_max
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
    local visible_count = min(#items, max_visible)
    local h = visible_count * item_h
    local selected = opts.selected

    local data = Core.GetWidgetSubData("alist", id)
    if data._init == nil then
        data.scroll = 0
        data._init = true
    end

    -- Re-clamp scroll every frame (audit B14: a shrinking source — search
    -- filter — used to leave the view past the end: blank list until the
    -- next wheel tick, thumb off the track)
    data.scroll = max(0, min(data.scroll, max(0, #items - visible_count)))

    local clicked_item, clicked_action, activated_item = nil, nil, nil

    -- Multi-selection (F6): opts.selection = { [index] = true } set, mutated
    -- in place. Plain click = single select, Ctrl+click = toggle,
    -- Shift+click = range from the last plain click. opts.selected (single)
    -- keeps working as before when no set is passed.
    local sel_set = opts.selection

    -- Keyboard navigation (F2): opts.nav = true routes Up/Down/Enter to this
    -- list (the caller decides when — e.g. while its search box has focus).
    -- Up/Down report the new index through clicked_item (the caller updates
    -- its selection exactly like for a click); Enter reports activated_item.
    if opts.nav and Keys then
        local char = Core.GetChar()
        if char == Keys.UP or char == Keys.DOWN then
            local cur = selected or 0
            local nxt = max(1, min(#items, cur + (char == Keys.DOWN and 1 or -1)))
            if nxt ~= cur then
                clicked_item = nxt
                -- Scroll-to-selection
                if nxt - 1 < data.scroll then
                    data.scroll = nxt - 1
                elseif nxt > data.scroll + visible_count then
                    data.scroll = nxt - visible_count
                end
            end
            Core.ConsumeChar()
        elseif char == Keys.ENTER and selected then
            activated_item = selected
            Core.ConsumeChar()
        end
    end

    -- Action buttons total width — cached per actions table (audit: this
    -- O(actions) measure loop ran per frame, before the visibility test)
    local action_total_w = 0
    if actions then
        if data._actions_ref == actions and data._actions_w then
            action_total_w = data._actions_w
        else
            for _, act in ipairs(actions) do
                local aw = Core.MeasureText(act.icon or "?") + theme.frame_padding_x * 2
                action_total_w = action_total_w + aw + 2
            end
            data._actions_ref = actions
            data._actions_w = action_total_w
        end
    end

    -- Reserve scrollbar area when items overflow
    local has_scroll = #items > max_visible
    local SCROLLBAR_W = 10
    local content_w = has_scroll and (w - SCROLLBAR_W) or w

    if Core.IsVisible(x, y, w, h) then
        -- Background (uses list-specific colors when available)
        local list_bg = theme.colors.list_bg or theme.colors.frame_bg
        Core.DrawRect(x, y, w, h, list_bg[1], list_bg[2], list_bg[3], list_bg[4])

        -- Items
        local list_text = theme.colors.list_text or theme.colors.text
        local list_alt  = theme.colors.list_alt_bg
        local list_sel  = theme.colors.list_selected or theme.colors.accent
        local list_sel_t = theme.colors.list_selected_text or COLOR_WHITE
        local list_hov  = theme.colors.list_hover or theme.colors.header_hovered
        local list_grid = theme.colors.list_grid

        local scroll_offset = floor(data.scroll)
        for i = 1 + scroll_offset, min(#items, visible_count + scroll_offset) do
            local item = items[i]
            local iy = y + (i - 1 - scroll_offset) * item_h
            local is_selected = sel_set and sel_set[i] or (i == selected)
            local row_idx = i - scroll_offset  -- 1-based visible row index

            -- Clipped hit-test: rows partially outside the container must
            -- not respond (audit: phantom clicks in horizontal scrollers)
            local row_hovered = Core.MouseInClippedRect(x, iy, content_w, item_h) and not Core.HasPopup()

            -- Inset for bevel (2px in windows mode so highlights don't overpaint border)
            local inset = (theme.widget_style == "windows") and 2 or 1

            -- Alternating row background (every other row)
            if list_alt and row_idx % 2 == 0 then
                Core.DrawRect(x + inset, iy, content_w - inset * 2, item_h, list_alt[1], list_alt[2], list_alt[3], list_alt[4])
            end

            -- Selection highlight (full row, like REAPER's blue band)
            if is_selected then
                Core.DrawRect(x + inset, iy, content_w - inset * 2, item_h, list_sel[1], list_sel[2], list_sel[3], list_sel[4])
            end

            -- Hover highlight (subtle, below selection)
            if row_hovered and not is_selected then
                Core.DrawRect(x + inset, iy, content_w - inset * 2, item_h, list_hov[1], list_hov[2], list_hov[3], list_hov[4] or 0.5)
            end

            -- Grid line (bottom of each row)
            if list_grid then
                Core.DrawLine(x + inset, iy + item_h - 1, x + content_w - inset, iy + item_h - 1,
                    list_grid[1], list_grid[2], list_grid[3], list_grid[4] or 0.3)
            end

            -- Label — per-item color override (e.g. current-file highlight)
            -- wins over selected/default colors unless the row is actively selected.
            local tc
            if is_selected then
                tc = list_sel_t
            elseif item.color then
                tc = item.color
            else
                tc = list_text
            end
            local _, lh = Core.MeasureText(item.label)
            local ly = iy + floor((item_h - lh) / 2)
            -- Truncate label to fit row's text area (accounting for action
            -- buttons + padding). Prevents long filenames spilling past edges.
            local text_area_w = content_w - 6 - (actions and (action_total_w + 4) or 4)
            local label = Core.TruncateText(item.label, text_area_w)
            Core.DrawText(label, x + 6, ly, tc[1], tc[2], tc[3], tc[4])

            -- Click on label area (single = select, double = activate)
            if row_hovered then
                local mx = Core.GetState().mouse_x
                local on_label = mx < x + content_w - action_total_w - 4
                if on_label and Core.MouseClicked(1) then
                    clicked_item = i
                    -- Multi-selection set updates (F6)
                    if sel_set then
                        if Core.ModCtrl() then
                            sel_set[i] = not sel_set[i] or nil
                            data._sel_anchor = i
                        elseif Core.ModShift() and data._sel_anchor then
                            for k in pairs(sel_set) do sel_set[k] = nil end
                            local a, b = data._sel_anchor, i
                            if a > b then a, b = b, a end
                            for k = a, b do sel_set[k] = true end
                        else
                            for k in pairs(sel_set) do sel_set[k] = nil end
                            sel_set[i] = true
                            data._sel_anchor = i
                        end
                    end
                end
                if on_label and Core.MouseDoubleClicked() then
                    activated_item = i
                end
            end

            -- Action buttons (right-aligned)
            if actions and (row_hovered or is_selected) then
                local btn_x = x + content_w - action_total_w - 4
                for ai, act in ipairs(actions) do
                    local aw = Core.MeasureText(act.icon or "?") + theme.frame_padding_x * 2
                    local btn_hovered = Core.MouseInClippedRect(btn_x, iy + 2, aw, item_h - 4)

                    -- Button background
                    if btn_hovered then
                        local hbc = theme.colors.button_hovered
                        Core.DrawRect(btn_x, iy + 2, aw, item_h - 4, hbc[1], hbc[2], hbc[3], hbc[4])
                    end

                    -- Button label
                    local atc = btn_hovered and theme.colors.text or theme.colors.text_disabled
                    local atw, ath = Core.MeasureText(act.icon or "?")
                    Core.DrawText(act.icon or "?",
                        btn_x + floor((aw - atw) / 2),
                        iy + floor((item_h - ath) / 2),
                        atc[1], atc[2], atc[3], atc[4])

                    -- Click action button
                    if btn_hovered and Core.MouseClicked(1) then
                        clicked_item = i
                        clicked_action = ai
                    end

                    btn_x = btn_x + aw + 2
                end
            end

        end

        -- Sunken bevel (drawn AFTER items so highlights don't overwrite edges)
        draw_win32_bevel(x, y, w, h, theme, "sunken")

        -- Scrollbar (vertical) + wheel scroll
        -- opts.scroll_step = rows advanced per wheel notch (default 3). Using a
        -- notch-based step avoids dependence on platform-specific wheel delta
        -- magnitudes (Windows = ±120, Mac/trackpad can differ).
        if has_scroll then
            local in_list = Core.MouseInClippedRect(x, y, w, h)
            if in_list and not Core.HasPopup() and not Core.IsWheelConsumed() then
                local wheel = Core.GetState().mouse_wheel
                if wheel ~= 0 then
                    local step = opts.scroll_step or 3
                    local dir = wheel > 0 and -1 or 1
                    data.scroll = max(0, min(data.scroll + dir * step, #items - visible_count))
                    -- Consumed (audit B4): otherwise the parent scrolls too
                    Core.ConsumeWheel()
                end
            end
            -- Draw scrollbar track + thumb on the right side
            local sb_x = x + w - SCROLLBAR_W
            local sb_track = theme.colors.scrollbar_bg or theme.colors.frame_bg
            Core.DrawRect(sb_x, y + 1, SCROLLBAR_W, h - 2,
                sb_track[1], sb_track[2], sb_track[3], (sb_track[4] or 1) * 0.5)
            local thumb_h = max(16, floor(h * (visible_count / #items)))
            local max_scroll = #items - visible_count
            local thumb_y = y + 1 + floor((data.scroll / max_scroll) * (h - 2 - thumb_h))
            local thumb_c = theme.colors.scrollbar_grab or theme.colors.border
            local thumb_hovered = Core.MouseInClippedRect(sb_x, thumb_y, SCROLLBAR_W, thumb_h)
            local thumb_a = thumb_hovered and 0.9 or 0.6
            Core.DrawRect(sb_x + 2, thumb_y, SCROLLBAR_W - 4, thumb_h,
                thumb_c[1], thumb_c[2], thumb_c[3], thumb_a)
            -- Drag thumb (id cached — audit P9)
            local drag_id = data._sb_id
            if not drag_id then
                drag_id = id .. "_sb"
                data._sb_id = drag_id
            end
            if thumb_hovered and Core.MouseClicked(1) then
                Core.SetActive(drag_id)
            end
            if Core.IsActive(drag_id) then
                if Core.MouseDown(1) then
                    local _, dy = Core.MouseDelta()
                    if dy ~= 0 then
                        local drag_ratio = dy / (h - 2 - thumb_h)
                        data.scroll = max(0, min(max_scroll, data.scroll + drag_ratio * max_scroll))
                    end
                else
                    Core.ClearActive()
                end
            end
        else
            data.scroll = 0
        end
    end

    Layout.AdvanceCursor(w, h)
    return clicked_item, clicked_action, activated_item
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
                local cx = x + floor((collapsed_w - cw) / 2)
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
            Core.DrawText(label, x + 6, y + floor((header_h - lth) / 2), tc[1], tc[2], tc[3], tc[4])

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

    -- If expanded, push a pooled child container for panel content (audit
    -- P8: an ~18-field table + id concat used to be allocated every frame
    -- the panel was open — its steady state)
    if new_open then
        local header_h = theme.tab_height
        local content_x = x
        local content_y = y + header_h
        local content_w = expanded_w
        local content_h = panel_h - header_h

        local cd = Core.GetWidgetSubData("cpanel", id)
        if not cd.cid then
            cd.cid = "cpanel_" .. id
            cd.c = {}
        end
        local c = cd.c
        for k in pairs(c) do c[k] = nil end
        c.id = cd.cid
        c.x = content_x; c.y = content_y; c.w = content_w; c.h = content_h
        c.pad_x = 4; c.pad_y = 4
        c.cursor_x = 4; c.cursor_y = 4
        c.content_h = 0; c.scroll_y = 0
        c.scrollable = false
        c.same_line = false; c.same_line_x = 0
        c.max_row_h = 0; c.spacing = theme.item_spacing
        c.indent_x = 0; c.sameline_pending = false
        c.last_widget_end_x = 4; c.last_widget_y = 4; c.last_widget_h = 0
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

    local data = Core.GetWidgetSubData("reorder", id)
    if data._init == nil then
        data.drag_index = nil
        data.drag_y = 0
        data.order = nil
        data._init = true
    end

    -- Initialize order if needed
    if not data.order or #data.order ~= #items then
        data.order = {}
        for i = 1, #items do data.order[i] = i end
    end

    local changed = false
    local selected = opts.selected

    -- Cached drag capture id (audit P9)
    local drag_id = data._drag_id
    if not drag_id then
        drag_id = id .. "_drag"
        data._drag_id = drag_id
    end

    -- Drop / release handling runs REGARDLESS of visibility (audit B17: the
    -- drop used to live inside the visibility gate — scrolling the list away
    -- mid-drag left a stale drag_index that fired a phantom reorder later).
    if data.drag_index and not Core.MouseDown(1) then
        local my = Core.GetState().mouse_y
        local target_i = max(1, min(#items, floor((my - y) / item_h) + 1))
        if Core.IsVisible(x, y, w, h) and target_i ~= data.drag_index then
            local moving = table.remove(data.order, data.drag_index)
            local insert_at = max(1, min(#data.order + 1, target_i))
            table.insert(data.order, insert_at, moving)
            changed = true
        end
        data.drag_index = nil
        if Core.IsActive(drag_id) then Core.ClearActive() end
    end

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
                local row_hovered = Core.MouseInClippedRect(x, iy, w, item_h) and not Core.HasPopup()

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
                Core.DrawText("=", x + 4, iy + floor((item_h - 14) / 2),
                    tc_dim[1], tc_dim[2], tc_dim[3], tc_dim[4])

                -- Label
                local tc = theme.colors.text
                local _, lh = Core.MeasureText(label)
                Core.DrawText(label, x + handle_w + 4, iy + floor((item_h - lh) / 2),
                    tc[1], tc[2], tc[3], tc[4])

                -- Start drag — with mouse capture (audit B17: without
                -- SetActive, other widgets could become active mid-drag)
                if row_hovered and Core.MouseClicked(1) and Core.MouseInClippedRect(x, iy, 20, item_h) then
                    data.drag_index = display_i
                    data.drag_y = Core.GetState().mouse_y
                    Core.SetActive(drag_id)
                end

                -- Row separator
                local sc = theme.colors.separator
                Core.DrawLine(x, iy + item_h - 1, x + w, iy + item_h - 1, sc[1], sc[2], sc[3], 0.1)
            end
        end

        -- Draw dragged item on top (drop itself is handled above, before the
        -- visibility gate)
        if data.drag_index and Core.MouseDown(1) then
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
            Core.DrawText(label, x + 20, drag_display_y + floor((item_h - lh) / 2),
                tc[1], tc[2], tc[3], tc[4])

            -- Calculate drop position
            local target_i = max(1, min(#items,
                floor((my - y) / item_h) + 1))

            -- Draw insertion indicator
            local ind_y = y + (target_i - 1) * item_h
            if target_i > data.drag_index then ind_y = ind_y + item_h end
            Core.DrawRect(x + 2, ind_y - 1, w - 4, 2, ac[1], ac[2], ac[3], ac[4])
        end

        -- Border
        local bc = theme.colors.border
        Core.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], 0.3, false)
    end

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
    local visible_rows = min(row_count, max_visible)
    local total_h = header_h + visible_rows * row_h
    local gap = opts.col_gap or 0
    local selected_row = opts.selected
    local header_render = opts.header_render

    -- Column layout tables are pooled per widget (audit P8: two fresh tables
    -- + O(cols) fills per frame, before the visibility test). The fill loops
    -- below are cheap arithmetic; the allocations were the problem.
    local ldata = Core.GetWidgetSubData("itable", id)
    local col_widths = ldata._col_widths
    local col_positions = ldata._col_positions
    if not col_widths then
        col_widths = {}
        col_positions = {}
        ldata._col_widths = col_widths
        ldata._col_positions = col_positions
    end
    for i = #columns + 1, #col_widths do
        col_widths[i] = nil
        col_positions[i] = nil
    end

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

    local gaps_total = max(0, #columns - 1) * gap
    local distributable = avail_w - total_fixed - gaps_total
    local cx = x
    for i, col in ipairs(columns) do
        col_positions[i] = cx
        if col.width then
            col_widths[i] = col.width
        else
            col_widths[i] = floor(distributable * (col.weight or 1) / total_weight)
        end
        cx = cx + col_widths[i] + gap
    end

    -- Scroll
    local data = ldata
    if data._init == nil then
        data.scroll = 0
        data._init = true
    end
    -- Re-clamp every frame (audit B14: shrinking datasets left the view
    -- past the end until the next wheel tick)
    data.scroll = max(0, min(data.scroll, max(0, row_count - visible_rows)))
    local scroll_offset = floor(data.scroll)

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
                        y + floor((header_h - hh) / 2),
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
        for row_idx = 1 + scroll_offset, min(row_count, visible_rows + scroll_offset) do
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
                    if Core.MouseInClippedRect(col_positions[i], ry, col_widths[i], row_h) then
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

        end

        -- Sunken bevel (drawn AFTER items so highlights don't overwrite edges)
        draw_win32_bevel(x, y, avail_w, total_h, theme, "sunken")

        -- Fallback border for flat mode (bevel is no-op when not "windows")
        if theme.widget_style ~= "windows" then
            local bc = theme.colors.border
            Core.DrawRect(x, y, avail_w, total_h, bc[1], bc[2], bc[3], 0.3, false)
        end

        -- Scroll with wheel — notch-based step (opts.scroll_step rows per notch)
        if row_count > max_visible then
            local in_table = Core.MouseInClippedRect(x, y, avail_w, total_h)
            if in_table and not Core.HasPopup() and not Core.IsWheelConsumed() then
                local wheel = Core.GetState().mouse_wheel
                if wheel ~= 0 then
                    local step = opts.scroll_step or 3
                    local dir = wheel > 0 and -1 or 1
                    data.scroll = max(0, min(data.scroll + dir * step, row_count - visible_rows))
                    -- Consumed (audit B4): otherwise the parent scrolls too
                    Core.ConsumeWheel()
                end
            end
        else
            data.scroll = 0
        end
    end

    Layout.AdvanceCursor(avail_w, total_h)
    return clicked_row, clicked_col_key, hovered_row
end

return Widgets
