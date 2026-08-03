# Roadmap — les chantiers, dans l'ordre

Écrite le 2026-08-01, après le premier vrai test d'écoute de la suite complète
et la confrontation aux références du genre.

**Trois documents, trois rôles.** `ROADMAP_Autonomie.md` est le JOURNAL — ce
qui a été fait, session par session, et pourquoi. `ANALYSE_Confrontation.md`
est le RAISONNEMENT — où on en est face à Ableton et FL, ce qu'on copie et ce
qu'on refuse. **Celui-ci est le PLAN** : ce qu'on fait ensuite, dans quel
ordre, et à quoi on saura que c'est fini. `Recherche/` tient la matière brute.

**Un quatrième, pour une seule fenêtre.** `ROADMAP_Editeur.md` tient le plan de
CP_Editor : l'inventaire des modificateurs de souris MIDI de REAPER dans la
config de Cédric, ce que l'éditeur fait en face, la liberté de lecture « à la
Ableton », et le chantier des raccourcis configurables. Il se pioche ; il n'a
pas de priorité sur ce qui suit.

Une case cochée ici veut dire *écrit et compilé*, jamais *entendu* — c'est
Cédric qui écoute.

---

## L'ORDRE, décidé par Cédric le 2026-08-02 — **PARCOURU LE MÊME JOUR**

Les cinq chantiers sont écrits et compilés. **Rien n'a été entendu** : c'est
Cédric qui écoute, et c'est la seule chose qui manque à cette liste.

**Ce qui reste dans tout ce fichier tient en deux lignes**, toutes deux dans
« ce qui reste ouvert sur l'instrument » (chantier 2) : les paramètres JSFX
déclarés que rien ne lit, et le pitch à durée constante, qui demande un
étirement qu'un fil audio de 2005 ne fera pas.

**L'état du moteur** : ABI **2.5**, formats de sérialisation **10** (lanes) et
**CPC1** (clips), **188 assertions** au harnais, zéro allocation dans le fil
audio. *(Le message du commit `02d92ee` annonce 190 : il a été écrit avant le
dernier passage du harnais et se trompe de deux. La mesure fait foi.)*

---

## Ce que la PREMIÈRE ÉCOUTE a rendu — 2026-08-02, le soir

Neuf points, et une seule cause pour les cinq premiers : **la longueur d'une
case n'est connue que de la lane**, et trois décisions musicales la demandaient
à la grille de quantize, qui ne connaît qu'elle-même.

- [x] **Les sept modes de motion étaient faux, et de la même façon.** On tirait
      dans la dernière fenêtre de Q en comptant sur la quantification du moteur
      pour poser le départ sur la fin de la passe. Dès que la passe fait plus de
      deux Q — une case de **deux mesures** avec Q à la mesure — la fenêtre
      s'ouvrait **pile** sur une frontière, le moteur répondait « tout de
      suite », et la colonne changeait de case **au milieu du clip**.
      → **ABI 2.5** : `play-at` / `stop-at`, un **rendez-vous** et non un
      quantize. Un geste humain garde la grille ; un enchaînement pose sa date.
- [x] **Une note aussi longue que sa boucle ne se déclenchait pas.** La porte
      réconcilie un **ensemble** : celle qui couvre toute la passe est désirée à
      toutes les phases, donc elle attaque une fois et plus jamais. Le
      contournement — « la raccourcir d'un cheveu » — rouvrait le trou qui
      produisait la ré-attaque. Le **numéro de passe** entre dans l'identité du
      désir ; il se calculait déjà pour la probabilité.
- [x] **Une prise commençait n'importe où dans la case.** Elle partait à la
      prochaine frontière de quantize, dure une passe entière, et ses notes sont
      écrites à la phase où elles ont été jouées : commencer ailleurs qu'à la
      phase zéro rend la même musique **tournée**. « À chaque fois c'est le
      milieu du clip qui est le début » — Q à la mesure avec Rec : 4 mesures se
      trompait trois fois sur quatre.
- [x] **Le réglage qui manquait : la LONGUEUR d'une passe.** « Je dépose un
      kick, il joue une fois par mesure ; si je mets 4 fois par bar, ça ne change
      rien. » Exact : la signature **multiplie** la passe, elle ne la divise pas,
      et « Loop the material » répète à la durée **du fichier** — cinq coups par
      mesure à 120, hors de toute grille. Une case joue **une fois par passe** :
      un quart de mesure fait sortir quatre coups, sur la grille. Menu `Length`,
      du huitième de mesure — le plancher du moteur — à trente-deux.
- [x] **Une case audio perdait sa signature et son accolade à chaque
      armement.** Son clip est synthétisé, et `Loop.ApplyClip` écrit *toujours*
      ces deux champs — exprès, pour effacer ceux de l'occupant précédent d'une
      lane partagée. Le clip synthétique ne les recopiait pas : le réglage tenait
      une seconde, puis le lancement suivant le remettait à zéro.
- [x] **La barre d'espace ne faisait rien depuis la grille.** Cliquer une case
      ouvre son clip dans CP_Editor — c'est le geste même — mais le focus clavier
      reste sur la grille. CP_Session entre dans l'ordre du focus en **dernier**
      et ne réclame jamais la touche : elle la passe.
- [x] **La barre de vélocité prenait la mauvaise note.** Les barres d'un accord
      tombent à la **même abscisse** : « la plus proche en X » revenait à prendre
      toujours la plus grave. La **sélection** gagne, puis la **hauteur du
      doigt** ; et les choisies se dessinent **en dernier**, sinon elles
      disparaissent derrière une voisine plus haute.
- [x] **Le VU n'avait pas deux moitiés de la même épaisseur.** Cinq pixels à
      gauche, six à droite. Un VU dont les côtés diffèrent cesse de se lire comme
      une paire.
- [x] **Le pied de tranche.** Pan, mute et solo passent en colonne **à droite**
      du fader et du VU au lieu d'occuper trois lignes sous eux — trente-trois
      pixels rendus à la course du fader. Le pan devient un bouton rond
      **bipolaire** : son arc part du centre, donc le côté se lit sans lire un
      nombre.

### Ce qui a été SONDÉ et volontairement laissé tel quel

**« Attendre le Q pour arrêter un clip quand l'horloge est libre, est-ce
juste ? »** Oui, et la raison n'est pas dans notre code : *horloge libre* et
*quantize* sont deux réglages différents. L'horloge libre dit **d'où vient le
temps** quand le transport de REAPER ne roule pas ; Q dit **où tombent les
gestes**. Live n'a pas la distinction parce que chez lui les clips *sont* le
transport — et il quantifie tout, y compris ses Follow Actions (*« any setting
other than "None" will quantize the clip's launch when it is triggered by Follow
Actions »*, `Recherche/REFERENCE_Ableton_SessionView.md` §70-71).

Sans grille, deux cases lancées à une seconde d'intervalle ne se rejoignent
jamais : c'est précisément ce qu'une session view existe pour empêcher. `Q: Off`
est à un clic et donne le comportement sans contrainte.

**Ce que Live a et que nous n'avons pas** : une quantification de lancement **par
clip** (`None` / `Global` / une valeur), qui est la vraie réponse à « je veux que
*celle-là* parte sans attendre ». C'est un champ par lane dans le moteur et un
sous-menu par case. Non fait ; c'est le prochain candidat de ce fichier.

**Une relecture adversariale avait précédé** (quatre angles, chaque trouvaille
attaquée par un sceptique) : dix-sept trouvailles, quatre réfutées, **treize
corrigées**. Les deux plus graves étaient de la même journée — le mute séparé
dans des tables **locales à un état Lua** alors que la lane est partagée, et la
phase **gelée** dans l'instantané alors qu'on l'apparie avec un instant vif. Le
détail est au journal ; les deux leçons y sont nommées, parce que le dépôt les
avait déjà payées sous d'autres noms.

L'ordre reste écrit ci-dessous parce qu'il dit *pourquoi* chacun venait là, et
que c'est ce qu'on relit — pas la case.

1. **La session devient un instrument** (§4b et §4c). Le seul qui change la
   nature de l'objet : aujourd'hui la grille exécute des ordres, demain elle
   produit une structure. ⚠️ **Une décision t'attend dedans** : les follow
   actions en Lua s'arrêtent quand la fenêtre se ferme. Si ça doit y survivre,
   ça descend dans le moteur et ce n'est plus le même chantier. Grain
   **colonne** d'abord, à la FL — les Follow Actions par clip sont un panneau
   par case, et il faut savoir si le grain colonne suffit avant de le
   construire.
