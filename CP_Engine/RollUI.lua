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
-- Musicians think in bars, not in "the span of what I selected". A one-bar
-- pattern whose last note is a 16th ending just before the barline must repeat
-- at bar 2, not a 16th early — which is what the raw span gives. So the offset
-- is the distance from the BAR CONTAINING the selection start to the BAR END at
-- or after the selection end. Using barFloor(a) rather than a itself preserves
-- the pattern's position inside its bar (a phrase starting on the "and" of 1
-- lands on the "and" of 1 in the next bar).
--
-- Hosts that don't provide barFloor/barCeil keep the old span behaviour.
local function dupOffset(ctx)
    local a, b = selBounds(ctx.Roll)
    if a == math.huge then return 0 end
    if ctx.barFloor and ctx.barCeil then
        local dt = ctx.barCeil(b) - ctx.barFloor(a)
        if dt > 1e-9 then return dt end
    end
    local dt = b - a
    if dt <= 0 then dt = ctx.gridStep(a) end
    return dt
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
-- Keyboard map (note-editing commands only; the host keeps play/zoom/undo/home)
-- Returns true when it consumed the key.
-- ---------------------------------------------------------------------------
function RollUI.HandleKey(char, ctx)
    local Roll, Keys = ctx.Roll, ctx.Keys
    if not Roll.backend then return false end
    local shift = ctx.Shift and ctx.Shift()
    local ctrl  = ctx.Ctrl and ctx.Ctrl()
    local alt   = ctx.Alt and ctx.Alt()
    local function flash(m) if ctx.flash then ctx.flash(m) end end
    local ref = (Roll.sel and Roll.starts[Roll.sel]) or 0

    -- Keyboard note-navigation (the "focus walk"): Alt+←/→ walks the notes
    -- of the anchor's pitch row (drum-row friendly), Alt+↑/↓ walks all notes
    -- in time order; Shift+Alt extends the selection instead of replacing
    -- it. One O(n) pass per keypress, no sort, wraps at the ends. The
    -- focused note auditions, so you can hear a phrase by walking it.
    if alt and Roll.count > 0
       and (char == Keys.LEFT or char == Keys.RIGHT
            or char == Keys.UP or char == Keys.DOWN) then
        local anchor = Roll.sel
        local as = anchor and Roll.starts[anchor]
        local ap = anchor and Roll.pitches[anchor]
        local fwd = (char == Keys.RIGHT or char == Keys.DOWN)
        local rowOnly = anchor and (char == Keys.LEFT or char == Keys.RIGHT)
                        and ap or nil
        local function lt(s1, p1, s2, p2)          -- (start, pitch) lex order
            return s1 < s2 or (s1 == s2 and p1 < p2)
        end
        local best, ext                            -- next note, and wrap end
        for i = 1, Roll.count do
            if i ~= anchor and (not rowOnly or Roll.pitches[i] == rowOnly) then
                local s, p = Roll.starts[i], Roll.pitches[i]
                local ok
                if not anchor then ok = true
                elseif fwd then ok = lt(as, ap, s, p)
                else ok = lt(s, p, as, ap) end
                if ok and (not best
                           or (fwd and lt(s, p, Roll.starts[best], Roll.pitches[best]))
                           or (not fwd and lt(Roll.starts[best], Roll.pitches[best], s, p))) then
                    best = i
                end
                if not ext
                   or (fwd and lt(s, p, Roll.starts[ext], Roll.pitches[ext]))
                   or (not fwd and lt(Roll.starts[ext], Roll.pitches[ext], s, p)) then
                    ext = i
                end
            end
        end
        local tgt = best or ext                    -- ext = wrap around the end
        if tgt then
            if shift and anchor then Roll.AddSel(tgt)
            else Roll.SelectOnly(tgt) end
            if ctx.audition then ctx.audition(Roll.pitches[tgt], Roll.vels[tgt]) end
        end
        return true
    end

    if char == 1 then                                   -- Ctrl+A: select all
        Roll.SelectAll(); return true
    elseif char == 4 then                               -- Ctrl+D: duplicate
        flash(doDuplicate(ctx)); return true
    elseif char == 3 then                               -- Ctrl+C: copy
        local n = Roll.Copy(); flash(n .. " copied"); return true
    elseif char == 24 then                              -- Ctrl+X: cut
        local n = Roll.Cut(); flash(n .. " cut"); return true
    elseif char == 22 then                              -- Ctrl+V: paste
        local at = ctx.pasteAt and ctx.pasteAt() or ref
        local n = Roll.Paste(at); flash(n .. " pasted"); return true
    elseif char == Keys.DELETE and Roll.seln > 0 then   -- delete selection
        if Roll.seln > 1 then Roll.DeleteSel() else Roll.Delete(Roll.sel) end
        return true
    elseif char == 113 or char == 81 then               -- q / Q: quantize
        local n = Roll.Quantize(ctx.snap); flash(n .. " quantized"); return true
    elseif char == Keys.ESCAPE and Roll.seln > 0 then   -- deselect
        Roll.ClearSel(); return true
    elseif Roll.seln > 0 and (char == Keys.UP or char == Keys.DOWN) then
        local dir = (char == Keys.UP) and 1 or -1
        if ctrl and Roll.scale_on then Roll.TransposeInScale(dir)
        elseif shift then Roll.Transpose(dir * 12)
        else Roll.Transpose(dir) end
        if ctx.audition and Roll.sel then ctx.audition(Roll.pitches[Roll.sel], Roll.vels[Roll.sel]) end
        return true
    elseif Roll.seln > 0 and (char == Keys.LEFT or char == Keys.RIGHT) then
        local dir = (char == Keys.RIGHT) and 1 or -1
        Roll.Nudge(dir * ctx.gridStep(ref)); return true
    end
    return false
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

return RollUI
