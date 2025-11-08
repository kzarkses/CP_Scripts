-- @description FXConstellation
-- @version 1.2
-- @author Cedric Pamalio

local r = reaper
local script_name = "CP_FXConstellation"
local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/"
local data_path = script_path .. "Data/"
local presets_file = data_path .. "presets.dat"

local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then
	local loader_func = dofile(style_loader_path)
	if loader_func then
		style_loader = loader_func()
	end
end

local ctx = r.ImGui_CreateContext('FX Constellation')
if style_loader then
	style_loader.ApplyFontsToContext(ctx)
end

function GetStyleValue(path, default_value)
	return style_loader and style_loader.GetValue(path, default_value) or default_value
end

local header_font_size = GetStyleValue("fonts.header.size", 16)
local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
local window_padding_x = GetStyleValue("spacing.window_padding_x", 6)
local window_padding_y = GetStyleValue("spacing.window_padding_y", 6)

local Core = dofile(data_path .. "Core.dat")
local License = dofile(data_path .. "License.dat")
local Persistence = dofile(data_path .. "Persistence.dat")
local FXManager = dofile(data_path .. "FXManager.dat")
local GestureSystem = dofile(data_path .. "GestureSystem.dat")
local PresetSystem = dofile(data_path .. "PresetSystem.dat")
local SoundGenerator = dofile(data_path .. "SoundGenerator.dat")
local UI = dofile(data_path .. "UI.dat")

Core.init(r)
License.init(r)
Persistence.init(r, Core, data_path, presets_file)
FXManager.init(r, Core, Persistence, License)
GestureSystem.init(r, Core, FXManager)
SoundGenerator.init(r, Core)
PresetSystem.init(r, Core, FXManager, GestureSystem, Persistence, SoundGenerator)
UI.init(r, Core, FXManager, GestureSystem, PresetSystem, Persistence, SoundGenerator, License, style_loader, ctx, header_font_size, item_spacing_x, item_spacing_y, window_padding_x, window_padding_y)

Persistence.loadSettings()

Core.state.snapshot_name = PresetSystem.getNextSnapshotName()
Core.state.granular_set_name = PresetSystem.getNextGranularSetName()

local function loop()
	local open = UI.drawInterface()
	if open then
		r.defer(loop)
	else
		Persistence.saveSettings()
	end
end

r.defer(loop)
