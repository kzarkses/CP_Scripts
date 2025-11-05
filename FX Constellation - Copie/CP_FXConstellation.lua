-- @description FXConstellation
-- @version 1.1
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_FXConstellation"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('FX Constellation')
local filters_ctx = nil
local presets_ctx = nil

local pushed_colors = 0
local filters_pushed_colors = 0
local presets_pushed_colors = 0

local pushed_vars = 0
local filters_pushed_vars = 0
local presets_pushed_vars = 0

if style_loader then
  style_loader.ApplyFontsToContext(ctx)
end

function GetStyleValue(path, default_value)
  if style_loader then
    return style_loader.GetValue(path, default_value)
  end
  return default_value
end

function getStyleFont(font_name, context)
  if style_loader then
    return style_loader.getFont(context or ctx, font_name)
  end
  return nil
end

local header_font_size = GetStyleValue("fonts.header.size", 16)
local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
local window_padding_x = GetStyleValue("spacing.window_padding_x", 6)
local window_padding_y = GetStyleValue("spacing.window_padding_y", 6)

local save_flags = {
  settings = false,
  track_selections = false,
  presets = false,
  granular_sets = false,
  snapshots = false
}

local state = {
  track = nil,
  fx_data = {},
  presets = {},
  track_selections = {},
  gesture_x = 0.5,
  gesture_y = 0.5,
  gesture_base_x = 0.5,
  gesture_base_y = 0.5,
  param_base_values = {},
  x_curve = 1.0,
  y_curve = 1.0,
  pad_mode = 0,
  navigation_mode = 0,
  randomize_intensity = 0.3,
  randomize_min = 0.0,
  randomize_max = 1.0,
  gesture_min = 0.0,
  gesture_max = 1.0,
  preset_name = "Preset1",
  selected_count = 0,
  last_fx_count = 0,
  last_fx_signature = "",
  random_min = 3,
  random_max = 8,
  fx_random_max = {},
  filter_keywords = {},
  param_filter = "",
  new_filter_word = "",
  show_filters = false,
  param_ranges = {},
  param_xy_assign = {},
  param_invert = {},
  gesture_active = false,
  gesture_range = 1.0,
  exclusive_xy = false,
  last_random_seed = os.time(),
  needs_save = false,
  save_timer = 0,
  scroll_offset = 0,
  selected_preset = "",
  preset_scroll = 0,
  show_preset_rename = false,
  rename_preset_name = "",
  fx_panel_scroll_x = 0,
  fx_panel_scroll_y = 0,
  last_update_time = 0,
  update_interval = 0.05,
  dirty_params = false,
  save_cooldown = 0,
  min_save_interval = 1.0,
  target_gesture_x = 0.5,
  target_gesture_y = 0.5,
  smooth_speed = 0,
  max_gesture_speed = 2.0,
  random_walk_active = false,
  random_walk_speed = 2.0,
  random_walk_smooth = true,
  random_walk_jitter = 0.2,
  random_walk_next_time = 0,
  random_walk_last_time = 0,
  random_walk_control_points = {},
  random_walk_bezier_progress = 0,
  param_cache = {},
  cache_dirty = true,
  param_update_interval = 0.02,
  granular_grid_size = 3,
  granular_grains = {},
  granular_sets = {},
  granular_set_name = "GrainSet1",
  snapshots = {},
  snapshot_name = "Snapshot1",
  show_snapshots = false,
  random_bypass_percentage = 0.3,
  layout_mode = 0,
  fx_collapsed = {},
  show_filters_window = false,
  show_presets_window = false,
  save_fx_chain = false,
  jsfx_automation_enabled = false,
  jsfx_automation_index = -1,
  all_fx_collapsed = false,
  range_min = 0.0,
  range_max = 1.0,
  figures_mode = 0,
  figures_speed = 1.0,
  figures_size = 0.5,
  figures_time = 0,
  figures_active = false,
  click_offset_x = 0,
  click_offset_y = 0,
  track_locked = false,
  locked_track = nil,
  current_loaded_preset = ""
}

local navigation_modes = { "Manual", "Random Walk", "Figures" }
local figures_modes = { "Circle", "Square", "Triangle", "Diamond", "Z", "Infinity" }

function getParamKey(fx_id, param_id, suffix)
  local guid = getTrackGUID()
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

function getFXKey(fx_id, suffix)
  local guid = getTrackGUID()
  if not guid or not state.fx_data[fx_id] then return nil end
  local fx_name = state.fx_data[fx_id].full_name
  local key = guid .. "_" .. fx_name
  if suffix then
    key = key .. "_" .. suffix
  end
  return key
end

function isTrackValid()
  if not state.track then return false end
  return r.ValidatePtr(state.track, "MediaTrack*")
end

function initializeGranularGrid()
  local grid_size = state.granular_grid_size or 3
  state.granular_grains = {}
  for y = 0, grid_size - 1 do
    for x = 0, grid_size - 1 do
      local grain_x = (x + 0.5) / grid_size
      local grain_y = (y + 0.5) / grid_size
      table.insert(state.granular_grains, { x = grain_x, y = grain_y, fx_states = {}, param_values = {} })
    end
  end
  randomizeGranularGrid()
end

function randomizeGranularGrid()
  if not isTrackValid() then return end
  if not state.granular_grains then
    initializeGranularGrid()
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

function getGrainInfluence(grain_x, grain_y, pos_x, pos_y)
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

function applyGranularGesture(gx, gy)
  if not isTrackValid() then return end
  if not gx or not gy then return end
  if not state.granular_grains or #state.granular_grains == 0 then
    initializeGranularGrid()
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
      local influence = getGrainInfluence(grain.x, grain.y, gx, gy)
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
          local key = getParamKey(fx_id, param_id)
          if key then
            state.param_base_values[key] = final_value
          end
        end
      end
    end
  end
end

function saveGranularSet(name)
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
  scheduleGranularSave()
end

function loadGranularSet(name)
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

function deleteGranularSet(name)
  if state.granular_sets[name] then
    state.granular_sets[name] = nil
    scheduleSave()
  end
end

function saveSnapshot(name)
  if name == "" or not isTrackValid() then return end
  
  local fx_sig = getCurrentFXChainSignature()
  if not fx_sig then return end
  
  if not state.snapshots[fx_sig] then
    state.snapshots[fx_sig] = {}
  end
  
  local snapshot = {
    gesture_x = state.gesture_x,
    gesture_y = state.gesture_y,
    gesture_base_x = state.gesture_base_x,
    gesture_base_y = state.gesture_base_y,
    fx_list = {},
    param_data = {}
  }
  
  for fx_id, fx_data in pairs(state.fx_data) do
    table.insert(snapshot.fx_list, fx_data.full_name)
    
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local key = fx_data.full_name .. "||" .. param_data.name
        local x_assign, y_assign = getParamXYAssign(fx_id, param_id)
        snapshot.param_data[key] = {
          base_value = param_data.base_value,
          range = getParamRange(fx_id, param_id),
          x_assign = x_assign,
          y_assign = y_assign,
          invert = getParamInvert(fx_id, param_id),
          selected = true
        }
      end
    end
  end
  
  state.snapshots[fx_sig][name] = snapshot
  scheduleSnapshotSave()
end

function loadSnapshot(name)
  if not isTrackValid() then return end
  
  local fx_sig = getCurrentFXChainSignature()
  if not fx_sig or not state.snapshots[fx_sig] or not state.snapshots[fx_sig][name] then return end
  
  local snapshot = state.snapshots[fx_sig][name]
  local current_fx_list = {}
  
  for fx_id, fx_data in pairs(state.fx_data) do
    table.insert(current_fx_list, fx_data.full_name)
  end
  
  local fx_match = true
  if #current_fx_list ~= #snapshot.fx_list then
    fx_match = false
  else
    for i, fx_name in ipairs(snapshot.fx_list) do
      if current_fx_list[i] ~= fx_name then
        fx_match = false
        break
      end
    end
  end
  
  if not fx_match then
    local msg = "FX Constellation - Snapshot Warning:\n\n"
    msg = msg .. "The current FX chain does not match the saved snapshot.\n\n"
    msg = msg .. "Expected FX:\n"
    for i, fx_name in ipairs(snapshot.fx_list) do
      msg = msg .. "  " .. i .. ". " .. fx_name .. "\n"
    end
    msg = msg .. "\nCurrent FX:\n"
    for i, fx_name in ipairs(current_fx_list) do
      msg = msg .. "  " .. i .. ". " .. fx_name .. "\n"
    end
    msg = msg .. "\nDo you want to load the snapshot anyway?\n"
    msg = msg .. "(Parameters will be matched by FX and parameter names)"
    
    local result = r.ShowMessageBox(msg, "FX Constellation - Snapshot Mismatch", 4)
    if result == 7 then
      return
    end
  end
  
  r.Undo_BeginBlock()
  
  state.gesture_x = snapshot.gesture_x or 0.5
  state.gesture_y = snapshot.gesture_y or 0.5
  state.gesture_base_x = snapshot.gesture_base_x or 0.5
  state.gesture_base_y = snapshot.gesture_base_y or 0.5
  updateJSFXFromGesture()
  
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      local key = fx_data.full_name .. "||" .. param_data.name
      local saved_param = snapshot.param_data[key]
      
      if saved_param then
        param_data.selected = saved_param.selected or false
        param_data.base_value = saved_param.base_value or param_data.current_value
        
        local actual_fx_id = fx_data.actual_fx_id or fx_id
        r.TrackFX_SetParam(state.track, actual_fx_id, param_id, param_data.base_value)
        param_data.current_value = param_data.base_value
        
        setParamRange(fx_id, param_id, saved_param.range or 1.0)
        setParamXYAssign(fx_id, param_id, "x", saved_param.x_assign)
        setParamXYAssign(fx_id, param_id, "y", saved_param.y_assign)
        setParamInvert(fx_id, param_id, saved_param.invert or false)
      end
    end
  end
  
  r.Undo_EndBlock("Load FX Constellation snapshot: " .. name, -1)
  updateSelectedCount()
  captureBaseValues()
  saveTrackSelection()
end

function deleteSnapshot(name)
  local fx_sig = getCurrentFXChainSignature()
  if fx_sig and state.snapshots[fx_sig] and state.snapshots[fx_sig][name] then
    state.snapshots[fx_sig][name] = nil
    if not next(state.snapshots[fx_sig]) then
      state.snapshots[fx_sig] = nil
    end
    scheduleSnapshotSave()
  end
end

function randomBypassFX()
  if not isTrackValid() then return end
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
  scanTrackFX()
end

function serialize(t)
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

function deserialize(s)
  if s == "" then return {} end
  local f, err = load("return " .. s)
  if f then
    local ok, res = pcall(f)
    if ok then return res end
  end
  return {}
end

function loadSettings()
  local filters_str = r.GetExtState("CP_FXConstellation", "filter_keywords")
  if filters_str ~= "" then
    state.filter_keywords = {}
    for word in filters_str:gmatch("[^,]+") do
      table.insert(state.filter_keywords, word)
    end
  else
    state.filter_keywords = { "MIDI", "CC", "midi", "Program", "Bank", "Channel", "Wet", "Dry" }
  end

  local param_filter_saved = r.GetExtState("CP_FXConstellation", "param_filter")
  if param_filter_saved ~= "" then
    state.param_filter = param_filter_saved
  end

  local saved_state = r.GetExtState("CP_FXConstellation", "state")
  if saved_state ~= "" then
    local loaded = deserialize(saved_state)
    if loaded then
      for k, v in pairs(loaded) do
        state[k] = v
      end
    end
  end

  local saved_selections = r.GetExtState("CP_FXConstellation", "track_selections")
  if saved_selections ~= "" then
    state.track_selections = deserialize(saved_selections) or {}
  end

  local saved_granular_sets = r.GetExtState("CP_FXConstellation", "granular_sets")
  if saved_granular_sets ~= "" then
    state.granular_sets = deserialize(saved_granular_sets) or {}
  end

  local saved_snapshots = r.GetExtState("CP_FXConstellation", "snapshots")
  if saved_snapshots ~= "" then
    state.snapshots = deserialize(saved_snapshots) or {}
  end

  local saved_presets = r.GetExtState("CP_FXConstellation", "presets")
  if saved_presets ~= "" then
    state.presets = deserialize(saved_presets) or {}
  end
