-- @description SourceManager
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

local sl = nil
local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp) then local lf = dofile(sp) if lf then sl = lf() end end

local script_id = "CP_SourceManager_Instance"
if _G[script_id] then
    _G[script_id] = false
    return
end
_G[script_id] = true

local ctx = r.ImGui_CreateContext('Source Manager')
local pc, pv = 0, 0

if sl then sl.applyFontsToContext(ctx) end

function getFont(font_name)
    if sl then return sl.getFont(ctx, font_name) end
    return nil
end

local WINDOW_FLAGS = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoCollapse() 

local config = {
    selected_items = {},
    common_directory = "",
    reference_files = {},
    available_media = {},
    current_project_version = nil,
    window_position_set = false,
    status_message = "",
    multiple_directories = false,
    search_query = "",
    filtered_media = {},
    adjust_item_size = true,
    rename_buffer = ""
}

local temp_sources = {}

function safelyDestroySource(source)
    if source then
        if r.PCM_Source_Destroy then
            r.PCM_Source_Destroy(source)
        end
    end
end

function cleanupTempSources()
    for i, source in ipairs(temp_sources) do
        safelyDestroySource(source)
    end
    temp_sources = {}
end

function findNextFile(currentFile)
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    local nameWithoutExt = baseName:match("(.+)%.")
    if not nameWithoutExt then return nil end
    
    local hasNumber = false
    local prefix, currentNum, separator
    
    local patterns = {
        {pattern = "%-(%d+)%.", separator = "-"},
        {pattern = "_(%d+)%.", separator = "_"},
        {pattern = " (%d+)%.", separator = " "}
    }
    
    for _, pat in ipairs(patterns) do
        local numStr = baseName:match(pat.pattern)
        if numStr then
            hasNumber = true
            currentNum = tonumber(numStr)
            separator = pat.separator
            prefix = baseName:match("(.+)" .. separator .. "%d+")
            
            if prefix and currentNum then
                local formatStr = string.format("%%0%dd", #numStr)
                local nextNum = string.format(formatStr, currentNum + 1)
                
                local nextFile = string.format("%s%s%s.%s", prefix, separator, nextNum, extension)
                local fullPath = directory .. "/" .. nextFile
                
                local file = io.open(fullPath, "r")
                if file then
                    file:close()
                    return fullPath
                end
            end
            
            break
        end
    end
    
    if not hasNumber then
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

function findPreviousFile(currentFile)
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    local patterns = {
        {pattern = "%-(%d+)%.", separator = "-"},
        {pattern = "_(%d+)%.", separator = "_"},
        {pattern = " (%d+)%.", separator = " "}
    }
    
    for _, pat in ipairs(patterns) do
        local numStr = baseName:match(pat.pattern)
        if numStr then
            local currentNum = tonumber(numStr)
            local prefix = baseName:match("(.+)" .. pat.separator .. "%d+")
            
            if prefix and currentNum then
                if currentNum > 1 then
                    local formatStr = string.format("%%0%dd", #numStr)
                    local prevNum = string.format(formatStr, currentNum - 1)
                    
                    local prevFile = string.format("%s%s%s.%s", prefix, pat.separator, prevNum, extension)
                    local fullPath = directory .. "/" .. prevFile
                    
                    local file = io.open(fullPath, "r")
                    if file then
                        file:close()
                        return fullPath
                    end
                elseif currentNum == 1 then
                    local baseFile = string.format("%s.%s", prefix, extension)
                    local fullPath = directory .. "/" .. baseFile
                    
                    local file = io.open(fullPath, "r")
                    if file then
                        file:close()
                        return fullPath
                    end
                end
            end
        end
    end
    
    return nil
end

function getProjectVersion()
    local _, projectPath = r.EnumProjects(-1)
    if not projectPath then return nil end
    
    local filename = projectPath:match("([^/\\]+)%.RPP$") or projectPath:match("([^/\\]+)%.rpp$")
    if not filename then return nil end
    
    local version = filename:match("_(%d+)")
    return tonumber(version)
end

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

function getCommonDirectoryAndReferenceFiles()
    if #config.selected_items == 0 then return nil, {}, false end
    
    local directories = {}
    local reference_files = {}
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local filepath = r.GetMediaSourceFileName(source)
            table.insert(reference_files, filepath)
            
            local directory = filepath:match("(.+)[/\\]")
            if directory then
                directories[directory] = (directories[directory] or 0) + 1
            end
        end
    end
    
    local common_dir = nil
    local multiple_dirs = false
    
    local dir_count = 0
    for dir, count in pairs(directories) do
        dir_count = dir_count + 1
        if not common_dir or count > directories[common_dir] then
            common_dir = dir
        end
    end
    
    if dir_count > 1 then
        multiple_dirs = true
    end
    
    return common_dir, reference_files, multiple_dirs
end

function filterMedia(media_list, query)
    if not query or query == "" then
        return media_list
    end
    
    local filtered = {}
    query = query:lower()
    
    for _, media in ipairs(media_list) do
        if media.name:lower():find(query, 1, true) then
            table.insert(filtered, media)
        end
    end
    
    return filtered
end

function scanAvailableMedia(directory)
    if not directory then return {} end
    
    local media_files = {}
    local supported_extensions = {
        ["wav"] = true, ["mp3"] = true, ["ogg"] = true, ["flac"] = true, 
        ["aif"] = true, ["aiff"] = true, ["m4a"] = true, ["wav64"] = true,
        ["mp4"] = true, ["mov"] = true, ["avi"] = true, ["mkv"] = true,
        ["rpp"] = true
    }
    
    local files = {}
    local i = 0
    repeat
        local fileName = r.EnumerateFiles(directory, i)
        if fileName then
            table.insert(files, fileName)
        end
        i = i + 1
    until not fileName
    
    for _, fileName in ipairs(files) do
        local extension = fileName:match("%.([^%.]+)$")
        if extension and supported_extensions[extension:lower()] then
            table.insert(media_files, {
                name = fileName,
                path = directory .. "/" .. fileName,
                extension = extension:lower()
            })
        end
    end
    
    table.sort(media_files, function(a, b) return a.name < b.name end)
    
    return media_files
end

function getFilenameFromPath(path)
    if not path then return "" end
    return path:match("([^/\\]+)$") or path
end

function getSafeSourceLength(filePath)
    if not filePath then return 0, false end
    
    local source_length = 0
    local temp_source = r.PCM_Source_CreateFromFile(filePath)
    
    table.insert(temp_sources, temp_source)
    
    if temp_source then
        source_length, lengthIsQN = r.GetMediaSourceLength(temp_source)
        if lengthIsQN then
            local tempo = r.Master_GetTempo()
            source_length = source_length * 60 / tempo
        end
    end
    
    return source_length, lengthIsQN
end

function updateItemsToPreviousVersion()
    if #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    cleanupTempSources()
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            local prevFile = findPreviousFile(currentFile)
            if prevFile then
                local source_length = 0
                if config.adjust_item_size then
                    source_length = getSafeSourceLength(prevFile)
                end
                
                local oldSource = r.GetMediaItemTake_Source(take)
                local newSource = r.PCM_Source_CreateFromFile(prevFile)
                
                if r.SetMediaItemTake_Source(take, newSource) then
                    if oldSource and r.PCM_Source_Destroy then
                        r.PCM_Source_Destroy(oldSource)
                    end
                    
                    if config.adjust_item_size and source_length > 0 then
                        r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                    end
                    
                    r.UpdateItemInProject(item)
                    r.SetMediaItemSelected(item, true)
                    updatedCount = updatedCount + 1
                else
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
    
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0)
    end
    
    cleanupTempSources()
    
    r.Undo_EndBlock("Update media sources to previous version", -1)
    
    return updatedCount, errorCount
end

function updateItemsToNextVersion()
    if #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    cleanupTempSources()
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            local nextFile = findNextFile(currentFile)
            if nextFile then
                local source_length = 0
                if config.adjust_item_size then
                    source_length = getSafeSourceLength(nextFile)
                end
                
                local oldSource = r.GetMediaItemTake_Source(take)
                local newSource = r.PCM_Source_CreateFromFile(nextFile)
                
                if r.SetMediaItemTake_Source(take, newSource) then
                    if oldSource and r.PCM_Source_Destroy then
                        r.PCM_Source_Destroy(oldSource)
                    end
                    
                    if config.adjust_item_size and source_length > 0 then
                        r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                    end
                    
                    r.UpdateItemInProject(item)
                    r.SetMediaItemSelected(item, true)
                    updatedCount = updatedCount + 1
                else
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
    
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0)
    end
    
    cleanupTempSources()
    
    r.Undo_EndBlock("Update media sources to next version", -1)
    
    return updatedCount, errorCount
