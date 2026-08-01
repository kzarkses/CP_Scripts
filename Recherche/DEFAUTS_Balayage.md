# Balayage — ce qui existe déjà mais est mal implémenté

Méthode : lecture de `CP_Session.lua`, `CP_Editor.lua`, `CP_Engine/*.lua`, `CP_Looper.lua` et des sources C++ concernées. **Vérifié** = lu dans le code et tracé jusqu'à sa conséquence. **Supposé** = mécanisme lu, conséquence déduite sans exécution. Aucun fichier modifié.

---

## A. Ce qui produit un mauvais son ou perd des données

### A1. Une case audio envoie une note fantôme dans l'instrument de la colonne — **vérifié**

`armLane` publie dans la lane un clip MIDI d'une note (`AUDIO_CLIP`, note 60/61) pour toute case audio : `CP_Session/CP_Session.lua:747-755` puis `:797`. Cette lane est liée au port `PORT_BASE + t` (`CP_Engine/Loop.lua:56, 179-184`), et ce port est attaché à la **piste de destination de la colonne** — donc à l'instrument.

Le moteur émet réellement ces octets : `CP_Native/src/core/cp_lanes.cpp:481` lit `L.port`, `:549` et `:559` émettent `0x80`/`0x90` sur ce port, et `CP_Native/src/host/cp_source.cpp:132-149` les verse dans `block->midi_events` de la piste.

Le commentaire qui couvre ce passage affirme le contraire :

> `CP_Session.lua:792-796` — « nobody hears it at all. The sound channel and its filtered send went with the router; a sound cell is a CP voice on its own port, and the column's instrument is on another one entirely. »

C'est vrai de l'**audio** (port `t`, `Cells`/`Voice`) et faux du **MIDI** : la lane, elle, n'a pas changé de port. À l'époque du routeur, le canal 9-12 + l'envoi filtré empêchaient l'instrument d'entendre le déclencheur ; `bindPort` met maintenant le canal 0 pour toutes les lanes (`Loop.lua:183-184`) et il n'y a plus de filtre.

Conséquence : une colonne qui porte **à la fois** un instrument et des cases audio — configuration explicitement revendiquée (`CP_Session.lua:176-179`, et c'est exactement le cas où `audioDest` crée l'enfant, `:736-741`) — joue un do central à chaque passe de chaque case audio.

Le garde-fou existe et n'est pas utilisé : `run_gate` n'émet rien pour une lane mutée (`cp_lanes.cpp:479`) tout en la gardant en `kLanePlaying`. `Loop.SetMute` n'est appelé que par CP_Looper (`CP_Looper.lua:975`), jamais par CP_Session. *(Réserve : la livraison MIDI passe par `block->midi_events`, que `cp_source.cpp:120-122` qualifie encore d'« expérimental » ; si REAPER ne fournit pas la liste, aucune lane MIDI ne sonne du tout — donc si les clips MIDI marchent, la note fantôme sort aussi.)*

### A2. Une lane du Looper ouverte dans l'Editor n'a aucune identité — l'édition peut atterrir dans la jumelle — **vérifié**

`Loop.LaneToClip` construit `{ kind, name, notes, bars, q, lmode }` — **ni `id` ni `cell`** (`Loop.lua:1041-1048`). Le bouton « Editor » du Looper envoie exactement ça (`CP_Looper.lua:1126-1129`).

Côté éditeur : `state.clip_tag = Ident.TagOf(c)` → `0` (`Ident.lua:127-132`), puis `state.clip_lane = Loop.LaneOfTag(track, 0)` (`CP_Editor.lua:671-672`). Or `LaneOfTag` avec un tag nul **ne rend pas nil** : il rend la moitié vivante (`Loop.lua:740`).

Donc si on ouvre la moitié haute d'une paire pendant que la moitié basse est vivante (ou simplement quand aucune n'est occupée — `resolveLive` laisse `live[t]` à sa valeur précédente, `Loop.lua:712-714`), `flushApply` écrit `Loop.ApplyClip(state.clip_lane, state.clip)` (`CP_Editor.lua:440-441`) **par-dessus les notes de l'autre lane**. Le retour a le même défaut : `CP_Looper.lua:1638`.