end

function scheduleSave()
  local current_time = r.time_precise()
  if current_time - state.save_cooldown > state.min_save_interval then
    save_flags.settings = true
    state.save_timer = current_time + 2.0
  end
end

function scheduleTrackSave()
  save_flags.track_selections = true
end

function schedulePresetSave()
  save_flags.presets = true
end

function scheduleGranularSave()
  save_flags.granular_sets = true
end

function scheduleSnapshotSave()
  save_flags.snapshots = true
end

function calculateFiguresPosition(time)
  local angle = time * state.figures_speed * 2 * math.pi
  local size = state.figures_size

  if state.figures_mode == 0 then
    local x = 0.5 + (size * 0.5) * math.cos(angle)
    local y = 0.5 + (size * 0.5) * math.sin(angle)
    return x, y
  elseif state.figures_mode == 1 then
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
      x = 0.5 - half_size + t * size
      y = 0.5 + half_size - t * half_size
    end
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  elseif state.figures_mode == 3 then
    local progress = (angle / (2 * math.pi)) % 1
    local half_size = size * 0.5
    local x, y
    if progress < 0.25 then
      local t = progress * 4
      x = 0.5 - half_size + t * half_size
      y = 0.5 + t * half_size
    elseif progress < 0.5 then
      local t = (progress - 0.25) * 4
      x = 0.5 + t * half_size
      y = 0.5 + half_size - t * half_size
    elseif progress < 0.75 then
      local t = (progress - 0.5) * 4
      x = 0.5 + half_size - t * half_size
      y = 0.5 - t * half_size
    else
      local t = (progress - 0.75) * 4
      x = 0.5 - t * half_size
      y = 0.5 - half_size + t * half_size
    end
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  elseif state.figures_mode == 4 then
    local progress = (angle / (2 * math.pi)) % 1
    local half_size = size * 0.5
    local x, y
    if progress < 0.25 then
      local t = progress * 4
      x = 0.5 - half_size + t * size
      y = 0.5 + half_size
    elseif progress < 0.5 then
      local t = (progress - 0.25) * 4
      x = 0.5 + half_size - t * size
      y = 0.5 + half_size - t * size
    elseif progress < 0.75 then
      local t = (progress - 0.5) * 4
      x = 0.5 - half_size + t * size
      y = 0.5 - half_size
    else
      local t = (progress - 0.75) * 4
      x = 0.5 + half_size - t * size
      y = 0.5 - half_size + t * size
    end
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  elseif state.figures_mode == 5 then
    local a = 0.5
    local scale = size * 0.4
    local x = 0.5 + scale * math.sin(angle) / (1 + math.cos(angle) * math.cos(angle))
    local y = 0.5 + scale * math.sin(angle) * math.cos(angle) / (1 + math.cos(angle) * math.cos(angle))
    return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  end

  return 0.5, 0.5
end

function bezierCurve(t, p0, p1, p2, p3)
  local u = 1 - t
  local tt = t * t
  local uu = u * u
  local uuu = uu * u
  local ttt = tt * t

  local x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x
  local y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y

  return x, y
end

function generateRandomWalkControlPoints()
  local current = { x = state.gesture_x, y = state.gesture_y }
  local target = { x = math.random(), y = math.random() }

  local dx = target.x - current.x
  local dy = target.y - current.y
  local distance = math.sqrt(dx * dx + dy * dy)

  local control1 = {
    x = current.x + dx * 0.3 + (math.random() - 0.5) * 0.2,
    y = current.y + dy * 0.3 + (math.random() - 0.5) * 0.2
  }

  local control2 = {
    x = current.x + dx * 0.7 + (math.random() - 0.5) * 0.2,
    y = current.y + dy * 0.7 + (math.random() - 0.5) * 0.2
  }

  control1.x = math.max(0, math.min(1, control1.x))
  control1.y = math.max(0, math.min(1, control1.y))
  control2.x = math.max(0, math.min(1, control2.x))
  control2.y = math.max(0, math.min(1, control2.y))

  state.random_walk_control_points = {
    p0 = current,
    p1 = control1,
    p2 = control2,
    p3 = target
  }
  state.random_walk_bezier_progress = 0
  state.target_gesture_x = target.x
  state.target_gesture_y = target.y
end

function findAutomationJSFX()
  if not isTrackValid() then return -1 end
  local fx_count = r.TrackFX_GetCount(state.track)
  for fx_id = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx_id, "")
    if fx_name:find("FX Constellation Bridge") then
      return fx_id
    end
  end
  return -1
end

function createAutomationJSFX()
  if not isTrackValid() then return false end
  local jsfx_code = [[
desc: FX Constellation Bridge
slider1:x_pos=0.5<0,1,0.001>X Position
slider2:y_pos=0.5<0,1,0.001>Y Position

@sample
// Pass audio through unchanged
spl0 = spl0;
spl1 = spl1;
]]

  local jsfx_path = r.GetResourcePath() .. "/Effects/FX Constellation Bridge.jsfx"
  local file = io.open(jsfx_path, "w")
  if file then
    file:write(jsfx_code)
    file:close()
    local fx_index = r.TrackFX_AddByName(state.track, "FX Constellation Bridge", false, -1)
    if fx_index >= 0 then
      state.jsfx_automation_index = fx_index
      state.jsfx_automation_enabled = true
      return true
    end
  end
  return false
end

function updateAutomationFromJSFX()
  if not state.jsfx_automation_enabled or state.jsfx_automation_index < 0 then return end
  if not isTrackValid() then return end

  local jsfx_x = r.TrackFX_GetParam(state.track, state.jsfx_automation_index, 0)
  local jsfx_y = r.TrackFX_GetParam(state.track, state.jsfx_automation_index, 1)

  if state.pad_mode == 1 then
    if not state.granular_grains or #state.granular_grains == 0 then
      initializeGranularGrid()
    end
    applyGranularGesture(jsfx_x, jsfx_y)
  else
    applyGestureToSelection(jsfx_x, jsfx_y)
  end
end

function updateJSFXFromGesture()
  if not state.jsfx_automation_enabled or state.jsfx_automation_index < 0 then return end
  if not isTrackValid() then return end

  r.TrackFX_SetParam(state.track, state.jsfx_automation_index, 0, state.gesture_x)
  r.TrackFX_SetParam(state.track, state.jsfx_automation_index, 1, state.gesture_y)
end

function updateGestureMotion()
  local current_time = r.time_precise()

  updateAutomationFromJSFX()

  if state.navigation_mode == 1 then
    if state.random_walk_active then
      if current_time >= state.random_walk_next_time then
        generateRandomWalkControlPoints()
        local base_interval = 1.0 / state.random_walk_speed
        local jitter_amount = base_interval * state.random_walk_jitter
        local jitter = (math.random() * 2 - 1) * jitter_amount
        state.random_walk_next_time = current_time + base_interval + jitter
        state.random_walk_last_time = current_time
      end

      if state.random_walk_control_points and state.random_walk_control_points.p0 then
        local duration = state.random_walk_next_time - state.random_walk_last_time
        local elapsed = current_time - state.random_walk_last_time
        local progress = math.min(1.0, elapsed / duration)

        state.random_walk_bezier_progress = progress
        local x, y = bezierCurve(progress,
          state.random_walk_control_points.p0,
          state.random_walk_control_points.p1,
          state.random_walk_control_points.p2,
          state.random_walk_control_points.p3)

        state.gesture_x = x
        state.gesture_y = y
        updateJSFXFromGesture()

        if state.pad_mode == 1 then
          if not state.granular_grains or #state.granular_grains == 0 then
            initializeGranularGrid()
          end
          applyGranularGesture(state.gesture_x, state.gesture_y)
        else
          applyGestureToSelection(state.gesture_x, state.gesture_y)
        end
      end
    end
  elseif state.navigation_mode == 2 then
    if state.figures_active then
      state.figures_time = state.figures_time + (current_time - (state.last_figures_update or current_time))
      local x, y = calculateFiguresPosition(state.figures_time)
      state.gesture_x = x
      state.gesture_y = y
      updateJSFXFromGesture()

      if state.pad_mode == 1 then
        if not state.granular_grains or #state.granular_grains == 0 then
          initializeGranularGrid()
        end
        applyGranularGesture(state.gesture_x, state.gesture_y)
      else
        applyGestureToSelection(state.gesture_x, state.gesture_y)
      end
    end
    state.last_figures_update = current_time
  else
    if not state.gesture_active and state.smooth_speed > 0 then
      local dx = state.target_gesture_x - state.gesture_x
      local dy = state.target_gesture_y - state.gesture_y
      local distance = math.sqrt(dx * dx + dy * dy)
      if distance > 0.001 then
        local max_distance = state.max_gesture_speed *
        (current_time - (state.last_smooth_update or current_time))
        if distance > max_distance then
          dx = dx / distance * max_distance
          dy = dy / distance * max_distance
        end
        state.gesture_x = state.gesture_x + dx * state.smooth_speed
        state.gesture_y = state.gesture_y + dy * state.smooth_speed
        if state.pad_mode == 1 then
          if not state.granular_grains or #state.granular_grains == 0 then
            initializeGranularGrid()
          end
          applyGranularGesture(state.gesture_x, state.gesture_y)
        else
          applyGestureToSelection(state.gesture_x, state.gesture_y)
        end
      end
    end
  end
  state.last_smooth_update = current_time
end

function checkSave()
  if r.time_precise() > state.save_timer then
    if save_flags.settings or save_flags.track_selections or save_flags.presets or save_flags.granular_sets or save_flags.snapshots then
      saveSettings()
      save_flags.settings = false
      save_flags.track_selections = false
      save_flags.presets = false
      save_flags.granular_sets = false
      save_flags.snapshots = false
      state.save_cooldown = r.time_precise()
    end
  end
end

function saveSettings()
  if save_flags.settings then
    local save_data = {
      gesture_x = state.gesture_x,
      gesture_y = state.gesture_y,
      randomize_intensity = state.randomize_intensity,
      randomize_min = state.randomize_min,
      randomize_max = state.randomize_max,
      gesture_min = state.gesture_min,
      gesture_max = state.gesture_max,
      gesture_range = state.gesture_range,
      pad_mode = state.pad_mode,
      navigation_mode = state.navigation_mode,
      x_curve = state.x_curve,
      random_min = state.random_min,
      random_max = state.random_max,
      exclusive_xy = state.exclusive_xy,
      smooth_speed = state.smooth_speed,
      max_gesture_speed = state.max_gesture_speed,
      random_walk_speed = state.random_walk_speed,
      random_walk_smooth = state.random_walk_smooth,
      random_walk_jitter = state.random_walk_jitter,
      target_gesture_x = state.target_gesture_x,
      target_gesture_y = state.target_gesture_y,
      granular_grid_size = state.granular_grid_size,
      random_bypass_percentage = state.random_bypass_percentage,
      layout_mode = state.layout_mode,
      fx_collapsed = state.fx_collapsed,
      range_min = state.range_min,
      range_max = state.range_max,
      figures_mode = state.figures_mode,
      figures_speed = state.figures_speed,
      figures_size = state.figures_size,
      save_fx_chain = state.save_fx_chain,
      jsfx_automation_enabled = state.jsfx_automation_enabled,
      current_loaded_preset = state.current_loaded_preset
    }
    r.SetExtState("CP_FXConstellation", "state", serialize(save_data), false)
  end

  if save_flags.track_selections then
    local current_guid = getTrackGUID()
    if current_guid and state.track_selections[current_guid] then
      local track_data = {}
      track_data[current_guid] = state.track_selections[current_guid]
      r.SetExtState("CP_FXConstellation", "track_selections", serialize(track_data), false)
    end
  end

  if save_flags.presets and next(state.presets) then
    r.SetExtState("CP_FXConstellation", "presets", serialize(state.presets), false)
  end

  if save_flags.granular_sets and next(state.granular_sets) then
    r.SetExtState("CP_FXConstellation", "granular_sets", serialize(state.granular_sets), false)
  end

  if save_flags.snapshots and next(state.snapshots) then
    r.SetExtState("CP_FXConstellation", "snapshots", serialize(state.snapshots), false)
  end

  if save_flags.settings then
    local filters_str = table.concat(state.filter_keywords, ",")
    r.SetExtState("CP_FXConstellation", "filter_keywords", filters_str, true)

    r.SetExtState("CP_FXConstellation", "param_filter", state.param_filter, true)
  end
