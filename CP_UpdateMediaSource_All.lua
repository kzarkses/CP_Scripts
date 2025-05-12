-- Function to extract project version number
function getProjectVersion()
    local _, projectPath = reaper.EnumProjects(-1)
    if not projectPath then return nil end
    
    local filename = projectPath:match("([^/\\]+)%.RPP$") or projectPath:match("([^/\\]+)%.rpp$")
    if not filename then return nil end
    
    local version = filename:match("_(%d+)")
    return tonumber(version)
end

-- Function to construct versioned filename
function constructVersionedFile(currentFile, targetVersion)
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    -- Handle different naming patterns
    local prefix
    local currentVersion = baseName:match("[_-]v?(%d+)%.") -- Match _2. or _v2. or -2. or -v2.
    
    if currentVersion then
        prefix = baseName:match("(.+)[_-]v?%d+")
        if not prefix then return nil end
        
        -- Create new versioned filename
        local newFile = string.format("%s_%d.%s", prefix, targetVersion, extension)
        return directory .. "/" .. newFile
    else
        -- Handle case where file doesn't have version number
        prefix = baseName:match("(.+)%.")
        if not prefix then return nil end
        
        local newFile = string.format("%s_%d.%s", prefix, targetVersion, extension)
        return directory .. "/" .. newFile
    end
end

-- Main function to process all items
function ProcessAllItems()
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
                -- Check if versioned file exists
                local file = io.open(versionedFile, "r")
                if file then
                    file:close()
                    -- Update source
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

ProcessAllItems()