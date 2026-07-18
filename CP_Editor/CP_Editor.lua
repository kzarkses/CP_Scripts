-- @description Editor (CP) — Ableton-style clip editor (audio + MIDI)
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   One editor window, two modes — exactly like Ableton's clip view:
--   click an AUDIO item and get the waveform editor (zoom to sample
--   level, zero-crossing selection, normalize/gain/reverse/pitch
--   (élastique)/rate/fades/trim, transient slicing to split items or
--   straight onto CP_Sampler pads); click a MIDI item and get a piano
--   roll (FL-style: click = insert note, drag = move, right-click =
--   delete, edge = resize, velocity lane, project-grid snap, quantize,
--   drum rows named after the CP_Sampler pads).
--
--   Follows the arrange selection (lock to pin); "Open in Editor" from
--   CP_MediaExplorer / CP_Sampler opens raw files in view/slice mode.
--
--   Requires SWS (preview) — js_ReaScriptAPI recommended.

local r = reaper

-- ---------------------------------------------------------------------------
-- Toolkit + modules
-- ---------------------------------------------------------------------------
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local cp_root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
local UI = dofile(cp_root .. "CP_Toolkit/CP_Toolkit.lua")

local Wave  = dofile(script_path .. "Modules/Wave.lua")
local Ops   = dofile(script_path .. "Modules/Ops.lua")
local Roll  = dofile(script_path .. "Modules/Roll.lua")
local Kit   = dofile(cp_root .. "CP_Sampler/Modules/Kit.lua")
local Audio = dofile(cp_root .. "CP_Toolkit/Audio.lua")

Wave.init(r)
Ops.init(r, Wave)
Roll.init(r)
Kit.init(r)
Audio.init(r)

local Core_tk = UI.Core
local Keys    = UI.Keys

-- ---------------------------------------------------------------------------
-- Config + state
-- ---------------------------------------------------------------------------
local CONFIG_ID = "CP_Editor"
local cfg = UI.LoadConfig(CONFIG_ID) or {}

local opts = {
    snap_zero = cfg.snap_zero ~= false,   -- default true
    norm_db   = cfg.norm_db or 0,         -- normalize target
    midi_snap = cfg.midi_snap ~= false,   -- piano roll: snap to the grid
    grid_div  = cfg.grid_div,             -- editor grid (whole notes), nil = project
}
Audio.volume = cfg.vol or 1.0

local state = {
    -- target
    mode = nil,          -- "item" | "file" | "midi" | nil
    item = nil, take = nil,
    src = nil, own_src = false,
    path = "", name = "",
    len = 0, ch = 1, sr = 0,
    lock = false,
    -- view (source seconds)
    t0 = 0, t1 = 1,
    sel_a = nil, sel_b = nil,
    cursor = 0,
    markers = {},
    sens = cfg.sens or 0.5,
    gen = 0,             -- waveform invalidation counter
    -- interaction
    wpress = nil,        -- {kind="sel"|"fadein"|"fadeout", x, t, moved}
    -- piano roll
    drum_mode = nil,     -- nil = auto (kit exists), true/false = user override
    mdrag = nil,         -- {mode="move"|"resize"|"vel"|"erase", idx, grab, moved}
    last_vel = cfg.last_vel or 100,
    aud_note = nil,      -- pending audition note-off
    aud_off_t = 0,
    -- caches
    meta_line = nil,
    last_change = -1,
    last_open = "",
    flash_msg = "", flash_until = 0,
    cfg_dirty = false,
}

-- wave area rect (client coords, set each frame by drawWave)
local wave = { x = 0, y = 0, w = 0, h = 0, ry = 0, rh = 0 }

local WAVE_BUF = 905
local RULER_H  = 18
local PLAY_OPTS = {}

local function persistConfig()
    state.cfg_dirty = false
    cfg.snap_zero = opts.snap_zero
    cfg.norm_db   = opts.norm_db
    cfg.sens      = state.sens
    cfg.vol       = Audio.volume
    cfg.midi_snap = opts.midi_snap
    cfg.last_vel  = state.last_vel
    UI.SaveConfig(CONFIG_ID, cfg)
end

local function markDirty() state.cfg_dirty = true end

local function flash(msg)
    state.flash_msg = msg
    state.flash_until = r.time_precise() + 2.5
    UI.RequestRedraw()
end

-- ---------------------------------------------------------------------------
-- View helpers
-- ---------------------------------------------------------------------------
local function span() return state.t1 - state.t0 end

local function timeAtX(x)
    return state.t0 + (x - wave.x) / wave.w * span()
end

local function xAtTime(t)
    return wave.x + (t - state.t0) / span() * wave.w
end

local function clampView()
    local sp = span()
    local min_sp = state.sr > 0 and (32 / state.sr) or 0.002
    if sp < min_sp then sp = min_sp end
    if sp > state.len then sp = state.len end
    if state.t0 < 0 then state.t0 = 0 end
    if state.t0 + sp > state.len then state.t0 = state.len - sp end
    if state.t0 < 0 then state.t0 = 0 end
    state.t1 = state.t0 + sp
end

local function fitView()
    state.t0, state.t1 = 0, math.max(state.len, 0.001)
end

local function zoomAt(mx, factor)
    if state.len <= 0 or wave.w <= 0 then return end
    local t = timeAtX(mx)
    state.t0 = t - (t - state.t0) * factor
    state.t1 = t + (state.t1 - t) * factor
    clampView()
end

local function zoomSelection()
    if not state.sel_a then return end
    local pad = (state.sel_b - state.sel_a) * 0.05
    state.t0 = state.sel_a - pad
    state.t1 = state.sel_b + pad
    clampView()
end

-- ---------------------------------------------------------------------------
-- Target management
-- ---------------------------------------------------------------------------
local function dropOwnSource()
    if state.own_src and state.src then
        r.PCM_Source_Destroy(state.src)
    end
    state.src, state.own_src = nil, false
end

local function resetForTarget()
    state.sel_a, state.sel_b = nil, nil
    state.cursor = 0
    for i = #state.markers, 1, -1 do state.markers[i] = nil end
    state.meta_line = nil
    state.gen = state.gen + 1
    fitView()
    Audio.Stop()
end

-- Re-read source-dependent fields (item mode: the take source can be
-- swapped under us — reverse wraps it in a section source).
local function refreshItemFields()
    local src = r.GetMediaItemTake_Source(state.take)
    if src ~= state.src then
        state.src = src
        state.gen = state.gen + 1
        state.meta_line = nil
    end
    state.len  = r.GetMediaSourceLength(src) or 0
    state.ch   = r.GetMediaSourceNumChannels(src) or 1
    state.sr   = r.GetMediaSourceSampleRate(src) or 0
    state.path = r.GetMediaSourceFileName(src) or ""
    clampView()
end

local function setItem(item)
    local take = r.GetActiveTake(item)
    if not take then return false end
    if r.TakeIsMIDI(take) then
        dropOwnSource()
        state.mode, state.item, state.take = "midi", item, take
        local ok, name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        state.name = (ok and name ~= "") and name or "MIDI item"
        state.src, state.path = nil, ""
        state.len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        state.ch, state.sr = 0, 0
        Roll.Attach(take, item)
        state.mdrag = nil
        resetForTarget()
        return true
    end
    dropOwnSource()
    state.mode, state.item, state.take = "item", item, take
    local ok, name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    state.name = (ok and name ~= "") and name or "item"
    state.src = nil
    refreshItemFields()
    resetForTarget()
    return true
end

