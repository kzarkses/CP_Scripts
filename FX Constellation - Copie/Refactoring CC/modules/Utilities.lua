-- FX Constellation - Utilities Module
-- Helper functions and validation utilities

local Utilities = {}

-- ============================================================================
-- Key Generation Functions
-- ============================================================================

-- Generate a unique key for a parameter
function Utilities.getParamKey(state, fx_id, param_id, suffix)
  local guid = Utilities.getTrackGUID(state)
  if not guid or not state.fx_data[fx_id] or not state.fx_data[fx_id].params[param_id] then
    return nil
  end
  local fx_name = state.fx_data[fx_id].full_name
  local param_name = state.fx_data[fx_id].params[param_id].name
  local key = guid .. "_" .. fx_name .. "||" .. param_name
  if suffix then
    key = key .. "_" .. suffix
  end
  return key
end

-- Generate a unique key for an FX
function Utilities.getFXKey(state, fx_id, suffix)
  local guid = Utilities.getTrackGUID(state)
  if not guid or not state.fx_data[fx_id] then return nil end
  local fx_name = state.fx_data[fx_id].full_name
  local key = guid .. "_" .. fx_name
  if suffix then
    key = key .. "_" .. suffix
  end
  return key
end

-- ============================================================================
-- Validation Functions
-- ============================================================================

-- Check if track is valid
function Utilities.isTrackValid(state, r)
  if not state.track then return false end
  return r.ValidatePtr(state.track, "MediaTrack*")
end

-- Get track GUID
function Utilities.getTrackGUID(state, r)
  if not Utilities.isTrackValid(state, r) then return nil end
  local _, guid = r.GetSetMediaTrackInfo_String(state.track, "GUID", "", false)
  return guid
end

-- ============================================================================
-- FX Chain Functions
-- ============================================================================

-- Create FX chain signature
function Utilities.createFXSignature(state, r)
  if not Utilities.isTrackValid(state, r) then return "" end
  local sig = ""
  local fx_count = r.TrackFX_GetCount(state.track)
  for fx = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx, "")
    sig = sig .. fx_name .. ":" .. r.TrackFX_GetNumParams(state.track, fx) .. ";"
  end
  return sig
end

-- Get current FX chain signature
function Utilities.getCurrentFXChainSignature(state, r)
  local guid = Utilities.getTrackGUID(state, r)
  if not guid then return nil end
  return guid .. "_" .. Utilities.createFXSignature(state, r)
end

-- Find automation JSFX
function Utilities.findAutomationJSFX(state, r)
  if not Utilities.isTrackValid(state, r) then return -1 end
  local fx_count = r.TrackFX_GetCount(state.track)
  for fx_id = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx_id, "")
    if fx_name:find("FX Constellation Bridge") then
      return fx_id
    end
  end
  return -1
end

-- ============================================================================
-- Parameter Range Functions
-- ============================================================================

-- Get parameter range
function Utilities.getParamRange(state, fx_id, param_id)
  local key = Utilities.getParamKey(state, fx_id, param_id, "range")
  if not key then return 1.0 end
  return state.param_ranges[key] or 1.0
end

-- Set parameter range
function Utilities.setParamRange(state, fx_id, param_id, range, saveTrackSelection)
  local key = Utilities.getParamKey(state, fx_id, param_id, "range")
  if not key then return end
  state.param_ranges[key] = range
  if saveTrackSelection then
    saveTrackSelection()
  end
end

-- Get parameter invert status
function Utilities.getParamInvert(state, fx_id, param_id)
  local key = Utilities.getParamKey(state, fx_id, param_id, "invert")
  if not key then return false end
  return state.param_invert[key] or false
end

-- Set parameter invert status
function Utilities.setParamInvert(state, fx_id, param_id, invert, saveTrackSelection)
  local key = Utilities.getParamKey(state, fx_id, param_id, "invert")
  if not key then return end
  state.param_invert[key] = invert
  if saveTrackSelection then
    saveTrackSelection()
  end
end

-- Get parameter XY assignment
function Utilities.getParamXYAssign(state, fx_id, param_id)
  local x_key = Utilities.getParamKey(state, fx_id, param_id, "x")
  local y_key = Utilities.getParamKey(state, fx_id, param_id, "y")
  if not x_key or not y_key then return true, true end
  return state.param_xy_assign[x_key] ~= false, state.param_xy_assign[y_key] ~= false
end

-- Set parameter XY assignment
function Utilities.setParamXYAssign(state, fx_id, param_id, axis, value, saveTrackSelection)
  local key = Utilities.getParamKey(state, fx_id, param_id, axis)
  if not key then return end
  state.param_xy_assign[key] = value
  if state.exclusive_xy and value then
    local other_axis = axis == "x" and "y" or "x"
    local other_key = Utilities.getParamKey(state, fx_id, param_id, other_axis)
    if other_key then
      state.param_xy_assign[other_key] = false
    end
  end
  if saveTrackSelection then
    saveTrackSelection()
  end
end

-- ============================================================================
-- Data Serialization Functions
-- ============================================================================

