--[[
 * ReaScript Name: CP_ImGuiStyleManager
 * Description: Global style manager for ReaImGui interfaces
 * Author: Claude
 * Version: 1.2
 * Provides: [main=main,imgui_v18,extension] .
--]]

local r = reaper
local extstate_id = "CP_ImGuiStyles"
local ctx = r.ImGui_CreateContext('ImGui Style Manager')
local dock_id = 0

-- Deep clone function for copying tables
function deepcopy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[deepcopy(orig_key)] = deepcopy(orig_value)
    end
    setmetatable(copy, deepcopy(getmetatable(orig)))
  else
    copy = orig
  end
  return copy
end

-- Add serialization function if not available
if not r.serialize then
  function r.serialize(tbl)
    local function serialize_value(value)
      local vtype = type(value)
      if vtype == "string" then
        return string.format("%q", value)
      elseif vtype == "number" or vtype == "boolean" then
        return tostring(value)
      elseif vtype == "table" then
        return r.serialize(value)
      else
        return "nil"
      end
    end
    
    local result = "{"
    local comma = false
    
    -- Handle array-like tables first
    local isArray = true
    local maxIndex = 0
    for k, v in pairs(tbl) do
      if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
        isArray = false
        break
      end
      maxIndex = math.max(maxIndex, k)
    end
    
    if isArray and maxIndex > 0 then
      for i = 1, maxIndex do
        if comma then result = result .. "," end
        result = result .. serialize_value(tbl[i])
        comma = true
      end
    else
      -- Handle normal tables with mixed keys
      for k, v in pairs(tbl) do
        if comma then result = result .. "," end
        
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          result = result .. k .. "="
        else
          result = result .. "[" .. serialize_value(k) .. "]="
        end
        
        result = result .. serialize_value(v)
        comma = true
      end
    end
    
    return result .. "}"
  end
end

-- Style properties
local styles = {
  fonts = {
    main = {name = "sans-serif", size = 16},
    header = {name = "sans-serif", size = 20},
    mono = {name = "monospace", size = 14}
  },
  colors = {
    window_bg = 0x252525FF,
    text = 0xDCDCDCFF,
    text_disabled = 0x888888FF,
    border = 0x333333FF,
    border_shadow = 0x000000FF,
    
    -- Button colors
    button = 0x3D3D3DFF,
    button_hovered = 0x4B4B4BFF,
    button_active = 0x666666FF,
    
    -- Headers
    header = 0x333333FF,
    header_hovered = 0x444444FF,
    header_active = 0x555555FF,
    
    -- Checkboxes, sliders, etc.
    frame_bg = 0x262626FF,
    frame_bg_hovered = 0x333333FF,
    frame_bg_active = 0x444444FF,
    
    -- Tabs
    tab = 0x333333FF,
    tab_hovered = 0x444444FF,
    tab_active = 0x555555FF,
    tab_unfocused = 0x222222FF,
    
    -- Title bar
    title_bg = 0x222222FF,
    title_bg_active = 0x333333FF,
    title_bg_collapsed = 0x111111FF,
    
    -- Tables
    table_header_bg = 0x333333FF,
    table_row_bg = 0x262626FF,
    table_row_bg_alt = 0x303030FF,
    
    -- Popups
    popup_bg = 0x232323FF,
    
    -- Scrollbar
    scrollbar_bg = 0x151515FF,
    scrollbar_grab = 0x555555FF,
    scrollbar_grab_hovered = 0x777777FF,
    scrollbar_grab_active = 0x999999FF,
    
    -- Modal window
    modal_window_dim_bg = 0x33333377,
    
    -- Accents
    accent_color = 0x1E90FFFF,
    accent_color_hovered = 0x3AA0FFFF,
    accent_color_active = 0x5BAAFDFF,
    
    -- Specials
    nav_highlight = 0x7373DAFF,
    drag_drop_target = 0xFFFF00FF,
    plot_lines = 0xB0B0B0FF,
    plot_histogram = 0xE0E0E0FF,
    
    separator = 0x444444FF
  },
  
  spacing = {
    item_spacing_x = 8,
    item_spacing_y = 4,
    inner_spacing_x = 4,
    inner_spacing_y = 4,
    frame_padding_x = 8,
    frame_padding_y = 4,
    window_padding_x = 8,
    window_padding_y = 8,
    cell_padding_x = 4,
    cell_padding_y = 2,
    indent_spacing = 20,
    scrollbar_size = 14
  },
  
  borders = {
    window_border_size = 1,
    child_border_size = 1,
    popup_border_size = 1,
    frame_border_size = 1,
    tab_border_size = 1
  },
  
  rounding = {
    window_rounding = 0,
    child_rounding = 0,
    frame_rounding = 0,
    popup_rounding = 0,
    scrollbar_rounding = 0,
    grab_rounding = 0,
    tab_rounding = 0
  },
  
  extras = {
    alpha = 1.0,
    disable_alpha = false,
    antialiased_lines = true,
    antialiased_fill = true,
    curve_tessellation_tolerance = 1.25,
    circle_tessellation_max_error = 0.30
  }
}

