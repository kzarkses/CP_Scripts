-- @description FXConstellation
-- @version 2.0
-- @author Cedric Pamalio
-- @about Refactored on top of CP_Toolkit (custom gfx UI, no ReaImGui dependency).

local r = reaper
local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/"
local data_path   = script_path .. "Data/"
local presets_file = data_path .. "presets.dat"

-- ---------------------------------------------------------------------------
-- License manager (optional bundle license)
-- ---------------------------------------------------------------------------
local license_manager = nil
local lm_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_LicenseManager.lua"
if r.file_exists(lm_path) then
    local lm_func = dofile(lm_path)
    if lm_func then
        license_manager = lm_func()
        license_manager.init(r)
    end
end

-- ---------------------------------------------------------------------------
-- CP_Toolkit
-- ---------------------------------------------------------------------------
local toolkit_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua"
local UI_TK = dofile(toolkit_path)

-- ---------------------------------------------------------------------------
-- Domain modules (unchanged — they hold all the business logic)
-- ---------------------------------------------------------------------------
local Core         = dofile(script_path .. "Modules/Core.lua")
local License      = dofile(script_path .. "Modules/License.lua")
local Persistence  = dofile(script_path .. "Modules/Persistence.lua")
local FXDatabase   = dofile(script_path .. "Modules/FXDatabase.lua")
local FXManager    = dofile(script_path .. "Modules/FXManager.lua")
local GestureSystem = dofile(script_path .. "Modules/GestureSystem.lua")
local PresetSystem = dofile(script_path .. "Modules/PresetSystem.lua")
local SoundGenerator = dofile(script_path .. "Modules/SoundGenerator.lua")

local FXManagerUI = dofile(script_path .. "Modules/FXManagerUI.lua")
local UI          = dofile(script_path .. "Modules/UI.lua")

Core.init(r)
License.init(r, license_manager)
Persistence.init(r, Core, data_path, presets_file)
FXDatabase.init(r, Core, Persistence, data_path)
SoundGenerator.init(r, Core)
FXManager.init(r, Core, Persistence, License, SoundGenerator, FXDatabase)
GestureSystem.init(r, Core, FXManager)
PresetSystem.init(r, Core, FXManager, GestureSystem, Persistence, SoundGenerator)

FXManagerUI.init(r, Core, FXManager, FXDatabase, UI_TK)
UI.init(r, Core, FXManager, GestureSystem, PresetSystem, Persistence, SoundGenerator, License, FXManagerUI, UI_TK)

Persistence.loadSettings()
FXDatabase.loadDatabase()
Core.state.snapshot_name = PresetSystem.getNextSnapshotName()
Core.state.granular_set_name = PresetSystem.getNextGranularSetName()

-- ---------------------------------------------------------------------------
-- Toolkit window setup
-- ---------------------------------------------------------------------------
UI_TK.Init("FX Constellation", 1400, 800, {
    persist = "CP_FXConstellation",
    scrollable = false,
    padding = 8,
})

UI_TK.OnClose(function()
    if Core.state.track then FXManager.saveTrackSelection() end
    Persistence.saveSettings()
end)

UI_TK.Run(function(theme)
    -- Hot-reload theme when the Theme Tweaker (or any other CP script)
    -- saves a change. CheckThemeUpdates returns true on the frame the theme
    -- got reloaded so the next frame paints with the new values.
    UI_TK.CheckThemeUpdates()
    UI.frame(theme)
end)
