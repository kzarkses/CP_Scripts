# Roadmap — les chantiers, dans l'ordre

Écrite le 2026-08-01, après le premier vrai test d'écoute de la suite complète
et la confrontation aux références du genre.

**Trois documents, trois rôles.** `ROADMAP_Autonomie.md` est le JOURNAL — ce
qui a été fait, session par session, et pourquoi. `ANALYSE_Confrontation.md`
est le RAISONNEMENT — où on en est face à Ableton et FL, ce qu'on copie et ce
qu'on refuse. **Celui-ci est le PLAN** : ce qu'on fait ensuite, dans quel
ordre, et à quoi on saura que c'est fini. `Recherche/` tient la matière brute.

Une case cochée ici veut dire *écrit et compilé*, jamais *entendu* — c'est
Cédric qui écoute.

---

## Où on en est (2026-08-01)

Le moteur natif est complet et l'autonomie est atteinte : plus aucune piste
d'infrastructure créée dans un projet, plus de JSFX de lanes, plus de gmem.
**ABI 1.7.** 141 assertions au harnais, zéro allocation dans le fil audio.

Le premier test d'écoute a rendu huit défauts, tous corrigés le jour même :
l'ancre d'horloge qui appariait deux instants différents (28 ms de retard
constant), la vitesse de lecture ignorée du moteur, la longueur d'une case
audio jamais lue dans le fichier, l'attaque mangée par le rattrapage de phase,
deux fondus qui n'existaient que sur le papier, la note fantôme envoyée à
l'instrument de la colonne, le stop du transport qui n'était pas maître, et la
porte de 97 % qui tranchait la queue de chaque passe.

**Le constat qui commande cette roadmap** : sur la vingtaine de défauts
restants, trois seulement touchent le C++. Le reste est du câblage absent — des
champs qui voyagent dans le format et que personne ne relit, des fonctions
écrites et jamais appelées, des réponses calculées et jamais montrées. *La
suite en sait beaucoup plus qu'elle n'en dit.*

---

## Chantier 1 — La propriété de l'entrée MIDI

**Le seul qui bloque un usage entier.** Et il ne décide pas de la question
RS5K : la réponse est la même dans les deux scénarios, donc rien n'est perdu.

### Le défaut

`Kit.EnsureBus` pose sur le bus du kit `I_RECINPUT = 4096 + (63 << 5)` — MIDI,
**toutes** entrées, **tous** canaux — avec `I_RECARM = 1` et `I_RECMON = 1`. Et
`Kit.HoldArm()` réaffirme cet état chaque fois que REAPER le remet à zéro,
c'est-à-dire à chaque changement de sélection de piste.

Le kit ne « ne réagit pas » aux pistes armées de REAPER : **il est en
compétition avec elles et il gagne, parce qu'il se réarme tout seul.**
`enforceSingleListener` désarme les autres *kits*, jamais tes pistes. Et un clic
de pad passe par `StuffMIDIMessage`, que le fichier qualifie lui-même de
*broadcast* : il atteint toute piste armée en monitoring.

### Le modèle visé

Le sampler pointe **une** piste. Le son sort par cette piste. C'est l'armement
de **cette** piste — dans REAPER, dans le mixer, ou dans CP_Sampler, c'est le
même bit — qui décide si tu la joues. Rien d'autre n'est touché.

### Étapes — **FAIT** (écrit et compilé, ABI 1.8)

- [x] **Ne plus forcer, lire.** `Kit.HoldArm` et `Kit.arm_intent` n'existent
      plus. `Kit.Armed()` lit l'état de la piste ciblée ; `Kit.SetArmed` écrit
      une fois, sur demande, et ne désarme plus l'autre instrument — une piste
      que l'utilisateur a armée lui-même est à lui.
- [x] **Rendre l'entrée normale.** Le bus naît comme n'importe quelle piste
      d'instrument : ni armé, ni monitoré, avec l'entrée que REAPER lui donne.
      « Écoute toutes les entrées MIDI » devient un geste nommé
      (`Kit.SetInputAll`, dans le menu), plus un état imposé. Idem pour la
      piste de l'instrument chromatique et pour la migration `SplitInstrument`.
