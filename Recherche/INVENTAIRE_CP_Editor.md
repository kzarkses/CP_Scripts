# INVENTAIRE EXHAUSTIF — CP_Editor

Fichiers lus intégralement : `CP_Editor/CP_Editor.lua` (3560 l.), `CP_Engine/Roll.lua` (930), `CP_Engine/RollUI.lua` (396), `CP_Engine/Ops.lua` (317), `CP_Engine/Peaks.lua` (356), `CP_Engine/Clip.lua` (207), plus `CP_Engine/Rows.lua` (125) qui est indispensable au roll.

Tout ce qui suit est **vérifié dans le code**. Les rares déductions sont marquées « (déduit) ».

---

## 0. STRUCTURE — quatre modes, deux moitiés

`state.mode` (`CP_Editor.lua:115`) vaut `"item"`, `"file"`, `"midi"`, `"clip"` ou `nil`.

| mode | source | moitié | posé par |
|---|---|---|---|
| `item` | take audio d'un item de l'arrange | audio | `setItem` `:587` |
| `file` | fichier brut, `PCM_Source_CreateFromFile` | audio | `setFile` `:626` |
| `midi` | take MIDI d'un item | roll | `setItem` `:595-614` |
| `clip` | clip sans take (lane Looper / cellule Session) | roll | `setClip` `:649` |

Aiguillage de la frame : `frame` `:3478-3492` — `midi = (mode=="midi" or mode=="clip")` → `drawRoll` sinon `drawWave` ; barre `barMidi` sinon `barAudio` `:3481`.

Le rect partagé `wave` (`:148`) sert aux deux moitiés : `timeAtX` `:186`, `xAtTime` `:190`, `zoomAt` `:346` sont communs. **Une seule grille** pour les deux : `gridStepQN` `:197`.

---

# PARTIE A — LA MOITIÉ AUDIO (`item` / `file`)

## A1. Cible et focus

| Fonction | Ce qu'elle fait | Déclenchement | Ligne |
|---|---|---|---|
| `setItem` | prend l'item sélectionné, lit `D_STARTOFFS`/`D_PLAYRATE`, remet la vue à plat | auto (suivi sélection) ou drop | `:587` |
| `setFile` | ouvre un chemin, crée une `PCM_source` possédée (`own_src`) | drop OS, bus, ExtState legacy | `:626` |
| `openClip` | ouvre un Clip audio du bus : sélectionne `offs..offs+len` et zoome dessus | `Bus.TakeDrop` / `editor:open` | `:764-777` |
| `handleFileDrops` | `gfx.getdropfile`, **premier fichier seulement**, verrouille le suivi | glisser depuis l'Explorateur Windows | `:796` |
| `busConsume` | `DragBus.Register` + `RectSync` + `Bus.TakeDrop` | drop d'une autre fenêtre CP | `:820` |
| `pollTarget` | suit `GetSelectedMediaItem(0,0)` quand `lock` est faux ; revalide sur `GetProjectStateChangeCount` | chaque frame | `:837` |
| `refreshItemFields` | re-lit la source (le reverse la remplace par une section source) | à chaque changement projet | `:388` |
| `clearTarget` | l'item est mort → tout est lâché | invalidation `ValidatePtr2` | `:699` |
| verrou (Lock) | fige la cible | bouton bascule `:1275`, forcé à `true` après un drop `:811`, `:829` | |

## A2. Vue, zoom, navigation

| Geste / commande | Effet | Ligne |
|---|---|---|
| molette dans la zone d'onde | zoom horizontal **au pointeur**, facteur 1.25 par cran, aucun modificateur lu | `:1770-1774` |
| molette bouton du milieu maintenu | pan horizontal | `:1777-1786` |
| touche `Home` | `fitView` (tout le fichier) | `:3350` |
| touche `+` (43) / `-` (45) | zoom au centre, facteur 1.5 | `:3351-3352` |
| bouton `zfit` / `zin` / `zout` | idem, au centre | `:1351-1357` |
| menu contextuel « Fit » / « Zoom to selection » | `fitView` / `zoomSelection` (5 % de marge) | `:1937-1939`, `:354` |
| clamp | span minimum = 32 échantillons, jamais au-delà du fichier | `clampView` `:331` |

Pas de scroll-follow pendant la lecture (aucun code ne recadre sur le curseur de lecture — vérifié par absence).

## A3. Sélection temporelle et curseur d'édition

La sélection audio est **locale à l'éditeur** (`state.sel_a/sel_b` `:124`), pas la time selection de REAPER. Le curseur d'édition audio est lui aussi local (`state.cursor` `:125`). **C'est l'inverse exact de la moitié MIDI** (voir B9) — asymétrie réelle, pas un détail.

