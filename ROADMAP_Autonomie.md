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

### Le programme (ordre imposé) — BILAN : les trois chantiers + le "?"
### livrés le soir même (`8a7b2ee`..`90cdfb0`)

- [x] **A — Unification CP_Editor** (`8a7b2ee`, `f8b34d5`, `f3e8369`) :
  le **mode clip** — un piano roll SANS take, backend Roll sur les
  tableaux du Clip (unité beats), mappage temps par paire
  rollToQN/qnToRoll (identité en clip, TimeMap en item — tout le reste
  marche à l'identique : snap, grille, transform, drum rows, clavier).
  Chaque geste committé publie `editor:apply` (debounce 250 ms, flush à
  la fermeture) ; le Looper l'applique par `Loop.ApplyClip` — notes +
  longueur SANS toucher au mode : une loop qui joue continue de jouer à
  travers l'édit. Bouton "Editor" dans l'éditeur de lane (origin
  looper:N). Preview via la piste de l'item (`opts.out_track` →
  CF_Preview_SetOutputTrack ; option Settings ON par défaut) — track FX
  + fader dans la préécoute ; les take FX restent le manque CF_Preview.
- [x] **B — Refonte graphique, tranche 1** (`7aa2fbe`) :
  `ANALYSE_DesignSystem.md` (références Ableton/Bitwig/FL/Vital →
  tokens, technique, tranches suivantes) ; `Core.DrawRoundRectFilled`
  (composition slabs + disques AA, fallback rect si rayon<2 ou alpha<1 —
  thème legacy = rendu identique) ; tokens `rounding/rounding_small/
  rounding_large` (4/3/6, scalés DPI, persistés, hérités par les thèmes
  sauvegardés anciens) ; **restyle global via Widgets.lua seul** :
  Button, Toggle, Checkbox, Sliders (piste/fill/poignée), Combo (plus
  carré, à la Ableton), Tabs, Tooltip, inputs, ProgressBar. Restent :
  palette sémantique (play/record/mod), knob v2, preset compact,
  maquettes HTML avec lui, headers borderless.
- [x] **C — Session view P1** (`c24a2a5`) : **`CP_Session/`** — la
  grille sur le moteur du Looper : cellule = lane (nom de piste routée,
  bars, état, blink pending, balayage de phase), clic = launch/stop
  quantisé, clic droit = Edit in CP_Editor / Mute / Clear, triangle de
  scène, Stop all, Panic, Clock, Q. Zéro moteur neuf ; rappel one-shot
  du set sauvé si la fenêtre arrive la première.
- [x] **"?" d'aide** (`90cdfb0`) : `UI.HelpButton` (overlay centré,
  titres "## ", clic/Esc ferme) + contenus dans Sampler, Looper,
  Editor, Session. Restent : Media Explorer, CP_ModLFO, FXC.
- [ ] Encore ouvert (ordre libre) : DnD-capture de modulation, "?"
  dans ME/ModLFO/FXC, overflow (§3.5), maquettes HTML design.

---

## Session 4 (2026-07-23 nuit) — ses retours de test sur le programme

Retours : "cliquer une lane ouvre encore l'éditeur embarqué", "la
Session n'accepte ni DnD ni clic-pour-éditer", "toujours pas d'audio
DnD dans le looper (stretch au beat ?)", "sample sync dans le
sampler ?", perfs légèrement en baisse (stutter au drag de fenêtre),
couleurs hardcodées (scrollbars, lignes ME/FXB, Looper), knobs
disgracieux.

Corrigé/livré (`35d4440`, `4ed5ee1`, `cc6361c`) :
- [x] **Unification réelle** : `Bus.OpenEditor` lance CP_Editor s'il ne
  tourne pas (action enregistrée persistée + heartbeat) ; clic sur le
  mini-roll d'une lane → CP_Editor (Alt+clic = éditeur embarqué) ;
  double-clic sur une cellule Session → CP_Editor (même vide).
- [x] **Session** : cible DragBus (fichier audio → cellule A, clip MIDI
  → lane) ; **rangée AUDIO interim (P3)** : CF_Preview par cellule,
  tempo-match natif (rate + preserve pitch), boucle, aligné mesure
  quand le transport tourne, sortie via piste sélectionnée, persistée
  par projet. Consomme aussi editor:apply (marche sans Looper ouvert).
- [x] **Perf** : la Session repasse en idle-throttle (redraw seulement
  quand pending/lecture) — c'était la seule fenêtre à tourner en
  continu sans besoin. Suspicion résiduelle du stutter : le coût
  de composition des arrondis → si ça persiste, bascule des surfaces
  vers des buffers bakés (la réserve notée dans ANALYSE_DesignSystem).
- [x] **Knobs lissés** : bake 2× + blit filtré (gfx.mode 4), bords de
  l'arc de valeur adoucis à demi-alpha.
