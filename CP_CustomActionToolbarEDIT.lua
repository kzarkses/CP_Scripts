-- @description Custom Actions Toolbar (Transport attachment)
-- @version 2.0
-- @author Claude
-- @about
--   Creates a customizable toolbar for REAPER actions with ReaImGui

local r = reaper
local extname = "CP_CustomToolbar_ReaImGui"

-- Check for ReaImGui
if not r.ImGui_CreateContext then
  r.ShowMessageBox("This script requires ReaImGui extension. Please install it via ReaPack.", "Error", 0)
  return
end

local ctx = r.ImGui_CreateContext('Custom Actions Toolbar')

-- Default configuration
local config = {
  -- Button and layout settings
  buttons = {},
  button_size = 32,
  button_spacing = 4,
  toolbar_height = 32,
  min_width = 100,
  
  -- Visual settings
  colors = {
    background = 0x33333366,
    text = 0xFFFFFFFF,
    button = 0x44444477,
    button_hovered = 0x55555588, 
    button_active = 0x666666AA,
    border = 0x444444FF,
  },
  
  -- Border and corner settings
  corner_radius = 5,
  border_width = 1,
  
  -- Transport attachment
  follow_transport = true,
  rel_pos_x = 0.5,
  rel_pos_y = 0.3,
  last_pos_x = 100,
  last_pos_y = 100,
  
  -- State
  first_run = true
}

-- Icon manager
local icon_manager = {
  icons = {},
  
  load_icon = function(self, icon_name)
    if not icon_name or icon_name == "" then return nil end
    if self.icons[icon_name] then return self.icons[icon_name] end
    
    -- Try standard REAPER paths first
    local reaper_paths = {
      r.GetResourcePath() .. "/Data/toolbar_icons/",
      r.GetResourcePath() .. "/Data/skins/Default/toolbar_icons/"
    }

    for _, path in ipairs(reaper_paths) do
      local icon_path = path .. icon_name .. ".png"
      if r.file_exists(icon_path) then
        self.icons[icon_name] = r.ImGui_CreateImage(icon_path)
        return self.icons[icon_name]
      end
    end
    
    -- Try theme icons
    local theme_path = r.GetLastColorThemeFile()
    local theme_dir = theme_path:match("(.+)[/\\][^/\\]+$")
    if theme_dir then
      local icon_path = theme_dir .. "/icons/" .. icon_name .. ".png"
      if r.file_exists(icon_path) then
        self.icons[icon_name] = r.ImGui_CreateImage(icon_path)
        return self.icons[icon_name]
      end
    end
    
    -- Try direct path
    if r.file_exists(icon_name) then
      self.icons[icon_name] = r.ImGui_CreateImage(icon_path)
      return self.icons[icon_name]
    end
    
    return nil
  end,
  
  cleanup = function(self)
    for _, img in pairs(self.icons) do
      r.ImGui_DestroyImage(img)
    end
    self.icons = {}
  end
}

-- Serialization utilities
function SerializeTable(tbl)
  local result = "{"
  for k, v in pairs(tbl) do
    if type(k) == "string" then
      result = result .. '["' .. k .. '"]='
    else
      result = result .. "[" .. k .. "]="
    end
    
    if type(v) == "table" then
      result = result .. SerializeTable(v)
    elseif type(v) == "string" then
      result = result .. '"' .. v .. '"'
    else
      result = result .. tostring(v)
    end
    
    result = result .. ","
  end
  
  result = result .. "}"
  return result
end

function DeserializeTable(str)
  local func = load("return " .. str)
  if func then
    local success, result = pcall(func)
    if success then
      return result
    end
  end
  return {}
end

-- Configuration management
function SaveConfig()
  local buttons_str = SerializeTable(config.buttons)
  r.SetExtState(extname, "buttons", buttons_str, true)
  
  local colors_str = SerializeTable(config.colors)
  r.SetExtState(extname, "colors", colors_str, true)
  
  r.SetExtState(extname, "pos_x", tostring(config.last_pos_x), true)
  r.SetExtState(extname, "pos_y", tostring(config.last_pos_y), true)
  
  r.SetExtState(extname, "button_size", tostring(config.button_size), true)
  r.SetExtState(extname, "button_spacing", tostring(config.button_spacing), true)
  
  r.SetExtState(extname, "corner_radius", tostring(config.corner_radius), true)
  r.SetExtState(extname, "border_width", tostring(config.border_width), true)
  
  r.SetExtState(extname, "follow_transport", config.follow_transport and "1" or "0", true)
  r.SetExtState(extname, "rel_pos_x", tostring(config.rel_pos_x), true)
  r.SetExtState(extname, "rel_pos_y", tostring(config.rel_pos_y), true)
