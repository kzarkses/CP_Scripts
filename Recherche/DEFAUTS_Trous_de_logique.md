# LES TROUS DANS LA LOGIQUE

Méthode : lecture intégrale de `CP_Engine/Loop.lua`, `Cells.lua`, `Clip.lua`, `Ident.lua`, `Tracks.lua`, `Warp.lua`, `SrcTempo.lua`, `Bus.lua`, des sections modèle de `CP_Session.lua`, `CP_Editor.lua`, `CP_Looper.lua`, de l'en-tête de `Kit.lua`, et de `CP_Native/src/core/cp_lanes.{h,cpp}`. **Vérifié** = lu et tracé jusqu'à sa conséquence. **Supposé** = mécanisme lu, conséquence déduite sans exécution. Aucun fichier modifié. Je ne reprends pas ce que le dossier établit déjà, sauf pour le corriger ou l'enfoncer.

---

## 1. LE MODÈLE EST-IL COHÉRENT ?

Non. Il y a **deux ontologies superposées** qui n'ont jamais été réconciliées, et cinq mots qui désignent chacun deux choses.

### 1.1 Les collisions de vocabulaire, vérifiées

| Mot | Sens A | Sens B | Où les deux se croisent |
|---|---|---|---|
| **track** | piste REAPER de destination | paire de lanes = colonne | `Loop.SetLaneDest(lane, track)` (`Loop.lua:342`) prend un *lane*, en tire un *track* (sens B) et l'attache à un *track* (sens A). Trois emplois dans une signature de deux arguments. |
| **lane** | lane moteur 0..31 | bande de l'UI du Looper (0..3) | `CP_Looper.lua:828` : `local el = Loop.LiveLane(l)` — `l` est une bande, `el` une lane. Le Looper affiche « Lane 1..4 » pour ce que `Loop` appelle des *tracks* et ce que la Session appelle des *colonnes*. |
| **cell** | case de grille (t, scène) | demi-lane porteuse de voix audio | `Cells.Arm(t, lane, path, rate)` (`Cells.lua:237`) — le module qui s'appelle « Cells » ne connaît **pas la notion de scène**. Sa « cellule » est `col[t].half[0|1]`. |
| **clip** | descripteur CPC1 de l'utilisateur | le clip d'une note synthétisé pour une case audio | `AUDIO_CLIP` (`CP_Session.lua:747`) est un `kind="midi"` complet qui traverse `Loop.ApplyClip` comme un vrai clip. |
| **column** | slot 0..TRACKS-1 (stable, possède les clips) | index de dessin 1..ColumnCount | `Loop.ColumnAt(i)` (`Loop.lua:286`) traduit. La distinction est tenue dans le dessin (`CP_Session.lua:2394`, `:2439`) et dans le drop (`:1305`) — mais `sceneLaunch` et `stopAll` bouclent sur les **slots** (`:884`, `:897`), donc ils touchent des colonnes qui ne sont pas dessinées. |

### 1.2 Trois objets qui se recouvrent sans que rien tranche

**(a) `origin` a deux conventions dans un même fichier — vérifié.**
`CP_Looper.lua:1032` écrit `c.origin = "looper:" .. l` (une bande, 0..3) ; `CP_Looper.lua:1128` écrit `c.origin = "looper:" .. lane` (une lane moteur, 0..7). `Clip.lua:145-147` déclare que `origin` « dit quelle lane JOUE » ; `CP_Editor.lua:667` le lit comme une piste (`Loop.TrackOfLane`) ; `CP_Session.lua:959-962` le lit comme un **index de lane brut** et fait `Loop.ApplyClip(ln, ac)` dessus. Quatre lectures, deux écritures, une seule sauvée par l'arithmétique : `TrackOfLane(lane) = lane % 4`, donc les deux conventions se rejoignent par accident. Ce n'est pas une cohérence, c'est une coïncidence — et `CP_Session.lua:961` est la branche où elle ne tient pas.

**(b) Le pad du Sampler et la case audio de la Session sont le même objet, décrits deux fois — vérifié.**
Les deux sont : un fichier + une région + un taux + un tempo source.

