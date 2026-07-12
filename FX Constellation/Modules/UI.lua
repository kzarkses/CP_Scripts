-- ============================================================================
-- CP_FXConstellation — UI module (CP_Toolkit port, v2.0)
--
-- The whole interface is rendered through CP_Toolkit's gfx-based widgets.
-- Layout is fully theme-driven: every padding, gap, height and width is
-- derived from theme primitives (window_padding, item_spacing, button_height,
-- scale, …) so the Theme Tweaker can tune the look without touching code.
--
-- Sections, in order: SoundGen | Navigation | Mode | XY Pad | Presets |
-- Randomizer | FX Settings (flexible). Each is collapsible (click header).
-- The FX cards row uses CP_Toolkit's horizontal scrolling child.
-- ============================================================================

local UI = {}

-- ---------------------------------------------------------------------------
-- INIT
-- ---------------------------------------------------------------------------
function UI.init(reaper_api, core, fxmanager, gesture, presetsystem, persistence,
                 soundgen, license, fxmanagerui, toolkit)
    UI.r            = reaper_api
    UI.core         = core
    UI.fxmanager    = fxmanager
    UI.gesture      = gesture
    UI.presetsystem = presetsystem
    UI.persistence  = persistence
    UI.soundgen     = soundgen
    UI.license      = license
    UI.fxmanagerui  = fxmanagerui
    UI.tk           = toolkit

    UI.license_key_input = ""
    UI.license_msg = ""
    UI.license_msg_time = 0

    UI.fxbrowser_script = reaper_api.GetResourcePath()
        .. "/Scripts/CP_Scripts/FX Constellation/CP_FXBrowser.lua"
    UI.fxbrowser_cmd = 0

    UI.section_order = core.state.section_order or {
        "soundgen", "navigation", "mode", "pad", "lfo",
        "presets", "randomizer", "fx_settings"
    }
    -- Persisted orders from before the LFO section existed: graft it in
    -- right after the pad.
    local has_lfo = false
    for _, k in ipairs(UI.section_order) do
        if k == "lfo" then has_lfo = true break end
    end
    if not has_lfo then
        local pos = #UI.section_order + 1
        for i, k in ipairs(UI.section_order) do
            if k == "pad" then pos = i + 1 break end
        end
        table.insert(UI.section_order, pos, "lfo")
    end
    core.state.section_order = UI.section_order
end

-- Launch the standalone FX Browser script as its own REAPER window.
-- Resolves the named command id once (registers the script if needed) and
-- caches it. The browser stays open across calls — REAPER toggles a script's
-- defer loop, so we re-trigger only when it's not already running.
function UI.openFXBrowser()
    local r = UI.r
    if not r.file_exists(UI.fxbrowser_script) then return false end

    if UI.fxbrowser_cmd == 0 then
        UI.fxbrowser_cmd = r.NamedCommandLookup("_RS" .. UI.fxbrowser_script)
        if UI.fxbrowser_cmd == 0 then
            UI.fxbrowser_cmd = r.AddRemoveReaScript(true, 0,
                                                   UI.fxbrowser_script, true)
        end
    end
    if UI.fxbrowser_cmd == 0 then return false end

    local running = r.GetToggleCommandStateEx(0, UI.fxbrowser_cmd)
    if running ~= 1 then
        r.Main_OnCommand(UI.fxbrowser_cmd, 0)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Toolkit's slider `format` is a fixed display string (not a printf pattern),
-- so we render the value through string.format and pass the resulting text
-- on every frame.
local function fmtVal(pattern, value)
    return string.format(pattern, value)
end

-- All section widgets fill their column by default and share the same
-- vertical metric (`theme.button_height`) so checkboxes, sliders, combos
-- and buttons line up on the same row. The toolkit accepts opts.height /
-- opts.size on each widget — we set them here once for FX Constellation.
local function _commonOpts(opts, theme)
    opts = opts or {}
    if opts.width  == nil then opts.width  = -1 end
    if opts.height == nil then opts.height = theme.button_height end
    return opts
end

local function Btn(id, label, opts)
    return UI.tk.Button(id, label, _commonOpts(opts, UI.tk.GetTheme()))
end

local function Tgl(id, label, on, opts)
    return UI.tk.ToggleButton(id, label, on, _commonOpts(opts, UI.tk.GetTheme()))
end

local function Slid(id, label, value, mn, mx, opts)
    return UI.tk.SliderDouble(id, label, value, mn, mx,
        _commonOpts(opts, UI.tk.GetTheme()))
end

local function SlidInt(id, label, value, mn, mx, opts)
    return UI.tk.SliderInt(id, label, value, mn, mx,
        _commonOpts(opts, UI.tk.GetTheme()))
end

local function RngSlid(id, label, vmin, vmax, mn, mx, opts)
    return UI.tk.RangeSlider(id, label, vmin, vmax, mn, mx,
        _commonOpts(opts, UI.tk.GetTheme()))
end

local function ValRngSlid(id, label, value, vmin, vmax, mn, mx, opts)
    return UI.tk.ValueRangeSlider(id, label, value, vmin, vmax, mn, mx,
        _commonOpts(opts, UI.tk.GetTheme()))
end

local function Chk(id, label, checked, opts)
    local theme = UI.tk.GetTheme()
    opts = opts or {}
    -- Match button height by sizing the checkbox box to button_height.
    if opts.size == nil then opts.size = theme.button_height end
    return UI.tk.Checkbox(id, label, checked, opts)
end

local function Combo(id, label, idx, items, opts)
    return UI.tk.Combo(id, label, idx, items,
        _commonOpts(opts, UI.tk.GetTheme()))
end

local function Input(id, label, text, opts)
    return UI.tk.InputText(id, label, text,
        _commonOpts(opts, UI.tk.GetTheme()))
end

-- Default section widths, expressed as multiples of theme.button_height
-- so they scale with DPI / the theme tweaker. The user can override any
-- of these by dragging the inter-column splitters; overrides live in
-- core.state.section_widths_user (persisted via Persistence) and are
-- consulted before this default map.
local SECTION_DEFAULT_W = {
    soundgen     = 7.5,
    navigation   = 7.5,
    mode         = 6.0,
    pad          = 13.0,
    lfo          = 8.0,
    presets      = 8.0,
    randomizer   = 9.0,
    fx_settings  = 0,    -- 0 = remaining (flex)
}

local function sectionW(theme, key)
    local s = UI.core.state
    s.section_widths_user = s.section_widths_user or {}
    local user_w = s.section_widths_user[key]
    if user_w and user_w > 0 then return math.floor(user_w) end
    local mult = SECTION_DEFAULT_W[key] or 0
    return math.floor(mult * theme.button_height)
end

-- ---------------------------------------------------------------------------
-- STATUS BAR (track name + Lock + Settings, single row)
-- ---------------------------------------------------------------------------
local function drawStatusBar(theme)
    local UItk = UI.tk
    local s = UI.core.state

    local track_name = "—"
    if UI.core.isTrackValid() then
        local _, name = UI.r.GetSetMediaTrackInfo_String(s.track, "P_NAME", "", false)
        if name and name ~= "" then track_name = name end
    end

    -- 0 = flex (left), then two fixed buttons sized from theme.button_height.
    local btn_w = math.floor(theme.button_height * 2.5)
    UItk.BeginColumns("statusbar", { 0, btn_w, theme.button_height },
                     { gap = theme.item_spacing })

    UItk.SetFontH2Bold()
    UItk.Text("FX Constellation")
    UItk.SetFontBody()
    UItk.SameLine(theme.frame_padding_x)
    UItk.TextColored("— " .. track_name,
        theme.colors.text_disabled[1],
        theme.colors.text_disabled[2],
        theme.colors.text_disabled[3], 1)

    UItk.NextColumn()

    local _, locked = Tgl("lock_track",
        s.track_locked and "Unlock" or "Lock", s.track_locked)
    if locked ~= s.track_locked then
        if locked then
            s.track_locked, s.locked_track = true, s.track
        else
            s.track_locked, s.locked_track = false, nil
        end
    end

    UItk.NextColumn()
    if Btn("settings_btn", "S") then
        s.show_settings_window = not s.show_settings_window
    end

    UItk.EndColumns()
    UItk.Separator()
end

-- ---------------------------------------------------------------------------
-- SECTION HEADER (collapsible). Returns true if open.
-- ---------------------------------------------------------------------------
local function sectionHeader(key, label, theme, extra_text)
    local s = UI.core.state
    local is_open = not (s.section_collapsed[key] == true)
    local toggled, new_open = UI.tk.CollapsingHeader("hdr_" .. key, label, is_open)
    if toggled then
        s.section_collapsed[key] = not new_open
        UI.persistence.scheduleSave()
    end
    if extra_text and new_open then
        UI.tk.SameLine(theme.frame_padding_x)
        UI.tk.SetFontCaption()
        UI.tk.TextColored(extra_text,
            theme.colors.text_disabled[1],
            theme.colors.text_disabled[2],
            theme.colors.text_disabled[3], 1)
        UI.tk.SetFontBody()
    end
    return new_open
end

-- ---------------------------------------------------------------------------
-- SOUND GENERATOR
-- ---------------------------------------------------------------------------
local SG_WAVEFORMS = { "Sine", "Triangle", "Square", "Saw", "Noise", "Click" }

-- One oscillator's controls (Vital-style: wave / freq / width / volume per
-- osc). Widget ids are suffixed with the osc index so per-widget state
-- (inline edits, drag anchors) never leaks between tabs.
local function drawSoundGenOsc(sg, idx)
    local osc = sg.osc[idx]
    if not osc then return end
    local sfx = tostring(idx)

    local tc, tv = Tgl("sg_osc_on" .. sfx, osc.on and "● ON" or "○ OFF", osc.on)
    if tc then osc.on = tv; UI.soundgen.updateJSFXParams() end

    local cc, ci = Combo("sg_wf" .. sfx, "Wave", osc.wave + 1, SG_WAVEFORMS)
    if cc then osc.wave = ci - 1; UI.soundgen.updateJSFXParams() end

    if osc.wave < 4 then
        local fmin, fmax = math.log(20), math.log(20000)
        local norm = (math.log(osc.freq) - fmin) / (fmax - fmin)
        local fc, fv = Slid("sg_freq" .. sfx, "Freq", norm, 0, 1,
            { format = fmtVal("%.1f Hz", osc.freq) })
        if fc then
            osc.freq = math.exp(fmin + fv * (fmax - fmin))
            UI.soundgen.updateJSFXParams()
        end
    elseif osc.wave == 4 then
        local cc2, cv = Slid("sg_color" .. sfx, "Color", osc.color, 0, 1,
            { format = fmtVal("%.2f", osc.color) })
        if cc2 then osc.color = cv; UI.soundgen.updateJSFXParams() end
    end

    local wc, wv = Slid("sg_w" .. sfx, "Width", osc.width, 0, 100,
        { format = fmtVal("%.1f c", osc.width) })
    if wc then osc.width = wv; UI.soundgen.updateJSFXParams() end

    local vc, vv = Slid("sg_vol" .. sfx, "Vol", osc.vol, 0, 1,
        { format = fmtVal("%.2f", osc.vol) })
    if vc then osc.vol = vv; UI.soundgen.updateJSFXParams() end
end

