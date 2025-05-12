-- Configuration
local WINDOW_FOLLOW_MOUSE = false

local time_selection_extension = 0.0
local sync_edit_cursor = false
local sync_automation = false
local sync_time_selection = true 
local auto_play = true
local playback_mode = "preview"
local last_selected_item_guid = nil
local mouse_down_time = 0
local last_mouse_state = 0
local CLICK_THRESHOLD = 0.15
local mouse_down_start = 0
local LONG_PRESS_THRESHOLD = 0.15  -- Seuil en secondes pour considérer un appui comme "long"
local is_dragging = false
local last_track_guid = nil

local last_refresh_time = 0
local lastSelectedItems = {}
local lastItemPositions = {}
local lastItemLengths = {}
local last_edit_cursor_pos = -1
local last_envelope_count = {}
local last_item_positions = {}
local last_item_lengths = {}
local last_item_rates = {}
local last_item_selection = {}


local WINDOW_X_OFFSET = 35  -- Horizontal offset from mouse position in pixels
local WINDOW_Y_OFFSET = 35  -- Vertical offset from mouse position in pixels
local WINDOW_WIDTH = 275   -- Initial window width in pixels
local WINDOW_HEIGHT = 275   -- Initial window height in pixels

-- Variables pour l'interface ImGui
local ctx = reaper.ImGui_CreateContext('Time Selection Extension Config')
local WINDOW_FLAGS = 0
local window_open = true
local window_position_set = false  -- Add this line

-- Load the style loader module
local style_loader_path = reaper.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

-- Variables globales pour le tracking des changements
local last_edit_cursor_pos = -1
local lastItemState = {
  position = nil,
  length = nil,
  rate = nil,
  sourceLength = nil,
  stretchMarkersHash = nil
}
local lastAutomationStates = {}
local lastEnvelopeCount = {}


-- Ajouter ces fonctions au début du script
function SaveSettings()
  reaper.SetExtState("TimeSelectionSync", "playback_mode", playback_mode, true)
  reaper.SetExtState("TimeSelectionSync", "sync_edit_cursor", sync_edit_cursor and "1" or "0", true)
  reaper.SetExtState("TimeSelectionSync", "sync_automation", sync_automation and "1" or "0", true)
  reaper.SetExtState("TimeSelectionSync", "sync_time_selection", sync_time_selection and "1" or "0", true) -- Nouvelle ligne
  reaper.SetExtState("TimeSelectionSync", "auto_play", auto_play and "1" or "0", true)
  reaper.SetExtState("TimeSelectionSync", "time_selection_extension", tostring(time_selection_extension), true)
end

-- Mettre à jour LoadSettings pour charger la nouvelle option
function LoadSettings()
  local cursor = reaper.GetExtState("TimeSelectionSync", "sync_edit_cursor")
  local automation = reaper.GetExtState("TimeSelectionSync", "sync_automation")
  local time_sel = reaper.GetExtState("TimeSelectionSync", "sync_time_selection") -- Nouvelle ligne
  local play = reaper.GetExtState("TimeSelectionSync", "auto_play")
  local ext = reaper.GetExtState("TimeSelectionSync", "time_selection_extension")
  local mode = reaper.GetExtState("TimeSelectionSync", "playback_mode")

  playback_mode = mode ~= "" and mode or "preview"
  sync_edit_cursor = cursor == "1"
  sync_automation = automation == "1"
  sync_time_selection = time_sel == "1" -- Correction du chargement
  auto_play = play == "1"
  time_selection_extension = ext ~= "" and tonumber(ext) or 0.0
end

-- Fonction pour comparer deux nombres avec une tolérance
local function approximately(a, b, tolerance)
  tolerance = tolerance or 0.000001
  return math.abs(a - b) < tolerance
end

-- Fonction pour calculer un hash des stretch markers
local function calculateStretchMarkersHash(take)
  if not take then return "" end
  
  local hash = ""
  local stretchMarkerCount = reaper.GetTakeNumStretchMarkers(take)
  
  for i = 0, stretchMarkerCount - 1 do
    local retval, pos, srcpos = reaper.GetTakeStretchMarker(take, i)
    if retval >= 0 then
      hash = hash .. string.format("%.6f:%.6f;", pos, srcpos)
    end
  end
  
  return hash
