# Moteur natif — dossier d'architecture

Etat : **conception arrêtée, rien n'est écrit.** Ce document consigne ce qui a été
établi, ce qui a été mesuré, ce qui a été corrigé, et ce qui reste à vérifier par
la sonde technique. Il est écrit pour être relu dans six mois sans le fil de
discussion qui l'a produit.

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

**L'argument irréductible du natif n'est pourtant aucun de ceux-là. C'est le
warp.** Préserver la hauteur pendant un changement de vitesse demande un
étireur, et tout étireur a une latence de fenêtre. Depuis Lua, cette latence
n'est rapportée par **aucune API** — c'est ce qui a produit un décalage constant
de 40 ms que rien ne pouvait corriger. Depuis du code natif, on appelle
`ReaperGetPitchShiftAPI` (l'élastique de REAPER lui-même) et **on voit ce qu'on a
donné et ce qui est sorti**, donc on compense.

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

## 3. Le chemin audio — deux routes, et ce qui les départage

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
  On ne l'écrit pas, on l'appelle, **et on connaît sa latence**. Le seul argument
  irréductible du projet.
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

**Langage : C++.** L'ABI est du C, les en-têtes sont C++, le SDK VST3 l'est
franchement. Du C pur coûterait cher sans rien acheter.

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

## 8. Les étapes

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
   **exagéré.** Le modèle lecteur suffit tant que Lua met la suite en file à
   l'avance, ce qu'il fait déjà. Le risque est réel mais bien plus petit
   qu'annoncé.
