-- CP_Toolkit Theme — Colors, fonts, spacing, style variables
-- All sizes are in LOGICAL units. Call Theme.ApplyScale() to adapt to DPI/monitor.

local Theme = {}

-- ============================================================================
-- DEFAULT THEME (dark, REAPER-ish) — values at scale 1.0
-- ============================================================================
-- ============================================================================
-- MACROS — the six numbers a theme is really made of
-- ============================================================================
-- The colour list below is forty-odd keys, and editing it by hand produces
-- exactly one outcome: a pile of near-identical greys. Measured on a real
-- hand-tuned theme — window 0.18, surface 0.16, surface2 0.20, frame 0.22,
-- header 0.22, tab 0.20, list 0.18 — seven levels inside six hundredths, with
-- a border at 0.30 × 0.5 alpha (≈0.25 effective) that could not draw a line
-- between any of them. Nothing separated because nothing was far enough apart.
--
-- So the chrome is DERIVED from six macros instead of authored key by key:
--
--   base       the deepest ground; everything else climbs from it
--   step       the distance between two levels — this IS the contrast knob
--   primary    "active, chosen, yours" — the accent
--   secondary  the second voice: selection, links, informational chrome
--   text       text luminance
--   outline    how strongly elements are framed (0 = none, 1 = hard edges)
--
-- Levels, and what may live on each — a widget picks a LEVEL, never a colour:
--   L0 base            the window
--   L1 base + step     panels, lists, popups
--   L2 base + 2·step   inputs, headers, tabs, alternating rows
--   L3 base + 3·step   buttons at rest
--   L4 base + 4·step   buttons hovered
-- A pressed control goes DOWN to L1: sunken, not brighter.
--
-- The neutral is tinted a few percent toward `secondary` on purpose. A pure
-- grey reads as unconsidered; the tint is what makes it look chosen.
function Theme.MacroDefault()
    return {
        base      = { 0.105, 0.105, 0.115 },
        step      = 0.055,
        primary   = { 0.40, 0.62, 0.45 },
        secondary = { 0.42, 0.55, 0.72 },
        text      = 0.92,
        outline   = 0.62,
    }
end

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

-- level → an rgba on the ladder, tinted toward `secondary`
local function lvl(m, n, a)
    local s = m.secondary
    local out = {}
    for i = 1, 3 do
        local g = m.base[i] + m.step * n
        out[i] = clamp01(g + (s[i] - 0.5) * 0.035)
    end
    out[4] = a or 1
    return out
end

local function scaled(c, k, a)
    return { clamp01(c[1] * k), clamp01(c[2] * k), clamp01(c[3] * k), a or 1 }
end

local function grey(v, a) return { v, v, v, a or 1 } end

-- Rewrite every CHROME colour from the macros. Role colours (play, record,
-- pending, …) are deliberately untouched: they mean something, so they are
-- not the theme's to reinterpret.
function Theme.ApplyMacro(t)
    local m = t.macro
    if not m then return t end
    local c = t.colors
    local pri, sec = m.primary, m.secondary

    c.window_bg   = lvl(m, 0)
    c.title_bar   = lvl(m, -0.4)
    c.surface     = lvl(m, 1)
    c.list_bg     = lvl(m, 1)
    c.popup_bg    = lvl(m, 1.4, 0.98)
    c.surface2    = lvl(m, 2)
    c.frame_bg    = lvl(m, 2)
    c.header      = lvl(m, 2)
    c.tab         = lvl(m, 1.4)
    c.list_alt_bg = lvl(m, 1.5)
    c.list_hover  = lvl(m, 2.4)
    c.frame_hovered  = lvl(m, 2.8)
    c.header_hovered = lvl(m, 3)
    c.tab_hovered    = lvl(m, 2.6)
    c.tab_active     = lvl(m, 3.4)
    c.button         = lvl(m, 3)
    c.button_hovered = lvl(m, 4.2)
    -- pressed goes DOWN, not up: a sunken control is the physical metaphor
    c.button_active  = lvl(m, 1)
    c.frame_active   = lvl(m, 1)
    c.header_active  = lvl(m, 1)

    -- Framing. Opaque on purpose: a half-alpha border over a dark ground is
    -- the thing that stopped drawing a line at all.
    local ow = 3.4 + 4.6 * m.outline
    c.border      = lvl(m, ow)
    c.border_soft = lvl(m, 2.2 + 2.2 * m.outline)
    c.separator   = lvl(m, ow * 0.85)
    c.list_grid   = lvl(m, 2.4, 0.55)

    c.text          = grey(clamp01(m.text))
    c.title_text    = grey(clamp01(m.text * 0.86))
    c.list_text     = grey(clamp01(m.text * 0.95))
    c.value_normal  = grey(clamp01(m.text * 0.85))
    c.text_mute     = grey(clamp01(m.text * 0.52))
    c.text_disabled = grey(clamp01(m.text * 0.40))

    c.accent         = { pri[1], pri[2], pri[3], 1 }
    c.accent_hovered = scaled(pri, 1.22)
    c.accent_active  = scaled(pri, 0.82)
    c.accent_dim     = scaled(pri, 0.62)
    c.list_selected      = { sec[1], sec[2], sec[3], 1 }
    c.list_selected_text = grey(1)
    c.scrollbar_bg   = lvl(m, 0.6, 0.35)
    c.scrollbar_grab = lvl(m, 4, 0.75)
    return t
