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
    gfx.setfont(1, face or "Tahoma", size or 12, flags or 0)
end

-- ============================================================================
-- FONT SLOTS (pre-loaded for instant switching)
-- ============================================================================
-- Slot 1=Title(bold), 2=H1, 3=H2, 4=Body(default), 5=Caption, 6=Mono, 7=H2Bold
local font_slots_loaded = false

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
end

function Core.SetFontTitle()    if font_slots_loaded then gfx.setfont(1) end end
function Core.SetFontH1()       if font_slots_loaded then gfx.setfont(2) end end
function Core.SetFontH2()       if font_slots_loaded then gfx.setfont(3) end end
function Core.SetFontBody()     if font_slots_loaded then gfx.setfont(4) end end
function Core.SetFontCaption()  if font_slots_loaded then gfx.setfont(5) end end
function Core.SetFontMono()     if font_slots_loaded then gfx.setfont(6) end end
function Core.SetFontH2Bold()   if font_slots_loaded then gfx.setfont(7) end end

-- Legacy aliases
function Core.SetFontPrimary()      Core.SetFontH1() end
function Core.SetFontSecondary()    Core.SetFontBody() end
function Core.SetFontTertiary()     Core.SetFontCaption() end
function Core.SetFontPrimaryBold()  Core.SetFontTitle() end

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

-- ============================================================================
-- CURSOR SYSTEM
-- ============================================================================
-- Set cursor for current frame. Reset to default at end of frame.
local cursor_this_frame = nil

function Core.SetCursor(cursor_type)
    cursor_this_frame = cursor_type
end

-- Apply cursor at end of frame (called by Core.Run)
local function apply_cursor()
    if cursor_this_frame then
        -- gfx.setcursor(resource_id, name)
        -- Common Windows cursor resource IDs:
        -- 32512 = arrow, 32513 = ibeam, 32514 = wait, 32515 = cross
        -- 32516 = uparrow, 32642 = sizenwse, 32643 = sizenesw
        -- 32644 = sizewe (horizontal resize), 32645 = sizens (vertical resize)
        -- 32646 = sizeall (move), 32649 = hand
        local cursors = {
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
        local cid = cursors[cursor_this_frame]
        if cid then gfx.setcursor(cid) end
    else
        gfx.setcursor(32512)  -- default arrow
    end
    cursor_this_frame = nil  -- reset for next frame
end

-- ============================================================================
-- ANIMATION SYSTEM
-- ============================================================================
-- Interpolates values over time. Call each frame, returns current value.
local animations = {}

function Core.Animate(id, target, speed, dt)
    speed = speed or 8  -- higher = faster
    dt = dt or 0.033    -- ~30fps default

    if not animations[id] then
        animations[id] = target  -- snap on first call
    end

    local current = animations[id]
    local diff = target - current

    if math.abs(diff) < 0.001 then
        animations[id] = target
        return target
    end

    -- Exponential ease-out
    animations[id] = current + diff * math.min(1, speed * dt)
    return animations[id]
end

function Core.AnimateColor(id, target_color, speed, dt)
    speed = speed or 8
    dt = dt or 0.033

    if not animations[id] then
        animations[id] = { target_color[1], target_color[2], target_color[3], target_color[4] or 1 }
    end

    local c = animations[id]

    for i = 1, 4 do
        local t = target_color[i] or (i == 4 and 1 or 0)
        local diff = t - c[i]
        if math.abs(diff) > 0.001 then
            c[i] = c[i] + diff * math.min(1, speed * dt)
        else
            c[i] = t
        end
    end

    return c[1], c[2], c[3], c[4]
end

function Core.GetAnimValue(id)
    return animations[id]
end

function Core.SetAnimValue(id, value)
    animations[id] = value
end

-- ============================================================================
-- FOCUS CHAIN (Tab navigation between widgets)
-- ============================================================================
local focus_chain = {}
local focus_chain_index = 0

function Core.RegisterFocusable(id)
    -- Add to chain if not already present
    for _, fid in ipairs(focus_chain) do
        if fid == id then return end
    end
    focus_chain[#focus_chain + 1] = id
end

function Core.FocusNext()
    if #focus_chain == 0 then return end
    focus_chain_index = focus_chain_index + 1
    if focus_chain_index > #focus_chain then focus_chain_index = 1 end
    state.focus = focus_chain[focus_chain_index]
end

function Core.FocusPrev()
    if #focus_chain == 0 then return end
    focus_chain_index = focus_chain_index - 1
    if focus_chain_index < 1 then focus_chain_index = #focus_chain end
    state.focus = focus_chain[focus_chain_index]
end

function Core.ClearFocusChain()
    focus_chain = {}
    focus_chain_index = 0
end

-- ============================================================================
-- PERSISTENT LAYOUT (save/load window state, splitter positions, etc.)
-- ============================================================================
function Core.SaveWindowState(script_id)
    local dock_state = gfx.dock(-1)
    local x, y, w, h
    if dock_state == 0 then
        -- Undocked: save position/size
        local _, wx, wy, ww, wh = gfx.dock(-1, 0, 0, 0, 0)
        x, y, w, h = wx, wy, ww, wh
    end

    reaper.SetExtState(script_id, "win_dock", tostring(dock_state), true)
    if x then
        reaper.SetExtState(script_id, "win_x", tostring(x), true)
        reaper.SetExtState(script_id, "win_y", tostring(y), true)
        reaper.SetExtState(script_id, "win_w", tostring(w), true)
        reaper.SetExtState(script_id, "win_h", tostring(h), true)
    end
end

function Core.LoadWindowState(script_id)
    local dock = tonumber(reaper.GetExtState(script_id, "win_dock")) or 0
    local x = tonumber(reaper.GetExtState(script_id, "win_x"))
    local y = tonumber(reaper.GetExtState(script_id, "win_y"))
    local w = tonumber(reaper.GetExtState(script_id, "win_w"))
    local h = tonumber(reaper.GetExtState(script_id, "win_h"))
    return { dock = dock, x = x, y = y, w = w, h = h }
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
-- NATIVE GFX DRAWING (exposed for toolkit use)
-- ============================================================================
function Core.DrawRoundRect(x, y, w, h, radius, r, g, b, a, antialias)
    gfx.set(r, g, b, a or 1)
    gfx.roundrect(x, y, w, h, radius, antialias ~= false and 1 or 0)
end

function Core.DrawCircle(x, y, radius, r, g, b, a, filled, antialias)
    gfx.set(r, g, b, a or 1)
    gfx.circle(x, y, radius, filled and 1 or 0, antialias ~= false and 1 or 0)
end

function Core.DrawTriangle(x1, y1, x2, y2, x3, y3, r, g, b, a)
    gfx.set(r, g, b, a or 1)
    gfx.triangle(x1, y1, x2, y2, x3, y3)
end

function Core.DrawArc(x, y, radius, ang1, ang2, r, g, b, a, antialias)
    gfx.set(r, g, b, a or 1)
    gfx.arc(x, y, radius, ang1, ang2, antialias ~= false and 1 or 0)
end

function Core.DrawGradientRect(x, y, w, h, r1, g1, b1, a1, r2, g2, b2, a2, vertical)
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

        -- Apply mouse cursor for this frame
        apply_cursor()

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
