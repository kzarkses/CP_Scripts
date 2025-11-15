local PresetSystem = {}

function PresetSystem.init(reaper_api, core, fxmanager, gesture, persistence, soundgen)
	PresetSystem.r = reaper_api
	PresetSystem.core = core
	PresetSystem.fxmanager = fxmanager
	PresetSystem.gesture = gesture
	PresetSystem.persistence = persistence
	PresetSystem.soundgen = soundgen
end

function PresetSystem.getNextSnapshotName()
	local max_num = 0
	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset ~= "" and PresetSystem.core.state.presets[current_preset] and PresetSystem.core.state.presets[current_preset].snapshots then
		for name, _ in pairs(PresetSystem.core.state.presets[current_preset].snapshots) do
			local num = tonumber(name:match("Snapshot(%d+)"))
			if num and num > max_num then
				max_num = num
			end
		end
	end
	return "Snapshot" .. (max_num + 1)
end

function PresetSystem.getNextGranularSetName()
	local max_num = 0
	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset ~= "" and PresetSystem.core.state.presets[current_preset] and PresetSystem.core.state.presets[current_preset].granular_sets then
		for name, _ in pairs(PresetSystem.core.state.presets[current_preset].granular_sets) do
			local num = tonumber(name:match("GrainSet(%d+)"))
			if num and num > max_num then
				max_num = num
			end
		end
	end
	return "GrainSet" .. (max_num + 1)
end

function PresetSystem.saveGranularSet(name)
	if name == "" or #PresetSystem.core.state.granular_grains == 0 then return end

	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset == "" then
		PresetSystem.r.ShowMessageBox("Please load a preset first before saving granular sets.", "FX Constellation", 0)
		return
	end

	if not PresetSystem.core.state.presets[current_preset] then return end

	if not PresetSystem.core.state.presets[current_preset].granular_sets then
		PresetSystem.core.state.presets[current_preset].granular_sets = {}
	end

	PresetSystem.core.state.presets[current_preset].granular_sets[name] = {
		grid_size = PresetSystem.core.state.granular_grid_size,
		grains = {}
	}
	for i, grain in ipairs(PresetSystem.core.state.granular_grains) do
		PresetSystem.core.state.presets[current_preset].granular_sets[name].grains[i] = {
			x = grain.x,
			y = grain.y,
			param_values = {}
		}
		for fx_id, params in pairs(grain.param_values) do
			PresetSystem.core.state.presets[current_preset].granular_sets[name].grains[i].param_values[fx_id] = {}
			for param_id, value in pairs(params) do
				PresetSystem.core.state.presets[current_preset].granular_sets[name].grains[i].param_values[fx_id][param_id] = value
			end
		end
	end
	PresetSystem.core.state.granular_set_name = PresetSystem.getNextGranularSetName()
	PresetSystem.persistence.schedulePresetSave()
end

function PresetSystem.loadGranularSet(name)
	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset == "" or not PresetSystem.core.state.presets[current_preset] or not PresetSystem.core.state.presets[current_preset].granular_sets then
		return
	end

	local set_data = PresetSystem.core.state.presets[current_preset].granular_sets[name]
	if not set_data then return end
	PresetSystem.core.state.granular_grid_size = set_data.grid_size
	PresetSystem.core.state.granular_grains = {}
	for i, grain_data in ipairs(set_data.grains) do
		PresetSystem.core.state.granular_grains[i] = {
			x = grain_data.x,
			y = grain_data.y,
			param_values = {}
		}
		for fx_id, params in pairs(grain_data.param_values) do
			PresetSystem.core.state.granular_grains[i].param_values[fx_id] = {}
			for param_id, value in pairs(params) do
				PresetSystem.core.state.granular_grains[i].param_values[fx_id][param_id] = value
			end
		end
	end
end

function PresetSystem.deleteGranularSet(name)
	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset ~= "" and PresetSystem.core.state.presets[current_preset] and PresetSystem.core.state.presets[current_preset].granular_sets and PresetSystem.core.state.presets[current_preset].granular_sets[name] then
		PresetSystem.core.state.presets[current_preset].granular_sets[name] = nil
		if not next(PresetSystem.core.state.presets[current_preset].granular_sets) then
			PresetSystem.core.state.presets[current_preset].granular_sets = {}
		end
		PresetSystem.persistence.schedulePresetSave()
	end