end

-- Fonction pour obtenir l'état actuel d'un item
local function getItemState(item)
  if not item then return nil end
  
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local take = reaper.GetActiveTake(item)
  local rate = take and reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
  
  -- Obtenir la source length
  local sourceLength = 0
  if take then
    local source = reaper.GetMediaItemTake_Source(take)
    if source then
      local source_length, lengthIsQN = reaper.GetMediaSourceLength(source)
      if lengthIsQN then
        local tempo = reaper.Master_GetTempo()
        sourceLength = source_length * 60 / tempo
      else
        sourceLength = source_length
      end
    end
  end
  
  local stretchMarkersHash = take and calculateStretchMarkersHash(take) or ""
  
  return {
    position = pos,
    length = length,
    rate = rate,
    sourceLength = sourceLength,
    stretchMarkersHash = stretchMarkersHash
  }
end

function GetSelectedItemsRange()
  local start_pos = math.huge 
  local end_pos = -math.huge
  local num_items = reaper.CountSelectedMediaItems(0)
  
  for i = 0, num_items-1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end = item_pos + item_length
      
      start_pos = math.min(start_pos, item_pos)
      end_pos = math.max(end_pos, item_end)
  end
  
  if start_pos == math.huge then return nil, nil end
  return start_pos, end_pos
end

-- Fonction pour obtenir l'état d'un automation item
local function getAutomationItemState(env, idx)
  local pos = reaper.GetSetAutomationItemInfo(env, idx, "D_POSITION", 0, false)
  local len = reaper.GetSetAutomationItemInfo(env, idx, "D_LENGTH", 0, false)
  local rate = reaper.GetSetAutomationItemInfo(env, idx, "D_PLAYRATE", 0, false)
  
  return {
    position = pos,
    length = len,
    rate = rate
  }
end

-- Fonction pour détecter les changements d'enveloppes
function detectEnvelopeChanges(track)
  if not track then return false end
  
  local track_guid = reaper.GetTrackGUID(track)
  local current_env_count = reaper.CountTrackEnvelopes(track)
  
  if last_envelope_count[track_guid] ~= current_env_count then
      last_envelope_count[track_guid] = current_env_count
      return true
  end
  
  return false
end

function isClickOnSelectedItem()
  local x, y = reaper.GetMousePosition()
  local item = reaper.GetItemFromPoint(x, y, false)
  if not item then return false end
  
  -- Si un item est trouvé sous la souris et qu'il est sélectionné
  local is_selected = reaper.IsMediaItemSelected(item)
  if not is_selected then return false end
  
  -- Vérifier si clic gauche
  local left_click = reaper.JS_Mouse_GetState(1) == 1
  local was_clicked = left_click and last_mouse_state == 0
  last_mouse_state = left_click and 1 or 0
  
  return was_clicked
end

-- Fonction pour détecter les changements
function detectChanges()
  local changes_detected = false
  
  -- Détecter le clic sur item
  if isClickOnSelectedItem() then
      return true
  end
  
  -- Vérifier le changement de sélection
  local current_selection = {}
  local num_selected = reaper.CountSelectedMediaItems(0)
  for i = 0, num_selected - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      local guid = reaper.BR_GetMediaItemGUID(item)
      current_selection[guid] = true
      
      if not last_item_selection[guid] then
          changes_detected = true
      end
  end
  
  for guid in pairs(last_item_selection) do
      if not current_selection[guid] then
          changes_detected = true
      end
  end
  
  last_item_selection = current_selection
  
  -- Vérifier les changements des items sélectionnés
  for i = 0, num_selected - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      local guid = reaper.BR_GetMediaItemGUID(item)
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local take = reaper.GetActiveTake(item)
      local rate = take and reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
      
      -- Vérifier les changements d'enveloppes
      local track = reaper.GetMediaItem_Track(item)
      if detectEnvelopeChanges(track) then
          changes_detected = true
      end
      
      -- Vérifier les changements de position/taille/rate
      if last_item_positions[guid] ~= pos or
         last_item_lengths[guid] ~= length or
         last_item_rates[guid] ~= rate then
          changes_detected = true
      end
      
      last_item_positions[guid] = pos
      last_item_lengths[guid] = length
      last_item_rates[guid] = rate
  end
  
  -- Vérifier la position de l'edit cursor
  local cursor_pos = reaper.GetCursorPosition()
  if sync_edit_cursor and last_edit_cursor_pos ~= cursor_pos then
      changes_detected = true
  end
  
  return changes_detected