- [x] **Les clics de pad cessent d'être un broadcast.** Nouvelle fonction
      d'ABI `CP_PortMidiAt(port, at, status, d1, d2)` : un message MIDI brut
      dans la piste d'un port, et nulle part ailleurs. `CP_Engine/Notes.lua`
      tient la cible et les notes non relâchées ; `Voice` expose la capacité
      (`CanSendMidi`) et la carte des ports réserve **24** au sampler, **25**
      à l'éditeur. **Tranché en écrivant : oui, le clic traverse la chaîne
      d'effets du pad** — le port est versé dans la piste du kit, donc le choke
      JSFX puis les RS5K. « Fais-moi entendre ce pad » ne peut pas vouloir dire
      autre chose que « ce que ce pad sonne ».
- [x] **`enforceSingleListener` disparaît.** Il désarmait le bus de tous les
      autres kits, en boucle, uniquement parce qu'un clic était un broadcast.
      Ce qui reste de l'idée est `Kit.active_guid` : un seul kit est la cible du
      sampler, et c'est une propriété de la fenêtre qui ne touche à l'état
      d'aucune piste. `Kit.Repair` ne désarme plus rien non plus.
- [x] **La même règle vaut pour la Session.** `Loop.SetArmedLane` reste, mais
      elle est désormais réservée au geste : les deux chemins de restitution
      (chargement de projet, relecture du blob) passent par
      `Loop.AdoptArmedLane`, qui **se souvient sans écrire**. Ouvrir un projet
      n'arme plus aucune piste.
- [x] **L'éditeur aussi.** CP_Editor auditionnait ses notes par le bus du kit
      de CP_Sampler — donc il fallait un kit pour s'entendre, et la note
      partait en broadcast. Il joue maintenant dans **la piste que ce clip
      alimente** : la piste de l'item pour une prise, la destination de la
      colonne pour une case. Sans destination, rien ne sonne — un silence
      explicable vaut mieux qu'un son dont personne ne sait d'où il sort.

### À quoi on saura que c'est fini

Armer une piste dans REAPER et jouer : seul cet instrument sonne. Ouvrir
CP_Sampler ne change rien tant qu'on ne lui demande rien. Cliquer un pad fait
sonner ce pad, et rien d'autre dans le projet.

**Le seul point sur lequel ce chantier s'appuie sans l'avoir mesuré** : le MIDI
d'un aperçu de piste franchit-il les **envois** de cette piste ? Il traverse la
chaîne d'effets, c'est acquis depuis l'ABI 1.6 (les lanes en vivent). Le saut
supplémentaire vers les pads est le seul inconnu, et le chantier 2 le supprime
en remontant les RS5K dans la chaîne du bus. Si un clic de pad reste muet, ce
n'est pas la peine de chercher ailleurs — c'est ça, et la réponse est le
chantier suivant.

---

## Chantier 2 — Un kit, une piste

### Le défaut

Un kit = un dossier « CP Kit » + **une piste enfant par pad**. Soixante-quatre
pads, c'est jusqu'à soixante-cinq pistes dans le projet de l'utilisateur.

### Ce que la recherche a tranché

**Personne ne modélise « un kit » et « un instrument » comme deux objets
différents.** Chez Ableton, un Drum Rack et un Simpler sont deux *devices* sur
une piste, et un pad de Drum Rack est une chaîne qui contient un Simpler : le
même objet à deux granularités. Chez FL, un channel sampler est chromatique par
défaut et le Channel Rack n'est que la liste des channels — l'objet « kit »
n'existe pas. Chez Battery ou Kontakt, une instance = un kit, sorties séparées
optionnelles.

