# Roadmap — CP_Editor, égaler l'éditeur MIDI de REAPER

Ouverte le 2026-08-02, à partir de la table des **modificateurs de souris de la
config de Cédric** (Preferences → Editing Behavior → Mouse Modifiers, contextes
MIDI). Ce document tient deux choses :

1. **L'inventaire**, relevé tel quel — c'est la référence, et elle ne se
   redevine pas ;
2. **Ce que CP_Editor fait déjà en face**, et donc le manque exact.

`ROADMAP_Chantiers.md` reste LE PLAN de la suite. Celui-ci est le plan d'**une
fenêtre**, et il n'a pas de priorité sur les chantiers : il se pioche.

Une case cochée veut dire *écrit et compilé*, jamais *joué* — c'est Cédric qui
joue.

---

## 1. Ce que CP_Editor sait déjà faire

Relevé dans le code le 2026-08-02, pour que le manque soit un manque et non un
oubli de lecture.

**Grille — clic gauche**
- sur une note : sélectionne (Shift ajoute), glisse = déplace ; à 6 px du bord
  droit = redimensionne ; la note s'auditionne à la prise ;
- sur le vide : insère une note d'un pas de grille **dans la case sous le
  pointeur** (le geste de FL), et garder le bouton enfoncé en glissant à droite
  règle la longueur ;
- **Ctrl pendant un glisser = sans magnétisme.**

**Grille — clic droit** : presse = rectangle de sélection ; relâché sans avoir
bougé sur une note = supprime cette note.

**Colonne des libellés** (clavier ou pads) : clic gauche sélectionne toute la
rangée (Shift additif), clic droit auditionne.

**Molette**, sur la grille et la lane de vélocité : nue = défilement vertical,
Shift = zoom horizontal, Alt = défilement horizontal, Ctrl = zoom vertical
autour de la note pointée, **Ctrl+Shift sur une note = subdivision** (×2 / ÷2,
le *trap roll*). Bouton du milieu = panoramique.

**Lane de vélocité** : clic gauche prend la barre la plus proche, glisser règle
la vélocité — de toute la sélection s'il y en a une.

**Règle** (tous les modes depuis le 2026-08-02) : de vraies poignées — un bord de la
sélection temporelle la redimensionne, son corps la déplace, le drapeau du
curseur d'édition le déplace, un clic dans le vide pose le curseur et efface la
sélection, un glisser dans le vide en crée une. Ctrl = sans magnétisme.
~~**Inerte en mode clip**~~ — corrigé le 2026-08-02 (§5.1) : une case porte son
propre curseur et sa propre sélection, en beats.

**Clavier** : `Space` / `Shift+Space` / `Ctrl+Shift+Space` (trois départs, ceux
de REAPER), `Home`, `+` / `-`, `Ctrl+Z` / `Ctrl+Y`, `Ctrl+A` / `C` / `X` / `V`
/ `D`, `Delete`, `Q` (quantifier), `Échap`, `↑`/`↓` (transposer ±1, Shift ±12,
Ctrl dans la gamme), `←`/`→` (décaler d'un pas), `Alt`+flèches (marcher de note
en note, avec audition), `Shift+Alt`+flèches (étendre la sélection en
marchant).

Le tout est **partagé avec CP_Looper** par `CP_Engine/Roll.lua` et
`CP_Engine/RollUI.lua` : une opération ajoutée à `Roll` doit être câblée dans
les deux hôtes **dans le même changement**.

---

## 2. L'inventaire REAPER — la config de Cédric, relevée

> **La colonne « CP_Editor » date du 2026-08-02 au matin**, avant le travail
> décrit en §3. Elle n'est pas mise à jour, et c'est délibéré : c'est le relevé
> qui a fondé le plan, et un relevé qu'on repeint au fur et à mesure ne prouve
> plus rien. Ce qui est fait se lit aux cases cochées du §3. Sont encore ✗
> aujourd'hui : les quatre lignes « loop points » du glisser de règle (§7 — on
> ne les copie pas), et le changement de hauteur pendant le glisser
> d'insertion (§3.7).

### MIDI note — clic gauche