end

function PresetSystem.saveSnapshot(name)
	if name == "" or not PresetSystem.core.isTrackValid() then return end

	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset == "" then
		PresetSystem.r.ShowMessageBox("Please load a preset first before saving snapshots.", "FX Constellation", 0)
		return
	end

	if not PresetSystem.core.state.presets[current_preset] then return end

	if not PresetSystem.core.state.presets[current_preset].snapshots then
		PresetSystem.core.state.presets[current_preset].snapshots = {}
	end

	local snapshot = {
		gesture_x = PresetSystem.core.state.gesture_x,
		gesture_y = PresetSystem.core.state.gesture_y,
		gesture_base_x = PresetSystem.core.state.gesture_base_x,
		gesture_base_y = PresetSystem.core.state.gesture_base_y,
		fx_list = {},
		fx_bypass_states = {},
		param_data = {}
	}

	for fx_id, fx_data in pairs(PresetSystem.core.state.fx_data) do
		table.insert(snapshot.fx_list, fx_data.full_name)
		snapshot.fx_bypass_states[fx_data.full_name] = not fx_data.enabled

		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				local key = fx_data.full_name .. "||" .. param_data.name
				local x_assign, y_assign = PresetSystem.fxmanager.getParamXYAssign(fx_id, param_id)
				snapshot.param_data[key] = {
					base_value = param_data.base_value,
					range = PresetSystem.fxmanager.getParamRange(fx_id, param_id),
					x_assign = x_assign,
					y_assign = y_assign,
					invert = PresetSystem.fxmanager.getParamInvert(fx_id, param_id),
					selected = true
				}
			end
		end
	end

	PresetSystem.core.state.presets[current_preset].snapshots[name] = snapshot
	PresetSystem.core.state.snapshot_name = PresetSystem.getNextSnapshotName()
	PresetSystem.persistence.schedulePresetSave()
end

function PresetSystem.loadSnapshot(name)
	if not PresetSystem.core.isTrackValid() then return end

	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset == "" or not PresetSystem.core.state.presets[current_preset] or not PresetSystem.core.state.presets[current_preset].snapshots or not PresetSystem.core.state.presets[current_preset].snapshots[name] then
		return
	end

	local snapshot = PresetSystem.core.state.presets[current_preset].snapshots[name]
	local current_fx_list = {}

	for fx_id, fx_data in pairs(PresetSystem.core.state.fx_data) do
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
		local msg = "FX Constellation - Snapshot Warning:\n\nThe current FX chain does not match the saved snapshot.\n\nExpected FX:\n"
		for i, fx_name in ipairs(snapshot.fx_list) do
			msg = msg .. "  " .. i .. ". " .. fx_name .. "\n"
		end
		msg = msg .. "\nCurrent FX:\n"
		for i, fx_name in ipairs(current_fx_list) do
			msg = msg .. "  " .. i .. ". " .. fx_name .. "\n"
		end
		msg = msg .. "\nDo you want to load the snapshot anyway?\n(Parameters will be matched by FX and parameter names)"

		local result = PresetSystem.r.ShowMessageBox(msg, "FX Constellation - Snapshot Mismatch", 4)
		if result == 7 then return end
	end

	PresetSystem.r.Undo_BeginBlock()

	PresetSystem.core.state.gesture_x = snapshot.gesture_x or 0.5
	PresetSystem.core.state.gesture_y = snapshot.gesture_y or 0.5
	PresetSystem.core.state.gesture_base_x = snapshot.gesture_base_x or 0.5
	PresetSystem.core.state.gesture_base_y = snapshot.gesture_base_y or 0.5
	PresetSystem.gesture.updateJSFXFromGesture()

	for fx_id, fx_data in pairs(PresetSystem.core.state.fx_data) do
		if snapshot.fx_bypass_states and snapshot.fx_bypass_states[fx_data.full_name] ~= nil then
			local actual_fx_id = fx_data.actual_fx_id or fx_id
			local should_bypass = snapshot.fx_bypass_states[fx_data.full_name]
			PresetSystem.r.TrackFX_SetEnabled(PresetSystem.core.state.track, actual_fx_id, not should_bypass)
			fx_data.enabled = not should_bypass
		end

		for param_id, param_data in pairs(fx_data.params) do
			local key = fx_data.full_name .. "||" .. param_data.name
			local saved_param = snapshot.param_data[key]

			if saved_param then
				param_data.selected = saved_param.selected or false
				param_data.base_value = saved_param.base_value or param_data.current_value

				local actual_fx_id = fx_data.actual_fx_id or fx_id
				local denormalized_value = PresetSystem.core.denormalizeParamValue(param_data.base_value, param_data.min_val, param_data.max_val)
				PresetSystem.r.TrackFX_SetParam(PresetSystem.core.state.track, actual_fx_id, param_id, denormalized_value)
				param_data.current_value = param_data.base_value

				PresetSystem.fxmanager.setParamRange(fx_id, param_id, saved_param.range or 1.0)
				PresetSystem.fxmanager.setParamXYAssign(fx_id, param_id, "x", saved_param.x_assign)
				PresetSystem.fxmanager.setParamXYAssign(fx_id, param_id, "y", saved_param.y_assign)
				PresetSystem.fxmanager.setParamInvert(fx_id, param_id, saved_param.invert or false)
			end
		end
	end

	PresetSystem.r.Undo_EndBlock("Load FX Constellation snapshot: " .. name, -1)
	PresetSystem.fxmanager.updateSelectedCount()
	PresetSystem.fxmanager.captureBaseValues()
	PresetSystem.fxmanager.saveTrackSelection()