local function drawSoundGen(theme)
    local UItk = UI.tk
    if not sectionHeader("soundgen", "SOUND GENERATOR", theme) then return end

    if not UI.license.isFull() then
        UItk.TextColored("🔒 Premium", 1.0, 0.7, 0.2, 1)
        if Btn("sg_act", "Activate License") then
            UI.core.state.show_license_window = true
        end
        return
    end

    local sg = UI.core.state.sound_generator

    -- Resync from the JSFX at 4 Hz instead of every frame (it walks all 31
    -- params through the API), and never while a mouse button is down: the
    -- sliders are stepped on the JSFX side, so a same-frame read-back
    -- quantizes the value under the user's drag.
    local now = UI.r.time_precise()
    if not UItk.Core.MouseDown(1)
       and now - (UI._sg_sync_time or 0) >= 0.25 then
        UI._sg_sync_time = now
        UI.soundgen.syncFromJSFX()
    end

    local toggled, _ = Tgl("sg_toggle",
        sg.enabled and "● ON" or "○ OFF", sg.enabled)
    if toggled then
        if not sg.enabled then UI.soundgen.createGenerator()
        else UI.soundgen.removeGenerator() end
        UI.fxmanager.scanTrackFX()
    end

    if not sg.enabled then return end

    if Btn("sg_mode", sg.mode == 0 and "Continuous" or "Triggered") then
        sg.mode = sg.mode == 0 and 1 or 0
        UI.soundgen.updateJSFXParams()
    end

    -- ---- Oscillator bank -------------------------------------------------
    local tab_changed, tab_idx = UItk.TabBar("sg_osc_tabs",
        { "OSC 1", "OSC 2", "OSC 3" }, sg.ui_osc_tab or 1)
    if tab_changed then sg.ui_osc_tab = tab_idx end
    drawSoundGenOsc(sg, sg.ui_osc_tab or 1)

    UItk.Separator()

    -- ---- Master ------------------------------------------------------------
    local ac, av = Slid("sg_amp", "Amp", sg.amplitude, 0, 1,
        { format = fmtVal("%.2f", sg.amplitude) })
    if ac then sg.amplitude = av; UI.soundgen.updateJSFXParams() end

    if sg.mode == 0 then
        local rc, rv = Chk("sg_rh", "Rhythmic", sg.rhythmic)
        if rc then sg.rhythmic = rv; UI.soundgen.updateJSFXParams() end
        if sg.rhythmic then
            local tc, tv = Slid("sg_tr", "Rate", sg.tick_rate, 0.1, 20,
                { format = fmtVal("%.2f Hz", sg.tick_rate) })
            if tc then sg.tick_rate = tv; UI.soundgen.updateJSFXParams() end
            local dc, dv = Slid("sg_du", "Duty", sg.duty_cycle, 0.01, 0.99,
                { format = fmtVal("%.2f", sg.duty_cycle) })
            if dc then sg.duty_cycle = dv; UI.soundgen.updateJSFXParams() end
            local cc, cv = Slid("sg_cur", "Curve", sg.rhythmic_curve, 0, 1,
                { format = fmtVal("%.2f", sg.rhythmic_curve) })
            if cc then sg.rhythmic_curve = cv; UI.soundgen.updateJSFXParams() end
        end
    else
        local ec, ev = Chk("sg_adsr", "ADSR", sg.use_adsr)
        if ec then sg.use_adsr = ev; UI.soundgen.updateJSFXParams() end
        if sg.use_adsr then
            local c, v = Slid("sg_a", "A", sg.attack, 0.001, 2,
                { format = fmtVal("%.3f s", sg.attack) })
            if c then sg.attack = v; UI.soundgen.updateJSFXParams() end
            c, v = Slid("sg_d", "D", sg.decay, 0.001, 2,
                { format = fmtVal("%.3f s", sg.decay) })
            if c then sg.decay = v; UI.soundgen.updateJSFXParams() end
            c, v = Slid("sg_s", "S", sg.sustain, 0, 1,
                { format = fmtVal("%.2f", sg.sustain) })
            if c then sg.sustain = v; UI.soundgen.updateJSFXParams() end
            c, v = Slid("sg_r", "R", sg.release, 0.001, 5,
                { format = fmtVal("%.3f s", sg.release) })
            if c then sg.release = v; UI.soundgen.updateJSFXParams() end
        end
        local mc, mv = Chk("sg_midi", "MIDI", sg.midi_mode)
        if mc then sg.midi_mode = mv; UI.soundgen.updateJSFXParams() end

        -- Hold-to-play: press-and-hold gate on the trigger param. The old
        -- button ignored its click entirely — setManualTrigger was never
        -- called from the UI, so Triggered mode was unplayable without MIDI.
        Btn("sg_play", UI._sg_play_held and "▶ PLAYING" or "HOLD TO PLAY")
        local hovered = UItk.IsItemHovered()
        local down = UItk.Core.MouseDown(1)
        if hovered and down and not UI._sg_play_held then
            UI._sg_play_held = true
            UI.soundgen.setManualTrigger(true)
        elseif UI._sg_play_held and not down then
            UI._sg_play_held = false
            UI.soundgen.setManualTrigger(false)
        end
        if UI._sg_play_held then
            -- Keep the loop awake while held so the release edge is caught
            -- even if nothing else animates.
            UItk.RequestRedraw()
        end
    end
end

-- ---------------------------------------------------------------------------
-- NAVIGATION
-- ---------------------------------------------------------------------------
local function drawPatternIcon(UItk, theme, x, y, size, pattern_id, active)
    local cx, cy = x + size / 2, y + size / 2
    local rad = size * 0.32
    local col = active and theme.colors.accent or theme.colors.text_disabled
    local r, g, b = col[1], col[2], col[3]
    if pattern_id == 0 then
        UItk.DrawCircle(cx, cy, rad, r, g, b, 1, false)
    elseif pattern_id == 1 then
        UItk.Core.DrawRect(cx - rad, cy - rad, rad * 2, rad * 2, r, g, b, 1, false)
    elseif pattern_id == 2 then
        local h = rad * 1.1
        UItk.DrawTriangle(cx, cy - h * 0.7,
                          cx - h * 0.6, cy + h * 0.5,
                          cx + h * 0.6, cy + h * 0.5,
                          r, g, b, 1)
    elseif pattern_id == 3 then
        UItk.DrawTriangle(cx, cy - rad,  cx + rad, cy,  cx, cy + rad, r, g, b, 1)
        UItk.DrawTriangle(cx, cy - rad,  cx - rad, cy,  cx, cy + rad, r, g, b, 1)
    elseif pattern_id == 4 then
        UItk.Core.DrawLine(cx - rad, cy + rad, cx + rad, cy - rad, r, g, b, 1)
        UItk.Core.DrawLine(cx - rad, cy - rad, cx + rad, cy + rad, r, g, b, 1)
    elseif pattern_id == 5 then
        UItk.DrawCircle(cx - rad * 0.5, cy, rad * 0.6, r, g, b, 1, false)
        UItk.DrawCircle(cx + rad * 0.5, cy, rad * 0.6, r, g, b, 1, false)
    end
end

local function drawNavigation(theme)
    local UItk = UI.tk
    local s = UI.core.state
    if not sectionHeader("navigation", "NAVIGATION", theme) then return end

    local nav_modes = UI.license.isFull()
        and UI.core.navigation_modes
        or { "Manual", "Random Walk 🔒", "Figures 🔒" }
    local cc, ci = Combo("nav_mode", "", s.navigation_mode + 1, nav_modes)
    if cc then
        local new_mode = ci - 1
        if (new_mode == 1 or new_mode == 2) and not UI.license.isFull() then
            s.navigation_mode = 0
            s.show_license_window = true
        else
            s.navigation_mode = new_mode
            if new_mode == 1 then
                s.random_walk_active = true
                s.random_walk_next_time = UI.r.time_precise() + 1.0 / s.random_walk_speed
                UI.gesture.generateRandomWalkControlPoints()
                UI.fxmanager.captureBaseValues()
            elseif new_mode == 2 then
                s.figures_active = true
                s.figures_time = 0
                UI.fxmanager.captureBaseValues()
            else
                s.random_walk_active = false
                s.figures_active = false
            end
            UI.persistence.scheduleSave()
        end
    end

    if s.navigation_mode == 0 then
        local c, v = Slid("nav_smooth", "Smooth", s.smooth_speed, 0, 1,
            { format = fmtVal("%.2f", s.smooth_speed) })
        if c then s.smooth_speed = v end
        c, v = Slid("nav_speed", "Speed", s.max_gesture_speed, 0.1, 10,
            { format = fmtVal("%.1f", s.max_gesture_speed) })
        if c then s.max_gesture_speed = v end
    elseif s.navigation_mode == 1 then
        -- Jump: teleport to random points instead of traveling to them.
        local jc, jv = Chk("rw_jump", "Jump", s.random_walk_jump)
        if jc then
            s.random_walk_jump = jv
            s.random_walk_last_slot = nil
            s.random_walk_next_time = UI.r.time_precise()
            UI.persistence.scheduleSave()
        end

        if s.random_walk_jump then
            local syncs = { "Free (Hz)", "1/16", "1/8", "1/4", "1/2", "1 bar" }
            local sc, si = Combo("rw_sync", "", (s.random_walk_sync or 0) + 1, syncs)
            if sc then
                s.random_walk_sync = si - 1
                s.random_walk_last_slot = nil
                s.random_walk_next_time = UI.r.time_precise()
                UI.persistence.scheduleSave()
            end
        end

        -- Speed/Jitter drive the bezier walk, and jump mode only in Free
        -- rate (beat-synced jumps follow the project tempo instead).
        if not s.random_walk_jump or (s.random_walk_sync or 0) == 0 then
            local c, v = Slid("rw_speed", "Speed", s.random_walk_speed, 0.1, 10,
                { format = fmtVal("%.1f Hz", s.random_walk_speed) })
            if c then
                s.random_walk_speed = v
                if s.random_walk_active then
                    s.random_walk_next_time = UI.r.time_precise() + 1.0 / s.random_walk_speed
                end
            end
            c, v = Slid("rw_jit", "Jitter", s.random_walk_jitter, 0, 1,
                { format = fmtVal("%.2f", s.random_walk_jitter) })
            if c then s.random_walk_jitter = v end
        end
    elseif s.navigation_mode == 2 then
        -- Pattern grid — square cells, manual hit-testing so the click
        -- zones line up exactly with the drawn icons (BeginGrid only
        -- gives screen rects; widgets like ToggleButton drift because
        -- they use the layout cursor instead).
        local cell = math.floor(theme.button_height * 1.4)
        UItk.BeginGrid("fig_grid",
            { cell_w = cell, cell_h = cell, gap = theme.item_spacing })
        for pid = 0, 5 do
            local px, py, pw, ph = UItk.GridCell("fig_grid")
            local active = s.figures_mode == pid
            local hovered = UItk.Core.MouseInRect(px, py, pw, ph)
                            and not UItk.Core.HasPopup()

            -- Background: accent for the active cell, hover tint, plain
            -- frame_bg otherwise (mirrors a flat ToggleButton look).
            local bg
            if active then bg = theme.colors.accent
            elseif hovered then bg = theme.colors.button_hovered
            else bg = theme.colors.frame_bg end
            UItk.Core.DrawRect(px, py, pw, ph, bg[1], bg[2], bg[3], bg[4] or 1)
            local bc = theme.colors.border
            UItk.Core.DrawRect(px, py, pw, ph, bc[1], bc[2], bc[3], bc[4] or 0.4, false)

            drawPatternIcon(UItk, theme, px, py, pw, pid, active)

            if hovered and UItk.Core.MouseClicked(1) then
                s.figures_mode = pid
                s.figures_time = 0
                UI.persistence.scheduleSave()
            end
        end
        UItk.EndGrid("fig_grid")

        local c, v = Slid("fig_speed", "Speed", s.figures_speed, 0.01, 10,
            { format = fmtVal("%.2f Hz", s.figures_speed) })
        if c then s.figures_speed = v; UI.persistence.scheduleSave() end
        c, v = Slid("fig_size", "Size", s.figures_size, 0.1, 1.0,
            { format = fmtVal("%.2f", s.figures_size) })
        if c then s.figures_size = v; UI.persistence.scheduleSave() end
    end

    -- Range = base+range expressed as a single dual-thumb slider. Drag the
    -- middle to translate the window (preserves span = move base value).
    local rc, rmin, rmax = RngSlid("gesture_rng", "Range",
        s.gesture_min, s.gesture_max, 0, 1, { format = "%.2f" })
    if rc then
        s.gesture_min = rmin
        s.gesture_max = rmax
        UI.persistence.scheduleSave()
    end

    UItk.BeginColumns("morph_row", { 0.5, 0.5 }, { gap = theme.item_spacing })
    if Btn("morph1", "Morph 1") then UI.gesture.captureToMorph(1) end
    UItk.NextColumn()
    if Btn("morph2", "Morph 2") then UI.gesture.captureToMorph(2) end
    UItk.EndColumns()

    if s.morph_preset_a and s.morph_preset_b then
        local mc, mv = Slid("morph_amt", "Morph", s.morph_amount or 0, 0, 1,
            { format = fmtVal("%.2f", s.morph_amount or 0) })
        if mc then
            s.morph_amount = mv
            UI.gesture.morphBetweenPresets(mv)
        end
    end

    if Btn("auto_jsfx", s.jsfx_automation_enabled and "Auto JSFX (ON)" or "Auto JSFX") then
        if s.jsfx_automation_enabled then
            -- Keep the index: the bridge FX (and its envelopes) stay on the
            -- track, only the coupling is switched off.
            s.jsfx_automation_enabled = false
        else
            UI.gesture.createAutomationJSFX()
        end
        UI.persistence.scheduleSave()
    end

    if Btn("show_env", "Show Env") then
        if not s.jsfx_automation_enabled or s.jsfx_automation_index < 0 then
            UI.gesture.createAutomationJSFX()
        end
        if s.jsfx_automation_enabled and s.jsfx_automation_index >= 0 then
            local x_env = UI.r.GetFXEnvelope(s.track, s.jsfx_automation_index, 0, true)
            local y_env = UI.r.GetFXEnvelope(s.track, s.jsfx_automation_index, 1, true)
            if x_env then UI.r.SetCursorContext(2, x_env) end
            if y_env then UI.r.SetCursorContext(2, y_env) end
        end
    end

    -- Linked mode: the gesture is compiled into native parameter links
    -- (target params follow the bridge at audio-block rate — modulable by
    -- envelopes, LFO/ACS, MIDI or third-party plugins, script closed or
    -- not). Single pad mode only; granular stays script-driven.
    local ltoggled, lstate = Tgl("linked_mode",
        s.links_active and ("Native Links (" .. (s.links_count or 0) .. ")")
        or "Native Links", s.linked_mode)
    if ltoggled and lstate ~= s.linked_mode then
        s.linked_mode = lstate
        s.links_dirty = true
        -- Both transitions RE-ANCHOR (sweep-side): the audible value at
        -- this instant becomes the base and the pad becomes the center.
        -- Replaying the script-mode math through the link can never be
        -- exact (asymmetric clamping, gesture min/max, step snapping) —
        -- freezing the present as the new reference is, by construction.
        s.links_reanchor = true
        if lstate then
            s.links_rebuild = true
        end
        UI.fxmanager.saveTrackSelection()
    end
    if s.linked_mode then
        if s.pad_mode == 1 then
            UItk.SetFontCaption()
            UItk.Text("Granular mode: links suspended")
            UItk.SetFontBody()
        end
        local slc, slv = Slid("link_slew", "Slew", s.link_slew or 0, 0, 2,
            { format = fmtVal("%.2f s", s.link_slew or 0) })
        if slc then
            s.link_slew = slv
            if UI.linkengine then UI.linkengine.applySlew() end
            UI.persistence.scheduleSave()
        end
    end
