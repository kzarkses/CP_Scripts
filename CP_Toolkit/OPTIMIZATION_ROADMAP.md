# CP_Toolkit Optimization Roadmap

> Companion to `PERFORMANCE.md`. PERFORMANCE.md is the *contract* (rules, why, how to think). This file is the *plan* (what, in what order, how to verify).

## How to use this document

- Tasks are ordered by ROI: gain ÷ effort. Do them top-down.
- Each task lists: **file:line refs**, **what to change**, **acceptance test**, **risk**, and **impact estimate**.
- Mark a task `[x]` when its acceptance test passes on the demo script.
- Do **not** skip Phase 0. Without measurement, the rest is guesswork.
- Do **not** start Phase 3 before Phase 1 + 2 are done. Architectural refactors on top of unoptimized code waste effort.

Impact scale: S (saves <0.1 ms/frame) · M (0.1–0.5 ms) · L (0.5–2 ms) · XL (>2 ms or eliminates idle CPU).

Risk scale: low (local edit) · med (touches multiple widgets) · high (architectural).

---

## Phase 0 — Instrumentation (do this FIRST)

You cannot optimize what you cannot measure. Without these, every "improvement" is a guess.

### 0.1 Frame timer in Core.Run [low risk · enables everything]
- **File:** `Core.lua` around line 700 (`Core.Run`).
- **Do:** wrap `user_loop_fn()` and `gfx.update()` with `reaper.time_precise()`. Maintain a 60-sample moving average of frame ms. Expose via `Core.GetFrameStats()` returning `{avg_ms, peak_ms, last_ms}`.
- **Accept:** demo script shows current frame time in F12 overlay.

### 0.2 Allocation counter (Lua GC delta) [low · enables Rule 1 verification]
- **File:** `Core.lua`.
- **Do:** before `user_loop_fn`, sample `collectgarbage("count")`. After, sample again. Track delta. A clean frame should have delta ≈ 0 KB.
- **Accept:** demo script F12 shows "alloc: X KB/frame". A static page should read 0–1 KB. If it reads 20+ KB, you have hot-path allocation.

### 0.3 Draw call counter [low · helps fillrate analysis]
- **File:** `Core.lua`.
- **Do:** wrap `Core.DrawRect`, `Core.DrawText`, `Core.DrawLine`, plus the gfx primitives. Increment a counter per call, reset each frame. Expose count.
- **Accept:** F12 shows "draws/frame: N". The toolkit demo should be under ~500 draws per frame for the current widget set.

### 0.4 Idle vs. active mode markers [low · groundwork for 2.1]
- **File:** `Core.lua`.
- **Do:** add a `state.frame_dirty = false` flag. Set it true on any mouse movement, click, key, wheel, animation tick. Expose `Core.IsFrameDirty()`. This is just instrumentation for now — Phase 2.1 actually uses it to throttle.
- **Accept:** F12 shows "dirty: yes/no". Static window with mouse outside reads "no".

---

## Phase 1 — Quick wins (no architecture change)

All Phase 1 tasks are local edits. Each can be shipped independently. Cumulative impact: probably **2–4× lower CPU on a typical script** before any structural change.

### 1.1 Cache MeasureText for widget labels [med risk · L impact]
- **Files:** `Widgets.lua` — `Text` (line 168), `Button` (209), `Checkbox` (266), `Slider` (327), `TabBar` (570), `CollapsingHeader` (630), `TreeNode` (731), `RadioGroup` (1743), `NumberInput` (1374), `ColorPicker` (1191).
- **Do:** introduce `Widgets._MeasureLabel(label_id, label_text)` that:
  1. Looks up `widget_data["lbl:"..label_id]` for `{text, w, h}`.
  2. If absent OR if cached `text ~= label_text`, call `Core.MeasureText` and store.
  3. Return `w, h`.
- **Note:** the `label_id` should be derived from the widget's id, not from the label string itself (label may contain dynamic content). Use `id .. ":lbl"` or store on the widget's own data.
- **Accept:** allocation counter drops; remove all bare `Core.MeasureText(label)` calls in widget hot paths. F12 frame time should drop measurably on TabBar-heavy demos.
- **Risk:** med. The cache key must invalidate on font size change (DPI scale or theme reload). Add a global font version counter that bumps when `LoadFontSlots` runs; cache entries below current version are invalid.

### 1.2 Cache formatted value strings (sliders, NumberInput, ProgressBar) [low · M]
- **Files:** `Widgets.lua` — slider (line 401), NumberInput (1506), ProgressBar (1837).
- **Do:** in widget_data, store `last_value`, `last_format`, `last_str`. If incoming `value == last_value` and format unchanged, reuse `last_str`. Otherwise re-format and update.
- **Accept:** allocation counter drops on a slider-heavy page that isn't being dragged.
- **Risk:** low.

