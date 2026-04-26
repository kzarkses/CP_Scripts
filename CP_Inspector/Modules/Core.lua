-- CP_Inspector Core — Shared constants, state, helpers
-- All values from Theme (no hardcoded sizes/colors)

local Core = {}

-- ============================================================================
-- SCRIPT IDENTITY
-- ============================================================================
Core.SCRIPT_ID = "CP_Inspector"
Core.VERSION = "1.0"

-- ============================================================================
-- PROPERTY DEFINITIONS
-- ============================================================================
-- Each property: key, label, type, default, range, format, weight (for responsive layout)
Core.PROPERTIES = {
    { key = "name",           label = "Name",     type = "text",    weight = 2.5 },
    { key = "source",         label = "Source",    type = "text",    weight = 2.5 },
    { key = "position",       label = "Position",  type = "time",    weight = 1.0 },
    { key = "length",         label = "Length",    type = "time",    weight = 1.0 },
    { key = "snap",           label = "Snap",      type = "time",    weight = 1.0 },
    { key = "fadein",         label = "Fade In",   type = "time",    weight = 1.0 },
    { key = "fadeout",        label = "Fade Out",  type = "time",    weight = 1.0 },
    { key = "itemvol",        label = "Item Vol",  type = "db",      weight = 1.0, min = -120, max = 120, sensitivity = 0.05 },
    { key = "takevol",        label = "Take Vol",  type = "db",      weight = 1.0, min = -120, max = 120, sensitivity = 0.05 },
    { key = "pitch",          label = "Pitch",     type = "semi",    weight = 1.0, min = -96,  max = 96,  sensitivity = 0.1 },
    { key = "preserve_pitch", label = "PP",        type = "bool",    weight = 1.0 },
    { key = "pan",            label = "Pan",       type = "pan",     weight = 1.0, min = -1,   max = 1,   sensitivity = 0.01 },
    { key = "rate",           label = "Rate",      type = "rate",    weight = 1.0, min = 0.01, max = 40,  sensitivity = 0.01 },
    { key = "mute",           label = "Mute",      type = "bool",    weight = 1.0 },
}

-- Build lookup by key
Core.PROP_BY_KEY = {}
for _, p in ipairs(Core.PROPERTIES) do
    Core.PROP_BY_KEY[p.key] = p
end

-- ============================================================================
-- TIME DISPLAY MODES
-- ============================================================================
Core.TIME_MODES = {
    { key = "minsec",  label = "Min:Sec.ms" },
    { key = "beats",   label = "Bars.Beats.Ticks" },
    { key = "samples", label = "Samples" },
    { key = "seconds", label = "Seconds" },
}

-- ============================================================================
-- PITCH ALGORITHMS
-- ============================================================================
Core.PITCH_ALGORITHMS = {
    { index = -1, name = "Project Default" },
    { index = 0,  name = "SoundTouch" },
    { index = 2,  name = "Simple Windowed" },
    { index = 6,  name = "Elastique 2 Pro" },
    { index = 7,  name = "Elastique 2 Efficient" },
    { index = 8,  name = "Elastique 2 SOLOIST" },
    { index = 9,  name = "Elastique 3 Pro" },
    { index = 10, name = "Elastique 3 Efficient" },
    { index = 11, name = "Elastique 3 SOLOIST" },
    { index = 3,  name = "Rubber Band (Library)" },
    { index = 14, name = "Rrreeeaaa" },
    { index = 15, name = "ReaReaRea" },
}

-- ============================================================================
-- STATE
-- ============================================================================
Core.state = {
    -- Selection
    selected_items = {},
    item_count = 0,
    last_item = nil,

    -- Property values (current frame)
    values = {},

    -- Drag state
    drag_active = false,
    drag_prop = nil,
    drag_start_value = 0,

    -- Active sub-panel (nil, "take_renamer", "pitch_stretch", "source_manager")
    active_panel = nil,

    -- Settings
    time_mode = 1,  -- index into TIME_MODES
    visible_props = {},  -- which properties are shown

    -- Visual prefs (tweakable via CP_Inspector_Settings)
    prefs = {
        row_height       = 18,    -- height of header / value row (tight vertical rhythm like MPT)
        window_padding   = 2,     -- toolkit window padding (left/right/top/bottom)
        top_padding      = 0,     -- extra space above header (added to window padding)
        gap              = 0,     -- absolute px between header and value row (0 = touching)
        col_gap          = 4,     -- horizontal gap between columns
        show_header      = true,
        font_value       = "mono", -- "mono" or "body"
        text_align       = "center", -- "left" / "center" / "right"
        cell_padding_x   = 6,

        -- Value coloring (override theme.colors.value_*)
        col_normal   = { 0.75, 0.75, 0.75, 1.0 },
        col_modified = { 0.00, 0.80, 0.60, 1.0 },
        col_negative = { 0.80, 0.40, 0.60, 1.0 },
        col_header   = { 0.78, 0.78, 0.78, 0.5 },
        col_bg       = { 0.155, 0.155, 0.16, 1.0 }, -- window background
    },

    -- Settings version (bumped on save → other instances reload)
    settings_version = 0,
}

