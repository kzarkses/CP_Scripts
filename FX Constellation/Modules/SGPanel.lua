-- ============================================================================
-- CP_Scripts — SGPanel
--
-- Shared CP_Toolkit UI for the FX Constellation Sound Generator (3-osc
-- Vital-style bank + master / rhythmic gate / ADSR / trigger). Used embedded
-- (FX Constellation's SOUND GENERATOR section, tabbed oscillators) and
-- standalone (CP_SoundGen.lua popup, the three oscillators side by side).
-- The caller provides a ctx:
--   ctx.sg          state.sound_generator table (mutated in place)
--   ctx.apply()     push the table to the JSFX (updateJSFXParams)
--   ctx.trigger(on) manual trigger gate (Triggered mode)
--   ctx.toggle()    enable/disable the generator (create/remove instance)
--   ctx.wide        true → oscillators in columns; false/nil → tabs
--
-- Frequency entry is Hz (log slider) or musical note (name + octave,
-- A4 = 440 Hz) — toggled with sg.freq_as_note (UI-only field, the JSFX
-- always stores Hz).
-- ============================================================================

local SGPanel = {}

SGPanel.WAVEFORMS = { "Sine", "Triangle", "Square", "Saw", "Noise", "Click" }
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

function SGPanel.init(toolkit)
	SGPanel.tk = toolkit
end

-- Same defaults as FX Constellation's widget helpers: fill width, uniform
-- button-height rows.
local function opts(theme, o)
	o = o or {}
	if o.width == nil then o.width = -1 end
	if o.height == nil then o.height = theme.button_height end
	return o
end

-- Equal-temperament helpers (A4 = 440 Hz = MIDI 69). Result clamped to
-- the generator's slider range (20..20000 Hz).
local function noteToFreq(midi)
	return math.max(20, math.min(20000, 440 * 2 ^ ((midi - 69) / 12)))
end

-- Nearest tempered note of a frequency + deviation in cents.
local function freqToNote(freq)
	local midi = 69 + 12 * math.log((freq or 440) / 440) / math.log(2)
	local n = math.floor(midi + 0.5)
	n = math.max(0, math.min(127, n))
	return n, (midi - n) * 100
end

-- One oscillator's controls. Widget ids are suffixed with the osc index so
-- per-widget state (inline edits, drag anchors) never leaks between
-- oscillators or tabs.
local function drawOsc(theme, ctx, idx)
	local UItk = SGPanel.tk
	local sg = ctx.sg
	local osc = sg.osc[idx]
	if not osc then return end
	local sfx = tostring(idx)

	local tc, tv = UItk.ToggleButton("sgp_on" .. sfx,
		osc.on and "● ON" or "○ OFF", osc.on, opts(theme))
	if tc then osc.on = tv; ctx.apply() end

	local cc, ci = UItk.Combo("sgp_wf" .. sfx, "Wave", osc.wave + 1,
		SGPanel.WAVEFORMS, opts(theme))
	if cc then osc.wave = ci - 1; ctx.apply() end

	if osc.wave < 4 then
		if sg.freq_as_note then
			-- Musical entry: note + octave, snapped to equal temperament.
			local midi, cents = freqToNote(osc.freq)
			UItk.BeginColumns("sgp_note_row" .. sfx, { 0.55, 0.45 },
				{ gap = theme.item_spacing })
			local nc, ni = UItk.Combo("sgp_note" .. sfx, "Note",
				(midi % 12) + 1, NOTE_NAMES, opts(theme))
			if nc then
				osc.freq = noteToFreq(midi - (midi % 12) + (ni - 1))
				ctx.apply()
			end
			UItk.NextColumn()
			local oc, ov = UItk.SliderInt("sgp_oct" .. sfx, "Oct",
				math.floor(midi / 12) - 1, 0, 9, opts(theme))
			if oc then
				osc.freq = noteToFreq((midi % 12) + (ov + 1) * 12)
				ctx.apply()
			end
			UItk.EndColumns()
			-- The freq may have been set in Hz: show the deviation from
			-- the displayed tempered note.
			if math.abs(cents) >= 1 then
				UItk.SetFontCaption()
				UItk.Text(string.format("%.1f Hz (%+.0f ct)", osc.freq, cents))
				UItk.SetFontBody()
			end
		else
			local fmin, fmax = math.log(20), math.log(20000)
			local norm = (math.log(osc.freq) - fmin) / (fmax - fmin)
			local fc, fv = UItk.SliderDouble("sgp_freq" .. sfx, "Freq",
				norm, 0, 1,
				opts(theme, { format = string.format("%.1f Hz", osc.freq) }))
			if fc then
				osc.freq = math.exp(fmin + fv * (fmax - fmin))
				ctx.apply()
			end
		end
	elseif osc.wave == 4 then
		local c2, cv = UItk.SliderDouble("sgp_color" .. sfx, "Color",
			osc.color, 0, 1,
			opts(theme, { format = string.format("%.2f", osc.color) }))
		if c2 then osc.color = cv; ctx.apply() end
	end

	local wc, wv = UItk.SliderDouble("sgp_w" .. sfx, "Width", osc.width, 0, 100,
		opts(theme, { format = string.format("%.1f c", osc.width) }))
	if wc then osc.width = wv; ctx.apply() end

	local vc, vv = UItk.SliderDouble("sgp_vol" .. sfx, "Vol", osc.vol, 0, 1,
		opts(theme, { format = string.format("%.2f", osc.vol) }))
	if vc then osc.vol = vv; ctx.apply() end
end

function SGPanel.draw(theme, ctx)
	local UItk = SGPanel.tk
	local sg = ctx.sg

	local toggled = UItk.ToggleButton("sgp_toggle",
		sg.enabled and "● ON" or "○ OFF", sg.enabled, opts(theme))
	if toggled then ctx.toggle() end
	if not sg.enabled then return end

	UItk.BeginColumns("sgp_mode_row", { 0.5, 0.5 }, { gap = theme.item_spacing })
	if UItk.Button("sgp_mode", sg.mode == 0 and "Continuous" or "Triggered",
	               opts(theme)) then
		sg.mode = sg.mode == 0 and 1 or 0
		ctx.apply()
	end
	UItk.NextColumn()
	local nmc, nmv = UItk.Checkbox("sgp_notemode", "Note",
		sg.freq_as_note or false, { size = theme.button_height })
	if nmc then sg.freq_as_note = nmv end
	UItk.EndColumns()

	-- ---- Oscillator bank ---------------------------------------------------
	if ctx.wide then
		UItk.BeginColumns("sgp_osc_cols", { 1 / 3, 1 / 3, 1 / 3 },
			{ gap = theme.item_spacing * 2 })
		for i = 1, 3 do
			if i > 1 then UItk.NextColumn() end
			UItk.SetFontCaption()
			UItk.Text("OSC " .. i)
			UItk.SetFontBody()
			drawOsc(theme, ctx, i)
		end
		UItk.EndColumns()
	else
		local tab_changed, tab_idx = UItk.TabBar("sgp_osc_tabs",
			{ "OSC 1", "OSC 2", "OSC 3" }, sg.ui_osc_tab or 1)
		if tab_changed then sg.ui_osc_tab = tab_idx end
		drawOsc(theme, ctx, sg.ui_osc_tab or 1)
	end

	UItk.Separator()

	-- ---- Master ------------------------------------------------------------
	local ac, av = UItk.SliderDouble("sgp_amp", "Amp", sg.amplitude, 0, 1,
		opts(theme, { format = string.format("%.2f", sg.amplitude) }))
	if ac then sg.amplitude = av; ctx.apply() end

	if sg.mode == 0 then
		local rc, rv = UItk.Checkbox("sgp_rh", "Rhythmic", sg.rhythmic,
			{ size = theme.button_height })
		if rc then sg.rhythmic = rv; ctx.apply() end
		if sg.rhythmic then
			local tc2, tv2 = UItk.SliderDouble("sgp_tr", "Rate",
				sg.tick_rate, 0.1, 20,
				opts(theme, { format = string.format("%.2f Hz", sg.tick_rate) }))
			if tc2 then sg.tick_rate = tv2; ctx.apply() end
			local dc, dv = UItk.SliderDouble("sgp_du", "Duty",
				sg.duty_cycle, 0.01, 0.99,
				opts(theme, { format = string.format("%.2f", sg.duty_cycle) }))
			if dc then sg.duty_cycle = dv; ctx.apply() end
			local cc2, cv2 = UItk.SliderDouble("sgp_cur", "Curve",
				sg.rhythmic_curve, 0, 1,
				opts(theme, { format = string.format("%.2f", sg.rhythmic_curve) }))
			if cc2 then sg.rhythmic_curve = cv2; ctx.apply() end
		end
	else
		local ec, ev = UItk.Checkbox("sgp_adsr", "ADSR", sg.use_adsr,
			{ size = theme.button_height })
		if ec then sg.use_adsr = ev; ctx.apply() end
		if sg.use_adsr then
			local c, v = UItk.SliderDouble("sgp_a", "A", sg.attack, 0.001, 2,
				opts(theme, { format = string.format("%.3f s", sg.attack) }))
			if c then sg.attack = v; ctx.apply() end
			c, v = UItk.SliderDouble("sgp_d", "D", sg.decay, 0.001, 2,
				opts(theme, { format = string.format("%.3f s", sg.decay) }))
			if c then sg.decay = v; ctx.apply() end
			c, v = UItk.SliderDouble("sgp_s", "S", sg.sustain, 0, 1,
				opts(theme, { format = string.format("%.2f", sg.sustain) }))
			if c then sg.sustain = v; ctx.apply() end
			c, v = UItk.SliderDouble("sgp_r", "R", sg.release, 0.001, 5,
				opts(theme, { format = string.format("%.3f s", sg.release) }))
			if c then sg.release = v; ctx.apply() end
		end
		local mc, mv = UItk.Checkbox("sgp_midi", "MIDI", sg.midi_mode,
			{ size = theme.button_height })
		if mc then sg.midi_mode = mv; ctx.apply() end

		-- Hold-to-play: press-and-hold gate on the trigger param.
		UItk.Button("sgp_play",
			SGPanel._play_held and "▶ PLAYING" or "HOLD TO PLAY", opts(theme))
		local hovered = UItk.IsItemHovered()
		local down = UItk.Core.MouseDown(1)
		if hovered and down and not SGPanel._play_held then
			SGPanel._play_held = true
			ctx.trigger(true)
		elseif SGPanel._play_held and not down then
			SGPanel._play_held = false
			ctx.trigger(false)
		end
		if SGPanel._play_held then
			-- Keep the loop awake while held so the release edge is caught
			-- even if nothing else animates.
			UItk.RequestRedraw()
		end
	end
end

return SGPanel
