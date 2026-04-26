local GestureSystem = {}

function GestureSystem.init(reaper_api, core, fxmanager)
	GestureSystem.r = reaper_api
	GestureSystem.core = core
	GestureSystem.fxmanager = fxmanager
end

function GestureSystem.applyGestureToSelection(gx, gy)
	if not GestureSystem.core.isTrackValid() then return end
	local offset_x = (gx - GestureSystem.core.state.gesture_base_x) * 2
	local offset_y = (gy - GestureSystem.core.state.gesture_base_y) * 2
	for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				local param_range = GestureSystem.fxmanager.getParamRange(fx_id, param_id)
				local x_assign, y_assign = GestureSystem.fxmanager.getParamXYAssign(fx_id, param_id)
				local param_invert = GestureSystem.fxmanager.getParamInvert(fx_id, param_id)
				local base_key = GestureSystem.core.getParamKey(fx_id, param_id)
				local base_value = (base_key and GestureSystem.core.state.param_base_values[base_key]) or param_data.base_value
				local up_range, down_range = GestureSystem.core.calculateAsymmetricRange(base_value, param_range, GestureSystem.core.state.gesture_range, GestureSystem.core.state.gesture_min, GestureSystem.core.state.gesture_max)
				local new_value = base_value
				local x_contribution, y_contribution = 0, 0
				if x_assign then
					local x_offset = param_invert and -offset_x or offset_x
					x_contribution = x_offset > 0 and x_offset * up_range or x_offset * down_range
				end
				if y_assign then
					local y_offset = param_invert and -offset_y or offset_y
					y_contribution = y_offset > 0 and y_offset * up_range or y_offset * down_range
				end
				if x_assign and y_assign then
					new_value = base_value + (x_contribution + y_contribution) / 2
				elseif x_assign then
					new_value = base_value + x_contribution
				elseif y_assign then
					new_value = base_value + y_contribution
				end
				new_value = math.max(GestureSystem.core.state.gesture_min, math.min(GestureSystem.core.state.gesture_max, new_value))
				if param_data.step_count and param_data.step_count > 0 then
					new_value = GestureSystem.core.snapToDiscreteValue(new_value, param_data.step_count)
				end
				local actual_fx_id = fx_data.actual_fx_id or fx_id
				local denormalized_value = GestureSystem.core.denormalizeParamValue(new_value, param_data.min_val, param_data.max_val)
				GestureSystem.r.TrackFX_SetParam(GestureSystem.core.state.track, actual_fx_id, param_id, denormalized_value)
				param_data.current_value = new_value
				param_data.base_value = new_value
			end
		end
	end
end

function GestureSystem.randomizeSelection()
	if not GestureSystem.core.isTrackValid() then return end
	GestureSystem.core.state.last_random_seed = os.time() + math.random(1000)
	math.randomseed(GestureSystem.core.state.last_random_seed)
	for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				local param_range = GestureSystem.fxmanager.getParamRange(fx_id, param_id)
				local up_range, down_range = GestureSystem.core.calculateAsymmetricRange(param_data.base_value, param_range, GestureSystem.core.state.randomize_intensity, GestureSystem.core.state.randomize_min, GestureSystem.core.state.randomize_max)
				local rand = math.random() * 2 - 1
				local variation = rand > 0 and rand * up_range or rand * down_range
				local new_value = math.max(GestureSystem.core.state.randomize_min, math.min(GestureSystem.core.state.randomize_max, param_data.base_value + variation))
				local actual_fx_id = fx_data.actual_fx_id or fx_id
				local denormalized_value = GestureSystem.core.denormalizeParamValue(new_value, param_data.min_val, param_data.max_val)
				GestureSystem.r.TrackFX_SetParam(GestureSystem.core.state.track, actual_fx_id, param_id, denormalized_value)
				param_data.current_value = new_value
				param_data.base_value = new_value
			end
		end
	end
	GestureSystem.fxmanager.captureBaseValues()
	GestureSystem.fxmanager.saveTrackSelection()
end

function GestureSystem.initializeGranularGrid()
	local grid_size = GestureSystem.core.state.granular_grid_size or 3
	GestureSystem.core.state.granular_grains = {}
	for y = 0, grid_size - 1 do
		for x = 0, grid_size - 1 do
			local grain_x = (x + 0.5) / grid_size
			local grain_y = (y + 0.5) / grid_size
			table.insert(GestureSystem.core.state.granular_grains, { x = grain_x, y = grain_y, param_values = {} })
		end
	end
	GestureSystem.randomizeGranularGrid()