end

function isMouseOverMediaItem()
  local x, y = reaper.GetMousePosition()
  local item, take = reaper.GetItemFromPoint(x, y, false)
  return item
end

function isReaperWindowActive()
  local hwnd = reaper.GetMainHwnd()
  return reaper.JS_Window_GetForeground() == hwnd
end

function isLeftClick()
  local current_mouse_state = reaper.JS_Mouse_GetState(1)
  local current_time = reaper.time_precise()
  
  -- Début de l'appui
  if current_mouse_state == 1 and last_mouse_state == 0 then
    mouse_down_time = current_time
    mouse_down_start = current_time
    is_dragging = false
  end
  
  -- Pendant l'appui, vérifier si c'est un appui long
  if current_mouse_state == 1 and last_mouse_state == 1 then
    if (current_time - mouse_down_start) > LONG_PRESS_THRESHOLD then
      is_dragging = true
      -- Stop le transport si on commence à déplacer un item
      if is_dragging and reaper.GetPlayState() == 1 then
        reaper.Main_OnCommand(1016, 0) -- Transport: Stop
      end
    end
  end
  
  -- Relâchement du clic
  if current_mouse_state == 0 and last_mouse_state == 1 then
    local was_short_click = (current_time - mouse_down_start) < LONG_PRESS_THRESHOLD and not is_dragging
    last_mouse_state = current_mouse_state
    return was_short_click
  end
  
  last_mouse_state = current_mouse_state
  return false
end

function PlaySelectedItem()
  if not (auto_play and isReaperWindowActive()) then 
    return 
  end

  local selected_item_count = reaper.CountSelectedMediaItems(0)
  local is_playing = reaper.GetPlayState() & 1 == 1
  local is_previewing = reaper.GetPlayState() & 4 == 4
  
  -- Stop any current playback
  if selected_item_count == 0 and (is_playing or is_previewing) then
    if playback_mode == "preview" then
      reaper.Main_OnCommand(reaper.NamedCommandLookup("_BR_PREV_TAKE_CURSOR"), 0)
    else
      reaper.Main_OnCommand(1016, 0)  -- Stop
    end
    return
  end
  
  if selected_item_count == 0 then return end

  local clicked_item = isMouseOverMediaItem()
  if clicked_item and isLeftClick() then
    reaper.SetMediaItemSelected(clicked_item, true)
    -- Set edit cursor to item start
    local item_pos = reaper.GetMediaItemInfo_Value(clicked_item, "D_POSITION")
    reaper.SetEditCurPos(item_pos, false, false)
    -- Play based on selected mode
    if playback_mode == "preview" then
      reaper.Main_OnCommand(reaper.NamedCommandLookup("_BR_PREV_TAKE_CURSOR"), 0)
    else
      reaper.Main_OnCommand(1007, 0)  -- Play
    end
  end
end

-- Ajouter cette fonction dans la boucle MainLoop
function ProcessFades()
  if not is_fading or not fade_start_time then return end
  
  local master_track = reaper.GetMasterTrack(0)
  local current_time = reaper.time_precise()
  local elapsed = current_time - fade_start_time
  local fade_duration = fade_type == "in" and FADE_IN_LENGTH or FADE_OUT_LENGTH
  
  if elapsed >= fade_duration then
    -- Fin du fade
    if fade_type == "in" then
      reaper.SetMediaTrackInfo_Value(master_track, "D_VOL", 1)
    else
      reaper.Main_OnCommand(1016, 0) -- Transport: Stop
      reaper.SetMediaTrackInfo_Value(master_track, "D_VOL", 1)
    end
    is_fading = false
    fade_start_time = nil
    return
  end
  
  local progress = elapsed / fade_duration
  local vol = fade_type == "in" and progress or (1 - progress)
  reaper.SetMediaTrackInfo_Value(master_track, "D_VOL", vol)
