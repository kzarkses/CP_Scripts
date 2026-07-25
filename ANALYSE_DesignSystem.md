# Système de design CP — identité, jetons, et pourquoi ça ne tenait pas

> Compagnon de `ANALYSE_Design.md` (l'usage, les ponts entre apps) et de
> `ANALYSE_Nomenclature.md` (quel rôle mérite quel widget). Celui-ci regarde le
> **langage visuel** : la palette, les jetons, la structure de fenêtre.
>
> **Refondu le 2026-07-25**, après un audit transversal du dépôt (12 agents,
> 641 lectures de fichiers, chaque affirmation recontrôlée par un vérificateur
> adverse) et le décodage complet du thème REAPER que Cédric utilise vraiment.
> La version précédente (2026-07-23) posait une doctrine juste et n'avait aucun
> moyen de la faire respecter. Ce qu'elle affirmait comme acquis est ici
> **mesuré**, et l'essentiel ne tenait pas.
>
> Contrainte qui prime tout, inchangée : **PC de 2005, zéro allocation par
> frame, perf avant esthétique**.

---

## 0. Le verdict en une page

Trois phrases.

1. **On n'a pas un problème de contraste, on a un problème de lumière.** Tout
   notre système vit entre L\* 9 et L\* 30. Le thème REAPER que Cédric aime vit
   entre L\* 20 et L\* 50. Monter le contraste dans une boîte trop sombre durcit
   l'image sans jamais la découper.
2. **On n'a pas trop de niveaux de couleur, on a trop de NOMS pour trop peu de
   niveaux.** 51 clés dérivées produisent 41 valeurs distinctes ; cinq noms
   désignent littéralement la même couleur.
3. **Il n'existe aucune identité dans le code.** `Theme.Default()` n'est pas une
   palette écrite : c'est un gabarit immédiatement écrasé par `ApplyMacro`.
   L'identité du produit est donc « ce que contient `CP_Config/theme.lua` », et
   ce fichier est aujourd'hui le thème de DEBUG (texte rouge pur, fond
   turquoise). **C'est la faute mère : tout le reste en découle.**

---

## 1. Ce que dit le thème que Cédric aime (mesuré)

Thème actif dans REAPER : `Reapertips Theme – Green` v1.91, 396 clés couleur.
Décodé depuis le `.ReaperTheme` (entiers COLORREF : R = octet bas).

### 1.1 Le chrome est ACHROMATIQUE