| Fait | Case Session | Pad Sampler |
|---|---|---|
| région | `clip.offs` / `clip.len` (CPC1) | RS5K `SOFFS` / `EOFFS` (`Kit.P`, `Kit.lua:66`) |
| tempo source déclaré | `clip.src_bpm` (`Clip.lua:138`) | `P_EXT:CP_KIT_BPM` (`Kit.lua:897-900`) |
| suivi du tempo | taux de voix (`Cells.lua:357`) | transposition en demi-tons (`Kit.lua:888`) |
| couleur | index de palette `Clip.COLORS` | — |

Aucun des deux ne sait lire l'autre. Et le pont existant ne transporte que le chemin (dossier §3). Ce n'est pas « une fonctionnalité manquante », c'est **le même concept modélisé deux fois avec deux stockages et deux unités**.

**(c) « Le kit » a deux définitions concurrentes — vérifié.**
`Kit.active_guid` (`Kit.lua:103`, persisté `CP_Sampler/ACTIVE_KIT`, `:451`) dit quel kit le Sampler pilote. `Loop.KitViewOfTrack(tr)` (`Loop.lua:392`) remonte les parents de la piste routée jusqu'à un `P_EXT:CP_KIT`. Les deux répondent « le kit », et rien ne les fait converger : c'est la racine du défaut B11 du dossier (les noms de rangées viennent d'un kit, le son part vers l'autre).

Asymétrie supplémentaire, vérifiée : un projet peut contenir **N kits** (`Kit.kits`, `Kit.lua:102`) mais **un seul instrument chromatique** — `scanInstrument` prend le premier `CP_KIT_INSTR` et sort (`Kit.lua:395`, `break`). Et le mode qui choisit entre les deux (`Kit.mode`) est stocké **sur la piste du kit actif** (`CP_KIT_MODE`, `Kit.lua:352`). Donc un réglage global vit dans un objet multiple et arbitre un objet singleton.

### 1.3 Ce qui est cohérent, et qu'il faut dire

La paire de lanes est un vrai invariant : `LiveLane`/`TwinLane` (`Loop.lua:725-729`) sont dérivées du moteur à chaque frame par `resolveLive` (`:714`), et les trois fenêtres les lisent au lieu d'en garder une copie. L'exclusivité « une colonne, un clip » tombe de là, gratuitement. C'est la seule relation du modèle qui soit à la fois nommée, unique et respectée partout.

---

## 2. QU'EST-CE QUI N'A PAS DE PROPRIÉTAIRE

### 2.1 La longueur d'un clip : trois propriétaires, dont un qui la change tout seul

`clip.bars` (grille) → `Loop.SetLengthBars(lane, bars)` → `Lane.bars` (moteur). Puis, **à chaque bloc audio** :

```cpp
double Lanes::lane_len_beats(int li, double ts_num) const {
  double b = lanes_[li].bars.load(...);
  return b * ((ts_num >= 1.0) ? ts_num : 4.0);
}
```
`cp_lanes.cpp:134-138`, avec `ts_num` venant de `tr_cache_.ts_num` (`:596`), publié par `Loop.Poll` → `Loop.TsNum()` → `TimeMap_GetTimeSigAtTime(0, nowPos)` (`Loop.lua:767-770`), et `nowPos` est **la position de lecture** (`:761-763`).

**Conséquence vérifiée** : la longueur d'une boucle n'est pas une propriété du clip, c'est le produit d'un nombre de mesures par la signature rythmique *à l'endroit où la tête de lecture se trouve en ce moment*. Un projet avec une mesure en 3/4 quelque part fait changer la longueur de **toutes** les lanes quand le transport la traverse. Les notes, elles, sont stockées en beats absolus (`LaneNote.start`, `cp_lanes.h:115`) et ne se remettent pas à l'échelle : le point de bouclage glisse sous la musique.

Il n'existe nulle part de « signature rythmique du clip ». Ableton en a une par clip (référence §3, Clip View, vérifié). Ici la métrique est empruntée au projet, à un instant qui n'a rien à voir avec le clip.

### 2.2 Le tempo : quatre sources, aucune arbitre

1. `Loop.Tempo()` = `Master_GetTempo()` (`Loop.lua:758`) — sert à `Cells.playAt` pour `spb = 60/tempo` (`Cells.lua:317-318`) et à `Warp.Resolve` pour la clé de cache (`Warp.lua:203`).
2. `SrcTempo.Bpm(path, declared)` — le tempo du fichier.
3. `clip.src_bpm` — le tempo « déclaré » qui doit gagner. **Il n'a aucun écrivain dans tout le dépôt** : `grep src_bpm` ne rend que `Clip.lua:19`, `Clip.lua:138` (déclaration + registre) et `CP_Session.lua:535`, `:589` (deux lectures). Le champ prioritaire du modèle est en écriture morte.
4. Le fichier cuit par `Warp`, dont le tempo est figé dans son nom de cache (`Warp.PathFor`, `Warp.lua:90`).

