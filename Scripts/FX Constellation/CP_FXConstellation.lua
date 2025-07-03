-- @description FXConstellation
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper
local sl = nil
local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp) then
  local lf = dofile(sp)
  if lf then sl = lf() end
end
local ctx = r.ImGui_CreateContext('FX Constellation')

if sl then
  sl.applyFontsToContext(ctx)
end

local filters_ctx = nil
local presets_ctx = nil
local pc, pv = 0, 0
local filters_pc, filters_pv = 0, 0
local presets_pc, presets_pv = 0, 0

function getStyleFont(font_name, context)
  if sl then
    return sl.getFont(context or ctx, font_name)
  end
  return nil
end

local save_flags = {
  settings = false,
  track_selections = false,
  presets = false,
  granular_sets = false
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
  gesture_range = 0.5,
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
  figures_active = false
}

local navigation_modes = { "Manual", "Random Walk", "Figures" }
local figures_modes = { "Circle", "Z" }

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
                weighted_param_values[fx_id][param_id] = weighted_param_values[fx_id][param_id] + (value * influence)
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
          r.TrackFX_SetParam(state.track, fx_id, param_id, final_value)
          param_data.current_value = final_value
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

function calculateFiguresPosition(time)
  local angle = time * state.figures_speed * 2 * math.pi
  local size = state.figures_size

  if state.figures_mode == 0 then
    local x = 0.5 + (size * 0.5) * math.cos(angle)
    local y = 0.5 + (size * 0.5) * math.sin(angle)
    return x, y
  elseif state.figures_mode == 1 then
    local progress = (angle / (2 * math.pi)) % 1
    local x, y
    if progress < 0.5 then
      local t = progress * 2
      x = 0.5 - (size * 0.5) + t * size
      y = 0.5 + (size * 0.5) - t * size
    else
      local t = (progress - 0.5) * 2
      x = 0.5 + (size * 0.5) - t * size
      y = 0.5 - (size * 0.5) + t * size
    end
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
        local max_distance = state.max_gesture_speed * (current_time - (state.last_smooth_update or current_time))
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
    if save_flags.settings or save_flags.track_selections or save_flags.presets or save_flags.granular_sets then
      saveSettings()
      save_flags.settings = false
      save_flags.track_selections = false
      save_flags.presets = false
      save_flags.granular_sets = false
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
      jsfx_automation_enabled = state.jsfx_automation_enabled
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
    fx_rand_max[fx_id] = state.fx_random_max[fx_id] or 3
    for param_id, param_data in pairs(fx_data.params) do
      local key = fx_data.full_name .. "||" .. param_data.name
      if param_data.selected then
        selection[key] = true
      end
      ranges[key] = state.param_ranges[fx_id .. "_" .. param_id .. "_range"] or 1.0
      invert_assign[key] = state.param_invert[fx_id .. "_" .. param_id .. "_invert"] or false
      xy_assign[key] = {
        x = state.param_xy_assign[fx_id .. "_" .. param_id .. "_x"] ~= false,
        y = state.param_xy_assign[fx_id .. "_" .. param_id .. "_y"] ~= false
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
    gesture_base_y = state.gesture_base_y
  }
  scheduleTrackSave()
end

