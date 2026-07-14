-- @description CP ChordLab — application glue: state, selection watcher, frame loop
-- @author Cedric Pamalio

-- App owns the single state table (ARCHITECTURE.md § App.lua). UI_* modules are
-- stateless renderers: each exposes Draw(state, deps, theme) where `deps` is the
-- shared wiring table { Theory, Voicing, Fretboard, Suggest, MidiIO, Preview, UI }.
-- App.Init wires everything, App.Frame is the UI.Run callback, App.Shutdown the
-- OnClose handler.
--
-- Heavy work (Analyze / Suggest.For) is event-driven only: the watcher runs at
-- ~4 Hz and re-analyzes on target/hash change; every MIDI write re-analyzes
-- synchronously (the user must see the result immediately). Preview.Update runs
-- every frame. Nothing allocates in the draw path that can be avoided.

local M = {}

-- Wired dependencies (set in Init).
local UI
local Theory, Voicing, Fretboard, Suggest, MidiIO, Preview
local UI_Timeline, UI_Fretboard, UI_Suggestions

-- The single state table.
local state

-- Watcher gate: re-check target at ~4 Hz, not every frame.
local WATCH_INTERVAL = 0.25
local last_watch = 0.0

-- Reusable deps table handed to every UI module (no per-frame alloc).
local deps = {}

-- ---------------------------------------------------------------------------
-- Config defaults (merged under any loaded config at startup).
-- ---------------------------------------------------------------------------
local function default_cfg()
    return {
        mode = "onset",       -- "onset" | "grid"
        onset_ms = 80,
        grid_qn = 4.0,
        place_len_qn = 4.0,
        strum_ms = 18,
        prev_dur_ms = 900,
        vel = 96,
        tuning = 1,
        capo = 0,
        flats = false,
        auto_preview = true,  -- auto-audition on fingering change
        -- Persisted CollapsingHeader open state, keyed by suggestion category.
        cat_open = {
            diatonic = true, ["function"] = true, subs = true,
            borrowed = false, negative = false, passing = false, exotic = false,
        },
    }
end

-- Deep-ish merge: fill any missing key in `dst` from `src` (one level for the
-- nested cat_open table). Loaded config wins over defaults for present keys.
local function merge_defaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = v
        elseif type(v) == "table" and type(dst[k]) == "table" then
            for kk, vv in pairs(v) do
                if dst[k][kk] == nil then dst[k][kk] = vv end
            end
        end
    end
    return dst
end

-- ---------------------------------------------------------------------------
-- Init / Shutdown
-- ---------------------------------------------------------------------------

-- deps_in = { UI, Theory, Voicing, Fretboard, Suggest, MidiIO, Preview,
--             UI_Timeline, UI_Fretboard, UI_Suggestions }
function M.Init(deps_in)
    UI        = deps_in.UI
    Theory    = deps_in.Theory
    Voicing   = deps_in.Voicing
    Fretboard = deps_in.Fretboard
    Suggest   = deps_in.Suggest
    MidiIO    = deps_in.MidiIO
    Preview   = deps_in.Preview
    UI_Timeline    = deps_in.UI_Timeline
    UI_Fretboard   = deps_in.UI_Fretboard
    UI_Suggestions = deps_in.UI_Suggestions

    -- Load persisted config over defaults.
    local cfg = default_cfg()
    local loaded = UI.LoadConfig("CP_ChordLab")
    if loaded and loaded.cfg then
        merge_defaults(loaded.cfg, cfg)
        cfg = loaded.cfg
    end

    state = {
        take = nil, item = nil, hash = "",
        analysis = nil,
        selected_seg = nil,
        armed = nil,               -- { chord, pitches, source="fret"|"suggest" }
        key_override = nil,        -- Key | nil (nil → analysis.key)
        fret = Fretboard.New(cfg.tuning or 1),
        suggestions = nil,
        cfg = cfg,
        -- UI-only transient flags.
        settings_open = false,
        status = "",               -- contextual hint line
        _dirty_suggest = false,    -- request suggestion recompute next check
    }
    state.fret.capo = cfg.capo or 0
    -- Seed the fret readings cache so the draw path never scores on frame 1.
    M.RefreshFretReadings()

    -- Shared deps table for the UI modules (reused every frame).
    deps.UI = UI
    deps.Theory = Theory
    deps.Voicing = Voicing
    deps.Fretboard = Fretboard
    deps.Suggest = Suggest
    deps.MidiIO = MidiIO
    deps.Preview = Preview
    deps.App = M