-- Serialize table to string
function Utilities.serialize(t)
  local function ser(v)
    local t = type(v)
    if t == "string" then
      return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
      return tostring(v)
    elseif t == "table" then
      local s = "{"
      local first = true
      for k, val in pairs(v) do
        if not first then s = s .. "," end
        first = false
        if type(k) == "string" then
          s = s .. "[" .. ser(k) .. "]=" .. ser(val)
        else
          s = s .. ser(val)
        end
      end
      return s .. "}"
    else
      return "nil"
    end
  end
  return ser(t)
end

-- Deserialize string to table
function Utilities.deserialize(s)
  if s == "" then return {} end
  local f, err = load("return " .. s)
  if f then
    local ok, res = pcall(f)
    if ok then return res end
  end
  return {}
end

-- ============================================================================
-- Parameter Filtering Functions
-- ============================================================================

-- Check if parameter should be filtered
function Utilities.shouldFilterParam(state, param_name)
  local lower_name = param_name:lower()
  for _, keyword in ipairs(state.filter_keywords) do
    if lower_name:find(keyword:lower(), 1, true) then
      return true
    end
  end
  if state.param_filter ~= "" then
    return not lower_name:find(state.param_filter:lower(), 1, true)
  end
  return false
end

-- Extract and format FX name
function Utilities.extractFXName(full_name)
  local clean_name = full_name:match("^[^:]*:%s*(.+)") or full_name
  clean_name = clean_name:gsub("%(.-%)", "")
  clean_name = clean_name:match("^%s*(.-)%s*$")
  if clean_name:len() > 25 then
    clean_name = clean_name:sub(1, 22) .. "..."
  end
  return clean_name
end

-- ============================================================================
-- FX Change Detection
-- ============================================================================

-- Check for FX chain changes
function Utilities.checkForFXChanges(state, r, scanTrackFX)
  if not Utilities.isTrackValid(state, r) then return false end
  local current_time = r.time_precise()
  if current_time - state.last_update_time < state.update_interval then
    return false
  end
  state.last_update_time = current_time
  local current_fx_count = r.TrackFX_GetCount(state.track)
  local current_signature = Utilities.createFXSignature(state, r)
  local changes_detected = false
  if current_fx_count ~= state.last_fx_count or current_signature ~= state.last_fx_signature then
    if scanTrackFX then
      scanTrackFX()
    end
    changes_detected = true
  else
    for fx_id, fx_data in pairs(state.fx_data) do
      local actual_fx_id = fx_data.actual_fx_id or fx_id
      local current_enabled = r.TrackFX_GetEnabled(state.track, actual_fx_id)
      if fx_data.enabled ~= current_enabled then
        fx_data.enabled = current_enabled
        changes_detected = true
      end
      for param_id, param_data in pairs(fx_data.params) do
        local actual_fx_param_id = param_data.actual_fx_id or actual_fx_id
        local current_value = r.TrackFX_GetParam(state.track, actual_fx_param_id, param_id)
        if math.abs(param_data.current_value - current_value) > 0.001 then
          param_data.current_value = current_value
          if not param_data.selected then
            param_data.base_value = current_value
          end
        end
      end
    end
  end
  return changes_detected
end

-- ============================================================================
-- Selection Management
-- ============================================================================

-- Update selected parameter count
function Utilities.updateSelectedCount(state)
  state.selected_count = 0
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        state.selected_count = state.selected_count + 1
      end
    end
  end
end

-- ============================================================================
-- Save Management
-- ============================================================================

-- Check if save is needed
function Utilities.checkSave(state, r, save_flags, saveSettings)
  if r.time_precise() > state.save_timer then
    if save_flags.settings or save_flags.track_selections or save_flags.presets or save_flags.granular_sets or save_flags.snapshots then
      if saveSettings then
        saveSettings()
      end
      save_flags.settings = false
      save_flags.track_selections = false
      save_flags.presets = false
      save_flags.granular_sets = false
      save_flags.snapshots = false
      state.save_cooldown = r.time_precise()
    end
  end
end

-- ============================================================================
-- Mathematical Utility Functions
-- ============================================================================

-- Get grain influence for granular synthesis
function Utilities.getGrainInfluence(grain_x, grain_y, pos_x, pos_y, granular_grid_size)
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

-- Calculate asymmetric range
function Utilities.calculateAsymmetricRange(base, range, intensity, min_limit, max_limit)
  local max_range = range * intensity * 0.5
  local up_space = max_limit - base
  local down_space = base - min_limit
  local up_range = math.min(max_range, up_space)
  local down_range = math.min(max_range, down_space)
  if up_range < max_range then
    local excess = max_range - up_range
    down_range = math.min(down_range + excess, down_space)
  elseif down_range < max_range then
    local excess = max_range - down_range
    up_range = math.min(up_range + excess, up_space)
  end
  return up_range, down_range
end

-- Snap value to discrete steps
function Utilities.snapToDiscreteValue(value, step_count)
  if step_count <= 1 then return value end
  local step = 1.0 / (step_count - 1)
  local closest_step = math.floor((value / step) + 0.5)
  return closest_step * step
end

