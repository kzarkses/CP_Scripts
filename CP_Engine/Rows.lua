-- CP_Engine — Rows
-- The vertical row model shared by every piano-roll host (CP_Editor,
-- CP_Looper). A roll is either MELODIC — a contiguous, scrollable pitch
-- window — or DRUM — an arbitrary, sorted pitch LIST (kit pads + whatever
-- pitches the notes already use), where "one row up" can be a seven-
-- semitone jump. Everything that translates between rows and pitches
-- lives here so both hosts do it the same way, and so group operations
-- can move by ROWS (the only delta that makes sense on an arbitrary
-- list) instead of by semitones.
--
-- The host owns the rows table and hands it in — zero allocation per
-- frame once warm; Build is keyed on the inputs' versions and returns
-- without touching anything when nothing changed.

local Rows = {}

-- Build/refresh the host-owned table m = { list = {}, map = {}, n = 0,
-- drum = false, key = nil }. list is pitches top-down (list[1] is the
-- highest); map is pitch → row index.
--
-- o.drum       : true for drum rows
-- o.roll       : the Roll module (count/pitches/version) — its pitches are
--                always rows in drum mode, so no note can be off-grid
-- o.kit        : optional Kit module — pads with a sample become rows
-- o.view_hi    : melodic window top pitch (default 71)
-- o.view_rows  : melodic window height in rows (default 30)
--
-- Melodic clamps are written back as m.view_hi / m.view_rows for the host
-- to persist (an unclamped host value would re-key every frame).
-- Drum fallback when kit and roll are both empty: the GM drum octave
-- 51..36, so an empty lane still shows a usable grid.
function Rows.Build(m, o)
    local drum = o.drum and true or false
    local roll, kit = o.roll, o.kit
    local key = (drum and 1 or 0) .. ":" .. (roll and roll.version or 0)
             .. ":" .. (kit and kit.version or 0)
             .. ":" .. (o.view_hi or 0) .. ":" .. (o.view_rows or 0)
    if m.key == key then return m end
    m.key = key
    m.drum = drum
    local list = m.list
    for i = #list, 1, -1 do list[i] = nil end
    if drum then
        local set = {}
        if kit then
            for note = kit.BASE, kit.BASE + kit.MAX - 1 do
                local pad = kit.pads[note]
                if pad and pad.fx then set[note] = true end
            end
        end
        if roll then
            for i = 1, roll.count do set[roll.pitches[i]] = true end
        end
        for p = 127, 0, -1 do
            if set[p] then list[#list + 1] = p end
        end
        if #list == 0 then
            for p = 51, 36, -1 do list[#list + 1] = p end
        end
    else
        local nrows = o.view_rows or 30
        local hi = o.view_hi or 71
        local lo = hi - nrows + 1
        if lo < 0 then lo = 0; hi = math.min(127, nrows - 1) end
        if hi > 127 then hi = 127; lo = math.max(0, 127 - nrows + 1) end
        m.view_hi, m.view_rows = hi, hi - lo + 1
        for p = hi, lo, -1 do list[#list + 1] = p end
    end
    local map = m.map
    for k in pairs(map) do map[k] = nil end
    for idx = 1, #list do map[list[idx]] = idx end
    m.n = #list
    return m
end

-- Row index (1-based from the top) under a y position, clamped.
function Rows.AtY(m, my, ry, rowh)
    local i = math.floor((my - ry) / rowh) + 1
    if i < 1 then i = 1 elseif i > m.n then i = m.n end
    return i
end

-- Pitch under a y position (clamped to the visible rows).
function Rows.PitchAtY(m, my, ry, rowh)
    return m.list[Rows.AtY(m, my, ry, rowh)] or 60
end

-- Top y of a pitch's row — nil when the pitch has no row (melodic pitch
-- scrolled out of the window; never happens to a note pitch in drum mode).
function Rows.YOfPitch(m, p, ry, rowh)
    local i = m.map[p]
    if not i then return nil end
    return ry + (i - 1) * rowh
end

-- Move a pitch by a number of rows (positive = down the list = lower on
-- screen), clamped to the list. A pitch without a row comes back as-is.
function Rows.Shift(m, p, drows)
    local i = m.map[p]
    if not i then return p end
    i = i + drows
    if i < 1 then i = 1 elseif i > m.n then i = m.n end
    return m.list[i]
end

-- Note names, built once at load so labels are allocation-free per frame.
local NOTE_N = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local NOTE_NAME = {}
for p = 0, 127 do
    NOTE_NAME[p] = NOTE_N[p % 12 + 1] .. (math.floor(p / 12) - 1)
end

function Rows.NoteName(p) return NOTE_NAME[p] or "?" end

-- Row label: the kit pad's name in drum mode when one exists, else the
-- note name ("C3"). Zero allocation — everything is precomputed or stored.
function Rows.Label(m, p, kit)
    if m.drum and kit then
        local pad = kit.pads and kit.pads[p]
        if pad and pad.name and pad.name ~= "" then return pad.name end
    end
    return NOTE_NAME[p] or "?"
end

return Rows