Chez nous, `Kit.mode` bascule entre un kit et un instrument chromatique qui vit
sur **sa propre piste** (`CP_KIT_INSTR`), et c'est incohérent en interne : un
projet peut contenir **N kits** mais **exactement un** instrument
(`scanInstrument` prend le premier et sort), et le réglage global qui arbitre
les deux est stocké **sur la piste du kit actif**.

### La trouvaille qui rend le chantier léger

Le fan-out d'envois MIDI filtrés vers les pads n'existe **que** parce que les
pads sont des pistes séparées. Dans **une seule chaîne d'effets**, tous les
RS5K voient le même MIDI et chacun répond à sa propre plage de notes — c'est le
RS5K lui-même qui filtre. Passer à une piste unique **supprime** de la
machinerie au lieu d'en ajouter. Ce n'est pas un compromis.

### Étapes

- [x] **Les RS5K montent dans la chaîne de la piste du kit**, un par pad, et le
      fan-out d'envois disparaît avec les pistes enfants. L'identité d'un pad
      est désormais **sa plage de notes** (`lo == hi`) : la seule qui ne puisse
      pas mentir, puisque c'est elle qui décide sur quelle touche il sonne.
- [x] **Un conteneur d'effets par pad qui en veut un** (REAPER 7), créé **à la
      demande** — « Give this pad its own FX chain » dans le menu du pad, et
      automatiquement quand on lui demande un ReaPitch (qui, posé à plat,
      transposerait tous les pads suivants). Un pad en conteneur porte un index
      encodé, et il se lit et s'écrit comme les autres : le reste du module ne
      sait pas lequel des deux il tient.
- [x] **Plus de dossier CP.** Le kit naît en piste ordinaire, marquée
      `P_EXT:CP` comme le veut la règle de découverte, et `DropFolderIfEmpty`
      retire le dossier quand le repli l'a vidé. L'instrument chromatique aussi.
- [x] **Le JSFX de choke reste**, premier de la chaîne, caché — et `ensureChoke`
      le **remonte** en tête s'il traîne ailleurs : placé après un RS5K, il
      couperait des notes que celui-ci a déjà jouées.
- [x] **Migration** — `Kit.Fold`, une fois par session, au premier poll. Une
      règle la commande : *on ne supprime jamais une piste dont le contenu n'a
      pas été déplacé avec succès.* Chaque pad **déménage**
      (`TrackFX_CopyToTrack` en mode move) — à plat quand il n'avait que son
      RS5K, dans un conteneur quand il avait des effets à lui, ce qui les
      préserve exactement. L'identité de tempo est relue avant que la piste ne
      parte et reposée sur le kit. Jamais les deux formes en même temps : c'est
      un déplacement, pas une copie, donc jamais le même pad joué deux fois.
- [ ] **L'instrument chromatique devient un pad** dont la plage de notes couvre
      le clavier. `CP_KIT_INSTR`, `Kit.mode` et le singleton disparaissent.
      **Pas fait** : c'est une refonte de l'interface de CP_Sampler (le mode
      instrument est un écran entier), pas du routage, et rien n'en dépend.
- [ ] **« Éclater ce pad vers une piste »** devient un geste explicite (un
      envoi depuis le conteneur), à la demande — jamais par défaut. **Pas
      fait** : c'est un ajout, pas une suppression, et c'est la réponse au seul
      manque assumé ci-dessous.

### Ce qu'on perd, et qui est assumé

Le fader, le mute/solo et le VU **par pad** dans le mixer de REAPER. Les effets
par pad, non — les conteneurs les gardent. Pour le pad qui a vraiment besoin de
sa tranche, l'éclatement explicite est la réponse.

Conséquence visible tout de suite : la **lueur d'un pad** n'est plus un VU.
REAPER mesure une piste, pas un effet. Elle est maintenant le niveau du kit
attribué au pad dont on *sait* qu'il vient d'être frappé — un retour de geste,
pas une mesure, et elle ne prétend rien sur les pads déclenchés par un item ou
une lane. Un kit pas encore replié garde son vrai VU, puisqu'il a encore ses
pistes.

---