C'est mot pour mot le défaut n°2 que l'en-tête d'`Ident` dit exister pour supprimer (`Ident.lua:16-19`), et le commentaire de `CP_Looper.lua:1631-1637` — « l'edit va à la moitié qui TIENT le clip, donc jamais sur la jumelle » — est faux pour le seul chemin qui produit ces descripteurs. Correction minimale : `Ident.Of(c)` dans `Loop.LaneToClip`, ou faire rendre `nil` à `LaneOfTag(t, 0)`.

### A3. Aucun undo sur l'édition de notes d'une case ou d'une lane — **vérifié**

Le contrat de `Roll` prévoit `be.undo(desc)` (`Roll.lua:29`) et l'appelle à chaque geste structurel (`Roll.lua:224, 253, 262, 292, 312, 630, 675, 715, 737, 840, 898, 926`). Le backend take le branche sur `Undo_OnStateChange` (`Roll.lua:98`). Le backend **clip** le branche sur `scheduleApply()` (`CP_Editor.lua:583`) — c'est-à-dire rien.

Et Ctrl+Z est explicitement réservé au mode take : `CP_Editor.lua:3381-3384` (`if state.mode == "midi" then`). `RollUI.HandleKey` ne traite pas l'undo (`RollUI.lua:123`).

Résultat : en mode clip (toute case de session, toute lane de looper), une suppression de sélection, un Quantize, un Euclidean ou un Humanize sont **définitifs**. C'est la seule surface d'édition des cases de session — `CP_Session.lua:145-153` dit « CP_Editor is the only place a cell is edited ».

### A4. Fermer la fenêtre écrase l'état sauvé du projet — **vérifié**

`Loop.SaveState` n'a **aucun garde `NATIVE`** (`Loop.lua:1208-1211`), et `Loop.Serialize` non plus (`:1102-1124`). Sans extension, `Mode()` rend 0, `NoteCount()` rend 0, `GetLengthBars()` rend 1 — la sérialisation produit une chaîne **non vide** représentant huit lanes vides.

`Loop.Deserialize` est asymétrique : il refuse quand `not NATIVE` (`:1127`). Donc la lecture est protégée, l'écriture ne l'est pas.

Chemin : ouvrir CP_Session dans un projet qui contient des boucles, sans l'extension → la fenêtre affiche « No looper engine » et sort (`CP_Session.lua:2304-2313`) → la fermer déclenche `pcall(Loop.SaveState)` (`:2589`) et `r.atexit` (`:2599`) → `CP_Loop/data` est remplacé par du vide. Même chose côté Looper (`CP_Looper.lua:1712, 1718`).

### A5. Changement de projet, fenêtre ouverte : l'état d'un projet part dans le fichier d'un autre — **mécanisme vérifié, exécution non testée**

`Loop.RouterChanged()` rend `false` inconditionnellement (`Loop.lua:1268`), sur la prémisse énoncée en `:1253-1259` :

> « Les notes vivent maintenant dans ce module — une instance par script, par projet »

Cette prémisse est fausse : un script `defer` survit à un changement d'onglet de projet, donc la table `notes` (`Loop.lua:83`), les lanes du moteur (per-REAPER) et la table `cells` de la grille (`CP_Session.lua:84`) survivent aussi, alors que `GetProjExtState(0, …)` et `SetProjExtState(0, …)` visent le projet **actif**.

Conséquences en chaîne : `state.recalled` est déjà vrai (`CP_Session.lua:2206`) donc le nouveau projet n'est jamais rappelé ; `saveGrid()` (`:490`) écrit la grille du projet A dans le projet B ; `Loop.SaveState` à la fermeture y écrit les lanes du projet A. Le garde qui détectait ça a été retiré, pas remplacé.

### A6. Changer le mode tempo d'un son en cours de lecture décharge la matière sous la voix — **vérifié**

`setCellTempoMode` → `retune` → `Cells.Arm(t, lane, soundFor(c))` (`CP_Session.lua:1185-1193, 1175-1183`). Dans `Cells.Arm`, si le chemin a changé (repitch → fichier cuisiné) :

```lua
if slot.path ~= path then
    if slot.path then clipUnref(slot.path) end   -- Cells.lua:246
```

`clipUnref` → `Voice.Unload` → `CP_ClipUnload` → `Pool::retire` qui met immédiatement `state = kClipLoading` (`cp_pool.cpp:109`). La voix qui joue encore obtient alors `nullptr` de `pool.get()` et **meurt sur place, sans fondu** : `cp_voice.cpp:70-88` documente ce chemin comme un chemin d'erreur assumé. `Cells.Arm` ne remet même pas `slot.running` à `false` (`Cells.lua:250`), donc `drive()` ne rejoue pas — le silence dure jusqu'à la passe suivante.

