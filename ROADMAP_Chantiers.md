# Roadmap — les chantiers, dans l'ordre

Écrite le 2026-08-01, après le premier vrai test d'écoute de la suite complète
et la confrontation aux références du genre.

**Trois documents, trois rôles.** `ROADMAP_Autonomie.md` est le JOURNAL — ce
qui a été fait, session par session, et pourquoi. `ANALYSE_Confrontation.md`
est le RAISONNEMENT — où on en est face à Ableton et FL, ce qu'on copie et ce
qu'on refuse. **Celui-ci est le PLAN** : ce qu'on fait ensuite, dans quel
ordre, et à quoi on saura que c'est fini. `Recherche/` tient la matière brute.

**Un quatrième, pour une seule fenêtre.** `ROADMAP_Editeur.md` tient le plan de
CP_Editor : l'inventaire des modificateurs de souris MIDI de REAPER dans la
config de Cédric, ce que l'éditeur fait en face, la liberté de lecture « à la
Ableton », et le chantier des raccourcis configurables. Il se pioche ; il n'a
pas de priorité sur ce qui suit.

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

## Chantier 2 — Un kit, une piste — **FAIT (2026-08-02)**

Un kit est **une piste portant un effet** : `CP_JSFX/CP_KitSampler.jsfx`,
64 pads, 64 voix, 8 paires de sortie. Plus de dossier, plus de piste par pad,
plus d'envoi MIDI filtré, plus de conteneur.

### Ce que l'instrument porte

Tout ce que faisait le RS5K — volume, pan, tune, A/D/S/R, choke, boucle,
région, min vol, vélocité min/max, plage de notes, canal MIDI, max voices,
probabilité, round-robin, mode sample ou chromatique — **plus** ce qui
manquait : portamento, obey note-offs, note-off release override, pitch bend,
loop start offset. **Plus** ce qu'exige un mixer interne : mute, solo et
sortie par pad, avec « Break out to a new track » pour rendre fader, mute,
solo et VU à un pad qui les mérite.

