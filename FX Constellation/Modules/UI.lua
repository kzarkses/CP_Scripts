local UI = {}

function UI.init(reaper_api, core, fxmanager, gesture, presetsystem, persistence, soundgen, license, style_loader, ctx, header_font_size, item_spacing_x, item_spacing_y, window_padding_x, window_padding_y)
	UI.r = reaper_api
	UI.core = core
	UI.fxmanager = fxmanager
	UI.gesture = gesture
	UI.presetsystem = presetsystem
	UI.persistence = persistence
	UI.soundgen = soundgen
	UI.license = license
	UI.style_loader = style_loader
	UI.ctx = ctx
	UI.filters_ctx = nil
	UI.presets_ctx = nil
	UI.pushed_colors = 0
	UI.filters_pushed_colors = 0
	UI.presets_pushed_colors = 0
	UI.pushed_vars = 0
	UI.filters_pushed_vars = 0
	UI.presets_pushed_vars = 0
	UI.header_font_size = header_font_size
	UI.item_spacing_x = item_spacing_x
	UI.item_spacing_y = item_spacing_y
	UI.window_padding_x = window_padding_x
	UI.window_padding_y = window_padding_y
	UI.license_key_input = ""
end

function UI.getStyleValue(path, default_value)
	return UI.style_loader and UI.style_loader.GetValue(path, default_value) or default_value
end

function UI.getStyleFont(font_name, context)
	return UI.style_loader and UI.style_loader.getFont(context or UI.ctx, font_name) or nil
end

function UI.drawCollapsibleHeader(section_name, display_text)
	local is_collapsed = UI.core.state.section_collapsed[section_name]
	local collapse_icon = is_collapsed and "▶ " or "▼ "
	local header_font = UI.getStyleFont("header")
	if header_font and UI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		UI.r.ImGui_PushFont(UI.ctx, header_font, 0)
	end
	UI.r.ImGui_Text(UI.ctx, collapse_icon .. display_text)
	if UI.r.ImGui_IsItemHovered(UI.ctx) then
		local draw_list = UI.r.ImGui_GetWindowDrawList(UI.ctx)
		local min_x, min_y = UI.r.ImGui_GetItemRectMin(UI.ctx)
		local max_x, max_y = UI.r.ImGui_GetItemRectMax(UI.ctx)
		UI.r.ImGui_DrawList_AddRectFilled(draw_list, min_x, min_y, max_x, max_y, 0x33FFFFFF)
		UI.r.ImGui_SetMouseCursor(UI.ctx, UI.r.ImGui_MouseCursor_Hand())
	end
	if UI.r.ImGui_IsItemClicked(UI.ctx) then
		UI.core.state.section_collapsed[section_name] = not is_collapsed
		UI.persistence.scheduleSave()
	end
	if header_font and UI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		UI.r.ImGui_PopFont(UI.ctx)
	end
	UI.r.ImGui_Separator(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	return not is_collapsed
end

function UI.drawPatternIcon(draw_list, x, y, size, pattern_id, is_active)
	local center_x = x + size / 2
	local center_y = y + size / 2
	local radius = size * 0.35
	local color = is_active and 0xFFFFFFFF or 0x888888FF
	local thickness = is_active and 2 or 1

	if pattern_id == 0 then
		UI.r.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, radius, color, 32, thickness)
	elseif pattern_id == 1 then
		local offset = radius
		UI.r.ImGui_DrawList_AddRect(draw_list, center_x - offset, center_y - offset, center_x + offset, center_y + offset, color, 0, 0, thickness)
	elseif pattern_id == 2 then
		local h = radius * 1.2
		UI.r.ImGui_DrawList_AddTriangle(draw_list, center_x, center_y - h * 0.7, center_x - h * 0.6, center_y + h * 0.5, center_x + h * 0.6, center_y + h * 0.5, color, thickness)
	elseif pattern_id == 3 then
		local offset = radius * 0.8
		UI.r.ImGui_DrawList_AddQuad(draw_list, center_x, center_y - offset, center_x + offset, center_y, center_x, center_y + offset, center_x - offset, center_y, color, thickness)
	elseif pattern_id == 4 then
		local offset = radius * 0.8
		UI.r.ImGui_DrawList_AddLine(draw_list, center_x - offset, center_y + offset, center_x + offset, center_y - offset, color, thickness)
		UI.r.ImGui_DrawList_AddLine(draw_list, center_x + offset, center_y + offset, center_x - offset, center_y - offset, color, thickness)
	elseif pattern_id == 5 then
		local segments = 64
		for i = 0, segments - 1 do
			local t1 = (i / segments) * 2 * math.pi
			local t2 = ((i + 1) / segments) * 2 * math.pi
			local scale = radius * 1.3
			local x1 = center_x + scale * math.sin(t1) / (1 + math.cos(t1) * math.cos(t1))
			local y1 = center_y + scale * math.sin(t1) * math.cos(t1) / (1 + math.cos(t1) * math.cos(t1))
			local x2 = center_x + scale * math.sin(t2) / (1 + math.cos(t2) * math.cos(t2))
			local y2 = center_y + scale * math.sin(t2) * math.cos(t2) / (1 + math.cos(t2) * math.cos(t2))
			UI.r.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, color, thickness)
		end
	end
end

