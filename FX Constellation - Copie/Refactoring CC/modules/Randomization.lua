-- FX Constellation - Randomization Module
-- FX scanning and parameter randomization system

local Randomization = {}

-- ============================================================================
-- FX Scanning Functions
-- ============================================================================

-- Scan track FX chain and build fx_data structure
function Randomization.scanTrackFX(state, r, Utilities, StateManagement)
  if not Utilities.isTrackValid(state, r) then return end
  state.fx_data = {}
  local fx_count = r.TrackFX_GetCount(state.track)
  local visible_fx_id = 0
  for fx = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx, "")
    if not fx_name:find("FX Constellation Bridge") then
      local param_count = r.TrackFX_GetNumParams(state.track, fx)
      state.fx_data[visible_fx_id] = {
        name = Utilities.extractFXName(fx_name),
        full_name = fx_name,
        enabled = r.TrackFX_GetEnabled(state.track, fx),
        actual_fx_id = fx,
        params = {}
      }
      local fx_key = Utilities.getFXKey(state, visible_fx_id)
      if fx_key and state.fx_random_max[fx_key] == nil then
        state.fx_random_max[fx_key] = 3
      end
      for param = 0, param_count - 1 do
        local _, param_name = r.TrackFX_GetParamName(state.track, fx, param, "")
        if not Utilities.shouldFilterParam(state, param_name) then
          local value = r.TrackFX_GetParam(state.track, fx, param)
          local step_count = Utilities.detectParamSteps(state, r, visible_fx_id, param)
          state.fx_data[visible_fx_id].params[param] = {
            name = param_name,
            current_value = value,
            base_value = value,
            min_val = 0,
            max_val = 1,
            selected = false,
            fx_id = visible_fx_id,
            param_id = param,
            actual_fx_id = fx,
            step_count = step_count
          }
        end
      end
      visible_fx_id = visible_fx_id + 1
    end
  end
  state.last_fx_count = fx_count
  state.last_fx_signature = Utilities.createFXSignature(state, r)

  -- Load track selection if StateManagement is available
  if StateManagement and StateManagement.loadTrackSelection then
    StateManagement.loadTrackSelection(state, r, Utilities, nil, Randomization.captureBaseValues, Utilities.updateSelectedCount)
  end

  Utilities.updateSelectedCount(state)
end

-- ============================================================================
-- Selection Helper Functions
-- ============================================================================

-- Select all parameters
function Randomization.selectAllParams(state, params, selected, StateManagement, scheduleSaveFn)
  for _, param in pairs(params) do
    param.selected = selected
  end
  Utilities.updateSelectedCount(state)
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- Select all continuous parameters
function Randomization.selectAllContinuousParams(state, params, selected, StateManagement, scheduleSaveFn)
  for _, param in pairs(params) do
    if not param.step_count or param.step_count == 0 then
      param.selected = selected
    end
  end
  Utilities.updateSelectedCount(state)
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- ============================================================================
-- Base Value Management
-- ============================================================================

-- Capture base values for all selected parameters
function Randomization.captureBaseValues(state, Utilities)
  state.param_base_values = {}
  state.gesture_base_x = state.gesture_x
  state.gesture_base_y = state.gesture_y
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        param_data.base_value = param_data.current_value
        local key = Utilities.getParamKey(state, fx_id, param_id)
        if key then
          state.param_base_values[key] = param_data.current_value
        end
      end
    end
  end
end

-- ============================================================================
-- Random Parameter Selection
-- ============================================================================