2. **Huit colonnes** (`Loop.MAX_LANES` 8 → 16). Voir « Les corrections d'une
   ligne » : ça casse le format de session, plafond dur à 15.
3. ~~**La probabilité par note**~~ — **faite le 2026-08-02** (ABI 2.2,
   format 9). Tirage **sans état** : un hachage de (note, passe), la passe prise
   sur l'**attaque** pour qu'attaque et coupure soient d'accord. Le harnais
   prouve les bornes, la distribution, l'égalité coupures/attaques, et que deux
   lanes identiques ne tirent pas la même suite. **Mode case seulement** — le
   MIDI de REAPER n'a pas de champ où la ranger, et l'en-tête de la section le
   **dit** au lieu de laisser glisser une barre qui ne survivrait pas.
   La section sous les notes a désormais ses **en-têtes de catégories** :
   vélocité et probabilité, le nom ouvre la liste, le chevron replie.
4. ~~**Le registre des défauts.**~~ **Fait.** Onze lignes restaient, dont sept
   touchaient la perte de données ou le mauvais son. Ce qu'elles avaient en
   commun n'était pas une famille de bugs : c'était **une phrase écrite dans le
   code qui n'était plus vraie**, et que personne ne relisait parce qu'elle avait
   l'air d'une explication. « Une instance par script, par projet » ; « le mute
   ne veut dire qu'une chose » ; « retirer un clip, c'est le retirer ».
5. ~~**La performance.**~~ **Fait.** Cinq lignes (la sixième, la collision de clé
   du cache de troncature, était tombée en passant à huit colonnes). La plus
   grosse n'était pas dans la liste : à huit colonnes et huit scènes, une frame
   franchissait le pont d'ABI trois à quatre **cents** fois. Un instantané par
   frame rend ce coût **constant**.

**Le « plus de son sauf C2 » du sampler — FERMÉ le 2026-08-02.** Trois défauts
répondaient, et le troisième était la cause. Une boucle `while` **non bornée**
dans le repli d'une voix du moteur natif, un drain d'anneau gmem non borné de la
même façon — les deux se lisent « le moteur audio a planté » et les deux sont
fermés et comptés (`N resync` dans la zone de statut). Mais le silence des pads
venait d'ailleurs : **`@gfx` et `@block` partageaient `i` et `k`**. Toute
variable d'un JSFX est globale et les sections ne tournent pas sur le même fil ;
or `k` est l'**index du champ** dans le drain de réglages, et `@gfx` s'en servait
comme compteur de lignes de 0 à 12 — soit exactement `P_LOADED`, `P_DATA`,
`P_FRAMES`, `P_NCH`. Un réglage arrivant pendant que la fenêtre dessine
atterrissait dans le pointeur de matière : le pad se taisait sans qu'aucun geste
ne l'ait touché. Aucun plantage n'était nécessaire — juste la fenêtre ouverte.

Désigné par une anomalie d'**affichage** : la liste montrait des pads 65 à 77
alors qu'il n'y en a que 64, et ces lignes lisent la table des voix
(`pad(65) == voice(2)`). Le partage de `i` était la moitié visible de celui de
`k`. Sans la capture image par image de Cédric, il n'y avait rien à chercher.
`Tools/jsfx_lint.py` refuse désormais le croisement, **vérifié contre le fichier
d'avant** (trois lignes rendues) et muet sur celui d'après.

---

## Ce que la DEUXIÈME ÉCOUTE a rendu — 2026-08-02, la nuit

- [x] **Le tempo écrit dans le nom du fichier n'était pas lu.** `_02_136.wav` :
      le motif exigeait un séparateur **des deux côtés**, donc il consommait
      celui de droite, et `gmatch` reprenait la lecture à `136` — qui n'avait
      alors plus de séparateur devant lui. **Le numéro de piste mangeait le
      tempo**, dans la convention de nommage la plus répandue des banques.
      Douze fichiers sur douze passaient à travers. Prouvé sur vingt cas :
      treize gains, zéro régression.
- [x] **Le tempo écrit dans l'ENTÊTE du fichier n'était lu par personne.** WAV
      acidisé, trame `TBPM`, AIFF annoté. C'est une source à part maintenant
      (`embedded`), et on ne devine pas le nom de la clé : REAPER rend la
      **liste** des identifiants du fichier. Le drapeau `oneshot` a le dernier
      mot. Conséquence : `analysed` descend en quatrième — une fois le tempo
      embarqué lu explicitement, ce qui lui reste est un **ajustement**, et un
      ajustement ne passe pas devant un nombre qu'un humain a écrit.
- [x] **La grille de CP_Editor était celle du PROJET par-dessus la forme
      d'onde.** Juste seulement si le fichier est déjà au tempo du projet. « Je
      dnd un sample, ça marche, mais je ne sais pas pourquoi » : les lignes
      tombaient à côté de la caisse claire. Un fichier ne porte pas une *carte*
      de tempo, il porte **un** tempo : ses temps sont réguliers dans ses
      propres secondes. Grille, magnétisme et règle en héritent — la règle
      compte en mesures (« 3.1 »), la ligne d'info nomme le tempo, **sa source**
      et la longueur en mesures.
- [x] **Le découpage d'une case son pouvait s'ouvrir mais pas rentrer.**
      « Comment décaler le début d'un sample dans un système non linéaire ? » —
      un clip n'a pas de position, il a une **région** dans son fichier.
      `offs`/`len` existaient de bout en bout ; seul le retour manquait.
      Sans sélection, on rend le fichier entier. La longueur en mesures est
      reprise à zéro, parce que c'est la région qui la décide.

### Le plafond d'un pad — 5,8 s, et ce n'est pas un choix

`maxmem=33554432` est le **plafond dur de REAPER** pour un JSFX. Les chemins en
prennent 24 576 ; les 33 529 856 restants se divisent en soixante-quatre parts
égales, soit 512 000 slots par pad — **5,80 s en stéréo à 44,1 kHz**, 11,6 s en
mono, 5,33 s à 48 kHz. Le découpage est **fixe** exprès : un pad ne peut ni
fragmenter, ni déborder sur son voisin, ni fuir quand on le recharge vingt fois.

**Ce qui le lèverait, si le besoin se confirme** : un allocateur à pointeur
montant sur toute la réserve — chaque pad prend ce qu'il lui faut, à la suite —
avec **repack par rechargement** quand le pointeur bute. Le JSFX en est capable
sans aide : il possède les chemins de ses soixante-quatre pads (c'est ce qui rend
un kit auto-suffisant) et `reload_next` recharge déjà un pad par bloc. Un kit de
quatre boucles de quatre mesures tiendrait alors, et un kit de soixante-quatre
coups aussi. **Non fait** : la carte mémoire est ce qui vient de cesser de coûter
des soirées, et une boucle de quatre mesures a déjà sa place — une **case de
Session**, jouée par le moteur natif, qui n'a pas ce plafond.

**La décision qui attendait dans le chantier 1 n'a pas été forcée** : le motion
est écrit en Lua, donc l'enchaînement s'arrête quand CP_Session se ferme. Le son
continue, la marche non. C'est écrit en tête du bloc. Descendre la règle dans le
moteur reste un autre chantier, et il se décide à l'usage — la question est de
savoir si Cédric ferme cette fenêtre en jouant, et elle n'a pas de réponse
théorique.

**Où NE PAS chercher ce qui reste** : `ROADMAP_Autonomie.md` est le JOURNAL. Ses
cases non cochées sont des marqueurs « prochain chantier » que leur propre
exécution a rendus caducs, et l'une d'elles a déjà été comptée à tort comme un
reste. Ce qui reste à faire vit ici, et nulle part ailleurs.

---

## Chantier 6 — La vue dédiée : vivre à la place de l'arrangeur

**Mesuré, pas supposé.** J'avais répondu « ce n'est pas possible » en raisonnant,
et Cédric a demandé qu'on teste. Trois sondes (`CP_Tools/CP_ArrangeProbe.lua`,
`CP_ArrangeBand.lua`, `CP_ArrangePanel.lua`), et **j'avais tort sur les trois
points**.

### Ce que les sondes ont établi

