-- CP_MediaExplorer — Insert
-- Inserting files into the project: at the edit cursor, on a new track, or
-- at an arbitrary arrange point (emulated drag-and-drop release).
--
-- The manual AddMediaItemToTrack path (Soundmole's "fast insert") is used
-- everywhere instead of reaper.InsertMedia: no edit-cursor moves, no track
-- selection churn, no view scroll — the drop does exactly one thing.
--
-- Ownership rule: the take takes ownership of the PCM_source passed to
-- SetMediaItemTake_Source, so every insert creates a FRESH source (never
-- one from the preview cache).

local Insert = {}

local r  -- reaper, injected

function Insert.init(reaper_api)
    r = reaper_api
end

-- Carry-over options (wired to the preview bar by the app):
--   carry_rate_pitch : apply the preview rate/pitch to the inserted take
--   carry_volume     : apply the preview volume as take volume (fixes the
--                      native ME "preview louder than inserted item" gripe)
Insert.carry_rate_pitch = false
Insert.carry_volume     = false
--   swap_resize      : hot-swap also resizes the item to the new source's
--                      length (otherwise the item length is kept and the
--                      new source may loop inside it)
Insert.swap_resize      = false

-- ---------------------------------------------------------------------------
-- Core insert (no global state side effects)
-- ---------------------------------------------------------------------------
-- opts: { rate, pitch, volume, section = {offs, len}, select = true }
-- Returns the new MediaItem or nil.
local function insertItem(track, path, pos, opts)
    if not track or not r.ValidatePtr(track, "MediaTrack*") then return nil end

    local src = r.PCM_Source_CreateFromFile(path)
    if not src then return nil end

    local src_len = r.GetMediaSourceLength(src) or 0
    if src_len <= 0 then
        r.PCM_Source_Destroy(src)
        return nil
    end

    -- Section (waveform strip selection): plain start-offset + length on
    -- the take — keeps the item fully editable (no SECTION source).
    local startoffs, use_len = 0, src_len
    if opts and opts.section then
        startoffs = math.max(0, math.min(opts.section.offs or 0, src_len))
        use_len   = math.max(0.001, math.min(opts.section.len or src_len,
                                             src_len - startoffs))
    end

    local item = r.AddMediaItemToTrack(track)
    if not item then
        r.PCM_Source_Destroy(src)
        return nil
    end
    local take = r.AddTakeToMediaItem(item)
    if not take then
        r.DeleteTrackMediaItem(track, item)
        r.PCM_Source_Destroy(src)
        return nil
    end

    r.SetMediaItemInfo_Value(item, "D_POSITION", pos)
    r.SetMediaItemTake_Source(take, src)  -- take owns src from here on
    if startoffs > 0 then
        r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", startoffs)
    end
    local name = path:match("([^/\\]+)$") or path
    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)

    local timeline_len = use_len
    local rate = opts and opts.rate or 1.0
    if rate ~= 1.0 then
        timeline_len = use_len / rate
        r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
        r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
    end
    if opts and opts.pitch and opts.pitch ~= 0 then
        r.SetMediaItemTakeInfo_Value(take, "D_PITCH", opts.pitch)
    end
    if opts and opts.volume and opts.volume ~= 1.0 then
        r.SetMediaItemTakeInfo_Value(take, "D_VOL", opts.volume)
    end
    r.SetMediaItemInfo_Value(item, "D_LENGTH", timeline_len)

    if not opts or opts.select ~= false then
        r.SelectAllMediaItems(0, false)
        r.SetMediaItemSelected(item, true)
    end
    r.UpdateItemInProject(item)
    -- Freshly imported sources may have no .reapeaks yet — without this the
    -- item draws blank until the arrange is zoomed into sample-read range
    -- (native inserts queue the build automatically; the manual
    -- AddMediaItemToTrack path must do it explicitly). Async, no-op when
    -- peaks already exist.
    r.Main_OnCommand(40047, 0)  -- Peaks: build any missing peaks
    return item
end

-- Build the opts table from the carry-over settings + preview state.
-- preview_state: { rate, pitch, volume, force_rate } — force_rate (the
-- tempo-matched rate) is always applied when present, independent of the
-- carry option (native ME behavior).
local function carryOpts(preview_state)
    local opts = { rate = 1.0, pitch = 0, volume = 1.0 }
    if preview_state then
        if Insert.carry_rate_pitch then
            opts.rate  = preview_state.rate or 1.0
            opts.pitch = preview_state.pitch or 0
        end
        if preview_state.force_rate then
            opts.rate = preview_state.force_rate
        end
        if Insert.carry_volume then
            opts.volume = preview_state.volume or 1.0
        end
        opts.section = preview_state.section
    end
    return opts
end