end

function GestureSystem.randomizeGranularGrid()
	if not GestureSystem.core.isTrackValid() then return end
	if not GestureSystem.core.state.granular_grains then
		GestureSystem.initializeGranularGrid()
		return
	end
	for _, grain in ipairs(GestureSystem.core.state.granular_grains) do
		if grain then
			grain.param_values = {}
			for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
				grain.param_values[fx_id] = {}
				for param_id, param_data in pairs(fx_data.params) do
					if param_data.selected then
						local min_val = GestureSystem.core.state.gesture_min or 0
						local max_val = GestureSystem.core.state.gesture_max or 1
						grain.param_values[fx_id][param_id] = min_val + math.random() * (max_val - min_val)
					end
				end
			end
		end
	end
end

function GestureSystem.getGrainInfluence(grain_x, grain_y, pos_x, pos_y)
	if not grain_x or not grain_y or not pos_x or not pos_y then return 0 end
	local dx = pos_x - grain_x
	local dy = pos_y - grain_y
	local distance = math.sqrt(dx * dx + dy * dy)
	local grain_radius = 1.0 / GestureSystem.core.state.granular_grid_size
	return math.max(0, 1.0 - (distance / grain_radius))
end

function GestureSystem.applyGranularGesture(gx, gy)
	if not GestureSystem.core.isTrackValid() or not gx or not gy then return end
	if not GestureSystem.core.state.granular_grains or #GestureSystem.core.state.granular_grains == 0 then
		GestureSystem.initializeGranularGrid()
		return
	end

	local total_weights, weighted_param_values = {}, {}
	for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
		total_weights[fx_id] = 0
		weighted_param_values[fx_id] = {}
		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				weighted_param_values[fx_id][param_id] = 0
			end
		end
	end

	for _, grain in ipairs(GestureSystem.core.state.granular_grains) do
		if grain and grain.x and grain.y then
			local influence = GestureSystem.getGrainInfluence(grain.x, grain.y, gx, gy)
			if influence > 0 then
				for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
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

	for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
		if total_weights[fx_id] and total_weights[fx_id] > 0 then
			for param_id, param_data in pairs(fx_data.params) do
				if param_data.selected and weighted_param_values[fx_id][param_id] then
					local final_value = weighted_param_values[fx_id][param_id] / total_weights[fx_id]
					local actual_fx_id = fx_data.actual_fx_id or fx_id
					local denormalized_value = GestureSystem.core.denormalizeParamValue(final_value, param_data.min_val, param_data.max_val)
					GestureSystem.r.TrackFX_SetParam(GestureSystem.core.state.track, actual_fx_id, param_id, denormalized_value)
					param_data.current_value = final_value
					param_data.base_value = final_value
					local key = GestureSystem.core.getParamKey(fx_id, param_id)
					if key then
						GestureSystem.core.state.param_base_values[key] = final_value
					end
				end
			end
		end
	end
end

