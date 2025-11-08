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
	local source_path = script_path .. "JSFX/FX Constellation - Sound Generator.jsfx"
	local target_path = SoundGenerator.r.GetResourcePath() .. "/Effects/FX Constellation - Sound Generator.jsfx"

	local source_file = io.open(source_path, "r")
	if not source_file then return false end
	local jsfx_code = source_file:read("*all")
	source_file:close()

	local target_file = io.open(target_path, "w")
	if target_file then
		target_file:write(jsfx_code)
		target_file:close()
		return true
	end
	return false
end

function SoundGenerator.createGenerator()
	if not SoundGenerator.core.isTrackValid() then return false end
	local sg = SoundGenerator.core.state.sound_generator
	if sg.enabled then return true end

	SoundGenerator.removeAllSoundGenerators()

	if not SoundGenerator.installJSFX() then return false end

	local fx_index = SoundGenerator.r.TrackFX_AddByName(SoundGenerator.core.state.track, "FX Constellation - Sound Generator", false, -1000)
	if fx_index >= 0 then
		sg.enabled = true
		sg.jsfx_index = 0
		SoundGenerator.r.TrackFX_Show(SoundGenerator.core.state.track, 0, 0)
		SoundGenerator.updateJSFXParams()
		return true
	end
	return false
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
	if not sg.enabled or sg.jsfx_index < 0 then return end
	if not SoundGenerator.core.isTrackValid() then return end

	SoundGenerator.r.TrackFX_Delete(SoundGenerator.core.state.track, sg.jsfx_index)
	sg.enabled = false
	sg.jsfx_index = -1
end

function SoundGenerator.updateJSFXParams()
	local sg = SoundGenerator.core.state.sound_generator
	if not sg.enabled or sg.jsfx_index < 0 then return end
	if not SoundGenerator.core.isTrackValid() then return end

	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 0, sg.mode)
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 1, SoundGenerator.normalize(sg.waveform, 0, 5))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 2, SoundGenerator.normalize(sg.frequency, 20, 20000))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 3, SoundGenerator.normalize(sg.width, 0, 100))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 4, SoundGenerator.normalize(sg.amplitude, 0, 1))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 5, SoundGenerator.normalize(sg.noise_color, 0, 1))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 6, sg.rhythmic and 1 or 0)
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 7, SoundGenerator.normalize(sg.tick_rate, 0.1, 20))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 8, SoundGenerator.normalize(sg.duty_cycle, 0.01, 0.99))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 9, sg.use_adsr and 1 or 0)
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 10, SoundGenerator.normalize(sg.attack, 0.001, 2))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 11, SoundGenerator.normalize(sg.decay, 0.001, 2))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 12, SoundGenerator.normalize(sg.sustain, 0, 1))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 13, SoundGenerator.normalize(sg.release, 0.001, 5))
	SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 14, sg.midi_mode and 1 or 0)
end

function SoundGenerator.syncFromJSFX()
	local sg = SoundGenerator.core.state.sound_generator
	if not sg.enabled or sg.jsfx_index < 0 then return end
	if not SoundGenerator.core.isTrackValid() then return end

	local _, fx_name = SoundGenerator.r.TrackFX_GetFXName(SoundGenerator.core.state.track, 0, "")
	if not fx_name:find("Sound Generator") then
		sg.enabled = false
		sg.jsfx_index = -1
		return
	end

	sg.mode = math.floor(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 0) + 0.5)
	sg.waveform = math.floor(SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 1), 0, 5) + 0.5)
	sg.frequency = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 2), 20, 20000)
	sg.width = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 3), 0, 100)
	sg.amplitude = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 4), 0, 1)
	sg.noise_color = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 5), 0, 1)
	sg.rhythmic = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 6) > 0.5
	sg.tick_rate = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 7), 0.1, 20)
	sg.duty_cycle = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 8), 0.01, 0.99)
	sg.use_adsr = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 9) > 0.5
	sg.attack = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 10), 0.001, 2)
	sg.decay = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 11), 0.001, 2)
	sg.sustain = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 12), 0, 1)
	sg.release = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 13), 0.001, 5)
	sg.midi_mode = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, 0, 14) > 0.5
end

function SoundGenerator.setManualTrigger(value)
	local sg = SoundGenerator.core.state.sound_generator
	if sg.mode == 1 and sg.enabled and sg.jsfx_index >= 0 then
		if not SoundGenerator.core.isTrackValid() then return end
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 15, value and 1 or 0)
	end
end

return SoundGenerator
