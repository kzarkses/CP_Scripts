-- State.lua — Global state management and project data collection
local State = {}
local r

function State.init(reaper_api)
    r = reaper_api
end

-- Global state table
State.data = {
    projects = {},
    active_proj = nil,
    active_proj_idx = -1,
    last_refresh = 0,
    first_frame = true,
    -- Item focus
    focused_item = nil,
    focused_take = nil,
    focused_item_id = nil,
    -- Extended item info (cached)
    item_info = nil,  -- {name, pos, len, sr, n_chans, item_vol, take_vol, pitch, rate, fade_in, fade_out, pitch_mode, is_midi, is_subproj, subproj_ptr}
    -- Editor state
    editor_cursor = nil,  -- relative position within item (0..1) for click-to-place
    stereo_mode = true,   -- true = stereo, false = mono merged
}

-- ============================================================================
-- COLLECT PROJECT DATA — scans all open project tabs
-- ============================================================================
function State.CollectProjectData()
    local projects = {}
    local active_proj = r.EnumProjects(-1)
    local active_idx = -1
    local idx = 0

    while true do
        local proj, proj_fn = r.EnumProjects(idx)
        if not proj then break end

        if proj == active_proj then active_idx = idx end

        local master = r.GetMasterTrack(proj)
        local track_count = r.CountTracks(proj)
        local master_vol = r.GetMediaTrackInfo_Value(master, "D_VOL")
        local master_pan = r.GetMediaTrackInfo_Value(master, "D_PAN")
        local master_mute = r.GetMediaTrackInfo_Value(master, "B_MUTE") == 1
        local peak_l = r.Track_GetPeakInfo(master, 0)
        local peak_r_val = r.Track_GetPeakInfo(master, 1)
        local play_state = r.GetPlayStateEx(proj)
        local is_playing = (play_state & 1) == 1
        local is_paused = (play_state & 2) == 2
        local play_pos = r.GetPlayPositionEx(proj)
        local cursor_pos = r.GetCursorPositionEx(proj)
        local tempo = r.GetProjectTimeSignature2(proj)
        local is_active = (proj == active_proj)

        -- Track data (with FX) — only for active project
        local tracks = {}
        if is_active then
            for t = 0, track_count - 1 do
                local track = r.GetTrack(proj, t)
                if track then
                    local _, track_name = r.GetTrackName(track)
                    local vol = r.GetMediaTrackInfo_Value(track, "D_VOL")
                    local pan = r.GetMediaTrackInfo_Value(track, "D_PAN")
                    local mute = r.GetMediaTrackInfo_Value(track, "B_MUTE") == 1
                    local solo = r.GetMediaTrackInfo_Value(track, "I_SOLO") > 0
                    local t_peak_l = r.Track_GetPeakInfo(track, 0)
                    local t_peak_r = r.Track_GetPeakInfo(track, 1)
                    local color = r.GetTrackColor(track)

                    -- FX chain
                    local fx_list = {}
                    local fx_count = r.TrackFX_GetCount(track)
                    for f = 0, fx_count - 1 do
                        local _, fx_name = r.TrackFX_GetFXName(track, f, "")
                        local clean = fx_name:gsub("^VST3?i?: ", ""):gsub("^JS: ", ""):gsub(" %(.+%)$", "")
                        if #clean > 12 then clean = clean:sub(1, 11) .. "." end
                        fx_list[#fx_list + 1] = {
                            name = clean,
                            enabled = r.TrackFX_GetEnabled(track, f),
                            idx = f,
                        }
                    end

                    -- Sends
                    local send_list = {}
                    local send_count = r.GetTrackNumSends(track, 0) -- 0 = sends
                    for s = 0, send_count - 1 do
                        local dest_track = r.GetTrackSendInfo_Value(track, 0, s, "P_DESTTRACK")
                        local send_name = ""
                        if dest_track then
                            local _, dn = r.GetTrackName(dest_track)
                            send_name = dn or "?"
                            if #send_name > 8 then send_name = send_name:sub(1, 7) .. "." end
                        end
                        local send_mute = r.GetTrackSendInfo_Value(track, 0, s, "B_MUTE") == 1
                        send_list[#send_list + 1] = {
                            name = send_name,
                            muted = send_mute,
                            idx = s,
                        }
                    end

                    tracks[#tracks + 1] = {
                        ptr = track, name = track_name,
                        vol = vol, pan = pan, mute = mute, solo = solo,
                        peak_l = t_peak_l, peak_r = t_peak_r,
                        color = color, index = t, fx = fx_list,
                        sends = send_list,
                    }
                end
            end
        end

        -- Project name
        local name = "Untitled"
        if proj_fn and proj_fn ~= "" then
            name = proj_fn:match("([^/\\]+)$") or "Untitled"
            name = name:gsub("%.rpp$", ""):gsub("%.RPP$", "")
        end

        projects[#projects + 1] = {
            ptr = proj, name = name, idx = idx,
            master = master, master_vol = master_vol,
            master_pan = master_pan, master_mute = master_mute,
            peak_l = peak_l, peak_r = peak_r_val,
            is_playing = is_playing, is_paused = is_paused,
            play_pos = play_pos, cursor_pos = cursor_pos,
            tempo = tempo, track_count = track_count,
            tracks = tracks, is_active = is_active,
        }
        idx = idx + 1
    end

    State.data.active_proj = active_proj
    State.data.active_proj_idx = active_idx
    State.data.projects = projects
    return projects
