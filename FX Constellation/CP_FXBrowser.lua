-- @description FX Browser (standalone)
-- @version 1.1
-- @author Cedric Pamalio
-- @about
--   Standalone FX browser. Reuses FX Constellation's domain modules
--   (FXDatabase, FXManager, Persistence) and runs in its own CP_Toolkit
--   window — independent OS window, dockable, leaves the main app free.
--
--   Operates on REAPER's selected track (re-read every frame). Adds, bypasses
--   and deletes FX through standard REAPER API; the main FX Constellation
--   app picks up changes via its own FX-chain polling.

local r = reaper
local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/"
local data_path   = script_path .. "Data/"
local presets_file = data_path .. "presets.dat"

-- ---------------------------------------------------------------------------
-- Toolkit + domain modules
-- ---------------------------------------------------------------------------
local toolkit_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua"
local UI = dofile(toolkit_path)

local Core        = dofile(script_path .. "Modules/Core.lua")
local Persistence = dofile(script_path .. "Modules/Persistence.lua")
local FXDatabase  = dofile(script_path .. "Modules/FXDatabase.lua")

local LicenseStub  = { init = function() end, isFull = function() return true end }
local SoundGenStub = { init = function() end }
local FXManager    = dofile(script_path .. "Modules/FXManager.lua")

Core.init(r)
Persistence.init(r, Core, data_path, presets_file)
FXDatabase.init(r, Core, Persistence, data_path)
FXManager.init(r, Core, Persistence, LicenseStub, SoundGenStub, FXDatabase)

Persistence.loadSettings()
FXDatabase.loadDatabase()

-- ---------------------------------------------------------------------------
-- Persistent browser state (own config file, separate from main app)
-- ---------------------------------------------------------------------------
local CONFIG_ID = "CP_FXBrowser"
local cfg = UI.LoadConfig(CONFIG_ID) or {}

local state = {
    sort_mode      = cfg.sort_mode      or "az",          -- "az" | "za"
    auto_open      = cfg.auto_open      or false,
    type_filter    = cfg.type_filter    or "All",
    search         = "",
    selected_idx   = 0,                                   -- last clicked plugin row (anchor)
    selected       = {},                                  -- multi-select: { [plugin.name]=true }
    chain_selected = nil,                                 -- selected chain row (fx_idx)
    rand_count        = cfg.rand_count        or 3,
    rand_fav_only     = cfg.rand_fav_only     or false,
    rand_replace      = cfg.rand_replace      or false,
    rand_from_visible = cfg.rand_from_visible or false,
    -- Post-insertion macros: actions auto-applied after each FX is added.
    post_insert       = cfg.post_insert or {
        enabled          = false,
        select_mode      = "none",   -- "none" | "all" | "all_cont" | "random"
        random_count     = 3,
        randomize_xy     = false,
        randomize_range  = false,
        randomize_base   = false,
        randomize_invert = false,    -- "N" toggle (negate / invert direction)
        bypass_after     = false,
    },
    post_insert_open  = false,      -- modal visibility
    recents        = cfg.recents        or {},            -- list of plugin.name (most-recent first)
    split_left     = cfg.split_left     or 0.62,          -- ratio plugins-pane / chain-pane
    -- Custom tabs: list of { name=string, plugin_names={...} }
    -- type_filter prefix "T:" + name = a custom tab is active.
    tabs           = cfg.tabs           or {},
    -- Modal/UI state for tab management (transient, not persisted)
    new_tab_open   = false,
    new_tab_name   = "",
    rename_tab_idx = nil,
    rename_tab_name = "",
    flash_msg      = "",
    flash_until    = 0,
}

-- Built-in filters. `compact` is the chip label (1-3 chars). `tip` shows the
-- full meaning on hover. `icon_key` (optional) draws a glyph instead of text.
local BUILTIN_FILTERS = {
    { key = "All",       compact = "All",  tip = "All plugins" },
    { key = "Favorites", icon_key = "StarFilled", tip = "Favorites" },
    { key = "Recents",   icon_key = "Clock",      tip = "Recently added" },
    { key = "VST3",      compact = "V3",   tip = "VST3" },
    { key = "VST",       compact = "V",    tip = "VST" },
    { key = "JS",        compact = "JS",   tip = "JSFX" },
    { key = "Bundled",   compact = "B",    tip = "Bundled (REAPER + Cockos)" },
}

local function persistConfig()
    UI.SaveConfig(CONFIG_ID, {
        sort_mode         = state.sort_mode,
        auto_open         = state.auto_open,
        type_filter       = state.type_filter,
        category          = state.category,
        rand_count        = state.rand_count,
        rand_fav_only     = state.rand_fav_only,
        rand_replace      = state.rand_replace,
        rand_from_visible = state.rand_from_visible,
        post_insert       = state.post_insert,
        recents           = state.recents,
        split_left        = state.split_left,
        tabs              = state.tabs,
    })
end

-- Find a custom tab by name. Returns (index, tab) or nil.
local function findTab(name)
    for i, t in ipairs(state.tabs) do
        if t.name == name then return i, t end
    end
    return nil
end

local function flash(msg)
    state.flash_msg   = msg
    state.flash_until = r.time_precise() + 2.5
end