## Chantier 3 — Dire ce que la suite sait déjà

Petit, et c'est celui qui rend la confiance. « Je ne suis jamais sûr que le
sample soit bien tempo-matché » est un problème d'affichage, pas de moteur.

- [x] **Le tempo retenu ET SA RAISON.** La ligne sous une case audio dit
      maintenant `128 BPM · name` — et `· read` (REAPER a lu le fichier, tempo
      embarqué compris), `· set` (décidé), `· guess` (déduit de la seule durée),
      ou **`no tempo found`**, qui est l'information qui manquait le plus :
      elle dit que le fichier joue tel quel. Calculé **une fois**, là où
      `soundBars` l'est déjà, et mémoïsé par case — cette ligne part dans une
      boucle de dessin.
- [x] **Le tempo déclaré, enfin éditable.** « Source tempo… » dans le menu
      Tempo. Il bat toutes les autres sources, et la longueur de passe est
      recalculée avec lui — puisqu'elle en dépend.
- [x] **La barre de progression suit le SON.** `Cells.Progress(t)` lit la
      position que la voix publie et la rend en fraction de la matière ; la
      phase de la lane reste la réponse pour une case MIDI, et le repli quand
      rien ne sonne. Un one-shot ne voit plus sa barre continuer d'avancer
      pendant qu'il se tait.
- [x] **« Stretch » cesse de mentir.** Les trois correctifs : `Warp.Version()`
      change à chaque fin de cuisson (réussie **ou** échouée) et `frame()`
      réarme les cases concernées — une case étirée ne reste plus un repitch
      jusqu'au prochain lancement manuel ; `Warp.Retry` a enfin un appelant, à
      côté de `Warp.Failure` qui dit **pourquoi** ça a échoué ; et le libellé
      est réécrit — « keeps the key, repitches until it is rendered ».
- [x] **Le texte d'aide de CP_Session** ne décrit plus de câblage supprimé.
      « Unroute », la piste SAMPLER par colonne et le routeur à canaux filtrés
      sont remplacés par ce qui est vrai : une colonne est une piste du projet,
      le moteur y verse le son directement, et l'armement est celui de REAPER.

---

## Chantier 4 — La grille devient un instrument

À faire après le 3, pas avant : ajouter des fonctions à une fenêtre dont on ne
comprend pas encore ce qu'elle joue est le meilleur moyen de perdre les deux.

### 4a — La région et le gain d'une case audio

`Cells.Arm` ne prend qu'un chemin et un taux. **`clip.offs`, `clip.len` et
`clip.gain` n'ont aucun consommateur** : une sélection de deux mesures glissée
depuis CP_Editor joue le fichier entier. Tout existe pourtant dessous — le
moteur porte `loop_start` / `loop_end` / `pos` / `gain` en frames source, et
`Voice.Play` les transmet déjà.

- [ ] Faire passer `offs` / `len` / `gain` jusqu'à `opts` dans `playAt`.
- [ ] `soundBars` mesure la RÉGION et non le fichier.

**Ce que ça débloque** : découper un break en huit tranches, une par case. Un
geste fondateur d'une session view, aujourd'hui strictement impossible. Et
l'aller-retour éditeur → case cesse de mentir.

### 4b — La fin de passe comme évènement

FL appelle ça *Motion*, **par piste** : `Stay`, `One shot`, `March & wrap`,
`March & stay`, `March & stop`, `Random`, `Exclusive random`. Ableton fait la
même chose **par clip** avec dix Follow Actions et deux probabilités.

**Grain colonne d'abord**, à la FL. Les Follow Actions par clip sont un panneau
par case, et il faut savoir si le grain colonne suffit avant de le construire.

- [ ] Un enum de sept comportements par colonne, dans `frame()` juste après
      `Loop.Poll()`. Tout est déjà exposé : `Loop.Phase`, `Loop.LenBeats`,
      `Loop.GetLaunchQ`, et `launchCell` sait déjà échanger sur une frontière.
