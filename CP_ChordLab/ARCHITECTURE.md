# CP ChordLab — Architecture & Module Contracts

Chord-grid authoring tool for REAPER: virtual guitar fretboard input, chord
detection on MIDI items, timeline chord editing, and a suggestion engine
(substitutions, modal interchange, negative harmony, passing chords).

This document is the **single source of truth** for module boundaries. Every
module must implement exactly the API described here. If an implementation
needs to deviate, the deviation must be flagged, reviewed, and this document
updated in the same commit.

```
CP_ChordLab/
├── CP_ChordLab.lua        -- entry point / launcher
├── ARCHITECTURE.md        -- this file
├── Modules/
│   ├── Theory.lua         -- PURE: pitch classes, chord dictionary, detection,
│   │                      --       key finding, transformations
│   ├── Voicing.lua        -- PURE: voicings, voice leading, note remapping
│   ├── Fretboard.lua      -- PURE: fretboard model, fingering <-> pitches
│   ├── Suggest.lua        -- PURE: suggestion engine (categories of chords)
│   ├── MidiIO.lua         -- REAPER: item analysis, segment write/replace
│   ├── Preview.lua        -- REAPER: audition via StuffMIDIMessage (strum)
│   ├── App.lua            -- glue: state, selection watcher, frame loop
│   ├── UI_Timeline.lua    -- chord blocks strip (custom draw)
│   ├── UI_Fretboard.lua   -- fretboard canvas (custom draw)
│   └── UI_Suggestions.lua -- suggestion panel
└── Tests/
    ├── run_tests.lua      -- standalone runner (plain lua53.exe, no REAPER)
    ├── test_theory.lua
    ├── test_voicing.lua
    ├── test_fretboard.lua
    └── test_suggest.lua
```

**PURE modules** never reference `reaper.*`, `gfx.*`, or the toolkit — they are
plain Lua 5.3, unit-tested with `C:/Users/Cedric/Tools/lua53/lua53.exe`.

## Module loading pattern (dependency injection)

Every module file ends with `return M`. No globals. Consumers wire
dependencies explicitly:

```lua
local Theory    = dofile(mod_path .. "Theory.lua")
local Voicing   = dofile(mod_path .. "Voicing.lua");   Voicing.Init(Theory)
local Suggest   = dofile(mod_path .. "Suggest.lua");   Suggest.Init(Theory, Voicing)
local Fretboard = dofile(mod_path .. "Fretboard.lua"); Fretboard.Init(Theory)
local MidiIO    = dofile(mod_path .. "MidiIO.lua");    MidiIO.Init(Theory, Voicing)
local Preview   = dofile(mod_path .. "Preview.lua")
```

Tests use the same pattern (no `reaper` global available).

---

## Data model (shared vocabulary)

- **pitch** — integer MIDI note number 0..127 (60 = C4, middle C).
- **pc** — pitch class, integer 0..11, `0 = C`.
- **Chord** — abstract chord, no voicing:
  ```lua
  { root = pc, type = "m7", bass = pc|nil }
  -- bass ~= nil and bass ~= root → slash chord / inversion ("Am7/G")
  ```
- **ChordType** (entry in `Theory.TYPES`):
  ```lua
  { name="m7b5", intervals={0,3,6,10}, label="m7b5", family="seventh",
    rank=n }   -- rank = commonness bonus used by detection scoring
  ```
- **Key** — `{ tonic = pc, mode = "major"|"minor" }`.
- **Segment** (produced by `MidiIO.Analyze`, consumed by UI + replace):
  ```lua
  {
    start_ppq, end_ppq,        -- number (floats)
    start_time, end_time,      -- project seconds
    notes = {                  -- notes whose START lies inside the segment
      { idx=noteidx, ppq, end_ppq, pitch, vel, chan }, ...
    },
    held = { ...same shape... },  -- notes starting before but sounding into it
    pitches = {48,52,55,60},   -- distinct sounding pitches, sorted asc
    weights = { [pc]=w, ... }, -- pc → weight (overlap_qn × vel), detection input
    candidates = {...},        -- Theory.Detect output (ranked)
    chord = Chord|nil,         -- candidates[1].chord, nil if no notes
    empty = bool,              -- true → placement slot (grid gap), no notes
  }
  ```
- All arrays are 1-based dense sequences. Determinism everywhere: same input →
  same output (stable sorts, no `pairs()` iteration order dependency in
  anything that feeds output ordering — iterate sorted keys instead).

---

## Theory.lua (PURE)

