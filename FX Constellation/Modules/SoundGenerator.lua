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

function SoundGenerator.createContinuousJSFX()
	if not SoundGenerator.core.isTrackValid() then return false end
	local jsfx_code = [[desc: FX Constellation - Sound Generator Continuous
slider1:waveform=0<0,5,1{Sine,Triangle,Square,Saw,Noise,Click}>Type
slider2:frequency=440<20,20000,1>Frequency (Hz)
slider3:width=10<0,100,0.1>Width (cents)
slider4:amplitude=0.5<0,1,0.01>Amplitude
slider5:noise_color=0.5<0,1,0.01>Noise Color
slider6:rhythmic=0<0,1,1{Off,On}>Rhythmic
slider7:tick_rate=4<0.1,20,0.1>Tick Rate (Hz)
slider8:duty_cycle=0.5<0.01,0.99,0.01>Duty Cycle

@init
phase_l = 0;
phase_r = 0;
tick_phase = 0;
brown_l = 0;
brown_r = 0;
pi2 = $pi * 2;
click_phase = 0;

@slider
amp = amplitude;

@sample
dt = 1 / srate;

// Width as detune in cents
cents_to_ratio = 2^(width / 1200);
freq_l = frequency / cents_to_ratio;
freq_r = frequency * cents_to_ratio;

phase_inc_l = freq_l * dt;
phase_inc_r = freq_r * dt;

// Rhythmic gating
tick_on = 1;
rhythmic == 1 ? (
	tick_phase += tick_rate * dt;
	tick_on = (tick_phase % 1) < duty_cycle;
	tick_phase >= 1 ? tick_phase -= 1;
);

tick_on ? (
	out_l = 0;
	out_r = 0;

	// Waveforms 0-3: Oscillators
	waveform == 0 ? (
		// Sine
		out_l = sin(phase_l * pi2);
		out_r = sin(phase_r * pi2);
	) : waveform == 1 ? (
		// Triangle
		t_l = (phase_l % 1);
		t_r = (phase_r % 1);
		out_l = t_l < 0.5 ? (t_l * 4 - 1) : (3 - t_l * 4);
		out_r = t_r < 0.5 ? (t_r * 4 - 1) : (3 - t_r * 4);
	) : waveform == 2 ? (
		// Square
		out_l = (phase_l % 1) < 0.5 ? 1 : -1;
		out_r = (phase_r % 1) < 0.5 ? 1 : -1;
	) : waveform == 3 ? (
		// Saw
		out_l = (phase_l % 1) * 2 - 1;
		out_r = (phase_r % 1) * 2 - 1;
	) : waveform == 4 ? (
		// Noise
		white_l = rand() * 2 - 1;
		white_r = rand() * 2 - 1;
		brown_l += (white_l - brown_l) * 0.1;
		brown_r += (white_r - brown_r) * 0.1;
		brown_l = max(-1, min(1, brown_l));
		brown_r = max(-1, min(1, brown_r));
		out_l = white_l * (1 - noise_color) + brown_l * noise_color;
		out_r = white_r * (1 - noise_color) + brown_r * noise_color;
	) : waveform == 5 ? (
		// Click
		click_phase < 0.005 ? (
			env = 1 - (click_phase / 0.005);
			env = env * env;
			white_l = rand() * 2 - 1;
			white_r = rand() * 2 - 1;
			out_l = white_l * env;
			out_r = white_r * env;
		) : (
			out_l = 0;
			out_r = 0;
		);
		click_phase += dt;
		click_phase >= 0.005 ? click_phase = 0.005;
	);

	// Advance oscillator phases
	waveform < 4 ? (
		phase_l += phase_inc_l;
		phase_r += phase_inc_r;
		phase_l >= 1 ? phase_l -= 1;
		phase_r >= 1 ? phase_r -= 1;
	);

	// Reset click phase on tick start for rhythmic mode
	waveform == 5 && rhythmic == 1 ? (
		(tick_phase % 1) < (dt * tick_rate) ? (
			click_phase = 0;
		);
	);
) : (
	out_l = 0;
	out_r = 0;
);

spl0 = out_l * amp;
spl1 = out_r * amp;
]]

	local jsfx_path = SoundGenerator.r.GetResourcePath() .. "/Effects/FX Constellation - Sound Generator Continuous.jsfx"
	local file = io.open(jsfx_path, "w")
	if file then
		file:write(jsfx_code)
		file:close()
		return true
	end
	return false
