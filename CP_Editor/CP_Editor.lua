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
local cp_root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
local UI = dofile(cp_root .. "CP_Toolkit/CP_Toolkit.lua")

local Peaks = dofile(cp_root .. "CP_Engine/Peaks.lua")
local Ops   = dofile(cp_root .. "CP_Engine/Ops.lua")
local Roll  = dofile(cp_root .. "CP_Engine/Roll.lua")
local RollUI = dofile(cp_root .. "CP_Engine/RollUI.lua")
local Rows  = dofile(cp_root .. "CP_Engine/Rows.lua")
-- LES LIAISONS SONT DES DONNEES. Ce module ne dessine rien et n'appelle rien :
-- il repond « quelle ACTION pour ce geste », et c'est tout ce qui separe un
-- raccourci fige d'un raccourci qu'on peut changer.
local Keymap = dofile(cp_root .. "CP_Engine/Keymap.lua")
-- LE PANNEAU DE RACCOURCIS EST UN MODULE, pas une autre fenetre. On regle les
-- raccourcis de l'outil qu'on a sous la main : aller chercher un script dans la
-- liste des actions pour regler CELUI-CI est un detour que personne ne fait
-- deux fois.
local KeymapUI = dofile(cp_root .. "CP_Engine/KeymapUI.lua")
local Kit   = dofile(cp_root .. "CP_Engine/Kit.lua")
local Tracks = dofile(cp_root .. "CP_Engine/Tracks.lua")
-- L'AUDITION PARTAGEE (feuille de route phase 3). Le meme geste etait
-- ecrit trois fois dans la suite ; c'est un seul module maintenant, et il
-- choisit par CAPACITE — une voix du moteur quand elle suffit, CF_Preview
-- pour ce qu'elle ne sait pas faire (transposer, lire un long fichier
-- depuis le disque, jouer une PCM_source qu'on lui tend sans fichier).
local Audition = dofile(cp_root .. "CP_Engine/Audition.lua")
local Insert = dofile(cp_root .. "CP_Engine/Insert.lua")
local DragBus = dofile(cp_root .. "CP_Toolkit/DragBus.lua")
local Clip  = dofile(cp_root .. "CP_Engine/Clip.lua")
local Ident = dofile(cp_root .. "CP_Engine/Ident.lua")
local Bus   = dofile(cp_root .. "CP_Engine/Bus.lua")
local Loop  = dofile(cp_root .. "CP_Engine/Loop.lua")
-- JOUER UNE NOTE DANS LA PISTE QUE CE CLIP ALIMENTE, et nulle part ailleurs.
-- Cet editeur auditionnait par le bus du kit de CP_Sampler, ce qui voulait dire
-- deux choses fausses a la fois : il fallait un kit pour s'entendre, et la note
-- partait en broadcast vers toute piste armee. Un piano roll ouvert sur une
-- case de session doit sonner comme cette case sonne — donc par SA piste.
local Voice = dofile(cp_root .. "CP_Engine/Voice.lua")
local Notes = dofile(cp_root .. "CP_Engine/Notes.lua")

Peaks.init(r)
Ops.init(r, Peaks)
Roll.init(r)
Tracks.init(r)
Kit.init(r, Tracks)
Audition.init(r)
Keymap.init(r, UI.Core, UI.Keys)
KeymapUI.init(r, UI.Core, Keymap)
Insert.init(r)
DragBus.init(r)
Ident.init(r, Clip)
Bus.init(r, DragBus, Clip)
Voice.init(r)
Notes.init(r, Voice, Voice.PLAY_PORT_EDITOR)

-- Loop (the live-lane link for clips born in the Looper/Session) is armed
-- LAZILY, on the first clip that names a lane: its init re-scans the
-- project and re-syncs the router's sends, and an editor opened on an
-- audio item has no business touching that.
local loop_ready = false
local function loopInit()
    if loop_ready then return end
    loop_ready = true
    Loop.init(r, Tracks)
    -- an engine older than this build silently drops commands aimed at the
    -- lanes it does not scan; refresh it rather than misbehave. Never
    -- CREATES one — an editor must not conjure tracks into a project.
    Loop.Ensure(false)
end

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
    note_names = cfg.note_names == true,  -- draw note names inside notes
    -- Hear a note as you write or drag it. On by default: writing blind is
    -- the exception, not the rule. Off matters when the instrument is loud,
    -- when you are working against a running loop, or when the audition
    -- reaches an instrument you did not mean (see the input-monitor note).
    audition   = cfg.audition ~= false,
    -- OU SORT L'ECOUTE : "hw" la carte son, "master" le master du projet,
    -- "item" la piste de l'item. Sans piste, une voix CP sort DIRECTEMENT sur
    -- la carte : c'est le bon defaut d'un navigateur — on entend le fichier tel
    -- qu'il est — et c'est deroutant quand on prepare un son pour le morceau,
    -- parce que le son ne passe alors ni par le master ni par rien.
    -- `thru_track` etait la meme question posee en oui/non, et seulement pour
    -- un item ; il se relit pour ne pas perdre le reglage de l'utilisateur.
    out_mode   = cfg.out_mode or ((cfg.thru_track ~= false) and "item" or "master"),
    -- Loop the preview over the played region (the selection, or the whole
    -- region when there is none). Off by default: an audition that will not
    -- stop is a surprise, a loop you asked for is a tool.
    loop       = cfg.loop == true,
    -- Snap the audio selection and the edit cursor to the same grid the roll
    -- uses. On by default: a sample being cut into a loop wants beats far more
    -- often than it wants samples, and the toggle is one click away.
    wave_snap  = cfg.wave_snap ~= false,
    -- Transients are snap targets too, when there are any. On by default:
    -- detecting them and then not being able to land on them would be an odd
    -- thing to ask for. The grid still wins unless one is genuinely nearer.
    snap_trans = cfg.snap_trans ~= false,
    -- What a time selection means to playback when the loop is off. On by
    -- default: a range you drew is a range you meant, and hearing the sound
    -- walk straight through it reads as the editor ignoring you.
    stop_at_sel = cfg.stop_at_sel ~= false,
    -- CLIQUER DANS LA REGLE D'UNE CASE QUI JOUE LA FAIT REPARTIR DE LA. C'est
    -- le geste qu'on cherche spontanement — « je clique dans le header en
    -- pensant pouvoir lire a partir de la » — et c'est le scrub d'Ableton.
    -- Actif par defaut : une regle sur laquelle on clique sans que rien ne se
    -- passe est ce qu'on avait, et c'etait le defaut signale.
    ruler_scrub = cfg.ruler_scrub ~= false,
}
Audition.volume = cfg.vol or 1.0

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
    marquee = nil,       -- right-drag box {x,y,cx,cy}
    ruler_drag = nil,    -- top-strip drag {t0} for time-selection
    -- LE CURSEUR ET LA SELECTION D'UNE CASE, en beats de la case.
    --
    -- On a longtemps ecrit qu'une case « n'a ni curseur d'edition ni selection
    -- temporelle, ce sont des concepts du PROJET ». C'etait vrai du curseur DU
    -- PROJET, et faux de celui de la CASE — qui n'est que de l'etat de fenetre,
    -- ne coute rien, et manquait a tout ce qui prend une plage : coller ici,
    -- quantifier ceci, selectionner ce qui est dedans. La regle etait donc
    -- inerte en mode case, et on cliquait dedans sans que rien ne se passe.
    clip_cur = 0,
    clip_sel_a = nil, clip_sel_b = nil,
    row_hi = nil,        -- pitch of the highlighted (selected) row
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
    cfg.vol       = Audition.volume
    cfg.midi_snap = opts.midi_snap
    cfg.last_vel  = state.last_vel
    cfg.grid_div  = opts.grid_div
    cfg.note_names = opts.note_names
    cfg.audition   = opts.audition
    cfg.out_mode   = opts.out_mode
    cfg.loop       = opts.loop
    cfg.wave_snap  = opts.wave_snap
    cfg.snap_trans = opts.snap_trans
    cfg.stop_at_sel = opts.stop_at_sel
    cfg.ruler_scrub = opts.ruler_scrub
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

-- ONE grid for the whole editor: the piano roll and the waveform snap to the
-- same division, and it is the project's own until you say otherwise.
-- Whole notes → quarter notes, because every snap below works in QN.
local function gridStepQN()
    local division = opts.grid_div
    if not division then
        local _, d = r.GetSetProjectGrid(0, false)
        division = d
    end
    if not division or division <= 0 then division = 0.25 end
    return division * 4
end

-- ---------------------------------------------------------------------------
-- Waveform snap
--
-- The waveform is drawn in the SOURCE domain and the grid is musical, so the
-- round trip is source → project → QN → back. Going through REAPER's TimeMap
-- rather than doing the arithmetic ourselves means a tempo MAP is honoured
-- instead of assumed away.
--
-- An item is anchored by its own position on the timeline. A bare file has no
-- position at all, so it is read as if it started at the project's zero —
-- which is exactly what makes a loop's beats land on the grid.
-- ---------------------------------------------------------------------------
local function srcToProj(t)
    if state.mode == "item" and state.item and state.take then
        local soffs = r.GetMediaItemTakeInfo_Value(state.take, "D_STARTOFFS")
        local rate  = r.GetMediaItemTakeInfo_Value(state.take, "D_PLAYRATE")
        if rate <= 0 then rate = 1 end
        local pos = r.GetMediaItemInfo_Value(state.item, "D_POSITION")
        return pos + (t - soffs) / rate, rate, pos, soffs
    end
    return t, 1, 0, 0
end

local function projToSrc(pt, rate, pos, soffs)
    return soffs + (pt - pos) * rate
end

-- Snap targets: the grid always, and the TRANSIENTS when there are any.
--
-- The grid has no distance limit (it is everywhere, so the nearest line is the
-- answer); a transient only wins when it is BOTH nearer and within a few
-- pixels — otherwise a marker on the far side of the view would yank the
-- cursor across the screen because nothing else was closer.
local SNAP_PX = 12

-- SHIFT bypasses the snap. That is REAPER's rule everywhere, so it is this
-- editor's rule everywhere too: dragging a selection edge, a transient, the
-- ruler, or dropping a new marker — hold shift and you land where you point.
local function waveSnap(t)
    if not opts.wave_snap or Core_tk.ModShift() then return t end
    local pt, rate, pos, soffs = srcToProj(t)
    local step = gridStepQN()
    local qn = math.floor(r.TimeMap2_timeToQN(0, pt) / step + 0.5) * step
    local best = projToSrc(r.TimeMap2_QNToTime(0, qn), rate, pos, soffs)
    if best < 0 then best = 0 end
    local bd = math.abs(best - t)

    local m = state.markers
    if opts.snap_trans and #m > 0 and wave.w > 0 then
        local tol = SNAP_PX * span() / wave.w
        for i = 1, #m do
            local d = m[i] - t
            if d < 0 then d = -d end
            if d < bd and d <= tol then best, bd = m[i], d end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Transient markers, as OBJECTS
--
-- Detection puts them there; from then on they are yours. The array stays
-- sorted — the snap search, the split and the slice export all read it in
-- order — so an insert finds its place and a drag is CLAMPED between its
-- neighbours instead of being re-sorted behind your back.
-- ---------------------------------------------------------------------------
local MARK_MIN = 0.0005      -- closer than this and it is the same marker

local function markerAdd(t)
    if not state.src then return false end
    if t < 0 then t = 0 elseif t > state.len then t = state.len end
    local m = state.markers
    local at = #m + 1
    for i = 1, #m do
        local d = m[i] - t
        if d < 0 then d = -d end
        if d < MARK_MIN then return false end
        if m[i] > t then at = i break end
    end
    table.insert(m, at, t)
    return true
end

-- Index of the marker within `tol` of t, nearest first.
local function markerAt(t, tol)
    local m, best, bd = state.markers, nil, nil
    for i = 1, #m do
        local d = m[i] - t
        if d < 0 then d = -d end
        if d <= tol and (not bd or d < bd) then best, bd = i, d end
    end
    return best
end

