-- CP_MediaExplorer — Preview
-- Audio preview engine on SWS CF_Preview (SWS >= 2.13).
--
-- Latency rule (the whole point of this browser): Play() is called in the
-- SAME defer tick as the triggering key/click, BEFORE any metadata or peaks
-- work. Sound first, decorate later.
--
-- Lifecycle rules (SWS):
--   * CF_CreatePreview does NOT take ownership of the PCM_source — we keep
--     sources alive in a small LRU cache and destroy them on eviction.
--   * A preview object is auto-destroyed by SWS at the end of the defer
--     cycle once playback finished — every handle access is pcall-guarded
--     and a failure means "finished".
--   * Create + Play must happen inside one defer tick (a never-started
--     preview is reaped at end of cycle).

local Preview = {}

local r  -- reaper, injected

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------
Preview.available = false

function Preview.init(reaper_api)
    r = reaper_api
    Preview.available = (r.CF_CreatePreview ~= nil)
end

-- ---------------------------------------------------------------------------
-- PCM_source LRU cache (keeps arrow-key browsing / drum-spam retrigger warm)
-- ---------------------------------------------------------------------------
local CACHE_MAX = 12
local src_cache = {}   -- path → { src = PCM_source, tick = number }
local src_count = 0
local use_tick  = 0
local last_played_path = nil  -- protected from eviction: destroying a source
                              -- a preview may still reference crashes REAPER

local function evictOldest()
    local oldest_path, oldest_tick = nil, math.huge
    for path, e in pairs(src_cache) do
        if path ~= Preview.playing_path and path ~= last_played_path
           and e.tick < oldest_tick then
            oldest_path, oldest_tick = path, e.tick
        end
    end
    if oldest_path then
        local victim = src_cache[oldest_path]
        if victim.src then r.PCM_Source_Destroy(victim.src) end
        src_cache[oldest_path] = nil
        src_count = src_count - 1
    end
end

-- Returns a cached (or freshly created) PCM_source for the file, or nil.
-- Failures are cached too (src = false): an unreadable selected file is
-- polled by the waveform strip every frame, and each miss used to retry a
-- disk-touching PCM_Source_CreateFromFile. Negatives retry after 5s.
function Preview.GetSource(path)
    use_tick = use_tick + 1
    local e = src_cache[path]
    if e then
        if e.src then
            e.tick = use_tick
            return e.src
        end
        if r.time_precise() - e.neg_t < 5.0 then return nil end
        src_cache[path] = nil
        src_count = src_count - 1
    end
    local src = r.PCM_Source_CreateFromFile(path)
    if src_count >= CACHE_MAX then
        evictOldest()
    end
    if not src then
        src_cache[path] = { src = false, tick = use_tick, neg_t = r.time_precise() }
        src_count = src_count + 1
        return nil
    end
    src_cache[path] = { src = src, tick = use_tick }
    src_count = src_count + 1
    return src
end

