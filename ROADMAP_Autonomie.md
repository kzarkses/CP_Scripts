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

---

## Session 6 (2026-07-25) — le programme discuté, en autonomie

Discussion préalable : (1) la Session doit se rapprocher au maximum
d'Ableton, avec une analyse de son fonctionnement réel ; (3) l'UI a
besoin d'une **nomenclature** — quel rôle mérite quel widget — avant
toute migration massive ; (6) la logique produit, c'est **CP_Editor
qui transforme un son en sampler** : « je suis sur un son dans Media
Explorer, je le drag n drop dans CP_Editor, il devrait se passer
quelque chose, pour le moment rien ». Validé : « d'accord avec tout,
travaille en autonomie ».

- [x] **Déposer un son dans CP_Editor** (`8394f00`) : l'éditeur
  chargeait DragBus sans jamais s'enregistrer comme cible — d'où
  « rien ». Il accepte les deux protocoles : le bus CP (Media
  Explorer, Session, Sampler — descripteur Clip, donc l'audio garde sa
  région) et les fichiers de l'OS (explorateur Windows). Un dépôt
  VERROUILLE le suivi de sélection, sinon le prochain clic dans
  l'arrangeur volerait la cible. La chaîne « son → instrument » est
  dite explicitement dans l'accueil et l'aide (tranches → pads,
  sélection → pad, son entier → instrument chromatique), sans rien
  créer dans l'arrangeur. Au passage : `DragBus.RectSync` ne formate
  plus une chaîne par frame (gain pour toutes les applis).
- [x] **`ANALYSE_Ableton_Session.md`** (`b510911`) : le fonctionnement
  réel d'Ableton, comportement par comportement (quantisation de
  lancement, modes + legato, follow actions, scènes, stop, rec dans une
  cellule, warp, ponts avec l'arrangement), puis la traduction CP. Deux
  conclusions qui engagent le code : **colonne = piste = une lane**
  (l'exclusivité devient structurelle) et **double tampon A/B** pour
  changer de clip sur la frontière sans toucher au JSFX.
- [x] **Saisie d'une valeur exacte sur les knobs** (`3a81c81`) : le
  prérequis de toute migration (sinon migrer un champ numérique vers un
  knob fait perdre la précision). Clic droit = taper la valeur ; le
  double-clic reste « remettre le défaut ». Le modèle d'interaction est
  factorisé (slider + knob + les futurs), et `Kit` expose la conversion
  inverse (position 0..1 dont l'AFFICHAGE vaut la valeur demandée).
  Sampler câblé, en unités du plugin, sans allocation par frame.
- [x] **`ANALYSE_Nomenclature.md`** (`15b1906`) + **maquette** : la
  règle en trois questions, le tableau rôle → widget, trois interdits,
  l'inventaire mesuré (40 boutons sur 58 contrôles ; des knobs
  uniquement dans le Sampler), et la migration app par app en cinq
  étapes isolables. Maquette HTML publiée (avant/après par écran + 3
  choix à trancher) : https://claude.ai/code/artifact/869747a6-3ee1-42b7-a6a7-9b6aa068f194
- [x] **CP_Session : la vraie grille** (`88d48ae`, `898af8e`) — une
  colonne par piste, une ligne par scène (8), un clip par cellule, et
  **une piste ne joue qu'un clip** : lancer une cellule arrête ce que
  la piste jouait. Le changement à chaud passe par la lane jumelle
  silencieuse (Play + Stop, tous deux quantisés par le moteur) → la
  bascule tombe pile sur la frontière, zéro ligne de JSFX en plus ;
  quand rien ne joue, pas d'échange. Le tampon actif est re-déduit du
  moteur à chaque frame (un lancement venu de l'éditeur ne peut pas
  désynchroniser). Lancer une scène arrête les pistes sans clip (défaut
  Ableton). Cellules stockées en CPC1 dans le projet, éditables
  UNIQUEMENT dans CP_Editor — celle qui joue s'édite via sa propre lane
  (on entend), les autres via la jumelle. Moteur : MAX_LANES 4 → 8
  (vérifié contre la carte gmem) ; le JSFX publie le nombre de lanes
  qu'il sert, donc un projet portant l'ancien moteur est signalé au
  lieu d'avaler les écritures ; CP_Looper continue d'afficher 4 lanes.

**Reste ouvert** : phases 2-6 de la Session (quantisation par clip,
legato, **follow actions**, rec dans une cellule, audio P4, capture
vers l'arrangeur) ; la migration UI elle-même (les 5 étapes du
document, en attente de ses réponses sur les 3 choix) ; palette
sémantique + sweep des couleurs en dur ; DnD-capture de modulation ;
« ? » dans ME/ModLFO/FXC.

---

## Session 7 (2026-07-25 soir) — retours de test sur la grille

Retours : pas de boutons play/stop/rec par case (« sinon je fais play
comment ? »), les icônes doivent être anticrénelées **partout**
(doctrine), le clic sur le contenu doit ouvrir l'éditeur sans toucher au
play state, une cellule doit accepter **son OU MIDI** indifféremment, le
switch de clip dans une colonne coupe la colonne, et « quels tracks sont
considérés dans les colonnes ? ».

- [x] **Boutons par cellule** (`c9e26bd`) : triangle / carré / rond,
  tirés de la bibliothèque du toolkit (bake 4×, donc anticrénelés) —
  plus un seul `gfx.triangle` brut, lanceur de scène compris. Rangée de
  stop dédiée sous la grille, armement par piste dans l'en-tête, et
  **enregistrement dans une cellule vide** d'une piste armée (quantisé,
  auto-stop sur la longueur, capture dans la cellule).
- [x] **File de commandes moteur** (`e6bdc5a`) : le JSFX ne lit qu'UNE
  commande par bloc, depuis un emplacement unique. Deux commandes dans
  la même frame = la première perdue — or un échange de clip en demande
  deux, et une scène huit (sept perdues : une scène ne s'est jamais
  lancée entièrement). File + accusé de réception côté JSFX.
- [x] **Bouton séparé du contenu** (`e6bdc5a`) : bande de transport à
  gauche (survol + état allumé), le reste de la cellule ouvre
  CP_Editor. Regarder un clip ne change plus ce qui joue.
