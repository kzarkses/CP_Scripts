# CP Item Editor — Sous-roadmap (7 phases)

> **Parent** : [ROADMAP_CPStudio.md](../ROADMAP_CPStudio.md)
> **Dernière mise à jour** : 2026-02-28

---

## Vision

Un éditeur d'item complet intégré au CP Studio, inspiré du Clip Editor d'Ableton (depuis v1). Pas un gadget — un outil de travail quotidien qui remplace le besoin d'ouvrir les propriétés d'item ou d'utiliser l'arrangeur pour les opérations courantes sur les clips audio.

**Principe fondamental** : L'item est une *fenêtre* dans un fichier source plus long. L'éditeur montre TOUJOURS le source complet, avec l'item comme zone active mise en évidence. Toutes les opérations sont visuelles et directes sur la waveform.

---

## Status actuel : V0.4 — Toutes les phases implémentées ✅

### Ce qui fonctionne
- Waveform spectrale (coloration fréquentielle logarithmique HSL)
- Vue stéréo (L top / R bottom) et mono
- **Source complet visible** : item = fenêtre bright dans le source dimmed
- **Zoom/Scroll** : mouse wheel, middle-click drag, slider, Fit/Src buttons
- **Trim des bords** : drag left/right edges (D_POSITION + D_STARTOFFS + D_LENGTH)
- **Fades interactifs** : drag handles, courbes visuelles (7 shapes), poignées
- **Grille configurable** : 10 résolutions (1 Bar → 1/32, triplets, dotted), snap toggle
- **Stretch markers interactifs** : drag (snap to grid), double-click delete, Add/Clear
- **Sélection de région** : click+drag, Crop/Delete, info bar avec durée
- **Reverse/Loop/Warp** : toolbar toggles, action REAPER 41051
- **Context menu** : right-click popup avec toutes les actions
- **Raccourcis clavier** : S=split, M=marker, R=reverse, L=loop, Del=delete sel, Esc=clear, +/-=zoom
- **Curseur souris adaptatif** : resize pour edges/fades, hand pour SM
- Grille bar/beat avec numéros de mesure + subdivisions
- Playback cursor temps réel
- Pitch/Rate/Volume knobs
- Algo pitch dropdown (12 algorithmes) + Formants toggle
- Click = edit cursor, Shift+Click = add SM, Ctrl+Click = split
- Split@Bars, Dive subproject, Stereo/Mono toggle

---

