# ANALYSE — nomenclature des contrôles : quel rôle mérite quel widget

Écrit le 2026-07-25, à la demande de Cédric : « en fonction du rôle de
l'action, décider judicieusement si ce sera un bouton, un knob, un
dropdown, un slider. Pour le moment ça semble arbitraire et non
cohérent. » Ce document pose la règle, mesure l'existant, et liste les
migrations — **par rôle, jamais par goût**.

---

## 1. La règle

Le choix se décide sur **trois questions**, dans cet ordre :

1. **La valeur a-t-elle un état ?** Non → *bouton*. Oui → suite.
2. **L'état est-il binaire ?** Oui → *toggle* (si l'état doit rester
   visible) ou *checkbox* (si c'est une option de réglage rangée dans un
   panneau).
3. **La valeur est-elle continue ?** Non (choix parmi des noms) →
   *segmenté* (2-4) ou *combo* (5+). Oui → suite : est-ce qu'on la
   règle **à l'oreille** (knob) ou est-ce que sa **position dans la
   plage doit se lire d'un coup d'œil** (slider) ? Et si c'est le
   **chiffre exact** qui compte → *champ numérique*.

| Widget | Le rôle qu'il porte | Signes distinctifs |
|---|---|---|
| **Bouton** | Action instantanée, sans état | Verbe à l'infinitif : Normalize, Detect, Quantize, Panic |
| **Toggle** | État binaire **permanent et central**, visible sans chercher | Play/Stop, Rec, Mute, Solo, Arm, Loop, Snap |
| **Checkbox** | Option secondaire, dans un panneau ou un menu | Note names, Follow selection, Preview through track |
| **Knob** | Valeur continue **réglée à l'oreille** | Vol, Pan, Tune, Pitch, A/D/S/R, Sens, sends, macros |
| **Slider** | Valeur continue dont la **position dans la plage** est l'information | Position dans un fichier, crossfade, mix A/B, zoom |
| **Range slider** | Deux bornes d'un même axe | Région d'un sample, plage de vélocité |
| **Champ numérique** | Le **chiffre exact** compte et on veut le taper | Root note, vélocité, BPM source, mesures |
| **Segmenté (2-4)** | Choix exclusif qu'on veut voir en entier | Keys/Drum, forme d'onde, mode de courbe |
| **Combo (5+)** | Choix exclusif parmi des noms | Grille, preset, mode de warp, choke group |
| **Clic droit** | Rare, avancé ou destructif | Renommer, effacer, ouvrir dans…, régler le BPM source |

**Trois interdits**, qui sont la source du sentiment d'arbitraire :

- Une **checkbox dans une barre d'action** : si l'état pilote ce qu'on
  entend, c'est un toggle, et il doit s'allumer.
- Un **slider pour une valeur qu'on règle à l'oreille** : il mange une
  largeur qu'un knob ne prend pas, et sa position n'apprend rien.
- Un **bouton qui porte un état** (dont le libellé change entre deux
  sens opposés) sans le montrer : c'est un toggle déguisé.

**Corollaire technique, désormais acquis** : tout knob accepte la saisie
d'une valeur exacte au **clic droit** (commit `3a81c81`). Sans ça,
migrer un champ numérique vers un knob perdrait de la précision et la
règle ci-dessus serait une régression déguisée.

---

## 2. Ce que dit l'inventaire (mesuré, pas ressenti)

Appels de widgets du toolkit, par application :

| App | Boutons | Knobs | Checkbox | Combo | Sliders | Champs num. |
|---|---|---|---|---|---|---|
| CP_Editor | 18 | 0 | 3 | 0 | 1 | 4 |
| CP_Looper | 11 | 0 | 0 | 0 | 0 | 0 |
| CP_Sampler | 6 | 3 | 2 | 1 | 1 (range) | 1 |
| CP_Session | 4 | 0 | 0 | 0 | 0 | 0 |
| CP_MediaExplorer | 1 | 0 | 0 | 0 | 1 | 2 |

Deux constats que ce tableau rend indiscutables :

1. **Le bouton est utilisé comme widget par défaut** (40 sur 58
   contrôles). Beaucoup portent en réalité un état — surtout dans le
   Looper et la Session, qui dessinent en plus leurs propres boutons
   « maison » (`tinyBtn`) au lieu du toolkit : deux styles de bouton
   coexistent dans la même fenêtre.
2. **Les knobs n'existent que dans le Sampler.** Toutes les valeurs
   continues des autres apps passent par des sliders ou des champs —
   d'où l'impression d'incohérence : le même type de réglage a trois
   apparences selon la fenêtre où il se trouve.

---

## 3. Les migrations, app par app

### CP_Editor

