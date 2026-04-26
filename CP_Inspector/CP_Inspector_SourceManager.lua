-- @description CP Inspector — Source Manager (standalone)
-- @version 1.0
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")
local SourceManager = dofile(script_path .. "Modules/SourceManager.lua")

SourceManager.Init()

UI.Init("CP Inspector — Source Manager", 600, 540, {
    scale = 1.0,
    persist = "CP_Inspector_SourceManager",
    scrollable = false,
})

UI.OnClose(function() SourceManager.SaveSettings() end)

UI.Run(function(theme)
    SourceManager.Draw(UI, theme)
end)
