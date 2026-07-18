-- CP_MediaExplorer — FXList
-- Installed-plugin tree for the FX chip (FL "Plugin database" equivalent).
-- Enumerated once via the native EnumInstalledFX (REAPER 6.37+, no ini
-- parsing), grouped Effects / Instruments → type → alphabetical leaves.
--
-- Node contract (shared with the app's list renderer): kind="fx", name,
-- lo_name, path (stable virtual key "fx|<full add-name>"), is_dir, parent,
-- children, depth, expanded — the same fields the FS nodes expose, so the
-- virtualized list, sticky stack, favorites and collections work as-is.
-- Leaves also carry `full`: the exact string TrackFX_AddByName accepts
-- (e.g. "VST3: Pro-Q 3 (FabFilter)"), and lo_search: lowercase full name
-- (type + vendor included) for token matching.

local FXList = {}

local r  -- reaper, injected

FXList.count = 0     -- total plugin leaves (status caption)

local roots      = nil   -- built lazily by Ensure()
local flat_cache = nil   -- flattened visible rows for the current expansion
local filter_cache, filter_text = nil, nil
local all_leaves = {}    -- every plugin leaf (search scans this)

function FXList.init(reaper_api)
    r = reaper_api
end

-- Display order of the type sub-folders.
local TYPE_RANK = { CLAP = 1, VST3 = 2, VST = 3, JS = 4, LV2 = 5, AU = 6, DX = 7 }

local function newDir(name, parent, depth)
    return {
        kind = "fx", name = name, lo_name = name:lower(),
        path = "fxdir|" .. (parent and (parent.name .. "/") or "") .. name,
        is_dir = true, parent = parent, depth = depth,
        children = {}, expanded = false,
    }
end

function FXList.Ensure()
    if roots then return end
    roots = {}
    all_leaves = {}

    local eff  = newDir("Effects", nil, 0)
    local inst = newDir("Instruments", nil, 0)
    eff.expanded = true  -- content visible on first open
    local type_dirs = { [eff] = {}, [inst] = {} }

    local i = 0
    while true do
        local ok, name = r.EnumInstalledFX(i)
        if not ok then break end
        i = i + 1
        if name and name ~= "" then
            -- "VST3i: Serum (Xfer Records)" → type "VST3i" (i = instrument)
            local typ  = name:match("^(%w+):") or "FX"
            local disp = name:match("^%w+:%s*(.+)$") or name
            local is_inst = typ:sub(-1) == "i" and #typ > 1
            local base = is_inst and typ:sub(1, -2) or typ
            local root = is_inst and inst or eff

            local dirs = type_dirs[root]
            local tdir = dirs[base]
            if not tdir then
                tdir = newDir(base, root, 1)
                dirs[base] = tdir
                root.children[#root.children + 1] = tdir
            end
            local leaf = {
                kind = "fx", name = disp, lo_name = disp:lower(),
                lo_search = name:lower(),
                path = "fx|" .. name, full = name,
                is_dir = false, parent = tdir, depth = 2,
            }
            tdir.children[#tdir.children + 1] = leaf
            all_leaves[#all_leaves + 1] = leaf
        end
    end
    FXList.count = #all_leaves

    local function dirOrder(a, b)
        local ra = TYPE_RANK[a.name] or 99
        local rb = TYPE_RANK[b.name] or 99
        if ra ~= rb then return ra < rb end
        return a.lo_name < b.lo_name
    end
    local function leafOrder(a, b) return a.lo_name < b.lo_name end
    for _, root in ipairs({ eff, inst }) do
        table.sort(root.children, dirOrder)
        for _, tdir in ipairs(root.children) do
            table.sort(tdir.children, leafOrder)
        end
        if #root.children > 0 then
            roots[#roots + 1] = root
        end
    end
end

-- ---------------------------------------------------------------------------
-- Rows (flattened visible tree, or token-filtered leaves while searching)
-- ---------------------------------------------------------------------------
local function flatten(node, out)
    out[#out + 1] = node
    if node.is_dir and node.expanded then
        for _, ch in ipairs(node.children) do flatten(ch, out) end
    end
end

-- Same grammar as the file search: space-separated AND tokens over the
-- FULL name (type + vendor included), "-tok" excludes.
local function matchTokens(lo, text)
    for tok in text:gmatch("%S+") do
        if tok:sub(1, 1) == "-" then
            if #tok > 1 and lo:find(tok:sub(2), 1, true) then return false end
        elseif not lo:find(tok, 1, true) then
            return false
        end
    end
    return true
end

function FXList.Rows(search)
    FXList.Ensure()
    if search and search ~= "" then
        local lo = search:lower()
        if filter_text ~= lo or not filter_cache then
            filter_text = lo
            filter_cache = {}
            for _, leaf in ipairs(all_leaves) do
                if matchTokens(leaf.lo_search, lo) then
                    filter_cache[#filter_cache + 1] = leaf
                end
            end
        end
        return filter_cache
    end
    if not flat_cache then
        flat_cache = {}
        for _, root in ipairs(roots) do flatten(root, flat_cache) end
    end
    return flat_cache
end

function FXList.Expand(node)
    if node.is_dir and not node.expanded then
        node.expanded = true
        flat_cache = nil
    end
end

function FXList.Collapse(node)
    if node.is_dir and node.expanded then
        node.expanded = false
        flat_cache = nil
    end
end

function FXList.Toggle(node)
    if not node.is_dir then return end
    node.expanded = not node.expanded
    flat_cache = nil
end

-- Drop caches (rescan after plugin install: pass rebuild=true).
function FXList.Invalidate(rebuild)
    flat_cache, filter_cache, filter_text = nil, nil, nil
    if rebuild then
        roots = nil
        FXList.count = 0
    end
end

return FXList
