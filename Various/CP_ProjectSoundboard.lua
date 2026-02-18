-- @description ProjectSoundboard
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

-- Ultraschall API initialization
local ultraschall_available = false

-- Try to load Ultraschall API
function loadUltraschall()
  local ultraschall_path = r.GetResourcePath().."/UserPlugins/ultraschall_api.lua"
  local file = io.open(ultraschall_path, "r")
  
  if file then
    file:close()
    dofile(ultraschall_path)
    ultraschall_available = true
    return true
  else
    return false
  end
end

-- Configuration (valeurs par dÃ©faut)
local config = {
  columns_per_page = 10,   -- Number of columns per page
  item_height = 26,       -- Height of item buttons (increased for more spacing)
  refresh_interval = 0.5, -- Time interval for checking project changes (in seconds)
  preview_check_interval = 0.03, -- Time interval for checking preview state (in seconds - made more responsive)
  
  -- Colors
  active_color = 0x0088AAFF,     -- Blue color for active items
  inactive_color = 0x323232FF,   -- Darker gray color for inactive items (more subtle)
  first_column_color = 0x00AA88FF, -- Teal color for first column (folder files)
  other_track_color = 0xFFFF00FF, -- Yellow color for other tracks
  border_color = 0x444444FF,     -- Border color
  child_bg = 0x1E1E1EFF,         -- Darker background color for content areas
  window_bg = 0x181818FF,        -- Main window background color
  text_color = 0xDDDDDDFF,       -- Main text color
  muted_text_color = 0x888888FF,  -- Color for muted/disabled text
  header_separator_color = 0x444444FF, -- Color for header separators
  item_hover_color = 0x444444FF,  -- Color for button hover state
  
  -- Layout
  column_padding = 4,    -- Increased padding inside columns
  column_spacing = 14,    -- Increased spacing between columns
  title_height = 32,     -- Increased height of track title area
  button_rounding = 6,   -- Rounding for buttons
  section_spacing = 10,  -- Additional spacing after separators
  text_margin = 8,      -- Margin for text elements
  child_rounding = 6,    -- Rounding for child windows
  window_rounding = 0,   -- Rounding for main window
  border_size = 1.0,     -- Size of borders
  header_height = 36,    -- Height of column headers
  scrollbar_size = 14,   -- Size of scrollbars
  
  -- Font settings
  font_name = "Georgia", -- Font name
  font_size = 16,           -- Font size
  title_font_size = 24,     -- Font size for titles
  
  -- Visual behavior
  show_tooltips = true,     -- Whether to show tooltips
  compact_view = false,     -- More compact layout with smaller spacing
  enable_animations = true, -- Enable smooth animations (non implÃ©mentÃ©)
  theme_variant = "dark",   -- Current theme variant ("dark", "light", "custom")
  
  -- Folder browsing settings
  last_folder = "",      -- Last used folder path
  crossfade_duration = 2.0, -- Crossfade duration in seconds
  
  -- Soundboard tracks settings
  num_sb_tracks = 2,     -- Number of dedicated soundboard tracks
  sb_track_name = "Musics Track", -- Base name for soundboard tracks (changed from Soundboard to Musics)
  use_folder_track = true, -- Whether to use a folder track for organization
  folder_track_name = "Musics" -- Changed from Soundboard to Musics
}

-- Global variables
local gui = {}
local tracks = {}           -- Table to store track info
local items_by_track = {}   -- Items organized by track
local dedicated_tracks = {} -- Dedicated tracks for soundboard
local folder_track = nil    -- Folder track for soundboard tracks
local active_track_index = 1 -- Currently active track index
local last_refresh = 0      -- Last time project data was refreshed
local last_preview_check = 0 -- Last time preview state was checked
local dock_state = 0        -- Dock state for the window
local current_preview_item = nil  -- Currently previewed item
local preview_start_time = 0      -- Time when preview started
local preview_duration = 0        -- Duration of current preview
local ctx_valid = false     -- Flag to track if ImGui context is valid
local project_change_count = 0    -- Counter for detecting project changes
local track_item_counts = {}      -- Track the number of items per track
local last_click_time = 0         -- Time of last click for double-click detection
local actually_playing = false    -- Flag to track if the preview is actually playing
local last_play_state = 0         -- To track play state changes

-- Folder file browser variables
local folder_files = {}           -- Table to store audio files from folder
local current_folder = nil        -- Currently selected folder
local current_folder_file = nil   -- Currently playing folder file
local next_folder_file = nil      -- Next file for crossfade

-- Style loader integration
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

-- Variables globales pour le systÃ¨me de preview amÃ©liorÃ©
local preview_handles = {} -- Table pour stocker les handles de preview par item
local preview_info = {} -- Pour stocker les informations prÃ©cises sur chaque preview
local CF_API_available = false -- Flag pour vÃ©rifier si l'API CF_Preview est disponible

-- VÃ©rifier la disponibilitÃ© de l'API CF_Preview
function checkCFPreviewAPI()
  if r.CF_CreatePreview and r.CF_Preview_Play and r.CF_Preview_Stop then
    CF_API_available = true
    return true
  else
    return false
  end
end

-- Try to load style loader module
local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

-- Fonction pour charger la configuration de style depuis l'ExtState
function loadStyleConfig()
  local ext_state = r.GetExtState("CP_ProjectSoundboard", "style_config")
  if ext_state ~= "" then
    local success, loaded_config = pcall(function() return load("return " .. ext_state)() end)
    if success and type(loaded_config) == "table" then
      -- Fusionner la configuration chargÃ©e avec les valeurs par dÃ©faut
      for k, v in pairs(loaded_config) do
        config[k] = v
      end
      return true
    end
  end
  return false
end

-- Create ImGui context
function init()
  -- Try to load Ultraschall
  loadUltraschall()
  
  -- Charger la configuration de style avant de crÃ©er le contexte
  loadStyleConfig()
  
  -- Create ImGui context
  gui.ctx = r.ImGui_CreateContext('Musics') -- Changed from 'Soundboard' to 'Musics'
  
  -- Check if context was created successfully
  if not gui.ctx then
    r.ShowMessageBox("Failed to create ImGui context", "Error", 0)
    return false
  end
  
  -- Create font using the config values
  gui.font = r.ImGui_CreateFont(config.font_name, config.font_size)
  r.ImGui_Attach(gui.ctx, gui.font)
  
  -- Create title font if needed
  if config.title_font_size ~= config.font_size then
    gui.title_font = r.ImGui_CreateFont(config.font_name, config.title_font_size)
    r.ImGui_Attach(gui.ctx, gui.title_font)
  end
  
  -- Load saved settings
  loadSettings()
  
  -- Setup dedicated soundboard tracks
  createDedicatedTracks()
  
  -- Load tracks and items from project
  refresh_tracks_and_items()
  
  -- Load audio files from last folder if available
  if config.last_folder ~= "" then
    current_folder = config.last_folder
    refresh_folder_files()
  end
  
  -- Initialize last play state
  last_play_state = r.GetPlayState()
  
  ctx_valid = true
  return true
