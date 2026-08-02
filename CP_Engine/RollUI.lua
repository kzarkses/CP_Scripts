-- CP_Editor — RollUI
-- Shared command layer for the piano roll: one keyboard map and one transform
-- menu, driven by a host-supplied `ctx`, so CP_Editor and CP_Looper behave
-- IDENTICALLY (same shortcuts, same commands) — the "keep your bearings"
-- requirement, satisfied by construction. This module is pure logic + menu
-- DATA; it never draws. The host owns rendering, navigation and undo.
--
-- The `ctx` a host must provide:
--   ctx.Roll               the SAME Roll instance the host renders (not a fresh
--                          dofile — that would be a second, disconnected model)
--   ctx.Keys               the toolkit Keys table
--   ctx.Shift/Ctrl/Alt     modifier predicates (e.g. Core.ModShift) — optional
--   ctx.gridStep(t)        one grid step at cache-time t, in CACHE UNITS
--   ctx.snap(t)            snap a cache-time to the grid (cache units)
--   ctx.divToUnit(div)     whole-note division (0.0625 = 1/16) -> cache units
--   ctx.pasteAt()          paste anchor time (cache units)           [optional]
--   ctx.barFloor(t)        largest bar boundary <= t (cache units)   [optional]
--   ctx.barCeil(t)         smallest bar boundary >= t (cache units)  [optional]
--                          — both or neither; they make Duplicate bar-aware
--   ctx.fitLen()           length of a FIXED canvas (cache units)    [optional]
--   ctx.grow(need)         try to extend that canvas to `need`;      [optional]
--                          returns true on success
--   ctx.swingSnap(amt)     -> a swing-aware snap fn (0..1 amount)    [optional]
--   ctx.flash(msg)         status message                            [optional]
--   ctx.audition(p,v)      preview a pitch                           [optional]
--
-- Cache units are the host's: seconds for a MIDI take, beats for a gmem loop.
-- Every amount RollUI computes (nudge distance, arp rate, duplicate offset) is
-- expressed in those units via ctx, so the model stays unit-agnostic.

local RollUI = {}

local NOTE = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }

-- selection (or all) time bounds in cache units
local function selBounds(Roll)
    local a, b = math.huge, -math.huge
    local function f(i)
        local s = Roll.starts[i]; local e = s + Roll.lens[i]
        if s < a then a = s end
        if e > b then b = e end
    end
    if Roll.seln > 0 then for i in pairs(Roll.selset) do f(i) end
    else for i = 1, Roll.count do f(i) end end
    return a, b
end
local function selSpan(Roll)
    local a, b = selBounds(Roll)
    return (a == math.huge) and 0 or (b - a)
end
RollUI.SelSpan = selSpan

-- How far a Duplicate should move the copy.
--
-- Musicians think in musical units, not in "the span of what I selected": a
-- figure whose last note is a 16th ending just short of the next unit must
-- repeat ON that unit, not a 16th early, which is what the raw span gives.
--
-- WHICH unit is decided by what the selection already fills — that is the
-- whole point. Four 16ths covering beat 1 repeat on beat 2; a full bar repeats
-- on the next bar; a lone 16th repeats on the next grid step. Rounding the
-- span UP to a whole number of that unit does the rest: a figure filling most
-- of a bar rounds to the bar by itself, and one and a half bars rounds to two.
--
-- The offset is anchored on the selection, not on an absolute lattice, so the
-- copy keeps the original's placement inside its unit for free — a phrase
-- starting on the "and" of 1 lands on the "and" of 1 in the next unit — and it
-- stays correct in both hosts, whose cache unit is beats for a loop and
-- seconds for a take.
local function ceilUnits(span, unit)
    local n = math.ceil(span / unit - 1e-6)
    return (n < 1 and 1 or n) * unit
end

local function dupOffset(ctx)
    local a, b = selBounds(ctx.Roll)
    if a == math.huge then return 0 end
    local span = b - a
    local grid = ctx.gridStep and ctx.gridStep(a) or 0

    -- bar length in cache units, measured through the host's own bar map so
    -- tempo maps and odd meters come out right. The probe has to clear
    -- barCeil's "already on a barline" epsilon, hence half a grid step.
    local bar
    if ctx.barFloor and ctx.barCeil then
        local f = ctx.barFloor(a)
        local c = ctx.barCeil(f + (grid > 0 and grid * 0.5 or 1e-3))
        if c and c > f + 1e-9 then bar = c - f end
    end
    if bar and span >= bar - 1e-6 then return ceilUnits(span, bar) end

    local beat = ctx.divToUnit and ctx.divToUnit(0.25) or nil
    if beat and beat > 0 and span >= beat - 1e-6 then return ceilUnits(span, beat) end

    if grid > 0 then return ceilUnits(span, grid) end
    return span > 0 and span or 1
