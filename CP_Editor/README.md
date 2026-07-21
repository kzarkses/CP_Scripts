# CP Editor

Ableton-style **clip editor** for REAPER, built on CP_Toolkit — one
window, two modes, exactly like Live's clip view:

- click an **audio item** → waveform editor (zoom to sample level,
  zero-crossing selection, non-destructive ops, transient slicing);
- click a **MIDI item** → piano roll (FL-style note editing, drum rows
  named after the CP_Sampler pads).

Run `CP_Editor.lua` as a ReaScript action (formerly `CP_SampleEditor` —
re-bind your custom double-click action once). Requires **SWS**
(preview); **js_ReaScriptAPI** recommended.

## Targets

- **Arrange item** (default): follows the item selection — the Lock
  toggle pins the current target. Audio items show the active region
  bright with draggable fade handles; MIDI items open the piano roll.
- **Raw file** ("Open in Editor" from CP_MediaExplorer rows or
  CP_Sampler pads): view/slice mode — select, audition, send slices and
  selections to pads. Full editing needs an item.

## Audio mode (non-destructive, one undo point each)

| Control | What it does |
|---|---|
| Gain dB | take volume (polarity preserved) |
| Normalize | true-peak scan of the region (source domain, pre-volume) → take volume to hit the target (0/-1/-3/-6 dBFS in settings). Selection scopes it. |
| Reverse | native take reverse — the waveform flips with the wrapped source |
| Pitch st | take pitch — REAPER's élastique, the same zplane engine as Live's Complex warp |
| Rate | playrate (pitch preserved); item length follows |
| Trim to selection | crop the item to the selected region |
| Fade handles | drag the squares at the top of the item region |

Slicing: Detect (sensitivity slider) finds transient onsets → **Split
item**, **Slices to pads** (one file across CP_Sampler pads via RS5K
start/end offsets — no slice files), **Sel to pad**.

## MIDI mode (piano roll)

| Input | Action |
|---|---|
| click empty cell | insert a note (grid length, current velocity); **keep dragging right to set its length** (a plain click keeps one cell) |
| drag a note | move (grid snap; **Ctrl = free**) — moves the whole selection if several are selected |
| drag the right edge | resize (resizes the whole selection together) |
| **right-drag** | **marquee multi-select** (Shift = add to selection) |
| right-click on a note | delete it |
| **left-click** a piano key / drum-row header | select the whole row (that pitch) |
| **right-click** a piano key / drum-row header | audition that note |
| **Ctrl+Shift+Wheel** on a note | **subdivide** the run: ×2 up, ÷2 down (1 → 2 → 4 → 8… fills the same span — trap rolls) |
| velocity lane (bottom) | drag a note's bar (whole selection if multi-selected) |
| Q | quantize (selection, else all) |
| Ctrl+A · Delete | select all · delete the selection |
| **Ctrl+D** · **Ctrl+C/X/V** | duplicate (offset by the selection span, chains) · copy / cut / paste (at the edit cursor) |
| **Ctrl+Z / Ctrl+Y** | undo / redo, in the editor |
| arrows | transpose Up/Down (**Shift = octave**, **Ctrl = in-scale**) · nudge Left/Right, whole selection |
| **Transform** button | the command menu (see below) |
| Space | REAPER transport — the item plays in context |
| Native editor | escape hatch: opens the built-in MIDI editor |

### Transform menu & scale (shared with CP_Looper)

The **Transform** button opens one menu of offline note operations, driven by the
same shared command layer both editors use — so the shortcuts and commands are
**identical in CP_Looper**:

- **Duplicate / Copy / Cut / Paste**.
- **Transpose** (octave / semitone / fifth), **Nudge**, **Length** (set to grid /
  legato), **Reverse**, **Invert pitch**.
- **Velocity** (set / ramp up-down / compress / expand), **Humanize** (light /
  medium / heavy, seeded so it's reproducible), **Quantize** (100 / 66 / 50 % +
  swing).
