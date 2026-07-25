# CP_Toolkit — la grammaire des composants

> **Spec, pas analyse.** Ce fichier dit comment se fabrique un bouton, un
> dropdown, un knob, une icône. Il vit à côté du code qu'il gouverne. Les
> analyses datées sont à la racine (`ANALYSE_DesignSystem.md` pour la palette,
> `ANALYSE_Nomenclature.md` pour « quel rôle mérite quel widget »).
>
> Chaque section dit **la règle**, puis **aujourd'hui** (mesuré, ligne à
> l'appui), puis **la cible**.
>
> Écrit le 2026-07-25 sur une mesure de 7 familles de contrôles.
> ⚠️ 5 des 7 recontrôles adverses n'ont pas pu tourner (limite de session).
> Les mesures marquées ✅ sont vérifiées deux fois ou lues par moi
> directement ; les autres viennent d'une seule passe.

---

## 0. Les trois canaux — la règle qui gouverne tout le reste

Une interface dense a exactement **trois canaux visuels** pour dire quelque
chose sur un contrôle :

| Canal | Porte | Vocabulaire |
|---|---|---|
| **Valeur** (clair/sombre) | l'élévation et le survol | un pas sur la rampe neutre |
| **Teinte** | l'état sémantique | accent, play, record, pending… |
| **Poids** | l'emphase | gras, épaisseur de trait, cadre |

**La règle : un message = un canal, et jamais deux canaux pour le même
message.**

C'est la règle que j'ai enfreinte au commit `186402a`. `ToggleButton` allumé
peint un fond accent (canal *teinte*) **puis** une barre accent par-dessus
(même canal, même valeur) :

```lua
-- Widgets.lua:4703
bg = hovered and theme.colors.accent_hovered or theme.colors.accent
-- Widgets.lua:4716
Core.DrawRect(x + 1, y + 1, 3, h - 2, a[1], a[2], a[3], dim)  -- a = accent
```

✅ Accent sur accent : delta nul, **la barre n'existe pas**. Le commentaire
juste au-dessus revendique pourtant « la même grammaire que le rail ».

Corollaire qui règle le cas proprement : **l'allumé change la teinte, le survol
change la valeur.** Deux canaux orthogonaux, donc « allumé non survolé » et
« éteint survolé » ne peuvent jamais se confondre. Une barre n'est nécessaire
que quand le fond ne porte PAS l'accent — c'est le cas du rail (lavis à 0,13),
et c'est le seul endroit où elle est justifiée.

---

## 0 bis. La fenêtre est une pile de ZONES

*(écrit le 2026-07-25 au soir, après le retour de test sur CP_Editor)*

Avant, le toolkit n'exposait **aucune primitive de chrome de fenêtre**. Huit
fenêtres dessinaient donc la leur, et on avait quatre formes de zone de
commande, quatre positions pour Settings, quatre hauteurs de barre, et `iconBtn`
écrit **trois fois** avec deux signatures incompatibles. Ce n'étaient pas huit
divergences à corriger : c'était une primitive manquante et huit contournements.

```
+----------------------------------------+  contour : la fenêtre possède sa zone
| [i][i] | [combo]  [valeur]     [o][?]  |  ZONE barre    — ce qu'on peut faire
+----------------------------------------+  couture
|                                        |
|               contenu                  |  ZONE contenu  — le travail
|                                        |
+----------------------------------------+  couture
| statut                                 |  ZONE statut   — ce qui vient d'arriver
+----------------------------------------+
```

### La couture, pas le trait

Une arête de zone se dessine avec **un pixel d'ombre et un pixel de lumière**
(`Widgets.SeamH` / `SeamV`), jamais avec un trait coloré.

Un trait coloré ne sépare que **tant que la palette lui laisse la place**.
Aplatis le thème, passe en clair, pousse un curseur du tweaker un peu trop
loin : il disparaît, et les zones se recollent. Une couture est un contraste
**local** — l'ombre porte sur fond clair, la lumière porte sur fond sombre —
donc la structure survit à n'importe quelle palette.

