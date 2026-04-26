-- Minimal drag test — isolate JS_API frameless drag
-- This tests ONLY the drag mechanism, nothing else.

gfx.init("Drag Test", 300, 100, 0, 200, 200)

-- Make frameless
local hwnd
if reaper.JS_Window_Find then
    hwnd = reaper.JS_Window_Find("Drag Test", true)
    if hwnd then
        reaper.JS_Window_SetStyle(hwnd, "POPUP")
        reaper.JS_Window_Resize(hwnd, 300, 100)
    end
end

local dragging = false
local start_mx, start_my = 0, 0
local start_wx, start_wy = 0, 0

local function frame()
    local char = gfx.getchar()
    if char < 0 or char == 27 then gfx.quit() return end

    -- Background
    gfx.set(0.15, 0.15, 0.18, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    -- Title bar area (top 30px)
    gfx.set(0.10, 0.10, 0.12, 1)
    gfx.rect(0, 0, gfx.w, 30, 1)

    -- Title
    gfx.set(0.8, 0.8, 0.8, 1)
    gfx.setfont(1, "Tahoma", 12, 0)
    gfx.x, gfx.y = 10, 8
    gfx.drawstr("Drag Test — Grab title bar to move")

    -- Status
    gfx.x, gfx.y = 10, 50
    if reaper.JS_Mouse_GetPosition then
        local sx, sy = reaper.JS_Mouse_GetPosition()
        gfx.drawstr(string.format("Screen mouse: %d, %d", sx, sy))
        gfx.x, gfx.y = 10, 65
        gfx.drawstr(string.format("Dragging: %s  hwnd: %s", tostring(dragging), tostring(hwnd ~= nil)))

        if hwnd then
            gfx.x, gfx.y = 10, 80
            local ok, wl, wt, wr, wb = reaper.JS_Window_GetRect(hwnd)
            gfx.drawstr(string.format("Window: %d, %d (%s)", wl or 0, wt or 0, tostring(ok)))
        end
    else
        gfx.drawstr("JS_ReaScriptAPI not found!")
    end

    -- Mouse interaction
    local mouse_down = (gfx.mouse_cap & 1) ~= 0
    local prev_down = dragging

    if not dragging and mouse_down and gfx.mouse_y < 30 then
        -- Start drag
        dragging = true
        if reaper.JS_Mouse_GetPosition then
            start_mx, start_my = reaper.JS_Mouse_GetPosition()
            if hwnd then
                local ok, wl, wt = reaper.JS_Window_GetRect(hwnd)
                if ok then
                    start_wx, start_wy = wl, wt
                end
            end
        end
    end

    if dragging then
        if mouse_down then
            if reaper.JS_Mouse_GetPosition and hwnd then
                local mx, my = reaper.JS_Mouse_GetPosition()
                local nx = start_wx + (mx - start_mx)
                local ny = start_wy + (my - start_my)
                reaper.JS_Window_Move(hwnd, nx, ny)
            end
        else
            dragging = false
        end
    end

    gfx.update()
    reaper.defer(frame)
end

frame()
