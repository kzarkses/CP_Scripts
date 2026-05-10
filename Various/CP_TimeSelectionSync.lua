-- @description TimeSelectionSync
-- @version 2.0
-- @author Cedric Pamalio

local r = reaper

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root_path = script_path:match("(.*[\\/]).*[\\/]") or script_path
local toolkit_path = root_path .. "CP_Toolkit/"

local UI = dofile(toolkit_path .. "CP_Toolkit.lua")

local script_id = "CP_TimeSelectionSync"

local config = {
    time_selection_extension = 0.0,
    sync_edit_cursor = false,
    sync_automation = false,
    sync_time_selection = true,
    playback_mode = "preview",
    automation_mode = "stretch_trim", -- "stretch_trim" | "stretch" | "loop"
    automation_loop_divisions = 4,    -- integer N: source = item_length / N (Loop mode)
}

local state = {
    last_selected_item_guid = nil,
    mouse_down_time = 0,
    last_mouse_state = 0,
    mouse_down_start = 0,
    long_press_threshold = 0.15,
    is_dragging = false,
    last_track_guid = nil,
    last_refresh_time = 0,
    last_selected_items = {},
    last_item_positions = {},
    last_item_lengths = {},
    last_edit_cursor_pos = -1,
    last_envelope_count = {},
    last_item_rates = {},
    last_item_selection = {},
    last_ai_qnlen = {},  -- key: env_ptr .. ":" .. pool_id, val: last applied D_POOL_QNLEN
    locked_item = nil,   -- MediaItem* or nil — when set, sync targets only this item
}

local function SaveSettings()
    for key, value in pairs(config) do
        local value_str = tostring(value)
        if type(value) == "boolean" then
            value_str = value and "1" or "0"
        end
        r.SetExtState(script_id, "config_" .. key, value_str, true)
    end
end

local function LoadSettings()
    for key, default_value in pairs(config) do
        local saved_value = r.GetExtState(script_id, "config_" .. key)
        if saved_value ~= "" then
            if type(default_value) == "number" then
                config[key] = tonumber(saved_value) or default_value
            elseif type(default_value) == "boolean" then
                config[key] = saved_value == "1"
            else
                config[key] = saved_value
            end
        end
    end
end

-- ============================================================================
-- Per-item AI preferences store
-- ----------------------------------------------------------------------------
-- Each item carries its own prefs for the AIs that overlap it. Keyed by the
-- AI pool_id (stable identifier on the envelope). An entry exists only when
-- the user has explicitly adopted the AI; absence means "not managed".
-- Serialized in project ExtState as: pid=mode:div|pid=mode:div|...
-- ============================================================================

local item_prefs_cache = {}  -- item_guid -> { [pool_id] = {mode=..., divisions=...} }

local function ItemGUID(item)
    local _, g = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
    return g
end

local function ItemPrefsKey(guid)
    return "item_" .. guid
end

local function ParseItemPrefs(s)
    local out = {}
    if not s or s == "" then return out end
    for entry in string.gmatch(s, "[^|]+") do
        local pid, mode, div = entry:match("^(-?%d+)=([^:]+):(%-?%d+)$")
        if pid then
            out[tonumber(pid)] = {
                mode = mode,
                divisions = tonumber(div) or 4,
            }
        end
    end
    return out
end

local function SerializeItemPrefs(prefs)
    local parts = {}
    for pid, p in pairs(prefs) do
        parts[#parts + 1] = string.format("%d=%s:%d",
            math.floor(pid), p.mode or "stretch_trim", p.divisions or 4)
    end
    return table.concat(parts, "|")
end

local function GetItemPrefs(item)
    local guid = ItemGUID(item)
    local cached = item_prefs_cache[guid]
    if cached then return cached, guid end
    local raw = r.GetProjExtState(0, script_id, ItemPrefsKey(guid))
    -- GetProjExtState returns (retval, value) where retval is 1 if found.
    local s
    if type(raw) == "number" then
        local _, v = r.GetProjExtState(0, script_id, ItemPrefsKey(guid))
        s = v
    else
        s = raw
    end
    local prefs = ParseItemPrefs(s)
    item_prefs_cache[guid] = prefs
    return prefs, guid
