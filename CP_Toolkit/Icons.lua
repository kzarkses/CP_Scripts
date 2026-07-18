-- CP_Toolkit Icons — vector icons drawn with native gfx primitives
-- All icons: (x, y, size, r, g, b, a) — centered in a size x size box
--
-- Rendering pipeline (quality pass 2026-07): every glyph is drawn once at
-- 4x supersample into a scratch buffer, then downscaled twice (filtered
-- blits = 16-tap box filter) into its bake slot. Primitives therefore need
-- NO per-primitive antialiasing — thick strokes are filled quads/arcs whose
-- staircase edges vanish in the downscale. Per-frame cost is unchanged:
-- one gfx.blit of the baked slot.
--
-- PNG overrides: drop white-on-transparent PNGs (64-128 px, square) named
-- after the icon function (Play.png, StarFilled.png, …) into
-- CP_Toolkit/IconOverrides/ — they replace the procedural glyph and are
-- tinted to the requested color at bake time. Icons.ReloadOverrides()
-- rescans the folder and rebakes.

local Icons = {}

-- ============================================================================
-- HELPERS
-- ============================================================================
local floor = math.floor
local sqrt  = math.sqrt
local cos, sin = math.cos, math.sin
local pi = math.pi

local function set_color(r, g, b, a)
    gfx.set(r, g, b, a or 1)
end

-- Dedicated font slot for the two glyph-based icons (Solo "S", FX "fx").
-- Audit B5a: these used to redefine slot 1 — the theme's Title font — on
-- every call and never restore it, corrupting titles AND poisoning Core's
-- measure cache (whose slot tracking no longer matched the real gfx font).
local ICON_FONT_SLOT = 15
local _icon_font_size = -1
local _restore_font = nil

-- Wired by CP_Toolkit at init: called after a glyph icon draws, so the gfx
-- font matches what Core believes is current again.
function Icons.SetFontRestorer(fn)
    _restore_font = fn
end

local function icon_font(px)
    if px ~= _icon_font_size then
        gfx.setfont(ICON_FONT_SLOT, "Arial", px, 66)  -- bold
        _icon_font_size = px
    else
        gfx.setfont(ICON_FONT_SLOT)
    end
end

local function icon_font_done()
    if _restore_font then _restore_font() end
end

local function center(x, y, size)
    return x + size / 2, y + size / 2
end

-- Size-relative measure. No floor: glyphs draw at 4x supersample where
-- sub-pixel coordinates are exactly what we want.
local function scale(size, factor)
    return size * factor
end

-- ----------------------------------------------------------------------------
-- Stroke kit. Hairline gfx.line/gfx.arc calls don't survive the supersample
-- (a 1px line becomes 0.25px after the 4x downscale) — strokes must scale
-- with the cell instead.
-- ----------------------------------------------------------------------------
-- Optical stroke width: ~1.5px at a 16px cell, linear with size.
local function stroke_w(size)
    local w = size * 0.09
    if w < 1 then w = 1 end
    return w
end

-- Thick line: filled quad (gfx.triangle accepts convex polygons) with round
-- caps. Degenerate length falls back to a dot.
local function sline(x1, y1, x2, y2, w)
    local dx, dy = x2 - x1, y2 - y1
    local len = sqrt(dx * dx + dy * dy)
    local hw = w * 0.5
    if len < 0.001 then
        gfx.circle(x1, y1, hw, 1, 1)
        return
    end
    local nx, ny = -dy / len * hw, dx / len * hw
    gfx.triangle(x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny)
    gfx.circle(x1, y1, hw, 1, 1)
    gfx.circle(x2, y2, hw, 1, 1)
end

-- Thick arc: concentric 1px arcs stepping 0.5px (bake-time only cost).
-- Angle convention matches the historical glyph code (arc endpoint sits at
-- cx + cos(ang)*rad, cy + sin(ang)*rad for arrowhead placement).
local function sarc(cx, cy, rad, a1, a2, w)
    local rr = rad - w * 0.5
    local r1 = rad + w * 0.5
    while rr <= r1 do
        gfx.arc(cx, cy, rr, a1, a2, 1)
        rr = rr + 0.5
    end