end

function getTrackGUID()
  if not isTrackValid() then return nil end
  local _, guid = r.GetSetMediaTrackInfo_String(state.track, "GUID", "", false)
  return guid
end

function saveTrackSelection()
  local guid = getTrackGUID()
  if not guid then return end
  local selection = {}
  local ranges = {}
  local xy_assign = {}
  local invert_assign = {}
  local fx_rand_max = {}
  local base_values = {}
  for fx_id, fx_data in pairs(state.fx_data) do
    local fx_key = guid .. "_" .. fx_data.full_name
    fx_rand_max[fx_data.full_name] = state.fx_random_max[fx_key] or 3
    for param_id, param_data in pairs(fx_data.params) do
      local key = fx_data.full_name .. "||" .. param_data.name
      if param_data.selected then
        selection[key] = true
      end
      local range_key = guid .. "_" .. key .. "_range"
      local invert_key = guid .. "_" .. key .. "_invert"
      local x_key = guid .. "_" .. key .. "_x"
      local y_key = guid .. "_" .. key .. "_y"
      ranges[key] = state.param_ranges[range_key] or 1.0
      invert_assign[key] = state.param_invert[invert_key] or false
      xy_assign[key] = {
        x = state.param_xy_assign[x_key] ~= false,
        y = state.param_xy_assign[y_key] ~= false
      }
      base_values[key] = param_data.base_value
    end
  end
  state.track_selections[guid] = {
  selection = selection,
  ranges = ranges,
  xy_assign = xy_assign,
  invert_assign = invert_assign,
  fx_random_max = fx_rand_max,
  base_values = base_values,
  gesture_base_x = state.gesture_base_x,
  gesture_base_y = state.gesture_base_y,
  gesture_x = state.gesture_x,
  gesture_y = state.gesture_y,
   current_preset = state.current_loaded_preset
	}
  scheduleTrackSave()
end

function loadTrackSelection()
local guid = getTrackGUID()
if not guid then return end
local track_data = state.track_selections[guid]
if not track_data then
state.current_loaded_preset = ""
captureBaseValues()
 return
	end
  local selection = track_data.selection or {}
  local ranges = track_data.ranges or {}
  local xy_assign = track_data.xy_assign or {}
  local invert_assign = track_data.invert_assign or {}
  local fx_rand_max = track_data.fx_random_max or {}
  local base_values = track_data.base_values or {}
  state.gesture_base_x = track_data.gesture_base_x or 0.5
  state.gesture_base_y = track_data.gesture_base_y or 0.5
  state.gesture_x = track_data.gesture_x or 0.5
  state.gesture_y = track_data.gesture_y or 0.5
  state.current_loaded_preset = track_data.current_preset or ""
	updateJSFXFromGesture()
  for fx_id, fx_data in pairs(state.fx_data) do
    local fx_key = guid .. "_" .. fx_data.full_name
    if fx_rand_max[fx_data.full_name] then
      state.fx_random_max[fx_key] = fx_rand_max[fx_data.full_name]
    end
    for param_id, param_data in pairs(fx_data.params) do
      local key = fx_data.full_name .. "||" .. param_data.name
      param_data.selected = selection[key] or false
      param_data.base_value = base_values[key] or param_data.current_value
      local range_key = guid .. "_" .. key .. "_range"
      state.param_ranges[range_key] = ranges[key] or 1.0
      local invert_key = guid .. "_" .. key .. "_invert"
      state.param_invert[invert_key] = invert_assign[key] or false
      local xy = xy_assign[key]
      if xy then
        local x_key = guid .. "_" .. key .. "_x"
        local y_key = guid .. "_" .. key .. "_y"
        state.param_xy_assign[x_key] = xy.x
        state.param_xy_assign[y_key] = xy.y
      else
        local x_key = guid .. "_" .. key .. "_x"
        local y_key = guid .. "_" .. key .. "_y"
        state.param_xy_assign[x_key] = true
        state.param_xy_assign[y_key] = true
      end
    end
  end
  updateSelectedCount()
end

function createFXSignature()
  if not isTrackValid() then return "" end
  local sig = ""
  local fx_count = r.TrackFX_GetCount(state.track)
  for fx = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx, "")
    sig = sig .. fx_name .. ":" .. r.TrackFX_GetNumParams(state.track, fx) .. ";"
  end
  return sig
end

function getCurrentFXChainSignature()
  local guid = getTrackGUID()
  if not guid then return nil end
  return guid .. "_" .. createFXSignature()
end

function shouldFilterParam(param_name)
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

function extractFXName(full_name)
  local clean_name = full_name:match("^[^:]*:%s*(.+)") or full_name
  clean_name = clean_name:gsub("%(.-%)", "")
  clean_name = clean_name:match("^%s*(.-)%s*$")
  if clean_name:len() > 25 then
    clean_name = clean_name:sub(1, 22) .. "..."
  end
  return clean_name
end

function scanTrackFX()
  if not isTrackValid() then return end
  state.fx_data = {}
  local fx_count = r.TrackFX_GetCount(state.track)
  local visible_fx_id = 0
  for fx = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx, "")
    if not fx_name:find("FX Constellation Bridge") then
      local param_count = r.TrackFX_GetNumParams(state.track, fx)
      state.fx_data[visible_fx_id] = {
        name = extractFXName(fx_name),
        full_name = fx_name,
        enabled = r.TrackFX_GetEnabled(state.track, fx),
        actual_fx_id = fx,
        params = {}
      }
      local fx_key = getFXKey(visible_fx_id)
      if fx_key and state.fx_random_max[fx_key] == nil then
        state.fx_random_max[fx_key] = 3
      end
      for param = 0, param_count - 1 do
        local _, param_name = r.TrackFX_GetParamName(state.track, fx, param, "")
        if not shouldFilterParam(param_name) then
          local value = r.TrackFX_GetParam(state.track, fx, param)
          local step_count = detectParamSteps(visible_fx_id, param)
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
  state.last_fx_signature = createFXSignature()
  loadTrackSelection()
  updateSelectedCount()
end

function checkForFXChanges()
  if not isTrackValid() then return false end
  local current_time = r.time_precise()
  if current_time - state.last_update_time < state.update_interval then
    return false
  end
  state.last_update_time = current_time
  local current_fx_count = r.TrackFX_GetCount(state.track)
  local current_signature = createFXSignature()
  local changes_detected = false
  if current_fx_count ~= state.last_fx_count or current_signature ~= state.last_fx_signature then
    scanTrackFX()
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

function updateSelectedCount()
  state.selected_count = 0
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        state.selected_count = state.selected_count + 1
      end
    end
  end
end

function selectAllContinuousParams(params, selected)
  for _, param in pairs(params) do
    if not param.step_count or param.step_count == 0 then
      param.selected = selected
    end
  end
  updateSelectedCount()
  saveTrackSelection()
end

function selectAllParams(params, selected)
  for _, param in pairs(params) do
    param.selected = selected
  end
  updateSelectedCount()
  saveTrackSelection()
end

function getParamRange(fx_id, param_id)
  local key = getParamKey(fx_id, param_id, "range")
  if not key then return 1.0 end
  return state.param_ranges[key] or 1.0
end

function setParamRange(fx_id, param_id, range)
  local key = getParamKey(fx_id, param_id, "range")
  if not key then return end
  state.param_ranges[key] = range
  saveTrackSelection()
end

function getParamInvert(fx_id, param_id)
  local key = getParamKey(fx_id, param_id, "invert")
  if not key then return false end
  return state.param_invert[key] or false
end

function setParamInvert(fx_id, param_id, invert)
  local key = getParamKey(fx_id, param_id, "invert")
  if not key then return end
  state.param_invert[key] = invert
  saveTrackSelection()
end

function getParamXYAssign(fx_id, param_id)
  local x_key = getParamKey(fx_id, param_id, "x")
  local y_key = getParamKey(fx_id, param_id, "y")
  if not x_key or not y_key then return true, true end
  return state.param_xy_assign[x_key] ~= false, state.param_xy_assign[y_key] ~= false
end

function setParamXYAssign(fx_id, param_id, axis, value)
  local key = getParamKey(fx_id, param_id, axis)
  if not key then return end
  state.param_xy_assign[key] = value
  if state.exclusive_xy and value then
    local other_axis = axis == "x" and "y" or "x"
    local other_key = getParamKey(fx_id, param_id, other_axis)
    if other_key then
      state.param_xy_assign[other_key] = false
    end
  end
  saveTrackSelection()
end

