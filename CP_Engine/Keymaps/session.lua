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

    -- ----- agir sur la case choisie ------------------------------------------
    -- Sur une case VIDE, lancer veut dire arreter la colonne : c'est ce qu'on
    -- veut dire en descendant une grille trouee, et c'est deja le comportement.
    { act = "cell.launch",      group = "Grid", k = Keys.ENTER,  mods = "",
      label = "Launch the cell (an empty cell stops the column)" },
    { act = "cell.erase",       group = "Grid", k = Keys.DELETE, mods = "",
      label = "Erase the cell" },

    -- ----- reparer -----------------------------------------------------------
    { act = "edit.undo",        group = "Edit", k = 26, mods = "Ctrl",
      label = "Put the last erased cell back" },
}
