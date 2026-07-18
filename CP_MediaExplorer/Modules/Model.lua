-- CP_MediaExplorer — Model
-- File-system tree model: lazy enumeration, flattened visible rows,
-- background recursive indexer, token search, favorites/recents views.
--
-- Design rules (PERFORMANCE.md):
--   * The flattened `rows` array is rebuilt ONLY on structural events
--     (expand/collapse/root change/filter change) — never per frame.
--   * Directory enumeration happens lazily on first expand (FL Studio model)
--     or incrementally inside IndexStep() with a caller-supplied time budget.
--   * Nodes cache their lowercase name/relpath once at creation so search
--     never allocates per candidate.

local Model = {}

local r  -- reaper, injected by init()

-- ---------------------------------------------------------------------------
-- Audio file extensions (lowercase, no dot). Extendable via config.
-- ---------------------------------------------------------------------------
local DEFAULT_EXTS = {
    wav = true, aif = true, aiff = true, aifc = true, flac = true,
    mp3 = true, ogg = true, opus = true, wv = true, m4a = true,
    wma = true, mid = true, midi = true,
}

Model.exts = DEFAULT_EXTS

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
Model.roots       = {}     -- array of root nodes (user-pinned folders)
Model.rows        = {}     -- flattened visible rows (tree mode), array of nodes
Model.search_rows = {}     -- flat file rows while a search query is active
Model.by_path     = {}     -- path → node (every node ever created)
Model.favorites   = {}     -- path → true (persisted by the app)
Model.mode        = "tree" -- "tree" | "search" | "favorites" | "recents"

Model.file_count  = 0      -- audio files discovered so far (indexer + expands)
Model.dir_count   = 0

-- Search state
local search_tokens = {}   -- lowercase tokens (AND), "-tok" = exclusion
local search_query  = ""
local SEARCH_CAP    = 4000 -- hard cap on result rows (UI stays responsive)
Model.search_truncated = false

-- Indexer state (background recursive walk of all roots)
local index_stack   = nil  -- array used as a stack of dir nodes to enumerate
Model.indexing      = false
Model.indexed       = false -- true once a full walk completed

-- ---------------------------------------------------------------------------
-- Node helpers
-- ---------------------------------------------------------------------------
-- Node = {
--   name, lo_name       display name / lowercase
--   path                full path (parent.path .. "/" .. name)
--   lo_rel              lowercase path relative to its root (for token search)
--   is_dir, depth       depth: root = 0
--   parent              parent node (nil for roots)
--   children            array (dirs first, files after) or nil = not enumerated
--   expanded            dirs only
--   is_root             true for pinned roots
--   len, srate, ch      lazy media metadata (filled by the app on selection)
--   _lbl, _lbl_w        ellipsised label cache (owned by the UI layer)
-- }

local function newNode(name, parent, is_dir, root_rel)
    local path
    if parent then
        path = parent.path .. "/" .. name
    else
        path = name
    end
    local lo_name = name:lower()
    -- A detached node (favorites/recents/MediaDB) for this path may exist;
    -- the tree node supersedes it (views skip superseded nodes).
    local old = Model.by_path[path]
    if old and old.detached then old.superseded = true end
    local node = {
        name    = name,
        lo_name = lo_name,
        path    = path,
        lo_rel  = root_rel or lo_name,
        is_dir  = is_dir,
        depth   = parent and (parent.depth + 1) or 0,
        parent  = parent,
    }
    Model.by_path[path] = node
    return node
end

local function extOf(name)
    local e = name:match("%.([^.]+)$")
    return e and e:lower() or nil
end

Model.ExtOf = extOf

local function isAudioName(name)
    local e = extOf(name)
    return e ~= nil and Model.exts[e] == true
end

local function nodeSort(a, b)
    return a.lo_name < b.lo_name
end