| modificateur | comportement REAPER | CP_Editor |
|---|---|---|
| (aucun) | Select note and move edit cursor | sélectionne — **ne bouge pas le curseur** |
| Shift | Add a **range** of notes to selection | ajoute **une** note |
| Ctrl | Toggle note selection | ✗ |
| Shift+Ctrl | Select note and move edit cursor ignoring snap | ✗ |
| Alt | • **Erase note** | ✗ (c'est le clic droit ici) |
| Shift+Alt | Select all notes **in measure** | ✗ |
| Ctrl+Alt | Select note **and all later notes** | ✗ |
| Shift+Win | • **Double note length** | ✗ |
| Ctrl+Win | • **Halve note length** | ✗ |

### MIDI note — glisser gauche

| modificateur | comportement REAPER | CP_Editor |
|---|---|---|
| (aucun) | Move note | ✔ déplace |
| Shift | Move note ignoring snap | ✗ (c'est **Ctrl** ici) |
| Ctrl | **Copy note** | ✗ — Ctrl est pris par « sans magnétisme » |
| Shift+Ctrl | Move note **on one axis only** | ✗ |
| Alt | • **Erase notes** | ✗ |
| Shift+Ctrl+Alt | Move note vertically ignoring scale/key | ✗ |
| Ctrl+Win | • **Stretch note positions (arpeggiate)** | ✗ |
| Shift+Ctrl+Win | • idem, sans magnétisme | ✗ |

### MIDI note edge — glisser gauche

| modificateur | comportement REAPER | CP_Editor |
|---|---|---|
| (aucun) | Move note edge | ✔ redimensionne |
| Shift | Move note edge ignoring snap | ✗ (c'est **Ctrl** ici) |
| Ctrl | Move note edge **ignoring selection** | ✗ |
| Shift+Ctrl | idem, sans magnétisme | ✗ |
| Alt | **Stretch notes** | ✗ |
| Shift+Alt | Stretch notes ignoring snap | ✗ |
| Shift+Win | • Move note edge ignoring snap | ✗ |

### MIDI piano roll (le vide) — clic gauche

| modificateur | comportement REAPER | CP_Editor |
|---|---|---|
| (aucun) | • **Insert note** | ✔ insère dans la case |
| Ctrl | Deselect all notes and move edit cursor ignoring snap | ✗ |
| Alt | Deselect all notes | ✗ |
| Shift+Alt | Insert note ignoring snap | ✗ |
| Shift+Ctrl+Alt | Insert note | ✗ |

### MIDI piano roll (le vide) — glisser gauche

| modificateur | comportement REAPER | CP_Editor |
|---|---|---|
| (aucun) | Insert note, drag to extend or change pitch | ✔ (l'extension ; **pas** le changement de hauteur) |
| Shift | idem, sans magnétisme | ✗ |
| Ctrl | **Copy selected notes** | ✗ |
| Alt | **Erase notes** | ✗ |
| Shift+Alt | Erase notes ignoring snap | ✗ |
| Ctrl+Alt | **Paint a straight line of notes** | ✗ |
| Shift+Ctrl+Alt | **Paint notes and chords** | ✗ |

### MIDI ruler — clic gauche

| modificateur | comportement REAPER | CP_Editor |
|---|---|---|
| (aucun) | Move edit cursor | ✔ (modes take/item) |
| Shift | Select notes or CC **in time selection** | ✗ |
| Ctrl | Move edit cursor ignoring snap | ✔ |
| Alt | **Clear loop or time selection** | ✗ |

### MIDI ruler — glisser gauche

| modificateur | comportement REAPER | CP_Editor |
|---|---|---|
| (aucun) | Edit **loop points** (règle) ou **time selection** (grille) | ✔ time selection uniquement |
| Shift | *Move* au lieu de *edit* | ✔ (par la poignée « corps ») |
| Ctrl | idem, sans magnétisme | ✔ |
| Shift+Ctrl | move, sans magnétisme | ✔ |
| Alt | Edit loop point **et** time selection ensemble | ✗ (pas de loop points) |
| Shift+Alt | Move les deux ensemble | ✗ |
| Ctrl+Alt | Edit les deux, sans magnétisme | ✗ |
| Shift+Ctrl+Alt | Move les deux, sans magnétisme | ✗ |

---

## 3. Ce qu'il faut construire, dans l'ordre où ça se tient

**Fait le 2026-08-02 : 3.1 à 3.7, la section 4, et la 5.1/5.2.** Ce qui reste
est en fin de document — la fenêtre de capture (§6), les gestes de molette, les
lanes de CC.

L'ordre n'est pas celui des tableaux : il est celui des **dépendances**. Chaque
étape rend la suivante moins chère.

### 3.1 — Trancher la collision Ctrl / Shift

**À faire en premier, et une seule fois.** Chez REAPER, **Shift** ignore le
magnétisme et **Ctrl** copie. Chez CP_Editor, **Ctrl** ignore le magnétisme et
rien ne copie. Les deux conventions ne peuvent pas coexister, et tout le reste
du document en dépend : la moitié des lignes manquantes sont des combinaisons
*avec* l'un ou l'autre.

- [x] Passer « sans magnétisme » sur **Shift**, libérer **Ctrl** pour la copie.
      Shift est aujourd'hui « sélection additive » sur la grille — qui devient
      **Ctrl**, comme chez REAPER (*Toggle note selection*).
- [x] Le faire **dans `RollUI` et les deux hôtes en même temps** ; un éditeur
      qui n'obéit pas aux mêmes doigts que l'autre est pire que les deux
      anciens.

### 3.2 — Le trousseau de modificateurs

- [x] `Core.ModWin()` — le bit 32 de `mouse_cap`, que le toolkit n'expose pas
      encore alors que quatre lignes de la config de Cédric s'en servent
      (double/halve length, arpeggiate).
- [x] **Une table**, pas une cascade de `if`. Un `modmask` (ctrl|shift|alt|win)
      calculé une fois par frame, et un dictionnaire geste → action. C'est ce
      qui rend le point 5 de ce document possible : **on ne peut rendre
      configurable que ce qui est déjà une donnée.**

### 3.3 — La gomme, partout où REAPER la met

Trois contextes, un seul mécanisme : Alt efface. Aujourd'hui il n'y a que le
clic droit, et il ne fait pas de traînée.

- [x] Alt+clic sur une note = supprime.
- [x] Alt+glisser sur la grille = **gomme à la traînée** (tout ce que le
      pointeur traverse).
- [x] Shift+Alt = idem, sans magnétisme.

### 3.4 — Les sélections riches

Ce sont les quatre lignes de « MIDI note — clic gauche » et ce sont, à l'usage,
celles qui font gagner le plus de temps.

- [x] Shift+clic = ajoute la **plage** entre l'ancre et la note cliquée.
- [x] Ctrl+clic = bascule une note dans la sélection.
- [x] Shift+Alt = toutes les notes de la mesure.
- [x] Ctrl+Alt = cette note et toutes celles qui suivent.
- [x] Alt+clic dans le vide = tout désélectionner.
- [x] Sur la règle, Shift+clic = sélectionner les notes de la sélection
      temporelle.

### 3.5 — Les contraintes de déplacement

- [x] Shift+Ctrl = déplacement sur **un seul axe** (celui du plus grand
      mouvement, verrouillé à la prise).
- [ ] Shift+Ctrl+Alt = déplacement vertical **hors gamme** — `Roll` connaît
      déjà la gamme (`Roll.scale_on`, `TransposeInScale`), donc c'est la
      dérogation qui manque, pas la contrainte.

### 3.6 — Les longueurs et les bords

- [x] Ctrl sur un bord = redimensionner **cette** note en ignorant la
      sélection.
- [x] Alt sur un bord = **étirer** (le groupe se dilate au lieu de se
      déplacer) ; Shift+Alt sans magnétisme.
- [x] Shift+Win / Ctrl+Win au clic = doubler / diviser la longueur. Deux
      lignes, une fois `ModWin` posé.

### 3.7 — Les gestes qui écrivent

Les plus gros, et les seuls qui demandent de vraies fonctions dans `Roll`.

- [x] **Copier en glissant** (Ctrl) — la note, ou la sélection entière.
- [x] **Peindre une ligne droite** (Ctrl+Alt) — des notes régulières entre le
      point de prise et le pointeur, au pas de la grille.
- [x] **Peindre notes et accords** (Shift+Ctrl+Alt) — la même chose, mais
      l'accord de la gamme sous la hauteur pointée.
- [x] **Arpéger** (Ctrl+Win) — étirer les *positions* d'un groupe sans toucher
      aux longueurs. `Roll.Reverse` et `Roll.Legato` montrent la forme :
      une passe sur la sélection, une seule écriture.
- [ ] Le glisser d'insertion doit aussi **changer la hauteur** en montant ou
      descendant, pas seulement la longueur. *(reste à faire)*

---

## 4. Le curseur d'édition dans l'éditeur

Trois lignes de la config de Cédric le déplacent (clic sur une note, clic dans
la règle, Ctrl+clic dans le vide). CP_Editor ne le déplace que depuis la règle,
et **jamais en mode clip**.

- [ ] Le clic sur une note pose le curseur à son début (mode take/item).
      *(reste à faire — le seul point de la section 4 encore ouvert)*
- [x] Ctrl+clic dans le vide : désélectionne **et** pose le curseur, sans
      magnétisme.

---

## 5. La liberté de lecture — « à la Ableton »

C'est la demande de Cédric du 2026-08-02, et elle mérite d'être découpée,
parce que ses trois morceaux n'ont pas du tout le même coût.

### 5.1 — Un curseur et une sélection **locaux** à la case — gratuit

En mode clip, la règle est délibérément inerte : le commentaire dit *« edit
cursor / time selection are project concepts; a clip has neither »*. C'est vrai
du curseur **du projet** — pas d'un curseur **de la case**, qui est de l'état
de fenêtre pur et ne coûte rien.

- [x] Un `state.clip_cursor` et un `state.clip_sel_a/b`, **en beats de la
      case**, avec les mêmes poignées que la règle du mode take.
- [x] Ce qu'ils débloquent immédiatement : quantifier / supprimer / transposer
      **dans la plage**, coller au curseur, sélectionner par le temps. Toutes
      ces opérations existent déjà dans `Roll` et ne prennent pas de plage —
      c'est le seul argument qui leur manque.

### 5.2 — Lire à partir d'ici — un champ d'ABI, et une décision

C'est celui qui touche le moteur. La phase d'une lane est publiée par le C++
comme `pb mod Lb` : elle est ancrée sur le **beat zéro du projet**, jamais sur
l'instant du lancement. C'est ce qui verrouille toutes les boucles sur la même
grille, et c'est le fondement du moteur — on n'y touche pas.

**Mais un décalage constant ne le casse pas.** `phase = (pb + off) mod Lb`
laisse la case verrouillée à la grille, à un décalage près qui ne dérive pas.
C'est exactement ce que fait le *legato launch* d'Ableton, et c'est ce que
« lire à partir d'ici » veut dire.

- [x] Un champ `offset` par lane dans `cp_lanes.cpp`, ajouté **au seul endroit
      où la phase est publiée**. `Cells` relit `Loop.Phase` à chaque frame :
      l'audio suit sans une ligne de plus.
- [x] Le clic dans la règle d'une case écrit `offset = (position cliquée −
      phase courante)`, quantifié comme un lancement.
- [x] ⚠️ **Une réserve à écrire dans le code** : deux cases d'une même colonne
      partagent la colonne, pas l'offset. L'offset appartient à la LANE.

### 5.2 bis — Ce que le scrub NE fait pas, et pourquoi

- Il ne s'applique qu'à une case qui **sonne** : déplacer une case à l'arrêt
  n'a pas de sens, elle repartira de la grille quand on la lancera.
- Il n'est appelé **ni à chaque frame d'un glisser** — chaque appel fait
  rentrer la voix audio au nouvel endroit, et soixante rentrées par seconde
  s'entendent comme un bourdonnement — mais une fois à la prise et une fois au
  relâchement.
- Il n'est **pas quantifié**. Ableton aligne son scrub sur le quantize global ;
  ici c'est un geste d'édition, et attendre une mesure pour voir où l'on a
  cliqué serait une gêne, pas une aide. À rediscuter après usage.

### 5.3 — La zone de lecture d'une case — après le 5.1

Le début et la fin de boucle **dans** la case (le *loop brace* d'Ableton), qui
est la version musicale de « je ne veux entendre que ces deux mesures ».

- [x] Réutiliser la sélection locale du 5.1 comme zone de lecture, sur un
      commutateur — pas automatiquement : une sélection sert d'abord à éditer.
      `L` en fait la zone de lecture, `Ctrl+L` l'efface.
- [x] Un vrai couple début/fin par lane dans le C++ (`loopa` / `loopb`,
      **ABI 2.1**), et le portail MIDI qui les honore.
- [x] **Ce n'est pas une porte, c'est une longueur de boucle.** Bâillonner les
      notes du dehors aurait laissé la case tourner sur ses quatre mesures en
      n'en faisant sonner que deux — deux mesures de musique, deux de silence.
      La case *devient* une boucle de deux mesures. Le harnais compte les notes
      pour trancher entre les deux, parce que l'oreille ne le fait pas.
- [x] **Sa propre bande**, les sept pixels du haut de la règle, en mode case
      seulement. Pas un modificateur de la règle : les deux poignées se posent
      au même endroit — on fait une sélection, puis on en fait la zone de
      lecture — donc un même pixel aurait porté les deux. Un bord
      redimensionne, le corps déplace, le vide crée, Alt efface.
- [x] Dessinée comme un **dehors éteint** et non comme un dedans coloré : ce
      qu'on doit lire d'un coup d'œil, c'est ce qui ne sonnera pas — et un
      dedans coloré se confondrait avec la sélection temporelle.
- [x] **Persistée** (format 7), contrairement au décalage de phase : un
      décalage est un geste de jeu, une accolade est une édition.
- [x] Le son suit : `Cells` confondait « longueur de la case » et « longueur
      d'une passe », ce qui aurait fait tourner les notes sur deux mesures et
      le son sur quatre.
- [ ] Côté audio, la région en frames source (`loop_start` / `loop_end`, portée
      par la voix depuis le chantier 4a) reste **indépendante** de l'accolade :
      l'une découpe la matière, l'autre le temps. Les réunir dans une seule
      interface est une question ouverte, pas un manque.

---

## 5 bis. Ce qui accompagne une note

Demande de Cédric du 2026-08-02 : *« des choses spécifiques aux notes… jouer
des notes avec probabilité à chaque boucle… tout ce qui accompagne les notes
(vel, prob, …) dans la section en dessous des notes, et en faire une section
collapsable »*.

- [x] **La section se replie**, et son en-tête survit au repliement : treize
      pixels qui portent le chevron et le nom de ce qu'on règle. Une section
      qu'on replie sans laisser de poignée est une section qu'on a perdue.
      L'état est persisté avec les autres réglages de fenêtre.
- [ ] **Une liste dans l'en-tête** pour choisir ce qu'on règle. Elle attend
      d'avoir deux entrées : un sélecteur à un seul choix ment sur ce qui
      existe.

### La probabilité — le chantier, et il est décidé

**Elle ne peut exister qu'en mode case.** Le MIDI de REAPER n'a pas de champ
par note où la ranger : sur un take, il faudrait la coder dans un événement de
notation, la voir se perdre à chaque glisser, et l'expliquer. La lane, elle,
est notre format — c'est là que ça se fait, et la limitation se dit plutôt
qu'elle ne se contourne.

**Le tirage est SANS ÉTAT, et c'est ce qui le rend possible dans le fil
audio.** Une note tirée au sort doit garder sa décision pendant toute la
passe — sinon elle s'allume et s'éteint en cours de note — ce qui semble
demander une mémoire par note et par passe. Ça n'est pas nécessaire :

```
pass  = floor(pref / Ls)                  // l'index de passe, déjà calculable
h     = hash2(index_de_note, pass ^ graine_de_lane)
if (h & 0xFF) >= prob  →  cette note se tait CE TOUR-CI
```

Le hachage ne dépend que de `(note, passe)`, donc il est **constant pendant
toute la passe** et **identique pour l'attaque et pour la coupure**. Zéro
octet d'état, zéro allocation, et le harnais peut prouver la distribution
parce qu'elle est reproductible — ce qu'un vrai générateur aléatoire ne
permettrait pas.

La graine par lane empêche deux lanes portant les mêmes notes de tirer à
l'identique, ce qui s'entendrait immédiatement comme un artefact.

**Ce que ça coûte ailleurs** : un octet dans `LaneNote`, un septième argument
à `CP_LaneSetNote` / `CP_LaneGetNote` (**ABI 2.2**), un champ de plus dans le
format de sérialisation (**8**), et la lane de la section ci-dessus qui
l'édite. Rien dans `Cells` : une case audio n'a pas de notes.

**Pourquoi ce n'est pas fait le 2026-08-02** : le moteur venait de recevoir
deux corrections de datation le même soir, et empiler un tirage dans la porte
avant que Cédric ait entendu les premières aurait mélangé deux causes dans le
même symptôme. C'est exactement ce qui a coûté la soirée de l'ABI 1.10.

---

## 6. Rendre les raccourcis configurables — l'ADN de REAPER

Demande de Cédric du 2026-08-02 : *« à terme, rendre configurable tous les
raccourcis et modificateurs, dans des réglages, pour chaque module de
CP_Scripts. REAPER style, c'est dans son ADN. »*

**Ce n'est pas un chantier d'interface, c'est un chantier de forme.** Tant
qu'un raccourci est un `if char == 113` au milieu d'une fonction, il n'y a rien
à configurer : il faut d'abord que la liaison soit une **donnée**.

- [x] **Une table de liaisons par module**, déclarée en haut du fichier :
      `{ id, défaut, contexte, libellé }`. Les fonctions ne testent plus un
      code de touche mais un **identifiant d'action**.
- [x] **Un module partagé**, `CP_Engine/Keymap.lua` : charge les défauts,
      applique le fichier de l'utilisateur, répond `Keymap.Action(char, mods,
      contexte)`. Un seul endroit qui sait lire une combinaison.
- [x] **Le stockage dans `CP_Config/`**, comme le reste des réglages de Cédric
      — un fichier Lua lisible, pas un ExtState opaque.
- [x] **Une fenêtre d'édition** — `CP_Tools/CP_Keymap.lua` (2026-08-02).
      Liste par groupe, filtre, marque les conflits, capture une nouvelle
      liaison. L'obstacle n'était pas le dessin : les vocabulaires vivaient
      **dans** les scripts, donc une fenêtre séparée — un autre état Lua — ne
      les aurait jamais vus. Ils sont sortis dans
      `CP_Engine/Keymaps/<module>.lua`, chargés par l'application **et** par la
      fenêtre.
      Trois décisions qui font que l'outil sert : l'échappatoire de la capture
      est la **souris**, jamais une touche (toute touche doit pouvoir être
      assignée, Échap comprise) ; la frappe est lue **avant** que le toolkit ne
      la distribue, sinon Entrée validerait un champ au lieu d'être capturée ;
      et un tampon ExtState fait relire les fenêtres déjà ouvertes une fois par
      seconde — sans lui il faudrait fermer et rouvrir CP_Editor après chaque
      réglage, c'est-à-dire ne jamais tester ce qu'on règle.
- [ ] **Les autres modules.** Seul `editor` a un vocabulaire. CP_Session,
      CP_Sampler et CP_Looper suivront le même chemin : un fichier dans
      `CP_Engine/Keymaps/`, une ligne dans la liste des modules de la fenêtre.

**Réserve honnête** : `gfx.getchar` ne rapporte pas tout. Certaines touches
mortes et certaines combinaisons ne remontent pas, et le clavier AZERTY décale
les codes des touches de ponctuation. La fenêtre d'édition doit donc afficher
**ce qu'elle a reçu**, pas ce qu'elle croit avoir reçu — sinon on configure un
raccourci qui ne se déclenchera jamais.

---

## 7. Ce qu'on ne copie pas

- **Les onze lignes de modificateurs Win+ de REAPER.** La touche Windows sert
  au système ; on n'en prend que les deux que Cédric utilise réellement
  (double/halve length, arpeggiate) et on laisse le reste libre pour la
  configuration du point 6.
- **Les CC comme une lane par contrôleur.** La lane de vélocité couvre ce dont
  la suite a besoin aujourd'hui ; ouvrir les CC est un chantier à part, avec
  son propre modèle de données.
- **Les loop points séparés de la sélection temporelle.** Quatre lignes de la
  table de la règle les combinent ; ici la sélection *est* la zone, et un
  second couple de bornes doublerait l'état sans doubler l'usage.