end

function M.Shutdown()
    Preview.StopAll()
    UI.SaveConfig("CP_ChordLab", { cfg = state.cfg })
end

-- ---------------------------------------------------------------------------
-- Accessors used by the UI modules
-- ---------------------------------------------------------------------------

function M.State() return state end

-- Effective key: override wins, else analysis key, else C major.
function M.CurrentKey()
    if state.key_override then return state.key_override end
    if state.analysis and state.analysis.key then return state.analysis.key end
    return { tonic = 0, mode = "major" }
end

function M.SelectedSegment()
    if not state.analysis or not state.selected_seg then return nil end
    return state.analysis.segments[state.selected_seg]
end

-- ---------------------------------------------------------------------------
-- Analysis / suggestions (event-driven — never called from the draw path)
-- ---------------------------------------------------------------------------

-- Cache each segment's display name + roman numeral so the timeline draw loop
-- (which runs every frame, at full rate during playback) never allocates a
-- chord-name string or a scale table per block. Invalidated whenever the
-- effective key or the flats spelling changes — see M.RefreshSegmentLabels.
local function decorate_segments()
    local segs = state.analysis and state.analysis.segments
    if not segs then return end
    local key = M.CurrentKey()
    local flats = state.cfg.flats
    for i = 1, #segs do
        local seg = segs[i]
        if seg.chord then
            seg.display_name = Theory.ChordName(seg.chord, flats)
            seg.roman = Theory.RomanNumeral(seg.chord, key)
        else
            seg.display_name = nil
            seg.roman = nil
        end
    end
end

-- Public: re-decorate labels without re-analyzing (cheap — no MIDI read). Call
-- when the key override or flats setting changes.
function M.RefreshSegmentLabels()
    decorate_segments()
end

-- opts table reused to avoid alloc.
local analyze_opts = {}

local function analyze_now()
    if not state.take then
        state.analysis = nil
        state.selected_seg = nil
        state.suggestions = nil
        return
    end
    analyze_opts.mode = state.cfg.mode
    analyze_opts.onset_ms = state.cfg.onset_ms
    analyze_opts.grid_qn = state.cfg.grid_qn
    analyze_opts.flats = state.cfg.flats
    state.analysis = MidiIO.Analyze(state.take, analyze_opts)
    state.hash = state.analysis and state.analysis.hash or ""
    -- Clamp / drop selection.
    local segs = state.analysis and state.analysis.segments
    if not segs or #segs == 0 then
        state.selected_seg = nil
    elseif state.selected_seg and state.selected_seg > #segs then
        state.selected_seg = #segs
    end
    decorate_segments()
    M.RecomputeSuggestions()
end

-- Public: synchronous re-analyze after any MIDI write, storing the new hash so
-- the gated watcher does not re-trigger on our own edit.
function M.ReanalyzeAfterWrite()
    analyze_now()
end

-- ctx scratch reused for Suggest.For.
local suggest_ctx = {}

-- Build suggestion context from the selected segment (prev/next neighbors) or,
-- when nothing is selected, from the armed fretboard chord.
function M.RecomputeSuggestions()
    local key = M.CurrentKey()
    local chord, prev_chord, next_chord = nil, nil, nil
    local segs = state.analysis and state.analysis.segments

    if state.selected_seg and segs then
        local i = state.selected_seg
        local seg = segs[i]
        chord = seg and seg.chord or nil
        local p = segs[i - 1]
        local n = segs[i + 1]
        prev_chord = p and p.chord or nil
        next_chord = n and n.chord or nil
    elseif state.armed and state.armed.chord then
        chord = state.armed.chord
    end

    if not chord and not key then
        state.suggestions = nil
        return
    end
    suggest_ctx.chord = chord
    suggest_ctx.key = key
    suggest_ctx.prev = prev_chord
    suggest_ctx.next = next_chord
    suggest_ctx.flats = state.cfg.flats
    state.suggestions = Suggest.For(suggest_ctx)
end

-- ---------------------------------------------------------------------------
-- Watcher — cheap every frame, heavy only on change
-- ---------------------------------------------------------------------------