end

function LoadConfig()
  -- Load buttons
  local buttons_str = r.GetExtState(extname, "buttons")
  if buttons_str ~= "" then
    config.buttons = DeserializeTable(buttons_str)
  else
    -- Default buttons
    config.buttons = {
      {name = "Play", action_id = "1007", icon = "transport_play"},
      {name = "Stop", action_id = "1016", icon = "transport_stop"}
    }
  end
  
  -- Load colors
  local colors_str = r.GetExtState(extname, "colors")
  if colors_str ~= "" then
    local loaded_colors = DeserializeTable(colors_str)
    for k, v in pairs(loaded_colors) do
      config.colors[k] = v
    end
  end
  
  -- Load position
  local pos_x = r.GetExtState(extname, "pos_x")
  local pos_y = r.GetExtState(extname, "pos_y")
  if pos_x ~= "" then config.last_pos_x = tonumber(pos_x) end
  if pos_y ~= "" then config.last_pos_y = tonumber(pos_y) end
  
  -- Load button size and spacing
  local button_size = r.GetExtState(extname, "button_size")
  local button_spacing = r.GetExtState(extname, "button_spacing")
  if button_size ~= "" then config.button_size = tonumber(button_size) end
  if button_spacing ~= "" then config.button_spacing = tonumber(button_spacing) end
  
  -- Load corner radius and border
  local corner_radius = r.GetExtState(extname, "corner_radius")
  local border_width = r.GetExtState(extname, "border_width")
  if corner_radius ~= "" then config.corner_radius = tonumber(corner_radius) end
  if border_width ~= "" then config.border_width = tonumber(border_width) end
  
  -- Load transport following
  local follow_transport = r.GetExtState(extname, "follow_transport")
  local rel_pos_x = r.GetExtState(extname, "rel_pos_x")
  local rel_pos_y = r.GetExtState(extname, "rel_pos_y")
  
  if follow_transport ~= "" then config.follow_transport = follow_transport == "1" end
  if rel_pos_x ~= "" then config.rel_pos_x = tonumber(rel_pos_x) end
  if rel_pos_y ~= "" then config.rel_pos_y = tonumber(rel_pos_y) end
end

-- Action functions
function ExecuteAction(action_id)
  if action_id and action_id ~= "" then
    local cmd_id = tonumber(action_id)
    if cmd_id then
      r.Main_OnCommand(cmd_id, 0)
    end
  end
end

function ResolveActionName(action_id)
  if action_id and action_id ~= "" then
    local cmd_id = tonumber(action_id)
    if cmd_id then
      local _, name = r.GetActionName(cmd_id, 0)
      return name
    end
  end
  return "Unknown"
end

-- Transport handling
function FollowTransport()
  if not config.follow_transport then return false end
  
  local transport_hwnd = r.JS_Window_Find("transport", true)
  if not transport_hwnd then return false end
  
  local retval, orig_LEFT, orig_TOP, orig_RIGHT, orig_BOT = r.JS_Window_GetRect(transport_hwnd)
  if not retval then return false end
  
  local LEFT, TOP = r.ImGui_PointConvertNative(ctx, orig_LEFT, orig_TOP)
  local RIGHT, BOT = r.ImGui_PointConvertNative(ctx, orig_RIGHT, orig_BOT)
  
  local transport_width = RIGHT - LEFT
  local transport_height = BOT - TOP
  
  local target_x = LEFT + (config.rel_pos_x * transport_width)
  local target_y = TOP + (config.rel_pos_y * transport_height)
  
  -- Calculate toolbar width
  local toolbar_width = #config.buttons * (config.button_size + config.button_spacing)
  
  r.ImGui_SetNextWindowPos(ctx, target_x - (toolbar_width/2), target_y)
  return true
end

-- Simple button editor
function AddNewButton()
  local retval, user_input = r.GetUserInputs("Add Button", 3, 
      "Button Name:,Action ID:,Icon Name:", "New Button,1007,transport_play")
  
  if retval then
    local name, action_id, icon = user_input:match("([^,]*),([^,]*),([^,]*)")
    
    table.insert(config.buttons, {
      name = name or "Button",
      action_id = action_id or "",
      icon = icon or ""
    })
    
    SaveConfig()
  end
end

