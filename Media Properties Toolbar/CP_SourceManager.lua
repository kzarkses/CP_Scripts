-- @description SourceManager
-- @version 1.0.2
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_SourceManager"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local script_id = "CP_SourceManager_Instance"
if _G[script_id] then
    _G[script_id] = false
    return
end
_G[script_id] = true

local ctx = r.ImGui_CreateContext('Source Manager')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

function GetFont(font_name)
    if style_loader then
        return style_loader.GetFont(ctx, font_name)
    end
    return nil
end

local header_font_size = GetStyleValue("fonts.header.size", 16)
local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
local window_padding_x = GetStyleValue("spacing.window_padding_x", 6)
local window_padding_y = GetStyleValue("spacing.window_padding_y", 6)

local config = {
    window_position_set = false,
    adjust_item_size = true,
    search_query = ""
}

local state = {
    selected_items = {},
    common_directory = "",
    reference_files = {},
    available_media = {},
    current_project_version = nil,
    status_message = "",
    multiple_directories = false,
    filtered_media = {},
    rename_buffer = ""
}

local temp_sources = {}

function ApplyStyle()
    if style_loader then
        local success, colors, vars = style_loader.ApplyToContext(ctx)
        if success then 
            pushed_colors = colors
            pushed_vars = vars
            return true
        end
    end
    return false
end

function ClearStyle()
    if style_loader then 
        style_loader.ClearStyles(ctx, pushed_colors, pushed_vars)
    end
end

function SaveSettings()
    for key, value in pairs(config) do
        local value_str = tostring(value)
        if type(value) == "boolean" then
            value_str = value and "1" or "0"
        end
        r.SetExtState(script_name, "config_" .. key, value_str, true)
    end
end

function LoadSettings()
    for key, default_value in pairs(config) do
        local saved_value = r.GetExtState(script_name, "config_" .. key)
        if saved_value ~= "" then
            if type(default_value) == "number" then
                config[key] = tonumber(saved_value) or default_value
            elseif type(default_value) == "boolean" then
                config[key] = saved_value == "1"
            else
                config[key] = saved_value
            end
        end
    end
end

function SafelyDestroySource(source)
    if source then
        if r.PCM_Source_Destroy then
            r.PCM_Source_Destroy(source)
        end
    end
end

function CleanupTempSources()
    for i, source in ipairs(temp_sources) do
        SafelyDestroySource(source)
    end
    temp_sources = {}
end

function FindNextFile(currentFile)
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

function FindPreviousFile(currentFile)
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

function GetProjectVersion()
    local _, projectPath = r.EnumProjects(-1)
    if not projectPath then return nil end
    
    local filename = projectPath:match("([^/\\]+)%.RPP$") or projectPath:match("([^/\\]+)%.rpp$")
    if not filename then return nil end
    
    local version = filename:match("_(%d+)")
    return tonumber(version)
end

function ConstructVersionedFile(currentFile, targetVersion)
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

function GetCommonDirectoryAndReferenceFiles()
    if #state.selected_items == 0 then return nil, {}, false end
    
    local directories = {}
    local reference_files = {}
    
    for _, item in ipairs(state.selected_items) do
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

function FilterMedia(media_list, query)
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

function ScanAvailableMedia(directory)
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

function GetFilenameFromPath(path)
    if not path then return "" end
    return path:match("([^/\\]+)$") or path
end

function GetSafeSourceLength(filePath)
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

