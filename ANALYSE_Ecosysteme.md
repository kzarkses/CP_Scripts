# Analyse de l'écosystème CP — état réel et plan de convergence

> **Document d'analyse, pas de roadmap d'implémentation.** Il sert à cadrer la
> refonte : il décrit ce qui existe *vraiment* dans le dépôt (lecture du code,
> pas des intentions), nomme les duplications, et propose une architecture cible.
>
> Rédigé le 2026-07-21. À relire avant toute grosse refonte.
> Voir aussi : [ANALYSE_Interactions.md](ANALYSE_Interactions.md) (ponts
> inter-apps + manques face aux ténors, 2026-07-22),
> [ROADMAP_CPStudio.md](ROADMAP_CPStudio.md) (vision CP Studio,
> 2026-02) et [CP_Editor/docs/midi-editor-benchmark.md](CP_Editor/docs/midi-editor-benchmark.md).

---

## 0. Périmètre

**Le noyau « création musicale / sound design »** — les scripts qui auraient pu
être natifs à REAPER et qui doivent travailler ensemble :

| Script | Rôle dans la chaîne | UI |
|---|---|---|
| CP_MediaExplorer | **la source** — trouver et faire entrer le son | CP_Toolkit |
| CP_Sampler | **l'instrument** — transformer un son en instrument jouable | CP_Toolkit |
| CP_Editor | **l'établi** — éditer audio et MIDI | CP_Toolkit |
| CP_Looper | **le performeur** — jouer et boucler en live | CP_Toolkit |
| Clip Launcher | **le performeur audio** — session view audio | ReaImGui |
| Meta Mixer / CP Studio | **la console** — mixer + session + item editor | ReaImGui |

**Hors périmètre** (outils autonomes, sans vocation à converger) : CP_PaintSynth,
CP_PoopKit, CP_FloatingToolbar, CP_VideoKit, CP_Inspector, CP_ColorPicker,
CP_ChordLab, Analyzer, Stop Motion, TTM, Track Navigator, Various.
FX Constellation est un cas limite : il partage CP_Toolkit et touche aux FX,
mais son cycle de vie est indépendant.

---

## 1. Le graphe de dépendances réel

Lu dans les `dofile` du code, pas dans les intentions :

```
CP_Toolkit/           Core · Layout · Widgets · Theme · Icons · Keys · Audio · DragBus · Log
   │
   ├── CP_MediaExplorer  → Model · Insert · Preview · Peaks · MediaDB · FXList
   ├── CP_Sampler        → Kit          ⋯⋯> emprunte CP_Editor/Modules/Wave.lua  (pcall)
   ├── CP_Editor         → Wave · Ops · Roll · RollUI
   │                                    ⋯⋯> emprunte CP_Sampler/Modules/Kit.lua
   └── CP_Looper         → Loop         ⋯⋯> emprunte CP_Editor/Modules/Roll + RollUI

ReaImGui (stack séparée)
   ├── Meta Mixer        → 11 modules dont ItemEditor · Waveform · SessionView · BarGrid
   └── Clip Launcher     → Engine · ClipManager · Persistence · Transport · Sequencer · UI
                           + CP_JSFX/CP_ClipEngine.jsfx
```

**Constat n°1 — l'écosystème existe déjà, mais implicitement et en cycle.**
CP_Sampler emprunte à CP_Editor, qui emprunte à CP_Sampler. CP_Looper emprunte à
CP_Editor. Les modules qui servent à tout le monde vivent dans le dossier d'une
application particulière. Ce n'est pas une architecture, c'est une habitude.

**Constat n°2 — une de ces dépendances dégrade en silence.**
`CP_Sampler.lua:33` charge Wave via `pcall` et met `Wave = nil` en cas d'échec :
la forme d'onde du pad disparaît sans un mot si CP_Editor bouge. C'est le signe
qu'on sait déjà que ces emprunts sont fragiles.

---

## 2. La découverte majeure : il y a **deux** écosystèmes qui se recouvrent

Ce n'est pas « 4 apps + des outils standalone ». C'est **deux lignées parallèles
qui construisent la même chose**, sur deux stacks UI incompatibles.