end

function PresetSystem.deleteSnapshot(name)
	local current_preset = PresetSystem.core.state.current_loaded_preset
	if current_preset ~= "" and PresetSystem.core.state.presets[current_preset] and PresetSystem.core.state.presets[current_preset].snapshots and PresetSystem.core.state.presets[current_preset].snapshots[name] then
		PresetSystem.core.state.presets[current_preset].snapshots[name] = nil
		if not next(PresetSystem.core.state.presets[current_preset].snapshots) then
			PresetSystem.core.state.presets[current_preset].snapshots = {}
		end
		PresetSystem.persistence.schedulePresetSave()
	end
end

function PresetSystem.captureFXChainState()
	if not PresetSystem.core.isTrackValid() then return nil end
	local state = { fx_list = {}, bypass_states = {} }
	local fx_count = PresetSystem.r.TrackFX_GetCount(PresetSystem.core.state.track)
	for fx_id = 0, fx_count - 1 do
		local _, fx_name = PresetSystem.r.TrackFX_GetFXName(PresetSystem.core.state.track, fx_id, "")
		if not fx_name:find("FX Constellation Bridge") then
			table.insert(state.fx_list, fx_name)
			state.bypass_states[fx_name] = not PresetSystem.r.TrackFX_GetEnabled(PresetSystem.core.state.track, fx_id)
		end
	end
	return state
end

function PresetSystem.compareFXChainState(state1, state2)
	if not state1 or not state2 then return false end
	if #state1.fx_list ~= #state2.fx_list then return false end
	for i, fx_name in ipairs(state1.fx_list) do
		if state2.fx_list[i] ~= fx_name then return false end
		if state1.bypass_states[fx_name] ~= state2.bypass_states[fx_name] then return false end
	end
	return true
end

function PresetSystem.checkPresetModification()
	if PresetSystem.core.state.preset_base_name == "" or not PresetSystem.core.state.initial_fx_chain_state then
		return
	end
	local current_state = PresetSystem.captureFXChainState()
	if not PresetSystem.compareFXChainState(PresetSystem.core.state.initial_fx_chain_state, current_state) then
		if not PresetSystem.core.state.current_loaded_preset:find(" %(Modified%)$") then
			PresetSystem.core.state.current_loaded_preset = PresetSystem.core.state.preset_base_name .. " (Modified)"
		end
	else
		if PresetSystem.core.state.current_loaded_preset:find(" %(Modified%)$") then
			PresetSystem.core.state.current_loaded_preset = PresetSystem.core.state.preset_base_name
		end
	end
