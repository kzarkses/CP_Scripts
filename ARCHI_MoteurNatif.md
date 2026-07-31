# Moteur natif — dossier d'architecture

Etat : **conception rouverte le 2026-07-31 après confrontation adversariale.**
Ce document consigne ce qui a été établi, ce qui a été mesuré, ce qui a été
corrigé, et ce qui reste à vérifier. Il est écrit pour être relu dans six mois
sans le fil de discussion qui l'a produit.

> **Lis d'abord le §12.** La confrontation a trouvé une **troisième route** que
> ce dossier ignorait (un lecteur JSFX dans la chaîne, qui ouvre lui-même son
> fichier), et elle a invalidé plusieurs affirmations des §1, §3, §4, §5 et §8.
> Les sections corrigées portent la mention **[révisé 07-31]**. Le §11 liste les
> erreurs, le §12 la décision qui tranche tout et les trois mesures à faire.

---

## 1. Pourquoi — et uniquement ce qui est mesuré

Rien ici n'est une intuition. Chaque ligne est un chiffre relevé sur la machine
de l'auteur (ASIO4All et DirectSound, projet à 112 BPM, boucle de 4,571 s).

**L'aperçu SWS (`CF_Preview`) s'affame quand le tampon est petit.** Vitesse de
lecture mesurée de sa tête (`D_POSITION` rapporté contre le temps réel) :

| tampon | vitesse de lecture | retard mesuré à l'enregistrement |
|---|---|---|
| ASIO 64 | **0,54× à 0,91×** | 182 ms |
| ASIO 128 | — | 63 ms |
| ASIO 256 | — | 50 ms |
| ASIO 512 | — | 30 ms |
| ASIO 1024 | **1,0000×** | 30 ms |
| DirectSound | — | 62 ms |
| **kick MIDI (RS5K), enregistré en audio** | — | **1 ms** |

Deux conclusions, et elles ferment le débat :

1. **Le chemin d'enregistrement est propre** (le kick à 1 ms le prouve), donc le
   retard était bien le nôtre.
2. **64 échantillons est le réglage de la performance live**, et l'aperçu n'y
   tient pas. Il est lu à la demande dans le fil audio ; à 1,33 ms d'échéance il
   rate ses rendez-vous, et un rendez-vous raté pour un aperçu veut dire qu'il
   **n'avance pas** — il cale au lieu de craquer, ce qui le rend invisible.

**Ce qui a été essayé et n'a pas suffi** (chronologie, pour ne pas y revenir) :
tir en avance depuis la queue de la boucle ; frontière prise au démarrage du
transport ; tolérance de quantize égale à la frame ; suppression du demi-bloc ;
correction des unités de `D_POSITION` (elles comptent des secondes de LECTURE,
pas de source — `D_LENGTH` = source ÷ taux, mesuré) ; `I_PERFFLAGS`. Chacun a
retiré un vrai défaut. Aucun n'a touché la famine, parce que la famine n'est pas
un problème de calage.

**Le contournement actuel (RS5K)** fonctionne — le son est bloc-exact et ne
s'affame pas — mais il coûte, par colonne : une piste enfant, deux instances de
RS5K, un canal MIDI réservé, un drapeau de lane, un clip d'une note, une note
jumelle un demi-ton au-dessus, une porte à 97 % de la boucle. Tout cela n'existe
que parce que ReaScript ne peut pas tenir un échantillon en RAM ni déclencher
dans le fil audio. **C'est la mesure du bricolage, et c'est ce que le natif
supprime.**

**[révisé 07-31] Avertissement sur la colonne « retard mesuré ».** Ce profil — le
retard qui GRANDIT quand le tampon RÉTRÉCIT — est la signature du traitement
anticipatif, déjà diagnostiqué et corrigé le 2026-07-26 (`9420e75`, raffiné en
`30130db` à `I_PERFFLAGS = 2`). Le drapeau est reparti avec `4a126e5` : `grep
I_PERFFLAGS **/*.lua` rend **zéro** occurrence aujourd'hui. La table mélange donc
deux causes. **La famine (0,54×–0,91× de vitesse de tête) est une mesure séparée,
elle survit intacte, et elle suffit à elle seule.** Le drapeau doit être remis
avant toute nouvelle mesure d'aperçu, sinon on remesurera 147 ms et on cherchera
la cause à l'intérieur du binaire.

**[révisé 07-31] L'argument irréductible du natif n'est aucun de ceux-là. C'est le
warp à taux VARIABLE.** Préserver la hauteur pendant un changement de vitesse
demande un étireur, et tout étireur a une latence de fenêtre qu'aucune API Lua ne
rapporte. Mais il faut distinguer :

- **taux constant** (le cas courant : un clip calé au tempo de la session) — se
  **cuit hors ligne**, une fois, à l'ajout du clip. Il n'y a alors plus d'étireur
  pendant la lecture, donc plus de latence à compenser : elle n'existe pas au
  lieu d'être corrigée. `Bake.FileRegionToWav` (`CP_Engine/Bake.lua:160-186`) fait
  déjà les neuf dixièmes du travail ; il manque `D_PLAYRATE`, `B_PPITCH` et
  `I_PITCHMODE`. Dix lignes.
- **taux variable** (rampe de tempo, warp markers, tempo qui bouge pendant le jeu)
  — irréductible, et c'est le seul cas qui justifie encore l'étireur en direct.

Depuis du code natif on appelle `ReaperGetPitchShiftAPI` (l'élastique de REAPER
lui-même). Sur ce que ça donne exactement, voir la correction §11.9 : **ce n'est
pas « on connaît sa latence »**, c'est « on peut l'amorcer ».

---

## 2. Ce qu'on construit

### 2.1 Le principe de propriété

> **Le moteur possède ce qui doit être exact dans le temps ou continu dans le fil
> audio. Lua possède ce qui est une décision, une description ou un dessin.**

Conséquence directe : **le moteur ne connaît ni scène, ni colonne, ni cellule.**
Il connaît des voix. Les quatre fenêtres ne sont pas quatre moteurs, ce sont
quatre **politiques** sur une même **capacité**.

