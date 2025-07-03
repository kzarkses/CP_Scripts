-- @description CreateProjectAndSubprojectAlternativeVersion
-- @version 1.0
-- @author Cedric Pamalio

function getProjectVersionInfo(projectPath)
    if not projectPath then return nil end
    
    local filename = projectPath:match("([^/\\]+)%.RPP$") or projectPath:match("([^/\\]+)%.rpp$")
    if not filename then return nil end
    
    -- Check if it's already an alternative version (e.g., Test_1_1)
    local baseName, mainVer, altVer = filename:match("(.+)_(%d+)_(%d+)$")
    if baseName and mainVer and altVer then
        return {
            baseName = baseName,
            mainVersion = mainVer,
            altVersion = altVer,
            isAlt = true
        }
    end
    
    -- Check if it's a main version (e.g., Test_1)
    local base, ver = filename:match("(.+)_(%d+)$")
    if base and ver then
        return {
            baseName = base,
            mainVersion = ver,
            altVersion = nil,
            isAlt = false
        }
    end
    
    return nil
end

-- Function to create alternative version path
function createAlternativeVersionPath(directory, baseName, mainVer, altVer)
    return string.format("%s/%s_%s_%d.RPP", directory, baseName, mainVer, altVer)
end

-- Function to check if a file exists
function fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- Function to process all media items
function processAllItems(targetVersion)
    local project = 0
    local itemCount = reaper.CountMediaItems(project)
    local updatedCount = 0
    local errorCount = 0
    
    reaper.Undo_BeginBlock()
    
    for i = 0, itemCount - 1 do
        local item = reaper.GetMediaItem(project, i)
        local take = reaper.GetActiveTake(item)
        
        if take then
            local source = reaper.GetMediaItemTake_Source(take)
            local currentFile = reaper.GetMediaSourceFileName(source)
            
            -- Get directory and file info
            local directory = currentFile:match("(.+)[/\\]")
            local filename = currentFile:match("^.+[/\\](.+)$")
            if directory and filename then
                -- Try to match either version pattern
                local info = getProjectVersionInfo(filename)
                if info then
                    local altPath
                    if info.isAlt then
                        -- Already an alternative version, create next one
                        altPath = createAlternativeVersionPath(directory, info.baseName, info.mainVersion, targetVersion)
                    else
                        -- Main version, create first alternative
                        altPath = createAlternativeVersionPath(directory, info.baseName, info.mainVersion, targetVersion)
                    end
                    
                    -- Update source if alternative version exists
                    if fileExists(altPath) then
                        local newSource = reaper.PCM_Source_CreateFromFile(altPath)
                        if reaper.SetMediaItemTake_Source(take, newSource) then
                            reaper.UpdateItemInProject(item)
                            updatedCount = updatedCount + 1
                        else
                            errorCount = errorCount + 1
                        end
                    else
                        errorCount = errorCount + 1
                    end
                end
            end
        end
    end
    
    reaper.Undo_EndBlock("Sync media sources to alternative version", -1)
    
    local msg = string.format("Updated %d items\nSkipped %d items", updatedCount, errorCount)
    reaper.ShowMessageBox(msg, "Update Results", 0)
end

function incrementAllProjectAlternativeVersions()
    -- Get current project info
    local _, mainProjectPath = reaper.EnumProjects(-1)
    local mainProjectInfo = getProjectVersionInfo(mainProjectPath)
    
    if not mainProjectInfo then
        reaper.ShowMessageBox("Main project must have a version number (e.g., Project_1)", "Error", 0)
        return
    end
    
    -- Determine target alternative version
    local targetAltVer = 1
    if mainProjectInfo.isAlt then
        targetAltVer = tonumber(mainProjectInfo.altVersion) + 1
    end
    
    -- Store all open projects
    local allProjects = {}
    local index = 0
    while true do
        local proj = reaper.EnumProjects(index)
        if not proj then break end
        local _, path = reaper.EnumProjects(index)
        table.insert(allProjects, {proj = proj, path = path})
        index = index + 1
    end
    
    -- Store current project
    local currentProject = reaper.EnumProjects(-1)
    
    -- Create alternative version for each project
    for _, projInfo in ipairs(allProjects) do
        reaper.SelectProjectInstance(projInfo.proj)
        
        local info = getProjectVersionInfo(projInfo.path)
        if info then
            local directory = projInfo.path:match("(.+)[/\\]")
            local newPath = createAlternativeVersionPath(directory, info.baseName, info.mainVersion, targetAltVer)
            reaper.Main_SaveProjectEx(projInfo.proj, newPath, 0)
            
            -- If this is the main project, open the new version
            if projInfo.proj == currentProject then
                reaper.Main_openProject("noprompt:" .. newPath)
            end
        end
    end
    
    -- Sync all media items to the new version
    processAllItems(targetAltVer)
end

-- Launch script
incrementAllProjectAlternativeVersions()