Et le tempo déclaré du Sampler vit ailleurs (`P_EXT:CP_KIT_BPM`). Donc **le même fichier a deux tempos déclarés possibles, dans deux magasins, et celui de la Session ne peut pas être écrit.**

### 2.3 L'identité : quatre emplacements, deux espaces de nommage qui se croisent

- `clip.id` (dans le CPC1, sauvé dans `CP_Session/grid`)
- le registre `Ident.reg` — **table faible, une par script Lua** (`Ident.lua:80`)
- le compteur `CP_Ident/next` — **par PROJET** (`Ident.lua:62-63`)
- le champ `tag` de la lane — **par PROCESSUS REAPER** (`cp_lanes.h:163`, remis à zéro seulement à la construction, `cp_lanes.cpp:19`)

Le commentaire d'`Ident` assume la collision inter-projets et affirme qu'elle « ne coûte rien — voir `Get` », parce que `Ident.Get` interroge le registre et rend `nil` (`Ident.lua:134-144`). **Mais `Get` n'est pas le seul consommateur du tag.** `Loop.LaneOfTag(t, tag)` (`Loop.lua:747-753`) compare des nombres bruts et ne passe jamais par le registre.

**Scénario vérifié par lecture** : projet A alloue l'id 1000003 pour une case, la lance, la lane porte le tag 1000003. Fermer le projet A, ouvrir le projet B dans la même instance de REAPER — le binaire survit, la lane garde 1000003. Le projet B, dont le compteur repart de 1, alloue 1000003 à sa première case dessinée (`Ident.Of` est appelé depuis `cellTag` ← `drawCell`, `CP_Session.lua:264`, `:1356`). Dès la première frame, `LaneOfTag` répond « oui », la case du projet B se dessine comme jouant, et `editCell` (`:921`) écrira dans une lane qui contient les notes du projet A.

La conclusion du raisonnement d'`Ident` est juste ; sa prémisse (« le seul lecteur est le registre ») est fausse.

### 2.4 L'état de lecture : un propriétaire, trois copies muettes

Le moteur possède `mode` — c'est net. Mais :
- `cur[t]` (`CP_Session.lua:85`) est une copie, **jamais persistée**, réécrite chaque frame par `sceneOfLane` (`:2353-2356`) et utilisée comme repli quand le tag est nul (`:1357`).
- `slot.running` / `slot.armed` (`Cells.lua:107-109`) sont l'état des voix, resynchronisés par lecture de `Loop.Mode` — bien.
- **`muted` n'est lu par personne du côté grille.** `grep GetMute` sur `CP_Session.lua` et `CP_Editor.lua` : zéro. Seul le Looper l'écrit (`CP_Looper.lua:975`) et `Loop.Serialize` le persiste (`Loop.lua:1121`). Et `Cells.drive` (`Cells.lua:388-460`) ne consulte pas la mute non plus : elle ne lit que `Mode`, `Pending`, `PendingTarget`, `LenBeats`.

**Conséquence vérifiée** : muter une lane dans le Looper coupe son MIDI (`cp_lanes.cpp:479`, `flush_lane`) mais **ne coupe pas la case audio** portée par la même lane. Et la mute survit à la sauvegarde du projet, sans qu'aucune interface de la Session ne la montre ni ne l'annule.

### 2.5 La couleur : un propriétaire, un seul consommateur

`Clip.ColorOf` — `grep` sur tout le dépôt : **un appelant**, `CP_Session.lua:1416`. La couleur est déclarée comme « ce qui voyage avec le clip » (`Clip.lua:43-55`) et elle est invisible dans l'Editor, dans le Looper, dans le fantôme de glisser, et dans REAPER. Ce n'est pas un défaut de propriété — c'est un champ modélisé pour un usage qui n'existe qu'à un endroit.

### 2.6 Les champs qui voyagent et que personne ne lit

