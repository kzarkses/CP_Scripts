# CP_Toolkit API Reference

> 2026-07 audit pass: ESC is now layered (cancels edit → closes popup →
> releases focus → only a *bare* ESC closes the window). Widgets that handle
> a key call `UI.ConsumeChar()`; widgets that scroll call `UI.ConsumeWheel()`
> so parents don't double-scroll. See `AUDIT_2026-07.md` for the full list.

## Setup

```lua
local UI = dofile(path .. "CP_Toolkit/CP_Toolkit.lua")
UI.Init(title, width, height, opts)
UI.Run(function(theme) ... end)
UI.OnClose(function() ... end)
```

### Init options
```lua
{
    scale = 1.0,         -- DPI scaling (1.0 = 100%)
    dock = 0,            -- 0 = floating, 1 = docked
    x = 100, y = 100,    -- initial position
    frameless = false,   -- remove OS title bar (JS_API)
    topmost = false,     -- always on top (JS_API)
    scrollable = true,   -- false = disable window scrollbar (toolbar/status-bar mode)
    persist = nil,       -- script_id (string) → auto save/restore dock/pos/size across sessions
    padding = nil,       -- override theme.window_padding (set to 0 for edge-to-edge layouts)
}
```

`UI.SetWindowPadding(n)` — change the window padding at runtime (the next frame
applies it). Useful for live-reloadable layout settings.

---

## Text & Fonts

```lua
UI.Text(text, opts)                -- opts: {disabled, color={r,g,b,a}, font_size}
UI.TextColored(text, r, g, b, a)
UI.TextWrapped(text, opts)         -- word-wrapped multi-line text
    -- opts: {color, max_width}  (default max_width = available width)
    -- The wrap layout is cached per (font, text, width) — steady-state cost
    -- is one DrawText per line, zero measurement.
UI.Header(text)                    -- legacy, use SetFontH1 + Text instead
```

### Font hierarchy
```lua
UI.SetFontTitle()      -- biggest, bold — window titles
UI.SetFontH1()         -- section headers
UI.SetFontH2()         -- sub-section headers
UI.SetFontH2Bold()     -- sub-section bold
UI.SetFontBody()       -- default body text (auto-reset target)
UI.SetFontCaption()    -- small hints, labels
UI.SetFontMono()       -- values, time codes, dB
```

---

## Buttons & Toggles

```lua
-- Standard button. Returns: clicked (bool)
UI.Button(id, label, opts)              -- opts: {width, height}
    -- width = -1 → fill the available width of the parent column / container
    --             (the standard ImGui idiom)

-- ON/OFF toggle. Returns: toggled (bool), new_state (bool)
UI.ToggleButton(id, label, is_on, opts) -- opts: {width, height}
    -- width = -1 → fill (same semantic as Button)

-- Checkbox (filled square). Returns: toggled, new_checked
UI.Checkbox(id, label, checked)

-- Radio group. Returns: changed, new_index
UI.RadioGroup(id, label, index, items, opts)  -- opts: {horizontal=true}
```

---

## Sliders & Number Inputs

