# CP_Editor confronté aux références

Tout ce qui est affirmé du code a été **lu** (chemins absolus en fin de document). Les affirmations sur REAPER sont marquées *vérifié* avec leur source ; celles sur Ableton/FL portent leur URL. Aucun fichier modifié.

---

# 0. LA QUESTION QUI DOMINE : cet éditeur a-t-il une raison d'exister ?

## 0.1 Le fait qui tranche, et il est déjà dans le code

Le bouton « Open in REAPER's MIDI editor » n'est dessiné **que si `state.item` existe**, avec ce commentaire :

> `CP_Editor.lua:2462` — `if state.item then   -- take-backed only (a clip has no native editor)`

C'est la réponse entière, et elle était déjà écrite. **Une cellule de session et une lane de looper ne sont pas des takes.** Une cellule est un descripteur `Clip` sérialisé « s,l,p,v; » ; une lane est un tampon `LaneNote` dans le binaire natif. L'éditeur MIDI de REAPER ne sait ouvrir qu'un take dans un item : il ne peut pas ouvrir ces objets, et aucune option, aucun réglage, aucune extension ne le lui fera faire.

Donc la question n'a pas une réponse mais **trois**, une par territoire.

## 0.2 Les trois territoires

| Territoire | Concurrent natif | Verdict |
|---|---|---|
| **Mode `clip`** (cellule de session, lane de looper) | **aucun** — il n'existe pas | **Justifié à 100 %.** C'est la seule surface d'édition de ces objets. Tout l'investissement futur du roll appartient ici. |
| **Mode `midi`** (take d'un item) | l'éditeur MIDI natif, à **un** bouton (`Main_OnCommand(40153)`, `:2466` — *vérifié : `40153=Item: Open in built-in MIDI editor`*, actionlist REAPER) | **Justifié pour une seule chose : la continuité.** Mêmes touches, mêmes rangées drum nommées d'après le kit, même menu Transform, même fenêtre que la moitié audio. Pour tout le reste, il réécrit moins bien — et sur un point, **il détruit** (§I.D.1). |
| **Moitié audio** | ce n'est pas le même concurrent du tout : l'arrangement de REAPER, sa Media Explorer, son Dynamic Split, son édition d'échantillon au pixel | **Justifié, mais pas pour ce que la barre d'outils fait aujourd'hui** (§II). |

## 0.3 Ce que coûte réellement le mode take — et pourquoi je ne le supprimerais pas

J'ai mesuré. Le code qui n'existe QUE pour le mode take :

| Bloc | Lignes |
|---|---|
| règle / time selection / curseur d'édition (entrée) `:2728-2798` | 71 |
| time selection + curseur + playhead transport (dessin) `:3241-3295` | 55 |
| `makeTakeBackend` `Roll.lua:54-100` | 47 |
| branche midi de `setItem` `:593-615` | 23 |
| branche midi de `pollTarget` `:881-893` | 13 |
| passe barlines par la carte des mesures `:2658-2668` | 11 |
| Ctrl+Z / Ctrl+Y `:3381-3384` | 4 |
| bouton natif `:2462-2468` | 7 |

**≈ 231 lignes sur 3560.** Le mode take est **bon marché**. Le supprimer rapporterait 6 % du fichier et coûterait la seule chose qu'il achète : pouvoir sélectionner un item MIDI dans l'arrangement et rester dans la même fenêtre, la même grammaire, les mêmes rangées de kit.

**Donc : on le garde, et on le GÈLE.** Sa définition devient explicite — *« les notes, et une porte vers l'éditeur natif pour tout le reste »*. Avec deux conséquences immédiates :

1. **On répare le canal MIDI codé en dur** (§I.D.1), parce qu'aujourd'hui le mode take n'est pas « moins », il est **destructeur**.
2. **On n'ajoute plus jamais une fonction MIDI dont la seule maison est le mode take.** Lanes de CC, canaux, notation, liste d'événements, propriétés d'événement, expression par note : ce sont des territoires où le natif est à un clic et à dix ans d'avance. Chaque heure passée là est une heure volée au mode clip, où rien n'existe.

## 0.4 La règle d'investissement qui en découle

> **Une fonction du roll ne mérite d'être écrite ici que si elle vit dans `Roll`/`RollUI` (donc unit-agnostique, donc take + clip, donc CP_Editor + CP_Looper), ET qu'elle sert le mode clip.**

Corollaire vérifié : `Roll.lua` et `RollUI.lua` sont chargés par **exactement deux** scripts (`CP_Editor.lua:29-30`, `CP_Looper.lua:43,47`). Une op écrite dans `Roll` est payée une fois et rendue quatre fois (deux hôtes × deux backends). Une *vue* nouvelle est payée deux fois : CP_Looper redessine son propre roll de bout en bout (`CP_Looper.lua:1138-1500` — sa propre grille, son propre marquee, sa propre voie de vélocité à `VEL_H = 34` contre 44 ici, `:1153` contre `CP_Editor.lua:2195`). **C'est l'argument décisif pour classer les manques ci-dessous** : ceux qui tombent dans `Roll` sont bon marché, ceux qui tombent dans le dessin sont chers.

---

# I. LA MOITIÉ MIDI

**Concurrents réels :** l'éditeur MIDI de REAPER (mode take uniquement), les MIDI Tools d'Ableton 12, le piano roll de FL. En mode clip, **personne**.

## I.A — Les manques qui comptent

### A1. Aucun undo en mode clip — c'est le trou, pas un manque

Le contrat de backend prévoit `be.undo(desc)` (`Roll.lua:29`) et `Roll` l'appelle sur **chaque** geste structurel (`Roll.lua:224, 253, 262, 292, 312, 630, 675, 715, 737, 840, 898, 926`). Le backend take le branche sur `Undo_OnStateChange` (`Roll.lua:98`). Le backend clip le branche sur **une publication** :

> `CP_Editor.lua:583` — `undo = function() scheduleApply() end,`

Et Ctrl+Z est explicitement réservé au take : `if state.mode == "midi" then` (`:3381`).

Conséquence vérifiée : en mode clip — **toute cellule de session, toute lane de looper** — `Roll.Arpeggiate` fait `deleteSelectedRaw()` puis réécrit (`Roll.lua:884-894`), `Roll.Euclidean` ajoute 9 notes, `Roll.Humanize(heavy)` déplace tout, `Roll.DeleteSel` efface : **rien de tout cela n'est annulable.** Une fausse manœuvre sur une cellule est définitive.

**Ce que ça coûte ici :** les notes du clip sont quatre tables plates (`c.notes.s/l/p/v`, `CP_Editor.lua:542-581`). Un instantané = quatre copies de N nombres, pris sur une **commande**, jamais dans une frame. Un anneau de 20 instantanés pour un clip de 200 notes, c'est 16 000 nombres — invisible même sur le PC de 2005.

**Contre quoi ça rivalise :** rien. Ableton, FL et REAPER ont tous l'undo partout ; ce n'est pas une fonctionnalité, c'est le prix d'entrée. Et l'instantané/restauration est **exactement** la machinerie dont A2 a besoin — c'est le même chantier, fait dans le bon ordre.

### A2. Le panneau Transform paramétré, avec prévisualisation

Le modèle est **déjà paramétrique** et le menu ne l'expose pas :

| Op | Signature réelle | Ce que le menu offre |
|---|---|---|
| `Roll.Humanize(tAmt, vAmt, lAmt)` `Roll.lua:584` | trois amplitudes continues | Light / Medium / Heavy en dur (`RollUI.lua:274-276`) |
| `Roll.Euclidean(a,b,pitch,steps,pulses,vel,rotation)` `:904` | steps, pulses, **rotation** libres | 6 presets, `rotation = 0` en dur (`RollUI.lua:356-365`) |
| `Roll.Arpeggiate(rate, mode, gate, octaves)` `:850` | gate et octaves libres | 4 modes × 4 rates, `gate = 0.9`, `octaves = 1` en dur (`RollUI.lua:340`) |
| `Roll.Quantize(snap_fn, strength)` `:323` | force continue + fonction de snap | 100 / 66 / 50 % + deux swings (`RollUI.lua:279-288`) |

Ableton 12 a exactement cette idée, et son détail décisif n'est pas la liste d'outils mais **Auto Apply activé par défaut** : chaque mouvement de paramètre se voit immédiatement dans le roll ([MIDI Tools, manuel Live 12](https://www.ableton.com/en/live-manual/12/midi-tools/) — *vérifié*). FL fait mieux encore sur un point : **le dialogue est généré à partir des variables du script** ([Piano roll scripting API](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_scripting_api.htm) — *vérifié*).

**Ce que ça coûte ici :** un panneau non modal + « restaurer l'instantané, ré-appliquer » à chaque changement de paramètre. O(n) sur une action de souris, jamais dans le chemin de frame. Le menu Transform est déjà une table `{label, action}` (`RollUI.lua:224-226`), donc la moitié de la plomberie existe.

**Contre quoi ça rivalise :** **rien côté REAPER** — aucun cadre de transformation paramétrée n'existe dans le changelog (*vérifié par absence*, whatsnew.txt v7.78 → v0.20). C'est le seul endroit du roll où CP peut dépasser sa référence au lieu de la rattraper. Et c'est ce qui rend enfin rentables les trois générateurs déjà écrits et bridés par des presets.

### A3. La grille adaptative et le cull au pas de PIXEL

`renderRollGrid` borne ses passes par un **compte d'itérations**, jamais par une densité :

```
:2625   if n > 4096 then n = 4096 end            -- absurd zoom, not a grid
:2639   if n > 2048 then n = 2048 end
:2648   if n > 1024 then n = 1024 end
```

Et `gridLine` (`:2526-2539`) appelle `qnToRoll(qn)` **avant** de tester si la ligne est visible — or en mode take `qnToRoll` fait `r.TimeMap2_QNToTime(0, qn)` plus `itemPos()` qui fait `GetMediaItemInfo_Value` (`:2220-2228`, `:2212-2215`). **Deux appels API par ligne de grille, visible ou non.**

Cas réel, non pathologique : un clip de 32 mesures affiché en entier avec une grille 1/32 → 128 QN / 0,125 = **1024 lignes de la passe 1**, plus 256 (croches), plus 128 (temps), plus 32 (mesures). Dans une fenêtre de 700 px, les subdivisions sont à **0,7 px** l'une de l'autre : ce n'est plus une grille, c'est un lavis gris. Et le buffer est reconstruit à **chaque frame** d'un pan ou d'un zoom, puisque `t0`/`t1` sont dans la clé de cache (`:2551-2554`).

L'ironie est que le code le sait déjà — **sur l'autre moitié** : la grille de l'onde a `WGRID_MAX = 400` avec le commentaire *« denser than this says nothing: it is a grey wash »* (`:1493`) et une garde sur l'empan en QN (`:1510`). La leçon a été apprise sur la forme d'onde et jamais reportée sur le roll.

**Ce que fait la référence :** REAPER — *« MIDI editor: use project grid setting for grid line minimum pixel spacing »* (*vérifié*, whatsnew.txt ligne 1837). Ableton — Zoom-Adaptive Grid, bascule Ctrl+5 ([raccourcis Live 12](https://www.ableton.com/en/live-manual/12/live-keyboard-shortcuts/) — *vérifié*).

**Ce que ça coûte ici :** dix lignes — calculer `step * w / span_qn` et sauter la passe sous ~4 px. **Gain double : lisibilité ET performance**, exactement pendant le geste (pan/zoom) où le buffer se reconstruit, et exactement sous la contrainte « PC de 2005 » du projet. À répliquer dans le roll de CP_Looper (`CP_Looper.lua:1215+`), qui a le même défaut.

### A4. Le fold : n'afficher que les hauteurs utilisées

`Rows.Build` sait déjà construire une liste **arbitraire** de hauteurs — c'est ce que fait le mode drum. Le mode mélodique, lui, est une fenêtre contiguë (`state.view_hi` / `state.view_rows`, `:2382`). Sur une basse de 4 mesures qui utilise 5 hauteurs, on fait défiler une fenêtre de 30 rangées pour rien.

Ableton a les deux d'un coup : **Fold to Notes (F)** et **Fold to Scale (G)** (*vérifié*, manuel Live 12). REAPER a le note folding — mais pas pour un clip, puisqu'il n'ouvre pas les clips.

**Ce que ça coûte :** une branche dans `Rows.Build` + deux bascules. `Rows.Shift` (utilisé au drag vertical, `:2990`) travaille déjà **en rangées** et non en demi-tons, donc le drag reste correct sur une liste non contiguë — le mécanisme qui rend le fold possible est déjà écrit et déjà testé par le mode drum. Sert les deux hôtes.

### A5. Les gestes manquants de la voie de vélocité

Aujourd'hui, la voie de 44 px saisit **une** note, celle dont le **début** est à moins de 6 px du pointeur :

```lua
:2956-2960   local best, best_d = nil, 6
             for i = 1, Roll.count do
                 local d = math.abs(xAtTime(Roll.starts[i]) - mx)
```

Pas de peinture au glissé, pas de rampe. Or `Roll.VelocityRamp(v0, v1)` (`Roll.lua:567`) et `Roll.SetVelLive` (`:280`) existent — la rampe n'est atteignable que par deux entrées de menu à valeurs figées (`RollUI.lua:268-269` : 40→120 et 120→40).

**C'est la plus grosse asymétrie geste/modèle de tout l'éditeur.** REAPER le fait, Ableton le fait (dessin en Draw Mode, Alt = ligne droite, *vérifié* manuel Live 12), FL le fait. Coût : le geste seul.

### A6. Le groove quantize, avec CPC1 comme gabarit

`Roll.Quantize(snap_fn, strength)` prend **une fonction** (`Roll.lua:323`) — un groove n'est rien d'autre qu'une fonction de snap construite à partir d'une liste de départs. Et la liste de départs sérialisable existe déjà, voyage déjà sur le Bus, et s'appelle CPC1.

C'est l'idée centrale de FL, répétée trois fois : le **même** fichier `.fsc` sert de grille au Quantizer, de motif au Chopper et de motif à l'Arpeggiator ([Quantizer](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_qnt.htm) — *vérifié* : *« seules la position et la longueur comptent, la hauteur est ignorée »*).

**Contre quoi ça rivalise : rien.** REAPER n'a **aucun** groove quantize natif (*vérifié par absence* : zéro entrée « groove » pertinente dans whatsnew.txt ; les `.rgt` de cette machine viennent de SWS/FNG). Ableton a le Groove Pool avec hot-swap pendant la lecture (*vérifié*). Aujourd'hui le menu offre trois pourcentages et deux swings en dur.

### A7. Trois transformations que REAPER n'a pas du tout

Chacune ~30 lignes au-dessus de `gatherTargets`/`forEachTarget` (`Roll.lua:370-392`), unit-agnostique donc take **et** clip, donc les deux hôtes :

- **Strum** — décaler les départs d'un accord selon l'ordre des hauteurs, avec une tension. Ableton l'a (Strum Low/High + tension par breakpoints, *vérifié*), FL l'a avec en plus l'alternance de direction et le traitement de la FIN des notes ([Strum](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_strum.htm) — *vérifié*). REAPER : rien.
- **Ornament / Flam** — frappes de grâce. La plus utile des trois en contexte drum, et le modèle de rangées drum la rend évidente.
- **Recombine** — permuter / miroir / rotation d'**une** des quatre dimensions du cache SoA. C'est littéralement une permutation d'un des quatre tableaux : le meilleur rendement créatif par ligne de code de toute cette liste. Ableton l'a (*vérifié*, MIDI Tools).

### A8. La peinture continue — mais SEULEMENT en mode drum

Aujourd'hui, un clic sur le vide insère une note et **enchaîne immédiatement sur un redimensionnement** (`:2894-2906`) : le glissé sert à fixer la longueur. C'est le geste FL, c'est bon, et il ne faut pas le perdre. Mais il rend la peinture impossible, et poser seize charleys au clic en mode drum est le geste le plus fréquent qui soit.

REAPER a **sept** variantes de peinture, en modificateurs de souris (*vérifié*, actionlist : `39485 Paint notes and chords`, `39493 Paint a row of notes of the same pitch`, `39500 Paint a stack of notes`, `39501-39504 Paint notes / straight line / ignoring snap`). FL a Paint (B) et **Paint drum sequencer mode (N)** (*vérifié*).

**La proposition bornée :** en mode drum, où la longueur est une cellule, le glissé peint ; en mode mélodique, le glissé garde la longueur. Un `if rows.drum` dans la branche `resize`/`fresh`. Pas de mode modal, pas d'outil à ramasser.

### A9. (mineur, à faire si l'occasion se présente) Les notes fantômes en lecture seule

`Loop.ReadNotes(lane, …)` expose déjà les notes des autres lanes du moteur. Afficher **en lecture seule** ce que jouent les autres colonnes coûte une passe de dessin et zéro modèle. FL a les ghost channels, Ableton le multi-clip 8 pistes + Focus Mode (N), REAPER les contextes secondaires avec opacité réglable (*vérifié*, whatsnew v7.7x). **L'édition** multi-clip, en revanche, est chère (indices, undo, plusieurs backends) et n'apporte rien que la fenêtre unique ne donne : à ne pas suivre.

## I.B — Les manques à NE PAS combler

| Ce qu'on ne construit pas | Pourquoi, précisément |
|---|---|
| **Lanes de CC / poly AT / 14 bits / formes de courbe par segment** | En mode take, le natif est à un bouton et à dix ans d'avance (*vérifié*, whatsnew : formes de courbe par lane, CC 14 bits appairés, lane Poly AT qui suit la sélection de notes, presets de lanes, réordonnancement par drag). En mode clip, **le stockage ne les porte pas** : `LaneNote` = start/len/pitch/vel + 2 octets, le format Clip est « s,l,p,v; », la file de port émet des messages de 3 octets. C'est un chantier à travers cinq couches — et il est en concurrence directe avec ModJSFX, qui module déjà des paramètres à la résolution audio sans qu'un script tourne. |
| **Notation, liste d'événements, sysex, canaux MIDI, propriétés d'événement, remapping de souris** | Natif, profond, hors d'atteinte. (*Vérifié* : deux articulations + un ornement par note, export PDF, 16 actions « Set events to channel NN ».) |
| **MPE / expression par note** | REAPER ne l'a pas non plus (*vérifié par absence*). Il faudrait 5 tableaux à travers Roll, deux backends, CPC1, le moteur natif, et un instrument qui comprenne. Non. |
| **Multi-clip édité ensemble** (Ableton 8 clips + Focus Mode) | Indices, undo, backends multiples. La fenêtre unique répond déjà au besoin. |
| **Riff machine, Stacks/Tonnetz, générateurs à dialogue complet** | Une masse d'UI par bouton. `InsertChord` + les 11 accords (`Roll.lua:759-766`) couvrent 90 % de l'usage. |
| **Un mode Draw modal (Ableton, B)** | L'insertion au clic + glissé-longueur d'ici est plus directe. Ajouter un mode serait un recul. |
| **Le probabilité par note (chance)** | Tentant : Ableton l'a, REAPER ne l'a pas du tout, et `LaneNote` a deux octets libres. **Mais** un take REAPER n'a nulle part où le stocker : ce serait la première fonction qui marche dans une moitié de l'éditeur et pas dans l'autre, ce qui casse la promesse que `RollUI` existe pour tenir (`RollUI.lua:2-6`). Si un jour, alors en connaissance de cause, et pas avant A1-A6. |

## I.C — Les forces à protéger

1. **Le mode clip lui-même.** La lane est re-résolue par TAG une fois par frame (`:3434`), la publication débouncée écrit la lane **directement** même sans Session ni Looper ouverts (`:432-449`), le playhead est la phase du moteur en beats (`:3299-3310`). Éditer une cellule pendant qu'elle joue marche, et c'est le cas le mieux traité de toute la suite. Rien ailleurs ne fait ça sur des objets REAPER.
2. **Un modèle, deux hôtes, deux backends** (contrat `Roll.lua:22-30`). C'est la propriété qui rend les items A bon marché. Ne jamais écrire une op dans l'hôte.
3. **Ctrl+Shift+molette = subdivision trap-roll** (`:2819-2830` → `Roll.Subdivide:297`). Ableton demande Ctrl+E puis les flèches ; FL demande le dialogue du Chopper. Ici c'est une molette. **Meilleur que les deux références.**
4. **Les rangées drum nommées d'après le kit de la CIBLE** (`clipKit:2345-2356` → `Loop.KitViewOfTrack`), pas d'après le kit global du Sampler. Le commentaire `:2342-2344` dit pourquoi, et il a raison.
5. **La marche Alt+flèches avec audition** (`RollUI.lua:140-179`) — entendre une phrase en la parcourant. Petit, rare, juste.
6. **`midiSnapFloor`** (`:2241-2248`) : la note naît dans la cellule **sous** le curseur, sémantique FL. Ableton arrondit autrement. À garder.
7. **Une seule grille pour les deux moitiés** (`gridStepQN:197`). L'onde et le roll aimantent sur la même division ; c'est ce qui fait de cette fenêtre une fenêtre et pas deux.
8. **Les deux gardes de correction** : touches d'édition bloquées pendant un drag (`:3336-3340`) et pas de `Roll.Sync` en plein drag (`:891`). Elles ont visiblement été payées. Ne pas les défaire en ajoutant A5 ou A8.

## I.D — Déjà là, mais mal fait

### D1. Le canal MIDI codé en dur — le mode take est LOSSY, pas seulement pauvre

```lua
Roll.lua:77   r.MIDI_InsertNote(take, false, false, ppq(t), ppq(t + len), 0, pitch, vel, true)
```

Le 6ᵉ argument est le canal : **0**, en dur. `be.setNote` passe `nil` pour le canal (`:94`), donc une note *déplacée* garde le sien. Mais **toute note insérée** part sur le canal 1 — et « insérée » couvre : le clic sur le vide, Duplicate, Paste, Chord, Euclidean, Arpeggiate, Glue, Subdivide.

Pire : `Roll.Arpeggiate` (`:884`), `Roll.Glue` (`:710`) et `Roll.Subdivide` (`:299-308`) **suppriment puis réinsèrent**. Sur un take dont les notes sont en canal 3, ces trois ops **convertissent** les notes en canal 1. *(Vérifié dans le code ; la conséquence est mécanique.)* Elles perdent aussi le drapeau muted, que le natif sait poser (`Edit: Mute events (toggle)`, *vérifié* dans la liste d'actions MIDI).

C'est le seul endroit du dépôt où CP_Editor **détruit** ce que REAPER conserve. Correction : passer le canal de la note de référence, ou à défaut celui du take, ou à tout le moins refuser silencieusement d'insérer sur un take multi-canal. Trois lignes.

### D2. L'undo du mode clip est branché sur la mauvaise chose

Voir A1. Ce n'est pas un manque de conception : la couture existe (`Roll.lua:29`), elle est simplement câblée sur une publication (`:583`).

### D3. Le menu Settings est intégralement audio, et s'affiche en mode MIDI

`barCommon()` est appelé **avant** l'aiguillage (`:3480`), et `openSettings` (`:1151-1170`) contient cinq entrées : snap zéro, cible de normalisation, volume de préview, préview par la piste, arrêt à la fin de la time selection. **Aucune** ne concerne un piano roll. *(Vérifié.)*

### D4. `gridLabel()` est morte, et son cache est entretenu

`:2320-2334` — aucun appelant dans le dépôt (*vérifié par grep*). Sa chaîne « Grid 1/16 (proj) » n'est affichée nulle part, et pourtant `grid_lbl.div = -1` est consciencieusement remis en deux endroits (`:1378`, `:2423`).

### D5. `rollRows()` deux fois par frame, `clipKit()` trois fois

`rollRows()` est appelée en `:2428` (barMidi) **et** en `:3075` (drawRoll). Chacune appelle `clipKit()` (`:2376`), qui appelle `Loop.KitViewOfTrack` — dont le cache est clé sur `GetProjectStateChangeCount` et qui incrémente `kitview.version` à **chaque** reconstruction, ce qui re-clé `Rows.Build`. Plus l'appel direct `:3154`. *(Appels vérifiés ici ; le comportement du cache est celui décrit dans le dossier.)*

### D6. La voie de vélocité ne peut pas viser une note longue

`:2955-2966` : seule la fenêtre de 6 px **autour du début** est cliquable. Une ronde est inatteignable sur 99 % de sa longueur, et deux notes qui démarrent ensemble sont indiscernables (le `if d < best_d` strict laisse gagner la première dans l'ordre du cache, ce qui est arbitraire).

### D7. Le passage au natif ne transporte rien

`:2462-2468` sélectionne l'item et appelle 40153. Il n'emporte ni la grille (`opts.grid_div`), ni la gamme (`Roll.scale_on/scale_root`), ni la vue. Si le natif est la sortie officielle du mode take — et c'est ce que je propose — la poignée de main mérite au moins de poser la division de grille du projet avant de partir. Quelques lignes, et le geste cesse d'être une éjection.

### D8. Le même roll est dessiné deux fois dans le dépôt

`CP_Looper.lua:1138-1500` réimplémente grille, notes, marquee, voie de vélocité, avec ses propres constantes (`VEL_H = 34` contre 44). Chaque item A qui touche la VUE (A3, A4, A5, A8) se paie deux fois ; chaque item qui tombe dans `Roll` (A2, A6, A7) se paie une fois. **C'est le critère de classement, et il devrait le rester.**

### D9. Deux vestiges de commentaire

- `state.mdrag` documente un mode `"erase"` (`:132`) qu'aucun producteur ne fabrique (`:2883`, `:2887`, `:2904`, `:2963`).
- Le fit vertical à l'ouverture est copié à l'identique en `:603-611` (midi) et `:683-693` (clip).

---

# II. LA MOITIÉ AUDIO

**Concurrents réels, et ils n'ont rien à voir avec les précédents :**

| Concurrent | Ce qu'il fait, vérifié |
|---|---|
| **L'arrangement de REAPER** | fondus avec 7 formes + éditeur de crossfade, bords à la souris avec grouping/ripple, D_VOL / D_PITCH / D_PLAYRATE / B_PPITCH, glue, normalize, prises et comping, **stretch markers** avec une matrice entière de modificateurs (*vérifié*, actionlist `39928`-`25080`) |
| **La Media Explorer de REAPER** | *« Audition only a portion of a file: make time selection… drag and drop from either end of selection to extend/shorten it »*, zoom molette, tempo match (+ half/double), rotatifs pitch/rate avec preserve-pitch, écoute à travers une piste sélectionnée, et **« Insert into sample player (on new track, or reusing existing sample player) »** (*vérifié*, `Up and Running: A REAPER User Guide v7.78`, §4.6-4.7) |
| **Dynamic Split** | découpe par gate/transitoires avec seuil, hystérésis, longueur minimale de tranche, pad avant/après, **découpe au passage par zéro**, presets, et un mode qui **pose des stretch markers au lieu de découper** (*vérifié*, ug.txt §7.36/§9.19 + whatsnew) |
| **L'édition d'échantillon native** | crayon au niveau de l'échantillon, mise à zéro, ligne droite, courbe interpolée, mise à l'échelle 0-200 %, **réparation spectrale**, vue spectrogramme (*vérifié*, ug.txt §7.41-7.42) |
| **Ableton** | warp markers, 6 modes de warp, clip gain, **Slice to New MIDI Track** (*vérifié*, [Converting Audio to MIDI](https://www.ableton.com/en/manual/converting-audio-to-midi/)) |
| **FL** | Edison (*« Drag / copy sample / move selection » vers Sampler channels, Fruity Slicer, DirectWave, Playlist* — *vérifié*, [Edison](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Edison.htm)), Slicex, et **« Dump beat to piano roll »** (*vérifié*, [Fruity Slicer](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Fruity%20Slicer.htm)) |

## II.0 Le verdict de cette moitié

**Elle est justifiée — plus nettement que le mode take du roll — mais pas pour ce que sa barre d'outils fait.**

Justifiée pour trois choses :

- **éditer et découper un fichier qui n'est dans AUCUN projet** (`setFile:626-645`, mode `file`). REAPER ne sait pas faire ça : la Media Explorer prévisualise, sélectionne une portion et insère, mais elle ne détecte pas les transitoires et ne découpe rien ;
- **la chaîne « un son devient un instrument »** — `slicesToPads:1065-1095` (chaque tranche → un pad vide avec ses offsets), `selectionToPad:1097`, `sendToInstrument:1119` — **sans rien créer dans l'arrangement**. Le commentaire `:1447-1448` le dit : *« these three are the product's whole point »*, et il a raison ;
- **être source et cible du protocole de glisser CP** : `selectionClip:1640` fabrique un CPC1 (chemin + offs + len), aucun rendu, aucun fichier temporaire, et `DragBus.HoverTarget` laisse une fenêtre CP prendre le drop avant l'arrangement (`:1666-1682`).

**Non justifiée pour :** gain, pitch, rate, reverse, normalize, trim aux bords, fondus. Ce sont sept contrôles (`:1401-1428`, `:1873-1890`) qui refont, en moins bien, ce que l'arrangement fait nativement — sans les formes de fondu, sans le grouping, sans le ripple, sans les prises (`GetActiveTake` seul, `:588`), sans le multi-item (`GetSelectedMediaItem(0,0)`, `:858`), sans les stretch markers (*vérifié par absence : aucune occurrence de « stretch » dans `CP_Editor.lua` ni dans `Ops.lua` hors un commentaire*).

Ils ont une excuse — la préview qui SONNE comme l'item (§C4) — et c'est une vraie excuse. Mais elle ne justifie pas de les faire **grandir**.

## II.A — Les manques qui comptent

### A1. L'aller-retour du clip audio n'existe pas — c'est le trou de toute la fenêtre

```
:765-766   if c.kind == "audio" and c.path and c.path ~= "" then
               if not setFile(c.path) then return end
:628-629   state.clip, state.clip_lane = nil, nil
           state.clip_track, state.clip_tag = nil, 0
```

et `flushApply` exige `state.mode == "clip"` (`:433`). Donc : une cellule audio de la Session ouverte ici **perd `cell`, `origin`, `id`, `color`, `tempo_mode`, `src_bpm`, `bars` à la deuxième ligne de l'ouverture**, et rien ne repart jamais. `c.offs`/`c.len` ne servent qu'à préréglérla sélection (`:768-777`).

Autrement dit : **tout ce que la moitié audio sait faire est inaccessible à l'objet qui en a le plus besoin.** La cellule audio se *lance* déjà comme un clip ; elle ne s'*édite* pas comme un clip.

**Contre quoi ça rivalise :** rien, parce qu'aucun concurrent n'est dans la pièce — chez Ableton, l'éditeur d'un clip audio de session **est** la Clip View, la question ne se pose pas. Ici elle se pose, et la réponse est « non ».

**Ce que ça coûte :** un quatrième mode (« clip audio ») qui garde le descripteur et republie `offs`, `len`, `gain`, `pitch`, `bars`, `tempo_mode`. Et — c'est la moitié difficile — que la Session consomme enfin `offs`/`len` à la lecture (aujourd'hui `Cells.Arm` ne prend qu'un chemin et un taux). Deux côtés, un seul sens.

### A2. Découper, puis **rejouer** : la moitié manquante de la chaîne SEND

`slicesToPads` fabrique N pads. Et ensuite ? Rien. Il n'existe aucun objet qui **joue** ces tranches dans l'ordre. L'utilisateur a découpé une boucle en 12 morceaux et se retrouve avec 12 pads muets.

Les deux références font exactement l'inverse :

- Ableton, **Slice to New MIDI Track** : *« A new MIDI track will be created, containing a MIDI clip. The clip will contain one note for each slice, arranged in a chromatic sequence. A Drum Rack will be added… containing one chain per slice »* (*vérifié*, [Converting Audio to MIDI](https://www.ableton.com/en/manual/converting-audio-to-midi/)) ;
- FL, **Dump beat to piano roll** : *« writing a sequence of notes within it »*, une note par tranche (*vérifié*, [Fruity Slicer](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Fruity%20Slicer.htm)).

**Ce que ça coûte ici : une boucle.** `slicesToPads` connaît déjà les deux moitiés de l'information — le temps de chaque tranche (`state.markers`) et la note du pad (`Kit.FirstEmpty()` rendue dans `note`, `:1076-1081`). Fabriquer un `Clip.new("midi")` avec une note par tranche, à la position de la tranche, et le publier par `Bus.BeginClip` (le mécanisme existe déjà, `:1656`) ou vers une cellule libre : trente lignes. **Aucune piste d'infrastructure créée** — les pads sont déjà des pistes, ce qui est un acquis, et le clip est un descripteur.

C'est le meilleur rapport valeur/effort de toute cette analyse, moitié audio et moitié MIDI confondues.

### A3. Deux portes vers le natif, qui convertissent une duplication en passage

La moitié MIDI a une sortie explicite vers l'éditeur natif ; la moitié audio n'en a **aucune** (*vérifié par absence*). Or c'est elle qui duplique le plus.

Deux entrées de menu contextuel, `Main_OnCommand`, coût nul :

- `40009 = Item properties: Show media item/take properties` (*vérifié*, actionlist) — tout ce que la barre ne sait pas régler y est ;
- `40760 = Item: Dynamic split items…` (*vérifié*) — le découpage adulte, avec gate, longueur minimale, passages par zéro et presets, juste à côté de notre `Detect` maison.

Le message implicite est le bon : *ici on découpe pour envoyer au Sampler ; pour découper dans l'arrangement, voilà l'outil qui le fait mieux.*

### A4. La vue ne suit pas la lecture

*Vérifié par absence* : `playCursorTime()` (`:1591`) n'est lu que pour dessiner (`:2170-2178`), rien ne recadre `t0`/`t1`. Auditionner un fichier de trois minutes en étant zoomé, c'est regarder le curseur sortir de l'écran et ne jamais revenir. Toutes les références défilent. C'est bon marché et c'est ressenti à chaque écoute.

### A5. Les formes de fondu

`Ops.SetFades` (`Ops.lua:234-238`) n'écrit que `D_FADEINLEN`/`D_FADEOUTLEN`. Le dessin, lui, trace un **triangle droit** (`:2069-2078`). REAPER a sept formes et un éditeur de crossfade (*vérifié*, ug.txt §7.31-7.32). Résultat : on dessine une droite et on entend une courbe. Lire `D_FADEINDIR`/`C_FADEINSHAPE` pour dessiner la vraie forme est le minimum ; les exposer au clic droit sur la poignée est presque gratuit.

### A6. Le seul chiffre qui manque : la sélection en mesures

La ligne d'état donne des secondes (`:3510`). Pour un son qu'on transforme en boucle, le chiffre utile est « 4 mesures à 128 » — et `SrcTempo` sait déjà deviner le BPM d'un fichier, et la Session sait déjà déduire un nombre de mesures d'une durée. La Media Explorer de REAPER affiche justement la position *« en beats using embedded tempo »* (*vérifié*, ug.txt §4.6). Une ligne d'état, pas un chantier.

## II.B — Les manques à NE PAS combler

| Ce qu'on ne construit pas | Pourquoi |
|---|---|
| **L'édition destructive** (normalize écrit dans le fichier, EQ, reverb, trim cuits — les onglets Tools/Effects de FL) | CP a tranché l'inverse, et mieux : les éditions sont des propriétés de take, et `Bake` est l'échappatoire explicite. Rouvrir ça, c'est rouvrir une question fermée. |
| **Les prises, le comping, les lanes fixes, le multi-item** | Le système de prises de REAPER est énorme (ug.txt chapitre 8 entier). Un éditeur qui suit **un** item et **une** prise est un choix, pas un manque. |
| **Les stretch markers / un éditeur de warp par marqueurs** | REAPER les a avec une matrice complète de modificateurs de souris (*vérifié*, actionlist `39928`-`25080`), et la question du tempo est déjà traitée un cran plus haut par `Warp`. Rivaliser sur ce terrain, c'est perdre deux fois. |
| **Vue spectrale, réparation spectrale, crayon au niveau de l'échantillon** | Natif et profond (*vérifié*, ug.txt §7.39, §7.41, §7.42). Sans rapport avec le produit. |
| **Un enregistreur façon Edison** | Hors sujet : l'enregistrement appartient au Looper et à la Session. |
| **Remplacer `Ops.DetectTransients` par les transient guides de REAPER** | Tentant (42027/42028/41208 existent, *vérifié*) mais **il n'y a pas d'API pour LIRE la position des guides** — seulement des actions qui déplacent le curseur d'édition. Le détecteur maison (`Ops.lua:96-113`, enveloppe à 1000 Hz, seuil + ratio + réfractaire 30 ms, marqueur reculé au début de la montée) est un choix défendable. **À garder, et à assumer.** |

## II.C — Les forces à protéger

1. **Le mode `file`** : ouvrir, zoomer, sélectionner, détecter, découper, envoyer — sur un fichier qui n'appartient à aucun projet, sans rien créer. REAPER ne le fait pas.
2. **La chaîne SEND** (`:1449-1453`), y compris `Kit.SetOffsets` par tranche : chaque pad pointe une région du **même** fichier, sans rendu.
3. **Le glisser-sortir sans rendu** (`:1640-1704`) : un CPC1 = chemin + offs + len, donc ce qui atterrit reste entièrement éditable. Et la priorité donnée aux fenêtres CP avant l'arrangement.
4. **La préview qui SONNE comme l'item** (`:1004-1032`) : gain composé avec le volume de monitoring, pitch, rate, `B_PPITCH`, les vraies longueurs de fondu, la **source réelle du take** (donc une section ou un reverse s'entend juste), et le routage par la piste de l'item avec ses FX. La Media Explorer de REAPER ne peut pas faire ça (elle lit le fichier, avec ses propres rotatifs — *vérifié*, ug.txt §4.6), un éditeur externe encore moins. C'est l'avantage le plus concret de cette moitié, et c'est ce qui excuse la présence des sept contrôles d'item.
5. **Les transitoires comme OBJETS**, saisies par leur **fanion** et non par leur ligne (`:1713-1741`), déplaçables, clampées entre voisines, supprimables une à une. Chez REAPER, un transient guide se calcule et s'efface **en bloc** (`42027`/`42028`, *vérifié*) : il n'est pas un objet qu'on attrape. Ici, si.
6. **Les trois départs de lecture sur les touches de REAPER** + la clôture par la sélection **armée à l'entrée du playhead** (`:912-973`). C'est du design fin, écrit deux fois plutôt qu'une, et documenté. À ne pas casser en ajoutant A4.
7. **Le clic pose le curseur et ne détruit pas la sélection** (`:1899-1906`) — la règle de REAPER, respectée.

## II.D — Déjà là, mais mal fait

1. **La barre est écrite deux fois** avec les mêmes identifiants de widget : mode `file` (`:1386-1397`) et mode `item` (`:1438-1453`).
2. **`sendToInstrument` passe par un canal ExtState privé** (`CP_Sampler/instrument`, `:1129-1131`) alors que `Bus` + `Clip` existent et que le Sampler consomme déjà DragBus. Un CPC1 audio avec `offs`/`len` dirait la même chose dans le vocabulaire de la maison.
3. **Le « Dropped » est un mensonge.** `DragBus.Drop` rend « une fenêtre enregistrée était sous la souris », pas « la cible a compris » — et `:1689` affiche `flash("Dropped: …")` sur ce retour. Glisser une sélection sur le Sampler annonce une livraison qui n'a pas eu lieu (le Sampler n'accepte que `file`/`instrument`).
4. **Après un split, les marqueurs mentent.** `splitAtMarkers` (`:1058-1062`) ne vide pas `state.markers`, et `state.item` devient le fragment de gauche (`Ops.lua:298-299`). L'éditeur affiche donc un item rétréci avec tous les marqueurs d'origine tracés au-delà de sa région — et un second clic sur Split ne fait rien, puisque `Ops.SplitAt` ignore ce qui est hors `[a,b]` (`Ops.lua:307`).
5. **Une option, deux libellés, dont un faux.** Settings dit « Snap selection to zero crossings » (`:1152`) ; le menu contextuel dit « Snap to zero crossings **(when the grid is off)** » (`:1954`). C'est la seconde qui décrit le code (`:1897` : `opts.snap_zero and not opts.wave_snap`).
6. **Deux curseurs d'édition sans le dire.** L'audio a le sien, local (`state.cursor`, `:125`) ; le roll utilise celui de REAPER (`:2737`). `M` pose une transitoire sur le curseur **local** (`:3363`). Passer d'un item audio à un item MIDI change silencieusement ce que « le curseur » désigne.
7. **La forme d'onde ignore les FX de prise et l'enveloppe de volume** : elle n'est mise à l'échelle que par `D_VOL` (`:1554-1558`). Le dessin est donc juste pour le gain et faux pour tout le reste.
8. **`state.wpress` documente trois `kind`** (`:129`) et le code en produit **neuf** (`sel`, `sel_a`, `sel_b`, `dragout`, `mark`, `trim_a`, `trim_b`, `fadein`, `fadeout`).
9. **`Ops.Reverse` manipule la sélection d'items de l'utilisateur** (`Ops.lua:197-213`) : elle déselectionne tout, agit, puis restaure item par item avec un `ValidatePtr2` chacun. C'est le seul op audio qui passe par l'arrangement, et sur un projet où 200 items sont sélectionnés, c'est 400 appels API pour un clic sur « Reverse ».
10. **Trois modules morts pour cet éditeur** : `Peaks.InvalidateView` (`Peaks.lua:116`) et `Peaks.Invalidate` (`:336`) n'ont **aucun appelant dans le dépôt** (l'éditeur invalide par `state.gen`) ; et `Ops.lua` vit dans `CP_Engine/` — les capacités *partagées* — alors que **CP_Editor est son unique client** (*vérifié par grep*).

---

# III. L'ordre que je défendrais

**D'abord ce qui répare, parce que c'est ce qui coûte des données :**

1. Le canal MIDI de `Roll.lua:77` — trois lignes, et le mode take cesse d'être destructeur.
2. L'undo du mode clip (`I.A1`) — et il faut le faire **en premier** parmi les ajouts, parce que son instantané/restauration EST la machinerie du panneau paramétré.

**Ensuite ce qui est bon marché et se voit à chaque frame :**

3. La grille adaptative + cull au pixel (`I.A3`) — perf et lisibilité, dans les deux rolls.
4. Les gestes de la voie de vélocité (`I.A5`) — le modèle existe déjà entièrement.
5. Le fold mélodique (`I.A4`) — une branche dans `Rows.Build`.

**Ensuite ce qui rend rentable ce qui est déjà écrit :**

6. Le panneau Transform paramétré avec prévisualisation (`I.A2`) — le seul endroit où cet éditeur peut dépasser ses références.
7. Le groove quantize par CPC1 (`I.A6`) — un format, deux outils, zéro concurrent.
8. Strum / Ornament / Recombine (`I.A7`) — trente lignes chacun dans `Roll`.

**Côté audio, deux choses qui ne se ressemblent pas :**

9. **Découper puis rejouer** (`II.A2`) — la boucle qui manque à `slicesToPads`. Trente lignes, et la chaîne « un son devient un instrument » est enfin complète au lieu de s'arrêter au milieu.
10. **L'aller-retour du clip audio** (`II.A1`) — le vrai chantier, deux côtés, à décider plutôt qu'à glisser dans une session.

**Et trois gestes de ménage qui changent le contrat de la fenêtre :**

11. Les deux portes natives côté audio (`II.A3`) : `40009` et `40760`.
12. La grille emportée vers l'éditeur MIDI natif (`I.D7`).
13. Le menu Settings scindé (`I.D3`), `gridLabel` retirée (`I.D4`), `rollRows` appelée une fois (`I.D5`).

**Ce qu'on arrête définitivement d'envisager** : lanes de CC, canaux MIDI, notation, liste d'événements, expression par note, multi-clip éditable, warp par marqueurs, édition destructive, prises et comping. Ce ne sont pas des « plus tard » : ce sont des territoires où le natif est à un bouton et où chaque heure passée est volée au mode clip, qui est la seule raison pour laquelle cette fenêtre existe.

---

## Fichiers lus (chemins absolus)

- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Editor\CP_Editor.lua` (3560 l., intégralement)
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Roll.lua` (930 l.)
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\RollUI.lua` (396 l.)
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Ops.lua` (317 l.)
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Engine\Kit.lua` (extrait `StuffNote`/`armTarget`, l. 1560-1600)
- `c:\Users\Cedric\AppData\Roaming\REAPER\Scripts\CP_Scripts\CP_Looper\CP_Looper.lua` (roll, l. 1138-1500)

## Sources externes

**REAPER** (locales, faisant autorité) : `C:\Users\Cedric\AppData\Local\Temp\claude\…\scratchpad\whatsnew.txt` (changelog officiel v7.78→v0.20), `…\scratchpad\ug.txt` (*Up and Running: A REAPER User Guide v7.78*, Geoffrey Francis), `…\scratchpad\actionlist.ini` (liste d'actions), `C:\Users\Cedric\AppData\Roaming\REAPER\LangPack\MIDI Editor actions (active take only) vs (all editable).ReaperLangPack`.

**Ableton** : [Converting Audio to MIDI](https://www.ableton.com/en/manual/converting-audio-to-midi/) · [MIDI Tools](https://www.ableton.com/en/live-manual/12/midi-tools/) · [Editing MIDI](https://www.ableton.com/en/live-manual/12/editing-midi/) · [Keyboard Shortcuts](https://www.ableton.com/en/live-manual/12/live-keyboard-shortcuts/)

**Image-Line** : [Fruity Slicer](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Fruity%20Slicer.htm) · [Edison](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Edison.htm) · [Slicex](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Slicex.htm) · [Quantizer](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_qnt.htm) · [Strum](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_strum.htm) · [Piano roll scripting API](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_scripting_api.htm)