-- Font objects (loaded at runtime)
local font_objects = {
  main = nil,
  header = nil,
  mono = nil
}

-- Preset themes
local themes = {
  {
    name = "Default Dark",
    styles = deepcopy(styles) -- Will copy the default styles
  },
  {
    name = "Light Theme",
    styles = {
      -- Light theme colors
      colors = {
        window_bg = 0xF0F0F0FF,
        text = 0x111111FF,
        text_disabled = 0x888888FF,
        border = 0xDDDDDDFF,
        border_shadow = 0xAAAAAAFF,
        button = 0xDDDDDDFF,
        button_hovered = 0xCCCCCCFF,
        button_active = 0xBBBBBBFF,
        header = 0xEEEEEEFF,
        header_hovered = 0xDDDDDDFF,
        header_active = 0xCCCCCCFF,
        frame_bg = 0xE9E9E9FF,
        frame_bg_hovered = 0xDDDDDDFF,
        frame_bg_active = 0xCCCCCCFF,
        tab = 0xE0E0E0FF,
        tab_hovered = 0xD0D0D0FF,
        tab_active = 0xF0F0F0FF,
        tab_unfocused = 0xEAEAEAFF,
        title_bg = 0xE0E0E0FF,
        title_bg_active = 0xD0D0D0FF,
        title_bg_collapsed = 0xF5F5F5FF,
        table_header_bg = 0xE0E0E0FF,
        table_row_bg = 0xFFFFFFFF,
        table_row_bg_alt = 0xF5F5F5FF,
        popup_bg = 0xFFFFFFFF,
        scrollbar_bg = 0xEEEEEEFF,
        scrollbar_grab = 0xCCCCCCFF,
        scrollbar_grab_hovered = 0xBBBBBBFF,
        scrollbar_grab_active = 0xAAAAAAFF,
        modal_window_dim_bg = 0x77777777,
        accent_color = 0x3F85CDFF,
        accent_color_hovered = 0x5B91D0FF,
        accent_color_active = 0x77A3E0FF,
        nav_highlight = 0x7373DAFF,
        drag_drop_target = 0xFFAA00FF,
        plot_lines = 0x444444FF,
        plot_histogram = 0x333333FF,
        separator = 0xDDDDDDFF
      },
      -- Keep other default values
      fonts = deepcopy(styles.fonts),
      spacing = deepcopy(styles.spacing),
      borders = deepcopy(styles.borders),
      rounding = deepcopy(styles.rounding),
      extras = deepcopy(styles.extras)
    }
  },
  {
    name = "Modern Dark",
    styles = {
      -- Modern dark theme colors
      colors = {
        window_bg = 0x1A1A1AFF,
        text = 0xEAEAEAFF,
        text_disabled = 0x666666FF,
        border = 0x444444FF,
        border_shadow = 0x000000FF,
        button = 0x2A2A2AFF,
        button_hovered = 0x3A3A3AFF,
        button_active = 0x4A4A4AFF,
        header = 0x222222FF,
        header_hovered = 0x333333FF,
        header_active = 0x444444FF,
        frame_bg = 0x2A2A2AFF,
        frame_bg_hovered = 0x3A3A3AFF,
        frame_bg_active = 0x4A4A4AFF,
        tab = 0x222222FF,
        tab_hovered = 0x333333FF,
        tab_active = 0x444444FF,
        tab_unfocused = 0x1D1D1DFF,
        title_bg = 0x111111FF,
        title_bg_active = 0x222222FF,
        title_bg_collapsed = 0x0A0A0AFF,
        table_header_bg = 0x222222FF,
        table_row_bg = 0x1A1A1AFF,
        table_row_bg_alt = 0x232323FF,
        popup_bg = 0x1A1A1AFF,
        scrollbar_bg = 0x0F0F0FFF,
        scrollbar_grab = 0x444444FF,
        scrollbar_grab_hovered = 0x555555FF,
        scrollbar_grab_active = 0x666666FF,
        modal_window_dim_bg = 0x22222277,
        accent_color = 0x6A64F4FF, -- Purple-blue accent
        accent_color_hovered = 0x8A84FFFF,
        accent_color_active = 0xAA9CFFFF,
        nav_highlight = 0x6A64F4FF,
        drag_drop_target = 0xFFC107FF, -- Amber drop target
        plot_lines = 0xB0B0B0FF,
        plot_histogram = 0xE0E0E0FF,
        separator = 0x444444FF
      },
      -- Use more rounded corners
      rounding = {
        window_rounding = 6,
        child_rounding = 4,
        frame_rounding = 4,
        popup_rounding = 4,
        scrollbar_rounding = 4,
        grab_rounding = 4,
        tab_rounding = 4
      },
      -- Other defaults
      fonts = deepcopy(styles.fonts),
      spacing = deepcopy(styles.spacing),
      borders = deepcopy(styles.borders),
      extras = deepcopy(styles.extras)
    }
  },
  {
    name = "Retro Green",
    styles = {
      -- Retro terminal-like theme
      colors = {
        window_bg = 0x0D1117FF,
        text = 0x4AFF3AFF, -- Green text
        text_disabled = 0x2A8A2AFF,
        border = 0x2A3F17FF,
        border_shadow = 0x000000FF,
        button = 0x142211FF,
        button_hovered = 0x1F3319FF,
        button_active = 0x2A4422FF,
        header = 0x0F1A0FFF,
        header_hovered = 0x1A2A1AFF,
        header_active = 0x254425FF,
        frame_bg = 0x111A11FF,
        frame_bg_hovered = 0x1A2A1AFF,
        frame_bg_active = 0x254425FF,
        tab = 0x111A11FF,
        tab_hovered = 0x1A2A1AFF,
        tab_active = 0x254425FF,
        tab_unfocused = 0x0A140AFF,
        title_bg = 0x0A140AFF,
        title_bg_active = 0x111A11FF,
        title_bg_collapsed = 0x070F07FF,
        table_header_bg = 0x111A11FF,
        table_row_bg = 0x0D1117FF,
        table_row_bg_alt = 0x0F141CFF,
        popup_bg = 0x0D1117FF,
        scrollbar_bg = 0x070F07FF,
        scrollbar_grab = 0x1A2A1AFF,
        scrollbar_grab_hovered = 0x254425FF,
        scrollbar_grab_active = 0x305530FF,
        modal_window_dim_bg = 0x0A0A0A77,
        accent_color = 0x4AFF3AFF, -- Green accent
        accent_color_hovered = 0x5AFF4AFF,
        accent_color_active = 0x6AFF5AFF,
        nav_highlight = 0x4AFF3AFF,
        drag_drop_target = 0xFFFF00FF, -- Yellow highlight
        plot_lines = 0x4AFF3AFF,
        plot_histogram = 0x5AFF4AFF,
        separator = 0x254425FF
      },
      fonts = {
        main = {name = "monospace", size = 14},
        header = {name = "monospace", size = 16},
        mono = {name = "monospace", size = 14}
      },
      spacing = deepcopy(styles.spacing),
      borders = deepcopy(styles.borders),
      rounding = {
        window_rounding = 0,
        child_rounding = 0,
        frame_rounding = 0,
        popup_rounding = 0,
        scrollbar_rounding = 0,
        grab_rounding = 0,
        tab_rounding = 0
      },
      extras = deepcopy(styles.extras)
    }
  }
}

