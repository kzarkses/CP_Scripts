local ClipManager = {}

local r, Core

function ClipManager.init(reaper_api, core)
    r = reaper_api
    Core = core
end

-- ============================================================
-- AUDIO FILE READING
-- ============================================================

-- Read audio file samples using REAPER's audio accessor
-- Returns stereo float samples (-1 to 1) as two Lua tables (L, R)
-- Supports all formats REAPER supports (WAV, MP3, FLAC, OGG, AIFF...)
function ClipManager.readAudioFile(filepath)
    local source = r.PCM_Source_CreateFromFile(filepath)
    if not source then return nil, "Cannot open file" end

    local length = r.GetMediaSourceLength(source)
    local src_srate = r.GetMediaSourceSampleRate(source)

    if length <= 0 or src_srate <= 0 then
        r.PCM_Source_Destroy(source)
        return nil, "Invalid audio file"
    end

    -- Use project sample rate for output
    local out_srate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 44100
    if out_srate == 0 then out_srate = 44100 end

    local total_samples = math.floor(length * out_srate)

    -- Cap at 10 seconds (480000 samples at 48kHz) to match JSFX limit
    local max_samples = 480000
    if total_samples > max_samples then
        total_samples = max_samples
        length = max_samples / out_srate
    end

    -- Create temporary track and item for audio accessor
    r.PreventUIRefresh(1)

    local track_count = r.CountTracks(0)
    r.InsertTrackAtIndex(track_count, false)
    local temp_track = r.GetTrack(0, track_count)
    local temp_item = r.AddMediaItemToTrack(temp_track)
    local temp_take = r.AddTakeToMediaItem(temp_item)

    r.SetMediaItemTake_Source(temp_take, source)
    r.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)
    r.SetMediaItemInfo_Value(temp_item, "D_POSITION", 0)

    -- Read at 2 channels (REAPER will up/downmix as needed)
    local read_channels = 2
    local accessor = r.CreateTakeAudioAccessor(temp_take)
    if not accessor then
        r.DeleteTrack(temp_track)
        r.PreventUIRefresh(-1)
        return nil, "Cannot create audio accessor"
    end

    local block_size = 4096
    local samples_l = {}
    local samples_r = {}
    local buf = reaper.new_array(block_size * read_channels)

    local pos = 0
    while pos < total_samples do
        local count = math.min(block_size, total_samples - pos)
        r.GetAudioAccessorSamples(accessor, out_srate, read_channels, pos / out_srate, count, buf)

        for i = 0, count - 1 do
            samples_l[#samples_l + 1] = buf[i * read_channels + 1]
            samples_r[#samples_r + 1] = buf[i * read_channels + 2]
        end

        pos = pos + count
    end

    -- Cleanup
    r.DestroyAudioAccessor(accessor)
    r.DeleteTrack(temp_track)
    r.PreventUIRefresh(-1)
    r.Undo_CanUndo2(0)  -- clear last undo point (temp track create/delete)

    return {
        samples_l = samples_l,
        samples_r = samples_r,
        sample_rate = out_srate,
        channels = 2,
        length_samples = #samples_l,
        length_seconds = #samples_l / out_srate,
    }
end

-- ============================================================
-- CLIP MANAGEMENT
-- ============================================================

-- Load an audio file into a clip slot and queue transfer to JSFX
function ClipManager.loadClip(column_index, clip_index, file_path, engine)
    local columns = Core.state.columns
    if not columns[column_index] then return false end

    local column = columns[column_index]
    if not column.clips[clip_index] then
        column.clips[clip_index] = Core.createClip()
    end

    local clip = column.clips[clip_index]

    -- Unload previous if any
    if clip.loaded then
        ClipManager.unloadClip(column_index, clip_index)
    end

    -- Read audio data
    local audio, err = ClipManager.readAudioFile(file_path)
    if not audio then
        return false, err
    end

    -- Update clip metadata
    clip.file_path = file_path
    clip.name = file_path:match("([^/\\]+)%.%w+$") or "clip"
    clip.length_samples = audio.length_samples
    clip.length_seconds = audio.length_seconds
    clip.sample_rate = audio.sample_rate
    clip.channels = audio.channels
    clip.loaded = true
    clip.transferring = engine and true or false
    clip.source = "file"

    -- Initialize probability if not set
    if not column.probabilities[clip_index] then
        column.probabilities[clip_index] = 1.0
    end

    column.is_active = true

    -- Queue transfer to JSFX (stereo: L then R)
    if engine then
        engine.queueClipTransfer(column_index, clip_index, audio.samples_l, audio.samples_r, {
            sample_rate = audio.sample_rate,
            channels = audio.channels,
        })
    end

    Core.state.dirty = true
    r.Undo_OnStateChangeEx("ClipLauncher: Load clip", 1, -1)
    return true
end

-- Unload a clip
function ClipManager.unloadClip(column_index, clip_index)
    local columns = Core.state.columns
    if not columns[column_index] then return end

    local column = columns[column_index]
    local clip = column.clips[clip_index]
    if not clip then return end

    clip.loaded = false
    clip.file_path = nil
    clip.name = ""
    clip.length_samples = 0
    clip.length_seconds = 0
    clip.source = nil

    -- Check if column still has clips
    local has_clips = false
    for _, c in pairs(column.clips) do
        if c.loaded then has_clips = true; break end
    end
    column.is_active = has_clips

    Core.state.dirty = true
    r.Undo_OnStateChangeEx("ClipLauncher: Remove clip", 1, -1)
end

-- Get loaded clip indices for a column
function ClipManager.getLoadedClips(column_index)
    local columns = Core.state.columns
    if not columns[column_index] then return {} end

    local loaded = {}
    for i, clip in pairs(columns[column_index].clips) do
        if clip.loaded then
            loaded[#loaded + 1] = i
        end
    end
    return loaded
end

-- Load audio from a REAPER item/take into a clip slot
function ClipManager.loadFromItem(column_index, clip_index, item, engine)
    local columns = Core.state.columns
    if not columns[column_index] then return false, "Invalid column" end
    if not item or not r.ValidatePtr(item, "MediaItem*") then return false, "Invalid item" end

    local take = r.GetActiveTake(item)
    if not take then return false, "No active take" end

    local source = r.GetMediaItemTake_Source(take)
    if not source then return false, "No source" end

    -- Get source file path
    local source_file = r.GetMediaSourceFileName(source)

    -- Get item/take timing info
    local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take_offset = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")

    -- Use project sample rate
    local out_srate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 44100
    if out_srate == 0 then out_srate = 44100 end

    local total_samples = math.floor(item_len * out_srate)

    -- Cap at 10 seconds (match JSFX limit)
    local max_samples = 480000
    if total_samples > max_samples then
        total_samples = max_samples
        item_len = max_samples / out_srate
    end

    -- Read audio using take audio accessor (always read 2 channels for stereo)
    local read_channels = 2
    local accessor = r.CreateTakeAudioAccessor(take)
    if not accessor then return false, "Cannot create audio accessor" end

    local block_size = 4096
    local samples_l = {}
    local samples_r = {}
    local buf = reaper.new_array(block_size * read_channels)

    local pos = 0
    while pos < total_samples do
        local count = math.min(block_size, total_samples - pos)
        local time_pos = take_offset + (pos / out_srate)
        r.GetAudioAccessorSamples(accessor, out_srate, read_channels, time_pos, count, buf)

        for i = 0, count - 1 do
            samples_l[#samples_l + 1] = buf[i * read_channels + 1]
            samples_r[#samples_r + 1] = buf[i * read_channels + 2]
        end

        pos = pos + count
    end

    r.DestroyAudioAccessor(accessor)

    if #samples_l == 0 then return false, "No audio data" end

    -- Create/update clip
    local column = columns[column_index]
    if not column.clips[clip_index] then
        column.clips[clip_index] = Core.createClip()
    end

    local clip = column.clips[clip_index]
    if clip.loaded then
        ClipManager.unloadClip(column_index, clip_index)
        column.clips[clip_index] = Core.createClip()
        clip = column.clips[clip_index]
    end

    -- Derive name from take or source file
    local _, take_name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if not take_name or take_name == "" then
        take_name = source_file and source_file:match("([^/\\]+)%.%w+$") or "item"
    end

    clip.file_path = source_file ~= "" and source_file or nil
    clip.name = take_name
    clip.length_samples = #samples_l
    clip.length_seconds = #samples_l / out_srate
    clip.sample_rate = out_srate
    clip.channels = 2
    clip.loaded = true
    clip.transferring = engine and true or false
    clip.source = "item"

    if not column.probabilities[clip_index] then
        column.probabilities[clip_index] = 1.0
    end
    column.is_active = true

    -- Queue transfer to JSFX (stereo: L then R)
    if engine then
        engine.queueClipTransfer(column_index, clip_index, samples_l, samples_r, {
            sample_rate = out_srate,
            channels = 2,
        })
    end

    Core.state.dirty = true
    r.Undo_OnStateChangeEx("ClipLauncher: Load from item", 1, -1)
    return true
end

-- Get clip count for a column
function ClipManager.getClipCount(column_index)
    local count = 0
    local columns = Core.state.columns
    if not columns[column_index] then return 0 end

    for _, clip in pairs(columns[column_index].clips) do
        if clip.loaded then count = count + 1 end
    end
    return count
end

-- ============================================================
-- WAV EXPORT (for recorded clips)
-- ============================================================

-- Write a stereo WAV file from L+R sample data
function ClipManager.exportWAV(filepath, samples_l, samples_r, sample_rate)
    local num_samples = #samples_l
    if num_samples == 0 then return false end

    local bits_per_sample = 16
    local num_channels = 2
    local byte_rate = sample_rate * num_channels * bits_per_sample / 8
    local block_align = num_channels * bits_per_sample / 8
    local data_size = num_samples * block_align

    local file = io.open(filepath, "wb")
    if not file then return false end

    -- Helper: write little-endian integers
    local function writeU16(v)
        file:write(string.char(v & 0xFF, (v >> 8) & 0xFF))
    end
    local function writeU32(v)
        file:write(string.char(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF))
    end

    -- RIFF header
    file:write("RIFF")
    writeU32(36 + data_size)
    file:write("WAVE")

    -- fmt chunk
    file:write("fmt ")
    writeU32(16)           -- chunk size
    writeU16(1)            -- PCM format
    writeU16(num_channels)
    writeU32(sample_rate)
    writeU32(byte_rate)
    writeU16(block_align)
    writeU16(bits_per_sample)

    -- data chunk
    file:write("data")
    writeU32(data_size)

    -- Write interleaved stereo samples as 16-bit PCM
    for i = 1, num_samples do
        -- Left
        local sl = math.max(-1, math.min(1, samples_l[i]))
        local int_l = math.floor(sl * 32767 + 0.5)
        if int_l < 0 then int_l = int_l + 65536 end
        writeU16(int_l)
        -- Right
        local sr = math.max(-1, math.min(1, samples_r[i] or sl))
        local int_r = math.floor(sr * 32767 + 0.5)
        if int_r < 0 then int_r = int_r + 65536 end
        writeU16(int_r)
    end

    file:close()
    return true
end

-- Export a recorded clip: read from JSFX heap via Engine, save as WAV
function ClipManager.exportRecordedClip(column_index, clip_index, engine)
    local columns = Core.state.columns
    if not columns[column_index] then return false end

    local column = columns[column_index]
    local clip = column.clips[clip_index]
    if not clip or not clip.loaded or clip.source ~= "recorded" then return false end

    -- Ensure clip directory exists
    r.RecursiveCreateDirectory(Core.clip_directory, 0)

    local filename = string.format("rec_%s_%d_%d_%s.wav",
        column.track_guid:sub(2, 9), column_index, clip_index,
        os.date("%Y%m%d_%H%M%S"))
    local filepath = Core.clip_directory .. filename

    -- Queue reverse transfer (stereo: L then R), then write WAV on completion
    engine.queueClipRead(column_index, clip_index, function(samples_l, samples_r)
        if ClipManager.exportWAV(filepath, samples_l, samples_r, clip.sample_rate) then
            clip.file_path = filepath
            clip.source = "file"  -- now backed by a file
        end
    end)

    return true
end

-- Format clip length for display
function ClipManager.formatLength(seconds)
    if seconds < 1 then
        return string.format("%.0fms", seconds * 1000)
    elseif seconds < 60 then
        return string.format("%.1fs", seconds)
    else
        local m = math.floor(seconds / 60)
        local s = seconds - m * 60
        return string.format("%d:%04.1f", m, s)
    end
end

return ClipManager
