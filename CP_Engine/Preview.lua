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

-- The one answer on a file's tempo (roadmap phase 3). Loaded here rather
-- than injected: this module is dofile'd by half the suite, and a caller that
-- has to remember to wire a dependency is a caller that will forget.
local SrcTempo = dofile(reaper.GetResourcePath()
                        .. "/Scripts/CP_Scripts/CP_Engine/SrcTempo.lua")

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
Preview.out_track   = nil    -- DEDICATED preview track — outranks route_track

-- Declick. SWS defaults both fade lengths to 0, so a preview starts and stops on
-- a raw sample edge — audible as a click on anything that doesn't begin and end
-- at zero (most loops, and every mid-file section). These are short enough to be
-- inaudible on a transient: 3 ms in keeps a kick's attack intact, 8 ms out is
-- enough to swallow the cut. Stop is the worse offender, hence the asymmetry.
Preview.fade_in     = 0.003
Preview.fade_out    = 0.008

-- ---------------------------------------------------------------------------
-- THE SECTION — a part of a file, played and looped as if it were the file.
--
-- CF_Preview's own B_LOOP repeats the whole source, so it cannot express
-- "play these four bars and turn back". The turnaround is therefore ours: a
-- once-per-frame poll (Preview.Poll) that watches the position and either
-- stops at the end or sends it back to the start. That is exactly what the
-- editor's section playback needs, and it is why this lived in a second
-- audition module until now.
--
-- `cur_start` is not always where playback BEGAN: starting from a cursor
-- dropped in the middle of a loop and then turning back to that point would
-- repeat a fragment nobody asked for. The loop belongs to the PART, so its
-- owner names it (opts.loop_start).
-- ---------------------------------------------------------------------------
local cur_end   = nil
local cur_start = 0
local cur_loop  = false

