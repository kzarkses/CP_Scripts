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
local cp_root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
local UI = dofile(cp_root .. "CP_Toolkit/CP_Toolkit.lua")

local Kit     = dofile(cp_root .. "CP_Engine/Kit.lua")
local Tracks  = dofile(cp_root .. "CP_Engine/Tracks.lua")
local Tempo   = dofile(cp_root .. "CP_Engine/Tempo.lua")
local Bake    = dofile(cp_root .. "CP_Engine/Bake.lua")
-- L'AUDITION PARTAGEE (feuille de route phase 3). Le meme geste — on
-- appuie, ca sonne — etait ecrit trois fois dans la suite ; c'est
-- desormais un seul module, qui choisit par CAPACITE entre une voix du
-- moteur et CF_Preview. Un pad court entre donc en RAM et attaque a
-- l'echantillon, sans que cette fenetre ait a le savoir.
local Audition = dofile(cp_root .. "CP_Engine/Audition.lua")
local DragBus = dofile(cp_root .. "CP_Toolkit/DragBus.lua")
local Clip    = dofile(cp_root .. "CP_Engine/Clip.lua")
local Bus     = dofile(cp_root .. "CP_Engine/Bus.lua")

-- Soft dependency: the engine's peaks reader draws the region strip
-- (falls back to a plain range slider when the package is absent).
local okW, Peaks = pcall(dofile, cp_root .. "CP_Engine/Peaks.lua")
if not okW or type(Peaks) ~= "table" then Peaks = nil end

Tracks.init(r)
Kit.init(r, Tracks)
Tempo.init(r)
Bake.init(r)
Audition.init(r)
DragBus.init(r)
Bus.init(r, DragBus, Clip)
if Peaks then Peaks.init(r) end

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
    -- Pads are an instrument, so a click sounds by default (FL/MPC). Turn this
    -- off to click a pad purely to SELECT it and edit its knobs — the useful
    -- mode while a loop is running. Enter/Space still triggers the selection.
    play_on_select = cfg.play_on_select ~= false,
}
Audition.volume = cfg.vol or 1.0

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
    cfg.play_on_select = opts.play_on_select
    cfg.vol      = Audition.volume
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
local PAGE_IDS    = { "pg1", "pg2", "pg3", "pg4" }
local PAGE_LBL    = { "1", "2", "3", "4" }
-- Role colour for the arm toggle, bound once. `record` is what the rest of the
-- suite already uses to mean "this is live"; rebuilt when the theme object
-- itself changes, never per frame.
local R_REC = { accent = nil }
-- Typing an exact value on a knob (right-click) needs the real unit, which
-- only the plugin knows. The conversion pair is bound ONCE to these two
-- upvalues and re-aimed before each knob call — closures built per frame
-- would allocate in the draw loop, which is exactly what we don't do.
local ent_note, ent_pid
local KNOB_OPTS   = {
    size = 34,
    decimals = 2,
    to_display   = function() return Kit.ParamPlain(ent_note, ent_pid) or 0 end,
    from_display = function(v) return Kit.NormForPlain(ent_note, ent_pid, v) end,
}
local IKNOB_OPTS  = {
    size = 34,
    decimals = 2,
    to_display   = function() return Kit.InstrParamPlain(ent_pid) or 0 end,
    from_display = function(v) return Kit.InstrNormForPlain(ent_pid, v) end,
}
-- ±24 st over the knob travel: slower drag so one pixel stays sub-decimal
local PITCH_KNOB_OPTS = {
    size = 34, sensitivity = 0.002, decimals = 2,
    to_display   = function() return Kit.PadPitch(ent_note) or 0 end,
    from_display = function(st) return 0.5 + st / 48 end,   -- the knob window
}
-- Instrument row: three controls that are not continuous, in a dial's box.
local ROOT_OPTS   = { on = false,
    tip = "Root note — the key the sample plays at its own pitch (click: choose, wheel: semitone, Ctrl+click a key)" }
local VOICE_OPTS  = { on = false,
    tip = "Voices — 1 is monophonic, so every note cuts the one before it (click: choose, wheel: step)" }
local ILOOP_OPTS  = { tip = "Loop the sample while a note is held; release fades out" }
local VOICE_LBL   = { "1", "2", "3", "4", "5", "6", "7", "8",
                      "9", "10", "11", "12", "13", "14", "15", "16" }
local PLAY_OPTS   = {}            -- pooled Audition.Play opts
local GRID_GAP    = 6
-- Control strip reserve. It is the SAME whatever is selected: the strip draws
-- its dials disabled rather than collapsing, so the grid never resizes under
-- the cursor because a click landed on an empty pad.
local CTRL_H      = 176
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

-- Publish "open this pad's sample in CP_Editor" (picked up if it runs):
-- a Clip over the Engine Bus, carrying the pad's trim as the region so
-- the editor lands selected on exactly what the pad plays.
local function editorOpen(note)
    local pad = Kit.pads[note]
    if not (pad and pad.path) then return end
    local c = Clip.new("audio")
    c.path = pad.path
    c.name = pad.name
    local s = Kit.Param(note, Kit.P.SOFFS) or 0
    local e = Kit.Param(note, Kit.P.EOFFS) or 1
    if e > s and (s > 0 or e < 1) then
        local len = Audition.Meta(pad.path)
        if len and len > 0 then
            c.offs, c.len = s * len, (e - s) * len
        end
    end
    Bus.Send("editor:open", c)
end

-- ---------------------------------------------------------------------------
-- Audition (press = sound, FL/MPC style — pads are an instrument)
-- ---------------------------------------------------------------------------
-- WHICH OF THE THREE PRODUCERS THIS CLICK GOES TO. Extracted so the status
-- line and the trigger read the SAME expression: a badge that keeps its own
-- copy of this rule is a badge that will eventually lie, and a lying badge is
-- worse than none — it is what you check when you already doubt the sound.
-- L'ARMEMENT N'ENTRE PLUS DANS CETTE REPONSE, et c'est le changement qui rend
-- la fenetre lisible. « auto » voulait dire « par le kit SI une piste est
-- armee », parce qu'une note d'apercu partait en broadcast et n'atteignait
-- qu'une piste armee ; il fallait donc armer, et le sampler armait de force.
-- La note a une adresse maintenant : elle atteint le kit, armee ou pas. Donc
-- « auto » veut dire ce qu'il a toujours voulu dire — FAIS SONNER LE PAD, avec
-- sa chaine d'effets, son choke et son enveloppe — et le repli sur la lecture
-- brute du fichier ne sert plus qu'aux pads sans instrument.
local function padUsesMidi(pad)
    return opts.audition == "midi"
        or (opts.audition == "auto" and Kit.Exists())
        or not (pad and pad.path)   -- no readable file → only MIDI can play it
