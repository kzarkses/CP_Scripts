-- CP_FloatingToolbar / IconPicker
-- Searchable thumbnail grid for REAPER's Data/toolbar_icons/.
-- The full filename list is enumerated lazily at first open (~3500 files).
-- Thumbnails are loaded on demand and cached on the picker state.

local IconPicker = {}

local UI = nil
local file_list = nil   -- { "00 - Foo.png", ... }

-- ---------------------------------------------------------------------------
-- LRU thumbnail pool — uses gfx buffer slots [600..899], 300 thumbnails max.
-- This is isolated from Widgets.LoadImage (which starts at 200) so the
-- picker can't starve the rest of the UI of buffer slots, and a 3500-icon
-- toolbar_icons folder doesn't blow past gfx's 1024-buffer hard cap.
-- ---------------------------------------------------------------------------
local POOL_FIRST = 600
local POOL_SIZE  = 300

-- filename → { buffer, w, h, failed=true|nil, lru_tick }
local thumb_cache = {}
-- circular slot allocator + monotonic tick for LRU
local next_slot = POOL_FIRST
local lru_tick  = 0

local function evict_oldest()
    -- Find the cache entry with the smallest lru_tick and free its slot.
    local oldest_name, oldest_tick = nil, math.huge
    for name, entry in pairs(thumb_cache) do
        if entry.buffer and entry.lru_tick < oldest_tick then
            oldest_name = name
            oldest_tick = entry.lru_tick
        end
    end
    if oldest_name then
        local e = thumb_cache[oldest_name]
        gfx.setimgdim(e.buffer, 0, 0)  -- release the buffer's pixel data
        thumb_cache[oldest_name] = nil
        return e.buffer
    end
    return nil
end

local function alloc_slot()
    -- Try the next slot in the circular pool. If it's already in use by
    -- another cache entry, evict the oldest entry to free a slot.
    local used_count = 0
    for _ in pairs(thumb_cache) do used_count = used_count + 1 end
    if used_count >= POOL_SIZE then
        return evict_oldest()
    end
    -- Find the next unused slot starting from next_slot
    for i = 0, POOL_SIZE - 1 do
        local s = POOL_FIRST + ((next_slot - POOL_FIRST + i) % POOL_SIZE)
        local taken = false
        for _, entry in pairs(thumb_cache) do
            if entry.buffer == s then taken = true; break end
        end
        if not taken then
            next_slot = POOL_FIRST + ((s - POOL_FIRST + 1) % POOL_SIZE)
            return s
        end
    end
    return evict_oldest()
end

