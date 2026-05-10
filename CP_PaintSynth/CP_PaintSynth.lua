-- CP_PaintSynth.lua
-- Spectrogram drawing → audio via CP_PaintSynth_JSFX (gmem: CP_PaintSynth)
-- Place CP_PaintSynth_JSFX on a track, then run this script.

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])") .. "../"
local UI = dofile(script_path .. "CP_Toolkit/CP_Toolkit.lua")

local SCRIPT_ID = "CP_PaintSynth"

r.gmem_attach("CP_PaintSynth")

local GMEM_BINS = 0
local GMEM_COLS = 1
local GMEM_TRIG = 2
local GMEM_SPD  = 3
local GMEM_PLAY = 4
local GMEM_SNAP = 5
local GMEM_DATA = 6

local state = {
    num_bins   = 128,
    num_cols   = 192,
    grid       = {},
    brush_size = 8,
    brush_amp  = 1.0,
    erasing    = false,
    playing    = false,
    speed      = 4,
    speed_locked = false,
    show_grid  = true,
    snap       = false,
    snap_brush = false,
    -- Sound params (mirrored to JSFX sliders 8/9/10)
    waveshape  = 0,    -- 0=sine 1=saw 2=square 3=triangle 4=noise
    harmonics  = 4,    -- 1..16
    detune     = 0,    -- 0..0.05
    -- Frequency mapping (must match JSFX freq_min/freq_max sliders)
    freq_min   = 40,
    freq_max   = 16000,
    -- Chord brush: 0=Off, then list below
    chord_idx  = 0,
    last_paint_x = nil,
    last_paint_y = nil,
    dirty_grid = true,
    cfg_loaded = false,
}

local function grid_index(col, bin) return col * state.num_bins + bin + 1 end

local function grid_step_col() return math.max(1, math.floor(state.num_cols / 16)) end

-- Frequency <-> bin mapping (must mirror the JSFX: bin 0 = top = freq_max)
local function bin_to_freq(bin)
    local n = math.max(1, state.num_bins - 1)
    local norm = 1 - bin / n  -- 1 at top → freq_max
    local lf = math.log(state.freq_min) + norm * (math.log(state.freq_max) - math.log(state.freq_min))
    return math.exp(lf)
end

local function freq_to_bin(freq)
    if freq <= 0 then return state.num_bins - 1 end
    local lf = math.log(freq)
    local lmin = math.log(state.freq_min)
    local lmax = math.log(state.freq_max)
    local norm = (lf - lmin) / (lmax - lmin)
    norm = math.max(0, math.min(1, norm))
    local n = math.max(1, state.num_bins - 1)
    return math.floor((1 - norm) * n + 0.5)
end

-- MIDI note → freq (A4 = 440 Hz = note 69)
local function note_to_freq(note) return 440 * 2 ^ ((note - 69) / 12) end
local function freq_to_note(freq) return 69 + 12 * math.log(freq / 440) / math.log(2) end

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local function note_name(note)
    local n = math.floor(note + 0.5)
    local octave = math.floor(n / 12) - 1
    return NOTE_NAMES[(n % 12) + 1] .. octave
end

-- Chord intervals in semitones (from root)
local CHORDS = {
    {name = "Off",      intervals = {0}},
    {name = "5th",      intervals = {0, 7}},
    {name = "Octave",   intervals = {0, 12}},
    {name = "Major",    intervals = {0, 4, 7}},
    {name = "Minor",    intervals = {0, 3, 7}},
    {name = "Sus2",     intervals = {0, 2, 7}},
    {name = "Sus4",     intervals = {0, 5, 7}},
    {name = "Maj7",     intervals = {0, 4, 7, 11}},
    {name = "Min7",     intervals = {0, 3, 7, 10}},
    {name = "Dom7",     intervals = {0, 4, 7, 10}},
    {name = "Dim",      intervals = {0, 3, 6}},
    {name = "Aug",      intervals = {0, 4, 8}},
    {name = "Maj9",     intervals = {0, 4, 7, 11, 14}},
    {name = "Min9",     intervals = {0, 3, 7, 10, 14}},
}