function EditButton(index)
  local button = config.buttons[index]
  if not button then return end
  
  local retval, user_input = r.GetUserInputs("Edit Button", 3,
      "Button Name:,Action ID:,Icon Name:", 
      button.name .. "," .. button.action_id .. "," .. button.icon)
  
  if retval then
    local name, action_id, icon = user_input:match("([^,]*),([^,]*),([^,]*)")
    
    config.buttons[index] = {
      name = name or button.name,
      action_id = action_id or button.action_id,
      icon = icon or button.icon
    }
    
    SaveConfig()
  end
end

function RemoveButton(index)
  if index > 0 and index <= #config.buttons then
    table.remove(config.buttons, index)
    SaveConfig()
  end
end

-- Settings dialog
function ShowSettingsDialog()
  r.ImGui_SetNextWindowSize(ctx, 400, 500, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "Toolbar Settings", true)
  
  if visible then
    -- Transport attachment
    local follow_changed, follow_new = r.ImGui_Checkbox(ctx, "Follow Transport", config.follow_transport)
    if follow_changed then 
      config.follow_transport = follow_new
      SaveConfig()
    end
    
    -- if config.follow_transport then
    --   -- Direct inputs for position
    --   r.ImGui_Text(ctx, "Position (0-1 horizontal, 0-1 vertical):")
    --   local retval, input = r.GetUserInputs("Transport Position", 2, 
    --                                       "X (0-1):,Y (0-1):", 
    --                                       config.rel_pos_x .. "," .. config.rel_pos_y)
    --   if retval then
    --     local pos_x, pos_y = input:match("([^,]*),([^,]*)")
    --     config.rel_pos_x = tonumber(pos_x) or config.rel_pos_x
    --     config.rel_pos_y = tonumber(pos_y) or config.rel_pos_y
    --     SaveConfig()
    --   end
    -- end
    
    r.ImGui_Separator(ctx)
    
    -- Size settings
    if r.ImGui_CollapsingHeader(ctx, "Size Settings") then
      r.ImGui_Text(ctx, "Enter button size (16-64):")
      local retval, input = r.GetUserInputs("Button Size", 1, "Size (16-64):", tostring(config.button_size))
      if retval then
        config.button_size = math.min(64, math.max(16, tonumber(input) or config.button_size))
        config.toolbar_height = config.button_size
        SaveConfig()
      end
      
      r.ImGui_Text(ctx, "Enter button spacing (0-10):")
      local retval, input = r.GetUserInputs("Button Spacing", 1, "Spacing (0-10):", tostring(config.button_spacing))
      if retval then
        config.button_spacing = math.min(10, math.max(0, tonumber(input) or config.button_spacing))
        SaveConfig()
      end
      
      r.ImGui_Text(ctx, "Enter corner radius (0-20):")
      local retval, input = r.GetUserInputs("Corner Radius", 1, "Radius (0-20):", tostring(config.corner_radius))
      if retval then
        config.corner_radius = math.min(20, math.max(0, tonumber(input) or config.corner_radius))
        SaveConfig()
      end
      
      r.ImGui_Text(ctx, "Enter border width (0-5):")
      local retval, input = r.GetUserInputs("Border Width", 1, "Width (0-5):", tostring(config.border_width))
      if retval then
        config.border_width = math.min(5, math.max(0, tonumber(input) or config.border_width))
        SaveConfig()
      end
    end
    
    -- Color settings
    if r.ImGui_CollapsingHeader(ctx, "Color Settings") then
      r.ImGui_Text(ctx, "Colors (format: 0xRRGGBBAA):")
      
      local function GetColorInput(name, current_color)
        r.ImGui_Text(ctx, name .. ":")
        local color_str = string.format("0x%08X", current_color)
        local retval, input = r.GetUserInputs(name, 1, "Color (0xRRGGBBAA):", color_str)
        if retval and input:match("^0x%x+$") then
          return tonumber(input)
        end
        return current_color
      end
      
      config.colors.background = GetColorInput("Background", config.colors.background)
      config.colors.text = GetColorInput("Text", config.colors.text)
      config.colors.button = GetColorInput("Button", config.colors.button)
      config.colors.button_hovered = GetColorInput("Button Hover", config.colors.button_hovered)
      config.colors.button_active = GetColorInput("Button Active", config.colors.button_active)
      config.colors.border = GetColorInput("Border", config.colors.border)
      
      SaveConfig()
    end
    
    -- Button management
    if r.ImGui_CollapsingHeader(ctx, "Button Management") then
      if r.ImGui_Button(ctx, "Add New Button") then
        AddNewButton()
      end
      
      r.ImGui_Separator(ctx)
      r.ImGui_Text(ctx, "Current Buttons:")
      
      for i, button in ipairs(config.buttons) do
        local label = button.name .. " [" .. button.action_id .. "]"
        r.ImGui_Text(ctx, label)
        
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Edit##" .. i) then
          EditButton(i)
        end
        
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Delete##" .. i) then
          RemoveButton(i)
        end
      end
    end
    
    r.ImGui_Separator(ctx)
    
    if r.ImGui_Button(ctx, "Close") then 
      settings_open = false
    end
    
    r.ImGui_End(ctx)
  end
  
  if not open then settings_open = false end
  
  return open
