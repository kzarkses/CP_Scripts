-- @description ImGuiStyleLoader
-- @version 1.1
-- @author Cedric Pamalio

local module = {}
local extstate_id = "CP_ImGuiStyles"

function module.ApplyToContext(ctx)
    local r = reaper

    if not ctx then
        return false, 0, 0
    end

    local is_valid = true
    if r.ImGui_ValidatePtr then
        is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end

    if not is_valid then
        return false, 0, 0
    end

    local saved = r.GetExtState(extstate_id, "styles")
    if saved == "" then
        return false, 0, 0
    end

    local success, styles = pcall(function() return load("return " .. saved)() end)
    if not success or not styles then
        return false, 0, 0
    end

    local pushed_colors = 0

    if styles.colors then
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

        pcall(function()
            if r.ImGui_Col_Separator then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Separator(), styles.colors.separator)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SliderGrab then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrab(), styles.colors.slider_grab)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SliderGrabActive then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrabActive(), styles.colors.slider_grab_active)
                pushed_colors = pushed_colors + 1
            end
        end)
        
        pcall(function()
            if r.ImGui_Col_CheckMark then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(), styles.colors.checkmark)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabSelected then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabSelected(), styles.colors.tab_active)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabHovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabHovered(), styles.colors.tab_hovered)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_Tab then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Tab(), styles.colors.tab)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabUnfocused then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabUnfocused(), styles.colors.tab_unfocused)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabUnfocusedActive then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabUnfocusedActive(), styles.colors.tab_unfocused_active)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SeparatorHovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SeparatorHovered(), styles.colors.separator_hovered)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TextSelectedBg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextSelectedBg(), styles.colors.text_selected_bg)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SeparatorActive then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SeparatorActive(), styles.colors.separator_active)
                pushed_colors = pushed_colors + 1
            end
        end)
        
        pcall(function()
            if r.ImGui_Col_ResizeGrip and styles.colors.resize_grip then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGrip(), styles.colors.resize_grip)
                pushed_colors = pushed_colors + 1
            end
        end)
        
        pcall(function()
            if r.ImGui_Col_ResizeGripHovered and styles.colors.resize_grip_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGripHovered(), styles.colors.resize_grip_hovered)
                pushed_colors = pushed_colors + 1
            end
        end)
        
        pcall(function()
            if r.ImGui_Col_ResizeGripActive and styles.colors.resize_grip_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGripActive(), styles.colors.resize_grip_active)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarBg and styles.colors.scrollbar_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarBg(), styles.colors.scrollbar_bg)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarGrab and styles.colors.scrollbar_grab then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrab(), styles.colors.scrollbar_grab)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarGrabHovered and styles.colors.scrollbar_grab_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrabHovered(), styles.colors.scrollbar_grab_hovered)
                pushed_colors = pushed_colors + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarGrabActive and styles.colors.scrollbar_grab_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrabActive(), styles.colors.scrollbar_grab_active)
                pushed_colors = pushed_colors + 1
            end
        end)
        

    end

    local pushed_vars = 0

    if styles.spacing then
        pcall(function()
            if r.ImGui_StyleVar_ItemSpacing then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(),
                    styles.spacing.item_spacing_x, styles.spacing.item_spacing_y)
                pushed_vars = pushed_vars + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_FramePadding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(),
                    styles.spacing.frame_padding_x, styles.spacing.frame_padding_y)
                pushed_vars = pushed_vars + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_WindowPadding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(),
                    styles.spacing.window_padding_x, styles.spacing.window_padding_y)
                pushed_vars = pushed_vars + 1
            end
        end)
    end

    if styles.rounding then
        pcall(function()
            if r.ImGui_StyleVar_WindowRounding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), styles.rounding.window_rounding)
                pushed_vars = pushed_vars + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_FrameRounding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), styles.rounding.frame_rounding)
                pushed_vars = pushed_vars + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_GrabRounding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(), styles.rounding.grab_rounding)
                pushed_vars = pushed_vars + 1
            end
        end)
    end

    if styles.borders then
        pcall(function()
            if r.ImGui_StyleVar_WindowBorderSize then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), styles.borders.window_border_size)
                pushed_vars = pushed_vars + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_FrameBorderSize then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), styles.borders.frame_border_size)
                pushed_vars = pushed_vars + 1
            end
        end)
    end

    if styles.sliders then
        pcall(function()
            if r.ImGui_StyleVar_GrabMinSize then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabMinSize(), styles.sliders.grab_min_size)
                pushed_vars = pushed_vars + 1
            end
        end)
    end

    return true, pushed_colors, pushed_vars
end

