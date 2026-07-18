-- CP_Toolkit — DragBus
-- Cross-script drag & drop between CP windows (Media Explorer → Sampler…).
--
-- ReaScript windows are separate defer scripts: no shared memory, no OS DnD.
-- The bus is a tiny ExtState protocol (session-only, never persisted):
--
--   publisher (drag source)             consumer (drop target)
--   ------------------------            ------------------------
--   Begin(kind, path, label)            Register(id)          -- once
--   … drag frames …                     RectSync(id)          -- per frame
--   HoverTarget(sx, sy) → id?           ActiveDrag()          -- highlight UI
--   Drop(sx, sy) → delivered?           TakeDrop(id) → kind, path, x, y
--   End()                               Unregister(id)        -- on close
--
-- Matching is RECT-based: every consumer publishes its window's SCREEN
-- rect (gfx.clienttoscreen — no JS API needed, works docked); on release
-- the publisher point-tests the registered rects. The publisher's own
-- window is excluded automatically (in-window drags are the app's own
-- business). A publisher that gets Drop() == true MUST skip its own drop
-- handling (no double-insert when a target window floats over the
-- arrange). Caveat: pure rect tests ignore z-order — acceptable, CP
-- targets take priority by design.

local DragBus = {}

local r  -- reaper, injected

local SECTION = "CP_DragBus"

function DragBus.init(reaper_api)
    r = reaper_api
end

-- ---------------------------------------------------------------------------
-- Consumer side
-- ---------------------------------------------------------------------------
local last_rect = nil   -- last published rect string (write only on change)

function DragBus.Register(id)
    if not r then return false end
    local list = r.GetExtState(SECTION, "targets")
    if not list:find(id, 1, true) then
        r.SetExtState(SECTION, "targets",
                      list == "" and id or (list .. "," .. id), false)
    end
    last_rect = nil
    return true
end

-- Publish this window's screen rect. Call once per frame from the target
-- app (cheap: one ExtState write only when the window actually moved).
function DragBus.RectSync(id)
    if not r then return end
    local x1, y1 = gfx.clienttoscreen(0, 0)
    local x2, y2 = gfx.clienttoscreen(gfx.w, gfx.h)
    local rect = string.format("%d|%d|%d|%d", x1, y1, x2, y2)
    if rect ~= last_rect then
        last_rect = rect
        r.SetExtState(SECTION, "rect_" .. id, rect, false)
    end
end

function DragBus.Unregister(id)
    if not r then return end
    r.DeleteExtState(SECTION, "rect_" .. id, false)
    r.DeleteExtState(SECTION, "drop_" .. id, false)
    local list = r.GetExtState(SECTION, "targets")
    if list ~= "" then
        local out = {}
        for tid in list:gmatch("[^,]+") do
            if tid ~= id then out[#out + 1] = tid end
        end
        r.SetExtState(SECTION, "targets", table.concat(out, ","), false)
    end
end

-- Live drag info (any publisher). Returns kind, path, label — or nil.
-- Consumers poll this to highlight the pad/row under the mouse.
function DragBus.ActiveDrag()
    if not r or r.GetExtState(SECTION, "active") ~= "1" then return nil end
    return r.GetExtState(SECTION, "kind"),
           r.GetExtState(SECTION, "path"),
           r.GetExtState(SECTION, "label")
end

-- Pending drop delivered to this target. Returns kind, path, sx, sy
-- (screen coords of the release) — or nil. One-shot.
function DragBus.TakeDrop(id)
    if not r then return nil end
    local rec = r.GetExtState(SECTION, "drop_" .. id)
    if rec == "" then return nil end
    r.DeleteExtState(SECTION, "drop_" .. id, false)
    local kind, x, y, path = rec:match("^([^\n]*)\n([^\n]*)\n([^\n]*)\n(.*)$")
    if not kind then return nil end
    return kind, path, tonumber(x) or 0, tonumber(y) or 0
end

-- ---------------------------------------------------------------------------
-- Publisher side
-- ---------------------------------------------------------------------------
local pub = nil   -- { kind, path }

function DragBus.Begin(kind, path, label, self_id)
    if not r then return end
    pub = { kind = kind, path = path, self_id = self_id }
    r.SetExtState(SECTION, "kind",   kind or "", false)
    r.SetExtState(SECTION, "path",   path or "", false)
    r.SetExtState(SECTION, "label",  label or "", false)
    r.SetExtState(SECTION, "active", "1", false)
end

-- Which registered target window is under the screen point? Returns the
-- target id or nil. The publisher's own window always wins (returns nil
-- there) — this module runs inside the publisher script, so its gfx IS
-- the publisher window.
function DragBus.HoverTarget(sx, sy)
    if not pub then return nil end
    local ox1, oy1 = gfx.clienttoscreen(0, 0)
    local ox2, oy2 = gfx.clienttoscreen(gfx.w, gfx.h)
    if sx >= ox1 and sx < ox2 and sy >= oy1 and sy < oy2 then return nil end
    local list = r.GetExtState(SECTION, "targets")
    if list == "" then return nil end
    for tid in list:gmatch("[^,]+") do
        if tid ~= pub.self_id then
            local rect = r.GetExtState(SECTION, "rect_" .. tid)
            local x1, y1, x2, y2 =
                rect:match("^(-?%d+)|(-?%d+)|(-?%d+)|(-?%d+)$")
            if x1 then
                x1, y1, x2, y2 = tonumber(x1), tonumber(y1),
                                 tonumber(x2), tonumber(y2)
                if sx >= x1 and sx < x2 and sy >= y1 and sy < y2 then
                    return tid
                end
            end
        end
    end
    return nil
end

-- Release at screen point: deliver to the target under the mouse if any.
-- Returns true when a target consumed the drop (the publisher must then
-- skip its own drop handling). Always ends the drag.
function DragBus.Drop(sx, sy)
    local tid = DragBus.HoverTarget(sx, sy)
    if tid and pub then
        r.SetExtState(SECTION, "drop_" .. tid,
                      string.format("%s\n%d\n%d\n%s",
                                    pub.kind or "", sx, sy, pub.path or ""),
                      false)
    end
    DragBus.End()
    return tid ~= nil
end

function DragBus.End()
    if not r then return end
    pub = nil
    r.SetExtState(SECTION, "active", "0", false)
end

return DragBus
