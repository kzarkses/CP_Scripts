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
Layout.Init(Core)
Widgets.Init(Core, Layout, ThemeMod)
Widgets.SetLog(LogMod)
Widgets.SetIcons(IconsMod)
Widgets.SetKeys(KeysMod)

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

    -- Apply scale (from opts, or auto-detect, or default 1.0)
    local scale = opts.scale or 1.0
    ThemeMod.ApplyScale(UI._theme, scale)

    -- Scale window size too
    local sw = math.floor(width * scale + 0.5)
    local sh = math.floor(height * scale + 0.5)

    Core.Init(title, sw, sh, opts.dock, opts.x, opts.y)
    Core.SetFont(UI._theme.fonts.default_size, UI._theme.fonts.default_face)

    -- Frameless overlay mode (requires JS_ReaScriptAPI)
    if opts.frameless then
        Core.SetFrameless()
        if opts.topmost then Core.SetTopMost(true) end
    end
end

function UI.Run(loop_fn)
    Core.Run(function()
        Layout.Begin("root", UI._theme)
        loop_fn(UI._theme)
        Layout.End()
    end)
end

function UI.OnClose(fn)
    Core.OnClose(fn)
end

function UI.SaveTheme()
    ThemeMod.Save(UI._theme)
end

function UI.ResetTheme()
    UI._theme = ThemeMod.Default()
    ThemeMod.ApplyScale(UI._theme, UI._theme.scale)
    Core.SetFont(UI._theme.fonts.default_size, UI._theme.fonts.default_face)
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

-- Text
function UI.Text(text, opts)
    Widgets.Text(text, UI._theme, opts)
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
function UI.Checkbox(id, label, checked)
    return Widgets.Checkbox(id, label, checked, UI._theme)
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

-- Context Menu (call in the area where right-click should trigger it)
function UI.ContextMenu(id, items)
    Widgets.ContextMenu(id, items, UI._theme)
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
function UI.LoadImage(path)
    return Widgets.LoadImage(path)
end

-- Color Picker
function UI.ColorPicker(id, label, color, opts)
    return Widgets.ColorPicker(id, label, color, UI._theme, opts)
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

-- Frameless / Overlay
function UI.SetPosition(x, y)
    Core.SetPosition(x, y)
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

-- ============================================================================
-- LAYOUT SHORTCUTS
-- ============================================================================
function UI.SameLine(spacing)
    Layout.SameLine(spacing)
end

function UI.NewLine()
    Layout.NewLine()
end

function UI.Spacing(amount)
    Layout.Spacing(amount)
end

function UI.Indent(amount)
    Layout.Indent(amount)
end

function UI.Unindent(amount)
    Layout.Unindent(amount)
end

function UI.BeginChild(id, w, h, opts)
    opts = opts or {}
    opts.theme = UI._theme
    Layout.BeginChild(id, w, h, opts)
end

function UI.EndChild()
    Layout.EndChild()
end

return UI