function randomSelectParams(params, fx_id)
  selectAllParams(params, false)
  local param_list = {}
  for id, param in pairs(params) do
    table.insert(param_list, param)
  end
  if #param_list == 0 then return end
  local fx_key = getFXKey(fx_id)
  local max_count = (fx_key and state.fx_random_max[fx_key]) or 3
  local count = math.random(1, math.min(max_count, #param_list))
  for i = 1, count do
    local idx = math.random(1, #param_list)
    param_list[idx].selected = true
    table.remove(param_list, idx)
  end
  updateSelectedCount()
  captureBaseValues()
  saveTrackSelection()
end

function randomizeBaseValues(params, fx_id)
  if not isTrackValid() then return end
  local actual_fx_id = state.fx_data[fx_id] and state.fx_data[fx_id].actual_fx_id or fx_id
  for param_id, param_data in pairs(params) do
    if param_data.selected then
      local new_base = math.random()
      param_data.base_value = new_base
      local key = getParamKey(fx_id, param_id)
      if key then
        state.param_base_values[key] = new_base
      end
      r.TrackFX_SetParam(state.track, actual_fx_id, param_id, new_base)
      param_data.current_value = new_base
    end
  end
  saveTrackSelection()
end

function randomizeAllBases()
  if not isTrackValid() then return end
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
        local key = getParamKey(fx_id, param_id)
        if key then
          state.param_base_values[key] = new_base
        end
        r.TrackFX_SetParam(state.track, fx_id, param_id, new_base)
        param_data.current_value = new_base
      end
    end
  end
  r.Undo_EndBlock("Randomize all bases", -1)
  captureBaseValues()
  saveTrackSelection()
end

function randomizeXYAssign(params, fx_id)
  for param_id, param_data in pairs(params) do
    if param_data.selected then
      local rand = math.random()
      if state.exclusive_xy then
        setParamXYAssign(fx_id, param_id, "x", rand < 0.5)
        setParamXYAssign(fx_id, param_id, "y", rand >= 0.5)
      else
        if rand < 0.33 then
          setParamXYAssign(fx_id, param_id, "x", true)
          setParamXYAssign(fx_id, param_id, "y", false)
        elseif rand < 0.66 then
          setParamXYAssign(fx_id, param_id, "x", false)
          setParamXYAssign(fx_id, param_id, "y", true)
        else
          setParamXYAssign(fx_id, param_id, "x", true)
          setParamXYAssign(fx_id, param_id, "y", true)
        end
      end
    end
  end
end

function globalRandomInvert()
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        setParamInvert(fx_id, param_id, math.random() < 0.5)
      end
    end
  end
end

function globalRandomXYAssign()
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local rand = math.random()
        if state.exclusive_xy then
          setParamXYAssign(fx_id, param_id, "x", rand < 0.5)
          setParamXYAssign(fx_id, param_id, "y", rand >= 0.5)
        else
          if rand < 0.33 then
            setParamXYAssign(fx_id, param_id, "x", true)
            setParamXYAssign(fx_id, param_id, "y", false)
          elseif rand < 0.66 then
            setParamXYAssign(fx_id, param_id, "x", false)
            setParamXYAssign(fx_id, param_id, "y", true)
          else
            setParamXYAssign(fx_id, param_id, "x", true)
            setParamXYAssign(fx_id, param_id, "y", true)
          end
        end
      end
    end
  end
end

function randomizeRanges(params, fx_id)
  for param_id, param_data in pairs(params) do
    if param_data.selected then
      local new_range = state.range_min + math.random() * (state.range_max - state.range_min)
      setParamRange(fx_id, param_id, new_range)
    end
  end
end

function globalRandomRanges()
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local new_range = state.range_min + math.random() * (state.range_max - state.range_min)
        setParamRange(fx_id, param_id, new_range)
      end
    end
  end
end

function globalRandomSelect()
  for fx_id, fx_data in pairs(state.fx_data) do
    selectAllParams(fx_data.params, false)
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
  updateSelectedCount()
  captureBaseValues()
  saveTrackSelection()
end

function randomizeFXOrder()
  if not isTrackValid() then return end
  local fx_count = r.TrackFX_GetCount(state.track)
  if fx_count < 2 then return end
  saveTrackSelection()
  r.Undo_BeginBlock()

  local jsfx_index = findAutomationJSFX()
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
    initializeGranularGrid()
  end
  scanTrackFX()
  state.jsfx_automation_index = findAutomationJSFX()
  state.jsfx_automation_enabled = state.jsfx_automation_index >= 0
end

function captureBaseValues()
  state.param_base_values = {}
  state.gesture_base_x = state.gesture_x
  state.gesture_base_y = state.gesture_y
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        param_data.base_value = param_data.current_value
        local key = getParamKey(fx_id, param_id)
        if key then
          state.param_base_values[key] = param_data.current_value
        end
      end
    end
  end
end

function updateParamBaseValue(fx_id, param_id, new_value)
  if not isTrackValid() then return end
  local param_data = state.fx_data[fx_id].params[param_id]
  if param_data then
    param_data.base_value = new_value
    local key = getParamKey(fx_id, param_id)
    if key then
      state.param_base_values[key] = new_value
    end
    local actual_fx_id = state.fx_data[fx_id].actual_fx_id or fx_id
    r.TrackFX_SetParam(state.track, actual_fx_id, param_id, new_value)
    param_data.current_value = new_value
    saveTrackSelection()
  end
end

function calculateAsymmetricRange(base, range, intensity, min_limit, max_limit)
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

function snapToDiscreteValue(value, step_count)
  if step_count <= 1 then return value end
  local step = 1.0 / (step_count - 1)
  local closest_step = math.floor((value / step) + 0.5)
  return closest_step * step
end

function detectParamSteps(fx_id, param_id)
  if not isTrackValid() then return 0 end
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

function applyGestureToSelection(gx, gy)
  if not isTrackValid() then return end
  local offset_x = (gx - state.gesture_base_x) * 2
  local offset_y = (gy - state.gesture_base_y) * 2
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local param_range = getParamRange(fx_id, param_id)
        local x_assign, y_assign = getParamXYAssign(fx_id, param_id)
        local param_invert = getParamInvert(fx_id, param_id)
        local base_key = getParamKey(fx_id, param_id)
        local base_value = (base_key and state.param_base_values[base_key]) or param_data.base_value
        local up_range, down_range = calculateAsymmetricRange(base_value, param_range, state.gesture_range,
          state.gesture_min, state.gesture_max)
        local new_value = base_value
        local x_contribution = 0
        local y_contribution = 0
        if x_assign then
          local x_offset = offset_x
          if param_invert then x_offset = -x_offset end
          x_contribution = x_offset > 0 and x_offset * up_range or x_offset * down_range
        end
        if y_assign then
          local y_offset = offset_y
          if param_invert then y_offset = -y_offset end
          y_contribution = y_offset > 0 and y_offset * up_range or y_offset * down_range
        end
        if x_assign and y_assign then
          new_value = base_value + (x_contribution + y_contribution) / 2
        elseif x_assign then
          new_value = base_value + x_contribution
        elseif y_assign then
          new_value = base_value + y_contribution
        end
        new_value = math.max(state.gesture_min, math.min(state.gesture_max, new_value))
        if param_data.step_count and param_data.step_count > 0 then
          new_value = snapToDiscreteValue(new_value, param_data.step_count)
        end
        local actual_fx_id = fx_data.actual_fx_id or fx_id
        r.TrackFX_SetParam(state.track, actual_fx_id, param_id, new_value)
        param_data.current_value = new_value
        param_data.base_value = new_value
      end
    end
  end
end

function randomizeSelection()
  if not isTrackValid() then return end
  state.last_random_seed = os.time() + math.random(1000)
  math.randomseed(state.last_random_seed)
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        local param_range = getParamRange(fx_id, param_id)
        local up_range, down_range = calculateAsymmetricRange(param_data.base_value, param_range,
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
  captureBaseValues()
  saveTrackSelection()
end

function captureToMorph(slot)
  local preset = {}
  for fx_id, fx_data in pairs(state.fx_data) do
    preset[fx_data.full_name] = {
      enabled = fx_data.enabled,
      params = {}
    }
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        preset[fx_data.full_name].params[param_data.name] = param_data.current_value
      end
    end
  end
  if slot == 1 then
    state.morph_preset_a = preset
  else
    state.morph_preset_b = preset
  end
end

function morphBetweenPresets(amount)
  if not state.morph_preset_a or not state.morph_preset_b or not isTrackValid() then return end
  for fx_id, fx_data in pairs(state.fx_data) do
    local preset_a = state.morph_preset_a[fx_data.full_name]
    local preset_b = state.morph_preset_b[fx_data.full_name]
    if preset_a and preset_b then
      local params_a = preset_a.params or preset_a
      local params_b = preset_b.params or preset_b
      for param_id, param_data in pairs(fx_data.params) do
        local value_a = params_a[param_data.name]
        local value_b = params_b[param_data.name]
        if value_a and value_b then
          local morphed_value = value_a * (1 - amount) + value_b * amount
          r.TrackFX_SetParam(state.track, fx_id, param_id, morphed_value)
          param_data.current_value = morphed_value
        end
      end
    end
  end
end

function captureCompleteState()
  if not isTrackValid() then return {} end

  local complete_state = {
    gesture_x = state.gesture_x,
    gesture_y = state.gesture_y,
    gesture_base_x = state.gesture_base_x,
    gesture_base_y = state.gesture_base_y,
    fx_chain = {},
    track_guid = getTrackGUID()
  }

  local fx_count = r.TrackFX_GetCount(state.track)
  for fx_id = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx_id, "")
    local enabled = r.TrackFX_GetEnabled(state.track, fx_id)
    local retval, preset = r.TrackFX_GetPreset(state.track, fx_id, "")
    local param_count = r.TrackFX_GetNumParams(state.track, fx_id)

    complete_state.fx_chain[fx_id] = {
      name = fx_name,
      enabled = enabled,
      preset = retval and preset or "",
      param_count = param_count,
      params = {}
    }

    if state.fx_data[fx_id] then
    for param_id, param_data in pairs(state.fx_data[fx_id].params) do
    local x_assign, y_assign = getParamXYAssign(fx_id, param_id)
    complete_state.fx_chain[fx_id].params[param_id] = {
    name = param_data.name,
    current_value = param_data.current_value,
    base_value = param_data.base_value,
    selected = param_data.selected,
    range = getParamRange(fx_id, param_id),
    x_assign = x_assign,
    y_assign = y_assign,
     invert = getParamInvert(fx_id, param_id)
     }
     end
      end
  end

  return complete_state
end

function savePreset(name)
if name == "" then return end
local preset_data = captureCompleteState()
state.presets[name] = preset_data
schedulePresetSave()
end

function loadPreset(name)
if not isTrackValid() then return end
local preset = state.presets[name]
if not preset then return end

local missing_fx = {}
local param_count_warnings = {}

local original_fxfloat = r.SNM_GetIntConfigVar("fxfloat_focus", -1)
	if original_fxfloat >= 0 then
		r.SNM_SetIntConfigVar("fxfloat_focus", 0)
	end

	r.Undo_BeginBlock()

  local fx_count = r.TrackFX_GetCount(state.track)
  for fx_id = fx_count - 1, 0, -1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx_id, "")
    if not fx_name:find("FX Constellation Bridge") then
      r.TrackFX_Delete(state.track, fx_id)
    end
  end

  local fx_order = {}
  for fx_id, fx_preset in pairs(preset.fx_chain or {}) do
    table.insert(fx_order, {id = fx_id, preset = fx_preset})
  end
  table.sort(fx_order, function(a, b) return a.id < b.id end)

  for _, fx_entry in ipairs(fx_order) do
    local fx_preset = fx_entry.preset
    if not fx_preset.name:find("FX Constellation Bridge") then
      local new_fx_id = r.TrackFX_AddByName(state.track, fx_preset.name, false, -1)
      if new_fx_id >= 0 then
        r.TrackFX_SetEnabled(state.track, new_fx_id, fx_preset.enabled)
        if fx_preset.preset and fx_preset.preset ~= "" then
          r.TrackFX_SetPreset(state.track, new_fx_id, fx_preset.preset)
        end
        if fx_preset.param_count then
          local current_param_count = r.TrackFX_GetNumParams(state.track, new_fx_id)
          if current_param_count ~= fx_preset.param_count then
            table.insert(param_count_warnings, {
              name = fx_preset.name,
              expected = fx_preset.param_count,
              actual = current_param_count
            })
          end
        end
      else
        table.insert(missing_fx, fx_preset.name)
      end
    end
  end

  scanTrackFX()

  for fx_id, fx_data in pairs(state.fx_data) do
    state.fx_collapsed[fx_id] = false
  end

  state.gesture_x = preset.gesture_x or 0.5
  state.gesture_y = preset.gesture_y or 0.5
  updateJSFXFromGesture()
  state.gesture_base_x = preset.gesture_base_x or 0.5
  state.gesture_base_y = preset.gesture_base_y or 0.5

  for saved_fx_id, fx_preset in pairs(preset.fx_chain or {}) do
    for current_fx_id, fx_data in pairs(state.fx_data) do
      if fx_data.full_name == fx_preset.name then
        for saved_param_id, param_preset in pairs(fx_preset.params or {}) do
          for current_param_id, param_data in pairs(fx_data.params) do
            if param_data.name == param_preset.name then
              local actual_fx_id = fx_data.actual_fx_id or current_fx_id
              r.TrackFX_SetParam(state.track, actual_fx_id, current_param_id, param_preset.current_value)
              param_data.current_value = param_preset.current_value
              param_data.base_value = param_preset.base_value
              param_data.selected = param_preset.selected

              setParamRange(current_fx_id, current_param_id, param_preset.range or 1.0)
              setParamXYAssign(current_fx_id, current_param_id, "x", param_preset.x_assign)
              setParamXYAssign(current_fx_id, current_param_id, "y", param_preset.y_assign)
              setParamInvert(current_fx_id, current_param_id, param_preset.invert or false)
              break
            end
          end
        end
        break
      end
    end
  end

  r.Undo_EndBlock("Load FX Constellation preset: " .. name, -1)
  closeAllFloatingFX()
  updateSelectedCount()
  captureBaseValues()
  state.current_loaded_preset = name
  saveTrackSelection()

	if original_fxfloat >= 0 then
		r.SNM_SetIntConfigVar("fxfloat_focus", original_fxfloat)
	end

  if #missing_fx > 0 or #param_count_warnings > 0 then
    local msg = "FX Constellation - Preset Load Issues:\n\n"
    if #missing_fx > 0 then
      msg = msg .. "MISSING FX (not installed):\n"
      for i, fx_name in ipairs(missing_fx) do
        msg = msg .. "  - " .. fx_name .. "\n"
      end
      msg = msg .. "\n"
    end
    if #param_count_warnings > 0 then
      msg = msg .. "PARAMETER COUNT MISMATCHES (possible version change):\n"
      for i, warning in ipairs(param_count_warnings) do
        msg = msg .. "  - " .. warning.name .. "\n"
        msg = msg .. "    Expected: " .. warning.expected .. " params, Found: " .. warning.actual .. " params\n"
      end
    end
    r.ShowMessageBox(msg, "FX Constellation - Preset Warnings", 0)
  end
end

function deletePreset(name)
  if state.presets[name] then
    state.presets[name] = nil
    if state.selected_preset == name then
      state.selected_preset = ""
    end
    if state.current_loaded_preset == name then
      state.current_loaded_preset = ""
    end
    scheduleSave()
  end
end

function renamePreset(old_name, new_name)
  if state.presets[old_name] and new_name ~= "" and old_name ~= new_name then
    state.presets[new_name] = state.presets[old_name]
    state.presets[old_name] = nil
    if state.selected_preset == old_name then
      state.selected_preset = new_name
    end
    scheduleSave()
  end
end

function drawFiltersWindow()
  if not state.show_filters_window then return end
  if not filters_ctx or not r.ImGui_ValidatePtr(filters_ctx, "ImGui_Context*") then
    filters_ctx = r.ImGui_CreateContext('FX Constellation Filters')
    if style_loader then
      style_loader.ApplyFontsToContext(filters_ctx)
    end
  end
  if style_loader then
    local success, colors, vars = style_loader.applyToContext(filters_ctx)
    if success then filters_pushed_colors, filters_pushed_vars = colors, vars end
  end
  r.ImGui_SetNextWindowSize(filters_ctx, 400, 300, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(filters_ctx, 'Filter Keywords', true)
  if visible then
    local main_font = getStyleFont("main", filters_ctx)
    local header_font = getStyleFont("header", filters_ctx)

    if main_font and r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
      r.ImGui_PushFont(filters_ctx, main_font, 0)
    end

    if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
      r.ImGui_PushFont(filters_ctx, header_font, 0)
      r.ImGui_Text(filters_ctx, "FILTER KEYWORDS")
      r.ImGui_PopFont(filters_ctx)
    else
      r.ImGui_Text(filters_ctx, "Filter Keywords:")
    end

    local changed, new_word = r.ImGui_InputText(filters_ctx, "Add Filter", state.new_filter_word)
    if changed then state.new_filter_word = new_word end
    r.ImGui_SameLine(filters_ctx)
    if r.ImGui_Button(filters_ctx, "Add") and state.new_filter_word ~= "" then
      table.insert(state.filter_keywords, state.new_filter_word)
      state.new_filter_word = ""
      scheduleSave()
      scanTrackFX()
    end
    for i, keyword in ipairs(state.filter_keywords) do
      r.ImGui_Text(filters_ctx, keyword)
      r.ImGui_SameLine(filters_ctx)
      if r.ImGui_Button(filters_ctx, "X##" .. i) then
        table.remove(state.filter_keywords, i)
        scheduleSave()
        scanTrackFX()
        break
      end
    end
    r.ImGui_Separator(filters_ctx)
    r.ImGui_Text(filters_ctx, "Param Filter:")
    r.ImGui_SameLine(filters_ctx)
    r.ImGui_SetNextItemWidth(filters_ctx, 200)
    local changed, new_filter = r.ImGui_InputText(filters_ctx, "##paramfilter", state.param_filter)
    if changed then
      state.param_filter = new_filter
      scanTrackFX()
    end

    if main_font and r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
      r.ImGui_PopFont(filters_ctx)
    end
    r.ImGui_End(filters_ctx)
  end
  if not open then
    state.show_filters_window = false
  end
  if style_loader then style_loader.clearStyles(filters_ctx, filters_pushed_colors, filters_pushed_vars) end
end

function drawPresetsWindow()
  if not state.show_presets_window then return end
  if not presets_ctx or not r.ImGui_ValidatePtr(presets_ctx, "ImGui_Context*") then
    presets_ctx = r.ImGui_CreateContext('FX Constellation Presets')
    if style_loader then
      style_loader.ApplyFontsToContext(presets_ctx)
    end
  end
  if style_loader then
    local success, colors, vars = style_loader.applyToContext(presets_ctx)
    if success then presets_pushed_colors, presets_pushed_vars = colors, vars end
  end

  r.ImGui_SetNextWindowSize(presets_ctx, 400, 500, r.ImGui_Cond_FirstUseEver())
  local flags = r.ImGui_WindowFlags_NoTitleBar()
  local visible, open = r.ImGui_Begin(presets_ctx, '##PresetsWindow', true, flags)

  if visible then
    local main_font = getStyleFont("main", presets_ctx)
    local header_font = getStyleFont("header", presets_ctx)

    if main_font and r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
      r.ImGui_PushFont(presets_ctx, main_font, 0)
    end

    local window_width = r.ImGui_GetWindowWidth(presets_ctx)

    if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
      r.ImGui_PushFont(presets_ctx, header_font, 0)
      r.ImGui_Text(presets_ctx, "PRESETS")
      r.ImGui_PopFont(presets_ctx)
    else
      r.ImGui_Text(presets_ctx, "Presets")
    end

    r.ImGui_SameLine(presets_ctx, window_width - 30)
    if r.ImGui_Button(presets_ctx, "X", 20, 20) then
      state.show_presets_window = false
    end

    r.ImGui_Separator(presets_ctx)
    r.ImGui_Dummy(presets_ctx, 0, 4)

    if r.ImGui_Button(presets_ctx, "Save Preset", window_width - 20) then
      local retval, preset_name = r.GetUserInputs("Save FX Chain Preset", 1, "Preset name:", "")
      if retval and preset_name ~= "" then
        savePreset(preset_name)
      end
    end

    r.ImGui_Dummy(presets_ctx, 0, 4)

    if r.ImGui_BeginChild(presets_ctx, "PresetsList", 0, -1) then
      for name, preset_data in pairs(state.presets) do
        r.ImGui_PushID(presets_ctx, name)

        local btn_width = window_width - 80
        local clean_name = name:gsub("[^%w%s_%-]", "")
        if r.ImGui_Button(presets_ctx, clean_name, btn_width, 25) then
          loadPreset(name)
        end

        r.ImGui_SameLine(presets_ctx)
        if r.ImGui_Button(presets_ctx, "R", 25, 25) then
          local retval, new_name = r.GetUserInputs("Rename Preset", 1, "New name:", name)
          if retval and new_name ~= "" and new_name ~= name then
            renamePreset(name, new_name)
          end
        end

        r.ImGui_SameLine(presets_ctx)
        if r.ImGui_Button(presets_ctx, "X", 25, 25) then
          deletePreset(name)
        end

        r.ImGui_PopID(presets_ctx)
      end
      r.ImGui_EndChild(presets_ctx)
    end

    if main_font and r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
      r.ImGui_PopFont(presets_ctx)
    end
    r.ImGui_End(presets_ctx)
  end

  if not open then
    state.show_presets_window = false
  end
  if style_loader then style_loader.clearStyles(presets_ctx, presets_pushed_colors, presets_pushed_vars) end
end

function drawPatternIcon(draw_list, x, y, size, pattern_id, is_active)
  local center_x = x + size / 2
  local center_y = y + size / 2
  local radius = size * 0.35
  local color = is_active and 0xFFFFFFFF or 0x888888FF
  local thickness = is_active and 2 or 1

  if pattern_id == 0 then
    r.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, radius, color, 32, thickness)
  elseif pattern_id == 1 then
    local offset = radius
    r.ImGui_DrawList_AddRect(draw_list, center_x - offset, center_y - offset, center_x + offset, center_y + offset,
      color,
      0, 0, thickness)
  elseif pattern_id == 2 then
    local h = radius * 1.2
    r.ImGui_DrawList_AddTriangle(draw_list,
      center_x, center_y - h * 0.7,
      center_x - h * 0.6, center_y + h * 0.5,
      center_x + h * 0.6, center_y + h * 0.5,
      color, thickness)
  elseif pattern_id == 3 then
    local offset = radius * 0.8
    r.ImGui_DrawList_AddQuad(draw_list,
      center_x, center_y - offset,
      center_x + offset, center_y,
      center_x, center_y + offset,
      center_x - offset, center_y,
      color, thickness)
  elseif pattern_id == 4 then
    local offset = radius * 0.8
    r.ImGui_DrawList_AddLine(draw_list, center_x - offset, center_y + offset, center_x + offset, center_y - offset,
      color,
      thickness)
    r.ImGui_DrawList_AddLine(draw_list, center_x + offset, center_y + offset, center_x - offset, center_y - offset,
      color,
      thickness)
  elseif pattern_id == 5 then
    local segments = 64
    for i = 0, segments - 1 do
      local t1 = (i / segments) * 2 * math.pi
      local t2 = ((i + 1) / segments) * 2 * math.pi
      local scale = radius * 1.3
      local x1 = center_x + scale * math.sin(t1) / (1 + math.cos(t1) * math.cos(t1))
      local y1 = center_y + scale * math.sin(t1) * math.cos(t1) / (1 + math.cos(t1) * math.cos(t1))
      local x2 = center_x + scale * math.sin(t2) / (1 + math.cos(t2) * math.cos(t2))
      local y2 = center_y + scale * math.sin(t2) * math.cos(t2) / (1 + math.cos(t2) * math.cos(t2))
      r.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, color, thickness)
    end
  end
end

function drawNavigation()
  local header_font = getStyleFont("header")
  local content_width = r.ImGui_GetContentRegionAvail(ctx)
  if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, header_font, 0)
    r.ImGui_Text(ctx, "NAVIGATION")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end

  r.ImGui_SetNextItemWidth(ctx, 128)
  local nav_items = table.concat(navigation_modes, "\0") .. "\0"
  local changed, new_nav_mode = r.ImGui_Combo(ctx, "##navmode", state.navigation_mode, nav_items)
  if changed then
    state.navigation_mode = new_nav_mode
    if new_nav_mode == 1 then
      state.random_walk_active = true
      state.random_walk_next_time = r.time_precise() + 1.0 / state.random_walk_speed
      generateRandomWalkControlPoints()
      captureBaseValues()
    elseif new_nav_mode == 2 then
      state.figures_active = true
      state.figures_time = 0
      captureBaseValues()
    else
      state.random_walk_active = false
      state.figures_active = false
    end
    scheduleSave()
  end

  r.ImGui_Dummy(ctx, 0, 0)

  if state.navigation_mode == 0 then
    r.ImGui_SetNextItemWidth(ctx, content_width)
    local changed, new_smooth = r.ImGui_SliderDouble(ctx, "Smooth", state.smooth_speed, 0.0, 1.0, "%.2f")
    if changed then state.smooth_speed = new_smooth end
    r.ImGui_SetNextItemWidth(ctx, content_width)
    local changed, new_max_speed = r.ImGui_SliderDouble(ctx, "Speed", state.max_gesture_speed, 0.1, 10.0, "%.1f")
    if changed then state.max_gesture_speed = new_max_speed end
  elseif state.navigation_mode == 1 then
    r.ImGui_SetNextItemWidth(ctx, content_width)
    local changed, new_speed = r.ImGui_SliderDouble(ctx, "Speed", state.random_walk_speed, 0.1, 10.0, "%.1f Hz")
    if changed then
      state.random_walk_speed = new_speed
      if state.random_walk_active then
        state.random_walk_next_time = r.time_precise() + 1.0 / state.random_walk_speed
      end
    end
    r.ImGui_SetNextItemWidth(ctx, content_width)
    local changed, new_jitter = r.ImGui_SliderDouble(ctx, "Jitter", state.random_walk_jitter, 0.0, 1.0)
    if changed then state.random_walk_jitter = new_jitter end
  elseif state.navigation_mode == 2 then
    local content_width = r.ImGui_GetContentRegionAvail(ctx)
    local button_size = (content_width - 16) / 3
    local draw_list = r.ImGui_GetWindowDrawList(ctx)

    for row = 0, 1 do
      for col = 0, 2 do
        local pattern_id = row * 3 + col
        if pattern_id < 6 then
          if col > 0 then
            r.ImGui_SameLine(ctx)
          end

          local cursor_x, cursor_y = r.ImGui_GetCursorScreenPos(ctx)
          local is_active = state.figures_mode == pattern_id

          if is_active then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x444444FF)
          end

          if r.ImGui_Button(ctx, "##pattern" .. pattern_id, button_size, button_size) then
            state.figures_mode = pattern_id
            state.figures_time = 0
            scheduleSave()
          end

          if is_active then
            r.ImGui_PopStyleColor(ctx)
          end

          drawPatternIcon(draw_list, cursor_x, cursor_y, button_size, pattern_id, is_active)

          if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, figures_modes[pattern_id + 1])
          end
        end
      end
    end

    r.ImGui_Dummy(ctx, 0, 4)

    r.ImGui_SetNextItemWidth(ctx, content_width)
    local changed, new_speed = r.ImGui_SliderDouble(ctx, "Speed", state.figures_speed, 0.01, 10.0, "%.2f Hz")
    if changed then
      state.figures_speed = new_speed
      scheduleSave()
    end

    r.ImGui_SetNextItemWidth(ctx, content_width)
    local changed, new_size = r.ImGui_SliderDouble(ctx, "Size", state.figures_size, 0.1, 1.0, "%.2f")
    if changed then
      state.figures_size = new_size
      scheduleSave()
    end
  end

  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SetNextItemWidth(ctx, content_width)
  local changed, new_range = r.ImGui_SliderDouble(ctx, "Range", state.gesture_range, 0.1, 1.0)
  if changed then state.gesture_range = new_range end
  r.ImGui_SetNextItemWidth(ctx, content_width)
  local changed, new_min = r.ImGui_SliderDouble(ctx, "Min", state.gesture_min, 0.0, 1.0)
  if changed then
    state.gesture_min = new_min
    if state.gesture_max < new_min then state.gesture_max = new_min end
    scheduleSave()
  end
  r.ImGui_SetNextItemWidth(ctx, content_width)
  local changed, new_max = r.ImGui_SliderDouble(ctx, "Max", state.gesture_max, 0.0, 1.0)
  if changed then
    state.gesture_max = new_max
    if state.gesture_min > new_max then state.gesture_min = new_max end
    scheduleSave()
  end

  r.ImGui_Dummy(ctx, 0, 0)

  if r.ImGui_Button(ctx, "Morph 1", (content_width - item_spacing_x) / 2) then
    captureToMorph(1)
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Morph 2", (content_width - item_spacing_x) / 2) then
    captureToMorph(2)
  end
  r.ImGui_SameLine(ctx)
  if state.morph_preset_a and state.morph_preset_b then
    r.ImGui_Text(ctx, "Ready")
  else
    r.ImGui_Text(ctx, "Set both")
  end
  r.ImGui_SetNextItemWidth(ctx, 128)
  local changed, new_amount = r.ImGui_SliderDouble(ctx, "Morph", state.morph_amount, 0.0, 1.0)
  if changed then
    state.morph_amount = new_amount
    morphBetweenPresets(state.morph_amount)
  end
  r.ImGui_Dummy(ctx, 0, 0)

  if r.ImGui_Button(ctx, "Auto JSFX", content_width) then
    if state.jsfx_automation_enabled then
      state.jsfx_automation_enabled = false
      state.jsfx_automation_index = -1
    else
      createAutomationJSFX()
    end
  end
  if state.jsfx_automation_enabled then
    r.ImGui_SameLine(ctx)
    r.ImGui_TextColored(ctx, 0x00FF00FF, "ON")
  else
    local found_idx = findAutomationJSFX()
    if found_idx >= 0 then
      state.jsfx_automation_enabled = true
      state.jsfx_automation_index = found_idx
      r.ImGui_SameLine(ctx)
      r.ImGui_TextColored(ctx, 0x00FF00FF, "Found")
    else
      r.ImGui_SameLine(ctx)
      r.ImGui_TextColored(ctx, 0xFF0000FF, "OFF")
    end
  end

  if r.ImGui_Button(ctx, "Show Env", content_width) and state.jsfx_automation_enabled and state.jsfx_automation_index >= 0 then
    r.TrackFX_Show(state.track, state.jsfx_automation_index, 3)
  end
