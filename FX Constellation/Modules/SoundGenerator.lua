local SoundGenerator = {}

function SoundGenerator.init(reaper_api, core)
	SoundGenerator.r = reaper_api
	SoundGenerator.core = core
end

function SoundGenerator.normalize(value, min_val, max_val)
	return (value - min_val) / (max_val - min_val)
end

function SoundGenerator.denormalize(normalized, min_val, max_val)
	return normalized * (max_val - min_val) + min_val
end

function SoundGenerator.installJSFX()
	if not SoundGenerator.core.isTrackValid() then return false end
	local script_path = SoundGenerator.r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/"
	local effects_path = SoundGenerator.r.GetResourcePath() .. "/Effects/"

	-- Install Continuous JSFX
	local source_continuous = script_path .. "JSFX/FX Constellation - Sound Generator Continuous.jsfx"
	local target_continuous = effects_path .. "FX Constellation - Sound Generator Continuous.jsfx"
	local file = io.open(source_continuous, "r")
	if not file then return false end
	local code = file:read("*all")
	file:close()
	local out = io.open(target_continuous, "w")
	if not out then return false end
	out:write(code)
	out:close()

	-- Install Triggered JSFX
	local source_triggered = script_path .. "JSFX/FX Constellation - Sound Generator Triggered.jsfx"
	local target_triggered = effects_path .. "FX Constellation - Sound Generator Triggered.jsfx"
	file = io.open(source_triggered, "r")
	if not file then return false end
	code = file:read("*all")
	file:close()
	out = io.open(target_triggered, "w")
	if not out then return false end
	out:write(code)
	out:close()

	return true
end

function SoundGenerator.createGenerator()
	if not SoundGenerator.core.isTrackValid() then return false end
	local sg = SoundGenerator.core.state.sound_generator
	if sg.enabled then return true end

	SoundGenerator.removeAllSoundGenerators()

	if not SoundGenerator.installJSFX() then return false end

	-- Add Continuous JSFX at position 0
	local continuous_idx = SoundGenerator.r.TrackFX_AddByName(SoundGenerator.core.state.track, "FX Constellation - Sound Generator Continuous", false, -1000)
	if continuous_idx < 0 then return false end

	-- Add Triggered JSFX at position 1
	local triggered_idx = SoundGenerator.r.TrackFX_AddByName(SoundGenerator.core.state.track, "FX Constellation - Sound Generator Triggered", false, -1000)
	if triggered_idx < 0 then
		SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, continuous_idx)
		return false
	end

	sg.enabled = true
	sg.jsfx_continuous_index = continuous_idx
	sg.jsfx_triggered_index = triggered_idx

	-- Bypass the one not in use
	if sg.mode == 0 then
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, continuous_idx, true)
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, triggered_idx, false)
	else
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, continuous_idx, false)
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, triggered_idx, true)
	end

	SoundGenerator.updateJSFXParams()
	return true
end

function SoundGenerator.removeAllSoundGenerators()
	if not SoundGenerator.core.isTrackValid() then return end
	local fx_count = SoundGenerator.r.TrackFX_GetCount(SoundGenerator.core.state.track)
	for i = fx_count - 1, 0, -1 do
		local _, fx_name = SoundGenerator.r.TrackFX_GetFXName(SoundGenerator.core.state.track, i, "")
		if fx_name:find("Sound Generator") then
			SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, i)
		end
	end
end

function SoundGenerator.removeAllSoundGenerators()
	if not SoundGenerator.core.isTrackValid() then return end
	local fx_count = SoundGenerator.r.TrackFX_GetCount(SoundGenerator.core.state.track)
	for i = fx_count - 1, 0, -1 do
		local _, fx_name = SoundGenerator.r.TrackFX_GetFXName(SoundGenerator.core.state.track, i, "")
		if fx_name:find("Sound Generator") then
			SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, i)
		end
	end
end

function SoundGenerator.removeGenerator()
	local sg = SoundGenerator.core.state.sound_generator
	if not sg.enabled then return end
	if not SoundGenerator.core.isTrackValid() then return end

	-- Remove both JSFX (remove higher index first to avoid shifting)
	if sg.jsfx_triggered_index and sg.jsfx_triggered_index >= 0 then
		if sg.jsfx_triggered_index > sg.jsfx_continuous_index then
			SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, sg.jsfx_triggered_index)
			SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, sg.jsfx_continuous_index)
		else
			SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, sg.jsfx_continuous_index)
			SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, sg.jsfx_triggered_index)
		end
	end

	sg.enabled = false
	sg.jsfx_continuous_index = -1
	sg.jsfx_triggered_index = -1