### 1.3 Pre-cast Table cell values [low · M for tables]
- **File:** `Widgets.lua` — `Table` (line 1864).
- **Do:** add an internal cache keyed by table id. On first call OR when row count or any cell value changes, walk rows once and store `string_rows[i][j] = tostring(rows[i][j])`. Reuse next frame.
- **Note:** detecting "rows changed" cheaply means hashing or trusting the user to call an invalidate. Simpler interim: cache only when the table has a stable identity flag.
- **Accept:** rendering a 100-row table no longer allocates per frame.
- **Risk:** low.

### 1.4 Stop redundant `Core.SetWidgetData` calls [low · S–M]
- **Files:** all widgets that do `Core.SetWidgetData("foo_"..id, data)` after only mutating fields.
- **Do:** when `data` was obtained from `Core.GetWidgetData`, mutations are already visible (it's a reference). Remove the `SetWidgetData` call. Only keep it for widgets that *replace* `data` with a new table.
- **Accept:** SetWidgetData call count drops to ~zero per frame in stable state.
- **Risk:** low.

### 1.5 Pre-build widget_data id strings [low · M]
- **Files:** all widgets using `"prefix_" .. id`.
- **Do:** option A — switch widget_data storage from `state.widget_data["combo_"..id]` to `state.widget_data.combo[id]`. Each widget category gets its own sub-table. Eliminates one concat per call.
- **Or option B:** require id strings to be passed in already namespaced (e.g., `"combo:track:3"`), and use the id directly.
- **Accept:** no more `..` concat in widget hot paths; allocation counter drops.
- **Risk:** low to med (mechanical refactor, many sites).

### 1.6 ColorPicker gradient → buffered [low · L when picker open]
- **File:** `Widgets.lua` line 1280–1296.
- **Do:** allocate one offscreen buffer per ColorPicker instance (or one shared, keyed by hue). On hue change, redraw the gradient into the buffer once. Each frame: blit the buffer instead of running the nested per-pixel loop.
- **Accept:** popup open frame time < 0.5 ms (currently likely 5–15 ms).
- **Risk:** low — the gradient logic is self-contained.

### 1.7 TextEdit: cache the lines split [low · M for editors]
- **File:** `Widgets.lua` line 1657.
- **Do:** in widget_data, store `lines_cache` and `lines_cache_text`. Re-split only when `text ~= lines_cache_text`.
- **Accept:** TextEdit on a 200-line buffer no longer allocates 200 strings/frame.
- **Risk:** low.

### 1.8 TextEdit: don't re-setimgdim every frame [low · S]
- **File:** `Widgets.lua` line 1685.
- **Do:** track `last_buf_w, last_buf_h` per editor. Only call `gfx.setimgdim(buf_id, vis_w, vis_h)` when the size actually changes.
- **Accept:** verifiable via draw call counter — fewer gfx state changes.
- **Risk:** low.

### 1.9 Knob: bake the arc into a buffer [med · M for knob-heavy panels]
- **File:** `Widgets.lua` line 791 (Knob).
- **Do:** since the track arc is identical for every knob of the same size, cache it once per (size, color) tuple in a buffer. The value arc still runs per-frame because it varies, but the background can be a blit.
- **Note:** for a Mixer with 30 knobs, this turns 30×N arc-thickness loops into 30 blits + 30 short loops.
- **Accept:** Mixer demo with 30 knobs frame time drops by ~20%.
- **Risk:** med — buffer key management.

---

## Phase 2 — Structural fixes

These touch the engine, not just widgets. Bigger gains, more careful work.

### 2.1 Idle throttle in Core.Run [med · XL impact]
- **File:** `Core.lua` line 700–780.
- **Do:** introduce a tiered defer cadence:
  - **Active** (mouse moved, click, key, wheel, animation pending, popup open, anchor active): `reaper.defer(frame)` → ~30 fps.
  - **Idle** (none of the above, two consecutive clean frames): switch to `reaper.runloop` style throttle, e.g. defer with a `reaper.time_precise` gate of ~150 ms (≈6 Hz).
  - On any input event arriving during idle, immediately resume active cadence within one frame.
- **Mechanism for "frame is clean":** use the dirty flag from 0.4. A frame is clean if no mouse delta, no buttons changed, no chars, wheel == 0, no animation has values still moving toward target, no popup open, no `wheel_consumed`, no widget marked itself dirty.
- **Accept:** open a static toolkit window. CPU should drop from ~5–8% to <0.5% within 1 second of idle. Wiggling the mouse over the window resumes immediately with no perceptible lag.
- **Risk:** med. Two failure modes to test:
  1. **Animation killed by idle**: ensure animations request "active mode" while their value hasn't reached target.
  2. **External state changes** (REAPER playback position, FX values): if you display live data, you must opt-in to active mode via a `Core.RequestRedraw()` call.
- **Why this is the highest single impact in the entire roadmap:** it changes the toolkit from "constant 30 Hz CPU drain" to "5 Hz unless used". For a user with 4 toolkit windows open in REAPER, this alone is a 20× idle CPU reduction.

### 2.2 Visibility-first widget order [med · M]
- **Files:** all widgets, especially in `Widgets.lua`.
- **Do:** restructure each widget to:
  1. Compute size from cached label measurements.
  2. Compute position from layout cursor.
  3. Call `IsVisible(x, y, w, h)` — if false, just `AdvanceCursor` and return.
  4. Hit-test, update state, draw.
- **Currently:** most widgets do hit-test and state update before checking visibility. For widgets in scrolled containers (lists with hundreds of items), this is wasted work for clipped rows.
- **Accept:** ActionList with 1000 items (only 10 visible) has frame time independent of list length.
- **Risk:** med — every widget touched. Do them one by one, validate the demo each time.

### 2.3 Frame-local theme color cache [low · S–M]
- **File:** `Layout.lua` and widgets.
- **Do:** at the start of each frame in `Layout.Begin`, copy the most-used theme colors into local upvalues (window_bg, text, button, button_hovered, frame_bg, accent…). Widgets read from those upvalues instead of `theme.colors.x` table lookups.
- **Accept:** small but measurable reduction in widget call cost. Mostly a micro-opt — do this *after* the bigger wins.
- **Risk:** low.

### 2.4 Single allocation map for clip stack [low · S]
- **File:** `Core.lua` line 248.
- **Do:** the clip stack uses `clip_stack[#clip_stack + 1] = { x=x, y=y, w=w, h=h }` — allocates a table per push. Switch to a parallel array layout: 4 arrays (`clip_x`, `clip_y`, `clip_w`, `clip_h`) and an index counter. Push = 4 array writes, no allocation.
- **Accept:** zero allocations from clip pushes per frame.
- **Risk:** low.

### 2.5 Reduce double bounds checks in MouseInClippedRect [low · S]
- **File:** `Core.lua` line 300.
- **Do:** inline the clip+hit test into a single bounds intersection. Avoid the helper-on-helper structure.
- **Accept:** measurable widget hit-test reduction on dense pages.
- **Risk:** low.

---

## Phase 3 — Architectural deep work

These are bigger refactors. Consider them only after Phases 0–2 are done and you still need more headroom (e.g., a Mixer with 200 tracks lags).

### 3.1 Dirty rect system [high · XL]
- **What:** track a list of "dirty rectangles" each frame. Only those regions are redrawn. The rest is left alone (or blitted from a persistent backbuffer).
- **Why hard:** REAPER's `gfx.*` doesn't expose a backbuffer compositor. You have to maintain your own offscreen image (full window size), draw into it, and blit to screen. On window resize you reallocate the buffer.
- **Sketch:**
  - Maintain a backbuffer image (`gfx.dest = backbuffer_id`) of window size.
  - Each frame, the user loop runs and "draws" — but draws into the backbuffer.
  - Widgets compute a hash of their visual state. If unchanged from last frame and their position is unchanged, mark their rect as "skip" and don't draw it.
  - At end of frame, for any rects that *were* drawn, also mark them in a dirty list. Blit only those rects from backbuffer to screen.
  - On mouse move, the *previous* hover region and the *new* hover region are both dirty.
- **Big risk:** complexity explosion. Imgui-style devs love it because there's no extra bookkeeping; retained mode devs hate it for the same reason. This refactor brings *some* bookkeeping back, which is the price of perf.
- **Accept:** static toolkit window has 0 draw calls per frame after the initial draw. Mouse hover causes only 2 small rect blits.
- **Recommendation:** prototype on a single widget first (Button), validate, then scale.

### 3.2 Draw command batching [high · L]
- **What:** instead of widgets calling `gfx.set` + `gfx.rect` directly, they push commands to a list. At end of frame, sort by color/font, then issue. Reduces gfx state changes.
- **Why:** `gfx.set` followed by `gfx.rect` is one state change + one draw. If 50 widgets all use the same `frame_bg` color, you can do 1 state change + 50 draws.
- **Note:** this is what most retained-mode UIs do internally. Worth it only if Phase 1+2 left a measurable bottleneck on `gfx.set`.
- **Accept:** measurable reduction in `gfx.set` call count per frame.
- **Risk:** high — fundamentally changes how widgets emit draws.

### 3.3 Font version + invalidation system [med · S]
- **What:** when DPI scale or theme changes, all cached MeasureText results become invalid. A global version counter that increments on font reload, stamped on every cached entry, lets stale entries auto-invalidate.
- **Already needed by 1.1.** Promoted here to track it explicitly.
- **Risk:** med.

---

## Phase 4 — Optional escape hatch: native extension

Only consider this if Phases 0–3 are complete and you still hit a hard wall (e.g., FX scanning of 10k plugins is too slow even with Lua optimized).

### 4.1 Identify candidates for native offload
Things that make sense to push into a small C++ extension exposed as ReaScript functions:
- **FX Database** — index 10k plugins, hash-keyed lookups, in-RAM cache, persistence.
- **Gesture engine** — tight input loop, custom hit-testing for FX Constellation.
- **Bulk MeasureText** — a cached text-measurement function that takes (font_id, string) and returns w,h, all in C++ with a global hash table.
- **JSFX gmem helpers** — already using JSFX, could expose more gmem ops.

Things that should stay in Lua:
- The widget loop itself (iteration speed > raw perf).
- Layout, theme, drawing primitives (already thin wrappers over `gfx.*` which is C).
- Anything you want to hot-reload during dev.

### 4.2 Architecture
- One extension DLL: `CP_Native.dll` (or .dylib/.so).
- Built from `reaper-sdk` (Cockos GitHub) in C++ or Rust (via `reaper-rs`).
- Exposes new ReaScript functions: `CP_FXDB_Query`, `CP_MeasureCached`, `CP_Gesture_Update`, etc.
- Lua scripts call them like any reaper.* function.
- The extension owns the heavy state; the Lua side stays UI-only.

### 4.3 Cost
- Three platform builds (Win/Mac/Linux) — Mac requires signing.
- Distribution via ReaPack supports extensions but it's clunkier than scripts.
- Compile-edit-test loop replaces Lua's reload-and-run.
- Crash in extension = REAPER crashes (vs. Lua errors are caught).

### 4.4 Recommendation
**Don't do this until you've done Phases 0–3.** The gain over a tightly-written Lua toolkit is real but smaller than people expect — maybe 2–3× on hot paths, not 10×. The hidden cost (iteration speed, distribution complexity) is large for a solo dev. The right time to extend native is when you have a *specific service* that genuinely cannot meet its target in Lua (e.g., "scan 10k FX in under 2s") rather than because Lua "feels slow".

---

## Suggested execution order

If you want a single ordered to-do list, here it is:

1. [x] 0.1 Frame timer
2. [x] 0.2 Alloc counter
3. [x] 0.4 Dirty flag (instrumentation)
4. [x] 2.1 Idle throttle ← **biggest single win, do this early**
5. [x] 1.1 MeasureText cache
6. [x] 1.2 Format value cache (slider, NumberInput, ProgressBar, RangeSlider)
7. [x] 1.4 Drop redundant SetWidgetData
8. [x] 1.5 Widget data id namespacing (GetWidgetSubData + init sentinels)
9. [x] 1.6 ColorPicker buffer (SV gradient + hue bar baked)
10. [x] 1.7 TextEdit lines cache (extended to click handler)
11. [x] 1.3 Table pre-cast (cell tostring + MeasureText cached per-cell)
12. [x] 1.8 TextEdit setimgdim (only on size change)
13. [x] 0.3 Draw counter (if not done)
14. [~] 2.2 Visibility-first reorder (partial — MouseInClippedRect inlined now short-circuits; list widgets use scroll_offset)
15. [x] 1.9 Knob arc cache (shared per-size buffer pool, slots 910-925)
16. [x] 2.4 Clip stack flatten (parallel clip_x/y/w/h arrays, no per-push alloc)
17. [~] 2.3 Theme color frame cache (partial — widgets already cache locally per function)
18. [x] 2.5 MouseInClippedRect inline (single bounds intersection, no helper calls)
19. [x] math.* localization (Widgets, Core, Layout — ~200 lookups saved/frame)
20. *(Re-measure. Decide if Phase 3 is needed.)*
21. 3.1 Dirty rect system (only if needed)
22. 3.2 Draw batching (only if needed)

After step 7 (post-1.4), expect noticeable improvement on the demo's idle CPU.
After step 4 (post-2.1), expect *dramatic* improvement on multi-window setups.
After step 14 (post-2.2), expect long lists to scroll smoothly regardless of length.

## What "done" looks like

A toolkit script meeting all of these on a midrange modern machine:
- Idle CPU < 0.5%.
- Active redraw < 2 ms/frame.
- Mouse move only causes the hovered widget to redraw, not the whole window.
- Opening a window with 200 widgets takes < 100 ms.
- A 1000-row list scrolls at 60 fps with no slowdown vs. a 10-row list.
- Lua GC delta per idle frame: 0 KB.
- Frame time stable — no stutters from GC pauses.

If all of those hold, you can confidently say you have a *frugal* immediate-mode toolkit, and the 2005 PC test would pass.
