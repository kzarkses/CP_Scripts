# ANALYSE — comment marche la Session View d'Ableton, et comment CP_Session s'en rapproche

Écrit le 2026-07-25. Objectif fixé par Cédric : « CP_Session doit se
rapprocher le plus possible d'Ableton Live ». Ce document décrit
d'abord le fonctionnement réel d'Ableton (comportements, pas
impressions), puis ce que ça implique pour CP_Session — architecture,
ce qui est reproductible tel quel, ce qui doit être adapté, ce qui est
hors de portée. **Zéro code ici.**

---

## 1. Le modèle mental (le seul truc qu'il faut vraiment comprendre)

Ableton Session View est une grille :

- **une colonne = une piste**, et **une piste ne joue qu'UN clip à la
  fois** ;
- **une ligne = une scène** ;
- une cellule = un *clip slot* : soit un clip, soit vide.

Tout le confort de la Session découle de cette exclusivité. Lancer un
clip **arrête automatiquement** celui qui jouait sur la même piste —
on n'a jamais à réfléchir « est-ce que je dois d'abord stopper l'autre ».
Le musicien ne pense qu'en « quoi maintenant », jamais en gestion de
voix. C'est ça qu'il faut reproduire, avant tout effet cosmétique.

Corollaire souvent oublié : **la Session ne fait pas de son toute seule**.
Elle pilote les pistes du set, exactement comme l'Arrangement. Un clip
lancé remplace ce que jouerait l'Arrangement sur cette piste, jusqu'au
prochain « Back to Arrangement ».

**Écart CP actuel** : CP_Session est une *rangée* de lanes + une rangée
audio. C'est un launcher, pas une session — il n'y a ni colonne-piste,
ni scène, donc ni exclusivité, ni empilement de variations. C'est LE
changement structurel à faire ; tout le reste s'y greffe.

---

## 2. Les comportements, un par un

### 2.1 Lancement et quantisation

- Un clic sur une cellule ne démarre pas le clip tout de suite : il le
  **met en attente** jusqu'à la prochaine frontière de la *Global
  Quantization* (barre d'outils : None, 8/4/2/1 bar, 1/2, 1/4…, défaut
  **1 bar**). La cellule clignote pendant l'attente.
- Chaque clip peut **surcharger** cette quantisation (Launch box → Quantization, « Global » par défaut).
- Cliquer une deuxième fois pendant l'attente **annule** le lancement.
- Quand le transport est arrêté, un lancement démarre le transport.

**CP** : déjà là. `G_LAUNCH_Q` (en beats), pending 1/2 avec annulation,
clignotement, et un mode « free run » qui permet de jouer transport
arrêté — ce qu'Ableton ne sait pas faire aussi simplement. Il manque
seulement la **quantisation par clip**.

### 2.2 Les modes de lancement (Launch Mode)

Par clip, quatre modes :

| Mode | Comportement |
|---|---|
| **Trigger** (défaut) | Le clic lance ; relâcher ne fait rien. |
| **Gate** | Le clip joue tant que le bouton est maintenu. |
| **Toggle** | Le clic lance, le clic suivant arrête. |
| **Repeat** | Le clip se relance en boucle au rythme de la quantisation tant qu'on maintient. |

Plus **Legato** : le nouveau clip reprend à la *position de phase* du
précédent au lieu de repartir de zéro — c'est ce qui permet de changer
de variation sans casser le groove.

**CP** : Trigger et Toggle sont naturels (c'est déjà le comportement du
clic). Gate et Repeat demandent le suivi de l'état du bouton — faisable
côté Lua, faible valeur au clavier/souris. **Legato est le vrai
morceau intéressant** : il demande que le moteur démarre une lane à une
phase donnée plutôt qu'à 0 (une commande « play at phase » côté JSFX).

### 2.3 Follow Actions — le mécanisme qui rend une session vivante

Chaque clip peut, après une durée réglée (en barres + beats), déclencher
tout seul une action :

- **No Action**, **Stop**, **Play Again**, **Previous**, **Next**,
  **First**, **Last**, **Any**, **Other** (Any sauf lui-même).
- **Deux actions A et B avec une probabilité** (curseur A:B) → une
  chaîne de clips peut devenir semi-aléatoire.
- Les versions récentes ajoutent le mode « linked » (l'action tombe à la
  fin du clip) et des groupes de suivi.

C'est ce qui transforme une grille statique en machine à variations : on
pose 4 variantes d'une boucle de batterie avec « Next » et la batterie
tourne toute seule.