function UI.drawNavigation()
	local content_width = UI.r.ImGui_GetContentRegionAvail(UI.ctx)
	if not UI.drawCollapsibleHeader("navigation", "NAVIGATION") then return end

	UI.r.ImGui_SetNextItemWidth(UI.ctx, 128)
	local nav_items = table.concat(UI.core.navigation_modes, "\0") .. "\0"
	local changed, new_nav_mode = UI.r.ImGui_Combo(UI.ctx, "##navmode", UI.core.state.navigation_mode, nav_items)
	if changed then
		UI.core.state.navigation_mode = new_nav_mode
		if new_nav_mode == 1 then
			UI.core.state.random_walk_active = true
			UI.core.state.random_walk_next_time = UI.r.time_precise() + 1.0 / UI.core.state.random_walk_speed
			UI.gesture.generateRandomWalkControlPoints()
			UI.fxmanager.captureBaseValues()
		elseif new_nav_mode == 2 then
			UI.core.state.figures_active = true
			UI.core.state.figures_time = 0
			UI.fxmanager.captureBaseValues()
		else
			UI.core.state.random_walk_active = false
			UI.core.state.figures_active = false
		end
		UI.persistence.scheduleSave()
	end

	UI.r.ImGui_Dummy(UI.ctx, 0, 0)

	if UI.core.state.navigation_mode == 0 then
		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_smooth = UI.r.ImGui_SliderDouble(UI.ctx, "Smooth", UI.core.state.smooth_speed, 0.0, 1.0, "%.2f")
		if changed then UI.core.state.smooth_speed = new_smooth end
		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_max_speed = UI.r.ImGui_SliderDouble(UI.ctx, "Speed", UI.core.state.max_gesture_speed, 0.1, 10.0, "%.1f")
		if changed then UI.core.state.max_gesture_speed = new_max_speed end
	elseif UI.core.state.navigation_mode == 1 then
		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_speed = UI.r.ImGui_SliderDouble(UI.ctx, "Speed", UI.core.state.random_walk_speed, 0.1, 10.0, "%.1f Hz")
		if changed then
			UI.core.state.random_walk_speed = new_speed
			if UI.core.state.random_walk_active then
				UI.core.state.random_walk_next_time = UI.r.time_precise() + 1.0 / UI.core.state.random_walk_speed
			end
		end
		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_jitter = UI.r.ImGui_SliderDouble(UI.ctx, "Jitter", UI.core.state.random_walk_jitter, 0.0, 1.0)
		if changed then UI.core.state.random_walk_jitter = new_jitter end
	elseif UI.core.state.navigation_mode == 2 then
		local button_size = (content_width - 16) / 3
		local draw_list = UI.r.ImGui_GetWindowDrawList(UI.ctx)

		for row = 0, 1 do
			for col = 0, 2 do
				local pattern_id = row * 3 + col
				if pattern_id < 6 then
					if col > 0 then UI.r.ImGui_SameLine(UI.ctx) end
					local cursor_x, cursor_y = UI.r.ImGui_GetCursorScreenPos(UI.ctx)
					local is_active = UI.core.state.figures_mode == pattern_id
					if is_active then UI.r.ImGui_PushStyleColor(UI.ctx, UI.r.ImGui_Col_Button(), 0x444444FF) end
					if UI.r.ImGui_Button(UI.ctx, "##pattern" .. pattern_id, button_size, button_size) then
						UI.core.state.figures_mode = pattern_id
						UI.core.state.figures_time = 0
						UI.persistence.scheduleSave()
					end
					if is_active then UI.r.ImGui_PopStyleColor(UI.ctx) end
					UI.drawPatternIcon(draw_list, cursor_x, cursor_y, button_size, pattern_id, is_active)
					if UI.r.ImGui_IsItemHovered(UI.ctx) then
						UI.r.ImGui_SetTooltip(UI.ctx, UI.core.figures_modes[pattern_id + 1])
					end
				end
			end
		end

		UI.r.ImGui_Dummy(UI.ctx, 0, 4)
		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_speed = UI.r.ImGui_SliderDouble(UI.ctx, "Speed", UI.core.state.figures_speed, 0.01, 10.0, "%.2f Hz")
		if changed then
			local current_angle = UI.core.state.figures_time * UI.core.state.figures_speed * 2 * math.pi
			local current_progress = (current_angle / (2 * math.pi)) % 1
			UI.core.state.figures_time = (current_progress / new_speed)
			UI.core.state.figures_speed = new_speed
			UI.persistence.scheduleSave()
		end

		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_size = UI.r.ImGui_SliderDouble(UI.ctx, "Size", UI.core.state.figures_size, 0.1, 1.0, "%.2f")
		if changed then
			UI.core.state.figures_size = new_size
			UI.persistence.scheduleSave()
		end
	end

	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
	local changed, new_range = UI.r.ImGui_SliderDouble(UI.ctx, "Range", UI.core.state.gesture_range, 0.1, 1.0)
	if changed then UI.core.state.gesture_range = new_range end
	UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
	local changed, new_min = UI.r.ImGui_SliderDouble(UI.ctx, "Min", UI.core.state.gesture_min, 0.0, 1.0)
	if changed then
		UI.core.state.gesture_min = new_min
		if UI.core.state.gesture_max < new_min then UI.core.state.gesture_max = new_min end
		UI.persistence.scheduleSave()
	end
	UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
	local changed, new_max = UI.r.ImGui_SliderDouble(UI.ctx, "Max", UI.core.state.gesture_max, 0.0, 1.0)
	if changed then
		UI.core.state.gesture_max = new_max
		if UI.core.state.gesture_min > new_max then UI.core.state.gesture_min = new_max end
		UI.persistence.scheduleSave()
	end

	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	if UI.r.ImGui_Button(UI.ctx, "Morph 1", (content_width - UI.item_spacing_x) / 2) then
		UI.gesture.captureToMorph(1)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Morph 2", (content_width - UI.item_spacing_x) / 2) then
		UI.gesture.captureToMorph(2)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_Text(UI.ctx, UI.core.state.morph_preset_a and UI.core.state.morph_preset_b and "Ready" or "Set both")
	UI.r.ImGui_SetNextItemWidth(UI.ctx, 128)
	local changed, new_amount = UI.r.ImGui_SliderDouble(UI.ctx, "Morph", UI.core.state.morph_amount or 0, 0.0, 1.0)
	if changed then
		UI.core.state.morph_amount = new_amount
		UI.gesture.morphBetweenPresets(UI.core.state.morph_amount)
	end
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)

	if UI.r.ImGui_Button(UI.ctx, "Auto JSFX", content_width) then
		if UI.core.state.jsfx_automation_enabled then
			UI.core.state.jsfx_automation_enabled = false
			UI.core.state.jsfx_automation_index = -1
		else
			UI.gesture.createAutomationJSFX()
		end
	end
	if UI.core.state.jsfx_automation_enabled then
		UI.r.ImGui_SameLine(UI.ctx)
		UI.r.ImGui_TextColored(UI.ctx, 0x00FF00FF, "ON")
	else
		local found_idx = UI.gesture.findAutomationJSFX()
		if found_idx >= 0 then
			UI.core.state.jsfx_automation_enabled = true
			UI.core.state.jsfx_automation_index = found_idx
			UI.r.ImGui_SameLine(UI.ctx)
			UI.r.ImGui_TextColored(UI.ctx, 0x00FF00FF, "Found")
		else
			UI.r.ImGui_SameLine(UI.ctx)
			UI.r.ImGui_TextColored(UI.ctx, 0xFF0000FF, "OFF")
		end
	end

	if UI.r.ImGui_Button(UI.ctx, "Show Env", content_width) then
		if not UI.core.state.jsfx_automation_enabled or UI.core.state.jsfx_automation_index < 0 then
			UI.gesture.createAutomationJSFX()
		end
		if UI.core.state.jsfx_automation_enabled and UI.core.state.jsfx_automation_index >= 0 then
			local x_env = UI.r.GetFXEnvelope(UI.core.state.track, UI.core.state.jsfx_automation_index, 0, true)
			local y_env = UI.r.GetFXEnvelope(UI.core.state.track, UI.core.state.jsfx_automation_index, 1, true)
			if x_env then UI.r.SetCursorContext(2, x_env) end
			if y_env then UI.r.SetCursorContext(2, y_env) end
		end
	end
end

function UI.drawMode()
	if not UI.drawCollapsibleHeader("mode", "MODE") then return end

	if UI.r.ImGui_Button(UI.ctx, "Single", 128) then
		UI.core.state.pad_mode = 0
		UI.persistence.scheduleSave()
	end
	if UI.r.ImGui_Button(UI.ctx, "Granular", 128) then
		UI.core.state.pad_mode = 1
		if not UI.core.state.granular_grains or #UI.core.state.granular_grains == 0 then
			UI.gesture.initializeGranularGrid()
		end
		UI.persistence.scheduleSave()
	end
	if UI.core.state.pad_mode == 1 then
		UI.r.ImGui_Dummy(UI.ctx, 0, 0)
		local grid_sizes = { "2x2", "3x3", "4x4" }
		local grid_values = { 2, 3, 4 }
		local current_grid_idx = 1
		for i, val in ipairs(grid_values) do
			if val == UI.core.state.granular_grid_size then
				current_grid_idx = i - 1
				break
			end
		end
		UI.r.ImGui_SetNextItemWidth(UI.ctx, 128)
		local changed, new_grid_idx = UI.r.ImGui_Combo(UI.ctx, "##gran", current_grid_idx, table.concat(grid_sizes, "\0") .. "\0")
		if changed then
			UI.core.state.granular_grid_size = grid_values[new_grid_idx + 1]
			UI.gesture.initializeGranularGrid()
		end
		if UI.r.ImGui_Button(UI.ctx, "Randomize", 128) then
			if not UI.core.state.granular_grains or #UI.core.state.granular_grains == 0 then
				UI.gesture.initializeGranularGrid()
			else
				UI.gesture.randomizeGranularGrid()
			end
		end
		UI.r.ImGui_Dummy(UI.ctx, 0, 0)
		UI.r.ImGui_SetNextItemWidth(UI.ctx, 128)
		local changed, new_name = UI.r.ImGui_InputText(UI.ctx, "##granset", UI.core.state.granular_set_name)
		if changed then UI.core.state.granular_set_name = new_name end
		if UI.r.ImGui_Button(UI.ctx, "Save", 62) then
			if UI.core.state.granular_set_name and UI.core.state.granular_set_name ~= "" then
				UI.presetsystem.saveGranularSet(UI.core.state.granular_set_name)
			end
		end
		UI.r.ImGui_SameLine(UI.ctx)
		if UI.r.ImGui_Button(UI.ctx, "Load", 62) then
			if UI.core.state.granular_set_name and UI.core.state.granular_set_name ~= "" then
				UI.presetsystem.loadGranularSet(UI.core.state.granular_set_name)
			end
		end
		UI.r.ImGui_Dummy(UI.ctx, 0, 0)
		if UI.r.ImGui_BeginChild(UI.ctx, "GrainSetList", 128, 80) then
			local current_preset = UI.core.state.current_loaded_preset
			local granular_sets_to_display = {}
			if current_preset ~= "" and UI.core.state.presets[current_preset] and UI.core.state.presets[current_preset].granular_sets then
				granular_sets_to_display = UI.core.state.presets[current_preset].granular_sets
			end
			for name, _ in pairs(granular_sets_to_display) do
				UI.r.ImGui_PushID(UI.ctx, name)
				if UI.r.ImGui_Button(UI.ctx, name, 102, 22) then
					UI.presetsystem.loadGranularSet(name)
					UI.core.state.granular_set_name = name
				end
				UI.r.ImGui_SameLine(UI.ctx)
				if UI.r.ImGui_Button(UI.ctx, "X", 22, 22) then
					UI.presetsystem.deleteGranularSet(name)
				end
				UI.r.ImGui_PopID(UI.ctx)
			end
			UI.r.ImGui_EndChild(UI.ctx)
		end
	end
end