| question | réponse mesurée |
|---|---|
| masquer l'arrangeur tient-il ? | **oui** — `ShowWindow HIDE` survit aux deux passes de disposition |
| REAPER remet-il la géométrie ? | **oui**, et c'est une bonne nouvelle (voir l'oracle) |
| remet-il la **visibilité** ? | **pas sur une passe**, mais **oui pendant un glissement de séparateur** — 62 fois en 20 s |
| tient-il le rectangle à jour **masqué** ? | **oui** : A `843,156 420x652` → fenêtre réduite → B `935,255 0x427` → remise → C **exactement A**, et 143 valeurs distinctes en tirant les séparateurs |
| une fenêtre `gfx` reparentée dessine-t-elle ? | **oui** |
| reçoit-elle la souris, dans ses repères ? | **oui** |
| reçoit-elle le clavier ? | **oui, avec le focus qui suit la souris** — pris 6 / rendu 6, aucune fuite |
| la remise en état est-elle fiable ? | **5/5** à chaque passage |

**Aucune DLL.** `js_ReaScriptAPI` expose les mêmes appels Win32 qu'une extension
ferait. Une DLL ne serait nécessaire que pour **intercepter** des messages — et
il n'y a rien à intercepter.

### L'idée, en une phrase

> On ne touche **jamais** à la géométrie de REAPER. On masque la bande (ça
> tient), on **lit** le rectangle qu'il continue de calculer, et on y pose nos
> fenêtres. L'arrangeur invisible est notre **oracle de disposition**.

C'est ce qui fait disparaître la seule objection sérieuse — « il faudra
ré-appliquer sans arrêt contre le gestionnaire de disposition ». Il n'y a rien
contre quoi lutter : on s'aligne.

### Et une correction d'estimation

J'avais dit qu'un hôte multi-panneaux imposerait de **fusionner les
applications** dans un seul contexte gfx, et rendre `GetWindowSize` et les
coordonnées de souris relatives au panneau. **C'est faux.** Chaque application
garde sa fenêtre, sa boucle et son gfx ; l'hôte ne fait que de la **géométrie**.
`gfx.w`/`gfx.h` suivent la taille réelle de la fenêtre, donc une application
reparentée voit simplement « ma fenêtre a changé de taille » — ce qu'elle sait
déjà gérer. **Zéro ligne à changer dans CP_Session.**

### L'ordre, du plus utile au plus ambitieux

1. **Une application, toute la bande.** Masquer, garder masqué, reparenter
   CP_Session, suivre l'oracle, focus par la souris, tout rendre en sortant.
   C'est la demande d'origine, et c'est à une centaine de lignes de la sonde 3.
2. **Le découpage en panneaux.** Un arbre de séparations avec des ratios, un
   rectangle par panneau, une application par panneau. Les coutures se
   dessinent dans une fenêtre à nous placée **derrière** les panneaux (fond de
   la pile z), qui reçoit donc la souris dans les interstices : c'est elle qui
   porte le glissement des séparateurs.
3. **Les boutons de disposition**, à la Ableton/FL. Ils commandent nos panneaux,
   pas les screensets — ceux-ci restent utiles pour ce qui reste natif.

### Ce qui n'est PAS résolu, et qu'il ne faut pas découvrir en route

- **Le cycle de vie.** Que fait l'hôte si une application n'est pas lancée ? La
  lancer suppose son identifiant de commande (`NamedCommandLookup`), donc un
  registre. Et si elle est fermée pendant qu'elle est reparentée, il reste un
  trou : l'hôte doit le voir.
- **L'état dangereux : l'hôte meurt en laissant la bande masquée.** `atexit`
  couvre l'arrêt du script ; un plantage de REAPER ne laisse rien de durable
  (les fenêtres se recréent au démarrage). C'est borné, mais ça doit être écrit
  au-dessus du code, pas découvert.
- **Une fenêtre DOCKÉE ne doit pas être reparentée.** L'hôte doit exiger
  qu'elles soient flottantes, ou le faire lui-même.
- **La boucle gardienne est obligatoire** : 176 remises en visibilité pendant un
  glissement de séparateur. Cinq lectures par frame, mais elle doit exister.
- **Le « Track 1 [FX] none »** qui réapparaît pendant un glissement n'est pas
  une fenêtre : c'est REAPER qui peint sur la fenêtre parente. Rien ne peut le
  « recacher » — et ça devient sans objet dès qu'un panneau occupe la place.

### Étape 2 — le sélecteur de vue (décidé le 2026-08-03, pas commencé)

Trois boutons : **Arrange · Session · FX**. Cliquer met cette fenêtre à la place
de l'arrangeur ; cliquer Arrange remet tout comme avant.

**Ils vont dans une DEUXIÈME INSTANCE de `CP_FloatingToolbar`.** Elle n'en
accepte qu'une aujourd'hui — c'est donc le premier travail, et il profite à
autre chose que ce chantier.

