# Recherche — la matière brute du 2026-08-01

Dix analyses produites par des agents en parallèle le 1er août 2026, après le
premier vrai test d'écoute de la suite complète. Elles sont ici **telles
qu'elles ont été rendues**, sans réécriture.

`ANALYSE_Confrontation.md` (à la racine) en est la synthèse. Ce dossier est ce
sur quoi elle s'appuie — on n'y revient pas pour se faire une opinion, on y
revient pour vérifier une affirmation ou pour retrouver une source.

## Ce qu'il y a dedans

### Référence externe — ce que font les autres, vérifié sur leurs manuels

| Fichier | Contenu |
|---|---|
| `REFERENCE_Ableton_SessionView.md` | Session View de Live 11/12 : grille, modes de lancement, quantification par clip, Follow Actions, propriétés de clip, enregistrement, rapport Session ↔ Arrangement, et les micro-comportements qui la rendent jouable |
| `REFERENCE_FL_Studio.md` | Le modèle pattern contre le modèle clip-par-piste, le Performance Mode de la Playlist, le piano roll et ses outils, le channel sampler, et ce que FL fait que personne d'autre ne fait |
| `REFERENCE_Editeurs_MIDI.md` | Les éditeurs de clip chez Ableton, FL et **REAPER lui-même** — avec la question qui compte ici : qu'est-ce qui vaut la peine d'être écrit plutôt que d'appeler l'éditeur natif |

Chaque affirmation y porte sa marque : **« vérifié (URL) »** ou **« de
mémoire »**. Les URL sont dans le corps des documents. C'est la seule partie de
ce dossier qui ne périme pas avec le code — elle périme avec les versions des
logiciels concernés (Live 12, FL 21/24 au moment de l'écriture).

### Inventaire — ce que notre code fait réellement

`INVENTAIRE_CP_Session.md`, `INVENTAIRE_CP_Editor.md`,
`INVENTAIRE_Interactions.md`.

Fonction par fonction, avec `fichier:ligne`. **Ces trois-là périment vite** :
les numéros de ligne étaient justes le 1er août au matin et ne le sont déjà
plus. On les garde pour la structure et pour la liste de ce qui est déclaré
mais mort, pas pour les adresses.

### Défauts — ce qui est là et mal fait

`DEFAUTS_Balayage.md` (classé par gravité : mauvais son ou perte de données,
puis ce qui trompe l'utilisateur, puis les pièges de performance, puis le code
mort) et `DEFAUTS_Trous_de_logique.md` (les collisions de vocabulaire, ce qui
n'a pas de propriétaire, et des enchaînements concrets vers un état absurde).

**C'est la partie la plus actionnable du dossier.** `ROADMAP_Chantiers.md` en
reprend les entrées et suit leur état ; quand les deux se contredisent, c'est
la roadmap qui a raison, parce qu'elle est tenue à jour.

### Confrontation — nous, face à eux

`CONFRONTATION_CP_Session.md` et `CONFRONTATION_CP_Editor.md` : ce qui manque et
qui compte, ce qui manque et qu'il ne faut **pas** faire, ce qui est déjà bon —
y compris ce qui est meilleur qu'Ableton et qu'une refonte d'interface perdrait
sans s'en apercevoir.

## Comment lire ces documents

Ils ont été écrits par des agents distincts qui ne se voyaient pas, puis — pour
les six diagnostics de bug de la même journée, qui ne sont pas dans ce dossier —
réfutés par une seconde passe adverse. **Ils se contredisent par endroits.**
Quand c'est le cas, `ANALYSE_Confrontation.md` a tranché et dit pourquoi.

Deux réserves à garder en tête :

- une affirmation marquée « de mémoire » sur Ableton ou FL n'a **pas** été
  vérifiée, et plusieurs recommandations en dépendent ;
- la synthèse automatique a été coupée par une limite de session. Ce qui est à
  la racine est ma synthèse manuelle de ces dix textes, pas celle d'un agent.
