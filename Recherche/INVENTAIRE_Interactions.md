# Les interactions entre fenêtres — état réel du code

Tout ce qui suit est **vérifié dans le code** sauf mention explicite « supposé ». Aucun fichier modifié.

---

## 1. LE PROTOCOLE — inventaire exact

Il y a **trois** canaux inter-fenêtres, plus deux canaux privés survivants.

### 1.1 DragBus — glisser-déposer par rectangles (`CP_Toolkit/DragBus.lua`)

Section ExtState `CP_DragBus`, non persistante.

| Clé | Écrite par | Format |
|---|---|---|
| `targets` | consommateur, `Register` (`:43`) | liste d'ids séparés par `,` |
| `rect_<id>` | consommateur, `RectSync` (`:56`) | `x1|y1|x2|y2` en coords écran |
| `active`,`kind`,`path`,`label` | publieur, `Begin` (`:106`) | scalaires |
| `drop_<id>` | publieur, `Drop` (`:146`) | `kind\nsx\nsy\npath` |

**Câblage réel :**

| Fenêtre | id | publie | consomme |
|---|---|---|---|
| CP_MediaExplorer | — | `file`, `fx` (`:2033`,`:2035`) | **rien** (aucun `Register`) |
| CP_Sampler | `sampler` | `file` (`:983`) | `file`, `instrument` (`:355`) |
| CP_Editor | `editor` | `clip` (`Bus.BeginClip`, `:1656`) | `clip` + `file` promu (`:825`) |
| CP_Session | `session` | **rien** | `clip` + `file` promu, `fx` (`:1275`) |
| CP_Looper | — | rien | rien |

### 1.2 Bus — clips sur DragBus + boîte aux lettres (`CP_Engine/Bus.lua`)

`Bus.BeginClip` (`:37`) sérialise un Clip CPC1 dans le champ `path` de DragBus. `Bus.TakeDrop` (`:44`) désérialise, **promeut** `kind="file"` en Clip audio, et **renvoie les genres étrangers en 4e..7e valeur de retour** (`:58`).

`Bus.Send/Recv` (`:68`,`:74`) : section `CP_Bus`, une clé par adresse, corps `timestamp\nCPC1|…`, TTL 5 s, **delete-on-read**.

| Adresse | Émetteurs | Consommateur unique |
|---|---|---|
| `editor:open` | Session `:930`, Looper `:1034`+`:1129`, Sampler `:222`, MediaExplorer `:963` | CP_Editor `:851` |
| `editor:apply` | CP_Editor `:447` (clip **sans** `cell`) | CP_Looper `:1626` |
| `editor:apply:cell` | CP_Editor `:447` (clip **avec** `cell`) | CP_Session `:2361` |

Le dédoublement `apply` / `apply:cell` est délibéré (commentaire `CP_Editor.lua:443-446`) : c'est la seule protection anti-vol du protocole, et elle marche. **Aucune autre adresse n'est protégée** : deux instances du même script consommeraient la même boîte, premier arrivé premier servi.

### 1.3 Heartbeat / réveil (`Bus.FocusApp`, `Bus.OpenEditor`)

`GetExtState(app,"alive")` avec fenêtre de 2 s + `GetExtState(app,"cmd")` (action nommée, persistante).

**Seuls deux scripts publient ce couple** : CP_Editor (`:3401`,`:3542`) et CP_FXBrowser (`FX Constellation/CP_FXBrowser.lua:1740`,`:1757`). Session, Looper, Sampler, MediaExplorer n'ont ni `alive` ni `cmd` : `Bus.FocusApp` ne peut pas les atteindre, et rien ne peut les démarrer.

Asymétrie : FXBrowser fait `DeleteExtState(…,"alive")` en sortie (`:1746`), **CP_Editor ne le fait pas** (`OnClose` `:3546-3555`). Pendant 2 s après fermeture, `Bus.OpenEditor` croit l'éditeur vivant, ne le relance pas, et le clip est posté dans le vide.

### 1.4 Les deux canaux privés qui n'ont pas migré

