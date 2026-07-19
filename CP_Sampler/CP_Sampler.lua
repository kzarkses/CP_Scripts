-- @description Sampler (CP) — drum pad grid on hidden RS5K
-- @version 0.9
-- @author Cedric Pamalio
-- @about
--   Ableton Drum Rack-style 4x4 pad grid (4 pages, 64 pads) built on
--   CP_Toolkit. Each pad is a child track of a "CP Kit" folder hosting a
--   hidden ReaSamplOmatic5000 — RS5K is the engine, this window is the
--   interface. Pads get per-pad FX chains, sends and mixer strips for free;
--   the kit lives inside the project like any other tracks.
--
--   Drop samples from CP_MediaExplorer, Windows Explorer or the pad menu.
--   Click = trigger (through the armed kit bus, or direct preview), drag a
--   pad onto another = swap, right-click = pad menu (choke groups, editor,
--   RS5K escape hatch). Kit presets save paths + params to CP_Config/Kits.
--
--   Requires SWS (direct preview) — js_ReaScriptAPI recommended (cross-
--   window drops, file dialogs).

local r = reaper

-- ---------------------------------------------------------------------------
-- Toolkit + modules
-- ---------------------------------------------------------------------------
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local UI = dofile(r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua")

local Kit     = dofile(script_path .. "Modules/Kit.lua")
local Audio   = dofile(r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/Audio.lua")
local DragBus = dofile(r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/DragBus.lua")

-- Soft dependency: CP_Editor's peaks reader draws the region strip
-- (falls back to a plain range slider when the package is absent).
local okW, Wave = pcall(dofile,
    r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Editor/Modules/Wave.lua")
if not okW or type(Wave) ~= "table" then Wave = nil end

Kit.init(r)
Audio.init(r)
DragBus.init(r)
if Wave then Wave.init(r) end

local Core_tk = UI.Core
local Keys    = UI.Keys

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local CONFIG_ID = "CP_Sampler"
local BUS_ID    = "sampler"       -- DragBus target id
local cfg = UI.LoadConfig(CONFIG_ID) or {}

local opts = {
    velocity = cfg.velocity or 100,
    audition = cfg.audition or "auto",   -- "auto" | "midi" | "preview"
}
Audio.volume = cfg.vol or 1.0

local state = {
    page       = cfg.page or 0,   -- 0..3 (16 notes per page)
    sel        = Kit.BASE,        -- selected note
    hover      = nil,             -- pad under mouse this frame
    press      = nil,             -- {note, x, y} mouse-down on a pad
    press_midi = nil,             -- note-on sent, note-off due on release
    drag       = nil,             -- pad→pad drag {from, label}
    key_off_note = nil,           -- deferred note-off for keyboard triggers
    key_off_t  = 0,
    last_click_t = 0,             -- manual double-click detection
    last_click_note = nil,
    flash_msg  = "",
    flash_until = 0,
    cfg_dirty  = false,
    registered = false,           -- DragBus registration done
    meta_line  = nil,             -- cached selected-pad meta caption
    meta_key   = nil,
    glow       = {},              -- [note] = 0..1 smoothed output level
}
for n = Kit.BASE, Kit.BASE + Kit.MAX - 1 do state.glow[n] = 0 end

local function persistConfig()
    state.cfg_dirty = false
    cfg.page     = state.page
    cfg.velocity = opts.velocity
    cfg.audition = opts.audition
    cfg.vol      = Audio.volume
    UI.SaveConfig(CONFIG_ID, cfg)
end

local function markDirty() state.cfg_dirty = true end

local function flash(msg)
    state.flash_msg = msg
    state.flash_until = r.time_precise() + 2.5
    UI.RequestRedraw()
end

-- ---------------------------------------------------------------------------
-- Static tables (built once — the frame loop only indexes them)
-- ---------------------------------------------------------------------------
local NOTE_NAMES = {}
do
    local N = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
    for note = 0, 127 do
        NOTE_NAMES[note] = N[note % 12 + 1] .. tostring(math.floor(note / 12) - 1)
    end
end
local CHOKE_STR   = { "1", "2", "3", "4", "5", "6", "7", "8" }
local CHOKE_ITEMS = { "Off", "1", "2", "3", "4", "5", "6", "7", "8" }
local PAGE_IDS    = { "pg1", "pg2", "pg3", "pg4" }
local PAGE_LBL    = { "1", "2", "3", "4" }
local MODE_TABS   = { { key = "drum", id = "mode_drum", label = "Drum" },
                      { key = "instrument", id = "mode_instr", label = "Instr" } }
local ICONBTN_OPTS = { width = 0, height = 0 }
local KNOB_OPTS   = { size = 34 }
local COMBO_OPTS  = { width = 58 }
local ROOT_OPTS   = { step = 1, format = "%.0f", width = 50 }
local PLAY_OPTS   = {}            -- pooled Audio.Play opts
local GRID_GAP    = 6
local CTRL_H      = 176           -- control strip reserve (grid gets the rest)
local DRAG_PX     = 8             -- pad drag promotion threshold

-- ---------------------------------------------------------------------------
-- Pad helpers
-- ---------------------------------------------------------------------------
local grid = { x = 0, y = 0, cw = 0, ch = 0 }   -- geometry of the last drawn grid

local function pageBase()
    return Kit.BASE + state.page * 16
end

-- note at a window-client point, or nil (gaps count as miss)
local function padAt(mx, my)
    local cw, chh = grid.cw, grid.ch
    if cw <= 0 or chh <= 0 then return nil end
    local rel_x, rel_y = mx - grid.x, my - grid.y
    if rel_x < 0 or rel_y < 0 then return nil end
    local col = math.floor(rel_x / (cw + GRID_GAP))
    local row = math.floor(rel_y / (chh + GRID_GAP))
    if col > 3 or row > 3 then return nil end
    if rel_x - col * (cw + GRID_GAP) >= cw then return nil end
    if rel_y - row * (chh + GRID_GAP) >= chh then return nil end
    return pageBase() + (3 - row) * 4 + col
end

local function firstEmpty()
    for n = pageBase(), pageBase() + 15 do
        local pad = Kit.pads[n]
        if not (pad and pad.fx) then return n end
    end
    for n = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
        local pad = Kit.pads[n]
        if not (pad and pad.fx) then return n end
    end
    return nil
end

-- Publish "open this file in CP_Editor" (picked up if it runs).
local function editorOpen(path)
    if not path then return end
    r.SetExtState("CP_Editor", "open",
                  string.format("%.3f\n%s", r.time_precise(), path), false)
end

-- ---------------------------------------------------------------------------
-- Audition (press = sound, FL/MPC style — pads are an instrument)
-- ---------------------------------------------------------------------------
local function padOn(note)
    local pad = Kit.pads[note]
    if not pad or not pad.fx then return end
    local use_midi = opts.audition == "midi"
        or (opts.audition == "auto" and Kit.Armed())
        or not pad.path             -- no readable file → only MIDI can play it
    if use_midi then
        Kit.StuffNote(note, true, opts.velocity)
        state.press_midi = note
    else
        local len = Audio.Meta(pad.path)
        PLAY_OPTS.start_s, PLAY_OPTS.end_s = nil, nil
        if len then
            local s = Kit.Param(note, Kit.P.SOFFS) or 0
            local e = Kit.Param(note, Kit.P.EOFFS) or 1
            if s > 0 then PLAY_OPTS.start_s = s * len end
            if e < 1 then PLAY_OPTS.end_s = e * len end
        end
        Audio.Play(pad.path, PLAY_OPTS)
    end
end

local function padOff()
    if state.press_midi then
        Kit.StuffNote(state.press_midi, false)
        state.press_midi = nil
    end
    -- direct previews ring out (one-shot feel) — no stop here
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------
local function loadInto(note, path)
    if Kit.LoadSample(note, path) then
        state.sel = note
        flash("Loaded: " .. (Kit.pads[note] and Kit.pads[note].name or path))
        return true
    end
    flash("Load failed")
    return false
end

-- Multi-file load: target pad, then next empty pads.
local function loadMany(note, paths)
    local n = note
    for i = 1, #paths do
        if not n then break end
        local pad = Kit.pads[n]
        if i > 1 and pad and pad.fx then
            n = firstEmpty()
            if not n then break end
        end
        loadInto(n, paths[i])
        n = n + 1
        if n >= Kit.BASE + Kit.MAX then n = firstEmpty() end
    end
end

local function browseInto(note)
    if r.JS_Dialog_BrowseForOpenFiles then
        local ok, files = r.JS_Dialog_BrowseForOpenFiles("Load sample", "", "",
            "Audio files\0*.wav;*.aif;*.aiff;*.flac;*.mp3;*.ogg;*.wv;*.opus;*.rex\0All files\0*.*\0\0",
            true)
        if ok and ok > 0 and files and files ~= "" then
            -- Multi returns "dir\0file1\0file2…", single returns "path"
            local parts = {}
            for token in files:gmatch("[^\0]+") do parts[#parts + 1] = token end
            if #parts == 1 then
                loadMany(note, parts)
            elseif #parts > 1 then
                local dir = parts[1]
                local paths = {}
                for i = 2, #parts do paths[#paths + 1] = dir .. "/" .. parts[i] end
                loadMany(note, paths)
            end
        end
    else
        local ok, path = r.GetUserFileNameForRead("", "Load sample", "")
        if ok and path and path ~= "" then loadInto(note, path) end
    end
end

-- ---------------------------------------------------------------------------
-- OS file drops (Explorer → pads)
-- ---------------------------------------------------------------------------
local drop_paths = {}   -- reused scratch
local function handleFileDrops()
    local ok = gfx.getdropfile(0)
    if ok == 0 then return end
    for i = #drop_paths, 1, -1 do drop_paths[i] = nil end
    local i = 0
    while true do
        local got, path = gfx.getdropfile(i)
        if got == 0 or not path or path == "" then break end
        if r.file_exists(path) then drop_paths[#drop_paths + 1] = path end
        i = i + 1
    end
    gfx.getdropfile(-1)
    if #drop_paths == 0 then return end
    if Kit.mode == "instrument" then
        if Kit.LoadInstrument(drop_paths[1]) then
            flash("Instrument: " .. (Kit.instr and Kit.instr.name or ""))
        end
        return
    end
    local note = padAt(gfx.mouse_x, gfx.mouse_y) or firstEmpty() or state.sel
    loadMany(note, drop_paths)
end

-- ---------------------------------------------------------------------------
-- DragBus (drops from CP_MediaExplorer / other CP windows)
-- ---------------------------------------------------------------------------
local function busConsume()
    if not state.registered then
        state.registered = DragBus.Register(BUS_ID)
    end
    DragBus.RectSync(BUS_ID)   -- publish our screen rect (write-on-change)
    local kind, path, sx, sy = DragBus.TakeDrop(BUS_ID)
    if (kind == "file" or kind == "instrument") and path and path ~= "" then
        -- an explicit "instrument" drop (editor "Send to instrument") or a
        -- plain file dropped while in instrument mode loads the instrument
        if kind == "instrument" or Kit.mode == "instrument" then
            if kind == "instrument" and Kit.mode ~= "instrument" then
                Kit.SetMode("instrument")
            end
            if Kit.LoadInstrument(path) then
                flash("Instrument: " .. (Kit.instr and Kit.instr.name or ""))
            end
        else
            local cx, cy = Core_tk.ScreenToClient(sx, sy)
            local note = padAt(cx, cy) or firstEmpty() or state.sel
            loadInto(note, path)
        end
    end
end

-- "Send to instrument" from CP_Editor: an ExtState message (path + optional
-- selection offsets) — switches to instrument mode and loads the sample.
local last_instr_msg = ""
local function instrumentPoll()
    local v = r.GetExtState("CP_Sampler", "instrument")
    if v == "" or v == last_instr_msg then return end
    last_instr_msg = v
    local ts, path, s, e = v:match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n(.*)$")
    ts = tonumber(ts)
    if not ts or not path or path == "" or r.time_precise() - ts >= 5.0 then return end
    Kit.SetMode("instrument")
    if Kit.LoadInstrument(path) then
        local ss, ee = tonumber(s), tonumber(e)
        if ss and ee and (ss > 0 or ee < 1) then
            Kit.SetInstrParam(Kit.P.SOFFS, ss)
            Kit.SetInstrParam(Kit.P.EOFFS, ee)
        end
        flash("Instrument: " .. (Kit.instr and Kit.instr.name or ""))
    end
end

-- Highlight target pad while another CP window drags over us. Our window
-- doesn't get mouse events during a foreign drag (the source window holds
-- capture) — track the OS cursor instead, and keep redrawing.
local function busHover()
    local kind = DragBus.ActiveDrag()
    if kind ~= "file" then return nil end
    local sx, sy = r.GetMousePosition()
    local cx, cy = Core_tk.ScreenToClient(sx, sy)
    if cx < 0 or cy < 0 or cx >= gfx.w or cy >= gfx.h then return nil end
    UI.RequestRedraw()
    return padAt(cx, cy)
end

-- ---------------------------------------------------------------------------
-- Pad context menu
-- ---------------------------------------------------------------------------
local function chokeMenuItems(note)
    local cur = Kit.Choke(note)
    local items = { { label = "Off", checked = cur == 0,
                      action = function() Kit.SetChoke(note, 0) end } }
    for g = 1, 8 do
        items[#items + 1] = { label = CHOKE_STR[g], checked = cur == g,
                              action = function() Kit.SetChoke(note, g) end }
    end
    return items
end

local function openPadMenu(note)
    local pad = Kit.pads[note]
    local has = pad and pad.path
    local items = {
        { label = "Load sample...", action = function() browseInto(note) end },
    }
    if has then
        items[#items + 1] = { label = "Open in Editor",
                              action = function() editorOpen(pad.path) end }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { label = "Choke group", children = chokeMenuItems(note) }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { label = "Rename pad...", action = function()
            local ok, name = r.GetUserInputs("Rename pad", 1,
                                             "Name:,extrawidth=160", pad.name)
            if ok and name ~= "" then
                pad.name = name
                r.GetSetMediaTrackInfo_String(pad.track, "P_NAME", name, true)
                Kit.version = Kit.version + 1
            end
        end }
        items[#items + 1] = { label = "Show RS5K UI", action = function()
            Kit.FloatRS5K(note)
        end }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { label = "Clear pad (keep track FX)", action = function()
            Kit.ClearPad(note)
        end }
    end
    if pad then
        items[#items + 1] = { label = "Delete pad track", action = function()
            Kit.DeletePad(note)
        end }
    end
    UI.NativeMenu(items)
end

-- ---------------------------------------------------------------------------
-- Kit preset menus
-- ---------------------------------------------------------------------------
local function savePresetDialog()
    if not Kit.Exists() then flash("No kit to save") return end
    local ok, name = r.GetUserInputs("Save kit preset", 1,
                                     "Kit name:,extrawidth=160", "")
    if not ok or name == "" then return end
    name = name:gsub("[\\/:*?\"<>|]", "_")
    if Kit.SavePreset(Kit.PresetDir() .. "/" .. name .. ".lua") then
        flash("Kit saved: " .. name)
    else
        flash("Save failed")
    end
end

local function loadPresetMenu()
    local dir = Kit.PresetDir()
    local items = {}
    local i = 0
    while true do
        local fn = r.EnumerateFiles(dir, i)
        if not fn then break end
        local name = fn:match("^(.*)%.lua$")
        if name then
            local full = dir .. "/" .. fn
            items[#items + 1] = { label = name, action = function()
                if Kit.LoadPreset(full) then
                    flash("Kit loaded: " .. name)
                else
                    flash("Load failed: " .. name)
                end
            end }
        end
        i = i + 1
    end
    if #items == 0 then
        items[1] = { label = "(no saved kits)", disabled = true }
    end
    UI.NativeMenu(items)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local function auditionItem(label, mode)
    return { label = label, checked = opts.audition == mode,
             action = function() opts.audition = mode markDirty() end }
end

local function velocityItem(v)
    return { label = tostring(v), checked = opts.velocity == v,
             action = function() opts.velocity = v markDirty() end }
end

local function openSettings()
    UI.NativeMenu({
        { label = "Pad click audition", children = {
            auditionItem("Auto (through kit bus when armed)", "auto"),
            auditionItem("Always MIDI through kit bus", "midi"),
            auditionItem("Always direct preview", "preview"),
        } },
        { label = "Pad velocity", children = {
            velocityItem(64), velocityItem(80), velocityItem(100),
            velocityItem(112), velocityItem(127),
        } },
        { separator = true },
        { label = "Kit bus armed (MIDI input + pad clicks sound)",
          checked = Kit.Armed(),
          action = function() Kit.SetArmed(not Kit.Armed()) end },
        { label = "Create kit bus now", disabled = Kit.Exists(),
          action = function() Kit.Ensure() flash("Kit bus created") end },
        { separator = true },
        { label = "Rescan kit now", action = function()
            Kit.Scan()
            local pads, loaded = Kit.Count()
            flash(string.format("Kit: %d pad tracks, %d loaded", pads, loaded))
        end },
        { label = "Adopt selected track as kit bus (mpl/hand-built kits)",
          action = function()
            local tr = r.GetSelectedTrack(0, 0)
            if tr and Kit.Adopt(tr) then
                local pads, loaded = Kit.Count()
                flash(string.format("Adopted: %d pad tracks, %d loaded", pads, loaded))
            else
                flash("Select the kit folder track first")
            end
        end },
    })
end

-- ---------------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------------
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

local function drawToolbar(theme)
    local btn = theme.button_height

    if not Kit.Exists() then
        if UI.Button("mk_kit", "Create kit bus") then
            Kit.Ensure()
            flash("Kit bus created — drop samples on the pads")
        end
    else
        -- Armed toggle (Record icon, red when live)
        local armed = Kit.Armed()
        local cx, cy = UI.GetCursorPos()
        ICONBTN_OPTS.width, ICONBTN_OPTS.height = btn, btn
        if UI.Button("arm", "", ICONBTN_OPTS) then
            Kit.SetArmed(not armed)
        end
        local c = armed and (theme.colors.danger or theme.colors.accent)
                         or theme.colors.text_disabled
        UI.Icons.Record(cx, cy, btn, c[1], c[2], c[3], c[4] or 1)
        if Core_tk.MouseInRect(cx, cy, btn, btn) then
            UI.Tooltip(armed and "Kit bus armed: MIDI input and pad clicks play through the pads"
                              or "Kit bus disarmed: pad clicks fall back to direct preview")
        end
    end

    -- Mode toggle: Drum (4x4 pads) vs Instrument (chromatic, one sample)
    if Kit.Exists() then
        UI.SameLine(12)
        local acc = theme.colors.accent
        for _, m in ipairs(MODE_TABS) do
            UI.SameLine()
            local on = Kit.mode == m.key
            if on then UI.PushStyleColor("button", acc[1], acc[2], acc[3]) end
            if UI.Button(m.id, m.label) then
                if not on then Kit.SetMode(m.key) end
            end
            if on then UI.PopStyleColor() end
        end
    end

    -- Pages (drum mode only)
    if Kit.mode == "drum" then
        for p = 1, 4 do
            UI.SameLine()
            if p == state.page + 1 then UI.PushStyleColor("button",
                theme.colors.accent[1], theme.colors.accent[2], theme.colors.accent[3]) end
            ICONBTN_OPTS.width, ICONBTN_OPTS.height = btn, btn
            if UI.Button(PAGE_IDS[p], PAGE_LBL[p], ICONBTN_OPTS) then
                state.page = p - 1
                markDirty()
            end
            if p == state.page + 1 then UI.PopStyleColor() end
        end
    end

    -- Right group: save / load / settings
    local right_w = btn * 3 + theme.item_spacing * 2
    local gap = UI.GetAvailableWidth() - right_w
    if gap > 0 then UI.SameLine(gap) else UI.SameLine() end
    if iconBtn("save_kit", UI.Icons.Save, "Save kit preset") then
        savePresetDialog()
    end
    UI.SameLine()
    if iconBtn("load_kit", UI.Icons.Folder, "Load kit preset") then
        loadPresetMenu()
    end
    UI.SameLine()
    if iconBtn("settings", UI.Icons.Settings, "Settings") then
        openSettings()
    end
    UI.Spacing(0)
end

-- ---------------------------------------------------------------------------
-- Pad grid
-- ---------------------------------------------------------------------------
local function handleGridPress(note)
    state.sel = note
    local pad = Kit.pads[note]
    local now = r.time_precise()
    local dbl = state.last_click_note == note and (now - state.last_click_t) < 0.35
    state.last_click_t, state.last_click_note = now, note

    -- Double-click only means something on an EMPTY pad (browse). On a
    -- loaded pad rapid clicks are DRUMMING — a double-click action would
    -- eat every second hit (the editor lives in the right-click menu).
    if dbl and not (pad and pad.fx) then
        browseInto(note)
        return
    end
    local mx, my = Core_tk.GetMousePos()
    state.press = { note = note, x = mx, y = my }
    padOn(note)
end

local function drawGrid(theme, grid_h)
    local gx, gy = UI.GetCursorPos()
    local aw = UI.GetAvailableWidth()
    -- Rectangular cells fill the whole area (Drum Rack style) — width and
    -- height are independent, so no window shape leaves dead space.
    local cw  = math.floor((aw - 3 * GRID_GAP) / 4)
    local chh = math.floor((grid_h - 3 * GRID_GAP) / 4)
    if cw < 40 then cw = 40 end
    if chh < 30 then chh = 30 end
    grid.x = gx + math.floor((aw - (cw * 4 + GRID_GAP * 3)) / 2)
    if grid.x < gx then grid.x = gx end
    grid.y = gy
    grid.cw, grid.ch = cw, chh

    local base = pageBase()
    local mx, my = Core_tk.GetMousePos()
    local popup = Core_tk.HasPopup()
    state.hover = (not popup) and padAt(mx, my) or nil
    local bus_target = busHover()

    local col_bg    = theme.colors.frame_bg
    local col_empty = theme.colors.list_bg or theme.colors.window_bg
    local col_hov   = theme.colors.frame_hovered
    local col_acc   = theme.colors.accent
    local col_text  = theme.colors.text
    local col_mute  = theme.colors.text_mute or theme.colors.text_disabled
    local col_bord  = theme.colors.border

    UI.SetFontCaption()
    local glow_live = false

    for row = 0, 3 do
        for col = 0, 3 do
            local note = base + (3 - row) * 4 + col
            local x = grid.x + col * (cw + GRID_GAP)
            local y = grid.y + row * (chh + GRID_GAP)
            local pad = Kit.pads[note]
            local has = pad and pad.fx   -- an RS5K makes a pad live, path or not

            -- output glow (event: only pads with samples poll their track)
            local g = state.glow[note]
            if has then
                local peak = Kit.PadPeak(note)
                local target = peak * 2
                if target > 1 then target = 1 end
                g = g * 0.85
                if target > g then g = target end
                state.glow[note] = g
                if g > 0.02 then glow_live = true end
            elseif g > 0 then
                state.glow[note] = 0
            end

            local bg = has and col_bg or col_empty
            if state.hover == note and not state.drag then bg = col_hov end
            Core_tk.DrawRect(x, y, cw, chh, bg[1], bg[2], bg[3], bg[4] or 1)
            if g > 0.02 then
                Core_tk.DrawRect(x, y, cw, chh,
                                 col_acc[1], col_acc[2], col_acc[3], g * 0.4)
            end

            -- borders: selection (accent, 2px), bus-drag target, default
            if note == state.sel then
                Core_tk.DrawRect(x, y, cw, chh,
                                 col_acc[1], col_acc[2], col_acc[3], 1, false)
                Core_tk.DrawRect(x + 1, y + 1, cw - 2, chh - 2,
                                 col_acc[1], col_acc[2], col_acc[3], 1, false)
            elseif bus_target == note
                   or (state.drag and state.hover == note) then
                Core_tk.DrawRect(x, y, cw, chh,
                                 col_acc[1], col_acc[2], col_acc[3], 0.9, false)
            else
                Core_tk.DrawRect(x, y, cw, chh,
                                 col_bord[1], col_bord[2], col_bord[3],
                                 (col_bord[4] or 1) * 0.6, false)
            end

            if has then
                local label = Core_tk.TruncateText(pad.name, cw - 8)
                local tw = Core_tk.MeasureText(label)
                Core_tk.DrawText(label, x + math.floor((cw - tw) / 2),
                                 y + math.floor(chh / 2) - 7,
                                 col_text[1], col_text[2], col_text[3], col_text[4] or 1)
            elseif state.hover == note then
                local tw = Core_tk.MeasureText("+")
                Core_tk.DrawText("+", x + math.floor((cw - tw) / 2),
                                 y + math.floor(chh / 2) - 7,
                                 col_mute[1], col_mute[2], col_mute[3], col_mute[4] or 1)
            end

            -- note name, bottom-left
            Core_tk.DrawText(NOTE_NAMES[note], x + 4, y + chh - 16,
                             col_mute[1], col_mute[2], col_mute[3],
                             (col_mute[4] or 1) * 0.9)
            -- choke badge, top-right
            local grp = has and Kit.Choke(note) or 0
            if grp > 0 then
                local s = CHOKE_STR[grp]
                local tw = Core_tk.MeasureText(s)
                Core_tk.DrawText(s, x + cw - tw - 4, y + 3,
                                 col_acc[1], col_acc[2], col_acc[3], 1)
            end
        end
    end
    UI.SetFontBody()
    if glow_live then UI.RequestRedraw() end

    -- interactions (raw region — the toolkit owns nothing here)
    if not popup then
        if state.hover and Core_tk.MouseClicked(1) then
            handleGridPress(state.hover)
        end
        if state.hover and Core_tk.MouseClicked(2) then
            state.sel = state.hover
            openPadMenu(state.hover)
        end
    end

    UI.Layout.AdvanceCursor(aw, math.min(grid_h, chh * 4 + GRID_GAP * 3))
end

-- ---------------------------------------------------------------------------
-- Pad → pad drag (swap slots; cross-window via DragBus)
-- ---------------------------------------------------------------------------
local function handlePadDrag()
    if state.press and not state.drag then
        if Core_tk.MouseDown(1) then
            local mx, my = Core_tk.GetMousePos()
            local dx, dy = mx - state.press.x, my - state.press.y
            if dx * dx + dy * dy > DRAG_PX * DRAG_PX then
                local pad = Kit.pads[state.press.note]
                if pad and pad.path then
                    state.drag = { from = state.press.note,
                                   label = "+ " .. pad.name, path = pad.path }
                    DragBus.Begin("file", pad.path, state.drag.label, BUS_ID)
                end
                state.press = nil
            end
        else
            state.press = nil
            padOff()
        end
    end

    if not state.drag then
        if state.press_midi and not Core_tk.MouseDown(1) then padOff() end
        return
    end

    local sx, sy = r.GetMousePosition()
    r.TrackCtl_SetToolTip(state.drag.label, sx + 16, sy + 12, true)
    UI.SetCursor("hand")

    if Core_tk.MouseReleased(1) then
        r.TrackCtl_SetToolTip("", 0, 0, true)
        padOff()
        local target = state.hover
        local from = state.drag.from
        state.drag = nil
        local cx, cy = Core_tk.ScreenToClient(sx, sy)
        local inside = cx >= 0 and cy >= 0 and cx < gfx.w and cy < gfx.h
        if inside then
            DragBus.End()
            if target and target ~= from then
                Kit.SwapPads(from, target)
                state.sel = target
                flash("Pads swapped")
            end
        else
            -- released over another window: maybe a CP target (editor…)
            DragBus.Drop(sx, sy)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Selected pad controls
-- ---------------------------------------------------------------------------
local function metaLine(pad)
    -- keyed on (path, kit version) without building a key string per frame
    if state.meta_key == pad.path and state.meta_ver == Kit.version then
        return state.meta_line
    end
    local len, ch, sr = Audio.Meta(pad.path)
    if len then
        state.meta_line = string.format("%s  ·  %.2fs  ·  %dch  ·  %.1fk",
                                        NOTE_NAMES[pad.note], len, ch, sr / 1000)
    else
        state.meta_line = NOTE_NAMES[pad.note]
    end
    state.meta_key = pad.path
    state.meta_ver = Kit.version
    return state.meta_line
end

-- ---------------------------------------------------------------------------
-- Region strip: the selected pad's waveform with the RS5K start/end
-- offsets as a draggable region (edges resize, middle translates).
-- Waveform renders into an offscreen buffer only when the file or the
-- width changes; a steady frame is one blit + overlay rects.
-- ---------------------------------------------------------------------------
local STRIP_H  = 44
local WAVE_BUF = 905
local strip = { path = nil, w = 0, h = 0 }   -- buffer content key

local function drawRegionStrip(theme, note, pad)
    local x, y = UI.GetCursorPos()
    local aw = UI.GetAvailableWidth()
    local h = STRIP_H
    local col_bg   = theme.colors.list_bg or theme.colors.window_bg
    local col_acc  = theme.colors.accent
    local col_bord = theme.colors.border

    local len = Audio.Meta(pad.path)
    local entry = nil
    if Wave and len and len > 0 then
        local src = Audio.GetSource(pad.path)
        if src then
            entry = Wave.Read(src, pad.path, 0, len, aw, 0)
        end
    end

    if entry and (strip.path ~= pad.path or strip.w ~= aw or strip.h ~= h) then
        strip.path, strip.w, strip.h = pad.path, aw, h
        gfx.dest = WAVE_BUF
        gfx.setimgdim(WAVE_BUF, aw, h)
        gfx.muladdrect(0, 0, aw, h, 0, 0, 0, 0)  -- undefined after resize
        gfx.set(col_bg[1], col_bg[2], col_bg[3], 1)
        gfx.rect(0, 0, aw, h, 1)
        gfx.set(col_acc[1], col_acc[2], col_acc[3], 0.8)
        local mid, scale = h * 0.5, h * 0.47
        local n, ch = entry.n, entry.ch
        for px = 1, n do
            local vmax, vmin = -1, 1
            for c = 1, ch do
                local v = entry.maxs[c][px] or 0
                if v > vmax then vmax = v end
                v = entry.mins[c][px] or 0
                if v < vmin then vmin = v end
            end
            local y1 = mid - vmax * scale
            local y2 = mid - vmin * scale
            if y2 - y1 < 1 then y2 = y1 + 1 end
            gfx.line(px - 1, y1, px - 1, y2)
        end
        gfx.dest = -1
    end

    if strip.path == pad.path and strip.w == aw then
        gfx.dest = -1
        gfx.a, gfx.mode = 1, 0
        gfx.blit(WAVE_BUF, 1, 0, 0, 0, aw, h, x, y, aw, h)
    else
        Core_tk.DrawRect(x, y, aw, h, col_bg[1], col_bg[2], col_bg[3], 1)
        UI.RequestRedraw()   -- peaks still building
    end

    -- region overlay (dim outside, accent edges + top handles)
    local s = Kit.Param(note, Kit.P.SOFFS) or 0
    local e = Kit.Param(note, Kit.P.EOFFS) or 1
    local xs = x + s * aw
    local xe = x + e * aw
    if xs > x then Core_tk.DrawRect(x, y, xs - x, h, 0, 0, 0, 0.55) end
    if xe < x + aw then Core_tk.DrawRect(xe, y, x + aw - xe, h, 0, 0, 0, 0.55) end
    Core_tk.DrawRect(xs, y, 1, h, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(xe - 1, y, 1, h, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(xs, y, 5, 8, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(xe - 5, y, 5, 8, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(x, y, aw, h,
                     col_bord[1], col_bord[2], col_bord[3],
                     (col_bord[4] or 1) * 0.6, false)

    -- interaction (RangeSlider grammar on the waveform)
    local mx, my = Core_tk.GetMousePos()
    local inside = mx >= x and mx < x + aw and my >= y and my < y + h
    if not Core_tk.HasPopup() then
        if inside and Core_tk.MouseClicked(1) then
            if math.abs(mx - xs) <= 6 then
                state.rdrag = { mode = "s", note = note }
            elseif math.abs(mx - xe) <= 6 then
                state.rdrag = { mode = "e", note = note }
            elseif mx > xs and mx < xe then
                state.rdrag = { mode = "m", note = note, grab = (mx - x) / aw - s }
            else
                state.rdrag = { mode = (mx < xs) and "s" or "e", note = note }
            end
        end
        -- a drag stays bound to ITS pad (keyboard can move the selection
        -- mid-drag — the strip then shows another pad's region)
        if state.rdrag and state.rdrag.note ~= note then
            state.rdrag = nil
        end
        if state.rdrag then
            if Core_tk.MouseDown(1) then
                local frac = (mx - x) / aw
                if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
                local MINW = 0.004
                if state.rdrag.mode == "s" then
                    Kit.SetOffsets(note, math.min(frac, e - MINW), e)
                elseif state.rdrag.mode == "e" then
                    Kit.SetOffsets(note, s, math.max(frac, s + MINW))
                else
                    local w = e - s
                    local ns = frac - state.rdrag.grab
                    if ns < 0 then ns = 0 end
                    if ns + w > 1 then ns = 1 - w end
                    Kit.SetOffsets(note, ns, ns + w)
                end
                UI.SetCursor(state.rdrag.mode == "m" and "size_all" or "size_we")
            else
                state.rdrag = nil
            end
        elseif inside then
            UI.SetCursor((math.abs(mx - xs) <= 6 or math.abs(mx - xe) <= 6)
                         and "size_we" or "arrow")
        end
    end

    UI.Layout.AdvanceCursor(aw, h)
end

local function knob(id, label, note, pid, default)
    local v = Kit.Param(note, pid)
    if not v then return end
    local changed, nv = UI.Knob(id, label, v, default or v, KNOB_OPTS)
    if changed then Kit.SetParam(note, pid, nv) end
    if UI.IsItemHovered() then UI.Tooltip(Kit.ParamFmt(note, pid)) end
    UI.SameLine()
end

local function drawControls(theme)
    local note = state.sel
    local pad = note and Kit.pads[note]
    if not pad then
        UI.SetFontCaption()
        UI.Text(Kit.Exists() and "Select a pad — drop samples from the Media Explorer or Windows"
                              or "Create the kit bus, then drop samples on the pads",
                { disabled = true })
        UI.SetFontBody()
        return
    end
    if not pad.fx then
        UI.SetFontH2()
        UI.Text("Pad " .. NOTE_NAMES[note])
        UI.SetFontCaption()
        UI.Text("Empty — drop a sample, or double-click to browse", { disabled = true })
        UI.SetFontBody()
        return
    end

    UI.SetFontH2()
    UI.Text(pad.name)
    UI.SetFontCaption()
    UI.SameLine(10)
    UI.Text(pad.path and metaLine(pad) or NOTE_NAMES[note], { disabled = true })
    UI.SetFontBody()

    knob("k_vol", "Vol", note, Kit.P.VOL, Kit.DEFAULT_VOL)
    knob("k_pan", "Pan", note, Kit.P.PAN, 0.5)
    knob("k_tune", "Tune", note, Kit.P.TUNE, 0.5)
    knob("k_att", "A", note, Kit.P.ATTACK, Kit.DEFAULT_ATT)
    knob("k_dec", "D", note, Kit.P.DECAY, Kit.DEFAULT_DEC)
    knob("k_sus", "S", note, Kit.P.SUSTAIN, Kit.DEFAULT_SUS)
    knob("k_rel", "R", note, Kit.P.RELEASE, Kit.DEFAULT_REL)

    -- choke + loop, stacked next to the knobs
    local grp = Kit.Choke(note)
    local changed, idx = UI.Combo("k_choke", "Choke", grp + 1, CHOKE_ITEMS, COMBO_OPTS)
    if changed then Kit.SetChoke(note, idx - 1) end
    UI.SameLine()
    local lv = Kit.Param(note, Kit.P.LOOP) or 0
    local ltog, lon = UI.Checkbox("k_loop", "Loop", lv >= 0.5)
    if ltog then Kit.SetParam(note, Kit.P.LOOP, lon and 1 or 0) end

    -- sample region (RS5K start/end offsets) — waveform strip when the
    -- peaks reader is available, plain range slider otherwise
    UI.Spacing(2)
    if Wave and pad.path then
        drawRegionStrip(theme, note, pad)
    else
        local s = Kit.Param(note, Kit.P.SOFFS) or 0
        local e = Kit.Param(note, Kit.P.EOFFS) or 1
        local rchanged, ns, ne = UI.RangeSlider("k_region", "Region", s, e, 0, 1)
        if rchanged then Kit.SetOffsets(note, ns, ne) end
    end
end

-- ---------------------------------------------------------------------------
-- Instrument (chromatic) view: one sample across the keyboard
-- ---------------------------------------------------------------------------
local INST_BUF   = 907
local WHITE_STEP = { [0]=true,[2]=true,[4]=true,[5]=true,[7]=true,[9]=true,[11]=true }
local istrip = { path = nil, w = 0, h = 0 }
local KB_LO, KB_HI = 36, 84   -- C2..C6 mini keyboard range

local function iknob(id, label, pid, default)
    local v = Kit.InstrParam(pid)
    if not v then return end
    local changed, nv = UI.Knob(id, label, v, default or v, KNOB_OPTS)
    if changed then Kit.SetInstrParam(pid, nv) end
    if UI.IsItemHovered() then UI.Tooltip(Kit.InstrParamFmt(pid)) end
    UI.SameLine()
end

local function instrNoteOn(note)
    local instr = Kit.instr
    if not instr or not instr.path then return end
    local use_midi = opts.audition == "midi"
        or (opts.audition == "auto" and Kit.Armed())
    if use_midi then
        Kit.StuffNote(note, true, opts.velocity)
        state.press_midi = note
    else
        PLAY_OPTS.start_s, PLAY_OPTS.end_s = nil, nil
        PLAY_OPTS.pitch = note - instr.root
        Audio.Play(instr.path, PLAY_OPTS)
        PLAY_OPTS.pitch = nil
    end
end

-- Waveform + draggable region over the instrument sample.
local function instrWave(theme, x, y, w, h)
    local instr = Kit.instr
    local col_bg   = theme.colors.list_bg or theme.colors.window_bg
    local col_acc  = theme.colors.accent
    local col_bord = theme.colors.border
    local len = instr.path and Audio.Meta(instr.path) or nil
    local entry = nil
    if Wave and len and len > 0 then
        local src = Audio.GetSource(instr.path)
        if src then entry = Wave.Read(src, instr.path, 0, len, w, 0) end
    end
    if entry and (istrip.path ~= instr.path or istrip.w ~= w or istrip.h ~= h) then
        istrip.path, istrip.w, istrip.h = instr.path, w, h
        gfx.dest = INST_BUF
        gfx.setimgdim(INST_BUF, w, h)
        gfx.muladdrect(0, 0, w, h, 0, 0, 0, 0)
        gfx.set(col_bg[1], col_bg[2], col_bg[3], 1)
        gfx.rect(0, 0, w, h, 1)
        gfx.set(col_acc[1], col_acc[2], col_acc[3], 0.8)
        local mid, scale = h * 0.5, h * 0.46
        for px = 1, entry.n do
            local vmax, vmin = -1, 1
            for c = 1, entry.ch do
                local v = entry.maxs[c][px] or 0
                if v > vmax then vmax = v end
                v = entry.mins[c][px] or 0
                if v < vmin then vmin = v end
            end
            local y1 = mid - vmax * scale
            local y2 = mid - vmin * scale
            if y2 - y1 < 1 then y2 = y1 + 1 end
            gfx.line(px - 1, y1, px - 1, y2)
        end
        gfx.dest = -1
    end
    if istrip.path == instr.path and istrip.w == w and instr.path then
        gfx.dest = -1
        gfx.a, gfx.mode = 1, 0
        gfx.blit(INST_BUF, 1, 0, 0, 0, w, h, x, y, w, h)
    else
        Core_tk.DrawRect(x, y, w, h, col_bg[1], col_bg[2], col_bg[3], 1)
        if instr.path then UI.RequestRedraw() end
    end

    -- region overlay + drag (RS5K start/end offsets)
    local s = Kit.InstrParam(Kit.P.SOFFS) or 0
    local e = Kit.InstrParam(Kit.P.EOFFS) or 1
    local xs, xe = x + s * w, x + e * w
    if xs > x then Core_tk.DrawRect(x, y, xs - x, h, 0, 0, 0, 0.55) end
    if xe < x + w then Core_tk.DrawRect(xe, y, x + w - xe, h, 0, 0, 0, 0.55) end
    Core_tk.DrawRect(xs, y, 1, h, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(xe - 1, y, 1, h, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(xs, y, 5, 8, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(xe - 5, y, 5, 8, col_acc[1], col_acc[2], col_acc[3], 1)
    Core_tk.DrawRect(x, y, w, h, col_bord[1], col_bord[2], col_bord[3],
                     (col_bord[4] or 1) * 0.6, false)

    local mx, my = Core_tk.GetMousePos()
    local inside = mx >= x and mx < x + w and my >= y and my < y + h
    if not Core_tk.HasPopup() then
        if inside and Core_tk.MouseClicked(1) then
            if math.abs(mx - xs) <= 6 then state.rdrag = { mode = "s", instr = true }
            elseif math.abs(mx - xe) <= 6 then state.rdrag = { mode = "e", instr = true }
            elseif mx > xs and mx < xe then
                state.rdrag = { mode = "m", instr = true, grab = (mx - x) / w - s }
            else state.rdrag = { mode = (mx < xs) and "s" or "e", instr = true } end
        end
        if state.rdrag and state.rdrag.instr then
            if Core_tk.MouseDown(1) then
                local frac = (mx - x) / w
                if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
                local MINW = 0.004
                if state.rdrag.mode == "s" then
                    Kit.SetInstrParam(Kit.P.SOFFS, math.min(frac, e - MINW))
                elseif state.rdrag.mode == "e" then
                    Kit.SetInstrParam(Kit.P.EOFFS, math.max(frac, s + MINW))
                else
                    local wd = e - s
                    local ns = frac - state.rdrag.grab
                    if ns < 0 then ns = 0 end
                    if ns + wd > 1 then ns = 1 - wd end
                    Kit.SetInstrParam(Kit.P.SOFFS, ns)
                    Kit.SetInstrParam(Kit.P.EOFFS, ns + wd)
                end
                UI.SetCursor(state.rdrag.mode == "m" and "size_all" or "size_we")
            else
                state.rdrag = nil
            end
        elseif inside then
            UI.SetCursor((math.abs(mx - xs) <= 6 or math.abs(mx - xe) <= 6)
                         and "size_we" or "arrow")
        end
    end
end

-- Static keyboard layout (built once — the frame loop must not allocate).
local KB_WHITES = {}
for n = KB_LO, KB_HI do if WHITE_STEP[n % 12] then KB_WHITES[#KB_WHITES + 1] = n end end
local KB_NW = #KB_WHITES
local KB_WIDX = {}                 -- note → white-key column index (0-based)
for i = 1, KB_NW do KB_WIDX[KB_WHITES[i]] = i - 1 end

-- Mini piano keyboard: white keys full height, black keys on top; click
-- plays chromatically, the root note is outlined.
local function instrKeyboard(theme, x, y, w, h)
    local instr = Kit.instr
    local col_acc  = theme.colors.accent
    local col_mute = theme.colors.text_mute or theme.colors.text_disabled
    local nw = KB_NW
    local kw = w / nw
    -- white-key screen x for a note = x + KB_WIDX[note]*kw (built once)

    local mx, my = Core_tk.GetMousePos()
    local inside = mx >= x and mx < x + w and my >= y and my < y + h
    local hit = nil

    -- white keys
    for i = 1, nw do
        local n = KB_WHITES[i]
        local kx = x + (i - 1) * kw
        local playing = state.press_midi == n
        local rc = (n == instr.root)
        Core_tk.DrawRect(kx, y, kw - 1, h,
            playing and col_acc[1] or 0.85,
            playing and col_acc[2] or 0.85,
            playing and col_acc[3] or 0.87, 1)
        if rc then
            Core_tk.DrawRect(kx, y, kw - 1, h, col_acc[1], col_acc[2], col_acc[3], 1, false)
        end
        if n % 12 == 0 then
            Core_tk.DrawText(NOTE_NAMES[n], kx + 2, y + h - 14, 0.2, 0.2, 0.2, 1)
        end
    end
    -- black keys (on top, half height, between whites)
    local bh = h * 0.6
    for n = KB_LO, KB_HI do
        if not WHITE_STEP[n % 12] then
            local bx = x + (KB_WIDX[n - 1] or 0) * kw + kw * 0.62
            local bw = kw * 0.66
            local playing = state.press_midi == n
            local rc = (n == instr.root)
            Core_tk.DrawRect(bx, y, bw, bh,
                playing and col_acc[1] or 0.12,
                playing and col_acc[2] or 0.12,
                playing and col_acc[3] or 0.13, 1)
            if rc then
                Core_tk.DrawRect(bx, y, bw, bh, col_acc[1], col_acc[2], col_acc[3], 1, false)
            end
        end
    end

    -- hit test on click: black keys first (they sit on top)
    if inside and not Core_tk.HasPopup() and Core_tk.MouseClicked(1) then
        for n = KB_LO, KB_HI do
            if not WHITE_STEP[n % 12] then
                local bx = x + (KB_WIDX[n - 1] or 0) * kw + kw * 0.62
                local bw = kw * 0.66
                if mx >= bx and mx < bx + bw and my < y + bh then hit = n break end
            end
        end
        if not hit then
            local i = math.floor((mx - x) / kw) + 1
            hit = KB_WHITES[math.max(1, math.min(nw, i))]
        end
        if hit then
            local set_root = Core_tk.ModCtrl()
            if set_root then Kit.SetRoot(hit) flash("Root = " .. NOTE_NAMES[hit])
            else instrNoteOn(hit) end
        end
    end
    if inside then UI.SetCursor("hand") end
    -- octave label hint
    Core_tk.DrawText("Ctrl+click = set root", x, y - 13,
                     col_mute[1], col_mute[2], col_mute[3], 0.8)
end

local function drawInstrument(theme, avail_h)
    local instr = Kit.instr
    if not instr then Kit.EnsureInstrument() instr = Kit.instr end

    UI.SetFontH2()
    UI.Text(instr.path and instr.name or "Instrument")
    UI.SetFontCaption()
    UI.SameLine(10)
    if instr.path then
        UI.Text("root " .. NOTE_NAMES[instr.root] .. "  ·  play with a MIDI keyboard",
                { disabled = true })
    else
        UI.Text("Drop a sample — it plays chromatically across the keyboard",
                { disabled = true })
    end
    UI.SetFontBody()

    local x, y = UI.GetCursorPos()
    local w = UI.GetAvailableWidth()
    -- layout: waveform (fills), knobs row, keyboard at the bottom
    local kb_h   = 90
    local knob_h = 58
    local wave_h = math.max(60, avail_h - kb_h - knob_h - 24)

    instrWave(theme, x, y, w, wave_h)
    UI.Layout.AdvanceCursor(w, wave_h)
    UI.Spacing(4)

    -- knobs + root
    iknob("i_vol", "Vol", Kit.P.VOL, Kit.DEFAULT_VOL)
    iknob("i_pan", "Pan", Kit.P.PAN, 0.5)
    iknob("i_tune", "Tune", Kit.P.TUNE, 0.5)
    iknob("i_att", "A", Kit.P.ATTACK, Kit.DEFAULT_ATT)
    iknob("i_dec", "D", Kit.P.DECAY, Kit.DEFAULT_DEC)
    iknob("i_sus", "S", Kit.P.SUSTAIN, Kit.DEFAULT_SUS)
    iknob("i_rel", "R", Kit.P.RELEASE, Kit.DEFAULT_REL)
    local rootv, nroot = UI.NumberInput("i_root", "Root", instr.root, 0, 127,
                                        ROOT_OPTS)
    if rootv then Kit.SetRoot(nroot) end
    UI.SameLine()
    local lv = Kit.InstrParam(Kit.P.LOOP) or 0
    local ltog, lon = UI.Checkbox("i_loop", "Loop", lv >= 0.5)
    if ltog then Kit.SetInstrParam(Kit.P.LOOP, lon and 1 or 0) end

    UI.Spacing(16)
    local kx, ky = UI.GetCursorPos()
    instrKeyboard(theme, kx, ky, w, kb_h)
    UI.Layout.AdvanceCursor(w, kb_h)
end

-- ---------------------------------------------------------------------------
-- Keyboard
-- ---------------------------------------------------------------------------
local function handleKeys()
    if Core_tk.HasPopup() then return end
    if Kit.mode == "instrument" then return end   -- played via MIDI/mouse
    local char = Core_tk.GetChar()
    if not char or char <= 0 then return end
    if Core_tk.GetState().focus then return end

    local note = state.sel or pageBase()

    if char == Keys.LEFT then
        if note > Kit.BASE then state.sel = note - 1 end
        UI.ConsumeChar()
    elseif char == Keys.RIGHT then
        if note < Kit.BASE + Kit.MAX - 1 then state.sel = note + 1 end
        UI.ConsumeChar()
    elseif char == Keys.UP then
        if note + 4 < Kit.BASE + Kit.MAX then state.sel = note + 4 end
        UI.ConsumeChar()
    elseif char == Keys.DOWN then
        if note - 4 >= Kit.BASE then state.sel = note - 4 end
        UI.ConsumeChar()
    elseif char == Keys.ENTER or char == Keys.SPACE then
        padOn(note)
        if state.press_midi then
            -- keyboard has no key-up: schedule the note-off
            state.key_off_note = state.press_midi
            state.key_off_t = r.time_precise() + 0.2
            state.press_midi = nil
        end
        UI.ConsumeChar()
    elseif char == Keys.DELETE then
        Kit.ClearPad(note)
        UI.ConsumeChar()
    elseif char == Keys.PAGE_UP then
        state.page = math.min(3, state.page + 1)
        markDirty()
        UI.ConsumeChar()
    elseif char == Keys.PAGE_DOWN then
        state.page = math.max(0, state.page - 1)
        markDirty()
        UI.ConsumeChar()
    elseif char >= Keys.N1 and char <= Keys.N4 then
        state.page = char - Keys.N1
        markDirty()
        UI.ConsumeChar()
    end

    -- follow the selection across pages
    if state.sel then
        local page = math.floor((state.sel - Kit.BASE) / 16)
        if page ~= state.page and (char == Keys.LEFT or char == Keys.RIGHT
                                   or char == Keys.UP or char == Keys.DOWN) then
            state.page = page
            markDirty()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------
local function frame(theme)
    if Kit.Poll() then
        state.meta_key = nil
        UI.RequestRedraw()
    end
    Audio.Poll()
    if Wave and Wave.Step() then UI.RequestRedraw() end
    busConsume()
    instrumentPoll()
    handleFileDrops()
    handleKeys()

    -- deferred keyboard note-off
    if state.key_off_note and r.time_precise() >= state.key_off_t then
        Kit.StuffNote(state.key_off_note, false)
        state.key_off_note = nil
    end

    local pad_l = theme.pad_large or 10
    UI.SetWindowPadding(pad_l)

    drawToolbar(theme)

    if Kit.Exists() and Kit.mode == "instrument" then
        UI.Spacing(theme.pad_small or 4)
        drawInstrument(theme, UI.GetAvailableHeight())
        -- release a MIDI-triggered note on mouse-up (keyboard clicks)
        if state.press_midi and not Core_tk.MouseDown(1) then
            Kit.StuffNote(state.press_midi, false)
            state.press_midi = nil
        end
    else
        -- Controls reserve tracks the selection: a loaded pad needs the full
        -- strip, an empty one two lines — the grid gets everything else.
        local avail = UI.GetAvailableHeight()
        local selpad = state.sel and Kit.pads[state.sel]
        local ctrl_h = (selpad and selpad.fx) and CTRL_H or 56
        local grid_h = avail - ctrl_h
        if grid_h < 120 then grid_h = math.max(80, avail - 60) end
        drawGrid(theme, grid_h)

        UI.Spacing(theme.pad_small or 4)
        drawControls(theme)

        handlePadDrag()
    end

    -- status flash
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            UI.SetFontCaption()
            UI.Text(state.flash_msg, { disabled = true })
            UI.SetFontBody()
            UI.RequestRedraw()
        else
            state.flash_msg = ""
        end
    end

    if state.cfg_dirty and not Core_tk.MouseDown(1) then
        persistConfig()
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("Sampler", 420, 560, {
    persist    = CONFIG_ID,
    scrollable = false,
})

UI.OnClose(function()
    r.TrackCtl_SetToolTip("", 0, 0, true)
    if state.press_midi then Kit.StuffNote(state.press_midi, false) end
    if state.key_off_note then Kit.StuffNote(state.key_off_note, false) end
    DragBus.Unregister(BUS_ID)
    persistConfig()
    Audio.Destroy()
    if Wave then Wave.Destroy() end
end)

r.atexit(function()
    r.TrackCtl_SetToolTip("", 0, 0, true)
    pcall(DragBus.Unregister, BUS_ID)
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
