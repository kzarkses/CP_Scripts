-- CP_Editor — Roll
-- MIDI layer for the piano roll: note cache + edit operations, over a
-- pluggable BACKEND (the storage the notes live in).
--
-- The cache is structure-of-arrays (starts/lens/pitches/vels), reused in
-- place; selection, hit-testing, box/pitch select, subdivide and quantize
-- all operate on the cache and are storage-agnostic. Only the backend knows
-- how to read/write notes:
--
--   * TakeBackend (Roll.Attach) — a REAPER MIDI take. Cache unit is
--     ITEM-RELATIVE seconds, converted through MIDI_Get*PPQ* so tempo is
--     always respected. This is what CP_Editor uses.
--   * A caller may inject its own backend (Roll.SetBackend) whose cache unit
--     is whatever that consumer renders in (e.g. beats for a loop). Roll does
--     not care what the numbers mean — the backend and the renderer agree.
--
-- Edit protocol: interactive drags call *Live() writers (setNote, no sort —
-- indices stay stable mid-drag), then ONE Commit() at release sorts, re-reads
-- and mints the undo point. Structural edits (insert/delete) sort + sync +
-- undo immediately.
--
-- Backend contract (all indices 1-based into the cache):
--   be.readAll()           -> count ; fills Roll.starts/lens/pitches/vels
--   be.insertNote(t,p,l,v) -- unsorted insert (Roll calls be.sort() after)
--   be.deleteNote(i)       -- remove cache note i
--   be.setNote(i,t,l,p,v)  -- live write; nil field = unchanged; may read the
--                             cache for the endpoints it does not receive
--   be.sort()              -- normalize order to match a fresh readAll()
--   be.undo(desc)          -- mint an undo / persistence point

local Roll = {}

local r  -- reaper, injected

Roll.take, Roll.item = nil, nil
Roll.backend = nil
Roll.count   = 0
Roll.starts  = {}   -- cache unit (seconds for a take, beats for a loop)
Roll.lens    = {}
Roll.pitches = {}   -- 0..127
Roll.vels    = {}   -- 1..127
Roll.sel     = nil  -- primary selected note (1-based index) or nil
Roll.selset  = {}   -- multi-selection: set { [idx] = true }
Roll.seln    = 0    -- count in selset
Roll.version = 0    -- bumped on every Sync (UI cache key)

function Roll.init(reaper_api)
    r = reaper_api
end

-- ---------------------------------------------------------------------------
-- Take backend — a REAPER MIDI take (item-relative seconds)
-- ---------------------------------------------------------------------------
local function makeTakeBackend(take, item)
    local be = { item_pos = 0 }
    local function ppq(t_rel)
        return r.MIDI_GetPPQPosFromProjTime(take, be.item_pos + t_rel)
    end

    function be.readAll()
        be.item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local _, notecnt = r.MIDI_CountEvts(take)
        for i = 0, notecnt - 1 do
            local _, _, _, sppq, eppq, _, pitch, vel = r.MIDI_GetNote(take, i)
            local t0 = r.MIDI_GetProjTimeFromPPQPos(take, sppq) - be.item_pos
            local t1 = r.MIDI_GetProjTimeFromPPQPos(take, eppq) - be.item_pos
            local j = i + 1
            Roll.starts[j]  = t0
            Roll.lens[j]    = t1 - t0
            Roll.pitches[j] = pitch
            Roll.vels[j]    = vel
        end
        return notecnt
    end

    function be.insertNote(t, pitch, len, vel)
        r.MIDI_InsertNote(take, false, false, ppq(t), ppq(t + len), 0, pitch, vel, true)
    end

    function be.deleteNote(i)
        r.MIDI_DeleteNote(take, i - 1)
    end

    -- nil t & len = leave timing; if t given the note moves (length kept via
    -- the cache unless len is also given); if only len given, the end moves.
    function be.setNote(i, t, len, pitch, vel)
        local sppq, eppq
        if t ~= nil then
            sppq = ppq(t)
            eppq = ppq(t + (len or Roll.lens[i]))
        elseif len ~= nil then
            eppq = ppq(Roll.starts[i] + len)
        end
        r.MIDI_SetNote(take, i - 1, nil, nil, sppq, eppq, nil, pitch, vel, true)
    end

    function be.sort() r.MIDI_Sort(take) end
    function be.undo(desc) r.Undo_OnStateChange(desc or "MIDI edit") end
    return be
end

function Roll.Attach(take, item)
    Roll.take, Roll.item = take, item
    Roll.backend = makeTakeBackend(take, item)
    -- clear the whole SET, not just the primary: Sync re-selects by (pitch,start)
    -- identity, so a stale selset would bleed a selection into the new take
    Roll.ClearSel()
    Roll.Sync()
end

-- Inject a custom backend (e.g. a loop stored in gmem). Cache unit is
-- whatever the backend/renderer agree on.
function Roll.SetBackend(be)
    Roll.take, Roll.item = nil, nil
    Roll.backend = be
    Roll.ClearSel()          -- see Roll.Attach: a stale selset bleeds across lanes
    Roll.Sync()
end

function Roll.Detach()
    Roll.take, Roll.item = nil, nil
    Roll.backend = nil
    Roll.count = 0
    Roll.ClearSel()
end

-- Re-read every note from the backend (arrays reused, no per-frame use).
-- The selection is preserved BY IDENTITY (pitch + start): indices shift on
-- every re-read, so a raw index set would point at the wrong notes.
-- Selection identity is (pitch, start) kept as two parallel arrays. A single
-- packed key (pitch*BIG + start_ms) would collide once start_ms exceeds BIG —
-- reachable in seconds (items > ~100 s) and in beats (odd meters) — and could
-- reselect the wrong note; a pair comparison has no such cap.
local sel_keep_p  = {}
local sel_keep_ms = {}
function Roll.Sync()
    if not Roll.backend then
        Roll.count = 0
        Roll.ClearSel()
        return
    end
    local nkeep = 0
    for i in pairs(Roll.selset) do
        if Roll.pitches[i] then
            nkeep = nkeep + 1
            sel_keep_p[nkeep]  = Roll.pitches[i]
            sel_keep_ms[nkeep] = math.floor(Roll.starts[i] * 1000 + 0.5)
        end
    end

    local notecnt = Roll.backend.readAll()
    Roll.count = notecnt

    -- re-select by identity
    Roll.ClearSel()
    if nkeep > 0 then
        for i = 1, notecnt do
            local p  = Roll.pitches[i]
            local ms = math.floor(Roll.starts[i] * 1000 + 0.5)
            for k = 1, nkeep do
                if sel_keep_p[k] == p and sel_keep_ms[k] == ms then Roll.AddSel(i) break end
            end
        end
        for k = nkeep, 1, -1 do sel_keep_p[k] = nil; sel_keep_ms[k] = nil end
    end
    Roll.version = Roll.version + 1
