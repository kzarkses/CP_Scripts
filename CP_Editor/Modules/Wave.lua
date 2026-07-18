-- CP_SampleEditor — Wave
-- Peaks reader for the zoomable editor view: arbitrary [t0, t1] source-time
-- range at pixel resolution, per-channel lanes (stereo shows two lanes,
-- Ableton-style). Built on PCM_Source_GetPeaks:
--
--   buffer = new_array(count * channels * 2)
--   block 1 = maxima  → idx = (px-1)*channels + ch
--   block 2 = minima  → offset count*channels
--   retval low 20 bits = valid sample count
--   peakrate above the file samplerate degrades gracefully (REAPER reads
--   the source directly — the visible width bounds the cost).
--
-- Zero-churn contract: the peak buffer is pooled per exact size (widths
-- only change on window resize) and the result entry mutates in place —
-- a pan drag re-reads every frame and must not allocate.

local Wave = {}

local r  -- reaper, injected

function Wave.init(reaper_api)
    r = reaper_api
end

-- ---------------------------------------------------------------------------
-- Pooled reaper.array buffers (exact size — GetPeaks contract)
-- ---------------------------------------------------------------------------
local arrays = {}

function Wave.Array(sz)
    local a = arrays[sz]
    if not a then
        a = r.new_array(sz)
        arrays[sz] = a
    end
    return a
end

-- ---------------------------------------------------------------------------
-- Async peak building (0/1/2 state machine, one build in flight)
-- ---------------------------------------------------------------------------
local build = nil

local function startBuild(path)
    if not path or path == "" then return end
    if build then
        if build.path == path then return end
        r.PCM_Source_BuildPeaks(build.src, 2)
        r.PCM_Source_Destroy(build.src)
        build = nil
    end
    local src = r.PCM_Source_CreateFromFile(path)
    if not src then return end
    if r.PCM_Source_BuildPeaks(src, 0) == 0 then
        r.PCM_Source_Destroy(src)
        return
    end
    build = { path = path, src = src }
end

-- Advance the build; call once per frame. Returns true while building.
function Wave.Step()
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

function Wave.Building()
    return build ~= nil
end

-- ---------------------------------------------------------------------------
-- View read (single cached entry — the editor shows one view at a time)
-- ---------------------------------------------------------------------------
-- entry.n px valid, entry.ch lanes; lanes mutate in place across reads.
local entry = { n = 0, ch = 1,
                maxs = { {}, {} }, mins = { {}, {} } }
local ck = { src = nil, t0 = -1, t1 = -1, w = 0, gen = -1 }

function Wave.Invalidate()
    ck.src = nil
end

-- src is borrowed (item take source or the app's own file source); path is
-- only used to kick a .reapeaks build when none exist. gen: bump to force a
-- re-read after an edit. Returns the shared entry, or nil while building.
function Wave.Read(src, path, t0, t1, w, gen)
    w = math.floor(w)
    if w < 16 or not src or t1 <= t0 then return nil end
    if ck.src == src and ck.t0 == t0 and ck.t1 == t1 and ck.w == w
       and ck.gen == gen then
        return entry
    end
    if build and path and build.path == path then return nil end

    local ch = r.GetMediaSourceNumChannels(src) or 1
    if ch < 1 then ch = 1 end
    if ch > 2 then ch = 2 end

    local count    = w
    local peakrate = count / (t1 - t0)
    local buf      = Wave.Array(count * ch * 2)
    buf.clear()

    local retval = r.PCM_Source_GetPeaks(src, peakrate, t0, ch, count, 0, buf)
    local valid  = retval and (retval & 0xfffff) or 0
    if valid <= 0 then
        startBuild(path)
        return nil
    end

    local n = math.min(valid, count)
    local min_base = count * ch
    for c = 1, ch do
        local maxs, mins = entry.maxs[c], entry.mins[c]
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
    entry.n, entry.ch = n, ch
    ck.src, ck.t0, ck.t1, ck.w, ck.gen = src, t0, t1, w, gen
    return entry
end

function Wave.Destroy()
    if build then
        r.PCM_Source_BuildPeaks(build.src, 2)
        r.PCM_Source_Destroy(build.src)
        build = nil
    end
end

return Wave
