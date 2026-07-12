-- CP_Toolkit Log — Debug logging system
-- Toggle overlay: F12 key | Output to REAPER console: F11
-- Categories: MOUSE, WIDGET, LAYOUT, POPUP, STATE, CORE

local Log = {}

-- Load key codes
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local Keys = dofile(script_path .. "Keys.lua")

-- ============================================================================
-- CONFIG
-- ============================================================================
local config = {
    enabled = true,
    max_entries = 200,         -- ring buffer size
    overlay_lines = 24,        -- visible lines in overlay
    overlay_visible = false,
    console_output = false,    -- also print to REAPER console
    -- Category filters (true = shown)
    filters = {
        MOUSE  = false,  -- very verbose, off by default
        WIDGET = true,
        LAYOUT = true,
        POPUP  = true,
        STATE  = true,
        CORE   = true,
        USER   = true,   -- user-defined logs from scripts
    },
    -- Log level: 1=DEBUG, 2=INFO, 3=WARN, 4=ERROR
    min_level = 1,
}

local LEVELS = { "DEBUG", "INFO", "WARN", "ERROR" }
local LEVEL_COLORS = {
    DEBUG = { 0.5, 0.5, 0.5, 0.8 },
    INFO  = { 0.7, 0.8, 0.9, 0.9 },
    WARN  = { 1.0, 0.85, 0.3, 1.0 },
    ERROR = { 1.0, 0.3, 0.3, 1.0 },
}
local CAT_COLORS = {
    MOUSE  = { 0.5, 0.7, 0.5, 0.8 },
    WIDGET = { 0.6, 0.8, 1.0, 0.9 },
    LAYOUT = { 0.8, 0.7, 1.0, 0.9 },
    POPUP  = { 1.0, 0.7, 0.5, 0.9 },
    STATE  = { 0.7, 1.0, 0.7, 0.9 },
    CORE   = { 0.6, 0.6, 0.7, 0.8 },
    USER   = { 1.0, 1.0, 0.6, 0.9 },
}

-- ============================================================================
-- STORAGE
-- ============================================================================
local entries = {}
local entry_count = 0
local scroll_offset = 0
local current_frame = 0
local last_state_snapshot = ""

-- Frame-scoped event tracking (reset each frame)
local frame_events = {
    widgets_drawn = 0,
    widgets_hovered = {},
    widgets_clicked = {},
    popups_opened = {},
    popups_closed = {},
    containers_pushed = 0,
    containers_popped = 0,
}

-- ============================================================================
-- CORE LOGGING
-- ============================================================================
local function add_entry(level, category, message, details)
    if not config.enabled then return end
    if level < config.min_level then return end
    if not config.filters[category] then return end

    entry_count = entry_count + 1
    local idx = ((entry_count - 1) % config.max_entries) + 1

    entries[idx] = {
        frame = current_frame,
        time = reaper.time_precise(),
        level = LEVELS[level] or "INFO",
        category = category,
        message = message,
        details = details,
    }

    if config.console_output then
        local prefix = string.format("[F%d][%s][%s] ", current_frame, category, LEVELS[level] or "?")
        reaper.ShowConsoleMsg(prefix .. message .. (details and (" | " .. details) or "") .. "\n")
    end
end

-- Public logging functions
function Log.Debug(category, msg, details) add_entry(1, category, msg, details) end
function Log.Info(category, msg, details)  add_entry(2, category, msg, details) end
function Log.Warn(category, msg, details)  add_entry(3, category, msg, details) end
function Log.Error(category, msg, details) add_entry(4, category, msg, details) end

-- Convenience shortcuts
function Log.Widget(msg, details) add_entry(1, "WIDGET", msg, details) end
function Log.Mouse(msg, details)  add_entry(1, "MOUSE", msg, details) end
function Log.Popup(msg, details)  add_entry(2, "POPUP", msg, details) end
function Log.Layout(msg, details) add_entry(1, "LAYOUT", msg, details) end
function Log.State(msg, details)  add_entry(2, "STATE", msg, details) end
function Log.User(msg, details)   add_entry(2, "USER", msg, details) end