**Au démarrage on part en Arrange** (les autres applications ne tournent pas
encore, une vue qui échoue au boot est pire qu'un clic). **Une application non
lancée : le bouton le dit et ne fait rien** — la lancer demanderait son
identifiant de commande, donc un registre, donc une autre fonctionnalité.

**Pas besoin de plusieurs fenêtres dans la bande** : une vue = une fenêtre qui
prend toute la place. La question des panneaux se pose ailleurs (voir ci-dessous).

### ⚠️ SONDE À FAIRE : peut-on désamarrer une fenêtre de l'EXTÉRIEUR ?

J'ai affirmé que non — « seule l'application peut se désamarrer, `gfx.dock`
n'agit que sur son propre contexte ». **C'est une affirmation, pas une mesure**,
et c'est exactement la faute qui a précédé les trois sondes de l'étape 1.

Ce qu'on sait : `Dock_UpdateDockID(ident_str, whichDock)` existe et prend un
**ident_str** — l'identifiant qu'une fenêtre déclare en s'enregistrant auprès du
docker (`DockWindowAddEx`). Ce qu'on ignore : est-ce qu'une fenêtre `gfx` de
ReaScript en possède un exploitable, et sous quelle forme.

Trois issues, et elles changent le plan :
1. **Ça marche** → l'hôte désamarre tout seul, rien à ajouter au toolkit.
2. **Ça ne marche pas** → un canal partagé dans `Core.Run` (« sors du docker »,
   adressé par titre, **avec péremption** : sans horodatage, une application
   lancée demain obéirait à un ordre donné aujourd'hui).
3. `JS_Window_SetParent` déplace bien la fenêtre mais **le docker garde son
   onglet** — à vérifier aussi, parce que c'est ce que je refuse actuellement
   dans `CP_ArrangeHost`, également sans l'avoir mesuré.

### Le vrai but à terme : notre PROPRE système de docking

REAPER n'accepte **qu'un élément par position de dock** (left, bottom, right,
top). Cédric veut deux choses à gauche de l'arrangeur — le Media Explorer et le
FX Browser côte à côte — et c'est impossible nativement.

C'est **le même mécanisme que la bande** : prendre une région, la découper, y
héberger N fenêtres. Ce que l'étape 1 a prouvé (masquer tient, l'oracle existe,
le reparentage marche, le focus se pilote) vaut pour n'importe quelle région,
pas seulement pour l'arrangeur. Un dock CP serait donc : une région lue chez
REAPER, un découpage à nous, des coutures à nous.

Ce qui reste à savoir avant de s'y engager : REAPER maintient-il le rectangle
d'un DOCKER masqué comme il maintient celui de l'arrangeur ? La deuxième sonde
répond pour l'arrangeur seulement.

---

## Où on en est (2026-08-01)

Le moteur natif est complet et l'autonomie est atteinte : plus aucune piste
d'infrastructure créée dans un projet, plus de JSFX de lanes, plus de gmem.
**ABI 1.7.** 141 assertions au harnais, zéro allocation dans le fil audio.

Le premier test d'écoute a rendu huit défauts, tous corrigés le jour même :
l'ancre d'horloge qui appariait deux instants différents (28 ms de retard
constant), la vitesse de lecture ignorée du moteur, la longueur d'une case
audio jamais lue dans le fichier, l'attaque mangée par le rattrapage de phase,
deux fondus qui n'existaient que sur le papier, la note fantôme envoyée à
l'instrument de la colonne, le stop du transport qui n'était pas maître, et la
porte de 97 % qui tranchait la queue de chaque passe.

**Le constat qui commande cette roadmap** : sur la vingtaine de défauts
restants, trois seulement touchent le C++. Le reste est du câblage absent — des
champs qui voyagent dans le format et que personne ne relit, des fonctions
écrites et jamais appelées, des réponses calculées et jamais montrées. *La
suite en sait beaucoup plus qu'elle n'en dit.*

---

## Chantier 1 — La propriété de l'entrée MIDI

**Le seul qui bloque un usage entier.** Et il ne décide pas de la question
RS5K : la réponse est la même dans les deux scénarios, donc rien n'est perdu.

### Le défaut

`Kit.EnsureBus` pose sur le bus du kit `I_RECINPUT = 4096 + (63 << 5)` — MIDI,
**toutes** entrées, **tous** canaux — avec `I_RECARM = 1` et `I_RECMON = 1`. Et
`Kit.HoldArm()` réaffirme cet état chaque fois que REAPER le remet à zéro,
c'est-à-dire à chaque changement de sélection de piste.

Le kit ne « ne réagit pas » aux pistes armées de REAPER : **il est en
compétition avec elles et il gagne, parce qu'il se réarme tout seul.**
`enforceSingleListener` désarme les autres *kits*, jamais tes pistes. Et un clic
de pad passe par `StuffMIDIMessage`, que le fichier qualifie lui-même de
*broadcast* : il atteint toute piste armée en monitoring.

### Le modèle visé

Le sampler pointe **une** piste. Le son sort par cette piste. C'est l'armement
de **cette** piste — dans REAPER, dans le mixer, ou dans CP_Sampler, c'est le
même bit — qui décide si tu la joues. Rien d'autre n'est touché.

### Étapes — **FAIT** (écrit et compilé, ABI 1.8)

- [x] **Ne plus forcer, lire.** `Kit.HoldArm` et `Kit.arm_intent` n'existent
      plus. `Kit.Armed()` lit l'état de la piste ciblée ; `Kit.SetArmed` écrit
      une fois, sur demande, et ne désarme plus l'autre instrument — une piste
      que l'utilisateur a armée lui-même est à lui.
- [x] **Rendre l'entrée normale.** Le bus naît comme n'importe quelle piste
      d'instrument : ni armé, ni monitoré, avec l'entrée que REAPER lui donne.
      « Écoute toutes les entrées MIDI » devient un geste nommé
      (`Kit.SetInputAll`, dans le menu), plus un état imposé. Idem pour la
      piste de l'instrument chromatique et pour la migration `SplitInstrument`.
- [x] **Les clics de pad cessent d'être un broadcast.** Nouvelle fonction
      d'ABI `CP_PortMidiAt(port, at, status, d1, d2)` : un message MIDI brut
      dans la piste d'un port, et nulle part ailleurs. `CP_Engine/Notes.lua`
      tient la cible et les notes non relâchées ; `Voice` expose la capacité
      (`CanSendMidi`) et la carte des ports réserve **24** au sampler, **25**
      à l'éditeur. **Tranché en écrivant : oui, le clic traverse la chaîne
      d'effets du pad** — le port est versé dans la piste du kit, donc le choke
      JSFX puis les RS5K. « Fais-moi entendre ce pad » ne peut pas vouloir dire
      autre chose que « ce que ce pad sonne ».
- [x] **`enforceSingleListener` disparaît.** Il désarmait le bus de tous les
      autres kits, en boucle, uniquement parce qu'un clic était un broadcast.
      Ce qui reste de l'idée est `Kit.active_guid` : un seul kit est la cible du
      sampler, et c'est une propriété de la fenêtre qui ne touche à l'état
      d'aucune piste. `Kit.Repair` ne désarme plus rien non plus.
- [x] **La même règle vaut pour la Session.** `Loop.SetArmedLane` reste, mais
      elle est désormais réservée au geste : les deux chemins de restitution
      (chargement de projet, relecture du blob) passent par
      `Loop.AdoptArmedLane`, qui **se souvient sans écrire**. Ouvrir un projet
      n'arme plus aucune piste.
- [x] **L'éditeur aussi.** CP_Editor auditionnait ses notes par le bus du kit
      de CP_Sampler — donc il fallait un kit pour s'entendre, et la note
      partait en broadcast. Il joue maintenant dans **la piste que ce clip
      alimente** : la piste de l'item pour une prise, la destination de la
      colonne pour une case. Sans destination, rien ne sonne — un silence
      explicable vaut mieux qu'un son dont personne ne sait d'où il sort.

### À quoi on saura que c'est fini

Armer une piste dans REAPER et jouer : seul cet instrument sonne. Ouvrir
CP_Sampler ne change rien tant qu'on ne lui demande rien. Cliquer un pad fait
sonner ce pad, et rien d'autre dans le projet.

**Le seul point sur lequel ce chantier s'appuie sans l'avoir mesuré** : le MIDI
d'un aperçu de piste franchit-il les **envois** de cette piste ? Il traverse la
chaîne d'effets, c'est acquis depuis l'ABI 1.6 (les lanes en vivent). Le saut
supplémentaire vers les pads est le seul inconnu, et le chantier 2 le supprime
en remontant les RS5K dans la chaîne du bus. Si un clic de pad reste muet, ce
n'est pas la peine de chercher ailleurs — c'est ça, et la réponse est le
chantier suivant.

---

## Chantier 2 — Un kit, une piste — **FAIT (2026-08-02)**

Un kit est **une piste portant un effet** : `CP_JSFX/CP_KitSampler.jsfx`,
64 pads, 64 voix, 8 paires de sortie. Plus de dossier, plus de piste par pad,
plus d'envoi MIDI filtré, plus de conteneur.

### Ce que l'instrument porte

Tout ce que faisait le RS5K — volume, pan, tune, A/D/S/R, choke, boucle,
région, min vol, vélocité min/max, plage de notes, canal MIDI, max voices,
probabilité, round-robin, mode sample ou chromatique — **plus** ce qui
manquait : portamento, obey note-offs, note-off release override, pitch bend,
loop start offset. **Plus** ce qu'exige un mixer interne : mute, solo et
sortie par pad, avec « Break out to a new track » pour rendre fader, mute,
solo et VU à un pad qui les mérite.

Trois réglages du RS5K disparaissent parce qu'ils n'ont plus de sens :
*Cache samples smaller than* (tout est en RAM), *Remove played notes from FX
chain* (on ne repasse pas la note — le réglage est devenu le comportement),
*Resample mode* (l'interpolation est la nôtre).

### Ce qui reste ouvert sur l'instrument

- [ ] `P_XFADE`, `P_INTERP`, `P_PLO/PHI` sont déclarés, sérialisés, et **rien
      ne les lit** — c'est écrit dans le fichier, à ne pas laisser pourrir.
- [ ] Le pitch à durée constante rend zéro plutôt que de mentir : il demande
      un étirement, que `Warp` fait hors ligne et qu'un fil audio de 2005 ne
      fera pas. C'est là qu'il faudra le brancher.

### Les deux moteurs cohabitent

Un kit dit lequel il est (`P_EXT:CP_KIT_ENGINE`) ; tout demande à
`Kit.IsFX()`. Un kit neuf naît sur l'instrument — y compris quand un
glisser-déposer le crée. La migration **construit à côté et n'efface rien** :
elle compte les pads qui SONNENT et laisse Cédric supprimer l'ancien kit.

### Ce que cette semaine a appris, et qui vaut pour la suite

**Chaque défaut a été trouvé par une MESURE, aucun par un raisonnement.** Les
mots bruts de gmem ont désigné une virgule en trente secondes ; le compteur de
notes reçues a séparé « le MIDI n'arrive pas » de « rien n'est chargé » ; le
journal a montré que les boutons marchaient alors qu'on cherchait pourquoi ils
ne marchaient pas. Trois soirées ont été perdues avant d'instrumenter.

Les outils qui en sortent vivent dans `Tools/` et tournent avant chaque
commit : `lua_lint.py` (blocs, locale utilisée avant déclaration, argument
manquant qu'une fonction concatène), `jsfx_lint.py` (blocs, arité des
fonctions de fichier, accès gmem, propreté du fil audio), `gen_kitsampler.py`.
Et l'instrument **dit ce qu'il fait** dans sa propre fenêtre : pads chargés,
notes reçues, notes réellement jouées, dernier réglage reçu, mots bruts de la
boîte aux lettres, battement de Lua.

## Chantier 3 — Dire ce que la suite sait déjà

Petit, et c'est celui qui rend la confiance. « Je ne suis jamais sûr que le
sample soit bien tempo-matché » est un problème d'affichage, pas de moteur.

- [x] **Le tempo retenu ET SA RAISON.** La ligne sous une case audio dit
      maintenant `128 BPM · name` — et `· read` (REAPER a lu le fichier, tempo
      embarqué compris), `· set` (décidé), `· guess` (déduit de la seule durée),
      ou **`no tempo found`**, qui est l'information qui manquait le plus :
      elle dit que le fichier joue tel quel. Calculé **une fois**, là où
      `soundBars` l'est déjà, et mémoïsé par case — cette ligne part dans une
      boucle de dessin.
- [x] **Le tempo déclaré, enfin éditable.** « Source tempo… » dans le menu
      Tempo. Il bat toutes les autres sources, et la longueur de passe est
      recalculée avec lui — puisqu'elle en dépend.
- [x] **La barre de progression suit le SON.** `Cells.Progress(t)` lit la
      position que la voix publie et la rend en fraction de la matière ; la
      phase de la lane reste la réponse pour une case MIDI, et le repli quand
      rien ne sonne. Un one-shot ne voit plus sa barre continuer d'avancer
      pendant qu'il se tait.
- [x] **« Stretch » cesse de mentir.** Les trois correctifs : `Warp.Version()`
      change à chaque fin de cuisson (réussie **ou** échouée) et `frame()`
      réarme les cases concernées — une case étirée ne reste plus un repitch
      jusqu'au prochain lancement manuel ; `Warp.Retry` a enfin un appelant, à
      côté de `Warp.Failure` qui dit **pourquoi** ça a échoué ; et le libellé
      est réécrit — « keeps the key, repitches until it is rendered ».
- [x] **Le texte d'aide de CP_Session** ne décrit plus de câblage supprimé.
      « Unroute », la piste SAMPLER par colonne et le routeur à canaux filtrés
      sont remplacés par ce qui est vrai : une colonne est une piste du projet,
      le moteur y verse le son directement, et l'armement est celui de REAPER.

---

## Chantier 4 — La grille devient un instrument

À faire après le 3, pas avant : ajouter des fonctions à une fenêtre dont on ne
comprend pas encore ce qu'elle joue est le meilleur moyen de perdre les deux.

### 4a — La région et le gain d'une case audio

`Cells.Arm` ne prend qu'un chemin et un taux. **`clip.offs`, `clip.len` et
`clip.gain` n'ont aucun consommateur** : une sélection de deux mesures glissée
depuis CP_Editor joue le fichier entier. Tout existe pourtant dessous — le
moteur porte `loop_start` / `loop_end` / `pos` / `gain` en frames source, et
`Voice.Play` les transmet déjà.

- [x] Faire passer `offs` / `len` / `gain` jusqu'à `opts` dans `playAt`.
- [x] `soundBars` mesure la RÉGION et non le fichier — une tranche de deux
      temps prise dans un break de quatre mesures fait deux temps, et c'est
      cette longueur-là qui décide de la passe.

**Ce que ça débloque** : découper un break en huit tranches, une par case. Un
geste fondateur d'une session view, aujourd'hui strictement impossible. Et
l'aller-retour éditeur → case cesse de mentir.

### 4b — La fin de passe comme évènement

FL appelle ça *Motion*, **par piste** : `Stay`, `One shot`, `March & wrap`,
`March & stay`, `March & stop`, `Random`, `Exclusive random`. Ableton fait la
même chose **par clip** avec dix Follow Actions et deux probabilités.

**Grain colonne d'abord**, à la FL. Les Follow Actions par clip sont un panneau
par case, et il faut savoir si le grain colonne suffit avant de le construire.

- [x] Un enum de sept comportements par colonne (`pollMotion`, appelé dans
      `frame()` juste après `Loop.Poll()` — c'est lui qui redonne quelle moitié
      est vivante, et lire la phase avant lui suivrait la lane que la colonne
      vient de quitter). Réglage par colonne dans le menu du **nom** de colonne,
      persisté avec le projet, et **visible dans l'en-tête** : `1x`, `M>`, `M=`,
      `M.`, `R?`, `R!`. Stay ne dessine rien — un défaut n'a pas à se signaler.
- [x] Le compteur de tours joués tombe du même repli de phase, et s'affiche
      dans la case qui joue (`xN`, à droite du nom). Il compte les passes de
      **ce clip-là** : un pas de marche le remet à zéro, parce que la question
      qu'on se pose est « depuis combien de temps j'entends ça ».

**Les trois réserves sont écrites au-dessus de `pollMotion`**, là où elles
mordent : la frontière de Q ne coïncide avec la fin de boucle que si la longueur
de lane est un **multiple** de Q ; à Q: Beat et 160 BPM la fenêtre vaut 375 ms,
soit onze frames de defer, et c'est le plancher ; **Q: Off n'a pas de fenêtre du
tout**, on y tire donc sur le repli lui-même, avec une frame de retard — le dire
vaut mieux qu'inventer une avance qu'on ne peut pas tenir.

**Deux gardes que l'écriture a rendus nécessaires**, et qui ne se devinent pas :
l'horloge doit battre (un transport arrêté fige la phase, et une fenêtre de Q
figée tire) ; et **retomber sur la case en cours veut dire *continue*** — la
relancer la ferait basculer, donc un Random sur une colonne d'une seule case
s'éteindrait dès la première passe.

⚠️ **L'enchaînement s'arrête si la fenêtre se ferme**, parce que c'est du Lua.
Le son continue, la marche non. C'est écrit en tête du bloc. Descendre la règle
dans le moteur reste un autre chantier, et il se décide à l'usage : la question
est de savoir si Cédric ferme cette fenêtre en jouant, et elle n'a pas de
réponse théorique.

### 4c — Les petits gestes

- [x] **`+Scene`** — superposer au lieu de remplacer. FL, verbatim : *« will
      replace playing Clips with any new Clips on the same track in the next
      Scene but leave any Clips on unused tracks playing »*. Aujourd'hui
      `sceneLaunch` arrête toute colonne sans clip, donc **une nappe ne peut pas
      survivre à un changement de scène** : il faut la dupliquer dans les huit
      lignes. Cinq lignes, zéro stockage. Ctrl+clic sur le triangle de scène,
      ou Ctrl+Entrée au clavier : la question se pose **au lancement** plutôt
      que de vivre dans un réglage qu'on oublie avoir posé.
- [x] **Une sélection et un clavier.** Flèches, Entrée (case), Suppr, Ctrl+Z.
      **Page Up / Page Down** montent et descendent de huit scènes chez Ableton ;
      cette grille en a huit *en tout*, donc ils y valent le haut et le bas de la
      colonne — le même geste ramené à la taille de l'objet, plutôt qu'une touche
      inerte. Et **Maj+Entrée lance la scène puis descend d'un cran** : c'est
      l'avance qui fait le geste, pas le lancement — sans elle il faudrait une
      flèche entre chaque scène et on ne descend plus un set en tapant Entrée.
- [x] **Capture and Insert Scene** (Ctrl+Shift+I) : ce qui joue devient une
      ligne, *« with no audible interruption »*, et c'est exact **par
      construction** — le tag de lane est de la métadonnée pure, donc recopier
      les descripteurs puis reposer les tags allume la nouvelle ligne sans
      redéclencher une note ni remettre une phase à zéro.
      Ableton **insère** une ligne ; cette grille en a huit, fixes, donc la
      cible est la première ligne **entièrement vide** en descendant depuis la
      sélection — et quand il n'y en a plus, on le dit. Écraser une ligne pleine
      serait détruire une scène pour en garder une autre, ce que personne ne
      demande en tapant « capture ». Une lane qui **enregistre** est exclue de
      la relève : la réétiqueter couperait le lien que `pollRec` suit pour ranger
      la prise dans sa case.

---

## Les corrections d'une ligne

Elles ne sont pas des chantiers et changent l'usage quotidien.

- [x] **Le transport suspend, il n'oublie pas.** En mode Suivre, arrêter le
      transport arrêtait *l'état* de chaque case en lecture, pas seulement son
      son : rappuyer sur play ne relançait rien, il fallait recliquer la
      grille. Le moteur avait déjà raison — il laisse une lane en lecture dans
      son mode sur le front descendant. Ce qui obligeait à l'arrêt, c'étaient
      les cases **audio**, qui sont des voix et gardaient leur passe
      programmée ; elles se taisent maintenant d'elles-mêmes quand l'horloge ne
      bat plus (`Cells.drive`), et `Loop.ClockRunning()` dit cette condition
      une fois pour toutes.
- [x] **Un clip s'ouvre dans la vue de ce qu'il joue.** « Il y a un kit sous la
      cible » décidait des rangées de batterie — mais depuis le chantier 2 un
      instrument chromatique **est** un kit (d'un seul pad, sur sa piste), donc
      chaque clip d'instrument s'ouvrait avec une seule rangée nommée, sur
      laquelle aucune mélodie ne s'écrit. Le genre voyage désormais dans la vue
      (`Loop.KitViewOfTrack` → `kitview.mode`), et seulement pour un kit JSFX :
      sur l'ancien moteur, `CP_KIT_MODE` note quelle page le Sampler affichait
      en dernier, ce qui n'est pas un genre.
- [x] **La barre d'espace et le bouton Play disaient deux choses.** Le son
      partait, le bouton restait sur « Play » : les touches sont traitées après
      le dessin, donc l'appui laisse toujours une image de retard — et la
      fenêtre s'endormait avant de la rattraper, parce que le seul réveil
      demandé pendant une écoute venait du **curseur de lecture**, qui ne se
      dessine que si sa position est lisible. Le réveil est maintenant demandé
      sur la bonne condition : ça sonne.

- [x] **La fenêtre de tolérance de lancement.** Elle vaut désormais **un
      huitième du quantize**, plafonnée à 0,25 beat : 250 ms à Q: Bar, 62 ms à
      Q: Beat, 15 ms à Q: 1/4. Elle suit donc la finesse demandée — serrer le
      quantize resserre la fenêtre, ce qui est exactement ce qu'on veut dire en
      le serrant. Le plafond existe pour Q: 32 mesures, où un huitième ferait
      partir « tout de suite » un lancement qu'on voulait à la fin.
      **Deux assertions de plus au harnais** — dont une qui mesure la fenêtre
      elle-même, parce que l'ancien test passait à 0,45 beat de la frontière et
      aurait donc mesuré autre chose que ce qu'il annonçait.
- [x] **Huit colonnes.** `Loop.MAX_LANES = 16`.

      **Le calcul de ports était faux dans les deux sens, et l'écrire a suffi à
      le voir** : le MIDI ne prend pas `PORT_BASE + lane` mais `PORT_BASE + t`
      — les deux moitiés d'une paire partagent un port, parce qu'une paire est
      *une* piste musicale. Donc audio `0..TRACKS-1`, MIDI `8..8+TRACKS-1`, et
      **huit est exactement le plafond** : à neuf, le son de la colonne 8 prend
      le port 8, qui est le MIDI de la colonne 0. Les deux plages se touchent
      sans se recouvrir, pile. Aller au-delà demande `PORT_BASE = 16`, et le
      plafond devient alors quinze — là, le MIDI atteint le 31, l'audition.

      **La remontée est faite, et elle porte un NOMBRE plutôt qu'un drapeau.**
      Le bloc de rappel est ordonné par lane, et le pas qui sépare une moitié
      vivante de sa jumelle *vaut le nombre de colonnes*. **Format 8** : le
      nombre de lanes entre dans l'en-tête, donc un blob se remonte depuis
      n'importe quelle valeur passée et vers n'importe quelle valeur future avec
      la même ligne. Un drapeau « ancien / récent » aurait tenu jusqu'au
      changement suivant. Les `dest<lane>`, eux, n'ont nulle part où porter ce
      nombre : `Loop.MigrateLayout` les déplace une fois, et le marqueur
      `CP_Loop/lanes` dit **comment ce projet range**, pas « ce projet a été
      migré » — c'est la seule formulation qui empêche de remonter deux fois un
      projet écrit par la version d'après.

      **Trois choses que l'écriture a rendues nécessaires**, et qu'aucune ne
      figurait au plan : la remontée vit dans `RefreshDests` et non à
      l'initialisation, parce qu'un `defer` survit à un changement d'onglet et
      que le second projet aurait été lu avec la disposition du premier ; la
      lane **armée** subit le même pas, sinon rouvrir un projet arme la jumelle
      d'une autre colonne ; et une lane que le blob ne couvre pas doit être
      **vidée**, parce que le moteur survit au script et que les quatre colonnes
      neuves se seraient allumées avec le set du projet précédent.

      **Et la migration du routeur traduit elle-même.** Elle arrive *après* le
      marqueur — celui-ci est posé dès l'ouverture d'une fenêtre, elle attend un
      `Setup` — donc s'appuyer sur `MigrateLayout` l'aurait rendue inerte.

---

## Le registre des défauts

Détail et citations `fichier:ligne` dans `Recherche/DEFAUTS_Balayage.md` et
`Recherche/DEFAUTS_Trous_de_logique.md`. Les adresses y datent du 1er août au
matin ; le fond tient.

### Perte de données ou mauvais son

- [x] **`Loop.SaveState` n'a aucun garde `NATIVE`.** Corrigé — une ligne de
      garde. Sans l'extension, la sérialisation produisait huit lanes vides et
      les écrivait par-dessus l'état du projet, à la fermeture de la fenêtre.
- [x] **Aucune annulation sur l'édition de notes d'une case.** Une pile de
      **photos** des notes (64 crans), remise à zéro en changeant de case —
      mélanger deux historiques ferait annuler un geste dans une autre case, ce
      qui est pire que de ne pas annuler. Pas un journal d'opérations : quelques
      centaines de nombres se recopient pour rien, et un journal aurait demandé
      à chaque geste **futur** de savoir se défaire.
      ⚠️ **La photo prend tout ce qu'une note porte** — la probabilité comprise
      depuis aujourd'hui. Une photo partielle fait de l'annulation une
      destruction : elle remet les notes en place *sans* un réglage que le geste
      annulé n'avait pas touché.
- [x] **Alt+clic efface une case sans confirmation ni annulation.** La dernière
      case effacée est gardée, Ctrl+Z la repose. **Une seule**, pas une pile : ce
      geste se fait une fois et on le regrette tout de suite, et une pile aurait
      fait croire à une annulation générale de la grille, qui elle n'existe pas.
- [x] **Le tag de lane n'est pas sérialisé.** **Format 6** : le tag entre dans
      le bloc de chaque lane, entre le mode et le nombre de notes. Un lecteur
      ancien ignore le champ, un lecteur neuf sur un projet ancien lit 0 — ce
      que le tag valait déjà. Les gardes de version acceptent v6 et comparent
      des NOMBRES, pas des chaînes : `"10" < "4"` aurait cassé silencieusement
      à la version dix.
- [x] **Une lane du Looper ouverte dans l'éditeur n'a aucune identité.**
      `LaneOfTag(t, 0)` rend `nil` — zéro n'est pas une identité, c'est
      l'absence d'identité, et le commentaire d'origine promettait déjà cette
      réponse. `LaneToClip` porte le tag de la lane, et lui en pose un
      (`1000000 + lane`, hors de portée des identités de la grille) quand elle
      n'en avait pas : c'est le seul moment où on peut le faire.
- [x] **Un slot libéré est réattribué avec ses clips.** **On n'efface pas, on
      n'adopte pas** : un slot qui tient quelque chose (`Loop.SetSlotHeld`, que
      seul l'hôte peut savoir) est sauté par l'adoption automatique. Il reste,
      ses clips restent, et sa colonne se dessine en disant « no track » — ce
      qui est l'état des choses, et ce que l'en-tête savait déjà montrer.
      Effacer aurait été plus simple **et aurait détruit du travail pour réparer
      un rangement**. Les slots orphelins passent en fin d'ordre d'affichage, et
      *après* le tri : sans piste ils n'ont pas de numéro de piste, donc aucune
      place dans un ordre qui suit le projet — et une colonne qu'on ne dessine
      pas est un travail qu'on croit perdu.
- [x] **Changement de projet, fenêtre ouverte.** La prémisse « une instance par
      script, par projet » était fausse, et on l'avait écrite deux fois — dans
      `Loop.RouterChanged` et au-dessus de l'autosave. **Un `defer` survit à un
      changement d'onglet.** Trois conséquences, toutes silencieuses : l'autosave
      écrivait le set de A dans le fichier de B ; `RefreshDests` rebranchait les
      ports de A sur les pistes de B ; et les identités, qui sont par projet, se
      résolvaient les unes sur les autres.
      Le front est **détecté** (comparaison de pointeur de projet, une fois par
      frame, sans allocation) et **consommé** : il suspend l'autosave *avant tout
      le reste*, puis CP_Session relit la grille, les motions, la longueur de
      prise, remet `Ident` à zéro et invalide ses caches. La décision demandée
      est donc prise : ces fenêtres suivent le projet actif.
- [x] **Une lane du Looper portait l'identité du premier clip de la grille.**
      `LaneToClip` frappait `1000000 + lane` — c'est-à-dire `Ident.BASE + lane`,
      et la toute première identité d'un projet est `BASE + 1`. Deux clips
      répondaient à un seul tag, et le commentaire affirmait l'inverse : *« ne
      peut collisionner avec aucun autre »*. La bande est descendue **sous**
      `Ident.BASE` (`Loop.LANE_TAG_BASE`), là où le compteur ne peut par
      construction jamais descendre, et au-dessus de tout tag positionnel
      possible. Trouvé en relisant les espaces de numéros pour huit colonnes.
- [x] **Collisions d'identité entre projets.** Fermé par le point ci-dessus :
      `Ident.Reset` vide le registre et le compteur sur le front de changement de
      projet. La réponse n'est **pas** de rendre les identités globales — elles
      appartiennent au projet — c'est que l'hôte remette le module à zéro quand
      le projet change sous lui.
- [x] **Changer le mode tempo d'un son en cours décharge la matière sous la
      voix.** **Retirer est désormais une DEMANDE, pas un geste** : un clip
      qu'une voix joue encore reste visible et résident, et la demande est
      honorée dès que plus personne ne le tient.
      Le garde-fou `Clip::refs` existait et n'était alimenté par personne. Il se
      **déduit** maintenant de ce que les voix publient (`pub_clip`, un champ de
      plus dans la publication de fin de bloc) plutôt que d'être tenu par le fil
      audio : compter au démarrage et décompter à la mort aurait demandé quatre
      chemins sans faute — démarrage, arrêt, vol de voix, enchaînement — et c'est
      le genre de comptabilité qui finit par mentir une fois.
      Deux assertions au harnais : le son continue pendant la demande, et la
      mémoire est rendue une fois la voix éteinte (sans quoi ce serait une fuite
      avec un drapeau dessus).
- [x] **Une lane mutée dans le Looper coupe son MIDI mais pas sa case audio.**
      Les deux intentions sont **séparées**, ce qui était le préalable écrit
      au-dessus du code depuis le premier jour :
      **mécanique** (`Loop.SetMute` — « ce MIDI ne doit pas sortir », ce que
      CP_Session pose sur une case audio pour que sa note unique n'atteigne pas
      l'instrument de la colonne) et **musicale** (`Loop.SetUserMute` — « tais
      cette lane », le bouton du Looper). Le moteur reçoit leur **OU** : il n'a
      qu'une case à cocher et n'a pas à savoir pourquoi.
      `Cells.drive` lit l'intention musicale, et elle seule, pour taire la voix —
      comme une horloge arrêtée : le son se tait, l'**état** ne bouge pas, et
      démuter fait rentrer la voix sur la phase courante par le chemin qui
      existait déjà. Le bouton du Looper affiche l'**intention** et non l'état
      effectif : il s'allumait sur des lanes que personne n'avait tues.
- [x] **Fuite de `PCM_source` dans `SrcTempo.FromAnalysis`.** Un seul point de
      sortie, parce que la fonction rendait à quatre endroits et qu'il en
      manquait quatre. Un kit de soixante-quatre pads en fuyait soixante-quatre
      au chargement.

### Ce qui trompe

- [x] **Sept champs morts voyagent dans chaque `.RPP`** — il en restait
      **quatre**, et ils sont partis : `pitch`, `rate`, `q`, `root`. `gain`,
      `src_bpm` et `lmode` ont gagné des lecteurs en chemin (le découpage de
      région, le tempo déclaré, one-shot/boucle), et c'est justement ce qui les
      distingue. Les retirer est sans risque : le registre de champs ignore ce
      qu'il ne connaît pas, donc un projet ancien les perd simplement à la
      prochaine écriture.
- [x] **La longueur d'une boucle n'appartient à personne.** Elle en a une
      maintenant : **ABI 2.3**, `CP_LaneSet(lane, "tsnum", n)`, et le champ
      `tsnum` du descripteur — donc elle voyage avec la CASE et non avec la
      lane, exactement comme l'accolade, pour la même raison (une lane est un
      emplacement partagé). **Zéro = suivre le projet**, ce qui est le
      comportement d'avant : la correction est gratuite pour qui ne s'en sert
      pas, et tous les projets existants s'ouvrent inchangés.
      « Time signature » dans le menu d'une case. Poussée dans la lane **tout de
      suite** quand la lane tient cette case : c'est la longueur de boucle qui
      change, donc ce qu'on entend, et attendre le prochain lancement donnerait
      un réglage qui « ne marche pas » jusqu'à ce qu'on relance.
- [x] **Q et le mode d'horloge ne survivent qu'à une fermeture propre.** Les
      deux appellent `Loop.MarkDirty()` maintenant, comme CP_Looper le faisait
      déjà.
- [x] **`Mix.SendCreate` annonce « Send → X » sur un envoi déjà existant.** Elle
      rend désormais l'index **et** si l'envoi vient d'être créé. Le message est
      le seul retour de ce geste : il disait « c'est fait » à quelqu'un qui
      venait de refaire ce qui était déjà là, et la fois d'après on ne savait
      plus s'il y avait un envoi ou deux.
- [x] **`Cells.LastOnsetError`** est lue, et son résultat s'affiche dans la zone
      de statut : `onset +0.00 ms worst / N`. Le **pire** depuis l'ouverture, pas
      le dernier — un écart qui n'arrive qu'une passe sur vingt est exactement
      celui qu'on cherche, et montrer le dernier le fait disparaître avant qu'on
      ait levé les yeux. Relevée **une fois par passe** et non par frame : la
      vérité terrain est notée par la voix au démarrage et ne bouge plus, donc la
      relire chaque frame coûterait un appel d'ABI par colonne pour un nombre qui
      ne change pas.

### Performance (la cible est un PC de 2005, et le dépôt l'écrit partout)

- [x] **`Mix.guidOf` alloue une chaîne par appel.** Le cache était indexé par
      GUID, et `guidOf` construisait cette chaîne à chaque appel — donc une
      quinzaine d'allocations par colonne et par frame **uniquement pour
      retrouver l'entrée qui évitait des allocations**. La clé est le POINTEUR
      de piste : rien à construire, rien à comparer caractère par caractère. Le
      prix est qu'il ne survit pas à la suppression d'une piste, donc la table
      est bornée — au-delà de 64 pistes vues, on vide et on reconstruit les huit
      qui comptent. Une table qui ne grandit que quand on supprime des pistes,
      et qui se vide toute seule, n'a pas besoin de savoir ce qui est mort.
- [x] **Le cache du mixer est clé sur `GetProjectStateChangeCount`.** On
      distingue maintenant deux causes. Un changement de **nombre** (un effet
      ajouté ou retiré) se voit tout de suite : `TrackFX_GetCount` est un appel
      sans allocation, payé à chaque fois. Un changement du compteur **à nombre
      constant** — un fader, un pan, une automation — attend un quart de
      seconde. Un nom d'effet qui change est assez rare pour que 250 ms de
      retard ne se voient jamais ; soixante reconstructions par seconde, si.
      ⚠️ **Le bypass n'est plus caché**, et c'est ce qui rend l'étranglement
      possible : caché, il aurait mis un quart de seconde à s'allumer sous le
      doigt. Le commentaire d'origine disait déjà « every bypass is read live »
      — le code, lui, le cachait.
- [x] **`audioSub` fait un `io.open` par frame et par case en stretch.**
      L'accès disque était déjà mémoïsé (`st_cache`, invalidé par
      `Warp.Version`) ; ce qui restait était plus discret et tout aussi cher :
      la **clé** du memo était une chaîne concaténée à chaque frame, donc trois
      allocations par case audio et par frame pour décider s'il fallait
      reconstruire un texte qui ne change jamais. Les quatre composantes se
      comparent séparément — zéro allocation tant que rien ne bouge.
