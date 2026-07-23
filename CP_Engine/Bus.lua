-- CP_Engine — Bus
-- Inter-app messages carrying Clips (refonte chantier 7). DragBus stays
-- what it is — a domain-free rect-matching drag channel in the toolkit —
-- and this thin layer on top makes the payload a Clip instead of a bare
-- path. The CPC1 string escapes \n, so it rides DragBus's \n-delimited
-- drop records untouched.
--
-- Compatibility is one-way by design: Bus.TakeDrop PROMOTES a legacy
-- kind="file" drop into an audio Clip, so a consumer ported to the Bus
-- has ONE code path while old publishers keep emitting files. Publishers
-- migrate at their own pace with BeginClip.
--
-- The second half generalizes the suite's other channel — the
-- timestamped ExtState message (the "Open in Editor" idiom, TTL 5 s) —
-- into Send/Recv of Clips, so point-to-point bridges stop inventing
-- private formats.

local Bus = {}

local r        -- reaper, injected
local DragBus  -- CP_Toolkit/DragBus, injected
local Clip     -- CP_Engine/Clip, injected

local SECTION = "CP_Bus"

function Bus.init(reaper_api, dragbus, clip_module)
    r       = reaper_api
    DragBus = dragbus
    Clip    = clip_module
end

-- ---------------------------------------------------------------------------
-- Drag side (thin over DragBus — Register/RectSync/Unregister/HoverTarget/
-- Drop/End are used directly from DragBus; only payload translation lives
-- here)
-- ---------------------------------------------------------------------------
function Bus.BeginClip(clip, self_id)
    DragBus.Begin("clip", Clip.serialize(clip), clip.name or clip.kind, self_id)
end

-- One-shot pending drop for this target. Returns clip, sx, sy — or nil.
-- Legacy kind="file" drops are promoted to an audio Clip; other kinds
-- (fx…) are not Clips and stay DragBus.TakeDrop's business.
function Bus.TakeDrop(id)
    local kind, payload, sx, sy = DragBus.TakeDrop(id)
    if not kind then return nil end
    if kind == "clip" then
        local c = Clip.deserialize(payload)
        if c then return c, sx, sy end
        return nil
    end
    if kind == "file" and payload and payload ~= "" then
        local c = Clip.new("audio")
        c.path = payload
        return c, sx, sy
    end
    -- foreign kind: put it back for a plain DragBus consumer in the host
    return nil, nil, nil, kind, payload, sx, sy
end

-- ---------------------------------------------------------------------------
-- Addressed messages: Send targets a well-known address ("editor:open",
-- "sampler:instrument", "looper:lane3"…); Recv is one-shot and rejects
-- stale mail. Session-only, never persisted.
-- ---------------------------------------------------------------------------
local TTL = 5.0

function Bus.Send(addr, clip)
    r.SetExtState(SECTION, addr,
        string.format("%.3f\n%s", r.time_precise(), Clip.serialize(clip)),
        false)
end

function Bus.Recv(addr, ttl)
    local rec = r.GetExtState(SECTION, addr)
    if rec == "" then return nil end
    local ts, body = rec:match("^([^\n]*)\n(.*)$")
    ts = tonumber(ts)
    if not ts or r.time_precise() - ts > (ttl or TTL) then return nil end
    r.DeleteExtState(SECTION, addr, false)
    return Clip.deserialize(body)
end

-- ---------------------------------------------------------------------------
-- The universal "edit this clip" gesture (Ableton semantics): CP_Editor is
-- THE editor, wherever the clip comes from. The editor advertises its
-- registered action (persistent) and a liveness heartbeat over ExtState;
-- OpenEditor STARTS it when it is not running, then mails the clip — the
-- 5 s TTL covers the boot.
-- ---------------------------------------------------------------------------
function Bus.OpenEditor(clip)
    local alive = tonumber(r.GetExtState("CP_Editor", "alive"))
    if not (alive and r.time_precise() - alive < 2.0) then
        local named = r.GetExtState("CP_Editor", "cmd")
        if named ~= "" then
            local id = r.NamedCommandLookup(named)
            if id and id ~= 0 then r.Main_OnCommand(id, 0) end
        end
    end
    Bus.Send("editor:open", clip)
end

return Bus