Vérifié par `grep` : `clip.gain`, `clip.pitch`, `clip.rate`, `clip.root`, `clip.q`, `clip.lmode`, `clip.src_bpm` n'ont **aucun écrivain applicatif** (au-delà des valeurs par défaut de `Clip.new`, `Clip.lua:31-40`) et, pour `q`/`lmode`/`gain`/`pitch`/`rate`, aucun lecteur. `Cells.playAt` écrit `opts.gain = 1.0` en dur (`Cells.lua:358`). Chaque case du projet transporte donc sept champs morts dans le `.RPP`, et le seul défaut sérieux là-dedans est qu'ils **promettent un modèle** (quantisation par clip, mode one-shot, gain par clip) que rien n'implémente : on lit le format et on croit que la fonctionnalité existe.

---

## 3. ENCHAÎNEMENTS CONCRETS VERS UN ÉTAT ABSURDE

### S1. Créer une piste, et elle arrive avec les clips de quelqu'un d'autre — vérifié

1. Quatre pistes, quatre colonnes. La colonne 1 (slot 1) contient huit clips.
2. Supprimer la piste de la colonne 1 dans REAPER. `Loop.RefreshDests` (`Loop.lua:294-306`) ne retrouve plus le GUID → `Loop.dest[1] = nil` → `syncColumns` libère le slot 1. La colonne disparaît du dessin (`ColumnCount` tombe à 3).
3. **`cells[1]` n'est pas touché.** Rien dans `CP_Session.lua` n'observe un changement de `Loop.dest` pour vider une colonne.
4. Ajouter une nouvelle piste. `syncColumns` (`Loop.lua:242-257`) remplit « les slots libres, le plus bas d'abord » → la nouvelle piste prend le slot 1.
5. La nouvelle piste s'affiche avec les huit clips de l'ancienne, déjà en place, prêts à être lancés dans un instrument qui n'a rien à voir.

Même chaîne avec « Hide this column » (`CP_Session.lua:362-368`) : `SetLaneDest(t, nil)` libère le slot, et la première piste éligible non revendiquée hérite des clips. Le mécanisme d'adoption est écrit avec soin pour que **les clips restent au slot** (`Loop.lua:197-201`, commentaire explicite) — mais il n'a pas prévu qu'un slot libéré soit ensuite réattribué.

### S2. Enregistrer dans le Looper détruit une case de la Session, en silence et pour de bon — vérifié

1. Session : la case (1, 0) joue sur la lane 1, taguée id N.
2. Le Looper affiche exactement cette lane (`CP_Looper.lua:828`, `el = Loop.LiveLane(1)`).
3. Appuyer sur REC dans le Looper : `Loop.SetArmedLane(el); Loop.Rec(el)` (`CP_Looper.lua:925`).
4. `pollCapture` voit le `recgen` bouger et fait `t.n = 0` + `publish` (`Loop.lua:903-912`) : les notes de la case sont effacées du miroir **et** du moteur.
5. **Le tag n'est pas touché** — `kLcRec` ne le remet pas à zéro (`grep tag` sur `cp_lanes.cpp` : une seule écriture, à la construction). Donc `LaneOfTag(1, N)` répond toujours « lane 1 », et la case continue de se dessiner comme la sienne, avec la prise du Looper dedans.
6. `Loop.AutoSave` (`Loop.lua:1293`) écrit la prise dans `CP_Loop/data`. `cells[1][0].notes` contient toujours les anciennes notes, et `CP_Session/grid` aussi.
7. Rouvrir le projet, relancer la case : `armLane` → `Loop.ApplyClip(lane, c)` (`CP_Session.lua:797`) **réécrit les anciennes notes par-dessus la prise**. La prise disparaît sans qu'aucun geste ne l'ait supprimée.

Le même mécanisme, à l'envers, fait revenir un clip effacé : « Clr » dans le Looper (`CP_Looper.lua:968`) vide la lane mais pas `cells[t][s]` ; le prochain lancement depuis la grille le ressuscite.

### S3. Changer de signature rythmique fait mentir la barre de commande — vérifié

`qIndex()` (`CP_Session.lua:415-423`) reconstruit l'index du combo en comparant la valeur du moteur à `Loop.TsNum()` :

```lua
if q <= 0 then return 1 end
if q == 1 then return 2 end
if q == tsn then return 3 end
if q == tsn * 2 then return 4 end
if q == tsn * 4 then return 5 end
return 1
```

