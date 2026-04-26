local MixerOverlay = {}

local r, Core

-- Cache
local mixer_hwnd = nil
local mixer_rect = nil
local last_mixer_update = 0
local MIXER_UPDATE_INTERVAL = 0.05  -- 50ms throttle

function MixerOverlay.init(reaper_api, core)
    r = reaper_api
    Core = core
end

-- Get mixer window handle (cached, with fallback)
local function getMixerHwnd()
    if mixer_hwnd then
        -- Validate cached handle still exists
        local ok = pcall(r.JS_Window_IsVisible, mixer_hwnd)
        if ok then return mixer_hwnd end
        mixer_hwnd = nil
    end

    if not r.APIExists("JS_Window_Find") then
        return nil
    end

    -- Try "MCP" first (the actual MCP panel where strips are drawn)
    local ok, hwnd = pcall(r.JS_Window_Find, "MCP", true)
    if ok and hwnd then
        mixer_hwnd = hwnd
        return hwnd
    end

    -- Fallback: try "mixer" (the mixer window itself)
    ok, hwnd = pcall(r.JS_Window_Find, "mixer", true)
    if ok and hwnd then
        mixer_hwnd = hwnd
        return hwnd
    end

    return nil
end

-- Check if mixer is visible
function MixerOverlay.isMixerVisible()
    local state = r.GetToggleCommandState(40078)  -- View: Toggle mixer visible
    return state == 1
end

-- Update mixer window rect (throttled)
function MixerOverlay.updateMixerRect()
    local now = r.time_precise()
    if (now - last_mixer_update) < MIXER_UPDATE_INTERVAL and mixer_rect then
        return mixer_rect
    end
    last_mixer_update = now

    if not MixerOverlay.isMixerVisible() then
        mixer_rect = nil
        mixer_hwnd = nil  -- Reset handle when mixer closed
        return nil
    end

    local hwnd = getMixerHwnd()
    if not hwnd then
        mixer_rect = nil
        return nil
    end

    -- Use JS_Window_GetRect (same as Custom Toolbars - proven to work)
    local ok, retval, left, top, right, bottom = pcall(r.JS_Window_GetRect, hwnd)
    if ok and retval then
        mixer_rect = {
            left = left,
            top = top,
            right = right,
            bottom = bottom,
            width = right - left,
            height = bottom - top,
        }
    else
        mixer_rect = nil
    end

    return mixer_rect
end

-- Get track's mixer strip position (screen coordinates)
function MixerOverlay.getTrackMCPRect(track)
    if not track or not r.ValidatePtr(track, "MediaTrack*") then
        return nil
    end

    -- Check if track is visible in mixer
    local show_in_mixer = r.GetMediaTrackInfo_Value(track, "B_SHOWINMIXER")
    if show_in_mixer == 0 then return nil end

    local mcpx = r.GetMediaTrackInfo_Value(track, "I_MCPX")
    local mcpy = r.GetMediaTrackInfo_Value(track, "I_MCPY")
    local mcpw = r.GetMediaTrackInfo_Value(track, "I_MCPW")
    local mcph = r.GetMediaTrackInfo_Value(track, "I_MCPH")

    if mcpw <= 0 or mcph <= 0 then return nil end

    -- I_MCPX/Y are relative to the mixer panel
    -- Add mixer window rect origin to get screen coordinates
    local mr = mixer_rect
    if not mr then return nil end

    -- Apply calibration offsets
    local ov = Core.config.overlay
    local h_ratio = math.max(0.1, math.min(1.0, ov.height_ratio or 0.6))

    return {
        x = mr.left + mcpx + (ov.offset_x or 0),
        y = mr.top + mcpy + (ov.offset_y or 0),
        w = mcpw,
        h = math.floor(mcph * h_ratio),
    }
end

-- Convert screen coords to ImGui coords (handles DPI scaling)
function MixerOverlay.convertToImGui(ctx, screen_x, screen_y)
    if r.APIExists("ImGui_PointConvertNative") then
        local ok, rx, ry = pcall(r.ImGui_PointConvertNative, ctx, screen_x, screen_y)
        if ok then return rx, ry end
    end
    return screen_x, screen_y
end

-- Get all visible track overlay positions (screen coordinates)
function MixerOverlay.getOverlayPositions()
    local positions = {}

    if not Core.config.overlay.enabled then return positions end

    local mr = MixerOverlay.updateMixerRect()
    if not mr then return positions end

    for i, column in ipairs(Core.state.columns) do
        local rect = MixerOverlay.getTrackMCPRect(column.track)
        if rect then
            -- Clip to mixer bounds (only show if strip is visible)
            if rect.x + rect.w > mr.left and rect.x < mr.right then
                positions[i] = rect
            end
        end
    end

    return positions
end

-- Get scene column position (snapped to right of last visible strip)
function MixerOverlay.getSceneColumnPosition()
    if not Core.config.overlay.enabled then return nil end

    local mr = MixerOverlay.updateMixerRect()
    if not mr then return nil end

    -- Find the rightmost visible strip
    local rightmost_x = nil
    local ref_y = nil
    local ref_h = nil
    local ref_w = nil

    for _, column in ipairs(Core.state.columns) do
        local rect = MixerOverlay.getTrackMCPRect(column.track)
        if rect and rect.x + rect.w > mr.left and rect.x < mr.right then
            if not rightmost_x or (rect.x + rect.w) > rightmost_x then
                rightmost_x = rect.x + rect.w
                ref_y = rect.y
                ref_h = rect.h
                ref_w = rect.w
            end
        end
    end

    if not rightmost_x then return nil end

    -- Place scene column to the right of the last strip, same height
    local scene_w = math.min(ref_w or 80, 80)  -- narrower than track strips
    return {
        x = rightmost_x,
        y = ref_y,
        w = scene_w,
        h = ref_h,
    }
end

return MixerOverlay
