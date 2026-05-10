-- @description CP_GenerateIcons - render toolbar icons (90x30 PNG, 3 states) for CP scripts
-- @author Cedric Pamalio
--
-- Run once. Outputs PNGs into the same folder as this script.
-- Requires JS_ReaScriptAPI.
--
-- Icons generated:
--   CP_FXConstellation       — 5-node connected constellation
--   CP_Inspector             — magnifier glass + content lines
--   CP_PaintSynth            — paintbrush stroke + sound wave
--   CP_VideoKit              — film frame + play triangle
--   CP_VideoKit_Inspector    — film frame + magnifier
--   CP_VideoKit_Modules      — film frame + stacked module bricks

local r = reaper
if not r.JS_LICE_CreateBitmap then
    r.MB("CP_GenerateIcons requires the JS_ReaScriptAPI extension.",
         "Missing dependency", 0)
    return
end

local info = debug.getinfo(1, "S")
local SCRIPT_PATH = info.source:match("@?(.*[\\/])")

-- ============================================================================
-- LICE color helpers
-- ----------------------------------------------------------------------------
-- JS_LICE wants 0xAARRGGBB for filled, but for line/circle it expects 0xRRGGBB
-- and alpha is passed separately. We always pass white and modulate via alpha.
-- ============================================================================
-- LICE color is 0xRRGGBB (alpha is the separate `alpha` argument).
local WHITE = 0xFFFFFF
local function clear(bm, w, h)
    -- Fully transparent base. mode "COPY" forces destination pixels to
    -- exactly (color, alpha) with no blending, guaranteeing alpha=0.
    r.JS_LICE_FillRect(bm, 0, 0, w, h, 0x000000, 0.0, "COPY")
end

-- ============================================================================
-- CP_FXConstellation icon — 90x30, 3 horizontal states (normal|hover|active)
-- 5 connected nodes (a small constellation), drawn in a 30×30 cell.
-- ============================================================================
local FXC_NODES = {
    { x =  7, y =  9, r = 1.8 },
    { x = 23, y =  8, r = 1.8 },
    { x = 15, y = 14, r = 2.2 },
    { x =  9, y = 22, r = 1.8 },
    { x = 22, y = 22, r = 1.8 },
}
local FXC_LINES = {
    { 1, 3 }, { 3, 2 }, { 3, 4 }, { 3, 5 }, { 4, 5 },
}

local function draw_fxconstellation(bm, ox, line_a, line_w, ring_w, fill)
    -- lines
    for _, ln in ipairs(FXC_LINES) do
        local a, b = FXC_NODES[ln[1]], FXC_NODES[ln[2]]
        -- LICE has no native line thickness; emulate by drawing N parallel lines
        for o = 0, math.floor(line_w) - 1 do
            r.JS_LICE_Line(bm, a.x + ox, a.y + o, b.x + ox, b.y + o,
                           WHITE, line_a, "ALPHA", true)
        end
        r.JS_LICE_Line(bm, a.x + ox, a.y, b.x + ox, b.y,
                       WHITE, line_a, "ALPHA", true)
    end
    -- nodes
    for _, n in ipairs(FXC_NODES) do
        if fill then
            r.JS_LICE_FillCircle(bm, n.x + ox, n.y, n.r + 0.2,
                                 WHITE, 1.0, "ALPHA", true)
        else
            -- ring: outer fill minus inner fill
            r.JS_LICE_FillCircle(bm, n.x + ox, n.y, n.r + ring_w * 0.5,
                                 WHITE, 1.0, "ALPHA", true)
            r.JS_LICE_FillCircle(bm, n.x + ox, n.y, n.r - ring_w * 0.5,
                                 0, 0.0, "COPY", true)
        end
    end
end