| Capacité | Lignée CP_Toolkit (gfx) | Lignée CP Studio (ReaImGui) |
|---|---|---|
| Session view / lancement de clips | CP_Looper (MIDI, 4 lanes) | Clip Launcher (audio, 16×8) + SessionView |
| Éditeur de clip audio | CP_Editor mode audio | Meta Mixer `ItemEditor.lua` (50 Ko, 7 phases) |
| Rendu de forme d'onde | `Wave.lua` + `Peaks.lua` | `Waveform.lua` (spectral) |
| Grille bar/beat + snap | CP_Editor + CP_Looper | `BarGrid.lua` |
| Transport / tempo | `Loop.lua` lit gmem | `Transport.lua` lit gmem |
| Moteur temps réel gmem | `CP_MidiLooper.jsfx` | `CP_ClipEngine.jsfx` |
| Persistance de session | *aucune* | `Persistence.lua` (autosave) |
| Pitch / stretch | `Ops.lua` (rate/pitch take) | `PitchStretch.lua` (12 algos, stretch markers) |

### CP_ClipEngine : première tentative, modèle de stockage à jeter

`CP_JSFX/CP_ClipEngine.jsfx` v0.4 stocke **l'audio lui-même dans le heap JSFX**,
poussé depuis Lua par gmem. Les chiffres disqualifient le modèle :

- `MAX_CLIP_SAMPLES = 480000` → **10 secondes par clip**, plafond dur. À 120 BPM,
  4 mesures = 8 s : ça passe. 8 mesures = 16 s : **ça ne rentre pas.**
- `freembuf(1000 + 16*8*480000*2)` = 122 881 000 slots. Le heap JSFX est en
  doubles → **≈ 983 Mo réservés**, et `options:maxmem=134217728` déclare un
  plafond de 1 Gio. Rédhibitoire sous la contrainte « PC de 2005 ».
- Le chargement passe par `CHUNK_SIZE = 16384` slots à la fois, en `gmem_write`
  un par un côté Lua puis copie un par un côté JSFX : **≈ 960 000 écritures gmem
  par clip** de 10 s stéréo. Remplir la grille = ~123 millions d'écritures.

Ce n'est pas un moteur à récupérer, c'est un modèle à ne pas refaire. **La leçon
utile : ne jamais stocker d'audio dans gmem.** gmem est un canal de contrôle.

**Ce qui mérite d'être repris — des idées, pas du code :**

1. **La machine à états de lancement quantisé** (`pending_clip` + `pending_quantize`
   0/1/2 = immédiat/beat/mesure). C'est exactement le comportement Ableton qui
   manque encore à CP_Looper, et le concept est juste.
2. **Le fondu anti-clic** (`FADE_STATE`, 128 échantillons ≈ 2,7 ms, rampe de gain
   vers une cible). Indispensable dès qu'on démarre/arrête de l'audio.
3. **`loop_count` republié vers Lua** — permet les *follow actions* (« après 4
   boucles, enchaîner »).
4. **Les cellules `3095` init-count et `3099` version** : c'est la convention que
   `CP_MidiLooper` a reprise. À formaliser comme en-tête gmem partagé.
5. **`Persistence.lua`** — save/load de session avec autosave, indépendant du
   moteur audio. Valable tel quel.
6. **`ClipManager.readAudioFile`** — lit n'importe quel format supporté par REAPER
   vers des échantillons flottants. Brique du futur *bake* / écrivain WAV.

### Alors quel modèle pour l'audio dans le Looper ?

**Le moteur dont tu as besoin est celui que tu as déjà construit.** Une lane du
Looper dont la destination est un pad CP_Sampler *est* une piste de clip audio :

- le fichier reste sur le disque, streamé par REAPER → **coût mémoire ≈ 0**,
  longueur illimitée, tous les formats ;
- le `CP_MidiLooper` fait déjà du déclenchement **verrouillé sur la phase** avec
  routage par canal → « lancer le clip audio de la lane 3 » = une note tenue sur
  le canal 3 ;
- la longueur de boucle, le mute, le launch/stop existent déjà par lane.

Ce qui reste à construire est donc beaucoup plus petit que le ClipEngine :
la quantisation de lancement (idée n°1 ci-dessus) et le tempo-matching du sample.

**L'enregistrement audio** suit la même logique : enregistrer avec REAPER (natif,
robuste, illimité) puis *bake* vers un fichier chargé dans un pad — plutôt que de
réimplémenter un enregistreur en EEL2.

Ce qui fait converger trois chantiers sur une seule brique manquante : **le bake**
(écrivain WAV en Lua pur). Il sert l'édition audio destructive de CP_Editor, les
boucles calées au tempo, et l'enregistrement audio du Looper.