local function markerMove(i, t)
    local m = state.markers
    if not m[i] then return end
    local lo = (i > 1) and (m[i - 1] + MARK_MIN) or 0
    local hi = (i < #m) and (m[i + 1] - MARK_MIN) or state.len
    if t < lo then t = lo elseif t > hi then t = hi end
    m[i] = t
end

-- The grid choices, as a combo's two parallel arrays with entry 1 meaning
-- "follow the project". Built once at load — a combo needs a plain list of
-- strings, and rebuilding one per frame would allocate for nothing. Up here
-- with the grid itself, because BOTH bars offer them now.
local GRID_CHOICES = {
    { "1/1", 1 }, { "1/2", 0.5 }, { "1/4", 0.25 }, { "1/8", 0.125 },
    { "1/16", 0.0625 }, { "1/32", 0.03125 }, { "1/64", 0.015625 },
    { "1/8 T", 1 / 12 }, { "1/16 T", 1 / 24 },
}
local GRID_ITEMS, GRID_VALS = { "Grid: project" }, { false }
for i = 1, #GRID_CHOICES do
    GRID_ITEMS[i + 1] = "Grid " .. GRID_CHOICES[i][1]
    GRID_VALS[i + 1]  = GRID_CHOICES[i][2]
end
local GRID_BAR_OPTS = { w = 3 }

-- "Grid 1/16" display label, cached until the division changes (read per
-- frame — no concat in the frame path)
local grid_lbl = { div = -1, s = "" }

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
    -- Back to auto: the rows describe THIS target's instrument, and a manual
    -- "show me drum rows" chosen for a kit clip must not follow you onto the
    -- next clip, which may be a synth.
    state.drum_mode = nil
    -- Le curseur et la selection d'une case appartiennent A CETTE case : les
    -- laisser trainer ferait coller au milieu de la suivante.
    state.clip_cur = 0
    state.clip_sel_a, state.clip_sel_b = nil, nil
    state.sel_a, state.sel_b = nil, nil
    state.cursor = 0
    for i = #state.markers, 1, -1 do state.markers[i] = nil end
    state.meta_line = nil
    state.gen = state.gen + 1
    fitView()
    Audition.Stop()
end

-- Re-read source-dependent fields (item mode: the take source can be
-- swapped under us — reverse wraps it in a section source).
local function refreshItemFields()
    local src = r.GetMediaItemTake_Source(state.take)
    if src ~= state.src then
        -- the preview may be playing the OLD source, which the swap (e.g.
        -- reverse wrapping it in a section) is about to destroy
        Audition.Stop()
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

-- ---------------------------------------------------------------------------
-- Clip focus (take-less MIDI: a Looper lane, a session cell). Roll runs on
-- a backend over the clip's own note arrays — cache unit BEATS — and every
-- committed gesture publishes the clip back over the Bus (editor:apply), so
-- the origin engine hears the edit live.
-- ---------------------------------------------------------------------------
-- Beats per bar for the clip grid, asked of the ENGINE rather than of the
-- edit cursor: a clip has no position in the timeline, so "the meter where
-- the cursor happens to sit" was an arbitrary answer that could disagree with
-- the bar count the lane is actually looping. The cursor stays the fallback
-- for an editor with no engine attached.
-- (state.loop_att is the once-per-frame attach probe; calling IsAttached here
-- would walk the router's FX chain from inside the draw path.)
local function clipTsNum()
    if state.loop_att then
        local n = Loop.TsNum()
        if n and n > 0 then return n end
    end
    local tsn = r.TimeMap_GetTimeSigAtTime(0, r.GetCursorPosition())
    return (tsn and tsn > 0) and tsn or 4
end

-- Debounced publish (one editor:apply per edit gesture, not per drag frame).
local function scheduleApply()
    state.apply_t = r.time_precise() + 0.25
end

local function flushApply()
    if state.apply_t and state.mode == "clip" and state.clip then
        -- Write the live lane DIRECTLY. The Bus message only reaches an app
        -- that happens to be RUNNING (5 s TTL, delete-on-read) — the engine
        -- must hear the edit even with no Looper/Session window open, which
        -- is the whole point of editing session clips from here. The message
        -- still goes out so those apps refresh their own view when they are
        -- up (Loop.ApplyClip is idempotent, applying it twice is harmless).
        if state.clip_lane and Loop.IsAttached() then
            Loop.ApplyClip(state.clip_lane, state.clip)
        end
        -- Addressed by DESTINATION: bus messages are delete-on-read, so a
        -- session cell's edit sent on the shared channel could be eaten by
        -- CP_Looper — the lane would sound right and the stored cell would
        -- silently keep the old notes.
        Bus.Send(state.clip.cell and "editor:apply:cell" or "editor:apply",
                 state.clip)
    end
    state.apply_t = nil
end

-- Direct loop-length control (clip mode): resize the clip and, when a live
-- lane backs it, the engine lane too — the Looper's halve/double gesture.
local function setClipBars(bars)
    local c = state.clip
    if not c then return end
    if bars < 1 then bars = 1 elseif bars > 32 then bars = 32 end
    if bars == (c.bars or 4) then return end
    c.bars = bars
    state.len = bars * clipTsNum()
    if state.clip_lane and Loop.IsAttached() then
        Loop.SetLengthBars(state.clip_lane, bars)
    end
    scheduleApply()   -- other consumers (Session grid) hear the new length
    fitView()         -- the canvas changed size: show the whole loop again
    UI.RequestRedraw()
end

-- Clip transport: the lane's own launch/stop, driven exactly like the
-- Looper's lane button — a queued launch/stop cancels, an overdubbing lane
-- stops, a recording one is left to the Looper. A lane the engine still
-- believes is empty is promoted to "stopped with content" first, so the
-- very first launch of a freshly written clip takes instead of no-oping.
-- La position de l'item dans le projet, ou zero quand la cible n'en est pas
-- un. Remontee ici parce que les accesseurs de curseur en dependent, et qu'ils
-- doivent eux-memes preceder clipLaunch.
local function itemPos()
    if not state.item then return 0 end   -- clip/file mode: no item
    return r.GetMediaItemInfo_Value(state.item, "D_POSITION")
end

-- LE CURSEUR D'EDITION, ET IL Y EN A DEUX SORTES. Un item vit dans la
-- timeline et emprunte donc celui de REAPER ; une case vit hors d'elle et
-- porte le sien. Quatre fonctions le disent une fois, et plus rien en dessous
-- n'a besoin de savoir laquelle des deux il regarde — c'est ce qui permet a la
-- regle d'etre le MEME code dans les deux modes.
local function editCursor()
    if state.mode == "clip" then return state.clip_cur or 0 end
    return r.GetCursorPosition() - itemPos()
end

local function setEditCursor(t)
    if t < 0 then t = 0 end
    if state.mode == "clip" then state.clip_cur = t return end
    r.SetEditCurPos(itemPos() + t, false, false)
end

local function timeSel()
    if state.mode == "clip" then
        local a, b = state.clip_sel_a, state.clip_sel_b
        if a and b and b > a + 1e-6 then return a, b end
        return nil
    end
    local a, b = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if b > a + 0.0001 then
        local pos = itemPos()
        return a - pos, b - pos
    end
    return nil
end

local function setTimeSel(a, b)
    if state.mode == "clip" then
        if not a or not b or b <= a + 1e-6 then
            state.clip_sel_a, state.clip_sel_b = nil, nil
        else
            state.clip_sel_a, state.clip_sel_b = a, b
        end
        return
    end
    local pos = itemPos()
    if not a or not b or b <= a + 0.0001 then
        r.GetSet_LoopTimeRange(true, false, 0, 0, false)
    else
        r.GetSet_LoopTimeRange(true, false, pos + a, pos + b, false)
    end
end

-- LANCER UNE CASE DEPUIS LE CURSEUR.
--
-- Le scrub ne peut deplacer qu'une case QUI SONNE : sur une case a l'arret il
-- n'y a pas de phase a decaler, et poser le decalage maintenant ne voudrait
-- rien dire — le lancement tombera sur une frontiere de quantize, plus tard,
-- ou la phase sera tout autre.
--
-- On note donc l'intention et on l'applique AU MOMENT OU LA CASE PART. Le
-- rendez-vous existe deja : le sondage de lane ci-dessous voit le mode passer a
-- « joue », et c'est la seule frame ou la question a une reponse exacte.
--
-- C'est ce qui fait que le curseur veut dire quelque chose meme quand rien ne
-- joue — sans ca, on le pose, on regarde, et il ne se passe rien.
local function clipLaunch(from)
    -- OU COMMENCE LA LECTURE, sur les trois touches de REAPER. Le mode case n'a
    -- pas de transport a lui : c'est le point de depart de la BOUCLE qu'on
    -- choisit, et il vaut jusqu'au prochain lancement.
    local at
    if from == "start" then at = 0
    elseif from == "sel" then local a = timeSel() at = a or editCursor()
    else at = editCursor() end
    state.clip_launch_from = at
    if not state.clip_track then
        flash("Clip has no live engine (open it from the Looper or Session)")
        return
    end
    if not Loop.IsAttached() then
        flash("Looper engine not found in this project")
        return
    end
    flushApply()   -- the engine must play what is on screen
    local lane = state.clip_lane
    if not lane then
        -- The engine no longer holds this clip. Stage it in the track's
        -- SILENT half — exactly what the Session does — so launching from
        -- here never yanks the clip that is currently playing.
        if Roll.count <= 0 then flash("Empty clip") return end
        lane = Loop.TwinLane(state.clip_track)
        Loop.ApplyClip(lane, state.clip)
        if state.clip.bars and state.clip.bars > 0 then
            Loop.SetLengthBars(lane, state.clip.bars)
        end
        Loop.SetLaneTag(lane, state.clip_tag)
        Loop.SetMode(lane, 2)
        state.clip_lane = lane
        -- the outgoing clip leaves on the same boundary the new one arrives
        local live = Loop.LiveLane(state.clip_track)
        if live ~= lane and (Loop.IsRunning(live) or Loop.Pending(live) == 1) then
            Loop.StopClip(live)
        end
        Loop.ArmPlayFrom(lane, state.clip_launch_from)
        Loop.Play(lane)
        return
    end
    -- The track's other half. A queued swap arms BOTH — one to stop, one to
    -- play, on the same boundary — so anything that cancels or launches here
    -- has to answer for the pair, or the Session grid (which enforces
    -- one clip per track) and what you hear stop agreeing.
    local other = (lane == state.clip_track) and (state.clip_track + Loop.TRACKS)
                   or state.clip_track
    Loop.ArmPlayFrom(lane, state.clip_launch_from)
    local p = Loop.Pending(lane)
    if p == 1 or p == 2 then
        if p == 1 and Loop.Pending(other) == 2 then Loop.Play(other) end
        if p == 2 and Loop.Pending(other) == 1 then Loop.StopClip(other) end
        Loop.ToggleClip(lane)   -- cancels the queued launch / stop
        return
    end
    local m = math.floor(Loop.Mode(lane) + 0.5)
    if m == 1 or m == 4 or p == 3 or p == 4 then
        flash("Lane is recording — stop it in the Looper")
    elseif m == 3 or m == 5 then
        Loop.StopClip(lane)
    else
        if m == 0 then
            if Roll.count <= 0 then flash("Empty clip") return end
            Loop.SetMode(lane, 2)   -- it has content now: launchable
        end
        -- A track plays ONE clip: whatever its other half held leaves on the
        -- same boundary this arrives on — whether it is sounding OR merely
        -- queued to start (a queued one is invisible to IsRunning and would
        -- come in on top).
        if Loop.IsRunning(other) or Loop.Pending(other) == 1 then
            Loop.StopClip(other)
        end
        Loop.Play(lane)
    end
end

-- ---------------------------------------------------------------------------
-- ANNULATION SUR UNE CASE
-- ---------------------------------------------------------------------------
-- UNE CASE VIT HORS DE L'ANNULATION DE REAPER, et c'est structurel : elle n'a
-- pas d'item, donc rien que Undo_OnStateChange puisse retenir. Le contrat de
-- Roll prevoit be.undo et l'appelle a chaque geste structurel ; le backend
-- take le branche sur l'annulation de REAPER, le backend clip le branchait sur
-- scheduleApply(), c'est-a-dire sur rien. Un Quantize, un Euclidean ou une
-- suppression dans une case etaient DEFINITIFS, et Ctrl+Z etait explicitement
-- reserve au mode take.
--
-- Une pile de photos des notes, ici. Ce n'est pas un journal d'operations :
-- une case porte quelques centaines de notes, quatre tableaux de nombres se
-- recopient pour rien du tout, et un journal aurait demande a chaque geste de
-- savoir se defaire — c'est-a-dire du travail a CHAQUE ajout futur, contre
-- zero ici.
local HIST_MAX = 64
local hist = { snaps = {}, top = 0, key = nil }

local function histSnap(nt)
    local n = #nt.s
    local s, l, p, v = {}, {}, {}, {}
    for i = 1, n do
        s[i], l[i], p[i], v[i] = nt.s[i], nt.l[i], nt.p[i], nt.v[i]
    end
    return { s = s, l = l, p = p, v = v }
end

local function histRestore(nt, sn)
    local s, l, p, v = {}, {}, {}, {}
    for i = 1, #sn.s do
        s[i], l[i], p[i], v[i] = sn.s[i], sn.l[i], sn.p[i], sn.v[i]
    end
    nt.s, nt.l, nt.p, nt.v = s, l, p, v
end

-- La pile appartient a UNE case. Changer de case la remet a zero : melanger
-- les historiques ferait annuler un geste dans une autre case, ce qui est
-- pire que de ne pas annuler du tout.
local function histReset(c, key)
    hist.key = key
    hist.snaps = { histSnap(c.notes) }
    hist.top = 1
end

local function histPush(c)
    if hist.top < 1 then return end
    for i = #hist.snaps, hist.top + 1, -1 do hist.snaps[i] = nil end
    hist.snaps[#hist.snaps + 1] = histSnap(c.notes)
    if #hist.snaps > HIST_MAX then table.remove(hist.snaps, 1) end
    hist.top = #hist.snaps
end

local function histUndo(c)
    if hist.top <= 1 then return false end
    hist.top = hist.top - 1
    histRestore(c.notes, hist.snaps[hist.top])
    return true
end

local function histRedo(c)
    if hist.top >= #hist.snaps then return false end
    hist.top = hist.top + 1
    histRestore(c.notes, hist.snaps[hist.top])
    return true
end

local function makeClipBackend(c)
    local nt = c.notes
    return {
        readAll = function()
            local n = #nt.s
            for i = 1, n do
                Roll.starts[i], Roll.lens[i], Roll.pitches[i], Roll.vels[i]
                    = nt.s[i], nt.l[i], nt.p[i], nt.v[i]
            end
            return n
        end,
        insertNote = function(t, pitch, len, vel)
            local n = #nt.s + 1
            nt.s[n], nt.l[n], nt.p[n], nt.v[n] = t, len, pitch, vel
        end,
        deleteNote = function(i)
            table.remove(nt.s, i)
            table.remove(nt.l, i)
            table.remove(nt.p, i)
            table.remove(nt.v, i)
        end,
        setNote = function(i, t, len, pitch, vel)
            if t ~= nil then nt.s[i] = t end
            if len ~= nil then nt.l[i] = len end
            if pitch ~= nil then nt.p[i] = pitch end
            if vel ~= nil then nt.v[i] = vel end
        end,
        -- (start, pitch) order keeps Sync's selection-by-identity stable
        sort = function()
            local idx = {}
            for i = 1, #nt.s do idx[i] = i end
            table.sort(idx, function(a, b)
                if nt.s[a] ~= nt.s[b] then return nt.s[a] < nt.s[b] end
                return nt.p[a] < nt.p[b]
            end)
            local s, l, p, v = {}, {}, {}, {}
            for k = 1, #idx do
                local i = idx[k]
                s[k], l[k], p[k], v[k] = nt.s[i], nt.l[i], nt.p[i], nt.v[i]
            end
            nt.s, nt.l, nt.p, nt.v = s, l, p, v
        end,
        -- be.undo est appele APRES le geste : la photo prise ici est donc
        -- l'etat qui en resulte, et la pile part de l'etat initial pose au
        -- chargement de la case. Annuler, c'est revenir d'un cran.
        undo = function()
            histPush(c)
            scheduleApply()
        end,
    }
end

local function setItem(item)
    local take = r.GetActiveTake(item)
    if not take then return false end
    flushApply()
    state.clip, state.clip_lane = nil, nil
    state.clip_track, state.clip_tag = nil, 0
    if r.TakeIsMIDI(take) then
        dropOwnSource()
        state.mode, state.item, state.take = "midi", item, take
        local ok, name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        state.name = (ok and name ~= "") and name or "MIDI item"
        state.src, state.path = nil, ""
        state.len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        state.ch, state.sr = 0, 0
        Roll.Attach(take, item)
        -- fit the vertical view to the notes (scrollable/zoomable afterwards)
        do
            local vlo, vhi = 127, 0
            for i = 1, Roll.count do local p = Roll.pitches[i]; if p < vlo then vlo = p end; if p > vhi then vhi = p end end
            if Roll.count == 0 then vlo, vhi = 48, 71 end
            local rows = (vhi - vlo) + 6
            if rows < 18 then rows = 18 elseif rows > 48 then rows = 48 end
            state.view_rows = rows
            state.view_hi = math.min(127, vhi + 2)
        end
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
    flushApply()
    state.clip, state.clip_lane = nil, nil
    state.clip_track, state.clip_tag = nil, 0
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
    -- L'item selectionne au moment de l'ouverture ne doit pas reprendre le
    -- focus tout de suite — mais le SUIVANT, oui. Meme regle que le mode case,
    -- et posee ici pour qu'elle vaille par quelque porte qu'on soit entre : un
    -- depot Windows, la barre de messages, ou un envoi depuis une autre
    -- fenetre.
    state.seen_sel_item = r.GetSelectedMediaItem(0, 0)
    resetForTarget()
    return true
end

-- Focus a take-less MIDI clip. The editor edits the clip IN PLACE and
-- publishes it back (editor:apply) after each gesture.
local function setClip(c)
    flushApply()
    dropOwnSource()
    Roll.Detach()
    state.mode, state.item, state.take = "clip", nil, nil
    state.clip = c
    -- origin "looper:N" → the engine TRACK this clip belongs to. The lane is
    -- deliberately NOT kept: a track owns two lanes and its clips move
    -- between them as they swap, so a remembered lane number goes stale and
    -- takes the playhead, the transport button and — worst — the edits with
    -- it. The tag says which lane holds THIS clip; it is asked for again
    -- every frame.
    state.clip_track, state.clip_tag, state.clip_lane = nil, 0, nil
    local ln = c.origin and c.origin:match("^looper:(%d+)")
    if ln then
        loopInit()
        -- old descriptors stored a raw lane (0..7); lane 5 has always meant
        -- track 1, so the migration is free
        state.clip_track = Loop.TrackOfLane(tonumber(ln))
        -- The clip's own identity when it has one, the positional tag when it
        -- comes from a project written before identities existed. One call,
        -- and this window stops needing to know which era it is looking at.
        state.clip_tag   = Ident.TagOf(c)
        state.clip_lane  = Loop.LaneOfTag(state.clip_track, state.clip_tag)
    end
    c.notes = c.notes or { s = {}, l = {}, p = {}, v = {} }
    state.name = (c.name and c.name ~= "") and c.name or "Clip"
    state.src, state.path = nil, ""
    state.len = (c.bars and c.bars > 0 and c.bars or 4) * clipTsNum()
    state.ch, state.sr = 0, 0
    -- the item selected when the clip opened must not steal the focus back
    state.seen_sel_item = r.GetSelectedMediaItem(0, 0)
    -- L'HISTORIQUE APPARTIENT A CETTE CASE. La cle est son identite quand
    -- elle en a une, son adresse sinon : melanger deux historiques ferait
    -- annuler un geste dans une autre case, ce qui est pire que de ne pas
    -- annuler.
    histReset(c, state.clip_tag ~= 0 and state.clip_tag or tostring(c))
    Roll.SetBackend(makeClipBackend(c))
    -- vertical fit to the notes (same as the midi branch of setItem)
    local vlo, vhi = 127, 0
    for i = 1, Roll.count do
        local p = Roll.pitches[i]
        if p < vlo then vlo = p end
        if p > vhi then vhi = p end
    end
    if Roll.count == 0 then vlo, vhi = 48, 71 end
    local rows = (vhi - vlo) + 6
    if rows < 18 then rows = 18 elseif rows > 48 then rows = 48 end
    state.view_rows = rows
    state.view_hi = math.min(127, vhi + 2)
    state.mdrag = nil
    resetForTarget()
    return true
end

local function clearTarget()
    flushApply()
    Audition.Stop()   -- a dying item takes its source with it; stop first
    dropOwnSource()
    Roll.Detach()
    state.mode, state.item, state.take = nil, nil, nil
    state.clip, state.clip_lane = nil, nil
    state.clip_track, state.clip_tag = nil, 0
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

-- « Ce que je fais maintenant s'applique a QUOI » — dit, pas devine. Une
-- portee d'operation invisible se decouvre en quantifiant tout un clip.
local function rangeNote()
    if Roll.seln > 0 then return "  ·  " .. Roll.seln .. " selected" end
    if Roll.HasRange() then
        return "  ·  range: " .. Roll.RangeCount() .. " notes"
    end
    return ""
end

local function metaLine()
    if state.mode == "midi" or state.mode == "clip" then
        if state.meta_line and state.meta_rollver == Roll.version
           and state.meta_len == state.len then
            return state.meta_line
        end
        if state.mode == "clip" then
            -- Notes past the loop end are KEPT but silent. Shortening a loop
            -- must never destroy what you wrote — lengthening it brings the
            -- music back — but without saying so, a shorter loop looks like
            -- a deletion.
            local out = 0
            for i = 1, Roll.count do
                if Roll.starts[i] >= state.len - 1e-6 then out = out + 1 end
            end
            state.meta_line = string.format("%d notes%s  ·  %g beats%s%s",
                Roll.count, rangeNote(), state.len,
                out > 0 and ("  ·  " .. out .. " past the loop (kept, silent)") or "",
                (state.clip and state.clip.origin)
                    and ("  ·  " .. state.clip.origin) or "")
        else
            state.meta_line = string.format("%d notes%s  ·  %.2fs",
                                            Roll.count, rangeNote(), state.len)
        end
        state.meta_rollver, state.meta_len = Roll.version, state.len
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

-- Focus-switch on a Clip (chantier 10, the universal-editor foundation):
-- the editor opens whatever the suite hands it over the Bus. Audio clips
-- open the referenced file with the clip's region as the selection —
-- the Sampler's trim lands selected, not just the whole file. MIDI
-- clips need the take-less Roll backend; that lands with the full
-- universal editor.
local function openClip(c)
    if c.kind == "audio" and c.path and c.path ~= "" then
        if not setFile(c.path) then return end
        if c.name and c.name ~= "" then state.name = c.name end
        if c.offs and c.len and c.len > 0 and state.len > 0 then
            state.sel_a = math.max(0, c.offs)
            state.sel_b = math.min(state.len, c.offs + c.len)
            if state.sel_b > state.sel_a then
                state.cursor = state.sel_a
                zoomSelection()
            else
                state.sel_a, state.sel_b = nil, nil
            end
        end
    elseif c.kind == "midi" then
        setClip(c)
    end
end

-- ---------------------------------------------------------------------------
-- Drops INTO the editor. Two protocols, one destination:
--   · the CP bus (Media Explorer, Session, Sampler…) — a Clip descriptor,
--     so an audio drop keeps its region and a MIDI clip stays a clip;
--   · plain OS files (Explorer, or any app that drops paths on the window).
-- Dropping a sound here is the gesture that turns it into an instrument:
-- it opens for editing, and the SEND cluster ships it to the Sampler
-- (slices → pads, selection → pad, whole file → chromatic instrument)
-- without ever touching the arrange.
-- ---------------------------------------------------------------------------
local BUS_ID = "editor"
local drop_paths = {}   -- reused scratch (no per-frame allocation)

local function handleFileDrops()
    if gfx.getdropfile(0) == 0 then return end
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
    -- one editor, one target: the first file wins (the rest would just
    -- replace each other), and the lock is respected like any other open
    if setFile(drop_paths[1]) then
        -- UN DEPOT SE DEFEND CONTRE LA SELECTION DEJA EN PLACE, PAS CONTRE LA
        -- SUIVANTE. Le verrou faisait les deux : apres un depot, cliquer un
        -- item de l'arrangement ne changeait plus rien et il fallait relancer
        -- le script — un Lock qu'on n'a pas presse et qu'on ne pense donc pas
        -- a lever. `setFile` se souvient maintenant de l'item selectionne a cet
        -- instant, ce qui dit exactement ce qu'on voulait dire.
        flash(#drop_paths > 1
              and ("Opened " .. state.name .. "  ·  "
                   .. (#drop_paths - 1) .. " more ignored")
              or ("Opened " .. state.name))
    end
end

local function busConsume()
    if not state.registered then
        state.registered = DragBus.Register(BUS_ID)
    end
    DragBus.RectSync(BUS_ID)   -- publish our screen rect (write-on-change)
    local clip = Bus.TakeDrop(BUS_ID)
    if not clip then return end
    openClip(clip)
    if state.mode then
        state.seen_sel_item = r.GetSelectedMediaItem(0, 0)
        flash("Opened " .. state.name)
    end
end

-- ---------------------------------------------------------------------------
-- Target polling (arrange selection follow + cross-script open + validity)
-- ---------------------------------------------------------------------------
local function pollTarget()
    -- legacy "Open in Editor" channel (bare path, old publishers)
    local v = r.GetExtState("CP_Editor", "open")
    if v ~= "" and v ~= state.last_open then
        state.last_open = v
        local ts, path = v:match("^([^\n]+)\n(.*)$")
        ts = tonumber(ts)
        if ts and path and path ~= "" and r.time_precise() - ts < 5.0 then
            setFile(path)
        end
    end

    -- "editor:open" Clips over the Engine Bus (region-aware; this is the
    -- one channel every publisher migrates to)
    local clip = Bus.Recv("editor:open")
    if clip then openClip(clip) end

    -- follow the arrange selection. In clip mode the clip owns the focus:
    -- only a NEW selection (not the one already selected when the clip
    -- opened) pulls the editor back to the arrange.
    if not state.lock then
        local it = r.GetSelectedMediaItem(0, 0)
        -- Une cible qui n'est PAS un item du projet — une case, un fichier
        -- depose — garde le focus tant que la selection de l'arrangement ne
        -- CHANGE pas. C'est la difference entre « on m'a ouvert ceci » et « on
        -- vient de cliquer autre chose », et sans elle un fichier depose
        -- repartait aussitot vers l'item deja selectionne, ou ne repartait
        -- jamais selon la facon dont on avait bloque le premier cas.
        if state.mode == "clip" or state.mode == "file" then
            if it ~= state.seen_sel_item then
                state.seen_sel_item = it
                if it then setItem(it) end
            end
        elseif it and it ~= state.item then
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
-- Where the preview starts, where it stops, and where a LOOP turns back to.
--
-- REAPER's three starts, and the same keys:
--   Space              — the edit cursor
--   Shift+Space        — the start of the time selection
--   Ctrl+Shift+Space   — the start of the material (its "project start")
--
-- The turnaround is NOT the start. Beginning at a cursor dropped in the middle
-- and then looping on that point would repeat a fragment nobody asked for:
-- a loop belongs to the PART being played — the selection when there is one,
-- the whole material otherwise.
local function previewSpan(from)
    local a, b = targetRegion()

    -- The PART being played. ONLY Shift+Space plays the time selection —
    -- plain Space plays the material and merely STARTS at the cursor, which
    -- is the distinction the two keys exist for. Reading the selection here
    -- for every start is what made Space ignore the cursor.
    local pa, pb = a, b
    if from == "sel" and state.sel_a then
        pa, pb = state.sel_a, state.sel_b
    end

    local s = (from == "cursor" or from == nil) and state.cursor or pa
    if s < pa then s = pa end
    if pb and s >= pb then s = pa end

    return s, pb, pa
end

-- ONE place decides what section is in force while a preview runs.
--
-- The time selection is never IGNORED. You may start outside it — that is what
-- plain Space is for — but the moment the playhead enters it, its edges take
-- over: loop back when the loop is on, stop at the end when you asked for
-- that. Arming it on arrival rather than at the press is what lets a start
-- from anywhere and a respected range be the same thing.
--
-- It also re-asserts the section every frame, so MOVING the selection while it
-- plays moves what plays instead of being ignored until the next press.
local function pollSection()
    if not Audition.IsPlaying() then
        state.fenced = false
        return
    end

    -- TANT QUE NOTRE ECOUTE SONNE, LA FENETRE RESTE EVEILLEE.
    --
    -- Le bouton Play ne se mettait pas toujours a « Stop » apres un appui sur
    -- la barre d'espace, alors que le son partait : la fenetre s'endormait.
    -- Les touches sont traitees APRES le dessin, donc l'appui laisse toujours
    -- une image de retard ; l'elan d'entree la rattrapait — quand il durait
    -- assez. Passe ce delai, la boucle retombait a deux images par seconde et
    -- l'ecran restait fige sur « Play » pendant que ca jouait.
    --
    -- Le reveil etait demande ailleurs : par le CURSEUR DE LECTURE, et
    -- seulement quand il tombait juste (`playCursorTime` rend nil des que la
    -- position n'est pas lisible). Une fenetre qui se rafraichit parce qu'elle
    -- a quelque chose a dessiner s'arrete de le faire des qu'elle n'a plus
    -- rien — et l'etat d'un bouton, lui, doit rester vrai.
    --
    -- Ici, la condition est la bonne : ca sonne, donc ce qui montre que ca
    -- sonne doit continuer d'etre redessine.
    UI.RequestRedraw()

    -- Does the selection govern playback at all right now? Only if there is
    -- one AND something says what its end means: the loop, the stop rule, or
    -- the fact that you asked to play it.
    local governs = state.sel_a
        and (opts.loop or opts.stop_at_sel or state.play_from == "sel")

    if not governs then
        -- The material's own span, re-asserted — which also RELEASES a fence
        -- if the rule that armed it was just switched off.
        state.fenced = false
        local _, pe, pl = previewSpan(state.play_from)
        Audition.SetSection(opts.loop, pe, pl)
        return
    end

    if not state.fenced and state.play_from ~= "sel" then
        local pos = Audition.Position()
        if not (pos and pos >= state.sel_a and pos < state.sel_b) then
            -- outside it still: the material's span applies until we arrive
            local _, pe, pl = previewSpan(state.play_from)
            Audition.SetSection(opts.loop, pe, pl)
            return
        end
        state.fenced = true
    end
    Audition.SetSection(opts.loop, state.sel_b, state.sel_a)
end

-- La source de l'item est-elle un vrai fichier, dont le chemin dit la meme
-- chose qu'elle ? Une SECTION enveloppe un fichier : meme chemin, autre duree
-- et autre origine — jouer son chemin jouerait autre chose que ce qui est
-- dessine. Tout le reste (WAVE, MP3, FLAC...) est le fichier lui-meme.
local function plainFileSource()
    if not state.src or state.path == "" then return false end
    local t = r.GetMediaSourceType(state.src)
    return t ~= "SECTION" and t ~= "" and t ~= "MIDI" and t ~= "MIDIPOOL"
end

-- CE QUI VA JOUER, en toutes lettres. On ne le devine pas : on repose la
-- question a Audition (`WillUseVoices`) et aux memes CAPACITES qu'elle
-- interroge, plutot que de recopier sa decision ici — deux copies d'une regle
-- finissent toujours par diverger, et celle-la se lit dans un menu au moment
-- ou l'utilisateur cherche une explication.
local function previewEngineLabel()
    if not Audition.WillUseVoices() then
        return "CF_Preview (loop polled once per frame)"
    end
    if state.mode == "item" and state.src and not plainFileSource() then
        return "CF_Preview — the take has no file of its own (section/reversed)"
    end
    if state.mode == "item" and state.take then
        local rate = r.GetMediaItemTakeInfo_Value(state.take, "D_PLAYRATE")
        if rate and math.abs(rate - 1.0) > 1e-9 then
            return "CF_Preview — the take is stretched"
        end
    end
    if state.len > 15.0 then
        return "CF_Preview — over 15 s, read from disk"
    end
    return "CP voice (sample-exact loop)"
end

-- La piste par laquelle l'ecoute doit sortir, ou nil pour la carte son.
-- Les DEUX moteurs l'honorent maintenant (`resolveOut` d'Audition lit
-- `opts.out_track`), donc ce choix ne depend plus de celui qui repond.
-- Rend la piste de sortie ET le drapeau « carte son ». Les deux, parce que
-- « pas de piste » ne veut plus dire « la carte » : sans piste on sort par le
-- master, qui est la sortie que tout le monde entend. Court-circuiter le projet
-- est devenu un choix explicite, comme il aurait toujours du l'etre.
local function previewOut()
    local m = opts.out_mode
    if m == "hw" then return nil, true end
    if m == "item" and state.mode == "item" and state.item
       and r.ValidatePtr2(0, state.item, "MediaItem*") then
        return r.GetMediaItemTrack(state.item), false
    end
    return r.GetMasterTrack(0), false
end

-- from: "cursor" (default) | "sel" | "start"
local function togglePlay(from)
    if state.mode == "clip" then
        -- Les trois departs de REAPER valent ici aussi : le curseur, le debut
        -- de la zone, le debut de la matiere. Une case n'a pas de transport a
        -- elle, donc « ou commence la lecture » veut dire « ou commence la
        -- BOUCLE » — et c'est la meme question.
        clipLaunch(from)
        return
    end
    if state.mode == "midi" then
        -- MIDI previews in context: the item plays through its track
        r.Main_OnCommand(40044, 0)   -- Transport: Play/stop
        return
    end
    if Audition.IsPlaying() then
        Audition.Stop()
        return
    end
    state.play_from = from or "cursor"
    state.fenced = false
    local ps, pe, pl = previewSpan(from)
    PLAY_OPTS.start_s = ps
    -- The section is the played PART either way; the loop only decides whether
    -- its end stops playback or turns it around. (Audio enforces the section
    -- itself — CF_Preview's own B_LOOP would repeat the whole source, not the
    -- part you are listening to.)
    PLAY_OPTS.loop       = opts.loop or nil
    PLAY_OPTS.end_s      = pe
    PLAY_OPTS.loop_start = pl
    -- Reflect the take's non-destructive edits so the preview SOUNDS like
    -- the item (gain/normalize, pitch, rate, fades, repitch mode) — playing
    -- the raw file otherwise ignores every edit.
    PLAY_OPTS.vol, PLAY_OPTS.pitch, PLAY_OPTS.rate = nil, nil, nil
    -- (out_track / hw_out sont poses juste apres : ils ne se remettent pas a
    -- nil ici, sinon la sortie choisie serait perdue a chaque lancement.)
    PLAY_OPTS.fade_in, PLAY_OPTS.fade_out, PLAY_OPTS.ppitch = nil, nil, nil
    PLAY_OPTS.out_track, PLAY_OPTS.hw_out = previewOut()
    if state.mode == "item" and state.take then
        local v = r.GetMediaItemTakeInfo_Value(state.take, "D_VOL")
        -- compose take gain WITH the user's preview-volume setting (an OR in
        -- Audition.Play would otherwise let take gain replace the monitor level)
        PLAY_OPTS.vol    = Audition.volume * math.abs(v)
        PLAY_OPTS.pitch  = r.GetMediaItemTakeInfo_Value(state.take, "D_PITCH")
        PLAY_OPTS.rate   = r.GetMediaItemTakeInfo_Value(state.take, "D_PLAYRATE")
        PLAY_OPTS.ppitch = r.GetMediaItemTakeInfo_Value(state.take, "B_PPITCH")
        -- the item's real fades (lengths — CF_Preview has no shapes), so a
        -- fade-out drawn in the editor is HEARD on the very next play
        local fin  = r.GetMediaItemInfo_Value(state.item, "D_FADEINLEN")
        local fout = r.GetMediaItemInfo_Value(state.item, "D_FADEOUTLEN")
        if fin  and fin  > 0 then PLAY_OPTS.fade_in  = fin  end
        if fout and fout > 0 then PLAY_OPTS.fade_out = fout end
        -- LA SOURCE QUAND IL LE FAUT, LE FICHIER QUAND ON PEUT.
        --
        -- Une source SECTION (une prise inversee, une sous-section) n'a pas de
        -- fichier a elle : son chemin designe le fichier ENTIER, donc toutes
        -- nos positions seraient fausses. Elle doit passer par CF_Preview, qui
        -- sait jouer une PCM_source qu'on lui tend.
        --
        -- Mais un item ordinaire — l'immense majorite — a un vrai fichier
        -- dessous, et le lui refuser le condamnait a CF_Preview pour rien. Or
        -- CF_Preview ne tient pas les points de boucle : le retour est
        -- surveille une fois par frame depuis Lua (`Preview.Poll`), donc une
        -- selection courte s'entend par paliers au lieu de boucler ou on l'a
        -- posee. La voix CP, elle, porte ses bornes en frames source et
        -- reboucle A L'ECHANTILLON — c'est ce qui rend le mode fichier si
        -- reactif, et il n'y avait aucune raison que l'item n'y ait pas droit.
        --
        -- Ce qui reste hors de portee du moteur (transposition, etirement) est
        -- renvoye a CF_Preview par `Audition` elle-meme, sur des CAPACITES et
        -- non sur un backend : rien a decider ici.
        if state.src and not plainFileSource() then
            Audition.PlaySource(state.src, PLAY_OPTS)
            return
        end
    end
    if state.path == "" then
        flash("No previewable file for this source")
        return
    end
    Audition.Play(state.path, PLAY_OPTS)
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
            -- a slice is a fragment of the file: its length says nothing
            -- about a tempo, so never auto beat-match it
            if Kit.LoadSample(note, state.path, { no_sync = true }) then
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
        if Kit.LoadSample(note, state.path, { no_sync = true }) then
            Kit.SetOffsets(note, state.sel_a / state.len,
                                 state.sel_b / state.len)
        end
    end)
    flash("Selection sent to pad " .. note)
end

-- Send the current file (or its selection) to the CP_Sampler as a
-- chromatic INSTRUMENT — the Ableton "sample → Simpler" move. Delivered by
-- ExtState; the Sampler switches to instrument mode and loads it (5s window).
local function sendToInstrument()
    if state.path == "" then
        flash("No previewable file for this source")
        return
    end
    local s, e = 0, 1
    if state.sel_a and state.len > 0 then
        s = state.sel_a / state.len
        e = state.sel_b / state.len
    end
    r.SetExtState("CP_Sampler", "instrument",
        string.format("%.3f\n%s\n%.6f\n%.6f", r.time_precise(), state.path, s, e),
        false)
    flash("Sent to Sampler instrument")
end

-- ---------------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------------
-- The row tags, dividers and icon-button helper that dressed the old action
-- bar are gone with it: a rail group IS the tag, and a rail entry IS the icon
-- button. Nothing here draws a widget by hand any more.
local function openSettings()
    local function normItem(db)
        return { label = db == 0 and "0 dBFS" or (db .. " dBFS"),
                 checked = opts.norm_db == db,
                 action = function() opts.norm_db = db markDirty() end }
    end
    local function volItem(pct)
        return { label = pct .. "%", checked = Audition.volume == pct / 100,
                 action = function() Audition.SetVolume(pct / 100) markDirty() end }
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
        { label = "Preview output", children = {
            { label = "Master track (default)",
              checked = opts.out_mode == "master",
              action = function() opts.out_mode = "master" markDirty() end },
            { label = "Sound card (direct — bypasses the whole project)",
              checked = opts.out_mode == "hw",
              action = function() opts.out_mode = "hw" markDirty() end },
            { label = "The item's own track (its FX + fader)",
              checked = opts.out_mode == "item",
              action = function() opts.out_mode = "item" markDirty() end },
        } },
        -- QUEL MOTEUR VA REPONDRE, dit avant qu'on se demande pourquoi le son
        -- n'est pas le meme. La voix CP reboucle a l'echantillon ; CF_Preview
        -- fait surveiller son retour une fois par frame depuis Lua, donc une
        -- selection tres courte s'entend par paliers. Ce n'est pas un reglage,
        -- c'est une consequence — de la duree du fichier, d'une transposition,
        -- d'un taux de lecture, d'une source sans fichier.
        -- Et « le son n'arrive pas par la porte que j'ai choisie » se cherche
        -- longtemps quand rien ne le dit : le repli s'annonce sur la meme
        -- ligne, parce qu'un menu natif n'a pas d'entree qu'on peut cacher.
        { label = "Engine: " .. previewEngineLabel()
                  .. (Audition.out_fallback
                      and "   ·   ⚠ output refused, playing through the sound card"
                      or ""),
          disabled = true },
        { separator = true },
        -- LA CARTE DES GESTES, EN CLAIR. REAPER a eu reaper-kb.ini bien avant
        -- d'avoir une fenetre pour le remplir, et c'est le bon ordre : un
        -- fichier qu'on peut lire ET modifier vaut deja l'essentiel. Celui-ci
        -- s'ecrit complet, chaque action commentee de son libelle, et se relit
        -- sans fermer la fenetre.
        { label = "Keyboard & mouse", children = {
            { label = "Configure the keys and modifiers…",
              action = function()
                  -- UNE FENETRE A PART, jamais une page par-dessus celle-ci :
                  -- on regle un raccourci en REGARDANT l'editeur, pas a sa
                  -- place. Une page aurait oblige a fermer pour verifier et a
                  -- rouvrir pour corriger, a chaque essai.
                  if not KeymapUI.OpenWindow(KM) then
                      flash("Could not open CP_Tools/CP_Keymap.lua")
                  end
              end },
            { separator = true },
            { label = "Write the current map to CP_Config/CP_Keymap.lua",
              action = function()
                  local ok, path = Keymap.Export(KM)
                  flash(ok and ("Written: " .. tostring(path))
                        or ("Could not write: " .. tostring(path)))
              end },
            { label = "Reload it (after editing the file)",
              action = function()
                  Keymap.Reload(KM)
                  flash("Keymap reloaded")
              end },
            { label = "Back to the defaults",
              action = function()
                  Keymap.Reset(KM)
                  flash("Keymap back to defaults (the file still exists)")
              end },
        } },
        { separator = true },
        -- The rule that says what a time selection MEANS to playback when the
        -- loop is off. With the loop on it loops; with this on it stops there;
        -- with both off the selection is only a range you act on, and the
        -- sound runs past it.
        { label = "Playback stops at the end of the time selection",
          checked = opts.stop_at_sel,
          action = function() opts.stop_at_sel = not opts.stop_at_sel markDirty() end },
        { label = "Clicking a clip's ruler moves the playing clip there",
          checked = opts.ruler_scrub,
          action = function() opts.ruler_scrub = not opts.ruler_scrub markDirty() end },
    })
end

-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## CP Editor
One editor for everything: an audio item, a MIDI item, a plain file,
or a CLIP (a Looper lane / session cell — edits go back live). It
follows the arrange selection; the lock keeps the current target.

## Sound in, instrument out
Drop a sound on this window — from the Media Explorer, the Session, or
Windows — and it opens for editing (following the arrange selection
locks itself, so the drop stays). Then the SEND cluster turns it into
an instrument WITHOUT creating anything in the arrange: Detect finds
the transients, "Slices to pads" scatters them across the kit, "Sel to
pad" sends one region, "To instrument" spreads the whole sound across
the keyboard (chromatic).

## Audio
Drag = select, wheel = zoom, middle-drag = pan. Gain, fades, pitch,
rate and reverse are the item's own, non-destructive — and the
preview SOUNDS like the item: fades, reverse, repitch, its track's
FX (Settings). Slice to pads, bake a selection, normalize, warp.

Handles, and where they live. FADES at the TOP of the waveform, the
item's EDGES at the BOTTOM — drag one to change what actually plays,
the way the Sampler's region works. A selection's own edges resize it
instead of starting a new one. Every handle lights up under the
cursor and grows while you hold it.

The RULER moves the edit cursor and nothing else, as REAPER's does:
you place where the next action starts without losing the range you
just selected. Drag in it to scrub.

Where play starts, on REAPER's own keys:
  Space              the edit cursor
  Shift+Space        the start of the time selection
  Ctrl+Shift+Space   the start of the sample
Space plays the SAMPLE from wherever the cursor is; only Shift+Space
plays the time selection. A loop turns back to the start of the part
being played, never to the point you started from — and moving the
selection while it loops changes what loops.

The time selection is never IGNORED. Start outside it if you like:
the moment the playhead enters it, its edges take over — it loops if
LOOP is on, and it stops at the end if "Playback stops at the end of
the time selection" is on (Settings, on by default). Turn both off and
the selection becomes a range you act on rather than one you hear.

A CLICK places the edit cursor and leaves the selection alone: only a
DRAG changes a selection. SHIFT ignores the snap, everywhere.

TRANSIENTS are objects. Detect them, then: Ctrl+click adds one where
you point, M adds one on the edit cursor, drag a flag to move it,
Alt+click a flag (or Delete on the cursor) removes it. They are snap
targets too, so a selection lands on a hit instead of near it.

CTRL+DRAG A SELECTION OUT of the window: an item follows the mouse
into the arrange, and a CP window (a Sampler pad, a Session cell)
takes the same region if you drop it there instead. Nothing is
rendered — it is the same file with a start and a length — so what
lands stays fully editable.

SNAP (the magnet) holds the selection and the cursor to the grid, and
the grid is the SAME one the piano roll uses. A file has no position
on the timeline, so its grid is read from the project's zero — which
is what makes a loop's beats land where you expect. Turn snap off and
the zero-crossing snap takes over instead (Settings).

LOOP (next to Play) repeats the played part — the selection when
there is one, the whole region otherwise — and takes effect on what
is already playing. The play cursor is REAPER's own colour and shows
both our preview AND the arrange's transport running over this item.

## MIDI / clip
Click empty = add note (keep dragging for length), drag = move,
edge = resize, right-drag = marquee, velocity lane below.

Mouse modifiers follow REAPER's own MIDI table:
  Shift+drag       ignore snap        Ctrl+drag     copy
  Alt+click/drag   erase              Shift+click   add a range
  Ctrl+click       toggle one note    Shift+Alt     the whole measure
  Ctrl+Alt+click   this note onward   Shift+Ctrl    one axis only
  Alt on the edge  stretch            Ctrl+Win      arpeggiate
  Ctrl+Alt+drag    paint a line       +Shift        paint chords
  Shift/Ctrl+Win   double / halve the note length
(On the RULER it is Ctrl that ignores snap — REAPER's own split.)

Q quantize, Ctrl+D duplicate, Ctrl+C/X/V, arrows transpose/nudge,
Alt+arrows walk the notes, Esc leave. Transform: scale snap, chord,
arpeggiate, euclidean, humanize... Drum rows name the kit's pads.

## Clip loop (LOOP cluster)
A clip born in the Looper/Session stays live: the playhead shows the
engine's position, Play/Stop launches the lane (quantized — Space
works too), and -/+ halve/double the loop length in bars.
]]