-- ---------------------------------------------------------------------------
-- Public inserts (each wrapped in a single undo point)
-- ---------------------------------------------------------------------------
-- Insert at edit cursor on the (first) selected track. Falls back to a new
-- track when nothing is selected. Returns the item or nil.
function Insert.AtCursor(path, preview_state)
    local track = r.GetSelectedTrack(0, 0)
    if not track then
        return Insert.OnNewTrack(path, preview_state)
    end
    r.Undo_BeginBlock()
    local item = insertItem(track, path, r.GetCursorPosition(), carryOpts(preview_state))
    r.Undo_EndBlock("Media Explorer: insert file", -1)
    if item then r.UpdateArrange() end
    return item
end

-- Insert at edit cursor on a new track named after the file.
function Insert.OnNewTrack(path, preview_state)
    r.Undo_BeginBlock()
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, true)
    local track = r.GetTrack(0, idx)
    if track then
        local name = (path:match("([^/\\]+)$") or path):gsub("%.[^.]+$", "")
        r.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
    end
    local item = track and insertItem(track, path, r.GetCursorPosition(),
                                      carryOpts(preview_state)) or nil
    r.Undo_EndBlock("Media Explorer: insert file on new track", -1)
    if item then
        r.TrackList_AdjustWindows(false)
        r.UpdateArrange()
    end
    return item
end

