-- @description DeleteUnderMouse
-- @version 1.0
-- @author Cedric Pamalio

function nothing() end

-- Fonctions utilitaires pour la gestion des chunks (tirÃ©es du script fourni)
function GetTrackChunk(track)
  if not track then return end
  local fast_str, track_chunk
  fast_str = reaper.SNM_CreateFastString("")
  if reaper.SNM_GetSetObjectState(track, fast_str, false, false) then
    track_chunk = reaper.SNM_GetFastString(fast_str)
  end
  reaper.SNM_DeleteFastString(fast_str)  
  return track_chunk
end

function SetTrackChunk(track, track_chunk)
  if not (track and track_chunk) then return end
  local fast_str, ret 
  fast_str = reaper.SNM_CreateFastString("")
  if reaper.SNM_SetFastString(fast_str, track_chunk) then
    ret = reaper.SNM_GetSetObjectState(track, fast_str, true, false)
  end
  reaper.SNM_DeleteFastString(fast_str)
  return ret
end

function esc(str)
  str = str:gsub('%(', '%%(')
  str = str:gsub('%)', '%%)')
  str = str:gsub('%.', '%%.')
  str = str:gsub('%+', '%%+')
  str = str:gsub('%-', '%%-')
  str = str:gsub('%$', '%%$')
  str = str:gsub('%[', '%%[')
  str = str:gsub('%]', '%%]')
  str = str:gsub('%*', '%%*')
  str = str:gsub('%?', '%%?')
  str = str:gsub('%^', '%%^')
  str = str:gsub('/', '%%/')
  return str
end

-- Fonction pour collecter toutes les tracks d'un dossier (incluant sous-dossiers)
function CollectFolderTracks(parent_track)
  local tracks_to_delete = {parent_track}
  local parent_index = reaper.GetMediaTrackInfo_Value(parent_track, "IP_TRACKNUMBER") - 1
  local parent_depth = reaper.GetTrackDepth(parent_track)
  local total_tracks = reaper.CountTracks(0)
  
  -- Parcourir toutes les tracks suivantes
  for i = parent_index + 1, total_tracks - 1 do
    local track = reaper.GetTrack(0, i)
    local track_depth = reaper.GetTrackDepth(track)
    
    -- Si on revient au niveau du parent ou moins, on s'arrÃªte
    if track_depth <= parent_depth then
      break
    end
    
    -- Sinon, c'est un enfant (direct ou indirect), on l'ajoute
    table.insert(tracks_to_delete, track)
  end
  
  return tracks_to_delete
end

-- Fonction pour forcer le recalcul des Ã©tats de folder
function ForceUpdateFolderStates()
  -- MÃ©thode 1 : Forcer une mise Ã  jour complÃ¨te de la track list
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  
  -- MÃ©thode 2 : Forcer REAPER Ã  recalculer en triggering une action qui met Ã  jour les folders
  local total_tracks = reaper.CountTracks(0)
  for i = 0, total_tracks - 1 do
    local track = reaper.GetTrack(0, i)
    local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    
    -- Si c'est un folder parent potentiel, vÃ©rifier s'il a encore des enfants
    if folder_depth > 0 then
      local has_children = false
      local track_depth = reaper.GetTrackDepth(track)
      
      -- VÃ©rifier s'il y a encore des tracks enfants
      for j = i + 1, total_tracks - 1 do
        local child_track = reaper.GetTrack(0, j)
        local child_depth = reaper.GetTrackDepth(child_track)
        
        -- Si on revient au niveau du parent ou moins, on s'arrÃªte
        if child_depth <= track_depth then
          break
        end
        
        -- Il y a au moins un enfant
        has_children = true
        break
      end
      
      -- Si plus d'enfants, remettre I_FOLDERDEPTH Ã  0
      if not has_children then
        reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
      end
    end
  end
end

