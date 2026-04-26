local Engine = {}

local r, Core, ClipManager, Transport

-- GMEM constants (must match JSFX)
local GMEM = {
    CMD       = 0,
    CMD_COL   = 1,
    CMD_CLIP  = 2,
    CMD_MODE  = 3,
    CMD_QUANT = 4,
    CMD_SEQ   = 5,

    LOAD_CMD    = 10,
    LOAD_COL    = 11,
    LOAD_CLIP   = 12,
    LOAD_OFFSET = 13,
    LOAD_CHUNK  = 14,

    META_BASE  = 500,
    VOLUME_BASE = 1000,
    PB_BASE    = 2000,
    TRANSPORT  = 3000,
    AUDIO_BUF  = 20000,

    -- Recording
    REC_STATE  = 800,
    REC_SLOT   = 832,
    REC_POS    = 864,

    -- Reverse transfer (heap -> gmem)
    READ_CMD    = 15,
    READ_COL    = 16,
    READ_CLIP   = 17,
    READ_OFFSET = 18,
    READ_CHUNK  = 19,
}

-- Expose GMEM for other modules if needed
Engine.GMEM = GMEM

local MAX_CLIPS = 8
local CHUNK_SIZE = 16384

function Engine.init(reaper_api, core, clip_manager, transport)
    r = reaper_api
    Core = core
    ClipManager = clip_manager
    Transport = transport

    Engine.cmd_seq = 0
    Engine.load_queue = {}
    Engine.read_queue = {}
    Engine.gmem_attached = false
    Engine.last_init_count = nil
    Engine.jsfx_version_checked = false
    Engine.last_volume = {}  -- cache to avoid redundant gmem writes

    -- Attach to shared memory
    r.gmem_attach("CP_ClipLauncher")
    Engine.gmem_attached = true

    -- Clear all recording states in gmem (may be stale from previous session)
    for i = 0, Core.MAX_COLUMNS - 1 do
        r.gmem_write(GMEM.REC_STATE + i, 0)
    end
end

-- ============================================================
-- ENGINE TRACK MANAGEMENT
-- ============================================================

function Engine.ensureEngineTrack()
    local track = Core.findTrackByName(Core.ENGINE_TRACK_NAME)
    if track then
        Core.state.engine_track = track
        Engine.configureEngineTrack(track)
        Engine.ensureJSFX(track)
        return track
    end

    -- Create engine track at last position (hidden, out of the way)
    r.PreventUIRefresh(1)
    local last_idx = r.CountTracks(0)
    r.InsertTrackAtIndex(last_idx, false)
    track = r.GetTrack(0, last_idx)
    r.GetSetMediaTrackInfo_String(track, "P_NAME", Core.ENGINE_TRACK_NAME, true)
    r.SetTrackColor(track, r.ColorToNative(80, 40, 120) | 0x1000000)

    Engine.configureEngineTrack(track)
    Engine.ensureJSFX(track)
    r.PreventUIRefresh(-1)

    Core.state.engine_track = track
    return track
end

function Engine.configureEngineTrack(track)
    -- 32 channels for 16 stereo pairs
    local nchan = r.GetMediaTrackInfo_Value(track, "I_NCHAN")
    if nchan < 32 then
        r.SetMediaTrackInfo_Value(track, "I_NCHAN", 32)
    end
    -- Disable master send (audio goes through sends only)
    r.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
    -- Ensure engine track volume is at 0dB
    r.SetMediaTrackInfo_Value(track, "D_VOL", 1.0)
    -- Hide from TCP and mixer
    r.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
    r.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
end

local JSFX_EXPECTED_VERSION = 10
local MAX_CLIP_SAMPLES = 480000  -- must match JSFX

