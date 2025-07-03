-- @description UpdateMediaSource Rename
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

-- Create ImGui context for dialog
local ctx = r.ImGui_CreateContext('Rename Media Sources')
local WINDOW_FLAGS = r.ImGui_WindowFlags_AlwaysAutoResize() | r.ImGui_WindowFlags_NoCollapse()

-- Configuration
local config = {
    rename_mode = 1, -- 1 = rename original file, 2 = create copy
    rename_only_filename = true,  -- Don't add take name path components
    sanitize_filenames = true,    -- Replace invalid characters
    window_position_set = false,
    result_message = "",
    operation_complete = false,
    debug_info = "" -- For troubleshooting
}

-- Function to sanitize filename (remove invalid characters)
function sanitizeFilename(name)
    if not config.sanitize_filenames then
        return name
    end
    
    -- Replace invalid characters with underscores
    local sanitized = name:gsub("[\\/:*?\"<>|]", "_")
    -- Remove leading/trailing spaces and dots
    sanitized = sanitized:match("^%s*(.-)%s*$")
    return sanitized
end

-- Function to copy a file using basic I/O - platform-independent
function copyFile(sourcePath, destPath)
    local sourceFile = io.open(sourcePath, "rb")
    if not sourceFile then
        return false, "Could not open source file"
    end
    
    local destFile = io.open(destPath, "wb")
    if not destFile then
        sourceFile:close()
        return false, "Could not create destination file"
    end
    
    local content = sourceFile:read("*all")
    destFile:write(content)
    
    sourceFile:close()
    destFile:close()
    
    return true, ""
end

-- Function to move/rename a file
function moveFile(sourcePath, destPath)
    -- Try to use a direct method first for Windows-specific paths
    local isWindows = package.config:sub(1,1) == '\\'
    if isWindows then
        -- Escape paths for command line
        local src = sourcePath:gsub('/', '\\'):gsub('"', '\\"')
        local dst = destPath:gsub('/', '\\'):gsub('"', '\\"')
        
        -- Use the Windows MOVE command
        -- Redirecting stderr to nul suppresses error messages
        local cmd = 'MOVE /Y "' .. src .. '" "' .. dst .. '" 2>nul'
        config.debug_info = config.debug_info .. "\nUsing Windows MOVE: " .. cmd
        
        local result = os.execute(cmd)
        if result then
            config.debug_info = config.debug_info .. "\nMOVE command succeeded"
            return true, ""
        end
        
        config.debug_info = config.debug_info .. "\nMOVE command failed, trying Lua rename"
    end
    
    -- Try standard Lua rename (works on most platforms)
    local success = os.rename(sourcePath, destPath)
    if success then
        config.debug_info = config.debug_info .. "\nRenamed with os.rename"
        return true, ""
    else
        config.debug_info = config.debug_info .. "\nos.rename failed"
    end
    
    -- Last resort: copy and delete
    config.debug_info = config.debug_info .. "\nTrying copy+delete method"
    local copySuccess, copyError = copyFile(sourcePath, destPath)
    if not copySuccess then
        return false, copyError
    end
    
    -- Try to delete the original after successful copy
    os.remove(sourcePath)
    
    -- Check if original still exists
    local originalExists = io.open(sourcePath, "r") ~= nil
    if originalExists then
        config.debug_info = config.debug_info .. "\nWarning: Could not delete original file"
        return true, "Warning: Created copy but couldn't remove the original file"
    else
        config.debug_info = config.debug_info .. "\nSuccessfully deleted original after copy"
        return true, ""
    end
end