function UI.drawSoundGenerator()
	local content_width = UI.r.ImGui_GetContentRegionAvail(UI.ctx)
	if not UI.drawCollapsibleHeader("soundgen", "SOUND GENERATOR") then return end

	if not UI.license.isFull() then
		UI.r.ImGui_TextColored(UI.ctx, 0xFFAA00FF, "🔒 Premium Feature")
		UI.r.ImGui_Text(UI.ctx, "Sound Generator is available")
		UI.r.ImGui_Text(UI.ctx, "in the full version.")
		UI.r.ImGui_Dummy(UI.ctx, 0, 0)
		if UI.r.ImGui_Button(UI.ctx, "Activate License", content_width) then
			UI.core.state.show_license_window = true
		end
		return
	end

	local sg = UI.core.state.sound_generator
	local button_width = (content_width - UI.item_spacing_x) / 2

	if not sg.enabled then
		if UI.r.ImGui_Button(UI.ctx, "Create Generator", content_width) then
			UI.soundgen.createGenerator()
		end
	else
		if UI.r.ImGui_Button(UI.ctx, "Remove", button_width) then
			UI.soundgen.removeGenerator()
		end
		UI.r.ImGui_SameLine(UI.ctx)
		if UI.r.ImGui_Button(UI.ctx, sg.mode == 0 and "Continuous" or "Triggered", button_width) then
			UI.soundgen.removeGenerator()
			sg.mode = sg.mode == 0 and 1 or 0
			UI.soundgen.createGenerator()
		end

		UI.r.ImGui_Dummy(UI.ctx, 0, 0)

		if sg.mode == 0 then
			local waveforms = {"Sine", "Triangle", "Square", "Saw"}
			local wf_combo = table.concat(waveforms, "\0") .. "\0"
			UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
			local changed, new_wf = UI.r.ImGui_Combo(UI.ctx, "Waveform##sg", sg.waveform, wf_combo)
			if changed then
				sg.waveform = new_wf
				UI.soundgen.updateJSFXParams()
			end

			UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
			local changed, new_freq = UI.r.ImGui_SliderDouble(UI.ctx, "Frequency##sg", sg.frequency, 20, 2000, "%.1f Hz")
			if changed then
				sg.frequency = new_freq
				UI.soundgen.updateJSFXParams()
			end

			local changed, rhythmic = UI.r.ImGui_Checkbox(UI.ctx, "Rhythmic", sg.rhythmic)
			if changed then
				sg.rhythmic = rhythmic
				UI.soundgen.updateJSFXParams()
			end

			if sg.rhythmic then
				UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
				local changed, new_rate = UI.r.ImGui_SliderDouble(UI.ctx, "Tick Rate##sg", sg.tick_rate, 0.1, 20, "%.2f Hz")
				if changed then
					sg.tick_rate = new_rate
					UI.soundgen.updateJSFXParams()
				end

				UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
				local changed, new_duty = UI.r.ImGui_SliderDouble(UI.ctx, "Duty Cycle##sg", sg.duty_cycle, 0.01, 0.99, "%.2f")
				if changed then
					sg.duty_cycle = new_duty
					UI.soundgen.updateJSFXParams()
				end
			end

			UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
			local changed, new_noise = UI.r.ImGui_SliderDouble(UI.ctx, "Noise Color##sg", sg.noise_color, 0, 1, "%.2f")
			if changed then
				sg.noise_color = new_noise
				UI.soundgen.updateJSFXParams()
			end
		else
			local waveforms = {"Sine", "Triangle", "Square", "Saw"}
			local wf_combo = table.concat(waveforms, "\0") .. "\0"
			UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
			local changed, new_wf = UI.r.ImGui_Combo(UI.ctx, "Waveform##sg", sg.waveform, wf_combo)
			if changed then
				sg.waveform = new_wf
				UI.soundgen.updateJSFXParams()
			end

			UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
			local changed, new_freq = UI.r.ImGui_SliderDouble(UI.ctx, "Base Freq##sg", sg.base_freq, 20, 2000, "%.1f Hz")
			if changed then
				sg.base_freq = new_freq
				UI.soundgen.updateJSFXParams()
			end

			local changed, use_adsr = UI.r.ImGui_Checkbox(UI.ctx, "ADSR Envelope", sg.use_adsr)
			if changed then
				sg.use_adsr = use_adsr
				UI.soundgen.updateJSFXParams()
			end

			if sg.use_adsr then
				UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
				local changed, new_a = UI.r.ImGui_SliderDouble(UI.ctx, "Attack##sg", sg.attack, 0.001, 2, "%.3f s")
				if changed then
					sg.attack = new_a
					UI.soundgen.updateJSFXParams()
				end

				UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
				local changed, new_d = UI.r.ImGui_SliderDouble(UI.ctx, "Decay##sg", sg.decay, 0.001, 2, "%.3f s")
				if changed then
					sg.decay = new_d
					UI.soundgen.updateJSFXParams()
				end

				UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
				local changed, new_s = UI.r.ImGui_SliderDouble(UI.ctx, "Sustain##sg", sg.sustain, 0, 1, "%.2f")
				if changed then
					sg.sustain = new_s
					UI.soundgen.updateJSFXParams()
				end

				UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
				local changed, new_r = UI.r.ImGui_SliderDouble(UI.ctx, "Release##sg", sg.release, 0.001, 5, "%.3f s")
				if changed then
					sg.release = new_r
					UI.soundgen.updateJSFXParams()
				end
			end

			local changed, midi = UI.r.ImGui_Checkbox(UI.ctx, "MIDI Trigger", sg.midi_mode)
			if changed then
				sg.midi_mode = midi
				UI.soundgen.updateJSFXParams()
			end

			if not sg.midi_mode then
				UI.r.ImGui_Dummy(UI.ctx, 0, 0)
				if UI.r.ImGui_Button(UI.ctx, "HOLD TO PLAY", content_width) then
					if UI.r.ImGui_IsItemActive(UI.ctx) then
						UI.soundgen.setManualTrigger(true)
					end
				end
				if UI.r.ImGui_IsItemDeactivated(UI.ctx) then
					UI.soundgen.setManualTrigger(false)
				end
			end
		end

		UI.r.ImGui_Dummy(UI.ctx, 0, 0)
		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_amp = UI.r.ImGui_SliderDouble(UI.ctx, "Amplitude##sg", sg.amplitude, 0, 1, "%.2f")
		if changed then
			sg.amplitude = new_amp
			UI.soundgen.updateJSFXParams()
		end

		UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
		local changed, new_width = UI.r.ImGui_SliderDouble(UI.ctx, "Stereo Width##sg", sg.stereo_width, 0, 1, "%.2f")
		if changed then
			sg.stereo_width = new_width
			UI.soundgen.updateJSFXParams()
		end
	end
end

