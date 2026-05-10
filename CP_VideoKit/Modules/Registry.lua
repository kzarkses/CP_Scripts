-- CP_VideoKit / Registry.lua
-- Loads every module file from the Effects/ directory.
-- Each module file returns a table with:
--   id, name, tag, preset, params, on_drag, on_wheel, on_mouse_down, draw_panel

local Registry = {}

local modules    = {}
local by_tag     = {}
local by_id      = {}

function Registry.load_all(effects_root)
    modules = {}
    by_tag  = {}
    by_id   = {}

    -- We can't list a directory with stock Lua on Windows reliably; rely on
    -- a fixed manifest file in Effects/manifest.lua that lists module files.
    local manifest_path = effects_root .. "manifest.lua"
    local f = io.open(manifest_path, "rb")
    if not f then
        reaper.MB("Manifest not found: " .. manifest_path, "CP_VideoKit", 0)
        return modules
    end
    f:close()

    local manifest = dofile(manifest_path)
    local current_category = "Other"
    for _, entry in ipairs(manifest) do
        if type(entry) == "table" and entry.category then
            current_category = entry.category
        elseif type(entry) == "string" then
            local mod_path = effects_root .. entry
            local ok, mod = pcall(dofile, mod_path)
            if ok and type(mod) == "table" and mod.id and mod.tag then
                mod.category          = current_category
                modules[#modules + 1] = mod
                by_tag[mod.tag]       = mod
                by_id[mod.id]         = mod
            else
                reaper.ShowConsoleMsg("CP_VideoKit: failed to load " ..
                                      entry .. " — " .. tostring(mod) .. "\n")
            end
        end
    end
    return modules
end

-- Returns modules grouped by category, preserving manifest order:
--   { { name = "Transform", modules = { def1, def2 } }, ... }
function Registry.list_grouped()
    local groups   = {}
    local by_name  = {}
    for _, mod in ipairs(modules) do
        local cat = mod.category or "Other"
        local g = by_name[cat]
        if not g then
            g = { name = cat, modules = {} }
            by_name[cat] = g
            groups[#groups + 1] = g
        end
        g.modules[#g.modules + 1] = mod
    end
    return groups
end

function Registry.list()
    return modules
end

function Registry.find_by_tag(tag)
    return by_tag[tag]
end

function Registry.find_by_id(id)
    return by_id[id]
end

return Registry