end

function SyncAutomationItems()
  local num_selected = reaper.CountSelectedMediaItems(0)
  if num_selected == 0 then return end
  
  -- Obtenir la plage totale des items sélectionnés
  local total_start, total_end = GetSelectedItemsRange()
  if not total_start then return end
  
  -- Synchronisation de la time selection
  if sync_time_selection then
      local start_time = total_start
      local end_time = total_end + time_selection_extension
      reaper.GetSet_LoopTimeRange(true, false, start_time, end_time, false)
  end
  
  -- Synchronisation de l'edit cursor
  if sync_edit_cursor then
      reaper.SetEditCurPos(total_start, false, false)
      last_edit_cursor_pos = total_start
  end
  
  -- Synchronisation des automation items
  if sync_automation then
      for i = 0, num_selected - 1 do
          local item = reaper.GetSelectedMediaItem(0, i)
          local take = reaper.GetActiveTake(item)
          if not take then goto continue end
          
          local track = reaper.GetMediaItem_Track(item)
          local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local item_rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          
          -- Mise à jour des automation items
          local env_count = reaper.CountTrackEnvelopes(track)
          for k = 0, env_count - 1 do
              local env = reaper.GetTrackEnvelope(track, k)
              
              -- Vérifier si l'enveloppe est visible
              local br_env = reaper.BR_EnvAlloc(env, false)
              local _, _, _, _, _, visible = reaper.BR_EnvGetProperties(br_env)
              reaper.BR_EnvFree(br_env, false)
              if not visible then goto continue_env end
              
              local ai_count = reaper.CountAutomationItems(env)
              local ai_found = false
              
              for l = 0, ai_count - 1 do
                  local ai_pos = reaper.GetSetAutomationItemInfo(env, l, "D_POSITION", 0, false)
                  
                  if approximately(ai_pos, item_pos) then
                      reaper.GetSetAutomationItemInfo(env, l, "D_LENGTH", math.max(item_length, 0.1), true)
                      reaper.GetSetAutomationItemInfo(env, l, "D_PLAYRATE", item_rate, true)
                      reaper.GetSetAutomationItemInfo(env, l, "D_LOOPLEN", item_length, true)
                      reaper.GetSetAutomationItemInfo(env, l, "D_POOL_LOOPLEN", item_length, true)
                      ai_found = true
                      break
                  end
              end
              
              if not ai_found then
                  local new_ai = reaper.InsertAutomationItem(env, -1, item_pos, math.max(item_length, 0.1))
                  reaper.GetSetAutomationItemInfo(env, new_ai, "D_PLAYRATE", item_rate, true)
                  reaper.GetSetAutomationItemInfo(env, new_ai, "D_LOOPLEN", item_length, true)
                  reaper.GetSetAutomationItemInfo(env, new_ai, "D_POOL_LOOPLEN", item_length, true)
              end
              
              ::continue_env::
          end
          
          ::continue::
      end
  end
  
  reaper.UpdateTimeline()
end


