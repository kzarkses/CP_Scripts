-- CP_Engine — Tracks
-- Track ownership (refonte chantier 4, ANALYSE_Ecosysteme.md §7): one
-- shared "CP" folder per project for the suite's infrastructure, and one
-- common mark P_EXT:CP = "<app>:<role>" on every track the suite owns —
-- on top of each app's specific tags. The mark is the ONLY discovery
-- authority: never find a CP track by its name (users rename things).
--
-- Adoption rule: existing tracks are marked where they stand — a user's
-- layout is never rearranged. Only genuinely NEW infrastructure is born
-- inside the CP folder.

local Tracks = {}

local r  -- reaper, injected

local EXT = "P_EXT:CP"

function Tracks.init(reaper_api)
    r = reaper_api
end

local function valid(tr) return tr and r.ValidatePtr2(0, tr, "MediaTrack*") end

function Tracks.Mark(tr, app, role)
    r.GetSetMediaTrackInfo_String(tr, EXT, app .. ":" .. role, true)
end

-- app, role of a marked track (nil, nil when unmarked).
function Tracks.MarkOf(tr)
    local ok, v = r.GetSetMediaTrackInfo_String(tr, EXT, "", false)
    if ok and v ~= "" then return v:match("^([^:]*):(.*)$") end
end

-- First track marked app:role (role nil = any role of that app).
function Tracks.Find(app, role)
    local want = role and (app .. ":" .. role)
    local prefix = app .. ":"
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        local ok, v = r.GetSetMediaTrackInfo_String(tr, EXT, "", false)
        if ok and v ~= "" then
            if want and v == want then return tr end
            if not want and v:sub(1, #prefix) == prefix then return tr end
        end
    end
end

-- The one CP folder. Found by mark only; created collapsed at the end of
-- the track list when absent (and asked for). While empty its folder
-- depth stays 0 — REAPER dislikes a folder head with no child; the first
-- NewChild opens it.
function Tracks.Folder(create)
    local tr = Tracks.Find("engine", "folder")
    if valid(tr) or not create then return tr end
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP", true)
    r.SetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT", 2)   -- born collapsed
    Tracks.Mark(tr, "engine", "folder")
    return tr
end

-- Append a NEW marked track inside the CP folder and return it. Depth
-- accounting is nesting-safe: the closing depth always rides on the
-- folder's last child, so the previous last child gives back one level
-- and keeps whatever inner folders it was closing.
function Tracks.NewChild(app, role, name)
    local folder = Tracks.Folder(true)
    local fidx = math.floor(
        r.GetMediaTrackInfo_Value(folder, "IP_TRACKNUMBER")) - 1
    local depth = r.GetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH")

    local idx, last
    if depth <= 0 then
        idx = fidx + 1                        -- first child ever
    else
        local run, i, n = depth, fidx + 1, r.CountTracks(0)
        last = folder
        while run > 0 and i < n do
            last = r.GetTrack(0, i)
            run = run + r.GetMediaTrackInfo_Value(last, "I_FOLDERDEPTH")
            i = i + 1
        end
        idx = i
    end

    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    if depth <= 0 or last == folder then
        r.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", -1)
    else
        local close = r.GetMediaTrackInfo_Value(last, "I_FOLDERDEPTH")
        r.SetMediaTrackInfo_Value(last, "I_FOLDERDEPTH", close + 1)
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", -1)
    end

    if name then
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
    end
    Tracks.Mark(tr, app, role)
    return tr
end

-- Find-or-create the app's infrastructure track. Existing marked tracks
-- are returned where they stand; second return says "was created".
function Tracks.Ensure(app, role, name)
    local tr = Tracks.Find(app, role)
    if valid(tr) then return tr, false end
    return Tracks.NewChild(app, role, name), true
end

return Tracks
