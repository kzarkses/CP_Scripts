# Handoff: FX Browser refonte (CP_Scripts / REAPER)

## Overview
Refonte UI du **FX Browser standalone** de `FX Constellation` (sous-projet de CP_Scripts).
Cible : fenêtre dockable de **555 × 750 px** utilisable confortablement, **zéro troncature** de label, layout adaptatif.

La direction retenue est **V2 — Single bottom-bar** : footer compact 1 ligne avec actions primaires, settings dans un menu ⚙. Les V1 et V3 sont incluses dans le bundle comme références secondaires (à ignorer pour cette implémentation).

## About the Design Files
Les fichiers `.jsx` et le `FX Browser refonte.html` de ce dossier sont des **prototypes HTML/React de référence visuelle**. Ils ne sont **pas du code à porter directement** : la cible réelle est **Lua / CP_Toolkit** (toolkit gfx custom dessinant via `gfx.*` natif REAPER). Ouvre le HTML dans un navigateur pour voir le comportement (hover, tabs, splitter, ⚙ menu) ; lis les `.jsx` pour la structure et les valeurs ; puis recompose en Lua avec les widgets du toolkit.

Le code source actuel à refondre :
- `FX Constellation/CP_FXBrowser.lua` (le fichier à réécrire)
- `CP_Toolkit/API.md` (référence des widgets disponibles — single source of truth)
- `CP_Toolkit/{CP_Toolkit,Widgets,Layout,Core}.lua` (implémentations)

## Fidelity
**Hi-fi sur la structure et le comportement, neutre sur le rendu pixel.**
Les couleurs, sizes et fonts dans `theme.jsx` sont des **placeholders raisonnables** ; la version Lua doit lire ses valeurs depuis `UI.GetTheme()` (colors + sizes), **jamais en dur**. C'est une règle stricte du projet : aucune valeur hardcodée dans `CP_FXBrowser.lua`.

## Règles d'or à respecter
1. **Aucune valeur hardcodée** — tout vient de `UI.GetTheme().sizes` et `.colors`. Si un size manque, l'ajouter au theme, pas dans le browser.
2. **Toutes les features actuelles préservées** : multi-select (Click / Ctrl+Click / Shift+Click), DnD plugin → chain, DnD plugin → tab chip, DnD chain row reorder, Ctrl+Drag = duplicate, Alt+Click chain row = delete, double-click plugin = add, double-click chain row = open.
3. **Le SoundGenerator JSFX de FX Constellation reste filtré** dans la chain pane (caché de la liste).
4. **Pas de dépendance externe** — uniquement le toolkit existant.
5. **`body_h` adaptatif** : utiliser `UI.GetAvailableHeight()` au lieu de la valeur fixe `360`.

---

## V2 — Layout cible

Référence visuelle : `layout-v2.jsx` + `layout-shared.jsx` (primitives partagées) + `components.jsx` (widgets).
Ouvre `FX Browser refonte.html` dans un navigateur, puis dans le canvas zoom sur la section **« V2 — Single bottom-bar »** pour voir le rendu interactif.

### Structure verticale (de haut en bas)

```
┌─────────────────────────────────────────────────┐
│  TOOLBAR        Search [_____________] ⟳ ↕      │  ← inputH + 2·pad
├─────────────────────────────────────────────────┤
│  CHIPS    [All][★][⏱][V3][V][JS][B] | tabs… [+] │  ← chipH + 2·padSmall
├──────────────────────────┬──────────────────────┤
│  Plugins (242)           │  Chain (4)           │  ← pane label : btnH + 2·padSmall
│ ┌──────────────────────┐ │ ┌──────────────────┐ │
│ │  list scrollable     │ │ │  list scrollable │ │  ← flex:1, body_h adaptatif
│ │  ★ kHs Pitch  VST3   │ │ │  ⋮ 01 kHs… VST3  │ │
│ │    Pro-Q 3    VST3   │ │ │  ⋮ 02 Pro… VST3  │ │
│ │    …                 │ │ │  …               │ │
│ └──────────────────────┘ │ └──────────────────┘ │
├──────────────────────────┴──────────────────────┤
│  ⊕ Add(2) │ 🎲 ▰▰▰▱ 3   ⌫ ⚙                   │  ← btnH + 2·padSmall
└─────────────────────────────────────────────────┘
```

### Toolbar (haut)

