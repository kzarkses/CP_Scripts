-- CP_Engine — Clip
-- The missing concept (refonte chantier 5, ANALYSE_Ecosysteme.md §4).
-- The four apps manipulate the same object under four names — a file in
-- the Explorer, a pad in the Sampler, an item/take in the Editor, a lane
-- in the Looper. All of them are: a reference to a media + a region +
-- playback parameters. This module is that object, plus a stable string
-- form so it can travel over any dumb channel (DragBus/Bus records,
-- P_EXT, ExtState).
--
-- Pure data — no reaper API, no UI, loadable anywhere (including tests).
--
-- Fields (all optional beyond `kind`):
--   kind        "audio" | "midi"
--   name, color
--   path        source file                       (audio)
--   offs, len   region, in SOURCE seconds        (audio)
--   root        reference note for repitch       (audio)
--   tempo_mode  "none" | "repitch" | "stretch"   (audio)
--   src_bpm     announced/detected source tempo  (audio)
--   gain, pitch, rate
--   notes       parallel arrays of the Roll model: s/l/p/v (start QN,
--               length QN, pitch, velocity)                     (midi)
--   bars        loop length in measures                         (midi)
--   q           launch quantize: "none" | "beat" | "bar"
--   lmode       launch mode:    "oneshot" | "loop"

local Clip = {}

Clip.VERSION = "CPC1"

function Clip.new(kind)
    return {
        kind  = kind or "audio",
        gain  = 1.0,
        pitch = 0.0,
        rate  = 1.0,
        q     = "none",
        lmode = "oneshot",
    }
end

-- ---------------------------------------------------------------------------
-- Clip colour
--
-- An INDEX into a fixed palette, not an RGB value. Three reasons, and they
-- are the same three every time this choice comes up:
--   · it serialises as one digit, and the descriptor travels over channels
--     where every byte is a byte;
--   · two windows showing the same clip show the same colour, forever,
--     without either of them agreeing on a colour space first;
--   · a palette can be RE-TUNED for a light theme one day; a stored RGB
--     cannot be.
-- The hues are chosen to survive a dark canvas AND to stay apart from each
-- other at a 3-pixel band. 0 or nil = no colour, which is not "black" — it is
-- the cell keeping the theme's own ground.
Clip.COLORS = {
    { 0.86, 0.32, 0.30 },   -- 1 red
    { 0.90, 0.56, 0.24 },   -- 2 orange
    { 0.87, 0.79, 0.28 },   -- 3 yellow
    { 0.44, 0.76, 0.40 },   -- 4 green
    { 0.30, 0.72, 0.70 },   -- 5 teal
    { 0.38, 0.58, 0.88 },   -- 6 blue
    { 0.62, 0.46, 0.86 },   -- 7 violet
    { 0.88, 0.44, 0.68 },   -- 8 pink
}

Clip.COLOR_NAMES = { "Red", "Orange", "Yellow", "Green",
                     "Teal", "Blue", "Violet", "Pink" }

-- The three components of a clip's colour, or nil when it has none. Returning
-- three numbers rather than the table keeps callers from holding a reference
-- into the palette and painting with a stale one.
function Clip.ColorOf(c)
    local i = c and c.color
    if not i or i < 1 then return nil end
    local p = Clip.COLORS[i]
    if not p then return nil end
    return p[1], p[2], p[3]
end

-- ---------------------------------------------------------------------------
-- POSITIONAL TAG — the legacy view. Engine/Ident is the current one.
--
-- This was identity-by-address: a cell's name derived from WHERE it sits, so
-- moving a clip renamed it and two clips that ever shared a cell shared a
-- name. Engine/Ident replaced it with a number the clip owns (`c.id`), and
-- `Ident.TagOf` is the single place that answers with one or the other.
--
-- These two stay, and are still correct, because projects written before the
-- identity existed have positional tags in their lanes and must keep opening.
-- The two number spaces do not overlap: a positional tag is below
-- `Ident.BASE`, an identity is at or above it. New code calls Ident.
-- ---------------------------------------------------------------------------
function Clip.CellTag(cell, scene)
    local t, s = cell, scene
    if type(cell) ~= "number" then
        if type(cell) ~= "string" then return 0 end
        local a, b = cell:match("^(%d+),(%d+)$")
        t, s = tonumber(a), tonumber(b)
    end
    if not t or not s then return 0 end
    return t * 1000 + s + 1