local function setFile(path)
    local src = r.PCM_Source_CreateFromFile(path)
    if not src then
        flash("Cannot open: " .. path)
        return false
    end
    dropOwnSource()
    state.mode, state.item, state.take = "file", nil, nil
    state.src, state.own_src = src, true
    state.path = path
    state.name = path:match("([^/\\]+)$") or path
    state.len  = r.GetMediaSourceLength(src) or 0
    state.ch   = r.GetMediaSourceNumChannels(src) or 1
    state.sr   = r.GetMediaSourceSampleRate(src) or 0
    resetForTarget()
    return true
end

local function clearTarget()
    dropOwnSource()
    Roll.Detach()
    state.mode, state.item, state.take = nil, nil, nil
    state.path, state.name, state.len = "", "", 0
    state.mdrag = nil
end

-- Region shown brighter + the ops scope: item’s active source region, or
-- the whole file.
local function targetRegion()
    if state.mode == "item" then
        local a, b = Ops.ItemRegion(state.item, state.take)
        return a, b
    end
    return 0, state.len
end

local function metaLine()
    if state.mode == "midi" then
        if state.meta_line and state.meta_rollver == Roll.version then
            return state.meta_line
        end
        state.meta_line = string.format("%d notes  ·  %.2fs", Roll.count, state.len)
        state.meta_rollver = Roll.version
        return state.meta_line
    end
    if state.meta_line then return state.meta_line end
    if not state.mode then
        state.meta_line = ""
        return ""
    end
    state.meta_line = string.format("%.3fs  ·  %dch  ·  %.1fk%s",
        state.len, state.ch, state.sr / 1000,
        state.mode == "file" and "  ·  file (view/slice)" or "")
    return state.meta_line
end