**CP** : entièrement faisable **côté Lua**, sans toucher au moteur — il
suffit d'observer la phase de la lane (déjà exposée) et de déclencher le
lancement suivant à la frontière. C'est, à mon avis, le **meilleur
rapport valeur/effort de tout le projet Session**.

### 2.4 Scènes

- Le bouton de scène lance **toute la ligne** : chaque piste prend le
  clip de cette scène **et les pistes dont la cellule est vide
  s'arrêtent**. (C'est le défaut ; une préférence permet de les laisser
  jouer.)
- Une scène peut porter un **tempo** et une **signature** (écrits dans
  son nom : « 128 BPM », « 4/4 ») → la lancer change le tempo du set.
- « Select on Launch », renommage, insertion/capture de scène.

**CP** : le bouton de scène existe déjà, mais il lance « toutes les
lanes non vides » — dans une vraie grille, il devra lancer *la ligne* et
arrêter les pistes sans clip. Le tempo par scène est trivial à ajouter
(`SetCurrentBPM`) et très payant en live.

### 2.5 Arrêt

- Un **bouton stop par piste** (carré sous la colonne) arrête le clip de
  cette piste, à la quantisation.
- **Stop All Clips** arrête tout, à la quantisation.
- Une **cellule de stop** peut être placée dans une scène (une piste qui
  s'arrête quand cette scène est lancée).

**CP** : Stop All existe. Le stop par piste devient naturel avec les
colonnes. La cellule de stop est un petit plus.

### 2.6 Enregistrer dans la Session

- Piste armée + clic sur le **rond d'une cellule vide** = l'enregistrement
  démarre à la quantisation ; re-clic (ou lancement d'une autre cellule)
  finalise et le clip boucle immédiatement.
- **Session Record** enregistre dans tous les clips en cours (overdub).
- **Capture MIDI** : ce qu'on vient de jouer *sans* avoir enregistré est
  récupéré dans un clip, longueur devinée.

**CP** : le Looper sait déjà tout ça (rec quantisé, auto-stop sur la
longueur, overdub). C'est du recâblage d'UI, pas du moteur. La Capture
MIDI n'a pas d'équivalent (il faudrait un buffer tournant côté JSFX) —
c'est un chantier à part, très séduisant, mais pas prioritaire.

### 2.7 Audio : le warp

- Un clip audio **suit le tempo du set** grâce aux *warp markers* et à
  un mode : **Beats** (percussif, granulaire), **Tones**, **Texture**,
  **Re-Pitch** (change la vitesse ET la hauteur, comme un vinyle),
  **Complex/Pro** (phase vocoder).
- Le clip a un start/end et une *loop brace* indépendants.

**CP** : le repitch actuel du Sampler **est** le mode Re-Pitch. Les
autres modes demandent un vrai moteur de time-stretch : côté REAPER
c'est le playrate + le mode de stretch de l'item (élastique), donc
faisable pour un clip audio joué par un item, pas par un JSFX. C'est le
sujet du **moteur audio P4**, indépendant de cette analyse.

### 2.8 Session ↔ Arrangement

- Enregistrer le transport en Arrangement **capture ce qu'on joue en
  Session** (le résultat devient des items).
- On peut glisser un clip d'Arrangement vers une cellule et
  réciproquement.
- Le bouton « Back to Arrangement » redonne la main à l'arrangement.

**CP** : le pont existe déjà côté Looper (« To item » : une lane
devient un item MIDI). L'enregistrement continu d'une performance
Session vers l'arrangeur serait le vrai plus — techniquement, c'est
écrire les notes jouées dans un item pendant que ça tourne. Faisable
plus tard, à ranger après la grille.

---

## 3. Traduction CP : l'architecture

### 3.1 La grille

- **Colonne = piste = UNE lane logique du moteur.** L'exclusivité
  Ableton devient structurelle : une lane n'a qu'un contenu, donc une
  piste ne peut jouer qu'un clip. Rien à coder pour ça.
- **Ligne = scène**, **côté Lua uniquement**. Les clips des cellules
  sont des descripteurs CPC1 (déjà notre format) rangés dans le projet
  (`ProjExtState`). Le moteur ne connaît QUE le clip en cours par piste.
  Conséquence : le nombre de scènes est gratuit — 8, 16, 64, ça ne coûte
  que de la mémoire Lua.

### 3.2 Le problème du changement de clip, et sa solution

Lancer une autre cellule de la même piste veut dire « remplacer le
contenu de la lane ». Or `ApplyClip` écrit **immédiatement** : on
entendrait le nouveau clip au milieu de la boucle, à la mauvaise
position. Ableton, lui, échange **exactement** à la frontière.

**Solution retenue : double tampon par piste (A/B).** Chaque piste
possède deux lanes moteur ; celle qui joue et sa jumelle silencieuse.
Lancer une autre cellule = écrire le clip dans la jumelle (inaudible,
donc le timing d'écriture n'a aucune importance) puis demander
`Play(jumelle)` + `Stop(courante)` — **deux commandes que le moteur
quantise déjà**. L'échange tombe donc pile sur la frontière, sans une
ligne de JSFX en plus. La piste alterne A/B à chaque changement.

C'est la même idée que le double buffering graphique, et ça évite
d'inventer un « pending clip » dans le moteur (qui reviendrait, de
toute façon, à stocker deux jeux de notes).

### 3.3 Ce que ça coûte en lanes

Le moteur est à `MAX_LANES = 4`. Avec le double tampon, **une piste =
2 lanes**.

- **8 lanes = 4 pistes.** Vérifié : le layout gmem actuel l'accepte sans
  rien déplacer (`LANE_CTRL` à 100, pas 8 → 164 ; `LANE_STATE` à 200 →
  264 ; les notes à 10000 + 8×4096 = 42768). C'est **un changement de
  constante dans deux fichiers**, pas une refonte.
- **16 lanes = 8 pistes.** Là, `LANE_CTRL` déborderait sur `LANE_STATE`
  (100 + 16×8 = 228 > 200) : il faut réorganiser le layout gmem **et**
  bumper la signature (`GMEM_MAGIC`/`VERSION`) pour qu'une vieille
  instance ne lise pas de travers.

**Décision : phase 1 à 4 pistes** (aucun risque de layout), extension à
8 pistes traitée comme un chantier propre et séparé, avec sa migration.
Le coût CPU par bloc croît linéairement avec le nombre de lanes ; sur un
PC de 2005 c'est la vraie limite, et une lane vide doit sortir tôt de la
boucle de scan (optimisation évidente à faire en même temps).

### 3.4 Ce que la Session stocke

Par cellule : un descripteur CPC1 (notes, longueur en mesures, nom,
couleur), plus les propriétés de lancement (quantisation propre, mode,
follow action A/B + probabilité + durée). Le tout sérialisé dans le
projet — donc un set voyage avec le .rpp, sans fichier annexe.

---

## 4. Hors de portée (à dire franchement)

- **Le warp multi-mode** (Beats/Tones/Texture/Complex) : demande un
  moteur de time-stretch. Re-Pitch est le seul mode réellement
  disponible aujourd'hui. → moteur audio P4.
- **Capture MIDI** : demande un buffer tournant dans le JSFX. Faisable,
  gros, à part.
- **Automation par clip (clip envelopes)** : Ableton dessine des
  enveloppes par clip qui modulent n'importe quel paramètre. Chez nous
  la brique existe (ModJSFX + parameter links), mais la relier à un clip
  de session est un chantier entier.
- **Les groupes de pistes, les racks, les macros** : hors sujet Session.

---

## 5. Phases proposées

1. **La grille** — colonnes/pistes × scènes, double tampon A/B,
   exclusivité, stop par piste, lancement de scène « à l'Ableton »
   (les pistes sans clip s'arrêtent), stockage CPC1 par projet.
   *C'est la phase qui change tout ; les suivantes sont des ajouts.*
2. **Les propriétés de lancement** — quantisation par clip, Toggle,
   puis Legato (une commande « play at phase » côté moteur).
3. **Follow Actions** — A/B avec probabilité et durée, entièrement en
   Lua. Le plus gros gain musical du lot.
4. **Enregistrer dans une cellule** — recâblage du rec du Looper sur la
   grille, plus le tempo par scène.
5. **Audio** — quand le moteur P4 existe : les cellules audio deviennent
   des clips de plein droit au lieu de la rangée interim.
6. **Vers l'arrangeur** — capturer une performance de Session en items.

---

## 6. Décisions actées (validées le 2026-07-25)

- Grille **pistes × scènes**, exclusivité par piste : validé.
- **Double tampon A/B** plutôt qu'un « pending clip » dans le JSFX :
  aucune modification du moteur, l'échange tombe sur la frontière.
- **4 pistes d'abord** (8 lanes, layout gmem intact), 8 pistes ensuite
  comme chantier séparé avec migration de layout.
- Les scènes ne coûtent rien au moteur : elles vivent en Lua/CPC1.
- Le Looper reste l'outil de *capture* (jouer/enregistrer une boucle) ;
  CP_Session est l'outil d'*arrangement en direct*. CP_Editor reste la
  seule fenêtre d'édition — une cellule ne s'édite pas sur place.
