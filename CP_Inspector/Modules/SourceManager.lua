-- CP_Inspector SourceManager — Browse/swap media sources, version navigation, rename
-- 1:1 port of CP_SourceManager.lua to CP_Toolkit

local SourceManager = {}
local r = reaper

local SCRIPT_ID = "CP_SourceManager"  -- keep old key for ExtState compat

-- ============================================================================
-- SUPPORTED FORMATS
-- ============================================================================
local SUPPORTED = {
    wav=true, mp3=true, ogg=true, flac=true, aif=true, aiff=true,
    m4a=true, wav64=true, mp4=true, mov=true, avi=true, mkv=true, rpp=true,
}

-- ============================================================================
-- CONFIG (persisted)
-- ============================================================================
SourceManager.config = {
    adjust_item_size = true,
    search_query = "",
}

-- ============================================================================
-- STATE (live)
-- ============================================================================
SourceManager.state = {
    selected_items = {},
    common_directory = "",
    reference_files = {},
    available_media = {},
    filtered_media = {},
    multiple_directories = false,
    status_message = "",
    selected_media = 0,
}

local temp_sources = {}

-- ============================================================================
-- PERSISTENCE
-- ============================================================================
local function SaveSettings()
    for k, v in pairs(SourceManager.config) do
        local s = tostring(v)
        if type(v) == "boolean" then s = v and "1" or "0" end
        r.SetExtState(SCRIPT_ID, "config_" .. k, s, true)
    end
end

local function LoadSettings()
    for k, default in pairs(SourceManager.config) do
        local saved = r.GetExtState(SCRIPT_ID, "config_" .. k)
        if saved ~= "" then
            if type(default) == "number" then
                SourceManager.config[k] = tonumber(saved) or default
            elseif type(default) == "boolean" then
                SourceManager.config[k] = saved == "1"
            else
                SourceManager.config[k] = saved
            end
        end
    end
end

SourceManager.SaveSettings = SaveSettings

-- ============================================================================
-- HELPERS
-- ============================================================================
local function get_filename(path)
    if not path then return "" end
    return path:match("([^/\\]+)$") or path
end

local function SafelyDestroySource(source)
    if source and r.PCM_Source_Destroy then
        r.PCM_Source_Destroy(source)
    end
end

local function CleanupTempSources()
    for _, src in ipairs(temp_sources) do SafelyDestroySource(src) end
    temp_sources = {}
end

local function SanitizeFilename(name)
    local s = name:gsub("[\\/:*?\"<>|]", "_")
    return s:match("^%s*(.-)%s*$")
end

local function CopyFile(src_path, dst_path)
    local src = io.open(src_path, "rb")
    if not src then return false, "Could not open source file" end
    local dst = io.open(dst_path, "wb")
    if not dst then src:close(); return false, "Could not create destination file" end
    dst:write(src:read("*all"))
    src:close(); dst:close()
    return true, ""
end

