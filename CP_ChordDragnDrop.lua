-- Chord Drag & Drop
-- @description Drag & drop chords to arrange view or MIDI editor
-- @version 1.0
-- @author Claude

local r = reaper
local ctx = r.ImGui_CreateContext('Chord Builder')

-- Constants
local NOTES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local ROMAN_NUMERALS = {"I", "ii", "iii", "IV", "V", "vi", "vii°"}
local MODES = {
    "Major",
    "Natural Minor",
    "Harmonic Minor",
    "Melodic Minor",
    "Dorian",
    "Phrygian",
    "Lydian",
    "Mixolydian"
}

-- State
local state = {
    root_note = 1, -- C
    mode = 1, -- Major
    dragging = false,
    drag_chord = "",
    mouse_x = 0,
    mouse_y = 0
}

-- Helper functions
function get_chord_notes(chord)
    local root_note = 60 -- Middle C
    local intervals = {0} -- Root
    
    -- Add chord intervals based on type
    if chord:match("m7b5") then
        intervals = {0, 3, 6, 10} -- Half-diminished
    elseif chord:match("dim") then
        intervals = {0, 3, 6} -- Diminished
    elseif chord:match("maj7") then
        intervals = {0, 4, 7, 11} -- Major 7th
    elseif chord:match("m7") then
        intervals = {0, 3, 7, 10} -- Minor 7th
    elseif chord:match("7") then
        intervals = {0, 4, 7, 10} -- Dominant 7th
    elseif chord:match("m") then
        intervals = {0, 3, 7} -- Minor
    else
        intervals = {0, 4, 7} -- Major
    end
    
    -- Get root note from chord name
    local note_str = chord:match("^([A-G]#?)")
    if note_str then
        for i, note in ipairs(NOTES) do
            if note == note_str then
                root_note = 60 + (i - 1) -- Adjust root note
                break
            end
        end
    end
    
    -- Generate MIDI notes
    local notes = {}
    for _, interval in ipairs(intervals) do
        table.insert(notes, root_note + interval)
    end
    
    return notes
