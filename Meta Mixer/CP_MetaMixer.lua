-- @description CP Studio — Cross-project mixer, item editor, unified hub
-- @author Cedric Music (music.music.music)
-- @version 1.0
-- @about
--   CP Studio: horizontal adaptive mixer for controlling volume, pan, mute,
--   solo, FX and transport across all open REAPER project tabs.
--   Item Editor with spectral waveform, bar grid, stretch markers,
--   pitch/stretch algorithm control, trim/fades, interactive SM,
--   selection/crop, reverse/loop/warp, context menu, shortcuts.
--   Take FX control, auto-subproject, glue, export.
--   Session View with item grid, subproject navigation.
--   FX Control with XY pad, param scanning, animated figures.
--   Tab system, persistence, licensing.
--   Docks at the bottom of REAPER.

local r = reaper

-- ============================================================================
-- MODULE LOADING
-- ============================================================================
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")

local C  = dofile(script_path .. "Modules/Constants.lua")
local H  = dofile(script_path .. "Modules/Helpers.lua")
local S  = dofile(script_path .. "Modules/State.lua")
local W  = dofile(script_path .. "Modules/Widgets.lua")
local MS = dofile(script_path .. "Modules/MixerStrip.lua")
local WF = dofile(script_path .. "Modules/Waveform.lua")
local BG = dofile(script_path .. "Modules/BarGrid.lua")
local PS = dofile(script_path .. "Modules/PitchStretch.lua")
local IE = dofile(script_path .. "Modules/ItemEditor.lua")
local FC = dofile(script_path .. "Modules/FXControl.lua")
local SV = dofile(script_path .. "Modules/SessionView.lua")

-- ============================================================================
-- LICENSE MANAGER (optional — graceful fallback if not present)
-- ============================================================================
local license_mgr = nil
local PRODUCT_ID = "CP_STUDIO"
local is_licensed = true  -- default to licensed if manager not found

local license_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_LicenseManager.lua"
if r.file_exists(license_path) then
    local ok, loader = pcall(dofile, license_path)
    if ok and loader then
        local mgr = loader()
        if mgr and mgr.init then
            mgr.init(r)
            license_mgr = mgr
            is_licensed = mgr.isLicensed(PRODUCT_ID)
        end
    end
end

-- ============================================================================
-- STYLE LOADER
-- ============================================================================
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then
    local loader_func = dofile(style_loader_path)
    if loader_func then style_loader = loader_func() end
end

-- ============================================================================
-- IMGUI CONTEXT
-- ============================================================================
local ctx = r.ImGui_CreateContext('CP Studio')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then style_loader.ApplyFontsToContext(ctx) end

-- ============================================================================
-- MODULE INITIALIZATION (dependency injection)
-- ============================================================================
S.init(r)
W.init(r, C, H, ctx)
MS.init(r, C, H, W, ctx)
WF.init(r, C, ctx)
BG.init(r, C, ctx)
PS.init(r, C, W, ctx)
IE.init(r, C, H, W, WF, BG, PS, S, ctx)
FC.init(r, C, H, W, S, ctx)
SV.init(r, C, H, S, ctx)

-- ============================================================================
-- PERSISTENCE — save/restore state via ExtState
-- ============================================================================
local EXT_SECTION = "CP_Studio"

local function LoadSettings()
    local tab = r.GetExtState(EXT_SECTION, "active_tab")
    if tab ~= "" then S.data.active_tab = tonumber(tab) or 0 end

    local stereo = r.GetExtState(EXT_SECTION, "stereo_mode")
    if stereo ~= "" then S.data.stereo_mode = stereo == "1" end
end

local function SaveSettings()
    r.SetExtState(EXT_SECTION, "active_tab", tostring(S.data.active_tab or 0), true)
    r.SetExtState(EXT_SECTION, "stereo_mode", S.data.stereo_mode and "1" or "0", true)
end

-- Load settings at startup
S.data.active_tab = 0  -- 0 = Mixer, 1 = Session, 2 = FX Control
LoadSettings()

-- ============================================================================
-- STYLE
-- ============================================================================
local function ApplyStyle()
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors = colors
            pushed_vars = vars
        end
    end
end

local function ClearStyle()
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
        pushed_colors = 0
        pushed_vars = 0
    end
end

-- ============================================================================
-- TAB BAR
-- ============================================================================
local TAB_NAMES = { "Mixer", "Session", "FX Control" }
local TAB_PAID  = { false,   true,      true }  -- Session and FX require license

local function DrawTabBar()
    if r.ImGui_BeginTabBar(ctx, "##cp_studio_tabs") then
        for i, name in ipairs(TAB_NAMES) do
            local tab_idx = i - 1
            local flags = 0
            -- Set the active tab on first frame
            if S.data.first_frame and tab_idx == (S.data.active_tab or 0) then
                flags = r.ImGui_TabItemFlags_SetSelected()
            end
            -- Mark paid tabs if not licensed
            local label = name
            if TAB_PAID[i] and not is_licensed then
                label = name .. " *"
            end
            local tab_open = r.ImGui_BeginTabItem(ctx, label .. "##tab_" .. i, nil, flags)
            if tab_open then
                if S.data.active_tab ~= tab_idx then
                    S.data.active_tab = tab_idx
                    SaveSettings()
                end
                r.ImGui_EndTabItem(ctx)
            end
        end
        r.ImGui_EndTabBar(ctx)
    end
