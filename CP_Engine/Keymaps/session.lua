-- ---------------------------------------------------------------------------
-- LE VOCABULAIRE DE CP_SESSION — les liaisons en donnees
-- ---------------------------------------------------------------------------
-- Meme forme que `editor.lua` et `sampler.lua`. Le vocabulaire vit DEHORS parce
-- que la fenetre de reglages est un autre etat Lua : declaree dans le script,
-- une table de liaisons ne serait jamais vue par elle.
--
-- ---------------------------------------------------------------------------
-- POURQUOI SI PEU DE LIGNES
-- ---------------------------------------------------------------------------
-- Une grille de cases se joue a la SOURIS et au controleur, pas au clavier :
-- les fleches et Entree sont la pour qu'on puisse traverser la grille sans
-- lacher ce qu'on regle ailleurs, et non pour remplacer le clic. Ajouter des
-- raccourcis « parce qu'on peut » remplirait une page de reglages de choses que
-- personne n'apprendra.
--
-- Ctrl+Z est ici parce qu'il repare un geste DESTRUCTEUR : Alt+clic efface une
-- case a une seule main, et il lui fallait son retour. C'est le seul raccourci
-- de cette fenetre qui existe pour une raison qui n'est pas la commodite.
local Keys = dofile(reaper.GetResourcePath()
                    .. "/Scripts/CP_Scripts/CP_Toolkit/Keys.lua")

return {
    -- ----- traverser la grille -----------------------------------------------
    { act = "cell.prev_track",  group = "Grid", k = Keys.LEFT,  mods = "",
      label = "Previous column" },
    { act = "cell.next_track",  group = "Grid", k = Keys.RIGHT, mods = "",
      label = "Next column" },
    { act = "cell.prev_scene",  group = "Grid", k = Keys.UP,    mods = "",
      label = "Previous scene" },
    { act = "cell.next_scene",  group = "Grid", k = Keys.DOWN,  mods = "",
      label = "Next scene" },

    -- Ableton monte et descend de HUIT scenes avec Page Up / Page Down. Cette
    -- grille en a huit en tout, donc « huit scenes » y veut dire le haut et le
    -- bas de la colonne — le meme geste, ramene a la taille de l'objet. Inventer
    -- un saut de huit dans une grille de huit aurait rendu la touche inerte.
    { act = "cell.first_scene", group = "Grid", k = Keys.PAGE_UP,   mods = "",
      label = "Top of the column" },
    { act = "cell.last_scene",  group = "Grid", k = Keys.PAGE_DOWN, mods = "",
      label = "Bottom of the column" },

    -- ----- agir sur la case choisie ------------------------------------------
    -- Sur une case VIDE, lancer veut dire arreter la colonne : c'est ce qu'on
    -- veut dire en descendant une grille trouee, et c'est deja le comportement.
    { act = "cell.launch",      group = "Grid", k = Keys.ENTER,  mods = "",
      label = "Launch the cell (an empty cell stops the column)" },
    { act = "cell.erase",       group = "Grid", k = Keys.DELETE, mods = "",
      label = "Erase the cell" },

    -- ----- la scene entiere --------------------------------------------------
    -- LE GESTE QUI DESCEND UN SET. Chez Ableton on selectionne une scene, on
    -- tape Entree, et la selection AVANCE — donc taper Entree encore et encore
    -- joue le morceau. C'est cet enchainement qui compte, pas le lancement :
    -- sans l'avance, il faudrait une fleche entre chaque scene et le geste
    -- cesse d'etre jouable.
    { act = "scene.launch",     group = "Scene", k = Keys.ENTER, mods = "Shift",
      label = "Launch the whole scene, then step down one" },
    -- Le « +Scene » de FL, au clavier : les colonnes que cette scene ne remplit
    -- pas continuent de jouer. C'est ce qui laisse une nappe survivre a un
    -- changement de scene sans etre recopiee dans les huit lignes.
    { act = "scene.launch_add", group = "Scene", k = Keys.ENTER, mods = "Ctrl",
      label = "Launch the scene ADDITIVELY (unfilled columns keep playing)" },
    -- Ableton : Ctrl+Shift+I. Ce qui joue devient une ligne, sans coupure.
    { act = "scene.capture",    group = "Scene", k = 9, mods = "Ctrl+Shift",
      label = "Capture what is playing into the first empty scene row" },

    -- ----- reparer -----------------------------------------------------------
    { act = "edit.undo",        group = "Edit", k = 26, mods = "Ctrl",
      label = "Put the last erased cell back" },
}