end
function get_scale_chords(root, mode)
    -- Tables définissant les intervalles pour chaque mode
    local mode_intervals = {
        -- Major
        [1] = {
            chords = {"%s", "%sm", "%sm", "%s", "%s", "%sm", "%sdim"},
            sevenths = {"%smaj7", "%sm7", "%sm7", "%smaj7", "%s7", "%sm7", "%sm7b5"},
            extended = {"%smaj9", "%sm9", "%sm11", "%smaj9", "%s9", "%sm11", "%sm7b5b9"},
            steps = {0, 2, 4, 5, 7, 9, 11},
            numerals = {"I", "ii", "iii", "IV", "V", "vi", "vii°"}
        },
        -- Natural Minor
        [2] = {
            chords = {"%sm", "%sdim", "%s", "%sm", "%sm", "%s", "%s"},
            sevenths = {"%sm7", "%sm7b5", "%smaj7", "%sm7", "%sm7", "%smaj7", "%s7"},
            extended = {"%sm9", "%sm7b5b9", "%smaj9", "%sm11", "%sm9", "%smaj9#11", "%s13b9"},
            steps = {0, 2, 3, 5, 7, 8, 10},
            numerals = {"i", "ii°", "III", "iv", "v", "VI", "VII"}
        },
        -- Harmonic Minor
        [3] = {
            chords = {"%sm", "%sdim", "%saug", "%sm", "%s", "%s", "%sdim"},
            sevenths = {"%sm(maj7)", "%sm7b5", "%s7#5", "%sm7", "%s7", "%smaj7", "%sdim7"},
            extended = {"%sm(maj9)", "%sm7b5b9", "%s7#5#9", "%sm11", "%s7b9", "%smaj9", "%sdim7b9"},
            steps = {0, 2, 3, 5, 7, 8, 11},
            numerals = {"i", "ii°", "III+", "iv", "V", "VI", "vii°"}
        },
        -- Melodic Minor
        [4] = {
            chords = {"%sm", "%sm", "%saug", "%s", "%s", "%sdim", "%sdim"},
            sevenths = {"%sm(maj7)", "%sm7", "%smaj7#5", "%s7", "%s7", "%sm7b5", "%sm7b5"},
            extended = {"%sm(maj9)", "%sm9", "%smaj7#5#11", "%s9#11", "%s13", "%sm7b5b9", "%sm7b5b9"},
            steps = {0, 2, 3, 5, 7, 9, 11},
            numerals = {"i", "ii", "III+", "IV", "V", "vi°", "vii°"}
        },
        -- Dorian
        [5] = {
            chords = {"%sm", "%sm", "%s", "%s", "%sm", "%sdim", "%s"},
            sevenths = {"%sm7", "%sm7", "%smaj7", "%s7", "%sm7", "%sm7b5", "%s7"},
            extended = {"%sm11", "%sm9", "%smaj9", "%s13", "%sm11", "%sm7b5b9", "%s13b9"},
            steps = {0, 2, 3, 5, 7, 9, 10},
            numerals = {"i", "ii", "bIII", "IV", "v", "vi°", "bVII"}
        },
        -- Phrygian
        [6] = {
            chords = {"%sm", "%s", "%s", "%sm", "%sdim", "%s", "%sm"},
            sevenths = {"%sm7", "%smaj7", "%s7", "%sm7", "%sm7b5", "%smaj7", "%sm7"},
            extended = {"%sm7b9", "%smaj7b9", "%s7b9", "%sm11", "%sm7b5b9", "%smaj9", "%sm9"},
            steps = {0, 1, 3, 5, 7, 8, 10},
            numerals = {"i", "bII", "bIII", "iv", "v°", "bVI", "bvii"}
        },
        -- Lydian
        [7] = {
            chords = {"%s", "%s", "%s", "%sdim", "%s", "%sm", "%sm"},
            sevenths = {"%smaj7", "%s7", "%s7", "%sdim7", "%s7", "%sm7", "%sm7"},
            extended = {"%smaj9#11", "%s9#11", "%s9", "%sdim7b9", "%s13", "%sm9", "%sm11"},
            steps = {0, 2, 4, 6, 7, 9, 11},
            numerals = {"I", "II", "III", "iv°", "V", "vi", "vii"}
        },
        -- Mixolydian
        [8] = {
            chords = {"%s", "%sm", "%sdim", "%s", "%sm", "%sm", "%s"},
            sevenths = {"%s7", "%sm7", "%sdim7", "%smaj7", "%sm7", "%sm7", "%smaj7"},
            extended = {"%s9", "%sm9", "%sdim7b9", "%smaj9", "%sm11", "%sm9", "%s13"},
            steps = {0, 2, 4, 5, 7, 9, 10},
            numerals = {"I", "ii", "iii°", "IV", "v", "vi", "bVII"}
        }
    }

    local progressions = {}
    local intervals = mode_intervals[mode]
    
    -- Generate main progression
    local chord_progression = {}
    local sevenths_progression = {}
    local extended_progression = {}
    
    for i = 1, 7 do
        local note_idx = ((root - 1 + intervals.steps[i]) % 12) + 1
        chord_progression[i] = string.format(intervals.chords[i], NOTES[note_idx])
        sevenths_progression[i] = string.format(intervals.sevenths[i], NOTES[note_idx])
        extended_progression[i] = string.format(intervals.extended[i], NOTES[note_idx])
    end
    
    table.insert(progressions, {
        chords = chord_progression,
        sevenths = sevenths_progression,
        extended = extended_progression,
        numerals = intervals.numerals,
        title = MODES[mode] .. " Scale"
    })
    
    -- Add parallel minor/major
    if mode == 1 then  -- If in major mode
        -- Add parallel minor
        local parallel_mode = mode_intervals[2]  -- Natural minor
        local parallel_chords = {}
        local parallel_sevenths = {}
        local parallel_extended = {}
        
        for i = 1, 7 do
            local note_idx = ((root - 1 + parallel_mode.steps[i]) % 12) + 1
            parallel_chords[i] = string.format(parallel_mode.chords[i], NOTES[note_idx])
            parallel_sevenths[i] = string.format(parallel_mode.sevenths[i], NOTES[note_idx])
            parallel_extended[i] = string.format(parallel_mode.extended[i], NOTES[note_idx])
        end
        
        table.insert(progressions, {
            chords = parallel_chords,
            sevenths = parallel_sevenths,
            extended = parallel_extended,
            numerals = parallel_mode.numerals,
            title = "Parallel Minor"
        })
        
        -- Add relative minor chords
        local relative_minor_root = ((root - 1 + 9) % 12) + 1  -- Up 9 semitones
        local relative_chords = {}
        local relative_sevenths = {}
        local relative_extended = {}
        
        for i = 1, 7 do
            local note_idx = ((relative_minor_root - 1 + parallel_mode.steps[i]) % 12) + 1
            relative_chords[i] = string.format(parallel_mode.chords[i], NOTES[note_idx])
            relative_sevenths[i] = string.format(parallel_mode.sevenths[i], NOTES[note_idx])
            relative_extended[i] = string.format(parallel_mode.extended[i], NOTES[note_idx])
        end
        
        table.insert(progressions, {
            chords = relative_chords,
            sevenths = relative_sevenths,
            extended = relative_extended,
            numerals = parallel_mode.numerals,
            title = string.format("Relative Minor (%s)", NOTES[relative_minor_root])
        })
    elseif mode == 2 then  -- If in minor mode
        -- Add relative major
        local relative_major_root = ((root - 1 + 3) % 12) + 1  -- Up 3 semitones
        local major_mode = mode_intervals[1]
        local relative_chords = {}
        local relative_sevenths = {}
        local relative_extended = {}
        
        for i = 1, 7 do
            local note_idx = ((relative_major_root - 1 + major_mode.steps[i]) % 12) + 1
            relative_chords[i] = string.format(major_mode.chords[i], NOTES[note_idx])
            relative_sevenths[i] = string.format(major_mode.sevenths[i], NOTES[note_idx])
            relative_extended[i] = string.format(major_mode.extended[i], NOTES[note_idx])
        end
        
        table.insert(progressions, {
            chords = relative_chords,
            sevenths = relative_sevenths,
            extended = relative_extended,
            numerals = major_mode.numerals,
            title = string.format("Relative Major (%s)", NOTES[relative_major_root])
        })
    end
    
    return progressions