end

function SoundGenerator.createTriggeredJSFX()
	if not SoundGenerator.core.isTrackValid() then return false end
	local jsfx_code = [[desc: FX Constellation - Sound Generator Triggered
slider1:waveform=0<0,5,1{Sine,Triangle,Square,Saw,Noise,Click}>Type
slider2:frequency=440<20,20000,1>Base Frequency (Hz)
slider3:width=10<0,100,0.1>Width (cents)
slider4:amplitude=0.5<0,1,0.01>Amplitude
slider5:noise_color=0.5<0,1,0.01>Noise Color
slider6:use_adsr=1<0,1,1{Off,On}>ADSR
slider7:attack=0.01<0.001,2,0.001>Attack (s)
slider8:decay=0.1<0.001,2,0.001>Decay (s)
slider9:sustain=0.7<0,1,0.01>Sustain
slider10:release=0.2<0.001,5,0.001>Release (s)
slider11:midi_mode=0<0,1,1{Manual,MIDI}>Trigger Mode
slider12:manual_trigger=0<0,1,1>Manual Trigger

@init
phase_l = 0;
phase_r = 0;
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
midi_mode == 1 ? (
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
) : (
	manual_trigger == 1 && last_manual == 0 ? (
		note_on = 1;
		env_state = 1;
		env = 0;
		click_phase = 0;
	) : manual_trigger == 0 && last_manual == 1 ? (
		note_on = 0;
		env_state = 3;
	);
	last_manual = manual_trigger;
);

@sample
dt = 1 / srate;

// Calculate frequency from MIDI note or base frequency
midi_mode == 1 && note_on ? (
	target_freq = frequency * 2^((midi_note - 69) / 12);
) : (
	target_freq = frequency;
);

// Width as detune in cents
cents_to_ratio = 2^(width / 1200);
freq_l = target_freq / cents_to_ratio;
freq_r = target_freq * cents_to_ratio;

phase_inc_l = freq_l * dt;
phase_inc_r = freq_r * dt;

// ADSR Envelope
use_adsr == 1 ? (
	env_state == 1 ? (
		env += dt / attack;
		env >= 1 ? (
			env = 1;
			env_state = 2;
		);
	) : env_state == 2 ? (
		env -= dt * (1 - sustain) / decay;
		env <= sustain ? (
			env = sustain;
		);
	) : env_state == 3 ? (
		env -= dt * sustain / release;
		env <= 0 ? (
			env = 0;
			env_state = 0;
		);
	);
) : (
	env = note_on ? 1 : 0;
);

env > 0 ? (
	out_l = 0;
	out_r = 0;

	// Waveforms 0-3: Oscillators
	waveform == 0 ? (
		// Sine
		out_l = sin(phase_l * pi2);
		out_r = sin(phase_r * pi2);
	) : waveform == 1 ? (
		// Triangle
		t_l = (phase_l % 1);
		t_r = (phase_r % 1);
		out_l = t_l < 0.5 ? (t_l * 4 - 1) : (3 - t_l * 4);
		out_r = t_r < 0.5 ? (t_r * 4 - 1) : (3 - t_r * 4);
	) : waveform == 2 ? (
		// Square
		out_l = (phase_l % 1) < 0.5 ? 1 : -1;
		out_r = (phase_r % 1) < 0.5 ? 1 : -1;
	) : waveform == 3 ? (
		// Saw
		out_l = (phase_r % 1) * 2 - 1;
		out_r = (phase_r % 1) * 2 - 1;
	) : waveform == 4 ? (
		// Noise
		white_l = rand() * 2 - 1;
		white_r = rand() * 2 - 1;
		brown_l += (white_l - brown_l) * 0.1;
		brown_r += (white_r - brown_r) * 0.1;
		brown_l = max(-1, min(1, brown_l));
		brown_r = max(-1, min(1, brown_r));
		out_l = white_l * (1 - noise_color) + brown_l * noise_color;
		out_r = white_r * (1 - noise_color) + brown_r * noise_color;
	) : waveform == 5 ? (
		// Click
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

	// Advance oscillator phases
	waveform < 4 ? (
		phase_l += phase_inc_l;
		phase_r += phase_inc_r;
		phase_l >= 1 ? phase_l -= 1;
		phase_r >= 1 ? phase_r -= 1;
	);

	spl0 = out_l * env * amp;
	spl1 = out_r * env * amp;
) : (
	spl0 = 0;
	spl1 = 0;
);
]]

	local jsfx_path = SoundGenerator.r.GetResourcePath() .. "/Effects/FX Constellation - Sound Generator Triggered.jsfx"
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

	local jsfx_name = sg.mode == 0 and "FX Constellation - Sound Generator Continuous" or "FX Constellation - Sound Generator Triggered"

	if sg.mode == 0 then
		if not SoundGenerator.createContinuousJSFX() then return false end
	else
		if not SoundGenerator.createTriggeredJSFX() then return false end
	end

	local fx_index = SoundGenerator.r.TrackFX_AddByName(SoundGenerator.core.state.track, jsfx_name, false, -1)
	if fx_index >= 0 then
		sg.enabled = true
		sg.jsfx_index = fx_index
		SoundGenerator.r.TrackFX_Show(SoundGenerator.core.state.track, fx_index, 0)
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

	if sg.mode == 0 then
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 0, SoundGenerator.normalize(sg.waveform, 0, 5))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 1, SoundGenerator.normalize(sg.frequency, 20, 20000))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 2, SoundGenerator.normalize(sg.width, 0, 100))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 3, SoundGenerator.normalize(sg.amplitude, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 4, SoundGenerator.normalize(sg.noise_color, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 5, sg.rhythmic and 1 or 0)
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 6, SoundGenerator.normalize(sg.tick_rate, 0.1, 20))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 7, SoundGenerator.normalize(sg.duty_cycle, 0.01, 0.99))
	else
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 0, SoundGenerator.normalize(sg.waveform, 0, 5))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 1, SoundGenerator.normalize(sg.frequency, 20, 20000))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 2, SoundGenerator.normalize(sg.width, 0, 100))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 3, SoundGenerator.normalize(sg.amplitude, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 4, SoundGenerator.normalize(sg.noise_color, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 5, sg.use_adsr and 1 or 0)
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 6, SoundGenerator.normalize(sg.attack, 0.001, 2))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 7, SoundGenerator.normalize(sg.decay, 0.001, 2))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 8, SoundGenerator.normalize(sg.sustain, 0, 1))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 9, SoundGenerator.normalize(sg.release, 0.001, 5))
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 10, sg.midi_mode and 1 or 0)
	end