```lua
-- Integer slider. Returns: changed, new_value
UI.SliderInt(id, label, value, min, max, opts)

-- Float slider. Returns: changed, new_value
UI.SliderDouble(id, label, value, min, max, opts)

-- Both sliders: Ctrl+click (or double-click) on the track opens an inline
-- numeric edit — type the exact value, Enter commits (clamped), Esc cancels.

-- Dual-thumb range. Returns: changed, new_min, new_max
UI.RangeSlider(id, label, val_min, val_max, range_min, range_max, opts)
    -- opts: {width, format="%.1f"}
    -- Three drag zones:
    --   • Click near min handle  → drag the lower bound only
    --   • Click near max handle  → drag the upper bound only
    --   • Click in the middle    → translate both bounds together
    --                              (the span max-min is preserved, clamped
    --                              to [range_min, range_max])
    -- Cursor: size_we for handles, size_all for the middle drag zone.

-- Range slider with a current-value point (3-thumb).
-- Returns: value_changed, new_value, range_changed, new_min, new_max
UI.ValueRangeSlider(id, label, value, val_min, val_max,
                    range_min, range_max, opts)
    -- opts: {width, height, format=string}
    -- The value is drawn as a filled circle inside the range fill, and is
    -- clamped to [val_min, val_max] (the handles cannot cross the value).
    -- Drag zones:
    --   • Click on the value dot → drag the value (writes through your
    --     own callback when you receive value_changed=true)
    --   • Click near min/max handle → drag that bound only
    --   • Click between the handles (away from the value) → translate the
    --     range AND the value together (span preserved)
    --   • Click in the empty track outside the range → snap nearest handle

-- Number input (drag or double-click to edit). Returns: changed, new_value
UI.NumberInput(id, label, value, min, max, opts)
    -- opts: {step=1, speed=1, format="%d", width=80}
    -- Supports mousewheel increment

-- Knob (rotary). Returns: changed, new_value (0-1)
UI.Knob(id, label, value, default_value, opts)
    -- opts: {size=40, sensitivity=0.004, wheel_step=0.02}
    -- Double-click to reset to default; mouse wheel steps the value
    -- (Ctrl = fine, ×0.25). Combo also cycles its selection on wheel.

-- ModKnob (knob + modulation overlay, Bitwig-style).
-- Returns: base_changed, new_base, depth_changed, new_depth
UI.ModKnob(id, label, base, depth, live, opts)
    -- base: 0..1 (the knob value = modulation BASE)
    -- depth: -1..1 (signed modulation amount; model: value = base + (src-0.5)×depth)
    -- live: 0..1 or nil — current modulated value, drawn as a dot riding
    --       the inner ring; the excursion window [base ± |depth|/2] is a
    --       tinted arc (value_negative tint when depth < 0)
    -- opts: {size=40, sensitivity=0.004, depth_sensitivity=0.008, default=0.5}
    -- Drag = base, Alt+drag = depth, double-click = reset base,
    -- Alt+double-click = reset depth to 0
```

---

## Text Inputs

```lua
-- Single-line input. Returns: changed, new_text, submitted
--   submitted = true on the frame the user pressed Enter
UI.InputText(id, label, text, opts)
    -- opts: {hint="placeholder", width, select_all_on_focus=true, disabled=false}
    -- Ctrl+C/V/X, selection, auto-scroll, clipped via gfx buffer
    -- Ctrl+Z / Ctrl+Y: undo/redo (coalesced typing bursts, bounded stack)
    -- UTF-8 aware: accented input works; cursor moves per codepoint
    -- Esc releases focus (does NOT close the window)
    -- Use UI.SetFocus(id) to programmatically focus this widget

-- Multi-line editor. Returns: changed, new_text
UI.TextEdit(id, text, opts)
    -- opts: {width, height=120}
    -- Enter = newline, scroll, click to position cursor
```

---

## Selection

```lua
-- Dropdown. Returns: changed, new_index
UI.Combo(id, label, index, items, opts)  -- opts: {width}
    -- Popup scrolls (wheel + thin scrollbar) when the list doesn't fit the
    -- window, and supports Up/Down/Enter/Esc keyboard navigation.

-- Color picker (HSV popup). Returns: changed, new_color {r,g,b}
UI.ColorPicker(id, label, color, opts)   -- color = {r, g, b}
    -- changed is true only on frames where the value was actually edited
    -- (safe to do `if changed then save end`). The HSV state resyncs when
    -- the caller's color changes externally (preset/theme load).
```

---

## Layout

### Spacing & Indentation
```lua
UI.SameLine(spacing)    -- next widget on same line
UI.NewLine()            -- force new line
UI.Spacing(pixels)      -- vertical space
UI.Indent(pixels)       -- increase indent (default 16)
UI.Unindent(pixels)     -- decrease indent
UI.Separator()          -- horizontal line
```

### Wrap (auto-flow)
```lua
UI.BeginWrap(id, opts)  -- opts: {gap=4}
    UI.Button("a", "A")
    UI.Button("b", "B")  -- wraps automatically when line is full
UI.EndWrap()
```

### Columns (proportional)
```lua
UI.BeginColumns(id, {0.3, 0.7}, opts)  -- 30% / 70%
    -- left column content
UI.NextColumn()
    -- right column content
UI.EndColumns()
```