end

function syncWithProjectVersion()
    local version = getProjectVersion()
    if not version then return 0, 0 end
    
    if #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    cleanupTempSources()
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            local versionedFile = constructVersionedFile(currentFile, version)
            if versionedFile then
                local file = io.open(versionedFile, "r")
                if file then
                    file:close()
                    
                    local source_length = 0
                    if config.adjust_item_size then
                        source_length = getSafeSourceLength(versionedFile)
                    end
                    
                    local oldSource = r.GetMediaItemTake_Source(take)
                    local newSource = r.PCM_Source_CreateFromFile(versionedFile)
                    
                    if r.SetMediaItemTake_Source(take, newSource) then
                        if oldSource and r.PCM_Source_Destroy then
                            r.PCM_Source_Destroy(oldSource)
                        end
                        
                        if config.adjust_item_size and source_length > 0 then
                            r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                        end
                        
                        r.UpdateItemInProject(item)
                        r.SetMediaItemSelected(item, true)
                        updatedCount = updatedCount + 1
                    else
                        if newSource and r.PCM_Source_Destroy then
                            r.PCM_Source_Destroy(newSource)
                        end
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
    
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0)
    end
    
    cleanupTempSources()
    
    r.Undo_EndBlock("Sync media sources to project version", -1)
    
    return updatedCount, errorCount