end
RollUI.DupOffset = dupOffset

-- Duplicate, making room first when the host has a fixed-length canvas (the
-- looper's lane). Returns the message to flash.
local function doDuplicate(ctx)
    local dt = dupOffset(ctx)
    if dt <= 0 then return "nothing to duplicate" end
    local _, b = selBounds(ctx.Roll)
    local fit = ctx.fitLen and ctx.fitLen()
    if fit and fit > 0 then
        local need = b + dt
        if need > fit + 1e-9 then
            -- Do NOT wrap: for a full-loop selection the offset is a multiple of
            -- the loop length, so wrapping would stack every copy exactly on its
            -- original — a duplicate that doubles the note count and changes
            -- nothing audible. Grow the lane instead (FL/Ableton behaviour).
            if not (ctx.grow and ctx.grow(need)) then
                return "no room - raise the loop length"
            end
        end
    end
    return ctx.Roll.Duplicate(dt, 0) .. " duplicated"
end

-- ---------------------------------------------------------------------------
-- Clavier — la touche devient une ACTION, et l'action seule est executee
--
-- DEUX ENTREES, UNE SEULE MISE EN OEUVRE. Un hote qui a declare son
-- vocabulaire (`ctx.keymap`) fait resoudre la touche par CP_Engine/Keymap, donc
-- ses raccourcis sont configurables ; un hote qui n'en a pas declare passe par
-- la table historique ci-dessous et ne change pas d'un poil. Ce qui compte est
-- que le CORPS des actions ne soit ecrit qu'une fois : dupliquer la mise en
-- oeuvre « pour ne pas casser l'autre fenetre » est exactement la facon dont
-- deux editeurs finissent par ne plus se comporter pareil.
--
-- Renvoie true quand la touche a ete consommee.
-- ---------------------------------------------------------------------------

-- La table historique, telle qu'elle etait — devenue une simple traduction
-- (touche, modificateurs) → nom d'action.
local function legacyAct(char, Keys, shift, ctrl, alt)
    if alt and (char == Keys.LEFT or char == Keys.RIGHT
                or char == Keys.UP or char == Keys.DOWN) then
        if char == Keys.LEFT  then return shift and "walk.ext_prev_row" or "walk.prev_row" end
        if char == Keys.RIGHT then return shift and "walk.ext_next_row" or "walk.next_row" end
        if char == Keys.UP    then return shift and "walk.ext_prev" or "walk.prev" end
        return shift and "walk.ext_next" or "walk.next"
    end
    if char == 1  then return "sel.all" end
    if char == 4  then return "edit.duplicate" end
    if char == 3  then return "edit.copy" end
    if char == 24 then return "edit.cut" end
    if char == 22 then return "edit.paste" end
    if char == Keys.DELETE then return "edit.delete" end
    if char == 113 or char == 81 then return "edit.quantize" end
    if char == Keys.ESCAPE then return "sel.clear" end
    if char == Keys.UP or char == Keys.DOWN then
        local up = (char == Keys.UP)
        if ctrl  then return up and "note.scale_up"  or "note.scale_down" end
        if shift then return up and "note.octave_up" or "note.octave_down" end
        return up and "note.transpose_up" or "note.transpose_down"
    end
    if char == Keys.LEFT  then return "note.nudge_left" end
    if char == Keys.RIGHT then return "note.nudge_right" end
    return nil
end

-- LA MARCHE DE NOTE EN NOTE. Une passe O(n) par frappe, sans tri, qui reboucle
-- aux extremites. La note atteinte s'auditionne, donc on peut ecouter une
-- phrase en la parcourant.
local function walk(ctx, fwd, row_only, extend)
    local Roll = ctx.Roll
    if Roll.count == 0 then return true end
    local anchor = Roll.sel
    local as = anchor and Roll.starts[anchor]
    local ap = anchor and Roll.pitches[anchor]
    local rowOnly = (row_only and anchor) and ap or nil
    local function lt(s1, p1, s2, p2)          -- ordre lexical (depart, hauteur)
        return s1 < s2 or (s1 == s2 and p1 < p2)
    end
    local best, ext                            -- la suivante, et le bout ou boucler
    for i = 1, Roll.count do
        if i ~= anchor and (not rowOnly or Roll.pitches[i] == rowOnly) then
            local sp, pp = Roll.starts[i], Roll.pitches[i]
            local ok
            if not anchor then ok = true
            elseif fwd then ok = lt(as, ap, sp, pp)
            else ok = lt(sp, pp, as, ap) end
            if ok and (not best
                       or (fwd and lt(sp, pp, Roll.starts[best], Roll.pitches[best]))
                       or (not fwd and lt(Roll.starts[best], Roll.pitches[best], sp, pp))) then
                best = i
            end
            if not ext
               or (fwd and lt(sp, pp, Roll.starts[ext], Roll.pitches[ext]))
               or (not fwd and lt(Roll.starts[ext], Roll.pitches[ext], sp, pp)) then
                ext = i
            end
        end
    end
    local tgt = best or ext
    if tgt then
        if extend and anchor then Roll.AddSel(tgt) else Roll.SelectOnly(tgt) end
        if ctx.audition then ctx.audition(Roll.pitches[tgt], Roll.vels[tgt]) end
    end
    return true
end

-- Le corps des actions. Ecrit une fois, atteint par les deux entrees.
function RollUI.Do(act, ctx)
    local Roll = ctx.Roll
    if not act or not Roll.backend then return false end
    local function flash(m) if ctx.flash then ctx.flash(m) end end
    local ref = (Roll.sel and Roll.starts[Roll.sel]) or 0

    if act == "walk.prev_row"     then return walk(ctx, false, true,  false) end
    if act == "walk.next_row"     then return walk(ctx, true,  true,  false) end
    if act == "walk.prev"         then return walk(ctx, false, false, false) end
    if act == "walk.next"         then return walk(ctx, true,  false, false) end
    if act == "walk.ext_prev_row" then return walk(ctx, false, true,  true) end
    if act == "walk.ext_next_row" then return walk(ctx, true,  true,  true) end
    if act == "walk.ext_prev"     then return walk(ctx, false, false, true) end
    if act == "walk.ext_next"     then return walk(ctx, true,  false, true) end

    if act == "sel.all" then Roll.SelectAll() return true end
    if act == "sel.invert" then Roll.SelectInvert() return true end
    if act == "sel.clear" then
        if Roll.seln == 0 then return false end
        Roll.ClearSel() return true
    end
    if act == "edit.duplicate" then flash(doDuplicate(ctx)) return true end
    if act == "edit.copy"  then flash(Roll.Copy() .. " copied") return true end
    if act == "edit.cut"   then flash(Roll.Cut() .. " cut") return true end
    if act == "edit.paste" then
        local at = ctx.pasteAt and ctx.pasteAt() or ref
        flash(Roll.Paste(at) .. " pasted") return true
    end
    if act == "edit.delete" then
        if Roll.seln == 0 then return false end
        if Roll.seln > 1 then Roll.DeleteSel() else Roll.Delete(Roll.sel) end
        return true
    end
    if act == "edit.quantize" then
        flash(Roll.Quantize(ctx.snap) .. " quantized") return true
    end
    if act == "edit.legato" then flash(Roll.Legato(0) .. " legato") return true end

    local function transpose(d, in_scale)
        if Roll.seln == 0 then return false end
        if in_scale and Roll.scale_on then Roll.TransposeInScale(d)
        else Roll.Transpose(d) end
        if ctx.audition and Roll.sel then
            ctx.audition(Roll.pitches[Roll.sel], Roll.vels[Roll.sel])
        end
        return true
    end
    if act == "note.transpose_up"   then return transpose(1) end
    if act == "note.transpose_down" then return transpose(-1) end
    if act == "note.octave_up"      then return transpose(12) end
    if act == "note.octave_down"    then return transpose(-12) end
    if act == "note.scale_up"       then return transpose(1, true) end
    if act == "note.scale_down"     then return transpose(-1, true) end

    if act == "note.nudge_left" or act == "note.nudge_right" then
        if Roll.seln == 0 then return false end
        local dir = (act == "note.nudge_right") and 1 or -1
        Roll.Nudge(dir * ctx.gridStep(ref))
        return true
    end
    if act == "note.len_double" then Roll.ScaleLen(2) return true end
    if act == "note.len_halve"  then Roll.ScaleLen(0.5) return true end
    return false
end

function RollUI.HandleKey(char, ctx)
    local Roll, Keys = ctx.Roll, ctx.Keys
    if not Roll.backend then return false end
    local act
    if ctx.keymap and ctx.Keymap then
        act = ctx.Keymap.Key(ctx.keymap, char)
    else
        act = legacyAct(char, Keys,
                        ctx.Shift and ctx.Shift(), ctx.Ctrl and ctx.Ctrl(),
                        ctx.Alt and ctx.Alt())
    end
    return RollUI.Do(act, ctx) and true or false
end

-- ---------------------------------------------------------------------------
-- Transform menu (returns a NativeMenu items table)
-- ---------------------------------------------------------------------------
function RollUI.TransformMenu(ctx)
    local Roll = ctx.Roll
    local hasSel = Roll.seln > 0
    local one    = (Roll.seln == 1) and Roll.sel or nil
    local ref    = (Roll.sel and Roll.starts[Roll.sel]) or 0
    local grid   = ctx.gridStep(ref)
    local function flash(m) if ctx.flash then ctx.flash(m) end end

    local items = {}
    local function add(t) items[#items + 1] = t end

    -- clipboard / duplicate
    add({ label = "Duplicate", action = function()
        flash(doDuplicate(ctx))
    end })
    add({ label = "Copy", disabled = not hasSel,
          action = function() flash(Roll.Copy() .. " copied") end })
    add({ label = "Cut", disabled = not hasSel,
          action = function() Roll.Cut(); flash("cut") end })
    add({ label = "Paste", disabled = not Roll.HasClip(),
          action = function() flash(Roll.Paste(ctx.pasteAt and ctx.pasteAt() or ref) .. " pasted") end })
    add({ separator = true })

    -- pitch / time transforms
    add({ label = "Transpose", children = {
        { label = "+ Octave",    action = function() Roll.Transpose(12) end },
        { label = "- Octave",    action = function() Roll.Transpose(-12) end },
        { label = "+ Semitone",  action = function() Roll.Transpose(1) end },
        { label = "- Semitone",  action = function() Roll.Transpose(-1) end },
        { label = "+ Fifth",     action = function() Roll.Transpose(7) end },
    } })
    add({ label = "Nudge", children = {
        { label = "Nudge left (grid)",  action = function() Roll.Nudge(-grid) end },
        { label = "Nudge right (grid)", action = function() Roll.Nudge(grid) end },
    } })
    add({ label = "Length", children = {
        { label = "Set to grid",       action = function() flash(Roll.SetLengthAll(grid) .. " set") end },
        { label = "Legato (to next)",  action = function() flash(Roll.Legato(0) .. " legato") end },
    } })
    add({ label = "Reverse (time)", disabled = not hasSel,
          action = function() flash(Roll.Reverse() .. " reversed") end })
    add({ label = "Invert pitch", disabled = not hasSel,
          action = function() Roll.InvertPitch(nil) end })
    add({ separator = true })

    -- velocity / humanize / quantize
    add({ label = "Velocity", children = {
        { label = "Set 127", action = function() Roll.VelocitySet(127) end },
        { label = "Set 100", action = function() Roll.VelocitySet(100) end },
        { label = "Set 80",  action = function() Roll.VelocitySet(80) end },
        { label = "Set 64",  action = function() Roll.VelocitySet(64) end },
        { separator = true },
        { label = "Ramp up",   action = function() Roll.VelocityRamp(40, 120) end },
        { label = "Ramp down", action = function() Roll.VelocityRamp(120, 40) end },
        { label = "Compress",  action = function() Roll.VelocityScale(0.6, 64) end },
        { label = "Expand",    action = function() Roll.VelocityScale(1.4, 64) end },
    } })
    add({ label = "Humanize", children = {
        { label = "Light",  action = function() Roll.Humanize(grid * 0.06, 6, 0) end },
        { label = "Medium", action = function() Roll.Humanize(grid * 0.15, 14, grid * 0.10) end },
        { label = "Heavy",  action = function() Roll.Humanize(grid * 0.30, 24, grid * 0.20) end },
    } })
    do
        local q = {
            { label = "100%", action = function() flash(Roll.Quantize(ctx.snap, 1) .. " quantized") end },
            { label = "66%",  action = function() Roll.Quantize(ctx.snap, 0.66) end },
            { label = "50%",  action = function() Roll.Quantize(ctx.snap, 0.5) end },
        }
        if ctx.swingSnap then
            q[#q + 1] = { separator = true }
            q[#q + 1] = { label = "Swing 8%",  action = function() Roll.Quantize(ctx.swingSnap(0.08), 1) end }
            q[#q + 1] = { label = "Swing 16%", action = function() Roll.Quantize(ctx.swingSnap(0.16), 1) end }
        end
        add({ label = "Quantize", children = q })
    end
    add({ separator = true })

    -- scale
    do
        local rootItems, typeItems = {}, {}
        for rt = 0, 11 do
            rootItems[#rootItems + 1] = {
                label = NOTE[rt + 1], checked = Roll.scale_on and Roll.scale_root == rt,
                action = function() Roll.SetScale(rt, Roll.scale_iv or Roll.SCALES[2].iv) end }
        end
        typeItems[#typeItems + 1] = { label = "Off", checked = not Roll.scale_on,
            action = function() Roll.ClearScale() end }
        for _, sc in ipairs(Roll.SCALES) do
            typeItems[#typeItems + 1] = {
                label = sc.name, checked = Roll.scale_on and Roll.scale_name == sc.name,
                action = function() Roll.scale_iv = sc.iv; Roll.scale_name = sc.name; Roll.SetScale(Roll.scale_root, sc.iv) end }
        end
        add({ label = "Scale", children = {
            { label = "Root",  children = rootItems },
            { label = "Type",  children = typeItems },
            { separator = true },
            { label = "Snap selection to scale", disabled = not Roll.scale_on,
              action = function() flash(Roll.SnapToScale() .. " snapped") end },
        } })
    end

    -- chord from a single selected note
    do
        local ch = {}
        for _, c in ipairs(Roll.CHORDS) do
            ch[#ch + 1] = { label = c.name, action = function()
                if not one then return end
                -- the selected note IS the root: stamping interval 0 too would
                -- lay a duplicate on top of it
                local iv = {}
                for _, v in ipairs(c.iv) do if v ~= 0 then iv[#iv + 1] = v end end
                Roll.InsertChord(Roll.starts[one], Roll.pitches[one], iv, Roll.lens[one], Roll.vels[one])
            end }
        end
        add({ label = "Chord from note", disabled = not one, children = ch })
    end

    -- arpeggiate (offline bake of the selected chord)
    do
        local rates = { { "1/8", 0.125 }, { "1/16", 0.0625 }, { "1/16T", 1/24 }, { "1/32", 0.03125 } }
        local function rateItems(mode)
            local r = {}
            for _, rr in ipairs(rates) do
                r[#r + 1] = { label = rr[1], action = function()
                    local n = Roll.Arpeggiate(ctx.divToUnit(rr[2]), mode, 0.9, 1)
                    flash(n .. " arp notes")
                end }
            end
            return r
        end
        add({ label = "Arpeggiate", disabled = not hasSel, children = {
            { label = "Up",      children = rateItems("up") },
            { label = "Down",    children = rateItems("down") },
            { label = "Up/Down", children = rateItems("updown") },
            { label = "Random",  children = rateItems("random") },
        } })
    end

    -- euclidean fill over the selection's span, on its primary pitch
    do
        local presets = { { "3 of 8", 8, 3 }, { "4 of 8", 8, 4 }, { "5 of 8", 8, 5 },
                          { "5 of 16", 16, 5 }, { "7 of 16", 16, 7 }, { "9 of 16", 16, 9 } }
        local ec = {}
        for _, p in ipairs(presets) do
            ec[#ec + 1] = { label = p[1], action = function()
                local a, b = selBounds(Roll)
                if a == math.huge then return end
                local pitch = (Roll.sel and Roll.pitches[Roll.sel]) or 60
                local vel = (Roll.sel and Roll.vels[Roll.sel]) or 100
                flash(Roll.Euclidean(a, b, pitch, p[2], p[3], vel, 0) .. " hits")
            end }
        end
        add({ label = "Euclidean fill", disabled = not hasSel, children = ec })
    end

    return items
end

-- ---------------------------------------------------------------------------
-- Grid line weight — shared so both rolls read the same
-- ---------------------------------------------------------------------------
-- A grid drawn at one intensity is a wall of identical lines: at 1/16 you
-- cannot see where beat 3 is. Ranking measure > beat > eighth > finer puts the
-- pulse back in the picture. Both hosts index this table so a barline looks
-- like a barline whichever roll you are in.
--
-- Hosts DRAW it in passes, weakest first — subdivisions, eighths, beats,
-- barlines — and let each pass overwrite the previous where lines coincide.
-- Layering rather than classifying is what keeps odd meters and tempo maps
-- honest: a barline never has to land on the subdivision lattice to appear,
-- and a triplet grid keeps drawing triplets.
-- REMOVED. Grid weight used to be one colour faded four ways — 0.45 / 0.26 /
-- 0.15 / 0.085 of text_mute. Composited over a dark ground, the strongest of
-- the four, the barline, landed near 0.27: the line whose whole job was to cut
-- the view was the one you could least see, and no contrast setting could
-- reach it because alpha is not a colour. Both rolls now read four real theme
-- tokens at full alpha (canvas_line_bar / _beat / _sub / _fine), so the
-- hierarchy lives in the values and stays editable.
RollUI.GRID_ALPHA = nil

return RollUI
