-- @description BPM Slider avec ReaImGui et BPM préréglés
-- @version 1.2
-- @author Claude
-- @about
--   Un script pour contrôler le BPM avec un slider et des préréglages
-- @changelog
--   + Fixed ImGui context handling
--   + Ajout des BPM préréglés
--   + Version initiale

local r = reaper

-- Create context at script start
local ctx = r.ImGui_CreateContext('BPM Slider')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

-- Variables pour stocker le BPM
local current_bpm = r.Master_GetTempo()
local new_bpm = current_bpm

-- Table des BPM préréglés
local preset_bpms = {60, 80, 100, 120, 140, 160, 180, 200, 220, 240, 260, 280, 300, 320, 340, 360, 380, 400}

function frame()
    local visible, open = r.ImGui_Begin(ctx, 'BPM Control', true, WINDOW_FLAGS)
    
    if visible then
        -- Récupérer le BPM actuel
        current_bpm = r.Master_GetTempo()
        
        -- Créer un slider pour le BPM
        local rv, value = r.ImGui_SliderDouble(ctx, 'BPM', current_bpm, 20, 400, '%.1f')
        if rv then
            -- Si le slider a été modifié, mettre à jour le BPM
            new_bpm = value
            r.SetCurrentBPM(0, new_bpm, false)
        end
        
        -- Bouton pour réinitialiser au BPM du projet
        if r.ImGui_Button(ctx, 'Reset to Project BPM') then
            new_bpm = r.Master_GetTempo()
            r.SetCurrentBPM(0, new_bpm, false)
        end
        
        -- Afficher le BPM actuel du projet
        r.ImGui_Text(ctx, string.format('Project BPM: %.1f', r.Master_GetTempo()))
        
        -- Ajouter un espacement
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Text(ctx, "Preset BPMs:")
        r.ImGui_Spacing(ctx)
        
        -- Créer une grille de boutons pour les BPM préréglés
        local button_width = 70
        local button_height = 25
        local buttons_per_row = 5
        local current_column = 0
        
        for i, bpm in ipairs(preset_bpms) do
            if current_column > 0 then
                r.ImGui_SameLine(ctx)
            end
            
            -- Créer un bouton pour chaque BPM préréglé
            if r.ImGui_Button(ctx, tostring(bpm), button_width, button_height) then
                new_bpm = bpm
                r.SetCurrentBPM(0, new_bpm, false)
            end
            
            current_column = current_column + 1
            if current_column >= buttons_per_row then
                current_column = 0
            end
        end
        
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(frame)
    end
end

-- Fonction pour définir le BPM
function r.SetCurrentBPM(project, bpm, isundo)
    local timebase = r.TimeMap_GetDividedBpmAtTime(0, 0)
    r.SetTempoTimeSigMarker(project, -1, 0, 0, 0, bpm, 0, 0, 0)
end

-- Simple exit function
function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
r.defer(frame)
