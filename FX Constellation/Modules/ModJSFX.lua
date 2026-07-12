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

-- Randomize a slot's engine settings (and enable it). opts flags gate each
-- field: shape (0-5), rate (log-uniform 0.05..10 Hz, forces Free), sync
-- (random division; combined with rate → per-slot coin flip free/synced),
-- phase (0..1). Pure slider writes — works from any script, FXC running
-- or not.
function ModJSFX.randomizeSlot(r, track, fx_idx, slot, opts)
	if not track or fx_idx < 0 then return end
	local patch = { on = true }
	if opts.shape then patch.shape = math.random(0, 5) end
	local function randRate()
		local lo, hi = math.log(0.05), math.log(10)
		return math.exp(lo + math.random() * (hi - lo))
	end
	if opts.rate and opts.sync then
		if math.random() < 0.5 then
			patch.sync = 0
			patch.rate = randRate()
		else
			patch.sync = math.random(1, 6)
		end
	elseif opts.rate then
		patch.sync = 0
		patch.rate = randRate()
	elseif opts.sync then
		patch.sync = math.random(0, 6)
	end
	if opts.phase then patch.phase = math.random() end
	ModJSFX.setSlot(r, track, fx_idx, slot, patch)
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

-- FX belonging to the CP ecosystem — mapping flows must never target them.
function ModJSFX.isInternalFX(name)
	return name ~= nil
	   and (name:find("FX Constellation", 1, true) ~= nil
	     or name:find("CP_Mod", 1, true) ~= nil)
end

-- Last-touched FX parameter, normalized across API generations.
-- Returns track, fx_idx, param_idx, fx_name — or nil (nothing touched,
-- take FX, or unresolvable).
function ModJSFX.getTouchedParam(r)
	local track, fxidx, parmidx
	if r.GetTouchedOrFocusedFX then
		local ok, trackidx, itemidx, _, fx, parm = r.GetTouchedOrFocusedFX(0)
		if not ok or itemidx >= 0 then return nil end
		track = trackidx == -1 and r.GetMasterTrack(0) or r.GetTrack(0, trackidx)
		fxidx, parmidx = fx, parm
	else
		local ok, tracknumber, fxnumber, paramnumber = r.GetLastTouchedFX()
		if not ok then return nil end
		if (tracknumber >> 16) ~= 0 then return nil end -- item FX
		local low = tracknumber & 0xFFFF
		track = low == 0 and r.GetMasterTrack(0) or r.GetTrack(0, low - 1)
		fxidx, parmidx = fxnumber, paramnumber
	end
	if not track or not fxidx or fxidx < 0 then return nil end
	local _, name = r.TrackFX_GetFXName(track, fxidx, "")
	return track, fxidx, parmidx, name
end

-- ---------------------------------------------------------------------------
-- Click-to-focus channel. Clicking a param NAME in FX Constellation makes
-- it the modulation target without wiggling its value: a cross-script
-- ExtState hint (plus a best-effort native touch). getFocusParam merges
-- the hint with REAPER's real last-touched param — most recent event wins.
-- ---------------------------------------------------------------------------
function ModJSFX.pokeTouch(r, track, fxidx, parmidx)
	if not track then return end
	-- Best effort: rewriting the current value may mark the param as last
	-- touched natively (harmless either way — under PM the own storage is
	-- ignored, without PM the value is unchanged).
	local v = r.TrackFX_GetParam(track, fxidx, parmidx)
	r.TrackFX_SetParam(track, fxidx, parmidx, v)
	local _, guid = r.GetSetMediaTrackInfo_String(track, "GUID", "", false)
	r.SetExtState("CP_Mod", "touch",
		guid .. "|" .. fxidx .. "|" .. parmidx .. "|" .. r.time_precise(), false)
end