local function target_changed()
    local take, item = MidiIO.GetTarget()
    -- Pointer identity: validate before comparing so a deleted item re-fetches.
    local same_item = item ~= nil and item == state.item
        and reaper.ValidatePtr(item, "MediaItem*")
    if not same_item then
        return true, take, item
    end
    -- Same item pointer: hash decides (content edited externally).
    local h = take and MidiIO.Hash(take) or ""
    if h ~= state.hash then
        return true, take, item
    end
    return false, take, item
end

-- force = true bypasses the time gate (Refresh button).
function M.Watch(force)
    local now = reaper.time_precise()
    if not force and (now - last_watch) < WATCH_INTERVAL then return end
    last_watch = now

    local changed, take, item = target_changed()
    if changed then
        state.take = take
        state.item = item
        analyze_now()
    elseif state._dirty_suggest then
        state._dirty_suggest = false
        M.RecomputeSuggestions()
    end
end

-- Selection changed inside the UI (segment click): recompute suggestions on the
-- next watcher tick (cheap, avoids doing it mid-draw). Selection itself is set
-- by the caller; here we just flag.
function M.SelectSegment(i)
    state.selected_seg = i
    M.RecomputeSuggestions()
end

-- ---------------------------------------------------------------------------
-- Arming (preview + remember a chord for placement)
-- ---------------------------------------------------------------------------

local spell_opts = { register = 48 }

-- Arm a chord from a source and audition it. `pitches` may be provided (e.g.
-- fretboard sounding pitches); otherwise it is spelled at register 48.
function M.ArmChord(chord, source, pitches)
    if not chord and not pitches then return end
    local p = pitches
    if not p and chord then
        p = Voicing.Spell(chord, spell_opts)
    end
    state.armed = state.armed or {}
    state.armed.chord = chord
    state.armed.pitches = p
    state.armed.source = source
    M.PreviewPitches(p)
    -- Arming from the fretboard changes suggestion context when no segment is
    -- selected — flag a recompute.
    if not state.selected_seg then state._dirty_suggest = true end
end

local preview_opts = {}
function M.PreviewPitches(pitches)
    if not pitches or #pitches == 0 then return end
    preview_opts.strum_ms = state.cfg.strum_ms
    preview_opts.dur_ms = state.cfg.prev_dur_ms
    preview_opts.vel = state.cfg.vel
    preview_opts.dir = "up"
    Preview.Play(pitches, preview_opts)
end

-- ---------------------------------------------------------------------------
-- MIDI write actions (each: single undo block via MidiIO, then re-Analyze)
-- ---------------------------------------------------------------------------

-- Replace the chord under the selected segment (rhythm-preserving).
-- A segment can be non-empty (a held note sounds through it) yet own no onset
-- notes of its own — there is nothing to re-pitch there, so we tell the user
-- instead of silently no-op'ing.
function M.ReplaceSelected(chord)
    local seg = M.SelectedSegment()
    if not seg or not state.take or seg.empty then return end
    if not seg.notes or #seg.notes == 0 then
        state.status = "Segment sans note propre (note tenue) — rien à remplacer ici."
        return
    end
    MidiIO.ReplaceSegment(state.take, seg, chord)
    M.ReanalyzeAfterWrite()
    state.status = ""
end

-- Place a chord into an empty slot using voice-leading from the previous
-- segment's sounding pitches.
function M.PlaceInSlot(slot_index, chord)
    local segs = state.analysis and state.analysis.segments
    if not segs or not chord or not state.take then return end
    local slot = segs[slot_index]
    if not slot or not slot.empty then return end

    -- Previous sounding pitches for voice leading.
    local prev
    for i = slot_index - 1, 1, -1 do
        local s = segs[i]
        if s and not s.empty and s.pitches and #s.pitches > 0 then
            prev = s.pitches
            break
        end
    end
    local pitches = Voicing.LeadFrom(prev, chord, spell_opts)
    MidiIO.WriteChord(state.take, slot.start_ppq, slot.end_ppq, pitches, state.cfg.vel)
    M.ReanalyzeAfterWrite()
end

-- Delete the notes of the selected segment.
function M.DeleteSelected()
    local seg = M.SelectedSegment()
    if not seg or not state.take or seg.empty then return end
    if not seg.notes or #seg.notes == 0 then
        state.status = "Segment sans note propre (note tenue) — rien à supprimer ici."
        return
    end
    MidiIO.DeleteSegment(state.take, seg)
    M.ReanalyzeAfterWrite()