- Réponses données : le **sync du sampler existe** (menu pad → "Sync to
  project tempo", repitch par TUNE, BPM source du nom de fichier ou
  saisi) ; l'**audio du looper** vit dans la Session (rangée A interim,
  moteur JSFX sample-lock = P4) ; les **couleurs hardcodées** = la
  tranche "palette sémantique + tokens" d'ANALYSE_DesignSystem §4.1 (à
  faire : play/record/mod en tokens + sweep des littéraux d'apps).

---

## Session 5 (2026-07-25) — sampler cassé, parité clip, sync

Retours : le sync tempo "ne correspond pas du tout au tempo" (hat loop
en Follow), le sync doit être **par défaut** avec détection du BPM ; le
CP_Editor en mode clip n'a "pas le curseur de progression, super
important" ni de contrôle des bars — "il faut que ce soit complet, au
moins aussi complet que le CP_Looper actuel", puisqu'à terme les clips
de la Session ne seront éditables QUE là ; dans le Sampler les poignées
ADSR "ne font rien visuellement", les knobs A/D/S/R "passent de 0 à 100
sans transition", le knob Pitch reste figé alors que le plugin part de
0 à +24. CP_Session : **session dédiée plus tard**, ne pas y toucher.

**La cause unique des trois bugs sampler** : les paramètres des VST
Cockos (RS5K, ReaPitch) exposent une valeur BRUTE **normalisée 0..1**,
quelle que soit l'unité affichée. Le code les lisait comme des ms / dB /
demi-tons (vrai pour les sliders JSFX, faux pour un VST). D'où des
poignées larges de quelques pixels, des knobs qui saturent, un TUNE de
sync visé au mauvais endroit.

- [x] **Unités réelles auto-calibrées** (`cd31de5`) : lecture par valeur
  FORMATÉE, écriture par dichotomie sur `FormatParamValueNormalized`
  (pure requête) puis `SetParamNormalized` — aucune plage ni courbe
  supposée. L'écriture pose un point SONDÉ (jamais le milieu final),
  sinon elle atterrit sur la frontière d'affichage : sur le slider par
  pas de ReaPitch, ça rendait la migration non idempotente (dérive d'un
  demi-ton par session). `ParamPlain/SetParamPlain/PadPitch/SetPadPitch`
  + la migration ReaPitch passent dessus ; parse mis en cache contre la
  chaîne formatée (l'overlay ADSR en lit quatre par frame).
- [x] **Sync par défaut** (`cd31de5`) : deux niveaux volontairement
  inégaux — tempo DÉCLARÉ (nom de fichier) = confiance, à condition que
  le fichier soit assez long pour ÊTRE une boucle à ce tempo (un 808
  "120bpm" de 0.6 s ne l'est pas) ; tempo DÉDUIT de la longueur =
  seulement si UN SEUL décompte de mesures tombe dans une bande étroite
  autour du tempo projet (les fenêtres se recouvrent : 3 s = "4 temps à
  80" ET "8 temps à 160") et si la correction reste sous ±2 demi-tons.
  Activer le sync beat-matche IMMÉDIATEMENT. L'identité tempo (BPM +
  drapeau) vit sur la piste et survivait au sample : purgée dès que la
  matière change, avec `no_sync` (tranche, sélection, preset) et
  `keep_sync` (bake du même matériau).
- [x] **Parité clip dans CP_Editor** (`06eabe2`, `5372afa`) : curseur de
  progression (phase du moteur, animé seulement quand la lane tourne),
  groupe LOOP (mesures -/+ = moitié/double sur le clip ET la lane,
  Play/Stop quantisé, états rec/armé affichés au lieu d'un bouton mort),
  Espace = lancer/arrêter. Le lancement ÉCRIT la lane directement
  (`Loop.ApplyClip`) : le message de bus ne touche qu'une application
  ouverte, or le moteur doit entendre l'édition même sans fenêtre
  Looper/Session — et une lane crue vide est promue "arrêtée avec
  contenu" pour que le premier lancement parte. La vue se refait quand
  la longueur change (sinon la moitié ajoutée restait hors écran).
  `Loop` est initialisé paresseusement (son init resynchronise les sends
  du routeur : un éditeur ouvert sur un item audio n'a rien à y faire).

**Méthode** : le diff a été passé au crible par une revue multi-agents
(3 lentilles — logique/Lua, sémantique API REAPER, intégration avec les
appelants — puis vérification adverse de chaque point). 9 défauts
confirmés dans mon propre code, tous corrigés avant le commit : écriture
au milieu de dichotomie, BPM périmé au remplacement d'un sample,
heuristique de longueur qui acceptait tout, preset dont le TUNE se
faisait écraser, bouton Stop mort en overdub, dépendance à une appli
tierce pour jouer, "-inf dB" lu comme une erreur, allocations par frame.

- [ ] Reste ouvert (inchangé) : palette sémantique + sweep des couleurs
  en dur, DnD-capture de modulation, "?" dans ME/ModLFO/FXC, maquettes
  HTML design (avec lui), overflow §3.5, **CP_Session (sa session
  dédiée)**, moteur audio P4 (JSFX sample-lock).
