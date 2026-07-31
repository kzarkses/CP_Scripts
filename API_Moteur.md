# API du moteur CP — contrat de référence

Document de référence. Il dit **ce qu'on appelle, avec quelles unités, depuis
quel fil, et ce qui se passe quand ça rate**. Il ne dit pas pourquoi le moteur
existe — c'est `ARCHI_MoteurNatif.md` — ni comment il est construit — c'est
`CP_Native/README.md`.

---

## 0. La règle qui prime sur tout le reste

> **Une fenêtre appelle `CP_Engine/Voice.lua`. Jamais `reaper.CP_*` directement.**

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
| `Voice.Backend()` | `"native"` / `"preview"` | diagnostic seulement |
| `Voice.Diag()` | chaîne | état du moteur en une ligne |

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
| `Voice.Load(path)` | identifiant opaque, ou nil | décode en RAM au taux du moteur |
| `Voice.Unload(clip)` | — | mémoire rendue après deux blocs audio |
| `Voice.ClipInfo(clip)` | durée_s, canaux, taux | ou nil |

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
| `Voice.UnbindTrack(port)` | — | reprend aussi les voix du port |

Le son entre **pré-FX** : il traverse la chaîne d'effets de la piste, son fader,
son VU et ses envois (mesuré — une réverbe sur la piste s'applique bien). Rien
n'est inséré dans la chaîne de l'utilisateur.

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
| `Voice.State(h)` | état, position | **deux valeurs**, pas une table |
| `Voice.IsPlaying(h)` | bool | |
| `Voice.StartedAt(h)` | frame, ou −1 | attaque réelle, sans course |
| `Voice.Panic()` | — | tout couper en 5 ms |

`opts` (toutes optionnelles) : `rate`, `gain`, `loop`, `pan`, `fade_in`,
`fade_out`. **Réutilisez la même table** si vous appelez par frame.

`param` de `Set` : `rate`, `gain`, `pan`, `loop_start`, `loop_end`, `fade_in`,
`fade_out`. En repli, seuls `gain` et `rate` existent.

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

## 3. `reaper.CP_*` — l'ABI brute

À n'appeler que depuis `Voice.lua`, ou depuis une sonde.

### 3.1 Le garde, obligatoire

```lua
if not reaper.APIExists("CP_EngineABI") then return end
if reaper.CP_EngineABI() < 1.4 then return end   -- un MINIMUM, pas une égalité
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
| `CP_ClipLoad(path)` | identifiant, ou −1 |
| `CP_ClipUnload(clip)` | — |
| `CP_ClipInfo(clip)` | ok, frames, srate, nch |
| `CP_PortAttach(track, port)` | bool, idempotent |
| `CP_PortDetach(port)` | — |
| `CP_PortGain(port, gain)` | — |
| `CP_VoiceAlloc(port)` | handle, ou 4294967295 |
| `CP_VoiceRelease(v)` | — |
| `CP_VoicePlayAtSample(v, clip, at, mode, rate, gain)` | bool |
| `CP_VoiceStopAtSample(v, at, fade)` | bool |
| `CP_VoiceSet(v, param, value)` | bool |
| `CP_VoiceQueueNext(v, next, xfade)` | bool |
| `CP_VoiceState(v)` | ok, pos, état |
| `CP_VoiceStartedAt(v)` | frame, ou −1 |
| `CP_ClockNow()` | frame absolu |
| `CP_ClockSync()` | frame ; prend l'ancre |
| `CP_TimeToSample(t)` | frame **fractionnaire** — arrondir |
| `CP_Panic()` | — |
| `CP_Diag()` | état en une ligne |

`mode` : 0 = une fois, 1 = boucle.

### 3.3 Instruments de mesure

Ils ne servent pas à faire de la musique et ne doivent pas entrer dans une
fenêtre. Marqués EXPERIMENTAL dans le code — ce ne sont pas des interfaces.

| fonction | mesure |
|---|---|
| `CP_LoadReset()` / `CP_LoadDiag()` | ports, voix, ratio du port le plus mal servi, part du fil audio |
| `CP_WarpProbe(tempoRatio, nvoices)` | amorçage et coût de l'étireur de REAPER |
| `CP_TestMidiAt(port, at, note, vel, dur)` | dépose une note datée |
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
| lecture depuis le disque | décision produit : des boucles ≤ 64 s, tout en RAM |
| warp / time-stretch | mesuré à **2,3 % par voix** contre 0,053 % sans étirement, soit ~42×. Deux étireurs vivants au maximum ; le reste se cuit hors ligne |
| lancement immédiat d'un clip warpé | l'étireur exige **85 à 139 ms** d'amorçage. Toujours disponible sur un lancement quantifié, jamais sur un immédiat |
| vrai fondu croisé | `xfade` avance le départ de la suivante ; la sortante ne sonne pas pendant le recouvrement |
| filtre anti-repliement | le repitch vers l'aigu replie au-delà de quelques demi-tons. `Resample_Create` le règlera — et lui expose sa latence, contrairement à l'étireur |
| MIDI comme voix | le véhicule est prouvé (huit notes déposées, huit entendues) mais le moteur MIDI — porte par bloc, capture live, quantize — vit encore dans `CP_MidiLooper.jsfx` |
| rendu accéléré | un aperçu n'est pas vu par un rendu offline. L'**enregistrement** et le rendu **temps réel** le voient — mesuré à 99,9 % d'identité avec la source |
