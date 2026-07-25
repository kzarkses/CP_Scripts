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

1. **Rail** dans le toolkit, puis Session → Sampler → Editor.
2. **Icônes** : convertisseur SVG + pack Lucide + toggles à icônes.
3. **Mixer minimal** Session (vol/mute/solo) + couleur de clip.
4. **CP_Looper en step sequencer**.
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