Q réglé sur « Bar » en 4/4 → le moteur tient 4.0. Placer la tête de lecture dans une mesure en 3/4 → `tsn = 3` → aucune branche ne tombe → `return 1` → le combo affiche **« Q: Off »** alors que le moteur quantifie toujours à 4 beats. Et le premier clic sur le combo écrit ce mensonge : `setQIndex(1)` → `SetLaunchQ(0)` → la quantisation est réellement désactivée.

### S4. Passer une case audio de Repitch à Stretch change la portion de fichier qui joue — vérifié

`Cells.Arm(t, lane, path, rate)` (`Cells.lua:237`) ne reçoit **que** un chemin et un taux : `clip.offs`/`clip.len` ne l'atteignent jamais, le fichier entier est chargé et joué.
`Warp.Resolve` (`Warp.lua:200-207`), lui, lit `clip.offs` et `clip.len` et les passe à `Bake.FileRegionToWav(q.path, q.s0, q.s1, …)` (`Warp.lua:154`), qui découpe réellement (`Bake.lua:182-190`).

1. Dans l'Editor, sélectionner deux secondes au milieu d'un fichier de trente, glisser vers une case. `selectionClip` (`CP_Editor.lua:1640-1648`) pose `offs`/`len`.
2. La case joue **les trente secondes** (repitch).
3. Clic droit → Tempo → Stretch. Après la cuisson, la case joue **les deux secondes**.

Trois réponses différentes à « quelle est la durée de ce clip » coexistent dans le même objet : `soundBars` interroge `SrcTempo.Length(c.path)` — le fichier entier (`CP_Session.lua:585`) ; la lecture joue le fichier entier ; le warp cuit la région.

### S5. Une case invisible qui joue — vérifié

`sceneLaunch` (`CP_Session.lua:883-894`) et `stopAll` (`:896-898`) bouclent sur `t = 0, TRACKS - 1`, c'est-à-dire sur **tous les slots**, y compris ceux qui ne sont pas dessinés parce que `ColumnCount()` les exclut (`:2379`, `:2393`). Après S1 (un slot libéré mais pas encore réattribué), lancer une scène met la lane de ce slot en mode 3 avec le clip de l'ancienne colonne. `bindPort` l'a liée à rien (`Loop.lua:170-173`), donc c'est silencieux — mais le mode 3 est persisté par `Loop.Serialize` (`:1119`), il fait tourner l'horloge libre (`cp_lanes.cpp:625-633`, `sbusy`) et il n'apparaît nulle part.

### S6. Cliquer une case audio pour la regarder arme une voix qui ne sera jamais désarmée — vérifié

`editCell` (`CP_Session.lua:907-932`) ne distingue pas audio et MIDI. Pour une case audio non tenue par une lane : `armLane(twinLane(t), …)` → `Cells.Arm` charge le fichier dans les voix du jumeau, `Loop.ApplyClip` pose le clip d'une note, `SetMode(lane, 2)`. Puis l'Editor reçoit un `kind="audio"` et fait `setFile` (`CP_Editor.lua:766` → `:626-629`), qui met `state.clip_lane = nil` : plus rien ne pointe vers la lane armée.

Répéter le geste sur trois cases audio de la même colonne : chaque fois, `twinLane(t)` est **la même** demi-lane, donc chaque clic décharge le fichier précédent et charge le nouveau (`Cells.lua:245-251`). Le jumeau finit armé avec le dernier fichier regardé, tagué avec la dernière case regardée. Un lancement ultérieur de n'importe quelle autre case dans cette colonne passe par ce même jumeau et efface tout ça — ce qui sauve la situation par hasard, pas par conception.

### S7. Le Sampler et la Session s'arment mutuellement dessus — vérifié (conséquence sonore supposée)

Deux notions d'« armement » écrivent `I_RECARM` sur deux pistes différentes, chacune exclusive **dans son module seulement** :
- `Loop.SetArmedLane` → `setMonitor(dest, true)` : `I_RECARM = 1`, `I_RECMON = 1` sur la piste de la colonne (`Loop.lua:606-617`).
- `Kit.SetListen` → `I_RECARM` sur le bus du kit (`Kit.lua:1621`, `:1642-1653`).