```lua
Theory.TYPES            -- ordered array of ChordType (order = display order)
Theory.TYPE_BY_NAME     -- name → ChordType
Theory.MODES            -- { major={0,2,4,5,7,9,11}, minor={...}, dorian=...,
                        --   phrygian, lydian, mixolydian, locrian,
                        --   harmonic_minor, melodic_minor }
Theory.PcName(pc, flats)             -- "C#" or "Db"
Theory.NoteName(pitch, flats)        -- "C#4" (C4 = 60)
Theory.ChordName(chord, flats)       -- "F#m7b5", "Am7/G"; nil-safe → "—"
Theory.ChordPcs(chord)               -- pcs low-intervals-first incl. bass? NO:
                                     --   returns { (root+iv)%12 for iv in type.intervals }
Theory.ChordEquals(a, b)             -- same root, type, bass
Theory.Detect(pitches, opts)         -- → ranked candidates (see below)
Theory.DetectFromWeights(weights, bass_pc, opts)  -- same, pc-weight input
Theory.DetectKey(weights)            -- → { tonic, mode, confidence, ranked }
Theory.Scale(key)                    -- pcs of key.mode at key.tonic
Theory.DiatonicChords(key, sevenths) -- array of {chord, roman="ii7"}
Theory.RomanNumeral(chord, key)      -- "iv7", "bVII", "V7/ii"-style NOT needed;
                                     --   plain degree + quality, "?" if non-diatonic root
Theory.Transpose(chord, semitones)
Theory.TritoneSub(chord)             -- root+6, type forced to "7"
Theory.RelativeOf(chord)             -- maj→ rel minor, min→ rel major (triad/7th preserved)
Theory.ParallelOf(chord)             -- maj↔min quality swap, same root
Theory.SecondaryDominant(target)     -- V7 of target.root
Theory.ChromaticMediants(chord)      -- array of 4 mediants (±M3/±m3, quality preserved)
Theory.NegativeMirror(chord, key)    -- negative harmony reflection (see below)
Theory.MirrorPc(pc, key)             -- (2*key.tonic + 7 - pc) % 12
```

### Chord dictionary (minimum set, extensible)

Triads: `maj {0,4,7}`, `min {0,3,7}`, `dim {0,3,6}`, `aug {0,4,8}`,
`sus2 {0,2,7}`, `sus4 {0,5,7}`, `5 {0,7}` (power chord).
Sixths: `6 {0,4,7,9}`, `m6 {0,3,7,9}`, `69 {0,4,7,9,2}`.
Sevenths: `maj7 {0,4,7,11}`, `7 {0,4,7,10}`, `m7 {0,3,7,10}`,
`mMaj7 {0,3,7,11}`, `dim7 {0,3,6,9}`, `m7b5 {0,3,6,10}`, `aug7 {0,4,8,10}`,
`augMaj7 {0,4,8,11}`, `7sus4 {0,5,7,10}`.
Extensions: `add9 {0,4,7,2}`, `madd9 {0,3,7,2}`, `maj9 {0,4,7,11,2}`,
`9 {0,4,7,10,2}`, `m9 {0,3,7,10,2}`, `11 {0,4,7,10,2,5}`, `m11 {0,3,7,10,2,5}`,
`13 {0,4,7,10,2,9}`, `maj13 {0,4,7,11,2,9}`, `m13 {0,3,7,10,2,9}`.
Altered dominants: `7b9 {0,4,7,10,1}`, `7#9 {0,4,7,10,3}`, `7b5 {0,4,6,10}`,
`7#5 {0,4,8,10}`, `7#11 {0,4,7,10,6}`, `7alt {0,4,8,10,1}`.
Exotic: `quartal {0,5,10}` (label "4ths"), `quartal4 {0,5,10,3}`.

`intervals` listed with root first; store sorted internally as needed.
`rank`: triads and plain sevenths high, altered/exotic low — the detector must
prefer `Cmaj7` over `Em/C`-style readings and `Am7` over `C6/A`.

### Detection contract — `Theory.Detect(pitches, opts)`

Input: array of midi pitches (≥1), `opts = { flats=bool }` optional.
`bass = pc of lowest pitch`. Builds pc set + calls the same core as
`DetectFromWeights` with uniform weights.

Returns ranked array (best first):
```lua
{ chord=Chord, score=number, name="Am7/G",
  matched={pcs}, missing={pcs}, extra={pcs} }
```

