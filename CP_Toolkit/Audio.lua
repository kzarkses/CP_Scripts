-- CP_Toolkit — Audio
-- Small shared audition engine on SWS CF_Preview, for CP scripts that need
-- "click → hear this file (or this section of it)" without the full browser
-- preview stack (CP_MediaExplorer keeps its own richer module).
--
-- Standalone: dofile() it, call Audio.init(reaper). No toolkit dependencies.
--
-- SWS lifecycle rules (learned the hard way in CP_MediaExplorer):
--   * CF_CreatePreview does NOT take ownership of the PCM_source — sources
--     stay alive in a tiny cache here and are destroyed on eviction, never
--     while they may still be playing.
--   * SWS reaps finished previews at the end of the defer cycle: every
--     handle access is pcall-guarded, a failure means "finished".
--   * Create + Play must happen inside one defer tick.
--
-- Section playback: Play(path, {start_s=…, end_s=…}) starts at start_s and
-- Poll() (call once per frame) stops — or loops — when the position crosses
-- end_s. Since playback always starts inside [start_s, end_s], a static
-- ">= end_s" check is safe here (no seek API is exposed).

local Audio = {}

local r  -- reaper, injected

Audio.available = false

function Audio.init(reaper_api)
    r = reaper_api
    Audio.available = (r.CF_CreatePreview ~= nil)
end

-- ---------------------------------------------------------------------------
-- PCM_source cache (tiny: pad clicks re-trigger the same handful of files)
-- ---------------------------------------------------------------------------
local CACHE_MAX = 6
local src_cache = {}   -- path → { src = PCM_source|false, tick, neg_t }
local src_count = 0
local use_tick  = 0
local playing_path = nil
local last_path    = nil

local function evictOldest()
    local victim, oldest = nil, math.huge
    for path, e in pairs(src_cache) do
        if path ~= playing_path and path ~= last_path and e.tick < oldest then
            victim, oldest = path, e.tick
        end
    end
    if victim then
        local e = src_cache[victim]
        if e.src then r.PCM_Source_Destroy(e.src) end
        src_cache[victim] = nil
        src_count = src_count - 1
    end
end

-- Cached source for a file (negative results cached 5s — an unreadable file
-- polled every frame must not retry a disk open every frame).
function Audio.GetSource(path)
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
    if src_count >= CACHE_MAX then evictOldest() end
    if not src then
        src_cache[path] = { src = false, tick = use_tick, neg_t = r.time_precise() }
        src_count = src_count + 1
        return nil
    end
    src_cache[path] = { src = src, tick = use_tick }
    src_count = src_count + 1
    return src
end

-- Returns len_seconds, channels, samplerate — or nil (samplerate 0 = MIDI).
function Audio.Meta(path)
    local src = Audio.GetSource(path)
    if not src then return nil end
    return r.GetMediaSourceLength(src),
           r.GetMediaSourceNumChannels(src),
           r.GetMediaSourceSampleRate(src)
end

-- ---------------------------------------------------------------------------
-- Playback
-- ---------------------------------------------------------------------------
local cur      = nil   -- live CF_Preview handle
local cur_end  = nil   -- section end (seconds) or nil
local cur_start = 0
local cur_loop = false

Audio.volume = 1.0     -- linear, applied to every Play

-- opts (all optional): { start_s, end_s, loop, rate, pitch, vol }
-- Returns true when playback started.
function Audio.Play(path, opts)
    if not Audio.available or not path then return false end
    Audio.Stop()

    local src = Audio.GetSource(path)
    if not src then return false end
    if r.GetMediaSourceSampleRate(src) == 0 then return false end

    local preview = r.CF_CreatePreview(src)
    if not preview then return false end

    local vol = (opts and opts.vol) or Audio.volume
    r.CF_Preview_SetValue(preview, "D_VOLUME", vol)
    if opts then
        if opts.pitch and opts.pitch ~= 0 then
            r.CF_Preview_SetValue(preview, "D_PITCH", opts.pitch)
        end
        if opts.rate and opts.rate ~= 1.0 then
            r.CF_Preview_SetValue(preview, "D_PLAYRATE", opts.rate)
            r.CF_Preview_SetValue(preview, "B_PPITCH", 1)
        end
        if opts.start_s and opts.start_s > 0 then
            r.CF_Preview_SetValue(preview, "D_POSITION", opts.start_s)
        end
    end
    r.CF_Preview_Play(preview)

    cur          = preview
    cur_start    = (opts and opts.start_s) or 0
    cur_end      = opts and opts.end_s or nil
    cur_loop     = (opts and opts.loop) or false
    playing_path = path
    last_path    = path
    return true
end

function Audio.Stop()
    if cur then pcall(r.CF_Preview_Stop, cur) end
    cur, cur_end, playing_path = nil, nil, nil
end

-- path arg optional: IsPlaying("x.wav") = "is THIS file playing".
function Audio.IsPlaying(path)
    if not cur then return false end
    if path then return playing_path == path end
    return true
end

-- Position (seconds, source domain) and length — or nil when stopped.
function Audio.Progress()
    if not cur then return nil end
    local ok, retval, pos = pcall(r.CF_Preview_GetValue, cur, "D_POSITION")
    if not ok or not retval then
        cur, cur_end, playing_path = nil, nil, nil
        return nil
    end
    local len = 0
    local ok2, retval2, plen = pcall(r.CF_Preview_GetValue, cur, "D_LENGTH")
    if ok2 and retval2 and plen then len = plen end
    return pos, len
end

-- Call once per defer frame: enforces the section end (stop or loop back)
-- and reaps dead handles. Cheap no-op while idle.
function Audio.Poll()
    if not cur then return end
    local pos = Audio.Progress()
    if not pos then return end
    if cur_end and pos >= cur_end then
        if cur_loop then
            pcall(r.CF_Preview_SetValue, cur, "D_POSITION", cur_start)
        else
            Audio.Stop()
        end
    end
end

function Audio.SetVolume(vol)
    Audio.volume = vol
    if cur then pcall(r.CF_Preview_SetValue, cur, "D_VOLUME", vol) end
end

function Audio.Destroy()
    Audio.Stop()
    for path, e in pairs(src_cache) do
        if e.src then r.PCM_Source_Destroy(e.src) end
        src_cache[path] = nil
    end
    src_count = 0
end

return Audio
