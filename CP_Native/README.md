# CP_Native — le moteur de clips

Extension REAPER en C++ (`reaper_cpclip`) qui joue des clips audio **exacts à
l'échantillon**, depuis la RAM, sur une piste REAPER — **sans rien poser dans la
chaîne d'effets de l'utilisateur**.

Trois documents, trois rôles :

| document | répond à |
|---|---|
| `../ARCHI_MoteurNatif.md` | **pourquoi** — le raisonnement, les mesures, les corrections |
| `../API_Moteur.md` | **comment l'appeler** — le contrat de référence |
| ce fichier | **ce qui existe** — le code, sa forme, ses limites, sa construction |

---

## 1. Ce qui est mesuré

Tout ce qui suit est un relevé, pas une intention. Machine de l'auteur, ASIO,
tampon **64 échantillons**.

| | résultat |
|---|---|
| attaque d'un lancement daté | `demandé == réel`, **écart 0 échantillon** |
| service d'aperçu | **15 009 appels pour 15 009 blocs** — aucun manqué |
| contiguïté des demandes | `maxgap = 0,000000` |
| 8 ports × 8 voix = **64 voix** | ratio 1,0000, **3,39 %** du fil audio |
| MIDI | 16 événements, **16 exacts, 0 en retard** |
| enregistrement de la piste | **99,9 % identique** à la source |
| entrée dans la piste | **pré-FX** — la chaîne, le fader et les envois s'appliquent |
| décodage | 8,000 s attendues, 8,000 s obtenues, 2,93 Mo en 27 ms |
| étireur de REAPER | **2,3 %/voix**, amorçage 85–139 ms selon le taux |
| cœur, hors REAPER | **88 assertions**, **zéro allocation** dans le chemin audio |

Pour mémoire, ce que remplace tout cela : `CF_Preview` lisait à **0,54×** de sa
vitesse au même tampon, et se taisait à ce sujet.

---

## 2. Ce qui est cassé, incomplet, ou volontairement absent

Écrit ici plutôt que découvert plus tard.

### Défaut connu, non corrigé

**Course sur la réutilisation d'une voix.** `voice_alloc` appelle
`voices_[i].reset()` depuis le fil principal sur un emplacement que le fil audio
peut encore parcourir. Bénin sur x86 — une lecture d'entier ne se déchire pas —
mais c'est un bug intermittent et non reproductible garanti le jour du portage
ARM (macOS). C'est aussi une **incohérence** : toute autre commande passe par
l'anneau, celle-là non. Correctif connu : le fil principal demande, le fil audio
exécute.

### Volontairement absent

- **Aucune persistance.** Rien dans le `.RPP`, par décision : l'état reste dans
  `ProjExtState`, natif à REAPER, pour qu'un projet CP s'ouvre toujours sur une
  machine sans le binaire.
- **Pas de lecture disque.** Des boucles ≤ 64 s, tout en RAM (décision produit).
- **Décodage synchrone** sur le fil appelant. Quelques millisecondes pour une
  boucle ; le fil de travail viendra si la durée maximale change.
- **Pas de vrai fondu croisé.** `xfade` avance le départ de la suivante ; la
  sortante ne sonne pas pendant le recouvrement.
- **Pas de filtre anti-repliement** sur le repitch vers l'aigu.
- **Windows x64 uniquement.**

### Jamais éprouvé

- **Aucune session de plus de 20 secondes.** Toutes les mesures portent sur des
  fenêtres courtes.
- Deux onglets de projet simultanés avec des ports des deux côtés.
- Une piste supprimée puis restaurée par annulation (`MediaTrack*` pendant).

---

## 3. Construire

Prérequis : Visual Studio 2022, composant « Desktop development with C++ ».
Le SDK reste **hors du dépôt** — c'est une dépendance fournisseur, et sa licence
n'est pas la nôtre :

```
git clone --depth 1 https://github.com/justinfrankel/reaper-sdk.git
```

Par défaut les scripts le cherchent dans `C:\Users\Cedric\dev\reaper-sdk\sdk` ;
surchargez `REAPER_SDK` pour le ranger ailleurs.

```
build_test.cmd    le harnais hors-ligne, sans REAPER   -> build\cp_test.exe
build_dll.cmd     l'extension, puis l'installe         -> build\reaper_cpclip.dll
```

`build_dll.cmd` copie la DLL dans `UserPlugins` et **refuse proprement si REAPER
tourne** — aucune extension ne se recharge à chaud, c'est la nature du format.
Les sondes Lua, elles, se remplacent sans redémarrer.

`CMakeLists.txt` produit la même chose et sert au portage. CMake n'est pas
installé sur la machine de développement ; les deux voies doivent rester
d'accord.

### Réglages non négociables

`/std:c++17 /EHsc /GR- /MT`, et **jamais `/arch:`**.

- **`/EHsc` ON**, avec un `catch(...)` à chaque frontière exportée : une
  exception qui traverse la frontière C tue l'hôte, et couper les exceptions rend
  la STL formellement non supportée alors que `new` jette quand même.
- **`/MT`** : la DLL atterrit sur des machines sans redistribuable VC++.
- **Aucun `/arch:`** : la baseline x64 de MSVC est SSE2, ce qui *est* la cible.
  Un `/arch:AVX` rendrait le binaire inexécutable sur une machine ancienne, avec
  un plantage au chargement et pas un message.