-- Fonction pour ajuster la structure de dossier aprÃ¨s suppression d'une track
function FixFolderStructureAfterDeletion(track_to_delete)
  local track_index = reaper.GetMediaTrackInfo_Value(track_to_delete, "IP_TRACKNUMBER") - 1
  local track_folder_depth = reaper.GetMediaTrackInfo_Value(track_to_delete, "I_FOLDERDEPTH")
  local total_tracks = reaper.CountTracks(0)
  
  -- Si cette track ferme un dossier (I_FOLDERDEPTH < 0)
  if track_folder_depth < 0 then
    -- Chercher la track suivante qui n'est pas dans le mÃªme dossier
    local next_track_index = track_index + 1
    while next_track_index < total_tracks do
      local next_track = reaper.GetTrack(0, next_track_index)
      if next_track then
        local next_depth = reaper.GetTrackDepth(next_track)
        local current_depth = reaper.GetTrackDepth(track_to_delete)
        
        -- Si la track suivante est au mÃªme niveau ou moins profonde, transfÃ©rer la fermeture
        if next_depth <= current_depth then
          local next_folder_depth = reaper.GetMediaTrackInfo_Value(next_track, "I_FOLDERDEPTH")
          local new_folder_depth = next_folder_depth + track_folder_depth
          reaper.SetMediaTrackInfo_Value(next_track, "I_FOLDERDEPTH", new_folder_depth)
          break
        end
      end
      next_track_index = next_track_index + 1
    end
  end
end

-- Fonction pour parser les razor edits d'une chaÃ®ne
function ParseRazorEdits(razor_string)
  local razors = {}
  if not razor_string or razor_string == "" then return razors end
  
  local pos = 1
  while pos <= #razor_string do
    local start_pos, end_pos, start_time, end_time = razor_string:find("([%d%.%-]+)%s+([%d%.%-]+)", pos)
    if not start_pos then break end
    
    table.insert(razors, {
      start = tonumber(start_time),
      ending = tonumber(end_time)
    })
    
    pos = end_pos + 1
  end
  
  return razors
end

-- Fonction pour vÃ©rifier si une position est dans une zone razor
function IsInRazorEdit(track, mouse_time)
  local _, razor_string = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
  if not razor_string or razor_string == "" then return false, nil end
  
  local razors = ParseRazorEdits(razor_string)
  for _, razor in ipairs(razors) do
    if mouse_time >= razor.start and mouse_time <= razor.ending then
      return true, razor
    end
  end
  
  return false, nil
end

-- Fonction pour supprimer des points d'automation dans une zone spÃ©cifique
function DeleteAutomationPointsInZone(env, start_time, end_time)
  if not env then return false end
  
  -- Utiliser DeleteEnvelopePointRange pour supprimer tous les points dans la plage
  local deleted_points = reaper.DeleteEnvelopePointRange(env, start_time, end_time)
  
  return deleted_points
end

-- Fonction pour supprimer tous les points d'une enveloppe (clear envelope)
function ClearEnvelope(env)
  if not env then return false end
  
  local point_count = reaper.CountEnvelopePoints(env)
  if point_count == 0 then return false end
  
  -- Obtenir la plage temporelle complÃ¨te de l'enveloppe
  local retval, min_time = reaper.GetEnvelopePoint(env, 0)
  if not retval then return false end
  
  local retval2, max_time = reaper.GetEnvelopePoint(env, point_count - 1)
  if not retval2 then return false end
  
  -- Supprimer tous les points en utilisant une plage trÃ¨s large pour Ãªtre sÃ»r
  local deleted_points = reaper.DeleteEnvelopePointRange(env, min_time - 1000, max_time + 1000)
  
  return deleted_points
end

