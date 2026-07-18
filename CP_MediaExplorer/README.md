# CP Media Explorer

FL Studio-style media/sample browser for REAPER, built on CP_Toolkit.
One inline expanding tree, zero-latency audition, keyboard-first.

Run `CP_MediaExplorer.lua` as a ReaScript action. Requires **SWS**
(CF_Preview) for audition; **js_ReaScriptAPI** recommended (folder picker,
drag-to-arrange hit-testing).

Four views (chips): folder tree · favorites · recents · **plugins** —
plus the colored collections. One list, one search box, one keyboard
grammar for all of them.

## Design pillars

- **Sound first, decorate later** — the preview starts in the same defer
  tick as the triggering key/click, before any metadata or peaks work.
  Target select→sound < 50 ms.
- **FL inline tree** — folders unfold in place, the whole library is one
  scrollable virtualized list (`UI.ListClipper`, O(visible) rows).
- **Interaction quality over feature count** — the native Media Explorer
  loses on focus stealing, preview/insert gain mismatch and DB latency;
  this browser fixes exactly those (Space stays on the transport by
  default, preview volume optionally carries to the inserted item).
- **Augment, don't replace** — OS-level drag into plugin windows is
  impossible from ReaScript; for those workflows keep the native ME.

## Keyboard

| Key | Action |
|---|---|
| Up / Down | move selection **and** audition (autoplay) |
| Right | expand folder / replay file |
| Left | collapse folder / jump to parent |
| Enter | insert at edit cursor (selected track) |
| Double-click | insert at edit cursor |
| Drag to arrange | insert at mouse position (snap-aware) |
| Space | REAPER transport play/stop (option: preview toggle) |
| Ctrl+Up / Ctrl+Down | folder skim: next/prev folder, play its first file |
| F | toggle favorite |
| 1-7 | toggle colored collection (0 = clear) — dots on the row, chips to filter |
| Q | hot-swap **mode**: while on, selecting a file replaces the selected arrange item's source (one undo point per swap — Ctrl+Z reverts); Q/Esc exits. Right-click a row → "Hot-swap into selected item" for a one-shot. With the transport stopped the selection is still auditioned through the preview engine. |
| R | random file: jump + audition. Scope = the selection's folder (tree view) or the current filtered view. In hot-swap mode: random swap (sound-design roulette). Also: dice toolbar button, right-click a folder → "Random from this folder". |
| Shift+R | random + insert at edit cursor |
| Middle-drag | pan the list (hand-tool style, toolkit-wide) |
| Ctrl+F | focus search |
| Ctrl+R | rescan folder of the selection |
| Esc | clear search → close window (layered) |
| Backspace | jump to parent |

Search grammar: space-separated AND tokens over the path below each root,
`-token` excludes — `kick 808 -loop`. The first search also streams in the
native Media Explorer databases (`MediaDB/*.ReaperFileList`), so results
cover everything REAPER has already indexed — no waiting for a fresh scan
(toggle in settings).

The tree pins the **full ancestor stack** of the topmost visible row
(sticky headers, one per level — something no DAW browser does); clicking a
level jumps to that folder. The list renders through the toolkit's buffered
clip region, so rows slide seamlessly behind the container edges.

## Architecture

```
CP_MediaExplorer.lua      UI: tree list, sticky folder header, preview bar,
                          keyboard grammar, drag, hot-swap session, config
Modules/Model.lua         FS tree: lazy enumeration, flattened rows,
                          background indexer (budgeted defer slices),
                          token search, favorites/recents views
Modules/Preview.lua       CF_Preview engine: PCM_source LRU + prefetch,
                          volume/pitch/rate/loop, tempo-sync rate,
                          progress via D_LENGTH
Modules/Insert.lua        manual AddMediaItemToTrack insert (no cursor or
                          selection side effects), arrange hit-testing for
                          drag drops, hot-swap take-source swapping
Modules/Peaks.lua         PCM_Source_GetPeaks reader (two-block buffer),
                          async BuildPeaks 0/1/2 state machine, small LRU
```

Rules inherited from `CP_Toolkit/PERFORMANCE.md`: no per-frame allocations
in the row loop (labels/ellipsis cached per node), directory enumeration
only on expand or inside `Model.IndexStep(budget)`, waveform only for the
selected file (never per-row thumbnails).

State is persisted to `CP_Config/CP_MediaExplorer.lua` (roots, favorites,
recents, expanded folders, preview settings, options).

## Known limits (by design)

