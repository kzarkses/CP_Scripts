-- @description CP ColorPicker — Colors (pure module)
-- @version 1.0
-- @author Cedric Pamalio

-- PURE module (no reaper.* / gfx.*): hex<->rgb, hsv<->rgb, spectrum ramp,
-- config defaults + merge. Testable with plain lua53.exe. DI-free (no deps).
-- Per the house PURE-module rule (ARCHITECTURE), logic lives here so both the
-- main popup and the Settings editor share one source of truth for colors.

local Colors = {}

local floor, abs = math.floor, math.abs

local function clamp01(x)
    if x < 0 then return 0 elseif x > 1 then return 1 else return x end
end
Colors.clamp01 = clamp01

-- 0-1 float channel -> 0-255 integer (rounded). Integers only, so downstream
-- %d / %02X are Lua-5.3-safe (a float would error "no integer representation").
function Colors.rgb_to_255(r, g, b)
    return floor(clamp01(r) * 255 + 0.5),
           floor(clamp01(g) * 255 + 0.5),
           floor(clamp01(b) * 255 + 0.5)
end

-- "#RRGGBB" or "RRGGBB" -> r, g, b (0-1 floats). Invalid parts fall back to 0.
function Colors.hex_to_rgb(hex)
    if type(hex) ~= "string" then return 0, 0, 0 end
    hex = hex:gsub("#", "")
    local R = tonumber(hex:sub(1, 2), 16) or 0
    local G = tonumber(hex:sub(3, 4), 16) or 0
    local B = tonumber(hex:sub(5, 6), 16) or 0
    return R / 255, G / 255, B / 255
end

-- r, g, b (0-1) -> "#RRGGBB" (uppercase).
function Colors.rgb_to_hex(r, g, b)
    local R, G, B = Colors.rgb_to_255(r, g, b)
    return string.format("#%02X%02X%02X", R, G, B)
end

-- h (0-360), s (0-1), v (0-1) -> r, g, b (0-1).
function Colors.hsv_to_rgb(h, s, v)
    h = h % 360
    if h < 0 then h = h + 360 end
    local c = v * s
    local x = c * (1 - abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if     h < 60  then r, g, b = c, x, 0
    elseif h < 120 then r, g, b = x, c, 0
    elseif h < 180 then r, g, b = 0, c, x
    elseif h < 240 then r, g, b = 0, x, c
    elseif h < 300 then r, g, b = x, 0, c
    else                r, g, b = c, 0, x end
    return r + m, g + m, b + m
end

-- r, g, b (0-1) -> h (0-360), s (0-1), v (0-1).
function Colors.rgb_to_hsv(r, g, b)
    local mx = math.max(r, g, b)
    local mn = math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h * 60
        if h < 0 then h = h + 360 end
    end
    local s = mx == 0 and 0 or d / mx
    return h, s, mx
end

-- Fill `buf` (reused array of {r,g,b} tables) with a hue-spectrum GRID:
-- `cols` hues across the columns (0..360), `rows` brightness levels down the
-- rows (val_top at the top row -> val_bottom at the bottom), at a constant
-- saturation. Row-major (idx = row*cols + col + 1). In-place so a live
-- saturation slider costs zero per-frame allocation once warm. Returns buf.
function Colors.fill_spectrum_grid(buf, cols, rows, sat, val_top, val_bottom)
    cols = math.max(1, floor(cols))
    rows = math.max(1, floor(rows))
    local n = 0
    for row = 0, rows - 1 do
        local v = (rows <= 1) and val_top
                  or (val_top + (val_bottom - val_top) * row / (rows - 1))
        for col = 0, cols - 1 do
            n = n + 1
            local cell = buf[n]
            if not cell then cell = {}; buf[n] = cell end
            cell[1], cell[2], cell[3] = Colors.hsv_to_rgb(col / cols * 360, sat, v)
        end
    end
    for i = #buf, n + 1, -1 do buf[i] = nil end
    return buf
end

-- ============================================================================
-- CONFIG DEFAULTS
-- ============================================================================
-- A curated 8x3 default palette spanning the hue wheel at three lightness
-- bands (muted / mid / bright). The user re-curates it in the Settings editor.
Colors.DEFAULTS = {
    -- The spectrum grid IS the default UI: 2 rows x 10 hues, clean, nothing else.
    show_spectrum       = true,
    spectrum_cols       = 10,   -- hues across
    spectrum_rows       = 2,    -- brightness levels down
    spectrum_sat        = 0.70, -- saturation (constant unless the slider is on)
    spectrum_val_top    = 0.95, -- top row brightness (vivid)
    spectrum_val_bottom = 0.55, -- bottom row brightness (muted/dark)

    -- Optional extras, all OFF by default (enable per taste in Settings).
    show_saturation_slider = false, -- live saturation slider under the spectrum
    show_palette           = false, -- fixed palette grid
    show_favorites         = false, -- favorites row
    show_clear             = false, -- "no color" chip
    show_target_label      = false, -- one-line caption naming the target

    -- Palette / favorites data (only shown when their toggle is on).
    palette = {
        "#7A7A7A", "#9E4B4B", "#A6683C", "#9E8E3C", "#4E8E4E", "#3C8E8E", "#3C5E9E", "#6E4B9E",
        "#B0B0B0", "#C24B4B", "#D07A2E", "#C9B23A", "#4FB04F", "#3FB0B0", "#3F6EC9", "#8A4BC2",
        "#DADADA", "#E88A8A", "#F0B36B", "#EDD87A", "#8FD98F", "#7ED9D9", "#7E9DE8", "#B78AE8",
    },
    favorites = {},

    columns     = 8,   -- palette grid width (only when show_palette)
    swatch_size = 20,  -- px per swatch (spectrum + palette + favorites)
    gap         = 4,   -- px between swatches
    pad         = 8,   -- inner window margin

    anchor_side = "right", -- "right" | "left" of the TCP/arrange divider
    offset_x    = 0,       -- calibration nudge (px)
    offset_y    = 0,
}

-- Returns a config table with every default key present. Arrays (palette,
-- favorites) are kept as-is when supplied, else deep-copied from defaults so
-- callers never mutate Colors.DEFAULTS.
function Colors.merge_defaults(cfg)
    cfg = cfg or {}
    local d = Colors.DEFAULTS
    for k, v in pairs(d) do
        if cfg[k] == nil then
            if type(v) == "table" then
                local t = {}
                for i = 1, #v do t[i] = v[i] end
                cfg[k] = t
            else
                cfg[k] = v
            end
        end
    end
    if type(cfg.palette) ~= "table" then cfg.palette = {} end
    if type(cfg.favorites) ~= "table" then cfg.favorites = {} end
    return cfg
end

return Colors
