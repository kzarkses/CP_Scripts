-- FX Constellation - Presets Module
-- Preset and snapshot management system

local Presets = {}

-- Save snapshot with FX chain validation
function Presets.saveSnapshot(state, r, Utilities, StateManagement)
  local name = state.current_snapshot_name or ""
  if name == "" or not Utilities.isTrackValid(state, r) then return end

  local fx_sig = Utilities.getCurrentFXChainSignature(state, r)
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
        local x_assign, y_assign = Utilities.getParamXYAssign(fx_id, param_id)
        snapshot.param_data[key] = {
          base_value = param_data.base_value,
          range = Utilities.getParamRange(fx_id, param_id),
          x_assign = x_assign,
          y_assign = y_assign,
          invert = Utilities.getParamInvert(fx_id, param_id),
          selected = true
        }
      end
    end
  end

  state.snapshots[fx_sig][name] = snapshot
  StateManagement.scheduleSnapshotSave()
end

-- Load snapshot with FX chain matching
function Presets.loadSnapshot(state, r, Utilities, StateManagement)
  local name = state.current_snapshot_name or ""
  if not Utilities.isTrackValid(state, r) then return end

  local fx_sig = Utilities.getCurrentFXChainSignature(state, r)
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
  Utilities.updateJSFXFromGesture(state, r)

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

        Utilities.setParamRange(fx_id, param_id, saved_param.range or 1.0)
        Utilities.setParamXYAssign(fx_id, param_id, "x", saved_param.x_assign)
        Utilities.setParamXYAssign(fx_id, param_id, "y", saved_param.y_assign)
        Utilities.setParamInvert(fx_id, param_id, saved_param.invert or false)
      end
    end
  end

  r.Undo_EndBlock("Load FX Constellation snapshot: " .. name, -1)
  Utilities.updateSelectedCount(state)
  Presets.captureBaseValues(state, r, Utilities)
  StateManagement.saveTrackSelection(state)
end

-- Delete a snapshot
function Presets.deleteSnapshot(state, r, Utilities, StateManagement)
  local name = state.current_snapshot_name or ""
  local fx_sig = Utilities.getCurrentFXChainSignature(state, r)
  if fx_sig and state.snapshots[fx_sig] and state.snapshots[fx_sig][name] then
    state.snapshots[fx_sig][name] = nil
    if not next(state.snapshots[fx_sig]) then
      state.snapshots[fx_sig] = nil
    end
    StateManagement.scheduleSnapshotSave()
  end
end

-- Capture base values for all selected parameters
function Presets.captureBaseValues(state, r, Utilities)
  state.param_base_values = {}
  state.gesture_base_x = state.gesture_x
  state.gesture_base_y = state.gesture_y
  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        param_data.base_value = param_data.current_value
        local key = Utilities.getParamKey(fx_id, param_id)
        if key then
          state.param_base_values[key] = param_data.current_value
        end
      end
    end
  end
end

-- Update parameter base value
function Presets.updateParamBaseValue(state, r, Utilities, StateManagement, fx_id, param_id, new_value)
  if not Utilities.isTrackValid(state, r) then return end
  local param_data = state.fx_data[fx_id].params[param_id]
  if param_data then
    param_data.base_value = new_value
    local key = Utilities.getParamKey(fx_id, param_id)
    if key then
      state.param_base_values[key] = new_value
    end
    local actual_fx_id = state.fx_data[fx_id].actual_fx_id or fx_id
    r.TrackFX_SetParam(state.track, actual_fx_id, param_id, new_value)
    param_data.current_value = new_value
    StateManagement.saveTrackSelection(state)
  end
end

-- Capture state for morphing
function Presets.captureToMorph(state, r, slot)
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

-- Morph between two presets
function Presets.morphBetweenPresets(state, r, Utilities, amount)
  if not state.morph_preset_a or not state.morph_preset_b or not Utilities.isTrackValid(state, r) then return end
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

-- Capture full state including all FX and parameters
function Presets.captureCompleteState(state, r, Utilities)
  if not Utilities.isTrackValid(state, r) then return {} end

  local complete_state = {
    gesture_x = state.gesture_x,
    gesture_y = state.gesture_y,
    gesture_base_x = state.gesture_base_x,
    gesture_base_y = state.gesture_base_y,
    fx_chain = {},
    track_guid = Utilities.getTrackGUID(state, r)
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
        local x_assign, y_assign = Utilities.getParamXYAssign(fx_id, param_id)
        complete_state.fx_chain[fx_id].params[param_id] = {
          name = param_data.name,
          current_value = param_data.current_value,
          base_value = param_data.base_value,
          selected = param_data.selected,
          range = Utilities.getParamRange(fx_id, param_id),
          x_assign = x_assign,
          y_assign = y_assign,
          invert = Utilities.getParamInvert(fx_id, param_id)
        }
      end
    end
  end

  return complete_state
end

-- Save complete preset
function Presets.savePreset(state, r, Utilities, StateManagement, name)
  if name == "" then return end
  local preset_data = Presets.captureCompleteState(state, r, Utilities)
  state.presets[name] = preset_data
  StateManagement.schedulePresetSave()
end

-- Load preset with all parameters
function Presets.loadPreset(state, r, Utilities, StateManagement, name)
  if not Utilities.isTrackValid(state, r) then return end
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

  Utilities.scanTrackFX(state, r)

  for fx_id, fx_data in pairs(state.fx_data) do
    state.fx_collapsed[fx_id] = false
  end

  state.gesture_x = preset.gesture_x or 0.5
  state.gesture_y = preset.gesture_y or 0.5
  Utilities.updateJSFXFromGesture(state, r)
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

              Utilities.setParamRange(current_fx_id, current_param_id, param_preset.range or 1.0)
              Utilities.setParamXYAssign(current_fx_id, current_param_id, "x", param_preset.x_assign)
              Utilities.setParamXYAssign(current_fx_id, current_param_id, "y", param_preset.y_assign)
              Utilities.setParamInvert(current_fx_id, current_param_id, param_preset.invert or false)
              break
            end
          end
        end
        break
      end
    end
  end

  r.Undo_EndBlock("Load FX Constellation preset: " .. name, -1)
  Utilities.closeAllFloatingFX(state, r)
  Utilities.updateSelectedCount(state)
  Presets.captureBaseValues(state, r, Utilities)
  state.current_loaded_preset = name
  StateManagement.saveTrackSelection(state)

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

-- Rename existing preset
function Presets.renamePreset(state, StateManagement, old_name, new_name)
  if state.presets[old_name] and new_name ~= "" and old_name ~= new_name then
    state.presets[new_name] = state.presets[old_name]
    state.presets[old_name] = nil
    if state.selected_preset == old_name then
      state.selected_preset = new_name
    end
    StateManagement.scheduleSave()
  end
end

-- Delete preset
function Presets.deletePreset(state, StateManagement, name)
  if state.presets[name] then
    state.presets[name] = nil
    if state.selected_preset == name then
      state.selected_preset = ""
    end
    if state.current_loaded_preset == name then
      state.current_loaded_preset = ""
    end
    StateManagement.scheduleSave()
  end
end

return Presets
