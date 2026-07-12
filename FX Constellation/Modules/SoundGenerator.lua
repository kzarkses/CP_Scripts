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

-- ---------------------------------------------------------------------------
-- Param map — single source of truth for the Lua ↔ JSFX slider mapping.
-- `p` is the 0-based TrackFX param index (= slider number - 1). `path` walks
-- into core.state.sound_generator. Sliders 1-17 keep the legacy single-osc
-- layout (osc 1 occupies the old waveform/freq/width/color slots) so projects
-- saved with the previous generator load with identical sound; osc 2/3 and
-- the per-osc volumes are appended after.
-- ---------------------------------------------------------------------------
SoundGenerator.PARAM_SPEC = {
	{ p = 0,  path = { "mode" },              min = 0,     max = 1,     kind = "int" },
	{ p = 1,  path = { "osc", 1, "wave" },    min = 0,     max = 5,     kind = "int" },
	{ p = 2,  path = { "osc", 1, "freq" },    min = 20,    max = 20000 },
	{ p = 3,  path = { "osc", 1, "width" },   min = 0,     max = 100 },
	{ p = 4,  path = { "amplitude" },         min = 0,     max = 1 },
	{ p = 5,  path = { "osc", 1, "color" },   min = 0,     max = 1 },
	{ p = 6,  path = { "rhythmic" },          kind = "bool" },
	{ p = 7,  path = { "tick_rate" },         min = 0.1,   max = 20 },
	{ p = 8,  path = { "duty_cycle" },        min = 0.01,  max = 0.99 },
	{ p = 9,  path = { "rhythmic_curve" },    min = 0,     max = 1 },
	{ p = 10, path = { "use_adsr" },          kind = "bool" },
	{ p = 11, path = { "attack" },            min = 0.001, max = 2 },
	{ p = 12, path = { "decay" },             min = 0.001, max = 2 },
	{ p = 13, path = { "sustain" },           min = 0,     max = 1 },
	{ p = 14, path = { "release" },           min = 0.001, max = 5 },
	{ p = 15, path = { "midi_mode" },         kind = "bool" },
	-- p = 16 is the transient manual trigger — never synced.
	{ p = 17, path = { "osc", 1, "on" },      kind = "bool" },
	{ p = 18, path = { "osc", 1, "vol" },     min = 0,     max = 1 },
	{ p = 19, path = { "osc", 2, "on" },      kind = "bool" },
	{ p = 20, path = { "osc", 2, "wave" },    min = 0,     max = 5,     kind = "int" },
	{ p = 21, path = { "osc", 2, "freq" },    min = 20,    max = 20000 },
	{ p = 22, path = { "osc", 2, "width" },   min = 0,     max = 100 },
	{ p = 23, path = { "osc", 2, "vol" },     min = 0,     max = 1 },
	{ p = 24, path = { "osc", 2, "color" },   min = 0,     max = 1 },
	{ p = 25, path = { "osc", 3, "on" },      kind = "bool" },
	{ p = 26, path = { "osc", 3, "wave" },    min = 0,     max = 5,     kind = "int" },
	{ p = 27, path = { "osc", 3, "freq" },    min = 20,    max = 20000 },
	{ p = 28, path = { "osc", 3, "width" },   min = 0,     max = 100 },
	{ p = 29, path = { "osc", 3, "vol" },     min = 0,     max = 1 },
	{ p = 30, path = { "osc", 3, "color" },   min = 0,     max = 1 }
}

local MANUAL_TRIGGER_PARAM = 16