end

-- Ring: circle outline with thickness.
local function sring(cx, cy, rad, w)
    local rr = rad - w * 0.5
    local r1 = rad + w * 0.5
    while rr <= r1 do
        gfx.circle(cx, cy, rr, 0, 1)
        rr = rr + 0.5
    end
end

-- Rectangle outline with thickness (round caps double as rounded corners).
local function srect(x, y, w, h, sw)
    sline(x, y, x + w, y, sw)
    sline(x + w, y, x + w, y + h, sw)
    sline(x + w, y + h, x, y + h, sw)
    sline(x, y + h, x, y, sw)
end

-- ============================================================================
-- ARROWS / CHEVRONS
-- ============================================================================
function Icons.ChevronDown(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.24)
    local w = stroke_w(size)
    sline(cx - s, cy - s * 0.5, cx, cy + s * 0.5, w)
    sline(cx, cy + s * 0.5, cx + s, cy - s * 0.5, w)
end

function Icons.ChevronUp(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.24)
    local w = stroke_w(size)
    sline(cx - s, cy + s * 0.5, cx, cy - s * 0.5, w)
    sline(cx, cy - s * 0.5, cx + s, cy + s * 0.5, w)
end

function Icons.ChevronRight(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.24)
    local w = stroke_w(size)
    sline(cx - s * 0.5, cy - s, cx + s * 0.5, cy, w)
    sline(cx + s * 0.5, cy, cx - s * 0.5, cy + s, w)
end

function Icons.ChevronLeft(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.24)
    local w = stroke_w(size)
    sline(cx + s * 0.5, cy - s, cx - s * 0.5, cy, w)
    sline(cx - s * 0.5, cy, cx + s * 0.5, cy + s, w)
end

