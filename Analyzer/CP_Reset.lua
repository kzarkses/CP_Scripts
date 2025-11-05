local r = reaper

local scripts = {
    "CP_Goniometer_GFX",
    "CP_FrequencyAnalyzer_GFX"
}

function ResetScript(script_name)
    local keys_to_delete = {}
    
    local i = 0
    repeat
        local key = r.EnumProjExtState(script_name, i)
        if key and key ~= "" then
            table.insert(keys_to_delete, key)
            i = i + 1
        else
            break
        end
    until false
    
    for _, key in ipairs(keys_to_delete) do
        r.SetExtState(script_name, key, "", false)
    end
    
    return #keys_to_delete
end

local total_deleted = 0

for _, script_name in ipairs(scripts) do
    local count = ResetScript(script_name)
    total_deleted = total_deleted + count
    if count > 0 then
        r.ShowConsoleMsg(script_name .. ": " .. count .. " settings deleted\n")
    end
end

if total_deleted > 0 then
    r.ShowConsoleMsg("\nTotal: " .. total_deleted .. " settings deleted\n")
    r.ShowConsoleMsg("Restart the analyzer scripts to use default values\n")
else
    r.ShowConsoleMsg("No saved settings found\n")
end