-- Function to get item source info
function getItemSourceInfo()
    local selected_items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(selected_items, r.GetSelectedMediaItem(0, i))
    end
    
    if #selected_items == 0 then
        return {}, "No items selected."
    end
    
    local itemSourceInfo = {}
    
    for _, item in ipairs(selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            if source ~= nil then
                local currentFile = r.GetMediaSourceFileName(source)
                local directory = currentFile:match("(.+)[/\\]")
                local baseName = currentFile:match("([^/\\]+)$")
                local extension = baseName:match("%.([^%.]+)$")
                
                if directory and extension then
                    -- Store all the info we need
                    table.insert(itemSourceInfo, {
                        item = item,
                        take = take,
                        filePath = currentFile,
                        directory = directory,
                        baseName = baseName,
                        extension = extension,
                        takeName = r.GetTakeName(take)
                    })
                end
            end
        end
    end
    
    if #itemSourceInfo == 0 then
        return {}, "No valid media items with sources found."
    end
    
    return itemSourceInfo, ""
end

-- Function that does the actual renaming
function performRenameOperation()
    -- Get source info for all selected items
    local itemSourceInfo, errorMsg = getItemSourceInfo()
    
    if #itemSourceInfo == 0 then
        config.result_message = errorMsg
        config.operation_complete = true
        return 0, 0
    end
    
    local updatedCount = 0
    local errorCount = 0
    local errorDetails = {}
    
    r.Undo_BeginBlock()
    
    -- Force refresh of the media file list to ensure no file locks
    r.Main_OnCommand(40047, 0) -- Media item: Clear active take source
    
    -- Add to our debug output
    config.debug_info = string.format("Operation mode: %s\nSelected items: %d", 
        config.rename_mode == 1 and "Rename Original" or "Create Copy", #itemSourceInfo)
    
    -- Process each item
    for i, info in ipairs(itemSourceInfo) do
        local takeName = info.takeName
        local sanitizedName = config.sanitize_filenames and sanitizeFilename(takeName) or takeName
        
        -- Create new filename
        local newFilename = sanitizedName .. "." .. info.extension
        local newFilePath = info.directory .. "/" .. newFilename
        
        -- Check if the new file already exists and it's not the same as the current file
        local fileExists = io.open(newFilePath, "r") ~= nil
        local isSameFile = newFilePath:lower() == info.filePath:lower()
        
        if fileExists and not isSameFile then
            -- If file exists, add a counter to make it unique
            local counter = 1
            repeat
                newFilename = sanitizedName .. "_" .. counter .. "." .. info.extension
                newFilePath = info.directory .. "/" .. newFilename
                fileExists = io.open(newFilePath, "r") ~= nil
                isSameFile = newFilePath:lower() == info.filePath:lower()
                counter = counter + 1
            until not fileExists or isSameFile
        end
        
        -- Skip if the file would have the same name
        if isSameFile then
            -- Already has the correct name, consider it a success
            updatedCount = updatedCount + 1
            goto continue
        end
        
        -- Debug output
        config.debug_info = config.debug_info .. string.format("\n[%d] Processing: %s -> %s", 
            i, info.filePath, newFilePath)
        
        -- Either rename the file or copy it based on mode
        local success, errorMsg
        
        if config.rename_mode == 1 then
            -- Rename/move the original file
            success, errorMsg = moveFile(info.filePath, newFilePath)
        else
            -- Create a copy
            success, errorMsg = copyFile(info.filePath, newFilePath)
        end
        
        if success then
            -- Create new source for the item
            local newSource = r.PCM_Source_CreateFromFile(newFilePath)
            
            if newSource then
                -- Get the take and set the new source
                local take = r.GetActiveTake(info.item)
                if take and r.SetMediaItemTake_Source(take, newSource) then
                    -- Update the item
                    r.UpdateItemInProject(info.item)
                    r.SetMediaItemSelected(info.item, true)
                    updatedCount = updatedCount + 1
                    
                    -- If there was a warning in the errorMsg, log it
                    if errorMsg and errorMsg:match("^Warning") then
                        table.insert(errorDetails, errorMsg .. " for " .. takeName)
                    end
                else
                    errorCount = errorCount + 1
                    table.insert(errorDetails, "Failed to set source for " .. takeName)
                    
                    -- If we renamed (not copied) and failed to set the source, try to rename back
                    if config.rename_mode == 1 then
                        moveFile(newFilePath, info.filePath)
                    end
                end
            else
                errorCount = errorCount + 1
                table.insert(errorDetails, "Failed to create new source for " .. takeName)
                
                -- If we renamed (not copied) and failed to create a source, try to rename back
                if config.rename_mode == 1 then
                    moveFile(newFilePath, info.filePath)
                end
            end
        else
            errorCount = errorCount + 1
            table.insert(errorDetails, errorMsg .. " for " .. takeName)
        end
        
        ::continue::
    end
    
    -- Force build peaks for all selected items
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0) -- Build peaks for selected items
    end
    
    local actionName = config.rename_mode == 1 and "Rename media sources" or "Copy media sources"
    r.Undo_EndBlock(actionName .. " to take names", -1)
    
    -- Create result message
    local message = string.format("%s %d source files based on take names.\n%d errors occurred.", 
        config.rename_mode == 1 and "Renamed" or "Copied", updatedCount, errorCount)
        
    if errorCount > 0 and #errorDetails > 0 then
        message = message .. "\n\nError details:"
        for i = 1, math.min(5, #errorDetails) do  -- Show up to 5 errors
            message = message .. "\n- " .. errorDetails[i]
        end
        if #errorDetails > 5 then
            message = message .. "\n- ... and " .. (#errorDetails - 5) .. " more errors"
        end
    end
    
    config.result_message = message
    config.operation_complete = true
    
    return updatedCount, errorCount
end

-- Main GUI loop
function MainLoop()
    -- Set window position
    if not config.window_position_set then
        r.ImGui_SetNextWindowSize(ctx, 400, 200)
        r.ImGui_SetNextWindowPos(ctx, 200, 200, r.ImGui_Cond_Appearing())
        config.window_position_set = true
    end
    
    local visible, open = r.ImGui_Begin(ctx, 'Rename Media Sources', true, WINDOW_FLAGS)
    
    if visible then
        r.ImGui_Text(ctx, "This script will rename source files based on item/take names.")
        r.ImGui_Separator(ctx)
        
        -- Rename mode selection - using compatible RadioButton format
        r.ImGui_Text(ctx, "Operation mode:")
        
        -- First radio button (rename original)
        local clicked = r.ImGui_RadioButton(ctx, "Rename original files", config.rename_mode == 1)
        if clicked then
            config.rename_mode = 1
        end
        
        r.ImGui_SameLine(ctx)
        
        -- Second radio button (create copies)
        clicked = r.ImGui_RadioButton(ctx, "Create copies", config.rename_mode == 2)
        if clicked then
            config.rename_mode = 2
        end
        
        -- Option for sanitizing filenames
        local changed
        changed, config.sanitize_filenames = r.ImGui_Checkbox(ctx, "Replace invalid characters", config.sanitize_filenames)
        
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "Replaces characters not allowed in filenames like: \\ / : * ? \" < > |")
            r.ImGui_EndTooltip(ctx)
        end
        
        r.ImGui_Separator(ctx)
        
        -- Action buttons
        if r.ImGui_Button(ctx, "Rename Sources", 120, 30) then
            performRenameOperation()
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Cancel", 80, 30) then
            open = false
        end
        
        -- Status message
        if config.result_message ~= "" then
            r.ImGui_Separator(ctx)
            r.ImGui_TextWrapped(ctx, config.result_message)
            
            -- Debug info checkbox
            local show_debug = false
            show_debug, _ = r.ImGui_Checkbox(ctx, "Show debug info", false)
            
            if show_debug and config.debug_info ~= "" then
                r.ImGui_BeginChild(ctx, "DebugInfo", 380, 100, true)
                r.ImGui_TextWrapped(ctx, config.debug_info)
                r.ImGui_EndChild(ctx)
            end
            
            if config.operation_complete then
                r.ImGui_Separator(ctx)
                if r.ImGui_Button(ctx, "Close", 100, 25) then
                    open = false
                end
            end
        end
        
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(MainLoop)
    else
        r.ImGui_DestroyContext(ctx)
    end
end

-- Start the GUI
MainLoop()









