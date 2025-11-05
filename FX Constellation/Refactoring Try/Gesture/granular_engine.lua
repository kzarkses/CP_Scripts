local GranularEngine = {}

local r = reaper
local granular_grains = {}
local granular_grid_size = 3
local granular_sets = {}
local data_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/Data/"
local granular_sets_file = data_path .. "granular_sets.dat"

function GranularEngine.Initialize(utils)
  utils.EnsureDataDirectory(data_path)
  GranularEngine.LoadGranularSetsFromFile(utils)
end

function GranularEngine.GetGridSize()
  return granular_grid_size
end

function GranularEngine.SetGridSize(size)
  granular_grid_size = size
end

function GranularEngine.GetGrains()
  return granular_grains
end

function GranularEngine.InitializeGrid(state)
  granular_grains = {}
  for y = 0, granular_grid_size - 1 do
    for x = 0, granular_grid_size - 1 do
      local grain_x = (x + 0.5) / granular_grid_size
      local grain_y = (y + 0.5) / granular_grid_size
      table.insert(granular_grains, { x = grain_x, y = grain_y, fx_states = {}, param_values = {} })
    end
  end
  GranularEngine.RandomizeGrid(state)
end

function GranularEngine.RandomizeGrid(state)
  local track = state.track
  if not track or not r.ValidatePtr(track, "MediaTrack*") then return end
  if not granular_grains then
    GranularEngine.InitializeGrid(state)
    return
  end
  
  for _, grain in ipairs(granular_grains) do
    if grain then
      grain.param_values = {}
      for fx_id, fx_data in pairs(state.fx_data) do
        grain.param_values[fx_id] = {}
        for param_id, param_data in pairs(fx_data.params) do
          if param_data.selected then
            local min_val = state.gesture_min or 0
            local max_val = state.gesture_max or 1
            local random_value = min_val + math.random() * (max_val - min_val)
            grain.param_values[fx_id][param_id] = random_value
          end
        end
      end
    end
  end
end

function GranularEngine.GetGrainInfluence(grain_x, grain_y, pos_x, pos_y)
  if not grain_x or not grain_y or not pos_x or not pos_y then
    return 0
  end
  local dx = pos_x - grain_x
  local dy = pos_y - grain_y
  local distance = math.sqrt(dx * dx + dy * dy)
  local grain_radius = 1.0 / granular_grid_size
  local influence = math.max(0, 1.0 - (distance / grain_radius))
  return influence
end

function GranularEngine.ApplyGesture(gx, gy, state)
  local track = state.track
  if not track or not r.ValidatePtr(track, "MediaTrack*") then return end
  if not gx or not gy then return end
  if not granular_grains or #granular_grains == 0 then
    GranularEngine.InitializeGrid(state)
    return
  end

  local total_weights = {}
  local weighted_param_values = {}
  for fx_id, fx_data in pairs(state.fx_data) do
    total_weights[fx_id] = 0
    weighted_param_values[fx_id] = {}
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        weighted_param_values[fx_id][param_id] = 0
      end
    end
  end

  for _, grain in ipairs(granular_grains) do
    if grain and grain.x and grain.y then
      local influence = GranularEngine.GetGrainInfluence(grain.x, grain.y, gx, gy)
      if influence > 0 then
        for fx_id, fx_data in pairs(state.fx_data) do
          total_weights[fx_id] = total_weights[fx_id] + influence
          if grain.param_values and grain.param_values[fx_id] then
            for param_id, value in pairs(grain.param_values[fx_id]) do
              if value and weighted_param_values[fx_id][param_id] then
                weighted_param_values[fx_id][param_id] = weighted_param_values[fx_id][param_id] +
                (value * influence)
              end
            end
          end
        end
      end
    end
  end

  for fx_id, fx_data in pairs(state.fx_data) do
    if total_weights[fx_id] and total_weights[fx_id] > 0 then
      for param_id, param_data in pairs(fx_data.params) do
        if param_data.selected and weighted_param_values[fx_id][param_id] then
          local final_value = weighted_param_values[fx_id][param_id] / total_weights[fx_id]
          local actual_fx_id = fx_data.actual_fx_id or fx_id
          r.TrackFX_SetParam(track, actual_fx_id, param_id, final_value)
          param_data.current_value = final_value
          param_data.base_value = final_value
        end
      end
    end
  end
end

function GranularEngine.SaveSet(name, current_preset, presets)
  if name == "" or #granular_grains == 0 then return false end
  
  if current_preset == "" then
    r.ShowMessageBox("Please load a preset first before saving granular sets.", "FX Constellation", 0)
    return false
  end
  
  if not presets[current_preset] then return false end
  
  if not presets[current_preset].granular_sets then
    presets[current_preset].granular_sets = {}
  end
  
  presets[current_preset].granular_sets[name] = {
    grid_size = granular_grid_size,
    grains = {}
  }
  
  for i, grain in ipairs(granular_grains) do
    presets[current_preset].granular_sets[name].grains[i] = {
      x = grain.x,
      y = grain.y,
      param_values = {}
    }
    for fx_id, params in pairs(grain.param_values) do
      presets[current_preset].granular_sets[name].grains[i].param_values[fx_id] = {}
      for param_id, value in pairs(params) do
        presets[current_preset].granular_sets[name].grains[i].param_values[fx_id][param_id] = value
      end
    end
  end
  
  return true
end

function GranularEngine.LoadSet(name, current_preset, presets)
  if current_preset == "" or not presets[current_preset] or not presets[current_preset].granular_sets then
    return false
  end
  
  local set_data = presets[current_preset].granular_sets[name]
  if not set_data then return false end
  
  granular_grid_size = set_data.grid_size
  granular_grains = {}
  
  for i, grain_data in ipairs(set_data.grains) do
    granular_grains[i] = {
      x = grain_data.x,
      y = grain_data.y,
      param_values = {}
    }
    for fx_id, params in pairs(grain_data.param_values) do
      granular_grains[i].param_values[fx_id] = {}
      for param_id, value in pairs(params) do
        granular_grains[i].param_values[fx_id][param_id] = value
      end
    end
  end
  
  return true
end

function GranularEngine.DeleteSet(name, current_preset, presets)
  if current_preset ~= "" and presets[current_preset] and presets[current_preset].granular_sets and presets[current_preset].granular_sets[name] then
    presets[current_preset].granular_sets[name] = nil
    if not next(presets[current_preset].granular_sets) then
      presets[current_preset].granular_sets = {}
    end
    return true
  end
  return false
end

function GranularEngine.SaveGranularSetsToFile(utils)
  if not next(granular_sets) then return end
  local file = io.open(granular_sets_file, "w")
  if file then
    file:write(utils.Serialize(granular_sets))
    file:close()
  end
end

function GranularEngine.LoadGranularSetsFromFile(utils)
  if r.file_exists(granular_sets_file) then
    local file = io.open(granular_sets_file, "r")
    if file then
      local content = file:read("*all")
      file:close()
      if content and content ~= "" then
        granular_sets = utils.Deserialize(content) or {}
      end
    end
  end
end

function GranularEngine.GetSaveData()
  return {
    grains = granular_grains,
    grid_size = granular_grid_size,
    sets = granular_sets
  }
end

function GranularEngine.LoadSaveData(data)
  if data then
    granular_grains = data.grains or {}
    granular_grid_size = data.grid_size or 3
    granular_sets = data.sets or {}
  end
end

return GranularEngine