Scoring guidelines (implementation may tune, tests pin behavior):
- try every present pc as candidate root × every ChordType;
- reward matched type tones (root and 3rd weigh more than 5th),
  penalize missing tones (missing 5th is cheap — `C7 no5` must still read
  as `C7`), penalize extra pcs harder;
- bonus when bass == root; smaller bonus when bass is a chord tone
  (then `bass` field set → slash name);
- add `type.rank` tiebreaker.
- 1 pitch → name the note (`chord=nil`, name="C4"); 2 pitches → detect `5`
  or return interval name with `chord=nil`.

**Pinned expectations (tests):**
| pitches | best name |
|---|---|
| C4 E4 G4 | `C` |
| E3 C4 E4 G4 | `C/E` |
| C3 Eb3 G3 Bb3 | `Cm7` |
| A2 C3 E3 G3 | `Am7` |
| C3 E3 G3 A3 | `C6` (bass C wins over Am7/C) |
| C3 E3 Bb3 | `C7` (no 5) |
| C3 F3 G3 | `Csus4` |
| C3 Eb3 Gb3 A3 | `Cdim7` |
| B2 D3 F3 A3 | `Bm7b5` |
| C3 E3 G#3 | `Caug` (any inversion → root by bass preference) |
| G2 B2 D3 F3 | `G7` |
| C3 D3 G3 | `Csus2` (bass tiebreak vs Gsus4/C) |

### Key detection — `Theory.DetectKey(weights)`

Krumhansl-Schmuckler: correlate the 12-bin weight histogram against the 24
Krumhansl-Kessler major/minor profiles (embed the standard coefficients).
Return best `{tonic, mode, confidence}` + full `ranked` list. `confidence` =
normalized gap between best and second-best correlation (0..1). Empty/flat
histogram → `{ tonic=0, mode="major", confidence=0 }`.

### Negative harmony — `Theory.NegativeMirror(chord, key)`

Reflect every pc of the chord across the tonic/dominant axis:
`pc' = (2*tonic + 7 - pc) % 12`. Re-detect the mirrored pc set (bass = mirror
of original root) and return the best candidate Chord (fallback: raw pcs with
`chord=nil` never returned — always return the best-scoring Chord).
Pinned: in C major, `C → Cm`, `G7 → Fm6` (accept `Dm7b5/F` only if
dictionary scoring genuinely prefers it — pin whichever the scorer picks and
document it in the test).

---

## Voicing.lua (PURE) — `Voicing.Init(Theory)`

```lua
Voicing.Spell(chord, opts)
-- → sorted midi pitches. opts = { register=48 (lowest note target),
--   inversion=0 (0=root position, 1=first, ...), spread="close"|"open" }
-- "open": drop the 2nd-highest voice one octave (drop-2) when ≥4 tones.
-- Bass note (chord.bass) always placed lowest when set.

Voicing.Inversions(chord, register)
-- → array of { pitches, label } for every rotation of the chord tones.

Voicing.LeadFrom(prev_pitches, chord, opts)
-- Voice-leading: choose the voicing of `chord` (over inversions × octave
-- shifts, same cardinality as chord tones) minimizing total |semitone
-- movement| against prev_pitches (greedy nearest-pair sum is fine, must be
-- deterministic). nil/empty prev → Spell(chord, opts).

Voicing.MapNotes(old_pitches, new_chord)
-- THE rhythm-preserving remap used when swapping a chord under existing MIDI
-- (arpeggios included). Returns map: old_pitch → new_pitch for every distinct
-- old pitch.
-- Algorithm: distinct old pcs → assign each to a pc of new_chord minimizing
-- total circular pc distance (brute-force assignment, ≤7×7); unmatched old
-- pcs (non-chord/passing tones) move by the same delta as their nearest
-- assigned old pc (parallel motion). Each old pitch then moves to the mapped
-- pc at the octave closest to its original pitch (ties: downward).
-- Every distinct new_chord pc should be reachable when cardinalities allow;
-- when old has fewer distinct pcs than the new chord, cover root+third first.
```

Pinned: mapping C-major arpeggio `{C4,E4,G4,C5,E5}` to `Am` yields
`{C4,E4,A4?/A3?...}` — test asserts: result pcs ⊆ {A,C,E}, each old pitch moves
≤ 6 semitones, and the contour (pairwise order) of the arpeggio is preserved
where movement allows (no octave jumps beyond nearest placement).

---

## Fretboard.lua (PURE) — `Fretboard.Init(Theory)`

