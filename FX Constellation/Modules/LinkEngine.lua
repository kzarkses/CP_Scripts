-- ============================================================================
-- CP_FXConstellation — LinkEngine
--
-- "Linked" mode: instead of the Lua defer loop applying the XY gesture to
-- every selected parameter at ~30 Hz (TrackFX_SetParam per param per frame),
-- the gesture is COMPILED into REAPER's native parameter links:
--
--   target param  ──plink──►  bridge x_out / y_out / xy_mix
--     mod.baseline = the param's base value
--     plink.scale  = param range × gesture range   (negative = inverted)
--     plink.offset = -0.5                           (pad center = base)
--
-- The native modulation engine then propagates every bridge move (pad drag,
-- envelope, LFO, third-party modulator, MIDI) to all linked params at audio
-- block rate, in the audio thread, with the script closed or not. The
-- bridge's block-rate slew smooths 30 Hz script writes into glides.
--
-- The Lua side only EDITS links, event-driven (selection / range / invert /
-- assign / base changes mark state.links_dirty; syncLinks runs on the next
-- frame). syncLinks is idempotent and only touches links it owns — a link
-- whose source is not the bridge is user property and is left alone.
--
-- Not covered by links (script path keeps handling them): granular pad
-- mode (non-linear grain interpolation) and the asymmetric range clamping
-- (plink is linear; REAPER clamps the modulated value to the param's own
-- 0..1 instead of gesture_min/max).
-- ============================================================================

local LinkEngine = {}

-- 0-based param indices of the link sources on the bridge JSFX
local SRC_X, SRC_Y, SRC_MIX = 3, 4, 5
local SLEW_PARAM = 2

-- Mod-source slot encoding in state.param_mod_source:
--   0 / absent  = pad XY
--   1..8        = CP_Mod LFO slot on the current track
--   101..108    = global CP_Mod MIDI slot (hidden "CP MOD" track, received
--                 as 14-bit CC through a MIDI send — cross-track modulation)
local GLOBAL_SLOT_BASE = 100
LinkEngine.GLOBAL_SLOT_BASE = GLOBAL_SLOT_BASE

function LinkEngine.init(reaper_api, core, fxmanager, gesture)
	LinkEngine.r = reaper_api
	LinkEngine.core = core
	LinkEngine.fxmanager = fxmanager
	LinkEngine.gesture = gesture
	-- Shared CP_Mod plumbing (JSFX builders, banks, MOD track) — pure
	-- module, also used by the standalone CP_ModLFO panel script.
	LinkEngine.modjsfx = dofile(reaper_api.GetResourcePath()
		.. "/Scripts/CP_Scripts/FX Constellation/Modules/ModJSFX.lua")
	-- Refresh the JSFX sources once per session so layout updates reach
	-- existing instances on the next project (re)load.
	LinkEngine.modjsfx.writeBankFile(reaper_api, "lfo")
	LinkEngine.modjsfx.writeBankFile(reaper_api, "midi")
end

local function setParm(track, fx, param_id, key, value)
	return LinkEngine.r.TrackFX_SetNamedConfigParm(track, fx,
		"param." .. param_id .. ".plink." .. key, tostring(value))
end

local function setMod(track, fx, param_id, key, value)
	return LinkEngine.r.TrackFX_SetNamedConfigParm(track, fx,
		"param." .. param_id .. ".mod." .. key, tostring(value))
end

local function getParm(track, fx, param_id, key)
	local ok, val = LinkEngine.r.TrackFX_GetNamedConfigParm(track, fx,
		"param." .. param_id .. ".plink." .. key)
	return ok and val or nil
end