end

function updateToMediaFile(mediaPath)
    if not mediaPath or #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    cleanupTempSources()
    
    local source_length = 0
    if config.adjust_item_size then
        source_length = getSafeSourceLength(mediaPath)
    end
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local oldSource = r.GetMediaItemTake_Source(take)
            
            local newSource = r.PCM_Source_CreateFromFile(mediaPath)
            
            if newSource and r.SetMediaItemTake_Source(take, newSource) then
                if oldSource and r.PCM_Source_Destroy then
                    r.PCM_Source_Destroy(oldSource)
                end
                
                if config.adjust_item_size and source_length > 0 then
                    r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                end
                
                r.UpdateItemInProject(item)
                updatedCount = updatedCount + 1
                
                r.SetMediaItemSelected(item, true)
            else
                if newSource and r.PCM_Source_Destroy then
                    r.PCM_Source_Destroy(newSource)
                end
                errorCount = errorCount + 1
            end
        end
    end
    
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0)
    end
    
    cleanupTempSources()
    
    r.Undo_EndBlock("Update media sources to " .. getFilenameFromPath(mediaPath), -1)
    
    return updatedCount, errorCount
end

function sanitizeFilename(name)
    local sanitized = name:gsub("[\\/:*?\"<>|]", "_")
    sanitized = sanitized:match("^%s*(.-)%s*$")
    return sanitized
end

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

function renameSourceFiles()
    if #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    cleanupTempSources()
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            local directory = currentFile:match("(.+)[/\\]")
            local extension = currentFile:match("%.([^%.]+)$")
            
            if directory and extension then
                local takeName = r.GetTakeName(take)
                
                local sanitizedName = sanitizeFilename(takeName)
                
                local newFilename = sanitizedName .. "." .. extension
                local newFilePath = directory .. "/" .. newFilename
                
                local fileExists = io.open(newFilePath, "r") ~= nil
                if fileExists then
                    local counter = 1
                    repeat
                        newFilename = sanitizedName .. "_" .. counter .. "." .. extension
                        newFilePath = directory .. "/" .. newFilename
                        fileExists = io.open(newFilePath, "r") ~= nil
                        counter = counter + 1
                    until not fileExists
                end
                
                local success, errorMsg = copyFile(currentFile, newFilePath)
                
                if success then
                    local source_length = 0
                    if config.adjust_item_size then
                        source_length = getSafeSourceLength(newFilePath)
                    end
                    
                    local oldSource = r.GetMediaItemTake_Source(take)
                    local newSource = r.PCM_Source_CreateFromFile(newFilePath)
                    
                    if r.SetMediaItemTake_Source(take, newSource) then
                        if oldSource and r.PCM_Source_Destroy then
                            r.PCM_Source_Destroy(oldSource)
                        end
                        
                        if config.adjust_item_size and source_length > 0 then
                            r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                        end
                        
                        r.UpdateItemInProject(item)
                        r.SetMediaItemSelected(item, true)
                        updatedCount = updatedCount + 1
                    else
                        if newSource and r.PCM_Source_Destroy then
                            r.PCM_Source_Destroy(newSource)
                        end
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
    
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0)
        
        config.common_directory, config.reference_files, config.multiple_directories = getCommonDirectoryAndReferenceFiles()
        if config.common_directory then
            config.available_media = scanAvailableMedia(config.common_directory)
            config.filtered_media = filterMedia(config.available_media, config.search_query)
        end
    end
    
    cleanupTempSources()
    
    r.Undo_EndBlock("Rename media sources to take names", -1)
    
    return updatedCount, errorCount
