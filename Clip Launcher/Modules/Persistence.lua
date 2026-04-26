local Persistence = {}

local r, Core, ClipManager, Engine, Sequencer

local SAVE_INTERVAL = 1.0  -- max 1 save per second

function Persistence.init(reaper_api, core, clip_manager, engine, sequencer)
    r = reaper_api
    Core = core
    ClipManager = clip_manager
    Engine = engine
    Sequencer = sequencer

    Persistence.last_save_time = 0
end

-- Check if state is dirty and enough time has passed, then auto-save
function Persistence.checkAutoSave()
    if not Core.state.dirty then return end

    local now = r.time_precise()
    if now - Persistence.last_save_time < SAVE_INTERVAL then return end

    Persistence.saveSession()
    Persistence.last_save_time = now
    Core.state.dirty = false
end

-- ============================================================
-- SIMPLE SERIALIZATION
-- ============================================================

local function serializeValue(val)
    local t = type(val)
    if t == "string" then
        return string.format("%q", val)
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "table" then
        local parts = {}
        -- Array part
        local array_len = #val
        for i = 1, array_len do
            parts[#parts + 1] = serializeValue(val[i])
        end
        -- Hash part
        for k, v in pairs(val) do
            if type(k) == "number" and k >= 1 and k <= array_len and math.floor(k) == k then
                -- Skip, already handled
            else
                local key_str
                if type(k) == "string" then
                    key_str = "[" .. string.format("%q", k) .. "]"
                else
                    key_str = "[" .. tostring(k) .. "]"
                end
                parts[#parts + 1] = key_str .. "=" .. serializeValue(v)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

local function deserialize(str)
    if not str or str == "" then return nil end
    local func = load("return " .. str)
    if func then
        local ok, result = pcall(func)
        if ok then return result end
    end
    return nil
end

-- ============================================================
-- SESSION SAVE/LOAD
-- ============================================================

function Persistence.saveSession()
    local section = Core.EXTSTATE_SECTION

    -- Save config
    r.SetExtState(section, "quantize_mode", tostring(Core.state.quantize_mode), true)
    r.SetExtState(section, "window_width", tostring(Core.config.window_width), true)
    r.SetExtState(section, "window_height", tostring(Core.config.window_height), true)

    -- Save overlay calibration (MCP)
    local ov = Core.config.overlay
    r.SetExtState(section, "overlay_enabled", ov.enabled and "1" or "0", true)
    r.SetExtState(section, "overlay_offset_x", tostring(ov.offset_x), true)
    r.SetExtState(section, "overlay_offset_y", tostring(ov.offset_y), true)
    r.SetExtState(section, "overlay_height_ratio", tostring(ov.height_ratio), true)

    -- Save TCP overlay calibration
    local tcp = Core.config.tcp_overlay
    r.SetExtState(section, "tcp_enabled", tcp.enabled and "1" or "0", true)
    r.SetExtState(section, "tcp_offset_x", tostring(tcp.offset_x), true)
    r.SetExtState(section, "tcp_offset_y", tostring(tcp.offset_y), true)
    r.SetExtState(section, "tcp_width_ratio", tostring(tcp.width_ratio), true)

    -- Export recorded clips to WAV before saving (so they have file paths)
    for i, column in ipairs(Core.state.columns) do
        for ci, clip in pairs(column.clips) do
            if clip.loaded and clip.source == "recorded" and not clip.file_path then
                ClipManager.exportRecordedClip(i, ci, Engine)
            end
        end
    end

    -- Save columns (keyed by track GUID for stable identification)
    local columns_data = {}
    for i, column in ipairs(Core.state.columns) do
        local col_data = {
            track_guid = column.track_guid,
            jsfx_slot = column.jsfx_slot,
            play_mode = column.play_mode,
            launch_mode = column.launch_mode,
            volume = column.volume,
            sequencer_enabled = column.sequencer_enabled,
            sequencer_interval_min = column.sequencer_interval_min,
            sequencer_interval_max = column.sequencer_interval_max,
            probabilities = column.probabilities,
            clips = {},
        }

        for ci, clip in pairs(column.clips) do
            if clip.loaded and clip.file_path then
                col_data.clips[ci] = {
                    file_path = clip.file_path,
                    name = clip.name,
                    follow_action = clip.follow_action ~= Core.FOLLOW_NONE and clip.follow_action or nil,
                    follow_count = clip.follow_count ~= 1 and clip.follow_count or nil,
                }
            end
        end

        columns_data[i] = col_data
    end

    r.SetExtState(section, "columns", serializeValue(columns_data), true)
    r.SetExtState(section, "num_columns", tostring(#columns_data), true)
end

function Persistence.loadSession()
    local section = Core.EXTSTATE_SECTION

    -- Load config
    local qm = r.GetExtState(section, "quantize_mode")
    if qm ~= "" then Core.state.quantize_mode = tonumber(qm) or Core.QUANTIZE_BAR end

    local ww = r.GetExtState(section, "window_width")
    if ww ~= "" then Core.config.window_width = tonumber(ww) or 600 end

    local wh = r.GetExtState(section, "window_height")
    if wh ~= "" then Core.config.window_height = tonumber(wh) or 400 end

    -- Load overlay calibration (MCP)
    local ov = Core.config.overlay
    local oe = r.GetExtState(section, "overlay_enabled")
    if oe ~= "" then ov.enabled = oe == "1" end
    local ox = r.GetExtState(section, "overlay_offset_x")
    if ox ~= "" then ov.offset_x = tonumber(ox) or 0 end
    local oy = r.GetExtState(section, "overlay_offset_y")
    if oy ~= "" then ov.offset_y = tonumber(oy) or 0 end
    local oh = r.GetExtState(section, "overlay_height_ratio")
    if oh ~= "" then ov.height_ratio = tonumber(oh) or 0.6 end

    -- Load TCP overlay calibration
    local tcp = Core.config.tcp_overlay
    local te = r.GetExtState(section, "tcp_enabled")
    if te ~= "" then tcp.enabled = te == "1" end
    local tx = r.GetExtState(section, "tcp_offset_x")
    if tx ~= "" then tcp.offset_x = tonumber(tx) or 0 end
    local ty = r.GetExtState(section, "tcp_offset_y")
    if ty ~= "" then tcp.offset_y = tonumber(ty) or 0 end
    local tw = r.GetExtState(section, "tcp_width_ratio")
    if tw ~= "" then tcp.width_ratio = tonumber(tw) or 0.5 end

    -- Load saved column data
    local columns_str = r.GetExtState(section, "columns")
    local columns_data = deserialize(columns_str)
    if not columns_data then return end

    -- First do an initial sync so columns exist for all current tracks
    Engine.syncColumns()

    -- Then restore saved state to matching columns
    for _, col_data in ipairs(columns_data) do
        -- Find the column by track GUID
        local column = Engine.findColumnByGUID(col_data.track_guid)
        if column then
            column.play_mode = col_data.play_mode or Core.PLAY_LOOP
            column.launch_mode = col_data.launch_mode or Core.LAUNCH_TRIGGER
            column.volume = col_data.volume or 1.0
            column.sequencer_enabled = col_data.sequencer_enabled or false
            column.sequencer_interval_min = col_data.sequencer_interval_min or 1
            column.sequencer_interval_max = col_data.sequencer_interval_max or 4
            column.probabilities = col_data.probabilities or {}

            -- Find column index for clip loading
            local col_idx = -1
            for i, c in ipairs(Core.state.columns) do
                if c.track_guid == col_data.track_guid then
                    col_idx = i
                    break
                end
            end

            -- Reload clips
            if col_idx > 0 then
                for ci, clip_data in pairs(col_data.clips or {}) do
                    if clip_data.file_path and r.file_exists(clip_data.file_path) then
                        ClipManager.loadClip(col_idx, ci, clip_data.file_path, Engine)
                        -- Restore follow actions
                        local loaded_clip = column.clips[ci]
                        if loaded_clip then
                            loaded_clip.follow_action = clip_data.follow_action or Core.FOLLOW_NONE
                            loaded_clip.follow_count = clip_data.follow_count or 1
                        end
                    end
                end
            end
        end
    end
end

return Persistence