function GestureSystem.calculateFiguresPosition(time)
	local angle = time * GestureSystem.core.state.figures_speed * 2 * math.pi
	local size = GestureSystem.core.state.figures_size

	if GestureSystem.core.state.figures_mode == 0 then
		return 0.5 + (size * 0.5) * math.cos(angle), 0.5 + (size * 0.5) * math.sin(angle)
	elseif GestureSystem.core.state.figures_mode == 1 then
		local progress = (angle / (2 * math.pi)) % 1
		local half_size = size * 0.5
		local x, y
		if progress < 0.25 then
			local t = progress * 4
			x, y = 0.5 - half_size + t * size, 0.5 - half_size
		elseif progress < 0.5 then
			local t = (progress - 0.25) * 4
			x, y = 0.5 + half_size, 0.5 - half_size + t * size
		elseif progress < 0.75 then
			local t = (progress - 0.5) * 4
			x, y = 0.5 + half_size - t * size, 0.5 + half_size
		else
			local t = (progress - 0.75) * 4
			x, y = 0.5 - half_size, 0.5 + half_size - t * size
		end
		return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
	elseif GestureSystem.core.state.figures_mode == 2 then
		local progress = (angle / (2 * math.pi)) % 1
		local half_size = size * 0.5
		local x, y
		if progress < 0.33 then
			local t = progress * 3
			x, y = 0.5, 0.5 - half_size + t * half_size
		elseif progress < 0.66 then
			local t = (progress - 0.33) * 3
			x, y = 0.5 - t * size, 0.5 + half_size
		else
			local t = (progress - 0.66) * 3
			x, y = 0.5 - half_size + t * size, 0.5 + half_size - t * half_size
		end
		return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
	elseif GestureSystem.core.state.figures_mode == 3 then
		local progress = (angle / (2 * math.pi)) % 1
		local half_size = size * 0.5
		local x, y
		if progress < 0.25 then
			local t = progress * 4
			x, y = 0.5 - half_size + t * half_size, 0.5 + t * half_size
		elseif progress < 0.5 then
			local t = (progress - 0.25) * 4
			x, y = 0.5 + t * half_size, 0.5 + half_size - t * half_size
		elseif progress < 0.75 then
			local t = (progress - 0.5) * 4
			x, y = 0.5 + half_size - t * half_size, 0.5 - t * half_size
		else
			local t = (progress - 0.75) * 4
			x, y = 0.5 - t * half_size, 0.5 - half_size + t * half_size
		end
		return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
	elseif GestureSystem.core.state.figures_mode == 4 then
		local progress = (angle / (2 * math.pi)) % 1
		local half_size = size * 0.5
		local x, y
		if progress < 0.25 then
			local t = progress * 4
			x, y = 0.5 - half_size + t * size, 0.5 + half_size
		elseif progress < 0.5 then
			local t = (progress - 0.25) * 4
			x, y = 0.5 + half_size - t * size, 0.5 + half_size - t * size
		elseif progress < 0.75 then
			local t = (progress - 0.5) * 4
			x, y = 0.5 - half_size + t * size, 0.5 - half_size
		else
			local t = (progress - 0.75) * 4
			x, y = 0.5 + half_size - t * size, 0.5 - half_size + t * size
		end
		return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
	elseif GestureSystem.core.state.figures_mode == 5 then
		local scale = size * 0.4
		local x = 0.5 + scale * math.sin(angle) / (1 + math.cos(angle) * math.cos(angle))
		local y = 0.5 + scale * math.sin(angle) * math.cos(angle) / (1 + math.cos(angle) * math.cos(angle))
		return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
	end

	return 0.5, 0.5
end

function GestureSystem.bezierCurve(t, p0, p1, p2, p3)
	local u = 1 - t
	local tt, uu = t * t, u * u
	local ttt, uuu = tt * t, uu * u
	local x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x
	local y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y
	return x, y
end

function GestureSystem.generateRandomWalkControlPoints()
	local current = { x = GestureSystem.core.state.gesture_x, y = GestureSystem.core.state.gesture_y }
	local target = { x = math.random(), y = math.random() }
	local dx, dy = target.x - current.x, target.y - current.y

	local control1 = {
		x = math.max(0, math.min(1, current.x + dx * 0.3 + (math.random() - 0.5) * 0.2)),
		y = math.max(0, math.min(1, current.y + dy * 0.3 + (math.random() - 0.5) * 0.2))
	}
	local control2 = {
		x = math.max(0, math.min(1, current.x + dx * 0.7 + (math.random() - 0.5) * 0.2)),
		y = math.max(0, math.min(1, current.y + dy * 0.7 + (math.random() - 0.5) * 0.2))
	}

	GestureSystem.core.state.random_walk_control_points = { p0 = current, p1 = control1, p2 = control2, p3 = target }
	GestureSystem.core.state.random_walk_bezier_progress = 0
	GestureSystem.core.state.target_gesture_x = target.x
	GestureSystem.core.state.target_gesture_y = target.y
end

function GestureSystem.findAutomationJSFX()
	if not GestureSystem.core.isTrackValid() then return -1 end
	local fx_count = GestureSystem.r.TrackFX_GetCount(GestureSystem.core.state.track)
	for fx_id = 0, fx_count - 1 do
		local _, fx_name = GestureSystem.r.TrackFX_GetFXName(GestureSystem.core.state.track, fx_id, "")
		if fx_name:find("FX Constellation Bridge") then
			return fx_id
		end
	end
	return -1
end

