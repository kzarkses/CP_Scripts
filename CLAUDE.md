# CP_Scripts — ce qu'un agent doit savoir avant de toucher a quoi que ce soit

Suite de scripts REAPER (Lua) + une extension C++ (`CP_Native`). Auteur :
Cedric Pamalio. Ce fichier est le point d'entree ; il ne remplace aucun des
documents qu'il designe, il dit dans quel ordre les lire.

---

## 1. Ou ce depot doit vivre

Le depot **EST** le dossier de scripts de REAPER :

```
%APPDATA%\REAPER\Scripts\CP_Scripts
```

Ailleurs, rien ne marche : les modules se chargent par
`reaper.GetResourcePath() .. "/Scripts/CP_Scripts/..."`.

**Installation complete, y compris la construction du binaire :
[INSTALL.md](INSTALL.md).** Ne pas la redecrire ailleurs.

---

## 2. Par ou commencer, selon ce qu'on cherche

| question | document |
|---|---|
| **qu'est-ce qu'on fait ensuite** | `ROADMAP_Chantiers.md` — **LE PLAN. Commencer ici.** |
| ce qui a ete fait, session par session, et pourquoi | `ROADMAP_Autonomie.md` — le JOURNAL |
| ou on en est face a Ableton et FL, ce qu'on refuse | `ANALYSE_Confrontation.md` — le RAISONNEMENT |
| comment appeler le moteur natif | `API_Moteur.md` — le contrat d'ABI |
| pourquoi le moteur est fait comme ca | `ARCHI_MoteurNatif.md` |
| ce que font les autres DAW, verifie sur leurs manuels | `Recherche/` (+ son `README.md`) |

Confondre les trois premiers fait perdre une heure a chaque reprise. Une case
cochee dans `ROADMAP_Chantiers.md` veut dire **ecrit et compile**, jamais
**entendu** — c'est Cedric qui ecoute.

---

## 3. Les regles non negociables

**La performance est la priorite absolue. La cible est un PC de 2005.**
Zero allocation par frame dans les chemins de dessin, zero allocation dans le
fil audio. Le harnais (`CP_Native/build_test.cmd`) le **prouve** cote coeur et
doit continuer a le prouver.

**Langue.** Cedric ecrit en francais. **Le texte d'interface reste en
anglais.** Les commentaires de code sont en francais **sans accents** (les
polices de REAPER ne les rendent pas partout).

**Commits.** Atomiques, message en francais **sans accents**, un titre qui dit
ce qui a change *et pourquoi ca comptait*. Toujours par fichier :

```sh
git commit -F <fichier>
```

Jamais un here-string PowerShell : il a deja corrompu un message. Terminer le
corps par :