end

function PresetSystem.captureCompleteState()
	if not PresetSystem.core.isTrackValid() then return {} end

	local sg = PresetSystem.core.state.sound_generator
	local complete_state = {
		gesture_x = PresetSystem.core.state.gesture_x,
		gesture_y = PresetSystem.core.state.gesture_y,
		gesture_base_x = PresetSystem.core.state.gesture_base_x,
		gesture_base_y = PresetSystem.core.state.gesture_base_y,
		fx_chain = {},
		track_guid = PresetSystem.core.getTrackGUID(),
		sound_generator = {
			enabled = sg.enabled,
			mode = sg.mode,
			waveform = sg.waveform,
			frequency = sg.frequency,
			rhythmic = sg.rhythmic,
			tick_rate = sg.tick_rate,
			duty_cycle = sg.duty_cycle,
			noise_color = sg.noise_color,
			base_freq = sg.base_freq,
			use_adsr = sg.use_adsr,
			attack = sg.attack,
			decay = sg.decay,
			sustain = sg.sustain,
			release = sg.release,
			midi_mode = sg.midi_mode,
			amplitude = sg.amplitude,
			stereo_width = sg.stereo_width
		}
	}

	local fx_count = PresetSystem.r.TrackFX_GetCount(PresetSystem.core.state.track)
	for fx_id = 0, fx_count - 1 do
		local _, fx_name = PresetSystem.r.TrackFX_GetFXName(PresetSystem.core.state.track, fx_id, "")
		local enabled = PresetSystem.r.TrackFX_GetEnabled(PresetSystem.core.state.track, fx_id)
		local retval, preset = PresetSystem.r.TrackFX_GetPreset(PresetSystem.core.state.track, fx_id, "")
		local param_count = PresetSystem.r.TrackFX_GetNumParams(PresetSystem.core.state.track, fx_id)

		complete_state.fx_chain[fx_id] = {
			name = fx_name,
			enabled = enabled,
			preset = retval and preset or "",
			param_count = param_count,
			params = {}
		}

		if PresetSystem.core.state.fx_data[fx_id] then
			for param_id, param_data in pairs(PresetSystem.core.state.fx_data[fx_id].params) do
				local x_assign, y_assign = PresetSystem.fxmanager.getParamXYAssign(fx_id, param_id)
				complete_state.fx_chain[fx_id].params[param_id] = {
					name = param_data.name,
					current_value = param_data.current_value,
					base_value = param_data.base_value,
					selected = param_data.selected,
					range = PresetSystem.fxmanager.getParamRange(fx_id, param_id),
					x_assign = x_assign,
					y_assign = y_assign,
					invert = PresetSystem.fxmanager.getParamInvert(fx_id, param_id)
				}
			end
		end
	end

	return complete_state
end

function PresetSystem.savePreset(name)
	if name == "" then return end
	local preset_data = PresetSystem.captureCompleteState()
	PresetSystem.core.state.presets[name] = preset_data
	PresetSystem.core.state.current_loaded_preset = name
	PresetSystem.core.state.preset_base_name = name
	PresetSystem.core.state.initial_fx_chain_state = PresetSystem.captureFXChainState()
	PresetSystem.persistence.schedulePresetSave()
end