| Geste | Effet | Ligne |
|---|---|---|
| glisser dans l'onde (> 3 px) | nouvelle sélection, **snappée en direct aux deux bouts** | `:1840-1848` |
| clic simple (sans mouvement) | pose le curseur d'édition, **ne touche pas à la sélection** | `:1899-1906` |
| glisser un bord de sélection (±5 px) | redimensionne ; le croisement échange les bords | `:1849-1858` |
| glisser dans la règle (18 px de haut) | scrub du curseur d'édition seul | `:1749-1766` |
| `Esc` | efface la sélection | `:3353-3355` |
| menu contextuel → Clear selection | idem | `:1949-1950` |
| relâchement + `snap_zero` **et** grille éteinte | recalage sur passage par zéro (`Ops.SnapZero` `Ops.lua:117`) | `:1897`, `:1907-1915` |

## A4. Aimantation (audio)

`waveSnap` `:245-264`. Cibles : la grille **toujours**, les transitoires **si `snap_trans`** et si elles sont à la fois plus proches et à moins de `SNAP_PX = 12` px (`:240`).

- Aller-retour source → projet → QN → source via `srcToProj` `:219` / `projToSrc` `:230`, donc une carte de tempo est honorée.
- Un fichier brut est lu comme s'il commençait au zéro du projet (`:227`).
- **`Shift` court-circuite le snap partout** (`:246`).
- Bascule aimant : `w_snap` `:1363` ; division : combo `w_grid` `:1374` sur `GRID_CHOICES` `:315` (1/1 → 1/64 + 1/8T + 1/16T, entrée 1 = grille projet).
- La grille n'est **dessinée que si l'aimant est allumé** (`:2034`), cache `wgrid` `:1491`, plafond `WGRID_MAX = 400` lignes `:1493`, deux poids (mesure 0.28 / division 0.11) `:2040`.

## A5. Transitoires — des objets

`state.markers`, tableau **trié**, `MARK_MIN = 0.0005 s` (`:274`).

| Geste | Effet | Ligne |
|---|---|---|
| bouton `sl_detect` | `Ops.DetectTransients` sur la région ou la sélection | `:1044-1051`, `Ops.lua:61` |
| réglage `sl_sens` (0–100 %) | seuil et ratio de détection | `:1431-1437`, `Ops.lua:96-98` |
| `Ctrl`+clic dans l'onde | ajoute une transitoire (snappée) | `:1824-1826` |
| touche `M` | ajoute une transitoire **sur le curseur d'édition** (marche pendant la lecture) | `:3362-3365` |
| glisser un fanion (bande haute 14 px, ±5 px) | déplace, **clampé entre ses voisines** | `:1868-1872`, `markerMove` `:302` |
| `Alt`+clic sur un fanion | supprime | `:1816-1818` |
| `Delete` | supprime celle sous le curseur d'édition | `:3366-3373` |
| bouton `sl_clear` / menu | vide la liste | `:1053` |
| bouton `sl_split` (mode item) | `Ops.SplitAt` → découpe l'item | `:1058-1062`, `Ops.lua:300` |

Le **fanion** est la poignée, pas la ligne (`waveHit` `:1726-1729`) — commentaire explicite `:1715-1718`.

## A6. Édition non destructive de l'item (mode `item` seul)

| Contrôle | Op | Ligne éditeur | Ligne Ops |
|---|---|---|---|
| `op_gain` (−60…+24 dB) | `D_VOL`, polarité préservée | `:1402-1403` | `Ops.SetVolDB:188`, `setVolKeepPolarity:167` |
| `op_pitch` (−48…+48 st) | `D_PITCH` | `:1404-1406` | `Ops.SetPitch:216` |
| `op_rate` (0.25…4×) | `D_PLAYRATE` + `B_PPITCH=1` + longueur item recalculée (sémantique clip Ableton) | `:1407-1409` | `Ops.SetRate:224` |
| `op_norm` | normalise la région/sélection vers `norm_db` (0/−1/−3/−6) | `:1412-1420` | `Ops.Normalize:178` |
| `op_rev` | action native 41051, sélection d'items restaurée | `:1421-1423` | `Ops.Reverse:198` |
| `op_trim` | recale `D_STARTOFFS` + longueur sur la sélection | `:1424-1428` | `Ops.TrimToSel:289` |
| poignée fondu (haut, ±7 px) | `D_FADEINLEN` / `D_FADEOUTLEN` en direct | `:1879-1890` | `Ops.SetFades:234` |
| poignée bord (bas, ±6 px) | `Ops.TrimEdge` — le bord gauche déplace l'item, le droit change la longueur | `:1873-1878` | `Ops.TrimEdge:253` |