local function chord_names()
    local out = {}
    for i, c in ipairs(CHORDS) do out[i] = c.name end
    return out
end

-- Snap a bin to the nearest semitone
local function snap_bin_to_note(bin)
    local f = bin_to_freq(bin)
    local n = math.floor(freq_to_note(f) + 0.5)
    return freq_to_bin(note_to_freq(n))
end

local function snap_to_grid(col, bin)
    if not state.snap_brush then return col, bin end
    local sc = grid_step_col()
    return math.floor(col / sc + 0.5) * sc, snap_bin_to_note(bin)
end

local function clear_grid()
    state.grid = {}
    local n = state.num_cols * state.num_bins
    for i = 1, n do state.grid[i] = 0 end
    state.dirty_grid = true
end

local function push_dimensions_to_jsfx()
    r.gmem_write(GMEM_BINS, state.num_bins)
    r.gmem_write(GMEM_COLS, state.num_cols)
    -- Always push speed: JSFX uses it when > 0, falls back to its own slider when 0.
    -- speed_locked toggles whether Lua "owns" the speed value or lets JSFX slider win.
    r.gmem_write(GMEM_SPD, state.speed_locked and 0 or state.speed)
    r.gmem_write(GMEM_SNAP, state.snap and 1 or 0)
end

-- Find first JSFX instance by name across all tracks. Returns track, fx_idx or nil.
local function find_jsfx()
    local n_tracks = r.CountTracks(0)
    for t = -1, n_tracks - 1 do  -- -1 = master
        local tr = (t == -1) and r.GetMasterTrack(0) or r.GetTrack(0, t)
        local fx_count = r.TrackFX_GetCount(tr)
        for fx = 0, fx_count - 1 do
            local _, name = r.TrackFX_GetFXName(tr, fx)
            if name and name:find("CP_PaintSynth") then return tr, fx end
        end
    end
    return nil, nil
end

-- JSFX slider indices (0-based for TrackFX_SetParam)
local JSFX_WAVESHAPE = 7   -- slider8
local JSFX_HARMONICS = 8   -- slider9
local JSFX_DETUNE    = 9   -- slider10

local function push_sound_params()
    local tr, fx = find_jsfx()
    if not tr or not fx then return end
    r.TrackFX_SetParam(tr, fx, JSFX_WAVESHAPE, state.waveshape)
    r.TrackFX_SetParam(tr, fx, JSFX_HARMONICS, state.harmonics)
    r.TrackFX_SetParam(tr, fx, JSFX_DETUNE,    state.detune)
end

local function push_grid_to_jsfx()
    -- gmem layout: column-major, base GMEM_DATA, col*num_bins + bin
    local base = GMEM_DATA
    local nb = state.num_bins
    for col = 0, state.num_cols - 1 do
        local col_base = base + col * nb
        local lua_base = col * nb + 1
        for bin = 0, nb - 1 do
            r.gmem_write(col_base + bin, state.grid[lua_base + bin] or 0)
        end
    end
    state.dirty_grid = false
end

local function push_dirty_column(col)
    local base = GMEM_DATA + col * state.num_bins
    local lua_base = col * state.num_bins + 1
    for bin = 0, state.num_bins - 1 do
        r.gmem_write(base + bin, state.grid[lua_base + bin] or 0)
    end
end

local function stamp_brush(col, bin, value)
    local size = state.brush_size
    local r2 = size * size
    for dy = -size, size do
        for dx = -size, size do
            local d2 = dx * dx + dy * dy
            if d2 <= r2 then
                local cc = col + dx
                local bb = bin + dy
                if cc >= 0 and cc < state.num_cols and bb >= 0 and bb < state.num_bins then
                    local falloff = 1 - math.sqrt(d2) / size
                    local idx = grid_index(cc, bb)
                    if state.erasing then
                        state.grid[idx] = 0
                    else
                        local cur = state.grid[idx] or 0
                        local v = value * falloff
                        if v > cur then state.grid[idx] = v end
                    end
                end
            end
        end
    end
