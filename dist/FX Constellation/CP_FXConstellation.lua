-- @description CP FX Constellation
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   Advanced FX parameter manipulation with XY gesture control,
--   preset management, randomization, and sound generation.
-- @links
--   Store Page https://gumroad.com/TODO
-- @provides
--   Data53/*.lua

local r = reaper
local SEP = package.config:sub(1, 1)
local script_path = debug.getinfo(1, 'S').source:match('@(.+[/\\])')
local data_path = script_path .. "Data53" .. SEP
local user_data_path = script_path .. "Data" .. SEP

-- Ensure user data directory exists
reaper.RecursiveCreateDirectory(user_data_path, 0)

-- Style loader (shared dependency)
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then
	local loader_func = dofile(style_loader_path)
	if loader_func then style_loader = loader_func() end
end

local ctx = r.ImGui_CreateContext('FX Constellation')
if style_loader then style_loader.ApplyFontsToContext(ctx) end

function GetStyleValue(path, default_value)
	return style_loader and style_loader.GetValue(path, default_value) or default_value
end

local header_font_size = GetStyleValue("fonts.header.size", 16)
local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
local window_padding_x = GetStyleValue("spacing.window_padding_x", 6)
local window_padding_y = GetStyleValue("spacing.window_padding_y", 6)

local presets_file = user_data_path .. "presets.dat"

-- Load modules
local Core = dofile(data_path .. "Core.lua")
local License = dofile(data_path .. "License.lua")
local Persistence = dofile(data_path .. "Persistence.lua")
local FXDatabase = dofile(data_path .. "FXDatabase.lua")
local FXManager = dofile(data_path .. "FXManager.lua")
local GestureSystem = dofile(data_path .. "GestureSystem.lua")
local PresetSystem = dofile(data_path .. "PresetSystem.lua")
local SoundGenerator = dofile(data_path .. "SoundGenerator.lua")
local FXManagerUI = dofile(data_path .. "FXManagerUI.lua")
local UI = dofile(data_path .. "UI.lua")

-- Initialize
Core.init(r)
License.init(r)
Persistence.init(r, Core, user_data_path, presets_file)
FXDatabase.init(r, Core, Persistence, user_data_path)
SoundGenerator.init(r, Core)
FXManager.init(r, Core, Persistence, License, SoundGenerator, FXDatabase)
GestureSystem.init(r, Core, FXManager)
PresetSystem.init(r, Core, FXManager, GestureSystem, Persistence, SoundGenerator)
FXManagerUI.init(r, Core, FXManager, FXDatabase, style_loader)
UI.init(r, Core, FXManager, GestureSystem, PresetSystem, Persistence, SoundGenerator, License, FXManagerUI, style_loader, ctx, header_font_size, item_spacing_x, item_spacing_y, window_padding_x, window_padding_y)

Persistence.loadSettings()
FXDatabase.loadDatabase()

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