### Grid (fixed cell size, auto-wrap)
```lua
UI.BeginGrid(id, {cell_w=80, cell_h=60, gap=4})
    local x, y, w, h = UI.GridCell(id)  -- returns screen coords
    -- draw cell content at x, y
UI.EndGrid(id)
```

### Weighted Row (responsive, auto-hide)
```lua
local widths, visible = UI.BeginWeightedRow(id, {
    {key="name", weight=2.5, min_w=60},
    {key="vol",  weight=1.0, min_w=40},
}, opts)
    local x, y, w, h = UI.WeightedCell(id, "name")
    -- draw cell
UI.EndWeightedRow(id)
```

### Splitter (resizable divider)
```lua
local size_a = UI.Splitter(id, "horizontal", total_w, 0.5, opts)
    -- opts: {thickness=6, min_a=50, min_b=50}
```

### List Clipper (virtualization for long lists)
```lua
-- ImGuiListClipper equivalent: only the visible rows are laid out, measured
-- and drawn — cost is O(visible), independent of count. For custom
-- fixed-height rows inside a scrollable BeginChild.
-- Contract: each row must be exactly row_h tall.
UI.BeginChild("list", 0, 0)
local first, last = UI.ListClipper(#rows, row_h)
for i = first, last do
    -- draw row i (height row_h)
end
UI.EndListClipper(#rows, row_h)
UI.EndChild()
```

### Scrollable Child Region
```lua
UI.BeginChild(id, width, height, opts)
    -- opts: {scrollable=true, scrollable_x=false, border=true,
    --        padding=6, bg={r,g,b,a}, scroll_step=nil}
    -- width=0 or height=0 → fill available space
    -- scrollable    = vertical scroll (default true)
    -- scrollable_x  = horizontal scroll (default false). When enabled,
    --                 content can extend past the right edge and the user
    --                 scrolls with the bottom scrollbar or Shift+wheel.
    -- scroll_step   = pixels per wheel notch (default Layout.SCROLL_STEP=66).
UI.EndChild()
```

Wheel scrolling is notch-proportional: the accumulated `gfx.mouse_wheel`
delta (±120 per notch, multiples per frame on fast spins) maps to
`scroll_step` pixels per notch — no ticks are ever dropped.

**Middle-click pan**: press and drag mouse3 inside any scrollable region
(window or child) to pan it hand-tool style — the content follows the
mouse; the innermost hovered region wins. No setup needed.

---

## Panels (Windows-style content containers)

```lua
UI.BeginPanel(id, opts)
    -- ... content ...
UI.EndPanel()
```

`opts`:
```lua
{
    style   = "filled",  -- "filled" | "groupbox" | "inset"
    title   = nil,       -- optional label string
    padding = nil,       -- inner padding (default = theme.frame_padding_x * 2)
    width   = nil,       -- nil = full width of parent
    bg      = nil,       -- nil = theme.colors.frame_bg, or {r,g,b,a}, or "window"
    border  = true,
}
```

Three visual styles:
- **`filled`** — solid background + border + optional title rendered inside the panel.
  Use for content areas that should stand out (like the Actions list in REAPER).
- **`groupbox`** — no fill, border with the title text inset on the top edge.
  Classic Win32 GroupBox; use to logically group related controls.
- **`inset`** — sunken bevel (dark top/left, light bottom/right). Use for read-only
  display surfaces.

Auto-fits to content height: BeginPanel reserves the maximum available space,
content draws inside, EndPanel measures the actual height and erases the excess
with the parent's background color. No need to predeclare the height.

Panels can be nested. Each panel uses `frame_bg` by default unless overridden.

## Containers & Navigation

```lua
-- Tab bar. Returns: changed, new_index
UI.TabBar(id, {"Tab1", "Tab2"}, active_index, opts)

-- Collapsible section. Returns: toggled, new_open
UI.CollapsingHeader(id, label, is_open)

-- Tree node (hierarchical). Returns: toggled, new_open
UI.TreeNode(id, label, is_open, opts)
UI.TreePop()  -- close indent after open TreeNode

-- Tooltip (call after the widget it belongs to). Multi-line: text wraps at
-- theme.tooltip_max_w; "\n" forces a break. Delay = theme.tooltip_delay.
UI.Tooltip(text)
```

