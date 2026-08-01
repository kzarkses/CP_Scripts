# FL STUDIO comme référence — ce qu'il fait autrement, et ce qui vaut d'être volé

Analyse faite sans éditer un fichier. Documents lus avant de conclure : `ANALYSE_Ableton_Session.md`, `ANALYSE_SessionView.md`, `ANALYSE_Design.md`, `ROADMAP_Autonomie.md` (§« ce qui n'est PAS au programme » + session 21). Les décisions déjà actées y sont respectées : modèle Ableton pour `CP_Session`, pas de scènes dans le moteur, pas de conteneur propriétaire, pas de piste d'infrastructure.

Chaque affirmation sur FL est marquée **vérifié (URL)** ou **de mémoire**. Chaque affirmation sur CP est citée `fichier:ligne`.

---

## 1. LE MODÈLE — pattern vs clip-par-piste

### Ce que FL fait

**Un pattern contient les notes de TOUS les channels à la fois.** Vérifié ([channelrack.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm)) : *« Every pattern has access to all instruments in the rack. In other words, all patterns play from the same set of instruments. Patterns are not limited to a single instrument as they are in most other sequencers. »* Le pattern est une **tranche horizontale du rack entier**, pas un objet d'une piste.

**Une piste de Playlist n'est liée à rien.** Vérifié ([playlist.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm)) : *« Playlist tracks are not restricted to a single instrument, audio recording, or Clip type »*, *« you can place any Clip type anywhere and even overlay Clips »*. Trois types de clips coexistent sur n'importe quelle piste : Pattern Clips, Audio Clips, Automation Clips. Un mode optionnel **Track Mode** rétablit la relation 1:1 instrument ↔ piste playlist ↔ piste mixer pour ceux qui veulent un DAW classique. Vérifié : plusieurs **Arrangements** par projet, partageant le même Channel Rack et le même Mixer.

### Ce que ça change au quotidien

- **L'unité de travail est la section, pas le clip.** En FL on fabrique « le pattern du couplet » : batterie + basse + lead ensemble, un seul objet. En Ableton (et dans `CP_Session`) une scène est l'**assemblage** de N clips indépendants. Dupliquer une section en FL = cloner un pattern, un geste. Dupliquer une scène en CP = N copies de cellules.
- **L'axe vertical est libre.** Comme la piste playlist n'est pas un instrument, on range par sens (drums / vox / FX / transitions), pas par chemin de signal.
- **Le prix : aucune exclusivité garantie.** Deux Pattern Clips sur deux pistes playlist qui pilotent le même channel **s'additionnent**, ils ne se remplacent pas (conséquence directe du fait que la piste n'est pas l'instrument — de mémoire pour l'addition, structurellement impliqué par la doc vérifiée). Le modèle Ableton donne l'exclusivité gratuitement. C'est pourquoi la discipline FL réelle est « un pattern par groupe d'instruments » — les utilisateurs reconstruisent à la main ce qu'Ableton impose.

### Verdict pour CP

**Ne pas rouvrir le choix.** `CP_Session` a pris le modèle Ableton, et il est déjà structurel, pas cosmétique : une colonne possède une paire de lanes (`CP_Engine/Loop.lua:725-730`, `LiveLane`/`TwinLane`), donc l'exclusivité est acquise par construction, exactement comme `ANALYSE_Ableton_Session.md` §3.1-3.2 l'a décidé. Le modèle pattern n'est pas transposable sans jeter ça.

**En revanche, la conséquence est volable, et elle coûte une boucle :** *dupliquer une scène entière vers la ligne suivante*. Aujourd'hui la copie est **par cellule** (`CP_Session/CP_Session.lua:2440-2455` : drag d'une cellule vers une autre). Le geste FL — « je veux une variation de toute la section » — n'existe pas. Un item « Duplicate scene → prochaine ligne libre » dans le menu du lanceur de scène, c'est une boucle sur les colonnes qui appelle le code de copie qui existe déjà. **Meilleur rapport valeur/effort de cette section.**

---

## 2. LE PERFORMANCE MODE