| Élément | Toolkit | Notes |
|---|---|---|
| Search input | `UI.InputText` | flex:1, leftIcon `Icons.search`, clear button au hover si non vide |
| Scan button | `UI.Button` icon-only | `Icons.scan`, tooltip "Rescan FX list" |
| Sort A→Z | `UI.Button` icon-only | `Icons.sort`, tooltip "Sort A→Z" |

**Layout** : `UI.BeginColumns` avec largeurs intrinsèques — search prend `flex:1`, les boutons icon-only font `sizes.btnH × sizes.btnH`.
Plus de colonnes proportionnelles 55/15/15/15 — c'est la cause principale du gaspillage actuel.

### Chip row (filtres + tabs)

**Built-in filters (compactés en 1–2 caractères)** :
- `All` (texte)
- `★` (Favorites — `Icons.star`, sans label)
- `⏱` (Recents — `Icons.clock`, sans label)
- `V3` (texte) — VST3
- `V` (texte) — VST
- `JS` (texte) — JS
- `B` (texte) — Bundled

Chaque filtre = `UI.Button` taille `chipH` avec tooltip décrivant le filtre complet.

**User tabs (custom)** :
- Affichés à droite des built-ins, séparés par un `UI.Sep` vertical
- **Scrollable horizontalement** (jamais de wrap sur 2 lignes) — utiliser `UI.BeginScrollX` ou équivalent ; si pas dispo dans le toolkit, l'ajouter
- Hover sur un tab révèle un bouton ✕ pour le supprimer
- Bouton `+` à l'extrême droite pour créer un tab

**Layout** : 1 seule ligne, hauteur = `chipH + 2·padSmall`. Si la row déborde → scroll horizontal, **pas de wrap**.

### Body (panes)

**Splitter resizable** entre Plugins et Chain. Ratio par défaut `0.6` (Plugins 60 / Chain 40). Persisté en state (ex. `state.split_left`). Range autorisé : `[0.3, 0.75]`.

**Hauteur** : `body_h = UI.GetAvailableHeight()` — la zone scrollable grandit avec la fenêtre.

#### Plugins pane

- Header minimal (`btnH + 2·padSmall` de hauteur) : label `PLUGINS  242` en uppercase tamisé.
- Liste scrollable : chaque row = `rowH` de hauteur, padding horizontal `pad`.
- Row content : `[★ si fav]  [name flex:1 ellipsis]  [type mono à droite]`
- States : hover = `surface2` bg, selected = `accentDim` bg.
- Multi-select : Click toggle, Ctrl+Click ajoute/retire, Shift+Click range.

#### Chain pane

- Header minimal identique : label `CHAIN  4`.
- Liste scrollable, row = `rowHLarge` (un peu plus haut pour confort de drag).
- Row content : `[grip drag, opacity 0.4 → 1 au hover]  [index 01..NN, mono]  [name flex:1 ellipsis]  [type mono]  [actions hover-only]`
- **Actions révélées au hover seulement** (opacity 0 → 1, transition 80ms) :
  - `Icons.play` — Open FX (équivalent du ○ actuel)
  - `Icons.eye` / `Icons.eyeOff` — Bypass toggle
  - `Icons.trash` — Delete (rouge)
- **State Bypassed** : texte en `colors.textMute` + `text-decoration: line-through` + icône `eyeOff` colorée en `colors.bypass` (amber).
- DnD : drag header pour reorder, Ctrl+Drag = duplique. Alt+Click row = delete (raccourci, pas de confirmation).
- Filtre : exclure le SoundGenerator JSFX de FX Constellation de la liste (déjà fait dans le code actuel, le préserver).

### Bottom-bar (footer V2 — 1 ligne)

```
[⊕ Add (2)]  │  [🎲]  ▰▰▰▱ 3        [⌫]  [⚙]
   primary       random + count slider    clear · settings
```

| Élément | Toolkit | Comportement |
|---|---|---|
| Add (N) | `UI.Button` avec icon + label | Désactivé si `selected.size == 0`. Quand actif : bg `accentDim`, text plein. Ajoute la sélection à la chain. |
| Sep vertical | `UI.Sep` | Hauteur `btnH * 0.6` |
| Random dice | `UI.Button` icon-only | Tire aléatoirement `randomCount` plugins (depuis visible si `settings.fromVisible`, sinon depuis tous). Si `settings.replace` → remplace la chain, sinon append. |
| Slider count | `UI.SliderInt` | width fixe ~70px, range `[1, 12]`, label de valeur en mono à droite |
| spacer | `UI.Spacer` flex | pousse les actions secondaires à droite |
| Clear chain | `UI.Button` icon-only | `Icons.erase` ou `Icons.trash`, danger color, tooltip "Clear chain" |
| Settings ⚙ | `UI.Button` icon-only | `Icons.gear`, ouvre `UI.ContextMenu` ancré au-dessus |

