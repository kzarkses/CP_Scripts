# Analyse design — les 4 applications face aux ténors

> Compagnon de [ANALYSE_Ecosysteme.md](ANALYSE_Ecosysteme.md). Celui-ci regarde
> l'**usage** : ce que chaque app fait bien, ce que font les références du genre,
> et surtout ce qui manque pour que l'ensemble forme une chaîne complète.
>
> Les références ne sont pas un cahier des charges. Elles servent à repérer les
> manques structurels, pas à copier. La direction propre est en §6.
>
> Rédigé le 2026-07-21. Meta Mixer hors périmètre. La lignée ReaImGui est vouée
> à disparaître (cf. « carrière de pièces », ANALYSE_Ecosysteme §8).

---

## 1. Le test qui compte : la boucle créative est-elle fermée ?

Un écosystème de création sonore n'est pas une somme d'outils, c'est un **cycle**.
Le bon test n'est pas « est-ce que chaque app est complète » mais « est-ce que la
matière circule et revient enrichie ».

```
   ┌──────────────────────────────────────────────────────┐
   │                                                      │
   ▼                                                      │
 TROUVER ──► FAÇONNER ──► INSTRUMENTALISER ──► JOUER ──► ARRANGER
 Explorer     Editor         Sampler           Looper     REAPER
```

État réel des ponts :

| Pont | Existe ? | Comment |
|---|---|---|
| Explorer → Sampler | ✅ | DragBus, drop sur un pad |
| Explorer → Arrangement | ✅ | drag fantôme, item réel qui suit la souris |
| Explorer → Editor | ✅ | ExtState `CP_Editor/open` |
| Sampler → Editor | ✅ | double-clic sur un pad |
| Editor → Sampler | ✅ | « To instrument », « Slices to pads », « Sel to pad » |
| Looper → Sampler | ✅ | routage de lane vers une piste d'instrument |
| **Editor → Explorer** | ❌ | **un son édité ne redevient jamais un fichier** |
| **Looper → Arrangement** | ❌ | les loops ne deviennent jamais des items |
| **Looper → Editor** | ❌ | on ne peut pas ouvrir une lane dans CP_Editor |

**Diagnostic central : la boucle est ouverte.** La matière entre, se transforme,
se joue — et ne ressort jamais comme *nouvelle matière*. Tout l'édition audio est
non destructive (propriétés de take), donc rien de ce qu'on fabrique ne devient un
fichier réutilisable. C'est ce qui distingue un ensemble d'outils d'un écosystème.

C'est aussi ce que font tous les ténors : Edison exporte et « drag region out »,
Ableton a Freeze & Flatten / Consolidate, Bitwig a Bounce in Place. Aucun ne
laisse la chaîne ouverte.

---

## 2. CP_MediaExplorer — la source

### Ce qui est déjà fort
Arbre inline FL avec pile d'ancêtres épinglée (personne ne fait ça), audition
< 50 ms par contrainte de conception explicite, recherche à tokens avec exclusion,
bootstrap sur les bases natives, collections colorées 1-7, chip plugins,
hot-swap (Q) et random (R) — deux gestes de sound design que la plupart des
navigateurs n'ont pas —, drag fantôme avec item réel.

Sur la qualité d'interaction, il est **au-dessus** du navigateur natif et tient la
comparaison avec les ténors.

### Ce que font les références
| Référence | Idée directrice |
|---|---|
| Ableton Live 12 | recherche par **similarité sonore**, preview calé au tempo du projet |
| Sononym, XO, Atlas | espace 2D de similarité — on navigue par *voisinage timbral*, pas par dossier |
| Splice / Loopcloud | **BPM et tonalité détectés** affichés sur chaque ligne, filtrables |
| Soundminer, Soundly | métadonnées descriptives (catégorie, description, bibliothèque), pas des chemins |
| Bitwig | filtrage à facettes en colonnes |

### Le manque qui compte
**Le BPM et la tonalité ne sont pas connus.** Le README l'admet : BPM lu dans le
nom de fichier ou deviné par `GetTempoMatchPlayRate`, pas d'analyse audio ; aucune
notion de tonalité. Pour un écosystème qui vise des boucles calées et un sampler
synchronisé, c'est un manque **fondation**, pas confort : le Sampler, le Looper et
l'Editor en dépendent tous.

Deuxième manque : les collections 1-7 sont un système de tags qui n'ose pas dire
son nom, mais elles ne portent pas de sens (couleur 3 = quoi ?) et ne survivent
pas au partage.

### Ce que je ferais
1. **Détection BPM + tonalité** à l'indexation, en tâche de fond budgétée (le
   modèle `IndexStep(budget)` existe déjà). Stockage dans un cache local, colonnes
   affichables, filtrables, et **exposé à tout l'écosystème** via `Engine`.
2. **Nommer les collections** — 7 tags libres au lieu de 7 couleurs muettes.
3. Similarité : intéressant mais coûteux et non fondateur. À garder pour plus tard.

---

## 3. CP_Sampler — l'instrument