function Engine.ensureJSFX(track)
    local fx_count = r.TrackFX_GetCount(track)
    for i = 0, fx_count - 1 do
        local _, name = r.TrackFX_GetFXName(track, i)
        if name and name:find("CP_ClipEngine") then
            -- Check JSFX version (once per session)
            if not Engine.jsfx_version_checked then
                Engine.jsfx_version_checked = true
                local ver = r.gmem_read(3099)
                if ver ~= JSFX_EXPECTED_VERSION then
                    Engine.reloadJSFX(track, i)
                    return Engine.ensureJSFX(track)
                end
            end
            return i
        end
    end

    local fx_idx = r.TrackFX_AddByName(track, "JS:CP Clip Launcher/CP_ClipEngine", false, -1)
    return fx_idx
end

-- Force-reload the JSFX (delete + re-add) and re-transfer all clips
function Engine.reloadJSFX(track, fx_idx)
    r.PreventUIRefresh(1)
    r.TrackFX_Delete(track, fx_idx)
    r.TrackFX_AddByName(track, "JS:CP Clip Launcher/CP_ClipEngine", false, -1)
    r.PreventUIRefresh(-1)

    Engine.retransferAllClips()
end

-- Re-transfer all loaded clips to the JSFX heap (after heap reset)
-- Does NOT mark clips as transferring, so they remain playable during retransfer.
-- If heap was cleared, clips will be silent until their data is restored.
-- If heap wasn't cleared, clips play normally throughout.
function Engine.retransferAllClips()
    -- Clear any pending transfers to avoid duplicates
    Engine.load_queue = {}

    for col_idx, column in ipairs(Core.state.columns) do
        for clip_idx, clip in pairs(column.clips) do
            if clip.loaded and clip.file_path then
                local audio = ClipManager.readAudioFile(clip.file_path)
                if audio then
                    Engine.queueClipTransfer(col_idx, clip_idx, audio.samples_l, audio.samples_r, {
                        sample_rate = audio.sample_rate,
                        channels = audio.channels,
                    })
                end
            end
        end
    end
end

-- ============================================================
-- SEND MANAGEMENT
-- ============================================================

-- Ensure a send from engine to dest_track with correct channel routing
function Engine.ensureSend(dest_track, jsfx_slot)
    local engine = Core.state.engine_track
    if not engine or not dest_track then return -1 end

    -- Check if send already exists to this track
    local num_sends = r.GetTrackNumSends(engine, 0)
    for i = 0, num_sends - 1 do
        local target = r.GetTrackSendInfo_Value(engine, 0, i, "P_DESTTRACK")
        if target == dest_track then
            -- Update channel routing (slot may have changed)
            r.SetTrackSendInfo_Value(engine, 0, i, "I_SRCCHAN", jsfx_slot * 2)
            r.SetTrackSendInfo_Value(engine, 0, i, "I_DSTCHAN", 0)
            r.SetTrackSendInfo_Value(engine, 0, i, "I_SENDMODE", 1) -- post-FX, pre-fader
            return i
        end
    end

    -- Create new send
    local send_idx = r.CreateTrackSend(engine, dest_track)
    if send_idx >= 0 then
        r.SetTrackSendInfo_Value(engine, 0, send_idx, "D_VOL", 1.0)
        r.SetTrackSendInfo_Value(engine, 0, send_idx, "I_SRCCHAN", jsfx_slot * 2)
        r.SetTrackSendInfo_Value(engine, 0, send_idx, "I_DSTCHAN", 0)
        r.SetTrackSendInfo_Value(engine, 0, send_idx, "I_SENDMODE", 1) -- post-FX, pre-fader
    end

    return send_idx
end

function Engine.removeSend(dest_track)
    local engine = Core.state.engine_track
    if not engine or not dest_track then return end

    local num_sends = r.GetTrackNumSends(engine, 0)
    for i = num_sends - 1, 0, -1 do
        local target = r.GetTrackSendInfo_Value(engine, 0, i, "P_DESTTRACK")
        if target == dest_track then
            r.RemoveTrackSend(engine, 0, i)
            return
        end
    end
end

-- ============================================================
-- JSFX SLOT ALLOCATION
-- ============================================================

