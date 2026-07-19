# CP Sampler

Ableton Drum Rack-style pad grid for REAPER, built on CP_Toolkit.
4x4 pads × 4 pages (64 slots), each pad = a child track of a **CP Kit**
folder hosting a hidden ReaSamplOmatic5000. RS5K is the audio engine —
its window is never shown; this grid is the interface.

Run `CP_Sampler.lua` as a ReaScript action. Requires **SWS** (direct
preview); **js_ReaScriptAPI** recommended (cross-window drops from
CP_MediaExplorer, file dialogs).

## Why track-per-pad

The mpl RS5K-manager / Drum Rack architecture: every pad automatically
gets its own FX chain, sends, meter and mixer strip, and the whole kit is
saved **inside the project** (undo included — pads are just tracks).
The kit is identified by track P_EXT state, so it survives reload,
renaming and reordering.

MIDI flow: a dedicated **"CP Kit MIDI" child track** is the input bus —
armed + monitoring all MIDI inputs (including the virtual keyboard,
which is how pad clicks trigger), it runs the generated choke JSFX and
fans MIDI out to the pads through MIDI-only sends; each pad's RS5K note
range does the filtering. Notes: **36-99** (pad 1 of page 1 = 36).

Why a separate bus and not the folder itself: a send from the folder
parent to its own child, whose audio returns through the folder, is a
feedback loop — REAPER silently **mutes** such sends (this is why mpl's
RS5K manager has a "MIDI bus" track too). Recording lands your pad
performance as a MIDI item on the bus track; its playback drives the
kit the same way. Older CP kits are migrated automatically on first
scan (choke moved to the bus, dead sends removed, pads disarmed).

## Two modes (Drum / Instrument)

The **Drum / Instr** toggle in the toolbar switches the whole rack, like
Ableton's Simpler/Sampler split:

- **Drum** — the 4x4 pad grid below (one sound per pad, fixed pitch).
- **Instrument** — **one** sample spread chromatically across the whole
  keyboard, pitched per semitone from a **root note** (RS5K's "Note
  (Semitone shifted)" mode). Big waveform with a draggable region, the
  usual Vol/Pan/Tune/ADSR knobs, a **Root** control, and a mini piano
  keyboard you can click to play (Ctrl+click a key = set the root). Play
  it melodically with any MIDI keyboard through the armed kit bus. Drop a
  sample (from CP_MediaExplorer, Windows, or the editor's **To
  instrument** button) and it loads straight in.

The editor loop: edit/trim a sample in **CP_Editor**, then **To
instrument** sends it here as a playable chromatic instrument (the
selection becomes the region) — sample-design → instrument in two clicks.

## Using it

- **Create kit bus** (toolbar) once per project — or just drop a sample
  anywhere: pads create their tracks on demand.
- **Load samples**: drag from CP_MediaExplorer onto a pad (cross-window),
  drop files from Windows Explorer, double-click an empty pad to browse
  (multi-select fills the following pads), or right-click → Load sample.
- **Trigger**: click a pad (velocity in settings). With the kit bus armed
  the click goes through the real engine (choke, FX chain, meters glow);
  disarmed it falls back to a direct file preview. MIDI keyboards just
  play — the bus listens to all inputs.
- **Swap pads**: drag a pad onto another (FX chains travel with their
  pad — it's the note assignment that swaps, plus the choke groups).
- **Choke groups** (right-click → Choke group, badge on the pad): a pad
  cuts every other pad of its group — hi-hat behavior. Implemented by a
  tiny generated JSFX on the kit bus (`Effects/CP_Scripts/
  cp_kit_choke.jsfx`); members stay one-shots (their own note-offs are
  swallowed), the cut uses the RS5K release for a click-free fade.
- **Pad controls** (below the grid): volume, pan, tune (semitones),
  ADSR, choke, loop, and the **Region** waveform strip = the pad's
  waveform with the RS5K start/end offsets as a draggable region (edges
  resize, middle translates) — a pad plays any slice of its file without
  writing slice files. Pads default to 4 voices so rapid hits overlap
  naturally; double-click only acts on empty pads (browse) — on a loaded
  pad every click is a hit, FL-style.
- **Sample Editor**: double-click a filled pad (or right-click → Open in
  Sample Editor) sends the file to CP_SampleEditor; its "Slices to pads"
  fills consecutive pads from one sliced file.
- **Kit presets** (toolbar save/load): paths + params + choke groups to
  `CP_Config/Kits/<name>.lua`. Loading replaces the current kit's samples
  (tracks and their FX chains stay).

## Keyboard

| Key | Action |
|---|---|
| Arrows | move pad selection (crosses pages) |
| Enter / Space | trigger the selected pad |
| Delete | clear the selected pad (keeps the track) |
| 1-4 | switch page |
| PageUp / PageDown | next / previous page |

## Escape hatches

Everything is standard REAPER underneath: right-click → **Show RS5K UI**
floats the real plugin, the pad tracks are normal tracks (add FX, sends,
record the kit bus performance as a MIDI item and it plays the pads).
Deleting the kit folder track deletes the kit — it's just tracks.

## Architecture

```
CP_Sampler.lua       UI: grid, controls, audition, drops, presets menu
Modules/Kit.lua      engine (no UI): kit/pad tracks (P_EXT-tagged), RS5K
                     driving (FILE0/DONE + param indices verified against
                     mpl RS5K manager), choke JSFX generation, presets.
                     Also dofile'd by CP_SampleEditor for slice-to-pads.
CP_Toolkit/Audio.lua shared CF_Preview audition (section playback)
CP_Toolkit/DragBus.lua cross-script drag & drop (ExtState protocol)
```

Performance: zero allocations in the frame loop (labels via the
toolkit's memoized TruncateText, pooled option tables, formatted param
strings cached until the param moves); pad glow polls `Track_GetPeakInfo`
for the visible page only; project changes are detected with one
`GetProjectStateChangeCount` call per frame.
