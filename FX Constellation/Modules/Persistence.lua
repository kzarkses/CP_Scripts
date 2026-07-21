local Persistence = {}

function Persistence.init(reaper_api, core, data_path, presets_file)
	Persistence.r = reaper_api
	Persistence.core = core
	Persistence.data_path = data_path
	Persistence.presets_file = presets_file
	Persistence.settings_file = data_path .. "settings.dat"
	-- Track selections live in their OWN file. They are three orders of
	-- magnitude bigger than the app settings, and merging both into one file
	-- meant every parameter edit paid for the whole blob (see writeSettingsFile).
	Persistence.selections_file = data_path .. "selections.dat"
	Persistence._presets_loaded = false
	Persistence.save_flags = {
		settings = false,
		track_selections = false,
		presets = false
	}
end

-- Emits into a buffer joined once, NOT by `s = s .. piece`.
--
-- The old form was quadratic in the output size: every append copied the whole
-- string built so far. The settings blob is well over a megabyte once a few
-- tracks carry selections, so a single save took long enough to be felt as a
-- freeze — and it fires on a 0.75 s debounce after *every* parameter edit, which
-- is exactly the hitch reported after changing one value. Same output, O(n).
function Persistence.serialize(t)
	local buf, n = {}, 0
	local function put(s) n = n + 1; buf[n] = s end
	local function ser(v)
		local vtype = type(v)
		if vtype == "string" then
			put(string.format("%q", v))
		elseif vtype == "number" then
			put(string.format("%.17g", v))
		elseif vtype == "boolean" then
			put(tostring(v))
		elseif vtype == "table" then
			put("{")
			local first = true
			for k, val in pairs(v) do
				if not first then put(",") end
				first = false
				put("[") ser(k) put("]=") ser(val)
			end
			put("}")
		else
			put("nil")
		end
	end
	ser(t)
	return table.concat(buf)
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
	else
		-- Own file first; fall back to the old combined settings.dat so an
		-- existing install keeps its selections on the first run after the split.
		local sels = nil
		if Persistence.r.file_exists(Persistence.selections_file) then
			local f = io.open(Persistence.selections_file, "r")
			if f then
				local content = f:read("*all")
				f:close()
				if content and content ~= "" then sels = Persistence.deserialize(content) end
			end
		end
		if type(sels) ~= "table" and file_data and type(file_data.track_selections) == "table" then
			sels = file_data.track_selections
			-- Migrating off the combined file: schedule a settings write so the
			-- old blob is dropped from settings.dat instead of lingering there.
			Persistence.save_flags.settings = true
			Persistence.save_flags.track_selections = true
		end
		if type(sels) == "table" then
			-- NEVER prune on load: the MRU list is empty at that point, so the
			-- kept set would be arbitrary. Loading must not lose anything.
			state.track_selections = sels
			-- Seed the cross-process channel so the FX Browser sees the same
			-- selections without needing this script to save first.
			Persistence.r.SetExtState("CP_FXConstellation", "track_selections",
				Persistence.serialize(state.track_selections), false)
		end
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

-- Runaway guard ONLY. This is deliberately far above any real project.
--
-- It was 32, which lost data: a measured install had 51 tracks with selections,
-- so a fifth of them silently lost their selected params, ranges, XY assignments
-- AND their mod_sources — which is where "the LFO isn't mapped like it was"
-- comes from, since the LFO routing per param lives in this same table.
--
-- It was also not worth it: capping 51 -> 32 removed 1.3% of the payload,
-- because size comes from a few huge tracks, not from track count. The real fix
-- was to stop storing rows that carry nothing but defaults (see
-- FXManager.saveTrackSelection); this cap now only exists so the table cannot
-- grow without bound over years.
local MAX_TRACK_SELECTIONS = 512

function Persistence.pruneTrackSelections()
	local state = Persistence.core.state
	local sel = state.track_selections
	if not sel then return end

	local mru = state._sel_mru
	if not mru then mru = {}; state._sel_mru = mru end
	local guid = Persistence.core.getTrackGUID()
	if guid then
		for i = #mru, 1, -1 do
			if mru[i] == guid then table.remove(mru, i) end
		end
		table.insert(mru, 1, guid)
		for i = #mru, MAX_TRACK_SELECTIONS + 1, -1 do mru[i] = nil end
	end

	local n = 0
	for _ in pairs(sel) do n = n + 1 end
	if n <= MAX_TRACK_SELECTIONS then return end

	local keep, kept = {}, 0
	for i = 1, #mru do
		if sel[mru[i]] and not keep[mru[i]] then
			keep[mru[i]] = true; kept = kept + 1
		end
	end
	-- After a fresh load the MRU list is empty, so top it up arbitrarily rather
	-- than wiping everything down to the one track in hand.
	for g in pairs(sel) do
		if kept >= MAX_TRACK_SELECTIONS then break end
		if not keep[g] then keep[g] = true; kept = kept + 1 end
	end
	for g in pairs(sel) do
		if not keep[g] then sel[g] = nil end
	end
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
		lfo_random_settings = state.lfo_random_settings,
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

-- Write a payload, optionally skipping when this process already wrote exactly
-- that text.
--
-- `memo` is only safe on a SINGLE-WRITER file. selections.dat has two writers
-- (this app and the standalone FX Browser), so a memo there would corrupt state:
-- A writes X, B writes Y, A writes X again and skips — leaving Y on disk while A
-- believes X was saved. settings.dat is written by this app alone, so it may
-- memo.
local last_written = {}
local function writeFile(path, text, memo)
	if memo and last_written[path] == text then return false end
	local f = io.open(path, "w")
	if not f then return false end
	f:write(text)
	f:close()
	if memo then last_written[path] = text end
	return true
end

-- Durable mirror of the RAM ExtState, one file per section.
--
-- This used to be ONE file holding both sections, rewritten read-modify-write
-- so a process owning a single section couldn't wipe the other's. The cost was
-- brutal and it landed on EVERY parameter edit: read 1.3 MB back, run it
-- through deserialize (which is `load()` on a megabyte-plus table literal —
-- Lua compiles the whole thing), merge, re-serialize everything, write 1.3 MB.
-- Separate files give the same isolation for free: each writer owns its file.
function Persistence.writeSettingsFile(state_data, selections_data)
	Persistence.ensureDataDirectory()
	if state_data then
		writeFile(Persistence.settings_file,
			Persistence.serialize({ state = state_data }), true)
	end
	if selections_data then
		writeFile(Persistence.selections_file,
			Persistence.serialize(selections_data), false)
	end
end

function Persistence.saveSettings()
	local state = Persistence.core.state
	local state_data = nil
	local sel_data = nil

	if Persistence.save_flags.settings then
		state_data = buildSettingsData(state)
		Persistence.r.SetExtState("CP_FXConstellation", "state", Persistence.serialize(state_data), false)
	end

	if Persistence.save_flags.track_selections and next(state.track_selections) then
		Persistence.pruneTrackSelections()
		sel_data = state.track_selections
		-- serialize ONCE and reuse for both the cross-process channel and disk
		local blob = Persistence.serialize(sel_data)
		Persistence.r.SetExtState("CP_FXConstellation", "track_selections", blob, false)
		Persistence.ensureDataDirectory()
		writeFile(Persistence.selections_file, blob, false)
		sel_data = nil   -- already written
	end

	if state_data or sel_data then
		Persistence.writeSettingsFile(state_data, sel_data)
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
