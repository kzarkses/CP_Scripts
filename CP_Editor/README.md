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
| click empty cell | insert a note in the cell under the cursor (grid length, current velocity) and drag it |
| drag a note | move (grid snap; **Ctrl = free**) — moves the whole selection if several are selected |
| drag the right edge | resize |
| **right-drag** | **marquee multi-select** (Shift = add to selection) |
| right-click on a note | delete it |
| click a piano key / drum-row header | select the whole row (that pitch) |
| **Ctrl+Shift+Wheel** on a note | **subdivide** the run: ×2 up, ÷2 down (1 → 2 → 4 → 8… fills the same span — trap rolls) |
| velocity lane (bottom) | drag a note's bar (whole selection if multi-selected) |
| Q | quantize (selection, else all) |
| Ctrl+A | select all · Delete | delete the selection |
| arrows | transpose (Up/Down) / nudge (Left/Right) the selection |
| Space | REAPER transport — the item plays in context |
| Native editor | escape hatch: opens the built-in MIDI editor |

**Top ruler strip**: click to move the edit cursor, drag to set a time
selection (both drive REAPER's transport, so Space plays from there).
The left lane is a **piano keyboard** in melodic mode (black/white keys,
C rows labelled) or the **named pad rows** in drum mode — click either
to select the whole row.

The **Grid** button in the toolbar sets the editor's snap division
(1/1…1/64, triplets) or follows the project grid. Snap toggles
independently.

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
Modules/Roll.lua    MIDI note cache (item-relative seconds ↔ PPQ) +
                    edit layer: live no-sort writes during drags, one
                    sorted Commit + undo point at release
```

Rendering: the waveform / roll grid renders into an offscreen buffer
only when the view changes; a steady frame is one blit plus overlays.
Known limit: looped MIDI items edit their first iteration (source
notes), like the arrange inline editor.

## Ideas for next

- Destructive audio ops via a pure-Lua WAV writer (export selection as
  a new sample → pad or folder — Edison's "drag region out").
- Marquee multi-select + batch move in the roll; CC lanes.
- Spectral view; warp-marker UI on take stretch markers.
