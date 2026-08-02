# API du moteur CP — contrat de référence

Document de référence. Il dit **ce qu'on appelle, avec quelles unités, depuis
quel fil, et ce qui se passe quand ça rate**. Il ne dit pas pourquoi le moteur
existe — c'est `ARCHI_MoteurNatif.md` — ni comment il est construit — c'est
`CP_Native/README.md`.

---

## 0. La règle qui prime sur tout le reste

> **Une fenêtre appelle `CP_Engine/Voice.lua`. Jamais `reaper.CP_*` directement.**
>
> **Et pour faire entendre un fichier à quelqu'un, elle appelle
> `CP_Engine/Audition.lua`** — qui est bâti sur `Voice`, et qui choisit.

`CP_*` est l'ABI brute de l'extension. Elle est plate, ennuyeuse et stable par
conception — un ABI qu'on renégocie est un cauchemar. `Voice.lua` est la couche
que les fenêtres utilisent : elle porte le repli quand l'extension est absente,
elle arrondit ce qui doit l'être, et elle contient **l'unique** `if natif then`
de toute la suite.

Écrire `if reaper.CP_VoiceAlloc then` dans une fenêtre, c'est refaire exactement
la faute qu'on répare : chaque fenêtre possédant sa propre version d'une capacité
partagée.

---

## 1. Ce que le moteur sait, et ce qu'il ne saura jamais

Il connaît des **voix** et des **frames absolus**. Rien d'autre.

Pas de scène, pas de colonne, pas de cellule, pas de beat, pas de tempo, pas de
transport. La carte de tempo reste en Lua, sur le fil principal, où `TimeMap2_*`
la résout exactement — et gratuitement.