### Ce qui est déjà fort
**Chaque pad est une vraie piste REAPER.** C'est l'atout structurel majeur de tout
l'écosystème et aucun ténor ne l'a : chaque pad hérite gratuitement d'une chaîne
FX complète, de sends, d'un meter, d'une tranche de mixette, d'automation et de la
capacité d'être enregistré. Ableton doit inventer les *chains* pour approcher ça.
S'ajoutent : bus MIDI dédié (avec la raison documentée — le feedback de dossier),
choke groups par JSFX généré, région start/end draggable sans écrire de fichiers
de slices, modes Drum/Instrument, presets de kit.

### Ce que font les références
| Référence | Idée directrice |
|---|---|
| Ableton Simpler | 3 modes : **Classic / One-Shot / Slice**, et **Warp** pour verrouiller au tempo |
| FL Slicex, Serato Sample | slicing par transitoires **dans le sampler**, pads auto-assignés |
| Battery 4, Kontakt | **couches de vélocité** et round-robin par cellule |
| Ableton Drum Rack | 8 **macros** sur le rack, chaînes par pad |
| Logic Drum Machine Designer | le pad *est* une piste (même intuition que CP) |
| Tous | un **filtre** par voix |

### Les manques qui comptent
1. **Aucune conscience du tempo.** Vérifié : zéro occurrence de tempo/bpm/playrate
   dans tout CP_Sampler. C'est le manque n°1 — il bloque les boucles calées, donc
   l'audio dans le Looper, donc la session view.
2. **Pas de mode Slice.** La capacité existe (détection de transitoires + « Slices
   to pads ») mais elle vit dans **CP_Editor**. Chez tous les ténors, slicer est
   un *mode du sampler*, pas un aller-retour vers un éditeur.
3. **Pas de filtre par pad** — alors que l'architecture piste-par-pad rend ça
   trivial (un JSFX sur la piste du pad). Occasion manquée, pas obstacle.
4. **Pas de couches de vélocité**, alors que `Kit.P` expose déjà `MINVEL`/`MAXVEL`
   et que plusieurs RS5K sur une même piste de pad suffiraient.

### Ce que je ferais
- **Sync tempo d'abord** : mode par pad `none | repitch | stretch`, alimenté par le
  BPM venu de l'Explorer. Réserve honnête : via RS5K le calage passe par le taux
  de lecture, donc la hauteur suit (effet vinyle) — c'est acceptable et souvent
  désirable ; le vrai stretch demandera le *bake*.
- **Rapatrier le slicing comme mode du Sampler**, l'Editor restant l'endroit où
  on affine.
- Filtre et couches de vélocité : gains réels, faibles risques, à faire ensuite.

---

## 4. CP_Editor — l'établi

### Ce qui est déjà fort
Côté MIDI, le piano roll est désormais au niveau après le benchmark 7 DAW :
transformations partagées, gammes, arpégiateur, euclidien, humanize reproductible.
Côté audio : zoom jusqu'à l'échantillon, sélection sur passage par zéro, normalize
en domaine source, détection de transitoires, poignées de fade réelles.

### Ce que font les références
| Référence | Idée directrice |
|---|---|
| Edison (FL) | éditeur **destructif** assumé, rendu vers fichier, « drag region out » |
| Ableton | **warp markers** — l'audio devient élastique et suit le tempo |
| Ableton, Serato Sample | **audio → MIDI** (batterie / mélodie / harmonie) |
| RX, Logic, Serato | vue **spectrale** |
| Melodyne | édition par note dans l'audio |
| Bitwig | Bounce in Place systématique |

### Les manques qui comptent
1. **Le bake.** Rien de ce qu'on fabrique ne devient un fichier. C'est *le* trou de
   la boucle (§1), et il est mono-cause : tout est propriété de take.
2. **Warp / stretch markers** : l'API REAPER les expose, l'UI n'existe pas, et
   `PitchStretch.lua` (12 algorithmes) est déjà écrit dans la lignée à démolir.
3. **Lanes de CC / automation** — le seul grand pan MIDI absent, et bien moins cher
   côté CP_Editor (le backend take écrit du vrai CC) que côté Looper (gmem ne
   stocke que des notes).
4. **Audio → MIDI**, au moins pour la batterie : la détection de transitoires
   existe déjà, donc « slices → notes MIDI » est presque gratuit et crée un pont
   **Editor → Looper** qui manque aujourd'hui.

### Ce que je ferais
Le bake en premier, parce qu'il débloque trois autres chantiers. Puis les lanes de
CC. Puis audio→MIDI batterie, qui est le meilleur rapport effet/effort de tout le
document.

---

## 5. CP_Looper — le performeur

### Ce qui est déjà fort
Le verrouillage de phase sur la grille de l'hôte : les boucles restent calées même
quand REAPER est esclave d'une horloge externe. C'est un choix d'architecture que
la session view d'Ableton, centrée sur son propre maître, ne fait pas. Pour du live
synchronisé à quelqu'un d'autre, c'est un avantage réel. S'ajoutent le routage par
lane sur canal MIDI, l'horloge Free/Follow, et l'éditeur inline à parité.