local _hint_cache = { raw = nil }
local function getTouchHint(r)
	local raw = r.GetExtState("CP_Mod", "touch")
	if raw == "" then return nil end
	if _hint_cache.raw ~= raw then
		local guid, fx, parm, t = raw:match("^(.-)|(%d+)|(%d+)|([%d%.]+)$")
		local track
		if guid then
			for i = 0, r.GetNumTracks() - 1 do
				local tr = r.GetTrack(0, i)
				local _, g = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
				if g == guid then track = tr break end
			end
		end
		_hint_cache.raw = raw
		_hint_cache.track = track
		_hint_cache.fx = tonumber(fx)
		_hint_cache.parm = tonumber(parm)
		_hint_cache.t = tonumber(t)
	end
	if not _hint_cache.track
	   or not r.ValidatePtr(_hint_cache.track, "MediaTrack*") then
		return nil
	end
	return _hint_cache.track, _hint_cache.fx, _hint_cache.parm, _hint_cache.t
end

local _touch_state = { sig = "", t = 0 }
function ModJSFX.getFocusParam(r)
	local tr, fx, parm, name = ModJSFX.getTouchedParam(r)
	local now = r.time_precise()
	local sig = tr and (tostring(tr) .. ":" .. fx .. ":" .. parm) or ""
	if sig ~= _touch_state.sig then
		_touch_state.sig = sig
		_touch_state.t = now
	end
	local htr, hfx, hparm, ht = getTouchHint(r)
	if htr and ht and ht >= _touch_state.t then
		local _, hname = r.TrackFX_GetFXName(htr, hfx, "")
		return htr, hfx, hparm, hname
	end
	return tr, fx, parm, name
end

-- Tiny plink plumbing (duplicated from LinkEngine on purpose: this module
-- stays dependency-free so the standalone panel can link params).
local function setPlink(r, track, fx, parm, key, value)
	r.TrackFX_SetNamedConfigParm(track, fx,
		"param." .. parm .. ".plink." .. key, tostring(value))
end

local function setModParm(r, track, fx, parm, key, value)
	r.TrackFX_SetNamedConfigParm(track, fx,
		"param." .. parm .. ".mod." .. key, tostring(value))
end

-- Cross-process edit hint: a raw write on a link (standalone panel knobs,
-- Map) tells any FX Constellation instance managing that param to pull the
-- link's state back into its own display (base/range/invert) live, instead
-- of waiting for the next chain rescan.
local function emitEditHint(r, track, fxidx, parmidx)
	local _, guid = r.GetSetMediaTrackInfo_String(track, "GUID", "", false)
	r.SetExtState("CP_Mod", "edit",
		guid .. "|" .. fxidx .. "|" .. parmidx .. "|" .. r.time_precise(), false)
end

-- Link ANY track FX parameter to a global MIDI slot: ensures the MOD track,
-- the MIDI bank, the MIDI send toward the target's track, then writes the
-- 14-bit CC link. baseline = the param's current value, depth = plink scale
-- (0.5 → the LFO sweeps ±25% of the param range around the baseline).
function ModJSFX.linkParamToGlobalSlot(r, target_track, fxidx, parmidx, slot, depth)
	if not target_track or fxidx < 0 or not parmidx then return false end
	local mod_track = ModJSFX.ensureModTrack(r)
	if not mod_track then return false end
	if ModJSFX.ensureBank(r, mod_track, "midi") < 0 then return false end
	ModJSFX.ensureMIDISend(r, mod_track, target_track)
	local cc = ModJSFX.CC_MSB_BASE + slot - 1
	local base = r.TrackFX_GetParamNormalized(target_track, fxidx, parmidx)
	setPlink(r, target_track, fxidx, parmidx, "effect", -100)
	setPlink(r, target_track, fxidx, parmidx, "midi_bus", 0)
	setPlink(r, target_track, fxidx, parmidx, "midi_chan", 1)
	setPlink(r, target_track, fxidx, parmidx, "midi_msg", 176)
	setPlink(r, target_track, fxidx, parmidx, "midi_msg2", 128 + cc)
	setPlink(r, target_track, fxidx, parmidx, "offset", -0.5)
	setPlink(r, target_track, fxidx, parmidx, "scale", depth or 0.5)
	setModParm(r, target_track, fxidx, parmidx, "baseline", base)
	setModParm(r, target_track, fxidx, parmidx, "active", 1)
	setPlink(r, target_track, fxidx, parmidx, "active", 1)
	-- Let a running FX Constellation adopt the new link immediately
	-- (badge, selection, base/range) instead of at the next rescan.
	emitEditHint(r, target_track, fxidx, parmidx)
	return true
