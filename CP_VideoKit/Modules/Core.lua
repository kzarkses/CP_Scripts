-- CP_VideoKit / Core.lua
-- Take detection, FX scanning, install/remove of tagged Video Processors,
-- and Video Window mouse interception.

local Core = {}

local TAG_PREFIX = "CP_VideoKit_"  -- every module's tag must start with this
local FX_NAME    = "Video processor"

-- ============================================================================
-- Take detection
-- ============================================================================

function Core.get_selected_take()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then return nil end
    return reaper.GetActiveTake(item)
end

-- ============================================================================
-- FX scanning — find which CP_VideoKit modules are installed on a take.
-- Returns an ordered list of { fx_idx, tag, module_id }, where module_id is
-- looked up against the registry.
-- ============================================================================

function Core.read_video_code(take, fx_idx)
    local _, code = reaper.TakeFX_GetNamedConfigParm(take, fx_idx, "VIDEO_CODE")
    return code or ""
end

function Core.extract_tag(code)
    -- Tag is on the first line as "// CP_VideoKit_XXX"
    local tag = code:match("//%s*(" .. TAG_PREFIX .. "[%w_]+)")
    return tag
end

function Core.extract_custom_name(code)
    return code:match("//%s*NAME:%s*([^\n\r]+)")
end

function Core.scan_modules(take, registry)
    local result = {}
    if not take then return result end
    local n = reaper.TakeFX_GetCount(take)
    for i = 0, n - 1 do
        local _, name = reaper.TakeFX_GetFXName(take, i)
        if name and name:lower():find("video processor", 1, true) then
            local code = Core.read_video_code(take, i)
            local tag = Core.extract_tag(code)
            if tag then
                local mod_def = registry.find_by_tag(tag)
                if mod_def then
                    local custom = Core.extract_custom_name(code)
                    result[#result + 1] = {
                        fx_idx       = i,
                        tag          = tag,
                        module_id    = mod_def.id,
                        name         = mod_def.name,
                        custom_name  = custom,
                        display_name = custom and custom ~= "" and custom or mod_def.name,
                        bypassed     = not reaper.TakeFX_GetEnabled(take, i),
                    }
                end
            end
        end
    end
    return result
end

-- ============================================================================
-- Install / remove
-- ============================================================================

-- Rewrite the VIDEO_CODE of an existing module-tagged FX with the latest
-- preset on disk. Used at script startup so changes to .eel files are
-- picked up without forcing the user to re-add the module.
function Core.update_module_code(take, fx_idx, mod_def, preset_root)
    if not take or not mod_def then return false end
    local preset_path = preset_root .. mod_def.preset
    local f = io.open(preset_path, "rb")
    if not f then return false end
    local code = f:read("*a")
    f:close()

    -- Preserve any custom name set by the user across preset rewrites.
    local existing  = Core.read_video_code(take, fx_idx)
    local prev_name = Core.extract_custom_name(existing)

    local tagged = "// " .. mod_def.tag .. "\n"
    if prev_name and prev_name ~= "" then
        tagged = tagged .. "// NAME: " .. prev_name .. "\n"
    end
    tagged = tagged .. code
    reaper.TakeFX_SetNamedConfigParm(take, fx_idx, "VIDEO_CODE", tagged)
    return true
end

function Core.install_module(take, mod_def, preset_root)
    if not take or not mod_def then return nil end
    local preset_path = preset_root .. mod_def.preset
    local f = io.open(preset_path, "rb")
    if not f then
        reaper.MB("Could not load preset " .. preset_path, "CP_VideoKit", 0)
        return nil
    end
    local code = f:read("*a")
    f:close()

    local tagged = "// " .. mod_def.tag .. "\n" .. code
    local idx = reaper.TakeFX_AddByName(take, FX_NAME, 1)
    if idx < 0 then return nil end
    reaper.TakeFX_SetNamedConfigParm(take, idx, "VIDEO_CODE", tagged)
    return idx
end

function Core.remove_module(take, fx_idx)
    if not take or not fx_idx then return false end
    return reaper.TakeFX_Delete(take, fx_idx)
end

function Core.move_module(take, src_idx, dst_idx)
    -- TakeFX_CopyToTake with is_move=true reorders within a take
    if not take or src_idx == dst_idx then return false end
    return reaper.TakeFX_CopyToTake(take, src_idx, take, dst_idx, true)
end

-- ============================================================================
-- Bypass / enable
-- ============================================================================

function Core.is_bypassed(take, fx_idx)
    if not take then return false end
    return not reaper.TakeFX_GetEnabled(take, fx_idx)
