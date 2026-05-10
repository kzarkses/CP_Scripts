-- ============================================================================
-- FXManagerUI — Add FX dialog (CP_Toolkit port)
--
-- Replaces the old ReaImGui-based FX browser with a CP_Toolkit modal-style
-- panel. The window opens when state.show_fxmanager_window is true.
--
-- The full ReaImGui version supported drag&drop reordering directly in the
-- track FX chain. The toolkit port keeps the core flow (search → filter by
-- category → add) and exposes selection + reorder via simple buttons.
-- ============================================================================

local FXManagerUI = {}

function FXManagerUI.init(reaper_api, core, fxmanager, fxdatabase, toolkit)
    FXManagerUI.r           = reaper_api
    FXManagerUI.core        = core
    FXManagerUI.fxmanager   = fxmanager
    FXManagerUI.fxdatabase  = fxdatabase
    FXManagerUI.tk          = toolkit
    FXManagerUI._sort_mode  = "az"  -- "az" | "za" | "none"
end

local function selectedPlugins(plugins)
    local sel = {}
    for _, p in ipairs(plugins) do
        if FXManagerUI.core.state.fxdb_selected_plugins[p.name] then
            sel[#sel + 1] = p
        end
    end
    return sel
end

local function addPlugins(plugins, auto_open, auto_close)
    for _, p in ipairs(plugins) do
        local fx_name = FXManagerUI.fxmanager.buildFXName(p)
        FXManagerUI.fxmanager.addFXByName(fx_name, auto_open, true)
    end
    if auto_close then
        FXManagerUI.core.state.show_fxmanager_window = false
    end
end

-- ---------------------------------------------------------------------------
-- DRAW (called every frame from UI.frame after the main layout)
-- ---------------------------------------------------------------------------
function FXManagerUI.draw(theme)
    local s = FXManagerUI.core.state
    if not s.show_fxmanager_window then return end

    local UItk = FXManagerUI.tk

    UItk.BeginModal("fxmgr_modal", "FX Browser",
                    { width = 760, height = 520 })

    -- Top toolbar: search + scan + sort
    UItk.BeginColumns("fxmgr_toolbar", { 0.55, 0.15, 0.15, 0.15 }, { gap = 6 })

    local sc, sv = UItk.InputText("fxmgr_search", "", s.fxdb_search_query or "",
                                  { hint = "Search FX…" })
    if sc then s.fxdb_search_query = sv end
    UItk.NextColumn()

    if UItk.Button("fxmgr_scan", "Scan") then
        local n = FXManagerUI.fxdatabase.scanPlugins()
        s.fxdb_scan_message = "Scanned " .. n .. " plugins"
        s.fxdb_scan_time = FXManagerUI.r.time_precise()
    end
    UItk.NextColumn()

    local sort_lbl = (FXManagerUI._sort_mode == "az") and "Z-A" or "A-Z"
    if UItk.Button("fxmgr_sort", sort_lbl) then
        FXManagerUI._sort_mode = (FXManagerUI._sort_mode == "az") and "za" or "az"
    end
    UItk.NextColumn()

    if UItk.Button("fxmgr_close", "Close") then
        s.show_fxmanager_window = false
    end
    UItk.EndColumns()

    -- Status line
    if s.fxdb_scan_message and s.fxdb_scan_time
       and (FXManagerUI.r.time_precise() - s.fxdb_scan_time) < 3.0 then
        UItk.SetFontCaption()
        UItk.TextColored(s.fxdb_scan_message,
            theme.colors.text_disabled[1],
            theme.colors.text_disabled[2],
            theme.colors.text_disabled[3], 1)
        UItk.SetFontBody()
    end

    UItk.Separator()

    -- Three-column body: categories | plugins list | track FX chain
    UItk.BeginColumns("fxmgr_body", { 0.20, 0.55, 0.25 }, { gap = 6 })

    -- ── Categories ─────────────────────────────────────────────────────────
    UItk.BeginChild("fxmgr_cats", 0, 320, { scrollable = true, border = true })
    UItk.SetFontH2Bold()
    UItk.Text("Categories")
    UItk.SetFontBody()
    UItk.Spacing(2)
    local cats = FXManagerUI.fxdatabase.getCategories()
    local sel_cat = s.fxdb_selected_category or "All"
    for _, cat in ipairs(cats) do
        local is_sel = sel_cat == cat.name
        local label = (is_sel and "● " or "  ") .. cat.name
        if UItk.Button("cat_" .. cat.name, label) then
            s.fxdb_selected_category = cat.name
        end
    end
    UItk.EndChild()
    UItk.NextColumn()

    -- ── Plugins list ───────────────────────────────────────────────────────
    UItk.BeginChild("fxmgr_plugins", 0, 320, { scrollable = true, border = true })
    UItk.SetFontH2Bold()
    UItk.Text("Plugins")
    UItk.SetFontBody()
    UItk.Spacing(2)

    local plugins = FXManagerUI.fxdatabase.searchPlugins(
        s.fxdb_search_query or "",
        sel_cat
    )

    local function name_lower(p) return (p.display_name or p.name):lower() end
    if FXManagerUI._sort_mode == "az" then
        table.sort(plugins, function(a, b) return name_lower(a) < name_lower(b) end)
    elseif FXManagerUI._sort_mode == "za" then
        table.sort(plugins, function(a, b) return name_lower(a) > name_lower(b) end)
    end

    s.fxdb_selected_plugins = s.fxdb_selected_plugins or {}

    for i, plugin in ipairs(plugins) do
        local is_sel = s.fxdb_selected_plugins[plugin.name] == true
        local fav    = FXManagerUI.fxdatabase.isFavorite(plugin.name)
        local label  = (is_sel and "▣ " or "  ")
                       .. (fav and "★ " or "☆ ")
                       .. (plugin.display_name or plugin.name)

        UItk.BeginColumns("plg_row_" .. i, { 0.10, 0.90 }, { gap = 2 })
        if UItk.Button("fav_" .. i, fav and "★" or "☆", { width = 0 }) then
            FXManagerUI.fxdatabase.toggleFavorite(plugin.name)
        end
        UItk.NextColumn()
        if UItk.Button("plg_" .. i, label) then
            -- Single-click: select. Could be Ctrl/Shift extended later.
            local ctrl = FXManagerUI.tk.Core.ModCtrl
                         and FXManagerUI.tk.Core.ModCtrl() or false
            if not ctrl then
                s.fxdb_selected_plugins = {}
            end
            s.fxdb_selected_plugins[plugin.name] = not is_sel or true
            s.fxdb_last_clicked_plugin = plugin.name
        end
        UItk.EndColumns()
    end

    UItk.EndChild()
    UItk.NextColumn()

    -- ── Track FX chain ─────────────────────────────────────────────────────
    UItk.BeginChild("fxmgr_chain", 0, 320, { scrollable = true, border = true })
    UItk.SetFontH2Bold()
    UItk.Text("Track FX Chain")
    UItk.SetFontBody()
    UItk.Spacing(2)

    if not FXManagerUI.core.isTrackValid() then
        UItk.SetFontCaption()
        UItk.Text("No track selected.")
        UItk.SetFontBody()
    else
        local track = s.track
        local fx_count = FXManagerUI.r.TrackFX_GetCount(track)
        if fx_count == 0 then
            UItk.SetFontCaption()
            UItk.Text("No FX on track.")
            UItk.SetFontBody()
        else
            for fx_idx = 0, fx_count - 1 do
                local _, fx_name = FXManagerUI.r.TrackFX_GetFXName(track, fx_idx, "")
                local display = FXManagerUI.core.extractFXName(fx_name)
                local raw_low = (fx_name or ""):lower()
                if not (raw_low:find("sound generator") or raw_low:find("jsfx sound")) then
                    local enabled = FXManagerUI.r.TrackFX_GetEnabled(track, fx_idx)
                    local label = (fx_idx + 1) .. ". " .. display
                                  .. (enabled and "" or " (bypassed)")
                    UItk.BeginColumns("chain_" .. fx_idx,
                                      { 0.7, 0.15, 0.15 }, { gap = 2 })
                    if UItk.Button("ch_open_" .. fx_idx, label) then
                        FXManagerUI.r.TrackFX_Show(track, fx_idx, 3)
                    end
                    UItk.NextColumn()
                    if UItk.Button("ch_byp_" .. fx_idx, enabled and "ON" or "off") then
                        FXManagerUI.r.TrackFX_SetEnabled(track, fx_idx, not enabled)
                    end
                    UItk.NextColumn()
                    if UItk.Button("ch_del_" .. fx_idx, "X") then
                        FXManagerUI.r.TrackFX_Delete(track, fx_idx)
                    end
                    UItk.EndColumns()
                end
            end
        end
    end

    UItk.EndChild()
    UItk.EndColumns()

    -- ── Footer: actions + random insertion ─────────────────────────────────
    UItk.Separator()
    UItk.Spacing(4)

    local sel = selectedPlugins(plugins)
    UItk.SetFontCaption()
    UItk.Text(string.format("%d plugin%s · %d selected",
        #plugins, #plugins == 1 and "" or "s", #sel))
    UItk.SetFontBody()

    UItk.BeginColumns("fxmgr_footer", { 0.25, 0.25, 0.25, 0.25 }, { gap = 6 })

    -- Auto open / auto close toggles
    local oc, ov = UItk.Checkbox("fxmgr_autoopen", "Auto-open",
                                 s.fxmanager_auto_open or false)
    if oc then s.fxmanager_auto_open = ov end
    UItk.NextColumn()
    local cc, cv = UItk.Checkbox("fxmgr_autoclose", "Close after add",
                                 s.fxmanager_auto_close or false)
    if cc then s.fxmanager_auto_close = cv end
    UItk.NextColumn()
    if UItk.Button("fxmgr_cancel", "Cancel") then
        s.show_fxmanager_window = false
    end
    UItk.NextColumn()
    if UItk.Button("fxmgr_add", "Add to Track") then
        local to_add = sel
        if #to_add == 0 and s.fxdb_last_clicked_plugin then
            for _, p in ipairs(plugins) do
                if p.name == s.fxdb_last_clicked_plugin then
                    to_add = { p }
                    break
                end
            end
        end
        if #to_add > 0 then
            addPlugins(to_add, s.fxmanager_auto_open, s.fxmanager_auto_close)
        end
    end
    UItk.EndColumns()

    -- Random FX insertion
    UItk.Spacing(4)
    UItk.Separator()
    UItk.SetFontH2Bold()
    UItk.Text("Random FX Insertion")
    UItk.SetFontBody()

    s.random_fx_count = s.random_fx_count or 3
    if s.random_fx_favorites_only == nil then
        s.random_fx_favorites_only = false
    end

    UItk.BeginColumns("fxmgr_rand", { 0.45, 0.30, 0.25 }, { gap = 6 })
    local rc, rv = UItk.SliderInt("fxmgr_rcount", "FX",
                                  s.random_fx_count, 1, 10)
    if rc then s.random_fx_count = rv; FXManagerUI.fxmanager.persistence.scheduleSave() end
    UItk.NextColumn()
    local fc, fv = UItk.Checkbox("fxmgr_rfav", "Favorites only",
                                 s.random_fx_favorites_only)
    if fc then s.random_fx_favorites_only = fv; FXManagerUI.fxmanager.persistence.scheduleSave() end
    UItk.NextColumn()
    if UItk.Button("fxmgr_radd", "Add Random") then
        local ok = FXManagerUI.fxmanager.addRandomFX(
            s.random_fx_count, s.random_fx_favorites_only)
        if ok and s.fxmanager_auto_close then
            s.show_fxmanager_window = false
        end
    end
    UItk.EndColumns()

    UItk.EndModal()
end

-- Backwards-compat alias for the old name used in CP_FXConstellation.lua
FXManagerUI.drawWindow = FXManagerUI.draw

return FXManagerUI
