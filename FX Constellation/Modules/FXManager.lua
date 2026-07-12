local FXManager = {}

function FXManager.init(reaper_api, core, persistence, license, soundgen, fxdatabase)
	FXManager.r = reaper_api
	FXManager.core = core
	FXManager.persistence = persistence
	FXManager.license = license
	FXManager.soundgen = soundgen
	FXManager.fxdatabase = fxdatabase
end

function FXManager.shouldFilterParam(param_name)
	local lower_name = param_name:lower()
	for _, keyword in ipairs(FXManager.core.state.filter_keywords) do
		if lower_name:find(keyword:lower(), 1, true) then
			return true
		end
	end
	if FXManager.core.state.param_filter ~= "" then
		return not lower_name:find(FXManager.core.state.param_filter:lower(), 1, true)
	end
	return false
end

-- Discrete-step detection. The old implementation probed each param by
-- WRITING 21 test values and reading them back — on a big synth (Vital:
-- ~780 params) that meant ~16k param writes per scan, seconds of freeze and
-- audible zipper noise every time the chain changed. REAPER exposes the
-- same information natively without touching the value.
function FXManager.detectParamSteps(actual_fx_id, param_id)
	if not FXManager.core.isTrackValid() then return 0 end
	local ok, step, _, _, istoggle = FXManager.r.TrackFX_GetParameterStepSizes(
		FXManager.core.state.track, actual_fx_id, param_id)
	if not ok then return 0 end
	if istoggle then return 2 end
	if step and step > 0 then
		local _, min_val, max_val = FXManager.r.TrackFX_GetParamEx(
			FXManager.core.state.track, actual_fx_id, param_id)
		if min_val and max_val and max_val > min_val then
			local count = math.floor((max_val - min_val) / step + 0.5) + 1
			-- Same envelope as the old probe: 2..10 discrete positions snap,
			-- anything finer is treated as continuous.
			if count >= 2 and count <= 10 then return count end
		end
	end
	return 0
end

