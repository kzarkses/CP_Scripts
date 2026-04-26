-- @description ClipLauncher
-- @version 0.4
-- @author Cedric Pamalio

local r = reaper
local script_name = "CP_ClipLauncher"
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local resource_path = r.GetResourcePath()

-- Install JSFX to REAPER Effects folder (auto-update on new version)
local function installJSFX()
    local jsfx_source = resource_path .. "/Scripts/CP_Scripts/CP_JSFX/"
    local effects_dir = resource_path .. "/Effects/CP Clip Launcher/"

    r.RecursiveCreateDirectory(effects_dir, 0)

    local jsfx_files = {
        "CP_ClipEngine.jsfx",
    }

    for _, filename in ipairs(jsfx_files) do
        local src = jsfx_source .. filename
        local dst = effects_dir .. filename

        local src_file = io.open(src, "rb")
        if src_file then
            local src_content = src_file:read("*a")
            src_file:close()

            local needs_install = true
            local dst_file = io.open(dst, "rb")
            if dst_file then
                local dst_content = dst_file:read("*a")
                dst_file:close()
                if dst_content == src_content then
                    needs_install = false
                end
            end

            if needs_install then
                dst_file = io.open(dst, "wb")
                if dst_file then
                    dst_file:write(src_content)
                    dst_file:close()
                end
            end
        end
    end
end

installJSFX()

-- Style loader
local style_loader = nil
local style_loader_path = resource_path .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then
    local loader_func = dofile(style_loader_path)
    if loader_func then
        style_loader = loader_func()
    end
end

-- Load modules
local Core = dofile(script_path .. "Modules/Core.lua")
local Transport = dofile(script_path .. "Modules/Transport.lua")
local ClipManager = dofile(script_path .. "Modules/ClipManager.lua")
local Engine = dofile(script_path .. "Modules/Engine.lua")
local Sequencer = dofile(script_path .. "Modules/Sequencer.lua")
local Persistence = dofile(script_path .. "Modules/Persistence.lua")
local MixerOverlay = dofile(script_path .. "Modules/MixerOverlay.lua")
local TCPOverlay = dofile(script_path .. "Modules/TCPOverlay.lua")
local UI = dofile(script_path .. "Modules/UI.lua")

-- Initialize modules
Core.init(r, script_path, script_name, style_loader)
Transport.init(r, Core)
ClipManager.init(r, Core)
Engine.init(r, Core, ClipManager, Transport)
Sequencer.init(r, Core, Engine, Transport, ClipManager)
Persistence.init(r, Core, ClipManager, Engine, Sequencer)
MixerOverlay.init(r, Core)
TCPOverlay.init(r, Core)
UI.init(r, Core, Engine, ClipManager, Transport, Sequencer, Persistence, MixerOverlay, TCPOverlay, style_loader)

-- Initial sync: creates engine track, discovers all tracks, creates columns
Engine.syncColumns()

-- Load saved session (restores clips, settings to existing columns)
Persistence.loadSession()

local function mainLoop()
    Transport.update()
    Sequencer.update()
    Engine.update()
    Persistence.checkAutoSave()

    local running = UI.draw()

    if running then
        r.defer(mainLoop)
    else
        Persistence.saveSession()
        Engine.cleanup()
    end
end

r.defer(mainLoop)
