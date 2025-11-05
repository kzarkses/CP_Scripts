local SaveManager = {}

local r = reaper
local registered_modules = {}
local save_flags = {}
local save_timer = 0
local save_cooldown = 0
local min_save_interval = 1.0

function SaveManager.RegisterModule(name, module)
  registered_modules[name] = module
  save_flags[name] = false
end

function SaveManager.ScheduleSave(module_name)
  if not module_name then
    for name, _ in pairs(registered_modules) do
      save_flags[name] = true
    end
  else
    save_flags[module_name] = true
  end
  
  local current_time = r.time_precise()
  if current_time - save_cooldown > min_save_interval then
    save_timer = current_time + 2.0
  end
end

function SaveManager.CheckSave(utils)
  local current_time = r.time_precise()
  
  if current_time > save_timer then
    local something_saved = false
    
    for module_name, should_save in pairs(save_flags) do
      if should_save then
        local module = registered_modules[module_name]
        if module and module.GetSaveData then
          local data = module.GetSaveData()
          r.SetExtState("CP_FXConstellation", module_name, utils.Serialize(data), false)
          something_saved = true
        end
        save_flags[module_name] = false
      end
    end
    
    if something_saved then
      save_cooldown = current_time
    end
  end
end

function SaveManager.SaveAll(utils)
  for name, module in pairs(registered_modules) do
    if module.GetSaveData then
      local data = module.GetSaveData()
      r.SetExtState("CP_FXConstellation", name, utils.Serialize(data), false)
    end
  end
end

function SaveManager.LoadAll(utils)
  for name, module in pairs(registered_modules) do
    if module.LoadSaveData then
      local data_str = r.GetExtState("CP_FXConstellation", name)
      if data_str ~= "" then
        local data = utils.Deserialize(data_str)
        module.LoadSaveData(data)
      end
    end
  end
end

return SaveManager
