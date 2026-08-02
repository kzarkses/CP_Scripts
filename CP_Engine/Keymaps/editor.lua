-- ---------------------------------------------------------------------------
-- LE VOCABULAIRE DE GESTES — la table des modificateurs de REAPER, en donnees
-- ---------------------------------------------------------------------------
-- Releve sur la config de Cedric (Preferences > Editing Behavior > Mouse
-- Modifiers, contextes MIDI) et reproduit FIDELEMENT, y compris la ou REAPER
-- n'est pas coherent avec lui-meme : Shift ignore le magnetisme sur une note
-- et sur la grille, mais c'est Ctrl qui l'ignore sur la REGLE. On ne corrige
-- pas ca. Le geste que ses doigts connaissent vaut mieux qu'une regle propre
-- qu'il faudrait reapprendre — et le jour ou il pense autrement, c'est une
-- ligne de ce tableau, plus une ligne de code.
--
-- Ce que ce tableau CHANGE par rapport a l'ancien editeur : « ignorer le
-- magnetisme » passe de Ctrl a Shift, et « ajouter a la selection » de Shift a
-- Ctrl. Les deux suivent REAPER, et la premiere aligne enfin le piano roll sur
-- la vue d'onde de cette meme fenetre, qui lit Shift depuis toujours
-- (`waveSnap`). Il y avait donc DEUX conventions dans un seul editeur.
--
-- `ctx` nomme la zone sous le pointeur, `g` le geste brut. Un meme
-- modificateur porte souvent le clic ET le glisser (Alt efface une note, Alt
-- glisse en efface plusieurs) : ce sont deux lignes, parce que ce sont deux
-- actions, et parce qu'on doit pouvoir les separer.
--
-- ---------------------------------------------------------------------------
-- POURQUOI CE FICHIER EST DEHORS
-- ---------------------------------------------------------------------------
-- Le vocabulaire etait declare DANS CP_Editor, et c'etait le seul obstacle
-- reel a une fenetre de reglages : une fenetre separee est un autre etat Lua,
-- elle ne voit rien de ce que l'editeur a enregistre chez lui. Elle aurait donc
-- affiche une liste vide, ou — pire — une copie de la liste, qui aurait diverge
-- au premier ajout.
--
-- Ici, l'application et la fenetre chargent LE MEME fichier. Il ne contient que
-- des donnees : pas un dessin, pas un appel, rien qui suppose un hote.
local Keys = dofile(reaper.GetResourcePath()
                    .. "/Scripts/CP_Scripts/CP_Toolkit/Keys.lua")