Une commande ne dit jamais « joue maintenant ». Elle dit **« joue au beat
128.0 »**. La frontière se *décide* en Lua (c'est une décision musicale) et se
*tire* dans le fil audio (c'est de la physique). Une follow action se calcule au
lancement, pas à l'arrivée : deux commandes horodatées envoyées ensemble.

Ce modèle « lecteur » va très loin **à une condition** : que Lua mette toujours
la suite en file à l'avance. Descendre le modèle de session dans le binaire
serait un choix conscient et coûteux (il faudrait recompiler pour changer d'avis
sur ce qu'est une scène). Rien de ce qui est prévu ne l'exige.

### 2.2 Les trois morceaux

| | rôle | pourquoi il existe |
|---|---|---|
| **Extension** `reaper_cpclip` | le cerveau : modèle de voix, ordonnanceur, streamer disque, fils de travail, **et la surface `CP_*` appelable depuis Lua** | seule une extension peut enregistrer des fonctions ReaScript |
| **Plugin** `CP Port` (VST3) | un port par colonne : verse l'audio dans la piste, **et émet le MIDI** vers l'instrument qui suit | seul un plugin est dans le graphe de rendu |
| **Lua** (inchangé dans l'esprit) | toutes les fenêtres, le toolkit, le modèle de session | c'est la couche qui doit rester rapide à changer |

**Le plugin n'est pas un préalable.** L'extension seule peut déjà produire du
son sur une piste (voir §3), ce qui rend le premier jalon audible avec **un seul
binaire**.

---

## 3. Le chemin audio — trois routes, et ce qui les départage

### 3.0 Route « JSFX lecteur » — aucun binaire *[ajoutée 07-31]*

**Un JSFX ouvre lui-même un fichier audio arbitraire, chemin choisi à
l'exécution.** Prouvé sur disque par un JSFX de Cockos livré avec REAPER 7.75,
`Effects/loopsamplers/super8` :

```eel
function load_file(filename, channel) ...      // l.1085, filename = chaine
  (fh = file_open(filename)) >= 0 ? (          // l.1093
    // REAPER 6.29+ will take nch='rqsr' sr>0 as a hint for desired samplerate
    file_riff(fh, nch='rqsr', sr=srate) > 0 ? (  // l.1095
      len = min((file_avail(fh) / nch)|0, g_maxlen);
```
`filename` vient de `gfx_getdropfile` (l.1159-1170). En-tête : `options:
maxmem=<jusqu'à 1 Go> no_meter gfx_idle prealloc=*` — et **`prealloc=*` est la
contrainte zéro-allocation, offerte par une option de description.**

Conséquences :

- **La prémisse « l'audio doit entrer par gmem » est fausse.** C'était une faute
  de plomberie de `CP_ClipEngine.jsfx`, pas une propriété du format : 960 000
  écritures gmem depuis Lua, par paquets de 16384 cadencés au defer, soit ~2 s de
  chargement pour un clip de 10 s. Un `file_open` direct supprime le canal entier.
- **`file_riff` avec `'rqsr'` fait le rééchantillonnage vers le taux de l'hôte.**
  Pas de rééchantillonneur à écrire.
- Le lecteur se place **dans la chaîne, après l'instrument** de la colonne, et
  additionne son audio sur les canaux 1/2 : plus d'envoi, plus de mapping de
  canaux, plus de piste enfant, **plus un seul canal MIDI consommé** — le plafond
  passe de 4 à 7 colonnes sans rien d'autre (voir §4.2).
- Il reçoit `beat_position`, `play_state`, `tempo` **à chaque bloc**, gratuitement.
  C'est précisément la référence de transport qui manque à la route aperçu (§9.6).

Ce que cette route ne fait pas : pas de fil de travail (le chargement se fait en
`@gfx`/`@slider`), donc **pas de streaming disque** ; pas d'accès à l'élastique de
REAPER, donc **pas de warp à taux variable**. Ce sont exactement les deux seules
choses qui justifient encore le natif — voir §12.

### 3.1 Route « aperçu » — extension seule

`PCM_source` est une **classe C++ publique du SDK**. Une extension peut donc
écrire sa propre source dont `GetSamples()` rend ce qu'elle veut, et la donner à
`PlayTrackPreview2Ex` avec `preview_track` renseigné. C'est exactement ce que
fait CF_Preview — **SWS est une extension, et elle met du son dans une piste.**

Forme retenue : **un aperçu permanent par colonne**, jamais arrêté, jamais
repositionné, dont la source est la sortie du moteur pour cette colonne. Il rend
du silence quand rien ne joue. Le timing repasse entièrement à l'intérieur de
notre `GetSamples()`, qui compte ses échantillons — **le lancement redevient
exact à l'échantillon, sur une piste, sans une ligne de VST3.**

### 3.2 Route « plugin » — VST3 sur la piste

Citoyen normal du graphe. Rendu accéléré, gel, PDC, et — le point décisif — il
peut se placer **après** un instrument.

### 3.3 Ce qui les départage

| | aperçu | plugin |
|---|---|---|
| son dans la piste, fader, FX, VU | oui | oui |
| **écoute et ENREGISTREMENT** (sortie de piste, master) | **oui** | oui |
| **rendu ONLINE (temps réel)** | **oui** | oui |
| rendu **offline** (accéléré) | non | oui |
| gel de piste | non | oui |
| compensation de latence automatique | non (compensable à la main : on possède la source) | oui |
| colonne portant **aussi un instrument** | **non** — l'aperçu entre pré-FX, le synthé remplace son entrée par sa sortie | **oui**, placé après lui |
| dépend du service d'aperçu de REAPER | oui | non |
| aucune piste d'infrastructure | oui | oui |

**La vraie justification du plugin est la colonne mixte**, pas le rendu. Le rendu
online et l'enregistrement fonctionnent parfaitement avec l'aperçu ; seul le
rendu accéléré ne le fait pas, et c'est une contrainte mineure pour un
instrument de scène.

---

## 4. Le MIDI — pourquoi un JSFX, et comment s'en détacher

### 4.1 Pourquoi il existe

`CP_MidiLooper.jsfx` vit sur une piste « routeur » dédiée. Il tient les boucles
en gmem (objets note en beats), réconcilie à chaque bloc les notes qui sonnent
contre celles qui couvrent la phase courante (**porte par bloc** — comportement
de Live, et bien fait : une édition prend effet au bloc suivant sans jamais de
note coincée), capture l'entrée live, et possède le quantize de lancement, les
états en attente et l'horloge libre.

Il émet sur **le canal de la lane** (`0x90 + li`), et chaque lane est portée vers
sa piste de destination par un envoi MIDI filtré sur ce canal
(`I_MIDIFLAGS = lane + 1`, `I_SRCCHAN = -1`).

**Il existe pour exactement la même raison que RS5K :** ReaScript ne peut pas
émettre de MIDI dans le flux audio. `StuffMIDIMessage` passe par la file du
clavier virtuel — une diffusion, pas un événement horodaté (c'est d'ailleurs le
canal 16 que le moteur avale, `Kit.UI_CHAN = 15`).

### 4.2 Ce qu'il coûte aujourd'hui

- Une **piste routeur** dédiée.
- Toute la machinerie d'envois filtrés : `wireLane`, `makeLaneSend`,
  `findLaneSend`, `SyncSends`, `RefreshDests`, les GUID de destination en `P_EXT`.
- **Le plafond de 4 colonnes** : `MAX_LANES = 8`, une paire de lanes par colonne.
  Le layout du moteur est devenu la limite du produit — chez Live, aucune limite
  visible par l'utilisateur ne vient de là.
- gmem comme protocole, et l'état d'un clip éparpillé entre gmem, ProjExtState
  et `P_EXT`.
- Les note-on de lecture partent à **l'offset 0 du bloc** (`jsfx:798-799`) ; seul
  le live-thru porte un offset fin (`mofs`, `jsfx:735`). Ce n'est **pas** une
  limite du JSFX — `midisend` prend un offset — c'est un choix qu'on n'a jamais
  révisé. Bloc-exact vaut 1,33 ms à 64 échantillons et 21 ms à 1024.

### 4.3 Peut-on s'en détacher — oui, mais pas avec l'extension seule

Une extension **ne peut pas** injecter du MIDI horodaté dans la chaîne d'une
piste. Il faut être dans le graphe. Donc :

> **Le `CP Port` VST3, placé avant l'instrument de la colonne, émet le MIDI des
> clips MIDI et verse l'audio des clips audio. Un seul objet par colonne, pour
> les deux natures.**

Ce que le détachement achète, au-delà de « moins de pièces » :

- **le plafond de 4 colonnes tombe** ;
- la piste routeur et tous les envois filtrés disparaissent ;
- gmem disparaît comme protocole ;
- l'émission MIDI devient exacte à l'échantillon ;
- **un seul modèle de clip pour les deux natures, en un seul endroit.**

### 4.4 Quand

**Pas au début.** Le JSFX marche, il mesure 1 ms, il n'est pas le problème. Le
détachement se fait quand le plugin existe pour d'autres raisons (colonnes
mixtes, rendu accéléré), et il devient alors presque gratuit.

**Contrainte de la période de cohabitation :** en horloge libre, les deux moteurs
doivent partager la même horloge. **L'extension la possède** (c'est elle qui a la
précision) et le JSFX la lit. C'est le seul couplage à écrire pendant la
transition.

---

## 5. Ce qui est exposé au natif

Depuis un plugin : `IReaperHostApplication::getReaperApi("Nom")` rend les
fonctions de l'API REAPER en pointeurs C — les mêmes que Lua appelle, plus
celles que Lua n'a pas. Depuis une extension : le même jeu, fourni au chargement.

Les trois qui décident :

- **`ReaperGetPitchShiftAPI`** → un `IReaperPitchShift` : l'étireur de REAPER.
  On ne l'écrit pas, on l'appelle. **[révisé 07-31] Il n'expose AUCUN accesseur de
  latence** — interface vérifiée sur `reaper_plugin.h:989` : `GetBuffer`,
  `BufferDone`, `FlushSamples`, `GetSamples`, `Reset`, `SetQualityParameter`,
  `Extended`. C'est un modèle **push/pull**, donc la latence est *observable* (on
  compte ce qu'on pousse et ce qui sort) et surtout **amorçable** : on pré-remplit
  l'étireur pour que le premier échantillon utile tombe pile sur le beat.
  Corollaire absent du dossier initial : **l'amorçage exige un pre-roll, donc un
  lancement immédiat d'un clip warpé ne peut jamais être exact à l'échantillon.**
  Pour comparaison, `REAPER_Resample_Interface` juste au-dessus
  (`reaper_plugin.h:961`) expose bien `GetCurrentLatency()`.
- **`PCM_Source_CreateFromFile` + `PCM_source::GetSamples`** → les lecteurs de
  fichiers de REAPER. **Aucun format n'est perdu** : WAV, MP3, FLAC, OGG, tout ce
  que REAPER lit.
- **`Resample_Create`** → le rééchantillonneur, qualité réglable.

Et ce que la nature du binaire apporte, sans REAPER : **ses propres fils**
(lecture disque, peaks, analyse — hors du fil audio, donc la famine devient
impossible par construction), **sa propre mémoire** (tampons pré-alloués, zéro
allocation dans le fil audio — la contrainte « PC de 2005 » devient tenable par
nous et non par REAPER), le traitement à l'échantillon, la déclaration de PDC.

Pour le pont Lua : une extension enregistre `API_Foo`, `APIdef_Foo` et
`APIvararg_Foo`, et `reaper.CP_Foo()` existe en Lua. C'est littéralement par là
que `CF_*` (SWS) et `JS_*` arrivent déjà dans les scripts.

**[révisé 07-31] Langage : C++17, en style C strict dans le fil audio.** La
conclusion tient, l'argument initial était mort : l'entrée d'extension est
`extern "C"` et CLAP est du C pur, donc « le SDK est C++ » ne décide rien. **Ce
qui décide : `PCM_source` et `IReaperPitchShift` sont des classes abstraites à
vtable** qu'il faut dériver et appeler. En C pur il faudrait fabriquer ces vtables
à la main, avec une disposition qui dépend de l'ABI du compilateur. « Moteur
clean » et « vtable écrite à la main » ne vont pas dans la même phrase.

- **Norme** C++17. **`/EHsc` ON**, avec un `catch(...)` autour de **chaque**
  fonction exportée vers REAPER : une exception qui traverse la frontière C tue
  l'hôte, et couper les exceptions rend la STL formellement non supportée alors
  que `new` jette quand même. **`/GR-`** (pas de RTTI). **`/MT`** : un binaire
  ReaPack atterrit sur des machines sans redistribuable VC++.
- **Jamais `/arch:AVX`.** La baseline x64 de MSVC est SSE2 ; un seul de ces
  drapeaux rend le binaire inexécutable sur un CPU de 2005, avec un plantage au
  chargement et pas un message.
- **Fil audio :** `std::atomic`, `std::array`, pointeurs bruts. Interdits :
  `std::string`, `std::function`, `std::mutex`, `iostream`, destruction de
  `shared_ptr`, **et tout static local** (garde thread-safe + construction à la
  première entrée = une allocation dans le fil audio, une seule fois, donc
  irreproductible). RAII et STL librement dans les 90 % restants.
- **Rejetés, et pourquoi :** *C99* — les vtables. *Zig* — pré-1.0, ne peut pas
  appeler de méthode virtuelle C++, donc on écrit du C++ quand même. *Rust* — le
  gain `Send`/`Sync` s'arrête précisément là où est le risque (les vtables, en
  `unsafe`), pour un coût d'apprentissage réel.

**[révisé 07-31] Format de plugin : CLAP, pas VST3.** L'argument qui décide n'est
aucun de ceux du dossier initial, c'est **la licence**. `LICENSE:1` de ce dépôt est
MIT ; le SDK VST3 est en double licence GPLv3 / accord propriétaire Steinberg. La
première rend le binaire GPLv3-seulement dans un dépôt MIT, la seconde impose
enregistrement développeur et règles de marque. CLAP est MIT, en en-têtes C purs,
avec un port de notes en sortie horodaté en échantillons. Et le plugin n'a besoin
d'**aucune** API REAPER : `clap_process` suffit, le moteur se joint par résolution
de symbole in-process — ce qui supprime `getReaperApi` et la dernière dépendance
au SDK VST3.

---

## 6. La surface d'API — esquisse

Deux couches, délibérément.

**En bas, plate et ennuyeuse** (elle doit être stable ; un ABI qu'on renégocie
est un cauchemar) :

```
CP_VoiceAlloc(out_id)                  -> handle
CP_VoiceLoad(h, path)                  -> ok      (asynchrone, le fil de travail lit)
CP_VoiceSet(h, "rate"|"gain"|"pan"|"loop_start"|"loop_end"|"fade_in"…, v)
CP_VoicePlayAt(h, beat, mode)                     (mode: once | loop)
CP_VoiceStopAt(h, beat)
CP_VoiceState(h, &pos, &playing, &pending)
CP_Peaks(path, from, to, npx, buf)                (le moteur a deja lu le fichier)
CP_SrcInfo(path, &len, &srate, &nch, &bpm)        (une seule reponse sur le tempo)
CP_ClockSet(mode, tempo)                          (suivre | libre)
CP_ClockBeat()                        -> double
```

**Au-dessus, un module Lua unique** — et **c'est lui que toutes les fenêtres
utilisent**. Auditionner, lancer, déclencher un pad, arrêter une colonne : quatre
politiques, un seul chemin. C'est ici que se règle une bonne part de la confusion
actuelle, et c'est **un correctif Lua, pas C++** : le natif ne l'unifie pas tout
seul, il rend l'unification possible en leur donnant enfin une capacité commune
à partager. Aujourd'hui ils n'en partagent aucune.

---

## 7. Ce qui disparaît

Quand la moitié audio bascule :

- la piste enfant « … smp » par colonne, et les **deux RS5K** qu'elle porte ;
- le canal MIDI réservé (9-12), le drapeau `SetLaneAudio`, `Loop.WireAudio` ;
- le clip d'une note, la note-racine 60, la note jumelle 61, la porte à 97 % ;
- la création/destruction d'un aperçu **à chaque lancement** ;
- `previewDest`, qui remonte l'arbre des dossiers pour trouver une piste capable
  d'accepter de l'audio ;
- `rateFor` en trois exemplaires, et les trois réponses différentes au tempo d'un
  même fichier.

Quand le MIDI bascule à son tour : la piste routeur, `wireLane` / `makeLaneSend`
/ `SyncSends`, gmem comme protocole, et le plafond de 4 colonnes.

---

## 8. Les étapes *(ordonnancement initial — REMPLACÉ, voir §12.3)*

> Conservé tel quel pour la trace. Il plaçait la sonde native en premier, la
> persistance `.RPP` avant le plugin, et ne connaissait pas la route §3.0.

**0 — La sonde technique.** Un binaire minimal qui : se charge, enregistre **une**
fonction appelable depuis Lua, implémente un `PCM_source` maison qui rend un
sinus, et le joue via `PlayTrackPreview2Ex` dans une piste. Prouve d'un coup la
chaîne de compilation, l'enregistrement d'API, la source personnalisée et la
route aperçu. **Doit aussi mesurer le service d'aperçu à 64 échantillons sous
charge** — c'est la seule inconnue qui pourrait invalider la route.

**1 — Une voix, juste.** Charger (fil de travail), jouer, boucler, arrêter, à un
taux. Démarrage à l'échantillon exact sur un instant du projet. Mesuré comme on
l'a fait cette semaine, même exigence : **0 ms, à n'importe quel tampon.**

**2 — L'horloge et la grammaire.** Suivre/libre, quantize, file d'attente,
échange sur la frontière, fondu croisé. **Ne pas commencer avant que le modèle
soit arrêté** (voir §10) : écrire un moteur natif autour du modèle actuel
coulerait la confusion dans du béton.

**3 — CP_Session pilote le moteur.** La moitié audio est remplacée ; la liste du
§7 disparaît. Étape essentiellement soustractive.

**4 — Media Explorer et CP_Editor migrent.** L'audition et le lancement partagent
enfin un chemin, et surtout **le même avis sur le tempo d'un fichier**.

**5 — La persistance.** L'extension écrit ses données dans le `.RPP`
(`projectconfig` / `ProcessExtensionLine`). Une session, un fichier, une vérité —
fin du triangle gmem / ProjExtState / `P_EXT`.

**6 — Le plugin `CP Port`.** Colonnes mixtes, rendu accéléré, gel, PDC. Puis le
détachement du JSFX MIDI (§4.3).

**7 — Le reste du monde.** macOS (signature + notarisation), Linux, ReaPack.
Windows x64 / MSVC d'abord, sans complexe. **CMake dès le premier jour** pour que
le portage ne soit pas une réécriture.

---

## 9. Ce que la sonde doit établir

Ce qui suit n'est pas vérifié et pourrait changer la forme :

1. Le service d'aperçu de REAPER tient-il à 64 échantillons sous charge, avec une
   source qui rend depuis la RAM ? (La famine mesurée venait de la **lecture
   disque** ; cette cause disparaît, mais on reste dans un ordonnancement qu'on
   n'instrumente pas de l'intérieur.)
2. Un aperçu injecté dans une piste entre-t-il bien **pré-FX** ? (Cela décide si
   la colonne mixte exige le plugin — hypothèse actuelle : oui, pré-FX.)
3. `PlayTrackPreview2Ex` accepte-t-il une source dont la longueur est infinie /
   inconnue, et la tire-t-il continûment ?
4. Quelles fonctions de l'API sont sûres depuis le fil audio ? (Voie sûre par
   défaut : **aucune** — le fil principal pousse un instantané du transport, le
   fil audio interpole en comptant ses échantillons. On a établi cette semaine
   que la boucle et le projet tournent sur **la même horloge de carte son**, donc
   il n'y a aucune dérive à rattraper.)
5. Coût réel de `IReaperPitchShift` par voix sur la machine cible.

---

## 10. Ce que le natif ne règle PAS — et qui doit passer avant

Onze sources de confusion ont été recensées sur le code réel. **Le natif en règle
trois** : le « Stretch (keeps the key) » qui fait un repitch, le plafond de 4
colonnes, et une partie de l'insertion de pistes. **Il n'en règle pas huit.**

Le diagnostic n'est pas dans le moteur :

- **Rien ne possède « ce clip, dans cette case, dans cet état ».** La vérité d'une
  cellule est répartie sur sept fragments qui ne se connaissent pas, et chaque
  fenêtre la redérive — donc différemment. L'objet manquant est le **ClipSlot**,
  pas le Clip.
- **Il n'existe aucune identité dans le système.** Tout est adressé par
  *position* : indice de lane, indice de colonne, `t*1000+s`. `Clip.CellTag` est
  une clé étrangère inventée parce qu'il manque une table.
- **Le générateur, unique, est une habitude : la fenêtre est l'unité de
  propriété.** Chaque capacité nouvelle a été écrite *dans* la fenêtre qui en
  avait besoin, à côté d'un module partagé qui en faisait déjà 90 %. Neuf
  concepts ont deux maisons pour cette seule raison.

Deux corollaires notés au passage, jamais décidés, devenus des engagements par
inertie : **aucun `Undo_` dans CP_Session** (ouvrir la fenêtre peut insérer une
piste et transformer une piste utilisateur en dossier, sans bloc d'annulation),
et **une cellule son est invisible aux autres fenêtres** (CP_Looper la dessine
« 1 nt » à la hauteur 60).

> **Conséquence sur l'ordre : le modèle d'abord, en Lua, où il coûte des jours et
> non des mois. Le natif ensuite, avec une seule question à répondre.** Fait dans
> l'autre sens, le binaire fige un modèle de clip sur lequel quatre fenêtres ne
> sont pas d'accord, et ajoute un septième endroit où vit l'état d'un clip.

---

## 11. Corrections au dossier — ce qui a été dit et qui était faux

Consigné pour que la trace soit honnête et qu'on n'y revienne pas.

1. **« Une extension ne peut pas produire de son dans une piste »** — **faux.**
   `PCM_source` est publique, `PlayTrackPreview2Ex` prend une piste, et CF_Preview
   *est* une extension qui fait exactement cela. Ce qui est vrai est plus étroit :
   une extension ne peut pas s'insérer comme **FX dans la chaîne** d'une piste.
2. **`Audio_RegHardwareHook` comme sortie principale** — **rejeté.** Il vit à la
   frontière matérielle, hors du graphe : pas de routage, pas de PDC, pas de VU,
   pas d'enregistrement. C'est un second mixeur à côté de celui de REAPER,
   c'est-à-dire la maladie qu'on soigne.
3. **« Ça ne se rend pas »** — **trop fort.** Le rendu **offline** (accéléré) ne
   voit pas les aperçus. L'écoute, l'**enregistrement** de la sortie d'une piste
   ou du master, et le **rendu online (temps réel)** les voient parfaitement.
4. **« Le C++ achète l'exactitude à l'échantillon »** — **faux.** `midisend` prend
   déjà un offset ; le moteur déclenche au bloc **par choix**. Corrigeable dans le
   JSFX en une soirée si besoin.
5. **« Le C++ achète la vitesse »** — **faux.** 1 ms à 64 échantillons, sans une
   ligne de compensation.
6. **« Il faudra embarquer un étireur (Signalsmith, SoundTouch) »** — **inutile.**
   `ReaperGetPitchShiftAPI` donne celui de REAPER.
7. **« On perdra les formats non-WAV »** — **faux**, c'était vrai de la piste
   JSFX. Les `PCM_source` de REAPER lisent tout ce que REAPER lit.
8. **« Si tu veux que le moteur connaisse les scènes ce sera coûteux »** —
   **exagéré**, mais la correction inverse était fausse aussi : voir §11.12.

*Ajoutées le 2026-07-31, après confrontation adversariale :*

9. **« On connaît la latence de l'étireur »** (§1, §5) — **faux.**
   `IReaperPitchShift` (`reaper_plugin.h:989`) n'a aucun accesseur de latence.
   Formulation juste : « on peut l'**amorcer** ». Et le corollaire manquant :
   l'amorçage exige un pre-roll, donc **un lancement immédiat d'un clip warpé ne
   peut jamais être exact à l'échantillon**. C'est une contrainte de modèle, pas
   une découverte d'implémentation.
10. **« Le chemin audio a deux routes »** (§3) — **faux par omission.** Il y en a
    trois. Un JSFX ouvre lui-même un fichier arbitraire (§3.0, prouvé sur
    `super8:1093-1095`). Et **« seul un plugin est dans le graphe de rendu »**
    (§2.2, §3.2, §4.3) est faux : un JSFX est un FX de chaîne. Les **cinq**
    justifications déclarées du `CP Port` sont toutes tenues par un JSFX.
11. **« Le plafond de 4 colonnes vient de `MAX_LANES = 8` »** (§4.2, §7, §10) —
    **faux de nom.** Le mur est le budget de 16 canaux MIDI **par piste routeur** :
    2·T lanes + T son + 1 UI ≤ 16, donc T ≤ 5. Le JSFX le dit lui-même
    (`CP_MidiLooper.jsfx:179-183`). Il se lève par N instances routeur, ou
    disparaît avec §3.0 (un lecteur en chaîne ne consomme plus aucun canal MIDI →
    T ≤ 7 immédiatement). **À retirer de la colonne bénéfices du natif** : la
    version extension le porterait de 4 à 7, pas au-delà.
12. **« Le binaire fige un modèle de clip »** (§10) — **faux tel qu'écrit.** Les
    dix fonctions du §6 ne parlent que de voix. Ce qui fige, c'est **l'étape 5**
    (`projectconfig`), qui fait de la forme du ClipSlot un format de fichier sur
    le disque des utilisateurs. La règle juste est « le modèle avant l'étape 5 »,
    pas « le modèle avant le natif ». Et à l'inverse, §11.8 était trop optimiste :
    legato, fondu croisé sur la frontière et fin exacte d'un one-shot ont une
    fenêtre d'**un bloc** (1,33 ms), alors qu'une frame defer fait 16 à 74 ms.
    Lua ne peut structurellement pas les tenir, et le JSFX MIDI actuel fait déjà
    mieux (`CP_MidiLooper.jsfx:624-723`). Le moteur doit donc posséder **un
    emplacement « suivant » par voix** — `CP_VoiceQueueNext(h, next_h, at, xfade)`.
    Un champ, pas un modèle de session.
13. **« Le natif retire la moitié audio de CP_Session »** (§7) — **chiffré :
    ~140 lignes sur 1685, soit 8 %.** Le bloc RS5K `CP_Session.lua:472-671`,
    `rateFor` 445-457, `retune` 1046-1059, la ré-estampille 2075-2088. 25 % du
    fichier est l'UI de mixer que rien dans ce dossier ne touche. **Ne pas
    budgéter le natif sur la promesse d'un CP_Session plus simple.**

---

## 12. Confrontation du 2026-07-31 — ce qui change

Six analyses adversariales sur code réel, chacune suivie d'un réfutateur, puis une
synthèse. Ce qui suit remplace le §8 et complète le §9.

### 12.1 La question qui tranche le dossier, et qui coûte zéro ligne

> **Quelle est la durée maximale d'un clip audio ?**

Le heap EEL2 est en doubles : 8 s de stéréo à 48 kHz = 6,1 Mo ; 5 minutes = 230 Mo
pour **un** clip.

- **Réponse « des boucles de 1 à 16 mesures »** → la RAM suffit, la route §3.0
  tient, et **le natif perd son dernier argument dur** (il ne reste que le warp à
  taux variable, que la cuisson hors ligne couvre).
- **Réponse « des stems de plusieurs minutes »** → le streaming disque est
  obligatoire, et **rien d'autre que du natif ne le fait.**

C'est une décision **produit**. Elle doit être écrite avant toute autre chose.

Deux autres angles jamais posés : **l'enregistrement audio dans une cellule**
(`CP_Session.lua:855-970` a déjà `armTrack/recCell/pollRec/stopRec` pour le MIDI ;
l'ABI du §6 est un lecteur pur, sans surface de capture — l'aller-retour
enregistrer → fichier → charger n'est pas conçu), et le **pool d'échantillons
partagé** entre instances lectrices, qui décide si la RAM se duplique par colonne.

### 12.2 Les trous bloquants

- **B1 — risque de perte de données.** On ne sait pas si REAPER conserve, **à la
  re-sauvegarde**, les lignes projet d'une extension absente. Si non, ouvrir puis
  sauver un projet CP sur une machine sans le binaire **détruit la session**. Ça
  disqualifie l'étape « persistance » tant que ce n'est pas répondu, et **ça se
  teste sans SDK** : installer une extension tierce qui utilise `projectconfig`,
  sauver, désinstaller, rouvrir, re-sauver, diff du `.RPP`.
- **B2 — la route aperçu n'a aucune référence de transport.** `GetSamples` ne
  reçoit ni `beat_position` ni `play_state`, et le §9.4 s'interdit d'appeler
  l'API depuis le fil audio. Le critère de l'étape 1 (« démarrage exact à
  l'échantillon sur un instant du projet ») est donc **inatteignable par
  construction** sur cette route. Un JSFX les reçoit gratuitement à chaque bloc.
- **B3 — l'ABI du §6 est incomplète sur quatre points**, et un ABI ne se
  renégocie pas : pas de `ReaProject*` en premier paramètre (deux onglets = deux
  sessions) ; **`beat` au lieu d'échantillon** — convertir beat→échantillon dans
  le fil audio y remet la carte de tempo, exactement ce qu'on veut en sortir, donc
  `CP_VoicePlayAtSample(h, int64)` avec le helper en Lua ; **pas de primitive
  d'annulation**, alors que trois fenêtres annulent déjà un rendez-vous ; pas de
  `CP_EngineABI()` ni de garde central, alors que **ReaPack n'a aucun mécanisme de
  dépendance** (mesuré : 89 index, 5993 paquets, zéro élément de dépendance).
- **B4 — aucun plan d'instrumentation.** Le projet entier est justifié par une
  mesure, et la sonde n'a aucun instrument. Jour 1 : anneau de trace lock-free POD
  drainé par le fil principal (un point d'arrêt dans `GetSamples` affame la carte
  et rend l'état observé faux), piège d'allocation en debug, **harnais offline
  déterministe** — un `.exe` dans le même CMake qui linke le cœur sans REAPER.
  Contrainte induite, du même rang que « le moteur ne connaît ni scène ni
  colonne » : **le cœur n'appelle aucune API REAPER.**
- **B12 — la chaîne ReaPack est morte.** `git log -- index.xml` = un seul commit ;
  28 paquets indexés pour 103 fichiers portant `@version` ; `CP_Session.lua` n'est
  pas dans l'index ; **zéro `@provides` dans tout le dépôt**. Et `reapack-index`
  dérive les paquets d'en-têtes de fichiers texte — un `.dll` n'en a pas. On ne
  peut **pas** livrer le binaire par le pipeline actuel.

### 12.3 L'ordonnancement recommandé

Règle transverse, non négociable : **le chemin Lua ne gèle jamais.** Le jour où
une fonctionnalité est mise en attente du moteur, le plan a commencé à échouer.
Le mode d'échec le plus probable n'est pas « le binaire est trop dur », c'est
**ni le binaire fini, ni le Lua avancé.**

| # | étape | coût | on arrête si | coût d'abandon |
|---|---|---|---|---|
| −2 | écrire la durée max d'un clip (§12.1) | 1 ligne | — | nul |
| −1 | la journée d'ergonomie + les 3 bugs Lua | 1 j | — | **négatif** |
| 0 | **les trois mesures (§12.4)** | 1-2 j | — | nul |
| 1 | prototype **lecteur JSFX** (§3.0), ~200 l. | 1-2 j | onset > 1 bloc @64, ou famine à 16 voix | c'est du texte |
| 2 | **cuisson du warp** (`Bake` + 10 lignes) | 1-2 j | la hauteur n'est pas préservée | survit partout |
| 3 | **l'identité** — ClipSlot minimal, ~250 l., 12 sites | 1 j | — | survit à 100 % |
| 4 | **`CP_Engine/Voice.lua`** — le §6 + l'annulation, sur le chemin actuel | 2 j | — | **négatif** |
| 5 | réparer la livraison ReaPack du Lua (`@provides`) | 1-2 j | — | nul |
| — | *bifurcation : la suite n'est justifiée que par le streaming de clips longs ou le warp à taux variable* | | | |
| 6 | sonde native, **boîte de temps 3 j**, avec B4 | 3 j | 4 voix warpées ne tiennent pas sur la cible | 3 j, zéro Lua touché |
| 7 | une voix juste, **boîte 10 j** | 10 j | pas 0 ms à n'importe quel tampon | gratuit côté produit |
| 8 | bascule derrière `Voice.lua` | | régression sur 3 sessions réelles | `git revert` |
| 9 | le plugin **CLAP**, si nécessaire | | | |
| 10 | **la persistance `.RPP`, EN DERNIER**, si B1 est répondu | | B1 négatif | **point de non-retour** |

Trois inversions par rapport au §8 : **l'étape 1 devient un JSFX, pas un binaire**
(si elle tient, les étapes 0, 1, 3 et 6 du §8 tombent) ; **`Voice.lua` s'écrit
avant le binaire**, pour valider l'ABI par l'usage avant qu'un compilateur ne la
fige et pour confiner le futur `if reaper.CP_VoiceAlloc then` à **un** fichier ;
**la persistance passe après le plugin**, parce que le §8 gravait le format de
fichier avant que la chose qui change ce qu'il faut stocker existe.

Ce qu'il ne faut **pas** faire maintenant : l'unification des douze fragments
d'état. ~630 des lignes qu'elle refactorerait sont programmées pour la
suppression. L'identité (étape 3) suffit et survit ; l'unification, non.

Note : `projectconfig` apporte l'**undo** gratuitement (`isUndo` est vrai quand
REAPER sérialise un point d'annulation), ce qui répond à l'un des deux corollaires
« jamais décidés » du §10. Trois pièges : garder le blob petit quand `isUndo`,
l'absence de `ReaProject*` dans les callbacks (→ `GetCurrentProjectInLoadSave`),
et `BeginLoadProjectState` qui doit **remettre à zéro** — sinon l'état du projet
précédent fuit dans le nouveau, et le symptôme (des clips fantômes dans un projet
neuf) ne ressemble pas à sa cause.

### 12.4 Les trois mesures à faire en premier

**Mesure 1 — un JSFX peut-il charger et jouer un fichier arbitraire ?**
*(une demi-journée, zéro C++ — c'est elle qui tranche le dossier)*

- **1a.** Ouvrir `super8` sur une piste, y glisser un `.wav`, puis `.mp3`, `.flac`,
  `.ogg`. Chaque format qui sonne est un format que la route §3.0 conserve.
  → *seul le WAV passe* : il faut une cuisson à l'import, ce que fait de toute
  façon la mesure 2. Ça change le produit, pas la viabilité.
- **1b.** Un JSFX de 20 lignes, `options: gmem=CP_Probe gfx_idle`, `@gfx` fait
  `gmem[0] += 1`. Poser l'effet, **fermer sa fenêtre**, attendre 30 s, lire
  `gmem[0]` depuis Lua. → *le compteur monte* : le chargement de fichier a un fil
  sûr hors du fil audio. *Figé* : replier sur `@slider` forcé par
  `TrackFX_SetParam`. *Ni l'un ni l'autre* : la route §3.0 meurt.
- **1c.** Le prototype joue un fichier sur une frontière de beat, en même temps
  qu'un kick MIDI RS5K sur la **même** frontière. Enregistrer le master, mesurer
  l'écart des onsets. → *≤ 1 bloc (1,33 ms)* : **la moitié audio de ce dossier
  tombe.** *> 20 ms, ou l'écart grandit* : le JSFX s'affame aussi, et il ne reste
  que le natif.

**Mesure 2 — la cuisson préserve-t-elle la hauteur, et en combien de temps ?**

Copier `Bake.FileRegionToWav` (`CP_Engine/Bake.lua:160-186`), ajouter après le
`D_STARTOFFS` :

```lua
r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", mode)   -- EnumPitchShiftModes
r.SetMediaItemInfo_Value(item, "D_LENGTH", (s1 - s0) / rate)
```

Fichier de test : 8 s stéréo 48 kHz, une note tenue, `rate = 0.5`, entouré
d'`os.clock()`. Trois chiffres, trois décisions : **hauteur** (16 s à la même
hauteur ; si elle descend d'une octave, `B_PPITCH` ne traverse pas l'accessor et
toute la piste de la cuisson meurt — le warp redevient l'argument irréductible) ;
**longueur** (exactement 16,000 s) ; **temps mur** (< 1 s → cuisson synchrone ;
1-5 s → avec indicateur ; > 5 s → tâche de fond avec un état « cuisson » sur la
cellule).

**Mesure 3 — la profondeur du traitement anticipatif, avec et sans `I_PERFFLAGS`**

Un JSFX témoin de 15 lignes sur une piste ordinaire : `@block` écrit
`gmem[0] = play_position; gmem[1] = time_precise();`. Un script Lua lit
`GetPlayPosition()` et `time_precise()` à la même frame et publie l'écart. À 1024,
256, puis 64. Puis `I_PERFFLAGS = 2` sur la piste, et refaire les trois.
**L'écart EST la profondeur d'anticipation de cette machine.** S'il grandit quand
le tampon rétrécit, la colonne « retard » du §1 mesurait ça, et `I_PERFFLAGS & 2`
devient un **prérequis explicite** de la route §3.1 — donc une ligne du tableau
§3.3 : « exige un réglage de performance non-défaut sur la piste de l'utilisateur ».

*Bonus, 30 secondes, même montage :* poser ReaSynth sur la piste de destination et
y jouer un aperçu CF_Preview. **Silence** = l'aperçu entre bien pré-FX,
l'hypothèse du §3.3 tient. **Son audible** = la colonne mixte n'exige aucun
plugin, et §3.2 / §3.3 / §8-étape-6 perdent leur seule justification déclarée.

### 12.5 Ce qui reste vraiment incertain

1. **`PCM_source_transfer_t::time_s` est un temps DEMANDÉ, pas un compteur**
   (`reaper_plugin.h:448`). Donc §3.1 « le timing repasse entièrement à
   l'intérieur de notre `GetSamples()`, qui compte ses échantillons » n'est vrai
   **que si** l'hôte demande de façon contiguë et monotone. Rien ne le garantit, et
   un compteur interne qui ignore `time_s` dérive silencieusement dès que l'hôte
   saute — la même classe de bug que `30130db`. La sonde doit **journaliser
   `time_s`** au lieu de faire du son.
2. **Le bloc porte aussi `midi_events`** (même struct). Si un aperçu de piste
   transmet ce MIDI à la piste, le `CP Port` devient inutile pour le MIDI aussi.
   Ne se tranche pas sur l'en-tête : c'est une des questions les plus rentables de
   la sonde.
3. **REAPER route-t-il la sortie de notes d'un CLAP vers le FX suivant**, comme il
   le fait pour un JSFX ? Si non, §4.3 n'a plus de véhicule, quel que soit le format.
4. **La taille max de gmem et l'écriture depuis `@gfx`** — décide si le pool
   d'échantillons se partage entre instances ou se duplique par colonne.
5. **Le coût CPU réel d'`IReaperPitchShift` par voix sur la cible.** Protocole,
   une heure : un étireur, 4096 échantillons avec un clic à l'échantillon 0,
   compter les échantillons de sortie qui précèdent le clic (= la latence, la
   chose que Lua n'a pas et qui justifie tout le projet), puis chronométrer 10 s
   de traitement pour 1, 2, 4, 8 instances. Décisions attendues : taux exactement
   1,0 → **court-circuit** du rééchantillonneur ; linéaire sous ±10 cents, sinc 16
   taps au-delà, **jamais 64** ; pool de **2 étireurs vivants** mutualisés, jamais
   un par voix.
6. **« PC de 2005 » veut-il dire un CPU de 2005 ou Windows XP ?** v143 convient au
   premier et ne peut pas cibler le second (il faudrait `v141_xp`, en fin de vie).
   À écrire **avant** l'étape 0 : sans ça le toolset sera choisi par défaut, et
   irréversiblement.

### 12.6 Décision d'architecture — aucun objet CP dans la chaîne FX de l'utilisateur

*Arrêtée par Cédric le 2026-07-31, après lecture du §3.0.*

> **Critère :** le système ne doit rien poser dans la chaîne d'effets d'une piste
> utilisateur. Un objet inséré est un objet que l'utilisateur peut déplacer,
> désactiver ou supprimer en réorganisant sa chaîne — fonctionnel, mais toujours
> bancal. L'objectif est un système **indépendant**, qui marche sans rien d'autre.

C'est un critère de **propriété**, pas de capacité. Il ne contredit aucune mesure ;
il départage des routes que la technique laissait à égalité. Il devient une ligne
du tableau §3.3, et c'est la plus lourde :

| | JSFX lecteur (§3.0) | plugin CP Port (§3.2) | aperçu + extension (§3.1) |
|---|---|---|---|
| **aucun objet dans la chaîne de l'utilisateur** | **non** | **non** | **oui** |

**Conséquence 1 — la route §3.0 est écartée comme produit.** Elle reste le moyen
le moins cher de *mesurer* si le calage est atteignable (mesure 1c), et elle reste
le filet si la route aperçu tombe. Elle n'est plus la cible.

**Conséquence 2, non anticipée — le `CP Port` tombe sous le même critère.** Un
CLAP ou un VST3 est **aussi** un objet dans la chaîne. Si un JSFX inséré est du
bricolage, un plugin inséré l'est autant : ils ont exactement le même défaut. Donc
**le §2.2 passe de trois morceaux à deux** :

| | rôle |
|---|---|
| **Extension** `reaper_cpclip` | le moteur entier, plus la surface `CP_*` appelable depuis Lua |
| **Lua** | toutes les fenêtres, le toolkit, le modèle de session |

Un seul binaire. Le §8-étape-6, le choix VST3/CLAP du §5 et tout le §4.3
deviennent sans objet **tant que ce critère tient**. C'est une simplification
majeure du plan, obtenue en ajoutant une contrainte.

**Conséquence 3 — B2 devient le trou n°1**, et il se comble par conception, pas
par mesure. La route aperçu est désormais la seule, et son `GetSamples` ne reçoit
aucune référence de transport. La forme retenue reste celle du §9.4 : le fil
principal pousse un instantané du transport (position, tempo, état, horodatage),
le fil audio interpole en comptant ses échantillons, et **`time_s` du bloc sert de
détecteur de discontinuité** (§12.5.1) — pas de source de vérité.

**Conséquence 4 — le MIDI est le seul point qui résiste.** Une extension ne peut
pas injecter de MIDI horodaté dans la chaîne d'une piste. Deux issues, et une
seule mesure les départage :

- **(a)** `PCM_source_transfer_t` porte `midi_events` (`reaper_plugin.h:448`). Si
  un aperçu de piste transmet ce MIDI à la piste, alors **l'affranchissement du
  JSFX est total** : audio et MIDI par le même objet, un seul binaire, aucun objet
  dans la chaîne. C'est l'architecture cible complète.
- **(b)** S'il ne le transmet pas, le `CP_MidiLooper.jsfx` **reste** — il marche,
  il mesure 1 ms, et il est le seul véhicule possible. La promesse « indépendant »
  serait alors tenue pour l'audio et non pour le MIDI.

> **C'est donc la question la plus rentable du projet, et elle se répond en une
> journée de sonde.** Elle doit passer avant toute écriture de moteur : elle décide
> si la cible est « un binaire » ou « un binaire + le JSFX MIDI ».

**Conséquence 5 — la colonne mixte se paie en pistes, pas en plugin.** Si l'aperçu
entre pré-FX (hypothèse §3.3, à mesurer), une colonne ne peut pas porter un
instrument *et* de l'audio. Sous ce critère, la réponse n'est plus « ajouter un
plugin » mais « la colonne audio est une piste, la colonne instrument en est une
autre ». À arbitrer comme un choix de produit.

### 12.7 Ordonnancement révisé sous le critère 12.6

Remplace le tableau du §12.3. Les étapes −2, −1, 3, 4, 5 et 10 sont inchangées :
elles ne dépendaient d'aucune route.

| # | étape | coût | on arrête si | coût d'abandon |
|---|---|---|---|---|
| −2 | écrire la durée max d'un clip (§12.1) | 1 ligne | — | nul |
| −1 | journée d'ergonomie + les 3 bugs Lua (§12.2 / B10) | 1 j | — | **négatif** |
| 0 | **mesure 3** (anticipation) et **mesure 2** (cuisson) — Lua seul | 1 j | — | nul |
| 1 | **la sonde native**, boîte de temps 3 j, avec l'instrumentation B4. Répond dans l'ordre : `midi_events` dans un aperçu de piste ; pré-FX ou post-FX ; famine à 64 avec source en RAM ; contiguïté de `time_s` | 3 j | la sonde ne charge pas, ou l'aperçu s'affame avec une source RAM | 3 j, zéro Lua touché |
| 2 | **`CP_Engine/Voice.lua`** — l'ABI du §6 + l'annulation, sur le chemin actuel (RS5K) | 2 j | — | **négatif** |
| 3 | **l'identité** — ClipSlot minimal, ~250 l., 12 sites | 1 j | — | survit à 100 % |
| 4 | **une voix juste**, boîte 10 j | 10 j | pas 0 ms à n'importe quel tampon | gratuit côté produit |
| 5 | bascule derrière `Voice.lua` | | régression sur 3 sessions réelles | `git revert` |
| 6 | livraison ReaPack (`@provides` du Lua, puis le binaire) | 2 j | — | nul |
| 7 | **la persistance `.RPP`, EN DERNIER**, si B1 est répondu | | B1 négatif | **point de non-retour** |

Deux changements par rapport au §12.3 : le prototype JSFX sort du chemin produit
(il ne reste que comme instrument de mesure si la sonde échoue), et **la sonde
native passe avant `Voice.lua`** — parce que sous le critère 12.6 elle ne prouve
plus seulement une chaîne de compilation : elle décide de la forme de la cible.
