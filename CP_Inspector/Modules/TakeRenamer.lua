-- CP_Inspector TakeRenamer — Batch-rename takes (port of MPT TakeRenamer)
-- Single mode: replace base name across selection
-- Batch mode:  preserve each take's base name, only apply prefix/suffix/numbering
-- Wildcards:   $track $project $parent $region $marker $folders
-- Wwise prefix [XYZ] is preserved automatically

local TakeRenamer = {}
local r = reaper

local SCRIPT_ID = "CP_Inspector_TakeRenamer"

-- ============================================================================
-- WILDCARDS
-- ============================================================================
local wildcards = {
    ["$track"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local track = r.GetMediaItemTrack(item)
        if not track then return "" end
        local _, name = r.GetTrackName(track)
        return name or ""
    end,

    ["$project"] = function()
        local _, path = r.EnumProjects(-1)
        if path then
            return path:match("([^/\\]+)%.RPP$")
                or path:match("([^/\\]+)%.rpp$")
                or "Untitled"
        end
        return "Untitled"
    end,

    ["$parent"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local track = r.GetMediaItemTrack(item)
        if not track then return "" end
        local parent = r.GetParentTrack(track)
        if parent then
            local _, name = r.GetTrackName(parent)
            return name or ""
        end
        return ""
    end,

    ["$region"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local _, num_markers, num_regions = r.CountProjectMarkers(0)
        for i = 0, num_markers + num_regions - 1 do
            local _, isrgn, start, ending, name = r.EnumProjectMarkers2(0, i)
            if isrgn and pos >= start and pos < ending then
                return name or ""
            end
        end
        return ""
    end,

    ["$marker"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local _, num_markers, num_regions = r.CountProjectMarkers(0)
        local closest_name, closest_dist = "", math.huge
        for i = 0, num_markers + num_regions - 1 do
            local _, isrgn, start, _, name = r.EnumProjectMarkers2(0, i)
            if not isrgn then
                local dist = math.abs(start - pos)
                if dist < closest_dist then
                    closest_dist = dist
                    closest_name = name or ""
                end
            end
        end
        return closest_name
    end,

    ["$folders"] = function(item)
        if not item or not r.ValidatePtr(item, "MediaItem*") then return "" end
        local track = r.GetMediaItemTrack(item)
        if not track then return "" end
        local folders = {}
        while track do
            local _, tname = r.GetTrackName(track)
            if tname then
                tname = tname:gsub("%[%w+%]%s*", "")
                table.insert(folders, 1, tname)
            end
            track = r.GetParentTrack(track)
        end
        return table.concat(folders, "_")
    end,
}

local WILDCARD_KEYS = { "$track", "$parent", "$region", "$marker", "$project", "$folders" }

-- ============================================================================
-- STATE
-- ============================================================================
TakeRenamer.state = {
    -- Editable fields
    base_name      = "",
    prefix         = "",
    suffix         = "",
    number_format  = "%02d",        -- " %d", "%02d", "%03d", "(%d)", ".%d"
    spacer_type    = "none",        -- "none", "underscore", "hyphen"

    -- Toggles
    use_prefix     = true,
    use_suffix     = true,
    use_numbering  = true,
    batch_mode     = false,
    auto_close     = false,

    -- Runtime
    selected_items     = {},
    wwise_prefix       = "",
    last_selection_count = 0,
    last_first_item    = nil,
    need_focus         = false,
}

local NUMBER_FORMATS = {
    { label = "1",   value = " %d"  },
    { label = "01",  value = "%02d" },
    { label = "001", value = "%03d" },
    { label = "(1)", value = "(%d)" },
    { label = ".1",  value = ".%d"  },
}

local SPACER_TYPES = {
    { label = "None",       value = "none"       },
    { label = "_", value = "underscore" },
    { label = "-",     value = "hyphen"     },
}

-- ============================================================================
-- SETTINGS PERSISTENCE
--   File-based via CP_Config (one Lua file per script). The toolkit reference
--   is injected via SetToolkit so this module doesn't have to dofile() the
--   toolkit itself (avoids dependency cycles).
-- ============================================================================
local TK = nil
function TakeRenamer.SetToolkit(toolkit) TK = toolkit end

function TakeRenamer.LoadSettings()
    if not TK then return end
    local data = TK.LoadConfig(SCRIPT_ID)
    if not data then return end
    local s = TakeRenamer.state
    for k, v in pairs(data) do
        if s[k] ~= nil and type(s[k]) ~= "table" and type(s[k]) ~= "function" then
            s[k] = v
        end
    end
end

function TakeRenamer.SaveSettings()
    if not TK then return end
    local s = TakeRenamer.state
    TK.SaveConfig(SCRIPT_ID, {
        prefix        = s.prefix,
        suffix        = s.suffix,
        number_format = s.number_format,
        spacer_type   = s.spacer_type,
        use_prefix    = s.use_prefix,
        use_suffix    = s.use_suffix,
        use_numbering = s.use_numbering,
        batch_mode    = s.batch_mode,
        auto_close    = s.auto_close,
    })
end

-- ============================================================================
-- BASE-NAME EXTRACTION
--   Strips: file extensions, Wwise prefix [XYZ], current prefix/suffix,
--           trailing numbers (5 patterns), trim leading/trailing punctuation.
--   Returns: base_name, wwise_prefix
-- ============================================================================
local function escape_pattern(str)
    return (str:gsub("([%-%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

function TakeRenamer.ExtractBaseName(full_name)
    if not full_name or full_name == "" then return "", "" end
    local s = TakeRenamer.state
    local name = full_name

    -- Strip common audio extensions
    name = name:gsub("%.wav$", "")
                :gsub("%.flac$", "")
                :gsub("%.mp3$", "")
                :gsub("%.aif+$", "")
                :gsub("%s+", " ")

    -- Extract Wwise prefix (e.g. "[Voice]")
    local wwise = name:match("^(%[%w+%])")
    if wwise then
        name = name:sub(#wwise + 1):match("^%s*(.-)%s*$") or ""
    end

    -- Strip current prefix
    if s.use_prefix and s.prefix ~= "" then
        name = (name:gsub("^" .. escape_pattern(s.prefix), ""))
        name = name:match("^%s*(.-)%s*$") or ""
    end

    -- Strip current suffix
    if s.use_suffix and s.suffix ~= "" then
        name = (name:gsub(escape_pattern(s.suffix) .. "$", ""))
        name = name:match("^%s*(.-)%s*$") or ""
    end

    -- Strip trailing number suffixes (5 common patterns)
    local number_patterns = {
        "%s+%d+%s*$",
        "_%d+%s*$",
        "%.%d+%s*$",
        "%-%d+%s*$",
        "%(%d+%)%s*$",
    }
    for _, pat in ipairs(number_patterns) do
        local stripped = name:gsub(pat, "")
        if stripped ~= name then
            name = stripped
            break
        end
    end

    name = (name:match("^%s*(.-)%s*$") or "")
        :gsub("^[_%-,]+", "")
        :gsub("[_%-,]+$", "")

    return name, wwise or ""
end

-- ============================================================================
-- WILDCARD RESOLUTION + SPACE REPLACEMENT
-- ============================================================================
function TakeRenamer.ProcessWildcards(name, item)
    if not item or not r.ValidatePtr(item, "MediaItem*") then return name end
    local s = TakeRenamer.state
    local result = name

    -- Strip any existing Wwise-style brackets so wildcards don't double them
    result = result:gsub("%[%w+%]%s*", "")

    for token, fn in pairs(wildcards) do
        local replacement = fn(item) or ""
        local esc = escape_pattern(token)
        result = result:gsub(esc, replacement)
    end

    -- Space replacement (matches MPT spacer_type)
    if s.spacer_type == "underscore" then
        result = result:gsub("%s+", "_"):gsub("_+", "_")
        result = (result:gsub("^_+", ""):gsub("_+$", ""))
    elseif s.spacer_type == "hyphen" then
        result = result:gsub("%s+", "-"):gsub("%-+", "-")
        result = (result:gsub("^%-+", ""):gsub("%-+$", ""))
    end

    return result
end

-- ============================================================================
-- BUILD FINAL NAME
-- ============================================================================
function TakeRenamer.BuildFinalName(base, index, wwise_prefix, force_no_number)
    local s = TakeRenamer.state
    local name = base or ""

    if s.use_prefix and s.prefix ~= "" then
        name = s.prefix .. name
    end

    if s.use_suffix and s.suffix ~= "" then
        name = name .. s.suffix
    end

    if s.use_numbering and not force_no_number and index then
        local fmt = s.number_format
        if fmt and fmt ~= "" then
            local num
            if fmt == "%02d" then
                num = string.format("_%02d", index)
            elseif fmt == "%03d" then
                num = string.format("_%03d", index)
            elseif fmt == " %d" then
                num = string.format(" %d", index)
            elseif fmt == ".%d" then
                num = string.format(".%d", index)
            elseif fmt == "(%d)" then
                num = string.format("(%d)", index)
            else
                num = ""
            end
            name = name .. num
        end
    end

    if wwise_prefix and wwise_prefix ~= "" then
        name = wwise_prefix .. name
    end

    return name
end

-- ============================================================================
-- GROUPING (batch mode)
-- ============================================================================
function TakeRenamer.GroupTakesByBaseName(items)
    local groups = {}
    local order = {}
    for _, item in ipairs(items) do
        if r.ValidatePtr(item, "MediaItem*") then
            local take = r.GetActiveTake(item)
            if take and r.ValidatePtr(take, "MediaItemTake*") then
                local current = ({ r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false) })[2] or ""
                local base, ww = TakeRenamer.ExtractBaseName(current)
                if not groups[base] then
                    groups[base] = { items = {}, wwise_prefix = ww }
                    table.insert(order, base)
                end
                table.insert(groups[base].items, item)
            end
        end
    end
    return groups, order
end

-- ============================================================================
-- APPLY RENAMING
--   UI_ref (optional): pass the toolkit UI module so we can RequestClose
--   synchronously when auto_close is on (saves 1+ frames of latency).
-- ============================================================================
function TakeRenamer.Apply(UI_ref)
    local s = TakeRenamer.state
    local items = s.selected_items
    if #items == 0 then return end

    r.Undo_BeginBlock()

    if s.batch_mode then
        local groups, order = TakeRenamer.GroupTakesByBaseName(items)
        for _, base in ipairs(order) do
            local group = groups[base]
            local group_size = #group.items
            for i, item in ipairs(group.items) do
                if r.ValidatePtr(item, "MediaItem*") then
                    local take = r.GetActiveTake(item)
                    if take and r.ValidatePtr(take, "MediaItemTake*") then
                        local current = ({ r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false) })[2] or ""
                        local preserved = TakeRenamer.ExtractBaseName(current)
                        local force_no_num = not (group_size > 1 and s.use_numbering and s.number_format ~= "")
                        local name = TakeRenamer.BuildFinalName(preserved, i, group.wwise_prefix, force_no_num)
                        name = TakeRenamer.ProcessWildcards(name, item)
                        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
                    end
                end
            end
        end
    else
        local count = #items
        for i, item in ipairs(items) do
            if r.ValidatePtr(item, "MediaItem*") then
                local take = r.GetActiveTake(item)
                if take and r.ValidatePtr(take, "MediaItemTake*") then
                    local force_no_num = not (count > 1 and s.use_numbering and s.number_format ~= "")
                    local name = TakeRenamer.BuildFinalName(s.base_name, i, s.wwise_prefix, force_no_num)
                    name = TakeRenamer.ProcessWildcards(name, item)
                    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
                end
            end
        end
    end

    r.Undo_EndBlock("CP Inspector: Batch rename takes", -1)
    r.UpdateArrange()
    -- NOTE: SaveSettings is intentionally NOT called here. Multiple
    -- SetExtState(persist=true) calls hit the disk and add ~100-300ms
    -- to the perceived Apply latency. Settings are saved on close instead.

    if s.auto_close and UI_ref and UI_ref.Core then
        -- Synchronous close: same frame's post-loop check sees the flag
        UI_ref.Core.RequestClose()
    end
end

-- ============================================================================
-- LIVE SELECTION POLLING
-- ============================================================================
function TakeRenamer.RefreshSelection()
    local s = TakeRenamer.state
    local count = r.CountSelectedMediaItems(0)
    local first = count > 0 and r.GetSelectedMediaItem(0, 0) or nil

    if count == s.last_selection_count and first == s.last_first_item then
        return false
    end

    s.last_selection_count = count
    s.last_first_item = first
    s.selected_items = {}

    for i = 0, count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        if r.ValidatePtr(item, "MediaItem*") then
            s.selected_items[#s.selected_items + 1] = item
        end
    end

    -- In single mode, prefill base_name from the first selected take
    if not s.batch_mode and first then
        local take = r.GetActiveTake(first)
        if take and r.ValidatePtr(take, "MediaItemTake*") then
            local current = ({ r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false) })[2] or ""
            local base, ww = TakeRenamer.ExtractBaseName(current)
            s.base_name = base
            s.wwise_prefix = ww
            s.need_focus = true
        end
    end

    return true
end

-- ============================================================================
-- PREVIEW (returns up to 3 example names)
-- ============================================================================
function TakeRenamer.Preview()
    local s = TakeRenamer.state
    local items = s.selected_items
    if #items == 0 then return { "(no items selected)" } end

    local lines = {}

    if s.batch_mode then
        local groups, order = TakeRenamer.GroupTakesByBaseName(items)
        for i, base in ipairs(order) do
            local group = groups[base]
            local size = #group.items
            local force_no_num = not (size > 1 and s.use_numbering and s.number_format ~= "")
            local example = TakeRenamer.BuildFinalName(base, 1, group.wwise_prefix, force_no_num)
            example = TakeRenamer.ProcessWildcards(example, group.items[1])
            if size > 1 then
                lines[#lines + 1] = example .. "  (" .. size .. " items)"
            else
                lines[#lines + 1] = example
            end
            if i >= 3 then
                lines[#lines + 1] = "..."
                break
            end
        end
    else
        local count = #items
        local force_no_num = not (count > 1 and s.use_numbering and s.number_format ~= "")
        local ex1 = TakeRenamer.BuildFinalName(s.base_name, 1, s.wwise_prefix, force_no_num)
        ex1 = TakeRenamer.ProcessWildcards(ex1, items[1])
        lines[#lines + 1] = ex1

        if count > 1 then
            local ex2 = TakeRenamer.BuildFinalName(s.base_name, 2, s.wwise_prefix, force_no_num)
            ex2 = TakeRenamer.ProcessWildcards(ex2, items[2] or items[1])
            lines[#lines + 1] = ex2
            if count > 2 then lines[#lines + 1] = "..." end
        end
    end

    return lines
end

-- ============================================================================
-- UI
-- ============================================================================
local BASE_INPUT_ID = "rn_base_name"

function TakeRenamer.Draw(UI, theme)
    local s = TakeRenamer.state

    -- Live selection sync (cheap; runs each frame, only refetches on change)
    TakeRenamer.RefreshSelection()

    -- ---- Mode toggle (sits directly on the window bg, no panel) ----
    local bch, bnew = UI.Checkbox("rn_batch", "Batch mode  (preserve each take's base name)", s.batch_mode)
    if bch then
        s.batch_mode = bnew
        if not s.batch_mode then s.need_focus = true end
    end
    UI.Spacing(theme.item_spacing)

    -- ---- Base name panel (disabled in batch mode) ----
    UI.BeginPanel("rn_base", { style = "groupbox", title = "Base name" })
        if not s.batch_mode and s.need_focus then
            UI.SetFocus(BASE_INPUT_ID)
            s.need_focus = false
        end
        local ch, nv, submitted = UI.InputText(BASE_INPUT_ID, "", s.base_name, {
            hint = "type a name…",
            disabled = s.batch_mode,
        })
        if ch then s.base_name = nv end
        if submitted and not s.batch_mode then
            TakeRenamer.Apply(UI)
        end
    UI.EndPanel()

    -- ---- Naming options panel ----
    UI.BeginPanel("rn_opts", { style = "groupbox", title = "Naming options" })
        -- Prefix (checkbox + input on same line)
        local pch, pnew = UI.Checkbox("rn_use_pfx", "Use prefix", s.use_prefix)
        if pch then s.use_prefix = pnew end
        if s.use_prefix then
            UI.SameLine()
            local ich, inew = UI.InputText("rn_pfx", "", s.prefix, { hint = "prefix" })
            if ich then s.prefix = inew end
        end

        -- Suffix (checkbox + input on same line)
        local sch, snew = UI.Checkbox("rn_use_sfx", "Use suffix", s.use_suffix)
        if sch then s.use_suffix = snew end
        if s.use_suffix then
            UI.SameLine()
            local ich, inew = UI.InputText("rn_sfx", "", s.suffix, { hint = "suffix" })
            if ich then s.suffix = inew end
        end

        -- Numbering
        local multiple = #s.selected_items > 1
        local num_label = "Use numbering" .. (multiple and "" or "  (multiple items only)")
        local nch, nnew = UI.Checkbox("rn_use_num", num_label, s.use_numbering)
        if nch then s.use_numbering = nnew end

        if s.use_numbering then
            UI.Spacing(theme.separator_pad)
            UI.Text("Number format:")
            UI.Spacing(theme.separator_pad)
            local nf_idx = 1
            for i, f in ipairs(NUMBER_FORMATS) do
                if f.value == s.number_format then nf_idx = i; break end
            end
            local nf_labels = {}
            for i, f in ipairs(NUMBER_FORMATS) do nf_labels[i] = f.label end
            local fch, fnew = UI.RadioGroup("rn_numfmt", "", nf_idx, nf_labels, { horizontal = true })
            if fch then s.number_format = NUMBER_FORMATS[fnew].value end
        end
    UI.EndPanel()

    -- ---- Space replacement panel ----
    UI.BeginPanel("rn_space", { style = "groupbox", title = "Space replacement" })
        local sp_idx = 1
        for i, sp in ipairs(SPACER_TYPES) do
            if sp.value == s.spacer_type then sp_idx = i; break end
        end
        local sp_labels = {}
        for i, sp in ipairs(SPACER_TYPES) do sp_labels[i] = sp.label end
        local spch, spnew = UI.RadioGroup("rn_spacer", "", sp_idx, sp_labels, { horizontal = true })
        if spch then s.spacer_type = SPACER_TYPES[spnew].value end
    UI.EndPanel()

    -- ---- Preview (inset panel — no max_h fill issue) ----
    UI.BeginPanel("rn_preview", { style = "inset", title = "Preview" })
        local lines = TakeRenamer.Preview()
        local accent = theme.colors.accent
        for _, line in ipairs(lines) do
            UI.TextColored(line, accent[1], accent[2], accent[3], 1)
        end
    UI.EndPanel()

    -- ---- Wildcards help ----
    UI.Text("Available wildcards:", { disabled = true })
    UI.Text(table.concat(WILDCARD_KEYS, "  "), { disabled = true })

    -- ---- Push buttons to bottom ----
    local footer_h = theme.button_height + theme.item_spacing
    local remaining = UI.Layout.GetAvailableHeight() - footer_h
    if remaining > 0 then UI.Spacing(remaining) end

    -- ---- Action row ----
    if UI.Button("rn_apply", "Apply", { width = 100 }) then
        TakeRenamer.Apply(UI)
    end
    UI.SameLine()
    if UI.Button("rn_cancel", "Cancel", { width = 100 }) then
        UI.Core.RequestClose()
    end
    UI.SameLine()
    local ach, anew = UI.Checkbox("rn_auto", "Auto-close after apply", s.auto_close)
    if ach then s.auto_close = anew end
end

return TakeRenamer