end

function drawMode()
  local header_font = getStyleFont("header")

  if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, header_font, 0)
    r.ImGui_Text(ctx, "MODE")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end
  if r.ImGui_Button(ctx, state.pad_mode == 0 and "Single" or "Single", 128) then
    state.pad_mode = 0
    scheduleSave()
  end
  if r.ImGui_Button(ctx, state.pad_mode == 1 and "Granular" or "Granular", 128) then
    state.pad_mode = 1
    if not state.granular_grains or #state.granular_grains == 0 then
      initializeGranularGrid()
    end
    scheduleSave()
  end
  if state.pad_mode == 1 then
    r.ImGui_Dummy(ctx, 0, 0)
    local grid_sizes = { "2x2", "3x3", "4x4" }
    local grid_values = { 2, 3, 4 }
    local current_grid_idx = 1
    for i, val in ipairs(grid_values) do
      if val == state.granular_grid_size then
        current_grid_idx = i - 1
        break
      end
    end
    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_grid_idx = r.ImGui_Combo(ctx, "##gran", current_grid_idx,
      table.concat(grid_sizes, "\0") .. "\0")
    if changed then
      state.granular_grid_size = grid_values[new_grid_idx + 1]
      initializeGranularGrid()
    end
    if r.ImGui_Button(ctx, "Randomize", 128) then
      if not state.granular_grains or #state.granular_grains == 0 then
        initializeGranularGrid()
      else
        randomizeGranularGrid()
      end
    end
    r.ImGui_Dummy(ctx, 0, 0)
    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_name = r.ImGui_InputText(ctx, "##granset", state.granular_set_name)
    if changed then state.granular_set_name = new_name end
    if r.ImGui_Button(ctx, "Save", 62) then
      if state.granular_set_name and state.granular_set_name ~= "" then
        saveGranularSet(state.granular_set_name)
      end
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Load", 62) then
      if state.granular_set_name and state.granular_set_name ~= "" then
        loadGranularSet(state.granular_set_name)
      end
    end
    r.ImGui_Dummy(ctx, 0, 0)
    if r.ImGui_BeginChild(ctx, "GrainSetList", 128, 80) then
      for name, _ in pairs(state.granular_sets or {}) do
        r.ImGui_PushID(ctx, name)
        if r.ImGui_Button(ctx, name, 102, 22) then
          loadGranularSet(name)
          state.granular_set_name = name
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "X", 22, 22) then
          deleteGranularSet(name)
        end
        r.ImGui_PopID(ctx)
      end
      r.ImGui_EndChild(ctx)
    end
  end