---

## Disabled Scope & Item Queries

```lua
-- Gray out + block interaction for every widget in the scope (nests;
-- BeginDisabled(false) is a transparent level).
UI.BeginDisabled(cond)
    UI.Button("apply", "Apply")
    UI.SliderDouble("wet", "Wet", wet, 0, 1)
UI.EndDisabled()
UI.IsDisabled()  -- true inside an active disabled scope

-- Last-item queries (call right AFTER a widget — ImGui idiom)
UI.IsItemHovered()
UI.IsItemClicked(button)      -- button: 1=left (default), 2=right, 64=middle
UI.IsItemRightClicked()
UI.IsItemDoubleClicked()
UI.GetLastItemRect()          -- x, y, w, h of the last submitted widget
```

---

## Style Overrides

```lua
-- Temporarily replace a theme color (restore with Pop — same frame):
UI.PushStyleColor("accent", 0.9, 0.2, 0.2)   -- danger red
UI.Button("del", "Delete")
UI.PopStyleColor()          -- PopStyleColor(n) pops n levels
```

---

## Input Consumption

```lua
UI.ConsumeChar()    -- a custom widget handled this frame's key: stops the
                    -- layered ESC fallback (Core would otherwise close
                    -- popup → clear focus → close window on a bare ESC)
UI.ConsumeWheel()   -- a custom widget scrolled: parents won't also scroll
UI.RequestRedrawAt(t)  -- wake the idle loop at reaper.time_precise() = t
                       -- (egui request_repaint_after — timed reveals/fades)
```

---

## Buffered Clip (pixel-true region clipping)

gfx has no scissor: `DrawText` drops a partially-clipped string entirely and
the antialiased icon primitives ignore the clip stack. For regions whose
edges must crop content seamlessly (scrolling lists), draw through a shared
offscreen buffer — everything inside is pixel-cropped at the region bounds.

```lua
if UI.BeginBufferedClip(x, y, w, h) then  -- opt. 5th arg: margin (default 64)
    -- draw with normal SCREEN coordinates; fill the region with an opaque
    -- background first (buffer pixels persist across frames)
    UI.EndBufferedClip()                   -- restores gfx.dest, blits region
end
```

Not nestable (returns false if a region is already active). Cost: one
window-sized gfx buffer (id 904) + one blit per frame.

---

## Tables & Lists

```lua
-- Simple table. Returns: clicked_row, clicked_col
--   clicked_row == 0 → a HEADER was clicked (clicked_col = which one);
--   use it to toggle your sort order, re-sort your rows (event-driven,
--   never per frame) and pass opts.sort so the arrow is drawn.
UI.Table(id, columns, rows, opts)
    -- columns = {{header="Name", width=100}, {header="Value"}}
    -- rows = {{"A", "1"}, {"B", "2"}}
    -- opts: {selected=row_idx, max_rows=10, row_height,
    --        sort={col=1, dir="asc"|"desc"}}  -- draws the sort indicator

-- Interactive table (custom cell render). Returns: clicked_row, clicked_col_key, hovered_row
UI.InteractiveTable(id, columns, row_count, cell_render_fn, opts)
    -- cell_render_fn(row, col_key, x, y, w, h, theme)
    -- opts: {header_render, selected, max_rows, row_height, col_gap}

-- Scrollable list with row actions. Returns: clicked_item, clicked_action, activated_item
--   clicked_item   = index on single click (use to set selection)
--   clicked_action = action index when an action button is clicked
--   activated_item = index on double-click (use to trigger default action)
UI.ActionList(id, items, actions, opts)
    -- items = {{label="Item 1"}, ...}
    -- actions = {{icon="X", tooltip="Delete"}, ...}
    -- opts: {max_visible=8, selected, item_height,
    --        selection = set,   -- multi-select: {[idx]=true}, MUTATED in
    --                           -- place (click=single, Ctrl=toggle,
    --                           -- Shift=range from last plain click)
    --        nav = bool}        -- route Up/Down/Enter to this list this
    --                           -- frame (e.g. while your search box has
    --                           -- focus). Up/Down report through
    --                           -- clicked_item, Enter through activated_item,
    --                           -- and the view auto-scrolls to the selection.

-- Drag-to-reorder list. Returns: changed, new_order, dragging_index
UI.ReorderableList(id, items, opts)
    -- opts: {width, item_height, selected}
```