function loadTrackSelection()
  local guid = getTrackGUID()
  if not guid then return end
  local track_data = state.track_selections[guid]
  if not track_data then
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
  for fx_id, fx_data in pairs(state.fx_data) do
    if fx_rand_max[fx_id] then
      state.fx_random_max[fx_id] = fx_rand_max[fx_id]
    end
    for param_id, param_data in pairs(fx_data.params) do
      local key = fx_data.full_name .. "||" .. param_data.name
      param_data.selected = selection[key] or false
      param_data.base_value = base_values[key] or param_data.current_value
      state.param_ranges[fx_id .. "_" .. param_id .. "_range"] = ranges[key] or 1.0
      state.param_invert[fx_id .. "_" .. param_id .. "_invert"] = invert_assign[key] or false
      local xy = xy_assign[key] or { x = true, y = true }
      state.param_xy_assign[fx_id .. "_" .. param_id .. "_x"] = xy.x
      state.param_xy_assign[fx_id .. "_" .. param_id .. "_y"] = xy.y
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
      if state.fx_random_max[visible_fx_id] == nil then
        state.fx_random_max[visible_fx_id] = 3
      end
      for param = 0, param_count - 1 do
        local _, param_name = r.TrackFX_GetParamName(state.track, fx, param, "")
        if not shouldFilterParam(param_name) then
          local value = r.TrackFX_GetParam(state.track, fx, param)
          state.fx_data[visible_fx_id].params[param] = {
            name = param_name,
            current_value = value,
            base_value = value,
            min_val = 0,
            max_val = 1,
            selected = false,
            fx_id = visible_fx_id,
            param_id = param,
            actual_fx_id = fx
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

function selectAllParams(params, selected)
  for _, param in pairs(params) do
    param.selected = selected
  end
  updateSelectedCount()
  saveTrackSelection()
end

function getParamRange(fx_id, param_id)
  local key = fx_id .. "_" .. param_id .. "_range"
  return state.param_ranges[key] or 1.0
end

function setParamRange(fx_id, param_id, range)
  local key = fx_id .. "_" .. param_id .. "_range"
  state.param_ranges[key] = range
  saveTrackSelection()
end

function getParamInvert(fx_id, param_id)
  local key = fx_id .. "_" .. param_id .. "_invert"
  return state.param_invert[key] or false
end

function setParamInvert(fx_id, param_id, invert)
  local key = fx_id .. "_" .. param_id .. "_invert"
  state.param_invert[key] = invert
  saveTrackSelection()
end

function getParamXYAssign(fx_id, param_id)
  local x_key = fx_id .. "_" .. param_id .. "_x"
  local y_key = fx_id .. "_" .. param_id .. "_y"
  return state.param_xy_assign[x_key] ~= false, state.param_xy_assign[y_key] ~= false
end

function setParamXYAssign(fx_id, param_id, axis, value)
  local key = fx_id .. "_" .. param_id .. "_" .. axis
  state.param_xy_assign[key] = value
  if state.exclusive_xy and value then
    local other_axis = axis == "x" and "y" or "x"
    local other_key = fx_id .. "_" .. param_id .. "_" .. other_axis
    state.param_xy_assign[other_key] = false
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
  local max_count = state.fx_random_max[fx_id] or 3
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
      state.param_base_values[fx_id .. "_" .. param_id] = new_base
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
        state.param_base_values[fx_id .. "_" .. param_id] = new_base
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
        state.param_base_values[fx_id .. "_" .. param_id] = param_data.current_value
      end
    end
  end
end

function updateParamBaseValue(fx_id, param_id, new_value)
  if not isTrackValid() then return end
  local param_data = state.fx_data[fx_id].params[param_id]
  if param_data then
    param_data.base_value = new_value
    state.param_base_values[fx_id .. "_" .. param_id] = new_value
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
        local base_key = fx_id .. "_" .. param_id
        local base_value = state.param_base_values[base_key] or param_data.base_value
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
        local actual_fx_id = fx_data.actual_fx_id or fx_id
        r.TrackFX_SetParam(state.track, actual_fx_id, param_id, new_value)
        param_data.current_value = new_value
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

    complete_state.fx_chain[fx_id] = {
      name = fx_name,
      enabled = enabled,
      preset = retval and preset or "",
      params = {}
    }

    if state.fx_data[fx_id] then
      for param_id, param_data in pairs(state.fx_data[fx_id].params) do
        complete_state.fx_chain[fx_id].params[param_id] = {
          name = param_data.name,
          current_value = param_data.current_value,
          base_value = param_data.base_value,
          selected = param_data.selected,
          range = getParamRange(fx_id, param_id),
          x_assign = state.param_xy_assign[fx_id .. "_" .. param_id .. "_x"] ~= false,
          y_assign = state.param_xy_assign[fx_id .. "_" .. param_id .. "_y"] ~= false,
          invert = getParamInvert(fx_id, param_id)
        }
      end
    end
  end

  return complete_state
end

function getFXChainSignature()
  if not isTrackValid() then return "" end
  local signature = ""
  local fx_count = r.TrackFX_GetCount(state.track)
  for fx_id = 0, fx_count - 1 do
    local _, fx_name = r.TrackFX_GetFXName(state.track, fx_id, "")
    if not fx_name:find("FX Constellation Bridge") then
      signature = signature .. fx_name .. ";"
    end
  end
  return signature
end

function findMatchingFXChain(target_signature)
  for chain_name, chain_data in pairs(state.presets) do
    if chain_data.is_fx_chain and chain_data.fx_signature == target_signature then
      return chain_name
    end
  end
  return nil
end

function savePreset(name)
  if name == "" then return end

  if state.save_fx_chain then
    local preset_data = captureCompleteState()
    preset_data.is_fx_chain = true
    preset_data.fx_signature = getFXChainSignature()
    preset_data.variations = {}
    state.presets[name] = preset_data
  else
    local current_signature = getFXChainSignature()
    local matching_chain = findMatchingFXChain(current_signature)

    if matching_chain then
      if not state.presets[matching_chain].variations then
        state.presets[matching_chain].variations = {}
      end
      state.presets[matching_chain].variations[name] = captureCompleteState()
      state.presets[matching_chain].variations[name].is_fx_chain = false
    else
      local chain_preset = captureCompleteState()
      chain_preset.is_fx_chain = true
      chain_preset.fx_signature = current_signature
      chain_preset.variations = {}
      chain_preset.variations[name] = captureCompleteState()
      chain_preset.variations[name].is_fx_chain = false
      state.presets[name .. "_Chain"] = chain_preset
    end
  end
  schedulePresetSave()
end

function loadPreset(name, variation_name)
  if not isTrackValid() then return end
  local preset

  if variation_name then
    preset = state.presets[name] and state.presets[name].variations and state.presets[name].variations[variation_name]
    local current_signature = getFXChainSignature()
    local target_signature = state.presets[name] and state.presets[name].fx_signature
    if current_signature ~= target_signature then
      loadPreset(name)
    end
  else
    preset = state.presets[name]
  end

  if not preset then return end

  r.Undo_BeginBlock()

  if preset.is_fx_chain then
    local fx_count = r.TrackFX_GetCount(state.track)
    for fx_id = fx_count - 1, 0, -1 do
      local _, fx_name = r.TrackFX_GetFXName(state.track, fx_id, "")
      if not fx_name:find("FX Constellation Bridge") then
        r.TrackFX_Delete(state.track, fx_id)
      end
    end

    for fx_id, fx_preset in pairs(preset.fx_chain or {}) do
      if not fx_preset.name:find("FX Constellation Bridge") then
        local new_fx_id = r.TrackFX_AddByName(state.track, fx_preset.name, false, -1)
        if new_fx_id >= 0 then
          r.TrackFX_SetEnabled(state.track, new_fx_id, fx_preset.enabled)
          if fx_preset.preset and fx_preset.preset ~= "" then
            r.TrackFX_SetPreset(state.track, new_fx_id, fx_preset.preset)
          end
        end
      end
    end
    scanTrackFX()
    for fx_id, fx_data in pairs(state.fx_data) do
      state.fx_collapsed[fx_id] = true
    end
  end

  state.gesture_x = preset.gesture_x or 0.5
  state.gesture_y = preset.gesture_y or 0.5
  updateJSFXFromGesture()
  state.gesture_base_x = preset.gesture_base_x or 0.5
  state.gesture_base_y = preset.gesture_base_y or 0.5

  for fx_id, fx_preset in pairs(preset.fx_chain or {}) do
    if state.fx_data[fx_id] and state.fx_data[fx_id].full_name == fx_preset.name then
      if not preset.is_fx_chain then
        local actual_fx_id = state.fx_data[fx_id].actual_fx_id or fx_id
        r.TrackFX_SetEnabled(state.track, actual_fx_id, fx_preset.enabled)
        state.fx_data[fx_id].enabled = fx_preset.enabled
      end

      for param_id, param_preset in pairs(fx_preset.params or {}) do
        if state.fx_data[fx_id].params[param_id] and
            state.fx_data[fx_id].params[param_id].name == param_preset.name then
          local actual_fx_id = state.fx_data[fx_id].actual_fx_id or fx_id
          r.TrackFX_SetParam(state.track, actual_fx_id, param_id, param_preset.current_value)
          state.fx_data[fx_id].params[param_id].current_value = param_preset.current_value
          state.fx_data[fx_id].params[param_id].base_value = param_preset.base_value
          state.fx_data[fx_id].params[param_id].selected = param_preset.selected

          setParamRange(fx_id, param_id, param_preset.range or 1.0)
          setParamXYAssign(fx_id, param_id, "x", param_preset.x_assign)
          setParamXYAssign(fx_id, param_id, "y", param_preset.y_assign)
          setParamInvert(fx_id, param_id, param_preset.invert or false)
        end
      end
    end
  end

  r.Undo_EndBlock("Load FX Constellation preset: " .. name .. (variation_name and ("/" .. variation_name) or ""), -1)
  updateSelectedCount()
  captureBaseValues()
end

function deletePreset(name)
  if state.presets[name] then
    state.presets[name] = nil
    if state.selected_preset == name then
      state.selected_preset = ""
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

function getStyleSpacing()
  if sl then
    local saved = r.GetExtState("CP_ImGuiStyles", "styles")
    if saved ~= "" then
      local success, styles = pcall(function() return load("return " .. saved)() end)
      if success and styles and styles.spacing then
        return styles.spacing.item_spacing_x or 8
      end
    end
  end
  return 8
end

function drawFiltersWindow()
  if not state.show_filters_window then return end
  if not filters_ctx or not r.ImGui_ValidatePtr(filters_ctx, "ImGui_Context*") then
    filters_ctx = r.ImGui_CreateContext('FX Constellation Filters')
    if sl then
      sl.applyFontsToContext(filters_ctx)
    end
  end
  if sl then
    local success, colors, vars = sl.applyToContext(filters_ctx)
    if success then filters_pc, filters_pv = colors, vars end
  end
  r.ImGui_SetNextWindowSize(filters_ctx, 400, 300, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(filters_ctx, 'Filter Keywords', true)
  if visible then
    local main_font = getStyleFont("main", filters_ctx)
    local header_font = getStyleFont("header", filters_ctx)

    if main_font then
      r.ImGui_PushFont(filters_ctx, main_font)
    end

    if header_font then
      r.ImGui_PushFont(filters_ctx, header_font)
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

    if main_font then
      r.ImGui_PopFont(filters_ctx)
    end
    r.ImGui_End(filters_ctx)
  end
  if not open then
    state.show_filters_window = false
  end
  if sl then sl.clearStyles(filters_ctx, filters_pc, filters_pv) end
end

function drawPresetsWindow()
  if not state.show_presets_window then return end
  if not presets_ctx or not r.ImGui_ValidatePtr(presets_ctx, "ImGui_Context*") then
    presets_ctx = r.ImGui_CreateContext('FX Constellation Presets')
    if sl then
      sl.applyFontsToContext(presets_ctx)
    end
  end
  if sl then
    local success, colors, vars = sl.applyToContext(presets_ctx)
    if success then presets_pc, presets_pv = colors, vars end
  end

  local preset_count = 0
  local variation_count = 0
  for name, preset_data in pairs(state.presets) do
    if preset_data.is_fx_chain then
      preset_count = preset_count + 1
      if preset_data.variations then
        for _ in pairs(preset_data.variations) do
          variation_count = variation_count + 1
        end
      end
    else
      preset_count = preset_count + 1
    end
  end

  if state.save_fx_chain then
    state.preset_name = "Chain" .. (preset_count + 1)
  else
    state.preset_name = "Variation" .. (variation_count + 1)
  end

  r.ImGui_SetNextWindowSize(presets_ctx, 400, 500, r.ImGui_Cond_FirstUseEver())
  local flags = r.ImGui_WindowFlags_NoTitleBar()
  local visible, open = r.ImGui_Begin(presets_ctx, '##PresetsWindow', true, flags)

  if visible then
    local main_font = getStyleFont("main", presets_ctx)
    local header_font = getStyleFont("header", presets_ctx)

    if main_font then
      r.ImGui_PushFont(presets_ctx, main_font)
    end

    local window_width = r.ImGui_GetWindowWidth(presets_ctx)

    if header_font then
      r.ImGui_PushFont(presets_ctx, header_font)
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

    local changed, save_fx_chain = r.ImGui_Checkbox(presets_ctx, "Save FX Chain", state.save_fx_chain)
    if changed then state.save_fx_chain = save_fx_chain end

    r.ImGui_SetNextItemWidth(presets_ctx, window_width - 80)
    local changed, new_name = r.ImGui_InputText(presets_ctx, "##preset_name", state.preset_name)
    if changed then state.preset_name = new_name end
    r.ImGui_SameLine(presets_ctx)
    if r.ImGui_Button(presets_ctx, "Save", 60) then
      if state.preset_name and state.preset_name ~= "" then
        savePreset(state.preset_name)
      end
    end

    r.ImGui_Dummy(presets_ctx, 0, 4)

    if r.ImGui_BeginChild(presets_ctx, "PresetsList", 0, -1) then
      for name, preset_data in pairs(state.presets) do
        if preset_data.is_fx_chain then
          r.ImGui_PushID(presets_ctx, name)

          local tree_flags = r.ImGui_TreeNodeFlags_OpenOnArrow()
          local display_name = name:gsub("[^%w%s_%-]", "") .. " (FX Chain)"
          if r.ImGui_TreeNodeEx(presets_ctx, display_name, tree_flags) then
            r.ImGui_SameLine(presets_ctx, window_width - 80)
            if r.ImGui_Button(presets_ctx, "Load", 25, 20) then
              loadPreset(name)
            end
            r.ImGui_SameLine(presets_ctx)
            if r.ImGui_Button(presets_ctx, "X", 25, 20) then
              deletePreset(name)
            end

            if preset_data.variations then
              for var_name, _ in pairs(preset_data.variations) do
                r.ImGui_PushID(presets_ctx, var_name)
                r.ImGui_Indent(presets_ctx)

                local clean_var_name = var_name:gsub("[^%w%s_%-]", "")
                r.ImGui_Text(presets_ctx, clean_var_name)
                r.ImGui_SameLine(presets_ctx, window_width - 80)
                if r.ImGui_Button(presets_ctx, "Load", 25, 20) then
                  loadPreset(name, var_name)
                end
                r.ImGui_SameLine(presets_ctx)
                if r.ImGui_Button(presets_ctx, "X", 25, 20) then
                  if preset_data.variations then
                    preset_data.variations[var_name] = nil
                  end
                end

                r.ImGui_Unindent(presets_ctx)
                r.ImGui_PopID(presets_ctx)
              end
            end

            r.ImGui_TreePop(presets_ctx)
          else
            r.ImGui_SameLine(presets_ctx, window_width - 80)
            if r.ImGui_Button(presets_ctx, "Load", 25, 20) then
              loadPreset(name)
            end
            r.ImGui_SameLine(presets_ctx)
            if r.ImGui_Button(presets_ctx, "X", 25, 20) then
              deletePreset(name)
            end
          end

          r.ImGui_PopID(presets_ctx)
        else
          r.ImGui_PushID(presets_ctx, name)

          local btn_width = window_width - 80
          local clean_name = name:gsub("[^%w%s_%-]", "")
          if r.ImGui_Button(presets_ctx, clean_name, btn_width, 25) then
            loadPreset(name)
            state.selected_preset = name
          end

          r.ImGui_SameLine(presets_ctx)
          if r.ImGui_Button(presets_ctx, "R", 25, 25) then
            state.show_preset_rename = true
            state.rename_preset_name = name
            state.selected_preset = name
          end

          r.ImGui_SameLine(presets_ctx)
          if r.ImGui_Button(presets_ctx, "X", 25, 25) then
            deletePreset(name)
          end

          r.ImGui_PopID(presets_ctx)
        end
      end
      r.ImGui_EndChild(presets_ctx)
    end

    if state.show_preset_rename then
      r.ImGui_OpenPopup(presets_ctx, "Rename Preset")
    end

    if r.ImGui_BeginPopupModal(presets_ctx, "Rename Preset", nil, r.ImGui_WindowFlags_AlwaysAutoResize()) then
      local changed, new_name = r.ImGui_InputText(presets_ctx, "New Name", state.rename_preset_name)
      if changed then state.rename_preset_name = new_name end

      if r.ImGui_Button(presets_ctx, "OK", 120, 0) then
        renamePreset(state.selected_preset, state.rename_preset_name)
        state.show_preset_rename = false
        r.ImGui_CloseCurrentPopup(presets_ctx)
      end
      r.ImGui_SameLine(presets_ctx)
      if r.ImGui_Button(presets_ctx, "Cancel", 120, 0) then
        state.show_preset_rename = false
        r.ImGui_CloseCurrentPopup(presets_ctx)
      end
      r.ImGui_EndPopup(presets_ctx)
    end

    if main_font then
      r.ImGui_PopFont(presets_ctx)
    end
    r.ImGui_End(presets_ctx)
  end

  if not open then
    state.show_presets_window = false
  end
  if sl then sl.clearStyles(presets_ctx, presets_pc, presets_pv) end
end

function drawNavigation()
  local header_font = getStyleFont("header")

  if header_font then
    r.ImGui_PushFont(ctx, header_font)
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
    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_smooth = r.ImGui_SliderDouble(ctx, "Smooth", state.smooth_speed, 0.0, 1.0, "%.2f")
    if changed then state.smooth_speed = new_smooth end
    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_max_speed = r.ImGui_SliderDouble(ctx, "Speed", state.max_gesture_speed, 0.1, 10.0, "%.1f")
    if changed then state.max_gesture_speed = new_max_speed end
  elseif state.navigation_mode == 1 then
    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_speed = r.ImGui_SliderDouble(ctx, "Speed", state.random_walk_speed, 0.1, 10.0, "%.1f Hz")
    if changed then
      state.random_walk_speed = new_speed
      if state.random_walk_active then
        state.random_walk_next_time = r.time_precise() + 1.0 / state.random_walk_speed
      end
    end
    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_jitter = r.ImGui_SliderDouble(ctx, "Jitter", state.random_walk_jitter, 0.0, 1.0)
    if changed then state.random_walk_jitter = new_jitter end
  elseif state.navigation_mode == 2 then
    r.ImGui_SetNextItemWidth(ctx, 128)
    local figures_items = table.concat(figures_modes, "\0") .. "\0"
    local changed, new_figures_mode = r.ImGui_Combo(ctx, "##figuresmode", state.figures_mode, figures_items)
    if changed then
      state.figures_mode = new_figures_mode
      state.figures_time = 0
      scheduleSave()
    end

    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_speed = r.ImGui_SliderDouble(ctx, "Speed", state.figures_speed, 0.01, 10.0, "%.2f Hz")
    if changed then
      state.figures_speed = new_speed
      scheduleSave()
    end

    r.ImGui_SetNextItemWidth(ctx, 128)
    local changed, new_size = r.ImGui_SliderDouble(ctx, "Size", state.figures_size, 0.1, 1.0, "%.2f")
    if changed then
      state.figures_size = new_size
      scheduleSave()
    end
  end

  r.ImGui_Dummy(ctx, 0, 0)
  r.ImGui_SetNextItemWidth(ctx, 128)
  local changed, new_range = r.ImGui_SliderDouble(ctx, "Range", state.gesture_range, 0.1, 1.0)
  if changed then state.gesture_range = new_range end
  r.ImGui_SetNextItemWidth(ctx, 128)
  local changed, new_min = r.ImGui_SliderDouble(ctx, "Min", state.gesture_min, 0.0, 1.0)
  if changed then
    state.gesture_min = new_min
    if state.gesture_max < new_min then state.gesture_max = new_min end
    scheduleSave()
  end
  r.ImGui_SetNextItemWidth(ctx, 128)
  local changed, new_max = r.ImGui_SliderDouble(ctx, "Max", state.gesture_max, 0.0, 1.0)
  if changed then
    state.gesture_max = new_max
    if state.gesture_min > new_max then state.gesture_min = new_max end
    scheduleSave()
  end

  r.ImGui_Dummy(ctx, 0, 0)

  if r.ImGui_Button(ctx, "Morph 1", 62) then
    captureToMorph(1)
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Morph 2", 62) then
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

  if r.ImGui_Button(ctx, "Auto JSFX", 128) then
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

  if r.ImGui_Button(ctx, "Show Env", 128) and state.jsfx_automation_enabled and state.jsfx_automation_index >= 0 then
    r.TrackFX_Show(state.track, state.jsfx_automation_index, 3)
  end
end

function drawMode()
  local header_font = getStyleFont("header")

  if header_font then
    r.ImGui_PushFont(ctx, header_font)
    r.ImGui_Text(ctx, "MODE")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end
  if r.ImGui_Button(ctx, state.pad_mode == 0 and "Single" or "Single", 128, 22) then
    state.pad_mode = 0
    scheduleSave()
  end
  if r.ImGui_Button(ctx, state.pad_mode == 1 and "Granular" or "Granular", 128, 22) then
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
    local changed, new_grid_idx = r.ImGui_Combo(ctx, "##gran", current_grid_idx, table.concat(grid_sizes, "\0") .. "\0")
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

  if header_font then
    r.ImGui_PushFont(ctx, header_font)
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
      captureBaseValues()
    end
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
    end
  end
  r.ImGui_DrawList_AddRectFilled(draw_list, cursor_pos_x, cursor_pos_y, cursor_pos_x + pad_size, cursor_pos_y + pad_size,
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
  if mono_font then
    r.ImGui_PushFont(ctx, mono_font)
    r.ImGui_Text(ctx, string.format("Position: %.2f, %.2f", state.gesture_x, state.gesture_y))
    r.ImGui_PopFont(ctx)
  end
end

function drawRandomizer()
  local header_font = getStyleFont("header")

  if header_font then
    r.ImGui_PushFont(ctx, header_font)
    r.ImGui_Text(ctx, "RANDOMIZER")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end
  if r.ImGui_Button(ctx, "FX Order", 128) then
    randomizeFXOrder()
  end
  if r.ImGui_Button(ctx, "Bypass", 62) then
    randomBypassFX()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 62)
  local changed, new_bypass = r.ImGui_SliderDouble(ctx, "##bypass", state.random_bypass_percentage * 100, 0.0, 100.0,
    "%.0f%%")
  if changed then
    state.random_bypass_percentage = new_bypass / 100
    scheduleSave()
  end
  if r.ImGui_Button(ctx, "XY", 36) then
    globalRandomXYAssign()
  end
  r.ImGui_SameLine(ctx)
  local changed, exclusive = r.ImGui_Checkbox(ctx, "##exclusive", state.exclusive_xy)
  if changed then
    state.exclusive_xy = exclusive
    scheduleSave()
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "N", 62) then
    globalRandomInvert()
  end
  r.ImGui_Dummy(ctx, 0, 0)
  if r.ImGui_Button(ctx, "Ranges", 128) then
    globalRandomRanges()
  end
  r.ImGui_SetNextItemWidth(ctx, 62)
  local changed, new_rmin = r.ImGui_SliderDouble(ctx, "##rngmin", state.range_min, 0.0, 1.0, "%.2f")
  if changed then
    state.range_min = new_rmin
    if state.range_max < new_rmin then state.range_max = new_rmin end
    scheduleSave()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 62)
  local changed, new_rmax = r.ImGui_SliderDouble(ctx, "##rngmax", state.range_max, 0.0, 1.0, "%.2f")
  if changed then
    state.range_max = new_rmax
    if state.range_min > new_rmax then state.range_min = new_rmax end
    scheduleSave()
  end
  r.ImGui_Dummy(ctx, 0, 0)
  if r.ImGui_Button(ctx, "Bases", 128) then
    randomizeAllBases()
  end

  r.ImGui_SetNextItemWidth(ctx, 128)
  local changed, new_intensity = r.ImGui_SliderDouble(ctx, "##intensity", state.randomize_intensity, 0.0, 1.0, "%.2f")
  if changed then state.randomize_intensity = new_intensity end
  r.ImGui_SetNextItemWidth(ctx, 62)
  local changed, new_min = r.ImGui_SliderDouble(ctx, "##basemin", state.randomize_min, 0.0, 1.0, "%.2f")
  if changed then
    state.randomize_min = new_min
    if state.randomize_max < new_min then state.randomize_max = new_min end
    scheduleSave()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 62)
  local changed, new_max = r.ImGui_SliderDouble(ctx, "##basemax", state.randomize_max, 0.0, 1.0, "%.2f")
  if changed then
    state.randomize_max = new_max
    if state.randomize_min > new_max then state.randomize_min = new_max end
    scheduleSave()
  end

  r.ImGui_Dummy(ctx, 0, 0)
  if r.ImGui_Button(ctx, "Random", 128) then
    globalRandomSelect()
    saveTrackSelection()
  end

  r.ImGui_SetNextItemWidth(ctx, 62)
  local changed, new_min = r.ImGui_SliderInt(ctx, "##min", state.random_min, 1, 300)
  if changed then state.random_min = new_min end
  r.ImGui_SameLine(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 62)
  local changed, new_max = r.ImGui_SliderInt(ctx, "##max", state.random_max, 1, 300)
  if changed then
    state.random_max = math.max(new_max, state.random_min)
  end

  r.ImGui_Dummy(ctx, 0, 0)
  if r.ImGui_Button(ctx, "Presets", 128) then
    state.show_presets_window = true
  end