-- Filled triangles (dropdowns, tree nodes) — filled shapes need no stroke
-- conversion; the supersample downscale antialiases their edges.
function Icons.TriangleDown(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.triangle(cx - s, cy - s * 0.5, cx + s, cy - s * 0.5, cx, cy + s * 0.6)
end

function Icons.TriangleRight(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.triangle(cx - s * 0.5, cy - s, cx - s * 0.5, cy + s, cx + s * 0.6, cy)
end

function Icons.TriangleLeft(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.triangle(cx + s * 0.5, cy - s, cx + s * 0.5, cy + s, cx - s * 0.6, cy)
end

function Icons.TriangleUp(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.triangle(cx - s, cy + s * 0.5, cx + s, cy + s * 0.5, cx, cy - s * 0.6)
end

-- ============================================================================
-- COMMON UI ICONS
-- ============================================================================
function Icons.Close(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local m = scale(size, 0.30)
    local w = stroke_w(size)
    sline(x + m, y + m, x + size - m, y + size - m, w)
    sline(x + size - m, y + m, x + m, y + size - m, w)
end

function Icons.Check(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.26)
    local w = stroke_w(size)
    sline(cx - s, cy, cx - s * 0.2, cy + s * 0.7, w)
    sline(cx - s * 0.2, cy + s * 0.7, cx + s, cy - s * 0.5, w)
end

function Icons.Plus(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.27)
    local w = stroke_w(size)
    sline(cx, cy - s, cx, cy + s, w)
    sline(cx - s, cy, cx + s, cy, w)
end

function Icons.Minus(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.27)
    sline(cx - s, cy, cx + s, cy, stroke_w(size))
end

-- ============================================================================
-- TRANSPORT
-- ============================================================================
function Icons.Play(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.28)
    gfx.triangle(cx - s * 0.6, cy - s, cx - s * 0.6, cy + s, cx + s, cy)
end

function Icons.Pause(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.26)
    local bar_w = scale(size, 0.14)
    local gap = scale(size, 0.09)
    gfx.rect(cx - gap - bar_w, cy - s, bar_w, s * 2, 1)
    gfx.rect(cx + gap, cy - s, bar_w, s * 2, 1)
end

function Icons.Stop(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.24)
    gfx.rect(cx - s, cy - s, s * 2, s * 2, 1)
end

function Icons.Record(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    gfx.circle(cx, cy, scale(size, 0.26), 1, 1)
end

function Icons.SkipForward(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.triangle(cx - s, cy - s, cx - s, cy + s, cx + s * 0.3, cy)
    gfx.rect(cx + s * 0.5, cy - s, scale(size, 0.10), s * 2, 1)
end

function Icons.SkipBackward(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.triangle(cx + s, cy - s, cx + s, cy + s, cx - s * 0.3, cy)
    gfx.rect(cx - s * 0.5 - scale(size, 0.10), cy - s, scale(size, 0.10), s * 2, 1)
end

function Icons.Loop(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.28)
    local w = stroke_w(size)
    -- Full ring (two half arcs like the original) + two arrowheads on the sides
    sarc(cx, cy, s, 0, pi, w)
    sarc(cx, cy, s, pi, pi * 2, w)
    local aw = scale(size, 0.14)
    gfx.triangle(cx + s - aw, cy - aw * 1.6, cx + s + aw, cy - aw * 1.6, cx + s, cy + aw * 0.4)
    gfx.triangle(cx - s - aw, cy + aw * 1.6, cx - s + aw, cy + aw * 1.6, cx - s, cy - aw * 0.4)
end

-- ============================================================================
-- ACTIONS / EDITING
-- ============================================================================
function Icons.Settings(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local rad = scale(size, 0.24)   -- ring center-line radius
    local ring_w = scale(size, 0.13)
    sring(cx, cy, rad, ring_w)
    -- 8 teeth: thick radial stubs through the ring's outer edge
    local tooth_w = scale(size, 0.12)
    local outer = scale(size, 0.38)
    for i = 0, 7 do
        local ang = i * pi / 4 + pi / 8
        local ca, sa = cos(ang), sin(ang)
        sline(cx + ca * rad, cy + sa * rad, cx + ca * outer, cy + sa * outer, tooth_w)
    end
end

function Icons.Search(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local s = scale(size, 0.22)
    local cx = x + size * 0.42
    local cy = y + size * 0.42
    local w = stroke_w(size)
    sring(cx, cy, s, w)
    sline(cx + s * 0.72, cy + s * 0.72, x + size * 0.80, y + size * 0.80, w * 1.3)
end

function Icons.Refresh(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.28)
    sarc(cx, cy, s, -pi * 0.5, pi, stroke_w(size))
    local ax = cx + cos(-pi * 0.5) * s
    local ay = cy + sin(-pi * 0.5) * s
    local aw = scale(size, 0.13)
    gfx.triangle(ax, ay, ax + aw, ay + aw, ax - aw, ay + aw)
end

function Icons.Undo(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    sarc(cx + s * 0.3, cy, s, pi * 0.5, pi * 1.5, stroke_w(size))
    local aw = scale(size, 0.13)
    gfx.triangle(cx + s * 0.3 - s, cy - aw, cx + s * 0.3 - s, cy + aw, cx + s * 0.3 - s - aw, cy)
end

function Icons.Redo(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    sarc(cx - s * 0.3, cy, s, -pi * 0.5, pi * 0.5, stroke_w(size))
    local aw = scale(size, 0.13)
    gfx.triangle(cx - s * 0.3 + s, cy - aw, cx - s * 0.3 + s, cy + aw, cx - s * 0.3 + s + aw, cy)
end

function Icons.Delete(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    local w = stroke_w(size)
    -- Body
    srect(cx - s, cy - s * 0.3, s * 2, s * 1.5, w)
    -- Lid + handle
    sline(cx - s * 1.3, cy - s * 0.3, cx + s * 1.3, cy - s * 0.3, w)
    sline(cx - s * 0.5, cy - s * 0.3, cx - s * 0.5, cy - s * 0.7, w)
    sline(cx - s * 0.5, cy - s * 0.7, cx + s * 0.5, cy - s * 0.7, w)
    sline(cx + s * 0.5, cy - s * 0.7, cx + s * 0.5, cy - s * 0.3, w)
end

function Icons.Copy(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local s = scale(size, 0.2)
    local ox = x + size * 0.3
    local oy = y + size * 0.25
    local w = stroke_w(size)
    srect(ox + s * 0.4, oy, s * 1.5, s * 2, w)
    gfx.rect(ox, oy + s * 0.4, s * 1.5, s * 2, 1)
end

function Icons.Save(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.27)
    srect(cx - s, cy - s, s * 2, s * 2, stroke_w(size))
    gfx.rect(cx - s * 0.6, cy - s, s * 1.2, s * 0.8, 1)
    gfx.rect(cx - s * 0.5, cy + s * 0.2, s, s * 0.7, 1)
end

-- ============================================================================
-- STATE / STATUS
-- ============================================================================
function Icons.Lock(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.rect(cx - s, cy, s * 2, s * 1.4, 1)
    sarc(cx, cy, s * 0.65, pi, pi * 2, stroke_w(size))
end

function Icons.Unlock(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.rect(cx - s, cy, s * 2, s * 1.4, 1)
    sarc(cx, cy, s * 0.65, pi, pi * 1.7, stroke_w(size))
end

function Icons.Eye(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.32)
    local w = stroke_w(size)
    sarc(cx, cy - s * 0.15, s, 0.3, pi - 0.3, w)
    sarc(cx, cy + s * 0.15, s, pi + 0.3, pi * 2 - 0.3, w)
    gfx.circle(cx, cy, scale(size, 0.10), 1, 1)
end

function Icons.EyeOff(x, y, size, r, g, b, a)
    Icons.Eye(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local m = scale(size, 0.2)
    sline(x + m, y + size - m, x + size - m, y + m, stroke_w(size))
end

function Icons.Mute(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.16)
    gfx.rect(cx - s * 1.6, cy - s * 0.7, s, s * 1.4, 1)
    gfx.triangle(cx - s * 0.6, cy - s * 0.7, cx - s * 0.6, cy + s * 0.7, cx + s, cy - s * 1.3)
    gfx.triangle(cx - s * 0.6, cy + s * 0.7, cx + s, cy + s * 1.3, cx + s, cy - s * 1.3)
end

function Icons.Volume(x, y, size, r, g, b, a)
    Icons.Mute(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.16)
    local w = stroke_w(size) * 0.9
    sarc(cx + s * 1.3, cy, s * 0.8, -0.6, 0.6, w)
    sarc(cx + s * 1.3, cy, s * 1.4, -0.5, 0.5, w)
end

function Icons.Solo(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    icon_font(floor(size * 0.5))
    local tw, th = gfx.measurestr("S")
    gfx.x = cx - tw / 2
    gfx.y = cy - th / 2
    gfx.drawstr("S")
    icon_font_done()
end

-- ============================================================================
-- AUDIO / MUSIC
-- ============================================================================
function Icons.Waveform(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cy = y + size / 2
    local bars = 7
    local bar_w = size / (bars * 2)
    local gap = (size - bars * bar_w) / (bars + 1)
    local heights = { 0.3, 0.6, 0.9, 1.0, 0.7, 0.5, 0.2 }
    for i = 1, bars do
        local bx = x + gap + (i - 1) * (bar_w + gap)
        local bh = size * 0.35 * heights[i]
        gfx.rect(bx, cy - bh, bar_w, bh * 2, 1)
    end
end

function Icons.MIDI(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.30)
    sring(cx, cy, s, stroke_w(size))
    local pin_r = scale(size, 0.05)
    for i = 0, 4 do
        local angle = pi * 0.3 + (i / 4) * pi * 1.4
        gfx.circle(cx + cos(angle) * s * 0.55, cy + sin(angle) * s * 0.55, pin_r, 1, 1)
    end
end

function Icons.Folder(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    -- Filled silhouette (reads better at row sizes than an outline)
    local fx = x + size * 0.16
    local fy = y + size * 0.24
    local fw = size * 0.68
    local fh = size * 0.46
    -- Tab
    gfx.rect(fx, fy, fw * 0.42, size * 0.12, 1)
    -- Body
    gfx.rect(fx, fy + size * 0.10, fw, fh, 1)
end

function Icons.File(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local w = stroke_w(size)
    local fx = x + size * 0.28
    local fy = y + size * 0.18
    local fw = size * 0.42
    local fh = size * 0.62
    local fold = size * 0.16
    -- Outline with a folded corner (top-right)
    sline(fx, fy, fx + fw - fold, fy, w)
    sline(fx + fw - fold, fy, fx + fw, fy + fold, w)
    sline(fx + fw, fy + fold, fx + fw, fy + fh, w)
    sline(fx + fw, fy + fh, fx, fy + fh, w)
    sline(fx, fy + fh, fx, fy, w)
    sline(fx + fw - fold, fy, fx + fw - fold, fy + fold, w)
    sline(fx + fw - fold, fy + fold, fx + fw, fy + fold, w)
end

function Icons.FX(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    icon_font(floor(size * 0.4))
    local tw, th = gfx.measurestr("fx")
    gfx.x = cx - tw / 2
    gfx.y = cy - th / 2
    gfx.drawstr("fx")
    icon_font_done()
end

function Icons.Crosshair(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.32)
    local gap = scale(size, 0.09)
    local w = stroke_w(size)
    sline(cx - s, cy, cx - gap, cy, w)
    sline(cx + gap, cy, cx + s, cy, w)
    sline(cx, cy - s, cx, cy - gap, w)
    sline(cx, cy + gap, cx, cy + s, w)
    gfx.circle(cx, cy, scale(size, 0.05), 1, 1)
end

function Icons.Pipette(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    sline(cx - s, cy + s, cx + s * 0.3, cy - s * 0.3, stroke_w(size))
    gfx.circle(cx + s * 0.5, cy - s * 0.5, scale(size, 0.11), 1, 1)
    gfx.circle(cx - s * 0.8, cy + s * 0.8, scale(size, 0.06), 1, 1)
end

-- ============================================================================
-- EXTENDED ICONS (added 2026-05-10 for FX Browser refonte V2)
-- ============================================================================

-- 5-point star outline (favorite indicator, off state)
function Icons.Star(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local outer = scale(size, 0.36)
    local inner = scale(size, 0.16)
    local w = stroke_w(size) * 0.85
    local pts = {}
    for i = 0, 9 do
        local rad = (i % 2 == 0) and outer or inner
        local ang = -pi / 2 + (i * pi / 5)
        pts[#pts + 1] = cx + cos(ang) * rad
        pts[#pts + 1] = cy + sin(ang) * rad
    end
    for i = 1, 19, 2 do
        local nx = (i + 2 > 20) and pts[1] or pts[i + 2]
        local ny = (i + 2 > 20) and pts[2] or pts[i + 3]
        sline(pts[i], pts[i + 1], nx, ny, w)
    end
end

-- Filled star (favorite indicator, on state)
function Icons.StarFilled(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local outer = scale(size, 0.36)
    local inner = scale(size, 0.16)
    local pts = {}
    for i = 0, 9 do
        local rad = (i % 2 == 0) and outer or inner
        local ang = -pi / 2 + (i * pi / 5)
        pts[#pts + 1] = cx + cos(ang) * rad
        pts[#pts + 1] = cy + sin(ang) * rad
    end
    -- Fan-fill from center: each pair (i, i+1) → triangle (center, p_i, p_{i+1})
    for i = 1, 19, 2 do
        local x1, y1 = pts[i], pts[i + 1]
        local x2, y2 = (i + 2 > 20) and pts[1] or pts[i + 2],
                       (i + 2 > 20) and pts[2] or pts[i + 3]
        gfx.triangle(cx, cy, x1, y1, x2, y2)
    end
end

-- Analog clock (recents indicator)
function Icons.Clock(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local rad = scale(size, 0.34)
    local w = stroke_w(size)
    sring(cx, cy, rad, w)
    sline(cx, cy, cx, cy - scale(size, 0.20), w * 0.9)
    sline(cx, cy, cx + scale(size, 0.17), cy, w * 0.9)
end

-- Scan: magnifier with horizontal scan line crossing the lens
function Icons.Scan(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local rad = scale(size, 0.22)
    local w = stroke_w(size)
    local lx = cx - scale(size, 0.05)
    local ly = cy - scale(size, 0.05)
    sring(lx, ly, rad, w)
    sline(lx - rad, ly, lx + rad, ly, w * 0.8)
    sline(cx + scale(size, 0.13), cy + scale(size, 0.13),
          cx + scale(size, 0.30), cy + scale(size, 0.30), w * 1.3)
end

-- Sort A→Z arrows (down arrow with decreasing bars)
function Icons.Sort(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    local w = stroke_w(size)
    sline(cx - s * 1.2, cy - s, cx - s * 1.2, cy + s, w)
    sline(cx - s * 1.2 - s * 0.4, cy + s * 0.4, cx - s * 1.2, cy + s, w)
    sline(cx - s * 1.2, cy + s, cx - s * 1.2 + s * 0.4, cy + s * 0.4, w)
    sline(cx, cy - s, cx + s * 1.2, cy - s, w)
    sline(cx, cy, cx + s * 0.8, cy, w)
    sline(cx, cy + s, cx + s * 0.4, cy + s, w)
end

-- Dice (random — 6-face with 5-pip pattern)
function Icons.Dice(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local half = scale(size, 0.32)
    srect(cx - half, cy - half, half * 2, half * 2, stroke_w(size))
    local pip = scale(size, 0.07)
    local off = scale(size, 0.17)
    gfx.circle(cx, cy, pip, 1, 1)
    gfx.circle(cx - off, cy - off, pip, 1, 1)
    gfx.circle(cx + off, cy - off, pip, 1, 1)
    gfx.circle(cx - off, cy + off, pip, 1, 1)
    gfx.circle(cx + off, cy + off, pip, 1, 1)
end

-- Erase (eraser block — for "Clear chain")
function Icons.Erase(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local w = scale(size, 0.30)
    local h = scale(size, 0.18)
    local sw = stroke_w(size)
    srect(cx - w, cy - h, w * 2, h * 2, sw)
    sline(cx, cy - h, cx, cy + h, sw)
    local ml = scale(size, 0.09)
    sline(cx + w + 2, cy - h * 0.5, cx + w + 2 + ml, cy - h * 0.5, sw * 0.8)
    sline(cx + w + 2, cy + h * 0.5, cx + w + 2 + ml, cy + h * 0.5, sw * 0.8)
end

-- Grip (drag handle: 6 dots in 2 columns, like ⋮⋮)
function Icons.Grip(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local dot = scale(size, 0.06)
    local sx = scale(size, 0.10)
    local sy = scale(size, 0.18)
    for col = -1, 1, 2 do
        for row = -1, 1 do
            gfx.circle(cx + col * sx, cy + row * sy, dot, 1, 1)
        end
    end
end

-- Layers (stacked rhombi — for tabs / collections)
function Icons.Layers(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local hw = scale(size, 0.30)
    local hh = scale(size, 0.11)
    local off = scale(size, 0.11)
    local w = stroke_w(size) * 0.85
    for i = -1, 1 do
        local oy = cy + i * off
        sline(cx - hw, oy, cx, oy - hh, w)
        sline(cx, oy - hh, cx + hw, oy, w)
        sline(cx + hw, oy, cx, oy + hh, w)
        sline(cx, oy + hh, cx - hw, oy, w)
    end
end

-- ============================================================================
-- BAKE POOL (audit P10 + supersampling quality pass)
-- ============================================================================
-- Rasterizing arcs/circles/triangles per frame ate the 2005-target's frame
-- budget (a toolbar of 10 icons + one glyph per list row = hundreds of
-- primitives). Cure: bake each (icon, size, color) into an offscreen buffer
-- on first use, then blit — a blit is a plain memory copy.
--
-- Quality: the bake draws the glyph at 4x into a scratch buffer, then
-- downscales in two filtered halving passes (gfx.mode default = bilinear
-- filtering; two passes ≈ a 16-tap box filter). Hard-edged primitives come
-- out antialiased; stroke thickness scales via the stroke kit above.
--
-- Buffer map: 926-989 bake slots (64), 990 = 4x scratch, 991 = half-step
-- scratch, 992 = PNG override load slot (knob uses 910-925, inputs 900-901,
-- ColorPicker 902-903, BufferedClip 904, images 200-899). On pool
-- exhaustion everything is wiped and re-baked on demand — rare (theme
-- change), amortized. Colors are quantized to 4 bits/channel for the cache
-- key so animated fades don't mint unlimited entries.
local ICON_BUF_FIRST, ICON_BUF_LAST = 926, 989
local ICON_MAX_BAKE_SIZE = 128
local SS = 4
local SS_BUF, HALF_BUF, PNG_BUF = 990, 991, 992
local icon_cache = {}      -- [name] = { [key] = buf_id }
local icon_next_buf = ICON_BUF_FIRST

-- PNG overrides: CP_Toolkit/IconOverrides/<Name>.png (white on transparent,
-- 64-128px square). Missing files are probed once per session; present
-- files are re-loaded per bake (disk cost is bake-time only, amortized).
local override_dir =
    (debug.getinfo(1, "S").source:match("@?(.*[/\\])") or "") .. "IconOverrides/"
local png_probe = {}       -- [name] = true (exists) | false (absent)

local function png_load(name)
    if png_probe[name] == false then return false end
    local ok = gfx.loadimg(PNG_BUF, override_dir .. name .. ".png") >= 0
    png_probe[name] = ok
    return ok
end

local function icon_pool_wipe()
    for buf = ICON_BUF_FIRST, icon_next_buf - 1 do
        gfx.setimgdim(buf, 0, 0)
    end
    for k in pairs(icon_cache) do icon_cache[k] = nil end
    icon_next_buf = ICON_BUF_FIRST
end

-- Reentrancy: some glyphs compose others (Volume draws Mute, EyeOff draws
-- Eye). During a bake those inner calls must draw DIRECT into the scratch
-- at the supersampled size — a nested bake would wipe SS_BUF mid-bake.
local baking = false

-- gfx.setimgdim leaves the buffer contents UNDEFINED after a resize (per
-- the API doc — current builds happen to zero it). Deterministic clear:
-- multiply every channel (incl. alpha) by 0. gfx.dest must be the buffer.
local function clear_buf(w, h)
    gfx.muladdrect(0, 0, w, h, 0, 0, 0, 0)
end

local function bake_icon(buf, name, isize, draw_fn, r, g, b, a)
    local prev_dest = gfx.dest
    local prev_a2 = gfx.a2
    gfx.a2 = 1  -- drawing ops must write real alpha into the scratch buffers
    baking = true

    if png_load(name) then
        -- PNG override: filtered downscale (aspect-fit) + tint in place.
        local iw, ih = gfx.getimgdim(PNG_BUF)
        gfx.dest = buf
        gfx.setimgdim(buf, 0, 0)
        gfx.setimgdim(buf, isize, isize)
        clear_buf(isize, isize)
        if iw > 0 and ih > 0 then
            local sc = (isize / iw < isize / ih) and isize / iw or isize / ih
            local dw, dh = iw * sc, ih * sc
            gfx.a = 1
            gfx.mode = 2  -- straight copy (no src-alpha blend), filtering ON
            gfx.blit(PNG_BUF, 1, 0, 0, 0, iw, ih,
                     (isize - dw) / 2, (isize - dh) / 2, dw, dh)
            gfx.mode = 0
            -- White source × theme color = tinted; alpha × a honors fades.
            gfx.muladdrect(0, 0, isize, isize, r, g, b, a)
        end
    else
        -- Supersampled procedural bake: draw 4x OPAQUE, halve twice, then
        -- apply the requested alpha exactly once. (Drawing with gfx.a = a
        -- and compositing the stored alpha again would fade twice: a 0.5
        -- icon rendered at ~quarter intensity.)
        local ss = isize * SS
        gfx.dest = SS_BUF
        gfx.setimgdim(SS_BUF, 0, 0)
        gfx.setimgdim(SS_BUF, ss, ss)
        clear_buf(ss, ss)
        draw_fn(0, 0, ss, r, g, b, 1)

        gfx.dest = HALF_BUF
        gfx.setimgdim(HALF_BUF, 0, 0)
        gfx.setimgdim(HALF_BUF, isize * 2, isize * 2)
        clear_buf(isize * 2, isize * 2)
        gfx.a = 1
        gfx.mode = 2
        gfx.blit(SS_BUF, 1, 0, 0, 0, ss, ss, 0, 0, isize * 2, isize * 2)

        gfx.dest = buf
        gfx.setimgdim(buf, 0, 0)
        gfx.setimgdim(buf, isize, isize)
        clear_buf(isize, isize)
        gfx.blit(HALF_BUF, 1, 0, 0, 0, isize * 2, isize * 2, 0, 0, isize, isize)
        gfx.mode = 0
        if a < 1 then
            gfx.muladdrect(0, 0, isize, isize, 1, 1, 1, a)
        end
    end

    baking = false
    gfx.a2 = prev_a2
    gfx.dest = prev_dest
end

local function bake_wrap(name, draw_fn)
    return function(x, y, size, r, g, b, a)
        a = a or 1
        -- Composed glyph inside another glyph's bake → draw direct into the
        -- scratch at the supersampled size (see `baking`).
        if baking then
            return draw_fn(x, y, size, r, g, b, a)
        end
        local isize = floor(size + 0.5)
        -- Degenerate or oversized: draw direct, don't hog buffers
        if isize < 2 or isize > ICON_MAX_BAKE_SIZE then
            return draw_fn(x, y, size, r, g, b, a)
        end

        -- Cache key: size + color quantized to 4 bits per channel
        local key = isize * 65536
            + floor(r * 15 + 0.5) * 4096
            + floor(g * 15 + 0.5) * 256
            + floor(b * 15 + 0.5) * 16
            + floor(a * 15 + 0.5)

        local per_name = icon_cache[name]
        if not per_name then
            per_name = {}
            icon_cache[name] = per_name
        end
        local buf = per_name[key]

        if not buf then
            if icon_next_buf > ICON_BUF_LAST then
                icon_pool_wipe()
                per_name = {}
                icon_cache[name] = per_name
            end
            buf = icon_next_buf
            icon_next_buf = icon_next_buf + 1
            bake_icon(buf, name, isize, draw_fn, r, g, b, a)
            per_name[key] = buf
        end

        gfx.set(1, 1, 1, 1)
        gfx.blit(buf, 1, 0, 0, 0, isize, isize, x, y, isize, isize)
    end
end

-- Wrap every icon present at this point. Helpers (SetFontRestorer) are
-- excluded by name. Icons added after this block would be unbaked — add
-- them above.
do
    local NO_BAKE = { SetFontRestorer = true }
    local names = {}
    for name, fn in pairs(Icons) do
        if type(fn) == "function" and not NO_BAKE[name] then
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(names) do
        Icons[name] = bake_wrap(name, Icons[name])
    end
end

-- Rescan the IconOverrides folder and rebake everything (call after adding
-- or editing override PNGs — no restart needed). Defined after the wrap
-- block on purpose: it must not be baked.
function Icons.ReloadOverrides()
    for k in pairs(png_probe) do png_probe[k] = nil end
    icon_pool_wipe()
end

return Icons