`Kit.StuffNote` diffuse sur la file du clavier virtuel (`Kit.lua:1572-1573`), qui atteint **toutes** les pistes armées et monitorées. Armer une colonne dans la Session puis cliquer un pad dans le Sampler envoie donc la note au kit *et* à l'instrument de la colonne. `pollCapture` l'ignore à l'enregistrement (canal 16, `Loop.lua:969`) — donc elle ne pollue pas la prise, mais elle sonne. C'est le miroir exact du défaut B11 du dossier : les noms viennent d'un endroit, le son part vers un autre.

Second effet, vérifié : `setMonitor(tr, false)` remet `I_RECARM = 0` **sans mémoriser l'état antérieur**. Une piste que l'utilisateur avait armée pour son propre enregistrement est désarmée par le simple fait d'armer puis désarmer une colonne dans la Session. Aucun bloc d'annulation.

### S8. Deux colonnes sur une piste, deux pistes « smp » — vérifié

`syncColumns` déclare explicitement supporter deux colonnes pointées sur la même piste (`Loop.lua:260-262`). Si cette piste porte un instrument, `audioDest(0)` et `audioDest(1)` appellent chacun `soundChild(t, true)` (`CP_Session.lua:736-741`), dont la clé de mémorisation est `CP_Session/smp<t>` — **indexée par slot, pas par piste** (`:724`, `:682`). Résultat : deux pistes enfants nommées identiquement sous la même piste.

Pire, la même clé par slot rejoue S1 : après une réattribution de slot, `samplerGuid(t)` rend l'enfant de l'**ancienne** piste. Si cet enfant existe encore (supprimer un parent-dossier dans REAPER ne supprime pas ses enfants — **supposé**, comportement REAPER non vérifié ici), le son de la colonne est versé dans une piste qui n'est plus sous la colonne : il contourne le fader, les FX et le VU de la bande de mixage qui prétend le contrôler. Et cette piste orpheline, redevenue de premier niveau et **non marquée** — `soundChild` n'appelle jamais `Tracks.Mark` (`:703-726`) — devient éligible comme colonne (`Loop.lua:221-229`).

---

## 4. CE QUI EST IMPOSSIBLE À EXPRIMER

Classé par ce que l'absence coûte, pas par difficulté.

**1. Une scène.** Il n'y a pas d'objet scène : `SCENES = 8` est une constante (`CP_Session.lua:72`), et une scène est un index dans `cells[t][s]`. Donc pas de nom, pas de couleur, pas de tempo, pas d'insertion, pas de réordonnancement, pas de nombre variable. Et l'insertion est structurellement bloquée, pas seulement absente : l'adresse d'un clip est la chaîne `clip.cell = "t,s"` (`Clip.lua:147-148`), qui est aussi ce que `applyEdit` (`:939`) et `Ident.CellOf` (`Ident.lua:157`) utilisent pour livrer les éditions. Insérer une scène demanderait de réécrire l'adresse de tous les clips en dessous, y compris ceux qui sont ouverts dans l'Editor avec l'ancienne adresse en vol.

**2. Un clip qui ne boucle pas.** `Clip.lmode = "oneshot"|"loop"` existe et est même le **défaut** de `Clip.new` (`Clip.lua:38`), mais aucun lecteur : le moteur boucle, point. Un one-shot audio est simulé en faisant boucler la matière *dans la voix* sur une passe d'une mesure (`Cells.lua:334-336`, `soundBars` rend 1, `CP_Session.lua:599`) — c'est-à-dire l'inverse d'un one-shot.

**3. Une quantisation de lancement par clip.** `Clip.q` existe (`Clip.lua:141`), personne ne le lit. Le moteur n'a qu'un `launch_q_` global (`cp_lanes.cpp:37`). Ableton en a quatorze valeurs plus une surcharge par clip (référence §2.1, vérifié).

**4. Une signature rythmique de clip.** Voir §2.1 — c'est le trou qui fait bouger la longueur des boucles sous les notes.

**5. Une case qui n'arrête pas sa colonne à un lancement de scène.** `sceneLaunch` arrête inconditionnellement (`:891`). Le document de référence Ableton corrige explicitement le dossier sur ce point : le mécanisme réel est un **bouton stop posé dans la case et retirable** (référence §0-a, vérifié) — et son absence est ce qui laisse une nappe traverser plusieurs sections. Ici c'est inexprimable, et le texte d'aide (`CP_Session.lua:124`) revendique la sémantique Ableton en la décrivant à l'envers.

**6. Un enregistrement audio dans une case.** `recCell` ne parle qu'aux lanes MIDI (`:1000-1018`).