function GestureSystem.createAutomationJSFX()
	if not GestureSystem.core.isTrackValid() then return false end
	local jsfx_code = [[desc: FX Constellation Bridge
slider1:x_pos=0.5<0,1,0.001>X Position
slider2:y_pos=0.5<0,1,0.001>Y Position

@sample
spl0 = spl0;
spl1 = spl1;]]

	local jsfx_path = GestureSystem.r.GetResourcePath() .. "/Effects/FX Constellation Bridge.jsfx"
	local file = io.open(jsfx_path, "w")
	if file then
		file:write(jsfx_code)
		file:close()
		local fx_index = GestureSystem.r.TrackFX_AddByName(GestureSystem.core.state.track, "FX Constellation Bridge", false, -1)
		if fx_index >= 0 then
			GestureSystem.core.state.jsfx_automation_index = fx_index
			GestureSystem.core.state.jsfx_automation_enabled = true
			return true
		end
	end
	return false
end

function GestureSystem.updateAutomationFromJSFX()
	if not GestureSystem.core.state.jsfx_automation_enabled or GestureSystem.core.state.jsfx_automation_index < 0 then return end
	if not GestureSystem.core.isTrackValid() then return end

	local jsfx_x = GestureSystem.r.TrackFX_GetParam(GestureSystem.core.state.track, GestureSystem.core.state.jsfx_automation_index, 0)
	local jsfx_y = GestureSystem.r.TrackFX_GetParam(GestureSystem.core.state.track, GestureSystem.core.state.jsfx_automation_index, 1)

	if GestureSystem.core.state.pad_mode == 1 then
		if not GestureSystem.core.state.granular_grains or #GestureSystem.core.state.granular_grains == 0 then
			GestureSystem.initializeGranularGrid()
		end
		GestureSystem.applyGranularGesture(jsfx_x, jsfx_y)
	else
		GestureSystem.applyGestureToSelection(jsfx_x, jsfx_y)
	end
end

function GestureSystem.updateJSFXFromGesture()
	if not GestureSystem.core.state.jsfx_automation_enabled or GestureSystem.core.state.jsfx_automation_index < 0 then return end
	if not GestureSystem.core.isTrackValid() then return end
	GestureSystem.r.TrackFX_SetParam(GestureSystem.core.state.track, GestureSystem.core.state.jsfx_automation_index, 0, GestureSystem.core.state.gesture_x)
	GestureSystem.r.TrackFX_SetParam(GestureSystem.core.state.track, GestureSystem.core.state.jsfx_automation_index, 1, GestureSystem.core.state.gesture_y)
end