end

-- Paint at (col, bin) — applies chord intervals if a chord is selected.
-- The mouse position is the *root* note. Each interval offsets the bin by
-- the equivalent number of semitones in log-frequency space.
local function paint_at(col, bin, value)
    local chord = CHORDS[state.chord_idx + 1]
    if not chord or state.erasing or #chord.intervals == 1 then
        stamp_brush(col, bin, value)
        return
    end
    local root_freq = bin_to_freq(bin)
    for _, semi in ipairs(chord.intervals) do
        local f = root_freq * 2 ^ (semi / 12)
        if f >= state.freq_min and f <= state.freq_max then
            stamp_brush(col, freq_to_bin(f), value)
        end
    end
end

local function paint_line(x1, y1, x2, y2, value)
    local dx = x2 - x1
    local dy = y2 - y1
    local steps = math.max(math.abs(dx), math.abs(dy), 1)
    for s = 0, steps do
        local t = s / steps
        local cx = math.floor(x1 + dx * t + 0.5)
        local cy = math.floor(y1 + dy * t + 0.5)
        paint_at(cx, cy, value)
    end
end

local function trigger_play()
    push_grid_to_jsfx()
    push_dimensions_to_jsfx()
    r.gmem_write(GMEM_TRIG, 1)
    state.playing = true
end

local function trigger_stop()
    r.gmem_write(GMEM_TRIG, 0)
    state.playing = false
end

local function get_playhead_norm()
    if not state.playing then return nil end
    local trig = r.gmem_read(GMEM_TRIG)
    if trig < 1 then state.playing = false; return nil end
    local ph = r.gmem_read(GMEM_PLAY) or 0
    if state.num_cols <= 0 then return nil end
    local norm = (ph % state.num_cols) / state.num_cols
    return norm
end

-- ============================================================================
-- Drawing the canvas (uses Core.DrawRect for speed; one rect per active cell)
-- ============================================================================

local function draw_spectrogram(canvas, theme)
    local x, y, w, h = canvas.x, canvas.y, canvas.w, canvas.h
    local cell_w = w / state.num_cols
    local cell_h = h / state.num_bins

    -- Background
    UI.Core.DrawRect(x, y, w, h, 0.06, 0.07, 0.09, 1, true)

    -- Optional grid: vertical = time divisions, horizontal = octave lines (C notes)
    if state.show_grid then
        gfx.set(1, 1, 1, 0.04)
        local cols_per_line = math.max(1, math.floor(state.num_cols / 16))
        for c = 0, state.num_cols, cols_per_line do
            local px = x + c * cell_w
            gfx.line(px, y, px, y + h)
        end

        -- Horizontal: one line per octave C, label on left
        local low_note  = math.ceil(freq_to_note(state.freq_min))
        local high_note = math.floor(freq_to_note(state.freq_max))
        for note = low_note, high_note do
            local pc = note % 12  -- pitch class: 0=C, 7=G
            -- Major lines on C, minor on G (5th)
            local is_C = (pc == 0)
            local is_G = (pc == 7)
            if is_C or is_G then
                local f = note_to_freq(note)
                local b = freq_to_bin(f)
                local py = y + b * cell_h
                gfx.set(1, 1, 1, is_C and 0.10 or 0.04)
                gfx.line(x, py, x + w, py)
                if is_C then
                    gfx.set(1, 1, 1, 0.35)
                    gfx.x = x + 3
                    gfx.y = py - 12
                    gfx.drawstr(note_name(note))
                end
            end
        end
    end

    -- Cells: only draw non-zero cells (sparse)
    local nb = state.num_bins
    -- Color ramp: black → accent color of theme
    local ar = theme.colors.accent[1]
    local ag = theme.colors.accent[2]
    local ab = theme.colors.accent[3]
    for col = 0, state.num_cols - 1 do
        local col_base = col * nb + 1
        local px = x + col * cell_w
        for bin = 0, nb - 1 do
            local v = state.grid[col_base + bin]
            if v and v > 0.01 then
                local py = y + bin * cell_h
                local rr = ar * v
                local gg2 = ag * v
                local bb = ab * v
                UI.Core.DrawRect(px, py, cell_w + 1, cell_h + 1, rr, gg2, bb, 1, true)
            end
        end
    end

    -- Playhead
    local ph = get_playhead_norm()
    if ph then
        local px = x + ph * w
        gfx.set(1, 1, 1, 0.9)
        gfx.line(px, y, px, y + h)
    end

    -- Border
    UI.Core.DrawRect(x, y, w, h, theme.colors.border[1], theme.colors.border[2],
                     theme.colors.border[3], theme.colors.border[4], false)
