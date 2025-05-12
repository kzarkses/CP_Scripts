-- CP_Widget_Handler.lua
local r = reaper
local handler = {}

function handler.init(widget_name, default_settings)
    local h = {}
    h.r = reaper
    h.ctx = r.ImGui_CreateContext(widget_name)
    h.has_js_api = r.APIExists("JS_Window_Find")
    h.script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
    h.os_separator = package.config:sub(1, 1)
    h.first_position_set = false
    
    -- JSON module
    h.json = {
        decode = function(str)
            if str ~= "" then
                local loaded_state = load("return " .. str)()
                return loaded_state
            end
            return {}
        end
    }
    
    h.settings = {}
    for k, v in pairs(default_settings) do
        h.settings[k] = v
    end
    
    if not r.serialize then
        function r.serialize(tbl)
            local res = "{"
            for k, v in pairs(tbl) do
                if type(k) == "string" then
                    res = res .. '["' .. k .. '"]='
                else
                    res = res .. "[" .. k .. "]="
                end
                if type(v) == "table" then
                    res = res .. r.serialize(v)
                elseif type(v) == "string" then
                    res = res .. string.format("%q", v)
                elseif type(v) == "number" or type(v) == "boolean" then
                    res = res .. tostring(v)
                end
                res = res .. ","
            end
            return res .. "}"
        end
    end
    
    h.font = r.ImGui_CreateFont(h.settings.current_font, h.settings.font_size)
    r.ImGui_Attach(h.ctx, h.font)
    
    function h.LoadSettings(section_name)
        h.section_name = section_name
        local state_str = r.GetExtState(section_name, "settings")
        if state_str ~= "" then
            local success, loaded_state = pcall(function() return load("return " .. state_str)() end)
            if success and loaded_state then
                for k, v in pairs(loaded_state) do
                    h.settings[k] = v
                end
            end
        end
    end
    
    function h.SaveSettings()
        local section = h.section_name or "WIDGET_HANDLER"
        local state = {}
        for k, v in pairs(h.settings) do
            state[k] = v
        end
        r.SetExtState(section, "settings", r.serialize(state), true)
    end
    
    function h.FollowTransport()
        if not h.has_js_api then return false end
        local transport_hwnd = r.JS_Window_Find("transport", true)
        if not transport_hwnd then return false end
        local retval, orig_LEFT, orig_TOP, orig_RIGHT, orig_BOT = r.JS_Window_GetRect(transport_hwnd)
        if not retval then return false end
        
        -- Convert coordinates if needed - depends on REAPER version
        local LEFT, TOP, RIGHT, BOT
        if r.APIExists("ImGui_PointConvertNative") then
            LEFT, TOP = r.ImGui_PointConvertNative(h.ctx, orig_LEFT, orig_TOP)
            RIGHT, BOT = r.ImGui_PointConvertNative(h.ctx, orig_RIGHT, orig_BOT)
        else
            LEFT, TOP, RIGHT, BOT = orig_LEFT, orig_TOP, orig_RIGHT, orig_BOT
        end
        
        local transport_width = RIGHT - LEFT
        local transport_height = BOT - TOP
        local target_x = LEFT + (h.settings.rel_pos_x * transport_width)
        local target_y = TOP + (h.settings.rel_pos_y * transport_height)
        r.ImGui_SetNextWindowPos(h.ctx, target_x, target_y)
        r.ImGui_SetNextWindowSize(h.ctx, h.settings.widget_width, h.settings.widget_height)
        return true
    end
    
    function h.SetStyle()
        r.ImGui_PushStyleVar(h.ctx, r.ImGui_StyleVar_WindowRounding(), h.settings.window_rounding)
        r.ImGui_PushStyleVar(h.ctx, r.ImGui_StyleVar_FrameRounding(), h.settings.frame_rounding)
        r.ImGui_PushStyleVar(h.ctx, r.ImGui_StyleVar_PopupRounding(), h.settings.popup_rounding or h.settings.window_rounding)
        r.ImGui_PushStyleVar(h.ctx, r.ImGui_StyleVar_GrabRounding(), h.settings.grab_rounding or h.settings.frame_rounding)
        r.ImGui_PushStyleVar(h.ctx, r.ImGui_StyleVar_GrabMinSize(), h.settings.grab_min_size or 8)
        r.ImGui_PushStyleVar(h.ctx, r.ImGui_StyleVar_FrameBorderSize(), h.settings.button_border_size or h.settings.border_size or 1)
        r.ImGui_PushStyleVar(h.ctx, r.ImGui_StyleVar_WindowBorderSize(), h.settings.border_size or 1)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_WindowBg(), h.settings.background_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_Text(), h.settings.text_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_Border(), h.settings.border_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_FrameBg(), h.settings.frame_bg or h.settings.button_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_FrameBgHovered(), h.settings.frame_bg_hovered or h.settings.button_hover_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_FrameBgActive(), h.settings.frame_bg_active or h.settings.button_active_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_Button(), h.settings.button_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_ButtonHovered(), h.settings.button_hover_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_ButtonActive(), h.settings.button_active_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_CheckMark(), h.settings.check_mark or h.settings.text_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_SliderGrab(), h.settings.slider_grab or h.settings.button_color)
        r.ImGui_PushStyleColor(h.ctx, r.ImGui_Col_SliderGrabActive(), h.settings.slider_grab_active or h.settings.button_active_color)
    end
    
    function h.ShowSettingsDialog()
        r.ImGui_Text(h.ctx, "Widget Settings")
        r.ImGui_Separator(h.ctx)
        local rv
        rv, h.settings.overlay_enabled = r.ImGui_Checkbox(h.ctx, "Follow transport", h.settings.overlay_enabled)
        rv, h.settings.show_background = r.ImGui_Checkbox(h.ctx, "Show background", h.settings.show_background)
        r.ImGui_Text(h.ctx, "Position within transport:")
        rv, h.settings.rel_pos_x = r.ImGui_SliderDouble(h.ctx, "X position", h.settings.rel_pos_x, 0.0, 1.0, "%.2f")
        rv, h.settings.rel_pos_y = r.ImGui_SliderDouble(h.ctx, "Y position", h.settings.rel_pos_y, -1.0, 1.0, "%.2f")
        r.ImGui_Text(h.ctx, "Widget dimensions:")
        rv, h.settings.widget_width = r.ImGui_SliderInt(h.ctx, "Width", h.settings.widget_width, 20, 1000)
        rv, h.settings.widget_height = r.ImGui_SliderInt(h.ctx, "Height", h.settings.widget_height, 14, 400)
        r.ImGui_Text(h.ctx, "Fine adjustment:")
        if r.ImGui_Button(h.ctx, "l") then
            h.settings.rel_pos_x = math.max(0, h.settings.rel_pos_x - 0.01)
        end
        r.ImGui_SameLine(h.ctx)
        if r.ImGui_Button(h.ctx, "r") then
            h.settings.rel_pos_x = math.min(1, h.settings.rel_pos_x + 0.01)
        end
        r.ImGui_SameLine(h.ctx)
        if r.ImGui_Button(h.ctx, "u") then
            h.settings.rel_pos_y = math.max(-1, h.settings.rel_pos_y - 0.01)
        end
        r.ImGui_SameLine(h.ctx)
        if r.ImGui_Button(h.ctx, "d") then
            h.settings.rel_pos_y = math.min(1, h.settings.rel_pos_y + 0.01)
        end
        r.ImGui_Separator(h.ctx)
        
        if r.ImGui_CollapsingHeader(h.ctx, "Theme Settings") then
            rv, h.settings.window_rounding = r.ImGui_SliderDouble(h.ctx, "Window Rounding", h.settings.window_rounding, 0, 20)
            rv, h.settings.frame_rounding = r.ImGui_SliderDouble(h.ctx, "Frame Rounding", h.settings.frame_rounding, 0, 20)
            rv, h.settings.popup_rounding = r.ImGui_SliderDouble(h.ctx, "Popup Rounding", h.settings.popup_rounding or h.settings.window_rounding, 0, 20)
            rv, h.settings.grab_rounding = r.ImGui_SliderDouble(h.ctx, "Grab Rounding", h.settings.grab_rounding or h.settings.frame_rounding, 0, 20)
            rv, h.settings.border_size = r.ImGui_SliderDouble(h.ctx, "Border Size", h.settings.border_size, 0, 5)
            rv, h.settings.background_color = r.ImGui_ColorEdit4(h.ctx, "Background Color", h.settings.background_color)
            rv, h.settings.text_color = r.ImGui_ColorEdit4(h.ctx, "Text Color", h.settings.text_color)
            rv, h.settings.button_color = r.ImGui_ColorEdit4(h.ctx, "Button Color", h.settings.button_color)
            rv, h.settings.button_hover_color = r.ImGui_ColorEdit4(h.ctx, "Button Hover Color", h.settings.button_hover_color)
            rv, h.settings.button_active_color = r.ImGui_ColorEdit4(h.ctx, "Button Active Color", h.settings.button_active_color)
            rv, h.settings.border_color = r.ImGui_ColorEdit4(h.ctx, "Border Color", h.settings.border_color)
        end
        
        if h.widget_settings_handler then
            h.widget_settings_handler(h.ctx)
        end
        
        if r.ImGui_Button(h.ctx, "Save Settings") then
            h.SaveSettings()
        end
    end
    
    function h.RunLoop(content_func)
        local window_flags = r.ImGui_WindowFlags_NoScrollbar() |
                             r.ImGui_WindowFlags_AlwaysAutoResize() |
                             r.ImGui_WindowFlags_NoTitleBar() |
                             r.ImGui_WindowFlags_NoFocusOnAppearing()

        if h.settings.overlay_enabled then
            window_flags = window_flags | r.ImGui_WindowFlags_NoMove() |
                          r.ImGui_WindowFlags_NoResize()
            if not h.settings.show_background then
                window_flags = window_flags | r.ImGui_WindowFlags_NoBackground()
            end
            local positioned = h.FollowTransport()
            if not positioned then
                r.ImGui_SetNextWindowPos(h.ctx, 100, 100)
                r.ImGui_SetNextWindowSize(h.ctx, h.settings.widget_width, h.settings.widget_height)
            end
        else
            if not h.first_position_set then
                local pos_x = h.settings.last_pos_x or 100
                local pos_y = h.settings.last_pos_y or 100
                r.ImGui_SetNextWindowPos(h.ctx, pos_x, pos_y)
                h.first_position_set = true
            end
            
            r.ImGui_SetNextWindowSize(h.ctx, h.settings.widget_width, h.settings.widget_height)
        end
        
        h.SetStyle()
        
        r.ImGui_PushFont(h.ctx, h.font)
        local visible, open = r.ImGui_Begin(h.ctx, h.widget_title or "Widget", true, window_flags)
        if visible then
            if content_func then
                content_func(h)
            end
            
            if not h.settings.overlay_enabled then
                local window_pos_x, window_pos_y = r.ImGui_GetWindowPos(h.ctx)
                if window_pos_x ~= h.settings.last_pos_x or window_pos_y ~= h.settings.last_pos_y then
                    h.settings.last_pos_x = window_pos_x
                    h.settings.last_pos_y = window_pos_y
                end
            end
            
            if r.ImGui_IsWindowHovered(h.ctx) and r.ImGui_IsMouseClicked(h.ctx, 1) and not r.ImGui_IsAnyItemHovered(h.ctx) then
                r.ImGui_OpenPopup(h.ctx, "SettingsMenu")
            end
            
            if r.ImGui_BeginPopup(h.ctx, "SettingsMenu") then
                h.ShowSettingsDialog()
                r.ImGui_EndPopup(h.ctx)
            end
            
            r.ImGui_End(h.ctx)
        end

        r.ImGui_PopFont(h.ctx)
        r.ImGui_PopStyleVar(h.ctx, 7)
        r.ImGui_PopStyleColor(h.ctx, 12)
        
        return open
    end
    
    function h.RegisterWidgetSettings(settings_handler)
        h.widget_settings_handler = settings_handler
    end
    
    function h.SetWidgetTitle(title)
        h.widget_title = title
    end
    
    return h
end

return handler