-- Classify the active link on (fx, param):
--   "bridge" — pad link (always managed by FX Constellation)
--   "cpmod"  — CP_Mod source: track LFO bank, or MIDI link in our CC window.
--              Managed by FX Constellation ONLY for params that carry a
--              mod_source entry; links made by hand or via the Map flow
--              (standalone panel) have no entry and must be left alone.
--   nil      — no active link, or a link we don't own.
local function linkKind(track, fx, param_id)
	local active = getParm(track, fx, param_id, "active")
	if active ~= "1" then return nil end
	local eff = tonumber(getParm(track, fx, param_id, "effect") or "")
	if not eff then return nil end
	if eff == -100 then
		local mj = LinkEngine.modjsfx
		local msg2 = tonumber(getParm(track, fx, param_id, "midi_msg2") or "")
		if not msg2 then return nil end
		local lo, hi = mj.CC_MSB_BASE, mj.CC_MSB_BASE + mj.SLOTS - 1
		if (msg2 >= lo and msg2 <= hi)
		   or (msg2 >= 128 + lo and msg2 <= 128 + hi) then
			return "cpmod"
		end
		return nil
	end
	if eff < 0 then return nil end
	local _, name = LinkEngine.r.TrackFX_GetFXName(track, eff, "")
	if name:find("FX Constellation Bridge") then return "bridge" end
	if name:find("CP_Mod", 1, true) then return "cpmod" end
	return nil
end

local function ownsLink(track, fx, param_id)
	return linkKind(track, fx, param_id) ~= nil
end

-- ---------------------------------------------------------------------------
-- CP_Mod banks (delegated to the shared, dependency-free ModJSFX module)
-- ---------------------------------------------------------------------------
function LinkEngine.findModLFO()
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return -1 end
	-- scanTrackFX keeps the cache fresh; validate then fall back to a sweep.
	if s.modlfo_index and s.modlfo_index >= 0 then
		local _, name = LinkEngine.r.TrackFX_GetFXName(s.track, s.modlfo_index, "")
		if name:find(LinkEngine.modjsfx.LFO_NAME, 1, true) then return s.modlfo_index end
	end
	s.modlfo_index = LinkEngine.modjsfx.findBank(LinkEngine.r, s.track, "lfo")
	return s.modlfo_index
end

function LinkEngine.ensureModLFO()
	local existing = LinkEngine.findModLFO()
	if existing >= 0 then return existing end
	if not LinkEngine.core.isTrackValid() then return -1 end
	local idx = LinkEngine.modjsfx.ensureBank(LinkEngine.r, LinkEngine.core.state.track, "lfo")
	LinkEngine.core.state.modlfo_index = idx
	return idx
end

function LinkEngine.getLFOSlot(slot)
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return nil end
	return LinkEngine.modjsfx.getSlot(LinkEngine.r, s.track, s.modlfo_index or -1, slot)
end

function LinkEngine.setLFOSlot(slot, patch)
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return end
	LinkEngine.modjsfx.setSlot(LinkEngine.r, s.track, s.modlfo_index or -1, slot, patch)
end

-- ---------------------------------------------------------------------------
-- Global (cross-track) MIDI bank on the hidden CP MOD track
-- ---------------------------------------------------------------------------
-- Returns mod_track, bank_fx_index — cached per frame-ish via state, the
-- track pointer is validated before reuse.
function LinkEngine.findGlobalMIDI()
	local s = LinkEngine.core.state
	local track = s._mod_track
	if not (track and LinkEngine.r.ValidatePtr(track, "MediaTrack*")) then
		track = LinkEngine.modjsfx.findModTrack(LinkEngine.r)
		s._mod_track = track
	end
	if not track then return nil, -1 end
	local idx = s._mod_bank_idx or -1
	if idx >= 0 then
		local _, name = LinkEngine.r.TrackFX_GetFXName(track, idx, "")
		if name:find(LinkEngine.modjsfx.MIDI_NAME, 1, true) then return track, idx end
	end
	idx = LinkEngine.modjsfx.findBank(LinkEngine.r, track, "midi")
	s._mod_bank_idx = idx
	return track, idx
end

function LinkEngine.ensureGlobalMIDI()
	local track, idx = LinkEngine.findGlobalMIDI()
	if track and idx >= 0 then return track, idx end
	track = LinkEngine.modjsfx.ensureModTrack(LinkEngine.r)
	if not track then return nil, -1 end
	idx = LinkEngine.modjsfx.ensureBank(LinkEngine.r, track, "midi")
	LinkEngine.core.state._mod_track = track
	LinkEngine.core.state._mod_bank_idx = idx
	return track, idx