-- Preview panel content
local preview_content = {
  active_tab = 0,
  checkbox_state = true,
  radio_state = 0,
  slider_value = 50,
  combo_selected = 0,
  input_text = "Sample text",
  multiline_text = "This is a\nmultiline\ntext input."
}

-- Initialize variables
local initialized = false
local font_update_pending = false
local theme_name_input = "My Custom Theme"
local debug_info = ""

-- Helper functions
-- Show hex color editor (simplified version for maximum compatibility)
function ShowColorEditor(label, color_var, color_path)
  local r_val = (color_var >> 24) & 0xFF
  local g_val = (color_var >> 16) & 0xFF
  local b_val = (color_var >> 8) & 0xFF
  local a_val = color_var & 0xFF
  
  -- Pack RGB into a single integer value (0xXXRRGGBB format for ImGui_ColorEdit3)
  local rgb_val = (r_val << 16) | (g_val << 8) | b_val
  
  -- Use ImGui_ColorEdit3 with the correct argument count
  local changed, new_rgb = r.ImGui_ColorEdit3(ctx, label, rgb_val)
  
  if changed then
    -- Extract new RGB components
    local new_r_val = (new_rgb >> 16) & 0xFF
    local new_g_val = (new_rgb >> 8) & 0xFF
    local new_b_val = new_rgb & 0xFF
    
    -- Construct new color with original alpha
    local new_color = (new_r_val << 24) | (new_g_val << 16) | (new_b_val << 8) | a_val
    
    -- Set the value
    local path_parts = {}
    for part in color_path:gmatch("[^%.]+") do
      table.insert(path_parts, part)
    end
    
    local current = styles
    for i = 1, #path_parts - 1 do
      current = current[path_parts[i]]
    end
    current[path_parts[#path_parts]] = new_color
    
    return new_color
  end
  
  return color_var
end

-- Function to apply styles to current context (for live preview)
function applyStylesInteractive()
  local pushed_colors = 0
  local pushed_vars = 0

  -- Apply colors to current context
  if styles.colors then
    -- Only use colors that have corresponding ImGui constants
    -- Main colors
    if r.ImGui_Col_WindowBg then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), styles.colors.window_bg)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_Text then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), styles.colors.text)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_Border then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), styles.colors.border)
      pushed_colors = pushed_colors + 1
    end
    
    -- Button colors
    if r.ImGui_Col_Button then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), styles.colors.button)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_ButtonHovered then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), styles.colors.button_hovered)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_ButtonActive then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), styles.colors.button_active)
      pushed_colors = pushed_colors + 1
    end
    
    -- Header colors
    if r.ImGui_Col_Header then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), styles.colors.header)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_HeaderHovered then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), styles.colors.header_hovered)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_HeaderActive then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), styles.colors.header_active)
      pushed_colors = pushed_colors + 1
    end
    
    -- Frame colors
    if r.ImGui_Col_FrameBg then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), styles.colors.frame_bg)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_FrameBgHovered then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), styles.colors.frame_bg_hovered)
      pushed_colors = pushed_colors + 1
    end
    
    if r.ImGui_Col_FrameBgActive then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), styles.colors.frame_bg_active)
      pushed_colors = pushed_colors + 1
    end
    
    -- Separator
    if r.ImGui_Col_Separator then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Separator(), styles.colors.separator)
      pushed_colors = pushed_colors + 1
    end
  end
  
  -- Apply spacings
  if styles.spacing then
    if r.ImGui_StyleVar_ItemSpacing then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), styles.spacing.item_spacing_x, styles.spacing.item_spacing_y)
      pushed_vars = pushed_vars + 1
    end
    
    if r.ImGui_StyleVar_FramePadding then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), styles.spacing.frame_padding_x, styles.spacing.frame_padding_y)
      pushed_vars = pushed_vars + 1
    end
    
    if r.ImGui_StyleVar_WindowPadding then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), styles.spacing.window_padding_x, styles.spacing.window_padding_y)
      pushed_vars = pushed_vars + 1
    end
  end
  
  -- Apply rounding
  if styles.rounding then
    if r.ImGui_StyleVar_WindowRounding then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), styles.rounding.window_rounding)
      pushed_vars = pushed_vars + 1
    end
    
    if r.ImGui_StyleVar_FrameRounding then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), styles.rounding.frame_rounding)
      pushed_vars = pushed_vars + 1
    end
  end
  
  -- Apply borders
  if styles.borders then
    if r.ImGui_StyleVar_WindowBorderSize then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), styles.borders.window_border_size)
      pushed_vars = pushed_vars + 1
    end
    
    if r.ImGui_StyleVar_FrameBorderSize then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), styles.borders.frame_border_size)
      pushed_vars = pushed_vars + 1
    end
  end
  
  -- Return the number of pushed styles for popping later
  return pushed_colors, pushed_vars