end

-- Create or find dedicated tracks for soundboard
function createDedicatedTracks()
  local found_tracks = {}
  local track_count = r.CountTracks(0)
  
  -- First look for the folder track if we're using one
  if config.use_folder_track then
    folder_track = nil
    for i = 0, track_count - 1 do
      local track = r.GetTrack(0, i)
      local _, track_name = r.GetTrackName(track)
      
      if track_name == config.folder_track_name then
        folder_track = track
        break
      end
    end
  end
  
  -- Next, try to find existing soundboard tracks
  for i = 0, track_count - 1 do
    local track = r.GetTrack(0, i)
    local _, track_name = r.GetTrackName(track)
    
    -- Check if this is one of our soundboard tracks
    if track_name and track_name:match("^" .. config.sb_track_name .. " %d+$") then
      local track_number = tonumber(track_name:match("%d+"))
      if track_number and track_number <= config.num_sb_tracks then
        found_tracks[track_number] = track
      end
    end
  end
  
  r.Undo_BeginBlock()
  
  -- Create folder track if needed
  if config.use_folder_track and not folder_track then
    -- Insert a new track at the end
    r.InsertTrackAtIndex(track_count, false)
    folder_track = r.GetTrack(0, track_count)
    track_count = track_count + 1
    
    -- Set track name and make it a folder
    r.GetSetMediaTrackInfo_String(folder_track, "P_NAME", config.folder_track_name, true)
    r.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1) -- 1 means start of folder
  end
  
  -- Check how many tracks we found
  local tracks_needed = 0
  for i = 1, config.num_sb_tracks do
    if not found_tracks[i] then
      tracks_needed = tracks_needed + 1
    end
  end
  
  -- Create any missing tracks
  if tracks_needed > 0 then
    -- Insert tracks at the proper position
    local insert_position = track_count
    if folder_track then
      -- If we have a folder track, get its position for insertion
      insert_position = r.GetMediaTrackInfo_Value(folder_track, "IP_TRACKNUMBER")
    end
    
    for i = 1, config.num_sb_tracks do
      if not found_tracks[i] then
        -- Create a new track at the insertion position
        r.InsertTrackAtIndex(insert_position, false)
        local new_track = r.GetTrack(0, insert_position)
        insert_position = insert_position + 1
        
        -- Set track name
        local track_name = config.sb_track_name .. " " .. i
        r.GetSetMediaTrackInfo_String(new_track, "P_NAME", track_name, true)
        
        -- Make it a child of the folder track if we're using one
        if folder_track then
          -- Set it as a child track
          r.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", 0) -- 0 means regular track within folder
        end
        
        found_tracks[i] = new_track
      end
    end
    
    -- If we have a folder track, make sure it's properly closed
    if folder_track then
      -- Find the last track in our group
      local last_track_idx = insert_position - 1
      local last_track = r.GetTrack(0, last_track_idx)
      
      -- Set the folder closing flag on the last track
      r.SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", -1) -- -1 means end of folder
    end
  end
  
  r.Undo_EndBlock("Create Musics Tracks", -1) -- Changed from "Soundboard" to "Musics"
  
  -- Store tracks in ordered array
  dedicated_tracks = {}
  for i = 1, config.num_sb_tracks do
    dedicated_tracks[i] = found_tracks[i]
  end
  
  -- Initialize active track index
  active_track_index = 1
  
  return #dedicated_tracks
end

-- Load settings from persistent storage
function loadSettings()
  -- Load existing dock state
  local saved_dock_state = r.GetExtState("CP_SoundboardPistes", "dock_state")
  if saved_dock_state ~= "" then
    dock_state = tonumber(saved_dock_state)
  end
  
  -- Load folder settings
  local saved_folder = r.GetExtState("CP_SoundboardPistes", "last_folder")
  if saved_folder ~= "" then
    config.last_folder = saved_folder
  end
  
  local saved_crossfade = r.GetExtState("CP_SoundboardPistes", "crossfade")
  if saved_crossfade ~= "" then
    config.crossfade_duration = tonumber(saved_crossfade)
  end
  
  -- Load track settings
  local saved_num_tracks = r.GetExtState("CP_SoundboardPistes", "num_sb_tracks")
  if saved_num_tracks ~= "" then
    config.num_sb_tracks = math.max(2, tonumber(saved_num_tracks))
  end
  
  local saved_use_folder = r.GetExtState("CP_SoundboardPistes", "use_folder_track")
  if saved_use_folder ~= "" then
    config.use_folder_track = saved_use_folder == "1"
  end
end

-- Save settings to persistent storage
function saveSettings()
  r.SetExtState("CP_SoundboardPistes", "dock_state", tostring(dock_state), true)
  r.SetExtState("CP_SoundboardPistes", "last_folder", config.last_folder, true)
  r.SetExtState("CP_SoundboardPistes", "crossfade", tostring(config.crossfade_duration), true)
  r.SetExtState("CP_SoundboardPistes", "num_sb_tracks", tostring(config.num_sb_tracks), true)
  r.SetExtState("CP_SoundboardPistes", "use_folder_track", config.use_folder_track and "1" or "0", true)
end

-- Safely stop all previews (without affecting arranger)
-- Modifier la fonction existante stopAllPreviews pour utiliser la nouvelle API
function stopAllPreviews()
  actually_playing = false
  
  if CF_API_available then
    -- ArrÃªter chaque preview individuellement
    for ptr, preview in pairs(preview_handles) do
      r.CF_Preview_Stop(preview)
    end
    preview_handles = {}
    preview_info = {}
  elseif ultraschall_available then
    -- MÃ©thodes Ultraschall existantes
    if type(ultraschall.StopAllPreviews) == "function" then
      ultraschall.StopAllPreviews()
    elseif type(ultraschall.StopPreviewMediaItemPeaksBuilding) == "function" then
      ultraschall.StopPreviewMediaItemPeaksBuilding()
    elseif type(ultraschall.StopPreviews) == "function" then
      ultraschall.StopPreviews()
    end
  else
    -- MÃ©thode standard
    r.StopPreview()
  end
  
  -- RÃ©initialiser les variables de suivi
  preview_start_time = 0
  preview_duration = 0
  
  -- RÃ©initialiser l'Ã©tat de l'item prÃ©visualisÃ©
  if current_preview_item then
    current_preview_item.playing = false
    current_preview_item = nil
  end
  
  -- Effacer les Ã©tats de lecture pour tous les items
  for track_idx, items in pairs(items_by_track) do
    for _, item in ipairs(items) do
      item.playing = false
    end
  end
end