-- ============================================================================
-- CP_Inspector icon — 90x30, 3 horizontal states
-- Magnifier glass over 3 stacked content lines, drawn in a 30×30 cell.
-- ============================================================================
local INSP_LINES = {
    { x1 = 5, x2 = 22, y = 9  },
    { x1 = 5, x2 = 20, y = 15 },
    { x1 = 5, x2 = 17, y = 21 },
}
local LENS = { cx = 19, cy = 18, r = 5.5 }
local HANDLE = { x1 = 23, y1 = 22, x2 = 27, y2 = 26 }

local function draw_inspector(bm, ox, line_a, line_w, ring_w, fill)
    -- content lines
    for _, ln in ipairs(INSP_LINES) do
        for o = 0, math.floor(line_w) - 1 do
            r.JS_LICE_Line(bm, ln.x1 + ox, ln.y + o, ln.x2 + ox, ln.y + o,
                           WHITE, line_a, "ALPHA", true)
        end
    end
    -- lens
    if fill then
        r.JS_LICE_FillCircle(bm, LENS.cx + ox, LENS.cy, LENS.r,
                             WHITE, 1.0, "ALPHA", true)
        -- punch a hole so it reads as a ring
        r.JS_LICE_FillCircle(bm, LENS.cx + ox, LENS.cy, LENS.r - 2.2,
                             0, 0.0, "COPY", true)
    else
        r.JS_LICE_FillCircle(bm, LENS.cx + ox, LENS.cy, LENS.r + ring_w * 0.5,
                             WHITE, 1.0, "ALPHA", true)
        r.JS_LICE_FillCircle(bm, LENS.cx + ox, LENS.cy, LENS.r - ring_w * 0.5,
                             0, 0.0, "COPY", true)
    end
    -- handle: thick diagonal line via several parallel strokes
    local thickness = fill and 2.4 or ring_w
    local steps = math.max(2, math.floor(thickness * 1.5))
    for i = 0, steps - 1 do
        -- offset perpendicular to the diagonal (45°): (-1,1) / sqrt(2)
        local off = (i - (steps - 1) * 0.5) * 0.6
        local dx, dy = -off * 0.7071, off * 0.7071
        r.JS_LICE_Line(bm,
            HANDLE.x1 + ox + dx, HANDLE.y1 + dy,
            HANDLE.x2 + ox + dx, HANDLE.y2 + dy,
            WHITE, 1.0, "ALPHA", true)
    end
end

-- ============================================================================
-- Helpers shared by the new icons
-- ============================================================================
local function diagonal_line(bm, x1, y1, x2, y2, alpha, thickness)
    local steps = math.max(2, math.floor(thickness * 1.5))
    for i = 0, steps - 1 do
        local off = (i - (steps - 1) * 0.5) * 0.6
        local dx, dy = -off * 0.7071, off * 0.7071
        r.JS_LICE_Line(bm, x1 + dx, y1 + dy, x2 + dx, y2 + dy,
                       WHITE, alpha, "ALPHA", true)
    end
end

local function ring_or_disc(bm, cx, cy, radius, ring_w, fill)
    if fill then
        r.JS_LICE_FillCircle(bm, cx, cy, radius, WHITE, 1.0, "ALPHA", true)
    else
        r.JS_LICE_FillCircle(bm, cx, cy, radius + ring_w * 0.5, WHITE, 1.0, "ALPHA", true)
        r.JS_LICE_FillCircle(bm, cx, cy, radius - ring_w * 0.5, 0, 0.0, "COPY", true)
    end
end

local function rect_outline(bm, x, y, w, h, alpha, line_w)
    -- Top
    for o = 0, math.floor(line_w) - 1 do
        r.JS_LICE_Line(bm, x, y + o, x + w, y + o, WHITE, alpha, "ALPHA", true)
        r.JS_LICE_Line(bm, x, y + h - 1 - o, x + w, y + h - 1 - o, WHITE, alpha, "ALPHA", true)
        r.JS_LICE_Line(bm, x + o, y, x + o, y + h, WHITE, alpha, "ALPHA", true)
        r.JS_LICE_Line(bm, x + w - 1 - o, y, x + w - 1 - o, y + h, WHITE, alpha, "ALPHA", true)
    end