-- Right-hand end of the bar: what is true of the window whatever it is
-- showing. Reserved FIRST, before anything fills from the left, so a narrow
-- window drops a slice tool rather than Settings.
--
-- Written outermost-first: Help sits hard against the right edge, Settings to
-- its left, Lock to the left of that.
--
-- Lock is a TOGGLE and not a button — it carried a state and hid it, which is
-- the third of the nomenclature's interdits.
local function barCommon()
    UI.BarRight()
    if UI.BarIcon("help", "Help", "Help") then
        UI.ShowHelp("help", HELP_TEXT)
    end
    if UI.BarIcon("settings", "Settings2", "Settings") then
        openSettings()
    end
    local lk = UI.BarToggle("lock", "Lock", "Unlock", state.lock,
                            state.lock and "Locked to this take"
                                       or "Following the selection")
    if lk then state.lock = not state.lock end
    UI.BarSep()
    UI.BarLeft()
end

-- The identity of what is open, on one line above the canvas. It is not a
-- toolbar: nothing here is clickable, so it costs a line and no ambiguity.
local function headerLine(theme)
    UI.SetFontH2()
    UI.Text(state.mode and state.name or "Sample Editor")
    UI.SameLine(10)
    UI.SetFontCaption()
    if state.mode == "file" then
        UI.Text("file mode — slice and send to pads; no item is touched",
                { disabled = true })
    elseif not state.mode then
        UI.Text("drop a sound here, or select an audio item in the arrange",
                { disabled = true })
    else
        UI.Text(metaLine(), { disabled = true })
    end
    UI.SetFontBody()
    UI.Spacing(2)
end

-- The rail is gone. It cost 126 px of WIDTH permanently, and width is what a
-- waveform and a piano roll are made of; a bar costs 30 px of height once.
-- The other half of the trade is that the bar degrades by itself: a control
-- that no longer fits is simply not placed, so a narrow window sheds tools
-- from the middle instead of needing a fold flag to be told to.
--
-- Verbs are ICONS ONLY here, with the name in the tooltip. In a strip that
-- dense the glyph is what you aim at; the word only takes room.

-- Role-coloured option tables, rebuilt only when the theme object itself
-- changes. The colours are the THEME's (play / record / pending), never
-- literals copied in here — that was the point of making them tokens.
local roleOpts = { theme = false }
local function roles(theme)
    if roleOpts.theme ~= theme then
        roleOpts.theme = theme
        roleOpts.play = { accent = theme.colors.play }
        roleOpts.rec  = { accent = theme.colors.record }
        roleOpts.pend = { accent = theme.colors.pending }
    end
    return roleOpts
end

-- Gain / pitch / rate / sens are values you set BY EAR, so they keep the
-- gestures a knob had — drag, wheel, right-click to type, double-click to
-- reset — but they wear the bar's form: a chip of the one height, filled to
-- show how far along the value sits. A 30 px knob in a 22 px strip would have
-- set the height of the whole window's chrome by itself.
local V_GAIN = { format = "%.1f dB", step = 0.5, integer = false, default = 0, w = 4 }
local V_PIT  = { format = "%d st",   step = 1,   default = 0, w = 3 }
local V_RATE = { format = "%.2fx",   step = 0.05, integer = false, default = 1, w = 3 }
local V_SENS = { format = "%d%%",    step = 1,   default = 50, w = 3 }

local function barAudio(theme)
    local playing = Audition.IsPlaying()
    if UI.BarToggle("play", "Stop", "Play", playing,
                    playing and "Stop" or "Play", false, roles(theme).play) then
        togglePlay()
    end
    -- Loop the played part: the selection when there is one, the region
    -- otherwise. It applies to what is ALREADY playing, so it is a thing you
    -- reach for while listening rather than a setting for next time.
    if UI.BarToggle("loop", "Repeat", nil, opts.loop,
                    "Loop the played part (selection, else the whole region)") then
        opts.loop = not opts.loop
        markDirty()
        -- nothing to compute: pollSection re-asserts the section every frame
    end
    if UI.BarIcon("zfit", "Maximize", "Fit to window") then fitView() end
    if UI.BarIcon("zin", "ZoomIn", "Zoom in") then
        zoomAt(wave.x + wave.w / 2, 1 / 1.5)
    end
    if UI.BarIcon("zout", "ZoomOut", "Zoom out") then
        zoomAt(wave.x + wave.w / 2, 1.5)
    end
    UI.BarSep()

    -- The SAME grid the roll uses, on the same two controls. A file has no
    -- position on the timeline, so its grid is read from the project's zero —
    -- which is what makes a loop's beats fall where you expect them.
    if UI.BarToggle("w_snap", "Magnet", nil, opts.wave_snap,
                    "Snap the selection and the cursor to the grid") then
        opts.wave_snap = not opts.wave_snap
        markDirty()
    end
    local widx = 1
    for i = 2, #GRID_ITEMS do
        if opts.grid_div and math.abs(opts.grid_div - GRID_VALS[i]) < 1e-9 then
            widx = i break
        end
    end
    local wch, wgi = UI.BarCombo("w_grid", widx, GRID_ITEMS, not opts.wave_snap,
                                 GRID_BAR_OPTS)
    if wch then
        opts.grid_div = (wgi == 1) and nil or GRID_VALS[wgi]
        grid_lbl.div = -1
        markDirty()
    end
    UI.BarSep()

    local nomark = #state.markers == 0

    if state.mode ~= "item" then
        if UI.BarIcon("sl_detect", "Activity", "Detect transients") then
            detectMarkers()
        end
        if UI.BarIcon("sl_clear", "Eraser", "Clear markers", nomark) then
            clearMarkers()
        end
        UI.BarSep()
        if UI.BarIcon("sl_pads", "Drum", "Slices to pads", nomark) then slicesToPads() end
        if UI.BarIcon("sl_selpad", "Target", "Selection to pad",
                      state.sel_a == nil) then selectionToPad() end
        if UI.BarIcon("sl_instr", "Piano", "To instrument",
                      state.path == "") then sendToInstrument() end
        return
    end

    local db = Ops.VolDB(state.take)
    local gch, gdb = UI.BarValue("op_gain", nil, db, -60, 24, false, V_GAIN)
    if gch then Ops.SetVolDB(state.item, state.take, gdb) end
    local pitch = r.GetMediaItemTakeInfo_Value(state.take, "D_PITCH")
    local pch, npit = UI.BarValue("op_pitch", nil, pitch, -48, 48, false, V_PIT)
    if pch then Ops.SetPitch(state.take, state.item, npit) end
    local rate = r.GetMediaItemTakeInfo_Value(state.take, "D_PLAYRATE")
    local rch, nrate = UI.BarValue("op_rate", nil, rate, 0.25, 4, false, V_RATE)
    if rch then Ops.SetRate(state.item, state.take, nrate, true) end
    UI.BarSep()

    if UI.BarIcon("op_norm", "Gauge", "Normalize") then
        local a, b = targetRegion()
        if state.sel_a then a, b = state.sel_a, state.sel_b end
        if Ops.Normalize(state.item, state.take, state.src, a, b, opts.norm_db) then
            flash("Normalized to " .. opts.norm_db .. " dBFS")
        else
            flash("Normalize: no peaks readable")
        end
    end
    if UI.BarIcon("op_rev", "ArrowUpDown", "Reverse") then
        Ops.Reverse(state.item)
    end
    if UI.BarIcon("op_trim", "Scissors", "Trim to selection",
                  state.sel_a == nil) then
        Ops.TrimToSel(state.item, state.take, state.sel_a, state.sel_b)
        state.sel_a, state.sel_b = nil, nil
    end
    UI.BarSep()

    local sch, sens = UI.BarValue("sl_sens", nil,
                                  math.floor(state.sens * 100 + 0.5), 0, 100,
                                  false, V_SENS)
    if sch then
        state.sens = sens / 100
        markDirty()
    end
    if UI.BarIcon("sl_detect", "Activity", "Detect transients") then
        detectMarkers()
    end
    if UI.BarIcon("sl_clear", "Eraser", "Clear markers", nomark) then clearMarkers() end
    if UI.BarIcon("sl_split", "Scissors", "Split item at markers", nomark) then
        splitAtMarkers()
    end
    UI.BarSep()

    -- SEND is the chain "a sound becomes an instrument". It reads as one
    -- block on purpose: these three are the product's whole point.
    if UI.BarIcon("sl_pads", "Drum", "Slices to pads", nomark) then slicesToPads() end
    if UI.BarIcon("sl_selpad", "Target", "Selection to pad",
                  state.sel_a == nil) then selectionToPad() end
    if UI.BarIcon("sl_instr", "Piano", "To instrument",
                  state.path == "") then sendToInstrument() end
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
-- The musical grid over the waveform, cached exactly like the ruler's ticks:
-- rebuilt only when the view, the width or the division moves. Walking the
-- TimeMap per line per frame would be a few hundred API calls for a picture
-- that does not change between them.
-- ---------------------------------------------------------------------------
local wgrid = { t0 = -1, t1 = -1, w = 0, step = -1, mode = "", n = 0,
                xs = {}, bar = {} }
