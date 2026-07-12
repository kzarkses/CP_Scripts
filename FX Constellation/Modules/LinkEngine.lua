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

-- CP_Mod LFO: standalone 8-slot LFO bank JSFX (the first brick of the
-- CP_Mod ecosystem — any FX param can link to its block-rate outputs, with
-- or without any CP script running). Sliders 1..40 = 5 settings per slot,
-- sliders 41..48 = hidden outputs → 0-based out params 40..47.
local MODLFO_NAME = "CP_Mod LFO"
local MODLFO_SLOTS = 8
local MODLFO_OUT_BASE = 40

function LinkEngine.init(reaper_api, core, fxmanager, gesture)
	LinkEngine.r = reaper_api
	LinkEngine.core = core
	LinkEngine.fxmanager = fxmanager
	LinkEngine.gesture = gesture
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

-- Is the existing link on (fx, param) one of ours? Ours = source effect is
-- the bridge or a CP_Mod modulator (matched by name, so it survives chain
-- reorders and a stale cached index).
local function ownsLink(track, fx, param_id)
	local active = getParm(track, fx, param_id, "active")
	if active ~= "1" then return false end
	local eff = tonumber(getParm(track, fx, param_id, "effect") or "")
	if not eff or eff < 0 then return false end
	local _, name = LinkEngine.r.TrackFX_GetFXName(track, eff, "")
	return name:find("FX Constellation Bridge") ~= nil
	    or name:find("CP_Mod", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- CP_Mod LFO (shared LFO bank)
-- ---------------------------------------------------------------------------
local function buildModLFOSource()
	local p = {}
	-- desc must be EXACTLY the AddByName lookup string.
	p[#p + 1] = "desc: " .. MODLFO_NAME .. "\n"
	for i = 1, MODLFO_SLOTS do
		local b = (i - 1) * 5
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
	for i = 1, MODLFO_SLOTS do
		p[#p + 1] = ("slider%d:lfo%d_out=0.5<0,1,0.0001>-LFO %d Out (mod source)\n")
			:format(MODLFO_OUT_BASE + i, i, i)
	end
	p[#p + 1] = "\n@init\n"
	for i = 1, MODLFO_SLOTS do
		p[#p + 1] = ("ph%d = 0; held%d = 0.5; cyc%d = -1;\n"):format(i, i, i)
	end
	p[#p + 1] = "\n@block\n"
	for i = 1, MODLFO_SLOTS do
		-- Sync divisions in LFO cycles per quarter note: 1/16=4, 1/8=2,
		-- 1/4=1, 1/2=0.5, 1 bar=0.25, 2 bars=0.125 (4/4 reference). Synced
		-- slots follow beat_position (freeze when the transport is stopped);
		-- free slots accumulate wall-clock phase per block.
		p[#p + 1] = (([[
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
) : ( lfoI_out = 0.5; );
]]):gsub("I", tostring(i)))
	end
	return table.concat(p)
end

function LinkEngine.findModLFO()
	local s = LinkEngine.core.state
	if not LinkEngine.core.isTrackValid() then return -1 end
	local fx_count = LinkEngine.r.TrackFX_GetCount(s.track)
	for fx = 0, fx_count - 1 do
		local _, name = LinkEngine.r.TrackFX_GetFXName(s.track, fx, "")
		if name:find(MODLFO_NAME, 1, true) then return fx end
	end
	return -1
end

-- Find or create the shared LFO bank on the current track. The JSFX file
-- is (re)written on demand, like the bridge and the sound generator.
function LinkEngine.ensureModLFO()
	local existing = LinkEngine.findModLFO()
	if existing >= 0 then return existing end
	if not LinkEngine.core.isTrackValid() then return -1 end
	local path = LinkEngine.r.GetResourcePath() .. "/Effects/" .. MODLFO_NAME .. ".jsfx"
	local file = io.open(path, "w")
	if not file then return -1 end
	file:write(buildModLFOSource())
	file:close()
	return LinkEngine.r.TrackFX_AddByName(LinkEngine.core.state.track, MODLFO_NAME, false, -1)
end

function LinkEngine.openModLFO()
	local idx = LinkEngine.ensureModLFO()
	if idx >= 0 then
		LinkEngine.r.TrackFX_Show(LinkEngine.core.state.track, idx, 3)
	end
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

-- Disable a link we own. mod.active is released only if the user has no
-- LFO/ACS riding on the same parameter — their modulation setup survives.
local function releaseLink(track, fx, param_id)
	setParm(track, fx, param_id, "active", 0)
	local _, lfo = LinkEngine.r.TrackFX_GetNamedConfigParm(track, fx,
		"param." .. param_id .. ".lfo.active")
	local _, acs = LinkEngine.r.TrackFX_GetNamedConfigParm(track, fx,
		"param." .. param_id .. ".acs.active")
	if lfo ~= "1" and acs ~= "1" then
		setMod(track, fx, param_id, "active", 0)
	end
end

-- Push the current base value of one param into its link baseline (fast
-- path for the param-row value drag; avoids a full sync sweep).
function LinkEngine.setBaseline(fx_id, param_id, base_value)
	local s = LinkEngine.core.state
	if not s.links_active or not LinkEngine.core.isTrackValid() then return end
	local fx_data = s.fx_data[fx_id]
	if not fx_data then return end
	setMod(s.track, fx_data.actual_fx_id or fx_id, param_id, "baseline", base_value)
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
	local lfo_idx = nil  -- resolved lazily, once, on first LFO-sourced param
	for fx_id, fx_data in pairs(s.fx_data) do
		local target = fx_data.actual_fx_id or fx_id
		for param_id, param_data in pairs(fx_data.params) do
			local want = false
			local src_fx, src_param
			if param_data.selected then
				local slot = param_data.key and s.param_mod_source[param_data.key] or 0
				if slot > 0 then
					-- CP_Mod LFO slot — a standing link, active in BOTH pad
					-- modes: in script mode the gesture keeps writing the
					-- param (= moves the baseline) and the LFO rides on top.
					if lfo_idx == nil then lfo_idx = LinkEngine.ensureModLFO() end
					if lfo_idx >= 0 then
						src_fx = lfo_idx
						src_param = MODLFO_OUT_BASE + slot - 1
						want = true
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
				local range = LinkEngine.fxmanager.getParamRange(fx_id, param_id)
				local invert = LinkEngine.fxmanager.getParamInvert(fx_id, param_id)
				local span = range * (s.gesture_range or 1.0)
				if invert then span = -span end
				-- Effective value = baseline + (source + offset) × scale,
				-- source ∈ [0,1] → source center (0.5) sits exactly on base.
				setParm(track, target, param_id, "effect", src_fx)
				setParm(track, target, param_id, "param", src_param)
				setParm(track, target, param_id, "offset", -0.5)
				setParm(track, target, param_id, "scale", span)
				setMod(track, target, param_id, "baseline", param_data.base_value or 0.5)
				setMod(track, target, param_id, "active", 1)
				setParm(track, target, param_id, "active", 1)
				count = count + 1
			elseif ownsLink(track, target, param_id) then
				releaseLink(track, target, param_id)
			end
		end
	end

	s.links_active = want_links
	s.links_count = count
	if want_links then LinkEngine.applySlew() end
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
