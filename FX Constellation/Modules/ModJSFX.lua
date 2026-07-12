-- ============================================================================
-- CP_Scripts — ModJSFX
--
-- Pure, dependency-free helpers for the CP_Mod modulator ecosystem. Owns:
--   • the JSFX source builders (LFO bank, MIDI bank) and their slider layout
--   • find/ensure of bank instances on a track (files written on demand,
--     instances added silently — no floating window)
--   • raw slot access (get/set) usable from ANY script: FX Constellation's
--     LinkEngine delegates here, and the standalone CP_ModLFO panel uses it
--     directly with nothing but `reaper` and a track handle
--   • the hidden "CP MOD" utility track hosting the global (cross-track)
--     MIDI bank
--
-- Slider layout, shared by both banks (0-based param indices):
--   0..39   slot i (1..8) settings: base=(i-1)*5 → on, shape, rate, sync, phase
--   40..47  -Out i        (block-rate output value, link source / display)
--   48..55  -Phase i      (raw cycle phase 0..1, display only — the preview
--                          dot needs the phase, the out value alone cannot
--                          be inverted back to a curve position)
-- ============================================================================

local ModJSFX = {}

ModJSFX.LFO_NAME = "CP_Mod LFO"
ModJSFX.MIDI_NAME = "CP_Mod MIDI"
ModJSFX.MOD_TRACK_NAME = "CP MOD"
ModJSFX.SLOTS = 8
ModJSFX.OUT_BASE = 40
ModJSFX.PHASE_BASE = 48
ModJSFX.PARAM_COUNT = 56
-- 14-bit CC pairs emitted by the MIDI bank: slot i → CC (MSB_BASE+i-1)
-- with LSB at +32, MIDI channel 1.
ModJSFX.CC_MSB_BASE = 16

local function slotBase(slot) return (slot - 1) * 5 end

