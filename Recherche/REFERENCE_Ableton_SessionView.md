# La Session View d'Ableton Live 11/12 — référence vérifiée

Établie par lecture du manuel officiel Live 12 (et Live 11 quand la version diffère), du Live Object Model, et de la page des raccourcis. Chaque point porte sa marque. Les URL complètes sont en fin de document.

---

## 0. Ce que les documents CP disent déjà, et les deux corrections

`ANALYSE_Ableton_Session.md` et `ANALYSE_SessionView.md` couvrent déjà l'essentiel et sont globalement **exacts**. Deux affirmations sont fausses ou incomplètes, et elles ont été recopiées dans le code :

**(a) « le lancement de scène arrête les pistes dont la cellule est vide »** — `ANALYSE_Ableton_Session.md:102-103` et le texte d'aide `CP_Session/CP_Session.lua:124` (« tracks with no clip in it stop, as in Ableton »).

Ce n'est pas le mécanisme d'Ableton. Le mécanisme réel est un **bouton Stop posé dans la case**, présent par défaut, et **retirable case par case** :

> « You can add and remove Clip Stop buttons from the grid using the Edit menu's Add/Remove Stop Button command. This is useful for pre-configuring the scene launch behavior: If, for instance, you don't want scene 3 to affect track 4, remove the scene 3/track 4 Stop button. » — *vérifié (manuel L11, Session View)*

La différence n'est pas cosmétique : c'est **la seule façon** de laisser un pad ou une nappe tourner à travers plusieurs scènes. Sans ça, toute case vide devient un couperet et on est obligé de dupliquer le clip dans chaque scène. Ce que le doc CP appelle « la cellule de stop, un petit plus » (`ANALYSE_Ableton_Session.md:122`) est en réalité **l'inverse** : le stop est le défaut, et c'est *son absence* qui est la fonctionnalité.

**(b) « Follow Actions : No Action, Stop, Play Again, Previous, Next, First, Last, Any, Other »** — `ANALYSE_Ableton_Session.md:86-87`. Il en manque une (**Jump**, avec sa cible), le « curseur A:B » décrit à la ligne 88 n'existe plus (ce sont deux pourcentages indépendants depuis Live 11), et le mode Linked décrit comme « l'action tombe à la fin du clip » (ligne 89) est en fait le **défaut**, pas une option récente, et il se double d'un **multiplicateur en nombre de boucles**.

---

## 1. La grille

*Toute cette section : vérifié (manuel L12, Session View), sauf mention contraire.*

- **Colonne = piste.** Verbatim : « Each vertical column, or track, can play only one clip at a time. »
- **Ligne = scène.** « The horizontal rows are called scenes. »
- **Cellule = clip slot**, avec ou sans clip.
- **Bouton de lancement** : un **triangle** au bord gauche de la cellule. « Click the button with the mouse to 'launch' clip playback at any time, or pre-select a clip by clicking on its name, and launch it using the computer's Enter key. »
- **Bouton stop** : un **carré**. « Click on a square Clip Stop button to stop a running clip, either in one of the track's slots, or in the Track Status field below the Session grid. » (*L11*)
- **Ajout/retrait du bouton stop** : commande `Add/Remove Stop Button` du menu Edit, raccourci **Ctrl+E**. Voir §0.
- **Bouton de scène** : colonne la plus à droite, sur la piste **Main** (renommée depuis « Master »). « To launch every clip in a row simultaneously, click on the associated Scene Launch button. » (*L11*)
- **Stop All Clips** : dans le Track Status field de la piste Main.
- **Renommage de scène** : commande `Rename` du menu Edit ou du menu contextuel. Raccourci **Ctrl+R**.
- **Insert Scene** (Ctrl+I) : « inserts an empty scene below the current selection ».
- **Capture and Insert Scene** (Ctrl+Shift+I) : « inserts a new scene below the current selection, places copies of the clips that are currently running in the new scene and launches the new scene immediately **with no audible interruption**. » — c'est le geste « je viens de trouver une combinaison en jouant, fige-la en scène ».
- **Déplacement de clips** : « Clips can be moved around the Session grid by drag-and-drop. To move several clips at once, select them by using the Shift or Ctrl / Cmd modifier before dragging. »
- **Couleur** : « Newly created clips use the same color as the track on which they're created » (*vérifié, manuel L12 Clip View*). Modifiable par clip.