end

local function padOn(note)
    local pad = Kit.pads[note]
    if not pad or not pad.fx then return end
    local use_midi = padUsesMidi(pad)
    if use_midi then
        Kit.PlayNote(note, true, opts.velocity)
        state.press_midi = note
    else
        local len = Audition.Meta(pad.path)
        PLAY_OPTS.start_s, PLAY_OPTS.end_s = nil, nil
        if len then
            local s = Kit.Param(note, Kit.P.SOFFS) or 0
            local e = Kit.Param(note, Kit.P.EOFFS) or 1
            if s > 0 then PLAY_OPTS.start_s = s * len end
            if e < 1 then PLAY_OPTS.end_s = e * len end
        end
        Audition.Play(pad.path, PLAY_OPTS)
    end
end

local function padOff()
    if state.press_midi then
        Kit.PlayNote(state.press_midi, false)
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

-- Native item drag from the ARRANGE onto a pad: REAPER holds the mouse
-- capture during an item drag, so we poll the OS cursor (the same trick
-- as busHover below). Arm on a press that starts over the arrange with a
-- selected item; on release over one of our pads, load that item's audio
-- into it. The item itself never moves — releasing outside the arrange
-- cancels REAPER's own drag, so this is non-destructive by construction.
local arr = { armed = false, was_down = false }

local function arrangeDropPoll()
    if not (r.JS_Mouse_GetState and r.JS_Window_FromPoint) then return end
    local down = (r.JS_Mouse_GetState(1) & 1) == 1
    local sx, sy = r.GetMousePosition()
    local cx, cy = Core_tk.ScreenToClient(sx, sy)
    local over_us = cx >= 0 and cy >= 0 and cx < gfx.w and cy < gfx.h
    if down and not arr.was_down then
        arr.armed = false
        if not over_us and r.CountSelectedMediaItems(0) > 0 then
            local w = r.JS_Window_FromPoint(sx, sy)
            if w and r.JS_Window_GetClassName(w) == "REAPERTrackListWindow" then
                arr.armed = true
            end
        end
    elseif not down and arr.was_down then
        if arr.armed and over_us then
            local item = r.GetSelectedMediaItem(0, 0)
            local take = item and r.GetActiveTake(item)
            local src = take and not r.TakeIsMIDI(take)
                        and r.GetMediaItemTake_Source(take)
            if src then
                local par = r.GetMediaSourceParent(src)   -- unwrap SECTION
                if par then src = par end
                local path = r.GetMediaSourceFileName(src)
                local note = padAt(cx, cy)
                if path and path ~= "" and note then
                    loadInto(note, path)
                end
            end
        end
        arr.armed = false
    end
    if arr.armed and down and over_us then UI.RequestRedraw() end
    arr.was_down = down
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

-- Bake the pad's trimmed region (SOFFS..EOFFS) into a new WAV next to the
-- source and point the pad at it — destructive editing without touching the
-- original file. With no trim set this consolidates the sample as a clean
-- WAV copy (useful to materialize an MP3/FLAC pad).
local function bakeCropPad(note)
    local pad = Kit.pads[note]
    if not (pad and pad.path) then return end
    local s = Kit.Param(note, Kit.P.SOFFS) or 0
    local e = Kit.Param(note, Kit.P.EOFFS) or 1
    if e <= s then flash("Nothing to crop") return end
    local psrc = r.PCM_Source_CreateFromFile(pad.path)
    if not psrc then flash("Cannot open " .. pad.path) return end
    local slen = r.GetMediaSourceLength(psrc)
    r.PCM_Source_Destroy(psrc)
    local dst = Bake.NextPath(pad.path, "crop")
    local frames, err = Bake.FileRegionToWav(pad.path, s * slen, e * slen, dst)
    if not frames then flash("Bake failed: " .. (err or "?")) return end
    -- same musical material in a cleaner file: the pad keeps its tempo
    -- identity (sync flag + source BPM) instead of re-deriving from the crop
    Kit.LoadSample(note, dst, { keep_sync = true })
    flash("Baked -> " .. (dst:match("[^\\/]+$") or dst))
end

local function openPadMenu(note)
    local pad = Kit.pads[note]
    local has = pad and pad.path
    local items = {
        { label = "Load sample...", action = function() browseInto(note) end },
    }
    if has then
        items[#items + 1] = { label = "Open in Editor",
                              action = function() editorOpen(note) end }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { label = "Choke group", children = chokeMenuItems(note) }
        -- Tempo sync (vinyl-style repitch through TUNE; Engine/Tempo feeds
        -- the project BPM every frame, Kit re-aims on change).
        local src = Kit.PadSrcBpm(note)
        items[#items + 1] = { label = "Sync to project tempo"
                                  .. (src and ("  (src " .. src .. " BPM)")
                                           or "  (source BPM unknown)"),
                              checked = Kit.PadSynced(note),
                              action = function()
            local on = not Kit.PadSynced(note)
            if on and not Kit.PadSrcBpm(note) then
                local ok, v = r.GetUserInputs("Source tempo", 1,
                    "Loop BPM:,extrawidth=80", "")
                local bpm = ok and tonumber(v) or nil
                if not bpm or bpm <= 0 then return end
                Kit.SetPadSrcBpm(note, bpm)
            end
            Kit.SetPadSynced(note, on)
            if on then Kit.ApplyTempoSync(Tempo.Get().tempo) end
        end }
        items[#items + 1] = { label = "Set source BPM...", action = function()
            local ok, v = r.GetUserInputs("Source tempo", 1,
                "Loop BPM:,extrawidth=80", tostring(src or ""))
            local bpm = ok and tonumber(v) or nil
            if bpm and bpm > 0 then
                Kit.SetPadSrcBpm(note, bpm)
                if Kit.PadSynced(note) then
                    Kit.ApplyTempoSync(Tempo.Get().tempo)
                end
            end
        end }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { label = "Bake: crop to trim (new file)",
                              action = function() bakeCropPad(note) end }
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
            auditionItem("Auto — play the pad (FX chain, choke, envelope)", "auto"),
            auditionItem("Always play the pad", "midi"),
            auditionItem("Always preview the raw file", "preview"),
        } },
        { label = "Pad velocity", children = {
            velocityItem(64), velocityItem(80), velocityItem(100),
            velocityItem(112), velocityItem(127),
        } },
        -- "Clicking a pad plays it" lives in the BAR now (the pointer chip):
        -- it is answered several times a session, and a decision taken that
        -- often has no business being two clicks deep in a menu.
        { separator = true },
        -- L'ARMEMENT NE FAIT PLUS SONNER LES CLICS : ils sonnent toujours,
        -- parce qu'ils ont une adresse. Il ne veut donc plus dire que ce que
        -- REAPER en dit — cette piste enregistre et monitore son entree — et
        -- l'intitule le dit, sinon on reprendrait l'ancienne habitude.
        { label = Kit.mode == "instrument"
                  and "Record-arm the instrument track (play it from a keyboard)"
                  or "Record-arm the kit track (play it from a keyboard)",
          checked = Kit.Armed(),
          action = function() Kit.SetArmed(not Kit.Armed()) end },
        { label = "Listen to every MIDI input on that track",
          checked = Kit.InputIsAll(),
          disabled = Kit.InputIsAll(),
          action = function()
            Kit.SetInputAll()
            flash("Kit track now listens to all MIDI inputs")
          end },
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
-- Command bar
-- ---------------------------------------------------------------------------
-- The local `iconBtn` is gone. It was one of three private copies across the
-- repo, with two incompatible signatures, all of them re-solving what the
-- toolkit now owns: a chip of the bar's one height, with four states and a
-- tooltip.