end

-- ---------------------------------------------------------------------------
-- MODE
-- ---------------------------------------------------------------------------
local function drawMode(theme)
    local UItk = UI.tk
    local s = UI.core.state
    if not sectionHeader("mode", "MODE", theme) then return end

    local _, single = Tgl("mode_single", "Single", s.pad_mode == 0)
    if single and s.pad_mode ~= 0 then
        s.pad_mode = 0
        s.links_dirty = true
        UI.persistence.scheduleSave()
    end

    if not UI.license.isFull() then
        if Btn("mode_gran_locked", "Granular 🔒") then
            s.show_license_window = true
        end
        return
    end

    local _, gran = Tgl("mode_gran", "Granular", s.pad_mode == 1)
    if gran and s.pad_mode ~= 1 then
        s.pad_mode = 1
        if not s.granular_grains or #s.granular_grains == 0 then
            UI.gesture.initializeGranularGrid()
        end
        s.links_dirty = true
        UI.persistence.scheduleSave()
    end

    if s.pad_mode == 1 then
        local sizes = { "2x2", "3x3", "4x4" }
        local vals = { 2, 3, 4 }
        local cur = 1
        for i, v in ipairs(vals) do if v == s.granular_grid_size then cur = i; break end end
        local cc, ci = Combo("gran_grid", "", cur, sizes)
        if cc then
            s.granular_grid_size = vals[ci]
            UI.gesture.initializeGranularGrid()
        end
        if Btn("gran_rnd", "Randomize") then
            if not s.granular_grains or #s.granular_grains == 0 then
                UI.gesture.initializeGranularGrid()
            else
                UI.gesture.randomizeGranularGrid()
            end
        end

        local nc, nv = Input("gran_name", "", s.granular_set_name,
            { hint = "Set name" })
        if nc then s.granular_set_name = nv end

        UItk.BeginColumns("gran_btns", { 0.5, 0.5 }, { gap = theme.item_spacing })
        if Btn("gran_save", "Save") and s.granular_set_name ~= "" then
            UI.presetsystem.saveGranularSet(s.granular_set_name)
        end
        UItk.NextColumn()
        if Btn("gran_load", "Load") and s.granular_set_name ~= "" then
            UI.presetsystem.loadGranularSet(s.granular_set_name)
        end
        UItk.EndColumns()

        local cur_preset = s.current_loaded_preset
        if cur_preset ~= "" and s.presets[cur_preset]
           and s.presets[cur_preset].granular_sets then
            UItk.BeginChild("gran_list", 0, theme.button_height * 4,
                { scrollable = true, border = true })
            for name, _ in pairs(s.presets[cur_preset].granular_sets) do
                UItk.BeginColumns("gr_" .. name, { 0, theme.button_height },
                    { gap = theme.item_spacing })
                if Btn("gload_" .. name, name) then
                    UI.presetsystem.loadGranularSet(name)
                    s.granular_set_name = name
                end
                UItk.NextColumn()
                if Btn("gdel_" .. name, "X") then
                    UI.presetsystem.deleteGranularSet(name)
                end
                UItk.EndColumns()
            end
            UItk.EndChild()
        end
    end
end

-- ---------------------------------------------------------------------------
-- XY PAD
-- ---------------------------------------------------------------------------
local function drawXYPad(theme)
    local UItk = UI.tk
    local s = UI.core.state
    if not sectionHeader("pad", "XY PAD", theme) then return end

    if Btn("pad_reset", "Reset") then
        s.gesture_x, s.gesture_y = 0.5, 0.5
        s.gesture_base_x, s.gesture_base_y = 0.5, 0.5
        UI.gesture.updateJSFXFromGesture()
        UI.fxmanager.captureBaseValues()
        if s.pad_mode == 1 then
            if not s.granular_grains or #s.granular_grains == 0 then
                UI.gesture.initializeGranularGrid()
            end
            UI.gesture.applyGranularGesture(s.gesture_x, s.gesture_y)
        else
            UI.gesture.applyGestureToSelection(s.gesture_x, s.gesture_y)
        end
    end

    -- Square pad sized to the actual available width of its column. Using
    -- Layout.GetAvailableWidth keeps it tight against the column edges even
    -- when the user resizes the window. Crosshair/grid are drawn manually
    -- below with stronger contrast than the toolkit Canvas defaults.
    local pad_size = UItk.GetAvailableWidth()
    if pad_size < 80 then pad_size = 80 end
    local canvas = UItk.Canvas("xy_pad", {
        width = pad_size, height = pad_size,
    })

    -- Center crosshair (more prominent than the Canvas built-in alpha=0.2).
    do
        local sc = theme.colors.separator
        local mid_x = canvas.x + math.floor(canvas.w / 2)
        local mid_y = canvas.y + math.floor(canvas.h / 2)
        UItk.Core.DrawLine(mid_x, canvas.y, mid_x, canvas.y + canvas.h,
            sc[1], sc[2], sc[3], 0.55)
        UItk.Core.DrawLine(canvas.x, mid_y, canvas.x + canvas.w, mid_y,
            sc[1], sc[2], sc[3], 0.55)
    end

    -- Granular grid (only in granular mode)
    if s.pad_mode == 1 then
        local grid = s.granular_grid_size or 3
        local sc = theme.colors.separator
        for i = 1, grid - 1 do
            local lx = canvas.x + math.floor(canvas.w * i / grid)
            local ly = canvas.y + math.floor(canvas.h * i / grid)
            UItk.Core.DrawLine(lx, canvas.y, lx, canvas.y + canvas.h,
                sc[1], sc[2], sc[3], 0.35)
            UItk.Core.DrawLine(canvas.x, ly, canvas.x + canvas.w, ly,
                sc[1], sc[2], sc[3], 0.35)
        end
    end

    if canvas.dragging or canvas.clicked then
        local cx = canvas.norm_x
        local cy = 1.0 - canvas.norm_y
        if not s.gesture_active then
            s.gesture_active = true
            s.gesture_base_x = s.gesture_x
            s.gesture_base_y = s.gesture_y
            UI.fxmanager.captureBaseValues()
            local dot_nx, dot_ny = s.gesture_x, 1.0 - s.gesture_y
            local dx = canvas.norm_x - dot_nx
            local dy = canvas.norm_y - dot_ny
            local dist = math.sqrt(dx * dx + dy * dy)
            -- Dead zone radius scaled to pad size: ~10% of edge.
            if dist <= 0.10 then
                s.click_offset_x = s.gesture_x - cx
                s.click_offset_y = s.gesture_y - cy
            else
                s.click_offset_x = 0
                s.click_offset_y = 0
            end
        end

        cx = clamp(cx + s.click_offset_x, 0, 1)
        cy = clamp(cy + s.click_offset_y, 0, 1)

        if s.navigation_mode == 1 then s.random_walk_active = false
        elseif s.navigation_mode == 2 then s.figures_active = false end

        if s.navigation_mode == 1 or s.navigation_mode == 2 or s.smooth_speed == 0 then
            s.gesture_x, s.gesture_y = cx, cy
            UI.gesture.updateJSFXFromGesture()
            if s.pad_mode == 1 then
                if not s.granular_grains or #s.granular_grains == 0 then
                    UI.gesture.initializeGranularGrid()
                end
                UI.gesture.applyGranularGesture(cx, cy)
            else
                UI.gesture.applyGestureToSelection(cx, cy)
            end
        else
            s.target_gesture_x = cx
            s.target_gesture_y = cy
        end
    elseif s.gesture_active and not canvas.dragging then
        s.gesture_active = false
        s.click_offset_x = 0
        s.click_offset_y = 0
    end

    -- Granular grains (only in granular mode)
    if s.pad_mode == 1 and s.granular_grains then
        local grid = s.granular_grid_size or 3
        for _, grain in ipairs(s.granular_grains) do
            local gx = canvas.x + grain.x * canvas.w
            local gy = canvas.y + (1.0 - grain.y) * canvas.h
            local gr = canvas.w / grid * 0.5
            UItk.DrawCircle(gx, gy, gr,
                theme.colors.text_disabled[1],
                theme.colors.text_disabled[2],
                theme.colors.text_disabled[3], 0.25, false)
            UItk.DrawCircle(gx, gy, 3,
                theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1, true)
        end
    end

    -- Cursor dot (size scales with the pad)
    local dot_r = math.max(4, math.floor(pad_size * 0.025))
    local dot_x = canvas.x + s.gesture_x * canvas.w
    local dot_y = canvas.y + (1.0 - s.gesture_y) * canvas.h
    UItk.DrawCircle(dot_x, dot_y, dot_r,
        theme.colors.accent[1], theme.colors.accent[2], theme.colors.accent[3], 1, true)
    UItk.DrawCircle(dot_x, dot_y, dot_r + 1,
        theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1, false)

    if s.navigation_mode == 0 and (s.smooth_speed or 0) > 0 then
        local tx = canvas.x + s.target_gesture_x * canvas.w
        local ty = canvas.y + (1.0 - s.target_gesture_y) * canvas.h
        UItk.DrawCircle(tx, ty, dot_r - 1,
            theme.colors.text_disabled[1],
            theme.colors.text_disabled[2],
            theme.colors.text_disabled[3], 0.6, false)
    end

    UItk.SetFontMono()
    UItk.Text(string.format("Position: %.2f, %.2f", s.gesture_x, s.gesture_y))
    UItk.SetFontBody()