- [ ] Le compteur de tours joués tombe gratuitement du même poll (une détection
      de repli de phase). Ableton l'affiche dans le Track Status field.

**Trois réserves à écrire dans le code** : la règle « tirer dans la dernière
fenêtre de Q » ne tombe sur la fin de boucle que si la longueur de lane est un
multiple de Q ; à Q: Beat et 160 BPM la fenêtre vaut onze frames de defer, ce
qui est le plancher ; et **l'enchaînement s'arrête si la fenêtre se ferme**,
parce que c'est du Lua — Ableton et FL n'ont pas ce problème.

### 4c — Les petits gestes

- [ ] **`+Scene`** — superposer au lieu de remplacer. FL, verbatim : *« will
      replace playing Clips with any new Clips on the same track in the next
      Scene but leave any Clips on unused tracks playing »*. Aujourd'hui
      `sceneLaunch` arrête toute colonne sans clip, donc **une nappe ne peut pas
      survivre à un changement de scène** : il faut la dupliquer dans les huit
      lignes. Cinq lignes, zéro stockage.
- [ ] **Une sélection et un clavier.** Ableton : flèches, Page Up/Down = huit
      scènes, Entrée = lancer — on descend un set entier en tapant Entrée.
      CP_Session n'a **aucune gestion clavier** ; l'infrastructure existe et est
      éprouvée dans CP_Editor. ~60 lignes.
- [ ] **Capture and Insert Scene** (Ableton, Ctrl+Shift+I) : copier ce qui joue
      dans une nouvelle scène *« with no audible interruption »*. Ici c'est
      exact **par construction** : le tag de lane est de la métadonnée pure, donc
      recopier les descripteurs puis reposer les tags allume la nouvelle ligne
      sans redéclencher une note.

---

## Les corrections d'une ligne

Elles ne sont pas des chantiers et changent l'usage quotidien.

- [ ] **La fenêtre de tolérance de lancement.** Le moteur a déjà la bonne
      sémantique — un clic dans les 0,05 beat *après* une frontière part
      immédiatement, exactement comme le *tolerant trigger sync* de FL. Mais
      0,05 beat = **25 ms** à 120 BPM, et une main humaine est en retard de 40 à
      120 ms. Passer à une fraction de Q (1/8 = 250 ms à Q: Bar) : une ligne de
      C++ et une recompilation. **Meilleur rapport effet/effort du document.**
- [ ] **Huit colonnes.** `Loop.MAX_LANES = 16`. Le calcul de ports que personne
      n'avait fait : audio prend le port `t`, le MIDI `PORT_BASE + lane`,
      l'audition le 31 — donc huit colonnes tiennent **sans rien d'autre**
      (audio 0-7, MIDI 8-23). À douze, le MIDI atteint 31 et percute l'audition.
      ⚠️ Le pas de la paire déplace les lanes jumelles : il faut la remontée de
      format v5 → v6 (`dest<lane>`, la lane armée persistée, le blob ordonné par
      lane) **dans le même changement**, sinon les projets existants rechargent
      leurs boucles dans des lanes vides, en silence.

---

## Le registre des défauts

Détail et citations `fichier:ligne` dans `Recherche/DEFAUTS_Balayage.md` et
`Recherche/DEFAUTS_Trous_de_logique.md`. Les adresses y datent du 1er août au
matin ; le fond tient.

### Perte de données ou mauvais son

- [ ] **`Loop.SaveState` n'a aucun garde `NATIVE`.** Sans l'extension, la
      sérialisation produit huit lanes vides et les écrit par-dessus l'état du
      projet, à la fermeture de la fenêtre. `Deserialize`, lui, refuse quand
      `not NATIVE` : la lecture est protégée, l'écriture non. **Trois lignes.**
- [ ] **Aucune annulation sur l'édition de notes d'une case.** Le contrat de
      `Roll` prévoit `be.undo` et l'appelle à chaque geste structurel ; le
      backend take le branche sur `Undo_OnStateChange`, le backend **clip** le
      branche sur `scheduleApply()` — c'est-à-dire rien. Un Quantize, un
      Euclidean ou une suppression dans une case sont **définitifs**. Et
      Ctrl+Z est explicitement réservé au mode take.
