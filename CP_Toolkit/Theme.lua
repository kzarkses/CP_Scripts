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
        },

        -- Font settings (sizes are scaled)
        fonts = {
            default_face = "Arial",
            default_size = 14,
            header_size  = 16,
            small_size   = 12,
        },

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
    t.fonts.default_size = s(t.fonts.default_size)
    t.fonts.header_size  = s(t.fonts.header_size)
    t.fonts.small_size   = s(t.fonts.small_size)

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
-- SAVE / LOAD TOOLKIT THEME (own ExtState, separate from ImGui styles)
-- ============================================================================
local EXTSTATE_SECTION = "CP_Toolkit_Theme"

function Theme.Save(t)
    -- Serialize colors
    local data = { colors = {}, spacing = {}, fonts = {}, sizes = {} }

    for key, c in pairs(t.colors) do
        data.colors[key] = string.format("%.3f,%.3f,%.3f,%.3f", c[1], c[2], c[3], c[4] or 1)
    end

    data.spacing.window_padding = t.window_padding
    data.spacing.frame_padding_x = t.frame_padding_x
    data.spacing.frame_padding_y = t.frame_padding_y
    data.spacing.item_spacing = t.item_spacing
    data.spacing.indent = t.indent

    data.fonts.default_face = t.fonts.default_face
    data.fonts.default_size = t.fonts.default_size
    data.fonts.header_size = t.fonts.header_size
    data.fonts.small_size = t.fonts.small_size

    data.sizes.checkbox_size = t.checkbox_size
    data.sizes.slider_height = t.slider_height
    data.sizes.button_height = t.button_height
    data.sizes.tab_height = t.tab_height
    data.sizes.combo_height = t.combo_height
    data.sizes.scrollbar_width = t.scrollbar_width

    -- Serialize to string
    local parts = {}
    for section, values in pairs(data) do
        for key, val in pairs(values) do
            parts[#parts + 1] = section .. "." .. key .. "=" .. tostring(val)
        end
    end

    reaper.SetExtState(EXTSTATE_SECTION, "theme", table.concat(parts, ";"), true)
end

function Theme.LoadSaved()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, "theme")
    if saved == "" then return nil end

    local t = Theme.Default()

    for entry in saved:gmatch("[^;]+") do
        local path, val = entry:match("^(.-)=(.+)$")
        if path and val then
            local section, key = path:match("^(.-)%.(.+)$")
            if section == "colors" then
                local r, g, b, a = val:match("([%d%.]+),([%d%.]+),([%d%.]+),([%d%.]+)")
                if r then
                    t.colors[key] = { tonumber(r), tonumber(g), tonumber(b), tonumber(a) }
                end
            elseif section == "spacing" then
                if key == "window_padding" then t.window_padding = tonumber(val)
                elseif key == "frame_padding_x" then t.frame_padding_x = tonumber(val)
                elseif key == "frame_padding_y" then t.frame_padding_y = tonumber(val)
                elseif key == "item_spacing" then t.item_spacing = tonumber(val)
                elseif key == "indent" then t.indent = tonumber(val)
                end
            elseif section == "fonts" then
                if key == "default_face" then t.fonts.default_face = val
                elseif key == "default_size" then t.fonts.default_size = tonumber(val)
                elseif key == "header_size" then t.fonts.header_size = tonumber(val)
                elseif key == "small_size" then t.fonts.small_size = tonumber(val)
                end
            elseif section == "sizes" then
                local num = tonumber(val)
                if num then t[key] = num end
            end
        end
    end

    return t
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