function PresetSystem.loadPreset(name)
	if not PresetSystem.core.isTrackValid() then return end
	local preset = PresetSystem.core.state.presets[name]
	if not preset then return end

	local missing_fx, param_count_warnings = {}, {}

	local original_fxfloat = PresetSystem.r.SNM_GetIntConfigVar("fxfloat_focus", -1)
	if original_fxfloat >= 0 then
		PresetSystem.r.SNM_SetIntConfigVar("fxfloat_focus", 0)
	end

	PresetSystem.r.Undo_BeginBlock()

	local fx_count = PresetSystem.r.TrackFX_GetCount(PresetSystem.core.state.track)
	for fx_id = fx_count - 1, 0, -1 do
		local _, fx_name = PresetSystem.r.TrackFX_GetFXName(PresetSystem.core.state.track, fx_id, "")
		if not fx_name:find("FX Constellation Bridge") then
			PresetSystem.r.TrackFX_Delete(PresetSystem.core.state.track, fx_id)
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
			local new_fx_id = PresetSystem.r.TrackFX_AddByName(PresetSystem.core.state.track, fx_preset.name, false, -1)
			if new_fx_id >= 0 then
				PresetSystem.r.TrackFX_Show(PresetSystem.core.state.track, new_fx_id, 2)
				PresetSystem.r.TrackFX_SetEnabled(PresetSystem.core.state.track, new_fx_id, fx_preset.enabled)
				if fx_preset.preset and fx_preset.preset ~= "" then
					PresetSystem.r.TrackFX_SetPreset(PresetSystem.core.state.track, new_fx_id, fx_preset.preset)
				end
				if fx_preset.param_count then
					local current_param_count = PresetSystem.r.TrackFX_GetNumParams(PresetSystem.core.state.track, new_fx_id)
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

	PresetSystem.fxmanager.scanTrackFX()

	for fx_id, fx_data in pairs(PresetSystem.core.state.fx_data) do
		PresetSystem.core.state.fx_collapsed[fx_id] = false
	end

	PresetSystem.core.state.gesture_x = preset.gesture_x or 0.5
	PresetSystem.core.state.gesture_y = preset.gesture_y or 0.5
	PresetSystem.gesture.updateJSFXFromGesture()
	PresetSystem.core.state.gesture_base_x = preset.gesture_base_x or 0.5
	PresetSystem.core.state.gesture_base_y = preset.gesture_base_y or 0.5

	for saved_fx_id, fx_preset in pairs(preset.fx_chain or {}) do
		for current_fx_id, fx_data in pairs(PresetSystem.core.state.fx_data) do
			if fx_data.full_name == fx_preset.name then
				for saved_param_id, param_preset in pairs(fx_preset.params or {}) do
					for current_param_id, param_data in pairs(fx_data.params) do
						if param_data.name == param_preset.name then
							local actual_fx_id = fx_data.actual_fx_id or current_fx_id
							local denormalized_value = PresetSystem.core.denormalizeParamValue(param_preset.current_value, param_data.min_val, param_data.max_val)
							PresetSystem.r.TrackFX_SetParam(PresetSystem.core.state.track, actual_fx_id, current_param_id, denormalized_value)
							param_data.current_value = param_preset.current_value
							param_data.base_value = param_preset.base_value
							param_data.selected = param_preset.selected

							PresetSystem.fxmanager.setParamRange(current_fx_id, current_param_id, param_preset.range or 1.0)
							PresetSystem.fxmanager.setParamXYAssign(current_fx_id, current_param_id, "x", param_preset.x_assign)
							PresetSystem.fxmanager.setParamXYAssign(current_fx_id, current_param_id, "y", param_preset.y_assign)
							PresetSystem.fxmanager.setParamInvert(current_fx_id, current_param_id, param_preset.invert or false)
							break
						end
					end
				end
				break
			end
		end
	end

	if preset.sound_generator then
		local sg = PresetSystem.core.state.sound_generator
		if preset.sound_generator.enabled then
			sg.mode = preset.sound_generator.mode or 0
			sg.waveform = preset.sound_generator.waveform or 0
			sg.frequency = preset.sound_generator.frequency or 440
			sg.rhythmic = preset.sound_generator.rhythmic or false
			sg.tick_rate = preset.sound_generator.tick_rate or 4
			sg.duty_cycle = preset.sound_generator.duty_cycle or 0.5
			sg.noise_color = preset.sound_generator.noise_color or 0.5
			sg.base_freq = preset.sound_generator.base_freq or 440
			sg.use_adsr = preset.sound_generator.use_adsr ~= false
			sg.attack = preset.sound_generator.attack or 0.01
			sg.decay = preset.sound_generator.decay or 0.1
			sg.sustain = preset.sound_generator.sustain or 0.7
			sg.release = preset.sound_generator.release or 0.2
			sg.midi_mode = preset.sound_generator.midi_mode ~= false
			sg.amplitude = preset.sound_generator.amplitude or 0.5
			sg.stereo_width = preset.sound_generator.stereo_width or 1.0
			if not sg.enabled then
				PresetSystem.soundgen.createGenerator()
			else
				PresetSystem.soundgen.updateJSFXParams()
			end
		elseif sg.enabled then
			PresetSystem.soundgen.removeGenerator()
		end
	end

	PresetSystem.r.Undo_EndBlock("Load FX Constellation preset: " .. name, -1)
	PresetSystem.fxmanager.updateSelectedCount()
	PresetSystem.fxmanager.captureBaseValues()
	PresetSystem.core.state.current_loaded_preset = name
	PresetSystem.core.state.preset_base_name = name
	PresetSystem.core.state.initial_fx_chain_state = PresetSystem.captureFXChainState()
	PresetSystem.fxmanager.saveTrackSelection()

	if original_fxfloat >= 0 then
		PresetSystem.r.SNM_SetIntConfigVar("fxfloat_focus", original_fxfloat)
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
		PresetSystem.r.ShowMessageBox(msg, "FX Constellation - Preset Warnings", 0)
	end