**Hauteur** : `btnH + 2·padSmall`. Padding horizontal `pad`. Border-top `1px borderSoft`. Background `surface`.

### ⚙ Settings ContextMenu

Ouvert par le bouton ⚙ en bas-droite, ancré **au-dessus** du bouton.

```
┌──────────────────────┐
│ BEHAVIOR             │
│  ☑ Auto-open FX on add │
│  ☐ Replace on add    │
│ ─────────────────    │
│ RANDOM               │
│  ☐ From visible only │
└──────────────────────┘
```

3 toggles `UI.Checkbox`, 2 sections séparées par `UI.Sep`, libellés de section en uppercase tamisés (`fontSm`, `textMute`, letter-spacing).

---

## Design tokens

À déclarer dans `UI.GetTheme()` (ou compléter ce qui existe). **Aucun de ces noms ne doit apparaître en dur dans `CP_FXBrowser.lua`.**

### Colors

| Token | Valeur de référence (placeholder) | Usage |
|---|---|---|
| `bg` | `#1e1e1f` | Window background |
| `surface` | `#252526` | Panel / footer background |
| `surface2` | `#2d2d2f` | Hover, selected secondary |
| `border` | `#363638` | Dividers durs |
| `borderSoft` | `#2a2a2c` | Dividers subtils |
| `text` | `#d4d4d4` | Texte principal |
| `textDim` | `#8a8a8c` | Labels secondaires, boutons inactifs |
| `textMute` | `#5d5d60` | Type indicator, count, sections |
| `accent` | `#7aa2c4` | Splitter focus, view tab underline |
| `accentDim` | `#4a6680` | Selected row, primary button bg |
| `danger` | `#c47a7a` | Delete / clear |
| `bypass` | `#c4a87a` | Bypassed FX indicator (amber) |

### Sizes

| Token | px | Usage |
|---|---|---|
| `rowH` | 22 | Plugin list row |
| `rowHSmall` | 18 | Boutons compacts |
| `rowHLarge` | 26 | Chain list row |
| `chipH` | 20 | Filter pills, user tabs |
| `inputH` | 24 | Search input |
| `btnH` | 24 | Boutons toolbar / footer |
| `pad` | 6 | Padding standard |
| `padSmall` | 4 | Padding serré |
| `padLarge` | 10 | Padding aéré |
| `gap` | 4 | Gap horizontal entre éléments |
| `gapLarge` | 8 | Gap entre sections |
| `radius` | 2 | Border radius |
| `fontSm` | 10 | Labels secondaires |
| `fontBase` | 11 | Texte UI |
| `fontLg` | 13 | Titres (peu utilisé ici) |
| `splitterW` | 3 | Largeur du splitter |

### Icons utilisés (tous depuis `UI.Icons.*`)

`search`, `scan`, `sort`, `gear`, `close`, `plus`, `star` (+ `starF` rempli), `clock`, `chevR`, `chevL`, `play`, `eye`, `eyeOff`, `trash`, `dice`, `erase`, `add`, `check`, `grip`, `folder`, `layers`.

Si certains manquent dans `Icons`, les ajouter (mono-glyph, cohérents avec le set existant).

---

## Interactions & comportement

### Multi-select plugin list
- **Click** → sélectionne uniquement cette row (clear le reste)
- **Ctrl+Click** → toggle l'inclusion de cette row
- **Shift+Click** → étend la sélection du dernier index sélectionné jusqu'à celui-ci
- **Escape** → clear selection
- Après "Add (N)" → la sélection est vidée

### Drag & Drop
- **Plugin row → Chain pane** : ajoute le(s) plugin(s) à la chain (à la position du drop). Si multi-select, drag déplace le groupe entier.
- **Plugin row → Tab chip** : ajoute le(s) plugin(s) au tab custom (assigne le tag).
- **Chain row header → autre row position** : reorder dans la chain. **Ctrl pendant le drag** = duplique au lieu de déplacer.
- Drag preview : utiliser `UI.DrawDragPreview` (existant).