-- Initialize visible props (all on by default)
for _, p in ipairs(Core.PROPERTIES) do
    Core.state.visible_props[p.key] = true
end

-- ============================================================================
-- SETTINGS PERSISTENCE
-- ============================================================================
-- Toolkit reference (set externally so we can use UI.SaveConfig/LoadConfig).
-- We can't `dofile` the toolkit here without creating a dependency cycle, so
-- the bootstrap (CP_Inspector.lua / CP_Inspector_Settings.lua) calls
-- Core.SetToolkit(UI) before Load/SaveSettings.
local TK = nil
function Core.SetToolkit(toolkit) TK = toolkit end

function Core.SaveSettings()
    if not TK then return end
    -- 1) Build a single Lua table containing everything and write it as
    --    CP_Config/CP_Inspector.lua (one disk write of a small file).
    local data = {
        visible_props = {},
        time_mode = Core.state.time_mode,
        prefs = {},
    }
    for _, p in ipairs(Core.PROPERTIES) do
        data.visible_props[p.key] = Core.state.visible_props[p.key] and true or false
    end
    -- Copy prefs by value (avoid sharing the live table)
    for k, v in pairs(Core.state.prefs) do
        if type(v) == "table" then
            data.prefs[k] = { v[1], v[2], v[3], v[4] }
        else
            data.prefs[k] = v
        end
    end
    TK.SaveConfig(Core.SCRIPT_ID, data)

    -- 2) Bump the cross-script version stamp via ExtState (in-memory only,
    --    no disk write — other running instances poll it cheaply).
    Core.state.settings_version = Core.state.settings_version + 1
    reaper.SetExtState(Core.SCRIPT_ID, "settings_version",
        tostring(Core.state.settings_version), false)
end

