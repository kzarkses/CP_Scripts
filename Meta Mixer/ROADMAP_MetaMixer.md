# CP MetaMixer — Sous-roadmap Mixer

> **Parent** : [ROADMAP_CPStudio.md](../ROADMAP_CPStudio.md)
> **Dernière mise à jour** : 2026-02-28

---

## Description

Le MetaMixer est le composant central de CP Studio : un mixer horizontal cross-projet qui affiche les masters de tous les projets ouverts et les tracks du projet actif. Inspiré du mixer d'Ableton mais exploitant la navigation en profondeur via subprojects.

---

## Status actuel : V0.3 ✅

### Ce qui fonctionne

**Masters (tous projets) :**
- Volume knob custom (drag + double-click reset)
- Pan knob
- Mute/Solo buttons
- VU meters stéréo verticaux
- Transport (Play/Stop) par projet
- FX chain display (noms + toggle bypass)
- Clic = switch tab REAPER + expand

**Tracks (projet actif) :**
- Volume/Pan knobs
- Mute/Solo
- VU meters
- FX chain cliquable
- Couleur de track REAPER

**Architecture :**
- `MixerStrip.lua` — Strip unifié masters + tracks
- `Widgets.lua` — DrawKnob (arc, drag sensitivity 0.004, double-click reset), DrawVMeter, DrawHMeter
- `State.lua` — Scan cross-projet, enriched item info

---

## Roadmap détaillée

### V0.4 — Améliorations mixer

- [ ] **Sends display** : Affichage des sends par track (icône ou texte compact)
- [ ] **Groups/Folders** : Respect de la hiérarchie de dossiers REAPER (indent visuel)
- [ ] **Track filtering** : Masquer/montrer par type (audio, MIDI, bus, folder)
- [ ] **Horizontal scroll** : Si trop de tracks, scrollbar horizontal ou scroll molette
- [ ] **Peak hold** : Maintien du peak max pendant ~2s sur les VU meters
- [ ] **Clip indicator** : Indicateur rouge si peak > 0dB sur les meters

### V0.5 — Interactions avancées

- [ ] **Drag volume** : Drag sur le meter directement pour ajuster le volume
- [ ] **Right-click menu** : Menu contextuel sur un strip (rename, color, insert FX, etc.)
- [ ] **FX insertion rapide** : Bouton + sur chaque strip → browser FX compact
- [ ] **Solo exclusive** : Ctrl+Click sur solo = solo exclusive (unsolo tous les autres)
- [ ] **Track reorder** : Drag & drop pour réordonner les tracks

### V0.6 — Persistence & Settings

- [ ] **Sauvegarder l'état** : Taille de fenêtre, position, strip widths
- [ ] **Settings panel** : Strip width, VU decay speed, refresh rate, etc.
- [ ] **Presets de layout** : Sauvegarder/restaurer des configurations de mixer

### V0.7 — Polish

- [ ] **Animations** : Smooth transitions sur mute/solo/volume
- [ ] **Couleurs adaptatives** : Track color influence le fond du strip
- [ ] **Keyboard shortcuts** : M=mute, S=solo, Flèches=naviguer entre strips
- [ ] **Tooltips enrichis** : Afficher peak hold, time position, etc. au hover

---

## Fichiers

| Fichier | Rôle | Status |
|---------|------|--------|
| `Modules/MixerStrip.lua` | Rendu d'un strip (master ou track) | ✅ Stable |
| `Modules/Widgets.lua` | Knobs, VU meters | ✅ Stable |
| `Modules/State.lua` | Scan projets, collection données | ✅ Stable, à étendre |
| `Modules/Constants.lua` | Couleurs, dimensions | ✅ Stable, à étendre |
| `Modules/Helpers.lua` | Conversions dB, formatting | ✅ Stable |
| `CP_MetaMixer.lua` | Entry point, main loop | ✅ Stable |

---

## API REAPER utilisées

```lua
-- Cross-projet
r.EnumProjects(idx)                    -- Lister les projets
r.GetMasterTrack(proj)                 -- Master par projet
r.GetTrack(proj, idx)                  -- Track par projet
r.Track_GetPeakInfo(track, chan)        -- VU meters temps réel
r.GetPlayStateEx(proj)                 -- État transport
r.OnPlayButtonEx(proj)                 -- Contrôle transport
r.SelectProjectInstance(proj)          -- Switch tab

-- Track info
r.GetMediaTrackInfo_Value(track, key)  -- D_VOL, D_PAN, B_MUTE, I_SOLO
r.SetMediaTrackInfo_Value(track, k, v) -- Modifier volume/pan/mute/solo
r.GetTrackColor(track)                 -- Couleur track

-- FX
r.TrackFX_GetCount(track)             -- Nombre FX
r.TrackFX_GetFXName(track, fx, "")    -- Nom FX
r.TrackFX_GetEnabled(track, fx)        -- Bypass state
r.TrackFX_SetEnabled(track, fx, bool)  -- Toggle bypass
```
