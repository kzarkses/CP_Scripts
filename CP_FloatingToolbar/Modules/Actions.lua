-- CP_FloatingToolbar / Actions
-- Resolve REAPER command_id (string or number) → numeric, get name, get
-- toggle state, execute. Mirrors CP_CustomToolbars/ActionManager but
-- minimal and dependency-free.

local Actions = {}

local name_cache = {}
local resolved_cache = {}

-- Cached enumeration of all REAPER actions (built lazily on first call)
local enum_cache = nil

local function resolve(command_id)
    if not command_id then return nil end
    local key = tostring(command_id)
    if resolved_cache[key] ~= nil then return resolved_cache[key] end

    local numeric = nil
    if type(command_id) == "number" then
        numeric = command_id
    else
        local ok, id = pcall(reaper.NamedCommandLookup, command_id)
        if ok and id and id ~= 0 then numeric = id end
        if not numeric and not command_id:match("^_") and command_id:match("[A-Za-z]") then
            local ok2, id2 = pcall(reaper.NamedCommandLookup, "_" .. command_id)
            if ok2 and id2 and id2 ~= 0 then numeric = id2 end
        end
    end

    resolved_cache[key] = numeric or false
    return numeric
end

function Actions.GetName(command_id)
    if not command_id then return "Unknown" end
    local key = tostring(command_id)
    if name_cache[key] then return name_cache[key] end

    local numeric = resolve(command_id)
    local name = nil
    if numeric then
        if reaper.CF_GetCommandText then
            local n = reaper.CF_GetCommandText(0, numeric)
            if n and n ~= "" then name = n end
        end
        if not name and reaper.GetActionName then
            local _, n = reaper.GetActionName(0, numeric)
            if n and n ~= "" then name = n end
        end
    end
    name = name or ("Cmd " .. tostring(command_id))
    name_cache[key] = name
    return name
end

function Actions.GetState(command_id)
    local numeric = resolve(command_id)
    if not numeric then return 0 end
    return reaper.GetToggleCommandState(numeric)
end

function Actions.Execute(command_id)
    local numeric = resolve(command_id)
    if not numeric then return false end
    reaper.Main_OnCommand(numeric, 0)
    return true
end

-- Build the full enum cache lazily. Returns the full list (each entry:
-- {id, numeric_id, name, search_text}).
function Actions.Enumerate()
    if enum_cache then return enum_cache end
    enum_cache = {}

    if reaper.CF_EnumerateActions then
        local idx = 0
        while true do
            local retval, name = reaper.CF_EnumerateActions(0, idx)
            if retval == 0 or not name or name == "" then break end
            local numeric = retval
            local named = reaper.ReverseNamedCommandLookup and reaper.ReverseNamedCommandLookup(retval)
            if named and named ~= "" and not named:match("^_") and named:match("[A-Za-z]") then
                named = "_" .. named
            end
            table.insert(enum_cache, {
                id = named or numeric,
                numeric_id = numeric,
                name = name,
                search_text = name:lower(),
            })
            idx = idx + 1
        end
    end
    return enum_cache
end

function Actions.Search(query, limit)
    local all = Actions.Enumerate()
    if not query or query == "" then
        if limit and limit < #all then
            local res = {}
            for i = 1, limit do res[i] = all[i] end
            return res
        end
        return all
    end
    local q = query:lower()
    local results = {}
    for _, a in ipairs(all) do
        if a.search_text:find(q, 1, true) then
            table.insert(results, a)
            if limit and #results >= limit then break end
        end
    end
    return results
end

function Actions.InvalidateCache()
    name_cache = {}
    resolved_cache = {}
    enum_cache = nil
end

return Actions