Les quatre `BarValue` ont les quatre mêmes gestes : glisser (`Shift` = fin), molette, clic droit = saisie au clavier, double-clic = défaut (`Widgets.lua:5730-5753`).

Les fondus dessinés sont **entendus dans la préview** dès la lecture suivante (`:1022-1025`), le gain/pitch/rate aussi (`:1013-1019`), et la forme d'onde est mise à l'échelle par `D_VOL` (`:1554-1558`).

## A7. Découpe et envoi (« un son devient un instrument »)

| Bouton | Effet | Ligne |
|---|---|---|
| `sl_pads` | chaque tranche (bornes = région + marqueurs) → un pad vide du kit, via `Kit.LoadSample` + `Kit.SetOffsets`, `no_sync = true` | `:1065-1095` |
| `sl_selpad` | la sélection → premier pad vide | `:1097-1114` |
| `sl_instr` | le fichier (ou la sélection) → CP_Sampler en mode instrument chromatique, par `SetExtState("CP_Sampler","instrument", …)` fenêtre 5 s | `:1119-1133` |

En mode `file` la barre n'offre **que** detect/clear + les trois envois (`:1385-1398`) : ni gain, ni pitch, ni fondus, ni split.

## A8. Lecture (audition)

Trois départs, sur les touches de REAPER (`previewSpan` `:912`, `handleKeys` `:3345-3348`) :

- `Espace` → curseur d'édition (`"cursor"`)
- `Shift+Espace` → début de la sélection (`"sel"`)
- `Ctrl+Shift+Espace` → début du matériau (`"start"`)

`togglePlay` `:976` — en mode `clip` délègue à `clipLaunch`, en mode `midi` fait `Main_OnCommand(40044)`, sinon `Audition.PlaySource` (la **source du take**, donc reverse/section corrects) ou `Audition.Play(path)`.

`pollSection` `:941` réaffirme la section **chaque frame** : la sélection ne gouverne que si `loop` OU `stop_at_sel` OU départ « sel » ; la clôture s'arme à l'**entrée** du playhead dans la sélection (`state.fenced` `:962-971`), donc déplacer la sélection pendant la lecture change ce qui joue.

