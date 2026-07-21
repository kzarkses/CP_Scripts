# MIDI piano-roll benchmark — CP vs the field

> Reference document. Generated 2026-07-21 from a multi-agent benchmark run
> (11 survey agents: 2 reading our own two hosts, 8 covering one feature
> category each across the DAWs, plus a REAPER-native deep dive; then a
> synthesis, then 24 factual claims fact-checked adversarially — 6 of which
> came back corrected and were folded in).
>
> This is the analysis that produced the tiered roadmap we implemented
> (Tiers 0-2 + offline generators). Kept because the comparative matrix is
> expensive to rebuild; the *decisions* it drove live in the memory files.
> The "CP now" column is a SNAPSHOT of the state BEFORE that work — it is
> deliberately not updated, so it records where we started.

---

# CP MIDI Piano-Roll — Assessment & Roadmap

*Synthesis of two internal inventories (CP_Editor host + CP_Looper embedded host, both over the shared `Roll` model) and eight cross-DAW benchmark reports. The governing constraint throughout: features live in the shared `Roll` model wherever possible (so both hosts inherit them for free), the architecture is immediate-mode `gfx.*` with a zero-allocation-per-frame hot path on a 2005-era target, and input is mouse + computer keyboard only. Offline note-list transforms are cheap and in-scope; realtime MIDI FX and live MPE playback are hard/out-of-scope, with offline "bake" substitutes proposed where they exist.*

---

## 1. Current CP capabilities

### 1a. The shared `Roll` model (the asset everything builds on)
`Roll` is a structure-of-arrays note cache with a pluggable backend (TakeBackend = item-relative seconds via `MIDI_Get*PPQ*`, used by CP_Editor; LoopBackend = gmem beats, used by CP_Looper). Both hosts render the *same* model, so any op added to `Roll` appears in both. Public ops today:

