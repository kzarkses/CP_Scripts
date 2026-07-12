-- CP_Toolkit — Point d'entrée principal
-- Usage:
--   local UI = dofile(path .. "CP_Toolkit/CP_Toolkit.lua")
--   UI.Init("My Script", 400, 600)
--   UI.Run(function() ... end)

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")

local Core    = dofile(script_path .. "Core.lua")
local Layout  = dofile(script_path .. "Layout.lua")
local ThemeMod = dofile(script_path .. "Theme.lua")
local Widgets = dofile(script_path .. "Widgets.lua")
local KeysMod = dofile(script_path .. "Keys.lua")
local IconsMod = dofile(script_path .. "Icons.lua")
local LogMod   = dofile(script_path .. "Log.lua")

-- Wire dependencies
Core.SetLog(LogMod)
LogMod.SetStatsSource(Core.GetStats)  -- F12 overlay shows live perf stats
Layout.Init(Core)
Widgets.Init(Core, Layout, ThemeMod)
Widgets.SetLog(LogMod)
Widgets.SetIcons(IconsMod)
Widgets.SetKeys(KeysMod)
-- Icons (glyph icons) and the Log overlay draw with their own font slots;
-- after drawing they must re-select the slot Core believes is current, or
-- Core's slot guards and measure cache would go stale (audit B5a/B5c).
IconsMod.SetFontRestorer(Core.RestoreFont)
LogMod.SetFontRestorer(Core.RestoreFont)

-- ============================================================================
-- PUBLIC API
-- ============================================================================
local UI = {}

-- Re-export modules for advanced use
UI.Core    = Core
UI.Layout  = Layout
UI.Theme   = ThemeMod
UI.Widgets = Widgets
UI.Log     = LogMod
UI.Keys    = KeysMod
UI.Icons   = IconsMod

-- Active theme (loaded once at init)
UI._theme = nil

-- ============================================================================
-- INIT / RUN
-- ============================================================================
function UI.Init(title, width, height, opts)
    opts = opts or {}
    -- Try to load saved toolkit theme, then ImGui styles, then default
    UI._theme = ThemeMod.LoadSaved() or ThemeMod.LoadFromExtState() or ThemeMod.Default()
    -- Sync local version stamp so CheckThemeUpdates only fires on real changes
    UI._theme_version = ThemeMod.GetVersion()

    -- Apply scale (from opts, or default 1.0). Remembered so every theme
    -- reload path can re-apply it (audit B8: a hot-reload from ThemeTweaker
    -- silently dropped the DPI scale and the padding override).
    local scale = opts.scale or 1.0
    UI._scale = scale
    UI._padding_override = opts.padding
    ThemeMod.ApplyScale(UI._theme, scale)

    -- Scale window size too
    local sw = math.floor(width * scale + 0.5)
    local sh = math.floor(height * scale + 0.5)

    -- Persist window state across sessions (dock + position + size)
    -- Pass opts.persist = "your_script_id" to opt-in.
    UI._persist_id = opts.persist
    local dock = opts.dock or 0
    local x, y = opts.x, opts.y
    if UI._persist_id then
        local saved = Core.LoadWindowState(UI._persist_id)
        if saved then
            if saved.dock then dock = saved.dock end
            if saved.x then x = saved.x end
            if saved.y then y = saved.y end
            if saved.w and saved.w > 0 then sw = saved.w end
            if saved.h and saved.h > 0 then sh = saved.h end
        end
    end

    Core.Init(title, sw, sh, dock, x, y)

    -- Load font slots (title, h1, h2, body, caption, mono)
    Core.LoadFontSlots(UI._theme)
    Core.SetFontBody()  -- default to body text

    -- Frameless overlay mode (requires JS_ReaScriptAPI)
    if opts.frameless then
        Core.SetFrameless()
        if opts.topmost then Core.SetTopMost(true) end
    end

    -- Disable window-level scrollbar (toolbar/status-bar mode)
    UI._scrollable = opts.scrollable ~= false

    -- Override window padding (overrides theme.window_padding for this script)
    if opts.padding ~= nil then
        UI._theme.window_padding = opts.padding
    end

    -- Idle throttle: by default, frames where nothing changed are skipped to
    -- save CPU. Scripts with continuously animated content (live meters,
    -- waveforms, playback cursors) can opt out by passing idle_throttle=false.
    -- Granular alternative: call UI.RequestRedraw() each frame an animation runs.
    if opts.idle_throttle == false then
        Core.SetIdleThrottle(false)
    end

    -- Register a default OnClose so persist works even if the user never
    -- calls UI.OnClose. UI.OnClose() will replace this with a wrapped version.
    if UI._persist_id then
        Core.OnClose(function()
            pcall(Core.SaveWindowState, UI._persist_id)
        end)
    end