- [ ] **Alt+clic efface une case sans confirmation ni annulation.**
- [ ] **Le tag de lane n'est pas sérialisé.** Après réouverture du projet, la
      grille et le moteur ne parlent plus du même clip : les lanes jouent, la
      grille montre tout arrêté, aucune case audio n'est réarmée. Un champ de
      plus dans le format, plus la persistance de `cur`.
- [ ] **Une lane du Looper ouverte dans l'éditeur n'a aucune identité.**
      `Loop.LaneToClip` construit un descripteur sans `id` ni `cell` ; côté
      éditeur `Ident.TagOf` rend 0, et `Loop.LaneOfTag(t, 0)` — dont le
      commentaire promet « nil quand le moteur ne tient plus ce clip » — rend
      **la moitié vivante**. L'édition peut atterrir dans la jumelle,
      par-dessus les notes de l'autre clip. Correction : `Ident.Of` dans
      `LaneToClip`, et `LaneOfTag(t, 0)` doit rendre `nil`.
- [ ] **Un slot libéré est réattribué avec ses clips.** Supprimer la piste de la
      colonne 1 libère le slot ; la piste suivante l'adopte et arrive avec les
      huit clips de l'ancienne. Le mécanisme d'adoption a été écrit pour que les
      clips restent au slot ; il n'a pas prévu qu'un slot libéré change de
      piste.
- [ ] **Changement de projet, fenêtre ouverte.** `Loop.RouterChanged()` rend
      `false` inconditionnellement, sur la prémisse « une instance par script,
      par projet » — fausse, puisqu'un `defer` survit à un changement d'onglet.
      La grille du projet A peut s'écrire dans le projet B. **Demande une
      décision** : détecter le changement, ou assumer que ces fenêtres sont
      liées à un projet.
- [ ] **Collisions d'identité entre projets.** `Ident` assume la collision et la
      déclare inoffensive parce que `Ident.Get` filtre — mais `Loop.LaneOfTag`
      compare des nombres bruts sans passer par le registre. Deux projets dans
      la même instance de REAPER suffisent.
- [ ] **Changer le mode tempo d'un son en cours décharge la matière sous la
      voix** : `clipUnref` → `CP_ClipUnload` → `Pool::retire`, et la voix
      obtient `nullptr` et meurt sans fondu. Le garde-fou du pool est du code
      mort — `Clip::refs` n'est incrémenté nulle part.
- [ ] **Une lane mutée dans le Looper coupe son MIDI mais pas sa case audio.**
- [ ] **Fuite de `PCM_source` dans `SrcTempo.FromAnalysis`** — le second retour
      de `getSource` (« owned ») est ignoré, donc rien n'est détruit. Invisible
      dans CP_Session, qui injecte un cache ; réel dans `Kit.lua`, qui n'en
      injecte pas.

### Ce qui trompe

- [ ] **Sept champs morts voyagent dans chaque `.RPP`** : `gain`, `pitch`,
      `rate`, `root`, `q`, `src_bpm` (et `lmode`, câblé le 1er août). Ils
      **promettent un modèle** que rien n'implémente : on lit le format et on
      croit que la fonctionnalité existe.
- [ ] **La longueur d'une boucle n'appartient à personne.** Elle vaut
      `bars × ts_num`, où `ts_num` est la signature rythmique **à l'endroit où
      la tête de lecture se trouve en ce moment**. Une mesure en 3/4 quelque
      part change la longueur de toutes les lanes quand le transport la
      traverse, alors que les notes sont en beats absolus. Il n'existe nulle
      part de signature **du clip** ; Ableton en a une.