-- ---------------------------------------------------------------------------
-- Filtering / search
-- ---------------------------------------------------------------------------
local function pluginPool()
    -- Custom tab? type_filter starts with "T:" prefix.
    if state.type_filter and state.type_filter:sub(1, 2) == "T:" then
        local tab_name = state.type_filter:sub(3)
        local _, tab = findTab(tab_name)
        if not tab then return {} end
        local out, idx = {}, {}
        for _, p in ipairs(FXDatabase.plugins) do idx[p.name] = p end
        for _, name in ipairs(tab.plugin_names) do
            if idx[name] then out[#out + 1] = idx[name] end
        end
        return out
    end

    if state.type_filter == "Favorites" then
        return FXDatabase.getFavorites()
    elseif state.type_filter == "Recents" then
        local out, idx = {}, {}
        for _, p in ipairs(FXDatabase.plugins) do idx[p.name] = p end
        for _, name in ipairs(state.recents) do
            if idx[name] then out[#out + 1] = idx[name] end
        end
        return out
    elseif state.type_filter == "VST3" then
        return FXDatabase.filterByType("VST3")
    elseif state.type_filter == "VST" then
        return FXDatabase.filterByType("VST")
    elseif state.type_filter == "JS" then
        return FXDatabase.filterByType("JS")
    elseif state.type_filter == "Bundled" then
        return FXDatabase.filterBundled()
    end
    return FXDatabase.plugins
end

-- Append plugin names to a tab (dedupe), then persist.
local function addNamesToTab(tab, names)
    local seen = {}
    for _, n in ipairs(tab.plugin_names) do seen[n] = true end
    local added = 0
    for _, n in ipairs(names) do
        if not seen[n] then
            tab.plugin_names[#tab.plugin_names + 1] = n
            seen[n] = true
            added = added + 1
        end
    end
    persistConfig()
    return added
end

-- Remove a plugin name from a tab (used for chip-X cleanup).
local function removeNameFromTab(tab, name)
    for i, n in ipairs(tab.plugin_names) do
        if n == name then table.remove(tab.plugin_names, i); break end
    end
    persistConfig()
end

-- Multi-word AND search on display_name + name (each token must match)
local function matchSearch(plugin, tokens)
    if #tokens == 0 then return true end
    local hay = ((plugin.display_name or "") .. " " .. (plugin.name or "")):lower()
    for _, t in ipairs(tokens) do
        if not hay:find(t, 1, true) then return false end
    end
    return true
end

local function tokenize(query)
    local out = {}
    for w in query:lower():gmatch("%S+") do out[#out + 1] = w end
    return out
end

local function filteredPlugins()
    local pool = pluginPool()
    local tokens = tokenize(state.search or "")
    local out = {}
    for _, p in ipairs(pool) do
        if matchSearch(p, tokens) then out[#out + 1] = p end
    end
    -- Recents has its own ordering; otherwise sort by name
    if state.type_filter ~= "Recents" then
        local function nm(p) return (p.display_name or p.name):lower() end
        if state.sort_mode == "az" then
            table.sort(out, function(a, b) return nm(a) < nm(b) end)
        elseif state.sort_mode == "za" then
            table.sort(out, function(a, b) return nm(a) > nm(b) end)
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- FX add / track ops
-- ---------------------------------------------------------------------------
local function refreshTrack()
    Core.state.track = r.GetSelectedTrack(0, 0)
end

local function pushRecent(name)
    -- move-to-front, dedupe, cap to 30
    local out = { name }
    for _, n in ipairs(state.recents) do
        if n ~= name and #out < 30 then out[#out + 1] = n end
    end
    state.recents = out
    persistConfig()
end

-- Apply post-insertion macros to a single FX, identified by its REAPER
-- (actual) 0-based fx index. FXManager indexes its state.fx_data table by a
-- "visible_fx_id" that skips Bridge / Sound Generator helpers, so we resolve
-- the right key by scanning fx_data after refresh.
-- Debug helper (toggle in cfg.debug_post_insert if you want trace logs)
local function dbg(...)
    if not state.post_insert or not state.post_insert.debug then return end
    local parts = {"[POST-INSERT]"}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    r.ShowConsoleMsg(table.concat(parts, " ") .. "\n")
end

local function applyPostInsert(actual_fx_idx)
    local pi = state.post_insert
    if not pi or not pi.enabled then return end
    if not Core.isTrackValid() then return end
    if not actual_fx_idx or actual_fx_idx < 0 then return end

    dbg("called with actual_fx_idx=", actual_fx_idx)

    if FXManager.scanTrackFX then FXManager.scanTrackFX() end

    -- Dump fx_data so we know what got scanned
    if pi.debug then
        for vid, data in pairs(Core.state.fx_data or {}) do
            dbg("  fx_data[" .. tostring(vid) .. "] actual=" ..
                tostring(data.actual_fx_id) ..
                " name=" .. tostring(data.name))
        end
    end

    -- Find the visible_fx_id whose actual_fx_id matches the REAPER index.
    local fx_id, fx_data = nil, nil
    for vid, data in pairs(Core.state.fx_data or {}) do
        if (data.actual_fx_id or vid) == actual_fx_idx then
            fx_id, fx_data = vid, data
            break
        end
    end
    if not fx_data or not fx_data.params then
        dbg("  no fx_data found for actual_fx_idx=", actual_fx_idx)
        return
    end
    dbg("  resolved fx_id=", fx_id, " params=", #fx_data.params)

    local params = fx_data.params

    -- Param selection
    if pi.select_mode == "all" then
        FXManager.selectAllParams(params, true)
    elseif pi.select_mode == "all_cont" then
        FXManager.selectAllContinuousParams(params, true)
    elseif pi.select_mode == "random" then
        local fx_key = Core.getFXKey and Core.getFXKey(fx_id) or nil
        if fx_key and Core.state.fx_random_max then
            Core.state.fx_random_max[fx_key] = pi.random_count or 3
        end
        FXManager.randomSelectParams(params, fx_id)
    end

    -- Count what got selected
    if pi.debug then
        local sel = 0
        for _, p in pairs(params) do if p.selected then sel = sel + 1 end end
        dbg("  after select_mode='" .. tostring(pi.select_mode) ..
            "' selected_count=" .. sel)
    end

    -- Randomization passes (only meaningful if at least one param is selected)
    if pi.randomize_xy    then FXManager.randomizeXYAssign(params, fx_id) end
    if pi.randomize_range then FXManager.randomizeRanges(params, fx_id)   end
    if pi.randomize_base  then FXManager.randomizeBaseValues(params, fx_id) end
    if pi.randomize_invert then
        -- Per-FX equivalent of FXManager.globalRandomInvert: 50/50 negate.
        for param_id, param_data in pairs(params) do
            if param_data.selected then
                FXManager.setParamInvert(fx_id, param_id, math.random() < 0.5)
            end
        end
    end

    -- Optional: bypass the FX after the macro
    if pi.bypass_after then
        FXManager.r.TrackFX_SetEnabled(Core.state.track, actual_fx_idx, false)
    end

    -- Persist immediately. saveTrackSelection() only flips Persistence.save_flags,
    -- and the actual ExtState write happens in Persistence.checkSave() which is
    -- never called from the browser's defer loop. Force a flush now so the main
    -- FX Constellation app can read the new selection on its next scan.
    if FXManager.saveTrackSelection then FXManager.saveTrackSelection() end
    if Persistence.save_flags then
        Persistence.save_flags.track_selections = true
    end
    if Persistence.saveSettings then Persistence.saveSettings() end
    dbg("  flushed track_selections to ExtState")
end

local function addPlugin(plugin)
    refreshTrack()
    if not Core.isTrackValid() then
        flash("No track selected")
        return false
    end
    local fx_name = FXManager.buildFXName(plugin)
    local ok = FXManager.addFXByName(fx_name, state.auto_open, true)
    if ok then
        pushRecent(plugin.name)
        local track = Core.state.track
        local new_idx = r.TrackFX_GetCount(track) - 1
        if not state.auto_open and new_idx >= 0 then
            r.TrackFX_Show(track, new_idx, 2)
        end
        applyPostInsert(new_idx)
        flash("Added: " .. (plugin.display_name or plugin.name))
    else
        flash("Failed to add: " .. (plugin.display_name or plugin.name))
    end
    return ok
end

-- Returns true if the FX at fx_idx is the SoundGenerator helper JSFX.
local function isSoundGenFX(track, fx_idx)
    local _, fx_name = r.TrackFX_GetFXName(track, fx_idx, "")
    local low = (fx_name or ""):lower()
    return low:find("sound generator") ~= nil or low:find("jsfx sound") ~= nil
end

-- Delete every FX on the track except the SoundGenerator helper.
-- Returns the number of FX removed.
local function clearChain(track)
    local removed = 0
    -- Walk top-down so deletes don't shift indices we haven't processed yet.
    for fx_idx = r.TrackFX_GetCount(track) - 1, 0, -1 do
        if not isSoundGenFX(track, fx_idx) then
            r.TrackFX_Delete(track, fx_idx)
            removed = removed + 1
        end
    end
    return removed
end

-- Collect plugins that are currently selected (preserves visible order).
local function collectSelected(plugins)
    local out = {}
    for _, p in ipairs(plugins) do
        if state.selected[p.name] then out[#out + 1] = p end
    end
    return out
end

-- Add a plugin to the track at a specific destination index (0-based).
-- addFXByName always inserts at the end; we then move it with TrackFX_CopyToTrack.
local function addPluginAt(plugin, dest_idx)
    refreshTrack()
    if not Core.isTrackValid() then
        flash("No track selected")
        return false
    end
    local track = Core.state.track
    local before = r.TrackFX_GetCount(track)
    local fx_name = FXManager.buildFXName(plugin)
    local ok = FXManager.addFXByName(fx_name, state.auto_open, true)
    if not ok then
        flash("Failed to add: " .. (plugin.display_name or plugin.name))
        return false
    end
    if not state.auto_open then
        r.TrackFX_Show(track, before, 2)  -- close any floating window for the new FX
    end
    local final_idx = before
    if dest_idx and dest_idx >= 0 and dest_idx < before then
        -- Move the freshly inserted FX (at index `before`) to dest_idx.
        r.TrackFX_CopyToTrack(track, before, track, dest_idx, true)
        final_idx = dest_idx
    end
    pushRecent(plugin.name)
    applyPostInsert(final_idx)
    return true
end

-- ---------------------------------------------------------------------------
-- UI helpers (V2)
-- ---------------------------------------------------------------------------
-- Icon-only square button. Returns clicked.
local function iconBtn(id, icon_fn, tooltip, opts)
    local theme = UI.GetTheme()
    opts = opts or {}
    local size = opts.size or theme.button_height
    local Core_tk = UI.Core
    local cx, cy = UI.GetCursorPos()
    local clicked = UI.Button(id, "", { width = size, height = size })
    -- Draw the icon centered over the button face.
    local color = opts.color or theme.colors.text
    icon_fn(cx, cy, size, color[1], color[2], color[3], color[4] or 1)
    if tooltip and Core_tk.MouseInRect(cx, cy, size, size) then
        UI.Tooltip(tooltip)
    end
    return clicked
end

-- ---------------------------------------------------------------------------
-- UI: top toolbar (V2)
--   [Search ........................ flex] [Scan] [Sort A-Z]
-- ---------------------------------------------------------------------------
local function drawToolbar()
    local theme = UI.GetTheme()
    local btn   = theme.button_height
    local gap   = theme.gap or 4
    -- Total available width minus 2 icon buttons + 2 gaps.
    local avail = UI.GetAvailableWidth()
    local search_w = math.max(120, avail - (btn + gap) * 2)

    local sc, sv = UI.InputText("fxbr_search", "", state.search,
        { hint = "Search FX (multi-word)…", width = search_w })
    if sc then
        state.search = sv
        state.selected_idx = 0
    end
    UI.SameLine(gap)
    if iconBtn("fxbr_scan", UI.Icons.Scan, "Rescan plugin database") then
        local n = FXDatabase.scanPlugins()
        flash("Scanned " .. n .. " plugins")
    end
    UI.SameLine(gap)
    local sort_tip = (state.sort_mode == "az") and "Sort A→Z (click for Z→A)"
                                                or  "Sort Z→A (click for A→Z)"
    if iconBtn("fxbr_sort", UI.Icons.Sort, sort_tip) then
        state.sort_mode = (state.sort_mode == "az") and "za" or "az"
        persistConfig()
    end
end

-- ---------------------------------------------------------------------------
-- UI: type filter chip row (V2 — single line, horizontally scrollable)
--   [All] [★] [⏱] [V3] [V] [JS] [B] | [tab1] [tab2] … [+]
-- ---------------------------------------------------------------------------
local function drawFilterChips()
    local Core_tk = UI.Core
    local theme   = UI.GetTheme()
    local chip_h  = theme.chip_h or theme.button_height
    local pad_x   = theme.frame_padding_x
    local gap     = theme.gap or 4
    local icon_w  = chip_h

    local row_h = chip_h + (theme.pad_small or 4) * 2
    UI.BeginChild("fxbr_chips", 0, row_h,
        { scrollable = false, scrollable_x = true, border = false,
          padding = theme.pad_small or 4 })

    -- Built-in chips
    for _, f in ipairs(BUILTIN_FILTERS) do
        local is_on = (state.type_filter == f.key)
        local cx, cy = UI.GetCursorPos()
        local clicked
        if f.icon_key then
            -- Icon-only chip — manual draw to skip the label rendering.
            local btn_color = is_on and theme.colors.accent or theme.colors.button
            local hov = Core_tk.MouseInRect(cx, cy, icon_w, chip_h)
                        and not Core_tk.HasPopup()
            if hov and not is_on then btn_color = theme.colors.button_hovered end
            Core_tk.DrawRect(cx, cy, icon_w, chip_h,
                btn_color[1], btn_color[2], btn_color[3], btn_color[4] or 1)
            local fg = is_on and theme.colors.list_selected_text
                              or  theme.colors.text
            UI.Icons[f.icon_key](cx, cy, chip_h, fg[1], fg[2], fg[3], fg[4] or 1)
            UI.Layout.AdvanceCursor(icon_w, chip_h)
            clicked = hov and Core_tk.MouseClicked(1)
        else
            local label = is_on and ("● " .. f.compact) or f.compact
            clicked = UI.Button("chip_" .. f.key, label, { height = chip_h })
        end
        if Core_tk.MouseInRect(cx, cy,
            (f.icon_key and icon_w) or (Core_tk.MeasureText(f.compact) + pad_x * 2),
            chip_h) then
            UI.Tooltip(f.tip)
        end
        if clicked then
            state.type_filter = f.key
            state.selected_idx = 0
            persistConfig()
        end
        UI.SameLine(gap)
    end

    -- Visual separator before user tabs
    if #state.tabs > 0 then
        local sx, sy = UI.GetCursorPos()
        local sc = theme.colors.border_soft or theme.colors.separator
        Core_tk.DrawRect(sx, sy + 2, 1, chip_h - 4,
            sc[1], sc[2], sc[3], sc[4] or 0.6)
        UI.Layout.AdvanceCursor(1, chip_h)
        UI.SameLine(gap)
    end

    -- Custom tabs
    for i, tab in ipairs(state.tabs) do
        local key   = "T:" .. tab.name
        local is_on = (state.type_filter == key)
        local label = (is_on and "● " or "") .. tab.name
                      .. "  " .. #tab.plugin_names
        local cx, cy = UI.GetCursorPos()
        local w = Core_tk.MeasureText(label) + pad_x * 2
        if UI.Button("chip_tab_" .. i, label, { height = chip_h }) then
            state.type_filter = key
            state.selected_idx = 0
            persistConfig()
        end
        local dropped = UI.BeginDropTarget(cx, cy, w, chip_h, "fx_plugins")
        if dropped and type(dropped) == "table" then
            local names = {}
            for _, p in ipairs(dropped) do names[#names + 1] = p.name end
            local added = addNamesToTab(tab, names)
            flash(("Added %d to %s"):format(added, tab.name))
        end
        if Core_tk.MouseInRect(cx, cy, w, chip_h) then
            local idx, nm = i, tab.name
            UI.ContextMenu("tabctx_" .. i, {
                { label = "Rename…", action = function()
                    state.rename_tab_idx  = idx
                    state.rename_tab_name = nm
                end },
                { label = "Delete",  action = function()
                    state.delete_tab_idx = idx
                end },
            })
        end
        UI.SameLine(gap)
    end

    -- "+" chip
    if iconBtn("chip_tab_add", UI.Icons.Plus, "New tab",
               { size = chip_h }) then
        state.new_tab_open = true
        state.new_tab_name = ""
    end

    UI.EndChild()

    -- Apply deferred tab deletion
    if state.delete_tab_idx then
        local idx = state.delete_tab_idx
        state.delete_tab_idx = nil
        local victim = state.tabs[idx]
        if victim and ("T:" .. victim.name) == state.type_filter then
            state.type_filter = "All"
        end
        table.remove(state.tabs, idx)
        persistConfig()
    end
end

-- ---------------------------------------------------------------------------
-- UI: track header (V2 — single muted caption line)
-- ---------------------------------------------------------------------------
local function drawTrackHeader()
    local track = Core.state.track
    local label
    if track then
        local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        if name == "" then
            local idx = math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
            name = "Track " .. tostring(idx)
        end
        local fx_count = r.TrackFX_GetCount(track)
        label = "● " .. name .. "  ·  " .. fx_count .. " FX"
    else
        label = "No track selected — pick a track in REAPER"
    end
    local theme = UI.GetTheme()
    local tc = theme.colors.text_mute or theme.colors.text_disabled
    UI.SetFontCaption()
    UI.TextColored(label, tc[1], tc[2], tc[3], tc[4] or 1)
    UI.SetFontBody()
end

-- ---------------------------------------------------------------------------
-- UI: plugins pane (left, V2)
-- ---------------------------------------------------------------------------
local function drawPluginsPane(theme, plugins, w, h)
    local Core_tk = UI.Core
    local pad     = theme.pad_small or 4
    local row_h   = theme.row_h or theme.combo_height
    local fav_w   = row_h         -- icon column

    UI.BeginChild("fxbr_left", w, h,
        { scrollable = false, border = false, padding = pad,
          bg = theme.colors.surface })

    -- Mini header (uppercase, muted) — single line above the list.
    UI.SetFontCaption()
    local tm = theme.colors.text_mute or theme.colors.text_disabled
    local sel_count = 0
    for _ in pairs(state.selected) do sel_count = sel_count + 1 end
    local hdr = (sel_count > 0)
        and string.format("PLUGINS  %d  ·  %d sel", #plugins, sel_count)
        or  string.format("PLUGINS  %d", #plugins)
    UI.TextColored(hdr, tm[1], tm[2], tm[3], tm[4] or 1)
    UI.SetFontBody()

    -- Inner scrollable region — fills the rest of the pane.
    local list_h = h - row_h - pad * 2
    UI.BeginChild("fxbr_pluglist", 0, list_h,
        { scrollable = true, border = true, padding = 0,
          bg = theme.colors.list_bg or theme.colors.surface })

    local list_x, list_y = UI.GetCursorPos()
    local list_w = UI.GetAvailableWidth()
    local has_popup = Core_tk.HasPopup and Core_tk.HasPopup() or false

    -- Click intent (computed once per frame, applied below).
    -- For an unmodified click on an already-selected row we DEFER the
    -- "set to single" until release (so a drag can start with the multi-sel).
    local click_intent_idx = nil      -- which row is being clicked
    local click_intent_mode = nil     -- "set" | "toggle" | "range" | "set_deferred"
    local fav_toggle_idx   = nil
    local rclick_row_idx   = nil      -- right-clicked row index (for context menu)

    -- Helper: clip a label so it fits within a max width, adding "…"
    local function ellipsis(text, max_w)
        local tw = Core_tk.MeasureText(text)
        if tw <= max_w then return text end
        local s = text
        while #s > 1 and Core_tk.MeasureText(s .. "…") > max_w do
            s = s:sub(1, -2)
        end
        return s .. "…"
    end

    for i, p in ipairs(plugins) do
        local row_y = list_y + (i - 1) * row_h
        if Core_tk.IsVisible(list_x, row_y, list_w, row_h) then
            local fav     = FXDatabase.isFavorite(p.name)
            local is_sel  = state.selected[p.name] == true
            local hovered = (not has_popup)
                            and Core_tk.MouseInRect(list_x, row_y, list_w, row_h)

            -- Background
            if is_sel then
                local ac = theme.colors.accent_dim or theme.colors.accent
                Core_tk.DrawRect(list_x, row_y, list_w, row_h,
                                 ac[1], ac[2], ac[3], ac[4] or 1)
            elseif hovered then
                local hc = theme.colors.surface2 or theme.colors.header_hovered
                Core_tk.DrawRect(list_x, row_y, list_w, row_h,
                                 hc[1], hc[2], hc[3], hc[4] or 1)
            end

            -- Favorite icon (left column, clickable)
            local fav_x = list_x + pad
            local fc = fav and theme.colors.accent or theme.colors.text_mute
                         or theme.colors.text_disabled
            local fav_icon = fav and UI.Icons.StarFilled or UI.Icons.Star
            fav_icon(fav_x, row_y + math.floor((row_h - row_h * 0.7) / 2),
                     row_h * 0.7, fc[1], fc[2], fc[3], fc[4] or 1)

            -- Reserve space for the vertical scrollbar so the rightmost
            -- column never overlaps it.
            local sb_w = theme.scrollbar_width or 6
            local right_edge = list_x + list_w - sb_w - pad

            -- Type indicator (right side, mono-ish dim text — use plugin.type)
            local type_str = p.type or ""
            local type_w = Core_tk.MeasureText(type_str)
            local type_x = right_edge - type_w
            local tym = theme.colors.text_mute or theme.colors.text_disabled
            Core_tk.DrawText(type_str, type_x,
                             row_y + math.floor((row_h - select(2, Core_tk.MeasureText(type_str))) / 2),
                             tym[1], tym[2], tym[3], tym[4] or 1)

            -- Label (between fav icon and type indicator, ellipsised)
            local label = p.display_name or p.name
            local label_x = list_x + fav_w + pad
            local label_max_w = type_x - label_x - pad
            label = ellipsis(label, label_max_w)
            local _, lh = Core_tk.MeasureText(label)
            local tc = is_sel and theme.colors.list_selected_text or theme.colors.text
            Core_tk.DrawText(label, label_x,
                             row_y + math.floor((row_h - lh) / 2),
                             tc[1], tc[2], tc[3], tc[4] or 1)

            -- Click handling
            if hovered and Core_tk.MouseClicked(1) then
                local mx = Core_tk.GetMousePos()
                if mx and mx >= fav_x and mx < fav_x + fav_w - 4 then
                    fav_toggle_idx = i
                elseif Core_tk.ModAlt()
                       and state.type_filter
                       and state.type_filter:sub(1, 2) == "T:" then
                    -- Alt+Click on a row inside a custom tab → remove from tab
                    local _, tab = findTab(state.type_filter:sub(3))
                    if tab then
                        removeNameFromTab(tab, p.name)
                        state.selected[p.name] = nil
                        flash("Removed from " .. tab.name)
                    end
                else
                    click_intent_idx = i
                    if Core_tk.ModShift() then
                        click_intent_mode = "range"
                    elseif Core_tk.ModCtrl() then
                        click_intent_mode = "toggle"
                    elseif state.selected[p.name] then
                        -- Click on an already-selected row: defer "set" until
                        -- release, so a drag can carry the existing multi-sel.
                        click_intent_mode = "set_deferred"
                    else
                        click_intent_mode = "set"
                    end
                    Core_tk.SetActive("fxbr_plug_drag")
                end
            end

            -- Double-click adds the plugin (legacy convenience).
            -- Suppressed under Alt so Alt-clicks never trigger an add.
            if hovered and Core_tk.MouseDoubleClicked()
               and not Core_tk.ModAlt() then
                addPlugin(p)
            end

            -- Right-click on a row → remember which row to anchor the menu on
            if hovered and Core_tk.MouseClicked(2) then
                rclick_row_idx = i
                -- Make sure the row is in the selection so the menu's
                -- "Add to track" / "Add as favorite" act on it.
                if not state.selected[p.name] then
                    state.selected = { [p.name] = true }
                    state.selected_idx = i
                end
            end
        end
    end

    -- Single ContextMenu rendered once after the loop, anchored on the
    -- right-clicked row (if any). Widgets.ContextMenu opens itself on the
    -- frame's MouseClicked(2), so we just provide the items.
    if rclick_row_idx and plugins[rclick_row_idx] then
        local p = plugins[rclick_row_idx]
        local in_tab  = state.type_filter and state.type_filter:sub(1, 2) == "T:"
        local is_fav  = FXDatabase.isFavorite(p.name)
        local items = {
            { label = "Add to track", action = function()
                  addPlugin(p)
              end },
            { separator = true },
            { label = is_fav and "★ Remove favorite" or "☆ Add to favorites",
              action = function()
                  FXDatabase.toggleFavorite(p.name)
              end },
        }
        if in_tab then
            local tab_name = state.type_filter:sub(3)
            local _, tab = findTab(tab_name)
            if tab then
                items[#items + 1] = { separator = true }
                items[#items + 1] = {
                    label = "Remove from " .. tab_name,
                    action = function()
                        removeNameFromTab(tab, p.name)
                        state.selected[p.name] = nil
                        flash("Removed from " .. tab_name)
                    end,
                }
            end
        end
        UI.ContextMenu("fxbr_plug_ctx", items)
    end

    -- Apply selection change
    if fav_toggle_idx and plugins[fav_toggle_idx] then
        FXDatabase.toggleFavorite(plugins[fav_toggle_idx].name)
    elseif click_intent_idx then
        local p = plugins[click_intent_idx]
        if p then
            if click_intent_mode == "set" then
                state.selected = { [p.name] = true }
                state.selected_idx = click_intent_idx
            elseif click_intent_mode == "toggle" then
                state.selected[p.name] = (not state.selected[p.name]) and true or nil
                state.selected_idx = click_intent_idx
            elseif click_intent_mode == "range" then
                local anchor = state.selected_idx
                if anchor < 1 or anchor > #plugins then anchor = click_intent_idx end
                local lo = math.min(anchor, click_intent_idx)
                local hi = math.max(anchor, click_intent_idx)
                state.selected = {}
                for j = lo, hi do
                    if plugins[j] then state.selected[plugins[j].name] = true end
                end
            elseif click_intent_mode == "set_deferred" then
                -- Remember which row to collapse-to-single if release without drag
                state._pending_collapse_idx = click_intent_idx
                state.selected_idx = click_intent_idx
            end
        end
    end

    -- If user released without starting a drag → collapse selection to the
    -- single clicked row (like Explorer). The drag state's "active" flag is
    -- only set by BeginDragSource once it observes mouse movement.
    if state._pending_collapse_idx and Core_tk.MouseReleased(1) then
        local idx = state._pending_collapse_idx
        state._pending_collapse_idx = nil
        if not UI.IsDragging("fx_plugins") and plugins[idx] then
            state.selected = { [plugins[idx].name] = true }
            state.selected_idx = idx
        end
    end

    -- (Drag source for "fxbr_plug_drag" is registered EARLY in frame() so
    -- drop targets that appear before this pane in draw order — like the
    -- tab chips up top — can still react to the drop in the same frame.)

    -- Reserve scrollable area
    UI.Layout.AdvanceCursor(list_w, math.max(#plugins * row_h, list_h))
    UI.EndChild()

    UI.EndChild()
end

-- ---------------------------------------------------------------------------
-- UI: track FX chain pane (right, V2)
--   Mini header → list with grip + index + name + actions hover-only.
-- ---------------------------------------------------------------------------
local function drawChainPane(theme, w, h)
    local Core_tk = UI.Core
    local pad     = theme.pad_small or 4

    UI.BeginChild("fxbr_right", w, h,
        { scrollable = false, border = false, padding = pad,
          bg = theme.colors.surface })

    local track = Core.state.track
    local fx_count = Core.isTrackValid() and r.TrackFX_GetCount(track) or 0

    -- Build visible items (skip Sound Generator helpers).
    local visible = {}
    if Core.isTrackValid() then
        for fx_idx = 0, fx_count - 1 do
            local _, fx_name = r.TrackFX_GetFXName(track, fx_idx, "")
            if not isSoundGenFX(track, fx_idx) then
                visible[#visible + 1] = {
                    fx_idx  = fx_idx,
                    display = Core.extractFXName(fx_name),
                    type    = (fx_name or ""):match("^([^:]+):") or "",
                    enabled = r.TrackFX_GetEnabled(track, fx_idx),
                }
            end
        end
    end

    -- Mini header
    UI.SetFontCaption()
    local tm = theme.colors.text_mute or theme.colors.text_disabled
    UI.TextColored(string.format("CHAIN  %d", #visible),
        tm[1], tm[2], tm[3], tm[4] or 1)
    UI.SetFontBody()

    local row_h = theme.row_h_large or theme.tab_height
    local list_h = h - row_h - pad * 2

    UI.BeginChild("fxbr_chainlist", 0, list_h,
        { scrollable = true, border = true, padding = 0,
          bg = theme.colors.list_bg or theme.colors.surface })

    if not Core.isTrackValid() then
        UI.SetFontCaption()
        UI.TextColored("No track selected.", tm[1], tm[2], tm[3], tm[4] or 1)
        UI.SetFontBody()
        UI.EndChild()
        UI.EndChild()
        return
    end

    local list_x, list_y = UI.GetCursorPos()
    local list_w = UI.GetAvailableWidth()
    local btn_w  = row_h          -- square hover-action buttons
    local has_popup = Core_tk.HasPopup and Core_tk.HasPopup() or false

    -- Local ellipsis helper
    local function ellipsis(text, max_w)
        local tw = Core_tk.MeasureText(text)
        if tw <= max_w then return text end
        local s = text
        while #s > 1 and Core_tk.MeasureText(s .. "…") > max_w do
            s = s:sub(1, -2)
        end
        return s .. "…"
    end

    -- Pending actions to apply once after the loop (avoid mutating fx during iteration)
    local action      = nil      -- "open" | "bypass" | "delete" | "select"
    local action_fx   = nil
    local reorder_src = nil      -- fx_idx being dragged
    local reorder_dst = nil      -- destination fx_idx (insert before)
    local plugin_drop = nil      -- payload from incoming plugin DnD
    local plugin_dst  = nil      -- destination fx_idx

    if #visible == 0 then
        local dropped = UI.BeginDropTarget(list_x, list_y, list_w, list_h - pad,
                                           "fx_plugins")
        if dropped then
            plugin_drop = dropped
            plugin_dst  = nil  -- append
        end
        UI.SetFontCaption()
        UI.TextColored("No FX on track.", tm[1], tm[2], tm[3], tm[4] or 1)
        UI.SetFontBody()
    else
        local idx_w   = Core_tk.MeasureText("00") + pad * 2
        local actions_w = btn_w * 3   -- 3 hover-only icons

        for i, v in ipairs(visible) do
            local row_y    = list_y + (i - 1) * row_h
            local hovered  = (not has_popup)
                             and Core_tk.MouseInRect(list_x, row_y, list_w, row_h)
            local is_sel   = (state.chain_selected == v.fx_idx)
            -- Header zone = whole row minus the actions area
            local header_w = list_w - (hovered and actions_w or 0)

            -- Background
            if is_sel then
                local ac = theme.colors.accent_dim or theme.colors.accent
                Core_tk.DrawRect(list_x, row_y, list_w, row_h,
                                 ac[1], ac[2], ac[3], ac[4] or 1)
            elseif hovered then
                local hc = theme.colors.surface2 or theme.colors.header_hovered
                Core_tk.DrawRect(list_x, row_y, list_w, row_h,
                                 hc[1], hc[2], hc[3], hc[4] or 1)
            end

            -- Index (1-based, padded to 2 digits, mono-ish)
            local idx_str = string.format("%02d", i)
            local idx_tc  = theme.colors.text_mute or theme.colors.text_disabled
            UI.SetFontMono()
            local _, idx_h = Core_tk.MeasureText(idx_str)
            Core_tk.DrawText(idx_str,
                list_x + pad,
                row_y + math.floor((row_h - idx_h) / 2),
                idx_tc[1], idx_tc[2], idx_tc[3], idx_tc[4] or 1)
            UI.SetFontBody()

            -- Label (between index and the right edge), bypassed = amber + strike-through
            local label_x   = list_x + pad + idx_w
            local label_max = header_w - label_x + list_x - pad
            local label = ellipsis(v.display, label_max)
            local _, lh = Core_tk.MeasureText(label)
            local label_y = row_y + math.floor((row_h - lh) / 2)
            local tc
            if not v.enabled then
                tc = theme.colors.bypass or theme.colors.text_disabled
            elseif is_sel then
                tc = theme.colors.list_selected_text or theme.colors.text
            else
                tc = theme.colors.text
            end
            Core_tk.DrawText(label, label_x, label_y,
                tc[1], tc[2], tc[3], tc[4] or 1)
            -- Strike-through line for bypassed
            if not v.enabled then
                local lw = Core_tk.MeasureText(label)
                Core_tk.DrawLine(label_x,
                    label_y + math.floor(lh / 2),
                    label_x + lw,
                    label_y + math.floor(lh / 2),
                    tc[1], tc[2], tc[3], tc[4] or 1)
            end

            -- Header click handling:
            --   Alt+Click   → delete
            --   Shift+Click → toggle bypass
            --   plain Click → select + start drag
            if hovered and Core_tk.MouseClicked(1) then
                local mx = Core_tk.GetMousePos()
                if mx and mx < list_x + header_w then
                    if Core_tk.ModAlt() then
                        action = "delete"
                    elseif Core_tk.ModShift() then
                        action = "bypass"
                    else
                        action = "select"
                        Core_tk.SetActive("fxbr_chain_drag_" .. v.fx_idx)
                    end
                    action_fx = v.fx_idx
                end
            end
            UI.BeginDragSource("fxbr_chain_drag_" .. v.fx_idx,
                               v.fx_idx, "fx_chain", "↕ " .. v.display)

            -- Drop targets on the header zone
            local dropped_chain = UI.BeginDropTarget(
                list_x, row_y, header_w, row_h, "fx_chain")
            if dropped_chain ~= nil then
                reorder_src = dropped_chain
                reorder_dst = v.fx_idx
            end
            local dropped_plug = UI.BeginDropTarget(
                list_x, row_y, header_w, row_h, "fx_plugins")
            if dropped_plug ~= nil then
                plugin_drop = dropped_plug
                plugin_dst  = v.fx_idx
            end

            -- Hover-only action icons (right-aligned: Open / Bypass / Delete)
            if hovered then
                local function chainAction(idx_in_row, icon_fn, color)
                    local bx = list_x + list_w - btn_w * idx_in_row
                    local hov = Core_tk.MouseInRect(bx, row_y, btn_w, row_h)
                                and not has_popup
                    if hov then
                        local hc = theme.colors.button_hovered
                        Core_tk.DrawRect(bx, row_y, btn_w, row_h,
                            hc[1], hc[2], hc[3], hc[4] or 1)
                    end
                    icon_fn(bx, row_y, row_h,
                        color[1], color[2], color[3], color[4] or 1)
                    return hov and Core_tk.MouseClicked(1)
                end
                if chainAction(3, UI.Icons.Play, theme.colors.text) then
                    action = "open"; action_fx = v.fx_idx
                end
                local eye_color = v.enabled and theme.colors.text
                                            or  (theme.colors.bypass
                                                 or theme.colors.text_disabled)
                local eye_icon = v.enabled and UI.Icons.Eye or UI.Icons.EyeOff
                if chainAction(2, eye_icon, eye_color) then
                    action = "bypass"; action_fx = v.fx_idx
                end
                if chainAction(1, UI.Icons.Delete,
                               theme.colors.danger or theme.colors.text) then
                    action = "delete"; action_fx = v.fx_idx
                end
            end

            -- Double-click on header → open FX UI (suppressed under Alt)
            if hovered and Core_tk.MouseDoubleClicked()
               and not Core_tk.ModAlt() then
                local mx = Core_tk.GetMousePos()
                if mx and mx < list_x + header_w then
                    action = "open"; action_fx = v.fx_idx
                end
            end
        end

        -- Drop zone after last row → append
        local tail_y = list_y + #visible * row_h
        local tail_h = math.max(row_h, list_h - (#visible * row_h) - 8)
        local tail_chain = UI.BeginDropTarget(list_x, tail_y, list_w,
                                              tail_h, "fx_chain")
        if tail_chain ~= nil then
            reorder_src = tail_chain
            reorder_dst = fx_count  -- past the end
        end
        local tail_plug = UI.BeginDropTarget(list_x, tail_y, list_w,
                                             tail_h, "fx_plugins")
        if tail_plug ~= nil then
            plugin_drop = tail_plug
            plugin_dst  = nil  -- append
        end
    end

    UI.Layout.AdvanceCursor(list_w, math.max(#visible * row_h + 24, list_h))
    UI.EndChild()

    -- Apply pending actions ----------------------------------------------------
    if action and action_fx then
        if action == "select" then
            state.chain_selected = action_fx
        elseif action == "open" then
            r.TrackFX_Show(track, action_fx, 3)
        elseif action == "bypass" then
            local en = r.TrackFX_GetEnabled(track, action_fx)
            r.TrackFX_SetEnabled(track, action_fx, not en)
        elseif action == "delete" then
            r.TrackFX_Delete(track, action_fx)
            if state.chain_selected == action_fx then state.chain_selected = nil end
        end
    end

    if reorder_src and reorder_dst and reorder_src ~= reorder_dst then
        -- Ctrl held at drop time → duplicate (copy), otherwise move.
        local copy = Core_tk.ModCtrl()
        r.Undo_BeginBlock()
        if copy then
            r.TrackFX_CopyToTrack(track, reorder_src, track, reorder_dst, false)
            if not state.auto_open then
                r.TrackFX_Show(track, reorder_dst, 2)
            end
            r.Undo_EndBlock("Duplicate FX", -1)
            flash("Duplicated FX")
        else
            r.TrackFX_CopyToTrack(track, reorder_src, track, reorder_dst, true)
            r.Undo_EndBlock("Reorder FX", -1)
        end
    end

    if plugin_drop then
        r.Undo_BeginBlock()
        local insert_at = plugin_dst  -- nil = append
        for _, p in ipairs(plugin_drop) do
            addPluginAt(p, insert_at)
            if insert_at then insert_at = insert_at + 1 end
        end
        r.Undo_EndBlock("Add FX from drop", -1)
        flash("Added " .. #plugin_drop .. " FX")
    end

    UI.EndChild()
end

-- ---------------------------------------------------------------------------
-- Add-selection helper used by both the footer button and the keyboard hooks.
-- ---------------------------------------------------------------------------
local function addSelectionToTrack(plugins)
    local sel = collectSelected(plugins)
    if #sel == 0 and plugins[state.selected_idx] then
        sel = { plugins[state.selected_idx] }
    end
    if #sel == 0 then return end
    -- Shift while a custom tab is active → add to tab, not the track.
    local tab_key = state.type_filter
    if UI.Core.ModShift() and tab_key and tab_key:sub(1, 2) == "T:" then
        local _, tab = findTab(tab_key:sub(3))
        if tab then
            local names = {}
            for _, p in ipairs(sel) do names[#names + 1] = p.name end
            local added = addNamesToTab(tab, names)
            flash(("Added %d to %s"):format(added, tab.name))
        end
        return
    end
    r.Undo_BeginBlock()
    local removed = 0
    if state.rand_replace then removed = clearChain(Core.state.track) end
    for _, p in ipairs(sel) do addPlugin(p) end
    r.Undo_EndBlock(state.rand_replace and "Replace chain with selection"
                                       or  "Add selected FX", -1)
    local msg = "Added " .. #sel .. " FX"
    if state.rand_replace and removed > 0 then
        msg = msg .. " (replaced " .. removed .. ")"
    end
    flash(msg)
end

-- ---------------------------------------------------------------------------
-- UI: bottom-bar (V2 — single line)
--   [Add (N)] | [🎲][▰▰▰▱ count] ··· [⌫][⚙]
-- ---------------------------------------------------------------------------
local function drawFooter(theme, plugins)
    local Core_tk = UI.Core
    local btn     = theme.button_height
    local pad     = theme.pad_small or 4
    local gap     = theme.gap or 4

    -- Footer container with surface bg and top border
    local footer_h = btn + pad * 2
    UI.BeginChild("fxbr_footer", 0, footer_h,
        { scrollable = false, border = false, padding = pad,
          bg = theme.colors.surface })

    -- Selection count for the Add button label
    local sel_count = 0
    for _ in pairs(state.selected) do sel_count = sel_count + 1 end
    if sel_count == 0 and plugins[state.selected_idx] then sel_count = 1 end

    local add_label = "Add"
    if sel_count > 0 then add_label = string.format("Add (%d)", sel_count) end
    local add_disabled = (sel_count == 0)

    -- Primary "Add" button
    if UI.Button("fxbr_addsel", add_label,
                 { height = btn, disabled = add_disabled }) then
        addSelectionToTrack(plugins)
    end
    UI.SameLine(gap)

    -- Visual separator
    do
        local sx, sy = UI.GetCursorPos()
        local sc = theme.colors.border_soft or theme.colors.separator
        Core_tk.DrawRect(sx, sy + 4, 1, btn - 8,
            sc[1], sc[2], sc[3], sc[4] or 0.6)
        UI.Layout.AdvanceCursor(1, btn)
        UI.SameLine(gap)
    end

    -- Random dice + count slider
    if iconBtn("fxbr_dice", UI.Icons.Dice, "Add random FX (uses count)") then
        refreshTrack()
        if not Core.isTrackValid() then
            flash("No track selected")
        else
            local from_visible = state.rand_from_visible
            local track = Core.state.track
            r.Undo_BeginBlock()
            local removed = 0
            if state.rand_replace then removed = clearChain(track) end
            local before = r.TrackFX_GetCount(track)
            if from_visible and #plugins > 0 then
                local pool, picks = {}, {}
                for _, p in ipairs(plugins) do pool[#pool + 1] = p end
                local n = math.min(state.rand_count, #pool)
                for _ = 1, n do
                    local idx = math.random(1, #pool)
                    picks[#picks + 1] = pool[idx]
                    table.remove(pool, idx)
                end
                for _, p in ipairs(picks) do addPlugin(p) end
            else
                FXManager.addRandomFX(state.rand_count, state.rand_fav_only)
            end
            local after = r.TrackFX_GetCount(track)
            if not state.auto_open then
                for i = before, after - 1 do r.TrackFX_Show(track, i, 2) end
            end
            -- Apply post-insert macros to each newly-added FX. The
            -- "from_visible" path already hits applyPostInsert via addPlugin,
            -- so we only need to walk new indices for the database-random path.
            if not from_visible then
                for i = before, after - 1 do applyPostInsert(i) end
            end
            r.Undo_EndBlock(state.rand_replace
                and "Replace chain with random FX" or "Add random FX", -1)
            local msg = "Added " .. (after - before) .. " random FX"
            if state.rand_replace and removed > 0 then
                msg = msg .. " (replaced " .. removed .. ")"
            end
            flash(msg)
        end
    end
    UI.SameLine(gap)

    local slider_w = math.floor(btn * 3.5)
    local rc, rv = UI.SliderInt("fxbr_rcount", "", state.rand_count, 1, 12,
                                { width = slider_w, height = btn })
    if rc then state.rand_count = rv; persistConfig() end
    UI.SameLine(gap)

    -- Spacer: push remaining buttons to the right.
    local right_btns = btn * 2 + gap
    local avail = UI.GetAvailableWidth()
    local spacer_w = math.max(0, avail - right_btns)
    UI.Layout.AdvanceCursor(spacer_w, btn)
    UI.SameLine(0)

    -- Clear chain
    if iconBtn("fxbr_clear", UI.Icons.Erase, "Clear FX chain",
               { color = theme.colors.danger }) then
        refreshTrack()
        if Core.isTrackValid() then
            r.Undo_BeginBlock()
            local removed = clearChain(Core.state.track)
            r.Undo_EndBlock("Clear FX chain", -1)
            flash("Cleared " .. removed .. " FX")
        else
            flash("No track selected")
        end
    end
    UI.SameLine(gap)

    -- Settings ⚙: left-click OR right-click opens the menu.
    -- We render the icon manually (not via iconBtn → which checks left-click)
    -- and convert any click on the gear into the right-click that
    -- Widgets.ContextMenu listens for.
    local gear_x, gear_y = UI.GetCursorPos()
    local gear_hov = Core_tk.MouseInRect(gear_x, gear_y, btn, btn)
                     and not Core_tk.HasPopup()
    local bg = gear_hov and theme.colors.button_hovered or theme.colors.button
    Core_tk.DrawRect(gear_x, gear_y, btn, btn,
        bg[1], bg[2], bg[3], bg[4] or 1)
    local gc = theme.colors.text
    UI.Icons.Settings(gear_x, gear_y, btn, gc[1], gc[2], gc[3], gc[4] or 1)
    UI.Layout.AdvanceCursor(btn, btn)
    -- Convert a left-click on the gear into a right-click for ContextMenu.
    -- Core.MouseClicked is a frame-level read-only check, so we can't mutate
    -- it; instead we manually call Core.SetPopup with the same draw function
    -- that ContextMenu would build. We hand-roll a tiny popup here.
    local function openSettingsMenu()
        local items = {
            { label = "Auto-open FX on add",
              checked = state.auto_open,
              action = function()
                  state.auto_open = not state.auto_open
                  persistConfig()
              end },
            { label = "Replace chain on add/random",
              checked = state.rand_replace,
              action = function()
                  state.rand_replace = not state.rand_replace
                  persistConfig()
              end },
            { separator = true },
            { label = "Random from visible only",
              checked = state.rand_from_visible,
              action = function()
                  state.rand_from_visible = not state.rand_from_visible
                  persistConfig()
              end },
            { label = "Random from favorites only",
              checked = state.rand_fav_only,
              action = function()
                  state.rand_fav_only = not state.rand_fav_only
                  persistConfig()
              end },
            { separator = true },
            { label = "Post-insertion macros",
              checked = state.post_insert.enabled,
              action = function()
                  state.post_insert.enabled = not state.post_insert.enabled
                  persistConfig()
              end },
            { label = "Configure post-insertion…",
              action = function()
                  state.post_insert_open = true
              end },
        }
        local item_h = theme.combo_height
        local menu_w = 240
        local visible_count = 0
        for _, it in ipairs(items) do
            visible_count = visible_count + (it.separator and 0.3 or 1)
        end
        local menu_h = math.floor(visible_count * item_h)
        local px = gear_x + btn - menu_w
        local py = gear_y - menu_h - 4

        Core_tk.SetPopup("fxbr_settings_popup", function()
            -- Skip same-frame close: the click that OPENED the popup is still
            -- "fresh" this frame and would immediately trigger close-on-outside.
            local is_new = Core_tk.IsPopupNewThisFrame
                           and Core_tk.IsPopupNewThisFrame() or false
            local pbg = theme.colors.popup_bg
            Core_tk.DrawRect(px, py, menu_w, menu_h,
                pbg[1], pbg[2], pbg[3], pbg[4] or 1)
            local pbc = theme.colors.border
            Core_tk.DrawRect(px, py, menu_w, menu_h,
                pbc[1], pbc[2], pbc[3], 0.6, false)
            local iy = py
            local closed_this_frame = false
            for _, it in ipairs(items) do
                if it.separator then
                    local sep_h = math.floor(item_h * 0.3)
                    local sc = theme.colors.separator
                    Core_tk.DrawLine(px + 4, iy + sep_h / 2,
                        px + menu_w - 4, iy + sep_h / 2,
                        sc[1], sc[2], sc[3], sc[4] or 0.5)
                    iy = iy + sep_h
                else
                    local hov = Core_tk.MouseInRect(px, iy, menu_w, item_h)
                    if hov then
                        local hc = theme.colors.header_hovered
                        Core_tk.DrawRect(px + 1, iy, menu_w - 2, item_h,
                            hc[1], hc[2], hc[3], hc[4] or 1)
                    end
                    local mark = it.checked and "✓ " or "    "
                    local tc = theme.colors.text
                    local _, th = Core_tk.MeasureText(mark .. it.label)
                    Core_tk.DrawText(mark .. it.label,
                        px + 8, iy + math.floor((item_h - th) / 2),
                        tc[1], tc[2], tc[3], tc[4] or 1)
                    if not is_new and hov and Core_tk.MouseClicked(1) then
                        Core_tk.ClearPopup("fxbr_settings_popup")
                        if it.action then it.action() end
                        closed_this_frame = true
                    end
                    iy = iy + item_h
                end
            end
            -- Close on click outside (skipped on the opening frame)
            if not is_new and not closed_this_frame
               and (Core_tk.MouseClicked(1) or Core_tk.MouseClicked(2))
               and not Core_tk.MouseInRect(px, py, menu_w, menu_h) then
                Core_tk.ClearPopup("fxbr_settings_popup")
            end
        end)
    end

    if gear_hov then
        UI.Tooltip("Settings")
        local already_open = Core_tk.HasPopup
                             and Core_tk.HasPopup("fxbr_settings_popup")
        if not already_open
           and (Core_tk.MouseClicked(1) or Core_tk.MouseClicked(2)) then
            openSettingsMenu()
        end
    end

    UI.EndChild()

    -- Status / flash line drawn just above the footer (uses the spacer area).
    if state.flash_msg ~= "" and r.time_precise() < state.flash_until then
        local fc = theme.colors.accent
        UI.SetFontCaption()
        UI.TextColored(state.flash_msg, fc[1], fc[2], fc[3], 1)
        UI.SetFontBody()
    end
end

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------
local function frame(theme)
    refreshTrack()

    -- Compute the filtered plugin list ONCE per frame so we can register the
    -- drag source early. BeginDragSource flips drag_state.dropping inside this
    -- single call, so any drop targets drawn LATER in the frame (chips, chain
    -- pane) can react in the same frame the user releases the mouse.
    local plugins = filteredPlugins()
    if state.selected_idx > 0 and plugins[state.selected_idx] then
        local payload = collectSelected(plugins)
        if #payload == 0 then payload = { plugins[state.selected_idx] } end
        local lbl = (#payload == 1)
            and ("+ " .. (payload[1].display_name or payload[1].name))
            or  ("+ " .. #payload .. " plugins")
        UI.BeginDragSource("fxbr_plug_drag", payload, "fx_plugins", lbl)
    end

    local pad = theme.pad_small or 4
    local pad_l = theme.pad_large or 10

    -- Top: toolbar + chips + track header (rendered with window padding).
    UI.SetWindowPadding(pad_l)
    drawToolbar()
    UI.Spacing(pad)
    drawFilterChips()
    UI.Spacing(pad)
    drawTrackHeader()
    UI.Spacing(pad)

    -- Body fills the rest minus the footer (which we know is btn + 2*pad_small).
    local btn = theme.button_height
    local footer_h = btn + pad * 2
    local body_h = math.max(120, UI.GetAvailableHeight() - footer_h - pad * 2)

    -- Splitter-driven 2-column body. We compute left/right widths from the
    -- persisted ratio. UI.Splitter would be ideal but we want full DnD control;
    -- emulate via fixed-px columns and a manually drawn handle.
    local total_w = UI.GetAvailableWidth()
    local sp_w    = theme.splitter_w or 3
    local left_w  = math.floor((total_w - sp_w) * (state.split_left or 0.6))
    local right_w = total_w - sp_w - left_w

    -- Splitter drag handle (between the two panes)
    local Core_tk = UI.Core
    local sp_id   = "fxbr_splitter"

    UI.BeginColumns("fxbr_body",
        { left_w, sp_w, right_w },
        { gap = 0 })
    drawPluginsPane(theme, plugins, 0, body_h)
    UI.NextColumn()
    -- Splitter visual + interaction
    do
        local sx, sy = UI.GetCursorPos()
        local sc = theme.colors.border_soft or theme.colors.separator
        Core_tk.DrawRect(sx, sy, sp_w, body_h,
            sc[1], sc[2], sc[3], sc[4] or 0.6)
        local hov = Core_tk.MouseInRect(sx, sy, sp_w, body_h)
        if hov then UI.SetCursor("size_we") end
        if hov and Core_tk.MouseClicked(1) then
            Core_tk.SetActive(sp_id)
        end
        if Core_tk.IsActive(sp_id) and Core_tk.MouseDown(1) then
            local mx = Core_tk.GetMousePos()
            local pane_x0 = sx - left_w  -- start of the body region
            local new_ratio = (mx - pane_x0) / total_w
            if new_ratio < 0.30 then new_ratio = 0.30 end
            if new_ratio > 0.75 then new_ratio = 0.75 end
            state.split_left = new_ratio
        end
        if Core_tk.IsActive(sp_id) and Core_tk.MouseReleased(1) then
            Core_tk.ClearActive()
            persistConfig()
        end
        UI.Layout.AdvanceCursor(sp_w, body_h)
    end
    UI.NextColumn()
    drawChainPane(theme, 0, body_h)
    UI.EndColumns()

    UI.Spacing(pad)
    drawFooter(theme, plugins)

    -- New-tab modal -----------------------------------------------------------
    if state.new_tab_open then
        UI.BeginModal("fxbr_newtab", "New tab", { width = 320, height = 130 })
        UI.Text("Name:")
        UI.SetFocus("fxbr_newtab_name")
        local _, nv, submitted = UI.InputText("fxbr_newtab_name", "",
            state.new_tab_name, { hint = "tab name…" })
        state.new_tab_name = nv or state.new_tab_name
        UI.Spacing(6)
        UI.BeginColumns("fxbr_newtab_btns", { 0.5, 0.5 }, { gap = 6 })
        local create = UI.Button("fxbr_newtab_ok", "Create") or submitted
        UI.NextColumn()
        local cancel = UI.Button("fxbr_newtab_cancel", "Cancel")
        UI.EndColumns()
        if create then
            local nm = (state.new_tab_name or ""):match("^%s*(.-)%s*$") or ""
            if nm ~= "" and not findTab(nm) then
                state.tabs[#state.tabs + 1] = { name = nm, plugin_names = {} }
                persistConfig()
                -- If user already has a selection, seed the tab with it.
                local sel = collectSelected(plugins)
                if #sel > 0 then
                    local names = {}
                    for _, p in ipairs(sel) do names[#names + 1] = p.name end
                    addNamesToTab(state.tabs[#state.tabs], names)
                end
                state.type_filter = "T:" .. nm
                persistConfig()
                state.new_tab_open = false
            elseif nm == "" then
                flash("Name cannot be empty")
            else
                flash("Tab already exists")
            end
        elseif cancel then
            state.new_tab_open = false
        end
        UI.EndModal()
    end

    -- Rename-tab modal --------------------------------------------------------
    if state.rename_tab_idx then
        UI.BeginModal("fxbr_renametab", "Rename tab",
            { width = 320, height = 130 })
        UI.Text("New name:")
        UI.SetFocus("fxbr_renametab_name")
        local _, nv, submitted = UI.InputText("fxbr_renametab_name", "",
            state.rename_tab_name, { hint = "tab name…" })
        state.rename_tab_name = nv or state.rename_tab_name
        UI.Spacing(6)
        UI.BeginColumns("fxbr_renametab_btns", { 0.5, 0.5 }, { gap = 6 })
        local ok = UI.Button("fxbr_renametab_ok", "Rename") or submitted
        UI.NextColumn()
        local cancel = UI.Button("fxbr_renametab_cancel", "Cancel")
        UI.EndColumns()
        if ok then
            local nm = (state.rename_tab_name or ""):match("^%s*(.-)%s*$") or ""
            local tab = state.tabs[state.rename_tab_idx]
            if nm == "" then
                flash("Name cannot be empty")
            elseif tab and (tab.name == nm or not findTab(nm)) then
                local was_active = (state.type_filter == "T:" .. tab.name)
                tab.name = nm
                if was_active then state.type_filter = "T:" .. nm end
                persistConfig()
                state.rename_tab_idx = nil
            else
                flash("Tab already exists")
            end
        elseif cancel then
            state.rename_tab_idx = nil
        end
        UI.EndModal()
    end

    -- Post-insertion macros config modal --------------------------------------
    if state.post_insert_open then
        UI.BeginModal("fxbr_postins", "Post-insertion macros",
            { width = 400, height = 600 })
        local pi = state.post_insert

        -- Master toggle
        local ec, ev = UI.Checkbox("pi_enabled",
            "Enable post-insertion macros", pi.enabled)
        if ec then pi.enabled = ev; persistConfig() end
        UI.Separator()
        UI.Spacing(4)

        -- Param selection mode (radio group)
        UI.SetFontH2Bold()
        UI.Text("After insert, select these params:")
        UI.SetFontBody()
        UI.Spacing(2)

        local modes = { "none", "all", "all_cont", "random" }
        local labels = {
            "Don't touch selection",
            "Select all params",
            "Select all continuous params",
            "Select N random params",
        }
        local cur_idx = 1
        for i, m in ipairs(modes) do
            if pi.select_mode == m then cur_idx = i; break end
        end
        local rc, rv = UI.RadioGroup("pi_selmode", "", cur_idx, labels)
        if rc then
            pi.select_mode = modes[rv]
            persistConfig()
        end

        -- Random count slider (only meaningful for "random" mode)
        if pi.select_mode == "random" then
            UI.Spacing(4)
            local sc, sv = UI.SliderInt("pi_count",
                "Random count", pi.random_count, 1, 16)
            if sc then pi.random_count = sv; persistConfig() end
        end

        UI.Spacing(6)
        UI.Separator()
        UI.Spacing(4)

        -- Randomization passes
        UI.SetFontH2Bold()
        UI.Text("Then randomize on selected params:")
        UI.SetFontBody()
        UI.Spacing(2)

        local xc, xv = UI.Checkbox("pi_xy",
            "X/Y axis assignment", pi.randomize_xy)
        if xc then pi.randomize_xy = xv; persistConfig() end

        local rrc, rrv = UI.Checkbox("pi_range",
            "Param ranges (min/max)", pi.randomize_range)
        if rrc then pi.randomize_range = rrv; persistConfig() end

        local bc, bv = UI.Checkbox("pi_base",
            "Base values", pi.randomize_base)
        if bc then pi.randomize_base = bv; persistConfig() end

        local nc, nv = UI.Checkbox("pi_invert",
            "Invert direction (N — positive/negative)",
            pi.randomize_invert)
        if nc then pi.randomize_invert = nv; persistConfig() end

        UI.Spacing(6)
        UI.Separator()
        UI.Spacing(4)

        UI.SetFontH2Bold()
        UI.Text("Then:")
        UI.SetFontBody()
        UI.Spacing(2)

        local byc, byv = UI.Checkbox("pi_bypass",
            "Bypass FX after insertion", pi.bypass_after)
        if byc then pi.bypass_after = byv; persistConfig() end

        UI.Spacing(6)
        UI.Separator()
        UI.Spacing(4)
        local dbc, dbv = UI.Checkbox("pi_debug",
            "Debug (log to ReaConsole)", pi.debug or false)
        if dbc then pi.debug = dbv; persistConfig() end

        UI.Spacing(8)
        if UI.Button("pi_close", "Close") then
            state.post_insert_open = false
        end
        UI.EndModal()
    end

    -- Drag preview overlay (drawn on top of everything)
    UI.DrawDragPreview()
end

-- ---------------------------------------------------------------------------
-- Window setup
-- ---------------------------------------------------------------------------
UI.Init("FX Browser", 555, 750, {
    persist    = "CP_FXBrowser",
    scrollable = false,
    padding    = 0,                    -- handled per-section so the body fills
})

UI.OnClose(function()
    persistConfig()
    Persistence.saveSettings()
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