## Layout cible

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ [Snap: 1/4] [Grid ▼] [Mono/Stereo] [Warp] [Loop] [Rev]    "filename.wav" │
├─────────────────────────────────────────────────────────────────────────────┤
│ ┌fade─┐                                                         ┌─fade┐  │
│ │╲    │                                                         │    ╱│  │
│ │  ╲  │    ┌─WAVEFORM VISIBLE (item)───────────────────────┐    │  ╱  │  │
│ │    ╲│    │                                               │    │╱    │  │
│ ░░░░░░░░░░░║█▓▒░  |1  :  :  :  |2  :  :  :  |3  ░▒▓██████║░░░░░░░░░░░  │
│ ░dimmed░░░░║██▓▒░     ▲SM       ▲SM           ░▒▓██████▓▒░║░░dimmed░░░  │
│ ░(source)░░║█▓▒░      │         │              ░▒▓████▓▒░░║░░(source)░  │
│ ░░░░░░░░░░░║▓▒░       ▼drag     ▼snap-to-grid  ░▒▓██▓▒░░░║░░░░░░░░░░  │
│            ║                     ▲cursor                    ║            │
│ ◄─drag────►║◄──────────── item region ─────────────────────►║◄──drag───► │
│  left edge  ║  [=======SELECTION========]                    ║ right edge │
│            ╚════════════════════════════════════════════════╝            │
│                                                                         │
│  Zoom: [─────●────────] ◄► Scroll                                      │
├────────────────────────────────────────────────────────────────────┬─────┤
│  Algo: [Elastique 3 Pro ▼] [Formants] [Warp Mode ▼]              │Pitch│
│  SM: 3 markers  [+ Add at cursor] [Clear all]                    │Rate │
│                                                                   │Vol  │
│  Selection: 0.5s → 1.2s (0.7s) [Cut] [Crop] [Delete]            │Fade │
└────────────────────────────────────────────────────────────────────┴─────┘
```

### Zones d'interaction souris

| Zone | Curseur | Action drag | Action click |
|------|---------|-------------|-------------|
| Bord gauche item (5px) | ↔ resize | Trim left edge (D_POSITION + D_STARTOFFS + D_LENGTH) | — |
| Bord droit item (5px) | ↔ resize | Trim right edge (D_LENGTH) | — |
| Coin haut-gauche (fade zone) | ↔ fade | Drag = ajuste D_FADEINLEN | — |
| Coin haut-droit (fade zone) | ↔ fade | Drag = ajuste D_FADEOUTLEN | — |
| Triangle stretch marker | ↔ move | Drag horizontalement, snap to grid | Double-click = delete |
| Zone waveform (normal) | curseur | Drag = sélection region | Click = set edit cursor |
| Zone waveform (Shift) | + marker | — | Shift+Click = add stretch marker |
| Zone waveform (Ctrl) | ✂ scissors | — | Ctrl+Click = split at position |
| Zone source (dimmed) | extend | Drag = étend l'item dans cette direction | — |

---

## Phase 1 — Source complet + Zoom/Scroll (fondation) ✅

**Fichiers** : `Waveform.lua`, `ItemEditor.lua`, `State.lua`, `Constants.lua`

### State.lua — enrichir `item_info`

```lua
info.source_len = r.GetMediaSourceLength(source)  -- durée totale fichier source
info.source_offset = take_offset                   -- D_STARTOFFS
info.playrate = rate                               -- D_PLAYRATE
info.pre_item = offset / playrate                  -- audio avant l'item (secondes)
info.post_item = (source_len - offset - len * playrate) / playrate  -- audio après
info.loop_src = r.GetMediaItemInfo_Value(item, "B_LOOPSRC")
info.fade_in_shape = r.GetMediaItemInfo_Value(item, "C_FADEINSHAPE")
info.fade_out_shape = r.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE")
```

### Waveform.lua — refonte pour source complet

- [ ] `GetPeaks()` accepte paramètre `source_mode` : peaks du source ENTIER
- [ ] Calcul mapping pixel ↔ source time avec zoom/scroll
- [ ] Rendu : source complet dimmed (alpha réduit) + item en bright
- [ ] Rendu des courbes de fade (approximation via DrawList_PathLineTo, 4px sampling)
- [ ] Cache étendu : clé = `item_id + source_len + width + zoom_level + scroll_pos + vol`

### ItemEditor.lua — zoom slider + scroll

- [ ] `editor_state` local (zoom, scroll, drag_mode, selection, etc.)
- [ ] Toolbar : nom fichier + infos + futurs boutons
- [ ] Zoom slider horizontal ou mouse wheel
- [ ] Scroll : middle mouse drag ou scrollbar
- [ ] Conversion pixel ↔ temps :
  ```lua
  function PixelToTime(px, wx, wf_w, view_start, view_len)
      return view_start + (px - wx) / wf_w * view_len
  end
  function TimeToPixel(time, wx, wf_w, view_start, view_len)
      return wx + (time - view_start) / view_len * wf_w
  end
  ```

### Constants.lua — nouvelles couleurs

- [ ] `COL_WAVEFORM_DIMMED` (source hors item, alpha réduit)
- [ ] `COL_SELECTION` (rectangle semi-transparent bleu)
- [ ] `COL_ITEM_EDGE` (bords de l'item, ligne verticale)
- [ ] `COL_FADE_HANDLE` (poignées de fade)
- [ ] `COL_FADE_CURVE` (courbe de fade)

### Vérification
Sélectionner un item → voir le source complet (dimmed autour, bright au centre) → zoomer/dézoomer → scroller.

---

## Phase 2 — Trim edges + Fades (interactions de base) ✅

**Fichiers** : `ItemEditor.lua`, `Waveform.lua`

### Trim des bords

**Left edge drag :**
```lua
new_position  = old_position + delta_time
new_length    = old_length - delta_time
new_startoffs = old_startoffs + delta_time * playrate
-- Clamp: can't go past source start, can't shrink item to 0
```

**Right edge drag :**
```lua
new_length = old_length + delta_time
-- Clamp: can't go past source end
```

- [ ] Hit detection des edges (gauche/droite, 5px)
- [ ] Drag left edge : modifie D_POSITION + D_STARTOFFS + D_LENGTH
- [ ] Drag right edge : modifie D_LENGTH
- [ ] Clamp aux limites du source
- [ ] Snap edges to grid si snap activé
- [ ] Undo block pour chaque opération de trim

### Fades

**Fade in handle** (coin haut-gauche) :
- Zone de hit : `fade_in_len` pixels de large × 15px de haut
- Drag horizontal = modifie `D_FADEINLEN`
- Clamp : ne dépasse pas `item_len - fade_out_len`

**Fade out handle** (coin haut-droit) :
- Identique, miroir

- [ ] Hit detection corners fade (zone rectangulaire)
- [ ] Drag fade in/out handles
- [ ] Rendu visuel des courbes de fade (7 shapes REAPER via DrawList)
- [ ] Undo blocks pour toutes les opérations

### Shapes de fade REAPER

| C_FADEINSHAPE | Description |
|---------------|-------------|
| 0 | Linéaire |
| 1 | Fast start (exponentielle) |
| 2 | Slow start (logarithmique) |
| 3 | Fast start, slow end (S-curve 1) |
| 4 | Slow start, fast end (S-curve 2) |
| 5 | Smoothstep |
| 6 | Smootherstep |

### Curseur souris adaptatif

- [ ] Zone edge → curseur ↔ resize
- [ ] Zone fade → curseur ↔ fade
- [ ] Zone waveform → curseur normal
- [ ] Ctrl → curseur ✂ scissors
- [ ] Shift → curseur + marker

### Vérification
Drag les bords → l'item se trim → drag les coins → fades changent → undo fonctionne.

---

## Phase 3 — Grid configurable + Snap ✅

**Fichiers** : `BarGrid.lua`, `ItemEditor.lua`

### Résolutions de grille

```lua
GRID_RESOLUTIONS = {
    { name = "1 Bar",  beats = nil, bars = 1 },
    { name = "1/2",    beats = 2 },
    { name = "1/4",    beats = 1 },
    { name = "1/8",    beats = 0.5 },
    { name = "1/16",   beats = 0.25 },
    { name = "1/32",   beats = 0.125 },
    { name = "1/4T",   beats = 2/3 },     -- triplet
    { name = "1/8T",   beats = 1/3 },
    { name = "1/4D",   beats = 1.5 },     -- dotted
    { name = "1/8D",   beats = 0.75 },
}
```

- [ ] Table GRID_RESOLUTIONS dans BarGrid.lua
- [ ] `SnapToGrid(proj, time, resolution)` — snap une position
- [ ] `GetGridLines(proj, view_start, view_end, resolution)` — positions de grille visibles
- [ ] Grille s'adapte au zoom (plus de subdivisions quand on zoom)
- [ ] Toolbar : snap toggle button + grid resolution dropdown
- [ ] Snap appliqué au trim edges, split, stretch markers

### Vérification
Changer la grille → les lignes changent → activer snap → les opérations snappent → désactiver → opérations libres.

---

## Phase 4 — Stretch markers interactifs ✅

**Fichiers** : `ItemEditor.lua`, `PitchStretch.lua`

### Interactions

- [ ] Hit detection sur les triangles SM (±5px autour du sommet)
- [ ] Drag SM horizontalement : `SetTakeStretchMarker(take, idx, new_pos)`
- [ ] Snap SM to grid si snap activé (= quantize)
- [ ] Double-click SM = delete : `DeleteTakeStretchMarkers(take, idx, 1)`
- [ ] Bouton "Add SM at cursor" dans la barre info
- [ ] Bouton "Clear all SM"
- [ ] Visual feedback pendant le drag (ligne preview à la position cible)

### API REAPER

```lua
r.SetTakeStretchMarker(take, idx, new_pos)     -- idx >= 0 = move in-place
r.DeleteTakeStretchMarkers(take, start_idx, count)
r.GetTakeNumStretchMarkers(take)
r.GetTakeStretchMarker(take, idx)              -- → pos, srcpos
r.SetTakeStretchMarkerSlope(take, idx, slope)
```

### Vérification
Shift+Click → SM apparaît → drag SM → il bouge (snapped ou libre) → double-click → supprimé.

---

## Phase 5 — Selection + Cut/Crop/Delete ✅

**Fichiers** : `ItemEditor.lua`

### Sélection de région

- [ ] Click+drag sur waveform (sans modifier) = sélection de région
- [ ] `sel_start` et `sel_end` stockés en temps relatif à l'item
- [ ] Rendu visuel : rectangle semi-transparent bleu sur la sélection
- [ ] Info bar : affiche durée de la sélection (`0.5s → 1.2s (0.7s)`)
- [ ] Escape = clear selection

### Actions sur la sélection

- [ ] **Cut** : split aux 2 bords de la sélection → delete le segment du milieu
- [ ] **Crop** : trim l'item pour ne garder que la sélection
- [ ] **Delete** : comme Cut mais sans copier dans le clipboard
- [ ] Boutons Cut/Crop/Delete dans la barre info
- [ ] Undo blocks pour toutes les actions

### Implémentation Cut

```lua
-- 1. Split at sel_start → gets right part
local right = r.SplitMediaItem(item, item_pos + sel_start)
-- 2. Split right at sel_end → gets remainder
if right then
    local remainder = r.SplitMediaItem(right, item_pos + sel_end)
    -- 3. Delete the middle part (right)
    r.DeleteTrackMediaItem(track, right)