end

local function rect_filled(bm, x, y, w, h, alpha)
    r.JS_LICE_FillRect(bm, x, y, w, h, WHITE, alpha, "ALPHA")
end

-- ============================================================================
-- CP_PaintSynth icon — paintbrush stroke + sound wave (rounded sine)
-- Brush handle diagonal top-right, brush tip lower-left, wave underneath.
-- ============================================================================
local function draw_paintsynth(bm, ox, line_a, line_w, ring_w, fill)
    -- Diagonal brush handle (top-right → mid)
    local handle = { x1 = 24, y1 = 6, x2 = 14, y2 = 16 }
    diagonal_line(bm, handle.x1 + ox, handle.y1, handle.x2 + ox, handle.y2,
                  line_a + 0.1, fill and 2.4 or ring_w)

    -- Brush tip (small circle at the end of the handle)
    ring_or_disc(bm, 13 + ox, 17, 2.6, ring_w, fill)

    -- Paint dot (the "ink" being deposited)
    if fill then
        r.JS_LICE_FillCircle(bm, 11 + ox, 19, 1.4, WHITE, 1.0, "ALPHA", true)
    end

    -- Sound wave under the brush — a sine traced as connected line segments
    local wave_y = 24
    local steps = 20
    local x0, x1 = 4, 26
    for i = 0, steps - 1 do
        local t1 = i / steps
        local t2 = (i + 1) / steps
        local px1 = x0 + (x1 - x0) * t1
        local px2 = x0 + (x1 - x0) * t2
        local py1 = wave_y + math.sin(t1 * math.pi * 2.5) * 2.2
        local py2 = wave_y + math.sin(t2 * math.pi * 2.5) * 2.2
        for o = 0, math.floor(line_w) - 1 do
            r.JS_LICE_Line(bm, px1 + ox, py1 + o, px2 + ox, py2 + o,
                           WHITE, line_a, "ALPHA", true)
        end
    end
end

-- ============================================================================
-- CP_VideoKit family — shared "film frame" base
-- A simple rectangle frame (the video) used as the visual root for the
-- three VideoKit variants.
-- ============================================================================
local FRAME = { x = 4, y = 6, w = 22, h = 16 }

local function draw_video_frame(bm, ox, line_a, line_w, ring_w, fill)
    if fill then
        rect_filled(bm, FRAME.x + ox, FRAME.y, FRAME.w, FRAME.h, line_a * 0.35)
    end
    rect_outline(bm, FRAME.x + ox, FRAME.y, FRAME.w, FRAME.h, line_a, math.max(1, line_w))
end

-- CP_VideoKit — frame + centered play triangle
local function draw_videokit(bm, ox, line_a, line_w, ring_w, fill)
    draw_video_frame(bm, ox, line_a, line_w, ring_w, fill)

    -- Play triangle inside the frame
    local cx = FRAME.x + FRAME.w * 0.5 + ox
    local cy = FRAME.y + FRAME.h * 0.5
    local size = 5
    -- Build a filled triangle by drawing horizontal scanlines
    for dy = -size, size do
        local progress = (dy + size) / (size * 2)
        local half = size * (1 - progress) * 0.9
        if half > 0.5 then
            local x0 = cx - size * 0.6
            local x1 = x0 + (size - math.abs(dy)) * 0.95
            for o = 0, math.floor(line_w) - 1 do
                r.JS_LICE_Line(bm, x0 + o, cy + dy, x1, cy + dy,
                               WHITE, fill and 1.0 or line_a + 0.1, "ALPHA", true)
            end
        end
    end
end