-- Multi-kit selector: the label caches on Kit.version (GetTrackName
-- allocates, and the toolbar runs every frame).
local kitsel = { ver = -1, label = "" }

local function kitMenu()
    local items = {}
    for _, ktr in ipairs(Kit.kits) do
        local _, nm = r.GetTrackName(ktr)
        if nm == "" then nm = "Kit" end
        local tr = ktr
        items[#items + 1] = { label = nm, checked = tr == Kit.parent,
                              action = function()
                                  Kit.SetActive(tr)
                                  markDirty()
                                  flash("Kit: " .. nm)
                              end }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "New kit...", action = function()
        local ok, name = r.GetUserInputs("New kit", 1, "Name:,extrawidth=140", "")
        if ok then
            Kit.NewKit(name)
            markDirty()
            flash("New kit created")
        end
    end }
    UI.NativeMenu(items)
end

-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## CP Sampler
Pads are an instrument: a click plays through the real engine (one
RS5K per pad). ONE kit listens at a time — the toolbar kit button
picks it; the other kits still play from the Looper's lanes. Drop
files from the Media Explorer or drag an item from the arrange onto
a pad.

## Two instruments, two tracks
DRUM (the pads) and INSTRUMENT (one sample across the keyboard) are
two separate instruments on two separate tracks: both keep playing
whatever is sent to them, and each has its own output to mix. The
toolbar's Drum/Piano pair only says which one you are LOOKING at —
and, with it, which one hears your keyboard and your clicks, since
only one of them can (a click is a broadcast). Record arms the one
on screen.

The POINTER button says whether clicking a pad plays it. Off, a click
only selects — the useful mode while a loop is running — and Enter
plays the selection.

## Pad
Vol / Pan / Tune (vinyl repitch) / Pitch (elastique, length kept) /
ADSR. Loop gates the sample while the pad is held. Choke groups cut
each other. Shift = fine drag on every knob.

Two families, stacked, so they never fight over a click: the REGION
lives in the band along the BOTTOM of the waveform — drag an edge to
trim, drag between them to slide the whole thing — and the ENVELOPE
handles live on the waveform itself. Every handle lights up under the
cursor and grows while you hold it.

## Instrument
One sample across the keyboard, pitched from a ROOT note (click the
chip to choose one, wheel it by semitone, or Ctrl+click a key). VOICES
is this instrument's choke: at 1 it is monophonic and every note cuts
the one before it. Loop and the region band behave as they do on a pad.

## Right-click a pad
Load sample, Open in Editor (the trim lands selected), Bake: crop to
a new file, Sync to project tempo, choke group.
]]

-- CE QUE L'ARMEMENT DIT MAINTENANT. Il ne parle plus des clics — ils sonnent
-- dans tous les cas, parce qu'ils s'adressent a la piste du kit et a elle
-- seule. Il ne parle que de ce dont REAPER parle : un clavier branche, et
-- l'enregistrement de ce qu'on y joue.
local ARM_ON  = "Record-armed: your MIDI keyboard plays the kit, and records here"
local ARM_OFF = "Not record-armed. Pad clicks sound anyway"
local IARM_ON  = "Record-armed: your MIDI keyboard plays the instrument, and records here"
local IARM_OFF = "Not record-armed. Key clicks sound anyway"
local CLICK_ON  = "Clicking a pad plays it"
local CLICK_OFF = "Clicking a pad only selects it — Enter plays"
local KIT_W   = { w = 4 }