local WGRID_MAX = 400   -- denser than this says nothing: it is a grey wash

local function wgridBuild()
    local step = gridStepQN()
    if wgrid.t0 == state.t0 and wgrid.t1 == state.t1 and wgrid.w == wave.w
       and wgrid.step == step and wgrid.mode == (state.mode or "") then
        return
    end
    wgrid.t0, wgrid.t1, wgrid.w = state.t0, state.t1, wave.w
    wgrid.step, wgrid.mode = step, state.mode or ""
    wgrid.n = 0

    local p0, rate, pos, soffs = srcToProj(state.t0)
    local p1 = srcToProj(state.t1)
    if p1 <= p0 then return end
    local q0 = r.TimeMap2_timeToQN(0, p0)
    local q1 = r.TimeMap2_timeToQN(0, p1)
    if (q1 - q0) / step > WGRID_MAX then return end

    local n = 0
    local q = math.ceil(q0 / step - 0.0001) * step
    while q <= q1 and n < WGRID_MAX do
        local pt = r.TimeMap2_QNToTime(0, q)
        n = n + 1
        wgrid.xs[n] = xAtTime(projToSrc(pt, rate, pos, soffs))
        -- beats WITHIN the measure, so a bar line is one that sits at 0 —
        -- or, float being float, a hair short of the measure's own length
        local beats, _, cml = r.TimeMap2_timeToBeats(0, pt)
        wgrid.bar[n] = (beats < 0.002
                        or (cml and cml > 0 and beats > cml - 0.002)) and true or false
        q = q + step
    end
    wgrid.n = n
end
local wb = { src = nil, t0 = -1, t1 = -1, w = 0, h = 0, gen = -1 }
local SS = Peaks.SS or 2       -- supersampling factor: bake big, blit filtered
local WOPTS = { lanes = true, scale = 0.47, vol = 1,
                mid_r = 0, mid_g = 0, mid_b = 0, mid_a = 0.35 }

-- The buffer is baked at SSx and blitted back filtered, and the peaks are read
-- at SSx too — so the smoothness comes from FINER DATA, not from blurring
-- coarse data. The extra cost is one GetPeaks of twice the count and twice the
-- line calls, and both are paid only when the view actually changes; a steady
-- frame is still one blit. (The same trick the knobs use for their arcs.)
local function renderWave(theme, entry, w, h)
    if wb.src == state.src and wb.t0 == state.t0 and wb.t1 == state.t1
       and wb.w == w and wb.h == h and wb.gen == state.gen then
        return
    end
    wb.src, wb.t0, wb.t1, wb.w, wb.h, wb.gen =
        state.src, state.t0, state.t1, w, h, state.gen

    local bw, bh = w * SS, h * SS
    gfx.dest = WAVE_BUF
    gfx.setimgdim(WAVE_BUF, bw, bh)
    gfx.muladdrect(0, 0, bw, bh, 0, 0, 0, 0)   -- contents undefined after resize

    local bg = theme.colors.list_bg or theme.colors.window_bg
    gfx.set(bg[1], bg[2], bg[3], 1)
    gfx.rect(0, 0, bw, bh, 1)

    -- Take volume scales the drawn waveform so gain / normalize are
    -- visible (the peaks are source-domain, i.e. pre take-volume).
    local vol = 1
    if state.mode == "item" and state.take then
        vol = math.abs(r.GetMediaItemTakeInfo_Value(state.take, "D_VOL"))
    end

    local mid_c = theme.colors.text_mute or theme.colors.text_disabled
    local wf = theme.colors.accent
    WOPTS.vol = vol
    WOPTS.mid_r, WOPTS.mid_g, WOPTS.mid_b = mid_c[1], mid_c[2], mid_c[3]
    Peaks.Render(entry, bw, bh, wf[1], wf[2], wf[3], 0.9, WOPTS)
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

-- The play cursor, from whichever thing is actually playing.
--
--   · our own preview. In item mode it plays the take's SOURCE, so it has no
--     path — and the test used to be `IsPlaying(state.path)`, which can never
--     be true there. That is why the cursor only ever showed in file mode;
--   · REAPER's transport, when the item this editor follows is under the play
--     head. Watching the arrange play while nothing moved here was the other
--     half of it.
--
-- Both answers are in the SOURCE domain, so one xAtTime serves both.
local function playCursorTime()
    if Audition.IsPlaying() then
        local pos = Audition.Position()
        if pos then return pos end
    end
    if state.mode ~= "item" and state.mode ~= "midi" then return nil end
    if not state.item or not state.take then return nil end
    if (r.GetPlayState() & 1) ~= 1 then return nil end
    if not r.ValidatePtr2(0, state.item, "MediaItem*") then return nil end
    local pp   = r.GetPlayPosition()
    local ipos = r.GetMediaItemInfo_Value(state.item, "D_POSITION")
    local ilen = r.GetMediaItemInfo_Value(state.item, "D_LENGTH")
    if pp < ipos or pp > ipos + ilen then return nil end
    local a, _, rate = Ops.ItemRegion(state.item, state.take)
    return a + (pp - ipos) * rate
end

-- ---------------------------------------------------------------------------
-- Wave handles: what is under the cursor, so the DRAWING can answer before
-- the click. A handle you find by trial is not a handle.
--
-- The two families are separated by height rather than by luck: fades live in
-- the top strip, the region edges in the bottom one. They sit at different x
-- anyway, but not always — a fade of zero puts its handle exactly on the edge.
-- ---------------------------------------------------------------------------
local HANDLE_BAND = 14      -- how deep the top/bottom grab strips are
local HANDLE_PX   = 6       -- how close in x counts as "on it"

-- Rest / hover / grab. On a 5-px target a colour change alone is not an
-- answer, so a handle answers by getting BIGGER.
local function handleGrow(hot, held)
    if held then return 3 end
    if hot then return 2 end
    return 0
end