end
```

### Vérification
Click+drag → sélection bleue → Cut → item splitté → Crop → item réduit → Undo → tout revient.

---

## Phase 6 — Reverse + Loop + Warp toggle ✅

**Fichiers** : `PitchStretch.lua`, `ItemEditor.lua`

### Reverse

- [ ] Bouton Reverse dans toolbar
- [ ] Action REAPER `41051` ("Item: Toggle items reverse") ou manipulation directe
- [ ] Waveform se met à jour visuellement (cache invalidé)

### Loop

- [ ] Toggle Loop : `B_LOOPSRC` (0/1)
- [ ] Quand loop activé, l'item peut être étendu au-delà du source
- [ ] Visuel : motif de répétition dimmed après la fin du source

### Warp

- [ ] Toggle Warp on/off
- [ ] Warp off = playrate locked à 1.0
- [ ] Warp on = playrate libre (ajustable via knob Rate)

### Toolbar buttons

```
[Warp: ON] [Loop: OFF] [Rev: OFF]
```

### Vérification
Reverse → waveform miroir → Loop on → item extensible → Warp off → playrate locked.

---

## Phase 7 — Polish + Context menu + Shortcuts ✅

**Fichiers** : `ItemEditor.lua`

### Context menu (right-click)

- [ ] ImGui popup menu
- [ ] Entries :
  - Split at cursor
  - Add stretch marker at cursor
  - Reverse item
  - Normalize
  - Crop to selection (si sélection active)
  - Cut selection
  - Delete selection

### Raccourcis clavier

| Touche | Action |
|--------|--------|
| S | Split à la position du curseur |
| M | Add stretch marker à la position du curseur |
| Delete | Supprimer la sélection |
| Escape | Clear sélection |
| +/- | Zoom in/out |
| Home | Zoom fit (item remplit la largeur) |
| R | Toggle Reverse |
| L | Toggle Loop |

### Polish

- [ ] Curseur souris adaptatif (via `ImGui_SetMouseCursor`)
- [ ] Performance : culling (ne dessiner que la portion visible quand zoomé)
- [ ] Smooth scroll/zoom (lerp)
- [ ] Feedback visuel drag (ghost preview)

### Vérification
Right-click → menu contextuel → raccourcis fonctionnent → curseurs adaptés → smooth.

---

## Fichiers impactés (résumé)

| Fichier | Action | Complexité | Phases |
|---------|--------|-----------|--------|
| `Modules/Waveform.lua` | Refonte majeure | Haute | 1, 2 |
| `Modules/ItemEditor.lua` | Refonte majeure | Haute | 1-7 |
| `Modules/BarGrid.lua` | Extension | Moyenne | 3 |
| `Modules/PitchStretch.lua` | Extension | Moyenne | 4, 6 |
| `Modules/State.lua` | Extension | Basse | 1 |
| `Modules/Constants.lua` | Extension | Basse | 1 |
| `Modules/Widgets.lua` | Inchangé | — | — |
| `Modules/MixerStrip.lua` | Inchangé | — | — |
| `CP_MetaMixer.lua` | Inchangé | Basse | — |

---

## API REAPER clés pour l'éditeur

```lua
-- Source audio
r.GetMediaSourceLength(source)                    -- Durée totale source
r.GetMediaItemTake_Source(take)                    -- Obtenir le source