- `CP_Sampler/instrument` — `ts\npath\nsoffs\neoffs`, écrit par CP_Editor `:1129`, lu par CP_Sampler `:377`. Doublon fonctionnel de `Bus.Send` sur un Clip audio.
- `CP_Editor/open` — chemin nu, encore lu par CP_Editor `:839`. **Plus aucun émetteur** dans le dépôt : code mort côté lecture.

### 1.5 Le canal que personne n'appelle un canal : `ProjExtState`

C'est en réalité le canal le plus lourd de conséquences, et il n'est documenté nulle part comme tel.

- `CP_Session/grid` — la grille sérialisée, écrite **seulement** par CP_Session (`:490`).
- `CP_Loop/data` — l'état des 8 lanes, écrit par CP_Session **et** CP_Looper (`Loop.AutoSave`, `Loop.lua:1287`).
- `CP_Ident/next` — le compteur d'identités, écrit par `Ident.NewId` (`Ident.lua:94`), alloué **uniquement** par CP_Session.

---

## 2. CYCLE DE VIE D'UNE CASE — le chemin exact

### 2.1 Case MIDI (le seul aller-retour qui existe)

```
CP_Session, clic sur le contenu de la case (t,s)      CP_Session.lua:1588
  editCell(t,s)                                                    :907
    tag = cellTag(t,s) -> Ident.Of(c) -> c.id (alloue si absent)   :261,264
    si Loop.LaneOfTag(t,tag) == nil : armLane(twinLane(t), c, t, s) :921
        Loop.ApplyClip(lane, c)        <- ecrit le MIROIR LOCAL     :797
        Loop.SetLaneTag(lane, tag)     <- ecrit le MOTEUR           :802
    c.origin = "looper:"..t   (une PISTE 0..3)                      :926
    c.cell   = t..","..s                                            :927
    Bus.OpenEditor(c)  -> demarre l'editeur si mort, puis Send      :930

CP_Editor
  Bus.Recv("editor:open")                                           :851
  openClip(c) -> kind=="midi" -> setClip(c)                     :778,:649
    state.clip = c                (la table DESERIALISEE)           :654
    state.clip_track = Loop.TrackOfLane(tonumber("t"))              :667
    state.clip_tag   = Ident.TagOf(c)  = c.id                       :671
    state.clip_lane  = Loop.LaneOfTag(track, tag)                   :672
  chaque frame : clip_lane RE-RESOLU par le tag                     :3434
  chaque geste : scheduleApply() -> +0.25 s -> flushApply()     :428,:432
    Loop.ApplyClip(clip_lane, clip)   <- miroir local de l'EDITEUR  :441
    Bus.Send("editor:apply:cell", clip)                             :447

CP_Session
  Bus.Recv("editor:apply:cell")                                    :2361
  applyEdit(ac)                                                     :937
    cells[t][s] = ac          <- NOUVELLE TABLE, l'ancienne est jetee :946
    Ident.Bind(ac)            <- le registre pointe la nouvelle      :947
    saveGrid()                                                       :948
    Loop.ApplyClip(Loop.LaneOfTag(t,cellTag(t,s)), ac)          :951-954
```

Identifiants utilisés, dans l'ordre : `c.id` (≥ 1 000 000, `Ident.BASE`) → écrit dans le champ `tag` de la lane du moteur → relu par `Loop.LaneOfTag` à chaque frame des deux côtés → transporté dans le champ `id` du CPC1 → re-lié par `Ident.Bind`. La chaîne est cohérente. Le tag positionnel `t*1000+s+1` (`Clip.CellTag`) n'est plus qu'un chemin de repli pour les projets antérieurs.

### 2.2 Case AUDIO — l'aller-retour n'existe pas

`editCell` ne distingue pas audio et MIDI : elle arme la lane, pose `origin`/`cell`, et envoie. Puis :

```
CP_Editor : openClip(c), kind=="audio"                              :765
  setFile(c.path)                                                   :766
    state.clip, state.clip_lane = nil, nil                          :628
    state.clip_track, state.clip_tag = nil, 0                       :629
    state.mode = "file"                                             :636
```