-- ---------------------------------------------------------------------------
-- Dragging the selection OUT — to the arrange, or to another CP window
--
-- The selection is already a region of a file; an item is a file plus a start
-- offset and a length. So the drop needs no rendering, no temp file and no
-- bake: it is the same source with a section on it, which is also why the
-- result stays fully editable instead of arriving flattened.
--
-- Two destinations, one gesture. The arrange gets a REAL item that follows
-- the mouse (Insert's ghost — the machine the Media Explorer already uses);
-- a CP window gets the same region as a CPC1 clip over the bus, so a Sampler
-- pad or a Session cell takes the drop too.
-- ---------------------------------------------------------------------------
local function selectionClip()
    if not state.sel_a or state.path == "" then return nil end
    local c = Clip.new("audio")
    c.path = state.path
    c.offs = state.sel_a
    c.len  = state.sel_b - state.sel_a
    c.name = (state.name ~= "" and state.name or "selection")
    return c
end

local function startDragOut()
    local c = selectionClip()
    if not c then return end
    state.adrag = { label = "+ " .. c.name,
                    section = { offs = c.offs, len = c.len } }
    Audition.Stop()                     -- a drag stays silent
    Bus.BeginClip(c, BUS_ID)         -- CP windows can take it too (not us)
end

local function handleDragOut()
    local d = state.adrag
    if not d then return end
    local sx, sy = r.GetMousePosition()

    -- A CP window under the mouse takes priority: it consumes the drop, so
    -- no ghost item is created behind it.
    local on_cp = DragBus.HoverTarget and DragBus.HoverTarget(sx, sy)
    local over, track, time
    if on_cp then
        Insert.GhostCancel()
        r.TrackCtl_SetToolTip(d.label, sx + 16, sy + 12, true)
    else
        over, track, time = Insert.ArrangeHit(sx, sy)
        if over then
            r.TrackCtl_SetToolTip("", 0, 0, true)
            -- the section is read ONCE, when the ghost is born
            local ps = (not Insert.GhostActive()) and d or nil
            Insert.GhostUpdate(state.path, track, time, ps)
        else
            Insert.GhostCancel()
            r.TrackCtl_SetToolTip(d.label, sx + 16, sy + 12, true)
        end
    end
    UI.SetCursor("hand")

    if Core_tk.MouseReleased(1) then
        state.adrag = nil
        r.TrackCtl_SetToolTip("", 0, 0, true)
        if on_cp then
            if DragBus.Drop(sx, sy) then flash("Dropped: " .. d.label:sub(3)) end
            DragBus.End()
            return
        end
        DragBus.End()
        if over then
            local item = Insert.GhostCommit(state.path)
            if not item and time then
                item = Insert.AtArrange(state.path, track, time, d)
            end
            flash(item and "Selection dropped in the arrange"
                        or "Drop failed")
        else
            Insert.GhostCancel()
        end
    end
end

local function itemEdges()
    if state.mode ~= "item" then return nil end
    local a, b = Ops.ItemRegion(state.item, state.take)
    return xAtTime(a), xAtTime(b), a, b
end

-- "fadein" | "fadeout" | "trim_a" | "trim_b" | "sel_a" | "sel_b" | "mark", i
--
-- A transient is grabbed by its FLAG at the top, not by its line: the line
-- runs the whole height and would swallow every selection drag that happened
-- to start near one. The flag is a target you aim at, which is the whole
-- difference between a handle and a trap.
local function waveHit(mx, my)
    local top = my < wave.ry + HANDLE_BAND
    local bot = my > wave.ry + wave.rh - HANDLE_BAND
    if top then
        local fin_x, fout_x = fadeHandles()
        if fin_x and math.abs(mx - fin_x) < 7 then return "fadein" end
        if fout_x and math.abs(mx - fout_x) < 7 then return "fadeout" end
        if #state.markers > 0 and wave.w > 0 then
            local i = markerAt(timeAtX(mx), 5 * span() / wave.w)
            if i then return "mark", i end
        end
    end
    if bot then
        local xa, xb = itemEdges()
        if xa and math.abs(mx - xa) <= HANDLE_PX then return "trim_a" end
        if xb and math.abs(mx - xb) <= HANDLE_PX then return "trim_b" end
    end
    if state.sel_a then
        if math.abs(mx - xAtTime(state.sel_a)) <= 5 then return "sel_a" end
        if math.abs(mx - xAtTime(state.sel_b)) <= 5 then return "sel_b" end
    end
    return nil
end

local function waveInput(theme)
    local mx, my = Core_tk.GetMousePos()
    local inside = mx >= wave.x and mx < wave.x + wave.w
               and my >= wave.ry and my < wave.ry + wave.rh
    if Core_tk.HasPopup() then inside = false end

    -- The RULER moves the edit cursor and nothing else, exactly as REAPER's
    -- does. That is the whole point of it: you place where the next action
    -- starts without losing the range you just spent time selecting. Dragging
    -- in it scrubs the cursor along.
    local in_ruler = (not Core_tk.HasPopup())
        and mx >= wave.x and mx < wave.x + wave.w
        and my >= wave.y and my < wave.y + RULER_H
    if in_ruler then UI.SetCursor("arrow") end
    if in_ruler and Core_tk.MouseClicked(1) then state.rdrag_ruler = true end
    if state.rdrag_ruler then
        if Core_tk.MouseDown(1) then
            local t = timeAtX(mx)
            if t < 0 then t = 0 elseif t > state.len then t = state.len end
            state.cursor = waveSnap(t)
        else
            state.rdrag_ruler = nil
        end
    end

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

    -- What is under the cursor, once, for the pointer AND for the drawing
    -- (which runs before this and reads state.whot). Skipped mid-pan so the
    -- middle-drag size_all cursor wins.
    state.whot, state.whot_i = nil, nil
    if inside and not state.wpress and not Core_tk.MouseDown(64) then
        state.whot, state.whot_i = waveHit(mx, my)
        local t = timeAtX(mx)
        if state.whot == "mark" then
            UI.SetCursor(Core_tk.ModAlt() and "arrow" or "size_we")
        elseif Core_tk.ModCtrl() and state.sel_a and state.path ~= ""
               and t > state.sel_a and t < state.sel_b then
            -- the only cue that Ctrl in here drags the selection OUT
            UI.SetCursor("hand")
        else
            UI.SetCursor(state.whot and "size_we" or "ibeam")
        end
    end

    -- press: handles first, then a fresh selection.
    -- Ctrl+click PUTS a transient where you clicked, Alt+click on one removes
    -- it — direct on the object, no tool to pick up and no mode to leave. The
    -- editor has no tool palette anywhere else and should not grow one for two
    -- gestures.
    if inside and Core_tk.MouseClicked(1) then
        local k, ki = waveHit(mx, my)
        local t = timeAtX(mx)
        local in_sel = state.sel_a and t > state.sel_a and t < state.sel_b
        if k == "mark" and Core_tk.ModAlt() then
            table.remove(state.markers, ki)
            state.wpress = nil
        elseif Core_tk.ModCtrl() and in_sel and state.path ~= "" then
            -- Ctrl INSIDE the selection is a pending drag-out; released
            -- without moving it falls back to "add a transient here", which
            -- is what Ctrl+click means everywhere else on this canvas.
            state.wpress = { kind = "dragout", x = mx, y = my, t = t }
        elseif Core_tk.ModCtrl() and state.src and k ~= "mark" then
            if markerAdd(waveSnap(t)) then flash("Transient added") end
            state.wpress = nil
        elseif k then
            state.wpress = { kind = k, i = ki }
        else
            state.wpress = { kind = "sel", x = mx, t = t, moved = false }
        end
    end

    local wp = state.wpress
    if wp then
        if Core_tk.MouseDown(1) then
            local t = timeAtX(mx)
            if t < 0 then t = 0 elseif t > state.len then t = state.len end
            local k = wp.kind
            if k == "sel" then
                if wp.moved or math.abs(mx - wp.x) > 3 then
                    wp.moved = true
                    -- Snapped live, both ends, so the range you see while
                    -- dragging is the range you get on release.
                    local a, b = waveSnap(wp.t), waveSnap(t)
                    if b < a then a, b = b, a end
                    state.sel_a, state.sel_b = a, b
                end
            elseif k == "sel_a" or k == "sel_b" then
                -- Resize an existing selection instead of throwing it away and
                -- redrawing it. Crossing over swaps the ends, as any range does.
                t = waveSnap(t)
                if k == "sel_a" then state.sel_a = t else state.sel_b = t end
                if state.sel_a > state.sel_b then
                    state.sel_a, state.sel_b = state.sel_b, state.sel_a
                    wp.kind = (k == "sel_a") and "sel_b" or "sel_a"
                end
                UI.SetCursor("size_we")
            elseif k == "dragout" then
                -- Promote once the mouse has really moved: below the
                -- threshold this is still a click, and a click means
                -- something else here.
                local dx, dy = mx - wp.x, my - wp.y
                if dx * dx + dy * dy > 25 then
                    startDragOut()
                    state.wpress = nil
                end
            elseif k == "mark" then
                -- A dragged transient snaps like everything else, and is
                -- clamped between its neighbours so the list stays in order.
                markerMove(wp.i, waveSnap(t))
                UI.SetCursor("size_we")
            elseif k == "trim_a" or k == "trim_b" then
                -- The played part, resized by its edges — the same gesture as
                -- the Sampler's region, on the object the arrange owns.
                Ops.TrimEdge(state.item, state.take,
                             (k == "trim_a") and "start" or "end", t, state.len)
                UI.SetCursor("size_we")
            elseif state.mode == "item" then
                local _, _, a, b, rate = fadeHandles()
                if k == "fadein" then
                    local f = (t - a) / rate
                    if f < 0 then f = 0 end
                    Ops.SetFades(state.item, f, nil)
                else
                    local f = (b - t) / rate
                    if f < 0 then f = 0 end
                    Ops.SetFades(state.item, nil, f)
                end
                UI.SetCursor("size_we")
            end
        else
            -- release
            -- Zero-crossing snap only when the GRID is off: the two would
            -- fight, and a selection nudged off the beat it was just snapped
            -- to is worse than either rule on its own.
            local zsnap = opts.snap_zero and not opts.wave_snap and state.src
            local k = wp.kind
            if k == "sel" then
                if not wp.moved then
                    -- A CLICK places the edit cursor and leaves the time
                    -- selection alone — only a DRAG changes a selection, which
                    -- is REAPER's rule. Losing a range you spent time on
                    -- because you clicked somewhere to listen was the whole
                    -- complaint. ESC still clears it.
                    state.cursor = waveSnap(wp.t)
                elseif zsnap then
                    state.sel_a = Ops.SnapZero(state.src, state.sel_a)
                    state.sel_b = Ops.SnapZero(state.src, state.sel_b)
                end
            elseif k == "sel_a" or k == "sel_b" then
                if zsnap then
                    state.sel_a = Ops.SnapZero(state.src, state.sel_a)
                    state.sel_b = Ops.SnapZero(state.src, state.sel_b)
                end
            elseif k == "trim_a" or k == "trim_b" then
                Ops.CommitTrim()
            elseif k == "mark" then
                -- markers live in this window, not in the project: nothing to
                -- commit, and no undo point to invent
            elseif k == "dragout" then
                -- never left the spot: it was a Ctrl+click after all
                if markerAdd(waveSnap(wp.t)) then flash("Transient added") end
            else
                Ops.CommitFades()
            end
            state.wpress = nil
        end
    end

    -- right-click context
    if inside and Core_tk.MouseClicked(2) then
        local t = timeAtX(mx)
        local mi = (#state.markers > 0 and wave.w > 0)
                   and markerAt(t, 5 * span() / wave.w) or nil
        UI.NativeMenu({
            { label = "Fit (Home)", action = fitView },
            { label = "Zoom to selection", disabled = state.sel_a == nil,
              action = zoomSelection },
            { separator = true },
            { label = "Add transient here  (Ctrl+click, or M at the cursor)",
              disabled = state.src == nil,
              action = function() markerAdd(waveSnap(t)) end },
            { label = "Remove this transient  (Alt+click)", disabled = mi == nil,
              action = function() table.remove(state.markers, mi) end },
            { label = "Clear all transients", disabled = #state.markers == 0,
              action = clearMarkers },
            { separator = true },
            { label = "Clear selection", disabled = state.sel_a == nil,
              action = function() state.sel_a, state.sel_b = nil, nil end },
            { separator = true },
            { label = "Snap to transients", checked = opts.snap_trans,
              action = function() opts.snap_trans = not opts.snap_trans markDirty() end },
            { label = "Snap to zero crossings (when the grid is off)",
              checked = opts.snap_zero,
              action = function() opts.snap_zero = not opts.snap_zero markDirty() end },
        })
    end
end

local function drawWave(theme, area_h)
    local gx, gy = UI.GetCursorPos()
    local aw = UI.GetAvailableWidth()
    wave.x, wave.y, wave.w, wave.h = gx, gy, aw, area_h
    wave.ry, wave.rh = gy + RULER_H, area_h - RULER_H

    -- Named canvas colours here too: the waveform view is the same kind of
    -- surface as the roll, and it had the same nameless × 0.8 ruler.
    local C        = theme.colors
    local col_bg   = C.canvas_bg
    local col_mute = C.text_mute or C.text_disabled
    local col_acc  = C.canvas_item
    local col_text = C.text
    local col_mark = C.value_modified or col_acc
    local col_edge = C.border

    -- ruler strip, with its own edge
    local cr = C.canvas_ruler
    Core_tk.DrawRect(gx, gy, aw, RULER_H, cr[1], cr[2], cr[3], 1)
    Core_tk.DrawRect(gx, gy + RULER_H - 1, aw, 1,
                     col_edge[1], col_edge[2], col_edge[3], col_edge[4] or 1)

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

    local entry = Peaks.Read(state.src, state.path, state.t0, state.t1,
                            aw * SS, state.gen)
    if entry then
        renderWave(theme, entry, aw, wave.rh)
        gfx.dest = -1
        gfx.a = 1
        local om = gfx.mode
        gfx.mode = 4        -- filtered: the SSx bake downsamples smooth
        gfx.blit(WAVE_BUF, 1, 0, 0, 0, aw * SS, wave.rh * SS,
                 gx, wave.ry, aw, wave.rh)
        gfx.mode = om
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

    -- The musical grid, shown only when it is what the mouse obeys — a grid
    -- drawn while snapping is off is a promise the editor does not keep.
    -- Two weights: the bar carries, the division follows.
    if opts.wave_snap then
        wgridBuild()
        for i = 1, wgrid.n do
            local x = wgrid.xs[i]
            Core_tk.DrawRect(x, wave.ry, 1, wave.rh,
                             col_mute[1], col_mute[2], col_mute[3],
                             wgrid.bar[i] and 0.28 or 0.11)
            if wgrid.bar[i] then
                Core_tk.DrawRect(x, gy + RULER_H - 8, 1, 8,
                                 col_mute[1], col_mute[2], col_mute[3], 0.6)
            end
        end
    end

    -- Which handle is lit. `whot` is the hover the input pass found LAST
    -- frame; `wpress` is the one being held. Drawing runs before input, so a
    -- one-frame-old hover is the only honest answer — and at 30 fps nobody
    -- has ever seen the difference.
    local hot  = (state.wpress and state.wpress.kind) or state.whot
    local held = state.wpress and state.wpress.kind or nil

    -- item region bounds + dim outside + the edges you can drag
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
            local g = handleGrow(hot == "fadein", held == "fadein")
            Core_tk.DrawRect(fin_x - 3 - g * 0.5, wave.ry, 7 + g, 7 + g,
                             col_text[1], col_text[2], col_text[3],
                             (hot == "fadein") and 1 or 0.9)
        end
        if fout_x then
            local g = handleGrow(hot == "fadeout", held == "fadeout")
            Core_tk.DrawRect(fout_x - 3 - g * 0.5, wave.ry, 7 + g, 7 + g,
                             col_text[1], col_text[2], col_text[3],
                             (hot == "fadeout") and 1 or 0.9)
        end
        -- Region edges, with grips at the BOTTOM so they never argue with the
        -- fade grips at the top. Dragging one resizes what actually plays.
        -- Text colour, like the fades: both are the ITEM's geometry, and the
        -- accent belongs to the editor's own selection. Two families, two
        -- colours, and no guessing which handle you are about to grab.
        local ec = col_text
        for i = 1, 2 do
            local k  = (i == 1) and "trim_a" or "trim_b"
            local hx = (i == 1) and xa or xb
            if hx > gx - 8 and hx < gx + aw + 8 then
                local lit = (hot == k)
                local g = handleGrow(lit, held == k)
                local ca = lit and 1 or 0.55
                Core_tk.DrawRect((i == 1) and hx or (hx - 1), wave.ry, 1,
                                 wave.rh, ec[1], ec[2], ec[3], ca)
                local gw, gh = 5 + g, 10 + g
                Core_tk.DrawRect((i == 1) and hx or (hx - gw),
                                 wave.ry + wave.rh - gh, gw, gh,
                                 ec[1], ec[2], ec[3], lit and 1 or 0.8)
            end
        end
    end

    -- selection
    if state.sel_a then
        local xa, xb = xAtTime(state.sel_a), xAtTime(state.sel_b)
        if xb > gx and xa < gx + aw then
            Core_tk.DrawRect(math.max(xa, gx), wave.ry,
                             math.min(xb, gx + aw) - math.max(xa, gx), wave.rh,
                             col_acc[1], col_acc[2], col_acc[3], 0.20)
            for i = 1, 2 do
                local k  = (i == 1) and "sel_a" or "sel_b"
                local hx = (i == 1) and xa or xb
                local lit = (hot == k)
                local g = handleGrow(lit, held == k)
                Core_tk.DrawRect(hx, wave.ry, 1 + (g > 0 and 1 or 0), wave.rh,
                                 col_acc[1], col_acc[2], col_acc[3],
                                 lit and 1 or 0.9)
                if lit then
                    Core_tk.DrawRect(hx - 2, wave.ry + wave.rh * 0.5 - 8 - g,
                                     5 + g, 16 + g * 2,
                                     col_acc[1], col_acc[2], col_acc[3], 1)
                end
            end
        end
    end

    -- Transient markers. The FLAG is the handle — it lights and grows like
    -- every other one — and the line is only the reading of where it sits.
    local hot_i = (state.wpress and state.wpress.kind == "mark")
                  and state.wpress.i
                  or ((hot == "mark") and state.whot_i or nil)
    for i = 1, #state.markers do
        local t = state.markers[i]
        if t >= state.t0 and t <= state.t1 then
            local x = xAtTime(t)
            local lit = (i == hot_i)
            local g = handleGrow(lit, held == "mark" and lit)
            Core_tk.DrawRect(x, wave.ry, 1, wave.rh,
                             col_mark[1], col_mark[2], col_mark[3],
                             lit and 1 or 0.7)
            UI.DrawTriangle(x - 4 - g, wave.ry, x + 4 + g, wave.ry,
                            x, wave.ry + 6 + g,
                            col_mark[1], col_mark[2], col_mark[3],
                            lit and 1 or 0.9)
        end
    end

    -- edit cursor
    if state.cursor >= state.t0 and state.cursor <= state.t1 then
        local x = xAtTime(state.cursor)
        Core_tk.DrawRect(x, wave.ry, 1, wave.rh,
                         col_text[1], col_text[2], col_text[3], 0.8)
    end

    -- Play cursor: our preview, or the arrange's transport over this item.
    -- `pending` is the theme's play-cursor token, taken from REAPER's own —
    -- so the line here is the same colour as the one moving in the arrange,
    -- and it is not the accent the selection already speaks with.
    local pt = playCursorTime()
    if pt then
        if pt >= state.t0 and pt <= state.t1 then
            local pc = C.pending or col_acc
            Core_tk.DrawRect(xAtTime(pt), wave.ry, 1, wave.rh,
                             pc[1], pc[2], pc[3], 1)
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

-- LA PISTE QUI DOIT SONNER. Un piano roll n'a pas d'instrument a lui : il
-- montre des notes qui alimentent quelque chose, et c'est ce quelque chose
-- qu'on veut entendre. Deux cas, tous deux sans ambiguite :
--   · une prise MIDI  -> la piste de son item ;
--   · une case/lane   -> la piste de destination de sa colonne.
-- Rien d'autre ne sonne. C'est volontaire : jouer « quelque part » etait
-- exactement le probleme qu'on vient de retirer, et un silence explicable vaut
-- mieux qu'un son dont personne ne sait d'ou il sort.
local function auditionTrack()
    if state.item and r.ValidatePtr2(0, state.item, "MediaItem*") then
        return r.GetMediaItemTrack(state.item)
    end
    -- Pas de `loopInit()` ici, et c'est important : il rebranche les ports des
    -- colonnes, ce qui COUPE ce qu'ils portaient. Le faire depuis une audition,
    -- c'est-a-dire pendant qu'on joue, taillerait dans le son de la session.
    -- Il n'y a rien a initialiser de toute facon : `clip_track` n'est pose que
    -- par le chemin d'ouverture d'un clip, qui l'a deja appele.
    if state.mode == "clip" and state.clip_track then
        return Loop.GetLaneDest(state.clip_lane or state.clip_track)
    end
    return nil
end

local function auditionNote(pitch, vel)
    if not opts.audition then return end
    Notes.SetTrack(auditionTrack())
    if state.aud_note then Notes.Off(state.aud_note) end
    Notes.On(pitch, vel or state.last_vel)
    state.aud_note = pitch
    state.aud_off_t = r.time_precise() + 0.2
end

-- ---------------------------------------------------------------------------
-- Project-grid snap (QN domain — tempo changes respected)
-- `gridStepQN` lives with the view helpers now: the waveform snaps to the same
-- grid as the roll, and it is drawn much earlier in this file.
-- ---------------------------------------------------------------------------

-- Roll time mapping. Item-backed modes: the cache unit is item-relative
-- SECONDS, mapped through the project TimeMap (tempo maps respected).
-- Clip mode: the cache unit IS beats (QN) — identity mapping.
local function rollToQN(t)
    if state.mode == "clip" then return t end
    return r.TimeMap2_timeToQN(0, itemPos() + t)
end

local function qnToRoll(qn)
    if state.mode == "clip" then return qn end
    return r.TimeMap2_QNToTime(0, qn) - itemPos()
end

local function midiSnap(t)
    if not opts.midi_snap then return t end
    local step = gridStepQN()
    local qn = math.floor(rollToQN(t) / step + 0.5) * step
    local nt = qnToRoll(qn)
    if nt < 0 then nt = 0 end
    return nt
end

-- Cell snap (FL insert semantics): the note lands in the cell UNDER the
-- cursor — round-to-nearest used to push clicks into the NEXT cell.
local function midiSnapFloor(t)
    if not opts.midi_snap then return t end
    local step = gridStepQN()
    local qn = math.floor(rollToQN(t) / step + 0.0001) * step
    local nt = qnToRoll(qn)
    if nt < 0 then nt = 0 end
    return nt
end

-- One grid step, in cache units, around time t.
local function gridStepSec(t)
    local qn = rollToQN(t)
    return qnToRoll(qn + gridStepQN()) - t
end

-- Context handed to the shared RollUI (keyboard map + transform menu).
-- Every amount is in the roll's cache unit: item-relative seconds for a
-- take, beats for a clip — the rollToQN/qnToRoll pair hides which.
local midiCtx = {
    Roll = Roll, Keys = Keys,
    -- Declarer le vocabulaire fait passer RollUI par Keymap ; sans ces deux
    -- champs il retombe sur sa table historique, ce qui est exactement ce dont
    -- CP_Looper a besoin tant qu'il n'a pas declare la sienne.
    Keymap = Keymap, keymap = KM,
    Shift = Core_tk.ModShift, Ctrl = Core_tk.ModCtrl, Alt = Core_tk.ModAlt,
    flash = flash,
    audition = function(p, v) auditionNote(p, v) end,
    gridStep = function(t) return gridStepSec(t) end,
    snap = function(t) return midiSnap(t) end,
    divToUnit = function(div)
        local t0 = (Roll.sel and Roll.starts[Roll.sel]) or 0
        local qn = rollToQN(t0)
        return qnToRoll(qn + div * 4) - qnToRoll(qn)
    end,
    -- ON COLLE AU CURSEUR, y compris dans une case — c'est precisement ce que
    -- le curseur local rend possible. Il rendait 0 jusqu'ici, donc tout collage
    -- retombait au debut de la boucle, quelle que soit l'intention.
    pasteAt = function() return editCursor() end,
    -- Bar boundaries. Item mode goes through the measure map (tempo maps
    -- and odd meters come out right); clip mode is plain beat arithmetic
    -- on the project time signature.
    barFloor = function(t)
        local qn = rollToQN(t)
        if state.mode == "clip" then
            local tsn = clipTsNum()
            local nt = math.floor(qn / tsn) * tsn
            return nt < 0 and 0 or nt
        end
        local _, ms = r.TimeMap_QNToMeasures(0, qn + 1e-6)
        if not ms then return t end
        local nt = qnToRoll(ms)
        return nt < 0 and 0 or nt
    end,
    barCeil = function(t)
        local qn = rollToQN(t)
        if state.mode == "clip" then
            local tsn = clipTsNum()
            local m = math.floor(qn / tsn)
            -- already sitting on a barline: that bar IS the answer
            if qn - m * tsn < 1e-4 then return m * tsn end
            return (m + 1) * tsn
        end
        local _, ms, me = r.TimeMap_QNToMeasures(0, qn + 1e-6)
        if not ms then return t end
        -- already sitting on a barline: that bar IS the answer, don't skip ahead
        local qb = (qn <= ms + 1e-6) and ms or (me or ms)
        local nt = qnToRoll(qb)
        return nt < 0 and 0 or nt
    end,
    swingSnap = function(amt)
        return function(t)
            local step = gridStepQN()
            local qn = rollToQN(t)
            local idx = math.floor(qn / step + 0.5)
            local base = idx * step
            if idx % 2 == 1 then base = base + step * amt end
            local nt = qnToRoll(base)
            return nt < 0 and 0 or nt
        end
    end,
}

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

-- ---------------------------------------------------------------------------
-- Rows (event-driven build; drum mode shows pad rows named after the kit)
-- ---------------------------------------------------------------------------
local mrows = { list = {}, map = {}, n = 0, drum = false, key = nil }

-- The instrument THIS clip plays into, as a pad map — or nil when it is not a
-- CP kit. Asking the target rather than reaching for the Sampler's global kit
-- is what stops a clip routed to a synth from being drawn with someone else's
-- drum pads listed under its own notes.
local function clipKit()
    if state.mode == "clip" then
        if state.clip_lane and state.loop_att then
            return Loop.KitViewOfTrack(Loop.GetLaneDest(state.clip_lane))
        end
        return nil
    end
    if state.item then
        return Loop.KitViewOfTrack(r.GetMediaItem_Track(state.item))
    end
    return nil
end

-- Row labels, cut to the lane width. Cached against (text, width) because
-- truncation allocates and this runs once per visible row per frame.
local row_lbl = {}
local function rowLabel(rows, p, kv, w)
    local raw = Rows.Label(rows, p, kv)
    local c = row_lbl[p]
    if not c then c = {}; row_lbl[p] = c end
    if c.src ~= raw or c.w ~= w then
        c.src, c.w = raw, w
        c.s = Core_tk.TruncateText(raw, w)
    end
    return c.s
end

-- LA PLAGE VOYAGE JUSQU'A ROLL, une fois par frame. Deux nombres : c'est moins
-- cher que de le demander a chaque operation, et surtout ca ne peut pas etre
-- OUBLIE par une operation ajoutee plus tard.
local function syncRange()
    if state.mode ~= "midi" and state.mode ~= "clip" then
        Roll.SetRange(nil, nil)
        return
    end
    Roll.SetRange(timeSel())
end

local function rollRows()
    -- LE CLIP S'OUVRE DANS LA VUE DE CE QU'IL JOUE. Une batterie se regarde en
    -- rangees de pads, un instrument chromatique en clavier — et « il y a un
    -- kit sous la cible » ne suffisait pas a les distinguer, puisqu'un
    -- instrument EST un kit depuis le chantier 2 (un kit d'un seul pad, sur sa
    -- propre piste). On ouvrait donc chaque clip d'instrument avec une seule
    -- rangee nommee, sur laquelle aucune melodie ne s'ecrit.
    --
    -- Le genre se lit sur la piste du kit (P_EXT:CP_KIT_MODE) et voyage dans
    -- la vue. Le bouton Drum reste le dernier mot : ce qui change ici, c'est
    -- ce qu'on trouve en ouvrant, pas ce qu'on a le droit de demander.
    local kit = clipKit()
    local drum = state.drum_mode
    if drum == nil then
        drum = kit ~= nil and kit.mode ~= "instrument"
    end
    -- the row model itself is shared with CP_Looper (Engine/Rows), so drum
    -- rows and the melodic window behave identically in both editors
    local m = Rows.Build(mrows, {
        drum = drum, roll = Roll, kit = kit,
        view_hi = state.view_hi, view_rows = state.view_rows,
    })
    if not drum then
        state.view_hi, state.view_rows = m.view_hi, m.view_rows
    end
    return m
end

-- ---------------------------------------------------------------------------
-- Toolbar row (MIDI mode)
-- ---------------------------------------------------------------------------
-- Widget option tables, hoisted: built inline they would allocate per frame.
-- `w` is a step on the bar's width ladder, not a pixel count — that is what
-- keeps a dropdown the same width as the one three controls along.
local BARS_ITEMS  = { "1 bar", "2 bars", "4 bars", "8 bars", "16 bars", "32 bars" }
local BARS_VALS   = { 1, 2, 4, 8, 16, 32 }

-- MIDI / clip bar. GRID and VIEW hold state, EDIT holds the two gestures used
-- often enough to deserve a permanent home; everything rarer lives in the
-- Transform menu or the roll's own right-click.
local V_VEL = { w = 3, default = 100 }

local function barMidi(theme)
    local R = roles(theme)
    if UI.BarToggle("m_snap", "Magnet", nil, opts.midi_snap, "Snap to grid") then
        opts.midi_snap = not opts.midi_snap
        markDirty()
    end
    -- A real COMBO, not a button that opens a menu. The mousewheel walks the
    -- divisions without opening anything, which is the gesture that was
    -- missing — and triplets are just two more entries in the list, so nothing
    -- had to be given up to get it.
    local idx = 1
    for i = 2, #GRID_ITEMS do
        if opts.grid_div and math.abs(opts.grid_div - GRID_VALS[i]) < 1e-9 then
            idx = i break
        end
    end
    local gch, gi = UI.BarCombo("m_grid", idx, GRID_ITEMS, false, GRID_BAR_OPTS)
    if gch then
        opts.grid_div = (gi == 1) and nil or GRID_VALS[gi]
        grid_lbl.div = -1
        markDirty()
    end
    UI.BarSep()

    local rows = rollRows()
    if UI.BarToggle("m_drum", "Drum", nil, rows.drum, "Drum rows") then
        state.drum_mode = not rows.drum
        mrows.key = nil
    end
    if UI.BarToggle("m_names", "Note", nil, opts.note_names, "Note names") then
        opts.note_names = not opts.note_names
        markDirty()
    end
    -- Icon PAIR rather than a tick: a speaker with and without sound says
    -- which way this is set without reading a label (ANALYSE_Nomenclature).
    if UI.BarToggle("m_aud", "VolumeUp", "VolumeOff", opts.audition, "Listen") then
        opts.audition = not opts.audition
        -- a note may be sounding right now: do not strand it
        if not opts.audition and state.aud_note then
            Notes.Off(state.aud_note)
            state.aud_note = nil
        end
        markDirty()
    end
    UI.BarSep()

    local vch, nv = UI.BarValue("m_vel", "Vel", state.last_vel, 1, 127, false, V_VEL)
    if vch then
        state.last_vel = math.floor(nv + 0.5)
        markDirty()
    end
    if UI.BarIcon("m_quant", "Magnet", "Quantize") then
        local n = Roll.Quantize(midiSnap)
        flash(n .. " notes quantized" .. (Roll.sel and " (selected)" or ""))
    end
    if UI.BarIcon("m_transform", "Wand", "Transform") then
        UI.NativeMenu(RollUI.TransformMenu(midiCtx))
    end
    if state.item then   -- take-backed only (a clip has no native editor)
        if UI.BarIcon("m_native", "Piano", "Open in REAPER's MIDI editor") then
            r.SelectAllMediaItems(0, false)
            r.SetMediaItemSelected(state.item, true)
            r.Main_OnCommand(40153, 0)   -- Item: open in built-in MIDI editor
        end
    end

    -- LOOP (clip mode): the lane's own transport. The editor stands in for
    -- the Looper's lane editor completely — Session cells are only editable
    -- here — so length and play/stop have to live here too.
    if state.mode == "clip" and state.clip then
        UI.BarSep()
        local bars = math.floor((state.clip.bars or 4) + 0.5)
        -- A combo, not two nudge buttons: six named lengths, and the wheel
        -- walks them without opening anything.
        local bidx = 1
        for i = 1, #BARS_VALS do if BARS_VALS[i] == bars then bidx = i break end end
        local bch, bi = UI.BarCombo("c_bars", bidx, BARS_ITEMS, false, GRID_BAR_OPTS)
        if bch and BARS_VALS[bi] ~= bars then setClipBars(BARS_VALS[bi]) end
        if state.clip_track then
            local att = state.loop_att
            local lane = state.clip_lane
            local m = (att and lane) and math.floor(Loop.Mode(lane) + 0.5) or 0
            local p = (att and lane) and Loop.Pending(lane) or 0
            if not att then
                UI.BarIcon("c_play", "Power", "Engine off", true)
            elseif m == 1 or m == 4 or p == 3 or p == 4 then
                -- recording/armed: the Session owns that transport
                UI.BarToggle("c_play", "Mic", nil, true,
                             m == 4 and "Armed" or "Recording", false, R.rec)
            else
                -- nil lane = the engine is not holding this clip any more (its
                -- lane went to another cell): Play stages it back in and
                -- launches, same gesture, same result.
                local run = (m == 3 or m == 5)
                local lbl = run and "Stop" or "Play"
                if p == 1 then lbl = "Play…" elseif p == 2 then lbl = "Stop…" end
                if UI.BarToggle("c_play", "Stop", "Play", run or p > 0, lbl, false,
                                (p == 1 or p == 2) and R.pend or R.play) then
                    clipLaunch()
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Roll view: grid buffer + notes + labels lane + velocity lane
-- ---------------------------------------------------------------------------
local wbm = { t0 = -1, t1 = -1, w = 0, h = 0, rows = nil, step = 0 }

-- Grid line COLOURS: bar > beat > subdivision > fine. Four theme tokens at
-- full alpha, not one colour faded four ways. Fading was the defect: the
-- strongest line, the barline, was text_mute at 45 % — composited over the
-- ground it landed near 0.27, so the thing meant to cut the view the hardest
-- was the thing you could least see. A hierarchy has to be carried by the
-- values themselves, or the weakest end of it disappears into the floor.
-- Filled per frame from the theme; module-level so nothing allocates.
local GRID_COL = { nil, nil, nil, nil }

-- One vertical gridline at a QN position. Module level on purpose: a closure
-- built inside the render would allocate on every cache miss, and a cache
-- miss is every frame while the view is being dragged.
local function gridLine(qn, tier, sp, w, h)
    local t = qnToRoll(qn)
    if t < state.t0 or t > state.t1 then return end
    -- floored like the notes, so a note edge and its gridline share a column
    -- instead of straddling two
    local x = math.floor((t - state.t0) / sp * w)
    local c = GRID_COL[tier]
    -- The token carries its own alpha now. Three of the four tiers are laid
    -- in black over the row, so their weight stays constant whichever row
    -- they cross; forcing 1 here made them opaque and flattened the
    -- hierarchy back into four near-identical greys.
    gfx.set(c[1], c[2], c[3], c[4] or 1)
    gfx.line(x, 0, x, h - 1)
end

local function renderRollGrid(theme, rows, w, h, row_h)
    local step = gridStepQN()
    local ctsn = state.mode == "clip" and clipTsNum() or 0
    -- Item mode maps QN through the project, so editing the tempo map or
    -- dragging the item moves every line with no change to t0/t1/step to
    -- notice it by. The view edges IN QN do change, and they cost two
    -- TimeMap calls — far cheaper than keying on the project state counter,
    -- which every note drag bumps and which would rebuild this buffer on
    -- every frame of a drag.
    local qn0, qn1 = rollToQN(state.t0), rollToQN(state.t1)
    if wbm.t0 == state.t0 and wbm.t1 == state.t1 and wbm.w == w
       and wbm.h == h and wbm.rows == rows.key and wbm.step == step
       and wbm.ctsn == ctsn and wbm.qn0 == qn0 and wbm.qn1 == qn1
       and wbm.sver == Roll.scale_ver then
        return
    end
    wbm.t0, wbm.t1, wbm.w, wbm.h = state.t0, state.t1, w, h
    wbm.rows, wbm.step, wbm.sver = rows.key, step, Roll.scale_ver
    wbm.ctsn, wbm.qn0, wbm.qn1 = ctsn, qn0, qn1

    gfx.dest = MROLL_BUF
    gfx.setimgdim(MROLL_BUF, w, h)
    gfx.muladdrect(0, 0, w, h, 0, 0, 0, 0)
    local C = theme.colors
    -- Rows are PAINTED, each in its own colour, instead of the ground being
    -- covered by a black wash. A wash can only go one way — down — and on a
    -- dark ground it has almost nowhere to go, which is why the alternation
    -- was there in the code and invisible on screen. Two named colours that
    -- straddle the ground separate at any theme brightness.
    local cw, cd = C.canvas_row, C.canvas_row_dark
    for i = 1, rows.n do
        local p = rows.list[i]
        local dark = rows.drum and (i % 2 == 0) or BLACK_KEY[p % 12]
        local c = dark and cd or cw
        gfx.set(c[1], c[2], c[3], 1)
        gfx.rect(0, (i - 1) * row_h, w, row_h + 1, 1)
    end
    -- out of the current scale: its own colour, not a second wash on top
    if Roll.scale_on then
        local co = C.canvas_row_off
        gfx.set(co[1], co[2], co[3], 1)
        for i = 1, rows.n do
            if not Roll.InScale(rows.list[i]) then
                gfx.rect(0, (i - 1) * row_h, w, row_h + 1, 1)
            end
        end
    end
    -- row separators
    if row_h >= 7 then
        local mc = C.canvas_line_fine
        gfx.set(mc[1], mc[2], mc[3], 1)
        for i = 1, rows.n - 1 do
            gfx.line(0, i * row_h, w - 1, i * row_h)
        end
    end
    -- Vertical grid, drawn in passes from weakest to strongest: subdivisions,
    -- eighths, beats, barlines. LAYERING instead of classifying is what makes
    -- odd meters and tempo maps come out right — a barline no longer has to
    -- LAND on the subdivision lattice to appear, it comes from the measure
    -- map itself, and each pass simply overwrites the previous at the same x
    -- so the strongest weight always wins.
    -- Four canvas tokens, and CP_Looper's roll reads the same four: the two
    -- rolls used to derive their lines separately, so a barline changed shade
    -- depending on which window you were looking at.
    GRID_COL[1] = C.canvas_line_bar
    GRID_COL[2] = C.canvas_line_beat
    GRID_COL[3] = C.canvas_line_sub
    GRID_COL[4] = C.canvas_line_fine
    local sp = span()
    -- What "a beat" is. Item mode takes the real meter, so 6/8 tiers on its
    -- eighths instead of on quarter notes; clip mode keeps the ENGINE's
    -- convention (a loop's beats are quarter notes and its bar is TsNum of
    -- them) because that is what LenBeats and the bar buttons mean.
    local beatQN = 1
    if ctsn == 0 then
        local _, den = r.TimeMap_GetTimeSigAtTime(0, itemPos() + state.t0)
        if den and den > 0 then beatQN = 4 / den end
    end

    -- pass 1 — the grid's own subdivisions: exactly the positions snapping
    -- uses, so a triplet grid draws triplet lines and nothing is culled
    do
        local i0 = math.floor(qn0 / step)
        local n  = math.floor((qn1 - qn0) / step) + 2
        if n > 4096 then n = 4096 end            -- absurd zoom, not a grid
        for i = 0, n do gridLine((i0 + i) * step, 4, sp, w, h) end
    end
    -- pass 2 — eighths, only once the working resolution is at least that
    -- fine (showing halves of a beat under a 1/4 grid is noise, not help) AND
    -- the eighth actually sits on the grid's lattice. On a 1/8-triplet grid it
    -- does not: drawing it anyway would make the ONE line you cannot snap to
    -- the brightest of the three between beats.
    local half = beatQN * 0.5
    local mult = half / step
    if step <= half + 1e-9
       and math.abs(mult - math.floor(mult + 0.5)) < 1e-6 then
        local i0 = math.floor(qn0 / half)
        local n  = math.floor((qn1 - qn0) / half) + 2
        if n > 2048 then n = 2048 end
        for i = 0, n do gridLine((i0 + i) * half, 3, sp, w, h) end
    end
    -- pass 3 — beats. Drawn whatever the grid division: at 1/1 the grid alone
    -- shows nothing between barlines, and "where is beat 3" is exactly what
    -- the eye is hunting for.
    do
        local i0 = math.floor(qn0 / beatQN)
        local n  = math.floor((qn1 - qn0) / beatQN) + 2
        if n > 1024 then n = 1024 end
        for i = 0, n do gridLine((i0 + i) * beatQN, 2, sp, w, h) end
    end
    -- pass 4 — barlines, from the measure map in item mode so a tempo map or
    -- a meter change puts them where the ruler says they are
    if ctsn > 0 then
        local i0 = math.floor(qn0 / ctsn)
        local n  = math.floor((qn1 - qn0) / ctsn) + 2
        for i = 0, n do gridLine((i0 + i) * ctsn, 1, sp, w, h) end
    else
        local _, ms = r.TimeMap_QNToMeasures(0, qn0 + 1e-6)
        local q = ms or qn0
        local guard = 0
        while q <= qn1 and guard < 512 do
            guard = guard + 1
            gridLine(q, 1, sp, w, h)
            local _, _, me = r.TimeMap_QNToMeasures(0, q + 1e-6)
            -- never stall: a degenerate measure would spin this loop
            q = (me and me > q) and me or (q + 4)
        end
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

-- Snapshot the current selection's original start/pitch/length (group
-- move + group resize both read from this).

-- LE VOCABULAIRE DE GESTES vit dans CP_Engine/Keymaps/editor.lua — dehors,
-- pour que la fenetre de reglages puisse le lire. Elle est un autre etat Lua :
-- ce que ce script enregistre chez lui, elle ne le voit pas.
local KM = "editor"
Keymap.Register(KM, dofile(cp_root .. "CP_Engine/Keymaps/editor.lua"))

-- LA MESURE QUI CONTIENT CET INSTANT, en unites de cache. Le mode case n'a pas
-- de position dans le projet : sa mesure se compte a partir de son beat zero,
-- avec la signature que le moteur annonce. Un take, lui, demande a REAPER,
-- parce que le projet peut changer de signature en cours de route et que la
-- mesure « quatre beats » serait alors fausse.
-- LIRE A PARTIR D'ICI. Une case qui joue repart de l'endroit clique : le
-- moteur porte un decalage de phase par lane (ABI 1.9), et un decalage
-- CONSTANT ne casse pas le verrouillage de la grille — il le deplace. La lane
-- reste calee, a distance fixe, et rien ne derive.
--
-- On n'appelle PAS ceci a chaque frame d'un glisser : chaque appel fait
-- rentrer la voix audio au nouvel endroit, et soixante rentrees par seconde
-- s'entendent comme un bourdonnement. Une fois a la prise, une fois au
-- relachement — c'est ce qu'on entend d'un scrub, et c'est tout ce qu'il faut.
local function scrubTo(t)
    if not opts.ruler_scrub then return end
    if state.mode ~= "clip" or not state.clip_lane or not state.loop_att then
        return
    end
    local m = math.floor((Loop.Mode(state.clip_lane) or 0) + 0.5)
    if m ~= 3 and m ~= 5 then return end     -- seule une case qui SONNE se deplace
    Loop.PlayClipFrom(state.clip_lane, math.max(0, t))
end

local function measureAround(t)
    if state.mode == "clip" then
        local n = clipTsNum()
        local m = math.floor(t / n)
        return m * n, (m + 1) * n
    end
    local pt = itemPos() + t
    local _, meas = r.TimeMap2_timeToBeats(0, pt)
    local a = r.TimeMap2_beatsToTime(0, 0, meas)
    local b = r.TimeMap2_beatsToTime(0, 0, meas + 1)
    return a - itemPos(), b - itemPos()
end

-- Le DEBUT du groupe vise : le point fixe d'un etirement. Il ne peut pas etre
-- la note qu'on a attrapee — etirer depuis elle deplacerait tout le reste sous
-- la main sans que rien ne tienne.
local function spanStart()
    local a = math.huge
    if Roll.seln > 0 then
        for i in pairs(Roll.selset) do
            if Roll.starts[i] < a then a = Roll.starts[i] end
        end
    else
        for i = 1, Roll.count do
            if Roll.starts[i] < a then a = Roll.starts[i] end
        end
    end
    return (a < math.huge) and a or 0
end

-- ---------------------------------------------------------------------------
-- L'ASCENSEUR VERTICAL DU PIANO ROLL
-- ---------------------------------------------------------------------------
-- La molette faisait defiler et zoomer depuis toujours, et ca reste le geste
-- rapide. Mais un ascenseur dit deux choses qu'aucune molette ne dit : OU on
-- est dans les cent vingt-huit hauteurs, et COMBIEN on en voit. Sans lui on
-- roule jusqu'a retrouver ses notes.
--
-- Les deux boutons ne font pas defiler, ils ZOOMENT — c'est ce qui manquait le
-- plus : le zoom vertical n'etait accessible qu'a la molette avec Ctrl, donc
-- invisible. `+` resserre la fenetre sur moins de rangees, `-` l'ouvre.
local SBAR_W = 14
local SBAR_BTN = 14

-- Le signe pose a cote du pointeur pour les gestes que le curseur systeme ne
-- sait pas dire.
local HINT_GLYPH = { copy = "+", erase = "x", stretch = "<>", draw = "/" }

local function drawVScroll(theme, x, y, w, h)
    local C = theme.colors
    local col_tr = C.list_alt_bg or C.surface
    local col_th = C.text_mute or C.text_disabled
    local col_ed = C.border
    local col_ac = C.accent

    local vrows = state.view_rows or 30
    local vhi = state.view_hi or 71
    local vlo = vhi - vrows + 1

    local mx, my = Core_tk.GetMousePos()
    local over = mx >= x and mx < x + w
    local down = Core_tk.MouseDown(1)
    local click = Core_tk.MouseClicked(1)

    Core_tk.DrawRect(x, y, w, h, col_tr[1], col_tr[2], col_tr[3], 0.5)
    Core_tk.DrawRect(x, y, 1, h, col_ed[1], col_ed[2], col_ed[3], 0.6)

    -- Les deux boutons, aux extremites. Le zoom est BORNE des deux cotes : six
    -- rangees en dessous on ne voit plus assez pour jouer, cent au-dessus les
    -- notes deviennent des traits.
    local ty, by = y, y + h - SBAR_BTN
    local hot_t = over and my >= ty and my < ty + SBAR_BTN
    local hot_b = over and my >= by and my < by + SBAR_BTN
    for _, b in ipairs({ { ty, "+", hot_t }, { by, "-", hot_b } }) do
        if b[3] then
            Core_tk.DrawRect(x + 1, b[1], w - 2, SBAR_BTN,
                             col_ac[1], col_ac[2], col_ac[3], 0.3)
        end
        Core_tk.DrawText(b[2], x + (w - 5) * 0.5, b[1] + 2,
                         col_th[1], col_th[2], col_th[3], 1)
    end
    if click and (hot_t or hot_b) then
        local ns = math.floor(vrows * (hot_t and 0.8 or 1.25) + 0.5)
        if ns < 6 then ns = 6 elseif ns > 100 then ns = 100 end
        -- ON ZOOME AUTOUR DU CENTRE DE LA VUE, pas autour de son bord : zoomer
        -- par le haut ferait fuir ce qu'on regarde vers le bas a chaque clic.
        local mid = vhi - (vrows - 1) * 0.5
        local nhi = math.floor(mid + (ns - 1) * 0.5 + 0.5)
        if nhi > 127 then nhi = 127 end
        if nhi - ns + 1 < 0 then nhi = ns - 1 end
        state.view_hi, state.view_rows = nhi, ns
        UI.RequestRedraw()
    end

    -- La glissiere, entre les deux boutons.
    local ry, rh = y + SBAR_BTN, h - SBAR_BTN * 2
    if rh < 20 then return end
    local frac = vrows / 128
    local th = math.max(18, rh * frac)
    -- 127 en haut, 0 en bas : la position du pouce suit la hauteur, pas
    -- l'index de rangee.
    local pos = (127 - vhi) / math.max(1, 128 - vrows)
    local tyy = ry + (rh - th) * pos

    local hot_th = over and my >= tyy and my < tyy + th
    Core_tk.DrawRect(x + 2, tyy, w - 4, th,
                     col_th[1], col_th[2], col_th[3],
                     (hot_th or state.sbar_drag) and 0.9 or 0.6)

    if click and over and my >= ry and my < ry + rh then
        if hot_th then
            state.sbar_drag = { grab = my - tyy }
        else
            -- Cliquer la glissiere saute d'une page, comme partout.
            local dir = (my < tyy) and 1 or -1
            local nhi = vhi + dir * vrows
            if nhi > 127 then nhi = 127 end
            if nhi - vrows + 1 < 0 then nhi = vrows - 1 end
            state.view_hi = nhi
            UI.RequestRedraw()
        end
    end
    if state.sbar_drag then
        if down then
            local p = (my - state.sbar_drag.grab - ry) / math.max(1, rh - th)
            if p < 0 then p = 0 elseif p > 1 then p = 1 end
            local nhi = math.floor(127 - p * (128 - vrows) + 0.5)
            if nhi > 127 then nhi = 127 end
            if nhi - vrows + 1 < 0 then nhi = vrows - 1 end
            state.view_hi = nhi
            UI.SetCursor("size_ns")
            UI.RequestRedraw()
        else
            state.sbar_drag = nil
        end
    elseif over then
        UI.SetCursor("arrow")
    end
end

local move_snap = {}
local function snapshotSel()
    local n = 0
    for i in pairs(Roll.selset) do
        n = n + 1
        move_snap[n] = { i = i, s = Roll.starts[i], p = Roll.pitches[i],
                         l = Roll.lens[i], v = Roll.vels[i] }
    end
    for k = #move_snap, n + 1, -1 do move_snap[k] = nil end
    return n
end

local function rollInput(theme, rows, row_h, lane_w, vy)
    local mx, my = Core_tk.GetMousePos()
    local lane_x0 = wave.x - lane_w
    local in_grid = mx >= wave.x and mx < wave.x + wave.w
                and my >= wave.ry and my < wave.ry + wave.rh
    local in_vel = mx >= wave.x and mx < wave.x + wave.w
               and my >= vy and my < vy + VEL_H
    local in_ruler = mx >= wave.x and mx < wave.x + wave.w
                 and my >= wave.y and my < wave.ry
    local in_lane = mx >= lane_x0 and mx < wave.x
                and my >= wave.ry and my < wave.ry + wave.rh
    if Core_tk.HasPopup() then in_grid, in_vel, in_ruler, in_lane = false, false, false, false end

    local t = timeAtX(mx)
    local row = math.floor((my - wave.ry) / row_h) + 1
    local pitch = rows.list[row]
    local pos = itemPos()

    -- LA ZONE SOUS LE POINTEUR, nommee une fois. C'est elle qui choisit la
    -- colonne du tableau de liaisons : la meme paire (modificateurs, geste) ne
    -- veut pas dire la meme chose sur une note, sur son bord et sur le vide, et
    -- c'est exactement ce que la table des modificateurs de REAPER encode.
    --
    -- `Roll.At` une seule fois : elle balaie les notes, et l'appeler pour la
    -- zone puis pour le clic puis pour l'affordance la faisait trois fois par
    -- frame sur une grille qui peut porter mille notes.
    local hit = (in_grid and pitch) and Roll.At(t, pitch) or nil
    local on_edge = hit ~= nil
                    and mx > xAtTime(Roll.starts[hit] + Roll.lens[hit]) - 6
    local zone = (in_ruler and "ruler") or (in_lane and "lane")
              or (in_vel and "vel")
              or (hit and (on_edge and "edge" or "note"))
              or (in_grid and "roll") or nil
    local mods = Keymap.Mods()
    local function act(gesture, z) return Keymap.Mouse(KM, z or zone, gesture, mods) end
    -- Le badge du pointeur s'eteint des qu'on quitte la grille : il n'est pose
    -- que par l'affordance de survol, qui ne s'execute pas ailleurs, et un
    -- badge qui reste allume sur une barre d'outils est pire que pas de badge.
    state.hint = nil

    -- ruler strip (top): real handles. Grab a time-selection EDGE to
    -- resize, its BODY to move it, the edit-cursor flag to drag it; an
    -- empty click sets the cursor, an empty drag makes a new selection.
    -- Grid-snapped unless Ctrl.
    local rfree = act("click", "ruler") == "ruler.cursor_free"
    local tsa, tsb = timeSel()
    local has_ts = tsa ~= nil
    local ecur = editCursor()
    -- hover affordance (cursor shape) over grabbable ruler handles
    if in_ruler and not state.ruler_drag then
        if (tsa and math.abs(mx - xAtTime(tsa)) <= 6)
           or (tsb and math.abs(mx - xAtTime(tsb)) <= 6) then
            UI.SetCursor("ts_edge")
        elseif tsa and tsb and mx > xAtTime(tsa) and mx < xAtTime(tsb) then
            UI.SetCursor("ts_move")
        elseif math.abs(mx - xAtTime(ecur)) <= 5 then
            UI.SetCursor("ts_edge")
        end
    end
    if in_ruler and Core_tk.MouseClicked(1) then
        -- Les deux actions qui ne touchent NI le curseur NI les bornes passent
        -- d'abord : ce sont des ordres, pas des prises de poignee.
        local ra = act("click", "ruler")
        if ra == "ruler.clear_ts" then
            setTimeSel(nil, nil)
            return
        elseif ra == "ruler.select_in_ts" then
            if has_ts then
                local n = Roll.SelectBox(tsa, tsb, 0, 127, false)
                state.row_hi = nil
                flash(n .. " selected")
            end
            return
        end
        if tsa and math.abs(mx - xAtTime(tsa)) <= 6 then
            state.ruler_drag = { mode = "resize_a", anchor = tsb }
        elseif tsb and math.abs(mx - xAtTime(tsb)) <= 6 then
            state.ruler_drag = { mode = "resize_b", anchor = tsa }
        elseif tsa and tsb and mx > xAtTime(tsa) and mx < xAtTime(tsb) then
            state.ruler_drag = { mode = "move", grab = t - tsa, len = tsb - tsa }
        elseif math.abs(mx - xAtTime(ecur)) <= 5 then
            state.ruler_drag = { mode = "cursor" }
        else
            local st = rfree and t or midiSnap(t)
            state.ruler_drag = { mode = "new", t0 = st }
            setEditCursor(math.max(0, st))
            setTimeSel(nil, nil)
            scrubTo(st)
        end
    end
    if state.ruler_drag then
        local rd = state.ruler_drag
        if Core_tk.MouseDown(1) then
            local ct = rfree and t or midiSnap(t)
            if ct < 0 then ct = 0 end
            if rd.mode == "cursor" then
                setEditCursor(ct)
            elseif rd.mode == "new" then
                setTimeSel(math.min(rd.t0, ct), math.max(rd.t0, ct))
            elseif rd.mode == "resize_a" then
                setTimeSel(math.min(ct, rd.anchor), math.max(ct, rd.anchor))
            elseif rd.mode == "resize_b" then
                setTimeSel(math.min(rd.anchor, ct), math.max(rd.anchor, ct))
            elseif rd.mode == "move" then
                -- snap the RESULT, not the grab point (like note-move) — else
                -- the sub-grid grab offset lands the range off-grid
                local na = t - rd.grab
                if not rfree then na = midiSnap(na) end
                if na < 0 then na = 0 end
                setTimeSel(na, na + rd.len)
            end
            UI.SetCursor(rd.mode == "move" and "ts_move" or "ts_edge")
            rd.last = ct
        else
            -- Une seconde fois, au relachement : le scrub suit la ou le doigt
            -- s'arrete, sans avoir suivi les soixante positions du trajet.
            if rd.last and (rd.mode == "cursor" or rd.mode == "new") then
                scrubTo(rd.last)
            end
            state.ruler_drag = nil
        end
    end

    -- labels lane (piano key / drum header): left-click selects the whole
    -- pitch row, right-click auditions the note (play the pad / key).
    if in_lane and pitch then
        UI.SetCursor("keys")
        if Core_tk.MouseClicked(1) then
            local a = act("click")
            if a == "lane.select_row" or a == "lane.select_row_add" then
                Roll.SelectPitch(pitch, a == "lane.select_row_add")
                state.row_hi = pitch
            end
        elseif Core_tk.MouseClicked(2) then
            if act("rclick") == "lane.audition" then
                auditionNote(pitch, state.last_vel)
            end
        end
    end

    -- zoom / pan / subdivide over grid + velocity lane
    if in_grid or in_vel then
        local wheel = Core_tk.GetState().mouse_wheel
        if wheel and wheel ~= 0 then
            local notches = wheel / 120
            local ctrl, shift, alt = Core_tk.ModCtrl(), Core_tk.ModShift(), Core_tk.ModAlt()
            local onNote = (in_grid and pitch) and Roll.At(t, pitch) or nil
            if onNote and ctrl and shift and not state.mdrag and not state.marquee then
                -- Ctrl+Shift+Wheel on a note = trap-roll subdivide. NEVER mid-drag:
                -- it Syncs, which reshuffles indices and strands the drag snapshot.
                local a, b, n = noteRun(onNote)
                local vel = Roll.vels[onNote]
                if wheel > 0 then n = n * 2 else n = math.max(1, math.floor(n / 2)) end
                if n <= 64 then
                    Roll.Subdivide(a, b, pitch, vel, n)
                    flash(n == 1 and "merged" or (n .. " notes"))
                end
                UI.ConsumeWheel()
                return
            elseif shift then                         -- horizontal zoom
                zoomAt(mx, notches > 0 and (1 / 1.25) ^ notches or 1.25 ^ (-notches))
            elseif alt then                           -- horizontal scroll
                local dt = -notches * span() * 0.15
                state.t0 = state.t0 + dt; state.t1 = state.t1 + dt; clampView()
            elseif ctrl then                          -- vertical zoom about the mouse pitch
                local vrows = state.view_rows or 30
                local anchor = pitch or state.view_hi or 71
                local ns = math.floor(vrows * (notches > 0 and 1 / 1.2 or 1.2) + 0.5)
                if ns < 6 then ns = 6 elseif ns > 100 then ns = 100 end
                local vlo = (state.view_hi or 71) - vrows + 1
                local frac = (anchor - vlo) / math.max(1, vrows - 1)
                local nlo = math.floor(anchor - frac * (ns - 1) + 0.5)
                local nhi = nlo + ns - 1
                if nlo < 0 then nlo = 0; nhi = ns - 1 end
                if nhi > 127 then nhi = 127; nlo = math.max(0, 127 - ns + 1) end
                state.view_hi, state.view_rows = nhi, (nhi - nlo + 1)
            else                                      -- vertical scroll (up = higher)
                local vrows = state.view_rows or 30
                local step = math.max(1, math.floor(vrows * 0.2))
                local vhi = (state.view_hi or 71) + (notches > 0 and step or -step)
                if vhi > 127 then vhi = 127 end
                if vhi - vrows + 1 < 0 then vhi = vrows - 1 end
                state.view_hi = vhi
            end
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
            UI.SetCursor("pan")
        end
    end

    -- grid presses
    -- UNE COMBINAISON NON ASSIGNEE RETOMBE SUR L'ACTION PAR DEFAUT, comme chez
    -- REAPER : sa table a toujours une ligne « Default action », et les
    -- combinaisons absentes y reviennent. C'est pour ca que « deplacer »,
    -- « redimensionner », « inserer » et « poser le curseur » n'ont pas de
    -- branche a leur nom — elles SONT le repli. `Tools/keymap_lint.py` les
    -- connait par leur nom pour ne pas les signaler comme mortes.
    --
    -- LA PRISE FAIT DEUX CHOSES A LA FOIS, et c'est ce que la table de REAPER
    -- decrit : l'action de CLIC s'applique tout de suite (selectionner,
    -- effacer, doubler une longueur) et l'action de GLISSER s'arme derriere
    -- pour le cas ou le pointeur bouge. Alt efface une note au clic et en
    -- efface une trainee au glisser — un seul modificateur, deux lignes du
    -- tableau, parce que ce sont deux actions.
    if in_grid and pitch then
        if Core_tk.MouseClicked(1) then
            local ca, da = act("click"), act("drag")
            if hit then
                -- ----- ce que le clic fait immediatement --------------------
                if ca == "note.erase" or da == "note.erase_drag"
                   or da == "note.erase_drag_free" then
                    Roll.Delete(hit)
                    state.row_hi = nil
                    state.mdrag = { mode = "erase", moved = true }
                    return
                elseif ca == "note.select_measure" then
                    local a, b = measureAround(Roll.starts[hit])
                    flash(Roll.SelectBox(a, b, 0, 127, false) .. " selected")
                    state.row_hi = nil
                    return
                elseif ca == "note.select_to_end" then
                    flash(Roll.SelectBox(Roll.starts[hit], 1e18, 0, 127, false)
                          .. " selected")
                    state.row_hi = nil
                    return
                elseif ca == "note.len_double" or ca == "note.len_halve" then
                    if not Roll.IsSel(hit) then Roll.SelectOnly(hit) end
                    Roll.ScaleLen(ca == "note.len_double" and 2 or 0.5)
                    return
                end

                -- ----- LES ACTIONS DE SELECTION S'APPLIQUENT ET LAISSENT
                -- ----- LE GLISSER S'ARMER DERRIERE.
                --
                -- Elles ne terminent pas le geste, contrairement aux commandes
                -- ci-dessus : chez REAPER, Ctrl bascule au CLIC et copie au
                -- GLISSER, Shift ajoute une plage au clic et ignore le
                -- magnetisme au glisser. Les faire sortir ici rendait la moitie
                -- des glissers inatteignables — « Ctrl+drag ne copie pas »
                -- n'etait pas un defaut de la copie, mais de cette sortie.
                if ca == "note.select_toggle" then
                    Roll.ToggleSel(hit)
                elseif ca == "note.select_range" then
                    Roll.SelectRange(Roll.sel or hit, hit, false)
                elseif not Roll.IsSel(hit) then
                    Roll.SelectOnly(hit)
                end
                state.row_hi = nil
                local idx = hit
                if on_edge then
                    if da == "edge.stretch" or da == "edge.stretch_free" then
                        local n = snapshotSel()
                        state.mdrag = { mode = "stretch", zone = "edge",
                                        idx = idx, moved = false,
                                        free_act = "edge.stretch_free",
                                        multi = n > 0 and n or nil, px = mx, py = my,
                                        a0 = spanStart(), t0 = midiSnap(t) }
                    else
                        local solo = (da == "edge.resize_solo")
                        state.mdrag = { mode = "resize", zone = "edge",
                                        idx = idx, moved = false,
                                        px = mx, py = my,
                                        free_act = "edge.resize_free",
                                        multi = (not solo) and Roll.seln > 1
                                                and snapshotSel() or nil,
                                        ol = Roll.lens[idx] }
                    end
                elseif da == "note.stretch_pos"
                       or da == "note.stretch_pos_free" then
                    local n = snapshotSel()
                    state.mdrag = { mode = "stretchpos", zone = "note",
                                    idx = idx, moved = false,
                                    free_act = "note.stretch_pos_free",
                                    multi = n > 0 and n or nil, px = mx, py = my,
                                    a0 = spanStart(), t0 = midiSnap(t) }
                else
                    -- LE CLIC A BASCULE, LE GLISSER NE DOIT PAS EN PATIR.
                    -- Si la note attrapee etait deja selectionnee, Ctrl vient
                    -- de l'en sortir ; on la remet avant de photographier, ou
                    -- la copie porterait sur tout SAUF celle qu'on tient.
                    local copy = (da == "note.copy")
                    if copy and not Roll.IsSel(idx) then Roll.AddSel(idx) end
                    -- La photo est prise MEME POUR UNE SEULE NOTE quand on
                    -- copie : c'est elle qui dira, au relachement, ou reposer
                    -- l'original.
                    local nsnap = (Roll.seln > 1 or copy) and snapshotSel() or nil
                    state.mdrag = { mode = "move", zone = "note",
                                    idx = idx, moved = false,
                                    grab = t - Roll.starts[idx],
                                    free_act = "note.move_free",
                                    axis_act = "note.move_axis",
                                    copy = copy, copy_n = copy and nsnap or nil,
                                    multi = Roll.seln > 1 and nsnap or nil,
                                    px = mx, py = my,
                                    op = Roll.starts[idx], opp = Roll.pitches[idx] }
                end
                auditionNote(pitch, Roll.vels[idx])
            else
                -- ----- la grille vide ---------------------------------------
                local eraser = (da == "roll.erase_drag"
                                or da == "roll.erase_drag_free")
                if ca == "roll.deselect" or eraser then
                    Roll.ClearSel()
                    state.row_hi = nil
                    if eraser then
                        state.mdrag = { mode = "erase", moved = true }
                    end
                    return
                elseif ca == "roll.cursor" then
                    Roll.ClearSel()
                    state.row_hi = nil
                    setEditCursor(math.max(0, t))
                    return
                elseif da == "roll.paint_line" or da == "roll.paint_chord" then
                    state.mdrag = { mode = "paint", moved = false,
                                    t0 = midiSnapFloor(t), p0 = pitch,
                                    chord = (da == "roll.paint_chord") }
                    return
                elseif da == "roll.copy_sel" then
                    if Roll.seln > 0 then
                        local nsnap = snapshotSel()
                        state.mdrag = { mode = "move", zone = "roll",
                                        idx = Roll.sel, moved = false,
                                        grab = 0, multi = nsnap,
                                        copy = true, copy_n = nsnap,
                                        free_act = "note.move_free",
                                        px = mx, py = my,
                                        op = midiSnap(t), opp = pitch }
                    end
                    return
                end
                -- FL: click on empty = insert in the cell UNDER the cursor.
                -- Draw-then-drag: keep the button held and drag right to set the
                -- length (a plain click keeps the one-cell default).
                local t0 = midiSnapFloor(t)
                local len = gridStepSec(t0)
                if len <= 0.001 then len = 0.1 end
                Roll.Insert(t0, pitch, len, state.last_vel)
                state.row_hi = nil
                auditionNote(pitch, state.last_vel)
                if Roll.sel then
                    state.mdrag = { mode = "resize", idx = Roll.sel, moved = false,
                                    fresh = true, px = mx, py = my, ol = Roll.lens[Roll.sel] }
                end
            end
        elseif Core_tk.MouseClicked(2) and not state.mdrag then
            -- right-press (only when no left-drag is active — a marquee's
            -- delete would Sync mid-drag and corrupt move_snap indices):
            -- start a marquee; a release without movement over a note
            -- deletes it (FL quick-delete preserved)
            if act("rclick", "roll") == "roll.marquee"
               or act("rclick", "note") == "roll.marquee" then
                state.marquee = { x = mx, y = my, cx = mx, cy = my,
                                  t0 = t, p0 = pitch, moved = false }
            end
        end
    end

    -- marquee (right-drag box select)
    if state.marquee then
        if Core_tk.MouseDown(2) then
            state.marquee.cx, state.marquee.cy = mx, my
            if math.abs(mx - state.marquee.x) > 4 or math.abs(my - state.marquee.y) > 4 then
                state.marquee.moved = true
            end
        else
            local m = state.marquee
            if m.moved then
                local ta = math.min(m.t0, t)
                local tb = math.max(m.t0, t)
                local ra = math.floor((math.min(m.y, my) - wave.ry) / row_h) + 1
                local rb = math.floor((math.max(m.y, my) - wave.ry) / row_h) + 1
                local plo, phi = 127, 0
                for rr = ra, rb do
                    local pp = rows.list[rr]
                    if pp then
                        if pp < plo then plo = pp end
                        if pp > phi then phi = pp end
                    end
                end
                if phi >= plo then
                    -- Additif : le meme modificateur que le clic sur une
                    -- note, sinon deux facons d'ajouter a une selection dans
                    -- la meme fenetre.
                    local n = Roll.SelectBox(ta, tb, plo, phi,
                                             (mods & Keymap.CTRL) ~= 0)
                    state.row_hi = nil
                    flash(n .. " selected")
                end
            elseif m.p0 then
                -- plain right-click: delete the note under the cursor
                local idx = Roll.At(m.t0, m.p0)
                if idx then Roll.Delete(idx) end
            end
            state.marquee = nil
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
            if not Roll.IsSel(best) then Roll.SelectOnly(best) end
            state.mdrag = { mode = "vel", idx = best, moved = false,
                            multi = Roll.seln > 1 and snapshotSel() or nil }
        end
    end

    -- active left-drags (move / resize / velocity)
    local md = state.mdrag
    if md then
        if Core_tk.MouseDown(1) then
            -- LES MODIFICATEURS SONT VIVANTS PENDANT LE GESTE.
            --
            -- Je les avais figes a la prise, avec un argument qui sonnait bien
            -- — « la note sauterait au moment ou le doigt bouge sur le clavier »
            -- — et qui etait faux a l'usage : on attrape un bord, on voit que
            -- ca accroche la grille, on presse Shift. C'est le geste naturel, et
            -- il ne demandait qu'a etre entendu. REAPER fait pareil.
            --
            -- On repose donc la question au TABLEAU, pas aux touches : la zone
            -- ou le geste a commence ne change pas, donc `Keymap.Mouse` rend
            -- l'action que les modificateurs d'AUJOURD'HUI designent dans cette
            -- zone, et on regarde si c'est la variante libre. Une liaison
            -- rebranchee suit donc aussi en cours de geste, sans une ligne de
            -- plus.
            local live = md.zone and Keymap.Mouse(KM, md.zone, "drag", mods) or nil
            local free = (md.free_act ~= nil and live == md.free_act)
            local axis = (md.axis_act ~= nil and live == md.axis_act)


            if md.mode == "erase" then
                if hit then Roll.Delete(hit) end
                UI.SetCursor("erase")
            elseif md.mode == "paint" then
                md.p1, md.t1 = pitch or md.p0, midiSnapFloor(t)
                if md.t1 ~= md.t0 then md.moved = true end
                UI.SetCursor("draw")
            elseif md.mode == "stretch" or md.mode == "stretchpos" then
                -- ETIRER : les positions se dilatent autour du DEBUT du groupe,
                -- qui est le seul point fixe qui ne depende pas de la note
                -- qu'on a attrapee. `stretch` emmene les longueurs avec elles,
                -- `stretchpos` ne bouge que les departs — c'est ce que REAPER
                -- appelle arpeger, et la difference est exactement la.
                local a = md.a0 or 0
                local d0 = (md.t0 or 0) - a
                -- L'ETIREMENT SE MAGNETISE, LUI AUSSI. Il ne le faisait pas :
                -- le facteur se calculait sur la position brute du pointeur,
                -- donc un groupe etire tombait entre deux cases et il fallait
                -- le requantifier apres. Ce n'est pas un choix de conception,
                -- c'est une ligne qui manquait.
                local ct = free and t or midiSnap(t)
                if math.abs(d0) > 1e-6 and md.multi then
                    local f = (ct - a) / d0
                    if f < 0.02 then f = 0.02 elseif f > 50 then f = 50 end
                    for k = 1, md.multi do
                        local e = move_snap[k]
                        local ns = a + (e.s - a) * f
                        if ns < 0 then ns = 0 end
                        Roll.MoveLive(e.i, ns, e.p)
                        if md.mode == "stretch" then
                            local nl = e.l * f
                            if nl < 0.01 then nl = 0.01 end
                            Roll.ResizeLive(e.i, nl)
                        end
                    end
                    md.moved = true
                end
                UI.SetCursor("stretch")
            elseif md.mode == "move" and md.idx then
                local nt = t - (md.grab or 0)
                if not free then nt = midiSnap(nt) end
                if nt < 0 then nt = 0 end
                local np = pitch or (md.multi and md.opp) or Roll.pitches[md.idx]
                -- UN SEUL AXE : celui du plus grand mouvement, decide une fois
                -- que le geste a une direction et jamais rediscute. Le decider
                -- a chaque frame ferait osciller la note entre les deux des que
                -- la main tremble sur la diagonale.
                if axis then
                    if not md.lock and md.px
                       and (math.abs(mx - md.px) > 4 or math.abs(my - md.py) > 4) then
                        md.lock = (math.abs(mx - md.px) >= math.abs(my - md.py))
                                  and "time" or "pitch"
                    end
                    if md.lock == "time" then np = md.opp
                    elseif md.lock == "pitch" then nt = md.op end
                else
                    -- Relacher le verrou le relache VRAIMENT : sinon on garderait
                    -- l'axe d'un geste qu'on a cesse de demander.
                    md.lock = nil
                end
                if md.multi and md.multi > 1 then
                    -- group move: same delta on every snapshot note. Vertically
                    -- the delta is in ROWS when the rows are a drum list — one
                    -- row there can be a 7-semitone jump, and a pitch delta
                    -- would throw every other note between the pads. Melodic
                    -- rows are contiguous, where the two deltas are the same.
                    local dt = nt - md.op
                    if rows.drum then
                        local drow = (rows.map[np] or 0) - (rows.map[md.opp] or 0)
                        for k = 1, md.multi do
                            local e = move_snap[k]
                            Roll.MoveLive(e.i, math.max(0, e.s + dt),
                                          Rows.Shift(rows, e.p, drow))
                        end
                    else
                        local dp = np - md.opp
                        for k = 1, md.multi do
                            local e = move_snap[k]
                            local ns = math.max(0, e.s + dt)
                            local npp = math.min(127, math.max(0, e.p + dp))
                            Roll.MoveLive(e.i, ns, npp)
                        end
                    end
                    md.moved = true
                elseif nt ~= Roll.starts[md.idx] or np ~= Roll.pitches[md.idx] then
                    if np ~= Roll.pitches[md.idx] then auditionNote(np, Roll.vels[md.idx]) end
                    Roll.MoveLive(md.idx, nt, np)
                    md.moved = true
                end
                -- Le curseur suit ce que le geste FAIT maintenant : un axe
                -- verrouille, une copie en cours, ou un simple deplacement.
                UI.SetCursor(md.lock == "time" and "move_h"
                             or md.lock == "pitch" and "move_v"
                             or (md.copy and "copy") or "note")
            elseif md.mode == "resize" and md.idx then
                local e = free and t or midiSnap(t)
                -- a freshly drawn note may never shrink BELOW the cell it was
                -- drawn as (the snapped end can round back onto its own start);
                -- only an existing-note resize may go sub-cell
                local min_len = md.fresh and md.ol or (gridStepSec(Roll.starts[md.idx]) * 0.25)
                local len = e - Roll.starts[md.idx]
                if len < min_len then len = min_len end
                if md.multi and md.multi > 1 then
                    -- group resize: same length delta on every selected note
                    local dl = len - md.ol
                    for k = 1, md.multi do
                        local en = move_snap[k]
                        local nl = en.l + dl
                        if nl < 0.01 then nl = 0.01 end
                        Roll.ResizeLive(en.i, nl)
                    end
                    md.moved = true
                elseif (md.moved or not md.px
                        or math.abs(mx - md.px) > 3 or math.abs(my - md.py) > 3)
                       and math.abs(len - Roll.lens[md.idx]) > 0.0001 then
                    -- draw-then-drag: a fresh insert only sets length once the
                    -- pointer actually moves (a plain click keeps the one cell)
                    Roll.ResizeLive(md.idx, len)
                    md.moved = true
                end
                UI.SetCursor("note_edge")
            elseif md.mode == "vel" and md.idx then
                local vel = (vy + VEL_H - my) / VEL_H * 127
                if md.multi and md.multi > 1 then
                    for k = 1, md.multi do Roll.SetVelLive(move_snap[k].i, vel) end
                else
                    Roll.SetVelLive(md.idx, vel)
                end
                state.last_vel = Roll.vels[md.idx]
                md.moved = true
            end
        else
            if md.mode == "paint" then
                -- ON PEINT AU RELACHEMENT, une seule fois. Peindre en continu
                -- demanderait de defaire a chaque frame ce que la frame
                -- precedente a insere — et une insertion re-trie, donc tous les
                -- index bougent sous le geste. Un trait, une ecriture, une
                -- annulation.
                if md.moved and md.t1 then
                    local step = gridStepSec(md.t0)
                    if step > 0.001 then
                        local n = Roll.PaintLine(md.t0, md.p0, md.t1, md.p1 or md.p0,
                                                 step, step, state.last_vel,
                                                 md.chord)
                        flash(n .. " painted")
                    end
                end
            elseif md.moved and md.copy then
                -- LA COPIE SE POSE AU RELACHEMENT, la ou les notes ETAIENT.
                -- On a deplace les originales ; on remet une copie a leur
                -- place de depart. L'etat final est celui de REAPER, et rien
                -- n'a eu a suivre des index pendant le geste.
                Roll.Commit(md.mode == "resize" and "MIDI: resize note"
                            or "MIDI: move note")
                Roll.Stamp(move_snap, md.copy_n or 0)
            elseif md.moved and md.mode ~= "erase" then
                Roll.Commit(md.mode == "vel" and "MIDI: velocity"
                            or md.mode == "resize" and "MIDI: resize note"
                            or md.mode == "stretch" and "MIDI: stretch notes"
                            or md.mode == "stretchpos" and "MIDI: stretch note positions"
                            or "MIDI: move note")
            end
            state.mdrag = nil
        end
    end

    -- hover affordance: edge = resize, note body = move, empty = insert
    -- (skipped mid-pan so the middle-drag size_all cursor wins)
    if in_grid and not state.mdrag and not state.marquee and pitch
       and not Core_tk.MouseDown(64) then
        -- LE POINTEUR ANNONCE CE QUI VA SE PASSER, modificateurs compris. Une
        -- gomme qui ressemble a un deplacement se decouvre en effacant une note
        -- qu'on ne voulait pas ; et c'est le seul retour qu'on a avant le clic.
        local da = act("drag")
        state.hint = nil
        if da == "note.erase_drag" or da == "roll.erase_drag"
           or da == "note.erase_drag_free" or da == "roll.erase_drag_free" then
            UI.SetCursor("erase") state.hint = "erase"
        elseif da == "roll.paint_line" or da == "roll.paint_chord" then
            UI.SetCursor("draw") state.hint = "draw"
        elseif da == "note.copy" or da == "roll.copy_sel" then
            UI.SetCursor("copy") state.hint = "copy"
        elseif da == "edge.stretch" or da == "edge.stretch_free"
               or da == "note.stretch_pos" or da == "note.stretch_pos_free" then
            UI.SetCursor("stretch") state.hint = "stretch"
        elseif hit then
            UI.SetCursor(on_edge and "note_edge" or "note")
        else
            UI.SetCursor("draw")
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

    -- L'ASCENSEUR VERTICAL prend sa place AVANT que quoi que ce soit ne
    -- mesure la vue : `wave.w` sert a timeAtX, xAtTime, zoomAt et a toutes les
    -- limites de clic. Le poser apres coup ferait dessiner les notes sous
    -- l'ascenseur et repondre « dans la grille » a un clic qui est dessus.
    --
    -- En mode batterie il n'y a rien a faire defiler : les rangees sont la
    -- liste des pads, elles tiennent toutes. On rend donc la place au lieu de
    -- montrer un ascenseur inerte.
    local sbar_w = rows.drum and 0 or SBAR_W

    -- the shared view rect (timeAtX/xAtTime/zoomAt all reuse it)
    wave.x, wave.y = gx + lane_w, gy
    wave.w, wave.h = aw - lane_w - sbar_w, area_h
    wave.ry, wave.rh = gy + RULER_H, grid_h
    local vy = wave.ry + grid_h + 4

    -- Every surface in this view is a NAMED colour now. It used to be
    -- list_bg multiplied by 0.8 / 0.9 / 0.5 — a product with no name, which
    -- nothing could find and no contrast setting could reach, and which could
    -- only ever move toward black.
    local C        = theme.colors
    local col_bg   = C.canvas_bg
    local col_mute = C.text_mute or C.text_disabled
    local col_acc  = C.canvas_item
    local col_text = C.text
    local col_sel  = C.canvas_item_sel
    local col_edge = C.border
    local col_head = C.canvas_playhead

    -- ruler strip (measure numbers on strong lines)
    local cr = C.canvas_ruler
    Core_tk.DrawRect(gx, gy, aw, RULER_H, cr[1], cr[2], cr[3], 1)
    -- and a real edge under it: the zones are told apart by a line, not by
    -- hoping two fills land far enough apart
    Core_tk.DrawRect(gx, gy + RULER_H - 1, aw, 1,
                     col_edge[1], col_edge[2], col_edge[3], col_edge[4] or 1)

    -- grid background (buffered)
    renderRollGrid(theme, rows, wave.w, grid_h, row_h)
    gfx.dest = -1
    gfx.a, gfx.mode = 1, 0
    gfx.blit(MROLL_BUF, 1, 0, 0, 0, wave.w, grid_h, wave.x, wave.ry, wave.w, grid_h)

    -- measure labels in the ruler (clip mode: bar numbers from 1, plain
    -- beat arithmetic on the project time signature)
    UI.SetFontCaption()
    do
        local step = gridStepQN()
        local ctsn = state.mode == "clip" and clipTsNum() or 0
        local qn = math.floor(rollToQN(state.t0) / step) * step
        local guard = 0
        while guard < 512 do
            guard = guard + 1
            local t = qnToRoll(qn)
            if t > state.t1 then break end
            if t >= state.t0 then
                local midx
                if ctsn > 0 then
                    local m = qn / ctsn
                    if math.abs(m - math.floor(m + 0.5)) < 0.001 then
                        midx = math.floor(m + 0.5) + 1
                    end
                else
                    local mi, mstart = r.TimeMap_QNToMeasures(0, qn + 0.0001)
                    if math.abs(qn - (mstart or -1)) < 0.001 then midx = mi end
                end
                if midx then
                    Core_tk.DrawText(tostring(midx), xAtTime(t) + 3, gy + 2,
                                     col_mute[1], col_mute[2], col_mute[3], 1)
                end
            end
            qn = qn + step
        end
    end

    -- labels lane: piano keyboard (melodic) or named pad rows (drum). The
    -- lane header is a clickable target — clicking a row selects the whole
    -- pitch (drum) / key (melodic).
    local cl = C.canvas_lane
    Core_tk.DrawRect(gx, wave.ry, lane_w, grid_h, cl[1], cl[2], cl[3], 1)
    UI.SetFontCaption()
    -- name the rows after the instrument THIS clip plays into (same helper
    -- CP_Looper uses), not after whatever kit the Sampler has open
    local kv = rows.drum and clipKit() or nil
    for i = 1, rows.n do
        local p = rows.list[i]
        local y = wave.ry + (i - 1) * row_h
        if rows.drum then
            local label = rowLabel(rows, p, kv, lane_w - 8)
            if row_h >= 8 then
                Core_tk.DrawText(label, gx + 4, y + row_h * 0.5 - 6,
                                 col_mute[1], col_mute[2], col_mute[3], 1)
            end
        else
            -- piano key: black keys drawn darker + inset, C rows labelled
            local black = BLACK_KEY[p % 12]
            if black then
                local ck = C.canvas_row_dark
                Core_tk.DrawRect(gx, y + 1, lane_w * 0.62, row_h - 1,
                                 ck[1], ck[2], ck[3], 1)
            else
                Core_tk.DrawRect(gx, y + 1, lane_w - 1, row_h - 1,
                                 0.82, 0.82, 0.84, 1)
                if p % 12 == 0 and row_h >= 8 then
                    Core_tk.DrawText(NOTE_NAMES[p], gx + lane_w - 26,
                                     y + row_h * 0.5 - 6, 0.2, 0.2, 0.2, 1)
                end
            end
        end
        -- selected-row tint (any note of this pitch is selected)
        if state.row_hi == p then
            Core_tk.DrawRect(gx, y, lane_w, row_h,
                             col_acc[1], col_acc[2], col_acc[3], 0.18)
        end
    end
    -- the lane's own edge: opaque, like every other zone boundary
    Core_tk.DrawRect(gx + lane_w - 1, wave.ry, 1, grid_h,
                     col_edge[1], col_edge[2], col_edge[3], col_edge[4] or 1)
    UI.SetFontBody()

    -- notes
    local show_names = opts.note_names
    if show_names then UI.SetFontCaption() end
    for i = 1, Roll.count do
        local rowi = rows.map[Roll.pitches[i]]
        if rowi then
            local t0n, t1n = Roll.starts[i], Roll.starts[i] + Roll.lens[i]
            if t1n > state.t0 and t0n < state.t1 then
                -- Snap BOTH edges to the pixel grid before taking the width.
                -- Rounded separately by gfx, two notes that touch end-to-start
                -- landed 1 px apart or 2 px apart depending on where the
                -- fraction fell — a row of 16ths visibly breathed. Flooring
                -- first puts every note on the same lattice, so the gap is
                -- always exactly one pixel.
                local x0 = math.floor(xAtTime(math.max(t0n, state.t0)))
                local x1 = math.floor(xAtTime(math.min(t1n, state.t1)))
                if x1 - x0 < 2 then x1 = x0 + 2 end
                local y = wave.ry + (rowi - 1) * row_h
                local alpha = 0.35 + (Roll.vels[i] / 127) * 0.55
                Core_tk.DrawRect(x0, y + 1, x1 - x0 - 1, row_h - 2,
                                 col_acc[1], col_acc[2], col_acc[3], alpha)
                if Roll.IsSel(i) then
                    Core_tk.DrawRect(x0, y + 1, x1 - x0 - 1, row_h - 2,
                                     col_sel[1], col_sel[2], col_sel[3], 1, false)
                end
                if show_names and row_h >= 11 and (x1 - x0) > 22 then
                    Core_tk.DrawText(NOTE_NAMES[Roll.pitches[i]], x0 + 3,
                                     y + row_h * 0.5 - 6,
                                     col_text[1], col_text[2], col_text[3], 0.9)
                end
            end
        end
    end
    if show_names then UI.SetFontBody() end

    -- velocity lane — its own zone, so it gets its own edge
    Core_tk.DrawRect(gx, vy, aw, VEL_H, col_bg[1], col_bg[2], col_bg[3], 1)
    Core_tk.DrawRect(gx, vy, aw, 1, col_edge[1], col_edge[2], col_edge[3], col_edge[4] or 1)
    for i = 1, Roll.count do
        local t0n = Roll.starts[i]
        if t0n >= state.t0 and t0n <= state.t1 then
            local x = math.floor(xAtTime(t0n))   -- same lattice as the note
            local bh = (Roll.vels[i] / 127) * (VEL_H - 4)
            local sel = Roll.IsSel(i)
            local c = sel and col_sel or col_acc
            Core_tk.DrawRect(x, vy + VEL_H - bh, 3, bh,
                             c[1], c[2], c[3], sel and 1 or 0.7)
        end
    end

    -- time selection (native loop/time range) painted over the grid + ruler,
    -- with grab handles (notches) at both edges in the ruler strip.
    -- Clip mode has no project time concepts: no time selection, no edit
    -- cursor, no transport playhead.
    local dsa, dsb = timeSel()
    if dsa then
        local xaf = xAtTime(dsa)          -- true edge x (unclamped, for handles)
        local xbf = xAtTime(dsb)
        local xa = math.max(xaf, wave.x)
        local xb = math.min(xbf, wave.x + wave.w)
        if xb > wave.x and xa < wave.x + wave.w then
            Core_tk.DrawRect(xa, gy, xb - xa, RULER_H + grid_h,
                             col_acc[1], col_acc[2], col_acc[3], 0.12)
            Core_tk.DrawRect(xa, gy, 1, RULER_H + grid_h,
                             col_acc[1], col_acc[2], col_acc[3], 0.7)
            Core_tk.DrawRect(xb, gy, 1, RULER_H + grid_h,
                             col_acc[1], col_acc[2], col_acc[3], 0.7)
            -- edge handles in the ruler (only if the edge is actually visible)
            if xaf >= wave.x then
                Core_tk.DrawRect(xaf, gy, 4, RULER_H,
                                 col_acc[1], col_acc[2], col_acc[3], 0.9)
            end
            if xbf <= wave.x + wave.w then
                Core_tk.DrawRect(xbf - 4, gy, 4, RULER_H,
                                 col_acc[1], col_acc[2], col_acc[3], 0.9)
            end
        end
    end

    -- edit cursor + a small flag handle at the top (grabbable)
    do
        local ec = editCursor()
        if ec >= state.t0 and ec <= state.t1 then
            local x = xAtTime(ec)
            Core_tk.DrawRect(x, gy, 1, RULER_H + grid_h,
                             col_text[1], col_text[2], col_text[3], 0.6)
            UI.DrawTriangle(x - 4, gy, x + 4, gy, x, gy + 6,
                            col_text[1], col_text[2], col_text[3], 0.9)
        end
    end

    -- playback cursor (transport, in context)
    if state.mode ~= "clip" and r.GetPlayState() & 1 == 1 then
        local pp = r.GetPlayPosition() - itemPos()
        if pp >= state.t0 and pp <= state.t1 then
            local x = xAtTime(pp)
            Core_tk.DrawRect(x, wave.ry, 1, grid_h + 4 + VEL_H,
                             col_head[1], col_head[2], col_head[3], 1)
        end
        UI.RequestRedraw()
    end

    -- clip playhead: the origin engine's phase, in beats — the same
    -- progress line the Looper draws on its lanes
    if state.mode == "clip" and state.clip_lane and state.loop_att then
        local lmode = math.floor(Loop.Mode(state.clip_lane) + 0.5)
        if lmode == 1 or lmode == 3 or lmode == 5 then
            local ph = Loop.Phase(state.clip_lane)
            if ph >= state.t0 and ph <= state.t1 then
                local x = xAtTime(ph)
                Core_tk.DrawRect(x, wave.ry, 1, grid_h + 4 + VEL_H,
                                 col_head[1], col_head[2], col_head[3], 1)
            end
            UI.RequestRedraw()
        end
    end

    -- marquee (right-drag multi-select box)
    if state.marquee then
        local m = state.marquee
        local x0, x1 = math.min(m.x, m.cx), math.max(m.x, m.cx)
        local y0, y1 = math.min(m.y, m.cy), math.max(m.y, m.cy)
        Core_tk.DrawRect(x0, y0, x1 - x0, y1 - y0,
                         col_acc[1], col_acc[2], col_acc[3], 0.18)
        Core_tk.DrawRect(x0, y0, x1 - x0, y1 - y0,
                         col_acc[1], col_acc[2], col_acc[3], 0.8, false)
    end

    -- LE TRAIT QU'ON VA PEINDRE. On peint au relachement — une seule ecriture,
    -- une seule annulation — donc il faut bien MONTRER ce qu'on vise, sans quoi
    -- le geste se fait a l'aveugle et on le refait trois fois. Les cases sont
    -- dessinees, pas une ligne : c'est ce qui sera insere, a la case pres.
    local pd = state.mdrag
    if pd and pd.mode == "paint" and pd.t1 then
        local step = gridStepSec(pd.t0)
        if step > 0.001 then
            local a, b = pd.t0, pd.t1
            local pa, pb = pd.p0, pd.p1 or pd.p0
            if b < a then a, b, pa, pb = b, a, pb, pa end
            local nst = math.floor((b - a) / step + 1e-6)
            if nst > 512 then nst = 512 end
            for k = 0, nst do
                local at = a + k * step
                local f = (nst > 0) and (k / nst) or 0
                local pp = math.floor(pa + (pb - pa) * f + 0.5)
                local rr = rows.map[pp]
                if rr then
                    local x0 = xAtTime(at)
                    local x1 = xAtTime(at + step)
                    local yy = wave.ry + (rr - 1) * row_h
                    Core_tk.DrawRect(x0 + 1, yy + 1, math.max(2, x1 - x0 - 2),
                                     row_h - 2,
                                     col_acc[1], col_acc[2], col_acc[3], 0.35)
                end
            end
        end
    end

    if sbar_w > 0 then
        drawVScroll(theme, wave.x + wave.w, wave.ry, sbar_w, grid_h)
    end

    -- LE BADGE, EN PLUS DU CURSEUR ET NON A SA PLACE.
    --
    -- Les curseurs de REAPER sont maintenant poses par leur nom, donc le geste
    -- est deja dit par le pointeur lui-meme. Le signe reste parce qu'il survit
    -- a deux choses que le curseur ne survit pas : un theme qui a remplace le
    -- .cur par quelque chose d'illisible, et un nom qui ne resoudrait pas sur
    -- une version plus ancienne — auquel cas le repli est une simple fleche, et
    -- plus rien ne distingue copier d'effacer.
    if state.hint then
        local hx, hy = Core_tk.GetMousePos()
        local g = HINT_GLYPH[state.hint]
        if g then
            Core_tk.DrawRect(hx + 11, hy + 3, 15, 15,
                             col_bg[1], col_bg[2], col_bg[3], 0.85)
            Core_tk.DrawRect(hx + 11, hy + 3, 15, 15,
                             col_acc[1], col_acc[2], col_acc[3], 0.9, false)
            Core_tk.DrawText(g, hx + 15, hy + 5,
                             col_acc[1], col_acc[2], col_acc[3], 1)
        end
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

    local midi = state.mode == "midi" or state.mode == "clip"
    -- Note-editing keys are BLOCKED mid-drag: they Commit → Sort → Sync, which
    -- reshuffles indices and would strand the drag's move_snap (silent MIDI
    -- corruption). Mirrors the pollTarget mid-drag Sync guard.
    local midi_edit = midi and not state.mdrag

    -- UNE SEULE QUESTION POSEE A LA TOUCHE : quelle action ? Ce qui vient
    -- ensuite ne teste plus jamais un code — donc changer une liaison ne
    -- demande de toucher a aucune de ces lignes, ce qui est tout l'objet du
    -- tableau.
    local a = Keymap.Key(KM, char)
    if not a then return end

    -- ----- ce qui vaut dans tous les modes ---------------------------------
    if a == "play.cursor" or a == "play.sel" or a == "play.start" then
        togglePlay(a == "play.start" and "start"
                   or (a == "play.sel" and "sel") or "cursor")
        UI.ConsumeChar(); return
    end
    if a == "view.fit" then fitView(); UI.ConsumeChar(); return end
    if a == "view.zoom_in" then
        zoomAt(wave.x + wave.w / 2, 1 / 1.5); UI.ConsumeChar(); return
    end
    if a == "view.zoom_out" then
        zoomAt(wave.x + wave.w / 2, 1.5); UI.ConsumeChar(); return
    end

    -- ----- l'audio : les transitoires comme des objets ----------------------
    -- M en pose un sur le curseur d'edition — exact, et ca marche PENDANT que
    -- le son joue, ce qu'un clic n'est jamais.
    if not midi then
        if a == "audio.clear_sel" and state.sel_a then
            state.sel_a, state.sel_b = nil, nil; UI.ConsumeChar(); return
        end
        if state.src and a == "audio.mark_add" then
            if markerAdd(state.cursor) then flash("Transient added") end
            UI.ConsumeChar(); return
        end
        if state.src and a == "audio.mark_del"
           and #state.markers > 0 and wave.w > 0 then
            local i = markerAt(state.cursor, 5 * span() / wave.w)
            if i then
                table.remove(state.markers, i)
                flash("Transient removed")
                UI.ConsumeChar(); return
            end
        end
        return
    end

    if not midi_edit then return end

    -- ----- l'annulation, qui n'appartient pas au meme historique ------------
    -- Un take passe par celle de REAPER ; une case a la sienne, parce qu'elle
    -- vit dehors — pas d'item, donc rien que Undo_OnStateChange puisse retenir.
    if a == "edit.undo" or a == "edit.redo" then
        local undo = (a == "edit.undo")
        if state.mode == "midi" then
            if undo then r.Undo_DoUndo2(0) else r.Undo_DoRedo2(0) end
            UI.ConsumeChar(); return
        elseif state.clip then
            local ok = undo and histUndo(state.clip) or histRedo(state.clip)
            if ok then
                Roll.ClearSel()
                Roll.Sync()
                scheduleApply()
                flash(undo and "Undo" or "Redo")
            elseif undo then
                flash("Nothing to undo in this cell")
            end
            UI.ConsumeChar(); return
        end
        return
    end

    -- ----- les notes : une seule mise en oeuvre, partagee avec CP_Looper -----
    if RollUI.Do(a, midiCtx) then
        state.row_hi = nil
        UI.ConsumeChar()
    end