function Engine.allocateSlot()
    for i = 0, Core.MAX_COLUMNS - 1 do
        if not Core.state.jsfx_slots[i] then
            Core.state.jsfx_slots[i] = true
            return i
        end
    end
    return nil -- all slots taken
end

function Engine.freeSlot(slot)
    if slot and slot >= 0 then
        Core.state.jsfx_slots[slot] = nil
    end
end

-- ============================================================
-- AUTO-SYNC COLUMNS WITH REAPER TRACKS
-- ============================================================

-- Find an existing column by track GUID
function Engine.findColumnByGUID(guid)
    for i, col in ipairs(Core.state.columns) do
        if col.track_guid == guid then
            return col, i
        end
    end
    return nil, -1
end

-- Sync columns array to match current REAPER track list
-- Preserves existing columns (clips, jsfx_slot, sequencer state)
function Engine.syncColumns()
    Engine.ensureEngineTrack()

    local new_columns = {}
    local active_guids = {}
    local track_count = r.CountTracks(0)

    -- Build new columns array in track order
    for i = 0, track_count - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetTrackName(track)

        if name ~= Core.ENGINE_TRACK_NAME then
            local guid = r.GetTrackGUID(track)
            active_guids[guid] = true

            -- Find existing column for this track
            local existing = Engine.findColumnByGUID(guid)

            if existing then
                -- Refresh track pointer
                existing.track = track
                new_columns[#new_columns + 1] = existing
            else
                -- New track: allocate JSFX slot and create column
                local slot = Engine.allocateSlot()
                if slot then
                    local col = Core.createColumn(track)
                    col.track_guid = guid
                    col.jsfx_slot = slot
                    col.is_active = true
                    col.send_index = Engine.ensureSend(track, slot)
                    r.gmem_write(GMEM.VOLUME_BASE + slot, col.volume)
                    new_columns[#new_columns + 1] = col
                end
            end
        end
    end

    -- Cleanup: free slots and remove sends for deleted tracks
    for _, old_col in ipairs(Core.state.columns) do
        if not active_guids[old_col.track_guid] then
            Engine.stopColumnBySlot(old_col.jsfx_slot)
            if old_col.track and r.ValidatePtr(old_col.track, "MediaTrack*") then
                Engine.removeSend(old_col.track)
            end
            Engine.freeSlot(old_col.jsfx_slot)
        end
    end

    Core.state.columns = new_columns
end

-- ============================================================
-- RECEIVE MANAGEMENT (for recording: track -> engine)
-- ============================================================

-- Ensure a receive from source_track into engine on correct channels
function Engine.ensureReceive(source_track, jsfx_slot)
    local engine = Core.state.engine_track
    if not engine or not source_track then return -1 end

    -- Receives on engine are sends from source_track's perspective
    -- Check existing sends from source_track to engine
    local num_sends = r.GetTrackNumSends(source_track, 0)
    for i = 0, num_sends - 1 do
        local target = r.GetTrackSendInfo_Value(source_track, 0, i, "P_DESTTRACK")
        if target == engine then
            -- Update channel routing
            r.SetTrackSendInfo_Value(source_track, 0, i, "I_SRCCHAN", 0)
            r.SetTrackSendInfo_Value(source_track, 0, i, "I_DSTCHAN", jsfx_slot * 2)
            r.SetTrackSendInfo_Value(source_track, 0, i, "I_SENDMODE", 0) -- post-fader
            return i
        end
    end

    -- Create new send from source to engine
    local send_idx = r.CreateTrackSend(source_track, engine)
    if send_idx >= 0 then
        r.SetTrackSendInfo_Value(source_track, 0, send_idx, "D_VOL", 1.0)
        r.SetTrackSendInfo_Value(source_track, 0, send_idx, "I_SRCCHAN", 0)
        r.SetTrackSendInfo_Value(source_track, 0, send_idx, "I_DSTCHAN", jsfx_slot * 2)
        r.SetTrackSendInfo_Value(source_track, 0, send_idx, "I_SENDMODE", 0) -- post-fader
    end

    return send_idx
end

-- Remove receive (send from source to engine)
function Engine.removeReceive(source_track)
    local engine = Core.state.engine_track
    if not engine or not source_track then return end

    local num_sends = r.GetTrackNumSends(source_track, 0)
    for i = num_sends - 1, 0, -1 do
        local target = r.GetTrackSendInfo_Value(source_track, 0, i, "P_DESTTRACK")
        if target == engine then
            r.RemoveTrackSend(source_track, 0, i)
            return
        end
    end
end

-- ============================================================
-- RECORDING CONTROL
-- ============================================================

-- Remove the playback send (engine -> track) to break circular routing completely.
-- REAPER detects cycles even with muted sends, so we must fully remove it.
-- Returns the send config so it can be restored later.
function Engine.removePlaybackSend(track)
    local engine = Core.state.engine_track
    if not engine or not track then return nil end

    local num_sends = r.GetTrackNumSends(engine, 0)
    for i = 0, num_sends - 1 do
        local dest = r.GetTrackSendInfo_Value(engine, 0, i, "P_DESTTRACK")
        if dest == track then
            -- Save config before removing
            local config = {
                src_chan = r.GetTrackSendInfo_Value(engine, 0, i, "I_SRCCHAN"),
                dst_chan = r.GetTrackSendInfo_Value(engine, 0, i, "I_DSTCHAN"),
                vol = r.GetTrackSendInfo_Value(engine, 0, i, "D_VOL"),
            }
            r.RemoveTrackSend(engine, 0, i)
            return config
        end
    end
    return nil
end

-- Restore a previously removed playback send
function Engine.restorePlaybackSend(track, config)
    local engine = Core.state.engine_track
    if not engine or not track or not config then return end

    local send_idx = r.CreateTrackSend(engine, track)
    if send_idx >= 0 then
        r.SetTrackSendInfo_Value(engine, 0, send_idx, "I_SRCCHAN", config.src_chan)
        r.SetTrackSendInfo_Value(engine, 0, send_idx, "I_DSTCHAN", config.dst_chan)
        r.SetTrackSendInfo_Value(engine, 0, send_idx, "D_VOL", config.vol)
    end
end

-- Find first empty clip slot in a column (1-indexed), or nil
function Engine.findEmptySlot(column_index)
    local column = Core.state.columns[column_index]
    if not column then return nil end
    for i = 1, Core.MAX_CLIPS_PER_COLUMN do
        local clip = column.clips[i]
        if not clip or not clip.loaded then
            return i
        end
    end
    return nil
end

-- Start recording on a column into a specific clip slot
function Engine.startRecording(column_index, clip_index)
    local column = Core.state.columns[column_index]
    if not column then return false end
    if column.is_recording then return false end

    -- Stop playback on this column first
    Engine.stopColumn(column_index)

    -- Create receive (track -> engine) for audio capture
    local recv_idx = Engine.ensureReceive(column.track, column.jsfx_slot)
    column.receive_index = recv_idx

    -- CRITICAL: Remove playback send (engine -> track) to break circular routing
    -- REAPER detects engine->track->engine feedback and blocks audio even with muted sends
    column.saved_send_config = Engine.removePlaybackSend(column.track)

    -- Set recording state
    column.is_recording = true
    column.recording_clip = clip_index
    column.recording_samples = 0

    -- Tell JSFX to start recording
    r.gmem_write(GMEM.REC_SLOT + column.jsfx_slot, clip_index - 1) -- 0-indexed
    r.gmem_write(GMEM.REC_POS + column.jsfx_slot, 0)
    r.gmem_write(GMEM.REC_STATE + column.jsfx_slot, 1)

    return true
end

-- Stop recording on a column, finalize the clip
function Engine.stopRecording(column_index)
    local column = Core.state.columns[column_index]
    if not column or not column.is_recording then return false end

    -- Tell JSFX to stop
    r.gmem_write(GMEM.REC_STATE + column.jsfx_slot, 0)

    -- Read final sample count
    local rec_samples = r.gmem_read(GMEM.REC_POS + column.jsfx_slot)
    column.recording_samples = math.floor(rec_samples)

    -- Restore playback send (engine -> track) that was removed for recording
    Engine.restorePlaybackSend(column.track, column.saved_send_config)
    column.saved_send_config = nil

    -- Remove receive (no longer needed)
    Engine.removeReceive(column.track)
    column.receive_index = -1

    -- Create clip metadata if we got audio
    if column.recording_samples > 0 then
        local clip_idx = column.recording_clip
        if not column.clips[clip_idx] then
            column.clips[clip_idx] = Core.createClip()
        end

        local out_srate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 44100
        if out_srate == 0 then out_srate = 44100 end

        local clip = column.clips[clip_idx]
        clip.name = "Rec " .. os.date("%H:%M:%S")
        clip.length_samples = column.recording_samples
        clip.length_seconds = column.recording_samples / out_srate
        clip.sample_rate = out_srate
        clip.channels = 2
        clip.loaded = true
        clip.transferring = false
        clip.source = "recorded"
        clip.file_path = nil  -- no file yet, lives in JSFX heap

        -- Write metadata to gmem so JSFX knows the clip
        local meta_addr = GMEM.META_BASE + (column.jsfx_slot * MAX_CLIPS + (clip_idx - 1)) * 4
        r.gmem_write(meta_addr + 0, 1)                     -- loaded
        r.gmem_write(meta_addr + 1, column.recording_samples) -- length
        r.gmem_write(meta_addr + 2, out_srate)              -- sample rate
        r.gmem_write(meta_addr + 3, 2)                      -- channels (stereo)

        column.is_active = true

        -- Initialize probability
        if not column.probabilities[clip_idx] then
            column.probabilities[clip_idx] = 1.0
        end
        Core.state.dirty = true
    else
        r.ShowConsoleMsg("[REC] WARNING: 0 samples recorded!\n")
    end

    column.is_recording = false
    column.recording_clip = -1

    return true
end

-- Read recording state from JSFX (called in update loop)
function Engine.readRecordState()
    for _, column in ipairs(Core.state.columns) do
        if column.is_recording then
            local rec_pos = r.gmem_read(GMEM.REC_POS + column.jsfx_slot)
            column.recording_samples = math.floor(rec_pos)

            -- Check if JSFX auto-stopped (max length reached)
            local rec_state = r.gmem_read(GMEM.REC_STATE + column.jsfx_slot)
            if rec_state == 2 then
                Engine.stopRecording(
                    (function()
                        for i, c in ipairs(Core.state.columns) do
                            if c == column then return i end
                        end
                        return -1
                    end)()
                )
            end
        end
    end
end

-- ============================================================
-- REVERSE TRANSFER (JSFX heap -> Lua for WAV export)
-- ============================================================

Engine.read_queue = {}

-- Queue a reverse transfer to read clip data from JSFX heap (stereo: L then R)
function Engine.queueClipRead(column_index, clip_index, callback)
    local column = Core.state.columns[column_index]
    if not column then return end

    local clip = column.clips[clip_index]
    if not clip or not clip.loaded then return end

    -- Shared state for combining L+R results
    local stereo_result = { samples_l = nil, samples_r = nil, callback = callback }

    -- Queue L channel read (offset 0)
    Engine.read_queue[#Engine.read_queue + 1] = {
        col = column.jsfx_slot,
        clip = clip_index - 1,
        length = clip.length_samples,
        offset = 0,
        heap_offset = 0,
        samples = {},
        stereo_result = stereo_result,
        channel = "L",
    }

    -- Queue R channel read (offset MAX_CLIP_SAMPLES)
    Engine.read_queue[#Engine.read_queue + 1] = {
        col = column.jsfx_slot,
        clip = clip_index - 1,
        length = clip.length_samples,
        offset = 0,
        heap_offset = MAX_CLIP_SAMPLES,
        samples = {},
        stereo_result = stereo_result,
        channel = "R",
    }
end

-- Process one chunk of reverse transfer per frame
function Engine.processReadQueue()
    if #Engine.read_queue == 0 then return end

    local job = Engine.read_queue[1]

    local read_state = r.gmem_read(GMEM.READ_CMD)
    if read_state == 1 then
        return -- JSFX still copying
    end

    if read_state == 3 then
        -- JSFX has data ready, read it
        local chunk = job.last_chunk or 0
        for i = 0, chunk - 1 do
            job.samples[#job.samples + 1] = r.gmem_read(GMEM.AUDIO_BUF + i)
        end
    end

    -- Check if done
    if job.offset >= job.length then
        -- Store channel result and invoke callback when both L+R are done
        if job.stereo_result then
            if job.channel == "L" then
                job.stereo_result.samples_l = job.samples
            else
                job.stereo_result.samples_r = job.samples
            end
            -- Call callback when both channels are read
            local sr = job.stereo_result
            if sr.samples_l and sr.samples_r and sr.callback then
                sr.callback(sr.samples_l, sr.samples_r)
            end
        end
        table.remove(Engine.read_queue, 1)
        r.gmem_write(GMEM.READ_CMD, 0)
        return
    end

    -- Request next chunk
    local remaining = job.length - job.offset
    local chunk = math.min(CHUNK_SIZE, remaining)

    r.gmem_write(GMEM.READ_COL, job.col)
    r.gmem_write(GMEM.READ_CLIP, job.clip)
    r.gmem_write(GMEM.READ_OFFSET, job.offset + (job.heap_offset or 0))
    r.gmem_write(GMEM.READ_CHUNK, chunk)
    r.gmem_write(GMEM.READ_CMD, 1)

    job.last_chunk = chunk
    job.offset = job.offset + chunk
end

-- ============================================================
-- GMEM COMMANDS
-- ============================================================

local function sendCommand(cmd, jsfx_slot, clip, mode, quantize)
    Engine.cmd_seq = Engine.cmd_seq + 1
    r.gmem_write(GMEM.CMD_COL, jsfx_slot or 0)
    r.gmem_write(GMEM.CMD_CLIP, clip or 0)
    r.gmem_write(GMEM.CMD_MODE, mode or 0)
    r.gmem_write(GMEM.CMD_QUANT, quantize or 0)
    r.gmem_write(GMEM.CMD_SEQ, Engine.cmd_seq)
    r.gmem_write(GMEM.CMD, cmd)
end

-- ============================================================
-- CLIP DATA TRANSFER (Lua -> JSFX via gmem)
-- ============================================================

function Engine.queueClipTransfer(column_index, clip_index, samples_l, samples_r, metadata)
    local column = Core.state.columns[column_index]
    if not column then return end

    -- Queue L channel (offset 0 in heap)
    Engine.load_queue[#Engine.load_queue + 1] = {
        col = column.jsfx_slot,
        clip = clip_index - 1,
        track_guid = column.track_guid,
        clip_lua = clip_index,
        samples = samples_l,
        metadata = nil,  -- metadata written after R channel
        offset = 0,
        heap_offset = 0,
    }

    -- Queue R channel (offset MAX_CLIP_SAMPLES in heap)
    Engine.load_queue[#Engine.load_queue + 1] = {
        col = column.jsfx_slot,
        clip = clip_index - 1,
        track_guid = column.track_guid,
        clip_lua = clip_index,
        samples = samples_r,
        metadata = metadata,  -- finalize after R channel
        offset = 0,
        heap_offset = MAX_CLIP_SAMPLES,
    }
end

function Engine.processLoadQueue()
    if #Engine.load_queue == 0 then return end

    local job = Engine.load_queue[1]

    -- Check if JSFX acknowledged previous chunk
    local load_state = r.gmem_read(GMEM.LOAD_CMD)
    if load_state == 1 then
        return -- JSFX still copying previous chunk
    end

    local remaining = #job.samples - job.offset
    if remaining <= 0 then
        -- All data transferred
        if job.metadata then
            -- Only the final job (R channel) carries metadata — write it and mark clip ready
            local meta_addr = GMEM.META_BASE + (job.col * MAX_CLIPS + job.clip) * 4
            r.gmem_write(meta_addr + 0, 1)                        -- loaded
            r.gmem_write(meta_addr + 1, #job.samples)             -- length
            r.gmem_write(meta_addr + 2, job.metadata.sample_rate)  -- sample rate
            r.gmem_write(meta_addr + 3, job.metadata.channels)    -- channels

            -- Mark clip as ready (find column by GUID, stable across rebuilds)
            local column = Engine.findColumnByGUID(job.track_guid)
            if column and column.clips[job.clip_lua] then
                column.clips[job.clip_lua].transferring = false
            end
        end

        table.remove(Engine.load_queue, 1)
        return
    end

    local chunk = math.min(CHUNK_SIZE, remaining)

    -- Write audio data to gmem transfer buffer
    for i = 0, chunk - 1 do
        r.gmem_write(GMEM.AUDIO_BUF + i, job.samples[job.offset + i + 1])
    end

    -- Signal JSFX to copy this chunk
    r.gmem_write(GMEM.LOAD_COL, job.col)
    r.gmem_write(GMEM.LOAD_CLIP, job.clip)
    r.gmem_write(GMEM.LOAD_OFFSET, job.offset + (job.heap_offset or 0))
    r.gmem_write(GMEM.LOAD_CHUNK, chunk)
    r.gmem_write(GMEM.LOAD_CMD, 1)

    job.offset = job.offset + chunk
end

-- ============================================================
-- PLAYBACK CONTROL
-- ============================================================

function Engine.playClip(column_index, clip_index, play_mode, quantize_mode)
    local column = Core.state.columns[column_index]
    if not column then return false end

    local clip = column.clips[clip_index]
    if not clip or not clip.loaded or clip.transferring then return false end

    play_mode = play_mode or column.play_mode
    quantize_mode = quantize_mode or Core.state.quantize_mode

    -- Force immediate mode when transport is stopped (beat/bar quantize
    -- needs an advancing beat_position to trigger, which doesn't happen
    -- when transport is stopped)
    if not Transport.state.is_playing and quantize_mode ~= Core.QUANTIZE_IMMEDIATE then
        quantize_mode = Core.QUANTIZE_IMMEDIATE
    end

    sendCommand(1, column.jsfx_slot, clip_index - 1, play_mode, quantize_mode)
    return true
end

function Engine.stopColumn(column_index)
    local column = Core.state.columns[column_index]
    if not column then return end
    sendCommand(2, column.jsfx_slot)
end

-- Stop by JSFX slot directly (used during cleanup)
function Engine.stopColumnBySlot(jsfx_slot)
    if not jsfx_slot or jsfx_slot < 0 then return end
    sendCommand(2, jsfx_slot)
end

function Engine.stopAll()
    sendCommand(3)
end

-- Launch a scene: play clip_index on all columns that have a clip at that index
function Engine.launchScene(scene_index, quantize_mode)
    quantize_mode = quantize_mode or Core.state.quantize_mode
    for i, column in ipairs(Core.state.columns) do
        local clip = column.clips[scene_index]
        if clip and clip.loaded and not clip.transferring then
            Engine.playClip(i, scene_index, nil, quantize_mode)
        end
    end
end

-- Stop all columns (scene stop)
function Engine.stopScene()
    Engine.stopAll()
end

-- ============================================================
-- READ PLAYBACK STATE FROM JSFX
-- ============================================================

function Engine.readPlaybackState()
    local ts = Transport.state
    local spb = ts.samples_per_beat
    local ts_num = ts.time_sig_num

    for _, column in ipairs(Core.state.columns) do
        local slot = column.jsfx_slot
        local pb_base = GMEM.PB_BASE + slot * 12
        local is_playing = r.gmem_read(pb_base + 0)
        local clip_idx = r.gmem_read(pb_base + 1)
        local play_pos = r.gmem_read(pb_base + 2)
        local pending = r.gmem_read(pb_base + 3)
        local clip_len = r.gmem_read(pb_base + 4)
        local loop_count = r.gmem_read(pb_base + 5)

        column.playing_clip = is_playing > 0 and (clip_idx + 1) or -1
        column.pending_clip = pending >= 0 and (pending + 1) or -1
        column.jsfx_play_pos = play_pos
        column.jsfx_clip_len = clip_len
        column.loop_count = math.floor(loop_count)

        -- Compute clip-local beat/bar position
        if is_playing > 0 and spb > 0 then
            local beat_pos = play_pos / spb
            column.clip_bar = math.floor(beat_pos / ts_num) + 1
            column.clip_beat = math.floor(beat_pos % ts_num) + 1
        else
            column.clip_bar = nil
            column.clip_beat = nil
        end
    end
end

function Engine.getPlaybackProgress(column_index)
    local column = Core.state.columns[column_index]
    if not column or column.playing_clip < 0 then return 0 end
    if not column.jsfx_clip_len or column.jsfx_clip_len <= 0 then return 0 end

    local pos = column.jsfx_play_pos or 0
    return math.min(1.0, pos / column.jsfx_clip_len)
end

-- ============================================================
-- UPDATE LOOP
-- ============================================================

-- Track transport state for heap protection
Engine.last_transport_playing = nil

function Engine.update()
    -- Transfer audio data chunks
    Engine.processLoadQueue()

    -- Process reverse transfer (JSFX -> Lua)
    Engine.processReadQueue()

    -- Read playback state from JSFX
    Engine.readPlaybackState()

    -- Read recording state
    Engine.readRecordState()

    -- Push volume changes to gmem (only when changed)
    for _, column in ipairs(Core.state.columns) do
        local slot = column.jsfx_slot
        if Engine.last_volume[slot] ~= column.volume then
            r.gmem_write(GMEM.VOLUME_BASE + slot, column.volume)
            Engine.last_volume[slot] = column.volume
        end
    end

    -- Detect JSFX @init reset (backup detection via gmem counter)
    local init_count = r.gmem_read(3095)
    if Engine.last_init_count ~= nil and init_count ~= Engine.last_init_count then
        Engine.retransferAllClips()
    end
    Engine.last_init_count = init_count

    -- Detect transport state changes: REAPER may zero JSFX heap memory
    -- on transport start or stop (destroying clip audio data). Re-transfer
    -- all clips on any transport transition to ensure audio is available.
    local transport_playing = Transport.state.is_playing
    if Engine.last_transport_playing ~= nil and transport_playing ~= Engine.last_transport_playing then
        Engine.retransferAllClips()
    end
    Engine.last_transport_playing = transport_playing

    -- Sync columns with track list periodically (every 60 frames ~ 2 sec)
    Core.state.frame_counter = Core.state.frame_counter + 1
    if Core.state.frame_counter % 60 == 0 then
        Engine.syncColumns()
    end

end

function Engine.cleanup()
    -- Stop all recording
    for i, column in ipairs(Core.state.columns) do
        if column.is_recording then
            Engine.stopRecording(i)
        end
    end
    Engine.stopAll()
end

function Engine.isLoading()
    return #Engine.load_queue > 0
end

function Engine.getLoadingText()
    if #Engine.load_queue == 0 then return nil end
    local job = Engine.load_queue[1]
    local total = #job.samples
    local done = job.offset
    return string.format("Loading... %d%%", math.floor(done / total * 100))
end

return Engine
