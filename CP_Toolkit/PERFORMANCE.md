# CP_Toolkit Performance Constraints

> **Read this BEFORE writing any toolkit code, alongside `API.md`.**
> These constraints are not optimization tips — they are non-negotiable design rules.

## The contract

CP_Toolkit must run smoothly on a **2005-era PC** (Pentium 4 ~2.8 GHz, 512 MB RAM,
Intel GMA integrated GPU, no SSD). REAPER itself shipped on machines like that and
felt instant. The toolkit must respect that legacy.

We measure success not by "looks fast on my machine" but by:
- **Idle CPU < 0.5%** when nothing is happening (mouse still, no animation).
- **Active redraw < 2 ms** per frame on a midrange modern machine
  (which extrapolates to <16 ms on a P4).
- **Zero allocations per frame** in the hot path of stable widgets.
- **Memory grows only when state grows** — never per frame.

If you cannot defend a change against these numbers, the change is wrong.

---

## Why this matters

REAPER is a 15 MB installer that boots in 2 seconds and runs hard real-time audio.
A UI toolkit running inside REAPER is borrowing CPU cycles from the audio thread,
the plugin DSP, and the user's session. Every wasted cycle is theft.

ReaImGui is heavy precisely because it ignores this:
- Full UI rebuild every frame (immediate-mode without dirty tracking).
- Lua↔C++ marshalling on every widget call (thousands per frame).
- Constant table/string allocation triggering Lua GC.
- No idle detection — burns CPU even when the user is staring at a static window.

CP_Toolkit must do better. We are immediate-mode (because retained-mode is more
complex than this scope warrants), but we are *frugal* immediate-mode.

---

## The seven rules

### 1. Zero allocation in the hot path
The hot path = anything inside `UI.Run`'s loop callback that runs every frame.

**Forbidden in stable widgets:**
- `{ ... }` — table literal (allocates a table).
- `"foo_" .. id` — string concat (allocates a string).
- `string.format(...)` — allocates the formatted string.
- `tostring(value)` for values that don't change.
- Closures `function() ... end` declared inside the loop.
- `table.insert`, `t[#t+1] = x` on per-frame buffers.

**Allowed:**
- Reading from pre-built tables (theme, persistent widget_data).
- Returning multiple values (`return r, g, b, a` — no table).
- Local variable assignment (stack, not heap).
- Pre-built id strings cached at first call.

**Pattern:** if a widget needs an id-derived string for `widget_data`, cache it
once in widget_data itself, not built every frame.

### 2. Cache `MeasureText` for static text
`gfx.measurestr` crosses the Lua↔C boundary and walks the font glyphs. Calling
it on the same string every frame is waste.

- Widgets that take a `label` argument: measure once on first call (or when label
  changes), store width/height in widget_data.
- Tables/lists with static cell values: measure once when rows are assigned, not
  per row per frame.

### 3. No background fill of unchanged regions
A full-window `DrawRect(0, 0, w, h, ...)` per frame at 1920×1080 is 2 megapixels
of fillrate burned for nothing. The window background should be drawn once and
left alone unless something invalidates it.

This implies a **dirty rect system** for the root container — the next major
toolkit refactor. Until that lands, keep root windows small or accept the cost.

### 4. Idle detection — `defer` smarter
Currently `Core.Run` calls `reaper.defer(frame)` unconditionally → ~30 fps even
when the UI is static and the mouse is still.

A toolkit script with no animation, no hover state changing, no input, no anchor,
should drop to **5 Hz or lower** until something happens. Implementation hint:
track a `dirty` flag set by mouse movement, key input, animation, or explicit
widget invalidation; when clean, defer with `reaper.runloop` or insert a small
`reaper.defer` chain that throttles.

### 5. Don't redraw what hasn't changed
Even within a single frame, a widget that knows its visual state hasn't changed
since last frame should be allowed to skip drawing. This requires per-widget
"last drawn state" tracking and a visible-rect cache.

Until dirty tracking is in place, the next-best thing is to **reduce per-widget
draw call count**:
- Combine border + fill into a single primitive when the API allows.
- Don't draw alternating row backgrounds for hovered/selected rows (the highlight
  already covers them).
- Skip text rendering when the rect would be clipped to zero pixels.

### 6. Hit-testing is cheap, layout is cheap, draw is expensive
Order operations so the expensive ones are last and can be skipped:
1. Compute size (cheap arithmetic).
2. Compute position from layout cursor (cheap).
3. **Visibility test** (`Core.IsVisible`) — if false, return early.
4. Hit-test against mouse (cheap bounds check).
5. Update interaction state.
6. Draw (last, only if visible).

Currently most widgets do hit-test before visibility check — invert this when
the widget is in a scrolled container.

### 7. No "just in case" abstractions
Every layer of indirection costs Lua interp cycles. Some specific anti-patterns
to avoid:
- Wrapping `gfx.rect` in `Core.DrawRect` in `Layout._DrawRect` in
  `Widgets._DrawButton._fill` — collapse to one level.
- Creating a `cell_render` callback for every cell when a tight loop would do.
- Building intermediate lists/tables to pass between widget phases when the data
  is already in scope.
- Generic dispatch over fast paths: e.g., `if opts.font_size then SetFont(...)`
  for every Text call when `Text` and `TextSized` could be two functions.

---

## Frame budget breakdown

For a midrange modern machine, target ~2 ms total per frame for a typical
toolkit script. Rough budget:

| Phase | Budget | Notes |
|---|---|---|
| Layout (cursor advance, clipping) | 0.2 ms | mostly arithmetic |
| Hit-testing | 0.1 ms | bounds checks |
| State updates (hot/active/focus) | 0.1 ms | table writes |
| MeasureText (uncached) | 0.3 ms | crosses C boundary |
| Drawing (gfx.* primitives) | 1.0 ms | dominant cost |
| Input processing | 0.1 ms | mouse/keyboard |
| GC pressure (allocations) | 0.2 ms | pay this only if rule 1 is violated |
| **Total** | **~2 ms** | |

A widget that exceeds 0.05 ms per call is suspicious. A frame that exceeds
4 ms needs investigation.

## How to measure

Add a frame timer in `Core.Run`:

```lua
local t0 = reaper.time_precise()
-- ... user_loop_fn() ...
local frame_ms = (reaper.time_precise() - t0) * 1000
```

Log a moving average of `frame_ms` to the F12 overlay. Any commit that increases
the average by more than 0.1 ms on the demo script is suspect and must be
justified.

## When to suspect a regression

- A new widget that adds > 0.2 ms to a frame containing one instance of it.
- Adding 100 instances of a widget that turns the UI sluggish.
- Lua GC pause visible as stutter (use F12 + animation to see it).
- The window taking > 100 ms to open.
- Memory growing while the user is idle on a static page.

## The 2005 rule

Before adding any feature, ask:

> "Would this run smoothly on a Pentium 4 with 512 MB RAM and Intel GMA graphics?"

If you have to think about it for more than 5 seconds, the answer is no.
Find a leaner approach.