end

-- ---------------------------------------------------------------------------
-- Selection set (storage-agnostic — operates on the cache)
-- ---------------------------------------------------------------------------
function Roll.ClearSel()
    local s = Roll.selset
    for k in pairs(s) do s[k] = nil end
    Roll.seln, Roll.sel = 0, nil
end

function Roll.SelectOnly(i)
    Roll.ClearSel()
    if i then Roll.selset[i] = true Roll.seln = 1 Roll.sel = i end
end

function Roll.AddSel(i)
    if i and not Roll.selset[i] then
        Roll.selset[i] = true
        Roll.seln = Roll.seln + 1
        Roll.sel = i
    end
end

function Roll.IsSel(i) return Roll.selset[i] == true end

-- Select every note whose start falls in [ta, tb] and pitch in [plo, phi].
function Roll.SelectBox(ta, tb, plo, phi, additive)
    if not additive then Roll.ClearSel() end
    for i = 1, Roll.count do
        local p = Roll.pitches[i]
        if p >= plo and p <= phi
           and Roll.starts[i] <= tb and Roll.starts[i] + Roll.lens[i] >= ta then
            Roll.AddSel(i)
        end
    end
    return Roll.seln
end

-- BASCULER UNE NOTE dans la selection. Le geste « Ctrl+clic » de REAPER, et
-- la seule facon honnete de l'ecrire : l'appelant tripotait `selset` et `seln`
-- depuis l'exterieur, ce qui marche jusqu'au jour ou la selection apprend a
-- tenir autre chose qu'un ensemble d'index.
function Roll.ToggleSel(i)
    if not i then return false end
    if Roll.selset[i] then
        Roll.selset[i] = nil
        Roll.seln = Roll.seln - 1
        if Roll.sel == i then
            Roll.sel = nil
            for k in pairs(Roll.selset) do Roll.sel = k break end
        end
        return false
    end
    Roll.AddSel(i)
    return true
end

-- SELECTIONNER UNE PLAGE, de l'ancre a la note pointee.
--
-- « Add a range of notes to selection » de REAPER. La plage se prend sur le
-- TEMPS, pas sur l'ordre du tableau : deux notes voisines dans le tableau
-- peuvent etre a deux mesures d'ecart, et l'utilisateur designe ce qu'il voit.
-- Toutes les hauteurs sont prises, comme chez REAPER — c'est un balayage
-- horizontal, et le restreindre a une rangee en ferait un autre geste.
function Roll.SelectRange(i0, i1, additive)
    if not Roll.backend or not i0 or not i1 then return 0 end
    local a = math.min(Roll.starts[i0], Roll.starts[i1])
    local b = math.max(Roll.starts[i0] + Roll.lens[i0],
                       Roll.starts[i1] + Roll.lens[i1])
    return Roll.SelectBox(a, b, 0, 127, additive)
end

-- Select every note of a given pitch (drum-row header click).
function Roll.SelectPitch(pitch, additive)
    if not additive then Roll.ClearSel() end
    for i = 1, Roll.count do
        if Roll.pitches[i] == pitch then Roll.AddSel(i) end
    end
    return Roll.seln
end

-- Delete every selected note (right-to-left so indices stay valid).
--
-- ET LA PLAGE COMPTE ICI AUSSI. Sans elle, Suppr sur une plage sans selection
-- ne faisait rien du tout (seln == 0) — ce qui est encore pire que d'en faire
-- trop : le geste part, et rien ne bouge.
function Roll.DeleteSel()
    if not Roll.backend then return end
    local ranged = (Roll.seln == 0) and Roll.range_a ~= nil
    if Roll.seln == 0 and not ranged then return end
    for i = Roll.count, 1, -1 do
        if (ranged and Roll.InRange(i)) or (not ranged and Roll.selset[i]) then
            Roll.backend.deleteNote(i)
        end
    end
    Roll.backend.sort()
    Roll.Sync()
    Roll.ClearSel()
    Roll.backend.undo("MIDI: delete notes")
end

-- Note under (t, pitch), topmost = last in order. Returns index or nil.
function Roll.At(t, pitch)
    for i = Roll.count, 1, -1 do
        if Roll.pitches[i] == pitch
           and t >= Roll.starts[i] and t < Roll.starts[i] + Roll.lens[i] then
            return i
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Structural edits (immediate undo point)
-- ---------------------------------------------------------------------------
function Roll.Insert(t, pitch, len, vel)
    if not Roll.backend or len <= 0 then return end
    Roll.backend.insertNote(t, pitch, len, vel)
    Roll.backend.sort()
    Roll.Sync()
    Roll.ClearSel()
    for i = 1, Roll.count do
        if Roll.pitches[i] == pitch and math.abs(Roll.starts[i] - t) < 0.001 then
            Roll.SelectOnly(i)
            break
        end
    end
    Roll.backend.undo("MIDI: insert note")
end

function Roll.Delete(i)
    if not Roll.backend or i < 1 or i > Roll.count then return end
    Roll.backend.deleteNote(i)
    Roll.backend.sort()
    Roll.Sync()
    Roll.ClearSel()
    Roll.backend.undo("MIDI: delete note")
end

-- ---------------------------------------------------------------------------
-- Live drag edits (no sort — indices stay stable) + Commit on release
-- ---------------------------------------------------------------------------
function Roll.MoveLive(i, t, pitch)
    if not Roll.backend or i < 1 or i > Roll.count then return end
    Roll.backend.setNote(i, t, nil, pitch, nil)
    Roll.starts[i], Roll.pitches[i] = t, pitch
end

function Roll.ResizeLive(i, len)
    if not Roll.backend or i < 1 or i > Roll.count or len <= 0 then return end
    Roll.backend.setNote(i, nil, len, nil, nil)
    Roll.lens[i] = len
end

