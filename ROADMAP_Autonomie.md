# ROADMAP — todo list du 2026-07-23

Liste donnée par Cédric avant une journée d'autonomie complète, avec les
verdicts techniques discutés. Complète `ANALYSE_Ecosysteme.md` (§9, le plan
moteur) et `ANALYSE_Interactions.md` (ponts + quick wins). Les cases se
cochent au fil des commits.

Règles du jour : finir l'engine d'abord (8b, 9), n'exécuter que ce qui est
sûr, Meta Mixer interdit, l'utilisateur teste tout lui-même.

**BILAN DU SOIR : les 13 points du plan du jour sont livrés, PLUS
l'overdub pris sur l'overflow (16 commits, `31376ca`..`d12c2ea`). Le plan
moteur §9 est COMPLET (chantiers 1-9 faits, 10 acté). L'**overdub**
(`d12c2ea`) : mode 5 du JSFX — le gate joue pendant que la capture
empile dans la même loop, entrée sans retrigger, pas d'auto-stop,
punch in/out quantisés, Shift+clic REC côté UI. Reste en attente de
décision : go session view (lire `ANALYSE_SessionView.md`), move
ModJSFX→Engine, format Inst standalone, refonte UI. Overflow restant :
demi-ponts DragBus, velocity layers, MediaDB DATA, contrôle MIDI du
Looper, blocs undo randomizers.**

---

## 1. LOOPER / EDITOR

- [x] **Parité éditeur Looper ↔ CP_Editor** (`1232c89`) : `Engine/Rows.lua`
  partagé (fenêtre mélodique / liste drum triée), drum mode dans le Looper
  (bouton Keys/Drum, labels, molette mélodique-only), édition audible
  (dessin, drag de pitch, clic droit sur label → l'instrument routé de la
  lane), et le fix du group-move en delta de LIGNE dans les deux hôtes.
- [x] **Passe raccourcis** (`23befe7`) : le benchmark 7-DAW du repo faisait
  foi (Tiers 0-2 déjà livrés) ; le manque réel était la navigation clavier
  de note en note — Alt+←/→ marche la ligne de pitch, Alt+↑/↓ le temps,
  Shift+Alt étend, wrap + audition. Dans RollUI → les deux hôtes.
- [ ] **Session view à la Ableton** — GRAND CHANTIER. **DÉCISIONS DU
  2026-07-23** : (a) chantier 10 ACTÉ — CP_Editor devient l'éditeur universel
  qui change de focus selon ce qu'on ouvre (media item / loop MIDI / loop
  audio) ; les fondations du focus-switching peuvent se poser dès aujourd'hui
  (`Bus.Send("editor:open", clip)` existe, Clip porte audio et MIDI).
  (b) ✅ La **spec design** est écrite (`ANALYSE_SessionView.md`, `525d528`,
  zéro code) : grille de clips CPC1 recommandée comme base, profondeur
  subproject en option par cellule plus tard ; inventaire des briques Engine
  (seul trou : le moteur audio) ; 5 phases ; 5 questions ouvertes à trancher.
  Le code de la session view attend ta lecture.

## 2. MOD

État des lieux (vérifié dans le code) : ModLFO est DÉJÀ l'architecture cible.
Les banques sont des JSFX purs (`ModJSFX.writeBankFile`), la modulation passe
par les parameter links natifs (`plink` + `mod.baseline`) → résolution audio,
fonctionne sans script ouvert ; le panneau Lua n'est qu'une télécommande.

- [x] **Move `ModJSFX` → `CP_Engine/`** (`d5b56ff`, session 2) : move pur,
  CP_ModLFO et LinkEngine chargent depuis CP_Engine/. PLUS la spec
  Bitwig-grade complète (`6cf79c5`) : slew (lissage one-pole), curve
  (power bend, pulse width sur Square), mode One-shot (un cycle puis
  tient), Loop resync (phase libre repart au play), trig manuel (bouton
  Sync). Layout étendu APPEND-ONLY (params 56..87) : les plinks
  existants survivent, les instances anciennes recompilent au
  rechargement de projet.
