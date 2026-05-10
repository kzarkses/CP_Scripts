-- CP_VideoKit / Shared.lua
-- Functionality used by both Modules and Inspector scripts:
--   * Focus persistence (config file)
--   * Take detection
--   * Active state container that follows the user selection

local Shared = {}

local SCRIPT_ID = "CP_VideoKit"

function Shared.script_id() return SCRIPT_ID end

-- ============================================================================
-- Persisted focus: focus_by_take[take_guid] = fx_idx
-- Stored via SaveConfig (file-based) so a Lua table round-trips correctly.
-- ============================================================================

function Shared.load_focus(UI)
    local data = UI.LoadConfig and UI.LoadConfig(SCRIPT_ID) or nil
    if type(data) == "table" and type(data.focus_by_take) == "table" then
        return data.focus_by_take
    end
    return {}
end

function Shared.save_focus(UI, focus_by_take)
    if UI.SaveConfig then
        UI.SaveConfig(SCRIPT_ID, { focus_by_take = focus_by_take })
    end
end

function Shared.take_guid(take)
    if not take then return nil end
    if reaper.BR_GetMediaItemTakeGUID then
        return reaper.BR_GetMediaItemTakeGUID(take)
    end
    local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
    return guid
end

-- ============================================================================
-- Active state — refreshed each frame from the user's REAPER selection.
-- The script that owns interception (Modules) and the Inspector both call
-- refresh_target() to know what to display.
-- ============================================================================

function Shared.new_state()
    return {
        take       = nil,
        guid       = nil,
        modules    = {},     -- list from Core.scan_modules
        focus_idx  = nil,    -- index into modules[]
        state      = {},     -- table from module.read_state
        session    = {},     -- scratch for drag anchors
    }
end

-- ============================================================================
-- Slider row with extras: Alt+click reset, "..." menu for numeric input.
-- Returns: changed, new_value
-- opts: { default = 0, format = "%.3f", step = nil, integer = false }
-- ============================================================================
function Shared.SliderRow(UI, id, label, value, min, max, opts)
    opts = opts or {}
    local default = opts.default or 0
    local fmt     = opts.format or (opts.integer and "%d" or "%.3f")

    local changed, new_value
    if opts.integer then
        changed, new_value = UI.SliderInt(id, label, math.floor(value),
                                          min, max, { format = fmt })
    else
        changed, new_value = UI.SliderDouble(id, label, value, min, max,
                                             { format = fmt })
    end

    -- Inline "..." menu button to open numeric input or reset.
    UI.SameLine()
    if UI.Button(id .. "_menu", "...", { width = 20 }) then
        local prompt = "New value (current " .. fmt:format(value) ..
                       "),Reset to default? 0=no 1=yes,extrawidth=120"
        local ok, csv = reaper.GetUserInputs(label, 2, prompt,
            tostring(value) .. "," .. "0")
        if ok then
            local val_str, reset_str = csv:match("([^,]*),([^,]*)")
            if reset_str and tonumber(reset_str) == 1 then
                return true, default
            end
            local n = tonumber(val_str)
            if n then
                if n < min then n = min end
                if n > max then n = max end
                if opts.integer then n = math.floor(n + 0.5) end
                return true, n
            end
        end
    end

    return changed, new_value
end

-- ============================================================================
-- Preset store — saves/loads per-module parameter snapshots.
-- File layout:
--   <CP_VideoKit>/UserPresets/<module_id>/<preset_name>.lua
-- Each file returns a table of param_key → value (matching def.params keys).
-- ============================================================================

local function preset_root(script_path, module_id)
    return script_path .. "UserPresets" .. package.config:sub(1,1) ..
           module_id .. package.config:sub(1,1)
end

local function ensure_dir(path)
    -- Best effort directory creation. On Windows we use `mkdir`, on POSIX
    -- `mkdir -p`. REAPER ships RecursiveCreateDirectory on newer versions.
    if reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return true
    end
    return false
end

local function serialize(t, indent)
    indent = indent or ""
    local nxt = indent .. "  "
    local parts = { "{\n" }
    for k, v in pairs(t) do
        local key
        if type(k) == "string" then key = string.format("[%q]", k)
        else key = "[" .. tostring(k) .. "]" end
        local val
        if type(v) == "table" then
            val = serialize(v, nxt)
        elseif type(v) == "string" then
            val = string.format("%q", v)
        else
            val = tostring(v)
        end
        parts[#parts + 1] = nxt .. key .. " = " .. val .. ",\n"
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts)
end

function Shared.preset_save(script_path, module_id, name, state_table)
    if not name or name == "" then return false, "empty name" end
    local dir = preset_root(script_path, module_id)
    ensure_dir(dir)
    local path = dir .. name .. ".lua"
    local f = io.open(path, "wb")
    if not f then return false, "cannot open " .. path end
    f:write("return ")
    f:write(serialize(state_table))
    f:write("\n")
    f:close()
    return true