local function drawToolbar(theme)
    R_REC.accent = theme.colors.record or theme.colors.danger
    UI.BeginBar("cmd")

    -- Right end claimed first, so a narrow window sheds a page button rather
    -- than Settings. Outermost written first: Help hard against the edge.
    UI.BarRight()
    if UI.BarIcon("help", "Help", "Help") then UI.ShowHelp("help", HELP_TEXT) end
    if UI.BarIcon("settings", "Settings", "Settings") then openSettings() end
    if UI.BarIcon("load_kit", "Folder", "Load kit preset") then loadPresetMenu() end
    if UI.BarIcon("save_kit", "Save", "Save kit preset") then savePresetDialog() end
    UI.BarSep()
    UI.BarLeft()

    if not Kit.Exists() then
        if UI.BarButton("mk_kit", "Create kit bus") then
            Kit.Ensure()
            flash("Kit bus created — drop samples on the pads")
        end
        UI.EndBar()
        return
    end

    -- Armed: a held state, so it lights. The role colour is `record`, which
    -- is what the rest of the suite already uses to mean "this is live".
    -- It arms WHAT IS ON SCREEN — the pads or the instrument — and it does not
    -- disarm the other one: a track the user armed himself is his.
    local armed = Kit.Armed()
    local inst = Kit.mode == "instrument"
    if UI.BarToggle("arm", "Record", nil, armed,
                    armed and (inst and IARM_ON or ARM_ON)
                           or (inst and IARM_OFF or ARM_OFF),
                    false, R_REC) then
        Kit.SetArmed(not armed)
    end

    -- Does a click SOUND? The other half of the arm question, and one that is
    -- answered several times a session — drumming on the pads, then dialling
    -- knobs while a loop runs — so it belongs in the bar, not in a menu.
    if UI.BarToggle("clickplay", "Pointer", nil, opts.play_on_select,
                    opts.play_on_select and CLICK_ON or CLICK_OFF) then
        opts.play_on_select = not opts.play_on_select
        markDirty()
    end
    UI.BarSep()

    -- Mode: two glyphs rather than two words. Pads versus a keyboard says it
    -- without being read, and the pair reads as one choice.
    if UI.BarToggle("mode_drum", "Drum", nil, Kit.mode == "drum", "Drum pads") then
        if Kit.mode ~= "drum" then Kit.SetMode("drum") end
    end
    if UI.BarToggle("mode_inst", "Piano", nil, Kit.mode == "instrument",
                    "Instrument (chromatic)") then
        if Kit.mode ~= "instrument" then Kit.SetMode("instrument") end
    end

    -- Kit selector: active kit's name; the menu switches or creates. Shown as
    -- soon as a kit exists so "New kit..." is always reachable.
    if kitsel.ver ~= Kit.version then
        kitsel.ver = Kit.version
        local _, nm = r.GetTrackName(Kit.parent)
        kitsel.label = (nm ~= "" and nm or "Kit")
                     .. (#Kit.kits > 1 and ("  (" .. #Kit.kits .. ")") or "")
    end
    UI.BarSep()
    if UI.BarButton("kit_sel", kitsel.label, false, false, KIT_W) then
        kitMenu()
    end

    -- Pages (drum mode only): four square chips, lit on the current one.
    if Kit.mode == "drum" then
        UI.BarSep()
        for p = 1, 4 do
            if UI.BarToggle(PAGE_IDS[p], nil, nil, p == state.page + 1,
                            PAGE_LBL[p]) then
                state.page = p - 1
                markDirty()
            end
        end
    end

    UI.EndBar()
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
    state.press = { note = note, x = mx, y = my }   -- still needed for pad→pad drag
    if opts.play_on_select then padOn(note) end
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
    local len, ch, sr = Audition.Meta(pad.path)
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
local STRIP_H   = 44     -- the MINIMUM; the strip takes whatever is left over
local WAVE_BUF  = 905
local strip = { path = nil, w = 0, h = 0 }   -- buffer content key

-- Which handle is under the cursor. The drawing has to know BEFORE the click:
-- a handle that only answers once you have grabbed it is a handle you find by
-- trial. Same names and same priority order as the drag.
--
-- The REGION lives in a band along the BOTTOM — its edges, and the middle that
-- slides it. The rest of the height belongs to the envelope. Two families
-- stacked instead of two families competing: aiming at an ADSR handle can no
-- longer move the region by accident, and there is no need to wash the region
-- body in white to explain what a click there would do.
local REGION_BAND = 12

local function stripHit(mx, my, xs, xe, ax, dx, rxx, sy2, etop, ybot)
    if my < ybot - REGION_BAND then
        if ax and math.abs(mx - ax) <= 5 and my <= etop + 8 then return "a" end
        if dx and math.abs(mx - dx) <= 5 and math.abs(my - sy2) <= 6 then return "d" end
        if rxx and math.abs(mx - rxx) <= 5 and math.abs(my - sy2) <= 6 then return "r" end
        return nil
    end
    if math.abs(mx - xs) <= 6 then return "s" end
    if math.abs(mx - xe) <= 6 then return "e" end
    if mx > xs and mx < xe then return "m" end
    return nil
end

-- Rest / hover / grab, in one place. A handle answers by getting BIGGER and
-- brighter, because on a 5-px target a colour change alone is not an answer.
local function hgrow(hot, grabbed)
    if grabbed then return 3, 1 end
    if hot then return 2, 1 end
    return 0, 0.9
end

-- Lighten toward white — the envelope has no `_hovered` companion in the
-- theme, and inventing one for a single overlay is worse than a mix.
local function lift(c, k)
    return c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k
end

local WAVE_OPTS = { lanes = false, scale = 0.47 }
local EDGES = { "s", "e" }        -- region edges, in draw order
local ENV_H = { "a", "d", "r" }   -- envelope handles, in draw order

local function drawRegionStrip(theme, note, pad, h)
    h = math.floor(h or STRIP_H)
    if h < STRIP_H then h = STRIP_H end
    local x, y = UI.GetCursorPos()
    local aw = UI.GetAvailableWidth()
    local col_bg   = theme.colors.list_bg or theme.colors.window_bg
    local col_acc  = theme.colors.accent
    local col_bord = theme.colors.border
    local col_env  = theme.colors.mod or col_acc
    local SS = Peaks and Peaks.SS or 2

    local len = Audition.Meta(pad.path)
    local entry = nil
    if Peaks and len and len > 0 then
        local src = Audition.GetSource(pad.path)
        if src then
            -- peaks at the SUPERSAMPLED width: the smoothness comes from
            -- reading finer, not from blurring coarse data
            entry = Peaks.Read(src, pad.path, 0, len, aw * SS, 0)
        end
    end

    if entry and (strip.path ~= pad.path or strip.w ~= aw or strip.h ~= h) then
        strip.path, strip.w, strip.h = pad.path, aw, h
        gfx.dest = WAVE_BUF
        gfx.setimgdim(WAVE_BUF, aw * SS, h * SS)
        gfx.muladdrect(0, 0, aw * SS, h * SS, 0, 0, 0, 0)  -- undefined after resize
        gfx.set(col_bg[1], col_bg[2], col_bg[3], 1)
        gfx.rect(0, 0, aw * SS, h * SS, 1)
        Peaks.Render(entry, aw * SS, h * SS,
                     col_acc[1], col_acc[2], col_acc[3], 0.85, WAVE_OPTS)
        gfx.dest = -1
    end

    if strip.path == pad.path and strip.w == aw and strip.h == h then
        gfx.dest = -1
        gfx.a = 1
        local om = gfx.mode
        gfx.mode = 4                       -- filtered: the 2x bake downsamples smooth
        gfx.blit(WAVE_BUF, 1, 0, 0, 0, aw * SS, h * SS, x, y, aw, h)
        gfx.mode = om
    else
        Core_tk.DrawRect(x, y, aw, h, col_bg[1], col_bg[2], col_bg[3], 1)
        UI.RequestRedraw()   -- peaks still building
    end

    -- geometry FIRST, then the hover, then the drawing: everything that can
    -- light up has to know whether it is the thing under the cursor.
    local s = Kit.Param(note, Kit.P.SOFFS) or 0
    local e = Kit.Param(note, Kit.P.EOFFS) or 1
    local xs = x + s * aw
    local xe = x + e * aw

    local ax, dx, rxx, sy2, etop, ebot
    if len and len > 0 and xe - xs > 8 then
        local region_s = (e - s) * len
        local att_s = (Kit.ParamPlain(note, Kit.P.ATTACK) or 0) / 1000
        local dec_s = (Kit.ParamPlain(note, Kit.P.DECAY) or 0) / 1000
        local rel_s = (Kit.ParamPlain(note, Kit.P.RELEASE) or 0) / 1000
        local sus_db = Kit.ParamPlain(note, Kit.P.SUSTAIN) or 0
        local sus_l = 10 ^ (math.min(sus_db, 0) / 20)
        local pps = (xe - xs) / region_s
        -- The envelope lives ABOVE the region band. Without this, a sustain at
        -- minimum puts its two handles at the very bottom — inside the band,
        -- where the region answers first, and they become ungrabbable.
        etop, ebot = y + 2, y + h - 2 - REGION_BAND
        sy2 = etop + (1 - sus_l) * (ebot - etop)
        ax  = math.min(xs + att_s * pps, xe)
        dx  = math.min(ax + dec_s * pps, xe)
        rxx = math.max(math.min(xe - rel_s * pps, xe), dx)
    end

    local ybot = y + h
    local mx, my = Core_tk.GetMousePos()
    local inside = mx >= x and mx < x + aw and my >= y and my < ybot
    local grab = (state.rdrag and state.rdrag.note == note) and state.rdrag.mode or nil
    local hot = grab
    if not hot and inside and not Core_tk.HasPopup() and not Core_tk.MouseDown(1) then
        hot = stripHit(mx, my, xs, xe, ax, dx, rxx, sy2, etop, ybot)
    end

    -- region overlay: dim outside, edges lit, grips along the bottom band
    if xs > x then Core_tk.DrawRect(x, y, xs - x, h, 0, 0, 0, 0.55) end
    if xe < x + aw then Core_tk.DrawRect(xe, y, x + aw - xe, h, 0, 0, 0, 0.55) end
    local moving = (hot == "m")
    for i = 1, 2 do
        local ed  = EDGES[i]
        local hx  = (ed == "s") and xs or xe
        local lit = (hot == ed) or moving
        local col = (grab == ed) and (theme.colors.accent_active or col_acc)
                    or (lit and (theme.colors.accent_hovered or col_acc) or col_acc)
        local g, a = hgrow(lit, grab == ed)
        Core_tk.DrawRect((ed == "s") and hx or (hx - 1), y, 1, h,
                         col[1], col[2], col[3], a)
        local gw, gh = 5 + g, REGION_BAND + g
        Core_tk.DrawRect((ed == "s") and hx or (hx - gw), ybot - gh, gw, gh,
                         col[1], col[2], col[3], 1)
    end
    Core_tk.DrawRect(x, y, aw, h,
                     col_bord[1], col_bord[2], col_bord[3],
                     (col_bord[4] or 1) * 0.6, false)

    -- ADSR overlay: what the envelope does to THIS region, drawn in place
    -- and manipulated in place. Attack ramps from the region start (the
    -- fade-in), release ramps into the region end (the fade-out), the
    -- decay knee carries the sustain level on its y axis. Times are read
    -- as PLAIN values (ms) so pixels map to real milliseconds.
    -- The colour is `mod`, the theme's envelope purple — it was defined for
    -- exactly this and read by nobody.
    if ax then
        local er, eg, eb = col_env[1], col_env[2], col_env[3]
        Core_tk.DrawLine(xs, ebot, ax, etop, er, eg, eb, 0.9)
        Core_tk.DrawLine(ax, etop, dx, sy2, er, eg, eb, 0.9)
        Core_tk.DrawLine(dx, sy2, rxx, sy2, er, eg, eb, 0.75)
        Core_tk.DrawLine(rxx, sy2, xe, ebot, er, eg, eb, 0.9)
        for i = 1, 3 do
            local m = ENV_H[i]
            local hx = (m == "a") and ax or ((m == "d") and dx or rxx)
            local hy = (m == "a") and (etop - 1) or (sy2 - 3)
            local g = hgrow(hot == m, grab == m)
            local rr, gg, bb = er, eg, eb
            if grab == m then rr, gg, bb = lift(col_env, 0.45)
            elseif hot == m then rr, gg, bb = lift(col_env, 0.25) end
            Core_tk.DrawRect(hx - 3 - g * 0.5, hy - g * 0.5,
                             6 + g, 6 + g, rr, gg, bb, 1)
        end
    end

    -- interaction (RangeSlider grammar on the waveform; envelope handles
    -- hit-test first — they live inside the region)
    if not Core_tk.HasPopup() then
        if inside and Core_tk.MouseClicked(1) then
            local m = stripHit(mx, my, xs, xe, ax, dx, rxx, sy2, etop, ybot)
            if m == "m" then
                state.rdrag = { mode = "m", note = note, grab = (mx - x) / aw - s }
            elseif m then
                state.rdrag = { mode = m, note = note }
            elseif my >= ybot - REGION_BAND then
                -- in the region band but outside the region: the nearest edge
                -- comes to you, which is how a range behaves everywhere
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
                if state.rdrag.mode == "a" and len then
                    local t = ((mx - xs) / (xe - xs)) * ((e - s) * len)
                    Kit.SetParamPlain(note, Kit.P.ATTACK, math.max(0, t * 1000))
                    UI.SetCursor("size_we")
                elseif state.rdrag.mode == "d" and len and ax then
                    local t = ((mx - ax) / (xe - xs)) * ((e - s) * len)
                    Kit.SetParamPlain(note, Kit.P.DECAY, math.max(0, t * 1000))
                    local L = 1 - (my - etop) / (ebot - etop)
                    if L < 0.001 then L = 0.001 elseif L > 1 then L = 1 end
                    Kit.SetParamPlain(note, Kit.P.SUSTAIN, 20 * math.log(L, 10))
                    UI.SetCursor("size_all")
                elseif state.rdrag.mode == "r" and len then
                    local t = ((xe - mx) / (xe - xs)) * ((e - s) * len)
                    Kit.SetParamPlain(note, Kit.P.RELEASE, math.max(0, t * 1000))
                    UI.SetCursor("size_we")
                elseif state.rdrag.mode == "s" then
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
            -- the cursor answers the same hit-test the drawing used, so the
            -- pointer, the glow and the grab are never three opinions
            UI.SetCursor(hot == "m" and "size_all"
                         or (hot == "d" and "size_all")
                         or (hot and "size_we" or "arrow"))
        end
    end

    UI.Layout.AdvanceCursor(aw, h)
end

-- A dial for a pad parameter. `note` is nil when nothing usable is selected:
-- the dial is still DRAWN, at its default, disabled — a control strip that
-- empties itself takes the layout with it, and the window jumps by a hundred
-- pixels every time the selection moves.
local function knob(id, label, note, pid, default)
    local v = note and Kit.Param(note, pid)
    if not v then
        UI.BeginDisabled()
        UI.Knob(id, label, default or 0.5, default or 0.5, KNOB_OPTS)
        UI.EndDisabled()
        UI.SameLine()
        return
    end
    ent_note, ent_pid = note, pid          -- aim the entry conversions
    local changed, nv = UI.Knob(id, label, v, default or v, KNOB_OPTS)
    if changed then Kit.SetParam(note, pid, nv) end
    if UI.IsItemHovered() then
        UI.Tooltip(Kit.ParamFmt(note, pid) .. "  (right-click: type)")
    end
    UI.SameLine()
end

local CHOKE_LBL = { [0] = "Off", "1", "2", "3", "4", "5", "6", "7", "8" }
local CHOKE_OPTS = { on = false,
    tip = "Choke group — pads in the same group cut each other (click: choose, wheel: step)" }
local LOOP_OPTS = { tip = "Loop the sample while the pad is held; release fades out" }

local function drawControls(theme, avail_h)
    local note = state.sel
    local pad = note and Kit.pads[note]
    local live = (pad and pad.fx) and note or nil     -- nil ⇒ everything disabled

    local _, y0 = UI.GetCursorPos()

    UI.SetFontH2()
    UI.Text(pad and pad.name or "No pad selected")
    UI.SetFontCaption()
    UI.SameLine(10)
    if live and pad and pad.path then
        UI.Text(metaLine(pad), { disabled = true })
    elseif pad then
        UI.Text(NOTE_NAMES[note] .. "  ·  empty — drop a sample, or double-click to browse",
                { disabled = true })
    else
        UI.Text(Kit.Exists() and "select a pad, or drop a sample on one"
                              or "create the kit bus, then drop samples on the pads",
                { disabled = true })
    end
    UI.SetFontBody()

    knob("k_vol", "Vol", live, Kit.P.VOL, Kit.DEFAULT_VOL)
    knob("k_pan", "Pan", live, Kit.P.PAN, 0.5)
    knob("k_tune", "Tune", live, Kit.P.TUNE, 0.5)
    do
        -- Pitch that keeps the length (ReaPitch, élastique) — Tune above is
        -- RS5K resample, the vinyl move: pitch and duration coupled.
        -- The knob spans ±24 st on ReaPitch's continuous full-range shift
        -- (SetPadPitch clamps into the param's real bounds); Shift = fine.
        if live then
            local st = Kit.PadPitch(live)
            ent_note = live
            local changed, nv = UI.Knob("k_rpitch", "Pitch", 0.5 + st / 48, 0.5,
                                        PITCH_KNOB_OPTS)
            if changed then Kit.SetPadPitch(live, (nv - 0.5) * 48) end
            if UI.IsItemHovered() then
                UI.Tooltip(string.format("%+.2f st — elastique pitch, length unchanged (Shift = fine, right-click = type)", st))
            end
        else
            UI.BeginDisabled()
            UI.Knob("k_rpitch", "Pitch", 0.5, 0.5, PITCH_KNOB_OPTS)
            UI.EndDisabled()
        end
        UI.SameLine()
    end
    knob("k_att", "A", live, Kit.P.ATTACK, Kit.DEFAULT_ATT)
    knob("k_dec", "D", live, Kit.P.DECAY, Kit.DEFAULT_DEC)
    knob("k_sus", "S", live, Kit.P.SUSTAIN, Kit.DEFAULT_SUS)
    knob("k_rel", "R", live, Kit.P.RELEASE, Kit.DEFAULT_REL)

    -- Choke and Loop, in a DIAL'S FOOTPRINT. A labelled combo and a checkbox
    -- next to eight dials read as two intruders from another window — same
    -- row, three different heights and three different shapes. These are the
    -- same 34 px box with the same caption line underneath, so the row is a
    -- row again. The shape stays square: it says "not continuous".
    local grp = live and Kit.Choke(live) or 0
    CHOKE_OPTS.on = grp > 0
    CHOKE_OPTS.disabled = not live
    local ck, cd = UI.KnobChip("k_choke", "Choke", CHOKE_LBL[grp] or "Off", CHOKE_OPTS)
    if live and cd ~= 0 then
        local ng = grp + cd
        if ng < 0 then ng = 0 elseif ng > 8 then ng = 8 end
        if ng ~= grp then Kit.SetChoke(live, ng) end
    elseif live and ck then
        UI.NativeMenu(chokeMenuItems(live))
    end
    UI.SameLine()

    local lv = live and (Kit.Param(live, Kit.P.LOOP) or 0) or 0
    LOOP_OPTS.disabled = not live
    local ltog, lon = UI.KnobToggle("k_loop", "Loop", "Repeat", lv >= 0.5, LOOP_OPTS)
    -- SetLoop, not SetParam: loop gates (obey note-offs) so the ADSR applies
    -- to every hit instead of only the first pass of an endless voice
    if live and ltog then Kit.SetLoop(live, lon) end

    -- Sample region (RS5K start/end offsets). It takes ALL the height the
    -- control strip has left instead of a fixed 44 px with a dead band under
    -- it — the waveform is the one thing here that gets better with room, and
    -- a gap under it was the reserve nobody was using.
    UI.Spacing(2)
    local _, y1 = UI.GetCursorPos()
    local strip_h = STRIP_H
    if avail_h then
        local rest = avail_h - (y1 - y0)
        if rest > strip_h then strip_h = rest end
    end

    if live and Peaks and pad and pad.path then
        drawRegionStrip(theme, live, pad, strip_h)
    elseif live then
        local s = Kit.Param(live, Kit.P.SOFFS) or 0
        local e = Kit.Param(live, Kit.P.EOFFS) or 1
        local rchanged, ns, ne = UI.RangeSlider("k_region", "Region", s, e, 0, 1)
        if rchanged then Kit.SetOffsets(live, ns, ne) end
    else
        -- No pad: the strip's GROUND still holds its place, so the window has
        -- the same shape whether or not something is selected.
        local x, y = UI.GetCursorPos()
        local aw = UI.GetAvailableWidth()
        local bg = theme.colors.list_bg or theme.colors.window_bg
        local bd = theme.colors.border
        Core_tk.DrawRect(x, y, aw, strip_h, bg[1], bg[2], bg[3], 1)
        Core_tk.DrawRect(x, y, aw, strip_h, bd[1], bd[2], bd[3],
                         (bd[4] or 1) * 0.6, false)
        UI.Layout.AdvanceCursor(aw, strip_h)
    end
end

-- ---------------------------------------------------------------------------
-- Instrument (chromatic) view: one sample across the keyboard
-- ---------------------------------------------------------------------------
local INST_BUF   = 907
local IWAVE_OPTS = { lanes = false, scale = 0.46 }
local WHITE_STEP = { [0]=true,[2]=true,[4]=true,[5]=true,[7]=true,[9]=true,[11]=true }
local istrip = { path = nil, w = 0, h = 0 }
local KB_LO, KB_HI = 36, 84   -- C2..C6 mini keyboard range

local function iknob(id, label, pid, default)
    local v = Kit.InstrParam(pid)
    if not v then return end
    ent_pid = pid          -- instrument knobs have no note: their own opts
    local changed, nv = UI.Knob(id, label, v, default or v, IKNOB_OPTS)
    if changed then Kit.SetInstrParam(pid, nv) end
    if UI.IsItemHovered() then
        UI.Tooltip(Kit.InstrParamFmt(pid) .. "  (right-click: type)")
    end
    UI.SameLine()
end

-- Menus for the two chips (built on click, never per frame).
local function rootMenuItems(cur)
    local items = {}
    for n = 12, 108, 12 do
        local note = n
        items[#items + 1] = { label = NOTE_NAMES[note], checked = note == cur,
                              action = function() Kit.SetRoot(note) end }
    end
    return items
end

local VOICE_CHOICES = { 1, 2, 4, 8, 16 }

local function voiceMenuItems(cur)
    local items = {}
    for i = 1, #VOICE_CHOICES do
        local n = VOICE_CHOICES[i]
        items[i] = { label = (n == 1) and "1  (mono)" or tostring(n),
                     checked = n == cur,
                     action = function() Kit.SetInstrVoices(n) end }
    end
    return items
end

local function instrNoteOn(note)
    local instr = Kit.instr
    if not instr or not instr.path then return end
    local use_midi = opts.audition == "midi"
        or (opts.audition == "auto" and instr.fx ~= nil)
    if use_midi then
        Kit.PlayNote(note, true, opts.velocity)
        state.press_midi = note
    else
        PLAY_OPTS.start_s, PLAY_OPTS.end_s = nil, nil
        PLAY_OPTS.pitch = note - instr.root
        Audition.Play(instr.path, PLAY_OPTS)
        PLAY_OPTS.pitch = nil
    end
end

-- Waveform + draggable region over the instrument sample.
local function instrWave(theme, x, y, w, h)
    local instr = Kit.instr
    local col_bg   = theme.colors.list_bg or theme.colors.window_bg
    local col_acc  = theme.colors.accent
    local col_bord = theme.colors.border
    local len = instr.path and Audition.Meta(instr.path) or nil
    local entry = nil
    local SS = Peaks and Peaks.SS or 2
    if Peaks and len and len > 0 then
        local src = Audition.GetSource(instr.path)
        if src then entry = Peaks.Read(src, instr.path, 0, len, w * SS, 0) end
    end
    if entry and (istrip.path ~= instr.path or istrip.w ~= w or istrip.h ~= h) then
        istrip.path, istrip.w, istrip.h = instr.path, w, h
        gfx.dest = INST_BUF
        gfx.setimgdim(INST_BUF, w * SS, h * SS)
        gfx.muladdrect(0, 0, w * SS, h * SS, 0, 0, 0, 0)
        gfx.set(col_bg[1], col_bg[2], col_bg[3], 1)
        gfx.rect(0, 0, w * SS, h * SS, 1)
        Peaks.Render(entry, w * SS, h * SS,
                     col_acc[1], col_acc[2], col_acc[3], 0.85, IWAVE_OPTS)
        gfx.dest = -1
    end
    if istrip.path == instr.path and istrip.w == w and istrip.h == h and instr.path then
        gfx.dest = -1
        gfx.a = 1
        local om = gfx.mode
        gfx.mode = 4
        gfx.blit(INST_BUF, 1, 0, 0, 0, w * SS, h * SS, x, y, w, h)
        gfx.mode = om
    else
        Core_tk.DrawRect(x, y, w, h, col_bg[1], col_bg[2], col_bg[3], 1)
        if instr.path then UI.RequestRedraw() end
    end

    -- region overlay + drag (RS5K start/end offsets) — same grammar and the
    -- same three states as the pad strip: a handle answers by growing.
    local s = Kit.InstrParam(Kit.P.SOFFS) or 0
    local e = Kit.InstrParam(Kit.P.EOFFS) or 1
    local xs, xe = x + s * w, x + e * w
    local ybot = y + h
    local mx, my = Core_tk.GetMousePos()
    local inside = mx >= x and mx < x + w and my >= y and my < ybot
    local grab = (state.rdrag and state.rdrag.instr) and state.rdrag.mode or nil
    local hot = grab
    if not hot and inside and my >= ybot - REGION_BAND
       and not Core_tk.HasPopup() and not Core_tk.MouseDown(1) then
        if math.abs(mx - xs) <= 6 then hot = "s"
        elseif math.abs(mx - xe) <= 6 then hot = "e"
        elseif mx > xs and mx < xe then hot = "m" end
    end

    if xs > x then Core_tk.DrawRect(x, y, xs - x, h, 0, 0, 0, 0.55) end
    if xe < x + w then Core_tk.DrawRect(xe, y, x + w - xe, h, 0, 0, 0, 0.55) end
    for i = 1, 2 do
        local ed  = EDGES[i]
        local hx  = (ed == "s") and xs or xe
        local lit = (hot == ed) or (hot == "m")
        local col = (grab == ed) and (theme.colors.accent_active or col_acc)
                    or (lit and (theme.colors.accent_hovered or col_acc) or col_acc)
        local g, a = hgrow(lit, grab == ed)
        Core_tk.DrawRect((ed == "s") and hx or (hx - 1), y, 1, h,
                         col[1], col[2], col[3], a)
        local gw, gh = 5 + g, REGION_BAND + g
        Core_tk.DrawRect((ed == "s") and hx or (hx - gw), ybot - gh, gw, gh,
                         col[1], col[2], col[3], 1)
    end
    Core_tk.DrawRect(x, y, w, h, col_bord[1], col_bord[2], col_bord[3],
                     (col_bord[4] or 1) * 0.6, false)

    if not Core_tk.HasPopup() then
        -- the region lives in the bottom band, as it does on a pad strip
        if inside and my >= ybot - REGION_BAND and Core_tk.MouseClicked(1) then
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
            UI.SetCursor(hot == "m" and "size_all" or (hot and "size_we" or "arrow"))
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

    -- Root, Voices and Loop in a DIAL'S FOOTPRINT — the same move the pad
    -- strip made for Choke and Loop, and for the same reason: a number box and
    -- a checkbox parked at the end of a knob bank are two intruders from
    -- another window. Same 34 px square, same caption line, one row.
    -- Voices IS the instrument's choke: at 1 the RS5K is monophonic and every
    -- note cuts the one before it, which is the only choke a single chromatic
    -- instrument can have.
    local rk, rd = UI.KnobChip("i_root", "Root", NOTE_NAMES[instr.root], ROOT_OPTS)
    if rd ~= 0 then Kit.SetRoot(instr.root + rd)
    elseif rk then UI.NativeMenu(rootMenuItems(instr.root)) end
    UI.SameLine()

    local nv = Kit.InstrVoices()
    VOICE_OPTS.on = nv <= 1
    local vk, vd = UI.KnobChip("i_voices", "Voices", VOICE_LBL[nv] or "16",
                               VOICE_OPTS)
    if vd ~= 0 then Kit.SetInstrVoices(nv + vd)
    elseif vk then UI.NativeMenu(voiceMenuItems(nv)) end
    UI.SameLine()

    local lv = Kit.InstrParam(Kit.P.LOOP) or 0
    local ltog, lon = UI.KnobToggle("i_loop", "Loop", "Repeat", lv >= 0.5,
                                    ILOOP_OPTS)
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
    Audition.Poll()
    -- Project tempo → synced pads (chantier 8). One poll per frame; the
    -- re-aim runs only when the tempo moved or the kit changed (scan,
    -- load, swap — Kit.version covers them all), and Kit itself writes
    -- RS5K only on a real delta.
    local tp = Tempo.Poll()
    if tp.tempo ~= state.last_tempo or Kit.version ~= state.last_sync_ver then
        state.last_tempo, state.last_sync_ver = tp.tempo, Kit.version
        Kit.ApplyTempoSync(tp.tempo)
    end
    if Peaks and Peaks.Step() then UI.RequestRedraw() end
    busConsume()
    arrangeDropPoll()
    instrumentPoll()
    handleFileDrops()
    handleKeys()

    -- deferred keyboard note-off
    if state.key_off_note and r.time_precise() >= state.key_off_t then
        Kit.PlayNote(state.key_off_note, false)
        state.key_off_note = nil
    end

    local pad_l = theme.pad_large or 10
    UI.SetWindowPadding(pad_l)

    drawToolbar(theme)

    -- The status strip is a ZONE now: it owns the bottom of the window whether
    -- or not it has something to say. Before, it appeared under the content
    -- only while a flash lasted, so the layout jumped by a line every time the
    -- app told you something.
    local STATUS_H = 20
    local body_h = UI.GetAvailableHeight() - STATUS_H

    if Kit.Exists() and Kit.mode == "instrument" then
        UI.Spacing(theme.pad_small or 4)
        drawInstrument(theme, body_h - (theme.pad_small or 4))
        -- release a MIDI-triggered note on mouse-up (keyboard clicks)
        if state.press_midi and not Core_tk.MouseDown(1) then
            Kit.PlayNote(state.press_midi, false)
            state.press_midi = nil
        end
    else
        -- The controls reserve is FIXED, and the grid gets the rest. It used
        -- to shrink to 56 px for an empty pad, so clicking an empty pad
        -- resized the grid under the cursor — and the strip, sized for the
        -- tallest case, left a dead band under the waveform the rest of the
        -- time. Now the strip always claims CTRL_H and hands the leftover to
        -- the waveform, which is the one thing here that gets better with it.
        local avail = body_h
        local ctrl_h = CTRL_H
        local grid_h = avail - ctrl_h
        if grid_h < 120 then grid_h = math.max(80, avail - 60) end
        local _, gy0 = UI.GetCursorPos()
        drawGrid(theme, grid_h)

        UI.Spacing(theme.pad_small or 4)
        -- what the grid ACTUALLY took (its rows round), so the strip fills
        -- exactly what is left instead of trusting the reserve
        local _, gy1 = UI.GetCursorPos()
        drawControls(theme, body_h - (gy1 - gy0))

        handlePadDrag()
    end

    -- status zone
    local msg
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            msg = state.flash_msg
            UI.RequestRedraw()
        else
            state.flash_msg = ""
        end
    end
    -- QUI FERA LE SON AU PROCHAIN CLIC. Le meme clic part vers l'un de TROIS
    -- producteurs selon un etat invisible : le RS5K du pad, une voix du moteur,
    -- ou CF_Preview. Sans cette ligne, « impossible de savoir si c'est le
    -- nouveau moteur ou pas » etait litteralement vrai. Reconstruite seulement
    -- quand un de ses termes change : elle vit dans une boucle de dessin.
    do
        local pad = state.sel and Kit.pads[state.sel] or nil
        local src = padUsesMidi(pad) and ("RS5K/" .. Kit.PlayLabel())
                    or (Audition.WillUseVoices() and "voice" or "preview")
        if state.badge_src ~= src then
            state.badge_src = src
            state.badge = "engine " .. Audition.Label() .. " · pads: " .. src
        end
    end

    if not msg then
        if not Kit.Exists() then
            msg = "no kit bus yet — create one to start dropping samples"
        elseif Kit.mode == "instrument" then
            msg = "click the keyboard to play · drop a sample to load it chromatically"
        elseif state.sel and Kit.pads[state.sel] and Kit.pads[state.sel].fx then
            msg = "drag the region by its edges along the BOTTOM · ADSR handles on the waveform itself · right-click a pad for load / bake / choke"
        else
            msg = "drop a file or an arrange item on a pad · right-click for the pad menu"
        end
    end
    UI.AppStatus((msg ~= "" and (msg .. "   ·   ") or "") .. (state.badge or ""))

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
    state.press_midi, state.key_off_note = nil, nil
    Kit.PlayClose()   -- rien de tenu, et l'apercu quitte la piste du kit
    DragBus.Unregister(BUS_ID)
    persistConfig()
    Audition.Destroy()
    if Peaks then Peaks.Destroy() end
end)

r.atexit(function()
    r.TrackCtl_SetToolTip("", 0, 0, true)
    pcall(DragBus.Unregister, BUS_ID)
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
