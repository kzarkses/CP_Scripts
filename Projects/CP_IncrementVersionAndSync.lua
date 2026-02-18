-- @description IncrementVersionAndSync
-- @version 1.0
-- @author Cedric Pamalio

function getProjectVersion()
    local _, projectPath = reaper.EnumProjects(-1)
    if not projectPath then return nil end
    
    local filename = projectPath:match("([^/\\]+)%.RPP$") or projectPath:match("([^/\\]+)%.rpp$")
    if not filename then return nil end
    
    -- Le pattern exact pour Project_1 mais pas Project_01
    local base, version = filename:match("(.+)_(%d+)$")
    if not base or not version then return nil end
    
    -- VÃ©rifie que ce n'est pas une version alternative (Project_1_1)
    if base:match("_%d+$") then return nil end
    
    return tonumber(version)
end

-- Function to construct versioned filename
function constructVersionedFile(currentFile, targetVersion)
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    local prefix
    local currentVersion = baseName:match("[_-]v?(%d+)%.") 
    
    if currentVersion then
        prefix = baseName:match("(.+)[_-]v?%d+")
        if not prefix then return nil end
        local newFile = string.format("%s_%d.%s", prefix, targetVersion, extension)
        return directory .. "/" .. newFile
    else
        prefix = baseName:match("(.+)%.")
        if not prefix then return nil end
        local newFile = string.format("%s_%d.%s", prefix, targetVersion, extension)
        return directory .. "/" .. newFile
    end
end

-- Function to process all media items
function processAllItems()
    local version = getProjectVersion()
    if not version then
        reaper.ShowMessageBox("Could not detect project version number", "Error", 0)
        return
    end
    
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
            
            local versionedFile = constructVersionedFile(currentFile, version)
            if versionedFile then
                local file = io.open(versionedFile, "r")
                if file then
                    file:close()
                    local newSource = reaper.PCM_Source_CreateFromFile(versionedFile)
                    if reaper.SetMediaItemTake_Source(take, newSource) then
                        reaper.UpdateItemInProject(item)
                        updatedCount = updatedCount + 1
                    else
                        errorCount = errorCount + 1
                    end
                else
                    errorCount = errorCount + 1
                end
            else
                errorCount = errorCount + 1
            end
        end
    end
    
    reaper.Undo_EndBlock("Sync media sources to project version", -1)
    
    local msg = string.format("Updated %d items\nSkipped %d items", updatedCount, errorCount)
    reaper.ShowMessageBox(msg, "Update Results", 0)
end

function incrementAllProjectVersions()
    -- Make sure we get all subprojects
    local allProjects = {}
    local index = 0
    
    -- Get all open projects
    while true do
        local proj = reaper.EnumProjects(index)
        if not proj then break end
        table.insert(allProjects, proj)
        index = index + 1
    end
    
    -- Store current project
    local currentProject = reaper.EnumProjects(-1)
    
    -- Increment version for each project
    for _, proj in ipairs(allProjects) do
        reaper.SelectProjectInstance(proj)
        reaper.Main_OnCommand(41895, 0) -- Save new version
    end
    
    -- Return to original project
    reaper.SelectProjectInstance(currentProject)
    
    -- Now sync all media items to project version
    processAllItems()
end

-- Launch script
incrementAllProjectVersions()










