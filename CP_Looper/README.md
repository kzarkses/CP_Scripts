# CP Looper

A live **MIDI looper** for REAPER, built on CP_Toolkit — session-view style,
made for jamming while slaved to an external clock.

Run `CP_Looper.lua` as a ReaScript action. No extra extension required (SWS /
js_ReaScriptAPI optional). The real-time engine is a hidden JSFX
(`CP_JSFX/CP_MidiLooper.jsfx`, auto-installed to your Effects folder on first
run); this window is the interface.

## Why a JSFX engine

A ReaScript has no audio thread, so it cannot record or replay MIDI with
sample accuracy. A JSFX can. The trick that makes this a *sync* tool: the JSFX
loops each lane against the host **beat grid** (`beat_position`), and when
REAPER is slaved to an external MIDI clock that grid follows the master — so
your loops stay locked to a friend's Ableton for free, with the arrangement
playing the whole time (as it must, when you're a slave).

The UI (this window) and the engine talk over a shared `gmem` block
(`CP_MidiLooper`) — the same pattern as CP_ClipLauncher's audio engine.

## Setup (once per session)

1. *(Optional)* Select the instrument track you want as the default sound.
2. Click **Create looper engine**.

This creates a dedicated **router track** ("CP Looper") that holds the engine
and is armed for **MIDI input monitoring**. It has no instrument of its own — it
routes each lane out to a per-lane destination track (see below). If a track was
selected, every lane starts routed to it, so you're up and running immediately.

Play with REAPER's own **virtual MIDI keyboard** (or any MIDI device). Hardware
MIDI reaches the router because it's armed; for the **virtual keyboard**, select
the "CP Looper" track first (that's why the router stays visible in the track
panel — it's hidden from the mixer to keep things tidy).

> The tag lives on the router (`P_EXT:CP_LOOPER = "router"`), so reopening the
> window reconnects to it. **Reload** reinstalls the engine from disk — use it
> after updating the `.jsfx`. It keeps your loops.

## Per-lane routing (FL / Ableton style)

Each lane can drive **its own instrument on its own track**. Every lane plays on
its own MIDI channel; a channel-filtered MIDI send carries it from the router to
the chosen destination track.

- **→ track** button (on each lane and in the editor header) — pick the
  destination: any project track, **No track** (silent), or **+ New instrument
  track** (creates one, selects it so you can drop your synth on it).
- **Sound → sel** (toolbar) — route *all* lanes to the currently selected track
  (quick way to put everything on one synth).
- Routing is stored on the router (`P_EXT`) and survives reopening the project.
  A routed destination is auto-disarmed so live input only reaches it through the
  router (no double-trigger).

### Armed lane (what you hear while playing)

The **Lane N** label doubles as an arm control: click it (or hit REC, or open a
lane's editor) to **arm** that lane. Live input is monitored on the armed lane's
channel, so you hear *that lane's* instrument as you play. The armed lane shows a
**● IN** marker.

## Lanes

Four independent lanes. Each:

- **REC** — clears the lane and captures. Click again while it's recording to
  finish the take — the clip locks and **starts playing** (loops on the grid).
  Held notes get a clean note-off at the loop point.
- **Play / Stop** — launch a stopped clip or halt a playing one (Ableton-style
  clip launch). A freshly recorded clip auto-plays.
- **Clear** — empties the lane (and sends note-offs, so nothing hangs).
- **Mute** — silences the lane's playback (its held notes are released).
- **Length** — cycles the loop length in bars (1 / 2 / 4 / 8). Lanes of
  different lengths realign automatically (a 1-bar and a 2-bar loop meet every
  2 bars), exactly like Ableton clips.
- **Mini piano-roll** — the captured notes, with a playhead sweeping in sync.

By default every lane is routed to the same instrument, so you can layer phrases
live; route lanes to different tracks (above) for a multi-instrument setup. Each
lane plays on its own MIDI channel, so lanes sharing one instrument never cut
each other's overlapping pitches (that instrument should be omni — Vital is by
default).

## Editing notes

**Click a lane's mini-roll** to open it in a full piano-roll editor — the same
editing engine (`Roll`) *and the same shared command layer* (`RollUI`) that power
CP_Editor, so the editing feels **identical** in both. You can also draw a clip
from scratch on an empty lane.

- **Click empty** — add a note; **keep dragging right to set its length** (a plain
  click keeps one grid step).
- **Drag a note** — move it (pitch + time), the whole selection if several are
  selected. **Drag its right edge** — resize (whole selection together).
- **Shift+click** — add to the selection. **Right-drag** — marquee select.
  **Right-click a note** — delete it.
- **Velocity lane** (below the grid) — drag a note's stalk to set its velocity.
- **Keyboard** (same map as CP_Editor): Ctrl+A select all · Delete · Q quantize ·
  Ctrl+D duplicate · Ctrl+C/X/V copy/cut/paste · arrows transpose/nudge
  (Shift = octave, Ctrl = in-scale) · Esc deselect / leave.
- **Vel** button sets the default velocity for new notes; **Transform** opens the
  full command menu (transpose, legato, reverse, invert, velocity ramp/compress,
  humanize, quantize %/swing, **scale** highlight + snap, chord, **arpeggiate**,
  euclidean). **Grid / Length / Play / Stop** and the lane's **→ track** are in
  the header; **‹ Lanes** returns to the overview.

Edits are **live**: while a clip is playing, any change is heard on the next loop
with no stuck notes (the engine reconciles what's sounding against the note list
every block). Drawing the first note into an empty lane makes it a launchable
clip. *(No in-editor undo yet — the loop lives in gmem, outside REAPER's undo.)*

## Clock: Free vs Follow

The toolbar **Clock** toggle decides what drives the loops:

- **Free** (default) — an internal clock running at the project tempo. Clips
  launch and play **with the transport stopped**, session-view style. Use this
  for solo jamming.
- **Follow** — the loops track REAPER's transport position (`beat_position`),
  which locks to an **external MIDI clock** when you're slaved. Use this when
  jamming synced to someone else's DAW: play the arrangement and everything
  stays locked to their downbeat.

## Notes

- **Loops are saved with the project.** They are mirrored into the router
  track's `P_EXT` state, so they live inside the `.rpp` like any other track
  data — no side-car file, and they travel with the track if you copy it.
  Saved: every lane's **notes**, its **bar length**, **mute** and **playing
  state**, plus the **clock mode** and the **armed lane**. Routing already was.
  Reopen the project and you get the set back as you left it, playing lanes
  included.
  Saving is automatic (0.4 s after the last edit, and on close); recall is
  automatic when the engine comes up empty — every fresh REAPER session — and
  also when you switch project inside one session. **Recall** (toolbar) forces
  it back over lanes that already hold notes; the automatic one never
  overwrites what is playing.
- **Listen** (toolbar) is the MIDI off switch. The router is armed on all MIDI
  inputs and fans your playing to each lane's instrument through sends — and a
  send ignores the destination's arm state, which is why lane tracks sound even
  when they are not armed. Turn Listen off and your keyboard is free for
  whatever track you armed yourself.
- **REC with the clock stopped arms the lane** (status `ARM`) instead of wiping
  it: capture starts by itself on the first running block. Click ARM to cancel.
  A take interrupted by a transport stop is **kept**, not dropped — it is
  finalized at the phase it reached.
- Their real lifetime is **the REAPER session**, not the plugin. They live in the
  shared gmem block, so they survive an engine reset — and REAPER resets a JSFX
  more often than it looks (transport start, samplerate change, FX reload). That
  reset used to wipe every lane; it no longer does, and the window says "Engine
  reset — loops kept" when one happens. Consequences worth knowing:
  **Clear all** (toolbar, confirmed) is now the only way to lose everything, and
  loops carry over if you open another project in the same REAPER session.
- **Panic** (toolbar) sends all-notes-off if anything hangs.
- V1 records a **fresh take** per lane (no overdub layering yet). Overdub is V2.
- This does **not** add a computer-keyboard note input — REAPER's native
  virtual keyboard already covers playing notes.

## Architecture

```
CP_Looper.lua           UI: toolbar, 4 lane strips (+ routing), piano-roll,
                        playhead, arm control, track picker
Modules/Loop.lua        engine bridge: gmem protocol, router track + engine,
                        per-lane MIDI-send routing, commands, state readers
CP_JSFX/CP_MidiLooper.jsfx  real-time engine: capture + phase-locked replay,
                        live thru re-channeled to the armed lane, clean
                        note-offs. Each lane on its own channel. gmem=CP_MidiLooper.
```

Routing model: the router track outputs each lane on MIDI channel `lane+1`; a
per-lane track send (audio off, source-channel filter `lane+1`) carries it to the
lane's destination track. Live input is re-channeled by the JSFX onto the armed
lane's channel so the right destination sounds while you play.

Performance: the frame loop allocates nothing — event/note-bar caches are
preallocated per lane and rebuilt only when a lane's content or length changes
(tracked by a version counter the JSFX bumps). Loop playback and grid sync run
on the audio thread; the UI only reads published state.
