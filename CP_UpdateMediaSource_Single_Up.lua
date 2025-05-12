-- Function to get next file in sequence
local function findNextFile(currentFile)
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
        -- File has number, get next number
        prefix = baseName:match("(.+)_%d+")
        currentNum = tonumber(baseName:match("_(%d+)%."))
        if not prefix or not currentNum then return nil end
        
        -- Create next numbered file path
        local nextFile = string.format("%s_%d.%s", prefix, currentNum + 1, extension)
        local fullPath = directory .. "/" .. nextFile
        
        -- Check if file exists
        local file = io.open(fullPath, "r")
        if file then
            file:close()
            return fullPath
        end
    else
        -- File has no number, look for _1 version
        prefix = baseName:match("(.+)%.")
        if not prefix then return nil end
        
        -- Create first numbered file path
        local nextFile = string.format("%s_1.%s", prefix, extension)
        local fullPath = directory .. "/" .. nextFile
        
        -- Check if file exists
        local file = io.open(fullPath, "r")
        if file then
            file:close()
            return fullPath
        end
    end
    
    return nil
end

-- Function to process all items
function ProcessAllItems()
    local project = 0 -- Current project
    local itemCount = reaper.CountSelectedMediaItems(project)
    local updatedCount = 0
    local errorCount = 0
    
    -- Begin undo block
    reaper.Undo_BeginBlock()
    
    -- Process each item
    for i = 0, itemCount - 1 do
        local item = reaper.GetSelectedMediaItem(project, i)
        local take = reaper.GetActiveTake(item)
        
        if take then
            local source = reaper.GetMediaItemTake_Source(take)
            local currentFile = reaper.GetMediaSourceFileName(source)
            
            -- Find next file
            local nextFile = findNextFile(currentFile)
            if nextFile then
                -- Create new source and set it
                local newSource = reaper.PCM_Source_CreateFromFile(nextFile)
                local success = reaper.SetMediaItemTake_Source(take, newSource)
                reaper.UpdateItemInProject(item)
                updatedCount = updatedCount + 1
            else
                errorCount = errorCount + 1
            end
        end
    end
    
    -- End undo block
    reaper.Undo_EndBlock("Update all takes sources to next files", -1)
    
    -- Show results
    local msg = string.format("Updated %d items\nSkipped %d items", updatedCount, errorCount)
    reaper.ShowMessageBox(msg, "Update Results", 0)
end

ProcessAllItems()