---

## 3. Les duplications, nommées

| # | Capacité | Implémentations | Verdict |
|---|---|---|---|
| 1 | Lecture de peaks | `MediaExplorer/Peaks.lua`, `Editor/Wave.lua`, `Meta Mixer/Waveform.lua` | **3 fois**, dont 2 avec leur propre machine à états `BuildPeaks` 0/1/2 |
| 2 | Cycle de vie `PCM_source` | `Preview.lua` (LRU 12 + cache négatif), `Wave.lua` (source privée), `Insert.lua` (toujours fraîche), `ClipManager.lua` | 4 politiques pour une seule ressource |
| 3 | Tempo-match d'un fichier | `Preview.TempoSyncRate` uniquement | Existe **une seule fois**, inaccessible aux 3 autres apps |
| 4 | Lecture transport/tempo | `Loop.lua` (gmem), `Transport.lua` (gmem), appels directs ailleurs | 2 protocoles gmem distincts |
| 5 | Installation d'un JSFX | `Loop.lua:installJSFX`, `CP_ClipLauncher.lua:installJSFX` | Copie conforme, dossiers cibles différents |
| 6 | Audition d'un son | CF_Preview (Explorer), `StuffMIDIMessage` vers le bus kit (Sampler), transport (Editor) | Mécanismes légitimement différents, mais **aucun point d'entrée commun** → volume, routage et tempo divergent |
| 7 | Propriété d'une piste | `P_EXT:CP_KIT` / `CP_KIT_NOTE`, `P_EXT:CP_LOOPER`, fallback par **nom** de piste (`"CP Kit"`, `"Pad NN"`), MediaExplorer crée des pistes sans marque | Pas de notion partagée de « cette piste appartient à CP » → **c'est ça, l'usine à gaz** |
| 8 | Persistance | `CP_Config/<App>.lua` (bon), sessions Clip Launcher, `P_EXT` piste, gmem volatile | 4 mécanismes, aucune règle |

### Détail sur les peaks (le cas le plus net)

`Wave.lua` et `Peaks.lua` encodent **le même savoir non trivial** — le layout du
buffer `PCM_Source_GetPeaks` (bloc max, bloc min à `count*channels`, 20 bits de
poids faible du retour) — dans deux fichiers, avec deux commentaires qui citent
deux sources différentes pour le vérifier. Leurs forces sont complémentaires :

- `Wave.lua` : plage `[t0,t1]` arbitraire, voies séparées, tableaux poolés
  (contrat zéro-allocation) → **supérieur en lecture**.
- `Peaks.lua` : cache LRU 2 niveaux `[path][width]` sans concaténation de chaîne
  → **supérieur en cache**.

La fusion est mécanique : la lecture de Wave, le cache de Peaks.

---

## 4. Le concept manquant : **le Clip**

Les quatre apps manipulent le même objet sous quatre noms. C'est la raison
profonde pour laquelle les ponts sont pénibles à écrire.

| App | Ce qu'elle appelle « la chose » | Contenu réel |
|---|---|---|
| MediaExplorer | un fichier (+ section, + rate/pitch/vol de preview) | chemin + région + params |
| Sampler | un pad | chemin + start/end offset + root + params RS5K |
| Editor | un item/take (ou une liste de notes) | chemin + startoffs + len + rate + pitch + vol |
| Looper | une lane | liste de notes + longueur en mesures |
| Clip Launcher | un clip | échantillons + longueur + quantize |

**Tous sont : une référence à un média + une région + des paramètres de lecture.**
C'est la définition du clip d'Ableton. C'est aussi la réponse à ta question « on
comprend pourquoi tel son se retrouve dans cette vue, mais s'ouvre aussi dans ces
paramètres, dans cette autre vue » : chez Ableton, **c'est le même objet**, et les
vues sont des vues.

Proposition de descripteur commun — une simple table Lua, schéma documenté :

```lua
Clip = {
  kind    = "audio" | "midi",
  name, color,
  -- audio
  path,                 -- fichier source
  offs, len,            -- région, en secondes source
  root,                 -- note de référence (repitch)
  tempo_mode,           -- "none" | "repitch" | "stretch"
  src_bpm,              -- tempo détecté/annoncé de la source
  gain, pitch, rate,
  -- midi
  notes,                -- tableaux parallèles du modèle Roll
  bars,                 -- longueur de boucle
  -- commun
  launch = { quantize = "none"|"beat"|"bar", mode = "oneshot"|"loop" },
}
```

