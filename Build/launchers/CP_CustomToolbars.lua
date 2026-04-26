-- @description CP Custom Toolbars
-- @version 1.1.0
-- @author Cedric Pamalio
-- @about
--   Custom floating toolbars that snap to REAPER windows,
--   with preset management, icon support, and responsive layout.
-- @provides
--   Data53/*.lua

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local SEP = package.config:sub(1, 1)
local data_path = script_path .. "Data53" .. SEP
local extname_base = "CP_CustomToolbars"

local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then
    local loader_func = dofile(style_loader_path)
    if loader_func then
        style_loader = loader_func()
    end
end

local license_manager = nil
local lm_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_LicenseManager.lua"
if r.file_exists(lm_path) then
    local lm_func = dofile(lm_path)
    if lm_func then
        license_manager = lm_func()
        license_manager.init(r)
    end
end

local Core = dofile(data_path .. "Core.lua")
local WindowTracker = dofile(data_path .. "WindowTracker.lua")
local IconManager = dofile(data_path .. "IconManager.lua")
local Config = dofile(data_path .. "Config.lua")
local Persistence = dofile(data_path .. "Persistence.lua")
local StyleManager = dofile(data_path .. "StyleManager.lua")
local ToolbarManager = dofile(data_path .. "ToolbarManager.lua")
local ActionManager = dofile(data_path .. "ActionManager.lua")
local Renderer = dofile(data_path .. "Renderer.lua")
local PresetSystem = dofile(data_path .. "PresetSystem.lua")
local UI = dofile(data_path .. "UI.lua")

Core.init(r, script_path, extname_base, style_loader, license_manager)
Core.ensureSerialize()

local script_initialized = false

WindowTracker.init(Core)
IconManager.init(Core)
Config.init(Core)
Persistence.init(Core, Config)
StyleManager.init(Core)
ToolbarManager.init(Core, IconManager, StyleManager)
ActionManager.init(Core)
Renderer.init(Core, WindowTracker, IconManager, ActionManager, StyleManager, ToolbarManager)
PresetSystem.init(Core, Persistence)
UI.init(Core, ToolbarManager, PresetSystem, StyleManager, IconManager, ActionManager, Persistence, Renderer)

local function checkToolbarToggleState()
    local open_manager = r.GetExtState(extname_base, "open_manager")
    if open_manager == "1" then
        Core.state.show_manager = true
        r.DeleteExtState(extname_base, "open_manager", false)
    end
end

local function mainLoop()
    if r.GetExtState(extname_base, "running") ~= "1" then
        return
    end

    Core.state.frame_counter = Core.state.frame_counter + 1

    Core.updateIdleState()

    if Core.state.is_idle and not Core.state.show_manager then
        Core.state.idle_frame_skip = Core.state.idle_frame_skip + 1
        if Core.state.idle_frame_skip < Core.constants.IDLE_FRAME_SKIP then
            r.defer(mainLoop)
            return
        end
        Core.state.idle_frame_skip = 0
    else
        Core.state.idle_frame_skip = 0
    end

    WindowTracker.checkWindowToggleChanges()

    WindowTracker.updateCache()

    if Core.state.frame_counter % Core.constants.TOGGLE_CHECK_INTERVAL == 0 then
        checkToolbarToggleState()
    end

    if Core.state.frame_counter % Core.constants.ICON_CLEANUP_FRAMES == 0 then
        IconManager.cleanupUnused()
    end

    Config.processSaveQueue()
    Persistence.processToolbarSaveQueue()

    for _, toolbar in ipairs(Core.state.toolbars) do
        if toolbar.is_enabled then
            if toolbar.font_needs_update then
                ToolbarManager.ensureToolbarReady(toolbar)
            end

            if WindowTracker.shouldDisplayToolbar(toolbar) then
                Renderer.displayToolbarWidget(toolbar)
            end
        end
    end

    if Core.state.show_manager then
        Core.state.show_manager = UI.showToolbarManager()
    end

    r.defer(mainLoop)
end

local function start()
    Config.loadSettings()
    Persistence.loadToolbars()

    if #Core.state.toolbars == 0 then
        ToolbarManager.createToolbar("Default Toolbar")
    end

    PresetSystem.loadPresets()

    Core.state.manager_ctx = r.ImGui_CreateContext('Custom Toolbars Manager')
    if style_loader then
        style_loader.ApplyFontsToContext(Core.state.manager_ctx)
    end

    script_initialized = true

    mainLoop()
end

local function stop()
    if script_initialized then
        Persistence.saveToolbars()
        Config.saveSettings()

        for _, toolbar in ipairs(Core.state.toolbars) do
            ToolbarManager.cleanupToolbarResources(toolbar)
        end

        IconManager.invalidateCache()

        if Core.state.manager_ctx and r.ImGui_ValidatePtr(Core.state.manager_ctx, "ImGui_Context*") then
            Core.state.manager_ctx = nil
        end
    end
end

local function toggleScript()
    local state = r.GetExtState(extname_base, "running")

    if state == "1" then
        r.SetExtState(extname_base, "running", "0", false)
        stop()
    else
        r.SetExtState(extname_base, "running", "1", false)
        start()
    end
end

toggleScript()
