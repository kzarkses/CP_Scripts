-- @description CP_Mod LFO Panel
-- @version 1.0
-- @author Cedric Pamalio
-- @about Standalone floating panel for the CP_Mod LFO banks. Opens at the
--        mouse cursor — bind it to a shortcut and pop it next to whatever
--        you are tweaking. Edits the selected track's LFO bank (Track tab)
--        or the global cross-track MIDI bank on the hidden CP MOD track
--        (Global tab). Works without FX Constellation running: the banks
--        are plain JSFX, this panel is just a remote control.

local r = reaper
local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/"

local UI_TK = dofile(r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua")
local ModJSFX = dofile(script_path .. "Modules/ModJSFX.lua")
local LFOPanel = dofile(script_path .. "Modules/LFOPanel.lua")
LFOPanel.init(UI_TK)

-- Refresh the JSFX sources so layout updates reach existing instances on
-- the next project (re)load.
ModJSFX.writeBankFile(r, "lfo")
ModJSFX.writeBankFile(r, "midi")

local mode = 1  -- 1 = Track, 2 = Global
local sel = 1

-- Pop up at the mouse cursor (no persisted position — the point of this
-- panel is to appear next to what you're working on).
local mx, my = r.GetMousePosition()
UI_TK.Init("CP LFO", 340, 430, {
	x = mx,
	y = my,
	scrollable = true,
	padding = 8,
})

UI_TK.Run(function(theme)
	UI_TK.CheckThemeUpdates()

	local tch, tidx = UI_TK.TabBar("mode_tabs", { "Track", "Global", "Matrix" }, mode)
	if tch then mode = tidx end

	if mode == 3 then
		local seltr = r.GetSelectedTrack(0, 0)
		LFOPanel.drawMatrix(theme, {
			tag = "matrix:" .. tostring(seltr),
			targets_all = function()
				return ModJSFX.scanAllTargets(r, seltr)
			end,
			inspect = function(tr, fx, parm)
				return ModJSFX.getParamLink(r, tr, fx, parm)
			end,
			set_base = function(tr, fx, parm, v)
				ModJSFX.setParamLinkBase(r, tr, fx, parm, v)
			end,
			set_depth = function(tr, fx, parm, v)
				ModJSFX.setParamLinkDepth(r, tr, fx, parm, v)
			end,
			unlink = function(tr, fx, parm)
				ModJSFX.releaseParamLink(r, tr, fx, parm)
			end,
		})
		return
	end

	local track, bank_idx, hint, add
	if mode == 1 then
		track = r.GetSelectedTrack(0, 0)
		if not track then
			UI_TK.SetFontH2Bold()
			UI_TK.Text("No track selected.")
			UI_TK.SetFontBody()
			return
		end
		local _, tname = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
		UI_TK.SetFontCaption()
		UI_TK.Text((tname and tname ~= "") and tname or "(unnamed track)")
		UI_TK.SetFontBody()
		bank_idx = ModJSFX.findBank(r, track, "lfo")
		hint = "No CP_Mod LFO bank on this track yet."
		add = function() ModJSFX.ensureBank(r, track, "lfo") end
	else
		track = ModJSFX.findModTrack(r)
		bank_idx = track and ModJSFX.findBank(r, track, "midi") or -1
		hint = "Global bank: hidden CP MOD track, modulates any track through 14-bit CC."
		add = function()
			local mtrack = ModJSFX.ensureModTrack(r)
			if mtrack then ModJSFX.ensureBank(r, mtrack, "midi") end
		end
	end

	local ctx = {
		present = track ~= nil and bank_idx >= 0,
		hint = hint,
		get = function(i) return ModJSFX.getSlot(r, track, bank_idx, i) end,
		set = function(i, patch) ModJSFX.setSlot(r, track, bank_idx, i, patch) end,
		add = add,
		sel = sel,
		onSelect = function(i) sel = i end,
	}
	-- Target inspector (both tabs) + Bitwig-style mapping (global tab):
	-- arm "Map" then touch any parameter anywhere in REAPER, or link the
	-- last touched one. Base/Depth of the touched target edit the link
	-- directly (raw writes — FX Constellation re-syncs its own params).
	ctx.touched = function()
		-- Real last-touched merged with the click-to-focus hint (clicking
		-- a param name in FX Constellation) — most recent event wins.
		local tr, fx, parm, name = ModJSFX.getFocusParam(r)
		if not tr or ModJSFX.isInternalFX(name) then return nil end
		return tr, fx, parm, name
	end
	ctx.inspect = function(tr, fx, parm)
		return ModJSFX.getParamLink(r, tr, fx, parm)
	end
	ctx.set_base = function(tr, fx, parm, v)
		ModJSFX.setParamLinkBase(r, tr, fx, parm, v)
	end
	ctx.set_depth = function(tr, fx, parm, v)
		ModJSFX.setParamLinkDepth(r, tr, fx, parm, v)
	end
	ctx.unlink = function(tr, fx, parm)
		ModJSFX.releaseParamLink(r, tr, fx, parm)
	end
	if mode == 2 then
		ctx.tag = "global"
		ctx.link = function(tr, fx, parm, slot)
			ModJSFX.linkParamToGlobalSlot(r, tr, fx, parm, slot, 0.5)
		end
		ctx.targets = function(slot)
			return ModJSFX.scanSlotTargets(r, "global", nil, slot)
		end
	else
		-- Track identity in the tag: switching tracks must invalidate the
		-- panel's cached target registry.
		ctx.tag = "track:" .. tostring(track)
		ctx.targets = function(slot)
			return ModJSFX.scanSlotTargets(r, "lfo", track, slot)
		end
	end
	LFOPanel.draw(theme, ctx)
end)
