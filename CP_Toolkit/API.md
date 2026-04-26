# CP_Toolkit API Reference

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

-- ON/OFF toggle. Returns: toggled (bool), new_state (bool)
UI.ToggleButton(id, label, is_on, opts) -- opts: {width, height}

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

-- Dual-thumb range. Returns: changed, new_min, new_max
UI.RangeSlider(id, label, val_min, val_max, range_min, range_max, opts)
    -- opts: {width, format="%.1f"}

-- Number input (drag or double-click to edit). Returns: changed, new_value
UI.NumberInput(id, label, value, min, max, opts)
    -- opts: {step=1, speed=1, format="%d", width=80}
    -- Supports mousewheel increment

-- Knob (rotary). Returns: changed, new_value (0-1)
UI.Knob(id, label, value, default_value, opts)
    -- opts: {size=40, sensitivity=0.004}
    -- Double-click to reset to default
```

---

## Text Inputs

```lua
-- Single-line input. Returns: changed, new_text, submitted
--   submitted = true on the frame the user pressed Enter
UI.InputText(id, label, text, opts)
    -- opts: {hint="placeholder", width, select_all_on_focus=true, disabled=false}
    -- Ctrl+C/V/X, selection, auto-scroll, clipped via gfx buffer
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

-- Color picker (HSV popup). Returns: changed, new_color {r,g,b}
UI.ColorPicker(id, label, color, opts)   -- color = {r, g, b}
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

### Scrollable Child Region
```lua
UI.BeginChild(id, width, height, opts)
    -- opts: {scrollable=true, border=true, padding=6, bg={r,g,b,a}}
    -- width=0 or height=0 → fill available space
UI.EndChild()
```

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

-- Tooltip (call after the widget it belongs to)
UI.Tooltip(text)
```

---

## Tables & Lists

```lua
-- Simple table. Returns: clicked_row, clicked_col
UI.Table(id, columns, rows, opts)
    -- columns = {{header="Name", width=100}, {header="Value"}}
    -- rows = {{"A", "1"}, {"B", "2"}}
    -- opts: {selected=row_idx, max_rows=10, row_height}

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
    -- opts: {max_visible=8, selected, item_height}

-- Drag-to-reorder list. Returns: changed, new_order, dragging_index
UI.ReorderableList(id, items, opts)
    -- opts: {width, item_height, selected}
```

---

## Popups & Modals

```lua
-- Context menu (right-click). Call in the area where it should trigger.
UI.ContextMenu(id, {
    {label="Cut", shortcut="Ctrl+X", action=function() end},
    {separator=true},
    {label="Disabled", disabled=true},
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

theme.fonts.face / title / h1 / h2 / body / caption / mono_face / mono_size
theme.window_padding / frame_padding_x / frame_padding_y / item_spacing / indent
theme.separator_pad / checkbox_size / slider_height / button_height / tab_height
theme.combo_height / header_height / scrollbar_width / scale

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

## Icons (41 available)

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
```

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