-- ---------------------------------------------------------------------------
-- Arrange hit-testing (for emulated drag-and-drop)
-- ---------------------------------------------------------------------------
-- Pixel → project time mapping over the arrange view.
-- Primary: JS arrange HWND rect. Fallback: REAPER's own probe math
-- (GetSet_ArrangeView2 with two known screen x's).
local function arrangeRect()
    if not r.JS_Window_GetRect then return nil end
    local main = r.GetMainHwnd()
    local arrange = r.JS_Window_FindChildByID(main, 0x3E8)  -- 1000 = arrange view
    if not arrange then return nil end
    local ok, left, top, right, bottom = r.JS_Window_GetRect(arrange)
    if not ok then return nil end
    return left, top, right, bottom
end

-- Screen point → project time (or nil when the mapping fails).
local function timeAtScreenX(x, left, right)
    if not left or right <= left then return nil end
    local view_start, view_end = r.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
    if not view_start or view_end <= view_start then return nil end
    local frac = (x - left) / (right - left)
    return view_start + frac * (view_end - view_start)
end

-- Hit-test a global mouse position against the arrange view.
-- Returns: over_arrange (bool), track (may be nil = empty area), time (may be nil)
function Insert.ArrangeHit(mx, my)
    local left, top, right, bottom = arrangeRect()

    -- GetThingFromPoint is the authoritative "what is under this point"
    -- (REAPER 6.36+). info is "arrange" possibly with a suffix.
    if r.GetThingFromPoint then
        local track, info = r.GetThingFromPoint(mx, my)
        if info and info:find("arrange", 1, true) then
            local time = timeAtScreenX(mx, left, right)
            if not time and r.BR_PositionAtMouseCursor then
                local pos = r.BR_PositionAtMouseCursor(false)
                if pos and pos >= 0 then time = pos end
            end
            return true, track, time
        end
        -- The EMPTY area below the last track reports no thing at all (the
        -- "arrange" context is tied to a track row) — but the native ME
        -- still drops there and creates a track. Bounds-check the arrange
        -- window rect for that case: inside + no track = empty-space drop.
        if left and mx >= left and mx < right and my >= top and my < bottom then
            return true, nil, timeAtScreenX(mx, left, right)
        end
        return false, nil, nil
    end

    -- Fallback: bounds check against the arrange rect + GetTrackFromPoint.
    if not left then return false, nil, nil end
    if mx < left or mx >= right or my < top or my >= bottom then
        return false, nil, nil
    end
    local track = r.GetTrackFromPoint(mx, my)
    return true, track, timeAtScreenX(mx, left, right)
end

-- Snap a time to the grid, honoring the global snap toggle.
function Insert.Snap(time)
    if r.GetToggleCommandState(1157) == 1 then  -- Options: toggle snapping
        return r.SnapToGrid(0, time)
    end
    return time
end

-- Drop released over the arrange: insert at (track, time). A drop on empty
-- arrange space below the tracks creates a new track at the end.
-- Returns the item or nil.
function Insert.AtArrange(path, track, time, preview_state)
    if not time then return nil end
    time = Insert.Snap(math.max(0, time))

    r.Undo_BeginBlock()
    local item
    if track then
        item = insertItem(track, path, time, carryOpts(preview_state))
    else
        local idx = r.CountTracks(0)
        r.InsertTrackAtIndex(idx, true)
        local new_track = r.GetTrack(0, idx)
        if new_track then
            local name = (path:match("([^/\\]+)$") or path):gsub("%.[^.]+$", "")
            r.GetSetMediaTrackInfo_String(new_track, "P_NAME", name, true)
            item = insertItem(new_track, path, time, carryOpts(preview_state))
        end
    end
    r.Undo_EndBlock("Media Explorer: insert file (drag)", -1)
    if item then
        r.TrackList_AdjustWindows(false)
        r.UpdateArrange()
    end
    return item
end

-- ---------------------------------------------------------------------------
-- FX insertion (FX chip): TrackFX_AddByName with the EnumInstalledFX name.
-- ---------------------------------------------------------------------------
-- Append the FX to the track's chain and float its window (FL behavior).
function Insert.AddFX(fxname, track, float)
    if not track or not r.ValidatePtr(track, "MediaTrack*") then return false end
    r.Undo_BeginBlock()
    local idx = r.TrackFX_AddByName(track, fxname, false,
                                    -1000 - r.TrackFX_GetCount(track))
    r.Undo_EndBlock("Media Explorer: add FX", -1)
    if idx < 0 then return false end
    if float ~= false then r.TrackFX_Show(track, idx, 3) end
    return true
end

-- New track at the end of the project, named after the plugin, FX added.
function Insert.AddFXNewTrack(fxname, label, float)
    r.Undo_BeginBlock()
    local tidx = r.CountTracks(0)
    r.InsertTrackAtIndex(tidx, true)
    local track = r.GetTrack(0, tidx)
    local ok = false
    if track then
        if label and label ~= "" then
            r.GetSetMediaTrackInfo_String(track, "P_NAME", label, true)
        end
        local idx = r.TrackFX_AddByName(track, fxname, false, -1000)
        ok = idx >= 0
        if ok and float ~= false then r.TrackFX_Show(track, idx, 3) end
    end
    r.Undo_EndBlock("Media Explorer: add FX on new track", -1)
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    return ok
end

-- ---------------------------------------------------------------------------
-- Live drag ghost (native-ME-feel drag-and-drop)
-- ---------------------------------------------------------------------------
-- While a drag hovers the arrange, a REAL item exists in the project and
-- follows the mouse — it occupies space, shows its waveform, and dropping
-- below the last track creates the track live. No Undo_* call happens until
-- commit, so the per-frame create/move/delete churn never mints undo points
-- (REAPER only snapshots on Undo_EndBlock/Undo_OnStateChange).
--
-- ghost = { item, track, temp_track, time }
local ghost = nil
-- Path whose ghost creation failed (unreadable file): retrying every frame
-- would spawn a track + attempt a file-open per frame. Cleared on drag end.
local ghost_dead = nil

function Insert.GhostActive() return ghost ~= nil end

-- Advance the ghost for this frame: mouse is over the arrange at (track,
-- time). track == nil means "below the last track" → a temporary track is
-- created once and reused. preview_state is only read when the ghost item
-- is first created (callers can skip building it while a ghost exists).
function Insert.GhostUpdate(path, track, time, preview_state)
    if not time then return end
    if path == ghost_dead then return end  -- unreadable file: don't retry
    time = Insert.Snap(math.max(0, time))

    r.PreventUIRefresh(1)
    local changed = false
    local track_ui = false  -- a track was created or deleted this frame

    -- Resolve the target track; manage the temporary end-of-project track.
    local temp = ghost and ghost.temp_track or nil
    if not track then
        if temp and r.ValidatePtr(temp, "MediaTrack*") then
            track = temp
        else
            local idx = r.CountTracks(0)
            r.InsertTrackAtIndex(idx, true)
            track = r.GetTrack(0, idx)
            temp = track
            changed = true
            track_ui = true
        end
    elseif temp and track ~= temp then
        -- Back over a real track: move the item off, drop the temp track.
        if ghost and ghost.item and r.ValidatePtr(ghost.item, "MediaItem*")
           and r.GetMediaItem_Track(ghost.item) == temp then
            r.MoveMediaItemToTrack(ghost.item, track)
            ghost.track = track
        end
        if r.ValidatePtr(temp, "MediaTrack*")
           and r.GetTrackNumMediaItems(temp) == 0 then
            r.DeleteTrack(temp)
        end
        temp = nil
        changed = true
        track_ui = true
    end

    if not track then
        r.PreventUIRefresh(-1)
        return
    end

    if not ghost or not r.ValidatePtr(ghost.item, "MediaItem*") then
        local opts = carryOpts(preview_state)
        opts.select = false  -- selection is set on commit, not per frame
        local item = insertItem(track, path, time, opts)
        if item then
            ghost = { item = item, track = track, temp_track = temp, time = time }
            changed = true
        else
            -- Unreadable file: undo this frame's temp track and stop
            -- retrying (a retry per frame would spawn a track per frame).
            ghost_dead = path
            if temp and track == temp and r.ValidatePtr(temp, "MediaTrack*")
               and r.GetTrackNumMediaItems(temp) == 0 then
                r.DeleteTrack(temp)
            end
        end
    else
        if ghost.track ~= track then
            r.MoveMediaItemToTrack(ghost.item, track)
            ghost.track = track
            changed = true
        end
        if ghost.time ~= time then
            r.SetMediaItemInfo_Value(ghost.item, "D_POSITION", time)
            ghost.time = time
            changed = true
        end
        ghost.temp_track = temp
    end

    r.PreventUIRefresh(-1)
    if changed then
        if track_ui then r.TrackList_AdjustWindows(false) end
        r.UpdateArrange()
    end
end

-- Remove the ghost (mouse left the arrange, drag cancelled, script closed).
function Insert.GhostCancel()
    ghost_dead = nil
    if not ghost then return end
    r.PreventUIRefresh(1)
    if ghost.item and r.ValidatePtr(ghost.item, "MediaItem*") then
        local tr = r.GetMediaItem_Track(ghost.item)
        if tr then r.DeleteTrackMediaItem(tr, ghost.item) end
    end
    local temp = ghost.temp_track
    if temp and r.ValidatePtr(temp, "MediaTrack*")
       and r.GetTrackNumMediaItems(temp) == 0 then
        r.DeleteTrack(temp)
        r.TrackList_AdjustWindows(false)
    end
    ghost = nil
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

-- Drop confirmed: keep the item, select it, name a freshly created track,
-- and mint ONE undo point covering item + track (Ctrl+Z removes both).
function Insert.GhostCommit(path)
    ghost_dead = nil
    if not ghost then return nil end
    local item = ghost.item
    local temp = ghost.temp_track
    ghost = nil
    if not (item and r.ValidatePtr(item, "MediaItem*")) then return nil end

    r.SelectAllMediaItems(0, false)
    r.SetMediaItemSelected(item, true)
    if temp and r.ValidatePtr(temp, "MediaTrack*") then
        local name = (path:match("([^/\\]+)$") or path):gsub("%.[^.]+$", "")
        r.GetSetMediaTrackInfo_String(temp, "P_NAME", name, true)
        r.TrackList_AdjustWindows(false)
    end
    r.UpdateArrange()
    -- Full-scope undo point: Undo_OnStateChange is documented items-only,
    -- which would leave the freshly created track behind on Ctrl+Z.
    r.Undo_OnStateChangeEx("Media Explorer: insert file (drag)", -1, -1)
    return item
end

-- ---------------------------------------------------------------------------
-- Hot-swap: replace the source of the selected arrange item in place
-- (Ableton Q / Bitwig audition-in-context). Every swap is a committed
-- one-shot with its own undo point — REAPER's undo history is the revert
-- path (no fragile orphaned-source chains to babysit).
-- ---------------------------------------------------------------------------
function Insert.SwapOneShot(path)
    local item = r.GetSelectedMediaItem(0, 0)
    if not item then return false end
    local take = r.GetActiveTake(item)
    if not take or r.TakeIsMIDI(take) then return false end

    local new_src = r.PCM_Source_CreateFromFile(path)
    if not new_src then return false end

    local old_src = r.GetMediaItemTake_Source(take)
    r.SetMediaItemTake_Source(take, new_src)
    r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0)
    local name = path:match("([^/\\]+)$") or path
    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
    if old_src then r.PCM_Source_Destroy(old_src) end

    -- Option: the item takes the new source's length (otherwise the old
    -- length is kept and a shorter source loops inside it).
    if Insert.swap_resize then
        local new_len = r.GetMediaSourceLength(new_src) or 0
        if new_len > 0 then
            local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
            if not rate or rate <= 0 then rate = 1 end
            r.SetMediaItemInfo_Value(item, "D_LENGTH", new_len / rate)
        end
    end

    -- Force the arrange to re-render the item's waveform for the new
    -- source: queue REAPER's native peaks build (40047 below), then nudge
    -- the item position back and forth (REAPER only invalidates the drawn
    -- peaks on a state change — the Soundmole trick).
    local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    r.SetMediaItemInfo_Value(item, "D_POSITION", pos + 0.0001)
    r.UpdateItemInProject(item)
    r.SetMediaItemInfo_Value(item, "D_POSITION", pos)
    r.UpdateItemInProject(item)
    r.Main_OnCommand(40047, 0)  -- Peaks: build any missing peaks

    r.UpdateArrange()
    r.Undo_OnStateChange("Media Explorer: swap item source")
    return true
end

return Insert
