local GestureSystem = {}

function GestureSystem.init(reaper_api, core, fxmanager)
	GestureSystem.r = reaper_api
	GestureSystem.core = core
	GestureSystem.fxmanager = fxmanager
end

function GestureSystem.applyGestureToSelection(gx, gy)
	if not GestureSystem.core.isTrackValid() then return end
	-- Linked mode: params follow the bridge through native parameter links
	-- (block rate, audio thread). Applying them from Lua as well would
	-- double-modulate — the pad only writes the bridge sliders.
	if GestureSystem.core.state.links_active then return end
	local offset_x = (gx - GestureSystem.core.state.gesture_base_x) * 2
	local offset_y = (gy - GestureSystem.core.state.gesture_base_y) * 2
	for fx_id, fx_data in pairs(GestureSystem.core.state.fx_data) do
		for param_id, param_data in pairs(fx_data.params) do
			if param_data.selected then
				local param_range = GestureSystem.fxmanager.getParamRange(fx_id, param_id)
				local x_assign, y_assign = GestureSystem.fxmanager.getParamXYAssign(fx_id, param_id)
				local param_invert = GestureSystem.fxmanager.getParamInvert(fx_id, param_id)
				-- The anchor for the whole gesture is param_base_values. If a
				-- param has no captured base yet (e.g. envelope drives the pad
				-- without a prior click), seed it ONCE from the param's base —
				-- never fall through to the live base_value each frame: that
				-- re-anchors on the last applied value and makes params drift
				-- away until they hit the clamp.
				local base_key = GestureSystem.core.getParamKey(fx_id, param_id)
				local base_value = base_key and GestureSystem.core.state.param_base_values[base_key]
				if not base_value then
					base_value = param_data.base_value
					if base_key then
						GestureSystem.core.state.param_base_values[base_key] = base_value
					end
				end
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

-- Bridge v2. Inputs (written by the script, by envelopes, or by anything
-- that modulates them): x_pos / y_pos / slew. Outputs (hidden sliders,
-- recomputed every audio block): x_out / y_out / xy_mix — these are the
-- sources native parameter links point at. The block-rate slew means a
-- 30 Hz script write (or a stepped envelope) reaches the linked plugin
-- params as a continuous glide, bypassing the defer-loop resolution.
GestureSystem.BRIDGE_PARAM_COUNT = 6

function GestureSystem.createAutomationJSFX()
	if not GestureSystem.core.isTrackValid() then return false end
	local jsfx_code = [[desc: FX Constellation Bridge
slider1:x_pos=0.5<0,1,0.001>X Position
slider2:y_pos=0.5<0,1,0.001>Y Position
slider3:slew=0<0,2,0.01>Slew (s)
slider4:x_out=0.5<0,1,0.0001>-X Out (link source)
slider5:y_out=0.5<0,1,0.0001>-Y Out (link source)
slider6:xy_mix=0.5<0,1,0.0001>-XY Mix (link source)

@init
x_out = x_pos;
y_out = y_pos;
xy_mix = (x_out + y_out) * 0.5;

@block
slew > 0.001 ? (
  coef = 1 - exp(-samplesblock / (srate * slew));
  x_out += (x_pos - x_out) * coef;
  y_out += (y_pos - y_out) * coef;
) : (
  x_out = x_pos;
  y_out = y_pos;
);
xy_mix = (x_out + y_out) * 0.5;

@sample
spl0 = spl0;
spl1 = spl1;]]

	-- Reuse an existing bridge instance: TrackFX_AddByName with a negative
	-- instantiate ALWAYS creates a new FX, so blindly adding would stack a
	-- duplicate bridge every time the user re-enables Auto JSFX.
	-- v1 instances (2 sliders, no link outputs) are upgraded in place: the
	-- file is rewritten below, and the instance is dropped and re-added so
	-- REAPER compiles the new slider set. X/Y envelopes on a v1 bridge are
	-- lost in the upgrade — one-time cost, flagged in the UI status line.
	local existing = GestureSystem.findAutomationJSFX()
	if existing >= 0
	   and GestureSystem.r.TrackFX_GetNumParams(GestureSystem.core.state.track, existing) >= GestureSystem.BRIDGE_PARAM_COUNT then
		GestureSystem.core.state.jsfx_automation_index = existing
		GestureSystem.core.state.jsfx_automation_enabled = true
		GestureSystem.syncBridgeState()
		GestureSystem.fxmanager.captureBaseValues()
		return true
	end
	if existing >= 0 then
		GestureSystem.r.TrackFX_Delete(GestureSystem.core.state.track, existing)
	end

	local jsfx_path = GestureSystem.r.GetResourcePath() .. "/Effects/FX Constellation Bridge.jsfx"
	local file = io.open(jsfx_path, "w")
	if file then
		file:write(jsfx_code)
		file:close()
		local fx_index = GestureSystem.r.TrackFX_AddByName(GestureSystem.core.state.track, "FX Constellation Bridge", false, -1)
		if fx_index >= 0 then
			-- Internal JSFX stay closed — never pop a floating window.
			GestureSystem.r.TrackFX_Show(GestureSystem.core.state.track, fx_index, 2)
			GestureSystem.core.state.jsfx_automation_index = fx_index
			GestureSystem.core.state.jsfx_automation_enabled = true
			-- Keep the count coherent with the cached index so the staleness
			-- guard doesn't skip the anchor write below; the 0.25 s signature
			-- pass picks up the full rescan.
			GestureSystem.core.state.last_fx_count = GestureSystem.r.TrackFX_GetCount(GestureSystem.core.state.track)
			-- Anchor the gesture: envelope-driven motion applies relative to
			-- the values captured now, exactly like a pad drag starting here.
			GestureSystem.updateJSFXFromGesture()
			GestureSystem.syncBridgeState()
			GestureSystem.fxmanager.captureBaseValues()
			return true
		end
	end
	return false