-- ---------------------------------------------------------------------------
-- Enumeration (one directory, blocking — kept small by the lazy model)
-- ---------------------------------------------------------------------------
-- `force` = true re-reads the OS listing (EnumerateFiles caches per path;
-- index -1 invalidates the cache — REAPER 6.20+).
local function enumerate(node, force)
    if force then
        r.EnumerateFiles(node.path, -1)
        r.EnumerateSubdirectories(node.path, -1)
    end

    local dirs, files = {}, {}
    local i = 0
    while true do
        local name = r.EnumerateSubdirectories(node.path, i)
        if not name then break end
        if name:sub(1, 1) ~= "." then dirs[#dirs + 1] = name end
        i = i + 1
    end
    i = 0
    while true do
        local name = r.EnumerateFiles(node.path, i)
        if not name then break end
        if name:sub(1, 1) ~= "." and isAudioName(name) then
            files[#files + 1] = name
        end
        i = i + 1
    end

    table.sort(dirs)
    table.sort(files)

    local children = {}
    local prefix = (node.lo_rel ~= "" and node.lo_rel .. "/") or ""
    for k = 1, #dirs do
        local nm = dirs[k]
        children[#children + 1] = newNode(nm, node, true, prefix .. nm:lower())
    end
    Model.dir_count = Model.dir_count + #dirs

    local first_file = #children + 1
    for k = 1, #files do
        local nm = files[k]
        children[#children + 1] = newNode(nm, node, false, prefix .. nm:lower())
    end
    Model.file_count = Model.file_count + #files

    node.children   = children
    node.first_file = first_file  -- index of the first file child (dirs before)

    -- Live-append to active search results (keeps display order = traversal
    -- order without ever re-walking the whole tree during indexing).
    if Model.mode == "search" and #search_tokens > 0 then
        for k = first_file, #children do
            local c = children[k]
            if #Model.search_rows >= SEARCH_CAP then
                Model.search_truncated = true
                break
            end
            if Model.MatchTokens(c.lo_rel) then
                Model.search_rows[#Model.search_rows + 1] = c
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Roots
-- ---------------------------------------------------------------------------
function Model.init(reaper_api)
    r = reaper_api
end

-- Normalize a user-picked path: backslashes → slashes, strip trailing slash.
local function normPath(path)
    path = path:gsub("\\", "/")
    if path:sub(-1) == "/" and #path > 3 then path = path:sub(1, -2) end
    return path
end

Model.NormPath = normPath

-- Returns the new root node, or nil + reason.
function Model.AddRoot(path)
    path = normPath(path)
    for _, root in ipairs(Model.roots) do
        if root.path == path then return nil, "already added" end
    end
    -- Root display name = last path segment (fall back to the full path for
    -- drive roots like "C:/").
    local name = path:match("([^/]+)/?$") or path
    local node = newNode(path, nil, true, "")
    node.name    = name
    node.lo_name = name:lower()
    node.is_root = true
    Model.roots[#Model.roots + 1] = node
    Model.Rebuild()
    return node
end

function Model.RemoveRoot(node)
    for i, root in ipairs(Model.roots) do
        if root == node then
            table.remove(Model.roots, i)
            Model.Rebuild()
            return true
        end
    end
    return false
end

-- Re-read a directory from disk (Ctrl+R semantics). Drops the subtree so it
-- re-enumerates lazily; keeps the node expanded.
function Model.Refresh(node)
    if node and node.is_dir then
        node.children = nil
        enumerate(node, true)
        Model.Rebuild()
    end
end

-- ---------------------------------------------------------------------------
-- Expand / collapse
-- ---------------------------------------------------------------------------
function Model.Expand(node, accordion)
    if not node.is_dir or node.expanded then return end
    if not node.children then enumerate(node) end
    if accordion and node.parent and node.parent.children then
        for _, sib in ipairs(node.parent.children) do
            if sib ~= node then sib.expanded = false end
        end
    end
    node.expanded = true
    Model.Rebuild()
end

function Model.Collapse(node)
    if not node.is_dir or not node.expanded then return end
    node.expanded = false
    Model.Rebuild()
end

function Model.Toggle(node, accordion)
    if not node.is_dir then return end
    if node.expanded then Model.Collapse(node)
    else Model.Expand(node, accordion) end
end

function Model.CollapseAll()
    for _, node in pairs(Model.by_path) do
        node.expanded = false
    end
    Model.Rebuild()
end

-- ---------------------------------------------------------------------------
-- Flatten (tree mode rows)
-- ---------------------------------------------------------------------------
local function pushVisible(rows, node)
    rows[#rows + 1] = node
    if node.is_dir and node.expanded and node.children then
        local children = node.children
        for i = 1, #children do
            pushVisible(rows, children[i])
        end
    end
end

function Model.Rebuild()
    local rows = {}
    for _, root in ipairs(Model.roots) do
        pushVisible(rows, root)
    end
    Model.rows = rows
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------
-- Token grammar: space-separated terms are ANDed; a leading "-" excludes.
-- Matching is plain substring over the node's root-relative lowercase path,
-- so "kick 808 -loop" matches "808/Kicks/kick 03.wav".
function Model.MatchTokens(lo_rel)
    local tokens = search_tokens
    for i = 1, #tokens do
        local t = tokens[i]
        if t.neg then
            if lo_rel:find(t.s, 1, true) then return false end
        else
            if not lo_rel:find(t.s, 1, true) then return false end
        end
    end
    return true
end

-- Extra flat file pools searched alongside the tree (detached nodes from
-- the native Media Explorer databases). Superseded nodes are skipped —
-- their tree twin already covers them.
Model.db_files = {}

-- Full re-walk of everything already enumerated. One-off cost when the query
-- changes; new discoveries stream in via enumerate()'s live-append.
local function rebuildSearch()
    local rows = {}
    Model.search_truncated = false

    local function walk(node)
        if #rows >= SEARCH_CAP then
            Model.search_truncated = true
            return true
        end
        local children = node.children
        if not children then return false end
        -- dirs first (recurse), then files (match)
        for i = 1, (node.first_file or 1) - 1 do
            if walk(children[i]) then return true end
        end
        for i = (node.first_file or 1), #children do
            local c = children[i]
            if Model.MatchTokens(c.lo_rel) then
                rows[#rows + 1] = c
                if #rows >= SEARCH_CAP then
                    Model.search_truncated = true
                    return true
                end
            end
        end
        return false
    end

    for _, root in ipairs(Model.roots) do
        if walk(root) then break end
    end

    -- MediaDB pool (flat)
    if #rows < SEARCH_CAP then
        local db = Model.db_files
        for i = 1, #db do
            local node = db[i]
            if not node.superseded and Model.MatchTokens(node.lo_rel) then
                rows[#rows + 1] = node
                if #rows >= SEARCH_CAP then
                    Model.search_truncated = true
                    break
                end
            end
        end
    end

    Model.search_rows = rows
end

-- Register a file discovered in a native Media Explorer database. Streams
-- into active search results like enumerate()'s live-append.
function Model.AddDBFile(path)
    local existing = Model.by_path[path]
    if existing then return end            -- tree or another pool owns it
    local node = Model.PathNode(path)
    node.lo_rel = path:lower()
    Model.db_files[#Model.db_files + 1] = node
    if Model.mode == "search" and #search_tokens > 0
       and #Model.search_rows < SEARCH_CAP then
        if Model.MatchTokens(node.lo_rel) then
            Model.search_rows[#Model.search_rows + 1] = node
        end
    end
end

-- Returns true when the mode changed (UI resets scroll/selection).
function Model.SetSearch(query)
    query = query or ""
    if query == search_query then return false end
    search_query = query

    search_tokens = {}
    for w in query:lower():gmatch("%S+") do
        if w:sub(1, 1) == "-" and #w > 1 then
            search_tokens[#search_tokens + 1] = { s = w:sub(2), neg = true }
        elseif w:sub(1, 1) ~= "-" then
            search_tokens[#search_tokens + 1] = { s = w }
        end
    end

    if #search_tokens == 0 then
        Model.mode = "tree"
        Model.search_rows = {}
        return true
    end

    Model.mode = "search"
    rebuildSearch()
    -- Kick the indexer so results keep streaming in from unscanned folders.
    if not Model.indexed and not Model.indexing then
        Model.StartIndex()
    end
    return true
end

function Model.GetSearch() return search_query end

-- ---------------------------------------------------------------------------
-- Background indexer
-- ---------------------------------------------------------------------------
-- Walks every root recursively, enumerating one directory at a time inside
-- a caller-supplied time budget. Cooperative: the app calls IndexStep() from
-- its defer loop while Model.indexing is true.
function Model.StartIndex()
    index_stack = {}
    for _, root in ipairs(Model.roots) do
        index_stack[#index_stack + 1] = root
    end
    Model.indexing = #index_stack > 0
end

function Model.StopIndex()
    index_stack = nil
    Model.indexing = false
end

-- budget_s: wall-clock budget for this step (e.g. 0.004 = 4 ms).
-- Returns true while more work remains.
function Model.IndexStep(budget_s)
    if not Model.indexing or not index_stack then return false end
    local deadline = r.time_precise() + (budget_s or 0.004)
    local stack = index_stack

    while #stack > 0 do
        local node = table.remove(stack)
        if not node.children then enumerate(node) end
        local children = node.children
        for i = 1, (node.first_file or 1) - 1 do
            stack[#stack + 1] = children[i]
        end
        if r.time_precise() >= deadline then
            if #stack == 0 then break end
            return true
        end
    end

    index_stack    = nil
    Model.indexing = false
    Model.indexed  = true
    return false
end

-- ---------------------------------------------------------------------------
-- Favorites / recents views (flat file rows from persisted path lists)
-- ---------------------------------------------------------------------------
-- Paths may point outside the enumerated tree; a standalone node is created
-- so preview/insert (which only need .path) keep working.
local function pathNode(path)
    local node = Model.by_path[path]
    if node then return node end
    local name = path:match("([^/\\]+)$") or path
    node = {
        name    = name,
        lo_name = name:lower(),
        path    = path,
        lo_rel  = name:lower(),
        is_dir  = false,
        depth   = 0,
        detached = true,   -- not part of the tree
    }
    Model.by_path[path] = node
    return node
end

Model.PathNode = pathNode

function Model.ToggleFavorite(path)
    if Model.favorites[path] then
        Model.favorites[path] = nil
    else
        Model.favorites[path] = true
    end
end

function Model.IsFavorite(path)
    return Model.favorites[path] == true
end

-- Stable, sorted favorites view.
function Model.FavoriteRows()
    local rows = {}
    for path in pairs(Model.favorites) do
        -- "fx|" keys are plugin favorites (FX chip) — they are not files
        -- and must not become broken PathNodes in the files view.
        if path:sub(1, 3) ~= "fx|" then
            rows[#rows + 1] = pathNode(path)
        end
    end
    table.sort(rows, nodeSort)
    return rows
end

-- ---------------------------------------------------------------------------
-- Colored collections (Ableton-style, keys 1-7)
-- ---------------------------------------------------------------------------
Model.collections = { {}, {}, {}, {}, {}, {}, {} }  -- [k][path] = true
Model.coll_version = 0  -- bumped on any change (invalidates row bitmask caches)

function Model.ToggleCollection(k, path)
    local set = Model.collections[k]
    if not set then return end
    set[path] = (not set[path]) and true or nil
    Model.coll_version = Model.coll_version + 1
end

function Model.ClearCollections(path)
    for k = 1, 7 do
        Model.collections[k][path] = nil
    end
    Model.coll_version = Model.coll_version + 1
end

-- Membership bitmask (bit k-1 = collection k), cached per node against the
-- global collection version so row drawing costs one comparison per frame.
function Model.CollectionMask(node)
    if node._cmask_v == Model.coll_version then return node._cmask end
    local mask = 0
    local path = node.path
    for k = 1, 7 do
        if Model.collections[k][path] then
            mask = mask | (1 << (k - 1))
        end
    end
    node._cmask   = mask
    node._cmask_v = Model.coll_version
    return mask
end

function Model.CollectionRows(k)
    local rows = {}
    local set = Model.collections[k]
    if set then
        for path in pairs(set) do
            if path:sub(1, 3) ~= "fx|" then  -- see Model.FavoriteRows
                rows[#rows + 1] = pathNode(path)
            end
        end
        table.sort(rows, nodeSort)
    end
    return rows
end

-- recents = array of paths, most recent first (owned by the app).
function Model.RecentRows(recents)
    local rows = {}
    for _, path in ipairs(recents) do
        rows[#rows + 1] = pathNode(path)
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Row queries (used by the UI for navigation & the sticky header)
-- ---------------------------------------------------------------------------
-- The nearest ancestor whose children contain this row — i.e. the folder the
-- row "belongs to". For the sticky header.
function Model.RowParentDir(node)
    if not node then return nil end
    return node.parent
end

-- Find a node's index in an array of rows (linear — call on events only).
function Model.IndexOf(rows, node)
    for i = 1, #rows do
        if rows[i] == node then return i end
    end
    return nil
end

return Model
