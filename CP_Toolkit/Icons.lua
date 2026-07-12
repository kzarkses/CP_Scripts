-- CP_Toolkit Icons — Vector icons drawn with native gfx primitives
-- All icons: (x, y, size, r, g, b, a) — centered in a size x size box
-- Uses gfx.circle, gfx.triangle, gfx.arc, gfx.line for clean rendering

local Icons = {}

-- ============================================================================
-- HELPERS
-- ============================================================================
local floor = math.floor

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

local function scale(size, factor)
    return math.floor(size * factor + 0.5)
end

-- ============================================================================
-- ARROWS / CHEVRONS
-- ============================================================================
function Icons.ChevronDown(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.line(cx - s, cy - s * 0.5, cx, cy + s * 0.5, 1)
    gfx.line(cx, cy + s * 0.5, cx + s, cy - s * 0.5, 1)
end

function Icons.ChevronUp(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.line(cx - s, cy + s * 0.5, cx, cy - s * 0.5, 1)
    gfx.line(cx, cy - s * 0.5, cx + s, cy + s * 0.5, 1)
end

function Icons.ChevronRight(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.line(cx - s * 0.5, cy - s, cx + s * 0.5, cy, 1)
    gfx.line(cx + s * 0.5, cy, cx - s * 0.5, cy + s, 1)
end

function Icons.ChevronLeft(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.line(cx + s * 0.5, cy - s, cx - s * 0.5, cy, 1)
    gfx.line(cx - s * 0.5, cy, cx + s * 0.5, cy + s, 1)
end

-- Filled triangles (dropdowns, tree nodes)
function Icons.TriangleDown(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    gfx.triangle(cx - s, cy - s * 0.5, cx + s, cy - s * 0.5, cx, cy + s * 0.5)
end

function Icons.TriangleRight(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    gfx.triangle(cx - s * 0.5, cy - s, cx - s * 0.5, cy + s, cx + s * 0.5, cy)
end

function Icons.TriangleLeft(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    gfx.triangle(cx + s * 0.5, cy - s, cx + s * 0.5, cy + s, cx - s * 0.5, cy)
end

function Icons.TriangleUp(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    gfx.triangle(cx - s, cy + s * 0.5, cx + s, cy + s * 0.5, cx, cy - s * 0.5)
end

-- ============================================================================
-- COMMON UI ICONS
-- ============================================================================
function Icons.Close(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local m = scale(size, 0.3)
    -- Double lines for thickness
    gfx.line(x + m, y + m, x + size - m, y + size - m, 1)
    gfx.line(x + m + 1, y + m, x + size - m + 1, y + size - m, 1)
    gfx.line(x + size - m, y + m, x + m, y + size - m, 1)
    gfx.line(x + size - m - 1, y + m, x + m - 1, y + size - m, 1)
end

function Icons.Check(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    -- Short leg + long leg (double lines for thickness)
    gfx.line(cx - s, cy, cx - s * 0.2, cy + s * 0.7, 1)
    gfx.line(cx - s + 1, cy, cx - s * 0.2 + 1, cy + s * 0.7, 1)
    gfx.line(cx - s * 0.2, cy + s * 0.7, cx + s, cy - s * 0.5, 1)
    gfx.line(cx - s * 0.2 + 1, cy + s * 0.7, cx + s + 1, cy - s * 0.5, 1)
end

function Icons.Plus(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    gfx.line(cx, cy - s, cx, cy + s, 1)
    gfx.line(cx - s, cy, cx + s, cy, 1)
end

function Icons.Minus(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    gfx.line(cx - s, cy, cx + s, cy, 1)
end

-- ============================================================================
-- TRANSPORT
-- ============================================================================
function Icons.Play(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    gfx.triangle(cx - s * 0.6, cy - s, cx - s * 0.6, cy + s, cx + s, cy)
end

function Icons.Pause(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    local bar_w = math.max(2, scale(size, 0.08))
    local gap = scale(size, 0.08)
    gfx.rect(cx - gap - bar_w, cy - s, bar_w, s * 2, 1)
    gfx.rect(cx + gap, cy - s, bar_w, s * 2, 1)
end

function Icons.Stop(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.22)
    gfx.rect(cx - s, cy - s, s * 2, s * 2, 1)
end

function Icons.Record(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    gfx.circle(cx, cy, s, 1, 1)
end

function Icons.SkipForward(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    gfx.triangle(cx - s, cy - s, cx - s, cy + s, cx + s * 0.3, cy)
    local bar_w = math.max(2, scale(size, 0.06))
    gfx.rect(cx + s * 0.5, cy - s, bar_w, s * 2, 1)
end

function Icons.SkipBackward(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    gfx.triangle(cx + s, cy - s, cx + s, cy + s, cx - s * 0.3, cy)
    local bar_w = math.max(2, scale(size, 0.06))
    gfx.rect(cx - s * 0.5 - bar_w, cy - s, bar_w, s * 2, 1)
end

function Icons.Loop(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.28)
    -- Two arcs forming a loop
    gfx.arc(cx, cy, s, 0, math.pi, 1)
    gfx.arc(cx, cy, s, math.pi, math.pi * 2, 1)
    -- Arrow heads
    local aw = scale(size, 0.08)
    gfx.triangle(cx + s - aw, cy - aw * 2, cx + s + aw, cy - aw * 2, cx + s, cy)
    gfx.triangle(cx - s - aw, cy + aw * 2, cx - s + aw, cy + aw * 2, cx - s, cy)
end

-- ============================================================================
-- ACTIONS / EDITING
-- ============================================================================
function Icons.Settings(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local outer = scale(size, 0.32)
    local inner = scale(size, 0.15)
    -- Gear teeth (using arc segments)
    local teeth = 6
    for i = 0, teeth - 1 do
        local angle = (i / teeth) * math.pi * 2
        local a1 = angle - 0.25
        local a2 = angle + 0.25
        gfx.arc(cx, cy, outer, a1, a2, 1)
        gfx.arc(cx, cy, outer - 2, a1, a2, 1)
    end
    -- Inner circle
    gfx.circle(cx, cy, inner, 0, 1)
end

function Icons.Search(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local s = scale(size, 0.22)
    local cx = x + size * 0.4
    local cy = y + size * 0.4
    -- Circle (magnifying glass)
    gfx.circle(cx, cy, s, 0, 1)
    -- Handle
    local hx = cx + s * 0.7
    local hy = cy + s * 0.7
    gfx.line(hx, hy, x + size * 0.78, y + size * 0.78, 1)
    gfx.line(hx + 1, hy, x + size * 0.78 + 1, y + size * 0.78, 1)
end

function Icons.Refresh(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.28)
    -- 3/4 circle
    gfx.arc(cx, cy, s, -math.pi * 0.5, math.pi, 1)
    -- Arrow head
    local ax = cx + math.cos(-math.pi * 0.5) * s
    local ay = cy + math.sin(-math.pi * 0.5) * s
    local aw = scale(size, 0.1)
    gfx.triangle(ax, ay, ax + aw, ay + aw, ax - aw, ay + aw)
end

function Icons.Undo(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    gfx.arc(cx + s * 0.3, cy, s, math.pi * 0.5, math.pi * 1.5, 1)
    -- Arrow
    local aw = scale(size, 0.1)
    gfx.triangle(cx + s * 0.3 - s, cy - aw, cx + s * 0.3 - s, cy + aw, cx + s * 0.3 - s - aw, cy)
end

function Icons.Redo(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    gfx.arc(cx - s * 0.3, cy, s, -math.pi * 0.5, math.pi * 0.5, 1)
    local aw = scale(size, 0.1)
    gfx.triangle(cx - s * 0.3 + s, cy - aw, cx - s * 0.3 + s, cy + aw, cx - s * 0.3 + s + aw, cy)
end

function Icons.Delete(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    -- Trash can body
    gfx.rect(cx - s, cy - s * 0.3, s * 2, s * 1.5, 0)
    -- Lid
    gfx.line(cx - s - 2, cy - s * 0.3, cx + s + 2, cy - s * 0.3, 1)
    gfx.line(cx - s * 0.5, cy - s * 0.3, cx - s * 0.5, cy - s * 0.7, 1)
    gfx.line(cx - s * 0.5, cy - s * 0.7, cx + s * 0.5, cy - s * 0.7, 1)
    gfx.line(cx + s * 0.5, cy - s * 0.7, cx + s * 0.5, cy - s * 0.3, 1)
end

function Icons.Copy(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local s = scale(size, 0.2)
    local ox = x + size * 0.3
    local oy = y + size * 0.25
    -- Back page
    gfx.rect(ox + s * 0.3, oy, s * 1.5, s * 2, 0)
    -- Front page
    gfx.rect(ox, oy + s * 0.3, s * 1.5, s * 2, 0)
    gfx.rect(ox + 1, oy + s * 0.3 + 1, s * 1.5 - 2, s * 2 - 2, 1)
end

function Icons.Save(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    -- Floppy body
    gfx.rect(cx - s, cy - s, s * 2, s * 2, 0)
    -- Label area
    gfx.rect(cx - s * 0.6, cy - s, s * 1.2, s * 0.8, 1)
    -- Bottom slot
    gfx.rect(cx - s * 0.5, cy + s * 0.2, s, s * 0.6, 1)
end

-- ============================================================================
-- STATE / STATUS
-- ============================================================================
function Icons.Lock(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    -- Body
    gfx.rect(cx - s, cy, s * 2, s * 1.3, 1)
    -- Shackle (arc)
    gfx.arc(cx, cy, s * 0.7, math.pi, math.pi * 2, 1)
end

function Icons.Unlock(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.2)
    gfx.rect(cx - s, cy, s * 2, s * 1.3, 1)
    gfx.arc(cx, cy, s * 0.7, math.pi, math.pi * 1.7, 1)
end

function Icons.Eye(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.3)
    -- Eye outline (two arcs)
    gfx.arc(cx, cy - s * 0.15, s, 0.3, math.pi - 0.3, 1)
    gfx.arc(cx, cy + s * 0.15, s, math.pi + 0.3, math.pi * 2 - 0.3, 1)
    -- Pupil
    gfx.circle(cx, cy, scale(size, 0.08), 1, 1)
end

function Icons.EyeOff(x, y, size, r, g, b, a)
    Icons.Eye(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    -- Diagonal strike
    local m = scale(size, 0.2)
    gfx.line(x + m, y + size - m, x + size - m, y + m, 1)
    gfx.line(x + m + 1, y + size - m, x + size - m + 1, y + m, 1)
end

function Icons.Mute(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.15)
    -- Speaker body
    gfx.rect(cx - s * 1.5, cy - s * 0.6, s, s * 1.2, 1)
    -- Cone
    gfx.triangle(cx - s * 0.5, cy - s * 0.6, cx - s * 0.5, cy + s * 0.6, cx + s, cy - s * 1.2)
    gfx.triangle(cx - s * 0.5, cy + s * 0.6, cx + s, cy + s * 1.2, cx + s, cy - s * 1.2)
end

function Icons.Volume(x, y, size, r, g, b, a)
    Icons.Mute(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.15)
    -- Sound waves
    gfx.arc(cx + s * 1.3, cy, s * 0.7, -0.6, 0.6, 1)
    gfx.arc(cx + s * 1.3, cy, s * 1.2, -0.5, 0.5, 1)
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
    local bar_w = math.max(1, math.floor(size / (bars * 2)))
    local gap = math.floor((size - bars * bar_w) / (bars + 1))
    local heights = { 0.3, 0.6, 0.9, 1.0, 0.7, 0.5, 0.2 }
    for i = 1, bars do
        local bx = x + gap + (i - 1) * (bar_w + gap)
        local bh = math.floor(size * 0.35 * heights[i])
        gfx.rect(bx, cy - bh, bar_w, bh * 2, 1)
    end
end

function Icons.MIDI(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    -- MIDI connector (circle with pins)
    gfx.circle(cx, cy, s, 0, 1)
    local pin_r = math.max(1, scale(size, 0.04))
    for i = 0, 4 do
        local angle = math.pi * 0.3 + (i / 4) * math.pi * 1.4
        local px = cx + math.cos(angle) * s * 0.55
        local py = cy + math.sin(angle) * s * 0.55
        gfx.circle(px, py, pin_r, 1, 1)
    end
end

function Icons.Folder(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local s = scale(size, 0.22)
    local fx = x + size * 0.2
    local fy = y + size * 0.25
    -- Tab
    gfx.rect(fx, fy, s * 0.8, s * 0.4, 1)
    -- Body
    gfx.rect(fx, fy + s * 0.4, s * 2, s * 1.4, 0)
end

function Icons.File(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local s = scale(size, 0.2)
    local fx = x + size * 0.3
    local fy = y + size * 0.2
    gfx.rect(fx, fy, s * 1.5, s * 2.2, 0)
    -- Corner fold
    gfx.line(fx + s, fy, fx + s * 1.5, fy + s * 0.5, 1)
    gfx.line(fx + s, fy, fx + s, fy + s * 0.5, 1)
    gfx.line(fx + s, fy + s * 0.5, fx + s * 1.5, fy + s * 0.5, 1)
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
    local s = scale(size, 0.3)
    local gap = scale(size, 0.08)
    -- Cross lines with center gap
    gfx.line(cx - s, cy, cx - gap, cy, 1)
    gfx.line(cx + gap, cy, cx + s, cy, 1)
    gfx.line(cx, cy - s, cx, cy - gap, 1)
    gfx.line(cx, cy + gap, cx, cy + s, 1)
    -- Center circle
    gfx.circle(cx, cy, scale(size, 0.04), 1, 1)
end

function Icons.Pipette(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    -- Dropper body (diagonal)
    gfx.line(cx - s, cy + s, cx + s * 0.3, cy - s * 0.3, 1)
    gfx.line(cx - s + 1, cy + s, cx + s * 0.3 + 1, cy - s * 0.3, 1)
    -- Bulb top
    gfx.circle(cx + s * 0.5, cy - s * 0.5, scale(size, 0.1), 1, 1)
    -- Tip
    gfx.circle(cx - s * 0.8, cy + s * 0.8, scale(size, 0.05), 1, 1)
end

-- ============================================================================
-- EXTENDED ICONS (added 2026-05-10 for FX Browser refonte V2)
-- ============================================================================

-- 5-point star outline (favorite indicator, off state)
function Icons.Star(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local outer = scale(size, 0.36)
    local inner = scale(size, 0.15)
    local pi = math.pi
    local pts = {}
    for i = 0, 9 do
        local rad = (i % 2 == 0) and outer or inner
        local ang = -pi / 2 + (i * pi / 5)
        pts[#pts + 1] = cx + math.cos(ang) * rad
        pts[#pts + 1] = cy + math.sin(ang) * rad
    end
    -- Draw outline (10 line segments connecting consecutive points)
    for i = 1, 19, 2 do
        local nx = (i + 2 > 20) and pts[1] or pts[i + 2]
        local ny = (i + 2 > 20) and pts[2] or pts[i + 3]
        gfx.line(pts[i], pts[i + 1], nx, ny, 1)
    end
end

-- Filled star (favorite indicator, on state) — uses native gfx.triangle for fill
function Icons.StarFilled(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local outer = scale(size, 0.36)
    local inner = scale(size, 0.15)
    local pi = math.pi
    local pts = {}
    for i = 0, 9 do
        local rad = (i % 2 == 0) and outer or inner
        local ang = -pi / 2 + (i * pi / 5)
        pts[#pts + 1] = cx + math.cos(ang) * rad
        pts[#pts + 1] = cy + math.sin(ang) * rad
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
    local rad = scale(size, 0.36)
    -- Outline
    gfx.circle(cx, cy, rad, 0, 1)
    -- Hands: hour up, minute right (10:10-style)
    gfx.line(cx, cy, cx, cy - scale(size, 0.22), 1)
    gfx.line(cx, cy, cx + scale(size, 0.20), cy, 1)
    -- Center dot
    gfx.circle(cx, cy, scale(size, 0.05), 1, 1)
end

-- Scan: magnifier with horizontal scan line crossing the lens
function Icons.Scan(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local rad = scale(size, 0.22)
    -- Lens
    gfx.circle(cx - scale(size, 0.05), cy - scale(size, 0.05), rad, 0, 1)
    -- Scan line through the lens
    gfx.line(cx - scale(size, 0.05) - rad, cy - scale(size, 0.05),
             cx - scale(size, 0.05) + rad, cy - scale(size, 0.05), 1)
    -- Handle
    gfx.line(cx + scale(size, 0.13), cy + scale(size, 0.13),
             cx + scale(size, 0.30), cy + scale(size, 0.30), 1)
end

-- Sort A→Z arrows (down arrow with two stacked bars)
function Icons.Sort(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local s = scale(size, 0.25)
    -- Down arrow on left
    gfx.line(cx - s * 1.2, cy - s, cx - s * 1.2, cy + s, 1)
    gfx.line(cx - s * 1.2 - s * 0.4, cy + s * 0.4, cx - s * 1.2, cy + s, 1)
    gfx.line(cx - s * 1.2, cy + s, cx - s * 1.2 + s * 0.4, cy + s * 0.4, 1)
    -- Three lines on the right (decreasing length)
    gfx.line(cx, cy - s, cx + s * 1.2, cy - s, 1)
    gfx.line(cx, cy, cx + s * 0.8, cy, 1)
    gfx.line(cx, cy + s, cx + s * 0.4, cy + s, 1)
end

-- Dice (random — 6-face with 5-pip pattern)
function Icons.Dice(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local half = scale(size, 0.30)
    -- Square
    gfx.line(cx - half, cy - half, cx + half, cy - half, 1)
    gfx.line(cx + half, cy - half, cx + half, cy + half, 1)
    gfx.line(cx + half, cy + half, cx - half, cy + half, 1)
    gfx.line(cx - half, cy + half, cx - half, cy - half, 1)
    -- Five pips (corners + center)
    local pip = scale(size, 0.05)
    local off = scale(size, 0.16)
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
    -- Rectangle slightly tilted (drawn axis-aligned for simplicity)
    gfx.rect(cx - w, cy - h, w * 2, h * 2, 0)
    -- Diagonal split line (separates "tip" from "block")
    gfx.line(cx, cy - h, cx, cy + h, 1)
    -- Action lines (motion)
    local ml = scale(size, 0.08)
    gfx.line(cx + w + 2, cy - h * 0.5, cx + w + 2 + ml, cy - h * 0.5, 1)
    gfx.line(cx + w + 2, cy + h * 0.5, cx + w + 2 + ml, cy + h * 0.5, 1)
end

-- Grip (drag handle: 6 dots in 2 columns, like ⋮⋮)
function Icons.Grip(x, y, size, r, g, b, a)
    set_color(r, g, b, a)
    local cx, cy = center(x, y, size)
    local dot = scale(size, 0.04)
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
    local hh = scale(size, 0.10)
    local off = scale(size, 0.10)
    -- Three diamond outlines stacked vertically
    for i = -1, 1 do
        local oy = cy + i * off
        gfx.line(cx - hw, oy, cx, oy - hh, 1)
        gfx.line(cx, oy - hh, cx + hw, oy, 1)
        gfx.line(cx + hw, oy, cx, oy + hh, 1)
        gfx.line(cx, oy + hh, cx - hw, oy, 1)
    end
end

-- ============================================================================
-- BAKE POOL (audit P10)
-- ============================================================================
-- Every icon above is rasterized from antialiased primitives — arcs, circles,
-- triangles — which LICE renders on the CPU. A toolbar of 10 icons plus one
-- glyph per list row re-traced hundreds of AA primitives per frame; on the
-- 2005 target that alone ate the frame budget. Same cure as the Knob's
-- background (ROADMAP 1.9): bake each (icon, size, color) into an offscreen
-- buffer on first use, then blit — a blit is a plain memory copy.
--
-- Buffer range 926-989 (64 slots; knob uses 910-925, inputs 900-901,
-- ColorPicker 902-903, images 200-899). On pool exhaustion everything is
-- wiped and re-baked on demand — rare (theme change), amortized. Colors are
-- quantized to 4 bits/channel for the cache key so animated fades don't
-- mint unlimited entries; the quantization is invisible at icon sizes.
local ICON_BUF_FIRST, ICON_BUF_LAST = 926, 989
local ICON_MAX_BAKE_SIZE = 128
local icon_cache = {}      -- [name] = { [key] = buf_id }
local icon_next_buf = ICON_BUF_FIRST

local function icon_pool_wipe()
    for buf = ICON_BUF_FIRST, icon_next_buf - 1 do
        gfx.setimgdim(buf, 0, 0)
    end
    for k in pairs(icon_cache) do icon_cache[k] = nil end
    icon_next_buf = ICON_BUF_FIRST
end

local function bake_wrap(name, draw_fn)
    return function(x, y, size, r, g, b, a)
        a = a or 1
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
            -- Resize-to-zero first: guarantees cleared pixels (see knob bake)
            local prev_dest = gfx.dest
            gfx.dest = buf
            gfx.setimgdim(buf, 0, 0)
            gfx.setimgdim(buf, isize, isize)
            draw_fn(0, 0, isize, r, g, b, a)
            gfx.dest = prev_dest
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

return Icons