end

function Core.set_bypassed(take, fx_idx, bypassed)
    if not take then return end
    reaper.TakeFX_SetEnabled(take, fx_idx, not bypassed)
end

-- ============================================================================
-- Custom name (stored as a 2nd-line comment in VIDEO_CODE: "// NAME: ...")
-- ============================================================================

function Core.get_custom_name(take, fx_idx)
    local code = Core.read_video_code(take, fx_idx)
    return code:match("//%s*NAME:%s*([^\n\r]+)")
end

function Core.set_custom_name(take, fx_idx, name)
    local code = Core.read_video_code(take, fx_idx)
    -- Strip any existing NAME comment
    code = code:gsub("//%s*NAME:%s*[^\n\r]*\r?\n", "")
    if name and name ~= "" then
        -- Insert NAME line right after the tag line (line 1).
        local first_line, rest = code:match("^(//[^\n]*)\n(.*)$")
        if first_line then
            code = first_line .. "\n// NAME: " .. name .. "\n" .. (rest or "")
        else
            code = "// NAME: " .. name .. "\n" .. code
        end
    end
    reaper.TakeFX_SetNamedConfigParm(take, fx_idx, "VIDEO_CODE", code)
end

-- ============================================================================
-- Param helpers
-- ============================================================================

function Core.get_param(take, fx_idx, p_idx)
    local v = reaper.TakeFX_GetParam(take, fx_idx, p_idx)
    return v
end

function Core.set_param(take, fx_idx, p_idx, val)
    reaper.TakeFX_SetParam(take, fx_idx, p_idx, val)
end

-- ============================================================================
-- Envelope helpers — clear points for a parameter, optionally within a range.
-- ============================================================================

-- Delete all envelope points for a single FX parameter on the take.
function Core.clear_envelope(take, fx_idx, p_idx, time_start, time_end)
    if not take then return false end
    local env = reaper.TakeFX_GetEnvelope(take, fx_idx, p_idx, false)
    if not env then return false end
    if time_start and time_end then
        reaper.DeleteEnvelopePointRange(env, time_start, time_end)
    else
        -- Delete all by passing an enormous range
        reaper.DeleteEnvelopePointRange(env, -1e10, 1e10)
    end
    reaper.Envelope_SortPoints(env)
    return true
end

-- Clear all envelopes for every parameter of an FX (used by "reset all" UI).
function Core.clear_fx_envelopes(take, fx_idx, time_start, time_end)
    if not take then return false end
    local count = reaper.TakeFX_GetNumParams(take, fx_idx)
    for p = 0, count - 1 do
        local env = reaper.TakeFX_GetEnvelope(take, fx_idx, p, false)
        if env then
            if time_start and time_end then
                reaper.DeleteEnvelopePointRange(env, time_start, time_end)
            else
                reaper.DeleteEnvelopePointRange(env, -1e10, 1e10)
            end
            reaper.Envelope_SortPoints(env)
        end
    end
    return true
end

function Core.get_time_selection()
    local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if s == e then return nil, nil end
    return s, e
end

-- ============================================================================
-- Video Window — find HWND, pick child, intercept mouse events
-- ============================================================================

local intercept = {
    video_hwnd      = nil,
    mouse_hwnd      = nil,
    armed_hwnd      = nil,
    intercepted     = false,
    status          = "",
    last_t          = { down = 0, up = 0, move = 0, wheel = 0 },
}

function Core.find_video_hwnd()
    local h = reaper.JS_Window_Find("Video Window", true)
    if h then return h end

    -- Localized fallback
    for _, needle in ipairs({ "fenêtre vidéo", "video", "vidéo" }) do
        local arr = reaper.new_array(64)
        local n = reaper.JS_Window_ArrayFind(needle, false, arr)
        if n and n > 0 then
            for i = 1, n do
                local addr = arr[i]
                if addr and addr ~= 0 then
                    local hh = reaper.JS_Window_HandleFromAddress(addr)
                    if hh then
                        local title = (reaper.JS_Window_GetTitle(hh) or ""):lower()
                        if (title:find("video") or title:find("vidéo"))
                                and not title:find("processor") then
                            return hh
                        end
                    end
                end
            end
        end
    end
    return nil
end

function Core.pick_video_child(top_hwnd)
    if not top_hwnd then return nil end
    local arr = reaper.new_array(64)
    local n = reaper.JS_Window_ArrayAllChild(top_hwnd, arr)
    if not n or n == 0 then return top_hwnd end
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