-- Stop all folder files playback (tracks version)
function stopAllFolderFiles()
  -- ArrÃªter la lecture
  r.Main_OnCommand(1016, 0)  -- Transport: Stop
  
  -- RÃ©initialiser tous les Ã©tats de fichiers
  for _, file in ipairs(folder_files) do
    file.active = false
    file.fading_out = false
    file.fade_start_time = nil
  end
  
  current_folder_file = nil
  next_folder_file = nil
  
  -- DÃ©sactiver le solo sur toutes les pistes
  for _, track in ipairs(dedicated_tracks) do
    r.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
  end
  
  -- Optionnel: Effacer les items des pistes dÃ©diÃ©es
  r.PreventUIRefresh(1)
  
  for _, track in ipairs(dedicated_tracks) do
    local item_count = r.CountTrackMediaItems(track)
    for i = item_count-1, 0, -1 do
      local item = r.GetTrackMediaItem(track, i)
      if item then
        r.DeleteTrackMediaItem(track, item)
      end
    end
  end
  
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
end

-- Check if preview has ended and update UI accordingly
function checkPreviewState()
  -- Check if the play state has changed (for detecting space bar)
  local current_play_state = r.GetPlayState()
  
  -- If the play state changed from playing to stopped, stop all music
  if last_play_state & 1 == 1 and current_play_state & 1 == 0 then
    -- Play state changed from playing to stopped, stop all soundboard files
    if current_folder_file then
      stopAllFolderFiles()
    end
  end
  
  -- Update last play state
  last_play_state = current_play_state
  
  -- VÃ©rifier les previews d'items avec la nouvelle API
  if CF_API_available then
    -- Mise Ã  jour de l'Ã©tat visuel des items en preview
    for ptr, preview in pairs(preview_handles) do
      -- VÃ©rifier si la preview est encore active
      local is_active = false
      local status, position = r.CF_Preview_GetValue(preview, "D_POSITION")
      
      if status then
        is_active = true
        
        -- VÃ©rifier si nous sommes Ã  la fin de l'item
        if preview_info[ptr] then
          local info = preview_info[ptr]
          
          -- Si on a dÃ©passÃ© la fin calculÃ©e, arrÃªter la preview
          if position >= info.end_position - 0.01 then
            is_active = false
            r.CF_Preview_Stop(preview)
            preview_handles[ptr] = nil
            preview_info[ptr] = nil
          end
        else
          -- Fallback si les infos ne sont pas disponibles
          local status2, length = r.CF_Preview_GetValue(preview, "D_LENGTH")
          if status2 and position >= length - 0.01 then
            is_active = false
            r.CF_Preview_Stop(preview)
            preview_handles[ptr] = nil
          end
        end
      else
        -- La preview n'est plus active
        is_active = false
        preview_handles[ptr] = nil
        if preview_info then preview_info[ptr] = nil end
      end
      
      -- Mettre Ã  jour l'Ã©tat des items
      for track_idx, items in pairs(items_by_track) do
        for _, item in ipairs(items) do
          if item.ptr == ptr then
            item.playing = is_active
            if not is_active and current_preview_item and current_preview_item.ptr == ptr then
              current_preview_item = nil
              actually_playing = false
            end
          end
        end
      end
    end
  else
    if current_preview_item then
      -- VÃ©rifier si la preview a atteint sa fin
      local current_time = r.time_precise()
      if preview_start_time > 0 and preview_duration > 0 then
        if current_time > preview_start_time + preview_duration then
          -- Preview terminÃ©e, mettre Ã  jour l'Ã©tat
          current_preview_item.playing = false
          current_preview_item = nil
          actually_playing = false
          preview_start_time = 0
          preview_duration = 0
        end
      end
    end
  end

  -- VÃ©rifier si un fichier est en fade-out
  for i, file in ipairs(folder_files) do
    if file.fading_out and file.fade_start_time then
      local current_time = r.time_precise()
      local fade_time_elapsed = current_time - file.fade_start_time
      
      -- Si le fade est terminÃ©
      if fade_time_elapsed >= config.crossfade_duration then
        file.fading_out = false
        file.fade_start_time = nil
        file.active = false
        
        -- Si c'Ã©tait le fichier courant, arrÃªter la lecture
        if file == current_folder_file then
          current_folder_file = nil
          stopAllFolderFiles()
        end
      end
    end
  end
  
  -- VÃ©rifier les items de piste en preview
  if current_preview_item then
    -- VÃ©rifier si la preview a atteint sa fin
    local current_time = r.time_precise()
    if preview_start_time > 0 and preview_duration > 0 then
      if current_time > preview_start_time + preview_duration then
        -- Preview terminÃ©e, mettre Ã  jour l'Ã©tat
        current_preview_item.playing = false
        current_preview_item = nil
        actually_playing = false
        preview_start_time = 0
        preview_duration = 0
      end
    end
  end
  
  -- Pour les fichiers jouÃ©s sur les pistes, vÃ©rifier s'ils sont terminÃ©s
  if current_folder_file and current_folder_file.active then
    -- VÃ©rifier si la lecture s'est arrÃªtÃ©e
    if not r.GetPlayState() then
      -- Si la lecture s'est arrÃªtÃ©e, reset tous les statuts de fichiers
      for _, file in ipairs(folder_files) do
        file.active = false
        file.fading_out = false
        file.fade_start_time = nil
      end
      current_folder_file = nil
      next_folder_file = nil
    else
      -- VÃ©rifier si nous avons atteint la fin du morceau
      local play_position = r.GetPlayPosition()
      local item_start = 0 -- Les items commencent gÃ©nÃ©ralement Ã  0
      
      -- Trouver l'item sur la piste actuelle
      local current_track = dedicated_tracks[active_track_index]
      local item_count = r.CountTrackMediaItems(current_track)
      
      if item_count > 0 then
        local item = r.GetTrackMediaItem(current_track, 0) -- GÃ©nÃ©ralement un seul item
        if item then
          item_start = r.GetMediaItemInfo_Value(item, "D_POSITION")
          local item_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
          
          -- Si nous avons atteint la fin de l'item
          if play_position >= (item_start + item_length - 0.01) then
            -- Marquer le fichier comme inactif et arrÃªter la lecture
            current_folder_file.active = false
            current_folder_file = nil
            
            -- ArrÃªter la lecture avec un petit dÃ©lai pour s'assurer que le fade out est jouÃ©
            r.defer(function()
              r.Main_OnCommand(1016, 0)  -- Transport: Stop
            end)
          end
        end
      end
    end
  end
  
  -- Si un crossfade est en cours, vÃ©rifier s'il est terminÃ©
  if next_folder_file and next_folder_file.active then
    local time_elapsed = r.time_precise() - next_folder_file.start_time
    if time_elapsed > config.crossfade_duration * 1.1 then
      -- Le crossfade est terminÃ©, mettre Ã  jour les statuts
      if current_folder_file then
        current_folder_file.active = false
      end
      current_folder_file = next_folder_file
      next_folder_file = nil
    end
  end
end

-- Check if double-click detected
function isDoubleClick()
  local current_time = r.time_precise()
  local is_double_click = (current_time - last_click_time) < 0.3
  last_click_time = current_time
  return is_double_click
end