function GestureSystem.updateGestureMotion()
	local current_time = GestureSystem.r.time_precise()
	GestureSystem.updateAutomationFromJSFX()

	if GestureSystem.core.state.navigation_mode == 1 then
		if GestureSystem.core.state.random_walk_active then
			if current_time >= GestureSystem.core.state.random_walk_next_time then
				GestureSystem.generateRandomWalkControlPoints()
				local base_interval = 1.0 / GestureSystem.core.state.random_walk_speed
				local jitter_amount = base_interval * GestureSystem.core.state.random_walk_jitter
				local jitter = (math.random() * 2 - 1) * jitter_amount
				GestureSystem.core.state.random_walk_next_time = current_time + base_interval + jitter
				GestureSystem.core.state.random_walk_last_time = current_time
			end

			if GestureSystem.core.state.random_walk_control_points and GestureSystem.core.state.random_walk_control_points.p0 then
				local duration = GestureSystem.core.state.random_walk_next_time - GestureSystem.core.state.random_walk_last_time
				local elapsed = current_time - GestureSystem.core.state.random_walk_last_time
				local progress = math.min(1.0, elapsed / duration)
				GestureSystem.core.state.random_walk_bezier_progress = progress
				local x, y = GestureSystem.bezierCurve(progress,
					GestureSystem.core.state.random_walk_control_points.p0,
					GestureSystem.core.state.random_walk_control_points.p1,
					GestureSystem.core.state.random_walk_control_points.p2,
					GestureSystem.core.state.random_walk_control_points.p3)

				GestureSystem.core.state.gesture_x = x
				GestureSystem.core.state.gesture_y = y
				GestureSystem.updateJSFXFromGesture()

				if GestureSystem.core.state.pad_mode == 1 then
					if not GestureSystem.core.state.granular_grains or #GestureSystem.core.state.granular_grains == 0 then
						GestureSystem.initializeGranularGrid()
					end
					GestureSystem.applyGranularGesture(GestureSystem.core.state.gesture_x, GestureSystem.core.state.gesture_y)
				else
					GestureSystem.applyGestureToSelection(GestureSystem.core.state.gesture_x, GestureSystem.core.state.gesture_y)
				end
			end
		end
	elseif GestureSystem.core.state.navigation_mode == 2 then
		if GestureSystem.core.state.figures_active then
			GestureSystem.core.state.figures_time = GestureSystem.core.state.figures_time + (current_time - (GestureSystem.core.state.last_figures_update or current_time))
			local x, y = GestureSystem.calculateFiguresPosition(GestureSystem.core.state.figures_time)
			GestureSystem.core.state.gesture_x = x
			GestureSystem.core.state.gesture_y = y
			GestureSystem.updateJSFXFromGesture()

			if GestureSystem.core.state.pad_mode == 1 then
				if not GestureSystem.core.state.granular_grains or #GestureSystem.core.state.granular_grains == 0 then
					GestureSystem.initializeGranularGrid()
				end
				GestureSystem.applyGranularGesture(GestureSystem.core.state.gesture_x, GestureSystem.core.state.gesture_y)
			else
				GestureSystem.applyGestureToSelection(GestureSystem.core.state.gesture_x, GestureSystem.core.state.gesture_y)
			end
		end
		GestureSystem.core.state.last_figures_update = current_time
	else
		if not GestureSystem.core.state.gesture_active and GestureSystem.core.state.smooth_speed > 0 then
			local dx = GestureSystem.core.state.target_gesture_x - GestureSystem.core.state.gesture_x
			local dy = GestureSystem.core.state.target_gesture_y - GestureSystem.core.state.gesture_y
			local distance = math.sqrt(dx * dx + dy * dy)
			if distance > 0.001 then
				local max_distance = GestureSystem.core.state.max_gesture_speed * (current_time - (GestureSystem.core.state.last_smooth_update or current_time))
				if distance > max_distance then
					dx = dx / distance * max_distance
					dy = dy / distance * max_distance
				end
				GestureSystem.core.state.gesture_x = GestureSystem.core.state.gesture_x + dx * GestureSystem.core.state.smooth_speed
				GestureSystem.core.state.gesture_y = GestureSystem.core.state.gesture_y + dy * GestureSystem.core.state.smooth_speed
				if GestureSystem.core.state.pad_mode == 1 then
					if not GestureSystem.core.state.granular_grains or #GestureSystem.core.state.granular_grains == 0 then
						GestureSystem.initializeGranularGrid()
					end
					GestureSystem.applyGranularGesture(GestureSystem.core.state.gesture_x, GestureSystem.core.state.gesture_y)
				else
					GestureSystem.applyGestureToSelection(GestureSystem.core.state.gesture_x, GestureSystem.core.state.gesture_y)
				end
			end
		end
	end
	GestureSystem.core.state.last_smooth_update = current_time
end

function GestureSystem.captureToMorph(slot)
	local preset = {}
	for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
		preset[fx_data.full_name] = { enabled = fx_data.enabled, params = {} }
		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				preset[fx_data.full_name].params[param_data.name] = param_data.current_value
			end
		end
	end
	if slot == 1 then
		GestureSystem.core.state.morph_preset_a = preset
	else
		GestureSystem.core.state.morph_preset_b = preset
	end
end

function GestureSystem.morphBetweenPresets(amount)
	if not GestureSystem.core.state.morph_preset_a or not GestureSystem.core.state.morph_preset_b or not GestureSystem.core.isTrackValid() then return end
	for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
		local preset_a = GestureSystem.core.state.morph_preset_a[fx_data.full_name]
		local preset_b = GestureSystem.core.state.morph_preset_b[fx_data.full_name]
		if preset_a and preset_b then
			local params_a = preset_a.params or preset_a
			local params_b = preset_b.params or preset_b
			for param_id, param_data in pairs(fx_data.params) do
				local value_a = params_a[param_data.name]
				local value_b = params_b[param_data.name]
				if value_a and value_b then
					local morphed_value = value_a * (1 - amount) + value_b * amount
					local actual_fx_id = fx_data.actual_fx_id or fx_id
					local denormalized_value = GestureSystem.core.denormalizeParamValue(morphed_value, param_data.min_val, param_data.max_val)
					GestureSystem.r.TrackFX_SetParam(GestureSystem.core.state.track, actual_fx_id, param_id, denormalized_value)
					param_data.current_value = morphed_value
				end
			end
		end
	end
end

return GestureSystem
