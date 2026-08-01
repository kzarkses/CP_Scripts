-- CP_Engine — Ident
--
-- THE TABLE THAT WAS MISSING (ANALYSE_Ecosysteme.md §4, roadmap phase 2).
--
-- Nothing in this suite owned "this clip, in this state". Everything was
-- addressed by POSITION — t*1000+s for a grid cell, a lane index for a loop,
-- a column index for a sound. `Clip.CellTag` is the symptom: a foreign key
-- invented because there was no table to point at.
--
-- Addressing by position has exactly three consequences, and all three are
-- bugs you can reproduce today:
--
--   1. MOVE a clip and its name changes. A window following it by tag does
--      not follow the clip, it follows the hole the clip left — and starts
--      reporting whatever lands there next.
--   2. Two different clips that occupy the same cell at different times are
--      THE SAME NAME. A lane still holding the old one answers yes when asked
--      whether it holds the new one, and an edit lands in the clip you were
--      not editing.
--   3. Only a grid cell had a name at all. A Looper loop, an Editor item and
--      a Sampler pad are the same object, and none of them could be pointed
--      at, so each window kept its own private bookkeeping instead.
--
-- An identity is a NUMBER, not a string: it travels through a lane tag slot,
-- a gmem cell or a native lane field with no allocation and no parsing, and
-- it is compared with `==`. It is allocated once, stored IN the descriptor
-- (`clip.id`, serialized by Engine/Clip), and it never changes again.
--
-- WHERE a clip is stays where it already was — `clip.cell` — so this module
-- does not hold a second copy of the truth. The registry maps id -> clip and
-- nothing else; a caller that wants the coordinates reads them off the clip
-- it got back. One fact, one owner.
--
-- Pure Lua beyond the counter, which needs the project to persist in.

local Clip = nil    -- resolved lazily: Ident is loadable without it (tests)

local Ident = {}

local r = reaper

-- ---------------------------------------------------------------------------
-- THE TWO NUMBER SPACES, AND WHY THEY MUST NOT MEET
--
-- A legacy positional tag is t*1000 + s + 1, so with four columns and eight
-- scenes it lives in 1 .. 4009. Real identities start at BASE, far above any
-- grid this UI could grow to, so a reader can tell which kind of number it is
-- holding WITHOUT being told — which is the whole reason the migration costs
-- nothing: old projects keep writing positional tags into their lanes and new
-- ones write identities, into the same slot, at the same time.
--
-- BASE also has to stay small enough that BASE + n is exact in a double after
-- passing through gmem or the engine's lane field. 2^53 is the limit; a
-- million and a counter will not approach it in this century.
-- ---------------------------------------------------------------------------
Ident.BASE = 1000000

local EXT_SEC = "CP_Ident"
local EXT_KEY = "next"

-- The counter belongs to the PROJECT: two clips in one project must never
-- share an identity, and that is the only guarantee this needs to make.
-- Across projects they may collide, and it costs nothing — see `Get`.
local next_id = nil

local function loadCounter()
    if next_id then return next_id end
    local _, v = r.GetProjExtState(0, EXT_SEC, EXT_KEY)
    local n = math.floor(tonumber(v or "") or 0)
    next_id = (n > 0) and n or 1
    return next_id
end

-- ---------------------------------------------------------------------------
-- The registry. WEAK VALUES on purpose: a cell cleared, a clip dropped, a
-- window closed — the entry has to go with it. A registry that only ever
-- grows is a leak with a lookup table attached, and this one is written to
-- every time a grid loads.
-- ---------------------------------------------------------------------------
local reg = setmetatable({}, { __mode = "v" })

function Ident.init(reaper_api, clip_module)
    r = reaper_api or r
    Clip = clip_module or Clip
    next_id = nil
end

-- Allocate a fresh identity. Persisted immediately: allocation happens when a
-- clip is CREATED, which is rare, and a counter that only reaches the project
-- file at save time hands out the same number twice after a crash.
function Ident.NewId()
    local n = loadCounter()
    next_id = n + 1
    r.SetProjExtState(0, EXT_SEC, EXT_KEY, tostring(next_id))
    return Ident.BASE + n
end

-- Register a clip under the identity it already carries. Idempotent.
function Ident.Bind(c)
    if type(c) ~= "table" then return nil end
    local id = c.id
    if not id or id < Ident.BASE then return nil end
    reg[id] = c
    return id
end

-- The identity of this clip, allocating one the first time it is asked for.
-- Lazy on purpose: a descriptor that never needs to be pointed at never
-- spends a number, and the ones that do get theirs at the moment they enter
-- a grid — which is also the moment they become findable.
function Ident.Of(c)
    if type(c) ~= "table" then return 0 end
    if not c.id or c.id < Ident.BASE then c.id = Ident.NewId() end
    reg[c.id] = c
    return c.id
end

-- ---------------------------------------------------------------------------
-- THE COMPATIBILITY VIEW
--
-- One function, and it is the whole migration: a clip that has an identity
-- answers with it, one that does not answers with the positional tag it has
-- always answered with. Every call site that used to say
-- `Clip.CellTag(c.cell)` says this instead, and stops caring which era the
-- project it was handed comes from.
-- ---------------------------------------------------------------------------
function Ident.TagOf(c)
    if type(c) ~= "table" then return 0 end
    if c.id and c.id >= Ident.BASE then return c.id end
    if Clip and c.cell then return Clip.CellTag(c.cell) end
    return 0
end

-- The clip behind an identity, or NIL — and nil is the answer that matters.
-- A tag can outlive its clip in three ordinary ways: the cell was cleared,
-- the project was closed with the engine still holding the number, or the tag
-- was written by ANOTHER project in this REAPER session (the counter is
-- per-project, so identities do collide across projects). Every one of them
-- resolves to nil here rather than to somebody else's clip, because the
-- registry only holds clips this script actually loaded.
function Ident.Get(id)
    if not id or id < Ident.BASE then return nil end
    return reg[id]
end

-- Where a tag points, in grid coordinates: t, s. Handles both number spaces,
-- so callers that only want "which scene of this track" never learn there are
-- two. Nil when the tag names nothing we hold.
function Ident.CellOf(tag)
    if not tag or tag <= 0 then return nil end
    if tag < Ident.BASE then
        if Clip then return Clip.CellOfTag(tag) end
        return nil
    end
    local c = reg[tag]
    if not c or not c.cell then return nil end
    local t, s = c.cell:match("^(%d+),(%d+)$")
    t, s = tonumber(t), tonumber(s)
    if not t or not s then return nil end
    return t, s
end

-- A COPY IS ANOTHER CLIP. Duplicating a cell and keeping the identity would
-- give two clips one name, which is the exact defect this module exists to
-- remove — and it would be worse than the positional tag, because the two
-- would now be indistinguishable everywhere rather than only in one grid.
function Ident.Clear(c)
    if type(c) == "table" then c.id = nil end
    return c
end

-- Forget an identity without touching the clip (a cell being emptied). The
-- weak table would get there on its own at the next collection; saying it
-- explicitly means a window that clears a cell and immediately asks about the
-- tag gets the right answer on that frame, not one garbage cycle later.
function Ident.Forget(id)
    if id and id >= Ident.BASE then reg[id] = nil end
end

return Ident
