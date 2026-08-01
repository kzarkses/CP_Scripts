-- CP_Engine — Warp
--
-- COOKING THE STRETCH (roadmap phase 4).
--
-- There are two ways to put a loop at the project's tempo, and they are not
-- variants of one another:
--
--   REPITCH   read the file faster. No window, no latency, exact — and the
--             key moves with the speed, which is the vinyl trade-off and is
--             often what you want on drums.
--   STRETCH   keep the key. REAPER can do it live, and the measurement said
--             what that costs: 2.3 % of the audio thread per voice and 85 to
--             139 ms of priming before the first sample comes out. A clip
--             that has to sound on the boundary cannot spend a tenth of a
--             second thinking about it.
--
-- So the stretch is not performed, it is COOKED: rendered once, to a real
-- file, at the tempo it is going to be played at — and then played back at
-- rate 1.0, which costs exactly what any other sample costs. The trade moves
-- from "every voice, every block, forever" to "one render, once, per tempo".
--
-- WHAT THIS REPAIRS TODAY. "Stretch (keeps the key)" was a silent repitch:
-- the rate routine answered with a rate AND whether the key was meant to be
-- preserved, and the caller took the rate and dropped the second half. The
-- menu said one thing and the ear heard another, with nothing in between to
-- notice. Nothing here would have fixed that on its own — but there is now
-- somewhere for the second half of that answer to go.
--
-- THE CACHE. Keyed by (file, region, target tempo) because those three are
-- exactly what changes the result, and by nothing else. It lives beside the
-- scripts rather than beside the user's samples: a cooked file is ours, it is
-- reproducible, and it has no business appearing in someone's sample folder
-- under a name they did not choose.
--
-- COOKING DOES NOT HAPPEN ON A CLICK. Request() enqueues and returns at once,
-- Tick() renders ONE entry per frame. The frame that renders does hitch — a
-- four-bar loop is on the order of a tenth of a second — and that is why the
-- cell can say "baking" during it instead of the window appearing to freeze
-- for no stated reason.

local Warp = {}

local r = reaper
local Bake = nil

-- Where cooked files live. Under REAPER's resource path, so it travels with
-- the installation, survives a project move, and is one folder to delete when
-- someone wants the disk back.
local CACHE_DIR = nil

function Warp.init(reaper_api, bake_module)
    r = reaper_api or r
    Bake = bake_module or Bake
    CACHE_DIR = r.GetResourcePath() .. "/Scripts/CP_Scripts_Cache/warp/"
    r.RecursiveCreateDirectory(CACHE_DIR, 0)
end

-- ---------------------------------------------------------------------------
-- Identity of a cooked file
-- ---------------------------------------------------------------------------
-- A short, stable, filesystem-safe digest of the four things that decide the
-- result. Not a cryptographic hash — a collision here would play the wrong
-- sample, so it is made wide enough that it will not happen, and the source
-- basename is kept in the name so the folder stays readable by a human who
-- opens it wondering what all this is.
local function digest(s)
    -- FNV-1a, 32 bits, in the integer range Lua 5.3+ handles exactly.
    local h = 2166136261
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end

local function baseName(path)
    local n = path:match("([^/\\]+)$") or path
    n = n:match("^(.*)%.[^.]+$") or n
    return (n:gsub("[^%w%-_]", "_"):sub(1, 40))
end

-- The key AND the path. One function, so the two can never drift: a cache
-- that looks up by one name and writes by another is a cache that always
-- misses and never stops growing.
function Warp.PathFor(path, s0, s1, bpm)
    if not path or path == "" then return nil end
    s0 = s0 or 0
    s1 = s1 or 0
    bpm = bpm or 0
    local key = string.format("%s|%.6f|%.6f|%.4f", path, s0, s1, bpm)
    return string.format("%s%s_%08x.wav", CACHE_DIR, baseName(path), digest(key)), key
end

local function fileExists(p)
    local f = p and io.open(p, "rb")
    if not f then return false end
    f:close()
    return true
end

-- ---------------------------------------------------------------------------
-- The queue. At most one render per frame, and never the same entry twice.
-- ---------------------------------------------------------------------------
local queued  = {}    -- [key] = { path, s0, s1, bpm, rate, dst }
local order   = {}    -- keys, oldest first
local failed  = {}    -- [key] = reason. A file that cannot be cooked must not
                      -- be re-attempted every frame for the rest of the session.
local baking  = nil   -- the key being rendered on THIS frame

-- CE QUI MANQUAIT POUR QUE « STRETCH » CESSE DE MENTIR.
--
-- Une case en stretch joue un REPITCH tant que la version cuite n'existe pas —
-- decision assumee, elle est en temps et seule la tonalite est fausse. Mais
-- rien ne prevenait quand la cuisson finissait : la case restait un repitch
-- jusqu'au prochain lancement manuel, c'est-a-dire souvent jusqu'a la fin de la
-- session. Un compteur suffit : il change a chaque fin de cuisson, l'hote le
-- compare a celui qu'il avait et rearme ce qui doit l'etre.
local version = 0

