-- @description CP ChordLab — guitar-fretboard chord authoring & suggestion tool
-- @version 1.0
-- @author Cedric Pamalio

-- Entry point. Resolves paths, wires the toolkit + modules (dependency
-- injection per ARCHITECTURE.md), sets the toolbar toggle state, and drives the
-- frame loop through App.Frame. Follows the CP_Inspector launcher pattern.

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"
local mod_path = script_path .. "Modules/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")

-- Pure + REAPER modules, wired exactly as the contract prescribes.
local Theory    = dofile(mod_path .. "Theory.lua")
local Voicing   = dofile(mod_path .. "Voicing.lua");   Voicing.Init(Theory)
local Suggest   = dofile(mod_path .. "Suggest.lua");   Suggest.Init(Theory, Voicing)
local Fretboard = dofile(mod_path .. "Fretboard.lua"); Fretboard.Init(Theory)
local MidiIO    = dofile(mod_path .. "MidiIO.lua");    MidiIO.Init(Theory, Voicing)
local Preview   = dofile(mod_path .. "Preview.lua")

-- UI layer.
local App            = dofile(mod_path .. "App.lua")
local UI_Timeline    = dofile(mod_path .. "UI_Timeline.lua")
local UI_Fretboard   = dofile(mod_path .. "UI_Fretboard.lua")
local UI_Suggestions = dofile(mod_path .. "UI_Suggestions.lua")

App.Init({
    UI = UI,
    Theory = Theory, Voicing = Voicing, Fretboard = Fretboard,
    Suggest = Suggest, MidiIO = MidiIO, Preview = Preview,
    UI_Timeline = UI_Timeline,
    UI_Fretboard = UI_Fretboard,
    UI_Suggestions = UI_Suggestions,
})

-- REAPER toolbar toggle state.
local _, _, section_id, command_id = reaper.get_action_context()
reaper.SetToggleCommandState(section_id, command_id, 1)
reaper.RefreshToolbar2(section_id, command_id)

-- Window: default 980×560, persisted across sessions.
UI.Init("CP ChordLab", 980, 560, {
    scale = 1.0,
    dock = 0,
    persist = "CP_ChordLab",
})

UI.Run(App.Frame)

UI.OnClose(function()
    App.Shutdown()
    reaper.SetToggleCommandState(section_id, command_id, 0)
    reaper.RefreshToolbar2(section_id, command_id)
end)