function module.ApplyFontsToContext(ctx)
    local r = reaper

    if not ctx then return false end

    local is_valid = true
    if r.ImGui_ValidatePtr then
        is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end

    if not is_valid then return false end

    local saved = r.GetExtState(extstate_id, "styles")
    if saved == "" then return false end

    local success, styles = pcall(function() return load("return " .. saved)() end)
    if not success or not styles or not styles.fonts then return false end

    local fonts = {}

    if styles.fonts.main and styles.fonts.main.name and styles.fonts.main.size then
        pcall(function()
            local font = r.ImGui_CreateFont(styles.fonts.main.name, styles.fonts.main.size)
            if font then
                r.ImGui_Attach(ctx, font)
                fonts.main = font
            end
        end)
    end

    if styles.fonts.header and styles.fonts.header.name and styles.fonts.header.size then
        pcall(function()
            local font = r.ImGui_CreateFont(styles.fonts.header.name, styles.fonts.header.size)
            if font then
                r.ImGui_Attach(ctx, font)
                fonts.header = font
            end
        end)
    end

    if styles.fonts.mono and styles.fonts.mono.name and styles.fonts.mono.size then
        pcall(function()
            local font = r.ImGui_CreateFont(styles.fonts.mono.name, styles.fonts.mono.size)
            if font then
                r.ImGui_Attach(ctx, font)
                fonts.mono = font
            end
        end)
    end

    if not _G.CP_StyleManager_Fonts then
        _G.CP_StyleManager_Fonts = {}
    end

    _G.CP_StyleManager_Fonts[tostring(ctx)] = fonts

    return true
end

function module.ClearStyles(ctx, pushed_colors, pushed_vars)
    local r = reaper

    if not ctx then return false end

    local is_valid = false
    pcall(function()
        is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end)

    if not is_valid then return false end

    if pushed_colors and pushed_colors > 0 then
        pcall(function() r.ImGui_PopStyleColor(ctx, pushed_colors) end)
    end

    if pushed_vars and pushed_vars > 0 then
        pcall(function() r.ImGui_PopStyleVar(ctx, pushed_vars) end)
    end

    return true
end

function module.GetFont(ctx, font_name)
    if not ctx or not font_name then return nil end

    if not _G.CP_StyleManager_Fonts then return nil end

    local ctx_fonts = _G.CP_StyleManager_Fonts[tostring(ctx)]
    if not ctx_fonts then return nil end

    return ctx_fonts[font_name]
end

function module.HasStyles()
    local r = reaper
    local saved = r.GetExtState(extstate_id, "styles")
    return saved ~= ""
end

function module.GetStyleValues()
    local r = reaper
    local saved = r.GetExtState(extstate_id, "styles")
    if saved == "" then return nil end
    
    local success, styles = pcall(function() return load("return " .. saved)() end)
    if not success or not styles then return nil end
    
    return styles
end

function module.GetSpacingValue(key)
    local styles = module.GetStyleValues()
    if not styles or not styles.spacing then return nil end
    return styles.spacing[key]
end

function module.GetValue(path, default_value)
    local styles = module.GetStyleValues()
    if not styles then return default_value end
    
    local current = styles
    for part in path:gmatch("[^%.]+") do
        if current and current[part] then
            current = current[part]
        else
            return default_value
        end
    end
    return current
end

function module.PushFont(ctx, font_name)
    local r = reaper
    
    if not ctx or not font_name then return false end
    
    local is_valid = true
    if r.ImGui_ValidatePtr then
        is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end
    if not is_valid then return false end
    
    local font = module.GetFont(ctx, font_name)
    if not font then return false end
    
    local styles = module.GetStyleValues()
    if not styles or not styles.fonts or not styles.fonts[font_name] then return false end
    
    local font_size = styles.fonts[font_name].size or 16
    
    pcall(function()
        r.ImGui_PushFont(ctx, font, font_size)
    end)
    
    return true
end

function module.PopFont(ctx)
    local r = reaper
    
    if not ctx then return false end
    
    local is_valid = true
    if r.ImGui_ValidatePtr then
        is_valid = r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end
    if not is_valid then return false end
    
    pcall(function()
        r.ImGui_PopFont(ctx)
    end)
    
    return true
end

module.applyToContext = module.ApplyToContext
module.applyFontsToContext = module.ApplyFontsToContext
module.clearStyles = module.ClearStyles
module.getFont = module.GetFont
module.hasStyles = module.HasStyles
module.getStyleValues = module.GetStyleValues
module.getSpacingValue = module.GetSpacingValue
module.getValue = module.GetValue
module.pushFont = module.PushFont
module.popFont = module.PopFont

return function()
    return module
end