Chaque app déclare ensuite ce qu'elle sait **émettre** et **accepter**. Le bus
transporte des Clips, plus des chemins de fichiers. À ce moment-là :

- « envoyer une sélection de CP_Editor vers un pad » = émettre un Clip audio ;
- « ouvrir la lane 3 du Looper dans CP_Editor » = émettre un Clip MIDI ;
- « lancer un clip audio dans le Looper » = un Clip audio dans une lane, joué par
  le ClipEngine au lieu du MidiLooper ;
- « une session » = une liste de Clips + le routage. Sérialisable.

---

## 5. Architecture cible : trois couches

Aujourd'hui il y en a deux (toolkit / apps) et les services de domaine sont
éparpillés dans les apps. Il en faut trois :

```
┌─ CP_Toolkit ──────────────────────────────────────────────┐
│  UI pure. Aucune connaissance du domaine musical.         │  ← inchangé
└───────────────────────────────────────────────────────────┘
┌─ CP_Engine (NOUVEAU) ─────────────────────────────────────┐
│  Services de domaine. AUCUNE UI. Testable seul.           │
│    Media      sources PCM, LRU, métadonnées   ← Preview   │
│    Peaks      un seul lecteur                 ← Wave+Peaks│
│    Audition   preview + tempo-match           ← Preview   │
│    Insert     média → projet, ghost, swap     ← Insert    │
│    Roll       modèle MIDI + backends          ← Roll      │
│    Kit        sampler RS5K                    ← Kit       │
│    Loop       pont looper gmem                ← Loop      │
│    Ops        édits audio non destructifs     ← Ops       │
│    Tempo      tempo/grille/transport          ← NOUVEAU   │
│    Tracks     propriété + dossier CP          ← NOUVEAU   │
│    Bus        messages inter-apps             ← DragBus   │
│    Mod        modulation: LFO et au-delà      ← ModJSFX   │
│    Clip       le descripteur + (dé)sérialisation ← NOUVEAU│
└───────────────────────────────────────────────────────────┘
┌─ Applications ────────────────────────────────────────────┐
│  UI + workflow uniquement. Zéro logique de domaine.       │
└───────────────────────────────────────────────────────────┘
```

Règle qui rend la chose vérifiable : **une app ne fait jamais `dofile` dans le
dossier d'une autre app.** Aujourd'hui cette règle est violée trois fois ; c'est
un test automatisable en une boucle sur les sources.

---

## 6. Le hub JSFX global

Décision déjà actée en discussion, à préciser ici.

Un JSFX unique dans la chaîne **Monitoring FX**, publiant dans un gmem partagé :
tempo, signature, position en beats, play state, samplerate — et à terme le tempo
reçu par **MIDI clock** externe. Tous les scripts le lisent au lieu d'interroger
REAPER chacun de leur côté.