function Core.LoadSettings()
    if not TK then return end
    local data = TK.LoadConfig(Core.SCRIPT_ID)
    if not data then
        -- First run: nothing on disk yet, defaults already set.
        Core.state.settings_version = tonumber(reaper.GetExtState(Core.SCRIPT_ID, "settings_version")) or 0
        return
    end

    if data.visible_props then
        for _, p in ipairs(Core.PROPERTIES) do
            if data.visible_props[p.key] ~= nil then
                Core.state.visible_props[p.key] = data.visible_props[p.key] and true or false
            end
        end
    end

    if data.time_mode then Core.state.time_mode = tonumber(data.time_mode) or 1 end

    if data.prefs then
        local p = Core.state.prefs
        for k, v in pairs(data.prefs) do
            if p[k] ~= nil then  -- only known keys (forward-compat)
                if type(v) == "table" and type(p[k]) == "table" then
                    p[k][1], p[k][2], p[k][3], p[k][4] = v[1], v[2], v[3], v[4] or 1
                else
                    p[k] = v
                end
            end
        end
    end

    -- Sync our version stamp from ExtState (the disk file doesn't carry it)
    Core.state.settings_version = tonumber(reaper.GetExtState(Core.SCRIPT_ID, "settings_version")) or 0
end

-- Cheap polling: read the in-memory ExtState version stamp (zero disk I/O);
-- if it changed, re-read CP_Config/CP_Inspector.lua. Returns true on reload.
function Core.CheckForUpdates()
    local v = reaper.GetExtState(Core.SCRIPT_ID, "settings_version")
    if v == "" then return false end
    local n = tonumber(v) or 0
    if n ~= Core.state.settings_version then
        Core.LoadSettings()
        return true
    end
    return false
end

-- ============================================================================
-- ITEM DATA FETCHING
-- ============================================================================
function Core.RefreshSelection()
    local r = reaper
    local count = r.CountSelectedMediaItems(0)
    Core.state.item_count = count
    Core.state.selected_items = {}

    if count == 0 then
        Core.state.values = {}
        return
    end

    -- Fetch first item's properties (display values)
    local item = r.GetSelectedMediaItem(0, 0)
    if not item then return end

    local take = r.GetActiveTake(item)
    local values = {}

    -- Item properties
    values.position = r.GetMediaItemInfo_Value(item, "D_POSITION")
    values.length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    values.snap = r.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
    values.fadein = r.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    values.fadeout = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
    values.itemvol = r.GetMediaItemInfo_Value(item, "D_VOL")
    values.mute = r.GetMediaItemInfo_Value(item, "B_MUTE") == 1

    if take then
        values.name = ({ r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false) })[2] or ""
        values.takevol = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
        values.pitch = r.GetMediaItemTakeInfo_Value(take, "D_PITCH")
        values.preserve_pitch = r.GetMediaItemTakeInfo_Value(take, "B_PPITCH") == 1
        values.pan = r.GetMediaItemTakeInfo_Value(take, "D_PAN")
        values.rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

        -- Source info + original (unmodified) length for "modified" detection
        values._is_midi = r.TakeIsMIDI(take)
        local source = r.GetMediaItemTake_Source(take)
        if source then
            local filename = r.GetMediaSourceFileName(source)
            if filename and filename ~= "" then
                values._source_path = filename
                values.source = filename:match("[^/\\]+$") or filename
            else
                values._source_path = nil
                values.source = values._is_midi and "[MIDI]" or "[No source]"
            end

            local src_len, src_is_qn = r.GetMediaSourceLength(source)
            if src_is_qn then
                -- MIDI source: length is in quarter notes. Convert to seconds
                -- via project tempo at the item position, then divide by playrate.
                local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
                local end_qn = r.TimeMap2_timeToQN(0, pos) + src_len
                local end_time = r.TimeMap2_QNToTime(0, end_qn)
                values._source_length = (end_time - pos) / values.rate
            else
                values._source_length = src_len / values.rate
            end
        else
            values.source = "[No source]"
        end
    else
        values.name = "(no take)"
        values.source = ""
        values.takevol = 1
        values.pitch = 0
        values.preserve_pitch = true
        values.pan = 0
        values.rate = 1
        values._is_midi = false
    end

    Core.state.values = values
    Core.state.last_item = item

    -- Store all selected items for batch operations
    for i = 0, count - 1 do
        Core.state.selected_items[i + 1] = r.GetSelectedMediaItem(0, i)
    end
end

-- ============================================================================
-- VALUE FORMATTING
-- ============================================================================
function Core.FormatValue(key, value)
    local prop = Core.PROP_BY_KEY[key]
    if not prop then return tostring(value) end

    if prop.type == "text" then
        return tostring(value or "")

    elseif prop.type == "time" then
        return Core.FormatTime(value or 0)

    elseif prop.type == "db" then
        if not value or value <= 0 then return "-inf" end
        local db = 20 * math.log(value, 10)
        if math.abs(db) < 0.05 then return "+0.0 dB" end
        return string.format("%+.1f dB", db)

    elseif prop.type == "semi" then
        local v = value or 0
        if math.abs(v) < 0.005 then return "0 st" end
        return string.format("%+.1f st", v)

    elseif prop.type == "pan" then
        local v = value or 0
        if math.abs(v) < 0.005 then return "C" end
        local pct = math.floor(math.abs(v) * 100 + 0.5)
        return (v < 0 and "L" or "R") .. pct

    elseif prop.type == "rate" then
        return string.format("%.3fx", value or 1)

    elseif prop.type == "bool" then
        return value and "ON" or "OFF"
    end

    return tostring(value)
end

function Core.FormatTime(seconds)
    local mode = Core.TIME_MODES[Core.state.time_mode]
    if not mode then return string.format("%.3f", seconds) end

    if mode.key == "minsec" then
        local min = math.floor(seconds / 60)
        local sec = seconds - min * 60
        return string.format("%d:%06.3f", min, sec)

    elseif mode.key == "seconds" then
        return string.format("%.3f s", seconds)

    elseif mode.key == "beats" then
        local str = reaper.format_timestr_pos(seconds, "", 2)
        return str

    elseif mode.key == "samples" then
        local sr = 44100
        return string.format("%d", math.floor(seconds * sr))
    end
