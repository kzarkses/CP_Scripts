local TCPOverlay = {}

local r, Core

-- Cache
local tcp_hwnd = nil
local tcp_rect = nil
local tcp_panel_width = nil  -- TCP panel width (from SWS or fallback)
local last_tcp_update = 0
local TCP_UPDATE_INTERVAL = 0.05  -- 50ms throttle

function TCPOverlay.init(reaper_api, core)
    r = reaper_api
    Core = core
end

-- Get tracklist panel handle (cached)
-- The TCP is inside the arrange view, which is child window ID 1000 of the main HWND
local function getTCPHwnd()
    if tcp_hwnd then
        local ok = pcall(r.JS_Window_IsVisible, tcp_hwnd)
        if ok then return tcp_hwnd end
        tcp_hwnd = nil
    end

    local main = r.GetMainHwnd()
    if not main then return nil end

    -- Method 1: Manual HWND (user-configured)
    local manual = Core.config.tcp_overlay.window_hwnd
    if manual and manual ~= 0 then
        local ok, hwnd = pcall(r.JS_Window_HandleFromAddress, manual)
        if ok and hwnd then
            local ok2 = pcall(r.JS_Window_IsVisible, hwnd)
            if ok2 then
                tcp_hwnd = hwnd
                return hwnd
            end
        end
    end

    -- Method 2: Child ID 1000 (arrange/tracklist window in REAPER)
    if r.APIExists("JS_Window_FindChildByID") then
        local ok, hwnd = pcall(r.JS_Window_FindChildByID, main, 1000)
        if ok and hwnd then
            tcp_hwnd = hwnd
            return hwnd
        end
    end

    -- Method 3: FindChild by title
    if r.APIExists("JS_Window_FindChild") then
        local ok, hwnd = pcall(r.JS_Window_FindChild, main, "tracklist", true)
        if ok and hwnd then
            tcp_hwnd = hwnd
            return hwnd
        end
    end

    -- Method 4: Enumerate children, look for class containing "TrackList" or "REAPERTrack"
    if r.APIExists("JS_Window_ListAllChild") then
        local ok, list = pcall(r.JS_Window_ListAllChild, main)
        if ok and list and list ~= "" then
            for addr in list:gmatch("([^,]+)") do
                local num = tonumber(addr)
                if num then
                    local ok2, child = pcall(r.JS_Window_HandleFromAddress, num)
                    if ok2 and child then
                        local ok3, cls = pcall(r.JS_Window_GetClassName, child)
                        if ok3 and cls and (cls:find("Track") or cls:find("tracklist")) then
                            tcp_hwnd = child
                            return child
                        end
                    end
                end
            end
        end
    end

    -- Method 5: Fallback to main window (user calibrates with offsets)
    tcp_hwnd = main
    return main
end

-- List child windows (for settings UI - user picks the right one)
function TCPOverlay.listChildWindows()
    local main = r.GetMainHwnd()
    if not main then return {} end

    local windows = {}

    if not r.APIExists("JS_Window_ListAllChild") then return windows end

    local ok, list = pcall(r.JS_Window_ListAllChild, main)
    if not ok or not list or list == "" then return windows end

    local count = 0
    for addr in list:gmatch("([^,]+)") do
        local num = tonumber(addr)
        if num and count < 30 then  -- limit to 30
            local ok2, child = pcall(r.JS_Window_HandleFromAddress, num)
            if ok2 and child then
                local title = ""
                local cls = ""
                pcall(function()
                    title = r.JS_Window_GetTitle(child)
                    cls = r.JS_Window_GetClassName(child)
                end)
                -- Get rect for reference
                local rect_str = ""
                pcall(function()
                    local retval, l, t, ri, b = r.JS_Window_GetRect(child)
                    if retval then
                        rect_str = string.format("%dx%d", ri - l, b - t)
                    end
                end)
                windows[#windows + 1] = {
                    addr = num,
                    title = title or "",
                    class = cls or "",
                    size = rect_str,
                }
                count = count + 1
            end
        end
    end

    return windows
end

-- Set manual HWND
function TCPOverlay.setManualHwnd(addr)
    Core.config.tcp_overlay.window_hwnd = addr
    tcp_hwnd = nil  -- force re-detect
    tcp_rect = nil
end

-- Get current detected window info (for debug display)
function TCPOverlay.getDetectedInfo()
    if not tcp_hwnd then return "none" end
    local cls = ""
    local title = ""
    local addr = 0
    pcall(function()
        cls = r.JS_Window_GetClassName(tcp_hwnd)
        title = r.JS_Window_GetTitle(tcp_hwnd)
        addr = r.JS_Window_AddressFromHandle(tcp_hwnd)
    end)
    return string.format("[%s] %s (0x%X)", cls, title, addr or 0)
