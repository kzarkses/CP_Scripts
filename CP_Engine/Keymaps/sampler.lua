-- ---------------------------------------------------------------------------
-- LE VOCABULAIRE DE CP_SAMPLER — les liaisons en donnees
-- ---------------------------------------------------------------------------
-- Meme forme que `editor.lua`, et pour la meme raison : le vocabulaire vit
-- DEHORS parce que la fenetre de reglages est un autre etat Lua et ne verrait
-- rien de ce que le script aurait enregistre chez lui.
--
-- Ce fichier ne contient que des donnees : pas un dessin, pas un appel, rien
-- qui suppose un hote.
--
-- ---------------------------------------------------------------------------
-- CE QUI N'EST PAS ICI, ET POURQUOI
-- ---------------------------------------------------------------------------
-- Le sampler n'a pas de gestes de souris declares. Ses zones sont des pads et
-- des boutons — des widgets du toolkit, qui portent deja leur comportement — et
-- non une grille continue ou le meme geste veut dire trois choses selon
-- l'endroit. Declarer un contexte de souris vide pour faire comme l'editeur
-- aurait donne une page de reglages qui ne regle rien.
--
-- ESPACE EST DECLARE ICI, mais il ne joue pas forcement ici : `CP_Engine/
-- Focus.lua` le donne au module qui mene (CP_Editor d'abord, puis celui-ci).
-- La liaison reste la sienne — c'est bien cette fenetre qui recoit la frappe —
-- et c'est la raison de la voir dans cette page plutot que dans une autre.
local Keys = dofile(reaper.GetResourcePath()
                    .. "/Scripts/CP_Scripts/CP_Toolkit/Keys.lua")

return {
    -- ----- se deplacer dans la grille de pads --------------------------------
    { act = "pad.prev",    group = "Pads", k = Keys.LEFT,  mods = "",
      label = "Previous pad" },
    { act = "pad.next",    group = "Pads", k = Keys.RIGHT, mods = "",
      label = "Next pad" },
    { act = "pad.up",      group = "Pads", k = Keys.UP,    mods = "",
      label = "Pad one row up" },
    { act = "pad.down",    group = "Pads", k = Keys.DOWN,  mods = "",
      label = "Pad one row down" },

    -- ----- agir sur le pad choisi -------------------------------------------
    { act = "pad.trigger", group = "Pads", k = Keys.ENTER, mods = "",
      label = "Play the selected pad" },
    { act = "pad.clear",   group = "Pads", k = Keys.DELETE, mods = "",
      label = "Clear the selected pad" },

    -- ----- les pages ---------------------------------------------------------
    { act = "page.next",   group = "Pages", k = Keys.PAGE_UP,   mods = "",
      label = "Next page of pads" },
    { act = "page.prev",   group = "Pages", k = Keys.PAGE_DOWN, mods = "",
      label = "Previous page of pads" },
    { act = "page.1",      group = "Pages", k = Keys.N1, mods = "", label = "Page 1" },
    { act = "page.2",      group = "Pages", k = Keys.N2, mods = "", label = "Page 2" },
    { act = "page.3",      group = "Pages", k = Keys.N3, mods = "", label = "Page 3" },
    { act = "page.4",      group = "Pages", k = Keys.N4, mods = "", label = "Page 4" },

    -- ----- le transport, qui n'est pas forcement le sien ---------------------
    { act = "play.toggle", group = "Transport", k = Keys.SPACE, mods = "",
      label = "Play / stop (goes to CP Editor when it is open)" },
}