end

-- ============================================================================
-- LICENSE ACTIVATION UI (inline, shown when unlicensed feature accessed)
-- ============================================================================
local license_key_buf = ""

local function DrawLicensePrompt()
    r.ImGui_TextDisabled(ctx, "This feature requires a CP Studio license.")
    r.ImGui_Spacing(ctx)

    if license_mgr then
        r.ImGui_Text(ctx, "License key:")
        r.ImGui_SetNextItemWidth(ctx, 280)
        local changed, new_val = r.ImGui_InputText(ctx, "##license_key", license_key_buf)
        if changed then license_key_buf = new_val end

        r.ImGui_SameLine(ctx, 0, 5)
        if r.ImGui_Button(ctx, "Activate##activate_btn") then
            license_mgr.setKey(PRODUCT_ID, license_key_buf)
            is_licensed = license_mgr.isLicensed(PRODUCT_ID)
        end

        -- Generate key button (dev)
        r.ImGui_SameLine(ctx, 0, 5)
        if r.ImGui_Button(ctx, "Gen##gen_key") then
            local key = license_mgr.generateKey(PRODUCT_ID, os.time())
            if key then license_key_buf = key end
        end
        if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, "Generate a license key (dev)")
        end

        local status = license_mgr.getStatus(PRODUCT_ID)
        if status == "INVALID" and license_key_buf ~= "" then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), C.COL_MUTE)
            r.ImGui_Text(ctx, "Invalid key — generate or enter a valid key, then click Activate")
            r.ImGui_PopStyleColor(ctx)
        elseif is_licensed then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), C.COL_PLAY)
            r.ImGui_Text(ctx, "Licensed!")
            r.ImGui_PopStyleColor(ctx)
        end
    else
        r.ImGui_TextDisabled(ctx, "License manager not found.")
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_TextDisabled(ctx, "The Mixer tab is free to use.")
end

-- ============================================================================
-- MIXER VIEW — all strips in one horizontal row, with culling
-- ============================================================================
local function DrawMixer()
    if #S.data.projects == 0 then
        r.ImGui_Text(ctx, "No projects open.")
        return
    end

    local first_strip = true
    for i, proj_data in ipairs(S.data.projects) do
        -- Separator between projects
        if not first_strip then
            r.ImGui_SameLine(ctx)
            r.ImGui_Text(ctx, "|")
            r.ImGui_SameLine(ctx)
        end
        first_strip = false

        -- Master FX (lazy: only scan FX for visible masters)
        local master_fx = {}
        local master_fx_count = r.TrackFX_GetCount(proj_data.master)
        for f = 0, master_fx_count - 1 do
            local _, fx_name = r.TrackFX_GetFXName(proj_data.master, f, "")
            local clean = fx_name:gsub("^VST3?i?: ", ""):gsub("^JS: ", ""):gsub(" %(.+%)$", "")
            if #clean > 10 then clean = clean:sub(1, 9) .. "." end
            master_fx[#master_fx + 1] = {
                name = clean,
                enabled = r.TrackFX_GetEnabled(proj_data.master, f),
                idx = f,
            }
        end

        -- Highlight active project
        if proj_data.is_active then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), C.COL_ACTIVE_BG)
        end

        MS.Draw({
            id = "M" .. i,
            name = proj_data.name,
            vol = proj_data.master_vol,
            pan = proj_data.master_pan,
            mute = proj_data.master_mute,
            solo = false,
            peak_l = proj_data.peak_l,
            peak_r = proj_data.peak_r,
            fx = master_fx,
            is_master = true,
            is_active = proj_data.is_active,
            track_ptr = proj_data.master,
            proj_ptr = proj_data.ptr,
            is_playing = proj_data.is_playing,
            play_pos = proj_data.play_pos,
            cursor_pos = proj_data.cursor_pos,
        })

        if proj_data.is_active then
            r.ImGui_PopStyleColor(ctx)
        end

        -- Expanded tracks for active project
        if proj_data.is_active and #proj_data.tracks > 0 then
            for t, trk in ipairs(proj_data.tracks) do
                r.ImGui_SameLine(ctx)
                MS.Draw({
                    id = "T" .. i .. "_" .. t,
                    name = trk.name,
                    vol = trk.vol,
                    pan = trk.pan,
                    mute = trk.mute,
                    solo = trk.solo,
                    peak_l = trk.peak_l,
                    peak_r = trk.peak_r,
                    color = trk.color,
                    fx = trk.fx,
                    sends = trk.sends,
                    is_master = false,
                    is_active = false,
                    track_ptr = trk.ptr,
                })
            end
        end
    end
