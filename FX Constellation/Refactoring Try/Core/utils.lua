local Utils = {}

function Utils.Serialize(t)
  local function ser(v)
    local t = type(v)
    if t == "string" then
      return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
      return tostring(v)
    elseif t == "table" then
      local s = "{"
      local first = true
      for k, val in pairs(v) do
        if not first then s = s .. "," end
        first = false
        if type(k) == "string" then
          s = s .. "[" .. ser(k) .. "]=" .. ser(val)
        else
          s = s .. ser(val)
        end
      end
      return s .. "}"
    else
      return "nil"
    end
  end
  return ser(t)
end

function Utils.Deserialize(s)
  if s == "" then return {} end
  local f, err = load("return " .. s)
  if f then
    local ok, res = pcall(f)
    if ok then return res end
  end
  return {}
end

function Utils.EnsureDataDirectory(data_path)
  local path_parts = {}
  for part in data_path:gmatch("[^/]+") do
    table.insert(path_parts, part)
  end
  local current_path = ""
  for i, part in ipairs(path_parts) do
    current_path = current_path .. part .. "/"
    if not reaper.file_exists(current_path) then
      reaper.RecursiveCreateDirectory(current_path, 0)
    end
  end
end

return Utils
