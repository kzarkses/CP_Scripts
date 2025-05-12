-- Function to get previous file in sequence
local function findPreviousFile(currentFile)
    -- Get directory and file info
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    -- Check if file has number
    local prefix, currentNum
    local hasNumber = baseName:match("_(%d+)%.")
    
    if hasNumber then
        -- File has number, get previous number
        prefix = baseName:match("(.+)_%d+")
        currentNum = tonumber(baseName:match("_(%d+)%."))
        if not prefix or not currentNum then return nil end
        
        if currentNum > 1 then
            -- Create previous numbered file path
            local prevFile = string.format("%s_%d.%s", prefix, currentNum - 1, extension)
            local fullPath = directory .. "/" .. prevFile
            
            -- Check if file exists
            local file = io.open(fullPath, "r")
            if file then
                file:close()
                return fullPath
            end
        elseif currentNum == 1 then
            -- We're at _1, look for unnumbered version
            local baseFile = string.format("%s.%s", prefix, extension)
            local fullPath = directory .. "/" .. baseFile
            
            -- Check if file exists
            local file = io.open(fullPath, "r")
            if file then
                file:close()
                return fullPath
            end
        end
    end
    
    return nil
end

-- Function to process all items
function ProcessAllItems()
    local project = 0 -- Current project
    local itemCount = reaper.CountMediaItems(project)
    local updatedCount = 0
    local errorCount = 0
    
    -- Begin undo block
    reaper.Undo_BeginBlock()
    
    -- Process each item
    for i = 0, itemCount - 1 do
        local item = reaper.GetMediaItem(project, i)
        local take = reaper.GetActiveTake(item)
        
        if take then
            local source = reaper.GetMediaItemTake_Source(take)
            local currentFile = reaper.GetMediaSourceFileName(source)
            
            -- Find previous file
            local prevFile = findPreviousFile(currentFile)
            if prevFile then
                -- Create new source and set it
                local newSource = reaper.PCM_Source_CreateFromFile(prevFile)
                local success = reaper.SetMediaItemTake_Source(take, newSource)
                reaper.UpdateItemInProject(item)
                updatedCount = updatedCount + 1
            else
                errorCount = errorCount + 1
            end
        end
    end
    
    -- End undo block
    reaper.Undo_EndBlock("Update all takes sources to previous files", -1)
    
    -- Show results
    local msg = string.format("Updated %d items\nSkipped %d items", updatedCount, errorCount)
    reaper.ShowMessageBox(msg, "Update Results", 0)
end

ProcessAllItems()