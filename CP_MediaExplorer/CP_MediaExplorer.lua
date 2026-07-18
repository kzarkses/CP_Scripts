-- @description Media Explorer (CP) — FL-style sample browser
-- @version 0.9
-- @author Cedric Pamalio
-- @about
--   FL Studio-style media explorer on CP_Toolkit: one inline expanding tree
--   for all pinned folders, zero-latency audition (selection = preview),
--   keyboard-first navigation, waveform strip with click-to-seek, insert at
--   edit cursor / drag to arrange, favorites, token search over a
--   background-built index, and hot-swap into the selected arrange item.
--
--   Requires SWS (CF_Preview) for audition. js_ReaScriptAPI recommended
--   (folder picker, drag-to-arrange hit-testing).
--
--   Keys: Up/Down move+play · Right expand/replay · Left collapse/parent
--   Enter insert · Space transport (option) · Ctrl+Up/Down folder skim
--   F favorite · Q hot-swap session · Ctrl+F search · Ctrl+R rescan
--   Esc clear search / cancel hot-swap

local r = reaper

-- ---------------------------------------------------------------------------
-- Toolkit + modules
-- ---------------------------------------------------------------------------
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local UI = dofile(r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua")

local Model   = dofile(script_path .. "Modules/Model.lua")
local Preview = dofile(script_path .. "Modules/Preview.lua")
local Insert  = dofile(script_path .. "Modules/Insert.lua")
local Peaks   = dofile(script_path .. "Modules/Peaks.lua")
local MediaDB = dofile(script_path .. "Modules/MediaDB.lua")
local FXList  = dofile(script_path .. "Modules/FXList.lua")
local DragBus = dofile(r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/DragBus.lua")

Model.init(r)
Preview.init(r)
Insert.init(r)
Peaks.init(r)
MediaDB.init(r)
FXList.init(r)
DragBus.init(r)

-- MediaDB streams file paths into the model (hoisted: one closure, not one
-- per frame).
local function dbSink(path)
    Model.AddDBFile(Model.NormPath(path))
end

local Core_tk = UI.Core
local Keys    = UI.Keys

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local CONFIG_ID = "CP_MediaExplorer"
local cfg = UI.LoadConfig(CONFIG_ID) or {}

local state = {
    chip      = "tree",           -- "tree" | "favorites" | "recents"
    search    = "",
    sel_idx   = 0,
    sel_node  = nil,
    recents   = cfg.recents or {},
    fav_rows  = nil,              -- cached view rows (rebuilt on events)
    rec_rows  = nil,
    scroll_to = nil,              -- pending scroll-to-row index
    flash_msg = "",
    flash_until = 0,
    cfg_dirty = false,
    -- custom drag (out-of-window drop onto the arrange)
    drag_pending = nil,           -- {node, mx, my}
    drag = nil,                   -- {node, label}
    -- hot-swap mode: while true, selecting a file swaps it into the
    -- selected arrange item (each swap = one undo point)
    swap_mode = false,
    -- waveform strip section selection
    wsel = nil,                   -- {path, a, b} normalized 0..1
    wpress = nil,                 -- transient strip press {x, frac, dragging}
    -- one-shot list scroll restore (applied once the list child exists)
    scroll_restore = cfg.list_scroll,
    wsel_prog = nil,              -- last observed preview progress (section bound)
    fx_rows = nil,                -- cached FX-chip rows (rebuilt on events)
    -- audition deferred to mouse RELEASE: a press that becomes a drag must
    -- stay silent (a started-then-cut preview is a parasite blip)
    click_audition = nil,         -- node to audition when the click releases
}

local opts = {
    autoplay         = cfg.autoplay ~= false,          -- default true
    accordion        = cfg.accordion == true,
    space_transport  = cfg.space_transport ~= false,   -- default true
    tempo_sync       = cfg.tempo_sync == true,
    route_track      = cfg.route_track == true,
    carry_volume     = cfg.carry_volume == true,
    carry_rate_pitch = cfg.carry_rate_pitch == true,
    use_mediadb      = cfg.use_mediadb ~= false,       -- default true
    sync_mult        = cfg.sync_mult or 1.0,           -- tempo-match ×0.5/×1/×2
    wave_rows        = cfg.wave_rows == true,          -- FL "Samples view"
    swap_resize      = cfg.swap_resize == true,        -- hot-swap takes new length
}

Preview.volume      = cfg.volume or 1.0
Preview.pitch       = cfg.pitch or 0
Preview.rate        = cfg.rate or 1.0
Preview.loop        = cfg.loop == true
Preview.route_track = opts.route_track
Insert.carry_volume     = opts.carry_volume
Insert.carry_rate_pitch = opts.carry_rate_pitch
Insert.swap_resize      = opts.swap_resize

-- Restore favorites / collections / roots / expansion
if type(cfg.favorites) == "table" then
    for _, path in ipairs(cfg.favorites) do Model.favorites[path] = true end
end
if type(cfg.collections) == "table" then
    for k = 1, 7 do
        local arr = cfg.collections[k]
        if type(arr) == "table" then
            local set = Model.collections[k]
            for _, path in ipairs(arr) do set[path] = true end
        end
    end
    Model.coll_version = Model.coll_version + 1
end
if type(cfg.roots) == "table" then
    for _, path in ipairs(cfg.roots) do Model.AddRoot(path) end
end
if type(cfg.expanded) == "table" then
    -- Parents first (shorter paths), capped so a huge saved session can't
    -- turn startup into a scan marathon.
    local exp = {}
    for i = 1, math.min(#cfg.expanded, 120) do exp[i] = cfg.expanded[i] end
    table.sort(exp, function(a, b) return #a < #b end)
    for _, path in ipairs(exp) do
        local node = Model.by_path[path]
        if node and node.is_dir then
            pcall(Model.Expand, node, false)
        end
    end
end

local function persistConfig()
    -- List scroll offset (restored one-shot at next boot).
    local list_data = Core_tk.GetWidgetSubData("child", "mx_list")
    local list_scroll = list_data and list_data.scroll_y or 0
    local favs = {}
    for path in pairs(Model.favorites) do favs[#favs + 1] = path end
    table.sort(favs)
    local colls = {}
    for k = 1, 7 do
        local arr = {}
        for path in pairs(Model.collections[k]) do arr[#arr + 1] = path end
        table.sort(arr)
        colls[k] = arr
    end
    local roots = {}
    for _, root in ipairs(Model.roots) do roots[#roots + 1] = root.path end
    local expanded = {}
    for path, node in pairs(Model.by_path) do
        if node.expanded and #expanded < 200 then
            expanded[#expanded + 1] = path
        end
    end
    UI.SaveConfig(CONFIG_ID, {
        roots       = roots,
        favorites   = favs,
        collections = colls,
        recents     = state.recents,
        expanded    = expanded,
        autoplay         = opts.autoplay,
        accordion        = opts.accordion,
        space_transport  = opts.space_transport,
        tempo_sync       = opts.tempo_sync,
        route_track      = opts.route_track,
        carry_volume     = opts.carry_volume,
        carry_rate_pitch = opts.carry_rate_pitch,
        use_mediadb      = opts.use_mediadb,
        sync_mult        = opts.sync_mult,
        wave_rows        = opts.wave_rows,
        swap_resize      = opts.swap_resize,
        list_scroll      = list_scroll,
        volume = Preview.volume,
        pitch  = Preview.pitch,
        rate   = Preview.rate,
        loop   = Preview.loop,
    })
    state.cfg_dirty = false
end

local function markDirty() state.cfg_dirty = true end

local function flash(msg)
    state.flash_msg   = msg
    state.flash_until = r.time_precise() + 2.5
end

-- ---------------------------------------------------------------------------
-- Rows (current view)
-- ---------------------------------------------------------------------------
-- Collection chip index: "coll1".."coll7" → 1..7
local COLL_INDEX = { coll1 = 1, coll2 = 2, coll3 = 3, coll4 = 4,
                     coll5 = 5, coll6 = 6, coll7 = 7 }

local function rowsNow()
    if state.chip == "fx" then
        -- Plugin tree (own search: the FX chip filters plugins, not files)
        if not state.fx_rows then state.fx_rows = FXList.Rows(state.search) end
        return state.fx_rows
    end
    if Model.mode == "search" then return Model.search_rows end
    if state.chip == "favorites" then
        if not state.fav_rows then state.fav_rows = Model.FavoriteRows() end
        return state.fav_rows
    end
    if state.chip == "recents" then
        if not state.rec_rows then state.rec_rows = Model.RecentRows(state.recents) end
        return state.rec_rows
    end
    local ck = COLL_INDEX[state.chip]
    if ck then
        if not state.coll_rows or state.coll_rows_k ~= ck then
            state.coll_rows   = Model.CollectionRows(ck)
            state.coll_rows_k = ck
        end
        return state.coll_rows
    end
    return Model.rows
end

local function invalidateViews()
    state.fav_rows  = nil
    state.rec_rows  = nil
    state.coll_rows = nil
    state.fx_rows   = nil
end

-- Expand/collapse dispatch: FX nodes belong to FXList, not the FS model.
local function nodeExpand(node)
    if node.kind == "fx" then
        FXList.Expand(node)
        state.fx_rows = nil
    else
        Model.Expand(node, opts.accordion)
    end
end

local function nodeCollapse(node)
    if node.kind == "fx" then
        FXList.Collapse(node)
        state.fx_rows = nil
    else
        Model.Collapse(node)
    end
end

local function nodeToggle(node)
    if node.kind == "fx" then
        FXList.Toggle(node)
        state.fx_rows = nil
    else
        Model.Toggle(node, opts.accordion)
    end
end

local function pushRecent(path)
    local out = { path }
    for _, p in ipairs(state.recents) do
        if p ~= path and #out < 50 then out[#out + 1] = p end
    end
    state.recents = out
    state.rec_rows = nil
    markDirty()
end

-- ---------------------------------------------------------------------------
-- Metadata (one-time per node, on selection)
-- ---------------------------------------------------------------------------
local function loadMeta(node)
    if node.is_dir or node._info then return end
    local len, ch, sr = Preview.Meta(node.path)
    if not len then
        node._info = "unreadable"
        return
    end
    node.len, node.ch, node.srate = len, ch, sr
    local ext = (Model.ExtOf(node.name) or "?"):upper()
    if sr == 0 then
        node._info = ext .. "  ·  MIDI"
    else
        local mins = math.floor(len / 60)
        local secs = len - mins * 60
        node._info = string.format("%s  ·  %.1fk  ·  %dch  ·  %d:%05.2f",
                                   ext, sr / 1000, ch, mins, secs)
    end
end

-- ---------------------------------------------------------------------------
-- Preview / selection
-- ---------------------------------------------------------------------------
-- Snapshot of the preview settings an insert should carry. With tempo-sync
-- on, the matched rate is ALWAYS applied to the inserted take (native ME
-- "apply tempo matching" behavior), independent of the carry option.
local function previewState(node)
    local ps = { rate = Preview.rate, pitch = Preview.pitch, volume = Preview.volume }
    if opts.tempo_sync and node and not node.is_dir then
        ps.force_rate = Preview.TempoSyncRate(node.path, opts.sync_mult)
    end
    -- Active strip section for this file → insert only that portion.
    if state.wsel and node and state.wsel.path == node.path then
        loadMeta(node)
        if node.len and node.len > 0 then
            ps.section = {
                offs = state.wsel.a * node.len,
                len  = (state.wsel.b - state.wsel.a) * node.len,
            }
        end
    end
    return ps
end

-- Mouse position → 0..1 fraction across the waveform strip (module-level:
-- a closure re-created inside drawWave would allocate every frame).
local function stripFrac(x, dw)
    local mx = Core_tk.GetMousePos()
    local frac = (mx - x - 1) / dw
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return frac
end

-- Drag-ghost label for a section drag (built once at drag promotion — never
-- in the frame loop).
local function sectionDragLabel(node)
    local ws = state.wsel
    if ws and ws.path == node.path and node.len and node.len > 0 then
        return string.format("+ %s  [%.2fs – %.2fs]",
                             node.name, ws.a * node.len, ws.b * node.len)
    end
    return "+ " .. node.name
end

-- Hot-swap: replace the selected arrange item's source (one undo point per
-- swap; REAPER undo is the revert path).
local function swapTo(path)
    if not Insert.SwapOneShot(path) then
        flash("Hot-swap: select an audio item in the arrange")
        return false
    end
    return true
end

-- frac: optional 0..1 start position within the file.
local function doPreview(node, frac)
    if not node or node.is_dir or node.kind == "fx" then return end
    loadMeta(node)
    state.wsel_prog = nil  -- fresh playback: no stale section-bound crossing

    if state.swap_mode then
        swapTo(node.path)
        -- Transport running → you hear the swap in context. Stopped → fall
        -- through so the preview engine makes the selection audible anyway.
        if (r.GetPlayState() & 1) == 1 then return end
    end

    local rate_override = nil
    if opts.tempo_sync then
        rate_override = Preview.TempoSyncRate(node.path, opts.sync_mult)
    end
    local position = nil
    if frac and node.len and node.len > 0 then
        local rate = rate_override or Preview.rate
        if rate <= 0 then rate = 1 end
        position = frac * node.len / rate
    end
    Preview.Play(node.path, { position = position, rate_override = rate_override })
end

-- Select row i in the current view. flags: { preview=bool, scroll=bool }
local function selectRow(i, flags)
    local rows = rowsNow()
    local n = #rows
    if n == 0 then
        state.sel_idx, state.sel_node = 0, nil
        return
    end
    if i < 1 then i = 1 elseif i > n then i = n end
    state.sel_idx  = i
    local node = rows[i]
    state.sel_node = node

    -- The strip section belongs to one file; drop it when moving away.
    if state.wsel and (node.is_dir or state.wsel.path ~= node.path) then
        state.wsel = nil
    end

    if not node.is_dir and node.kind ~= "fx" then
        loadMeta(node)
        if (not flags or flags.preview ~= false) and opts.autoplay then
            doPreview(node)
        end
        -- Prefetch neighbors so arrow-keying never waits on file-open.
        local up, down = rows[i - 1], rows[i + 1]
        if up and not up.is_dir and up.kind ~= "fx" then Preview.Prefetch(up.path) end
        if down and not down.is_dir and down.kind ~= "fx" then Preview.Prefetch(down.path) end
    end

    if not flags or flags.scroll ~= false then
        state.scroll_to = i
    end
end

local function insertNode(node, new_track)
    if not node or node.is_dir then return end

    -- Plugins: add to the selected track's chain (or a new track).
    if node.kind == "fx" then
        local ok
        if new_track then
            ok = Insert.AddFXNewTrack(node.full, node.name)
        else
            local track = r.GetSelectedTrack(0, 0)
            if track then
                ok = Insert.AddFX(node.full, track)
            else
                ok = Insert.AddFXNewTrack(node.full, node.name)
            end
        end
        flash((ok and "Added FX: " or "Add FX failed: ") .. node.name)
        return
    end

    local item
    if new_track then
        item = Insert.OnNewTrack(node.path, previewState(node))
    else
        item = Insert.AtCursor(node.path, previewState(node))
    end
    if item then
        pushRecent(node.path)
        flash("Inserted: " .. node.name)
    else
        flash("Insert failed: " .. node.name)
    end
end

-- ---------------------------------------------------------------------------
-- Folder skim (Ctrl+Up/Down — Resonic): jump to the next/prev directory row
-- and play its first file.
-- ---------------------------------------------------------------------------
local function folderSkim(direction)
    local rows = rowsNow()
    if #rows == 0 then return end
    local i = state.sel_idx > 0 and state.sel_idx or 1
    local j = i + direction
    while j >= 1 and j <= #rows do
        if rows[j].is_dir then
            selectRow(j, { preview = false })
            local dir = rows[j]
            if not dir.expanded then
                nodeExpand(dir)
            end
            -- First file child (children are dirs-first).
            if dir.children and dir.first_file and dir.children[dir.first_file] then
                local target = dir.children[dir.first_file]
                local rows2 = rowsNow()
                local ti = Model.IndexOf(rows2, target)
                if ti then selectRow(ti) end
            end
            return
        end
        j = j + direction
    end
end

-- ---------------------------------------------------------------------------
-- Programmatic list scroll (set before BeginChild draws the list)
-- ---------------------------------------------------------------------------
local LIST_ID = "mx_list"

local function applyScrollTo(row_h, list_h)
    if not state.scroll_to then return end
    local data = Core_tk.GetWidgetSubData("child", LIST_ID)
    -- The child initializes its scroll state on first draw — keep the
    -- request pending until then (BeginChild would clobber our write).
    if not data or data._init == nil then return end
    local i = state.scroll_to
    state.scroll_to = nil
    local row_top = (i - 1) * row_h
    local row_bot = row_top + row_h
    local scroll  = data.scroll_y or 0
    -- Keep the target below the sticky ancestor stack (its height equals the
    -- target's ancestor count in tree mode), plus one row of context.
    local stack_h = 0
    if Model.mode == "tree" and state.chip == "tree" then
        local node = rowsNow()[i]
        if node then
            local d = node.depth
            if d > 6 then d = 6 end
            stack_h = d * row_h
        end
    end
    if row_top < scroll + stack_h + row_h then
        data.scroll_y = math.max(0, row_top - stack_h - row_h)
    elseif row_bot > scroll + list_h then
        data.scroll_y = row_bot - list_h
    end
end

-- ---------------------------------------------------------------------------
-- Keyboard grammar
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Random pick (FL "surprise me"): R = jump + audition, Shift+R = + insert.
-- In hot-swap mode, R random-swaps the selected arrange item (sound design
-- roulette). Scope: the selection's folder in tree view (visible children),
-- otherwise the whole current view; empty scopes fall back to the view.
-- ---------------------------------------------------------------------------
math.randomseed(math.floor(r.time_precise() * 1000000) % 2147483647)

local function isUnder(node, ancestor)
    local p = node.parent
    while p do
        if p == ancestor then return true end
        p = p.parent
    end
    return false
end

-- Random FILE row index in rows[lo..hi] (two passes, no allocation).
local function randomFileIn(rows, lo, hi)
    local n = 0
    for i = lo, hi do
        if not rows[i].is_dir then n = n + 1 end
    end
    if n == 0 then return nil end
    local k = math.random(n)
    for i = lo, hi do
        if not rows[i].is_dir then
            k = k - 1
            if k == 0 then return i end
        end
    end
    return nil
end

-- folder: optional dir node forcing the scope (row context menu).
local function randomJump(also_insert, folder)
    local rows = rowsNow()
    if #rows == 0 then return end

    local lo, hi = 1, #rows
    if not folder and Model.mode ~= "search" and state.chip == "tree"
       and state.sel_node then
        local sel = state.sel_node
        folder = sel.is_dir and sel or sel.parent
    end
    if folder then
        local fi = Model.IndexOf(rows, folder)
        if fi then
            local last = fi
            for i = fi + 1, #rows do
                if not isUnder(rows[i], folder) then break end
                last = i
            end
            if last > fi then lo, hi = fi + 1, last end
        end
    end

    local i = randomFileIn(rows, lo, hi)
    if not i and (lo > 1 or hi < #rows) then
        i = randomFileIn(rows, 1, #rows)  -- empty folder → whole view
    end
    if not i then
        flash("Random: no files in view")
        return
    end
    selectRow(i)  -- audition (and hot-swap in swap mode) + scroll
    if also_insert then insertNode(rows[i], false) end
end

local function handleKeys()
    if Core_tk.HasPopup() then return end
    local char = Core_tk.GetChar()
    if not char or char <= 0 then return end

    -- Any focused widget (search box, inline numeric edit…) owns the
    -- keyboard — the browser grammar stays out of the way.
    local focus = Core_tk.GetState().focus
    if focus then
        -- Down from the search box drops into the results (Ableton flow).
        if focus == "mx_search" and char == Keys.DOWN then
            Core_tk.SetFocus(nil)
            selectRow(state.sel_idx > 0 and state.sel_idx or 1)
        end
        return
    end

    -- Ctrl+F → focus search (works from anywhere in the window).
    if char == 6 then  -- Ctrl+F control code
        UI.SetFocus("mx_search")
        UI.ConsumeChar()
        return
    end

    local rows = rowsNow()
    local node = state.sel_node
    local ctrl = Core_tk.ModCtrl()

    if char == Keys.DOWN then
        if ctrl then folderSkim(1) else selectRow(state.sel_idx + 1) end
        UI.ConsumeChar()
    elseif char == Keys.UP then
        if ctrl then folderSkim(-1) else selectRow(state.sel_idx - 1) end
        UI.ConsumeChar()
    elseif char == Keys.PAGE_DOWN then
        selectRow(state.sel_idx + 20)
        UI.ConsumeChar()
    elseif char == Keys.PAGE_UP then
        selectRow(state.sel_idx - 20)
        UI.ConsumeChar()
    elseif char == Keys.HOME then
        selectRow(1)
        UI.ConsumeChar()
    elseif char == Keys.END then
        selectRow(#rows)
        UI.ConsumeChar()
    elseif char == Keys.RIGHT then
        if node and node.is_dir then
            if node.expanded then
                -- Step into the folder: select its first child row.
                selectRow(state.sel_idx + 1)
            else
                nodeExpand(node)
                invalidateViews()
            end
        elseif node then
            doPreview(node)  -- replay from start
        end
        UI.ConsumeChar()
    elseif char == Keys.LEFT then
        if node and node.is_dir and node.expanded then
            nodeCollapse(node)
        elseif node and node.parent then
            local pi = Model.IndexOf(rows, node.parent)
            if pi then selectRow(pi, { preview = false }) end
        end
        UI.ConsumeChar()
    elseif char == Keys.BACKSPACE then
        if node and node.parent then
            local pi = Model.IndexOf(rows, node.parent)
            if pi then selectRow(pi, { preview = false }) end
        end
        UI.ConsumeChar()
    elseif char == Keys.ENTER then
        if node and node.is_dir then
            nodeToggle(node)
        elseif node then
            insertNode(node, false)
        end
        UI.ConsumeChar()
    elseif char == Keys.SPACE then
        if opts.space_transport then
            r.Main_OnCommand(40044, 0)  -- Transport: Play/stop
        else
            if Preview.IsPlaying() then Preview.Stop()
            elseif node and not node.is_dir then doPreview(node) end
        end
        UI.ConsumeChar()
    elseif char == Keys.F then
        if node and not node.is_dir then
            Model.ToggleFavorite(node.path)
            invalidateViews()
            markDirty()
        end
        UI.ConsumeChar()
    elseif char >= 49 and char <= 55 then  -- 1-7: toggle colored collection
        if node and not node.is_dir then
            Model.ToggleCollection(char - 48, node.path)
            invalidateViews()
            markDirty()
        end
        UI.ConsumeChar()
    elseif char == 48 then                 -- 0: clear collections
        if node and not node.is_dir then
            Model.ClearCollections(node.path)
            invalidateViews()
            markDirty()
        end
        UI.ConsumeChar()
    elseif char == Keys.Q then
        if state.swap_mode then
            state.swap_mode = false
            flash("Hot-swap mode off")
        elseif r.GetSelectedMediaItem(0, 0) then
            state.swap_mode = true
            flash("Hot-swap mode: selection replaces the selected item (Q/Esc exit)")
            if node and not node.is_dir then swapTo(node.path) end
        else
            flash("Hot-swap: select an audio item in the arrange first")
        end
        UI.ConsumeChar()
    elseif char == Keys.R then  -- random file (selection's folder / view)
        randomJump(false)
        UI.ConsumeChar()
    elseif char == 82 then      -- Shift+R: random + insert at edit cursor
        randomJump(true)
        UI.ConsumeChar()
    elseif char == 18 then  -- Ctrl+R control code
        local target = node
        while target and not target.is_dir do target = target.parent end
        if target then
            Model.Refresh(target)
            flash("Rescanned: " .. target.name)
        end
        UI.ConsumeChar()
    elseif char == Keys.ESCAPE then
        if state.swap_mode then
            state.swap_mode = false
            flash("Hot-swap mode off")
            UI.ConsumeChar()
        elseif state.search ~= "" then
            state.search = ""
            Model.SetSearch("")
            selectRow(state.sel_idx, { preview = false })
            UI.ConsumeChar()
        end
        -- otherwise fall through to the toolkit's layered ESC (close window)
    end
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------
-- Hoisted per-frame opts tables (PERFORMANCE.md rule 1: no table literals in
-- the frame loop — widgets consume opts synchronously, mutation is safe).
local ICONBTN_OPTS = { width = 0, height = 0 }
local SEARCH_OPTS  = { hint = "Search (kick 808 -loop)…", width = 120 }
local VOL_OPTS     = { width = 110 }
local PITCH_OPTS   = { step = 1, format = "%.0f st", width = 62 }
local RATE_OPTS    = { step = 0.05, format = "%.2fx", width = 62 }
local LIST_OPTS    = { scrollable = true, border = false, padding = 0,
                       spacing = 0, bg = nil }

local function iconBtn(id, icon_fn, tip, size)
    local theme = UI.GetTheme()
    size = size or theme.button_height
    local cx, cy = UI.GetCursorPos()
    ICONBTN_OPTS.width, ICONBTN_OPTS.height = size, size
    local clicked = UI.Button(id, "", ICONBTN_OPTS)
    local color = theme.colors.text
    icon_fn(cx, cy, size, color[1], color[2], color[3], color[4] or 1)
    if tip and Core_tk.MouseInRect(cx, cy, size, size) then UI.Tooltip(tip) end
    return clicked
end

local function iconToggle(id, icon_fn, tip, on, size)
    local theme = UI.GetTheme()
    size = size or theme.button_height
    local cx, cy = UI.GetCursorPos()
    local bg = on and theme.colors.accent or theme.colors.button
    local hov = Core_tk.MouseInRect(cx, cy, size, size) and not Core_tk.HasPopup()
    if hov and not on then bg = theme.colors.button_hovered end
    Core_tk.DrawRect(cx, cy, size, size, bg[1], bg[2], bg[3], bg[4] or 1)
    local fg = on and theme.colors.list_selected_text or theme.colors.text
    icon_fn(cx, cy, size, fg[1], fg[2], fg[3], fg[4] or 1)
    UI.Layout.AdvanceCursor(size, size)
    if hov and tip then UI.Tooltip(tip) end
    return hov and Core_tk.MouseClicked(1)
end

-- Ellipsised row label: toolkit-memoized truncation (Core.TruncateText probes
-- with raw measurestr — no measure-cache pollution) + a per-node fast path.
local function rowLabel(node, max_w)
    max_w = math.floor(max_w)
    if node._lbl and node._lbl_maxw == max_w then return node._lbl end
    local text = Core_tk.TruncateText(node.name, max_w)
    node._lbl      = text
    node._lbl_maxw = max_w
    return text
end

-- Dir child-count caption, cached per enumeration.
local function dirCount(node)
    if not node.children then return nil end
    if node._cnt and node._cnt_n == #node.children then return node._cnt end
    node._cnt_n = #node.children
    node._cnt = tostring(#node.children)
    return node._cnt
end

-- ---------------------------------------------------------------------------
-- Root management
-- ---------------------------------------------------------------------------
local function addRootDialog()
    local path = nil
    if r.JS_Dialog_BrowseForFolder then
        local ok, folder = r.JS_Dialog_BrowseForFolder("Add folder to Media Explorer", "")
        if ok == 1 and folder and folder ~= "" then path = folder end
    else
        local ok, csv = r.GetUserInputs("Add folder", 1, "Folder path:,extrawidth=260", "")
        if ok and csv ~= "" then path = csv end
    end
    if not path then return end
    local node, err = Model.AddRoot(path)
    if node then
        Model.Expand(node, false)
        flash("Added: " .. node.name)
        markDirty()
    else
        flash("Not added: " .. (err or "?"))
    end
end

-- OS drag-drop INTO the window: folders become roots.
local function handleFileDrops()
    local ok, fn = gfx.getdropfile(0)
    if ok == 0 or not fn or fn == "" then return end
    local i = 0
    while true do
        local got, path = gfx.getdropfile(i)
        if got == 0 or not path or path == "" then break end
        if not r.file_exists(path) then      -- not a file → assume folder
            if Model.AddRoot(path) then
                flash("Added: " .. path)
                markDirty()
            end
        end
        i = i + 1
    end
    gfx.getdropfile(-1)
end

-- ---------------------------------------------------------------------------
-- Settings menu
-- ---------------------------------------------------------------------------
local function openSettings()
    UI.NativeMenu({
        { label = "Autoplay on selection", checked = opts.autoplay,
          action = function() opts.autoplay = not opts.autoplay; markDirty() end },
        { label = "Waveform rows (Samples view)", checked = opts.wave_rows,
          action = function() opts.wave_rows = not opts.wave_rows; markDirty() end },
        { label = "Accordion folders (auto-collapse siblings)", checked = opts.accordion,
          action = function() opts.accordion = not opts.accordion; markDirty() end },
        { label = "Space controls REAPER transport", checked = opts.space_transport,
          action = function() opts.space_transport = not opts.space_transport; markDirty() end },
        { label = "Tempo-match preview && insert", checked = opts.tempo_sync,
          action = function() opts.tempo_sync = not opts.tempo_sync; markDirty() end },
        { label = "Tempo-match multiplier", children = {
            { label = "×0.5", checked = opts.sync_mult == 0.5,
              action = function() opts.sync_mult = 0.5; markDirty() end },
            { label = "×1",   checked = opts.sync_mult == 1.0,
              action = function() opts.sync_mult = 1.0; markDirty() end },
            { label = "×2",   checked = opts.sync_mult == 2.0,
              action = function() opts.sync_mult = 2.0; markDirty() end },
        } },
        { label = "Hot-swap mode (selection replaces selected item)",
          checked = state.swap_mode,
          action = function() state.swap_mode = not state.swap_mode end },
        { label = "Hot-swap resizes item to new length", checked = opts.swap_resize,
          action = function()
              opts.swap_resize = not opts.swap_resize
              Insert.swap_resize = opts.swap_resize
              markDirty()
          end },
        { label = "Route preview through selected track", checked = opts.route_track,
          action = function()
              opts.route_track = not opts.route_track
              Preview.route_track = opts.route_track
              markDirty()
          end },
        { separator = true },
        { label = "Apply preview volume on insert", checked = opts.carry_volume,
          action = function()
              opts.carry_volume = not opts.carry_volume
              Insert.carry_volume = opts.carry_volume
              markDirty()
          end },
        { label = "Apply pitch/rate on insert", checked = opts.carry_rate_pitch,
          action = function()
              opts.carry_rate_pitch = not opts.carry_rate_pitch
              Insert.carry_rate_pitch = opts.carry_rate_pitch
              markDirty()
          end },
        { separator = true },
        { label = "Search native ME databases", checked = opts.use_mediadb,
          action = function() opts.use_mediadb = not opts.use_mediadb; markDirty() end },
        { label = "Load ME databases now",
          action = function() MediaDB.Start() end },
        { label = "Index all folders now",
          action = function() Model.StartIndex() end },
        { label = "Collapse all folders",
          action = function()
              Model.CollapseAll()
              selectRow(1, { preview = false })
              markDirty()
          end },
    })
end

-- ---------------------------------------------------------------------------
-- Row context menu
-- ---------------------------------------------------------------------------
local function openRowMenu(node)
    -- Plugin rows (FX chip): add / favorite — no file operations.
    if node.kind == "fx" then
        if node.is_dir then
            UI.NativeMenu({
                { label = node.expanded and "Collapse" or "Expand",
                  action = function() nodeToggle(node) end },
            })
        else
            UI.NativeMenu({
                { label = "Add to selected track",
                  action = function() insertNode(node, false) end },
                { label = "Add on new track",
                  action = function() insertNode(node, true) end },
                { separator = true },
                { label = Model.IsFavorite(node.path)
                          and "★ Remove favorite" or "☆ Add to favorites",
                  action = function()
                      Model.ToggleFavorite(node.path)
                      invalidateViews()
                      markDirty()
                  end },
            })
        end
        return
    end

    local items = {}
    if node.is_dir then
        items[#items + 1] = { label = node.expanded and "Collapse" or "Expand",
            action = function() Model.Toggle(node, opts.accordion) end }
        items[#items + 1] = { label = "Rescan folder",
            action = function() Model.Refresh(node); node._cnt = nil end }
        items[#items + 1] = { label = "Random from this folder",
            action = function()
                if not node.expanded then Model.Expand(node, opts.accordion) end
                randomJump(false, node)
            end }
        if node.is_root then
            items[#items + 1] = { separator = true }
            items[#items + 1] = { label = "Remove from browser",
                action = function()
                    Model.RemoveRoot(node)
                    state.sel_idx, state.sel_node = 0, nil
                    markDirty()
                end }
        end
    else
        items[#items + 1] = { label = "Insert at edit cursor",
            action = function() insertNode(node, false) end }
        items[#items + 1] = { label = "Insert on new track",
            action = function() insertNode(node, true) end }
        items[#items + 1] = { label = "Hot-swap into selected item",
            action = function()
                if swapTo(node.path) then
                    flash("Swapped into selected item: " .. node.name)
                end
            end }
        items[#items + 1] = { label = "Open in Editor",
            action = function()
                -- Picked up by CP_Editor when it runs (5s window).
                r.SetExtState("CP_Editor", "open",
                              string.format("%.3f\n%s", r.time_precise(),
                                            node.path), false)
            end }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { label = Model.IsFavorite(node.path)
                                      and "★ Remove favorite" or "☆ Add to favorites",
            action = function()
                Model.ToggleFavorite(node.path)
                invalidateViews()
                markDirty()
            end }
        local coll_children = {}
        for k = 1, 7 do
            coll_children[k] = {
                label = "Collection " .. k,
                checked = Model.collections[k][node.path] == true,
                action = function()
                    Model.ToggleCollection(k, node.path)
                    invalidateViews()
                    markDirty()
                end,
            }
        end
        coll_children[8] = { separator = true }
        coll_children[9] = { label = "Clear all",
            action = function()
                Model.ClearCollections(node.path)
                invalidateViews()
                markDirty()
            end }
        items[#items + 1] = { label = "Collections (keys 1-7)", children = coll_children }
    end
    items[#items + 1] = { separator = true }
    if r.CF_LocateInExplorer then
        items[#items + 1] = { label = "Show in Explorer",
            action = function() r.CF_LocateInExplorer(node.path) end }
    end
    if r.CF_SetClipboard then
        items[#items + 1] = { label = "Copy path",
            action = function() r.CF_SetClipboard(node.path) end }
    end
    UI.NativeMenu(items)
end

-- ---------------------------------------------------------------------------
-- Toolbar + chips
-- ---------------------------------------------------------------------------
local function drawToolbar(theme)
    local btn = theme.button_height
    local gap = theme.gap or 4
    local avail = UI.GetAvailableWidth()
    local search_w = math.max(120, avail - (btn + gap) * 3)

    SEARCH_OPTS.width = search_w
    local changed, text = UI.InputText("mx_search", "", state.search, SEARCH_OPTS)
    if changed then
        state.search = text
        state.fx_rows = nil  -- FX chip filters plugins with the same box
        if Model.SetSearch(text) then
            selectRow(1, { preview = false })
        end
        -- First search: also pull the native ME databases into the index
        -- (not relevant while browsing plugins).
        if state.chip ~= "fx" and Model.mode == "search" and opts.use_mediadb
           and not MediaDB.loaded and not MediaDB.loading then
            MediaDB.Start()
        end
    end
    UI.SameLine(gap)
    if iconBtn("mx_random", UI.Icons.Dice, "Random file  (R · Shift+R inserts)") then
        randomJump(false)
    end
    UI.SameLine(gap)
    if iconBtn("mx_addroot", UI.Icons.Plus, "Add folder") then
        addRootDialog()
    end
    UI.SameLine(gap)
    if iconBtn("mx_settings", UI.Icons.Settings, "Settings") then
        openSettings()
    end
end

local CHIPS = {
    { key = "tree",      id = "mx_chip_tree",      icon = UI.Icons.Folder,     tip = "All folders" },
    { key = "favorites", id = "mx_chip_favorites", icon = UI.Icons.StarFilled, tip = "Favorites" },
    { key = "recents",   id = "mx_chip_recents",   icon = UI.Icons.Clock,      tip = "Recently inserted" },
    { key = "fx",        id = "mx_chip_fx",        icon = UI.Icons.FX,         tip = "Plugins (add FX to tracks)" },
}

-- Colored collections (Ableton-style). Fixed palette, theme-independent.
local COLL_COLORS = {
    { 0.91, 0.30, 0.24 },  -- 1 red
    { 0.95, 0.61, 0.07 },  -- 2 orange
    { 0.95, 0.87, 0.25 },  -- 3 yellow
    { 0.18, 0.80, 0.44 },  -- 4 green
    { 0.20, 0.60, 0.86 },  -- 5 blue
    { 0.61, 0.35, 0.71 },  -- 6 purple
    { 0.91, 0.49, 0.68 },  -- 7 pink
}
local COLL_CHIPS = {}
for k = 1, 7 do
    COLL_CHIPS[k] = { key = "coll" .. k, id = "mx_chip_coll" .. k,
                      tip = "Collection " .. k .. "  (key " .. k .. ")" }
end

-- Capped-at-3 popcount for the 7-bit membership mask (row dots).
local POPCOUNT3 = {}
for mask = 0, 127 do
    local n, m = 0, mask
    while m ~= 0 and n < 3 do
        if (m & 1) == 1 then n = n + 1 end
        m = m >> 1
    end
    POPCOUNT3[mask] = n
end

local function collChip(chip, k, on, size)
    local theme = UI.GetTheme()
    local cx, cy = UI.GetCursorPos()
    local bg = on and theme.colors.accent or theme.colors.button
    local hov = Core_tk.MouseInRect(cx, cy, size, size) and not Core_tk.HasPopup()
    if hov and not on then bg = theme.colors.button_hovered end
    Core_tk.DrawRect(cx, cy, size, size, bg[1], bg[2], bg[3], bg[4] or 1)
    local col = COLL_COLORS[k]
    UI.DrawCircle(cx + size / 2, cy + size / 2, size * 0.22,
                  col[1], col[2], col[3], 1, true)
    UI.Layout.AdvanceCursor(size, size)
    if hov then UI.Tooltip(chip.tip) end
    return hov and Core_tk.MouseClicked(1)
end

-- Status caption memo: the string (and its measurement) is rebuilt only when
-- the composing state changes; the live index counter is quantized to keep
-- unique-string cardinality bounded (measure-cache hygiene).
local status_cache = { kind = 0, n = -1, str = "", w = 0, h = 0 }

local function statusInfo()
    local kind, n
    if state.swap_mode then
        kind, n = 1, 0
    elseif state.chip == "fx" then
        kind, n = 6, FXList.count
    elseif Model.indexing or MediaDB.loading then
        kind, n = 2, math.floor((Model.file_count + MediaDB.count) / 100)
    elseif Model.mode == "search" then
        kind, n = Model.search_truncated and 3 or 4, #Model.search_rows
    else
        kind, n = 5, Model.file_count
    end
    if kind ~= status_cache.kind or n ~= status_cache.n then
        status_cache.kind, status_cache.n = kind, n
        if kind == 1 then
            status_cache.str = "HOT-SWAP MODE — Q/Esc exit"
        elseif kind == 2 then
            status_cache.str = "indexing…  " .. (n * 100) .. "+ files"
        elseif kind == 3 then
            status_cache.str = n .. "+ results"
        elseif kind == 4 then
            status_cache.str = n .. " results"
        elseif kind == 6 then
            status_cache.str = n .. " plugins"
        else
            status_cache.str = n .. " files"
        end
        status_cache.w = -1  -- re-measure under the caption font at draw time
    end
    return status_cache
end

local function drawChips(theme)
    local chip_h = theme.chip_h or theme.button_height
    local gap    = theme.gap or 4

    for _, chip in ipairs(CHIPS) do
        local on = (state.chip == chip.key)
        if iconToggle(chip.id, chip.icon, chip.tip, on, chip_h) then
            state.chip = chip.key
            invalidateViews()
            selectRow(1, { preview = false })
        end
        UI.SameLine(gap)
    end

    -- Collection chips: shown once a collection has content (or is active).
    for k = 1, 7 do
        local chip = COLL_CHIPS[k]
        local on = (state.chip == chip.key)
        if on or next(Model.collections[k]) ~= nil then
            if collChip(chip, k, on, chip_h) then
                state.chip = on and "tree" or chip.key  -- click again = back to tree
                invalidateViews()
                selectRow(1, { preview = false })
            end
            UI.SameLine(gap)
        end
    end

    -- Right side: status caption (indexing / counts / hot-swap banner).
    local st = statusInfo()
    local tm = state.swap_mode and theme.colors.accent
               or theme.colors.text_mute or theme.colors.text_disabled
    UI.SetFontCaption()
    if st.w < 0 then
        st.w, st.h = Core_tk.MeasureText(st.str)
    end
    local cx, cy = UI.GetCursorPos()
    local right = cx + UI.GetAvailableWidth() - st.w - 4
    Core_tk.DrawText(st.str, right, cy + math.floor((chip_h - st.h) / 2),
                     tm[1], tm[2], tm[3], tm[4] or 1)
    UI.SetFontBody()
    UI.Spacing(0)  -- close the SameLine row without an extra blank line
end

-- ---------------------------------------------------------------------------
-- The list (virtualized inline tree)
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Waveform rows (FL "Samples view"): per-row thumbnails kept in one slot
-- atlas buffer. Rendered lazily (ONE slot per frame, visible rows only),
-- LRU-evicted, wiped on resize/theme change. Buffer id 906 (see Icons.lua
-- for the toolkit's buffer map: 900-905 taken, 910+ knob/icons).
-- ---------------------------------------------------------------------------
local WROW_BUF   = 906
local WROW_SLOTS = 48

local wrow = {
    bw = 0, slot_h = 0, colkey = -1,   -- atlas geometry + baked color
    slots = {},                        -- [path] = { [bw] = {slot, tick} }
    used = 0,
    free = {},
    tick = 0,
}

local function wrowSetup(bw, slot_h, colkey)
    if wrow.bw == bw and wrow.slot_h == slot_h and wrow.colkey == colkey then
        return
    end
    wrow.bw, wrow.slot_h, wrow.colkey = bw, slot_h, colkey
    wrow.slots, wrow.used, wrow.free = {}, 0, {}
    gfx.setimgdim(WROW_BUF, 0, 0)
    gfx.setimgdim(WROW_BUF, bw, slot_h * WROW_SLOTS)
end

local function wrowGet(path)
    local per = wrow.slots[path]
    if not per then return nil end
    local e = per[wrow.bw]
    if not e then return nil end
    wrow.tick = wrow.tick + 1
    e.tick = wrow.tick
    return e.slot
end

local function wrowAlloc(path)
    local slot
    if #wrow.free > 0 then
        slot = table.remove(wrow.free)
    elseif wrow.used < WROW_SLOTS then
        slot = wrow.used
        wrow.used = wrow.used + 1
    else
        local op, ob, ot = nil, nil, math.huge
        for p, per in pairs(wrow.slots) do
            for b, e in pairs(per) do
                if e.tick < ot then op, ob, ot = p, b, e.tick end
            end
        end
        if not op then return nil end
        slot = wrow.slots[op][ob].slot
        wrow.slots[op][ob] = nil
        if next(wrow.slots[op]) == nil then wrow.slots[op] = nil end
    end
    local per = wrow.slots[path]
    if not per then per = {}; wrow.slots[path] = per end
    wrow.tick = wrow.tick + 1
    per[wrow.bw] = { slot = slot, tick = wrow.tick }
    return slot
end

-- Draw one file's min/max lanes into its atlas slot. The slot is first
-- zeroed (color AND alpha) so the blit composites over any row background.
local function wrowRender(slot, wave, color)
    local bw, sh = wrow.bw, wrow.slot_h
    local y0 = slot * sh
    local old_dest = gfx.dest
    gfx.dest = WROW_BUF
    gfx.muladdrect(0, y0, bw, sh, 0, 0, 0, 0)
    gfx.set(color[1], color[2], color[3], 0.55)
    local mid  = y0 + sh / 2
    local half = (sh - 2) / 2
    local n = wave.n
    local mins, maxs = wave.mins, wave.maxs
    local floor = math.floor
    for px = 1, bw do
        local idx = floor((px - 1) * n / bw) + 1
        local vmax = maxs[idx] or 0
        local vmin = mins[idx] or 0
        local y1 = mid - vmax * half
        local y2 = mid - vmin * half
        if y2 - y1 < 1 then y1 = mid - 0.5; y2 = mid + 0.5 end
        gfx.line(px - 1, y1, px - 1, y2)
    end
    gfx.dest = old_dest
end

local INDENT_PX = 14
local STICKY_MAX = 6

-- Sticky ancestor stack (reused array, root-first). The stack covers its own
-- height in rows, which changes which row sits just below it — a short
-- fixed-point settles the count.
--
-- The probe row COUNTS ITSELF when it is an expanded dir: that is what makes
-- the capture seamless — the folder header is claimed by the stack at the
-- exact scroll position where its real row reaches its future stack slot
-- (same pixels), instead of waiting to be pushed out of the viewport.
local sticky_stack = {}

local function chainCount(probe)
    if not probe then return 0 end
    local count = (probe.is_dir and probe.expanded) and 1 or 0
    local p = probe.parent
    while p do count = count + 1; p = p.parent end
    return count
end

local function computeSticky(rows, first, max_levels)
    if max_levels > STICKY_MAX then max_levels = STICKY_MAX end
    if max_levels < 1 then return 0 end
    local n = 0
    for _ = 1, 5 do
        local probe = rows[first + n] or rows[#rows]
        local count = chainCount(probe)
        if count > max_levels then count = max_levels end
        if count == n then break end
        n = count
    end
    if n == 0 then return 0 end
    -- Fill slots n..1 walking up from the probe (itself when expanded dir) →
    -- root-first order; when capped, the n DEEPEST levels win.
    local probe = rows[first + n] or rows[#rows]
    local p = (probe.is_dir and probe.expanded) and probe or probe.parent
    local i = n
    while p and i >= 1 do
        sticky_stack[i] = p
        i = i - 1
        p = p.parent
    end
    if i > 0 then
        for k = 1, n - i do sticky_stack[k] = sticky_stack[k + i] end
        n = n - i
    end
    return n
end

local function drawList(theme, list_h)
    local rows  = rowsNow()
    local wave_mode = opts.wave_rows
    local row_h = wave_mode and (theme.row_h_large or 34) or (theme.row_h or 22)
    local pad   = theme.pad_small or 4
    -- Tree-style rendering (indent + sticky ancestors) applies to the file
    -- tree AND to the plugin tree while it isn't being filtered.
    local in_tree = (Model.mode == "tree" and state.chip == "tree")
                    or (state.chip == "fx" and state.search == "")

    applyScrollTo(row_h, list_h)

    local list_bg = theme.colors.list_bg or theme.colors.surface
    LIST_OPTS.bg = nil  -- background is filled inside the buffered region
    UI.BeginChild(LIST_ID, 0, list_h, LIST_OPTS)

    -- One-shot scroll restore (previous session's position). The child's
    -- persistent data exists once BeginChild ran; the write shows next frame.
    if state.scroll_restore then
        local ld = Core_tk.GetWidgetSubData("child", LIST_ID)
        if ld and ld._init ~= nil then
            ld.scroll_y = state.scroll_restore
            state.scroll_restore = nil
        end
    end

    local c = Core_tk.CurrentContainer()
    local view_x, view_y, view_w, view_h = c.x, c.y, c.w, c.h
    -- With the toolkit's scrollbar gutter the bar sits OUTSIDE the content
    -- width — only a small breathing margin is needed.
    local sb_w = (c.gutter and c.gutter > 0) and 2 or (theme.scrollbar_width or 6)
    local has_popup = Core_tk.HasPopup()

    if #rows == 0 then
        Core_tk.DrawRect(view_x, view_y, view_w, view_h,
                         list_bg[1], list_bg[2], list_bg[3], 1)
        local bc = theme.colors.border
        Core_tk.DrawRect(view_x, view_y, view_w, view_h,
                         bc[1], bc[2], bc[3], bc[4] or 0.4, false)
        UI.SetFontCaption()
        local tm = theme.colors.text_mute or theme.colors.text_disabled
        local hint
        if #Model.roots == 0 then
            hint = "Add a folder with [+] or drop one here."
        elseif Model.mode == "search" then
            hint = Model.indexing and "Searching…" or "No match."
        else
            hint = "Empty."
        end
        UI.TextColored(hint, tm[1], tm[2], tm[3], tm[4] or 1)
        UI.SetFontBody()
        UI.EndChild()
        return
    end

    -- Pixel-true clipping: rows, icons and labels render into an offscreen
    -- buffer and slide seamlessly behind the container edges (partial rows
    -- stay half-visible instead of popping). Opaque bg fill is mandatory.
    local buffered = UI.BeginBufferedClip(view_x, view_y, view_w, view_h)
    Core_tk.DrawRect(view_x, view_y, view_w, view_h,
                     list_bg[1], list_bg[2], list_bg[3], 1)

    local first, last = UI.ListClipper(#rows, row_h)

    -- Sticky ancestor stack (tree mode): every parent level of the topmost
    -- visible row, pinned root-first. Clicks on covered rows are masked.
    local max_levels = math.floor(view_h / row_h) - 2
    local sticky_n = in_tree and computeSticky(rows, first, max_levels) or 0
    local sticky_cut = view_y + sticky_n * row_h

    -- Waveform-row atlas geometry (wiped when size/theme changes)
    local wrow_missing = nil
    if wave_mode then
        local wc = theme.colors.accent
        local colkey = math.floor(wc[1] * 255) * 65536
                     + math.floor(wc[2] * 255) * 256
                     + math.floor(wc[3] * 255)
        local bw = math.max(96, math.floor((view_w - 80) / 32) * 32)
        wrowSetup(bw, row_h - 4, colkey)
    end

    -- Deferred interactions (applied after the loop)
    local clicked_idx, dbl_idx, rclick_idx, fav_idx = nil, nil, nil, nil

    for i = first, last do
        local node = rows[i]
        local _, y = UI.GetCursorPos()
        local is_sel = (i == state.sel_idx)
        local row_w  = view_w
        local maskable = sticky_n > 0 and (y < sticky_cut - 2)
        -- Band-gate on the visible list area: partially clipped edge rows
        -- overhang the child by up to row_h-1 px (MouseInRect is unclipped),
        -- and a click just outside the list must never act on a hidden row.
        local mry = select(2, Core_tk.GetMousePos())
        local hovered = (not has_popup) and (not maskable)
                        and mry >= view_y and mry < view_y + view_h
                        and Core_tk.MouseInRect(view_x, y, row_w, row_h)

        -- Background (list_selected: the token the Theme Tweaker exposes —
        -- accent_dim may not exist in older saved themes and fell back to
        -- the default theme's blue)
        if is_sel then
            local ac = theme.colors.list_selected or theme.colors.accent
            Core_tk.DrawRect(view_x, y, row_w, row_h, ac[1], ac[2], ac[3], ac[4] or 1)
        elseif hovered then
            local hc = theme.colors.surface2 or theme.colors.header_hovered
            Core_tk.DrawRect(view_x, y, row_w, row_h, hc[1], hc[2], hc[3], hc[4] or 1)
        end

        local depth = in_tree and node.depth or 0
        local ix = view_x + pad + depth * INDENT_PX
        local icon_sz = wave_mode and 16 or (row_h - 6)
        local icon_y  = y + math.floor((row_h - icon_sz) / 2)
        local tc = is_sel and theme.colors.list_selected_text or theme.colors.text
        local tm = theme.colors.text_mute or theme.colors.text_disabled

        -- Waveform behind the label zone (Samples view, files only)
        if wave_mode and not node.is_dir and node.kind ~= "fx" then
            local slot = wrowGet(node.path)
            if slot then
                local zone_x = ix + icon_sz + 2 + pad
                local zone_w = view_x + row_w - sb_w - pad - zone_x
                if zone_w > 24 then
                    gfx.a = 1
                    gfx.mode = 0
                    gfx.blit(WROW_BUF, 1, 0,
                             0, slot * wrow.slot_h, wrow.bw, wrow.slot_h,
                             zone_x, y + 2, zone_w, wrow.slot_h)
                end
            elseif not wrow_missing and not node._wrow_bad
                   and node.srate ~= 0
                   and not node.lo_name:find("%.midi?$") then
                wrow_missing = node
            end
        end

        if node.is_dir then
            local chev = node.expanded and UI.Icons.TriangleDown or UI.Icons.TriangleRight
            chev(ix, icon_y, icon_sz, tm[1], tm[2], tm[3], tm[4] or 1)
            ix = ix + icon_sz + 2
            UI.Icons.Folder(ix, icon_y, icon_sz, tc[1], tc[2], tc[3], tc[4] or 1)
            ix = ix + icon_sz + pad
        else
            ix = ix + icon_sz + 2  -- align with dir labels (no chevron)
            if node.kind == "fx" then
                UI.Icons.FX(ix, icon_y, icon_sz, tm[1], tm[2], tm[3], tm[4] or 1)
            else
                local playing = (Preview.playing_path == node.path)
                local fic = playing and theme.colors.accent or tm
                UI.Icons.Waveform(ix, icon_y, icon_sz, fic[1], fic[2], fic[3], fic[4] or 1)
            end
            ix = ix + icon_sz + pad
        end

        -- Right zone: favorite star (files) + dir count / ext caption.
        -- The star column is ALWAYS reserved for files so the label width is
        -- hover-invariant (keeps the truncation cache from thrashing).
        local right_edge = view_x + row_w - sb_w - pad
        local star_w = 0
        if not node.is_dir then
            star_w = icon_sz
            local fav = Model.IsFavorite(node.path)
            if fav or hovered then
                local sx = right_edge - star_w
                local sc = fav and theme.colors.accent or tm
                local star = fav and UI.Icons.StarFilled or UI.Icons.Star
                star(sx, icon_y, icon_sz, sc[1], sc[2], sc[3], sc[4] or 1)
                if hovered and Core_tk.MouseClicked(1) then
                    local mx = Core_tk.GetMousePos()
                    if mx >= sx - 2 then fav_idx = i end
                end
            end
        end

        -- Collection membership dots (up to 3, Ableton-style), left of the
        -- star column. Mask is version-cached on the node.
        local dots_w = 0
        if not node.is_dir then
            local mask = Model.CollectionMask(node)
            if mask ~= 0 then
                local cnt = POPCOUNT3[mask]
                dots_w = cnt * 9 + 2
                local dcy = y + row_h / 2
                local dxr = right_edge - star_w - 6
                local drawn = 0
                for k = 1, 7 do
                    if (mask & (1 << (k - 1))) ~= 0 then
                        local col = COLL_COLORS[k]
                        UI.DrawCircle(dxr - drawn * 9, dcy, 3,
                                      col[1], col[2], col[3], 1, true)
                        drawn = drawn + 1
                        if drawn >= 3 then break end
                    end
                end
            end
        end

        local cap, cap_w = nil, 0
        if node.is_dir then
            cap = dirCount(node)
        elseif Model.mode == "search" then
            if node.parent then
                cap = node.parent.name
            else
                -- Detached (MediaDB) file: parent folder name from the path.
                if not node.dir_cap then
                    node.dir_cap = node.path:match("([^/\\]+)[/\\][^/\\]+$") or ""
                end
                cap = node.dir_cap ~= "" and node.dir_cap or nil
            end
        end
        if cap then
            UI.SetFontCaption()
            local cph
            cap_w, cph = Core_tk.MeasureText(cap)
            Core_tk.DrawText(cap, right_edge - star_w - dots_w - cap_w - pad,
                             y + math.floor((row_h - cph) / 2),
                             tm[1], tm[2], tm[3], tm[4] or 1)
            UI.SetFontBody()
        end

        -- Label
        local max_w = right_edge - star_w - dots_w - cap_w - pad * 2 - ix
        if max_w > 20 then
            local label = rowLabel(node, max_w)
            local _, lh = Core_tk.MeasureText(label)
            Core_tk.DrawText(label, ix, y + math.floor((row_h - lh) / 2),
                             tc[1], tc[2], tc[3], tc[4] or 1)
        end

        -- Interactions (favorite click already handled above)
        if hovered and not fav_idx then
            if Core_tk.MouseClicked(1) then
                clicked_idx = i
                if not node.is_dir then
                    local mx, my = Core_tk.GetMousePos()
                    state.drag_pending = { node = node, mx = mx, my = my }
                end
            end
            if Core_tk.MouseDoubleClicked() then dbl_idx = i end
            if Core_tk.MouseClicked(2) then rclick_idx = i end
        end

        UI.Layout.AdvanceCursor(row_w, row_h)
    end

    UI.EndListClipper(#rows, row_h)

    -- Sticky ancestor stack overlay (drawn last, over the rows). Each level
    -- keeps its tree indentation; clicking a level jumps to that folder.
    if sticky_n > 0 then
        local hc = theme.colors.surface2 or theme.colors.header
        local bc = theme.colors.border_soft or theme.colors.separator
        local tc = theme.colors.text
        local tm = theme.colors.text_mute or theme.colors.text_disabled
        local icon_sz = wave_mode and 16 or (row_h - 6)
        local icon_dy = math.floor((row_h - icon_sz) / 2)
        local sticky_click = nil
        for k = 1, sticky_n do
            local dir = sticky_stack[k]
            local hy = view_y + (k - 1) * row_h
            Core_tk.DrawRect(view_x, hy, view_w, row_h, hc[1], hc[2], hc[3], 1)
            local hx = view_x + pad + dir.depth * INDENT_PX
            UI.Icons.TriangleDown(hx, hy + icon_dy, icon_sz, tm[1], tm[2], tm[3], tm[4] or 1)
            hx = hx + icon_sz + 2
            UI.Icons.Folder(hx, hy + icon_dy, icon_sz, tc[1], tc[2], tc[3], tc[4] or 1)
            hx = hx + icon_sz + pad
            local label = Core_tk.TruncateText(dir.name, view_w - hx - pad * 2)
            local _, lh = Core_tk.MeasureText(label)
            Core_tk.DrawText(label, hx, hy + math.floor((row_h - lh) / 2),
                             tc[1], tc[2], tc[3], tc[4] or 1)
            if not has_popup and Core_tk.MouseInRect(view_x, hy, view_w, row_h)
               and Core_tk.MouseClicked(1) then
                sticky_click = dir
            end
        end
        -- Single separator under the whole stack
        Core_tk.DrawRect(view_x, view_y + sticky_n * row_h - 1, view_w, 1,
                         bc[1], bc[2], bc[3], bc[4] or 0.8)
        if sticky_click then
            local pi = Model.IndexOf(rows, sticky_click)
            if pi then selectRow(pi, { preview = false }) end
        end
    end

    if buffered then UI.EndBufferedClip() end

    -- Border drawn on screen (a border drawn before the blit would be
    -- covered by it).
    local bc = theme.colors.border
    Core_tk.DrawRect(view_x, view_y, view_w, view_h,
                     bc[1], bc[2], bc[3], bc[4] or 0.4, false)

    UI.EndChild()

    -- Apply deferred row interactions
    if fav_idx then
        local node = rows[fav_idx]
        if node then
            Model.ToggleFavorite(node.path)
            invalidateViews()
            markDirty()
        end
    elseif clicked_idx then
        local node = rows[clicked_idx]
        if node.is_dir then
            selectRow(clicked_idx, { preview = false, scroll = false })
            nodeToggle(node)
            invalidateViews()
            markDirty()
        else
            -- Audition on RELEASE, not on press: if this press turns into a
            -- drag, the sound must never have started (parasite blip).
            -- Same-row click = retrigger (FL drum-spam), also on release.
            local retrig = (clicked_idx == state.sel_idx)
            selectRow(clicked_idx, { preview = false, scroll = false })
            if retrig or opts.autoplay then
                state.click_audition = node
            end
        end
    end
    if dbl_idx then
        local node = rows[dbl_idx]
        if node and not node.is_dir then insertNode(node, false) end
    end
    if rclick_idx then
        local node = rows[rclick_idx]
        if node then
            selectRow(rclick_idx, { preview = false, scroll = false })
            openRowMenu(node)
        end
    end

    -- Samples view: fill ONE missing thumbnail per frame (visible rows only;
    -- keeps the 2005 frame budget intact while the list populates in ~1 s).
    if wrow_missing then
        local node = wrow_missing
        local wave = Peaks.Get(node.path, Preview.GetSource(node.path), wrow.bw)
        if wave and wave.n > 0 then
            local slot = wrowAlloc(node.path)
            if slot then
                wrowRender(slot, wave, theme.colors.accent)
            end
            node._wrow_wait = nil
        else
            -- Peaks not ready yet (build queue) — give up on files that
            -- never produce any (unreadable, no audio).
            node._wrow_wait = (node._wrow_wait or 0) + 1
            if node._wrow_wait > 90 then node._wrow_bad = true end
        end
        UI.RequestRedraw()
    end
end

-- ---------------------------------------------------------------------------
-- Waveform strip + transport (preview bar)
-- ---------------------------------------------------------------------------
local WAVE_H = 44

-- Offscreen waveform buffer: the per-pixel line render happens once per
-- (peaks entry, size, color); each frame costs one blit. Buffer id 905
-- (0-899 image pool, 900-903 widgets, 904 toolkit buffered-clip).
local WAVE_BUF = 905
local wave_buf = { wave = nil, dw = 0, h = 0, r = -1, g = -1, b = -1 }

local function renderWaveBuf(wave, dw, h, color)
    local old_dest = gfx.dest
    gfx.dest = WAVE_BUF
    gfx.setimgdim(WAVE_BUF, 0, 0)  -- force a real clear
    gfx.setimgdim(WAVE_BUF, dw, h)
    gfx.set(color[1], color[2], color[3], color[4] or 0.9)
    local mid  = h / 2
    local half = (h - 4) / 2
    local n = wave.n
    local mins, maxs = wave.mins, wave.maxs
    local floor = math.floor
    for px = 1, dw do
        local idx = floor((px - 1) * n / dw) + 1
        local vmax = maxs[idx] or 0
        local vmin = mins[idx] or 0
        local y1 = mid - vmax * half
        local y2 = mid - vmin * half
        if y2 - y1 < 1 then y1 = mid - 0.5; y2 = mid + 0.5 end
        gfx.line(px - 1, y1, px - 1, y2)
    end
    gfx.dest = old_dest
end

local function waveTarget()
    local node = state.sel_node
    if node and not node.is_dir and node.kind ~= "fx" then return node end
    if Preview.playing_path then
        return Model.by_path[Preview.playing_path]
    end
    return nil
end

local function drawWave(theme)
    local x, y = UI.GetCursorPos()
    local w = UI.GetAvailableWidth()
    local h = WAVE_H

    local bg = theme.colors.list_bg or theme.colors.surface
    Core_tk.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4] or 1)
    local bc = theme.colors.border_soft or theme.colors.border
    Core_tk.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], bc[4] or 0.4, false)

    local node = waveTarget()
    local tm = theme.colors.text_mute or theme.colors.text_disabled

    if node and node.srate ~= 0 then
        local dw = w - 2
        local bucket = math.max(64, math.floor(dw / 32) * 32)
        local wave = Peaks.Get(node.path, Preview.GetSource(node.path), bucket)
        if wave and wave.n > 0 then
            local wc = theme.colors.accent
            -- Render the static waveform ONCE into an offscreen buffer (the
            -- per-pixel line loop would otherwise eat most of the frame draw
            -- budget every frame); per frame: one blit + one cursor line.
            if wave_buf.wave ~= wave or wave_buf.dw ~= dw or wave_buf.h ~= h
               or wave_buf.r ~= wc[1] or wave_buf.g ~= wc[2] or wave_buf.b ~= wc[3] then
                renderWaveBuf(wave, dw, h - 2, wc)
                wave_buf.wave, wave_buf.dw, wave_buf.h = wave, dw, h
                wave_buf.r, wave_buf.g, wave_buf.b = wc[1], wc[2], wc[3]
            end
            gfx.a = 1
            gfx.mode = 0
            gfx.blit(WAVE_BUF, 1, 0, 0, 0, dw, h - 2, x + 1, y + 1, dw, h - 2)

            -- Section selection overlay (native ME-style time selection)
            local wsel = state.wsel
            if wsel and wsel.path == node.path then
                local ax = x + 1 + wsel.a * dw
                local bx = x + 1 + wsel.b * dw
                local sc = theme.colors.list_selected or theme.colors.accent
                Core_tk.DrawRect(ax, y + 1, bx - ax, h - 2, sc[1], sc[2], sc[3], 0.25)
                Core_tk.DrawLine(ax, y + 1, ax, y + h - 1, sc[1], sc[2], sc[3], 0.9)
                Core_tk.DrawLine(bx, y + 1, bx, y + h - 1, sc[1], sc[2], sc[3], 0.9)
            end

            -- Playback cursor (redraw paced to actual pixel movement)
            if Preview.playing_path == node.path then
                local prog, _, plen = Preview.Progress()
                if prog then
                    local cx = x + 1 + prog * dw
                    local ac = theme.colors.text
                    Core_tk.DrawLine(cx, y + 1, cx, y + h - 1, ac[1], ac[2], ac[3], 0.9)
                    local spp = (plen and plen > 0) and (plen / dw) or 0.033
                    if spp < 0.033 then spp = 0.033 end
                    UI.RequestRedrawAt(r.time_precise() + spp)
                end
            end

            -- Interaction: click = seek / play-from-here; DRAG = select a
            -- section (previewed on release, applied on insert).
            local hover_strip = not Core_tk.HasPopup()
                                and Core_tk.MouseInRect(x, y, w, h)
            if hover_strip and Core_tk.MouseClicked(1) then
                local mx, my = Core_tk.GetMousePos()
                local frac = stripFrac(x, dw)
                local ws = state.wsel
                -- Pressing INSIDE the existing section arms a drag OF the
                -- section (to the arrange); pressing outside redefines it.
                local in_sel = ws ~= nil and ws.path == node.path
                               and frac >= ws.a and frac <= ws.b
                state.wpress = { x = mx, y = my, frac = frac,
                                 dragging = false, in_sel = in_sel }
                Core_tk.SetActive("mx_wave")
            end
            if Core_tk.IsActive("mx_wave") and state.wpress then
                if Core_tk.MouseDown(1) then
                    local mx, my = Core_tk.GetMousePos()
                    if state.wpress.in_sel then
                        local dx = mx - state.wpress.x
                        local dy = my - state.wpress.y
                        if dx * dx + dy * dy > 25 then
                            -- Promote to an arrange drag of the section.
                            -- previewState() picks the section up from
                            -- state.wsel, so the whole drop pipeline (live
                            -- ghost item included) applies it as-is.
                            Core_tk.ClearActive()
                            state.wpress = nil
                            state.drag = { node = node,
                                           label = sectionDragLabel(node) }
                            Preview.Stop()
                            -- Section drops on CP targets load the whole
                            -- file (the bus carries paths, not sections).
                            DragBus.Begin("file", node.path, state.drag.label)
                        end
                    elseif state.wpress.dragging or math.abs(mx - state.wpress.x) > 3 then
                        state.wpress.dragging = true
                        local frac = stripFrac(x, dw)
                        -- Mutate in place: a fresh table per held-button
                        -- frame would be steady GC churn (perf contract).
                        local ws = state.wsel
                        if not ws then
                            ws = { path = node.path, a = 0, b = 0 }
                            state.wsel = ws
                        end
                        ws.path = node.path
                        if state.wpress.frac < frac then
                            ws.a, ws.b = state.wpress.frac, frac
                        else
                            ws.a, ws.b = frac, state.wpress.frac
                        end
                    end
                else
                    Core_tk.ClearActive()
                    local press = state.wpress
                    state.wpress = nil
                    if press.dragging then
                        if state.wsel and (state.wsel.b - state.wsel.a) > 0.005 then
                            doPreview(node, state.wsel.a)  -- audition the section
                        else
                            state.wsel = nil
                        end
                    elseif Preview.playing_path == node.path then
                        Preview.SeekFrac(press.frac)
                        state.wsel_prog = nil  -- a seek is not a crossing
                    else
                        doPreview(node, press.frac)
                    end
                end
            end
            if hover_strip and Core_tk.MouseClicked(2) and state.wsel then
                state.wsel = nil  -- right-click clears the section
            end
        else
            UI.SetFontCaption()
            local msg = Peaks.Building(node.path) and "building peaks…" or "no waveform"
            local mw, mh = Core_tk.MeasureText(msg)
            Core_tk.DrawText(msg, x + (w - mw) / 2, y + (h - mh) / 2,
                             tm[1], tm[2], tm[3], tm[4] or 1)
            UI.SetFontBody()
        end
    elseif node then
        UI.SetFontCaption()
        local msg = "MIDI file — no preview"
        local mw, mh = Core_tk.MeasureText(msg)
        Core_tk.DrawText(msg, x + (w - mw) / 2, y + (h - mh) / 2,
                         tm[1], tm[2], tm[3], tm[4] or 1)
        UI.SetFontBody()
    end

    UI.Layout.AdvanceCursor(w, h)
end

local function drawTransport(theme)
    local gap = theme.gap or 4
    local btn = theme.button_height
    local node = waveTarget()

    -- Play / stop
    local playing = Preview.IsPlaying()
    if iconBtn("mx_play", playing and UI.Icons.Stop or UI.Icons.Play,
               playing and "Stop" or "Play selected") then
        if playing then Preview.Stop()
        elseif node then doPreview(node) end
    end
    UI.SameLine(gap)

    if iconToggle("mx_loop", UI.Icons.Loop, "Loop preview", Preview.loop, btn) then
        Preview.SetLoop(not Preview.loop)
        markDirty()
    end
    UI.SameLine(gap)
    if iconToggle("mx_autoplay", UI.Icons.Volume, "Autoplay on selection",
                  opts.autoplay, btn) then
        opts.autoplay = not opts.autoplay
        markDirty()
    end
    UI.SameLine(gap)
    local sync_x, sync_y = UI.GetCursorPos()
    if iconToggle("mx_sync", UI.Icons.Clock,
                  "Tempo-match (right-click: ×0.5 / ×1 / ×2)",
                  opts.tempo_sync, btn) then
        opts.tempo_sync = not opts.tempo_sync
        markDirty()
    end
    -- Right-click cycles the ME-style multiplier.
    if Core_tk.MouseInRect(sync_x, sync_y, btn, btn)
       and Core_tk.MouseClicked(2) then
        if opts.sync_mult == 1.0 then opts.sync_mult = 2.0
        elseif opts.sync_mult == 2.0 then opts.sync_mult = 0.5
        else opts.sync_mult = 1.0 end
        flash(opts.sync_mult == 0.5 and "Tempo-match ×0.5"
              or opts.sync_mult == 2.0 and "Tempo-match ×2"
              or "Tempo-match ×1")
        markDirty()
    end
    UI.SameLine(gap * 2)

    -- Volume
    local vc, vv = UI.SliderDouble("mx_vol", "", Preview.volume, 0, 2, VOL_OPTS)
    if vc then
        Preview.SetVolume(vv)
        markDirty()
    end
    UI.SameLine(gap)

    -- Pitch (semitones). %.0f, not %d — drag interpolation yields floats
    -- and Lua 5.3 %d hard-errors on them (see commit 37a9612).
    local pc, pv = UI.NumberInput("mx_pitch", "", Preview.pitch, -24, 24, PITCH_OPTS)
    if pc then
        Preview.SetPitch(pv)
        markDirty()
    end
    UI.SameLine(gap)

    -- Rate
    local rc, rv = UI.NumberInput("mx_rate", "", Preview.rate, 0.25, 4, RATE_OPTS)
    if rc then
        Preview.SetRate(rv)
        markDirty()
    end
    UI.SameLine(gap * 2)

    -- Info / flash caption (right side)
    local text
    if state.flash_msg ~= "" and r.time_precise() < state.flash_until then
        text = state.flash_msg
    elseif node then
        text = node._info or node.name
    elseif not Preview.available then
        text = "SWS extension missing — preview disabled"
    else
        text = ""
    end
    if text ~= "" then
        UI.SetFontCaption()
        local tm = theme.colors.text_mute or theme.colors.text_disabled
        local cx, cy = UI.GetCursorPos()
        local avail = UI.GetAvailableWidth()
        local tw, th = Core_tk.MeasureText(text)
        local tx = cx + avail - tw - 4
        if tx < cx then tx = cx end
        Core_tk.DrawText(text, tx, cy + math.floor((btn - th) / 2),
                         tm[1], tm[2], tm[3], tm[4] or 1)
        UI.SetFontBody()
    end
    UI.NewLine()
end

-- ---------------------------------------------------------------------------
-- Custom drag (out the window, onto the arrange)
-- ---------------------------------------------------------------------------
local DRAG_THRESHOLD = 5

local function handleDrag()
    -- Promote pending → active once the mouse moved far enough.
    if state.drag_pending then
        if Core_tk.MouseDown(1) then
            local mx, my = Core_tk.GetMousePos()
            local dx = mx - state.drag_pending.mx
            local dy = my - state.drag_pending.my
            if dx * dx + dy * dy > DRAG_THRESHOLD * DRAG_THRESHOLD then
                -- Ghost label built once here, not per frame.
                local dn = state.drag_pending.node
                state.drag = { node = dn, label = "+ " .. dn.name }
                state.drag_pending = nil
                state.click_audition = nil  -- a drag stays silent
                Preview.Stop()  -- in case something was already playing
                -- Publish on the CP drag bus: other CP windows (Sampler
                -- pads, editor) can highlight and accept the drop.
                if dn.kind == "fx" then
                    DragBus.Begin("fx", dn.full, state.drag.label)
                else
                    DragBus.Begin("file", dn.path, state.drag.label)
                end
            end
        else
            -- Released without dragging: this was a plain click — fire the
            -- deferred audition now (never on press, see click_audition).
            state.drag_pending = nil
            local n = state.click_audition
            if n then
                state.click_audition = nil
                doPreview(n)
            end
        end
    end

    if not state.drag then return end

    local dnode = state.drag.node
    local sx, sy = r.GetMousePosition()

    -- Plugins: no ghost item — tooltip ghost everywhere; drop adds the FX
    -- to the track under the mouse (TCP included); empty arrange space =
    -- new track (FL behavior).
    if dnode.kind == "fx" then
        r.TrackCtl_SetToolTip(state.drag.label, sx + 16, sy + 12, true)
        UI.SetCursor("hand")
        if Core_tk.MouseReleased(1) then
            state.drag = nil
            r.TrackCtl_SetToolTip("", 0, 0, true)
            DragBus.End()  -- no CP target takes FX drops today
            local over, track = Insert.ArrangeHit(sx, sy)
            if not over and r.GetThingFromPoint then
                local ttrack, info = r.GetThingFromPoint(sx, sy)
                if ttrack and info and info:find("tcp", 1, true) then
                    over, track = true, ttrack
                end
            end
            if over then
                local ok
                if track then
                    ok = Insert.AddFX(dnode.full, track)
                else
                    ok = Insert.AddFXNewTrack(dnode.full, dnode.name)
                end
                flash((ok and "Added FX: " or "Add FX failed: ") .. dnode.name)
            end
        end
        return
    end

    -- A CP window (Sampler pads, editor…) under the mouse takes priority
    -- over the arrange: no ghost item — the target consumes the drop.
    if DragBus.HoverTarget(sx, sy) then
        Insert.GhostCancel()
        r.TrackCtl_SetToolTip(state.drag.label, sx + 16, sy + 12, true)
        UI.SetCursor("hand")
        if Core_tk.MouseReleased(1) then
            state.drag = nil
            r.TrackCtl_SetToolTip("", 0, 0, true)
            if DragBus.Drop(sx, sy) then
                pushRecent(dnode.path)
                flash("Dropped: " .. dnode.name)
            end
        end
        return
    end

    local over, track, time = Insert.ArrangeHit(sx, sy)

    if over then
        -- Over the arrange: a REAL item follows the mouse (native ME feel —
        -- it takes space, draws its waveform, and hovering below the last
        -- track creates the track live). The tooltip ghost disappears.
        r.TrackCtl_SetToolTip("", 0, 0, true)
        local ps = nil
        if not Insert.GhostActive() then
            ps = previewState(state.drag.node)  -- only read at ghost creation
        end
        Insert.GhostUpdate(state.drag.node.path, track, time, ps)
    else
        -- Elsewhere: OS-level tooltip ghost (it tracks the mouse over any
        -- window, which a gfx script window cannot do itself).
        Insert.GhostCancel()
        r.TrackCtl_SetToolTip(state.drag.label, sx + 16, sy + 12, true)
    end
    UI.SetCursor("hand")

    if Core_tk.MouseReleased(1) then
        local node = state.drag.node
        state.drag = nil
        r.TrackCtl_SetToolTip("", 0, 0, true)
        DragBus.End()
        if over then
            local item = Insert.GhostCommit(node.path)
            if not item and time then
                -- Ghost never materialized (e.g. mapping hiccup) — fall back
                -- to the direct insert path.
                item = Insert.AtArrange(node.path, track, time, previewState(node))
            end
            if item then
                pushRecent(node.path)
                flash("Inserted: " .. node.name)
            end
        else
            Insert.GhostCancel()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------
local function frame(theme)
    -- Section audition bounds: stop (or loop) when playback CROSSES the
    -- selection end. Crossing detection (prev < b, now >= b) — a static
    -- ">= b" check used to kill any seek/playback landing past the section.
    if state.wsel and Preview.playing_path == state.wsel.path then
        local prog = Preview.Progress()
        if prog then
            local prev = state.wsel_prog
            if prev and prev < state.wsel.b and prog >= state.wsel.b then
                if Preview.loop then
                    Preview.SeekFrac(state.wsel.a)
                    prog = state.wsel.a
                else
                    Preview.Stop()
                end
            end
            state.wsel_prog = prog
        end
    else
        state.wsel_prog = nil
    end

    -- Background work first (budgeted), keeps frames flowing while active.
    if Model.indexing then
        Model.IndexStep(0.004)
        UI.RequestRedraw()
    end
    if MediaDB.loading then
        MediaDB.Step(0.003, dbSink)
        UI.RequestRedraw()
    end
    if Peaks.Step() then
        UI.RequestRedraw()
    end

    handleFileDrops()
    handleKeys()

    local pad   = theme.pad_small or 4
    local pad_l = theme.pad_large or 10
    UI.SetWindowPadding(pad_l)

    -- Compact header: the rows' natural item spacing is enough — extra
    -- Spacing() calls opened a dead gap between the search bar and the list.
    drawToolbar(theme)
    drawChips(theme)

    -- List fills everything above the preview bar.
    local btn = theme.button_height
    local bar_h = WAVE_H + btn + pad * 3
    local list_h = math.max(100, UI.GetAvailableHeight() - bar_h - pad)
    drawList(theme, list_h)

    UI.Spacing(pad)
    drawWave(theme)
    UI.Spacing(pad)
    drawTransport(theme)

    handleDrag()

    -- Deferred config writes: flush once per interaction, not per drag frame.
    if state.cfg_dirty and not Core_tk.MouseDown(1) then
        persistConfig()
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("Media Explorer", 640, 800, {
    persist    = CONFIG_ID,
    scrollable = false,
    padding    = 0,
})

UI.OnClose(function()
    r.TrackCtl_SetToolTip("", 0, 0, true)  -- clear a mid-drag tooltip ghost
    Insert.GhostCancel()                   -- remove a mid-drag live item
    DragBus.End()                          -- release a mid-drag bus claim
    persistConfig()
    Preview.Destroy()
    Peaks.Destroy()
    Model.StopIndex()
    MediaDB.Stop()
end)

-- Hard-termination safety net (Actions-window kill, runtime error breaking
-- the defer chain): OnClose never runs on those paths, and a live ghost
-- item / temp track would be leaked into the project. Idempotent — a normal
-- close already cleaned everything up.
r.atexit(function()
    r.TrackCtl_SetToolTip("", 0, 0, true)
    pcall(Insert.GhostCancel)
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