C++ et non C, et ce n'est pas une préférence : `PCM_source` et
`IReaperPitchShift` sont des **classes abstraites à vtable** qu'il faut dériver
et appeler. Cockos le dit lui-même : *« Extensions for REAPER/win32 should be
written in C++ and compiled using MSVC — pure virtual interface classes are used
and as such the C++ ABI must be compatible. »*

---

## 4. Architecture

```
src/core/     AUCUN appel à l'API REAPER, aucune I/O, aucune allocation
              après l'initialisation.
  cp_types.h    constantes, commandes (POD, 40 octets), handles à génération
  cp_ring.h     anneau SPSC sans verrou, curseurs sur deux lignes de cache
  cp_pool.*     échantillons en RAM, publication par store(release),
                libération derrière une barrière de deux blocs
  cp_voice.*    une voix : un clip, une position, un rendez-vous
  cp_engine.*   ports, voix, horloge, application des commandes

src/host/     la seule couche qui connaît REAPER
  cp_source.*   PCM_source par colonne, aperçu permanent, MIDI, chronomètre
  cp_main.cpp   point d'entrée, surface CP_*, décodage, hook d'horloge

src/test/     harness.cpp — 88 assertions déterministes
lua/          les sondes de mesure
```

### La règle qui porte tout

> **`src/core` n'appelle aucune API REAPER.**

C'est ce qui rend le harnais hors-ligne possible. Sans lui, on débogue à
l'aveugle : un point d'arrêt dans le fil audio affame la carte son et rend l'état
observé faux. Si cette règle tombe, on s'en aperçoit trois mois trop tard.

### L'horloge

Le fil audio ne **demande** jamais l'heure : il **compte** ses échantillons.

`Engine::tick(frames)` est appelé au passage **post** du hook matériel — *après*
le rendu, jamais avant. L'appeler avant étiquetterait chaque bloc avec l'heure de
sa fin, et tout partirait un bloc trop tôt : c'est le premier bug qu'a trouvé le
harnais, invisible à l'oreille (1,33 ms) et qu'on aurait cherché dans REAPER.

Une ancre unique, prise sur le fil principal par `CP_ClockSync()` (deux lectures
collées), convertit un instant du projet en frame absolu. **Aucune dérive à
rattraper** : la boucle et le projet sont entraînés par la même horloge de carte
son.

Si le hook matériel manque, un port fait office d'horloge — aucun service
optionnel ne doit empêcher le moteur d'exister.

### Ce que le moteur ignore

Ni scène, ni colonne, ni cellule, ni beat, ni tempo. Il connaît des **voix** et
des **frames absolus**. La carte de tempo reste en Lua, où `TimeMap2_*` est
exact.

### Invariants du fil audio

- zéro allocation, zéro verrou, zéro appel système, zéro `assert`, zéro log ;
- interdits : `std::string`, `std::function`, `std::mutex`, `iostream`,
  destruction de `shared_ptr`, **et tout static local** (sa garde thread-safe
  alloue à la première entrée, une seule fois, donc le bug est irreproductible) ;
- **chaque voix est rendue exactement une fois par bloc.** Deux fois la fait
  avancer à double vitesse — ça s'entend comme un décalage et ça se cherche comme
  un problème d'horloge ;
- les gains sous `1e-15` sont forcés à zéro. Les dénormaux coûtent 100 à 400
  cycles sur un Athlon 64 ; on les tue à la source plutôt que de poser FTZ/DAZ
  globalement, ce qui dégraderait tous les autres plugins de l'hôte.

---

## 5. Le harnais

`build_test.cmd` compile `src/core` **sans REAPER** et lance 88 assertions
déterministes : départ exact pour des blocs de 1, 17, 63, 64, 128 et 512 ;
lecture bit-exacte à taux 1,0 ; boucle sans dérive sur 133 tours ; arrêt daté ;
enchaînement au frame exact ; changement de taux d'échantillonnage ; handles
périmés rejetés ; et un **piège sur `operator new`** qui *prouve* le
zéro-allocation au lieu de l'affirmer.

Il a trouvé deux bugs que l'oreille n'aurait pas isolés : l'horloge d'un bloc en
avance, et une commande sur un handle libéré qui passait le contrôle de
génération.

---

## 6. Les sondes

Dans `lua/`, copiées vers `WIP/` par le script de construction.

| sonde | mesure |
|---|---|
| `CP_NativeProbe` | attaque, contiguïté, tirage de l'aperçu |
| `CP_MidiProbe` | REAPER route-t-il le MIDI d'un aperçu, et notre placement est-il exact |
| `CP_LoadProbe` | 8 ports × 8 voix : ratio du port le plus mal servi, part du fil audio |
| `CP_WarpProbe` | amorçage et coût de l'étireur de REAPER |
| `../WIP/CP_VoiceProbe` | valide l'ABI **par l'usage** — ce qu'écrirait une fenêtre |

Elles écrivent dans `<ressources REAPER>/CP_NativeProbe.log`, en ajout.

### La leçon des sondes

**Cinq fois sur cinq, l'instrument s'est trompé avant le code mesuré**, et à
chaque fois il accusait le moteur. Le réflexe correct fut toujours le même :

> **Ne pas expliquer l'écart — rendre l'instrument incapable de le produire.**

Faire noter l'attaque par la voix elle-même plutôt que la déduire. Arrondir à la
frontière plutôt qu'afficher un arrondi. Distinguer « zéro » de « je ne sais
pas ». Mesurer la grandeur qu'on croit mesurer, pas celle qui lui ressemble.
Le détail des cinq est au §12.14 du dossier d'architecture.
