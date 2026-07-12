-- CP_Toolkit Core — Immediate-mode UI on REAPER gfx.*
-- Boucle principale, état souris/clavier, système d'IDs, hit-testing

-- Localize math lib — avoids table lookup per call on hot paths.
local floor, min, max, abs, ceil = math.floor, math.min, math.max, math.abs, math.ceil

local Core = {}
local Log   -- set via Core.SetLog()

function Core.SetLog(log_module)
    Log = log_module
end

-- ============================================================================
-- STATE
-- ============================================================================
local state = {
    -- Window
    win_w = 0,
    win_h = 0,
    dock = 0,

    -- Mouse (current frame)
    mouse_x = 0,
    mouse_y = 0,
    mouse_cap = 0,
    mouse_wheel = 0,
    mouse_hwheel = 0,

    -- Mouse (previous frame)
    prev_mouse_x = 0,
    prev_mouse_y = 0,
    prev_mouse_cap = 0,

    -- Keyboard
    char = 0,
    char_consumed = false,  -- set by widgets that handled this frame's key

    -- Widget state
    hot = nil,        -- widget under mouse (hover)
    active = nil,     -- widget being interacted with (click/drag)
    focus = nil,      -- widget with keyboard focus

    -- Frame tracking
    frame = 0,

    -- Layout cursor (managed by Layout.lua but stored here)
    cursor_x = 0,
    cursor_y = 0,

    -- Container stack (used by Layout.lua)
    container_stack = {},

    -- Combo/popup layer (drawn last, on top)
    popup_layer = nil,  -- {draw_fn, id}
    popup_open_frame = 0, -- frame when popup was opened (to skip same-frame close)

    -- Wheel consumed flag (child regions set this to prevent parent scroll)
    wheel_consumed = false,
    hwheel_consumed = false,

    -- Modal input blocking (see Core.EnterModalScope)
    _in_modal = false,
    _modal_frame = -1000,

    -- Persistent widget data (scroll offsets, combo open states, etc.)
    widget_data = {},

    -- Animation pending flag (set by Core.Animate when value still moving)
    _has_active_animation = false,

    -- Explicit redraw request (set via Core.RequestRedraw)
    _request_redraw = false,
}

-- ============================================================================
-- PERFORMANCE STATS (instrumentation — see PERFORMANCE.md)
-- ============================================================================
-- Lightweight measurement of frame cost. Always on. Cost: ~6 microseconds/frame.
local SAMPLE_COUNT = 60
local _stats = {
    -- Per-frame measurements (last full frame)
    frame_ms = 0,         -- last frame duration in ms
    alloc_kb = 0,         -- KB allocated by Lua during last frame
    draws_per_frame = 0,  -- gfx draw calls in last frame

    -- Moving averages (over SAMPLE_COUNT samples)
    frame_ms_avg = 0,
    frame_ms_peak = 0,
    alloc_kb_avg = 0,
    draws_avg = 0,

    -- Mode tracking
    mode = "active",      -- "active" or "idle"
    idle_skips = 0,       -- frames skipped since last full frame

    -- Internal: ring buffers for moving avg
    _samples_ms = {},
    _samples_kb = {},
    _samples_draws = {},
    _sample_idx = 0,
    _draw_count = 0,      -- counter incremented by draw wrappers
}

-- Push a sample into the ring buffer and update moving averages.
-- Incremental sums (subtract outgoing, add incoming) instead of rescanning
-- the 3×60 ring buffers every frame; the peak is only rescanned on the rare
-- frame where the outgoing sample *was* the peak.
local _sum_ms, _sum_kb, _sum_draws, _sample_n = 0, 0, 0, 0
local function _push_sample(ms, kb, draws)
    local idx = (_stats._sample_idx % SAMPLE_COUNT) + 1
    _stats._sample_idx = idx

    local old_ms = _stats._samples_ms[idx]
    if old_ms then
        _sum_ms = _sum_ms - old_ms
        _sum_kb = _sum_kb - (_stats._samples_kb[idx] or 0)
        _sum_draws = _sum_draws - (_stats._samples_draws[idx] or 0)
    else
        _sample_n = _sample_n + 1
    end

    _stats._samples_ms[idx] = ms
    _stats._samples_kb[idx] = kb
    _stats._samples_draws[idx] = draws
    _sum_ms = _sum_ms + ms
    _sum_kb = _sum_kb + kb
    _sum_draws = _sum_draws + draws

    if ms >= _stats.frame_ms_peak then
        _stats.frame_ms_peak = ms
    elseif old_ms and old_ms >= _stats.frame_ms_peak then
        -- The evicted sample held the peak — rescan once.
        local peak = 0
        for i = 1, SAMPLE_COUNT do
            local v = _stats._samples_ms[i]
            if v and v > peak then peak = v end
        end
        _stats.frame_ms_peak = peak
    end

    _stats.frame_ms_avg = _sum_ms / _sample_n
    _stats.alloc_kb_avg = _sum_kb / _sample_n
    _stats.draws_avg = _sum_draws / _sample_n
end

function Core.GetStats()
    return _stats
end

-- Mark the next frame as needing a full redraw (escapes idle mode).
-- Use this when displaying live external data (REAPER playback, FX values, etc.).
function Core.RequestRedraw()
    state._request_redraw = true
end

-- Schedule a full redraw at (or shortly after) an absolute time_precise()
-- deadline — egui-style request_repaint_after. Cheaper than blocking idle:
-- the loop keeps skipping frames until the deadline passes, then runs one
-- full frame. Callers re-arm each frame they still need future redraws
-- (caret blink, tooltip show delay, timed fades).
local _next_redraw_at = nil
function Core.RequestRedrawAt(t)
    if _next_redraw_at == nil or t < _next_redraw_at then
        _next_redraw_at = t
    end
end

-- Caret blink shared timing (used by text widgets + idle scheduling).
-- A focused text widget calls Core.ScheduleBlinkRedraw(blink_start) each
-- frame it is drawn so the idle loop wakes exactly at the next blink edge
-- instead of running full frames continuously.
Core.BLINK_PERIOD = 1.0
Core.BLINK_ON = 0.55
function Core.ScheduleBlinkRedraw(blink_start)
    local now = reaper.time_precise()
    local phase = (now - blink_start) % Core.BLINK_PERIOD
    local wait
    if phase < Core.BLINK_ON then
        wait = Core.BLINK_ON - phase
    else
        wait = Core.BLINK_PERIOD - phase
    end
    Core.RequestRedrawAt(now + wait)
end

-- Globally enable/disable the idle throttle. Default: enabled.
-- Disable this when the script is fundamentally always-active (live meters,
-- waveform displays, etc.) and per-frame RequestRedraw would be tedious.
local _idle_throttle_enabled = true
function Core.SetIdleThrottle(enabled)
    _idle_throttle_enabled = enabled ~= false
end
function Core.IsIdleThrottleEnabled()
    return _idle_throttle_enabled
end

-- ============================================================================
-- MOUSE HELPERS
-- ============================================================================
function Core.MouseDown(button)
    button = button or 1  -- 1=left, 2=right, 64=middle
    return (state.mouse_cap & button) ~= 0
end

function Core.MouseClicked(button)
    button = button or 1
    return (state.mouse_cap & button) ~= 0 and (state.prev_mouse_cap & button) == 0
end

function Core.MouseReleased(button)
    button = button or 1
    return (state.mouse_cap & button) == 0 and (state.prev_mouse_cap & button) ~= 0
end

function Core.MouseDoubleClicked()
    -- gfx.mouse_cap bit 32 = double-click (REAPER specific)
    -- Actually REAPER doesn't provide double-click via mouse_cap.
    -- We track it manually.
    return state._dbl_click
end

function Core.MouseInRect(x, y, w, h)
    -- Modal blocking: while a modal was open this frame or the previous one,
    -- everything outside the modal scope fails hit-tests. Widgets drawn
    -- before BeginModal in the frame are covered by the previous-frame flag.
    if not state._in_modal and state.frame - state._modal_frame <= 1 then
        return false
    end
    return state.mouse_x >= x and state.mouse_x < x + w
       and state.mouse_y >= y and state.mouse_y < y + h
end

function Core.MouseDelta()
    return state.mouse_x - state.prev_mouse_x, state.mouse_y - state.prev_mouse_y
end

-- Modifier keys (from mouse_cap)
function Core.ModCtrl()  return (state.mouse_cap & 4) ~= 0 end
function Core.ModShift() return (state.mouse_cap & 8) ~= 0 end
function Core.ModAlt()   return (state.mouse_cap & 16) ~= 0 end

-- ============================================================================
-- WIDGET STATE (hot/active/focus)
-- ============================================================================
function Core.SetHot(id)
    if state.active == nil or state.active == id then
        state.hot = id
    end
end

function Core.SetActive(id)
    state.active = id
end

function Core.ClearActive()
    state.active = nil
end

function Core.SetFocus(id)
    state.focus = id
end

function Core.IsHot(id)     return state.hot == id end
function Core.IsActive(id)  return state.active == id end
function Core.IsFocused(id) return state.focus == id end

-- ============================================================================
-- LAST ITEM RECT (ImGui-style IsItemHovered family — F7)
-- ============================================================================
-- Recorded by Layout.AdvanceCursor for every submitted widget: 4 plain
-- number writes, no allocation. Query right AFTER the widget call — the
-- active clip rect is still the widget's own at that point.
local _item_x, _item_y, _item_w, _item_h = 0, 0, 0, 0