end

-- Reset the bidirectional bookkeeping to "in sync with the JSFX right now"
-- so the next read doesn't misinterpret our own write as an envelope move.
function GestureSystem.syncBridgeState()
	local s = GestureSystem.core.state
	if s.jsfx_automation_index < 0 or not GestureSystem.core.isTrackValid() then return end
	s.jsfx_last_x = GestureSystem.r.TrackFX_GetParam(s.track, s.jsfx_automation_index, 0)
	s.jsfx_last_y = GestureSystem.r.TrackFX_GetParam(s.track, s.jsfx_automation_index, 1)
end

-- JSFX → script (envelope playback, MIDI-learn on the bridge sliders, …).
-- Runs only when the script is not itself the source of motion this frame:
-- while the user drags the pad or a navigation mode animates, the script is
-- authoritative and writes to the bridge instead. When the bridge sliders
-- move on their own, the pad cursor ADOPTS the position (bidirectional) and
-- the gesture is applied through the same code path as a manual drag.
local JSFX_EPS = 0.0005

function GestureSystem.updateAutomationFromJSFX()
	local s = GestureSystem.core.state
	if not s.jsfx_automation_enabled or s.jsfx_automation_index < 0 then return end
	if not GestureSystem.core.isTrackValid() then return end

	-- Script-driven this frame → the bridge is an output, not an input.
	if s.gesture_active then return end
	if s.navigation_mode == 1 and s.random_walk_active then return end
	if s.navigation_mode == 2 and s.figures_active then return end

	-- Chain mutated since the last scan → the cached index may point at a
	-- different FX for one frame. Skip; checkForFXChanges rescans right after.
	if GestureSystem.r.TrackFX_GetCount(s.track) ~= s.last_fx_count then return end

	local jsfx_x = GestureSystem.r.TrackFX_GetParam(s.track, s.jsfx_automation_index, 0)
	local jsfx_y = GestureSystem.r.TrackFX_GetParam(s.track, s.jsfx_automation_index, 1)

	local last_x = s.jsfx_last_x or jsfx_x
	local last_y = s.jsfx_last_y or jsfx_y
	if math.abs(jsfx_x - last_x) < JSFX_EPS and math.abs(jsfx_y - last_y) < JSFX_EPS then
		s.jsfx_last_x, s.jsfx_last_y = jsfx_x, jsfx_y
		return
	end
	s.jsfx_last_x, s.jsfx_last_y = jsfx_x, jsfx_y

	-- Adopt the external position: pad dot follows the envelope, and the
	-- smooth-mode target is pinned so manual smoothing doesn't tug it back.
	s.gesture_x, s.gesture_y = jsfx_x, jsfx_y
	s.target_gesture_x, s.target_gesture_y = jsfx_x, jsfx_y

	-- Linked mode: adoption is display-only, the links already applied it.
	if s.links_active then return end

	if s.pad_mode == 1 then
		if not s.granular_grains or #s.granular_grains == 0 then
			GestureSystem.initializeGranularGrid()
		end
		GestureSystem.applyGranularGesture(jsfx_x, jsfx_y)
	else
		GestureSystem.applyGestureToSelection(jsfx_x, jsfx_y)
	end
