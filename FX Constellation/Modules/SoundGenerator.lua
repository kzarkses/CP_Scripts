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

function SoundGenerator.createUnifiedJSFX()
	if not SoundGenerator.core.isTrackValid() then return false end
	local jsfx_code = [[desc: FX Constellation - Sound Generator
slider1:mode=0<0,1,1{Continuous,Triggered}>Mode
slider2:waveform=0<0,5,1{Sine,Triangle,Square,Saw,Noise,Click}>Type
slider3:frequency=440<20,20000,1>Frequency (Hz)
slider4:width=10<0,100,0.1>Width (cents)
slider5:amplitude=0.5<0,1,0.01>Amplitude
slider6:noise_color=0.5<0,1,0.01>Noise Color
slider7:rhythmic=0<0,1,1{Off,On}>Rhythmic
slider8:tick_rate=4<0.1,20,0.1>Tick Rate (Hz)
slider9:duty_cycle=0.5<0.01,0.99,0.01>Duty Cycle
slider10:use_adsr=1<0,1,1{Off,On}>ADSR
slider11:attack=0.01<0.001,2,0.001>Attack (s)
slider12:decay=0.1<0.001,2,0.001>Decay (s)
slider13:sustain=0.7<0,1,0.01>Sustain
slider14:release=0.2<0.001,5,0.001>Release (s)
slider15:midi_mode=0<0,1,1{Manual,MIDI}>Trigger Mode
slider16:manual_trigger=0<0,1,1>Manual Trigger

@init
pos_l = 0;
pos_r = 0;
tick_phase = 0;
brown_l = 0;
brown_r = 0;
pi2 = $pi * 2;
env = 0;
env_state = 0;
note_on = 0;
last_manual = 0;
click_phase = 0;

@slider
amp = amplitude;

@block
mode > 0.5 && midi_mode > 0.5 ? (
	while (midirecv(offset, msg1, msg2, msg3)) (
		status = msg1 & 0xF0;
		status == 0x90 && msg3 > 0 ? (
			note_on = 1;
			midi_note = msg2;
			env_state = 1;
			env = 0;
			click_phase = 0;
		) : status == 0x80 || (status == 0x90 && msg3 == 0) ? (
			note_on = 0;
			env_state = 3;
		);
		midisend(offset, msg1, msg2, msg3);
	);
) : mode > 0.5 ? (
	manual_trigger > 0.5 && last_manual < 0.5 ? (
		note_on = 1;
		env_state = 1;
		env = 0;
		click_phase = 0;
	) : manual_trigger < 0.5 && last_manual > 0.5 ? (
		note_on = 0;
		env_state = 3;
	);
	last_manual = manual_trigger;
);

@sample
dt = 1 / srate;

// Calculate base frequency
mode > 0.5 && midi_mode > 0.5 && note_on ? (
	base_freq = frequency * 2^((midi_note - 69) / 12);
) : (
	base_freq = frequency;
);

// Width as detune in cents - force absolute mono if width = 0
width <= 0.0 ? (
	freq_l = base_freq;
	freq_r = base_freq;
) : (
	cents_to_ratio = 2^(width / 1200);
	freq_l = base_freq / cents_to_ratio;
	freq_r = base_freq * cents_to_ratio;
);

// Phase increment (REAPER style: 2*pi*freq/srate)
adj_l = pi2 * freq_l / srate;
adj_r = pi2 * freq_r / srate;

// CONTINUOUS MODE
mode < 0.5 ? (
	tick_on = 1;
	rhythmic > 0.5 ? (
		tick_phase += tick_rate * dt;
		tick_phase >= 1 ? tick_phase -= 1;
		tick_on = tick_phase < duty_cycle;
	);

	tick_on ? (
		waveform < 0.5 ? (
			out_l = cos(pos_l);
			out_r = cos(pos_r);
		) : waveform < 1.5 ? (
			tone_l = 2.0 * pos_l / $pi - 1.0;
			tone_l > 1.0 ? tone_l = 2.0 - tone_l;
			tone_r = 2.0 * pos_r / $pi - 1.0;
			tone_r > 1.0 ? tone_r = 2.0 - tone_r;
			out_l = tone_l;
			out_r = tone_r;
		) : waveform < 2.5 ? (
			out_l = (pos_l % pi2) < $pi ? 1 : -1;
			out_r = (pos_r % pi2) < $pi ? 1 : -1;
		) : waveform < 3.5 ? (
			out_l = 1.0 - pos_l / $pi;
			out_r = 1.0 - pos_r / $pi;
		) : waveform < 4.5 ? (
			white_l = rand() * 2 - 1;
			white_r = rand() * 2 - 1;
			brown_l += (white_l - brown_l) * 0.1;
			brown_r += (white_r - brown_r) * 0.1;
			brown_l = max(-1, min(1, brown_l));
			brown_r = max(-1, min(1, brown_r));
			out_l = white_l * (1 - noise_color) + brown_l * noise_color;
			out_r = white_r * (1 - noise_color) + brown_r * noise_color;
		) : (
			click_phase < 0.005 ? (
				click_env = 1 - (click_phase / 0.005);
				click_env = click_env * click_env;
				white_l = rand() * 2 - 1;
				white_r = rand() * 2 - 1;
				out_l = white_l * click_env;
				out_r = white_r * click_env;
			) : (
				out_l = 0;
				out_r = 0;
			);
			click_phase += dt;
			click_phase >= 0.005 ? click_phase = 0.005;
		);

		waveform < 4 ? (
			pos_l += adj_l;
			pos_r += adj_r;
			pos_l >= pi2 ? pos_l -= pi2;
			pos_r >= pi2 ? pos_r -= pi2;
		);

		waveform > 4.5 && rhythmic > 0.5 ? (
			tick_phase < (dt * tick_rate) ? click_phase = 0;
		);

		spl0 = out_l * amp;
		spl1 = out_r * amp;
	) : (
		spl0 = 0;
		spl1 = 0;
	);
) : (
	use_adsr > 0.5 ? (
		env_state == 1 ? (
			env += dt / attack;
			env >= 1 ? (
				env = 1;
				env_state = 2;
			);
		) : env_state == 2 ? (
			target = sustain;
			env -= (env - target) * (1 - exp(-5 * dt / decay));
			abs(env - sustain) < 0.001 ? env = sustain;
		) : env_state == 3 ? (
			env -= env * (1 - exp(-5 * dt / release));
			env <= 0.001 ? (
				env = 0;
				env_state = 0;
			);
		);
	) : (
		env = note_on ? 1 : 0;
	);

	env > 0 ? (
		waveform < 0.5 ? (
			out_l = cos(pos_l);
			out_r = cos(pos_r);
		) : waveform < 1.5 ? (
			tone_l = 2.0 * pos_l / $pi - 1.0;
			tone_l > 1.0 ? tone_l = 2.0 - tone_l;
			tone_r = 2.0 * pos_r / $pi - 1.0;
			tone_r > 1.0 ? tone_r = 2.0 - tone_r;
			out_l = tone_l;
			out_r = tone_r;
		) : waveform < 2.5 ? (
			out_l = (pos_l % pi2) < $pi ? 1 : -1;
			out_r = (pos_r % pi2) < $pi ? 1 : -1;
		) : waveform < 3.5 ? (
			out_l = 1.0 - pos_l / $pi;
			out_r = 1.0 - pos_r / $pi;
		) : waveform < 4.5 ? (
			white_l = rand() * 2 - 1;
			white_r = rand() * 2 - 1;
			brown_l += (white_l - brown_l) * 0.1;
			brown_r += (white_r - brown_r) * 0.1;
			brown_l = max(-1, min(1, brown_l));
			brown_r = max(-1, min(1, brown_r));
			out_l = white_l * (1 - noise_color) + brown_l * noise_color;
			out_r = white_r * (1 - noise_color) + brown_r * noise_color;
		) : (
			click_phase < 0.005 ? (
				click_env = 1 - (click_phase / 0.005);
				click_env = click_env * click_env;
				white_l = rand() * 2 - 1;
				white_r = rand() * 2 - 1;
				out_l = white_l * click_env;
				out_r = white_r * click_env;
				click_phase += dt;
			) : (
				out_l = 0;
				out_r = 0;
			);
		);

		waveform < 4 ? (
			pos_l += adj_l;
			pos_r += adj_r;
			pos_l >= pi2 ? pos_l -= pi2;
			pos_r >= pi2 ? pos_r -= pi2;
		);

		spl0 = out_l * env * amp;
		spl1 = out_r * env * amp;
	) : (
		spl0 = 0;
		spl1 = 0;
	);
);
]]

	local jsfx_path = SoundGenerator.r.GetResourcePath() .. "/Effects/FX Constellation - Sound Generator.jsfx"
	local file = io.open(jsfx_path, "w")
	if file then
		file:write(jsfx_code)
		file:close()
		return true
	end
	return false
end

function SoundGenerator.createGenerator()
	if not SoundGenerator.core.isTrackValid() then return false end
	local sg = SoundGenerator.core.state.sound_generator
	if sg.enabled then return true end

	if not SoundGenerator.createUnifiedJSFX() then return false end

	local fx_index = SoundGenerator.r.TrackFX_AddByName(SoundGenerator.core.state.track, "FX Constellation - Sound Generator", false, -1000)
	if fx_index >= 0 then
		sg.enabled = true
		sg.jsfx_index = 0
		SoundGenerator.updateJSFXParams()
		return true
	end
	return false
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