end

local function handle_canvas_input(canvas)
    local x, y, w, h = canvas.x, canvas.y, canvas.w, canvas.h
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local inside = mx >= x and mx <= x + w and my >= y and my <= y + h
    local lmb = (gfx.mouse_cap & 1) == 1
    local rmb = (gfx.mouse_cap & 2) == 2

    if inside then UI.SetCursor("cross") end

    if (lmb or rmb) and inside then
        state.erasing = rmb
        local col = math.floor((mx - x) / w * state.num_cols)
        local bin = math.floor((my - y) / h * state.num_bins)
        col, bin = snap_to_grid(col, bin)
        local prev_col = state.last_paint_x
        if state.last_paint_x and state.last_paint_y then
            paint_line(state.last_paint_x, state.last_paint_y, col, bin, state.brush_amp)
        else
            paint_at(col, bin, state.brush_amp)
        end
        state.last_paint_x = col
        state.last_paint_y = bin
        state.dirty_grid = true
        -- Live push: re-send all columns affected by this mouse step (the brush
        -- radius around the *whole segment* prev_col..col, not just the endpoint).
        if state.playing then
            local size = state.brush_size
            local lo = math.min(prev_col or col, col) - size
            local hi = math.max(prev_col or col, col) + size
            lo = math.max(0, lo)
            hi = math.min(state.num_cols - 1, hi)
            for cc = lo, hi do
                push_dirty_column(cc)
            end
        end
    else
        state.last_paint_x = nil
        state.last_paint_y = nil
    end
end

-- ============================================================================
-- Persistence
-- ============================================================================

local function save_config()
    UI.SaveConfig(SCRIPT_ID, {
        num_bins = state.num_bins,
        num_cols = state.num_cols,
        brush_size = state.brush_size,
        brush_amp = state.brush_amp,
        speed = state.speed,
        speed_locked = state.speed_locked,
        show_grid = state.show_grid,
        snap = state.snap,
        snap_brush = state.snap_brush,
        waveshape = state.waveshape,
        harmonics = state.harmonics,
        detune = state.detune,
        chord_idx = state.chord_idx,
        grid = state.grid,
    })
end

local function load_config()
    local data = UI.LoadConfig(SCRIPT_ID)
    if data then
        state.num_bins = data.num_bins or state.num_bins
        state.num_cols = data.num_cols or state.num_cols
        state.brush_size = data.brush_size or state.brush_size
        state.brush_amp = data.brush_amp or state.brush_amp
        state.speed = data.speed or state.speed
        state.speed_locked = data.speed_locked or false
        state.show_grid = data.show_grid ~= false
        state.snap = data.snap or false
        state.snap_brush = data.snap_brush or false
        state.waveshape = data.waveshape or 0
        state.harmonics = data.harmonics or 4
        state.detune = data.detune or 0
        state.chord_idx = data.chord_idx or 0
        state.grid = data.grid or {}
    end
    if not state.grid or #state.grid == 0 then clear_grid() end
    state.cfg_loaded = true
end

-- ============================================================================
-- Main UI
-- ============================================================================

UI.Init("CP_PaintSynth", 960, 560, {
    persist = SCRIPT_ID,
    padding = 8,
    idle_throttle = false,  -- playhead must keep moving while user isn't interacting
})

load_config()
push_dimensions_to_jsfx()
push_grid_to_jsfx()
push_sound_params()