end

-- ============================================================================
-- VALUE COLOR CODING
--   Returns one of: "value_normal", "value_modified", "value_negative"
--   modified = changed from default (green)
--   negative = below baseline / OFF (pink)
-- ============================================================================
function Core.GetValueColorKey(key, value)
    local prop = Core.PROP_BY_KEY[key]
    if not prop then return "value_normal" end

    if prop.type == "db" then
        if not value or value <= 0 then return "value_negative" end
        local db = 20 * math.log(value, 10)
        if db < -0.05 then return "value_negative" end
        if db > 0.05 then return "value_modified" end
        return "value_normal"

    elseif prop.type == "semi" then
        local v = value or 0
        if v < -0.005 then return "value_negative" end
        if v > 0.005 then return "value_modified" end
        return "value_normal"

    elseif prop.type == "pan" then
        local v = value or 0
        if v < -0.005 then return "value_negative" end
        if v > 0.005 then return "value_modified" end
        return "value_normal"

    elseif prop.type == "rate" then
        local v = value or 1
        if v < 1 - 0.001 then return "value_negative" end
        if v > 1 + 0.001 then return "value_modified" end
        return "value_normal"

    elseif prop.type == "bool" then
        if key == "mute" then
            return value and "value_negative" or "value_normal"
        end
        return value and "value_modified" or "value_negative"

    elseif prop.type == "time" then
        if key == "snap" or key == "fadein" or key == "fadeout" then
            return (value or 0) > 0.001 and "value_modified" or "value_normal"

        elseif key == "length" then
            local src = Core.state.values._source_length
            if src and src > 0 and value then
                -- 0.5ms tolerance OR 0.1% of source, whichever is larger
                local tol = math.max(0.0005, src * 0.001)
                if value < src - tol then return "value_negative" end
                if value > src + tol then return "value_modified" end
            end
            return "value_normal"
        end
    end

    return "value_normal"
end

-- ============================================================================
-- TIME STRING ZONE METRICS (for intelligent zone-based drag/wheel)
--   Given a formatted time string and its on-screen x position, return
--   the x ranges for the major / minor / sub units.
--   For "minsec":  minutes | seconds | milliseconds
--   For "beats":   bars    | beats   | ticks
-- ============================================================================
function Core.GetTimeZones(str, text_x, measure_fn)
    local zones = {}
    local mode = Core.TIME_MODES[Core.state.time_mode]
    if not mode or not str then return zones end

    if mode.key == "beats" then
        local bars  = str:match("^(%d+)%.")
        local beats = str:match("%.(%d+)%.")
        local ticks = str:match("%.(%d+)$")
        if bars and beats and ticks then
            local bw = measure_fn(bars)
            local dw = measure_fn(".")
            local kw = measure_fn(beats)
            zones.bars_end  = text_x + bw
            zones.beats_end = zones.bars_end + dw + kw
            zones.ticks_end = text_x + measure_fn(str)
            zones.major = "bars"
            zones.mid   = "beats"
            zones.minor = "ticks"
        end
    else
        local minutes = str:match("^(%d+):")
        local seconds = str:match(":(%d+)%.")
        local ms      = str:match("%.(%d+)$")
        if minutes and seconds and ms then
            local mw = measure_fn(minutes)
            local cw = measure_fn(":")
            local sw = measure_fn(seconds)
            zones.bars_end  = text_x + mw
            zones.beats_end = zones.bars_end + cw + sw
            zones.ticks_end = text_x + measure_fn(str)
            zones.major = "minutes"
            zones.mid   = "seconds"
            zones.minor = "milliseconds"
        end
    end

    return zones
end

-- Returns "major" | "mid" | "minor" depending on which zone mouse_x falls into.
function Core.PickTimeZone(zones, mouse_x)
    if not zones.bars_end then return "mid" end
    if mouse_x < zones.bars_end  then return "major" end
    if mouse_x < zones.beats_end then return "mid"   end
    return "minor"
end

-- Returns the drag step (in seconds) for a given zone
function Core.GetTimeZoneStep(zone)
    local mode = Core.TIME_MODES[Core.state.time_mode]
    if not mode then return 0.01 end

    if mode.key == "beats" then
        local bpm, bpi = reaper.GetProjectTimeSignature2(0)
        local beat_len = 60.0 / bpm
        if zone == "major" then return bpi * beat_len end
        if zone == "mid"   then return beat_len end
        return beat_len / 960.0  -- ticks
    end

    if zone == "major" then return 60   end  -- minutes
    if zone == "mid"   then return 1    end  -- seconds
    return 0.001                              -- milliseconds
