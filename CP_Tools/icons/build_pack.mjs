// CP icon pack builder — Lucide SVG → gfx primitives
//
//   node CP_Tools/icons/build_pack.mjs
//
// Reads manifest.txt, parses the named SVGs out of Lucide/lucide-main/icons/,
// flattens every shape to polylines in Lucide's own 24x24 space, and writes
// CP_Toolkit/IconsPack.lua — pure data, no logic. Icons.lua turns each entry
// into a normal icon function and bakes it like the hand-drawn ones.
//
// Why flatten at BUILD time rather than draw beziers at runtime: an icon is
// rasterized once into its bake slot and blitted forever after, so curve
// subdivision is a cost we can pay here exactly once instead of shipping a
// bezier evaluator into the frame path. It also keeps the runtime loop free
// of allocation — it walks a flat array of numbers and calls sline.
//
// Why a build tool in JS and not a ReaScript: it must run outside REAPER so
// the pack can be regenerated and reviewed like any other source artifact.
// The output is the only thing that ships.

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')
const ICON_DIR = join(ROOT, 'Lucide', 'lucide-main', 'icons')
const MANIFEST = join(HERE, 'manifest.txt')
const OUT = join(ROOT, 'CP_Toolkit', 'IconsPack.lua')

// Flattening tolerance in SOURCE units (the viewBox is 24 wide). 0.35 keeps a
// full-width curve under ~24 segments, which is invisible at the 4x bake.
const SEG = 0.35
const ARC_STEP = Math.PI / 12

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
const dist = (ax, ay, bx, by) => Math.hypot(bx - ax, by - ay)

function segCount(len) {
    return Math.max(2, Math.min(28, Math.ceil(len / SEG)))
}

function cubic(x0, y0, x1, y1, x2, y2, x3, y3, out) {
    const n = segCount(dist(x0, y0, x1, y1) + dist(x1, y1, x2, y2) + dist(x2, y2, x3, y3))
    for (let i = 1; i <= n; i++) {
        const t = i / n, u = 1 - t
        const a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        out.push([a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3])
    }
}

function quad(x0, y0, x1, y1, x2, y2, out) {
    // promote to cubic — one code path for subdivision
    cubic(x0, y0,
          x0 + (2 / 3) * (x1 - x0), y0 + (2 / 3) * (y1 - y0),
          x2 + (2 / 3) * (x1 - x2), y2 + (2 / 3) * (y1 - y2),
          x2, y2, out)
}

// SVG endpoint-parameterized arc → points (F.6.5 of the SVG spec).
function arc(x1, y1, rx, ry, phiDeg, fa, fs, x2, y2, out) {
    if (rx === 0 || ry === 0 || (x1 === x2 && y1 === y2)) {
        out.push([x2, y2])
        return
    }
    const phi = (phiDeg * Math.PI) / 180
    const cp = Math.cos(phi), sp = Math.sin(phi)
    const dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
    const x1p = cp * dx + sp * dy
    const y1p = -sp * dx + cp * dy
    rx = Math.abs(rx); ry = Math.abs(ry)
    const lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if (lam > 1) { const s = Math.sqrt(lam); rx *= s; ry *= s }
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    let num = rx * rx * ry * ry - den
    if (num < 0) num = 0
    const co = (fa !== fs ? 1 : -1) * Math.sqrt(num / den)
    const cxp = (co * rx * y1p) / ry
    const cyp = (-co * ry * x1p) / rx
    const cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    const cy = sp * cxp + cp * cyp + (y1 + y2) / 2

    const ang = (ux, uy, vx, vy) => {
        const d = Math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        let c = (ux * vx + uy * vy) / d
        c = Math.max(-1, Math.min(1, c))
        return (ux * vy - uy * vx < 0 ? -1 : 1) * Math.acos(c)
    }
    const ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
    const vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
    const th1 = ang(1, 0, ux, uy)
    let dth = ang(ux, uy, vx, vy)
    if (!fs && dth > 0) dth -= 2 * Math.PI
    else if (fs && dth < 0) dth += 2 * Math.PI

    const n = Math.max(2, Math.ceil(Math.abs(dth) / ARC_STEP))
    for (let i = 1; i <= n; i++) {
        const t = th1 + (dth * i) / n
        const ct = Math.cos(t), st = Math.sin(t)
        out.push([cp * rx * ct - sp * ry * st + cx, sp * rx * ct + cp * ry * st + cy])
    }
}