- [x] **Collision de clé dans le cache de troncature.** La clé réserve
      maintenant une ligne de plus que la grille (`t * (SCENES + 1) + s`), parce
      que l'en-tête de colonne appelle `cellLabel` avec `s = SCENES` et tombait
      donc exactement sur la case `(t+1, 0)`. Fermé en passant à huit colonnes,
      où le défaut passait de trois collisions par frame à sept.
- [x] **`pollCapture` fait un `CP_LaneGet` par événement et par lane.** Le
      balayage qui ouvre la fonction répond déjà à la question : il retient les
      lanes en capture, et la zone et le décalage de chacune sont relevés **une
      fois** avant la boucle d'événements — ils ne bougent pas pendant la frame.
      Et les événements bruts vont dans deux tableaux parallèles réutilisés
      plutôt qu'une table par événement : 128 tables par frame pendant une
      prise, c'est 128 occasions pour le ramasse-miettes de passer pendant qu'on
      joue.
- [x] **~2 à 7 appels d'ABI par case et par frame** — c'est mieux qu'une table
      tag→lane : **un instantané de frame**. Les huit champs que le dessin
      demande en boucle (`tag`, `mode`, `pending`, `phase`, `lenbeats`,
      `target`, `spana`, `spanlen`) sont lus une fois par lane au début de
      `Loop.Poll`, et tout ce qui suit lit la table. Le coût devient
      **constant** (8 × 16) au lieu de croître avec la grille — à huit colonnes
      et huit scènes, une frame franchissait le pont d'ABI trois à quatre CENTS
      fois.
      **La fraîcheur ne change pas**, et c'est ce qui rend l'échange gratuit :
      ces champs sont publiés par le fil audio en fin de bloc, et une frame de
      defer dure plus longtemps qu'un bloc — les relire au milieu d'une frame
      rendait la même valeur. La seule exception est le **tag**, qui s'écrit
      depuis Lua : `SetLaneTag` met donc l'instantané à jour en même temps que
      le moteur, sans quoi une case armée puis dessinée dans la même frame
      clignoterait au mauvais endroit pendant une frame.

