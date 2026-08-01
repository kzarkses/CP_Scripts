# INVENTAIRE EXHAUSTIF — CP_Session

Fichier principal : `c:/Users/Cedric/AppData/Roaming/REAPER/Scripts/CP_Scripts/CP_Session/CP_Session.lua` (2604 lignes)
Dépendances lues intégralement : `CP_Engine/Loop.lua` (1304), `Cells.lua` (581), `Clip.lua` (207), `Mix.lua` (488), `Bus.lua` (132), plus `Ident.lua`, `Warp.lua`, `CP_Native/src/core/cp_lanes.cpp` pour vérifier deux affirmations du code.

Tout ce qui suit est **vérifié par lecture du code**. Les rares suppositions sont marquées.

---

## 1. LA GRILLE ET LES CASES

### Modèle
| Fonction | Où |
|---|---|
| `cells[t][s]` = descripteur CPC1 ou nil | `CP_Session.lua:84`, alloué `:91` |
| `cur[t]` = scène dont le clip est chargé | `:85` |
| 4 colonnes (`TRACKS = Loop.TRACKS`) | `:71` ← `Loop.lua:49` (`MAX_LANES // 2`) |
| 8 scènes, constante en dur | `:72` |
| Identité numérique par clip | `cellTag` `:261-265` → `Ident.Of` |
| Quelle scène une lane tient | `sceneOfLane` `:271-276` → `Ident.CellOf` |

### Les colonnes viennent du PROJET, pas de la fenêtre
- `Loop.ColumnCount()` / `ColumnAt(i)` — `:2379`, `:2395`, `:2441`, `:2474`, `:2538` ← `Loop.lua:289-290`.
- L'adoption d'une piste par un slot libre est faite par `Loop.syncColumns` (`Loop.lua:238-284`) ; éligible = piste **de premier niveau sans marque CP** (`Loop.lua:225-233`).
- Projet vide → aucune grille, message « Add a track in REAPER — a column is a track » `:2380-2387`.

### En-tête de colonne
- Nom tronqué + cache — `:2399`, cache `trackName` `:296-327` (invalidé sur pointeur, sur `known`, et sur `GetProjectStateChangeCount`).
- Clic **gauche OU droit** sur le nom → `trackMenu` `:2415-2418`.
- `trackMenu` `:331-370` : router vers n'importe quelle piste du projet (`:336-351`), « New track for this column » (`:353-356`), « Hide this column » (`:362-368`, écrit `Tracks.Mark(tr,"session","hidden")` puis `SetLaneDest(t,nil)`). **Pas d'« Unroute »**, retiré volontairement (`:356-361`).
- Rond d'armement à droite — `:2401-2412` → `armTrack`.

### Dessin d'une case (`drawCell` `:1344-1594`)
- Fond = `canvas_row` / `canvas_row_dark` `:1407`, teinté par la couleur du clip à 30 % (`CLIP_TINT` `:1337`, mélange `:1416-1421`), puis mélangé vers le rôle : record 0.42 / pending 0.30 / play 0.34 `:1422-1430`.
- Bord `:1434-1435`, coin arrondi `:1431`.
- **Bande transport à gauche**, largeur `BTN_W+6` `:1441` ; icônes Play / Stop / Record `:1456-1469` ; survol `:1446-1449`.
- Barre d'accent quand la case est « allumée » `:1471-1473`.
- Clignotement d'un lancement/arrêt en file `:1477-1482` (accent pour play, texte pour stop).
- Barre de progression `Phase(lane)/LenBeats(lane)` `:1483-1495`.
- Nom du clip + cache de troncature `:1496-1499` (`cellLabel` `:396-404`).
- Sous-titre : `audioSub` pour un son, sinon `barsLabel(cellBars)` `:1508-1509` ; remplacé par « waiting for the transport » quand le lancement attend l'horloge `:1501-1506`.
- Bloc d'enregistrement (compte à rebours) `:1514-1548`.
- Surbrillance de copie Ctrl-glisser `:1552-1559`.

