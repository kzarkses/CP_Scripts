# ANALYSE — Session View CP (spec design, zéro code)

> Rédigé le 2026-07-23 pendant la journée d'autonomie, à lire au retour.
> Décision déjà actée en amont : **CP_Editor est l'éditeur universel**
> (chantier 10) — ouvrir une loop/un clip ouvre CP_Editor avec le bon focus.
> Ce doc propose le reste : le modèle, le moteur, les phases. Rien n'est codé.

La demande (verbatim résumé) : « un session view à la Ableton. J'adore le
looper actuel, mais ça fait très looper, pas quelque chose qui pourrait
servir à faire des arrangements. DnD dans l'arrangeur, plusieurs pistes
automatiquement associées à une piste du looper, format en colonnes. En
gardant l'avantage de pouvoir rentrer dans une loop et la modifier. »

---

## 1. Les deux paradigmes sur la table

### A. La grille de clips (Ableton) — clips = descripteurs CPC1
Chaque cellule est un **Clip** (`CP_Engine/Clip.lua`) : MIDI (notes Roll) ou
audio (path/offs/len/gain/pitch/rate). Léger, sérialisable, transportable
par le Bus, éditable par CP_Editor. C'est ce que l'Engine porte nativement
depuis les chantiers 5-7.

### B. La profondeur (lignée CPStudio) — blocs = subprojects
`ROADMAP_CPStudio.md` (V0.7, 02/2026) l'a déjà construit une fois : la
grille montrait des items × pistes, chaque bloc pouvant être un **projet
REAPER complet** (dive par double-clic, `SelectProjectInstance`). Force
réelle : profondeur infinie, l'arrangeur reste intact, multi-projet
simultané. Coûts constatés : tout passe par l'API cross-projet (scans
lourds → throttling/lazy partout), la manipulation musicale d'un bloc
(quantize de lancement, resize en bars, edit note à note) reste hors de
portée — un subproject n'est pas un objet musical, c'est un conteneur.

### Recommandation
**La grille de Clips CPC1 comme base ; la profondeur comme OPTION par
cellule, plus tard.** Un clip « porte » vers un subproject peut exister un
jour comme un `kind="subproject"` du descripteur (le format ignore les
champs inconnus — prévu pour). On garde ainsi : objets musicaux légers,
lancement quantisé par le moteur existant, édition CP_Editor — et on ne
ferme pas la porte au paradigme profondeur qui est la signature CPStudio.

---

## 2. Ce que l'Engine fournit DÉJÀ (l'inventaire honnête)

| Brique | État | Rôle session view |
|---|---|---|
| `Clip.lua` (CPC1) | ✅ | la cellule de la grille |
| `Bus.lua` | ✅ | drag de clips entre fenêtres, `Send("editor:open")` |
| `Loop.lua` + CP_MidiLooper.jsfx | ✅ 4 lanes | LE moteur de lecture MIDI (gate, phase-lock, launch quantize 8b, pending visible par l'UI) |
| `Tempo.lua` + hub | ✅ | horloge partagée, NextBeat/NextBar pour tout ce qui n'est pas dans le JSFX |
| `Tracks.lua` | ✅ | marques `app:role` — l'association piste session ↔ piste REAPER |
| `Rows.lua`/`Roll`/`RollUI` | ✅ | l'édition (CP_Editor universel) |
| `Bake.lua` | ✅ | consolidation d'un clip audio en fichier |
| Loop.LaneToClip/ClipToLane | ✅ | lane ↔ Clip dans les deux sens |
| Export lane → item MIDI | ✅ (c94c1bd) | le pont grille → arrangeur existe déjà pour le MIDI |

**Le trou unique : un moteur de lecture de clips AUDIO.** Tout le reste est
de l'UI et du câblage.

## 3. Le modèle proposé

- **Une piste de session = une piste REAPER** (l'instrument/la chaîne FX
  vivent là). L'association est une marque `Tracks` (`session:track`), et
  les lanes du looper actuel deviennent le cas particulier « piste MIDI
  dont le moteur est CP_MidiLooper ».
- **Une colonne par piste, les scènes en lignes** (format Ableton demandé).
- **Stockage** : les clips d'une piste dans son `P_EXT` (le pattern éprouvé
  du blob looper v2/v3 : sauvé dans le .rpp, voyage avec la piste), format
  CPC1 concaténé. Pas de side-car.