end

function PresetSystem.deletePreset(name)
	if PresetSystem.core.state.presets[name] then
		PresetSystem.core.state.presets[name] = nil
		if PresetSystem.core.state.current_loaded_preset == name or PresetSystem.core.state.preset_base_name == name then
			PresetSystem.core.state.current_loaded_preset = ""
			PresetSystem.core.state.preset_base_name = ""
			PresetSystem.core.state.initial_fx_chain_state = nil
		end
		PresetSystem.persistence.schedulePresetSave()
	end
end

function PresetSystem.renamePreset(old_name, new_name)
	if PresetSystem.core.state.presets[old_name] and new_name ~= "" and old_name ~= new_name then
		PresetSystem.core.state.presets[new_name] = PresetSystem.core.state.presets[old_name]
		PresetSystem.core.state.presets[old_name] = nil
		if PresetSystem.core.state.current_loaded_preset == old_name then
			PresetSystem.core.state.current_loaded_preset = new_name
		end
		if PresetSystem.core.state.preset_base_name == old_name then
			PresetSystem.core.state.preset_base_name = new_name
		end
		PresetSystem.persistence.schedulePresetSave()
	end
end

function PresetSystem.showAllFloatingFX()
	local target_track = PresetSystem.core.state.track_locked and PresetSystem.core.state.locked_track or PresetSystem.core.state.track
	if not target_track or not PresetSystem.r.ValidatePtr(target_track, "MediaTrack*") then return end

	local command_id = PresetSystem.r.NamedCommandLookup("_S&M_WNTSHW3")
	if command_id > 0 then
		local current_track = PresetSystem.r.GetSelectedTrack(0, 0)
		PresetSystem.r.SetOnlyTrackSelected(target_track)
		PresetSystem.r.Main_OnCommand(command_id, 0)
		if current_track and current_track ~= target_track then
			PresetSystem.r.SetOnlyTrackSelected(current_track)
		end
	end
end

function PresetSystem.closeAllFloatingFX()
	local target_track = PresetSystem.core.state.track_locked and PresetSystem.core.state.locked_track or PresetSystem.core.state.track
	if not target_track or not PresetSystem.r.ValidatePtr(target_track, "MediaTrack*") then return end

	local command_id = PresetSystem.r.NamedCommandLookup("_S&M_WNCLS5")
	if command_id > 0 then
		local current_track = PresetSystem.r.GetSelectedTrack(0, 0)
		PresetSystem.r.SetOnlyTrackSelected(target_track)
		PresetSystem.r.Main_OnCommand(command_id, 0)
		if current_track and current_track ~= target_track then
			PresetSystem.r.SetOnlyTrackSelected(current_track)
		end
	end
end

return PresetSystem