-- Check if project has changed
function hasProjectChanged()
  -- Check project change count
  local current_change_count = r.GetProjectStateChangeCount(0)
  if current_change_count ~= project_change_count then
    project_change_count = current_change_count
    return true
  end
  
  -- Check if any track item counts have changed
  local track_count = r.CountTracks(0)
  if track_count ~= #tracks then
    return true
  end
  
  for i = 0, track_count - 1 do
    local track = r.GetTrack(0, i)
    local item_count = r.CountTrackMediaItems(track)
    if not track_item_counts[i] or track_item_counts[i] ~= item_count then
      return true
    end
  end
  
  return false
end

-- Load tracks and their items
function refresh_tracks_and_items()
  tracks = {}
  items_by_track = {}
  track_item_counts = {}
  
  -- Save the project change count
  project_change_count = r.GetProjectStateChangeCount(0)
  
  -- 1. Get all tracks (excluding dedicated soundboard tracks and folder)
  local num_tracks = r.CountTracks(0)
  for i = 0, num_tracks - 1 do
    local track = r.GetTrack(0, i)
    if track then
      local _, track_name = r.GetTrackName(track)
      
      -- Skip our dedicated soundboard tracks and folder
      local skip_track = false
      
      -- Skip soundboard tracks
      if track_name and track_name:match("^" .. config.sb_track_name .. " %d+$") then
        skip_track = true
      end
      
      -- Skip folder track
      if track_name and track_name == config.folder_track_name then
        skip_track = true
      end
      
      -- Add all other tracks
      if not skip_track then
        local track_info = {
          ptr = track,
          name = track_name or ("Track " .. (i + 1)),
          index = i,
          items = {}
        }
        
        table.insert(tracks, track_info)
        items_by_track[i] = {}
        
        -- Store item count for this track
        track_item_counts[i] = r.CountTrackMediaItems(track)
      end
    end
  end
  
  -- 2. Loop through all items and organize them by track
  local num_items = r.CountMediaItems(0)
  for i = 0, num_items - 1 do
    local item = r.GetMediaItem(0, i)
    local take = r.GetActiveTake(item)
    
    if take and not r.TakeIsMIDI(take) then
      local source = r.GetMediaItemTake_Source(take)
      local track = r.GetMediaItemTrack(item)
      local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
      
      -- Check if this item is on a regular track (not a soundboard track or folder)
      local _, track_name = r.GetTrackName(track)
      local skip_item = false
      
      -- Skip soundboard tracks
      if track_name and track_name:match("^" .. config.sb_track_name .. " %d+$") then
        skip_item = true
      end
      
      -- Skip folder track
      if track_name and track_name == config.folder_track_name then
        skip_item = true
      end
      
      if not skip_item then
        local item_info = {
          ptr = item,
          take_ptr = take,
          track_ptr = track,
          track_idx = track_idx,
          name = r.GetTakeName(take) or "Unnamed",
          position = r.GetMediaItemInfo_Value(item, "D_POSITION"),
          length = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
          playing = false
        }
        
        -- Add item to its track's list
        if items_by_track[track_idx] then
          table.insert(items_by_track[track_idx], item_info)
        end
      end
    end
  end
  
  -- 3. Sort items in each track by position
  for track_idx, items in pairs(items_by_track) do
    table.sort(items, function(a, b) return a.position < b.position end)
  end
  
  -- Update current preview item if it exists
  if current_preview_item then
    local found = false
    for track_idx, items in pairs(items_by_track) do
      for _, item in ipairs(items) do
        if item.ptr == current_preview_item.ptr then
          item.playing = true
          found = true
          current_preview_item = item
          break
        end
      end
      if found then break end
    end
    if not found then
      current_preview_item = nil
      actually_playing = false
      preview_start_time = 0
      preview_duration = 0
    end
  end
  
  last_refresh = r.time_precise()
end

-- Function to browse for folder
function browseForFolder()
  if not r.APIExists("JS_Dialog_BrowseForFolder") then
    r.ShowMessageBox("This script requires js_ReaScriptAPI extension to browse for folders.", "Error", 0)
    return nil
  end
  
  local retval, folder = r.JS_Dialog_BrowseForFolder("Select Audio Files Folder", config.last_folder)
  if retval and folder ~= "" then
    config.last_folder = folder
    return folder
  end
  
  return nil
end

-- Scan audio files from the selected folder
function refresh_folder_files()
  if not current_folder or current_folder == "" then return end
  
  folder_files = {}
  local extensions = {
    ["wav"] = true, ["mp3"] = true, ["ogg"] = true, ["flac"] = true, 
    ["aif"] = true, ["aiff"] = true, ["m4a"] = true
  }
  
  -- List all files in directory
  local i = 0
  local file_list = {}
  repeat
    local file = r.EnumerateFiles(current_folder, i)
    if file then table.insert(file_list, file) end
    i = i + 1
  until not file
  
  -- Find audio files
  for _, filename in ipairs(file_list) do
    local ext = filename:match("%.([^%.]+)$")
    if ext and extensions[ext:lower()] then
      local file_info = {
        name = filename:match("(.+)%.[^%.]+$") or filename,
        path = current_folder .. "/" .. filename,
        filename = filename,
        active = false,
        volume = 1.0,
        start_time = 0
      }
      table.insert(folder_files, file_info)
    end
  end
  
  -- Sort alphabetically
  table.sort(folder_files, function(a, b) return a.name < b.name end)
end

