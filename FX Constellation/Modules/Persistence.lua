local Persistence = {}

function Persistence.init(reaper_api, core, data_path, presets_file)
	Persistence.r = reaper_api
	Persistence.core = core
	Persistence.data_path = data_path
	Persistence.presets_file = presets_file
	Persistence.settings_file = data_path .. "settings.dat"
	Persistence._presets_loaded = false
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
		elseif vtype == "number" then
			return string.format("%.17g", v)
		elseif vtype == "boolean" then
			return tostring(v)
		elseif vtype == "table" then
			local s = "{"
			local first = true
			for k, val in pairs(v) do
				if not first then s = s .. "," end
				first = false
				s = s .. "[" .. ser(k) .. "]=" .. ser(val)
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
	-- Writing an empty table is legitimate (deleting the last preset must
	-- stick — the old guard made it reappear on restart); only refuse when
	-- the file was never loaded, so a save can't wipe unread data.
	if not Persistence._presets_loaded then return end
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
	Persistence._presets_loaded = true
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

	-- ExtState is written with persist=false (RAM only — it doubles as the
	-- cross-process channel for the FX Browser), so it only survives within
	-- a REAPER session. The settings file is the durable copy: prefer the
	-- ExtState when present (fresher), fall back to the file after a REAPER
	-- restart.
	local file_data = nil
	if Persistence.r.file_exists(Persistence.settings_file) then
		local file = io.open(Persistence.settings_file, "r")
		if file then
			local content = file:read("*all")
			file:close()
			if content and content ~= "" then
				file_data = Persistence.deserialize(content)
			end
		end
	end

	local saved_state = Persistence.r.GetExtState("CP_FXConstellation", "state")
	local loaded = nil
	if saved_state ~= "" then
		loaded = Persistence.deserialize(saved_state)
	end
	if (not loaded or not next(loaded)) and file_data and type(file_data.state) == "table" then
		loaded = file_data.state
	end
	if loaded then
		for k, v in pairs(loaded) do
			state[k] = v
		end
	end

	local saved_selections = Persistence.r.GetExtState("CP_FXConstellation", "track_selections")
	if saved_selections ~= "" then
		state.track_selections = Persistence.deserialize(saved_selections) or {}
	elseif file_data and type(file_data.track_selections) == "table" then
		state.track_selections = file_data.track_selections
		-- Seed the cross-process channel so the FX Browser sees the same
		-- selections without needing this script to save first.
		Persistence.r.SetExtState("CP_FXConstellation", "track_selections",
			Persistence.serialize(state.track_selections), false)
	end

	Persistence.loadPresetsFromFile()
end

-- scheduleSave always records that settings are dirty; the timer only
-- debounces WHEN the write happens (trailing edge, 2 s after the last
-- change). The old version gated the flag itself on a cooldown, so a change
-- made shortly after a save was silently never persisted.
function Persistence.scheduleSave()
	Persistence.save_flags.settings = true
	Persistence.core.state.save_timer = Persistence.r.time_precise() + 2.0
end

function Persistence.scheduleTrackSave()
	Persistence.save_flags.track_selections = true
	-- Trailing debounce: param-row drags call this every frame; without the
	-- timer bump checkSave would serialize all track selections to ExtState
	-- AND rewrite the settings file once per frame for the whole drag.
	local t = Persistence.r.time_precise() + 0.75
	if t > Persistence.core.state.save_timer then
		Persistence.core.state.save_timer = t
	end
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
		end
	end
end

-- Force-write everything (window close). checkSave's debounce would lose
-- edits made in the last 2 seconds otherwise.
function Persistence.flushAll()
	Persistence.save_flags.settings = true
	Persistence.save_flags.track_selections = true
	Persistence.saveSettings()
	Persistence.save_flags.settings = false
	Persistence.save_flags.track_selections = false
	Persistence.save_flags.presets = false
end

local function buildSettingsData(state)
	return {
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
		random_walk_jump = state.random_walk_jump,
		random_walk_sync = state.random_walk_sync,
		target_gesture_x = state.target_gesture_x,
		target_gesture_y = state.target_gesture_y,
		granular_grid_size = state.granular_grid_size,
		random_bypass_percentage = state.random_bypass_percentage,
		random_lfo_probability = state.random_lfo_probability,
		layout_mode = state.layout_mode,
		fx_collapsed = state.fx_collapsed,
		range_min = state.range_min,
		range_max = state.range_max,
		figures_mode = state.figures_mode,
		figures_speed = state.figures_speed,
		figures_size = state.figures_size,
		jsfx_automation_enabled = state.jsfx_automation_enabled,
		link_slew = state.link_slew,
		current_loaded_preset = state.current_loaded_preset,
		random_fx_count = state.random_fx_count,
		random_fx_favorites_only = state.random_fx_favorites_only,
		fxmanager_auto_open = state.fxmanager_auto_open,
		section_collapsed = state.section_collapsed,
		section_widths_user = state.section_widths_user,
		section_order = state.section_order
	}
end

-- Durable mirror of the RAM ExtState. Sections are merged into the existing
-- file so a process that only owns one section (the FX Browser flushes just
-- track_selections) can never wipe the other's data.
function Persistence.writeSettingsFile(state_data, selections_data)
	Persistence.ensureDataDirectory()
	local existing = {}
	if Persistence.r.file_exists(Persistence.settings_file) then
		local f = io.open(Persistence.settings_file, "r")
		if f then
			local content = f:read("*all")
			f:close()
			if content and content ~= "" then
				existing = Persistence.deserialize(content) or {}
			end
		end
	end
	if state_data then existing.state = state_data end
	if selections_data then existing.track_selections = selections_data end
	local f = io.open(Persistence.settings_file, "w")
	if f then
		f:write(Persistence.serialize(existing))
		f:close()
	end
end

function Persistence.saveSettings()
	local state = Persistence.core.state
	local state_data = nil

	if Persistence.save_flags.settings then
		state_data = buildSettingsData(state)
		Persistence.r.SetExtState("CP_FXConstellation", "state", Persistence.serialize(state_data), false)
	end

	if Persistence.save_flags.track_selections then
		if next(state.track_selections) then
			Persistence.r.SetExtState("CP_FXConstellation", "track_selections", Persistence.serialize(state.track_selections), false)
		end
	end

	if Persistence.save_flags.settings or Persistence.save_flags.track_selections then
		Persistence.writeSettingsFile(state_data,
			Persistence.save_flags.track_selections and next(state.track_selections) and state.track_selections or nil)
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