---

## Popups & Modals

```lua
-- Context menu (right-click). By default triggers anywhere in the window;
-- scope it with opts. `shortcut` is DISPLAY-ONLY (dispatch the key combo
-- yourself). Esc or click-outside closes.
UI.ContextMenu(id, {
    {label="Cut", shortcut="Ctrl+X", action=function() end},
    {separator=true},
    {label="Disabled", disabled=true},
}, opts)
    -- opts: {rect={x,y,w,h}}    → only when right-click lands inside rect
    --       {scope="item"}      → only on the last submitted widget

-- Native OS menu via gfx.showmenu: nested submenus, checkmarks, disabled
-- items for free; blocking while open, zero per-frame cost. The pragmatic
-- choice for deep menus (ContextMenu = the theme-styled flat alternative).
-- Returns the selected item table (runs item.action() when present).
UI.NativeMenu({
    {label="Cut", action=fn},
    {separator=true},
    {label="Send to", children={ {label="Bus 1", action=fn}, ... }},
    {label="Enabled", checked=true},
}, x, y)  -- x/y optional (default: mouse position)

-- Horizontal menu bar built on NativeMenu.
-- Returns: selected item table (or nil), menu index
UI.MenuBar(id, {
    {label="File", items={...NativeMenu items...}},
    {label="Edit", items={...}},
})

-- Modal dialog (centered, dimmed overlay)
UI.BeginModal(id, title, opts)  -- opts: {width=300, height=150}
    UI.Text("Content")
    if UI.Button("ok", "OK") then ... end
UI.EndModal()
```

---

## Visuals

```lua
-- Progress bar
UI.ProgressBar(id, fraction, opts)  -- opts: {label, height, width}

-- VU meters
UI.VMeter(id, peak_l, peak_r, opts)  -- opts: {width=12, height=80}
UI.HMeter(id, peak_l, peak_r, opts)  -- opts: {width=120, height=12}

-- Canvas (free drawing area). Returns: {x,y,w,h, hovered,clicked,dragging, norm_x,norm_y}
-- NOTE: the returned table is owned by the widget and REUSED next frame —
-- copy fields out if you need to keep them.
UI.Canvas(id, opts)  -- opts: {width, height=200, crosshair, grid=4, bg, border_color}
```

---

## Drag & Drop

```lua
-- After a draggable widget:
UI.BeginDragSource(id, payload, drag_type, display_text)

-- On a drop target area:
local dropped_payload = UI.BeginDropTarget(x, y, w, h, accept_type)

-- At end of frame (draws drag preview on top):
UI.DrawDragPreview()

UI.IsDragging(drag_type)  -- check if drag is active
```

---

## Images

```lua
local img = UI.LoadImage("path/to/image.png")  -- relative to REAPER resource path
UI.UnloadImage(img)                    -- frees the gfx buffer (id is recycled)
UI.Image(img, opts)                    -- opts: {width, height}
UI.ImageButton(id, img, opts)          -- opts: {size, padding}. Returns: clicked
```

---

## Drawing Primitives

```lua
UI.Core.DrawRect(x, y, w, h, r, g, b, a, filled)   -- filled=true by default
UI.Core.DrawLine(x1, y1, x2, y2, r, g, b, a)
UI.Core.DrawText(text, x, y, r, g, b, a)
UI.Core.MeasureText(text)  -- returns w, h

-- Native gfx (antialiased)
UI.DrawRoundRect(x, y, w, h, radius, r, g, b, a)
UI.DrawCircle(x, y, radius, r, g, b, a, filled)
UI.DrawTriangle(x1,y1, x2,y2, x3,y3, r, g, b, a)
UI.DrawArc(x, y, radius, ang1, ang2, r, g, b, a)
UI.DrawGradientRect(x, y, w, h, r1,g1,b1,a1, r2,g2,b2,a2, vertical)
```

---

## Cursor