Le fait le plus important, et celui qui contredit notre code : **la quasi-totalité
des neutres a une saturation de exactement 0.00** — R = G = B au bit près. Les
seules exceptions tintées de tout le thème sont `col_toolbar_text` (#c2c6ce),
`midi_notebg`, `genlist_selbg` et deux clés de mixer.

Notre `lvl()` teinte chaque neutre de 3,5 % vers la couleur secondaire, avec ce
commentaire : *« un gris pur se lit comme non réfléchi ; la teinte est ce qui le
fait paraître choisi »*. **C'est une maxime de design web, et elle est fausse
dans un DAW.** Dans un DAW, la couleur appartient au contenu de l'utilisateur —
ses pistes, ses clips, ses enveloppes. Le chrome doit être neutre, sinon il
entre en concurrence avec les seules couleurs qui portent une information.
Ableton, Bitwig et tous les thèmes REAPER sérieux font le même choix.

### 1.2 L'échelle neutre réelle

| Rôle | sRGB | hex | L\* |
|---|---|---|---|
| cadre extérieur du roll | 0.145 | `#252525` | 14.7 |
| **fond de fenêtre** (`col_main_bg`) | **0.196** | `#323232` | **20.8** |
| mixer, règle MIDI | 0.200 | `#333333` | 21.2 |
| barre d'outils (`col_main_bg2`) | 0.243 | `#3e3e3e` | 26.2 |
| **arrange + rangée sombre du roll** | **0.259** | `#424242` | **28.0** |
| fond de bouton (`col_buttonbg`) | 0.275 | `#464646` | 29.8 |
| **rangée claire du roll** | **0.298** | `#4c4c4c` | **32.3** |
| texte mute | 0.482 | `#7b7b7b` | 51.6 |
| texte secondaire | 0.627 | `#a0a0a0` | 65.8 |
| **texte** (`genlist_fg`, `midi_rulerfg`) | **0.784** | `#c8c8c8` | **80.6** |

Deux choses à retenir :

- **La zone de travail est PLUS CLAIRE que le chrome.** L'arrange (L\* 28) est
  au-dessus du fond de fenêtre (L\* 20.8) de 7 points. Chez nous, le canvas est
  à L\* 14.5 pour une fenêtre à L\* 9.7 : même direction, mais 13 points plus bas.
- **L'alternance des rangées du roll est DOUCE** : #424242 → #4c4c4c, soit
  **4.3 L\***. La nôtre, après le dernier commit, est de **9.5 L\*** — plus du
  double. On a sur-corrigé.

### 1.3 L'accent, et le fait que tous les rôles sont déjà là

L'identité du thème est un **vert-turquoise**, pas un vert :

| Rôle | Clé REAPER | hex | L\* |
|---|---|---|---|
| accent (bouton allumé) | `col_toolbar_text_on` | `#1abc98` | 68.3 |
| accent pressé | `col_cursor`, `midi_editcurs` | `#339887` | 57.0 |
| play / groupé | `item_grouphl` | `#33b830` | 65.9 |
| record | `env_track_mute` | `#ed474a` | 55.0 |
| **pending / attente** | `playcursor_color`, `guideline_color` | `#fec13a` | 81.6 |
| solo | `take_marker` | `#ffd830` | 87.3 |
| modulation | `col_env13` | `#b08aff` | 65.4 |

**Chacun de nos six rôles se prélève directement dans le thème qu'il aime déjà.**
Il n'y a rien à inventer. `pending` en particulier est littéralement la couleur
de son curseur de lecture — donc « ça va se déclencher là » et « on est là »
partagent une teinte, ce qui est juste.

### 1.4 La grille : elle va dans les DEUX sens

Format des `*dm` décodé : `0x0002_AA00`, où `AA` est l'alpha sur 8 bits.

| Ligne | couleur | alpha | composite sur `#424242` | ΔL\* |
|---|---|---|---|---|
| `midi_grid2` | blanc | 25 % | `#717171` (L\* 47.8) | **+19.8** |
| `midi_grid1` | noir | 20 % | `#353535` (L\* 22.1) | −5.9 |
| `midi_grid3` | noir | 50 % | `#212121` (L\* 12.8) | −15.2 |
| `midi_gridh` (octaves) | blanc | 50 % | — | — |

**Une seule ligne part vers le clair, les autres vers le sombre.** C'est une
technique, pas un hasard : la ligne la plus importante occupe un canal visuel
que rien d'autre n'occupe. Elle ne peut être confondue avec aucune autre parce
qu'elle est la seule dans sa direction.

Et — correction de ma propre doctrine du commit précédent — **l'alpha n'était
pas le coupable.** Une ligne posée en alpha sur le fond garde un poids
*relatif* constant quelle que soit la rangée qu'elle traverse ; une couleur
opaque juste sur la rangée claire est trop forte sur la rangée sombre. La vraie
faute était ailleurs : l'alpha n'était pas *dans le jeton* (il était appliqué à
`text_mute`, une clé qui ne parle pas de grille), donc aucun thème ne pouvait
l'atteindre. **La correction juste est un jeton RGBA — couleur ET alpha
écrits ensemble — pas la suppression de l'alpha.**

### 1.5 Le contenu est CLAIR sur un fond sombre

`col_mi_bg` = `#9e9e9e` : dans REAPER, un item média est un bloc **clair** posé
sur un arrange sombre, avec son libellé en `#1c1c1c` dessus. C'est l'inverse de
notre grille de Session, où les cellules sont sombres et l'accent ne sert qu'à
les teinter.

---

## 2. Ce que dit notre code (mesuré)

### 2.1 Les jetons

| Mesure | Valeur |
|---|---|
| Clés couleur définies | **63** |
| Clés réécrites par `ApplyMacro` | 51 |
| **Valeurs RGBA distinctes parmi ces 51** | **41** |
| Groupes de clés strictement identiques | **7** |
| Clés définies et jamais lues | **6** |
| Clés sans aucun éditeur dans le tweaker | **14** |
| Sites de lecture dans le dépôt | 704, sur 25 fichiers |
| Les 5 plus lues | `accent` 122, `text` 103, `text_disabled` 69, `border` 61, `text_mute` 42 |

Les sept collisions, toutes dans `Theme.lua` :

```
surface = list_bg = button_active = frame_active = header_active   (lvl 1)
surface2 = frame_bg = header                                       (lvl 2)
header_hovered = button                                            (lvl 3)
list_alt_bg = canvas_row                                           (lvl 1.5)
popup_bg ≈ tab            (même RGB, alpha différent)
list_grid ≈ list_hover    (même RGB, alpha différent)
text = canvas_playhead  ·  accent = canvas_item
```

La troisième est la plus gênante : **un bouton au repos a exactement la couleur
d'un en-tête survolé.** Ce n'est pas un état transitoire, c'est permanent.

Les six clés mortes : `close_btn`, `header_active`, `mute`, `solo`, `mod`,
`value_normal`. Quatre sont éditables dans le tweaker — **on peut les régler,
rien ne bouge.** Le commentaire de `Theme.lua` qui promet *« a theme can
restyle them once »* pour les rôles est faux pour la moitié d'entre eux.

Les quatorze sans éditeur incluent `surface`, `surface2`, `text_mute`,
`title_bar`, `title_text`, `danger`, `bypass` — c'est-à-dire les fonds de
panneau et le texte secondaire. On les voit partout, on ne les atteint nulle
part.

### 2.2 Le système de macros est DORMANT

Le point que l'audit a établi indépendamment et que j'ai revérifié :

```
$ grep -c macro CP_Config/*.lua     →  0 partout (8 fichiers)
```

`Theme.LoadSaved` fait `t.macro = nil` quand le fichier n'en contient pas.
**Donc dans tous les scripts CP\_ qui tournent aujourd'hui, `t.macro` est nil.**
L'onglet Macro n'affiche que son bouton d'opt-in ; les six boutons de macro
n'existent pas à l'écran. Le système entier est en sommeil depuis sa naissance.

Pire, il est inerte même quand il est actif : `LoadSaved` appelle `ApplyMacro`
**puis** applique les 63 couleurs littérales par-dessus (`Theme.lua:681-693`).
Au chargement, le bloc macro ne décide de rien.

### 2.3 Le thème actif est le thème de debug

`CP_Config/theme.lua` — le fichier partagé par TOUTES les apps :

```lua
text     = { 1, 0.0196078, 0.0196078, 1 },   -- rouge pur
window_bg= { 0.156863, 0.843137, 0.698039, 1 },  -- turquoise
separator= { 0.903554, 0.976471, 0.0431373, 0.5 }, -- jaune
```

Et `DEFAULT.lua`, son thème « propre », ne contient **aucune** clé `canvas_*`
ni **aucun** rôle : 44 clés sur 63. Le charger donne un hybride — chrome
littéral entre 0.18 et 0.28, canvas dérivé d'une base à 0.105. **Le piano roll
est plus sombre que la fenêtre qui le contient.** Ce n'est pas un choix visuel,
c'est un thème à cheval sur deux époques du code.

C'est la cause directe de « je n'ai pas de séparation réelle ». La séparation
existe dans le chrome et pas dans le canvas, parce que les deux viennent de
deux palettes différentes.

### 2.4 Trois régressions à moi, confirmées

- **`ToggleButton` : la barre d'accent est peinte accent sur accent.**
  `Widgets.lua:4703` met `bg = accent` quand le bouton est allumé, puis
  `:4716` dessine la barre en `accent` par-dessus. Contraste nul, la barre
  n'existe pas. Le commentaire juste au-dessus le dit presque
  (*« le remplissage porte déjà l'accent ici »*) et dessine quand même.
  Le vocabulaire unifié que j'ai annoncé n'est pas à l'écran sur ce widget.
- **Le blanc sur accent perd en lisibilité au survol** : 3,13:1 → **2,13:1**.
  Le contrôle devient moins lisible au moment précis où on interagit avec lui.
- **Les jetons `canvas_*` ne sont lus que par CP_Editor.** CP_Looper ne lit que
  les quatre `canvas_line_*` et code en dur ses rangées, son clavier et ses
  têtes de lecture ; CP_Session n'en lit aucun. « Un vocabulaire partagé » sur
  un seul consommateur n'est pas un vocabulaire.

### 2.5 La règle de 2026-07-23 n'a jamais été tenue

La version précédente de ce document écrivait : *« une app n'invente jamais un
rayon, une hauteur ou une couleur — elle nomme un jeton »*. Mesure :

| | |
|---|---|
| Sites de couleur hors thème en interface de production | **73** |
| Alphas littéraux substitués à celui d'un jeton | **102** (dont 52 sur des éléments de structure) |
| Constantes de hauteur codées en dur dans les apps | **22**, pour 10 valeurs distinctes entre 14 et 34 px |
| Offsets géométriques littéraux vs lectures de jetons d'espacement | **185 contre 28** |
| Occurrences de `Theme.` dans `CP_Toolkit/Layout.lua` | **0** |

`Layout.lua` dessine les scrollbars et le splitter de **toutes** les apps sans
jamais toucher au thème. Le splitter n'a même pas de jeton :
`local color = (hovered or ...) and 0.45 or 0.25`. Et un commentaire à
`Layout.lua:524` annonce une épaisseur *« from the theme »* via une clé
`scrollbar_thickness` **qui n'existe nulle part**.

Une règle qu'aucun mécanisme ne fait respecter n'est pas une règle, c'est un
vœu. **`FX Constellation` prouve pourtant que c'est tenable : 53 appels de
dessin, zéro RGB littéral.**

### 2.6 La structure de fenêtre n'existe pas

Huit fenêtres, **quatre formes de zone de commande** (rail vertical, barre
haute, footer bas, tabbar seule). Le bouton Settings est à **quatre
emplacements**. Le Help est à quatre rangs, absent de plusieurs fenêtres, et
dans CP_Session il est *à l'intérieur* du bloc `if attached` — donc il
**disparaît** quand le moteur n'est pas attaché, alors que CP_Looper le place
avant le même test. Quatre hauteurs de barre : 20, 24, 26, 28 px. Une fenêtre
sur huit trace un trait entre commande et contenu.

La cause est simple et n'avait pas été nommée : **le toolkit n'expose aucune
primitive de chrome de fenêtre.** Pas de `WindowTitle`, pas de `Toolbar`, pas
de `StatusBar`, pas de `Footer`. Chaque fenêtre réécrit son titre à la main —
et `iconBtn` est réimplémenté **trois fois**, avec deux signatures
incompatibles, alors que `UI.IconButton` existe.

Il n'y a pas de divergence à corriger app par app. **Il y a une primitive
manquante, et huit contournements.**

### 2.7 La typographie n'a pas de niveau intermédiaire

`h2 = 12` et `body = 12` dans le thème par défaut ; `h2 = 16` et `body = 16`
dans le thème enregistré. **Les deux slots chargent la même police** : le
niveau « sous-titre » n'existe visuellement que par le gras. Et `mono_size` 14
contre `body` 16 : les valeurs numériques sont plus petites que les libellés
posés à côté d'elles.

Neuf slots de police pour **quatre tailles distinctes**, et 25 noms
(clés + alias legacy + alias Core) pour ces quatre valeurs.

Enfin, les centrages verticaux sont écrits en dur — `y + h * 0.5 - 6` — où 6
est la moitié de `body = 12`. Le tweaker laisse régler `body` jusqu'à 24. La
casse est atteignable dans la même session.

---

## 3. Comment font les ténors — ce qui est portable

La partie de la version précédente qui tenait, resserrée.

**Ableton Live.** Chrome neutre, la couleur signifie toujours quelque chose.
Densité forte (lignes de 17-20 px), hiérarchie de section par **fond**, pas par
bordure. Knobs minimalistes : un arc fin, la valeur dans le champ voisin.

**Bitwig.** Jetons stricts, une seule échelle d'espacement. La modulation est
colorée **par source** — à garder pour ModJSFX.

**FL Studio.** Trop décoratif pour nous, mais la leçon tient : les zones de
travail restent **plates et sombres**, seul le chrome est riche.

**Vital / u-he.** Un design 100 % plat peut porter un instrument entier. Ce qui
fait le « fini », c'est l'anticrénelage, pas l'ornement.

**Et surtout, le modèle que la discipline UI a convergé à adopter — Radix
Colors.** Une rampe de 12 pas, où chaque pas a un emploi défini :

| Pas | Emploi |
|---|---|
| 1-2 | fonds d'application |
| 3-5 | fonds de composant : repos, survol, pressé |
| 6-8 | bordures : discrète, normale, forte |
| 9-10 | aplats saturés (l'accent) |
| 11-12 | texte : secondaire, primaire |

**L'état est un DÉPLACEMENT sur la rampe, pas une clé de plus.** C'est
exactement ce qui nous manque : nous avons `button` / `button_hovered` /
`button_active`, `frame_bg` / `frame_hovered` / `frame_active`, `header` /
`header_hovered` / `header_active`, `tab` / … — **douze noms pour dire trois
fois la même chose**, et c'est mécaniquement pour ça qu'ils finissent par
collisionner.

---

## 4. Le modèle cible

### 4.1 Deux couches, et une seule direction de dépendance

```
PRIMITIVES          n1 … n8   (rampe neutre, achromatique)
                    accent, accent_hi, accent_lo
                    play, record, pending, solo, mute, mod, danger
                            ↓   (alias, jamais l'inverse)
SÉMANTIQUE          surface, surface_raised, canvas, control,
                    control_hover, control_sunken,
                    border, border_soft, text, text_2, text_mute
                            ↓
WIDGETS             ne lisent QUE la couche sémantique
```

Règle dure : **un widget ne lit jamais une primitive, une app ne lit jamais un
`n<i>`.** Si un widget a besoin d'une couleur qui n'a pas de nom sémantique,
c'est le nom qui manque — pas la couleur.

### 4.2 L'état est un déplacement, pas une clé

Une seule fonction, `Theme.State(token, state)`, au lieu de trois clés par
famille : `repos → control`, `survol → +1 pas`, `pressé → −1 pas`. Ça supprime
d'un coup les douze clés d'état, les sept collisions, et la question « quelle
est la différence entre `frame_active` et `header_active` ? » (réponse
actuelle : aucune, ce sont les mêmes octets).

### 4.3 Un thème enregistré est un DIFF, pas une photo

C'est le changement le plus rentable du document.

Aujourd'hui `Theme.Save` écrit les 63 clés. Conséquence : tout thème
sauvegardé avant l'ajout d'une clé est définitivement amputé (`DEFAULT.lua`,
44 clés sur 63), et toute clé ajoutée plus tard est écrasée au chargement par
des valeurs d'une autre époque. **C'est exactement le bug que Cédric a sous les
yeux.**

Sauver uniquement ce qui diffère de `Theme.Default()` supprime cette classe
d'erreur pour toujours : un thème porte une **intention** (« j'ai changé
l'accent »), et tout le reste suit l'identité quand elle évolue. Un fichier de
thème passerait de 63 lignes à trois ou quatre.

### 4.4 Une primitive de chrome de fenêtre

`UI.AppFrame(title, opts)` qui rend : titre, barre d'outils, séparation,
contenu, barre de statut — avec la même hauteur, le même trait, le même rang
pour Settings et Help, partout. Les huit fenêtres perdent leur barre
bricolée. C'est la seule façon de faire converger la structure : pas huit
corrections, une primitive.

---

## 5. L'identité chiffrée

Achromatique, ancrée sur ReaperTips Green. **Écrite en littéraux dans
`Theme.Default()`**, pas dérivée : une identité qu'un algorithme peut réécrire
n'est pas une identité.

### 5.1 Rampe neutre

| Jeton | sRGB | hex | L\* | Δ | Emploi |
|---|---|---|---|---|---|
| `n1` | 0.145 | `#252525` | 14.7 | | fond d'application, gouttières |
| `n2` | 0.196 | `#323232` | 20.8 | +6.1 | **surface de panneau** |
| `n3` | 0.243 | `#3e3e3e` | 26.2 | +5.4 | barre d'outils, en-tête, règle |
| `n4` | 0.259 | `#424242` | 28.0 | +1.8 | **canvas**, contrôle au repos |
| `n5` | 0.298 | `#4c4c4c` | 32.3 | +4.3 | survol, rangée claire |
| `n6` | 0.345 | `#585858` | 37.4 | +5.1 | bordure discrète |
| `n7` | 0.420 | `#6b6b6b` | 45.3 | +7.9 | bordure |
| `n8` | 0.502 | `#808080` | 53.4 | +8.1 | bordure forte, **barre de mesure** |

Texte : `#c8c8c8` (L\* 80.6) · `#a0a0a0` (65.8) · `#7b7b7b` (51.6).

### 5.2 Accent et rôles

```
accent      #1abc98      accent_hi   #2fd9b2      accent_lo  #339887
play        #33b830      record      #ed474a      pending    #fec13a
solo        #ffd830      mod         #b08aff      mute       #6e7a82
```

### 5.3 Contraste vérifié

| Paire | Ratio | |
|---|---|---|
| texte / panneau `n2` | **7.66:1** | AA texte |
| texte / canvas `n4` | **6.00:1** | AA texte |
| texte secondaire / `n2` | **4.90:1** | AA texte |
| accent / panneau `n2` | **5.30:1** | AA texte |
| **noir sur accent** | **7.76:1** | AA texte |
| texte mute / `n2` | 3.03:1 | AA UI |

Note : **le texte sur un aplat d'accent doit être NOIR, pas blanc.** 7,76:1
contre 2,13:1 pour le blanc au survol. C'est le correctif direct de la
régression §2.4.

### 5.4 Grille — une seule ligne part vers le clair

Jetons RGBA, alpha compris, sur une rangée `n4` :

| Jeton | valeur | composite | ΔL\* |
|---|---|---|---|
| `grid_bar` | `n8` opaque | `#808080` | **+25.6** |
| `grid_beat` | noir α .32 | `#2d2d2d` | −9.6 |
| `grid_sub` | noir α .19 | `#353535` | −5.6 |
| `grid_fine` | noir α .09 | `#3c3c3c` | −2.6 |

Hiérarchie monotone (25.6 > 9.6 > 5.6 > 2.6), et la mesure est la seule dans sa
direction. Les trois tiers sombres étant en alpha, ils gardent le même poids
relatif sur la rangée claire comme sur la rangée sombre.

### 5.5 Alternance des rangées : redescendre

Objectif **≈ 4-5 L\*** (`n4`/`n5`), pas 9,5. On a sur-corrigé au commit
précédent : notre alternance actuelle est plus du double de celle du thème de
référence.

---

## 6. Verdict sur le Theme Tweaker

**Il reste, mais il change de statut.** Il est bon comme instrument de
développement — il a d'ailleurs servi exactement à ça cette semaine, un thème
de debug aux couleurs criardes étant le seul moyen de découvrir quelle clé
peint quoi. Ce n'est pas lui, le problème.

Le problème est qu'**il est devenu le seul endroit où l'identité existe**.
Comme `Theme.Default()` n'est qu'un gabarit écrasé par `ApplyMacro`, le produit
n'a pas de palette écrite : il a le contenu de `theme.lua`. Un éditeur ne peut
pas être la source de vérité de ce qu'il édite.

Ce qui ne va pas, mesuré :

- **L'onglet Macro et l'onglet Colors se battent, et le macro gagne en
  silence.** Chacun des six contrôles macro rappelle `ApplyMacro`, qui réécrit
  43 des 49 couleurs éditables. Un après-midi de réglage à la main disparaît au
  premier tour de bouton, sans avertissement.
- **Le même geste donne deux résultats selon le chemin.** Une retouche manuelle
  est détruite par un mouvement de macro, mais survit à un save/reload
  (`LoadSaved` applique les littéraux *après* `ApplyMacro`). C'est plus
  déroutant qu'un comportement franchement faux.
- **Le filet de sécurité est lui-même un piège.** `EndMacro` ne vide jamais
  `colors_pre_macro` et `BeginMacro` refuse de re-photographier : dériver,
  éditer, arrêter, re-dériver, re-arrêter restaure le **premier** instantané et
  jette tout le travail intermédiaire. C'est le même dégât que le mécanisme
  était censé réparer — ma correction de la semaine dernière est incomplète.
- **Les cinq presets embarquent un bloc macro sombre**, donc un preset clair est
  renoirci au premier tour de bouton.
- **14 clés sur 63 n'ont aucun éditeur**, dont `surface` et `surface2` — les
  fonds de panneau — et `text_mute`, cinquième clé la plus lue du dépôt.
- Et il alloue par frame sur la page même dont le code se plaint de le faire :
  deux concaténations par ligne de couleur visible, plus une dizaine de tables
  neuves.

**Recommandation.** Trois décisions, dans cet ordre :

1. **L'identité vit dans le code**, en littéraux, versionnée. Le tweaker
   l'ajuste, ne la définit plus.
2. **Un thème enregistré est un diff** (§4.3). Ça règle `DEFAULT.lua`, les
   thèmes amputés, et toutes les futures clés d'un seul coup.
3. **Supprimer le système de macros.** Il est dormant, inerte au chargement,
   destructeur quand il s'active, et son filet de sécurité perd des données.
   Il essaie de résoudre par le calcul un problème qui se résout en écrivant
   huit valeurs à la main — ce que le §5 vient de faire. **Une rampe de huit
   nombres écrits n'a pas besoin d'être dérivée de six autres nombres.**
   Ce que les macros apportaient de bon (« régler le contraste d'un geste »)
   survit sous une forme honnête : trois presets de densité et deux de
   luminosité, qui écrivent la rampe.

Et une addition qui vaut plus que tout le reste de l'onglet Colors : à côté de
chaque clé, **où elle est peinte**. Un jeton que personne ne peut localiser est
un jeton que personne ne peut régler — c'est textuellement ce que Cédric a
rencontré (« je ne sais même pas quelle couleur utilise pour la colonne »).
La version pauvre et robuste de cette idée est déjà dans le §4.1 : **nommer les
jetons d'après ce qu'ils peignent, et les ramener à une vingtaine.** Le besoin
de localisateur est un symptôme de cinquante noms abstraits.

---

## 7. L'ordre

Chaque étape est autonome et visible. Rien ne dépend de la suivante.

**Vague 1 — livrée le 2026-07-25 (`852c5a3`).**

1. ✅ **Écrire l'identité** (§5) en littéraux dans `Theme.Default()` — 64 clés.
   `ApplyMacro` / `BeginMacro` / `EndMacro` / `MacroDefault` supprimés, onglet
   Macro retiré du tweaker.
2. ✅ **Sauvegarde en diff** (§4.3). Les anciens fichiers pleins se chargent
   toujours et maigrissent au prochain enregistrement.
3. ✅ **Séparer les états** : les sept collisions sont tombées. Un champ
   s'enfonce sous son panneau, un bouton se lève au-dessus. `Theme.Step(n)`
   existe comme chemin d'avenir, mais les douze clés d'état **restent nommées**
   — 704 sites de lecture les désignent directement, et un renommage de masse
   n'a aucun bénéfice visible. Elles n'ont simplement plus le droit d'entrer en
   collision, et une vérification mécanique le contrôle.
4. ✅ **Les trois régressions** (§2.4), plus une quatrième trouvée en chemin :
   `opts.accent` court-circuitait la branche de survol, donc un `IconToggle`
   rouge-record allumé ne répondait plus à la souris.

En prime, hors plan initial mais dans la même faute : les presets clairs ne
repeignaient que le chrome, donc le roll restait sombre dans une fenêtre
blanche — le défaut exact de `DEFAULT.lua`. Ils basculent le canvas aussi.

**Vague 2 — la grammaire.**

5. ✅ **Une seule routine de ligne sélectionnée** (`00ddda3`). Il y en avait
   quatre, dont trois hors d'atteinte du thème. Au passage : le zébrage
   d'`InteractiveTable` était un lavis **blanc à 1,5 %** posé *après* l'état,
   donc invisible sur un thème clair et disparaissant au survol ; et le clavier
   et la souris étaient indistinguables dans le popup du combo, donc en
   flèchant on ne savait pas ce qu'Entrée allait prendre.
6. ✅ **Gestes et molette unifiés, `opts.bipolar`** (`46369a4`). Clic droit
   tape partout, double-clic remet au défaut partout, molette sur les trois
   contrôles de valeur. La poignée du slider était accent sur accent — même
   faute d'invisibilité-sur-soi que la barre du toggle.
7. ⬜ **Icônes.** Volontairement **pas** fait. Deux raisons, et la seconde est
   la vraie : (a) l'« ancrage divergent » que l'audit signalait n'existe pas —
   vérifié, les deux familles remplissent la même boîte ; (b) redessiner neuf
   glyphes sans pouvoir les regarder, c'est exactement coder dans le vide.
   Ce qui reste vrai et documenté : 14 glyphes pleins, 24 en trait, 9 mixtes,
   57 Lucide. La règle à poser est *transport plein, reste en trait*, et les
   9 mixtes sont le seul vrai défaut. À faire avec les yeux dessus.
8. 🟡 **Typo, partiel.** `h2 ≠ body` (vague 1) et `ShowHelp` mesuré + renvoyé à
   la ligne. **Reste** : les centrages `y + h * 0.5 - 6` dans les apps, où 6
   est la moitié de `body = 12` — ils se décentrent dès qu'on grossit la police,
   et le tweaker laisse monter `body` à 24.

**Vague 3 — la structure.**

9. ⬜ **`UI.AppFrame`** (§4.4), puis migrer les huit fenêtres. Supprimer les
   trois `iconBtn` locaux. C'est le plus gros morceau restant.
10. ✅ **`Layout.lua` branché sur le thème** (`0ea9f11`) : scrollbars, splitter
    (jeton créé), et le commentaire qui promettait une clé inexistante retiré.
11. ⬜ Désactivé sur les 31 contrôles, `SetHot` sur les 34, anneau de focus.
    **Correction** : les « deux conversions de molette contradictoires » ne le
    sont pas — le discret arrondit vers l'extérieur, le continu reste
    fractionnaire, et les faire coïncider casserait le trackpad. Le vrai
    défaut, `NumberInput` qui ignorait le nombre de crans, est corrigé.
12. ⬜ **Rôles morts** : brancher `mute`, `solo`, `mod`, `value_normal`,
    `close_btn` — ou les supprimer.

**Hors plan, sur demande.**

- ✅ **Inspecteur** (`dcdee2f`) : pointer un pixel dans n'importe quelle fenêtre
  CP et obtenir le nom du jeton, avec les couleurs composées en alpha
  identifiées (« Beat line, sur Row »). Pipette passée sur **E**.
- ✅ **Reveal** (`665af2a`) : survoler une couleur entoure les zones qu'elle
  peint, dans toutes les fenêtres ouvertes. C'est la réponse à la question
  qu'on a vraiment devant une clé — *qu'est-ce que je vais repeindre ?*

---

## 8. Ce qui reste vrai de la version 2026-07-23

- La technique d'arrondi (`Core.DrawRoundRectFilled`, 3 dalles + 4 disques AA)
  et son garde-fou alpha < 1. Rien à changer.
- L'arrondi hiérarchisé : bouton 4 > champ 3 > panneau 6. Il n'est simplement
  lu que par le toolkit — **six des huit fichiers de dessin d'app tracent zéro
  rectangle arrondi.**
- Les buffers bakés comme réserve de perf.
- La lecture des références (§3).

Ce qui est retiré : la promesse *« le restyle d'hier soir a touché UN fichier,
pas quatre apps »*. Elle était vraie du toolkit et fausse du dépôt — 73 sites
de couleur hors thème et 22 hauteurs en dur plus tard.
