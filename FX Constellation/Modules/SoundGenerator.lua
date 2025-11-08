local SoundGenerator = {}

function SoundGenerator.init(reaper_api, core)
	SoundGenerator.r = reaper_api
	SoundGenerator.core = core
end

function SoundGenerator.createContinuousJSFX()
	if not SoundGenerator.core.isTrackValid() then return false end
	local jsfx_code = [[desc: FX Constellation - Sound Generator (Continuous)
slider1:mode=0<0,1,1{Constant,Rhythmic}>Mode
slider2:waveform=0<0,3,1{Sine,Triangle,Square,Saw}>Waveform
slider3:freq=440<20,20000,1>Frequency (Hz)
slider4:tick_rate=4<0.1,20,0.1>Tick Rate (Hz)
slider5:duty_cycle=0.5<0.01,0.99,0.01>Duty Cycle
slider6:noise_color=0.5<0,1,0.01>Noise Color
slider7:amplitude=0.5<0,1,0.01>Amplitude
slider8:stereo_width=1.0<0,1,0.01>Stereo Width

@init
phase = 0;
tick_phase = 0;
brown_l = 0;
brown_r = 0;
pi2 = $pi * 2;

@slider
amp = amplitude;

@sample
dt = 1 / srate;
phase_inc = freq * dt;

mode == 0 ? (
	out_l = 0;
	out_r = 0;
	waveform == 0 ? (
		out_l = out_r = sin(phase * pi2);
	) : waveform == 1 ? (
		t = (phase % 1);
		out_l = out_r = t < 0.5 ? (t * 4 - 1) : (3 - t * 4);
	) : waveform == 2 ? (
		out_l = out_r = (phase % 1) < 0.5 ? 1 : -1;
	) : waveform == 3 ? (
		out_l = out_r = (phase % 1) * 2 - 1;
	);
	phase += phase_inc;
	phase >= 1 ? phase -= 1;
) : (
	tick_phase += tick_rate * dt;
	tick_on = (tick_phase % 1) < duty_cycle;
	tick_phase >= 1 ? tick_phase -= 1;
	tick_on ? (
		out_l = 0;
		out_r = 0;
		waveform == 0 ? (
			out_l = out_r = sin(phase * pi2);
		) : waveform == 1 ? (
			t = (phase % 1);
			out_l = out_r = t < 0.5 ? (t * 4 - 1) : (3 - t * 4);
		) : waveform == 2 ? (
			out_l = out_r = (phase % 1) < 0.5 ? 1 : -1;
		) : waveform == 3 ? (
			out_l = out_r = (phase % 1) * 2 - 1;
		);
		phase += phase_inc;
		phase >= 1 ? phase -= 1;
	) : (
		out_l = out_r = 0;
	);
);

white_l = rand() * 2 - 1;
white_r = rand() * 2 - 1;
brown_l += (white_l - brown_l) * 0.1;
brown_r += (white_r - brown_r) * 0.1;
pink_l = white_l * (1 - noise_color) + brown_l * noise_color;
pink_r = white_r * (1 - noise_color) + brown_r * noise_color;

final_l = out_l * (1 - noise_color) + pink_l * noise_color;
final_r = out_r * (1 - noise_color) + pink_r * noise_color;

mid = (final_l + final_r) * 0.5;
side = (final_l - final_r) * 0.5 * stereo_width;
spl0 = (mid + side) * amp;
spl1 = (mid - side) * amp;
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
	local jsfx_code = [[desc: FX Constellation - Sound Generator (Triggered)
slider1:waveform=0<0,3,1{Sine,Triangle,Square,Saw}>Waveform
slider2:base_freq=440<20,20000,1>Base Frequency (Hz)
slider3:use_adsr=1<0,1,1{Off,On}>ADSR
slider4:attack=0.01<0.001,2,0.001>Attack (s)
slider5:decay=0.1<0.001,2,0.001>Decay (s)
slider6:sustain=0.7<0,1,0.01>Sustain
slider7:release=0.2<0.001,5,0.001>Release (s)
slider8:midi_mode=1<0,1,1{Off,On}>MIDI Trigger
slider9:manual_trigger=0<0,1,1>Manual Trigger
slider10:amplitude=0.5<0,1,0.01>Amplitude
slider11:stereo_width=1.0<0,1,0.01>Stereo Width

@init
phase = 0;
env = 0;
note_on = 0;
note_freq = base_freq;
env_state = 0;
pi2 = $pi * 2;

@slider
amp = amplitude;

@block
midi_mode ? (
	while(midirecv(offset, msg1, msg2, msg3)) (
		status = msg1 & 0xF0;
		status == 0x90 && msg3 > 0 ? (
			note_on = 1;
			env_state = 1;
			note_num = msg2;
			note_freq = 440 * pow(2, (note_num - 69) / 12);
			phase = 0;
		) : status == 0x80 || (status == 0x90 && msg3 == 0) ? (
			note_on = 0;
			env_state = 4;
		);
		midisend(offset, msg1, msg2, msg3);
	);
) : (
	manual_trigger > 0 && !note_on ? (
		note_on = 1;
		env_state = 1;
		note_freq = base_freq;
		phase = 0;
	);
	manual_trigger == 0 && note_on ? (
		note_on = 0;
		env_state = 4;
	);
);

@sample
dt = 1 / srate;

use_adsr ? (
	env_state == 1 ? (
		env += dt / attack;
		env >= 1 ? (
			env = 1;
			env_state = 2;
		);
	) : env_state == 2 ? (
		env -= (1 - sustain) * dt / decay;
		env <= sustain ? (
			env = sustain;
			env_state = 3;
		);
	) : env_state == 3 ? (
		env = sustain;
	) : env_state == 4 ? (
		env -= sustain * dt / release;
		env <= 0 ? (
			env = 0;
			env_state = 0;
		);
	);
) : (
	env = note_on ? 1 : 0;
);

out_l = 0;
out_r = 0;

env > 0 ? (
	phase_inc = note_freq * dt;
	waveform == 0 ? (
		out_l = out_r = sin(phase * pi2);
	) : waveform == 1 ? (
		t = (phase % 1);
		out_l = out_r = t < 0.5 ? (t * 4 - 1) : (3 - t * 4);
	) : waveform == 2 ? (
		out_l = out_r = (phase % 1) < 0.5 ? 1 : -1;
	) : waveform == 3 ? (
		out_l = out_r = (phase % 1) * 2 - 1;
	);
	phase += phase_inc;
	phase >= 1 ? phase -= 1;
	out_l *= env;
	out_r *= env;
);

mid = (out_l + out_r) * 0.5;
side = (out_l - out_r) * 0.5 * stereo_width;
spl0 = (mid + side) * amp;
spl1 = (mid - side) * amp;
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
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 0, sg.rhythmic and 1 or 0)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 1, sg.waveform)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 2, sg.frequency)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 3, sg.tick_rate)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 4, sg.duty_cycle)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 5, sg.noise_color)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 6, sg.amplitude)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 7, sg.stereo_width)
	else
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 0, sg.waveform)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 1, sg.base_freq)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 2, sg.use_adsr and 1 or 0)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 3, sg.attack)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 4, sg.decay)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 5, sg.sustain)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 6, sg.release)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 7, sg.midi_mode and 1 or 0)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 9, sg.amplitude)
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 10, sg.stereo_width)
	end
end

function SoundGenerator.setManualTrigger(value)
	local sg = SoundGenerator.core.state.sound_generator
	if sg.mode == 1 and sg.enabled and sg.jsfx_index >= 0 then
		SoundGenerator.r.TrackFX_SetParam(SoundGenerator.core.state.track, sg.jsfx_index, 8, value and 1 or 0)
	end
end

return SoundGenerator