end

-- ---------------------------------------------------------------------------
-- LFO (CP_Mod banks — shared LFOPanel, the JSFX windows stay closed)
-- ---------------------------------------------------------------------------
local function drawLFOSection(theme)
    local UItk = UI.tk
    local s = UI.core.state
    if not sectionHeader("lfo", "LFO", theme) then return end
    local le = UI.linkengine
    if not le or not UI.lfopanel then return end

    -- Track bank (per-track LFO, link sources) / Global bank (hidden CP MOD
    -- track, cross-track 14-bit CC) / Matrix (every CP-linked param).
    s.lfo_panel_mode = s.lfo_panel_mode or 1
    local tch, tidx = UItk.TabBar("lfo_mode_tabs", { "Track", "Global", "Matrix" },
        s.lfo_panel_mode)
    if tch then s.lfo_panel_mode = tidx end

    local mj = le.modjsfx

    local function touchedParam()
        -- Real last-touched param merged with the click-to-focus hint
        -- (param name clicks) — most recent event wins.
        local tr, fx, parm, name = mj.getFocusParam(UI.r)
        if not tr or mj.isInternalFX(name) then return nil end
        return tr, fx, parm, name
    end

    -- Locate an FXC-managed (CP-linked) param for inspector edits: those
    -- must route through the managers so the next sync stays consistent;
    -- anything else (other tracks, Map-made links) is written raw.
    local function findManagedParam(tr, fx, parm)
        if tr ~= s.track then return nil end
        for fid, fd in pairs(s.fx_data) do
            if (fd.actual_fx_id or fid) == fx then
                local pd = fd.params[parm]
                if pd and le.isParamLinked(fid, parm, pd) then
                    return fid, pd
                end
                return nil
            end
        end
        return nil
    end

    local function inspectParam(tr, fx, parm)
        return mj.getParamLink(UI.r, tr, fx, parm)
    end

    -- Registry/matrix rows come from CACHED scans: after an FX reorder or
    -- deletion the stored fx index can point at another plugin entirely.
    -- Never write through a stale target — require a live CP link on the
    -- exact (track, fx, param) before touching it.
    local function validTarget(tr, fx, parm)
        return tr and UI.r.ValidatePtr(tr, "MediaTrack*")
           and mj.getParamLink(UI.r, tr, fx, parm) ~= nil
    end

    local function setTargetBase(tr, fx, parm, v)
        if not validTarget(tr, fx, parm) then return end
        local fid = findManagedParam(tr, fx, parm)
        if fid then
            UI.fxmanager.updateParamBaseValue(fid, parm, v)
        else
            mj.setParamLinkBase(UI.r, tr, fx, parm, v)
        end
    end

    local function setTargetDepth(tr, fx, parm, v)
        if not validTarget(tr, fx, parm) then return end
        local fid = findManagedParam(tr, fx, parm)
        if fid then
            -- FXC-managed: depth = range × gesture_range, sign = invert.
            UI.fxmanager.setParamInvert(fid, parm, v < 0)
            UI.fxmanager.setParamRange(fid, parm,
                math.min(1, math.abs(v) / (s.gesture_range or 1)))
        else
            mj.setParamLinkDepth(UI.r, tr, fx, parm, v)
        end
    end

    -- Unlink from the registry: FXC-managed params also clear their
    -- mod_source so the sweep doesn't recreate the link.
    local function unlinkTarget(tr, fx, parm)
        if not validTarget(tr, fx, parm) then return end
        local fid = findManagedParam(tr, fx, parm)
        if fid then
            le.releaseParamLink(fid, parm)
            le.setParamModSource(fid, parm, 0)
        else
            mj.releaseParamLink(UI.r, tr, fx, parm)
            -- The param may be FXC-managed on ANOTHER track: purge its
            -- persisted mod_source too, or the next time that track is
            -- selected loadTrackSelection restores the entry and the
            -- sweep resurrects the link we just removed.
            if tr and UI.r.ValidatePtr(tr, "MediaTrack*") then
                local _, guid = UI.r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
                local td = guid and s.track_selections[guid]
                if td and td.mod_sources then
                    local _, fxname = UI.r.TrackFX_GetFXName(tr, fx, "")
                    local _, pname = UI.r.TrackFX_GetParamName(tr, fx, parm, "")
                    local key = fxname .. "||" .. pname
                    if td.mod_sources[key] then
                        td.mod_sources[key] = nil
                        s.param_mod_source[guid .. "_" .. key] = nil
                        UI.persistence.scheduleTrackSave()
                    end
                end
            end
        end
    end

    if s.lfo_panel_mode == 3 then
        UI.lfopanel.drawMatrix(theme, {
            tag = "matrix:" .. tostring(s.track),
            targets_all = function()
                return mj.scanAllTargets(UI.r, s.track)
            end,
            inspect = inspectParam,
            set_base = setTargetBase,
            set_depth = setTargetDepth,
            unlink = unlinkTarget,
        })
        return
    end

    local ctx
    if s.lfo_panel_mode == 2 then
        local mtrack, midx = le.findGlobalMIDI()
        ctx = {
            present = mtrack ~= nil and midx >= 0,
            hint = "Global bank: hidden CP MOD track, modulates ANY track through 14-bit CC.",
            tag = "global",
            get = le.getGlobalSlot,
            set = le.setGlobalSlot,
            add = function() le.ensureGlobalMIDI() end,
            sel = s.lfo_sel_slot or 1,
            onSelect = function(i) s.lfo_sel_slot = i end,
            touched = touchedParam,
            link = function(tr, fx, parm, slot)
                mj.linkParamToGlobalSlot(UI.r, tr, fx, parm, slot, 0.5)
                -- Param on OUR track: register the routing, otherwise the
                -- sweep sees a selected pad-assigned param and silently
                -- retargets the fresh Map link back to the bridge.
                if tr == s.track then
                    for fid, fd in pairs(s.fx_data) do
                        if (fd.actual_fx_id or fid) == fx and fd.params[parm] then
                            local pd = fd.params[parm]
                            if not pd.selected then
                                pd.selected = true
                                UI.fxmanager.updateSelectedCount()
                            end
                            le.setParamModSource(fid, parm,
                                le.GLOBAL_SLOT_BASE + slot)
                            break
                        end
                    end
                end
            end,
            inspect = inspectParam,
            set_base = setTargetBase,
            set_depth = setTargetDepth,
            targets = function(slot)
                return mj.scanSlotTargets(UI.r, "global", nil, slot)
            end,
            unlink = unlinkTarget,
        }
    else
        ctx = {
            present = (s.modlfo_index or -1) >= 0,
            hint = "Track LFO bank (CP_Mod). Right-click a param to follow a slot.",
            tag = "track:" .. tostring(s.track),
            get = le.getLFOSlot,
            set = le.setLFOSlot,
            add = function() le.ensureModLFO() end,
            sel = s.lfo_sel_slot or 1,
            onSelect = function(i) s.lfo_sel_slot = i end,
            touched = touchedParam,
            inspect = inspectParam,
            set_base = setTargetBase,
            set_depth = setTargetDepth,
            targets = function(slot)
                return mj.scanSlotTargets(UI.r, "lfo", s.track, slot)
            end,
            unlink = unlinkTarget,
        }
    end
    UI.lfopanel.draw(theme, ctx)
end