-- Item comme fenêtre dans le source
r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")  -- Offset dans le source
r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")   -- Rate de lecture
r.GetMediaItemInfo_Value(item, "D_POSITION")       -- Position sur la timeline
r.GetMediaItemInfo_Value(item, "D_LENGTH")          -- Durée de l'item

-- Peaks waveform
r.GetMediaItemTake_Peaks(take, peakrate, starttime, n_chans, n_spls, 115, buf)
-- Buffer layout : [MAX | MIN | SPECTRAL]
-- Spectral : freq = value & 0x7FFF

-- Fades
r.GetMediaItemInfo_Value(item, "D_FADEINLEN")      -- Durée fade in
r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")      -- Durée fade out
r.GetMediaItemInfo_Value(item, "C_FADEINSHAPE")     -- Shape 0-6
r.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE")    -- Shape 0-6

-- Stretch markers
r.SetTakeStretchMarker(take, -1, pos)               -- Créer (idx=-1)
r.SetTakeStretchMarker(take, idx, new_pos)           -- Déplacer (idx>=0)
r.DeleteTakeStretchMarkers(take, start, count)       -- Supprimer
r.GetTakeStretchMarker(take, idx)                    -- Lire position

-- Opérations
r.SplitMediaItem(item, position)                    -- Split
r.DeleteTrackMediaItem(track, item)                 -- Delete
r.SetEditCurPos(time, moveview, seekplay)           -- Set cursor

-- Loop / Reverse
r.GetMediaItemInfo_Value(item, "B_LOOPSRC")         -- Loop source
-- Reverse : action 41051 ou chunk parsing

-- Pitch
r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")   -- mode_idx * 65536 + submode
r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", v)
r.SetMediaItemTakeInfo_Value(take, "D_PITCH", semitones)
```
