-- @description CP Sound Generator Panel
-- @version 1.0
-- @author Cedric Pamalio
-- @about Standalone floating panel for the FX Constellation Sound Generator.
--        Opens at the mouse cursor and follows the selected track — a large
--        view with the three oscillators side by side (no tab switching).
--        Works without FX Constellation running: it drives the generator
--        JSFX directly; a running FXC instance picks the edits up through
--        its own 4 Hz resync.

local r = reaper
local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/"

-- License (the Sound Generator is a premium feature, same gate as FXC).
local license_manager = nil
local lm_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_LicenseManager.lua"
if r.file_exists(lm_path) then
	local lm_func = dofile(lm_path)
	if lm_func then
		license_manager = lm_func()
		license_manager.init(r)
	end
end

local UI_TK = dofile(r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua")
local License = dofile(script_path .. "Modules/License.lua")
local SoundGenerator = dofile(script_path .. "Modules/SoundGenerator.lua")
local SGPanel = dofile(script_path .. "Modules/SGPanel.lua")

License.init(r, license_manager)
SGPanel.init(UI_TK)

-- Mini-core: exactly what SoundGenerator needs (track + sound_generator
-- state + validity check). The table is populated from the JSFX instance
-- by syncFromJSFX, so the defaults below only matter for a fresh add.
local core = {
	state = {
		track = nil,
		sound_generator = {
			enabled = false,
			jsfx_index = -1,
			mode = 0,
			amplitude = 0.5,
			rhythmic = false,
			tick_rate = 4.0,
			duty_cycle = 0.5,
			rhythmic_curve = 0.0,
			use_adsr = true,
			attack = 0.01,
			decay = 0.1,
			sustain = 0.7,
			release = 0.2,
			midi_mode = false,
			ui_osc_tab = 1,
			osc = {
				{ on = true,  wave = 0, freq = 440.0, width = 10.0, vol = 1.0, color = 0.5 },
				{ on = false, wave = 3, freq = 220.0, width = 10.0, vol = 0.5, color = 0.5 },
				{ on = false, wave = 1, freq = 880.0, width = 10.0, vol = 0.5, color = 0.5 }
			}
		}
	}
}
function core.isTrackValid()
	return core.state.track ~= nil
	   and r.ValidatePtr(core.state.track, "MediaTrack*")
end
SoundGenerator.init(r, core)

-- Pop up at the mouse cursor (no persisted position — the point of this
-- panel is to appear next to what you're working on).
local mx, my = r.GetMousePosition()
UI_TK.Init("CP SoundGen", 720, 460, {
	x = mx,
	y = my,
	scrollable = true,
	padding = 8,
})

local last_sync = 0

UI_TK.Run(function(theme)
	UI_TK.CheckThemeUpdates()

	if not License.isFull() then
		UI_TK.SetFontH2Bold()
		UI_TK.Text("Premium feature")
		UI_TK.SetFontBody()
		UI_TK.TextWrapped("The Sound Generator requires an FX Constellation "
			.. "license. Activate it from the FX Constellation window.")
		return
	end

	local track = r.GetSelectedTrack(0, 0)
	if track ~= core.state.track then
		core.state.track = track
		core.state.sound_generator.jsfx_index = -1
		if track then SoundGenerator.syncFromJSFX() end
	end
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

	-- Resync from the JSFX at 4 Hz, never mid-drag (the JSFX sliders are
	-- stepped: a same-frame read-back quantizes the value under the drag).
	-- Also picks up edits made in a running FX Constellation.
	local now = r.time_precise()
	if not UI_TK.Core.MouseDown(1) and now - last_sync >= 0.25 then
		last_sync = now
		SoundGenerator.syncFromJSFX()
	end

	SGPanel.draw(theme, {
		sg = core.state.sound_generator,
		wide = true,
		apply = SoundGenerator.updateJSFXParams,
		trigger = SoundGenerator.setManualTrigger,
		toggle = function()
			if not core.state.sound_generator.enabled then
				SoundGenerator.createGenerator()
			else
				SoundGenerator.removeGenerator()
			end
		end,
	})
end)