Trois réglages du RS5K disparaissent parce qu'ils n'ont plus de sens :
*Cache samples smaller than* (tout est en RAM), *Remove played notes from FX
chain* (on ne repasse pas la note — le réglage est devenu le comportement),
*Resample mode* (l'interpolation est la nôtre).

### Ce qui reste ouvert sur l'instrument

- [ ] `P_XFADE`, `P_INTERP`, `P_PLO/PHI` sont déclarés, sérialisés, et **rien
      ne les lit** — c'est écrit dans le fichier, à ne pas laisser pourrir.
- [ ] Le pitch à durée constante rend zéro plutôt que de mentir : il demande
      un étirement, que `Warp` fait hors ligne et qu'un fil audio de 2005 ne
      fera pas. C'est là qu'il faudra le brancher.

### Les deux moteurs cohabitent

Un kit dit lequel il est (`P_EXT:CP_KIT_ENGINE`) ; tout demande à
`Kit.IsFX()`. Un kit neuf naît sur l'instrument — y compris quand un
glisser-déposer le crée. La migration **construit à côté et n'efface rien** :
elle compte les pads qui SONNENT et laisse Cédric supprimer l'ancien kit.

### Ce que cette semaine a appris, et qui vaut pour la suite

**Chaque défaut a été trouvé par une MESURE, aucun par un raisonnement.** Les
mots bruts de gmem ont désigné une virgule en trente secondes ; le compteur de
notes reçues a séparé « le MIDI n'arrive pas » de « rien n'est chargé » ; le
journal a montré que les boutons marchaient alors qu'on cherchait pourquoi ils
ne marchaient pas. Trois soirées ont été perdues avant d'instrumenter.

Les outils qui en sortent vivent dans `Tools/` et tournent avant chaque
commit : `lua_lint.py` (blocs, locale utilisée avant déclaration, argument
manquant qu'une fonction concatène), `jsfx_lint.py` (blocs, arité des
fonctions de fichier, accès gmem, propreté du fil audio), `gen_kitsampler.py`.
Et l'instrument **dit ce qu'il fait** dans sa propre fenêtre : pads chargés,
notes reçues, notes réellement jouées, dernier réglage reçu, mots bruts de la
boîte aux lettres, battement de Lua.

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

- [x] **Le transport suspend, il n'oublie pas.** En mode Suivre, arrêter le
      transport arrêtait *l'état* de chaque case en lecture, pas seulement son
      son : rappuyer sur play ne relançait rien, il fallait recliquer la
      grille. Le moteur avait déjà raison — il laisse une lane en lecture dans
      son mode sur le front descendant. Ce qui obligeait à l'arrêt, c'étaient
      les cases **audio**, qui sont des voix et gardaient leur passe
      programmée ; elles se taisent maintenant d'elles-mêmes quand l'horloge ne
      bat plus (`Cells.drive`), et `Loop.ClockRunning()` dit cette condition
      une fois pour toutes.
- [x] **Un clip s'ouvre dans la vue de ce qu'il joue.** « Il y a un kit sous la
      cible » décidait des rangées de batterie — mais depuis le chantier 2 un
      instrument chromatique **est** un kit (d'un seul pad, sur sa piste), donc
      chaque clip d'instrument s'ouvrait avec une seule rangée nommée, sur
      laquelle aucune mélodie ne s'écrit. Le genre voyage désormais dans la vue
      (`Loop.KitViewOfTrack` → `kitview.mode`), et seulement pour un kit JSFX :
      sur l'ancien moteur, `CP_KIT_MODE` note quelle page le Sampler affichait
      en dernier, ce qui n'est pas un genre.
- [x] **La barre d'espace et le bouton Play disaient deux choses.** Le son
      partait, le bouton restait sur « Play » : les touches sont traitées après
      le dessin, donc l'appui laisse toujours une image de retard — et la
      fenêtre s'endormait avant de la rattraper, parce que le seul réveil
      demandé pendant une écoute venait du **curseur de lecture**, qui ne se
      dessine que si sa position est lisible. Le réveil est maintenant demandé
      sur la bonne condition : ça sonne.

- [x] **La fenêtre de tolérance de lancement.** Elle vaut désormais **un
      huitième du quantize**, plafonnée à 0,25 beat : 250 ms à Q: Bar, 62 ms à
      Q: Beat, 15 ms à Q: 1/4. Elle suit donc la finesse demandée — serrer le
      quantize resserre la fenêtre, ce qui est exactement ce qu'on veut dire en
      le serrant. Le plafond existe pour Q: 32 mesures, où un huitième ferait
      partir « tout de suite » un lancement qu'on voulait à la fin.
      **Deux assertions de plus au harnais** — dont une qui mesure la fenêtre
      elle-même, parce que l'ancien test passait à 0,45 beat de la frontière et
      aurait donc mesuré autre chose que ce qu'il annonçait.
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

- [x] **`Loop.SaveState` n'a aucun garde `NATIVE`.** Corrigé — une ligne de
      garde. Sans l'extension, la sérialisation produisait huit lanes vides et
      les écrivait par-dessus l'état du projet, à la fermeture de la fenêtre.
- [ ] **Aucune annulation sur l'édition de notes d'une case.** Le contrat de
      `Roll` prévoit `be.undo` et l'appelle à chaque geste structurel ; le
      backend take le branche sur `Undo_OnStateChange`, le backend **clip** le
      branche sur `scheduleApply()` — c'est-à-dire rien. Un Quantize, un
      Euclidean ou une suppression dans une case sont **définitifs**. Et
      Ctrl+Z est explicitement réservé au mode take.
- [ ] **Alt+clic efface une case sans confirmation ni annulation.**
- [x] **Le tag de lane n'est pas sérialisé.** **Format 6** : le tag entre dans
      le bloc de chaque lane, entre le mode et le nombre de notes. Un lecteur
      ancien ignore le champ, un lecteur neuf sur un projet ancien lit 0 — ce
      que le tag valait déjà. Les gardes de version acceptent v6 et comparent
      des NOMBRES, pas des chaînes : `"10" < "4"` aurait cassé silencieusement
      à la version dix.
- [x] **Une lane du Looper ouverte dans l'éditeur n'a aucune identité.**
      `LaneOfTag(t, 0)` rend `nil` — zéro n'est pas une identité, c'est
      l'absence d'identité, et le commentaire d'origine promettait déjà cette
      réponse. `LaneToClip` porte le tag de la lane, et lui en pose un
      (`1000000 + lane`, hors de portée des identités de la grille) quand elle
      n'en avait pas : c'est le seul moment où on peut le faire.
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
      ⚠️ **Ne pas corriger en branchant les voix sur `Loop.SetMute`** : la
      Session se sert du même `mute` pour un autre sens — une case audio arme
      une lane d'une seule note et la mute pour que cette note ne parte pas
      dans l'instrument de la colonne. Taire la voix sur mute rendrait donc
      **toute** case audio silencieuse. Il faut d'abord séparer les deux
      intentions. C'est écrit dans `Loop.SetMute`, au-dessus du code.
- [x] **Fuite de `PCM_source` dans `SrcTempo.FromAnalysis`.** Un seul point de
      sortie, parce que la fonction rendait à quatre endroits et qu'il en
      manquait quatre. Un kit de soixante-quatre pads en fuyait soixante-quatre
      au chargement.

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
- [x] **Q et le mode d'horloge ne survivent qu'à une fermeture propre.** Les
      deux appellent `Loop.MarkDirty()` maintenant, comme CP_Looper le faisait
      déjà.
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

**Atteinte le 2026-08-02, par le JSFX.** `ANALYSE_Sampler_JSFX_vs_CLAP.md`
posait les deux moyens ; le JSFX l'a emporté pour la raison qui y était
écrite — il rend l'échantillonneur disponible après un simple clone. Le CLAP
reste la bonne réponse **pour le moteur de clips**, qui est déjà écrit, déjà
testé, et dont la sortie de REAPER a un sens. Deux métiers, deux moteurs.

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

### La preuve par l'accident (2026-08-01)

Le pitch à durée constante par pad a été écrit, puis **retiré le jour même**.
Il exigeait un ReaPitch par pad, donc un conteneur par pad, donc un déplacement
d'effet — et ce déplacement se faisait sur le chemin d'**un bouton qu'on
tourne**. Chaque tour restructurait la chaîne d'effets du projet.

Ce n'est pas un défaut d'écriture, c'est la limite du montage : **tout paramètre
d'instrument qui n'existe pas dans le RS5K coûte un effet de plus dans une
chaîne partagée, et une chaîne ne se restructure pas pendant un geste.** ADSR
par pad au-delà de ce que le RS5K offre, zones de vélocité, choke sans JSFX,
transposition à durée constante : tous butent sur la même chose.

Dans un plugin, ce sont des **paramètres**. On en tourne un, il change. C'est
tout l'écart, et il est structurel — pas une question de soin.


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