end

function Shared.preset_load(script_path, module_id, name)
    local path = preset_root(script_path, module_id) .. name .. ".lua"
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

function Shared.preset_list(script_path, module_id)
    local dir = preset_root(script_path, module_id)
    local list = {}
    local i = 0
    while true do
        local fname = reaper.EnumerateFiles(dir, i)
        if not fname then break end
        if fname:match("%.lua$") then
            list[#list + 1] = fname:gsub("%.lua$", "")
        end
        i = i + 1
    end
    table.sort(list)
    return list
end

function Shared.preset_delete(script_path, module_id, name)
    local path = preset_root(script_path, module_id) .. name .. ".lua"
    return os.remove(path) and true or false
end

-- ============================================================================
-- Looks — saved chains: a list of { module_id, params, custom_name, bypassed }
-- File: <CP_VideoKit>/Looks/<look_name>.lua
-- ============================================================================
local function looks_root(script_path)
    return script_path .. "Looks" .. package.config:sub(1,1)
end

function Shared.look_save(script_path, name, look_data)
    if not name or name == "" then return false end
    local dir = looks_root(script_path)
    ensure_dir(dir)
    local path = dir .. name .. ".lua"
    local f = io.open(path, "wb")
    if not f then return false end
    f:write("return ")
    f:write(serialize(look_data))
    f:write("\n")
    f:close()
    return true
end

function Shared.look_load(script_path, name)
    local path = looks_root(script_path) .. name .. ".lua"
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

function Shared.look_list(script_path)
    local dir = looks_root(script_path)
    local list = {}
    local i = 0
    while true do
        local fname = reaper.EnumerateFiles(dir, i)
        if not fname then break end
        if fname:match("%.lua$") then
            list[#list + 1] = fname:gsub("%.lua$", "")
        end
        i = i + 1
    end
    table.sort(list)
    return list
end

function Shared.look_delete(script_path, name)
    return os.remove(looks_root(script_path) .. name .. ".lua") and true or false
end

-- Capture a snapshot of all CP_VideoKit modules on a take.
-- Requires Core (for scan_modules) and Registry (for module defs).
function Shared.look_capture(Core, Registry, take)
    local modules = Core.scan_modules(take, Registry)
    local list = {}
    for _, m in ipairs(modules) do
        local def = Registry.find_by_id(m.module_id)
        if def and def.read_state then
            local params = def.read_state(Core, take, m.fx_idx)
            params.show_frame = nil  -- UI-only, never persisted
            list[#list + 1] = {
                module_id   = m.module_id,
                params      = params,
                custom_name = m.custom_name,
                bypassed    = m.bypassed,
            }
        end
    end
    return list
end

-- Apply a look to a take: clears CP_VideoKit modules first, then installs
-- each in order with its saved params.
function Shared.look_apply(Core, Registry, take, look, preset_root_path)
    if not take or type(look) ~= "table" then return false end
    -- Remove existing CP_VideoKit modules (iterate from top to keep indices).
    local existing = Core.scan_modules(take, Registry)
    for i = #existing, 1, -1 do
        Core.remove_module(take, existing[i].fx_idx)
    end
    -- Install fresh from the look.
    for _, entry in ipairs(look) do
        local def = Registry.find_by_id(entry.module_id)
        if def then
            local idx = Core.install_module(take, def, preset_root_path)
            if idx and entry.params and def.params then
                for k, p_idx in pairs(def.params) do
                    if entry.params[k] ~= nil then
                        Core.set_param(take, idx, p_idx, entry.params[k])
                    end
                end
            end
            if idx and entry.custom_name and entry.custom_name ~= "" then
                Core.set_custom_name(take, idx, entry.custom_name)
            end
            if idx and entry.bypassed then
                Core.set_bypassed(take, idx, true)
            end
        end
    end
    return true
end

-- ============================================================================
-- Module clipboard — process-wide single slot for copy/paste between takes.
-- We store on disk so the two windows (Modules + Inspector) share the same
-- clipboard, and so it survives a script reload.
-- ============================================================================
local function clip_path(script_path)
    return script_path .. "module_clipboard.lua"
end

function Shared.clipboard_set(script_path, entry)
    local f = io.open(clip_path(script_path), "wb")
    if not f then return false end
    f:write("return ")
    f:write(serialize(entry))
    f:write("\n")
    f:close()
    return true
end

function Shared.clipboard_get(script_path)
    local ok, data = pcall(dofile, clip_path(script_path))
    if ok and type(data) == "table" then return data end
    return nil
end

function Shared.clipboard_clear(script_path)
    os.remove(clip_path(script_path))
end

return Shared
