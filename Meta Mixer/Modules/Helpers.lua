-- Helpers.lua — Utility functions (dB, volume, pan, formatting)
local Helpers = {}

function Helpers.VolToDb(vol)
    if vol < 0.00001 then return -150 end
    return 20 * math.log(vol, 10)
end

function Helpers.DbToVol(db)
    if db <= -150 then return 0 end
    return 10 ^ (db / 20)
end

function Helpers.VolToNorm(vol)
    local db = Helpers.VolToDb(vol)
    if db <= -150 then return 0 end
    if db >= 12 then return 1 end
    return (db + 60) / 72
end

function Helpers.NormToVol(norm)
    if norm <= 0 then return 0 end
    if norm >= 1 then return Helpers.DbToVol(12) end
    return Helpers.DbToVol(norm * 72 - 60)
end

function Helpers.PanToNorm(pan)
    return (pan + 1) / 2
end

function Helpers.NormToPan(norm)
    return norm * 2 - 1
end

function Helpers.FormatDb(vol)
    local db = Helpers.VolToDb(vol)
    if db <= -60 then return "-inf" end
    return string.format("%.1f", db)
end

function Helpers.FormatTime(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds - m * 60
    return string.format("%d:%04.1f", m, s)
end

function Helpers.GetMeterColor(peak, C)
    local db = 20 * math.log(math.max(peak, 0.00001), 10)
    if db > -3 then return C.COL_METER_RED end
    if db > -12 then return C.COL_METER_YELLOW end
    return C.COL_METER_GREEN
end

function Helpers.PeakToHeight(peak, max_h)
    if peak < 0.00001 then return 0 end
    local db = 20 * math.log(peak, 10)
    local norm = (db + 60) / 60
    if norm < 0 then return 0 end
    if norm > 1 then norm = 1 end
    return norm * max_h
end

return Helpers