---

## Ce qu'on refuse, et pourquoi

Pour ne pas y revenir tous les trois mois.

- **L'enregistrement audio dans une case.** REAPER le fait déjà, en mieux. Ce
  qui manque à ce chemin, c'est la région (4a), pas un enregistreur.
- **Le modèle « pattern » de FL.** L'exclusivité par colonne est structurelle
  ici (une colonne possède une paire de lanes) et gratuite. Rouvrir ce choix,
  c'est jeter la meilleure propriété du modèle. Sa conséquence, elle, est
  volable : dupliquer une scène entière (4c).
- **Le tempo et la signature par scène.** Il faudrait écrire la carte de tempo
  de REAPER depuis un lancement de clip — modifier le projet pendant un jam — et
  ça n'a aucun sens en horloge libre.
- **Gate / Repeat / Toggle par clip.** Ils existent chez Ableton *pour des
  contrôleurs*. Sans mapping MIDI ils n'achètent rien, et `Toggle` est déjà le
  comportement.
- **Le mapping MIDI des cases** — pas un refus, un **préalable** : le même flux
  alimente la piste armée, donc un pad qui lance une case jouerait aussi
  l'instrument et serait enregistré dans la prise. Après le chantier 1.
- **La zone de performance dans l'arrangement (FL).** Contredit l'acquis « CP ne
  crée aucune piste d'infrastructure ».
