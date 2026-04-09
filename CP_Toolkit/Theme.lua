-- CP_Toolkit Theme — Colors, fonts, spacing, style variables
-- All sizes are in LOGICAL units. Call Theme.ApplyScale() to adapt to DPI/monitor.

local Theme = {}

-- ============================================================================
-- DEFAULT THEME (dark, REAPER-ish) — values at scale 1.0
-- ============================================================================
function Theme.Default()
    return {
        -- Scale factor (1.0 = 100%, 1.5 = 150%, 2.0 = 200%)
        scale = 1.0,

        -- Colors: {r, g, b, a} in 0-1 range (not affected by scale)
        colors = {
            window_bg       = { 0.13, 0.13, 0.14, 1.0 },
            text            = { 0.88, 0.88, 0.88, 1.0 },
            text_disabled   = { 0.50, 0.50, 0.50, 1.0 },
            border          = { 0.30, 0.30, 0.32, 0.5 },

            button          = { 0.24, 0.24, 0.26, 1.0 },
            button_hovered  = { 0.32, 0.32, 0.35, 1.0 },
            button_active   = { 0.18, 0.18, 0.20, 1.0 },

            frame_bg        = { 0.20, 0.20, 0.22, 1.0 },
            frame_hovered   = { 0.26, 0.26, 0.28, 1.0 },
            frame_active    = { 0.18, 0.18, 0.20, 1.0 },

            accent          = { 0.35, 0.60, 0.85, 1.0 },
            accent_hovered  = { 0.45, 0.70, 0.95, 1.0 },
            accent_active   = { 0.25, 0.50, 0.75, 1.0 },

            header          = { 0.22, 0.22, 0.24, 1.0 },
            header_hovered  = { 0.28, 0.28, 0.30, 1.0 },
            header_active   = { 0.18, 0.18, 0.20, 1.0 },

            separator       = { 0.30, 0.30, 0.32, 0.5 },

            scrollbar_bg    = { 0.15, 0.15, 0.16, 0.3 },
            scrollbar_grab  = { 0.40, 0.40, 0.42, 0.5 },

            popup_bg        = { 0.16, 0.16, 0.18, 0.97 },

            tab             = { 0.20, 0.20, 0.22, 1.0 },
            tab_hovered     = { 0.30, 0.30, 0.33, 1.0 },
            tab_active      = { 0.26, 0.26, 0.29, 1.0 },

            -- Window chrome (custom header bar)
            title_bar       = { 0.10, 0.10, 0.11, 1.0 },
            title_text      = { 0.70, 0.70, 0.72, 1.0 },
            close_btn       = { 0.80, 0.25, 0.25, 1.0 },
            close_btn_hover = { 0.95, 0.30, 0.30, 1.0 },
        },

        -- Font settings (sizes are scaled)
        fonts = {
            face      = "Tahoma",     -- main font face for everything
            title     = 16,           -- window title (bold)
            h1        = 14,           -- section header ("Sliders", "Buttons")
            h2        = 12,           -- sub-section header, collapsing headers
            body      = 12,           -- default body text, widget labels
            caption   = 10,           -- hints, small labels, disabled text
            mono_face = "Consolas",   -- monospaced font face
            mono_size = 12,           -- monospaced size (values, time, dB)

            -- Legacy aliases (backward compat)
            default_face = "Tahoma",
            default_size = 12,
            header_size  = 14,
            small_size   = 10,
            primary      = 14,
            secondary    = 12,
            tertiary     = 10,
        },

        -- Window chrome
        header_height = 28,           -- custom title bar height

        -- Spacing / layout (all scaled)
        window_padding  = 10,
        frame_padding_x = 6,
        frame_padding_y = 4,
        item_spacing    = 5,
        indent          = 16,

        -- Rounding
        rounding = 0,

        -- Widget sizes (all scaled)
        scrollbar_width = 6,
        checkbox_size   = 16,
        slider_height   = 18,
        button_height   = 24,
        tab_height      = 26,
        combo_height    = 22,
    }
end