-- Randomly select parameters from an FX
function Randomization.randomSelectParams(state, r, Utilities, params, fx_id, scheduleSaveFn)
  Randomization.selectAllParams(state, params, false, nil, nil)
  local param_list = {}
  for id, param in pairs(params) do
    table.insert(param_list, param)
  end
  if #param_list == 0 then return end
  local fx_key = Utilities.getFXKey(state, fx_id)
  local max_count = (fx_key and state.fx_random_max[fx_key]) or 3
  local count = math.random(1, math.min(max_count, #param_list))
  for i = 1, count do
    local idx = math.random(1, #param_list)
    param_list[idx].selected = true
    table.remove(param_list, idx)
  end
  Utilities.updateSelectedCount(state)
  Randomization.captureBaseValues(state, Utilities)
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- Randomly select parameters globally across all FX
function Randomization.globalRandomSelect(state, Utilities, scheduleSaveFn)
  for fx_id, fx_data in pairs(state.fx_data) do
    Randomization.selectAllParams(state, fx_data.params, false, nil, nil)
  end
  local all_params = {}
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      table.insert(all_params, param_data)
    end
  end
  if #all_params == 0 then return end
  local count = math.random(state.random_min, math.min(state.random_max, #all_params))
  for i = 1, count do
    local idx = math.random(1, #all_params)
    all_params[idx].selected = true
    table.remove(all_params, idx)
  end
  Utilities.updateSelectedCount(state)
  Randomization.captureBaseValues(state, Utilities)
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- ============================================================================
-- Base Value Randomization
-- ============================================================================

-- Randomize base values for selected parameters in a specific FX
function Randomization.randomizeBaseValues(state, r, Utilities, params, fx_id, scheduleSaveFn)
  if not Utilities.isTrackValid(state, r) then return end
  local actual_fx_id = state.fx_data[fx_id] and state.fx_data[fx_id].actual_fx_id or fx_id
  for param_id, param_data in pairs(params) do
    if param_data.selected then
      local new_base = math.random()
      param_data.base_value = new_base
      local key = Utilities.getParamKey(state, fx_id, param_id)
      if key then
        state.param_base_values[key] = new_base
      end
      r.TrackFX_SetParam(state.track, actual_fx_id, param_id, new_base)
      param_data.current_value = new_base
    end
  end
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- Randomize all base values globally
function Randomization.randomizeAllBases(state, r, Utilities, scheduleSaveFn)
  if not Utilities.isTrackValid(state, r) then return end
  r.Undo_BeginBlock()
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local center_val = (state.randomize_min + state.randomize_max) / 2
        local range_val = (state.randomize_max - state.randomize_min) / 2
        local rand_offset = (math.random() * 2 - 1) * range_val * state.randomize_intensity
        local new_base = center_val + rand_offset
        new_base = math.max(state.randomize_min, math.min(state.randomize_max, new_base))
        param_data.base_value = new_base
        local key = Utilities.getParamKey(state, fx_id, param_id)
        if key then
          state.param_base_values[key] = new_base
        end
        r.TrackFX_SetParam(state.track, fx_id, param_id, new_base)
        param_data.current_value = new_base
      end
    end
  end
  r.Undo_EndBlock("Randomize all bases", -1)
  Randomization.captureBaseValues(state, Utilities)
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- ============================================================================
-- XY Assignment Randomization
-- ============================================================================

-- Randomize X/Y axis assignments for selected parameters in a specific FX
function Randomization.randomizeXYAssign(state, Utilities, params, fx_id, scheduleSaveFn)
  for param_id, param_data in pairs(params) do
    if param_data.selected then
      local rand = math.random()
      if state.exclusive_xy then
        Utilities.setParamXYAssign(state, fx_id, param_id, "x", rand < 0.5, nil)
        Utilities.setParamXYAssign(state, fx_id, param_id, "y", rand >= 0.5, nil)
      else
        if rand < 0.33 then
          Utilities.setParamXYAssign(state, fx_id, param_id, "x", true, nil)
          Utilities.setParamXYAssign(state, fx_id, param_id, "y", false, nil)
        elseif rand < 0.66 then
          Utilities.setParamXYAssign(state, fx_id, param_id, "x", false, nil)
          Utilities.setParamXYAssign(state, fx_id, param_id, "y", true, nil)
        else
          Utilities.setParamXYAssign(state, fx_id, param_id, "x", true, nil)
          Utilities.setParamXYAssign(state, fx_id, param_id, "y", true, nil)
        end
      end
    end
  end
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- Randomize X/Y axis assignments globally
function Randomization.globalRandomXYAssign(state, Utilities, scheduleSaveFn)
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local rand = math.random()
        if state.exclusive_xy then
          Utilities.setParamXYAssign(state, fx_id, param_id, "x", rand < 0.5, nil)
          Utilities.setParamXYAssign(state, fx_id, param_id, "y", rand >= 0.5, nil)
        else
          if rand < 0.33 then
            Utilities.setParamXYAssign(state, fx_id, param_id, "x", true, nil)
            Utilities.setParamXYAssign(state, fx_id, param_id, "y", false, nil)
          elseif rand < 0.66 then
            Utilities.setParamXYAssign(state, fx_id, param_id, "x", false, nil)
            Utilities.setParamXYAssign(state, fx_id, param_id, "y", true, nil)
          else
            Utilities.setParamXYAssign(state, fx_id, param_id, "x", true, nil)
            Utilities.setParamXYAssign(state, fx_id, param_id, "y", true, nil)
          end
        end
      end
    end
  end
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- ============================================================================
-- Invert Randomization
-- ============================================================================

-- Randomize invert status globally
function Randomization.globalRandomInvert(state, Utilities, scheduleSaveFn)
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        Utilities.setParamInvert(state, fx_id, param_id, math.random() < 0.5, nil)
      end
    end
  end
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- ============================================================================
-- Range Randomization
-- ============================================================================

-- Randomize parameter ranges for selected parameters in a specific FX
function Randomization.randomizeRanges(state, Utilities, params, fx_id, scheduleSaveFn)
  for param_id, param_data in pairs(params) do
    if param_data.selected then
      local new_range = state.range_min + math.random() * (state.range_max - state.range_min)
      Utilities.setParamRange(state, fx_id, param_id, new_range, nil)
    end
  end
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- Randomize parameter ranges globally
function Randomization.globalRandomRanges(state, Utilities, scheduleSaveFn)
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local new_range = state.range_min + math.random() * (state.range_max - state.range_min)
        Utilities.setParamRange(state, fx_id, param_id, new_range, nil)
      end
    end
  end
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- ============================================================================
-- FX Chain Randomization
-- ============================================================================

-- Randomize FX chain order
function Randomization.randomizeFXOrder(state, r, Utilities, scheduleSaveFn, initializeGranularGridFn)
  if not Utilities.isTrackValid(state, r) then return end
  local fx_count = r.TrackFX_GetCount(state.track)
  if fx_count < 2 then return end

  if scheduleSaveFn then
    scheduleSaveFn()
  end

  r.Undo_BeginBlock()

  local jsfx_index = Utilities.findAutomationJSFX(state, r)
  local jsfx_name = ""
  if jsfx_index >= 0 then
    _, jsfx_name = r.TrackFX_GetFXName(state.track, jsfx_index, "")
  end

  for i = fx_count - 1, 1, -1 do
    local _, fx_name_i = r.TrackFX_GetFXName(state.track, i, "")
    if not fx_name_i:find("FX Constellation Bridge") then
      local j = math.random(0, i - 1)
      local _, fx_name_j = r.TrackFX_GetFXName(state.track, j, "")
      if not fx_name_j:find("FX Constellation Bridge") and i ~= j then
        local temp_pos = fx_count
        r.TrackFX_CopyToTrack(state.track, i, state.track, temp_pos, true)
        r.TrackFX_CopyToTrack(state.track, j, state.track, i, true)
        r.TrackFX_CopyToTrack(state.track, temp_pos, state.track, j, true)
      end
    end
  end
  r.Undo_EndBlock("Randomize FX order", -1)

  if state.granular_grains and #state.granular_grains > 0 then
    if initializeGranularGridFn then
      initializeGranularGridFn()
    end
  end

  Randomization.scanTrackFX(state, r, Utilities, nil)
  state.jsfx_automation_index = Utilities.findAutomationJSFX(state, r)
  state.jsfx_automation_enabled = state.jsfx_automation_index >= 0
end

-- Randomly bypass FX
function Randomization.randomBypassFX(state, r, Utilities, scanTrackFXFn)
  if not Utilities.isTrackValid(state, r) then return end
  local fx_count = r.TrackFX_GetCount(state.track)
  if fx_count == 0 then return end
  r.Undo_BeginBlock()
  for fx_id = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx_id, "")
    if not fx_name:find("FX Constellation Bridge") then
      local should_bypass = math.random() < state.random_bypass_percentage
      r.TrackFX_SetEnabled(state.track, fx_id, not should_bypass)
    end
  end
  r.Undo_EndBlock("Random bypass FX", -1)
  if scanTrackFXFn then
    scanTrackFXFn()
  else
    Randomization.scanTrackFX(state, r, Utilities, nil)
  end
end

-- ============================================================================
-- Parameter Value Randomization
-- ============================================================================

-- Randomize selected parameter values based on their base values and ranges
function Randomization.randomizeSelection(state, r, Utilities, scheduleSaveFn)
  if not Utilities.isTrackValid(state, r) then return end
  state.last_random_seed = os.time() + math.random(1000)
  math.randomseed(state.last_random_seed)
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local param_range = Utilities.getParamRange(state, fx_id, param_id)
        local up_range, down_range = Utilities.calculateAsymmetricRange(param_data.base_value, param_range,
          state.randomize_intensity, state.randomize_min, state.randomize_max)
        local rand = math.random() * 2 - 1
        local variation = rand > 0 and rand * up_range or rand * down_range
        local new_value = param_data.base_value + variation
        new_value = math.max(state.randomize_min, math.min(state.randomize_max, new_value))
        r.TrackFX_SetParam(state.track, fx_id, param_id, new_value)
        param_data.current_value = new_value
        param_data.base_value = new_value
      end
    end
  end
  Randomization.captureBaseValues(state, Utilities)
  if scheduleSaveFn then
    scheduleSaveFn()
  end
end

-- ============================================================================
-- Granular Grid Functions
-- ============================================================================

-- Initialize granular grid
function Randomization.initializeGranularGrid(state, Utilities)
  local grid_size = state.granular_grid_size or 3
  state.granular_grains = {}
  for y = 0, grid_size - 1 do
    for x = 0, grid_size - 1 do
      local grain_x = (x + 0.5) / grid_size
      local grain_y = (y + 0.5) / grid_size
      table.insert(state.granular_grains, { x = grain_x, y = grain_y, fx_states = {}, param_values = {} })
    end
  end
  Randomization.randomizeGranularGrid(state, r, Utilities)
end

-- Randomize granular grid parameter values
function Randomization.randomizeGranularGrid(state, r, Utilities)
  if not Utilities.isTrackValid(state, r) then return end
  if not state.granular_grains then
    Randomization.initializeGranularGrid(state, Utilities)
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

return Randomization
