-- @description CP View — Session (met CP_Session a la place de l'arrangeur)
-- @version 1.0
-- @author Cedric Pamalio
--
-- Un lanceur : il nomme la vue, le raisonnement est dans CP_View.lua.
-- `section` est la cle ExtState sous laquelle l'application publie son
-- battement et son action ; `title` est le titre EXACT de sa fenetre gfx —
-- JS_Window_Find l'exige au caractere pres.
-- Bouton d'icone suggere : LayoutGrid, ou Grid3x3.

CP_VIEW = { section = "CP_Session", title = "CP Session" }
dofile(reaper.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Tools/CP_View.lua")
