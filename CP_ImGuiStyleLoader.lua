--[[
 * ReaScript Name: CP_ImGuiStyleLoader
 * Description: Loader for global ImGui styles
 * Author: Claude
 * Version: 1.2
--]]

-- Style loader module
local module = {}
local extstate_id = "CP_ImGuiStyles"

-- Load global styles from REAPER's ExtState and apply to given context
function module.applyToContext(ctx)
  local r = reaper
  
  if not ctx then
    return false, 0, 0
  end
  
  -- Validate context if possible
  local is_valid = true
  if r.ImGui_ValidatePtr then
    is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
  end
  
  if not is_valid then
    return false, 0, 0
  end
  
  -- Load style from ExtState
  local saved = r.GetExtState(extstate_id, "styles")
  if saved == "" then
    return false, 0, 0
  end
  
  -- Parse the style table
  local success, styles = pcall(function() return load("return " .. saved)() end)
  if not success or not styles then
    return false, 0, 0
  end
  
  -- Apply colors - count pushed styles for later cleanup
  local pushed_colors = 0
  
  if styles.colors then
    -- Check if ImGui color constants exist before using them
    
    -- Main colors
    pcall(function()
      if r.ImGui_Col_WindowBg then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), styles.colors.window_bg)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_Text then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), styles.colors.text)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_Border then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), styles.colors.border)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    -- Button colors
    pcall(function()
      if r.ImGui_Col_Button then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), styles.colors.button)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_ButtonHovered then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), styles.colors.button_hovered)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_ButtonActive then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), styles.colors.button_active)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    -- Header colors
    pcall(function()
      if r.ImGui_Col_Header then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), styles.colors.header)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_HeaderHovered then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), styles.colors.header_hovered)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_HeaderActive then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), styles.colors.header_active)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    -- Frame colors
    pcall(function()
      if r.ImGui_Col_FrameBg then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), styles.colors.frame_bg)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_FrameBgHovered then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), styles.colors.frame_bg_hovered)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    pcall(function()
      if r.ImGui_Col_FrameBgActive then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), styles.colors.frame_bg_active)
        pushed_colors = pushed_colors + 1
      end
    end)
    
    -- Separator
    pcall(function()
      if r.ImGui_Col_Separator then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Separator(), styles.colors.separator)
        pushed_colors = pushed_colors + 1
      end
    end)
  end
  
  -- Apply spacings - count pushed vars
  local pushed_vars = 0
  
  if styles.spacing then
    -- Item spacing
    pcall(function()
      if r.ImGui_StyleVar_ItemSpacing then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 
          styles.spacing.item_spacing_x, styles.spacing.item_spacing_y)
        pushed_vars = pushed_vars + 1
      end
    end)
    
    -- Frame padding
    pcall(function()
      if r.ImGui_StyleVar_FramePadding then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 
          styles.spacing.frame_padding_x, styles.spacing.frame_padding_y)
        pushed_vars = pushed_vars + 1
      end
    end)
    
    -- Window padding
    pcall(function()
      if r.ImGui_StyleVar_WindowPadding then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), 
          styles.spacing.window_padding_x, styles.spacing.window_padding_y)
        pushed_vars = pushed_vars + 1
      end
    end)
  end
  
  -- Apply rounding
  if styles.rounding then
    -- Window rounding
    pcall(function()
      if r.ImGui_StyleVar_WindowRounding then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), styles.rounding.window_rounding)
        pushed_vars = pushed_vars + 1
      end
    end)
    
    -- Frame rounding
    pcall(function()
      if r.ImGui_StyleVar_FrameRounding then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), styles.rounding.frame_rounding)
        pushed_vars = pushed_vars + 1
      end
    end)
  end
  
  -- Apply borders
  if styles.borders then
    -- Window border
    pcall(function()
      if r.ImGui_StyleVar_WindowBorderSize then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), styles.borders.window_border_size)
        pushed_vars = pushed_vars + 1
      end
    end)
    
    -- Frame border
    pcall(function()
      if r.ImGui_StyleVar_FrameBorderSize then
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), styles.borders.frame_border_size)
        pushed_vars = pushed_vars + 1
      end
    end)
  end
  
  -- Return success flag and counts of pushed styles for cleanup
  return true, pushed_colors, pushed_vars
end

-- Function to apply fonts from the global style settings
-- This should ONLY be called during script initialization, NOT during a frame
function module.applyFontsToContext(ctx)
    local r = reaper
    
    if not ctx then return false end
    
    -- Validate context
    local is_valid = true
    if r.ImGui_ValidatePtr then
      is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end
    
    if not is_valid then return false end
    
    -- Load style from ExtState
    local saved = r.GetExtState(extstate_id, "styles")
    if saved == "" then return false end
    
    -- Parse the style table
    local success, styles = pcall(function() return load("return " .. saved)() end)
    if not success or not styles or not styles.fonts then return false end
    
    -- Create and attach fonts
    local fonts = {}
    
    -- Create main font
    if styles.fonts.main and styles.fonts.main.name and styles.fonts.main.size then
      pcall(function()
        local font = r.ImGui_CreateFont(styles.fonts.main.name, styles.fonts.main.size)
        if font then
          r.ImGui_Attach(ctx, font)
          fonts.main = font
        end
      end)
    end
    
    -- Create header font
    if styles.fonts.header and styles.fonts.header.name and styles.fonts.header.size then
      pcall(function()
        local font = r.ImGui_CreateFont(styles.fonts.header.name, styles.fonts.header.size)
        if font then
          r.ImGui_Attach(ctx, font)
          fonts.header = font
        end
      end)
    end
    
    -- Create mono font
    if styles.fonts.mono and styles.fonts.mono.name and styles.fonts.mono.size then
      pcall(function()
        local font = r.ImGui_CreateFont(styles.fonts.mono.name, styles.fonts.mono.size)
        if font then
          r.ImGui_Attach(ctx, font)
          fonts.mono = font
        end
      end)
    end
    
    -- Store the fonts in a global table for future reference
    if not _G.CP_StyleManager_Fonts then
      _G.CP_StyleManager_Fonts = {}
    end
    
    _G.CP_StyleManager_Fonts[tostring(ctx)] = fonts
    
    return true
  end

-- Function to clean up styles when done
function module.clearStyles(ctx, pushed_colors, pushed_vars)
    local r = reaper
    
    if not ctx then return false end
    
    -- Vérifie si le contexte est valide de manière plus robuste
    local is_valid = false
    pcall(function()
        is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end)
    
    if not is_valid then return false end
    
    -- Pop style colors
    if pushed_colors and pushed_colors > 0 then
        pcall(function() r.ImGui_PopStyleColor(ctx, pushed_colors) end)
    end
    
    -- Pop style vars
    if pushed_vars and pushed_vars > 0 then
        pcall(function() r.ImGui_PopStyleVar(ctx, pushed_vars) end)
    end
    
    return true
end

-- Helper function to get a font by name for a specific context
function module.getFont(ctx, font_name)
  if not ctx or not font_name then return nil end
  
  if not _G.CP_StyleManager_Fonts then return nil end
  
  local ctx_fonts = _G.CP_StyleManager_Fonts[tostring(ctx)]
  if not ctx_fonts then return nil end
  
  return ctx_fonts[font_name]
end

-- Function to check if styles are available
function module.hasStyles()
  local r = reaper
  local saved = r.GetExtState(extstate_id, "styles")
  return saved ~= ""
end

-- Return the module
return function() 
  return module
end