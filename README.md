# CP_Native — moteur de clips audio pour REAPER

Extension C++ (`reaper_cpclip`) qui lance des clips audio **exactement à
l'échantillon**, en RAM, sans rien poser dans la chaîne d'effets de
l'utilisateur.

Dossier de conception : `ARCHI_MoteurNatif.md` dans le dépôt CP_Scripts.
Ce README ne redit pas le pourquoi ; il dit comment construire et ce qui est
vérifié.

---

## Ce qui est vérifié, et ce qui ne l'est pas

**Vérifié**, par `build_test.cmd`, hors REAPER, 79 assertions :

- départ exact à l'échantillon pour des blocs de 1, 17, 63, 64, 128 et 512 ;
- lecture bit-exacte à taux 1,0 (aucune interpolation parasite) ;
- boucle sans dérive sur 133 tours, échantillon par échantillon ;
- arrêt daté : dernier échantillon audible = `stop_at − 1` ;
- enchaînement au frame exact d'extinction de la voix précédente ;
- handles périmés rejetés en silence ;
- **zéro allocation dans le chemin audio** (piège sur `operator new`).

**Non vérifié** — c'est ce que la sonde dans REAPER doit établir :

- le service d'aperçu tient-il à 64 échantillons avec une source en RAM ;
- `PCM_source_transfer_t::time_s` est-il demandé de façon **contiguë** — c'est un
  temps demandé, pas un compteur, et le port l'instrumente (`maxgap` dans
  `CP_Diag()`) ;
- un aperçu de piste entre-t-il pré-FX ou post-FX ;
- un aperçu de piste transmet-il les `midi_events` du bloc — **c'est la question
  la plus rentable du projet** : elle décide si la cible est *un* binaire ou
  *un binaire + le JSFX MIDI*.

---

## Construire

Prérequis : Visual Studio 2022 (composant « Desktop development with C++ ») et
le SDK cloné en voisin.

```
git clone --depth 1 https://github.com/justinfrankel/reaper-sdk.git
```
Arborescence attendue :
```
dev/
  reaper-sdk/sdk/...
  CP_Native/
```

```
build_test.cmd    le harnais hors-ligne (aucun REAPER requis)  -> build\cp_test.exe
build_dll.cmd     l'extension                                  -> build\reaper_cpclip.dll
```

`CMakeLists.txt` produit la même chose et sert au portage macOS/Linux. CMake
n'est pas installé sur la machine de dev ; les scripts `.cmd` sont la voie
quotidienne, et les deux doivent rester d'accord.

Réglages non négociables : `/std:c++17 /EHsc /GR- /MT`, et **jamais `/arch:`** —
la baseline x64 de MSVC est SSE2, ce qui est exactement la cible ; un
`/arch:AVX` rendrait le binaire inexécutable sur une machine ancienne, avec un
plantage au chargement et pas un message.

## Installer

Copier `build\reaper_cpclip.dll` dans `%APPDATA%\REAPER\UserPlugins\`, puis
redémarrer REAPER. Pour désinstaller : supprimer le fichier.

## Éprouver

`lua\CP_NativeProbe.lua` : sélectionner une piste, lancer, donner un fichier
audio. Le son sort **sur la piste**, sans aucun objet dans sa chaîne d'effets.

---

## Architecture

```
src/core/     AUCUN appel à l'API REAPER, aucune I/O, aucune allocation
              après l'initialisation. C'est cette règle qui rend le harnais
              possible ; si elle tombe, on débogue à l'aveugle.
  cp_types.h    constantes, commandes (POD), handles à génération
  cp_ring.h     anneau SPSC sans verrou, curseurs sur deux lignes de cache
  cp_pool.*     échantillons en RAM, publication par store(release),
                libération derrière une barrière de deux blocs
  cp_voice.*    une voix : un clip, une position, un rendez-vous
  cp_engine.*   ports, voix, horloge, application des commandes

src/host/     la seule couche qui connaît REAPER
  cp_source.*   PCM_source par colonne, aperçu permanent
  cp_main.cpp   point d'entrée, surface CP_*, décodage, hook d'horloge

src/test/     harness.cpp — 79 assertions déterministes
```

### L'horloge

Le fil audio ne **demande** jamais l'heure : il **compte** ses échantillons.
`Engine::tick(frames)` est appelé au passage *post* du hook matériel — après le
rendu, jamais avant. Une ancre unique, prise sur le fil principal par
`CP_ClockSync()` (deux lectures collées : position du projet et compteur du
moteur), suffit à convertir un instant du projet en frame absolu. Il n'y a
aucune dérive à rattraper : la boucle et le projet sont entraînés par la même
horloge de carte son.

Si le hook matériel n'est pas disponible, un port fait office d'horloge. Aucun
service optionnel ne doit pouvoir empêcher le moteur d'exister.

### Ce que le moteur ignore

Ni scène, ni colonne, ni cellule, ni beat, ni tempo. Il connaît des **voix** et
des **frames absolus**. La carte de tempo reste en Lua, sur le fil principal, où
elle est exacte (`TimeMap2_*`).

---

## Surface CP_*

`CP_EngineABI()` d'abord, toujours : ReaPack n'a aucun mécanisme de dépendance,
un script peut donc s'installer sans le binaire.

| fonction | rôle |
|---|---|
| `CP_EngineABI()` | version de l'ABI |
| `CP_Srate()` | taux du moteur |
| `CP_ClipLoad(path)` | décode en RAM au taux du moteur, rend un id |
| `CP_ClipUnload(clip)` | libère (après deux blocs) |
| `CP_ClipInfo(clip)` | frames, taux, canaux |
| `CP_PortAttach(track, port)` | aperçu permanent sur la piste, idempotent |
| `CP_PortDetach(port)` / `CP_PortGain(port, g)` | |
| `CP_VoiceAlloc(port)` / `CP_VoiceRelease(v)` | |
| `CP_VoicePlayAtSample(v, clip, at, mode, rate, gain)` | rendez-vous exact |
| `CP_VoiceStopAtSample(v, at, fade)` | coupure datée |
| `CP_VoiceSet(v, param, value)` | rate gain pan loop_start loop_end fade_in fade_out |
| `CP_VoiceQueueNext(v, next, xfade)` | enchaînement au frame exact |
| `CP_VoiceState(v)` | position, état |
| `CP_ClockNow()` / `CP_ClockSync()` / `CP_TimeToSample(t)` | l'horloge |
| `CP_Panic()` | tout couper en 5 ms |
| `CP_Diag()` | état du moteur en une ligne |

## Limites assumées de la v1

- Décodage **synchrone** sur le fil appelant. Une boucle de 16 mesures se décode
  en quelques millisecondes ; le fil de travail viendra si la durée maximale
  d'un clip change.
- Clips **en RAM uniquement**, plafond 64 s. Pas de streaming disque : décision
  produit du 2026-07-31.
- `xfade` avance le départ de la voix suivante ; le vrai fondu croisé (les deux
  voix sonnant pendant le recouvrement) n'est pas fait.
- Aucune persistance : rien n'est écrit dans le `.RPP`. C'est le point de
  non-retour du plan, il vient en dernier et seulement une fois vérifié que
  REAPER ne détruit pas les lignes d'une extension absente à la re-sauvegarde.
- Windows x64 seulement.