-- Play folder file with crossfade handling
function play_folder_file(file_idx)
  local file = folder_files[file_idx]
  if not file then return false end
  
  -- Si ce son est dÃ©jÃ  en lecture, l'arrÃªter avec un fade
  if file.active then
    -- Prolonger l'item pour le fade-out avant de stopper
    local position = r.GetPlayPosition()
    
    -- Trouver la piste et l'item en lecture
    local current_track = dedicated_tracks[active_track_index]
    local item_count = r.CountTrackMediaItems(current_track)
    if item_count > 0 then
      -- Appliquer un fade-out sur tous les items actifs
      for i = 0, item_count - 1 do
        local item = r.GetTrackMediaItem(current_track, i)
        if item then
          -- Prolonger l'item pour le fade et ajouter le fade
          local current_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
          local current_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
          local new_length = position - current_pos + config.crossfade_duration
          
          -- Ne pas dÃ©passer la longueur originale de l'item
          if new_length <= current_length then
            r.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
          end
          
          r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", config.crossfade_duration)
        end
      end
      
      -- Marquer l'item comme en cours de fade-out
      file.fading_out = true
      file.fade_start_time = r.time_precise()
      
      -- On arrÃªtera rÃ©ellement le morceau dans checkPreviewState
      return true
    else
      stopAllFolderFiles()
    end
    
    return true
  end
  
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock()
  
  -- Choisir la prochaine piste Ã  utiliser
  local next_track_index = active_track_index % config.num_sb_tracks + 1
  local next_track = dedicated_tracks[next_track_index]
  
  -- DÃ©sactiver tous les autres fichiers pour l'affichage
  for _, f in ipairs(folder_files) do
    if f ~= file then
      f.active = false
    end
  end
  
  -- Si nous avons un fichier en cours et qu'on change pour un nouveau, faire un crossfade
  if current_folder_file and current_folder_file ~= file then
    -- Ajouter le nouveau fichier sur la piste suivante avec un fade-in
    local current_track = dedicated_tracks[active_track_index]
    local cursor_pos = r.GetPlayPosition()
    
    -- Effacer la piste de destination
    local item_count = r.CountTrackMediaItems(next_track)
    for i = item_count - 1, 0, -1 do
      local item = r.GetTrackMediaItem(next_track, i)
      if item then
        r.DeleteTrackMediaItem(next_track, item)
      end
    end
    
    -- InsÃ©rer le nouveau fichier sur la piste suivante
    local new_item = r.AddMediaItemToTrack(next_track)
    r.SetMediaItemPosition(new_item, cursor_pos, false)
    local new_take = r.AddTakeToMediaItem(new_item)
    local pcm_source = r.PCM_Source_CreateFromFile(file.path)
    r.SetMediaItemTake_Source(new_take, pcm_source)
    r.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", file.name, true)
    
    -- DÃ©finir la longueur de l'item selon la source
    local source_length = r.GetMediaSourceLength(pcm_source)
    r.SetMediaItemLength(new_item, source_length, false)
    
    -- Ajouter un fade-in au nouvel item
    r.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", config.crossfade_duration)
    
    -- Pour l'item en cours de lecture, ajouter un fade-out et couper sa longueur
    local current_items = {}
    local item_count = r.CountTrackMediaItems(current_track)
    for i = 0, item_count - 1 do
      local item = r.GetTrackMediaItem(current_track, i)
      if item then
        -- DÃ©finir la longueur totale jusqu'au point de fade + durÃ©e du fade
        local current_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local new_length = cursor_pos - r.GetMediaItemInfo_Value(item, "D_POSITION") + config.crossfade_duration
        new_length = math.min(current_length, new_length) -- Ne pas dÃ©passer la longueur originale
        
        -- DÃ©finir la nouvelle longueur et le fade out
        r.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
        r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", config.crossfade_duration)
      end
    end
    
    -- Marquer le nouveau fichier comme actif pour l'affichage
    file.active = true
    file.start_time = r.time_precise()
    
    -- Stocker le prochain fichier et mettre Ã  jour l'index de piste active
    next_folder_file = file
    active_track_index = next_track_index
    
    -- S'assurer que la lecture est en cours
    local play_state = r.GetPlayState()
    if play_state == 0 then -- Pas en lecture
      r.OnPlayButton()
    end
  else
    -- Pas de crossfade nÃ©cessaire, juste dÃ©marrer la lecture depuis le dÃ©but
    
    -- ArrÃªter toute lecture en cours
    stopAllFolderFiles()
    
    -- Nettoyer la piste courante
    local current_track = dedicated_tracks[active_track_index]
    local item_count = r.CountTrackMediaItems(current_track)
    for i = item_count - 1, 0, -1 do
      local item = r.GetTrackMediaItem(current_track, i)
      if item then
        r.DeleteTrackMediaItem(current_track, item)
      end
    end
    
    -- Ajouter le fichier Ã  la piste au dÃ©but
    local new_item = r.AddMediaItemToTrack(current_track)
    r.SetMediaItemPosition(new_item, 0, false)
    local new_take = r.AddTakeToMediaItem(new_item)
    local pcm_source = r.PCM_Source_CreateFromFile(file.path)
    r.SetMediaItemTake_Source(new_take, pcm_source)
    r.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", file.name, true)
    
    -- DÃ©finir la longueur de l'item selon la source
    local source_length = r.GetMediaSourceLength(pcm_source)
    r.SetMediaItemLength(new_item, source_length, false)
    
    -- Ajouter un fade-in au nouvel item mÃªme sans crossfade
    r.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", config.crossfade_duration)
    
    -- DÃ©placer le curseur au dÃ©but
    r.SetEditCurPos(0, true, false)
    
    -- SÃ©lectionner l'item et dÃ©marrer la lecture
    r.SetMediaItemSelected(new_item, true)
    r.Main_OnCommand(40317, 0)  -- Item: Play selected items
    
    -- Marquer comme fichier courant et enregistrer le temps de dÃ©marrage
    current_folder_file = file
    file.active = true
    file.start_time = r.time_precise()
    file.source_length = source_length -- Stocker la longueur pour dÃ©tecter la fin
  end
  
  r.Undo_EndBlock("Play Music File", -1) -- Changed from "Soundboard" to "Music"
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  
  return true
end

-- Update start time for a file
function updateStartTime(file)
  file.start_time = r.time_precise()
end

-- Play a track item via preview (without affecting arranger)
-- Jouer un aperÃ§u d'item avec la nouvelle API
function play_preview_item(track_idx, item_idx)
  local items = items_by_track[track_idx]
  if not items or not items[item_idx] then return end
  
  local item = items[item_idx]
  
  -- VÃ©rifier si cet item est dÃ©jÃ  en lecture - si oui, l'arrÃªter et sortir
  if current_preview_item and current_preview_item.ptr == item.ptr then
    stop_preview_item(item)
    return
  end
  
  -- IMPORTANT: Toujours arrÃªter toutes les previews existantes d'abord
  stopAllPreviews()
  
  -- L'API CF_Preview est-elle disponible?
  if CF_API_available then
    -- Obtenir la source de l'item
    local take = item.take_ptr
    local source = r.GetMediaItemTake_Source(take)
    
    -- Calculer prÃ©cisÃ©ment la durÃ©e et les offsets
    local take_offset = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local item_length = r.GetMediaItemInfo_Value(item.ptr, "D_LENGTH")
    local playback_rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    
    -- DurÃ©e rÃ©elle tenant compte du playback rate
    local actual_duration = item_length * playback_rate
    
    -- CrÃ©er un nouveau preview
    local preview = r.CF_CreatePreview(source)
    if preview then
      -- Configurer le preview
      r.CF_Preview_SetValue(preview, "D_VOLUME", 1.0)
      
      -- Utiliser le track de l'item pour la sortie
      local track = r.GetMediaItemTrack(item.ptr)
      r.CF_Preview_SetOutputTrack(preview, 0, track)
      
      -- Configurer le fade
      r.CF_Preview_SetValue(preview, "D_FADEINLEN", 0.02)
      r.CF_Preview_SetValue(preview, "D_FADEOUTLEN", 0.1)
      
      -- DÃ©finir la position de dÃ©part (offset)
      r.CF_Preview_SetValue(preview, "D_POSITION", take_offset)
      
      -- Configurer le taux de lecture pour correspondre Ã  l'item
      r.CF_Preview_SetValue(preview, "D_PLAYRATE", playback_rate)
      r.CF_Preview_SetValue(preview, "B_LOOP", 0)
      
      -- DÃ©marrer la lecture
      r.CF_Preview_Play(preview)
      
      -- Stocker le handle et les informations
      preview_handles[item.ptr] = preview
      preview_info[item.ptr] = {
        start_offset = take_offset,
        duration = actual_duration,
        end_position = take_offset + (actual_duration / playback_rate),
        playback_rate = playback_rate
      }
      
      -- Mettre Ã  jour l'Ã©tat de l'item
      item.playing = true
      current_preview_item = item
      actually_playing = true
      
      -- Mettre Ã  jour le temps de dÃ©marrage et la durÃ©e
      preview_start_time = r.time_precise()
      preview_duration = actual_duration
      
      return true
    end
  else
    -- MÃ©thode standard si CF_Preview n'est pas disponible
    local success = false
    
    if ultraschall_available then
      success = ultraschall.PreviewMediaItem(item.ptr, 3)
    else
      -- MÃ©thode standard avec calcul prÃ©cis de la durÃ©e
      local take = item.take_ptr
      local source = r.GetMediaItemTake_Source(take)
      local track = r.GetMediaItemTrack(item.ptr)
      local take_offset = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      local source_file = r.GetMediaSourceFileName(source, "")
      
      -- Calculer la durÃ©e exacte
      local item_length = r.GetMediaItemInfo_Value(item.ptr, "D_LENGTH")
      local playback_rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local actual_duration = item_length
      
      r.PlayTrackPreview2(track, source_file, 0, take_offset, actual_duration, false)
      success = true
    end
    
    if success then
      item.playing = true
      current_preview_item = item
      actually_playing = true
      
      local take = item.take_ptr
      local item_length = r.GetMediaItemInfo_Value(item.ptr, "D_LENGTH") 
      preview_start_time = r.time_precise()
      preview_duration = item_length
    end
    
    return success
  end
  
  return false