- **Scale** — pick a root + scale; out-of-scale rows dim in the grid, "Snap
  selection to scale" pulls notes in, and Ctrl+↑/↓ transposes *within* the scale.
- **Chord from note** (stamp a chord on a single selected note) and
  **Arpeggiate** (bake the selected chord into an up/down/updown/random pattern)
  and **Euclidean fill** (spread N hits over the selection's span).

**Top ruler strip** (real handles): click empty space to move the edit
cursor, drag to make a time selection; then **grab an edge** of the time
selection to resize it, its **body** to move it, or the **edit-cursor
flag** to drag it. All snap to the grid (Ctrl = free) and drive REAPER's
transport, so Space plays from there. The cursor shape reacts as you
hover a handle. The left lane is a **piano keyboard** in melodic mode
(black/white keys, C rows labelled) or the **named pad rows** in drum
mode.

The controls are grouped into labelled clusters (SHAPE / PROCESS,
SLICE / SEND, GRID / VIEW / EDIT) separated by dividers — so where to go
is visual, not a flat row.

The **Grid** button sets the editor's snap division (1/1…1/64, triplets)
or follows the project grid; **Note names** draws each note's name
inside it; **Snap** toggles snapping. All independent.

## Preview reflects the edits

In audio mode the in-editor preview (Space) now applies the take's
gain/normalize, pitch and rate, so you **hear** the edits — and the
waveform is scaled by the take volume so you **see** gain/normalize.
(The peaks themselves are source-domain; pitch/rate don't change the
drawn shape, which is correct — reverse does, since the source is
swapped.) Baking edits **destructively** into a new file is still V2.

**Drum rows**: when a CP_Sampler kit exists the rows are the kit pads,
labeled with the pad names (plus any pitch present in the item) — the
FL channel-rack feel; toggle to a classic chromatic piano roll anytime.
Notes audition through the armed kit bus on insert/select/transpose.
Snap follows the **project grid** (tempo changes respected — everything
maps through QN).

## View & shared keys

Wheel = zoom at mouse · middle-drag = pan · Home = fit · +/- = zoom ·
Esc = clear selection → close (layered).

## Architecture

```
CP_Editor.lua       UI: toolbar, mode dispatch, waveform view, piano
                    roll (grid buffered, notes drawn per frame), input
Modules/Wave.lua    PCM_Source_GetPeaks reader: arbitrary [t0,t1] at
                    pixel resolution, per-channel lanes, pooled arrays,
                    async .reapeaks build (also used by CP_Sampler's
                    region strip)
Modules/Ops.lua     item/take property edits + peaks-based analysis
                    (true-peak, transient onsets, zero-cross snap)
Modules/Roll.lua    MIDI note cache + edit layer over a pluggable
                    backend: live no-sort writes during drags, one
                    sorted Commit + undo point at release. The take
                    backend (item-relative seconds ↔ PPQ) is what the
                    editor uses; a caller can inject another backend
                    (e.g. a beat-based loop) — selection, hit-testing,
                    subdivide and quantize are storage-agnostic.
```

Rendering: the waveform / roll grid renders into an offscreen buffer
only when the view changes; a steady frame is one blit plus overlays.
Known limit: looped MIDI items edit their first iteration (source
notes), like the arrange inline editor.

## Where the MIDI feature set came from

[`docs/midi-editor-benchmark.md`](docs/midi-editor-benchmark.md) — the comparative
study behind the piano roll: every editing feature scored across Ableton 12, FL
21, Cubase 14, Studio One 7, Bitwig 5, Logic 11 and REAPER's native editor, with
the gap analysis and the tiered roadmap it produced. Its "CP now" column is a
snapshot of the state *before* that work, kept on purpose as the baseline.

## Ideas for next

- Destructive audio ops via a pure-Lua WAV writer (export selection as
  a new sample → pad or folder — Edison's "drag region out").
- **CC / automation lanes** (the one big missing MIDI category), a live
  preview→apply→dice loop over the transforms, and keyboard note-navigation.
- Spectral view; warp-marker UI on take stretch markers.