end

function insert_midi_chord(chord)
    local cursor_pos = r.GetCursorPosition()
    local _, measures, cml = r.TimeMap2_timeToBeats(0, cursor_pos)
    local measure_start_time = r.TimeMap2_beatsToTime(0, 0, measures)
    local measure_end_time = r.TimeMap2_beatsToTime(0, 0, measures + 1)
    local measure_length = measure_end_time - measure_start_time
    local chord_notes = get_chord_notes(chord)
    local track = r.GetSelectedTrack(0, 0) or r.GetTrack(0, 0)
    
    local item
    local selected_item = r.GetSelectedMediaItem(0, 0)
    if selected_item then
        local take = r.GetActiveTake(selected_item)
        if take and r.TakeIsMIDI(take) then
            item = selected_item
            -- Supprimer toutes les notes existantes
            local note_idx = 0
            while true do
                local retval, _, _, _, _, _, pitch = r.MIDI_GetNote(take, note_idx)
                if not retval then break end
                r.MIDI_DeleteNote(take, note_idx)
            end
            
            -- Insérer les nouvelles notes
            local start_ppq = r.MIDI_GetPPQPosFromProjTime(take, r.GetMediaItemInfo_Value(item, "D_POSITION"))
            local end_ppq = r.MIDI_GetPPQPosFromProjTime(take, r.GetMediaItemInfo_Value(item, "D_POSITION") + measure_length)
            
            r.MIDI_DisableSort(take)
            for _, note in ipairs(chord_notes) do
                r.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, note, 100, true)
            end
            r.MIDI_Sort(take)
        end
    end
    
    if not item then
        item = r.CreateNewMIDIItemInProj(track, cursor_pos, cursor_pos + measure_length)
        local take = r.GetActiveTake(item)
        local start_ppq = r.MIDI_GetPPQPosFromProjTime(take, cursor_pos)
        local end_ppq = r.MIDI_GetPPQPosFromProjTime(take, cursor_pos + measure_length)
        
        r.MIDI_DisableSort(take)
        for _, note in ipairs(chord_notes) do
            r.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, note, 100, true)
        end
        r.MIDI_Sort(take)
    end
    
    if item then
        local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        r.SetEditCurPos(item_pos + item_len, true, false)
    end
    
    r.UpdateArrange()