end

-- ArrÃªter un preview spÃ©cifique
function stop_preview_item(item)
  if not item then return false end
  
  if CF_API_available and preview_handles[item.ptr] then
    -- ArrÃªter avec l'API CF_Preview
    r.CF_Preview_Stop(preview_handles[item.ptr])
    preview_handles[item.ptr] = nil
    preview_info[item.ptr] = nil
    
    -- Mettre Ã  jour l'Ã©tat
    item.playing = false
    if current_preview_item and current_preview_item.ptr == item.ptr then
      current_preview_item = nil
      actually_playing = false
    end
    
    return true
  else
    -- Fallback vers la mÃ©thode existante
    stopAllPreviews()
    return true
  end
end

-- Function to rename an item
function renameItem(track_idx, item_idx)
  local items = items_by_track[track_idx]
  if not items or not items[item_idx] then return end
  
  local item = items[item_idx]
  local take = item.take_ptr
  
  -- Show input dialog with current name
  local retval, new_name = r.GetUserInputs("Rename Item", 1, "Enter new name:", item.name)
  
  if retval and new_name ~= "" then
    -- Update the take name
    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
    
    -- Update our local data
    item.name = new_name
    
    -- Force a refresh of the project data
    refresh_tracks_and_items()
  end
end

-- Function to rename a track (column)
function renameTrack(track_idx)
  if not tracks[track_idx + 1] then return end
  
  local track = tracks[track_idx + 1]
  
  -- Show input dialog with current name
  local retval, new_name = r.GetUserInputs("Rename Track", 1, "Enter new name:", track.name)
  
  if retval and new_name ~= "" then
    -- Update the track name
    r.GetSetMediaTrackInfo_String(track.ptr, "P_NAME", new_name, true)
    
    -- Update our local data
    track.name = new_name
    
    -- Force a refresh of the project data
    refresh_tracks_and_items()
  end
end

-- Function to rename a folder file
function renameFolderFile(file_idx)
  local file = folder_files[file_idx]
  if not file then return end
  
  -- Show input dialog with current name
  local retval, new_name = r.GetUserInputs("Rename File Display Name", 1, "Enter display name:", file.name)
  
  if retval and new_name ~= "" then
    -- Update display name (not the actual file)
    file.name = new_name
  end
end

function handleItemClick(track_idx, item_idx)
  play_preview_item(track_idx, item_idx)
end

-- Function to handle folder file click
function handleFolderFileClick(file_idx)
  play_folder_file(file_idx)
end

