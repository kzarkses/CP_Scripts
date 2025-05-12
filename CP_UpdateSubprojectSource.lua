-- @description Media Source Version Manager GUI
-- @version 1.0
-- @author Claude
-- @about
--   GUI for managing media source versions and synchronizing with project versions

local r = reaper

-- Create ImGui context
local ctx = r.ImGui_CreateContext('Media Source Version Manager')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

-- Style loader integration
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

-- Try to load style loader module
local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

-- Configuration variables
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
    adjust_item_size = true
}

-- Function to get next file in sequence
function findNextFile(currentFile)
    -- Get directory and file info
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    -- Obtenir le nom de base sans l'extension
    local nameWithoutExt = baseName:match("(.+)%.")
    if not nameWithoutExt then return nil end
    
    -- Vérifier si le fichier a déjà une numérotation
    local hasNumber = false
    local prefix, currentNum, separator
    
    -- Patterns pour détecter différents formats de version
    local patterns = {
        {pattern = "%-(%d+)%.", separator = "-"},  -- -1, -01, -001
        {pattern = "_(%d+)%.", separator = "_"},   -- _1, _01, _001
        {pattern = " (%d+)%.", separator = " "}    -- espace 1, espace 01, espace 001
    }
    
    for _, pat in ipairs(patterns) do
        local numStr = baseName:match(pat.pattern)
        if numStr then
            hasNumber = true
            currentNum = tonumber(numStr)
            separator = pat.separator
            prefix = baseName:match("(.+)" .. separator .. "%d+")
            
            if prefix and currentNum then
                -- Préserve le zéro-padding (ex: 001 -> 002)
                local formatStr = string.format("%%0%dd", #numStr)
                local nextNum = string.format(formatStr, currentNum + 1)
                
                -- Créer le chemin du fichier suivant
                local nextFile = string.format("%s%s%s.%s", prefix, separator, nextNum, extension)
                local fullPath = directory .. "/" .. nextFile
                
                -- Vérifier si le fichier existe
                local file = io.open(fullPath, "r")
                if file then
                    file:close()
                    return fullPath
                end
            end
            
            break -- Sort de la boucle une fois qu'un pattern a été trouvé
        end
    end
    
    -- Si le fichier n'a pas de numérotation, chercher la version 01
    if not hasNumber then
        -- Essayer les différents formats de numérotation pour trouver une version "01"
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

-- Function to get previous file in sequence
function findPreviousFile(currentFile)
    -- Get directory and file info
    local directory = currentFile:match("(.+)[/\\]")
    local baseName = currentFile:match("^.+[/\\](.+)$")
    
    if not directory or not baseName then return nil end
    
    local extension = baseName:match("%.([^%.]+)$")
    if not extension then return nil end
    
    -- Patterns pour détecter différents formats de version
    local patterns = {
        {pattern = "%-(%d+)%.", separator = "-"},  -- -1, -01, -001
        {pattern = "_(%d+)%.", separator = "_"},   -- _1, _01, _001
        {pattern = " (%d+)%.", separator = " "}    -- espace 1, espace 01, espace 001
    }
    
    for _, pat in ipairs(patterns) do
        local numStr = baseName:match(pat.pattern)
        if numStr then
            local currentNum = tonumber(numStr)
            local prefix = baseName:match("(.+)" .. pat.separator .. "%d+")
            
            if prefix and currentNum then
                if currentNum > 1 then
                    -- Préserve le zéro-padding (ex: 002 -> 001)
                    local formatStr = string.format("%%0%dd", #numStr)
                    local prevNum = string.format(formatStr, currentNum - 1)
                    
                    -- Créer le chemin du fichier précédent
                    local prevFile = string.format("%s%s%s.%s", prefix, pat.separator, prevNum, extension)
                    local fullPath = directory .. "/" .. prevFile
                    
                    -- Vérifier si le fichier existe
                    local file = io.open(fullPath, "r")
                    if file then
                        file:close()
                        return fullPath
                    end
                elseif currentNum == 1 then
                    -- Si on est à 1, chercher la version de base sans numéro
                    local baseFile = string.format("%s.%s", prefix, extension)
                    local fullPath = directory .. "/" .. baseFile
                    
                    -- Vérifier si le fichier de base existe
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

-- Function to extract project version number
function getProjectVersion()
    local _, projectPath = r.EnumProjects(-1)
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

-- Function to get common directory and reference files for selected items
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
    
    -- Check if all items are from the same directory
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

-- Function to scan available media files in directory
function scanAvailableMedia(directory)
    if not directory then return {} end
    
    local media_files = {}
    local supported_extensions = {
        ["wav"] = true, ["mp3"] = true, ["ogg"] = true, ["flac"] = true, 
        ["aif"] = true, ["aiff"] = true, ["m4a"] = true, ["wav64"] = true,
        ["mp4"] = true, ["mov"] = true, ["avi"] = true, ["mkv"] = true,
        ["rpp"] = true
    }
    
    -- List all files in directory
    local files = {}
    local i = 0
    repeat
        local fileName = r.EnumerateFiles(directory, i)
        if fileName then
            table.insert(files, fileName)
        end
        i = i + 1
    until not fileName
    
    -- Filter to keep only media files
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
    
    -- Sort alphabetically
    table.sort(media_files, function(a, b) return a.name < b.name end)
    
    return media_files
end

-- Function to get filename from path
function getFilenameFromPath(path)
    if not path then return "" end
    return path:match("([^/\\]+)$") or path
end

-- Function to update selected items to previous version
function updateItemsToPreviousVersion()
    if #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            -- Find previous file
            local prevFile = findPreviousFile(currentFile)
            if prevFile then
                -- Si on ajuste la taille, obtenir d'abord la longueur de la source
                local source_length = 0
                if config.adjust_item_size then
                    local temp_source = r.PCM_Source_CreateFromFile(prevFile)
                    if temp_source then
                        source_length, lengthIsQN = r.GetMediaSourceLength(temp_source)
                        if lengthIsQN then
                            -- Convertir la longueur MIDI en temps
                            local tempo = r.Master_GetTempo()
                            source_length = source_length * 60 / tempo
                        end
                    end
                end
                
                -- Create new source and set it
                local newSource = r.PCM_Source_CreateFromFile(prevFile)
                if r.SetMediaItemTake_Source(take, newSource) then
                    -- Ajuster la longueur de l'item si l'option est activée
                    if config.adjust_item_size and source_length > 0 then
                        r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                    end
                    
                    r.UpdateItemInProject(item)
                    r.SetMediaItemSelected(item, true)
                    updatedCount = updatedCount + 1
                else
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
    
    r.Undo_EndBlock("Update media sources to previous version", -1)
    
    return updatedCount, errorCount
end

-- Function to update selected items to next version
function updateItemsToNextVersion()
    if #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            -- Find next file
            local nextFile = findNextFile(currentFile)
            if nextFile then
                -- Si on ajuste la taille, obtenir d'abord la longueur de la source
                local source_length = 0
                if config.adjust_item_size then
                    local temp_source = r.PCM_Source_CreateFromFile(nextFile)
                    if temp_source then
                        source_length, lengthIsQN = r.GetMediaSourceLength(temp_source)
                        if lengthIsQN then
                            -- Convertir la longueur MIDI en temps
                            local tempo = r.Master_GetTempo()
                            source_length = source_length * 60 / tempo
                        end
                    end
                end
                
                -- Create new source and set it
                local newSource = r.PCM_Source_CreateFromFile(nextFile)
                if r.SetMediaItemTake_Source(take, newSource) then
                    -- Ajuster la longueur de l'item si l'option est activée
                    if config.adjust_item_size and source_length > 0 then
                        r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                    end
                    
                    r.UpdateItemInProject(item)
                    r.SetMediaItemSelected(item, true)
                    updatedCount = updatedCount + 1
                else
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
    
    r.Undo_EndBlock("Update media sources to next version", -1)
    
    return updatedCount, errorCount
end

-- Function to sync with project version
function syncWithProjectVersion()
    local version = getProjectVersion()
    if not version then return 0, 0 end
    
    if #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            local currentFile = r.GetMediaSourceFileName(source)
            
            local versionedFile = constructVersionedFile(currentFile, version)
            if versionedFile then
                -- Check if versioned file exists
                local file = io.open(versionedFile, "r")
                if file then
                    file:close()
                    
                    -- Si on ajuste la taille, obtenir d'abord la longueur de la source
                    local source_length = 0
                    if config.adjust_item_size then
                        local temp_source = r.PCM_Source_CreateFromFile(versionedFile)
                        if temp_source then
                            source_length, lengthIsQN = r.GetMediaSourceLength(temp_source)
                            if lengthIsQN then
                                -- Convertir la longueur MIDI en temps
                                local tempo = r.Master_GetTempo()
                                source_length = source_length * 60 / tempo
                            end
                        end
                    end
                    
                    -- Update source
                    local newSource = r.PCM_Source_CreateFromFile(versionedFile)
                    if r.SetMediaItemTake_Source(take, newSource) then
                        -- Ajuster la longueur de l'item si l'option est activée
                        if config.adjust_item_size and source_length > 0 then
                            r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                        end
                        
                        r.UpdateItemInProject(item)
                        r.SetMediaItemSelected(item, true)
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
    
    -- Force build peaks for all selected items
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0) -- Build peaks for selected items
    end
    
    r.Undo_EndBlock("Sync media sources to project version", -1)
    
    return updatedCount, errorCount
end

-- Function to update to specific media file
function updateToMediaFile(mediaPath)
    if not mediaPath or #config.selected_items == 0 then return 0, 0 end
    
    local updatedCount = 0
    local errorCount = 0
    
    r.Undo_BeginBlock()
    
    -- If we need to adjust size, get source length first
    local source_length = 0
    if config.adjust_item_size then
        local temp_source = r.PCM_Source_CreateFromFile(mediaPath)
        if temp_source then
            source_length, lengthIsQN = r.GetMediaSourceLength(temp_source)
            if lengthIsQN then
                -- Convert MIDI length to time
                local tempo = r.Master_GetTempo()
                source_length = source_length * 60 / tempo
            end
        end
    end
    
    for _, item in ipairs(config.selected_items) do
        local take = r.GetActiveTake(item)
        if take then
            -- Create new source and set it
            local newSource = r.PCM_Source_CreateFromFile(mediaPath)
            if newSource and r.SetMediaItemTake_Source(take, newSource) then
                -- Adjust item length if enabled and we have a valid source length
                if config.adjust_item_size and source_length > 0 then
                    r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
                end
                
                r.UpdateItemInProject(item)
                updatedCount = updatedCount + 1
                
                -- Force peak building for the item
                r.SetMediaItemSelected(item, true)
            else
                errorCount = errorCount + 1
            end
        end
    end
    
    -- Force build peaks for all selected items
    if updatedCount > 0 then
        r.Main_OnCommand(40441, 0) -- Build peaks for selected items
    end
    
    r.Undo_EndBlock("Update media sources to " .. getFilenameFromPath(mediaPath), -1)
    
    return updatedCount, errorCount
end

-- Main GUI loop
function MainLoop()
    -- Apply the global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end

    -- Set window position
    if not config.window_position_set then
        r.ImGui_SetNextWindowSize(ctx, 600, 500)
        config.window_position_set = true
    end
    
    local visible, open = r.ImGui_Begin(ctx, 'Media Source Version Manager', true, WINDOW_FLAGS)
    
    if visible then
        -- Update selected items list
        local selected_items = {}
        for i = 0, r.CountSelectedMediaItems(0) - 1 do
            table.insert(selected_items, r.GetSelectedMediaItem(0, i))
        end
        
        -- Check if selection changed
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
        -- Initialize filtered media with all media when selection changes
        config.filtered_media = filterMedia(config.available_media, config.search_query)
    else
        config.available_media = {}
        config.filtered_media = {}
    end
end
        
        -- Display current selection info
        r.ImGui_Text(ctx, string.format("Selected items: %d", #config.selected_items))
        if config.multiple_directories then
            r.ImGui_Text(ctx, "Directory: <multiple directories>")
        elseif config.common_directory then
            r.ImGui_Text(ctx, "Directory: " .. config.common_directory)
        else
            r.ImGui_Text(ctx, "No directory found")
        end
        
        -- Current media info
        if #config.selected_items > 0 then
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "Selected media sources:")
            
            -- Use a child window with scrolling for the item list if many items
            local list_height = math.min(100, #config.selected_items * 25) -- Scale height based on item count
            if #config.selected_items > 1 then
                r.ImGui_BeginChild(ctx, "ItemsList", -1, list_height, 1)
            end
            
            for i, item in ipairs(config.selected_items) do
                local take = r.GetActiveTake(item)
                if take then
                    local source = r.GetMediaItemTake_Source(take)
                    local filePath = r.GetMediaSourceFileName(source)
                    local filename = getFilenameFromPath(filePath)
                    
                    -- Display item info
                    local takeName = r.GetTakeName(take)
                    r.ImGui_Text(ctx, string.format("%d: %s (%s)", i, takeName, filename))
                    
                    -- Add tooltip with full path
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
        
        -- Version navigation buttons
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
        
        r.ImGui_EndDisabled(ctx)
        
        r.ImGui_Separator(ctx)
        
        local adjust_changed
        adjust_changed, config.adjust_item_size = r.ImGui_Checkbox(ctx, "Adjust item size to match source", config.adjust_item_size)
        
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_BeginTooltip(ctx)
            r.ImGui_Text(ctx, "When enabled, item length will be adjusted to match the source media length")
            r.ImGui_EndTooltip(ctx)
        end

        -- Project version sync
        local project_version = getProjectVersion()
        if project_version then
            r.ImGui_Text(ctx, string.format("Current project version: %d", project_version))
            
            r.ImGui_BeginDisabled(ctx, #config.selected_items == 0)
            if r.ImGui_Button(ctx, "Sync with Project Version", 200, 30) then
                local updated, errors = syncWithProjectVersion()
                config.status_message = string.format("Synced %d items with project version %d, %d errors", 
                               updated, project_version, errors)
            end
            r.ImGui_EndDisabled(ctx)
        else
            r.ImGui_Text(ctx, "No project version detected")
        end
        
        r.ImGui_Separator(ctx)

        r.ImGui_Text(ctx, "Search media files:")
        
        local search_changed
        search_changed, config.search_query = r.ImGui_InputText(ctx, "##search", config.search_query)
        
        if search_changed then
            -- Filter media based on search
            config.filtered_media = filterMedia(config.available_media, config.search_query)
        elseif selection_changed then
            -- Update filtered media when selection changes
            config.filtered_media = filterMedia(config.available_media, config.search_query)
        end
        
        -- Available media files list
        r.ImGui_Text(ctx, "Available media in directory:")
        
        if not config.multiple_directories and #config.available_media > 0 then
    -- Use filtered_media instead of available_media
    local display_media = config.search_query ~= "" and config.filtered_media or config.available_media
    
    -- Use a child window with scrolling for the media files list
    if r.ImGui_BeginChild(ctx, "MediaList", -1, 200, 1) then
        -- Only display the filtered media if search is active
        for i, media in ipairs(display_media) do
            -- Check if this media file is currently used by any selected item
            local is_current = false
            for _, refFile in ipairs(config.reference_files) do
                if refFile == media.path then
                    is_current = true
                    break
                end
            end
                    
                    -- Highlight current source
                    if is_current then
                        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFF00FF) -- Yellow for current source
                    end
                    
                    if r.ImGui_Selectable(ctx, media.name, false) then
                        local updated, errors = updateToMediaFile(media.path)
                        config.status_message = string.format("Updated %d items to %s, %d errors", 
                                       updated, media.name, errors)
                        
                        -- Update reference files after changing sources
                        config.common_directory, config.reference_files, config.multiple_directories = getCommonDirectoryAndReferenceFiles()
                    end
                    
                    if is_current then
                        r.ImGui_PopStyleColor(ctx)
                    end
                    
                    -- Add tooltip with full path
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
        
        -- Status message
        if config.status_message ~= "" then
            r.ImGui_Separator(ctx)
            r.ImGui_TextWrapped(ctx, config.status_message)
        end
        
        r.ImGui_End(ctx)
    end
    
    -- Clean up the styles we applied
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end
    
    if open then
        r.defer(MainLoop)
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
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()