-- Fonction pour supprimer une zone razor edit
function DeleteRazorEditZone(track, razor_zone)
  if not track or not razor_zone then return false end
  
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  
  local deleted_something = false
  
  -- 1. Supprimer les points d'automation dans la zone razor
  local env_count = reaper.CountTrackEnvelopes(track)
  for i = 0, env_count - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    if env then
      if DeleteAutomationPointsInZone(env, razor_zone.start, razor_zone.ending) then
        deleted_something = true
      end
    end
  end
  
  -- 2. Traiter les items dans la zone razor
  local item_count = reaper.CountTrackMediaItems(track)
  for i = item_count - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_start + item_length
    
    -- VÃ©rifier si l'item chevauche avec la zone razor
    if item_start < razor_zone.ending and item_end > razor_zone.start then
      -- Calculer la zone d'intersection
      local cut_start = math.max(item_start, razor_zone.start)
      local cut_end = math.min(item_end, razor_zone.ending)
      
      if cut_start < cut_end then
        -- Si l'item est entiÃ¨rement dans la zone razor, le supprimer
        if cut_start <= item_start and cut_end >= item_end then
          reaper.DeleteTrackMediaItem(track, item)
          deleted_something = true
        else
          -- Sinon, utiliser la fonction de split/trim pour dÃ©couper la partie
          if cut_start > item_start and cut_end < item_end then
            -- DÃ©couper au milieu - crÃ©er deux items
            local new_item = reaper.SplitMediaItem(item, cut_start)
            if new_item then
              reaper.SplitMediaItem(new_item, cut_end)
              reaper.DeleteTrackMediaItem(track, new_item)
              deleted_something = true
            end
          elseif cut_start <= item_start then
            -- DÃ©couper au dÃ©but
            reaper.SetMediaItemInfo_Value(item, "D_POSITION", cut_end)
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_end - cut_end)
            deleted_something = true
          else
            -- DÃ©couper Ã  la fin
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", cut_start - item_start)
            deleted_something = true
          end
        end
      end
    end
  end
  
  -- 3. Nettoyer les razor edits de la track (supprimer cette zone)
  local _, razor_string = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
  if razor_string and razor_string ~= "" then
    -- Reconstruire la chaÃ®ne razor sans cette zone
    local razors = ParseRazorEdits(razor_string)
    local new_razor_parts = {}
    
    for _, r in ipairs(razors) do
      if not (r.start == razor_zone.start and r.ending == razor_zone.ending) then
        table.insert(new_razor_parts, string.format("%.14f %.14f", r.start, r.ending))
      end
    end
    
    local new_razor_string = table.concat(new_razor_parts, " ")
    reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", new_razor_string, true)
    deleted_something = true
  end
  
  if deleted_something then
    reaper.Undo_EndBlock('Supprimer la zone razor edit sous la souris', -1)
  else
    reaper.Undo_EndBlock('Aucune zone razor edit Ã  supprimer', -1)
  end
  
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateTimeline()
  
  -- Forcer le recalcul des Ã©tats de folder avec un dÃ©lai
  if deleted_something then
    reaper.defer(function()
      ForceUpdateFolderStates()
    end)
  end
  
  return deleted_something
end

-- Fonction pour supprimer des points d'automation d'une enveloppe dans une zone razor
function DeleteEnvelopePointsInRazorZone(env, razor_zone)
  if not env or not razor_zone then return false end
  
  return DeleteAutomationPointsInZone(env, razor_zone.start, razor_zone.ending)
end

-- Obtenir la position temporelle du curseur de souris
local mouse_time = reaper.BR_GetMouseCursorContext_Position()

-- Essayer de rÃ©cupÃ©rer la piste sous le curseur avec le contexte
local track, context, position = reaper.BR_TrackAtMouseCursor()

-- VÃ©rifier si nous sommes dans le TCP (0 = TCP)
if track and context == 0 then
  -- D'abord, vÃ©rifier s'il y a une zone razor edit active sur cette track
  local in_razor, razor_zone = IsInRazorEdit(track, mouse_time)
  if in_razor and razor_zone then
    if DeleteRazorEditZone(track, razor_zone) then
      return
    end
  end
  
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  
  -- VÃ©rifier si c'est un dossier (I_FOLDERDEPTH > 0)
  local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
  
  if folder_depth > 0 then
    -- C'est un dossier, collecter toutes les tracks enfants
    local tracks_to_delete = CollectFolderTracks(track)
    
    -- Supprimer toutes les tracks en commenÃ§ant par la fin pour Ã©viter les problÃ¨mes d'index
    for i = #tracks_to_delete, 1, -1 do
      reaper.DeleteTrack(tracks_to_delete[i])
    end
    
    reaper.Undo_EndBlock('Supprimer le dossier et ses enfants sous la souris', -1)
  else
    -- Track normale - pas besoin de modifier la structure pour les tracks enfants simples
    -- Seulement ajuster si la track ferme explicitement un dossier
    local track_folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    if track_folder_depth < 0 then
      FixFolderStructureAfterDeletion(track)
    end
    
    reaper.DeleteTrack(track)
    reaper.Undo_EndBlock('Supprimer la piste sous la souris dans le TCP', -1)
  end
  
  -- Actualiser l'interface de faÃ§on plus complÃ¨te
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateTimeline()
  
  -- Forcer le recalcul des Ã©tats de folder avec un dÃ©lai
  reaper.defer(function()
    ForceUpdateFolderStates()
  end)
  return
end

-- Obtenir le contexte du curseur de souris
local window, segment, details = reaper.BR_GetMouseCursorContext()