- **Les onglets d'effets destructifs de FL** (normalize, reverse, EQ cuits dans
  l'échantillon au chargement). On a tranché l'inverse et mieux : éditions non
  destructives, `Bake` comme échappatoire explicite.
- **Slicex comme plugin séparé.** Le découpage est déjà décidé autrement, et
  mieux adapté ici puisque les slices atterrissent sur de vraies pistes.
- **L'entrée de notes au clavier QWERTY/AZERTY.** Le clavier virtuel de REAPER
  couvre le besoin.

---

## Ce qui est déjà bon, et qu'une refonte perdrait sans s'en apercevoir

À relire avant de toucher à l'interface.

- **Cliquer le contenu ouvre l'éditeur, cliquer la bande lance. Jamais
  l'inverse.** Ableton mélange les deux et a besoin d'une préférence pour
  rattraper la confusion. **Meilleur qu'Ableton.**
- **La scène tombe d'un bloc.** Le moteur draine toutes les commandes du bloc
  d'un coup : *« la moitié d'une scène partant une mesure avant l'autre n'est
  pas un quantize, c'est un bug poli »*.
- **La phase ancrée sur la timeline**, pas sur l'instant du clic.
- **Un son EST une lane** — une seule machine à états pour l'audio et le MIDI.
- **Follow / Free, et « waiting for the transport » écrit en toutes lettres.**
  Ableton n'a pas ce choix : il *est* le transport.
