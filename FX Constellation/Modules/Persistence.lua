local Persistence = {}

function Persistence.init(reaper_api, core, data_path, presets_file)
	Persistence.r = reaper_api
	Persistence.core = core
	Persistence.data_path = data_path
	Persistence.presets_file = presets_file
	Persistence.save_flags = {
		settings = false,
		track_selections = false,
		presets = false
	}
end

function Persistence.serialize(t)
	local function ser(v)
		local vtype = type(v)
		if vtype == "string" then
			return string.format("%q", v)
		elseif vtype == "number" or vtype == "boolean" then
			return tostring(v)
		elseif vtype == "table" then
			local s = "{"
			local first = true
			for k, val in pairs(v) do
				if not first then s = s .. "," end
				first = false
				s = s .. (type(k) == "string" and ("[" .. ser(k) .. "]=") or "") .. ser(val)
			end
			return s .. "}"
		end
		return "nil"
	end
	return ser(t)
end

function Persistence.deserialize(s)
	if s == "" then return {} end
	local f, err = load("return " .. s)
	if f then
		local ok, res = pcall(f)
		if ok then return res end
	end
	return {}
end

function Persistence.ensureDataDirectory()
	local path_parts = {}
	for part in Persistence.data_path:gmatch("[^/]+") do
		table.insert(path_parts, part)
	end
	local current_path = ""
	for i, part in ipairs(path_parts) do
		current_path = current_path .. part .. "/"
		if not Persistence.r.file_exists(current_path) then
			Persistence.r.RecursiveCreateDirectory(current_path, 0)
		end
	end
end

function Persistence.savePresetsToFile()
	if not next(Persistence.core.state.presets) then return end
	Persistence.ensureDataDirectory()
	local file = io.open(Persistence.presets_file, "w")
	if file then
		file:write(Persistence.serialize(Persistence.core.state.presets))
		file:close()
	end
end

function Persistence.loadPresetsFromFile()
	if Persistence.r.file_exists(Persistence.presets_file) then
		local file = io.open(Persistence.presets_file, "r")
		if file then
			local content = file:read("*all")
			file:close()
			if content and content ~= "" then
				Persistence.core.state.presets = Persistence.deserialize(content) or {}
			end
		end
	end
end

function Persistence.loadSettings()
	local state = Persistence.core.state

	local filters_str = Persistence.r.GetExtState("CP_FXConstellation", "filter_keywords")
	if filters_str ~= "" then
		state.filter_keywords = {}
		for word in filters_str:gmatch("[^,]+") do
			table.insert(state.filter_keywords, word)
		end
	else
		state.filter_keywords = { "MIDI", "CC", "midi", "Program", "Bank", "Channel", "Wet", "Dry" }
	end

	local param_filter_saved = Persistence.r.GetExtState("CP_FXConstellation", "param_filter")
	if param_filter_saved ~= "" then
		state.param_filter = param_filter_saved
	end

	local saved_state = Persistence.r.GetExtState("CP_FXConstellation", "state")
	if saved_state ~= "" then
		local loaded = Persistence.deserialize(saved_state)
		if loaded then
			for k, v in pairs(loaded) do
				state[k] = v
			end
		end
	end

	local saved_selections = Persistence.r.GetExtState("CP_FXConstellation", "track_selections")
	if saved_selections ~= "" then
		state.track_selections = Persistence.deserialize(saved_selections) or {}
	end

	Persistence.loadPresetsFromFile()
end

function Persistence.scheduleSave()
	local current_time = Persistence.r.time_precise()
	if current_time - Persistence.core.state.save_cooldown > Persistence.core.state.min_save_interval then
		Persistence.save_flags.settings = true
		Persistence.core.state.save_timer = current_time + 2.0
	end
end

function Persistence.scheduleTrackSave()
	Persistence.save_flags.track_selections = true
end

function Persistence.schedulePresetSave()
	Persistence.save_flags.presets = true
end

function Persistence.checkSave()
	if Persistence.r.time_precise() > Persistence.core.state.save_timer then
		if Persistence.save_flags.settings or Persistence.save_flags.track_selections or Persistence.save_flags.presets then
			Persistence.saveSettings()
			Persistence.save_flags.settings = false
			Persistence.save_flags.track_selections = false
			Persistence.save_flags.presets = false
			Persistence.core.state.save_cooldown = Persistence.r.time_precise()
		end
	end
end

function Persistence.saveSettings()
	local state = Persistence.core.state

	if Persistence.save_flags.settings then
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
			jsfx_automation_enabled = state.jsfx_automation_enabled,
			current_loaded_preset = state.current_loaded_preset,
			random_fx_count = state.random_fx_count,
			random_fx_favorites_only = state.random_fx_favorites_only,
			fxmanager_auto_open = state.fxmanager_auto_open
		}
		Persistence.r.SetExtState("CP_FXConstellation", "state", Persistence.serialize(save_data), false)
	end

	if Persistence.save_flags.track_selections then
		local current_guid = Persistence.core.getTrackGUID()
		if current_guid and state.track_selections[current_guid] then
			local track_data = {}
			track_data[current_guid] = state.track_selections[current_guid]
			Persistence.r.SetExtState("CP_FXConstellation", "track_selections", Persistence.serialize(track_data), false)
		end
	end

	if Persistence.save_flags.presets then
		Persistence.savePresetsToFile()
	end

	if Persistence.save_flags.settings then
		local filters_str = table.concat(state.filter_keywords, ",")
		Persistence.r.SetExtState("CP_FXConstellation", "filter_keywords", filters_str, true)
		Persistence.r.SetExtState("CP_FXConstellation", "param_filter", state.param_filter, true)
	end
end

return Persistence
