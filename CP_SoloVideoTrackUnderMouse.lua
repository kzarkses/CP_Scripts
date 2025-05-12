-- Paramètres configurables
local reference_track_index = 3  -- La piste à mettre en solo (les index commencent à 1 dans ce script)

-- Vérifier si le script est déjà en cours d'exécution
if reaper.GetExtState("CP_SoloVideoTrackUnderMouse", "running") == "1" then
  return -- Sortir si déjà en cours d'exécution
end

-- Marquer le script comme en cours d'exécution
reaper.SetExtState("CP_SoloVideoTrackUnderMouse", "running", "1", false)

-- Sauvegarder la position actuelle du curseur d'édition
local original_cursor_pos = reaper.GetCursorPosition()

-- Obtenir la position de la souris dans la timeline
local mouse_pos = original_cursor_pos  -- Par défaut, utiliser la position actuelle du curseur

-- Essayer d'obtenir la position de la souris dans l'arrangement
local window, segment, details = reaper.BR_GetMouseCursorContext()
if window == "arrange" then
  local position_valid, position = reaper.BR_GetMouseCursorContext_Position()
  if position_valid and position then
    mouse_pos = position
  end
end

-- Obtenir la piste de référence (index - 1 car REAPER commence à 0)
local reference_track = reaper.GetTrack(0, reference_track_index - 1)
if not reference_track then
  reaper.ShowConsoleMsg("Piste de référence non trouvée. Vérifiez le paramètre 'reference_track_index'.\n")
  reaper.SetExtState("CP_SoloVideoTrackUnderMouse", "running", "0", false)
  return
end

-- Sauvegarder l'état solo de toutes les pistes
local track_count = reaper.CountTracks(0)
local original_solo_states = {}
for i = 0, track_count - 1 do
  local track = reaper.GetTrack(0, i)
  original_solo_states[i] = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
end

-- Sauvegarder les états pour la restauration
reaper.SetExtState("CP_SoloVideoTrackUnderMouse", "cursor_pos", tostring(original_cursor_pos), false)
reaper.SetExtState("CP_SoloVideoTrackUnderMouse", "track_count", tostring(track_count), false)
for i = 0, track_count - 1 do
  reaper.SetExtState("CP_SoloVideoTrackUnderMouse", "solo_" .. i, tostring(original_solo_states[i]), false)
end

-- Mettre en solo uniquement la piste de référence
for i = 0, track_count - 1 do
  local track = reaper.GetTrack(0, i)
  if track == reference_track then
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 1) -- 1 = Solo
  else
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0) -- 0 = Non-solo
  end
end

-- Définir le curseur et lancer la lecture
reaper.SetEditCurPos(mouse_pos, true, true) -- Déplacer le curseur avec défilement
reaper.OnPlayButton()

-- Configuration du gestionnaire de nettoyage
local cleanup_id = "CP_SoloVideoTrackUnderMouse_Cleanup"

-- Fonction de nettoyage à exécuter lorsque la touche est relâchée
local cleanup_script = [[
-- Vérifier si le script principal est toujours en cours
if reaper.GetExtState("CP_SoloVideoTrackUnderMouse", "running") ~= "1" then
  return
end

-- Arrêter la lecture
reaper.OnStopButton()

-- Récupérer les informations sauvegardées
local cursor_pos = tonumber(reaper.GetExtState("CP_SoloVideoTrackUnderMouse", "cursor_pos"))
local track_count = tonumber(reaper.GetExtState("CP_SoloVideoTrackUnderMouse", "track_count"))

-- Restaurer l'état solo de toutes les pistes
for i = 0, track_count - 1 do
  local track = reaper.GetTrack(0, i)
  local solo_state = tonumber(reaper.GetExtState("CP_SoloVideoTrackUnderMouse", "solo_" .. i))
  if track and solo_state then
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", solo_state)
  end
end

-- Restaurer la position du curseur d'édition
if cursor_pos then
  reaper.SetEditCurPos(cursor_pos, false, false)
end

-- Actualiser l'interface
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()

-- Marquer le script comme terminé
reaper.SetExtState("CP_SoloVideoTrackUnderMouse", "running", "0", false)
]]

-- Enregistrer le script de nettoyage pour qu'il s'exécute lorsque la touche est relâchée
reaper.SetExtState(cleanup_id, "script", cleanup_script, false)
reaper.defer(function() 
  if reaper.GetExtState("CP_SoloVideoTrackUnderMouse", "running") == "1" then
    local _, _, sectionID, cmdID = reaper.get_action_context()
    local state = reaper.GetToggleCommandState(cmdID)
    if state ~= 1 then
      -- La touche a été relâchée, exécuter le nettoyage
      local script = reaper.GetExtState(cleanup_id, "script")
      if script ~= "" then
        load(script)()  -- Utilisation de load() au lieu de loadstring()
      end
    else
      reaper.defer(function() end)
    end
  end
end)