end

-- Live setter for the window padding (cells/labels are placed relative to it).
function UI.SetWindowPadding(n)
    if UI._theme then UI._theme.window_padding = n end
end

function UI.Run(loop_fn)
    local root_opts = { scrollable = UI._scrollable }
    Core.Run(function()
        Layout.Begin("root", UI._theme, root_opts)
        loop_fn(UI._theme)
        Layout.End()
        -- Update eyedropper if active (runs before tooltip layer in Core)
        Widgets.UpdateEyedropper(UI._theme)
    end)
end

function UI.OnClose(fn)
    -- Wrap user callback so we always save window state first when persist is on
    Core.OnClose(function()
        if UI._persist_id then
            pcall(Core.SaveWindowState, UI._persist_id)
        end
        if fn then fn() end
    end)
end

function UI.SaveTheme(name)
    ThemeMod.Save(UI._theme, name)
    -- CRITICAL: update our local version stamp to match the one Theme.Save
    -- just bumped. Without this, the next frame's CheckThemeUpdates would
    -- see a mismatch and RELOAD theme.lua, stomping any unsaved mutations
    -- still sitting in UI._theme. That was the "my font sizes don't stick"
    -- bug: user changes title (auto-save), then changes h1 (waiting for
    -- throttle), reload fires in between and the h1 change is lost.
    UI._theme_version = ThemeMod.GetVersion()
end

-- Every path that REPLACES UI._theme goes through this: re-applies the Init
-- scale and padding override before reloading the font slots (audit B8).
local function _adopt_theme(t)
    UI._theme = t
    if UI._scale and UI._scale ~= 1.0 then
        ThemeMod.ApplyScale(UI._theme, UI._scale)
    end
    if UI._padding_override ~= nil then
        UI._theme.window_padding = UI._padding_override
    end
    Core.LoadFontSlots(UI._theme)
    Core.SetFontBody()
end

function UI.LoadTheme(name)
    local t = ThemeMod.LoadSaved(name)
    if t then
        _adopt_theme(t)
        -- Sync our local version stamp with the on-disk one
        UI._theme_version = ThemeMod.GetVersion()
    end
end

-- Cross-script theme hot-reload. Call once per frame from your main loop;
-- if the theme tweaker (or another script) has saved a new theme since
-- last frame, we re-load the file and the next frame paints with the new
-- theme. Returns true if a reload happened.
-- Throttled (audit P17): GetVersion does a reaper.GetExtState round-trip and
-- allocates a string — pointless 30×/s per open window for an event that
-- happens once per manual theme save.
local THEME_CHECK_INTERVAL = 0.5
local _theme_last_check = 0

function UI.CheckThemeUpdates()
    local now = reaper.time_precise()
    if now - _theme_last_check < THEME_CHECK_INTERVAL then return false end
    _theme_last_check = now

    local v = ThemeMod.GetVersion()
    if v == 0 then return false end
    if v == UI._theme_version then return false end

    local t = ThemeMod.LoadSaved("theme")
    if t then
        _adopt_theme(t)
        UI._theme_version = v
        return true
    end
    return false
end

function UI.ResetTheme()
    _adopt_theme(ThemeMod.Default())
end

function UI.ApplyPreset(preset_key)
    _adopt_theme(ThemeMod.GetPreset(preset_key))
end

function UI.GetTheme()
    return UI._theme