end

-- Slot access on the global bank (for the shared panel / live display).
function LinkEngine.getGlobalSlot(slot)
	local track, idx = LinkEngine.findGlobalMIDI()
	if not track or idx < 0 then return nil end
	return LinkEngine.modjsfx.getSlot(LinkEngine.r, track, idx, slot)
end

function LinkEngine.setGlobalSlot(slot, patch)
	local track, idx = LinkEngine.findGlobalMIDI()
	if not track or idx < 0 then return end
	LinkEngine.modjsfx.setSlot(LinkEngine.r, track, idx, slot, patch)
end

-- ---------------------------------------------------------------------------
-- Per-param modulation source (pad XY by default, or a CP_Mod LFO slot)
-- ---------------------------------------------------------------------------
function LinkEngine.getParamModSource(fx_id, param_id)
	local key = LinkEngine.core.getParamKey(fx_id, param_id)
	return (key and LinkEngine.core.state.param_mod_source[key]) or 0
end

function LinkEngine.setParamModSource(fx_id, param_id, slot)
	local key = LinkEngine.core.getParamKey(fx_id, param_id)
	if not key then return end
	LinkEngine.core.state.param_mod_source[key] = (slot and slot > 0) and slot or nil
	LinkEngine.fxmanager.saveTrackSelection()
end

-- ---------------------------------------------------------------------------
-- Native per-param LFO (REAPER parameter modulation LFO — rides ON TOP of
-- the plink/baseline, which is exactly "LFO + pad shifts it proportionally")
-- ---------------------------------------------------------------------------
local function lfoParmName(param_id, key)
	return "param." .. param_id .. ".lfo." .. key
end

function LinkEngine.getParamLFO(fx_id, param_id)
	local s = LinkEngine.core.state
	local fx_data = s.fx_data[fx_id]
	if not fx_data or not LinkEngine.core.isTrackValid() then return nil end
	local target = fx_data.actual_fx_id or fx_id
	local function g(k)
		local _, v = LinkEngine.r.TrackFX_GetNamedConfigParm(s.track, target, lfoParmName(param_id, k))
		return v
	end
	return {
		active = g("active") == "1",
		shape = tonumber(g("shape")) or 0,
		speed = tonumber(g("speed")) or 1,
		strength = tonumber(g("strength")) or 0.25,
		temposync = g("temposync") == "1",
	}
end

-- Patch native-LFO settings. On first enable the modulation envelope is
-- anchored on the param's base value, centered (dir=0) so the LFO swings
-- symmetrically around wherever the base/pad puts the param.
function LinkEngine.setParamLFO(fx_id, param_id, patch)
	local s = LinkEngine.core.state
	local fx_data = s.fx_data[fx_id]
	if not fx_data or not LinkEngine.core.isTrackValid() then return end
	local target = fx_data.actual_fx_id or fx_id
	local function set(k, v)
		LinkEngine.r.TrackFX_SetNamedConfigParm(s.track, target, lfoParmName(param_id, k), tostring(v))
	end
	if patch.active ~= nil then
		if patch.active then
			local param_data = fx_data.params[param_id]
			setMod(s.track, target, param_id, "baseline",
				(param_data and param_data.base_value) or 0.5)
			setMod(s.track, target, param_id, "active", 1)
			set("dir", 0)
			set("active", 1)
		else
			set("active", 0)
			-- Release the PM slot only if nothing else of ours uses it.
			local acs = select(2, LinkEngine.r.TrackFX_GetNamedConfigParm(
				s.track, target, "param." .. param_id .. ".acs.active"))
			if acs ~= "1" and not ownsLink(s.track, target, param_id) then
				setMod(s.track, target, param_id, "active", 0)
			end
		end
	end
	if patch.shape then set("shape", patch.shape) end
	if patch.strength then set("strength", patch.strength) end
	if patch.speed then
		set("temposync", patch.temposync and 1 or 0)
		set("speed", patch.speed)
	end