```lua
UI.SetCursor("arrow")     -- default
UI.SetCursor("ibeam")     -- text input
UI.SetCursor("hand")      -- clickable
UI.SetCursor("size_we")   -- horizontal resize
UI.SetCursor("size_ns")   -- vertical resize
UI.SetCursor("size_all")  -- move
UI.SetCursor("cross")     -- crosshair
```

---

## Animation

```lua
-- Interpolate a value toward target (call each frame). Returns: current
local val = UI.Animate(id, target, speed)  -- speed=8 default

-- Interpolate a color. Returns: r, g, b, a
local r, g, b, a = UI.AnimateColor(id, {r, g, b, a}, speed)
```

---

## Theme

```lua
UI.GetTheme()                      -- returns live theme table
UI.SetTheme(theme)
UI.SaveTheme(name)                 -- save to CP_Config/<name>.lua
UI.LoadTheme(name)                 -- load from file
UI.ResetTheme()                    -- reset to default
UI.ApplyPreset(key)                -- "default_dark", "reaper_classic", "light", "midnight"

-- Theme structure:
theme.colors.window_bg             -- {r, g, b, a}
theme.colors.text / text_disabled / border / separator
theme.colors.accent / accent_hovered / accent_active
theme.colors.button / button_hovered / button_active
theme.colors.frame_bg / frame_hovered / frame_active
theme.colors.header / header_hovered / header_active
theme.colors.tab / tab_hovered / tab_active
theme.colors.popup_bg / scrollbar_bg / scrollbar_grab
theme.colors.title_bar / title_text / close_btn / close_btn_hover
theme.colors.value_normal / value_modified / value_negative
theme.colors.list_bg / list_alt_bg / list_text / list_grid
theme.colors.list_selected / list_selected_text / list_hover

-- Surface hierarchy + semantic accents (added for compact list/tab UIs)
theme.colors.surface / surface2 / border_soft / text_mute
theme.colors.accent_dim / danger / bypass

theme.fonts.face / title / h1 / h2 / body / caption / mono_face / mono_size
theme.window_padding / frame_padding_x / frame_padding_y / item_spacing / indent
theme.separator_pad / checkbox_size / slider_height / button_height / tab_height
theme.combo_height / header_height / scrollbar_width / scale

-- Compact list / chip rows (FX Browser-style dense UIs)
theme.chip_h / row_h / row_h_large / pad_small / pad_large
theme.gap / gap_large / splitter_w

-- Tooltips
theme.tooltip_max_w   -- wrap width in px (scaled), default 320
theme.tooltip_delay   -- hover delay in seconds, default 0.4

theme.widget_style  -- "flat" (default) | "windows"
                    -- "windows" enables Win32-style bevels on buttons (3D),
                    -- sunken inputs, and matches the REAPER native look.
                    -- Set automatically by the "REAPER Light" preset.
```

---

## Persistent Layout

```lua
UI.SaveWindowState(script_id)              -- save dock/position/size (1 ExtState write)
UI.LoadWindowState(script_id)              -- returns {dock, x, y, w, h}
UI.SavePersistent(script_id, key, value)   -- save any value (ExtState)
UI.LoadPersistent(script_id, key, default) -- load with fallback
```

### CP_Config files (recommended for non-trivial app state)

For anything bigger than a handful of values, use `SaveConfig/LoadConfig`
instead of ExtState. They write a single Lua file under
`<resource>/Scripts/CP_Scripts/CP_Config/<script_id>.lua` — much faster than
ExtState (1 small disk write vs rewriting the global ~50-200KB ini file)
and human-readable.

```lua
UI.SaveConfig("CP_Inspector", { prefs = {...}, visible_props = {...} })
local data = UI.LoadConfig("CP_Inspector")  -- returns table or nil
```

---

## Docking & Overlay

```lua
UI.Dock(dock_id)        UI.ToggleDock()       UI.IsDocked()
UI.SetPosition(x, y)    UI.SetTopMost(bool)   UI.IsFrameless()
UI.SetAnchor({x=0.5, y=0, offset_x=-25, offset_y=30})
UI.ClearAnchor()
```

---

## Icons (50 available)