**7. Une région, un gain, une transposition sur une case audio.** Les champs voyagent, `Cells` les ignore (§2.6, S4).

**8. Deux choses qui sonnent ensemble sur une colonne.** C'est le prix assumé du modèle Ableton et il ne faut pas le rouvrir — mais la conséquence à nommer est que **le pad du Sampler est le seul objet de la suite qui puisse se superposer**, et qu'il n'est pas lançable depuis la grille. La suite a donc deux modèles de déclenchement dont un seul est dans la Session.

**9. Un canal MIDI, une mute, une probabilité par note.** `LaneNote` a `pad[2]` libres (`cp_lanes.h:114-120`) et `Roll` quatre tableaux (`Roll.lua:38-41`) — c'est un plafond de format, pas un oubli. `Roll.lua:77` insère d'ailleurs toujours sur le canal 0, en dur, ce qui casse un take dont les notes sont sur un autre canal.

**10. Une longueur de boucle fractionnaire, de bout en bout.** `cellBars` accepte les fractions et le justifie (`CP_Session.lua:621-628`), `Loop.Serialize` les préserve (`%.6g`, `:1103`), le moteur descend à 0.125 (`cp_lanes.cpp:136`) — mais le combo de l'Editor force `1..32` entiers (`CP_Editor.lua:458`) et le bouton du Looper cycle `{1,2,4,8}` (`CP_Looper.lua:71`). Le seul endroit qui peut produire une demi-mesure est la détection automatique ; toute intervention humaine la détruit.

---

## 5. LE RAPPORT À REAPER

### 5.1 Là où la suite se bat contre son hôte

**(a) Le corpus de clips est invisible à REAPER.** Les notes vivent dans une table Lua, un tampon C++ et une chaîne de `ProjExtState`. Aucun item, aucun take. Conséquence en chaîne, vérifiée : pas de rendu, pas de gel, pas de bounce, pas de copier-coller vers l'arrangement, pas d'éditeur MIDI natif (`CP_Editor.lua:2462` le conditionne à `state.item`, avec le commentaire exact), pas d'undo. Ableton résout ça par l'autre bout : l'enregistrement d'arrangement est un **journal de références de clips**, pas un rendu (référence §5, verbatim vérifié) — la performance reste ré-éditable clip par clip parce qu'elle est faite des mêmes objets que la timeline. Ici la Session et l'arrangement ne partagent aucun objet. Le seul pont est `exportLaneToItem` dans le Looper, et il est à sens unique.

**(b) L'undo.** Vider une case, coller, renommer, colorer, changer le mode tempo, déposer un fichier : tous écrivent par `saveGrid` → `SetProjExtState` sans `Undo_BeginBlock` (`CP_Session.lua:480-491`). Et `soundChild` **modifie la structure de dossiers du projet de l'utilisateur** — `SetMediaTrackInfo_Value(dest, "I_FOLDERDEPTH", 1)` (`:718-719`) — sans bloc d'annulation non plus. C'est le seul endroit de la suite qui réarrange la hiérarchie de pistes, et c'est celui qui n'est pas annulable.

**(c) Deux transports.** Le mode Free (`Loop.SetFreeRun`) fait tourner une horloge que REAPER ne voit pas, dont le beat zéro est « le moment où le dernier clip s'est arrêté » (`cp_lanes.cpp:633`, `free_beat_ = sbusy ? … : 0.0`). Ce n'est pas un défaut — c'est nécessaire — mais il n'existe **aucun objet dans le modèle** qui dise à quelle horloge un clip appartient : c'est un réglage global, et `Cells.beatToFrame` doit brancher sur deux arithmétiques différentes selon sa valeur (`Cells.lua:283-294`).

**(d) `GetProjectStateChangeCount` comme clé de cache universelle.** `trackName` (`:309`), `Mix.chainOf`/`sendsOf`, `Loop.KitViewOfTrack` (`:393`), `pollTarget` de l'Editor. Le compteur bouge à chaque écriture de paramètre — donc pendant les gestes eux-mêmes. Le dossier le note en performance ; le point de modèle est ailleurs : **la suite n'a pas de notion de « ce fait a changé », elle a une notion de « quelque chose a changé dans le projet »**, et elle l'utilise pour tout.

### 5.2 Là où elle s'appuie sur REAPER et ne devrait pas

