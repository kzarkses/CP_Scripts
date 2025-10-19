-- @description TrackNavigator - ON
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

function FindScriptByName(script_name)
    local resource_path = r.GetResourcePath()
    local possible_paths = {
        resource_path .. "/Scripts/CP_Scripts/Track Navigator/" .. script_name,
        resource_path .. "/Scripts/CP_Scripts/" .. script_name,
        resource_path .. "/Scripts/" .. script_name,
        resource_path .. "/UserPlugins/" .. script_name
    }
    
    for _, path in ipairs(possible_paths) do
        if r.file_exists(path) then
            return path
        end
    end
    
    return nil
end

function GetScriptCommandID(script_path)
    if not script_path or not r.file_exists(script_path) then
        return 0
    end
    
    local command_id = r.NamedCommandLookup("_RS" .. script_path)
    
    if command_id == 0 then
        command_id = r.AddRemoveReaScript(true, 0, script_path, true)
    end
    
    return command_id
end

function StartTrackNavigator()
    local script_name = "CP_TrackNavigator.lua"
    local script_path = FindScriptByName(script_name)
    
    if not script_path then
        r.ShowMessageBox("Could not find " .. script_name .. " in Scripts folders", "Error", 0)
        return false
    end
    
    local command_id = GetScriptCommandID(script_path)
    
    if command_id == 0 then
        r.ShowMessageBox("Could not register " .. script_name .. " as a command", "Error", 0)
        return false
    end
    
    local current_state = r.GetToggleCommandStateEx(0, command_id)
    
    if current_state == 0 then
        r.Main_OnCommand(command_id, 0)
        return true
    else
        return true
    end
end

StartTrackNavigator()