function Warp.Version() return version end

-- Is a cooked version on disk? Returns its path, or nil.
function Warp.Get(path, s0, s1, bpm)
    local dst = Warp.PathFor(path, s0, s1, bpm)
    if dst and fileExists(dst) then return dst end
    return nil
end

-- "none" | "ready" | "queued" | "baking" | "failed"  — what the cell shows.
function Warp.State(path, s0, s1, bpm)
    local dst, key = Warp.PathFor(path, s0, s1, bpm)
    if not dst then return "none" end
    if fileExists(dst) then return "ready" end
    if baking == key then return "baking" end
    if queued[key] then return "queued" end
    if failed[key] then return "failed" end
    return "none"
end

-- Ask for a cooked version. Returns at once — the render happens in Tick.
-- `rate` is how fast the file must run to sit at `bpm`; it is passed rather
-- than recomputed so the caller's single answer on a file's tempo
-- (Engine/SrcTempo) stays the only one.
function Warp.Request(path, s0, s1, bpm, rate)
    if not path or path == "" then return false end
    if not rate or math.abs(rate - 1.0) < 1e-6 then return false end
    local dst, key = Warp.PathFor(path, s0, s1, bpm)
    if not dst or fileExists(dst) then return false end
    if queued[key] or failed[key] or baking == key then return false end
    queued[key] = { path = path, s0 = s0, s1 = s1, bpm = bpm,
                    rate = rate, dst = dst }
    order[#order + 1] = key
    return true
end

-- Cook one queued entry. Call once per frame from the host; a no-op while the
-- queue is empty, which is almost always.
function Warp.Tick()
    if #order == 0 then return end
    local key = table.remove(order, 1)
    local q = queued[key]
    queued[key] = nil
    if not q then return end
    if fileExists(q.dst) then return end          -- someone else got there
    baking = key
    local frames, err = Bake.FileRegionToWav(q.path, q.s0, q.s1, q.dst, {
        rate     = q.rate,
        preserve = true,        -- the whole point: the key does not move
        -- I_PITCHMODE left alone: the project's own default is the user's
        -- stated preference for how REAPER stretches, and overriding it here
        -- would make a cooked clip sound unlike everything else they own.
    })
    baking = nil
    if not frames then
        failed[key] = err or "render failed"
        -- A half-written file would be read as a valid cache hit forever.
        os.remove(q.dst)
    end
    -- Reussite ou echec, l'etat de cette case vient de changer : dans un cas
    -- elle peut passer au fichier cuit, dans l'autre elle doit dire qu'elle a
    -- echoue plutot que d'annoncer une cuisson en cours pour toujours.
    version = version + 1
    return key, frames, err
end

-- Forget a failure so it can be retried (the file may have come back, the
-- disk may have space again). Called by the UI, never on a timer.
function Warp.Retry(path, s0, s1, bpm)
    local _, key = Warp.PathFor(path, s0, s1, bpm)
    if key then
        failed[key] = nil
        version = version + 1
    end
end

-- Cette case a-t-elle echoue, et pourquoi ? Un echec etait DEFINITIF pour la
-- session et muet : ni raison affichee, ni moyen de reessayer. Les deux
-- manquaient, et `Warp.Retry` n'avait aucun appelant.
function Warp.Failure(path, s0, s1, bpm)
    local _, key = Warp.PathFor(path, s0, s1, bpm)
    return key and failed[key] or nil
end

function Warp.Pending() return #order end

-- ---------------------------------------------------------------------------
-- The whole answer, for a clip descriptor
-- ---------------------------------------------------------------------------
-- Given a clip and how fast it must run, says WHAT to play and AT WHAT RATE:
--
--   repitch, or no tempo to follow  -> the original file, at the rate
--   stretch, cooked                 -> the cooked file, at 1.0
--   stretch, not cooked yet         -> the original file at the rate, and a
--                                      request is filed
--
-- That last line is a deliberate choice and it is worth stating: while the
-- cooked version is missing, a stretched cell PLAYS AS A REPITCH rather than
-- staying silent. It is in time — which is what the launch was for — and only
-- the key is wrong, for one pass. Silence would have been the purer answer
-- and the useless one.
--
-- Returns path, rate, state.
function Warp.Resolve(clip, rate, stretch)
    local path = clip and clip.path
    if not path or not stretch or math.abs((rate or 1) - 1.0) < 1e-6 then
        return path, rate or 1.0, "none"
    end
    local s0 = clip.offs or 0
    local s1 = clip.len and (s0 + clip.len) or 0
    local bpm = r.Master_GetTempo() or 120
    local dst = Warp.Get(path, s0, s1, bpm)
    if dst then return dst, 1.0, "ready" end
    Warp.Request(path, s0, s1, bpm, rate)
    return path, rate, Warp.State(path, s0, s1, bpm)
end

return Warp