function Roll.SetVelLive(i, vel)
    if not Roll.backend or i < 1 or i > Roll.count then return end
    if vel < 1 then vel = 1 elseif vel > 127 then vel = 127 end
    vel = math.floor(vel + 0.5)
    Roll.backend.setNote(i, nil, nil, nil, vel)
    Roll.vels[i] = vel
end

function Roll.Commit(desc)
    if not Roll.backend then return end
    Roll.backend.sort()
    Roll.Sync()
    Roll.backend.undo(desc or "MIDI edit")
end

-- Replace the notes of `pitch` inside [a, b) by n equal notes filling the
-- span (trap-roll subdivision: 1 → 2 → 4 → 8…). One undo point.
function Roll.Subdivide(a, b, pitch, vel, n)
    if not Roll.backend or n < 1 or b <= a then return end
    for i = Roll.count, 1, -1 do
        if Roll.pitches[i] == pitch
           and Roll.starts[i] >= a - 0.0005 and Roll.starts[i] < b - 0.0005 then
            Roll.backend.deleteNote(i)
        end
    end
    local len = (b - a) / n
    for k = 0, n - 1 do
        Roll.backend.insertNote(a + k * len, pitch, len, vel)
    end
    Roll.backend.sort()
    Roll.Sync()
    Roll.sel = nil
    Roll.backend.undo("MIDI: subdivide note")
end