-- ============================================================================
-- APPLY SCALE — multiplies all size/spacing/font values by scale factor
-- Call this once after creating or loading a theme.
-- ============================================================================
function Theme.ApplyScale(t, scale)
    if not scale or scale == 1.0 then
        t.scale = 1.0
        return t
    end

    t.scale = scale
    local function s(v) return math.floor(v * scale + 0.5) end

    -- Fonts
    t.fonts.title    = s(t.fonts.title)
    t.fonts.h1       = s(t.fonts.h1)
    t.fonts.h2       = s(t.fonts.h2)
    t.fonts.body     = s(t.fonts.body)
    t.fonts.caption  = s(t.fonts.caption)
    t.fonts.mono_size = s(t.fonts.mono_size)
    -- Sync legacy aliases
    t.fonts.primary = t.fonts.h1
    t.fonts.secondary = t.fonts.body
    t.fonts.tertiary = t.fonts.caption
    t.fonts.default_size = t.fonts.body
    t.fonts.header_size = t.fonts.h1
    t.fonts.small_size = t.fonts.caption

    -- Spacing
    t.window_padding  = s(t.window_padding)
    t.frame_padding_x = s(t.frame_padding_x)
    t.frame_padding_y = s(t.frame_padding_y)
    t.item_spacing    = s(t.item_spacing)
    t.indent          = s(t.indent)

    -- Sizes
    t.scrollbar_width = s(t.scrollbar_width)
    t.checkbox_size   = s(t.checkbox_size)
    t.slider_height   = s(t.slider_height)
    t.button_height   = s(t.button_height)
    t.tab_height      = s(t.tab_height)
    t.combo_height    = s(t.combo_height)
    t.header_height   = s(t.header_height)

    return t
end

-- Convenience: scale a single pixel value using the theme's scale
function Theme.S(theme, v)
    return math.floor(v * (theme.scale or 1) + 0.5)
end

-- ============================================================================
-- LOAD FROM REAPER ExtState (CP_ImGuiStyles format)
-- ============================================================================
function Theme.LoadFromExtState()
    local saved = reaper.GetExtState("CP_ImGuiStyles", "styles")
    if saved == "" then return nil end

    local success, styles = pcall(function() return load("return " .. saved)() end)
    if not success or not styles then return nil end

    local t = Theme.Default()

    if styles.colors then
        local function hex_to_rgba(hex)
            if not hex or hex == 0 then return nil end
            local a = (hex & 0xFF) / 255
            local b = ((hex >> 8) & 0xFF) / 255
            local g = ((hex >> 16) & 0xFF) / 255
            local r = ((hex >> 24) & 0xFF) / 255
            return { r, g, b, a }
        end

        local map = {
            window_bg        = "window_bg",
            text             = "text",
            border           = "border",
            button           = "button",
            button_hovered   = "button_hovered",
            button_active    = "button_active",
            frame_bg         = "frame_bg",
            frame_bg_hovered = "frame_hovered",
            frame_bg_active  = "frame_active",
            header           = "header",
            header_hovered   = "header_hovered",
            header_active    = "header_active",
            separator        = "separator",
            slider_grab      = "accent",
            slider_grab_active = "accent_active",
            checkmark        = "accent",
        }

        for src_key, dst_key in pairs(map) do
            if styles.colors[src_key] then
                local c = hex_to_rgba(styles.colors[src_key])
                if c then t.colors[dst_key] = c end
            end
        end
    end

    if styles.spacing then
        t.item_spacing    = styles.spacing.item_spacing_y or t.item_spacing
        t.frame_padding_x = styles.spacing.frame_padding_x or t.frame_padding_x
        t.frame_padding_y = styles.spacing.frame_padding_y or t.frame_padding_y
        t.window_padding  = styles.spacing.window_padding_x or t.window_padding
    end

    if styles.fonts and styles.fonts.main then
        t.fonts.default_face = styles.fonts.main.name or t.fonts.default_face
        t.fonts.default_size = styles.fonts.main.size or t.fonts.default_size
    end

    return t
end

-- ============================================================================
-- HELPERS
-- ============================================================================
function Theme.Color(theme, key)
    local c = theme.colors[key]
    if c then return c[1], c[2], c[3], c[4] or 1 end
    return 0.5, 0.5, 0.5, 1
