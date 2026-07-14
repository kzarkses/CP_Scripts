-- @description CP ChordLab — MIDI audition (strummed chord preview via VKB queue)
-- @author Cedric Pamalio

-- REAPER-side module. Schedules note-on / note-off messages into the Virtual MIDI
-- Keyboard queue (StuffMIDIMessage mode 0), which routes to the track receiving
-- VKB input (normally the selected track). Play() enqueues a strum; Update() must
-- run every frame to flush due events.
--
-- Invariants:
--   * Every scheduled note-on has its matching note-off enqueued AT SCHEDULE TIME,
--     so a note can never hang even if Play() is never called again.
--   * The event queue and the active-note table are reused across frames — no
--     allocation happens on an idle Update() (the common per-frame case).
--   * Times are reaper.time_precise() seconds (floats). Never format them with %d.

local r = reaper

local M = {}

-- MIDI status bytes (channel added in).
local NOTE_ON = 0x90
local NOTE_OFF = 0x80

-- Pending timed events: dense array of records { t, on, pitch, vel, chan }.
-- head = index of the next unprocessed event; entries below head are consumed.
-- We compact (reset head to 1, clear the array) only when the queue drains, so
-- steady-state Update() does zero table work when nothing is due.
local queue = {}
local head = 1

-- Active sounding notes keyed by (chan*128 + pitch) → true. Lets StopAll flush a
-- note-off for exactly the notes currently on, with no duplicates.
local active = {}
local active_count = 0

local function active_key(chan, pitch)
    return chan * 128 + pitch
end

local function send(on, pitch, vel, chan)
    local status = (on and NOTE_ON or NOTE_OFF) + (chan & 0x0F)
    r.StuffMIDIMessage(0, status, pitch, vel)
    local k = active_key(chan, pitch)
    if on then
        if not active[k] then active_count = active_count + 1 end
        active[k] = true
    else
        if active[k] then active_count = active_count - 1 end
        active[k] = nil
    end
end

-- Push a timed event, reusing an existing slot when one is free past the tail.
local function enqueue(t, on, pitch, vel, chan)
    local n = #queue + 1
    local rec = queue[n]
    if rec then
        rec.t, rec.on, rec.pitch, rec.vel, rec.chan = t, on, pitch, vel, chan
    else
        queue[n] = { t = t, on = on, pitch = pitch, vel = vel, chan = chan }
    end
end

-- ---------------------------------------------------------------------------
-- Play
-- ---------------------------------------------------------------------------

function M.Play(pitches, opts)
    if not pitches or #pitches == 0 then return end
    opts = opts or {}
    local strum_ms = opts.strum_ms or 18
    local dur_ms = opts.dur_ms or 900
    local vel = opts.vel or 96
    local chan = (opts.chan or 0) & 0x0F
    local dir = opts.dir or "up"

    -- Order the strum: "up" = low→high pitch (guitar downstroke). Copy + sort so
    -- we never mutate the caller's array; ascending, then reverse for "down".
    local order = {}
    for i = 1, #pitches do order[i] = pitches[i] end
    table.sort(order)
    if dir == "down" then
        local lo, hi = 1, #order
        while lo < hi do
            order[lo], order[hi] = order[hi], order[lo]
            lo = lo + 1
            hi = hi - 1
        end
    end

    local now = r.time_precise()
    local strum = strum_ms / 1000.0
    local dur = dur_ms / 1000.0

    -- Enqueue on + matching off for each note. Both are queued now so the off can
    -- never be lost. Update() sends them in time order (queue sorted by t below).
    for i = 1, #order do
        local on_t = now + (i - 1) * strum
        enqueue(on_t, true, order[i], vel, chan)
        enqueue(on_t + dur, false, order[i], 0, chan)
    end

    -- Keep the pending region time-ordered so Update()'s due-check is monotone.
    -- Only the still-pending tail [head..#queue] needs sorting.
    if #queue > head then
        -- Move the pending tail to the front so table.sort works on a clean range,
        -- then reset head. Cheap: a strum is a handful of events.
        if head > 1 then
            local w = 1
            for i = head, #queue do
                local src = queue[i]
                local dst = queue[w]
                if dst then
                    dst.t, dst.on, dst.pitch, dst.vel, dst.chan =
                        src.t, src.on, src.pitch, src.vel, src.chan
                else
                    queue[w] = { t = src.t, on = src.on, pitch = src.pitch,
                                 vel = src.vel, chan = src.chan }
                end
                w = w + 1
            end
            for i = w, #queue do queue[i] = nil end
            head = 1
        end
        table.sort(queue, function(a, b) return a.t < b.t end)
    end
end

-- ---------------------------------------------------------------------------
-- Update — pop due events; zero allocation when idle
-- ---------------------------------------------------------------------------

function M.Update()
    local n = #queue
    if head > n then return end   -- idle fast path: nothing pending

    local now = r.time_precise()
    while head <= n do
        local ev = queue[head]
        if ev.t > now then break end   -- queue is time-ordered → nothing else due
        send(ev.on, ev.pitch, ev.vel, ev.chan)
        head = head + 1
    end

    -- Drained → compact so the next Play starts from a clean, small array.
    if head > n then
        for i = 1, n do queue[i] = nil end
        head = 1
    end
end

-- ---------------------------------------------------------------------------
-- StopAll — immediate note-offs for everything currently sounding
-- ---------------------------------------------------------------------------

function M.StopAll()
    -- Deterministic order not required for correctness (offs are independent), but
    -- iterate a collected key list rather than mutating `active` during pairs().
    if active_count > 0 then
        local keys = {}
        for k in pairs(active) do keys[#keys + 1] = k end
        for i = 1, #keys do
            local k = keys[i]
            local chan = k // 128
            local pitch = k % 128
            send(false, pitch, 0, chan)
        end
    end
    active = {}
    active_count = 0

    -- Drop any still-pending scheduled events.
    for i = 1, #queue do queue[i] = nil end
    head = 1
end

function M.IsActive()
    return active_count > 0 or head <= #queue
end

return M
