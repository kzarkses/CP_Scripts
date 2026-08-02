# Confrontation — CP_Session, CP_Editor, CP_Sampler face à Ableton et FL Studio

Écrit le 2026-08-01, après le premier vrai test d'écoute de la suite complète.

Deux sources : dix agents (inventaire du code, références Ableton/FL vérifiées
sur les manuels en ligne, confrontation) et les retours d'écoute de Cédric.
Quand les deux se croisent, je le dis. Quand ils se contredisent, aussi.

Tout ce qui est affirmé du code est cité `fichier:ligne` et a été relu. Tout ce
qui est affirmé d'Ableton ou de FL porte sa source.

---

## 0. Où en est la suite, honnêtement

**Le socle est meilleur que ce que l'usage laisse croire.** L'échange par paire
de lanes, la scène qui tombe d'un bloc, la phase ancrée sur la timeline plutôt
que sur l'instant du clic, un son qui EST une lane et hérite donc gratuitement
de toute la machine à états : ce sont de bonnes décisions, et deux d'entre
elles sont meilleures que ce que fait Ableton. Le moteur date à l'échantillon,
ce qu'aucun script Lua ne peut faire.

**Ce qui manque n'est presque jamais du moteur.** Sur les vingt-trois défauts
retenus ci-dessous, trois seulement touchent le C++. Le reste est du câblage
absent : des champs qui voyagent dans le format et que personne ne lit, des
fonctions écrites et jamais appelées, des réponses calculées et jamais
montrées. La suite en sait beaucoup plus qu'elle n'en dit.

**Et le modèle a deux ontologies superposées.** Un pad de CP_Sampler et une
case audio de CP_Session sont le même objet — un fichier, une région, un taux,
un tempo source — décrits deux fois, avec deux stockages et deux unités
(`clip.offs/len` contre RS5K `SOFFS/EOFFS` ; `clip.src_bpm` contre
`P_EXT:CP_KIT_BPM` ; un taux de voix contre une transposition en demi-tons).
Aucun des deux ne sait lire l'autre. C'est la racine du sentiment de « cul
entre deux chaises », et ce n'est pas une impression : c'est dans le code.

---

## 1. Le sampler — tes observations sont exactes, et le diagnostic est pire

### 1.1 « Je ne comprends pas ce qui rentre en MIDI, quand, et pourquoi »

Ce n'est pas un manque de compréhension. C'est le comportement.

`Kit.EnsureBus` (`CP_Engine/Kit.lua:599-601`) pose sur le bus du kit :

```lua
r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 4096 + (63 << 5))  -- MIDI, TOUS
r.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)                   -- entrées,
r.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)                   -- TOUS canaux
```

Le bus du kit est donc **armé et en monitoring en permanence, sur toutes les
entrées MIDI et tous les canaux**. Et il ne se contente pas de l'être :
`Kit.HoldArm()` (`Kit.lua:1637`) réaffirme cet état à chaque fois que REAPER le
remet à zéro, c'est-à-dire à chaque changement de sélection de piste.

Conséquence directe, et c'est exactement ce que tu décris : **tout ce que tu
joues entre dans le kit**, quelle que soit la piste que tu as armée dans
REAPER. La suite ne « ne réagit pas » aux pistes armées de REAPER — elle est en
compétition avec elles, et elle gagne parce qu'elle se réarme toute seule.

`enforceSingleListener` (`Kit.lua:428-436`) désarme les autres **kits**. Jamais
tes pistes.

Deuxième moitié : un clic sur un pad passe par `StuffMIDIMessage`
(`Kit.lua:1573`), et le commentaire du fichier le dit lui-même
(`Kit.lua:1550`) : *« StuffMIDIMessage is a BROADCAST »*. Il atteint **toute**
piste armée en monitoring. Le canal 16 (`Kit.UI_CHAN`) sert d'étiquette pour
que les envois vers les pads le reconnaissent, mais il n'empêche personne
d'autre de l'entendre. D'où « ça fait des envois dans tous les sens ».

