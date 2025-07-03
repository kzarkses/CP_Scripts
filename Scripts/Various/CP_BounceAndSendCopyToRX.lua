-- @description BounceAndSendCopyToRX
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

-- Function to sanitize filename (remove invalid characters)
function sanitizeFilename(name)
    local sanitized = name:gsub("[\\/:*?\"<>|]", "_")
    -- Remove leading/trailing spaces
    sanitized = sanitized:match("^%s*(.-)%s*$")
    -- Default name if empty
    if sanitized == "" then sanitized = "Unnamed" end
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

-- Get the render directory path
function getRenderPath()
    local ini_file = r.get_ini_file()
    local path = r.GetProjectPath("") -- Default to project path
    
    -- Try to get the last render path from REAPER's ini
    if ini_file then
        local f = io.open(ini_file, "r")
        if f then
            local content = f:read("*all")
            f:close()
            
            -- Look for the lastrender path in the ini file
            local lastrender = content:match('lastrender=([^\n]+)')
            if lastrender then
                -- Extract just the directory
                local dir = lastrender:match("(.+)[/\\][^/\\]+$")
                if dir then
                    path = dir
                end
            end
        end
    end
    
    return path
end

-- Main function
function BounceItemsWithRXCopy(openInRX)
    r.Undo_BeginBlock()
    
    local renderPath = getRenderPath()
    local rxFiles = {} -- Store _RX files for later opening
    
    -- Get the number of selected items
    local itemCount = r.CountSelectedMediaItems(0)
    
    if itemCount == 0 then
        r.ShowMessageBox("No items selected. Please select items to bounce.", "Bounce with RX Copy", 0)
        return
    end
    
    -- Prepare an array of selected items
    local selected_items = {}
    for i = 0, itemCount - 1 do
        table.insert(selected_items, r.GetSelectedMediaItem(0, i))
    end
    
    -- Process each item
    for i, item in ipairs(selected_items) do
        local take = r.GetActiveTake(item)
        
        if take then
            -- Get take name and item properties
            local takeName = r.GetTakeName(take)
            local sanitizedName = sanitizeFilename(takeName)
            
            -- Get item position and length
            local itemPos = r.GetMediaItemInfo_Value(item, "D_POSITION")
            local itemLen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            local itemEnd = itemPos + itemLen
            
            -- Generate a filename for the bounced file
            local originalFilename = sanitizedName .. ".wav"
            local originalFilePath = renderPath .. "/" .. originalFilename
            
            -- Ensure filename is unique
            local counter = 1
            while r.file_exists(originalFilePath) do
                originalFilename = sanitizedName .. "_" .. counter .. ".wav"
                originalFilePath = renderPath .. "/" .. originalFilename
                counter = counter + 1
            end
            
            -- Generate _RX filename
            local rxFilename = sanitizedName .. "_RX.wav"
            local rxFilePath = renderPath .. "/" .. rxFilename
            
            -- Ensure RX filename is unique
            counter = 1
            while r.file_exists(rxFilePath) do
                rxFilename = sanitizedName .. "_RX_" .. counter .. ".wav"
                rxFilePath = renderPath .. "/" .. rxFilename
                counter = counter + 1
            end
            
            -- Store the original selection state
            r.PreventUIRefresh(1)
            local cursorPos = r.GetCursorPosition()
            local origSelItems = {}
            for j = 0, r.CountSelectedMediaItems(0) - 1 do
                origSelItems[j] = r.GetSelectedMediaItem(0, j)
            end
            
            -- Clear selection and select only the current item
            r.SelectAllMediaItems(0, false) -- Deselect all
            r.SetMediaItemSelected(item, true)
            
            -- Set time selection to match item
            r.GetSet_LoopTimeRange(true, false, itemPos, itemEnd, false)
            
            -- Backup render settings
            local orig_render_bounds = r.GetToggleCommandStateEx(0, 41796) -- Get render bounds setting (time selection, etc.)
            local orig_render_settings = r.GetToggleCommandStateEx(0, 40089) -- Get render settings: Master Mix vs. Selected tracks
            
            -- Set render settings for bouncing
            r.Main_OnCommand(41892, 0) -- Set render bounds: Time selection
            r.Main_OnCommand(40015, 0) -- Set render: Master mix
            
            -- Set render format to WAV
            local render_format_string = "Wave:WAV "
            r.GetSetProjectInfo_String(0, "RENDER_FORMAT", render_format_string, true)
            
            -- Set render directory and base filename
            r.GetSetProjectInfo_String(0, "RENDER_FILE", originalFilePath, true)
            r.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", true) -- Clear pattern to avoid auto-naming
            
            -- Do the render (bounce)
            r.Main_OnCommand(42230, 0) -- Render project, using the most recent render settings, without opening render dialog
            
            -- Create the _RX copy
            if r.file_exists(originalFilePath) then
                copyFile(originalFilePath, rxFilePath)
                
                -- Create a new take with the _RX file
                local newTake = r.AddTakeToMediaItem(item)
                if newTake then
                    local newSource = r.PCM_Source_CreateFromFile(rxFilePath)
                    if newSource then
                        r.SetMediaItemTake_Source(newTake, newSource)
                        r.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", takeName .. "_RX", true)
                        r.SetActiveTake(newTake)
                        table.insert(rxFiles, item) -- Store the item for later RX opening
                    end
                end
                
                -- Set the original file to the original take
                local origSource = r.PCM_Source_CreateFromFile(originalFilePath)
                if origSource then
                    r.SetMediaItemTake_Source(take, origSource)
                    r.UpdateItemInProject(item)
                end
            end
            
            -- Restore original render settings
            if orig_render_bounds == 1 then
                r.Main_OnCommand(41796, 0) -- Restore original render bounds setting
            end
            if orig_render_settings == 1 then
                r.Main_OnCommand(40089, 0) -- Restore original render settings
            end
            
            -- Restore time selection and selection state
            r.GetSet_LoopTimeRange(true, false, 0, 0, false) -- Clear time selection
            r.SetEditCurPos(cursorPos, false, false)
            
            -- Restore selection
            r.SelectAllMediaItems(0, false) -- Deselect all
            for j = 0, #origSelItems do
                if origSelItems[j] then
                    r.SetMediaItemSelected(origSelItems[j], true)
                end
            end
            r.PreventUIRefresh(-1)
        end
    end
    
    -- Rebuild peaks
    r.Main_OnCommand(40441, 0) -- Build peaks for selected items
    
    -- Send to RX if requested
    if openInRX and #rxFiles > 0 then
        -- Select only the RX takes
        r.SelectAllMediaItems(0, false) -- Deselect all
        for _, item in ipairs(rxFiles) do
            local take = r.GetActiveTake(item)
            if take and r.GetTakeName(take):match("_RX") then
                r.SetMediaItemSelected(item, true)
            end
        end
        
        -- Open in RX
        r.Main_OnCommand(40109, 0) -- Open items in primary external editor
    end
    
    r.Undo_EndBlock("Bounce items to take names with RX copies", -1)
end

-- Show dialog to ask if user wants to send to RX
local function main()
    local title = "Bounce to Take Names with RX Copies"
    local message = "Do you want to send the _RX files to iZotope RX after bouncing?\n" ..
                  "(This will use 'Open items in primary external editor')"
    
    local result = r.ShowMessageBox(message, title, 3) -- yes/no/cancel
    
    if result == 2 then -- Cancel
        return
    elseif result == 6 then -- Yes
        BounceItemsWithRXCopy(true)
    elseif result == 7 then -- No
        BounceItemsWithRXCopy(false)
    end
end

-- Run the script
main()