end

-- Disable a link we own — delegated to ModJSFX.releaseParamLink: link
-- fully cleared (active + effect), param frozen at its baseline, PM slot
-- released only if the user has no LFO/ACS riding on it.
local function releaseLink(track, fx, param_id)
	LinkEngine.modjsfx.releaseParamLink(LinkEngine.r, track, fx, param_id)
end

-- Explicit release of a param's CP link (used by the assignment menu when
-- switching back to a pad source: the sweep intentionally never releases
-- CP_Mod links without a mod_source entry, so the menu does it here).
function LinkEngine.releaseParamLink(fx_id, param_id)
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return end
	local fx_data = s.fx_data[fx_id]
	if not fx_data then return end
	local target = fx_data.actual_fx_id or fx_id
	if linkKind(s.track, target, param_id) == "cpmod" then
		releaseLink(s.track, target, param_id)
	end
end

-- Push the current base value of one param into its link baseline (fast
-- path for value edits; avoids a full sync sweep). Valid whenever the
-- param has ANY CP link — pad (linked mode) or LFO/global (both modes):
-- with parameter modulation active, the baseline IS the audible base, the
-- param's own storage is ignored.
function LinkEngine.setBaseline(fx_id, param_id, base_value)
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return end
	local fx_data = s.fx_data[fx_id]
	if not fx_data then return end
	setMod(s.track, fx_data.actual_fx_id or fx_id, param_id, "baseline", base_value)
end

-- Push FXC's range/invert into the link scale of one param. The sweep no
-- longer rewrites intact links, so FXC-side depth edits (range slider,
-- invert toggle, inspector routing) propagate through this explicit path.
function LinkEngine.pushDepth(fx_id, param_id)
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return end
	local fx_data = s.fx_data[fx_id]
	if not fx_data then return end
	local target = fx_data.actual_fx_id or fx_id
	if not ownsLink(s.track, target, param_id) then return end
	local range = LinkEngine.fxmanager.getParamRange(fx_id, param_id)
	local span = range * (s.gesture_range or 1.0)
	if LinkEngine.fxmanager.getParamInvert(fx_id, param_id) then span = -span end
	setParm(s.track, target, param_id, "scale", span)
end

-- Does this param currently route through a CP link? (baseline is then the
-- write target for base edits, not the raw param)
function LinkEngine.isParamLinked(fx_id, param_id, param_data)
	local s = LinkEngine.core.state
	if not param_data.selected then return false end
	if param_data.key and s.param_mod_source[param_data.key] then return true end
	return s.links_active
end

-- Write the pad slew time (seconds) to the bridge.
function LinkEngine.applySlew()
	local s = LinkEngine.core.state
	if s.jsfx_automation_index < 0 or not LinkEngine.core.isTrackValid() then return end
	local slew = s.link_slew or 0
	LinkEngine.r.TrackFX_SetParamNormalized(s.track, s.jsfx_automation_index,
		SLEW_PARAM, math.max(0, math.min(1, slew / 2)))
end

