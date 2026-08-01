## Éditeurs de clip — Ableton / FL / REAPER, et ce qui vaut la peine d'être écrit ici

---

# 0. Base de comparaison : ce que le roll CP fait aujourd'hui (vérifié dans le code)

Modèle `CP_Engine/Roll.lua` — cache SoA à **quatre champs par note** : `starts / lens / pitches / vels` (Roll.lua:32-45). Pas de canal, pas de mute, pas de probabilité, pas d'expression par note. Sérialisation clip identique : `"s,l,p,v;…"` (Clip.lua:115-116, Clip.lua:168-198). Moteur natif identique : `struct LaneNote { float start; float len; uchar pitch; uchar vel; uchar pad[2]; }` (CP_Native/src/core/cp_lanes.h:114-120) — **avec deux octets libres déjà réservés**. Lanes gmem : `Loop.NOTE_STRIDE = 4` (Loop.lua:48).

Opérations déjà écrites (Roll.lua) : `SelectAll/SelectInvert/SelectSimilar` (415-443), `Transpose/Nudge/SetLengthAll/Legato/Reverse/InvertPitch` (447-543), `VelocitySet/VelocityScale/VelocityRamp/Humanize` (547-608, PRNG Park-Miller reproductible 362-363), `Duplicate/Copy/Cut/Paste/Glue/SplitAt/Subdivide` (614-740, 297-314), `Quantize(snap_fn, strength)` (323-345), 13 gammes + 11 accords (741-766), `SnapToScale/TransposeInScale/InsertChord` (794-843), `Arpeggiate` 4 modes (850), `Euclidean` (904).

Gestes (CP_Editor.lua) : clic vide = insertion + drag-resize immédiat (2872-2905), clic droit = suppression, drag droit = marquee, **Ctrl+Shift+molette sur une note = subdivision « trap roll »** (2820-2833), lane de vélocité 44 px (2195) qui saisit la note la plus proche à 6 px (2954-2970), Ctrl pendant un drag = bypass du snap. Clavier partagé (RollUI.lua:126-211) : Ctrl+A/C/X/V/D, Suppr, Q, Échap, flèches, **Alt+flèches = marche de note à note avec audition** (135-179).

Deux défauts vérifiés au passage, indépendamment de toute comparaison :
- **Roll.lua:77** — `MIDI_InsertNote(take, false, false, ppq, ppq, 0, pitch, vel, true)` : le canal est **codé en dur à 0**. Sur un take dont les notes sont canal 3, toute note insérée part canal 1 — et le filtre de canal de l'éditeur natif la fera disparaître. `setNote` (Roll.lua:94) passe `nil` donc ne détruit rien, mais l'insertion, si.
- **CP_Editor.lua:2620-2626** — la passe 1 de la grille dessine jusqu'à **4096 `gfx.line`** sans cull au pas de pixel. Le buffer est caché (clé `wbm`) mais se reconstruit à chaque frame d'un pan ou d'un zoom. REAPER, lui, applique un espacement minimal en pixels (whatsnew.txt v7.xx : « MIDI editor: use project grid setting for grid line minimum pixel spacing »). C'est le seul point de ce document qui soit à la fois un gain de perf et un gain de lisibilité.

---

# 1. ABLETON — l'éditeur MIDI du Clip View

## 1.1 Grille, dessin, sélection