-- CP_VideoKit_Inspector — frame + magnifier (smaller lens) bottom-right
local function draw_videokit_inspector(bm, ox, line_a, line_w, ring_w, fill)
    draw_video_frame(bm, ox, line_a, line_w, ring_w, fill)

    -- Magnifier overlay
    local lens = { cx = 19, cy = 17, r = 4.2 }
    local handle = { x1 = 22, y1 = 20, x2 = 26, y2 = 24 }

    if fill then
        r.JS_LICE_FillCircle(bm, lens.cx + ox, lens.cy, lens.r, WHITE, 1.0, "ALPHA", true)
        r.JS_LICE_FillCircle(bm, lens.cx + ox, lens.cy, lens.r - 1.8, 0, 0.0, "COPY", true)
    else
        r.JS_LICE_FillCircle(bm, lens.cx + ox, lens.cy, lens.r + ring_w * 0.5,
                             WHITE, 1.0, "ALPHA", true)
        r.JS_LICE_FillCircle(bm, lens.cx + ox, lens.cy, lens.r - ring_w * 0.5,
                             0, 0.0, "COPY", true)
    end

    -- Handle (diagonal)
    local thickness = fill and 2.0 or ring_w
    diagonal_line(bm, handle.x1 + ox, handle.y1, handle.x2 + ox, handle.y2,
                  1.0, thickness)
end

-- CP_VideoKit_Modules — frame + 3 stacked bricks (modules) on the right
local function draw_videokit_modules(bm, ox, line_a, line_w, ring_w, fill)
    draw_video_frame(bm, ox, line_a, line_w, ring_w, fill)

    -- 3 small bricks inside the right portion of the frame
    local bx = 16 + ox
    local bw = 8
    local bh = 3
    local gap = 1
    for i = 0, 2 do
        local by = 9 + i * (bh + gap)
        if fill then
            rect_filled(bm, bx, by, bw, bh, 1.0)
        else
            rect_outline(bm, bx, by, bw, bh, line_a + 0.1, math.max(1, line_w))
        end
    end
end

-- ============================================================================
-- Generate
-- ----------------------------------------------------------------------------
-- States (top→bottom): normal, hover, active.
-- Each state = different (line_alpha, line_width, ring_width, fill).
-- ============================================================================
local STATES = {
    { line_a = 0.45, line_w = 1.0, ring_w = 1.2, fill = false },  -- normal
    { line_a = 0.65, line_w = 1.4, ring_w = 1.6, fill = false },  -- hover
    { line_a = 0.90, line_w = 1.4, ring_w = 1.6, fill = true  },  -- active
}

local function generate(out_name, draw_fn)
    -- isSysBitmap=false → LICE in-memory bitmap with full alpha channel.
    -- isSysBitmap=true uses a GDI bitmap (Windows) which discards alpha
    -- and produces a fully transparent PNG when written with wantAlpha.
    -- REAPER toolbar icons are 90×30 with 3 horizontal states.
    local bm = r.JS_LICE_CreateBitmap(false, 90, 30)
    if not bm then return false, "CreateBitmap failed" end
    clear(bm, 90, 30)
    for i, st in ipairs(STATES) do
        local ox = (i - 1) * 30
        draw_fn(bm, ox, st.line_a, st.line_w, st.ring_w, st.fill)
    end
    local path = SCRIPT_PATH .. out_name
    local ok = r.JS_LICE_WritePNG(path, bm, true)
    r.JS_LICE_DestroyBitmap(bm)
    return ok, path
end

local jobs = {
    { "CP_FXConstellation.png",     draw_fxconstellation     },
    { "CP_Inspector.png",           draw_inspector           },
    { "CP_PaintSynth.png",          draw_paintsynth          },
    { "CP_VideoKit.png",            draw_videokit            },
    { "CP_VideoKit_Inspector.png",  draw_videokit_inspector  },
    { "CP_VideoKit_Modules.png",    draw_videokit_modules    },
}

local results = {}
for _, job in ipairs(jobs) do
    local ok, path = generate(job[1], job[2])
    results[#results + 1] = (ok and "OK   " or "FAIL ") .. path
end

r.MB(table.concat(results, "\n"), "CP_GenerateIcons", 0)