end

function Theme.Lerp(c1, c2, t)
    return {
        c1[1] + (c2[1] - c1[1]) * t,
        c1[2] + (c2[2] - c1[2]) * t,
        c1[3] + (c2[3] - c1[3]) * t,
        (c1[4] or 1) + ((c2[4] or 1) - (c1[4] or 1)) * t,
    }
end

-- ============================================================================
-- SERIALIZATION (Lua table → string → file)
-- ============================================================================
local function serialize_value(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "number" then
        return string.format("%.6g", v)
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = {}
        local next_indent = indent .. "  "
        -- Check if it's an array (sequential integer keys)
        local is_array = true
        local count = 0
        for _ in pairs(v) do count = count + 1 end
        for i = 1, count do
            if v[i] == nil then is_array = false break end
        end
        if is_array and count > 0 and count <= 4 then
            -- Short array on one line (for colors)
            local items = {}
            for i = 1, count do items[i] = serialize_value(v[i]) end
            return "{ " .. table.concat(items, ", ") .. " }"
        else
            for k, val in pairs(v) do
                local key_str
                if type(k) == "number" then
                    key_str = "[" .. k .. "]"
                else
                    key_str = k
                end
                parts[#parts + 1] = next_indent .. key_str .. " = " .. serialize_value(val, next_indent)
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
        end
    end
    return "nil"
end

-- ============================================================================
-- CONFIG FILE PATH
-- ============================================================================
local function get_config_dir()
    return reaper.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Config/"
end

local function get_theme_path(name)
    return get_config_dir() .. (name or "theme") .. ".lua"
end

local function ensure_config_dir()
    local dir = get_config_dir()
    reaper.RecursiveCreateDirectory(dir, 0)
end

-- ============================================================================
-- SAVE / LOAD THEME (file-based, Lua native serialization)
-- ============================================================================
function Theme.Save(t, name)
    ensure_config_dir()
    local path = get_theme_path(name)

    -- Build saveable data (exclude runtime/computed fields)
    local data = {
        colors = {},
        fonts = {
            face = t.fonts.face,
            title = t.fonts.title,
            h1 = t.fonts.h1,
            h2 = t.fonts.h2,
            body = t.fonts.body,
            caption = t.fonts.caption,
            mono_face = t.fonts.mono_face,
            mono_size = t.fonts.mono_size,
        },
        window_padding = t.window_padding,
        frame_padding_x = t.frame_padding_x,
        frame_padding_y = t.frame_padding_y,
        item_spacing = t.item_spacing,
        indent = t.indent,
        header_height = t.header_height,
        checkbox_size = t.checkbox_size,
        slider_height = t.slider_height,
        button_height = t.button_height,
        tab_height = t.tab_height,
        combo_height = t.combo_height,
        scrollbar_width = t.scrollbar_width,
    }

    for key, c in pairs(t.colors) do
        data.colors[key] = { c[1], c[2], c[3], c[4] or 1 }
    end

    local file = io.open(path, "w")
    if not file then return false end
    file:write("-- CP_Toolkit Theme: " .. (name or "theme") .. "\n")
    file:write("return " .. serialize_value(data) .. "\n")
    file:close()
    return true
end

function Theme.LoadSaved(name)
    local path = get_theme_path(name)
    local file = io.open(path, "r")
    if not file then return nil end
    file:close()

    local ok, data = pcall(dofile, path)
    if not ok or not data then return nil end

    local t = Theme.Default()

    -- Apply loaded data
    if data.colors then
        for key, c in pairs(data.colors) do
            if t.colors[key] then t.colors[key] = c end
        end
    end

    if data.fonts then
        t.fonts.face      = data.fonts.face or t.fonts.face
        t.fonts.title     = data.fonts.title or t.fonts.title
        t.fonts.h1        = data.fonts.h1 or t.fonts.h1
        t.fonts.h2        = data.fonts.h2 or t.fonts.h2
        t.fonts.body      = data.fonts.body or t.fonts.body
        t.fonts.caption   = data.fonts.caption or t.fonts.caption
        t.fonts.mono_face = data.fonts.mono_face or t.fonts.mono_face
        t.fonts.mono_size = data.fonts.mono_size or t.fonts.mono_size
        -- Sync legacy aliases
        t.fonts.default_face = t.fonts.face
        t.fonts.primary      = t.fonts.h1
        t.fonts.secondary    = t.fonts.body
        t.fonts.tertiary     = t.fonts.caption
        t.fonts.default_size = t.fonts.body
        t.fonts.header_size  = t.fonts.h1
        t.fonts.small_size   = t.fonts.caption
    end

    t.window_padding = data.window_padding or t.window_padding
    t.frame_padding_x = data.frame_padding_x or t.frame_padding_x
    t.frame_padding_y = data.frame_padding_y or t.frame_padding_y
    t.item_spacing = data.item_spacing or t.item_spacing
    t.indent = data.indent or t.indent
    t.header_height = data.header_height or t.header_height
    t.checkbox_size = data.checkbox_size or t.checkbox_size
    t.slider_height = data.slider_height or t.slider_height
    t.button_height = data.button_height or t.button_height
    t.tab_height = data.tab_height or t.tab_height
    t.combo_height = data.combo_height or t.combo_height
    t.scrollbar_width = data.scrollbar_width or t.scrollbar_width

    return t
end

-- ============================================================================
-- THEME PRESETS
-- ============================================================================
function Theme.Presets()
    return {
        { name = "Default Dark", key = "default_dark" },
        { name = "REAPER Classic", key = "reaper_classic" },
        { name = "Light", key = "light" },
        { name = "Midnight", key = "midnight" },
    }
end

function Theme.GetPreset(key)
    if key == "default_dark" then
        return Theme.Default()

    elseif key == "reaper_classic" then
        local t = Theme.Default()
        t.colors.window_bg       = { 0.18, 0.18, 0.18, 1.0 }
        t.colors.text            = { 0.78, 0.78, 0.78, 1.0 }
        t.colors.accent          = { 0.40, 0.55, 0.40, 1.0 }
        t.colors.accent_hovered  = { 0.50, 0.65, 0.50, 1.0 }
        t.colors.accent_active   = { 0.30, 0.45, 0.30, 1.0 }
        t.colors.button          = { 0.28, 0.28, 0.28, 1.0 }
        t.colors.button_hovered  = { 0.35, 0.35, 0.35, 1.0 }
        t.colors.header          = { 0.22, 0.22, 0.22, 1.0 }
        t.colors.title_bar       = { 0.14, 0.14, 0.14, 1.0 }
        t.colors.frame_bg        = { 0.22, 0.22, 0.22, 1.0 }
        t.colors.tab_active      = { 0.30, 0.30, 0.30, 1.0 }
        return t

    elseif key == "light" then
        local t = Theme.Default()
        t.colors.window_bg       = { 0.92, 0.92, 0.93, 1.0 }
        t.colors.text            = { 0.15, 0.15, 0.17, 1.0 }
        t.colors.text_disabled   = { 0.50, 0.50, 0.52, 1.0 }
        t.colors.border          = { 0.72, 0.72, 0.74, 0.5 }
        t.colors.accent          = { 0.20, 0.45, 0.75, 1.0 }
        t.colors.accent_hovered  = { 0.30, 0.55, 0.85, 1.0 }
        t.colors.accent_active   = { 0.15, 0.35, 0.65, 1.0 }
        t.colors.button          = { 0.82, 0.82, 0.84, 1.0 }
        t.colors.button_hovered  = { 0.75, 0.75, 0.78, 1.0 }
        t.colors.button_active   = { 0.68, 0.68, 0.72, 1.0 }
        t.colors.frame_bg        = { 0.85, 0.85, 0.87, 1.0 }
        t.colors.frame_hovered   = { 0.80, 0.80, 0.83, 1.0 }
        t.colors.frame_active    = { 0.75, 0.75, 0.78, 1.0 }
        t.colors.header          = { 0.82, 0.82, 0.84, 1.0 }
        t.colors.header_hovered  = { 0.76, 0.76, 0.79, 1.0 }
        t.colors.separator       = { 0.70, 0.70, 0.72, 0.5 }
        t.colors.popup_bg        = { 0.95, 0.95, 0.96, 0.98 }
        t.colors.tab             = { 0.85, 0.85, 0.87, 1.0 }
        t.colors.tab_hovered     = { 0.78, 0.78, 0.81, 1.0 }
        t.colors.tab_active      = { 0.90, 0.90, 0.92, 1.0 }
        t.colors.title_bar       = { 0.82, 0.82, 0.84, 1.0 }
        t.colors.title_text      = { 0.25, 0.25, 0.27, 1.0 }
        t.colors.close_btn       = { 0.80, 0.25, 0.25, 1.0 }
        return t

    elseif key == "midnight" then
        local t = Theme.Default()
        t.colors.window_bg       = { 0.08, 0.08, 0.12, 1.0 }
        t.colors.text            = { 0.80, 0.82, 0.90, 1.0 }
        t.colors.accent          = { 0.40, 0.50, 0.90, 1.0 }
        t.colors.accent_hovered  = { 0.50, 0.60, 1.00, 1.0 }
        t.colors.accent_active   = { 0.30, 0.40, 0.80, 1.0 }
        t.colors.button          = { 0.15, 0.15, 0.22, 1.0 }
        t.colors.button_hovered  = { 0.22, 0.22, 0.32, 1.0 }
        t.colors.frame_bg        = { 0.12, 0.12, 0.18, 1.0 }
        t.colors.header          = { 0.12, 0.12, 0.18, 1.0 }
        t.colors.title_bar       = { 0.06, 0.06, 0.09, 1.0 }
        t.colors.popup_bg        = { 0.10, 0.10, 0.16, 0.98 }
        t.colors.tab             = { 0.12, 0.12, 0.18, 1.0 }
        t.colors.tab_active      = { 0.18, 0.18, 0.28, 1.0 }
        t.colors.separator       = { 0.20, 0.20, 0.30, 0.5 }
        t.colors.border          = { 0.20, 0.20, 0.30, 0.5 }
        return t
    end

    return Theme.Default()
end

-- List saved theme files in config dir
function Theme.ListSaved()
    local dir = get_config_dir()
    local themes = {}
    local idx = 0
    while true do
        local filename = reaper.EnumerateFiles(dir, idx)
        if not filename then break end
        if filename:match("%.lua$") then
            local name = filename:match("^(.-)%.lua$")
            themes[#themes + 1] = name
        end
        idx = idx + 1
    end
    return themes
end

-- ============================================================================
-- COLOR GROUP HELPERS (for theme editor)
-- ============================================================================
-- Returns organized color groups for the theme editor UI
function Theme.GetColorGroups()
    return {
        { name = "Base",     keys = { "window_bg", "text", "text_disabled", "border", "separator" } },
        { name = "Accent",   keys = { "accent", "accent_hovered", "accent_active" } },
        { name = "Buttons",  keys = { "button", "button_hovered", "button_active" } },
        { name = "Frames",   keys = { "frame_bg", "frame_hovered", "frame_active" } },
        { name = "Headers",  keys = { "header", "header_hovered", "header_active" } },
        { name = "Tabs",     keys = { "tab", "tab_hovered", "tab_active" } },
        { name = "Popups",   keys = { "popup_bg", "scrollbar_bg", "scrollbar_grab" } },
    }
end

-- Human-readable label for a color key
function Theme.GetColorLabel(key)
    local labels = {
        window_bg = "Window BG", text = "Text", text_disabled = "Text Dim",
        border = "Border", separator = "Separator",
        accent = "Accent", accent_hovered = "Accent Hover", accent_active = "Accent Active",
        button = "Button", button_hovered = "Button Hover", button_active = "Button Active",
        frame_bg = "Frame BG", frame_hovered = "Frame Hover", frame_active = "Frame Active",
        header = "Header", header_hovered = "Header Hover", header_active = "Header Active",
        tab = "Tab", tab_hovered = "Tab Hover", tab_active = "Tab Active",
        popup_bg = "Popup BG", scrollbar_bg = "Scroll BG", scrollbar_grab = "Scroll Grab",
    }
    return labels[key] or key
end

return Theme
