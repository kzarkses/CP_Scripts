# Interactions & manques — l'écosystème CP face aux ténors

> **Complément de [ANALYSE_Ecosysteme.md](ANALYSE_Ecosysteme.md)** (qui décrit
> l'architecture cible ; ce document décrit les *workflows*). Rédigé le
> 2026-07-22 à partir du code réel : 7 lecteurs (un par app), 5 lentilles de
> comparaison (Ableton Live, FL Studio, Bitwig, Maschine/MPC, REAPER natif
> sous-exploité), 1 matrice de ponts. Meta Mixer volontairement non analysé
> (chantier à part).
>
> Objectif de référence, dans les mots de l'utilisateur : **« créer un
> écosystème viable et complet dans REAPER »**.

---

## 1. La matrice des ponts inter-apps

### 1.1 Ce qui existe déjà — quatre ponts réels

| Pont | Canal | Limite actuelle |
|---|---|---|
| Explorer → Sampler (fichier → pad ciblé, highlight au survol) | DragBus `kind=file` | **Le pont de référence** — mais il transporte un path nu : la section sélectionnée dans la bande waveform est perdue au drop |
| Editor → Sampler (slices → pads ; sélection → instrument chromatique) | `Kit.lua` en direct + ExtState `CP_Sampler/instrument` (path+offsets, TTL 5 s) | La mécanique à offsets prouve que le descripteur Clip (média+région) est le bon objet — elle est juste câblée en privé |
| Explorer / Sampler → Editor (« Open in Editor ») | ExtState `CP_Editor/open` | Path nu : l'Editor s'ouvre sur le fichier entier, pas sur la section auditionnée |
| Editor ↔ Looper (pont de *code* : Roll + RollUI partagés) | dofile CP_Engine | Toute op ajoutée à Roll sert les deux — mais il n'y a AUCUN canal *runtime* entre eux |

### 1.2 Les deux demi-ponts morts — émetteur en production, zéro consommateur

Le meilleur ratio valeur/effort de toute la matrice :

1. **Sampler → Explorer.** Le drag d'un pad hors fenêtre publie déjà DragBus
   `kind=file` (CP_Sampler.lua:735). L'Explorer n'est **jamais** consommateur
   (publisher only). Le rendre consumer = la boucle de curation « ce sample
   marche, range-le en collection ».
2. **Explorer (chip FX) → FX Constellation.** L'Explorer émet déjà DragBus
   `kind=fx`. FX Constellation ne consomme rien du DragBus. Le brancher =
   UN browser pour samples ET plugins, et un browser redondant à retirer à
   terme.

### 1.3 Les deux ponts « par accident » — à officialiser

- **ChordLab → Editor** : ChordLab écrit dans l'item sélectionné, l'Editor se
  resynchronise par `GetProjectStateChangeCount`. Ça marche par coïncidence.
  Officialisé (message de ciblage sur le Bus), ça donne un vrai mode
  « harmonie » au piano roll.
- **ChordLab → Sampler** : la queue VKB de ChordLab atteint probablement le
  bus « CP Kit MIDI » armé. Officialisé, on choisit ses voicings avec le son
  réel du kit. Idem **banque globale CP MOD → pads** : les pads étant des
  pistes ordinaires, la modulation peut déjà les toucher — mais la matrice ne
  sait pas dire « Kit / Pad 3 / Tune » (ça, c'est `Engine/Tracks` + `Engine/Mod`).

### 1.4 Ce que Clip + Bus débloquent, par valeur décroissante

| # | Pont | Ce qui manque | Coût |
|---|---|---|---|
| 1 | **Looper → arrange / Editor** : imprimer une boucle en item MIDI sur la piste déjà routée de la lane | L'op d'export seule — les notes sont lisibles côté Lua, `CreateNewMIDIItemInProj` + `MIDI_InsertNote` existent | **S** |
| 2 | **Sortie de piste → Explorer / pad** : résampler une piste ou la time selection vers une collection « Renders » ou un pad | Le bake (planifié) + le drop | M |
| 3 | **Looper → Sampler** : figer un motif jammé en loop audio sur un pad (rendu via le send existant, coupes garanties par le phase-lock) | bake + Clip/Bus | M |
| 4 | **ChordLab → Looper** : poser une progression validée à l'oreille dans une lane et jammer dessus | Clip MIDI + réception côté Loop (l'écriture de notes en gmem existe) | S |
| 5 | **SoundGen → Sampler** : rendre un patch (kick, perc) en WAV → pad en un geste | bake — **premier vrai pont entre les deux lignées parallèles** | S |
| 6 | **Hub Tempo → previews + lancements** : audition start-on-beat/bar, quantisation de lancement partagée | Engine/Tempo + hub (chantier 3) — ce pont est sa raison d'être musicale | M |
| 7 | **Editor → Explorer** : publier une sélection éditée comme WAV dans « Renders » | bake + collection cible | S |
| 8 | **Explorer → Looper** : drop d'un .mid sur une lane | Petit parseur SMF dans l'Engine (seul morceau neuf) | M |
| 9 | **Looper ↔ session audio unifiée** : clips MIDI et audio, même objet lançable | Le descripteur Clip complet — pont structurel, il rend les ponts 1/3/6 cohérents | L |

Lecture d'ensemble : **le bake (chantier 9) alimente les ponts 2, 3, 5, 7** —
c'est bien la clé de voûte annoncée. Et le Clip est confirmé par l'existant :
Editor→Sampler transporte déjà, en privé, exactement média+région+params.

---

## 2. Les manques, croisés sur cinq lentilles

### 2.1 Le verdict transversal — ce qui revient dans 3+ lentilles

**1. Le jam meurt sur place** *(5 lentilles sur 5 — LE trou n°1).*
Rien de ce qui se joue en session ne devient un morceau : le Looper ne sait
pas exporter une boucle en item MIDI, rien n'imprime une performance sur
l'arrange. Côté MIDI le coût est **S** (API native). C'est le manque qui
sépare « suite d'instruments de jam » de « outil de composition ».

**2. Pas d'overdub dans le Looper** *(4 lentilles).*
REC efface et recapture : kick au 1er tour, snare au 2e, hats au 3e — le
geste fondateur de tout looper/groovebox — est impossible. Fix côté JSFX :
fusionner la capture dans les notes gmem au lieu d'écraser. **S/M.**

**3. Aucune expression continue** *(4 lentilles).*
Pas de lanes CC/pitch-bend/aftertouch nulle part : l'Editor n'édite que la
vélocité, le Looper avale CC/PB en thru sans les boucler. Un filter sweep
joué pendant l'enregistrement est perdu. L'insight de la roadmap tient :
**commencer par CP_Editor** (le TakeBackend écrit du vrai CC via l'API MIDI),
le Looper (protocole gmem) ensuite.

**4. Pas d'undo sur les états hors-projet** *(3 lentilles).*
Les outils dont la proposition de valeur EST le hasard (randomizers FXC :
valeurs, ordre FX, bypass, ultra random) ne posent aucun bloc undo ; l'édition
de notes du Looper est irréversible. Blocs undo natifs autour des ops
destructives (**S**) + anneau de snapshots pour le gmem. « On ose le dé parce
que Ctrl+Z existe. »

**5. Un sample par pad** *(5 lentilles).*
Kits « mitraillette » : pas de velocity layers ni round-robin — alors que
MINVEL/MAXVEL existent déjà dans Kit.P sans UI, et que RS5K accepte plusieurs
instances par piste pad (pattern mpl RS5K manager). **S** pour exposer les
plages, **M** pour layers/round-robin complets.

**6. La boucle de resampling n'existe pas** *(4 lentilles).*
Pas de bounce de kit, pas de rendu de sélection, pas de capture de sortie.
REAPER offre pourtant **Apply-FX (40209) et Glue (40362) natifs** — un chemin
S avant même l'écrivain WAV pur Lua. Répare au passage le cul-de-sac Reverse
de l'Editor (preview cassé sur source section).

**7. Tout se pilote à la souris** *(4 lentilles).*
Le Looper — l'outil le plus « performance » — n'a ni actions REAPER
enregistrées ni MIDI-learn : impossible d'armer un REC à la pédale. Actions
par script compagnon + traduction MIDI→commandes gmem existantes : **S**.

**8. Le preview ignore le transport** *(3 lentilles).*
Le tempo-match ajuste le *rate* mais jamais la *phase* : impossible de juger
si un loop groove avec le projet en lecture. Le Media Explorer natif fait
start-on-bar depuis des années. Débloqué par le chantier 3 (Engine/Tempo).

**9. Slice → pattern s'arrête à mi-chemin** *(3 lentilles).*
Le chop existe (transitoires → pads) mais le pattern MIDI qui rejoue la
phrase originale n'est jamais généré : le break chopé est muet tant qu'on ne
l'a pas ressaisi à la main. Temps des transitoires et mapping notes/pads déjà
connus — il ne manque que l'écriture des notes. **S** (une fois le pont 1 fait).

**10. Le groove est une édition, pas un paramètre** *(3 lentilles).*
Swing uniquement comme quantize destructif dans Roll — pas de knob de groove
temps réel, pas de groove pool partagé Editor/Looper/Sampler.

### 2.2 Le reste notable, par lentille

**Ableton** — capture MIDI rétrospective (le buffer d'écoute sur le routeur :
« la phrase que je viens de jouer », récupérable après coup) ; racks/macros
nommées portables (FXC n'a que x/y et un presets.dat captif) ; clips audio
longs (le plafond 10 s du ClipEngine est acté comme impasse).

**FL Studio** — step sequencer/channel rack : LA boucle « idée → beat audible
en 30 s » n'a aucun équivalent (le drum mode Roll + les lanes du Looper sont
les briques naturelles) ; ghost notes dans le roll ; métadonnées + index
persistant du browser (démarrage instantané).

**Bitwig** — la lentille la plus utile pour `Engine/Mod` : **la qualité des
modulateurs conditionne tout** (lissage de sortie — un square en CC 14-bit
produit des marches —, courbes custom, one-shot/enveloppes déclenchables,
re-sync de phase). À spécifier AVANT de figer Engine/Mod. Aussi : note FX
temps réel (arp/euclidien/voicings existent déjà en offline dans trois
codebases — un seul JSFX « CP NoteFX » les rentabilise en live) ; opérateurs
par note (chance, repeats) dans le gate de lecture du JSFX Looper.

**Maschine/MPC** — note repeat synchronisé ; input quantize + métronome en
mode Free (le quantize existe, il n'est jamais appliqué à la capture) ;
mixette du kit dans l'UI du Sampler (la plomberie piste-par-pad existe
intégralement, seule l'UI manque — **S**) ; banques de patterns A-H et scènes
chaînables (L, plus tard).

**REAPER natif** — la lentille au levier le moins cher, quatre S immédiats :
hot-swap en **take alternative** (`AddTakeToMediaItem`) au lieu d'écraser la
source — l'A/B de sound-replacement gratuit ; **take markers natifs** pour
persister les transitoires détectés ; presets aux **formats natifs**
(.RfxChain pour FXC, .RTrackTemplate pour les kits — fin des blobs captifs) ;
lignes **DATA des MediaDB** (BPM/key/tags déjà streamés puis jetés au parse —
des années de tagging utilisateur perdues, et le tempo-match devine des BPM
qui sont écrits dans le fichier). Plus une idée structurante : les **fixed
item lanes de REAPER 7** comme stockage natif de variations/patterns, au lieu
d'un moteur de session maison plafonné.

### 2.3 État par piste : une dette transversale

FX Constellation garde sélections/ranges/routages par GUID dans des fichiers
**globaux** (selections.dat) : un projet partagé ou déplacé perd toute sa
modulation alors que les plinks, eux, sont dans le .rpp. À migrer vers
P_EXT/ProjExtState — s'inscrit dans le chantier 4 (`Engine/Tracks`) et la
persistance de session (chantier 6).

---

## 3. Conséquences sur le plan moteur (§9 de l'analyse écosystème)

Les chantiers 3-9 sortent **confirmés et précisés** :

1. **Chantier 3 (Tempo + hub)** : sa raison d'être musicale est le pont n°6
   (preview en phase + quantisation de lancement partagée). Le spec doit
   inclure « start-on-beat/bar » pour CF_Preview dès le départ.
2. **Chantier 5 (Clip)** : validé par l'existant — Editor→Sampler transporte
   déjà média+région+params en privé. Le Clip doit porter les notes MIDI
   (variante `kind="midi"`) pour servir les ponts 1, 4, 8, 9.
3. **Chantier 9 (bake)** : clé de voûte confirmée — quatre ponts en dépendent.
   Mais un **chemin court existe avant lui** : les actions natives Apply-FX /
   Glue couvrent le resampling piste→fichier dès maintenant (coût S).
4. **Engine/Mod** : ajouter au cahier des charges la qualité Bitwig (slew,
   courbes, one-shot, re-sync) — sinon la modulation généralisée restera
   cantonnée aux pads de texture.
5. **Nouveaux, absents du plan, à fort levier et coût S** — candidats à
   intercaler après le socle : export Looper→item MIDI (pont 1) ; overdub
   Looper ; blocs undo natifs sur les ops destructives ; demi-ponts DragBus
   (1.2) ; velocity layers UI ; take alternatives pour le hot-swap ;
   DATA des MediaDB ; contrôle MIDI externe du Looper.
6. **Les gros morceaux assumés pour plus tard** (L) : session view unifiée
   audio+MIDI, step sequencer/patterns première classe, banques/scènes,
   expression par note complète.