-- Idempotent sweep: make the set of native links match (linked_mode ×
-- selection × assignments). Event-driven — call when state.links_dirty.
function LinkEngine.syncLinks()
	local s = LinkEngine.core.state
	s.links_dirty = false
	-- Preset/snapshot loads set links_rebuild: every wanted link is then
	-- rewritten from FXC state (base/range) instead of being left intact.
	local rebuild = s.links_rebuild
	s.links_rebuild = false
	if not LinkEngine.core.isTrackValid() then
		s.links_active = false
		s.links_count = 0
		return
	end

	local want_links = s.linked_mode and s.pad_mode == 0

	-- The bridge is required (and auto-created) as soon as linked mode is
	-- on: it is both the link source and the automation surface.
	if want_links and s.jsfx_automation_index < 0 then
		LinkEngine.gesture.createAutomationJSFX()
	end
	local bridge = s.jsfx_automation_index
	if want_links and (bridge < 0
	   or LinkEngine.r.TrackFX_GetNumParams(s.track, bridge) < LinkEngine.gesture.BRIDGE_PARAM_COUNT) then
		-- v1 bridge instance that couldn't be upgraded — stay script-driven.
		want_links = false
	end

	local track = s.track
	local count = 0
	local lfo_count = 0
	local lfo_idx = nil        -- track LFO bank, resolved lazily once
	local global_ok = nil      -- global MIDI bank readiness, resolved once
	for fx_id, fx_data in pairs(s.fx_data) do
		local target = fx_data.actual_fx_id or fx_id
		for param_id, param_data in pairs(fx_data.params) do
			local want = false
			local src_fx, src_param, midi_cc
			if param_data.selected then
				local slot = param_data.key and s.param_mod_source[param_data.key] or 0
				if slot > GLOBAL_SLOT_BASE then
					-- Global MIDI slot: the hidden CP MOD track emits the
					-- slot as a 14-bit CC, routed here through a MIDI send;
					-- the param follows it via a native MIDI link. Standing
					-- link, active in both pad modes.
					if global_ok == nil then
						local mtrack, midx = LinkEngine.ensureGlobalMIDI()
						global_ok = (mtrack ~= nil and midx >= 0)
						if global_ok then
							LinkEngine.modjsfx.ensureMIDISend(LinkEngine.r, mtrack, track)
						end
					end
					if global_ok then
						midi_cc = LinkEngine.modjsfx.CC_MSB_BASE + (slot - GLOBAL_SLOT_BASE) - 1
						want = true
						lfo_count = lfo_count + 1
					end
				elseif slot > 0 then
					-- Track LFO slot — standing link, active in BOTH pad
					-- modes: in script mode the gesture keeps writing the
					-- param (= moves the baseline) and the LFO rides on top.
					if lfo_idx == nil then lfo_idx = LinkEngine.ensureModLFO() end
					if lfo_idx >= 0 then
						src_fx = lfo_idx
						src_param = LinkEngine.modjsfx.OUT_BASE + slot - 1
						want = true
						lfo_count = lfo_count + 1
					end
				elseif want_links then
					local x_ass, y_ass = LinkEngine.fxmanager.getParamXYAssign(fx_id, param_id)
					local src
					if x_ass and y_ass then src = SRC_MIX
					elseif x_ass then src = SRC_X
					elseif y_ass then src = SRC_Y end
					if src then
						src_fx = bridge
						src_param = src
						want = true
					end
				end
			end
			if want then
				-- TOPOLOGY-ONLY sweep: if the link already points at the
				-- expected source, leave scale/baseline UNTOUCHED. Depth and
				-- base are edited directly on the link (panel knobs, FXC
				-- fast paths) — rewriting them here from FXC's range on
				-- every sweep clobbered edits made in the standalone panel
				-- (depth snapping back to the default range).
				local intact = false
				if not rebuild
				   and getParm(track, target, param_id, "active") == "1" then
					local eff = tonumber(getParm(track, target, param_id, "effect") or "")
					if midi_cc then
						local msg2 = tonumber(getParm(track, target, param_id, "midi_msg2") or "")
						intact = eff == -100
							and (msg2 == 128 + midi_cc or msg2 == midi_cc)
					else
						local sp = tonumber(getParm(track, target, param_id, "param") or "")
						intact = eff == src_fx and sp == src_param
					end
				end
				if not intact then
					local range = LinkEngine.fxmanager.getParamRange(fx_id, param_id)
					local invert = LinkEngine.fxmanager.getParamInvert(fx_id, param_id)
					local span = range * (s.gesture_range or 1.0)
					if invert then span = -span end
					-- Effective value = baseline + (source + offset) × scale,
					-- source ∈ [0,1] → source center (0.5) sits on base.
					if midi_cc then
						-- MIDI link: effect = -100, msg = 0xB0 (CC class),
						-- msg2 = 128 + cc selects the 14-bit CC pair.
						setParm(track, target, param_id, "effect", -100)
						setParm(track, target, param_id, "midi_bus", 0)
						setParm(track, target, param_id, "midi_chan", 1)
						setParm(track, target, param_id, "midi_msg", 176)
						setParm(track, target, param_id, "midi_msg2", 128 + midi_cc)
					else
						setParm(track, target, param_id, "effect", src_fx)
						setParm(track, target, param_id, "param", src_param)
					end
					setParm(track, target, param_id, "offset", -0.5)
					setParm(track, target, param_id, "scale", span)
					setMod(track, target, param_id, "baseline", param_data.base_value or 0.5)
					setMod(track, target, param_id, "active", 1)
					setParm(track, target, param_id, "active", 1)
				end
				count = count + 1
			else
				-- Release only what this engine manages: pad links always,
				-- CP_Mod links only when the param carries a mod_source
				-- entry (Map-made/manual links have none — keep them).
				local kind = linkKind(track, target, param_id)
				if kind == "bridge"
				   or (kind == "cpmod" and param_data.key
				       and s.param_mod_source[param_data.key] ~= nil) then
					releaseLink(track, target, param_id)
				end
			end
		end
	end

	s.links_active = want_links
	s.links_count = count
	-- LFO-sourced links on THIS track (drives the live-value keepalive).
	s.lfo_links_count = lfo_count
	if want_links then LinkEngine.applySlew() end
