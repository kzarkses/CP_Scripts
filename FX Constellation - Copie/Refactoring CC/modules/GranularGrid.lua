-- FX Constellation - Granular Grid Module
-- Granular synthesis system for parameter control

local GranularGrid = {}

-- Note: This module will need the Utilities module for functions like:
-- - getParamKey
-- - isTrackValid
-- - scheduleSave

-- Initialize the granular grid with grains positioned evenly across the space
function GranularGrid.initializeGranularGrid(state, r, Utilities)
  local grid_size = state.granular_grid_size or 3
  state.granular_grains = {}
  for y = 0, grid_size - 1 do
    for x = 0, grid_size - 1 do
      local grain_x = (x + 0.5) / grid_size
      local grain_y = (y + 0.5) / grid_size
      table.insert(state.granular_grains, { x = grain_x, y = grain_y, fx_states = {}, param_values = {} })
    end
  end
  GranularGrid.randomizeGranularGrid(state, r, Utilities)
end

-- Randomize parameter values for all grains in the granular grid
function GranularGrid.randomizeGranularGrid(state, r, Utilities)
  if not Utilities.isTrackValid(state, r) then return end
  if not state.granular_grains then
    GranularGrid.initializeGranularGrid(state, r, Utilities)
    return
  end
  for _, grain in ipairs(state.granular_grains) do
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

-- Calculate the influence of a grain at a given position
-- Returns a value from 0 to 1 based on distance from grain center
function GranularGrid.getGrainInfluence(state, grain_x, grain_y, pos_x, pos_y)
  if not grain_x or not grain_y or not pos_x or not pos_y then
    return 0
  end
  local dx = pos_x - grain_x
  local dy = pos_y - grain_y
  local distance = math.sqrt(dx * dx + dy * dy)
  local grain_radius = 1.0 / state.granular_grid_size
  local influence = math.max(0, 1.0 - (distance / grain_radius))
  return influence
end

-- Apply granular gesture at the given grid position (gx, gy)
-- This interpolates parameter values based on proximity to each grain
function GranularGrid.applyGranularGesture(state, r, Utilities, gx, gy)
  if not Utilities.isTrackValid(state, r) then return end
  if not gx or not gy then return end
  if not state.granular_grains or #state.granular_grains == 0 then
    GranularGrid.initializeGranularGrid(state, r, Utilities)
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

  for _, grain in ipairs(state.granular_grains) do
    if grain and grain.x and grain.y then
      local influence = GranularGrid.getGrainInfluence(state, grain.x, grain.y, gx, gy)
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
          r.TrackFX_SetParam(state.track, actual_fx_id, param_id, final_value)
          param_data.current_value = final_value
          param_data.base_value = final_value
          local key = Utilities.getParamKey(fx_id, param_id)
          if key then
            state.param_base_values[key] = final_value
          end
        end
      end
    end
  end
end

-- Save the current granular grid configuration as a named set
function GranularGrid.saveGranularSet(state, r, Utilities, name)
  if name == "" or #state.granular_grains == 0 then return end
  state.granular_sets[name] = {
    grid_size = state.granular_grid_size,
    grains = {}
  }
  for i, grain in ipairs(state.granular_grains) do
    state.granular_sets[name].grains[i] = {
      x = grain.x,
      y = grain.y,
      param_values = {}
    }
    for fx_id, params in pairs(grain.param_values) do
      state.granular_sets[name].grains[i].param_values[fx_id] = {}
      for param_id, value in pairs(params) do
        state.granular_sets[name].grains[i].param_values[fx_id][param_id] = value
      end
    end
  end
  GranularGrid.scheduleGranularSave(state, r, Utilities)
end

-- Load a previously saved granular set by name
function GranularGrid.loadGranularSet(state, r, Utilities, name)
  local set_data = state.granular_sets[name]
  if not set_data then return end
  state.granular_grid_size = set_data.grid_size
  state.granular_grains = {}
  for i, grain_data in ipairs(set_data.grains) do
    state.granular_grains[i] = {
      x = grain_data.x,
      y = grain_data.y,
      param_values = {}
    }
    for fx_id, params in pairs(grain_data.param_values) do
      state.granular_grains[i].param_values[fx_id] = {}
      for param_id, value in pairs(params) do
        state.granular_grains[i].param_values[fx_id][param_id] = value
      end
    end
  end
end

-- Delete a saved granular set by name
function GranularGrid.deleteGranularSet(state, r, Utilities, name)
  if state.granular_sets[name] then
    state.granular_sets[name] = nil
    Utilities.scheduleSave(state, r, Utilities)
  end
end

-- Schedule the granular sets to be saved to disk
function GranularGrid.scheduleGranularSave(state, r, Utilities)
  state.save_flags.granular_sets = true
end

return GranularGrid