local function scan_dir()
    local dir = reaper.GetResourcePath() .. "/Data/toolbar_icons"
    local files = {}
    local i = 0
    while true do
        local f = reaper.EnumerateFiles(dir, i)
        if not f or f == "" then break end
        if f:lower():match("%.png$") then
            files[#files + 1] = f
        end
        i = i + 1
    end
    table.sort(files, function(a, b) return a:lower() < b:lower() end)
    return files
end

local function ensure_list()
    if file_list then return file_list end
    file_list = scan_dir()
    return file_list
end

-- Returns { buffer, w, h } or nil. Marks LRU tick on each successful access.
local function get_thumb(filename)
    local cached = thumb_cache[filename]
    if cached then
        if cached.failed then return nil end
        lru_tick = lru_tick + 1
        cached.lru_tick = lru_tick
        return cached
    end
    local slot = alloc_slot()
    if not slot then return nil end
    local path = reaper.GetResourcePath() .. "/Data/toolbar_icons/" .. filename
    local ok = gfx.loadimg(slot, path)
    if ok < 0 then
        thumb_cache[filename] = { failed = true }
        return nil
    end
    local w, h = gfx.getimgdim(slot)
    lru_tick = lru_tick + 1
    local entry = { buffer = slot, w = w, h = h, lru_tick = lru_tick }
    thumb_cache[filename] = entry
    return entry
end

-- For a 3-states (90×30) sheet, we want only the leftmost cell. Detect the
-- layout from the aspect ratio:
--   ratio 3:1  → 3 states (REAPER toolbar convention)
--   ratio 2:1  → 2 states (rare)
--   anything else → single icon, use the whole image
local function first_state_rect(w, h)
    if h <= 0 then return 0, 0, w, h end
    local ratio = w / h
    if ratio > 2.5 and ratio < 3.5 then  -- 3-states
        return 0, 0, math.floor(w / 3), h
    elseif ratio > 1.6 and ratio < 2.4 then  -- 2-states
        return 0, 0, math.floor(w / 2), h
    end
    return 0, 0, w, h
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
function IconPicker.Init(ui)
    UI = ui
end

-- The picker holds its own state: current search and open flag.
-- A new state is created per "session" (i.e. per consumer call site).
function IconPicker.NewState()
    return {
        open = false,
        target = nil,       -- the action being edited (or anything you want to remember)
        search = "",
        source = "native",  -- "native" (REAPER's PNGs) or "cp" (the toolkit pack)
        on_pick = nil,      -- function(filename) called when user clicks an icon
        on_pick_cp = nil,   -- function(icon_name) for a toolkit glyph
        on_clear = nil,     -- optional, called when "Clear" is pressed
    }
end

-- The toolkit's own glyphs, listed once. They are DRAWN, not loaded: no image
-- buffer, no LRU pool, and they take the colour they are asked for — which is
-- why a CP glyph follows the theme and a REAPER PNG cannot.
local cp_names = nil
local IP_SEARCH_OPTS = { hint = "Filter (play, mixer, fx…)" }

local function ensure_cp_list()
    if cp_names then return cp_names end
    cp_names = {}
    local skip = { Init = true, SetLog = true, Set = true,
                   ReloadOverrides = true, SetFontRestorer = true }
    for k, v in pairs(UI.Icons) do
        if type(v) == "function" and not skip[k] then
            cp_names[#cp_names + 1] = k
        end
    end
    table.sort(cp_names)
    return cp_names
end

function IconPicker.Open(state, opts)
    state.open = true
    state.target = opts and opts.target
    state.search = opts and opts.search or ""
    state.source = (opts and opts.source) or state.source or "native"
    state.on_pick = opts and opts.on_pick
    state.on_pick_cp = opts and opts.on_pick_cp
    state.on_clear = opts and opts.on_clear
    -- Lazy scan on first open so script startup stays cheap
    ensure_list()
end

function IconPicker.Close(state)
    state.open = false
end

-- Reset the lazily-built file list (e.g. after the user dropped new PNGs
-- into Data/toolbar_icons/). Also drops the thumbnail cache so freshly
-- written PNGs reload.
function IconPicker.Rescan()
    file_list = nil
    for _, e in pairs(thumb_cache) do
        if e.buffer then gfx.setimgdim(e.buffer, 0, 0) end
    end
    thumb_cache = {}
    next_slot = POOL_FIRST
end

-- Render the picker as an inline section (call inside your UI.Run).
-- Returns true if visible (so callers can layout around it). You typically
-- call this after a button that does IconPicker.Open(state, …).
function IconPicker.Draw(state, opts)
    if not state.open then return false end
    opts = opts or {}
    local cell    = opts.cell or 32
    local gap     = opts.gap or 4
    local height  = opts.height or 280
    local columns = opts.columns or 12

    -- Two sources, one grid. REAPER's own PNGs are the big set (~1500 files
    -- in Data/toolbar_icons) and they are what a REAPER user already knows;
    -- the toolkit's glyphs are ~110, they are DRAWN rather than loaded, and
    -- they take the theme's colour. Neither replaces the other, so the picker
    -- offers both instead of choosing for you.
    local cp = (state.source == "cp")
    UI.BeginBar("ip_bar")
    UI.BarRight()
    if UI.BarIcon("ip_close", "Close", "Close the picker") then
        state.open = false
    end
    if state.on_clear then
        if UI.BarIcon("ip_clear", "Eraser", "Remove this icon") then
            state.on_clear()
            state.open = false
        end
    end
    UI.BarSep()
    UI.BarLeft()
    if UI.BarButton("ip_src_native", "REAPER icons", false, not cp) then
        state.source = "native"
    end
    if UI.BarButton("ip_src_cp", "CP pack", false, cp) then
        state.source = "cp"
    end
    UI.BarSep()
    local changed, new_text = UI.BarInput("ip_search", state.search, IP_SEARCH_OPTS)
    if changed then state.search = new_text end
    UI.EndBar()
    UI.Spacing(4)

    -- Filter
    local list = cp and ensure_cp_list() or ensure_list()
    local q = state.search:lower()
    local filtered = {}
    if q == "" then
        filtered = list
    else
        for _, f in ipairs(list) do
            if f:lower():find(q, 1, true) then
                filtered[#filtered + 1] = f
                if #filtered >= 600 then break end -- cap to keep UI snappy
            end
        end
    end

    UI.TextColored(("%d match%s"):format(#filtered, #filtered == 1 and "" or "es"),
        0.6, 0.6, 0.6, 1)

    UI.BeginChild("ip_grid", -1, height, { scrollable = true, border = true, padding = 6 })

    -- Layout the grid using GetCursorPos + manual cell positioning. We
    -- only call UI.LoadImage for cells that fit inside the visible scroll
    -- range so we don't blow through the 900-image buffer cap on big lists.
    local x0, y0 = UI.GetCursorPos()
    local row_h = cell + gap

    for i, fname in ipairs(filtered) do
        local col = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        local cx = x0 + col * (cell + gap)
        local cy = y0 + row * row_h

        local hovered = UI.Core.MouseInClippedRect(cx, cy, cell, cell)

        if hovered then
            local theme = UI.GetTheme()
            local c = theme.colors.button_hovered or theme.colors.accent
            UI.Core.DrawRect(cx - 2, cy - 2, cell + 4, cell + 4, c[1], c[2], c[3], 0.4)
            UI.SetCursor("hand")
        end

        -- Lazy: only load images for cells that fall inside the clip rect.
        -- The LRU pool caps at POOL_SIZE entries so big icon folders
        -- don't exhaust gfx's hard buffer cap.
        if UI.Core.IsVisible(cx, cy, cell, cell) then
            if cp then
                -- Drawn, not loaded: no buffer, no pool, and it takes the
                -- colour it is asked for.
                local draw = UI.Icons[fname]
                local tc = UI.GetTheme().colors.text
                if draw then draw(cx, cy, cell, tc[1], tc[2], tc[3], 1) end
            else
                local thumb = get_thumb(fname)
                if thumb then
                    local sx, sy, sw, sh = first_state_rect(thumb.w, thumb.h)
                    -- gfx.blit modulates by gfx.r/g/b/a — reset before each
                    -- blit so the prior hover/DrawRect tint doesn't dim icons.
                    gfx.set(1, 1, 1, 1)
                    gfx.blit(thumb.buffer, 1, 0, sx, sy, sw, sh, cx, cy, cell, cell)
                else
                    UI.Core.DrawText(fname:sub(1, 2), cx + 6, cy + 8,
                        0.7, 0.7, 0.7, 1)
                end
            end
        end

        if hovered then
            -- Tooltip-ish hint via overlay rect at the bottom of the picker
            state._hovered_name = fname
            if UI.Core.MouseClicked(1) then
                if cp then
                    if state.on_pick_cp then state.on_pick_cp(fname) end
                elseif state.on_pick then
                    state.on_pick(fname)
                end
                state.open = false
            end
        end
    end

    -- Reserve the layout space we used so EndChild's scroll math is correct
    local rows_used = math.ceil(#filtered / columns)
    UI.Spacing(rows_used * row_h)

    UI.EndChild()

    -- The name of what is under the cursor, in the status zone. Close and
    -- Clear moved into the bar at the top, where every other window keeps
    -- them — a picker is not a reason to put them somewhere else.
    UI.AppStatus(state._hovered_name or "click an icon to use it")
    state._hovered_name = nil

    return true
end

return IconPicker