end

function Theme.Default()
    local t = {
        -- Derived chrome: see Theme.MacroDefault. A theme file that carries a
        -- `macro` block is re-derived on load; one that does not keeps the
        -- literal colours it was hand-tuned with. The literals below are the
        -- pre-macro values — kept as the shape of the table, immediately
        -- overwritten by ApplyMacro at the bottom of this function.
        macro = Theme.MacroDefault(),
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

            -- List/table rendering (matches REAPER's "Window list" color layer)
            list_bg           = { 0.18, 0.18, 0.20, 1.0 },  -- list container background
            list_alt_bg       = { 0.16, 0.16, 0.18, 1.0 },  -- alternating row (every other)
            list_text         = { 0.85, 0.85, 0.85, 1.0 },  -- text inside lists
            list_grid         = { 0.25, 0.25, 0.27, 0.3 },  -- grid lines between rows/cols
            list_selected     = { 0.25, 0.50, 0.80, 1.0 },  -- selected row background
            list_selected_text = { 1.00, 1.00, 1.00, 1.0 }, -- selected row text
            list_hover        = { 0.22, 0.22, 0.25, 1.0 },  -- hovered row highlight

            -- Value coloring (for property displays, meters, etc.)
            value_normal    = { 0.75, 0.75, 0.75, 1.0 },
            value_modified  = { 0.00, 0.80, 0.60, 1.0 },
            value_negative  = { 0.80, 0.40, 0.60, 1.0 },

            popup_bg        = { 0.16, 0.16, 0.18, 0.97 },

            tab             = { 0.20, 0.20, 0.22, 1.0 },
            tab_hovered     = { 0.30, 0.30, 0.33, 1.0 },
            tab_active      = { 0.26, 0.26, 0.29, 1.0 },

            -- Window chrome (custom header bar)
            title_bar       = { 0.10, 0.10, 0.11, 1.0 },
            title_text      = { 0.70, 0.70, 0.72, 1.0 },
            close_btn       = { 0.80, 0.25, 0.25, 1.0 },
            close_btn_hover = { 0.95, 0.30, 0.30, 1.0 },

            -- Surface hierarchy (added 2026-05-10 for FX Browser refonte).
            -- surface  = elevated panels above window_bg (footer, toolbar);
            -- surface2 = next layer up (hover row, alt list).
            surface         = { 0.16, 0.16, 0.17, 1.0 },
            surface2        = { 0.20, 0.20, 0.22, 1.0 },
            border_soft     = { 0.22, 0.22, 0.24, 0.6 },
            text_mute       = { 0.40, 0.40, 0.42, 1.0 },

            -- Semantic accent variants for state coloring.
            accent_dim      = { 0.25, 0.42, 0.58, 1.0 },  -- selected row bg, primary btn bg
            danger          = { 0.78, 0.32, 0.32, 1.0 },  -- delete / clear
            bypass          = { 0.78, 0.62, 0.32, 1.0 },  -- amber for bypassed FX

            -- ROLE colours. Not decoration: these say what a lit control is
            -- DOING, and they are the only place the apps may take a hue from
            -- for transport state. Everything else uses the single accent —
            -- if every toggle is coloured, colour stops meaning anything, and
            -- the place it has to read at a glance is the clip grid, not Snap.
            -- Kept as theme tokens rather than literals copied into each app
            -- (ANALYSE_DesignSystem §4.1): a theme can restyle them once.
            play            = { 0.31, 0.75, 0.42, 1.0 },  -- playing / running
            record          = { 0.82, 0.34, 0.35, 1.0 },  -- capturing / armed to capture
            pending         = { 0.85, 0.65, 0.25, 1.0 },  -- queued, waiting for the boundary
            mute            = { 0.44, 0.48, 0.55, 1.0 },  -- silenced on purpose
            solo            = { 0.90, 0.80, 0.30, 1.0 },  -- the only one you hear
            mod             = { 0.62, 0.47, 0.86, 1.0 },  -- modulation source / depth
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
        separator_pad   = 4,    -- vertical padding above AND below a separator line

        -- Widget visual style:
        --   "flat"    — modern minimal (default for dark themes)
        --   "windows" — classic Win32 look: bevel buttons, framed inputs, raised tabs
        widget_style    = "flat",

        -- Rounding (design system v2): buttons/toggles round with
        -- `rounding`, inputs/sliders/chips with `rounding_small`,
        -- panels/popups with `rounding_large`. 0 everywhere = the legacy
        -- square look, pixel-identical to before.
        rounding       = 4,
        rounding_small = 3,
        rounding_large = 6,

        -- Widget sizes (all scaled)
        scrollbar_width = 6,
        checkbox_size   = 16,
        slider_height   = 18,
        button_height   = 24,
        tab_height      = 26,
        combo_height    = 22,

        -- Compact list / chip rows (added 2026-05-10 for FX Browser refonte).
        chip_h          = 20,    -- filter pills, user tabs
        row_h           = 22,    -- standard list row (matches combo_height)
        row_h_large     = 26,    -- chain row (matches tab_height)
        pad_small       = 4,     -- tight padding
        pad_large       = 10,    -- aerated padding (matches window_padding)
        gap             = 4,     -- inter-element horizontal gap
        gap_large       = 8,     -- inter-section gap
        splitter_w      = 3,     -- splitter handle width

        -- Tooltips (2026-07 audit pass: multi-line word-wrapped tooltips)
        tooltip_max_w   = 320,   -- wrap width in px (scaled)
        tooltip_delay   = 0.4,   -- hover delay in seconds (not scaled)
    }
    return Theme.ApplyMacro(t)
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
    t.separator_pad   = s(t.separator_pad)
    if t.chip_h      then t.chip_h      = s(t.chip_h)      end
    if t.row_h       then t.row_h       = s(t.row_h)       end
    if t.row_h_large then t.row_h_large = s(t.row_h_large) end
    if t.pad_small   then t.pad_small   = s(t.pad_small)   end
    if t.pad_large   then t.pad_large   = s(t.pad_large)   end
    if t.gap         then t.gap         = s(t.gap)         end
    if t.gap_large   then t.gap_large   = s(t.gap_large)   end
    if t.splitter_w  then t.splitter_w  = s(t.splitter_w)  end
    if t.tooltip_max_w then t.tooltip_max_w = s(t.tooltip_max_w) end
    if t.rounding and t.rounding > 0 then t.rounding = s(t.rounding) end
    if t.rounding_small and t.rounding_small > 0 then t.rounding_small = s(t.rounding_small) end
    if t.rounding_large and t.rounding_large > 0 then t.rounding_large = s(t.rounding_large) end

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
-- Cross-script theme version stamp.
-- ExtState section "CP_Toolkit", key "theme_version" — incremented on every
-- save so other running scripts can detect changes and reload (see
-- UI.CheckThemeUpdates). persist=false: in-memory only, zero disk I/O for
-- the bump itself. The theme file is the persistent source of truth.
local THEME_EXTSTATE_SECTION = "CP_Toolkit"
local THEME_VERSION_KEY = "theme_version"

function Theme.GetVersion()
    local v = reaper.GetExtState(THEME_EXTSTATE_SECTION, THEME_VERSION_KEY)
    return tonumber(v) or 0
end

function Theme.BumpVersion()
    local v = Theme.GetVersion() + 1
    -- persist=false: cross-script visible immediately, but no disk write
    reaper.SetExtState(THEME_EXTSTATE_SECTION, THEME_VERSION_KEY, tostring(v), false)
    return v
end

function Theme.Save(t, name)
    ensure_config_dir()
    local path = get_theme_path(name)

    -- Build saveable data (exclude runtime/computed fields)
    local data = {
        macro = t.macro,
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
        separator_pad = t.separator_pad,
        header_height = t.header_height,
        checkbox_size = t.checkbox_size,
        slider_height = t.slider_height,
        button_height = t.button_height,
        tab_height = t.tab_height,
        combo_height = t.combo_height,
        scrollbar_width = t.scrollbar_width,
        widget_style = t.widget_style,
        chip_h = t.chip_h,
        row_h = t.row_h,
        row_h_large = t.row_h_large,
        pad_small = t.pad_small,
        pad_large = t.pad_large,
        gap = t.gap,
        gap_large = t.gap_large,
        splitter_w = t.splitter_w,
        tooltip_max_w = t.tooltip_max_w,
        tooltip_delay = t.tooltip_delay,
        rounding = t.rounding,
        rounding_small = t.rounding_small,
        rounding_large = t.rounding_large,
    }

    for key, c in pairs(t.colors) do
        data.colors[key] = { c[1], c[2], c[3], c[4] or 1 }
    end

    local file = io.open(path, "w")
    if not file then return false end
    file:write("-- CP_Toolkit Theme: " .. (name or "theme") .. "\n")
    file:write("return " .. serialize_value(data) .. "\n")
    file:close()

    -- Broadcast change to other running scripts (only for the active "theme")
    if (name or "theme") == "theme" then
        Theme.BumpVersion()
    end
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

    -- A file that carries macros is re-derived from them; the literal colour
    -- list it also stores is then only an override layer for the few keys a
    -- user pinned by hand. A file WITHOUT macros predates them and is left
    -- exactly as authored — upgrading someone's theme without being asked
    -- would be the rudest possible reading of "make it more contrasted".
    if data.macro then
        for k, v in pairs(data.macro) do t.macro[k] = v end
        Theme.ApplyMacro(t)
    else
        t.macro = nil
    end

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
    t.separator_pad = data.separator_pad or t.separator_pad
    t.header_height = data.header_height or t.header_height
    t.checkbox_size = data.checkbox_size or t.checkbox_size
    t.slider_height = data.slider_height or t.slider_height
    t.button_height = data.button_height or t.button_height
    t.tab_height = data.tab_height or t.tab_height
    t.combo_height = data.combo_height or t.combo_height
    t.scrollbar_width = data.scrollbar_width or t.scrollbar_width
    t.widget_style = data.widget_style or t.widget_style
    t.chip_h      = data.chip_h      or t.chip_h
    t.row_h       = data.row_h       or t.row_h
    t.row_h_large = data.row_h_large or t.row_h_large
    t.pad_small   = data.pad_small   or t.pad_small
    t.pad_large   = data.pad_large   or t.pad_large
    t.gap         = data.gap         or t.gap
    t.gap_large   = data.gap_large   or t.gap_large
    t.splitter_w  = data.splitter_w  or t.splitter_w
    t.tooltip_max_w = data.tooltip_max_w or t.tooltip_max_w
    t.tooltip_delay = data.tooltip_delay or t.tooltip_delay
    -- rounding: 0 is a legitimate saved choice (square legacy look), so
    -- only nil falls back to the defaults
    if data.rounding ~= nil then t.rounding = data.rounding end
    if data.rounding_small ~= nil then t.rounding_small = data.rounding_small end
    if data.rounding_large ~= nil then t.rounding_large = data.rounding_large end

    return t
end

-- ============================================================================
-- THEME PRESETS
-- ============================================================================
-- Module constant (audit P18: rebuilt per call, called per frame by the
-- theme editor). Shared — do not mutate.
local PRESET_LIST = {
    { name = "Default Dark",  key = "default_dark" },
    { name = "REAPER Classic", key = "reaper_classic" },
    { name = "REAPER Light",  key = "reaper_light" },
    { name = "Light",         key = "light" },
    { name = "Midnight",      key = "midnight" },
}

function Theme.Presets()
    return PRESET_LIST
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

    elseif key == "reaper_light" then
        -- Matches REAPER's native Windows classic look (Actions list, FX browser,
        -- Media Explorer). Critical insight: the WINDOW background is a medium
        -- gray, NOT white. Only INNER CONTAINERS (lists, inputs, group boxes)
        -- are white. This creates the layered "panel" hierarchy that defines
        -- the Win32 look. Use UI.BeginPanel("filled") to wrap content properly.
        local t = Theme.Default()
        t.widget_style = "windows"

        -- LEVEL 1: window bg (gray) — what you see between/around panels
        t.colors.window_bg       = { 0.85, 0.85, 0.86, 1.0 }
        -- Text on the window_bg (labels outside panels): dark
        t.colors.text            = { 0.10, 0.10, 0.10, 1.0 }
        t.colors.text_disabled   = { 0.50, 0.50, 0.52, 1.0 }
        t.colors.border          = { 0.55, 0.55, 0.56, 1.0 }
        t.colors.separator       = { 0.65, 0.65, 0.66, 1.0 }

        -- Microsoft Windows accent blue for selection / focus
        t.colors.accent          = { 0.20, 0.45, 0.85, 1.0 }
        t.colors.accent_hovered  = { 0.30, 0.55, 0.92, 1.0 }
        t.colors.accent_active   = { 0.12, 0.35, 0.72, 1.0 }

        -- LEVEL 2: panels / frame backgrounds (containers, inputs)
        --   filled panel bg = white
        --   inset panel bg  = slightly darker (sunken)
        t.colors.frame_bg        = { 1.00, 1.00, 1.00, 1.0 }
        t.colors.frame_hovered   = { 0.96, 0.98, 1.00, 1.0 }
        t.colors.frame_active    = { 0.92, 0.96, 1.00, 1.0 }

        -- Buttons: classic 3D bevel — light gray base, light top/left edge,
        -- dark bottom/right edge. The Button widget reads widget_style and
        -- adds the bevel automatically when set to "windows".
        t.colors.button          = { 0.93, 0.93, 0.94, 1.0 }
        t.colors.button_hovered  = { 0.96, 0.97, 1.00, 1.0 }
        t.colors.button_active   = { 0.85, 0.88, 0.95, 1.0 }

        -- Headers (column headers, collapsing headers): same gray as window
        t.colors.header          = { 0.88, 0.88, 0.89, 1.0 }
        t.colors.header_hovered  = { 0.92, 0.94, 0.98, 1.0 }
        t.colors.header_active   = { 0.86, 0.90, 0.96, 1.0 }

        -- Popups (dropdown menus): white with thin border
        t.colors.popup_bg        = { 1.00, 1.00, 1.00, 1.0 }

        -- Tabs: gray inactive, white active (raised look)
        t.colors.tab             = { 0.85, 0.85, 0.86, 1.0 }
        t.colors.tab_hovered     = { 0.92, 0.92, 0.93, 1.0 }
        t.colors.tab_active      = { 1.00, 1.00, 1.00, 1.0 }

        -- Custom title bar (when frameless)
        t.colors.title_bar       = { 0.78, 0.78, 0.80, 1.0 }
        t.colors.title_text      = { 0.10, 0.10, 0.10, 1.0 }
        t.colors.close_btn       = { 0.80, 0.20, 0.20, 1.0 }
        t.colors.close_btn_hover = { 1.00, 0.30, 0.30, 1.0 }

        -- Scrollbar: subtle gray
        t.colors.scrollbar_bg    = { 0.78, 0.78, 0.79, 0.6 }
        t.colors.scrollbar_grab  = { 0.55, 0.55, 0.56, 0.8 }

        -- Lists: white bg, subtle grid, blue selection (sampled from REAPER
        -- Actions list + Browse FX + Contextual Toolbars screenshots)
        t.colors.list_bg           = { 1.00, 1.00, 1.00, 1.0 }
        t.colors.list_alt_bg       = { 0.96, 0.96, 0.97, 1.0 }
        t.colors.list_text         = { 0.10, 0.10, 0.10, 1.0 }
        t.colors.list_grid         = { 0.80, 0.80, 0.82, 0.5 }
        t.colors.list_selected     = { 0.20, 0.45, 0.85, 1.0 }
        t.colors.list_selected_text = { 1.00, 1.00, 1.00, 1.0 }
        t.colors.list_hover        = { 0.88, 0.93, 1.00, 1.0 }

        -- Value coloring on white frame_bg backgrounds
        t.colors.value_normal    = { 0.15, 0.15, 0.16, 1.0 }
        t.colors.value_modified  = { 0.10, 0.55, 0.25, 1.0 }
        t.colors.value_negative  = { 0.80, 0.15, 0.25, 1.0 }
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