- [x] **Moduler les modulateurs** (`6cf79c5`) : LFO→LFO — la sortie d'un
  slot pilote rate/phase/curve/slew d'un autre slot du même bank via le
  plink natif (résolution audio, zéro script requis). Section "LFO → LFO"
  dans le panneau (les deux banks, les deux hôtes). Portes fermées :
  jamais les sorties ni les triggers (pas de feedback).
- [ ] **DnD vers VST tiers** : verdict honnête — on sait identifier la
  *fenêtre* du plugin sous la souris au relâchement (js_ReaScriptAPI), pas
  le *knob* dans une GUI étrangère (personne ne peut, Vital drop dans sa
  propre GUI). UX atteignable : drag depuis un slot → drop sur la fenêtre du
  plugin → ce FX passe en "capture" → premier paramètre touché = lié.
- [x] **Clic sur le nom du paramètre dans le panneau pour le sélectionner**
  (`d482a9a`) : clic dans la liste TARGETS → épinglé dans l'inspecteur, le
  "last touched" ne le reprend qu'à un VRAI nouveau touch.

## 3. MEDIA EXPLORER

- [x] **Préécoute via une piste spécifique** (`d62e844`) : sous-menu
  "Preview output" — Master / Follow selected / **Pin selected track**
  (épinglé par GUID, persiste, la piste morte se détache toute seule).

## 4. UI (chantier transverse, ATTEND une session de design)

- Migration vers un style knob/boutons, flat arrondi chaleureux et moderne,
  suite d'icônes maison, anticrénelage quand c'est gratuit.
  **Perf et ergonomie AVANT esthétique** (PC 2005, zéro alloc par frame).
- Header global "borderless" sans barre native Windows — CP_Color prouve que
  c'est faisable (js_ReaScriptAPI).

## 5. SAMPLER

- [x] **Plusieurs bus kit** (`94e8857`) : `Kit.kits` + `SetActive` (GUID) +
  `NewKit` ; sélecteur dans la barre d'outils ; les filets de sécurité du
  scan sont gardés mono-kit ; les bus des kits INACTIFS se désarment (un
  seul kit écoute les clics, les sends du Looper continuent de jouer).
- [ ] **Inst indépendant du drum, multi-instances ?** Recommandation : script
  léger séparé partageant `Kit` plutôt que multi-instance du même script gfx
  (collisions d'état persisté). Format à trancher ensemble.
- [x] **Tune sans changer la longueur** (`d28b845`) : knob "Pitch" par pad →
  ReaPitch inséré/masqué sur la piste du pad, ±12 st élastique, paramètre
  trouvé PAR NOM (les indices bougent entre versions REAPER). Le bake
  (`2e354d6`) couvre la version rendue.
- [x] **Handles fades + visu ADSR sur la preview** (`2f9942a`) : l'enveloppe
  dessinée sur la région (attack = fade-in depuis le début, release =
  fade-out dans la fin, genou decay portant le sustain en Y), trois handles
  draggables en place, temps lus/écrits en ms réels (ParamPlain).
- [x] **BUG ADSR/loop** (`ef8c364`) : cause = la case Loop mettait LOOP=1
  sans OBEY → voix infinie, enveloppe une seule fois, release jamais. Fix :
  résolveur OBEY unique (choke OU loop → obey ON), `Kit.SetLoop` — un pad
  loopé GATE désormais (maintien = boucle sous sustain, relâché = release).
  Les pads loopés d'avant guérissent au premier toucher de Loop/choke.

## 6. MISC

- [x] **DnD arrangeur → Looper/Sampler** (`06f0dfb`) : capture au
  relâchement (pattern busHover, JS_Mouse + classe de fenêtre arrange).
  Sampler : l'audio de l'item → le pad sous le curseur (SECTION déballée).
  Looper : le MIDI de l'item → la lane visée (PPQ→QN→beats, arrondi bars,
  cap MAX_NOTES). L'item ne bouge jamais — non-destructif par construction.
- [x] **Looper → item MIDI dans l'arrangeur** (`c94c1bd`) : bouton
  "To item" dans l'éditeur — piste routée de la lane (ou sélection), au
  curseur d'édition, un loop de long, mapping QN. La jam ne meurt plus.

