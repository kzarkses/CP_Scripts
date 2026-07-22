-- CP_Engine — Tempo
-- One clock for the whole suite (refonte chantier 3). The hub JSFX
-- (CP_JSFX/CP_TempoHub.jsfx, Monitoring FX chain) publishes transport,
-- tempo and — eventually — external MIDI clock into the gmem block
-- "CP_Tempo"; this module is the only reader the apps see. When the hub
-- is absent, stale, or the audio device is closed, every field falls
-- back to the direct REAPER API — callers never know which source fed
-- them.
--
-- gmem layout: see the header of CP_TempoHub.jsfx (single writer — the
-- hub writes cells 0..11, nothing else writes anything). LAYOUT_VER must
-- match on both sides.
--
-- ⚠ gmem_attach is GLOBAL to the script: it switches which named block
-- gmem_read/write touch for the WHOLE script. Tempo.Poll() re-attaches
-- to "CP_Tempo" on every call, so a host that also reads another block
-- must re-select it before its own reads — Loop exposes Loop.Reattach()
-- exactly for that (no app loads both today; the trap is armed for the
-- one that will). Any future gmem reader must follow the same discipline.

local Tempo = {}

local r  -- reaper, injected

local NS         = "CP_Tempo"
local LAYOUT_VER = 1
local SRC  = "/Scripts/CP_Scripts/CP_JSFX/CP_TempoHub.jsfx"
local DST  = "/Effects/CP_Scripts/CP_TempoHub.jsfx"
local ADD_NAME = "JS:CP_Scripts/CP_TempoHub.jsfx"

local attached = false

-- The one state table, mutated in place (zero per-frame allocation).
-- playing/paused/recording are normalized here because the hub (JSFX
-- play_state: 0/1/2/5/6) and the API (GetPlayState bitmask) disagree on
-- encodings — callers get booleans, never a raw code.
local state = {
    alive = false,          -- true = numbers came from the hub this frame
    tempo = 120, ts_num = 4, ts_den = 4,
    playing = false, paused = false, recording = false,
    beat_pos = 0,           -- quarter notes
    play_pos = 0,           -- seconds (play cursor, or edit cursor when stopped)
    srate = 48000,
    clock_bpm = 0,          -- external MIDI clock estimate (0 = none)
    clock_run = false,
}

-- Liveness: the heartbeat cell advances every audio block, so between two
-- UI frames it MUST have moved if the hub runs. The first observation
-- only seeds the comparison — a dead hub leaves a frozen-but-plausible
-- number behind in gmem, so "some value is there" proves nothing.
local last_hb, hb_age, hb_seen = 0, math.huge, false

function Tempo.init(reaper_api)
    r = reaper_api
    if r.gmem_attach then
        r.gmem_attach(NS)
        attached = true
    end
    local ok, desc = r.GetAudioDeviceInfo("SRATE", "")
    if ok then
        local sr = tonumber(desc)
        if sr and sr > 0 then state.srate = sr end
    end
end

-- Call once per defer frame; returns the shared state table.
function Tempo.Poll()
    local fresh = false
    if attached then
        r.gmem_attach(NS)   -- see the header warning: never assume the segment
        local hb = r.gmem_read(1)
        if not hb_seen then
            hb_seen, last_hb = true, hb
        elseif hb ~= last_hb then
            last_hb, hb_age = hb, 0
        else
            hb_age = hb_age + 1
        end
        fresh = hb_age < 5 and r.gmem_read(0) == LAYOUT_VER
    end

    if fresh then
        state.alive  = true
        state.srate  = r.gmem_read(2)
        state.tempo  = r.gmem_read(3)
        state.ts_num = r.gmem_read(4)
        state.ts_den = r.gmem_read(5)
        local ps = r.gmem_read(6)
        state.playing   = ps == 1 or ps == 5
        state.paused    = ps == 2 or ps == 6
        state.recording = ps == 5 or ps == 6
        state.beat_pos  = r.gmem_read(7)
        state.play_pos  = r.gmem_read(8)
        state.clock_bpm = r.gmem_read(10)
        state.clock_run = r.gmem_read(11) > 0.5
    else
        state.alive = false
        local ps = r.GetPlayState()
        state.playing   = ps & 1 == 1
        state.paused    = ps & 2 == 2
        state.recording = ps & 4 == 4
        state.play_pos  = state.playing and r.GetPlayPosition()
                          or r.GetCursorPosition()
        local num, den, bpm = r.TimeMap_GetTimeSigAtTime(0, state.play_pos)
        state.ts_num, state.ts_den, state.tempo = num, den, bpm
        state.beat_pos  = r.TimeMap2_timeToQN(0, state.play_pos)
        state.clock_bpm, state.clock_run = 0, false
    end
    return state
end

-- Last polled state without re-reading (same table Poll returns).
function Tempo.Get() return state end

function Tempo.SecPerBeat() return 60 / state.tempo end

-- Project time (seconds) of the next quarter-note / bar boundary — THE
-- primitive behind start-on-beat preview and launch quantize. nil while
-- the transport is stopped: "start now" is the caller's decision. These
-- go through the TimeMap API (tempo-map accurate), not gmem — they run
-- on user actions, not per frame.
function Tempo.NextBeatTime()
    if not state.playing then return nil end
    local qn = r.TimeMap2_timeToQN(0, r.GetPlayPosition())
    return r.TimeMap2_QNToTime(0, math.floor(qn) + 1)
end

function Tempo.NextBarTime()
    if not state.playing then return nil end
    local _, measures = r.TimeMap2_timeToBeats(0, r.GetPlayPosition())
    return r.TimeMap2_beatsToTime(0, 0, measures + 1)
end

-- ---------------------------------------------------------------------------
-- Hub install: copy the JSFX into Effects (content compare, same idiom as
-- Loop's installer) and make sure one instance sits in the Monitoring FX
-- chain (= the master track's recFX). Explicit call — apps that only want
-- the API fallback never touch the user's monitoring chain.
-- ---------------------------------------------------------------------------
local function installFile()
    local src = r.GetResourcePath() .. SRC
    local dst = r.GetResourcePath() .. DST
    r.RecursiveCreateDirectory(r.GetResourcePath() .. "/Effects/CP_Scripts", 0)

    local sf = io.open(src, "rb")
    if not sf then return false end
    local content = sf:read("*a"); sf:close()

    local df = io.open(dst, "rb")
    if df then
        local cur = df:read("*a"); df:close()
        if cur == content then return true end   -- up to date
    end
    df = io.open(dst, "wb")
    if not df then return false end
    df:write(content); df:close()
    return true
end

function Tempo.EnsureHub()
    if not installFile() then return false end
    local master = r.GetMasterTrack(0)
    -- recFX=true on the master track IS the Monitoring FX chain;
    -- instantiate=1 returns the existing instance instead of stacking one.
    local fx = r.TrackFX_AddByName(master, ADD_NAME, true, 1)
    return fx >= 0
end

function Tempo.HubAlive() return state.alive end

return Tempo