end

-- Function to pop all styles (for cleanup)
function popStyles(pushed_colors, pushed_vars)
  if pushed_colors > 0 then
    r.ImGui_PopStyleColor(ctx, pushed_colors)
  end
  
  if pushed_vars > 0 then
    r.ImGui_PopStyleVar(ctx, pushed_vars)
  end
end

-- Show the preview panel
function ShowPreviewPanel()
  r.ImGui_Text(ctx, "Preview")
  r.ImGui_Separator(ctx)
  
  -- Show tabs in preview - check if the function exists first
  if r.ImGui_BeginTabBar then
    if r.ImGui_BeginTabBar(ctx, "PreviewTabs") then
      if r.ImGui_BeginTabItem(ctx, "Controls") then
        -- Buttons with compatibility for different ImGui versions
        r.ImGui_Text(ctx, "Buttons:")
        -- Try different versions of the button API
        local success = pcall(function()
          r.ImGui_Button(ctx, "Click Me", 0, 0)
        end)
        if not success then
          r.ImGui_Button(ctx, "Click Me")
        end
        
        r.ImGui_SameLine(ctx)
        
        -- Try small button
        pcall(function()
          r.ImGui_SmallButton(ctx, "Small")
        end)
        
        -- Text
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Regular text")
        r.ImGui_TextDisabled(ctx, "Disabled text")
        r.ImGui_TextColored(ctx, 0xFF4444FF, "Colored text")
        
        -- Checkbox & Radio (if available)
        r.ImGui_Spacing(ctx)
        pcall(function()
          local chg, new_state = r.ImGui_Checkbox(ctx, "Checkbox", preview_content.checkbox_state)
          if chg then preview_content.checkbox_state = new_state end
        end)
        
        -- Slider (if available)
        r.ImGui_Spacing(ctx)
        pcall(function()
          local chg, new_val = r.ImGui_SliderInt(ctx, "Slider", preview_content.slider_value, 0, 100)
          if chg then preview_content.slider_value = new_val end
        end)
        
        -- Combo (if available)
        r.ImGui_Spacing(ctx)
        pcall(function()
          if r.ImGui_BeginCombo(ctx, "Combo", "Item " .. preview_content.combo_selected) then
            for i = 0, 4 do
              if r.ImGui_Selectable(ctx, "Item " .. i, preview_content.combo_selected == i) then
                preview_content.combo_selected = i
              end
            end
            r.ImGui_EndCombo(ctx)
          end
        end)
        
        -- Input text (if available)
        r.ImGui_Spacing(ctx)
        pcall(function()
          local chg, new_text = r.ImGui_InputText(ctx, "Input", preview_content.input_text)
          if chg then preview_content.input_text = new_text end
        end)
        
        r.ImGui_EndTabItem(ctx)
      end
      
      -- Try other tabs
      pcall(function()
        if r.ImGui_BeginTabItem(ctx, "Layout") then
          -- Child windows
          if r.ImGui_BeginChild then
            if r.ImGui_BeginChild(ctx, "child1", 180, 80) then
              r.ImGui_Text(ctx, "Child window content")
              r.ImGui_EndChild(ctx)
            end
          end
          
          -- Collapsing headers
          if r.ImGui_CollapsingHeader then
            if r.ImGui_CollapsingHeader(ctx, "Collapsing header") then
              r.ImGui_Text(ctx, "Content inside header")
            end
          end
          
          r.ImGui_EndTabItem(ctx)
        end
      end)
      
      r.ImGui_EndTabBar(ctx)
    end
  else
    -- Fallback if tabs aren't available
    r.ImGui_Text(ctx, "Basic controls")
    r.ImGui_Separator(ctx)

    -- Show some basic controls
    r.ImGui_Button(ctx, "Button")
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Text")
  end
