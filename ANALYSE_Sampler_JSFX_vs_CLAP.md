# L'échantillonneur : JSFX ou CLAP

Écrit le 2026-08-01, après avoir retiré le repli du kit sur une piste. Ce
document n'arbitre pas — il pose **les deux positions honnêtement**, avec ce
que chacune coûte, ce que chacune tue, et ce qu'il faut vérifier avant de
s'engager. Cédric tranche.

---

## Ce qui a rendu la question urgente

Deux accidents en une journée, et ils ont la même racine.

**Le pitch.** Transposer un pad sans changer sa durée demandait un ReaPitch par
pad. Un effet de plus dans une chaîne partagée, donc un conteneur par pad, donc
un déplacement d'effet — et ce déplacement se faisait sur le chemin d'**un
bouton qu'on tourne**, plusieurs fois par seconde. Chaque tour restructurait la
chaîne d'effets du projet ; la fenêtre se redessinait, un index encodé se
perdait, le tour d'après ajoutait un second ReaPitch.

**Le repli.** Faire tenir un kit sur une piste demandait de déplacer chaque RS5K
de sa piste vers la chaîne du kit. `TrackFX_CopyToTrack(..., is_move=true)` a
déplacé les instances — et les échantillons n'ont pas suivi. Le garde-fou
existait (« ne jamais supprimer une piste dont le contenu n'a pas bougé ») mais
il vérifiait le **déplacement**, pas le **son**.

**La racine commune** : tout paramètre d'instrument qui n'existe pas dans le
RS5K coûte un effet de plus dans une chaîne partagée, et une chaîne d'effets ne
se restructure pas pendant un geste. ADSR au-delà de ce que le RS5K offre,
zones de vélocité, choke sans JSFX, transposition à durée constante, sorties
séparées : tous butent sur la même chose. Ce n'est pas un défaut d'écriture,
c'est la limite du montage.

Dans un instrument à nous, ce sont des **paramètres**. On en tourne un, il
change. C'est tout l'écart, et il est structurel.

---

## Position A — un JSFX

### Ce qu'elle a pour elle

**Il reçoit du MIDI.** C'est *le* blocage identifié dans
`ROADMAP_Chantiers.md` § « La destination » : le moteur natif est un
`PCM_source`, il **produit** du MIDI et n'en **reçoit** pas, donc le jouer au
clavier passerait par Lua et une frame de defer (16 à 74 ms). Un JSFX vit dans
le fil audio ; `midirecv` est à l'échantillon. Le blocage ne se contourne pas,
il disparaît.

**Il voyage avec un `git pull`.** C'est du texte dans le dépôt. Pas de SDK, pas
de MSVC, pas de « ferme REAPER et relance le script ». Sur une machine neuve,
l'échantillonneur marche après un clone, sans rien construire — ce qui est
exactement la friction que `INSTALL.md` documente pour le moteur natif.

**Il supprime toute la classe de bug ci-dessus.** ADSR, choke à l'échantillon,
zones de vélocité, polyphonie par pad, tune, boucle, région, sorties séparées :
des paramètres, pas des effets qu'on empile. Plus de conteneur, plus de
déplacement, plus d'index encodé, plus de `Kit.Fold`, plus de migration.

**C'est déjà la forme qui marche ici.** `cp_kit_choke.jsfx` est généré par
`Kit.lua` depuis le premier jour, et c'est la seule pièce de l'échantillonneur
qui n'ait jamais posé de problème.

**Un kit = un effet = une piste**, donc l'objectif du chantier 2 est atteint
par construction, et le kit redevient une colonne de la Session sans rien de
particulier.

### Ce qu'elle coûte

**Une réécriture.** Allocateur de voix, lecture de la matière, enveloppes,
groupes de choke, mapping note→pad : environ 300 à 400 lignes d'EEL, à écrire
et à maintenir dans un langage qui n'a **aucun harnais de test**. Le cœur C++,
lui, en a 143 assertions et prouve zéro allocation dans le fil audio.

**Un plafond mémoire réel.** Un JSFX travaille dans un tableau plat. Des
one-shots de batterie tiennent large ; une boucle de trente secondes sur un pad,
non. Ce n'est pas le métier d'un pad — c'est celui d'une case de Session, que le
moteur natif joue déjà — mais la limite existe et il faut la connaître.

**Passer les chemins de Lua au JSFX n'est pas gratuit.** Un JSFX ne prend pas de
paramètre chaîne. Deux voies : `file_open` avec un chemin littéral **si REAPER
récent l'accepte** (à vérifier), ou un petit fichier texte que CP_Sampler écrit
et que le JSFX relit sur un signal. La seconde marche à coup sûr et reste plus
simple que le fan-out d'envois qu'on avait.

**gmem revient, peut-être.** Le dépôt l'a tué comme protocole en session 20, et
pour de bonnes raisons (deux copies d'une carte mémoire, une constante fausse
d'un côté ressemble à un bug de l'autre). Le réintroduire, même pour un signal,
doit être un choix conscient et écrit.

---

## Position B — un CLAP autour de `CP_Native/src/core`

### Ce qu'elle a pour elle

**Le cœur existe, il est testé, il est propre.** `src/core` a été écrit **sans
une seule ligne d'API REAPER** — c'est une règle du dossier, et le harnais le
compile et le teste hors REAPER. 143 assertions, zéro allocation dans le fil
audio, prouvé sous deux fils réels. L'emballer en CLAP est un travail
d'emballage.

**Aucun plafond mémoire, aucun bricolage de chemins.** Un plugin a une vraie
ABI : on lui passe ce qu'on veut, il alloue ce qu'il faut.

**Les sorties séparées viennent gratuitement.** Un plugin sort sur N paires
stéréo, et les conteneurs d'effets de REAPER 7 se punaisent sur une paire. Un
kit = une piste, un plugin, un conteneur par pad qui en veut un — et le fader,
le mute/solo et le VU par pad reviennent, qui sont exactement ce que le repli
faisait perdre.

**Ça sort de REAPER.** CLAP et VST3 marchent ailleurs. C'est la seule voie qui
ne soit pas un cul-de-sac.

### Ce qu'elle coûte

**Il faut construire.** Sur chaque machine, avec un compilateur et un SDK. C'est
précisément la friction de `INSTALL.md`, et elle s'appliquerait désormais à
l'échantillonneur — pas seulement au moteur de clips.

**La réutilisation est surestimée.** `src/core` est un moteur de **clips** : une
position, un taux, un gain, deux fondus linéaires, un rendez-vous à
l'échantillon. Un échantillonneur de batterie a besoin d'ADSR, de groupes de
choke, de couches de vélocité, d'un mapping note→pad. Rien de tout cela n'y est.
Ce qui se réutilise vraiment, c'est le vivier et le mélangeur de voix — utile,
mais loin du « c'est déjà écrit ».

**C'est plus long.** Un format de plugin, un hôte à satisfaire, une interface à
décider (celle du plugin, ou CP_Sampler qui le pilote), un cycle de compilation
à chaque essai.

---

## Ce qu'il faut vérifier avant de trancher — une soirée de sonde

C'est la méthode du dossier, et elle a déjà servi : `CP_TestMidiAt` a été écrit
pour répondre à « REAPER route-t-il le MIDI d'un aperçu de piste vers la chaîne
de cette piste » plutôt que d'en discuter. Elle a répondu oui, et elle est
devenue `CP_PortMidiAt`.

1. **`file_open` accepte-t-il un chemin littéral** dans un JSFX, sur la version
   de REAPER visée ? Sinon, quelle est la latence du passage par fichier texte ?
2. **Quel est le plafond mémoire réel** d'un JSFX sur cette machine, et combien
   de pads de deux secondes en stéréo y tiennent ?
3. **Un JSFX instrument tient-il 64 voix** au tampon de travail sans dépasser ce
   que le RS5K coûtait ? Le dossier mesure tout le reste en pourcentage du fil
   audio ; celui-ci ne fait pas exception.

Les trois premières réponses décident. Les deux premières ne concernent que la
position A ; la troisième vaut pour les deux.

---

## Mon avis, et il est à moi

**Le JSFX.** Pour une raison qui n'est pas technique : c'est celui qui rend
l'échantillonneur **disponible** — sur une machine neuve, après un clone, sans
rien construire. Et pour une qui l'est : il fait disparaître la classe de bug
qui a coûté cette journée, au lieu de la déplacer.

Le CLAP reste la bonne réponse **pour le moteur de clips**, qui est déjà écrit,
déjà testé, et dont la sortie de REAPER a un sens. Les deux ne s'excluent pas :
deux métiers, deux moteurs, et aucun des deux ne bricole dans l'autre.

Ce que j'écarte franchement, dans les deux cas : **garder le RS5K et réparer le
montage**. C'est faisable — il suffirait de relire le `FILE0` après chaque
déplacement et de le reposer — mais c'est consolider ce qu'on vient tous les
deux d'appeler du bricolage, et c'est deux migrations au lieu d'une.