end

function drawPadSection()
  local header_font = getStyleFont("header")

  if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, header_font, 0)
    r.ImGui_Text(ctx, "XY PAD")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end
  local pad_size = 298
  local draw_list = r.ImGui_GetWindowDrawList(ctx)
  local cursor_pos_x, cursor_pos_y = r.ImGui_GetCursorScreenPos(ctx)
  r.ImGui_InvisibleButton(ctx, "xy_pad", pad_size, pad_size)
  if r.ImGui_IsItemActive(ctx) then
    local mouse_x, mouse_y = r.ImGui_GetMousePos(ctx)
    local click_x = (mouse_x - cursor_pos_x) / pad_size
    local click_y = 1.0 - (mouse_y - cursor_pos_y) / pad_size
    if not state.gesture_active then
      state.gesture_active = true
      state.gesture_base_x = state.gesture_x
      state.gesture_base_y = state.gesture_y
      captureBaseValues()
      local cursor_screen_x = cursor_pos_x + state.gesture_x * pad_size
      local cursor_screen_y = cursor_pos_y + (1.0 - state.gesture_y) * pad_size
      local dx = mouse_x - cursor_screen_x
      local dy = mouse_y - cursor_screen_y
      local distance = math.sqrt(dx * dx + dy * dy)
      local dead_zone_radius = 30
      if distance <= dead_zone_radius then
        state.click_offset_x = state.gesture_x - click_x
        state.click_offset_y = state.gesture_y - click_y
      else
        state.click_offset_x = 0
        state.click_offset_y = 0
      end
    end
    click_x = click_x + state.click_offset_x
    click_y = click_y + state.click_offset_y
    click_x = math.max(0, math.min(1, click_x))
    click_y = math.max(0, math.min(1, click_y))
    if state.navigation_mode == 1 then
      state.random_walk_active = false
    elseif state.navigation_mode == 2 then
      state.figures_active = false
    end
    if state.navigation_mode == 1 or state.navigation_mode == 2 or state.smooth_speed == 0 then
      state.gesture_x = click_x
      state.gesture_y = click_y
      updateJSFXFromGesture()
      if state.pad_mode == 1 then
        if not state.granular_grains or #state.granular_grains == 0 then
          initializeGranularGrid()
        end
        applyGranularGesture(state.gesture_x, state.gesture_y)
      else
        applyGestureToSelection(state.gesture_x, state.gesture_y)
      end
    else
      state.target_gesture_x = click_x
      state.target_gesture_y = click_y
    end
  else
    if state.gesture_active then
      state.gesture_active = false
      state.click_offset_x = 0
      state.click_offset_y = 0
    end
  end
  r.ImGui_DrawList_AddRectFilled(draw_list, cursor_pos_x, cursor_pos_y, cursor_pos_x + pad_size,
    cursor_pos_y + pad_size,
    0x222222FF)
  r.ImGui_DrawList_AddRect(draw_list, cursor_pos_x, cursor_pos_y, cursor_pos_x + pad_size, cursor_pos_y + pad_size,
    0x666666FF)
  r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x + pad_size / 2, cursor_pos_y, cursor_pos_x + pad_size / 2,
    cursor_pos_y + pad_size, 0x444444FF)
  r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, cursor_pos_y + pad_size / 2, cursor_pos_x + pad_size,
    cursor_pos_y + pad_size / 2, 0x444444FF)
  if state.pad_mode == 1 and state.granular_grains and #state.granular_grains > 0 then
    local grid_size = state.granular_grid_size
    for i = 1, grid_size - 1 do
      local line_x = cursor_pos_x + (i / grid_size) * pad_size
      local line_y = cursor_pos_y + (i / grid_size) * pad_size
      r.ImGui_DrawList_AddLine(draw_list, line_x, cursor_pos_y, line_x, cursor_pos_y + pad_size, 0x444444AA)
      r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, line_y, cursor_pos_x + pad_size, line_y, 0x444444AA)
    end
    for _, grain in ipairs(state.granular_grains) do
      local grain_screen_x = cursor_pos_x + grain.x * pad_size
      local grain_screen_y = cursor_pos_y + (1.0 - grain.y) * pad_size
      local grain_radius = (pad_size / grid_size)
      r.ImGui_DrawList_AddCircle(draw_list, grain_screen_x, grain_screen_y, grain_radius, 0x66666644, 0, 1)
      r.ImGui_DrawList_AddCircleFilled(draw_list, grain_screen_x, grain_screen_y, 4, 0xFFFFFFFF)
    end
  elseif state.pad_mode == 1 then
    local grid_size = state.granular_grid_size
    for i = 1, grid_size - 1 do
      local line_x = cursor_pos_x + (i / grid_size) * pad_size
      local line_y = cursor_pos_y + (i / grid_size) * pad_size
      r.ImGui_DrawList_AddLine(draw_list, line_x, cursor_pos_y, line_x, cursor_pos_y + pad_size, 0x444444AA)
      r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, line_y, cursor_pos_x + pad_size, line_y, 0x444444AA)
    end
  end
  local dot_x = cursor_pos_x + state.gesture_x * pad_size
  local dot_y = cursor_pos_y + (1.0 - state.gesture_y) * pad_size
  r.ImGui_DrawList_AddCircleFilled(draw_list, dot_x, dot_y, 8, 0xFFFFFFFF)
  if state.navigation_mode == 0 and state.smooth_speed > 0 then
    local target_dot_x = cursor_pos_x + state.target_gesture_x * pad_size
    local target_dot_y = cursor_pos_y + (1.0 - state.target_gesture_y) * pad_size
    r.ImGui_DrawList_AddCircle(draw_list, target_dot_x, target_dot_y, 6, 0x888888FF, 0, 2)
  end
  local mono_font = getStyleFont("mono")
  if mono_font and r.ImGui_ValidatePtr(mono_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, mono_font, 0)
    r.ImGui_Text(ctx, string.format("Position: %.2f, %.2f", state.gesture_x, state.gesture_y))
    r.ImGui_PopFont(ctx)
  end
end