- **Lancement** : la sémantique 8b généralisée — pending/target au prochain
  boundary, annulation par re-clic, statut clignotant. Une **scène** =
  lancer la ligne entière (boucle sur les pistes).
- **Édition** : clic sur un clip → `Bus.Send("editor:open", clip)` →
  CP_Editor prend le focus qui va (piano roll pour MIDI, waveform pour
  audio). Le retour : `editor:apply` → la grille réécrit le P_EXT et
  recharge le moteur concerné.

## 4. Le moteur audio — trois options, une trajectoire

1. **CF_Preview quantisé (interim, coût S-M)** : lancement au boundary via
   Tempo.NextBar, sortie routée sur la piste du clip
   (`CF_Preview_SetOutputTrack`, déjà câblé dans l'Engine), B_LOOP pour
   boucler. Précision : ~bloc audio, pas sample-lock — suffisant pour
   maquetter et jammer, pas pour la scène finale.
2. **JSFX ClipEngine gmem (le vrai moteur, coût L)** : le pattern
   CP_MidiLooper appliqué à l'audio — un JSFX par piste session (ou un
   multi-voies), les samples streamés en gmem, phase-lock au beat grid,
   launch quantize dans le moteur. La lignée ancienne avait un
   `CP_ClipEngine.jsfx` (cf. ROADMAP_CPStudio « Briques réutilisables ») :
   à miner comme PREUVE de faisabilité, on réécrit sur les conventions
   Engine (WARM @init, LAYOUT_VER, heartbeat).
3. **Items natifs cachés** (écarté) : poser les clips comme items REAPER
   sur des pistes cachées et piloter le transport — casse le « lancer sans
   transport » (Free run) qui fait l'intérêt du looper.

Trajectoire : 1 puis 2 ; 3 jamais.

## 5. Phases proposées (chacune utilisable seule)

- **P1 — La grille sur l'existant (M)** : fenêtre CP_Session, colonnes =
  les 4 lanes du looper + pistes marquées, cellules cliquables (launch/
  stop quantisés via Loop), état pending/playing visible, clic → CP_Editor.
  Aucun moteur nouveau. C'est le MVP qui « ne fait plus looper ».
- **P2 — Clips MIDI multi-pistes (M-L)** : dépasser MAX_LANES=4 —
  plusieurs routeurs CP_MidiLooper (un par piste session, gmem nommé par
  piste) OU un jsfx élargi ; le blob P_EXT par piste ; scènes.
- **P3 — Clips audio interim (S-M)** : CF_Preview quantisé par piste.
- **P4 — ClipEngine JSFX audio (L)** : le moteur définitif, phase-lock.
- **P5 — Ponts et confort (S chacun)** : DnD grille ↔ arrangeur (l'export
  MIDI existe ; capture au relâchement en sens inverse), enregistrement
  direct dans une cellule (arm de cellule à la Ableton), profondeur
  `kind="subproject"`.

## 6. Ce qu'on mine de CPStudio (sans lire le code Meta Mixer)

Au niveau design uniquement : le dock bas compact, la lazy-scan discipline
(ne scanner que le projet actif), le dive-par-double-clic comme geste de
profondeur, la barre d'onglets unique. Le verdict convergence tient : on
reconstruit sur l'Engine, on ne ranime pas la lignée ImGui.

## 7. Questions ouvertes pour Cédric

1. **P1 tel quel ?** (grille sur les 4 lanes + launch quantize existant,
   zéro moteur neuf) — c'est la marche la plus courte vers « ça ne fait
   plus looper ».
2. **Multi-pistes MIDI (P2)** : plusieurs instances JSFX (un gmem par
   piste, simple mais N fenêtres de monitoring) ou un JSFX élargi (un seul
   gmem, MAX_LANES↑, plus de chirurgie) ?
3. **Scènes** : lignes nommées à la Ableton dès P1, ou après P2 ?
4. **La fenêtre** : app séparée (CP_Session) ou onglet/mode du Looper
   actuel ?
5. **L'audio interim (P3)** vaut-il le détour, ou on va droit au moteur
   JSFX (P4) ?