end

-- Returns the drag sensitivity (units-per-pixel) for a given zone.
function Core.GetTimeZoneDragSensitivity(zone)
    local mode = Core.TIME_MODES[Core.state.time_mode]
    if mode and mode.key == "beats" then
        if zone == "major" then return 0.10 end
        if zone == "mid"   then return 0.02 end
        return 0.002
    end
    if zone == "major" then return 0.6   end  -- minutes / pixel
    if zone == "mid"   then return 0.01  end  -- seconds / pixel
    return 0.001                                -- milliseconds / pixel
end

-- ============================================================================
-- VALUE INPUT DIALOG (double-click → GetUserInputs, ported from MPT)
--   Returns the new value, or nil if user cancelled.
-- ============================================================================
function Core.HandleValueInput(key, current_value)
    local r = reaper
    local prop = Core.PROP_BY_KEY[key]
    if not prop then return nil end

    -- Time fields
    if key == "position" or key == "length" or
       key == "fadein" or key == "fadeout" or key == "snap" then

        local mode = Core.TIME_MODES[Core.state.time_mode]
        if mode and mode.key == "beats" then
            local bpm, bpi = r.GetProjectTimeSignature2(0)
            local beat_len = 60.0 / bpm
            local total_beats = current_value / beat_len
            local bars = math.floor(total_beats / bpi)
            local beats = math.floor(total_beats % bpi)
            local ticks = math.floor((total_beats % 1) * 960)

            local ok, input = r.GetUserInputs(prop.label, 3,
                "Bars,Beats,Ticks",
                string.format("%d,%d,%d", bars + 1, beats + 1, ticks))
            if not ok then return nil end

            local nb, nbe, nt = input:match("([^,]+),([^,]+),([^,]+)")
            if nb and nbe and nt then
                nb  = math.max(0, (tonumber(nb)  or 1) - 1)
                nbe = math.max(0, (tonumber(nbe) or 1) - 1)
                nt  = tonumber(nt) or 0
                if nt < 0 then nt = 0 end
                if nt >= 960 then nt = 959 end
                local new_val = (nb * bpi + nbe + nt / 960.0) * beat_len
                if (key == "snap" or key == "fadein" or key == "fadeout") and new_val < 0 then
                    new_val = 0
                end
                return new_val
            end
            return nil
        else
            local m = math.floor(current_value / 60)
            local s = math.floor(current_value % 60)
            local ms = math.floor((current_value % 1) * 1000)

            local ok, input = r.GetUserInputs(prop.label, 3,
                "Minutes,Seconds,Milliseconds",
                string.format("%d,%d,%d", m, s, ms))
            if not ok then return nil end

            local nm, ns, nms = input:match("([^,]+),([^,]+),([^,]+)")
            if nm and ns and nms then
                nm  = tonumber(nm)  or 0
                ns  = tonumber(ns)  or 0
                nms = tonumber(nms) or 0
                local new_val = nm * 60 + ns + nms / 1000
                if (key == "snap" or key == "fadein" or key == "fadeout") and new_val < 0 then
                    new_val = 0
                end
                return new_val
            end
            return nil
        end

    elseif key == "itemvol" or key == "takevol" then
        local current_db = (current_value and current_value > 0)
            and 20 * math.log(current_value, 10) or -150
        local label = key == "itemvol" and "Item Volume (dB):" or "Take Volume (dB):"
        local ok, input = r.GetUserInputs(prop.label, 1, label, string.format("%.1f", current_db))
        if not ok then return nil end
        local new_db = tonumber(input)
        if new_db then
            if new_db < -150 then new_db = -150 end
            return 10 ^ (new_db / 20)
        end
        return nil

    elseif key == "pitch" then
        local ok, input = r.GetUserInputs(prop.label, 1,
            "Pitch (semitones):", string.format("%.2f", current_value or 0))
        if not ok then return nil end
        local v = tonumber(input)
        if v then
            if v < -96 then v = -96 end
            if v >  96 then v =  96 end
            return v
        end
        return nil

    elseif key == "pan" then
        local pan_pct = (current_value or 0) * 100
        local ok, input = r.GetUserInputs(prop.label, 1,
            "Pan (-100=L, 0=C, 100=R):", string.format("%.0f", pan_pct))
        if not ok then return nil end
        local v = tonumber(input)
        if v then
            if v < -100 then v = -100 end
            if v >  100 then v =  100 end
            return v / 100
        end
        return nil

    elseif key == "rate" then
        local ok, input = r.GetUserInputs(prop.label, 1,
            "Playback rate:", string.format("%.3f", current_value or 1))
        if not ok then return nil end
        local v = tonumber(input)
        if v then
            if v < 0.01 then v = 0.01 end
            if v >  40  then v =  40  end
            return v
        end
        return nil
    end

    return nil