Et le garde-fou du pool est du **code mort** : `Clip::refs` n'est incrémenté nulle part dans tout `CP_Native/src` (seulement remis à zéro en `cp_pool.cpp:50` et lu en `:118`). La seule protection réelle est la barrière de deux blocs (`:108`), soit 2,7 ms à 64 échantillons — alors que `Cells.Disarm` demande un fondu de 5 ms avant de décharger (`Cells.lua:268-269`).

### A7. Fuite de `PCM_source` dans `SrcTempo` — **vérifié**

`SrcTempo.Length` respecte le drapeau `owned` et détruit la source qu'il a créée (`SrcTempo.lua:72-79`). `SrcTempo.FromAnalysis` **ignore le second retour** de `getSource` et ne détruit jamais rien :

```lua
local src = getSource(path)          -- SrcTempo.lua:109  (owned jeté)
```

`Kit.lua:114` initialise `SrcTempo.init(r)` **sans fournisseur de cache**, donc `getSource` passe par `PCM_Source_CreateFromFile` (`SrcTempo.lua:68`). Chaque appel de `Kit.lua:977` (`SrcTempo.Bpm(pad.path)`) fuit une source. CP_Session, lui, injecte `Preview` (`CP_Session.lua:59`) et échappe au problème — ce qui explique qu'il soit resté invisible.

---

## B. Ce qui trompe l'utilisateur

### B1. Les tags de lane ne sont pas sérialisés : après rechargement, la grille et le moteur ne parlent plus du même clip — **vérifié**

