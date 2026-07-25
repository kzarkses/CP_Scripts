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