end

function handle_drop(chord)
    local window, segment, details = r.BR_GetMouseCursorContext()
    local cursor_pos = r.GetCursorPosition()
    
    if window == "midi_editor" then
        local editor = r.MIDIEditor_GetActive()
        if editor then
            local take = r.MIDIEditor_GetTake(editor)
            insert_midi_chord(chord)
        end
    else
        -- Arrange view
        local track = r.BR_GetMouseCursorContext_Track()
        if not track then
            track = r.GetSelectedTrack(0, 0)
        end
        if track then
            insert_midi_chord(chord)
        end
    end
end

function draw_chord_button(chord, numeral)
    local text = string.format("%s\n%s", numeral, chord)
    if r.ImGui_Button(ctx, text, 60, 40) then
        state.dragging = true 
        state.drag_chord = chord
    end
    
    if state.dragging and state.drag_chord == chord then
        r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_Hand())
        state.mouse_x, state.mouse_y = r.GetMousePosition()
        
        if not r.ImGui_IsMouseDown(ctx, 0) then
            state.dragging = false
            handle_drop(chord)
        end
    end
end

function draw_progression(prog)
    r.ImGui_Text(ctx, prog.title)
    r.ImGui_Separator(ctx)
    
    for i, chord in ipairs(prog.chords) do
        draw_chord_button(chord, prog.numerals[i])
        if i < #prog.chords then
            r.ImGui_SameLine(ctx)
        end
    end
    
    if #prog.sevenths > 0 then
        r.ImGui_Spacing(ctx)
        for i, chord in ipairs(prog.sevenths) do
            draw_chord_button(chord, prog.numerals[i])
            if i < #prog.sevenths then
                r.ImGui_SameLine(ctx)
            end
        end
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Spacing(ctx)
end

function loop()
    local visible, open = r.ImGui_Begin(ctx, 'Chord Builder')
    
    if visible then
        -- Root note selector
        if r.ImGui_BeginCombo(ctx, 'Root Note', NOTES[state.root_note]) then
            for i, note in ipairs(NOTES) do
                if r.ImGui_Selectable(ctx, note, i == state.root_note) then
                    state.root_note = i
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        r.ImGui_SameLine(ctx)
        
        -- Mode selector
        if r.ImGui_BeginCombo(ctx, 'Mode', MODES[state.mode]) then
            for i, mode in ipairs(MODES) do
                if r.ImGui_Selectable(ctx, mode, i == state.mode) then
                    state.mode = i
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Draw chord progressions
        local progressions = get_scale_chords(state.root_note, state.mode)
        for _, prog in ipairs(progressions) do
            draw_progression(prog)
        end
        
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(loop)
    end
end

function init()
    r.ImGui_SetNextWindowSize(ctx, 500, 400, r.ImGui_Cond_FirstUseEver())
end

function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        init()
        loop()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
    end
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()