```lua
Fretboard.TUNINGS   -- ordered array: { {name="Standard", notes={40,45,50,55,59,64}},
                    --   Drop D {38,...}, DADGAD, Open G, Open D, ... }
                    -- notes low string → high string.
Fretboard.New(tuning_index)  -- → state
-- state = { tuning=idx, capo=0, fingers={-1,-1,-1,-1,-1,-1} }
--   fingers[s]: -1 = muted, 0 = open, n≥1 = fret n (absolute, ignores capo;
--   UI clamps fretted values to > capo). String 1 = LOW string.
Fretboard.Pitches(state)     -- sounding pitches sorted asc:
--   fingers[s] == -1 → silent; 0 → tuning+capo; n → tuning+n
Fretboard.SetFinger(state, s, fret)   -- mutate + return state
Fretboard.Clear(state)                -- all -1
Fretboard.FromPitches(state, chord, opts)
-- Reverse solver: fingerings that realize chord's pc set.
-- opts = { max_results=5, max_span=4, min_strings=3, prefer_bass=true }
-- Window scan: for start fret p in 0..12, per string options = {mute, open,
-- frets in [p, p+max_span-1] whose pc ∈ chord pcs} — enumerate, score
-- (all pcs covered ≫ bass correct on lowest sounding string ≫ more strings ≫
-- lower position), dedupe, return top N as fingers arrays.
```

---

## Suggest.lua (PURE) — `Suggest.Init(Theory, Voicing)`

```lua
Suggest.For(ctx)
-- ctx = { chord=Chord|nil, key=Key, prev=Chord|nil, next=Chord|nil }
-- → array of categories, order fixed:
-- { key="diatonic",  title="Diatonique",       items={...} }
-- { key="function",  title="Suite logique",    items }  -- needs chord
-- { key="subs",      title="Substitutions",    items }  -- needs chord
-- { key="borrowed",  title="Emprunts modaux",  items }
-- { key="negative",  title="Harmonie négative",items }  -- needs chord
-- { key="passing",   title="Passage",          items }  -- needs next (approach chords)
-- { key="exotic",    title="Exotique",         items }  -- needs chord
-- item = { chord=Chord, label="Dm7", detail="ii7 — sous-dominante" }
```