-- Warm the cache for a path without playing (idle-tick prefetch of the
-- selection's neighbors — the cheap trick that makes arrow-keying instant).
function Preview.Prefetch(path)
    if not path or src_cache[path] then return end
    Preview.GetSource(path)
end

function Preview.DropSource(path)
    local e = src_cache[path]
    if not e then return end
    if path == Preview.playing_path then Preview.Stop() end
    if e.src then r.PCM_Source_Destroy(e.src) end
    src_cache[path] = nil
    src_count = src_count - 1
end

-- ---------------------------------------------------------------------------
-- Media metadata (cheap header reads off the cached source)
-- ---------------------------------------------------------------------------
-- Returns len_seconds, channels, samplerate (samplerate 0 → MIDI/none).
function Preview.Meta(path)
    local src = Preview.GetSource(path)
    if not src then return nil end
    local len = r.GetMediaSourceLength(src)
    local ch  = r.GetMediaSourceNumChannels(src)
    local sr  = r.GetMediaSourceSampleRate(src)
    return len, ch, sr
end

function Preview.SourceType(path)
    local src = Preview.GetSource(path)
    if not src then return nil end
    return r.GetMediaSourceType(src, "")
end

-- ---------------------------------------------------------------------------
-- Playback
-- ---------------------------------------------------------------------------
-- Current playback state
Preview.playing_path = nil
local cur_preview    = nil
local cur_len        = 0

-- Persistent settings (applied to every Play)
Preview.volume      = 1.0    -- linear
Preview.pitch       = 0      -- semitones
Preview.rate        = 1.0
Preview.loop        = false
Preview.route_track = false  -- route through the first selected track (its FX)

-- opts (all optional): { position, rate_override }
-- Returns true when playback started.
function Preview.Play(path, opts)
    if not Preview.available or not path then return false end
    Preview.Stop()

    local src = Preview.GetSource(path)
    if not src then return false end

    -- MIDI sources have no audio path through CF_Preview.
    if r.GetMediaSourceSampleRate(src) == 0 then return false end

    local preview = r.CF_CreatePreview(src)
    if not preview then return false end

    r.CF_Preview_SetValue(preview, "D_VOLUME", Preview.volume)
    if Preview.pitch ~= 0 then
        r.CF_Preview_SetValue(preview, "D_PITCH", Preview.pitch)
    end
    local rate = (opts and opts.rate_override) or Preview.rate
    if rate ~= 1.0 then
        r.CF_Preview_SetValue(preview, "D_PLAYRATE", rate)
        r.CF_Preview_SetValue(preview, "B_PPITCH", 1)
    end
    r.CF_Preview_SetValue(preview, "B_LOOP", Preview.loop and 1 or 0)
    if opts and opts.position and opts.position > 0 then
        r.CF_Preview_SetValue(preview, "D_POSITION", opts.position)
    end

    -- Optional: audition through the first selected track (session FX chain).
    if Preview.route_track then
        local track = r.GetSelectedTrack(0, 0)
        if track then
            r.CF_Preview_SetOutputTrack(preview, 0, track)
        end
    end

    r.CF_Preview_Play(preview)

    cur_preview          = preview
    cur_len              = r.GetMediaSourceLength(src) or 0
    Preview.playing_path = path
    last_played_path     = path
    return true
end

function Preview.Stop()
    if cur_preview then
        pcall(r.CF_Preview_Stop, cur_preview)
    end
    cur_preview          = nil
    Preview.playing_path = nil
end

function Preview.IsPlaying()
    return cur_preview ~= nil
end

-- Poll playback progress. Returns progress (0..1), pos, playback_len — or nil
-- when not playing. Uses the preview's own D_LENGTH as the denominator so
-- playrate domain math stays SWS's problem, not ours.
-- A dead handle (SWS reaped it after playback end) reads as "stopped".
function Preview.Progress()
    if not cur_preview then return nil end
    local ok, retval, pos = pcall(r.CF_Preview_GetValue, cur_preview, "D_POSITION")
    if not ok or not retval then
        cur_preview          = nil
        Preview.playing_path = nil
        return nil
    end
    local len = cur_len
    local ok2, retval2, plen = pcall(r.CF_Preview_GetValue, cur_preview, "D_LENGTH")
    if ok2 and retval2 and plen and plen > 0 then len = plen end
    if not len or len <= 0 then return 0, pos, 0 end
    local frac = pos / len
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return frac, pos, len
end

-- Seek to a normalized 0..1 position within the playing file.
function Preview.SeekFrac(frac)
    if not cur_preview then return end
    local len = cur_len
    local ok, retval, plen = pcall(r.CF_Preview_GetValue, cur_preview, "D_LENGTH")
    if ok and retval and plen and plen > 0 then len = plen end
    if not len or len <= 0 then return end
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    pcall(r.CF_Preview_SetValue, cur_preview, "D_POSITION", frac * len)
end

-- Live setters (also update the persistent defaults)
function Preview.SetVolume(vol)
    Preview.volume = vol
    if cur_preview then
        pcall(r.CF_Preview_SetValue, cur_preview, "D_VOLUME", vol)
    end
end

function Preview.SetPitch(semitones)
    Preview.pitch = semitones
    if cur_preview then
        pcall(r.CF_Preview_SetValue, cur_preview, "D_PITCH", semitones)
    end
end

function Preview.SetRate(rate)
    Preview.rate = rate
    if cur_preview then
        pcall(r.CF_Preview_SetValue, cur_preview, "D_PLAYRATE", rate)
        pcall(r.CF_Preview_SetValue, cur_preview, "B_PPITCH", 1)
    end
end

function Preview.SetLoop(loop)
    Preview.loop = loop
    if cur_preview then
        pcall(r.CF_Preview_SetValue, cur_preview, "B_LOOP", loop and 1 or 0)
    end
end

-- ---------------------------------------------------------------------------
-- Tempo sync (native Media Explorer "tempo match" semantics)
-- ---------------------------------------------------------------------------
-- mult = the ME-style ×0.5 / ×1 / ×2 multiplier.
--   1. REAPER's own tempo-match math: GetTempoMatchPlayRate — the same
--      routine the native ME uses (stretch to a round power-of-2 bar count,
--      using embedded/estimated source tempo). Returns (retval, rate, len).
--   2. Fallback: BPM parsed from the filename ("...120bpm...")
--      → rate = project_bpm / source_bpm.
-- Returns rate (1.0 when nothing sensible was found).
function Preview.TempoSyncRate(path, mult)
    mult = mult or 1.0
    if r.GetTempoMatchPlayRate then
        local src = Preview.GetSource(path)
        if src then
            local ok, retval, rate = pcall(r.GetTempoMatchPlayRate, src, 1.0, 0, mult)
            if ok and retval and rate and rate > 0.05 and rate < 20 then
                return rate
            end
        end
    end
    local name = path:match("([^/\\]+)$") or path
    local bpm = tonumber(name:match("(%d%d%d?%.?%d*)%s*[bB][pP][mM]"))
    if bpm and bpm >= 40 and bpm <= 300 then
        return (r.Master_GetTempo() / bpm) * mult
    end
    return 1.0
end

-- ---------------------------------------------------------------------------
-- Shutdown
-- ---------------------------------------------------------------------------
function Preview.Destroy()
    Preview.Stop()
    for path, e in pairs(src_cache) do
        if e.src then r.PCM_Source_Destroy(e.src) end
        src_cache[path] = nil
    end
    src_count = 0
end

return Preview