function UI.drawPadSection()
	local is_collapsed = UI.core.state.section_collapsed.pad
	local collapse_icon = is_collapsed and "▶ " or "▼ "
	local header_font = UI.getStyleFont("header")
	if header_font and UI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		UI.r.ImGui_PushFont(UI.ctx, header_font, 0)
	end
	UI.r.ImGui_Text(UI.ctx, collapse_icon .. "XY PAD")
	local header_clicked = UI.r.ImGui_IsItemClicked(UI.ctx)
	local header_hovered = UI.r.ImGui_IsItemHovered(UI.ctx)
	if header_hovered then
		local draw_list = UI.r.ImGui_GetWindowDrawList(UI.ctx)
		local min_x, min_y = UI.r.ImGui_GetItemRectMin(UI.ctx)
		local max_x, max_y = UI.r.ImGui_GetItemRectMax(UI.ctx)
		UI.r.ImGui_DrawList_AddRectFilled(draw_list, min_x, min_y, max_x, max_y, 0x33FFFFFF)
		UI.r.ImGui_SetMouseCursor(UI.ctx, UI.r.ImGui_MouseCursor_Hand())
	end
	UI.r.ImGui_SameLine(UI.ctx)
	local content_width = UI.r.ImGui_GetContentRegionAvail(UI.ctx)
	local reset_text = "↻"
	local reset_text_width = UI.r.ImGui_CalcTextSize(UI.ctx, reset_text)
	local reset_x = UI.r.ImGui_GetCursorPosX(UI.ctx) + content_width - reset_text_width
	UI.r.ImGui_SetCursorPosX(UI.ctx, reset_x)
	UI.r.ImGui_Text(UI.ctx, reset_text)
	if UI.r.ImGui_IsItemClicked(UI.ctx) then
		UI.core.state.gesture_x = 0.5
		UI.core.state.gesture_y = 0.5
		UI.core.state.gesture_base_x = 0.5
		UI.core.state.gesture_base_y = 0.5
		UI.gesture.updateJSFXFromGesture()
		UI.fxmanager.captureBaseValues()
		if UI.core.state.pad_mode == 1 then
			if not UI.core.state.granular_grains or #UI.core.state.granular_grains == 0 then
				UI.gesture.initializeGranularGrid()
			end
			UI.gesture.applyGranularGesture(UI.core.state.gesture_x, UI.core.state.gesture_y)
		else
			UI.gesture.applyGestureToSelection(UI.core.state.gesture_x, UI.core.state.gesture_y)
		end
	end
	if UI.r.ImGui_IsItemHovered(UI.ctx) then
		UI.r.ImGui_SetTooltip(UI.ctx, "Reset XY Pad to center")
	end
	if header_font and UI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		UI.r.ImGui_PopFont(UI.ctx)
	end
	if header_clicked then
		UI.core.state.section_collapsed.pad = not is_collapsed
		UI.persistence.scheduleSave()
	end
	UI.r.ImGui_Separator(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	if is_collapsed then return end
	local pad_size = 298
	local draw_list = UI.r.ImGui_GetWindowDrawList(UI.ctx)
	local cursor_pos_x, cursor_pos_y = UI.r.ImGui_GetCursorScreenPos(UI.ctx)
	UI.r.ImGui_InvisibleButton(UI.ctx, "xy_pad", pad_size, pad_size)
	if UI.r.ImGui_IsItemActive(UI.ctx) then
		local mouse_x, mouse_y = UI.r.ImGui_GetMousePos(UI.ctx)
		local click_x = (mouse_x - cursor_pos_x) / pad_size
		local click_y = 1.0 - (mouse_y - cursor_pos_y) / pad_size
		if not UI.core.state.gesture_active then
			UI.core.state.gesture_active = true
			UI.core.state.gesture_base_x = UI.core.state.gesture_x
			UI.core.state.gesture_base_y = UI.core.state.gesture_y
			UI.fxmanager.captureBaseValues()
			local cursor_screen_x = cursor_pos_x + UI.core.state.gesture_x * pad_size
			local cursor_screen_y = cursor_pos_y + (1.0 - UI.core.state.gesture_y) * pad_size
			local dx = mouse_x - cursor_screen_x
			local dy = mouse_y - cursor_screen_y
			local distance = math.sqrt(dx * dx + dy * dy)
			local dead_zone_radius = 30
			if distance <= dead_zone_radius then
				UI.core.state.click_offset_x = UI.core.state.gesture_x - click_x
				UI.core.state.click_offset_y = UI.core.state.gesture_y - click_y
			else
				UI.core.state.click_offset_x = 0
				UI.core.state.click_offset_y = 0
			end
		end
		click_x = math.max(0, math.min(1, click_x + UI.core.state.click_offset_x))
		click_y = math.max(0, math.min(1, click_y + UI.core.state.click_offset_y))
		if UI.core.state.navigation_mode == 1 then
			UI.core.state.random_walk_active = false
		elseif UI.core.state.navigation_mode == 2 then
			UI.core.state.figures_active = false
		end
		if UI.core.state.navigation_mode == 1 or UI.core.state.navigation_mode == 2 or UI.core.state.smooth_speed == 0 then
			UI.core.state.gesture_x = click_x
			UI.core.state.gesture_y = click_y
			UI.gesture.updateJSFXFromGesture()
			if UI.core.state.pad_mode == 1 then
				if not UI.core.state.granular_grains or #UI.core.state.granular_grains == 0 then
					UI.gesture.initializeGranularGrid()
				end
				UI.gesture.applyGranularGesture(UI.core.state.gesture_x, UI.core.state.gesture_y)
			else
				UI.gesture.applyGestureToSelection(UI.core.state.gesture_x, UI.core.state.gesture_y)
			end
		else
			UI.core.state.target_gesture_x = click_x
			UI.core.state.target_gesture_y = click_y
		end
	else
		if UI.core.state.gesture_active then
			UI.core.state.gesture_active = false
			UI.core.state.click_offset_x = 0
			UI.core.state.click_offset_y = 0
		end
	end
	UI.r.ImGui_DrawList_AddRectFilled(draw_list, cursor_pos_x, cursor_pos_y, cursor_pos_x + pad_size, cursor_pos_y + pad_size, 0x222222FF)
	UI.r.ImGui_DrawList_AddRect(draw_list, cursor_pos_x, cursor_pos_y, cursor_pos_x + pad_size, cursor_pos_y + pad_size, 0x666666FF)
	UI.r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x + pad_size / 2, cursor_pos_y, cursor_pos_x + pad_size / 2, cursor_pos_y + pad_size, 0x444444FF)
	UI.r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, cursor_pos_y + pad_size / 2, cursor_pos_x + pad_size, cursor_pos_y + pad_size / 2, 0x444444FF)
	if UI.core.state.pad_mode == 1 and UI.core.state.granular_grains and #UI.core.state.granular_grains > 0 then
		local grid_size = UI.core.state.granular_grid_size
		for i = 1, grid_size - 1 do
			local line_x = cursor_pos_x + (i / grid_size) * pad_size
			local line_y = cursor_pos_y + (i / grid_size) * pad_size
			UI.r.ImGui_DrawList_AddLine(draw_list, line_x, cursor_pos_y, line_x, cursor_pos_y + pad_size, 0x444444AA)
			UI.r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, line_y, cursor_pos_x + pad_size, line_y, 0x444444AA)
		end
		for _, grain in ipairs(UI.core.state.granular_grains) do
			local grain_screen_x = cursor_pos_x + grain.x * pad_size
			local grain_screen_y = cursor_pos_y + (1.0 - grain.y) * pad_size
			local grain_radius = (pad_size / grid_size)
			UI.r.ImGui_DrawList_AddCircle(draw_list, grain_screen_x, grain_screen_y, grain_radius, 0x66666644, 0, 1)
			UI.r.ImGui_DrawList_AddCircleFilled(draw_list, grain_screen_x, grain_screen_y, 4, 0xFFFFFFFF)
		end
	elseif UI.core.state.pad_mode == 1 then
		local grid_size = UI.core.state.granular_grid_size
		for i = 1, grid_size - 1 do
			local line_x = cursor_pos_x + (i / grid_size) * pad_size
			local line_y = cursor_pos_y + (i / grid_size) * pad_size
			UI.r.ImGui_DrawList_AddLine(draw_list, line_x, cursor_pos_y, line_x, cursor_pos_y + pad_size, 0x444444AA)
			UI.r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, line_y, cursor_pos_x + pad_size, line_y, 0x444444AA)
		end
	end
	local dot_x = cursor_pos_x + UI.core.state.gesture_x * pad_size
	local dot_y = cursor_pos_y + (1.0 - UI.core.state.gesture_y) * pad_size
	UI.r.ImGui_DrawList_AddCircleFilled(draw_list, dot_x, dot_y, 8, 0xFFFFFFFF)
	if UI.core.state.navigation_mode == 0 and UI.core.state.smooth_speed > 0 then
		local target_dot_x = cursor_pos_x + UI.core.state.target_gesture_x * pad_size
		local target_dot_y = cursor_pos_y + (1.0 - UI.core.state.target_gesture_y) * pad_size
		UI.r.ImGui_DrawList_AddCircle(draw_list, target_dot_x, target_dot_y, 6, 0x888888FF, 0, 2)
	end
	local mono_font = UI.getStyleFont("mono")
	if mono_font and UI.r.ImGui_ValidatePtr(mono_font, "ImGui_Font*") then
		UI.r.ImGui_PushFont(UI.ctx, mono_font, 0)
		UI.r.ImGui_Text(UI.ctx, string.format("Position: %.2f, %.2f", UI.core.state.gesture_x, UI.core.state.gesture_y))
		UI.r.ImGui_PopFont(UI.ctx)
	end
end