end

function drawFXSection()
  local header_font = getStyleFont("header")

  if header_font then
    r.ImGui_PushFont(ctx, header_font)
    r.ImGui_Text(ctx, "FX SETTINGS")
    r.ImGui_PopFont(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Dummy(ctx, 0, 0)
  end
  if r.ImGui_Button(ctx, state.show_filters_window and "Hide Filters" or "Show Filters") then
    state.show_filters_window = not state.show_filters_window
  end
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
  r.ImGui_Text(ctx, "Selected: " .. state.selected_count)
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "All") then
    for fx_id, fx_data in pairs(state.fx_data) do
      selectAllParams(fx_data.params, true)
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
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Set Base", 60) then
    captureBaseValues()
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
          local child_width = collapsed and 22 or fx_width
          local child_height = collapsed and 270 or -1
          if r.ImGui_BeginChild(ctx, "FX" .. fx_id, child_width, child_height) then
            if collapsed then
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ButtonTextAlign(), 0.5, 0.0)
              local fx_name_vertical = ""
              for i = 1, #fx_data.name do
                fx_name_vertical = fx_name_vertical .. fx_data.name:sub(i, i) .. "\n"
              end
              if r.ImGui_Button(ctx, fx_name_vertical, 22, 242) then
                state.fx_collapsed[fx_id] = false
              end
              r.ImGui_PopStyleVar(ctx)
              local enabled = fx_data.enabled
              if r.ImGui_Checkbox(ctx, "##enabled" .. fx_id, enabled) then
                local actual_fx_id = fx_data.actual_fx_id or fx_id
                r.TrackFX_SetEnabled(state.track, actual_fx_id, not enabled)
                fx_data.enabled = not enabled
              end
            else
              local header_text = fx_data.name .. " [-]"
              if r.ImGui_Button(ctx, header_text, fx_width - 44, 22) then
                state.fx_collapsed[fx_id] = true
              end
              r.ImGui_SameLine(ctx)
              local enabled = fx_data.enabled
              if r.ImGui_Checkbox(ctx, "##enabled" .. fx_id, enabled) then
                local actual_fx_id = fx_data.actual_fx_id or fx_id
                r.TrackFX_SetEnabled(state.track, actual_fx_id, not enabled)
                fx_data.enabled = not enabled
              end
              r.ImGui_Dummy(ctx, 0, 0)
              local btn_width1 = (fx_width - 30) / 4
              local btn_width2 = (fx_width - 26) / 3
              if r.ImGui_Button(ctx, "All##" .. fx_id, btn_width1) then
                selectAllParams(fx_data.params, true)
                saveTrackSelection()
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "None##" .. fx_id, btn_width1) then
                selectAllParams(fx_data.params, false)
                saveTrackSelection()
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "Rnd##" .. fx_id, btn_width1) then
                randomSelectParams(fx_data.params, fx_id)
                saveTrackSelection()
              end
              r.ImGui_SameLine(ctx)
              r.ImGui_SetNextItemWidth(ctx, btn_width1)
              local changed, new_max = r.ImGui_SliderInt(ctx, "##max" .. fx_id, state.fx_random_max[fx_id] or 3, 1, 10)
              if changed then
                state.fx_random_max[fx_id] = new_max
                saveTrackSelection()
              end
              if r.ImGui_Button(ctx, "RandXY##" .. fx_id, btn_width2) then
                randomizeXYAssign(fx_data.params, fx_id)
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "RandRng##" .. fx_id, btn_width2) then
                randomizeRanges(fx_data.params, fx_id)
              end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "RndBase##" .. fx_id, btn_width2) then
                randomizeBaseValues(fx_data.params, fx_id)
              end
              r.ImGui_Dummy(ctx, 0, 0)
              if r.ImGui_BeginTable(ctx, "params" .. fx_id, 6, r.ImGui_TableFlags_SizingFixedFit()) then
                r.ImGui_TableSetupColumn(ctx, "Name", 0, 110)
                r.ImGui_TableSetupColumn(ctx, "N", 0, 18)
                r.ImGui_TableSetupColumn(ctx, "X", 0, 18)
                r.ImGui_TableSetupColumn(ctx, "Y", 0, 18)
                r.ImGui_TableSetupColumn(ctx, "Range", 0, 62)
                r.ImGui_TableSetupColumn(ctx, "Base", 0, 62)
                for param_id, param_data in pairs(fx_data.params) do
                  r.ImGui_TableNextRow(ctx)
                  r.ImGui_TableNextColumn(ctx)
                  local param_name = param_data.name
                  if #param_name > 14 then
                    param_name = param_name:sub(1, 11) .. "..."
                  end
                  local changed, selected = r.ImGui_Checkbox(ctx, param_name .. "##" .. fx_id .. "_" .. param_id,
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
                  if r.ImGui_Button(ctx, param_invert and "N" or "P" .. "##n" .. fx_id .. "_" .. param_id, 22, 22) then
                    setParamInvert(fx_id, param_id, not param_invert)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  local x_assign, y_assign = getParamXYAssign(fx_id, param_id)
                  local param_invert = getParamInvert(fx_id, param_id)
                  if r.ImGui_Button(ctx, x_assign and "X" or "-" .. "##x" .. fx_id .. "_" .. param_id, 22, 22) then
                    setParamXYAssign(fx_id, param_id, "x", not x_assign)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  if r.ImGui_Button(ctx, y_assign and "Y" or "-" .. "##y" .. fx_id .. "_" .. param_id, 22, 22) then
                    setParamXYAssign(fx_id, param_id, "y", not y_assign)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  r.ImGui_SetNextItemWidth(ctx, 66)
                  local range = getParamRange(fx_id, param_id)
                  local changed, new_range = r.ImGui_SliderDouble(ctx, "##r" .. fx_id .. "_" .. param_id, range, 0.1, 1.0,
                    "%.1f")
                  if changed then
                    setParamRange(fx_id, param_id, new_range)
                  end
                  r.ImGui_TableNextColumn(ctx)
                  r.ImGui_SetNextItemWidth(ctx, 66)
                  local changed, new_base = r.ImGui_SliderDouble(ctx, "##b" .. fx_id .. "_" .. param_id,
                    param_data.base_value, 0.0, 1.0, "%.2f")
                  if changed then
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
                      string.format("%.3f (Base: %.3f, Range: %.1f)", param_data.current_value, param_data.base_value,
                        range) .. xy_text .. invert_text)
                  end
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
  if r.ImGui_Button(ctx, "Reset", 80, 30) then
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
  if r.ImGui_BeginChild(ctx, "Navigation", 188, 0) then
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
  if r.ImGui_BeginChild(ctx, "FX", 0, 0) then
    drawFXSection()
    r.ImGui_EndChild(ctx)
  end
end

function drawInterface()
  if sl then
    local success, colors, vars = sl.applyToContext(ctx)
    if success then pc, pv = colors, vars end
  end

  r.ImGui_SetNextWindowSize(ctx, 1400, 800, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, 'FX Constellation', true)
  if visible then
    local main_font = getStyleFont("main")

    if main_font then
      r.ImGui_PushFont(ctx, main_font)
    end

    checkSave()
    updateGestureMotion()
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
    if isTrackValid() then
      checkForFXChanges()
    end
    if not isTrackValid() then
      r.ImGui_Text(ctx, "No track selected")
      if main_font then r.ImGui_PopFont(ctx) end
      r.ImGui_End(ctx)
      if sl then sl.clearStyles(ctx, pc, pv) end
      return open
    end

    drawHorizontalLayout()

    if main_font then
      r.ImGui_PopFont(ctx)
    end
    r.ImGui_End(ctx)
  end
  if sl then sl.clearStyles(ctx, pc, pv) end
  drawFiltersWindow()
  drawPresetsWindow()
  return open
end

loadSettings()
local function loop()
  local open = drawInterface()
  if open then r.defer(loop) else saveSettings() end
end
r.atexit(saveSettings)
loop()