- [ ] **Q et le mode d'horloge ne survivent qu'à une fermeture propre** :
      `setQIndex` et la bascule Clock n'appellent pas `Loop.MarkDirty()`, et
      `AutoSave` ne surveille que la version de notes et le mode par lane.
      CP_Looper, lui, appelle `MarkDirty` sur les deux — deux fenêtres, deux
      comportements pour le même réglage.
- [ ] **`Mix.SendCreate` annonce « Send → X » sur un envoi déjà existant.**
- [ ] **`Cells.LastOnsetError`** — l'écart mesuré entre la passe demandée et la
      passe réellement jouée, construit exprès et **jamais appelé**. C'est
      l'instrument qui aurait montré les 28 ms sans qu'on ait à les chercher.

### Performance (la cible est un PC de 2005, et le dépôt l'écrit partout)

- [ ] **`Mix.guidOf` alloue une chaîne par appel**, et `chainOf`/`sendsOf`
      l'appellent chaque fois : ~14 allocations par colonne et par frame.
- [ ] **Le cache du mixer est clé sur `GetProjectStateChangeCount`**, que les
      écritures de fader incrémentent — donc il se reconstruit intégralement
      pendant le geste qu'il devait rendre fluide.
- [ ] **`audioSub` fait un `io.open` par frame et par case en stretch**
      (`Warp.State` → `PathFor` → `fileExists`). Un accès disque dans une
      boucle de dessin.
- [ ] **Collision de clé dans le cache de troncature** : `cellLabel(t, SCENES,…)`
      et la case `(t+1, scène 0)` calculent le même emplacement, donc chacun
      invalide l'autre à chaque frame.
- [ ] **`pollCapture` fait un `CP_LaneGet` par événement et par lane** pendant
      une prise — jusqu'à 1024 appels d'ABI pour 128 événements, alors que la
      liste des lanes en capture est déjà connue.
- [ ] **~2 à 7 appels d'ABI par case et par frame** dans `drawCell`, là où huit
      `GetLaneTag` construiraient une table tag→lane une fois par frame.

---

## Ce qu'on refuse, et pourquoi

Pour ne pas y revenir tous les trois mois.

- **L'enregistrement audio dans une case.** REAPER le fait déjà, en mieux. Ce
  qui manque à ce chemin, c'est la région (4a), pas un enregistreur.
- **Le modèle « pattern » de FL.** L'exclusivité par colonne est structurelle
  ici (une colonne possède une paire de lanes) et gratuite. Rouvrir ce choix,
  c'est jeter la meilleure propriété du modèle. Sa conséquence, elle, est
  volable : dupliquer une scène entière (4c).
- **Le tempo et la signature par scène.** Il faudrait écrire la carte de tempo
  de REAPER depuis un lancement de clip — modifier le projet pendant un jam — et
  ça n'a aucun sens en horloge libre.
- **Gate / Repeat / Toggle par clip.** Ils existent chez Ableton *pour des
  contrôleurs*. Sans mapping MIDI ils n'achètent rien, et `Toggle` est déjà le
  comportement.
- **Le mapping MIDI des cases** — pas un refus, un **préalable** : le même flux
  alimente la piste armée, donc un pad qui lance une case jouerait aussi
  l'instrument et serait enregistré dans la prise. Après le chantier 1.
- **La zone de performance dans l'arrangement (FL).** Contredit l'acquis « CP ne
  crée aucune piste d'infrastructure ».
- **Les onglets d'effets destructifs de FL** (normalize, reverse, EQ cuits dans
  l'échantillon au chargement). On a tranché l'inverse et mieux : éditions non
  destructives, `Bake` comme échappatoire explicite.
- **Slicex comme plugin séparé.** Le découpage est déjà décidé autrement, et
  mieux adapté ici puisque les slices atterrissent sur de vraies pistes.
- **L'entrée de notes au clavier QWERTY/AZERTY.** Le clavier virtuel de REAPER
  couvre le besoin.

---

## Ce qui est déjà bon, et qu'une refonte perdrait sans s'en apercevoir

À relire avant de toucher à l'interface.

