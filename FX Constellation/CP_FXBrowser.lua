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
    rand_count     = cfg.rand_count     or 3,
    rand_fav_only  = cfg.rand_fav_only  or false,
    rand_replace   = cfg.rand_replace   or false,
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

local TYPE_FILTERS = { "All", "Favorites", "Recents", "VST3", "VST", "JS", "Bundled" }

local function persistConfig()
    UI.SaveConfig(CONFIG_ID, {
        sort_mode      = state.sort_mode,
        auto_open      = state.auto_open,
        type_filter    = state.type_filter,
        category       = state.category,
        rand_count     = state.rand_count,
        rand_fav_only  = state.rand_fav_only,
        rand_replace   = state.rand_replace,
        recents        = state.recents,
        split_left     = state.split_left,
        tabs           = state.tabs,
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
        if not state.auto_open then
            -- Belt-and-braces: ensure no float window after add.
            local track = Core.state.track
            local n = r.TrackFX_GetCount(track)
            if n > 0 then r.TrackFX_Show(track, n - 1, 2) end
        end
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
    if dest_idx and dest_idx >= 0 and dest_idx < before then
        -- Move the freshly inserted FX (at index `before`) to dest_idx.
        r.TrackFX_CopyToTrack(track, before, track, dest_idx, true)
    end
    pushRecent(plugin.name)
    return true
end

-- ---------------------------------------------------------------------------
-- UI: top toolbar
-- ---------------------------------------------------------------------------
local function drawToolbar()
    UI.BeginColumns("fxbr_top", { 0.55, 0.15, 0.15, 0.15 }, { gap = 6 })

    local sc, sv = UI.InputText("fxbr_search", "", state.search,
                                { hint = "Search FX (multi-word)…" })
    if sc then
        state.search = sv
        state.selected_idx = 0
    end
    UI.NextColumn()

    if UI.Button("fxbr_scan", "Scan") then
        local n = FXDatabase.scanPlugins()
        flash("Scanned " .. n .. " plugins")
    end
    UI.NextColumn()

    local sort_lbl = (state.sort_mode == "az") and "A→Z" or "Z→A"
    if UI.Button("fxbr_sort", sort_lbl) then
        state.sort_mode = (state.sort_mode == "az") and "za" or "az"
        persistConfig()
    end
    UI.NextColumn()

    if UI.Button("fxbr_clear", "Clear") then
        state.search = ""
        state.selected_idx = 0
    end
    UI.EndColumns()
end

-- ---------------------------------------------------------------------------
-- UI: type filter chip row
-- ---------------------------------------------------------------------------
local function drawFilterChips()
    local Core_tk = UI.Core
    local theme   = UI.GetTheme()
    local chip_h  = theme.button_height
    UI.BeginWrap("fxbr_chips", { gap = 4 })

    -- Built-in filter chips
    for _, name in ipairs(TYPE_FILTERS) do
        local is_on = (state.type_filter == name)
        local label = is_on and ("● " .. name) or ("  " .. name)
        if UI.Button("chip_" .. name, label) then
            state.type_filter = name
            state.selected_idx = 0
            persistConfig()
        end
    end

    -- Custom tabs (each is a chip with DnD drop target + right-click menu)
    local fp_x = theme.frame_padding_x
    for i, tab in ipairs(state.tabs) do
        local key   = "T:" .. tab.name
        local is_on = (state.type_filter == key)
        local label = (is_on and "● " or "▸ ") .. tab.name
                      .. " (" .. #tab.plugin_names .. ")"

        -- Replicate Button's width calculation so we know the chip rect
        -- BEFORE drawing it, then overlay the drop target / hover-test.
        local tw = Core_tk.MeasureText(label)
        local chip_w = tw + fp_x * 2
        if UI.Layout.IsWrapping then UI.Layout.WrapPreCheck(chip_w) end
        local cx, cy = UI.GetCursorPos()

        if UI.Button("chip_tab_" .. i, label) then
            state.type_filter = key
            state.selected_idx = 0
            persistConfig()
        end

        -- DnD: accept "fx_plugins" payload → add plugin names to this tab
        local dropped = UI.BeginDropTarget(cx, cy, chip_w, chip_h, "fx_plugins")
        if dropped and type(dropped) == "table" then
            local names = {}
            for _, p in ipairs(dropped) do names[#names + 1] = p.name end
            local added = addNamesToTab(tab, names)
            flash(("Added %d to %s"):format(added, tab.name))
        end

        -- Right-click on the chip → context menu. The action runs on the
        -- popup's frame (N+1), not the right-click frame, so we must write
        -- to persistent `state` (locals would be re-initialised).
        if Core_tk.MouseInRect(cx, cy, chip_w, chip_h) then
            local idx = i
            local nm  = tab.name
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
    end

    -- "+" chip: open new-tab modal
    if UI.Button("chip_tab_add", "  +") then
        state.new_tab_open  = true
        state.new_tab_name  = ""
    end

    UI.EndWrap()

    -- Apply deferred tab deletion (rename is handled by its own modal)
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
-- UI: track header
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
        label = "● " .. name .. "   ·   " .. fx_count .. " FX"
    else
        label = "No track selected — pick a track in REAPER"
    end
    UI.SetFontH2Bold()
    UI.Text(label)
    UI.SetFontBody()
end

-- ---------------------------------------------------------------------------
-- UI: plugins pane (left) — custom rendering with multi-select + drag source
-- ---------------------------------------------------------------------------
local function drawPluginsPane(theme, plugins, w, h)
    UI.BeginChild("fxbr_left", w, h, { scrollable = false, border = true,
                                        padding = 6 })

    UI.SetFontH2Bold()
    UI.Text("Plugins")
    UI.SetFontBody()
    UI.SameLine(8)
    UI.SetFontCaption()
    local sel_count = 0
    for _ in pairs(state.selected) do sel_count = sel_count + 1 end
    if sel_count > 0 then
        UI.Text(string.format("(%d / %d sel)", #plugins, sel_count))
    else
        UI.Text(string.format("(%d)", #plugins))
    end
    UI.SetFontBody()
    UI.Spacing(2)

    local Core_tk = UI.Core
    local row_h   = theme.button_height
    local fav_w   = math.floor(row_h * 1.3)

    -- Inner scrollable region for the row list
    local list_h = math.max(120, h - 64)
    UI.BeginChild("fxbr_pluglist", 0, list_h,
        { scrollable = true, border = false, padding = 2 })

    local list_x, list_y = UI.GetCursorPos()
    local list_w = UI.GetAvailableWidth()
    local has_popup = Core_tk.HasPopup and Core_tk.HasPopup() or false

    -- Click intent (computed once per frame, applied below).
    -- For an unmodified click on an already-selected row we DEFER the
    -- "set to single" until release (so a drag can start with the multi-sel).
    local click_intent_idx = nil      -- which row is being clicked
    local click_intent_mode = nil     -- "set" | "toggle" | "range" | "set_deferred"
    local fav_toggle_idx   = nil

    for i, p in ipairs(plugins) do
        local row_y = list_y + (i - 1) * row_h
        if Core_tk.IsVisible(list_x, row_y, list_w, row_h) then
            local fav     = FXDatabase.isFavorite(p.name)
            local is_sel  = state.selected[p.name] == true
            local hovered = (not has_popup)
                            and Core_tk.MouseInRect(list_x, row_y, list_w, row_h)

            -- Background
            if is_sel then
                local ac = theme.colors.accent
                Core_tk.DrawRect(list_x, row_y, list_w, row_h - 1,
                                 ac[1], ac[2], ac[3], 0.30)
            elseif hovered then
                local hc = theme.colors.header_hovered
                Core_tk.DrawRect(list_x, row_y, list_w, row_h - 1,
                                 hc[1], hc[2], hc[3], 0.25)
            elseif (i % 2) == 0 and theme.colors.list_alt_bg then
                local ab = theme.colors.list_alt_bg
                Core_tk.DrawRect(list_x, row_y, list_w, row_h - 1,
                                 ab[1], ab[2], ab[3], ab[4] or 1)
            end

            -- Favorite glyph (clickable)
            local fav_x  = list_x + 4
            local fav_my = row_y + math.floor(row_h / 2) - 7
            local fc = fav and theme.colors.accent or theme.colors.text_disabled
            Core_tk.DrawText(fav and "★" or "☆",
                             fav_x, fav_my, fc[1], fc[2], fc[3], fc[4] or 1)

            -- Label
            local label = p.display_name or p.name
            local _, lh = Core_tk.MeasureText(label)
            local tc = is_sel and theme.colors.list_selected_text or theme.colors.text
            Core_tk.DrawText(label,
                             list_x + fav_w, row_y + math.floor((row_h - lh) / 2),
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
        end
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
-- UI: track FX chain pane (right) — custom rendering with selection,
-- DnD reorder (drag header) and DnD drop target for incoming plugins.
-- ---------------------------------------------------------------------------
local function drawChainPane(theme, w, h)
    UI.BeginChild("fxbr_right", w, h, { scrollable = false, border = true,
                                         padding = 6 })

    UI.SetFontH2Bold()
    UI.Text("Track FX Chain")
    UI.SetFontBody()
    UI.Spacing(2)

    local track = Core.state.track
    if not Core.isTrackValid() then
        UI.SetFontCaption()
        UI.Text("No track selected.")
        UI.SetFontBody()
        UI.EndChild()
        return
    end

    local fx_count = r.TrackFX_GetCount(track)

    -- Build visible items (skip Sound Generator helpers from FX Constellation).
    -- Filter on the FULL fx_name (not display) since extractFXName truncates
    -- to 25 chars and would hide the giveaway substring.
    local visible = {}
    for fx_idx = 0, fx_count - 1 do
        local _, fx_name = r.TrackFX_GetFXName(track, fx_idx, "")
        local display = Core.extractFXName(fx_name)
        local raw_low = (fx_name or ""):lower()
        if not (raw_low:find("sound generator") or raw_low:find("jsfx sound")) then
            local enabled = r.TrackFX_GetEnabled(track, fx_idx)
            visible[#visible + 1] = {
                fx_idx  = fx_idx,
                display = display,
                enabled = enabled,
            }
        end
    end

    local Core_tk = UI.Core
    local row_h   = theme.button_height
    local list_h  = math.max(120, h - 56)

    UI.BeginChild("fxbr_chainlist", 0, list_h,
        { scrollable = true, border = false, padding = 2 })

    local list_x, list_y = UI.GetCursorPos()
    local list_w = UI.GetAvailableWidth()
    local btn_w  = math.floor(row_h * 1.4)
    local btns_w = btn_w * 3 + 8
    local has_popup = Core_tk.HasPopup and Core_tk.HasPopup() or false

    -- Pending actions to apply once after the loop (avoid mutating fx during iteration)
    local action      = nil      -- "open" | "bypass" | "delete" | "select"
    local action_fx   = nil
    local reorder_src = nil      -- fx_idx being dragged
    local reorder_dst = nil      -- destination fx_idx (insert before)
    local plugin_drop = nil      -- payload from incoming plugin DnD
    local plugin_dst  = nil      -- destination fx_idx

    if #visible == 0 then
        -- Drop target covering the whole empty area for "add at end".
        local dropped = UI.BeginDropTarget(list_x, list_y, list_w, list_h - 8,
                                           "fx_plugins")
        if dropped then
            plugin_drop = dropped
            plugin_dst = nil  -- append
        end
        UI.SetFontCaption()
        UI.Text("No FX on track.")
        UI.SetFontBody()
    else
        for i, v in ipairs(visible) do
            local row_y    = list_y + (i - 1) * row_h
            local hovered  = (not has_popup)
                             and Core_tk.MouseInRect(list_x, row_y, list_w, row_h)
            local is_sel   = (state.chain_selected == v.fx_idx)
            -- Numbering uses the visible index (1-based), so hidden Sound
            -- Generator slots don't shift the user-visible numbering.
            local label    = i .. ". " .. v.display
                             .. (v.enabled and "" or "  (bypassed)")
            local header_w = list_w - btns_w

            -- Background
            if is_sel then
                local ac = theme.colors.accent
                Core_tk.DrawRect(list_x, row_y, list_w, row_h - 1,
                                 ac[1], ac[2], ac[3], 0.30)
            elseif hovered then
                local hc = theme.colors.header_hovered
                Core_tk.DrawRect(list_x, row_y, list_w, row_h - 1,
                                 hc[1], hc[2], hc[3], 0.25)
            end

            -- Header text
            local _, lh = Core_tk.MeasureText(label)
            local tc = is_sel and theme.colors.list_selected_text or theme.colors.text
            Core_tk.DrawText(label,
                             list_x + 6, row_y + math.floor((row_h - lh) / 2),
                             tc[1], tc[2], tc[3], tc[4] or 1)

            -- Header click area (Alt+Click=delete, plain click=select+drag).
            -- Ctrl is reserved for the drag-modifier (duplicate-on-drop).
            if hovered and Core_tk.MouseClicked(1) then
                local mx = Core_tk.GetMousePos()
                if mx and mx < list_x + header_w then
                    if Core_tk.ModAlt() then
                        action = "delete"
                    else
                        action = "select"
                        Core_tk.SetActive("fxbr_chain_drag_" .. v.fx_idx)
                    end
                    action_fx = v.fx_idx
                end
            end
            UI.BeginDragSource("fxbr_chain_drag_" .. v.fx_idx,
                               v.fx_idx, "fx_chain", "↕ " .. v.display)

            -- Drop target on header (reorder)
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

            -- Action buttons (right-aligned, drawn as plain rects + text so they
            -- don't interfere with the drag-source row click).
            local function actionBtn(label_txt, ax)
                local bx = list_x + list_w - ax
                local btn_hov = (not has_popup)
                                and Core_tk.MouseInRect(bx, row_y + 2,
                                                        btn_w, row_h - 4)
                local bg = btn_hov and theme.colors.button_hovered
                                   or  theme.colors.button
                Core_tk.DrawRect(bx, row_y + 2, btn_w, row_h - 4,
                                 bg[1], bg[2], bg[3], bg[4] or 1)
                local btc = theme.colors.text
                local tw, th = Core_tk.MeasureText(label_txt)
                Core_tk.DrawText(label_txt,
                                 bx + math.floor((btn_w - tw) / 2),
                                 row_y + math.floor((row_h - th) / 2),
                                 btc[1], btc[2], btc[3], btc[4] or 1)
                return btn_hov and Core_tk.MouseClicked(1)
            end

            if actionBtn("○", btns_w) then
                action = "open"; action_fx = v.fx_idx
            end
            if actionBtn(v.enabled and "B" or "b", btns_w - btn_w - 4) then
                action = "bypass"; action_fx = v.fx_idx
            end
            if actionBtn("X", btn_w) then
                action = "delete"; action_fx = v.fx_idx
            end

            -- Double-click on header → open FX UI (suppressed under Alt to
            -- avoid triggering after a chain of Alt+Click deletes).
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
-- UI: footer (auto-open + random insertion)
-- ---------------------------------------------------------------------------
local function drawFooter(theme, plugins)
    UI.Separator()
    UI.Spacing(3)

    UI.BeginColumns("fxbr_foot", { 0.22, 0.30, 0.22, 0.26 }, { gap = 6 })

    local oc, ov = UI.Checkbox("fxbr_autoopen", "Auto-open FX UI",
                               state.auto_open)
    if oc then state.auto_open = ov; persistConfig() end
    UI.NextColumn()

    if UI.Button("fxbr_addsel", "Add selected") then
        local sel = collectSelected(plugins)
        if #sel == 0 and plugins[state.selected_idx] then
            sel = { plugins[state.selected_idx] }
        end
        if #sel > 0 then
            -- If a custom tab is active and Shift is held → add to that tab
            -- instead of the track. Plain click always adds to track.
            local tab_key = state.type_filter
            if UI.Core.ModShift()
               and tab_key and tab_key:sub(1, 2) == "T:" then
                local _, tab = findTab(tab_key:sub(3))
                if tab then
                    local names = {}
                    for _, p in ipairs(sel) do names[#names + 1] = p.name end
                    local added = addNamesToTab(tab, names)
                    flash(("Added %d to %s"):format(added, tab.name))
                end
            else
                r.Undo_BeginBlock()
                for _, p in ipairs(sel) do addPlugin(p) end
                r.Undo_EndBlock("Add selected FX", -1)
            end
        end
    end
    UI.NextColumn()

    local fc, fv = UI.Checkbox("fxbr_rfav", "Favs only",
                               state.rand_fav_only)
    if fc then state.rand_fav_only = fv; persistConfig() end
    UI.NextColumn()

    UI.BeginColumns("fxbr_rand_inner", { 0.20, 0.22, 0.22, 0.18, 0.18 },
                    { gap = 4 })
    local rc, rv = UI.SliderInt("fxbr_rcount", "FX",
                                state.rand_count, 1, 10)
    if rc then state.rand_count = rv; persistConfig() end
    UI.NextColumn()
    if UI.Button("fxbr_radd", "Random (all)") then
        refreshTrack()
        if Core.isTrackValid() then
            local track = Core.state.track
            r.Undo_BeginBlock()
            local removed = 0
            if state.rand_replace then removed = clearChain(track) end
            local before = r.TrackFX_GetCount(track)
            FXManager.addRandomFX(state.rand_count, state.rand_fav_only)
            local after = r.TrackFX_GetCount(track)
            if not state.auto_open then
                for i = before, after - 1 do r.TrackFX_Show(track, i, 2) end
            end
            r.Undo_EndBlock(state.rand_replace
                and "Replace chain with random FX"
                or  "Add random FX", -1)
            local msg = "Added " .. (after - before) .. " random FX"
            if state.rand_replace and removed > 0 then
                msg = msg .. " (replaced " .. removed .. ")"
            end
            flash(msg)
        else
            flash("No track selected")
        end
    end
    UI.NextColumn()
    if UI.Button("fxbr_radd_vis", "Random (visible)") then
        refreshTrack()
        if not Core.isTrackValid() then
            flash("No track selected")
        elseif #plugins == 0 then
            flash("No plugins in current view")
        else
            -- Pick N distinct plugins from the currently filtered list.
            local pool, picks = {}, {}
            for _, p in ipairs(plugins) do pool[#pool + 1] = p end
            local n = math.min(state.rand_count, #pool)
            for _ = 1, n do
                local idx = math.random(1, #pool)
                picks[#picks + 1] = pool[idx]
                table.remove(pool, idx)
            end
            r.Undo_BeginBlock()
            local removed = 0
            if state.rand_replace then removed = clearChain(Core.state.track) end
            for _, p in ipairs(picks) do addPlugin(p) end
            r.Undo_EndBlock(state.rand_replace
                and "Replace chain with random FX (visible)"
                or  "Add random FX (visible)", -1)
            local msg = "Added " .. #picks .. " random FX from view"
            if state.rand_replace and removed > 0 then
                msg = msg .. " (replaced " .. removed .. ")"
            end
            flash(msg)
        end
    end
    UI.NextColumn()
    local rpc, rpv = UI.Checkbox("fxbr_rreplace", "Replace",
                                 state.rand_replace)
    if rpc then state.rand_replace = rpv; persistConfig() end
    UI.NextColumn()
    if UI.Button("fxbr_clear", "Clear chain") then
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
    UI.EndColumns()

    UI.EndColumns()

    -- Status / flash line
    if state.flash_msg ~= "" and r.time_precise() < state.flash_until then
        UI.Spacing(2)
        UI.SetFontCaption()
        UI.TextColored(state.flash_msg,
            theme.colors.accent[1],
            theme.colors.accent[2],
            theme.colors.accent[3], 1)
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

    drawToolbar()
    UI.Spacing(2)
    drawFilterChips()
    UI.Separator()
    drawTrackHeader()
    UI.Spacing(4)

    local body_h    = 360
    local left_ratio = state.split_left

    UI.BeginColumns("fxbr_body", { left_ratio, 1 - left_ratio }, { gap = 8 })
    drawPluginsPane(theme, plugins, 0, body_h)
    UI.NextColumn()
    drawChainPane(theme, 0, body_h)
    UI.EndColumns()

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

    -- Drag preview overlay (drawn on top of everything)
    UI.DrawDragPreview()
end

-- ---------------------------------------------------------------------------
-- Window setup
-- ---------------------------------------------------------------------------
UI.Init("FX Browser", 980, 640, {
    persist    = "CP_FXBrowser",
    scrollable = false,
    padding    = 8,
})

UI.OnClose(function()
    persistConfig()
    Persistence.saveSettings()
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