## Le plan du jour (2026-07-23), dans l'ordre

Décisions prises avant le départ : chantier 10 acté (CP_Editor universel),
8b en mode "fonce, commits atomiques" (bump LAYOUT_VER autorisé), move
ModJSFX différé, spec session view à rédiger.

1. Chantier 8b — launch quantize CP_MidiLooper (JSFX pending-launch,
   bump LAYOUT_VER si les cellules gmem changent).
2. Chantier 9 — bake (chemin natif Apply-FX 40209 / Glue 40362 d'abord,
   WAV writer pur Lua ensuite si solide).
3. Bug ADSR sampler (investigation + fix).
4. Media Explorer préécoute-via-piste.
5. ModLFO clic-nom-pour-sélectionner.
6. Looper hear-note + drum mode via Rows.lua partagé (+ fix CP_Editor:1661).
7. RollUI passe raccourcis REAPER.
8. Sampler multi-kit.
9. Sampler ReaPitch tune.
10. Sampler visu ADSR/handles.
11. Drops arrangeur↔apps (les deux sens).
12. Rédaction de `ANALYSE_SessionView.md` (spec design, zéro code).
13. Si la liste est épuisée : quick wins S de ANALYSE_Interactions §3.5.

**En attente de Cédric** : go session view (sur la base de la spec),
format Inst standalone, refonte UI, move ModJSFX→Engine.

---

## Session 2 (2026-07-23 après-midi) — retours de test + 2 chantiers

Cédric a testé, rapporté 4 problèmes, choisi 2 chantiers (ModJSFX +
éditeur universel ; overflow explicitement non retenu), puis est parti 1 h.

Retours de test, tous corrigés :

- [x] **Multi-kit : armé qui saute, tous les C2 qui jouent** (`d2f9fbb`) :
  l'invariant "un seul bus kit armé" n'était appliqué qu'au SetActive —
  il est désormais CONTINU (Poll) ; SetActive crée le bus MIDI s'il
  manque (la cause du "désarmé sans raison") et ré-affirme armé comme
  état par défaut ; le kit actif est persisté par projet.
- [x] **Knob Pitch mort puis hyper-sensible** (`d2f9fbb`) : il pilotait le
  slider À CRANS "Shift (semitones)" (chaque petit drag re-snappait).
  Rebind sur "Shift (full range)" continu, plage ±24 st, migration
  one-shot du résidu du slider à crans, et Shift = drag fin (1/10e)
  sur TOUS les knobs du toolkit.
- [x] **Lignes drum du Looper = le kit routé** (`2041086`) :
  `Loop.KitView(lane)` — une ligne par pad chargé (nom du pad) plus les
  pitches du clip ; charger un sample ajoute sa ligne. (Version légère
  en attendant l'unification chantier 10, comme convenu.)
- [x] **Preview de l'Editor fidèle à l'item** (`6ed102c`) :
  `Audio.PlaySource` joue la VRAIE source du take → reverse et sections
  enfin pré-écoutables, même base de temps que les peaks ; fades réels
  de l'item (longueurs) et mode repitch (B_PPITCH) reflétés ; gain/
  pitch/rate l'étaient déjà. Hors périmètre CF_Preview : les take FX
  (routage piste / bake, suite du chantier éditeur universel).

Chantiers choisis, exécutés :

- [x] **ModJSFX → CP_Engine + Bitwig-grade + LFO→LFO** (`d5b56ff`,
  `6cf79c5`) : voir section 2 MOD ci-dessus.
- [x] **Chantier 10, fondations** (`fa9fb91`) : CP_Editor écoute
  `editor:open` sur le Bus (Clips, RÉGION incluse : sélection + zoom à
  l'arrivée) en plus du canal legacy ; le Sampler émet le trim du pad,
  le Media Explorer émet la section active du strip — le trou "l'Editor
  s'ouvre sur le fichier entier" d'ANALYSE_Interactions est fermé.
  Clips MIDI : nécessitent le backend Roll sans take (suite du chantier).

---

## Session 3 (2026-07-23 soir) — la discussion, puis le grand programme

### Points discutés (ses retours, mes réponses)

- **Multi-kit, usage** : un seul kit ACTIF à la fois = celui du sélecteur
  de la barre d'outils ; pads/VKB/MIDI ne sonnent que lui ; les autres ne
  sonnent que via les lanes du Looper (voulu). Le "tout sonne en même
  temps" = la version d'avant le fix continu `d2f9fbb` (effectif au
  relancement du script). S'il reste du bleed après ça : câblage du
  projet (kits dupliqués, sends croisés) → passe "isolation" à ajouter
  au Repair si besoin.
- **"?" d'aide** (son idée du matin) : un bouton "?" dans le header de
  chaque app → panneau d'aide (modèle mental en 3 lignes + gestes +
  raccourcis), standardisé dans le toolkit. La version "info au survol"
  à la Ableton viendra par-dessus les tooltips. À FAIRE.