end

-- ============================================================================
-- DETECT SELECTED ITEM — enriched info for Item Editor
-- ============================================================================
function State.DetectSelectedItem()
    local proj = State.data.active_proj
    if not proj then
        State.data.focused_item = nil
        State.data.focused_take = nil
        State.data.focused_item_id = nil
        State.data.item_info = nil
        return
    end

    local item = r.GetSelectedMediaItem(proj, 0)
    if not item then
        State.data.focused_item = nil
        State.data.focused_take = nil
        State.data.focused_item_id = nil
        State.data.item_info = nil
        return
    end

    local item_id = tostring(item)
    local take = r.GetActiveTake(item)

    State.data.focused_item = item
    State.data.focused_take = take
    State.data.focused_item_id = item_id

    -- Build extended info
    local info = {}
    info.pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    info.len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    info.item_vol = r.GetMediaItemInfo_Value(item, "D_VOL")
    info.fade_in = r.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    info.fade_out = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")

    if take then
        info.is_midi = r.TakeIsMIDI(take)
        local _, take_name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        info.take_vol = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
        info.pitch = r.GetMediaItemTakeInfo_Value(take, "D_PITCH")
        info.rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        info.pitch_mode = r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")

        -- Source info
        local source = r.GetMediaItemTake_Source(take)
        if source then
            info.sr = r.GetMediaSourceSampleRate(source)
            info.n_chans = r.GetMediaSourceNumChannels(source)
            local src_type = r.GetMediaSourceType(source, "")

            -- Source length and offset for full-source view
            local source_len = r.GetMediaSourceLength(source)
            local take_offset = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
            info.source_len = source_len
            info.source_offset = take_offset
            info.playrate = info.rate
            -- Audio before the item (in item-time seconds)
            if info.rate > 0 then
                info.pre_item = take_offset / info.rate
                local post_src = source_len - take_offset - info.len * info.rate
                info.post_item = math.max(0, post_src / info.rate)
            else
                info.pre_item = 0
                info.post_item = 0
            end

            -- Fade shapes
            info.fade_in_shape = r.GetMediaItemInfo_Value(item, "C_FADEINSHAPE")
            info.fade_out_shape = r.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE")

            -- Loop source
            info.loop_src = r.GetMediaItemInfo_Value(item, "B_LOOPSRC")

            -- Item name
            if take_name and take_name ~= "" then
                info.name = take_name
            else
                local _, fn = r.GetMediaSourceFileName(source, "")
                info.name = fn and fn:match("([^/\\]+)$") or "Untitled"
            end

            -- Subproject detection
            info.is_subproj = (src_type == "RPP_PROJECT")
            if info.is_subproj then
                local _, src_fn = r.GetMediaSourceFileName(source, "")
                info.subproj_ptr = nil
                if src_fn and src_fn ~= "" then
                    local pidx = 0
                    while true do
                        local p, p_fn = r.EnumProjects(pidx)
                        if not p then break end
                        if p_fn and p_fn ~= "" then
                            if src_fn:gsub("\\", "/"):lower() == p_fn:gsub("\\", "/"):lower() then
                                info.subproj_ptr = p
                                break
                            end
                        end
                        pidx = pidx + 1
                    end
                end
            end
        else
            info.name = "Untitled"
            info.sr = 0
            info.n_chans = 0
            info.source_len = 0
            info.source_offset = 0
            info.playrate = 1
            info.pre_item = 0
            info.post_item = 0
            info.fade_in_shape = 0
            info.fade_out_shape = 0
            info.loop_src = 0
        end

        -- Stretch markers
        info.stretch_markers = {}
        local sm_count = r.GetTakeNumStretchMarkers(take)
        for i = 0, sm_count - 1 do
            local _, pos, srcpos = r.GetTakeStretchMarker(take, i)
            local _, slope = r.GetTakeStretchMarkerSlope(take, i)
            info.stretch_markers[#info.stretch_markers + 1] = {
                idx = i, pos = pos, srcpos = srcpos, slope = slope or 0
            }
        end

        -- Take FX chain
        info.take_fx = {}
        local tfx_count = r.TakeFX_GetCount(take)
        for f = 0, tfx_count - 1 do
            local _, fx_name = r.TakeFX_GetFXName(take, f, "")
            local clean = fx_name:gsub("^VST3?i?: ", ""):gsub("^JS: ", ""):gsub(" %(.+%)$", "")
            if #clean > 18 then clean = clean:sub(1, 17) .. "." end
            info.take_fx[#info.take_fx + 1] = {
                idx = f,
                name = clean,
                enabled = r.TakeFX_GetEnabled(take, f),
            }
        end
    else
        info.name = "No take"
        info.is_midi = false
        info.take_vol = 1
        info.pitch = 0
        info.rate = 1
        info.pitch_mode = -1
        info.sr = 0
        info.n_chans = 0
        info.stretch_markers = {}
        info.take_fx = {}
    end

    State.data.item_info = info
end

return State
