-- @description CP Inspector — Media item property bar
-- @version 1.1
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")

local InspCore = dofile(script_path .. "Modules/Core.lua")
local InspUI   = dofile(script_path .. "Modules/UI.lua")

InspUI.Init(InspCore, UI)
InspCore.SetToolkit(UI)
InspCore.LoadSettings()

-- REAPER toolbar toggle state
local _, _, section_id, command_id = reaper.get_action_context()
reaper.SetToggleCommandState(section_id, command_id, 1)
reaper.RefreshToolbar2(section_id, command_id)

-- Init window — toolbar mode (no scrollbar), persists position/dock/size,
-- minimal window padding (Inspector controls layout via prefs).
UI.Init("CP Inspector", 1200, 50, {
    scale = 1.0,
    dock = 0,
    scrollable = false,
    persist = "CP_Inspector",
    padding = InspCore.state.prefs.window_padding,
})

-- Apply window padding + background color from prefs (live-reloadable)
local function ApplyVisualPrefs()
    local p = InspCore.state.prefs
    UI.SetWindowPadding(p.window_padding)
    -- Mutate the per-script theme so Layout.Begin paints the chosen bg
    local t = UI.GetTheme()
    if t and p.col_bg then
        t.colors.window_bg[1] = p.col_bg[1]
        t.colors.window_bg[2] = p.col_bg[2]
        t.colors.window_bg[3] = p.col_bg[3]
        t.colors.window_bg[4] = p.col_bg[4] or 1
    end
end
ApplyVisualPrefs()

UI.Run(function(theme)
    -- Live-reload theme if the Theme Tweaker saved a change
    if UI.CheckThemeUpdates() then
        -- Theme was reloaded — re-apply our local visual prefs on top so
        -- the inspector's own bg/padding overrides survive a theme reload.
        ApplyVisualPrefs()
        theme = UI.GetTheme()
    end
    -- Live-reload settings if the Settings script bumped the version
    if InspCore.CheckForUpdates() then
        ApplyVisualPrefs()
    end
    InspCore.RefreshSelection()
    InspUI.Draw(theme)
end)

UI.OnClose(function()
    InspCore.SaveSettings()
    reaper.SetToggleCommandState(section_id, command_id, 0)
    reaper.RefreshToolbar2(section_id, command_id)
end)