-- Creates a temp source, reads length. Handles lengthIsQN (tempo-based).
-- Temp sources tracked for cleanup at end of operation.
local function GetSafeSourceLength(filepath)
    if not filepath then return 0, false end
    local temp = r.PCM_Source_CreateFromFile(filepath)
    if not temp then return 0, false end
    temp_sources[#temp_sources + 1] = temp
    local len, is_qn = r.GetMediaSourceLength(temp)
    if is_qn then
        local tempo = r.Master_GetTempo()
        len = len * 60 / tempo
    end
    return len, is_qn
end

-- ============================================================================
-- FILE SEQUENCE DETECTION (ported from old FindNextFile/FindPreviousFile)
-- ============================================================================
local SEQ_PATTERNS = {
    { pattern = "%-(%d+)%.", separator = "-" },
    { pattern = "_(%d+)%.",  separator = "_" },
    { pattern = " (%d+)%.",  separator = " " },
}

local function FindNextFile(current_file)
    local directory = current_file:match("(.+)[/\\]")
    local base_name = current_file:match("^.+[/\\](.+)$")
    if not directory or not base_name then return nil end

    local ext = base_name:match("%.([^%.]+)$")
    if not ext then return nil end
    local name_no_ext = base_name:match("(.+)%.")
    if not name_no_ext then return nil end

    for _, pat in ipairs(SEQ_PATTERNS) do
        local num_str = base_name:match(pat.pattern)
        if num_str then
            local cur = tonumber(num_str)
            local prefix = base_name:match("(.+)" .. pat.separator .. "%d+")
            if prefix and cur then
                local fmt = string.format("%%0%dd", #num_str)
                local next_num = string.format(fmt, cur + 1)
                local next_file = string.format("%s%s%s.%s", prefix, pat.separator, next_num, ext)
                local full = directory .. "/" .. next_file
                if r.file_exists(full) then return full end
            end
            return nil
        end
    end

    -- Fallback: no number in current filename — try common "01" variants
    local candidates = {
        directory .. "/" .. name_no_ext .. "-01." .. ext,
        directory .. "/" .. name_no_ext .. "-1."  .. ext,
        directory .. "/" .. name_no_ext .. "_01." .. ext,
        directory .. "/" .. name_no_ext .. "_1."  .. ext,
        directory .. "/" .. name_no_ext .. " 01." .. ext,
        directory .. "/" .. name_no_ext .. " 1."  .. ext,
    }
    for _, path in ipairs(candidates) do
        if r.file_exists(path) then return path end
    end
    return nil
end

local function FindPreviousFile(current_file)
    local directory = current_file:match("(.+)[/\\]")
    local base_name = current_file:match("^.+[/\\](.+)$")
    if not directory or not base_name then return nil end

    local ext = base_name:match("%.([^%.]+)$")
    if not ext then return nil end

    for _, pat in ipairs(SEQ_PATTERNS) do
        local num_str = base_name:match(pat.pattern)
        if num_str then
            local cur = tonumber(num_str)
            local prefix = base_name:match("(.+)" .. pat.separator .. "%d+")
            if prefix and cur then
                if cur > 1 then
                    local fmt = string.format("%%0%dd", #num_str)
                    local prev_num = string.format(fmt, cur - 1)
                    local prev_file = string.format("%s%s%s.%s", prefix, pat.separator, prev_num, ext)
                    local full = directory .. "/" .. prev_file
                    if r.file_exists(full) then return full end
                elseif cur == 1 then
                    -- _01 / -01 / " 01" → try base filename without sequence
                    local base_file = string.format("%s.%s", prefix, ext)
                    local full = directory .. "/" .. base_file
                    if r.file_exists(full) then return full end
                end
            end
        end
    end
    return nil
end

-- ============================================================================
-- MULTI-ITEM ANALYSIS
-- ============================================================================
local function GetCommonDirectoryAndReferenceFiles()
    local items = SourceManager.state.selected_items
    if #items == 0 then return nil, {}, false end

    local dirs = {}
    local refs = {}
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local src = r.GetMediaItemTake_Source(take)
            if src then
                local fp = r.GetMediaSourceFileName(src)
                refs[#refs + 1] = fp
                local d = fp:match("(.+)[/\\]")
                if d then dirs[d] = (dirs[d] or 0) + 1 end
            end
        end
    end

    local common, best_count = nil, 0
    local dir_count = 0
    for d, c in pairs(dirs) do
        dir_count = dir_count + 1
        if c > best_count then common, best_count = d, c end
    end

    return common, refs, dir_count > 1
end

local function ScanAvailableMedia(directory)
    if not directory then return {} end
    local files = {}
    local i = 0
    while true do
        local fn = r.EnumerateFiles(directory, i)
        if not fn then break end
        local ext = fn:match("%.([^%.]+)$")
        if ext and SUPPORTED[ext:lower()] then
            files[#files + 1] = {
                name = fn,
                path = directory .. "/" .. fn,
                extension = ext:lower(),
            }
        end
        i = i + 1
    end
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    return files
end

local function FilterMedia(list, query)
    if not query or query == "" then return list end
    local q = query:lower()
    local out = {}
    for _, m in ipairs(list) do
        if m.name:lower():find(q, 1, true) then out[#out + 1] = m end
    end
    return out
end

-- ============================================================================
-- SELECTION POLL (detects changes, refreshes directory/media lists)
-- ============================================================================
local function PollSelection()
    local s = SourceManager.state
    local new_items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        new_items[#new_items + 1] = r.GetSelectedMediaItem(0, i)
    end

    local changed = #new_items ~= #s.selected_items
    if not changed then
        for i, it in ipairs(new_items) do
            if it ~= s.selected_items[i] then changed = true; break end
        end
    end

    if changed then
        s.selected_items = new_items
        s.common_directory, s.reference_files, s.multiple_directories = GetCommonDirectoryAndReferenceFiles()
        if s.common_directory and not s.multiple_directories then
            s.available_media = ScanAvailableMedia(s.common_directory)
        else
            s.available_media = {}
        end
        s.filtered_media = FilterMedia(s.available_media, SourceManager.config.search_query)
    end
    return changed
end

-- ============================================================================
-- APPLY: swap source, adjust length (playrate-aware from original code)
-- ============================================================================
-- Applies new source file to a take. Returns true on success.
local function ApplySourceToTake(item, take, new_path, source_length)
    local old_source = r.GetMediaItemTake_Source(take)
    local new_source = r.PCM_Source_CreateFromFile(new_path)
    if not new_source then return false end
    if not r.SetMediaItemTake_Source(take, new_source) then
        SafelyDestroySource(new_source)
        return false
    end
    SafelyDestroySource(old_source)
    if SourceManager.config.adjust_item_size and source_length and source_length > 0 then
        r.SetMediaItemInfo_Value(item, "D_LENGTH", source_length)
    end
    r.UpdateItemInProject(item)
    r.SetMediaItemSelected(item, true)
    return true
end

local function UpdateItemsToPreviousVersion()
    local items = SourceManager.state.selected_items
    if #items == 0 then return 0, 0 end
    local updated, errors = 0, 0
    r.Undo_BeginBlock()
    CleanupTempSources()
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local src = r.GetMediaItemTake_Source(take)
            local cur = r.GetMediaSourceFileName(src)
            local prev = FindPreviousFile(cur)
            if prev then
                local len = SourceManager.config.adjust_item_size and GetSafeSourceLength(prev) or 0
                if ApplySourceToTake(item, take, prev, len) then
                    updated = updated + 1
                else
                    errors = errors + 1
                end
            else
                errors = errors + 1
            end
        end
    end
    if updated > 0 then r.Main_OnCommand(40441, 0) end
    CleanupTempSources()
    r.Undo_EndBlock("Update media sources to previous version", -1)
    return updated, errors
end

local function UpdateItemsToNextVersion()
    local items = SourceManager.state.selected_items
    if #items == 0 then return 0, 0 end
    local updated, errors = 0, 0
    r.Undo_BeginBlock()
    CleanupTempSources()
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local src = r.GetMediaItemTake_Source(take)
            local cur = r.GetMediaSourceFileName(src)
            local next_f = FindNextFile(cur)
            if next_f then
                local len = SourceManager.config.adjust_item_size and GetSafeSourceLength(next_f) or 0
                if ApplySourceToTake(item, take, next_f, len) then
                    updated = updated + 1
                else
                    errors = errors + 1
                end
            else
                errors = errors + 1
            end
        end
    end
    if updated > 0 then r.Main_OnCommand(40441, 0) end
    CleanupTempSources()
    r.Undo_EndBlock("Update media sources to next version", -1)
    return updated, errors
end

local function UpdateToMediaFile(media_path)
    local items = SourceManager.state.selected_items
    if not media_path or #items == 0 then return 0, 0 end
    local updated, errors = 0, 0
    r.Undo_BeginBlock()
    CleanupTempSources()
    local len = SourceManager.config.adjust_item_size and GetSafeSourceLength(media_path) or 0
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            if ApplySourceToTake(item, take, media_path, len) then
                updated = updated + 1
            else
                errors = errors + 1
            end
        end
    end
    if updated > 0 then r.Main_OnCommand(40441, 0) end
    CleanupTempSources()
    r.Undo_EndBlock("Update media sources to " .. get_filename(media_path), -1)
    return updated, errors
end

local function RenameSourceFiles()
    local items = SourceManager.state.selected_items
    if #items == 0 then return 0, 0 end
    local updated, errors = 0, 0
    r.Undo_BeginBlock()
    CleanupTempSources()
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local src = r.GetMediaItemTake_Source(take)
            local cur = r.GetMediaSourceFileName(src)
            local directory = cur:match("(.+)[/\\]")
            local ext = cur:match("%.([^%.]+)$")
            if directory and ext then
                local take_name = r.GetTakeName(take)
                local sanitized = SanitizeFilename(take_name)
                local new_fn = sanitized .. "." .. ext
                local new_path = directory .. "/" .. new_fn
                if r.file_exists(new_path) then
                    -- Disambiguate with suffix _1, _2, …
                    local counter = 1
                    repeat
                        new_fn = sanitized .. "_" .. counter .. "." .. ext
                        new_path = directory .. "/" .. new_fn
                        counter = counter + 1
                    until not r.file_exists(new_path)
                end
                local ok = CopyFile(cur, new_path)
                if ok then
                    local len = SourceManager.config.adjust_item_size and GetSafeSourceLength(new_path) or 0
                    if ApplySourceToTake(item, take, new_path, len) then
                        updated = updated + 1
                    else
                        errors = errors + 1
                    end
                else
                    errors = errors + 1
                end
            else
                errors = errors + 1
            end
        end
    end
    if updated > 0 then
        r.Main_OnCommand(40441, 0)
        -- Refresh analysis after rename
        local s = SourceManager.state
        s.common_directory, s.reference_files, s.multiple_directories = GetCommonDirectoryAndReferenceFiles()
        if s.common_directory and not s.multiple_directories then
            s.available_media = ScanAvailableMedia(s.common_directory)
            s.filtered_media = FilterMedia(s.available_media, SourceManager.config.search_query)
        end
    end
    CleanupTempSources()
    r.Undo_EndBlock("Rename media sources to take names", -1)
    return updated, errors
end

-- ============================================================================
-- INIT
-- ============================================================================
function SourceManager.Init()
    LoadSettings()
    PollSelection()
end

-- Legacy API (kept for compat with existing CP_Inspector_SourceManager.lua launcher)
function SourceManager.ScanDirectory()
    PollSelection()
end

-- ============================================================================
-- DRAW (1:1 layout from old ReaImGui version)
-- ============================================================================
function SourceManager.Draw(UI, theme)
    local s = SourceManager.state
    local cfg = SourceManager.config

    -- Selection poll every frame (cheap when unchanged)
    local sel_changed = PollSelection()

    -- ---- Header info ----
    UI.Text(string.format("Selected items: %d", #s.selected_items))
    if s.multiple_directories then
        UI.Text("Directory: <multiple directories>", { disabled = true, truncate = true })
    elseif s.common_directory and s.common_directory ~= "" then
        UI.Text("Directory: " .. s.common_directory, { disabled = true, truncate = true })
    else
        UI.Text("No directory found", { disabled = true })
    end

    -- ---- Selected media sources list ----
    if #s.selected_items > 0 then
        UI.Spacing(2)
        UI.Separator()
        UI.Spacing(2)
        UI.Text("Selected media sources:", { disabled = true })
        UI.Spacing(2)

        local list_items = {}
        for i, item in ipairs(s.selected_items) do
            local take = r.GetActiveTake(item)
            if take then
                local src = r.GetMediaItemTake_Source(take)
                local fp = r.GetMediaSourceFileName(src)
                local take_name = r.GetTakeName(take)
                list_items[#list_items + 1] = {
                    label = string.format("%d: %s  (%s)", i, take_name, get_filename(fp)),
                }
            end
        end
        local max_rows = math.min(5, #list_items)
        if max_rows > 0 then
            UI.ActionList("sm_items", list_items, nil, { max_visible = max_rows })
        end
    end

    UI.Spacing(2)
    UI.Separator()
    UI.Spacing(4)

    -- ---- Action buttons row (3-wide) ----
    local avail_w = UI.Layout.GetAvailableWidth()
    local btn_w = math.floor((avail_w - 2 * theme.item_spacing) / 3)
    local has_selection = #s.selected_items > 0

    if UI.Button("sm_prev_ver", "Previous Version", { width = btn_w, disabled = not has_selection }) then
        if has_selection then
            local u, e = UpdateItemsToPreviousVersion()
            s.status_message = string.format("Updated %d items to previous version, %d errors", u, e)
        end
    end
    UI.SameLine()
    if UI.Button("sm_next_ver", "Next Version", { width = btn_w, disabled = not has_selection }) then
        if has_selection then
            local u, e = UpdateItemsToNextVersion()
            s.status_message = string.format("Updated %d items to next version, %d errors", u, e)
        end
    end
    UI.SameLine()
    if UI.Button("sm_rename", "Rename Source(s)", { width = btn_w, disabled = not has_selection }) then
        if has_selection then
            local u, e = RenameSourceFiles()
            s.status_message = string.format("Renamed %d source files based on item names, %d errors", u, e)
        end
    end

    UI.Spacing(2)
    UI.Separator()
    UI.Spacing(2)

    -- ---- Adjust item size checkbox ----
    local cb_changed, cb_val = UI.Checkbox("sm_adjust", "Adjust item size to match source", cfg.adjust_item_size)
    if cb_changed then cfg.adjust_item_size = cb_val end

    UI.Spacing(2)
    UI.Separator()
    UI.Spacing(2)

    -- ---- Search ----
    UI.Text("Search media files:", { disabled = true })
    UI.Spacing(2)
    local sc, sv = UI.InputText("sm_search", "", cfg.search_query, { hint = "Filter...", width = avail_w })
    if sc then
        cfg.search_query = sv
        s.filtered_media = FilterMedia(s.available_media, sv)
    elseif sel_changed then
        s.filtered_media = FilterMedia(s.available_media, cfg.search_query)
    end

    UI.Spacing(4)
    UI.Text("Available media in directory:", { disabled = true })
    UI.Spacing(2)

    -- ---- Available media list ----
    -- Reserve space for the status line below (always, so layout is stable
    -- and the message is visible regardless of list size / window resize).
    local STATUS_RESERVE = 28
    local avail_h = (UI.Layout.GetAvailableHeight and UI.Layout.GetAvailableHeight() or 300) - STATUS_RESERVE
    local item_h = theme.combo_height

    if s.multiple_directories then
        UI.Text("Items from multiple directories selected", { disabled = true })
    elseif #s.available_media > 0 then
        local display = (cfg.search_query ~= "") and s.filtered_media or s.available_media

        -- Build highlight set (current reference files)
        local ref_set = {}
        for _, rf in ipairs(s.reference_files) do ref_set[rf] = true end

        local accent = theme.colors.accent
        local items = {}
        for i, m in ipairs(display) do
            items[i] = {
                label = m.name,
                color = ref_set[m.path] and accent or nil,
                _path = m.path,
            }
        end

        local max_rows = math.max(2, math.floor(avail_h / item_h))

        local clicked, _, activated = UI.ActionList("sm_media", items, nil,
            { max_visible = max_rows, selected = s.selected_media })
        if clicked then s.selected_media = clicked end

        local trigger = activated or clicked  -- single-click swaps, matches old behavior
        if trigger then
            local u, e = UpdateToMediaFile(items[trigger]._path)
            s.status_message = string.format("Updated %d items to %s, %d errors", u, items[trigger].label, e)
            -- Refresh refs after change
            s.common_directory, s.reference_files, s.multiple_directories = GetCommonDirectoryAndReferenceFiles()
        end
    else
        UI.Text("No media files found", { disabled = true })
    end

    -- ---- Status message (always render; blank when empty to keep layout stable) ----
    UI.Spacing(4)
    if s.status_message ~= "" then
        UI.Text(s.status_message, { disabled = true, truncate = true })
    end
end

return SourceManager