-- List saved theme files in config dir.
-- CP_Config is shared with UI.SaveConfig script-state files (audit B23: the
-- ThemeTweaker used to list those too — loading one as a "theme" reset the
-- active theme, and its delete button could destroy a script's config).
-- Theme files are identified by the header line Theme.Save writes.
function Theme.ListSaved()
    local dir = get_config_dir()
    local themes = {}
    local idx = 0
    while true do
        local filename = reaper.EnumerateFiles(dir, idx)
        if not filename then break end
        if filename:match("%.lua$") then
            local f = io.open(dir .. "/" .. filename, "r")
            if f then
                local first = f:read("*l")
                f:close()
                if first and first:find("CP_Toolkit Theme", 1, true) then
                    themes[#themes + 1] = filename:match("^(.-)%.lua$")
                end
            end
        end
        idx = idx + 1
    end
    return themes
end

-- ============================================================================
-- COLOR GROUP HELPERS (for theme editor)
-- ============================================================================
-- Module constants (audit P18: these tables were rebuilt on EVERY call, and
-- the ThemeTweaker calls them 30+ times per frame — dozens of KB of garbage
-- per frame on the very page meant for tuning the rendering).
local COLOR_GROUPS = {
    { name = "Base",     keys = { "window_bg", "text", "text_disabled", "border", "separator" } },
    { name = "Accent",   keys = { "accent", "accent_hovered", "accent_active" } },
    { name = "Buttons",  keys = { "button", "button_hovered", "button_active" } },
    { name = "Frames",   keys = { "frame_bg", "frame_hovered", "frame_active" } },
    { name = "Headers",  keys = { "header", "header_hovered", "header_active" } },
    { name = "Lists",    keys = { "list_bg", "list_alt_bg", "list_text", "list_grid",
                                  "list_selected", "list_selected_text", "list_hover" } },
    { name = "Tabs",     keys = { "tab", "tab_hovered", "tab_active" } },
    { name = "Popups",   keys = { "popup_bg", "scrollbar_bg", "scrollbar_grab" } },
}

local COLOR_LABELS = {
    window_bg = "Window BG", text = "Text", text_disabled = "Text Dim",
    border = "Border", separator = "Separator",
    accent = "Accent", accent_hovered = "Accent Hover", accent_active = "Accent Active",
    button = "Button", button_hovered = "Button Hover", button_active = "Button Active",
    frame_bg = "Frame BG", frame_hovered = "Frame Hover", frame_active = "Frame Active",
    header = "Header", header_hovered = "Header Hover", header_active = "Header Active",
    list_bg = "List BG", list_alt_bg = "List Alt Row", list_text = "List Text",
    list_grid = "List Grid", list_selected = "List Selected", list_selected_text = "List Sel Text",
    list_hover = "List Hover",
    tab = "Tab", tab_hovered = "Tab Hover", tab_active = "Tab Active",
    popup_bg = "Popup BG", scrollbar_bg = "Scroll BG", scrollbar_grab = "Scroll Grab",
}

-- Returns organized color groups for the theme editor UI (shared constant —
-- do not mutate)
function Theme.GetColorGroups()
    return COLOR_GROUPS
end

-- Human-readable label for a color key
function Theme.GetColorLabel(key)
    return COLOR_LABELS[key] or key
end

return Theme