end

local function SaveItemPrefs(guid, prefs)
    item_prefs_cache[guid] = prefs
    r.SetProjExtState(0, script_id, ItemPrefsKey(guid), SerializeItemPrefs(prefs))
end

-- Returns the envelope display name (FX param + plugin, or just the env name).
local function EnvName(env)
    local _, name = r.GetEnvelopeName(env)
    return name or "?"
end

-- Lists rows for the per-AI UI. Each visible envelope produces:
--  • one row per AI overlapping the item (with pool_id), OR
--  • a single "empty" row (pool_id = nil) so the user can Create one.
-- Returns: {{env, env_name, ai_idx?, pool_id?}, ...}
local function ListAIsOnItem(item)
    local out = {}
    if not item then return out end
    local track = r.GetMediaItem_Track(item)
    if not track then return out end

    local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_pos + item_len

    local env_count = r.CountTrackEnvelopes(track)
    for k = 0, env_count - 1 do
        local env = r.GetTrackEnvelope(track, k)
        local br_env = r.BR_EnvAlloc(env, false)
        local _, _, _, _, _, visible = r.BR_EnvGetProperties(br_env)
        r.BR_EnvFree(br_env, false)
        if visible then
            local env_name = EnvName(env)
            local found_any = false
            local n = r.CountAutomationItems(env)
            for l = 0, n - 1 do
                local pos = r.GetSetAutomationItemInfo(env, l, "D_POSITION", 0, false)
                local len = r.GetSetAutomationItemInfo(env, l, "D_LENGTH", 0, false)
                local pid = r.GetSetAutomationItemInfo(env, l, "D_POOL_ID", 0, false)
                if pos + len > item_pos and pos < item_end then
                    out[#out + 1] = {
                        env = env,
                        env_name = env_name,
                        ai_idx = l,
                        pool_id = math.floor(pid),
                    }
                    found_any = true
                end
            end
            if not found_any then
                out[#out + 1] = { env = env, env_name = env_name }
            end
        end
    end
    return out
end

local function DetectEnvelopeChanges(track)
    if not track then return false end
    local track_guid = r.GetTrackGUID(track)
    local current_env_count = r.CountTrackEnvelopes(track)
    if state.last_envelope_count[track_guid] ~= current_env_count then
        state.last_envelope_count[track_guid] = current_env_count
        return true
    end
    return false
end

local function IsClickOnSelectedItem()
    local x, y = r.GetMousePosition()
    local item = r.GetItemFromPoint(x, y, false)
    if not item then return false end
    if not r.IsMediaItemSelected(item) then return false end

    local left_click = r.JS_Mouse_GetState(1) == 1
    local was_clicked = left_click and state.last_mouse_state == 0
    state.last_mouse_state = left_click and 1 or 0
    return was_clicked
end

-- Returns the active target item list. When an item is locked it overrides
-- the current arrange selection. Auto-clears the lock if the item no longer
-- exists (e.g. user deleted it).
local function GetTargetItems()
    if state.locked_item then
        if r.ValidatePtr2(0, state.locked_item, "MediaItem*") then
            return { state.locked_item }
        else
            state.locked_item = nil
        end
    end
    local items = {}
    local n = r.CountSelectedMediaItems(0)
    for i = 0, n - 1 do
        items[#items + 1] = r.GetSelectedMediaItem(0, i)
    end
    return items
end

local function GetTargetItemsRange(items)
    local start_pos = math.huge
    local end_pos = -math.huge
    for _, item in ipairs(items) do
        local p = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local l = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        if p < start_pos then start_pos = p end
        if p + l > end_pos then end_pos = p + l end
    end
    if start_pos == math.huge then return nil, nil end
    return start_pos, end_pos
end

local function DetectChanges()
    local items = GetTargetItems()
    local changes_detected = false

    -- Click on a selected item is treated as a change so newly-touched
    -- items get re-synced even when nothing else moved.
    if not state.locked_item and IsClickOnSelectedItem() then
        return true
    end

    -- Track membership changes (selection add/remove). Skipped while locked
    -- since the target set is fixed.
    if not state.locked_item then
        local current = {}
        for _, item in ipairs(items) do
            local guid = r.BR_GetMediaItemGUID(item)
            current[guid] = true
            if not state.last_item_selection[guid] then
                changes_detected = true
            end
        end
        for guid in pairs(state.last_item_selection) do
            if not current[guid] then
                changes_detected = true
            end
        end
        state.last_item_selection = current
    end

    -- Track per-item geometry/envelope changes for the active target set.
    for _, item in ipairs(items) do
        local guid = r.BR_GetMediaItemGUID(item)
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local take = r.GetActiveTake(item)
        local rate = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1

        local track = r.GetMediaItem_Track(item)
        if DetectEnvelopeChanges(track) then
            changes_detected = true
        end

        if state.last_item_positions[guid] ~= pos or
           state.last_item_lengths[guid] ~= length or
           state.last_item_rates[guid] ~= rate then
            changes_detected = true
        end

        state.last_item_positions[guid] = pos
        state.last_item_lengths[guid] = length
        state.last_item_rates[guid] = rate
    end

    local cursor_pos = r.GetCursorPosition()
    if config.sync_edit_cursor and state.last_edit_cursor_pos ~= cursor_pos then
        changes_detected = true
    end

    return changes_detected
end

-- D_POOL_QNLEN is expressed in QN at a fixed 120 BPM reference (2 QN/sec),
-- independent of project tempo. Verified empirically.
local SEC_TO_POOL_QN = 2.0

-- Compute the (target_rate, target_qnlen) for a given item + mode + divisions.
local function ComputeAITarget(item, mode, divisions)
    local take = r.GetActiveTake(item)
    local item_length = math.max(r.GetMediaItemInfo_Value(item, "D_LENGTH"), 0.1)
    local item_rate = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1

    local src_len_sec = item_length
    if take then
        local source = r.GetMediaItemTake_Source(take)
        if source then
            local src_val, is_qn = r.GetMediaSourceLength(source)
            if is_qn then
                src_len_sec = src_val * 60 / r.Master_GetTempo()
            else
                src_len_sec = src_val
            end
        end
    end

    local item_qn_len   = item_length * SEC_TO_POOL_QN
    local source_qn_len = src_len_sec * SEC_TO_POOL_QN

    if mode == "stretch_trim" then
        return source_qn_len / item_qn_len, source_qn_len
    elseif mode == "stretch" then
        return item_rate, (item_length / item_rate) * SEC_TO_POOL_QN
    else  -- "loop"
        local divs = math.max(math.floor(divisions or 1), 1)
        return 1.0, item_qn_len / divs
    end
end

-- Apply geometry + source length to an AI, rescaling existing points
-- proportionally if D_POOL_QNLEN actually changed vs last applied.
local function ApplyAIGeometry(env, ai_idx, item_pos, item_length, mode, target_rate, target_qnlen)
    local old_qnlen = r.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_QNLEN", 0, false)
    local pool_id = r.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_ID", 0, false)
    local cache_key = tostring(env) .. ":" .. tostring(math.floor(pool_id))
    local last_applied = state.last_ai_qnlen[cache_key]

    r.GetSetAutomationItemInfo(env, ai_idx, "D_POSITION",   item_pos,    true)
    r.GetSetAutomationItemInfo(env, ai_idx, "D_LENGTH",     item_length, true)
    r.GetSetAutomationItemInfo(env, ai_idx, "D_STARTOFFS",  0,           true)
    r.GetSetAutomationItemInfo(env, ai_idx, "D_PLAYRATE",   target_rate, true)
    r.GetSetAutomationItemInfo(env, ai_idx, "D_LOOPSRC", mode == "loop" and 1 or 0, true)

    local qnlen_changed = (last_applied == nil)
                       or (math.abs((last_applied or 0) - target_qnlen) > 1e-9)

    if qnlen_changed and old_qnlen > 1e-9 and target_qnlen > 1e-9 then
        local AI_FLAG = ai_idx | 0x10000000
        local old_src_sec = old_qnlen    / SEC_TO_POOL_QN
        local new_src_sec = target_qnlen / SEC_TO_POOL_QN
        local ai_pos_sec  = r.GetSetAutomationItemInfo(env, ai_idx, "D_POSITION", 0, false)

        local pts = {}
        local n = r.CountEnvelopePointsEx(env, AI_FLAG)
        for p = 0, n - 1 do
            local ok, t, val, shape, tens, sel =
                r.GetEnvelopePointEx(env, AI_FLAG, p)
            if ok then
                pts[#pts + 1] = {
                    rel = (t - ai_pos_sec) / old_src_sec,
                    val = val, shape = shape, tens = tens, sel = sel,
                }
            end
        end

        r.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_QNLEN", target_qnlen, true)

        for p = n - 1, 0, -1 do
            r.DeleteEnvelopePointEx(env, AI_FLAG, p)
        end
        for _, pt in ipairs(pts) do
            local new_t = ai_pos_sec + pt.rel * new_src_sec
            r.InsertEnvelopePointEx(env, AI_FLAG,
                new_t, pt.val, pt.shape, pt.tens, pt.sel, true)
        end
        r.Envelope_SortPointsEx(env, AI_FLAG)
    else
        r.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_QNLEN", target_qnlen, true)
    end

    state.last_ai_qnlen[cache_key] = target_qnlen
end

local function SyncAutomationItems()
    local items = GetTargetItems()
    if #items == 0 then return end

    local total_start, total_end = GetTargetItemsRange(items)
    if not total_start then return end

    if config.sync_time_selection then
        r.GetSet_LoopTimeRange(true, false, total_start,
            total_end + config.time_selection_extension, false)
    end

    if config.sync_edit_cursor then
        r.SetEditCurPos(total_start, false, false)
        state.last_edit_cursor_pos = total_start
    end

    if not config.sync_automation then
        r.UpdateTimeline()
        return
    end

    -- Drive the sync from per-item adopted prefs only. Non-adopted AIs are
    -- left untouched (the user can adopt them via the UI).
    for _, item in ipairs(items) do
        local prefs = GetItemPrefs(item)
        local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = math.max(r.GetMediaItemInfo_Value(item, "D_LENGTH"), 0.1)

        for _, ai in ipairs(ListAIsOnItem(item)) do
            local p = prefs[ai.pool_id]
            if p then
                local rate, qnlen = ComputeAITarget(item, p.mode, p.divisions)
                ApplyAIGeometry(ai.env, ai.ai_idx, item_pos, item_length,
                                p.mode, rate, qnlen)
            end
        end
    end

    r.UpdateTimeline()
end

-- Create a new AI on a given envelope tied to an item, allocate a fresh
-- pool_id (so D_POOL_QNLEN works), and adopt it in the item's prefs with
-- the current global defaults.
local function CreateAndAdoptAI(item, env)
    local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = math.max(r.GetMediaItemInfo_Value(item, "D_LENGTH"), 0.1)

    -- Scan ALL envelopes on the track for the max pool_id, not just the one
    -- we're inserting into. Otherwise two empty envelopes would each get a
    -- fresh AI with pool_id=0 → same pool → linked behaviour.
    local track = r.GetMediaItem_Track(item)
    local max_pool_id = -1
    local env_count = r.CountTrackEnvelopes(track)
    for k = 0, env_count - 1 do
        local e = r.GetTrackEnvelope(track, k)
        local n = r.CountAutomationItems(e)
        for l = 0, n - 1 do
            local pid = r.GetSetAutomationItemInfo(e, l, "D_POOL_ID", 0, false)
            if pid > max_pool_id then max_pool_id = pid end
        end
    end

    local ai_idx = r.InsertAutomationItem(env, max_pool_id + 1, item_pos, item_length)
    local pool_id = math.floor(r.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_ID", 0, false))

    local prefs, guid = GetItemPrefs(item)
    prefs[pool_id] = {
        mode = config.automation_mode,
        divisions = config.automation_loop_divisions,
    }
    SaveItemPrefs(guid, prefs)

    local rate, qnlen = ComputeAITarget(item, config.automation_mode,
                                        config.automation_loop_divisions)
    ApplyAIGeometry(env, ai_idx, item_pos, item_length,
                    config.automation_mode, rate, qnlen)
end

-- Adopt an existing AI (already on an envelope under the item) into prefs.
local function AdoptAI(item, pool_id)
    local prefs, guid = GetItemPrefs(item)
    prefs[pool_id] = {
        mode = config.automation_mode,
        divisions = config.automation_loop_divisions,
    }
    SaveItemPrefs(guid, prefs)
end

local function DropAI(item, pool_id)
    local prefs, guid = GetItemPrefs(item)
    prefs[pool_id] = nil
    SaveItemPrefs(guid, prefs)
end

LoadSettings()

-- Garbage-collect ProjExtState entries for items that no longer exist.
-- Without this, deleting items would leave orphan prefs piling up forever.
local function GCItemPrefs()
    local known_guids = {}
    local n = r.CountMediaItems(0)
    for i = 0, n - 1 do
        known_guids[ItemGUID(r.GetMediaItem(0, i))] = true
    end
    local stale_keys = {}
    local idx = 0
    while true do
        local ok, key = r.EnumProjExtState(0, script_id, idx)
        if not ok or not key then break end
        local guid = key:match("^item_(.+)$")
        if guid and not known_guids[guid] then
            stale_keys[#stale_keys + 1] = key
        end
        idx = idx + 1
    end
    for _, key in ipairs(stale_keys) do
        r.SetProjExtState(0, script_id, key, "")
    end
end
GCItemPrefs()

local _, _, section_id, command_id = r.get_action_context()
r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

UI.Init("Time Selection Config", 280, 400, {
    scale = 1.0,
    dock = 0,
    persist = script_id,
})

local AUTO_MODES     = { "Stretch + Trim", "Stretch",   "Loop"   }
local AUTO_MODE_KEYS = { "stretch_trim",   "stretch",   "loop"   }

local function auto_mode_index()
    for i, k in ipairs(AUTO_MODE_KEYS) do
        if k == config.automation_mode then return i end
    end
    return 1
end

UI.Run(function(theme)
    UI.SetFontH2()
    UI.Text("Time Selection Config")
    UI.SetFontBody()
    UI.Separator()

    local time_changed, cursor_changed, auto_changed
    time_changed, config.sync_time_selection = UI.Checkbox("sync_ts", "Sync Time Selection", config.sync_time_selection)
    cursor_changed, config.sync_edit_cursor = UI.Checkbox("sync_cur", "Sync Edit Cursor", config.sync_edit_cursor)
    auto_changed, config.sync_automation = UI.Checkbox("sync_auto", "Sync Automation", config.sync_automation)

    if time_changed or cursor_changed or auto_changed then
        SaveSettings()
    end

    if config.sync_automation then
        UI.Indent()

        -- Lock + active item resolution
        local active_item = state.locked_item
        if active_item and not r.ValidatePtr2(0, active_item, "MediaItem*") then
            state.locked_item = nil
            active_item = nil
        end
        if not active_item then
            active_item = r.GetSelectedMediaItem(0, 0)
        end

        if state.locked_item then
            local name = "?"
            local take = r.GetActiveTake(state.locked_item)
            if take then
                local _, n = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                if n and n ~= "" then name = n end
            end
            UI.Text("Locked: " .. name)
            UI.SameLine()
            if UI.Button("auto_unlock", "Unlock") then
                state.locked_item = nil
            end
        else
            if UI.Button("auto_lock", "Lock to selection") then
                if active_item then
                    state.locked_item = active_item
                    SyncAutomationItems()
                end
            end
        end

        UI.Spacing(theme.item_spacing)

        -- Defaults applied when adopting / creating new AIs
        UI.SetFontCaption()
        UI.Text("Defaults for new AIs")
        UI.SetFontBody()
        local mode_changed, new_mode_idx = UI.Combo(
            "auto_mode", "Mode", auto_mode_index(), AUTO_MODES, { width = 140 }
        )
        if mode_changed then
            config.automation_mode = AUTO_MODE_KEYS[new_mode_idx]
            SaveSettings()
        end
        if config.automation_mode == "loop" then
            local div_changed, div_value = UI.SliderInt(
                "auto_loop_div", "Divisions",
                config.automation_loop_divisions,
                1, 32
            )
            if div_changed then
                config.automation_loop_divisions = div_value
                SaveSettings()
            end
        end

        UI.Spacing(theme.item_spacing)
        UI.Separator()

        -- Per-AI list for the active item
        if active_item then
            UI.SetFontCaption()
            UI.Text("Automation Items on this item")
            UI.SetFontBody()

            local rows = ListAIsOnItem(active_item)
            if #rows == 0 then
                UI.TextColored("(no visible envelopes on this track)", 0.6, 0.6, 0.6, 1)
            else
                local prefs = GetItemPrefs(active_item)
                for _, row in ipairs(rows) do
                    -- Stable, unique row ID. For empty envelopes we fall back
                    -- to the env pointer so two empty envs don't collide.
                    local row_id
                    if row.pool_id then
                        row_id = "ai_p" .. tostring(row.pool_id)
                    else
                        row_id = "ai_e" .. tostring(row.env)
                    end

                    UI.Text(row.env_name)

                    if not row.pool_id then
                        -- Visible envelope with no AI on this item → offer Create
                        UI.SameLine()
                        if UI.Button(row_id .. "_create", "Create") then
                            CreateAndAdoptAI(active_item, row.env)
                        end
                    else
                        local p = prefs[row.pool_id]
                        if p then
                            -- Adopted
                            local cur_mode_idx = 1
                            for k, key in ipairs(AUTO_MODE_KEYS) do
                                if key == p.mode then cur_mode_idx = k break end
                            end
                            local mc, new_idx = UI.Combo(row_id .. "_mode", "Mode",
                                cur_mode_idx, AUTO_MODES, { width = 120 })
                            if mc then
                                p.mode = AUTO_MODE_KEYS[new_idx]
                                SaveItemPrefs(ItemGUID(active_item), prefs)
                                SyncAutomationItems()
                            end
                            if p.mode == "loop" then
                                local dc, nv = UI.SliderInt(row_id .. "_div",
                                    "Divisions", p.divisions or 4, 1, 32)
                                if dc then
                                    p.divisions = nv
                                    SaveItemPrefs(ItemGUID(active_item), prefs)
                                    SyncAutomationItems()
                                end
                            end
                            if UI.Button(row_id .. "_drop", "Drop") then
                                DropAI(active_item, row.pool_id)
                            end
                        else
                            -- Not adopted yet (existing AI we don't manage)
                            UI.SameLine()
                            UI.TextColored("(not managed)", 0.6, 0.6, 0.6, 1)
                            UI.SameLine()
                            if UI.Button(row_id .. "_adopt", "Adopt") then
                                AdoptAI(active_item, row.pool_id)
                                SyncAutomationItems()
                            end
                        end
                    end
                    UI.Spacing(2)
                end
            end
        else
            UI.TextColored("(no item selected)", 0.6, 0.6, 0.6, 1)
        end

        UI.Unindent()
    end

    if config.sync_time_selection then
        UI.Separator()
        UI.Text("Time Selection Extension")

        local ext_changed, ext_value = UI.SliderDouble(
            "ext_slider", "s",
            config.time_selection_extension,
            0.0, 5.0,
            { format = "%.2fs" }
        )
        if ext_changed then
            config.time_selection_extension = ext_value
            SyncAutomationItems()
            SaveSettings()
        end

        UI.Spacing(theme.item_spacing)
        UI.Text("Presets:")

        local presets = { 0.0, 0.1, 0.3, 0.5 }
        for i, val in ipairs(presets) do
            if i > 1 then UI.SameLine() end
            local label = string.format("%.1fs", val)
            if UI.Button("preset_" .. i, label) then
                config.time_selection_extension = val
                SyncAutomationItems()
                SaveSettings()
            end
        end
    end

    local current_time = r.time_precise()
    if current_time - state.last_refresh_time >= 0.015 then
        if DetectChanges() then
            SyncAutomationItems()
        end
        state.last_refresh_time = current_time
    end
end)

UI.OnClose(function()
    local selected_item = r.GetSelectedMediaItem(0, 0)
    if selected_item then
        SyncAutomationItems()
    end
    SaveSettings()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
    r.UpdateArrange()
end)