-- ---------------------------------------------------------------------------
-- PRESETS
-- ---------------------------------------------------------------------------
local function drawPresets(theme)
    local UItk = UI.tk
    local s = UI.core.state
    if not sectionHeader("presets", "PRESETS", theme) then return end

    local locked = not UI.license.isFull()

    UItk.BeginColumns("preset_btns", { 0.5, 0.5 }, { gap = theme.item_spacing })
    if Btn("psave", locked and "Save 🔒" or "Save") then
        if locked then s.show_license_window = true
        else
            if s.current_loaded_preset ~= "" then
                UI.presetsystem.savePreset(s.current_loaded_preset)
            else
                local ok, name = UI.r.GetUserInputs("Save preset", 1, "Name:", "")
                if ok and name ~= "" then
                    UI.presetsystem.savePreset(name)
                    s.current_loaded_preset = name
                    UI.fxmanager.saveTrackSelection()
                end
            end
        end
    end
    UItk.NextColumn()
    if Btn("psaveas", locked and "Save As 🔒" or "Save As") then
        if locked then s.show_license_window = true
        else
            local ok, name = UI.r.GetUserInputs("Save preset as", 1, "Name:",
                s.current_loaded_preset)
            if ok and name ~= "" then
                UI.presetsystem.savePreset(name)
                s.current_loaded_preset = name
                UI.fxmanager.saveTrackSelection()
            end
        end
    end
    UItk.EndColumns()

    local names = {}
    for n, _ in pairs(s.presets) do names[#names + 1] = n end
    table.sort(names)
    local cur_idx = 0
    for i, n in ipairs(names) do if n == s.current_loaded_preset then cur_idx = i; break end end

    if #names > 0 then
        local cc, ci = Combo("preset_pick", "", cur_idx, names)
        if cc and ci > 0 then
            if locked then s.show_license_window = true
            else UI.presetsystem.loadPreset(names[ci]) end
        end
    end

    UItk.BeginColumns("preset_act", { 0.5, 0.5 }, { gap = theme.item_spacing })
    if Btn("prn", locked and "Rename 🔒" or "Rename")
       and s.current_loaded_preset ~= "" then
        if locked then s.show_license_window = true
        else
            local ok, n = UI.r.GetUserInputs("Rename preset", 1, "New name:",
                s.current_loaded_preset)
            if ok and n ~= "" and n ~= s.current_loaded_preset then
                UI.presetsystem.renamePreset(s.current_loaded_preset, n)
                s.current_loaded_preset = n
                UI.fxmanager.saveTrackSelection()
            end
        end
    end
    UItk.NextColumn()
    if Btn("pdel", locked and "Delete 🔒" or "Delete")
       and s.current_loaded_preset ~= "" then
        if locked then s.show_license_window = true
        else
            local ans = UI.r.ShowMessageBox(
                "Delete preset '" .. s.current_loaded_preset .. "'?",
                "Delete preset", 4)
            if ans == 6 then
                UI.presetsystem.deletePreset(s.current_loaded_preset)
                s.current_loaded_preset = ""
            end
        end
    end
    UItk.EndColumns()

    UItk.SetFontH2Bold()
    UItk.Text(locked and "SNAPSHOTS 🔒" or "SNAPSHOTS")
    UItk.SetFontBody()
    UItk.Separator()

    local nc, nv = Input("snap_name", "", s.snapshot_name, { hint = "Snapshot name" })
    if nc then s.snapshot_name = nv end
    if Btn("snap_save", locked and "Save 🔒" or "Save") then
        if locked then s.show_license_window = true
        elseif s.snapshot_name and s.snapshot_name ~= "" then
            UI.presetsystem.saveSnapshot(s.snapshot_name)
        end
    end

    local cur = s.current_loaded_preset
    if cur ~= "" and s.presets[cur] and s.presets[cur].snapshots then
        UItk.BeginChild("snap_list", 0, theme.button_height * 5,
            { scrollable = true, border = true })
        for n, _ in pairs(s.presets[cur].snapshots) do
            UItk.BeginColumns("snap_" .. n,
                { 0, theme.button_height, theme.button_height },
                { gap = theme.item_spacing })
            if Btn("sl_" .. n, n) then
                if locked then s.show_license_window = true
                else
                    UI.presetsystem.loadSnapshot(n)
                    s.snapshot_name = UI.presetsystem.getNextSnapshotName()
                end
            end
            UItk.NextColumn()
            if Btn("sr_" .. n, "R") then
                local ok, nn = UI.r.GetUserInputs("Rename snapshot", 1, "Name:", n)
                if ok and nn ~= "" and nn ~= n
                   and s.presets[cur].snapshots[n] then
                    s.presets[cur].snapshots[nn] = s.presets[cur].snapshots[n]
                    s.presets[cur].snapshots[n] = nil
                    UI.persistence.schedulePresetSave()
                end
            end
            UItk.NextColumn()
            if Btn("sx_" .. n, "X") then
                UI.presetsystem.deleteSnapshot(n)
            end
            UItk.EndColumns()
        end
        UItk.EndChild()
    end
end

-- ---------------------------------------------------------------------------
-- RANDOMIZER
-- ---------------------------------------------------------------------------
local function drawRandomizer(theme)
    local UItk = UI.tk
    local s = UI.core.state
    if not sectionHeader("randomizer", "RANDOMIZER", theme) then return end

    if UI.license.isFull() then
        if Btn("ultra_rand", "ULTRA RANDOM",
               { height = math.floor(theme.button_height * 1.2) }) then
            UI.fxmanager.ultraRandom()
            UI.gesture.updateJSFXFromGesture()
        end
    end

    if Btn("rnd_fxorder", "FX Order") then
        UI.fxmanager.randomizeFXOrder()
    end

    UItk.BeginColumns("rnd_byp_row", { 0.5, 0.5 }, { gap = theme.item_spacing })
    if Btn("rnd_byp", "Bypass") then UI.fxmanager.randomBypassFX() end
    UItk.NextColumn()
    local bc, bv = Slid("rnd_byp_pct",
        "", s.random_bypass_percentage * 100, 0, 100,
        { format = fmtVal("%.0f%%", s.random_bypass_percentage * 100) })
    if bc then
        s.random_bypass_percentage = bv / 100
        UI.persistence.scheduleSave()
    end
    UItk.EndColumns()

    -- XY/checkbox in left half, N button in right half. The checkbox sits
    -- to the right of the XY button, sharing the left half evenly.
    UItk.BeginColumns("rnd_xy_row", { 0.5, 0.5 }, { gap = theme.item_spacing })
    UItk.BeginColumns("rnd_xy_left", { 0, theme.button_height },
                      { gap = theme.item_spacing })
    if Btn("rnd_xy", "XY") then UI.fxmanager.globalRandomXYAssign() end
    UItk.NextColumn()
    local ec, ev = Chk("rnd_excl", "", s.exclusive_xy)
    if ec then s.exclusive_xy = ev; UI.persistence.scheduleSave() end
    UItk.EndColumns()
    UItk.NextColumn()
    if Btn("rnd_inv", "N") then UI.fxmanager.globalRandomInvert() end
    UItk.EndColumns()

    -- Random modulation sources: each selected param rolls against the
    -- probability — hit → a random enabled global LFO (G1-8), miss → pad.
    UItk.BeginColumns("rnd_lfo_row", { 0.5, 0.5 }, { gap = theme.item_spacing })
    if Btn("rnd_lfo", "LFO") then UI.fxmanager.globalRandomLFOAssign() end
    UItk.NextColumn()
    local lc, lv = Slid("rnd_lfo_pct",
        "", (s.random_lfo_probability or 0) * 100, 0, 100,
        { format = fmtVal("%.0f%%", (s.random_lfo_probability or 0) * 100) })
    if lc then
        s.random_lfo_probability = lv / 100
        UI.persistence.scheduleSave()
    end
    UItk.EndColumns()

    if Btn("rnd_ranges", "Ranges") then UI.fxmanager.globalRandomRanges() end
    local rc, rmin, rmax = RngSlid("rnd_range",
        "", s.range_min, s.range_max, 0, 1, { format = "%.2f" })
    if rc then
        s.range_min = rmin
        s.range_max = rmax
        UI.persistence.scheduleSave()
    end

    if Btn("rnd_bases", "Bases") then UI.fxmanager.randomizeAllBases() end
    local ic, iv = Slid("rnd_intensity", "Int", s.randomize_intensity, 0, 1,
        { format = fmtVal("%.2f", s.randomize_intensity) })
    if ic then s.randomize_intensity = iv end
    local bc2, bmin, bmax = RngSlid("rnd_base_rng",
        "", s.randomize_min, s.randomize_max, 0, 1, { format = "%.2f" })
    if bc2 then
        s.randomize_min = bmin
        s.randomize_max = bmax
        UI.persistence.scheduleSave()
    end

    if Btn("rnd_params", "Parameters") then
        UI.fxmanager.globalRandomSelect()
        UI.fxmanager.saveTrackSelection()
    end

    UItk.BeginColumns("rnd_pcount", { 0.5, 0.5 }, { gap = theme.item_spacing })
    local mc, mv = SlidInt("rnd_pmin", "", s.random_min, 1, 300)
    if mc then s.random_min = mv end
    UItk.NextColumn()
    local mc2, mv2 = SlidInt("rnd_pmax", "", s.random_max, 1, 300)
    if mc2 then s.random_max = math.max(mv2, s.random_min) end
    UItk.EndColumns()
end

-- ---------------------------------------------------------------------------
-- PARAM MODULATION MENU (right-click on a param row)
-- Assign the param's modulation source (Pad X/Y/XY or a CP_Mod LFO slot)
-- and drive REAPER's native per-param LFO — which stacks ON TOP of the
-- link, so "LFO + pad shifts it proportionally" works out of the box.
-- ---------------------------------------------------------------------------
local LFO_SHAPES = { "Sine", "Square", "Saw L>R", "Saw R>L", "Triangle", "Random" }
local LFO_SPEEDS_HZ = { 0.1, 0.25, 0.5, 1, 2, 4, 8 }
-- Native LFO tempo-sync speed is assumed to be in LFO cycles per quarter
-- note (1/4 → 1.0). If runtime shows otherwise, adjust this table only.
local LFO_SYNCS = {
    { label = "1/16",   speed = 4 },
    { label = "1/8",    speed = 2 },
    { label = "1/4",    speed = 1 },
    { label = "1/2",    speed = 0.5 },
    { label = "1 bar",  speed = 0.25 },
    { label = "2 bars", speed = 0.125 },
}
local LFO_STRENGTHS = { 0.1, 0.25, 0.5, 1.0 }

local function openParamModMenu(fx_id, param_id, param_data)
    local UItk = UI.tk
    local s = UI.core.state
    local le = UI.linkengine
    if not le then return end

    local src = le.getParamModSource(fx_id, param_id)
    local x_ass, y_ass = UI.fxmanager.getParamXYAssign(fx_id, param_id)
    local lfo = le.getParamLFO(fx_id, param_id) or
        { active = false, shape = 0, speed = 1, strength = 0.25, temposync = false }

    -- Direct map writes: the menu expresses an explicit choice, so the
    -- exclusive-XY auto-clear of setParamXYAssign must not interfere.
    local function followPad(x, y)
        -- Release the LFO link explicitly: the sweep deliberately leaves
        -- CP_Mod links without a mod_source entry alone (Map-made links).
        le.releaseParamLink(fx_id, param_id)
        le.setParamModSource(fx_id, param_id, 0)
        local x_key = UI.core.getParamKey(fx_id, param_id, "x")
        local y_key = UI.core.getParamKey(fx_id, param_id, "y")
        if x_key then s.param_xy_assign[x_key] = x end
        if y_key then s.param_xy_assign[y_key] = y end
        UI.fxmanager.saveTrackSelection()
    end

    local function followLFO(slot)
        le.setParamModSource(fx_id, param_id, slot)
        if not param_data.selected then
            -- Selection gates modulation — assigning a source implies it.
            param_data.selected = true
            UI.fxmanager.updateSelectedCount()
            UI.fxmanager.saveTrackSelection()
        end
        if slot > le.GLOBAL_SLOT_BASE then
            le.ensureGlobalMIDI()
        else
            le.ensureModLFO()
        end
    end

    local lfo_children = {}
    for i = 1, 8 do
        lfo_children[i] = {
            label = "CP LFO " .. i,
            checked = src == i,
            action = function() followLFO(i) end,
        }
    end

    local global_children = {}
    for i = 1, 8 do
        global_children[i] = {
            label = "Global LFO " .. i,
            checked = src == le.GLOBAL_SLOT_BASE + i,
            action = function() followLFO(le.GLOBAL_SLOT_BASE + i) end,
        }
    end

    local shape_children = {}
    for i, name in ipairs(LFO_SHAPES) do
        shape_children[i] = {
            label = name,
            checked = lfo.shape == i - 1,
            action = function() le.setParamLFO(fx_id, param_id, { shape = i - 1 }) end,
        }
    end
    local speed_children = {}
    for i, hz in ipairs(LFO_SPEEDS_HZ) do
        speed_children[i] = {
            label = hz .. " Hz",
            checked = not lfo.temposync and math.abs(lfo.speed - hz) < 0.001,
            action = function()
                le.setParamLFO(fx_id, param_id, { speed = hz, temposync = false })
            end,
        }
    end
    local sync_children = {}
    for i, sy in ipairs(LFO_SYNCS) do
        sync_children[i] = {
            label = sy.label,
            checked = lfo.temposync and math.abs(lfo.speed - sy.speed) < 0.001,
            action = function()
                le.setParamLFO(fx_id, param_id, { speed = sy.speed, temposync = true })
            end,
        }
    end
    local strength_children = {}
    for i, st in ipairs(LFO_STRENGTHS) do
        strength_children[i] = {
            label = math.floor(st * 100) .. "%",
            checked = math.abs(lfo.strength - st) < 0.005,
            action = function() le.setParamLFO(fx_id, param_id, { strength = st }) end,
        }
    end

    UItk.NativeMenu({
        { label = param_data.name or "?", disabled = true },
        { separator = true },
        { label = "Follow Pad X", checked = src == 0 and x_ass and not y_ass,
          action = function() followPad(true, false) end },
        { label = "Follow Pad Y", checked = src == 0 and y_ass and not x_ass,
          action = function() followPad(false, true) end },
        { label = "Follow Pad XY", checked = src == 0 and x_ass and y_ass,
          action = function() followPad(true, true) end },
        { label = "Follow CP LFO", children = lfo_children },
        { label = "Follow Global LFO", children = global_children },
        { separator = true },
        { label = "Param LFO (native)", children = {
            { label = lfo.active and "Disable" or "Enable",
              checked = lfo.active,
              action = function()
                  le.setParamLFO(fx_id, param_id, { active = not lfo.active })
              end },
            { label = "Shape", children = shape_children },
            { label = "Speed (Hz)", children = speed_children },
            { label = "Tempo sync", children = sync_children },
            { label = "Strength", children = strength_children },
        } },
        { separator = true },
        { label = "Edit CP LFO bank...", action = function()
            -- Opens OUR LFO section (toolkit UI) — internal JSFX windows
            -- stay closed.
            le.ensureModLFO()
            s.section_collapsed.lfo = false
            UI.persistence.scheduleSave()
        end },
    })
end

-- ---------------------------------------------------------------------------
-- PARAM ROW (one row per FX parameter inside an FX card)
-- ---------------------------------------------------------------------------
local function drawParamRow(theme, fx_id, param_id, param_data)
    local UItk = UI.tk

    -- Widget ids are hit every frame for every visible row: cache the
    -- concatenations on the param table (fx_data is rebuilt on scan, so the
    -- cache can never go stale).
    local id = param_data._uid
    if not id then
        id = "p_" .. fx_id .. "_" .. param_id
        param_data._uid = id
        param_data._uid_sel = id .. "_sel"
        param_data._uid_n = id .. "_n"
        param_data._uid_x = id .. "_x"
        param_data._uid_y = id .. "_y"
        param_data._uid_src = id .. "_src"
        param_data._uid_vr = id .. "_vrng"
    end

    -- Row screen rect, captured before layout for the right-click hit test.
    local row_x, row_y = UItk.GetCursorPos()
    local row_w = UItk.GetAvailableWidth()

    -- Current modulation source: 0 = pad, 1..8 = track LFO, 101..108 = global.
    local le = UI.linkengine
    local src_slot = (le and le.getParamModSource(fx_id, param_id)) or 0

    -- All toggle/checkbox cells use 1 unit (button_height) — tight row.
    -- The select cell must be button_height wide: the Chk helper sizes the
    -- box to button_height, so a checkbox_size column truncated it.
    UItk.BeginColumns(id,
        { theme.button_height, 0,
          theme.button_height, theme.button_height, theme.button_height,
          theme.button_height,
          0.5 },  -- last column = remaining ~half of row for the slider
        { gap = theme.item_spacing })

    local cc, cv = Chk(param_data._uid_sel, "", param_data.selected)
    if cc then
        param_data.selected = cv
        UI.fxmanager.updateSelectedCount()
        if cv then param_data.base_value = param_data.current_value end
        UI.fxmanager.saveTrackSelection()
    end
    UItk.NextColumn()

    -- Param name: clicking it FOCUSES the param (cross-script touch hint)
    -- so the CP LFO inspector locks onto it without wiggling its value —
    -- and while Map is armed, a name click maps it directly.
    local name = param_data.name or "?"
    UItk.Text(name)
    if UItk.IsItemHovered() then
        UItk.SetCursor("hand")
        UItk.Tooltip(name .. "\nClick: focus as modulation target")
        if UItk.IsItemClicked() and le then
            le.modjsfx.pokeTouch(UI.r, UI.core.state.track,
                param_data.actual_fx_id, param_id)
        end
    end
    UItk.NextColumn()

    local invert = UI.fxmanager.getParamInvert(fx_id, param_id)
    local tn, on = Tgl(param_data._uid_n, "N", invert)
    if tn then UI.fxmanager.setParamInvert(fx_id, param_id, on) end
    UItk.NextColumn()

    -- X/Y show the PAD routing: they light up only while the pad is the
    -- source. Clicking one while an LFO drives the param reclaims it for
    -- the pad (release the LFO link, back to pad assignment).
    local function reclaimForPad()
        if src_slot > 0 and le then
            le.releaseParamLink(fx_id, param_id)
            le.setParamModSource(fx_id, param_id, 0)
            src_slot = 0
        end
    end

    local pad_src = src_slot == 0
    local x_ass, y_ass = UI.fxmanager.getParamXYAssign(fx_id, param_id)
    local tx, ox = Tgl(param_data._uid_x, "X", x_ass and pad_src)
    if tx then
        reclaimForPad()
        UI.fxmanager.setParamXYAssign(fx_id, param_id, "x", pad_src and ox or true)
    end
    UItk.NextColumn()

    local ty, oy = Tgl(param_data._uid_y, "Y", y_ass and pad_src)
    if ty then
        reclaimForPad()
        UI.fxmanager.setParamXYAssign(fx_id, param_id, "y", pad_src and oy or true)
    end
    UItk.NextColumn()

    -- Modulation-source badge: L1..L8 = track LFO, G1..G8 = global. Click
    -- opens the assignment menu (same as right-clicking the row).
    local src_label
    if le and src_slot > le.GLOBAL_SLOT_BASE then
        src_label = "G" .. (src_slot - le.GLOBAL_SLOT_BASE)
    elseif src_slot > 0 then
        src_label = "L" .. src_slot
    else
        src_label = "·"
    end
    if src_slot > 0 then
        UItk.PushStyleColor("button", theme.colors.accent[1],
            theme.colors.accent[2], theme.colors.accent[3])
    end
    if Btn(param_data._uid_src, src_label) then
        openParamModMenu(fx_id, param_id, param_data)
    end
    if src_slot > 0 then UItk.PopStyleColor() end
    if UItk.IsItemHovered() then
        UItk.Tooltip(src_slot > 0
            and ("Modulation source (click to change)")
            or "Assign a modulation source (LFO)")
    end
    UItk.NextColumn()

    -- Value-range slider — three handles in one widget:
    --   • value dot: shows the LIVE plugin value (LFO/link modulation makes
    --     it move); dragging it writes the BASE value
    --   • min / max bars (drag to resize the randomization window)
    --   • middle-drag → translate range + value together
    -- The window is centered on the gesture ANCHOR (param_base_values), NOT
    -- on param_data.base_value: in script mode the gesture overwrites
    -- base_value every frame with the applied value, which made the whole
    -- window ride along with the dot instead of framing it. The anchor only
    -- moves on explicit base edits / gesture commit — a stable frame.
    local anchor_key = UI.core.getParamKey(fx_id, param_id)
    local base_value = (anchor_key
            and UI.core.state.param_base_values[anchor_key])
        or param_data.base_value or param_data.current_value or 0.5
    -- The API only reports the base value under parameter modulation; the
    -- link engine recomputes the modulated value from the link source.
    local live_value = (UI.linkengine
        and UI.linkengine.getLiveValue(fx_id, param_id, param_data))
        or param_data.current_value or base_value
    local range = UI.fxmanager.getParamRange(fx_id, param_id) or 1.0
    local v_min = clamp(base_value - range * 0.5, 0, 1)
    local v_max = clamp(base_value + range * 0.5, 0, 1)
    local shown_value = clamp(live_value, v_min, v_max)

    -- Show the live value in the param's real units (Hz, dB, %, …).
    local real_min = param_data.min_val or 0
    local real_max = param_data.max_val or 1
    local real_cur = UI.core.denormalizeParamValue(live_value, real_min, real_max)
    local readout
    if param_data.step_count and param_data.step_count == 2 then
        readout = live_value > 0.5 and "ON" or "OFF"
    elseif param_data.step_count and param_data.step_count > 2
           and param_data.step_count <= 5 then
        local idx = math.floor(live_value * (param_data.step_count - 1) + 0.5)
        readout = tostring(idx + 1) .. "/" .. param_data.step_count
    else
        readout = string.format("%.2f", real_cur)
    end

    local vc, new_v, rc, new_min, new_max = ValRngSlid(param_data._uid_vr, "",
        shown_value, v_min, v_max, 0, 1, { format = readout })

    if vc then
        local v = new_v
        if param_data.step_count and param_data.step_count > 0 then
            v = UI.core.snapToDiscreteValue(v, param_data.step_count)
        end
        UI.fxmanager.updateParamBaseValue(fx_id, param_id, v)
    end
    if rc then
        local span = clamp(new_max - new_min, 0, 1)
        UI.fxmanager.setParamRange(fx_id, param_id, span)
    end

    -- Tooltip with real-units values — built only while hovered (string
    -- building per row per frame is pure GC churn otherwise).
    if UItk.IsItemHovered() then
        local real_base = UI.core.denormalizeParamValue(param_data.base_value or 0,
                                                        real_min, real_max)
        local tip = string.format("%s\nCurrent: %.3f, Base: %.3f\nRange: %.2f",
            name, real_cur, real_base, range)
        if real_min ~= 0 or real_max ~= 1 then
            tip = tip .. string.format("\n(%.2f to %.2f)", real_min, real_max)
        end
        if x_ass and y_ass then tip = tip .. " [XY]"
        elseif x_ass then tip = tip .. " [X]"
        elseif y_ass then tip = tip .. " [Y]" end
        if invert then tip = tip .. " [INVERTED]" end
        UItk.Tooltip(tip)
    end

    UItk.EndColumns()

    -- Right-click anywhere on the row → modulation assignment menu
    -- (NativeMenu: blocking while open, zero cost otherwise).
    if UItk.Core.MouseClicked(2) and not UItk.Core.HasPopup()
       and UItk.Core.MouseInRect(row_x, row_y, row_w, theme.button_height) then
        openParamModMenu(fx_id, param_id, param_data)
    end
end

-- ---------------------------------------------------------------------------
-- FX CARD
-- ---------------------------------------------------------------------------
local function drawFXCard(theme, fx_id, fx_data, card_w)
    local UItk = UI.tk
    local s = UI.core.state
    local collapsed = s.fx_collapsed[fx_id] or false

    UItk.BeginPanel("fxcard_" .. fx_id, {
        style = "groupbox",
        width = card_w,
        bg = theme.colors.frame_bg,
    })

    -- Header: collapse | name | enabled (the enabled cell is button_height
    -- wide — the Chk helper sizes the box to button_height, a checkbox_size
    -- column clipped its right edge)
    UItk.BeginColumns("fxcard_hd_" .. fx_id,
        { theme.button_height, 0, theme.button_height },
        { gap = theme.item_spacing })
    if Btn("fxcol_" .. fx_id, collapsed and "+" or "−") then
        s.fx_collapsed[fx_id] = not collapsed
    end
    UItk.NextColumn()
    local fx_label = (fx_data.name and fx_data.name ~= "") and fx_data.name
                     or ("FX " .. fx_id)
    if Btn("fxopen_" .. fx_id, fx_label) then
        local actual = fx_data.actual_fx_id or fx_id
        local visible = UI.r.TrackFX_GetOpen(s.track, actual)
        UI.r.TrackFX_Show(s.track, actual, visible and 2 or 3)
    end
    UItk.NextColumn()
    local ec, ev = Chk("fxen_" .. fx_id, "", fx_data.enabled)
    if ec then
        local actual = fx_data.actual_fx_id or fx_id
        UI.r.TrackFX_SetEnabled(s.track, actual, ev)
        fx_data.enabled = ev
    end
    UItk.EndColumns()

    if collapsed then
        UItk.EndPanel()
        return
    end

    -- Action row: All / Cont / None / Rnd / [count]
    UItk.BeginColumns("fxact_" .. fx_id,
        { 0.2, 0.2, 0.2, 0.2, 0.2 }, { gap = theme.item_spacing })
    if Btn("fxall_" .. fx_id, "All") then
        UI.fxmanager.selectAllParams(fx_data.params, true)
        UI.fxmanager.saveTrackSelection()
    end
    UItk.NextColumn()
    if Btn("fxcont_" .. fx_id, "Cont") then
        UI.fxmanager.selectAllContinuousParams(fx_data.params, true)
        UI.fxmanager.saveTrackSelection()
    end
    UItk.NextColumn()
    if Btn("fxnone_" .. fx_id, "None") then
        UI.fxmanager.selectAllParams(fx_data.params, false)
        UI.fxmanager.saveTrackSelection()
    end
    UItk.NextColumn()
    if Btn("fxrnd_" .. fx_id, "Rnd") then
        UI.fxmanager.randomSelectParams(fx_data.params, fx_id)
        UI.fxmanager.saveTrackSelection()
    end
    UItk.NextColumn()
    local fx_key = UI.core.getFXKey(fx_id)
    local cur_max = (fx_key and UI.core.state.fx_random_max[fx_key]) or 3
    local sc, sv = SlidInt("fxmax_" .. fx_id, "", cur_max, 1, 10)
    if sc and fx_key then
        UI.core.state.fx_random_max[fx_key] = sv
        UI.fxmanager.saveTrackSelection()
    end
    UItk.EndColumns()

    -- Action row 2
    UItk.BeginColumns("fxact2_" .. fx_id,
        { 0.34, 0.33, 0.33 }, { gap = theme.item_spacing })
    if Btn("fxrxy_" .. fx_id, "RandXY") then
        UI.fxmanager.randomizeXYAssign(fx_data.params, fx_id)
    end
    UItk.NextColumn()
    if Btn("fxrrng_" .. fx_id, "RandRng") then
        UI.fxmanager.randomizeRanges(fx_data.params, fx_id)
    end
    UItk.NextColumn()
    if Btn("fxrbase_" .. fx_id, "RndBase") then
        UI.fxmanager.randomizeBaseValues(fx_data.params, fx_id)
    end
    UItk.EndColumns()

    UItk.Separator()

    -- Params — sorted ids cached on the fx entry (rebuilt with fx_data on
    -- every scan, so the cache tracks chain changes for free).
    local pids = fx_data._sorted_pids
    if not pids then
        pids = {}
        for pid, _ in pairs(fx_data.params) do pids[#pids + 1] = pid end
        table.sort(pids)
        fx_data._sorted_pids = pids
    end

    -- The rows live in their own vertical-scrolling child, virtualized with
    -- the list clipper: only the rows inside the viewport are laid out and
    -- drawn. A big synth (hundreds of params) costs the same as a small FX,
    -- and long lists finally get a scrollbar instead of being cut off.
    local row_h = theme.button_height
    local step = row_h + theme.item_spacing
    local needed_h = #pids * step + theme.frame_padding_y * 2
    local avail_h = UItk.GetAvailableHeight() - theme.frame_padding_y
    local min_h = math.min(needed_h, step * 2)
    local child_h = math.max(min_h, math.min(needed_h, avail_h))
    UItk.BeginChild("fxparams_" .. fx_id, 0, child_h,
        { scrollable = true, border = false, padding = 0 })
    local first, last = UItk.ListClipper(#pids, row_h)
    for i = first, last do
        local pid = pids[i]
        drawParamRow(theme, fx_id, pid, fx_data.params[pid])
    end
    UItk.EndListClipper(#pids, row_h)
    UItk.EndChild()

    UItk.EndPanel()
end

-- ---------------------------------------------------------------------------
-- FX SETTINGS
-- ---------------------------------------------------------------------------
local function drawFXSettings(theme)
    local UItk = UI.tk
    local s = UI.core.state

    local extra = " | Selected: " .. (s.selected_count or 0)
    if s.current_loaded_preset ~= "" then
        extra = extra .. " | " .. s.current_loaded_preset
    end
    if not sectionHeader("fx_settings", "FX SETTINGS", theme, extra) then return end

    -- Two-column body: sidebar (action buttons) + flex (FX cards horizontal scroll)
    local sidebar_w = math.floor(theme.button_height * 4.5)
    UItk.BeginColumns("fxsec_root",
        { sidebar_w, 0 }, { gap = theme.item_spacing })

    if Btn("fx_addfx", "Add FX...") then
        if not UI.openFXBrowser() then
            -- Fallback: in-window modal if the standalone script can't launch.
            s.show_fxmanager_window = not s.show_fxmanager_window
        end
    end
    if Btn("fx_filters", s.show_filters_window and "Hide Filters" or "Show Filters") then
        s.show_filters_window = not s.show_filters_window
    end
    if Btn("fx_showall", "Show All FX") then UI.presetsystem.showAllFloatingFX() end
    if Btn("fx_closeall", "Close All FX") then UI.presetsystem.closeAllFloatingFX() end
    if Btn("fx_collapse", "Collapse All") then
        s.all_fx_collapsed = true
        for fid, _ in pairs(s.fx_data) do s.fx_collapsed[fid] = true end
    end
    if Btn("fx_expand", "Expand All") then
        s.all_fx_collapsed = false
        for fid, _ in pairs(s.fx_data) do s.fx_collapsed[fid] = false end
    end
    if Btn("fx_selall", "All") then
        for _, fd in pairs(s.fx_data) do UI.fxmanager.selectAllParams(fd.params, true) end
        UI.fxmanager.saveTrackSelection()
    end
    if Btn("fx_selcont", "All Cont") then
        for _, fd in pairs(s.fx_data) do
            UI.fxmanager.selectAllContinuousParams(fd.params, true)
        end
        UI.fxmanager.saveTrackSelection()
    end
    if Btn("fx_selclr", "Clear") then
        for _, fd in pairs(s.fx_data) do UI.fxmanager.selectAllParams(fd.params, false) end
        UI.fxmanager.saveTrackSelection()
    end

    UItk.NextColumn()

    -- Viewport of the cards child, captured in the parent BEFORE BeginChild:
    -- the child starts at the cursor and fills the available width. Used to
    -- cull cards that are fully scrolled out of view.
    local view_x, _ = UItk.GetCursorPos()
    local view_r = view_x + UItk.GetAvailableWidth()

    -- FX cards: horizontal scrolling child. The new toolkit feature
    -- (scrollable_x) lets us lay all cards in a single row with SameLine
    -- and scroll them with a horizontal scrollbar / Shift+wheel.
    UItk.BeginChild("fx_cards", 0, 0,
        { scrollable = false, scrollable_x = true, border = false,
          padding = theme.frame_padding_x })

    local ids = {}
    for fid, _ in pairs(s.fx_data) do ids[#ids + 1] = fid end
    table.sort(ids)

    if #ids == 0 then
        UItk.SetFontCaption()
        UItk.Text("No FX on track. Click \"Add FX...\" to start.")
        UItk.SetFontBody()
    else
        local card_w = math.floor(theme.button_height * 14)  -- ~336px @ scale 1
        for i, fid in ipairs(ids) do
            if i > 1 then UItk.SameLine(theme.item_spacing) end
            -- Horizontal culling: a card fully outside the viewport is
            -- replaced by an empty panel of the same width (2 rects), so
            -- scroll geometry stays exact but off-screen cards cost nothing.
            local cx, _ = UItk.GetCursorPos()
            if cx + card_w < view_x or cx > view_r then
                UItk.BeginPanel("fxcard_" .. fid, {
                    style = "groupbox",
                    width = card_w,
                    bg = theme.colors.frame_bg,
                })
                UItk.EndPanel()
            else
                drawFXCard(theme, fid, s.fx_data[fid], card_w)
            end
        end
    end

    UItk.EndChild()
    UItk.EndColumns()
end

-- ---------------------------------------------------------------------------
-- LICENSE MODAL
-- ---------------------------------------------------------------------------
local function drawLicenseModal()
    if not UI.core.state.show_license_window then return end
    local UItk = UI.tk
    UItk.BeginModal("license_modal", "FX Constellation — License",
        { width = 420, height = 320 })

    local status = UI.license.getStatus()
    if status == "FULL" then
        UItk.TextColored("✓ Licensed", 0.2, 1.0, 0.2, 1)
        UItk.Text("Thank you for supporting FX Constellation!")
        if Btn("lic_close", "Close") then
            UI.core.state.show_license_window = false
        end
    else
        if status == "INVALID" then
            UItk.TextColored("✗ Invalid License Key", 1.0, 0.3, 0.3, 1)
        end
        UItk.SetFontH2Bold()
        UItk.Text("FX Constellation FREE")
        UItk.SetFontBody()
        UItk.Separator()
        UItk.Text("Upgrade to unlock:")
        UItk.Text("  • Sound Generator")
        UItk.Text("  • Unlimited FX (FREE: max 5)")
        UItk.Text("  • Granular mode")
        UItk.Text("  • Random Walk & Figures")
        UItk.Text("  • Ultra Random")
        UItk.Text("Enter License Key:")
        local kc, kv = Input("lic_key", "", UI.license_key_input,
            { hint = "key…" })
        if kc then UI.license_key_input = kv end
        UItk.BeginColumns("lic_btns", { 0.5, 0.5 }, { gap = 8 })
        if Btn("lic_act", "Activate") then
            if UI.license_key_input == "" then
                UI.license_msg = "Please enter a license key"
            elseif UI.license.validate(UI.license_key_input) then
                UI.license.setKey(UI.license_key_input)
                UI.license_msg = "License activated successfully!"
                UI.license_key_input = ""
            else
                UI.license_msg = "Invalid license key."
            end
            UI.license_msg_time = UI.r.time_precise()
        end
        UItk.NextColumn()
        if Btn("lic_cancel", "Cancel") then
            UI.core.state.show_license_window = false
            UI.license_key_input = ""
            UI.license_msg = ""
        end
        UItk.EndColumns()

        if UI.license_msg ~= "" and (UI.r.time_precise() - UI.license_msg_time < 5) then
            local is_ok = UI.license_msg:find("success")
            if is_ok then
                UItk.TextColored(UI.license_msg, 0.2, 1.0, 0.2, 1)
            else
                UItk.TextColored(UI.license_msg, 1.0, 0.3, 0.3, 1)
            end
        end
    end

    UItk.EndModal()
end

-- ---------------------------------------------------------------------------
-- SETTINGS MODAL
-- ---------------------------------------------------------------------------
local function drawSettingsModal()
    if not UI.core.state.show_settings_window then return end
    local UItk = UI.tk
    UItk.BeginModal("settings_modal", "Settings",
        { width = 420, height = 380 })
    UItk.SetFontH2Bold()
    UItk.Text("ULTRA RANDOM SETTINGS")
    UItk.SetFontBody()
    UItk.Separator()

    local urs = UI.core.state.ultra_random_settings
    local function flag(id, label, key)
        local c, v = Chk(id, label, urs[key])
        if c then urs[key] = v; UI.persistence.scheduleSave() end
    end
    flag("urs_xy",   "Randomize XY Assignments", "xy_assignments")
    flag("urs_r",    "Randomize Ranges",          "ranges")
    flag("urs_b",    "Randomize Bases",           "bases")
    flag("urs_byp",  "Randomize Bypass",          "bypass")
    flag("urs_ord",  "Randomize FX Order",        "fx_order")
    flag("urs_inv",  "Randomize Invert",          "invert")
    flag("urs_sf",   "Randomize Sound Generator Frequency", "sound_frequency")

    UItk.Separator()
    UItk.SetFontH2Bold()
    UItk.Text("FILTERS")
    UItk.SetFontBody()
    local pf, pv = Input("set_param_filter", "Param", UI.core.state.param_filter)
    if pf then
        UI.core.state.param_filter = pv
        UI.fxmanager.scanTrackFX()
    end

    if Btn("set_close", "Close") then
        UI.core.state.show_settings_window = false
    end

    UItk.EndModal()
end

-- ---------------------------------------------------------------------------
-- TRACK SYNC
-- ---------------------------------------------------------------------------
local function syncTrack()
    local s = UI.core.state
    UI.persistence.checkSave()
    UI.gesture.updateGestureMotion()

    if not s.track_locked then
        local new_track = UI.r.GetSelectedTrack(0, 0)
        if new_track ~= s.track then
            if s.track then UI.fxmanager.saveTrackSelection() end
            s.track = new_track
            if s.track then
                -- scanTrackFX refreshes jsfx_automation_index itself; a
                -- bridge already present on the track re-enables Auto JSFX.
                UI.fxmanager.scanTrackFX()
                s.jsfx_automation_enabled = s.jsfx_automation_index >= 0
                if s.jsfx_automation_enabled then
                    UI.gesture.syncBridgeState()
                end
            end
        end
    elseif s.locked_track and UI.r.ValidatePtr(s.locked_track, "MediaTrack*") then
        s.track = s.locked_track
    else
        s.track_locked = false
        s.locked_track = nil
    end

    if UI.core.isTrackValid() then
        UI.fxmanager.checkForFXChanges()
        UI.presetsystem.checkPresetModification()
        if UI.linkengine then
            -- External unlinks (standalone panel) must clear our entry
            -- BEFORE the sweep runs, or the link is instantly recreated.
            UI.linkengine.checkExternalUnlink()
            -- External raw edits (panel knobs, Map) sync back live.
            UI.linkengine.checkExternalEdits()
            if s.links_dirty then
                UI.linkengine.syncLinks()
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- COLLAPSED COLUMN (narrow strip with the section title drawn vertically)
-- ---------------------------------------------------------------------------
local SECTION_LABELS = {
    soundgen    = "SOUND GENERATOR",
    navigation  = "NAVIGATION",
    mode        = "MODE",
    pad         = "XY PAD",
    lfo         = "LFO",
    presets     = "PRESETS",
    randomizer  = "RANDOMIZER",
    fx_settings = "FX SETTINGS",
}

local function drawCollapsedColumn(theme, key)
    local UItk = UI.tk
    local s = UI.core.state

    local w = UItk.GetAvailableWidth()
    local h = UItk.GetAvailableHeight()
    if h < theme.combo_height then h = theme.combo_height end

    -- Cursor screen position BEFORE the button so we can overlay text on
    -- top after Button advances the layout cursor.
    local x, y = UItk.GetCursorPos()

    -- Big click target that fills the whole collapsed column.
    local clicked = UItk.Button("col_collapsed_" .. key, "",
        { width = w, height = h })
    if clicked then
        s.section_collapsed[key] = false
        UI.persistence.scheduleSave()
    end

    -- Vertical title — gfx can't rotate glyphs, so we stack characters one
    -- per line, centered on the column. Fits the chevron at the top.
    local label = SECTION_LABELS[key] or key
    local tc = theme.colors.text
    local _, ch = UItk.Core.MeasureText("M")  -- a single char's height
    local line_h = ch + 1

    -- Start a few px below the top with a chevron pointing right.
    local cy = y + theme.frame_padding_y
    local cx_center = x + math.floor(w / 2)

    -- Chevron icon (◀ → "expand")
    if UItk.Icons and UItk.Icons.TriangleRight then
        UItk.Icons.TriangleRight(cx_center - math.floor(line_h / 2),
                                 cy, line_h, tc[1], tc[2], tc[3], tc[4] or 1)
    else
        UItk.Core.DrawText(">", cx_center - 4, cy, tc[1], tc[2], tc[3], tc[4] or 1)
    end
    cy = cy + line_h + 4

    for i = 1, #label do
        local ch_str = label:sub(i, i)
        if ch_str == " " then
            cy = cy + math.floor(line_h * 0.4)
        else
            local cw = UItk.Core.MeasureText(ch_str)
            UItk.Core.DrawText(ch_str,
                cx_center - math.floor(cw / 2), cy,
                tc[1], tc[2], tc[3], tc[4] or 1)
            cy = cy + line_h
        end
    end
end

-- ---------------------------------------------------------------------------
-- FRAME (main entry called once per CP_Toolkit frame)
-- ---------------------------------------------------------------------------
local SECTION_RENDERERS = {
    soundgen     = drawSoundGen,
    navigation   = drawNavigation,
    mode         = drawMode,
    pad          = drawXYPad,
    lfo          = drawLFOSection,
    presets      = drawPresets,
    randomizer   = drawRandomizer,
    fx_settings  = drawFXSettings,
}

function UI.frame(theme)
    local UItk = UI.tk

    drawStatusBar(theme)
    syncTrack()

    -- Animated navigation modes (random walk + figures) must redraw every
    -- frame, otherwise the toolkit's idle-throttle pauses the loop and the
    -- gesture freezes between user input. The XY pad's smooth-speed
    -- interpolation has the same constraint.
    local s = UI.core.state
    if s.navigation_mode == 1 or s.navigation_mode == 2
       or (s.smooth_speed and s.smooth_speed > 0
           and (s.gesture_x ~= s.target_gesture_x
                or s.gesture_y ~= s.target_gesture_y)) then
        UItk.RequestRedraw()
    elseif (s.jsfx_automation_enabled and (UI.r.GetPlayState() & 1) == 1)
        or (s.lfo_links_count or 0) > 0 then
        -- Keep the loop alive at 30 Hz when following can happen without
        -- user input: envelopes while the transport runs, or LFO-assigned
        -- params whose live value must move in the param rows (free-running
        -- LFOs oscillate even when stopped). The virtualized FX cards keep
        -- this repaint cheap.
        UItk.RequestRedrawAt(UI.r.time_precise() + 1 / 30)
    end

    if not UI.core.isTrackValid() then
        UItk.SetFontH1()
        UItk.Text("No track selected.")
        UItk.SetFontBody()
        UItk.Text("Select a track in REAPER, or use the Lock button to pin to one.")
        return
    end

    -- Compute per-section widths from theme + collapsed state.
    local collapsed_w = math.floor(theme.button_height * 0.9)
    local widths = {}
    for _, k in ipairs(UI.section_order) do
        if s.section_collapsed[k] then
            widths[#widths + 1] = collapsed_w
        else
            widths[#widths + 1] = sectionW(theme, k)
        end
    end

    -- Capture the row's screen origin so we can overlay splitters on the
    -- column boundaries after EndColumns.
    local row_x, row_y = UItk.GetCursorPos()
    local row_h = UItk.GetAvailableHeight()
    local col_gap = math.floor(theme.window_padding * 1.0)

    UItk.BeginColumns("main_cols", widths, { gap = col_gap })
    for i, k in ipairs(UI.section_order) do
        if i > 1 then UItk.NextColumn() end
        local renderer = SECTION_RENDERERS[k]
        if s.section_collapsed[k] then
            drawCollapsedColumn(theme, k)
        elseif renderer then
            renderer(theme)
        end
    end
    UItk.EndColumns()

    -- Splitter overlays — one between each pair of consecutive sections,
    -- skipped if the LEFT section is fx_settings (the flex column has no
    -- explicit width). Hover/drag adjusts the LEFT section's stored width.
    s.section_widths_user = s.section_widths_user or {}
    local cursor_x = row_x
    local SPLITTER_W = math.max(4, math.floor(theme.frame_padding_x * 0.7))
    for i = 1, #UI.section_order - 1 do
        local left_key = UI.section_order[i]
        cursor_x = cursor_x + widths[i]
        local sx = cursor_x + math.floor((col_gap - SPLITTER_W) / 2)
        local sy = row_y
        local sw = SPLITTER_W
        local sh = row_h

        -- Don't allow resizing the flex column from its right edge (no
        -- meaningful width to set), and don't allow resizing collapsed
        -- columns either.
        local can_drag = (SECTION_DEFAULT_W[left_key] or 0) > 0
                         and not s.section_collapsed[left_key]

        if can_drag then
            local hovered = UItk.Core.MouseInRect(sx - 2, sy, sw + 4, sh)
            local drag_id = "split_" .. left_key
            if hovered then
                UItk.SetCursor("size_we")
                if UItk.Core.MouseClicked(1) then
                    UItk.Core.SetActive(drag_id)
                end
            end
            if UItk.Core.IsActive(drag_id) then
                UItk.SetCursor("size_we")
                if UItk.Core.MouseDown(1) then
                    local dx, _ = UItk.Core.MouseDelta()
                    if dx ~= 0 then
                        local cur_w = widths[i]
                        local min_w = math.floor(theme.button_height * 2.5)
                        local new_w = math.max(min_w, cur_w + dx)
                        s.section_widths_user[left_key] = new_w
                        UI.persistence.scheduleSave()
                        UItk.RequestRedraw()
                    end
                else
                    UItk.Core.ClearActive()
                end
            end
            -- Visible thumb (subtle line, only highlights on hover/drag)
            local active = (hovered or UItk.Core.IsActive(drag_id))
            local sc = active and theme.colors.accent or theme.colors.separator
            local alpha = active and 0.7 or 0.25
            UItk.Core.DrawRect(sx + math.floor(sw / 2),
                sy, 1, sh, sc[1], sc[2], sc[3], alpha)
        end
        cursor_x = cursor_x + col_gap
    end

    drawLicenseModal()
    drawSettingsModal()
    if UI.fxmanagerui and UI.fxmanagerui.draw then
        UI.fxmanagerui.draw(theme)
    end
end

return UI
