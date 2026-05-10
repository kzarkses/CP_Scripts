-- @description CP_PoopKit — Video Window drag POC
-- @version 0.1
-- @author Cedric Pamalio
--
-- Proof-of-concept: drag directly on the REAPER Video Window to drive
-- the cx/cy sliders of a Crop & Zoom video processor on the selected take.
-- Mouse wheel on the Video Window drives zoom.
--
-- HOW TO TEST
--   1. Select a media item with a video take.
--   2. Open the Video Window (View → Video).
--   3. Run this script. It will:
--        - insert "Video processor" on the take if missing
--        - paste the Crop & Zoom code into it
--        - open a small CP_Toolkit panel with status + latency
--   4. Left-click and drag inside the Video Window → cx/cy follow the cursor.
--   5. Mouse wheel inside the Video Window → zoom in/out.
--
-- The CP_Toolkit panel shows:
--   - whether interception is armed
--   - current cx / cy / zoom
--   - per-frame interception latency in ms

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local UI = dofile(script_path .. "../CP_Toolkit/CP_Toolkit.lua")

-- ============================================================================
-- Guards
-- ============================================================================
if not reaper.JS_Window_FindEx then
    reaper.MB("CP_PoopKit requires the JS_ReaScriptAPI extension.\n\n" ..
              "Install it via ReaPack: https://github.com/juliansader/ReaExtensions",
              "CP_PoopKit", 0)
    return
end

-- ============================================================================
-- Load the Crop & Zoom preset code from disk
-- ============================================================================
local preset_path = script_path .. "CropZoom.eel"
local preset_code
do
    local f = io.open(preset_path, "rb")
    if not f then
        reaper.MB("Could not open " .. preset_path, "CP_PoopKit", 0)
        return
    end
    preset_code = f:read("*a")
    f:close()
end

-- Param indices match the @param order in CropZoom.eel
local PARAM_CX         = 0
local PARAM_CY         = 1
local PARAM_ZOOM       = 2
local PARAM_ROT        = 3
local PARAM_FLIP       = 4
local PARAM_SHOW_FRAME = 5

-- How long the edit frame stays visible after the last interaction (seconds)
local FRAME_HOLD_TIME = 1.5

local FX_NAME = "Video processor"
local FX_TAG  = "CP_PoopKit_CropZoom"  -- used to identify our instance

-- ============================================================================
-- Find or create the VP on the selected take
-- ============================================================================
local function get_target_take()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then return nil end
    return reaper.GetActiveTake(item)
end

local function find_or_install_vp(take)
    if not take then return nil end
    local tagged = "// " .. FX_TAG .. "\n" .. preset_code
    local n = reaper.TakeFX_GetCount(take)
    for i = 0, n - 1 do
        local _, name = reaper.TakeFX_GetFXName(take, i)
        if name and name:find("Video processor", 1, true) then
            local _, code = reaper.TakeFX_GetNamedConfigParm(take, i, "VIDEO_CODE")
            if code and code:find(FX_TAG, 1, true) then
                -- Always rewrite so iteration on the preset takes effect
                reaper.TakeFX_SetNamedConfigParm(take, i, "VIDEO_CODE", tagged)
                return i
            end
        end
    end
    local idx = reaper.TakeFX_AddByName(take, FX_NAME, 1)
    if idx < 0 then return nil end
    reaper.TakeFX_SetNamedConfigParm(take, idx, "VIDEO_CODE", tagged)
    return idx
end

-- Active target — refreshed each frame to follow the user's selection.
local active_take, active_fx

-- Returns true if the active take/fx changed (or was lost).
local function refresh_target()
    local take = get_target_take()
    if take ~= active_take then
        active_take = take
        active_fx = take and find_or_install_vp(take) or nil
        return true
    end
    if active_take and not active_fx then
        active_fx = find_or_install_vp(active_take)
        return active_fx ~= nil
    end
    return false
end

refresh_target()

-- Open the Video Window only if it isn't already open. The View action 50125
-- is a toggle, so calling it on an already-open window would close it.
local function find_video_hwnd_quick()
    return reaper.JS_Window_Find("Video Window", true)
end
if not find_video_hwnd_quick() then
    reaper.Main_OnCommand(50125, 0)
end

-- ============================================================================
-- Find the Video Window HWND and start intercepting mouse messages
-- ============================================================================
local found_titles = {}  -- diagnostic: what windows we considered