end

-- Main toolbar drawing
function DrawToolbar()
  -- Calculate window size based on buttons
  local toolbar_width = #config.buttons * (config.button_size + config.button_spacing) - config.button_spacing
  if toolbar_width < config.min_width then toolbar_width = config.min_width end
  
  -- Set window styling
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), config.corner_radius)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), config.corner_radius / 2)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), config.border_width)
  
  -- Set window colors
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), config.colors.background)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), config.colors.text)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), config.colors.border)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), config.colors.button)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), config.colors.button_hovered)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), config.colors.button_active)
  
  -- Set window flags
  local window_flags = r.ImGui_WindowFlags_NoTitleBar()
                     | r.ImGui_WindowFlags_NoScrollbar()
                     | r.ImGui_WindowFlags_AlwaysAutoResize()
  
  if config.follow_transport then
    window_flags = window_flags | r.ImGui_WindowFlags_NoMove()
                  | r.ImGui_WindowFlags_NoResize()
    
    -- Try to attach to transport
    local positioned = FollowTransport()
    if not positioned then
      -- Fall back to saved position
      r.ImGui_SetNextWindowPos(ctx, config.last_pos_x, config.last_pos_y)
    end
  else
    -- Position window using last saved coordinates on first run
    if config.first_run then
      r.ImGui_SetNextWindowPos(ctx, config.last_pos_x, config.last_pos_y)
      config.first_run = false
    end
  end
  
  r.ImGui_SetNextWindowSize(ctx, toolbar_width, config.toolbar_height)
  
  local visible, open = r.ImGui_Begin(ctx, 'Custom Toolbar', true, window_flags)
  
  if visible then
    -- Store position if not attached to transport
    if not config.follow_transport then
      local pos_x, pos_y = r.ImGui_GetWindowPos(ctx)
      if pos_x ~= config.last_pos_x or pos_y ~= config.last_pos_y then
        config.last_pos_x = pos_x
        config.last_pos_y = pos_y
        SaveConfig()
      end
    end
    
    -- Right-click menu
    if r.ImGui_IsWindowHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 1) then
      if not r.ImGui_IsAnyItemHovered(ctx) then
        settings_open = true
      end
    end
    
    -- Draw buttons
    for i, button in ipairs(config.buttons) do
      local icon_img = icon_manager:load_icon(button.icon)
      local button_id = "btn_" .. i
      
      if icon_img then
        if r.ImGui_ImageButton(ctx, button_id, icon_img, config.button_size, config.button_size) then
          ExecuteAction(button.action_id)
        end
      else
        if r.ImGui_Button(ctx, button_id .. "_" .. (button.name:sub(1,1) or "?"), config.button_size, config.button_size) then
          ExecuteAction(button.action_id)
        end
      end
      
      -- Show tooltip
      if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, button.name or ResolveActionName(button.action_id))
      end
      
      -- Add spacing between buttons
      if i < #config.buttons then
        r.ImGui_SameLine(ctx, 0, config.button_spacing)
      end
    end
    
    r.ImGui_End(ctx)
  end
  
  -- Pop styles
  r.ImGui_PopStyleVar(ctx, 3)
  r.ImGui_PopStyleColor(ctx, 6)
  
  return open
end

-- Main loop
function Main()
  local open = true
  
  -- Draw toolbar
  open = DrawToolbar()
  
  -- Handle settings dialog
  if settings_open then
    ShowSettingsDialog()
  end
  
  if open then
    r.defer(Main)
  end
end

-- Initialize
function Init()
  LoadConfig()
  
  -- Initialize variables
  settings_open = false
  
  -- Start main loop
  Main()
end

-- Script entry point
local _, _, section_id, command_id = r.get_action_context()
r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

function Exit()
  r.SetToggleCommandState(section_id, command_id, 0)
  r.RefreshToolbar2(section_id, command_id)
  
  SaveConfig()
  icon_manager:cleanup()
end

r.atexit(Exit)
Init()