Tout ce paragraphe est vérifié sur [playlist_performance.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_performance.htm), recoupé par [la doc de l'API Python](https://maddyguthridge.github.io/FL-Studio-API-Stubs/tutorials/performance_mode/).

### Comment il marche

La **zone de performance est la partie de la Playlist AVANT le marqueur de départ**. Ce n'est pas une autre fenêtre : c'est le même canevas, à gauche. Enregistrer une performance dépose les clips **à droite** du marqueur pour le rendu. Contrainte identique à Ableton : *« Only one Clip per Playlist track can play at a time. »*

Quatre réglages, **tous par PISTE de playlist, pas par clip** :

| Réglage | Valeurs |
|---|---|
| **Motion** | Stay · One shot · March & wrap · March & stay · March & stop · Random · **Exclusive random** (jamais deux fois le même d'affilée) |
| **Press** | Retrigger · Hold & stop · Hold & motion · Latch |
| **Trigger sync** | Off · 1/4 beat → 4 beats · **Auto** (= la longueur du clip, jusqu'à 4 temps) · **Queue** · **Tolerant** |
| **Position sync** | Off · 1/4 beat → 4 beats · **Auto** (= la position courante du morceau) |

Les **scènes** ne sont pas des objets : trois conventions au choix — (a) une **région de marqueur** groupe le premier clip de chaque piste à cette position, (b) un **Clip group** créé à la main (Ctrl+Shift+clic puis Shift+G), (c) un **Track group**. Deux boutons : **Scene** remplace tout ce qui joue ; **+Scene** *superpose* — il ne remplace que les pistes qui ont du contenu dans la scène entrante et laisse les autres jouer.

Contrôle : clic gauche = déclencher, **clic droit = arrêter**, Ctrl+clic = scène/groupe, Alt = ignorer le snap, Shift = mettre en file. Au MIDI : une octave = une piste playlist, les 12 notes = les 12 premiers clips ; notes 120-127 = navigation, Scene mode, +Scene mode, snap global. (FL permet aussi le clavier alphanumérique — c'est du **déclenchement de clip**, pas de la saisie de notes, donc hors du refus acté ; je le cite pour l'exactitude, je ne le propose pas, la valeur est faible ici.)

### Ce que FL fait MIEUX qu'Ableton

1. **Motion par piste au lieu de Follow Actions par clip.** Sept comportements, un réglage, zéro dialogue. Ableton exige un panneau par clip (action A, action B, probabilité, durée) — de mémoire pour la forme exacte du panneau, la liste des actions est celle d'`ANALYSE_Ableton_Session.md` §2.3. FL couvre 90 % de l'usage réel (« mes 8 variations tournent ») avec 10 % de l'interface.
2. **Position sync.** C'est le Legato d'Ableton, généralisé : au lieu d'un booléen, une granularité (1/4 de temps → 4 temps) et un mode Auto « pars d'où en est le morceau ». Ableton n'offre que Legato on/off par clip (de mémoire).
3. **Tolerant.** Vérifié : *« Clips normally missed when triggered slightly late will be triggered immediately. »* Un déclenchement 30 ms en retard part **maintenant** au lieu d'attendre une mesure entière. Personne d'autre ne fait ça (de mémoire pour « personne d'autre »).
4. **+Scene.** Superposer au lieu de remplacer, sur un deuxième bouton. Ableton n'a que le remplacement (une préférence change le comportement globalement, pas au geste).
5. **Clic droit = stop.** Pas de colonne de boutons stop, pas de menu.
6. **Aucune dualité Session/Arrangement.** La zone de performance et l'arrangement sont le même canevas, donc « capturer une performance » est trivial : on écrit à droite du marqueur.

### Ce que FL fait MOINS BIEN

1. **Tout est par piste, rien par clip.** On ne peut pas dire « ce clip-ci est un one-shot de fill, les autres bouclent » sans lui dédier une piste. Le launch box par clip d'Ableton est strictement plus expressif.
2. **Pas de quantisation de lancement globale visible.** Trigger sync est par piste : un set a N quantisations par défaut, il n'y a pas la valeur unique de la barre d'outils d'Ableton (de mémoire pour l'absence).
3. **Les scènes ne sont pas des objets.** Pas de ligne nommée, pas de réordonnancement, pas de tempo par scène. Une « scène » FL est un marqueur, un groupe manuel ou un groupe de pistes.
4. **La zone de performance mange le canevas.** Long arrangement + grosse banque de clips se disputent le même espace (de mémoire).

### Où en est `CP_Session` — vérifié dans le code

| Concept | État CP |
|---|---|
| Exclusivité par colonne | ✅ par construction, `Loop.lua:725-730` |
| Grille pistes × scènes | ✅ `CP_Session.lua:2371-2480` |
| Lancement de scène « à l'Ableton » (les colonnes vides s'arrêtent) | ✅ `CP_Session.lua:881-883` |
| Quantisation de lancement | ✅ mais **globale seulement** — `Loop.SetLaunchQ/GetLaunchQ`, `Loop.lua:575-576`, réglée depuis la barre `CP_Session.lua:416-432` |
| Trigger / Latch | ✅ `Loop.ToggleClip`, `Loop.lua:564` |
| **Motion / March / Random** | ❌ aucune trace (grep sur `Follow`/`Motion` dans `Loop.lua` + `CP_Session.lua` : rien) |
| **Position sync / Legato** | ❌ un lancement part toujours de 0, sauf le chemin de rattrapage décrit en session 21 du roadmap |
| **Tolerant** | ❌ |
| **+Scene** | ❌ `sceneLaunch` arrête toujours les colonnes sans clip |
| Stop par colonne | ✅ mais dans le menu : `CP_Session.lua:1224` |

### Ce que je volerais, classé

1. **Motion par colonne** (Stay / March & wrap / March & stay / Random / Exclusive random). C'est les Follow Actions avec l'essentiel de la valeur musicale et un dixième de l'UI : un enum dans l'en-tête de colonne, pas un panneau par cellule. Entièrement en Lua : `Loop.Pending`/`Loop.PendingTarget` publient déjà la frontière (`Loop.lua:676-687`), donc « quand la lane vivante atteint sa frontière, lance la cellule suivante non vide de cette colonne » est un test dans le poll qui lit déjà la phase (`Loop.Poll`, `Loop.lua:1012`). Coût de stockage : un champ par colonne dans le blob de session.
   **Ça rivalise directement avec** la phase 3 d'`ANALYSE_Ableton_Session.md` §5 (« Follow Actions A/B avec probabilité, par clip »), et c'est strictement moins cher. **Recommandation : faire la version FL d'abord, par colonne. N'ajouter une surcharge par cellule que si le grain colonne se révèle trop grossier** — ce qui se saura en jouant, pas en spéculant.
2. **Tolerant.** Si le clic tombe dans les X ms *après* une frontière (mettons 1/8 de l'unité de quantisation), on part immédiatement au lieu d'attendre une période. Coût : une comparaison dans le chemin de lancement et une constante. C'est la chose la plus humaine de toute la liste FL, et elle est unique.
3. **+Scene.** Ctrl+clic sur le triangle de scène = ne lancer que les colonnes qui ont un clip dans cette ligne, laisser les autres jouer. Coût : un booléen passé à `sceneLaunch` (`CP_Session.lua:883`). Valeur haute : la ligne de scène passe de « l'image complète » à « un changement », qui est ce qu'on veut réellement en plein jam.
4. **Alt+clic sur une cellule = stop de la colonne.** FL met le stop sur le geste ; ici le clic droit est déjà pris par le menu (`CP_Session.lua:1219-1227`), donc c'est Alt+clic ou rien. Petit, mais c'est un geste par mesure gagné.
5. **Queue.** Shift+clic met en file, les cellules partent dans l'ordre. Plus gros, et recouvre partiellement Motion. À classer après.

**À NE PAS voler : la zone de performance dans l'arrangement.** `CP_Session` est une fenêtre séparée et c'est le bon choix — l'arrangement appartient à l'utilisateur, et c'est exactement l'acquis « pas de piste d'infrastructure » qu'il ne faut pas défaire.

---

## 3. LE PIANO ROLL — la référence du genre

### L'inventaire exact du menu Tools

Vérifié ([pianoroll_menu.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm)), avec les raccourcis :

> Riff machine (Alt+E) · Generate chord progression (Alt+P) · Quick legato (Ctrl+L) · Articulate (Alt+L) · Quick quantize (Ctrl+Q) · Quick quantize start times (Shift+Q) · Quantize (Alt+Q) · Quick chop (Ctrl+U) · Chop (Alt+U) · Glue (Ctrl+G) · Arpeggiate (Alt+A) · Strum (Alt+S) · Flam (Alt+F) · Claw machine (Alt+W) · Limit (Alt+K) · Flip (Alt+Y) · Randomize (Alt+R) · Scale levels (Alt+X) · LFO (Alt+O) · Script… (+ Run last script again, Ctrl+Alt+Y) · Stamp

Ce que chacun fait précisément :

- **Strum** — vérifié ([pianoroll_strum.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_strum.htm)) : traite les notes partageant un start comme un accord. *Time offset* (le signe donne le sens grave→aigu), **Tension** (le strum accélère ou ralentit), *Velocity change*, *Preserve end*, une section End avec sa propre tension, **Alternate direction** entre accords successifs, **Chop chords**.
- **Flam** — vérifié ([pianoroll_flam.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_flam.htm)) : insère des frappes de grâce avant chaque note. *Time*, *Absolute* (synchro tempo ou pas), *Before*, *Velocity*, *Group notes*.
- **Claw machine** — vérifié ([pianoroll_claw.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_claw.htm)) : *« removes notes, adds notes and/or shifts the timing of notes to create interesting new rhythms »*. *Period*, *Trash every*, **Time distortion** (décale l'effet vers le début ou la fin de la période → effet balle qui rebondit), *Remove short notes*, *Stretch to compensate*.
- **Chopper** — vérifié ([pianoroll_chp.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_chp.htm)) : découpe les notes **en suivant un fichier de score (.fsc) servant de gabarit**. *Time multiplier*, *Level knobs* (mélange les propriétés du gabarit avec celles de la note), *Absolute* (grille du piano roll) vs *Relative* (chaque note se découpe depuis son propre départ), *Group notes*. Les gabarits vivent dans `Data\Patches\Scores\Arpeggiator`.
- **Quantizer** — vérifié ([pianoroll_qnt.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_qnt.htm)) : **le groove template est un fichier de score .fsc dont seules la position et la longueur comptent, la hauteur est ignorée**. La grille résultante se dessine en lignes rouges. *Start time* (force), *Sensitivity* (à quelle distance une note est attirée), *Duration*, et un mode qui choisit d'ajuster la durée, la fin, ou de préserver l'original.
- **Arpeggiator** — vérifié ([pianoroll_arpeggiate.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_arpeggiate.htm)) : le motif est **un score .fsc lu relativement à C5**. *Range* (octaves), *Range pattern* (Normal / Flip / Alternate), *Time multiplication*, *Gate*, *Sync* (Time / Block / Chord), **Levels** (mélange pan/volume/pitch du motif dans les notes), *Group notes*.
- **Articulator** — vérifié ([pianoroll_articulate.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_articulate.htm)) : presets *Legato / Portato / Staccato*, *Multiply* 10-100 %, *Variation*, *Seed*, *Chop chords*, *Use lengths*, *Only with selection*.
- **Key limiter** — vérifié ([pianoroll_limit.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_limit.htm)) : contraint un score à une tonalité + un ambitus clavier ; les notes hors gamme montent, descendent ou alternent d'un demi-ton ; les notes hors ambitus se transposent d'une octave, ou **wrap** vers l'octave la plus grave.
- **Scale levels** — vérifié ([pianoroll_scale.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_scale.htm)) : sur les vélocités — *Center*, **Tension** (re-échelonnage logarithmique), *Multiply* 0-200 %, *Offset*. *« raising the overall volume of a performance while maintaining the relative note velocity differences »*.
- **LFO** — vérifié ([pianoroll_lfo.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_lfo.htm)) : dessine sine/triangle/square dans la lane d'événements sur la plage sélectionnée. *Value*, *Range*, *Speed* (avec presets tempo), *Phase*, et interpolation Start → End.
- **Randomizer** — vérifié ([pianoroll_random.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_random.htm)) : section *Pattern* (Octave, Range, Key & Scale, Length & Variation, **Population**, **Stack** = polyphonie, Random portamento, Merge same notes, Seed) + section *Levels* (une molette par propriété, -100→100 %, *Reset before processing*, **Bipolar**, Seed).
- **Riff machine** — vérifié ([pianoroll_riff.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_riff.htm)) : 8 étapes chaînables et individuellement activables — Note progression, Chord progression, Arpeggiation, Mirroring, Levels & panning, Articulation, Groove, **Fit** (tonalité/gamme/ambitus). Reset, randomize et preview par étape.
- **Chord progression** — vérifié ([pianoroll_chordprogression.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_chordprogression.htm)) : tonique + gamme, progressions preset saisies en lettres ou en chiffres romains, voicings **Block / Open / Octave / Stacked**, inversions, section Performance (strum time, arpégiation, chop), octave.
- **Script** — vérifié ([pianoroll_scripting_api.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_scripting_api.htm)) : **Python**, les scripts apparaissent dans un menu Scripts, et surtout **l'interface du dialogue est générée automatiquement à partir des variables du script** (knobs, cases, combos, champs texte). Scripts d'exemple : Add A Note, Modify Existing Notes, Snap To Scale, Random Melody, Note Repeat, Marker Copy.

### La sélection, les modes de dessin, les fantômes

**Sélection** — vérifié (pianoroll_menu.htm) : Deselect · Select all · **Select one at random (Shift+R)** · **Select more at random (Shift+M)** · **Select by color (Shift+C)** · **Select odd (Shift+O)** · Select muted · **Select overlapping notes** · **Select stacked notes** · Invert selection · Select time around selection · Select previous/next time · **Magic lasso**.

**Outils** — vérifié ([pianoroll.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm)) : Draw (P) · Paint (B) · **Paint drum sequencer mode (N)** · Delete (D) · Mute (T) · Slice (C) · Select (E) · **Interpolate (I)** · Zoom to selection (Z) · Play selected (Y).

**Propriétés par note** — vérifié (pianoroll.htm, recoupé channelrack.htm pour le graph editor du step sequencer) : Velocity · Panning · **Fine pitch** · **Filter cutoff (Mod X)** · **Filter resonance (Mod Y)** · **Release velocity** · **Slide** · **Portamento** · **Couleur = canal MIDI (16)** · Shift.

**Fantômes** — vérifié : blocs pleins = mêmes pattern, autres channels ; blocs vides = autres patterns. **Ghost channels (Alt+V)** et surtout **Editable ghosts (Ctrl+Alt+V)** — on édite les notes d'un autre channel sans quitter le sien. Plus **Background waveform (Alt+N)**.

**Gammes** — vérifié : Scale highlighting (tonique + type), snap to scale, snap incoming MIDI, labels de clavier (root notes / highlighted notes / white notes only), et **Add key marker** sur la règle temporelle — la gamme change en cours de clip.

**Stamp** — vérifié : accords, gammes et motifs de percussion tamponnés à la souris, dont *Automatic chord (top-down) — melody driven* et *(bottom-up) — harmony driven*.

Divers notables, vérifiés : Open/Save score (.fsc) avec drag & drop, import/export MIDI, **Export as score sheet (PDF)**, **Rotate left/right**, **Discard lengths**, **Insert space / Slice & insert space / Delete space**, **Trim selection**, **Turn into automation clip**, Group/Ungroup (Shift+G / Alt+G).

### Où en est CP — vérifié dans le code

`CP_Engine/RollUI.lua:216-372` est le menu Transform complet, partagé par `CP_Editor` et `CP_Looper` : Duplicate/Copy/Cut/Paste · Transpose (5 intervalles fixes) · Nudge · Length (grille, Legato to next) · Reverse · Invert pitch · Velocity (4 valeurs + ramp up/down/compress/expand) · Humanize (light/medium/heavy) · Quantize (100/66/50 % + swing 8/16 %) · Scale (13 gammes, `Roll.lua` SCALES) · Chord from note (11 accords) · Arpeggiate (up/down/updown/random × 4 rates) · Euclidean fill (6 presets).

Le modèle de données est `starts / lens / pitches / vels` — quatre tableaux, rien d'autre (`CP_Engine/Roll.lua:39-42`), et le contrat de backend ne transporte que ces quatre champs (`Roll.lua:22-30`).

### Le classement honnête de ce qui manque

**(a) Les groove templates — la meilleure idée de tout le document.**
FL a **une** idée répétée trois fois : *un score est un gabarit*. Le Quantizer s'en sert comme grille, le Chopper comme motif de découpe, l'Arpeggiator comme motif de notes. Le fichier est le même.

CP possède déjà le conteneur : **CPC1** (`CP_Engine/Clip.lua`), une liste de notes sérialisable, déjà transportée par `Bus`/`DragBus`. Faire accepter à `Roll.Quantize` un clip CPC1 comme grille au lieu d'une seule fonction de snap — la signature est `Roll.Quantize(snap_fn, strength)` (`Roll.lua:323`), donc c'est une fonction de snap construite à partir d'une liste de starts — donne le **groove quantize**, qui est le manque le plus criant du menu actuel (aujourd'hui : 100/66/50 % et deux valeurs de swing en dur, `RollUI.lua:278-289`).
**Ça ne rivalise avec rien** : il n'existe aucune notion de groove nulle part dans CP. Et le format existe déjà. **À faire en premier.**

**(b) Strum, avec tension et alternate direction.**
CP n'a aucun outil de temps sur accord. La machinerie existe : `Roll.Arpeggiate` (`Roll.lua:850`) est déjà un traitement hors-ligne qui rassemble une sélection et réécrit les starts, et les helpers `gatherTargets`/`forEachTarget` (`Roll.lua:370-392`) sont là. Un strum = pour chaque groupe de notes partageant un start, décaler de k×time avec une courbe et une rampe de vélocité. Une quarantaine de lignes.

**(c) Flam.** Encore plus petit que le strum, et c'est son jumeau côté batterie. Rivalise avec Humanize, qui fait autre chose.

**(d) Les commandes de sélection.** *Select by color* n'a pas de sens ici (pas de couleur de note), mais **Select odd**, **Select overlapping**, **Select stacked**, **Select one/more at random** font 5 à 10 lignes chacune au-dessus du `selset` existant (`Roll.lua:172-215`) — et elles changent ce que le menu Transform peut faire : « select odd → nudge » est un outil de groove, « select at random → humanize heavy » est un outil de variation. **C'est le tas de valeur le moins cher du document.**

**(e) Chop / note repeat.** `Roll.Subdivide` (`Roll.lua:297`) fait déjà la moitié difficile (remplir un span de n notes). Avec (a), le Chop devient « subdiviser en suivant le rythme d'un clip » — le même chemin de code. À noter : pour le cas simple, **CP a déjà un meilleur geste que FL** — Ctrl+Shift+molette sur une note subdivise ×2/÷2 en place (`CP_Editor/README.md`, section MIDI mode).

**(f) Les propriétés par note au-delà de la vélocité — le seul qui n'est PAS bon marché, et il faut dire pourquoi.**
Les Mod X / Mod Y de FL ne sont pas des CC MIDI : ce sont des chemins de modulation privés du channel, câblés vers la coupure et la résonance de son propre sampler (vérifié : [chansettings_ins.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_ins.htm) route Cutoff/Resonance sur MOD X/MOD Y). Reproduire ça ici veut dire soit (i) de vrais CC MIDI — que le backend de take sait écrire mais que le store de notes du moteur natif ne sait pas porter (le contrat de backend fait 4 champs, `Roll.lua:22-30`), soit (ii) un tableau supplémentaire par note traversant Roll, les deux backends, CPC1 et l'enregistrement de note du moteur. **Les deux sont un chantier, pas une entrée de menu.** Le pan par note est celui qui achète le plus pour le moins (roulements de caisse qui bougent dans le stéréo), mais même lui force un 5ᵉ tableau à travers toute la chaîne. **À classer sous tout le reste, et à ne faire que sur un besoin concret.**

**(g) Le scripting du piano roll — l'idée la plus FL que CP peut exécuter MIEUX que FL.**
FL exécute du Python et **génère le dialogue à partir des variables du script**. CP est déjà écrit en Lua, et le menu Transform est déjà une table de `{label, action}` (`RollUI.lua:224-226`). Un dossier « transforms utilisateur » où chaque `.lua` retourne `{ name, params, apply(Roll, p) }`, et `RollUI` construit l'entrée de menu et le popup de paramètres depuis `params` : c'est une petite tuyauterie avec un plafond illimité — et c'est **plus naturel ici que chez FL**, parce que la langue de l'hôte et celle du script sont la même. Réserve à écrire : une transformation tourne sur un clic, donc elle est hors du budget de frame par construction ; rien de tout ça ne touche le chemin de dessin.

**(h) Editable ghosts.** FL laisse voir *et éditer* les notes d'un autre channel depuis le sien. `CP_Editor` édite un take à la fois. La forme bon marché ici est précise : la grille de session connaît tous les clips d'une scène, donc « afficher en fantôme les clips des autres colonnes de cette scène » est **un calque en lecture seule d'abord** — et cette moitié-là fait 80 % du bénéfice (écrire une basse contre la batterie).

**(i) Key markers.** La gamme de CP est un couple root+type global (`Roll.scale_on`/`scale_root`, `Roll.lua:774-781`). Une liste de (temps, tonique, intervalles) ferait suivre une progression au snap-to-scale. Coût moyen, valeur moyenne.

**À NE PAS voler :** la **Riff machine** (un générateur dont chaque étape veut un dialogue complet — énorme UI pour un bouton « surprends-moi » ; Euclidean + Arpeggiate + Humanize couvrent déjà le tiers utile) ; la **bibliothèque de progressions** du Chord progression tool (c'est un problème de contenu, pas de code) ; l'**outil LFO** (il écrit dans des lanes d'événements que CP n'a pas — il dépend entièrement de (f)) ; **Export as score sheet**.

---

## 4. LE CHANNEL SAMPLER / DRUM

### Ce qu'un channel FL sait faire

Vérifié ([chansettings_sampler.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_sampler.htm) + [chansettings_ins.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_ins.htm)) :

- **SMP** : boucle avec start/end réglables, **ping-pong**, modes de stretch — temps réel : *Resample*, *Stretch*, *Stretch pro* (contrôle de formants) ; hors ligne : *e3 Generic*, *e3 Mono*, **Slice stretch**, **Slice map**, *Auto*. Declicking en six modes : *Out only / Transient / Generic / Smooth / Crossfade / No declicking*.
- **Precomputed** (destructif, au chargement) : onglet Tools — remove DC, reverse polarity, normalize, fade stereo, reverse, swap stereo, trim, fade in/out, crossfade, trim threshold. Onglet Effects — boost, EQ, ring mod, filtre LP (cutoff/res), reverb, stereo delay, **POGO** (pitch bend).
- **INS** : enveloppes ET LFOs pour **Panning, Volume, Cutoff (Mod X), Resonance (Mod Y), Pitch**. L'enveloppe de volume est **Delay-Attack-Hold-Decay-Sustain-Release**, avec une **tension** par segment et un multiplicateur *Amount*. Chaque LFO : sine/tri/square, Delay, Attack, Speed, Amount, synchro tempo, et un mode **Global** (libre à travers les notes au lieu de se redéclencher).
- Filtres : *Fast LP, LP, BP, HP, BS, LPx2, SVF LP, SVF LPx2*.
- **Slicex** (plugin séparé) — vérifié ([Slicex.htm](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Slicex.htm)) : découpe par détection de transitoires, lit les régions embarquées dans le wav, **articulateur par slice** (filtres, enveloppes, LFOs), slices mappées aux touches avec empilement quand plusieurs partagent une touche, time-stretch pour boucles de batterie, éditeur d'onde intégré de niveau Edison.

### Où en est `CP_Sampler` — vérifié

Un pad **est** une piste REAPER + un RS5K. Les paramètres utilisés (`CP_Engine/Kit.lua:64-70`) : `VOL, PAN, NOTE_LO, NOTE_HI, MAXV, ATTACK, RELEASE, OBEY, LOOP, SOFFS, EOFFS, TUNE, MINVEL, MAXVEL, LOOPOFFS, DECAY, SUSTAIN, PITCH_LO, PITCH_HI`. Donc **l'ADSR est complet**, et SOFFS/EOFFS donnent la région de slice.

Le menu d'un pad (`CP_Sampler/CP_Sampler.lua:492-551`) : Load sample · Open in Editor · Choke group · **Sync to project tempo** · Set source BPM · **Bake: crop to trim** · Rename · Show RS5K UI · Clear · Delete.

Point vérifié et intéressant : **`MINVEL`/`MAXVEL` sont mappés mais aucune UI ne les écrit** — le grep ne trouve que la déclaration de la table (`Kit.lua:67`). Les couches de vélocité sont donc à **un dialogue** d'exister, pas à un chantier. Ça confirme `ANALYSE_Design.md` §3 qui les listait déjà.

Absents : filtre par pad, LFO, mise en forme d'enveloppe au-delà de l'ADSR linéaire du RS5K, ping-pong, articulation par slice.

### Ce que je volerais, classé

1. **Un filtre par pad.** L'architecture le rend presque gratuit — un pad EST une piste, donc un filtre est un JSFX sur cette piste. `ANALYSE_Design.md` §3 le dit déjà et parle d'« occasion manquée ». La liste FL (LP/BP/HP/BS/SVF) est la liste de courses. **Ça ne rivalise avec rien** : il n'y a aujourd'hui aucune mise en forme du timbre sur un pad.
2. **Les couches de vélocité**, parce que les paramètres sont déjà mappés (`Kit.lua:67`) et que le motif « plusieurs RS5K sur la piste d'un pad » est déjà celui des choke groups. L'équivalent FL est l'empilement de slices sur la même touche dans Slicex.
3. **La tension d'enveloppe.** L'ADSR du RS5K est linéaire. La tension par segment de FL est ce qui fait qu'un kick synthétique sonne comme un kick. Ici elle devrait vivre dans le **même** JSFX que le filtre (un générateur d'enveloppe appliqué au gain) — raison pour laquelle il faut la concevoir **avec** (1), pas après.
4. **Les modes de declicking.** CP fait déjà des fondus (`CP_Engine/Voice.lua:488-514`, `Stop`/`StopAtSample` avec fondu, corrigés en session 21). Ce que FL ajoute, c'est que le *bon* declick dépend de la matière (transitoire vs lisse vs crossfade). Coût faible, visibilité faible.
5. **Ping-pong.** Bon marché dans le moteur natif (`Voice.SetLoop` existe, `Voice.lua:421`), musicalement étroit. Dernier.

**À NE PAS voler : les onglets Tools + Effects destructifs** (normalize, reverse, EQ, reverb cuits dans l'échantillon au chargement). CP a tranché l'inverse, et mieux : les éditions sont des propriétés de take non destructives, et le **Bake** est l'échappatoire explicite (`ANALYSE_Design.md` §8.3 ; `CP_Engine/Bake.lua` existe et le menu de pad l'expose déjà, `CP_Sampler.lua:530`). Ajouter un onglet d'effets destructifs rouvrirait une question fermée.

**À NE PAS voler non plus : Slicex comme plugin.** La décision de slicing est prise (l'opération monte dans l'Engine et les deux apps l'exposent à des granularités différentes, `ANALYSE_Design.md` §8.2), et elle est mieux adaptée ici parce que les slices atterrissent sur de vraies pistes.

---

## 5. CE QUE FL FAIT QUE PERSONNE D'AUTRE NE FAIT

1. **Le pattern traverse tous les instruments.** Vérifié (channelrack.htm). Unique. **Non volable** — le modèle Ableton est acté et structurel dans `Loop.lua`. Mais sa conséquence l'est : *dupliquer une scène entière d'un geste* (§1).
2. **Un fichier de score est une monnaie de gabarit universelle** : le même `.fsc` est un motif d'arpège, un motif de découpe et un groove de quantisation. Vérifié sur les trois pages (arpeggiate / chp / qnt). **C'est la meilleure idée de FL pour CP**, parce que le fichier existe déjà ici : CPC1. Un format, trois outils. **À voler.**
3. **Le dialogue est généré depuis le script.** Vérifié (scripting_api.htm). CP peut faire mieux : c'est du Lua des deux côtés. **À voler.**
4. **Coupure et résonance par note**, routées vers le sampler du channel et non vers des CC. Vérifié. Cher ici — voir §3(f).
5. **Tolerant trigger sync** — pardonner un déclenchement en retard au lieu de le punir d'une mesure. Vérifié. Minuscule, humain, unique. **À voler.**
6. **+Scene** — superposer une scène au lieu de la remplacer. Vérifié. **À voler.**
7. **Tout devient de l'automation d'un clic droit** (« Turn into automation clip » dans le piano roll ; chaque knob → Create automation clip). Vérifié pour l'entrée de menu du piano roll, de mémoire pour le comportement global des knobs. **Ne pas courir après** : l'équivalent CP existe sous une autre forme (ModJSFX + parameter links natifs, `ROADMAP_Autonomie.md` §2) et il est plus fort, puisqu'il résout à la résolution audio sans qu'un script tourne.
8. **Paint drum sequencer mode (N)** — un mode de dessin où le glissé bascule des pas au lieu de créer des notes. Vérifié (pianoroll.htm). Pour le mode drum de CP (`CP_Engine/Rows.lua`) c'est le geste naturel, et il est bon marché.
9. **La zone de performance est le même canevas que l'arrangement.** Vérifié. **Ne pas voler** — ça contredit l'acquis « CP touche le moins possible à l'arrangement de l'utilisateur ».

---

## 6. Ce que je ferais, dans l'ordre

Cinq choses, chacune petite, chacune sans dépendance sur le moteur :

1. **Groove templates via CPC1** — `Roll.Quantize` accepte un clip comme grille. Un format, et le Quantize du menu cesse d'être trois pourcentages.
2. **Motion par colonne** dans `CP_Session` (Stay / March & wrap / March & stay / Random / Exclusive random), en Lua sur `Loop.Pending`. Et **on n'écrit pas les Follow Actions par clip** tant que celui-là n'a pas montré sa limite.
3. **Le paquet de sélection** dans `RollUI` : odd / overlapping / stacked / random. Dix lignes chacune, et elles multiplient ce que les transformations existantes savent faire.
4. **Strum + Flam** dans `Roll`, au-dessus des helpers qui existent déjà.
5. **Tolerant + Alt+clic = stop + Ctrl+clic = +Scene** dans `CP_Session` : trois gestes, trois constantes, et la grille cesse de punir la main.

Et une chose plus grosse, à décider plutôt qu'à glisser dans une session : **le dossier de transformations utilisateur en Lua avec dialogue généré**. C'est le seul endroit de cette analyse où CP peut dépasser sa référence au lieu de la rattraper.

**Sources principales :** [Performance Mode](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_performance.htm) · [Playlist](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm) · [Channel Rack](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm) · [Piano roll](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm) · [Piano roll menu](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm) · [Quantizer](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_qnt.htm) · [Chopper](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_chp.htm) · [Arpeggiator](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_arpeggiate.htm) · [Strum](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_strum.htm) · [Flam](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_flam.htm) · [Claw machine](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_claw.htm) · [Articulator](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_articulate.htm) · [Key limiter](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_limit.htm) · [Scale levels](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_scale.htm) · [LFO](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_lfo.htm) · [Randomizer](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_random.htm) · [Riff machine](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_riff.htm) · [Chord progression](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_chordprogression.htm) · [Scripting](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_scripting_api.htm) · [Channel sampler](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_sampler.htm) · [Instrument settings](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/chansettings_ins.htm) · [Slicex](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Slicex.htm) · [FL Studio 2025 — what's new](https://www.image-line.com/fl-studio-news/fl-studio-2025-whats-new-2) · [API stubs — Performance Mode](https://maddyguthridge.github.io/FL-Studio-API-Stubs/tutorials/performance_mode/)