`flushApply` exige `state.mode == "clip"` (`:433`). **Un clip audio ne repart jamais.** `cell`, `origin`, `id`, `color`, `tempo_mode`, `src_bpm`, `bars` sont perdus à la seconde ligne de l'ouverture. Cliquer une case audio pour l'éditer :
- arme quand même la lane jumelle et charge le fichier dans ses voix (`Cells.Arm`, `:777`) — un effet moteur pour une édition qui n'aura pas lieu ;
- écrit `c.name` par défaut sur la table stockée **sans `saveGrid()`** derrière (`:928` — le `saveGrid` de `:914` n'est atteint que si la case était vide).

### 2.3 Ce que la lecture audio ignore du descripteur

`Cells.Arm(t, lane, path, rate)` (`Cells.lua:237`) ne prend qu'un chemin et un taux. `Cells.playAt` n'utilise `opts.offset` que pour le rattrapage de phase (`:363-375`). Donc **`clip.offs` / `clip.len` n'ont aucun consommateur dans la Session** : une sélection éditée déposée dans une case joue le fichier entier. `gain` et `pitch` : idem, aucun lecteur. Le champ existe, voyage, est sauvegardé — et ne fait rien.

---

## 3. LE GLISSER-DÉPOSER — ce qui voyage, ce qui se perd

| Trajet | Charge émise | Ce qui arrive | Perte |
|---|---|---|---|
| Explorer → Sampler | `file` + chemin | pad chargé | la section de la bande d'onde (`state.wsel`), que `openInEditor` sait pourtant transporter (`:956-961`) |
| Explorer → Session | `file` → promu Clip audio (`Bus.lua:52`) | case remplie, `ensureBars` devine la longueur | idem + nom |
| Explorer → Editor | `file` → promu | `setFile` | idem |
| Sampler → Session/Editor | `file` + `pad.path` (`:983`) | fichier nu | trim SOFFS/EOFFS, nom, choke, accordage — tout le pad |
| Editor → Session | `clip` CPC1 avec `offs`/`len` | case remplie… mais région ignorée à la lecture (§2.3) | la région, en pratique |
| **Editor → Sampler** | `clip` CPC1 | **rien** : `busConsume` n'accepte que `file`/`instrument` (`:355`) | **tout, silencieusement** |
| Explorer → Session (FX) | `fx` | **jamais livré** | tout |
| Session → n'importe où | — | — | la Session ne publie rien |
| Looper → / ← | — | — | le Looper n'est ni cible ni source |

Deux points durs :

**Le drop FX est du code mort.** `CP_Session.lua:1279-1295` gère `kind=="fx"` sur une tranche du mixer. Mais MediaExplorer traite les nœuds FX dans une branche qui `return` avant tout `HoverTarget`/`Drop` (`:2058-2082`, `DragBus.End()` explicite ligne `:2064`). Aucun autre script n'appelle `DragBus.Begin("fx", …)`. Donc la fonctionnalité ne peut pas se déclencher.

**`DragBus.Drop` ment.** Elle retourne `tid ~= nil` (`:155`) — « une fenêtre enregistrée était sous la souris », pas « la cible a compris ». D'où `CP_Editor.lua:1689` : `if DragBus.Drop(sx,sy) then flash("Dropped: …")`. Traîner une sélection audio de l'éditeur sur le Sampler affiche **« Dropped: … » alors que rien n'a été fait**.

---

## 4. LES TROUS — courses réelles, avec l'enchaînement qui les produit

### 4.1 Le miroir de notes est par script — c'est le trou structurel

`Loop.lua:83` : `local notes = {}`. `publish()` (`:96`) écrit vers le moteur (`CP_LaneSetNote`/`CP_LanePublish`). **Il n'existe aucune fonction de lecture des notes depuis le moteur** — vérifié : `Loop.ReadNotes`, `Loop.GetNote`, `Loop.NoteCount`, `Loop.HasContent` lisent tous `store(lane)`, le miroir Lua local. Chaque script `dofile`ant Loop.lua possède donc **sa propre vérité** des notes, et le seul point de rencontre est le blob `CP_Loop/data`.

**Course A — le Looper vide une case de la Session (destruction de données).**
1. Session + Looper ouverts, moteur attaché.
2. Dans la Session, lancer une case MIDI de la colonne 1. `armLane` → `ApplyClip` remplit **le miroir de la Session** et publie au moteur : ça sonne.
3. Le miroir du Looper pour cette lane est resté vide. Sa bande `ev[l]` (`:764`, alimentée par `Loop.EvtVersion`+`ReadNotes`, tous deux locaux) **dessine une lane vide pendant que la colonne joue**.
4. Clic sur cette bande (`:1024`) : `Loop.LaneToClip(el)` lit le miroir local → `n<=0` → `nil` → le Looper fabrique un **clip MIDI vide** (`:1026-1029`) et l'envoie à l'éditeur.
5. L'éditeur ouvre un piano roll vide sur une lane audible.
6. Une note posée → `flushApply` → `Loop.ApplyClip(live, {1 note})` → publish → **les notes de la case sont effacées du moteur**, alors que `cells[t][s]` les contient toujours. Son et grille divergent définitivement.

**Course B — l'autosave écrase (perte à la réouverture du projet).**
`Loop.AutoSave` (`:1287`) surveille `EvtVersion(lane)*8 + Mode(lane)`. `EvtVersion` est **local**, `Mode` est lu du **moteur**, donc partagé.
1. Session + Looper ouverts, tous deux `adopted` après leur `LoadState`/`AdoptState` (`Session:2232`, `Looper:1580`).
2. La Session lance une case : le mode de la lane passe de 2 à 3.
3. Le Looper voit ce changement de mode → `save_due = now+0.4` → 0.4 s plus tard `SaveState()` → `Loop.Serialize` (`:1102`) lit **le miroir du Looper**, périmé, et l'écrit dans `CP_Loop/data`.
4. Rouvrir le projet : les notes sont celles que le Looper avait, pas celles que la Session jouait.

Le sens inverse est vrai aussi : `CP_Session.OnClose` fait `pcall(Loop.SaveState)` inconditionnellement (`:2598`).

**Course C — l'ouverture d'une fenêtre republie l'ancien état.**
`Loop.LoadState(false)` refuse de charger « si une lane a du contenu » — mais teste `Loop.NoteCount` sur le miroir **local**, qui est vide au premier frame. Donc la garde ne garde rien : ouvrir CP_Looper (`:1571`) ou CP_Session (`:2213`) **désérialise toujours** le blob et republie les 8 lanes, avec `SetLengthBars`, `SetNoteCount` et `SetMode` (`:1177-1186`). Jouer une boucle dans le Looper puis ouvrir la Session rejoue l'état sauvegardé jusqu'à 0.4 s en retard, et remet les modes de l'époque.

### 4.2 Le tag de lane n'est pas persisté

`Loop.Serialize` (`:1112`) écrit `bars|muted|mode|n|notes…`. **Pas de `tag`.** Conséquences après *fermer le projet / rouvrir* :
- `Loop.GetLaneTag(lane)` vaut 0 partout ;
- la boucle de ré-armement des cases audio (`Session:2219-2227`) fait `Loop.LaneOfTag(t, GetLaneTag(live))` = `LaneOfTag(t, 0)` qui retourne la lane vive (`Loop.lua:740`), puis `sceneOfLane` → `Ident.CellOf(0)` → `nil` → `audio` faux : **elle ne ré-arme jamais rien**, contrairement à ce que son propre commentaire annonce ;
- une case audio qui jouait revient en lane mode 3 sans voix : elle boucle une note qu'aucun échantillon ne rend. Silence inexplicable ;
- `cur[]` n'est pas persisté non plus (aucun `ProjExtState` pour lui, `:85`), et `sceneOfLane` ne peut pas le reconstruire sans tag : la grille n'affiche aucune case en lecture pendant que le moteur joue.

Note : *dans* la même session REAPER, fermer et rouvrir CP_Session fonctionne — les tags vivent dans le binaire et survivent au script.

### 4.3 Éditer une case pendant qu'elle joue

Ça marche, par construction : `editCell` réutilise la lane qui tient déjà le clip (`:921`), `flushApply` écrit la lane vive, `ApplyClip` ne touche pas le mode (`Loop.lua:1051-1053`). **C'est le cas le mieux traité de tout le protocole.**

Le défaut est ailleurs — **la fusion n'existe pas** :
1. Ouvrir la case (0,0) dans l'éditeur.
2. Dans la Session, clic droit → *Rename* → « Kick », ou changer la couleur, ou `tempo_mode`.
3. Bouger une note dans l'éditeur.
4. `applyEdit` fait `cells[t][s] = ac` (`:946`) : la table de la Session, renommée, est **remplacée entière** par la copie de l'éditeur, qui porte l'ancien nom.

Le message est un objet complet, jamais un delta. Le dernier écrivain gagne sur **tous** les champs, y compris ceux qu'il n'a pas édités. Symétriquement, l'éditeur ne relit jamais les notes de sa cible : seul `bars` est suivi en retour (`:3449-3453`). L'éditeur intégré du Looper (Alt+clic, `:1022`) écrit dans le même miroir de lane — deux éditeurs sur la même lane, aucun ne voit l'autre.

### 4.4 Échanger / remplacer un clip pendant une édition

**Course D — le drop ressuscite l'ancien clip.**
1. Case (0,0) ouverte dans l'éditeur (id N, lane L taguée N).
2. Depuis l'Explorer, déposer un fichier sur (0,0). `busConsume` (`:1318`) fait `cells[0][0] = clip` **sans `Ident.Forget(N)` ni `clearCell`** — l'ancien id reste dans le registre, la lane reste taguée N.
3. Lancer la nouvelle case : `armLane` retague L avec le nouvel id.
4. Dans l'éditeur, bouger une note. `LaneOfTag(0, N)` = nil → pas d'écriture lane (bien), mais `Bus.Send("editor:apply:cell", clip)` part quand même avec `cell="0,0"` → `applyEdit` **réinstalle l'ancien clip dans la case**, écrasant le fichier déposé.

**Course E — clip supprimé, l'éditeur le fait revivre.**
1. Case ouverte dans l'éditeur.
2. Alt+clic dans la Session → `clearCell` (`:1089`) : `Ident.Forget`, `cells=nil`, `Loop.Clear(lane)` (qui remet le tag à 0, `Loop.lua:529`).
3. Dans l'éditeur, appuyer sur Play : `state.clip_lane` est nil → `clipLaunch` monte le clip dans la lane jumelle et fait `Loop.SetLaneTag(lane, state.clip_tag)` (`:496`) — le tag d'un clip qui n'existe plus.
4. Le clip supprimé joue. La Session ne peut pas le nommer (`Ident.CellOf` → `reg[tag]` = nil), donc aucune case ne clignote et aucun bouton stop de case ne l'atteint. Il faut le stop de colonne.

### 4.5 Le tag 0 — l'éditeur écrit dans « ce qui joue »

`Loop.LaneOfTag(t, 0)` retourne **la lane vive** (`Loop.lua:740`). Or `Loop.LaneToClip` (`:1036`) ne pose ni `id` ni `cell` ni `color` ni `name` d'origine — c'est une table neuve avec `q="bar"`, `lmode="loop"` en dur. Donc tout clip venu du Looper arrive dans l'éditeur avec `Ident.TagOf(c) == 0` (`Editor:671`), et `state.clip_lane` devient « la moitié qui joue en ce moment », re-résolue **chaque frame** (`:3434`).

Enchaînement : ouvrir une lane depuis le Looper, puis lancer une autre case sur cette colonne depuis la Session. Le temps que l'échange se fasse, `LiveLane` bascule, et le prochain `flushApply` de l'éditeur écrit ses notes **dans le clip entrant**.

Et l'aller-retour est cassé au bout aussi : ce clip part sur `editor:apply` (pas de `cell`), que **seule** la Session n'écoute pas — la case stockée ne bouge jamais, même si la lane, elle, a bien reçu l'édition.

### 4.6 Une fenêtre meurt en plein geste

- **Publieur tué pendant un drag** : `active` reste à `"1"`. MediaExplorer fait `DragBus.End()` dans son `OnClose` (`:2232`) ; **CP_Sampler et CP_Editor ne le font pas** (`Sampler:1931-1944`, `Editor:3546-3555`). Le Sampler tué pendant un drag de pad laisse `ActiveDrag()` allumé, et tous les autres surlignent une cible fantôme pour toujours.
- **Cible tuée** : `Unregister` nettoie `rect_`, `drop_` et la liste. Session et Sampler le font sous `pcall`/`atexit`. Mais si le script meurt sur une erreur Lua sans `OnClose`, le rect périmé reste dans `targets` : `HoverTarget` matche une fenêtre morte, `Drop` écrit dans un `drop_<id>` que personne ne lira, et le publieur affiche « Dropped ». **Aucune vérification de vivacité côté DragBus** — alors que le heartbeat existe déjà pour `Bus.FocusApp`.
- **Consommateur bloqué > 5 s** : `renameCell` (`Session:1137`) appelle `GetUserInputs`, qui bloque la boucle defer. Un `editor:apply:cell` émis pendant ce temps est périmé au retour ; `Bus.Recv` renvoie nil **sans supprimer l'enregistrement** (`Bus.lua:79`). L'édition est dans la lane, jamais dans la grille.
- **Session absente** : `flushApply` écrit la lane directement précisément pour ce cas (commentaire `:434-439`). Mais `CP_Session/grid` n'est écrit que par `saveGrid`. **Éditer une case avec CP_Session fermé change ce qui sonne et jamais ce qui est stocké** — la case revient à son état d'avant à la réouverture. Le raisonnement du commentaire couvre le moteur et oublie le magasin.

### 4.7 Défauts de plus petite portée, vérifiés

- `DragBus.Register` teste `list:find(id, 1, true)` (`:46`) — **une recherche de sous-chaîne**. Tout nouvel id qui est sous-chaîne d'un id déjà présent (`"edit"` avec `"editor"` enregistré) ne sera jamais ajouté, et ne recevra jamais de drop. Les trois ids actuels ne collisionnent pas ; le piège est armé pour le quatrième.
- Ids fixes ⇒ **deux instances du même script sont indiscernables** : même `rect_`, même `drop_`, même boîte `editor:open`.
- `Ident.Of` est appelé depuis `cellTag`, lui-même appelé depuis `drawCell` (`:1356`). Ouvrir un projet antérieur aux identités alloue un id par case **dans le chemin de dessin**, donc `SetProjExtState` → le projet est marqué modifié sans qu'on ait rien fait.
- `applyEdit` a un repli `Loop.ApplyClip(ln, ac)` (`:961`) qui traite `origin` comme un **numéro de lane brut**, alors que le Looper (`:1633`) et l'éditeur (`:667`) le traitent comme une **piste** via `TrackOfLane`. Incohérence réelle ; en pratique inatteignable puisque la Session n'écoute que `:cell` et que la branche `cell` capture tout.
- Le Looper (`:1129`) et le Sampler (`:222`) utilisent `Bus.Send("editor:open", …)` au lieu de `Bus.OpenEditor` : si l'éditeur n'est pas lancé, le geste ne fait **rien**, et le Looper affiche pourtant « Lane sent to CP_Editor ».

---

## 5. CE QUI MANQUE AU PROTOCOLE

Classé par ce que ça coûte de ne pas l'avoir, pas par difficulté.

1. **Une lecture des notes depuis le moteur.** C'est la racine de 4.1 et 4.2. Tant que `Loop.ReadNotes` lit un miroir local, chaque fenêtre a sa vérité et le blob de projet est un champ de bataille. Une seule fonction ABI (`CP_LaneGetNote`) supprimerait la course A *et* la course B, et rendrait `Loop.LaneToClip` honnête pour toutes les fenêtres.

2. **Le tag dans le format de sérialisation.** Un champ de plus dans `Loop.Serialize` (format 6, `bars|muted|mode|tag|n|…`). Sans lui, le lien clip↔lane meurt à chaque sauvegarde, et avec lui meurent le ré-armement audio, l'affichage de lecture, et le bouton stop de case après rechargement.

3. **Un aller-retour audio.** Aujourd'hui `openClip` dégrade un Clip audio en fichier nu (`Editor:766` → `setFile:628`). Il manque un mode `"clip audio"` dans l'éditeur qui garde `cell`/`origin`/`id` et republie `offs`, `len`, `gain`, `pitch`, `bars`, `tempo_mode`. C'est la moitié manquante de la « session unifiée audio+MIDI » : la case audio se lance déjà comme un clip, elle ne s'édite pas comme un clip.

4. **Des messages de champ, ou un numéro de version par clip.** Le CPC1 entier en écrasement aveugle (§4.3) fait perdre les renommages et les couleurs. Le moins cher : un compteur `rev` dans le descripteur, incrémenté à chaque écriture, et un `applyEdit` qui refuse un message plus vieux que ce qu'il détient. Le plus juste : un message qui ne porte que ce que l'émetteur a touché.

5. **Un canal « détache-toi ».** Rien ne dit à l'éditeur que sa cible a été vidée (4.4-E), remplacée (4.4-D), ou que la lane a été retaguée. Une adresse `editor:invalidate` portant un id suffirait : l'éditeur passe en lecture seule et le dit, au lieu de continuer à publier vers un fantôme.

6. **Une revendication d'édition.** Personne ne sait qu'une case est ouverte ailleurs. La Session pourrait le signaler visuellement, refuser un drop dessus, et le Looper pourrait éviter d'ouvrir dans son éditeur intégré ce que CP_Editor tient déjà.

7. **Un vocabulaire de cible dans DragBus.** Le publieur ne peut pas savoir que le Sampler ne comprend pas `clip` (§3). Une clé `accepts_<id>` (`file,clip,fx`) publiée avec le rect ferait de `HoverTarget` une réponse utile — pas de surlignage sur une cible incompétente, et pas de « Dropped » mensonger.

8. **Une vivacité côté DragBus.** Le heartbeat existe déjà pour `FocusApp` : `rect_<id>` pourrait porter un timestamp, et `HoverTarget` ignorer les rects plus vieux que 2 s. Ça supprime le drop dans le vide d'une fenêtre morte.

9. **`alive` + `cmd` pour les quatre autres fenêtres.** Deux lignes chacune (`Editor:3401`,`:3542` en modèle). Sans ça, « clique une case vide et le navigateur apparaît » ne peut exister que dans un sens, et `Bus.FocusApp` reste une fonction à un seul client.

10. **Un accusé de réception.** `Bus.Send` ne peut pas savoir si quelqu'un a lu. Trois flashes du dépôt affirment une livraison qu'ils n'ont pas vérifiée (Looper `:1130`, Editor `:1689`, Editor `:1132`). Un `Recv` qui repose un `ack:<addr>` réglerait les trois.

11. **Le Looper comme cible DragBus.** Il n'est ni source ni cible ; déposer un clip sur une lane est impossible alors que `Loop.ClipToLane` (`:1073`) existe déjà et fait exactement ça. C'est le pont le moins cher de la liste.

12. **Retirer les canaux privés.** `CP_Sampler/instrument` refait un Clip audio à la main ; `CP_Editor/open` n'a plus d'émetteur. Les deux devraient devenir `Bus.Send("sampler:instrument", clip)` et disparaître.

---

**Fichiers lus** (chemins absolus) :
`C:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Bus.lua`, `Clip.lua`, `Ident.lua`, `Loop.lua`, `Cells.lua` ; `CP_Toolkit\DragBus.lua` ; `CP_Session\CP_Session.lua` ; `CP_Editor\CP_Editor.lua` ; `CP_Looper\CP_Looper.lua` ; `CP_Sampler\CP_Sampler.lua` ; `CP_MediaExplorer\CP_MediaExplorer.lua` ; `ANALYSE_Interactions.md`.

**Note sur ANALYSE_Interactions.md** : daté du 2026-07-22, antérieur aux chantiers Clip/Bus/Ident. Ses §1.1 et §1.3 sont périmés (les ponts ont migré). Restent exacts : §1.2 (Sampler→Explorer et Explorer→FXC toujours morts — vérifié, MediaExplorer n'a aucun `Register` et FX Constellation ne touche pas DragBus) et la perte de la section au drop.

Aucune comparaison Ableton/FL n'est faite ici : le sujet demandé est le protocole interne, et je n'avance rien sur les concurrents sans l'avoir vérifié en source.