local function specGet(sg, spec)
	local node = sg
	for i = 1, #spec.path - 1 do
		node = node[spec.path[i]]
		if not node then return nil end
	end
	return node[spec.path[#spec.path]]
end

local function specSet(sg, spec, value)
	local node = sg
	for i = 1, #spec.path - 1 do
		node = node[spec.path[i]]
		if not node then return end
	end
	node[spec.path[#spec.path]] = value
end

-- ---------------------------------------------------------------------------
-- JSFX source. Multi-oscillator generator:
--   • 3 oscillators, each: on/off, waveform (Sine/Triangle/Square/Saw/Noise/
--     Click), frequency, stereo width (detune in cents), volume, noise color
--   • master amplitude, continuous/triggered modes
--   • continuous: optional rhythmic gate (rate, duty, smoothing curve)
--   • triggered: master ADSR, manual hold or MIDI note trigger (osc
--     frequencies track the played note relative to A4)
-- Per-osc phase/noise/click state lives in memory arrays indexed by osc so
-- the DSP is one shared function instead of six copy-pasted branches.
-- ---------------------------------------------------------------------------
local JSFX_SOURCE = [[desc: FX Constellation - Sound Generator
slider1:mode=0<0,1,1{Continuous,Triggered}>Mode
slider2:osc1_wave=0<0,5,1{Sine,Triangle,Square,Saw,Noise,Click}>Osc1 Wave
slider3:osc1_freq=440<20,20000,1>Osc1 Freq (Hz)
slider4:osc1_width=0<0,100,0.1>Osc1 Width (cents)
slider5:amplitude=0.5<0,1,0.01>Master Amp
slider6:osc1_color=0.5<0,1,0.01>Osc1 Noise Color
slider7:rhythmic=0<0,1,1{Off,On}>Rhythmic
slider8:tick_rate=4<0.1,20,0.1>Tick Rate (Hz)
slider9:duty_cycle=0.5<0.01,0.99,0.01>Duty Cycle
slider10:rhythmic_curve=0.01<0,1,0.01>Rhythmic Curve
slider11:use_adsr=1<0,1,1{Off,On}>ADSR
slider12:attack=0.01<0.001,2,0.001>Attack (s)
slider13:decay=0.1<0.001,2,0.001>Decay (s)
slider14:sustain=0.7<0,1,0.01>Sustain
slider15:release=0.2<0.001,5,0.001>Release (s)
slider16:midi_mode=0<0,1,1{Manual,MIDI}>Trigger Mode
slider17:manual_trigger=0<0,1,1>Manual Trigger
slider18:osc1_on=1<0,1,1{Off,On}>Osc1 On
slider19:osc1_vol=1<0,1,0.01>Osc1 Volume
slider20:osc2_on=0<0,1,1{Off,On}>Osc2 On
slider21:osc2_wave=3<0,5,1{Sine,Triangle,Square,Saw,Noise,Click}>Osc2 Wave
slider22:osc2_freq=220<20,20000,1>Osc2 Freq (Hz)
slider23:osc2_width=10<0,100,0.1>Osc2 Width (cents)
slider24:osc2_vol=0.5<0,1,0.01>Osc2 Volume
slider25:osc2_color=0.5<0,1,0.01>Osc2 Noise Color
slider26:osc3_on=0<0,1,1{Off,On}>Osc3 On
slider27:osc3_wave=1<0,5,1{Sine,Triangle,Square,Saw,Noise,Click}>Osc3 Wave
slider28:osc3_freq=880<20,20000,1>Osc3 Freq (Hz)
slider29:osc3_width=10<0,100,0.1>Osc3 Width (cents)
slider30:osc3_vol=0.5<0,1,0.01>Osc3 Volume
slider31:osc3_color=0.5<0,1,0.01>Osc3 Noise Color

@init
pi2 = $pi * 2;
env = 0;
env_state = 0;
note_on = 0;
last_manual = 0;
tick_phase = 0;
tick_env = 1;
note_ratio = 1;

// per-osc state arrays (memory base addresses, index 0..2)
posl = 0;
posr = 4;
brnl = 8;
brnr = 12;
clkp = 16;

// slider numbers per osc (osc1 keeps the legacy slots)
sl_on  = 24; sl_on[0]  = 18; sl_on[1]  = 20; sl_on[2]  = 26;
sl_wav = 28; sl_wav[0] = 2;  sl_wav[1] = 21; sl_wav[2] = 27;
sl_frq = 32; sl_frq[0] = 3;  sl_frq[1] = 22; sl_frq[2] = 28;
sl_wid = 36; sl_wid[0] = 4;  sl_wid[1] = 23; sl_wid[2] = 29;
sl_vol = 40; sl_vol[0] = 19; sl_vol[1] = 24; sl_vol[2] = 30;
sl_col = 44; sl_col[0] = 6;  sl_col[1] = 25; sl_col[2] = 31;

// One oscillator sample. Writes out_l/out_r (globals).
function osc_sample(idx, wave, freq, width, color)
	local(fl fr ratio adjl adjr pl pr w ce)
(
	width <= 0.0 ? (
		fl = freq;
		fr = freq;
	) : (
		ratio = 2^(width / 1200);
		fl = freq / ratio;
		fr = freq * ratio;
	);
	wave < 3.5 ? (
		adjl = pi2 * fl / srate;
		adjr = pi2 * fr / srate;
		pl = posl[idx];
		pr = posr[idx];
		wave < 0.5 ? (
			out_l = cos(pl);
			out_r = cos(pr);
		) : wave < 1.5 ? (
			out_l = 2.0 * pl / $pi - 1.0;
			out_l > 1.0 ? out_l = 2.0 - out_l;
			out_r = 2.0 * pr / $pi - 1.0;
			out_r > 1.0 ? out_r = 2.0 - out_r;
		) : wave < 2.5 ? (
			out_l = pl < $pi ? 1 : -1;
			out_r = pr < $pi ? 1 : -1;
		) : (
			out_l = 1.0 - pl / $pi;
			out_r = 1.0 - pr / $pi;
		);
		pl += adjl; pl >= pi2 ? pl -= pi2;
		pr += adjr; pr >= pi2 ? pr -= pi2;
		posl[idx] = pl;
		posr[idx] = pr;
	) : wave < 4.5 ? (
		w = rand() * 2 - 1;
		brnl[idx] += (w - brnl[idx]) * 0.1;
		brnl[idx] = max(-1, min(1, brnl[idx]));
		out_l = w * (1 - color) + brnl[idx] * color;
		width <= 0.0 ? (
			out_r = out_l;
		) : (
			w = rand() * 2 - 1;
			brnr[idx] += (w - brnr[idx]) * 0.1;
			brnr[idx] = max(-1, min(1, brnr[idx]));
			out_r = w * (1 - color) + brnr[idx] * color;
		);
	) : (
		clkp[idx] < 0.005 ? (
			ce = 1 - clkp[idx] / 0.005;
			ce = ce * ce;
			out_l = (rand() * 2 - 1) * ce;
			out_r = width <= 0.0 ? out_l : (rand() * 2 - 1) * ce;
			clkp[idx] += dt;
		) : (
			out_l = 0;
			out_r = 0;
		);
	);
);

@block
mode > 0.5 && midi_mode > 0.5 ? (
	while (midirecv(offset, msg1, msg2, msg3)) (
		status = msg1 & 0xF0;
		status == 0x90 && msg3 > 0 ? (
			note_on = 1;
			midi_note = msg2;
			env_state = 1;
			env = 0;
			clkp[0] = 0; clkp[1] = 0; clkp[2] = 0;
		) : status == 0x80 || (status == 0x90 && msg3 == 0) ? (
			note_on = 0;
			env_state = 3;
		);
		midisend(offset, msg1, msg2, msg3);
	);
);

mode > 0.5 ? (
	manual_trigger > 0.5 && last_manual < 0.5 ? (
		note_on = 1;
		env_state = 1;
		env = 0;
		clkp[0] = 0; clkp[1] = 0; clkp[2] = 0;
	) : manual_trigger < 0.5 && last_manual > 0.5 ? (
		note_on = 0;
		env_state = 3;
	);
	last_manual = manual_trigger;
);

@sample
dt = 1 / srate;

// Oscillators follow the played note relative to A4 in MIDI trigger mode.
note_ratio = (mode > 0.5 && midi_mode > 0.5 && note_on) ? 2^((midi_note - 69) / 12) : 1;

// Gate/envelope
mode < 0.5 ? (
	// CONTINUOUS: optional rhythmic gate
	rhythmic > 0.5 ? (
		tick_phase += tick_rate * dt;
		tick_phase >= 1 ? (
			tick_phase -= 1;
			clkp[0] = 0; clkp[1] = 0; clkp[2] = 0;   // retrigger clicks per tick
		);
		target_env = tick_phase < duty_cycle ? 1 : 0;
		rhythmic_curve > 0.001 ? (
			tick_env += (target_env - tick_env) * min(1, dt / (rhythmic_curve * 0.1));
		) : (
			tick_env = target_env;
		);
	) : (
		tick_env = 1;
	);
	gate = tick_env;
) : (
	// TRIGGERED: master ADSR (or plain gate when ADSR is off)
	use_adsr > 0.5 ? (
		env_state == 1 ? (
			env += dt / attack;
			env >= 1 ? (
				env = 1;
				env_state = 2;
			);
		) : env_state == 2 ? (
			env -= (env - sustain) * (1 - exp(-5 * dt / decay));
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
	gate = env;
);

gate > 0 ? (
	mix_l = 0;
	mix_r = 0;
	i = 0;
	loop(3,
		slider(sl_on[i]) > 0.5 ? (
			osc_sample(i, slider(sl_wav[i]), note_ratio * slider(sl_frq[i]),
			           slider(sl_wid[i]), slider(sl_col[i]));
			v = slider(sl_vol[i]);
			mix_l += out_l * v;
			mix_r += out_r * v;
		);
		i += 1;
	);
	spl0 = mix_l * amplitude * gate;
	spl1 = mix_r * amplitude * gate;
) : (
	spl0 = 0;
	spl1 = 0;
);
]]

function SoundGenerator.createUnifiedJSFX()
	local jsfx_path = SoundGenerator.r.GetResourcePath() .. "/Effects/FX Constellation - Sound Generator.jsfx"
	local file = io.open(jsfx_path, "w")
	if file then
		file:write(JSFX_SOURCE)
		file:close()
		return true
	end
	return false
end

-- Resolve the generator's FX index by name. The old code assumed index 0
-- forever: as soon as anything else sat at the top of the chain (the bridge
-- after a preset load, a manually moved FX), updateJSFXParams would write 16
-- parameters into an unrelated plugin.
function SoundGenerator.resolveIndex()
	local sg = SoundGenerator.core.state.sound_generator
	if not SoundGenerator.core.isTrackValid() then return -1 end
	local track = SoundGenerator.core.state.track
	local fx_count = SoundGenerator.r.TrackFX_GetCount(track)
	local idx = sg.jsfx_index
	if idx and idx >= 0 and idx < fx_count then
		local _, name = SoundGenerator.r.TrackFX_GetFXName(track, idx, "")
		if name:find("Sound Generator") then return idx end
	end
	for fx = 0, fx_count - 1 do
		local _, name = SoundGenerator.r.TrackFX_GetFXName(track, fx, "")
		if name:find("Sound Generator") then
			sg.jsfx_index = fx
			return fx
		end
	end
	sg.jsfx_index = -1
	return -1
end

function SoundGenerator.createGenerator()
	if not SoundGenerator.core.isTrackValid() then return false end
	local sg = SoundGenerator.core.state.sound_generator

	if not SoundGenerator.createUnifiedJSFX() then return false end

	local existing = SoundGenerator.resolveIndex()
	if existing >= 0 then
		sg.enabled = true
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, existing, true)
		SoundGenerator.updateJSFXParams()
		return true
	end

	local fx_index = SoundGenerator.r.TrackFX_AddByName(SoundGenerator.core.state.track, "FX Constellation - Sound Generator", false, -1000)
	if fx_index >= 0 then
		-- Internal JSFX stay closed — never pop a floating window.
		SoundGenerator.r.TrackFX_Show(SoundGenerator.core.state.track, fx_index, 2)
		sg.enabled = true
		sg.jsfx_index = fx_index
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, fx_index, true)
		SoundGenerator.updateJSFXParams()
		return true
	end
	return false
end

function SoundGenerator.removeGenerator()
	local sg = SoundGenerator.core.state.sound_generator
	if not SoundGenerator.core.isTrackValid() then
		sg.enabled = false
		return
	end
	local idx = SoundGenerator.resolveIndex()
	if idx >= 0 then
		SoundGenerator.r.TrackFX_SetEnabled(SoundGenerator.core.state.track, idx, false)
	end
	sg.enabled = false
end

function SoundGenerator.updateJSFXParams()
	local sg = SoundGenerator.core.state.sound_generator
	if not sg.enabled then return end
	if not SoundGenerator.core.isTrackValid() then return end
	local idx = SoundGenerator.resolveIndex()
	if idx < 0 then return end

	local track = SoundGenerator.core.state.track
	for _, spec in ipairs(SoundGenerator.PARAM_SPEC) do
		local value = specGet(sg, spec)
		local norm
		if spec.kind == "bool" then
			norm = value and 1 or 0
		else
			norm = SoundGenerator.normalize(value, spec.min, spec.max)
		end
		SoundGenerator.r.TrackFX_SetParamNormalized(track, idx, spec.p, norm)
	end
end

function SoundGenerator.syncFromJSFX()
	local sg = SoundGenerator.core.state.sound_generator
	if not SoundGenerator.core.isTrackValid() then return end

	local idx = SoundGenerator.resolveIndex()
	if idx < 0 then
		sg.enabled = false
		return
	end

	sg.enabled = SoundGenerator.r.TrackFX_GetEnabled(SoundGenerator.core.state.track, idx)

	local track = SoundGenerator.core.state.track
	for _, spec in ipairs(SoundGenerator.PARAM_SPEC) do
		local norm = SoundGenerator.r.TrackFX_GetParamNormalized(track, idx, spec.p)
		local value
		if spec.kind == "bool" then
			value = norm > 0.5
		elseif spec.kind == "int" then
			value = math.floor(SoundGenerator.denormalize(norm, spec.min, spec.max) + 0.5)
		else
			value = SoundGenerator.denormalize(norm, spec.min, spec.max)
		end
		specSet(sg, spec, value)
	end
end

function SoundGenerator.setManualTrigger(value)
	local sg = SoundGenerator.core.state.sound_generator
	if sg.mode == 1 and sg.enabled then
		if not SoundGenerator.core.isTrackValid() then return end
		local idx = SoundGenerator.resolveIndex()
		if idx < 0 then return end
		SoundGenerator.r.TrackFX_SetParamNormalized(SoundGenerator.core.state.track, idx, MANUAL_TRIGGER_PARAM, value and 1 or 0)
	end
end

return SoundGenerator