local function find_video_hwnd()
    -- 1. Try the exact English title first.
    local hwnd = reaper.JS_Window_Find("Video Window", true)
    if hwnd then return hwnd end

    -- 2. Localized variants: scan all top-level windows containing common
    --    substrings ("video", "vidéo"). JS_Window_ArrayFind is case-insensitive.
    local candidates = {}
    for _, needle in ipairs({ "video window", "fenêtre vidéo", "video", "vidéo" }) do
        local arr = reaper.new_array(64)
        local n = reaper.JS_Window_ArrayFind(needle, false, arr)
        if n and n > 0 then
            for i = 1, n do
                local addr = arr[i]
                if addr and addr ~= 0 then
                    local h = reaper.JS_Window_HandleFromAddress(addr)
                    if h then candidates[#candidates + 1] = h end
                end
            end
        end
    end

    found_titles = {}
    for _, h in ipairs(candidates) do
        local title = reaper.JS_Window_GetTitle(h) or "?"
        found_titles[#found_titles + 1] = title
        -- Skip our own panel and any FX/processor edit windows.
        local low = title:lower()
        if not low:find("processor") and not low:find("poopkit") then
            -- Prefer something that has "video" or "vidéo" without "processor"
            if low:find("video") or low:find("vidéo") then
                return h
            end
        end
    end
    return nil
end

-- The mouse messages are typically received by the CHILD window that draws
-- the video, not the top-level "Video Window" frame. We need to find the
-- right child to intercept on.
local function pick_video_child(top_hwnd)
    if not top_hwnd then return nil end
    local arr = reaper.new_array(64)
    local n = reaper.JS_Window_ArrayAllChild(top_hwnd, arr)
    if not n or n == 0 then return top_hwnd end
    -- Pick the largest child (the video drawing area).
    local best, best_area = top_hwnd, 0
    for i = 1, n do
        local addr = arr[i]
        local h = addr and reaper.JS_Window_HandleFromAddress(addr) or nil
        if h then
            local ok, l, t, r, b = reaper.JS_Window_GetClientRect(h)
            if ok then
                local a = (r - l) * (b - t)
                if a > best_area then best, best_area = h, a end
            end
        end
    end
    return best
end

local video_hwnd = find_video_hwnd()
local mouse_hwnd = pick_video_child(video_hwnd)
local intercepted = false
local intercept_status = ""

local last_armed_hwnd = nil

local function arm_intercepts()
    if not mouse_hwnd or intercepted then return end

    -- Force-release any prior intercept on this window. Required because:
    --  * a previous run of this script may have leaked an intercept (script
    --    crashed / was reload-killed before atexit fired)
    --  * code 0 from InterceptList means "already intercepted by another
    --    script" — releasing first lets us reclaim it.
    if reaper.JS_Window_IsWindow(mouse_hwnd) then
        reaper.JS_WindowMessage_ReleaseWindow(mouse_hwnd)
    end
    if last_armed_hwnd and last_armed_hwnd ~= mouse_hwnd
            and reaper.JS_Window_IsWindow(last_armed_hwnd) then
        reaper.JS_WindowMessage_ReleaseWindow(last_armed_hwnd)
    end

    local list = table.concat({
        "WM_LBUTTONDOWN:passthrough",
        "WM_LBUTTONUP:passthrough",
        "WM_MOUSEMOVE:passthrough",
        "WM_MOUSEWHEEL:passthrough",
    }, ",")
    local ok = reaper.JS_WindowMessage_InterceptList(mouse_hwnd, list)
    if ok == 1 then
        intercepted = true
        intercept_status = "OK"
        last_armed_hwnd = mouse_hwnd
    else
        intercept_status = "fail code=" .. tostring(ok)
    end
end

local function release_intercepts()
    if video_hwnd and intercepted then
        reaper.JS_WindowMessage_ReleaseWindow(video_hwnd)
    end
    intercepted = false
end

-- ============================================================================
-- Drag state + slider drive
-- ============================================================================
local state = {
    cx   = 0.5,
    cy   = 0.5,
    zoom = 1.0,
    dragging = false,
    last_latency_ms = 0,

    -- Drag anchors: position when the click started, in normalized [0..1].
    -- The drag is relative — moving the mouse adds a delta to anchor_cx/cy
    -- so successive drags accumulate instead of jumping to absolute clicks.
    anchor_mx = 0,
    anchor_my = 0,
    anchor_cx = 0.5,
    anchor_cy = 0.5,

    -- Edit frame visibility: shown while interacting and for FRAME_HOLD_TIME
    -- seconds after the last input.
    last_interact = 0,
    frame_visible = false,
}

local function pull_state_from_fx()
    if not active_take or not active_fx then return end
    state.cx   = ({ reaper.TakeFX_GetParam(active_take, active_fx, PARAM_CX) })[1] or 0.5
    state.cy   = ({ reaper.TakeFX_GetParam(active_take, active_fx, PARAM_CY) })[1] or 0.5
    state.zoom = ({ reaper.TakeFX_GetParam(active_take, active_fx, PARAM_ZOOM) })[1] or 1.0
end
pull_state_from_fx()

local function set_param(idx, val)
    if not active_take or not active_fx then return end
    reaper.TakeFX_SetParam(active_take, active_fx, idx, val)
end

-- ============================================================================
-- Per-frame: poll the intercepted messages and drive the sliders
-- Peek returns 7 values: (retval, passedThrough, time, wParamLow, wParamHigh,
-- lParamLow, lParamHigh). retval=true just means the message type is being
-- intercepted; "time" is the timestamp of the last message — we detect new
-- messages by comparing it against the previously seen timestamp.
-- ============================================================================
local last_t = { down = 0, up = 0, move = 0, wheel = 0 }

local function peek(msg)
    local r, _, t, wl, wh, ll, lh =
        reaper.JS_WindowMessage_Peek(mouse_hwnd, msg)
    return r and t or 0, wl or 0, wh or 0, ll or 0, lh or 0
end

-- Convert pixel mouse position to normalized 0..1 inside the video window
-- (the wrapped client_to_norm does this; we keep separate helpers for the
-- relative drag delta below).
local function norm_delta(dx_px, dy_px)
    if not mouse_hwnd then return 0, 0 end
    local ok, l, t, r, b = reaper.JS_Window_GetClientRect(mouse_hwnd)
    if not ok then return 0, 0 end
    local w, h = r - l, b - t
    if w == 0 or h == 0 then return 0, 0 end
    return dx_px / w, dy_px / h
end

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

local function mark_interact()
    state.last_interact = reaper.time_precise()
end

local function poll_messages()
    if not mouse_hwnd or not intercepted then return end
    local t0 = reaper.time_precise()

    -- Mouse down → anchor the current cx/cy and the click pixel.
    -- Drag is then relative: future moves apply a delta from this anchor.
    local td, _, _, dl, dh = peek("WM_LBUTTONDOWN")
    if td ~= 0 and td ~= last_t.down then
        last_t.down = td
        state.dragging = true
        state.anchor_mx = dl
        state.anchor_my = dh
        state.anchor_cx = state.cx
        state.anchor_cy = state.cy
        mark_interact()
    end

    -- Mouse move → relative delta from the anchor.
    -- Sign is inverted on both axes so dragging right moves the framing
    -- target right (the picture follows the drag direction instead of
    -- scrolling against it).
    local tm, _, _, ml, mh = peek("WM_MOUSEMOVE")
    if tm ~= 0 and tm ~= last_t.move then
        last_t.move = tm
        if state.dragging then
            local dnx, dny = norm_delta(ml - state.anchor_mx, mh - state.anchor_my)
            -- Scale by 1/zoom so the on-screen pan matches the cursor speed
            -- regardless of how zoomed in we are.
            local nx = clamp01(state.anchor_cx - dnx / state.zoom)
            local ny = clamp01(state.anchor_cy - dny / state.zoom)
            state.cx, state.cy = nx, ny
            set_param(PARAM_CX, nx)
            set_param(PARAM_CY, ny)
            mark_interact()
        end
    end

    -- Mouse up → stop drag. cx/cy keep their last value, so the next click
    -- starts from where this one ended.
    local tu = peek("WM_LBUTTONUP")
    if tu ~= 0 and tu ~= last_t.up then
        last_t.up = tu
        state.dragging = false
        mark_interact()
    end

    -- Wheel → zoom. wParamHigh is the wheel delta (signed, multiples of 120).
    local tw, _, wh = peek("WM_MOUSEWHEEL")
    if tw ~= 0 and tw ~= last_t.wheel then
        last_t.wheel = tw
        local delta = wh
        if delta > 32767 then delta = delta - 65536 end
        local step = delta / 120
        state.zoom = state.zoom * (1 + step * 0.1)
        if state.zoom < 1 then state.zoom = 1 end
        if state.zoom > 8 then state.zoom = 8 end
        set_param(PARAM_ZOOM, state.zoom)
        mark_interact()
    end

    -- Drive the edit frame: visible while dragging or briefly after any input.
    local should_show = state.dragging or
        (reaper.time_precise() - state.last_interact < FRAME_HOLD_TIME)
    if should_show ~= state.frame_visible then
        state.frame_visible = should_show
        set_param(PARAM_SHOW_FRAME, should_show and 1 or 0)
    end

    state.last_latency_ms = (reaper.time_precise() - t0) * 1000
end

-- ============================================================================
-- CP_Toolkit status panel
-- ============================================================================
UI.Init("CP_PoopKit — Video Drag POC", 380, 220, { scale = 1 })

UI.Run(function()
    -- Follow user selection: if the selected take changes, switch target.
    if refresh_target() then
        pull_state_from_fx()
    end

    -- Re-validate the Video Window HWND each frame. JS_Window_IsWindow is the
    -- only reliable way to detect that the window was closed or destroyed.
    local needs_rearm = false
    if not video_hwnd or not reaper.JS_Window_IsWindow(video_hwnd) then
        video_hwnd = find_video_hwnd()
        mouse_hwnd = pick_video_child(video_hwnd)
        intercepted = false
        intercept_status = ""
        needs_rearm = true
    elseif not mouse_hwnd or not reaper.JS_Window_IsWindow(mouse_hwnd) then
        -- Parent still alive but child changed (resize, dock change, etc).
        mouse_hwnd = pick_video_child(video_hwnd)
        intercepted = false
        intercept_status = ""
        needs_rearm = true
    end

    -- If the intercept is supposedly armed but Peek returns retval=false, the
    -- system silently dropped it (window recreated, OS focus loss, etc).
    -- Re-arm in that case.
    if intercepted and mouse_hwnd then
        local r = reaper.JS_WindowMessage_Peek(mouse_hwnd, "WM_LBUTTONDOWN")
        if not r then
            intercepted = false
            needs_rearm = true
        end
    end

    if needs_rearm or not intercepted then
        arm_intercepts()
    end
    poll_messages()

    UI.SetFontH1()
    UI.Text("Video Window — Drag POC")
    UI.SetFontBody()

    if video_hwnd then
        UI.Text("Video Window: armed (" .. (intercepted and "intercept ON" or "intercept OFF") .. ")")
        local t = reaper.JS_Window_GetTitle(video_hwnd) or "?"
        UI.SetFontCaption()
        UI.Text("  parent → " .. t)
        if mouse_hwnd and mouse_hwnd ~= video_hwnd then
            local ct = reaper.JS_Window_GetTitle(mouse_hwnd) or ""
            UI.Text("  child  → " .. (ct == "" and "(no title)" or ct))
        else
            UI.Text("  child  → (same as parent)")
        end
        if intercept_status ~= "" then
            UI.Text("  intercept: " .. intercept_status)
        end
        UI.SetFontBody()
    else
        UI.Text("Video Window: not found")
        UI.SetFontCaption()
        if #found_titles == 0 then
            UI.Text("  No window matched. Is the Video Window open?")
        else
            UI.Text("  Candidates seen:")
            for i = 1, math.min(#found_titles, 6) do
                UI.Text("    • " .. found_titles[i])
            end
        end
        UI.SetFontBody()
    end

    if active_take then
        local _, tname = reaper.GetSetMediaItemTakeInfo_String(active_take, "P_NAME", "", false)
        UI.Text("Take: " .. (tname or ""))
    else
        UI.Text("Take: (no item selected)")
    end
    UI.Text(string.format("cx=%.3f  cy=%.3f  zoom=%.2f", state.cx, state.cy, state.zoom))
    UI.Text(string.format("dragging=%s   poll latency=%.2f ms",
        tostring(state.dragging), state.last_latency_ms))

    if UI.Button("reset", "Reset crop", { width = -1 }) then
        state.cx, state.cy, state.zoom = 0.5, 0.5, 1.0
        set_param(PARAM_CX, 0.5)
        set_param(PARAM_CY, 0.5)
        set_param(PARAM_ZOOM, 1.0)
    end
end)

local function cleanup()
    release_intercepts()
    -- Also release on the last armed HWND in case mouse_hwnd was nil'd out.
    if last_armed_hwnd and reaper.JS_Window_IsWindow(last_armed_hwnd) then
        reaper.JS_WindowMessage_ReleaseWindow(last_armed_hwnd)
    end
end

UI.OnClose(cleanup)
reaper.atexit(cleanup)  -- runs even if the script is killed externally