// ---------------------------------------------------------------------------
// Path data
// ---------------------------------------------------------------------------
const D_TOKEN = /([MmLlHhVvCcSsQqTtAaZz])|(-?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)/g

function parsePath(d) {
    const toks = []
    let m
    D_TOKEN.lastIndex = 0
    while ((m = D_TOKEN.exec(d)) !== null) toks.push(m[1] !== undefined ? m[1] : parseFloat(m[2]))

    const subs = []
    let pts = null, closed = false
    let x = 0, y = 0, sx = 0, sy = 0
    let px = 0, py = 0          // last bezier control, for S/T reflection
    let lastCmd = ''
    let lastPrev = ''           // previous command letter, for S/T reflection
    let i = 0

    const flush = () => {
        if (pts && pts.length > 1) subs.push({ closed, pts })
        pts = null
        closed = false
    }
    const start = () => {
        flush()
        pts = [[x, y]]
        sx = x; sy = y
    }
    const num = () => toks[i++]

    while (i < toks.length) {
        let cmd = toks[i]
        if (typeof cmd === 'string') { i++ } else { cmd = lastCmd === 'M' ? 'L' : lastCmd === 'm' ? 'l' : lastCmd }
        lastCmd = cmd
        const rel = cmd >= 'a'
        const C = cmd.toUpperCase()

        if (C === 'Z') {
            if (pts) { closed = true; flush() }
            x = sx; y = sy
            continue
        }
        if (C === 'M') {
            const nx = num(), ny = num()
            x = rel ? x + nx : nx
            y = rel ? y + ny : ny
            start()
            continue
        }
        if (!pts) pts = [[x, y]]

        if (C === 'L') {
            const nx = num(), ny = num()
            x = rel ? x + nx : nx; y = rel ? y + ny : ny
            pts.push([x, y])
        } else if (C === 'H') {
            const nx = num(); x = rel ? x + nx : nx
            pts.push([x, y])
        } else if (C === 'V') {
            const ny = num(); y = rel ? y + ny : ny
            pts.push([x, y])
        } else if (C === 'C' || C === 'S') {
            let c1x, c1y
            if (C === 'C') {
                c1x = num(); c1y = num()
                if (rel) { c1x += x; c1y += y }
            } else {
                const smooth = 'CS'.includes(lastPrev)
                c1x = smooth ? 2 * x - px : x
                c1y = smooth ? 2 * y - py : y
            }
            let c2x = num(), c2y = num()
            let ex = num(), ey = num()
            if (rel) { c2x += x; c2y += y; ex += x; ey += y }
            cubic(x, y, c1x, c1y, c2x, c2y, ex, ey, pts)
            px = c2x; py = c2y
            x = ex; y = ey
        } else if (C === 'Q' || C === 'T') {
            let cx1, cy1
            if (C === 'Q') {
                cx1 = num(); cy1 = num()
                if (rel) { cx1 += x; cy1 += y }
            } else {
                const smooth = 'QT'.includes(lastPrev)
                cx1 = smooth ? 2 * x - px : x
                cy1 = smooth ? 2 * y - py : y
            }
            let ex = num(), ey = num()
            if (rel) { ex += x; ey += y }
            quad(x, y, cx1, cy1, ex, ey, pts)
            px = cx1; py = cy1
            x = ex; y = ey
        } else if (C === 'A') {
            const rx = num(), ry = num(), rot = num()
            const fa = num() !== 0, fs = num() !== 0
            let ex = num(), ey = num()
            if (rel) { ex += x; ey += y }
            arc(x, y, rx, ry, rot, fa, fs, ex, ey, pts)
            x = ex; y = ey
        } else {
            throw new Error('unsupported path command: ' + cmd)
        }
        lastPrev = C
    }
    flush()
    return subs
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------
const attr = (tag, name) => {
    const m = tag.match(new RegExp(name + '\\s*=\\s*"([^"]*)"'))
    return m ? m[1] : null
}
const numAttr = (tag, name, dflt = 0) => {
    const v = attr(tag, name)
    return v === null ? dflt : parseFloat(v)
}

function pointsAttr(v) {
    const n = v.trim().split(/[\s,]+/).map(parseFloat)
    const pts = []
    for (let i = 0; i + 1 < n.length; i += 2) pts.push([n[i], n[i + 1]])
    return pts
}

function roundedRect(x, y, w, h, rx, ry) {
    if (rx <= 0 && ry <= 0) return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]
    rx = rx || ry; ry = ry || rx
    rx = Math.min(rx, w / 2); ry = Math.min(ry, h / 2)
    const pts = []
    // four quarter-ellipses, clockwise from the top-right corner
    const corner = (cx, cy, a0) => {
        const n = Math.max(3, Math.ceil(Math.PI / 2 / ARC_STEP))
        for (let i = 0; i <= n; i++) {
            const a = a0 + (Math.PI / 2) * (i / n)
            pts.push([cx + Math.cos(a) * rx, cy + Math.sin(a) * ry])
        }
    }
    corner(x + w - rx, y + ry, -Math.PI / 2)
    corner(x + w - rx, y + h - ry, 0)
    corner(x + rx, y + h - ry, Math.PI / 2)
    corner(x + rx, y + ry, Math.PI)
    return pts
}