function UpdateItemsToPreviousVersion()
    if #state.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    CleanupTempSources()
    
    for _, item in ipairs(state.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            local prevFile = FindPreviousFile(currentFile)
            if prevFile then
                local source_length = 0
                if config.adjust_item_size then
                    source_length = GetSafeSourceLength(prevFile)
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
    
    CleanupTempSources()
    
    r.Undo_EndBlock("Update media sources to previous version", -1)
    
    return updatedCount, errorCount
end

function UpdateItemsToNextVersion()
    if #state.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    CleanupTempSources()
    
    for _, item in ipairs(state.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            local nextFile = FindNextFile(currentFile)
            if nextFile then
                local source_length = 0
                if config.adjust_item_size then
                    source_length = GetSafeSourceLength(nextFile)
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
    
    CleanupTempSources()
    
    r.Undo_EndBlock("Update media sources to next version", -1)
    
    return updatedCount, errorCount
end

function SyncWithProjectVersion()
    local version = GetProjectVersion()
    if not version then return 0, 0 end
    
    if #state.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    CleanupTempSources()
    
    for _, item in ipairs(state.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            local versionedFile = ConstructVersionedFile(currentFile, version)
            if versionedFile then
                local file = io.open(versionedFile, "r")
                if file then
                    file:close()
                    
                    local source_length = 0
                    if config.adjust_item_size then
                        source_length = GetSafeSourceLength(versionedFile)
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
    
    CleanupTempSources()
    
    r.Undo_EndBlock("Sync media sources to project version", -1)
    
    return updatedCount, errorCount
end

function UpdateToMediaFile(mediaPath)
    if not mediaPath or #state.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    CleanupTempSources()
    
    local source_length = 0
    if config.adjust_item_size then
        source_length = GetSafeSourceLength(mediaPath)
    end
    
    for _, item in ipairs(state.selected_items) do
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
    
    CleanupTempSources()
    
    r.Undo_EndBlock("Update media sources to " .. GetFilenameFromPath(mediaPath), -1)
    
    return updatedCount, errorCount
end

function SanitizeFilename(name)
    local sanitized = name:gsub("[\\/:*?\"<>|]", "_")
    sanitized = sanitized:match("^%s*(.-)%s*$")
    return sanitized
end

function CopyFile(sourcePath, destPath)
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

function RenameSourceFiles()
    if #state.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    CleanupTempSources()
    
    for _, item in ipairs(state.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            local directory = currentFile:match("(.+)[/\\]")
            local extension = currentFile:match("%.([^%.]+)$")
            
            if directory and extension then
                local takeName = r.GetTakeName(take)
                
                local sanitizedName = SanitizeFilename(takeName)
                
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
                
                local success, errorMsg = CopyFile(currentFile, newFilePath)
                
                if success then
                    local source_length = 0
                    if config.adjust_item_size then
                        source_length = GetSafeSourceLength(newFilePath)
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
        
        state.common_directory, state.reference_files, state.multiple_directories = GetCommonDirectoryAndReferenceFiles()
        if state.common_directory then
            state.available_media = ScanAvailableMedia(state.common_directory)
            state.filtered_media = FilterMedia(state.available_media, config.search_query)
        end
    end
    
    CleanupTempSources()
    
    r.Undo_EndBlock("Rename media sources to take names", -1)
    
    return updatedCount, errorCount
end

function MainLoop()
    if not _G[script_id] then return end
    
    ApplyStyle()
    
    local header_font = GetFont("header")
    local main_font = GetFont("main")
    
    if not config.window_position_set then
        r.ImGui_SetNextWindowSize(ctx, 600, 500, r.ImGui_Cond_FirstUseEver())
        config.window_position_set = true
    end
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Source Manager', true, window_flags)
    
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "Source Manager")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "Source Manager")
        end

        r.ImGui_SameLine(ctx)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if style_loader and style_loader.PushFont(ctx, "main") then

        r.ImGui_Separator(ctx)
        local selected_items = {}
        for i = 0, r.CountSelectedMediaItems(0) - 1 do
            table.insert(selected_items, r.GetSelectedMediaItem(0, i))
        end
        
        local selection_changed = false
        if #selected_items ~= #state.selected_items then
            selection_changed = true
        else
            for i, item in ipairs(selected_items) do
                if item ~= state.selected_items[i] then
                    selection_changed = true
                    break
                end
            end
        end
        
        if selection_changed then
            state.selected_items = selected_items
            state.common_directory, state.reference_files, state.multiple_directories = GetCommonDirectoryAndReferenceFiles()
            if state.common_directory then
                state.available_media = ScanAvailableMedia(state.common_directory)
                state.filtered_media = FilterMedia(state.available_media, config.search_query)
            else
                state.available_media = {}
                state.filtered_media = {}
            end
        end
        
        r.ImGui_Text(ctx, string.format("Selected items: %d", #state.selected_items))
        if state.multiple_directories then
            r.ImGui_Text(ctx, "Directory: <multiple directories>")
        elseif state.common_directory then
            r.ImGui_Text(ctx, "Directory: " .. state.common_directory)
        else
            r.ImGui_Text(ctx, "No directory found")
        end
        if #state.selected_items > 0 then
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Selected media sources:")
            
            local list_height = math.min(100, #state.selected_items * 25)
            if #state.selected_items > 1 then
                r.ImGui_BeginChild(ctx, "ItemsList", -1, list_height, 1)
            end
            
            for i, item in ipairs(state.selected_items) do
                local take = r.GetActiveTake(item)
                if take then
                    local source = r.GetMediaItemTake_Source(take)
                    local filePath = r.GetMediaSourceFileName(source)
                    local filename = GetFilenameFromPath(filePath)
                    
                    local takeName = r.GetTakeName(take)
                    r.ImGui_Text(ctx, string.format("%d: %s (%s)", i, takeName, filename))
                    
                    if r.ImGui_IsItemHovered(ctx) then
                        r.ImGui_BeginTooltip(ctx)
                        r.ImGui_Text(ctx, filePath)
                        r.ImGui_EndTooltip(ctx)
                    end
                end
            end
            
            if #state.selected_items > 1 then
                r.ImGui_EndChild(ctx)
            end
        end
        
        r.ImGui_Separator(ctx)
        
        r.ImGui_BeginDisabled(ctx, #state.selected_items == 0)
        
        local content_width = r.ImGui_GetContentRegionAvail(ctx)
        local button_width = (content_width - item_spacing_x * 2) / 3
        if r.ImGui_Button(ctx, "Previous Version", button_width) then
            local updated, errors = UpdateItemsToPreviousVersion()
            state.status_message = string.format("Updated %d items to previous version, %d errors", updated, errors)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Next Version", button_width) then
            local updated, errors = UpdateItemsToNextVersion()
            state.status_message = string.format("Updated %d items to next version, %d errors", updated, errors)
        end
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Rename Source(s)", button_width) then
            local updated, errors = RenameSourceFiles()
            state.status_message = string.format("Renamed %d source files based on item names, %d errors", updated, errors)
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
        
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "When enabled, item length will be adjusted to match the source media length")
            r.ImGui_EndTooltip(ctx)
        end

        r.ImGui_Separator(ctx)

        r.ImGui_Text(ctx, "Search media files:")
        
        local search_changed
        search_changed, config.search_query = r.ImGui_InputText(ctx, "##search", config.search_query)
        
        if search_changed then
            state.filtered_media = FilterMedia(state.available_media, config.search_query)
        elseif selection_changed then
            state.filtered_media = FilterMedia(state.available_media, config.search_query)
        end
        
        r.ImGui_Text(ctx, "Available media in directory:")
        if not state.multiple_directories and #state.available_media > 0 then
            local display_media = config.search_query ~= "" and state.filtered_media or state.available_media
            
            local window_height = r.ImGui_GetWindowHeight(ctx)
            local cursor_y = r.ImGui_GetCursorPosY(ctx)
            
            local status_space = 0
            if state.status_message ~= "" then
                local line_height = r.ImGui_GetTextLineHeight(ctx)
                status_space = line_height + 15
            end
            
            local child_height = window_height - cursor_y - window_padding_y - status_space
            
            if r.ImGui_BeginChild(ctx, "MediaList", -1, child_height, 1) then
                for i, media in ipairs(display_media) do
                    local is_current = false
                    for _, refFile in ipairs(state.reference_files) do
                        if refFile == media.path then
                            is_current = true
                            break
                        end
                    end
                    
                    if is_current then
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFF00FF)
                    end
                    
                    if r.ImGui_Selectable(ctx, media.name, false) then
                        local updated, errors = UpdateToMediaFile(media.path)
                        state.status_message = string.format("Updated %d items to %s, %d errors", 
                                       updated, media.name, errors)
                        
                        state.common_directory, state.reference_files, state.multiple_directories = GetCommonDirectoryAndReferenceFiles()
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
        elseif state.multiple_directories then
            r.ImGui_Text(ctx, "Items from multiple directories selected")
        else
            r.ImGui_Text(ctx, "No media files found")
        end
        
        if state.status_message ~= "" then
            r.ImGui_TextWrapped(ctx, state.status_message)
        end
        
        style_loader.PopFont(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    ClearStyle()
    
    r.PreventUIRefresh(-1)
    
    if open then
        r.defer(MainLoop)
    else
        CleanupTempSources()
        SaveSettings()
    end
end

function ToggleScript()
    local _, _, section_id, command_id = r.get_action_context()
    local script_state = r.GetToggleCommandState(command_id)
    
    if script_state == -1 or script_state == 0 then
        r.SetToggleCommandState(section_id, command_id, 1)
        r.RefreshToolbar2(section_id, command_id)
        Start()
    else
        r.SetToggleCommandState(section_id, command_id, 0)
        r.RefreshToolbar2(section_id, command_id)
        Stop()
    end
end

function Start()
    LoadSettings()
    MainLoop()
end

function Stop()
    SaveSettings()
    Cleanup()
end

function Cleanup()
    CleanupTempSources()
    local _, _, section_id, command_id = r.get_action_context()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end

function Exit()
    SaveSettings()
    Cleanup()
end

r.atexit(Exit)
ToggleScript()