Content per category (dedupe against ctx.chord and inside each category;
skip a category → omit it from the array, don't return empty items):
- **diatonic** — 7 sevenths of the key with roman numeral details.
- **function** — data-driven transition table on roman degrees
  (I→{IV,V,vi,ii}, ii→{V,vii°}, iii→{vi,IV}, IV→{V,I,ii}, V→{I,vi},
  vi→{ii,IV,V}, vii°→{I}); mirrored table for minor keys. Non-diatonic
  current chord → nearest diatonic root's row.
- **subs** — tritone sub, relative, parallel, 4 chromatic mediants,
  backdoor dominant (bVII7), Neapolitan (bII maj).
- **borrowed** — same-degree chords from parallel modes (minor↔major,
  dorian, phrygian, lydian, mixolydian, harmonic/melodic minor), only those
  differing from diatonic set.
- **negative** — NegativeMirror of current chord + of the next (if any).
- **passing** — secondary dominant V7/next, ii7/next ("two-five into"),
  dim7 a half-step below next root, chromatic approach (next type, root±1).
- **exotic** — quartal on current root, sus4/sus2 recolor, upper-structure
  triads (maj triad on b6 / on 2 over current bass as slash chords),
  hexatonic pole (maj→ minor at root+4... implement as: `maj` at
  root+4 swapped to `min`, and inverse), `7alt` when current is dominant.

---

## MidiIO.lua (REAPER) — `MidiIO.Init(Theory, Voicing)`

All write operations: single undo block
(`reaper.Undo_BeginBlock()` / `Undo_EndBlock("ChordLab: <desc>", -1)`),
`MIDI_DisableSort` before batch edits, `MIDI_Sort` after,
`reaper.UpdateArrange()` at the end. Never call per frame — event-driven only.

```lua
MidiIO.GetTarget()        -- → take, item | nil,nil  (first selected item w/ active MIDI take)
MidiIO.Hash(take)         -- → MIDI_GetHash(take, true) string ("" on failure)
MidiIO.Analyze(take, opts)
-- opts = { mode="onset"|"grid", onset_ms=80, grid_qn=4.0 }
-- → { segments = {Segment...}, key = Theory.DetectKey(histogram),
--     item_start_time, item_end_time, hash }
-- onset mode: cluster note starts whose project-time gap ≤ onset_ms;
--   segment span = cluster start → next cluster start (last: → last note end).
-- grid mode: boundaries every grid_qn quarter notes anchored on measure
--   starts (TimeMap_GetMeasureInfo / TimeMap2_timeToQN / TimeMap_QNToTime),
--   clipped to item bounds; slices with no sounding notes → empty=true
--   placement slots (also: onset mode emits ONE empty slot from last note end
--   to item end when ≥ 1 QN remains).
-- Detection input per segment: weights[pc] += overlap_qn × (vel/127) over
--   all overlapping notes; bass = pc of lowest sounding pitch;
--   candidates = Theory.DetectFromWeights(weights, bass).
-- Key histogram: same weighting over the whole item.
MidiIO.ReplaceSegment(take, segment, new_chord)
-- Rhythm-preserving: Voicing.MapNotes over segment.notes (NOT held notes),
-- MIDI_SetNote(pitch only, noSort=true) by note idx, then Sort.
-- Undo desc: "ChordLab: <old> → <new>".
MidiIO.WriteChord(take, start_ppq, end_ppq, pitches, vel)
-- Block chord via MIDI_InsertNote (selected=false, muted=false, chan 0).
MidiIO.DeleteSegment(take, segment)   -- delete segment.notes by idx (desc order)
MidiIO.EnsureItem(len_qn)
-- Selected MIDI item? return it. Else CreateNewMIDIItemInProject on selected
-- track (fallback: last touched track) at edit cursor, len_qn long (QN flag).
MidiIO.TimeToPpq(take, t) / MidiIO.PpqToTime(take, ppq)   -- thin wrappers
```

Note idx invalidation: any write invalidates `Segment.notes[].idx` → App must
re-Analyze after every write (cheap, event-driven).

## Preview.lua (REAPER)

Audition through the Virtual MIDI Keyboard queue —
`reaper.StuffMIDIMessage(0, 0x90+chan, pitch, vel)` (routes like the VKB:
plays the track receiving VKB input, typically the selected track).

```lua
Preview.Play(pitches, opts)
-- opts = { strum_ms=18, dur_ms=900, vel=96, chan=0, dir="up" }
-- "up" = low→high pitch order (guitar downstroke sound-wise); schedule
-- note-ons strum_ms apart, note-offs dur_ms after each on.
Preview.Update()    -- call every frame: pops due events (reaper.time_precise())
Preview.StopAll()   -- immediate note-offs for everything active
Preview.IsActive()
```

Internal queue is a small array reused across frames (no per-frame alloc when
idle). Always pair every note-on with a scheduled note-off; StopAll on exit
(`UI.OnClose`).

---

## App.lua + UI modules

### State (single table owned by App)

```lua
state = {
  take, item, hash,           -- current target
  analysis,                   -- MidiIO.Analyze result | nil
  selected_seg = nil,         -- index into analysis.segments
  armed = nil,                -- { chord, pitches, source="fret"|"suggest" }
  key_override = nil,         -- Key | nil (nil → analysis.key)
  fret = Fretboard.New(1),
  suggestions = nil,          -- Suggest.For result for selected/fret context
  cfg = { mode="onset", onset_ms=80, grid_qn=4.0, place_len_qn=4.0,
          strum_ms=18, prev_dur_ms=900, vel=96, tuning=1, capo=0,
          flats=false },
}
```

### Watcher (every frame, cheap; heavy work event-driven)

Every frame: `Preview.Update()`. At most ~4×/sec (time-gated with
`reaper.time_precise()`, keep last-check timestamp): compare selected item
GUID (`BR_GetMediaItemGUID`? NO — use `reaper.ValidatePtr` + compare item
pointer AND `MidiIO.Hash`); on change → re-Analyze + recompute suggestions +
clamp selected_seg. Manual "Refresh" button forces it. Never Analyze in the
draw path itself.

### Layout (window "CP ChordLab", default 980×560, `persist="CP_ChordLab"`)

```
[Top bar]    item name · key combo (Auto (X) + 24 keys) · mode combo ·
             grid res combo (grid mode) / onset window (onset mode) ·
             place-length combo · refresh btn · settings btn (modal)
[Timeline]   full-width strip, horizontal scroll (BeginChild scrollable_x)
[Splitter]
[Main row]   BeginColumns: fretboard (0.62) | suggestions (0.38)
[Status bar] contextual hint line (SetFontCaption)
```

- **Timeline** (`UI_Timeline.lua`): blocks proportional to segment duration
  (px-per-second scale fitting item into available width, min block width =
  `theme.row_h_large`); block = rounded rect, chord name (SetFontH2Bold) +
  roman numeral (SetFontCaption). Selected = accent border/fill
  (`theme.colors.accent` family); empty slots = dashed/dim outline with "+".
  Click block → select; double-click → Preview its actual pitches;
  click empty slot with armed chord → place (LeadFrom previous segment's
  sounding pitches); Del key → DeleteSegment of selection. Playhead: thin
  line at `GetPlayPosition()` when playing (cheap: one line draw).
- **Fretboard** (`UI_Fretboard.lua`): Canvas; 6 strings horizontal (LOW E at
  BOTTOM like a real tab view), frets 0..15 vertical; inlays at 3/5/7/9/12/15
  (double); nut zone left of fret 1 cycles open ↔ mute (shows ○ / ✕); click a
  cell toggles finger dot; string gauge = slightly thicker lines for low
  strings; capo drawn as a bar when > 0. Under the board: detected name big
  (SetFontH1) + top-3 alternate readings as small clickable chips; buttons:
  Écouter · Effacer · Écrire au curseur. Any finger change → arm
  (`state.armed = {source="fret"}`) + auto-preview (config toggle).
- **Suggestions** (`UI_Suggestions.lua`): scrollable child; per category a
  CollapsingHeader (persist open state in cfg) + BeginWrap of chip Buttons.
  Click chip → Preview + arm; double-click → ReplaceSegment on selection.
  Tooltip = detail text. Context: selected segment (prev/next = neighbors) or
  armed fretboard chord when no selection.
- All interactions that write MIDI end with re-Analyze (see watcher) — a
  write bumps the hash, so just invalidate `state.hash` and let the next
  gated check pick it up... NO: re-Analyze synchronously after a write (the
  user must see the result immediately), then store the new hash.

### Entry point `CP_ChordLab.lua`

Follows the CP_Inspector pattern exactly: `@description/@version/@author`
header, resolve `root_path`, `dofile` toolkit + modules, wire `Init(...)`
deps, toolbar toggle state (`SetToggleCommandState` on, off in OnClose),
`UI.Init(... persist="CP_ChordLab")`, `UI.Run(App.Frame)`,
`UI.OnClose(App.Shutdown)` (Preview.StopAll + save cfg via
`UI.SaveConfig("CP_ChordLab", cfg)`; load with `UI.LoadConfig` at startup).

---

## Coding rules (hard requirements)

1. **Lua 5.3**: never `string.format("%d", x)` on a possibly-float `x` —
   use `math.floor(x)` first or `%.0f`. PPQ/time values are ALWAYS floats.
   Use `//` for integer division. `#` only on dense sequences.
2. **Zero hardcoded UI values**: every color from `theme.colors.*`, every
   size/spacing from theme fields; custom pixel values via
   `UI.Theme.S(theme, v)` (scale-aware). Grep-clean: no raw numbers in draw
   calls except 0/1 factors and loop indices.
3. **2005-PC performance**: no disk I/O on hot paths; config saved on close +
   explicit setting changes only (SaveConfig, one file); analysis and
   suggestion computation event-driven, never per frame; reuse tables in
   per-frame code paths (no closures/tables allocated in draw loops where
   avoidable); watcher gated to ~4 Hz.
4. **Undo**: every MIDI mutation wrapped in a single undo block with a
   descriptive "ChordLab: ..." name.
5. Comments in English, concise, explaining constraints not restating code.
   Module headers: `-- @description ...` like existing CP_ modules.
6. IDs: every widget id unique and stable (`"cl_" .. semantic_name`).
7. Pure modules: no `reaper.`, no `gfx.`, no `os.`, no `io.` — enforced by
   tests running under plain lua53.

## Tests

`Tests/run_tests.lua` (already written — do not modify): zero-dependency
runner. Each `test_*.lua` file is loaded as a chunk and called with two
arguments — `local T, M = ...` — where `T` has `assert_true(cond, msg)`,
`assert_eq(got, expected, msg)`, `assert_near(got, expected, eps, msg)`,
`assert_deep_eq(got, expected, msg)`, and `M` has the wired modules
(`M.Theory`, `M.Voicing`, `M.Suggest`, `M.Fretboard`). The file must return
an array of `{ name = "...", fn = function() ... end }`.
Run: `C:/Users/Cedric/Tools/lua53/lua53.exe Tests/run_tests.lua` (any cwd —
paths resolved via `arg[0]`). Exits 1 on any failure.