function UI.drawRandomizer()
	local content_width = UI.r.ImGui_GetContentRegionAvail(UI.ctx)
	if not UI.drawCollapsibleHeader("randomizer", "RANDOMIZER") then return end

	if UI.r.ImGui_Button(UI.ctx, "ULTRA RANDOM", content_width) then
		UI.fxmanager.ultraRandom()
		UI.gesture.updateJSFXFromGesture()
	end
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	if UI.r.ImGui_Button(UI.ctx, "FX Order", content_width) then
		UI.fxmanager.randomizeFXOrder()
	end
	if UI.r.ImGui_Button(UI.ctx, "Bypass", (content_width - UI.item_spacing_x) / 2) then
		UI.fxmanager.randomBypassFX()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_SetNextItemWidth(UI.ctx, (content_width - UI.item_spacing_x) / 2)
	local changed, new_bypass = UI.r.ImGui_SliderDouble(UI.ctx, "##bypass", UI.core.state.random_bypass_percentage * 100, 0.0, 100.0, "%.0f%%")
	if changed then
		UI.core.state.random_bypass_percentage = new_bypass / 100
		UI.persistence.scheduleSave()
	end
	if UI.r.ImGui_Button(UI.ctx, "XY", (content_width - 2 * UI.item_spacing_x) / 4) then
		UI.fxmanager.globalRandomXYAssign()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	local changed, exclusive = UI.r.ImGui_Checkbox(UI.ctx, "##exclusive", UI.core.state.exclusive_xy)
	if changed then
		UI.core.state.exclusive_xy = exclusive
		UI.persistence.scheduleSave()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "N", (content_width - UI.item_spacing_x) / 2) then
		UI.fxmanager.globalRandomInvert()
	end
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	if UI.r.ImGui_Button(UI.ctx, "Ranges", content_width) then
		UI.fxmanager.globalRandomRanges()
	end
	UI.r.ImGui_SetNextItemWidth(UI.ctx, (content_width - UI.item_spacing_x) / 2)
	local changed, new_rmin = UI.r.ImGui_SliderDouble(UI.ctx, "##rngmin", UI.core.state.range_min, 0.0, 1.0, "%.2f")
	if changed then
		UI.core.state.range_min = new_rmin
		if UI.core.state.range_max < new_rmin then UI.core.state.range_max = new_rmin end
		UI.persistence.scheduleSave()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_SetNextItemWidth(UI.ctx, (content_width - UI.item_spacing_x) / 2)
	local changed, new_rmax = UI.r.ImGui_SliderDouble(UI.ctx, "##rngmax", UI.core.state.range_max, 0.0, 1.0, "%.2f")
	if changed then
		UI.core.state.range_max = new_rmax
		if UI.core.state.range_min > new_rmax then UI.core.state.range_min = new_rmax end
		UI.persistence.scheduleSave()
	end
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	if UI.r.ImGui_Button(UI.ctx, "Bases", content_width) then
		UI.fxmanager.randomizeAllBases()
	end
	UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
	local changed, new_intensity = UI.r.ImGui_SliderDouble(UI.ctx, "##intensity", UI.core.state.randomize_intensity, 0.0, 1.0, "%.2f")
	if changed then UI.core.state.randomize_intensity = new_intensity end
	UI.r.ImGui_SetNextItemWidth(UI.ctx, (content_width - UI.item_spacing_x) / 2)
	local changed, new_min = UI.r.ImGui_SliderDouble(UI.ctx, "##basemin", UI.core.state.randomize_min, 0.0, 1.0, "%.2f")
	if changed then
		UI.core.state.randomize_min = new_min
		if UI.core.state.randomize_max < new_min then UI.core.state.randomize_max = new_min end
		UI.persistence.scheduleSave()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_SetNextItemWidth(UI.ctx, (content_width - UI.item_spacing_x) / 2)
	local changed, new_max = UI.r.ImGui_SliderDouble(UI.ctx, "##basemax", UI.core.state.randomize_max, 0.0, 1.0, "%.2f")
	if changed then
		UI.core.state.randomize_max = new_max
		if UI.core.state.randomize_min > new_max then UI.core.state.randomize_min = new_max end
		UI.persistence.scheduleSave()
	end
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	if UI.r.ImGui_Button(UI.ctx, "Parameters", content_width) then
		UI.fxmanager.globalRandomSelect()
		UI.fxmanager.saveTrackSelection()
	end
	UI.r.ImGui_SetNextItemWidth(UI.ctx, (content_width - UI.item_spacing_x) / 2)
	local changed, new_min = UI.r.ImGui_SliderInt(UI.ctx, "##min", UI.core.state.random_min, 1, 300)
	if changed then UI.core.state.random_min = new_min end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_SetNextItemWidth(UI.ctx, (content_width - UI.item_spacing_x) / 2)
	local changed, new_max = UI.r.ImGui_SliderInt(UI.ctx, "##max", UI.core.state.random_max, 1, 300)
	if changed then
		UI.core.state.random_max = math.max(new_max, UI.core.state.random_min)
	end
end

function UI.drawPresets()
	local content_width = UI.r.ImGui_GetContentRegionAvail(UI.ctx)
	if not UI.drawCollapsibleHeader("presets", "PRESETS") then return end

	local button_width = (content_width - UI.item_spacing_x) / 2
	if UI.r.ImGui_Button(UI.ctx, "Save##presets", button_width) then
		if UI.core.state.current_loaded_preset ~= "" then
			UI.presetsystem.savePreset(UI.core.state.current_loaded_preset)
		else
			local retval, preset_name = UI.r.GetUserInputs("Save FX Chain Preset", 1, "Preset name:", "")
			if retval and preset_name ~= "" then
				UI.presetsystem.savePreset(preset_name)
				UI.core.state.current_loaded_preset = preset_name
				UI.fxmanager.saveTrackSelection()
			end
		end
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Save As##presets", button_width) then
		local retval, preset_name = UI.r.GetUserInputs("Save FX Chain Preset As", 1, "Preset name:", UI.core.state.current_loaded_preset)
		if retval and preset_name ~= "" then
			UI.presetsystem.savePreset(preset_name)
			UI.core.state.current_loaded_preset = preset_name
			UI.fxmanager.saveTrackSelection()
		end
	end

	local preset_names = {}
	local current_index = -1
	for name, _ in pairs(UI.core.state.presets) do
		table.insert(preset_names, name)
	end
	table.sort(preset_names)
	for idx, name in ipairs(preset_names) do
		if name == UI.core.state.current_loaded_preset then
			current_index = idx - 1
		end
	end

	UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
	local preset_combo_str = table.concat(preset_names, "\0") .. "\0"
	if preset_combo_str == "\0" then preset_combo_str = " \0" end
	local changed, new_index = UI.r.ImGui_Combo(UI.ctx, "##presetlist", current_index, preset_combo_str)
	if changed and new_index >= 0 and preset_names[new_index + 1] then
		UI.presetsystem.loadPreset(preset_names[new_index + 1])
	end

	local delete_button_width = (content_width - UI.item_spacing_x) / 2
	if UI.r.ImGui_Button(UI.ctx, "Rename##preset", delete_button_width) then
		if UI.core.state.current_loaded_preset ~= "" then
			local retval, new_name = UI.r.GetUserInputs("Rename Preset", 1, "New name:", UI.core.state.current_loaded_preset)
			if retval and new_name ~= "" and new_name ~= UI.core.state.current_loaded_preset then
				UI.presetsystem.renamePreset(UI.core.state.current_loaded_preset, new_name)
				UI.core.state.current_loaded_preset = new_name
				UI.fxmanager.saveTrackSelection()
			end
		end
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Delete##preset", delete_button_width) then
		if UI.core.state.current_loaded_preset ~= "" then
			local result = UI.r.ShowMessageBox("Delete preset '" .. UI.core.state.current_loaded_preset .. "'?", "Delete Preset", 4)
			if result == 6 then
				UI.presetsystem.deletePreset(UI.core.state.current_loaded_preset)
				UI.core.state.current_loaded_preset = ""
			end
		end
	end

	UI.r.ImGui_Dummy(UI.ctx, 0, 0)

	if header_font and UI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		UI.r.ImGui_PushFont(UI.ctx, header_font, 0)
		UI.r.ImGui_Text(UI.ctx, "SNAPSHOTS")
		UI.r.ImGui_PopFont(UI.ctx)
		UI.r.ImGui_Separator(UI.ctx)
		UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	end

	UI.r.ImGui_SetNextItemWidth(UI.ctx, content_width)
	local changed, new_name = UI.r.ImGui_InputText(UI.ctx, "##snapname", UI.core.state.snapshot_name)
	if changed then UI.core.state.snapshot_name = new_name end

	if UI.r.ImGui_Button(UI.ctx, "Save##snapshots", content_width) then
		if UI.core.state.snapshot_name and UI.core.state.snapshot_name ~= "" then
			UI.presetsystem.saveSnapshot(UI.core.state.snapshot_name)
		end
	end

	UI.r.ImGui_Dummy(UI.ctx, 0, 0)

	if UI.r.ImGui_BeginChild(UI.ctx, "SnapshotListPresets", content_width, -1) then
		local current_preset = UI.core.state.current_loaded_preset
		if current_preset ~= "" and UI.core.state.presets[current_preset] and UI.core.state.presets[current_preset].snapshots then
			for name, _ in pairs(UI.core.state.presets[current_preset].snapshots) do
				UI.r.ImGui_PushID(UI.ctx, name)
				local button_width = content_width - 54 - (2 * UI.item_spacing_x)
				if UI.r.ImGui_Button(UI.ctx, name, button_width) then
					UI.presetsystem.loadSnapshot(name)
					UI.core.state.snapshot_name = UI.presetsystem.getNextSnapshotName()
				end
				UI.r.ImGui_SameLine(UI.ctx)
				if UI.r.ImGui_Button(UI.ctx, "R", 22) then
					local retval, new_name = UI.r.GetUserInputs("Rename Snapshot", 1, "New name:", name)
					if retval and new_name ~= "" and new_name ~= name then
						if UI.core.state.presets[current_preset].snapshots[name] then
							UI.core.state.presets[current_preset].snapshots[new_name] = UI.core.state.presets[current_preset].snapshots[name]
							UI.core.state.presets[current_preset].snapshots[name] = nil
							UI.persistence.schedulePresetSave()
						end
					end
				end
				UI.r.ImGui_SameLine(UI.ctx)
				if UI.r.ImGui_Button(UI.ctx, "X", 22) then
					UI.presetsystem.deleteSnapshot(name)
				end
				UI.r.ImGui_PopID(UI.ctx)
			end
		end
		UI.r.ImGui_EndChild(UI.ctx)
	end
end