-- ---------------------------------------------------------------------------
-- Target polling (arrange selection follow + cross-script open + validity)
-- ---------------------------------------------------------------------------
local function pollTarget()
    -- "Open in Editor" from ME / Sampler (5s freshness window)
    local v = r.GetExtState("CP_Editor", "open")
    if v ~= "" and v ~= state.last_open then
        state.last_open = v
        local ts, path = v:match("^([^\n]+)\n(.*)$")
        ts = tonumber(ts)
        if ts and path and path ~= "" and r.time_precise() - ts < 5.0 then
            setFile(path)
        end
    end

    -- follow the arrange selection
    if not state.lock then
        local it = r.GetSelectedMediaItem(0, 0)
        if it and it ~= state.item then
            setItem(it)
        end
    end

    -- project edits: revalidate + refresh (undo can kill the item)
    local c = r.GetProjectStateChangeCount(0)
    if c ~= state.last_change then
        state.last_change = c
        if state.mode == "item" then
            if not r.ValidatePtr2(0, state.item, "MediaItem*")
               or not r.ValidatePtr2(0, state.take, "MediaItem_Take*") then
                clearTarget()
            else
                refreshItemFields()
                state.gen = state.gen + 1
            end
        elseif state.mode == "midi" then
            if not r.ValidatePtr2(0, state.item, "MediaItem*")
               or not r.ValidatePtr2(0, state.take, "MediaItem_Take*") then
                clearTarget()
            else
                state.len = r.GetMediaItemInfo_Value(state.item, "D_LENGTH")
                clampView()
                -- re-read notes on EXTERNAL edits — never mid-drag (our
                -- own live writes bump the counter every drag frame and
                -- a re-sort would trash the dragged note's index)
                if not state.mdrag then Roll.Sync() end
            end
        end
        UI.RequestRedraw()
    end
end

-- ---------------------------------------------------------------------------
-- Playback
-- ---------------------------------------------------------------------------
local function togglePlay()
    if state.mode == "midi" then
        -- MIDI previews in context: the item plays through its track
        r.Main_OnCommand(40044, 0)   -- Transport: Play/stop
        return
    end
    if Audio.IsPlaying() then
        Audio.Stop()
        return
    end
    if state.path == "" then
        flash("No previewable file for this source (section/reversed)")
        return
    end
    PLAY_OPTS.start_s = state.sel_a or state.cursor
    PLAY_OPTS.end_s   = state.sel_b
    Audio.Play(state.path, PLAY_OPTS)
end

-- ---------------------------------------------------------------------------
-- Slicing
-- ---------------------------------------------------------------------------
local function detectMarkers()
    if not state.src then return end
    local a, b = targetRegion()
    if state.sel_a then a, b = state.sel_a, state.sel_b end
    local n = Ops.DetectTransients(state.src, a, b, state.sens, state.markers)
    flash(n .. " transients")
    UI.RequestRedraw()
end

local function clearMarkers()
    for i = #state.markers, 1, -1 do state.markers[i] = nil end
    UI.RequestRedraw()
end

local function splitAtMarkers()
    if state.mode ~= "item" or #state.markers == 0 then return end
    local made = Ops.SplitAt(state.item, state.take, state.markers)
    flash("Split into " .. (made + 1) .. " items")
end

-- Slice boundaries = region start + markers + region end.
local function slicesToPads()
    if not state.src or state.path == "" then
        flash("Slices need a real file path")
        return
    end
    local a, b = targetRegion()
    if state.sel_a then a, b = state.sel_a, state.sel_b end
    local count = 0
    Kit.Batch("Sampler: slice to pads", function()
        local prev = a
        local function push(t)
            if t - prev < 0.001 then return end
            local note = Kit.FirstEmpty()
            if not note then return end
            if Kit.LoadSample(note, state.path) then
                Kit.SetOffsets(note, prev / state.len, t / state.len)
                count = count + 1
            end
            prev = t
        end
        for i = 1, #state.markers do
            local t = state.markers[i]
            if t > a and t < b then push(t) end
        end
        push(b)
    end)
    flash(count > 0 and (count .. " slices sent to Sampler pads")
                     or "No empty pads (or no slices)")
end

local function selectionToPad()
    if not state.sel_a or state.path == "" then
        flash("Select a region first")
        return
    end
    local note = Kit.FirstEmpty()
    if not note then
        flash("No empty pad")
        return
    end
    Kit.Batch("Sampler: selection to pad", function()
        if Kit.LoadSample(note, state.path) then
            Kit.SetOffsets(note, state.sel_a / state.len,
                                 state.sel_b / state.len)
        end
    end)
    flash("Selection sent to pad " .. note)
end

-- ---------------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------------
local ICONBTN_OPTS = { width = 0, height = 0 }
local NUM_W  = { step = 0.5, format = "%.1f", width = 64 }
local NUM_P  = { step = 1, format = "%+.0f", width = 56 }
local NUM_R  = { step = 0.05, format = "%.2f", width = 56 }
local SENS_OPTS = { width = 110 }

local function iconBtn(id, icon_fn, tip, size)
    local theme = UI.GetTheme()
    size = size or theme.button_height
    local cx, cy = UI.GetCursorPos()
    ICONBTN_OPTS.width, ICONBTN_OPTS.height = size, size
    local clicked = UI.Button(id, "", ICONBTN_OPTS)
    local color = theme.colors.text
    icon_fn(cx, cy, size, color[1], color[2], color[3], color[4] or 1)
    if tip and Core_tk.MouseInRect(cx, cy, size, size) then UI.Tooltip(tip) end
    return clicked
end

local function openSettings()
    local function normItem(db)
        return { label = db == 0 and "0 dBFS" or (db .. " dBFS"),
                 checked = opts.norm_db == db,
                 action = function() opts.norm_db = db markDirty() end }
    end
    local function volItem(pct)
        return { label = pct .. "%", checked = Audio.volume == pct / 100,
                 action = function() Audio.SetVolume(pct / 100) markDirty() end }
    end
    UI.NativeMenu({
        { label = "Snap selection to zero crossings", checked = opts.snap_zero,
          action = function() opts.snap_zero = not opts.snap_zero markDirty() end },
        { label = "Normalize target", children = {
            normItem(0), normItem(-1), normItem(-3), normItem(-6),
        } },
        { label = "Preview volume", children = {
            volItem(25), volItem(50), volItem(75), volItem(100),
        } },
    })
end

local function drawToolbar(theme)
    local btn = theme.button_height

    -- lock / follow
    local cx, cy = UI.GetCursorPos()
    ICONBTN_OPTS.width, ICONBTN_OPTS.height = btn, btn
    if UI.Button("lock", "", ICONBTN_OPTS) then
        state.lock = not state.lock
    end
    local lc = state.lock and theme.colors.accent or theme.colors.text_disabled
    local licon = state.lock and UI.Icons.Lock or UI.Icons.Unlock
    licon(cx, cy, btn, lc[1], lc[2], lc[3], lc[4] or 1)
    if Core_tk.MouseInRect(cx, cy, btn, btn) then
        UI.Tooltip(state.lock and "Locked: keeps this target (click to follow the arrange selection)"
                               or "Following the arrange selection (click to lock)")
    end

    UI.SameLine()
    UI.SetFontH2()
    UI.Text(state.mode and state.name or "Sample Editor")
    UI.SetFontCaption()
    UI.SameLine(10)
    UI.Text(metaLine(), { disabled = true })
    UI.SetFontBody()

    -- right: transport + view + settings
    local right_w = btn * 5 + theme.item_spacing * 4
    local gap = UI.GetAvailableWidth() - right_w
    if gap > 0 then UI.SameLine(gap) else UI.SameLine() end
    local playing = Audio.IsPlaying()
    if iconBtn("play", playing and UI.Icons.Stop or UI.Icons.Play,
               "Play selection / from cursor (Space)") then
        togglePlay()
    end
    UI.SameLine()
    if iconBtn("zfit", UI.Icons.Refresh, "Fit whole sample (Home)") then
        fitView()
    end
    UI.SameLine()
    if iconBtn("zin", UI.Icons.Plus, "Zoom in (wheel on the waveform)") then
        zoomAt(wave.x + wave.w / 2, 1 / 1.5)
    end
    UI.SameLine()
    if iconBtn("zout", UI.Icons.Minus, "Zoom out") then
        zoomAt(wave.x + wave.w / 2, 1.5)
    end
    UI.SameLine()
    if iconBtn("settings", UI.Icons.Settings, "Settings") then
        openSettings()
    end
    UI.Spacing(0)
end

local function drawOpsRow(theme)
    if state.mode ~= "item" then
        UI.SetFontCaption()
        UI.Text(state.mode == "file"
                and "File mode — select, slice, send to Sampler pads. Select an arrange item for full editing."
                or "Select an audio item in the arrange, or send a file from the Media Explorer.",
                { disabled = true })
        UI.SetFontBody()
        return
    end

    -- gain / pitch / rate — live take values, event-driven writes
    local db = Ops.VolDB(state.take)
    local changed, ndb = UI.NumberInput("op_gain", "Gain dB", db, -60, 24, NUM_W)
    if changed then Ops.SetVolDB(state.item, state.take, ndb) end

    UI.SameLine()
    local pitch = r.GetMediaItemTakeInfo_Value(state.take, "D_PITCH")
    local pch, npitch = UI.NumberInput("op_pitch", "Pitch st", pitch, -48, 48, NUM_P)
    if pch then Ops.SetPitch(state.take, state.item, npitch) end

    UI.SameLine()
    local rate = r.GetMediaItemTakeInfo_Value(state.take, "D_PLAYRATE")
    local rch, nrate = UI.NumberInput("op_rate", "Rate", rate, 0.25, 4, NUM_R)
    if rch then Ops.SetRate(state.item, state.take, nrate, true) end

    UI.SameLine()
    if UI.Button("op_norm", "Normalize") then
        local a, b = targetRegion()
        if state.sel_a then a, b = state.sel_a, state.sel_b end
        if Ops.Normalize(state.item, state.take, state.src, a, b, opts.norm_db) then
            flash("Normalized to " .. opts.norm_db .. " dBFS")
        else
            flash("Normalize: no peaks readable")
        end
    end
    UI.SameLine()
    if UI.Button("op_rev", "Reverse") then
        Ops.Reverse(state.item)
    end
    UI.SameLine()
    UI.BeginDisabled(state.sel_a == nil)
    if UI.Button("op_trim", "Trim to selection") then
        Ops.TrimToSel(state.item, state.take, state.sel_a, state.sel_b)
        state.sel_a, state.sel_b = nil, nil
    end
    UI.EndDisabled()
end

local function drawSliceRow(theme)
    local sch, nsens = UI.SliderDouble("sl_sens", "Sens", state.sens, 0, 1, SENS_OPTS)
    if sch then
        state.sens = nsens
        markDirty()
    end
    UI.SameLine()
    if UI.Button("sl_detect", "Detect") then detectMarkers() end
    UI.SameLine()
    UI.BeginDisabled(#state.markers == 0)
    if UI.Button("sl_clear", "Clear") then clearMarkers() end
    UI.SameLine()
    if UI.Button("sl_split", "Split item") then splitAtMarkers() end
    UI.SameLine()
    if UI.Button("sl_pads", "Slices to pads") then slicesToPads() end
    UI.EndDisabled()
    UI.SameLine()
    UI.BeginDisabled(state.sel_a == nil)
    if UI.Button("sl_selpad", "Sel to pad") then selectionToPad() end
    UI.EndDisabled()
end

-- ---------------------------------------------------------------------------
-- Ruler (labels cached per view — pan rebuilds, idle costs nothing)
-- ---------------------------------------------------------------------------
local ruler = { t0 = -1, t1 = -1, w = 0, n = 0, xs = {}, lbls = {} }
local NICE = { 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
               1, 2, 5, 10, 30, 60, 120, 300 }

local function rulerBuild()
    if ruler.t0 == state.t0 and ruler.t1 == state.t1 and ruler.w == wave.w then
        return
    end
    ruler.t0, ruler.t1, ruler.w = state.t0, state.t1, wave.w
    local target = span() / 6
    local step = NICE[#NICE]
    for i = 1, #NICE do
        if NICE[i] >= target then step = NICE[i] break end
    end
    local fmt = step >= 1 and "%.0f" or (step >= 0.01 and "%.2f" or "%.3f")
    local n = 0
    local t = math.ceil(state.t0 / step) * step
    while t <= state.t1 and n < 16 do
        n = n + 1
        ruler.xs[n] = xAtTime(t)
        ruler.lbls[n] = string.format(fmt, t)
        t = t + step
    end
    ruler.n = n
end

-- ---------------------------------------------------------------------------
-- Waveform buffer (re-rendered only when the view/audio changes)
-- ---------------------------------------------------------------------------
local wb = { src = nil, t0 = -1, t1 = -1, w = 0, h = 0, gen = -1 }

local function renderWave(theme, entry, w, h)
    if wb.src == state.src and wb.t0 == state.t0 and wb.t1 == state.t1
       and wb.w == w and wb.h == h and wb.gen == state.gen then
        return
    end
    wb.src, wb.t0, wb.t1, wb.w, wb.h, wb.gen =
        state.src, state.t0, state.t1, w, h, state.gen

    gfx.dest = WAVE_BUF
    gfx.setimgdim(WAVE_BUF, w, h)
    gfx.muladdrect(0, 0, w, h, 0, 0, 0, 0)   -- contents undefined after resize

    local bg = theme.colors.list_bg or theme.colors.window_bg
    gfx.set(bg[1], bg[2], bg[3], 1)
    gfx.rect(0, 0, w, h, 1)

    local ch = entry.ch
    local lane_h = h / ch
    local mid_c = theme.colors.text_mute or theme.colors.text_disabled
    local wf = theme.colors.accent
    for c = 1, ch do
        local mid = (c - 0.5) * lane_h
        gfx.set(mid_c[1], mid_c[2], mid_c[3], 0.35)
        gfx.line(0, mid, w - 1, mid)
        gfx.set(wf[1], wf[2], wf[3], 0.9)
        local scale = lane_h * 0.47
        local maxs, mins = entry.maxs[c], entry.mins[c]
        for px = 1, entry.n do
            local y1 = mid - (maxs[px] or 0) * scale
            local y2 = mid - (mins[px] or 0) * scale
            if y2 - y1 < 1 then y2 = y1 + 1 end
            gfx.line(px - 1, y1, px - 1, y2)
        end
    end
    gfx.dest = -1
end

-- ---------------------------------------------------------------------------
-- Wave area (draw + input)
-- ---------------------------------------------------------------------------
local function fadeHandles()
    -- returns fin_x, fout_x (client x of the fade handles) or nil
    if state.mode ~= "item" then return nil end
    local a, b, rate = Ops.ItemRegion(state.item, state.take)
    local fin  = r.GetMediaItemInfo_Value(state.item, "D_FADEINLEN") * rate
    local fout = r.GetMediaItemInfo_Value(state.item, "D_FADEOUTLEN") * rate
    return xAtTime(a + fin), xAtTime(b - fout), a, b, rate
end

local function waveInput(theme)
    local mx, my = Core_tk.GetMousePos()
    local inside = mx >= wave.x and mx < wave.x + wave.w
               and my >= wave.ry and my < wave.ry + wave.rh
    if Core_tk.HasPopup() then inside = false end

    -- wheel = zoom at mouse
    if inside then
        local wheel = Core_tk.GetState().mouse_wheel
        if wheel and wheel ~= 0 then
            local notches = wheel / 120
            zoomAt(mx, notches > 0 and (1 / 1.25) ^ notches or 1.25 ^ (-notches))
            UI.ConsumeWheel()
        end
        -- middle-drag pan
        if Core_tk.MouseDown(64) then
            local dx = Core_tk.MouseDelta()
            if dx ~= 0 then
                local dt = -dx * span() / wave.w
                state.t0 = state.t0 + dt
                state.t1 = state.t1 + dt
                clampView()
            end
            UI.SetCursor("size_all")
        end
    end

    -- press: fade handles first, then selection
    if inside and Core_tk.MouseClicked(1) then
        local fin_x, fout_x = fadeHandles()
        if fin_x and my < wave.ry + 14 and math.abs(mx - fin_x) < 7 then
            state.wpress = { kind = "fadein" }
        elseif fout_x and my < wave.ry + 14 and math.abs(mx - fout_x) < 7 then
            state.wpress = { kind = "fadeout" }
        else
            state.wpress = { kind = "sel", x = mx, t = timeAtX(mx), moved = false }
        end
    end

    local wp = state.wpress
    if wp then
        if Core_tk.MouseDown(1) then
            local t = timeAtX(mx)
            if t < 0 then t = 0 elseif t > state.len then t = state.len end
            if wp.kind == "sel" then
                if wp.moved or math.abs(mx - wp.x) > 3 then
                    wp.moved = true
                    if t < wp.t then
                        state.sel_a, state.sel_b = t, wp.t
                    else
                        state.sel_a, state.sel_b = wp.t, t
                    end
                end
            elseif state.mode == "item" then
                local _, _, a, b, rate = fadeHandles()
                if wp.kind == "fadein" then
                    local f = (t - a) / rate
                    if f < 0 then f = 0 end
                    Ops.SetFades(state.item, f, nil)
                else
                    local f = (b - t) / rate
                    if f < 0 then f = 0 end
                    Ops.SetFades(state.item, nil, f)
                end
            end
        else
            -- release
            if wp.kind == "sel" then
                if not wp.moved then
                    state.cursor = wp.t
                    state.sel_a, state.sel_b = nil, nil
                elseif opts.snap_zero and state.src then
                    state.sel_a = Ops.SnapZero(state.src, state.sel_a)
                    state.sel_b = Ops.SnapZero(state.src, state.sel_b)
                end
            else
                Ops.CommitFades()
            end
            state.wpress = nil
        end
    end

    -- right-click context
    if inside and Core_tk.MouseClicked(2) then
        UI.NativeMenu({
            { label = "Fit (Home)", action = fitView },
            { label = "Zoom to selection", disabled = state.sel_a == nil,
              action = zoomSelection },
            { separator = true },
            { label = "Clear selection", disabled = state.sel_a == nil,
              action = function() state.sel_a, state.sel_b = nil, nil end },
            { label = "Clear markers", disabled = #state.markers == 0,
              action = clearMarkers },
            { separator = true },
            { label = "Snap to zero crossings", checked = opts.snap_zero,
              action = function() opts.snap_zero = not opts.snap_zero markDirty() end },
        })
    end
end

local function drawWave(theme, area_h)
    local gx, gy = UI.GetCursorPos()
    local aw = UI.GetAvailableWidth()
    wave.x, wave.y, wave.w, wave.h = gx, gy, aw, area_h
    wave.ry, wave.rh = gy + RULER_H, area_h - RULER_H

    local col_bg   = theme.colors.list_bg or theme.colors.window_bg
    local col_mute = theme.colors.text_mute or theme.colors.text_disabled
    local col_acc  = theme.colors.accent
    local col_text = theme.colors.text
    local col_mark = theme.colors.value_modified or col_acc

    -- ruler strip
    Core_tk.DrawRect(gx, gy, aw, RULER_H,
                     col_bg[1] * 0.8, col_bg[2] * 0.8, col_bg[3] * 0.8, 1)

    if not state.mode or not state.src or state.len <= 0 then
        Core_tk.DrawRect(gx, wave.ry, aw, wave.rh,
                         col_bg[1], col_bg[2], col_bg[3], 1)
        UI.SetFontCaption()
        local hint = "Select an audio item in the arrange"
        local tw = Core_tk.MeasureText(hint)
        Core_tk.DrawText(hint, gx + (aw - tw) / 2, gy + area_h / 2 - 7,
                         col_mute[1], col_mute[2], col_mute[3], 1)
        UI.SetFontBody()
        UI.Layout.AdvanceCursor(aw, area_h)
        return
    end

    local entry = Wave.Read(state.src, state.path, state.t0, state.t1,
                            aw, state.gen)
    if entry then
        renderWave(theme, entry, aw, wave.rh)
        gfx.dest = -1
        gfx.a, gfx.mode = 1, 0
        gfx.blit(WAVE_BUF, 1, 0, 0, 0, aw, wave.rh, gx, wave.ry, aw, wave.rh)
    else
        Core_tk.DrawRect(gx, wave.ry, aw, wave.rh,
                         col_bg[1], col_bg[2], col_bg[3], 1)
        UI.SetFontCaption()
        Core_tk.DrawText("building peaks...", gx + 8, gy + area_h / 2 - 7,
                         col_mute[1], col_mute[2], col_mute[3], 1)
        UI.SetFontBody()
        UI.RequestRedraw()
    end

    -- ruler ticks + labels
    rulerBuild()
    UI.SetFontCaption()
    for i = 1, ruler.n do
        local x = ruler.xs[i]
        Core_tk.DrawRect(x, gy + RULER_H - 5, 1, 5,
                         col_mute[1], col_mute[2], col_mute[3], 0.8)
        Core_tk.DrawRect(x, wave.ry, 1, wave.rh,
                         col_mute[1], col_mute[2], col_mute[3], 0.08)
        Core_tk.DrawText(ruler.lbls[i], x + 3, gy + 2,
                         col_mute[1], col_mute[2], col_mute[3], 1)
    end
    UI.SetFontBody()

    -- item region bounds + dim outside
    if state.mode == "item" then
        local a, b = targetRegion()
        local xa, xb = xAtTime(a), xAtTime(b)
        if xa > gx then
            Core_tk.DrawRect(gx, wave.ry, math.min(xa - gx, aw), wave.rh,
                             0, 0, 0, 0.35)
        end
        if xb < gx + aw then
            Core_tk.DrawRect(math.max(xb, gx), wave.ry,
                             gx + aw - math.max(xb, gx), wave.rh, 0, 0, 0, 0.35)
        end
        -- fades (wedge outline + top handles)
        local fin_x, fout_x = fadeHandles()
        if fin_x and fin_x > xa + 1 then
            UI.DrawTriangle(xa, wave.ry + wave.rh, xa, wave.ry,
                            fin_x, wave.ry,
                            col_text[1], col_text[2], col_text[3], 0.10)
        end
        if fout_x and fout_x < xb - 1 then
            UI.DrawTriangle(fout_x, wave.ry, xb, wave.ry,
                            xb, wave.ry + wave.rh,
                            col_text[1], col_text[2], col_text[3], 0.10)
        end
        if fin_x then
            Core_tk.DrawRect(fin_x - 3, wave.ry, 7, 7,
                             col_text[1], col_text[2], col_text[3], 0.9)
        end
        if fout_x then
            Core_tk.DrawRect(fout_x - 3, wave.ry, 7, 7,
                             col_text[1], col_text[2], col_text[3], 0.9)
        end
    end

    -- selection
    if state.sel_a then
        local xa, xb = xAtTime(state.sel_a), xAtTime(state.sel_b)
        if xb > gx and xa < gx + aw then
            Core_tk.DrawRect(math.max(xa, gx), wave.ry,
                             math.min(xb, gx + aw) - math.max(xa, gx), wave.rh,
                             col_acc[1], col_acc[2], col_acc[3], 0.20)
            Core_tk.DrawRect(xa, wave.ry, 1, wave.rh,
                             col_acc[1], col_acc[2], col_acc[3], 0.9)
            Core_tk.DrawRect(xb, wave.ry, 1, wave.rh,
                             col_acc[1], col_acc[2], col_acc[3], 0.9)
        end
    end

    -- transient markers
    for i = 1, #state.markers do
        local t = state.markers[i]
        if t >= state.t0 and t <= state.t1 then
            local x = xAtTime(t)
            Core_tk.DrawRect(x, wave.ry, 1, wave.rh,
                             col_mark[1], col_mark[2], col_mark[3], 0.7)
            UI.DrawTriangle(x - 4, wave.ry, x + 4, wave.ry, x, wave.ry + 6,
                            col_mark[1], col_mark[2], col_mark[3], 0.9)
        end
    end

    -- edit cursor
    if state.cursor >= state.t0 and state.cursor <= state.t1 then
        local x = xAtTime(state.cursor)
        Core_tk.DrawRect(x, wave.ry, 1, wave.rh,
                         col_text[1], col_text[2], col_text[3], 0.8)
    end

    -- playback position (source domain — we play the raw file)
    if Audio.IsPlaying(state.path ~= "" and state.path or nil) then
        local pos = Audio.Progress()
        if pos and pos >= state.t0 and pos <= state.t1 then
            local x = xAtTime(pos)
            Core_tk.DrawRect(x, wave.ry, 1, wave.rh,
                             col_acc[1], col_acc[2], col_acc[3], 1)
        end
        UI.RequestRedraw()
    end

    waveInput(theme)
    UI.Layout.AdvanceCursor(aw, area_h)
end

-- ===========================================================================
-- PIANO ROLL (MIDI mode)
-- ===========================================================================
local NOTE_NAMES = {}
do
    local N = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
    for note = 0, 127 do
        NOTE_NAMES[note] = N[note % 12 + 1] .. tostring(math.floor(note / 12) - 1)
    end
end
local BLACK_KEY = { [1] = true, [3] = true, [6] = true, [8] = true, [10] = true }
local VEL_H  = 44     -- velocity lane height
local MROLL_BUF = 906 -- grid background buffer (905 = waveform)

-- Audition through the CP_Sampler kit bus (armed bus hears the VKB).
local function auditionNote(pitch, vel)
    if state.aud_note then Kit.StuffNote(state.aud_note, false) end
    Kit.StuffNote(pitch, true, vel or state.last_vel)
    state.aud_note = pitch
    state.aud_off_t = r.time_precise() + 0.2
end

-- ---------------------------------------------------------------------------
-- Project-grid snap (QN domain — tempo changes respected)
-- ---------------------------------------------------------------------------
local function gridStepQN()
    local division = opts.grid_div
    if not division then
        local _, d = r.GetSetProjectGrid(0, false)
        division = d
    end
    if not division or division <= 0 then division = 0.25 end
    return division * 4   -- whole notes → quarter notes
end

local function itemPos()
    return r.GetMediaItemInfo_Value(state.item, "D_POSITION")
end

local function midiSnap(t)
    if not opts.midi_snap then return t end
    local pos = itemPos()
    local qn = r.TimeMap2_timeToQN(0, pos + t)
    local step = gridStepQN()
    qn = math.floor(qn / step + 0.5) * step
    local nt = r.TimeMap2_QNToTime(0, qn) - pos
    if nt < 0 then nt = 0 end
    return nt
end

-- Cell snap (FL insert semantics): the note lands in the cell UNDER the
-- cursor — round-to-nearest used to push clicks into the NEXT cell.
local function midiSnapFloor(t)
    if not opts.midi_snap then return t end
    local pos = itemPos()
    local qn = r.TimeMap2_timeToQN(0, pos + t)
    local step = gridStepQN()
    qn = math.floor(qn / step + 0.0001) * step
    local nt = r.TimeMap2_QNToTime(0, qn) - pos
    if nt < 0 then nt = 0 end
    return nt
end

-- One grid step, in seconds, around item-relative time t.
local function gridStepSec(t)
    local pos = itemPos()
    local qn = r.TimeMap2_timeToQN(0, pos + t)
    return r.TimeMap2_QNToTime(0, qn + gridStepQN()) - (pos + t)
end

-- "Grid 1/16" display label, cached until the division changes (read per
-- frame — no concat in the frame path)
local grid_lbl = { div = -1, s = "" }
local function gridLabel()
    local division = gridStepQN() / 4
    if grid_lbl.div ~= division then
        grid_lbl.div = division
        local denom = 1 / division
        if denom >= 1 and math.abs(denom - math.floor(denom + 0.5)) < 0.01 then
            grid_lbl.s = string.format("Grid 1/%d%s", math.floor(denom + 0.5),
                                       opts.grid_div and "" or " (proj)")
        else
            grid_lbl.s = string.format("Grid %.3g%s", division,
                                       opts.grid_div and "" or " (proj)")
        end
    end
    return grid_lbl.s
end

local GRID_CHOICES = {
    { "1/1", 1 }, { "1/2", 0.5 }, { "1/4", 0.25 }, { "1/8", 0.125 },
    { "1/16", 0.0625 }, { "1/32", 0.03125 }, { "1/64", 0.015625 },
    { "1/8 T", 1 / 12 }, { "1/16 T", 1 / 24 },
}

local function gridMenu()
    local items = {
        { label = "Follow project grid", checked = opts.grid_div == nil,
          action = function()
              opts.grid_div = nil
              grid_lbl.div = -1
              markDirty()
          end },
        { separator = true },
    }
    for _, c in ipairs(GRID_CHOICES) do
        items[#items + 1] = { label = c[1], checked = opts.grid_div == c[2],
            action = function()
                opts.grid_div = c[2]
                grid_lbl.div = -1
                markDirty()
            end }
    end
    UI.NativeMenu(items)
end

-- ---------------------------------------------------------------------------
-- Rows (event-driven build; drum mode shows pad rows named after the kit)
-- ---------------------------------------------------------------------------
local mrows = { list = {}, map = {}, n = 0, drum = false, key = nil }

local function rollRows()
    local drum = state.drum_mode
    if drum == nil then drum = Kit.Exists() end
    local key = (drum and 1 or 0) .. ":" .. Roll.version .. ":" .. Kit.version
    if mrows.key == key then return mrows end
    mrows.key = key
    mrows.drum = drum
    local list = mrows.list
    for i = #list, 1, -1 do list[i] = nil end
    if drum then
        local set = {}
        for note = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
            local pad = Kit.pads[note]
            if pad and pad.fx then set[note] = true end
        end
        for i = 1, Roll.count do set[Roll.pitches[i]] = true end
        for p = 127, 0, -1 do
            if set[p] then list[#list + 1] = p end
        end
        if #list == 0 then
            for p = 51, 36, -1 do list[#list + 1] = p end
        end
    else
        local lo, hi = 127, 0
        for i = 1, Roll.count do
            local p = Roll.pitches[i]
            if p < lo then lo = p end
            if p > hi then hi = p end
        end
        if hi < lo then lo, hi = 48, 71 end
        lo, hi = math.max(0, lo - 2), math.min(127, hi + 2)
        if hi - lo < 11 then hi = math.min(127, lo + 11) end
        for p = hi, lo, -1 do list[#list + 1] = p end
    end
    local map = mrows.map
    for k in pairs(map) do map[k] = nil end
    for idx = 1, #list do map[list[idx]] = idx end
    mrows.n = #list
    return mrows
end

-- ---------------------------------------------------------------------------
-- Toolbar row (MIDI mode)
-- ---------------------------------------------------------------------------
local VEL_OPTS = { step = 1, format = "%.0f", width = 56 }

local function drawMidiBar(theme)
    local stog, son = UI.Checkbox("m_snap", "Snap", opts.midi_snap)
    if stog then
        opts.midi_snap = son
        markDirty()
    end
    UI.SameLine()
    -- grid picker (project grid by default, or a fixed division)
    if UI.Button("m_grid", gridLabel()) then
        gridMenu()
    end
    UI.SameLine()
    local rows = rollRows()
    local dtog, don = UI.Checkbox("m_drum", "Drum rows", rows.drum)
    if dtog then
        state.drum_mode = don
        mrows.key = nil
    end
    UI.SameLine()
    local vch, nv = UI.NumberInput("m_vel", "Vel", state.last_vel, 1, 127, VEL_OPTS)
    if vch then
        state.last_vel = math.floor(nv + 0.5)
        markDirty()
    end
    UI.SameLine()
    if UI.Button("m_quant", "Quantize") then
        local n = Roll.Quantize(midiSnap)
        flash(n .. " notes quantized" .. (Roll.sel and " (selected)" or ""))
    end
    UI.SameLine()
    if UI.Button("m_native", "Native editor") then
        r.SelectAllMediaItems(0, false)
        r.SetMediaItemSelected(state.item, true)
        r.Main_OnCommand(40153, 0)   -- Item: open in built-in MIDI editor
    end
end

-- ---------------------------------------------------------------------------
-- Roll view: grid buffer + notes + labels lane + velocity lane
-- ---------------------------------------------------------------------------
local wbm = { t0 = -1, t1 = -1, w = 0, h = 0, rows = nil, step = 0 }

local function renderRollGrid(theme, rows, w, h, row_h)
    local step = gridStepQN()
    if wbm.t0 == state.t0 and wbm.t1 == state.t1 and wbm.w == w
       and wbm.h == h and wbm.rows == rows.key and wbm.step == step then
        return
    end
    wbm.t0, wbm.t1, wbm.w, wbm.h = state.t0, state.t1, w, h
    wbm.rows, wbm.step = rows.key, step

    gfx.dest = MROLL_BUF
    gfx.setimgdim(MROLL_BUF, w, h)
    gfx.muladdrect(0, 0, w, h, 0, 0, 0, 0)
    local bg = theme.colors.list_bg or theme.colors.window_bg
    gfx.set(bg[1], bg[2], bg[3], 1)
    gfx.rect(0, 0, w, h, 1)

    -- row shading: black keys (melodic) / alternation (drum)
    gfx.set(0, 0, 0, 0.18)
    for i = 1, rows.n do
        local p = rows.list[i]
        local shade = rows.drum and (i % 2 == 0) or BLACK_KEY[p % 12]
        if shade then
            gfx.rect(0, (i - 1) * row_h, w, row_h + 1, 1)
        end
    end
    -- row separators
    if row_h >= 7 then
        local mc = theme.colors.text_mute or theme.colors.text_disabled
        gfx.set(mc[1], mc[2], mc[3], 0.08)
        for i = 1, rows.n - 1 do
            gfx.line(0, i * row_h, w - 1, i * row_h)
        end
    end
    -- vertical grid: project-grid steps, measure starts stronger
    local pos = itemPos()
    local gc = theme.colors.text_mute or theme.colors.text_disabled
    local qn = math.floor(r.TimeMap2_timeToQN(0, pos + state.t0) / step) * step
    local guard = 0
    while guard < 512 do
        guard = guard + 1
        local t = r.TimeMap2_QNToTime(0, qn) - pos
        if t > state.t1 then break end
        if t >= state.t0 then
            local x = (t - state.t0) / span() * w
            local _, mstart = r.TimeMap_QNToMeasures(0, qn + 0.0001)
            local strong = math.abs(qn - (mstart or -1)) < 0.001
            gfx.set(gc[1], gc[2], gc[3], strong and 0.35 or 0.12)
            gfx.line(x, 0, x, h - 1)
        end
        qn = qn + step
    end
    gfx.dest = -1
end

-- Contiguous same-pitch run containing note idx: notes that touch end→
-- start within a small epsilon (a subdivided beat). Returns a, b, count.
local function noteRun(idx)
    local pitch = Roll.pitches[idx]
    local a, b = Roll.starts[idx], Roll.starts[idx] + Roll.lens[idx]
    local count = 1
    local moved = true
    while moved do
        moved = false
        for i = 1, Roll.count do
            if i ~= idx and Roll.pitches[i] == pitch then
                local s, e = Roll.starts[i], Roll.starts[i] + Roll.lens[i]
                if math.abs(e - a) < 0.002 then a = s count = count + 1 moved = true
                elseif math.abs(s - b) < 0.002 then b = e count = count + 1 moved = true end
            end
        end
    end
    return a, b, count
end

local function rollInput(theme, rows, row_h, lane_w, vy)
    local mx, my = Core_tk.GetMousePos()
    local in_grid = mx >= wave.x and mx < wave.x + wave.w
                and my >= wave.ry and my < wave.ry + wave.rh
    local in_vel = mx >= wave.x and mx < wave.x + wave.w
               and my >= vy and my < vy + VEL_H
    if Core_tk.HasPopup() then in_grid, in_vel = false, false end

    local t = timeAtX(mx)
    local row = math.floor((my - wave.ry) / row_h) + 1
    local pitch = rows.list[row]

    -- zoom / pan / subdivide
    if in_grid or in_vel then
        local wheel = Core_tk.GetState().mouse_wheel
        if wheel and wheel ~= 0 then
            -- Ctrl+Shift+Wheel on a note = trap-roll subdivide: the whole
            -- run under the cursor becomes n*2 (up) or n/2 (down) notes
            -- filling the same span. Falls back to zoom otherwise.
            local idx = (in_grid and pitch) and Roll.At(t, pitch) or nil
            if idx and Core_tk.ModCtrl() and Core_tk.ModShift() then
                local a, b, n = noteRun(idx)
                local vel = Roll.vels[idx]
                if wheel > 0 then n = n * 2 else n = math.max(1, math.floor(n / 2)) end
                if n <= 64 then
                    Roll.Subdivide(a, b, pitch, vel, n)
                    flash(n == 1 and "merged" or (n .. " notes"))
                end
                UI.ConsumeWheel()
                return
            end
            local notches = wheel / 120
            zoomAt(mx, notches > 0 and (1 / 1.25) ^ notches or 1.25 ^ (-notches))
            UI.ConsumeWheel()
        end
        if Core_tk.MouseDown(64) then
            local dx = Core_tk.MouseDelta()
            if dx ~= 0 then
                local dt = -dx * span() / wave.w
                state.t0 = state.t0 + dt
                state.t1 = state.t1 + dt
                clampView()
            end
            UI.SetCursor("size_all")
        end
    end

    -- grid presses
    if in_grid and pitch then
        if Core_tk.MouseClicked(1) then
            local idx = Roll.At(t, pitch)
            if idx then
                local x1 = xAtTime(Roll.starts[idx] + Roll.lens[idx])
                Roll.sel = idx
                if mx > x1 - 6 then
                    state.mdrag = { mode = "resize", idx = idx, moved = false }
                else
                    state.mdrag = { mode = "move", idx = idx, moved = false,
                                    grab = t - Roll.starts[idx] }
                end
                auditionNote(pitch, Roll.vels[idx])
            else
                -- FL: click on empty = insert in the cell UNDER the cursor
                -- (floor-snap, not round — round pushed it a cell right).
                local t0 = midiSnapFloor(t)
                local len = gridStepSec(t0)
                if len <= 0.001 then len = 0.1 end
                Roll.Insert(t0, pitch, len, state.last_vel)
                auditionNote(pitch, state.last_vel)
                if Roll.sel then
                    state.mdrag = { mode = "move", idx = Roll.sel, moved = false,
                                    grab = t - t0 }
                end
            end
        elseif Core_tk.MouseClicked(2) then
            local idx = Roll.At(t, pitch)
            if idx then Roll.Delete(idx) end
            state.mdrag = { mode = "erase" }
        end
    end

    -- velocity lane press: grab the nearest note bar
    if in_vel and Core_tk.MouseClicked(1) and Roll.count > 0 then
        local best, best_d = nil, 6
        for i = 1, Roll.count do
            local d = math.abs(xAtTime(Roll.starts[i]) - mx)
            if d < best_d then best, best_d = i, d end
        end
        if best then
            Roll.sel = best
            state.mdrag = { mode = "vel", idx = best, moved = false }
        end
    end

    -- active drags
    local md = state.mdrag
    if md then
        if md.mode == "erase" then
            if Core_tk.MouseDown(2) then
                if in_grid and pitch then
                    local idx = Roll.At(t, pitch)
                    if idx then Roll.Delete(idx) end
                end
            else
                state.mdrag = nil
            end
        elseif Core_tk.MouseDown(1) then
            local free = Core_tk.ModCtrl()   -- Ctrl = bypass snap
            if md.mode == "move" and md.idx then
                local nt = t - (md.grab or 0)
                if not free then nt = midiSnap(nt) end
                if nt < 0 then nt = 0 end
                local np = pitch or Roll.pitches[md.idx]
                if nt ~= Roll.starts[md.idx] or np ~= Roll.pitches[md.idx] then
                    if np ~= Roll.pitches[md.idx] then auditionNote(np, Roll.vels[md.idx]) end
                    Roll.MoveLive(md.idx, nt, np)
                    md.moved = true
                end
                UI.SetCursor("size_all")
            elseif md.mode == "resize" and md.idx then
                local e = free and t or midiSnap(t)
                local min_len = gridStepSec(Roll.starts[md.idx]) * 0.25
                local len = e - Roll.starts[md.idx]
                if len < min_len then len = min_len end
                if math.abs(len - Roll.lens[md.idx]) > 0.0001 then
                    Roll.ResizeLive(md.idx, len)
                    md.moved = true
                end
                UI.SetCursor("size_we")
            elseif md.mode == "vel" and md.idx then
                local vel = (vy + VEL_H - my) / VEL_H * 127
                Roll.SetVelLive(md.idx, vel)
                state.last_vel = Roll.vels[md.idx]
                md.moved = true
            end
        else
            if md.moved then
                Roll.Commit(md.mode == "vel" and "MIDI: velocity"
                            or md.mode == "resize" and "MIDI: resize note"
                            or "MIDI: move note")
            end
            state.mdrag = nil
        end
    end

    -- hover cursor hint (resize zone)
    if in_grid and not state.mdrag and pitch then
        local idx = Roll.At(t, pitch)
        if idx and mx > xAtTime(Roll.starts[idx] + Roll.lens[idx]) - 6 then
            UI.SetCursor("size_we")
        end
    end
end

local function drawRoll(theme, area_h)
    local gx, gy = UI.GetCursorPos()
    local aw = UI.GetAvailableWidth()
    local rows = rollRows()
    local lane_w = rows.drum and 96 or 40
    local grid_h = area_h - RULER_H - VEL_H - 4
    if grid_h < 60 then grid_h = 60 end
    local row_h = grid_h / rows.n

    -- the shared view rect (timeAtX/xAtTime/zoomAt all reuse it)
    wave.x, wave.y = gx + lane_w, gy
    wave.w, wave.h = aw - lane_w, area_h
    wave.ry, wave.rh = gy + RULER_H, grid_h
    local vy = wave.ry + grid_h + 4

    local col_bg   = theme.colors.list_bg or theme.colors.window_bg
    local col_mute = theme.colors.text_mute or theme.colors.text_disabled
    local col_acc  = theme.colors.accent
    local col_text = theme.colors.text
    local col_sel  = theme.colors.list_selected or col_acc

    -- ruler strip (measure numbers on strong lines)
    Core_tk.DrawRect(gx, gy, aw, RULER_H,
                     col_bg[1] * 0.8, col_bg[2] * 0.8, col_bg[3] * 0.8, 1)

    -- grid background (buffered)
    renderRollGrid(theme, rows, wave.w, grid_h, row_h)
    gfx.dest = -1
    gfx.a, gfx.mode = 1, 0
    gfx.blit(MROLL_BUF, 1, 0, 0, 0, wave.w, grid_h, wave.x, wave.ry, wave.w, grid_h)

    -- measure labels in the ruler
    UI.SetFontCaption()
    do
        local pos = itemPos()
        local step = gridStepQN()
        local qn = math.floor(r.TimeMap2_timeToQN(0, pos + state.t0) / step) * step
        local guard = 0
        while guard < 512 do
            guard = guard + 1
            local t = r.TimeMap2_QNToTime(0, qn) - pos
            if t > state.t1 then break end
            if t >= state.t0 then
                local midx, mstart = r.TimeMap_QNToMeasures(0, qn + 0.0001)
                if math.abs(qn - (mstart or -1)) < 0.001 then
                    Core_tk.DrawText(tostring(midx), xAtTime(t) + 3, gy + 2,
                                     col_mute[1], col_mute[2], col_mute[3], 1)
                end
            end
            qn = qn + step
        end
    end

    -- labels lane
    Core_tk.DrawRect(gx, wave.ry, lane_w, grid_h,
                     col_bg[1] * 0.9, col_bg[2] * 0.9, col_bg[3] * 0.9, 1)
    if row_h >= 8 then
        for i = 1, rows.n do
            local p = rows.list[i]
            local y = wave.ry + (i - 1) * row_h
            local label
            if rows.drum then
                local pad = Kit.pads[p]
                label = (pad and pad.fx and Core_tk.TruncateText(pad.name, lane_w - 8))
                        or NOTE_NAMES[p]
            elseif p % 12 == 0 then
                label = NOTE_NAMES[p]
            end
            if label then
                Core_tk.DrawText(label, gx + 4, y + row_h * 0.5 - 6,
                                 col_mute[1], col_mute[2], col_mute[3], 1)
            end
        end
    end
    UI.SetFontBody()

    -- notes
    for i = 1, Roll.count do
        local rowi = rows.map[Roll.pitches[i]]
        if rowi then
            local t0n, t1n = Roll.starts[i], Roll.starts[i] + Roll.lens[i]
            if t1n > state.t0 and t0n < state.t1 then
                local x0 = xAtTime(math.max(t0n, state.t0))
                local x1 = xAtTime(math.min(t1n, state.t1))
                if x1 - x0 < 2 then x1 = x0 + 2 end
                local y = wave.ry + (rowi - 1) * row_h
                local alpha = 0.35 + (Roll.vels[i] / 127) * 0.55
                Core_tk.DrawRect(x0, y + 1, x1 - x0 - 1, row_h - 2,
                                 col_acc[1], col_acc[2], col_acc[3], alpha)
                if i == Roll.sel then
                    Core_tk.DrawRect(x0, y + 1, x1 - x0 - 1, row_h - 2,
                                     col_text[1], col_text[2], col_text[3], 1, false)
                end
            end
        end
    end

    -- velocity lane
    Core_tk.DrawRect(gx, vy, aw, VEL_H, col_bg[1], col_bg[2], col_bg[3], 1)
    for i = 1, Roll.count do
        local t0n = Roll.starts[i]
        if t0n >= state.t0 and t0n <= state.t1 then
            local x = xAtTime(t0n)
            local bh = (Roll.vels[i] / 127) * (VEL_H - 4)
            local sel = (i == Roll.sel)
            local c = sel and col_sel or col_acc
            Core_tk.DrawRect(x, vy + VEL_H - bh, 3, bh,
                             c[1], c[2], c[3], sel and 1 or 0.7)
        end
    end

    -- playback cursor (transport, in context)
    if r.GetPlayState() & 1 == 1 then
        local pp = r.GetPlayPosition() - itemPos()
        if pp >= state.t0 and pp <= state.t1 then
            local x = xAtTime(pp)
            Core_tk.DrawRect(x, wave.ry, 1, grid_h + 4 + VEL_H,
                             col_text[1], col_text[2], col_text[3], 0.8)
        end
        UI.RequestRedraw()
    end

    rollInput(theme, rows, row_h, lane_w, vy)
    UI.Layout.AdvanceCursor(aw, area_h)
end

-- ---------------------------------------------------------------------------
-- Keyboard
-- ---------------------------------------------------------------------------
local function handleKeys()
    if Core_tk.HasPopup() then return end
    local char = Core_tk.GetChar()
    if not char or char <= 0 then return end
    if Core_tk.GetState().focus then return end

    local midi = state.mode == "midi"

    if char == Keys.SPACE then
        togglePlay()
        UI.ConsumeChar()
    elseif char == Keys.HOME then
        fitView()
        UI.ConsumeChar()
    elseif char == Keys.ESCAPE and not midi and state.sel_a then
        state.sel_a, state.sel_b = nil, nil
        UI.ConsumeChar()
    elseif char == Keys.ESCAPE and midi and Roll.sel then
        Roll.sel = nil
        UI.ConsumeChar()
    elseif char == 43 then          -- '+'
        zoomAt(wave.x + wave.w / 2, 1 / 1.5)
        UI.ConsumeChar()
    elseif char == 45 then          -- '-'
        zoomAt(wave.x + wave.w / 2, 1.5)
        UI.ConsumeChar()
    elseif midi and char == Keys.DELETE and Roll.sel then
        Roll.Delete(Roll.sel)
        UI.ConsumeChar()
    elseif midi and (char == 113 or char == 81) then   -- q / Q
        local n = Roll.Quantize(midiSnap)
        flash(n .. " notes quantized")
        UI.ConsumeChar()
    elseif midi and Roll.sel and char == Keys.UP then
        local i = Roll.sel
        if Roll.pitches[i] < 127 then
            Roll.MoveLive(i, Roll.starts[i], Roll.pitches[i] + 1)
            Roll.Commit("MIDI: transpose")
            auditionNote(Roll.pitches[i], Roll.vels[i])
        end
        UI.ConsumeChar()
    elseif midi and Roll.sel and char == Keys.DOWN then
        local i = Roll.sel
        if Roll.pitches[i] > 0 then
            Roll.MoveLive(i, Roll.starts[i], Roll.pitches[i] - 1)
            Roll.Commit("MIDI: transpose")
            auditionNote(Roll.pitches[i], Roll.vels[i])
        end
        UI.ConsumeChar()
    elseif midi and Roll.sel and (char == Keys.LEFT or char == Keys.RIGHT) then
        local i = Roll.sel
        local step = gridStepSec(Roll.starts[i])
        local t = Roll.starts[i] + (char == Keys.RIGHT and step or -step)
        if t < 0 then t = 0 end
        Roll.MoveLive(i, midiSnap(t), Roll.pitches[i])
        Roll.Commit("MIDI: nudge")
        UI.ConsumeChar()
    end
end

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------
local function frame(theme)
    pollTarget()
    Kit.Poll()
    Audio.Poll()
    if Wave.Step() then UI.RequestRedraw() end
    handleKeys()

    -- deferred audition note-off (piano roll clicks through the kit bus)
    if state.aud_note and r.time_precise() >= state.aud_off_t then
        Kit.StuffNote(state.aud_note, false)
        state.aud_note = nil
    end

    UI.SetWindowPadding(theme.pad_large or 10)
    drawToolbar(theme)
    if state.mode == "midi" then
        drawMidiBar(theme)
    else
        drawOpsRow(theme)
        drawSliceRow(theme)
    end

    local pad = theme.pad_small or 4
    UI.Spacing(pad)
    local status_h = 18
    local area_h = UI.GetAvailableHeight() - status_h - pad
    if area_h < 80 then area_h = 80 end
    if state.mode == "midi" then
        drawRoll(theme, area_h)
    else
        drawWave(theme, area_h)
    end

    -- status line
    UI.SetFontCaption()
    if state.flash_msg ~= "" and r.time_precise() < state.flash_until then
        UI.Text(state.flash_msg, { disabled = true })
        UI.RequestRedraw()
    elseif state.mode == "midi" then
        if Roll.sel and Roll.pitches[Roll.sel] then
            UI.Text(string.format("note %s  ·  vel %d  ·  %.3fs",
                                  NOTE_NAMES[Roll.pitches[Roll.sel]],
                                  Roll.vels[Roll.sel], Roll.lens[Roll.sel]),
                    { disabled = true })
        else
            UI.Text("click = add note · drag = move · edge = resize · right-click = delete · Q = quantize",
                    { disabled = true })
        end
    elseif state.sel_a then
        UI.Text(string.format("sel  %.3f – %.3f  (%.3fs)",
                              state.sel_a, state.sel_b,
                              state.sel_b - state.sel_a), { disabled = true })
    else
        UI.Text("drag = select · wheel = zoom · middle-drag = pan · Space = play",
                { disabled = true })
    end
    UI.SetFontBody()

    if state.cfg_dirty and not Core_tk.MouseDown(1) then
        persistConfig()
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("Editor", 780, 420, {
    persist    = CONFIG_ID,
    scrollable = false,
})

UI.OnClose(function()
    -- Core keeps a SINGLE OnClose callback — everything belongs here.
    if state.aud_note then Kit.StuffNote(state.aud_note, false) end
    persistConfig()
    Audio.Destroy()
    Wave.Destroy()
    dropOwnSource()
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
