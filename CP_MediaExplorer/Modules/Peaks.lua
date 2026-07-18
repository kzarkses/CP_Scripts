-- CP_MediaExplorer — Peaks
-- Waveform peaks for the selected-file strip: read via PCM_Source_GetPeaks,
-- async build via PCM_Source_BuildPeaks, small in-memory cache.
--
-- Buffer layout (verified against TK/Meta Mixer implementations):
--   reaper.new_array(count * channels * 2)
--   block 1 = maxima  → idx = (px-1)*channels + ch
--   block 2 = minima  → idx = count*channels + (px-1)*channels + ch
--   retval low 20 bits = valid sample count.
--
-- Policy (2005-PC rule): ONE waveform at a time (the selected file), never
-- per-row thumbnails. Peaks build is driven mode 0→1→2 across defer frames;
-- at most one build in flight.

local Peaks = {}

local r  -- reaper, injected

function Peaks.init(reaper_api)
    r = reaper_api
end

-- ---------------------------------------------------------------------------
-- Cache: [path][width] → { mins = {}, maxs = {}, n = int }
-- Two-level so the per-frame lookup needs ZERO string concat (numbers as
-- second-level keys). Tiny LRU — the strip only ever shows one file, so 8
-- entries make re-selecting recent files instant.
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

-- ---------------------------------------------------------------------------
-- Async peak building (documented 0/1/2 state machine, one build at a time)
-- ---------------------------------------------------------------------------
-- build = { path, src (owned), stage }  — src is a private source so the
-- build can never dangle when the preview cache evicts.
local build = nil

local function startBuild(path)
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
-- Read peaks for a file at a given pixel width.
-- Returns { mins, maxs, n } or nil while peaks are being built.
-- `src` is borrowed from the caller (the preview source cache) — only used
-- within this call.
-- ---------------------------------------------------------------------------
function Peaks.Get(path, src, width)
    width = math.floor(width)
    if width < 16 then width = 16 end

    local hit = cacheGet(path, width)
    if hit then return hit end

    -- Build in flight for this file: report "not ready" BEFORE any
    -- allocation — this branch runs every frame during a build (the caller
    -- keeps polling), and a per-frame new_array would be pure GC churn.
    if build and build.path == path then return nil end

    if not src then return nil end

    local len = r.GetMediaSourceLength(src)
    if not len or len <= 0 then return nil end
    local channels = r.GetMediaSourceNumChannels(src)
    if not channels or channels < 1 then channels = 1 end
    if channels > 2 then channels = 2 end

    local count    = width
    local peakrate = count / len
    local buf      = r.new_array(count * channels * 2)
    buf.clear()

    local retval = r.PCM_Source_GetPeaks(src, peakrate, 0, channels, count, 0, buf)
    local valid  = retval and (retval & 0xfffff) or 0

    if valid <= 0 then
        -- No .reapeaks yet: kick the async build and report "not ready".
        startBuild(path)
        return nil
    end

    -- Collapse channels to a single mono min/max lane (strip display).
    local mins, maxs = {}, {}
    local n = math.min(valid, count)
    local min_base = count * channels
    for px = 1, n do
        local mx, mn = 0, 0
        local base = (px - 1) * channels
        for ch = 1, channels do
            local vmax = buf[base + ch] or 0
            local vmin = buf[min_base + base + ch] or 0
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
end

return Peaks