- **Structural:** `Insert`, `Delete`, `DeleteSel`, `Subdivide` (trap-roll: replace one pitch's run with n equal notes; any n≥1 supported but only power-of-2 driven), `Quantize(snap_fn)` (snaps starts to nearest grid, lengths preserved, selection-else-all; the snap_fn is arbitrary so swing/groove is *latent* but never exposed).
- **Interactive (drag) writers + Commit:** `MoveLive`, `ResizeLive`, `SetVelLive`, with a single sort+resync+undo at release. This drag-then-commit discipline is exactly the shape the benchmark repeatedly calls the right one for zero-alloc live editing.
- **Selection:** `SelectOnly`, `AddSel`, `ClearSel`, `IsSel`, `SelectBox` (rectangular marquee, additive-capable), `SelectPitch` (whole row), `At` (topmost hit-test). Selection survives re-reads by (pitch,start) identity via two parallel arrays.

What the model does **not** represent (so neither host can expose it): copy/paste, duplicate, nudge/transpose commands, velocity ramp, swing/groove storage, scale/chord awareness, arpeggiate, legato, glue/split, humanize, and any CC/expression lane data. These are the real frontier.

### 1b. CP_Editor (full host) — the richer of the two
Wires essentially the entire `Roll` API. Has: click-to-insert (one-grid-step length, floor-snap FL semantics, immediate move-drag), single + shift-additive selection, right-drag marquee, left-click-key row-select, Ctrl+A, Esc-to-deselect, move (whole selection) / resize-right-edge (whole selection delta) / velocity-lane drag, transpose ±semitone (whole selection, Up/Down), nudge ±grid (**primary note only** — an asymmetry worth fixing), quantize (Q), Ctrl+Shift+wheel trap-roll subdivide, wheel-zoom, middle-drag pan, drum-vs-melodic auto mode, a real ruler strip driving REAPER's native loop/edit-cursor, and audition via the CP_Sampler kit bus. Undo is per-op through REAPER's main undo (no in-editor Ctrl+Z).

### 1c. CP_Looper (embedded host) — a strict subset
Wires only `SetBackend/Detach`, `Sync`, `MoveLive`, `ResizeLive`, `Commit`, `At`, `SelectOnly`, `Insert`, `Delete`. It is **single-select, insert/move/resize/delete-one, mouse-only** (zero computer-keyboard handling — no Delete, no arrows, no wheel-zoom/subdivide), velocity is hard-fixed at 100 with no way to change it, no marquee, no batch anything, always shows the whole loop.

### 1d. The parity gap (host-to-host)
Everything below already exists in `Roll` and is used by CP_Editor but is **unused by CP_Looper**: multi-selection (`AddSel/ClearSel`), `SelectBox` marquee, `SelectPitch`, `DeleteSel`, `Subdivide`, `Quantize`, `SetVelLive`, and any default-velocity control. Closing this gap is almost pure host-wiring work with *no model changes*, and it is a hard requirement ("the two hosts should feel consistent"). It should be treated as the price of admission for every new feature: **build the op in `Roll`, then wire both hosts in the same change.**

---

## 2. Comparative feature matrix

Rows = features; columns = the seven surveyed DAWs, REAPER's native MIDI editor, and **CP now**. Legend: ● = full / strong, ◐ = partial or awkward, ○ = absent, † = via offline transform/bake, ‡ = realtime device (out of CP scope). "CP now" reflects CP_Editor unless noted; CP_Looper is generally weaker (see §1c).

| Feature | Ableton 12 | FL 21 | Cubase 14 | Studio One 7 | Bitwig 5 | Logic 11 | REAPER native | **CP now** |
|---|---|---|---|---|---|---|---|---|
| Click/dbl-click add note | ● | ● | ● | ● | ● | ● | ● | ● |
| Draw-then-drag length (one gesture) | ● | ● | ● | ● | ● | ● | ● | ○ (fixed 1-grid) |
| Draw-then-drag velocity (vertical axis) | ● | ◐ | ○ | ● | ● | ◐ | ○ | ○ |
| Paint/brush run (fixed-pitch) | ● | ● | ○ | ● | ● | ● | ◐ | ○ |
| Sticky default length/velocity | ● | ● | ● | ● | ● | ● | ◐ (last-selected) | ◐ (last_vel only) |
| Left-drag marquee | ● | ● | ● | ● | ● | ● | ○ (right-drag) | ○ (right-drag) |
| Shift-add / Ctrl-toggle select | ● | ● | ● | ● | ● | ● | ● | ◐ (add only) |
| Select same pitch (click key) | ◐ | ● | ● | ○ | ○ | ● | ● | ● |
| Select all (Ctrl+A) | ● | ● | ● | ● | ● | ● | ● | ● |
| Semantic select (similar/subposition/invert) | ◐ | ● | ● (LE) | ● | ○ | ● | ◐ (actions) | ○ |
| Keyboard note navigation (step/extend) | ● | ◐ | ● | ○ | ● | ● | ◐ (weak) | ○ |
| Duplicate (Ctrl+D-style, offset by span) | ● | ● (Ctrl+B) | ● | ● (D) | ● | ● (Cmd+R) | ◐ (custom action) | ○ |
| Ctrl/Alt-drag clone | ● | ◐ | ● | ● | ● | ● | ◐ | ○ |
| Copy / paste (+ paste modes) | ● | ● | ● | ● | ● | ● | ● | ○ |
| Repeat N / duplicate-to-fill | ● | ● | ● (Ctrl+K) | ● | ● | ● | ◐ | ○ |
| Transpose ±semitone / ±octave | ● | ● | ● | ● | ● | ● | ◐ (unbound) | ◐ (semitone only) |
| Nudge time by grid (whole selection) | ● | ● | ● | ● | ● | ● | ◐ | ◐ (primary only) |
| Legato / set-to-next | ● | ● | ● | ● | ● | ● | ● (40405) | ○ |
| Glue/join / split | ● | ● | ● | ● | ● | ● | ● | ◐ (subdivide only) |
| Reverse / invert / mirror | ● | ● (Alt+Y) | ● | ● | ● | ● (Transform) | ● (native: reverse 40902, invert 40906) | ○ |
| Quantize strength % | ● | ● | ● | ● | ● | ● | ● | ○ (100% only) |
| Swing / groove | ● (Pool) | ● | ● | ● | ● | ● | ◐ (swing only) | ○ (latent) |
| Groove template extract | ● | ● | ● | ● | ◐ | ● | ○ | ○ |
| Humanize / randomize | ● | ● | ● | ● | ● | ● | ● (pos+vel, no length; H) | ○ |
| Velocity lane (draw/ramp) | ● | ● | ● | ● | ● | ● | ● | ◐ (drag only) |
| Scale highlight + snap-to-scale | ● | ● | ● | ● | ◐ | ● | ○ | ○ |
| Chord stamp / chord tools | ◐ | ● (Stamp) | ● (track) | ● (track) | ● (device) | ‡ | ○ | ○ |
| Arpeggiate (offline bake) | ● † | ● † (Alt+A) | ◐ (LE) | ‡ | † | ‡ | ○ | ○ |
| Generative (Euclidean/seed/shape) | ● | ● (Riff) | ○ | ● | ● | ○ | ○ | ○ |
| Per-note probability / ratchet | ● | ◐ (pattern) | ○ | ● (pattern) | ● (Operators) | ● (step seq) | ○ | ○ |
| CC / automation lanes | ◐ (clip env) | ● | ● | ● | ● | ● | ● | ○ (vel only) |
| Per-note MPE / expression | ● | ◐ | ● | ● | ● | ● | ◐ | ○ |
| Drum mode (named rows, diamonds) | ◐ | ● | ● (reorder) | ● | ◐ | ● | ● (Alt+7; custom note-row reorder) | ● |
| Note names / color-by-vel/chan/pitch | ● | ● | ● | ● | ● | ● | ● | ◐ (names + vel-alpha) |
| In-editor undo/redo shortcut | ● | ● | ● | ● | ● | ● | ● | ○ (main undo only) |
| Preview→Apply→dice transform loop | ● | ● | ◐ | ● | ◐ | ● | ○ | ○ |

**The shape of the gap:** CP is already competitive on the *primitive gestures* (insert, move, resize, marquee, row-select, drum mode, ruler/transport) and, on drum work specifically, competitive-to-ahead of REAPER-native on ergonomics — though note REAPER-native is *not* the drum-editing weakling the older literature describes: it has custom note-row view with drag-to-reorder (Named Notes mode), so non-chromatic drum-map ordering is a solved problem there, and it ships native one-click reverse/retrograde (40019/40902/40904) and pitch/interval invert (40905–40912) actions without any SWS/ReaScript. Where CP is genuinely behind is **the whole "command layer"** — duplicate, copy/paste, transforms, quantize-strength, scale awareness, arpeggiate, CC lanes — which is precisely the layer the user asked to close, and precisely the layer that is *pure offline note-list math* and therefore cheap on this architecture.

---

## 3. Gap analysis, ranked by value

Ranking weights: (a) the user's named priorities (note creation, selection, duplicate, arpeggiate), (b) muscle-memory universality across the seven DAWs, (c) feasibility on the zero-alloc immediate-mode architecture, (d) whether it also closes the host-parity gap.

1. **Host parity (CP_Looper ← existing `Roll` ops).** Highest value-for-effort in the entire report: zero model work, pure wiring, and it is a hard requirement. Multi-select, marquee, row-select, DeleteSel, Quantize, velocity editing, default-velocity control, and a keyboard map all already exist in the model and just need surfacing in the Looper.
2. **Duplicate + copy/paste (user priority).** Completely absent from the model — the single biggest "this feels broken" gap. `Ctrl+D` (offset by selection span, grid-snapped, re-selecting the copy so it chains) is the most universal key in the benchmark. Pure offline clone-into-SoA. Also unlocks Ctrl-drag clone and repeat-N.
3. **Selection depth (user priority).** CP has the geometric primitives but lacks Ctrl-toggle deselect, invert, semantic selects (same-subposition, similar velocity/length, stacked-duplicate cleanup), and keyboard note-navigation (an area where REAPER-native's stepping is weak). All are O(n) or O(n log n) passes over the flag array — no engine.
4. **Note-creation ergonomics (user priority).** Draw-then-drag length (and velocity on the vertical axis), sticky last-note defaults, and Bitwig-style Quick-Draw paint (Alt-drag = fixed-pitch run, +Shift = melodic run). These are the highest-ROI mouse gestures in the whole "note entry" survey and are pure geometry.
5. **Note transforms (feeds arpeggiate).** Transpose ±octave, whole-selection nudge (fix the primary-only asymmetry), legato/set-to-next, glue/join, split, and Studio-One-style Mirror (reverse/invert/mirror with pivot choice). Each is a `notes[]→notes[]` function; together they are the substrate the arpeggiator and a future rules-engine sit on. Note that reverse and interval-invert already exist as native REAPER actions, so for CP these are about bringing the same transforms *inside* the shared model (and into CP_Looper, which has no access to REAPER's action list) with an interactive pivot choice, rather than inventing something REAPER lacks.
6. **Arpeggiate (user priority).** Offline bake of a selected chord into a pattern (note-order modes, octave range, rate, gate, swing). Explicitly *not* a realtime device — the chord is simply the current selection. This is a legitimately differentiating feature because REAPER-native has no offline arpeggiate command at all. Depends on #5's transform plumbing and #7's preview loop.
7. **Quantize strength + swing/groove.** The model's `Quantize(snap_fn)` already takes an arbitrary function, so swing and iterative-strength are *latent* — mostly a UI + snap-fn change, not a rewrite. Iterative-quantize (Cubase iQ) and a signed quantize range (à la Logic's Q-Range: at positive values only notes *outside* the range are pulled to grid, at negative values only notes *inside* the range are) are cheap, beloved, offline.
8. **Scale awareness.** Scale highlight is a 12-entry membership LUT read in the draw loop (zero-alloc, closes REAPER-native's single biggest gap), plus snap-edited-pitch-to-scale, in-key transpose, and chord stamp. All pitch-domain lookups in `Roll`.
9. **Velocity lane upgrades + humanize.** Ramp/line draw, scale/compress around a pivot, flatten-to-equal, and a humanize/randomize op (seeded for reproducibility). Worth noting the field's baselines here are uneven — REAPER-native's own humanizer, for instance, randomizes position and velocity but *not* length — so a CP humanize that also jitters length is a genuine (if small) step past native. CP has a velocity lane today but only per-note drag.
10. **CC/expression lanes + per-note MPE.** Highest effort, lowest universality-per-effort *right now*, and it exposes the deepest architecture problem: the LoopBackend gmem protocol stores notes, not CC — so CC in CP_Looper is a **protocol change**, not a UI change, and true MPE playback needs a realtime JSFX. Defer; authoring UI can reuse a breakpoint-envelope widget later.

---

## 4. Tiered roadmap

Each item states: what it is · where it lives (Roll model vs host UI) · feasibility on the immediate-mode zero-alloc/2005-PC architecture · rough effort (S/M/L). The unifying rule for every model op: **add the op to `Roll`, wire both hosts in the same change** — this is how the two-host-parity requirement is satisfied continuously rather than as a separate project.

### TIER 0 — Parity must-haves (do first; unblocks everything and is a hard requirement)

- **Wire existing `Roll` ops into CP_Looper.** What: multi-select (`AddSel/ClearSel`), right-or-left-drag marquee (`SelectBox`), `SelectPitch` on the key column, `DeleteSel`, `Quantize` button, `SetVelLive` velocity editing, and a settable default velocity. Where: **host UI only** — model already supports all of it. Feasibility: trivial; the Looper already renders `IsSel`. Effort: **M** (it's breadth of wiring, not depth).
- **Shared keyboard map in a reusable module.** What: give CP_Looper the same key handling CP_Editor has (Delete, arrows, Ctrl+A, Q, +/−, Home, Esc), factored so both hosts call one keymap. Where: host UI, but factor the dispatch so it is shared. Feasibility: straightforward; respect the existing `midi_edit = not mdrag` gate to avoid index corruption. Effort: **M**.
- **In-editor Ctrl+Z / Ctrl+Y.** What: a key handler that calls REAPER undo/redo (undo points already exist per-op). Where: host UI. Feasibility: trivial; guard against firing mid-drag. Effort: **S**.
- **Note-creation defaults consistency.** What: make CP_Looper honor a sticky last-note velocity/length like CP_Editor's `last_vel`, instead of hard-coded 100. Where: host state + tiny model touchpoint. Effort: **S**.

### TIER 1 — Parity-with-the-field / user-named priorities (the core "considerably improved" push)

- **Duplicate `Ctrl+D` (user priority).** What: clone selection, offset by the selection's time-span (or active time selection), grid-snapped, and *select the copies* so repeated `Ctrl+D` chains. Where: **new `Roll` op** `Duplicate(offset)` → both hosts. Feasibility: pure clone into the SoA; grow arrays outside the draw loop, one sort+commit on release; reuse a preallocated clone buffer. Zero-alloc-safe. Effort: **S–M**.
- **Copy / cut / paste with modes.** What: `Ctrl+C/X/V`; paste-at-edit-cursor (default), paste-at-origin, and paste-preserving-measure-phase (the subtle pro feature, trivial on a beats cache). Where: a small clipboard buffer in `Roll` (preallocated parallel arrays) + host key handling. Feasibility: cheap; the clipboard is backend-unit-agnostic if stored in beats and mapped at paste. Effort: **M**.
- **Ctrl-drag clone + repeat-N + duplicate-to-fill.** What: modifier-drag spawns a moving copy (commit on mouse-up); a typed "Repeat N" prompt; `count = floor(range/span)` fill. Where: host gesture + the `Duplicate` op. Feasibility: reuse the drag-preview buffer already used for MoveLive; no per-frame alloc. Effort: **M**.
- **Selection depth (user priority).** What: Ctrl-toggle deselect, invert (`Shift+I`), select-same-pitch already exists, add select-same-subposition (bar-relative beat), select-similar-by-velocity/length (tolerance), and select-stacked-duplicates (cleanup). Where: **new `Roll` selection ops** → both hosts. Feasibility: O(n)/O(n log n) flag passes on a cached (start,pitch)-sorted index invalidated on edit — squarely within budget. Effort: **M**.
- **Keyboard note-navigation (user priority; strengthens an area REAPER-native handles weakly).** What: a "focus note" walked by Alt+←/→ (along a pitch row) and Alt+↑/↓ (by time), Shift+ to extend. Where: `Roll` maintains a focus index + sorted view; host binds keys. Feasibility: index arithmetic on the sorted array; sort on edit not per frame. Effort: **M**.
- **Left-drag marquee default (with a toggle).** What: flip the default so left-drag on empty = marquee (matching six of seven DAWs) while keeping right-drag as an option; reconcile with left-drag-insert via a draw/select mode or an empty-vs-note hit test. Where: host input. Feasibility: pure input routing. Effort: **S** (but a muscle-memory decision — expose as a preference).
- **Draw-then-drag note creation (user priority).** What: on insert, keep the button held → horizontal drag sets length, vertical drag sets velocity; both become the sticky pen defaults. Where: host gesture; model already has ResizeLive/SetVelLive. Feasibility: extends the existing "insert then immediately move-drag" gesture; no new alloc. Effort: **M**.
- **Bitwig Quick-Draw paint.** What: Alt-drag lays a run of grid-length notes at one pitch; +Shift frees pitch into a melodic run. Where: host gesture + repeated `Insert` (batched, single commit). Feasibility: monophonic-replace on overlap is a cheap same-pitch sweep; batch the inserts, one sort/commit. Effort: **M**.
- **Transpose ±octave + whole-selection nudge.** What: `Shift+↑/↓` = ±octave; make ←/→ nudge the *whole* selection (today the primary note only). Where: model op already exists for transpose; extend nudge to selset. Feasibility: trivial. Effort: **S**.
- **Quantize strength % + iterative quantize + swing.** What: add strength (0–100, default 100), 50-centered swing, and let repeated Q tighten iteratively; keep a per-note original-position shadow for non-destructive preview/reset. Where: extend the existing `Roll.Quantize` (its snap_fn is already arbitrary) → both hosts. Feasibility: the hardest part (an origStart/origVel shadow in the SoA) is a fixed-size array, not per-frame work. Effort: **M**.
- **Scale highlight + snap-to-scale + in-key transpose.** What: root+scale selector; highlight in-scale rows via a 12-entry LUT; snap only *edited* notes (FL's safety rule) with a block-vs-bend choice (Reason); Ctrl+↑/↓ = in-key transpose. Where: `Roll` holds the scale mask + pitch ops; host draws the highlight. Feasibility: the LUT is rebuilt on scale-change only; the draw loop just indexes it — a textbook zero-alloc addition that closes REAPER-native's biggest gap. Effort: **M**.

### TIER 2 — High-value (the "best editors have this" differentiators)

- **Arpeggiate (user priority).** What: offline bake of the selected chord into a pattern — note-order (Up/Down/UpDown/AsPlayed/Random), octave range 1–4, rate (tempo-synced note value), gate %, optional swing. Where: **new `Roll` generator op** `Arpeggiate(opts)` → both hosts. Feasibility: pure `notes[]→notes[]`; the chord is the current selection so no realtime engine; cap output count (Ableton caps Chop at 64) so a bad param can't explode the note list on a slow CPU. Effort: **M**. This is the flagship differentiator vs REAPER-native, which has no offline arpeggiate command at all.
- **Preview → Apply → dice loop (the Live-12 interaction model).** What: transforms compute into a preallocated *scratch* note buffer with live preview; `Ctrl+Enter` bakes; a "dice" button advances a stored RNG seed so preview is stable across frames (critical for the steady-render/zero-alloc contract). Where: shared host UI + a scratch buffer in `Roll`. Feasibility: recompute on parameter-change, not per frame; the draw loop only reads the scratch buffer. Effort: **M–L** (the frame is the UI, not the math). This is the wrapper that makes arpeggiate, humanize, quantize-preview, and the rules-engine all feel first-class.
- **Note transforms suite.** What: legato/set-to-next (+optional overlap ticks), glue/join same-pitch, split-at-cursor, and Mirror (reverse/invert/mirror with pivot = first/middle/last/mean, à la Studio One). Where: **new `Roll` ops** → both hosts. Feasibility: each is O(n log n) once per action; split is the only count-growing op — amortize the SoA append. Effort: **M**. (Reverse and interval-invert exist as native REAPER actions for the TakeBackend, but building them into `Roll` is what gives CP_Looper the same transforms and an interactive pivot.)
- **Chord stamp.** What: pick a chord type, click to place the whole chord (FL Stamp); add a diatonic bottom-up variant when a scale is active. Where: `Roll` op reading a preallocated interval-set table. Effort: **S–M**.
- **Humanize / randomize.** What: bounded, *seeded* (reproducible/undoable) jitter of start/velocity/length with a strength control. Where: `Roll` op. Feasibility: one pass, in place. Note this can go one better than REAPER-native, whose humanizer covers position and velocity but not length. Effort: **S**.
- **Velocity lane upgrades.** What: line/ramp draw (Shift-constrained), scale/compress around a pivot, flatten-selected-to-equal (Logic's Option+Shift), numeric entry, and velocity-follows-draw as the pen default. Where: mostly host UI over `SetVelLive`; scale/compress is a small `Roll` op. Effort: **M**.
- **Strum + groove-template extract.** What: stagger simultaneous onsets along a tension curve; extract a timing+velocity offset table from a `Roll` selection and apply with per-dimension strength. Where: `Roll` ops (time-domain, mapped per backend unit). Feasibility: pure math; groove-from-MIDI is the 90% case (groove-from-audio needs onset detection — defer). Effort: **M**.
- **Semantic/rules mini-engine.** What: an 80/20 of the Cubase Logical Editor — "select where pitch/velocity/length/position in range → set/add/scale property," saveable as named presets. Where: `Roll` transform pass + host UI. Feasibility: generic condition→action over the SoA; one UI replaces a dozen bespoke dialogs. Effort: **M–L**.

### TIER 3 — Advanced (deliberate, defer, or bake-only)

- **Euclidean / seed / shape generators.** What: Bjorklund rhythms, random-in-range with re-roll, melody-along-a-curve. Where: `Roll` generators. Feasibility: tiny algorithms, big payoff, fully offline; gate behind the preview-loop UI. Effort: **M**.
- **Per-note probability / ratchet as stored metadata (Bitwig Operators model).** What: store chance/repeat flags per note; offer an offline **bake** (seeded dice → concrete notes or ratchet splits) now, and live interpretation in the LoopBackend JSFX later. Where: model fields + bake op (offline) / JSFX (realtime, later). Feasibility: storage + bake are cheap; live re-roll per loop needs the JSFX (LoopBackend only — TakeBackend can't re-roll a static take). Effort: **M** offline, **L** realtime.
- **CC / automation lanes.** What: breakpoint arrays `(time,value,shape)` per controller, rendered as stalks/polylines; line/curve/LFO tools (portable from the ReaTeam js LFO node algorithm). Where: `Roll` gains a CC event stream. **Architecture flag:** TakeBackend maps to real REAPER CC + `MIDI_SetCCShape` (square/linear/slow-start-end/fast-start/fast-end/bézier), but **LoopBackend's gmem protocol currently stores only notes** — CC in CP_Looper is a *protocol + JSFX change*, not just UI. Feasibility: rendering is zero-alloc with preallocated point buffers; the protocol extension is the real cost. Effort: **L**.
- **Per-note MPE / expression editing.** What: reuse the CC breakpoint widget for per-note pitch/slide/pressure. Authoring is offline and cheap; **playback** requires per-note-channel voicing (bake into the take for TakeBackend; JSFX voice-allocation for LoopBackend). Effort: **L**; treat authoring and playback as separate milestones.
- **Realtime arpeggiator / chord-pad / live capture.** What: device-style arp reacting to live input, live scale-constrained input, retrospective record. Explicitly **out of scope for the gfx editor** — belongs in a JSFX (LoopBackend) or REAPER's own input path (TakeBackend). The offline substitutes (arpeggiate-bake, chord stamp) already deliver the editor-side value. Effort: **L**, and architecturally separate.
- **Notation view.** Out of scope — a large offline layout engine, unjustifiable on the effort budget and target hardware; the drum-mode named-rows + diamonds view plus REAPER's native notation editor cover the need.

---

## 5. Cross-cutting architecture notes

- **The zero-alloc contract survives all of Tiers 0–2.** Every transform, selection, duplicate, quantize, and generator op runs *on the user action* (keypress/menu/mouse-up), mutates the SoA in place, and mints one undo point. The draw loop never runs a transform. The only per-frame additions are (a) scale-highlight LUT indexing and (b) reading a preallocated scratch/preview buffer — both allocation-free.
- **Seed everything random.** Humanize, generators, probability-bake, and dice must use an explicit stored seed so preview is stable frame-to-frame and results are undoable — this is both a UX expectation (FL "Throw dice", Live "Reseed") and a hard requirement of a steady-render immediate-mode loop.
- **Backend-unit boundary is the only place ops branch.** Express every op in the model's native time unit; TakeBackend maps to seconds/PPQ, LoopBackend to beats. Duplicate/paste offsets, arpeggiate rate, groove tables, and swing all cross this boundary cleanly if stored in beats and mapped at commit.
- **The gmem note-list protocol is the one structural limiter.** It gates CC, per-note channel, and MPE in CP_Looper. Everything in Tiers 0–2 works within the existing note-only protocol; only Tier 3 forces a protocol revision. Verify the current gmem struct fields (esp. whether a per-note channel field exists) before scoping any Tier-3 work.

---

## 6. Bottom line
CP is already a capable primitive-gesture editor and competitive with REAPER-native on drum ergonomics and the transport-integrated ruler. (REAPER-native is a stronger baseline than the older literature implies — it has custom note-row reordering for drum maps and native one-click reverse/invert — so CP's edge is ergonomic packaging and cross-host consistency, not features REAPER lacks.) The whole opportunity is the **command layer** — and it happens to be the cheap-on-this-architecture layer. Sequence: **(0)** close host parity by wiring existing ops into CP_Looper; **(1)** ship duplicate/paste, selection depth, keyboard-nav, and draw-then-drag creation (the user's named note-creation/selection/duplicate priorities, all pure offline ops); **(2)** build the Live-12 preview→apply→dice loop and land arpeggiate + the transform suite + scale awareness on top of it (the user's arpeggiate priority — and, in the case of offline arpeggiate and scale-highlight, genuine leaps over native REAPER); **(3)** treat CC/MPE/realtime as a separate, protocol-touching program of work. Build each op in `Roll` and wire both hosts in the same change, and two-host consistency is maintained by construction rather than chased afterward.