end

function UI.SetTheme(theme)
    UI._theme = theme
end

-- ============================================================================
-- WIDGET SHORTCUTS (so user writes UI.Button instead of UI.Widgets.Button)
-- ============================================================================

-- Custom Window Chrome
-- Returns: closed (bool), settings_clicked (bool)
function UI.BeginWindow(title, opts)
    return Widgets.BeginWindow(title, UI._theme, opts)
end

function UI.EndWindow()
    Widgets.EndWindow()
end

-- Panel — Windows-style content container with auto-fit content height.
-- Three styles via opts.style: "filled" (default) | "groupbox" | "inset".
-- Other opts: { title="Group", padding=8, width=nil, bg=nil, border=true }
function UI.BeginPanel(id, opts)
    Widgets.BeginPanel(id, UI._theme, opts)
end

function UI.EndPanel()
    Widgets.EndPanel(UI._theme)
end

-- Font switching (new hierarchy). Direct references — a pure pass-through
-- wrapper costs one extra Lua call per invocation for nothing (audit P19,
-- PERFORMANCE.md rule 7). Only wrappers that inject UI._theme remain
-- functions.
UI.SetFontTitle   = Core.SetFontTitle     -- Window title, biggest bold
UI.SetFontH1      = Core.SetFontH1        -- Section headers
UI.SetFontH2      = Core.SetFontH2        -- Sub-section headers
UI.SetFontH2Bold  = Core.SetFontH2Bold    -- Sub-section bold
UI.SetFontBody    = Core.SetFontBody      -- Default body text
UI.SetFontCaption = Core.SetFontCaption   -- Small/hints
UI.SetFontMono    = Core.SetFontMono      -- Values, numbers

-- Legacy aliases
UI.SetFontPrimary     = Core.SetFontH1
UI.SetFontSecondary   = Core.SetFontBody
UI.SetFontTertiary    = Core.SetFontCaption
UI.SetFontPrimaryBold = Core.SetFontTitle

-- Text
function UI.Text(text, opts)
    Widgets.Text(text, UI._theme, opts)
end

-- Word-wrapped multi-line text (cached layout; see Widgets.TextWrapped)
function UI.TextWrapped(text, opts)
    Widgets.TextWrapped(text, UI._theme, opts)
end

function UI.TextColored(text, r, g, b, a)
    Widgets.TextColored(text, r, g, b, a, UI._theme)
end

function UI.Header(text)
    Widgets.Header(text, UI._theme)
end

-- Button
function UI.Button(id, label, opts)
    return Widgets.Button(id, label, UI._theme, opts)
end

-- Checkbox
function UI.Checkbox(id, label, checked, opts)
    return Widgets.Checkbox(id, label, checked, UI._theme, opts)
end

-- Sliders
function UI.SliderInt(id, label, value, min_val, max_val, opts)
    return Widgets.SliderInt(id, label, value, min_val, max_val, UI._theme, opts)
end

function UI.SliderDouble(id, label, value, min_val, max_val, opts)
    return Widgets.SliderDouble(id, label, value, min_val, max_val, UI._theme, opts)
end

-- Separator
function UI.Separator()
    Widgets.Separator(UI._theme)
end

-- Combo
function UI.Combo(id, label, current_index, items, opts)
    return Widgets.Combo(id, label, current_index, items, UI._theme, opts)
end

-- Text Input
function UI.InputText(id, label, text, opts)
    return Widgets.InputText(id, label, text, UI._theme, opts)
end

-- Radio Group
function UI.RadioGroup(id, label, current_index, items, opts)
    return Widgets.RadioGroup(id, label, current_index, items, UI._theme, opts)
end

-- Progress Bar
function UI.ProgressBar(id, fraction, opts)
    Widgets.ProgressBar(id, fraction, UI._theme, opts)
end

-- Context Menu. opts (optional): {rect={x,y,w,h}} or {scope="item"} to bind
-- the trigger zone (default: whole window — see Widgets.ContextMenu).
function UI.ContextMenu(id, items, opts)
    Widgets.ContextMenu(id, items, UI._theme, opts)
