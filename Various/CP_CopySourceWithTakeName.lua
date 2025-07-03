-- @description CopySourceWithTakeName
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

-- Function to sanitize filename (remove invalid characters)
function sanitizeFilename(name)
    local sanitized = name:gsub("[\\/:*?\"<>|]", "_")
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

-- Main function
function CopySourcesWithTakeName()
    r.Undo_BeginBlock()
    
    local selected_items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(selected_items, r.GetSelectedMediaItem(0, i))
    end
    
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
                local sanitizedName = sanitizeFilename(takeName)
                
                -- Create new filename
                local newFilename = sanitizedName .. "." .. extension
                local newFilePath = directory .. "/" .. newFilename
                
                -- Check if the new file already exists
                local fileExists = io.open(newFilePath, "r") ~= nil
                
                if fileExists then
                    -- If file exists, add a counter to make it unique
                    local counter = 1
                    repeat
                        newFilename = sanitizedName .. "_" .. counter .. "." .. extension
                        newFilePath = directory .. "/" .. newFilename
                        fileExists = io.open(newFilePath, "r") ~= nil
                        counter = counter + 1
                    until not fileExists
                end
                
                -- Copy the file
                if copyFile(currentFile, newFilePath) then
                    -- Create new source for the item
                    local newSource = r.PCM_Source_CreateFromFile(newFilePath)
                    
                    if newSource then
                        -- Set the new source to the take
                        r.SetMediaItemTake_Source(take, newSource)
                        r.UpdateItemInProject(item)
                    end
                end
            end
        end
    end
    
    -- Force build peaks for all selected items
    r.Main_OnCommand(40441, 0) -- Build peaks for selected items
    
    r.Undo_EndBlock("Copy media sources with take names", -1)
end

-- Run the script
CopySourcesWithTakeName()









