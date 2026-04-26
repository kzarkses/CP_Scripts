# CP Studio — Master Roadmap

> **Dernière mise à jour** : 2026-02-28
> **Sous-roadmaps** : [MetaMixer](Meta%20Mixer/ROADMAP_MetaMixer.md) · [Item Editor](Meta%20Mixer/ROADMAP_ItemEditor.md)

---

## Vision

CP Studio est un **hub central** docké en bas de REAPER, inspiré de la Session View d'Ableton mais exploitant le paradigme unique de **profondeur** (projets imbriqués via subprojects). Il unifie tous les outils CP_Scripts dans une interface unique à onglets.

**Paradigme** : Là où Ableton pense en **grille** (clips × tracks) et REAPER pense en **timeline** (linéaire), CP Studio pense en **profondeur** — chaque "bloc" est une porte vers un projet entier.

---

## Architecture globale

```
┌══════════════════════════════════════════════════════════════════════════════┐
║ CP STUDIO  [Mixer] [Session] [FX Control] [Clip Editor]      [Settings]   ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                            ║
║  MIXER : Masters (tous projets) + Tracks (projet actif)                   ║
║  ITEM EDITOR : Waveform source complet, trim, fades, grid, stretch, etc.  ║
║                                                                            ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

### Composants (onglets planifiés)

| Onglet | Description | Sous-roadmap | Status |
|--------|-------------|-------------|--------|
| **Mixer** | Cross-project mixer horizontal, knobs, VU, FX, sends, transport | [ROADMAP_MetaMixer.md](Meta%20Mixer/ROADMAP_MetaMixer.md) | V0.5 ✅ |
| **Item Editor** | Éditeur d'item Ableton-style intégré au mixer | [ROADMAP_ItemEditor.md](Meta%20Mixer/ROADMAP_ItemEditor.md) | V0.4 complet ✅ |
| **Session View** | Grille items × tracks, subproject navigation | [SessionView.lua](Meta%20Mixer/Modules/SessionView.lua) | V0.7 ✅ |
| **FX Control** | XY pad global, param scanning, figures animées | [FXControl.lua](Meta%20Mixer/Modules/FXControl.lua) | V0.6 ✅ |
| **Clip Editor** | Take FX control, auto-subproject, glue, export | Intégré dans ItemEditor.lua | V0.8 ✅ |

### Structure de fichiers (actuelle)

```
Meta Mixer/
├── CP_MetaMixer.lua                 # Entry point (v1.0)
├── Modules/
│   ├── Constants.lua                # Couleurs, dimensions, params spectraux
│   ├── Helpers.lua                  # Conversions dB/vol/pan, formatting
│   ├── State.lua                    # État global, scan projets, détection item, sends
│   ├── Widgets.lua                  # DrawKnob, DrawVMeter, DrawHMeter
│   ├── MixerStrip.lua              # Strip unifié masters + tracks + sends
│   ├── Waveform.lua                # Rendu waveform spectral (stereo, gain-aware)
│   ├── BarGrid.lua                  # Grille bar/beat configurable + snap
│   ├── PitchStretch.lua             # Algorithmes pitch/stretch + reverse/loop
│   ├── ItemEditor.lua               # Panel éditeur d'item complet (7 phases)
│   ├── FXControl.lua                # XY pad FX controller + figures
│   └── SessionView.lua             # Session grid: items × tracks, subproject nav
├── ROADMAP_MetaMixer.md             # Sous-roadmap mixer
└── ROADMAP_ItemEditor.md            # Sous-roadmap item editor (7 phases)
```

---

## Briques existantes réutilisables

| Brique | Source | Réutilisation prévue |
|--------|--------|---------------------|
| Style loader | `Various/CP_ImGuiStyleLoader.lua` | Thème UI unifié (déjà intégré) |
| FX Database | `FX Constellation/Modules/FXDatabase.lua` | FX Control tab — scan plugins, catégories |
| FX Browser UI | `FX Constellation/Modules/FXManagerUI.lua` | FX Control tab — layout, drag-drop |
| FX Insertion | `FX Constellation/Modules/FXManager.lua` | Insertion FX cross-projet |
| Gesture/XY | `FX Constellation/Modules/GestureSystem.lua` | FX Control tab — XY pad, figures |
| Clip Engine | `CP_JSFX/CP_ClipEngine.jsfx` | Session View — playback audio via gmem |
| Clip Manager | `Clip Launcher/Modules/ClipManager.lua` | Session View — I/O audio, WAV export |
| Transport sync | `Clip Launcher/Modules/Transport.lua` | Session View — beat/tempo tracking |
| License | `Various/CP_LicenseManager.lua` | Licensing du CP Studio payant |

### API REAPER cross-projet (confirmé fonctionnel)

```lua
r.EnumProjects(idx)                           -- Énumère tous les tabs
r.GetMasterTrack(proj)                        -- Master d'un projet spécifique
r.GetTrack(proj, idx)                         -- Track d'un projet spécifique
r.Track_GetPeakInfo(track, chan)               -- VU meters cross-projet
r.GetPlayStateEx(proj) / OnPlayButtonEx(proj) -- Transport par projet
r.TrackFX_*                                   -- FX cross-projet
r.SelectProjectInstance(proj)                 -- Switch de tab
r.GetSelectedMediaItem(proj, idx)             -- Items sélectionnés
r.GetMediaItemTake_Peaks(take, ...)           -- Peaks waveform
r.GetMediaSourceLength(source)                -- Durée source audio complète
r.TimeMap2_timeToBeats / beatsToTime          -- Grille bar/beat
r.SetTakeStretchMarker(take, idx, pos)        -- Stretch markers
```

---

## Roadmap par versions

### V0.1 — Proto Meta Mixer ✅ FAIT
- [x] Enumération des projets ouverts
- [x] Mixer strips verticaux par projet (master)
- [x] Volume fader, pan, mute, VU meters
- [x] Transport par projet (play/stop/pause)
- [x] Expand tracks individuelles
- [x] Style loader intégré

### V0.2 — Mixer adaptatif horizontal ✅ FAIT
- [x] Refonte layout horizontal (docké en bas)
- [x] Masters compacts côte à côte (knobs au lieu de faders)
- [x] Custom knob widgets (DrawKnob avec drag + double-click reset)
- [x] Auto-expand du projet actif
- [x] Clic sur master = switch tab + expand
- [x] Tracks du projet actif en horizontal (vol knob, VU, M/S)
- [x] FX chain display par track (cliquable, bypass toggle)

### V0.3 — Item Editor basique + Modularisation ✅ FAIT
- [x] Modularisation complète en 9 modules (dofile + init DI)
- [x] Détection item sélectionné, info enrichie (source, subproj, stretch markers)
- [x] Waveform spectrale (coloration fréquentielle, stéréo, gain-aware)
- [x] Grille bar/beat (bars + subdivisions + numéros de mesure)
- [x] Panneau pitch/stretch (12 algorithmes, formants, stretch markers)
- [x] Playback cursor sur waveform
- [x] Interactions : click=edit cursor, Shift+click=add SM, Ctrl+click=split
- [x] Split@Bars, Dive subproject, Stereo/Mono toggle

### V0.4 — Item Editor complet ✅ FAIT
> Voir [ROADMAP_ItemEditor.md](Meta%20Mixer/ROADMAP_ItemEditor.md) pour les 7 phases détaillées

- [x] **Phase 1** : Source complet visible + Zoom/Scroll
- [x] **Phase 2** : Trim edges + Fades interactifs
- [x] **Phase 3** : Grid configurable + Snap to grid
- [x] **Phase 4** : Stretch markers interactifs (drag, snap, delete)
- [x] **Phase 5** : Sélection de région + Cut/Crop/Delete
- [x] **Phase 6** : Reverse + Loop + Warp toggle
- [x] **Phase 7** : Context menu + Raccourcis clavier + Polish

### V0.5 — Tab system + Persistence ✅ FAIT
- [x] Tab bar interne (Mixer / Session / FX Control) avec ImGui_BeginTabBar
- [x] Persistence des settings via ExtState (active_tab, stereo_mode)
- [x] Affichage sends par track (cliquable pour mute/unmute)
- [x] Keyboard shortcuts globaux (Space=play, Home=stop, Ctrl+Tab=switch tab)

### V0.6 — Meta FX Controller ✅ FAIT
- [x] XY Pad (200px, custom draw, grid, crosshair, drag interaction)
- [x] FX parameter scanning (auto-scan selected track's FX chain)
- [x] Assignment params aux axes X/Y (checkboxes, range slider per param)
- [x] Figures animées (Circle, Square, Triangle, Lissajous) avec vitesse réglable
- [x] Quick assign buttons (All X, All Y, None) par FX
- [x] Collapsible FX tree dans la liste de paramètres
- [x] Reset pad, Rescan FX, base value capture

### V0.7 — Session View ✅ FAIT
- [x] Grille items × tracks (timeline view, items as colored blocks)
- [x] Détection subprojects dans le projet parent (RPP_PROJECT source type)
- [x] Dive subproject (double-clic → switch tab via SelectProjectInstance)
- [x] Time ruler avec bar markers + playback cursor
- [x] Click to select item in REAPER
- [x] Zoom slider + scroll (mouse wheel, Ctrl+Wheel)
- [x] Project tab quick-switch buttons
- [x] Track/item color display + tooltips
- [x] Show/hide empty tracks toggle

### V0.8 — Clip Editor avancé ✅ FAIT
- [x] Take FX control intégré (display, bypass/enable, open FX window, bypass/enable all)
- [x] Auto-subproject : créer un subproject depuis un item (action 41997)
- [x] Glue item (bounce in-place avec FX, action 40362)
- [x] Apply FX as new take (non-destructive, action 40209)
- [x] Export/render item to new audio file (action 41823)

### V1.0 — CP Studio unifié ✅ FAIT
- [x] Polish UI : status bar (projet, playback, tracks), version display
- [x] Undo integration complète (toutes les opérations Item Editor, FX, session)
- [x] Performance optimization (lazy item detection — skip quand pas sur Mixer tab)
- [x] License integration (free: Mixer, paid: Session + FX Control, activation UI inline)
- [x] Tab labels indiquent features payantes (*) quand non licensé

---

## Notes de design

### Layout (docking bas, hauteur limitée)
- Knobs (ImGui custom draw) au lieu de faders verticaux
- VU meters compacts (mini-barres verticales 60px)
- Texte compact, tooltips pour les détails
- Sections collapsibles

### Performance
- Polling throttlé (~30fps rendu, ~10fps scan data)
- Lazy scanning : ne scan les FX/items que du projet actif + masters
- Cache des données cross-projet (refresh sur changement de tab)
- ImGui culling : ne rend que les strips visibles
- Waveform peak cache (invalidé sur changement vol/rate/item)

### Ce qui fait la force vs Ableton
- Chaque "clip" peut être un projet REAPER complet (profondeur infinie)
- L'arrangeur REAPER reste intact et complémentaire
- FX Constellation ajoute le contrôle gestuel que même Ableton n'a pas
- Multi-projet simultané = performance live multi-timeline unique

---

## Version History

| Version | Date | Changements |
|---------|------|------------|
| 1.0 | 2026-02-28 | CP Studio unifié: status bar, license integration, performance optimization, polish |
| 0.8 | 2026-02-28 | Clip Editor avancé: Take FX control, auto-subproject, glue, apply FX, export |
| 0.7 | 2026-02-28 | Session View: item grid, subproject detection/dive, time ruler, zoom/scroll, project tabs |
| 0.6 | 2026-02-28 | Meta FX Controller: XY pad, param scanning, X/Y assignment, figures animées |
| 0.5 | 2026-02-28 | Tab system (Mixer/Session/FX), persistence ExtState, sends display, global shortcuts |
| 0.4 | 2026-02-28 | Item editor complet: trim, fades, grid configurable, SM interactifs, selection, reverse/loop/warp, context menu, shortcuts |
| 0.3 | 2026-02-27 | Item editor spectral, modularisation 9 modules, bar grid, pitch/stretch |
| 0.2 | 2026-02-27 | Mixer horizontal adaptatif, knobs, FX chains |
| 0.1 | 2026-02-27 | Proto initial, mixer vertical, transport cross-projet |
