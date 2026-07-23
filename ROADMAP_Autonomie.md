# ROADMAP — todo list du 2026-07-23

Liste donnée par Cédric avant une journée d'autonomie complète, avec les
verdicts techniques discutés. Complète `ANALYSE_Ecosysteme.md` (§9, le plan
moteur) et `ANALYSE_Interactions.md` (ponts + quick wins). Les cases se
cochent au fil des commits.

Règles du jour : finir l'engine d'abord (8b, 9), n'exécuter que ce qui est
sûr, Meta Mixer interdit, l'utilisateur teste tout lui-même.

---

## 1. LOOPER / EDITOR

- [ ] **Parité éditeur Looper ↔ CP_Editor.** Roll/RollUI sont déjà partagés :
  la parité = câblage côté hôte Looper + ergonomie. Base : entendre la note
  touchée, drum mode (via `CP_Engine/Rows.lua` partagé, avec le fix du
  group-move en delta de ligne — le bug existe aussi dans CP_Editor.lua:1661).
- [ ] **Passe raccourcis.** Inventaire des raccourcis/workflows de l'éditeur
  MIDI natif REAPER + comparatif ténors (Ableton/FL/Bitwig), intégration du
  socle dans RollUI → les deux hôtes en profitent d'un coup.
- [ ] **Session view à la Ableton** — GRAND CHANTIER. **DÉCISIONS DU
  2026-07-23** : (a) chantier 10 ACTÉ — CP_Editor devient l'éditeur universel
  qui change de focus selon ce qu'on ouvre (media item / loop MIDI / loop
  audio) ; les fondations du focus-switching peuvent se poser dès aujourd'hui
  (`Bus.Send("editor:open", clip)` existe, Clip porte audio et MIDI).
  (b) Une **spec design** est rédigée aujourd'hui (`ANALYSE_SessionView.md`,
  zéro code) : grille de clips CPC1 vs paradigme profondeur/subprojects de
  `ROADMAP_CPStudio.md` (la lignée ancienne avait DÉJÀ une session view V0.7 —
  à miner au niveau design, sans lire le code Meta Mixer), mapping pistes
  looper↔REAPER, plan par étapes. On décide dessus au retour de Cédric.
  Le code de la session view elle-même attend cette décision.

## 2. MOD

État des lieux (vérifié dans le code) : ModLFO est DÉJÀ l'architecture cible.
Les banques sont des JSFX purs (`ModJSFX.writeBankFile`), la modulation passe
par les parameter links natifs (`plink` + `mod.baseline`) → résolution audio,
fonctionne sans script ouvert ; le panneau Lua n'est qu'une télécommande.

- [ ] **Move `ModJSFX` → `CP_Engine/`** (le vrai reste du chantier
  "standalone"). **DÉCISION 2026-07-23 : attend le retour de Cédric** — à
  faire en une seule fois avec la spec Bitwig-grade (slew, courbes, one-shot,
  re-sync, LFO→LFO) de ANALYSE_Interactions.
- [ ] **Moduler les modulateurs** (LFO → depth/base/freq d'un autre LFO) :
  faisable — les params d'un slot sont des sliders JSFX, donc des cibles
  plink comme les autres. Travail = exposer les sorties de slots comme
  sources + affordance UI.
- [ ] **DnD vers VST tiers** : verdict honnête — on sait identifier la
  *fenêtre* du plugin sous la souris au relâchement (js_ReaScriptAPI), pas
  le *knob* dans une GUI étrangère (personne ne peut, Vital drop dans sa
  propre GUI). UX atteignable : drag depuis un slot → drop sur la fenêtre du
  plugin → ce FX passe en "capture" → premier paramètre touché = lié.
- [x] **Clic sur le nom du paramètre dans le panneau pour le sélectionner**
  (fait aujourd'hui si tout va bien — coût S).

## 3. MEDIA EXPLORER

- [ ] **Préécoute via une piste spécifique** : `CF_Preview_SetOutputTrack`
  (SWS, vérifié dispo) → la préécoute traverse la chaîne FX de la piste
  choisie. Coût S. Aujourd'hui.

## 4. UI (chantier transverse, ATTEND une session de design)

- Migration vers un style knob/boutons, flat arrondi chaleureux et moderne,
  suite d'icônes maison, anticrénelage quand c'est gratuit.
  **Perf et ergonomie AVANT esthétique** (PC 2005, zéro alloc par frame).
- Header global "borderless" sans barre native Windows — CP_Color prouve que
  c'est faisable (js_ReaScriptAPI).

## 5. SAMPLER

- [ ] **Plusieurs bus kit** : généraliser les marques Tracks (id de kit dans
  la marque / P_EXT) + sélecteur UI. Aujourd'hui.
- [ ] **Inst indépendant du drum, multi-instances ?** Recommandation : script
  léger séparé partageant `Kit` plutôt que multi-instance du même script gfx
  (collisions d'état persisté). Format à trancher ensemble.
- [ ] **Tune sans changer la longueur** : RS5K est resample-only. Deux voies :
  ReaPitch inséré sur la piste du pad (temps réel, élastique) + le bake du
  chantier 9 pour la version rendue. ReaPitch aujourd'hui.
- [ ] **Handles fade-in/fade-out + visu ADSR sur la preview**, manipulation
  de l'enveloppe directement sur la forme d'onde. Aujourd'hui.
- [ ] **BUG : premier hit avec ADSR, itérations de loop brutes.** Cohérent
  avec l'enveloppe RS5K appliquée au note-on et pas à chaque bouclage, mais
  vérifier ce que NOUS écrivons (LOOP/OBEY/retrigger) avant de conclure.
  Investigation en priorité.

## 6. MISC

- [ ] **DnD arrangeur → Looper/Sampler** : par capture au relâchement — on
  surveille la souris (JS API) pendant le drag natif ; relâchement au-dessus
  de notre fenêtre → lire la sélection d'items → Clip (audio : path/offs/len ;
  MIDI : notes via MIDI_GetNote). Le scroll de bord d'arrangeur est cosmétique,
  l'item ne quitte jamais REAPER. Coût M.
- [ ] **Looper → item MIDI dans l'arrangeur** (quick-win n°1 de l'analyse,
  coût S) : la jam ne meurt plus dans le looper.

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