- **Le mixer est celui de REAPER**, pas un second à synchroniser.
- **Une colonne est une piste du projet, adoptée par GUID**, le slot stable,
  l'ordre d'affichage suivant le projet.

---

## La destination — un instrument CP en plugin

**Atteinte le 2026-08-02, par le JSFX.** `ANALYSE_Sampler_JSFX_vs_CLAP.md`
posait les deux moyens ; le JSFX l'a emporté pour la raison qui y était
écrite — il rend l'échantillonneur disponible après un simple clone. Le CLAP
reste la bonne réponse **pour le moteur de clips**, qui est déjà écrit, déjà
testé, et dont la sortie de REAPER a un sens. Deux métiers, deux moteurs.

Ce qui manque au moteur pour remplacer le RS5K est **petit** : un ADSR (il n'y
a que des fondus linéaires), un vol de voix par groupe de choke (plus simple en
natif que le JSFX), les zones de vélocité. Loop, région, vol, pan et varispeed
existent déjà. L'étirement à durée constante reste hors ligne (`Warp`), et
c'est une décision chiffrée : 2,3 % du fil audio par voix et 85 à 139 ms
d'amorçage.

**Le blocage n'est pas le DSP, c'est le MIDI.** Le moteur est un `PCM_source`
joué par `PlayTrackPreview2Ex` : il **produit** du MIDI — c'est comme ça que les
lanes parlent — mais il n'en **reçoit** pas. Le jouer au clavier passerait par
Lua et `MIDI_GetRecentInputEvent` : les événements sont horodatés à
l'échantillon, mais la sonde tourne une fois par frame de defer, 16 à 74 ms.
Bon pour armer une case, inutilisable pour jouer.

La seule sortie propre est de **livrer le cœur comme plugin** (CLAP, en-têtes
MIT et sans dépendance, ou VST3). Et c'est borné plutôt que fantasmé :
`CP_Native/src/core` a été écrit depuis le début sans une seule ligne d'API
REAPER — c'est une règle du dossier, et le harnais le compile et le teste hors
REAPER.

En bonus, cette voie règle le routage : un plugin sort sur N paires stéréo, et
les conteneurs d'effets de REAPER 7 se punaisent sur une paire. Un kit = une
piste, un plugin, un conteneur par pad qui en veut un.

**Ce qui serait perdu, c'est de faire ça sans le chantier 1** : on aurait un
beau moteur avec le même MIDI incompréhensible.

### La preuve par l'accident (2026-08-01)

Le pitch à durée constante par pad a été écrit, puis **retiré le jour même**.
Il exigeait un ReaPitch par pad, donc un conteneur par pad, donc un déplacement
d'effet — et ce déplacement se faisait sur le chemin d'**un bouton qu'on
tourne**. Chaque tour restructurait la chaîne d'effets du projet.

Ce n'est pas un défaut d'écriture, c'est la limite du montage : **tout paramètre
d'instrument qui n'existe pas dans le RS5K coûte un effet de plus dans une
chaîne partagée, et une chaîne ne se restructure pas pendant un geste.** ADSR
par pad au-delà de ce que le RS5K offre, zones de vélocité, choke sans JSFX,
transposition à durée constante : tous butent sur la même chose.

Dans un plugin, ce sont des **paramètres**. On en tourne un, il change. C'est
tout l'écart, et il est structurel — pas une question de soin.


---

## Les décisions qui appartiennent à Cédric

- **Le nombre de colonnes.** Huit est fait (2026-08-02), et c'est le plafond
  exact de la carte des ports actuelle. Au-delà il faut monter `PORT_BASE` à 16,
  ce qui porte le plafond à quinze — et, à ce nombre-là, une largeur minimale de
  cellule ou un défilement horizontal. À huit, la grille tient encore dans une
  fenêtre de 240 px : c'est le plancher existant, pas un nouveau.
- **Le sort du chantier 2 si le plugin arrive vite.** Replier le kit sur une
  piste avec des RS5K, puis remplacer les RS5K par le plugin, c'est deux
  migrations. Les faire d'un coup est possible — au prix d'attendre le plugin.
- **CP_Editor face à l'éditeur natif.** Sa raison d'exister est structurelle :
  il est le seul à pouvoir éditer un clip **sans item** (une lane, une case).
  La question ouverte est jusqu'où continuer à réécrire, sur un take, ce que
  REAPER fait déjà. Ma règle : sur un take, ne rien écrire que REAPER fasse
  correctement ; sur un clip sans take, tout écrire, parce qu'il n'y a personne
  d'autre.
- **Les lanes de CC.** Le plus grand trou de l'éditeur, identifié depuis
  longtemps. À faire d'abord sur CP_Editor, où le backend take écrit du vrai CC
  par l'API de REAPER sans changement de protocole. Côté clip, la note du
  moteur a **deux octets libres déjà réservés**.