- Il remplace la publication transport de `CP_MidiLooper.jsfx` et de
  `CP_ClipEngine.jsfx` (aujourd'hui redondantes, à deux adresses différentes).
- Il donne enfin au **Sampler** une notion de tempo, qu'il n'a pas du tout
  (vérifié : zéro occurrence de tempo/bpm/playrate dans tout CP_Sampler).
- ⚠️ **Non vérifié** : que le MIDI d'un périphérique matériel atteigne les
  Monitoring FX sans piste armée. À tester avant de figer ce design.

**Limite gmem à connaître** : un espace gmem est nommé et partagé par tous les
scripts qui l'attachent, sans limite de nombre d'espaces. Le vrai plafond est la
mémoire (`CP_ClipEngine` réserve déjà 128 Mo via `maxmem`) et l'absence
d'atomicité : gmem n'a pas de verrou, donc tout protocole doit rester
« un seul écrivain par cellule », comme le fait déjà `nev` dans le looper.

---

## 7. Convention de pistes — la vraie réponse à « l'usine à gaz »

Le sentiment d'usine à gaz ne vient pas du nombre de scripts, il vient de N pistes
et M FX sans organisation visible. Aucune fusion d'interface ne le corrigera.

Ce qui le corrige :

1. **Un dossier `CP` unique** dans le projet, contenant tout ce que la suite crée
   (routeur du looper, kit du sampler, bus…). Repliable d'un clic.
2. **Une marque commune** : `P_EXT:CP = "<app>:<role>"` sur chaque piste créée,
   en plus des marques spécifiques existantes. Une seule fonction
   `Tracks.Ensure(app, role, name)` la pose.
3. **Interdire le fallback par nom.** `Kit.lua` retrouve ses pads en cherchant les
   noms `"CP Kit"` / `"Pad NN"` : un simple renommage par l'utilisateur casse la
   découverte. La marque `P_EXT` doit être la seule autorité.

---

## 8. Par application : évolutions et convergences

### CP_MediaExplorer — la source
**Actifs uniques :** `Model` (arbre, recherche tokenisée, favoris, collections),
bootstrap `MediaDB` sur les bases natives de REAPER, `Insert` (drag fantôme avec
item réel qui suit la souris, hot-swap de source), `Preview` (le seul tempo-match).

**Convergence :** `Preview`, `Peaks` et `Insert` sont des services, pas des
fonctionnalités de navigateur → ils montent dans CP_Engine. Les « collections »
sont un proto-concept de session.

**Évolution :** un unique sélecteur de destination (« envoyer vers… pad / lane /
arrangement / éditeur ») à la place de boutons dédiés par cible. Émettre un Clip.

### CP_Sampler — l'instrument
**Manque criant :** aucune notion de tempo. C'est le prérequis des boucles
audio synchronisées, et la brique existe ailleurs (`Preview.TempoSyncRate`,
qui s'appuie sur `GetTempoMatchPlayRate`, la routine du Media Explorer natif).

**Réserve honnête :** caler une boucle au tempo via RS5K passe par le taux de
lecture, donc la hauteur suit (effet vinyle). Acceptable et souvent désirable ;
du vrai time-stretch demanderait un pré-rendu — et `PitchStretch.lua` du Meta
Mixer contient déjà 12 algorithmes à récupérer.

**Convergence :** un pad *est* un Clip audio. Le Sampler devient le fournisseur
de voix audio pour le Looper.

### CP_Editor — l'établi
**Observation :** ce sont deux applications dans un même manteau — un éditeur
audio et un éditeur MIDI qui ne partagent que la fenêtre. Ce n'est pas un défaut,
mais ça explique la taille du fichier principal (79 Ko).

**Concurrent interne :** `Meta Mixer/Modules/ItemEditor.lua` (50 Ko) fait le même
travail côté audio, avec en plus stretch markers interactifs, sélection de région
et grille configurable. **Il faut trancher lequel survit** — écrire une troisième
version serait la pire issue.

**Évolution :** troisième cible « lane de loop » (le backend existe déjà dans
`CP_Looper.lua:makeLoopBackend`, il suffit de le déplacer dans `Loop.lua`), puis
le **bake destructif** via un écrivain WAV en Lua pur — la capacité manquante qui
referme la boucle vers le Sampler et l'Explorer.

### CP_Looper — le performeur
**Convergence immédiate :** il est déjà client de `Roll`. Il doit devenir client
de `Tempo` et, pour l'audio, de `ClipEngine` plutôt que d'un nouveau moteur.

**Manque :** persistance. `Clip Launcher/Modules/Persistence.lua` existe et fait
exactement ça. Aujourd'hui les loops vivent le temps de la session REAPER.

### FX Constellation + CP_ModLFO — le modulateur *(ajout 2026-07-22)*
Décision utilisateur : **CP_ModLFO doit devenir entièrement standalone.** Il a
été codé dans le dossier de FX Constellation par accident historique, et
`ModJSFX` est de fait l'embryon d'un service de modulation généraliste — « il
pourrait avoir d'autres mods que seulement des LFO » ; la cible ressemble aux
modulateurs de Bitwig. À terme : `Engine/Mod` (ModJSFX + LinkEngine, sans UI),
et CP_ModLFO devient une simple vue dessus. FX Constellation aura ensuite sa
propre refonte d'interface (knobs partout — le grid de 2026-07 est le premier
pas —, ergonomie « Ableton » où chaque élément a une place pensée) ; pas avant
le socle.

### Clip Launcher + Meta Mixer — carrière de pièces, pas socle
Ils sont sur ReaImGui alors que tout le noyau est passé sur CP_Toolkit, et le
Clip Launcher repose sur un modèle de stockage à jeter (§2).

**Recommandation : les traiter comme une carrière**, pas comme une base à porter.
On en extrait des briques précises, on archive le reste :

| À extraire | Vers | Pourquoi |
|---|---|---|
| `Persistence.lua` (save/load + autosave) | `Engine/Session` | Indépendant du moteur audio ; comble le manque n°1 du Looper |
| `ClipManager.readAudioFile` | `Engine/Media` | Brique du bake / écrivain WAV |
| `PitchStretch.lua` (12 algos, stretch markers) | `Engine/Ops` | Ce que `Ops.lua` ne sait pas faire |
| Quantisation de lancement + fondu anti-clic | `CP_MidiLooper.jsfx` | Concepts, ~30 lignes chacun |
| `BarGrid.lua` (grille configurable + snap) | `Engine/Tempo` | Déjà écrit, déjà testé |

`ItemEditor.lua` (50 Ko) est le cas à trancher : il fait le même travail que le
mode audio de CP_Editor, avec en plus stretch markers interactifs et sélection de
région. **Choisir lequel survit** — en écrire une troisième version serait la
pire issue.

---

## 9. Ordre proposé pour Fable

Chaque étape est utile seule et ne dépend que des précédentes.

| # | Chantier | Pourquoi d'abord |
|---|---|---|
| 1 | ✅ **FAIT 2026-07-22.** Créer `CP_Engine/`, y **déplacer** Roll, RollUI, Wave, Ops, Kit, Loop, Preview, Peaks, Insert. Aucune réécriture. | Casse le cycle de dépendances. Purement mécanique, donc sûr. |
| 2 | ✅ **FAIT 2026-07-22.** Fusionner les deux lecteurs de peaks (lecture de Wave + cache de Peaks) → `CP_Engine/Peaks.lua`, deux surfaces (`Read` vue éditeur, `Get` bandeau navigateur) sur un seul cœur. | La duplication la plus nette, le gain le plus immédiat. |
| 3 | `Engine/Tempo.lua` + hub JSFX Monitoring FX | Débloque le sync BPM du Sampler et unifie deux protocoles gmem. |
| 4 | `Engine/Tracks.lua` : dossier CP + marque `P_EXT:CP`, suppression du fallback par nom | Règle l'usine à gaz, visible immédiatement. |
| 5 | `Engine/Clip.lua` : le descripteur + (dé)sérialisation | Prérequis de tout le reste. |
| 6 | Persistance des loops via Clip (P_EXT du routeur), en reprenant `Persistence.lua` | Petit, et rend le concept de session réel. |
| 7 | Généraliser DragBus en `Engine/Bus.lua` transportant des Clips | Les ponts deviennent triviaux à ajouter. |
| 8 | Sync BPM du Sampler (§8) + quantisation de lancement dans `CP_MidiLooper` | Débloque les clips audio sans nouveau moteur. |
| 9 | **Bake** : écrivain WAV en Lua pur | Keystone : édition destructive + boucles calées + enregistrement audio. |
| 10 | Trancher CP_Editor vs `ItemEditor.lua`, extraire les briques retenues | Demande une décision, pas du code. |

---

## 10. Ce qu'il ne faut **pas** faire

- **Ne pas fusionner les fenêtres** des deux éditeurs MIDI. Le comportement est
  déjà unifié (Roll + RollUI) ; la fenêtre séparée est un *atout* : contrats de
  latence opposés (le Looper ne throttle jamais, l'Editor si), modes de
  défaillance découplés, et multi-écran possible. Une fenêtre gfx = une seule
  boucle defer, donc fusionner impose le pire des deux régimes.
- **Ne pas construire une coquille runtime commune** (un lanceur, des apps dockées
  dans une fenêtre unique). Partager les *fondations* : oui. Partager le
  *processus* : c'est là que les suites de scripts meurent.
- **Ne jamais stocker d'audio dans gmem.** C'est ce qui a coulé `CP_ClipEngine`
  (≈ 1 Gio réservé, 10 s par clip, ~960 000 écritures gmem par chargement). gmem
  est un canal de **contrôle**. L'audio reste sur le disque, streamé par REAPER.
- **Ne pas réécrire un moteur de clip audio.** Le Looper + le Sampler en forment
  déjà un ; il manque la quantisation de lancement et le tempo-matching.
- **Ne pas ajouter de fonctionnalité avant l'étape 1.** Chaque nouvelle
  fonctionnalité écrite dans le dossier d'une app y reste piégée — c'est
  exactement comme ça que `TempoSyncRate` est devenu inaccessible.