-- Function to display folder files column
function display_folder_column(column_width)
  -- Push styling for the column background
  r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_ChildBg(), config.child_bg)
  r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Border(), config.border_color)
  r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ChildBorderSize(), config.border_size)
  r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ChildRounding(), config.child_rounding)
  
  -- Create the column container with border
  local child_flags = r.ImGui_WindowFlags_None() -- Utilise None au lieu de Border qui n'existe pas
  
  if r.ImGui_BeginChild(gui.ctx, "FolderFiles", column_width, 0, child_flags) then
    -- Increased spacing and padding for header
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ItemSpacing(), 12, 12)
    
    -- Column header with title vertically centered
    r.ImGui_Dummy(gui.ctx, 0, 6) -- Add top spacing to vertically center the title

    -- Use title font if available
    if gui.title_font then r.ImGui_PushFont(gui.ctx, gui.title_font) end

    -- Calculate the width needed for browse button and spacing
    local browse_width = 85 -- Ajustez si nÃ©cessaire selon la taille rÃ©elle du bouton
    local browse_pos = column_width - browse_width
    local text_width = r.ImGui_CalcTextSize(gui.ctx, "Music")
    local title_pos = (browse_pos - text_width) / 2

    -- Set cursor position to center title
    r.ImGui_SetCursorPosX(gui.ctx, title_pos)
    r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Text(), config.first_column_color)
    r.ImGui_Text(gui.ctx, "Music")
    r.ImGui_PopStyleColor(gui.ctx)

    if gui.title_font then r.ImGui_PopFont(gui.ctx) end

    r.ImGui_SameLine(gui.ctx)
    r.ImGui_SetCursorPosX(gui.ctx, browse_pos) -- Position the button at the right sides

    
    -- Prettier button style
    r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Button(), 0x3D78B4FF)
    r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_ButtonHovered(), 0x4D88C4FF)
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_FrameRounding(), config.button_rounding)
    
    if r.ImGui_Button(gui.ctx, "Browse...") then
      local folder = browseForFolder()
      if folder then
        current_folder = folder
        config.last_folder = folder
        refresh_folder_files()
      end
    end
    
    r.ImGui_PopStyleVar(gui.ctx)
    r.ImGui_PopStyleColor(gui.ctx, 2)
    
    -- r.ImGui_Dummy(gui.ctx, 0, 5) -- Add bottom spacing to vertically center the title
    
    -- Crossfade slider with better layout
    r.ImGui_Dummy(gui.ctx, 0, 0) -- Add bottom spacing to vertically center the title

    -- Le sÃ©parateur doit Ãªtre au mÃªme niveau que dans display_track_column
    r.ImGui_Separator(gui.ctx)
    -- r.ImGui_Dummy(gui.ctx, 0, config.section_spacing) -- Add spacing after separator
    
    -- Fade control with more space and proper margins
    r.ImGui_SetCursorPosX(gui.ctx, config.text_margin) -- Left margin for text
    r.ImGui_Text(gui.ctx, "Crossfade:")
    r.ImGui_SameLine(gui.ctx, 0) -- Better spacing for alignment
    r.ImGui_SetNextItemWidth(gui.ctx, column_width - 100) -- Leave margin for slider
    
    r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_FrameBg(), 0x222222FF)
    r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_SliderGrab(), config.first_column_color)
    
    local fade_changed
    fade_changed, config.crossfade_duration = r.ImGui_SliderDouble(gui.ctx, "##crossfade", config.crossfade_duration, 0.0, 5.0, "%.1f s")
    
    r.ImGui_PopStyleColor(gui.ctx, 2)
    
    -- Espace supplÃ©mentaire aprÃ¨s le slider de crossfade
    -- r.ImGui_Dummy(gui.ctx, 0, config.section_spacing)
    
    r.ImGui_PopStyleVar(gui.ctx) -- Pop item spacing
    
    -- r.ImGui_Dummy(gui.ctx, 0, config.section_spacing) -- Add space after the crossfade control
    r.ImGui_Separator(gui.ctx)
    r.ImGui_Dummy(gui.ctx, 0, config.section_spacing) -- Add spacing after separator
    
    -- Pad content inside column
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ItemSpacing(), config.column_padding, config.column_padding)
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_FrameRounding(), config.button_rounding)
    
    if #folder_files > 0 then
      for i, file in ipairs(folder_files) do
        -- Button style based on playback state
        if file.active then
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Button(), config.active_color)
          
          -- Utiliser une couleur rouge pour le survol d'un fichier dÃ©jÃ  actif (indique "stop")
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_ButtonHovered(), 0xAA3333FF)
        else
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Button(), config.inactive_color)
          
          -- Couleur de survol normale pour les items inactifs
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_ButtonHovered(), config.item_hover_color)
        end
        
        -- Calculate available width for button
        local avail_width = r.ImGui_GetContentRegionAvail(gui.ctx)
        
        -- Button for the file
        if r.ImGui_Button(gui.ctx, file.name .. "##folder_" .. i, avail_width, config.item_height) then
          handleFolderFileClick(i)
        end
        
        -- Handle right-click for renaming
        if r.ImGui_IsItemClicked(gui.ctx, 1) then -- 1 = right mouse button
          renameFolderFile(i)
        end
        
        -- Tooltip with full info
        if config.show_tooltips and r.ImGui_IsItemHovered(gui.ctx) then
          r.ImGui_BeginTooltip(gui.ctx)
          r.ImGui_Text(gui.ctx, "Filename: " .. file.filename)
          r.ImGui_Text(gui.ctx, "Full path: " .. file.path)
          r.ImGui_EndTooltip(gui.ctx)
        end
        
        r.ImGui_PopStyleColor(gui.ctx, 2) -- Pop button color and hover color
      end
    else
      -- Add margin to the no files text
      r.ImGui_SetCursorPosX(gui.ctx, config.text_margin)
      r.ImGui_TextColored(gui.ctx, config.muted_text_color, "No audio files found")
      r.ImGui_SetCursorPosX(gui.ctx, config.text_margin)
      r.ImGui_TextColored(gui.ctx, config.muted_text_color, "Click Browse to select a folder")
    end
    
    r.ImGui_PopStyleVar(gui.ctx, 2) -- Pop item spacing and frame rounding
    r.ImGui_EndChild(gui.ctx)
  end
  
  -- Pop styling
  r.ImGui_PopStyleVar(gui.ctx, 2) -- Pop ChildBorderSize and ChildRounding
  r.ImGui_PopStyleColor(gui.ctx, 2) -- Pop ChildBg and Border colors
end

-- Fonction d'aide pour ImGui_BeginChild
function getChildFlags(border)
  if border then
    -- Pas de WindowFlags_Border dans REAPER, utilisons None() Ã  la place
    return r.ImGui_WindowFlags_None()
  else
    return 0
  end
end

-- Recharger et appliquer les styles en temps rÃ©el (pour l'aperÃ§u immÃ©diat)
function reloadStyleConfig()
  -- Essaie de charger la configuration de style depuis l'ExtState
  local new_config = false
  local ext_state = r.GetExtState("CP_ProjectSoundboard", "style_config")
  if ext_state ~= "" then
    local success, loaded_config = pcall(function() return load("return " .. ext_state)() end)
    if success and type(loaded_config) == "table" then
      -- Fusionner avec la configuration actuelle
      for k, v in pairs(loaded_config) do
        config[k] = v
      end
      new_config = true
    end
  end
  return new_config
end

-- Function to display a track column
function display_track_column(track_idx, column_width)
  if not tracks[track_idx + 1] then return end
  
  local track = tracks[track_idx + 1]
  local column_items = items_by_track[track.index] or {}
  
  -- Push styling for the column background
  r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_ChildBg(), config.child_bg)
  r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Border(), config.border_color)
  r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ChildBorderSize(), config.border_size)
  r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ChildRounding(), config.child_rounding)
  
  -- Create the column container with border
  local child_flags = r.ImGui_WindowFlags_None() -- Utilise None au lieu de Border qui n'existe pas
  
  if r.ImGui_BeginChild(gui.ctx, "Track_" .. track_idx, column_width, 0, child_flags) then
    -- Column header with track name
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ItemSpacing(), 12, 12)
    r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Text(), config.other_track_color)
    
    -- Vertically center track name by adding dummy space before and after
    r.ImGui_Dummy(gui.ctx, 0, 6) -- Add top spacing to vertically center the title
    
    -- Use title font if available
    if gui.title_font then r.ImGui_PushFont(gui.ctx, gui.title_font) end
    
    -- Center track name text
    local text_width = r.ImGui_CalcTextSize(gui.ctx, track.name)
    local content_width = r.ImGui_GetContentRegionAvail(gui.ctx)
    r.ImGui_SetCursorPosX(gui.ctx, (content_width - text_width) / 2)
    
    -- Make track name clickable for right-click renaming
    r.ImGui_Text(gui.ctx, track.name)
    
    if gui.title_font then r.ImGui_PopFont(gui.ctx) end
    
    if r.ImGui_IsItemClicked(gui.ctx, 1) then -- 1 = right mouse button
      renameTrack(track_idx)
    end
    
    r.ImGui_Dummy(gui.ctx, 0, 0) -- Add bottom spacing to vertically center the title
    
    r.ImGui_PopStyleColor(gui.ctx) -- Pop text color
    r.ImGui_PopStyleVar(gui.ctx) -- Pop item spacing
    
    r.ImGui_Separator(gui.ctx)
    r.ImGui_Dummy(gui.ctx, 0, config.section_spacing) -- Add spacing after separator
    
    -- Pad content inside column
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ItemSpacing(), config.column_padding, config.column_padding)
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_FrameRounding(), config.button_rounding)
    
    if #column_items > 0 then
      for item_idx, item in ipairs(column_items) do
        -- Button style based on playback state
        if item.playing then
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Button(), config.active_color) -- Couleur active
          
          -- Utiliser une couleur rouge pour le survol d'un item dÃ©jÃ  actif (indique "stop")
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_ButtonHovered(), 0xAA3333FF)
        else
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Button(), config.inactive_color) -- Couleur inactive
          
          -- Couleur de survol normale pour les items inactifs
          r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_ButtonHovered(), config.item_hover_color)
        end
        
        -- Calculate available width for button
        local avail_width = r.ImGui_GetContentRegionAvail(gui.ctx)
        
        -- Button for the item
        if r.ImGui_Button(gui.ctx, item.name .. "##" .. track_idx .. "_" .. item_idx, avail_width, config.item_height) then
          handleItemClick(track.index, item_idx)
        end

        -- DÃ©tection du clic droit pour renommer
        if r.ImGui_IsItemClicked(gui.ctx, 1) then -- 1 = clic droit
          renameItem(track.index, item_idx)
        end
        
        -- Tooltip with item position and length
        if config.show_tooltips and r.ImGui_IsItemHovered(gui.ctx) then
          r.ImGui_BeginTooltip(gui.ctx)
          r.ImGui_Text(gui.ctx, string.format("Position: %.2f s", item.position))
          r.ImGui_Text(gui.ctx, string.format("Length: %.2f s", item.length))
          r.ImGui_EndTooltip(gui.ctx)
        end
        
        r.ImGui_PopStyleColor(gui.ctx, 2) -- Pop button color and hover color
      end
    else
      -- Add margin to the no items text
      r.ImGui_SetCursorPosX(gui.ctx, config.text_margin)
      r.ImGui_TextColored(gui.ctx, config.muted_text_color, "No items")
      r.ImGui_SetCursorPosX(gui.ctx, config.text_margin)
      r.ImGui_TextColored(gui.ctx, config.muted_text_color, "Add media items to this track")
    end
    
    r.ImGui_PopStyleVar(gui.ctx, 2) -- Pop item spacing and frame rounding
    r.ImGui_EndChild(gui.ctx)
  end
  
  -- Pop styling
  r.ImGui_PopStyleVar(gui.ctx, 2) -- Pop ChildBorderSize and ChildRounding
  r.ImGui_PopStyleColor(gui.ctx, 2) -- Pop ChildBg and Border colors