end

-- Inverse: tag -> track, scene. Nil when the lane holds nothing tagged.
function Clip.CellOfTag(tag)
    if not tag or tag <= 0 then return nil end
    local k = math.floor(tag + 0.5) - 1
    return k // 1000, k % 1000
end

-- ---------------------------------------------------------------------------
-- Serialization: "CPC1|key=value|key=value|…". Values are %-escaped so a
-- path containing the separator survives; numbers go through %.14g (times
-- and rates round-trip well below any audible epsilon). MIDI notes pack
-- as "s,l,p,v;s,l,p,v;…" — one quad per note, Roll order preserved.
-- ---------------------------------------------------------------------------
local function esc(s)
    return (s:gsub("[%%|=\n]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function num(v) return string.format("%.14g", v) end

-- Field registry: name → kind ("s" string, "n" number). Notes and kind
-- are handled apart. New fields append here; unknown fields are IGNORED
-- on read, so old readers survive newer writers (forward compatible).
local FIELDS = {
    { "name", "s" }, { "color", "n" },
    { "path", "s" }, { "offs", "n" }, { "len", "n" }, { "root", "n" },
    { "tempo_mode", "s" }, { "src_bpm", "n" },
    { "gain", "n" }, { "pitch", "n" }, { "rate", "n" },
    { "bars", "n" },
    { "q", "s" }, { "lmode", "s" },
    -- where the clip came from ("looper:2") — the editor:apply consumer
    -- routes the edited clip home with it, and the editor uses it to talk
    -- to the live lane (playhead, launch)
    { "origin", "s" },
    -- session grid coordinates ("track,scene") when the clip lives in a
    -- cell: origin says which lane PLAYS it, cell says where it is STORED
    { "cell", "s" },
    -- STABLE IDENTITY (Engine/Ident). Allocated once, never reused, and it
    -- travels with the descriptor — which is what makes a clip findable after
    -- it moves, and distinguishable from the one that used to sit where it
    -- sits now. Absent in projects written before phase 2, and absent is a
    -- legitimate value: Ident.TagOf falls back to the positional tag.
    { "id", "n" },
}
local FIELD_KIND = {}
for _, f in ipairs(FIELDS) do FIELD_KIND[f[1]] = f[2] end

function Clip.serialize(c)
    local out = { Clip.VERSION, "kind=" .. (c.kind or "audio") }
    for _, f in ipairs(FIELDS) do
        local k, t = f[1], f[2]
        local v = c[k]
        if v ~= nil then
            out[#out + 1] = k .. "=" .. (t == "n" and num(v) or esc(tostring(v)))
        end
    end
    local nt = c.notes
    if nt and nt.s and #nt.s > 0 then
        local quads = {}
        for i = 1, #nt.s do
            quads[i] = num(nt.s[i]) .. "," .. num(nt.l[i]) .. ","
                    .. num(nt.p[i]) .. "," .. num(nt.v[i])
        end
        out[#out + 1] = "notes=" .. table.concat(quads, ";")
    end
    return table.concat(out, "|")
end

function Clip.deserialize(str)
    if type(str) ~= "string" then return nil, "not a string" end
    local first = str:match("^([^|]*)")
    if first ~= Clip.VERSION then return nil, "bad header: " .. tostring(first) end

    local c = Clip.new()
    for pair in str:sub(#first + 2):gmatch("[^|]+") do
        local k, v = pair:match("^([^=]+)=(.*)$")
        if k == "kind" then
            c.kind = v
        elseif k == "notes" then
            local s, l, p, vel = {}, {}, {}, {}
            for a, b, d, e in v:gmatch("([^,;]+),([^,;]+),([^,;]+),([^,;]+)") do
                s[#s + 1]   = tonumber(a)
                l[#l + 1]   = tonumber(b)
                p[#p + 1]   = tonumber(d)
                vel[#vel + 1] = tonumber(e)
            end
            c.notes = { s = s, l = l, p = p, v = vel }
        elseif k and FIELD_KIND[k] then
            c[k] = FIELD_KIND[k] == "n" and tonumber(v) or unesc(v)
        end
        -- unknown keys: skipped on purpose (see the registry note)
    end
    return c
end

return Clip