- **Cliquer le contenu ouvre l'éditeur, cliquer la bande lance. Jamais
  l'inverse.** Ableton mélange les deux et a besoin d'une préférence pour
  rattraper la confusion. **Meilleur qu'Ableton.**
- **La scène tombe d'un bloc.** Le moteur draine toutes les commandes du bloc
  d'un coup : *« la moitié d'une scène partant une mesure avant l'autre n'est
  pas un quantize, c'est un bug poli »*.
- **La phase ancrée sur la timeline**, pas sur l'instant du clic.
- **Un son EST une lane** — une seule machine à états pour l'audio et le MIDI.
- **Follow / Free, et « waiting for the transport » écrit en toutes lettres.**
  Ableton n'a pas ce choix : il *est* le transport.
- **Le mixer est celui de REAPER**, pas un second à synchroniser.
- **Une colonne est une piste du projet, adoptée par GUID**, le slot stable,
  l'ordre d'affichage suivant le projet.

---

## La destination — un instrument CP en plugin

Pas la prochaine étape. La direction.

Ce qui manque au moteur pour remplacer le RS5K est **petit** : un ADSR (il n'y
a que des fondus linéaires), un vol de voix par groupe de choke (plus simple en
natif que le JSFX), les zones de vélocité. Loop, région, vol, pan et varispeed
existent déjà. L'étirement à durée constante reste hors ligne (`Warp`), et
c'est une décision chiffrée : 2,3 % du fil audio par voix et 85 à 139 ms
d'amorçage.

**Le blocage n'est pas le DSP, c'est le MIDI.** Le moteur est un `PCM_source`
joué par `PlayTrackPreview2Ex` : il **produit** du MIDI — c'est comme ça que les
lanes parlent — mais il n'en **reçoit** pas. Le jouer au clavier passerait par
Lua et `MIDI_GetRecentInputEvent` : les événements sont horodatés à
l'échantillon, mais la sonde tourne une fois par frame de defer, 16 à 74 ms.
Bon pour armer une case, inutilisable pour jouer.

La seule sortie propre est de **livrer le cœur comme plugin** (CLAP, en-têtes
MIT et sans dépendance, ou VST3). Et c'est borné plutôt que fantasmé :
`CP_Native/src/core` a été écrit depuis le début sans une seule ligne d'API
REAPER — c'est une règle du dossier, et le harnais le compile et le teste hors
REAPER.

En bonus, cette voie règle le routage : un plugin sort sur N paires stéréo, et
les conteneurs d'effets de REAPER 7 se punaisent sur une paire. Un kit = une
piste, un plugin, un conteneur par pad qui en veut un.

**Ce qui serait perdu, c'est de faire ça sans le chantier 1** : on aurait un
beau moteur avec le même MIDI incompréhensible.

---

## Les décisions qui appartiennent à Cédric

- **Le nombre de colonnes.** Huit tient sans rien changer d'autre que le format
  de session. Douze demande de bouger `PORT_BASE` et une largeur minimale de
  cellule ou un défilement horizontal.
- **Le sort du chantier 2 si le plugin arrive vite.** Replier le kit sur une
  piste avec des RS5K, puis remplacer les RS5K par le plugin, c'est deux
  migrations. Les faire d'un coup est possible — au prix d'attendre le plugin.
- **CP_Editor face à l'éditeur natif.** Sa raison d'exister est structurelle :
  il est le seul à pouvoir éditer un clip **sans item** (une lane, une case).
  La question ouverte est jusqu'où continuer à réécrire, sur un take, ce que
  REAPER fait déjà. Ma règle : sur un take, ne rien écrire que REAPER fasse
  correctement ; sur un clip sans take, tout écrire, parce qu'il n'y a personne
  d'autre.
- **Les lanes de CC.** Le plus grand trou de l'éditeur, identifié depuis
  longtemps. À faire d'abord sur CP_Editor, où le backend take écrit du vrai CC
  par l'API de REAPER sans changement de protocole. Côté clip, la note du
  moteur a **deux octets libres déjà réservés**.