end

-- Write a chord at the edit cursor into (creating if needed) the target item.
function M.WriteAtCursor(chord, pitches)
    if not chord and not pitches then return end
    local take, item = MidiIO.EnsureItem(state.cfg.place_len_qn)
    if not take then return end
    local p = pitches or Voicing.Spell(chord, spell_opts)
    -- Span place_len_qn quarter notes from the edit cursor, mapped through the
    -- project tempo map so the block honors tempo changes.
    local cur = reaper.GetCursorPositionEx(0)
    local end_qn = reaper.TimeMap2_timeToQN(0, cur) + state.cfg.place_len_qn
    local end_time = reaper.TimeMap2_QNToTime(0, end_qn)
    local start_ppq = MidiIO.TimeToPpq(take, cur)
    local end_ppq = MidiIO.TimeToPpq(take, end_time)
    MidiIO.WriteChord(take, start_ppq, end_ppq, p, state.cfg.vel)
    -- The written take becomes the target (EnsureItem may have created it) so
    -- the watcher tracks it and does not re-fetch a different selection.
    state.take = take
    state.item = item
    M.ReanalyzeAfterWrite()
end

-- ---------------------------------------------------------------------------
-- Fretboard integration
-- ---------------------------------------------------------------------------

-- Recompute the fretboard readings (sounding pitches + detection candidates)
-- and cache them on state. Detection is expensive (full scorer) and only
-- changes when the fingering / tuning / flats setting changes — never per
-- frame — so it MUST be event-driven. All fret mutators call this; the draw
-- path reads the cache via M.FretReadings().
local fret_detect_opts = {}
function M.RefreshFretReadings()
    local pitches = Fretboard.Pitches(state.fret)
    fret_detect_opts.flats = state.cfg.flats
    local cands = (#pitches > 0) and Theory.Detect(pitches, fret_detect_opts) or nil
    state.fret_readings = { cands = cands, pitches = pitches }
    return cands, pitches
end

-- Called by UI_Fretboard after any finger change: refresh readings, arm the
-- detected chord and (if enabled) auto-preview. Detection is done here so the
-- pure UI stays dumb and the draw path never scores a chord.
function M.OnFretChanged()
    local cands, pitches = M.RefreshFretReadings()
    local chord = cands and cands[1] and cands[1].chord or nil
    state.armed = state.armed or {}
    state.armed.chord = chord
    state.armed.pitches = pitches
    state.armed.source = "fret"
    if state.cfg.auto_preview then
        M.PreviewPitches(pitches)
    end
    if not state.selected_seg then state._dirty_suggest = true end
end

-- Current fretboard readings (top candidates) for the fretboard panel — reads
-- the cache populated by RefreshFretReadings. Returns cands, pitches.
function M.FretReadings()
    local fr = state.fret_readings
    if not fr then return M.RefreshFretReadings() end  -- lazy seed safety net
    return fr.cands, fr.pitches
end

-- ---------------------------------------------------------------------------
-- Settings changes that must persist immediately (SaveConfig, not on hot path)
-- ---------------------------------------------------------------------------

-- Called after any settings-modal edit that changes analysis parameters.
function M.ApplyAnalysisSettings()
    -- Re-analyze with the new mode/resolution and persist config.
    analyze_now()
    UI.SaveConfig("CP_ChordLab", { cfg = state.cfg })
end

-- Called after tuning / capo change from the fretboard controls.
function M.ApplyTuning(tuning_index)
    state.cfg.tuning = tuning_index
    state.fret = Fretboard.New(tuning_index)
    state.fret.capo = state.cfg.capo or 0
    state.armed = nil
    M.RefreshFretReadings()
    UI.SaveConfig("CP_ChordLab", { cfg = state.cfg })
end

function M.SaveCfg()
    UI.SaveConfig("CP_ChordLab", { cfg = state.cfg })
end

-- ---------------------------------------------------------------------------
-- Frame (UI.Run callback)
-- ---------------------------------------------------------------------------

local COLS = { 0.62, 0.38 }

function M.Frame(theme)
    -- Preview scheduler every frame; watcher gated to ~4 Hz.
    Preview.Update()
    M.Watch(false)

    -- ------- Top bar -------
    M.DrawTopBar(theme)

    UI.Spacing(theme.gap)

    -- ------- Timeline strip (full-width, horizontal scroll) -------
    UI_Timeline.Draw(state, deps, theme)

    UI.Spacing(theme.gap)
    UI.Separator()
    UI.Spacing(theme.gap)

    -- ------- Main row: fretboard | suggestions -------
    UI.BeginColumns("cl_main_cols", COLS)
        UI_Fretboard.Draw(state, deps, theme)
    UI.NextColumn()
        UI_Suggestions.Draw(state, deps, theme)
    UI.EndColumns()

    -- ------- Status bar -------
    UI.Spacing(theme.gap)
    UI.Separator()
    UI.SetFontCaption()
    local hint = state.status
    if not hint or hint == "" then hint = M.DefaultHint() end
    UI.Text(hint, { disabled = true })
    UI.SetFontBody()

    -- ------- Settings modal -------
    if state.settings_open then
        M.DrawSettingsModal(theme)
    end
end

-- Contextual default hint when nothing more specific is set.
function M.DefaultHint()
    if not state.take then
        return "Selectionnez un item MIDI pour analyser ses accords."
    end
    if state.armed and state.armed.chord then
        local nm = Theory.ChordName(state.armed.chord, state.cfg.flats)
        return "Accord arme : " .. nm ..
            " — cliquez un emplacement vide pour le placer, ou double-cliquez une suggestion pour remplacer."
    end
    if state.selected_seg then
        return "Segment selectionne — Suppr pour effacer, double-clic sur une suggestion pour remplacer."
    end
    return "Cliquez un accord de la timeline, ou construisez-en un sur le manche."
end

-- ---------------------------------------------------------------------------
-- Top bar
-- ---------------------------------------------------------------------------

-- Static option arrays (built once, never reallocated per frame).
local MODE_ITEMS = { "Onsets", "Grille" }
local MODE_KEYS = { "onset", "grid" }
local GRID_ITEMS = { "1", "2", "4", "8" }
local GRID_VALS = { 1.0, 2.0, 4.0, 8.0 }
local ONSET_ITEMS = { "40 ms", "60 ms", "80 ms", "120 ms", "200 ms" }
local ONSET_VALS = { 40, 60, 80, 120, 200 }
local PLACE_ITEMS = { "1", "2", "4", "8" }
local PLACE_VALS = { 1.0, 2.0, 4.0, 8.0 }

-- Key combo: "Auto (X)" + 24 tonic/mode entries. Built once.
local KEY_ITEMS = nil
local function build_key_items()
    if KEY_ITEMS then return KEY_ITEMS end
    KEY_ITEMS = { "" }  -- index 1 = Auto, filled per-frame with detected key
    for mode_i = 1, 2 do
        local suffix = mode_i == 1 and " maj" or " min"
        for pc = 0, 11 do
            KEY_ITEMS[#KEY_ITEMS + 1] = Theory.PcName(pc, false) .. suffix
        end
    end
    return KEY_ITEMS
end

-- Map (mode_i, pc) → combo index (2..25).
local function key_to_index(key)
    if not key then return 1 end
    local base = key.mode == "minor" and (1 + 12) or 1
    return base + (key.tonic % 12) + 1
end

local function index_to_key(idx)
    if idx <= 1 then return nil end  -- Auto
    local n = idx - 2               -- 0..23
    local mode = n < 12 and "major" or "minor"
    local pc = n % 12
    return { tonic = pc, mode = mode }
end

local function find_index(vals, v)
    for i = 1, #vals do
        if vals[i] == v then return i end
    end
    return 1
end

function M.DrawTopBar(theme)
    local S = UI.Theme.S
    local cfg = state.cfg

    -- Item name.
    UI.SetFontH2Bold()
    local name = "—"
    if state.item then
        local take = state.take
        if take then
            local ok, tn = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
            if ok and tn and tn ~= "" then name = tn end
        end
    end
    UI.Text(name)
    UI.SetFontBody()
    UI.SameLine(theme.gap_large)

    -- Key combo.
    local items = build_key_items()
    local ak = M.CurrentKey()
    items[1] = "Auto (" .. Theory.PcName(ak.tonic, cfg.flats) ..
        (ak.mode == "minor" and " min" or " maj") .. ")"
    local kidx = state.key_override and key_to_index(state.key_override) or 1
    local kchg, knew = UI.Combo("cl_key", "", kidx, items, { width = S(theme, 120) })
    if kchg then
        state.key_override = index_to_key(knew)
        M.RefreshSegmentLabels()   -- roman numerals depend on the effective key
        M.RecomputeSuggestions()
    end
    UI.SameLine(theme.gap)

    -- Mode combo (onset / grid).
    local midx = cfg.mode == "grid" and 2 or 1
    local mchg, mnew = UI.Combo("cl_mode", "", midx, MODE_ITEMS, { width = S(theme, 90) })
    if mchg then
        cfg.mode = MODE_KEYS[mnew]
        M.ApplyAnalysisSettings()
    end
    UI.SameLine(theme.gap)

    -- Grid res OR onset window depending on mode.
    if cfg.mode == "grid" then
        local gi = find_index(GRID_VALS, cfg.grid_qn)
        local gchg, gnew = UI.Combo("cl_grid", "", gi, GRID_ITEMS, { width = S(theme, 60) })
        if gchg then
            cfg.grid_qn = GRID_VALS[gnew]
            M.ApplyAnalysisSettings()
        end
    else
        local oi = find_index(ONSET_VALS, cfg.onset_ms)
        local ochg, onew = UI.Combo("cl_onset", "", oi, ONSET_ITEMS, { width = S(theme, 80) })
        if ochg then
            cfg.onset_ms = ONSET_VALS[onew]
            M.ApplyAnalysisSettings()
        end
    end
    UI.SameLine(theme.gap)

    -- Place-length combo.
    local pi = find_index(PLACE_VALS, cfg.place_len_qn)
    local pchg, pnew = UI.Combo("cl_place", "", pi, PLACE_ITEMS, { width = S(theme, 60) })
    if pchg then
        cfg.place_len_qn = PLACE_VALS[pnew]
        M.SaveCfg()
    end
    UI.SameLine(theme.gap)

    -- Refresh button (forces a watcher pass immediately).
    if UI.Button("cl_refresh", "Rafraichir") then
        M.Watch(true)
    end
    UI.SameLine(theme.gap)

    -- Settings button (modal).
    if UI.Button("cl_settings", "Reglages") then
        state.settings_open = true
    end
end

-- ---------------------------------------------------------------------------
-- Settings modal
-- ---------------------------------------------------------------------------

function M.DrawSettingsModal(theme)
    local S = UI.Theme.S
    local cfg = state.cfg
    UI.BeginModal("cl_settings_modal", "Reglages CP ChordLab",
        { width = S(theme, 340), height = S(theme, 300) })

    local dirty_analysis = false

    -- Preview strum / duration / velocity.
    local c1, v1 = UI.SliderInt("cl_set_strum", "Strum (ms)", cfg.strum_ms, 0, 60)
    if c1 then cfg.strum_ms = v1 end
    local c2, v2 = UI.SliderInt("cl_set_dur", "Duree preview (ms)", cfg.prev_dur_ms, 200, 2000)
    if c2 then cfg.prev_dur_ms = v2 end
    local c3, v3 = UI.SliderInt("cl_set_vel", "Velocite", cfg.vel, 1, 127)
    if c3 then cfg.vel = v3 end

    UI.Separator()

    -- Auto-preview toggle.
    local c4, v4 = UI.Checkbox("cl_set_autoprev", "Preview auto au changement de doigte", cfg.auto_preview)
    if c4 then cfg.auto_preview = v4 end

    -- Flats vs sharps naming.
    local c5, v5 = UI.Checkbox("cl_set_flats", "Noter en bemols", cfg.flats)
    if c5 then cfg.flats = v5 dirty_analysis = true end

    UI.Separator()

    -- Capo (affects fretboard model — clamp handled in fretboard).
    local c6, v6 = UI.SliderInt("cl_set_capo", "Capo", cfg.capo, 0, 12)
    if c6 then
        cfg.capo = v6
        state.fret.capo = v6
        M.RefreshFretReadings()  -- capo changes sounding pitches → refresh cache
    end

    UI.Spacing(theme.gap_large)

    if UI.Button("cl_set_close", "Fermer") then
        state.settings_open = false
        if dirty_analysis then
            M.ApplyAnalysisSettings()
        else
            M.SaveCfg()
        end
    end

    UI.EndModal()
end

return M