### Modifiers chain row
- **Double-click** → open FX (équivalent au bouton ▶)
- **Alt+Click** → delete row (équivalent au bouton 🗑)
- Les boutons hover sont **redondants par sécurité** (découvrabilité), pas obligatoires fonctionnellement.

### Random
- Bouton 🎲 utilise `randomCount` (slider) et `settings.fromVisible`.
- Si `settings.replace == true` → vide la chain et insère.
- Si `settings.replace == false` → append à la fin.

### Clear chain
- Bouton ⌫ vide la chain. **Pas de confirmation modale** (réversible via undo de REAPER).

---

## State variables (pour la version Lua)

```lua
state = {
  search       = "",          -- string
  filter       = "all",       -- "all" | "fav" | "recent" | "vst3" | "vst" | "js" | "bundled"
  active_tab   = nil,         -- nil ou index dans state.tabs
  tabs         = {...},       -- liste de { name, plugins = {...} }
  selected     = {},          -- set d'indices dans la liste filtrée
  chain        = {...},       -- liste FX de la track sélectionnée
  random_count = 3,           -- 1..12
  split_left   = 0.6,         -- 0.3..0.75 (ratio splitter)
  settings = {
    auto_open    = true,
    replace      = false,
    from_visible = false,
  },
  -- état UI
  settings_menu_open = false,
  hover_row          = nil,   -- pour reveal des actions chain
}
```

---

## Files in this bundle

| Fichier | Rôle |
|---|---|
| `FX Browser refonte.html` | Prototype interactif des **3 variations** (V1, V2, V3). Ouvre dans un navigateur ; zoom sur la section V2 pour la cible. |
| `theme.jsx` | Tokens couleurs/sizes/fonts (placeholder de `UI.GetTheme()`). |
| `icons.jsx` | Set d'icônes mono-glyph (référence pour le mapping vers `UI.Icons.*`). |
| `components.jsx` | Widgets primitifs : `Btn`, `IconBtn`, `Input`, `Pill`, `Tab`, `Check`, `Slider`, `Sep`. |
| `mock-data.jsx` | Données mock (plugins, chain, tabs). |
| `layout-shared.jsx` | Primitives partagées entre V1/V2/V3 : `PluginRow`, `ChainRow`, `Splitter`, `PaneHeader`, `SettingsMenu`, `ChipRow`, `FILTERS`. |
| **`layout-v2.jsx`** | **La direction retenue.** Lecture prioritaire. |
| `layout-v1.jsx` / `layout-v3.jsx` | Variations alternatives — référence secondaire, **ne pas implémenter**. |
| `design-canvas.jsx` | Composant d'affichage (canvas pan/zoom). Pas pertinent pour le port. |

---

## Quick reference — mapping CP_Toolkit

| Prototype primitive | CP_Toolkit equivalent |
|---|---|
| `Input` (search) | `UI.InputText` |
| `Btn` / `IconBtn` | `UI.Button` |
| `Pill` (filter) | `UI.Button` style="chip" ou compose toi-même |
| `Tab` (user tab) | `UI.Button` + bouton ✕ enfant au hover |
| `Check` | `UI.Checkbox` |
| `Slider` | `UI.SliderInt` |
| `Sep` | `UI.Separator` (vertical / horizontal) |
| ScrollList | `UI.BeginChild` + scroll natif |
| ChipRow scroll horizontal | `UI.BeginScrollX` (à ajouter au toolkit si absent) |
| `SettingsMenu` | `UI.ContextMenu` ouvert par le bouton ⚙ |
| Splitter | `UI.BeginColumns` resizable, ou primitive custom |
| Drag&Drop | `UI.BeginDragSource` / `UI.BeginDropTarget` / `UI.DrawDragPreview` (existants) |

---

## Definition of Done

- [ ] Fenêtre 555 × 750 utilisable confortablement, **aucun label tronqué**.
- [ ] `body_h` adaptatif (la zone scroll grandit avec la fenêtre).
- [ ] `state.split_left` persisté entre sessions.
- [ ] Toutes les features actuelles préservées (multi-select, DnD, modifiers, tabs custom, Replace, Clear, SoundGenerator filtré).
- [ ] Aucune valeur en dur — grep `CP_FXBrowser.lua` pour `[0-9]+` dans des contextes de pixel/size doit être vide (sauf indices et bornes de range).
- [ ] Chip row jamais sur 2 lignes même avec 8+ tabs custom.
- [ ] Hover state révèle les actions chain row en < 100ms.
- [ ] ⚙ ContextMenu contient Auto-open / Replace / From visible only.
