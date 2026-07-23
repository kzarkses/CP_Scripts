# Système de design CP — étude des références et tokens

> Compagnon de `ANALYSE_Design.md` (qui regarde l'usage/les ponts). Celui-ci
> regarde le **langage visuel** : ce que font les meilleures interfaces du
> domaine, comment, et ce qu'on en adopte dans CP_Toolkit — sous la
> contrainte qui prime tout : **PC 2005, zéro allocation par frame,
> perf avant esthétique**.
>
> Rédigé le 2026-07-23 (chantier B de la refonte). La première tranche est
> DÉJÀ implémentée — voir §5.

---

## 1. Ce que font les références (et pourquoi ça marche)

**Ableton Live 12** — la référence que Cédric a pointée (capture du 23/07).
- **La couleur SIGNIFIE.** Fond quasi neutre (gris chauds), et chaque teinte
  vive est un message : cyan = clips/sélection, rose/magenta = génération et
  actions "chaudes", orange = enregistrement, jaune = warning. Jamais de
  couleur décorative. Les surfaces neutres laissent les clips porter la
  couleur.
- **Arrondis hiérarchisés.** Boutons et toggles doucement arrondis (~3-4 px),
  **dropdowns et champs plus carrés** (~2 px), les panneaux le sont à peine.
  L'arrondi dit "cliquable".
- **Knobs ultra-minimalistes** : un arc fin + une aiguille, pas de skeuomorphe.
  L'info (valeur, unité) est DANS le champ voisin, pas autour du knob.
- **Bold + anticrénelé partout** : la typo est petite mais grasse, tout trait
  diagonal/courbe est lissé. C'est l'AA qui fait le "fini", plus que tout.
- **Densité** : lignes de 17-20 px, padding minimal, mais UNE hiérarchie de
  section très claire (headers sombres, séparation par fond, pas par bordure).

**Bitwig Studio** — le maximaliste discipliné.
- Tokens stricts : une échelle d'espacement, des pills (boutons capsule) pour
  les toggles, du rounding plus marqué qu'Ableton (~5-6 px).
- La modulation est colorée par SOURCE (chaque modulateur a sa teinte) — à
  garder en tête pour ModJSFX quand les sources se multiplieront.

**FL Studio** — le contraste maximal, arrondis plus forts, gradients. Trop
décoratif pour nous, mais leur leçon tient : les zones de travail (playlist,
piano roll) restent PLATES et sombres, seule la chrome est riche.

**Vital / u-he** — les plugins : fond très sombre, knobs = arcs fins avec
la valeur au centre, labels caption au-dessous, TOUT est AA. Vital prouve
qu'un design 100 % flat + arcs peut porter un instrument entier.

**Synthèse portable chez nous** : neutres chauds + accents sémantiques,
arrondi hiérarchisé (bouton > champ > panneau), AA généralisé, knobs
arc-fin, densité par tokens.

## 2. Les tokens (l'API du design)

Déjà dans `Theme.lua` (et c'est leur rôle qui change : ils deviennent le
SEUL endroit où le look se décide) :

| Token | Valeur | Rôle |
|---|---|---|
| `rounding` | 4 | boutons, toggles — "cliquable" |
| `rounding_small` | 3 | champs, sliders, combos, chips, tabs — "éditable" |
| `rounding_large` | 6 | panneaux, popups (réservé, pas encore appliqué) |
| `accent` | bleu | LA couleur d'action/sélection |
| `accent_dim/danger/bypass` | | sémantique existante à étendre (voir §4) |
| `button_height/row_h/chip_h/pad_*/gap_*` | | densité — un preset "compact" = ces tokens réduits, rien d'autre |

Règle : **une app n'invente jamais un rayon, une hauteur ou une couleur** —
elle nomme un token. C'est ça qui évite la dette dont parlait Cédric : le
restyle d'hier soir a touché UN fichier (Widgets.lua), pas quatre apps.

## 3. La technique (pourquoi c'est gratuit sur un PC de 2005)

gfx n'a **pas** de rounded-rect plein ni d'AA sur les formes pleines. Deux
outils dans Core :

1. **`Core.DrawRoundRectFilled`** — composition 3 slabs clippés + 4 disques
   AA (`gfx.circle` est anticrénelé nativement). ~7 primitives au lieu
   d'une : négligeable (le rasterizer gfx est en C, le coût réel d'une frame
   est ailleurs — textes et blits). Garde-fous : rayon < 2 → rect simple
   (thème legacy = rendu à l'identique), alpha < 1 → rect simple (le
   recouvrement slab/disque double-blenderait en translucide).
2. **Buffers bakés** (le pattern existant des fonds de knobs) : pour ce qui
   coûte VRAIMENT (arcs multiples, dégradés, coins à grand rayon), on
   dessine une fois hors-écran par (taille, couleurs) et on blitte. C'est la
   réserve de perf si un profil montre que la composition pèse — pas avant.

L'AA "généralisé" est donc : cercles/arcs/roundrect natifs AA (déjà le cas),
formes composées via disques AA, et le reste (rects, lignes verticales/
horizontales) n'a pas besoin d'AA. Les diagonales (`gfx.line` AA) le sont.

## 4. Prochaines tranches (dans l'ordre de valeur)

1. **Palette sémantique étendue** : `play` (vert), `record` (orange/rouge),
   `mod` (teinte modulation) — aujourd'hui les apps composent ces couleurs à
   la main (le Looper a ses verts/rouges locaux). Les remonter en tokens.
2. **Knob v2** : arc plus fin, aiguille optionnelle, valeur au centre en
   mono — le knob actuel est déjà arc-based, c'est un réglage de dessin,
   pas une refonte.
3. **Preset densité "compact"** : un jeu de tokens réduits (row_h 18,
   button_height 20, paddings 3/6) activable par thème.
4. **Headers borderless** (CP_Color le prouve) : chrome custom généralisé —
   chantier séparé, js_ReaScriptAPI.
5. **Maquettes HTML** ("claude design") : itérer la palette et les
   proportions avec Cédric dans le navigateur avant de toucher aux tokens —
   la boucle rapide qui remplace "recharge le script et regarde".

## 5. Ce qui est déjà livré (2026-07-23 soir)

- `Core.DrawRoundRectFilled` + `strokeRound`/`fillRound` dans Widgets.
- Tokens `rounding/rounding_small/rounding_large` (défauts 4/3/6, scalés
  DPI, persistés/chargés par le système de thème ; un thème sauvegardé
  ancien hérite des nouveaux défauts, `rounding = 0` sauvegardé est
  respecté = opt-out carré).
- Widgets arrondis via le toolkit (AUCUNE app modifiée) : Button,
  ToggleButton, Checkbox, Slider (piste + remplissage + poignée + boîte
  d'édition), Combo, TabBar, Tooltip, NumberInput, TextEdit, InputText,
  ProgressBar, RangeSlider, ValueRangeSlider. Le style "windows" (bevel)
  reste carré — deux époques, jamais combinées.
- Les popups/listes restent carrés à dessein (lisibilité, et c'est le choix
  Ableton pour les menus).