-- VÃ©rifier le contexte pour voir si on est sur une enveloppe
if segment == "envelope" or details == "env_point" or details == "env_segment" then
  -- Obtenir l'enveloppe sous le curseur
  local env, takeEnv = reaper.BR_GetMouseCursorContext_Envelope()
  
  -- Ne gÃ©rer que les enveloppes de piste (pas les enveloppes de take)
  if env and not takeEnv then
    -- VÃ©rifier s'il y a une zone razor edit sur cette enveloppe
    local parent_track = reaper.Envelope_GetParentTrack(env)
    if parent_track then
      local in_razor, razor_zone = IsInRazorEdit(parent_track, mouse_time)
      if in_razor and razor_zone then
        -- Supprimer seulement les points dans la zone razor sur cette enveloppe
        reaper.PreventUIRefresh(1)
        reaper.Undo_BeginBlock()
        
        local deleted_points = DeleteEnvelopePointsInRazorZone(env, razor_zone)
        
        if deleted_points then
          reaper.Undo_EndBlock('Supprimer les points d\'enveloppe dans la zone razor', -1)
        else
          reaper.Undo_EndBlock('Aucun point d\'enveloppe Ã  supprimer dans la zone', -1)
        end
        
        reaper.PreventUIRefresh(-1)
        reaper.UpdateArrange()
        reaper.TrackList_AdjustWindows(false)
        reaper.UpdateTimeline()
        
        -- Forcer le recalcul des Ã©tats de folder avec un dÃ©lai
        reaper.defer(function()
          reaper.TrackList_AdjustWindows(false)
          reaper.UpdateArrange()
        end)
        return
      end
    end
    
    -- Pas de razor edit - supprimer tous les points et l'enveloppe elle-mÃªme
    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock()
    
    -- D'abord, clear l'enveloppe (supprimer tous les points)
    local cleared_points = ClearEnvelope(env)
    
    -- Ensuite, supprimer l'enveloppe track elle-mÃªme
    local tr = reaper.Envelope_GetParentTrack(env)
    local deleted_envelope = false
    
    -- Trouver l'index de l'enveloppe dans la piste
    local num = nil
    local envs = reaper.CountTrackEnvelopes(tr)
    for i = 0, envs-1 do
      local tr_env = reaper.GetTrackEnvelope(tr, i)
      if tr_env == env then 
        num = i
        break
      end
    end
    
    if num ~= nil then
      -- RÃ©cupÃ©rer le chunk de la piste
      local chunk = GetTrackChunk(tr)
      
      -- Trouver et supprimer l'enveloppe du chunk
      local x = -1
      for env_chunk in chunk:gmatch('<PARMENV.->') do
        x = x+1
        if x == num then
          chunk = chunk:gsub(esc(env_chunk)..'\n', '', 1)
          deleted_envelope = true
          break
        end
      end
      
      -- Appliquer le chunk modifiÃ©
      if deleted_envelope then
        SetTrackChunk(tr, chunk)
      end
    end
    
    if cleared_points or deleted_envelope then
      reaper.Undo_EndBlock('Clear enveloppe et supprimer envelope track', -1)
    else
      reaper.Undo_EndBlock('Aucune modification d\'enveloppe', -1)
    end
    
    -- Actualiser l'interface de faÃ§on plus complÃ¨te
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateTimeline()
    
    -- Forcer le recalcul des Ã©tats de folder avec un dÃ©lai
    reaper.defer(function()
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
    end)
    return
  end
end

-- Si nous ne sommes pas dans le TCP, essayer de rÃ©cupÃ©rer un item sous le curseur
local item, item_pos = reaper.BR_ItemAtMouseCursor()
if item then
  -- VÃ©rifier d'abord s'il y a une zone razor edit sur la track de cet item
  local item_track = reaper.GetMediaItem_Track(item)
  if item_track then
    local in_razor, razor_zone = IsInRazorEdit(item_track, mouse_time)
    if in_razor and razor_zone then
      if DeleteRazorEditZone(item_track, razor_zone) then
        return
      end
    end
  end
  
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(item), item)
  reaper.Undo_EndBlock('Supprimer l\'item sous la souris', -1)
  -- Actualiser l'interface de faÃ§on plus complÃ¨te
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateTimeline()
  
  -- Forcer le recalcul des Ã©tats de folder avec un dÃ©lai
  reaper.defer(function()
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
  end)
  return
end

-- Si aucune action n'a Ã©tÃ© effectuÃ©e
reaper.defer(nothing)