end

-- Inspect the CP link on an arbitrary param (target inspector). Returns
-- nil when the param has no active CP link, else:
--   { kind = "pad"|"lfo"|"global", slot = 1..8|nil,
--     scale, baseline, pname, fxname }
function ModJSFX.getParamLink(r, track, fxidx, parmidx)
	local function plink(key)
		local ok, v = r.TrackFX_GetNamedConfigParm(track, fxidx,
			"param." .. parmidx .. ".plink." .. key)
		return ok and v or nil
	end
	if plink("active") ~= "1" then return nil end
	local eff = tonumber(plink("effect") or "")
	if not eff then return nil end

	local kind, slot
	if eff == -100 then
		local msg2 = tonumber(plink("midi_msg2") or "")
		if not msg2 then return nil end
		local cc = msg2 >= 128 and msg2 - 128 or msg2
		slot = cc - ModJSFX.CC_MSB_BASE + 1
		if slot < 1 or slot > ModJSFX.SLOTS then return nil end
		kind = "global"
	elseif eff >= 0 then
		local _, src_name = r.TrackFX_GetFXName(track, eff, "")
		if src_name:find("CP_Mod", 1, true) then
			kind = "lfo"
			local sp = tonumber(plink("param") or "")
			if sp then slot = sp - ModJSFX.OUT_BASE + 1 end
		elseif src_name:find("FX Constellation Bridge") then
			kind = "pad"
		else
			return nil
		end
	else
		return nil
	end

	local ok_b, bstr = r.TrackFX_GetNamedConfigParm(track, fxidx,
		"param." .. parmidx .. ".mod.baseline")
	local _, pname = r.TrackFX_GetParamName(track, fxidx, parmidx, "")
	local _, fxname = r.TrackFX_GetFXName(track, fxidx, "")
	local scale = tonumber(plink("scale") or "") or 0
	local baseline = ok_b and tonumber(bstr) or 0.5

	-- Live modulated value, recomputed from the readable source slider
	-- (the API only reports the base under parameter modulation).
	local live
	local src_val
	if kind == "global" then
		local mod = ModJSFX.findModTrack(r)
		local bank = mod and ModJSFX.findBank(r, mod, "midi") or -1
		if mod and bank >= 0 then
			src_val = r.TrackFX_GetParam(mod, bank, ModJSFX.OUT_BASE + slot - 1)
		end
	elseif kind == "lfo" then
		src_val = r.TrackFX_GetParam(track, eff, ModJSFX.OUT_BASE + slot - 1)
	else -- pad: the link points at a bridge output slider directly
		local sp = tonumber(plink("param") or "")
		if sp then src_val = r.TrackFX_GetParam(track, eff, sp) end
	end
	if src_val then
		live = math.max(0, math.min(1, baseline + (src_val - 0.5) * scale))
	end

	return {
		kind = kind,
		slot = slot,
		scale = scale,
		baseline = baseline,
		live = live,
		pname = pname,
		fxname = fxname,
	}
end

function ModJSFX.setParamLinkBase(r, track, fxidx, parmidx, value)
	setModParm(r, track, fxidx, parmidx, "baseline", value)
	emitEditHint(r, track, fxidx, parmidx)
end

function ModJSFX.setParamLinkDepth(r, track, fxidx, parmidx, scale)
	setPlink(r, track, fxidx, parmidx, "scale", scale)
	emitEditHint(r, track, fxidx, parmidx)
end