- **Éditeur universel confirmé** : cliquer une lane / un clip de session
  → CP_Editor avec le bon visage. Fondations posées (`fa9fb91`) ; il
  manque le backend Roll sans take. C'est le chantier A ci-dessous.
- **Refonte graphique, sa vision** : knobs partout, flat plus arrondi,
  anticrénelage généralisé (via buffers bakés — gratuit par frame),
  condenser (densité par tokens de thème), améliorer l'API du toolkit,
  itérer via maquettes HTML ("claude design"), et une étude des
  références (Ableton : couleurs qui signifient, boutons arrondis,
  dropdowns carrés, knobs minimalistes, bold + AA). Chantier B.
- **Mods** : oui, une SÉRIE de modulateurs à terme (env follower — le
  bank voit l'audio de la piste ; step sequencer ; macros ; sources
  MIDI) sur le même moule bank+plink. **Map: touch target reste le
  geste central.** DnD de modulation : verdict re-confirmé — fenêtre
  identifiable au drop, knob étranger impossible ; UX = drop sur la
  fenêtre → capture → premier param touché lié. À FAIRE (S-M).
- **Session view ré-expliquée** en détail (colonnes=pistes,
  cellules=clips, lancement quantisé, scènes=lignes, double-clic →
  CP_Editor, ponts arrangeur). Les 5 questions : il me laisse juge.

### Décisions (Cédric, verbatim résumé)

« Il faudra de toute façon tout faire. Dans l'ordre : 1. finir
l'unification de CP_Editor ; 2. refonte graphique (pour éviter les
dettes techniques sur les changements futurs) ; 3. session view (je te
laisse juge). Les autres chantiers dans l'ordre que tu veux, après.
Full autonomie, code propre, pérenne, performance maître mot. »

### Mes arbitrages sur les 5 questions session view (délégués)

1. P1 tel quel : OUI (grille sur les 4 lanes, zéro moteur neuf).
2. Multi-pistes MIDI : PLUSIEURS instances JSFX (un gmem par piste) —
   le pattern éprouvé, pas de chirurgie du moteur.
3. Scènes : APRÈS P2 (une scène sur 4 lanes n'apporte rien).
4. Fenêtre : APP SÉPARÉE `CP_Session` (le Looper reste l'outil de jam).
5. Audio : INTERIM CF_Preview quantisé d'abord (P3), moteur JSFX (P4)
   ensuite.

### Le programme (ordre imposé)

- [ ] **A — Unification CP_Editor** : backend Roll sans take (mode
  "clip"), aller-retour Looper↔Editor (editor:open avec origine +
  editor:apply), preview via piste (track FX).
- [ ] **B — Refonte graphique** : étude design + tokens (doc), toolkit
  v2 (primitives AA bakées, thème étendu, densité), restyle global par
  le toolkit (pas app par app — c'est ça qui évite la dette), maquettes
  HTML pour itérer avec lui.
- [ ] **C — Session view P1** : `CP_Session`, grille sur les lanes du
  Looper (launch/stop quantisés, pending visible, double-clic →
  CP_Editor).
- [ ] Ensuite, ordre libre : "?" d'aide partout, DnD-capture de
  modulation, overflow (§3.5).