return {
    -- ----- une note, au clic ------------------------------------------------
    { act = "note.select",         group = "Note", ctx = "note", g = "click", mods = "",
      label = "Select note" },
    { act = "note.select_range",   group = "Note", ctx = "note", g = "click", mods = "Shift",
      label = "Add a range of notes to the selection" },
    { act = "note.select_toggle",  group = "Note", ctx = "note", g = "click", mods = "Ctrl",
      label = "Toggle note selection" },
    { act = "note.erase",          group = "Note", ctx = "note", g = "click", mods = "Alt",
      label = "Erase note" },
    { act = "note.select_measure", group = "Note", ctx = "note", g = "click", mods = "Shift+Alt",
      label = "Select all notes in the measure" },
    { act = "note.select_to_end",  group = "Note", ctx = "note", g = "click", mods = "Ctrl+Alt",
      label = "Select this note and all later notes" },
    { act = "note.len_double",     group = "Note", ctx = "note", g = "click", mods = "Shift+Win",
      label = "Double note length" },
    { act = "note.len_halve",      group = "Note", ctx = "note", g = "click", mods = "Ctrl+Win",
      label = "Halve note length" },
    -- ----- une note, au glisser ---------------------------------------------
    { act = "note.move",           group = "Note", ctx = "note", g = "drag", mods = "",
      label = "Move note" },
    { act = "note.move_free",      group = "Note", ctx = "note", g = "drag", mods = "Shift",
      label = "Move note ignoring snap" },
    { act = "note.copy",           group = "Note", ctx = "note", g = "drag", mods = "Ctrl",
      label = "Copy note" },
    { act = "note.move_axis",      group = "Note", ctx = "note", g = "drag", mods = "Shift+Ctrl",
      label = "Move note on one axis only" },
    { act = "note.erase_drag",     group = "Note", ctx = "note", g = "drag", mods = "Alt",
      label = "Erase notes" },
    { act = "note.stretch_pos",    group = "Note", ctx = "note", g = "drag", mods = "Ctrl+Win",
      label = "Stretch note positions (arpeggiate)" },
    -- ----- le bord d'une note -----------------------------------------------
    { act = "edge.resize",         group = "Note edge", ctx = "edge", g = "drag", mods = "",
      label = "Move note edge" },
    { act = "edge.resize_free",    group = "Note edge", ctx = "edge", g = "drag", mods = "Shift",
      label = "Move note edge ignoring snap" },
    { act = "edge.resize_solo",    group = "Note edge", ctx = "edge", g = "drag", mods = "Ctrl",
      label = "Move note edge ignoring selection" },
    { act = "edge.stretch",        group = "Note edge", ctx = "edge", g = "drag", mods = "Alt",
      label = "Stretch notes" },
    { act = "edge.stretch_free",   group = "Note edge", ctx = "edge", g = "drag", mods = "Shift+Alt",
      label = "Stretch notes ignoring snap" },
    -- ----- la grille vide ---------------------------------------------------
    { act = "roll.insert",         group = "Grid", ctx = "roll", g = "click", mods = "",
      label = "Insert note" },
    { act = "roll.deselect",       group = "Grid", ctx = "roll", g = "click", mods = "Alt",
      label = "Deselect all notes" },
    { act = "roll.cursor",         group = "Grid", ctx = "roll", g = "click", mods = "Ctrl",
      label = "Deselect all and move the edit cursor (no snap)" },
    { act = "roll.insert_drag",    group = "Grid", ctx = "roll", g = "drag", mods = "",
      label = "Insert note, drag to extend" },
    { act = "roll.copy_sel",       group = "Grid", ctx = "roll", g = "drag", mods = "Ctrl",
      label = "Copy the selected notes" },
    { act = "roll.erase_drag",     group = "Grid", ctx = "roll", g = "drag", mods = "Alt",
      label = "Erase notes" },
    { act = "roll.paint_line",     group = "Grid", ctx = "roll", g = "drag", mods = "Ctrl+Alt",
      label = "Paint a straight line of notes" },
    { act = "roll.paint_chord",    group = "Grid", ctx = "roll", g = "drag", mods = "Shift+Ctrl+Alt",
      label = "Paint notes and chords" },
    { act = "roll.marquee",        group = "Grid", ctx = "roll", g = "rclick", mods = "",
      label = "Marquee select (release without moving deletes)" },
    -- ----- la colonne des libelles ------------------------------------------
    { act = "lane.select_row",     group = "Rows", ctx = "lane", g = "click", mods = "",
      label = "Select the whole row" },
    { act = "lane.select_row_add", group = "Rows", ctx = "lane", g = "click", mods = "Ctrl",
      label = "Add the row to the selection" },
    { act = "lane.audition",       group = "Rows", ctx = "lane", g = "rclick", mods = "",
      label = "Audition the row" },
    -- ----- la regle ---------------------------------------------------------
    -- ICI C'EST CTRL qui ignore le magnetisme, et non Shift. C'est le choix de
    -- REAPER, pas le notre : sa regle repond a Ctrl et ses notes a Shift.
    { act = "ruler.cursor",        group = "Ruler", ctx = "ruler", g = "click", mods = "",
      label = "Move the edit cursor" },
    { act = "ruler.cursor_free",   group = "Ruler", ctx = "ruler", g = "click", mods = "Ctrl",
      label = "Move the edit cursor ignoring snap" },
    { act = "ruler.select_in_ts",  group = "Ruler", ctx = "ruler", g = "click", mods = "Shift",
      label = "Select the notes inside the time selection" },
    { act = "ruler.clear_ts",      group = "Ruler", ctx = "ruler", g = "click", mods = "Alt",
      label = "Clear the time selection" },
    -- ----- le clavier -------------------------------------------------------
    -- LES CODES SONT CEUX QUE `gfx.getchar` REND, pas ceux qu'on deduirait :
    -- Ctrl+A arrive en 1, et la ponctuation se deplace selon la disposition du
    -- clavier. Une deduction serait fausse precisement sur les claviers qui ne
    -- sont pas le notre.
    { act = "play.cursor",   group = "Transport", k = Keys.SPACE, mods = "",
      label = "Play from the edit cursor" },
    { act = "play.sel",      group = "Transport", k = Keys.SPACE, mods = "Shift",
      label = "Play the time selection" },
    { act = "play.start",    group = "Transport", k = Keys.SPACE, mods = "Ctrl+Shift",
      label = "Play from the start of the material" },
    { act = "view.fit",      group = "View", k = Keys.HOME, mods = "",
      label = "Fit the view" },
    { act = "view.zoom_in",  group = "View", k = 43, mods = "",
      label = "Zoom in" },
    { act = "view.zoom_out", group = "View", k = 45, mods = "",
      label = "Zoom out" },
    { act = "audio.clear_sel", group = "Audio", k = Keys.ESCAPE, mods = "",
      label = "Clear the time selection (audio)" },
    { act = "audio.mark_add",  group = "Audio", k = 109, mods = "",
      label = "Add a transient at the cursor" },
    { act = "audio.mark_del",  group = "Audio", k = Keys.DELETE, mods = "",
      label = "Remove the transient under the cursor" },
    { act = "edit.undo",     group = "Edit", k = 26, mods = "Ctrl",
      label = "Undo" },
    { act = "edit.redo",     group = "Edit", k = 25, mods = "Ctrl",
      label = "Redo" },
    { act = "sel.all",       group = "Edit", k = 1,  mods = "Ctrl",
      label = "Select all notes" },
    { act = "edit.duplicate",group = "Edit", k = 4,  mods = "Ctrl",
      label = "Duplicate" },
    { act = "edit.copy",     group = "Edit", k = 3,  mods = "Ctrl", label = "Copy" },
    { act = "edit.cut",      group = "Edit", k = 24, mods = "Ctrl", label = "Cut" },
    { act = "edit.paste",    group = "Edit", k = 22, mods = "Ctrl", label = "Paste" },
    { act = "edit.delete",   group = "Edit", k = Keys.DELETE, mods = "",
      label = "Delete the selection" },
    { act = "edit.quantize", group = "Edit", k = 113, mods = "",
      label = "Quantize" },
    { act = "sel.clear",     group = "Edit", k = Keys.ESCAPE, mods = "",
      label = "Deselect" },
    { act = "note.transpose_up",   group = "Notes", k = Keys.UP,   mods = "",
      label = "Transpose +1 semitone" },
    { act = "note.transpose_down", group = "Notes", k = Keys.DOWN, mods = "",
      label = "Transpose -1 semitone" },
    { act = "note.octave_up",      group = "Notes", k = Keys.UP,   mods = "Shift",
      label = "Transpose +1 octave" },
    { act = "note.octave_down",    group = "Notes", k = Keys.DOWN, mods = "Shift",
      label = "Transpose -1 octave" },
    { act = "note.scale_up",       group = "Notes", k = Keys.UP,   mods = "Ctrl",
      label = "Transpose one scale step up" },
    { act = "note.scale_down",     group = "Notes", k = Keys.DOWN, mods = "Ctrl",
      label = "Transpose one scale step down" },
    { act = "note.nudge_left",     group = "Notes", k = Keys.LEFT,  mods = "",
      label = "Nudge one grid step left" },
    { act = "note.nudge_right",    group = "Notes", k = Keys.RIGHT, mods = "",
      label = "Nudge one grid step right" },
    { act = "walk.prev_row",     group = "Walk", k = Keys.LEFT,  mods = "Alt",
      label = "Previous note in the row" },
    { act = "walk.next_row",     group = "Walk", k = Keys.RIGHT, mods = "Alt",
      label = "Next note in the row" },
    { act = "walk.prev",         group = "Walk", k = Keys.UP,    mods = "Alt",
      label = "Previous note in time" },
    { act = "walk.next",         group = "Walk", k = Keys.DOWN,  mods = "Alt",
      label = "Next note in time" },
    { act = "walk.ext_prev_row", group = "Walk", k = Keys.LEFT,  mods = "Shift+Alt",
      label = "Extend to the previous note in the row" },
    { act = "walk.ext_next_row", group = "Walk", k = Keys.RIGHT, mods = "Shift+Alt",
      label = "Extend to the next note in the row" },
    { act = "walk.ext_prev",     group = "Walk", k = Keys.UP,    mods = "Shift+Alt",
      label = "Extend to the previous note in time" },
    { act = "walk.ext_next",     group = "Walk", k = Keys.DOWN,  mods = "Shift+Alt",
      label = "Extend to the next note in time" },
}