end

-- ============================================================================
-- BATCH UPDATE
-- ============================================================================
function Core.UpdateProperty(key, value)
    local r = reaper
    r.Undo_BeginBlock()

    for _, item in ipairs(Core.state.selected_items) do
        local take = r.GetActiveTake(item)

        if key == "position" then
            r.SetMediaItemInfo_Value(item, "D_POSITION", value)
        elseif key == "length" then
            r.SetMediaItemInfo_Value(item, "D_LENGTH", value)
        elseif key == "snap" then
            r.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", value)
        elseif key == "fadein" then
            r.SetMediaItemInfo_Value(item, "D_FADEINLEN", value)
        elseif key == "fadeout" then
            r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", value)
        elseif key == "itemvol" then
            r.SetMediaItemInfo_Value(item, "D_VOL", value)
        elseif key == "mute" then
            r.SetMediaItemInfo_Value(item, "B_MUTE", value and 1 or 0)
        elseif take then
            if key == "takevol" then
                r.SetMediaItemTakeInfo_Value(take, "D_VOL", value)
            elseif key == "pitch" then
                r.SetMediaItemTakeInfo_Value(take, "D_PITCH", value)
            elseif key == "preserve_pitch" then
                r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", value and 1 or 0)
            elseif key == "pan" then
                r.SetMediaItemTakeInfo_Value(take, "D_PAN", value)
            elseif key == "rate" then
                r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", value)
            end
        end
    end

    r.UpdateArrange()
    r.Undo_EndBlock("CP Inspector: Edit " .. key, -1)
end

-- Update with relative offset (preserves differences between items)
function Core.UpdatePropertyOffset(key, offset)
    local r = reaper

    for _, item in ipairs(Core.state.selected_items) do
        local take = r.GetActiveTake(item)
        local current

        if key == "position" then
            current = r.GetMediaItemInfo_Value(item, "D_POSITION")
            r.SetMediaItemInfo_Value(item, "D_POSITION", math.max(0, current + offset))
        elseif key == "length" then
            current = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            r.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(0.001, current + offset))
        elseif key == "snap" then
            current = r.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
            r.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", math.max(0, current + offset))
        elseif key == "fadein" then
            current = r.GetMediaItemInfo_Value(item, "D_FADEINLEN")
            r.SetMediaItemInfo_Value(item, "D_FADEINLEN", math.max(0, current + offset))
        elseif key == "fadeout" then
            current = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
            r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", math.max(0, current + offset))
        elseif key == "itemvol" then
            current = r.GetMediaItemInfo_Value(item, "D_VOL")
            local db = 20 * math.log(math.max(0.00001, current), 10)
            db = db + offset
            r.SetMediaItemInfo_Value(item, "D_VOL", 10 ^ (db / 20))
        elseif take then
            if key == "takevol" then
                current = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
                local db = 20 * math.log(math.max(0.00001, current), 10)
                db = db + offset
                r.SetMediaItemTakeInfo_Value(take, "D_VOL", 10 ^ (db / 20))
            elseif key == "pitch" then
                current = r.GetMediaItemTakeInfo_Value(take, "D_PITCH")
                r.SetMediaItemTakeInfo_Value(take, "D_PITCH", math.max(-96, math.min(96, current + offset)))
            elseif key == "pan" then
                current = r.GetMediaItemTakeInfo_Value(take, "D_PAN")
                r.SetMediaItemTakeInfo_Value(take, "D_PAN", math.max(-1, math.min(1, current + offset)))
            elseif key == "rate" then
                current = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
                r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", math.max(0.01, math.min(40, current + offset)))
            end
        end
    end

    r.UpdateArrange()
end

return Core
