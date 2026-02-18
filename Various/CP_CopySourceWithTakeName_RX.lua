-- @description CopySourceWithTakeName RX
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

-- Function to sanitize filename (remove invalid characters)
function sanitizeFilename(name)
    -- Remove extension if present in the name
    local nameWithoutExt = name:match("^(.+)%.[^%.]+$") or name
    
    local sanitized = nameWithoutExt:gsub("[\\/:*?\"<>|]", "_")
    -- Remove leading/trailing spaces
    sanitized = sanitized:match("^%s*(.-)%s*$")
    return sanitized
end

-- Function to copy a file
function copyFile(sourcePath, destPath)
    local sourceFile = io.open(sourcePath, "rb")
    if not sourceFile then return false end
    
    local destFile = io.open(destPath, "wb")
    if not destFile then 
        sourceFile:close()
        return false 
    end
    
    local content = sourceFile:read("*all")
    destFile:write(content)
    
    sourceFile:close()
    destFile:close()
    
    return true
end

-- Function to remove file extension from name
function removeExtension(name)
    return name:match("^(.+)%.[^%.]+$") or name
end

-- Main function
function CopySourcesWithTakeNameRX()
    r.Undo_BeginBlock()
    
    local selected_items = {}
    -- Store the original selected items to restore selection later
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        table.insert(selected_items, item)
    end
    
    local last_processed_item = nil
    
    for _, item in ipairs(selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            local directory = currentFile:match("(.+)[/\\]")
            local extension = currentFile:match("%.([^%.]+)$")
            
            if directory and extension then
                -- Get take name to use as new filename
                local takeName = r.GetTakeName(take)
                local takeName_noExt = removeExtension(takeName)
                local sanitizedName = sanitizeFilename(takeName)
                
                -- Create new filename with _RX suffix
                local newFilename = sanitizedName .. "_RX." .. extension
                local newFilePath = directory .. "/" .. newFilename
                
                -- Check if the new file already exists
                local fileExists = io.open(newFilePath, "r") ~= nil
                if fileExists then
                    -- If file exists, add a counter to make it unique
                    local counter = 1
                    repeat
                        newFilename = sanitizedName .. "_RX_" .. counter .. "." .. extension
                        newFilePath = directory .. "/" .. newFilename
                        fileExists = io.open(newFilePath, "r") ~= nil
                        counter = counter + 1
                    until not fileExists
                end
                
                -- Copy the file
                if copyFile(currentFile, newFilePath) then
                    -- Add a new take to the item
                    local newTake = r.AddTakeToMediaItem(item)
                    
                    if newTake then
                        -- Create new source for the take
                        local newSource = r.PCM_Source_CreateFromFile(newFilePath)
                        
                        if newSource then
                            -- Set the new source to the take
                            r.SetMediaItemTake_Source(newTake, newSource)
                            
                            -- Set the take name to include _RX without extension
                            r.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", takeName_noExt .. "_RX", true)
                            
                            -- Make the new take active
                            r.SetActiveTake(newTake)
                            
                            -- Update the item
                            r.UpdateItemInProject(item)
                            
                            -- Track the last processed item
                            last_processed_item = item
                            
                            -- To help prevent file locking, explicitly destroy source references
                            collectgarbage()
                        end
                    end
                end
            end
        end
    end
    
    -- Force build peaks for all selected items
    r.Main_OnCommand(40441, 0) -- Build peaks for selected items
    
    -- Force REAPER to release any file handles by clearing selection
    r.Main_OnCommand(40769, 0) -- Unselect all items (correct command ID)
    
    -- Restore original selection
    for _, item in ipairs(selected_items) do
        r.SetMediaItemSelected(item, true)
    end
    
    -- Make sure last processed item is visible
    if last_processed_item then
        r.SetMediaItemSelected(last_processed_item, true)
        r.Main_OnCommand(40913, 0) -- Vertical scroll to selected items
    end
    
    -- Open in external editor
    r.Main_OnCommand(40109, 0) -- Open items in primary external editor

    r.Main_OnCommand(40769, 0) -- Unselect all items (correct command ID)
    
    r.Undo_EndBlock("Copy source and create new take with _RX", -1)
end

-- Run the script
CopySourcesWithTakeNameRX()