function Core.SetLastItemRect(x, y, w, h)
    _item_x, _item_y, _item_w, _item_h = x, y, w, h
end

function Core.GetLastItemRect()
    return _item_x, _item_y, _item_w, _item_h
end

function Core.IsItemHovered()
    return _item_w > 0 and Core.MouseInClippedRect(_item_x, _item_y, _item_w, _item_h)
end

function Core.IsItemClicked(button)
    return Core.IsItemHovered() and Core.MouseClicked(button or 1)
end

function Core.IsItemRightClicked()
    return Core.IsItemHovered() and Core.MouseClicked(2)
end

function Core.IsItemDoubleClicked()
    return Core.IsItemHovered() and Core.MouseDoubleClicked()
end

-- ============================================================================
-- DISABLED SCOPE (ImGui-style BeginDisabled/EndDisabled)
-- ============================================================================
-- Widgets consult Core.IsDisabled() at the top of their body: when true they
-- skip all interaction and draw with theme.colors.text_disabled. Scopes nest;
-- BeginDisabled(false) pushes a transparent level so call sites can stay
-- unconditional. Both counters are reset at the start of each frame so an
-- unbalanced Begin/End can never leak across frames.
local _disabled_stack = {}
local _disabled_top = 0
local _disabled_active = 0

function Core.BeginDisabled(disabled)
    disabled = disabled ~= false
    _disabled_top = _disabled_top + 1
    _disabled_stack[_disabled_top] = disabled
    if disabled then _disabled_active = _disabled_active + 1 end
end

function Core.EndDisabled()
    if _disabled_top > 0 then
        if _disabled_stack[_disabled_top] then
            _disabled_active = _disabled_active - 1
        end
        _disabled_top = _disabled_top - 1
    end
end

function Core.IsDisabled()
    return _disabled_active > 0
end

local function _reset_disabled_scope()
    _disabled_top = 0
    _disabled_active = 0
end

-- ============================================================================
-- MODAL SCOPE (input blocking behind BeginModal/EndModal)
-- ============================================================================
-- Inline modals can't retroactively block widgets that already ran earlier in
-- the same frame, so blocking spans this frame AND the next: MouseInRect /
-- MouseInClippedRect fail everywhere outside the modal scope while
-- state.frame - state._modal_frame <= 1.
function Core.EnterModalScope()
    state._in_modal = true
    state._modal_frame = state.frame
end

function Core.LeaveModalScope()
    state._in_modal = false
end

-- ============================================================================
-- PERSISTENT WIDGET DATA
-- ============================================================================
function Core.GetWidgetData(id, default)
    if state.widget_data[id] == nil then
        state.widget_data[id] = default or {}
    end
    return state.widget_data[id]
end

function Core.SetWidgetData(id, data)
    state.widget_data[id] = data
end

-- Sub-table accessor: avoids "prefix_"..id string concat in widget hot paths.
-- Each widget category gets its own sub-table, indexed by raw id.
-- Always returns a table (creates an empty one on first access).
--
-- Entries are frame-stamped (parallel table, so widget data stays clean) and
-- swept periodically: an id not requested for WD_TTL_FRAMES active frames is
-- dropped — otherwise dynamic ids (one per FX in a browser list, per search
-- result…) grow widget_data monotonically for the whole session (microui's
-- "forgetful pool" pattern). Legacy flat Core.GetWidgetData ids are NOT swept.
local _wd_stamp = {}   -- [category] = { [id] = last frame requested }

function Core.GetWidgetSubData(category, id)
    local map = state.widget_data[category]
    if not map then
        map = {}
        state.widget_data[category] = map
        _wd_stamp[category] = {}
    end
    local d = map[id]
    if not d then
        d = {}
        map[id] = d
    end
    _wd_stamp[category][id] = state.frame
    return d
end

-- Explicitly drop a widget's persistent data (dynamic views can call this
-- when an item is removed instead of waiting for the sweep).
function Core.FreeWidgetSubData(category, id)
    local map = state.widget_data[category]
    if map then map[id] = nil end
    local st = _wd_stamp[category]
    if st then st[id] = nil end
end

-- ============================================================================
-- POPUP LAYER
-- ============================================================================
function Core.SetPopup(id, draw_fn)
    state.popup_layer = { id = id, draw = draw_fn }
    state.popup_open_frame = state.frame
    if Log then Log.PopupOpened(id, "frame=" .. state.frame) end
end

function Core.ClearPopup(id)
    if state.popup_layer and (id == nil or state.popup_layer.id == id) then
        if Log then Log.PopupClosed(state.popup_layer.id, id and "explicit" or "any") end
        state.popup_layer = nil
    end
end

function Core.HasPopup(id)
    if id then
        return state.popup_layer ~= nil and state.popup_layer.id == id
    end
    return state.popup_layer ~= nil
end

-- Returns true if popup was opened THIS frame (to skip same-frame close)
function Core.IsPopupNewThisFrame()
    return state.popup_layer ~= nil and state.popup_open_frame == state.frame
end

-- ============================================================================
-- TOOLTIP LAYER (drawn last, on top of everything including popups)
-- ============================================================================
function Core.SetTooltip(draw_fn)
    state.tooltip_layer = draw_fn
end

function Core.ClearTooltip()
    state.tooltip_layer = nil
end

-- ============================================================================
-- DRAWING HELPERS (thin wrappers for readability)
-- ============================================================================
-- Note: each wrapper increments _stats._draw_count. Cost is one local table
-- write per call, ~10ns. Always on (cheap enough not to gate behind a flag).
--
-- Clip stack (defined here so the draw helpers below can read it). The
-- corresponding Push/Pop functions live further down with the rest of the
-- public layout API; they all operate on these same arrays.
local clip_x = {}
local clip_y = {}
local clip_w = {}
local clip_h = {}
local clip_top = 0

-- Clamp (x, y, w, h) to the active clip rect. Returns the visible portion
-- or nil if fully outside the clip. Called by primitive Draw* helpers so
-- that scroll containers can hide content that extends past their edges.
local function _clip_rect(x, y, w, h)
    if clip_top == 0 then return x, y, w, h end
    local cx, cy, cw, ch = clip_x[clip_top], clip_y[clip_top],
                           clip_w[clip_top], clip_h[clip_top]
    local x2 = x + w
    local y2 = y + h
    local cx2 = cx + cw
    local cy2 = cy + ch
    if x >= cx2 or y >= cy2 or x2 <= cx or y2 <= cy then return nil end
    if x < cx then x = cx end
    if y < cy then y = cy end
    if x2 > cx2 then x2 = cx2 end
    if y2 > cy2 then y2 = cy2 end
    return x, y, x2 - x, y2 - y
end

function Core.DrawRect(x, y, w, h, r, g, b, a, filled)
    _stats._draw_count = _stats._draw_count + 1
    if filled ~= false then
        local cx, cy, cw, ch = _clip_rect(x, y, w, h)
        if not cx then return end
        gfx.set(r, g, b, a or 1)
        gfx.rect(cx, cy, cw, ch, 1)
    else
        -- Outline rectangles can't be uniformly clipped (corners would be
        -- cropped weirdly). Skip the rect entirely if its bounding box is
        -- fully outside the clip; otherwise let it draw — gfx itself will
        -- still respect the rect's coordinates.
        if clip_top > 0 then
            local cx = clip_x[clip_top]; local cy = clip_y[clip_top]
            if x + w <= cx or y + h <= cy
               or x >= cx + clip_w[clip_top]
               or y >= cy + clip_h[clip_top] then return end
        end
        gfx.set(r, g, b, a or 1)
        gfx.rect(x, y, w, h, 0)
    end
end

-- Cohen–Sutherland outcode. Module-level on purpose: declaring this as a
-- closure inside _clip_line allocated one function (plus captured upvalues)
-- per clipped DrawLine — and the root clip pushed by Layout.Begin means the
-- clip is active for every line of every frame (zero-alloc rule violation).
local function _cs_outcode(x, y, cx, cy, cx2, cy2)
    local c = 0
    if x < cx  then c = c | 1
    elseif x > cx2 then c = c | 2 end
    if y < cy  then c = c | 4
    elseif y > cy2 then c = c | 8 end
    return c
end

-- Cohen–Sutherland line clipping against the active clip rect. Modifies
-- the endpoints in place so the line is fully inside the rect (or returns
-- nil when the line is fully outside).
local function _clip_line(x1, y1, x2, y2)
    if clip_top == 0 then return x1, y1, x2, y2 end
    local cx = clip_x[clip_top]
    local cy = clip_y[clip_top]
    local cx2 = cx + clip_w[clip_top]
    local cy2 = cy + clip_h[clip_top]

    local c1 = _cs_outcode(x1, y1, cx, cy, cx2, cy2)
    local c2 = _cs_outcode(x2, y2, cx, cy, cx2, cy2)
    while true do
        if (c1 | c2) == 0 then return x1, y1, x2, y2 end          -- inside
        if (c1 & c2) ~= 0 then return nil end                       -- outside
        local cout = (c1 ~= 0) and c1 or c2
        local x, y
        if (cout & 8) ~= 0 then        -- bottom
            x = x1 + (x2 - x1) * (cy2 - y1) / (y2 - y1)
            y = cy2
        elseif (cout & 4) ~= 0 then    -- top
            x = x1 + (x2 - x1) * (cy - y1) / (y2 - y1)
            y = cy
        elseif (cout & 2) ~= 0 then    -- right
            y = y1 + (y2 - y1) * (cx2 - x1) / (x2 - x1)
            x = cx2
        else                            -- left
            y = y1 + (y2 - y1) * (cx - x1) / (x2 - x1)
            x = cx
        end
        if cout == c1 then x1, y1, c1 = x, y, _cs_outcode(x, y, cx, cy, cx2, cy2)
        else               x2, y2, c2 = x, y, _cs_outcode(x, y, cx, cy, cx2, cy2) end
    end