**Ton modèle attendu est le bon** : le sampler pointe une piste, le son sort par
cette piste, et c'est l'armement de CETTE piste — dans REAPER, dans le mixer ou
dans CP_Sampler, peu importe lequel — qui décide si tu la joues. Rien d'autre
n'est touché.

Ce modèle est implémentable **sans toucher au RS5K** et sans nouveau binaire :
c'est une question de propriété de l'armement, pas de moteur audio. Trois
choses : ne plus forcer `I_RECARM`/`I_RECMON`, mais les LIRE ; router les clics
de pad par un chemin qui n'est pas un broadcast (le bus a un port d'entrée, un
envoi direct suffit) ; et faire de `Kit.active` une conséquence de la piste
ciblée au lieu d'un état parallèle.

### 1.2 « Est-ce qu'on peut s'affranchir du RS5K ? »

**Oui, et le coût n'est pas là où on l'attend.**

Ce qui manque au moteur, côté DSP, est petit :

| Besoin | État | Coût |
|---|---|---|
| ADSR | il n'y a que des fondus **linéaires** entrée/sortie (`cp_voice.h:45-49`) | une machine à quatre étages dans `Voice::render`, ~40 lignes, plus les paramètres d'ABI |
| choke | JSFX généré sur le bus (`Kit.lua:192`) | **plus simple en natif** : un vol de voix par groupe, exact à l'échantillon, sans plugin |
| loop, région | déjà là, en frames source (`cp_voice.cpp:119-121`) | rien |
| vol, pan | déjà là, avec rampe par bloc | rien |
| pitch (varispeed) | déjà là (`rate`) | rien |
| stretch à durée constante | **absent, et par décision chiffrée** : 2,3 %/voix et 85-139 ms d'amorçage | reste hors ligne (`Warp`), et c'est le bon choix |
| vélocité, zones | absent | trivial (gain + filtre à l'aiguillage) |

Autrement dit : trois ou quatre soirées de DSP, pas un chantier.

**Le blocage n'est pas le DSP. C'est le MIDI.**

Le moteur est un `PCM_source` joué par `PlayTrackPreview2Ex`
(`cp_main.cpp:260`). Un aperçu **produit** du MIDI — c'est comme ça que les
lanes parlent — mais il n'en **reçoit** pas. Un sampler natif ne pourrait donc
être joué au clavier qu'en passant par Lua : `MIDI_GetRecentInputEvent`, puis
un lancement daté. Les évènements sont horodatés à l'échantillon, mais la
SONDE, elle, tourne une fois par frame de defer — 16 à 74 ms. C'est acceptable
pour armer une case sur la mesure suivante ; c'est inacceptable pour jouer.

Il n'y a qu'une sortie propre : **livrer le cœur comme un plugin**. Et c'est
moins violent qu'il n'y paraît, parce que `CP_Native/src/core` a été écrit
depuis le début sans une seule ligne d'API REAPER — c'est une règle écrite dans
le dossier, et le harnais le compile et le teste hors REAPER (141 assertions).
Une coquille CLAP (en-têtes MIT, sans dépendance) ou VST3 autour de `Voice` et
`Pool` est un projet borné, pas une réécriture.

Et cette voie règle **aussi** ton problème de pistes : un plugin peut sortir sur
N paires stéréo, et les conteneurs d'effets de REAPER 7 se punaisent sur une
paire de canaux. Un kit = **une piste**, un plugin, et un conteneur par pad qui
veut sa chaîne. C'est exactement ton intuition, et c'est ce que font les gros
sampleurs modernes.

Ta seconde idée — un dossier CP Kit dont le parent route vers ses enfants — est
faisable aussi (REAPER sait faire des envois parent→enfants avec décalage de
canaux), mais elle recrée la forêt de pistes que tu veux supprimer. Je ne la
recommanderais que comme mode explicite « éclater le kit », pas comme défaut.

### 1.3 Le JSFX de choke

Tu as raison sans réserve, et pour une raison de plus que celles que tu donnes.
Toute son interface est reprise dans CP_Sampler ; il est généré ; il n'a aucune
valeur pour l'utilisateur. Dans le scénario « plugin natif » il disparaît de
lui-même (le choke devient un vol de voix). Dans le scénario « RS5K bien
intégré », il reste nécessaire — c'est la seule pièce qui puisse couper une
note à l'échantillon — mais il doit être invisible et non déplaçable.

### 1.4 Ma recommandation, tranchée

**Ne reste pas entre les deux.** Deux états cohérents existent :

- **(a) RS5K, mais invisible et discipliné** : une piste par kit, les pads dans
  des conteneurs d'effets et non des pistes, l'armement suit REAPER au lieu de
  le forcer, pas de dossier CP. Coût : moyen, entièrement en Lua, aucun
  nouveau binaire. Gain : la confusion MIDI disparaît demain.
- **(b) Un instrument CP** : le cœur en plugin CLAP/VST3, ADSR et choke natifs,
  sortie multicanale, un conteneur par pad. Coût : un nouveau binaire et son
  cycle de vie. Gain : un seul moteur audio dans toute la suite, et le pad et
  la case audio redeviennent le même objet.

**(a) d'abord, (b) ensuite** — et (a) n'est pas du travail perdu, parce que la
discipline d'armement et le modèle « un kit, une piste » sont les mêmes dans
les deux. Ce qui serait perdu, c'est de faire (b) sans (a) : tu aurais un beau
moteur avec le même MIDI incompréhensible.

---

## 2. CP_Session — ce que tes symptômes recouvrent

### 2.1 « Je ne suis jamais sûr que le sample soit bien tempo-matché »

Parce que rien ne te le dit, alors que la réponse est calculée.

`SrcTempo.Bpm` rend **`bpm, why`** — `"declared"`, `"analysed"`, `"named"`,
`"inferred"`, ou `nil` — et l'en-tête du module dit explicitement pourquoi :
*« la raison fait partie de la réponse, parce qu'une fenêtre qui affiche un
tempo qu'elle ne peut pas justifier est une fenêtre qu'on apprend à ne pas
croire »*. **Aucune fenêtre n'affiche cette raison.** `rateFor`
(`CP_Session.lua:520-529`) jette le `why` sans le regarder.

Pire, et c'est le vrai trou du modèle : `clip.src_bpm` est le tempo *déclaré*,
celui qui doit gagner sur toutes les heuristiques. **Il n'a aucun écrivain dans
tout le dépôt** — deux lectures, zéro écriture. Le champ prioritaire est en
écriture morte : tu n'as littéralement aucun moyen de dire à une case « ce
fichier fait 128 ».

C'est le correctif au meilleur rapport de tout ce document : afficher le tempo
retenu et sa raison sous la case, et rendre le tempo déclaré éditable.

### 2.2 « Les boucles ne bouclent pas pile au bon moment »

Trois causes distinctes, toutes vérifiées.

**(a) La longueur d'une boucle n'appartient à personne.** Elle vaut
`bars × ts_num` (`cp_lanes.cpp:134-138`), où `ts_num` est la signature
rythmique **à l'endroit où la tête de lecture se trouve en ce moment**
(`Loop.TsNum()` → `TimeMap_GetTimeSigAtTime(0, nowPos)`). Une mesure en 3/4
quelque part dans le projet change la longueur de **toutes** les lanes quand le
transport la traverse — alors que les notes sont stockées en beats absolus et
ne se remettent pas à l'échelle. Le point de bouclage glisse sous la musique.
Ableton a une signature **par clip** ; ici la métrique est empruntée au projet,
à un instant sans rapport avec le clip.

**(b) La longueur venait d'un défaut, pas du fichier.** Corrigé ce matin : elle
se lit désormais dans le fichier. Avant, tout valait quatre mesures.

**(c) Le one-shot se mitraillait.** C'était mon correctif de ce matin, et il
était faux : pour combler le silence d'un kick dans une passe, je faisais
boucler la matière — cinq kicks par mesure, hors grille. Corrigé : un one-shot
joue une fois par passe, et `Clip.lmode` — un champ du format que personne n'avait
jamais lu — pilote enfin le choix.

### 2.3 « La barre de progression ne correspond pas au son »

Elle ne peut pas. Elle affiche la **phase de la lane**, qui est une position
musicale sur la grille. Le son a sa propre position, son propre taux, et sa
propre longueur de matière. Les deux ne coïncident que quand le fichier remplit
exactement sa passe.

Ce n'est pas un bug de dessin, c'est un choix jamais fait : la barre doit dire
*où en est le clip* et non *où en est la mesure*. La voix publie sa position
(`Voice.State` rend `état, position`) et personne ne la lit.

### 2.4 « Le mode stretch n'est pas stable »

Le libellé du menu dit « Stretch (keeps the key, plays late) »
(`CP_Session.lua:1229`). **Les deux moitiés sont fausses.**

`Warp.Resolve` dépose une demande de cuisson et rend **le fichier d'origine en
repitch** (`Warp.lua:196-208`). Le commentaire promet que c'est « seulement
pour une passe ». En réalité **rien ne réarme après la cuisson** : `soundFor`
n'est appelé que depuis `armLane`, `retune` et le rappel, et `Warp.Tick()` ne
notifie personne. Une case reste en repitch **jusqu'au prochain lancement
manuel**. Et `Warp.Retry` a zéro appelant : un échec de cuisson est définitif
pour la session, sans recours.

Trois correctifs, tous petits : notifier la fin de cuisson (un compteur de
version que `frame()` observe), câbler `Retry`, et réécrire le libellé.

### 2.5 « En clock follow, l'arrangeur démarre mais le clip ne démarre pas »

J'ai un coupable très probable, corrigé ce matin, mais je ne peux pas
l'affirmer sans l'entendre : quand un lancement était découvert en retard,
`playAt` convertissait la phase en position dans le fichier, et si cette
position dépassait la fin du fichier la fonction **rendait la main sans rien
jouer** (`Cells.lua`, ancien `if opts.offset >= slot.clip.frames then return`).
Sur un son court, c'est le silence. Sur un long, non — ce qui explique « en
fonction du sample, les clips réagissent plus ou moins bien ». Un one-shot n'a
plus de phase du tout maintenant, et une boucle replie son offset.

S'il reste quelque chose après ça, c'est ailleurs et je n'ai pas de deuxième
hypothèse solide.

### 2.6 « Le stop de l'arrangeur devrait tout couper »

D'accord, et corrigé. Le raisonnement, écrit dans le code : un lancement et un
arrêt demandés **depuis la grille** attendent le quantize — c'est à ça qu'il
sert. Le stop du transport n'est pas de ceux-là. En horloge libre, rien ne se
passe, et c'est tout l'intérêt de l'horloge libre.

Le retard que tu observais (« une mesure, indépendamment du Q ») venait de ce
que le MIDI était bien coupé par le fil audio, mais les voix audio gardaient
leur passe programmée jusqu'à la porte.

### 2.7 Ce que le balayage a trouvé et que tu n'as pas encore vu

Par ordre de gravité.

- **Une case audio envoyait un do central dans l'instrument de la colonne.**
  Corrigé aujourd'hui. C'était l'exact contraire de ce que le commentaire
  affirmait.
- **Fermer la fenêtre sans l'extension écrase l'état sauvé.** `Loop.SaveState`
  n'a aucun garde `NATIVE` (`Loop.lua`), alors que `Deserialize` en a un. Sans
  le binaire, la sérialisation produit huit lanes vides et les écrit. **Trois
  lignes**, et c'est de la perte de travail.
- **Aucune annulation sur l'édition de notes d'une case.** Le contrat de `Roll`
  prévoit `be.undo` ; le backend clip le branche sur `scheduleApply()`,
  c'est-à-dire rien. Un Quantize, un Euclidean ou une suppression dans une case
  de session sont **définitifs**. Et Alt+clic efface une case sans confirmation.
- **Le tag de lane n'est pas sérialisé.** Après réouverture du projet, la grille
  et le moteur ne parlent plus du même clip : les lanes jouent, la grille montre
  tout arrêté, aucune case audio n'est réarmée. Un champ de plus dans le format.
- **Un slot libéré est réattribué avec ses clips.** Supprime la piste de la
  colonne 1, crée-en une autre : elle arrive avec les huit clips de l'ancienne.
  Le mécanisme d'adoption a été écrit pour que les clips restent au slot ; il
  n'a pas prévu qu'un slot libéré change de piste.
- **Une lane mutée dans le Looper coupe son MIDI mais pas sa case audio.**
- **Les collisions d'identité entre projets.** `Ident` assume la collision et la
  déclare inoffensive parce que `Ident.Get` filtre — mais `Loop.LaneOfTag`
  compare des nombres bruts sans passer par le registre. Ouvrir un second projet
  dans la même instance de REAPER suffit à faire dessiner une case comme
  jouante alors qu'elle tient les notes de l'autre projet.
- **Sept champs morts** voyagent dans chaque `.RPP` : `gain`, `pitch`, `rate`,
  `root`, `q`, `lmode` (branché aujourd'hui), `src_bpm`. Ils **promettent** un
  modèle que rien n'implémente.

### 2.8 Face à Ableton et FL — ce qui manque et qui compte

Vérifié sur les manuels.

1. **La fin de passe comme évènement.** FL appelle ça *Motion*, par piste :
   `Stay`, `One shot`, `March & wrap`, `March & stay`, `March & stop`,
   `Random`, `Exclusive random`. Ableton fait la même chose par clip avec dix
   *Follow Actions*. C'est ce qui transforme 4×8 cases en machine qui se joue
   pendant que tu mixes. **Entièrement en Lua**, dans `frame()` après
   `Loop.Poll()` : tout est déjà exposé (`Loop.Phase`, `Loop.LenBeats`,
   `Loop.GetLaunchQ`, et `launchCell` sait déjà échanger sur une frontière).
   Grain COLONNE d'abord, à la FL — les Follow Actions par clip sont un panneau
   par case, et il faut savoir si le grain colonne suffit avant de le
   construire.
2. **La région et le gain d'une case audio.** `Cells.Arm` ne prend qu'un chemin
   et un taux : `clip.offs`, `clip.len` et `clip.gain` **n'ont aucun
   consommateur**. Une sélection de deux mesures glissée depuis CP_Editor joue
   le fichier entier. Tout existe pourtant en dessous — le moteur porte
   `loop_start`/`loop_end`/`pos`/`gain` en frames source, et `Voice.Play` les
   transmet déjà. C'est du câblage, ~20 lignes. Ça débloque « je découpe un
   break en huit tranches, une par case », qui est un geste fondateur d'une
   session view et qui est aujourd'hui strictement impossible.
3. **`+Scene`.** FL, verbatim : `+Scene` *« will replace playing Clips with any
   new Clips on the same track in the next Scene but leave any Clips on unused
   tracks playing »*. Aujourd'hui `sceneLaunch` arrête toute colonne sans clip,
   donc **une nappe ne peut pas survivre à un changement de scène** : il faut la
   dupliquer dans les huit lignes. Cinq lignes, zéro stockage.
4. **Une sélection et un clavier.** Ableton : flèches, Page Up/Down = huit
   scènes, Entrée = lancer — on descend un set entier en tapant Entrée.
   CP_Session n'a **aucune gestion clavier**. L'infrastructure existe et est
   éprouvée dans CP_Editor. ~60 lignes.
5. **La fenêtre de tolérance de lancement.** Le moteur a déjà la bonne
   sémantique — un clic dans les 0,05 beat *après* une frontière part
   immédiatement plutôt que d'attendre la suivante (`cp_lanes.cpp:154-158`),
   exactement comme FL. Mais 0,05 beat = **25 ms** à 120 BPM, et une main
   humaine est en retard de 40 à 120 ms. Passer à une fraction de Q (1/8 =
   250 ms à Q: Bar) est **une ligne de C++**, et c'est le meilleur rapport
   effet/effort du document.
6. **Plus de quatre colonnes.** *Fait le 2026-08-02 — et le calcul ci-dessous
   était faux.* Le MIDI prend `PORT_BASE + t`, pas `PORT_BASE + lane` : les deux
   moitiés d'une paire partagent un port, parce qu'une paire est *une* piste
   musicale. Donc audio `0..TRACKS-1`, MIDI `8..8+TRACKS-1`, et **huit est le
   plafond exact** — à neuf, le son de la colonne 8 prend le port 8, qui est le
   MIDI de la colonne 0. Le coût réel n'était ni la largeur d'écran ni
   l'architecture : c'était la **remontée de disposition**, parce que le pas qui
   sépare une moitié vivante de sa jumelle vaut le nombre de colonnes.
7. **Capture and Insert Scene** (Ableton, Ctrl+Shift+I) : copier ce qui joue
   dans une nouvelle scène *« with no audible interruption »*. Ici c'est
   exact par construction et non par chance, parce que le tag de lane est de la
   métadonnée pure : recopier les descripteurs puis reposer les tags allume la
   nouvelle ligne sans redéclencher une seule note. C'est l'anti-« j'avais un
   truc bien et je l'ai perdu ».

### 2.9 Ce qu'il ne faut PAS copier

- **L'enregistrement audio dans une case.** REAPER le fait déjà, en mieux. Ce
  qui manque à ce chemin, c'est la région (point 2), pas un enregistreur.
- **Le modèle « pattern » de FL.** L'exclusivité par colonne est ici
  structurelle (une colonne possède une paire de lanes) et elle est gratuite.
  Rouvrir ce choix, c'est jeter la meilleure propriété du modèle.
- **Le tempo et la signature par scène.** Il faudrait écrire la carte de tempo
  de REAPER depuis un lancement de clip — modifier le projet pendant un jam — et
  ça n'a aucun sens en horloge libre.
- **Gate / Repeat / Toggle par clip.** Ils existent chez Ableton *pour des
  contrôleurs*. Sans mapping MIDI, ils n'achètent rien. `Toggle` est déjà le
  comportement.
- **Le mapping MIDI des cases, pas avant d'avoir tranché l'entrée.** Le même
  flux alimente la piste armée : un pad qui lance une case jouerait aussi
  l'instrument et serait enregistré dans la prise. C'est le même problème que
  le sampler (§1.1), et il faut le régler une fois pour les deux.

### 2.10 Ce qui est déjà là et qu'il faut protéger

Parce qu'une refonte d'interface perd ça sans s'en apercevoir.

- **Cliquer le contenu ouvre l'éditeur, cliquer la bande lance. Jamais
  l'inverse.** Ableton mélange les deux et a besoin d'une préférence pour
  rattraper la confusion. **Meilleur qu'Ableton.**
- **La scène tombe d'un bloc.** Le moteur draine toutes les commandes du bloc
  d'un coup, avec le raisonnement écrit : *« la moitié d'une scène partant une
  mesure avant l'autre n'est pas un quantize, c'est un bug poli »*. Ableton
  cache ce mécanisme ; ici il est démontrable.
- **La phase ancrée sur la timeline.** Lancer une boucle de quatre mesures à la
  mesure 2 la fait entrer à sa deuxième mesure. C'est le cœur, et c'est juste.
- **Follow / Free, et « waiting for the transport » écrit en toutes lettres
  dans la case.** Ableton n'a pas ce choix : il *est* le transport.
- **Le mixer est celui de REAPER, pas un second.** Pas de deuxième vérité à
  synchroniser.
- **Une colonne est une piste du projet, adoptée par GUID**, le slot stable,
  l'ordre d'affichage suivant le projet. C'est l'adaptation à REAPER qu'aucun
  concurrent ne peut avoir.

---

## 3. CP_Editor

### 3.1 A-t-il une raison d'exister à côté de l'éditeur natif de REAPER ?

**Oui, mais pas celle qu'on croit, et elle a une frontière.**

Sa raison d'exister n'est pas d'être un meilleur piano roll. C'est qu'il est le
**seul endroit où l'on peut éditer un clip qui n'a pas d'item** — une lane du
Looper, une case de la Session. L'éditeur natif de REAPER ne sait pas ouvrir ce
qui n'est pas un take. C'est une raison suffisante et elle est structurelle.

La seconde est la moitié audio : région, fondus, gain, pitch, taux sur un
fichier, avec l'audition partagée — l'équivalent d'Edison, que REAPER n'a pas.

**Où elle s'arrête** : tout ce que l'éditeur réécrit et qui existe déjà en mode
take (les gestes de souris standard, la molette, les outils de sélection) est
du travail qui se paie deux fois. La règle que je défendrais : sur un take, ne
rien écrire que REAPER fasse déjà correctement ; sur un clip sans take, tout
écrire, parce qu'il n'y a personne d'autre.

### 3.2 Ce qui manque et qui compte

Le roll a déjà beaucoup : 13 gammes, 11 accords, arpégiateur 4 modes, euclidien,
humanize avec PRNG reproductible, quantize avec force, legato, split, glue,
subdivide. C'est au niveau du genre pour les opérations *offline*.

Ce qui manque vraiment :

1. **Les lanes de CC/automation.** Le trou le plus grand, et il est identifié
   depuis longtemps. À faire d'abord sur CP_Editor : le backend take écrit du
   vrai CC par l'API MIDI de REAPER, sans changement de protocole. Côté clip, la
   note du moteur a **deux octets libres déjà réservés** (`cp_lanes.h:114-120`),
   ce qui n'est pas rien.
2. **L'annulation en mode clip** (cf. §2.7). C'est un défaut, pas un manque.
3. **La vélocité par note visible et éditable en bloc** — l'éditeur de vélocité
   d'Ableton et ses déviations.
4. **Les outils de transformation de Live 12** (Arpeggiate, Ornament, Strum,
   Time Warp, Velocity Shaper, Recombine…) et de FL (chop, flam, riff machine,
   articulator). Une partie existe déjà ici sous d'autres noms. Ce qui manque
   surtout, c'est la boucle **aperçu → appliquer → relancer les dés**, qui est
   ce qui rend ces outils utilisables.

### 3.3 Le trou d'interaction le plus grave

Une lane du Looper ouverte dans l'éditeur **n'a aucune identité** :
`Loop.LaneToClip` construit un descripteur sans `id` ni `cell`. Côté éditeur,
`Ident.TagOf` rend 0, et `Loop.LaneOfTag(t, 0)` — dont le commentaire promet
« nil quand le moteur ne tient plus ce clip » — rend **la moitié vivante**.
L'édition peut donc atterrir dans la jumelle, par-dessus les notes de l'autre
clip. C'est mot pour mot le défaut que l'en-tête d'`Ident` dit exister pour
supprimer. Correction : `Ident.Of` dans `LaneToClip`, et `LaneOfTag(t, 0)` doit
rendre `nil`.

---

## 4. CP_MediaExplorer et les samples courts

Tu observes que les longs se calent et que les courts non — sauf un hat qui,
lui, s'est calé.

**Ton observation est exacte. J'inverse ta conclusion.** Un one-shot n'a pas de
tempo : le hat qui s'est étiré est le bug, pas le kick qui ne s'est pas étiré.
`GetTempoMatchPlayRate` ajuste un nombre de mesures à une durée, et une durée
courte s'ajuste toujours à quelque chose. Le module le disait déjà pour les
noms de fichiers — un kick nommé d'après le tempo du kit n'est pas une mesure de
quoi que ce soit — mais pas pour l'analyse. Le même garde-fou lui a été appliqué
ce matin.

La position du dépôt, elle, est aimantée **sans condition** (`Insert.Snap`
respecte l'aimantation globale de REAPER). Ce qui diffère entre tes deux
essais, c'est le TAUX hérité de l'écoute, pas la position.

Donc : ce qui doit devenir cohérent n'est pas « stretcher aussi les courts »,
c'est **que la réponse soit stable et affichée**. Un one-shot ne doit jamais
être étiré ; un fichier dont le tempo est cru doit dire pourquoi il est cru. Et
c'est le même correctif qu'en §2.1.

---

## 5. Ce que je ferais, dans l'ordre

**Trois chantiers, et rien d'autre avant qu'ils soient finis.**

### Chantier 1 — La propriété de l'entrée MIDI (le sampler)

Le seul qui bloque un usage entier. Le bus du kit cesse de forcer son armement
et de capturer toutes les entrées ; il suit la piste que le sampler cible ; les
clics de pad cessent d'être un broadcast. Entièrement en Lua, aucun binaire.

Ça ne décide PAS de la question RS5K — et c'est pour ça qu'il faut le faire
d'abord : la réponse est la même dans les deux scénarios.

### Chantier 2 — Dire ce que la suite sait déjà

Le tempo retenu et sa **raison** sous chaque case et dans le navigateur ; le
tempo déclaré éditable (`src_bpm` a deux lecteurs et zéro écrivain) ; la barre
de progression qui suit le SON et non la mesure ; le libellé « Stretch »
réécrit et la cuisson qui réarme.

Coût faible, et c'est ce qui te rendrait la confiance que tu dis avoir perdue :
« je ne suis jamais sûr » est un problème d'affichage, pas de moteur.

### Chantier 3 — La région d'une case, puis la fin de passe comme évènement

La région débloque le découpage d'un break en cases — geste fondateur,
aujourd'hui impossible, et tout existe déjà dessous. La fin de passe (Motion à
la FL, grain colonne) transforme la grille en instrument.

**Et deux corrections d'une ligne qui ne sont pas des chantiers :** la fenêtre
de tolérance de lancement (25 ms → 1/8 de Q), et `MAX_LANES = 16` pour huit
colonnes. Elles changent l'usage quotidien pour un coût qui ne se compte pas.

**Puis les défauts de perte de données**, qui n'attendent aucun chantier : le
garde `NATIVE` dans `SaveState`, l'annulation en mode clip, le tag de lane
sérialisé, `Ident.Of` dans `LaneToClip`.

---

## 6. Ce que je n'ai pas pu vérifier

- **« Le clip ne démarre pas » en clock follow.** J'ai un coupable probable et
  je l'ai corrigé, sans pouvoir confirmer que c'était le seul.
- **Le rapport exact entre les samples qui « réagissent plus ou moins bien »**
  et le tempo-match : la corrélation est plausible et cohérente avec le code,
  mais je n'ai pas ton jeu de fichiers.
- **Le coût réel d'une coquille CLAP.** Je sais que le cœur est prêt (il compile
  et se teste hors REAPER) ; je n'ai pas écrit la coquille et je ne chiffrerai
  pas ce que je n'ai pas fait.
- **Deux affirmations de performance** sur le mixer supposent que
  `SetMediaTrackInfo_Value` incrémente le compteur d'état du projet. C'est
  cohérent avec le symptôme mais je ne l'ai pas mesuré.
- **La synthèse automatique de ce document** a été coupée par une limite de
  session. Les dix analyses sources sont intactes et ont été relues à la main ;
  ce texte est ma synthèse, pas celle d'un agent.
