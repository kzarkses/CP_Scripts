-- CP_Toolkit Theme — Colors, fonts, spacing, style variables
-- All sizes are in LOGICAL units. Call Theme.ApplyScale() to adapt to DPI/monitor.

local Theme = {}

-- ============================================================================
-- DEFAULT THEME (dark, REAPER-ish) — values at scale 1.0
-- ============================================================================
-- ============================================================================
-- THE RAMP — eight neutrals, written, not derived
-- ============================================================================
-- This used to be a macro system: six numbers, forty colours derived from them
-- by formula. It is gone, and the reasons are worth keeping.
--
--   • It never ran. No theme file on disk carried a `macro` block, so
--     LoadSaved set t.macro = nil in every script and the whole system slept.
--   • It was inert even when awake: LoadSaved called ApplyMacro and then
--     applied the 63 literal colours on top, so the macros decided nothing.
--   • It was destructive when it did fire: one turn of one knob rewrote 43 of
--     the 49 hand-editable colours, with no warning.
--   • And it left the product with NO identity. Theme.Default() was a
--     placeholder overwritten on its last line, so "what the product looks
--     like" was whatever CP_Config/theme.lua happened to hold.
--
-- A ramp of eight written numbers does not need to be derived from six others.
--
-- Measured off `Reapertips Theme – Green` v1.91 — the theme actually in use —
-- with lightness in CIE L*, because sRGB distance lies at the dark end.
-- The old ladder lived between L* 9.7 and L* 30. This one lives between
-- L* 14.7 and L* 53.4. That gap is the whole complaint: it was never a
-- contrast problem, it was a LIGHT problem, and adding contrast inside a box
-- that dark only hardens it.
--
--   n1  0.145  #252525  L* 14.7   app ground, gutters
--   n2  0.196  #323232  L* 20.8   panel surface        ← the base
--   n3  0.243  #3e3e3e  L* 26.2   raised: toolbar, header
--   n4  0.259  #424242  L* 28.0   canvas ground, control at rest
--   n5  0.298  #4c4c4c  L* 32.3   hover, light row
--   n6  0.345  #585858  L* 37.4   soft border
--   n7  0.420  #6b6b6b  L* 45.3   border
--   n8  0.502  #808080  L* 53.4   strong border, bar line
--
-- ACHROMATIC on purpose. The old lvl() tinted every neutral 3.5 % toward the
-- secondary, on the grounds that "a pure grey reads as unconsidered". That is
-- a web maxim and it is wrong in a DAW: here the colour belongs to the user's
-- content — their tracks, their clips, their envelopes — so the chrome has to
-- get out of its way. The reference theme is grey to the bit, R = G = B, on
-- essentially every neutral it defines.
--
-- Two values may repeat when the surfaces they paint are never adjacent, or
-- are separated by an edge. list_bg == surface is deliberate (a list sits
-- flush in its panel and is separated by its border — REAPER does the same:
-- genlist_bg and col_main_bg are both #323232). What is NOT allowed is what
-- this file used to do: five names — surface, list_bg, button_active,
-- frame_active, header_active — resolving to one identical colour, so that a
-- pressed control was indistinguishable from the panel carrying it.
Theme.RAMP = { 0.145, 0.196, 0.243, 0.259, 0.298, 0.345, 0.420, 0.502 }

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

local function scaled(c, k, a)
    return { clamp01(c[1] * k), clamp01(c[2] * k), clamp01(c[3] * k), a or 1 }
end

local function grey(v, a) return { v, v, v, a or 1 } end

-- A state is a DISPLACEMENT on the ramp, not another key. Rest sits on some
-- step; hover climbs one; pressed sinks one — sunken is the physical metaphor,
-- and it keeps "lit" free for the accent, which is a different channel.
--
-- The twelve state keys below (button/frame/header/tab × rest/hover/active)
-- stay for now because 704 read sites name them directly; they are simply no
-- longer allowed to collide. New code should ask for a step.
function Theme.Step(n, a)
    local r = Theme.RAMP
    if n < 1 then n = 1 elseif n > #r then n = #r end
    local lo = math.floor(n)
    local v = r[lo]
    if lo < n and r[lo + 1] then v = v + (r[lo + 1] - v) * (n - lo) end
    return { v, v, v, a or 1 }
end

function Theme.Default()
    local t = {
        -- Scale factor (1.0 = 100%, 1.5 = 150%, 2.0 = 200%)
        scale = 1.0,

        -- ================================================================
        -- THE IDENTITY — written, versioned, and the product's own
        -- ================================================================
        -- Every neutral here is a step of Theme.RAMP (top of this file), or a
        -- value written out between two steps. Reading this table tells you
        -- what the screen looks like without running anything — which is the
        -- whole point, and exactly what a derived table could never do.
        --
        -- A saved theme is a DIFF against this table (see Theme.Save), so a
        -- key added here reaches every theme ever saved. That is the cure for
        -- CP_Config/DEFAULT.lua: written before canvas_* and the roles
        -- existed, saved as a full snapshot of 44 keys out of 63, it left the
        -- chrome on one palette and the roll on another — and the piano roll
        -- came out DARKER than the window containing it.
        colors = {
            -- ---- ground --------------------------------------------------
            title_bar       = { 0.118, 0.118, 0.118, 1.0 },  -- deepest strip
            window_bg       = { 0.145, 0.145, 0.145, 1.0 },  -- n1
            surface         = { 0.196, 0.196, 0.196, 1.0 },  -- n2, the panel
            surface2        = { 0.243, 0.243, 0.243, 1.0 },  -- n3, raised
            popup_bg        = { 0.212, 0.212, 0.212, 1.0 },  -- opaque on purpose

            -- ---- fields sink, buttons rise --------------------------------
            -- REAPER ships the same relation: col_main_editbk #2a2a2a sits
            -- UNDER col_main_bg #323232. An input is a hole, a button a lump.
            frame_bg        = { 0.165, 0.165, 0.165, 1.0 },
            frame_hovered   = { 0.190, 0.190, 0.190, 1.0 },
            frame_active    = { 0.145, 0.145, 0.145, 1.0 },  -- deeper when live

            button          = { 0.275, 0.275, 0.275, 1.0 },
            button_hovered  = { 0.320, 0.320, 0.320, 1.0 },
            button_active   = { 0.212, 0.212, 0.212, 1.0 },  -- sunken, not lit

            header          = { 0.230, 0.230, 0.230, 1.0 },
            header_hovered  = { 0.255, 0.255, 0.255, 1.0 },
            header_active   = { 0.205, 0.205, 0.205, 1.0 },

            tab             = { 0.220, 0.220, 0.220, 1.0 },
            tab_hovered     = { 0.259, 0.259, 0.259, 1.0 },
            tab_active      = { 0.290, 0.290, 0.290, 1.0 },

            -- ---- edges ---------------------------------------------------
            -- Opaque. A half-alpha border over a dark ground is the thing
            -- that stopped drawing a line at all.
            border          = { 0.420, 0.420, 0.420, 1.0 },  -- n7
            border_soft     = { 0.345, 0.345, 0.345, 1.0 },  -- n6
            separator       = { 0.345, 0.345, 0.345, 1.0 },
            list_grid       = { 0.300, 0.300, 0.300, 1.0 },

            scrollbar_bg    = { 0.176, 0.176, 0.176, 1.0 },
            scrollbar_grab  = { 0.380, 0.380, 0.380, 1.0 },

            -- ---- lists ---------------------------------------------------
            -- list_bg == surface on purpose: a list sits flush inside its
            -- panel and is separated by its border, not by its fill. REAPER
            -- makes the same call (genlist_bg == col_main_bg == #323232).
            -- Repeating a value is fine when the two surfaces never touch, or
            -- touch across an edge. What is banned is what this file used to
            -- do: surface, list_bg, button_active, frame_active and
            -- header_active all resolving to ONE colour, so that a pressed
            -- control was indistinguishable from the panel carrying it.
            list_bg         = { 0.196, 0.196, 0.196, 1.0 },
            list_alt_bg     = { 0.220, 0.220, 0.220, 1.0 },
            list_hover      = { 0.259, 0.259, 0.259, 1.0 },
            -- Selection is a DARK tinted band with light text — the DAW
            -- convention (REAPER: genlist_selbg #466168 with white on top).
            -- A bright selection fights the content it is meant to point at.
            list_selected      = { 0.135, 0.341, 0.302, 1.0 },
            list_selected_text = { 1.000, 1.000, 1.000, 1.0 },
            list_text          = { 0.784, 0.784, 0.784, 1.0 },

            -- ---- text ----------------------------------------------------
            text            = { 0.784, 0.784, 0.784, 1.0 },  -- 7.66:1 on n2
            title_text      = { 0.627, 0.627, 0.627, 1.0 },
            value_normal    = { 0.784, 0.784, 0.784, 1.0 },
            text_mute       = { 0.482, 0.482, 0.482, 1.0 },  -- 3.03:1 on n2
            text_disabled   = { 0.380, 0.380, 0.380, 1.0 },

            -- ---- accent --------------------------------------------------
            -- #1abc98, lifted from col_toolbar_text_on: the colour the
            -- reference theme uses to say "this button is ON". 5.30:1 on the
            -- panel.
            --
            -- Text ON an accent fill must be BLACK: 7.76:1, against 2.13:1
            -- for white the moment the control is hovered — i.e. white is
            -- least readable exactly when you are interacting with it.
            accent          = { 0.102, 0.737, 0.596, 1.0 },
            accent_hovered  = { 0.184, 0.851, 0.698, 1.0 },
            accent_active   = { 0.200, 0.596, 0.529, 1.0 },  -- = col_cursor
            accent_dim      = { 0.135, 0.341, 0.302, 1.0 },
            on_accent       = { 0.070, 0.070, 0.070, 1.0 },  -- text on accent

            -- ---- semantic ------------------------------------------------
            danger          = { 0.929, 0.278, 0.290, 1.0 },
            bypass          = { 0.627, 0.494, 0.231, 1.0 },
            value_modified  = { 0.102, 0.737, 0.596, 1.0 },
            value_negative  = { 0.929, 0.278, 0.290, 1.0 },
            close_btn       = { 0.929, 0.278, 0.290, 1.0 },
            close_btn_hover = { 1.000, 0.400, 0.400, 1.0 },

            -- ---- ROLES ---------------------------------------------------
            -- What a lit control is DOING. Every one is lifted straight from
            -- the reference theme, so they already agree with the REAPER
            -- arrange sitting behind our windows: `pending` IS its play
            -- cursor, `mod` its envelope purple, `solo` its take marker.
            play            = { 0.200, 0.722, 0.188, 1.0 },  -- item_grouphl
            record          = { 0.929, 0.278, 0.290, 1.0 },  -- env_track_mute
            pending         = { 0.996, 0.757, 0.227, 1.0 },  -- playcursor_color
            solo            = { 1.000, 0.847, 0.188, 1.0 },  -- take_marker
            mute            = { 0.431, 0.478, 0.510, 1.0 },
            mod             = { 0.690, 0.541, 1.000, 1.0 },  -- col_env13

            -- ---- CANVAS: piano roll, waveform, clip grid ------------------
            -- The work surface is BRIGHTER than the chrome around it. That is
            -- the reference theme's arrangement (arrange #424242 over a
            -- #323232 window) and the opposite of what we shipped, where the
            -- roll sat in a hole.
            canvas_bg        = { 0.243, 0.243, 0.243, 1.0 },
            canvas_row       = { 0.298, 0.298, 0.298, 1.0 },  -- white key
            canvas_row_dark  = { 0.259, 0.259, 0.259, 1.0 },  -- black key
            canvas_row_off   = { 0.212, 0.212, 0.212, 1.0 },  -- out of scale
            -- 4.3 L* between the two rows. The previous pass put 9.5 there,
            -- more than twice the reference — over-corrected, so the roll
            -- read as striped rather than as ruled.

            -- The ruler and the key column are CHROME, so they sit BELOW the
            -- work surface, not above it (REAPER: midi_rulerbg and midi_leftbg
            -- are both #323232 under a #424242 roll).
            canvas_lane      = { 0.200, 0.200, 0.200, 1.0 },
            canvas_ruler     = { 0.200, 0.200, 0.200, 1.0 },

            -- Grid — and the one place alpha is right. A line laid in alpha
            -- keeps a constant RELATIVE weight whichever row it crosses; an
            -- opaque line tuned on the light row is too strong on the dark
            -- one. The old defect was never the alpha itself: it was that the
            -- alpha lived at the draw site instead of in the token, so no
            -- theme could reach it. Here colour AND alpha are both authored.
            --
            -- Only the BAR line goes toward the light. It is then the only
            -- bright thing in the roll and cannot be confused with anything
            -- else — the same trick the reference theme uses (one white line
            -- among black ones).
            --   bar +25.6 L*    beat -9.6    sub -5.6    fine -2.6
            canvas_line_bar  = { 0.502, 0.502, 0.502, 1.00 },
            canvas_line_beat = { 0.000, 0.000, 0.000, 0.32 },
            canvas_line_sub  = { 0.000, 0.000, 0.000, 0.19 },
            canvas_line_fine = { 0.000, 0.000, 0.000, 0.09 },

            canvas_item      = { 0.102, 0.737, 0.596, 1.0 },  -- a note / a clip
            canvas_item_sel  = { 0.920, 0.920, 0.920, 1.0 },
            canvas_playhead  = { 0.980, 0.980, 0.980, 1.0 },
        },

        -- Font settings (sizes are scaled)
        --
        -- A SCALE, not a list. h2 used to equal body (12 and 12), so Core
        -- loaded slots 3 and 4 with the identical font and the sub-heading
        -- level existed only as bold. Same for slots 7 and 9. Four names have
        -- to be four sizes or they are not a hierarchy.
        --
        -- And mono is never SMALLER than body: a value matters more than the
        -- label beside it, and the saved theme had mono 14 against body 16 —
        -- the numbers came out smaller than their own captions.
        fonts = {
            face      = "Tahoma",     -- main font face for everything
            title     = 18,           -- window title (bold)
            h1        = 16,           -- section header ("Sliders", "Buttons")
            h2        = 14,           -- sub-section header, collapsing headers
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
    return t
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

-- A saved theme is a DIFF against Theme.Default(), never a snapshot.
--
-- Snapshots are what broke CP_Config/DEFAULT.lua. It was written when the
-- canvas tokens and the role colours did not exist, so it froze 44 of the 63
-- keys and silently kept the defaults for the other 19 — chrome from one
-- palette, piano roll from another, and a roll darker than the window holding
-- it. Every theme ever saved carried the same latent fault, and every key
-- added to the identity made it worse.
--
-- A diff carries INTENT ("I changed the accent"), so everything the author did
-- not touch follows the identity as it evolves. It also turns a 63-line colour
-- block into the two or three lines someone actually meant.
local function colors_diff(t)
    local base = Theme.Default().colors
    local out = {}
    for key, c in pairs(t.colors) do
        local b = base[key]
        if not b then
            out[key] = { c[1], c[2], c[3], c[4] or 1 }   -- key we don't ship
        else
            local a1, a2 = c[4] or 1, b[4] or 1
            if c[1] ~= b[1] or c[2] ~= b[2] or c[3] ~= b[3] or a1 ~= a2 then
                out[key] = { c[1], c[2], c[3], a1 }
            end
        end
    end
    return out
end

function Theme.Save(t, name)
    ensure_config_dir()
    local path = get_theme_path(name)

    -- Build saveable data (exclude runtime/computed fields)
    local data = {
        colors = colors_diff(t),
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

    -- The identity is the base; the file is an override layer on top. A file
    -- saved before a key existed simply has nothing to say about it, and gets
    -- the current identity's value — which is the entire point of saving a
    -- diff, and what full snapshots could not do.
    --
    -- Old full-snapshot files still load correctly: they just override every
    -- key instead of a few. They shrink to a diff on their next save.
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

-- A light preset that only repaints the chrome leaves the canvas on the dark
-- identity, and the piano roll comes out as a black hole inside a white
-- window. That is precisely the fault that made CP_Config/DEFAULT.lua
-- unusable, so a preset that flips the polarity has to flip ALL of it.
--
-- The ramp is mirrored rather than inverted key by key: the work surface stays
-- brighter than the chrome around it, the ruler and key lane stay chrome, and
-- only the bar line reverses direction — on a light ground it must go DARK to
-- remain the one line that reads differently from every other.
local function light_canvas(t)
    local c = t.colors
    c.canvas_bg        = { 0.980, 0.980, 0.980, 1.0 }
    c.canvas_row       = { 0.940, 0.940, 0.940, 1.0 }
    c.canvas_row_dark  = { 0.890, 0.890, 0.890, 1.0 }
    c.canvas_row_off   = { 0.840, 0.840, 0.840, 1.0 }
    c.canvas_lane      = { 0.870, 0.870, 0.880, 1.0 }
    c.canvas_ruler     = { 0.870, 0.870, 0.880, 1.0 }
    c.canvas_line_bar  = { 0.380, 0.380, 0.400, 1.00 }
    c.canvas_line_beat = { 1.000, 1.000, 1.000, 0.70 }
    c.canvas_line_sub  = { 0.000, 0.000, 0.000, 0.13 }
    c.canvas_line_fine = { 0.000, 0.000, 0.000, 0.06 }
    c.canvas_item_sel  = { 0.120, 0.120, 0.130, 1.0 }
    c.canvas_playhead  = { 0.100, 0.100, 0.110, 1.0 }
    c.on_accent        = { 0.070, 0.070, 0.070, 1.0 }
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
        light_canvas(t)
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
        light_canvas(t)
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
-- Every key in Theme.Default().colors MUST appear in exactly one group. A key
-- outside this table has no editor at all — and fourteen of them used to be
-- outside it, including `surface` and `surface2` (the panel fills) and
-- `text_mute`, the fifth most-read colour in the repo. They were visible on
-- every screen and reachable from nowhere.
local COLOR_GROUPS = {
    { name = "Base",     keys = { "window_bg", "surface", "surface2", "title_bar",
                                  "border", "border_soft", "separator" } },
    { name = "Text",     keys = { "text", "title_text", "text_mute", "text_disabled",
                                  "value_normal", "value_modified", "value_negative" } },
    { name = "Accent",   keys = { "accent", "accent_hovered", "accent_active",
                                  "accent_dim", "on_accent" } },
    { name = "Buttons",  keys = { "button", "button_hovered", "button_active" } },
    { name = "Frames",   keys = { "frame_bg", "frame_hovered", "frame_active" } },
    { name = "Headers",  keys = { "header", "header_hovered", "header_active" } },
    { name = "Lists",    keys = { "list_bg", "list_alt_bg", "list_text", "list_grid",
                                  "list_selected", "list_selected_text", "list_hover" } },
    { name = "Tabs",     keys = { "tab", "tab_hovered", "tab_active" } },
    { name = "Popups",   keys = { "popup_bg", "scrollbar_bg", "scrollbar_grab" } },
    { name = "Semantic", keys = { "danger", "bypass", "close_btn", "close_btn_hover" } },
    { name = "Canvas",   keys = { "canvas_bg", "canvas_row", "canvas_row_dark",
                                  "canvas_row_off", "canvas_lane", "canvas_ruler",
                                  "canvas_line_bar", "canvas_line_beat",
                                  "canvas_line_sub", "canvas_line_fine",
                                  "canvas_item", "canvas_item_sel", "canvas_playhead" } },
    { name = "Roles",    keys = { "play", "record", "pending", "mute", "solo", "mod" } },
}

local COLOR_LABELS = {
    window_bg = "Window BG", text = "Text", text_disabled = "Text Dim",
    border = "Border", separator = "Separator",
    accent = "Accent", accent_hovered = "Accent Hover", accent_active = "Accent Active",
    accent_dim = "Accent Dim", on_accent = "Text on accent",
    surface = "Panel", surface2 = "Panel raised", border_soft = "Border soft",
    title_bar = "Title bar", title_text = "Title text", text_mute = "Text muted",
    value_normal = "Value", value_modified = "Value changed", value_negative = "Value negative",
    danger = "Danger", bypass = "Bypassed",
    close_btn = "Close", close_btn_hover = "Close hover",
    button = "Button", button_hovered = "Button Hover", button_active = "Button Active",
    frame_bg = "Frame BG", frame_hovered = "Frame Hover", frame_active = "Frame Active",
    header = "Header", header_hovered = "Header Hover", header_active = "Header Active",
    list_bg = "List BG", list_alt_bg = "List Alt Row", list_text = "List Text",
    list_grid = "List Grid", list_selected = "List Selected", list_selected_text = "List Sel Text",
    list_hover = "List Hover",
    tab = "Tab", tab_hovered = "Tab Hover", tab_active = "Tab Active",
    popup_bg = "Popup BG", scrollbar_bg = "Scroll BG", scrollbar_grab = "Scroll Grab",
    canvas_bg = "Roll BG", canvas_row = "Row", canvas_row_dark = "Row (black key)",
    canvas_row_off = "Row (off scale)", canvas_lane = "Key lane", canvas_ruler = "Ruler",
    canvas_line_bar = "Bar line", canvas_line_beat = "Beat line",
    canvas_line_sub = "Subdivision", canvas_line_fine = "Fine line",
    canvas_item = "Note / clip", canvas_item_sel = "Note selected",
    canvas_playhead = "Playhead",
    play = "Playing", record = "Recording", pending = "Queued",
    mute = "Muted", solo = "Solo", mod = "Modulation",
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

-- ============================================================================
-- REVERSE LOOKUP — "what is this pixel?"
-- ============================================================================
-- The complaint that started all of this was "I don't even know which colour
-- the column uses, and it isn't in the theme". A token nobody can locate is a
-- token nobody can tune, and no amount of renaming fixes that on its own: you
-- have to be able to point at a pixel and get an answer.
--
-- So the match table is built the way the screen is: every token appears at
-- its own value AND, when it is drawn with alpha, at the values it actually
-- composites to over the grounds it is laid on. Without that second part the
-- grid lines could never be identified — a beat line is black at 32 %, and
-- black at 32 % is not a colour anyone ever sees.
local COMPOSITE_OVER = { "canvas_row", "canvas_row_dark", "canvas_bg", "surface", "window_bg" }

function Theme.BuildMatchTable(t)
    local mt = {}
    local c = t.colors
    for key, col in pairs(c) do
        local a = col[4] or 1
        if a >= 0.999 then
            mt[#mt + 1] = { key = key, r = col[1], g = col[2], b = col[3] }
        else
            -- The token's own value stays in, for the case where it is blitted
            -- opaque somewhere, but the composites are what will actually hit.
            mt[#mt + 1] = { key = key, r = col[1], g = col[2], b = col[3], alpha = a }
            for i = 1, #COMPOSITE_OVER do
                local ground = c[COMPOSITE_OVER[i]]
                if ground then
                    mt[#mt + 1] = {
                        key = key, over = COMPOSITE_OVER[i], alpha = a,
                        r = col[1] * a + ground[1] * (1 - a),
                        g = col[2] * a + ground[2] * (1 - a),
                        b = col[3] * a + ground[3] * (1 - a),
                    }
                end
            end
        end
    end
    return mt
end

-- Nearest entries to an (r, g, b), best first. Writes into `out` — this runs
-- every frame while the inspector is live, and a fresh table per frame in a
-- polling loop is exactly the kind of garbage this codebase does not make.
-- Distance is weighted for the eye (green counts most), which keeps a grey
-- from claiming a faint tint and vice versa.
function Theme.MatchColor(mt, r, g, b, out, want)
    want = want or 3
    -- `out` carries its own slot tables, filled in place: this runs every
    -- frame while the inspector is live.
    for i = 1, want do
        if not out[i] then out[i] = { key = nil, over = nil, alpha = nil, d = 0 } end
        out[i].key = nil
        out[i].d = math.huge
    end
    local n = 0
    for i = 1, #mt do
        local e = mt[i]
        local dr, dg, db = e.r - r, e.g - g, e.b - b
        local d = dr * dr * 0.30 + dg * dg * 0.59 + db * db * 0.11
        -- Insertion into the top-N. N is 3, so this beats any sort and, more
        -- to the point, allocates nothing.
        if d < out[want].d then
            local pos = want
            while pos > 1 and d < out[pos - 1].d do pos = pos - 1 end
            local last = out[want]
            for j = want, pos + 1, -1 do out[j] = out[j - 1] end
            out[pos] = last
            last.key, last.over, last.alpha, last.d = e.key, e.over, e.alpha, d
            if n < want then n = n + 1 end
        end
    end
    return n
end

return Theme