function UI.drawFXSection()
	local header_font = UI.getStyleFont("header")
	if header_font and UI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		UI.r.ImGui_PushFont(UI.ctx, header_font, 0)
		local header_text = "FX SETTINGS"
		UI.r.ImGui_Text(UI.ctx, header_text)
		UI.r.ImGui_PopFont(UI.ctx)
		UI.r.ImGui_SameLine(UI.ctx)
		local selection_text = "| Selected: " .. UI.core.state.selected_count
		if UI.core.state.current_loaded_preset ~= "" then
			selection_text = selection_text .. " | " .. UI.core.state.current_loaded_preset
		end
		UI.r.ImGui_Text(UI.ctx, selection_text)
		UI.r.ImGui_Separator(UI.ctx)
		UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	end
	if UI.r.ImGui_Button(UI.ctx, UI.core.state.show_filters_window and "Hide Filters" or "Show Filters") then
		UI.core.state.show_filters_window = not UI.core.state.show_filters_window
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Show All FX") then
		UI.presetsystem.showAllFloatingFX()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Close All FX") then
		UI.presetsystem.closeAllFloatingFX()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Collapse All") then
		UI.core.state.all_fx_collapsed = true
		for fx_id, _ in pairs(UI.core.state.fx_data) do
			UI.core.state.fx_collapsed[fx_id] = true
		end
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Expand All") then
		UI.core.state.all_fx_collapsed = false
		for fx_id, _ in pairs(UI.core.state.fx_data) do
			UI.core.state.fx_collapsed[fx_id] = false
		end
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "All") then
		for fx_id, fx_data in pairs(UI.core.state.fx_data) do
			UI.fxmanager.selectAllParams(fx_data.params, true)
		end
		UI.fxmanager.saveTrackSelection()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "All Cont") then
		for fx_id, fx_data in pairs(UI.core.state.fx_data) do
			UI.fxmanager.selectAllContinuousParams(fx_data.params, true)
		end
		UI.fxmanager.saveTrackSelection()
	end
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_Button(UI.ctx, "Clear") then
		for fx_id, fx_data in pairs(UI.core.state.fx_data) do
			UI.fxmanager.selectAllParams(fx_data.params, false)
		end
		UI.fxmanager.saveTrackSelection()
	end
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	local fx_count = 0
	for _ in pairs(UI.core.state.fx_data) do fx_count = fx_count + 1 end
	if fx_count > 0 then
		if UI.r.ImGui_BeginChild(UI.ctx, "FXHorizontal", 0, 0, 0, UI.r.ImGui_WindowFlags_HorizontalScrollbar()) then
			local fx_width = 350
			UI.r.ImGui_SetCursorPosX(UI.ctx, 0)
			for fx_id = 0, fx_count - 1 do
				if fx_id > 0 then UI.r.ImGui_SameLine(UI.ctx) end
				local fx_data = UI.core.state.fx_data[fx_id]
				if fx_data then
					UI.r.ImGui_BeginGroup(UI.ctx)
					UI.r.ImGui_PushStyleVar(UI.ctx, UI.r.ImGui_StyleVar_ChildBorderSize(), 1)
					local collapsed = UI.core.state.fx_collapsed[fx_id] or false
					local child_width = collapsed and 28 or fx_width
					local child_height = collapsed and 320 or -1
					if UI.r.ImGui_BeginChild(UI.ctx, "FX" .. fx_id, child_width, child_height) then
						if collapsed then
							if UI.r.ImGui_Button(UI.ctx, "+", -1) then
								UI.core.state.fx_collapsed[fx_id] = false
							end
							local enabled = fx_data.enabled
							UI.r.ImGui_PushStyleVar(UI.ctx, UI.r.ImGui_StyleVar_ButtonTextAlign(), 0.5, 0.0)
							local fx_name_vertical = ""
							for i = 1, #fx_data.name do
								fx_name_vertical = fx_name_vertical .. fx_data.name:sub(i, i) .. "\n"
							end
							if UI.r.ImGui_Button(UI.ctx, fx_name_vertical, -1, 242) then
								local actual_fx_id = fx_data.actual_fx_id or fx_id
								UI.r.TrackFX_Show(UI.core.state.track, actual_fx_id, 3)
							end
							UI.r.ImGui_PopStyleVar(UI.ctx)
							if UI.r.ImGui_Checkbox(UI.ctx, "##enabled" .. fx_id, enabled) then
								local actual_fx_id = fx_data.actual_fx_id or fx_id
								UI.r.TrackFX_SetEnabled(UI.core.state.track, actual_fx_id, not enabled)
								fx_data.enabled = not enabled
							end
						else
							local content_width = UI.r.ImGui_GetContentRegionAvail(UI.ctx)
							local num_elements_line1 = 3
							local num_spacings_line1 = num_elements_line1 - 1
							local available_width_line1 = content_width - (num_spacings_line1 * UI.item_spacing_x)
							local part_width_line1 = available_width_line1 / 15

							if UI.r.ImGui_Button(UI.ctx, "-", part_width_line1) then
								UI.core.state.fx_collapsed[fx_id] = true
							end
							UI.r.ImGui_SameLine(UI.ctx, 0, UI.item_spacing_x)
							if UI.r.ImGui_Button(UI.ctx, fx_data.name, 13 * part_width_line1) then
								local actual_fx_id = fx_data.actual_fx_id or fx_id
								local is_visible = UI.r.TrackFX_GetOpen(UI.core.state.track, actual_fx_id)
								UI.r.TrackFX_Show(UI.core.state.track, actual_fx_id, is_visible and 2 or 3)
							end
							UI.r.ImGui_SameLine(UI.ctx, 0, UI.item_spacing_x)
							local enabled = fx_data.enabled
							if UI.r.ImGui_Checkbox(UI.ctx, "##enabled" .. fx_id, enabled) then
								local actual_fx_id = fx_data.actual_fx_id or fx_id
								UI.r.TrackFX_SetEnabled(UI.core.state.track, actual_fx_id, not enabled)
								fx_data.enabled = not enabled
							end
							local num_items = 5
							local item_width = (content_width - (UI.item_spacing_x * (num_items - 1))) / num_items
							if UI.r.ImGui_Button(UI.ctx, "All##" .. fx_id, item_width) then
								UI.fxmanager.selectAllParams(fx_data.params, true)
								UI.fxmanager.saveTrackSelection()
							end
							UI.r.ImGui_SameLine(UI.ctx)
							if UI.r.ImGui_Button(UI.ctx, "Cont##" .. fx_id, item_width) then
								UI.fxmanager.selectAllContinuousParams(fx_data.params, true)
								UI.fxmanager.saveTrackSelection()
							end
							UI.r.ImGui_SameLine(UI.ctx)
							if UI.r.ImGui_Button(UI.ctx, "None##" .. fx_id, item_width) then
								UI.fxmanager.selectAllParams(fx_data.params, false)
								UI.fxmanager.saveTrackSelection()
							end
							UI.r.ImGui_SameLine(UI.ctx)
							if UI.r.ImGui_Button(UI.ctx, "Rnd##" .. fx_id, item_width) then
								UI.fxmanager.randomSelectParams(fx_data.params, fx_id)
								UI.fxmanager.saveTrackSelection()
							end
							UI.r.ImGui_SameLine(UI.ctx)
							UI.r.ImGui_SetNextItemWidth(UI.ctx, item_width)
							local fx_key = UI.core.getFXKey(fx_id)
							local current_max = (fx_key and UI.core.state.fx_random_max[fx_key]) or 3
							local changed, new_max = UI.r.ImGui_SliderInt(UI.ctx, "##max" .. fx_id, current_max, 1, 10)
							if changed and fx_key then
								UI.core.state.fx_random_max[fx_key] = new_max
								UI.fxmanager.saveTrackSelection()
							end
							local num_items = 3
							local item_width = (content_width - (UI.item_spacing_x * (num_items - 1))) / num_items
							if UI.r.ImGui_Button(UI.ctx, "RandXY##" .. fx_id, item_width) then
								UI.fxmanager.randomizeXYAssign(fx_data.params, fx_id)
							end
							UI.r.ImGui_SameLine(UI.ctx)
							if UI.r.ImGui_Button(UI.ctx, "RandRng##" .. fx_id, item_width) then
								UI.fxmanager.randomizeRanges(fx_data.params, fx_id)
							end
							UI.r.ImGui_SameLine(UI.ctx)
							if UI.r.ImGui_Button(UI.ctx, "RndBase##" .. fx_id, item_width) then
								UI.fxmanager.randomizeBaseValues(fx_data.params, fx_id)
							end
							UI.r.ImGui_Dummy(UI.ctx, 0, 0)
							local table_flags = UI.r.ImGui_TableFlags_SizingStretchProp()
							if UI.r.ImGui_BeginTable(UI.ctx, "params" .. fx_id, 6, table_flags) then
								UI.r.ImGui_TableSetupColumn(UI.ctx, "Name", 0, 4.0)
								UI.r.ImGui_TableSetupColumn(UI.ctx, "N", 0, 1.0)
								UI.r.ImGui_TableSetupColumn(UI.ctx, "X", 0, 1.0)
								UI.r.ImGui_TableSetupColumn(UI.ctx, "Y", 0, 1.0)
								UI.r.ImGui_TableSetupColumn(UI.ctx, "Range", 0, 2.0)
								UI.r.ImGui_TableSetupColumn(UI.ctx, "Base", 0, 2.0)
								for param_id, param_data in pairs(fx_data.params) do
									UI.r.ImGui_PushID(UI.ctx, fx_id * 10000 + param_id)
									UI.r.ImGui_TableNextRow(UI.ctx)
									UI.r.ImGui_TableNextColumn(UI.ctx)
									local param_name = param_data.name
									if #param_name > 14 then
										param_name = param_name:sub(1, 11) .. "..."
									end
									local changed, selected = UI.r.ImGui_Checkbox(UI.ctx, param_name .. "##" .. fx_id .. "_" .. param_id, param_data.selected)
									if changed then
										param_data.selected = selected
										UI.fxmanager.updateSelectedCount()
										if selected then
											param_data.base_value = param_data.current_value
										end
										UI.fxmanager.saveTrackSelection()
									end
									if UI.r.ImGui_IsItemHovered(UI.ctx) then
										UI.r.ImGui_SetTooltip(UI.ctx, param_data.name)
									end
									UI.r.ImGui_TableNextColumn(UI.ctx)
									local param_invert = UI.fxmanager.getParamInvert(fx_id, param_id)
									if UI.r.ImGui_Button(UI.ctx, param_invert and "N" or "P" .. "##n" .. fx_id .. "_" .. param_id, -1) then
										UI.fxmanager.setParamInvert(fx_id, param_id, not param_invert)
									end
									UI.r.ImGui_TableNextColumn(UI.ctx)
									local x_assign, y_assign = UI.fxmanager.getParamXYAssign(fx_id, param_id)
									if UI.r.ImGui_Button(UI.ctx, x_assign and "X" or "-" .. "##x" .. fx_id .. "_" .. param_id, -1) then
										UI.fxmanager.setParamXYAssign(fx_id, param_id, "x", not x_assign)
									end
									UI.r.ImGui_TableNextColumn(UI.ctx)
									if UI.r.ImGui_Button(UI.ctx, y_assign and "Y" or "-" .. "##y" .. fx_id .. "_" .. param_id, -1) then
										UI.fxmanager.setParamXYAssign(fx_id, param_id, "y", not y_assign)
									end
									UI.r.ImGui_TableNextColumn(UI.ctx)
									UI.r.ImGui_SetNextItemWidth(UI.ctx, -1)
									local range = UI.fxmanager.getParamRange(fx_id, param_id)
									local changed, new_range = UI.r.ImGui_SliderDouble(UI.ctx, "##r" .. fx_id .. "_" .. param_id, range, 0.1, 1.0, "%.1f")
									if changed then
										UI.fxmanager.setParamRange(fx_id, param_id, new_range)
									end
									UI.r.ImGui_TableNextColumn(UI.ctx)
									UI.r.ImGui_SetNextItemWidth(UI.ctx, -1)
									local format_str = "%.2f"
									local display_value = param_data.base_value
									local real_min = param_data.min_val
									local real_max = param_data.max_val
									local real_current = UI.core.denormalizeParamValue(param_data.current_value, real_min, real_max)
									local real_base = UI.core.denormalizeParamValue(param_data.base_value, real_min, real_max)

									if param_data.step_count and param_data.step_count == 2 then
										format_str = param_data.base_value > 0.5 and "ON" or "OFF"
										display_value = param_data.base_value > 0.5 and 1.0 or 0.0
									elseif param_data.step_count and param_data.step_count > 2 and param_data.step_count <= 5 then
										local step_index = math.floor(param_data.base_value * (param_data.step_count - 1) + 0.5)
										format_str = tostring(step_index + 1) .. "/" .. param_data.step_count
									elseif real_min ~= 0 or real_max ~= 1 then
										format_str = string.format("%.2f", real_base)
									end

									local changed, new_base = UI.r.ImGui_SliderDouble(UI.ctx, "##b" .. fx_id .. "_" .. param_id, param_data.base_value, 0.0, 1.0, format_str)
									if changed then
										if param_data.step_count and param_data.step_count > 0 then
											new_base = UI.core.snapToDiscreteValue(new_base, param_data.step_count)
										end
										UI.fxmanager.updateParamBaseValue(fx_id, param_id, new_base)
									end
									if UI.r.ImGui_IsItemHovered(UI.ctx) then
										local xy_text = ""
										if x_assign and y_assign then
											xy_text = " [XY]"
										elseif x_assign then
											xy_text = " [X]"
										elseif y_assign then
											xy_text = " [Y]"
										end
										local invert_text = param_invert and " [INVERTED]" or ""
										local value_text = string.format("Current: %.3f, Base: %.3f", real_current, real_base)
										if real_min ~= 0 or real_max ~= 1 then
											value_text = value_text .. string.format(" (%.1f to %.1f)", real_min, real_max)
										end
										UI.r.ImGui_SetTooltip(UI.ctx, param_data.name .. "\n" .. value_text .. string.format("\nRange: %.1f", range) .. xy_text .. invert_text)
									end
									UI.r.ImGui_PopID(UI.ctx)
								end
								UI.r.ImGui_EndTable(UI.ctx)
							end
						end
						UI.r.ImGui_EndChild(UI.ctx)
					end
					UI.r.ImGui_PopStyleVar(UI.ctx)
					UI.r.ImGui_EndGroup(UI.ctx)
				end
			end
			UI.r.ImGui_EndChild(UI.ctx)
		end
	else
		UI.r.ImGui_Text(UI.ctx, "No FX found")
	end