end

-- Native OS menu (gfx.showmenu): nested submenus/checks for free, blocking.
UI.NativeMenu = Widgets.NativeMenu

-- Horizontal menu bar built on NativeMenu
function UI.MenuBar(id, menus)
    return Widgets.MenuBar(id, menus, UI._theme)
end

-- Table
function UI.Table(id, columns, rows, opts)
    return Widgets.Table(id, columns, rows, UI._theme, opts)
end

-- Modal Dialog
function UI.BeginModal(id, title, opts)
    Widgets.BeginModal(id, title, UI._theme, opts)
end

function UI.EndModal()
    Widgets.EndModal()
end

-- Drag & Drop
function UI.BeginDragSource(id, payload, drag_type, display_text)
    return Widgets.BeginDragSource(id, payload, drag_type, display_text)
end

function UI.BeginDropTarget(x, y, w, h, accept_type)
    return Widgets.BeginDropTarget(x, y, w, h, accept_type, UI._theme)
end

function UI.DrawDragPreview()
    Widgets.DrawDragPreview(UI._theme)
end

function UI.IsDragging(drag_type)
    return Widgets.IsDragging(drag_type)
end

-- Images
UI.LoadImage = Widgets.LoadImage
UI.UnloadImage = Widgets.UnloadImage

-- Color Picker
function UI.ColorPicker(id, label, color, opts)
    return Widgets.ColorPicker(id, label, color, UI._theme, opts)
end

-- Eyedropper (screen color sampler)
function UI.StartEyedropper(callback)
    return Widgets.StartEyedropper(callback)
end

function UI.IsEyedropperActive()
    return Widgets.IsEyedropperActive()
end

-- Number Input
function UI.NumberInput(id, label, value, min_val, max_val, opts)
    return Widgets.NumberInput(id, label, value, min_val, max_val, UI._theme, opts)
end

-- Multi-line Text Edit
function UI.TextEdit(id, text, opts)
    return Widgets.TextEdit(id, text, UI._theme, opts)
end

function UI.Image(img, opts)
    Widgets.Image(img, UI._theme, opts)
end

function UI.ImageButton(id, img, opts)
    return Widgets.ImageButton(id, img, UI._theme, opts)
end

-- Docking
function UI.Dock(dock_id)
    Core.Dock(dock_id)
end

function UI.ToggleDock()
    Core.ToggleDock()
end

function UI.IsDocked()
    return Core.IsDocked()
end

-- Cursor
UI.SetCursor = Core.SetCursor

-- Animation
UI.Animate = Core.Animate
UI.AnimateColor = Core.AnimateColor

-- Idle throttle escape hatch — call each frame to keep the UI redrawing.
-- Use this when displaying live data (peak meters, playback time, etc.) so
-- the toolkit doesn't enter idle mode and freeze the visual.
UI.RequestRedraw = Core.RequestRedraw
-- Deadline variant (egui request_repaint_after): wake the idle loop at an
-- absolute reaper.time_precise() timestamp — for timed reveals/fades.
UI.RequestRedrawAt = Core.RequestRedrawAt
UI.SetIdleThrottle = Core.SetIdleThrottle

-- Disabled scope (ImGui BeginDisabled/EndDisabled): widgets inside the scope
-- skip interaction and draw grayed. BeginDisabled(false) is a transparent
-- level so call sites can stay unconditional.
UI.BeginDisabled = Core.BeginDisabled
UI.EndDisabled = Core.EndDisabled
UI.IsDisabled = Core.IsDisabled

-- Last-item queries (ImGui IsItemHovered family) — call right AFTER a widget
UI.IsItemHovered = Core.IsItemHovered
UI.IsItemClicked = Core.IsItemClicked
UI.IsItemRightClicked = Core.IsItemRightClicked
UI.IsItemDoubleClicked = Core.IsItemDoubleClicked
UI.GetLastItemRect = Core.GetLastItemRect