local WAVESHAPES = {"Sine", "Saw", "Square", "Triangle", "Noise"}

UI.Run(function(theme)
    -- Top toolbar row
    if state.playing then
        if UI.Button("stop", "Stop", {width=80}) then trigger_stop() end
    else
        if UI.Button("play", "Play", {width=80}) then
            state._trig_time = r.time_precise()
            trigger_play()
        end
    end
    UI.SameLine()
    if UI.Button("clear", "Clear", {width=80}) then
        clear_grid()
        push_grid_to_jsfx()
    end
    UI.SameLine()
    local pushed
    pushed, state.show_grid = UI.Checkbox("grid", "Grid", state.show_grid)
    UI.SameLine()
    pushed, state.snap = UI.Checkbox("snap", "Snap", state.snap)
    if pushed then push_dimensions_to_jsfx() end
    UI.SameLine()
    pushed, state.snap_brush = UI.Checkbox("snap_brush", "Snap brush", state.snap_brush)
    UI.SameLine(20)

    UI.Text("Speed")
    UI.SameLine()
    local changed
    changed, state.speed = UI.SliderDouble("speed", "", state.speed, 0.25, 1024, {width=160})
    if changed then push_dimensions_to_jsfx() end
    UI.SameLine()
    changed, state.speed = UI.NumberInput("speed_n", "", state.speed, 0.25, 1024, {step=0.25, speed=0.25, format="%.2f c/s", width=80})
    if changed then push_dimensions_to_jsfx() end
    UI.SameLine()
    pushed, state.speed_locked = UI.Checkbox("spd_lock", "JSFX slider", state.speed_locked)
    if pushed then push_dimensions_to_jsfx() end

    UI.SameLine(20)
    UI.Text("Brush")
    UI.SameLine()
    changed, state.brush_size = UI.SliderInt("bsz", "", state.brush_size, 1, 32, {width=100})
    UI.SameLine()
    changed, state.brush_amp = UI.SliderDouble("bamp", "", state.brush_amp, 0.05, 1.0, {width=100})

    -- Sound row
    UI.Text("Sound")
    UI.SameLine()
    local ws_idx = state.waveshape + 1   -- Combo is 1-based
    changed, ws_idx = UI.Combo("ws", "", ws_idx, WAVESHAPES, {width=110})
    if changed then state.waveshape = ws_idx - 1; push_sound_params() end
    UI.SameLine(12)
    UI.Text("Harm")
    UI.SameLine()
    changed, state.harmonics = UI.SliderInt("harm", "", state.harmonics, 1, 16, {width=120})
    if changed then push_sound_params() end
    UI.SameLine(12)
    UI.Text("Detune")
    UI.SameLine()
    changed, state.detune = UI.SliderDouble("det", "", state.detune, 0, 0.05, {width=120})
    if changed then push_sound_params() end
    UI.SameLine(12)
    UI.Text("Chord")
    UI.SameLine()
    local chord_combo_idx = state.chord_idx + 1
    changed, chord_combo_idx = UI.Combo("chord", "", chord_combo_idx, chord_names(), {width=100})
    if changed then state.chord_idx = chord_combo_idx - 1 end

    UI.Spacing(6)

    -- Canvas: take all remaining space
    local _, cy = UI.GetCursorPos()
    local total_w = gfx.w - 16
    local total_h = gfx.h - cy - 28
    if total_h < 100 then total_h = 100 end

    local canvas = UI.Canvas("paint_canvas", {
        width  = total_w,
        height = total_h,
        bg     = {0.06, 0.07, 0.09, 1},
        border_color = theme.colors.border,
    })

    draw_spectrogram(canvas, theme)
    handle_canvas_input(canvas)

    UI.Spacing(4)
    UI.SetFontCaption()
    UI.Text(string.format("LMB: paint  •  RMB: erase  •  Place CP_PaintSynth_JSFX on a track  •  %d×%d cells",
                          state.num_cols, state.num_bins))
    UI.SetFontBody()
end)

UI.OnClose(function()
    trigger_stop()
    save_config()
end)