C'est ça, **la séparation par le design et non par la palette**. Deux jetons
existent (`seam_shadow`, `seam_light`) pour que l'inspecteur sache les nommer et
qu'aplatir le relief reste une décision possible, mais leurs valeurs par défaut
sont du noir et du blanc à alpha fixe, **pas des marches de la rampe** : une
arête qui dépend de la rampe est une arête qu'on peut faire disparaître par
accident.

### La zone distribue la géométrie, pas le widget

**C'est la règle qui manquait, et le défaut se voyait à l'écran :** dans le
rail, un dropdown moins large que le toggle du dessus, encadré alors que ses
voisins étaient plats. Cause : chaque widget se dimensionnait sur ce qui restait
de largeur.

| | Règle |
|---|---|
| **Hauteur** | une seule, celle de la zone (`BAR_CTL_H` = 22, zone = 30) |
| **Rayon** | un seul, `rounding_small` |
| **Largeur** | une marche de l'échelle `{ 22, 54, 76, 104, 140 }`, **jamais un pixel entre deux** |
| **Débordement** | un contrôle qui ne rentre plus n'est **pas** placé — pas de moitié dépassant du bord |

Un contrôle prend la première marche qui contient son contenu. Les voisins
s'alignent **par construction**, pas par chance.

Ce qui a le droit de différer, c'est le **remplissage**, sur un seul canal :

- un **verbe** se lève → `button` / `button_hovered` / `button_active`
- une **valeur** s'enfonce → `frame_bg` / `frame_hovered` / `frame_active`

Agir contre tenir. Rien d'autre.

### Les quatre états, sans exception

| État | Ce qu'il dit | Comment |
|---|---|---|
| repos | « c'est un contrôle » | la puce, visible |
| survol | « la souris est dessus » | un pas plus clair |
| enfoncé | « ce clic-là a porté » | un pas plus sombre |
| allumé | « cet état est **tenu** » | fond accent, glyphe en `on_accent` |

Sa règle, mot pour mot : *« chaque élément, icône, bouton, tout doit toujours
avoir un état hover, highlighted, active »*. En comptant, **dix contrôles
n'avaient pas d'état enfoncé** — Checkbox, CollapsingHeader, HelpButton,
TreeNode, RadioGroup, MenuBar, CollapsiblePanel, les items de menu contextuel,
les rangées de Table et celles du rail.

Un contrôle qui répond au survol mais pas à l'appui laisse **le clic lui-même
sans accusé de réception** : on ne distingue pas un clic qui a porté d'un clic
qui a manqué. Sur une liste c'est pire — l'appui est le seul moment qui dit
*quelle* rangée on a attrapée. Et sur une machine lente c'est la différence
entre « ça n'a pas pris » et « il travaille ».

Une seule routine choisit désormais dans un triplet du thème :
`pickState(repos, survol, enfoncé, hovered, down, disabled)`. Les trois couleurs
sont **passées**, pas déduites d'un nom de base : `base .. "_active"`
construirait une chaîne à chaque frame de chaque contrôle.

La couleur de rôle (`play`, `record`, `pending`) atteint le **remplissage
allumé**, pas seulement le glyphe — un bouton d'enregistrement qui s'allume dans
l'accent générique ment sur son rôle. Et elle ne teinte **que** l'état allumé :
la teinte est le canal de l'état ; la dépenser sur une catégorie ferait discuter
deux messages sur le même axe (§0).

### Le vocabulaire

| Appel | Pour quoi |
|---|---|
| `UI.BeginBar(id, opts)` / `UI.EndBar()` | ouvre la zone ; `opts.title` met le nom **dans** la barre |
| `UI.BarIcon(id, icon, label, disabled)` | un verbe, icône seule, nom en infobulle |
| `UI.BarButton(id, label, disabled, on)` | un verbe qui a besoin de **mots** |
| `UI.BarToggle(id, icon, icon_off, on, label, disabled, opts)` | un état tenu |
| `UI.BarCombo(id, idx, items, disabled, opts)` | un choix parmi une liste |
| `UI.BarValue(id, label, v, min, max, disabled, opts)` | un nombre (glisser / molette / clic droit / double-clic) |
| `UI.BarInput(id, text, opts)` | un champ qui prend **tout le reste** |
| `UI.BarCaption(text, opts)` | un texte calé à droite |
| `UI.BarSep()` | une rupture de groupe (la couture, debout) |
| `UI.BarRight()` / `UI.BarLeft()` | remplir depuis le bord droit, puis revenir |
| `UI.BarSlot(w)` | l'échappatoire : réserve un créneau, rend `x, y, h` |
| `UI.AppStatus(text)` | la zone du bas, ancrée au bord de la **fenêtre** |