```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

**Ne jamais creer `ROADMAP.md`** — il est dans `.gitignore` et sert a autre
chose. Les feuilles de route s'appellent `ROADMAP_<sujet>.md`.

**Les `.cmd` doivent rester en CRLF.** `cmd.exe` mange le debut de chaque ligne
d'un fichier en LF. Les editer en binaire, ou verifier apres coup.

**Ne jamais commiter de binaire.** `CP_Native/build/` est ignore : le moteur se
**reconstruit**, il ne se transporte pas.

**Deliberement non commite** : `CP_Config/*.lua` (les reglages de fenetres de
Cedric, pas du code) et `FX Constellation/Data/*.dat`. Ne pas les ajouter a un
commit « pour faire propre ».

**Abandonnes, ne pas y toucher** : `CP_Studio`, `MetaMixer`.

---

## 4. Comment travailler avec Cedric

- **Il teste tout lui-meme.** Ne jamais lui dire de tester, ne jamais classer
  « non teste » comme un risque : c'est l'etat normal de tout ce qu'on livre.
- **« Discutons » veut dire une reponse en prose**, avec UNE recommandation et
  l'alternative qu'on ecarte — pas un panneau de choix multiples.
- **Autonomie complete veut dire aller au bout.** Pas de point d'etape pour
  faire valider entre deux etapes.
- Pas d'entree de notes au clavier QWERTY/AZERTY : le clavier virtuel de REAPER
  couvre le besoin, et c'est tranche.

---

## 5. Les pieges qui coutent une soiree

Ils sont tous ecrits **au-dessus du code concerne**. Les relire avant de
« corriger » quoi que ce soit dans ces zones.

**`Loop.SetMute` (CP_Engine/Loop.lua).** Ne PAS y brancher les voix pour
corriger « une lane mutee ne tait pas sa case audio ». CP_Session utilise le
meme mute pour empecher la note unique d'une case audio de partir dans
l'instrument de la colonne : taire la voix rendrait **toute** case audio
silencieuse.

**Ne jamais restructurer une chaine d'effets pendant un geste.** Un bouton
qu'on tourne appelle son handler plusieurs fois par seconde ; s'il ajoute ou
deplace un effet, la chaine change sous lui. Un index encode de conteneur
contient le **nombre d'effets de la chaine** et devient faux au milieu de
l'operation. Ca a coute une journee le 2026-08-01, deux fois. Un bouton ecrit
un PARAMETRE, jamais une structure.

**Un garde-fou doit verifier le RESULTAT, pas le geste.** La migration du kit
refusait de supprimer une piste dont le contenu n'avait pas ete deplace — et
elle a supprime des pistes dont les echantillons n'avaient pas suivi le
deplacement. Elle controlait que le geste avait eu lieu, pas qu'il avait
marche.

**`GetPlayPosition` contre `GetPlayPosition2`.** Le premier est
« ce-qu'on-entend » (compense de la latence de sortie), le second « le bloc en
cours de traitement ». Le moteur compte les echantillons **produits** : il
s'ancre sur le second. Apparier le mauvais a coute 28 ms de retard constant.

**`gmem_attach` est GLOBAL au script Lua.** Il ne rend pas une poignee : il
choisit quel bloc nomme *tous* les `gmem_read`/`gmem_write` du script touchent,
jusqu'au prochain appel. `Tempo.Poll()` se rebranche sur `CP_Tempo` a **chaque
passage de boucle** ; toute autre module qui lit gmem doit donc **reselectionner
son bloc avant chaque acces** (`KitFX` le fait, `Loop.Reattach` existe pour ca).
Attacher une fois a l'initialisation ne vaut que jusqu'au premier passage.
Le symptome est le pire qui soit : ca marche par intermittence, selon l'ordre
des appels dans une frame. Le piege etait ecrit dans l'en-tete de `Tempo.lua`
depuis la session 20 — « the trap is armed for the one that will » — et il a
quand meme coute trois soirees, parce qu'il etait documente a cote de celui qui
le pose et non a cote de celui qui tombe dedans.

**Une mesure ne doit pas abimer ce qu'elle mesure.** Le premier auto-test du
sampler ecrivait une valeur connue dans cinq parametres et s'en allait : il a
mis un pad a -30 dB et -12,8 demi-tons, et on a cherche une heure pourquoi plus
rien ne sonnait. Il repose ce qu'il a pris.

**Les parametres VST Cockos sont normalises.** `TrackFX_GetParam` sur un RS5K
ou un ReaPitch rend 0..1, jamais des ms, des dB ou des demi-tons. Les unites
reelles n'existent qu'a travers l'API de formatage (`plainOf` / `plainSet`).

**La vitesse de lecture (playrate) n'est pas un facteur de tempo.** Le tempo ne
bouge pas ; c'est la ligne de temps entiere qui defile plus vite. Trois
consequences distinctes, a tenir separees — voir `ARCHI_MoteurNatif.md`.

---

## 6. Verifier qu'on n'a rien casse

```sh
cd CP_Native
build_test.cmd          # le coeur, hors REAPER : assertions + zero allocation
build_dll.cmd           # l'extension, REAPER FERME, installe dans UserPlugins
```

Depuis REAPER, la zone de statut de CP_Session doit afficher la version de
l'ABI (`engine native 1.8 · cells: voices`). Elle y est **expres** : la question
qu'on se pose vraiment est « REAPER a-t-il repris la DLL que je viens de
construire ».

Sans l'extension, rien ne plante et rien ne s'efface — les fenetres le
**disent** (`cells: silent`, `pads: RS5K/broadcast`), et `Loop.SaveState` refuse
d'ecrire, precisement pour que l'absence du binaire ne coute pas un projet.