end

function SoundGenerator.syncFromJSFX()
	local sg = SoundGenerator.core.state.sound_generator
	if not sg.enabled or sg.jsfx_index < 0 then return end
	if not SoundGenerator.core.isTrackValid() then return end

	if sg.mode == 0 then
		sg.waveform = math.floor(SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 0), 0, 5) + 0.5)
		sg.frequency = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 1), 20, 20000)
		sg.width = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 2), 0, 100)
		sg.amplitude = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 3), 0, 1)
		sg.noise_color = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 4), 0, 1)
		sg.rhythmic = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 5) > 0.5
		sg.tick_rate = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 6), 0.1, 20)
		sg.duty_cycle = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 7), 0.01, 0.99)
	else
		sg.waveform = math.floor(SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 0), 0, 5) + 0.5)
		sg.frequency = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 1), 20, 20000)
		sg.width = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 2), 0, 100)
		sg.amplitude = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 3), 0, 1)
		sg.noise_color = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 4), 0, 1)
		sg.use_adsr = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 5) > 0.5
		sg.attack = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 6), 0.001, 2)
		sg.decay = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 7), 0.001, 2)
		sg.sustain = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 8), 0, 1)
		sg.release = SoundGenerator.denormalize(SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 9), 0.001, 5)
		sg.midi_mode = SoundGenerator.r.TrackFX_GetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 10) > 0.5
	end
end

function SoundGenerator.setManualTrigger(value)
	local sg = SoundGenerator.core.state.sound_generator
	if sg.mode == 1 and sg.enabled and sg.jsfx_index >= 0 then
		if not SoundGenerator.core.isTrackValid() then return end
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, sg.jsfx_index, 11, value and 1 or 0)
	end
end

return SoundGenerator
