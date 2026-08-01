# Installer la suite sur une autre machine

Réponse courte à « si je pull sur un autre PC, aura-t-il tout ce qu'il faut » :
**presque**. Les scripts, oui, entièrement. Le binaire, non — et c'est
délibéré : le dépôt ne contient pas de `.dll`, il contient sa **source** et de
quoi la construire en une commande.

---

## Ce qui voyage dans le dépôt

| | |
|---|---|
| tous les scripts Lua | oui — c'est le dépôt |
| le toolkit, les icônes, les thèmes | oui |
| **la source** du moteur natif (`CP_Native/src`) | oui |
| les scripts de construction et le harnais de test | oui |
| `reaper_cpclip.dll` | **non** (`CP_Native/.gitignore` : `build/`) |
| le SDK REAPER | **non** — dépendance fournisseur, licence tierce |
| tes réglages de fenêtres (`CP_Config/*.lua`) | **non** — volontairement non commités |

Un binaire dans un dépôt de scripts, c'est une version qui se désynchronise de
sa source sans le dire, et un fichier qu'aucun *diff* ne relit. La règle du
dossier est que le binaire se **reconstruit**, jamais qu'il se transporte.

---

## Sur la nouvelle machine, dans l'ordre

### 1. REAPER, et le dépôt à sa place

Le dépôt EST le dossier `Scripts/CP_Scripts` de REAPER :

```
%APPDATA%\REAPER\Scripts\CP_Scripts
```

Soit par ReaPack (`index.xml` à la racine du dépôt), soit par un `git clone`
directement à cette adresse. Les deux marchent ; le clone est ce qu'il faut
pour développer, parce que ReaPack installe des copies et pas un dépôt.

### 2. Les extensions dont la suite dépend

- **SWS/S&M** — indispensable (aperçu, actions, utilitaires)
- **js_ReaScriptAPI** — recommandé (fenêtres, glisser-déposer)
- **ReaPack** — seulement si tu passes par lui plutôt que par git

### 3. Le moteur natif — sans lui, la moitié se tait

**Ce que ça change de ne pas l'avoir** : les fenêtres s'ouvrent et le disent.
`Voice.Label()` rend `off`, le badge de CP_Session affiche `cells: silent`,
CP_Sampler affiche `pads: RS5K/broadcast`. Les cases audio de la Session ne
sonnent pas, les lanes MIDI non plus, et une note d'aperçu repart en *broadcast*
sur le clavier virtuel — le comportement d'avant le chantier 1. Rien ne plante,
rien ne s'efface : `Loop.SaveState` refuse d'écrire sans le moteur, exactement
pour que l'absence du binaire ne coûte pas un projet.

**Prérequis** : Visual Studio 2022 ou les **Build Tools**, composant
« Desktop development with C++ ». Les scripts trouvent l'installation par
`vswhere` — n'importe quelle édition, n'importe quel disque.

**Le SDK REAPER**, une fois, n'importe où :

```
git clone --depth 1 https://github.com/justinfrankel/reaper-sdk.git
```

Les scripts le cherchent dans cet ordre, et s'arrêtent au premier trouvé :

1. la variable d'environnement `REAPER_SDK` (elle gagne toujours) ;
2. `..\..\reaper-sdk\sdk` — c'est-à-dire à côté du dépôt cloné ;
3. `%USERPROFILE%\dev\reaper-sdk\sdk`.

**Construire**, depuis `CP_Native`, REAPER FERMÉ :

```
build_dll.cmd
```

Il vérifie les *defstrings* ReaScript, compile, copie la DLL dans
`%APPDATA%\REAPER\UserPlugins\` et te dit de redémarrer REAPER. Si REAPER
tourne, **il refuse proprement** au lieu d'écrire à moitié : une extension ne se
recharge pas à chaud, c'est la nature du format.

**Vérifier**, sans rien ouvrir d'autre :

```
build_test.cmd
```

Le harnais compile le cœur **hors REAPER** et rend un compte d'assertions. S'il
passe, le moteur est bon ; le reste est du montage.

### 4. Vérifier depuis REAPER

Ouvre CP_Session. Le badge de la zone de statut doit dire :

```
engine native 1.8 · cells: voices
```

`1.8` est la version de l'ABI, et elle est là **exprès** : la question qu'on se
pose vraiment est « REAPER a-t-il repris la DLL que je viens de construire ».
Si tu lis `off`, la DLL n'est pas chargée ou est plus ancienne que les scripts.

---

## Ce qui ne voyage PAS, et c'est voulu

`CP_Config/*.lua` — la taille de tes fenêtres, ton thème, tes préférences par
app. Ce sont **tes** réglages sur **cette** machine, pas du code. Le nouveau PC
part sur les valeurs par défaut, ce qui est la bonne façon de découvrir qu'une
valeur par défaut est mauvaise.

Le JSFX de choke (`Effects/CP_Scripts/cp_kit_choke.jsfx`) n'a pas besoin de
voyager non plus : `Kit.lua` le **génère** au premier kit, et le régénère si sa
version change. C'est une pièce dérivée, pas une source.

---

## Un projet ouvert sur une machine sans le moteur

Il s'ouvre. Ce qu'il contient est dans le `.RPP` : les pistes, les FX, les kits
(des RS5K dans une chaîne d'effets, que REAPER lit sans nous), et l'état de la
grille en `ProjExtState` — du texte, lisible par un REAPER qui n'a rien de tout
ceci installé.

Ce qui manque, c'est la **lecture** : les lanes et les cases audio. Elles sont
décrites dans le projet et personne ne les joue. Reconstruis la DLL et elles
reprennent, à la note près — c'était la raison de sortir l'état des pistes.
