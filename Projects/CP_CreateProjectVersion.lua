-- @description CreateProjectVersion
-- @version 1.0
-- @author Cedric Pamalio

function findNextVersionNumber(directory, baseName)
    local highestVersion = 0
    
    -- List all files in directory
    local files = {}
    local i = 0
    repeat
        local fileName = reaper.EnumerateFiles(directory, i)
        if fileName then
            table.insert(files, fileName)
        end
        i = i + 1
    until not fileName
    
    -- Find highest version number
    for _, fileName in ipairs(files) do
        if fileName:match("%.RPP$") or fileName:match("%.rpp$") then
            -- Match only main version numbers (not alternative versions)
            local version = fileName:match("^" .. baseName .. "_(%d+)[^_]?.*%.RPP$") or 
                          fileName:match("^" .. baseName .. "_(%d+)[^_]?.*%.rpp$")
            if version then
                local versionNum = tonumber(version)
                if versionNum > highestVersion then
                    highestVersion = versionNum
                end
            end
        end
    end
    
    return highestVersion + 1
end

function createNextVersion()
    -- Get current project filename
    local proj = 0
    local _, projectPath = reaper.EnumProjects(-1)
    if not projectPath then 
        reaper.ShowMessageBox("No project found", "Error", 0)
        return 
    end
    
    -- Extract filename without extension
    local directory = projectPath:match("(.+)[/\\]")
    local filename = projectPath:match("([^/\\]+)%.RPP$") or projectPath:match("([^/\\]+)%.rpp$")
    if not filename then return end
    
    -- Handle case where we have a base name with no version
    if not filename:match("_%d+") then
        local nextVersion = findNextVersionNumber(directory, filename)
        local newPath = string.format("%s/%s_%d.RPP", directory, filename, nextVersion)
        reaper.Main_SaveProjectEx(proj, newPath, 0)
        reaper.Main_openProject("noprompt:" .. newPath)
        return
    end
    
    -- Handle case where we have version and possibly alternative version
    local baseName, mainVer
    
    -- Check if we have an alternative version (ex: Test_3_5)
    if filename:match("_%d+_%d+$") then
        baseName = filename:match("(.+)_%d+_%d+$")
    else
        -- Simple version (ex: Test_3)
        baseName = filename:match("(.+)_%d+$")
    end
    
    if not baseName then
        reaper.ShowMessageBox("Could not parse project name format", "Error", 0)
        return
    end
    
    -- Find next available version number
    local nextVersion = findNextVersionNumber(directory, baseName)
    
    -- Create new path
    local newPath = string.format("%s/%s_%d.RPP", directory, baseName, nextVersion)
    
    -- Save project as new version
    reaper.Main_SaveProjectEx(proj, newPath, 0)
    
    -- Open the new version
    reaper.Main_openProject("noprompt:" .. newPath)
end

createNextVersion()