end

-- Function to update fonts safely
function updateFonts()
  -- Destroy old fonts if they exist
  font_objects = {
    main = nil,
    header = nil,
    mono = nil
  }
  
  -- Create fonts
  font_objects.main = r.ImGui_CreateFont(styles.fonts.main.name, styles.fonts.main.size)
  font_objects.header = r.ImGui_CreateFont(styles.fonts.header.name, styles.fonts.header.size)
  font_objects.mono = r.ImGui_CreateFont(styles.fonts.mono.name, styles.fonts.mono.size)
  
  -- Attach fonts
  r.ImGui_Attach(ctx, font_objects.main)
  r.ImGui_Attach(ctx, font_objects.header)
  r.ImGui_Attach(ctx, font_objects.mono)
  
  font_update_pending = false
  
  -- Force a refresh of the window
  r.ImGui_SetNextWindowPos(ctx, 200, 200, r.ImGui_Cond_FirstUseEver())
end

-- Save styles to REAPER's ExtState
function SaveStyles()
  -- Convert table to string
  local serialized = r.serialize(styles)
  r.SetExtState(extstate_id, "styles", serialized, true)
  
  -- Save dock state
  r.SetExtState(extstate_id, "dock", tostring(dock_id), true)
  
  -- Add debugging info
  debug_info = "Settings saved"
end

-- Load styles from REAPER's ExtState
function LoadStyles()
  local saved = r.GetExtState(extstate_id, "styles")
  if saved and saved ~= "" then
    local success, loaded = pcall(function() return load("return " .. saved)() end)
    if success and loaded then
      -- Merge loaded styles with defaults to ensure all properties exist
      for category, values in pairs(loaded) do
        if styles[category] then
          for key, value in pairs(values) do
            styles[category][key] = value
          end
        end
      end
    end
  end
  
  -- Load dock state
  local saved_dock = r.GetExtState(extstate_id, "dock")
  if saved_dock and saved_dock ~= "" then
    dock_id = tonumber(saved_dock) or 0
  end
end

-- Apply a theme
function ApplyTheme(theme_idx)
  if themes[theme_idx] and themes[theme_idx].styles then
    styles = deepcopy(themes[theme_idx].styles)
    font_update_pending = true
    SaveStyles()
  end
end

-- Initialize function
function init()
  LoadStyles()
  
  -- Create and attach fonts
  updateFonts()
  
  -- Signal that we're ready
  initialized = true
end