| Fonction | État chez Ableton | Ici |
|---|---|---|
| Grille adaptative (densité suit le zoom) vs fixe | **vérifié** ([shortcuts 41.13](https://www.ableton.com/en/live-manual/12/live-keyboard-shortcuts/)) : Ctrl+1 Narrow, Ctrl+2 Widen, Ctrl+3 Triplet, Ctrl+4 Snap, **Ctrl+5 Fixed/Zoom-Adaptive** | division fixe ou projet, combo + molette (CP_Editor.lua:2420). **Pas d'adaptatif** |
| Draw Mode (B) | **vérifié** ([Editing MIDI](https://www.ableton.com/en/live-manual/12/editing-midi/)) : clic-glissé pose des notes ; en Draw Mode un clic sur une note existante **la supprime** ; préférence « Draw Mode with Pitch Lock » — activée = une seule touche à la fois, désactivée = dessin mélodique libre, Alt force le verrouillage | pas de mode dessin : clic = une note, drag = longueur. Pas de peinture continue |
| Marquee / sélection de plage de temps | **vérifié** : le drag sélectionne des notes **ou une plage de temps** | `Roll.SelectBox` par marquee droit (2915-2952). Pas de sélection de plage de temps comme portée d'opération |
| Shift+clic sur la touche du piano = toute la ligne | **vérifié** | `Roll.SelectPitch` sur clic gauche dans la lane de labels (CP_Editor.lua:2807-2812) — **déjà là, et en un clic au lieu de Shift+clic** |
| **Find and Select Notes** — 8 filtres : Pitch, Time, Chance, Condition, Count (« every nth note or chord »), Duration, Scale, Velocity, chacun avec Invert | **vérifié** | `Roll.SelectSimilar(mode, tol)` (Roll.lua:431) couvre une fraction |
| Fold to Notes (F) / Fold to Scale (G) / Highlight Scale (K) | **vérifié** | mode Drum plie implicitement (Rows.lua:43-56 : pads du kit + hauteurs réellement utilisées). Le mode **mélodique ne plie pas** (Rows.lua:60-67 = fenêtre contiguë). Les rangs hors gamme sont juste teintés (CP_Editor.lua:2581-2589) |

## 1.2 Édition de notes

Tout **vérifié** ([Editing MIDI](https://www.ableton.com/en/live-manual/12/editing-midi/)) :
- Déplacement souris + flèches ; **Alt+flèches = nudge hors grille** ; Ctrl+drag = copie, y compris décidée **en cours de drag**.
- Longueur par les bords ; Shift+flèches = allonge/raccourcit d'un pas de grille ; +Alt = hors grille.
- **Note Stretch markers** : dès qu'une sélection multiple ou une plage existe, des poignées apparaissent sous la zone de scrub et mettent la sélection à l'échelle **proportionnellement** ; entre deux poignées apparaît un « pseudo » marqueur qui étire la matière comprise entre elles.
- **Split** : maintenir E et tracer un trait à travers les notes ; ou Ctrl+E sans sélection = coupe à l'insert marker.
- **Chop** : Ctrl+E sur sélection découpe sur la grille, et **en gardant Ctrl, les flèches haut/bas changent le nombre de parts** ; variante souris E+Ctrl puis drag vertical.
- **Join** : Ctrl+J fusionne les notes de même hauteur.
- **Deactivate** : touche `0` — la note grise ne joue plus.
- Quantize : Ctrl+U, Ctrl+Shift+U pour les réglages, l'outil Quantize a un **Amount** en pourcentage.

Comparaison honnête : **Chop/Join/Split, ici, sont déjà là et le geste est meilleur.** `Roll.Subdivide` piloté à la molette (Ctrl+Shift+molette, CP_Editor.lua:2820-2833) fait en une molette ce qu'Ableton fait en Ctrl+E puis flèches ; `Roll.Glue` (680) = Join ; `Roll.SplitAt` (720) = Split. Ce qui manque vraiment de cette liste : **Note Stretch** (mise à l'échelle proportionnelle d'une sélection) et **la désactivation de note**.

## 1.3 Vélocité, Chance, MPE

- **Velocity Editor** — **vérifié** : saisie numérique au clavier, Ctrl+flèches = ±10, **Randomize + Randomization Amount**, **Ramp Start / Ramp End sliders**, dessin en Draw Mode, Alt = ligne droite. → Ici, `VelocityRamp`, `VelocityScale`, `Humanize` existent déjà côté modèle (Roll.lua:556-608) ; **c'est le geste dans la lane qui manque** (pas de peinture, pas de rampe au drag).
- **Velocity Deviation** — **vérifié** : un intervalle par note, tiré au hasard **à chaque lecture**. Aucun équivalent ici, et aucun dans REAPER.
- **Chance Editor** — **vérifié** : probabilité 0-100 % par note, randomisation relative, et **groupes de probabilité Play All (losange) / Play One (triangle)**, Ctrl+G. C'est la fonction la plus distinctive d'Ableton sur ce terrain.
- **Release velocity** — lane séparée, **vérifié**, marqué « esotérique » par le manuel lui-même.
- **MPE** — **vérifié** ([Editing MPE](https://www.ableton.com/en/live-manual/12/editing-mpe/)) : cinq dimensions (Pitch, Slide, Pressure, Velocity, Release Velocity), onglet Note Expression (Alt+3), enveloppes à breakpoints par note, Alt+drag courbe un segment, double-clic le redresse, Alt+clic aimante le Pitch au demi-ton. Outils MPE : **Glissando** et **LFO**.
- **CC / contrôleurs** — point important et souvent mal compris : **Live n'a pas de lane de CC**. Les CC vivent dans l'onglet **Envelopes**, chooser « MIDI Ctrl », contrôleurs jusqu'à 119, édition par breakpoints, et l'enveloppe peut être **déliée** de la boucle du clip (boucle/région propres) — **vérifié** ([Clip Envelopes](https://www.ableton.com/en/live-manual/12/clip-envelopes/)). C'est structurellement plus pauvre que REAPER (pas de courbes par segment nommées, pas de 14 bits explicite) mais plus riche sur un point : l'enveloppe déliée fait un LFO qui traverse plusieurs répétitions du clip.

## 1.4 MIDI Tools de Live 12 (Transform / Generate) — **vérifié** ([MIDI Tools](https://www.ableton.com/en/live-manual/12/midi-tools/))

**Transformations** : Arpeggiate (18 styles, Distance, Steps, Rate, Gate) · Chop (2-64 parts, gaps, emphasis, stretch chunks, variation) · Connect (interpole entre les notes : Spread, Density, Rate, Tie) · Ornament (flam / grace notes : position, vélocité, chance, amount) · Quantize (grille + Amount) · **Recombine** (permute une dimension parmi Position/Pitch/Duration/Velocity : shuffle, mirror, rotate) · Span (legato/tenuto/staccato par offset de grille + variation) · **Strum** (décale les départs d'un accord : Strum Low, Strum High, **Tension** par breakpoints) · Time Warp (courbes de vitesse à 1-3 breakpoints) · Velocity Shaper (M4L) · Glissando et LFO (MPE).

**Générateurs** : Rhythm (16 pas, pattern, density, split, shift, accents) · Seed (aléatoire borné : pitch min/max, durée, vélocité, voices, density) · Shape (notes le long d'une forme : presets, rate, tie, density, jitter) · **Stacks** (accords et progressions dans la gamme active, pad de sélection basé sur le **Tonnetz**) · Euclidean (M4L, 4 voix).

**Le panneau lui-même** : **Auto Apply activé par défaut** — chaque changement de paramètre se voit immédiatement dans le roll — plus un bouton Apply, des Reset, et Ctrl+Entrée pour appliquer. **C'est ça, la vraie idée**, pas la liste d'outils : les transformations sont *paramétrées et prévisualisées*, pas des commandes de menu à valeur fixe.

Face à ça, `RollUI.TransformMenu` (RollUI.lua:216-371) expose des **valeurs figées** : Humanize Light/Medium/Heavy, 6 presets euclidiens, 4 modes d'arpège × 4 rates, Compress 0.6 / Expand 1.4. Or `Roll.Humanize(tAmt, vAmt, lAmt)` et `Roll.Euclidean(a, b, pitch, steps, pulses, vel, rotation)` sont **déjà paramétriques**. L'écart Ableton/CP sur ce chapitre n'est donc pas dans le modèle, il est dans les 40 lignes d'UI au-dessus.

## 1.5 Multi-clip

**Vérifié** : jusqu'à 8 clips MIDI édités ensemble, loop bars colorées au-dessus du roll, **Focus Mode (N)** — le clip actif en couleur, les autres en gris et non éditables ; N maintenu bascule momentanément. En Arrangement, on peut dessiner à travers les frontières de clips.

---

# 2. FL STUDIO — seulement ce qu'il a et qu'Ableton n'a pas

(Le piano roll FL est couvert par un autre agent ; je ne liste que le delta.)

1. **Propriétés par note bien plus larges** — **vérifié** ([manuel Piano roll](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm)) : velocity, **panning (PAN)**, **release (REL)**, **Mod X (cutoff)**, **Mod Y (résonance)**, fine pitch, et une **couleur de note = canal MIDI**. Ableton n'a que vélocité, release velocity, chance et l'expression MPE. FL fait passer du timbre par note **sans MPE**, ce qui est beaucoup moins cher à implémenter que MPE.
2. **Slide notes et portamento** — **vérifié**, même URL : une slide note fait glisser la hauteur des notes au-dessus/au-dessous vers la sienne. Ableton n'a pas d'équivalent hors MPE/Glissando.
3. **Ghost notes venant d'autres patterns** — **vérifié** : « Those within the same Pattern (Solid blocks) and those from other Patterns (Open Blocks) ». Le multi-clip d'Ableton est comparable mais borné à 8 clips et pensé pour l'édition, pas pour la référence visuelle permanente.
4. **Riff Machine (Alt+E)** — **vérifié** ([Riff Machine](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_riff.htm)) : un pipeline d'étapes chaînées (dont Levels, qui randomise pan/velocity/release/mod X/Y/pitch) — plus intégré que les MIDI Tools d'Ableton, qui s'appliquent un à la fois.
5. **Strumizer (Alt+S)** — **vérifié** ([Strum](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_strum.htm)) : strength **et** tension, sur le début **et** la fin des notes. Le Strum d'Ableton n'agit que sur les départs.

Ce qui compte pour ce projet dans cette colonne : **(1) et (3)**. Le point (1) parce que `LaneNote` a déjà deux octets libres ; le point (3) parce que la Session, ici, est une grille où « les autres clips de la même scène » est une notion native.

---

# 3. REAPER — la colonne décisive

## 3.1 Ce que l'éditeur natif fait très bien, et qu'il ne faut pas réécrire

Sources : liste d'actions officielle extraite du langpack local `C:\Users\Cedric\AppData\Roaming\REAPER\LangPack\MIDI Editor actions (active take only) vs (all editable).ReaperLangPack` (section `[midi_actions]`, ~180 actions en clair), plus le changelog officiel `https://www.reaper.fm/whatsnew.txt` (téléchargé, v7.78 → v0.20).

- **Les lanes de CC.** Formes de courbe par événement avec préférences par lane (`MIDI editor: add CC shape preferences to MIDI CC lane context menu`), **CC 14 bits** avec appairage et indicateurs de présence, **lane Poly Aftertouch qui suit la sélection de notes**, presets de lanes CC/vélocité natifs avec actions load/save, réordonnancement par drag/drop des en-têtes, option de griser les CC / de les cacher dans les contextes secondaires. **Vérifié** (whatsnew.txt, entrées `MIDI editor: add native CC/velocity lane preset support`, `add support for Poly Aftertouch CC lane`, `allow reordering velocity/CC lanes via drag/drop of header`, `14-bit CC editing fixes`). API : `MIDI_GetCCShape / MIDI_SetCCShape`.
- **La notation.** Éditeur de partition avec **deux articulations + un ornement par note**, dynamiques, pédale, octaviation, export PDF. **Vérifié** (whatsnew.txt, `Notation editor: support two articulations plus one ornament per note`, `Notation: fix font sizes of PDF export`).
- **Les canaux MIDI.** 16 actions « Set events to channel NN », 16 « Set channel for new events to NN », channel higher/lower, et le filtre d'événements. **Vérifié** (langpack).
- **La précision au clavier.** Move/lengthen/shorten **d'un pixel** ou **d'une unité de grille**, `Note velocity ±01 / ±10`, `Move left/right edge of note to edit cursor`, `Trim left/right edge to edit cursor`, `set note length to 1/128…1` selon le type de division courant, `Fit notes to time selection`, `Set time selection / loop points to selected notes`, navigation `Select previous/next note with same pitch`. **Vérifié** (langpack).
- **Le multi-item.** « Contextes éditables » multiples, avec préférence d'opacité des contextes secondaires et option de masquer leurs CC. **Vérifié** (whatsnew.txt v7.7x).
- **Snap to key + Scale Finder.** `MIDI editor: add action to toggle snap to key signature`, `expose key snap root/type in options menu`, `Scale Finder: dialog for finding scales that contain a given set of notes`, `Scale finder: button to use selected notes in MIDI editor`, **fichiers de gammes et d'accords définissables par l'utilisateur (.ReaScale)**, `MIDI editor: actions to invert chord voicings`, et — détail qui montre le soin — `disregard snap to key when in named notes (drum map) mode`. **Vérifié** (whatsnew.txt).
- **Les modificateurs de souris entièrement remappables**, y compris un modificateur **arpeggiate** : `mouse modifier to stretch MIDI note selection horizontally (arpeggiate) respecting snap`, `arpeggiate movement is based on number of selected notes`, `mouse modifiers to arpeggiate legato`. **Vérifié** (whatsnew.txt). C'est l'équivalent REAPER du Note Stretch d'Ableton.
- **Divers déjà écrits** : `Humanize notes…`, `Quantize…` + `Unquantize`, `Split notes on grid`, `Join notes`, `Make notes legato (preserving note start times / relative spacing)`, `Reverse selected events`, `Correct overlapping notes`, `Delete all notes of less than 1/8…1/256`, `Mute events (toggle)`, `Select all muted notes`, `Show raw MIDI data`, vue liste d'événements, éditeur inline dans l'arrangement, `Note properties`. **Vérifié** (langpack).

**Conclusion de cette sous-section : lanes de CC, notation, liste d'événements, sysex/texte, canaux, 14 bits, formes de courbe, propriétés d'événement, remapping de souris — tout cela est du travail perdu s'il est réécrit ici.** Le bouton existe déjà : CP_Editor.lua:2462-2468, `Main_OnCommand(40153)`.

## 3.2 Ce que REAPER ne fait PAS, vérifié par l'absence dans deux sources

- **Aucune probabilité / chance par note.** Zéro occurrence de `probabilit` dans whatsnew.txt hors ReaSamplomatic5000, zéro action dans le langpack. Le sujet n'existe que comme demande sur le forum Cockos (t=257246).
- **Aucune édition MPE / expression par note.** Zéro occurrence de « MPE » ou « polyphonic expression » dans whatsnew.txt.
- **Aucun quantize à groove natif.** Zéro entrée « groove » dans le changelog hors mentions VST. Le dossier `REAPER/Grooves` de cette machine (`.rgt`) vient de l'extension **SWS/FNG**, pas de REAPER — **vérifié** ([KVR, Midi Groove Template in Reaper?](https://www.kvraudio.com/forum/viewtopic.php?t=381799)).
- **Aucun cadre de génération/transformation paramétrée.** Rien d'euclidien, rien de « Seed/Shape/Stacks », pas d'arpège offline (l'arpeggiate de REAPER est un *étirement* de sélection, pas un dépliage d'accord), pas de Recombine, pas de Strum, pas d'Ornament.
- **Aucune notion de clip/session.** L'éditeur natif édite un **take dans un item sur la timeline**. Point.

## 3.3 Le vrai argument d'existence, et il n'est pas esthétique

**Une cellule de CP_Session / une lane de CP_Looper n'est pas un take.** C'est un descripteur `Clip` (Clip.lua) ou un tampon `LaneNote` dans le binaire (cp_lanes.h:114-120). L'éditeur natif de REAPER ne peut pas l'ouvrir — et le code le sait déjà : le bouton « Open in REAPER's MIDI editor » est **conditionné à `state.item`**, avec le commentaire exact « take-backed only (a clip has no native editor) » (CP_Editor.lua:2462).

Cela partage le problème en deux moitiés qui n'ont pas la même réponse :

| | Mode **item/take** | Mode **clip** (Session/Looper) |
|---|---|---|
| Alternative native | l'éditeur MIDI complet, à un bouton | **aucune** |
| Ce qui justifie du code ici | seulement ce qui est *partagé* avec le mode clip, donc gratuit | tout ce qui est nécessaire pour éditer une cellule |
| Ce qui ne le justifie pas | CC, notation, canaux, liste, 14 bits, MPE | idem (et en plus le stockage ne les porte pas) |

Corollaire opérationnel : **toute opération ajoutée à `Roll` sert les deux hôtes et les deux backends** (c'est déjà l'architecture, Roll.lua:22-31 et ANALYSE_Interactions.md:24). Toute *lane* ou *vue* nouvelle ne sert que l'un ou l'autre et double le travail. Le rapport effort/effet penche donc massivement vers **les opérations sur la liste de notes**, et contre **les vues d'événements non-notes**.

---

# 4. Ce qui vaut la peine d'être écrit ici — classé

**Rang 1 — le panneau Transform paramétré (l'idée d'Ableton, pas sa liste).**
Ce qu'il fait : un panneau non modal avec les paramètres réels des ops déjà écrites (Humanize t/v/l, Euclidean steps/pulses/rotation, Arpeggiate rate/mode/gate/octaves, Quantize strength/swing), **prévisualisation immédiate** façon Auto Apply, bouton Apply. Coût : le modèle est déjà paramétrique (Roll.lua:584, 850, 904, 323) ; il faut un snapshot/restore pour la preview — `Roll.Copy()` (635) fait déjà le snapshot. Coût réel : UI + une boucle « restore puis ré-applique », O(n) par changement de paramètre, jamais dans le chemin de frame. Contre quoi ça rivalise : rien côté REAPER (aucun cadre équivalent), et ça rend rentables les 3 ops génératives déjà écrites qui sont aujourd'hui bridées par des presets de menu.

**Rang 2 — grille adaptative + cull au pas de pixel.**
Ce qu'il fait : ne pas dessiner une ligne quand deux lignes voisines sont à moins de N pixels ; borne haute réelle au lieu de `n > 4096` (CP_Editor.lua:2626). Coût : ~10 lignes dans `renderRollGrid`, à répliquer dans le roll du Looper. Contre quoi : c'est exactement ce que fait REAPER (« grid line minimum pixel spacing », vérifié) et Ableton (Zoom-Adaptive Grid, Ctrl+5, vérifié). Gain double : lisibilité **et** perf sur le PC de 2005, pendant les pans et les zooms, qui sont précisément les moments où le buffer se reconstruit.

**Rang 3 — Fold mélodique + Fold to Scale.**
Ce qu'il fait : `Rows.Build` construit déjà une liste arbitraire de hauteurs en mode drum (Rows.lua:43-56). Étendre la même branche au mode mélodique avec deux filtres — « seulement les hauteurs utilisées » (F d'Ableton) et « seulement les degrés de la gamme » (G d'Ableton) — donne les deux fonctions d'un coup. Coût : une dizaine de lignes dans Rows.Build + deux toggles ; `Rows.Shift` (98-104) fait déjà bouger les notes par rang, donc le drag reste correct sur une liste non contiguë. Sert les deux hôtes. Contre quoi : REAPER a le note folding, mais pas en mode clip.

**Rang 4 — les gestes manquants dans la lane de vélocité.**
Ce qu'il fait : peindre les vélocités au drag horizontal, et rampe au Alt+drag (la ligne droite d'Ableton). Coût : le modèle est écrit (`VelocityRamp` 567, `SetVelLive` 280) ; il manque le geste — aujourd'hui la lane ne sait saisir qu'**une** note à 6 px (CP_Editor.lua:2954-2970). Contre quoi : REAPER le fait, Ableton le fait, FL le fait. C'est la plus grosse asymétrie geste/modèle du roll actuel.

**Rang 5 — trois transformations absentes partout ailleurs dans REAPER, ~30 lignes chacune dans Roll.**
- **Strum** : décaler les départs d'un accord selon l'ordre des hauteurs, avec une tension. Ableton et FL l'ont, REAPER non.
- **Ornament** (flam / grace notes) : la plus utile des trois en contexte drum, et le modèle de rangs drum la rend évidente.
- **Recombine** : permuter/miroir/rotation d'**une** des quatre dimensions du cache SoA. C'est littéralement une permutation d'un des quatre tableaux — le rendement créatif par ligne de code le plus élevé de tout ce document.
Toutes trois sont unit-agnostiques, donc servent take **et** clip sans une ligne de plus.

**Rang 6 — désactivation de note (mute).**
Ableton `0`, REAPER `Edit: Mute events (toggle)`. Ici : le backend take le supporte gratuitement (`MIDI_SetNote` a un paramètre `mutedIn`, aujourd'hui passé à `nil`, Roll.lua:94) ; côté moteur natif il reste **deux octets libres dans `LaneNote`** (cp_lanes.h:119). Coût : un champ de cache, un rendu grisé, une touche. Réserve honnête : cela fait passer le cache SoA de 4 à 5 tableaux et le format `Clip.lua` de « s,l,p,v » à un quintuplet — le parseur ignore déjà les clés inconnues en lecture (Clip.lua:202) mais le champ `notes` lui-même est positionnel, donc c'est une **version de format**, pas une extension silencieuse. À trancher avant, pas après.

**Rang 7 — probabilité par note (chance), en mode clip uniquement.**
Pourquoi c'est tentant : c'est la fonction la plus distinctive d'Ableton sur ce terrain, REAPER ne l'a pas du tout, et le moteur natif a la place (le second octet de `pad[2]`) plus l'endroit exact où la tester — la porte de note-on du fil audio dans `cp_lanes.cpp`. Coût audio : un tirage et une comparaison par note-on, pas d'allocation.
Pourquoi il faut le limiter au mode clip : **un take REAPER n'a nulle part où stocker ça.** Il faudrait un canal parallèle (extstate, événements texte) que l'éditeur natif ne comprend pas et que le moindre glue/split désynchronise. Une fonction qui marche dans une moitié de l'éditeur et pas dans l'autre viole le principe « mêmes raccourcis, mêmes commandes » que RollUI existe pour tenir (RollUI.lua:2-6). À proposer, mais en sachant que c'est le premier écart assumé entre les deux backends. Les **groupes Play All / Play One** d'Ableton, eux, sont hors de portée raisonnable : ils demandent une notion de groupe persistante que ni `LaneNote` ni le format Clip ne portent.

**Rang 8 — Note Stretch (mise à l'échelle proportionnelle d'une sélection).**
Ableton l'a en poignées ; REAPER l'a via `Fit notes to time selection` + le modificateur arpeggiate. Ici, une seule op `Roll.ScaleTime(anchor, factor)` + deux poignées sous la règle. Utile surtout en mode clip, où rien d'autre ne le fait.

**Rang 9 — notes fantômes des autres clips.**
FL (ghost channels) et Ableton (multi-clip 8 pistes + Focus Mode N) le font, REAPER le fait (contextes secondaires avec opacité réglable). Ici, `Loop.ReadNotes(lane, …)` (Loop.lua:822) expose déjà les notes d'une autre lane : afficher **en lecture seule** les notes de la scène courante coûte une passe de rendu et zéro modèle. L'édition multi-clip, en revanche, est chère (indices, undo, backends multiples) et n'apporte rien que la fenêtre unique ne donne déjà — **ne pas la suivre**.

**Rang 10 — filtres de sélection façon « Find and Select Notes ».**
`SelectSimilar` (Roll.lua:431) existe ; y ajouter **Count / every-nth** et **Duration** couvre l'usage réel (fabriquer une variation en sélectionnant une note sur trois). Une barre de filtres complète à 8 critères serait du sur-mesure pour rien.

## Ce qu'il ne faut pas écrire, et pourquoi

- **Lanes de CC en mode take** — `ANALYSE_Design.md:162` les classe comme « le seul grand pan MIDI absent ». Je nuance : en mode take, c'est le terrain où REAPER est le plus loin devant (formes par segment, 14 bits, poly AT suivant la sélection, presets de lanes, réordonnancement) et l'éditeur natif est à un clic. En **mode clip**, il n'y a effectivement aucune alternative — mais le stockage n'a pas de place : `LaneNote` ne porte que des notes, et la file de port émet des messages 3 octets (`PortMidi::msg[…][3]`, cp_lanes.h:198). Ce serait un tableau supplémentaire dans `Lane`, un format de sérialisation en plus dans `Clip.lua`, et une lane d'UI dans deux hôtes. C'est un chantier, pas un ajout — et il est en concurrence directe avec `ModJSFX`, qui module déjà des paramètres sans passer par le CC.
- **MPE, notation, liste d'événements, sysex, canaux, propriétés d'événement, remapping de souris** — natif, profond, et hors d'atteinte à effort raisonnable.
- **Time Warp / courbes de vitesse** d'Ableton — la même chose se fabrique avec Quantize à strength partielle plus un nudge, pour un centième du coût.
- **Stacks / Tonnetz** — joli, mais `InsertChord` + les 11 accords (Roll.lua:758-766) couvrent 90 % de l'usage, et le pad Tonnetz est de l'UI pure.
- **Draw Mode d'Ableton (B)** — l'insertion au clic + drag-longueur d'ici (CP_Editor.lua:2872-2905) est le geste FL, plus direct ; ajouter un mode modal serait un recul. En revanche, la **peinture continue** (glisser pour poser plusieurs notes sur une même ligne) manque réellement en contexte drum, et elle ne demande pas de mode : elle demande de ne pas terminer le drag après la première note.

---

## Fichiers cités

- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Roll.lua`
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\RollUI.lua`
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Rows.lua`
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Clip.lua`
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Loop.lua`
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Editor\CP_Editor.lua`
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Native\src\core\cp_lanes.h`
- `C:\Users\Cedric\AppData\Roaming\REAPER\LangPack\MIDI Editor actions (active take only) vs (all editable).ReaperLangPack` (inventaire d'actions en clair)
- `C:\Users\Cedric\AppData\Local\Temp\claude\c--Users-Cedric-AppData-Roaming-REAPER-Scripts-CP-Scripts\eb4a7e16-1e9f-4125-af8c-e66aee0cbe77\scratchpad\whatsnew.txt` (changelog REAPER v7.78→v0.20, téléchargé)

Sources : [Ableton — MIDI Tools](https://www.ableton.com/en/live-manual/12/midi-tools/) · [Ableton — Editing MIDI](https://www.ableton.com/en/live-manual/12/editing-midi/) · [Ableton — Editing MPE](https://www.ableton.com/en/live-manual/12/editing-mpe/) · [Ableton — Clip Envelopes](https://www.ableton.com/en/live-manual/12/clip-envelopes/) · [Ableton — Keyboard Shortcuts](https://www.ableton.com/en/live-manual/12/live-keyboard-shortcuts/) · [Image-Line — Piano roll](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm) · [Image-Line — Riff Machine](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_riff.htm) · [Image-Line — Strum](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_strum.htm) · [REAPER — whatsnew.txt](https://www.reaper.fm/whatsnew.txt) · [KVR — Midi Groove Template in Reaper?](https://www.kvraudio.com/forum/viewtopic.php?t=381799) · [Cockos forum — MIDI note probability](https://forums.cockos.com/showthread.php?t=257246)