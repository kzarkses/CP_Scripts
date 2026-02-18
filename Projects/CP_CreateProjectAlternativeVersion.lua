-- @description CreateProjectAlternativeVersion
-- @version 1.0
-- @author Cedric Pamalio

function createAlternativeVersion()
    -- Get current project filename
    local proj = 0
    local _, projectPath = reaper.EnumProjects(-1)
    if not projectPath then 
        reaper.ShowMessageBox("No project found", "Error", 0)
        return 
    end
    
    -- Extract filename without extension
    local directory = projectPath:match("(.+)[/\\]")
    local filename = projectPath:match("([^/\\]+)%.RPP$") or projectPath:match("([^/\\]+)%.rpp$")
    if not filename then return end
    
    -- Check if there's a version number
    local base, version = filename:match("(.+)_(%d+)$")
    
    if not base or not version then
        reaper.ShowMessageBox("Please save a numbered version first (ex: Project_1)", "Error", 0)
        return
    end
    
    -- Check if there's already an alternative version
    local altBase, mainVer, altVer = filename:match("(.+)_(%d+)_(%d+)$")
    
    local newFilename
    if altBase and mainVer and altVer then
        -- Increment alternative version
        newFilename = string.format("%s_%s_%d", altBase, mainVer, tonumber(altVer) + 1)
    else
        -- Create first alternative version
        newFilename = string.format("%s_%s_1", base, version)
    end
    
    -- Create full path
    local newPath = directory .. "/" .. newFilename .. ".RPP"
    
    -- Save project as new version
    reaper.Main_SaveProjectEx(proj, newPath, 0)
    
    -- Open the new version (with noprompt to avoid save dialog)
    reaper.Main_openProject("noprompt:" .. newPath)
end

createAlternativeVersion()