end

function MainLoop()
    if not _G[script_id] then return end
    if sl then
        local success, colors, vars = sl.applyToContext(ctx)
        if success then pc, pv = colors, vars end
    end

    local header_font = getFont("header")
    local main_font = getFont("main")

    if main_font then r.ImGui_PushFont(ctx, main_font) end

    if not config.window_position_set then
        r.ImGui_SetNextWindowSize(ctx, 600, 500)
        config.window_position_set = true
    end
    
    local visible, open = r.ImGui_Begin(ctx, 'Source Manager', true, WINDOW_FLAGS)
    
    if visible then
        if header_font then r.ImGui_PushFont(ctx, header_font) end
        r.ImGui_Text(ctx, "Source Manager")
        if header_font then r.ImGui_PopFont(ctx) end
        -- if main_font then r.ImGui_PushFont(ctx, main_font) end

        r.ImGui_SameLine(ctx)
        local close_x = r.ImGui_GetWindowWidth(ctx) - 30
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", 22, 22) then
            open = false
        end
        r.ImGui_Separator(ctx)
        local selected_items = {}
        for i = 0, r.CountSelectedMediaItems(0) - 1 do
            table.insert(selected_items, r.GetSelectedMediaItem(0, i))
        end
        
        local selection_changed = false
        if #selected_items ~= #config.selected_items then
            selection_changed = true
        else
            for i, item in ipairs(selected_items) do
                if item ~= config.selected_items[i] then
                    selection_changed = true
                    break
                end
            end
        end
        
        if selection_changed then
            config.selected_items = selected_items
            config.common_directory, config.reference_files, config.multiple_directories = getCommonDirectoryAndReferenceFiles()
            if config.common_directory then
                config.available_media = scanAvailableMedia(config.common_directory)
                config.filtered_media = filterMedia(config.available_media, config.search_query)
            else
                config.available_media = {}
                config.filtered_media = {}
            end
        end
        
        r.ImGui_Text(ctx, string.format("Selected items: %d", #config.selected_items))
        if config.multiple_directories then
            r.ImGui_Text(ctx, "Directory: <multiple directories>")
        elseif config.common_directory then
            r.ImGui_Text(ctx, "Directory: " .. config.common_directory)
        else
            r.ImGui_Text(ctx, "No directory found")
        end
        r.ImGui_Dummy(ctx, 0, 0)
        if #config.selected_items > 0 then
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Selected media sources:")
            
            local list_height = math.min(100, #config.selected_items * 25)
            if #config.selected_items > 1 then
                r.ImGui_BeginChild(ctx, "ItemsList", -1, list_height, 1)
            end
            
            for i, item in ipairs(config.selected_items) do
                local take = r.GetActiveTake(item)
                if take then
                    local source = r.GetMediaItemTake_Source(take)
                    local filePath = r.GetMediaSourceFileName(source)
                    local filename = getFilenameFromPath(filePath)
                    
                    local takeName = r.GetTakeName(take)
                    r.ImGui_Text(ctx, string.format("%d: %s (%s)", i, takeName, filename))
                    
                    if r.ImGui_IsItemHovered(ctx) then
                        r.ImGui_BeginTooltip(ctx)
                        r.ImGui_Text(ctx, filePath)
                        r.ImGui_EndTooltip(ctx)
                    end
                end
            end
            
            if #config.selected_items > 1 then
                r.ImGui_EndChild(ctx)
            end
        end
        
        r.ImGui_Separator(ctx)
        
        r.ImGui_BeginDisabled(ctx, #config.selected_items == 0)
        
        if r.ImGui_Button(ctx, "Previous Version", 150, 30) then
            local updated, errors = updateItemsToPreviousVersion()
            config.status_message = string.format("Updated %d items to previous version, %d errors", updated, errors)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Next Version", 150, 30) then
            local updated, errors = updateItemsToNextVersion()
            config.status_message = string.format("Updated %d items to next version, %d errors", updated, errors)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Rename Source(s)", 150, 30) then
            local updated, errors = renameSourceFiles()
            config.status_message = string.format("Renamed %d source files based on item names, %d errors", updated, errors)
        end
        
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "Creates a copy of each source file with a name matching its take name")
            r.ImGui_EndTooltip(ctx)
        end
        
        r.ImGui_EndDisabled(ctx)
        
        r.ImGui_Separator(ctx)
        
        local adjust_changed
        adjust_changed, config.adjust_item_size = r.ImGui_Checkbox(ctx, "Adjust item size to match source", config.adjust_item_size)
        
        -- r.ImGui_SameLine(ctx)
        
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "When enabled, item length will be adjusted to match the source media length")
            r.ImGui_EndTooltip(ctx)
        end

        -- local project_version = getProjectVersion()
        -- if project_version then
        --     r.ImGui_Text(ctx, string.format("Current project version: %d", project_version))
            
        --     r.ImGui_BeginDisabled(ctx, #config.selected_items == 0)
        --     if r.ImGui_Button(ctx, "Sync with Project Version", 200, 30) then
        --         local updated, errors = syncWithProjectVersion()
        --         config.status_message = string.format("Synced %d items with project version %d, %d errors", 
        --                        updated, project_version, errors)
        --     end
        --     r.ImGui_EndDisabled(ctx)
        -- else
        --     r.ImGui_Text(ctx, "No project version detected")
        -- end
        
        r.ImGui_Separator(ctx)

        r.ImGui_Text(ctx, "Search media files:")
        
        local search_changed
        search_changed, config.search_query = r.ImGui_InputText(ctx, "##search", config.search_query)
        
        if search_changed then
            config.filtered_media = filterMedia(config.available_media, config.search_query)
        elseif selection_changed then
            config.filtered_media = filterMedia(config.available_media, config.search_query)
        end
        
        r.ImGui_Text(ctx, "Available media in directory:")
        
        if not config.multiple_directories and #config.available_media > 0 then
            local display_media = config.search_query ~= "" and config.filtered_media or config.available_media
            
            if r.ImGui_BeginChild(ctx, "MediaList", -1, 240, 1) then
                for i, media in ipairs(display_media) do
                    local is_current = false
                    for _, refFile in ipairs(config.reference_files) do
                        if refFile == media.path then
                            is_current = true
                            break
                        end
                    end
                    
                    if is_current then
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFF00FF)
                    end
                    
                    if r.ImGui_Selectable(ctx, media.name, false) then
                        local updated, errors = updateToMediaFile(media.path)
                        config.status_message = string.format("Updated %d items to %s, %d errors", 
                                       updated, media.name, errors)
                        
                        config.common_directory, config.reference_files, config.multiple_directories = getCommonDirectoryAndReferenceFiles()
                    end
                    
                    if is_current then
                        r.ImGui_PopStyleColor(ctx)
                    end
                    
                    if r.ImGui_IsItemHovered(ctx) then
                        r.ImGui_BeginTooltip(ctx)
                        r.ImGui_Text(ctx, media.path)
                        r.ImGui_EndTooltip(ctx)
                    end
                end
                r.ImGui_EndChild(ctx)
            end
        elseif config.multiple_directories then
            r.ImGui_Text(ctx, "Items from multiple directories selected")
        else
            r.ImGui_Text(ctx, "No media files found")
        end
        
        if config.status_message ~= "" then
            r.ImGui_Separator(ctx)
            r.ImGui_TextWrapped(ctx, config.status_message)
        end
        
        r.ImGui_End(ctx)
    end
    
    if main_font then r.ImGui_PopFont(ctx) end
    
    if sl then sl.clearStyles(ctx, pc, pv) end
    
    if open then
        r.defer(MainLoop)
    else
        cleanupTempSources()
    end
end

function Start()
    MainLoop()
end

function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        Start()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
    end
end

function Exit()
    cleanupTempSources()
    
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()