-- ---------------------------------------------------------------------------
-- JSFX source
-- ---------------------------------------------------------------------------
local function buildSliders(p)
	for i = 1, ModJSFX.SLOTS do
		local b = slotBase(i)
		p[#p + 1] = ("slider%d:lfo%d_on=%d<0,1,1{Off,On}>LFO %d On\n")
			:format(b + 1, i, i == 1 and 1 or 0, i)
		p[#p + 1] = ("slider%d:lfo%d_shape=0<0,5,1{Sine,Triangle,Saw Up,Saw Down,Square,Random}>LFO %d Shape\n")
			:format(b + 2, i, i)
		p[#p + 1] = ("slider%d:lfo%d_rate=1<0.01,20,0.01>LFO %d Rate (Hz)\n")
			:format(b + 3, i, i)
		p[#p + 1] = ("slider%d:lfo%d_sync=0<0,6,1{Free,1/16,1/8,1/4,1/2,1 bar,2 bars}>LFO %d Sync\n")
			:format(b + 4, i, i)
		p[#p + 1] = ("slider%d:lfo%d_phase=0<0,1,0.01>LFO %d Phase\n")
			:format(b + 5, i, i)
	end
	for i = 1, ModJSFX.SLOTS do
		p[#p + 1] = ("slider%d:lfo%d_out=0.5<0,1,0.0001>-LFO %d Out (mod source)\n")
			:format(ModJSFX.OUT_BASE + i, i, i)
	end
	for i = 1, ModJSFX.SLOTS do
		p[#p + 1] = ("slider%d:lfo%d_pho=0<0,1,0.0001>-LFO %d Phase (display)\n")
			:format(ModJSFX.PHASE_BASE + i, i, i)
	end
end

-- Per-slot engine. Sync divisions in LFO cycles per quarter note (4/4):
-- 1/16=4, 1/8=2, 1/4=1, 1/2=0.5, 1 bar=0.25, 2 bars=0.125. Synced slots
-- follow beat_position (freeze when stopped); free slots accumulate
-- wall-clock phase per block. phI stays the RAW phase (without the phase
-- offset) and is exported for the UI preview dot.
local SLOT_ENGINE = [[
lfoI_on > 0.5 ? (
  lfoI_sync > 0.5 ? (
    cpb = lfoI_sync < 1.5 ? 4 : lfoI_sync < 2.5 ? 2 : lfoI_sync < 3.5 ? 1 : lfoI_sync < 4.5 ? 0.5 : lfoI_sync < 5.5 ? 0.25 : 0.125;
    phI = beat_position * cpb;
  ) : (
    phI += samplesblock / srate * lfoI_rate;
  );
  pp = phI + lfoI_phase;
  pf = pp - floor(pp);
  lfoI_shape > 4.5 ? (
    cc = floor(pp);
    cc != cycI ? ( heldI = rand(); cycI = cc; );
    vv = heldI;
  ) : lfoI_shape > 3.5 ? ( vv = pf < 0.5 ? 1 : 0; )
  : lfoI_shape > 2.5 ? ( vv = 1 - pf; )
  : lfoI_shape > 1.5 ? ( vv = pf; )
  : lfoI_shape > 0.5 ? ( vv = pf < 0.5 ? 2*pf : 2 - 2*pf; )
  : ( vv = 0.5 + 0.5 * sin(pf * 2 * $pi); );
  lfoI_out = vv;
  lfoI_pho = phI - floor(phI);
) : ( lfoI_out = 0.5; lfoI_pho = 0; );
]]

-- The MIDI bank additionally emits each slot as a 14-bit CC pair when the
-- quantized value changes (MSB CC_MSB_BASE+i-1, LSB at +32, channel 1).
local SLOT_MIDI = [[
lfoI_on > 0.5 ? (
  vqI = floor(lfoI_out * 16383 + 0.5);
  vqI != lastI ? (
    lastI = vqI;
    msb = floor(vqI / 128);
    midisend(0, 0xB0, CCMSB, msb);
    midisend(0, 0xB0, CCLSB, vqI - msb * 128);
  );
);
]]

function ModJSFX.buildSource(kind)
	local p = {}
	-- desc must be EXACTLY the AddByName lookup string.
	p[#p + 1] = "desc: " .. (kind == "midi" and ModJSFX.MIDI_NAME or ModJSFX.LFO_NAME) .. "\n"
	buildSliders(p)
	p[#p + 1] = "\n@init\n"
	for i = 1, ModJSFX.SLOTS do
		p[#p + 1] = ("ph%d = 0; held%d = 0.5; cyc%d = -1;\n"):format(i, i, i)
		if kind == "midi" then
			p[#p + 1] = ("last%d = -1;\n"):format(i)
		end
	end
	p[#p + 1] = "\n@block\n"
	for i = 1, ModJSFX.SLOTS do
		p[#p + 1] = (SLOT_ENGINE:gsub("I", tostring(i)))
	end
	if kind == "midi" then
		for i = 1, ModJSFX.SLOTS do
			p[#p + 1] = (SLOT_MIDI
				:gsub("CCMSB", tostring(ModJSFX.CC_MSB_BASE + i - 1))
				:gsub("CCLSB", tostring(ModJSFX.CC_MSB_BASE + 32 + i - 1))
				:gsub("I", tostring(i)))
		end
	end
	return table.concat(p)
end

-- ---------------------------------------------------------------------------
-- Bank instances
-- ---------------------------------------------------------------------------
function ModJSFX.findBank(r, track, kind)
	if not track then return -1 end
	local name = kind == "midi" and ModJSFX.MIDI_NAME or ModJSFX.LFO_NAME
	local fx_count = r.TrackFX_GetCount(track)
	for fx = 0, fx_count - 1 do
		local _, fx_name = r.TrackFX_GetFXName(track, fx, "")
		if fx_name:find(name, 1, true) then return fx end
	end
	return -1
end

-- (Re)write the bank's JSFX source on disk. Called at script startup and
-- before adding an instance, so layout updates (e.g. the phase-display
-- sliders) propagate — EXISTING instances pick the new source up when the
-- project is reloaded (REAPER compiles JSFX at instantiation time).
function ModJSFX.writeBankFile(r, kind)
	local name = kind == "midi" and ModJSFX.MIDI_NAME or ModJSFX.LFO_NAME
	local path = r.GetResourcePath() .. "/Effects/" .. name .. ".jsfx"
	local file = io.open(path, "w")
	if not file then return false end
	file:write(ModJSFX.buildSource(kind))
	file:close()
	return true
end

function ModJSFX.ensureBank(r, track, kind)
	if not track then return -1 end
	local existing = ModJSFX.findBank(r, track, kind)
	if existing >= 0 then return existing end
	if not ModJSFX.writeBankFile(r, kind) then return -1 end
	local name = kind == "midi" and ModJSFX.MIDI_NAME or ModJSFX.LFO_NAME
	local idx = r.TrackFX_AddByName(track, name, false, -1)
	if idx >= 0 then
		-- Internal JSFX stay closed — never pop a floating window.
		r.TrackFX_Show(track, idx, 2)
	end
	return idx
end

-- ---------------------------------------------------------------------------
-- Slot access (raw JSFX slider units)
-- ---------------------------------------------------------------------------
function ModJSFX.getSlot(r, track, fx_idx, slot)
	if not track or fx_idx < 0 then return nil end
	local b = slotBase(slot)
	local function g(off) return r.TrackFX_GetParam(track, fx_idx, b + off) end
	local has_phase = r.TrackFX_GetNumParams(track, fx_idx) >= ModJSFX.PARAM_COUNT
	return {
		on = g(0) > 0.5,
		shape = math.floor(g(1) + 0.5),
		rate = g(2),
		sync = math.floor(g(3) + 0.5),
		phase = g(4),
		out = r.TrackFX_GetParam(track, fx_idx, ModJSFX.OUT_BASE + slot - 1),
		-- nil on pre-phase-display instances (recompiled on project reload)
		ph = has_phase
			and r.TrackFX_GetParam(track, fx_idx, ModJSFX.PHASE_BASE + slot - 1)
			or nil,
	}
end

function ModJSFX.setSlot(r, track, fx_idx, slot, patch)
	if not track or fx_idx < 0 then return end
	local b = slotBase(slot)
	local function set(off, v) r.TrackFX_SetParam(track, fx_idx, b + off, v) end
	if patch.on ~= nil then set(0, patch.on and 1 or 0) end
	if patch.shape then set(1, patch.shape) end
	if patch.rate then set(2, patch.rate) end
	if patch.sync then set(3, patch.sync) end
	if patch.phase then set(4, patch.phase) end
end

-- ---------------------------------------------------------------------------
-- Global MOD track (hidden utility track hosting the cross-track MIDI bank)
-- ---------------------------------------------------------------------------
function ModJSFX.findModTrack(r)
	for i = 0, r.GetNumTracks() - 1 do
		local track = r.GetTrack(0, i)
		local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
		if name == ModJSFX.MOD_TRACK_NAME then return track end
	end
	return nil
end

function ModJSFX.ensureModTrack(r)
	local track = ModJSFX.findModTrack(r)
	if track then return track end
	local idx = r.GetNumTracks()
	r.InsertTrackAtIndex(idx, false)
	track = r.GetTrack(0, idx)
	if not track then return nil end
	r.GetSetMediaTrackInfo_String(track, "P_NAME", ModJSFX.MOD_TRACK_NAME, true)
	-- Invisible utility track: hidden from TCP/mixer, no master send.
	r.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
	r.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
	r.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
	return track
end

-- MIDI-only send MOD → target (created once, reused afterwards).
function ModJSFX.ensureMIDISend(r, mod_track, target_track)
	if not mod_track or not target_track or mod_track == target_track then return end
	for i = 0, r.GetTrackNumSends(mod_track, 0) - 1 do
		local dest = r.GetTrackSendInfo_Value(mod_track, 0, i, "P_DESTTRACK")
		if dest == target_track then return end
	end
	local send = r.CreateTrackSend(mod_track, target_track)
	if send >= 0 then
		r.SetTrackSendInfo_Value(mod_track, 0, send, "I_SRCCHAN", -1)  -- no audio
		r.SetTrackSendInfo_Value(mod_track, 0, send, "I_MIDIFLAGS", 0) -- MIDI all→all
	end
end

return ModJSFX
