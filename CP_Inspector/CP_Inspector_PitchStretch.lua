-- @description CP Inspector — Pitch & Stretch (standalone)
-- @version 1.0
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")
local InspCore = dofile(script_path .. "Modules/Core.lua")
local PitchStretch = dofile(script_path .. "Modules/PitchStretch.lua")

PitchStretch.Init(InspCore)

UI.Init("CP Inspector — Pitch & Stretch", 520, 470, {
    scale = 1.0,
    persist = "CP_Inspector_PitchStretch",
    scrollable = false,  -- fixed layout, no root scrollbar
})

UI.OnClose(function() PitchStretch.SaveSettings() end)

UI.Run(function(theme)
    PitchStretch.Draw(UI, theme)
end)