end

function UI.drawFiltersWindow()
	if not UI.core.state.show_filters_window then return end
	if not UI.filters_ctx or not UI.r.ImGui_ValidatePtr(UI.filters_ctx, "ImGui_Context*") then
		UI.filters_ctx = UI.r.ImGui_CreateContext('FX Constellation Filters')
		if UI.style_loader then
			UI.style_loader.ApplyFontsToContext(UI.filters_ctx)
		end
	end
	if UI.style_loader then
		local success, colors, vars = UI.style_loader.applyToContext(UI.filters_ctx)
		if success then UI.filters_pushed_colors, UI.filters_pushed_vars = colors, vars end
	end
	UI.r.ImGui_SetNextWindowSize(UI.filters_ctx, 400, 300, UI.r.ImGui_Cond_FirstUseEver())
	local visible, open = UI.r.ImGui_Begin(UI.filters_ctx, 'Filter Keywords', true)
	if visible then
		local main_font = UI.getStyleFont("main", UI.filters_ctx)
		local header_font = UI.getStyleFont("header", UI.filters_ctx)

		if main_font and UI.r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
			UI.r.ImGui_PushFont(UI.filters_ctx, main_font, 0)
		end

		if header_font and UI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
			UI.r.ImGui_PushFont(UI.filters_ctx, header_font, 0)
			UI.r.ImGui_Text(UI.filters_ctx, "FILTER KEYWORDS")
			UI.r.ImGui_PopFont(UI.filters_ctx)
		else
			UI.r.ImGui_Text(UI.filters_ctx, "Filter Keywords:")
		end

		local changed, new_word = UI.r.ImGui_InputText(UI.filters_ctx, "Add Filter", UI.core.state.new_filter_word)
		if changed then UI.core.state.new_filter_word = new_word end
		UI.r.ImGui_SameLine(UI.filters_ctx)
		if UI.r.ImGui_Button(UI.filters_ctx, "Add") and UI.core.state.new_filter_word ~= "" then
			table.insert(UI.core.state.filter_keywords, UI.core.state.new_filter_word)
			UI.core.state.new_filter_word = ""
			UI.persistence.scheduleSave()
			UI.fxmanager.scanTrackFX()
		end
		for i, keyword in ipairs(UI.core.state.filter_keywords) do
			UI.r.ImGui_Text(UI.filters_ctx, keyword)
			UI.r.ImGui_SameLine(UI.filters_ctx)
			if UI.r.ImGui_Button(UI.filters_ctx, "X##" .. i) then
				table.remove(UI.core.state.filter_keywords, i)
				UI.persistence.scheduleSave()
				UI.fxmanager.scanTrackFX()
				break
			end
		end
		UI.r.ImGui_Separator(UI.filters_ctx)
		UI.r.ImGui_Text(UI.filters_ctx, "Param Filter:")
		UI.r.ImGui_SameLine(UI.filters_ctx)
		UI.r.ImGui_SetNextItemWidth(UI.filters_ctx, 200)
		local changed, new_filter = UI.r.ImGui_InputText(UI.filters_ctx, "##paramfilter", UI.core.state.param_filter)
		if changed then
			UI.core.state.param_filter = new_filter
			UI.fxmanager.scanTrackFX()
		end

		if main_font and UI.r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
			UI.r.ImGui_PopFont(UI.filters_ctx)
		end
		UI.r.ImGui_End(UI.filters_ctx)
	end
	if not open then
		UI.core.state.show_filters_window = false
	end
	if UI.style_loader then UI.style_loader.clearStyles(UI.filters_ctx, UI.filters_pushed_colors, UI.filters_pushed_vars) end
