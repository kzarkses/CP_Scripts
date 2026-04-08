-- CP_Toolkit Icons — Vector icons drawn with gfx primitives
-- All icons take (x, y, size, r, g, b, a) and draw centered in a size x size box.
-- Scale-independent: just pass a bigger size.

local Icons = {}

-- ============================================================================
-- ARROWS
-- ============================================================================
function Icons.ChevronDown(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local cy = y + size / 2
    local s = math.floor(size * 0.3)
    -- V shape
    gfx.line(cx - s, cy - s * 0.4, cx, cy + s * 0.4)
    gfx.line(cx, cy + s * 0.4, cx + s, cy - s * 0.4)
end

function Icons.ChevronUp(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local cy = y + size / 2
    local s = math.floor(size * 0.3)
    gfx.line(cx - s, cy + s * 0.4, cx, cy - s * 0.4)
    gfx.line(cx, cy - s * 0.4, cx + s, cy + s * 0.4)
end

function Icons.ChevronRight(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local cy = y + size / 2
    local s = math.floor(size * 0.3)
    gfx.line(cx - s * 0.4, cy - s, cx + s * 0.4, cy)
    gfx.line(cx + s * 0.4, cy, cx - s * 0.4, cy + s)
end

function Icons.ChevronLeft(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local cy = y + size / 2
    local s = math.floor(size * 0.3)
    gfx.line(cx + s * 0.4, cy - s, cx - s * 0.4, cy)
    gfx.line(cx - s * 0.4, cy, cx + s * 0.4, cy + s)
end

-- Filled triangles (for dropdowns, tree nodes)
function Icons.TriangleDown(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local s = math.floor(size * 0.25)
    local top = y + size / 2 - s * 0.5
    local bot = y + size / 2 + s * 0.5
    for row = 0, s do
        local ratio = row / s
        local half_w = math.floor(s * (1 - ratio))
        gfx.line(cx - half_w, top + row, cx + half_w, top + row)
    end
end

function Icons.TriangleRight(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cy = y + size / 2
    local s = math.floor(size * 0.25)
    local left = x + size / 2 - s * 0.5
    for col = 0, s do
        local ratio = col / s
        local half_h = math.floor(s * (1 - ratio))
        gfx.line(left + col, cy - half_h, left + col, cy + half_h)
    end
end

-- ============================================================================
-- COMMON UI ICONS
-- ============================================================================
function Icons.Check(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local s = math.floor(size * 0.3)
    local cx = x + size / 2
    local cy = y + size / 2
    -- Short leg (down-left to bottom)
    gfx.line(cx - s, cy, cx - s * 0.3, cy + s * 0.7)
    gfx.line(cx - s + 1, cy, cx - s * 0.3 + 1, cy + s * 0.7)
    -- Long leg (bottom to up-right)
    gfx.line(cx - s * 0.3, cy + s * 0.7, cx + s, cy - s * 0.5)
    gfx.line(cx - s * 0.3 + 1, cy + s * 0.7, cx + s + 1, cy - s * 0.5)
end

function Icons.Close(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local m = math.floor(size * 0.3)
    gfx.line(x + m, y + m, x + size - m, y + size - m)
    gfx.line(x + m + 1, y + m, x + size - m + 1, y + size - m)
    gfx.line(x + size - m, y + m, x + m, y + size - m)
    gfx.line(x + size - m - 1, y + m, x + m - 1, y + size - m)
end

function Icons.Plus(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local m = math.floor(size * 0.25)
    local cx = x + size / 2
    local cy = y + size / 2
    gfx.line(cx, y + m, cx, y + size - m)
    gfx.line(x + m, cy, x + size - m, cy)
end

function Icons.Minus(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local m = math.floor(size * 0.25)
    local cy = y + size / 2
    gfx.line(x + m, cy, x + size - m, cy)
end

function Icons.Play(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local s = math.floor(size * 0.3)
    local cx = x + size / 2
    local cy = y + size / 2
    local left = cx - s * 0.5
    for col = 0, s do
        local ratio = col / s
        local half_h = math.floor(s * (1 - ratio))
        gfx.line(left + col, cy - half_h, left + col, cy + half_h)
    end
end

function Icons.Pause(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local m = math.floor(size * 0.28)
    local bar_w = math.max(2, math.floor(size * 0.12))
    gfx.rect(x + m, y + m, bar_w, size - m * 2, 1)
    gfx.rect(x + size - m - bar_w, y + m, bar_w, size - m * 2, 1)
end

function Icons.Stop(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local m = math.floor(size * 0.3)
    gfx.rect(x + m, y + m, size - m * 2, size - m * 2, 1)
end

function Icons.Search(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cr = math.floor(size * 0.25)
    local cx = x + size * 0.4
    local cy = y + size * 0.4
    -- Circle (approximate with lines)
    local segs = 12
    for i = 0, segs - 1 do
        local a1 = (i / segs) * math.pi * 2
        local a2 = ((i + 1) / segs) * math.pi * 2
        gfx.line(
            cx + math.cos(a1) * cr, cy + math.sin(a1) * cr,
            cx + math.cos(a2) * cr, cy + math.sin(a2) * cr)
    end
    -- Handle
    local hx = cx + cr * 0.7
    local hy = cy + cr * 0.7
    gfx.line(hx, hy, x + size * 0.78, y + size * 0.78)
    gfx.line(hx + 1, hy, x + size * 0.78 + 1, y + size * 0.78)
end

function Icons.Settings(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local cy = y + size / 2
    local outer = math.floor(size * 0.35)
    local inner = math.floor(size * 0.18)
    -- Gear teeth (outer circle with notches)
    local segs = 16
    for i = 0, segs - 1 do
        local a1 = (i / segs) * math.pi * 2
        local a2 = ((i + 1) / segs) * math.pi * 2
        local rad = (i % 2 == 0) and outer or (outer - 3)
        local rad2 = ((i + 1) % 2 == 0) and outer or (outer - 3)
        gfx.line(
            cx + math.cos(a1) * rad, cy + math.sin(a1) * rad,
            cx + math.cos(a2) * rad2, cy + math.sin(a2) * rad2)
    end
    -- Inner circle
    for i = 0, 11 do
        local a1 = (i / 12) * math.pi * 2
        local a2 = ((i + 1) / 12) * math.pi * 2
        gfx.line(
            cx + math.cos(a1) * inner, cy + math.sin(a1) * inner,
            cx + math.cos(a2) * inner, cy + math.sin(a2) * inner)
    end
end

function Icons.Refresh(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local cy = y + size / 2
    local rad = math.floor(size * 0.3)
    -- 3/4 circle
    local segs = 12
    for i = 0, segs - 2 do
        local a1 = (i / segs) * math.pi * 2 - math.pi * 0.5
        local a2 = ((i + 1) / segs) * math.pi * 2 - math.pi * 0.5
        gfx.line(
            cx + math.cos(a1) * rad, cy + math.sin(a1) * rad,
            cx + math.cos(a2) * rad, cy + math.sin(a2) * rad)
    end
    -- Arrow head at the end
    local ax = cx + math.cos(-math.pi * 0.5) * rad
    local ay = cy + math.sin(-math.pi * 0.5) * rad
    local s = math.floor(size * 0.12)
    gfx.line(ax, ay, ax + s, ay + s)
    gfx.line(ax, ay, ax - s, ay + s)
end

function Icons.Lock(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local bw = math.floor(size * 0.5)
    local bh = math.floor(size * 0.35)
    local bx = x + (size - bw) / 2
    local by = y + size * 0.5
    gfx.rect(bx, by, bw, bh, 1)
    -- Shackle
    local sr = math.floor(size * 0.18)
    local cx = x + size / 2
    local top = by - sr
    for i = 0, 8 do
        local a1 = math.pi + (i / 8) * math.pi
        local a2 = math.pi + ((i + 1) / 8) * math.pi
        gfx.line(
            cx + math.cos(a1) * sr, top + sr + math.sin(a1) * sr,
            cx + math.cos(a2) * sr, top + sr + math.sin(a2) * sr)
    end
end

function Icons.Eye(x, y, size, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    local cx = x + size / 2
    local cy = y + size / 2
    local w = math.floor(size * 0.38)
    local h = math.floor(size * 0.2)
    -- Eye shape (two arcs)
    local segs = 10
    for i = 0, segs - 1 do
        local a1 = (i / segs) * math.pi
        local a2 = ((i + 1) / segs) * math.pi
        gfx.line(cx - w + math.cos(math.pi - a1) * w, cy - math.sin(a1) * h,
                 cx - w + math.cos(math.pi - a2) * w, cy - math.sin(a2) * h)
        gfx.line(cx - w + math.cos(math.pi - a1) * w, cy + math.sin(a1) * h,
                 cx - w + math.cos(math.pi - a2) * w, cy + math.sin(a2) * h)
    end
    -- Pupil
    local pr = math.floor(size * 0.06)
    gfx.rect(cx - pr, cy - pr, pr * 2, pr * 2, 1)
end

return Icons