end

function Core.DrawLine(x1, y1, x2, y2, r, g, b, a)
    _stats._draw_count = _stats._draw_count + 1
    local cx1, cy1, cx2, cy2 = _clip_line(x1, y1, x2, y2)
    if not cx1 then return end
    gfx.set(r, g, b, a or 1)
    gfx.line(cx1, cy1, cx2, cy2)
end

-- DrawText: skip if any part of the text would extend past the active
-- clip rect. gfx has no per-glyph scissor, so partial clipping isn't
-- possible without offscreen buffers — dropping the whole label as soon
-- as it doesn't fully fit is the closest visual match (an FX card label
-- disappears the moment its panel starts to scroll out).
function Core.DrawText(text, x, y, r, g, b, a)
    _stats._draw_count = _stats._draw_count + 1
    if clip_top > 0 then
        local cx = clip_x[clip_top]
        local cy = clip_y[clip_top]
        -- Position checks first: they can reject without measuring at all.
        if x < cx or y < cy then return end
        -- Cached measurement (audit P4): the raw gfx.measurestr that used to
        -- sit here ran for EVERY text of every frame (the root clip pushed by
        -- Layout.Begin makes clip_top > 0 for the whole UI), bypassing the
        -- measure cache that exists precisely to eliminate that cost.
        local tw, th = Core.MeasureText(text)
        if x + tw > cx + clip_w[clip_top] or y + th > cy + clip_h[clip_top] then
            return
        end
    end
    gfx.set(r, g, b, a or 1)
    gfx.x, gfx.y = x, y
    gfx.drawstr(text)
end

-- ============================================================================
-- MEASURE TEXT CACHE (PERFORMANCE.md rule 2 / ROADMAP task 1.1)
-- ============================================================================
-- gfx.measurestr crosses the Lua↔C boundary and walks the font glyphs. For
-- static labels (which is most UI text), the result never changes between
-- frames — caching saves N traversals per frame where N = label count.
--
-- Cache layout: _measure_cache[slot][text] = {w, h}
--   - keyed by (current font slot, text) so font-dependent measurements stay
--     correct even when widgets switch slots mid-frame
--   - cleared whenever LoadFontSlots reloads the underlying fonts
--   - bounded by MEASURE_CACHE_MAX as a safety net against pathological use
--     (e.g. per-frame unique formatted strings); on overflow we wipe and
--     refill on next frame
local _current_font_slot = 4   -- default body slot (matches LoadFontSlots default)
local _measure_cache = {}      -- [slot] = { [text] = {w, h} }
local _measure_cache_count = {} -- [slot] = entry count (so clearing one slot
                                -- can decrement the global size — audit B5b:
                                -- the old over-estimate drifted up and forced
                                -- a full wipe + re-measure storm every few min)
local _measure_cache_size = 0
local MEASURE_CACHE_MAX = 8000

-- Truncation memo cache (audit P5) — declared here so the shared clear
-- function below can wipe it together with the measure cache.
local _trunc_cache = {}        -- [slot] = { [text] = { [floor(max_w)] = {out, w} } }
local _trunc_cache_size = 0
local TRUNC_CACHE_MAX = 2000

local function _measure_cache_clear()
    for k in pairs(_measure_cache) do _measure_cache[k] = nil end
    for k in pairs(_measure_cache_count) do _measure_cache_count[k] = nil end
    _measure_cache_size = 0
    for k in pairs(_trunc_cache) do _trunc_cache[k] = nil end
    _trunc_cache_size = 0
end

function Core.ClearMeasureCache()
    _measure_cache_clear()
end

function Core.MeasureText(text)
    local sub = _measure_cache[_current_font_slot]
    if not sub then
        sub = {}
        _measure_cache[_current_font_slot] = sub
        _measure_cache_count[_current_font_slot] = 0
    end
    local entry = sub[text]
    if entry then return entry[1], entry[2] end

    local w, h = gfx.measurestr(text)
    if _measure_cache_size >= MEASURE_CACHE_MAX then
        _measure_cache_clear()
        sub = {}
        _measure_cache[_current_font_slot] = sub
        _measure_cache_count[_current_font_slot] = 0
    end
    sub[text] = { w, h }
    _measure_cache_size = _measure_cache_size + 1
    _measure_cache_count[_current_font_slot] = _measure_cache_count[_current_font_slot] + 1
    return w, h
end

-- Truncate a string so that MeasureText(result) <= max_w. If truncation is
-- needed, appends ".." (which is included in the width budget). Returns the
-- (possibly shortened) string plus its measured width. If max_w is too small
-- to even fit "..", returns ("", 0) so callers never overflow.
--
-- Memoized per (font slot, text, floor(max_w)) — audit P5: the binary search
-- allocated ~log2(n) substrings + one concat per truncated label per FRAME,
-- and every probe substring became a permanent measure-cache entry, speeding
-- up cache saturation and its full-wipe stutter. Probes now use raw
-- gfx.measurestr (same values as the cache, no pollution) and the whole
-- search runs only on a cache miss.
function Core.TruncateText(text, max_w)
    if max_w <= 0 then return "", 0 end
    local wkey = floor(max_w)

    local slot_cache = _trunc_cache[_current_font_slot]
    if slot_cache then
        local per_text = slot_cache[text]
        if per_text then
            local hit = per_text[wkey]
            if hit then return hit[1], hit[2] end
        end
    end

    local tw = Core.MeasureText(text)
    local out, out_w
    if tw <= max_w or #text <= 2 then
        out, out_w = text, tw
    else
        local ellipsis_w = Core.MeasureText("..")
        if max_w < ellipsis_w then
            out, out_w = "", 0
        else
            local budget = max_w - ellipsis_w
            local lo, hi = 1, #text
            while lo < hi do
                local mid = (lo + hi + 1) >> 1
                if gfx.measurestr(text:sub(1, mid)) <= budget then
                    lo = mid
                else
                    hi = mid - 1
                end
            end
            out = text:sub(1, lo) .. ".."
            out_w = gfx.measurestr(out)
        end
    end

    if _trunc_cache_size >= TRUNC_CACHE_MAX then
        for k in pairs(_trunc_cache) do _trunc_cache[k] = nil end
        _trunc_cache_size = 0
        slot_cache = nil
    end
    if not slot_cache then
        slot_cache = _trunc_cache[_current_font_slot]
        if not slot_cache then
            slot_cache = {}
            _trunc_cache[_current_font_slot] = slot_cache
        end
    end
    local per_text = slot_cache[text]
    if not per_text then
        per_text = {}
        slot_cache[text] = per_text
    end
    per_text[wkey] = { out, out_w }
    _trunc_cache_size = _trunc_cache_size + 1
    return out, out_w
end