```lua
UI.Icons.ChevronDown(x, y, size, r, g, b, a)
-- All icons follow the same signature: (x, y, size, r, g, b, a)
-- Centered in a size x size box

-- Arrows: ChevronDown/Up/Left/Right, TriangleDown/Up/Left/Right
-- UI: Close, Check, Plus, Minus, Search, Settings, Refresh
-- Transport: Play, Pause, Stop, Record, SkipForward, SkipBackward, Loop
-- Actions: Undo, Redo, Delete, Copy, Save
-- State: Lock, Unlock, Eye, EyeOff, Mute, Volume, Solo
-- Audio: Waveform, MIDI, FX
-- Files: Folder, File
-- Tools: Crosshair, Pipette
-- Lists/tabs: Star, StarFilled, Clock, Scan, Sort, Dice, Erase, Grip, Layers
```

Rendering: each (icon, size, color) is baked once — drawn at 4x supersample,
then downscaled through two filtered blits (real antialiasing) — and blitted
per frame (buffers 926-989; scratch 990-992).

**PNG overrides**: drop white-on-transparent PNGs (64-128px, square) named
after the icon function (`Play.png`, `StarFilled.png`, …) into
`CP_Toolkit/IconOverrides/` — they replace the vector glyph and are tinted
to the requested color at bake time. `UI.Icons.ReloadOverrides()` rescans
without a restart. See `IconOverrides/README.md`.

---

## Shared non-UI modules (dofile separately — not part of CP_Toolkit.lua)

### Audio.lua — audition engine (SWS CF_Preview)

```lua
local Audio = dofile(cp_root .. "CP_Toolkit/Audio.lua")
Audio.init(reaper)                 -- Audio.available = SWS present
Audio.Play(path, {start_s, end_s, loop, rate, pitch, vol})  -- section-aware
Audio.Poll()                       -- once per frame: section end stop/loop
Audio.Stop() / Audio.IsPlaying(path?) / Audio.Progress()  -- pos_s, len
Audio.Meta(path)                   -- len, channels, samplerate
Audio.SetVolume(v) / Audio.Destroy()
```

Tiny cached PCM_source pool, pcall-guarded dead handles, negative-cache
on unreadable files. For the full browser preview stack (LRU + prefetch
+ tempo-sync) use CP_MediaExplorer's own module.

### DragBus.lua — cross-script drag & drop

ReaScript windows are separate processes to each other: the bus is an
ExtState protocol (session-only), **rect-based and JS-free** — every
consumer publishes its window's screen rect via `gfx.clienttoscreen`
(works docked), the publisher point-tests those rects on release.
Publisher (drag source):

```lua
DragBus.Begin(kind, path, label [, self_id])  -- at drag promotion
DragBus.HoverTarget(sx, sy)   -- target id under the point (nil inside
                              --   the publisher's own window)
DragBus.Drop(sx, sy)          -- deliver on release → true if consumed
DragBus.End()                 -- always end the drag
```

Consumer (drop target):

```lua
DragBus.Register(id)          -- once
DragBus.RectSync(id)          -- every frame (writes only on move/resize)
DragBus.ActiveDrag()          -- kind, path, label (highlight UI)
DragBus.TakeDrop(id)          -- kind, path, sx, sy (one-shot)
DragBus.Unregister(id)        -- OnClose + atexit
```

A publisher that gets `Drop() == true` must skip its own drop handling.
During a foreign drag the consumer's window gets no mouse events (the
source holds capture): track `reaper.GetMousePosition()` +
`Core.ScreenToClient` and call `RequestRedraw`. Rect tests ignore
z-order — CP targets take priority by design.

---

## Keys

```lua
UI.Keys.F1 .. F12, UP/DOWN/LEFT/RIGHT, HOME/END, PAGE_UP/PAGE_DOWN
UI.Keys.DELETE, INSERT, BACKSPACE, TAB, ENTER, SPACE, ESCAPE
UI.Keys.A .. Z, N0 .. N9
UI.Keys.GetName(code)  -- reverse lookup
```

---

## Log (Debug)

```lua
-- F12 = toggle overlay, F11 = toggle console
UI.Log.Info(category, msg, details)
UI.Log.Warn(category, msg, details)
UI.Log.Error(category, msg, details)
```