-- Remove a CP link and FREEZE the param at its base: the baseline was the
-- audible center, so after unlinking the param must keep that value (its
-- own storage may hold something stale from before the link). plink.effect
-- is reset too — leaving it dangling kept the link half-alive. The PM slot
-- is released only when the user has no LFO/ACS of their own riding on it.
function ModJSFX.releaseParamLink(r, track, fxidx, parmidx)
	local ok_b, bstr = r.TrackFX_GetNamedConfigParm(track, fxidx,
		"param." .. parmidx .. ".mod.baseline")
	setPlink(r, track, fxidx, parmidx, "active", 0)
	setPlink(r, track, fxidx, parmidx, "effect", -1)
	local _, lfo = r.TrackFX_GetNamedConfigParm(track, fxidx,
		"param." .. parmidx .. ".lfo.active")
	local _, acs = r.TrackFX_GetNamedConfigParm(track, fxidx,
		"param." .. parmidx .. ".acs.active")
	if lfo ~= "1" and acs ~= "1" then
		setModParm(r, track, fxidx, parmidx, "active", 0)
	end
	local base = ok_b and tonumber(bstr) or nil
	if base then
		r.TrackFX_SetParamNormalized(track, fxidx, parmidx, base)
	end
	-- Cross-process hint: an FXC instance managing this param must clear
	-- its mod_source entry, or its sync sweep recreates the link on the
	-- next frame. Harmless for FXC's own releases (it clears entries
	-- itself before/after calling this).
	local _, guid = r.GetSetMediaTrackInfo_String(track, "GUID", "", false)
	r.SetExtState("CP_Mod", "unlink",
		guid .. "|" .. fxidx .. "|" .. parmidx .. "|" .. r.time_precise(), false)
end

-- Enumerate every param linked to a bank slot (the per-slot target
-- registry). Bounded scan:
--   kind "lfo"    → the given track only (track bank targets live there)
--   kind "global" → every track receiving a send from the CP MOD track
-- Cost: 1 GetNamedConfigParm per unlinked param (the active check short-
-- circuits), a handful more per linked one. Event-driven only.
function ModJSFX.scanSlotTargets(r, kind, track, slot)
	local targets = {}
	local function scanTrack(tr)
		for fx = 0, r.TrackFX_GetCount(tr) - 1 do
			local _, fxname = r.TrackFX_GetFXName(tr, fx, "")
			if not ModJSFX.isInternalFX(fxname) then
				for parm = 0, r.TrackFX_GetNumParams(tr, fx) - 1 do
					local info = ModJSFX.getParamLink(r, tr, fx, parm)
					if info and info.kind == kind and info.slot == slot then
						targets[#targets + 1] = {
							tr = tr, fx = fx, parm = parm,
							pname = info.pname, fxname = fxname,
							scale = info.scale, baseline = info.baseline,
						}
					end
				end
			end
		end
	end
	if kind == "lfo" then
		if track then scanTrack(track) end
	else
		local mod = ModJSFX.findModTrack(r)
		if mod then
			for i = 0, r.GetTrackNumSends(mod, 0) - 1 do
				local dest = r.GetTrackSendInfo_Value(mod, 0, i, "P_DESTTRACK")
				if dest then scanTrack(dest) end
			end
		end
	end
	return targets
end

-- Full modulation matrix: EVERY param carrying a CP link (pad, track LFO,
-- global), across the given track and every track receiving a CP MOD send.
-- Sorted by source (kind + slot) then param name.
function ModJSFX.scanAllTargets(r, track)
	local targets = {}
	local seen = {}
	local function scanTrack(tr)
		if not tr or seen[tostring(tr)] then return end
		seen[tostring(tr)] = true
		local _, tname = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
		for fx = 0, r.TrackFX_GetCount(tr) - 1 do
			local _, fxname = r.TrackFX_GetFXName(tr, fx, "")
			if not ModJSFX.isInternalFX(fxname) then
				for parm = 0, r.TrackFX_GetNumParams(tr, fx) - 1 do
					local info = ModJSFX.getParamLink(r, tr, fx, parm)
					if info then
						targets[#targets + 1] = {
							tr = tr, fx = fx, parm = parm,
							kind = info.kind, slot = info.slot,
							pname = info.pname, fxname = fxname,
							track_name = tname,
							scale = info.scale, baseline = info.baseline,
						}
					end
				end
			end
		end
	end
	scanTrack(track)
	local mod = ModJSFX.findModTrack(r)
	if mod then
		for i = 0, r.GetTrackNumSends(mod, 0) - 1 do
			scanTrack(r.GetTrackSendInfo_Value(mod, 0, i, "P_DESTTRACK"))
		end
	end
	table.sort(targets, function(a, b)
		local ka = (a.kind or "") .. tostring(a.slot or 0)
		local kb = (b.kind or "") .. tostring(b.slot or 0)
		if ka ~= kb then return ka < kb end
		return (a.pname or "") < (b.pname or "")
	end)
	return targets
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