-- Legacy custom font path (Header, Text{font_size}). Audit B5b: this used to
-- redefine slot 1 — the Title slot — corrupting the title font AND nil-ing
-- its measure cache every frame. It now owns a dedicated slot and only
-- reloads (+ invalidates that slot's caches) when the requested font
-- actually changes.
local LEGACY_FONT_SLOT = 8
local _legacy_size, _legacy_face, _legacy_flags = nil, nil, nil

function Core.SetFont(size, face, flags)
    -- flags: 0=normal, 66=bold ('B'), 73=italic ('I')
    size = size or 12
    face = face or "Tahoma"
    flags = flags or 0
    if size ~= _legacy_size or face ~= _legacy_face or flags ~= _legacy_flags then
        gfx.setfont(LEGACY_FONT_SLOT, face, size, flags)
        _legacy_size, _legacy_face, _legacy_flags = size, face, flags
        -- The slot's definition really changed → drop only its cached entries.
        if _measure_cache[LEGACY_FONT_SLOT] then
            _measure_cache_size = _measure_cache_size
                - (_measure_cache_count[LEGACY_FONT_SLOT] or 0)
            if _measure_cache_size < 0 then _measure_cache_size = 0 end
            _measure_cache[LEGACY_FONT_SLOT] = nil
            _measure_cache_count[LEGACY_FONT_SLOT] = nil
        end
        _trunc_cache[LEGACY_FONT_SLOT] = nil
    elseif _current_font_slot ~= LEGACY_FONT_SLOT then
        gfx.setfont(LEGACY_FONT_SLOT)
    end
    _current_font_slot = LEGACY_FONT_SLOT
end

-- ============================================================================
-- FONT SLOTS (pre-loaded for instant switching)
-- ============================================================================
-- Slot 1=Title(bold), 2=H1, 3=H2, 4=Body(default), 5=Caption, 6=Mono, 7=H2Bold
-- (Slot 8 = legacy Core.SetFont; slots 15/16 are reserved for Icons and the
-- Log overlay — LoadFontSlots must never touch them.)
local font_slots_loaded = false

-- Bumped whenever the font slots are (re)loaded — external text caches
-- (word-wrap in Widgets, etc.) compare against this to self-invalidate.
local _font_version = 0
function Core.GetFontVersion()
    return _font_version
end

function Core.LoadFontSlots(theme)
    local f = theme.fonts
    gfx.setfont(1, f.face, f.title, 66)          -- Title (bold)
    gfx.setfont(2, f.face, f.h1, 0)              -- H1 (section headers)
    gfx.setfont(3, f.face, f.h2, 0)              -- H2 (sub-headers)
    gfx.setfont(4, f.face, f.body, 0)            -- Body (default)
    gfx.setfont(5, f.face, f.caption, 0)         -- Caption (small/hints)
    gfx.setfont(6, f.mono_face, f.mono_size, 0)  -- Mono (values)
    gfx.setfont(7, f.face, f.h2, 66)             -- H2 Bold
    font_slots_loaded = true
    gfx.setfont(4)  -- restore to Body
    _current_font_slot = 4
    -- Font definitions changed → all cached measurements are now invalid
    _measure_cache_clear()
    _font_version = _font_version + 1
end

-- Slot guards (audit P15): rtk documents gfx.setfont as one of the most
-- expensive gfx state changes — skip it when the slot is already current.
-- External code that changes the font behind Core's back (icons, log overlay)
-- must restore via Core.RestoreFont() or the guard would lie.
function Core.SetFontTitle()    if font_slots_loaded and _current_font_slot ~= 1 then gfx.setfont(1); _current_font_slot = 1 end end
function Core.SetFontH1()       if font_slots_loaded and _current_font_slot ~= 2 then gfx.setfont(2); _current_font_slot = 2 end end
function Core.SetFontH2()       if font_slots_loaded and _current_font_slot ~= 3 then gfx.setfont(3); _current_font_slot = 3 end end
function Core.SetFontBody()     if font_slots_loaded and _current_font_slot ~= 4 then gfx.setfont(4); _current_font_slot = 4 end end
function Core.SetFontCaption()  if font_slots_loaded and _current_font_slot ~= 5 then gfx.setfont(5); _current_font_slot = 5 end end
function Core.SetFontMono()     if font_slots_loaded and _current_font_slot ~= 6 then gfx.setfont(6); _current_font_slot = 6 end end
function Core.SetFontH2Bold()   if font_slots_loaded and _current_font_slot ~= 7 then gfx.setfont(7); _current_font_slot = 7 end end

function Core.GetCurrentFontSlot()
    return _current_font_slot
end

-- Re-select the slot Core believes is current. Modules that set a font
-- directly on their own slot (Icons, Log overlay) call this after drawing so
-- the actual gfx font matches _current_font_slot again (and the slot guards
-- above stay truthful).
function Core.RestoreFont()
    gfx.setfont(_current_font_slot)
end

-- Legacy aliases
function Core.SetFontPrimary()      Core.SetFontH1() end
function Core.SetFontSecondary()    Core.SetFontBody() end
function Core.SetFontTertiary()     Core.SetFontCaption() end
function Core.SetFontPrimaryBold()  Core.SetFontTitle() end

-- ============================================================================
-- CLIPPING (software-based scissor via off-screen buffer)
-- ============================================================================
-- gfx doesn't have hardware scissor, but we can skip draw calls outside the
-- clip rect. Widgets should call Core.IsVisible() before drawing; the
-- primitive Core.DrawRect/DrawText also bail out when fully outside the
-- clip. The clip stack arrays themselves are declared above (so that the
-- draw helpers can see them).

function Core.PushClipRect(x, y, w, h)
    -- Intersect with current clip rect if any
    if clip_top > 0 then
        local px, py, pw, ph = clip_x[clip_top], clip_y[clip_top], clip_w[clip_top], clip_h[clip_top]
        local cx2 = min(x + w, px + pw)
        local cy2 = min(y + h, py + ph)
        x = max(x, px)
        y = max(y, py)
        w = max(0, cx2 - x)
        h = max(0, cy2 - y)
    end
    clip_top = clip_top + 1
    clip_x[clip_top] = x
    clip_y[clip_top] = y
    clip_w[clip_top] = w
    clip_h[clip_top] = h
end

function Core.PopClipRect()
    if clip_top > 0 then clip_top = clip_top - 1 end
end

function Core.GetClipRect()
    if clip_top > 0 then
        return clip_x[clip_top], clip_y[clip_top], clip_w[clip_top], clip_h[clip_top]
    end
    return 0, 0, state.win_w, state.win_h
end

-- Returns true if a rect is at least partially visible in current clip.
-- Inlined clip lookup + bounds intersection (no helper call in hot path).
-- Audit B3: this used to demand FULL vertical containment (while allowing
-- partial horizontal overlap), contradicting its own doc — rows popped out
-- of existence at scroll edges and any widget taller than its viewport
-- never drew at all. Now a symmetric overlap test; the Draw* primitives
-- already clamp/drop content at the clip edges.
function Core.IsVisible(x, y, w, h)
    local cx, cy, cw, ch
    if clip_top > 0 then
        cx, cy, cw, ch = clip_x[clip_top], clip_y[clip_top], clip_w[clip_top], clip_h[clip_top]
    else
        cx, cy, cw, ch = 0, 0, state.win_w, state.win_h
    end
    return x + w > cx and x < cx + cw and y + h > cy and y < cy + ch
end

-- Strict variant: true only when the rect lies entirely inside the clip.
-- For widgets that draw with raw gfx.* calls (blits, arcs) which bypass the
-- software clip — partially visible content would bleed over neighbours.
function Core.IsFullyVisible(x, y, w, h)
    local cx, cy, cw, ch
    if clip_top > 0 then
        cx, cy, cw, ch = clip_x[clip_top], clip_y[clip_top], clip_w[clip_top], clip_h[clip_top]
    else
        cx, cy, cw, ch = 0, 0, state.win_w, state.win_h
    end
    return x >= cx and y >= cy and x + w <= cx + cw and y + h <= cy + ch
end

-- Less strict: partially visible (for rects that can be clamped)
function Core.IsPartiallyVisible(x, y, w, h)
    local cx, cy, cw, ch
    if clip_top > 0 then
        cx, cy, cw, ch = clip_x[clip_top], clip_y[clip_top], clip_w[clip_top], clip_h[clip_top]
    else
        cx, cy, cw, ch = 0, 0, state.win_w, state.win_h
    end
    return x + w > cx and x < cx + cw and y + h > cy and y < cy + ch
end

-- Clamp drawing coordinates to clip rect (for rect fills)
function Core.ClampToClip(x, y, w, h)
    local cx, cy, cw, ch
    if clip_top > 0 then
        cx, cy, cw, ch = clip_x[clip_top], clip_y[clip_top], clip_w[clip_top], clip_h[clip_top]
    else
        cx, cy, cw, ch = 0, 0, state.win_w, state.win_h
    end
    local x2 = min(x + w, cx + cw)
    local y2 = min(y + h, cy + ch)
    x = max(x, cx)
    y = max(y, cy)
    return x, y, max(0, x2 - x), max(0, y2 - y)
end

-- Hit-test respects clip rect: clicks outside clip are ignored.
-- Inlined clip+hit intersection: single bounds check, no helper calls.
function Core.MouseInClippedRect(x, y, w, h)
    -- Modal blocking (see Core.MouseInRect)
    if not state._in_modal and state.frame - state._modal_frame <= 1 then
        return false
    end
    local cx, cy, cw, ch
    if clip_top > 0 then
        cx, cy, cw, ch = clip_x[clip_top], clip_y[clip_top], clip_w[clip_top], clip_h[clip_top]
    else
        cx, cy, cw, ch = 0, 0, state.win_w, state.win_h
    end
    if x + w <= cx or x >= cx + cw or y + h <= cy or y >= cy + ch then return false end
    local mx, my = state.mouse_x, state.mouse_y
    -- The mouse itself must also be inside the clip: a widget partially
    -- outside its container must not respond on its clipped part.
    if mx < cx or mx >= cx + cw or my < cy or my >= cy + ch then return false end
    return mx >= x and mx < x + w and my >= y and my < y + h
end

-- ============================================================================
-- DOUBLE-CLICK TRACKING
-- ============================================================================
local dbl_click_state = {
    last_time = 0,
    last_x = 0,
    last_y = 0,
    threshold = 0.35,  -- seconds
    dist = 4,          -- pixels
}

local function update_double_click()
    state._dbl_click = false
    if Core.MouseClicked(1) then
        local now = reaper.time_precise()
        local dx = abs(state.mouse_x - dbl_click_state.last_x)
        local dy = abs(state.mouse_y - dbl_click_state.last_y)
        if now - dbl_click_state.last_time < dbl_click_state.threshold
           and dx < dbl_click_state.dist and dy < dbl_click_state.dist then
            state._dbl_click = true
        end
        dbl_click_state.last_time = now
        dbl_click_state.last_x = state.mouse_x
        dbl_click_state.last_y = state.mouse_y
    end
end

-- ============================================================================
-- STATE ACCESS
-- ============================================================================
function Core.GetState() return state end

function Core.GetMousePos() return state.mouse_x, state.mouse_y end
function Core.GetWindowSize() return state.win_w, state.win_h end
function Core.GetChar() return state.char end
function Core.GetFrame() return state.frame end
function Core.ConsumeWheel() state.wheel_consumed = true end
function Core.IsWheelConsumed() return state.wheel_consumed end

-- Keyboard consumption (audit B2): a widget or popup that handled this
-- frame's key calls ConsumeChar so Core.Run's layered ESC handling doesn't
-- also act on it (previously a bare `char ~= 27` check closed the whole
-- window even while a text edit or popup was cancelling).
function Core.ConsumeChar() state.char_consumed = true end
function Core.IsCharConsumed() return state.char_consumed end

-- Horizontal wheel (audit B19: was never read — ticks accumulated forever)
function Core.GetHWheel() return state.mouse_hwheel end
function Core.ConsumeHWheel() state.hwheel_consumed = true end
function Core.IsHWheelConsumed() return state.hwheel_consumed end
function Core.IsDocked() return state.dock ~= 0 end
function Core.GetDockState() return state.dock end

function Core.Dock(dock_id)
    -- dock_id: 0=undock, >0=dock position
    -- REAPER dock positions: 1=bottom, 2=left, 3=top, 4=right, 257=bottom(tab), etc.
    gfx.dock(dock_id or 1)
end

function Core.ToggleDock()
    if state.dock == 0 then
        gfx.dock(1)  -- dock to bottom by default
    else
        gfx.dock(0)  -- undock
    end
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
local user_loop_fn = nil
local win_title = "CP Toolkit"
local init_w, init_h = 400, 600
local init_dock = 0

local is_frameless = false
local win_hwnd = nil

function Core.Init(title, width, height, dock, x, y)
    win_title = title or win_title
    init_w = width or init_w
    init_h = height or init_h
    init_dock = dock or 0
    gfx.init(win_title, init_w, init_h, init_dock, x or 0, y or 0)
    gfx.setfont(1, "Arial", 14, 0)
end

-- Make the window frameless (no title bar, no border)
-- Requires JS_ReaScriptAPI extension
function Core.SetFrameless()
    if not reaper.JS_Window_Find then
        if Log then Log.Warn("CORE", "JS_ReaScriptAPI not found — frameless not available") end
        return false
    end

    -- Find our gfx window
    local hwnd = reaper.JS_Window_Find(win_title, true)
    if not hwnd then
        -- Fallback: enumerate top-level windows
        hwnd = reaper.JS_Window_FindTop(win_title, true)
    end

    if not hwnd then
        if Log then Log.Warn("CORE", "Could not find gfx window handle") end
        return false
    end

    win_hwnd = hwnd

    -- Remove frame: WS_POPUP style = no title bar, no border
    reaper.JS_Window_SetStyle(hwnd, "POPUP")

    -- Force resize to apply (gfx window might jump)
    reaper.JS_Window_Resize(hwnd, init_w, init_h)

    is_frameless = true
    if Log then Log.Info("CORE", "Frameless mode enabled") end
    return true
end

function Core.IsFrameless() return is_frameless end

-- Move the window to a specific screen position (useful for frameless overlays)
function Core.SetPosition(x, y)
    if win_hwnd and reaper.JS_Window_Move then
        reaper.JS_Window_Move(win_hwnd, x, y)
    end
end

-- Resize the gfx window. Works for frameless overlays (uses
-- JS_Window_Resize) and for regular windows (re-applies via gfx state).
-- Returns true if resize was attempted.
function Core.SetSize(w, h)
    if w == nil or h == nil then return false end
    state.win_w = w
    state.win_h = h
    if win_hwnd and reaper.JS_Window_Resize then
        reaper.JS_Window_Resize(win_hwnd, w, h)
        return true
    end
    return false
end

-- Set window always on top
function Core.SetTopMost(topmost)
    if win_hwnd and reaper.JS_Window_SetZOrder then
        local flag = topmost and "TOPMOST" or "NOTOPMOST"
        reaper.JS_Window_SetZOrder(win_hwnd, flag)
    end
end

-- ============================================================================
-- ANCHOR SYSTEM (follow a REAPER window position)
-- ============================================================================
-- anchor = {
--     target = "main"                     -- "main" (default) | "mixer" | "transport"
--                                         -- | "media_explorer" | "arrange"
--                                         -- | hwnd userdata | function() -> hwnd
--     snap = "free",                      -- "free" | "left" | "right"
--                                         --   left  → align to target.left + offset_x
--                                         --   right → align to target.right - win_w - offset_x
--                                         --   free  → use proportional x (anchor.x)
--     x = 0.5, y = 0.0,                   -- 0.0-1.0 proportional on target rect
--     offset_x = 0, offset_y = 30,        -- pixel offset
--     hide_when_target_hidden = true,     -- auto hide when target not visible
--     auto_hide_min_width  = 0,           -- hide when target.w < this (0 = disabled)
--     auto_hide_min_height = 0,           -- hide when target.h < this (0 = disabled)
-- }
local anchor = nil
local anchor_target_hwnd = nil
local anchor_last_target_lookup = 0
local anchor_was_hidden = false

-- Target rect throttle: GetRect costs ~5µs but adds up at 60Hz. The user's
-- target window only resizes when they drag it, so polling at 10Hz misses
-- nothing perceptible. Anchor moves still happen at frame rate using the
-- cached rect.
local RECT_POLL_INTERVAL = 0.1
local rect_last_check = 0
local rect_cache_left, rect_cache_top, rect_cache_right, rect_cache_bottom = 0, 0, 0, 0
local rect_cache_valid = false

-- Last applied window position — skip JS_Window_Move when the computed
-- target position is identical to where we already are. In steady state
-- (target window not moving, anchor not animated) this turns ~60 syscalls/s
-- into 0.
local last_applied_x, last_applied_y = nil, nil

-- Target-visibility cache (audit P23): JS_Window_IsVisible was pcall'd every
-- tick — including idle ticks — while GetRect three lines below was carefully
-- throttled to 10 Hz. Same throttle for both now.
local vis_cache = false
local vis_cache_valid = false
local vis_last_check = 0

-- Set to true on the frames where UpdateAnchor actually moved the window.
-- The idle-skip predicate looks at this so anchored overlays can still go
-- idle when their target hasn't moved.
local anchor_moved_this_frame = false

local function resolve_target_hwnd(target)
    if target == nil or target == "main" then
        return reaper.GetMainHwnd()
    end
    if type(target) == "function" then
        local ok, h = pcall(target)
        if ok then return h end
        return nil
    end
    if type(target) == "userdata" then
        return target
    end
    if type(target) ~= "string" then return nil end
    if not reaper.JS_Window_Find then return reaper.GetMainHwnd() end

    local lookups = {
        mixer          = "mixer",
        transport      = "transport",
        media_explorer = "Media Explorer",
        arrange        = "trackview",
        ruler          = "ruler",
        action_list    = "Actions",
        track_manager  = "Track Manager",
        region_manager = "Region/Marker Manager",
    }
    local title = lookups[target] or target
    local ok, h = pcall(reaper.JS_Window_Find, title, true)
    if ok and h then return h end
    return nil
end

function Core.SetAnchor(opts)
    if not reaper.JS_Window_GetRect then
        if Log then Log.Warn("CORE", "JS_ReaScriptAPI required for anchoring") end
        return false
    end
    anchor = opts
    anchor_target_hwnd = resolve_target_hwnd(opts and opts.target)
    anchor_last_target_lookup = reaper.time_precise()
    -- Invalidate caches: target may have changed, geometry params too.
    rect_cache_valid = false
    vis_cache_valid = false
    last_applied_x, last_applied_y = nil, nil
    return true
end

function Core.ClearAnchor()
    anchor = nil
    anchor_target_hwnd = nil
    rect_cache_valid = false
    vis_cache_valid = false
    last_applied_x, last_applied_y = nil, nil
end

-- Called each frame to reposition window if anchored
function Core.UpdateAnchor()
    if not anchor or not win_hwnd then return end
    if not reaper.JS_Window_GetRect then return end

    -- Re-resolve the target hwnd periodically (windows can be opened/closed
    -- during the session — e.g. mixer toggle).
    local now = reaper.time_precise()
    if not anchor_target_hwnd or (now - anchor_last_target_lookup) > 1.0 then
        anchor_target_hwnd = resolve_target_hwnd(anchor.target)
        anchor_last_target_lookup = now
    end

    local target_hwnd = anchor_target_hwnd
    if not target_hwnd then
        if anchor.hide_when_target_hidden and not anchor_was_hidden and reaper.JS_Window_Show then
            reaper.JS_Window_Show(win_hwnd, "HIDE")
            anchor_was_hidden = true
        end
        return
    end

    -- Auto-hide when target is not visible (throttled to RECT_POLL_INTERVAL)
    if anchor.hide_when_target_hidden and reaper.JS_Window_IsVisible then
        local nowv = reaper.time_precise()
        if not vis_cache_valid or (nowv - vis_last_check) >= RECT_POLL_INTERVAL then
            vis_last_check = nowv
            local ok, v = pcall(reaper.JS_Window_IsVisible, target_hwnd)
            vis_cache = ok and v or false
            vis_cache_valid = true
        end
        local visible = vis_cache
        if not visible then
            if not anchor_was_hidden and reaper.JS_Window_Show then
                reaper.JS_Window_Show(win_hwnd, "HIDE")
                anchor_was_hidden = true
            end
            return
        elseif anchor_was_hidden and reaper.JS_Window_Show then
            reaper.JS_Window_Show(win_hwnd, "SHOWNA")
            anchor_was_hidden = false
        end
    end

    -- (Focus-based auto-hide was removed: with topmost=false the toolbar
    -- naturally falls behind any window that comes in front, so an
    -- explicit hide-on-defocus added bugs without a real visual benefit.
    -- hide_when_target_hidden + IsVisible still cover the REAPER-minimised
    -- case below.)

    -- Throttle GetRect to 10Hz; reuse last result in between. Target
    -- windows only move/resize when the user drags them, so polling at
    -- frame rate is wasteful. The first frame primes the cache.
    local now3 = reaper.time_precise()
    if not rect_cache_valid or (now3 - rect_last_check) >= RECT_POLL_INTERVAL then
        rect_last_check = now3
        local ok, r_left, r_top, r_right, r_bottom = reaper.JS_Window_GetRect(target_hwnd)
        if not ok then return end
        rect_cache_left, rect_cache_top   = r_left, r_top
        rect_cache_right, rect_cache_bottom = r_right, r_bottom
        rect_cache_valid = true
    end
    local r_left, r_top   = rect_cache_left, rect_cache_top
    local r_right, r_bottom = rect_cache_right, rect_cache_bottom
    local r_w = r_right - r_left
    local r_h = r_bottom - r_top

    -- Auto-hide when the target window is too small (mirrors the legacy
    -- CP_CustomToolbars behaviour). Useful for toolbars anchored to the
    -- mixer or arrange view that should disappear when the user drags
    -- those panes very narrow/short.
    local min_w = anchor.auto_hide_min_width or 0
    local min_h = anchor.auto_hide_min_height or 0
    if (min_w > 0 and r_w < min_w) or (min_h > 0 and r_h < min_h) then
        if not anchor_was_hidden and reaper.JS_Window_Show then
            reaper.JS_Window_Show(win_hwnd, "HIDE")
            anchor_was_hidden = true
        end
        return
    elseif anchor_was_hidden and reaper.JS_Window_Show then
        reaper.JS_Window_Show(win_hwnd, "SHOWNA")
        anchor_was_hidden = false
    end

    local snap = anchor.snap or "free"
    local off_x = anchor.offset_x or 0
    local off_y = anchor.offset_y or 0

    local target_x
    if snap == "left" then
        target_x = r_left + off_x
    elseif snap == "right" then
        -- Anchor to the right edge: position so the toolbar's right edge
        -- ends at target.right - off_x. We need our own window width for
        -- this; fall back to 0 if we don't have a current size yet.
        local our_w = (state and state.win_w) or 0
        target_x = r_right - our_w - off_x
    else
        target_x = r_left + floor(r_w * (anchor.x or 0)) + off_x
    end

    local target_y = r_top + floor(r_h * (anchor.y or 0)) + off_y

    -- Skip the syscall if our window is already at the computed position.
    -- In a static scene this turns a per-frame Win32 SetWindowPos into a
    -- single integer comparison.
    if target_x ~= last_applied_x or target_y ~= last_applied_y then
        reaper.JS_Window_Move(win_hwnd, target_x, target_y)
        last_applied_x, last_applied_y = target_x, target_y
        anchor_moved_this_frame = true
    end
end


-- ============================================================================
-- CURSOR SYSTEM
-- ============================================================================
-- Set cursor for current frame. Reset to default at end of frame.
local cursor_this_frame = nil

function Core.SetCursor(cursor_type)
    cursor_this_frame = cursor_type
end

-- Cursor name → Windows cursor resource id. Module constant (audit P9: this
-- table used to be rebuilt on every frame where a cursor was requested).
-- 32512 = arrow, 32513 = ibeam, 32514 = wait, 32515 = cross
-- 32516 = uparrow, 32642 = sizenwse, 32643 = sizenesw
-- 32644 = sizewe (horizontal resize), 32645 = sizens (vertical resize)
-- 32646 = sizeall (move), 32649 = hand
local CURSOR_IDS = {
    arrow    = 32512,
    ibeam    = 32513,
    wait     = 32514,
    cross    = 32515,
    hand     = 32649,
    size_we  = 32644,  -- horizontal resize ↔
    size_ns  = 32645,  -- vertical resize ↕
    size_all = 32646,  -- move ✥
    size_nwse = 32642, -- diagonal ↘
    size_nesw = 32643, -- diagonal ↗
}
local _last_cursor_id = nil

-- Apply cursor at end of frame (called by Core.Run). gfx keeps the cursor
-- per window, so re-applying an unchanged id every frame is a wasted
-- syscall — only call gfx.setcursor when the id actually changes.
local function apply_cursor()
    local cid = 32512  -- default arrow
    if cursor_this_frame then
        cid = CURSOR_IDS[cursor_this_frame] or 32512
    end
    if cid ~= _last_cursor_id then
        gfx.setcursor(cid)
        _last_cursor_id = cid
    end
    cursor_this_frame = nil  -- reset for next frame
end

-- ============================================================================
-- ANIMATION SYSTEM
-- ============================================================================
-- Interpolates values over time. Call each frame, returns current value.
-- Entries are frame-stamped and swept together with widget_data (audit P11:
-- dynamic animation ids — one per hovered list row, per tab… — accumulated
-- for the whole session).
local animations = {}
local _anim_stamp = {}

function Core.Animate(id, target, speed, dt)
    speed = speed or 8  -- higher = faster
    dt = dt or 0.033    -- ~30fps default

    _anim_stamp[id] = state.frame
    if not animations[id] then
        animations[id] = target  -- snap on first call
    end

    local current = animations[id]
    local diff = target - current

    if abs(diff) < 0.001 then
        animations[id] = target
        return target
    end

    -- Animation is still moving — keep frame loop in active mode
    state._has_active_animation = true

    -- Exponential ease-out
    animations[id] = current + diff * min(1, speed * dt)
    return animations[id]
end

function Core.AnimateColor(id, target_color, speed, dt)
    speed = speed or 8
    dt = dt or 0.033

    _anim_stamp[id] = state.frame
    if not animations[id] then
        animations[id] = { target_color[1], target_color[2], target_color[3], target_color[4] or 1 }
    end

    local c = animations[id]
    local moving = false

    for i = 1, 4 do
        local t = target_color[i] or (i == 4 and 1 or 0)
        local diff = t - c[i]
        if abs(diff) > 0.001 then
            c[i] = c[i] + diff * min(1, speed * dt)
            moving = true
        else
            c[i] = t
        end
    end

    if moving then state._has_active_animation = true end

    return c[1], c[2], c[3], c[4]
end

function Core.GetAnimValue(id)
    return animations[id]
end

function Core.SetAnimValue(id, value)
    animations[id] = value
    _anim_stamp[id] = state.frame
end

-- ============================================================================
-- RETAINED-STATE SWEEP (microui "forgetful pool" — audit P11)
-- ============================================================================
-- Runs every WD_SWEEP_INTERVAL *active* frames (idle frames don't tick the
-- counter, and don't accrue garbage either). Drops widget_data sub-entries
-- and animation values whose id hasn't been requested for WD_TTL_FRAMES
-- active frames. Sweep cost is O(entries) but amortized: at 30 fps active,
-- once every ~20 s.
local WD_SWEEP_INTERVAL = 600
local WD_TTL_FRAMES = 1800

local function _sweep_retained_state()
    local cutoff = state.frame - WD_TTL_FRAMES
    if cutoff <= 0 then return end
    for category, stamps in pairs(_wd_stamp) do
        local map = state.widget_data[category]
        for id, f in pairs(stamps) do
            if f < cutoff then
                stamps[id] = nil
                if map then map[id] = nil end
            end
        end
    end
    for id, f in pairs(_anim_stamp) do
        if f < cutoff then
            _anim_stamp[id] = nil
            animations[id] = nil
        end
    end
end

-- ============================================================================
-- FOCUS CHAIN (Tab navigation between widgets)
-- ============================================================================
-- Immediate-mode chain: rebuilt every frame (Core.Run resets the count), so
-- ids of widgets that stopped rendering can never receive focus. Audit B18:
-- the previous accumulate-forever version did an O(n) dedup scan per call and
-- kept dead ids for the whole session. Registration is now a plain append —
-- widgets call it once per frame in draw order.
local focus_chain = {}
local focus_chain_n = 0

function Core.RegisterFocusable(id)
    focus_chain_n = focus_chain_n + 1
    focus_chain[focus_chain_n] = id
end

-- Find the currently focused id in this frame's chain (0 if none).
local function _focus_chain_index()
    for i = 1, focus_chain_n do
        if focus_chain[i] == state.focus then return i end
    end
    return 0
end

function Core.FocusNext()
    if focus_chain_n == 0 then return end
    local idx = _focus_chain_index() + 1
    if idx > focus_chain_n then idx = 1 end
    state.focus = focus_chain[idx]
end

function Core.FocusPrev()
    if focus_chain_n == 0 then return end
    local idx = _focus_chain_index() - 1
    if idx < 1 then idx = focus_chain_n end
    state.focus = focus_chain[idx]
end

function Core.ClearFocusChain()
    focus_chain_n = 0
end

-- ============================================================================
-- PERSISTENT LAYOUT (save/load window state, splitter positions, etc.)
-- ============================================================================
-- Window state is saved as a SINGLE ExtState entry (one disk write) to keep
-- close latency low. Format: "dock,x,y,w,h" — undocked saves x/y/w/h, docked
-- only saves dock.
function Core.SaveWindowState(script_id)
    local dock_state = gfx.dock(-1)
    local payload
    if dock_state == 0 then
        local _, wx, wy, ww, wh = gfx.dock(-1, 0, 0, 0, 0)
        payload = string.format("%d,%d,%d,%d,%d", dock_state, wx, wy, ww, wh)
    else
        payload = tostring(dock_state)
    end
    reaper.SetExtState(script_id, "win_state", payload, true)
end

function Core.LoadWindowState(script_id)
    local payload = reaper.GetExtState(script_id, "win_state")
    if payload ~= "" then
        local dock, x, y, w, h = payload:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
        if dock then
            return {
                dock = tonumber(dock) or 0,
                x = tonumber(x), y = tonumber(y),
                w = tonumber(w), h = tonumber(h),
            }
        end
        -- Docked-only payload (single number)
        local d = tonumber(payload)
        if d then return { dock = d } end
    end

    -- Legacy fallback: read the old per-key format if present
    local dock = tonumber(reaper.GetExtState(script_id, "win_dock")) or 0
    return {
        dock = dock,
        x = tonumber(reaper.GetExtState(script_id, "win_x")),
        y = tonumber(reaper.GetExtState(script_id, "win_y")),
        w = tonumber(reaper.GetExtState(script_id, "win_w")),
        h = tonumber(reaper.GetExtState(script_id, "win_h")),
    }
end

-- Save/load arbitrary persistent values (splitter positions, collapsing states, etc.)
function Core.SavePersistent(script_id, key, value)
    reaper.SetExtState(script_id, "layout_" .. key, tostring(value), true)
end

function Core.LoadPersistent(script_id, key, default)
    local val = reaper.GetExtState(script_id, "layout_" .. key)
    if val == "" then return default end
    if default and type(default) == "number" then return tonumber(val) or default end
    if default and type(default) == "boolean" then return val == "true" end
    return val
end

-- ============================================================================
-- CP_CONFIG — file-based config storage
--   One Lua file per script_id under <resource>/Scripts/CP_Scripts/CP_Config/
--   - Save: 1 disk write of a small file (~1-5KB) regardless of #fields,
--     vs ExtState which rewrites the global ~50-200KB reaper-extstate.ini.
--   - Load: dofile() returns the table; instant after the OS file cache.
--   - Format: human-readable Lua source, manually editable / backup-friendly.
-- ============================================================================
local function _cp_config_dir()
    return reaper.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Config/"
end

local function _cp_config_path(script_id)
    return _cp_config_dir() .. script_id .. ".lua"
end

-- Recursive Lua-table serializer. Supports: nil, boolean, number, string,
-- and tables (mixed array/hash). Cycles will infinite-loop — don't pass them.
local function _serialize(value, indent)
    local t = type(value)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return tostring(value)
    elseif t == "number" then
        -- Preserve precision; "%.6g" trims trailing zeros while keeping enough digits
        if value == floor(value) and abs(value) < 1e15 then
            return string.format("%d", value)
        end
        return string.format("%.6g", value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        local pad = string.rep("  ", indent)
        local pad2 = string.rep("  ", indent + 1)
        local parts = {}
        -- Detect array vs hash
        local n = 0
        local is_array = true
        for k, _ in pairs(value) do
            n = n + 1
            if type(k) ~= "number" or k ~= floor(k) or k < 1 then
                is_array = false
            end
        end
        if is_array and n == #value and n > 0 then
            for i = 1, #value do
                parts[#parts + 1] = pad2 .. _serialize(value[i], indent + 1)
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
        else
            -- Hash table — sort keys for stable output
            local keys = {}
            for k, _ in pairs(value) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                local v = value[k]
                local key_str
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key_str = k
                else
                    key_str = "[" .. _serialize(k, indent + 1) .. "]"
                end
                parts[#parts + 1] = pad2 .. key_str .. " = " .. _serialize(v, indent + 1)
            end
            if #parts == 0 then return "{}" end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
        end
    end
    return "nil"
end

-- Save a Lua table as <CP_Config>/<script_id>.lua. Returns true on success.
function Core.SaveConfig(script_id, data)
    if not script_id or type(data) ~= "table" then return false end
    reaper.RecursiveCreateDirectory(_cp_config_dir(), 0)
    local path = _cp_config_path(script_id)

    local body = "-- " .. script_id .. " — auto-generated config\n"
              .. "return " .. _serialize(data, 0) .. "\n"

    local f = io.open(path, "w")
    if not f then return false end
    f:write(body)
    f:close()
    return true
end

-- Load a config table from disk. Returns the table or nil if not found.
function Core.LoadConfig(script_id)
    if not script_id then return nil end
    local path = _cp_config_path(script_id)
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

-- ============================================================================
-- NATIVE GFX DRAWING (exposed for toolkit use)
-- ============================================================================
function Core.DrawRoundRect(x, y, w, h, radius, r, g, b, a, antialias)
    _stats._draw_count = _stats._draw_count + 1
    gfx.set(r, g, b, a or 1)
    gfx.roundrect(x, y, w, h, radius, antialias ~= false and 1 or 0)
end

function Core.DrawCircle(x, y, radius, r, g, b, a, filled, antialias)
    _stats._draw_count = _stats._draw_count + 1
    -- Skip only when the bounding box is FULLY outside the clip rect. gfx
    -- has no per-pixel scissor; circles partially overlapping the clip
    -- still draw cleanly enough that we don't need a hard cutoff (matches
    -- the toolkit Demo's XY-pad cursor that hugs the edges).
    if clip_top > 0 then
        local cx = clip_x[clip_top]
        local cy = clip_y[clip_top]
        local cw = clip_w[clip_top]
        local ch = clip_h[clip_top]
        if x + radius < cx or y + radius < cy
           or x - radius > cx + cw or y - radius > cy + ch then
            return
        end
    end
    gfx.set(r, g, b, a or 1)
    gfx.circle(x, y, radius, filled and 1 or 0, antialias ~= false and 1 or 0)
end

function Core.DrawTriangle(x1, y1, x2, y2, x3, y3, r, g, b, a)
    _stats._draw_count = _stats._draw_count + 1
    -- Skip only when the bounding box is FULLY outside the clip rect.
    if clip_top > 0 then
        local cx = clip_x[clip_top]
        local cy = clip_y[clip_top]
        local cw = clip_w[clip_top]
        local ch = clip_h[clip_top]
        local minx = x1 < x2 and (x1 < x3 and x1 or x3) or (x2 < x3 and x2 or x3)
        local maxx = x1 > x2 and (x1 > x3 and x1 or x3) or (x2 > x3 and x2 or x3)
        local miny = y1 < y2 and (y1 < y3 and y1 or y3) or (y2 < y3 and y2 or y3)
        local maxy = y1 > y2 and (y1 > y3 and y1 or y3) or (y2 > y3 and y2 or y3)
        if maxx < cx or maxy < cy or minx > cx + cw or miny > cy + ch then
            return
        end
    end
    gfx.set(r, g, b, a or 1)
    gfx.triangle(x1, y1, x2, y2, x3, y3)
end

function Core.DrawArc(x, y, radius, ang1, ang2, r, g, b, a, antialias)
    _stats._draw_count = _stats._draw_count + 1
    gfx.set(r, g, b, a or 1)
    gfx.arc(x, y, radius, ang1, ang2, antialias ~= false and 1 or 0)
end

function Core.DrawGradientRect(x, y, w, h, r1, g1, b1, a1, r2, g2, b2, a2, vertical)
    _stats._draw_count = _stats._draw_count + 1
    gfx.set(r1, g1, b1, a1)
    if vertical then
        local dr = (r2 - r1) / h
        local dg = (g2 - g1) / h
        local db = (b2 - b1) / h
        local da = (a2 - a1) / h
        gfx.gradrect(x, y, w, h, r1, g1, b1, a1, 0, 0, 0, 0, dr, dg, db, da)
    else
        local dr = (r2 - r1) / w
        local dg = (g2 - g1) / w
        local db = (b2 - b1) / w
        local da = (a2 - a1) / w
        gfx.gradrect(x, y, w, h, r1, g1, b1, a1, dr, dg, db, da, 0, 0, 0, 0)
    end
end

function Core.ClientToScreen(x, y)
    return gfx.clienttoscreen(x, y)
end

function Core.ScreenToClient(x, y)
    return gfx.screentoclient(x, y)
end

-- Get the gfx window handle
function Core.GetHWND()
    if not win_hwnd and reaper.JS_Window_Find then
        win_hwnd = reaper.JS_Window_Find(win_title, true)
    end
    return win_hwnd
end

-- ============================================================================
-- IDLE THROTTLE (see PERFORMANCE.md rule 4 + ROADMAP task 2.1)
-- ============================================================================
-- Strategy: instead of running the full frame body 30x/sec unconditionally,
-- detect frames where nothing has changed and skip the heavy work (input
-- processing, user loop, drawing). On idle frames we still defer at REAPER's
-- natural rate, but we bail out early — saving the bulk of the CPU cost.
--
-- A frame is considered idle when ALL of these are true:
--   - mouse position, buttons and wheels are unchanged from last full frame
--   - no key is pending (the skip path polls gfx.getchar — see below)
--   - no widget is active (held/dragged)
--   - no animation is mid-interpolation
--   - no explicit Core.RequestRedraw() pending
--   - no Core.RequestRedrawAt() deadline has passed (caret blink, tooltip
--     delay — the scheduled-redraw mechanism that replaced the old
--     "focus ~= nil blocks idle forever" rule; audit P2)
--   - the anchor target (if any) hasn't moved
--   - window size hasn't changed
--   - we have not exceeded the idle heartbeat interval (forces a wakeup
--     occasionally so external dirty state still gets a chance to redraw)
--
-- Keyboard (audit P1): gfx.getchar() is consuming, so the skip path polls it
-- and stashes a nonzero result in _pending_char — the loop wakes on the very
-- next tick instead of waiting out the heartbeat, and the full frame consumes
-- the stashed char instead of re-reading. This also catches the window-close
-- signal (-1) immediately. With the keyboard handled, the heartbeat's only
-- job is external state (RequestRedraw from coroutines etc.) — it can be
-- slow: 0.5 s = 2 full frames/s ≈ 0.4% CPU at a 2 ms frame, within contract.
--
-- During an idle skip we DO NOT call gfx.update() (no draws to flush — gfx
-- keeps its backbuffer).
local IDLE_HEARTBEAT = 0.5   -- forced wakeup interval in seconds (~2 Hz)
local INPUT_MOMENTUM = 0.30  -- stay active for N seconds after last user input
local _last_full_frame_time = 0
local _last_input_time = 0
local _pending_char = nil

-- Called from the full-frame body when an input event was observed.
-- Keeps the loop active for INPUT_MOMENTUM seconds so follow-up events
-- (rapid wheel ticks, key repeat, drag-release) are processed promptly
-- without waiting on the idle heartbeat + REAPER's defer throttle.
local function _mark_input()
    _last_input_time = reaper.time_precise()
end

local function _can_skip_frame()
    -- Throttle disabled globally? Never skip.
    if not _idle_throttle_enabled then return false end

    -- Window resize or first frame: always do full frame
    if gfx.w ~= state.win_w or gfx.h ~= state.win_h then return false end
    if state.frame == 0 then return false end

    -- Mouse changes: any movement, button state change, or wheel input
    if gfx.mouse_x ~= state.mouse_x then return false end
    if gfx.mouse_y ~= state.mouse_y then return false end
    if gfx.mouse_cap ~= state.mouse_cap then return false end
    if gfx.mouse_wheel ~= 0 then return false end
    if gfx.mouse_hwheel ~= 0 then return false end

    -- Anything that demands continuous redraw. Note (audit P2/P3): a held
    -- widget (state.active) blocks idle — auto-repeat and drag capture need
    -- real frames even with the mouse motionless. Keyboard focus does NOT
    -- block anymore: focused text widgets schedule their caret blink via
    -- Core.RequestRedrawAt and keystrokes wake the loop through the
    -- gfx.getchar poll in the skip path. Open popups don't block either —
    -- any interaction with them changes mouse state and wakes the loop.
    if state.active ~= nil then return false end
    if state._has_active_animation then return false end
    if state._request_redraw then return false end

    -- Anchored overlays can skip *if* the anchor target didn't move
    -- this frame. We tick the anchor here in the cheap path so it can
    -- update its caches, then check whether it actually relocated us.
    if anchor ~= nil then
        Core.UpdateAnchor()
        if anchor_moved_this_frame then
            anchor_moved_this_frame = false
            return false
        end
    end

    local now = reaper.time_precise()

    -- Scheduled redraw deadline reached? (RequestRedrawAt — caret blink,
    -- tooltip show delay, timed fades)
    if _next_redraw_at ~= nil and now >= _next_redraw_at then
        _next_redraw_at = nil
        return false
    end

    -- Input momentum: absorb follow-up events (rapid wheel ticks etc.) without
    -- the defer-throttle round-trip penalty of dropping to idle between ticks.
    if now - _last_input_time < INPUT_MOMENTUM then return false end

    -- Heartbeat: at least one full frame per IDLE_HEARTBEAT, so external
    -- state changes (e.g. RequestRedraw from a coroutine) get a chance.
    if now - _last_full_frame_time > IDLE_HEARTBEAT then
        return false
    end

    return true
end

function Core.Run(loop_fn)
    user_loop_fn = loop_fn
    local function frame()
        -- ----- Idle skip check (cheap path, runs first) -----
        if _can_skip_frame() then
            -- Keyboard can't be observed without consuming: poll it here.
            -- A pending key (or the window-close signal -1) wakes the loop
            -- immediately and is handed to the full frame below instead of
            -- being re-read (audit P1: keys used to wait out the heartbeat).
            local ch = gfx.getchar()
            if ch ~= 0 then
                _pending_char = ch
                _mark_input()
            else
                _stats.mode = "idle"
                _stats.idle_skips = _stats.idle_skips + 1
                reaper.defer(frame)
                return
            end
        end

        -- ----- Full frame body -----
        local t0 = reaper.time_precise()
        local kb0 = collectgarbage("count")
        _stats._draw_count = 0
        _stats.mode = "active"
        _stats.idle_skips = 0
        _last_full_frame_time = t0

        -- Update state
        state.prev_mouse_x = state.mouse_x
        state.prev_mouse_y = state.mouse_y
        state.prev_mouse_cap = state.mouse_cap

        state.mouse_x = gfx.mouse_x
        state.mouse_y = gfx.mouse_y
        state.mouse_cap = gfx.mouse_cap
        state.mouse_wheel = gfx.mouse_wheel
        gfx.mouse_wheel = 0  -- consume wheel delta
        state.mouse_hwheel = gfx.mouse_hwheel
        gfx.mouse_hwheel = 0
        state.char = _pending_char or gfx.getchar()
        _pending_char = nil
        state.char_consumed = false
        state.win_w = gfx.w
        state.win_h = gfx.h
        state.dock = gfx.dock(-1)
        state.frame = state.frame + 1

        -- Any user input on this frame → refresh momentum so follow-up events
        -- stay on the active path (see INPUT_MOMENTUM).
        if state.mouse_wheel ~= 0
           or state.mouse_hwheel ~= 0
           or state.mouse_cap ~= state.prev_mouse_cap
           or state.mouse_x ~= state.prev_mouse_x
           or state.mouse_y ~= state.prev_mouse_y
           or (state.char and state.char ~= 0 and state.char ~= -1) then
            _mark_input()
        end

        -- Reset animation tracker — set by Core.Animate during user loop
        state._has_active_animation = false
        -- Consume one-shot redraw request
        state._request_redraw = false

        -- Log: begin frame
        if Log then
            Log.HandleInput(state.char, state.mouse_wheel, state.mouse_y)
            Log.BeginFrame(state.frame, state)
        end

        -- Update anchor position (if overlay is anchored to REAPER).
        -- Reset the moved-flag first so the predicate sees a clean state
        -- on the next idle check.
        anchor_moved_this_frame = false
        Core.UpdateAnchor()
        anchor_moved_this_frame = false

        -- Reset per-frame flags
        state.hot = nil
        state.wheel_consumed = false
        state.hwheel_consumed = false
        _reset_disabled_scope()
        focus_chain_n = 0  -- focus chain is rebuilt by this frame's widgets

        -- Double-click tracking
        update_double_click()

        -- Clear on click outside any widget
        if Core.MouseClicked(1) and state.active == nil then
            state.focus = nil
        end

        -- Call user loop
        if user_loop_fn then
            user_loop_fn()
        end

        -- Draw popup layer (on top of main content)
        if state.popup_layer then
            state.popup_layer.draw()
        end

        -- Draw tooltip layer (on top of popups)
        if state.tooltip_layer then
            state.tooltip_layer()
            state.tooltip_layer = nil  -- clear each frame (re-set by Tooltip widget)
        end

        -- Log: end frame + overlay
        if Log then
            Log.EndFrame(state)
            Log.DrawOverlay()
        end

        -- Apply mouse cursor for this frame
        apply_cursor()

        -- End frame
        gfx.update()

        -- Retained-state sweep (widget_data / animations LRU, audit P11)
        if state.frame % WD_SWEEP_INTERVAL == 0 then
            _sweep_retained_state()
        end

        -- ----- Stats sampling (after gfx.update so we capture full frame cost) -----
        local frame_ms = (reaper.time_precise() - t0) * 1000
        local alloc_kb = collectgarbage("count") - kb0
        _stats.frame_ms = frame_ms
        _stats.alloc_kb = alloc_kb
        _stats.draws_per_frame = _stats._draw_count
        _push_sample(frame_ms, alloc_kb, _stats._draw_count)

        -- ----- Close check -----
        -- Layered ESC (audit B2): a widget that handled the key consumed it;
        -- otherwise an open popup absorbs it, then keyboard focus is released;
        -- only a "bare" ESC — nothing left to dismiss — closes the window.
        local want_close = state._request_close or state.char < 0
        if not want_close and state.char == 27 and not state.char_consumed then
            if state.popup_layer ~= nil then
                Core.ClearPopup()
            elseif state.focus ~= nil then
                state.focus = nil
            else
                want_close = true
            end
        end

        if not want_close then
            reaper.defer(frame)
        else
            -- Run user OnClose BEFORE gfx.quit() so it can still query
            -- gfx state (window position, dock, etc.)
            if Core._on_close then Core._on_close() end
            gfx.quit()
        end
    end

    frame()
end

function Core.OnClose(fn)
    Core._on_close = fn
end

-- Programmatically request the window to close on the next frame.
function Core.RequestClose()
    state._request_close = true
end

-- ============================================================================
-- CONTAINER STACK (used by Layout.lua)
-- ============================================================================
function Core.PushContainer(container)
    state.container_stack[#state.container_stack + 1] = container
end

function Core.PopContainer()
    local c = state.container_stack[#state.container_stack]
    state.container_stack[#state.container_stack] = nil
    return c
end

function Core.CurrentContainer()
    return state.container_stack[#state.container_stack]
end

return Core