function drawRandomizer()
  local header_font = getStyleFont("header")
  local content_width = r.ImGui_GetContentRegionAvail(ctx)
  local button_width = content_width - item_spacing_x


  if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, header_font, 0)
    r.ImGui_Text(ctx, "RANDOMIZER")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end
  if r.ImGui_Button(ctx, "FX Order", content_width) then
    randomizeFXOrder()
  end
  if r.ImGui_Button(ctx, "Bypass", (content_width - item_spacing_x) / 2) then
    randomBypassFX()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, (content_width - item_spacing_x) / 2)
  local changed, new_bypass = r.ImGui_SliderDouble(ctx, "##bypass", state.random_bypass_percentage * 100, 0.0, 100.0,
    "%.0f%%")
  if changed then
    state.random_bypass_percentage = new_bypass / 100
    scheduleSave()
  end
  if r.ImGui_Button(ctx, "XY", (content_width - 2 * item_spacing_x) / 4) then
    globalRandomXYAssign()
  end
  r.ImGui_SameLine(ctx)
  local changed, exclusive = r.ImGui_Checkbox(ctx, "##exclusive", state.exclusive_xy)
  if changed then
    state.exclusive_xy = exclusive
    scheduleSave()
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "N", (content_width - item_spacing_x) / 2) then
    globalRandomInvert()
  end
  r.ImGui_Dummy(ctx, 0, 0)
  if r.ImGui_Button(ctx, "Ranges", content_width) then
    globalRandomRanges()
  end
  r.ImGui_SetNextItemWidth(ctx, (content_width - item_spacing_x) / 2)
  local changed, new_rmin = r.ImGui_SliderDouble(ctx, "##rngmin", state.range_min, 0.0, 1.0, "%.2f")
  if changed then
    state.range_min = new_rmin
    if state.range_max < new_rmin then state.range_max = new_rmin end
    scheduleSave()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, (content_width - item_spacing_x) / 2)
  local changed, new_rmax = r.ImGui_SliderDouble(ctx, "##rngmax", state.range_max, 0.0, 1.0, "%.2f")
  if changed then
    state.range_max = new_rmax
    if state.range_min > new_rmax then state.range_min = new_rmax end
    scheduleSave()
  end
  r.ImGui_Dummy(ctx, 0, 0)
  if r.ImGui_Button(ctx, "Bases", content_width) then
    randomizeAllBases()
  end

  r.ImGui_SetNextItemWidth(ctx, content_width)
  local changed, new_intensity = r.ImGui_SliderDouble(ctx, "##intensity", state.randomize_intensity, 0.0, 1.0, "%.2f")
  if changed then state.randomize_intensity = new_intensity end
  r.ImGui_SetNextItemWidth(ctx, (content_width - item_spacing_x) / 2)
  local changed, new_min = r.ImGui_SliderDouble(ctx, "##basemin", state.randomize_min, 0.0, 1.0, "%.2f")
  if changed then
    state.randomize_min = new_min
    if state.randomize_max < new_min then state.randomize_max = new_min end
    scheduleSave()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, (content_width - item_spacing_x) / 2)
  local changed, new_max = r.ImGui_SliderDouble(ctx, "##basemax", state.randomize_max, 0.0, 1.0, "%.2f")
  if changed then
    state.randomize_max = new_max
    if state.randomize_min > new_max then state.randomize_min = new_max end
    scheduleSave()
  end

  r.ImGui_Dummy(ctx, 0, 0)
  if r.ImGui_Button(ctx, "Random", content_width) then
    globalRandomSelect()
    saveTrackSelection()
  end

  r.ImGui_SetNextItemWidth(ctx, (content_width - item_spacing_x) / 2)
  local changed, new_min = r.ImGui_SliderInt(ctx, "##min", state.random_min, 1, 300)
  if changed then state.random_min = new_min end
  r.ImGui_SameLine(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, (content_width - item_spacing_x) / 2)
  local changed, new_max = r.ImGui_SliderInt(ctx, "##max", state.random_max, 1, 300)
  if changed then
    state.random_max = math.max(new_max, state.random_min)
  end
end

function drawPresets()
  local header_font = getStyleFont("header")
  local content_width = r.ImGui_GetContentRegionAvail(ctx)

  if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, header_font, 0)
    r.ImGui_Text(ctx, "PRESETS")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end

  local button_width = (content_width - item_spacing_x) / 2
  if r.ImGui_Button(ctx, "Save##presets", button_width) then
   if state.current_loaded_preset ~= "" then
    savePreset(state.current_loaded_preset)
   else
    local retval, preset_name = r.GetUserInputs("Save FX Chain Preset", 1, "Preset name:", "")
    if retval and preset_name ~= "" then
     savePreset(preset_name)
     state.current_loaded_preset = preset_name
    saveTrackSelection()
   end
  end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Save As##presets", button_width) then
  local retval, preset_name = r.GetUserInputs("Save FX Chain Preset As", 1, "Preset name:", state.current_loaded_preset)
  if retval and preset_name ~= "" then
  savePreset(preset_name)
  state.current_loaded_preset = preset_name
   saveTrackSelection()
   end
	end

  local preset_list = {}
  local preset_names = {}
  local current_index = -1
  local i = 0
  for name, _ in pairs(state.presets) do
    table.insert(preset_names, name)
  end
  table.sort(preset_names)
  for idx, name in ipairs(preset_names) do
    if name == state.current_loaded_preset then
      current_index = idx - 1
    end
  end

  r.ImGui_SetNextItemWidth(ctx, content_width)
  local preset_combo_str = table.concat(preset_names, "\0") .. "\0"
  if preset_combo_str == "\0" then preset_combo_str = " \0" end
  local changed, new_index = r.ImGui_Combo(ctx, "##presetlist", current_index, preset_combo_str)
  if changed and new_index >= 0 and preset_names[new_index + 1] then
  loadPreset(preset_names[new_index + 1])
  end

  local delete_button_width = (content_width - item_spacing_x) / 2
	if r.ImGui_Button(ctx, "Rename##preset", delete_button_width) then
		if state.current_loaded_preset ~= "" then
			local retval, new_name = r.GetUserInputs("Rename Preset", 1, "New name:", state.current_loaded_preset)
			if retval and new_name ~= "" and new_name ~= state.current_loaded_preset then
				renamePreset(state.current_loaded_preset, new_name)
				state.current_loaded_preset = new_name
				saveTrackSelection()
			end
		end
	end
	r.ImGui_SameLine(ctx)
	if r.ImGui_Button(ctx, "Delete##preset", delete_button_width) then
    if state.current_loaded_preset ~= "" then
      local result = r.ShowMessageBox("Delete preset '" .. state.current_loaded_preset .. "'?", "Delete Preset", 4)
      if result == 6 then
        deletePreset(state.current_loaded_preset)
        state.current_loaded_preset = ""
      end
    end
  end

  r.ImGui_Dummy(ctx, 0, 0)

  if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, header_font, 0)
    r.ImGui_Text(ctx, "SNAPSHOTS")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end

  r.ImGui_SetNextItemWidth(ctx, content_width)
  local changed, new_name = r.ImGui_InputText(ctx, "##snapname", state.snapshot_name)
  if changed then state.snapshot_name = new_name end

  if r.ImGui_Button(ctx, "Save##snapshots", content_width) then
    if state.snapshot_name and state.snapshot_name ~= "" then
      saveSnapshot(state.snapshot_name)
    end
  end

  r.ImGui_Dummy(ctx, 0, 0)

  if r.ImGui_BeginChild(ctx, "SnapshotListPresets", content_width, -1) then
    local fx_sig = getCurrentFXChainSignature()
    if fx_sig and state.snapshots[fx_sig] then
      for name, _ in pairs(state.snapshots[fx_sig]) do
        r.ImGui_PushID(ctx, name)
        local button_width = content_width - 54 - (2 * item_spacing_x)
        if r.ImGui_Button(ctx, name, button_width) then
          loadSnapshot(name)
          state.snapshot_name = name
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "R", 22) then
          local retval, new_name = r.GetUserInputs("Rename Snapshot", 1, "New name:", name)
          if retval and new_name ~= "" and new_name ~= name then
            if state.snapshots[fx_sig] and state.snapshots[fx_sig][name] then
              state.snapshots[fx_sig][new_name] = state.snapshots[fx_sig][name]
              state.snapshots[fx_sig][name] = nil
              scheduleSnapshotSave()
            end
          end
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "X", 22) then
          deleteSnapshot(name)
        end
        r.ImGui_PopID(ctx)
      end
    end
    r.ImGui_EndChild(ctx)
  end
end

function showAllFloatingFX()
  local target_track = state.track_locked and state.locked_track or state.track
  if not target_track or not r.ValidatePtr(target_track, "MediaTrack*") then return end

  local command_id = r.NamedCommandLookup("_S&M_WNTSHW3")
  if command_id > 0 then
    local current_track = r.GetSelectedTrack(0, 0)
    r.SetOnlyTrackSelected(target_track)
    r.Main_OnCommand(command_id, 0)
    if current_track and current_track ~= target_track then
      r.SetOnlyTrackSelected(current_track)
    end
  end
end

function closeAllFloatingFX()
  local target_track = state.track_locked and state.locked_track or state.track
  if not target_track or not r.ValidatePtr(target_track, "MediaTrack*") then return end

  local command_id = r.NamedCommandLookup("_S&M_WNCLS5")
  if command_id > 0 then
    local current_track = r.GetSelectedTrack(0, 0)
    r.SetOnlyTrackSelected(target_track)
    r.Main_OnCommand(command_id, 0)
    if current_track and current_track ~= target_track then
      r.SetOnlyTrackSelected(current_track)
    end
  end
end