-- ---------------------------------------------------------------------------
-- Batch
-- ---------------------------------------------------------------------------
-- Snap note starts through snap_fn (t → t'), lengths preserved. `strength`
-- (0..1, default 1) pulls each note only part-way to the grid — the universal
-- "iterative / soft" quantize. Swing is expressed inside snap_fn by the host
-- (it knows the grid), so the model stays grid-agnostic. Acts on the selection
-- when there is one, else on everything. Returns the number of notes moved.
-- ---------------------------------------------------------------------------
-- LA PLAGE DE TEMPS — l'autre facon de designer ce qu'on vise
-- ---------------------------------------------------------------------------
-- Une selection temporelle qui ne fait rien n'est pas une selection : c'est un
-- rectangle qu'on dessine pour rien. Elle etait dessinee, deplacable,
-- redimensionnable — et AUCUNE operation ne la consultait, parce que le seul
-- endroit qui decide de ce qu'une operation vise ne connaissait que deux
-- reponses : « la selection de notes » ou « tout ».
--
-- L'ORDRE DE PRIORITE, et il n'est pas negociable : une selection de NOTES
-- gagne toujours. Elle est explicite, on l'a faite note par note ; une plage
-- est un contour, et un contour ne doit pas defaire un choix. La plage ne
-- repond donc que quand rien n'est selectionne — la ou « tout » repondait, et
-- ou « tout » etait justement la mauvaise reponse.
--
-- Le brancher ICI plutot que dans chaque operation les rend TOUTES sensibles a
-- la plage d'un coup : quantifier, transposer, decaler, legato, inverser,
-- humaniser, velocite, supprimer, copier. Les brancher une par une aurait
-- garanti qu'il en reste trois qui ne le sont pas.
Roll.range_a, Roll.range_b = nil, nil

function Roll.SetRange(a, b)
    if a and b and b > a + 1e-9 then Roll.range_a, Roll.range_b = a, b
    else Roll.range_a, Roll.range_b = nil, nil end
end

function Roll.HasRange() return Roll.range_a ~= nil end

-- Une note est DANS la plage si elle y commence. Le critere « elle la
-- chevauche » ferait quantifier une note commencee deux mesures avant parce
-- que sa queue depasse dans le contour, ce qui n'est jamais ce qu'on veut dire.
function Roll.InRange(i)
    if not Roll.range_a then return true end
    local st = Roll.starts[i]
    return st >= Roll.range_a - 1e-9 and st < Roll.range_b - 1e-9
end

-- Combien de notes la plage tient. Sert a le DIRE dans la fenetre : une portee
-- d'operation qu'on ne voit pas est une surprise en attente.
function Roll.RangeCount()
    if not Roll.range_a then return 0 end
    local n = 0
    for i = 1, Roll.count do if Roll.InRange(i) then n = n + 1 end end
    return n
end

function Roll.Quantize(snap_fn, strength)
    if not Roll.backend or Roll.count == 0 then return 0 end
    strength = strength or 1
    local function q(i)
        local s = Roll.starts[i]
        local t = snap_fn(s)
        t = s + (t - s) * strength
        if math.abs(t - s) > 0.0005 then
            Roll.MoveLive(i, t < 0 and 0 or t, Roll.pitches[i])
            return true
        end
        return false
    end
    -- MEME REGLE QUE PARTOUT AILLEURS, et elle est ecrite ici parce que cette
    -- fonction est declaree AVANT `forEachTarget` et garde donc sa propre
    -- boucle. C'est exactement le cas que le commentaire de la plage annonce :
    -- brancher les operations une par une garantit qu'il en reste une qui ne
    -- l'est pas, et celle-la aurait ete la plus utilisee des trois.
    local moved = 0
    if Roll.seln > 0 then
        for i in pairs(Roll.selset) do if q(i) then moved = moved + 1 end end
    elseif Roll.range_a then
        for i = 1, Roll.count do
            if Roll.InRange(i) and q(i) then moved = moved + 1 end
        end
    else
        for i = 1, Roll.count do if q(i) then moved = moved + 1 end end
    end
    if moved > 0 then Roll.Commit("MIDI: quantize") end
    return moved
end

-- ===========================================================================
-- Command layer — offline note-list operations shared by BOTH hosts
--
-- Every op below acts on the current selection when there is one, else on all
-- notes (except where it explicitly requires a selection), and mints ONE undo
-- point. The model is unit-agnostic: the host passes concrete amounts in its
-- own cache unit (seconds for a take, beats for a loop) — a nudge distance, an
-- arp rate, a paste anchor. Structural ops (count changes) delete/insert then
-- sort+Sync+undo once; value ops reuse the live writers (MoveLive/ResizeLive/
-- SetVelLive) then Commit. None of this runs in the frame path, so command-path
-- allocation (closures, scratch growth) is fine; the render loop stays alloc-free.
-- ===========================================================================

-- Reproducible PRNG (Park–Miller) so randomized ops never touch global RNG
-- state and a re-run with the same seed repeats exactly.
local rng = 1
local function rseed(s) s = math.floor(s) % 2147483646; rng = (s <= 0) and 1 or s end
local function rnd() rng = (rng * 16807) % 2147483647; return rng / 2147483647 end
Roll.seed = 0

-- structural-op scratch (reused; command-path only)
local gS, gL, gP, gV = {}, {}, {}, {}   -- gathered target values
local rsS, rsP = {}, {}                 -- reselect (start,pitch) identity buffers

local function forEachTarget(fn)
    if Roll.seln > 0 then
        for i in pairs(Roll.selset) do fn(i) end
    elseif Roll.range_a then
        for i = 1, Roll.count do if Roll.InRange(i) then fn(i) end end
    else
        for i = 1, Roll.count do fn(i) end
    end
end

-- Snapshot target notes' values into gS/gL/gP/gV. Returns count, avg velocity,
-- min start, max end.
local function gatherTargets()
    local n, sum, a, b = 0, 0, math.huge, -math.huge
    local function take(i)
        n = n + 1
        gS[n], gL[n], gP[n], gV[n] = Roll.starts[i], Roll.lens[i], Roll.pitches[i], Roll.vels[i]
        sum = sum + Roll.vels[i]
        if gS[n] < a then a = gS[n] end
        if gS[n] + gL[n] > b then b = gS[n] + gL[n] end
    end
    forEachTarget(take)
    return n, (n > 0 and sum / n or 100), a, b
end

local function deleteSelectedRaw()   -- delete selected notes (no sort/sync/undo)
    for i = Roll.count, 1, -1 do if Roll.selset[i] then Roll.backend.deleteNote(i) end end
end

-- Clear selection, then reselect the notes matching the given (start,pitch)
-- identities — used to keep the *copies* selected after duplicate/paste so the
-- gesture chains.
function Roll.SelectByIdentity(sArr, pArr, n)
    Roll.ClearSel()
    if not n or n == 0 then return end
    for i = 1, Roll.count do
        local p  = Roll.pitches[i]
        local ms = math.floor(Roll.starts[i] * 1000 + 0.5)
        for k = 1, n do
            if pArr[k] == p and math.floor(sArr[k] * 1000 + 0.5) == ms then Roll.AddSel(i) break end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Selection depth
-- ---------------------------------------------------------------------------
function Roll.SelectAll() return Roll.SelectBox(-1e18, 1e18, 0, 127, false) end

function Roll.SelectInvert()
    local n, last = 0, nil
    for i = 1, Roll.count do
        if Roll.selset[i] then Roll.selset[i] = nil
        else Roll.selset[i] = true; n = n + 1; last = i end
    end
    -- recount cleanly (invert may have left holes)
    n = 0; last = nil
    for i = 1, Roll.count do if Roll.selset[i] then n = n + 1; last = i end end
    Roll.seln, Roll.sel = n, last
    return n
end

-- Select every note similar to the primary by "vel" | "len" | "pitch" (± tol).
function Roll.SelectSimilar(mode, tol)
    if not Roll.sel then return 0 end
    local ref = (mode == "vel" and Roll.vels[Roll.sel])
             or (mode == "len" and Roll.lens[Roll.sel])
             or Roll.pitches[Roll.sel]
    Roll.ClearSel()
    for i = 1, Roll.count do
        local v = (mode == "vel" and Roll.vels[i]) or (mode == "len" and Roll.lens[i]) or Roll.pitches[i]
        if math.abs(v - ref) <= tol then Roll.AddSel(i) end
    end
    return Roll.seln
end

-- ---------------------------------------------------------------------------
-- Value transforms (reuse the live writers, one Commit)
-- ---------------------------------------------------------------------------
function Roll.Transpose(d)
    if not Roll.backend or d == 0 then return 0 end
    local moved = 0
    forEachTarget(function(i)
        local np = Roll.pitches[i] + d
        if np < 0 then np = 0 elseif np > 127 then np = 127 end
        if np ~= Roll.pitches[i] then Roll.MoveLive(i, Roll.starts[i], np); moved = moved + 1 end
    end)
    if moved > 0 then Roll.Commit("MIDI: transpose") end
    return moved
end

function Roll.Nudge(dt)
    if not Roll.backend or dt == 0 then return 0 end
    local moved = 0
    forEachTarget(function(i)
        local nt = Roll.starts[i] + dt
        if nt < 0 then nt = 0 end
        if nt ~= Roll.starts[i] then Roll.MoveLive(i, nt, Roll.pitches[i]); moved = moved + 1 end
    end)
    if moved > 0 then Roll.Commit("MIDI: nudge") end
    return moved
end

function Roll.SetLengthAll(len)
    if not Roll.backend or len <= 0 then return 0 end
    local n = 0
    forEachTarget(function(i)
        if math.abs(Roll.lens[i] - len) > 1e-6 then Roll.ResizeLive(i, len); n = n + 1 end
    end)
    if n > 0 then Roll.Commit("MIDI: set length") end
    return n
end

-- MULTIPLIER LA LONGUEUR des notes visees. Doubler et diviser par deux sont
-- les deux gestes que Cedric a places sur Win, et ce sont les seuls facteurs
-- qui gardent une figure sur la grille : ×1,5 sort du binaire des la premiere
-- application. Le plancher est un centieme de beat, pour qu'une division
-- repetee ne fabrique pas de notes de duree nulle qu'on ne peut plus attraper.
function Roll.ScaleLen(f)
    if not Roll.backend or not f or f <= 0 then return 0 end
    local n = 0
    forEachTarget(function(i)
        local nl = Roll.lens[i] * f
        if nl < 0.01 then nl = 0.01 end
        if math.abs(nl - Roll.lens[i]) > 1e-6 then
            Roll.ResizeLive(i, nl); n = n + 1
        end
    end)
    if n > 0 then Roll.Commit("MIDI: scale length") end
    return n
end

-- PEINDRE UNE LIGNE DROITE DE NOTES entre deux points de la grille.
--
-- `step` est le pas de temps, `len` la duree de chaque note. La hauteur
-- interpole de p0 a p1 : une ligne horizontale fait une roulade, une ligne
-- oblique fait une gamme — c'est ce que REAPER appelle « paint a straight line
-- of notes », et l'interpolation EST le geste.
--
-- `chord` (optionnel) empile une triade AU-DESSUS DE CHAQUE NOTE : c'est ainsi
-- que « paint notes and chords » se fait sans une seconde fonction — un accord
-- n'est qu'une ligne a plusieurs voix. La triade est DIATONIQUE quand une gamme
-- est posee : on monte de deux degres puis de deux degres, ce qui donne un
-- accord mineur sur le second degre d'une majeure, comme il se doit. Sans
-- gamme, la tierce majeure et la quinte — le choix de REAPER, et il vaut mieux
-- qu'un refus.
local chordBuf = {}
local function chordAbove(p)
    local c = chordBuf
    c[1] = p
    if not Roll.scale_on then
        c[2], c[3] = p + 4, p + 7
        return c
    end
    local q, steps = p, 0
    while q < 127 and steps < 2 do
        q = q + 1
        if Roll.InScale(q) then steps = steps + 1 end
    end
    c[2] = q
    steps = 0
    while q < 127 and steps < 2 do
        q = q + 1
        if Roll.InScale(q) then steps = steps + 1 end
    end
    c[3] = q
    return c
end

function Roll.PaintLine(t0, p0, t1, p1, step, len, vel, chord)
    if not Roll.backend or not step or step <= 0 then return 0 end
    if t1 < t0 then t0, t1, p0, p1 = t1, t0, p1, p0 end
    local span = t1 - t0
    local nsteps = math.floor(span / step + 1e-6)
    if nsteps > 512 then nsteps = 512 end     -- garde-fou : un geste, pas un
    local n = 0                               -- generateur
    for k = 0, nsteps do
        local at = t0 + k * step
        local f  = (nsteps > 0) and (k / nsteps) or 0
        local pp = math.floor(p0 + (p1 - p0) * f + 0.5)
        if pp < 0 then pp = 0 elseif pp > 127 then pp = 127 end
        if chord then
            local c = chordAbove(pp)
            for j = 1, 3 do
                local q = c[j]
                if q >= 0 and q <= 127 and not Roll.At(at + step * 0.5, q) then
                    Roll.backend.insertNote(at, q, len, vel); n = n + 1
                end
            end
        elseif not Roll.At(at + step * 0.5, pp) then
            Roll.backend.insertNote(at, pp, len, vel); n = n + 1
        end
    end
    if n > 0 then
        Roll.backend.sort()
        Roll.Sync()
        Roll.backend.undo("MIDI: paint notes")
    end
    return n
end

-- Extend each target note to the start of the next note in time (any pitch),
-- plus `gap` (default 0). The universal "legato / connect".
local legStarts = {}
function Roll.Legato(gap)
    if not Roll.backend or Roll.count == 0 then return 0 end
    gap = gap or 0
    local m = 0
    for i = 1, Roll.count do m = m + 1; legStarts[m] = Roll.starts[i] end
    for k = #legStarts, m + 1, -1 do legStarts[k] = nil end
    table.sort(legStarts)
    local changed = 0
    forEachTarget(function(i)
        local s = Roll.starts[i]
        local ns
        for k = 1, m do if legStarts[k] > s + 1e-6 then ns = legStarts[k] break end end
        if ns then
            local nl = ns - s + gap
            if nl > 1e-4 and math.abs(nl - Roll.lens[i]) > 1e-4 then Roll.ResizeLive(i, nl); changed = changed + 1 end
        end
    end)
    if changed > 0 then Roll.Commit("MIDI: legato") end
    return changed
end

-- Reverse the timing of the target notes within their own bounding span.
function Roll.Reverse()
    if not Roll.backend then return 0 end
    local a, b = math.huge, -math.huge
    forEachTarget(function(i)
        local s, e = Roll.starts[i], Roll.starts[i] + Roll.lens[i]
        if s < a then a = s end
        if e > b then b = e end
    end)
    if a == math.huge then return 0 end
    local n = 0
    forEachTarget(function(i)
        local ns = a + b - (Roll.starts[i] + Roll.lens[i])
        if ns < 0 then ns = 0 end
        Roll.MoveLive(i, ns, Roll.pitches[i]); n = n + 1
    end)
    if n > 0 then Roll.Commit("MIDI: reverse") end
    return n
end

-- Mirror pitch around a pivot (nil = mean pitch of the targets, rounded).
function Roll.InvertPitch(pivot)
    if not Roll.backend then return 0 end
    if not pivot then
        local sum, n = 0, 0
        forEachTarget(function(i) sum = sum + Roll.pitches[i]; n = n + 1 end)
        if n == 0 then return 0 end
        pivot = math.floor(sum / n + 0.5)
    end
    local n = 0
    forEachTarget(function(i)
        local np = 2 * pivot - Roll.pitches[i]
        if np < 0 then np = 0 elseif np > 127 then np = 127 end
        if np ~= Roll.pitches[i] then Roll.MoveLive(i, Roll.starts[i], np); n = n + 1 end
    end)
    if n > 0 then Roll.Commit("MIDI: invert pitch") end
    return n
end

-- ---------------------------------------------------------------------------
-- Velocity shaping
-- ---------------------------------------------------------------------------
function Roll.VelocitySet(v)
    if not Roll.backend then return 0 end
    local n = 0
    forEachTarget(function(i) Roll.SetVelLive(i, v); n = n + 1 end)
    if n > 0 then Roll.Commit("MIDI: velocity") end
    return n
end

-- Scale velocity around a pivot (compress/expand): v' = pivot + (v-pivot)*f.
function Roll.VelocityScale(f, pivot)
    if not Roll.backend then return 0 end
    pivot = pivot or 64
    local n = 0
    forEachTarget(function(i) Roll.SetVelLive(i, pivot + (Roll.vels[i] - pivot) * f); n = n + 1 end)
    if n > 0 then Roll.Commit("MIDI: velocity scale") end
    return n
end

-- Linear velocity ramp v0→v1 across the targets ordered by start time.
local rampIdx = {}
function Roll.VelocityRamp(v0, v1)
    if not Roll.backend then return 0 end
    local n = 0
    forEachTarget(function(i) n = n + 1; rampIdx[n] = i end)
    for k = #rampIdx, n + 1, -1 do rampIdx[k] = nil end
    if n == 0 then return 0 end
    table.sort(rampIdx, function(x, y) return Roll.starts[x] < Roll.starts[y] end)
    for k = 1, n do
        local f = (n == 1) and 1 or (k - 1) / (n - 1)
        Roll.SetVelLive(rampIdx[k], v0 + (v1 - v0) * f)
    end
    Roll.Commit("MIDI: velocity ramp")
    return n
end

-- Bounded, seeded jitter of start / velocity / length (amounts in cache units,
-- velocity in 0..127). Seeded so it's reproducible and undoable.
function Roll.Humanize(tAmt, vAmt, lAmt)
    if not Roll.backend then return 0 end
    Roll.seed = Roll.seed + 1
    rseed(Roll.seed * 40503)
    local n = 0
    forEachTarget(function(i)
        if tAmt and tAmt > 0 then
            local ns = Roll.starts[i] + (rnd() * 2 - 1) * tAmt
            if ns < 0 then ns = 0 end
            Roll.MoveLive(i, ns, Roll.pitches[i])
        end
        if lAmt and lAmt > 0 then
            local nl = Roll.lens[i] + (rnd() * 2 - 1) * lAmt
            if nl < 1e-3 then nl = 1e-3 end
            Roll.ResizeLive(i, nl)
        end
        if vAmt and vAmt > 0 then
            Roll.SetVelLive(i, Roll.vels[i] + math.floor((rnd() * 2 - 1) * vAmt + 0.5))
        end
        n = n + 1
    end)
    if n > 0 then Roll.Commit("MIDI: humanize") end
    return n
end

-- ---------------------------------------------------------------------------
-- Structural: duplicate / clipboard / glue / split
-- ---------------------------------------------------------------------------
-- Clone targets, offset by (dt time, dp pitch), and select the copies so the
-- gesture chains (repeated duplicate). dt/dp in cache units.
function Roll.Duplicate(dt, dp)
    if not Roll.backend then return 0 end
    dt, dp = dt or 0, dp or 0
    local n = gatherTargets()
    if n == 0 then return 0 end
    for k = 1, n do
        local np = gP[k] + dp
        if np < 0 then np = 0 elseif np > 127 then np = 127 end
        local ns = gS[k] + dt
        if ns < 0 then ns = 0 end
        Roll.backend.insertNote(ns, np, gL[k], gV[k])
        rsS[k], rsP[k] = ns, np
    end
    Roll.backend.sort()
    Roll.Sync()
    Roll.SelectByIdentity(rsS, rsP, n)
    Roll.backend.undo("MIDI: duplicate")
    return n
end

-- POSER DES NOTES A DES POSITIONS DONNEES, sans toucher a la selection.
--
-- `Roll.Duplicate(0, 0)` semblait faire l'affaire pour un copier-glisser, et
-- ne le faisait pas : il re-selectionne les copies PAR LEUR IDENTITE (depart,
-- hauteur), et une copie posee au meme endroit a exactement l'identite de son
-- original. Les deux se retrouvaient donc selectionnes, le glisser les
-- emmenait ENSEMBLE, et on voyait un simple deplacement — « Ctrl+glisser ne
-- copie rien », alors que la duplication avait bien eu lieu.
--
-- D'ou cette fonction, et la facon de s'en servir : on laisse le glisser
-- deplacer les notes d'ORIGINE, et au relachement on repose une copie la ou
-- elles etaient. L'etat final est le meme que chez REAPER — l'original a sa
-- place, la copie a destination — et la selection reste sur ce qu'on vient de
-- deplacer, ce qui est ce qu'on veut pour enchainer.
--
-- Aucune identite a comparer, aucun index a suivre pendant le geste : une
-- passe d'insertion, un tri, un point d'annulation.
-- DOUBLER UN GROUPE ET REPARTIR AVEC L'UN DES DEUX EXEMPLAIRES.
--
-- C'est le copier-glisser, et il demande une chose que ni `Duplicate` ni `Sync`
-- ne savent faire : apres l'insertion il y a DEUX notes a chaque position, et
-- il faut en designer exactement UNE par position. Les deux fonctions
-- precedentes re-selectionnent par IDENTITE — le couple (depart, hauteur) —
-- donc elles prennent les deux, et le glisser emporte l'original avec la copie.
-- Le geste marche alors parfaitement et ne se voit pas.
--
-- Ici on RESERVE : chaque entree de la photo reclame un index encore libre a sa
-- position. Peu importe lequel des deux exemplaires elle obtient — ils sont
-- identiques a cet instant — ce qui compte est qu'il y en ait un par entree, et
-- qu'il en reste autant sur place. C'est ce qui fait qu'on voit l'original
-- rester pendant qu'on emmene la copie, des le premier pixel du glisser.
--
-- La photo est mise a jour au passage : ses index pointaient sur des notes
-- d'avant l'insertion, et un tri les a tous deplaces.
local claimed = {}
function Roll.StampAndClaim(list, n)
    if not Roll.backend or not n or n <= 0 then return 0 end
    for k = 1, n do
        local e = list[k]
        if e and e.s and e.p then
            Roll.backend.insertNote(e.s, e.p, e.l or 0.25, e.v or 100)
        end
    end
    Roll.backend.sort()
    -- `readAll` remplit les tableaux ET rend le compte, comme dans Sync. On ne
    -- passe PAS par Sync : elle re-selectionne par identite, ce qui est
    -- exactement ce qu'on doit eviter ici.
    Roll.count = Roll.backend.readAll()

    for i = 1, Roll.count do claimed[i] = nil end
    Roll.ClearSel()
    local got = 0
    for k = 1, n do
        local e = list[k]
        local ms = math.floor(e.s * 1000 + 0.5)
        for i = 1, Roll.count do
            if not claimed[i] and Roll.pitches[i] == e.p
               and math.floor(Roll.starts[i] * 1000 + 0.5) == ms then
                claimed[i] = true
                e.i = i
                Roll.AddSel(i)
                got = got + 1
                break
            end
        end
    end
    Roll.version = Roll.version + 1
    Roll.backend.undo("MIDI: copy notes")
    return got
end

Roll.clip = { n = 0, s = {}, l = {}, p = {}, v = {} }
function Roll.Copy()
    local c = Roll.clip
    local base = math.huge
    forEachTarget(function(i) if Roll.starts[i] < base then base = Roll.starts[i] end end)
    if base == math.huge then c.n = 0; return 0 end
    local n = 0
    forEachTarget(function(i)
        n = n + 1
        c.s[n], c.l[n], c.p[n], c.v[n] = Roll.starts[i] - base, Roll.lens[i], Roll.pitches[i], Roll.vels[i]
    end)
    c.n = n
    return n
end

-- Cut needs a real selection: Copy falls back to "all notes" when nothing is
-- selected, but DeleteSel is a no-op then — which would silently copy the whole
-- clip and delete nothing.
function Roll.Cut()
    if Roll.seln == 0 and not Roll.range_a then return 0 end
    local n = Roll.Copy()
    if n > 0 then Roll.DeleteSel() end
    return n
end

function Roll.HasClip() return Roll.clip.n > 0 end

-- Paste the clipboard anchored so its first note starts at `at` (cache units).
function Roll.Paste(at)
    local c = Roll.clip
    if c.n == 0 or not Roll.backend then return 0 end
    at = at or 0
    for k = 1, c.n do
        local ns = at + c.s[k]
        if ns < 0 then ns = 0 end
        Roll.backend.insertNote(ns, c.p[k], c.l[k], c.v[k])
        rsS[k], rsP[k] = ns, c.p[k]
    end
    Roll.backend.sort()
    Roll.Sync()
    Roll.SelectByIdentity(rsS, rsP, c.n)
    Roll.backend.undo("MIDI: paste")
    return c.n
end

-- Merge selected same-pitch notes that overlap or touch into single notes.
function Roll.Glue()
    if not Roll.backend or Roll.seln < 2 then return 0 end
    local n = gatherTargets()
    -- sort target values by pitch then start (index array over gathered values)
    local order = rampIdx
    for k = 1, n do order[k] = k end
    for k = #order, n + 1, -1 do order[k] = nil end
    table.sort(order, function(x, y)
        if gP[x] ~= gP[y] then return gP[x] < gP[y] end
        return gS[x] < gS[y]
    end)
    -- build merged runs
    local mS, mL, mP, mV, mn = {}, {}, {}, {}, 0
    local cs, ce, cp, cv, cvn
    local function flush()
        if cp then mn = mn + 1; mS[mn] = cs; mL[mn] = ce - cs; mP[mn] = cp; mV[mn] = math.floor(cv / cvn + 0.5) end
    end
    for k = 1, n do
        local idx = order[k]
        local s, e, p = gS[idx], gS[idx] + gL[idx], gP[idx]
        if cp == p and s <= ce + 1e-6 then
            if e > ce then ce = e end
            cv = cv + gV[idx]; cvn = cvn + 1
        else
            flush()
            cs, ce, cp, cv, cvn = s, e, p, gV[idx], 1
        end
    end
    flush()
    if mn == 0 then return 0 end
    deleteSelectedRaw()
    for k = 1, mn do Roll.backend.insertNote(mS[k], mP[k], mL[k], mV[k]); rsS[k], rsP[k] = mS[k], mP[k] end
    Roll.backend.sort()
    Roll.Sync()
    Roll.SelectByIdentity(rsS, rsP, mn)
    Roll.backend.undo("MIDI: glue")
    return mn
end

-- Split every target note that straddles time `at` (cache units) in two.
function Roll.SplitAt(at)
    if not Roll.backend then return 0 end
    -- collect crossing targets (index + values), don't mutate while scanning
    local ci, n = {}, 0
    forEachTarget(function(i)
        if Roll.starts[i] < at - 1e-6 and Roll.starts[i] + Roll.lens[i] > at + 1e-6 then
            n = n + 1; ci[n] = i; gS[n] = Roll.starts[i]; gL[n] = Roll.lens[i]
            gP[n] = Roll.pitches[i]; gV[n] = Roll.vels[i]
        end
    end)
    if n == 0 then return 0 end
    for k = 1, n do
        Roll.backend.setNote(ci[k], nil, at - gS[k], nil, nil)            -- shorten first half
        Roll.backend.insertNote(at, gP[k], gS[k] + gL[k] - at, gV[k])     -- second half
    end
    Roll.backend.sort()
    Roll.Sync()
    Roll.backend.undo("MIDI: split")
    return n
end

-- ---------------------------------------------------------------------------
-- Chord / scale
-- ---------------------------------------------------------------------------
Roll.SCALES = {
    { name = "Chromatic",  iv = { 0,1,2,3,4,5,6,7,8,9,10,11 } },
    { name = "Major",      iv = { 0,2,4,5,7,9,11 } },
    { name = "Nat minor",  iv = { 0,2,3,5,7,8,10 } },
    { name = "Harm minor", iv = { 0,2,3,5,7,8,11 } },
    { name = "Mel minor",  iv = { 0,2,3,5,7,9,11 } },
    { name = "Dorian",     iv = { 0,2,3,5,7,9,10 } },
    { name = "Phrygian",   iv = { 0,1,3,5,7,8,10 } },
    { name = "Lydian",     iv = { 0,2,4,6,7,9,11 } },
    { name = "Mixolydian", iv = { 0,2,4,5,7,9,10 } },
    { name = "Locrian",    iv = { 0,1,3,5,6,8,10 } },
    { name = "Penta maj",  iv = { 0,2,4,7,9 } },
    { name = "Penta min",  iv = { 0,3,5,7,10 } },
    { name = "Blues",      iv = { 0,3,5,6,7,10 } },
}
Roll.CHORDS = {
    { name = "Major",  iv = { 0,4,7 } },   { name = "Minor",  iv = { 0,3,7 } },
    { name = "Maj7",   iv = { 0,4,7,11 } },{ name = "Min7",   iv = { 0,3,7,10 } },
    { name = "Dom7",   iv = { 0,4,7,10 } },{ name = "Sus2",   iv = { 0,2,7 } },
    { name = "Sus4",   iv = { 0,5,7 } },   { name = "Dim",    iv = { 0,3,6 } },
    { name = "Aug",    iv = { 0,4,8 } },   { name = "Power5", iv = { 0,7 } },
    { name = "Octave", iv = { 0,12 } },
}

Roll.scale_on   = false
Roll.scale_root = 0
Roll.scale_ver  = 0     -- bumped on any scale change (host grid-buffer key)
Roll.scale_mask = {}
for i = 0, 11 do Roll.scale_mask[i] = true end

function Roll.SetScale(root, intervals)
    Roll.scale_root = root % 12
    for i = 0, 11 do Roll.scale_mask[i] = false end
    for _, iv in ipairs(intervals) do Roll.scale_mask[iv % 12] = true end
    Roll.scale_on = true
    Roll.scale_ver = Roll.scale_ver + 1
end
function Roll.ClearScale() Roll.scale_on = false; Roll.scale_ver = Roll.scale_ver + 1 end
function Roll.InScale(p)
    if not Roll.scale_on then return true end
    return Roll.scale_mask[(p - Roll.scale_root) % 12] == true
end
function Roll.SnapPitch(p)
    if not Roll.scale_on then return p end
    for d = 0, 6 do
        if p - d >= 0 and Roll.InScale(p - d) then return p - d end
        if p + d <= 127 and Roll.InScale(p + d) then return p + d end
    end
    return p
end
function Roll.SnapToScale()
    if not Roll.backend or not Roll.scale_on then return 0 end
    local n = 0
    forEachTarget(function(i)
        local np = Roll.SnapPitch(Roll.pitches[i])
        if np ~= Roll.pitches[i] then Roll.MoveLive(i, Roll.starts[i], np); n = n + 1 end
    end)
    if n > 0 then Roll.Commit("MIDI: snap to scale") end
    return n
end
local function scaleStep(p, dir)
    for _ = 1, 24 do
        p = p + dir
        if p < 0 or p > 127 then return nil end
        if Roll.InScale(p) then return p end
    end
    return nil
end
function Roll.TransposeInScale(steps)
    if not Roll.backend or not Roll.scale_on or steps == 0 then return 0 end
    local dir, cnt = (steps > 0 and 1 or -1), math.abs(steps)
    local n = 0
    forEachTarget(function(i)
        local p = Roll.pitches[i]
        if not Roll.InScale(p) then p = Roll.SnapPitch(p) end
        for _ = 1, cnt do local np = scaleStep(p, dir); if np then p = np end end
        if p ~= Roll.pitches[i] then Roll.MoveLive(i, Roll.starts[i], p); n = n + 1 end
    end)
    if n > 0 then Roll.Commit("MIDI: transpose in scale") end
    return n
end

-- Stamp a chord at (t, root): one note per interval. len/vel in cache units/0..127.
function Roll.InsertChord(t, root, intervals, len, vel)
    if not Roll.backend or len <= 0 then return 0 end
    local n = 0
    for _, iv in ipairs(intervals) do
        local p = root + iv
        if p >= 0 and p <= 127 then
            Roll.backend.insertNote(t, p, len, vel); rsS[n + 1] = t; rsP[n + 1] = p; n = n + 1
        end
    end
    if n == 0 then return 0 end
    Roll.backend.sort()
    Roll.Sync()
    Roll.SelectByIdentity(rsS, rsP, n)
    Roll.backend.undo("MIDI: chord")
    return n
end

-- ---------------------------------------------------------------------------
-- Generators (offline bake): arpeggiate + euclidean
-- ---------------------------------------------------------------------------
local seqP = {}   -- arp pitch sequence scratch
-- Replace the selected CHORD with an arpeggio filling its span. rate/gate in
-- cache units; mode = "up"|"down"|"updown"|"random"; octaves ≥ 1. Caps output.
function Roll.Arpeggiate(rate, mode, gate, octaves)
    if not Roll.backend or Roll.seln == 0 or rate <= 0 then return 0 end
    gate = gate or 0.9; octaves = octaves or 1
    local n, avg, a, b = gatherTargets()
    if n == 0 or b <= a then return 0 end
    -- distinct sorted pitches
    local pset, pitches, pn = {}, {}, 0
    for k = 1, n do
        local p = gP[k]
        if not pset[p] then pset[p] = true; pn = pn + 1; pitches[pn] = p end
    end
    for k = #pitches, pn + 1, -1 do pitches[k] = nil end
    table.sort(pitches)
    -- expand octaves
    local base = pn
    for o = 1, octaves - 1 do
        for k = 1, base do local p = pitches[k] + 12 * o; if p <= 127 then pn = pn + 1; pitches[pn] = p end end
    end
    if pn > base then table.sort(pitches) end   -- octaves append out of order
    -- build the play order
    local sn = 0
    if mode == "down" then
        for k = pn, 1, -1 do sn = sn + 1; seqP[sn] = pitches[k] end
    elseif mode == "updown" then
        for k = 1, pn do sn = sn + 1; seqP[sn] = pitches[k] end
        for k = pn - 1, 2, -1 do sn = sn + 1; seqP[sn] = pitches[k] end
    else
        for k = 1, pn do sn = sn + 1; seqP[sn] = pitches[k] end
    end
    for k = #seqP, sn + 1, -1 do seqP[k] = nil end
    if sn == 0 then return 0 end
    local vel = math.floor(avg + 0.5)
    rseed((Roll.seed + 1) * 40503); Roll.seed = Roll.seed + 1
    -- bake
    deleteSelectedRaw()
    local t, k, made = a, 0, 0
    while t < b - 1e-6 and made < 512 do
        local p = (mode == "random") and seqP[math.floor(rnd() * sn) + 1] or seqP[(k % sn) + 1]
        local len = rate * gate
        if t + len > b then len = b - t end
        if len > 1e-4 then
            Roll.backend.insertNote(t, p, len, vel); rsS[made + 1] = t; rsP[made + 1] = p; made = made + 1
        end
        t = t + rate; k = k + 1
    end
    Roll.backend.sort()
    Roll.Sync()
    Roll.SelectByIdentity(rsS, rsP, made)
    Roll.backend.undo("MIDI: arpeggiate")
    return made
end

-- Even (Euclidean-style) distribution of `pulses` hits over `steps` cells in
-- [a,b] at `pitch`. rotation shifts the pattern. Adds notes (does not clear).
function Roll.Euclidean(a, b, pitch, steps, pulses, vel, rotation)
    if not Roll.backend or steps < 1 or b <= a then return 0 end
    if pulses < 0 then pulses = 0 elseif pulses > steps then pulses = steps end
    rotation = rotation or 0
    local cell = (b - a) / steps
    -- seed the accumulator so cell 0 (the downbeat) can fire; starting at 0
    -- pushes every hit one cell late and silences the downbeat entirely
    local made, bucket = 0, steps - pulses
    for i = 0, steps - 1 do
        bucket = bucket + pulses
        local hit = false
        if bucket >= steps then bucket = bucket - steps; hit = true end
        if hit then
            local si = (i + rotation) % steps
            Roll.backend.insertNote(a + si * cell, pitch, cell * 0.9, vel)
            rsS[made + 1] = a + si * cell; rsP[made + 1] = pitch; made = made + 1
        end
    end
    if made == 0 then return 0 end
    Roll.backend.sort()
    Roll.Sync()
    Roll.SelectByIdentity(rsS, rsP, made)
    Roll.backend.undo("MIDI: euclid")
    return made
end

return Roll
