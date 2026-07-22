-- CP_Engine — Peaks
-- THE peaks service: one reader for every waveform in the suite (refonte
-- chantier 2 — fusion of CP_Editor's Wave.lua, superior reading, with
-- CP_MediaExplorer's Peaks.lua, superior cache).
--
-- Buffer layout (PCM_Source_GetPeaks) — encoded HERE and nowhere else:
--   reaper.new_array(count * channels * 2)
--   block 1 = maxima  → idx = (px-1)*channels + ch
--   block 2 = minima  → offset count*channels
--   retval low 20 bits = valid sample count
--   peakrate above the file samplerate degrades gracefully (REAPER reads
--   the source directly — the visible width bounds the cost).
--
-- Two surfaces over the same core:
--   Peaks.Read(src, path, t0, t1, w, gen)
--       Editor view: arbitrary source-time range, per-channel lanes
--       (stereo shows two lanes, Ableton-style), ONE entry mutating in
--       place — a pan drag re-reads every frame and must not allocate.
--   Peaks.Get(path, src, width)
--       Browser strip: whole file, channels collapsed to one mono lane,
--       LRU-cached per [path][width] (two-level so the per-frame lookup
--       needs zero string concat).
-- Both return nil while a .reapeaks build is in flight — async 0/1/2
-- state machine, one build at a time, shared by the two surfaces.

local Peaks = {}

local r  -- reaper, injected

function Peaks.init(reaper_api)
    r = reaper_api
end

-- ---------------------------------------------------------------------------
-- Pooled reaper.array buffers (exact size — GetPeaks contract). Public:
-- Ops borrows the pool for its own analysis reads.
-- ---------------------------------------------------------------------------
local arrays = {}

function Peaks.Array(sz)
    local a = arrays[sz]
    if not a then
        a = r.new_array(sz)
        arrays[sz] = a
    end
    return a
end

-- The one low-level read — the only place that touches the buffer layout.
local function readRaw(src, peakrate, t_start, ch, count)
    local buf = Peaks.Array(count * ch * 2)
    buf.clear()
    local retval = r.PCM_Source_GetPeaks(src, peakrate, t_start, ch, count, 0, buf)
    return buf, (retval and (retval & 0xfffff) or 0)
end

local function chanCount(src)
    local ch = r.GetMediaSourceNumChannels(src) or 1
    if ch < 1 then ch = 1 end
    if ch > 2 then ch = 2 end
    return ch
end

-- ---------------------------------------------------------------------------
-- Async peak building (documented 0/1/2 state machine, one build at a time)
-- ---------------------------------------------------------------------------
-- build = { path, src (owned), … } — src is a private source so the build
-- can never dangle when a caller's source cache evicts.
local build = nil

local function startBuild(path)
    if not path or path == "" then return end
    if build then
        if build.path == path then return end
        -- Abandon the previous build (finalize so REAPER closes the file).
        r.PCM_Source_BuildPeaks(build.src, 2)
        r.PCM_Source_Destroy(build.src)
        build = nil
    end
    local src = r.PCM_Source_CreateFromFile(path)
    if not src then return end
    if r.PCM_Source_BuildPeaks(src, 0) == 0 then
        -- Peaks already exist — nothing to do.
        r.PCM_Source_Destroy(src)
        return
    end
    build = { path = path, src = src }
end

-- Advance the in-flight build. Call once per defer frame; cheap no-op when
-- idle. Returns true while building (the app schedules a redraw).
function Peaks.Step()
    if not build then return false end
    local remaining = r.PCM_Source_BuildPeaks(build.src, 1)
    if remaining == 0 then
        r.PCM_Source_BuildPeaks(build.src, 2)
        r.PCM_Source_Destroy(build.src)
        build = nil
        return false
    end
    return true
end

function Peaks.Building(path)
    return build ~= nil and (path == nil or build.path == path)
end

-- ---------------------------------------------------------------------------
-- Editor view read (single cached entry — an editor shows one view at a
-- time; lanes mutate in place across reads)
-- ---------------------------------------------------------------------------
local view = { n = 0, ch = 1,
               maxs = { {}, {} }, mins = { {}, {} } }
local vck = { src = nil, t0 = -1, t1 = -1, w = 0, gen = -1 }

function Peaks.InvalidateView()
    vck.src = nil
end

-- src is borrowed (item take source or the app's own file source); path is
-- only used to kick a .reapeaks build when none exist. gen: bump to force a
-- re-read after an edit. Returns the shared entry, or nil while building.
function Peaks.Read(src, path, t0, t1, w, gen)
    w = math.floor(w)
    if w < 16 or not src or t1 <= t0 then return nil end
    if vck.src == src and vck.t0 == t0 and vck.t1 == t1 and vck.w == w
       and vck.gen == gen then
        return view
    end
    if build and path and build.path == path then return nil end

    local ch = chanCount(src)
    local count = w
    local buf, valid = readRaw(src, count / (t1 - t0), t0, ch, count)
    if valid <= 0 then
        startBuild(path)
        return nil
    end

    local n = math.min(valid, count)
    local min_base = count * ch
    for c = 1, ch do
        local maxs, mins = view.maxs[c], view.mins[c]
        for px = 1, n do
            local base = (px - 1) * ch + c
            local mx = buf[base]
            local mn = buf[min_base + base]
            if mx > 1 then mx = 1 elseif mx < -1 then mx = -1 end
            if mn > 1 then mn = 1 elseif mn < -1 then mn = -1 end
            maxs[px] = mx
            mins[px] = mn
        end
    end
    view.n, view.ch = n, ch
    vck.src, vck.t0, vck.t1, vck.w, vck.gen = src, t0, t1, w, gen
    return view
end

-- ---------------------------------------------------------------------------
-- Browser strip read, LRU-cached: [path][width] → { mins, maxs, n }
-- ---------------------------------------------------------------------------
local CACHE_MAX = 64   -- sized for waveform-row mode (~25 visible rows)
local cache     = {}   -- [path] = { [width] = entry }
local cache_n   = 0    -- total entries across paths
local tick      = 0

local function cacheGet(path, width)
    local per = cache[path]
    if not per then return nil end
    local e = per[width]
    if e then
        tick = tick + 1
        e.tick = tick
        return e
    end
    return nil
end

local function cachePut(path, width, entry)
    if cache_n >= CACHE_MAX then
        local op, ow, oldest_tick = nil, nil, math.huge
        for p, per in pairs(cache) do
            for w, e in pairs(per) do
                if e.tick < oldest_tick then op, ow, oldest_tick = p, w, e.tick end
            end
        end
        if op then
            cache[op][ow] = nil
            if next(cache[op]) == nil then cache[op] = nil end
            cache_n = cache_n - 1
        end
    end
    tick = tick + 1
    entry.tick = tick
    local per = cache[path]
    if not per then
        per = {}
        cache[path] = per
    end
    per[width] = entry
    cache_n = cache_n + 1
end

-- Read peaks for a whole file at a given pixel width. Returns
-- { mins, maxs, n } or nil while peaks are being built. `src` is borrowed
-- from the caller (its source cache) — only used within this call.
function Peaks.Get(path, src, width)
    width = math.floor(width)
    if width < 16 then width = 16 end

    local hit = cacheGet(path, width)
    if hit then return hit end

    -- Build in flight for this file: report "not ready" BEFORE any work —
    -- this branch runs every frame during a build (the caller keeps
    -- polling), and per-frame garbage here would be pure GC churn.
    if build and build.path == path then return nil end

    if not src then return nil end

    local len = r.GetMediaSourceLength(src)
    if not len or len <= 0 then return nil end
    local ch = chanCount(src)

    local count = width
    local buf, valid = readRaw(src, count / len, 0, ch, count)
    if valid <= 0 then
        -- No .reapeaks yet: kick the async build and report "not ready".
        startBuild(path)
        return nil
    end

    -- Collapse channels to a single mono min/max lane (strip display).
    local mins, maxs = {}, {}
    local n = math.min(valid, count)
    local min_base = count * ch
    for px = 1, n do
        local mx, mn = 0, 0
        local base = (px - 1) * ch
        for c = 1, ch do
            local vmax = buf[base + c] or 0
            local vmin = buf[min_base + base + c] or 0
            if vmax > mx then mx = vmax end
            if vmin < mn then mn = vmin end
        end
        if mx > 1 then mx = 1 elseif mx < -1 then mx = -1 end
        if mn > 1 then mn = 1 elseif mn < -1 then mn = -1 end
        maxs[px] = mx
        mins[px] = mn
    end

    local entry = { mins = mins, maxs = maxs, n = n }
    cachePut(path, width, entry)
    return entry
end

-- Drop cached lanes for a path (after a build completes, so the next Get
-- re-reads real data instead of a cached silence).
function Peaks.Invalidate(path)
    local per = cache[path]
    if not per then return end
    for _ in pairs(per) do
        cache_n = cache_n - 1
    end
    cache[path] = nil
end

function Peaks.Destroy()
    if build then
        r.PCM_Source_BuildPeaks(build.src, 2)
        r.PCM_Source_Destroy(build.src)
        build = nil
    end
    cache = {}
    cache_n = 0
    vck.src = nil
end

return Peaks