-- Input consumption (custom widgets that handle a key/wheel tick call these
-- so the toolkit's fallbacks — ESC-close, container scroll — stay quiet)
UI.ConsumeChar = Core.ConsumeChar
UI.ConsumeWheel = Core.ConsumeWheel

-- Focus chain (Tab navigation)
UI.FocusNext = Core.FocusNext
UI.FocusPrev = Core.FocusPrev
UI.RegisterFocusable = Core.RegisterFocusable

-- Programmatic focus: pass an InputText / TextEdit widget id to give it
-- keyboard focus on the next frame. Pass nil to clear focus.
UI.SetFocus = Core.SetFocus
UI.IsFocused = Core.IsFocused

-- Persistent layout
UI.SaveWindowState = Core.SaveWindowState
UI.LoadWindowState = Core.LoadWindowState
UI.SavePersistent = Core.SavePersistent

-- Config files (CP_Config/<script_id>.lua) — preferred over ExtState for
-- non-trivial app state. One file per script, one disk write per save.
UI.SaveConfig = Core.SaveConfig
UI.LoadConfig = Core.LoadConfig
UI.LoadPersistent = Core.LoadPersistent

-- Native GFX drawing
UI.DrawRoundRect = Core.DrawRoundRect
UI.DrawCircle = Core.DrawCircle
UI.DrawTriangle = Core.DrawTriangle
UI.DrawArc = Core.DrawArc
UI.DrawGradientRect = Core.DrawGradientRect

-- ============================================================================
-- STYLE OVERRIDES (ImGui PushStyleColor idiom)
-- ============================================================================
-- Temporarily replace a theme color for the next widget(s), then restore:
--   UI.PushStyleColor("accent", 0.9, 0.2, 0.2)   -- danger red
--   UI.Button("del", "Delete")
--   UI.PopStyleColor()
-- Stack entries and replacement tables are pooled — zero allocation in
-- steady state. Overrides must be popped within the same frame.
local _style_stack = {}
local _style_top = 0

function UI.PushStyleColor(key, r, g, b, a)
    _style_top = _style_top + 1
    local e = _style_stack[_style_top]
    if not e then
        e = { repl = {} }
        _style_stack[_style_top] = e
    end
    e.key = key
    e.prev = UI._theme.colors[key]
    local repl = e.repl
    repl[1], repl[2], repl[3], repl[4] = r, g, b, a or 1
    UI._theme.colors[key] = repl
end

function UI.PopStyleColor(count)
    count = count or 1
    for _ = 1, count do
        if _style_top == 0 then break end
        local e = _style_stack[_style_top]
        UI._theme.colors[e.key] = e.prev
        _style_top = _style_top - 1
    end
end

-- Frameless / Overlay
function UI.SetPosition(x, y)
    Core.SetPosition(x, y)
end

-- Resize the gfx window at runtime (mainly useful for frameless overlays
-- whose content size depends on dynamic data). Returns true on success.
function UI.SetSize(w, h)
    return Core.SetSize(w, h)
end

function UI.SetTopMost(topmost)
    Core.SetTopMost(topmost)
end

function UI.IsFrameless()
    return Core.IsFrameless()
end

-- Anchor to REAPER window (proportional positioning)
-- x/y = 0.0-1.0 position on REAPER window, offset_x/y = pixel offset
function UI.SetAnchor(opts)
    return Core.SetAnchor(opts)
end

function UI.ClearAnchor()
    Core.ClearAnchor()
end

-- Tabs
function UI.TabBar(id, tabs, active_tab, opts)
    return Widgets.TabBar(id, tabs, active_tab, UI._theme, opts)
end

-- Collapsing header
function UI.CollapsingHeader(id, label, is_open)
    return Widgets.CollapsingHeader(id, label, is_open, UI._theme)
end

-- Tooltip (call right after the widget it belongs to)
function UI.Tooltip(text)
    Widgets.Tooltip(text, UI._theme)
end

-- Tree node
function UI.TreeNode(id, label, is_open, opts)
    return Widgets.TreeNode(id, label, is_open, UI._theme, opts)
end

function UI.TreePop()
    Widgets.TreePop(UI._theme)
end

-- Knob
function UI.Knob(id, label, value, default_value, opts)
    return Widgets.Knob(id, label, value, default_value, UI._theme, opts)
end

-- VU Meters
function UI.VMeter(id, peak_l, peak_r, opts)
    return Widgets.VMeter(id, peak_l, peak_r, UI._theme, opts)
end

function UI.HMeter(id, peak_l, peak_r, opts)
    return Widgets.HMeter(id, peak_l, peak_r, UI._theme, opts)
end

-- Canvas
function UI.Canvas(id, opts)
    return Widgets.Canvas(id, UI._theme, opts)
end

-- Toggle Button
function UI.ToggleButton(id, label, is_on, opts)
    return Widgets.ToggleButton(id, label, is_on, UI._theme, opts)
end

-- Range Slider
function UI.RangeSlider(id, label, val_min, val_max, range_min, range_max, opts)
    return Widgets.RangeSlider(id, label, val_min, val_max, range_min, range_max, UI._theme, opts)
end

-- Range Slider with a draggable current-value point inside the range.
-- Returns: value_changed, new_value, range_changed, new_min, new_max
function UI.ValueRangeSlider(id, label, value, val_min, val_max,
                             range_min, range_max, opts)
    return Widgets.ValueRangeSlider(id, label, value, val_min, val_max,
                                    range_min, range_max, UI._theme, opts)
end

-- Action List
function UI.ActionList(id, items, actions, opts)
    return Widgets.ActionList(id, items, actions, UI._theme, opts)
end

-- Collapsible Panel
function UI.CollapsiblePanel(id, label, is_open, opts)
    return Widgets.CollapsiblePanel(id, label, is_open, UI._theme, opts)
end

function UI.EndCollapsiblePanel()
    Widgets.EndCollapsiblePanel()
end

-- Reorderable List
function UI.ReorderableList(id, items, opts)
    return Widgets.ReorderableList(id, items, UI._theme, opts)
end

-- Interactive Table v2
function UI.InteractiveTable(id, columns, row_count, cell_render, opts)
    return Widgets.InteractiveTable(id, columns, row_count, cell_render, UI._theme, opts)
end

-- ============================================================================
-- LAYOUT SHORTCUTS (direct references — audit P19: pure pass-through
-- wrappers cost one Lua call per widget per frame for nothing)
-- ============================================================================
UI.SameLine = Layout.SameLine
UI.NewLine = Layout.NewLine
UI.Spacing = Layout.Spacing
UI.Indent = Layout.Indent
UI.Unindent = Layout.Unindent

-- Width / height available in the current container (after the cursor).
UI.GetAvailableWidth = Layout.GetAvailableWidth
UI.GetAvailableHeight = Layout.GetAvailableHeight

-- Absolute screen position of the layout cursor (where the next widget
-- would be drawn).
UI.GetCursorPos = Layout.GetCursorPos

function UI.BeginChild(id, w, h, opts)
    opts = opts or {}
    opts.theme = UI._theme
    Layout.BeginChild(id, w, h, opts)
end

UI.EndChild = Layout.EndChild

-- Wrap (auto-flow like CSS flex-wrap)
UI.BeginWrap = Layout.BeginWrap
UI.WrapItem = Layout.WrapItem
UI.EndWrap = Layout.EndWrap

-- Columns
UI.BeginColumns = Layout.BeginColumns
UI.NextColumn = Layout.NextColumn
UI.EndColumns = Layout.EndColumns

-- Weighted Row
UI.BeginWeightedRow = Layout.BeginWeightedRow
UI.WeightedCell = Layout.WeightedCell
UI.EndWeightedRow = Layout.EndWeightedRow

-- Grid
UI.BeginGrid = Layout.BeginGrid
UI.GridCell = Layout.GridCell
UI.EndGrid = Layout.EndGrid

-- Splitter
UI.Splitter = Layout.Splitter

-- List virtualization (F1 — ImGuiListClipper equivalent, O(visible) cost;
-- see Layout.ListClipper for the row-height contract)
UI.ListClipper = Layout.ListClipper
UI.EndListClipper = Layout.EndListClipper

return UI