end

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------
local function frame(theme)
    -- liveness heartbeat (read by Bus.OpenEditor; 0.5 s throttle)
    local now = r.time_precise()
    if now >= (state.alive_t or 0) then
        state.alive_t = now + 0.5
        r.SetExtState("CP_Editor", "alive", tostring(now), false)
    end

    handleFileDrops()   -- OS files dropped on the window
    busConsume()        -- Clips dropped from another CP window
    pollTarget()
    -- La fenetre CP_Keymap est un autre script : sans ce battement, un
    -- raccourci qu'on vient de regler ne prendrait qu'apres avoir ferme et
    -- rouvert celle-ci — c'est-a-dire jamais, en pratique.
    if Keymap.PollSync(KM) then flash("Keymap updated") end
    syncRange()
    Kit.Poll()
    Audition.Poll()
    pollSection()
    -- The drag-out lives OUTSIDE the window once it starts, so it is polled
    -- from the frame rather than from the wave's input pass.
    handleDragOut()
    -- live lane (clip mode): keep the engine link fresh and animate while
    -- it runs. reconnect() is cheap once attached (early return) — the 1 s
    -- throttle only matters for the track scan while the Looper is absent.
    state.loop_att = false
    state.clip_lane = nil
    if state.mode == "clip" and state.clip_track then
        if now >= (state.loop_rt or 0) then
            state.loop_rt = now + 1.0
            Loop.reconnect()
        end
        -- one attach probe per frame (it walks the router's FX chain);
        -- the draw paths read the flag
        state.loop_att = Loop.IsAttached()
        if state.loop_att then
            -- Resolve the lane ONCE per frame, here, and let every draw and
            -- input path below read it. This is what keeps the playhead, the
            -- transport button and the writes pointed at the clip on screen
            -- after the Session swapped the halves under us. Nil = the engine
            -- is not holding this clip any more: no playhead, no writes, and
            -- the transport stages it again on demand.
            Loop.Poll()
            state.clip_lane = Loop.LaneOfTag(state.clip_track, state.clip_tag)
        end
        if state.clip_lane then
            local m = math.floor(Loop.Mode(state.clip_lane) + 0.5)
            local p = Loop.Pending(state.clip_lane)
            if m ~= state.lane_mode or p ~= state.lane_pend then
                state.lane_mode, state.lane_pend = m, p
                UI.RequestRedraw()
            end
            -- rec/play/overdub advance the phase; pending states blink
            if m == 1 or m == 3 or m == 5 or p ~= 0 then
                UI.RequestRedraw()
            end
            -- the lane's length can also change from the Looper's own
            -- button: follow it, or the roll would draw the wrong canvas
            local lb = math.floor(Loop.GetLengthBars(state.clip_lane) + 0.5)
            if lb >= 1 and state.clip
               and lb ~= math.floor((state.clip.bars or 4) + 0.5) then
                state.clip.bars = lb
                state.len = lb * clipTsNum()
                fitView()
                UI.RequestRedraw()
            end
        end
    end
    -- debounced clip publish (editor:apply): one message per edit gesture
    if state.apply_t and r.time_precise() >= state.apply_t then
        flushApply()
    end
    if Peaks.Step() then UI.RequestRedraw() end
    handleKeys()

    -- deferred audition note-off (the note is held for 0.2 s, then released
    -- in the track it was played into)
    if state.aud_note and r.time_precise() >= state.aud_off_t then
        Notes.Off(state.aud_note)
        state.aud_note = nil
    end

    UI.SetWindowPadding(theme.pad_large or 10)

    -- FOUR ZONES, each with its own ground and a seam between: the command
    -- bar, the identity line, the canvas, the status. The rail is gone — it
    -- cost 126 px of width permanently, and width is what a waveform and a
    -- piano roll are made of.
    local midi = (state.mode == "midi" or state.mode == "clip")
    UI.BeginBar("cmd")
    barCommon()                                  -- claims the right end first
    if midi then barMidi(theme) else barAudio(theme) end
    UI.EndBar()

    headerLine(theme)
    local status_h = 18
    local area_h = UI.GetAvailableHeight() - status_h - 4
    if area_h < 80 then area_h = 80 end
    if midi then
        drawRoll(theme, area_h)
    else
        drawWave(theme, area_h)
    end

    -- status zone: its own ground, its own seam, pinned to the bottom
    local msg
    if state.flash_msg ~= "" and r.time_precise() < state.flash_until then
        msg = state.flash_msg
        UI.RequestRedraw()
    elseif midi then
        if Roll.seln > 1 then
            msg = Roll.seln .. " notes selected  ·  drag = move all · Del = delete · arrows = transpose"
        elseif Roll.sel and Roll.pitches[Roll.sel] then
            msg = string.format("note %s  ·  vel %d  ·  %.3fs",
                                NOTE_NAMES[Roll.pitches[Roll.sel]],
                                Roll.vels[Roll.sel], Roll.lens[Roll.sel])
        else
            msg = "click = add · edge = resize · Shift = no snap · Ctrl = copy · Alt = erase · right-drag = select · Q quant"
        end
    elseif state.sel_a then
        msg = string.format("sel  %.3f – %.3f  (%.3fs)",
                            state.sel_a, state.sel_b, state.sel_b - state.sel_a)
    else
        msg = "drag = select · wheel = zoom · middle-drag = pan · Space = play"
    end
    UI.AppStatus(msg)

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
    -- ESC already means something here: clear the selection, leave a mode. A
    -- second press must do NOTHING rather than close the window — "cancel what
    -- I am doing" and "throw away what I am working on" are not the same
    -- intention, and one of them costs the whole view.
    close_on_esc = false,
})

-- Advertise this script's registered action so any CP app can LAUNCH the
-- editor when it isn't running (Bus.OpenEditor — the universal "edit this
-- clip" gesture). Persistent: survives REAPER restarts.
do
    local _, _, sectionID, cmdID = r.get_action_context()
    if cmdID and cmdID ~= 0 and sectionID == 0 then
        local named = r.ReverseNamedCommandLookup(cmdID)
        if named then r.SetExtState("CP_Editor", "cmd", "_" .. named, true) end
    end
end

UI.OnClose(function()
    -- Core keeps a SINGLE OnClose callback — everything belongs here.
    flushApply()   -- a pending clip edit must reach its engine
    Notes.Close()   -- rien de tenu, et l'apercu quitte la piste de l'utilisateur
    state.aud_note = nil
    if state.registered then DragBus.Unregister(BUS_ID) end
    persistConfig()
    Audition.Destroy()
    Peaks.Destroy()
    dropOwnSource()
end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