end

-- Script → JSFX. Skips redundant writes (same value = no automation churn)
-- and records what was written so the read path can tell "our own write"
-- apart from an actual envelope move.
function GestureSystem.updateJSFXFromGesture()
	local s = GestureSystem.core.state
	if not s.jsfx_automation_enabled or s.jsfx_automation_index < 0 then return end
	if not GestureSystem.core.isTrackValid() then return end
	if GestureSystem.r.TrackFX_GetCount(s.track) ~= s.last_fx_count then return end
	local gx, gy = s.gesture_x, s.gesture_y
	if s.jsfx_last_x and math.abs(gx - s.jsfx_last_x) < JSFX_EPS
	   and s.jsfx_last_y and math.abs(gy - s.jsfx_last_y) < JSFX_EPS then
		return
	end
	GestureSystem.r.TrackFX_SetParam(s.track, s.jsfx_automation_index, 0, gx)
	GestureSystem.r.TrackFX_SetParam(s.track, s.jsfx_automation_index, 1, gy)
	s.jsfx_last_x, s.jsfx_last_y = gx, gy
end

-- Beat-sync divisions for jump mode, in quarter notes (4/4 reference):
-- Free (Hz), 1/16, 1/8, 1/4, 1/2, 1 bar.
local JUMP_SYNC_QN = { 0.25, 0.5, 1, 2, 4 }

-- Teleport variant of the random walk: the cursor JUMPS to a random point
-- (no interpolated travel), either at a free rate in Hz (with jitter) or
-- locked to the beat grid while the transport plays.
function GestureSystem.updateRandomJump(current_time)
	local s = GestureSystem.core.state
	local due = false

	if s.random_walk_sync > 0 then
		local qn_mult = JUMP_SYNC_QN[s.random_walk_sync] or 1
		if (GestureSystem.r.GetPlayState() & 1) == 1 then
			-- Playing: quantize to the project beat grid so jumps land on
			-- musical boundaries whatever the tempo map does.
			local qn = GestureSystem.r.TimeMap2_timeToQN(0, GestureSystem.r.GetPlayPosition())
			local slot = math.floor(qn / qn_mult + 1e-9)
			if slot ~= s.random_walk_last_slot then
				s.random_walk_last_slot = slot
				due = true
			end
		else
			-- Stopped: derive the interval from the current tempo.
			local bpm = GestureSystem.r.Master_GetTempo()
			local interval = qn_mult * 60.0 / (bpm > 0 and bpm or 120)
			if current_time >= s.random_walk_next_time then
				s.random_walk_next_time = current_time + interval
				due = true
			end
		end
	else
		if current_time >= s.random_walk_next_time then
			local base_interval = 1.0 / s.random_walk_speed
			local jitter = (math.random() * 2 - 1) * base_interval * s.random_walk_jitter
			s.random_walk_next_time = current_time + math.max(0.05, base_interval + jitter)
			due = true
		end
	end

	if not due then return end

	s.gesture_x = math.random()
	s.gesture_y = math.random()
	s.target_gesture_x, s.target_gesture_y = s.gesture_x, s.gesture_y
	GestureSystem.updateJSFXFromGesture()
	if s.pad_mode == 1 then
		if not s.granular_grains or #s.granular_grains == 0 then
			GestureSystem.initializeGranularGrid()
		end
		GestureSystem.applyGranularGesture(s.gesture_x, s.gesture_y)
	else
		GestureSystem.applyGestureToSelection(s.gesture_x, s.gesture_y)
	end
end

function GestureSystem.updateGestureMotion()
	local current_time = GestureSystem.r.time_precise()
	GestureSystem.updateAutomationFromJSFX()

	if GestureSystem.core.state.navigation_mode == 1 then
		if GestureSystem.core.state.random_walk_active then
			if GestureSystem.core.state.random_walk_jump then
				GestureSystem.updateRandomJump(current_time)
				GestureSystem.core.state.last_smooth_update = current_time
				return
			end
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
		-- Smooth chase runs during the drag too (lazy-cursor feel); the drag
		-- handler only moves the target in smooth mode, so without this the
		-- dot stayed frozen until mouse release.
		if GestureSystem.core.state.smooth_speed > 0 then
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