- [x] **Cellules polymorphes** (`0311808`) : la rangée « A » figée
  disparaît, un son est une cellule comme une autre, et l'exclusivité
  vaut pour les deux types. Le son sort par la piste de la colonne (ses
  FX s'appliquent) au lieu de la piste sélectionnée. Migration
  automatique de l'ancienne rangée.
- [x] **LE bug du switch** (`59c8a1d`) : ce n'était pas la Session. Le
  JSFX **installé** dans `Effects/CP_Scripts/` datait d'avant les 8
  lanes (`MAX_LANES = 4`) et rejetait toute commande visant la jumelle,
  donc le Play était ignoré et le Stop passait. Le fichier n'était
  recopié qu'au « Create engine » / « Reload ». La Session rafraîchit
  désormais le moteur elle-même quand il annonce trop peu de lanes, avec
  bandeau permanent en cas d'échec ; `ReloadEngine` préserve horloge,
  arm et quantisation.
- [x] **Routage des colonnes visible** (`59c8a1d`) : une colonne est une
  lane, qui joue dans la piste vers laquelle elle est routée. Cliquer le
  nom ouvre le choix (piste du projet / nouvelle piste / dérouter) ;
  sans destination, la colonne affiche « no track » au lieu d'un
  « Track 1 » imaginaire.

### Décisions prises dans la discussion

- **Knobs : option A** (34 px, libellé dessous) dans les panneaux ;
  28 px réservé aux bandeaux denses.
- **Toggles : icônes** qui représentent l'action, pas seulement une
  couleur → d'où le chantier bibliothèque d'icônes.
- **Icônes : portage VECTORIEL**, pas des PNG. Nos glyphes sont du code
  Lua baké en 4× (anticrénelage, teinte par le thème, zéro fichier,
  zéro accès disque) ; des PNG perdraient les trois. Source retenue :
  **Lucide** (licence ISC, ~1500 icônes, style trait 24 px cohérent avec
  le nôtre) ; équivalents acceptables : Tabler (MIT), Phosphor (MIT).
  Cédric télécharge le dépôt, un convertisseur SVG → primitives `gfx`
  génère le pack, seules les icônes utiles sont embarquées + la licence.
- **Layout : colonne à gauche** (rail) pour CP_Editor, CP_Sampler,
  CP_Session — vues horizontales ; barre haute conservée pour le Media
  Explorer (vue verticale). Rail standardisé dans le toolkit, deux
  largeurs (large / icônes seules), pliage mémorisé par app.
- **CP_Looper devient un step sequencer** façon channel rack : il cesse
  de dupliquer le piano roll de CP_Editor. Les LIGNES sont les **pads du
  kit routé sur la lane** (détection automatique, une ligne par pad
  chargé) ; un instrument qui n'est pas un kit CP retombe sur les notes
  présentes dans la boucle. Le pas est une VUE du même clip (start,
  durée, pitch, vélocité) — aucune conversion, le même clip s'ouvre en
  pas ici et en piano roll dans CP_Editor. Les notes hors grille
  s'affichent en demi-teinte plutôt que d'être quantisées de force.
  Résolution réglable (1/8, 1/16, 1/32, triolets), nombre de pas suivant
  la longueur.
- **CP_Sampler et CP_Editor restent séparés** : le pont DnD suffit.
  L'Editor fabrique et édite ce qui est joué ; les boutons « slices to
  pads / sel to pad / to instrument » sont des EXPORTS vers le Sampler,
  pas du sampling dans l'Editor.
- **Mixer** : pas de console. Trois contrôles par piste dans la Session
  (volume, mute, solo) — le reste vit dans le mixer de REAPER.

### Reste à faire, dans l'ordre

1. ✅ **Rail** dans le toolkit, puis Session → Sampler → Editor. *(sessions 10-11 ;
   CP_Editor est finalement repassé en barre haute sur son retour de test)*
2. ✅ **Icônes** : convertisseur SVG + pack Lucide + toggles à icônes. *(session 9 ;
   l'extension du pack à 200-400 glyphes attend son choix des familles)*
3. ✅ **Mixer minimal** Session (vol/mute/solo) + couleur de clip. *(session 12)*
4. **CP_Looper en step sequencer**. ← le prochain
5. Session phases 2-6 : quantisation par clip, legato, **follow
   actions**, tempo par scène, audio P4 (moteur sample-lock), capture
   vers l'arrangeur.
6. Fond de tiroir : palette sémantique + sweep des couleurs en dur,
   DnD-capture de modulation, « ? » dans ME/ModLFO/FXC.

---

## Session 8 — un seul moteur, et une grille qui se lit

Retour de test : « le CP_Editor n'est pas toujours sync avec CP_Session…
des fois il affiche bien le MIDI d'un clip en cours et pourtant son
curseur d'avancement n'est pas présent… le son ne sort pas toujours…
c'est comme si CP_Editor et CP_Session avaient deux logiques différentes
et pas un même moteur commun. »

Diagnostic mené sur les cinq fichiers concernés (audit multi-agents,
27 défauts confirmés). Il n'y avait pas un bug mais **une erreur de
modèle**, dont tout le reste découlait.

### L'erreur de modèle

Une piste de Session, c'est **deux lanes** du moteur : celle qu'on
entend et une jumelle silencieuse dans laquelle on prépare le clip
suivant, pour que l'échange tombe sur la frontière de quantisation.
Cette paire n'existait que dans la tête de CP_Session. Conséquences :

- **Le routage était par lane.** Router une colonne ne câblait que la
  moitié basse ; dès que l'échange basculait sur la jumelle, le MIDI
  partait sur un canal que rien ne transportait → *le son ne sort pas
  toujours*, une fois sur deux, selon la parité des lancements.
- **CP_Editor mémorisait un numéro de lane** au moment de l'ouverture.
  Le clip changeait de moitié sous lui : plus de curseur, état
  play/stop faux, et surtout des éditions écrites dans le clip qu'on
  n'éditait pas.
- **CP_Looper adressait les lanes brutes 0-3.** Une piste jouant sur sa
  jumelle disparaissait de sa vue.
- **Le compteur de commandes était local à chaque script** alors que la
  case gmem est partagée : deux fenêtres finissaient par écrire un
  numéro déjà vu, et le moteur ignorait la commande sans trace.
- **`cur[t]`** (quelle cellule joue) n'était déduit de rien : à la
  réouverture de la fenêtre, la grille montrait du silence sur des
  boucles audibles.

### Ce qui a été fait

`CP_Engine/Loop.lua` expose désormais des **pistes**, plus des lanes :

- `Loop.TRACKS`, `Loop.LiveLane(t)`, `Loop.TwinLane(t)`,
  `Loop.TrackOfLane(lane)` — la moitié vivante est **redérivée du moteur
  à chaque frame**, jamais mémorisée.
- **Étiquette d'occupation** par lane (`Loop.SetLaneTag` /
  `Loop.LaneOfTag`), dans une case gmem libre : une lane dit quelle
  cellule elle tient, donc n'importe quelle fenêtre retrouve un clip
  après un échange — et sait se taire quand le moteur ne le tient plus
  (nil, pas un repli hasardeux).
- `Loop.Poll()` : **un seul appel par frame** dans chaque fenêtre —
  gmem resélectionné, une commande en attente qui part, moitiés vivantes
  redérivées. Les trois vues lisent la même image.
- `Loop.SetLaneDest` **câble les deux moitiés** ; `SyncSends` répare les
  projets routés avant la paire.
- `Loop.Ensure(create)` : **n'importe quelle fenêtre** crée ou rafraîchit
  le moteur. Plus besoin d'ouvrir CP_Looper d'abord.
- File de commandes : le compteur avance depuis gmem et la garde attend
  l'acquittement **de la case**, pas de ses propres envois.

Les trois fenêtres ont été converties : CP_Session perd sa logique de
paire privée, CP_Editor garde une piste + une étiquette (le numéro de
lane est résolu chaque frame), CP_Looper adresse des pistes.

### La grille

Quatre poids — **mesure > temps > croche > plus fin** — partagés par les
deux piano rolls (`RollUI.GRID_ALPHA`). Dessinés en **passes
superposées, du plus faible au plus fort** plutôt que par
classification : une barre de mesure n'a plus besoin de tomber sur le
pas de grille pour exister (carte de tempo, mesures composées), et une
grille en triolets continue de dessiner des triolets. Le temps suit la
vraie métrique en mode item (6/8 se hiérarchise sur ses croches) et la
convention du moteur en mode clip.

### Reste à faire

Inchangé — rail, icônes, mixer minimal, step sequencer, phases 2-6 —
voir la liste de la session 7.

---

## Session 9 (2026-07-25) — le moniteur d'entrée, puis les icônes

Ordre retenu, discuté avec lui : **ce qui est cassé, puis les fondations UI,
puis ce qui s'appuie dessus, puis la profondeur fonctionnelle.** La deuxième
marche vient de sa règle de la session 3 (« refonte graphique avant, pour
éviter les dettes techniques ») : l'unification étant finie, c'est son tour.

- [x] **Un seul moniteur d'entrée** (`f11072f`). Deux rapports — « un C2 du
  sampler déclenche aussi Vital sur la colonne 1 » et « le kit sort à +6 dB
  dès que je route la colonne sur CP Kit MIDI » — n'en faisaient **qu'un**.
  +6 dB, c'est exactement le double d'amplitude : la même note jouée deux
  fois, en phase. `StuffMIDIMessage` est une diffusion vers toute piste armée
  en monitoring, et la suite en arme deux volontairement ; par-dessus,
  `gmem[ARMED]` **n'avait pas de valeur « personne »** (un arm hors plage
  était rabattu sur la lane 0), donc un projet auquel on n'avait pas touché
  monitorait la lane 0 quand même. Correction en deux moitiés : les previews
  sortent sur le canal 16 et le moteur les ignore (ni monitorées, ni
  capturées — un preview n'est pas du jeu) ; et armer devient une décision,
  -1 par défaut, bascule dans les deux hôtes, plus d'armement en douce à
  l'ouverture d'un éditeur. Tant que le routeur monitore une lane armée, le
  bus du kit se rétrécit sur le canal de preview. BUILD_VER 3.
- [x] **Record lisible** (même commit) : la cellule distinguait mal « armé,
  en attente de la frontière » de « prise en cours » — elle virait au rouge
  dès le clic, y compris quand rien n'avait commencé, d'où « des fois la case
  devient rouge, des fois pas » et « je n'ai jamais réussi à enregistrer ».
  Attente = clignotement plus lent et plus sombre ; second clic = finalise ou
  annule.
- [x] **Pack d'icônes Lucide** (`ba846ad`) : convertisseur SVG → primitives
  `gfx` (`CP_Tools/icons/build_pack.mjs`), aplatissement à la construction
  (Béziers subdivisées, arcs SVG en paramétrage central, rects arrondis
  développés) vers un flux plat de nombres dans le repère 24×24 que
  `Icons.lua` parcourt sans rien allouer. **57 glyphes**, additifs seulement :
  un nom déjà dessiné à la main garde son glyphe (les triangles de transport
  sont PLEINS et se lisent mieux qu'un contour à 14 px). Source Lucide
  gitignorée, licence ISC commitée. Ajouter une icône = une ligne dans
  `manifest.txt` + une relance.
- [x] **Toggles à icône** (`2ad787d`) : `UI.IconButton` / `UI.IconToggle`.
  L'argument qui compte est `icon_off` — une couleur oblige à se souvenir de
  ce que l'allumage signifie, une **paire** de glyphes l'énonce. Première
  migration : le « Listen » de CP_Editor.

**Reste, dans l'ordre** : rail (toolkit → Session → Sampler → Editor), mixer
minimal Session + couleur de clip, CP_Looper en step sequencer, phases 2-6
(follow actions d'abord), fond de tiroir.

- [x] **L'enregistrement, pour de bon** (`4652dff`). Retour : « la case rouge
  une fois sur deux », « les notes sont enregistrées mais ça ne crée pas de
  clip ». **Le même défaut**, dans `pollRec` : une commande ne prend pas effet
  à la frame où on l'émet (le moteur en consomme une par bloc), donc pendant
  quelques frames la lane est encore en mode 0 — la cellule était vide — et
  `pollRec` lisait ce 0 comme « effacé sous nos pieds ». Selon le timing, la
  case devenait rouge ou pas ; et quand l'état était lâché, la prise tournait
  quand même, les notes étaient capturées (l'éditeur les montrait) mais plus
  personne n'attendait le résultat. `pollRec` attend maintenant d'avoir **vu**
  le moteur prendre la commande. Deux défauts de la même famille corrigés
  avec : il suivait « la lane vivante » au lieu de celle visée, et `laneBusy`
  ignorait ARMÉ et REC-EN-ATTENTE. Enfin, enregistrer dans une cellule vide
  envoyait REC à la moitié vivante — qui pouvait jouer un autre clip de la
  piste, que REC efface : la prise va dans la jumelle, comme `launchCell`.
- [x] **Le comportement, aligné sur Ableton** (même commit) : quantisation de
  lancement à **une mesure par défaut** (zéro rendait le double tampon A/B
  inutile et démarrait une prise en plein milieu de mesure) ; la case
  **décompte les temps** avant le départ ; en Follow transport arrêté elle
  affiche PLAY sans déclencher le transport à sa place ; **pas de pre-roll**,
  comme Ableton en session — la quantisation EST le pre-roll ; la **durée de
  prise** devient un réglage annoncé (`Rec: N bars`) puisque notre moteur
  ferme la prise tout seul, contrairement à l'enregistrement session
  d'Ableton qui reste ouvert ; barre de progression pendant la prise ; l'aide
  dit les trois étapes et ce qui rentre.

**Ouvert, noté pendant la session** : enregistrer par-dessus une cellule
pleine (Ableton le permet), et un métronome / décompte audible.

## Session 10 (2026-07-25) — le système visuel, puis les zones

Tout le détail est dans `ANALYSE_DesignSystem.md` (l'analyse et le plan) et
`CP_Toolkit/COMPOSANTS.md` (la grammaire, à côté du code). Ici, seulement l'état.

**Point de départ**, son constat : « on perd le cap pour le theming ». Le
diagnostic n'était pas celui qu'on croyait — ce n'était pas un problème de
contraste mais de **lumière**, et sous ça une cause bête : `Theme.Default()`
était un brouillon que le système de macros réécrivait à sa dernière ligne, donc
l'apparence réelle du produit était le contenu de `CP_Config/theme.lua`, resté
le thème de debug.

- [x] **Vague 1 — l'identité** (`852c5a3`) : 65 couleurs écrites en dur, macros
  supprimées (dormantes, inertes au chargement, destructrices quand elles
  tiraient), sauvegarde en **diff** (les nouvelles clés arrivent donc dans les
  anciens thèmes), et sept collisions où deux états rendaient la même couleur.
- [x] **Vague 2 — la grammaire** (`00ddda3`, `46369a4`) : une seule façon de
  dire « cette ligne est sélectionnée » (il y en avait quatre, dont trois hors
  d'atteinte du thème) ; clic droit tape une valeur partout, double-clic remet
  au défaut partout, molette sur les trois contrôles de valeur.
- [x] **Inspecteur + Reveal** (`dcdee2f`, `665af2a`, `4f70123`), sur demande :
  pointer un pixel dans n'importe quelle fenêtre CP et obtenir le nom du jeton ;
  survoler une couleur entoure les zones qu'elle peint, dans **toutes** les
  fenêtres ouvertes. Pipette passée sur **E**.
- [x] **Le knob** (`e8a0fe9`) : son bug. L'aiguille était à 90° de son propre
  arc — `gfx.arc` mesure depuis le haut dans le sens horaire, `cos`/`sin` depuis
  la droite dans l'autre sens, et le pointeur prenait directement l'angle donné
  à l'arc. L'arc a toujours été juste ; c'est l'aiguille qui mentait, et sur un
  cadran de 34 px c'est elle qu'on lit.
- [x] **Vague 3 — les ZONES** (`2bc22cc` → `7aa7d12`). Sa demande : « une
  fenêtre doit avoir son contour, c'est sa zone… de la séparation et du
  contraste non pas en palette, mais en design ». Livré : `BeginBar`/`EndBar`,
  `AppStatus`, le contour de fenêtre, et une **couture** (un pixel d'ombre, un
  de lumière) au lieu d'un trait coloré — un trait ne sépare que tant que la
  palette lui laisse la place, une couture est un contraste local et survit à
  n'importe quel thème.
  **Sept fenêtres migrées** (Editor, Sampler, Looper, Session, MediaExplorer,
  FXBrowser, ThemeTweaker) ; les trois `iconBtn` privés supprimés ; les quatre
  états (repos / survol / enfoncé / allumé) sur tout ce qui se clique, dix
  contrôles n'ayant pas d'état enfoncé.
  **CP_Editor repasse en barre haute** sur son retour de test : le rail coûtait
  126 px de largeur en permanence, une barre coûte 30 px de hauteur une fois.
  Son verdict après test : « les zones, on les voit clairement, les icônes,
  l'alignement, c'est génial ».

## Session 11 (2026-07-25) — Floating Toolbar

- [x] **La fenêtre trop grande à l'ouverture** (`7526195`, `3a0a659`, `b224b10`).
  `gfx.init` n'ouvre pas toujours à la taille demandée (la géométrie est
  mémorisée par NOM de fenêtre), et le retrait du cadre atterrit une ou deux
  frames plus tard. Corrigé en **boucle fermée** : on mesure l'écart entre le
  client que gfx annonce et celui qu'on veut, et on déplace le rectangle
  extérieur de cet écart exact — ça converge quel que soit le cadre. Affirmer
  `extérieur = client` ne suffisait pas : quelques pixels de cadre survivent.
- [x] **Trois sols au choix** : `panel` (une dalle), `chips` (une puce arrondie
  par icône, boutons détachés), `none` (les glyphes seuls). Couleur, arrondi et
  bord séparés pour la dalle et pour les puces.
- [x] **Le manager remis d'aplomb** : les rangées étaient disposées à partir de
  la largeur de leur propre nom, donc rien n'était aligné verticalement. C'est
  une grille maintenant. La rangée **montre** l'icône, et un clic dessus ouvre
  le sélecteur — une porte au lieu de trois contrôles qui se disputaient le
  même rôle. Pipette (comme le Theme Tweaker) sur les deux couleurs. Taille
  d'icône qui peut **suivre le thème**.
- [x] **Le sélecteur d'icônes a deux sources** : les PNG de REAPER et le pack CP
  (dessinés, donc ils prennent la couleur du thème).
- [x] Les trois `iconBtn` privés du dépôt sont tous supprimés.
- 🟡 **Clé chromatique, éteinte par défaut.** Elle rendrait les pixels non
  peints réellement transparents et traversants — le seul moyen d'avoir une
  barre non rectangulaire. **Elle ne prend pas sur sa machine** : le magenta
  s'affichait au lieu de disparaître. Gardée derrière une case marquée
  expérimentale, absente = éteinte. À reprendre si l'envie du flottant intégral
  revient (piste : vérifier `JS_Window_SetOpacity(hwnd, "COLOR", …)` et l'ordre
  entre `SetStyle POPUP` et l'ajout de `WS_EX_LAYERED`).

### À FAIRE PLUS TARD — étendre le pack d'icônes

Décidé le 2026-07-25, **repoussé volontairement**. Mesuré sur le pack existant :
**406 octets par glyphe**.

| | Fichier | Mémoire (env.) |
|---|---|---|
| 57 (actuel) | 23 Ko | ~30 Ko |
| 200 | 79 Ko | ~100 Ko |
| 400 | 159 Ko | ~200 Ko |
| 1754 (tout Lucide) | 0,68 Mo | ~0,9 Mo |

Le disque n'est pas le sujet. **Le coût est le temps d'analyse au chargement**,
et le toolkit est chargé par *chaque* script CP — donc quelques dizaines de ms
ajoutées à chaque ouverture de fenêtre, sur un PC de 2005, pour des glyphes
jamais utilisés.

**Recommandation : 200 à 400 glyphes curatés** (80–160 Ko, négligeable), ce qui
couvre tout ce dont une interface de DAW a besoin. Les 1754 restent faisables
mais exigeraient un chargement paresseux (un fichier par lettre, analysé à la
demande) — un chantier à part.

Procédure : une ligne par icône dans `CP_Tools/icons/manifest.txt`, puis
`node CP_Tools/icons/build_pack.mjs`. Aucun Lua à écrire. La source Lucide est
dans `Lucide/lucide-main/icons/` (1754 SVG, gitignorée).

**Attend son choix des familles** : transport, édition, fichiers, formes,
flèches, audio, MIDI, mixage…

---

**Reste sur le chantier visuel** : les 9 glyphes mixtes (mi-pleins, mi-trait) —
à faire en les regardant, et un PNG déposé dans `CP_Toolkit/IconOverrides/`
suffit à en remplacer un sans toucher au code ; `SetHot` sur les 14 widgets
muets ; l'anneau de focus (`RegisterFocusable`/`FocusNext`/`FocusPrev` existent
et n'ont **aucun appelant**, et TAB est capturé comme touche de validation) ;
les centrages `y + h * 0.5 - 6` dans les apps, où 6 est la moitié de `body = 12`
alors que le tweaker laisse monter `body` à 24. *(Les trois jetons de rôle qui
ne peignaient rien sont branchés : `mute` et `solo` en session 12, `mod` en 13.)*

**Les scripts périphériques attendent, sur sa demande** : ChordLab, ColorPicker,
Inspector, VideoKit, PaintSynth ne sont pas migrés sur les zones. « Le cœur
c'est ce qu'on travaille ici maintenant, on clarifie d'abord tout cela. »

---

## Session 12 (2026-07-25) — le mixer dans CP_Session, et la couleur de clip

La décision de la session 7 tenait en une phrase : **« Mixer : pas de console.
Trois contrôles par piste dans la Session (volume, mute, solo) — le reste vit
dans le mixer de REAPER. »** C'est ce qui est livré, plus le vu-mètre, parce
que trois contrôles muets ne disent pas quelle piste sonne trop fort.

### Ce qui est fait

- [x] **La bande, sous la grille** : par colonne, `M`, `S`, un fader et un
  vu-mètre. Sa propre couture et son propre sol — une zone qui partage le sol
  de sa voisine n'est pas une zone. Repliable (bascule à côté du « ? »,
  mémorisée) : elle coûte 28 px de hauteur en permanence, ce qui sur une
  fenêtre courte est la dernière rangée de la grille.
- [x] **La cible est la piste vers laquelle la colonne est ROUTÉE** — donc
  aussi le niveau de ce que CP_Sampler ou CP_Editor envoient là. Une colonne
  sans destination n'a rien à mixer et le dit en étant **désactivée**, pas en
  montrant un fader qui ne fait rien.
- [x] **`mute` et `solo` peignent enfin.** Les deux jetons étaient définis dans
  le thème et lus par personne depuis la refonte de la palette.
- [x] **Silencieux pour deux raisons, une seule couleur.** Le niveau du fader
  prend la teinte `mute` quand la colonne est muette **ou** quand quelqu'un
  d'autre est en solo : « qu'est-ce que j'entends réellement » se lit d'un
  coup d'œil au lieu de se déduire de quatre boutons.
- [x] **Le solo est celui de REAPER**, donc l'arrangement se tait aussi. C'est
  exactement ce que fait Ableton — il fallait juste que ce soit su, pas
  découvert. Ctrl-clic = exclusif.
- [x] **Couleur de clip.** Le champ `color` existait dans le descripteur CPC1
  depuis le chantier 5 et **personne ne l'écrivait**. C'est un INDEX dans une
  palette de 8 rangée dans `Clip.lua` (une seule couleur pour un clip, dans
  toutes les fenêtres, sans que deux d'entre elles aient à s'accorder sur un
  espace colorimétrique — et une palette se re-règle pour un thème clair, un
  RGB stocké non). Clic droit sur une cellule → Color. La teinte est **douce**
  (0,30) : dans cette suite la teinte est le canal de l'ÉTAT, et une cellule
  peinte à saturation pleine dépenserait ce canal en identité.

### Ce qui est monté d'un cran

- **`CP_Engine/Mix.lua`** — la couche domaine : volume, mute, solo, vu-mètres,
  et la courbe de fader. Deux segments droits en décibels, articulés à 0,8 :
  un fader linéaire en dB de −60 à +6 mettrait l'unité à 0,91 de la course,
  c'est-à-dire la zone où on mixe vraiment écrasée dans le dernier dixième.
  Le vu-mètre partage cette échelle, donc l'unité est au même endroit sur les
  deux. Un point d'annulation par geste, jamais par frame.
- **Trois primitives de toolkit posées par un RECTANGLE** : `UI.ChipAt`,
  `UI.FaderAt`, `UI.MeterAt` (`VMeter`/`HMeter` passent désormais par la
  troisième). Une grille calcule sa propre géométrie, le curseur de flux n'a
  rien à y dire — et c'est précisément là que chaque app avait recommencé à
  écrire son bouton privé. `FaderAt` rend `changed, value, released` : le
  relâchement est ce qui fait qu'un glisser est **un** point d'annulation.

### Ce qui n'est pas fait, et pourquoi

- **Pas de pan.** C'est le premier pas vers la console qu'on a refusée, et il
  est à un clic dans le mixer de REAPER.
- **Pas de sends, pas de FX, pas de hiérarchie de dossiers.** Même raison.
- **Le stop par colonne existait déjà** (rangée de carrés sous la grille,
  session 7) — c'est le seul élément de tranche que l'analyse Ableton
  réclamait et il était en place.

---

## Session 13 (2026-07-26) — la forme d'onde, les poignées, et trois retours de test

### Le rendu de forme d'onde, une seule fois et lisse

Trois endroits dessinaient la même boucle avec trois petites divergences, et
tous les trois dessinaient une **palissade** : un trait vertical par colonne,
isolé de ses voisins. `Peaks.Render` est cette boucle, une fois, et elle fait
deux choses de plus :

- les colonnes sont **reliées** le long des enveloppes haute et basse. Une
  colonne seule redevient une palissade dès que le zoom dépasse la résolution
  des crêtes ; reliée, c'est une forme avec un bord ;
- l'appelant **cuit en 2×** et reblitte en `gfx.mode = 4` — le tour que les
  knobs utilisent déjà. Les crêtes sont **lues** deux fois plus fin, donc ce
  n'est pas un flou de données grossières mais du vrai suréchantillonnage.

Coût : un `GetPeaks` de double compte et deux fois plus d'appels de ligne, tous
deux payés **seulement quand la vue change**. Une frame stable reste un blit.

### CP_Sampler — retours de test

- [x] **Le trou sous la waveform.** La réserve de la bande de contrôle était
  dimensionnée pour le cas le plus haut et le contenu ne la remplissait jamais.
  On mesure maintenant ce que la grille a *réellement* pris et la forme d'onde
  reçoit tout le reste.
- [x] **La bande ne change plus de taille** (176 → 56 px pour un pad vide) :
  cliquer un pad vide redimensionnait la grille sous le curseur. Les knobs
  restent, **désactivés** — d'où le support `disabled` ajouté au knob du toolkit.
- [x] **Les poignées répondent** : le dessin connaît ce qui est sous le curseur
  *avant* le clic, trois états sur chacune, et la réponse est la **taille**
  autant que la couleur (sur 5 px, une teinte seule n'est pas une réponse).
  Prise en haut **et** en bas sur les bords de région. Le curseur souris lit le
  même test que le dessin.
- [x] **Choke et Loop rentrent dans le rang** → `UI.KnobChip` / `UI.KnobToggle`.
- [x] L'enveloppe ADSR prend le jeton `mod` (le violet d'enveloppe de REAPER) :
  **le dernier jeton de rôle non lu est branché**, et un ambre en dur disparaît.

### CP_Editor — retours de test

- [x] **Le curseur de lecture.** Le test était `IsPlaying(state.path)`, or en
  mode item la preview joue la *source* de la prise — sans chemin, donc le test
  ne pouvait jamais être vrai là. Il suit maintenant ce qui joue quel que soit
  le mode, **et** le transport de REAPER quand l'item suivi passe sous la tête
  de lecture. Couleur `pending`, prise à REAPER : la même que celle qui bouge
  dans l'arrangeur.
- [x] **La boucle** (bouton à côté de Play) sur la partie jouée — la sélection,
  sinon la région. Sans FIN il n'y a rien contre quoi rebondir, d'où le repli
  sur la région ; `Audio.SetLoop` agit sur ce qui joue **déjà**.
- [x] **Les bords de la partie jouée se tirent**, comme la région du Sampler
  (`Ops.TrimEdge` : le bord de début déplace l'item avec lui, comme le glisser
  natif). Prises en **bas** pour ne jamais se disputer avec les fondus en haut.
  Les bords d'une sélection existante la redimensionnent au lieu d'en commencer
  une nouvelle. Deux familles, deux couleurs : la géométrie de l'**item** en
  couleur de texte, la sélection de l'**éditeur** en accent.

### CP_Session — un clip audio n'attend plus à chaque tour

L'alignement mesure de CF_Preview tient **chaque** passe de boucle à la grille,
pas seulement la première : un sample qui ne fait pas exactement N mesures
attend donc à la fin de chaque tour. C'est le trou entendu en Clock: Follow et
jamais en Free (transport arrêté ⇒ alignement jamais posé). On aligne le
**départ**, puis on relâche — une fois la lecture réellement commencée, sinon
la preview partirait sur-le-champ.

### Deuxième passe (ses retours sur la première)

- [x] **Le lavis sur la zone de sample disparaît**, et avec lui la raison qui
  le rendait nécessaire : la **région descend dans une bande le long du bas**
  (ses bords, et le milieu qui la fait glisser), l'enveloppe garde la forme
  d'onde. Deux familles empilées au lieu de deux familles qui se disputent le
  même clic — c'est le geste de CP_Editor, appliqué au Sampler comme demandé.
  *Détail qui aurait mordu* : l'enveloppe s'arrête au-dessus de la bande, sinon
  un sustain au minimum posait ses deux poignées dedans, où la région répond en
  premier, et elles devenaient inattrapables.
- [x] **La règle de CP_Editor place le curseur d'édition et rien d'autre**,
  comme celle de REAPER : on place où commence la prochaine action sans perdre
  la plage qu'on vient de sélectionner. Glisser dedans scrube.
- [x] **La sélection audio se cale sur la grille**, la même que celle du piano
  roll, avec les deux mêmes contrôles (aimant + résolution) — en mode fichier
  **et** sur un item de l'arrangeur. Le domaine dessiné est celui de la source
  et la grille est musicale : l'aller-retour passe par le TimeMap de REAPER, ce
  qui honore une carte de tempo au lieu de la supposer absente. Un fichier nu
  n'a pas de position, il est donc lu comme s'il commençait au zéro du projet.
  La grille n'est **dessinée que quand elle est ce à quoi la souris obéit**, et
  le calage sur passage par zéro ne s'applique plus que si elle est éteinte —
  les deux se battraient.
- [x] **ESC ne ferme plus l'éditeur.** La descente des couches (popup, focus)
  est inchangée ; la dernière marche est devenue une option du toolkit,
  `close_on_esc`, vraie par défaut. « Annuler ce que je fais » et « jeter ce sur
  quoi je travaille » ne sont pas la même intention. **Une ligne suffit pour
  l'appliquer aux autres fenêtres** le jour où ça se pose.

### Troisième passe

- [x] **Les trois départs de lecture de REAPER**, sur les trois mêmes touches :
  `Space` = le curseur d'édition, `Shift+Space` = le début de la sélection,
  `Ctrl+Shift+Space` = le début du sample. C'était « la sélection, sinon le
  curseur » — donc le curseur d'édition ne servait à rien dès qu'une sélection
  existait.
- [x] **La boucle ne reboucle plus sur le point de départ.** Partir d'un curseur
  posé au milieu puis boucler dessus répéterait un fragment que personne n'a
  demandé : le retour appartient à la **partie jouée** (la sélection, sinon le
  sample entier). `Audio` prend un `loop_start` distinct de `start_s`.
- [x] **Les transitoires sont des objets** : `Ctrl+clic` en ajoute un où l'on
  pointe, `M` en ajoute un sur le curseur (exact, et ça marche pendant que ça
  joue), glisser un fanion le déplace, `Alt+clic` (ou `Delete` sur le curseur)
  le supprime. Même chose dans le menu contextuel, raccourci écrit à côté.
  *Pas d'outil modal* : on attrape le fanion en haut, pas la ligne — la ligne
  traverse toute la hauteur et avalerait chaque glisser de sélection qui
  commence près d'un transitoire. Et cet éditeur n'a de palette d'outils nulle
  part ailleurs ; ce n'est pas pour deux gestes qu'il faut lui en donner une.
- [x] **Ils sont aussi des cibles de snap.** La grille n'a pas de limite de
  distance (elle est partout) ; un transitoire ne gagne que s'il est à la fois
  plus proche **et** à quelques pixels, sinon un marqueur à l'autre bout de la
  vue tirerait le curseur en travers de l'écran faute de concurrent.

### Quatrième passe — cinq règles de REAPER que l'éditeur n'appliquait pas

- [x] **Shift ignore le snap, partout** : bord de sélection, transitoire,
  règle, marqueur déposé. Une ligne, dans `waveSnap`, parce que c'est le seul
  endroit qui décide.
- [x] **Un clic ne touche plus à la sélection.** Il place le curseur, point ;
  seul un *glisser* change une sélection.
- [x] **Space part vraiment du curseur.** La partie jouée se lisait sur la
  sélection quel que soit le départ, donc le curseur était poussé sur le début
  de la sélection dès qu'il tombait après elle — et les trois touches donnaient
  le même résultat. Seul `Shift+Space` lit la sélection maintenant.
- [x] **La section est réaffirmée pendant que ça joue** : bouger la sélection
  en cours de boucle ne changeait rien jusqu'au prochain play.
- [x] **Ctrl+glisser la sélection dehors** — vers l'arrangeur (un vrai item
  suit la souris : la machine à fantôme d'`Insert`, celle du Media Explorer) ou
  vers une fenêtre CP (la même région en clip CPC1 sur le bus). **Rien n'est
  rendu** : une sélection *est* déjà une région d'un fichier, et un item est un
  fichier plus un offset et une longueur — donc pas de fichier temporaire, pas
  de bake, et ce qui atterrit reste entièrement éditable.
- [x] **La time selection n'est plus jamais ignorée.** On démarre dehors si on
  veut, mais dès que la tête de lecture y **entre**, ses bords commandent :
  boucle si la boucle est activée, arrêt à la fin si on a demandé ça (nouveau
  réglage *Playback stops at the end of the time selection*, actif par défaut).
  Armer la barrière **à l'arrivée** plutôt qu'à l'appui est ce qui permet à
  « partir de n'importe où » et à « une plage respectée » d'être la même chose.
  Une seule fonction décide quelle section est en vigueur et la réaffirme à
  chaque frame — elle arme, elle relâche si la règle qui l'avait armée vient
  d'être éteinte, et elle suit la sélection quand on la déplace en cours de
  lecture.

### À FAIRE PLUS TARD — les raccourcis clavier réassignables

Demandé explicitement le 2026-07-26, **repoussé volontairement**. À terme, les
raccourcis de **chaque programme** doivent être modifiables depuis ses Settings.

Ce que ça suppose, pour que le chantier soit fait une fois et pas cinq :
- une **table de commandes** par app (`id`, libellé, action), et le clavier qui
  la consulte au lieu de comparer des codes en dur dans une cascade de `if` ;
- un **binding** `id → (char, modificateurs)` rangé dans le config de l'app,
  donc un simple diff par rapport aux valeurs d'usine ;
- un **widget de capture** dans le toolkit (« appuyez sur la combinaison ») et
  la détection des collisions, qui est la partie qui fait vraiment le travail ;
- l'aide (`HELP_TEXT`) qui lit les bindings **effectifs** au lieu d'énoncer des
  touches écrites à la main, sinon elle mentira dès la première réassignation.

C'est le même chantier pour les cinq fenêtres : le faire dans le toolkit, pas
dans une app.

Les trois jetons de rôle `mute`, `solo` et `mod` attendent précisément ça —
`mute` et `solo` sont le vocabulaire documenté des boutons M/S, et ils sont
définis dans le thème sans que rien ne les lise. Le mixer est ce qui les
branche.

## Session 14 (2026-07-26) — quatre correctifs : le transport, le clic, la séparation

### CP_Session — un son suit l'horloge comme tout le reste

- [x] **En Follow, un clip audio attend le transport.** Les lanes MIDI l'ont
  toujours fait — le moteur avance sur le beat de l'hôte, donc un lancement mis
  en file sur un transport arrêté attend, tout simplement. Les cellules audio
  démarraient sur-le-champ : la grille montrait un clip en attente et le son
  sortait quand même.
  Un lancement et le moment où il démarre sont **deux choses différentes** dès
  que l'horloge suit. `audioPlay` **arme** la cellule, `pollAudio` la démarre
  quand l'horloge tourne, lui **reprend** l'aperçu quand le transport s'arrête,
  et la garde armée entre les deux. Une cellule armée porte la couleur d'un
  lancement en file : même état, même signe.
- [x] **`D_MEASUREALIGN` est parti, et avec lui les deux derniers symptômes.**
  Il tient **chaque passe** de boucle sur la grille de mesures, pas seulement la
  première : un sample qui ne fait pas exactement N mesures attend donc à la fin
  de chaque passe — c'est le trou entre deux instances. Et il ne sait aligner
  que sur une **mesure**, ce qui est exactement pourquoi un son ignorait le Q
  quand tous les clips MIDI l'honoraient. Le libérer après coup ne suffisait pas.
  La frontière est donc **la nôtre** maintenant (`launchBeat`), prise sur
  l'horloge du moteur et avec **la règle du JSFX recopiée** — une position à
  moins de 0.05 beat après une frontière compte comme dessus — pour qu'un son et
  un clip MIDI lancés ensemble atterrissent ensemble.
  Une frame fait 16 ms, donc on arrive toujours un cheveu après la frontière
  visée. Démarrer là laisserait le son en retard de ce cheveu **aussi longtemps
  qu'il boucle** : le dépassement est donc pris sur le **devant** du sample
  (`D_POSITION`), le clip atterrit en phase, et ce sont quelques millisecondes
  d'attaque que personne n'entend. La cible est reprise à chaque départ du
  transport — une frontière calculée sur une tête de lecture gelée est un numéro
  de beat dans un passé que le transport s'apprête à quitter.

### CP_Sampler — le drumkit et l'instrument sont deux instruments

L'instrument était une **page du kit** : piste fille du dossier, nourrie par le
bus du kit, avec la même plage de notes que les pads. Les deux ne pouvaient donc
que se relayer — regarder l'un **mutait** l'autre. Un kit ne pouvait pas jouer
pendant qu'un instrument était à l'écran, et aucun des deux ne se mixait
séparément puisque l'audio de l'instrument passait par le fader du kit.

- [x] **Sa piste, son entrée MIDI, sa sortie.** Plus aucun mute : les deux
  sonnent en même temps, c'est tout l'intérêt.
- [x] **Une seule chose reste exclusive, et elle doit l'être : qui entend le
  clavier.** Un clic de pad passe par la file du clavier virtuel, qui est une
  **diffusion** et atteint toute piste armée — sans arbitrage, cliquer un pad
  jouerait aussi l'instrument. L'écoute suit donc la vue (`armTarget`), comme la
  règle « un seul kit écoute » qui existait déjà pour exactement cette raison,
  et elle n'écarte l'autre que **tant qu'on revendique l'entrée** : désarmé, on
  n'a pas à toucher une piste que l'utilisateur a armée lui-même.
- [x] **`SplitInstrument` migre les projets existants**, une fois par session :
  coupe l'envoi du bus, donne l'entrée, sort la piste du dossier (la profondeur
  de fermeture repasse à l'enfant du dessus, ce qui couvre l'enfant unique comme
  l'enfant du milieu) et lève **les mutes que le mode avait posés** — ceux-là
  seulement, un pad muté à la main reste muté. En lecture pure quand il n'y a
  rien à faire : pas de bloc d'annulation ouvert pour rien.
- [x] **« Clicking a pad plays it » monte dans la barre** (puce pointeur) et
  quitte les settings. On y répond plusieurs fois par session — on tape sur les
  pads, puis on tourne des knobs pendant qu'une boucle joue — et une décision
  prise si souvent n'a rien à faire à deux clics de profondeur. Un seul foyer
  par décision : elle n'est plus dans le menu.
- [x] **Root / Voices / Loop prennent l'empreinte d'un cadran** côté instrument,
  comme Choke et Loop l'ont prise côté drum et pour la même raison : une boîte à
  chiffres et une case à cocher au bout d'une rangée de knobs sont deux intrus
  venus d'une autre fenêtre. **Voices est le choke de l'instrument** — à 1 le
  RS5K est monophonique, donc chaque note coupe la précédente, et c'est la seule
  forme de choke qu'un instrument chromatique unique puisse avoir.

### CP_MediaExplorer — le double-clic ouvre l'éditeur

- [x] Écouter un fichier puis vouloir le regarder de près est le pas suivant
  normal, et l'arrangement est à un glisser. Un fichier largué dans
  l'arrangement pour être examiné, lui, doit être retrouvé et supprimé. Le
  double-clic ouvre donc **CP_Editor en file mode** par défaut, avec la section
  active de la bande qui voyage avec — l'éditeur atterrit sélectionné sur ce
  qu'on écoutait. `Bus.OpenEditor` et non `Bus.Send` : un double-clic qui ne
  fait rien parce qu'une fenêtre était fermée serait pire que pas de
  double-clic du tout. Le choix est dans les options (éditeur / insertion au
  curseur), et un `.mid` prend l'autre route quoi qu'il arrive.

### CP_Session — parité complète entre un son et un clip

Le Q réglé, restait le reste : un son ne répondait pas à un clic comme un clip,
et l'écart se sentait sans se nommer. Il tenait à une asymétrie de structure —
une piste MIDI a **deux moitiés** (celle qui sonne, la jumelle qui attend), un
son n'en avait qu'une. Il en a deux maintenant, `aplay` et `aqueue`, et chaque
geste est écrit contre cette paire.

- [x] **L'arrêt est mis en file, comme le lancement.** Un clip ne s'arrête pas
  sous le doigt, il finit sa mesure ; un son n'avait aucune raison d'être
  l'exception. Deuxième clic sur un son qui joue = arrêt à la frontière (le
  clignotement *pending 2*, la couleur du texte, exactement comme une lane).
- [x] **L'échange se fait sur UNE frontière.** Lancer un son sur une piste qui
  en jouait déjà un coupait le premier **tout de suite** et faisait attendre le
  second : un trou de silence long comme le Q. Le sortant est maintenant mis en
  file sur la frontière du rentrant, et le poll fait les deux dans la même
  frame. Idem dans les deux sens entre MIDI et son.
- [x] **Annuler ce qui n'est que mis en file rend ce qui jouait.** C'était déjà
  la discipline des lanes (`Pending(twin) == 2 → Loop.Play(twin)`) ; le son la
  suit, et un clic sur un arrêt en attente le reprend.
- [x] **Un scene launch lance enfin les sons.** `sceneLaunch` demandait les
  NOTES de la cellule pour décider si elle avait du contenu — une cellule audio
  en a zéro, donc une scène contenant des sons **arrêtait** ces pistes-là.
- [x] **Supprimer une cellule arrête tout de suite** (frontière ou pas : il n'y
  a plus rien à finir), et une cellule dont l'aperçu a été repris par un
  transport arrêté redevient une cellule *en attente* — sauf si elle était déjà
  en train de sortir, auquel cas l'arrêt du transport est simplement là où elle
  va.

Reste **une** couture assumée, écrite dans l'aide : après un arrêt puis un
redépart du transport, un son repart de son début là où un clip reprend en phase
avec le beat. C'est le moteur intérimaire ; le moteur verrouillé à
l'échantillon est ce qui la ferme.

## Session 15 (2026-07-26) — la sortie du son, et le mixer qui devient une console

### Le son sortait par la porte de derrière

- [x] **Un aperçu sans piste de sortie part DIRECTEMENT au matériel** : pas par
  le fader de la colonne, pas par le master, pas dans ce qu'on enregistre. Le
  son était audible et *nulle part* — et c'est très probablement pourquoi il
  était aussi décalé, puisqu'il sautait le chemin de sortie sur lequel tout le
  projet est aligné.
  La règle « pas de piste quand elle porte un instrument » était juste sur le
  fait (un synth remplace son entrée par sa propre sortie, l'audio y disparaît)
  et fausse sur la conclusion. `previewDest` cherche le premier endroit **en
  aval** qui peut prendre de l'audio : la piste elle-même, sinon le dossier où
  elle vit, sinon le master.
- [x] **Le tempo se décide au même endroit que dans le navigateur.**
  `Preview.TempoSyncRate` connaît le tempo-match de REAPER **et** le BPM écrit
  dans le nom de fichier ; la grille n'appelait que le premier et jouait donc à
  1.0 ce que le navigateur étirait. Le `src_bpm` porté par le clip gagne quand
  il y en a un.
- [x] **Le rattrapage de phase se mesure en temps projet** contre
  `GetPlayPosition2` (la position que le thread audio s'apprête à rendre, donc
  celle où le premier échantillon tombe), **plus une demi-frame audio** :
  l'aperçu est ramassé au bloc suivant, son vrai départ est quelque part dans
  `[maintenant, maintenant + un bloc]`.
- [x] **Un REC qui n'a rien capturé le dit.** Avec Rec: 1 bar tout est fini deux
  secondes après le play, et une cellule qui cesse simplement de clignoter se
  lit comme « l'enregistrement a été supprimé ».
- [x] **Le toggle Clock est allumé quand on SUIT l'horloge.** Un bouton appelé
  Clock qui s'allume pour dire « pas d'horloge » dit le contraire de son nom, et
  l'œil lit la lumière avant l'infobulle. (Corrigé aussi dans CP_Looper.)

### Le mixer : la décision de la session 7 est révisée, à sa demande

« Mixer : pas de console » était vrai du **format** et faux de la **vue**. Rien
dans ce qui suit n'est un second moteur de mixage : chaque valeur est l'état de
piste de REAPER, lu et écrit par son API, et la fenêtre de chaîne qui s'ouvre est
la sienne. Ce qui manquait à la session, c'était la **chaîne** et les **sends**
de ce qu'elle lance, *à côté* de ce qu'elle lance — y accéder demandait de
quitter la fenêtre, et ne pas quitter la fenêtre est ce à quoi sert une session
view.

- [x] **Une tranche par colonne** : chaîne FX, sends, pan, fader vertical +
  vumètre, M/S.
- [x] **La hauteur de la zone est le seul réglage.** On tire son seam et, de bas
  en haut, apparaissent le bloc de fader, puis les sends, puis la chaîne. Pas de
  sous-cases à cocher : la hauteur *est* la réponse, et c'est un geste au lieu de
  trois cases.
- [x] **FX** : clic pour ouvrir, Ctrl-clic bypass, Alt-clic supprimer, clic droit
  pour les trois. Glisser réordonne ; glisser sur une autre colonne **déplace**
  (Ctrl : copie) — `TrackFX_CopyToTrack`, donc le plugin garde ses paramètres,
  son automation et sa fenêtre. Un FX glissé depuis le Media Explorer atterrit
  dans la tranche où on le lâche (le bus de drag portait déjà le type `fx`).
- [x] **Sends** : chaque ligne EST le send — on la tire pour régler son niveau,
  clic droit pour muter ou retirer. Pour en créer un, on tire « + send » sur la
  colonne destinataire : le geste dit *d'ici vers là*.
- [x] **Les seules chaînes de caractères du lot sont cachées** contre le compteur
  de changements du projet. Une tranche se redessine trente fois par seconde et
  `TrackFX_GetFXName` alloue à chaque appel.
- [x] **Le fader vertical manquait au toolkit** : `Widgets.VFaderAt`, avec un
  **cap** plutôt qu'une barre pleine — le point de prise doit se voir.
- [x] **Des slots, trois sections, et le texte qui tient dans sa case.** La
  chaîne se dessine en slots pleins ou vides, comme sur toute console — donc
  plus de « + FX » : un slot vide *est* le bouton. Un slot vide sélectionne la
  piste de la colonne et ouvre le **FX browser natif** (40271) ; un clic sur un
  send ouvre la **fenêtre de routage** de REAPER (40293), où vivent ses vrais
  paramètres. Une barre fine paraît quand la chaîne dépasse les slots visibles.
- [x] **La position du son est une formule, pas un espoir** : `lockPhase`
  redérive la position depuis le transport à chaque passe (4 ms de tolérance au
  départ, veille de dérive à 30 ms toutes les demi-secondes), et la latence de
  la chaîne (`pdc`) est compensée en nourrissant l'aperçu **plus loin dedans**.

## Session 16 (2026-07-26) — une seule règle de lancement, et une geste = un bloc

Le constat, posé à sa demande : en **Follow** avec le transport arrêté, un clip
ne *attendait* pas — il passait en « playing » sans rien jouer, puis entrait au
play là où le transport tombait. En **Free**, il attendait le Q alors que rien
ne jouait. Les deux à l'envers de ce qu'on attend, et l'audio par-dessus.

### La règle, et il n'y en a qu'une

- [x] **DÉMARRER a besoin d'un temps fort.** Sans horloge il n'y en a pas encore,
  donc un lancement **attend l'horloge** (`WAIT_CLOCK`) et part avec son
  **premier bloc** — pas une mesure après. Ce premier bloc *est* une frontière :
  le transport qui démarre est le temps fort que tout le monde attendait. Clips,
  sons et prises attendent ensemble et atterrissent ensemble.
- [x] **ARRÊTER n'a besoin de rien.** Sur une horloge qui tourne un clip finit sa
  mesure ; sans horloge il n'y a plus rien à finir, donc il s'arrête tout de
  suite. (`launch_target` / `stop_target` : deux fonctions, et les huit blocs de
  quantize recopiés dans le JSFX deviennent huit appels.)
- [x] **L'horloge libre est le transport de la session, et un transport que rien
  ne fait tourner est à ZÉRO.** Elle est tenue là tant qu'aucune lane ne sonne
  et qu'aucune cellule sonore ne joue — donc le premier lancement d'une session
  silencieuse tombe sur le temps 0 : immédiat, en phase, et c'est lui qui
  démarre l'horloge. Tout ce qui suit se quantifie contre ce qui joue déjà, ce
  qui est le seul moment où une quantification veut dire quelque chose.
- [x] **Le moteur ne voit pas un aperçu CF**, donc on le lui dit :
  `Loop.SetAudioRun` (gmem 8), écrit chaque frame, posé *avant* que le son
  existe, et effacé à la fermeture (`atexit`, donc même sur erreur).
- [x] **La cellule dit ce qu'elle attend** : « waiting for the transport » au
  lieu d'un clignotement qui se lit comme « bloqué ».

### Un geste est une intention, il doit tenir en un bloc

- [x] **File de commandes en ANNEAU** (gmem 400, 32 slots × 3 ; curseur en 9).
  Le moteur draine tout ce qui a été écrit depuis son dernier bloc. Avant :
  une seule case et un accusé de réception, donc **une commande par frame** —
  or les gestes qui comptent n'en sont jamais une seule. Un échange de clip en
  fait deux (arrêter cette moitié, lancer l'autre) et une **scène** en fait une
  paire par piste : distillées une par frame, elles pouvaient tomber de part et
  d'autre d'une frontière. Une demi-scène qui part une mesure avant l'autre
  n'est pas une quantification, c'est un bug bien élevé.
- [x] Disparaissent avec : `Loop.PumpCmd`, la file Lua, l'attente d'ACK et son
  timeout de 60 ms. Les cases 0..2, 5 et 7 sont **laissées inutilisées** plutôt
  que recyclées — un moteur d'avant y croit encore, et c'est `Loop.Ensure` qui
  doit le remplacer, pas un nombre égaré.

### Le son sur les deux horloges

- [x] **Une seule question, deux réponses** : `elapsed(a)` rend le temps écoulé
  depuis la frontière, mesuré sur le **thread audio** dans les deux cas —
  `GetPlayPosition2` en Follow, le beat du moteur (que le JSFX avance un bloc à
  la fois) en Free. `lockPhase` tient donc **aussi en Free**, où il renonçait
  faute de transport : c'est exactement là que le son partait à la dérive.
- [x] **Un lancement mis en attente sans horloge part au premier temps de
  celle-ci**, et non à la frontière *suivante* — c'est ce qui laissait un son
  une mesure entière derrière le clip lancé avec lui.
- [x] **Changer d'horloge sous un son qui joue** ne le déplace plus : c'est la
  référence qui bouge (`reanchor`), et les cibles en attente sont recalculées
  sur la nouvelle horloge. Le moteur fait déjà ça pour ses lanes.

### Correctifs de la même session

- [x] **EEL n'a pas de notation scientifique.** `-1e9` se lit `-1` suivi d'un
  identifiant parasite : le JSFX ne compilait plus du tout, donc le moteur ne
  répondait plus rien — ni sa version, ni ses lanes, ni une seule commande. Les
  sentinelles sont écrites en toutes lettres.
- [x] **Un moteur MUET se répare tout seul.** La vérification de fraîcheur était
  conditionnée à « le moteur est vivant » — donc le seul cas qu'on ne réparait
  pas était celui d'un moteur qui avait échoué à se charger. Il est toujours
  dans la chaîne, il répond toujours à son nom, il ne dit simplement rien. Un
  moteur muet annonce zéro lane : il tombe dans la même branche qu'un moteur
  périmé.
- [x] **La veille de dérive hachait le son.** Déplacer un aperçu **déjà en train
  de jouer** n'est pas gratuit : SWS réamorce son tampon, et une correction
  toutes les demi-secondes est un trou dans la musique toutes les demi-secondes.
  Sur une boucle tempo-matchée en Free, l'écart systématique (le temps
  d'ouverture du fichier) restait juste au-dessus de la tolérance de 30 ms :
  la veille corrigeait *à chaque passe*, indéfiniment. Il reste **UN** rattrapage,
  à la frame suivant le départ, sous 20 ms d'insensibilité et plafonné à 250 ms.
  Une boucle et le projet tournent sur **la même horloge de carte son** : il n'y
  avait pas de dérive à surveiller, la dérive *était* la surveillance.
- [x] **« Le premier bloc de l'horloge EST une frontière » était une règle trop
  maligne, et elle est retirée.** C'est vrai d'une horloge externe — un
  démarrage d'horloge externe *est* un temps fort. C'est faux du transport de
  REAPER, qui démarre là où le curseur traîne. La grille de mesures existe que
  le transport roule ou non : une attente prend donc une **vraie frontière** au
  moment où l'horloge apparaît. Sur une mesure, ça part ; entre deux mesures,
  Q: Bar veut toujours dire la mesure suivante. Corrigé des deux côtés (JSFX et
  cellules sonores) pour qu'un son et un clip lancés ensemble arrivent ensemble.
- [x] **LE DÉCALAGE, ENFIN MESURÉ ET COMPRIS.** 147 ms avec un buffer ASIO de
  3 ms ; 67 ms avec un buffer DirectSound de 200 ms. **L'écart grandit quand la
  latence rétrécit** — ce qui élimine d'un coup le buffer, la latence de sortie,
  le PDC et l'étireur : rien en aval du son ne peut être inversement
  proportionnel à la taille du bloc. Seule quelque chose qui court *devant* lui
  le peut.
  C'est le **traitement anticipatif** de REAPER : une piste est rendue en avance
  sur le curseur (200 ms par défaut) et mise en tampon. Un item y arrive à sa
  position de timeline, donc à l'heure ; un aperçu, lui, est mélangé au moment
  où le thread audio calcule cette piste — c'est-à-dire à la position qu'elle
  atteindra 200 ms plus tard. Le son est donc en retard de tout ce que REAPER a
  réussi à rendre en avance, et il en rend d'autant plus que les blocs sont
  petits.
  Et c'est exactement pourquoi le MIDI n'a JAMAIS été touché : le moteur vit sur
  une piste armée et monitorée, que REAPER joue déjà en direct.
  Correctif : `I_PERFFLAGS` (&1 pas de mise en tampon média, &2 pas de
  traitement anticipatif) sur la piste de destination — la réponse que REAPER
  donne lui-même à ses pistes live. Une colonne qui joue des sons est une
  colonne live.
- [x] **LA MESURE QUI A TOUT DIT : le décalage est proportionnel au TAUX DE
  LECTURE.** 147 ms, 220 ms, 460 ms à trois tempos différents — divisés par leur
  taux respectif, ils donnent tous ~125 ms. Or il n'y a qu'un seul endroit dans
  le code qui multiplie par le taux : le `skip` de départ.
  Et il était calculé **après** l'ouverture du fichier. Ouvrir le WAV, construire
  l'aperçu et demander le tempo-match à REAPER (qui *analyse* la source, le plus
  lent des trois) se passait entre « la frontière vient de passer » et « le son
  démarre ». Ce coût était donc lu comme du temps musical déjà écoulé, et retiré
  du début de l'échantillon — multiplié par le taux. D'où la croissance avec le
  tempo, et l'instabilité : le prix d'une lecture disque n'est pas une constante.
  Correctif : **le fichier d'un son est ouvert dès qu'il est armé**, plus au
  moment où il part. Et le dépassement est borné à ce qu'il *est* — une frame
  plus un bloc, 60 ms — parce qu'au-delà ce n'est plus du dépassement, c'est
  notre propre lenteur, et la retirer du début du son ne corrige rien : ça
  creuse un trou là où était le temps fort.
- [x] **LE RÉSIDU ÉTAIT UNE FRAME D'AFFICHAGE, et on ne l'attend plus.** Après
  tout ce qui précède il restait 21-41 ms — et 0 ms en MIDI. La différence est
  entière : le moteur tire sur un **bloc audio** (3 ms), cette fenêtre tirait sur
  une **frame** (30 ms). Aucune arithmétique après coup ne récupère ça : quand on
  apprend que la frontière est passée, elle est passée.
  Donc on n'arrive plus après elle. Le lancement se fait jusqu'à **45 ms AVANT**
  la frontière, et l'aperçu est positionné d'autant depuis la **fin** de sa
  source : il boucle, donc il atteint son propre zéro *sur* le temps. Ce qu'on
  entend entre-temps est la queue de la boucle — ce qu'une boucle *est*, et au
  plus une frame de queue.
  La position devient une seule formule des deux côtés de la frontière, parce
  que `elapsed` est **signé** : négatif avant (la queue), positif après (le
  dépassement, retiré du début comme avant). `position = (elapsed × taux) mod
  longueur`.
- [x] **Un son remplacé finit sa frame.** Puisqu'on tire en avance, arrêter le
  sortant au moment du tir le couperait une frame avant la frontière qu'on lui
  avait donnée. Il est mis de côté et libéré à la frame suivante : les deux se
  chevauchent exactement sur l'avance, ce qui est ce qu'un échange fait sur une
  console — pas un trou.
- [x] **Le tempo du projet change sous un son qui joue, et le son suit.** Le taux
  était décidé à l'ouverture, donc une boucle gardait le tempo de son lancement
  jusqu'à ce qu'on l'arrête et la relance à la main. Le BPM propre de la source
  est dérivé à l'ouverture (tempo ÷ taux, exact et gratuit), donc le nouveau taux
  est une division — pas de réouverture, pas de seconde analyse. Et c'est la
  référence qui bouge, pas le son.
- [x] **Ce qui ne peut PAS être préparé d'avance : l'objet aperçu lui-même.**
  SWS balaie un aperçu créé et jamais démarré à la fin du cycle defer — la règle
  était déjà écrite en tête de `Engine/Preview`, et je l'ai enfreinte. Construit
  à l'armement, il était mort à la frontière : en Free le lancement est immédiat
  (même tick, donc ça marchait), en Follow l'attente est réelle et **le son ne
  sortait tout simplement pas**. La séparation est donc : la **source** est
  ouverte tôt (le disque et l'analyse de tempo, les deux choses chères), l'
  **aperçu** est construit et joué dans le même tick. La moitié coûteuse est
  celle qu'on déplace.
- [x] **Le vrai calage se fait avant que le son parte** — `D_POSITION` sur un
  aperçu qui n'a pas commencé, seul moment où une position se choisit
  librement. Et le drapeau « la session sonne » est posé **juste avant** le
  départ, plus à l'armement : le zéro de l'horloge libre et le premier
  échantillon du son sont désormais le même instant, ce qu'est un temps fort.
- [x] **ET LE DERNIER RÉSIDU N'ÉTAIT PAS DU TIMING : c'était l'ÉTIREUR.**
  Après le tir en avance, les 21-41 ms se sont effondrés en **40 ms constants**,
  identiques d'une prise à l'autre — et une variance qui disparaît en laissant
  une constante ne désigne plus une logique, elle désigne une **latence fixe**
  dans le chemin du son. Trois faits la localisent, et un seul endroit les
  explique tous les trois : le son est *toujours en retard* alors qu'on part
  maintenant 45 ms *en avance* (quelque chose en aval mange l'avance) ; le MIDI
  mesure 0 ms sur la même piste, la même carte, le même montage de mesure ; Q
  Off et Q 2 bars donnent le même chiffre.
  La seule chose que le son traversait et que le MIDI ne traversait pas :
  `B_PPITCH`. Préserver la hauteur pendant un changement de vitesse n'est pas de
  l'arithmétique sur un pointeur de lecture — c'est **l'étireur temporel de
  REAPER**, et un étireur ne peut rien émettre avant d'avoir rempli sa fenêtre
  d'analyse. Cette fenêtre est une latence : quelques dizaines de millisecondes,
  fixe pour un mode donné, et **aucune API ne la rapporte** — `D_POSITION` dit
  où l'étireur *lit*, ce qui court devant ce qu'on entend. D'où un calage qui se
  croyait juste et un son qui sortait en retard, toujours du même montant.
  Un échantillonneur ne fait pas ça : il lit le fichier plus vite. C'est
  précisément pourquoi le MIDI était à zéro.
- [x] **`tempo_mode` devient réel, et son défaut est le mode exact.** Le champ
  existait dans le vocabulaire de `Engine/Clip` (`none | repitch | stretch`) et
  n'était honoré nulle part. Clic droit sur une case → **Tempo** :
  *Repitch* (défaut) lit plus vite et déplace la hauteur avec — aucune fenêtre,
  aucune latence, exact par construction, et c'est ce que fait tout
  échantillonneur matériel ; *Stretch* garde la tonalité et sort en retard de la
  fenêtre de son étireur, ce que le menu et l'aide disent tous les deux ;
  *Don't follow* joue le fichier à son propre tempo.
  Un son qui joue prend un nouveau **taux** tout de suite (c'est un nombre) mais
  ne change pas de **machine** sous lui-même : basculer l'étirement attend le
  prochain lancement, à une frontière de là.
- [x] **LA FRONTIÈRE SE DÉFINISSAIT ELLE-MÊME — le défaut de fond.** Analyse
  transversale (25 agents, 15 hypothèses confrontées au corpus complet des
  mesures ; une seule survit). Un son armé transport arrêté n'a pas de
  frontière : il en prend une à la **première frame qui voit le transport
  rouler**. Cette frame est en retard d'une frame, et la frontière était
  quantifiée depuis le beat tel qu'il se lisait **à cet instant** — la cible
  était donc « là où j'ai regardé ». Tout l'aval mesurait ensuite son propre
  retard contre cette cible et trouvait **zéro**, par construction. Le lancement
  ne pouvait pas percevoir qu'il était en retard, la compensation n'avait rien à
  compenser, et **tirer en avance ne pouvait rien y faire** : avec la cible
  égale à maintenant, « tirer avant la cible » est déjà vrai. C'est ce qui
  survivait à tous les correctifs précédents.
  Or le transport ne démarre pas là où on l'a remarqué : il démarre **au
  curseur**, ce qui est connaissable *avant* le fait. Le curseur est donc
  mémorisé à chaque frame tant que l'horloge est arrêtée, et la première frame
  qui roule quantifie depuis **lui**. La frontière tombe alors dans le passé de
  la durée exacte du délai de constat, `elapsed` le rapporte comme un vrai
  retard positif, et le son saute d'autant dans lui-même pour rester en phase.
  Ce à quoi l'arithmétique servait depuis le début.
  Gardé : si la position de lecture ne suit pas plausiblement le curseur (moins
  d'une demi-seconde derrière), on retombe sur « maintenant ». Et `OFF_MAX`
  passe à 250 ms, parce qu'un retard honnête peut désormais dépasser une frame
  et que sauter d'autant est la bonne réponse, pas une raison de douter.
- [x] **Ce que l'analyse a aussi établi, et qui n'est PAS du code.** Le corpus
  se lit en quatre termes qui s'empilent, et le plus gros est le montage de
  mesure : REAPER décale une prise de la latence que le **pilote déclare**, et
  ASIO4All en enveloppant du WDM/KS sous-déclare massivement (4,3 ms annoncés
  pour un aller-retour réel de 150 ms et plus). D'où l'inversion : DirectSound
  annonce 255 ms et il reste 40-67 ms, ASIO4All annonce 4 ms et il reste
  150-180 ms ; d'où le fait qu'un buffer plus gros donne **moins** de retard ;
  d'où la dépendance à la mesure du morceau où l'on enregistre. Le « MIDI à
  0 ms » a été mesuré sur **DirectSound** — il n'innocente donc pas ASIO4All.
  Le test décisif, sans code : enregistrer dans la même prise un item ordinaire
  posé sur la barre, un clip MIDI, et une case audio. Les trois décalés
  pareillement = c'est le montage. Item et MIDI sur la ligne, case en retard =
  c'est nous, et l'écart entre le premier et le troisième transitoire est la
  seule mesure immunisée contre le pilote.
- [x] **Une sonde de lancement** (icône de pouls, barre du haut). Chaque
  lancement journalise : où le transport a **réellement** démarré et de combien
  on l'a remarqué en retard, les deux horloges, chaque terme de l'offset, puis à
  +1 et +10 frames l'**ERREUR DE DÉPART** — mesurée sans croire aucun de nos
  calculs : `D_POSITION` contre `(maintenant − frontière) × taux`. Et le zéro de
  la boucle en temps projet, directement comparable à la règle de REAPER.
  Éteinte, elle coûte un test booléen par frame.
- [x] **LE RELEVÉ PAR BUFFER TRANCHE : le retard suit la FRAME, pas le bloc.**
  Même machine, même fichier, même barre : ASIO 64 → 182 ms, 128 → 63, 256 →
  50, 512 → 30, 1024 → 30, DirectSound → 62. Et surtout, **un kick MIDI routé
  dans une piste et enregistré en audio : 1 ms.** Le chemin d'enregistrement
  est donc propre — l'hypothèse du montage de mesure tombe entièrement, et la
  cible est 1 ms.
  Réduire le buffer audio n'accélère rien, ça ralentit : plus de rappels par
  seconde, une machine plus près du bord, et une boucle defer qui traîne. Le
  plancher à 30 ms est **une frame**. Donc le lead cesse d'être une constante
  devinée et devient **la frame elle-même, mesurée** (moyenne glissante,
  plancher à 45 ms, plafond à 150 ms parce qu'il est joué depuis la queue de la
  boucle : un huitième de seconde de queue est encore une boucle, une
  demi-seconde est un autre son). Au-delà du plafond, le lancement est
  simplement en retard et `off` le fait sauter en phase — ça coûte l'attaque,
  jamais la grille.
- [x] **LES POSITIONS N'ÉTAIENT PAS DANS LA BONNE UNITÉ — la cause exacte.**
  La sonde a mesuré la **pente** au lieu du départ, et c'est elle qui parle :
  l'erreur au départ valait −1 à +11 ms, l'erreur à dix frames −17 à −157 ms.
  Une erreur qui grandit n'est pas un départ raté, c'est une **vitesse**. Or
  entre les deux points, sur les trois relevés où la machine tient, `D_POSITION`
  avance **exactement autant que le temps réel** — 0,2773 s de tête pour
  0,2773 s d'horloge, à quatre décimales, alors que le taux demandé est 1,0667.
  Le rapport n'est pas approximatif : il est 1,0000.
  `D_LENGTH = 4,2857` pour une source de 4,5714 s à 1,0667 tranche : **un aperçu
  compte les secondes qu'il a PASSÉ À JOUER, pas celles du fichier qu'il lit.**
  Toute position remise à un aperçu est donc du **temps réel**, et le taux n'a
  rien à y faire. Il était dans les trois : `audioStart` (`off × rt`),
  `lockPhase` (`(e+pdc) × rt`), `reanchor` (`pos ÷ rt`) — chacun multipliant par
  le taux ce qu'il fallait laisser tel quel. **Chaque offset était donc rt fois
  trop grand** : 6 % à 112 BPM, quatre fois à 400 BPM contre une boucle à 100.
  C'est la forme exacte du couple 220 ms / 460 ms mesuré à 170 et 400 BPM, que
  j'avais attribué à l'ouverture du fichier — le symptôme avait rétréci parce
  que `e` avait rétréci, le facteur était resté.
  Une seule longueur désormais, `a.plen = source ÷ taux`, et une seule unité
  partout : la seconde.
- [x] **Le demi-bloc s'annulait avec sa propre référence.** Il compensait le
  fait qu'un aperçu est ramassé au bloc SUIVANT — mais la référence à laquelle
  on l'ajoutait est `GetPlayPosition2`, qui **est** ce bloc suivant. Ajouter le
  bloc à lui-même mettait chaque lancement d'un demi-bloc en avance : +10,7 ms
  sur un buffer de 1024, exactement ce que la sonde relit.
- [x] **Et une chose qui n'est pas du code : à 64 échantillons, l'aperçu est
  affamé.** La vitesse de lecture mesurée y tombe à **0,53×** le temps réel
  (1,0000× à 1024, sur les deux pilotes), et la frame passe de 32 à 74 ms. Ce
  buffer n'est pas utilisable sur cette machine, et aucun correctif de lancement
  ne le rendra utilisable. La sonde le dit maintenant en toutes lettres.
- [x] **Le lancement est exact, et la sonde le prouve.** Relevé à 1024 :
  `+1 F START ERROR = +0.0ms (loop zero at 8.5714, boundary 8.5714)`. Zéro de la
  boucle et frontière au même instant, sur la timeline du projet, à la quatrième
  décimale. Le calage n'est plus la question.
- [x] **Ce qui reste est une FAMINE, pas un calage.** À 64 échantillons la
  vitesse de lecture mesurée est **0,54×** le temps réel : l'aperçu joue à
  moitié vitesse parce que le fil audio ne peut pas le nourrir. À 1024 elle est
  à 1,0000×. Deux des trois relevés (et toute la campagne précédente) étaient à
  64 — donc « le même ressenti » se juge, pour l'instant, sur un aperçu qui ne
  tourne pas en temps réel. La sonde le crie maintenant en toutes lettres
  (`*** STARVED ***`) pour que ce ne soit plus jamais confondu avec un défaut de
  calage, et le second échantillon passe de 10 frames à **2 secondes** : sur un
  tiers de seconde, la granularité de bloc de `D_POSITION` vaut 6 % de la
  réponse et se lit comme une dérive qui n'existe pas.
