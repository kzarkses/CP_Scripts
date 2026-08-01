Vérifications faites dans le code (le dossier est un point de départ ; j'ai corrigé/complété plusieurs points), plus deux fetches primaires (manuel Live 12 Clip View, manuel FL Performance Mode).

**Corrections au dossier, d'abord** — deux affirmations ne tiennent plus :
- « Un FX peut être déposé sur le mixer fermé » : **corrigé**. `CP_Session.lua:2499-2502` efface `mix_col[t].y` à chaque frame pour toute colonne non dessinée, et `busConsume` teste `g and g.y` (`:1283`).
- « Tolerant n'existe pas ici » : **faux**. `cp_lanes.cpp:154-158` traite déjà une position à moins de 0,05 beat *après* une frontière comme étant dessus, et une cible dans le passé part au bloc suivant (`:402`). La sémantique est exactement celle de FL ; c'est la fenêtre qui est dix fois trop étroite.

---

# A. CE QUI MANQUE ET QUI COMPTE

## A1 — Un clip qui joue UNE FOIS (one-shot / boucle par clip)

**Chez le concurrent.** Ableton, verbatim (vérifié, [manuel Live 12, Clip View](https://www.ableton.com/en/live-manual/12/clip-view/)) : « An unlooped clip will play from its start point to its end point or until it is stopped. » FL, Motion « One shot: Play once and stop. » (vérifié, [Performance Mode](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist_performance.htm)).

**Pourquoi ça compte.** Ici tout boucle, sans exception. Pour l'audio c'est pire qu'une gêne : `Cells.playAt` calcule `loop_m = mat_s < pass_s * 0.98` (`CP_Engine/Cells.lua:326-333`) et **fait boucler la MATIÈRE dans la passe**. Un kick de 0,4 s dans une case d'une mesure à 120 BPM sort **cinq fois par mesure, à la durée du fichier, hors de toute grille**. Crash, riser, stab vocal, fill : inutilisables tels quels. C'est, à mon avis, le défaut le plus audible de toute la fenêtre pour quiconque dépose une banque de samples dans la grille.

**Coût ici.** Le champ existe déjà et n'a **aucun lecteur** : `lmode` (`CP_Engine/Clip.lua:25`, sérialisé `:141` — vérifié par grep sur tout le dépôt). L'implémentation est la même machine que A2 : dans le poll de `frame()`, quand `Loop.Phase(lane) >= Loop.LenBeats(lane) - Q`, appeler `Loop.StopClip(lane)` — l'arrêt quantifié tombe alors exactement sur la fin de boucle. Côté audio, `Cells` doit propager un `opts.loop = false` : la branche existe déjà (`Cells.lua:359`). Fichiers : `CP_Session.lua` (menu de case + poll), `Cells.lua` (un drapeau à travers `Arm`). Difficulté : faible. Risque : nul, l'arrêt est celui du moteur.

**Ce que ça rapporte.** La grille cesse d'être « huit boucles » et devient une grille de session : fills, transitions, one-shots, et un pad qui tient sur une seule case.

## A2 — La fin de passe comme évènement : Motion (FL) avant Follow Actions (Ableton)

**Chez le concurrent.** FL, par PISTE, verbatim (vérifié) : `Stay` · `One shot` · `March & wrap` (« Play then march to the next Clip, at the end wrap back to the first ») · `March & stay` · `March & stop` · `Random` · `Exclusive random` (« without any Clip playing twice in a row »). Ableton fait la même chose par CLIP, avec dix actions, deux probabilités A/B, un multiplicateur de boucles et un Jump (vérifié, dossier + manuel L12).

**Pourquoi ça compte.** C'est ce qui transforme 4×8 cases en machine qui se joue toute seule pendant qu'on mixe : une colonne qui marche dans ses variations, un fill tiré au hasard. Sans ça, chaque changement est un clic, et on ne peut pas faire deux choses à la fois.

**Coût ici.** **Entièrement en Lua**, dans `frame()` juste après `Loop.Poll()` (`CP_Session.lua:2336`). Tout ce qu'il faut est déjà exposé : `Loop.Phase` / `Loop.LenBeats` (`Loop.lua:668-672`), `Loop.GetLaunchQ` (`:576`), et `launchCell` fait déjà l'échange sur frontière. Stockage : un champ par colonne (grain FL) ou par case via `Clip.FIELDS` — le registre est append-only et ignore les clés inconnues en lecture (`Clip.lua:133-134, 199-202`), donc l'ajout est rétro-compatible sans version de format.

**Trois réserves honnêtes**, à écrire dans le code :
1. La règle « tirer dans la dernière fenêtre de Q » n'atterrit sur la fin de boucle que si **la longueur de lane est un multiple de Q** (vrai avec Q: Bar et un nombre entier de mesures ; faux pour une case d'une demi-mesure — `soundBars` peut légitimement rendre 0,5, `CP_Session.lua:561, 594`).
2. Granularité de frame : une fenêtre d'une mesure à 120 BPM = 2 s ≈ 60 frames. Large. Avec Q: Beat à 160 BPM, 375 ms ≈ 11 frames. Encore sûr, mais c'est le plancher.
3. **L'enchaînement s'arrête si la fenêtre se ferme** (c'est du Lua, pas le moteur). Ableton et FL n'ont pas ce problème. À assumer, ou à monter dans le C++ plus tard.

**Recommandation :** grain COLONNE d'abord (7 comportements, un enum dans l'en-tête). N'écrire les Follow Actions par clip que si le grain colonne montre sa limite à l'usage.

## A3 — Une sélection dans la grille et un clavier

**Chez le concurrent.** Ableton (vérifié, dossier — page raccourcis L12 + Accessibility) : flèches = déplacer la sélection, **Page Up/Down = huit scènes**, **Entrée = lancer**, et `Select Next Scene on Launch` qui pré-sélectionne la scène suivante. Conjugué : **on descend un set entier en tapant Entrée**, sans jamais viser une case.

**Pourquoi ça compte.** Une case fait 30 px de haut (`CP_Session.lua:2373`). En performance, viser à la souris est le geste le plus coûteux qui existe. C'est, d'après le manuel lui-même, ce qui rend la Session jouable.

**Coût ici.** `CP_Session` n'a **aucune gestion clavier** (vérifié : grep `Key|Char(|getchar` ne rend rien). Mais l'infrastructure est là et éprouvée : `Core.GetChar()` + `UI.ConsumeChar()` + `CP_Toolkit/Keys.lua`, exactement comme `CP_Editor.lua:3332, 3350`. Il faut : un curseur `sel = {t,s}`, un liseré dans `drawCell`, et six touches. ~60 lignes, un fichier, risque nul.

## A4 — Plus de quatre colonnes (une ligne)

**Vérifié.** `Loop.TRACKS = Loop.MAX_LANES // 2` avec `MAX_LANES = 8` (`Loop.lua:46-49`), et le commentaire dit déjà « raising it is one line here ». Le moteur en sert 32 (`cp_lanes.h`, `kMaxLanes = 32`) et 32 ports (`cp_types.h:29`).

**Le calcul de ports, que personne n'a écrit** : les cases audio prennent le port `t` (`Cells.lua:211`), les lanes MIDI `PORT_BASE + lane` = 8+lane (`Loop.lua:56, 163`), l'audition le 31 (`Voice.lua:95`). Donc **`MAX_LANES = 16` (8 colonnes) tient sans rien d'autre** : audio 0-7, MIDI 8-23, audition 31. À 12 colonnes, MIDI atteint 31 et entre en collision avec l'audition — il faudrait bouger `PORT_BASE`. Toutes les tables par piste de `CP_Session` sont bâties en boucle sur `TRACKS` (`:91`, `:1664-1684`), donc elles suivent.

**Pourquoi ça compte.** Batterie, basse, clavier, voix : la grille est pleine. Pas de retour d'effet, pas de deuxième synthé, pas de nappe. Aucun concurrent n'a de plafond comparable. Le seul vrai coût est la largeur d'écran (`cell_w` plancher à 24 px, `:2389`).

## A5 — La région et le gain d'une case audio

**Chez le concurrent.** Ableton, verbatim (vérifié, fetch) : « You can adjust the clip start and end position using the respective value fields. »

**Vérifié ici.** `Cells.Arm(t, lane, path, rate)` (`Cells.lua:237`) ne prend qu'un chemin et un taux. **`clip.offs`, `clip.len`, `clip.gain` n'ont aucun consommateur** : une sélection de deux mesures glissée depuis `CP_Editor` dans une case joue **le fichier entier**. Or tout est déjà en place en dessous : le moteur porte `loop_start` / `loop_end` / `pos` / `gain` en frames source (`cp_main.cpp:389-395`, `cp_voice.cpp:143-144`), et `Voice.Play` les transmet déjà (`Voice.lua:400-401`). Le descripteur les porte (`Clip.lua:137`), le drag les remplit.

**Coût.** Faire passer offs/len/gain de `Cells.Arm` jusqu'à `opts` dans `playAt` : ~20 lignes dans un fichier, plus `soundBars` qui doit mesurer la région et non le fichier. Risque : faible.

**Ce que ça rapporte.** Le geste « je découpe un break en huit tranches, une par case » devient possible — c'est un mouvement fondateur d'une session view, et il est aujourd'hui strictement impossible. Et l'aller-retour éditeur→case cesse de mentir.

## A6 — `+Scene` : superposer au lieu de remplacer (cinq lignes)

**Chez le concurrent.** FL, verbatim (vérifié, fetch) : `+Scene` « will replace playing Clips with any new Clips on the same track in the next Scene but leave any Clips on unused tracks (in the new scene) playing. » Ableton obtient la même chose autrement : le bouton stop est **présent par défaut dans chaque case vide et se retire case par case** (`Add/Remove Stop Button`, Ctrl+E — vérifié, manuel L11).

**Pourquoi ça compte.** Aujourd'hui `sceneLaunch` arrête toute colonne sans clip (`CP_Session.lua:883-893`). Conséquence : **une nappe ou un pad ne peut pas survivre à un changement de scène** — il faut dupliquer le clip dans les huit lignes. C'est la gêne n°1 d'une grille à scènes.

**Coût.** `+Scene` = un booléen passé à `sceneLaunch` et un test `Core.ModCtrl()` sur le lanceur (`:2437`). Cinq lignes, **zéro stockage**. La version Ableton (bouton stop retirable par case) coûte plus cher ici parce qu'une case vide n'a pas de descripteur (`cells[t][s]` est nil) : il faudrait une table parallèle persistée. **Faire `+Scene`, garder l'autre pour plus tard.**

## A7 — Nommer, insérer, dupliquer, CAPTURER une scène

**Chez le concurrent.** Ctrl+R renommer, Ctrl+I insérer, Ctrl+D dupliquer, et surtout **Ctrl+Shift+I `Capture and Insert Scene`** : « places copies of the clips that are currently running in the new scene and launches the new scene immediately **with no audible interruption** » (vérifié, dossier/manuel L12).

**Vérifié ici.** Le lanceur de scène n'a **aucun menu contextuel** (`:2435-2438`, seul `MouseClicked(1)`). Les scènes n'ont ni nom, ni ordre, ni nombre réglable.

**Coût, et la trouvaille qui rend Capture exact.** Copier les descripteurs joués dans la ligne libre (boucle sur `pasteCell`, `:1126`), puis **`Loop.SetLaneTag(lane, Ident.Of(nouveau))`** : le tag est de la métadonnée pure (`Loop.lua:735` → `CP_LaneSet(lane,"tag")`, jamais lu par le fil audio). La nouvelle ligne s'allume comme jouante **sans qu'une seule note soit redéclenchée** — « no audible interruption » par construction, et non par chance. C'est l'anti-« j'avais un truc bien et je l'ai perdu ».

## A8 — Une quantification de lancement par clip

**Chez le concurrent.** Ableton : chooser `Launch Quantization` par clip (None / Global / valeur), et il s'applique aussi aux enchaînements automatiques (vérifié, dossier). FL : Trigger sync **`Auto` — « Defined by the length of the Clip being triggered (up to 4 beats) »** (vérifié, fetch).

**Pourquoi ça compte.** Une boucle d'une mesure et une de quatre ne veulent pas la même frontière. Avec un Q global on attend quatre mesures pour tout, ou on casse la phase des clips longs.

**Coût — et c'est le seul de la liste qui n'est pas du Lua.** `launch_q_` est un unique atomique global du moteur (`cp_lanes.h`, `set_launch_q`), lu par `launch_target` et `stop_target` (`cp_lanes.cpp:155, 165`). Un Q par lane = un atomique par lane + un paramètre dans `CP_LaneSet` + la plomberie Lua. Le champ `clip.q` existe déjà dans le format et est mort (`Clip.lua:24, 141`) : une promesse déjà écrite dans les fichiers des projets. **Rang bas : ça rivalise avec A2, et A2 est gratuit en comparaison.**

## A9 — Élargir la fenêtre de tolérance (une constante)

**FL, verbatim (vérifié, fetch)** : « Clips normally missed when triggered slightly late will be triggered immediately, so a small part at the beginning of the Clip will be truncated (this is usually preferable to delaying the Clip until the next bar). »

**Vérifié ici** : `cp_lanes.cpp:154-158` fait déjà exactement ça — `(ph < 0.05) ? (pb - ph) : (pb - ph + q)` — et la phase des lanes étant ancrée sur la timeline (`phase_hit`, `:459-466`), l'entrée est bien tronquée et non décalée. Mais **0,05 beat = 25 ms à 120 BPM**. Une main humaine est en retard de 40 à 120 ms.

**Coût** : une constante, à passer de `0.05` à une fraction de `q` (1/8 de Q = 250 ms à Q: Bar / 120). Une ligne de C++ et une recompilation. Risque : trop large, un clic « en avance pour la mesure suivante » repart sur la précédente ; 1/8 est le bon compromis. **Le meilleur rapport effet/ligne de tout le document.**

## A10 — Nombre de tours joués / temps restant

Ableton l'affiche dans le Track Status field (camembert = tours déjà joués ; barre = temps restant du one-shot) (vérifié, dossier). Ici la case a une barre de progression (`:1483-1495`) mais ni compteur de tours, ni temps restant. Le compteur de tours tombe **gratuitement** du poll de A2 (une détection de rabat de phase). À faire avec A2, pas avant.

---

## Ordre : si l'utilisateur ne fait que trois choses

**D'abord deux corrections d'une ligne, qui ne sont pas des chantiers** : `MAX_LANES = 16` (A4) et la fenêtre de tolérance (A9). Elles changent l'usage quotidien pour un coût qui ne se compte pas.

Puis, dans l'ordre :

1. **La fin de passe comme évènement (A1 + A2 + A10 + D3).** Une seule machinerie, entièrement en Lua, dans un fichier, et elle livre le one-shot, la Motion par colonne et le compteur de tours. Elle corrige au passage la mitraillette du one-shot audio, qui est le pire son que produise la fenêtre. Rien d'autre dans la liste ne rend autant par ligne écrite.
2. **La région et le gain d'une case audio (A5 + D4).** Débloque toute la moitié audio de la grille — découper un break en cases, utiliser une sélection éditée — et tout existe déjà sous elle : c'est du câblage, pas de la conception.
3. **Le paquet de petits gestes : `+Scene` (A6) + la sélection clavier avec Entrée (A3).** Cinq lignes plus soixante. Ensemble, ils font passer la grille de « je vise des cases à la souris » à « je joue ».

`A7` (Capture and Insert Scene) est juste derrière et je le remonterais si le travail est plutôt de la composition que de la performance. `A8` (Q par clip) est le seul qui demande de rouvrir le C++ : à ne faire qu'après avoir joué avec A2, qui peut le rendre inutile.

---

# B. CE QUI MANQUE ET QU'IL NE FAUT PAS FAIRE

**B1 — L'enregistrement audio dans une case.** Ableton le fait (Session Record, Ctrl+Shift+F9). Ici il faudrait un enregistreur, des fichiers sur le disque, un punch quantifié, une gestion de nommage — et REAPER a déjà tout ça, en mieux. Le chemin existe déjà : enregistrer dans l'arrangement, ouvrir dans `CP_Editor`, glisser la sélection dans une case. Ce qui manque de ce chemin est A5, pas un enregistreur.

**B2 — Le modèle « pattern » de FL.** Un pattern traverse tous les instruments (vérifié, manuel Channel Rack). Ici l'exclusivité par colonne est **structurelle** : une colonne possède une paire de lanes (`Loop.LiveLane`/`TwinLane`, `Loop.lua:725-729`), ce qui donne l'exclusivité gratuitement. Rouvrir le choix, c'est jeter ça. En revanche sa conséquence est volable et elle est en A7 (dupliquer une scène entière).

**B3 — La zone de performance dans l'arrangement (FL).** Contredit frontalement l'acquis « CP ne touche pas l'arrangement de l'utilisateur, aucune piste d'infrastructure ». La fenêtre séparée est le bon choix.

**B4 — Le Session → Arrangement recording d'Ableton.** Tentant (« only clips, not new audio data »), et c'est un vrai chantier : journal temporel, création d'items, cases audio à convertir en takes avec taux et pitch — et ça écrit dans l'arrangement de l'utilisateur. Le geste qui rapporte 80 % pour 5 % du travail est ailleurs : **rendre `CP_Session` SOURCE sur DragBus** (aujourd'hui elle ne publie rien — aucun `Bus.BeginClip`, vérifié), pour pouvoir tirer une case vers l'arrangement, le Sampler ou l'éditeur. `CP_Editor` a déjà tout le protocole (`Insert.ArrangeHit` / `GhostCommit`).

**B5 — Les Follow Actions par clip d'Ableton, en premier.** A/B avec deux probabilités, multiplicateur de boucles, Jump avec cible, plus `Enable Follow Actions Globally` pour pouvoir éditer sans que la machine saute ailleurs : c'est un panneau par case, et il faut le construire avant de savoir si le grain colonne suffisait. Faire A2 d'abord, et n'ajouter la surcharge par case que sur un manque constaté en jouant.

**B6 — Le tempo et la signature par scène (Ableton).** Ici ça voudrait dire écrire la carte de tempo de REAPER depuis un lancement de clip — donc modifier le projet de l'utilisateur pendant un jam, et ça n'a aucun sens en horloge libre (il n'y a pas de carte de tempo). Refuser.

**B7 — Les modes de lancement Gate / Repeat / Toggle par clip.** `Gate` demande un relâchement sur la case, `Repeat` un maintien qui retrigge : les deux existent chez Ableton **pour des contrôleurs**, pas pour une souris. `Toggle` est déjà le comportement (`launchCell` : recliquer arrête, `:851-854`). Sans mapping MIDI, ils n'achètent rien.

**B8 — Le mapping MIDI des cases (Ctrl+M), pas avant d'avoir tranché l'entrée.** C'est ce qui rend la Session d'Ableton jouable, et c'est techniquement à portée (`Loop.pollCapture` draine déjà `MIDI_GetRecentInputEvent`, `Loop.lua:895-996`). Mais **le même flux alimente la piste armée** (`Loop.SetArmedLane`) : un pad qui lance une case jouerait aussi l'instrument et se ferait enregistrer dans la prise en cours. Il faut d'abord décider d'un filtre (canal, port, plage de notes). Pas un refus — un préalable.

**B9 — La bibliothèque de comportements (Press : Retrigger / Hold & stop / Hold & motion / Latch de FL).** Quatre modes pour une souris, alors que `Motion` seule couvre l'usage. Prendre `Motion`, laisser `Press`.

---

# C. CE QUI EST DÉJÀ LÀ ET QUI EST BON — à protéger

**C1 — L'échange par paire de lanes, et la scène qui tombe d'un bloc.** Le clip entrant est écrit dans une lane silencieuse (donc le coût d'écriture est gratuit) puis `Play(twin)` + `StopClip(live)` partent ensemble (`CP_Session.lua:871-878`). Et le moteur **draine toutes les commandes du bloc d'un coup**, avec le raisonnement écrit noir sur blanc : « distillees une par bloc, elles pourraient tomber de part et d'autre d'une frontiere de quantize — la moitie d'une scene partant une mesure avant l'autre n'est pas un quantize, c'est un bug poli » (`cp_lanes.cpp:203-210`). Ableton cache ce mécanisme ; ici il est explicite et démontrable. **Ne jamais le contourner.**

**C2 — La phase ancrée sur la ligne de temps, pas sur l'instant du clic.** Lancer une boucle de quatre mesures à la mesure 2 la fait entrer *à sa deuxième mesure* (`Cells.lua:306-314`, `phase_hit` dans `cp_lanes.cpp:459-466`). C'est ce qui verrouille toutes les boucles sur la même grille, et l'audio obéit à la même règle que le MIDI parce qu'il lit la phase de la lane. C'est le cœur, et c'est juste.

**C3 — Un son EST une lane.** Une seule machine à états pour l'audio et le MIDI : même lancement quantifié, même arrêt en file, même échange sur une frontière, même compte à rebours, même barre de progression, même scène. Ableton a le résultat ; ici il est obtenu en faisant de l'audio **du contenu pour le moteur qui marchait déjà**, au lieu d'écrire la machine deux fois (`CP_Session.lua:646-667`). C'est la meilleure décision d'architecture de la fenêtre.

**C4 — Cliquer le contenu ouvre l'éditeur, cliquer la bande lance. Jamais l'inverse.** (`:1437-1441`, `:1569-1592`.) Ableton mélange les deux — cliquer le nom sélectionne, le triangle lance, et il faut une préférence (`Select on Launch`) pour rattraper la confusion. Ici les deux gestes ne se croisent jamais. **Meilleur qu'Ableton, et c'est exactement le genre de chose qu'une refonte de l'UI perd sans s'en apercevoir.**

**C5 — Une colonne EST une piste du projet, adoptée par GUID.** Le slot est stable, l'ordre d'affichage suit l'ordre du projet, réordonner ses pistes ne coupe rien (`Loop.lua:234-284`). Un projet vide ne dessine **aucune** colonne et le dit en une phrase (`CP_Session.lua:2379-2387`). Et « Hide this column » a remplacé « Unroute » avec la raison écrite (`:357-368`). C'est l'adaptation à REAPER qu'aucun concurrent ne peut avoir, et elle est finie.

**C6 — Le mixer est celui de REAPER, pas un second.** Chaque valeur est l'état de piste de REAPER lu et écrit par son API, la fenêtre de FX qui s'ouvre est la sienne, le solo est le sien — donc l'arrangement se tait aussi, et l'aide le dit (`:192-193`). Avoir la chaîne et les envois de la colonne **à côté** des clips est précisément ce à quoi sert une session view, et ici il n'y a pas de deuxième vérité à synchroniser.

**C7 — La rangée de carrés d'arrêt, toujours visible.** Un stop par colonne plus le global à gauche (`:2460-2486`). FL met le stop sur le clic droit ; Ableton le met dans le Track Status field. Ici c'est une cible large et permanente — le bon choix, et il rend inutile le clic-droit-stop de FL.

**C8 — Follow / Free, et « waiting for the transport » écrit dans la case.** Ableton n'a pas ce choix : il *est* le transport. Ici la session peut être sa propre horloge, et un lancement qui attend un transport arrêté le **dit en mots** (`:1501-1506`, `Loop.PendingWaitsClock`). Mieux qu'un triangle qui clignote et qu'il faut interpréter.

**C9 — Le compte à rebours de la prise, en beats, dans la case où elle va tomber.** Avec « PLAY / waiting for the transport » quand l'horloge ne tourne pas, et un clignotement à 5 Hz pour une prise en cours contre 2 Hz pour une attente (`:1454`, `:1514-1548`). Ableton a un count-in dans la barre d'outils ; ici il est à l'endroit qu'on regarde.

**C10 — La tolérance existe déjà** (`cp_lanes.cpp:154-158`) : c'est un acquis à nommer pour qu'il ne soit pas redécouvert comme un manque. Seule la largeur est à revoir (A9).

**C11 — La discipline « zéro allocation par frame ».** `CD_LBL`, `bars_lbl`, `cell_lbl`, `ENGINE_BADGE`, `stat`, `AUDIO_CLIP` réutilisé en place. Trois fuites subsistent (D9, D10, D11) mais la règle est tenue partout ailleurs, et elle est la raison pour laquelle la fenêtre tient son budget.

**C12 — Un dépôt ne lance jamais** (`:1268`). Décidé, écrit, correct.

---

# D. CE QUI EST LÀ MAIS MAL FAIT

**D1 — Une case audio envoie un do central dans l'instrument de la colonne.** Vérifié de bout en bout : `armLane` publie `AUDIO_CLIP` dans la lane (`CP_Session.lua:797`), la lane est liée au port de la colonne, lui-même attaché à **la piste de destination** (`Loop.lua:179-180`), et `run_gate` émet le note-on/off sur ce port (`cp_lanes.cpp:481, 549, 559`) **sauf si la lane est mutée** (`:479`). Or `CP_Session` n'appelle jamais `Loop.SetMute` (vérifié par grep : les seuls appelants du dépôt sont `Mix.SetMute` `:2105` et `CP_Looper.lua:975`). Donc sur une colonne qui porte **à la fois** un instrument et des cases audio — le cas exact que `audioDest` traite en créant un enfant (`:736-741`) — l'instrument reçoit un do à chaque passe. Le commentaire qui couvre le passage affirme le contraire (`:792-796`). **Correction : une ligne**, `Loop.SetMute(lane, audio)` dans `armLane` — la lane reste en `kLanePlaying`, la phase continue, et `Cells.Tick` ne lit pas la sortie MIDI.

**D2 — Le tag de lane n'est pas sérialisé : après réouverture du projet, la grille ment.** `Loop.Serialize` écrit `bars|mute|mode|n|notes` (`Loop.lua:1110-1130`) — **pas le tag**. La chaîne des conséquences, toutes vérifiées : `Deserialize` remet en mode 3 toute lane qui jouait (`:1185`) ; la boucle de rappel demande `LaneOfTag(t, GetLaneTag(live) = 0)`, qui rend la lane vive (`Loop.lua:748`), puis `sceneOfLane` → `Ident.CellOf(0)` → nil (`Ident.lua:149`) → **aucune case audio n'est réarmée**, exactement l'inverse de ce que promet le commentaire au-dessus (`:2214-2218`) ; et le repli de `drawCell` (`:1357`) a besoin de `cur[t]`, qui n'est persisté nulle part (`:85`). Résultat : la grille montre tout arrêté, les lanes jouent, et les cases audio bouclent une note sans échantillon. **Un champ de plus dans le format (v6) plus la persistance de `cur`.**

**D3 — Un one-shot audio se mitraille.** Voir A1 : `Cells.lua:326-333`. Le commentaire assume le choix contre l'alternative (« un kick suivi d'un long silence ») — mais les deux réponses sont fausses, et la bonne est le mode one-shot.

**D4 — La région d'un clip audio est perdue à la lecture.** Voir A5 : `Cells.Arm` ignore `offs`/`len`/`gain` alors que la voix les porte. Le descripteur voyage, est sauvegardé, et ne fait rien.

**D5 — `stopTrack` ne réconcilie pas la paire.** `stopTrack` (`:809-814`) ne regarde que `liveLane(t)`. Pendant un échange en file les deux moitiés sont occupées et `resolveLive` ne bascule pas (`Loop.lua:714-722`). Donc le carré de colonne (`:2483`), « Stop every clip » (`:2286`) et la branche `else` de `sceneLaunch` (`:891`) **arrêtent le clip sortant et laissent le clip entrant démarrer**. `launchCell` réconcilie explicitement la paire (`:834-855`) ; ces trois chemins ne le font pas. Symptôme : on presse Stop pendant un changement de scène, et la session ne s'arrête pas.

**D6 — Annuler une prise laisse la colonne muette.** `recCell` pose `Loop.StopClip(live)` pour que le clip sortant parte sur la frontière de la prise (`:1015`) ; `stopRec` ne fait que `Loop.Clear(rec.lane)` (`:1083`), et l'arrêt en file reste armé. On annule une prise qu'on n'avait pas voulue et la colonne s'arrête quand même. Asymétrie directe avec `:842-844`, qui rend sa lecture au clip sortant.

**D7 — Aucune annulation sur la grille.** `clearCell`, `pasteCell`, `renameCell`, `setCellColor`, `setCellTempoMode` et le dépôt écrivent tous par `saveGrid` → `SetProjExtState` (`:480-491`) **sans `Undo_BeginBlock`**, alors que `Loop.SetLaneDest` et toutes les écritures du mixer en créent un. Et Alt+clic efface une case définitivement, sans confirmation (`:1565`) — le geste destructeur le moins cher de la fenêtre.

**D8 — « Stretch » ment deux fois.** (a) Le libellé du menu dit « Stretch (keeps the key, plays late) » (`:1212`) alors que l'implémentation joue un **repitch** jusqu'à ce qu'un fichier cuit existe (`Warp.lua:196-208`). (b) Le commentaire promet que c'est « seulement pour une passe » (`:549-551`), mais **rien ne réarme après la cuisson** : `soundFor` n'est appelé que depuis `armLane`, `retune` et la boucle de rappel, et `Warp.Tick()` ne notifie personne. Une case reste en repitch jusqu'au prochain lancement manuel. (c) `Warp.Retry` a zéro appelant (`Warp.lua:172`) : « audio · warp failed » est définitif pour la session, sans recours.

**D9 — `audioSub` ouvre un fichier sur le disque à chaque frame, par case en stretch.** `drawCell:1508` → `audioSub:613-618` → `Warp.State` → `PathFor` (deux `string.format`, un `gsub`, une boucle FNV sur le chemin complet) puis `fileExists` = `io.open` (`Warp.lua:85-99`). Le commentaire juste au-dessus dit « no allocation on a draw path » : c'est vrai des cinq chaînes, faux de ce qui les choisit.

**D10 — Collision de clé dans le cache de troncature.** `cellLabel` calcule `k = t*SCENES + s` (`:396`). L'en-tête appelle `cellLabel(t, SCENES, …)` (`:2399`) → `k = t*8+8` ; la case (t+1, scène 0) (`:1498`) → `k = (t+1)*8 = t*8+8`. **Même emplacement**, textes et largeurs différents, donc chacun invalide l'autre : deux `TruncateText` par colonne et par frame, dans le chemin de dessin.

**D11 — Le mixer se reconstruit pendant le geste qu'il devait rendre fluide.** `guidOf` (`Mix.lua:310-313`) alloue une chaîne **par appel**, et `chainOf`/`sendsOf` l'appellent chaque fois — de l'ordre de 14 allocations par colonne et par frame. Pire, la clé de cache est `GetProjectStateChangeCount` (`Mix.lua:306`) : *(supposé, non vérifiable en lecture seule)* si `SetMediaTrackInfo_Value` incrémente ce compteur, alors chaque frame d'un glissé de fader invalide tous les noms de FX et d'envois de toutes les bandes.

**D12 — Q et l'horloge ne survivent qu'à une fermeture propre.** `rec_bars` va dans `ProjExtState` (`:454`) ; Q va dans le moteur puis dans le blob. Mais `setQIndex` (`:425-433`) et la bascule Clock (`:2272-2276`) n'appellent jamais `Loop.MarkDirty()`, et `AutoSave` ne surveille que `EvtVersion*8 + Mode` par lane (`Loop.lua:1293-1302`). `CP_Looper` appelle `MarkDirty` sur les deux (`CP_Looper.lua:677, 687`) — deux fenêtres, deux comportements pour le même réglage.

**D13 — Trois paragraphes de l'aide décrivent un câblage supprimé.** `:113-114` « or unroute it » (retiré volontairement, `:357-361`) ; `:171` « Each column that plays a sound grows a SAMPLER track » (faux depuis `audioDest`, `:736-741`) ; `:176-178` « a channel of the column's own (9 to 12), and the router feeds each destination one filtered channel » (le routeur, les canaux et l'envoi filtré ont tous disparu). L'aide est le seul endroit où l'utilisateur apprend le modèle ; elle en enseigne un qui n'existe plus.