function FXManager.scanTrackFX()
	if not FXManager.core.isTrackValid() then return end
	local state = FXManager.core.state
	state.fx_data = {}
	state.param_poll_list = {}
	local fx_count = FXManager.r.TrackFX_GetCount(state.track)
	local visible_fx_id = 0
	local max_fx = FXManager.license and not FXManager.license.isFull() and 5 or 999
	local bridge_index = -1
	local modlfo_index = -1
	for fx = 0, fx_count - 1 do
		local _, fx_name = FXManager.r.TrackFX_GetFXName(state.track, fx, "")
		if fx_name:find("CP_Mod LFO", 1, true) and modlfo_index < 0 then
			modlfo_index = fx
		end
		if fx_name:find("FX Constellation Bridge") then
			-- The bridge moves whenever FX are inserted/removed before it
			-- (preset load, sound generator toggle, manual edits). The scan
			-- is the single chokepoint for chain changes, so the automation
			-- index is refreshed here — a stale index would read/WRITE the
			-- first two params of an unrelated plugin.
			if bridge_index < 0 then bridge_index = fx end
		elseif not fx_name:find("Sound Generator")
		   and not fx_name:find("CP_Mod", 1, true) then
			if visible_fx_id >= max_fx then
				break
			end
			local param_count = FXManager.r.TrackFX_GetNumParams(state.track, fx)
			local fx_entry = {
				name = FXManager.core.extractFXName(fx_name),
				full_name = fx_name,
				enabled = FXManager.r.TrackFX_GetEnabled(state.track, fx),
				actual_fx_id = fx,
				params = {}
			}
			state.fx_data[visible_fx_id] = fx_entry
			local fx_key = FXManager.core.getFXKey(visible_fx_id)
			if fx_key and state.fx_random_max[fx_key] == nil then
				state.fx_random_max[fx_key] = 3
			end
			for param = 0, param_count - 1 do
				local _, param_name = FXManager.r.TrackFX_GetParamName(state.track, fx, param, "")
				if not FXManager.shouldFilterParam(param_name) then
					local value, min_val, max_val = FXManager.r.TrackFX_GetParamEx(state.track, fx, param)
					if not min_val or not max_val then
						min_val, max_val = 0, 1
						value = FXManager.r.TrackFX_GetParam(state.track, fx, param)
					end
					local normalized_value = FXManager.core.normalizeParamValue(value, min_val, max_val)
					local step_count = FXManager.detectParamSteps(fx, param)
					local param_entry = {
						name = param_name,
						current_value = normalized_value,
						base_value = normalized_value,
						min_val = min_val,
						max_val = max_val,
						selected = state.exclusive_xy and true or false,
						fx_id = visible_fx_id,
						param_id = param,
						actual_fx_id = fx,
						step_count = step_count
					}
					fx_entry.params[param] = param_entry
					-- Warm the key cache once (also used by the poll loop) and
					-- register the param for round-robin change polling.
					FXManager.core.getParamKey(visible_fx_id, param)
					state.param_poll_list[#state.param_poll_list + 1] = param_entry
					if state.exclusive_xy then
						local x_key = param_entry.key_x
						local y_key = param_entry.key_y
						if x_key and y_key then
							local is_x_param = ((visible_fx_id + param) % 2) == 0
							state.param_xy_assign[x_key] = is_x_param
							state.param_xy_assign[y_key] = not is_x_param
						end
					end
				end
			end
			visible_fx_id = visible_fx_id + 1
		end
	end
	state.param_poll_idx = 0
	state.modlfo_index = modlfo_index
	state.jsfx_automation_index = bridge_index
	if state.jsfx_automation_enabled and bridge_index < 0 then
		state.jsfx_automation_enabled = false
	end
	state.last_fx_count = fx_count
	state.last_fx_signature = FXManager.core.createFXSignature()
	FXManager.loadTrackSelection()
	FXManager.updateSelectedCount()
	-- Adopt links present on the track that our bookkeeping doesn't know
	-- about (Map flow, standalone panel, lost entries) — badges and toggles
	-- must reflect the real link state.
	if FXManager.link_engine then
		FXManager.link_engine.reconcileModSources()
	end
	-- Chain layout changed: link targets/bridge index may have moved.
	state.links_dirty = true
end

-- Change polling. The old version re-read EVERY param of EVERY FX each tick
-- (50 ms): with a large synth in the chain that is >15k API calls per second
-- and it made the whole REAPER UI sluggish while the script was open. Now:
--   • FX count checked every tick (1 call — catches add/remove instantly)
--   • full name signature only every SIG_INTERVAL (catches replace/reorder)
--   • param values polled round-robin, PARAM_POLL_BUDGET per tick, so the
--     cost per tick is constant no matter how many params the chain has.
local SIG_INTERVAL = 0.25
local PARAM_POLL_BUDGET = 64

function FXManager.checkForFXChanges()
	if not FXManager.core.isTrackValid() then return false end
	local state = FXManager.core.state
	local current_time = FXManager.r.time_precise()
	if current_time - state.last_update_time < state.update_interval then
		return false
	end
	state.last_update_time = current_time

	local current_fx_count = FXManager.r.TrackFX_GetCount(state.track)
	local need_rescan = current_fx_count ~= state.last_fx_count
	if not need_rescan and current_time - (state._last_sig_time or 0) >= SIG_INTERVAL then
		state._last_sig_time = current_time
		need_rescan = FXManager.core.createFXSignature() ~= state.last_fx_signature
	end
	if need_rescan then
		FXManager.scanTrackFX()
		return true
	end

	local changes_detected = false
	for fx_id, fx_data in pairs(state.fx_data) do
		local actual_fx_id = fx_data.actual_fx_id or fx_id
		local current_enabled = FXManager.r.TrackFX_GetEnabled(state.track, actual_fx_id)
		if fx_data.enabled ~= current_enabled then
			fx_data.enabled = current_enabled
			changes_detected = true
		end
	end

	-- NO touch takeover. Grabbing a CP-linked param in the plugin UI is
	-- runtime-confirmed to not reach the own-value storage under parameter
	-- modulation, so takeover can't work — the manager/inspector is the
	-- official base-editing path. Worse, an adoption heuristic here actively
	-- misfires on MIDI-linked params (G slots): the incoming CC both writes
	-- the own storage and marks the param last-touched, so "adopt the drift
	-- of the last-touched param" chases the LFO — base, anchor and baseline
	-- rewritten every tick (the range frame dances). Do not reintroduce.

	-- Selected params refresh EVERY tick: their live (possibly LFO/link
	-- modulated) value is displayed in the param rows, so it must move
	-- smoothly. Capped so "select all" on a huge synth falls back to the
	-- round-robin below instead of re-creating the old full-sweep cost.
	if state.selected_count > 0 and state.selected_count <= 128 then
		for fx_id, fx_data in pairs(state.fx_data) do
			for param_id, param_data in pairs(fx_data.params) do
				if param_data.selected then
					local raw_value = FXManager.r.TrackFX_GetParam(state.track, param_data.actual_fx_id, param_id)
					local current_value = FXManager.core.normalizeParamValue(raw_value, param_data.min_val, param_data.max_val)
					if math.abs(param_data.current_value - current_value) > 0.001 then
						param_data.current_value = current_value
					end
				end
			end
		end
	end

	local poll_list = state.param_poll_list
	if poll_list and #poll_list > 0 then
		local count = #poll_list
		local budget = math.min(PARAM_POLL_BUDGET, count)
		local idx = state.param_poll_idx or 0
		for _ = 1, budget do
			idx = (idx % count) + 1
			local param_data = poll_list[idx]
			local raw_value = FXManager.r.TrackFX_GetParam(state.track, param_data.actual_fx_id, param_data.param_id)
			local current_value = FXManager.core.normalizeParamValue(raw_value, param_data.min_val, param_data.max_val)
			if math.abs(param_data.current_value - current_value) > 0.001 then
				param_data.current_value = current_value
				if not param_data.selected
				   and not (param_data.key and FXManager.core.state.param_mod_source[param_data.key]) then
					param_data.base_value = current_value
				end
			end
		end
		state.param_poll_idx = idx
	end
	return changes_detected
end

function FXManager.updateSelectedCount()
	FXManager.core.state.selected_count = 0
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				FXManager.core.state.selected_count = FXManager.core.state.selected_count + 1
			end
		end
	end
end

function FXManager.selectAllContinuousParams(params, selected)
	for _, param in pairs(params) do
		param.selected = (not param.step_count or param.step_count == 0 or param.step_count > 10) and selected or false
	end
	FXManager.updateSelectedCount()
	FXManager.saveTrackSelection()
end

function FXManager.selectAllParams(params, selected)
	for _, param in pairs(params) do
		param.selected = selected
	end
	FXManager.updateSelectedCount()
	FXManager.saveTrackSelection()
end

function FXManager.getParamRange(fx_id, param_id)
	local key = FXManager.core.getParamKey(fx_id, param_id, "range")
	return key and (FXManager.core.state.param_ranges[key] or 1.0) or 1.0
end

function FXManager.setParamRange(fx_id, param_id, range)
	local key = FXManager.core.getParamKey(fx_id, param_id, "range")
	if key then
		FXManager.core.state.param_ranges[key] = range
		-- The link sweep leaves intact links untouched — push the new depth
		-- to an existing link explicitly.
		if FXManager.link_engine then
			FXManager.link_engine.pushDepth(fx_id, param_id)
		end
		FXManager.saveTrackSelection()
	end
end

function FXManager.getParamInvert(fx_id, param_id)
	local key = FXManager.core.getParamKey(fx_id, param_id, "invert")
	return key and (FXManager.core.state.param_invert[key] or false) or false
end

function FXManager.setParamInvert(fx_id, param_id, invert)
	local key = FXManager.core.getParamKey(fx_id, param_id, "invert")
	if key then
		FXManager.core.state.param_invert[key] = invert
		if FXManager.link_engine then
			FXManager.link_engine.pushDepth(fx_id, param_id)
		end
		FXManager.saveTrackSelection()
	end
end

function FXManager.getParamXYAssign(fx_id, param_id)
	local x_key = FXManager.core.getParamKey(fx_id, param_id, "x")
	local y_key = FXManager.core.getParamKey(fx_id, param_id, "y")
	if not x_key or not y_key then return true, true end
	return FXManager.core.state.param_xy_assign[x_key] ~= false, FXManager.core.state.param_xy_assign[y_key] ~= false
end

function FXManager.setParamXYAssign(fx_id, param_id, axis, value)
	local key = FXManager.core.getParamKey(fx_id, param_id, axis)
	if not key then return end
	FXManager.core.state.param_xy_assign[key] = value
	if FXManager.core.state.exclusive_xy and value then
		local other_axis = axis == "x" and "y" or "x"
		local other_key = FXManager.core.getParamKey(fx_id, param_id, other_axis)
		if other_key then
			FXManager.core.state.param_xy_assign[other_key] = false
		end
	end
	FXManager.saveTrackSelection()
end

function FXManager.captureBaseValues()
	-- Linked mode: bases live in the links' baselines and current_value is
	-- the MODULATED value read back from the plugin — re-anchoring bases on
	-- it would make them drift toward wherever the pad happens to sit.
	if FXManager.core.state.links_active then return end
	FXManager.core.state.param_base_values = {}
	FXManager.core.state.gesture_base_x = FXManager.core.state.gesture_x
	FXManager.core.state.gesture_base_y = FXManager.core.state.gesture_y
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				local key = FXManager.core.getParamKey(fx_id, param_id)
				if key and FXManager.core.state.param_mod_source[key] then
					-- LFO-linked param: current_value is the modulated
					-- readback — re-anchoring on it would randomize the base
					-- with the LFO phase. Keep the stored base as anchor.
					FXManager.core.state.param_base_values[key] = param_data.base_value
				else
					param_data.base_value = param_data.current_value
					if key then
						FXManager.core.state.param_base_values[key] = param_data.current_value
					end
				end
			end
		end
	end
end

function FXManager.updateParamBaseValue(fx_id, param_id, new_value)
	if not FXManager.core.isTrackValid() then return end
	local param_data = FXManager.core.state.fx_data[fx_id].params[param_id]
	if param_data then
		param_data.base_value = new_value
		local key = FXManager.core.getParamKey(fx_id, param_id)
		if key then
			FXManager.core.state.param_base_values[key] = new_value
		end
		if FXManager.link_engine
		   and FXManager.link_engine.isParamLinked(fx_id, param_id, param_data) then
			-- CP-linked param (pad linked mode OR LFO/global in any mode):
			-- the base IS the link baseline; writing the raw param value
			-- changes nothing audible (PM ignores the param's own storage).
			FXManager.link_engine.setBaseline(fx_id, param_id, new_value)
		else
			local actual_fx_id = FXManager.core.state.fx_data[fx_id].actual_fx_id or fx_id
			local denormalized_value = FXManager.core.denormalizeParamValue(new_value, param_data.min_val, param_data.max_val)
			FXManager.r.TrackFX_SetParam(FXManager.core.state.track, actual_fx_id, param_id, denormalized_value)
		end
		param_data.current_value = new_value
		FXManager.saveTrackSelection()
	end
end

-- Batch scope: bulk operations (snapshot/preset load, randomize-all) call
-- setParamRange/XYAssign/Invert once per param, and each of those ends in
-- saveTrackSelection which rebuilds the whole selection table — O(params²)
-- overall. Inside a batch the rebuild is deferred to endBatch.
FXManager._batch_depth = 0
FXManager._batch_dirty = false

function FXManager.beginBatch()
	FXManager._batch_depth = FXManager._batch_depth + 1
end

function FXManager.endBatch()
	FXManager._batch_depth = math.max(0, FXManager._batch_depth - 1)
	if FXManager._batch_depth == 0 and FXManager._batch_dirty then
		FXManager._batch_dirty = false
		FXManager.saveTrackSelection()
	end
end

function FXManager.saveTrackSelection()
	if FXManager._batch_depth > 0 then
		FXManager._batch_dirty = true
		return
	end
	local guid = FXManager.core.getTrackGUID()
	if not guid then return end
	local selection, ranges, xy_assign, invert_assign, fx_rand_max, base_values = {}, {}, {}, {}, {}, {}
	local mod_sources = {}
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		local fx_key = guid .. "_" .. fx_data.full_name
		fx_rand_max[fx_data.full_name] = FXManager.core.state.fx_random_max[fx_key] or 3
		for param_id, param_data in pairs(fx_data.params) do
			local key = fx_data.full_name .. "||" .. param_data.name
			if param_data.selected then
				selection[key] = true
			end
			if param_data.key and FXManager.core.state.param_mod_source[param_data.key] then
				mod_sources[key] = FXManager.core.state.param_mod_source[param_data.key]
			end
			local range_key = guid .. "_" .. key .. "_range"
			local invert_key = guid .. "_" .. key .. "_invert"
			local x_key = guid .. "_" .. key .. "_x"
			local y_key = guid .. "_" .. key .. "_y"
			ranges[key] = FXManager.core.state.param_ranges[range_key] or 1.0
			invert_assign[key] = FXManager.core.state.param_invert[invert_key] or false
			xy_assign[key] = {
				x = FXManager.core.state.param_xy_assign[x_key] ~= false,
				y = FXManager.core.state.param_xy_assign[y_key] ~= false
			}
			base_values[key] = param_data.base_value
		end
	end
	FXManager.core.state.track_selections[guid] = {
		selection = selection,
		ranges = ranges,
		xy_assign = xy_assign,
		invert_assign = invert_assign,
		fx_random_max = fx_rand_max,
		base_values = base_values,
		gesture_base_x = FXManager.core.state.gesture_base_x,
		gesture_base_y = FXManager.core.state.gesture_base_y,
		gesture_x = FXManager.core.state.gesture_x,
		gesture_y = FXManager.core.state.gesture_y,
		current_preset = FXManager.core.state.current_loaded_preset,
		linked = FXManager.core.state.linked_mode,
		mod_sources = mod_sources
	}
	-- Everything that changes selection/range/invert/assign/base funnels
	-- through here — single chokepoint to re-sync native links.
	FXManager.core.state.links_dirty = true
	FXManager.persistence.scheduleTrackSave()
end

function FXManager.loadTrackSelection()
	local guid = FXManager.core.getTrackGUID()
	if not guid then return end
	-- Re-read track_selections from ExtState so cross-process writes (e.g. by
	-- the standalone FX Browser) become visible without a script restart —
	-- but ONLY when no local edits are waiting for the save debounce: the
	-- ExtState lags memory by up to 0.75 s, and adopting it mid-debounce
	-- rolled back everything edited since the last flush (a range drag, a
	-- selection, a mod_source — leaving its native link orphaned).
	local pers = FXManager.persistence
	if pers and pers.deserialize
	   and not (pers.save_flags and pers.save_flags.track_selections) then
		local saved = FXManager.r.GetExtState("CP_FXConstellation", "track_selections")
		if saved and saved ~= "" then
			local fresh = pers.deserialize(saved)
			if type(fresh) == "table" then
				FXManager.core.state.track_selections = fresh
			end
		end
	end
	local track_data = FXManager.core.state.track_selections[guid]
	if not track_data then
		FXManager.core.state.current_loaded_preset = ""
		FXManager.core.state.linked_mode = false
		FXManager.captureBaseValues()
		return
	end
	local selection = track_data.selection or {}
	local ranges = track_data.ranges or {}
	local xy_assign = track_data.xy_assign or {}
	local invert_assign = track_data.invert_assign or {}
	local fx_rand_max = track_data.fx_random_max or {}
	local mod_sources = track_data.mod_sources or {}
	local base_values = track_data.base_values or {}
	FXManager.core.state.gesture_base_x = track_data.gesture_base_x or 0.5
	FXManager.core.state.gesture_base_y = track_data.gesture_base_y or 0.5
	FXManager.core.state.gesture_x = track_data.gesture_x or 0.5
	FXManager.core.state.gesture_y = track_data.gesture_y or 0.5
	FXManager.core.state.current_loaded_preset = track_data.current_preset or ""
	FXManager.core.state.linked_mode = track_data.linked or false

	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		local fx_key = guid .. "_" .. fx_data.full_name
		if fx_rand_max[fx_data.full_name] then
			FXManager.core.state.fx_random_max[fx_key] = fx_rand_max[fx_data.full_name]
		end
		for param_id, param_data in pairs(fx_data.params) do
			local key = fx_data.full_name .. "||" .. param_data.name
			param_data.selected = selection[key] or false
			param_data.base_value = base_values[key] or param_data.current_value
			if param_data.key then
				FXManager.core.state.param_mod_source[param_data.key] = mod_sources[key]
			end
			local range_key = guid .. "_" .. key .. "_range"
			FXManager.core.state.param_ranges[range_key] = ranges[key] or 1.0
			local invert_key = guid .. "_" .. key .. "_invert"
			FXManager.core.state.param_invert[invert_key] = invert_assign[key] or false
			local xy = xy_assign[key]
			local x_key = guid .. "_" .. key .. "_x"
			local y_key = guid .. "_" .. key .. "_y"
			if xy then
				FXManager.core.state.param_xy_assign[x_key] = xy.x
				FXManager.core.state.param_xy_assign[y_key] = xy.y
			else
				FXManager.core.state.param_xy_assign[x_key] = true
				FXManager.core.state.param_xy_assign[y_key] = true
			end
		end
	end
	FXManager.updateSelectedCount()
end

function FXManager.randomSelectParams(params, fx_id)
	FXManager.selectAllParams(params, false)
	local param_list = {}
	for id, param in pairs(params) do
		table.insert(param_list, param)
	end
	if #param_list == 0 then return end
	local fx_key = FXManager.core.getFXKey(fx_id)
	local max_count = (fx_key and FXManager.core.state.fx_random_max[fx_key]) or 3
	local count = math.random(1, math.min(max_count, #param_list))
	for i = 1, count do
		local idx = math.random(1, #param_list)
		param_list[idx].selected = true
		table.remove(param_list, idx)
	end
	FXManager.updateSelectedCount()
	FXManager.captureBaseValues()
	FXManager.saveTrackSelection()
end

function FXManager.randomizeBaseValues(params, fx_id)
	if not FXManager.core.isTrackValid() then return end
	local actual_fx_id = FXManager.core.state.fx_data[fx_id] and FXManager.core.state.fx_data[fx_id].actual_fx_id or fx_id
	for param_id, param_data in pairs(params) do
		if param_data.selected then
			local new_base = math.random()
			param_data.base_value = new_base
			local key = FXManager.core.getParamKey(fx_id, param_id)
			if key then
				FXManager.core.state.param_base_values[key] = new_base
			end
			local denormalized_value = FXManager.core.denormalizeParamValue(new_base, param_data.min_val, param_data.max_val)
			FXManager.r.TrackFX_SetParam(FXManager.core.state.track, actual_fx_id, param_id, denormalized_value)
			param_data.current_value = new_base
			-- Intact links keep their baseline unless pushed explicitly.
			if FXManager.link_engine
			   and FXManager.link_engine.isParamLinked(fx_id, param_id, param_data) then
				FXManager.link_engine.setBaseline(fx_id, param_id, new_base)
			end
		end
	end
	FXManager.saveTrackSelection()
end

function FXManager.randomizeAllBases()
	if not FXManager.core.isTrackValid() then return end
	FXManager.r.Undo_BeginBlock()
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		if not fx_data.full_name:find("Sound Generator") then
			for param_id, param_data in pairs(fx_data.params) do
				if param_data.selected then
					local center_val = (FXManager.core.state.randomize_min + FXManager.core.state.randomize_max) / 2
					local range_val = (FXManager.core.state.randomize_max - FXManager.core.state.randomize_min) / 2
					local rand_offset = (math.random() * 2 - 1) * range_val * FXManager.core.state.randomize_intensity
					local new_base = math.max(FXManager.core.state.randomize_min, math.min(FXManager.core.state.randomize_max, center_val + rand_offset))
					param_data.base_value = new_base
					local key = FXManager.core.getParamKey(fx_id, param_id)
					if key then
						FXManager.core.state.param_base_values[key] = new_base
					end
					local actual_fx_id = fx_data.actual_fx_id or fx_id
					local denormalized_value = FXManager.core.denormalizeParamValue(new_base, param_data.min_val, param_data.max_val)
					FXManager.r.TrackFX_SetParam(FXManager.core.state.track, actual_fx_id, param_id, denormalized_value)
					param_data.current_value = new_base
					if FXManager.link_engine
					   and FXManager.link_engine.isParamLinked(fx_id, param_id, param_data) then
						FXManager.link_engine.setBaseline(fx_id, param_id, new_base)
					end
				end
			end
		end
	end
	FXManager.r.Undo_EndBlock("Randomize all bases", -1)
	FXManager.captureBaseValues()
	FXManager.saveTrackSelection()
end

-- Global LFO slots eligible for random assignment, encoded for
-- param_mod_source (GLOBAL_SLOT_BASE + 1..8). Only slots that are ON: a
-- link to a muted slot freezes the param instead of modulating it — the
-- user picks which LFOs participate by enabling them in the Global tab.
local function enabledGlobalSlots()
	local le = FXManager.link_engine
	if not le then return nil end
	local slots = nil
	for i = 1, le.modjsfx.SLOTS do
		local slot = le.getGlobalSlot(i)
		if slot and slot.on then
			slots = slots or {}
			slots[#slots + 1] = le.GLOBAL_SLOT_BASE + i
		end
	end
	return slots
end

function FXManager.randomizeXYAssign(params, fx_id)
	local le = FXManager.link_engine
	FXManager.beginBatch()
	for param_id, param_data in pairs(params) do
		if param_data.selected then
			-- LFO-routed params belong to the LFO randomizer (its own
			-- button) — the XY roll only re-rolls pad-driven params and
			-- never strips a modulation routing.
			if not (le and le.getParamModSource(fx_id, param_id) > 0) then
				FXManager.randomizeXYAssignOne(fx_id, param_id)
			end
		end
	end
	FXManager.endBatch()
end

-- Random modulation sources (the "LFO" randomizer button): each selected
-- param rolls against random_lfo_probability — hit → a random ENABLED
-- global slot (G1-8), miss → back to the pad (existing X/Y assignment).
-- 0% therefore clears all LFO routings, 100% routes everything.
function FXManager.globalRandomLFOAssign()
	local s = FXManager.core.state
	local le = FXManager.link_engine
	if not le then return end
	local p = s.random_lfo_probability or 0
	local lfo_slots = nil
	if p > 0 then
		-- Fresh banks have slot 1 ON; the user picks the participating
		-- LFOs by enabling slots in the Global tab.
		le.ensureGlobalMIDI()
		lfo_slots = enabledGlobalSlots()
	end
	FXManager.beginBatch()
	for fx_id, fx_data in pairs(s.fx_data) do
		if not fx_data.full_name:find("Sound Generator") then
			for param_id, param_data in pairs(fx_data.params) do
				if param_data.selected then
					if lfo_slots and math.random() < p then
						le.setParamModSource(fx_id, param_id,
							lfo_slots[math.random(#lfo_slots)])
					elseif le.getParamModSource(fx_id, param_id) > 0 then
						-- Back to the pad: the sweep never releases a link
						-- whose mod_source entry is gone (Map-made links
						-- look the same), so release explicitly.
						le.releaseParamLink(fx_id, param_id)
						le.setParamModSource(fx_id, param_id, 0)
					end
				end
			end
		end
	end
	FXManager.endBatch()
end

function FXManager.randomizeXYAssignOne(fx_id, param_id)
	local rand = math.random()
	if FXManager.core.state.exclusive_xy then
		FXManager.setParamXYAssign(fx_id, param_id, "x", rand < 0.5)
		FXManager.setParamXYAssign(fx_id, param_id, "y", rand >= 0.5)
	else
		if rand < 0.33 then
			FXManager.setParamXYAssign(fx_id, param_id, "x", true)
			FXManager.setParamXYAssign(fx_id, param_id, "y", false)
		elseif rand < 0.66 then
			FXManager.setParamXYAssign(fx_id, param_id, "x", false)
			FXManager.setParamXYAssign(fx_id, param_id, "y", true)
		else
			FXManager.setParamXYAssign(fx_id, param_id, "x", true)
			FXManager.setParamXYAssign(fx_id, param_id, "y", true)
		end
	end
end

function FXManager.globalRandomInvert()
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		if not fx_data.full_name:find("Sound Generator") then
			for param_id, param_data in pairs(fx_data.params) do
				if param_data.selected then
					FXManager.setParamInvert(fx_id, param_id, math.random() < 0.5)
				end
			end
		end
	end
end

function FXManager.globalRandomXYAssign()
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		if not fx_data.full_name:find("Sound Generator") then
			FXManager.randomizeXYAssign(fx_data.params, fx_id)
		end
	end
end

function FXManager.randomizeRanges(params, fx_id)
	for param_id, param_data in pairs(params) do
		if param_data.selected then
			local new_range = FXManager.core.state.range_min + math.random() * (FXManager.core.state.range_max - FXManager.core.state.range_min)
			FXManager.setParamRange(fx_id, param_id, new_range)
		end
	end
end

function FXManager.globalRandomRanges()
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		if not fx_data.full_name:find("Sound Generator") then
			FXManager.randomizeRanges(fx_data.params, fx_id)
		end
	end
end

function FXManager.globalRandomSelect()
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		FXManager.selectAllParams(fx_data.params, false)
	end
	local all_params = {}
	for fx_id, fx_data in pairs(FXManager.core.state.fx_data) do
		if not fx_data.full_name:find("Sound Generator") then
			for param_id, param_data in pairs(fx_data.params) do
				table.insert(all_params, param_data)
			end
		end
	end
	if #all_params == 0 then return end
	local count = math.random(FXManager.core.state.random_min, math.min(FXManager.core.state.random_max, #all_params))
	for i = 1, count do
		local idx = math.random(1, #all_params)
		all_params[idx].selected = true
		table.remove(all_params, idx)
	end
	FXManager.updateSelectedCount()
	FXManager.captureBaseValues()
	FXManager.saveTrackSelection()
end

function FXManager.ultraRandom()
	local urs = FXManager.core.state.ultra_random_settings

	if urs.xy_assignments then
		-- Sources first (some params move pad↔LFO), then the XY roll for
		-- whatever ends up pad-driven. The LFO roll is gated by its own
		-- probability slider (0% = strip nothing, keep hand-made routings).
		if FXManager.core.state.random_lfo_probability
		   and FXManager.core.state.random_lfo_probability > 0 then
			FXManager.globalRandomLFOAssign()
		end
		FXManager.globalRandomXYAssign()
	end

	if urs.invert then
		FXManager.globalRandomInvert()
	end

	if urs.bases then
		FXManager.randomizeAllBases()
	end

	if urs.ranges then
		FXManager.globalRandomRanges()
	end

	if urs.bypass then
		FXManager.randomBypassFX()
	end

	if urs.fx_order then
		FXManager.randomizeFXOrder()
	end

	if urs.sound_frequency and FXManager.core.state.sound_generator.enabled then
		local sg = FXManager.core.state.sound_generator
		local freq_min_log = math.log(20)
		local freq_max_log = math.log(20000)
		for _, osc in ipairs(sg.osc) do
			if osc.on then
				local random_freq_log = freq_min_log + math.random() * (freq_max_log - freq_min_log)
				osc.freq = math.exp(random_freq_log)
			end
		end
		if FXManager.soundgen then
			FXManager.soundgen.updateJSFXParams()
		end
	end

	FXManager.captureBaseValues()
end

function FXManager.randomizeFXOrder()
	if not FXManager.core.isTrackValid() then return end
	local fx_count = FXManager.r.TrackFX_GetCount(FXManager.core.state.track)
	if fx_count < 2 then return end
	FXManager.saveTrackSelection()
	FXManager.r.Undo_BeginBlock()

	local start_index = FXManager.core.state.sound_generator.enabled and 1 or 0

	for i = fx_count - 1, start_index + 1, -1 do
		local _, fx_name_i = FXManager.r.TrackFX_GetFXName(FXManager.core.state.track, i, "")
		if not fx_name_i:find("FX Constellation Bridge") and not fx_name_i:find("Sound Generator")
		   and not fx_name_i:find("CP_Mod", 1, true) then
			local j = math.random(start_index, i - 1)
			local _, fx_name_j = FXManager.r.TrackFX_GetFXName(FXManager.core.state.track, j, "")
			if not fx_name_j:find("FX Constellation Bridge") and not fx_name_j:find("Sound Generator")
			   and not fx_name_j:find("CP_Mod", 1, true) and i ~= j then
				local temp_pos = fx_count
				FXManager.r.TrackFX_CopyToTrack(FXManager.core.state.track, i, FXManager.core.state.track, temp_pos, true)
				FXManager.r.TrackFX_CopyToTrack(FXManager.core.state.track, j, FXManager.core.state.track, i, true)
				FXManager.r.TrackFX_CopyToTrack(FXManager.core.state.track, temp_pos, FXManager.core.state.track, j, true)
			end
		end
	end
	FXManager.r.Undo_EndBlock("Randomize FX order", -1)
	FXManager.scanTrackFX()
end

function FXManager.randomBypassFX()
	if not FXManager.core.isTrackValid() then return end
	local fx_count = FXManager.r.TrackFX_GetCount(FXManager.core.state.track)
	if fx_count == 0 then return end
	FXManager.r.Undo_BeginBlock()
	for fx_id = 0, fx_count - 1 do
		local _, fx_name = FXManager.r.TrackFX_GetFXName(FXManager.core.state.track, fx_id, "")
		if not fx_name:find("FX Constellation Bridge") and not fx_name:find("Sound Generator")
		   and not fx_name:find("CP_Mod", 1, true) then
			local should_bypass = math.random() < FXManager.core.state.random_bypass_percentage
			FXManager.r.TrackFX_SetEnabled(FXManager.core.state.track, fx_id, not should_bypass)
		end
	end
	FXManager.r.Undo_EndBlock("Random bypass FX", -1)
	FXManager.scanTrackFX()
end

function FXManager.buildFXName(plugin)
	if not plugin then return "" end

	local fx_name = plugin.name
	local plugin_type = plugin.type
	local is_instrument = plugin.instrument

	if plugin_type == "VST3" then
		if is_instrument then
			fx_name = "VST3i: " .. fx_name
		else
			fx_name = "VST3: " .. fx_name
		end
	elseif plugin_type == "VST" then
		if is_instrument then
			fx_name = "VSTi: " .. fx_name
		else
			fx_name = "VST: " .. fx_name
		end
	elseif plugin_type == "JS" then
		fx_name = "JS: " .. fx_name
	end

	return fx_name
end

function FXManager.addFXByName(fx_name, open_ui, insert_at_end)
	if not FXManager.core.isTrackValid() then return false end
	if not fx_name or fx_name == "" then return false end

	if open_ui == nil then open_ui = false end
	if insert_at_end == nil then insert_at_end = true end

	FXManager.r.Undo_BeginBlock()
	local fx_count = FXManager.r.TrackFX_GetCount(FXManager.core.state.track)
	local recFX = false
	local insert_pos
	if insert_at_end then
		insert_pos = open_ui and fx_count or (-1000 - fx_count)
	else
		insert_pos = open_ui and 0 or -1000
	end
	local new_fx_id = FXManager.r.TrackFX_AddByName(FXManager.core.state.track, fx_name, recFX, insert_pos)

	if new_fx_id >= 0 then
		FXManager.r.Undo_EndBlock("Add FX: " .. fx_name, -1)
		FXManager.scanTrackFX()
		return true
	else
		FXManager.r.Undo_EndBlock("Add FX failed", -1)
		return false
	end
end

function FXManager.addRandomFX(count, favorites_only)
	if not FXManager.core.isTrackValid() then return false end
	if not count or count <= 0 then return false end
	if not FXManager.fxdatabase then return false end

	local plugins = FXManager.fxdatabase.getRandomPlugins(count, favorites_only)
	if #plugins == 0 then return false end

	FXManager.r.Undo_BeginBlock()
	local added_count = 0

	for _, plugin in ipairs(plugins) do
		local fx_name = FXManager.buildFXName(plugin)
		local fx_count = FXManager.r.TrackFX_GetCount(FXManager.core.state.track)
		local recFX = false
		local insert_pos = -1000 - fx_count
		local fx_id = FXManager.r.TrackFX_AddByName(FXManager.core.state.track, fx_name, recFX, insert_pos)
		if fx_id >= 0 then
			added_count = added_count + 1
		end
	end

	local undo_text = "Add " .. added_count .. " random FX"
	if favorites_only then
		undo_text = undo_text .. " (favorites)"
	end

	FXManager.r.Undo_EndBlock(undo_text, -1)
	FXManager.scanTrackFX()

	return added_count > 0
end

return FXManager
