-- CP_Toolkit Core — Immediate-mode UI on REAPER gfx.*
-- Boucle principale, état souris/clavier, système d'IDs, hit-testing

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

    -- Mouse (previous frame)
    prev_mouse_x = 0,
    prev_mouse_y = 0,
    prev_mouse_cap = 0,

    -- Keyboard
    char = 0,

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

    -- Persistent widget data (scroll offsets, combo open states, etc.)
    widget_data = {},
}

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
function Core.DrawRect(x, y, w, h, r, g, b, a, filled)
    gfx.set(r, g, b, a or 1)
    if filled ~= false then
        gfx.rect(x, y, w, h, 1)
    else
        gfx.rect(x, y, w, h, 0)
    end
end

function Core.DrawLine(x1, y1, x2, y2, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    gfx.line(x1, y1, x2, y2)
end

function Core.DrawText(text, x, y, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    gfx.x, gfx.y = x, y
    gfx.drawstr(text)
end

function Core.MeasureText(text)
    local w, h = gfx.measurestr(text)
    return w, h
end

function Core.SetFont(size, face, flags)
    -- flags: 0=normal, 66=bold ('B'), 73=italic ('I')
    gfx.setfont(1, face or "Arial", size or 14, flags or 0)
end

-- ============================================================================
-- CLIPPING (software-based scissor via off-screen buffer)
-- ============================================================================
-- gfx doesn't have hardware scissor, but we can skip draw calls
-- outside the clip rect. Widgets should call Core.IsVisible() before drawing.
local clip_stack = {}

function Core.PushClipRect(x, y, w, h)
    -- Intersect with current clip rect if any
    local current = clip_stack[#clip_stack]
    if current then
        local cx2 = math.min(x + w, current.x + current.w)
        local cy2 = math.min(y + h, current.y + current.h)
        x = math.max(x, current.x)
        y = math.max(y, current.y)
        w = math.max(0, cx2 - x)
        h = math.max(0, cy2 - y)
    end
    clip_stack[#clip_stack + 1] = { x = x, y = y, w = w, h = h }
end

function Core.PopClipRect()
    clip_stack[#clip_stack] = nil
end

function Core.GetClipRect()
    local c = clip_stack[#clip_stack]
    if c then return c.x, c.y, c.w, c.h end
    return 0, 0, state.win_w, state.win_h
end

-- Returns true if a rect is at least partially visible in current clip
function Core.IsVisible(x, y, w, h)
    local cx, cy, cw, ch = Core.GetClipRect()
    return x + w > cx and x < cx + cw and y + h > cy and y < cy + ch
end

-- Clamp drawing coordinates to clip rect (for rect fills)
function Core.ClampToClip(x, y, w, h)
    local cx, cy, cw, ch = Core.GetClipRect()
    local x2 = math.min(x + w, cx + cw)
    local y2 = math.min(y + h, cy + ch)
    x = math.max(x, cx)
    y = math.max(y, cy)
    return x, y, math.max(0, x2 - x), math.max(0, y2 - y)
end

-- Hit-test respects clip rect: clicks outside clip are ignored
function Core.MouseInClippedRect(x, y, w, h)
    if not Core.IsVisible(x, y, w, h) then return false end
    return Core.MouseInRect(x, y, w, h)
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
        local dx = math.abs(state.mouse_x - dbl_click_state.last_x)
        local dy = math.abs(state.mouse_y - dbl_click_state.last_y)
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

-- Set window always on top
function Core.SetTopMost(topmost)
    if win_hwnd and reaper.JS_Window_SetZOrder then
        local flag = topmost and "TOPMOST" or "NOTOPMOST"
        reaper.JS_Window_SetZOrder(win_hwnd, flag)
    end
end

-- ============================================================================
-- ANCHOR SYSTEM (follow REAPER main window position)
-- ============================================================================
-- anchor = { x = 0.5, y = 0.0, offset_x = 0, offset_y = 30 }
-- x/y = 0.0-1.0 proportional position on REAPER window
-- offset_x/y = pixel offset from that position
local anchor = nil
local reaper_hwnd = nil

function Core.SetAnchor(opts)
    if not reaper.JS_Window_GetRect then
        if Log then Log.Warn("CORE", "JS_ReaScriptAPI required for anchoring") end
        return false
    end
    anchor = opts
    -- Cache REAPER main window handle
    reaper_hwnd = reaper.GetMainHwnd()
    return true
end

function Core.ClearAnchor()
    anchor = nil
end

-- Called each frame to reposition window if anchored
function Core.UpdateAnchor()
    if not anchor or not reaper_hwnd or not win_hwnd then return end
    if not reaper.JS_Window_GetRect then return end

    local ok, r_left, r_top, r_right, r_bottom = reaper.JS_Window_GetRect(reaper_hwnd)
    if not ok then return end

    local r_w = r_right - r_left
    local r_h = r_bottom - r_top

    local target_x = r_left + math.floor(r_w * (anchor.x or 0)) + (anchor.offset_x or 0)
    local target_y = r_top + math.floor(r_h * (anchor.y or 0)) + (anchor.offset_y or 0)

    reaper.JS_Window_Move(win_hwnd, target_x, target_y)
end

-- Get the gfx window handle
function Core.GetHWND()
    if not win_hwnd and reaper.JS_Window_Find then
        win_hwnd = reaper.JS_Window_Find(win_title, true)
    end
    return win_hwnd
end

function Core.Run(loop_fn)
    user_loop_fn = loop_fn
    local function frame()
        -- Update state
        state.prev_mouse_x = state.mouse_x
        state.prev_mouse_y = state.mouse_y
        state.prev_mouse_cap = state.mouse_cap

        state.mouse_x = gfx.mouse_x
        state.mouse_y = gfx.mouse_y
        state.mouse_cap = gfx.mouse_cap
        state.mouse_wheel = gfx.mouse_wheel
        gfx.mouse_wheel = 0  -- consume wheel delta
        state.char = gfx.getchar()
        state.win_w = gfx.w
        state.win_h = gfx.h
        state.dock = gfx.dock(-1)
        state.frame = state.frame + 1

        -- Log: begin frame
        if Log then
            Log.HandleInput(state.char, state.mouse_wheel, state.mouse_y)
            Log.BeginFrame(state.frame, state)
        end

        -- Update anchor position (if overlay is anchored to REAPER)
        Core.UpdateAnchor()

        -- Reset hot widget each frame (widgets re-claim it)
        state.hot = nil

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

        -- End frame
        gfx.update()

        -- Check for close (ESC or window closed)
        if state.char >= 0 and state.char ~= 27 then
            reaper.defer(frame)
        else
            gfx.quit()
            if Core._on_close then Core._on_close() end
        end
    end

    frame()
end

function Core.OnClose(fn)
    Core._on_close = fn
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