function drawFXSection()
  local header_font = getStyleFont("header")

  if header_font and r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
    r.ImGui_PushFont(ctx, header_font, 0)
    local header_text = "FX SETTINGS"
    r.ImGui_Text(ctx, header_text)
    r.ImGui_PopFont(ctx)
    r.ImGui_SameLine(ctx)
    local selection_text = "| Selected: " .. state.selected_count
    if state.current_loaded_preset ~= "" then
      selection_text = selection_text .. " | " .. state.current_loaded_preset
    end
    r.ImGui_Text(ctx, selection_text)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end
  if r.ImGui_Button(ctx, state.show_filters_window and "Hide Filters" or "Show Filters") then
    state.show_filters_window = not state.show_filters_window
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Show All FX") then
    showAllFloatingFX()
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Close All FX") then
    closeAllFloatingFX()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Collapse All") then
    state.all_fx_collapsed = true
    for fx_id, _ in pairs(state.fx_data) do
      state.fx_collapsed[fx_id] = true
    end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Expand All") then
    state.all_fx_collapsed = false
    for fx_id, _ in pairs(state.fx_data) do
      state.fx_collapsed[fx_id] = false
    end
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "All") then
    for fx_id, fx_data in pairs(state.fx_data) do
      selectAllParams(fx_data.params, true)
    end
    saveTrackSelection()
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "All Cont") then
    for fx_id, fx_data in pairs(state.fx_data) do
      selectAllContinuousParams(fx_data.params, true)
    end
    saveTrackSelection()
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Clear") then
    for fx_id, fx_data in pairs(state.fx_data) do
      selectAllParams(fx_data.params, false)
    end
    saveTrackSelection()
  end
  r.ImGui_Dummy(ctx, 0, 0)
  local fx_count = 0
  for _ in pairs(state.fx_data) do fx_count = fx_count + 1 end
  if fx_count > 0 then
    if r.ImGui_BeginChild(ctx, "FXHorizontal", 0, 0, 0, r.ImGui_WindowFlags_HorizontalScrollbar()) then
      local fx_width = 350
      r.ImGui_SetCursorPosX(ctx, 0)
      for fx_id = 0, fx_count - 1 do
        if fx_id > 0 then
          r.ImGui_SameLine(ctx)
        end
        local fx_data = state.fx_data[fx_id]
        if fx_data then
          r.ImGui_BeginGroup(ctx)
          r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildBorderSize(), 1)
          local collapsed = state.fx_collapsed[fx_id] or false
          local child_width = collapsed and 28 or fx_width
          local child_height = collapsed and 320 or -1
          if r.ImGui_BeginChild(ctx, "FX" .. fx_id, child_width, child_height) then
            if collapsed then
              if r.ImGui_Button(ctx, "+", -1) then
                state.fx_collapsed[fx_id] = false
              end
              local enabled = fx_data.enabled
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ButtonTextAlign(), 0.5, 0.0)
              local fx_name_vertical = ""
              for i = 1, #fx_data.name do
                fx_name_vertical = fx_name_vertical .. fx_data.name:sub(i, i) .. "\n"
              end
              if r.ImGui_Button(ctx, fx_name_vertical, -1, 242) then
                local actual_fx_id = fx_data.actual_fx_id or fx_id
                r.TrackFX_Show(state.track, actual_fx_id, 3)
              end
              r.ImGui_PopStyleVar(ctx)
              if r.ImGui_Checkbox(ctx, "##enabled" .. fx_id, enabled) then
                local actual_fx_id = fx_data.actual_fx_id or fx_id
                r.TrackFX_SetEnabled(state.track, actual_fx_id, not enabled)
                fx_data.enabled = not enabled
              end
          else
            local content_width = r.ImGui_GetContentRegionAvail(ctx)
            local num_elements_line1 = 3
            local num_spacings_line1 = num_elements_line1 - 1
            local available_width_line1 = content_width - (num_spacings_line1 * item_spacing_x)
            local part_width_line1 = available_width_line1 / 15

            if r.ImGui_Button(ctx, "-", part_width_line1) then
              state.fx_collapsed[fx_id] = true
            end
            r.ImGui_SameLine(ctx, 0, item_spacing_x)
            if r.ImGui_Button(ctx, fx_data.name, 13 * part_width_line1) then
              local actual_fx_id = fx_data.actual_fx_id or fx_id
              local is_visible = r.TrackFX_GetOpen(state.track, actual_fx_id)
              r.TrackFX_Show(state.track, actual_fx_id, is_visible and 2 or 3)
            end
            r.ImGui_SameLine(ctx, 0, item_spacing_x)
            local enabled = fx_data.enabled
            if r.ImGui_Checkbox(ctx, "##enabled" .. fx_id, enabled) then
              local actual_fx_id = fx_data.actual_fx_id or fx_id
              r.TrackFX_SetEnabled(state.track, actual_fx_id, not enabled)
              fx_data.enabled = not enabled
            end
            local num_items = 5
            local item_width = (content_width - (item_spacing_x * (num_items - 1))) / num_items
            if r.ImGui_Button(ctx, "All##" .. fx_id, item_width) then
                selectAllParams(fx_data.params, true)
                saveTrackSelection()
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "Cont##" .. fx_id, item_width) then
                selectAllContinuousParams(fx_data.params, true)
                saveTrackSelection()
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "None##" .. fx_id, item_width) then
                selectAllParams(fx_data.params, false)
                saveTrackSelection()
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "Rnd##" .. fx_id, item_width) then
                randomSelectParams(fx_data.params, fx_id)
                saveTrackSelection()
              end
              r.ImGui_SameLine(ctx)
              r.ImGui_SetNextItemWidth(ctx, item_width)
              local fx_key = getFXKey(fx_id)
              local current_max = (fx_key and state.fx_random_max[fx_key]) or 3
              local changed, new_max = r.ImGui_SliderInt(ctx, "##max" .. fx_id, current_max, 1, 10)
              if changed and fx_key then
              state.fx_random_max[fx_key] = new_max
               saveTrackSelection()
            end
              local num_items = 3
              local item_width = (content_width - (item_spacing_x * (num_items - 1))) / num_items
              if r.ImGui_Button(ctx, "RandXY##" .. fx_id, item_width) then
                randomizeXYAssign(fx_data.params, fx_id)
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "RandRng##" .. fx_id, item_width) then
                randomizeRanges(fx_data.params, fx_id)
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "RndBase##" .. fx_id, item_width) then
                randomizeBaseValues(fx_data.params, fx_id)
              end
              r.ImGui_Dummy(ctx, 0, 0)
              local table_flags = r.ImGui_TableFlags_SizingStretchProp()
              if r.ImGui_BeginTable(ctx, "params" .. fx_id, 6, table_flags) then
                r.ImGui_TableSetupColumn(ctx, "Name", 0, 4.0)
                r.ImGui_TableSetupColumn(ctx, "N", 0, 1.0)
                r.ImGui_TableSetupColumn(ctx, "X", 0, 1.0)
                r.ImGui_TableSetupColumn(ctx, "Y", 0, 1.0)
                r.ImGui_TableSetupColumn(ctx, "Range", 0, 2.0)
                r.ImGui_TableSetupColumn(ctx, "Base", 0, 2.0)
                for param_id, param_data in pairs(fx_data.params) do
                  r.ImGui_PushID(ctx, fx_id * 10000 + param_id)
                  r.ImGui_TableNextRow(ctx)
                  r.ImGui_TableNextColumn(ctx)
                  local param_name = param_data.name
                  if #param_name > 14 then
                    param_name = param_name:sub(1, 11) .. "..."
                  end
                  local changed, selected = r.ImGui_Checkbox(ctx,
                    param_name .. "##" .. fx_id .. "_" .. param_id,
                    param_data.selected)
                  if changed then
                    param_data.selected = selected
                    updateSelectedCount()
                    if selected then
                      param_data.base_value = param_data.current_value
                    end
                    saveTrackSelection()
                  end
                  if r.ImGui_IsItemHovered(ctx) then
                    r.ImGui_SetTooltip(ctx, param_data.name)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  local param_invert = getParamInvert(fx_id, param_id)
                  if r.ImGui_Button(ctx, param_invert and "N" or "P" .. "##n" .. fx_id .. "_" .. param_id, -1) then
                    setParamInvert(fx_id, param_id, not param_invert)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  local x_assign, y_assign = getParamXYAssign(fx_id, param_id)
                  local param_invert = getParamInvert(fx_id, param_id)
                  if r.ImGui_Button(ctx, x_assign and "X" or "-" .. "##x" .. fx_id .. "_" .. param_id, -1) then
                    setParamXYAssign(fx_id, param_id, "x", not x_assign)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  if r.ImGui_Button(ctx, y_assign and "Y" or "-" .. "##y" .. fx_id .. "_" .. param_id, -1) then
                    setParamXYAssign(fx_id, param_id, "y", not y_assign)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  r.ImGui_SetNextItemWidth(ctx, -1)
                  local range = getParamRange(fx_id, param_id)
                  local changed, new_range = r.ImGui_SliderDouble(ctx,
                    "##r" .. fx_id .. "_" .. param_id, range, 0.1, 1.0,
                    "%.1f")
                  if changed then
                    setParamRange(fx_id, param_id, new_range)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  r.ImGui_SetNextItemWidth(ctx, -1)
                  local format_str = "%.2f"
                  local display_value = param_data.base_value
                  if param_data.step_count and param_data.step_count == 2 then
                    format_str = param_data.base_value > 0.5 and "ON" or "OFF"
                    display_value = param_data.base_value > 0.5 and 1.0 or 0.0
                  elseif param_data.step_count and param_data.step_count > 2 and param_data.step_count <= 5 then
                    local step_index = math.floor(param_data.base_value * (param_data.step_count - 1) +
                    0.5)
                    format_str = tostring(step_index + 1) .. "/" .. param_data.step_count
                  end
                  local changed, new_base = r.ImGui_SliderDouble(ctx, "##b" .. fx_id .. "_" .. param_id,
                    param_data.base_value, 0.0, 1.0, format_str)
                  if changed then
                    if param_data.step_count and param_data.step_count > 0 then
                      new_base = snapToDiscreteValue(new_base, param_data.step_count)
                    end
                    updateParamBaseValue(fx_id, param_id, new_base)
                  end
                  if r.ImGui_IsItemHovered(ctx) then
                    local xy_text = ""
                    if x_assign and y_assign then
                      xy_text = " [XY]"
                    elseif x_assign then
                      xy_text = " [X]"
                    elseif y_assign then
                      xy_text = " [Y]"
                    end
                    local invert_text = param_invert and " [INVERTED]" or ""
                    r.ImGui_SetTooltip(ctx,
                      param_data.name ..
                      ": " ..
                      string.format("%.3f (Base: %.3f, Range: %.1f)", param_data.current_value,
                        param_data.base_value,
                        range) .. xy_text .. invert_text)
                  end
                  r.ImGui_PopID(ctx)
                end
                r.ImGui_EndTable(ctx)
              end
            end
            r.ImGui_EndChild(ctx)
          end
          r.ImGui_PopStyleVar(ctx)
          r.ImGui_EndGroup(ctx)
        end
      end
      r.ImGui_EndChild(ctx)
    end
  else
    r.ImGui_Text(ctx, "No FX found")
  end
end

function drawResetButton()
  local window_pos_x, window_pos_y = r.ImGui_GetWindowPos(ctx)
  local child_pos_x, child_pos_y = r.ImGui_GetCursorPos(ctx)
  r.ImGui_SetCursorPos(ctx, child_pos_x, child_pos_y)
  if r.ImGui_Button(ctx, "Reset", 80) then
    state.gesture_x = 0.5
    state.gesture_y = 0.5
    updateJSFXFromGesture()
    captureBaseValues()
    if state.pad_mode == 1 then
      applyGranularGesture(state.gesture_x, state.gesture_y)
    else
      applyGestureToSelection(state.gesture_x, state.gesture_y)
    end
  end
end

function drawHorizontalLayout()
  if r.ImGui_BeginChild(ctx, "Navigation", 160, 0) then
    drawNavigation()
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_BeginChild(ctx, "Mode", 128, 0) then
    drawMode()
    drawResetButton()
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_BeginChild(ctx, "PadXY", 298, 0) then
    drawPadSection()
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_BeginChild(ctx, "Randomizer", 128, 0) then
    drawRandomizer()
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_BeginChild(ctx, "Presets", 180, 0) then
    drawPresets()
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SameLine(ctx)
  if r.ImGui_BeginChild(ctx, "FX", 0, 0) then
    drawFXSection()
    r.ImGui_EndChild(ctx)
  end
end

function drawInterface()
  if style_loader then
    local success, colors, vars = style_loader.applyToContext(ctx)
    if success then pushed_colors, pushed_vars = colors, vars end
  end

  r.ImGui_SetNextWindowSize(ctx, 1400, 800, r.ImGui_Cond_FirstUseEver())
  local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
  local visible, open = r.ImGui_Begin(ctx, 'FX Constellation', true, window_flags)
  if visible then
    if style_loader and style_loader.PushFont(ctx, "header") then
      local lock_icon = state.track_locked and "[L] " or ""
      r.ImGui_Text(ctx, lock_icon .. "FX Constellation")
      style_loader.PopFont(ctx)
    else
      local lock_icon = state.track_locked and "[L] " or ""
      r.ImGui_Text(ctx, lock_icon .. "FX Constellation")
    end

    r.ImGui_SameLine(ctx)
    local lock_button_size = header_font_size + 6
    if r.ImGui_Button(ctx, state.track_locked and "U" or "L", lock_button_size, lock_button_size) then
      if state.track_locked then
        state.track_locked = false
        state.locked_track = nil
      else
        state.track_locked = true
        state.locked_track = state.track
      end
    end
    if r.ImGui_IsItemHovered(ctx) then
      r.ImGui_SetTooltip(ctx, state.track_locked and "Unlock track" or "Lock to current track")
    end

    r.ImGui_SameLine(ctx)
    local close_button_size = header_font_size + 6
    local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
    r.ImGui_SetCursorPosX(ctx, close_x)
    if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
      open = false
    end

    if style_loader and style_loader.PushFont(ctx, "main") then
      r.ImGui_Separator(ctx)

      checkSave()
      updateGestureMotion()

      if not state.track_locked then
        local new_track = r.GetSelectedTrack(0, 0)
        if new_track ~= state.track then
          if state.track then saveTrackSelection() end
          state.track = new_track
          if state.track then
            scanTrackFX()
            state.jsfx_automation_index = findAutomationJSFX()
            state.jsfx_automation_enabled = state.jsfx_automation_index >= 0
          end
        end
      else
        if state.locked_track and r.ValidatePtr(state.locked_track, "MediaTrack*") then
          state.track = state.locked_track
        else
          state.track_locked = false
          state.locked_track = nil
        end
      end
      if isTrackValid() then
        checkForFXChanges()
      end
      if not isTrackValid() then
        r.ImGui_Text(ctx, "No track selected")
        if style_loader and style_loader.PopFont then style_loader.PopFont(ctx) end
        r.ImGui_End(ctx)
        if style_loader then style_loader.clearStyles(ctx, pushed_colors, pushed_vars) end
        return open
      end

      drawHorizontalLayout()

      style_loader.PopFont(ctx)
    end
    r.ImGui_End(ctx)
  end
  if style_loader then style_loader.clearStyles(ctx, pushed_colors, pushed_vars) end
  drawFiltersWindow()
  return open
end

loadSettings()
local function loop()
  local open = drawInterface()
  if open then r.defer(loop) else saveSettings() end
end
r.atexit(saveSettings)
loop()