function MainLoop()
  -- Définit la position de la fenêtre au premier lancement
  if not window_position_set then
      if WINDOW_FOLLOW_MOUSE then
          local mouse_x, mouse_y = reaper.GetMousePosition()
          reaper.ImGui_SetNextWindowPos(ctx, mouse_x + WINDOW_X_OFFSET, mouse_y + WINDOW_Y_OFFSET)
      end
      reaper.ImGui_SetNextWindowSize(ctx, WINDOW_WIDTH, WINDOW_HEIGHT)
      window_position_set = true
  end

  -- Apply global styles if available
  if style_loader then
    local success, colors, vars = style_loader.applyToContext(ctx)
    if success then
      pushed_colors, pushed_vars = colors, vars
    end
  end

  local visible, open = reaper.ImGui_Begin(ctx, 'Time Selection Config', true, WINDOW_FLAGS)
  if visible then
    -- Options section
    reaper.ImGui_Text(ctx, "Options:")
    reaper.ImGui_Spacing(ctx)
    
    -- Time Selection option
    local time_sel_changed
    time_sel_changed, sync_time_selection = reaper.ImGui_Checkbox(ctx, "Sync Time Selection", sync_time_selection)
    reaper.ImGui_Spacing(ctx)
    
    local cursor_changed
    cursor_changed, sync_edit_cursor = reaper.ImGui_Checkbox(ctx, "Sync Edit Cursor", sync_edit_cursor)
    reaper.ImGui_Spacing(ctx)
    
    local automation_changed
    automation_changed, sync_automation = reaper.ImGui_Checkbox(ctx, "Sync Automation", sync_automation)
    reaper.ImGui_Spacing(ctx)
    
    local play_changed
    play_changed, auto_play = reaper.ImGui_Checkbox(ctx, "Auto-Play", auto_play)

    -- Extension settings (seulement visible si sync_time_selection est activé)
    if sync_time_selection then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)
      
      reaper.ImGui_Text(ctx, string.format("Time Selection Extension: %.2f s", time_selection_extension))
      reaper.ImGui_Spacing(ctx)
      
      local changed
      changed, time_selection_extension = reaper.ImGui_SliderDouble(ctx, 's', 
                                                                time_selection_extension, 0.0, 5.0, '%.2f')
      reaper.ImGui_Spacing(ctx)
      
      -- Preset buttons
      reaper.ImGui_Text(ctx, "Presets:")
      if reaper.ImGui_Button(ctx, "0.0s") then
        time_selection_extension = 0.0
        changed = true
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "0.1s") then
        time_selection_extension = 0.1
        changed = true
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "0.3s") then
        time_selection_extension = 0.3
        changed = true
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "0.5s") then
        time_selection_extension = 0.5
        changed = true
      end
      
      if changed or cursor_changed or automation_changed or play_changed or time_sel_changed then
        SaveSettings()
      end
    end
    
    reaper.ImGui_End(ctx)
  end

  -- Clean up global styles
  if style_loader then
    style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
  end

  -- Process automation and features
  if auto_play then 
      PlaySelectedItem() 
  end
    
  local current_time = reaper.time_precise()
    if current_time - last_refresh_time >= 0.025 then -- 100ms minimum entre les updates
      if detectChanges() then
          SyncAutomationItems()
      end
      last_refresh_time = current_time
  end
    
  reaper.PreventUIRefresh(-1)
    
  if open then
      reaper.defer(MainLoop)
  else
      SaveSettings()
  end
end

function ToggleScript()
  local _, _, sectionID, cmdID = reaper.get_action_context()
  local state = reaper.GetToggleCommandState(cmdID)
  
  if state == -1 or state == 0 then
    reaper.SetToggleCommandState(sectionID, cmdID, 1)
    reaper.RefreshToolbar2(sectionID, cmdID)
    Start()
  else
    reaper.SetToggleCommandState(sectionID, cmdID, 0)
    reaper.RefreshToolbar2(sectionID, cmdID)
    Stop()
  end
end

function Start()
  LoadSettings()
  
  -- Apply global font styles if available
  if style_loader then
    style_loader.applyFontsToContext(ctx)
  end
  
  MainLoop()
end

function Stop()
  local selected_item = reaper.GetSelectedMediaItem(0, 0)
  if selected_item then
    SyncAutomationItems()
  end
  window_open = false
  SaveSettings()
  
  -- Clean up any remaining styles
  if style_loader then
    style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
  end
  
  reaper.UpdateArrange()
end

function Exit()
  local _, _, sectionID, cmdID = reaper.get_action_context()
  SaveSettings()
  
  reaper.SetToggleCommandState(sectionID, cmdID, 0)
  reaper.RefreshToolbar2(sectionID, cmdID)
  
  if reaper.GetToggleCommandState(42213) == 1 then
    reaper.Main_OnCommand(42213, 0)
  end
end

reaper.atexit(Exit)
ToggleScript()