-- opts (all optional):
--   position / start_s   where playback begins, in source seconds
--   end_s, loop_start    the section: where it ends, where a loop turns back
--   loop                 turn back at end_s instead of stopping there
--   vol, pitch, rate     per-call overrides of the persistent settings
--   ppitch               0 = a rate change repitches (default preserves pitch)
--   fade_in, fade_out    override the declick defaults (an item's own fades)
--   out_track            route through that track's FX chain and fader
--   rate_override        legacy name for `rate` (the browser's tempo match)
--
-- Everything the caller does not state falls back to the module setting, so
-- the browser's "set it once, play many" style and the editor's "state it per
-- press" style are the same function.
local function startPreview(src, path, opts)
    if not src then return false end
    -- MIDI sources have no audio path through CF_Preview.
    if r.GetMediaSourceSampleRate(src) == 0 then return false end

    local preview = r.CF_CreatePreview(src)
    if not preview then return false end

    local vol   = (opts and opts.vol) or Preview.volume
    local fin   = (opts and opts.fade_in)  or Preview.fade_in
    local fout  = (opts and opts.fade_out) or Preview.fade_out
    local pitch = (opts and opts.pitch) or Preview.pitch
    local rate  = (opts and (opts.rate or opts.rate_override)) or Preview.rate
    local start = (opts and (opts.start_s or opts.position)) or 0

    r.CF_Preview_SetValue(preview, "D_VOLUME", vol)
    if fin  > 0 then r.CF_Preview_SetValue(preview, "D_FADEINLEN",  fin)  end
    if fout > 0 then r.CF_Preview_SetValue(preview, "D_FADEOUTLEN", fout) end
    if pitch ~= 0 then
        r.CF_Preview_SetValue(preview, "D_PITCH", pitch)
    end
    if rate ~= 1.0 then
        r.CF_Preview_SetValue(preview, "D_PLAYRATE", rate)
        r.CF_Preview_SetValue(preview, "B_PPITCH",
                              (opts and opts.ppitch == 0) and 0 or 1)
    end
    -- SWS's own loop repeats the SOURCE; a section turns back in Poll. Both
    -- would fight, so the native one is only asked for when there is no
    -- section to respect.
    local section = opts and opts.end_s
    local want_loop = (opts and opts.loop) or (opts == nil and Preview.loop)
    if opts and opts.loop == nil then want_loop = Preview.loop end
    r.CF_Preview_SetValue(preview, "B_LOOP",
                          (want_loop and not section) and 1 or 0)
    if start > 0 then
        r.CF_Preview_SetValue(preview, "D_POSITION", start)
    end

    -- Optional routing: the caller's track wins, then a dedicated preview
    -- track, then the first selected track when route_track is on. Either way
    -- the preview plays through that track's FX chain. No route = hardware.
    local out = (opts and opts.out_track) or Preview.out_track
    if out and not r.ValidatePtr2(0, out, "MediaTrack*") then
        out = nil
        if not (opts and opts.out_track) then Preview.out_track = nil end
    end
    if not out and Preview.route_track then
        out = r.GetSelectedTrack(0, 0)
    end
    if out and r.CF_Preview_SetOutputTrack then
        r.CF_Preview_SetOutputTrack(preview, 0, out)
    end

    r.CF_Preview_Play(preview)

    cur_preview          = preview
    cur_len              = r.GetMediaSourceLength(src) or 0
    cur_start            = (opts and (opts.loop_start or opts.start_s)) or 0
    cur_end              = section or nil
    cur_loop             = want_loop and true or false
    Preview.playing_path = path
    if path then last_played_path = path end
    return true
end

-- Returns true when playback started.
function Preview.Play(path, opts)
    if not Preview.available or not path then return false end
    Preview.Stop()
    return startPreview(Preview.GetSource(path), path, opts)
end

-- Play an EXISTING PCM_source — an item take's real source, SECTION and
-- reversed sources included, which have no standalone file path and cannot be
-- reached any other way. The caller owns that source and must keep it alive
-- while it plays: this module never caches it and never destroys it.
function Preview.PlaySource(src, opts)
    if not Preview.available or not src then return false end
    Preview.Stop()
    return startPreview(src, nil, opts)
end

function Preview.Stop()
    if cur_preview then
        pcall(r.CF_Preview_Stop, cur_preview)
    end
    cur_preview          = nil
    cur_end              = nil
    Preview.playing_path = nil
end

-- Install or move the section of what is ALREADY playing. Toggling a loop
-- must take effect on what you are hearing, not on the next thing you press,
-- and restarting the preview to apply it would jump the position back.
function Preview.SetSection(on, end_s, start_s)
    cur_loop = on and true or false
    if end_s   then cur_end   = end_s   end
    if start_s then cur_start = start_s end
    -- With a section installed the turnaround is ours; SWS's whole-source
    -- loop has to stand down or the two disagree at the boundary.
    if cur_preview and cur_end then
        pcall(r.CF_Preview_SetValue, cur_preview, "B_LOOP", 0)
    end
end

-- Once per defer frame: enforce the section end (stop, or turn back) and reap
-- a handle SWS already collected. A no-op while idle.
function Preview.Poll()
    if not cur_preview or not cur_end then return end
    local ok, retval, pos = pcall(r.CF_Preview_GetValue, cur_preview, "D_POSITION")
    if not ok or not retval then
        cur_preview, cur_end = nil, nil
        Preview.playing_path = nil
        return
    end
    if pos >= cur_end then
        if cur_loop then
            pcall(r.CF_Preview_SetValue, cur_preview, "D_POSITION", cur_start)
        else
            Preview.Stop()
        end
    end
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
    cur_loop = loop and true or false
    -- Only when there is no section: with one, Poll owns the turnaround and
    -- SWS's whole-source loop would repeat material outside the part.
    if cur_preview and not cur_end then
        pcall(r.CF_Preview_SetValue, cur_preview, "B_LOOP", loop and 1 or 0)
    end
end

-- Position in source seconds, and the playback length — or nil when stopped.
-- Progress() answers the same question as a fraction; a caller comparing
-- against a selection in seconds wants this one, and had to divide by a
-- length it did not have otherwise.
function Preview.Position()
    local _, pos, len = Preview.Progress()
    return pos, len
end

-- Dedicated preview track (nil clears it). Takes effect on the next Play —
-- SWS has no output re-route on a live preview handle.
function Preview.SetOutputTrack(track)
    Preview.out_track = track
end

-- ---------------------------------------------------------------------------
-- Tempo sync — DELEGATED (roadmap phase 3)
-- ---------------------------------------------------------------------------
-- This used to be one of three routines in the suite that answered "how fast
-- is this file", and the three did not agree. Engine/SrcTempo is the answer
-- now; this stays as the browser's name for it, and passes the source cache
-- along so asking costs no disk.
--
-- mult = the Media-Explorer-style ×0.5 / ×1 / ×2 multiplier.
-- Returns rate (1.0 when no tempo deserved belief).
function Preview.TempoSyncRate(path, mult)
    SrcTempo.init(r, Preview)
    return (SrcTempo.Rate(path, { mult = mult or 1.0 }))
end

-- The tempo itself, and WHY it is believed ("declared" | "analysed" |
-- "named" | "inferred"). A window showing a number the user cannot account
-- for is a window they learn to distrust.
function Preview.SrcBpm(path, declared)
    SrcTempo.init(r, Preview)
    return SrcTempo.Bpm(path, declared)
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