`Loop.Serialize` écrit par lane `bars | mute | mode | n | notes…` (`Loop.lua:1112-1121`). **Pas le tag.** Or le tag est le seul lien entre une lane et une case (`Loop.SetLaneTag` n'écrit que dans le moteur, `:727-729`), et le moteur est per-REAPER, pas per-projet.

Après un redémarrage de REAPER, à la réouverture du projet :
- `Deserialize` remet en mode 3 toute lane qui jouait (`:1181`) — y compris une lane de case audio, qui contient une note (celle de A1) ;
- le rappel de CP_Session lit `Loop.GetLaneTag(liveLane(t))` = 0 → `Ident.CellOf(0)` = nil (`Ident.lua:150`) → **aucune case audio n'est réarmée** (`CP_Session.lua:2219-2227`), alors que le commentaire juste au-dessus (`:2214-2218`) promet exactement l'inverse ;
- `drawCell` cherche `Loop.LaneOfTag(t, cellTag(t,s))` avec un id non nul contre un tag moteur nul → nil → la case s'affiche **arrêtée** (`:1356`), et le repli `cur[t] == s` ne se déclenche pas non plus puisque `cur` est vierge au chargement.

Résultat : la grille montre tout arrêté, la lane joue, l'instrument reçoit la note fantôme, l'échantillon ne sonne pas, et un clic sur le triangle arme la jumelle au lieu d'arrêter ce qui sonne.

### B2. « Stretch » : le fichier cuisiné n'est jamais repris — **vérifié**

`Warp.Resolve` dépose une demande et rend le fichier d'origine en repitch (`Warp.lua:196-208`), avec cette promesse :

> `Warp.lua:190-193` et `CP_Session.lua:548-551` — « seule la tonalité est fausse, et seulement pour **une passe** »

Rien ne réarme après la cuisson. `soundFor` n'est appelé que depuis `armLane`, `retune` et la boucle de rappel (`CP_Session.lua:770-807, 1175-1183, 2225`). `Warp.Tick()` tourne à chaque frame (`:2349`) mais son résultat n'est notifié à personne. Une case en mode stretch reste donc en repitch **jusqu'au prochain lancement manuel**, pas une passe.

Trois autres demi-mesures dans le même module :
- l'état `"baking"` est inatteignable : `Warp.Tick` pose `baking = key` et le remet à nil dans le même appel synchrone (`Warp.lua:153-165`), donc aucune frame de dessin ne peut le lire ;
- `Warp.Retry` est décrite comme « appelée par l'UI » (`Warp.lua:171`) et **aucune UI ne l'appelle** : un échec de cuisson est définitif pour la session, sans recours ;
- `Warp.Pending` : zéro appelant.

### B3. Deux réglages voisins, deux mécanismes de persistance, un qui ne marche pas — **vérifié**

Dans la même barre de CP_Session : « Rec: N bars » est écrit dans `ProjExtState("CP_Session","rec_bars")` (`:454`), « Q: … » va dans le moteur puis dans le blob `CP_Loop/data`.

Mais CP_Session ne signale jamais le changement à l'autosave : `setQIndex` (`:426-433`) et la bascule Clock (`:2272-2276`) n'appellent pas `Loop.MarkDirty()`. CP_Looper, lui, l'appelle sur les deux (`CP_Looper.lua:687, 677`). `Loop.AutoSave` ne surveille que `EvtVersion*8 + Mode` par lane (`Loop.lua:1289-1297`) : ni Q ni le mode d'horloge n'y figurent. Le réglage ne survit que si la fenêtre se ferme proprement.

### B4. Le texte d'aide décrit un câblage qui n'existe plus — **vérifié**

`HELP_TEXT` de CP_Session :
- `:117` — « Click a column's NAME to choose that track, make a new one, or **unroute** it ». « Unroute » a été retiré, et le code dit pourquoi (`:357-361`).
- `:171-179` — « Each column that plays a sound **grows a SAMPLER track** » ; en réalité `audioDest` n'en crée un que si la colonne porte un instrument (`:736-741`).
- `:176-178` — « The trigger travels on a channel of the column's own (9 to 12), and the router feeds each destination one filtered channel ». Le routeur, les canaux 9-12 et l'envoi filtré ont tous disparu (`Loop.lua:3-31`, `CP_Session.lua:792-796`).

### B5. « Stretch » est décrit de trois façons différentes dans un seul fichier

- Aide : « it is now the same repitch until a baked version exists » (`:167-168`)
- Menu de la case : « Stretch (keeps the key, plays late) » (`:1212`)
- Commentaire au-dessus du menu : « REAPER's time stretcher. Keeps the key, and is late by the window » (`:1159-1161`)
- Commentaire de `soundFor` : cuisiné une fois, rejoué à 1.0, coût nul (`:539-551`)

Les deux premiers sont montrés à l'utilisateur et se contredisent : le libellé du menu annonce une latence que l'implémentation ne produit pas (et une conservation de tonalité qu'elle ne produit pas non plus, cf. B2).

### B6. Un envoi déjà existant est annoncé comme créé

`Mix.SendCreate` rend l'index de l'envoi **existant** sans rien créer (`Mix.lua:476-479`), et les deux appelants affichent « Send -> X » sur ce retour véridique (`CP_Session.lua:1757-1759` et `:2177-2179`). Refaire le geste donne le même message de succès sans deuxième envoi.

### B7. Deux tests pour « est-ce un son »

`isAudio(c)` = `c.kind == "audio" and c.path` (`CP_Session.lua:557`) ; le menu contextuel utilise `c.kind ~= "midi" and c.path ~= nil` (`:1207`). Équivalents aujourd'hui parce que `Clip.deserialize` met `kind = "audio"` par défaut (`Clip.lua:32, 185`) — donc c'est une divergence qui attend un troisième `kind`.

### B8. Le diagnostic construit exprès et jamais appelé

`Cells.LastOnsetError` (`Cells.lua:521-530`) est l'écart mesuré entre la passe demandée et la passe réellement jouée — l'en-tête du bloc le présente comme la leçon de la campagne moteur (`:516-519`). **Zéro appelant.**

De même, le commentaire de `CP_Session.lua:375-379` annonce avoir corrigé le fait que `Voice.Backend()`, `Voice.Diag()`, `Audition.Backend()` et `Audition.Diag()` « n'étaient appelées nulle part ». Seule `Voice.Label()` a été branchée (`:381`). Les quatre autres sont **toujours** sans appelant — dont `Voice.Diag()`, qui est la seule à interroger `r.CP_Diag()`, le diagnostic interne du moteur.

---

## C. Pièges de performance (le projet vise un PC de 2005 et l'écrit partout)

| # | Où | Coût par frame | Constat |
|---|---|---|---|
| **C1** | `Mix.lua:310-313` `guidOf` | ~1 chaîne allouée par **appel** | `chainOf`/`sendsOf` appellent `guidOf` à chaque fois. Dans `drawMix` cela fait `FxCount` + une `Fx()` par ligne + `SendCount` + une `Send()` par ligne, soit ~14 allocations **par colonne, par frame** — ~56 avec 4 colonnes, alors que l'en-tête du module (`Mix.lua:15-18`) dit ne cacher que les chaînes précisément pour éviter ça. |
| **C2** | `Mix.lua:306-308` `stamp()` | invalidation totale | Le cache est clé sur `GetProjectStateChangeCount`, que `Mix.SetNorm`/`SetPan`/`SetSendNorm` incrémentent **à chaque frame de drag**. Pendant le geste que le cache existe pour rendre fluide, il est reconstruit intégralement : `TrackFX_GetFXName` + `TrackFX_GetEnabled` par FX par colonne, plus deux `gsub` chacun (`shortFx`, `:324-325`). |
| **C3** | `CP_Session.lua:617` → `Warp.lua:118-126` | **un `io.open` + 2 `string.format` + 1 `gsub` par case stretch** | `audioSub` est appelé depuis `drawCell` (`:1508`). `Warp.State` → `Warp.PathFor` (2 `string.format`, `baseName` avec `gsub`, `digest` qui boucle sur toute la clé) puis `fileExists` → `io.open`. Un accès disque dans une boucle de dessin. |
| **C4** | `CP_Session.lua:1354-1379` | ~2 à 7 appels ABI **par case** | `LaneOfTag` fait 1-2 `CP_LaneGet` (`Loop.lua:742-743`), puis `Mode`, `Pending`, parfois `PendingWaitsClock`, `LenBeats`, `Phase`. 4×8 cases ⇒ ~64 à 224 appels ABI/frame, alors que 8 `GetLaneTag` suffiraient à construire une table tag→lane une fois par frame. |
| **C5** | `Rows.lua:34-37` | 1 chaîne + 4 coercions nombre→chaîne | La clé est concaténée **avant** le garde `if m.key == key then return m end` (`:38`), donc l'allocation qu'elle sert à éviter a lieu de toute façon. Et `rollRows()` est appelée **deux fois** par frame dans CP_Editor (`:2428`, `:3075`). |
| **C6** | `Loop.lua:384-413` `KitViewOfTrack` | 1 table + 1 chaîne **par pad** | Clé sur `GetProjectStateChangeCount` — donc reconstruit à chaque frame pendant un drag de note en mode take. Pire, `kitview.version` est incrémenté à **chaque** reconstruction (`:411`), même identique ⇒ re-clé `Rows.Build` ⇒ reconstruction du modèle de lignes. Et `clipKit()` est appelée 3 fois par frame (`CP_Editor.lua:2377, 3154`, via `rollRows` ×2). |
| **C7** | `CP_Session.lua:2561` | 1 à 2 concaténations | `msg = (msg ~= "" and (msg .. "   ·   ") or "") .. engineBadge()` s'exécute inconditionnellement à chaque frame, plus `Cells.Diag()` (`:2563`) qui fait un `string.format` (`Cells.lua:546`). Dans un fichier dont l'en-tête de section s'intitule « zero allocation per frame » (`:279`). |
| **C8** | `Loop.lua:943-996` `pollCapture` | O(événements × lanes) | `local pending, idx = {}, 0` + une table par événement (`:947`) + `local changed = {}` (`:953`), à chaque frame pendant une prise. Et pour **chaque** événement, une boucle sur les 8 lanes avec un `CP_LaneGet(lane,"mode")` (`:968-969`) — jusqu'à 1024 appels ABI pour 128 événements, alors que la liste des lanes en capture est déjà connue de la boucle `:894-920`. |
| **C9** | `Loop.lua:292-298` `RefreshDests` | O(8 × pistes) chaînes | `resolveGUID` refait un balayage complet avec `GetTrackGUID` (une chaîne chacun) pour les 8 lanes, puis `syncColumns` fait 3 `GetSetMediaTrackInfo_String` par piste (`eligible`, `:228-231`). Sur 100 pistes : ~800 + 300 allocations, toutes les 0,5 s **dès que le compteur d'état bouge** — c'est-à-dire en continu pendant n'importe quel drag de fader. |

---

## D. Code mort

**Dans `Loop.lua` — zéro appelant externe** (vérifié par grep sur tout le dépôt) : `ToggleRec` (`:550`), `SyncSends` (`:304`), `IsAdopted` (`:1270`), `EngineLanes` (`:429`), `EngineBuild` (`:430`), `ReloadEngine` (`:434`), `TrackName` (`:326`, rend toujours nil), `SetLaneAudio`/`GetLaneAudio` (`:651-652`, no-ops assumés), `Loop.Beat` (`:757`, remplacé par `EngineBeat`), `Loop.NOTE_STRIDE` (`:48`, dont le commentaire dit « kept: callers use it » — aucun ne l'utilise), `MigrateLegacy` (`:450`, appelée seulement en interne).

Cas particulier : `Loop.SetAudioRun`/`GetAudioRun` (`:577-581`) écrit `CP_SetAudioRun` dans le moteur pour tenir l'horloge libre en marche quand un son joue sans lane. Aucun appelant — cohérent avec « les sons sont des lanes maintenant », mais le drapeau moteur reste donc perpétuellement à zéro.

**Ailleurs** : `Cells.Available` (`Cells.lua:137`), `Cells.Retune` (`:258`), `Cells.LastOnsetError` (`:521`) ; `Warp.Retry` (`Warp.lua:172`), `Warp.Pending` (`:177`) ; `Tracks.Folder`, `Tracks.Ensure`, `Tracks.NewChild`, `Tracks.Find` (`Tracks.lua:52, 108, 68, 35`) ; `Ops.PeakInRegion` (`Ops.lua:31`) ; `Audition.CanPlaySource`, `Audition.SourceType`, `Audition.DropSource` (`Audition.lua:418, 585, 589`) ; `Voice.Backend`/`Voice.Diag` (`Voice.lua:151, 198`).

**Branche inatteignable** : `Pool::collect` teste `c.refs > 0` (`cp_pool.cpp:118`) alors que `refs` n'est incrémenté nulle part (cf. A6).

---

## E. Incohérences entre fenêtres

1. **Longueur de boucle fractionnaire.** CP_Session accepte les fractions et le justifie explicitement — « half a bar is a real loop, and the engine goes down to an eighth. Rounding to whole bars here is what used to turn a two-beat loop into a four-bar one » (`CP_Session.lua:621-628`). Le seul contrôle de longueur de l'Editor est un combo 1/2/4/8/16/32 (`CP_Editor.lua:2396-2397`) borné par `setClipBars` à `1..32` entiers (`:458`). Ouvrir une case d'une demi-mesure et toucher ce combo la force à une mesure, sans avertissement. `soundBars` peut légitimement rendre 0,5 (`CP_Session.lua:561, 594`).

2. **Le même geste sur la même chose, deux persistances** : cf. B3 (Q et Clock marqués sales dans le Looper, pas dans la Session).

3. **Deux vocabulaires pour le même objet.** `Loop.SetLaneDest(lane, …)` prend une *lane* et opère sur une *piste* (`Loop.lua:334-335`) ; `Loop.ColumnAt` rend un *slot* ; `Loop.TrackOfLane` traduit ; `CP_Session` appelle « colonne » ce que `Loop` appelle « track », qui est un *couple de lanes*, alors que « track » désigne aussi la piste REAPER de destination. `CP_Looper.lua:1638-1641` mélange les deux dans deux lignes voisines : `st` est un index de *track* (0..3) et sert d'index dans `ev[]`, indexé par *lane*.

4. **`Loop.LaneOfTag(t, 0)` a deux sens.** Son commentaire promet « NIL when the engine no longer holds that clip… a window that believed otherwise would write its edits over the clip that IS playing » (`Loop.lua:735-738`), et la première ligne du corps fait précisément le contraire pour tag = 0 (`:740`). C'est la racine de A2.

---

## Ordre que je défendrais

**A1**, **A2** et **A3** d'abord : ce sont les trois qui font sortir un mauvais son ou perdent du travail, et les trois ont une correction bornée (muter les lanes audio ; `Ident.Of` dans `LaneToClip` + `LaneOfTag(t,0) → nil` ; brancher `be.undo` du backend clip sur une pile locale). **A4** est trois lignes (un garde `NATIVE` dans `SaveState`). **B1** est un champ de plus dans le format de sérialisation, et il débloque tout le reste du rappel. **A5** demande une décision, pas un correctif : détecter le changement de projet, ou accepter que ces fenêtres soient liées à un projet.

Côté performance, **C1** et **C2** sont le meilleur rapport effet/effort de la liste — un GUID mis en cache par colonne et une clé de cache qui n'est pas le compteur d'état du projet, et le mixeur cesse d'allouer une cinquantaine de chaînes par frame. **C3** est un `io.open` par frame et se règle avec un cache d'existence invalidé par `Warp.Tick`.