### Tempo et signature par scène

- **Live 11** : contrôles dédiés, révélés en tirant le bord gauche du header de la piste Master — « Dragging the left edge of the Master track's title header reveals the Scene Tempo and Scene Time Signature controls. » (*vérifié, manuel L11*)
- **Live 12** : les mêmes valeurs se règlent dans la **Scene View** (double-clic sur le header de scène) — « In the upper section of the Scene View, the Tempo and Signature sliders allow you to edit tempo and time signature values for the selected scene(s). » (*vérifié, manuel L12*)
- Effet : « The project will automatically adjust to these parameters when the scene is launched. » Une scène porteuse d'un tempo a un **bouton de lancement coloré**.
- Réinitialisation : `Return to Default` du menu contextuel, ou touche Delete. (*vérifié faiblement, article d'aide Ableton relayé par recherche*)
- Historique : avant Live 11, le tempo se mettait **dans le nom** de la scène. La trace est restée dans le manuel L12, section enregistrement vers l'arrangement : « Tempos and time signature changes, **if they are included in the names of launched scenes** » — les deux mécanismes coexistent donc encore.

### Le Track Status field (la ligne sous la grille)

*Vérifié (manuel L12 + L11).* C'est le seul endroit qui donne l'**avancement** :

- **Icône camembert** = clip de session **en boucle**. « The number to the right of the circle is the loop length in beats, and the number at the left represents **how many times the loop has been played since its launch**. »
- **Icône barre de progression** = clip **one-shot** (Loop désactivé). La valeur affiche « the remaining play time in **minutes:seconds** ».
- **Miniature d'arrangement** = la piste joue l'Arrangement.

C'est le détail le plus sous-estimé de la Session View : à un coup d'œil on sait *combien de fois* une boucle a tourné et *combien de temps* il reste au one-shot — donc quand relancer, sans compter dans sa tête.

---

## 2. Le lancement

### 2.1 Quantisation

- **Liste exacte des valeurs** de la quantisation de lancement globale, *vérifié via le Live Object Model* (`Song.clip_trigger_quantization`, docs Cycling '74) :
  `0 None · 1 8 Bars · 2 4 Bars · 3 2 Bars · 4 1 Bar · 5 1/2 · 6 1/2T · 7 1/4 · 8 1/4T · 9 1/8 · 10 1/8T · 11 1/16 · 12 1/16T · 13 1/32`
  Quatorze valeurs, **avec les triolets**, et **rien au-delà de 8 mesures**.
- **Défaut = 1 Bar** : *de mémoire*. Je n'ai trouvé aucune source primaire l'énonçant ; le manuel ne le dit pas dans les chapitres consultés. À ne pas citer comme vérifié.
- **Raccourcis** (*vérifié, page raccourcis L12*) : Ctrl+6 = 1/16, Ctrl+7 = 1/8, Ctrl+8 = 1/4, Ctrl+9 = 1 Bar, Ctrl+0 = Quantization Off. **Cinq valeurs seulement sont au clavier** — celles qu'on change en jouant.
- **Par clip** : chooser `Launch Quantization` avec « None », « Global », ou une valeur propre. (*vérifié, L12 + L11*)
- Précision utile : « any setting other than 'None' will quantize the clip's launch **when it is triggered by Follow Actions** » (*vérifié*) — la quantisation par clip s'applique donc aussi aux enchaînements automatiques, pas seulement aux clics.

### 2.2 Les quatre modes de lancement

*Vérifié, verbatim (manuel L12 et L11, identiques) :*

| Mode | Texte du manuel |
|---|---|
| **Trigger** | « down starts the clip; up is ignored » |
| **Gate** | « down starts the clip; up stops the clip » |
| **Toggle** | « down starts the clip; up is ignored. The clip will stop on the next down » |
| **Repeat** | « As long as the mouse switch/key is held, the clip is triggered repeatedly **at the clip quantization rate** » |

Le défaut d'usine est **Trigger**, réglable par `Default Launch Mode` dans les préférences Record/Warp/Launch (*vérifié faiblement : documentation Ableton relayée par recherche, pas de fetch direct de la page de préférences — voir §7*).

Note sur Repeat : le taux de répétition **est** la quantisation du clip. Un clip en Repeat + quantisation 1/16 devient un roulement ; c'est un bégayeur gratuit, pas un mode de lancement anecdotique.

### 2.3 Legato

*Vérifié (L12 + L11), verbatim :* le clip lancé « takes over the play position from whatever clip was played in that track before ». Le manuel ajoute que le **Clip RAM Mode** évite les décrochages quand les clips utilisent des samples différents.

C'est bien, comme le dit le doc CP, la commande « démarrer à une phase donnée ». Détail que le doc CP ne mentionne pas : Legato est un **réglage du clip qui arrive**, pas du clip qui part.

### 2.4 Velocity Amount

*Vérifié, verbatim :* « the effect of MIDI note velocity on the clip's volume: If set to zero, there is no influence; at 100 percent, the softest notes play the clip silently. » Sert quand les clips sont mappés sur des notes MIDI (voir §6, mapping chromatique).

### 2.5 Follow Actions

*Vérifié (manuel L12, chapitre Launching Clips).*

**Les dix actions** : `No Action`, `Stop`, `Restart`, `Previous`, `Next`, `First`, `Last`, `Any`, `Other`, `Jump`.
Le manuel **L11** liste la troisième sous le nom **« Play Again »** ; le manuel **L12** l'appelle **« Restart »**. Même action, renommée. (*vérifié : les deux manuels, aux deux URL*)

- **Jump** : « lets you select a target clip slot or scene for the Follow Action to jump to. » Un **Jump Target slider** apparaît à côté du chooser ; on le tire ou on tape un numéro.
- **A et B avec Chance** : « set the probability (in a percentage) that each Follow Action will be triggered ». Ce sont **deux pourcentages indépendants**, pas un ratio — « Chance A set to 100% and Chance B set to 0% » garantit A ; « 0% means that an action will never happen ».
- **Linked / Unlinked** :
  - **Linked (défaut)** : l'action tombe « at the end of the clip, or after the number of loops set in the **Follow Action Multiplier** field ». Le multiplicateur en nombre de boucles est le mécanisme que le doc CP ne mentionne pas.
  - **Unlinked** : l'action tombe « after the clip has played for the duration of the **Follow Action Time** ».
- **Follow Action Time** : « defines when the Follow Action takes place in **bars-beats-sixteenths** from the point in the clip or scene where play starts. **The default for this setting is one bar.** »
- **Le groupe** : « A group is defined by clips arranged in **successive slots of the same track** » — les groupes sont délimités par les **cases vides**. C'est ce qui donne un sens à Previous/Next/First/Last/Any/Other : ils s'appliquent au groupe, pas à la piste entière. Point essentiel, absent du doc CP.
- **Enable Follow Actions Globally** : un bouton (voisin de Back to Arrangement) qui « lets you enable or disable **all clip and scene** Follow Actions in the Live Set ». Grisé s'il n'y a aucune follow action. Sa raison d'être : « By disabling [it], you can **edit running clips without being interrupted** by playback jumping to other clips. » — indispensable dès que les follow actions existent.
- **Repère visuel** : les clips et scènes porteurs d'une follow action ont un **bouton de lancement rayé** (« striped Clip/Scene Launch button »).
- **Raccourci** : Shift+Enter active/désactive la follow action du clip sélectionné.

**Follow actions de scène** : elles existent **depuis Live 11**, pas Live 12 (*vérifié : manuel L11, chapitre Launching Clips*). Édition par double-clic sur la scène (Scene View). Règle de priorité, verbatim : « Follow Actions in clips will continue to run when a scene Follow Action is created or scheduled, however **Follow Actions in scenes always take precedence once they are triggered.** »

---

## 3. Les propriétés d'un clip

*Vérifié (manuel L12, Clip View).* La Clip View est « a title bar and two sections: clip panels on the left and an editor on the right ».

**Barre de titre** : `Clip Activator` (« deactivate a clip so that it does not play when launched » — un mute par clip, différent du stop), `Clip Name`, `Clip Color`, `Save Default Clip` (audio seulement : mémorise les réglages avec le sample).

**Panneau principal** : Start/End markers (champs numériques), `Clip Loop` toggle, `Loop Position` / `Loop Length`, `Time Signature` par clip, `Groove` chooser, contrôles de gamme (tonique + nom de gamme, pour les devices scale-aware — Live 12).

**Panneau étendu** : « this panel shows the clip launch controls **only when a Session View clip is selected** ». Plus, pour le MIDI, les bank/program change.

Le **start marker** et la **loop brace** sont distincts : on peut démarrer avant la boucle et retomber dedans.

### Warp

*Vérifié (manuel L12, Audio Clips, Tempo and Warping).*

- **Warp switch** : désactivé, le clip joue à son tempo d'origine, insensible au tempo du set.
- **Warp markers** : double-clic dans la zone haute du Sample Editor ; suppression par double-clic ou Backspace/Delete ; Shift+drag pour décaler la forme d'onde sous un marqueur.
- **Transitoires** : détectés automatiquement, affichés en petits repères gris ; `Reset Transients` au menu contextuel.
- **Les modes et leurs paramètres** :
  - **Beats** — `Preserve` (Transients, ou une division de grille), `Transient Loop Mode` (Loop Off / Loop Forward / Loop Back-and-Forth), `Transient Envelope` (0–100).
  - **Tones** — `Grain Size`.
  - **Texture** — `Grain Size`, `Fluctuation`.
  - **Re-Pitch** — change la vitesse de lecture ; **les contrôles de transposition sont désactivés**.
  - **Complex** / **Complex Pro** — `Formants` (0–100 %, 100 % préserve l'original), `Envelope` (défaut **128**).
- **BPM d'origine** : champ éditable, boutons **×2 / ÷2**.
- **Lead/Follow** : par défaut un clip warpé suit le tempo du set ; en Arrangement il peut passer en **Lead** et imposer son tempo au set.
- **Audio Utilities** : Clip Gain, transposition, `Hi-Q` (interpolation haute qualité), `RAM` mode, fades.

Ranges numériques (Transpose en demi-tons, Detune en cents, Clip Gain en dB) : **non vérifiés**, le manuel ne les énonce pas dans les chapitres consultés.

### Enveloppes de clip

*Vérifié (manuel L12, Clip Envelopes).*

- « Every clip in Live can have its own clip envelopes. »
- **Audio** : Transposition, Gain, **Sample Offset**, paramètres des effets de la piste, contrôles de mixer.
- **MIDI** : mode `MIDI Ctrl` (données de contrôleur), paramètres de device, mixer.
- **Linked** : l'enveloppe suit la région/boucle du clip et « respond to changes in the clip's Warp Markers ».
- **Unlinked** : « A clip envelope can have its own local loop/region settings » — switch de boucle propre, longueur numérique propre, start/end propres. **C'est de la polyrythmie gratuite** : une enveloppe de 3 mesures sur un clip de 4.
- **Sample Offset** : disponible **uniquement en mode Beats**, module la position de lecture — le bégayeur/beat-repeat du pauvre, sans effet.

### Groove

*Vérifié (manuel L12, Using Grooves).*

- Groove Pool (Ctrl+Alt+6), chooser de groove par clip, **hot-swap** pendant que le clip joue.
- Paramètres : `Base` (résolution de référence), `Quantize` (quantisation droite appliquée **avant** le groove), `Timing`, `Random`, `Velocity` (−100 à +100, les négatifs inversent), `Global Amount` (jusqu'à **130 %**).
- **Marche sur l'audio comme sur le MIDI** : sur l'audio il agit sur le warp, donc **Warp doit être actif**.
- `Commit` : « For MIDI clips, this moves the notes accordingly. For audio clips, this creates Warp Markers at the appropriate positions. »

---

## 4. L'enregistrement en session

*Vérifié (manuel L12, Recording New Clips).*

- **Arm** : « Clicking one track's Arm button unarms all other tracks unless the Ctrl / Cmd modifier is held. » (arm exclusif par défaut). Avec plusieurs pistes sélectionnées, armer l'une arme les autres.
- **Clip Record buttons** : « Clip Record buttons will appear in the empty slots of the armed tracks. » — le rond n'apparaît que sur les pistes armées.
- **Session Record** (Ctrl+Shift+F9) : « record into the **selected scene** in all armed tracks ». Puis : « To go from recording immediately into loop playback, press the Session Record button again » et « Subsequent presses of the Session Record button will toggle between playback and overdub ». C'est un cycle à trois temps : rec → lecture → overdub → lecture → overdub…
- **Longueur du clip** : « Set the Global Quantization chooser to any value other than 'None' to obtain correctly cut clips. » **Il n'y a pas de champ « longueur de prise » dans Live** : c'est la quantisation globale qui découpe. (Le « Fixed Length » est une fonction de **Push**, pas de Live — *de mémoire, non vérifié*.)
- **Record Quantization** : chooser dans le menu Edit ; « the Record Quantization setting **cannot be changed mid-recording** » pour l'enregistrement session et arrangement. La liste exacte des valeurs : **non vérifiée**.
- **Count-in** : « set via the pull-down menu next to the Metronome switch. When set to any value other than 'None', Live will not begin recording until the count-in is complete. » Il court en mesures négatives jusqu'à 1.1.1.
- **Overdub MIDI** : « overdubbing only applies to MIDI tracks ».
- **Comportement par défaut à noter** : « by default, launching a Session View scene **will not** activate recording in empty record-enabled slots belonging to that scene. » (réglable — `Start Recording on Scene Launch` dans les préférences, *nom vérifié faiblement*).

### Capture MIDI

*Vérifié (manuel L12).* Live écoute en permanence les pistes armées ou en monitoring d'entrée.

- **Set neuf** : « Capture MIDI will detect and adjust the song tempo, set appropriate loop boundaries and place the played notes on the grid » ; la détection de tempo opère **dans la plage 80–160 BPM** ; le transport démarre aussitôt.
- **Set existant / transport en marche** : « Capture MIDI will **not** detect or adjust the song tempo. Instead, Capture MIDI will use the existing tempo to detect a meaningful musical phrase. » Overdub possible en rejouant par-dessus un clip existant de la même piste.
- Sur Push 2 : maintenir Record et presser New.
- Aucun raccourci clavier dédié listé dans la table des raccourcis L12 (le Ctrl+Shift+C souvent cité est *de mémoire*, **non confirmé** par la page des raccourcis).

---

## 5. Session ↔ Arrangement

*Vérifié (manuel L12, Session View §7.5) — verbatim, c'est la liste exhaustive :*

> « When the Arrangement Record button is on, Live logs all of your actions into the Arrangement:
> - The clips launched;
> - Changes of those clips' properties;
> - Changes of the mixer and the devices' controls, also known as automation;
> - Tempos and time signature changes, if they are included in the names of launched scenes. »

- Fin : « press the Arrangement Record button again, or stop playback ».
- Résultat : « Live has copied the clips you launched during recording into the Arrangement, in the appropriate tracks and the correct song positions. Notice that your recording has **not created new audio data, only clips**. » — c'est un **journal de références**, pas un rendu. Point capital : la performance reste ré-éditable clip par clip.
- **Exclusivité** : « The Session clips and the Arrangement clips in one track are mutually exclusive: Only one can play at a time. » Lancer un clip de session coupe l'arrangement **sur cette piste seulement**.
- **Back to Arrangement** (F10) : « Arrangement playback does not resume until you explicitly tell Live to resume by clicking the Back to Arrangement button, which appears in the Arrangement View and **lights up to remind you that what you hear differs from the Arrangement**. »
- **Sens inverse** : « Copy and Paste, by dragging clips over the [view] selectors, or by simply dragging clips between the two windows. » Et : « When pasting Arrangement material into Session View, Live attempts to **preserve the temporal structure** of the clips by laying them out in a matching top-to-bottom order. » — coller 8 mesures d'arrangement produit une pile de scènes cohérente, pas un tas.

---

## 6. Ce qui rend la Session agréable — les micro-comportements

C'est la partie que les listes de fonctions ratent, et c'est celle qui décide si une grille est jouable.

**Ce qui est visible sans rien ouvrir** *(vérifié, §1)* : le camembert avec le **nombre de tours déjà joués**, la barre de progression avec le **temps restant** du one-shot, le bouton de scène **coloré** s'il porte un tempo, le bouton **rayé** s'il porte une follow action, Back to Arrangement qui **s'allume** dès que ce qu'on entend diffère de l'arrangement. Cinq états structurels, cinq signaux distincts, aucun texte à lire.

Le clignotement du bouton pendant l'attente de quantisation : *vérifié faiblement (sources tierces, remotify.io et forum Ableton — « a flashing green arrow means that the clip will be played once the quantization value you selected will be reached »)*. Le manuel officiel ne le décrit pas dans les chapitres consultés.

**Ce qui se fait sans souris** *(vérifié, page raccourcis L12 + chapitre Accessibility)* :

- Flèches = déplacer la sélection dans la grille ; **Page Up/Down = huit scènes d'un coup**.
- **Enter** = lancer le clip ou la scène sélectionné.
- **Select Next Scene on Launch** : « The scene below a launched scene will automatically be selected as the next to be launched unless the [option] in the Record/Warp/Launch Preferences is set to 'Off.' » (*vérifié faiblement, manuel relayé par recherche*). Conjugué à Enter, **on descend tout un set en tapant Enter**, sans jamais viser une case. C'est le geste de performance le plus rentable de toute la Session View.
- **Select on Launch** : « By default, clicking a Session View clip's Launch button also selects the clip » — désactivable, pour que jouer ne déplace pas ce qu'on est en train d'éditer.
- Tab = bascule Session/Arrangement. Tab/Shift+Tab = descendre dans le mixer de la piste ; Ctrl+Tab = même contrôle sur la piste suivante ; **Esc = remonter au header de piste**.
- Ctrl+Shift+M insère un clip MIDI vide dans la case focalisée.
- Ctrl+D dupliquer, Ctrl+R renommer, Ctrl+E ajouter/retirer le bouton stop, Ctrl+I insérer une scène, Ctrl+Shift+I capturer et insérer, F10 Back to Arrangement, F9 Record, Espace play/stop, Ctrl+L loop brace.
- Ctrl+M et Ctrl+K entrent en mode mapping MIDI / clavier : **n'importe quelle case et n'importe quelle scène deviennent assignables**. Et : « [Clips] can even be mapped to MIDI note ranges so that they play chromatically » (*vérifié, Session View*) — une rangée de clips devient un instrument, et c'est là que sert le Velocity Amount du §2.4.

**Les trois comportements qui font la différence à l'usage, et qu'on ne devine pas d'une capture d'écran :**

1. **Capture and Insert Scene** — figer sans couper le son ce qu'on vient de trouver en tâtonnant. C'est l'anti-« j'avais un truc bien et je l'ai perdu ».
2. **Enable Follow Actions Globally** — pouvoir éditer pendant que ça tourne sans que la machine saute ailleurs. Toute grille avec des follow actions a besoin de cet interrupteur, sinon elle devient inéditable.
3. **Retirer le bouton stop d'une case vide** — décider qu'une piste ignore une scène. C'est le seul moyen d'avoir des couches qui persistent à travers des sections.

---

## 7. Ce que je n'ai PAS pu vérifier

À ne pas citer comme acquis :

- **La valeur par défaut de la quantisation globale** (1 Bar) — aucune source primaire trouvée.
- **La liste exacte des valeurs de Record Quantization** et son défaut.
- **La page « Record, Warp & Launch » des préférences** : elle est dans le chapitre First Steps (§2.3.9) du manuel L12, mais la page est trop longue pour être extraite ; seul le texte d'introduction est accessible (« The Record, Warp & Launch Settings allow customizing the default state for new Live Sets and their components, as well as selecting options for new recordings »). Les noms `Default Launch Mode` (défaut Trigger), `Default Launch Quantization`, `Select Next Scene on Launch`, `Start Recording on Scene Launch`, `Exclusive Arm`, `Clip Update Rate`, `Start Playback with Record` sont **attestés par la documentation Ableton relayée en recherche**, mais leurs valeurs par défaut ne le sont pas.
- **Les plages numériques** de Transpose, Detune, Clip Gain.
- **Le clignotement** du bouton en attente (source tierce seulement).
- **Fixed Length** : je le crois exclusif à Push. Non vérifié.
- **Live 12.2** apporte les Follow Actions **sur Push** (*vérifié faiblement, blog Ableton*) ; je n'ai trouvé **aucune** modification de la Session View elle-même en 12.1/12.2/12.3. Les nouveautés L12 recensées (MIDI Transformations, MIDI Generators, Bounce to New Track, Performance Pack) sont hors Session View.

---

## 8. Deux points de calibrage pour la comparaison à venir

Grounded sur le code, à titre de repères seulement :

- **CP n'a qu'une quantisation de lancement GLOBALE.** `CP_Engine/Loop.lua:575-576` (`Loop.SetLaunchQ` / `Loop.GetLaunchQ`, une seule valeur côté moteur natif), réglée depuis `CP_Session/CP_Session.lua:406-432`, initialisée à une mesure en `Loop.lua:502-505`. La surcharge par clip du §2.1 n'existe pas.
- **Le nombre de scènes est figé à 8** : `CP_Session/CP_Session.lua:72` (`local SCENES = 8`). Ableton n'a pas de limite comparable.

---

## Sources

- [Session View — manuel Live 12](https://www.ableton.com/en/live-manual/12/session-view/)
- [Launching Clips — manuel Live 12](https://www.ableton.com/en/live-manual/12/launching-clips/)
- [Clip View — manuel Live 12](https://www.ableton.com/en/live-manual/12/clip-view/)
- [Audio Clips, Tempo, and Warping — manuel Live 12](https://www.ableton.com/en/live-manual/12/audio-clips-tempo-and-warping/)
- [Recording New Clips — manuel Live 12](https://www.ableton.com/en/live-manual/12/recording-new-clips/)
- [Clip Envelopes — manuel Live 12](https://www.ableton.com/en/live-manual/12/clip-envelopes/)
- [Using Grooves — manuel Live 12](https://www.ableton.com/en/live-manual/12/using-grooves/)
- [Live Keyboard Shortcuts — manuel Live 12](https://www.ableton.com/en/live-manual/12/live-keyboard-shortcuts/)
- [Accessibility and Keyboard Navigation — manuel Live 12](https://www.ableton.com/en/live-manual/12/accessibility-and-keyboard-navigation/)
- [First Steps (préférences, §2.3.9) — manuel Live 12](https://www.ableton.com/en/live-manual/12/first-steps/)
- [Session View — manuel Live 11](https://www.ableton.com/en/live-manual/11/session-view/)
- [Launching Clips — manuel Live 11](https://www.ableton.com/en/live-manual/11/launching-clips/)
- [LOM — The Live Object Model, Max 8 (Cycling '74)](https://docs.cycling74.com/legacy/max8/vignettes/live_object_model)
- [Updates to Follow Actions in Live 11 — Ableton Help](https://help.ableton.com/hc/en-us/articles/360019101360-Updates-to-Follow-Actions-in-Live-11) (403 au fetch direct ; contenu obtenu via recherche)
- [Live 12.2 — blog Ableton](https://www.ableton.com/en/blog/live-12-2/)
- [Ableton Clips Not Launching In Time? — remotify.io](https://remotify.io/ableton-clips-not-launching-in-time/) (source tierce, pour le clignotement)