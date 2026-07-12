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
-- the bridge (matched by name, so it survives chain reorders and a stale
-- cached bridge index).
local function ownsLink(track, fx, param_id)
	local active = getParm(track, fx, param_id, "active")
	if active ~= "1" then return false end
	local eff = tonumber(getParm(track, fx, param_id, "effect") or "")
	if not eff or eff < 0 then return false end
	local _, name = LinkEngine.r.TrackFX_GetFXName(track, eff, "")
	return name:find("FX Constellation Bridge") ~= nil
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
	for fx_id, fx_data in pairs(s.fx_data) do
		local target = fx_data.actual_fx_id or fx_id
		for param_id, param_data in pairs(fx_data.params) do
			local want = false
			local src
			if want_links and param_data.selected then
				local x_ass, y_ass = LinkEngine.fxmanager.getParamXYAssign(fx_id, param_id)
				if x_ass and y_ass then src = SRC_MIX
				elseif x_ass then src = SRC_X
				elseif y_ass then src = SRC_Y end
				want = src ~= nil
			end
			if want then
				local range = LinkEngine.fxmanager.getParamRange(fx_id, param_id)
				local invert = LinkEngine.fxmanager.getParamInvert(fx_id, param_id)
				local span = range * (s.gesture_range or 1.0)
				if invert then span = -span end
				-- Effective value = baseline + (source + offset) × scale,
				-- source ∈ [0,1] → pad center (0.5) sits exactly on base.
				setParm(track, target, param_id, "effect", bridge)
				setParm(track, target, param_id, "param", src)
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
