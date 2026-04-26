-- @description CP Inspector — Take Renamer (standalone)
-- @version 1.1
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")
local TakeRenamer = dofile(script_path .. "Modules/TakeRenamer.lua")

-- No-selection guard: refuse to open if nothing is selected
if reaper.CountSelectedMediaItems(0) == 0 then
    reaper.MB("No media items selected.\nSelect at least one item to rename.",
              "CP Inspector — Take Renamer", 0)
    return
end

TakeRenamer.SetToolkit(UI)
TakeRenamer.LoadSettings()
TakeRenamer.RefreshSelection()  -- prefill base_name from current selection
TakeRenamer.state.need_focus = true

UI.Init("CP Inspector — Take Renamer", 420, 460, {
    scale = 1.0,
    persist = "CP_Inspector_TakeRenamer",
})

UI.Run(function(theme)
    if UI.CheckThemeUpdates() then
        theme = UI.GetTheme()
    end
    TakeRenamer.Draw(UI, theme)
end)

UI.OnClose(function()
    TakeRenamer.SaveSettings()
end)