| Contrôle | Aujourd'hui | Cible | Pourquoi |
|---|---|---|---|
| Gain dB, Pitch st, Rate | champ numérique | **knob** (saisie au clic droit) | Réglages sonores, on les tourne à l'oreille ; le chiffre reste accessible |
| Sens (détection) | slider | **knob** | Aucune lecture de position utile, juste « plus ou moins sensible » |
| Vel (vélocité par défaut) | champ numérique | **champ numérique** (inchangé) | Le chiffre exact EST l'information (127, 100, 64) |
| Snap | checkbox | **toggle** | État permanent qui change le comportement de chaque geste |
| Drum rows, Note names | checkbox | checkbox, **déplacées dans le menu VIEW** | Options d'affichage, pas des gestes |
| Normalize, Reverse, Trim, Detect, Split, Quantize, Transform, Native | bouton | bouton (inchangé) | Actions instantanées |
| Slices to pads / Sel to pad / To instrument | bouton | bouton (inchangé), **groupés visuellement** | C'est la chaîne « sample → instrument », elle doit se lire comme un bloc |
| Bars −/+ (mode clip) | deux boutons | **champ numérique à pas ×2** ou segmenté 1/2/4/8 | Une longueur de boucle est un chiffre, pas deux gestes |
| Lock | bouton-icône | **toggle** (il l'est déjà de fait) | Il porte un état, il doit s'allumer |

### CP_Sampler

| Contrôle | Aujourd'hui | Cible | Pourquoi |
|---|---|---|---|
| Vol, Pan, Tune, Pitch, A/D/S/R | knob | knob (inchangé) | La référence : c'est ce que les autres apps doivent rejoindre |
| Region | range slider | range slider (inchangé) | Deux bornes sur un axe temporel : c'est exactement son rôle |
| Loop | checkbox | **toggle** | Change ce qu'on entend, doit s'allumer |
| Choke | combo | combo (inchangé) | 9 valeurs nommées |
| Root | champ numérique | champ numérique (inchangé) | Une note se tape |
| Arm | bouton-icône | **toggle** | État permanent, central, et déjà source de confusion |
| Drum / Instr | onglets | **segmenté** | Deux modes exclusifs, pas deux pages |

### CP_Looper et CP_Session

Le vrai chantier de ces deux-là n'est pas le choix des widgets mais le
fait qu'ils **dessinent leurs propres boutons** (`tinyBtn`, rectangles
maison) au lieu d'utiliser le toolkit. Conséquences : les arrondis, les
états de survol, le thème et les futures migrations leur échappent.

| Contrôle | Aujourd'hui | Cible |
|---|---|---|
| Play/Stop, Rec, Overdub, Mute par lane | rectangle maison | **toggle du toolkit**, avec les couleurs sémantiques (play/record) |
| Clear, Panic, Stop all | rectangle maison | **bouton du toolkit** |
| Longueur en mesures | bouton qui cycle | **champ numérique à pas ×2** ou segmenté |
| Quantisation de lancement | bouton qui cycle | **combo** (Off, 1/4, 1/2, 1, 2, 4 mesures) |
| Volume / niveau de lane (à venir) | — | **knob** |

C'est aussi ce qui justifie la **palette sémantique** déjà notée dans
`ANALYSE_DesignSystem.md` §4.1 : `play`, `record`, `mod`, `mute` doivent
être des tokens de thème, pas des littéraux recopiés dans chaque app.

### CP_MediaExplorer

| Contrôle | Aujourd'hui | Cible |
|---|---|---|
| Volume de préécoute | slider | **knob** |
| Pitch, Rate | champs numériques | **knobs** (saisie au clic droit) |
| Recherche | champ texte | inchangé |

---

## 4. Ordre de migration proposé

1. **Les toggles** : Snap, Loop, Arm, Lock. Petit, visible tout de
   suite, et ça supprime la moitié de l'impression d'arbitraire.
2. **Le toolkit dans le Looper et la Session** (remplacer `tinyBtn`),
   avec les couleurs sémantiques — c'est le plus gros morceau, et il
   conditionne la refonte de la Session.
3. **Les knobs** : Editor (Gain/Pitch/Rate/Sens) puis Media Explorer
   (Vol/Pitch/Rate).
4. **Les longueurs et quantisations** : champ à pas ×2 / combos.
5. **Segmentés** : Drum/Instr, Keys/Drum.

Chaque étape est isolable et testable seule ; aucune ne dépend de la
suivante.

---

## 5. Ce qui reste à trancher avec Cédric

- **Le knob par défaut fait 34 px.** Pour un bandeau dense (Editor,
  Media Explorer), 28 px avec le libellé à droite serait plus compact.
  À voir sur maquette.
- **Le toggle a-t-il besoin d'une couleur par rôle** (vert = play,
  rouge = rec, ambre = pending) ou d'un simple accent unique ? Ableton
  utilise la couleur de la piste ; Bitwig un accent unique.
- **Les onglets Drum/Instr** : segmenté (compact) ou onglets (plus
  lisible) ? Le segmenté gagne si la barre devient dense.
