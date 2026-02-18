-- @description UpdateMediaSource Next
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

-- Source tracking table to release PCM sources properly
local temp_sources = {}

-- Helper function to safely destroy PCM sources
function safelyDestroySource(source)
    if source then
        -- Check if Destroy function exists and use it
        if r.PCM_Source_Destroy then
            r.PCM_Source_Destroy(source)
        end
    end
end

-- Function to clean up all temporary sources
function cleanupTempSources()
    for i, source in ipairs(temp_sources) do
        safelyDestroySource(source)
    end
    -- Clear the table
    temp_sources = {}
end

-- Function to get next file in sequence
function findNextFile(currentFile)
    -- Get directory and file info
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    -- Get basename without extension
    local nameWithoutExt = baseName:match("(.+)%.")
    if not nameWithoutExt then return nil end
    
    -- Check if file already has a numbering pattern
    local hasNumber = false
    local prefix, currentNum, separator
    
    -- Patterns to detect different version formats
    local patterns = {
        {pattern = "%-(%d+)%.", separator = "-"},  -- -1, -01, -001
        {pattern = "_(%d+)%.", separator = "_"},   -- _1, _01, _001
        {pattern = " (%d+)%.", separator = " "}    -- space 1, space 01, space 001
    }
    
    for _, pat in ipairs(patterns) do
        local numStr = baseName:match(pat.pattern)
        if numStr then
            hasNumber = true
            currentNum = tonumber(numStr)
            separator = pat.separator
            prefix = baseName:match("(.+)" .. separator .. "%d+")
            
            if prefix and currentNum then
                -- Preserve zero-padding (ex: 001 -> 002)
                local formatStr = string.format("%%0%dd", #numStr)
                local nextNum = string.format(formatStr, currentNum + 1)
                
                -- Create path for next file
                local nextFile = string.format("%s%s%s.%s", prefix, separator, nextNum, extension)
                local fullPath = directory .. "/" .. nextFile
                
                -- Check if file exists
                local file = io.open(fullPath, "r")
                if file then
                    file:close()
                    return fullPath
                end
            end
            
            break -- Exit loop once a pattern is found
        end
    end
    
    -- If file doesn't have numbering, look for version 01
    if not hasNumber then
        -- Try different numbering formats to find "01" version
        local potential_next_files = {
            directory .. "/" .. nameWithoutExt .. "-01." .. extension,
            directory .. "/" .. nameWithoutExt .. "-1." .. extension,
            directory .. "/" .. nameWithoutExt .. "_01." .. extension,
            directory .. "/" .. nameWithoutExt .. "_1." .. extension,
            directory .. "/" .. nameWithoutExt .. " 01." .. extension,
            directory .. "/" .. nameWithoutExt .. " 1." .. extension
        }
        
        for _, path in ipairs(potential_next_files) do
            local file = io.open(path, "r")
            if file then
                file:close()
                return path
            end
        end
    end
    
    return nil
end

-- Function to safely get the source length
function getSafeSourceLength(filePath)
    if not filePath then return 0, false end
    
    local source_length = 0
    local temp_source = r.PCM_Source_CreateFromFile(filePath)
    
    -- Add to temp sources list for cleanup
    table.insert(temp_sources, temp_source)
    
    if temp_source then
        source_length, lengthIsQN = r.GetMediaSourceLength(temp_source)
        if lengthIsQN then
            -- Convert MIDI length to time
            local tempo = r.Master_GetTempo()
            source_length = source_length * 60 / tempo
        end
    end
    
    return source_length, lengthIsQN
end

-- Main function to update selected items to next version
function updateItemsToNextVersion()
    local selected_items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(selected_items, r.GetSelectedMediaItem(0, i))
    end
    
    if #selected_items == 0 then
        r.ShowMessageBox("No items selected.", "Update Media Source", 0)
        return
    end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    -- Clear any existing temporary sources
    cleanupTempSources()
    
    for _, item in ipairs(selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            -- Find next file
            local nextFile = findNextFile(currentFile)
            if nextFile then
                -- Get source length if needed
                local source_length = getSafeSourceLength(nextFile)
                
                -- Create new source and set it
                local oldSource = r.GetMediaItemTake_Source(take)
                local newSource = r.PCM_Source_CreateFromFile(nextFile)
                
                if r.SetMediaItemTake_Source(take, newSource) then
                    -- Safely destroy the old source if possible
                    if oldSource and r.PCM_Source_Destroy then
                        r.PCM_Source_Destroy(oldSource)
                    end
                    
                    -- Adjust item length 
                    if source_length > 0 then
                        r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                    end
                    
                    r.UpdateItemInProject(item)
                    r.SetMediaItemSelected(item, true)
                    updatedCount = updatedCount + 1
                else
                    -- If setting source failed, destroy the new source we created
                    if newSource and r.PCM_Source_Destroy then
                        r.PCM_Source_Destroy(newSource)
                    end
                    errorCount = errorCount + 1
                end
            else
                errorCount = errorCount + 1
            end
        end
    end
    
    -- Force build peaks for all selected items
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0) -- Build peaks for selected items
    end
    
    -- Clean up any remaining temporary sources
    cleanupTempSources()
    
    r.Undo_EndBlock("Update media sources to next version", -1)
    
    -- Show results
    local message = string.format("Updated %d items to next version.\n%d errors occurred.", updatedCount, errorCount)
    if errorCount > 0 then
        message = message .. "\n\nPossible causes:\n- No next version exists\n- File permissions issue\n- Source file in use by another process"
    end
    
    r.ShowMessageBox(message, "Update Media Source", 0)
end

-- Run the script
updateItemsToNextVersion()