end

-- Live display value of a param. TrackFX_GetParam returns the BASE value —
-- parameter modulation (plink/LFO) is applied downstream and is invisible
-- to the API. For params linked to one of our sources we recompute the
-- modulated value from the source slider (which IS readable: the bridge
-- and the LFO bank write their own output sliders):
--   value = base + (source − 0.5) × span
-- Native per-param LFO can't be recomputed (phase is REAPER-internal).
function LinkEngine.getLiveValue(fx_id, param_id, param_data)
	local s = LinkEngine.core.state
	if not param_data.selected or not LinkEngine.core.isTrackValid() then
		return param_data.current_value
	end
	local key = param_data.key
	local slot = key and s.param_mod_source[key] or 0
	local src_val
	if slot > GLOBAL_SLOT_BASE then
		local mtrack, midx = LinkEngine.findGlobalMIDI()
		if mtrack and midx >= 0 then
			src_val = LinkEngine.r.TrackFX_GetParam(mtrack, midx,
				LinkEngine.modjsfx.OUT_BASE + (slot - GLOBAL_SLOT_BASE) - 1)
		end
	elseif slot > 0 then
		local lfo_idx = s.modlfo_index or -1
		if lfo_idx >= 0 then
			src_val = LinkEngine.r.TrackFX_GetParam(s.track, lfo_idx,
				LinkEngine.modjsfx.OUT_BASE + slot - 1)
		end
	elseif s.links_active and s.jsfx_automation_index >= 0 then
		local x_ass, y_ass = LinkEngine.fxmanager.getParamXYAssign(fx_id, param_id)
		local src
		if x_ass and y_ass then src = SRC_MIX
		elseif x_ass then src = SRC_X
		elseif y_ass then src = SRC_Y end
		if src then
			src_val = LinkEngine.r.TrackFX_GetParam(s.track, s.jsfx_automation_index, src)
		end
	end
	if not src_val then return param_data.current_value end
	local range = LinkEngine.fxmanager.getParamRange(fx_id, param_id)
	local span = range * (s.gesture_range or 1.0)
	if LinkEngine.fxmanager.getParamInvert(fx_id, param_id) then span = -span end
	local base = param_data.base_value or 0.5
	return math.max(0, math.min(1, base + (src_val - 0.5) * span))
end

-- Full teardown (linked mode toggled off, script closing with mode off…).
function LinkEngine.releaseAll()
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return end
	for fx_id, fx_data in pairs(s.fx_data) do
		local target = fx_data.actual_fx_id or fx_id
		for param_id in pairs(fx_data.params) do
			if ownsLink(s.track, target, param_id) then
				releaseLink(s.track, target, param_id)
			end
		end
	end
	s.links_active = false
	s.links_count = 0
end

return LinkEngine