end

function UI.drawHorizontalLayout()
	if UI.r.ImGui_BeginChild(UI.ctx, "Navigation", 160, 0) then
		UI.drawNavigation()
		UI.r.ImGui_EndChild(UI.ctx)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_BeginChild(UI.ctx, "Mode", 128, 0) then
		UI.drawMode()
		UI.r.ImGui_EndChild(UI.ctx)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_BeginChild(UI.ctx, "SoundGen", 160, 0) then
		UI.drawSoundGenerator()
		UI.r.ImGui_EndChild(UI.ctx)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_BeginChild(UI.ctx, "PadXY", 298, 0) then
		UI.drawPadSection()
		UI.r.ImGui_EndChild(UI.ctx)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_BeginChild(UI.ctx, "Randomizer", 128, 0) then
		UI.drawRandomizer()
		UI.r.ImGui_EndChild(UI.ctx)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_BeginChild(UI.ctx, "Presets", 180, 0) then
		UI.drawPresets()
		UI.r.ImGui_EndChild(UI.ctx)
	end
	UI.r.ImGui_SameLine(UI.ctx)
	UI.r.ImGui_Dummy(UI.ctx, 0, 0)
	UI.r.ImGui_SameLine(UI.ctx)
	if UI.r.ImGui_BeginChild(UI.ctx, "FX", 0, 0) then
		UI.drawFXSection()
		UI.r.ImGui_EndChild(UI.ctx)
	end
end

function UI.drawInterface()
	if UI.style_loader then
		local success, colors, vars = UI.style_loader.applyToContext(UI.ctx)
		if success then UI.pushed_colors, UI.pushed_vars = colors, vars end
	end

	UI.r.ImGui_SetNextWindowSize(UI.ctx, 1400, 800, UI.r.ImGui_Cond_FirstUseEver())
	local window_flags = UI.r.ImGui_WindowFlags_NoTitleBar() | UI.r.ImGui_WindowFlags_NoCollapse()
	local visible, open = UI.r.ImGui_Begin(UI.ctx, 'FX Constellation', true, window_flags)
	if visible then
		if UI.style_loader and UI.style_loader.PushFont(UI.ctx, "header") then
			local lock_icon = UI.core.state.track_locked and "[L] " or ""
			UI.r.ImGui_Text(UI.ctx, lock_icon .. "FX Constellation")
			UI.style_loader.PopFont(UI.ctx)
		else
			local lock_icon = UI.core.state.track_locked and "[L] " or ""
			UI.r.ImGui_Text(UI.ctx, lock_icon .. "FX Constellation")
		end

		UI.r.ImGui_SameLine(UI.ctx)
		local lock_button_size = UI.header_font_size + 6
		if UI.r.ImGui_Button(UI.ctx, UI.core.state.track_locked and "U" or "L", lock_button_size, lock_button_size) then
			if UI.core.state.track_locked then
				UI.core.state.track_locked = false
				UI.core.state.locked_track = nil
			else
				UI.core.state.track_locked = true
				UI.core.state.locked_track = UI.core.state.track
			end
		end
		if UI.r.ImGui_IsItemHovered(UI.ctx) then
			UI.r.ImGui_SetTooltip(UI.ctx, UI.core.state.track_locked and "Unlock track" or "Lock to current track")
		end

		UI.r.ImGui_SameLine(UI.ctx)
		local close_button_size = UI.header_font_size + 6
		local close_x = UI.r.ImGui_GetWindowWidth(UI.ctx) - close_button_size - UI.window_padding_x
		UI.r.ImGui_SetCursorPosX(UI.ctx, close_x)
		if UI.r.ImGui_Button(UI.ctx, "X", close_button_size, close_button_size) then
			open = false
		end

		if UI.style_loader and UI.style_loader.PushFont(UI.ctx, "main") then
			UI.r.ImGui_Separator(UI.ctx)

			UI.persistence.checkSave()
			UI.gesture.updateGestureMotion()

			if not UI.core.state.track_locked then
				local new_track = UI.r.GetSelectedTrack(0, 0)
				if new_track ~= UI.core.state.track then
					if UI.core.state.track then UI.fxmanager.saveTrackSelection() end
					UI.core.state.track = new_track
					if UI.core.state.track then
						UI.fxmanager.scanTrackFX()
						UI.core.state.jsfx_automation_index = UI.gesture.findAutomationJSFX()
						UI.core.state.jsfx_automation_enabled = UI.core.state.jsfx_automation_index >= 0
					end
				end
			else
				if UI.core.state.locked_track and UI.r.ValidatePtr(UI.core.state.locked_track, "MediaTrack*") then
					UI.core.state.track = UI.core.state.locked_track
				else
					UI.core.state.track_locked = false
					UI.core.state.locked_track = nil
				end
			end
			if UI.core.isTrackValid() then
				UI.fxmanager.checkForFXChanges()
				UI.presetsystem.checkPresetModification()
			end
			if not UI.core.isTrackValid() then
				UI.r.ImGui_Text(UI.ctx, "No track selected")
				if UI.style_loader and UI.style_loader.PopFont then UI.style_loader.PopFont(UI.ctx) end
				UI.r.ImGui_End(UI.ctx)
				if UI.style_loader then UI.style_loader.clearStyles(UI.ctx, UI.pushed_colors, UI.pushed_vars) end
				return open
			end

			UI.drawHorizontalLayout()

			UI.style_loader.PopFont(UI.ctx)
		end
		UI.r.ImGui_End(UI.ctx)
	end
	if UI.style_loader then UI.style_loader.clearStyles(UI.ctx, UI.pushed_colors, UI.pushed_vars) end
	UI.drawFiltersWindow()
	UI.drawLicenseWindow()
	return open
end

function UI.drawLicenseWindow()
	if not UI.core.state.show_license_window then return end

	UI.r.ImGui_SetNextWindowSize(UI.ctx, 400, 250, UI.r.ImGui_Cond_FirstUseEver())
	local visible, open = UI.r.ImGui_Begin(UI.ctx, 'FX Constellation - License', true)
	if visible then
		local status = UI.license.getStatus()

		if status == "FULL" then
			UI.r.ImGui_TextColored(UI.ctx, 0x00FF00FF, "✓ Licensed")
			UI.r.ImGui_Text(UI.ctx, "Thank you for supporting FX Constellation!")
			UI.r.ImGui_Dummy(UI.ctx, 0, 10)
			if UI.r.ImGui_Button(UI.ctx, "Close", 100) then
				UI.core.state.show_license_window = false
			end
		else
			if status == "INVALID" then
				UI.r.ImGui_TextColored(UI.ctx, 0xFF0000FF, "✗ Invalid License Key")
				UI.r.ImGui_Dummy(UI.ctx, 0, 5)
			end

			UI.r.ImGui_Text(UI.ctx, "FX Constellation FREE")
			UI.r.ImGui_Separator(UI.ctx)
			UI.r.ImGui_Dummy(UI.ctx, 0, 5)
			UI.r.ImGui_Text(UI.ctx, "Upgrade to unlock:")
			UI.r.ImGui_BulletText(UI.ctx, "Sound Generator")
			UI.r.ImGui_BulletText(UI.ctx, "Unlimited FX (FREE: max 10)")
			UI.r.ImGui_BulletText(UI.ctx, "Granular mode")
			UI.r.ImGui_BulletText(UI.ctx, "Random Walk & Figures")
			UI.r.ImGui_Dummy(UI.ctx, 0, 10)

			UI.r.ImGui_Text(UI.ctx, "Enter License Key:")
			UI.r.ImGui_SetNextItemWidth(UI.ctx, 350)
			local changed, new_key = UI.r.ImGui_InputText(UI.ctx, "##licensekey", UI.license_key_input)
			if changed then
				UI.license_key_input = new_key
			end

			UI.r.ImGui_Dummy(UI.ctx, 0, 5)

			if UI.r.ImGui_Button(UI.ctx, "Activate", 100) then
				if UI.license.validate(UI.license_key_input) then
					UI.license.setKey(UI.license_key_input)
					UI.license_key_input = ""
				end
			end
			UI.r.ImGui_SameLine(UI.ctx)
			if UI.r.ImGui_Button(UI.ctx, "Cancel", 100) then
				UI.core.state.show_license_window = false
				UI.license_key_input = ""
			end
		end

		UI.r.ImGui_End(UI.ctx)
	end
	if not open then
		UI.core.state.show_license_window = false
	end
end

return UI
