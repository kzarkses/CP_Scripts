local PresetManager = {}

local r = reaper
local presets = {}
local data_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/Data/"
local presets_file = data_path .. "presets.dat"

function PresetManager.Initialize(utils)
  utils.EnsureDataDirectory(data_path)
  PresetManager.LoadPresetsFromFile(utils)
end

function PresetManager.GetPresets()
  return presets
end

function PresetManager.SavePreset(name, preset_data)
  if name == "" then return end
  presets[name] = preset_data
end

function PresetManager.LoadPreset(name)
  return presets[name]
end

function PresetManager.DeletePreset(name)
  if presets[name] then
    presets[name] = nil
    return true
  end
  return false
end

function PresetManager.RenamePreset(old_name, new_name)
  if presets[old_name] and new_name ~= "" and old_name ~= new_name then
    presets[new_name] = presets[old_name]
    presets[old_name] = nil
    return true
  end
  return false
end

function PresetManager.GetPreset(name)
  return presets[name]
end

function PresetManager.SavePresetsToFile(utils)
  if not next(presets) then return end
  local file = io.open(presets_file, "w")
  if file then
    file:write(utils.Serialize(presets))
    file:close()
  end
end

function PresetManager.LoadPresetsFromFile(utils)
  if r.file_exists(presets_file) then
    local file = io.open(presets_file, "r")
    if file then
      local content = file:read("*all")
      file:close()
      if content and content ~= "" then
        presets = utils.Deserialize(content) or {}
      end
    end
  end
end

function PresetManager.GetSaveData()
  return presets
end

function PresetManager.LoadSaveData(data)
  if data then
    presets = data
  end
end

return PresetManager