**(a) La métrique.** `Loop.TsNum()` lit la signature à la tête de lecture pour en déduire la longueur de toutes les lanes (§2.1) et la valeur de « Q: Bar » (§3-S3). Deux faits musicaux qui appartiennent à la session sont dérivés d'une propriété locale de la timeline de l'hôte.

**(b) L'armement.** `Loop.SetArmedLane` écrase `I_RECARM`/`I_RECMON` sur une piste de l'utilisateur (S7) alors que la capture, elle, n'en dépend pas du tout — `MIDI_GetRecentInputEvent` lit l'historique global et le commentaire le dit (`Loop.lua:600-602`). L'armement n'est plus qu'un choix de monitoring, mais il est implémenté en modifiant l'état de la piste, donc il est destructeur et non annulable, pour un besoin purement local.

**(c) L'adoption automatique de colonnes.** « Une colonne est une piste » est une bonne décision, mais elle est réalisée en faisant de l'**ordre des pistes du projet** l'attributeur de slots (`syncColumns`, `Loop.lua:242-257`). Un geste que l'utilisateur fait pour son arrangement (ajouter, supprimer, sortir une piste d'un dossier) réattribue des slots qui possèdent des clips. C'est S1.

**(d) La couleur.** Une palette d'index privée (`Clip.COLORS`) alors que REAPER a `I_CUSTOMCOLOR` sur les pistes et sur les items, et qu'Ableton fait hériter la couleur de la piste (référence §1, vérifié). Le raisonnement de `Clip.lua:43-55` est bon pour la sérialisation, mais il produit un identifiant visuel qu'un seul écran affiche.

### 5.3 Là où elle s'appuie sur REAPER, correctement

À dire, parce que ça calibre le reste : le mixage (`Mix.lua` n'a aucun état propre, tout est lu et écrit dans REAPER), le solo (celui de REAPER, arrangement compris), le routage (par GUID dans `ProjExtState`), le monitoring d'entrée (rendu à REAPER avec le retrait du routeur), la carte de tempo pour la conversion beat→position (`CP_ClockPos` + `TimeMap2_timeToQN`, `Loop.lua:1025-1028`). Ce sont les endroits où la suite est le plus solide, et ce n'est pas un hasard : ce sont ceux où **elle n'a pas de deuxième copie de la vérité**.

---

## CE QUE JE TRANCHERAIS, ET DANS QUEL ORDRE

Trois décisions, pas dix correctifs. Chacune ferme une famille entière de scénarios ci-dessus.

**1. Le slot doit mourir avec sa piste, ou posséder sa piste.** Aujourd'hui le slot possède les clips et la piste est interchangeable dessous. Deux réponses cohérentes : soit un slot libéré vide ses cases (les clips suivent la piste), soit un slot mémorise son GUID pour toujours et n'est jamais réattribué automatiquement. La troisième — l'actuelle — est la seule qui produise S1 et S8.

**2. La longueur d'un clip doit être en beats, ou porter sa propre signature.** `bars × ts_num(position de lecture)` est indéfendable : c'est le seul endroit du modèle où une propriété d'un objet est recalculée depuis un contexte étranger, à chaque bloc audio. Le champ existe déjà côté sérialisation (`%.6g` accepte les fractions) ; il manque une décision, pas du code.

**3. Le tag de lane doit être sérialisé, et `LaneOfTag` doit refuser le tag 0.** Le dossier le dit déjà pour la persistance (B1) ; j'ajoute la moitié manquante — tant que le tag n'est pas remis à zéro à l'ouverture d'un projet, l'identité est un nombre partagé entre des projets qui ne se connaissent pas (§2.3). Un préfixe de session, ou un `CP_LanesResetTags()` au premier attachement, coûte une ligne et supprime une classe entière de « ma case joue les notes d'un autre projet ».

Le reste — `src_bpm` sans écrivain, `q`/`lmode`/`gain` sans lecteur, la mute que la Session ne voit pas, `offs`/`len` que seul le warp respecte — sont des symptômes de la même chose : **le format CPC1 décrit un modèle plus riche que celui que le moteur et les fenêtres implémentent**, et rien ne dit lequel des deux fait foi. C'est ça, le trou principal dans la logique : il n'y a pas de document, ni de code, qui dise « un clip, c'est exactement ceci » — il y a un sérialiseur qui accepte tout et trois consommateurs qui en prennent chacun un tiers.