-- ============================================================================
-- FRAME TRACKING (called by Core each frame)
-- ============================================================================
function Log.BeginFrame(frame, state)
    current_frame = frame

    -- Reset frame events
    frame_events.widgets_drawn = 0
    frame_events.widgets_hovered = {}
    frame_events.widgets_clicked = {}
    frame_events.popups_opened = {}
    frame_events.popups_closed = {}
    frame_events.containers_pushed = 0
    frame_events.containers_popped = 0

    -- Log mouse state changes
    if config.filters.MOUSE then
        if state.mouse_cap ~= state.prev_mouse_cap then
            local btns = {}
            if (state.mouse_cap & 1) ~= 0 then btns[#btns+1] = "LEFT" end
            if (state.mouse_cap & 2) ~= 0 then btns[#btns+1] = "RIGHT" end
            if (state.mouse_cap & 64) ~= 0 then btns[#btns+1] = "MIDDLE" end
            if (state.mouse_cap & 4) ~= 0 then btns[#btns+1] = "CTRL" end
            if (state.mouse_cap & 8) ~= 0 then btns[#btns+1] = "SHIFT" end
            if (state.mouse_cap & 16) ~= 0 then btns[#btns+1] = "ALT" end
            local msg = #btns > 0 and table.concat(btns, "+") or "RELEASED"
            Log.Mouse("mouse_cap: " .. msg,
                string.format("pos=(%d,%d) prev_cap=%d cap=%d",
                    state.mouse_x, state.mouse_y,
                    state.prev_mouse_cap, state.mouse_cap))
        end

        if state.mouse_wheel ~= 0 then
            Log.Mouse("wheel: " .. state.mouse_wheel,
                string.format("pos=(%d,%d)", state.mouse_x, state.mouse_y))
        end
    end
end

function Log.EndFrame(state)
    -- Log state summary if it changed
    local snapshot = string.format("hot=%s active=%s focus=%s popup=%s",
        tostring(state.hot), tostring(state.active),
        tostring(state.focus), tostring(state.popup_layer and state.popup_layer.id or "nil"))

    if snapshot ~= last_state_snapshot then
        Log.State("state changed", snapshot)
        last_state_snapshot = snapshot
    end
end

-- ============================================================================
-- WIDGET EVENT LOGGING (called by widgets)
-- ============================================================================
function Log.WidgetHovered(id, widget_type)
    frame_events.widgets_hovered[id] = widget_type or "unknown"
    Log.Debug("WIDGET", widget_type .. " hovered: " .. id)
end

function Log.WidgetClicked(id, widget_type, details)
    frame_events.widgets_clicked[id] = widget_type or "unknown"
    Log.Info("WIDGET", widget_type .. " CLICKED: " .. id, details)
end

function Log.WidgetChanged(id, widget_type, old_val, new_val)
    Log.Info("WIDGET", widget_type .. " changed: " .. id,
        "old=" .. tostring(old_val) .. " new=" .. tostring(new_val))
end

function Log.WidgetActive(id, widget_type)
    Log.Debug("WIDGET", widget_type .. " active: " .. id)
end

function Log.PopupOpened(id, details)
    frame_events.popups_opened[id] = true
    Log.Info("POPUP", "OPENED: " .. id, details)
end

function Log.PopupClosed(id, reason)
    frame_events.popups_closed[id] = true
    Log.Info("POPUP", "CLOSED: " .. id, "reason=" .. (reason or "unknown"))
end

function Log.ContainerPush(id, x, y, w, h)
    frame_events.containers_pushed = frame_events.containers_pushed + 1
    Log.Debug("LAYOUT", "push container: " .. id,
        string.format("rect=(%d,%d,%d,%d)", x, y, w, h))
end

function Log.ContainerPop(id)
    frame_events.containers_popped = frame_events.containers_popped + 1
    Log.Debug("LAYOUT", "pop container: " .. (id or "?"))
end

function Log.CursorAdvance(container_id, widget_w, widget_h, new_cx, new_cy, same_line)
    Log.Debug("LAYOUT", "cursor advance in " .. container_id,
        string.format("widget=(%d,%d) new_cursor=(%d,%d) sameline=%s",
            widget_w, widget_h, new_cx, new_cy, tostring(same_line)))
end

-- ============================================================================
-- STATS SOURCE (set by Core)
-- ============================================================================
local stats_source = nil  -- function returning the stats table

function Log.SetStatsSource(fn)
    stats_source = fn
end

-- ============================================================================
-- OVERLAY RENDERING
-- ============================================================================
-- Dedicated font slot for the overlay (audit B5c: the overlay used to
-- redefine slot 1 — the theme's Title font — corrupting titles and the
-- measure cache while it was open: the instrumentation was skewing the very
-- state it measures). Restored via the hook at the end of DrawOverlay.
local LOG_FONT_SLOT = 16
local _log_font_size = -1
local _restore_font = nil

function Log.SetFontRestorer(fn)
    _restore_font = fn
end

local function log_font(px)
    if px ~= _log_font_size then
        gfx.setfont(LOG_FONT_SLOT, "Consolas", px, 0)
        _log_font_size = px
    else
        gfx.setfont(LOG_FONT_SLOT)
    end
end

function Log.DrawOverlay()
    if not config.overlay_visible then return end

    local w, h = gfx.w, gfx.h
    local line_h = 14
    local stats_h = stats_source and 18 or 0
    local panel_h = config.overlay_lines * line_h + 30 + stats_h
    local panel_y = h - panel_h
    local pad = 6

    -- Background
    gfx.set(0.05, 0.05, 0.08, 0.92)
    gfx.rect(0, panel_y, w, panel_h, 1)

    -- Title bar
    gfx.set(0.15, 0.15, 0.2, 1)
    gfx.rect(0, panel_y, w, 18, 1)
    log_font(12)
    gfx.set(0.8, 0.9, 1.0, 1)
    gfx.x, gfx.y = pad, panel_y + 2
    local title = string.format("LOG [F12:toggle F11:console F1,F2,F4-F8:filters] Frame:%d Entries:%d",
        current_frame, math.min(entry_count, config.max_entries))
    gfx.drawstr(title)

    -- Stats line (frame timing, allocations, draw calls, idle mode)
    if stats_source then
        local s = stats_source()
        local stats_y = panel_y + 18
        gfx.set(0.08, 0.08, 0.12, 1)
        gfx.rect(0, stats_y, w, stats_h, 1)
        log_font(11)

        -- Mode indicator (active = green, idle = dim blue)
        if s.mode == "idle" then
            gfx.set(0.4, 0.6, 0.9, 1)
        else
            gfx.set(0.4, 0.9, 0.5, 1)
        end
        gfx.x, gfx.y = pad, stats_y + 3
        gfx.drawstr(string.format("[%s]", s.mode:upper()))

        -- Frame ms (color-coded: green<2 yellow<5 red>=5)
        local ms = s.frame_ms_avg or 0
        if ms < 2 then gfx.set(0.5, 0.9, 0.5, 1)
        elseif ms < 5 then gfx.set(0.95, 0.85, 0.3, 1)
        else gfx.set(1.0, 0.4, 0.4, 1) end
        gfx.x = pad + 70
        gfx.drawstr(string.format("frame: %.2fms (peak %.2f)", ms, s.frame_ms_peak or 0))

        -- Alloc KB (color-coded: green=0 yellow<5 red>=5)
        local kb = s.alloc_kb_avg or 0
        if kb < 0.5 then gfx.set(0.5, 0.9, 0.5, 1)
        elseif kb < 5 then gfx.set(0.95, 0.85, 0.3, 1)
        else gfx.set(1.0, 0.4, 0.4, 1) end
        gfx.x = pad + 280
        gfx.drawstr(string.format("alloc: %.1f KB/f", kb))

        -- Draw count
        gfx.set(0.7, 0.8, 0.9, 1)
        gfx.x = pad + 410
        gfx.drawstr(string.format("draws: %d", math.floor(s.draws_avg or 0)))

        -- Idle skip count (visible benefit indicator)
        if s.mode == "idle" and (s.idle_skips or 0) > 0 then
            gfx.set(0.5, 0.7, 0.9, 0.8)
            gfx.x = pad + 520
            gfx.drawstr(string.format("skipped: %d", s.idle_skips))
        end
    end

    -- Filter indicators
    local fx = w - 300
    for cat, enabled in pairs(config.filters) do
        local c = CAT_COLORS[cat] or {0.5,0.5,0.5,1}
        if enabled then
            gfx.set(c[1], c[2], c[3], c[4])
        else
            gfx.set(0.3, 0.3, 0.3, 0.5)
        end
        gfx.x, gfx.y = fx, panel_y + 2
        gfx.drawstr(cat:sub(1,3) .. " ")
        fx = fx + 35
    end

    -- Entries
    log_font(11)
    local total = math.min(entry_count, config.max_entries)
    local start_idx = math.max(1, total - config.overlay_lines - scroll_offset + 1)
    local end_idx = math.min(total, start_idx + config.overlay_lines - 1)

    local entries_top = panel_y + 22 + stats_h
    local draw_y = entries_top
    for i = start_idx, end_idx do
        local real_idx = ((entry_count - total + i - 1) % config.max_entries) + 1
        local e = entries[real_idx]
        if e then
            -- Frame number
            gfx.set(0.4, 0.4, 0.4, 0.7)
            gfx.x, gfx.y = pad, draw_y
            gfx.drawstr(string.format("F%-5d ", e.frame))

            -- Level
            local lc = LEVEL_COLORS[e.level] or {0.5,0.5,0.5,1}
            gfx.set(lc[1], lc[2], lc[3], lc[4])
            gfx.drawstr(string.format("%-5s ", e.level))

            -- Category
            local cc = CAT_COLORS[e.category] or {0.5,0.5,0.5,1}
            gfx.set(cc[1], cc[2], cc[3], cc[4])
            gfx.drawstr(string.format("%-7s ", e.category))

            -- Message
            gfx.set(0.85, 0.85, 0.85, 0.95)
            local msg = e.message
            if e.details then
                msg = msg .. "  |  " .. e.details
            end
            -- Truncate to fit
            local max_chars = math.floor((w - 200) / 7)
            if #msg > max_chars then msg = msg:sub(1, max_chars) .. "..." end
            gfx.drawstr(msg)

            draw_y = draw_y + line_h
        end
    end

    -- Scroll indicator
    if total > config.overlay_lines then
        local bar_h = panel_h - 22 - stats_h
        local ratio = config.overlay_lines / total
        local thumb_h = math.max(10, bar_h * ratio)
        local scroll_max = total - config.overlay_lines
        local scroll_ratio = scroll_max > 0 and (scroll_offset / scroll_max) or 0
        local thumb_y = entries_top + (bar_h - thumb_h) * (1 - scroll_ratio)

        gfx.set(0.3, 0.3, 0.4, 0.5)
        gfx.rect(w - 6, entries_top, 4, bar_h, 1)
        gfx.set(0.6, 0.6, 0.8, 0.7)
        gfx.rect(w - 6, thumb_y, 4, thumb_h, 1)
    end

    -- Restore the font Core believes is current (see LOG_FONT_SLOT note)
    if _restore_font then _restore_font() end
end

-- ============================================================================
-- INPUT HANDLING (called each frame)
-- ============================================================================
function Log.HandleInput(char, mouse_wheel, mouse_y)
    -- F12 = toggle overlay
    if char == Keys.F12 then
        config.overlay_visible = not config.overlay_visible
        Log.Info("CORE", "Log overlay " .. (config.overlay_visible and "ON" or "OFF"))
    end

    -- F11 = toggle console output
    if char == Keys.F11 then
        config.console_output = not config.console_output
        Log.Info("CORE", "Console output " .. (config.console_output and "ON" or "OFF"))
        if config.console_output then
            reaper.ShowConsoleMsg("=== CP_Toolkit Log — Console output enabled ===\n")
        end
    end

    -- F1-F7 = toggle category filters
    local filter_keys = {
        [Keys.F1] = "MOUSE",  [Keys.F2] = "WIDGET", [Keys.F4] = "LAYOUT",
        [Keys.F5] = "POPUP",  [Keys.F6] = "STATE",  [Keys.F7] = "CORE",
        [Keys.F8] = "USER",
    }
    -- F3 skipped (intercepted by REAPER)
    if filter_keys[char] then
        local cat = filter_keys[char]
        config.filters[cat] = not config.filters[cat]
        Log.Info("CORE", cat .. " filter " .. (config.filters[cat] and "ON" or "OFF"))
    end

    -- Scroll log overlay with mouse wheel when overlay is visible
    if config.overlay_visible then
        local win_h = gfx.h
        local panel_h = config.overlay_lines * 14 + 30
        if mouse_y > win_h - panel_h and mouse_wheel ~= 0 then
            local total = math.min(entry_count, config.max_entries)
            local max_scroll = math.max(0, total - config.overlay_lines)
            scroll_offset = scroll_offset + (mouse_wheel > 0 and 3 or -3)
            scroll_offset = math.max(0, math.min(scroll_offset, max_scroll))
        end
    end
end

-- ============================================================================
-- CONFIG ACCESS
-- ============================================================================
function Log.IsOverlayVisible() return config.overlay_visible end
function Log.SetOverlayVisible(v) config.overlay_visible = v end
function Log.SetConsoleOutput(v) config.console_output = v end
function Log.SetFilter(category, enabled) config.filters[category] = enabled end
function Log.SetMinLevel(level) config.min_level = level end
function Log.GetConfig() return config end
function Log.GetFrameEvents() return frame_events end

function Log.Clear()
    entries = {}
    entry_count = 0
    scroll_offset = 0
    Log.Info("CORE", "Log cleared")
end

-- Dump all entries to REAPER console
function Log.DumpToConsole()
    reaper.ShowConsoleMsg("\n=== CP_Toolkit Log Dump (" .. math.min(entry_count, config.max_entries) .. " entries) ===\n")
    local total = math.min(entry_count, config.max_entries)
    for i = 1, total do
        local real_idx = ((entry_count - total + i - 1) % config.max_entries) + 1
        local e = entries[real_idx]
        if e then
            reaper.ShowConsoleMsg(string.format("[F%d][%s][%s] %s%s\n",
                e.frame, e.category, e.level, e.message,
                e.details and (" | " .. e.details) or ""))
        end
    end
    reaper.ShowConsoleMsg("=== End Dump ===\n")
end

return Log