### Gestes sur une case (`:1561-1593`)
| Geste | Effet | Ligne |
|---|---|---|
| Alt + clic (n'importe où) | efface la case | `:1565-1566` |
| Ctrl + clic sur une case pleine | démarre une copie glissée | `:1567-1568` |
| Clic sur la bande transport | lance / arrête / finalise une prise / démarre une prise / message | `:1571-1580` |
| Clic droit (bande ou contenu) | `cellMenu` | `:1581-1582`, `:1589-1590` |
| Clic sur le contenu | `editCell` (jamais de lancement) | `:1587-1588` |

### `cellMenu` `:1195-1229`
Edit in CP_Editor · Rename clip… · Color (8 couleurs de `Clip.COLOR_NAMES` + None) · Tempo (Repitch / Stretch / Don't follow — **seulement pour un son**, `snd` `:1207`) · Stop this track · Clear cell.

### Opérations sur les cases
| Fonction | Ce qu'elle fait | Ligne |
|---|---|---|
| `editCell` | crée un clip MIDI vide si la case est vide, arme la moitié silencieuse si le moteur ne tient pas déjà ce clip, pose `origin`/`cell`/`name`, `Bus.OpenEditor` | `:907-932` |
| `applyEdit` | réception des éditions par `Bus.Recv("editor:apply:cell")` `:2361-2362`, replace par identité, `Ident.Bind`, rafraîchit la lane qui TIENT la case | `:937-965` |
| `clearCell` | oublie l'identité, vide la case, `Loop.Clear` sur la lane porteuse | `:1089-1101` |
| `copyCell` | copie profonde des notes, efface `cell`/`origin`, `Ident.Clear` | `:1105-1123` |
| `pasteCell` | dépose la copie, écrase ce qui était là | `:1126-1132` |
| `renameCell` | `GetUserInputs`, invalide le cache de libellé | `:1134-1145` |
| `setCellColor` | index de palette (`Clip.COLORS`), nil = aucune | `:1150-1155` |
| `setCellTempoMode` + `retune` | change le mode et re-vise **la lane qui tient la case**, pas « le son de la colonne » | `:1185-1193`, `:1175-1183` |

### Longueur d'un son
`soundBars` `:584-600` : longueur déclarée → sinon boucle musicale calée sur `BAR_GRID = {0.5,1,2,4,8,16,32}` (`:561`) à ±6 % → sinon 1 mesure (one-shot, la matière boucle dans la voix). `ensureBars` `:634-639` appelée au dépôt (`:1317`), à la migration (`:1256`) et en filet de sécurité à l'armement (`:778`). `cellBars` `:624-629` accepte les fractions, plancher 0.125.

---

## 2. LE LANCEMENT ET LA QUANTIFICATION

### Réglages
- **Q** : combo `Q_ITEMS = {Off, Beat, Bar, 2 bars, 4 bars}` `:411`, conversion en beats `qIndex`/`setQIndex` `:417-433`, affiché `:2281-2282`. Vit dans le moteur (`CP_SetLaunchQ`), persisté dans le blob `Loop.Serialize` (`Loop.lua:1105`).
- **Horloge** : bascule Follow/Free `:2270-2276` → `Loop.SetFreeRun`. Allumé = suit le transport.

### `launchCell` `:819-879` — six branches
1. Case vide → message `:825-828`.
2. Lancement en file sur MA lane (`p == 1`) → on l'annule **et** on rend sa lecture au clip sortant (`Loop.Play(twin)`) `:841-844`.
3. Arrêt en file sur MA lane (`p == 2`) → on le reprend **et** on annule le clip entrant `:845-849`.
4. En train de jouer → ce clic l'arrête `:851-854`.
5. Un lancement en file sur l'autre moitié perd `:860-861`.
6. Rien à échanger → chargement direct de la moitié vivante `:863-869` ; sinon armement du jumeau + `Play(twin)` + `StopClip(live)` sur la même frontière `:871-878`.

### `armLane` `:770-807`
- Son : `ensureBars`, `soundFor` (`:552-555` → `Warp.Resolve`), `Cells.Arm` avec **quatre messages d'erreur distincts** `:776-786` (`no_engine`, `too_long`, `failed`, sinon « pas de piste »).
- Non-son : `Cells.Disarm` `:790`.
- `Loop.ApplyClip` `:797`, `SetLengthBars` `:798`, `SetLaneTag(cellTag)` `:802`, `SetMode(lane,2)` si la lane était vide `:803-805`.
- Le clip d'une note pour un son : `AUDIO_CLIP` réutilisée en place `:747-755`, note `AUDIO_NOTE=60` (`:672`), +1 pour le jumeau (`laneNote` `:673-675`), porte `AUDIO_GATE=0.97` `:679`.

### Arrêts
- `stopTrack` `:809-814` (arrête si mode 3/5, annule si `Pending==1`).
- `stopAll` `:896-898`, appelé par l'icône de barre `:2286` et par le carré global `:2471`.
- Carré par colonne `:2481-2484`, opacité selon `isRunning(liveLane(t))` `:2476`.
- « Panic: all notes off » `:2287` → `Loop.Panic`.

### Suivi du moteur
Chaque frame, `sceneOfLane(liveLane(t), t)` réaligne `cur[t]` `:2353-2356` : un lancement déclenché depuis CP_Looper ou CP_Editor est vu ici.

### Les sons sont des lanes
`Cells.Tick(AUDIO_GATE)` `:2343`. Toute la mécanique (avance d'un beat `LOOKAHEAD_BEATS`, rattrapage `CATCHUP_SNAP_S`, deux voix par moitié, bouclage de la matière quand elle est plus courte que la passe) vit dans `Cells.lua:388-513`.

---

## 3. LES SCÈNES

- 8 lignes fixes (`SCENES` `:72`), **sans nom, sans ajout, sans suppression, sans réordonnancement**.
- Lanceur de scène : triangle dans la gouttière de gauche `:2428-2438`, clic → `sceneLaunch(s)` `:2437`.
- `sceneLaunch` `:883-894` : chaque colonne qui a un clip (MIDI **ou** son) se lance, **chaque colonne qui n'en a pas s'arrête** — la sémantique Ableton d'une scène comme image complète.
- Pas de bouton « arrêter cette scène », pas de renommage de scène, pas de couleur de scène.

---

## 4. L'ENREGISTREMENT

| Fonction | Détail | Ligne |
|---|---|---|
| `isArmed(t)` | l'armement est un fait de PISTE (`% TRACKS`), pas de lane | `:977-982` |
| `armTrack(t)` | bascule, exclusif (une seule piste armée), messages | `:985-993` |
| `recCell(t,s)` | la prise va dans le jumeau si la moitié vivante est occupée ; identité mintée AVANT le clip (`Ident.NewId`) ; `SetArmedLane`, `SetLaneTag`, `SetLengthBars(rec_bars)`, `Loop.Rec`, `StopClip(live)` | `:1000-1018` |
| `pollRec()` | surveille **la lane à qui la commande a été envoyée** ; garde `seen` + `REC_PICKUP_TIMEOUT = 3.0 s` (`:1035`) ; trois sorties : commande jamais prise, prise vide (« Nothing played »), clip récupéré via `Loop.LaneToClip` + nom + id + `Ident.Bind` + `saveGrid` | `:1037-1072` |
| `stopRec()` | deuxième clic : finalise si mode 1, sinon abandonne (`Loop.Clear`) | `:1078-1087` |
| Longueur de prise | `REC_BARS = {1,2,4,8}` `:441`, combo `:2283-2284`, persistée `ProjExtState CP_Session/rec_bars` `:454`, relue `:1233-1241` | |

**Affichage** : clignotement à 5 Hz en prise / 2 Hz en attente `:1454` ; compte à rebours en beats arrondi vers le haut avec libellés précalculés `CD_LBL` `:1341-1342`, `:1518-1524` ; « PLAY / waiting for the transport » quand le transport est arrêté `:1525-1526` ; « REC + N bars » `:1527-1528` ; barre de progression de la prise `:1538-1547`.

**Ce qui n'existe pas** : l'enregistrement audio dans une case. `recCell` ne parle qu'aux lanes MIDI ; il n'y a aucun chemin de capture audio.

---

## 5. LE ROUTAGE DES COLONNES ET LE CHEMIN DU SON

- Une colonne = une paire de lanes ; le port MIDI `PORT_BASE + t` est attaché à la piste destination et **les deux moitiés y sont liées** (`Loop.lua:167-185`).
- `audioDest(t)` `:736-741` : la piste elle-même si sa chaîne ne contient **pas** d'instrument ; sinon `soundChild(t,true)`. Enregistrée auprès de Cells par `Cells.SetDestResolver(audioDest)` `:742`.
- `soundChild` `:703-726` : crée une piste **enfant de dossier** juste après la colonne, ajuste `I_FOLDERDEPTH`, la nomme « <colonne> smp », mémorise son GUID dans `ProjExtState CP_Session/smp<t>`. `samplerGuid` `:681-684`, `trackByGuid` `:687-693`.
- « Show every hidden column again » dans la barre `:2245-2257` : balaie les pistes, efface `P_EXT:CP` pour celles marquées `session/hidden`, `Loop.RefreshDests()`.
- Badge permanent du moteur : `ENGINE_BADGE` construit une fois `:381-383`, affiché dans le statut `:2561` ; diagnostic chiffré `Cells.Diag()` seulement quand il y a quelque chose à compter `:2562-2564`.

---

## 6. LE MIXER

**Structure** : une bande par colonne, alignée sur la colonne (`cx` calculé pareil `:2537`), agissant sur la piste **routée**. Tout est l'état REAPER lu/écrit par l'API REAPER (`Mix.lua`, en-tête `:1-27`).

| Élément | Ce qu'il fait / gestes | Ligne |
|---|---|---|
| Bascule de la zone | icône « Sliders » dans la barre, persistée `CP_Session/mix` | `:2261-2265`, `:1650` |
| Couture (3 points) | glisser = hauteur de la zone, `MIX_MIN`..`MIX_MAX` (620), défaut 300, persistée `mixh2` | `:2503-2533`, `:1641-1653` |
| Géométrie adaptative | les deux listes ne prennent jamais plus de `MIX_LISTS = 0.55` ; le fader prend le reste | `:1818-1862`, `:1639` |
| Chaîne FX | clic = ouvrir · Ctrl = bypass · Alt = supprimer · glisser = réordonner ou déplacer sur une autre colonne (Ctrl = copier) · clic droit = menu | `:1881-1901`, `:2125-2164` |
| Slot FX vide | clic = sélectionne la piste + ouvre le navigateur FX REAPER (40271) ; clic droit = `fxMenu(tr,nil)` | `:1902-1918` |
| Barre de défilement FX + molette | `MIX_BAR = 5` | `:1921-1940` |
| Indicateur de dépôt FX | trait d'accent sur la ligne visée | `:1943-1946` |
| Envois | chaque ligne EST son niveau : glisser = niveau, clic sans glisser = fenêtre de routage REAPER (40293), clic droit = mute/remove | `:1958-2005` |
| Slot d'envoi vide | glisser vers une autre colonne = crée l'envoi ; clic = liste les destinations | `:1998-2002`, `:2165-2188` |
| Pan | `MIX_PAN = 12`, détente au centre (`Mix.SetPan` `Mix.lua:137`) | `:2029-2045` |
| Fader + VU | vertical `MIX_FADW = 21`, VU `MIX_MET = 11` avec hold ; reset quand la colonne n'est pas routée | `:2047-2083` |
| Lecture en dB | ligne propre sous le fader | `:2084-2093` |
| M / S | lettres, Ctrl-clic sur S = exclusif | `:2095-2110` |
| « Étouffé » | mute propre OU solo d'un autre (`Mix.AnySolo`) | `:1810-1816` |
| Surbrillance de dépôt | quand un FX ou un envoi est porté au-dessus d'une autre colonne | `:2112-2119` |

`fxMenu` `:1708-1735` (Open / Bypass / Delete / FX browser REAPER / CP_FX Browser via `Bus.FocusApp` / chaîne FX de la piste).
`sendMenu` `:1737-1768` (Mute / Remove / « Send to <colonne> » pour chaque autre colonne routée).
Un point d'annulation par geste, seulement si le geste a fait quelque chose (`mix_moved` `:2062-2067`).

---

## 7. LE GLISSER-DÉPOSER

- Enregistrement DragBus paresseux + `RectSync` chaque frame `:1271-1274`, désinscription à la fermeture `:2594`.
- `busConsume()` `:1270-1322` :
  - **FX** (`kind == "fx"`) → tombe dans la CHAÎNE de la bande survolée `:1279-1295`.
  - **Clip / fichier** → `Bus.TakeDrop` promeut un `kind="file"` en clip audio (`Bus.lua:52-58`) ; l'index de dessin est retraduit en slot par `Loop.ColumnAt` `:1305` ; arrêt de la piste si on remplace ce qui joue `:1312` ; `ensureBars` `:1317` ; `saveGrid` ; message.
- **Un dépôt ne lance jamais** (commentaire `:1268`).
- Copie Ctrl-glisser interne à la grille : `cdrag` `:86`, marquage `:1567`, résolution `:2447-2458`.
- Le CP_Session **ne publie rien** sur DragBus (aucun `Bus.BeginClip` / `DragBus.Begin`) : on peut déposer dedans, pas glisser depuis.

---

## 8. LES MENUS ET LA BARRE DE COMMANDE

Barre `:2238-2289` :
- Droite : `?` (aide `HELP_TEXT` `:109-241`) · « Show every hidden column again » · bascule Mixer.
- Gauche (seulement si le moteur est attaché) : bascule Clock · combo Q · combo Rec · séparateur · Stop every clip · Panic.

Quatre menus contextuels : `trackMenu` `:331`, `cellMenu` `:1195`, `fxMenu` `:1708`, `sendMenu` `:1737`.

**Aucun raccourci clavier** : `grep Key|Shortcut|Char(` sur le fichier ne rend rien.

---

## 9. L'ÉTAT PERSISTÉ

**ProjExtState (dans le .RPP)**
| Section / clé | Contenu | Écrit / lu |
|---|---|---|
| `CP_Session/grid` | toutes les cases, une ligne `t:s:CPC1…` | `saveGrid` `:480-491` / `loadGrid` `:493-507` |
| `CP_Session/rec_bars` | longueur de prise | `:454` / `:1233-1241` |
| `CP_Session/smp<t>` | GUID de la piste enfant « smp » | `:724` / `:682` |
| `CP_Session/audio1..4` | **hérité**, migré une fois puis effacé | `:1246-1264` |
| `CP_Loop/dest<lane>` | destination de chaque lane par GUID | `Loop.lua:145-147` |
| `CP_Loop/data` | blob de rappel (v5 : freerun, lane armée, launchQ, puis par lane bars/mute/mode/notes) | `Loop.lua:1102-1188` |
| `CP_Loop/armed` | lane armée | `Loop.lua:607` |
| `CP_Ident/next` | compteur d'identités | `Ident.lua:91-96` |

**ExtState global (préférences)**
`CP_Session/mix` `:1650`, `CP_Session/mixh2` `:1653` + géométrie de fenêtre via `UI.Init(..., persist="CP_Session")` `:2581-2584`.

**Sauvegarde** : `Loop.AutoSave()` chaque frame (débounce 0,4 s, `Loop.lua:1285-1302`) `:2339` ; `Loop.SaveState` à la fermeture `:2589` et sur `r.atexit` `:2599` ; `Cells.Destroy` à la fermeture `:2592`.

**Rappel** : un seul coup après le premier attachement `:2195-2233` — recharge si toutes les lanes sont vides, **puis réarme les voix des cases son avant que quoi que ce soit puisse sonner** `:2214-2227`, puis `Loop.AdoptState()` `:2232`.

---

## 10. LE RAPPORT AU TRANSPORT DE REAPER

- `Loop.Poll()` `:2336` fait tout : `CP_ClockSync` puis `CP_TransportSync(tempo, QN de la position du bloc traité, playing, ts)` (`Loop.lua:1017-1020`), résolution des moitiés vivantes, capture MIDI, rafraîchissement des destinations débouncé à 0,5 s.
- Deux horloges, un seul comportement (aide `:211-233`) : en Follow, un lancement sans transport attend le transport (`PendingWaitsClock` `Loop.lua:679-681`, affiché `:1501-1506`) ; en Free, la première case lancée EST le temps fort.
- Ligne de statut PLAY/STOP + BPM, recalculée seulement quand l'un des deux change `:461-474`.
- Demandes de redessin : dès que le moteur joue ou qu'un VU tombe encore `:2571-2575`.
- Le solo est celui de REAPER : l'arrangement se tait aussi (`Mix.lua:179-194`, dit dans l'aide `:192-193`).

---

# CE QUI EST DÉCLARÉ ET JAMAIS UTILISÉ

## A. Champs et fonctions sans lecteur ni appelant

1. **`Clip.lmode`** (`Clip.lua:25`, écrit `:38` et `Loop.lua:1047`, sérialisé `Clip.lua:141`) — **aucun lecteur dans tout le dépôt**. Confirmé : le seul autre `lmode` du dépôt est une variable locale sans rapport dans `CP_Editor.lua:3300`.
2. **`Clip.q`** (`Clip.lua:24`, écrit `:37` et `Loop.lua:1046`, sérialisé `:141`) — même chose. La quantification réelle est un réglage **global du moteur** (`Loop.GetLaunchQ`), jamais une propriété de clip. Deux octets par case dans le .RPP pour rien, et un champ qui promet un réglage par clip que rien n'implémente.
3. **`Cells.Retune(t, lane, rate)`** (`Cells.lua:258-262`) — zéro appelant. Le `retune` local de la session (`:1175-1183`) passe par `Cells.Arm`, qui ne recharge que si le chemin a bougé — la fonction dédiée n'a jamais servi.
4. **`Cells.Available()`** (`Cells.lua:137`) — zéro appelant ; la session utilise la valeur de retour de `Cells.init` (`:82`).
5. **`Cells.LastOnsetError(t, lane)`** (`Cells.lua:521-530`) — zéro appelant. C'est le seul instrument de mesure « ce qu'on a demandé vs ce qui a été joué » du module, et rien ne l'affiche : `Cells.Diag()` (`:532-547`) ne l'appelle pas.
6. **`state.arow`** (`CP_Session.lua:98`, « audio-cell row geometry ») — reliquat de l'ancienne rangée « A » fixe ; plus jamais écrit ni lu.
7. **`Loop.SetLaneAudio()` / `Loop.GetLaneAudio()`** (`Loop.lua:651-652`) — no-ops sans aucun appelant dans le dépôt.
8. **`Loop.SetAudioRun` / `GetAudioRun`** (`Loop.lua:577-581`) — aucun appelant. Le champ correspondant du moteur (`audio_run_`, `cp_lanes.cpp:37`, lu `:628` pour tenir l'horloge libre) reste donc à 0 en permanence. Devenu inutile quand les sons sont devenus des lanes, mais ni retiré ni documenté comme tel.
9. **Sans appelant dans `Loop.lua`** : `SyncSends` (`:304`), `Reattach` (`:318`), `TrackName` (`:326`), `EngineAlive` (`:428`), `EngineLanes` (`:429`), `EngineBuild` (`:430`), `ENGINE_BUILD` (`:431`), `ReloadEngine` (`:434`), `ToggleRec` (`:550`), `IsAdopted` (`:1270`), `Beat` (`:757`), et **`NOTE_STRIDE`** (`:48`) — dont le commentaire dit « kept: callers use it » alors qu'aucun appelant n'existe.
10. **`Loop.InitCount()`** (`:433`) retourne toujours 0 → la branche de CP_Looper qui le lit (`CP_Looper.lua:1611`) est morte là-bas aussi.
11. **`Mix.ShortFxName`** (`Mix.lua:329`) — alias exporté, aucun consommateur externe.
12. **`Warp.Retry`** (`Warp.lua:172`) et **`Warp.Pending`** (`:177`) — aucun appelant. Conséquence concrète : une case qui affiche « audio · warp failed » (`WARP_SUB.failed`, `:611`) n'a **aucun moyen d'être réessayée** — `failed[key]` est permanent pour la session (`Warp.lua:106-107`).
13. **Clé persistante `mixh`** — remplacée par `mixh2` (`:1651-1653`) ; l'ancienne reste dans le fichier de préférences, jamais relue.

## B. Branches inatteignables

14. **`Loop.RouterChanged()` retourne toujours `false`** (`Loop.lua:1268`). Donc dans `frame()` : `switched` `:2205` est toujours faux, `or switched` `:2206` n'ajoute rien, et **`Loop.LoadState(true)` `:2212` ne s'exécute jamais**. Seule la branche `elseif empty and HasSavedState()` peut tourner.
15. **`if not Loop.EngineCurrent()` `:2326-2331` est inatteignable.** `EngineCurrent()` et `IsAttached()` retournent tous deux `NATIVE` (`Loop.lua:427` et `:432`), et on est déjà sorti par `return` `:2312` si `attached` est faux. Le message « The CP engine extension is missing — MIDI lanes and sound cells both need it » ne peut jamais être dessiné.
16. **Le bloc `state.engine_checked` `:2321-2325` est un no-op.** `Loop.Ensure(false)` (`Loop.lua:501-511`) rend `true, nil` dès que `NATIVE` ; le `note` est donc toujours nil et le `flash` ne part jamais.
17. **Le bouton « Create looper engine » `:2309-2311` ne peut jamais réussir.** Il n'est dessiné que si `NATIVE` est faux ; il repasse par `Loop.Ensure(true)` `:2300`, qui teste `if not NATIVE then return false, msg end` **avant** de regarder `create` (`Loop.lua:502-505`). Il réaffiche donc le même message à l'infini. La ligne `attached = Loop.IsAttached()` `:2302` est toujours fausse.
18. **Conséquence de 17 : `Loop.Setup()` est inatteignable depuis CP_Session.** Or Setup fait trois choses que rien d'autre ne fait ici :
    - `Loop.MigrateLegacy()` (`Loop.lua:486`) — **retirer la piste routeur d'un ancien projet**. Un projet de l'époque routeur ouvert uniquement dans CP_Session garde son `CP_MidiLooper.jsfx` armé, qui rejoue le même set en parallèle : exactement le symptôme que `Loop.lua:436-448` décrit comme « un instrument cassé plutôt qu'un reliquat ». Seul `CP_Looper.lua:191` appelle `Setup`.
    - `Loop.SetLaunchQ(Loop.TsNum())` (`Loop.lua:497`) — le défaut « une mesure, comme dans Ableton ». Le défaut du moteur est `launch_q_(0.0)` = **Off** (`cp_lanes.cpp:37`). Sur une session REAPER fraîche, avec un projet sans blob sauvegardé, ouvrir CP_Session seul donne donc **Q: Off**, alors que toute la section « Clock, and what a launch waits for » de l'aide (`:211-233`) raisonne sur Q: Bar. (Le réglage est global au processus, donc l'effet ne se voit qu'à la première fenêtre d'une session REAPER.)
    - `Loop.SetArmedLane(nil)`.
19. `MIX_ROWS = 24` (`:1634`) borne les tables d'identifiants d'envois ; le garde `i <= MIX_ROWS` `:1962` fait qu'un envoi d'index > 24 est dessiné comme un **slot vide** au-dessus d'un envoi réel. Cas limite, mais la branche est écrite comme si elle était impossible.

## C. Documentation qui décrit un code qui n'existe plus

20. **Aide `:169-179`** : « Each column that plays a sound grows a SAMPLER track » — faux depuis `audioDest` (`:736-741`) : une colonne **sans instrument** reçoit le son directement et ne crée aucune piste.
21. **Aide `:175-178`** : « The trigger travels on a channel of the column's own (9 to 12), and **the router** feeds each destination one filtered channel » — le routeur, les canaux 9-12 et l'envoi filtré n'existent plus (`Loop.lua:3-31`, `Cells.lua:1-20`).
22. **Aide `:116`** : « Click a column's NAME to choose that track, make a new one, **or unroute it** » — l'option a été retirée volontairement (`:356-361`).

---

# DÉFAUTS TROUVÉS EN CHERCHANT LE CODE MORT

Ce ne sont pas des « manques », ce sont des écarts vérifiables entre ce que le code fait et ce que ses propres commentaires affirment.

### 1. Le clip d'une note d'une case son est bien envoyé à l'instrument de la colonne
`armLane` `:797` applique `AUDIO_CLIP` (note 60/61, vélocité 127) à la lane, et le commentaire `:791-796` affirme : « now nobody hears it at all […] deux fils qui ne se rencontrent jamais ». Or `Loop.bindPort` attache le port `PORT_BASE + t` à **la piste destination de la colonne** et y lie les deux moitiés (`Loop.lua:167-185`), et `Lanes::run_gate` émet un vrai note-on sur ce port dès que la lane joue et n'est pas mutée (`cp_lanes.cpp:479-559`). CP_Session n'appelle jamais `Loop.SetMute` sur une lane (vérifié : le seul `SetMute` du fichier est `Mix.SetMute` `:2105`).
Donc : colonne **sans** instrument → inaudible (le commentaire tient) ; colonne **avec** instrument — le cas que `audioDest` `:736-741` traite explicitement en créant une piste enfant — → l'instrument reçoit un do central pendant `bars × ts × 0.97` beats à chaque passe. Les deux fils se rencontrent sur le port de la colonne.

### 2. `audioSub` ouvre un fichier sur le disque à chaque frame, pour chaque case en stretch
`:613-619` appelle `Warp.State` à chaque frame de dessin. `Warp.State` (`Warp.lua:118-126`) appelle `Warp.PathFor` — deux `string.format` + un `gsub` + une boucle FNV octet par octet sur une clé qui contient le chemin complet (`Warp.lua:85-92`) — puis `fileExists`, qui est un `io.open` (`Warp.lua:94-99`). Le commentaire juste au-dessus (`:605`) dit « Five fixed strings, chosen from per frame: no allocation on a draw path » : c'est vrai des cinq chaînes, faux de ce qui les choisit. Contre la contrainte « zéro allocation par frame dans le dessin, PC de 2005 ». Ne concerne que les cases dont `tempo_mode == "stretch"` (`:614-615`).

### 3. Collision de clés dans le cache de troncature `cell_lbl`
`cellLabel` calcule `k = t * SCENES + s` (`:397`). L'en-tête de colonne appelle `cellLabel(t, SCENES, …)` `:2399` → `k = t*8 + 8`. La case (t+1, scène 0) appelle `cellLabel(t+1, 0, …)` `:1498` → `k = (t+1)*8 = t*8 + 8`. **Même emplacement.** Les deux ont des textes et des largeurs différents (`cell_w - 22` vs `w - bw - 6`), donc chacun invalide l'autre : deux `Core.TruncateText` par colonne et par frame, dans le chemin de dessin, dès que la case de la scène 1 de la colonne suivante contient un clip. Le commentaire `:277-280` promet exactement l'inverse (« zero allocation per frame: strings rebuilt only when the underlying fact changes »).

### 4. `stopTrack` n'annule pas un lancement en file sur le jumeau
`stopTrack` `:809-814` ne regarde que `liveLane(t)`. Quand un échange est en file, les deux moitiés sont « busy » et `resolveLive` (`Loop.lua:706-715`) ne bascule pas — `live[t]` reste la moitié qui sonne. Le carré de la colonne, « Stop every clip » et la branche `else` de `sceneLaunch` `:891` arrêtent donc le clip sortant **et laissent le clip entrant démarrer à la frontière**. `launchCell` réconcilie explicitement la paire (`:836-849`) ; les trois autres chemins d'arrêt ne le font pas.

### 5. Annuler une prise en file laisse la piste muette
`recCell` `:1015` pose `Loop.StopClip(live)` pour que le clip sortant parte sur la même frontière que la prise. `stopRec` `:1082-1086` ne fait que `Loop.Clear(rec.lane)` : l'arrêt en file du clip sortant reste armé. Résultat : on annule une prise qu'on n'avait pas voulue, et la colonne s'arrête quand même. Asymétrie directe avec `launchCell` `:841-844`, qui rend sa lecture au clip sortant dans le cas jumeau.

### 6. Un FX peut être déposé sur le mixer fermé
La branche FX de `busConsume` `:1279-1295` teste les rectangles `mix_col[t]` sans vérifier `mix_open`. Ces rectangles ne sont écrits que par `drawMix` `:1808`, lui-même appelé uniquement quand la zone est ouverte `:2494-2540`. Après une ouverture puis une fermeture, ils restent valides et couvrent la partie basse de la fenêtre : un FX lâché là est ajouté à la chaîne d'une colonne, sans qu'aucune bande ne soit visible. (Même remarque, plus bénigne, pour un `fxdrag`/`snddrag` en cours au moment où l'on ferme la zone : `pollMixDrag` `:2542` ne tourne plus et le glissé survit jusqu'à la prochaine ouverture.)

### 7. Aucune annulation sur les opérations de case
`clearCell`, `pasteCell`, `renameCell`, `setCellColor`, `setCellTempoMode` et le dépôt écrivent tous par `saveGrid` → `SetProjExtState` (`:480-491`), **sans `Undo_BeginBlock`**. Alt-clic efface une case définitivement. Par contraste, `Loop.SetLaneDest` / `NewDestTrack` (`Loop.lua:334-364`) et toutes les écritures du mixer (`Mix.lua`) créent des points d'annulation.

### 8. Deux réglages voisins, deux domiciles
Q vit dans le moteur et est persisté dans le blob `CP_Loop/data` (`Loop.lua:1105`) ; Rec vit dans `CP_Session/rec_bars` (`:454`). Les deux combos sont côte à côte dans la barre `:2281-2284` et l'aide les présente comme une paire (`:2277-2280`) ; ils ne survivent pas aux mêmes gestes ni aux mêmes projets.

### 9. Coûts par frame dépendant du compteur de changements du projet
`trackName` `:309-310` et les caches de `Mix` (`chainOf` `Mix.lua:331-348`, `sendsOf` `:405-427`) sont indexés sur `GetProjectStateChangeCount(0)`. **Supposition** (non vérifiable par lecture seule) : `SetMediaTrackInfo_Value` incrémente ce compteur. Si c'est le cas, tout glissement de fader ou de pan invalide, à chaque frame du geste, le nom de chaque colonne et **tous** les noms de FX et d'envois de toutes les bandes — soit une reconstruction complète de deux tables de chaînes par frame, exactement pendant le geste le plus fréquent du mixer.

### 10. Plafonds en dur
`SCENES = 8` (`:72`) et `TRACKS = 4` (`:71` ← `Loop.MAX_LANES = 8`). `Loop.lua:42-46` dit que le moteur en sert 32 et que « raising it is one line here » — mais `cells` (`:91`), `mix_id` (`:1664-1672`), `fx_lbl`/`sd_lbl`/`mix_scroll` (`:1679-1684`) sont tous préalloués sur `TRACKS`, et le nombre de scènes n'est ni réglable ni persisté.