function ellipsePts(cx, cy, rx, ry) {
    const n = Math.max(12, Math.ceil((2 * Math.PI) / ARC_STEP))
    const pts = []
    for (let i = 0; i < n; i++) {
        const a = (2 * Math.PI * i) / n
        pts.push([cx + Math.cos(a) * rx, cy + Math.sin(a) * ry])
    }
    return pts
}

// Every shape becomes one of: {kind:'poly', closed, pts} | {kind:'circle', c}
function parseSVG(svg) {
    const out = []
    const tags = svg.match(/<(path|circle|ellipse|rect|line|polyline|polygon)\b[^>]*>/g) || []
    for (const tag of tags) {
        const kind = tag.match(/<(\w+)/)[1]
        if (kind === 'path') {
            for (const s of parsePath(attr(tag, 'd'))) out.push({ kind: 'poly', ...s })
        } else if (kind === 'circle') {
            out.push({ kind: 'circle', cx: numAttr(tag, 'cx'), cy: numAttr(tag, 'cy'), r: numAttr(tag, 'r') })
        } else if (kind === 'ellipse') {
            const rx = numAttr(tag, 'rx'), ry = numAttr(tag, 'ry')
            if (Math.abs(rx - ry) < 1e-6) {
                out.push({ kind: 'circle', cx: numAttr(tag, 'cx'), cy: numAttr(tag, 'cy'), r: rx })
            } else {
                out.push({ kind: 'poly', closed: true, pts: ellipsePts(numAttr(tag, 'cx'), numAttr(tag, 'cy'), rx, ry) })
            }
        } else if (kind === 'rect') {
            out.push({
                kind: 'poly', closed: true,
                pts: roundedRect(numAttr(tag, 'x'), numAttr(tag, 'y'),
                                 numAttr(tag, 'width'), numAttr(tag, 'height'),
                                 numAttr(tag, 'rx'), numAttr(tag, 'ry')),
            })
        } else if (kind === 'line') {
            out.push({
                kind: 'poly', closed: false,
                pts: [[numAttr(tag, 'x1'), numAttr(tag, 'y1')], [numAttr(tag, 'x2'), numAttr(tag, 'y2')]],
            })
        } else {
            out.push({ kind: 'poly', closed: kind === 'polygon', pts: pointsAttr(attr(tag, 'points')) })
        }
    }
    return out
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------
const fmt = (n) => {
    const v = Math.round(n * 1000) / 1000
    return Object.is(v, -0) ? '0' : String(v)
}

function encode(shapes) {
    const ops = []
    for (const s of shapes) {
        if (s.kind === 'circle') {
            ops.push('3', fmt(s.cx), fmt(s.cy), fmt(s.r))
            continue
        }
        // drop consecutive duplicates: they would cost an sline that draws a dot
        const pts = []
        for (const p of s.pts) {
            const last = pts[pts.length - 1]
            if (!last || Math.abs(last[0] - p[0]) > 1e-4 || Math.abs(last[1] - p[1]) > 1e-4) pts.push(p)
        }
        if (s.closed && pts.length > 1) {
            const a = pts[0], b = pts[pts.length - 1]
            if (Math.abs(a[0] - b[0]) < 1e-4 && Math.abs(a[1] - b[1]) < 1e-4) pts.pop()
        }
        if (pts.length < 2) continue
        ops.push(s.closed ? '2' : '1', String(pts.length))
        for (const p of pts) ops.push(fmt(p[0]), fmt(p[1]))
    }
    return ops
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
if (!existsSync(ICON_DIR)) {
    console.error('Lucide sources not found: ' + ICON_DIR)
    console.error('Download https://github.com/lucide-icons/lucide and put it there.')
    process.exit(1)
}

const entries = []
for (const raw of readFileSync(MANIFEST, 'utf8').split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, '').trim()
    if (!line) continue
    const m = line.match(/^([A-Za-z_]\w*)\s*=\s*(\S+)$/)
    if (!m) { console.error('bad manifest line: ' + raw); process.exit(1) }
    entries.push({ name: m[1], file: m[2] })
}

// Names already drawn by hand in Icons.lua keep their glyph — see manifest.txt.
const existing = new Set(
    [...readFileSync(join(ROOT, 'CP_Toolkit', 'Icons.lua'), 'utf8')
        .matchAll(/^function Icons\.(\w+)\(/gm)].map((m) => m[1]))

const lines = []
let count = 0, skipped = 0, points = 0
for (const { name, file } of entries) {
    if (existing.has(name)) {
        console.warn(`skip  ${name}: already drawn by hand in Icons.lua`)
        skipped++
        continue
    }
    const path = join(ICON_DIR, file + '.svg')
    if (!existsSync(path)) { console.error(`MISS  ${name}: no ${file}.svg`); process.exit(1) }
    const ops = encode(parseSVG(readFileSync(path, 'utf8')))
    if (!ops.length) { console.error(`EMPTY ${name} (${file})`); process.exit(1) }
    lines.push(`    ${name} = { ${ops.join(',')} },`)
    points += ops.length
    count++
}

const out = `-- CP_Toolkit IconsPack — GENERATED, do not edit by hand.
--
-- Source: Lucide (ISC licence, see LUCIDE-LICENSE.txt), the 24x24 stroke set.
-- Rebuild:  node CP_Tools/icons/build_pack.mjs   (edit CP_Tools/icons/manifest.txt
-- to change which glyphs are embedded).
--
-- Pure DATA. Icons.lua turns each entry into a normal icon function and bakes
-- it exactly like the hand-drawn ones, so nothing here knows about gfx.
--
-- Encoding: one flat stream of numbers per icon, in Lucide's 24x24 viewBox.
--   1, n, x1,y1, ... xn,yn   open polyline of n points
--   2, n, x1,y1, ... xn,yn   closed polyline of n points
--   3, cx, cy, r             circle, stroked
-- Flat on purpose: the renderer walks it with numeric indices and allocates
-- nothing, and a bake reads it once.
--
-- ${count} glyphs, ${points} numbers.

return {
${lines.join('\n')}
}
`
writeFileSync(OUT, out)
console.log(`${count} glyphs, ${skipped} skipped, ${points} numbers -> ${OUT}`)