Une commande ne dit donc **jamais** « joue maintenant ». Elle dit « joue au
frame N ». La frontière se **décide** en Lua (c'est une décision musicale) et se
**tire** dans le fil audio (c'est de la physique).

### Les unités, une fois pour toutes

| grandeur | unité | remarque |
|---|---|---|
| instant de commande | **frame absolu** (entier) | jamais une seconde, jamais un beat |
| position de lecture | **frame source** (fractionnaire) | dans le clip, pas dans le projet |
| durée de fondu | **seconde** | convertie en frames par le moteur |
| gain | **linéaire** | 1.0 = unité |
| pan | **−1 … +1** | balance, unité au centre |
| taux | **multiplicateur** | 1.0 = vitesse d'origine |

Un frame absolu fractionnaire n'a aucun sens. `Voice.lua` arrondit à sa
frontière ; ne laissez jamais circuler un fractionnaire.

---

## 2. `CP_Engine/Voice.lua` — la couche que les fenêtres utilisent

```lua
local Preview = dofile(cp_root .. "CP_Engine/Preview.lua")
local Voice   = dofile(cp_root .. "CP_Engine/Voice.lua")
Preview.init(r)
Voice.init(r, Preview)          -- rend true si le moteur natif est là
```

### 2.1 Capacités — on commence toujours par là

Une fenêtre interroge une **capacité**, jamais un backend.

| appel | rend | sert à |
|---|---|---|
| `Voice.Available()` | bool | y a-t-il un moyen de faire du son |
| `Voice.CanScheduleExact()` | bool | **sait-on dater un lancement à l'échantillon** |
| `Voice.MaxVoices()` | nombre | 256 en natif, **1** en repli |
| `Voice.CanRouteToTrack()` | bool | le son peut-il traverser une chaîne de piste |
| `Voice.CanPitchShift()` | bool | **transposer sans changer la durée** — false en natif |
| `Voice.CanTimeStretch()` | bool | **étirer sans changer la hauteur** — false en natif |
| `Voice.Backend()` | `"native"` / `"preview"` | diagnostic seulement |
| `Voice.Diag()` | chaîne | état du moteur en une ligne |

`CanPitchShift` et `CanTimeStretch` rendent **false en natif, et c'est une
décision, pas un manque** : l'étireur de REAPER coûte 2,3 % du fil audio par voix
et exige 85 à 139 ms d'amorçage. Le taux natif est un varispeed — il change les
deux, comme un échantillonneur. Un appelant qui a besoin de l'un des deux le
demande et emprunte l'autre chemin ; c'est exactement ce que fait `Audition`.

Le motif attendu dans une fenêtre :

```lua
if Voice.CanScheduleExact() then
    Voice.PlayAtBeat(v, clip, prochaine_mesure, opts)   -- exact
else
    Voice.Play(v, clip, opts)                            -- immédiat, c'est tout
end
```

**Le repli déclare honnêtement ses limites.** `CF_Preview` est un singleton :
`MaxVoices()` rend 1 et `CanScheduleExact()` rend false. Un appelant sait ce
qu'il n'a pas au lieu de le découvrir en production.

### 2.2 Horloge

| appel | rend | note |
|---|---|---|
| `Voice.Sync()` | — | **une fois par frame**, avant toute conversion |
| `Voice.Now()` | frame | frame absolu courant |
| `Voice.Srate()` | Hz | taux du moteur |
| `Voice.TimeToSample(t)` | frame entier | instant projet (s) → frame |
| `Voice.BeatToSample(beat)` | frame entier | via `TimeMap2_QNToTime` |

`Sync()` prend l'ancre entre le temps du projet et celui du moteur : deux
lectures collées, dont l'écart vaut quelques microsecondes — pas une frame de
defer (16 à 74 ms). **Sans `Sync()` régulier, les conversions dérivent.**

### 2.3 Matière

| appel | rend | note |
|---|---|---|
| `Voice.Load(path)` | identifiant, ou **nil + raison** | décode en RAM au taux du moteur |
| `Voice.Unload(clip)` | — | mémoire rendue après deux blocs audio |
| `Voice.ClipInfo(clip)` | durée_s, canaux, taux | ou nil |

Raisons possibles de `Load` : `"too_long"`, `"failed"`, `"no_path"`. **« Trop
long » et « illisible » ne sont pas la même phrase** — un appelant qui ne peut
pas les distinguer finit par dire « fichier illisible » à propos d'un fichier
parfaitement lisible.

L'identifiant est **opaque** : un slot en natif, le chemin en repli. Ne
l'interprétez jamais.

Le décodage passe par les `PCM_source` de REAPER : **aucun format n'est perdu**,
et le clip est stocké prêt à lire, donc une lecture à taux 1,0 est une copie
bit-exacte. Coût mesuré : 27 ms pour 8 secondes de stéréo.

**Plafond : 64 s par clip.** Décision produit du 2026-07-31 (des boucles, pas
des stems). `Load` rend nil au-delà.

### 2.4 Ports — une colonne, une piste

| appel | rend | note |
|---|---|---|
| `Voice.BindTrack(port, track)` | bool | **idempotent** |
| `Voice.BindOutput(port, outchan)` | bool | **sortie matérielle, sans piste** |
| `Voice.OutputActive(port)` | bool | ce port a-t-il une sortie |
| `Voice.UnbindTrack(port)` | — | reprend aussi les voix du port |

Le son entre **pré-FX** : il traverse la chaîne d'effets de la piste, son fader,
son VU et ses envois (mesuré — une réverbe sur la piste s'applique bien). Rien
n'est inséré dans la chaîne de l'utilisateur.

`BindOutput` n'est pas du confort : c'est le comportement par défaut d'un
navigateur de fichiers, qui écoute avant de choisir une piste.

**`Voice.Alloc` refuse sur un port sans sortie.** Son anneau n'étant jamais
drainé, la voix ne sonnerait jamais *et* ne pourrait jamais être rendue. La
réponse honnête est « il n'y a pas de sortie », pas « plus de voix ».

**`Voice.AUDITION_PORT` (31) est réservé** à l'audition, partagé par toute la
suite. Il n'y a aucune raison que trois fenêtres ouvrent chacune leur sortie
pour faire la même chose.

### 2.5 Voix

| appel | rend | note |
|---|---|---|
| `Voice.Alloc(port)` | handle, ou nil | |
| `Voice.Release(h)` | — | toute commande ultérieure sur ce handle est ignorée |
| `Voice.Play(h, clip, opts)` | bool | **immédiat** — l'audition |
| `Voice.PlayAtSample(h, clip, at, opts)` | bool | **daté**, exact à l'échantillon |
| `Voice.PlayAtTime(h, clip, t, opts)` | bool | idem, en secondes projet |
| `Voice.PlayAtBeat(h, clip, beat, opts)` | bool | idem, en beats |
| `Voice.Stop(h, fade)` | — | immédiat, fondu 5 ms par défaut |
| `Voice.StopAtSample(h, at, fade)` | bool | **daté** ; fade 0 = coupure nette |
| `Voice.QueueNext(h, next_h, xfade)` | bool | enchaînement exact |
| `Voice.Set(h, param, value)` | bool | à la volée |
| `Voice.Seek(h, pos_frames)` | bool | déplace la tête, en frames source |
| `Voice.SetLoop(h, on)` | bool | **à la volée** — ne repart pas du début |
| `Voice.State(h)` | état, position | **deux valeurs**, pas une table |
| `Voice.IsPlaying(h)` | bool | |
| `Voice.StartedAt(h)` | frame, ou −1 | attaque réelle, sans course |
| `Voice.Panic()` | — | tout couper en 5 ms |

`opts` (toutes optionnelles) : `rate`, `gain`, `loop`, `pan`, `fade_in`,
`fade_out`, `offset`. **Réutilisez la même table** si vous appelez par frame.

`param` de `Set` : `rate`, `gain`, `pan`, `loop_start`, `loop_end`, `fade_in`,
`fade_out`, `pos`, `loop`. En repli, seuls `gain` et `rate` existent.

**`offset` est posé APRÈS le lancement, et c'est volontaire.** L'anneau de
commandes est FIFO : les deux tombent dans le même bloc audio, dans l'ordre
d'écriture. Le lancement remet la tête au début, le déplacement la pose où on
veut, et le premier échantillon audible est déjà le bon.

États : `Voice.IDLE` 0, `Voice.SCHEDULED` 1, `Voice.PLAYING` 2,
`Voice.STOPPING` 3.

**`QueueNext` n'est pas une commodité.** Legato, fondu croisé sur la frontière et
fin exacte d'un one-shot ont une fenêtre d'**un bloc** — 1,33 ms à 64
échantillons. Une frame de defer en vaut 16 à 74. Lua ne peut structurellement
pas les tenir ; c'est pour cela que le moteur possède un emplacement « suivant »
par voix.

**`StartedAt` plutôt qu'un calcul externe.** Déduire l'attaque de
(horloge − position) se trompe d'un bloc quand la lecture tombe entre le pull de
l'aperçu et le passage *post* du hook. La voix note son propre instant : aucune
course.

### 2.6 Performance — ce que ce module s'interdit

Il est appelé depuis des boucles de dessin, donc : **handles entiers, jamais de
tables**, `State()` rend plusieurs valeurs, registre préalloué, aucune
concaténation hors messages d'erreur.

---

## 2bis. `CP_Engine/Audition.lua` — faire entendre un fichier à quelqu'un

Le navigateur, l'éditeur et le sampler font exactement le même geste — on clique,
ça sonne — et chacun l'écrivait à sa façon. C'est le premier défaut recensé dans
`ANALYSE_Ecosysteme`, et ce module est la capacité qui manquait.

**Il choisit, à chaque lancement**, entre une voix CP et `CF_Preview`. Le choix
ne demande jamais « es-tu natif » : il demande `CanPitchShift()` et
`CanTimeStretch()`. Le jour où le moteur saura le faire, ce module n'a pas une
ligne à changer.

| | ce qu'il apporte |
|---|---|
| **voix CP** | exacte à l'échantillon, ne s'affame jamais (15 009 appels pour 15 009 blocs à 64), joue depuis la RAM |
| **`CF_Preview`** | transpose, étire, **lit depuis le disque** — donc pas de plafond de durée |

```lua
local Audition = dofile(cp_root .. "CP_Engine/Audition.lua")
Audition.init(r)
```

Surface : `Play(path, opts)`, `Stop`, `IsPlaying`, `Progress`, `SeekFrac`,
`SetVolume/SetPitch/SetRate/SetLoop`, `SetOutputTrack`, `Prefetch`, `Tick`,
`Destroy` — plus `Meta`, `SourceType`, `GetSource`, `TempoSyncRate`, délégués,
pour qu'une fenêtre n'ait **qu'un seul module** à charger.

Champs persistants : `volume`, `pitch`, `rate`, `loop`, `fade_in`, `fade_out`,
`route_track`, `out_track`, `playing_path`.

**`Tick()` une fois par frame.** Il prend l'ancre horloge↔projet et rend la
mémoire des clips retirés.

### Ce que ça coûte, écrit plutôt que découvert

Une voix CP joue depuis la RAM : il faut **décoder avant d'entendre**, environ
**3,4 ms par seconde de stéréo**. Un one-shot de deux secondes coûte 7 ms — moins
qu'une frame de dessin. Trente secondes en coûteraient 100, ce qui s'entend comme
une hésitation.

D'où deux réglages, isolés en tête de fichier pour se déplacer en une ligne après
une écoute : `NATIVE_MAX_S` (15 s, au-delà on laisse `CF_Preview` lire depuis le
disque) et `warm_prefetch` (on préchauffe les voisins de la sélection, la ruse
qui existait déjà pour les `PCM_source`). `Audition.last_load_ms` dit ce que le
décodage a réellement coûté sur **cette** machine.

---

## 3. `reaper.CP_*` — l'ABI brute

À n'appeler que depuis `Voice.lua`, ou depuis une sonde.

### 3.1 Le garde, obligatoire

```lua
if not reaper.APIExists("CP_EngineABI") then return end
if reaper.CP_EngineABI() < 1.8 then return end   -- un MINIMUM, pas une égalité
```

**ReaPack n'a aucun mécanisme de dépendance** — mesuré : 89 index, 5993 paquets,
zéro élément de dépendance. Un script peut donc s'installer sans le binaire. Sans
ce garde, la fenêtre explose sans un mot.

Politique de version : **un ajout lève la mineure, un changement de signature
lèverait la majeure.** Les scripts exigent un minimum, jamais une égalité —
sinon chaque ajout casse tout le monde.

### 3.2 Surface

| fonction | rend |
|---|---|
| `CP_EngineABI()` | version de l'ABI |
| `CP_Srate()` | taux du moteur |
| `CP_ClipLoad(path)` | identifiant, **−1 illisible, −2 au-delà de 64 s** |
| `CP_ClipUnload(clip)` | — |
| `CP_ClipInfo(clip)` | ok, frames, srate, nch |
| `CP_PortAttach(track, port)` | bool, idempotent — sortie **piste**, pré-FX |
| `CP_PortAttachOut(port, outchan)` | bool, idempotent — sortie **matérielle** |
| `CP_PortActive(port)` | bool |
| `CP_PortDetach(port)` | — |
| `CP_PortGain(port, gain)` | — |
| `CP_PortMidiAt(port, at, status, d1, d2)` | **1.8** — un message MIDI brut dans la piste de ce port, et nulle part ailleurs. `at < 0` = maintenant |
| `CP_VoiceAlloc(port)` | handle, ou 4294967295 |
| `CP_VoiceRelease(v)` | — |
| `CP_VoicePlayAtSample(v, clip, at, mode, rate, gain)` | bool |
| `CP_VoiceStopAtSample(v, at, fade)` | bool — `at < 0` = **maintenant**, en fondu ; sinon la coupure tombe exactement à `at` |
| `CP_VoiceSet(v, param, value)` | bool |
| `CP_VoiceQueueNext(v, next, xfade)` | bool |
| `CP_VoiceState(v)` | ok, pos, état |
| `CP_VoiceStartedAt(v)` | frame, ou −1 |
| `CP_ClockNow()` | frame absolu |
| `CP_ClockSync()` | frame ; prend l'ancre |
| `CP_ClockPos()` | **1.7** — la position projet que cette ancre a retenue |
| `CP_PlayRate()` | **1.7** — la vitesse de lecture que cette ancre a retenue |
| `CP_TimeToSample(t)` | frame **fractionnaire** — arrondir |
| `CP_Panic()` | — |
| `CP_Diag()` | état en une ligne |

`mode` : 0 = une fois, 1 = boucle.

#### L'ancre, et les deux erreurs qu'elle a coûtées (ABI 1.7)

L'horloge du moteur compte les échantillons **déjà produits** : elle avance dans
le hook audio, au passage POST. Elle doit donc être appariée à une position sur
la **même ligne de temps**, et c'est `GetPlayPosition2` — « position of next
audio block being processed ». `GetPlayPosition`, lui, est documenté par REAPER
comme la position *latency-compensated actual-what-you-hear* : l'apparier à
l'horloge décale tout ce qui est daté ensuite de la **latence de sortie du
périphérique**. Mesuré sur un clip de quatre noires : jusqu'à 28 ms de retard,
constant, sans dérive. Le JSFX n'avait pas ce défaut parce qu'il n'avait pas
d'ancre — il vivait dans la chaîne audio, où le temps de traitement est le seul
qui existe.

Deuxième moitié : les deux lectures se font sur le fil principal pendant que le
fil audio tourne, donc un bloc peut tomber entre elles — 5,8 ms à 256
échantillons. `take_anchor()` encadre la lecture de position par deux lectures
d'horloge et recommence si elle a bougé. Un seqlock côté lecteur.

**Conséquence pour un appelant** : ne jamais relire `GetPlayPosition*`
soi-même pour publier quelque chose sur la ligne de temps du moteur. Appeler
`CP_ClockSync()`, puis lire `CP_ClockPos()`. C'est ce que fait `Loop.Poll()`,
et `CP_TransportSync` se raccroche à la paire déjà validée plutôt que de relire
l'horloge.

**Et la vitesse de lecture fait partie de l'ancre.** Une seconde de projet ne
vaut pas une seconde d'échantillons dès que la réglette n'est pas à 1.0 :
`CP_TimeToSample` divise par le taux, et `CP_TransportSync` le transmet aux
lanes, qui avancent leur beat au tempo **fois** le taux. L'horloge **libre**,
elle, ne le suit pas : c'est le transport de la session, et la vitesse de
lecture est une propriété du transport de l'hôte.

### 3.3 Les lanes MIDI (ABI 1.6)

C'est la surface qui **remplace gmem**. Le JSFX et Lua se parlaient par un bloc
de mémoire partagée dont les deux côtés recopiaient la carte à la main : une
constante fausse d'un côté, et le symptôme ressemblait à un bug de Lua. Ici la
forme est vérifiée par le compilateur d'un côté et par le nom de la fonction de
l'autre.

| fonction | rend |
|---|---|
| `CP_LaneCount()` | nombre de lanes servies (32) |
| `CP_LaneBind(lane, port, chan)` | bool — où cette lane parle. `port` −1 = nulle part |
| `CP_LaneSet(lane, param, value)` | bool — `bars` `mute` `tag` `offset` (**1.9**) `playfrom` (**2.0**) `loopa` `loopb` (**2.1**) `tsnum` (**2.3**) `umute` (**2.4**) |
| `CP_LaneGet(lane, param)` | double — `mode` `pending` `target` `phase` `lenbeats` `tag` `nev` `recgen` `bars` `mute` `port` `offset` `playfrom` `loopa` `loopb` `spana` `spanlen` (**2.1**) `tsnum` (**2.3**) `umute` (**2.4**) |
| `CP_LaneCmd(lane, cmd, arg)` | bool |
| `CP_LaneSetNote(lane, i, start, len, pitch, vel, prob)` | bool — écrit dans le tampon **qui dort** ; `prob` en pourcent, **100 = toujours** (**2.2**) |
| `CP_LanePublish(lane, count)` | bool — échange les deux tampons |
| `CP_LaneGetNote(lane, i)` | ok, start, len, pitch, vel, prob (**2.2**) — lit le tampon **publié** |
| `CP_TransportSync(tempo, beat, playing, tsNum)` | — l'ancre, **une fois par frame** |
| `CP_SetFreeRun(on)` / `CP_GetFreeRun()` | horloge libre ou transport de l'hôte |
| `CP_SetLaunchQ(beats)` / `CP_GetLaunchQ()` | quantize de lancement, 0 = tout de suite |
| `CP_SetAudioRun(on)` | « une case audio de Lua sonne » |
| `CP_EngineBeat()` | position de l'horloge sur laquelle le moteur travaille |
| `CP_ClockRunning()` | y a-t-il une horloge du tout |
| `CP_LanesPanic()` | tout arrêter, rien de tenu |
| `CP_LanesDiag()` | état des lanes en une ligne |

**Commandes** (`CP_LaneCmd`) : 1 rec · 2 stop-rec · 3 clear · 4 panic · 5 play ·
6 stop · 7 clear-all · 8 overdub · 9 set-mode (`arg` = le mode).

**Modes** : 0 vide · 1 enregistre · 2 arrêté · 3 joue · 4 armé · 5 overdub.
**En attente** : 0 aucun · 1 play · 2 stop · 3 rec · 4 stop-rec · 5 overdub.

#### Les notes s'écrivent en entier, puis se publient

Le moteur tient **deux tampons par lane** et n'en lit qu'un. `CP_LaneSetNote`
remplit celui qui dort ; `CP_LanePublish` échange les deux, d'un seul store
atomique. Conséquence à ne pas oublier : **le tampon qui dort contient
l'avant-dernière version**, donc un appelant qui n'écrirait que la note modifiée
publierait la liste d'avant avec une note neuve dedans. On écrit tout, on publie
une fois — c'est ce que fait un éditeur de toute façon, et c'est ce qui rend la
publication atomique pour le fil audio.

Côté Lua, `Loop.BumpVer(lane)` est le seul endroit qui publie : chaque geste
d'édition l'appelle déjà exactement une fois à la fin. Publier par NOTE aurait
rendu une suppression quadratique en appels d'ABI ; ne jamais publier aurait
rendu un glissé de note inaudible.

#### Ce que le fil audio ne fait pas

**Il n'écrit jamais de note.** Il les lit. La capture live entre par
`MIDI_GetRecentInputEvent`, côté Lua, où chaque événement arrive **déjà horodaté
en échantillons relatifs à maintenant** — donc plus précisément que ce qu'un
`midirecv` par bloc pouvait donner. Une frame de defer sonde en retard ; elle
n'enregistre pas en retard.

Le moteur dit qu'une prise commence en incrémentant `recgen`. C'est ainsi que
Lua sait qu'il doit vider sa liste : la propriété n'est jamais partagée, elle
est signalée.

#### Ce que le portage gagne sur le JSFX

`tick()` prépare **le bloc suivant**, donc chaque événement est daté au frame
absolu au lieu d'être posé à l'offset zéro. La porte réconcilie sur la phase de
**fin** de bloc et calcule l'instant exact de chaque transition. Mesure du
harnais : une note d'un beat à 120 BPM dure **24000 échantillons**, pas 24000
plus ou moins un tampon.

Dégénérescence prévue : un tampon plus long que la boucle elle-même sauterait
des notes entières. Dans ce cas seul on revient à la phase de début de bloc, ce
qui est exactement le comportement du JSFX — moins juste, jamais faux.

> ⚠️ **`Loop.ABI_MIN` doit suivre ce que `Loop.lua` APPELLE, pas ce dont il a
> vaguement besoin.** Il est resté à 1.7 pendant trois versions d'ABI, et aucun
> des trois manques n'échouait bruyamment contre un moteur plus ancien : la
> probabilité était perdue, la signature de boucle ne prenait pas, le mute
> musical ne taisait rien. **Trois fonctionnalités qui ont l'air de marcher.**
> Refuser le moteur est la seule réponse honnête, et les fenêtres le disent déjà
> (`cells: silent`, `engine native …`).

> ⚠️ **La version de l'ABI est un `double`, donc sa mineure ne va pas au-delà
> de 9.** `1.10` écrit dans le code **vaut 1.1** : l'extension charge très bien
> et se fait refuser par tous les scripts, qui testent un minimum — plus une
> note, plus un son, et rien n'a planté. Après 1.9 vient donc **2.0**, et ce
> n'est pas une rupture de compatibilité : c'est une contrainte d'écriture.

### 3.3 septies Les deux mutes — `mute` et `umute` (ABI 2.4)

Le moteur tait une lane si **l'un OU l'autre** est posé, et il n'a pas à savoir
lequel parle :

- **`mute`, mécanique** — « le MIDI de cette lane ne doit pas sortir ». La
  Session le pose sur une case **audio**, dont la lane porte une note unique qui
  ne doit pas atteindre l'instrument de la colonne. C'est du câblage.
- **`umute`, musical** — « tais cette lane ». C'est le bouton du Looper, et il
  doit taire aussi la **voix** de la case audio, qui n'est pas une lane. C'est
  Lua qui s'en charge, en lisant ce champ (`Cells.drive`).

> ⚠️ **Pourquoi le moteur et pas Lua.** La séparation a d'abord été écrite dans
> deux tables Lua, et c'était faux pour une raison invisible à la relecture :
> `Loop.lua` est chargé **séparément par chaque fenêtre** — trois ReaScript,
> trois états Lua, trois paires de tables — alors que la lane est **une**. Chaque
> fenêtre recomposait donc le OU à partir de la seule moitié des gestes qu'elle
> avait vue, et l'écrivait par-dessus celle de l'autre : le mute du Looper
> n'atteignait jamais la case audio de la Session, c'est-à-dire *exactement* le
> défaut que la séparation devait corriger.
>
> **Un fait partagé se range là où il est partagé.** C'est la même leçon que
> gmem, sous une autre forme : deux copies d'une vérité divergent précisément
> sur le cas où elle sert.

Côté Lua, `Loop.SetUserMute` écrit **les deux moitiés de la paire** — la bande du
Looper montre une piste, pas une lane, et la moitié vivante bascule sur sa
jumelle à chaque échange de clip. `Loop.AdoptUserMute` restitue sans marquer
l'état sale, comme `AdoptArmedLane`.

### 3.3 sexies La signature de la boucle — `tsnum` (ABI 2.3)

`CP_LaneSet(lane, "tsnum", n)` fixe le nombre de beats par mesure de **cette
lane**. Zéro veut dire « suis le projet », ce qui est le comportement d'avant —
et donc ce que valent tous les projets déjà écrits.

**La longueur d'une boucle n'appartenait à personne.** Elle valait
`bars × ts_num`, où `ts_num` était la signature rythmique **à l'endroit où la
tête de lecture se trouve en ce moment**. Une seule mesure en 3/4 quelque part
dans le projet changeait donc la longueur de *toutes* les lanes au moment où le
transport la traversait — alors que les notes, elles, sont en beats absolus. La
musique se décalait toute seule, et rien dans la fenêtre ne pouvait l'expliquer.

Côté Lua elle voyage **dans le descripteur de clip** (`clip.tsnum`) et non sur la
lane, pour la même raison que l'accolade : une lane est un emplacement que toutes
les cases d'une colonne se partagent, et `ApplyClip` l'écrit **toujours** — c'est
le seul geste qui efface celle de l'occupant précédent. Elle est posée **avant**
l'accolade, parce que c'est elle qui donne la longueur en beats contre laquelle
le moteur borne la zone.

### 3.3 quinquies La probabilité par note — `prob` (ABI 2.2)

Le septième argument de `CP_LaneSetNote` est une **chance de jouer en pourcent**,
de 0 à 100. Cent est le défaut et le chemin rapide : la porte ne hache rien pour
une note qui n'a pas de probabilité, c'est-à-dire pour l'immense majorité d'entre
elles. Le champ a pris **un des deux octets de bourrage** de `LaneNote`, donc la
structure ne grossit pas et la liste tient dans le même mégaoctet.

**Le tirage est SANS ÉTAT, et c'est ce qui le rend possible dans le fil audio.**
Une note tirée au sort doit garder sa décision pendant toute la passe, sinon elle
s'allume et s'éteint en cours de note. Ça semble demander une mémoire par note et
par passe — c'est-à-dire de l'état, dans le fil audio, remis à zéro par un
évènement que ce fil ne connaît pas. Ça n'est pas nécessaire :

```
onset = pref - d                       // l'instant où CETTE note a commencé
pass  = floor(onset / Ls)
h     = hash(index_de_note, pass ^ graine_de_lane)
if (h % 100) >= prob  →  cette note se tait CE TOUR-CI
```

Le hachage ne dépend que de `(note, passe)`, donc il est **constant pendant toute
la passe** et **identique pour l'attaque et pour la coupure**. Zéro octet d'état,
zéro allocation, et le harnais peut prouver la distribution — ce qu'un vrai
générateur aléatoire n'aurait pas permis.

**Le numéro de passe se prend sur l'ATTAQUE, pas sur l'instant courant.** Une
note qui traverse la frontière de boucle est encore dans la passe où elle a
commencé ; la dater sur maintenant lui ferait retirer au sort à mi-note, et la
coupure d'une note qui n'a jamais sonné serait laissée en l'air — une note tenue
jusqu'à la fin des temps, qui est le seul défaut de cette fonctionnalité qui ne
se rattrape pas tout seul. C'est l'assertion que le harnais vérifie en comptant
**autant de coupures que d'attaques**.

**La graine se déduit de l'indice de lane** : rien à stocker, rien à sérialiser,
et deux lanes portant les mêmes notes ne tirent pas la même suite — ce qui
s'entendrait tout de suite comme un motif et non comme du hasard.

> ⚠️ **Le septième argument a un défaut côté C++, et c'est obligatoire.** `argi`
> rend **zéro** hors plage, et zéro veut dire « cette note ne sonne jamais » : un
> script antérieur à 2.2, qui appelle avec six arguments, aurait rendu toutes ses
> lanes muettes sans un mot. Le pont teste donc `narg` et non la valeur. Dans
> l'autre sens — script neuf, extension ancienne — le septième est ignoré et la
> probabilité est simplement inerte.

**Elle n'existe qu'en mode case.** Le MIDI de REAPER n'a aucun champ par note où
la ranger ; sur une prise il faudrait la coder dans un évènement de notation, la
voir se perdre à chaque glisser, et l'expliquer. `Roll.CanProb()` répond pour le
backend, et l'éditeur le **dit dans l'en-tête de la section** — une limite
énoncée avant le geste vaut mieux qu'un réglage qui a l'air de marcher.

### 3.3 ter Lire à partir d'ici — `offset` (ABI 1.9)

`CP_LaneSet(lane, "offset", beats)` décale la phase d'une lane.

La phase est ancrée sur le **beat zéro du projet** : c'est ce qui verrouille
toutes les boucles sur la même grille, et ça ne change pas. Un décalage
**constant** ne casse pas ce verrou — il le déplace. La lane reste calée, à
distance fixe, et rien ne dérive. C'est le *legato launch* d'Ableton, et c'est
ce que veut dire « lire à partir d'ici ».

Le moteur le lit **au même endroit** pour le portail MIDI (`run_gate`) et pour
la phase publiée (que `Cells` lit pour l'audio) : les notes et le son bougent
donc ensemble. Les brancher séparément les séparerait d'un décalage exactement
égal à celui qu'on vient de poser.

**Non persisté, délibérément** : c'est un geste de jeu, comme un scrub. Le
retrouver à la réouverture d'un projet serait une surprise, pas un service.

Le harnais le **mesure** plutôt que de le supposer : un beat demandé donne un
beat, et l'écart vaut toujours un beat vingt passes plus loin — ce qui est
toute la différence entre déplacer un verrou de phase et le casser.

Côté Lua, `Loop.PlayClipFrom(lane, beat)` fait le calcul et incrémente un
compteur que `Cells` relit : une voix audio tient une date de départ en frames
et finirait sa passe, alors que le MIDI saute au bloc suivant. Sans ça on
entendrait les notes sauter et le son rester.

### 3.3 quater L'accolade de boucle — `loopa` / `loopb` (ABI 2.1)

`CP_LaneSet(lane, "loopa"|"loopb", beats)` définit la sous-région qu'une case
joue en boucle, en beats depuis son début. `loopb <= loopa` l'efface.

**Ce n'est pas une porte, c'est une longueur de boucle**, et toute la valeur de
la fonctionnalité tient dans cette distinction. Taire les notes du dehors aurait
été plus simple à écrire : la case aurait continué de tourner sur ses quatre
mesures en n'en faisant sonner que deux — donc deux mesures de musique suivies
de deux mesures de silence. Le *loop brace* d'Ableton fait l'autre chose, la
seule qui soit musicale : **la case devient une boucle de deux mesures**, qui
revient deux fois plus souvent.

Le verrouillage de phase y survit intact parce que c'est exactement le même
verrou, sur une autre longueur : une lane de longueur `Ls` ancrée sur le beat
zéro du projet. On n'a pas ajouté d'horloge, on a changé une longueur — et
c'est pour ça que le champ ne coûte rien aux lanes qui ne s'en servent pas.

**Ce que le moteur publie, et pourquoi deux paires plutôt qu'une :**

| lecture | ce que c'est |
|---|---|
| `loopa` / `loopb` | ce qui a été **demandé**, tel quel — pour l'afficher et le modifier |
| `spana` / `spanlen` | ce qui est **joué**, après bornage dans la case |

Les deux diffèrent dans le cas qui arrive vraiment : on pose l'accolade sur les
mesures 3 et 4, puis on raccourcit la boucle à une mesure. Le moteur ramène
alors l'accolade dans la case et, s'il n'en reste pas une durée musicale, revient
à la case entière. **Une accolade qui déborde ne doit jamais rendre une case
muette** — rien dans le geste ne l'a demandé, et c'est le genre de silence qu'on
attribue au moteur. Le bornage vit donc d'un seul côté, et Lua lit son résultat
au lieu d'en tenir une deuxième copie qui aurait divergé exactement sur ce cas.

**`phase` est publiée en coordonnées de CASE**, accolade comprise : elle vaut
`spana + (phase dans la zone)`. C'est ce que le lecteur demande — où dans le
clip on se trouve, pour le trait de lecture de l'éditeur et pour l'endroit où la
voix audio doit entrer dans la matière. `lenbeats` reste la longueur de la
**case** : une accolade ne raccourcit pas le clip, et c'est le contrat que tous
les lecteurs ont déjà.

**Persistée, contrairement au décalage de phase**, et la différence est de
nature : un décalage est un geste de jeu, une accolade est une édition, au même
titre que la longueur de boucle ou les notes. La perdre à la fermeture en aurait
fait un brouillon. Format de sérialisation **7**.

Le harnais compte des notes plutôt que d'écouter : sur huit beats, une zone de
quatre fait partir chacune de ses notes **deux** fois. Une porte en aurait donné
une seule — c'est le test qui tranche entre les deux lectures, là où l'oreille
entend surtout que « ça marche », dans les deux cas.

Côté Lua : `Loop.SetLoopRange`, `Loop.GetLoopRange`, `Loop.Span`. Et `Cells`
suit, parce que « longueur de la case » et « longueur d'une passe » s'y
confondaient — sans quoi les notes auraient tourné sur deux mesures et le son
sur quatre.

### 3.3 quinquies Un arrêt de transport remet la case **en file**

En mode Suivre, l'arrêt du transport ne laisse plus une case en « joue ». Elle
repasse **arrêtée + en file** (`mode = 2`, `pending = 1`) : allumée, donc
dessinée **entourée** et non pleine, et elle repartira sur une frontière de
quantize quand le transport reviendra.

La distinction que ça règle est celle entre *« ce clip est allumé »* et *« ce
clip est en train de sonner »*. Garder le mode à « joue » à travers l'arrêt —
c'était l'intention, et elle était bonne — faisait repartir la case **au bloc
suivant** le retour du transport, sans jamais repasser par la file : elle ne
rattrapait donc aucune frontière et jouait contre l'arrangement.

**Le décalage de phase tombe avec l'arrêt.** Il avait été calculé contre une
frontière de lancement qui n'existe plus ; le garder ferait repartir la case à
côté de la grille. Le document dit déjà qu'un décalage est un geste de **jeu** —
un arrêt de transport termine ce geste.

### 3.3 sexies Deux horizons, et ils ne sont pas le même

Mesuré au harnais sur un bloc de 2048, et c'est la mesure qui a désigné les
deux coupables — le raisonnement cherchait ailleurs.

**Une transition en retard part au DÉBUT du bloc, pas à sa fin.** `phase_hit`
rend le *prochain* instant où la phase vaut ce qu'on cherche ; au premier bloc
d'un lancement le point est déjà passé, donc il repartait une boucle entière
plus loin et le bornage à la fin du bloc datait la note **au plus tard
possible**. La première note d'un lancement quantifié sortait **48 ms** après
son temps. C'est la même règle que `drain_midi` applique déjà à un événement
dépassé : mieux vaut un bloc de retard qu'un bloc et demi.

**Ce qui COMMENCE se résout sur le bloc qui CONTIENT sa frontière**, pas sur le
premier bloc qui l'a dépassée. La porte réconcilie sur la phase de **fin** de
bloc : lui livrer une lane passée à « joue » au bloc *suivant* lui faisait
manquer la frontière de quelques centaines d'échantillons. Ce qui **s'arrête**
garde l'ancien horizon, et ce n'est pas un oubli — un arrêt résolu sur le bloc
qui contient sa frontière couperait jusqu'à une taille de tampon **avant**
elle, alors qu'un arrêt quantifié promet exactement le contraire.

Après les deux : **0,000 ms d'écart sur chaque note**, et la première note
d'une reprise de transport tombe sur sa frontière de quantize à l'échantillon.

### 3.3 bis Une note qui a un destinataire (ABI 1.8)

`CP_PortMidiAt(port, at, status, d1, d2)` dépose un message MIDI brut dans le
flux du port. Un port est versé dans **une** piste, pré-FX : le message traverse
la chaîne d'effets de cette piste comme s'il venait d'un item, et rien d'autre
dans le projet ne l'entend.

**Ce qu'elle remplace, et pourquoi ce n'était pas un détail.** Toute la suite
jouait ses notes d'aperçu par `StuffMIDIMessage`, que le SDK décrit comme une
écriture dans la file du **clavier virtuel**. Une file n'a pas de destinataire :
ce qu'on y met part vers *toute* piste armée en monitoring. Trois conséquences
en chaîne, et ce sont les trois symptômes rapportés au premier test d'écoute :

1. pour s'entendre, il fallait **armer** une piste — donc le sampler armait la
   sienne de force, et la réaffirmait à chaque poll ;
2. comme il réarmait tout seul, il **gagnait** contre les pistes armées à la
   main : « ça ne réagit pas avec les armed track de REAPER natif » ;
3. un clic de pad sonnait aussi ce qui était armé ailleurs, d'où un **canal
   réservé** inventé pour que les autres apprennent à ignorer nos aperçus —
   un timbre-poste sur une lettre sans adresse.

Avec une adresse, les trois tombent ensemble : l'armement redevient ce que
REAPER en dit, et `Kit.Armed()` est une lecture, plus une volonté.

**`at < 0` veut dire maintenant**, même convention que `CP_VoiceStopAtSample` et
pour la même raison : une date lue sur le fil principal est déjà passée quand le
fil audio la regarde, et « au plus tôt » est la seule réponse honnête à un doigt.

**Le message est brut à dessein.** Note-on, note-off, CC, pitch bend,
all-notes-off sont la même chose vue du port. Composer une note **tenue** est le
travail de l'appelant, qui seul sait quand le doigt part —
`CP_Engine/Notes.lua` le fait, et tient le registre des notes non relâchées.

**La carte des ports** (énoncée dans `Voice.lua`) réserve **24** au jeu live du
sampler et **25** à celui de l'éditeur. Deux fenêtres sont deux états Lua mais un
seul moteur : partager un port ferait qu'un clic de pad vole sa piste au piano
roll. Un port par consommateur coûte une `PCM_source` silencieuse et rend le
partage impossible par construction.

### 3.4 Instruments de mesure

Ils ne servent pas à faire de la musique et ne doivent pas entrer dans une
fenêtre. Marqués EXPERIMENTAL dans le code — ce ne sont pas des interfaces.

| fonction | mesure |
|---|---|
| `CP_LoadReset()` / `CP_LoadDiag()` | ports, voix, ratio du port le plus mal servi, part du fil audio |
| `WIP/CP_SoakProbe.lua` | **la session longue** : sept invariants, première violation horodatée |
| `CP_WarpProbe(tempoRatio, nvoices)` | amorçage et coût de l'étireur de REAPER |
| `CP_TestMidiAt(port, at, note, vel, dur)` | une note **et sa coupure** en un appel, sur `CP_PortMidiAt` |
| `CP_TestMidiDiag()` | événements remis, exacts, en retard |

---

## 4. Fils, erreurs, durées de vie

**Tout `CP_*` s'appelle depuis le fil principal.** Rien n'est sûr depuis ailleurs,
et rien n'en a besoin : le fil audio ne demande jamais l'heure, il compte ses
échantillons.

**Les erreurs sont muettes et sûres.** Un handle périmé, un port hors bornes, un
clip absent : la commande est ignorée, rien n'explose. C'est délibéré — dans ce
dépôt les scripts meurent et redémarrent en permanence, et une commande venue
d'un script mort ne doit atteindre personne.

**La mémoire d'un clip n'est rendue qu'après deux blocs audio.** Le fil audio
peut être en train de rendre avec ce clip au moment où on le retire.

**`CP_PortDetach` reprend les voix du port.** Sans cela, une voix en fondu de
sortie sur un port qui ne rend plus reste éternellement en `STOPPING` et son
emplacement est perdu.

**Aucune persistance.** Rien n'est écrit dans le `.RPP`. C'est délibéré et
consigné : le moteur ne sera **jamais** la seule source de vérité d'une session.
L'état reste dans `ProjExtState`, natif à REAPER, qui survit sans le binaire —
ainsi un projet CP s'ouvre toujours sur une machine sans le moteur. Il ne sonne
pas, mais il n'est pas détruit.

---

## 5. Ce que l'API ne fait pas, et pourquoi

| absent | raison |
|---|---|
| lecture depuis le disque | décision produit : des boucles ≤ 64 s, tout en RAM. Le plafond **refuse** (−2), il ne tronque plus — et `Audition` renvoie les fichiers plus longs à `CF_Preview`, qui lit depuis le disque. La limite est **couverte**, pas seulement déclarée |
| warp / time-stretch | mesuré à **2,3 % par voix** contre 0,053 % sans étirement, soit ~42×. Deux étireurs vivants au maximum ; le reste se cuit hors ligne |
| lancement immédiat d'un clip warpé | l'étireur exige **85 à 139 ms** d'amorçage. Toujours disponible sur un lancement quantifié, jamais sur un immédiat — et c'est pourquoi il n'entre pas dans un chemin d'audition |
| vrai fondu croisé | `xfade` avance le départ de la suivante ; la sortante ne sonne pas pendant le recouvrement |
| filtre anti-repliement | le repitch vers l'aigu replie au-delà de quelques demi-tons. `Resample_Create` le règlera — et lui expose sa latence, contrairement à l'étireur |
| MIDI comme voix | le véhicule est prouvé (huit notes déposées, huit entendues) mais le moteur MIDI — porte par bloc, capture live, quantize — vit encore dans `CP_MidiLooper.jsfx` |
| rendu accéléré | un aperçu n'est pas vu par un rendu offline. L'**enregistrement** et le rendu **temps réel** le voient — mesuré à 99,9 % d'identité avec la source |