Autres : bascule `loop` `:1345` (agit sur ce qui joue déjà) ; `thru_track` (route par la piste de l'item, ses FX) `:1010-1011` ; volume de préview 25/50/75/100 % `:1147-1150`.

Curseur de lecture : `playCursorTime` `:1591` — notre préview, **ou** le transport de REAPER quand l'item suivi est sous la tête de lecture ; dessiné couleur `pending` `:2170-2178`.

## A9. Glisser-sortir la sélection

`selectionClip` `:1640` → `Clip.new("audio")` avec `path/offs/len`. Aucun rendu, aucun fichier temporaire.

- Amorce : `Ctrl`+presser **dans** la sélection `:1819-1823` ; promu en drag après 5 px `:1863-1866` ; sous le seuil, retombe sur « ajouter une transitoire » `:1921-1923`.
- Pendant : `DragBus.HoverTarget` d'abord (une fenêtre CP prend le drop), sinon `Insert.ArrangeHit` + item fantôme qui suit la souris `:1659-1682`.
- Relâchement : `DragBus.Drop` ou `Insert.GhostCommit` `:1685-1704`.

## A10. Barre, menus, aide (communs aux deux moitiés)

`barCommon` `:1267` réserve d'abord la **droite** : Help (`UI.ShowHelp` + `HELP_TEXT` `:1174-1256`), Settings, Lock.

Menu Settings `openSettings` `:1141-1170` : snap zéro, cible de normalisation, volume de préview, préview par la piste, « playback stops at the end of the time selection ». **Les cinq entrées sont audio ; le menu s'affiche pourtant à l'identique en mode MIDI/clip** (`barCommon` appelé avant l'aiguillage `:3480`).

Menu contextuel de l'onde (clic droit) `:1936-1957` : Fit, Zoom to selection, Add/Remove/Clear transient, Clear selection, Snap to transients, Snap to zero crossings.

Ligne d'identité `headerLine` `:1285` (non cliquable) + `metaLine` `:721` (durée/canaux/SR, ou nb de notes). Barre d'état `UI.AppStatus` `:3515` avec messages contextuels `:3495-3514` et `flash` (2,5 s) `:175`.

---

# PARTIE B — LA MOITIÉ MIDI / PIANO ROLL (`midi` / `clip`)

## B1. Le modèle et son unité

`Roll` est un cache structure-de-tableaux (`starts/lens/pitches/vels`, `Roll.lua:38-41`) au-dessus d'un **backend** :

- `makeTakeBackend` `Roll.lua:54` — unité **secondes relatives à l'item**, conversion par `MIDI_Get*PPQ*`.
- `makeClipBackend` `CP_Editor.lua:541` — unité **beats (QN)**, tableaux `c.notes.s/l/p/v` édités sur place.

`rollToQN` `:2220` / `qnToRoll` `:2225` cachent laquelle : identité en mode clip, `TimeMap2` sinon.

Protocole d'édition (`Roll.lua:16-20`) : les drags appellent les écrivains *Live* (pas de tri, indices stables), **un seul** `Commit()` au relâchement qui trie + resynchronise + pose l'undo.

`Roll.Sync` `Roll.lua:136` préserve la sélection **par identité (pitch, start en ms)**, jamais par index.

## B2. Les rangées

`rollRows` `:2372` → `Rows.Build` (`Rows.lua:32`), partagé avec CP_Looper.

- **Mélodique** : fenêtre contiguë `view_hi` / `view_rows` (`:2382`), clamps réécrits par Rows.
- **Drum** : liste triée = pads chargés du kit + tous les pitches déjà utilisés ; repli GM 51..36 si vide (`Rows.lua:57-59`).
- Le kit vient de **la cible**, pas du Sampler global : `clipKit` `:2345` → `Loop.KitViewOfTrack`.
- Bascule manuelle : `m_drum` `:2429` ; remise à `nil` (auto) à chaque changement de cible `:374`.
- Étiquettes : `Rows.Label` (nom du pad, sinon nom de note), tronquées et cachées par (texte, largeur) `rowLabel` `:2361`.
- Largeur de la voie : 96 px en drum, 40 px en mélodique `:3076`.

## B3. Grille et aimantation (roll)

- `midiSnap` `:2230` — arrondi au plus proche (déplacements, quantize, règle).
- `midiSnapFloor` `:2241` — **plancher**, sémantique FL : la note naît dans la cellule *sous* le curseur (`:2239-2240`).
- `gridStepSec(t)` `:2251` — un pas de grille en unités de cache.
- Bascule `m_snap` `:2406` ; combo `m_grid` `:2420` — **même liste et même variable `opts.grid_div` que la moitié audio**.
- `Ctrl` pendant un drag ou dans la règle = ignorer la grille (`:2972`, `:2732`).
- Dessin de la grille : `renderRollGrid` `:2541`, quatre passes du plus faible au plus fort — subdivisions, croches, temps, mesures (`:2620-2668`) — quatre jetons de thème (`canvas_line_bar/_beat/_sub/_fine` `:2605-2608`). Les croches ne sont tracées que si elles tombent sur le treillis de la grille (`:2635-2636`). Rangées hors gamme peintes en `canvas_row_off` `:2579-2587`.

## B4. Sélection de notes

| Geste | Effet | Ligne |
|---|---|---|
| clic sur une note | `SelectOnly`, ou `AddSel` avec `Shift` ; une note déjà dans la sélection ne la casse pas | `:2872-2880` |
| `Shift` | additif partout (`add` `:2726`) | |
| clic droit glissé (marquee) | `Roll.SelectBox(ta,tb,plo,phi,additive)` — seuil 4 px | `:2913`, `:2919-2944`, `Roll.lua:194` |
| clic gauche sur l'étiquette de rangée | `Roll.SelectPitch` — toute la rangée | `:2804-2806`, `Roll.lua:207` |
| clic droit sur l'étiquette | audition de la note/du pad | `:2807-2808` |
| `Ctrl+A` | `Roll.SelectAll` | `RollUI.lua:181` |
| `Esc` | `ClearSel` (uniquement si `seln > 0`) | `RollUI.lua:197` |
| `Alt+←/→` | marche sur les notes de **la rangée** de l'ancre | `RollUI.lua:140-179` |
| `Alt+↑/↓` | marche sur toutes les notes en ordre temporel | idem |
| `Shift+Alt+flèches` | étend au lieu de remplacer | `RollUI.lua:174` |

Chaque pas de la marche **auditionne** la note (`RollUI.lua:176`).

## B5. Édition de notes à la souris

| Geste | Effet | Ligne |
|---|---|---|
| clic sur vide | insère à `midiSnapFloor(t)`, longueur = un pas de grille (min 0.1), vélocité `last_vel`, puis **enchaîne sur un resize** (`fresh`) | `:2894-2906` |
| glisser après l'insertion | fixe la longueur ; un clic sec garde la cellule | `:3026-3032` |
| glisser une note (corps) | déplacement, snap sauf `Ctrl` ; audition au changement de pitch | `:2973-3007` |
| glisser le **bord droit** (6 px) | resize ; longueur mini = `ol` pour une note fraîche, sinon ¼ de pas | `:2882-2886`, `:3008-3034` |
| glisser **plusieurs** notes | même delta pour toutes, depuis `snapshotSel` ; en drum le delta vertical est en **rangées** (`Rows.Shift`), en mélodique en demi-tons | `:2978-3000`, `:2695` |
| resize multiple | même delta de longueur | `:3016-3025` |
| clic droit sans mouvement sur une note | supprime (`Roll.Delete`) | `:2945-2949` |
| `Ctrl+Shift`+molette sur une note | **subdivision trap-roll** du run contigu : ×2 / ÷2 jusqu'à 64, 1 = fusion | `:2819-2830`, `noteRun` `:2674`, `Roll.Subdivide:297` |
| voie de vélocité (44 px) | saisit la note dont le **début** est à moins de 6 px, règle la vélocité par le Y ; multi-sélection suivie | `:2955-2966`, `:3035-3043` |

Affordances de pointeur : bord = `size_we`, corps = `size_all`, vide = `cross` (`:3057-3069`).

**Absents** (vérifié par absence) : pas de duplication par `Alt`+glisser, pas d'outil gomme au pinceau (le clic droit est le marquee), aucune voie de CC / pitchbend / aftertouch, aucun éditeur d'expression.

## B6. Commandes clavier (partagées, `RollUI.HandleKey` `:126`)

| Touche | Commande | Ligne |
|---|---|---|
| `Ctrl+A` | select all | `:181` |
| `Ctrl+D` | duplicate, décalage **musical** (`dupOffset` `:75` : mesure si la sélection remplit une mesure, sinon temps, sinon pas de grille, arrondi au-dessus) | `:183`, `doDuplicate:102` |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | copier / couper / coller à `pasteAt` (curseur d'édition relatif, 0 en clip) | `:185-191`, `:2271-2275` |
| `Delete` | supprime la sélection | `:192-194` |
| `Q` | quantize 100 % sur `midiSnap` | `:195` |
| `Esc` | désélectionne | `:197` |
| `↑`/`↓` | transpose ±1 demi-ton, `Shift` = ±12, `Ctrl` = pas de gamme si une gamme est active | `:199-205` |
| `←`/`→` | nudge d'un pas de grille | `:206-208` |
| `Alt`+flèches | marche sur les notes (B4) | `:140` |

Hôte : `Espace` `:3345`, `Home` `:3350`, `+`/`-` `:3351-3352`, `Ctrl+Z` / `Ctrl+Y` **mode `midi` seulement** `:3381-3384`.

Garde : toutes les touches d'édition sont **bloquées pendant un drag** (`midi_edit = midi and not state.mdrag` `:3340`) car un Commit resynchroniserait les index et corromprait `move_snap`.

## B7. Menu Transform (`RollUI.TransformMenu` `:216`, bouton `m_transform` `:2459`)

- **Duplicate / Copy / Cut / Paste** `:228-236`
- **Transpose** : ±octave, ±demi-ton, +quinte `:240-246` → `Roll.Transpose:447`
- **Nudge** gauche/droite d'un pas `:247-250` → `Roll.Nudge:459`
- **Length** : « set to grid » (`Roll.SetLengthAll:471`), « legato (to next) » (`Roll.Legato:484` — étend jusqu'au début de la note suivante, tout pitch confondu) `:251-254`
- **Reverse (time)** dans l'empan de la sélection `Roll.Reverse:506`
- **Invert pitch** autour de la moyenne `Roll.InvertPitch:526`
- **Velocity** : set 127/100/80/64, ramp up/down (`VelocityRamp:567`), compress ×0.6 / expand ×1.4 autour de 64 (`VelocityScale:556`) `:262-272`
- **Humanize** light/medium/heavy — jitter borné et **graine reproductible** (Park–Miller, `Roll.lua:361-363`, `Humanize:584`) `:273-277`
- **Quantize** 100/66/50 % (force partielle, `Roll.Quantize:323`) + **Swing 8 % / 16 %** via `ctx.swingSnap` `:2307-2317`
- **Scale** : racine 0–11, 13 gammes (`Roll.SCALES:744`), « snap selection to scale » (`SnapToScale:794`) `:294-315`
- **Chord from note** : 11 accords (`Roll.CHORDS:759`), l'intervalle 0 est retiré pour ne pas doubler la fondamentale `:318-331`
- **Arpeggiate** up/down/updown/random × 1/8, 1/16, 1/16T, 1/32 — cuisson hors ligne, plafond 512 notes `:334-352`, `Roll.Arpeggiate:850`
- **Euclidean fill** 3/8, 4/8, 5/8, 5/16, 7/16, 9/16 sur l'empan de la sélection `:355-369`, `Roll.Euclidean:904`

Règle générale (`Roll.lua:348-352`) : chaque op agit sur **la sélection s'il y en a une, sinon sur tout**, et pose **un seul** point d'undo.

## B8. Barre MIDI (`barMidi` `:2404`)

`m_snap` (aimant) · combo `m_grid` · `m_drum` · `m_names` (noms de notes dans les notes, `:3216-3220`) · `m_aud` (écoute, paire d'icônes) · `m_vel` (vélocité par défaut 1–127) · `m_quant` (quantize) · `m_transform` · `m_native` (ouvre l'éditeur MIDI natif, action 40153 — **take seulement**, `:2462-2468`).

**Il n'y a ni bouton Play ni bouton Loop en mode `midi`** : `Espace` passe par le transport de REAPER (`:983`).

## B9. Règle, time selection, curseur (mode `midi` seulement)

Contrairement à la moitié audio, le roll manipule les **objets natifs de REAPER** (`GetSet_LoopTimeRange`, `GetCursorPosition`) :

| Geste | Effet | Ligne |
|---|---|---|
| clic vide dans la règle | pose le curseur d'édition + **efface** la time selection, puis glisse pour en créer une | `:2758-2763`, `:2771-2777` |
| glisser un bord (±6 px) | redimensionne | `:2750-2753`, `:2778-2785` |
| glisser le corps | déplace la plage, **le résultat est snappé**, pas le point de saisie | `:2754-2755`, `:2786-2792` |
| glisser le fanion du curseur (±5 px) | scrub du curseur d'édition | `:2756-2757`, `:2770-2771` |
| `Ctrl` | ignore la grille | `:2732`, `:2768` |

En mode `clip` la règle est **inerte** (`:2720`) : pas de time selection, pas de curseur d'édition, pas de playhead transport (`:3246`, `:3275`, `:3287`).

## B10. Zoom et navigation du roll (`:2813-2868`)

| Geste | Effet | Ligne |
|---|---|---|
| molette nue | scroll **vertical** (20 % de la fenêtre) | `:2848-2854` |
| `Shift`+molette | zoom **horizontal** au pointeur | `:2831-2833` |
| `Alt`+molette | scroll horizontal (15 % de l'empan) | `:2834-2835` |
| `Ctrl`+molette | zoom **vertical** autour du pitch survolé, 6 à 100 rangées | `:2836-2847` |
| `Ctrl+Shift`+molette sur une note | subdivision (B5) | `:2819-2830` |
| bouton du milieu | pan horizontal | `:2858-2867` |
| `Home` | fit | `:3350` |

À l'ouverture, la vue verticale s'ajuste aux notes (18 à 48 rangées, défaut C3–B4 si vide) — `:604-611` (mode midi) et `:683-693` (mode clip), **code dupliqué à l'identique**.

## B11. Audition des notes

`auditionNote` `:2199` → `Kit.StuffNote` → `StuffMIDIMessage` sur la file VKB (`Kit.lua:1572`). Note-off différé de 200 ms, servi dans `frame` `:3466-3470`. Déclenché par : insertion, clic sur note, changement de pitch en drag, clic droit sur l'étiquette de rangée, marche `Alt`+flèches, transpose au clavier.

**Incohérence vérifiée** : les noms de rangées viennent du kit **de la cible** (`clipKit` `:2345`) mais le son part sur la file VKB, qui atteint la piste **armée** — c'est-à-dire l'instrument affiché dans CP_Sampler (`Kit.lua:1577-1588`). On peut donc lire « Kick 2 » et entendre autre chose.

## B12. Le mode `clip` — ce qu'il ajoute

| Fonction | Ce qu'elle fait | Ligne |
|---|---|---|
| `setClip` | attache le backend clip, résout `clip_track` depuis `origin = "looper:N"`, `clip_tag` via `Ident.TagOf`, **ne mémorise pas la lane** (elle est redemandée chaque frame) | `:649-697` |
| résolution de lane | une fois par frame : `Loop.IsAttached` + `Loop.LaneOfTag` | `:3416-3435` |
| `scheduleApply` / `flushApply` | publication débouncée 250 ms : écriture **directe** dans la lane (`Loop.ApplyClip`) + message bus `editor:apply` ou `editor:apply:cell` | `:428-451` |
| combo `c_bars` | 1/2/4/8/16/32 mesures → `setClipBars` `:455`, redimensionne la lane vivante | `:2473-2481` |
| bouton `c_play` | transport de la lane : annule un lancement en attente, arrête l'autre moitié de la piste, promeut une lane « vide » en « stoppée avec contenu » | `:2482-2505`, `clipLaunch` `:476-539` |
| playhead clip | phase du moteur en beats, couleur `canvas_playhead` | `:3299-3310` |
| suivi de longueur | si le Looper change la longueur de la lane, `clip.bars` et la vue suivent | `:3449-3456` |
| `metaLine` clip | « N notes · X beats · K past the loop (kept, silent) » — les notes au-delà de la boucle sont conservées | `:727-740` |

---

# PARTIE C — CE QUI EST ANNULABLE, ET CE QUI NE L'EST PAS

**Annulable (point d'undo REAPER)**

- Audio : normalize `Ops.lua:184`, gain `:191`, pitch `:219`, rate `:231`, reverse (action native 41051 `:206`), trim to selection `:295`, split at transients (bloc `:303-312`), fondus **au relâchement** (`Ops.CommitFades:241`, appelé `:1925`), bord d'item **au relâchement** (`Ops.CommitTrim:286`, appelé `:1917`).
- Envois Sampler : `Kit.Batch` ouvre/ferme un bloc d'undo (`Kit.lua:1730`) — `:1073`, `:1107`.
- MIDI **sur take** : tout, via `be.undo = Undo_OnStateChange` (`Roll.lua:98`) — insert `:253`, delete `:262`, deleteSel `:224`, chaque `Commit` de drag `:292`, subdivide `:312`, quantize `:342`, et les ~20 ops de la couche commande. `Ctrl+Z` / `Ctrl+Y` internes `:3382-3383`.

**Non annulable**

1. **Toute édition de clip** (mode `clip`). Le backend clip a `undo = function() scheduleApply() end` (`CP_Editor.lua:583`) : il publie, il n'enregistre rien. Et `Ctrl+Z` est explicitement réservé à `state.mode == "midi"` (`:3381`). Une lane du Looper ou une cellule de Session éditée ici est modifiée **définitivement** — y compris `Humanize`, `Arpeggiate` ou `Euclidean`, qui remplacent tout.
2. Les transitoires : ajout, déplacement, suppression, effacement global — commentaire explicite `:1918-1920` (« markers live in this window, not in the project »).
3. La sélection audio, le curseur d'édition audio, le zoom, la vue verticale, le verrou.
4. Toutes les options (`opts`, `sens`, `last_vel`, volume de préview) : persistées dans la config `persistConfig` `:154`, jamais dans l'undo.
5. `setClipBars` (longueur de boucle) et `clipLaunch` (transport).

---

# PARTIE D — DÉCLARÉ MAIS MORT

**Dans `CP_Editor.lua`**

- `gridLabel()` `:2320-2334` — **jamais appelée**. La chaîne « Grid 1/16 (proj) » qu'elle construit n'est affichée nulle part ; le cache `grid_lbl` est pourtant invalidé consciencieusement en deux endroits (`:1378`, `:2423`). Vestige de l'ancienne barre.
- Commentaire de `state.mdrag` `:132` : `mode="move"|"resize"|"vel"|"erase"` — **`"erase"` n'est jamais produit** (les seuls producteurs sont `:2883`, `:2887`, `:2904`, `:2963`).
- Commentaire de `state.wpress` `:129` : annonce 3 `kind`, il y en a **9** (`sel`, `sel_a`, `sel_b`, `dragout`, `mark`, `trim_a`, `trim_b`, `fadein`, `fadeout`).

**Dans `Roll.lua` — quatre commandes sans aucun appelant** (vérifié sur tout le dépôt) :

- `Roll.SelectInvert` `:417`
- `Roll.SelectSimilar(mode, tol)` `:431` — sélection par vélocité / longueur / pitch similaires
- `Roll.Glue()` `:680` — fusion des notes de même pitch qui se touchent
- `Roll.SplitAt(at)` `:720` — coupe les notes qui traversent un temps

Les quatre sont écrites, correctes et non exposées : ni dans le menu Transform, ni dans la carte clavier, ni dans CP_Looper. `Glue` et `SplitAt` sont d'autant plus visibles que la moitié audio, elle, a un « split at markers ».

**Dans `RollUI.lua`**

- `RollUI.GRID_ALPHA = nil` `:394` — pierre tombale assumée (commentaire `:387-393`), mais l'assignation reste dans le module.
- `RollUI.SelSpan` `:51` et `RollUI.DupOffset` `:98` — exportées, aucun consommateur externe (usage purement interne).

**Dans `Peaks.lua`**

- `Peaks.InvalidateView` `:116` et `Peaks.Invalidate(path)` `:336` — **aucun appelant dans tout le dépôt**. L'éditeur invalide par `state.gen` (`:379`, `:392`, `:879`) et n'utilise donc jamais ces deux portes.
- `Peaks.Get` / le cache LRU `:239-332` n'est utilisé que par CP_MediaExplorer ; `Peaks.Building` uniquement par lui aussi (`CP_MediaExplorer.lua:1914`). Ce n'est pas mort, mais c'est mort **pour l'éditeur**.

**Dans `Ops.lua`**

- Le module vit dans `CP_Engine/` (les capacités partagées) mais **CP_Editor est son seul client** — vérifié par grep sur tout le dépôt. `Ops.PeakInRegion` `:31` n'est appelée que par `Ops.Normalize` `:179`.

---

# PARTIE E — CE QUI EXISTE EN DOUBLE

## E1. Entre `Roll.lua` / `RollUI.lua` et l'éditeur

1. **Quantize a trois portes** pour un seul comportement : le bouton `m_quant` `:2455-2458`, la touche `Q` (`RollUI.lua:195`), et Transform → Quantize → 100 % (`RollUI.lua:280`). Les trois appellent `Roll.Quantize(midiSnap)`. Le bouton et la touche perdent au passage l'option de force partielle et le swing.
2. **Duplicate a deux portes** : `Ctrl+D` (`RollUI.lua:183`) et Transform → Duplicate (`RollUI.lua:228`) — même `doDuplicate`, celle-là est une vraie factorisation.
3. **Trois tables de noms de notes** pour la même chose :
   - `CP_Editor.lua:2187-2193` (`NOTE_NAMES`, 0..127, utilisée pour le dessin et le statut)
   - `Rows.lua:107-113` (`NOTE_NAME` + `Rows.NoteName`, utilisée par `Rows.Label`)
   - `RollUI.lua:33` (`NOTE`, 12 entrées, pour le menu Scale)
   L'éditeur charge pourtant `Rows` et pourrait lire `Rows.NoteName`.
4. **`Rows.AtY` / `Rows.PitchAtY` existent, l'éditeur ne les appelle pas** : il refait le calcul à la main en trois endroits — `:2723` (`row = floor((my-wave.ry)/row_h)+1`), `:2930-2931` (marquee). CP_Looper, lui, utilise `Rows.PitchAtY` (`CP_Looper.lua:1329`). Deux hôtes, deux façons de faire la même conversion.
5. **`noteRun` `:2674` recoupe `Roll.Glue`** : les deux détectent des notes de même pitch adjacentes. `noteRun` est un scan O(n²) local à l'éditeur ; `Glue` fait le même regroupement dans la couche partagée, et est morte.
6. **Collision de nom** : `Roll.SplitAt(at)` (`Roll.lua:720`, découpe une note) et `Ops.SplitAt(item, take, times)` (`Ops.lua:300`, découpe un item). Domaines différents, nom identique, et l'un des deux est mort.
7. Le **presse-papiers `Roll.clip`** (`Roll.lua:634`) est déclaré partagé entre les deux hôtes, mais CP_Editor et CP_Looper sont deux ReaScripts, donc deux états Lua : `Ctrl+C` dans l'éditeur ne se colle pas dans le Looper. La carte clavier est identique, le contenu ne circule pas. (Déduit du modèle d'exécution ReaScript — pas d'IPC de clipboard dans `Bus.lua` pour ce canal.)

## E2. À l'intérieur de l'éditeur, entre les deux moitiés

8. **Deux implémentations de snap sur la même grille** : `waveSnap` `:245` (domaine source, aller-retour `srcToProj`/`projToSrc`, plus les transitoires) et `midiSnap` `:2230` / `midiSnapFloor` `:2241` (domaine roll, `rollToQN`/`qnToRoll`). Les deux lisent `gridStepQN()` `:197` — la division est bien unique, l'arithmétique est écrite deux fois.
9. **Deux constructeurs de grille dessinée** : `wgridBuild` `:1495` (audio, deux poids, plafond 400) et `renderRollGrid` `:2541` (roll, quatre passes, quatre jetons). Le roll a la hiérarchie mesure/temps/croche/subdivision ; l'onde n'a que mesure/division.
10. **Deux notions de sélection temporelle et deux curseurs** : l'audio a les siens, locaux (`sel_a/sel_b` `:124`, `cursor` `:125`) ; le roll utilise ceux de REAPER (`GetSet_LoopTimeRange` `:2733`, `GetCursorPosition` `:2737`). Passer d'un item audio à un item MIDI change donc de vocabulaire sans le dire.
11. **Deux blocs identiques d'ajustement vertical** à l'ouverture : `:604-611` (mode midi) et `:683-693` (mode clip) — même code, copié.
12. **Deux voies de suppression de sélection au clavier** selon la moitié : `Esc` efface la sélection audio `:3353`, `Esc` désélectionne les notes `RollUI.lua:197` — cohérent, mais `Delete` fait deux choses sans rapport (transitoire `:3366` / notes `RollUI.lua:192`).
13. `sl_detect` / `sl_clear` / `sl_pads` / `sl_selpad` / `sl_instr` sont écrits **deux fois** dans `barAudio` : une fois pour le mode `file` `:1386-1397`, une fois pour le mode `item` `:1438-1453`, avec les mêmes identifiants de widget.