-- Main loop function
function loop()
  -- Check if we need to update fonts (do this before starting any ImGui frame)
  if font_update_pending then
    updateFonts()
  end
  
  -- Set dock ID if needed
  if dock_id ~= 0 then
    pcall(function()
      r.ImGui_SetNextWindowDockID(ctx, dock_id)
    end)
  end
  
  -- Apply current styles for interactive preview
  local pushed_colors, pushed_vars = applyStylesInteractive()
  
  local window_flags = r.ImGui_WindowFlags_None()
  local visible, open = r.ImGui_Begin(ctx, 'ImGui Style Manager', true, window_flags)
  
  -- Track dock state changes
  pcall(function()
    local new_dock_id = r.ImGui_GetWindowDockID(ctx)
    if new_dock_id ~= dock_id then
      dock_id = new_dock_id
      r.SetExtState(extstate_id, "dock", tostring(dock_id), true)
    end
  end)
  
  if visible then
    -- Apply the main font globally
    if font_objects.main then
      r.ImGui_PushFont(ctx, font_objects.main)
    end
    
    if font_objects.header then
      r.ImGui_PushFont(ctx, font_objects.header)
      r.ImGui_Text(ctx, "Global ImGui Style Manager")
      r.ImGui_PopFont(ctx)
    else
      r.ImGui_Text(ctx, "Global ImGui Style Manager")
    end
    
    r.ImGui_Separator(ctx)
    
    -- Debugging info
    if debug_info ~= "" then
      r.ImGui_TextColored(ctx, 0x00FF00FF, debug_info)
      r.ImGui_Spacing(ctx)
    end
    
    -- Check if tab bar is available
    local has_tab_bar = pcall(function() return r.ImGui_BeginTabBar(ctx, "StyleTabs") end)
    
    if has_tab_bar then
      -- THEMES TAB
      if r.ImGui_BeginTabItem(ctx, "Themes") then
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Choose a preset theme or create your own:")
        r.ImGui_Spacing(ctx)
        
        -- Theme selection with compatibility for different ImGui button versions
        for i, theme in ipairs(themes) do
          local clicked = false
          -- Try the button API with width/height
          local success = pcall(function()
            clicked = r.ImGui_Button(ctx, theme.name, 200, 30)
          end)
          -- If that failed, try the simpler version
          if not success then
            clicked = r.ImGui_Button(ctx, theme.name)
          end
          
          if clicked then
            ApplyTheme(i)
          end
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Save current theme functionality
        r.ImGui_Text(ctx, "Save current style as custom theme:")
        local rv, new_name = r.ImGui_InputText(ctx, "Theme Name", theme_name_input)
        if rv then theme_name_input = new_name end
        
        local save_clicked = false
        pcall(function() save_clicked = r.ImGui_Button(ctx, "Save Current Theme", 200, 30) end)
        if not save_clicked then 
          save_clicked = r.ImGui_Button(ctx, "Save Current Theme") 
        end
        if save_clicked then
          local name = theme_name_input
          if name and name ~= "" then
            -- Add to themes list
            table.insert(themes, {
              name = name,
              styles = deepcopy(styles)
            })
            
            -- Clear the input
            theme_name_input = ""
          end
        end
        
        r.ImGui_EndTabItem(ctx)
      end
      
      -- COLORS TAB
      if r.ImGui_BeginTabItem(ctx, "Colors") then
        local window_width = r.ImGui_GetContentRegionAvail(ctx)
        
        -- Main colors
        r.ImGui_Text(ctx, "Main Colors")
        r.ImGui_Separator(ctx)
        
        styles.colors.window_bg = ShowColorEditor("Window Background", styles.colors.window_bg, "colors.window_bg")
        styles.colors.text = ShowColorEditor("Text", styles.colors.text, "colors.text")
        styles.colors.border = ShowColorEditor("Border", styles.colors.border, "colors.border")
        
        -- Button colors
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Button Colors")
        r.ImGui_Separator(ctx)
        
        styles.colors.button = ShowColorEditor("Button", styles.colors.button, "colors.button")
        styles.colors.button_hovered = ShowColorEditor("Button Hovered", styles.colors.button_hovered, "colors.button_hovered")
        styles.colors.button_active = ShowColorEditor("Button Active", styles.colors.button_active, "colors.button_active")
        
        -- Frame colors 
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Frames")
        r.ImGui_Separator(ctx)
        
        styles.colors.frame_bg = ShowColorEditor("Frame Background", styles.colors.frame_bg, "colors.frame_bg")
        styles.colors.frame_bg_hovered = ShowColorEditor("Frame BG Hovered", styles.colors.frame_bg_hovered, "colors.frame_bg_hovered")
        styles.colors.frame_bg_active = ShowColorEditor("Frame BG Active", styles.colors.frame_bg_active, "colors.frame_bg_active")
        
        -- Special colors
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Special")
        r.ImGui_Separator(ctx)
        
        styles.colors.separator = ShowColorEditor("Separator", styles.colors.separator, "colors.separator")
        
        r.ImGui_EndTabItem(ctx)
      end
      
      -- FONTS TAB
      if r.ImGui_BeginTabItem(ctx, "Fonts") then
        r.ImGui_Spacing(ctx)
        
        -- Main font
        r.ImGui_Text(ctx, "Main Font")
        if r.ImGui_BeginCombo(ctx, "Main Font Family", styles.fonts.main.name) then
          for _, fontname in ipairs({"sans-serif", "serif", "monospace", "Arial", "Verdana", "Times New Roman", "Courier New"}) do
            if r.ImGui_Selectable(ctx, fontname, styles.fonts.main.name == fontname) then
              styles.fonts.main.name = fontname
              font_update_pending = true
              SaveStyles()
            end
          end
          r.ImGui_EndCombo(ctx)
        end
        
        local changed, new_size = r.ImGui_SliderInt(ctx, "Main Font Size", styles.fonts.main.size, 8, 32)
        if changed then
          styles.fonts.main.size = new_size
          font_update_pending = true
          SaveStyles()
        end
        
        r.ImGui_Spacing(ctx)
        
        -- Header font
        r.ImGui_Text(ctx, "Header Font")
        if r.ImGui_BeginCombo(ctx, "Header Font Family", styles.fonts.header.name) then
          for _, fontname in ipairs({"sans-serif", "serif", "monospace", "Arial", "Verdana", "Times New Roman", "Courier New"}) do
            if r.ImGui_Selectable(ctx, fontname, styles.fonts.header.name == fontname) then
              styles.fonts.header.name = fontname
              font_update_pending = true
              SaveStyles()
            end
          end
          r.ImGui_EndCombo(ctx)
        end
        
        changed, new_size = r.ImGui_SliderInt(ctx, "Header Font Size", styles.fonts.header.size, 8, 32)
        if changed then
          styles.fonts.header.size = new_size
          font_update_pending = true
          SaveStyles()
        end
        
        r.ImGui_Spacing(ctx)
        
        -- Mono font
        r.ImGui_Text(ctx, "Monospace Font")
        if r.ImGui_BeginCombo(ctx, "Mono Font Family", styles.fonts.mono.name) then
          for _, fontname in ipairs({"monospace", "Consolas", "Courier New", "Lucida Console"}) do
            if r.ImGui_Selectable(ctx, fontname, styles.fonts.mono.name == fontname) then
              styles.fonts.mono.name = fontname
              font_update_pending = true
              SaveStyles()
            end
          end
          r.ImGui_EndCombo(ctx)
        end
        
        changed, new_size = r.ImGui_SliderInt(ctx, "Mono Font Size", styles.fonts.mono.size, 8, 32)
        if changed then
          styles.fonts.mono.size = new_size
          font_update_pending = true
          SaveStyles()
        end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Apply/Update button
        if r.ImGui_Button(ctx, "Apply Font Changes Now") then
          updateFonts()
          SaveStyles()
          debug_info = "Fonts updated and applied"
        end
        
        -- Font samples
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Text(ctx, "Font Samples:")
        r.ImGui_Spacing(ctx)
        
        if font_objects.main then
          r.ImGui_PushFont(ctx, font_objects.main)
          r.ImGui_Text(ctx, "Main font sample text - " .. styles.fonts.main.name)
          r.ImGui_PopFont(ctx)
        else
          r.ImGui_Text(ctx, "Main font not available")
        end
        
        if font_objects.header then
          r.ImGui_PushFont(ctx, font_objects.header)
          r.ImGui_Text(ctx, "Header font sample - " .. styles.fonts.header.name)
          r.ImGui_PopFont(ctx)
        else
          r.ImGui_Text(ctx, "Header font not available")
        end
        
        if font_objects.mono then
          r.ImGui_PushFont(ctx, font_objects.mono)
          r.ImGui_Text(ctx, "Monospace font sample - " .. styles.fonts.mono.name)
          r.ImGui_PopFont(ctx)
        else
          r.ImGui_Text(ctx, "Mono font not available")
        end
        
        r.ImGui_EndTabItem(ctx)
      end
      
      -- SPACING & LAYOUT TAB
      if r.ImGui_BeginTabItem(ctx, "Layout") then
        local window_width = r.ImGui_GetContentRegionAvail(ctx)
        
        r.ImGui_Text(ctx, "Spacing")
        r.ImGui_Separator(ctx)
        
        local chg, new_val
        
        -- Item spacing
        chg, new_val = r.ImGui_SliderInt(ctx, "Item Spacing X", styles.spacing.item_spacing_x, 0, 20)
        if chg then styles.spacing.item_spacing_x = new_val end
        
        chg, new_val = r.ImGui_SliderInt(ctx, "Item Spacing Y", styles.spacing.item_spacing_y, 0, 20)
        if chg then styles.spacing.item_spacing_y = new_val end
        
        -- Frame padding
        chg, new_val = r.ImGui_SliderInt(ctx, "Frame Padding X", styles.spacing.frame_padding_x, 0, 20)
        if chg then styles.spacing.frame_padding_x = new_val end
        
        chg, new_val = r.ImGui_SliderInt(ctx, "Frame Padding Y", styles.spacing.frame_padding_y, 0, 20)
        if chg then styles.spacing.frame_padding_y = new_val end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        r.ImGui_Text(ctx, "Borders")
        r.ImGui_Separator(ctx)
        
        -- Border sizes
        chg, new_val = r.ImGui_SliderInt(ctx, "Window Border", styles.borders.window_border_size, 0, 3)
        if chg then styles.borders.window_border_size = new_val end
        
        chg, new_val = r.ImGui_SliderInt(ctx, "Frame Border", styles.borders.frame_border_size, 0, 3)
        if chg then styles.borders.frame_border_size = new_val end
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        r.ImGui_Text(ctx, "Rounding")
        r.ImGui_Separator(ctx)
        
        -- Rounding
        chg, new_val = r.ImGui_SliderInt(ctx, "Window Rounding", styles.rounding.window_rounding, 0, 12)
        if chg then styles.rounding.window_rounding = new_val end
        
        chg, new_val = r.ImGui_SliderInt(ctx, "Frame Rounding", styles.rounding.frame_rounding, 0, 12)
        if chg then styles.rounding.frame_rounding = new_val end
        
        r.ImGui_EndTabItem(ctx)
      end
      
      -- PREVIEW TAB
      if r.ImGui_BeginTabItem(ctx, "Preview") then
        r.ImGui_Spacing(ctx)
        
        -- Show a preview of UI elements with current style
        ShowPreviewPanel()
        
        r.ImGui_EndTabItem(ctx)
      end
      
      -- EXPORT TAB
      if r.ImGui_BeginTabItem(ctx, "Export") then
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Export/Import Settings")
        r.ImGui_Separator(ctx)
        
        -- Save & Load buttons
        local save_clicked = false
        pcall(function() save_clicked = r.ImGui_Button(ctx, "Save Current Settings", 200, 30) end)
        if not save_clicked then 
          save_clicked = r.ImGui_Button(ctx, "Save Current Settings") 
        end
        if save_clicked then
          SaveStyles()
          debug_info = "Settings saved successfully"
        end
        
        -- Reset to defaults
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        local reset_clicked = false
        pcall(function() reset_clicked = r.ImGui_Button(ctx, "Reset to Defaults", 200, 30) end)
        if not reset_clicked then 
          reset_clicked = r.ImGui_Button(ctx, "Reset to Defaults") 
        end
        if reset_clicked then
          ApplyTheme(1) -- Reset to first theme (Default Dark)
          debug_info = "Reset to default theme"
        end
        
        r.ImGui_EndTabItem(ctx)
      end
      
      -- HELP TAB
      if r.ImGui_BeginTabItem(ctx, "Help") then
        r.ImGui_PushFont(ctx, font_objects.header)
        r.ImGui_Text(ctx, "ImGui Style Manager Help")
        r.ImGui_PopFont(ctx)
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        r.ImGui_Text(ctx, "This tool allows you to customize the appearance of all your ImGui-based scripts.")
        r.ImGui_Text(ctx, "The settings are saved globally and can be used by other scripts that use the style loader.")
        
        r.ImGui_Spacing(ctx)
        
        r.ImGui_Text(ctx, "Tip: Use the Preview tab to see how your styles will look in actual scripts.")
        
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        r.ImGui_TextColored(ctx, 0xFFFF00FF, "Troubleshooting:")
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "If you don't see font changes in the interface, try clicking 'Apply Font Changes Now'")
        r.ImGui_Text(ctx, "in the Fonts tab. You may need to restart the script after making changes.")
        
        r.ImGui_EndTabItem(ctx)
      end
      
      r.ImGui_EndTabBar(ctx)
    else
      -- Fallback if tab bar isn't available
      r.ImGui_Text(ctx, "Theme Selection")
      r.ImGui_Separator(ctx)
      
      for i, theme in ipairs(themes) do
        if r.ImGui_Button(ctx, theme.name) then
          ApplyTheme(i)
        end
      end
      
      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      
      r.ImGui_Text(ctx, "Basic Color Settings")
      
      styles.colors.window_bg = ShowColorEditor("Window Background", styles.colors.window_bg, "colors.window_bg")
      styles.colors.text = ShowColorEditor("Text", styles.colors.text, "colors.text")
      styles.colors.button = ShowColorEditor("Button", styles.colors.button, "colors.button")
    end
    
    -- Pop the main font if used
    if font_objects.main then
      r.ImGui_PopFont(ctx)
    end
    
    r.ImGui_End(ctx)
  end
  
  -- Pop all styles we applied for interactive preview
  popStyles(pushed_colors, pushed_vars)
  
  -- Keep looping if window is open
  if open then
    r.defer(loop)
  else
    -- Save settings before closing
    SaveStyles()
  end
end

-- Initialize and start the main loop
init()
loop()