function Core.ensure_video_window_open()
    if not Core.find_video_hwnd() then
        reaper.Main_OnCommand(50125, 0)  -- View: Show video window
    end
end

local function release(hwnd)
    if hwnd and reaper.JS_Window_IsWindow(hwnd) then
        reaper.JS_WindowMessage_ReleaseWindow(hwnd)
    end
end

function Core.refresh_intercept()
    -- Re-validate parent
    if not intercept.video_hwnd or not reaper.JS_Window_IsWindow(intercept.video_hwnd) then
        intercept.video_hwnd  = Core.find_video_hwnd()
        intercept.mouse_hwnd  = Core.pick_video_child(intercept.video_hwnd)
        intercept.intercepted = false
    elseif not intercept.mouse_hwnd or not reaper.JS_Window_IsWindow(intercept.mouse_hwnd) then
        intercept.mouse_hwnd  = Core.pick_video_child(intercept.video_hwnd)
        intercept.intercepted = false
    end

    -- Health check: a Peek with retval=false means the OS dropped us.
    if intercept.intercepted and intercept.mouse_hwnd then
        local r = reaper.JS_WindowMessage_Peek(intercept.mouse_hwnd, "WM_LBUTTONDOWN")
        if not r then intercept.intercepted = false end
    end

    if not intercept.intercepted and intercept.mouse_hwnd then
        release(intercept.mouse_hwnd)
        if intercept.armed_hwnd ~= intercept.mouse_hwnd then
            release(intercept.armed_hwnd)
        end
        local list = "WM_LBUTTONDOWN:passthrough,WM_LBUTTONUP:passthrough," ..
                     "WM_MOUSEMOVE:passthrough,WM_MOUSEWHEEL:passthrough"
        local ok = reaper.JS_WindowMessage_InterceptList(intercept.mouse_hwnd, list)
        if ok == 1 then
            intercept.intercepted = true
            intercept.status      = "OK"
            intercept.armed_hwnd  = intercept.mouse_hwnd
        else
            intercept.status = "fail code=" .. tostring(ok)
        end
    end
end

local function peek(msg)
    if not intercept.mouse_hwnd then return 0, 0, 0, 0, 0 end
    local r, _, t, wl, wh, ll, lh =
        reaper.JS_WindowMessage_Peek(intercept.mouse_hwnd, msg)
    return r and t or 0, wl or 0, wh or 0, ll or 0, lh or 0
end

-- Returns a table of fresh events since last call:
-- { down={x,y}, up=true, move={x,y}, wheel=delta } — any/all may be missing.
function Core.poll_events()
    if not intercept.intercepted then return {} end
    local ev = {}
    local lt = intercept.last_t

    local td, _, _, dl, dh = peek("WM_LBUTTONDOWN")
    if td ~= 0 and td ~= lt.down then
        lt.down = td
        ev.down = { x = dl, y = dh }
    end

    local tm, _, _, ml, mh = peek("WM_MOUSEMOVE")
    if tm ~= 0 and tm ~= lt.move then
        lt.move = tm
        ev.move = { x = ml, y = mh }
    end

    local tu = peek("WM_LBUTTONUP")
    if tu ~= 0 and tu ~= lt.up then
        lt.up = tu
        ev.up = true
    end

    local tw, _, wh = peek("WM_MOUSEWHEEL")
    if tw ~= 0 and tw ~= lt.wheel then
        lt.wheel = tw
        local d = wh
        if d > 32767 then d = d - 65536 end
        ev.wheel = d / 120
    end

    return ev
end

-- Snapshot of modifier keys at the moment of the call. Format matches
-- gfx.mouse_cap: 4=Ctrl, 8=Shift, 16=Alt, 32=Win/Cmd.
function Core.get_modifiers()
    local s = reaper.JS_Mouse_GetState(0xFC) or 0
    return {
        ctrl  = (s & 4)  ~= 0,
        shift = (s & 8)  ~= 0,
        alt   = (s & 16) ~= 0,
    }
end

function Core.get_intercept_state()
    return {
        video_hwnd  = intercept.video_hwnd,
        mouse_hwnd  = intercept.mouse_hwnd,
        intercepted = intercept.intercepted,
        status      = intercept.status,
    }
end

function Core.client_size()
    if not intercept.mouse_hwnd then return 0, 0 end
    local ok, l, t, r, b = reaper.JS_Window_GetClientRect(intercept.mouse_hwnd)
    if not ok then return 0, 0 end
    return r - l, b - t
end

function Core.cleanup()
    release(intercept.armed_hwnd)
    release(intercept.mouse_hwnd)
    intercept.intercepted = false
end

return Core