### Ce que font les références
| Référence | Idée directrice |
|---|---|
| Ableton Session View | **scènes** (une rangée lancée ensemble), **quantisation de lancement** par clip, **follow actions** |
| Ableton (Live 10+) | **Capture MIDI** — récupère ce que tu viens de jouer sans avoir armé |
| Boss RC-505, pédales | **overdub** — empiler dans une boucle existante |
| Maschine, Push | scènes + patterns, tout au doigt |
| Bitwig | clip launcher + arrangement, aller-retour libre |

### Les manques qui comptent
1. **Pas de scènes.** Il y a des lanes, pas de seconde dimension. C'est *le*
   concept de la session view : lancer un ensemble cohérent d'un geste.
2. **Pas de quantisation de lancement.** Un clip démarre immédiatement. La brique
   conceptuelle existe dans le ClipEngine abandonné (`pending_quantize`).
3. **Pas d'overdub** — on réenregistre une prise entière.
4. **Pas de persistance** — les loops vivent le temps de la session REAPER.
5. **Pas de retour vers l'arrangement.** Ce que tu joues ne devient jamais du
   matériel REAPER.
6. Pas de follow actions, pas d'undo interne, pas de mode drum, pas d'audio.

### Ce que je ferais
Persistance et quantisation de lancement d'abord (petits, structurants). Les
scènes ensuite, parce qu'elles changent le modèle de données et méritent d'être
décidées, pas bricolées. **Capture rétroactive** est le pari le plus intéressant :
le JSFX voit déjà passer toute l'entrée MIDI, il ne manque qu'un tampon glissant
— et en jam, c'est la fonctionnalité qui change la vie.

---

## 6. Synthèse : trois manques structurels, pas trente fonctionnalités

Tout ce qui précède se ramène à trois trous, et chacun est cité par plusieurs apps.

| # | Manque | Qui en dépend |
|---|---|---|
| **A** | **Le bake** (matière éditée → fichier) | Editor (destructif), Sampler (stretch vrai), Looper (audio, enregistrement), Explorer (la boucle se referme) |
| **B** | **Le contexte musical partagé** (tempo, grille, BPM/tonalité des sources) | Sampler (sync), Explorer (audition calée), Looper (quantisation), Editor (warp) |
| **C** | **Le retour vers l'arrangement** (loops → items) | Looper, et la crédibilité de tout l'ensemble |

Trois chantiers, pas trente. Le reste est du confort qui se posera dessus.

---

## 7. La direction propre — ce que je défendrais

Les ténors résolvent tous le même problème de la même façon : **un conteneur
propriétaire**. Le clip d'Ableton n'est pas un fichier, la cellule de Battery n'est
pas une piste, le pattern de Maschine n'est pas un item. Ils gagnent en cohérence
et perdent en ouverture.

CP a exactement l'inverse, et par accident heureux :

- un pad **est** une piste REAPER ;
- un clip édité **est** un item/take ;
- un kit **est** un dossier de pistes, sauvegardé dans le projet, annulable ;
- une lane **est** un routage MIDI réel.

**Direction proposée : « le projet est le document ».** Ne pas construire un
conteneur de session à la Ableton. Assumer que chaque objet CP est de l'état REAPER
natif, et que la valeur ajoutée est la **vue**, pas le format.

Conséquences concrètes, qui tranchent des choix :

- Une « session » n'est pas un fichier maison : c'est le projet (+ `P_EXT` pour ce
  qui n'a pas d'équivalent natif, comme les loops gmem).
- Le Clip (ANALYSE_Ecosysteme §4) est un **descripteur de vue**, pas un stockage :
  il pointe vers de l'état REAPER, il ne le remplace pas.
- Tout ce que l'écosystème fabrique doit pouvoir **sortir** en matériel REAPER
  standard — ce qui redit le manque A.
- L'utilisateur ne doit jamais se retrouver enfermé : les échappatoires actuelles
  (« Show RS5K UI », « Native editor », les pistes restent des pistes) sont une
  **caractéristique de conception**, à préserver explicitement.

C'est la seule direction où CP n'est pas un Ableton en moins bien, mais quelque
chose qu'Ableton ne peut pas faire.

---

## 8. Questions ouvertes — à trancher, pas à deviner

1. **Les scènes** : le Looper reste-t-il un rack de 4 lanes indépendantes (simple,
   live, proche d'une pédale) ou devient-il une grille clips × pistes (puissant,
   mais c'est un autre logiciel) ?
2. **Le slicing** : mode du Sampler, outil de l'Editor, ou les deux avec un modèle
   partagé ?
3. **Le bake** : écrivain WAV en Lua pur (contrôle total, travail réel) ou passage
   par les actions de rendu natives de REAPER (rapide, moins maîtrisé) ?
4. **BPM/tonalité** : analyse maison budgétée, ou se contenter des noms de fichiers
   et des tags MediaDB ?