-- Detect parameter steps (discrete vs continuous)
function Utilities.detectParamSteps(state, r, fx_id, param_id)
  if not Utilities.isTrackValid(state, r) then return 0 end
  local actual_fx_id = state.fx_data[fx_id].actual_fx_id or fx_id
  local original_value = r.TrackFX_GetParam(state.track, actual_fx_id, param_id)
  local samples = {}
  for i = 0, 20 do
    local test_val = i / 20
    r.TrackFX_SetParam(state.track, actual_fx_id, param_id, test_val)
    local result = r.TrackFX_GetParam(state.track, actual_fx_id, param_id)
    local found = false
    for _, s in ipairs(samples) do
      if math.abs(s - result) < 0.001 then
        found = true
        break
      end
    end
    if not found then
      table.insert(samples, result)
    end
  end
  r.TrackFX_SetParam(state.track, actual_fx_id, param_id, original_value)
  table.sort(samples)
  if #samples <= 10 then
    return #samples
  end
  return 0
end

-- Bezier curve calculation
function Utilities.bezierCurve(t, p0, p1, p2, p3)
  local u = 1 - t
  local tt = t * t
  local uu = u * u
  local uuu = uu * u
  local ttt = tt * t

  local x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x
  local y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y

  return x, y
end

-- Calculate figures position for pattern movement
function Utilities.calculateFiguresPosition(state, time)
  local angle = time * state.figures_speed * 2 * math.pi
  local size = state.figures_size

  if state.figures_mode == 0 then
    -- Circle
    local x = 0.5 + (size * 0.5) * math.cos(angle)
    local y = 0.5 + (size * 0.5) * math.sin(angle)
    return x, y
  elseif state.figures_mode == 1 then
    -- Square
    local progress = (angle / (2 * math.pi)) % 1
    local half_size = size * 0.5
    local x, y
    if progress < 0.25 then
      local t = progress * 4
      x = 0.5 - half_size + t * size
      y = 0.5 - half_size
    elseif progress < 0.5 then
      local t = (progress - 0.25) * 4
      x = 0.5 + half_size
      y = 0.5 - half_size + t * size
    elseif progress < 0.75 then
      local t = (progress - 0.5) * 4
      x = 0.5 + half_size - t * size
      y = 0.5 + half_size
    else
      local t = (progress - 0.75) * 4
      x = 0.5 - half_size
      y = 0.5 + half_size - t * size
    end
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  elseif state.figures_mode == 2 then
    -- Triangle
    local progress = (angle / (2 * math.pi)) % 1
    local half_size = size * 0.5
    local x, y
    if progress < 0.33 then
      local t = progress * 3
      x = 0.5
      y = 0.5 - half_size + t * half_size
    elseif progress < 0.66 then
      local t = (progress - 0.33) * 3
      x = 0.5 - t * size
      y = 0.5 + half_size
    else
      local t = (progress - 0.66) * 3
      x = 0.5 - size + t * size
      y = 0.5 + half_size - t * size
    end
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  elseif state.figures_mode == 3 then
    -- Diamond
    local progress = (angle / (2 * math.pi)) % 1
    local half_size = size * 0.5
    local x, y
    if progress < 0.25 then
      local t = progress * 4
      x = 0.5 + t * half_size
      y = 0.5 - half_size + t * half_size
    elseif progress < 0.5 then
      local t = (progress - 0.25) * 4
      x = 0.5 + half_size - t * half_size
      y = 0.5 + t * half_size
    elseif progress < 0.75 then
      local t = (progress - 0.5) * 4
      x = 0.5 - t * half_size
      y = 0.5 + half_size - t * half_size
    else
      local t = (progress - 0.75) * 4
      x = 0.5 - half_size + t * half_size
      y = 0.5 - t * half_size
    end
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  elseif state.figures_mode == 4 then
    -- Z pattern
    local progress = (angle / (2 * math.pi)) % 1
    local half_size = size * 0.5
    local x, y
    if progress < 0.33 then
      local t = progress * 3
      x = 0.5 - half_size + t * size
      y = 0.5 - half_size
    elseif progress < 0.66 then
      local t = (progress - 0.33) * 3
      x = 0.5 + half_size - t * size
      y = 0.5 - half_size + t * size
    else
      local t = (progress - 0.66) * 3
      x = 0.5 - half_size + t * size
      y = 0.5 + half_size
    end
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  elseif state.figures_mode == 5 then
    -- Infinity (figure-8)
    local x = 0.5 + (size * 0.5) * math.sin(angle)
    local y = 0.5 + (size * 0.5) * math.sin(angle) * math.cos(angle)
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  end

  return 0.5, 0.5
end

-- ============================================================================
-- Style Functions (for external style loader integration)
-- ============================================================================

-- Get style value (requires style_loader to be passed in)
function Utilities.GetStyleValue(style_loader, path, default_value)
  if style_loader then
    return style_loader.GetValue(path, default_value)
  end
  return default_value
end

-- Get style font (requires style_loader and context to be passed in)
function Utilities.getStyleFont(style_loader, ctx, font_name, context)
  if style_loader then
    return style_loader.getFont(context or ctx, font_name)
  end
  return nil
end

return Utilities