- No OS drag out of the window (ReaScript cannot start an OLE drag):
  drops target the REAPER arrange only.
- No MIDI/video preview (CF_Preview is audio-only); MIDI files insert fine.
- BPM for tempo-sync comes from the filename (`…120bpm…`) or REAPER's
  power-of-2-bars guess (`GetTempoMatchPlayRate`) — no audio BPM detection.

Tempo-match (clock toggle in the preview bar) uses REAPER's own
`GetTempoMatchPlayRate` — the native ME math — with the ×0.5/×1/×2
multiplier (right-click the toggle or use the settings menu). When on, the
matched rate applies to the preview **and** to inserted items.

## Shipped in V6

- **CP DragBus**: dragging a row (or the waveform-strip section) over a
  CP_Sampler window highlights the pad under the mouse and dropping loads
  the sample there — the arrange ghost yields to CP targets. Section
  drops send the whole file (the bus carries paths).
- Right-click a file → **Open in Sample Editor** (CP_SampleEditor).

## Shipped in V5

- **FX chip** (FL "Plugin database"): the fourth chip lists every installed
  plugin (native `EnumInstalledFX` — no ini parsing), grouped Effects /
  Instruments → type → name. Same interactions as files: Enter/double-click
  adds to the selected track (floats the FX window), **drag onto any track
  or the TCP adds it there**, dropping on empty arrange space creates a
  named track with the FX, F = favorite, 1-7 = collections, R = random
  plugin. The search box filters plugins (type + vendor + name tokens)
  while the chip is active. No audio preview (nothing to preview).
- **Audition on release**: clicking a row no longer starts the sound on
  mouse-down — a click auditions when the button releases, a drag stays
  silent from the first pixel (no more cut-off parasite blips).
- Drops in the **empty arrange area below the last track** now work exactly
  like the native ME (GetThingFromPoint reports nothing there; the arrange
  window rect is the fallback).

## Shipped in V4

- **Native-feel drag**: while a drag hovers the arrange, a REAL item exists
  in the project — it occupies space, shows its waveform, moves with the
  mouse (snap-aware), and hovering below the last track creates the track
  live. Dropping commits ONE undo point (item + track); releasing elsewhere
  or leaving the arrange removes everything. The OS tooltip ghost only
  shows outside the arrange.
- **Drag the section**: press inside the waveform-strip selection and pull —
  the section drags to the arrange like a row does (start offset + length
  applied). Pressing outside still redefines the selection.
- **Random** (R / Shift+R / dice button / folder menu) — see the key table.
- Inserted items build their peaks immediately (no more blank waveforms
  until you zoom into sample range).
- The list scroll position is remembered across sessions (along with the
  expanded folders); the window remembers its dock state and docker.
- Settings → "Hot-swap resizes item to new length": the swapped item takes
  the new source's length instead of keeping the old one (which loops a
  shorter source).
- Toolkit: wheel scrolling is notch-proportional (fast spins cover real
  distance) with a bigger default step; middle-click drag pans any
  scrollable region; icons are supersample-baked (real AA) with optional
  PNG overrides (`CP_Toolkit/IconOverrides/`).

## Shipped in V3

- **Samples view** (settings → "Waveform rows"): FL-style taller rows with
  the file's waveform behind the label — thumbnails render lazily (one per
  frame, visible rows only) into a slot atlas, LRU-evicted.
- **Section selection** in the waveform strip: drag = select a portion
  (right-click clears). The preview plays/loops the section; Enter,
  double-click and drag-to-arrange insert ONLY that portion (start offset +
  length on the take — stays fully editable).
- Hot-swap now refreshes the arrange item's waveform (peaks build + position
  nudge) and the selection highlight uses the `list_selected` theme token
  (Theme Tweaker-controlled) instead of `accent_dim`.

## Shipped in V2

- Native MediaDB bootstrap (search covers the whole ME-indexed library).
- Colored collections, keys 1-7 (0 clears), membership dots + filter chips.
- Sticky ancestor stack (full parent chain pinned).
- Pixel-true list clipping via the new toolkit `UI.BeginBufferedClip`.
- Offscreen-buffered waveform strip (render once, blit per frame).

## Ideas for V3

- Insert guides drawn over the arrange during drags (frameless overlay).
- Type-ahead jump in the list; multi-select insert.
- Waveform strip: drag a selection → insert only that section
  (`InsertMediaSection`).
- BPM/key columns parsed from MediaDB DATA tags; tempo-sync using DB bpm.