end

-- ============================================================================
-- VIEW WRAPPERS
-- ============================================================================
local function DrawSession()
    if not is_licensed then
        DrawLicensePrompt()
        return
    end
    SV.Draw()
end

local function DrawFXControl()
    if not is_licensed then
        DrawLicensePrompt()
        return
    end
    FC.Draw()
end

-- ============================================================================
-- GLOBAL KEYBOARD SHORTCUTS
-- ============================================================================
local function HandleGlobalShortcuts()
    -- Space = toggle play/pause on active project
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space()) then
        local proj = S.data.active_proj
        if proj then
            local play_state = r.GetPlayStateEx(proj)
            if (play_state & 1) == 1 then
                r.OnPauseButtonEx(proj)
            else
                r.OnPlayButtonEx(proj)
            end
        end
    end

    -- Home = stop on active project
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Home()) then
        local proj = S.data.active_proj
        if proj then r.OnStopButtonEx(proj) end
    end

    -- Tab cycling: Ctrl+Tab / Ctrl+Shift+Tab
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Tab()) then
        local mods = r.ImGui_GetKeyMods(ctx)
        if mods == r.ImGui_Mod_Ctrl() then
            S.data.active_tab = ((S.data.active_tab or 0) + 1) % #TAB_NAMES
            SaveSettings()
        elseif mods == (r.ImGui_Mod_Ctrl() + r.ImGui_Mod_Shift()) then
            S.data.active_tab = ((S.data.active_tab or 0) - 1 + #TAB_NAMES) % #TAB_NAMES
            SaveSettings()
        end
    end
end

-- ============================================================================
-- STATUS BAR — bottom-line info
-- ============================================================================
local function DrawStatusBar()
    r.ImGui_Separator(ctx)

    -- Project count
    local proj_count = #S.data.projects
    r.ImGui_TextDisabled(ctx, string.format("%d project%s", proj_count, proj_count ~= 1 and "s" or ""))

    -- Active project info
    if S.data.active_proj then
        r.ImGui_SameLine(ctx, 0, 10)
        local proj_data = nil
        for _, pd in ipairs(S.data.projects) do
            if pd.is_active then proj_data = pd; break end
        end
        if proj_data then
            local status = proj_data.is_playing and "Playing" or "Stopped"
            local col = proj_data.is_playing and C.COL_PLAY or 0x888888FF
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col)
            r.ImGui_Text(ctx, status)
            r.ImGui_PopStyleColor(ctx)

            r.ImGui_SameLine(ctx, 0, 10)
            r.ImGui_TextDisabled(ctx, string.format("%d tracks", proj_data.track_count))
        end
    end

    -- License status
    if license_mgr then
        r.ImGui_SameLine(ctx, 0, 15)
        if is_licensed then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x4CAF5088)
            r.ImGui_Text(ctx, "Licensed")
            r.ImGui_PopStyleColor(ctx)
        else
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFF880088)
            r.ImGui_Text(ctx, "Free")
            r.ImGui_PopStyleColor(ctx)
        end
    end

    -- Version
    r.ImGui_SameLine(ctx, 0, 15)
    r.ImGui_TextDisabled(ctx, "v1.0")
end

-- ============================================================================
-- MAIN LOOP — with performance optimization
-- ============================================================================
local save_timer = 0

local function MainLoop()
    local now = r.time_precise()

    -- Refresh data — always collect project data at refresh interval
    if now - S.data.last_refresh >= C.REFRESH_INTERVAL then
        S.CollectProjectData()
        -- Only detect selected item when on Mixer tab (performance: skip for other tabs)
        local tab = S.data.active_tab or 0
        if tab == 0 then
            S.DetectSelectedItem()
        end
        S.data.last_refresh = now
    end

    -- Window setup
    if S.data.first_frame then
        r.ImGui_SetNextWindowSize(ctx, 900, 450, r.ImGui_Cond_FirstUseEver())
    end

    ApplyStyle()

    local window_flags = r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'CP Studio', true, window_flags)

    if visible then
        -- Global shortcuts
        HandleGlobalShortcuts()

        -- Tab bar
        DrawTabBar()

        -- Content based on active tab
        local tab = S.data.active_tab or 0

        if tab == 0 then
            -- MIXER TAB: strips + item editor
            DrawMixer()

            -- Item Editor panel (appears when an item is selected)
            if S.data.focused_item and S.data.item_info then
                IE.Draw()
            end

        elseif tab == 1 then
            DrawSession()

        elseif tab == 2 then
            DrawFXControl()
        end

        -- Status bar
        DrawStatusBar()

        r.ImGui_End(ctx)
    end

    ClearStyle()

    if S.data.first_frame then
        S.data.first_frame = false
    end

    -- Periodic save (every 5s)
    if now - save_timer > 5 then
        SaveSettings()
        save_timer = now
    end

    if open then
        r.defer(MainLoop)
    else
        SaveSettings()
    end
end

-- ============================================================================
-- START
-- ============================================================================
r.defer(MainLoop)
