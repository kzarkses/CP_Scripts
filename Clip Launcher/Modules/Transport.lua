local Transport = {}

local r, Core

-- GMEM transport base (must match JSFX)
local GMEM_TRANSPORT = 3000

function Transport.init(reaper_api, core)
    r = reaper_api
    Core = core

    Transport.state = {
        is_playing = false,
        tempo = 120,
        time_sig_num = 4,
        time_sig_denom = 4,
        beat_position = 0,
        bar_position = 0,
        beat_in_bar = 0,
        play_position = 0,
        samples_per_beat = 0,
        sample_rate = 44100,
        seconds_per_beat = 0.5,
        seconds_per_bar = 2.0,
    }
end

function Transport.update()
    local s = Transport.state

    -- Read from JSFX gmem (more precise, runs in audio thread)
    local gmem_tempo = r.gmem_read(GMEM_TRANSPORT + 0)
    local gmem_play_state = r.gmem_read(GMEM_TRANSPORT + 1)
    local gmem_beat_pos = r.gmem_read(GMEM_TRANSPORT + 2)
    local gmem_spb = r.gmem_read(GMEM_TRANSPORT + 3)
    local gmem_ts_num = r.gmem_read(GMEM_TRANSPORT + 4)
    local gmem_ts_denom = r.gmem_read(GMEM_TRANSPORT + 5)
    local gmem_srate = r.gmem_read(GMEM_TRANSPORT + 6)

    -- Use JSFX values if available (non-zero), else fallback to REAPER API
    if gmem_tempo > 0 then
        s.tempo = gmem_tempo
        s.is_playing = gmem_play_state > 0
        s.beat_position = gmem_beat_pos
        s.samples_per_beat = gmem_spb
        s.time_sig_num = gmem_ts_num > 0 and gmem_ts_num or 4
        s.time_sig_denom = gmem_ts_denom > 0 and gmem_ts_denom or 4
        s.sample_rate = gmem_srate > 0 and gmem_srate or 44100
    else
        -- Fallback: JSFX not running yet
        s.is_playing = (r.GetPlayState() & 1) == 1
        s.play_position = r.GetPlayPosition2Ex(0)
        s.sample_rate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 44100
        if s.sample_rate == 0 then s.sample_rate = 44100 end

        local _, _, tempo = r.TimeMap_GetTimeSigAtTime(0, s.play_position)
        s.tempo = tempo or 120
        s.samples_per_beat = s.sample_rate * 60.0 / s.tempo
    end

    -- Derived values
    s.seconds_per_beat = 60.0 / s.tempo
    s.seconds_per_bar = s.seconds_per_beat * s.time_sig_num

    -- Beat/bar position
    s.beat_in_bar = s.beat_position % s.time_sig_num
    s.bar_position = math.floor(s.beat_position / s.time_sig_num)
end

-- Format beat position as "bar.beat"
function Transport.formatPosition()
    local s = Transport.state
    local bar = s.bar_position + 1
    local beat = math.floor(s.beat_in_bar) + 1
    return string.format("%d.%d", bar, beat)
end

return Transport
