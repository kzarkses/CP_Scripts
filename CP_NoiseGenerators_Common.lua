-- White Noise Generator (CP_GenerateWhiteNoise.lua)
function generateWhiteNoise(buffer, sampleCount)
  for i = 1, sampleCount do
    buffer[i] = math.random() * 2 - 1
  end
end

-- Pink Noise Generator (CP_GeneratePinkNoise.lua)
function generatePinkNoise(buffer, sampleCount)
  local b0, b1, b2, b3, b4, b5, b6 = 0, 0, 0, 0, 0, 0, 0
  for i = 1, sampleCount do
    local white = math.random() * 2 - 1
    b0 = 0.99886 * b0 + white * 0.0555179
    b1 = 0.99332 * b1 + white * 0.0750759
    b2 = 0.96900 * b2 + white * 0.1538520
    b3 = 0.86650 * b3 + white * 0.3104856
    b4 = 0.55000 * b4 + white * 0.5329522
    b5 = -0.7616 * b5 - white * 0.0168980
    buffer[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
    buffer[i] = buffer[i] * 0.11 -- Normalize to roughly -1 to 1
    b6 = white * 0.115926
  end
end

-- Brown Noise Generator (CP_GenerateBrownNoise.lua)
function generateBrownNoise(buffer, sampleCount)
  local last = 0
  for i = 1, sampleCount do
    local white = math.random() * 2 - 1
    last = (last + (0.02 * white)) / 1.02
    buffer[i] = last * 3.5 -- Normalize to roughly -1 to 1
  end
end

-- Shared utility functions
function createAudioFile(filePath, buffer, sampleRate)
  local file, err = io.open(filePath, "wb")
  if not file then
    reaper.ShowMessageBox("Failed to create audio file: " .. tostring(err), "Error", 0)
    return false
  end
  
  -- Write WAV header
  file:write("RIFF")
  file:write(string.pack("<I4", 36 + #buffer * 2)) -- File size
  file:write("WAVE")
  file:write("fmt ")
  file:write(string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sampleRate, sampleRate * 2, 2, 16))
  file:write("data")
  file:write(string.pack("<I4", #buffer * 2)) -- Data size
  
  -- Write audio data
  for _, sample in ipairs(buffer) do
    file:write(string.pack("<h", math.floor(sample * 32767)))
  end
  
  file:close()
  return true
end

function generateNoise(generatorFunc)
  local start_time, end_time = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if start_time == end_time then
    reaper.ShowMessageBox("Please set a time selection before running this script.", "Error", 0)
    return
  end

  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Please select a track before running this script.", "Error", 0)
    return
  end

  local sample_rate = 44100 -- You can adjust this if needed
  local duration = end_time - start_time
  local sample_count = math.floor(duration * sample_rate)

  local buffer = {}
  generatorFunc(buffer, sample_count)

  -- Create temporary WAV file with unique name
  local temp_file = string.format("%s/temp_noise_%s.wav", reaper.GetProjectPath(""), os.time())
  if not createAudioFile(temp_file, buffer, sample_rate) then
    return
  end

  -- Insert audio item
  reaper.PreventUIRefresh(1)
  
  local new_item = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemPosition(new_item, start_time, false)
  reaper.SetMediaItemLength(new_item, duration, false)
  
  local new_take = reaper.AddTakeToMediaItem(new_item)
  reaper.SetMediaItemTake_Source(new_take, reaper.PCM_Source_CreateFromFile(temp_file))
  reaper.UpdateItemInProject(new_item)
  
  -- Select the newly created item and rebuild peaks
  reaper.SetMediaItemSelected(new_item, true)
  reaper.Main_OnCommand(40441, 0) -- Rebuild peaks for selected items
  
  reaper.PreventUIRefresh(-1)

  -- Clean up
  os.remove(temp_file)

  reaper.UpdateArrange()
end