end

-- Update TCP panel rect (throttled)
function TCPOverlay.updateTCPRect()
    local now = r.time_precise()
    if (now - last_tcp_update) < TCP_UPDATE_INTERVAL and tcp_rect then
        return tcp_rect
    end
    last_tcp_update = now

    local hwnd = getTCPHwnd()
    if not hwnd then
        tcp_rect = nil
        return nil
    end

    local ok, retval, left, top, right, bottom = pcall(r.JS_Window_GetRect, hwnd)
    if ok and retval then
        tcp_rect = {
            left = left,
            top = top,
            right = right,
            bottom = bottom,
            width = right - left,
            height = bottom - top,
        }
    else
        tcp_rect = nil
    end

    -- Get TCP panel width from SWS extension (tracks the divider position)
    tcp_panel_width = nil
    if r.APIExists("SNM_GetIntConfigVar") then
        local w = r.SNM_GetIntConfigVar("leftpanewid", -1)
        if w > 0 then tcp_panel_width = w end
    end

    return tcp_rect
end

-- Get track's TCP clip area position (screen coordinates)
-- Uses I_TCPY/H for vertical, and TCP panel width for horizontal
-- (I_TCPW returns 0 on many themes, so we use SNM_GetIntConfigVar instead)
function TCPOverlay.getTrackTCPRect(track)
    if not track or not r.ValidatePtr(track, "MediaTrack*") then
        return nil
    end

    local tcpy = r.GetMediaTrackInfo_Value(track, "I_TCPY")
    local tcph = r.GetMediaTrackInfo_Value(track, "I_TCPH")

    if tcph <= 0 then return nil end

    local tr = tcp_rect
    if not tr then return nil end

    local ov = Core.config.tcp_overlay
    local w_ratio = math.max(0.05, math.min(1.0, ov.width_ratio or 0.5))

    local clip_w, clip_x
    if tcp_panel_width then
        -- SWS available: anchor to right side of TCP panel (follows divider)
        clip_w = math.floor(tcp_panel_width * w_ratio)
        clip_x = tr.left + tcp_panel_width - clip_w + (ov.offset_x or 0)
    else
        -- Fallback: use left portion of trackview with offset
        clip_w = math.floor(tr.width * w_ratio)
        clip_x = tr.left + (ov.offset_x or 0)
    end
    local clip_y = tr.top + tcpy + (ov.offset_y or 0)

    return {
        x = clip_x,
        y = clip_y,
        w = clip_w,
        h = tcph,
    }
end

-- Get bounding rect of all visible TCP clip areas (for single overlay window)
function TCPOverlay.getOverlayBounds()
    if not Core.config.tcp_overlay.enabled then return nil end

    local tr = TCPOverlay.updateTCPRect()
    if not tr then return nil end

    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    local has_any = false

    for _, column in ipairs(Core.state.columns) do
        local rect = TCPOverlay.getTrackTCPRect(column.track)
        if rect then
            if rect.y + rect.h > tr.top and rect.y < tr.bottom then
                min_x = math.min(min_x, rect.x)
                min_y = math.min(min_y, rect.y)
                max_x = math.max(max_x, rect.x + rect.w)
                max_y = math.max(max_y, rect.y + rect.h)
                has_any = true
            end
        end
    end

    if not has_any then return nil end

    return {
        x = min_x,
        y = min_y,
        w = max_x - min_x,
        h = max_y - min_y,
    }
end

-- Get all visible track positions relative to the overlay bounds
function TCPOverlay.getTrackPositions(bounds)
    if not bounds then return {} end

    local positions = {}
    local tr = tcp_rect
    if not tr then return positions end

    for i, column in ipairs(Core.state.columns) do
        local rect = TCPOverlay.getTrackTCPRect(column.track)
        if rect and rect.y + rect.h > tr.top and rect.y < tr.bottom then
            positions[i] = {
                x = rect.x - bounds.x,
                y = rect.y - bounds.y,
                w = rect.w,
                h = rect.h,
            }
        end
    end

    return positions
end

-- Convert screen coords to ImGui coords
function TCPOverlay.convertToImGui(ctx, screen_x, screen_y)
    if r.APIExists("ImGui_PointConvertNative") then
        local ok, rx, ry = pcall(r.ImGui_PointConvertNative, ctx, screen_x, screen_y)
        if ok then return rx, ry end
    end
    return screen_x, screen_y
end

return TCPOverlay