end

-- Main interface function
function loop()
  -- Check if context is valid
  if not ctx_valid then
    return
  end
  
  -- Check if it's time to refresh the project data
  local current_time = r.time_precise()
  if current_time - last_refresh >= config.refresh_interval then
    if hasProjectChanged() then
      refresh_tracks_and_items()
    end
    last_refresh = current_time
  end
  
  -- Check if it's time to update preview state
  if current_time - last_preview_check >= config.preview_check_interval then
    checkPreviewState()
    last_preview_check = current_time
    
    -- VÃ©rifier s'il y a des modifications de style Ã  appliquer (pour l'aperÃ§u immÃ©diat)
    reloadStyleConfig()
  end
  
  -- Apply global styles if available
  if style_loader then
    local success, colors, vars = style_loader.applyToContext(gui.ctx)
    if success then
      pushed_colors, pushed_vars = colors, vars
    end
  end
  
  -- Set window background and text color
  r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_WindowBg(), config.window_bg)
  r.ImGui_PushStyleColor(gui.ctx, r.ImGui_Col_Text(), config.text_color)
  r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_WindowRounding(), config.window_rounding)
  r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ScrollbarSize(), config.scrollbar_size)
  r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_WindowBorderSize(), config.border_size)
  
  -- Set window flags
  local window_flags = r.ImGui_WindowFlags_None()
  
  -- Begin window
  local visible, open = r.ImGui_Begin(gui.ctx, 'Soundboard', true, window_flags) -- Changed from 'Soundboard' to 'Musics'
  
  -- Get new dock state for tracking
  if r.ImGui_GetWindowDockID then
    local new_dock_state = r.ImGui_GetWindowDockID(gui.ctx)
    if new_dock_state ~= dock_state then
      dock_state = new_dock_state
    end
  end
  
  if visible then
    -- Push font if available
    if gui.font then
      r.ImGui_PushFont(gui.ctx, gui.font)
    end
    
    -- Modifiez la section de calcul des dimensions
    local window_width = r.ImGui_GetWindowWidth(gui.ctx)
    local track_count = #tracks

    -- RÃ©servez de l'espace pour la marge droite dÃ¨s le dÃ©part
    local right_margin = config.column_spacing
    local adjusted_width = window_width - right_margin * 2

    -- Calculez ensuite les colonnes avec la largeur ajustÃ©e
    local max_columns = track_count + 1 
    local columns_to_display = math.min(max_columns, config.columns_per_page)
    if columns_to_display <= 0 then columns_to_display = 1 end

    -- Calculez la largeur de colonne avec la nouvelle largeur ajustÃ©e
    local total_spacing = config.column_spacing * (columns_to_display - 1)
    local column_width = (adjusted_width - total_spacing) / columns_to_display
        
    -- Display columns side by side
    r.ImGui_PushStyleVar(gui.ctx, r.ImGui_StyleVar_ItemSpacing(), config.column_spacing, 0)
    
    -- First display folder files column
    display_folder_column(column_width)
    
    -- Then display track columns (starting from index 0)
    for i = 0, columns_to_display - 2 do
      r.ImGui_SameLine(gui.ctx)
      display_track_column(i, column_width)
    end
    
    -- Ajouter un espacement vide Ã  droite pour la derniÃ¨re colonne
    if columns_to_display > 0 then
      r.ImGui_SameLine(gui.ctx)
      r.ImGui_Dummy(gui.ctx, config.column_spacing, 1)
    end
    
    r.ImGui_PopStyleVar(gui.ctx) -- Pop ItemSpacing
    
    -- Pop font if it was pushed
    if gui.font then
      r.ImGui_PopFont(gui.ctx)
    end
  end
  
  r.ImGui_End(gui.ctx)
  
  -- Pop style colors for window
  r.ImGui_PopStyleVar(gui.ctx, 3) -- Pop WindowRounding, ScrollbarSize, WindowBorderSize
  r.ImGui_PopStyleColor(gui.ctx, 2) -- Pop WindowBg and TextColor
  
  -- Clean up global styles
  if style_loader then
    style_loader.clearStyles(gui.ctx, pushed_colors, pushed_vars)
  end
  
  if open then
    r.defer(loop)
  else
    -- Stop all playing sounds
    stopAllPreviews()
    stopAllFolderFiles()
    
    -- Save settings
    saveSettings()
  end
end

-- Error handling wrapper
function safeInit()
  checkCFPreviewAPI()
  local success, err = pcall(init)
  if not success then
    r.ShowMessageBox("Error initializing: " .. tostring(err), "Error", 0)
    return false
  end
  return true
end

-- Start script
if safeInit() then
  loop()
end