end

function SoundGenerator.updateJSFXParams()
	local sg = SoundGenerator.core.state.sound_generator
	if not sg.enabled then return end
	if not SoundGenerator.core.isTrackValid() then return end

	if sg.mode == 0 then
		-- Continuous mode parameters
		local idx = sg.jsfx_continuous_index
		if idx < 0 then return end
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 0, SoundGenerator.normalize(sg.waveform, 0, 5))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 1, SoundGenerator.normalize(sg.frequency, 20, 20000))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 2, SoundGenerator.normalize(sg.width, 0, 100))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 3, SoundGenerator.normalize(sg.amplitude, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 4, SoundGenerator.normalize(sg.noise_color, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 5, sg.rhythmic and 1 or 0)
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 6, SoundGenerator.normalize(sg.tick_rate, 0.1, 20))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 7, SoundGenerator.normalize(sg.duty_cycle, 0.01, 0.99))

		-- Enable Continuous, disable Triggered
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, sg.jsfx_continuous_index, true)
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, sg.jsfx_triggered_index, false)
	else
		-- Triggered mode parameters
		local idx = sg.jsfx_triggered_index
		if idx < 0 then return end
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 0, SoundGenerator.normalize(sg.waveform, 0, 5))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 1, SoundGenerator.normalize(sg.frequency, 20, 20000))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 2, SoundGenerator.normalize(sg.width, 0, 100))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 3, SoundGenerator.normalize(sg.amplitude, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 4, SoundGenerator.normalize(sg.noise_color, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 5, sg.use_adsr and 1 or 0)
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 6, SoundGenerator.normalize(sg.attack, 0.001, 2))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 7, SoundGenerator.normalize(sg.decay, 0.001, 2))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 8, SoundGenerator.normalize(sg.sustain, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 9, SoundGenerator.normalize(sg.release, 0.001, 5))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, 10, sg.midi_mode and 1 or 0)

		-- Disable Continuous, enable Triggered
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, sg.jsfx_continuous_index, false)
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, sg.jsfx_triggered_index, true)
	end
end

function SoundGenerator.syncFromJSFX()
	local sg = SoundGenerator.core.state.sound_generator
	if not sg.enabled then return end
	if not SoundGenerator.core.isTrackValid() then return end

	local idx = sg.mode == 0 and sg.jsfx_continuous_index or sg.jsfx_triggered_index
	if idx < 0 then return end

	local _, fx_name = SoundGenerator.r.TrackFX_GetFXName(SoundGenerator.core.state.track, idx, "")
	if not fx_name:find("Sound Generator") then
		sg.enabled = false
		sg.jsfx_continuous_index = -1
		sg.jsfx_triggered_index = -1
		return
	end

	-- Read common parameters
	sg.waveform = math.floor(SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 0), 0, 5) + 0.5)
	sg.frequency = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 1), 20, 20000)
	sg.width = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 2), 0, 100)
	sg.amplitude = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 3), 0, 1)
	sg.noise_color = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 4), 0, 1)

	if sg.mode == 0 then
		-- Continuous mode specific
		sg.rhythmic = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 5) > 0.5
		sg.tick_rate = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 6), 0.1, 20)
		sg.duty_cycle = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 7), 0.01, 0.99)
	else
		-- Triggered mode specific
		sg.use_adsr = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 5) > 0.5
		sg.attack = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 6), 0.001, 2)
		sg.decay = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 7), 0.001, 2)
		sg.sustain = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 8), 0, 1)
		sg.release = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 9), 0.001, 5)
		sg.midi_mode = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, idx, 10) > 0.5
	end
end

function SoundGenerator.setManualTrigger(value)
	local sg = SoundGenerator.core.state.sound_generator
	if sg.mode == 1 and sg.enabled and sg.jsfx_triggered_index >= 0 then
		if not SoundGenerator.core.isTrackValid() then return end
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_triggered_index, 11, value and 1 or 0)
	end
end

return SoundGenerator
