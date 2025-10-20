-- FX Constellation - State Management Module
-- Handles loading and saving of all persistent state

local StateManagement = {}

-- ============================================================================
-- Settings Load/Save Functions
-- ============================================================================

-- Load all settings from ExtState
function StateManagement.loadSettings(state, r, Utilities)
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
    local loaded = Utilities.deserialize(saved_state)
    if loaded then
      for k, v in pairs(loaded) do
        state[k] = v
      end
    end
  end

  local saved_selections = r.GetExtState("CP_FXConstellation", "track_selections")
  if saved_selections ~= "" then
    state.track_selections = Utilities.deserialize(saved_selections) or {}
  end

  local saved_granular_sets = r.GetExtState("CP_FXConstellation", "granular_sets")
  if saved_granular_sets ~= "" then
    state.granular_sets = Utilities.deserialize(saved_granular_sets) or {}
  end

  local saved_snapshots = r.GetExtState("CP_FXConstellation", "snapshots")
  if saved_snapshots ~= "" then
    state.snapshots = Utilities.deserialize(saved_snapshots) or {}
  end

  local saved_presets = r.GetExtState("CP_FXConstellation", "presets")
  if saved_presets ~= "" then
    state.presets = Utilities.deserialize(saved_presets) or {}
  end
end

-- Save all settings to ExtState
function StateManagement.saveSettings(state, r, Utilities, save_flags)
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
    r.SetExtState("CP_FXConstellation", "state", Utilities.serialize(save_data), false)
  end

  if save_flags.track_selections then
    local current_guid = Utilities.getTrackGUID(state, r)
    if current_guid and state.track_selections[current_guid] then
      local track_data = {}
      track_data[current_guid] = state.track_selections[current_guid]
      r.SetExtState("CP_FXConstellation", "track_selections", Utilities.serialize(track_data), false)
    end
  end

  if save_flags.presets and next(state.presets) then
    r.SetExtState("CP_FXConstellation", "presets", Utilities.serialize(state.presets), false)
  end

  if save_flags.granular_sets and next(state.granular_sets) then
    r.SetExtState("CP_FXConstellation", "granular_sets", Utilities.serialize(state.granular_sets), false)
  end

  if save_flags.snapshots and next(state.snapshots) then
    r.SetExtState("CP_FXConstellation", "snapshots", Utilities.serialize(state.snapshots), false)
  end

  if save_flags.settings then
    local filters_str = table.concat(state.filter_keywords, ",")
    r.SetExtState("CP_FXConstellation", "filter_keywords", filters_str, true)

    r.SetExtState("CP_FXConstellation", "param_filter", state.param_filter, true)
  end
end

-- ============================================================================
-- Track Selection Save/Load Functions
-- ============================================================================

-- Save track-specific parameter selection
function StateManagement.saveTrackSelection(state, r, Utilities, scheduleTrackSaveFn)
  local guid = Utilities.getTrackGUID(state, r)
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
  scheduleTrackSaveFn()
end

-- Load track-specific parameter selection
function StateManagement.loadTrackSelection(state, r, Utilities, updateJSFXFromGestureFn, captureBaseValuesFn, updateSelectedCountFn)
  local guid = Utilities.getTrackGUID(state, r)
  if not guid then return end
  local track_data = state.track_selections[guid]
  if not track_data then
    state.current_loaded_preset = ""
    captureBaseValuesFn()
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
  updateJSFXFromGestureFn()
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
  updateSelectedCountFn()
end

-- ============================================================================
-- Schedule Save Functions
-- ============================================================================

-- Schedule general settings save
function StateManagement.scheduleSave(state, r, save_flags)
  local current_time = r.time_precise()
  if current_time - state.save_cooldown > state.min_save_interval then
    save_flags.settings = true
    state.save_timer = current_time + 2.0
  end
end

-- Schedule track selection save
function StateManagement.scheduleTrackSave(save_flags)
  save_flags.track_selections = true
end

-- Schedule preset save
function StateManagement.schedulePresetSave(save_flags)
  save_flags.presets = true
end

-- Schedule granular sets save
function StateManagement.scheduleGranularSave(save_flags)
  save_flags.granular_sets = true
end

-- Schedule snapshot save
function StateManagement.scheduleSnapshotSave(save_flags)
  save_flags.snapshots = true
end

return StateManagement