**`label` et `disabled` sont positionnels**, pas des champs d'`opts`. Ils
changent d'une frame à l'autre (un Play qui devient Stop, un Clear qui se grise)
et les écrire en champs construirait une table par contrôle et par frame. `opts`
reste pour ce qui est vraiment constant (accent, largeur, taille d'icône) et
vient d'une table de niveau module.

**Réserver le bord droit EN PREMIER.** Quand la fenêtre est trop étroite, le
bout réservé le premier survit — et les contrôles qui ne doivent jamais
disparaître sont Settings et Help.

### Et dans une grille ? Les contrôles posés par un RECTANGLE

Une grille calcule sa propre géométrie — cellules, colonnes, rangées — et le
curseur de flux n'a rien à y dire. Mais les contrôles **dans** une cellule
doivent rester de vrais contrôles : même remplissage, mêmes quatre états, même
encre que la barre de commande, sinon la fenêtre cesse de se lire comme un seul
produit. C'est exactement là que chaque app avait commencé à écrire son propre
bouton privé (trois copies supprimées à la passe des zones, une quatrième dans
le manager de la Floating Toolbar).

| Appel | Pour quoi |
|---|---|
| `UI.ChipAt(id, x, y, w, h, icon, label, on, disabled, opts)` | la puce de la barre, posée où on veut ; glyphe si le nom existe, sinon le texte |
| `UI.FaderAt(id, x, y, w, h, v, opts)` | un fader horizontal 0..1 → `changed, value, released` |
| `UI.MeterAt(x, y, w, h, l, r, vertical, hold_l, hold_r)` | un vu-mètre à un rectangle (`VMeter`/`HMeter` passent par lui) |

Trois choses à retenir :

- **La valeur d'un fader est 0..1 et l'APPELANT possède la courbe et l'unité.**
  Un widget qui connaîtrait les décibels ne connaîtrait qu'une seule sorte de
  décibels. `opts.text` reçoit la valeur déjà formatée, donc rien n'alloue dans
  la boucle de dessin.
- **`released` compte** : un glisser est **un** point d'annulation, pas soixante.
  C'est le seul moment où l'appelant doit écrire l'historique.
- **`opts.mark`** dessine le cran (l'unité, le centre) — un fader sans repère
  oblige à lire le nombre pour savoir où est le zéro.

### Une rangée de knobs doit rester une RANGÉE

| Appel | Pour quoi |
|---|---|
| `UI.KnobToggle(id, label, icon, on, opts)` | un oui/non, dans l'empreinte d'un cadran |
| `UI.KnobChip(id, label, text, opts)` | un choix parmi une poignée → `clicked, wheel_delta` |

Une rangée de cadrans est un **rythme** : une largeur, une hauteur, une légende
dessous. Y poser un combo étiqueté et une case à cocher casse ce rythme, et
l'œil lit deux intrus venus d'une autre fenêtre. Ces deux-là occupent
exactement la boîte d'un knob (`KNOB_SIZE` + la ligne de légende) et portent ce
qu'un cadran ne peut pas.

**Carré arrondi, pas rond** — volontairement. La forme dit « ce n'est pas
continu ». C'est le rythme qui doit correspondre, pas le contour.

`KnobChip` **montre** la valeur courante et laisse l'appelant ouvrir son propre
menu au clic ; la molette rend un delta déjà consommé. Il est *sunken* au repos
(une valeur qu'on lit est un champ, pas un bouton) et **allumé** quand il n'est
pas à sa valeur neutre, ce qui rend « ce pad est dans un groupe » lisible sans
lire le mot.

**Le knob sait enfin être désactivé** (`opts.disabled`, ou `UI.BeginDisabled`).
Il garde sa place et sa valeur, et ne répond plus à rien — parce qu'un contrôle
qui disparaît quand il ne sert pas emporte la mise en page avec lui.

### Rail ou barre ?

Le rail existe toujours (`UI.BeginRail`), avec `RailCombo` et `RailValue` qui
portent enfin la forme d'une rangée de rail. Mais **CP_Editor est repassé en
barre haute** sur son retour de test, et l'argument est mesurable : le rail
coûtait **126 px de largeur en permanence**, et la largeur est ce dont une forme
d'onde et un piano roll sont faits. Une barre coûte **30 px de hauteur, une
fois**.

L'autre moitié de l'échange : la barre se dégrade toute seule. Un contrôle qui
ne rentre plus n'est pas placé, donc une fenêtre étroite perd des outils **par
le milieu** au lieu qu'il faille un drapeau de repli pour le lui dire.

### Ce qui est fait

| Fenêtre | Zone de commande | Statut |
|---|---|---|
| CP_Editor | barre, icônes | ✅ |
| CP_Sampler | barre, icônes | ✅ |
| CP_Looper | barre + titre dedans | ✅ |
| CP_Session | barre + titre dedans | ✅ |
| CP_MediaExplorer | 3 zones (recherche / chips / transport) | ✅ |
| CP_FXBrowser | barre + champ extensible | ✅ |
| CP_ThemeTweaker | barre d'onglets | ✅ |
| CP_ModLFO | — | panneau, pas une fenêtre |

Les trois `iconBtn` privés et l'`iconToggle` du Media Explorer sont supprimés.
Il reste **une** copie privée, l'`icon_btn` du manager de la Floating Toolbar :
`UI.ChipAt` fait son travail, mais la bascule change sa taille de glyphe (3 px
de marge fixe → 0,62 × la taille) et son rayon (donné à la main → celui du
thème). C'est un chantier à part entière, pas un remplacement à l'aveugle.

---

## 1. Le bouton

**Règle.** Un bouton *fait* quelque chose. Il n'a pas d'état persistant. Ses
états sont un **déplacement sur la rampe** : repos `n4`, survol `n5`, pressé
`n3` (il s'enfonce, il ne s'éclaire pas). Le texte est centré, sur une ligne,
tronqué avec ellipse, jamais renvoyé à la ligne.

**Un seul bouton accentué par zone.** Le bouton primaire prend l'accent en
aplat avec du **texte noir** (7,76:1 ; le blanc tombe à 2,13:1 au survol).
Tous les autres sont neutres. Si tous les boutons sont accentués, aucun ne
l'est.

**La hauteur découle de la typo** : `button_height = body + 2 × padding_y`.
Elle se calcule, elle ne se choisit pas. C'est pourquoi `body = 16` avec
`button_height = 18` dans `DEFAULT.lua` est cassé : 16 px de texte dans une
boîte de 18.

**Aujourd'hui.** ✅ `Widgets.Button` n'a **aucun accent** — le mot n'apparaît
pas une fois entre les lignes 774 et 860. `opts.selected` (allumé) donne
`button_active`, c'est-à-dire **exactement la même couleur que pressé**, et
plus sombre que le repos. Un bouton allumé se lit donc comme un bouton
enfoncé. En style *flat*, le pressé ne se voit que par le fond : le décalage
de 1 px n'existe qu'en style *windows*.

**Cible.** `Button` gagne `opts.primary` (aplat accent + texte noir). `selected`
disparaît du bouton — un bouton qui a un état est un toggle, pas un bouton.

---

## 2. Le toggle

**Règle.** Un toggle *est* dans un état. Il lui faut un canal qui **survit au
survol** : la teinte. Allumé = accent ; survol = un pas de valeur en plus.

**Aujourd'hui.** ✅ L'état allumé est peint de **six façons pour cinq
contrôles** :

| Contrôle | Allumé se dit par | Barre |
|---|---|---|
| `Button` + `opts.selected` | fond `button_active` (plus sombre) | — |
| `ToggleButton` | aplat accent | + barre accent **invisible** |
| `IconToggle` sans `icon_off` | aplat accent | + barre **invisible** |
| `IconToggle` avec `icon_off` | fond sombre + glyphe accent + glyphe échangé | barre visible |
| `RailItem` | lavis accent 0,13 + gras | barre visible (retrait 3) |
| `TabBar` | soulignement 2 px en bas | — |

Trois retraits de barre différents (`x+1`, `x+1`, `x+3`), quatre couleurs de
texte allumé (`COLOR_WHITE` codé en dur ×2, `accent` ×2), et `opts.accent`
**court-circuite le survol** : un `IconToggle` rouge-record allumé ne réagit
plus du tout à la souris.

**Cible.** Un seul vocabulaire :

```
éteint      fond n4          texte text
survol      fond n5          texte text
allumé      fond accent      texte NOIR
allumé+survol  fond accent_hi   texte NOIR
désactivé   alpha 0.4 sur tout
```

Pas de barre quand le fond porte l'accent. **La barre est réservée au cas
« fond neutre + état allumé »** — rail, ligne de liste courante — et vaut alors
3 px, retrait 0, sur toute la hauteur.

---

## 3. Le dropdown (combo)

**Règle.** Un dropdown se lit comme un **champ**, pas comme un bouton : coins
plus carrés (`rounding_small`), fond enfoncé, **chevron à droite** — c'est le
chevron qui porte l'affordance. Le libellé va **dehors** (à gauche ou dessus),
jamais dedans.

**La molette sur le combo fermé fait défiler les valeurs.** C'est le standard
DAW, REAPER le fait partout nativement.

**La ligne courante du popup utilise le MÊME vocabulaire de sélection que
toutes les listes de l'app.** Une seule couleur de sélection dans tout le
produit.

**Aujourd'hui.** Trois hauteurs cohabitent : `combo_height` 22, `tab_height`
26, `checkbox_size` 16 — aucune routine de peinture partagée. Le popup du
Combo marque le courant par une **barre accent de 3 px**, alors que toutes les
autres listes le marquent par un **fond plein** : deux vocabulaires opposés
dans le même fichier. Le survol du popup lit `header_hovered`, les listes lisent
`list_hover`. Et la valeur **saute horizontalement à l'ouverture**, parce que le
bouton la centre dans `combo_w - h` et le popup l'aligne sur son padding.

Le clavier et la souris sont indistinguables dans le popup : la même branche
peint la ligne pointée au clavier et la ligne survolée.

**Cible.** Une routine `drawSelectableRow(x, y, w, h, state)` partagée par le
popup du Combo, `Table`, `ActionList`, `InteractiveTable`, `ReorderableList` et
le rail. Six vocabulaires de « ligne sélectionnée » deviennent un.

---

## 4. Régler une valeur — knob et slider

**Règle du knob** (consensus Ableton / Vital / u-he) : un **arc fin + un
index**, aucun skeuomorphisme, aucun biseau. Balayage 270°, de 225° à 315°.
Piste en `n6`, valeur en accent.

**Un paramètre bipolaire se remplit depuis le CENTRE.** Un pan, un pitch, un
gain signé : l'arc part de midi. C'est la règle la plus souvent oubliée et la
plus visible quand elle manque.

**La valeur s'affiche dans un champ, pas autour du knob.** Le libellé dessous,
en caption, centré. **Une seule règle, partout.**

**Course souris** : glissement vertical, ~150 px pour toute la course,
Shift = fin (×0,25), double-clic = défaut, molette = un pas. **Les mêmes
gestes sur tous les contrôles de valeur.**

**Slider** : piste fine (~4 px), remplissage depuis l'origine (même règle
bipolaire). Le slider est pour ce qui est **spatial ou à longue course** (un
fader, une timeline) ; le knob pour les bancs de paramètres denses.

**Aujourd'hui.** Deux lignées jamais réconciliées — « piste » (`_Slider`,
`RangeSlider`, `ValueRangeSlider`, `NumberInput`, `ProgressBar`) et « cadran »
(`Knob`, `ModKnob`) — plus deux mètres qui ne partagent rien avec personne.

- **Le knob n'a ni point zéro ni centre marqué.** L'arc part toujours de la
  butée gauche. Aucun paramètre bipolaire n'est lisible.
- `KNOB_SIZE = 34` contre `opts.size or 40` pour ModKnob ; bande de libellé
  11 contre 14.
- Le remplissage accent est peint à **quatre alphas** : 1.0, 0.5, 0.35, 0.45.
- `grab_w = 8` déclaré **trois fois** sous deux noms.
- **Le double-clic a deux sens opposés** : remise à défaut sur les cadrans,
  ouvrir la saisie sur les pistes. Et les pistes n'ont alors *aucun* geste de
  remise à défaut.
- **Trois protocoles pour taper une valeur** : clic droit (Knob), Ctrl+clic ou
  double-clic (`_Slider`), rien (ModKnob).
- Le modificateur fin est **Shift au glissement et Ctrl à la molette, sur le
  même knob**.
- La molette : Knob oui, `_Slider` non, ModKnob non.
- La valeur s'affiche à **cinq endroits** différents, le libellé à **trois**.
- Course : le knob demande 250 px pour 0..1 et 2500 px avec Shift ; le slider
  est positionnel absolu. Le même geste n'a pas la même précision.
- **La poignée du slider est invisible au repos** : elle est peinte en accent
  sur un remplissage accent — le même défaut que la barre du toggle.
- Les mètres codent en dur `0.9,0.2,0.2` / `0.9,0.8,0.2` / `0.3,0.75,0.4` et
  les seuils `>0.9` / `>0.7`. Aucun jeton `meter_*` n'existe.
- `slider_grab` est mappé à l'import d'un thème externe et **jamais lu**.

**Cible.** Un module `Value` partagé : une conversion pixel→valeur, une table de
gestes, un formatage. Knob et slider deviennent deux *rendus* de la même
mécanique. Plus `opts.bipolar` sur les deux.

---

## 5. Les listes

**Règle.** Une seule hauteur de rangée par densité (`row_h`). Zébrage par
`canvas_row` / `canvas_row_dark`. **Une seule peinture de survol, une seule de
sélection**, partagées par toutes les listes. En-tête de colonne : `n3`, un
trait opaque en bas, tri indiqué par un chevron.

**Aujourd'hui.** Trois dialectes. `Table` et `ActionList` lisent les jetons
`list_*` ; `InteractiveTable` et `ReorderableList` les ignorent complètement et
repeignent avec `header_hovered`. Et **trois opacités pour le même lavis accent
de « ligne courante »** : 0,13 (RailItem), 0,15 (InteractiveTable), et une
troisième ailleurs.

Les scrollbars et le splitter de `Layout.lua` ne lisent **aucun** jeton — zéro
occurrence de `Theme.` dans le fichier. Le splitter n'a même pas de clé :
`local color = (hovered or ...) and 0.45 or 0.25`.

---

## 6. Typographie

**Règle.** Une **échelle**, pas une liste. Quatre tailles maximum dans un outil
dense, ratio ≈ 1,2 : `caption 11 / body 13 / h2 15 / h1 18`. **Jamais deux
slots à la même taille.**

**Les nombres ne sont jamais plus petits que leur libellé.** Une valeur compte
plus que son étiquette. Chiffres tabulaires, monospace, taille ≥ body.

**Le poids porte la hiérarchie mieux que la taille** en interface dense : les
en-têtes d'Ableton sont petits et gras, pas grands.

**Tout centrage vertical se calcule sur la hauteur mesurée du glyphe**, jamais
sur un littéral.

**Aujourd'hui.** ✅ `h2 = 12` et `body = 12` par défaut, `16` et `16` dans le
thème enregistré : **les slots 3 et 4 chargent la même police**, comme les
slots 7 et 9. Le niveau sous-titre n'existe que par le gras. Et `mono_size` 14
contre `body` 16 : **les valeurs numériques sont plus petites que les libellés
posés à côté d'elles.**

Neuf slots pour quatre tailles, 25 noms pour ces quatre valeurs. Les centrages
sont écrits `y + h * 0.5 - 6`, où 6 est la moitié de `body = 12` — et le
tweaker laisse monter `body` à 24.

`ShowHelp` ne tronque ni ne renvoie à la ligne, avance de `line_h = 16` fixe
alors qu'il dessine en Body, et **abandonne silencieusement les lignes du
bas**. Trois géométries de caret. La sélection de texte n'est peinte que par
`InputText`. `TextEdit` fait 120 px de haut en dur là où `InputText` lit
`combo_height`.

---

## 7. Les icônes

**Règle.** **Un jeu, un poids.** Grille 24×24, trait 2 px, terminaisons rondes,
1 px de marge (c'est la spec Lucide). Le trait **ne s'échelonne pas
linéairement** : entre 1,5 et 2 px quel que soit le rendu, sinon une icône
16 px devient un fil qui crénelle.

**Alignement sur la grille de pixels** : trait pair → coordonnée entière,
trait impair → demi-pixel. Sinon une verticale de 2 px bave sur trois colonnes.

**Une seule convention d'ancrage** pour toutes les icônes.

**Aujourd'hui.** 107 icônes en **trois grammaires** :

| Origine | Nombre | Forme | Ancrage |
|---|---|---|---|
| Lucide (pack) | 57 | trait, `size × 0.09` | coin haut-gauche |
| Main | 14 | **pleines** (Play, Pause, Stop, Skip, Mute, Folder, Waveform, Grip…) | centre |
| Main | 24 | trait | centre |
| Main | 9 | **mixtes** (fill + trait dans le même glyphe) | centre |

✅ Zéro collision de nom : le pack ne remplace rien, il **coexiste**. Un
transport plein à côté d'un engrenage en trait dans la même barre : c'est
exactement la sensation « pas homogène ».

**Nuance importante** : des glyphes de transport pleins sont une convention
légitime — Ableton, Logic, REAPER le font. Ce n'est pas un défaut *en soi*.
Le défaut est que ce soit **accidentel** au lieu d'être une règle.

**Cible.** Règle explicite : **transport = plein, tout le reste = trait
2/24.** Les 9 mixtes sont redessinées en trait pur. L'ancrage devient le
centre partout. Le trait passe à `size × 0.083` (le ratio natif Lucide) avec
un plancher à 1,5.

---

## 8. La grammaire d'interaction

**Règle.** Un geste = un sens, dans tout le produit.

| Geste | Sens unique |
|---|---|
| molette | un pas de la valeur / une ligne de la liste |
| double-clic | remise au défaut |
| clic droit | saisie exacte / menu contextuel |
| Shift | fin (×0,25) |
| Ctrl | par pas entiers |
| survol | un pas de valeur, jamais de teinte |

**Aujourd'hui.** ✅ Cinq API publiques exportées et **jamais appelées** :
`Core.IsHot`, `Core.RegisterFocusable`, `Core.FocusNext`, `Core.FocusPrev`,
`UI.BeginDisabled`.

- **La navigation clavier est une infrastructure morte.** La chaîne de focus
  est vidée à chaque frame et jamais remplie, aucun anneau de focus n'est
  dessiné nulle part, et **TAB est capté comme touche de validation par les
  widgets mêmes qui devraient être les cibles de la navigation.**
- **Deux conversions de molette contradictoires** : `Widgets.lua:15` arrondit
  vers l'extérieur (un delta trackpad de 30 = un cran entier),
  `Layout.lua:29` reste fractionnaire (le même delta = 0,25 cran). Molette sur
  un knob puis sur le fond du panneau : l'un saute, l'autre glisse.
- 3 des 7 widgets à molette ne **consomment** pas le tick — le conteneur
  parent défile en même temps que la liste.
- **Le survol n'est pas arbitré par l'état actif** dans `Widgets.lua` (alors
  que `Layout.lua` le fait) : pendant un glissement de knob, **tous les
  boutons traversés s'allument.**
- Le désactivé : 12 contrôles sur 31 le gèrent. Trois (`Combo`, `TabBar`,
  `NumberInput`) coupent l'interaction **sans aucun indice visuel**. Et un
  glissement ou une saisie **déjà commencés** ne sont pas coupés chez
  `_Slider` et `NumberInput` — `InputText` est le seul à le faire proprement.
- 14 des 34 points interactifs n'appellent jamais `SetHot`, ce qui les rend
  **structurellement incapables de porter une infobulle**. Il y a 18 infobulles
  dans tout le dépôt ; 29 widgets sur 31 n'ont pas d'option `tooltip`.
- Six sites de double-clic pour **cinq sémantiques**, cinq de clic droit pour
  **quatre**.

**Perf.** L'hygiène est bonne : une seule closure par frame dans un chemin de
dessin (`ModKnob:2098`), tous les formats mémoïsés. Seul résidu réel : les 36
`opts = opts or {}`, soit une table vide par widget et par frame dès que
l'appelant omet ses options. Une table `EMPTY_OPTS` partagée en lecture seule
les supprime toutes.

---

## 9. L'espacement

Une seule échelle : **2, 4, 8, 12, 16, 24**. Grille de base 4 px. Toute hauteur
est paire, tout écart est membre de l'échelle.

**Aujourd'hui** : 185 offsets littéraux contre 28 lectures de jeton, et 22
constantes de hauteur en dur dans les apps pour 10 valeurs distinctes entre 14
et 34 px. Les valeurs 3 et 6 n'existent nulle part dans le thème.

---

## 10. Récapitulatif

État au 2026-07-25 après les vagues 1 et 2.

| Élément | Au départ | Maintenant | Cible |
|---|---|---|---|
| Peintures de « allumé » | **6** pour 5 contrôles | 2 (fond accent / barre sur fond neutre) | 2 |
| Peintures de « ligne sélectionnée » | **4** | **1** ✅ | 1 |
| Sémantiques du double-clic | **5** | 1 (remise au défaut) ✅ | 1 |
| Sémantiques du clic droit | **4** | 2 (saisie / menu) ✅ | 2 |
| Contrôles de valeur avec molette | **1 / 3** | **3 / 3** ✅ | 3 / 3 |
| Paramètres bipolaires lisibles | **0** | `opts.bipolar` ✅ | — |
| Fichiers de dessin hors thème | `Layout.lua` entier | **0** ✅ | 0 |
| Grammaires d'icône | **3** | 3 ⬜ | 2 (transport plein / reste trait) |
| Tailles de police distinctes | 4 pour **9 slots** | 5 pour 9 ✅ | 5 pour 5 |
| Contrôles gérant le désactivé | **12 / 31** | 12 / 31 ⬜ | 31 / 31 |
| Contrôles enregistrant `SetHot` | **20 / 34** | 20 / 34 ⬜ | 34 / 34 |
| Anneau de focus | **0** | 0 ⬜ | tous les focusables |
| Jetons `meter_*` | **0** | 0 ⬜ | 3 |

Une correction au §8 : les deux conversions de molette **ne sont pas
contradictoires**. `wheel_notches` arrondit vers l'extérieur parce qu'une valeur
ou un index est discret — un petit delta de trackpad doit bouger d'un pas ou
rien n'arrive ; `wheel_to_px` reste fractionnaire parce que le défilement est
continu. Les faire coïncider casserait le défilement fluide. Le vrai défaut
était `NumberInput`, seul site à ignorer le **nombre** de crans, et il est
corrigé.

Et deux outils qui n'étaient pas dans la spec mais qui la rendent utilisable :
l'**inspecteur** (pointer un pixel → le nom du jeton) et le **reveal**
(survoler un jeton → les zones qu'il peint s'entourent, dans toutes les
fenêtres). Une spec de soixante-cinq jetons sans moyen d'aller du pixel au nom
et retour n'est pas praticable.
