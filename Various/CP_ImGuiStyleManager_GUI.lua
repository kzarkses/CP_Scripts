-- @description ImGuiStyleManager - GUI
-- @version 1.1
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_ImGuiStyleManager_GUI"
local extstate_id = "CP_ImGuiStyles"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end
local ctx = r.ImGui_CreateContext('ImGui Style Manager')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

local config = {
    dock_id = 0,
    current_preset = "default",
    theme_name_input = "My Custom Theme",
}

local state = {
    selected_preset = "",
    show_preset_rename = false,
    rename_preset_name = "",
    initialized = false,
    font_update_pending = false,
    debug_info = "",
    preview_content = {
        active_tab = 0,
        checkbox_state = true,
        radio_state = 0,
        slider_value = 50,
        combo_selected = 0,
        input_text = "Sample text",
        multiline_text = "This is a\nmultiline\ntext input."
    }
}

function DeepCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[DeepCopy(orig_key)] = DeepCopy(orig_value)
        end
        setmetatable(copy, DeepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

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

local default_colors = {
    window_bg = 0x202020FF,
    text = 0xFFFFFFFF,
    text_disabled = 0x666666FF,
    border = 0x4C4C4CFF,
    border_shadow = 0x000000FF,
    button = 0x4C4C4CFF,
    button_hovered = 0x707070FF,
    button_active = 0x606060FF,
    header = 0x4C4C4CFF,
    header_hovered = 0x707070FF,
    header_active = 0x606060FF,
    frame_bg = 0x262626FF,
    frame_bg_hovered = 0x4C4C4CFF,
    frame_bg_active = 0x707070FF,
    tab = 0x4C4C4CFF,
    tab_hovered = 0x707070FF,
    tab_active = 0x606060FF,
    tab_unfocused = 0x222222FF,
    tab_unfocused_active = 0x4C4C4CFF,
    title_bg = 0x222222FF,
    title_bg_active = 0x4C4C4CFF,
    title_bg_collapsed = 0x111111FF,
    menu_bar_bg = 0x4C4C4CFF,
    child_bg = 0x1A1A1A00,
    popup_bg = 0x232323FF,
    table_header_bg = 0x4C4C4CFF,
    table_row_bg = 0x262626FF,
    table_row_bg_alt = 0x303030FF,
    table_border_strong = 0x606060FF,
    table_border_light = 0x4C4C4CFF,
    scrollbar_bg = 0x151515FF,
    scrollbar_grab = 0x606060FF,
    scrollbar_grab_hovered = 0x777777FF,
    scrollbar_grab_active = 0x999999FF,
    modal_window_dim_bg = 0x4C4C4C77,
    accent_color = 0x1E90FFFF,
    accent_color_hovered = 0x3AA0FFFF,
    accent_color_active = 0x5BAAFDFF,
    nav_highlight = 0x7373DAFF,
    nav_windowing_highlight = 0x7373DAFF,
    nav_windowing_dim_bg = 0x20202066,
    drag_drop_target = 0xFFFF00FF,
    plot_lines = 0xB0B0B0FF,
    plot_lines_hovered = 0xD0D0D0FF,
    plot_histogram = 0xE0E0E0FF,
    plot_histogram_hovered = 0xF0F0F0FF,
    separator = 0x707070FF,
    separator_hovered = 0x606060FF,
    separator_active = 0x666666FF,
    slider_grab = 0x52A38DFF,
    slider_grab_active = 0x86BDAEFF,
    checkmark = 0x52A38DFF,
    resize_grip = 0x66666600,
    resize_grip_hovered = 0x777777FF,
    resize_grip_active = 0x888888FF,
    text_selected_bg = 0x8A7946FF
}

local styles = {
    fonts = {
        main = { name = "verdana", size = 16 },
        header = { name = "verdana", size = 24 },
        mono = { name = "consolas", size = 14 }
    },
    colors = DeepCopy(default_colors),
    spacing = {
        item_spacing_x = 6,
        item_spacing_y = 6,
        inner_spacing_x = 4,
        inner_spacing_y = 4,
        frame_padding_x = 6,
        frame_padding_y = 6,
        window_padding_x = 10,
        window_padding_y = 10,
        cell_padding_x = 4,
        cell_padding_y = 2,
        indent_spacing = 20,
        scrollbar_size = 14
    },
    borders = {
        window_border_size = 1,
        child_border_size = 1,
        popup_border_size = 1,
        frame_border_size = 0,
        tab_border_size = 1
    },
    rounding = {
        window_rounding = 6,
        child_rounding = 0,
        frame_rounding = 4,
        popup_rounding = 0,
        scrollbar_rounding = 0,
        grab_rounding = 4,
        tab_rounding = 0
    },
    sliders = {
        grab_min_size = 14
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

local font_objects = {
    main = nil,
    header = nil,
    mono = nil
}

local presets = {}

local themes = {
    {
        name = "Default Dark",
        styles = DeepCopy(styles)
    },
    {
        name = "Light Theme",
        styles = {
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
                tab_unfocused_active = 0xE5E5E5FF,
                title_bg = 0xE0E0E0FF,
                title_bg_active = 0xD0D0D0FF,
                title_bg_collapsed = 0xF5F5F5FF,
                menu_bar_bg = 0xE0E0E0FF,
                child_bg = 0xF8F8F8FF,
                popup_bg = 0xFFFFFFFF,
                table_header_bg = 0xE0E0E0FF,
                table_row_bg = 0xFFFFFFFF,
                table_row_bg_alt = 0xF5F5F5FF,
                table_border_strong = 0xCCCCCCFF,
                table_border_light = 0xE0E0E0FF,
                scrollbar_bg = 0xEEEEEEFF,
                scrollbar_grab = 0xCCCCCCFF,
                scrollbar_grab_hovered = 0xBBBBBBFF,
                scrollbar_grab_active = 0xAAAAAAFF,
                modal_window_dim_bg = 0x77777777,
                accent_color = 0x3F85CDFF,
                accent_color_hovered = 0x5B91D0FF,
                accent_color_active = 0x77A3E0FF,
                nav_highlight = 0x7373DAFF,
                nav_windowing_highlight = 0x7373DAFF,
                nav_windowing_dim_bg = 0x20202066,
                drag_drop_target = 0xFFAA00FF,
                plot_lines = 0x707070FF,
                plot_lines_hovered = 0x606060FF,
                plot_histogram = 0x4C4C4CFF,
                plot_histogram_hovered = 0x707070FF,
                separator = 0xDDDDDDFF,
                separator_hovered = 0xCCCCCCFF,
                separator_active = 0xBBBBBBFF,
                slider_grab = 0x3F85CDFF,
                slider_grab_active = 0x77A3E0FF,
                check_mark = 0x3F85CDFF,
                resize_grip = 0xCCCCCC00,
                resize_grip_hovered = 0xBBBBBB00,
                resize_grip_active = 0xAAAAAA00,
                text_selected_bg = 0x3875D7FF
            },
            fonts = DeepCopy(styles.fonts),
            spacing = DeepCopy(styles.spacing),
            borders = DeepCopy(styles.borders),
            rounding = DeepCopy(styles.rounding),
            sliders = DeepCopy(styles.sliders),
            extras = DeepCopy(styles.extras)
        }
    },
    {
        name = "Modern Dark",
        styles = {
            colors = {
                window_bg = 0x1A1A1AFF,
                text = 0xEAEAEAFF,
                text_disabled = 0x666666FF,
                border = 0x707070FF,
                border_shadow = 0x000000FF,
                button = 0x2A2A2AFF,
                button_hovered = 0x3A3A3AFF,
                button_active = 0x4A4A4AFF,
                header = 0x222222FF,
                header_hovered = 0x4C4C4CFF,
                header_active = 0x707070FF,
                frame_bg = 0x2A2A2AFF,
                frame_bg_hovered = 0x3A3A3AFF,
                frame_bg_active = 0x4A4A4AFF,
                tab = 0x222222FF,
                tab_hovered = 0x4C4C4CFF,
                tab_active = 0x707070FF,
                tab_unfocused = 0x1D1D1DFF,
                tab_unfocused_active = 0x222222FF,
                title_bg = 0x111111FF,
                title_bg_active = 0x222222FF,
                title_bg_collapsed = 0x0A0A0AFF,
                menu_bar_bg = 0x222222FF,
                child_bg = 0x1A1A1AFF,
                popup_bg = 0x1A1A1AFF,
                table_header_bg = 0x222222FF,
                table_row_bg = 0x1A1A1AFF,
                table_row_bg_alt = 0x232323FF,
                table_border_strong = 0x707070FF,
                table_border_light = 0x4C4C4CFF,
                scrollbar_bg = 0x0F0F0FFF,
                scrollbar_grab = 0x707070FF,
                scrollbar_grab_hovered = 0x606060FF,
                scrollbar_grab_active = 0x666666FF,
                modal_window_dim_bg = 0x22222277,
                accent_color = 0x6A64F4FF,
                accent_color_hovered = 0x8A84FFFF,
                accent_color_active = 0xAA9CFFFF,
                nav_highlight = 0x6A64F4FF,
                nav_windowing_highlight = 0x6A64F4FF,
                nav_windowing_dim_bg = 0x20202066,
                drag_drop_target = 0xFFC107FF,
                plot_lines = 0xB0B0B0FF,
                plot_lines_hovered = 0xD0D0D0FF,
                plot_histogram = 0xE0E0E0FF,
                plot_histogram_hovered = 0xF0F0F0FF,
                separator = 0x707070FF,
                separator_hovered = 0x606060FF,
                separator_active = 0x666666FF,
                slider_grab = 0x6A64F4FF,
                slider_grab_active = 0xAA9CFFFF,
                check_mark = 0x6A64F4FF,
                resize_grip = 0x707070FF,
                resize_grip_hovered = 0x606060FF,
                resize_grip_active = 0x666666FF,
                text_selected_bg = 0x3875D7FF
            },
            rounding = {
                window_rounding = 6,
                child_rounding = 4,
                frame_rounding = 4,
                popup_rounding = 4,
                scrollbar_rounding = 4,
                grab_rounding = 4,
                tab_rounding = 4
            },
            fonts = DeepCopy(styles.fonts),
            spacing = DeepCopy(styles.spacing),
            borders = DeepCopy(styles.borders),
            sliders = DeepCopy(styles.sliders),
            extras = DeepCopy(styles.extras)
        }
    },
    {
        name = "Retro Green",
        styles = {
            colors = {
                window_bg = 0x0D1117FF,
                text = 0x4AFF3AFF,
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
                tab_unfocused_active = 0x111A11FF,
                title_bg = 0x0A140AFF,
                title_bg_active = 0x111A11FF,
                title_bg_collapsed = 0x070F07FF,
                menu_bar_bg = 0x111A11FF,
                child_bg = 0x0D1117FF,
                popup_bg = 0x0D1117FF,
                table_header_bg = 0x111A11FF,
                table_row_bg = 0x0D1117FF,
                table_row_bg_alt = 0x0F141CFF,
                table_border_strong = 0x2A3F17FF,
                table_border_light = 0x1A2A1AFF,
                scrollbar_bg = 0x070F07FF,
                scrollbar_grab = 0x1A2A1AFF,
                scrollbar_grab_hovered = 0x254425FF,
                scrollbar_grab_active = 0x305530FF,
                modal_window_dim_bg = 0x0A0A0A77,
                accent_color = 0x4AFF3AFF,
                accent_color_hovered = 0x5AFF4AFF,
                accent_color_active = 0x6AFF5AFF,
                nav_highlight = 0x4AFF3AFF,
                nav_windowing_highlight = 0x4AFF3AFF,
                nav_windowing_dim_bg = 0x20202066,
                drag_drop_target = 0xFFFF00FF,
                plot_lines = 0x4AFF3AFF,
                plot_lines_hovered = 0x5AFF4AFF,
                plot_histogram = 0x5AFF4AFF,
                plot_histogram_hovered = 0x6AFF5AFF,
                separator = 0x254425FF,
                separator_hovered = 0x305530FF,
                separator_active = 0x3B663BFF,
                slider_grab = 0x4AFF3AFF,
                slider_grab_active = 0x6AFF5AFF,
                check_mark = 0x4AFF3AFF,
                resize_grip = 0x254425FF,
                resize_grip_hovered = 0x305530FF,
                resize_grip_active = 0x3B663BFF,
                text_selected_bg = 0x3875D7FF
            },
            fonts = {
                main = { name = "monospace", size = 14 },
                header = { name = "monospace", size = 16 },
                mono = { name = "monospace", size = 14 }
            },
            spacing = DeepCopy(styles.spacing),
            borders = DeepCopy(styles.borders),
            rounding = {
                window_rounding = 0,
                child_rounding = 0,
                frame_rounding = 0,
                popup_rounding = 0,
                scrollbar_rounding = 0,
                grab_rounding = 0,
                tab_rounding = 0
            },
            sliders = DeepCopy(styles.sliders),
            extras = DeepCopy(styles.extras)
        }
    }
}

function GetFont(font_name)
    if font_objects[font_name] then
        return font_objects[font_name]
    end
    return nil
end

function ApplyStyle()
    return ApplyStylesInteractive()
end

function ClearStyle()
    PopStyles(pushed_colors, pushed_vars)
end

function ShowColorEditor(label, color_var, color_path)
    local flags = r.ImGui_ColorEditFlags_AlphaBar()
    local changed, new_color = r.ImGui_ColorEdit4(ctx, label, color_var, flags)

    if changed then
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

function ApplyStylesInteractive()
    local pushed_colors_count = 0
    local pushed_vars_count = 0

    if styles.colors then
        pcall(function()
            if r.ImGui_Col_WindowBg and styles.colors.window_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), styles.colors.window_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_Text and styles.colors.text then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), styles.colors.text)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TextDisabled and styles.colors.text_disabled then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextDisabled(), styles.colors.text_disabled)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_Border and styles.colors.border then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), styles.colors.border)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_BorderShadow and styles.colors.border_shadow then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_BorderShadow(), styles.colors.border_shadow)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_Button and styles.colors.button then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), styles.colors.button)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ButtonHovered and styles.colors.button_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), styles.colors.button_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ButtonActive and styles.colors.button_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), styles.colors.button_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_Header and styles.colors.header then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), styles.colors.header)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_HeaderHovered and styles.colors.header_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), styles.colors.header_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_HeaderActive and styles.colors.header_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), styles.colors.header_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_FrameBg and styles.colors.frame_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), styles.colors.frame_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_FrameBgHovered and styles.colors.frame_bg_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), styles.colors.frame_bg_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_FrameBgActive and styles.colors.frame_bg_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), styles.colors.frame_bg_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_Separator and styles.colors.separator then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Separator(), styles.colors.separator)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SeparatorHovered and styles.colors.separator_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SeparatorHovered(), styles.colors.separator_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SeparatorActive and styles.colors.separator_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SeparatorActive(), styles.colors.separator_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SliderGrab and styles.colors.slider_grab then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrab(), styles.colors.slider_grab)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_SliderGrabActive and styles.colors.slider_grab_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrabActive(), styles.colors.slider_grab_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_CheckMark and styles.colors.checkmark then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(), styles.colors.checkmark)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_Tab and styles.colors.tab then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Tab(), styles.colors.tab)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabHovered and styles.colors.tab_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabHovered(), styles.colors.tab_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabSelected and styles.colors.tab_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabSelected(), styles.colors.tab_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabUnfocused and styles.colors.tab_unfocused then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabUnfocused(), styles.colors.tab_unfocused)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TabUnfocusedActive and styles.colors.tab_unfocused_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabUnfocusedActive(), styles.colors.tab_unfocused_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TitleBg and styles.colors.title_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBg(), styles.colors.title_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TitleBgActive and styles.colors.title_bg_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBgActive(), styles.colors.title_bg_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TitleBgCollapsed and styles.colors.title_bg_collapsed then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBgCollapsed(), styles.colors.title_bg_collapsed)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_MenuBarBg and styles.colors.menu_bar_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_MenuBarBg(), styles.colors.menu_bar_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ChildBg and styles.colors.child_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), styles.colors.child_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_PopupBg and styles.colors.popup_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), styles.colors.popup_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarBg and styles.colors.scrollbar_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarBg(), styles.colors.scrollbar_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarGrab and styles.colors.scrollbar_grab then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrab(), styles.colors.scrollbar_grab)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarGrabHovered and styles.colors.scrollbar_grab_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrabHovered(), styles.colors.scrollbar_grab_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ScrollbarGrabActive and styles.colors.scrollbar_grab_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrabActive(), styles.colors.scrollbar_grab_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ResizeGrip and styles.colors.resize_grip then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGrip(), styles.colors.resize_grip)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ResizeGripHovered and styles.colors.resize_grip_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGripHovered(), styles.colors.resize_grip_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ResizeGripActive and styles.colors.resize_grip_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGripActive(), styles.colors.resize_grip_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TextSelectedBg and styles.colors.text_selected_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextSelectedBg(), styles.colors.text_selected_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_DragDropTarget and styles.colors.drag_drop_target then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_DragDropTarget(), styles.colors.drag_drop_target)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_NavHighlight and styles.colors.nav_highlight then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_NavHighlight(), styles.colors.nav_highlight)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_NavWindowingHighlight and styles.colors.nav_windowing_highlight then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_NavWindowingHighlight(), styles.colors.nav_windowing_highlight)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_NavWindowingDimBg and styles.colors.nav_windowing_dim_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_NavWindowingDimBg(), styles.colors.nav_windowing_dim_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_ModalWindowDimBg and styles.colors.modal_window_dim_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ModalWindowDimBg(), styles.colors.modal_window_dim_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_PlotLines and styles.colors.plot_lines then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PlotLines(), styles.colors.plot_lines)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_PlotLinesHovered and styles.colors.plot_lines_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PlotLinesHovered(), styles.colors.plot_lines_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_PlotHistogram and styles.colors.plot_histogram then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PlotHistogram(), styles.colors.plot_histogram)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_PlotHistogramHovered and styles.colors.plot_histogram_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PlotHistogramHovered(), styles.colors.plot_histogram_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TableHeaderBg and styles.colors.table_header_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TableHeaderBg(), styles.colors.table_header_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TableRowBg and styles.colors.table_row_bg then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TableRowBg(), styles.colors.table_row_bg)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TableRowBgAlt and styles.colors.table_row_bg_alt then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TableRowBgAlt(), styles.colors.table_row_bg_alt)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TableBorderStrong and styles.colors.table_border_strong then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TableBorderStrong(), styles.colors.table_border_strong)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_Col_TableBorderLight and styles.colors.table_border_light then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TableBorderLight(), styles.colors.table_border_light)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)
        pcall(function()
            if r.ImGui_Col_ResizeGrip and styles.colors.resize_grip then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGrip()(), styles.colors.resize_grip)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)
        pcall(function()
            if r.ImGui_Col_ResizeGripActive and styles.colors.resize_grip_active then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGripActive(), styles.colors.resize_grip_active)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)
        pcall(function()
            if r.ImGui_Col_ResizeGripHovered and styles.colors.resize_grip_hovered then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ResizeGripHovered(), styles.colors.resize_grip_hovered)
                pushed_colors_count = pushed_colors_count + 1
            end
        end)
    end

    if styles.spacing then
        pcall(function()
            if r.ImGui_StyleVar_ItemSpacing then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), styles.spacing.item_spacing_x,
                    styles.spacing.item_spacing_y)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_FramePadding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), styles.spacing.frame_padding_x,
                    styles.spacing.frame_padding_y)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_WindowPadding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), styles.spacing.window_padding_x,
                    styles.spacing.window_padding_y)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)
    end

    if styles.rounding then
        pcall(function()
            if r.ImGui_StyleVar_WindowRounding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), styles.rounding.window_rounding)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_FrameRounding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), styles.rounding.frame_rounding)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_GrabRounding then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(), styles.rounding.grab_rounding)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)
    end

    if styles.borders then
        pcall(function()
            if r.ImGui_StyleVar_WindowBorderSize then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), styles.borders.window_border_size)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)

        pcall(function()
            if r.ImGui_StyleVar_FrameBorderSize then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), styles.borders.frame_border_size)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)
    end

    if styles.sliders then
        pcall(function()
            if r.ImGui_StyleVar_GrabMinSize then
                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabMinSize(), styles.sliders.grab_min_size)
                pushed_vars_count = pushed_vars_count + 1
            end
        end)
    end

    return pushed_colors_count, pushed_vars_count
end

function PopStyles(pushed_colors_count, pushed_vars_count)
    if pushed_colors_count > 0 then
        r.ImGui_PopStyleColor(ctx, pushed_colors_count)
    end

    if pushed_vars_count > 0 then
        r.ImGui_PopStyleVar(ctx, pushed_vars_count)
    end
end

function ShowPreviewPanel()
    r.ImGui_Text(ctx, "Preview")
    r.ImGui_Separator(ctx)

    if r.ImGui_BeginTabBar then
        if r.ImGui_BeginTabBar(ctx, "PreviewTabs") then
            if r.ImGui_BeginTabItem(ctx, "Controls") then
                r.ImGui_Text(ctx, "Buttons:")
                local success = pcall(function()
                    r.ImGui_Button(ctx, "Click Me")
                end)
                if not success then
                    r.ImGui_Button(ctx, "Click Me")
                end

                r.ImGui_SameLine(ctx)

                pcall(function()
                    r.ImGui_SmallButton(ctx, "Small")
                end)

                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Regular text")
                r.ImGui_TextDisabled(ctx, "Disabled text")
                r.ImGui_TextColored(ctx, 0xFF4444FF, "Colored text")

                r.ImGui_Spacing(ctx)
                pcall(function()
                    local chg, new_state = r.ImGui_Checkbox(ctx, "Checkbox", state.preview_content.checkbox_state)
                    if chg then state.preview_content.checkbox_state = new_state end
                end)

                r.ImGui_Spacing(ctx)
                pcall(function()
                    local chg, new_val = r.ImGui_SliderInt(ctx, "Slider", state.preview_content.slider_value, 0, 100)
                    if chg then state.preview_content.slider_value = new_val end
                end)

                r.ImGui_Spacing(ctx)
                pcall(function()
                    if r.ImGui_BeginCombo(ctx, "Combo", "Item " .. state.preview_content.combo_selected) then
                        for i = 0, 4 do
                            if r.ImGui_Selectable(ctx, "Item " .. i, state.preview_content.combo_selected == i) then
                                state.preview_content.combo_selected = i
                            end
                        end
                        r.ImGui_EndCombo(ctx)
                    end
                end)

                r.ImGui_Spacing(ctx)
                pcall(function()
                    local chg, new_text = r.ImGui_InputText(ctx, "Input", state.preview_content.input_text)
                    if chg then state.preview_content.input_text = new_text end
                end)

                r.ImGui_EndTabItem(ctx)
            end

            pcall(function()
                if r.ImGui_BeginTabItem(ctx, "Layout") then
                    if r.ImGui_BeginChild then
                        if r.ImGui_BeginChild(ctx, "child1", 180, 80) then
                            r.ImGui_Text(ctx, "Child window content")
                            r.ImGui_EndChild(ctx)
                        end
                    end

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
        r.ImGui_Text(ctx, "Basic controls")
        r.ImGui_Separator(ctx)

        r.ImGui_Button(ctx, "Button")
        r.ImGui_Spacing(ctx)
        r.ImGui_Text(ctx, "Text")
    end
end

function UpdateFonts()
    font_objects = {
        main = nil,
        header = nil,
        mono = nil
    }

    font_objects.main = r.ImGui_CreateFont(styles.fonts.main.name, styles.fonts.main.size)
    font_objects.header = r.ImGui_CreateFont(styles.fonts.header.name, styles.fonts.header.size)
    font_objects.mono = r.ImGui_CreateFont(styles.fonts.mono.name, styles.fonts.mono.size)

    r.ImGui_Attach(ctx, font_objects.main)
    r.ImGui_Attach(ctx, font_objects.header)
    r.ImGui_Attach(ctx, font_objects.mono)

    state.font_update_pending = false

    r.ImGui_SetNextWindowPos(ctx, 200, 200, r.ImGui_Cond_FirstUseEver())
end

function EnsureColorExists(colors_table, key, default_value)
    if not colors_table[key] then
        colors_table[key] = default_value
    end
end

function EnsureAllColorsExist(target_colors)
    for key, value in pairs(default_colors) do
        EnsureColorExists(target_colors, key, value)
    end
end

function SaveSettings()
    for key, value in pairs(config) do
        local value_str = tostring(value)
        if type(value) == "boolean" then
            value_str = value and "1" or "0"
        end
        r.SetExtState(script_name, "config_" .. key, value_str, true)
    end

    local serialized = r.serialize(styles)
    r.SetExtState(extstate_id, "styles", serialized, true)

    r.SetExtState(extstate_id, "dock", tostring(config.dock_id), true)
    r.SetExtState(extstate_id, "current_preset", config.current_preset, true)

    local saved_presets = r.serialize(presets)
    r.SetExtState(extstate_id, "presets", saved_presets, true)

    state.debug_info = "Settings saved"
end

function LoadSettings()
    for key, default_value in pairs(config) do
        local saved_value = r.GetExtState(script_name, "config_" .. key)
        if saved_value ~= "" then
            if type(default_value) == "number" then
                config[key] = tonumber(saved_value) or default_value
            elseif type(default_value) == "boolean" then
                config[key] = saved_value == "1"
            else
                config[key] = saved_value
            end
        end
    end

    local saved = r.GetExtState(extstate_id, "styles")
    if saved and saved ~= "" then
        local success, loaded = pcall(function() return load("return " .. saved)() end)
        if success and loaded then
            if loaded.colors then
                EnsureAllColorsExist(loaded.colors)
            end

            for category, values in pairs(loaded) do
                if styles[category] then
                    for key, value in pairs(values) do
                        styles[category][key] = value
                    end
                end
            end
        end
    end

    local saved_dock = r.GetExtState(extstate_id, "dock")
    if saved_dock and saved_dock ~= "" then
        config.dock_id = tonumber(saved_dock) or 0
    end

    local preset = r.GetExtState(extstate_id, "current_preset")
    if preset ~= "" then config.current_preset = preset end

    local saved_presets = r.GetExtState(extstate_id, "presets")
    if saved_presets ~= "" then
        local success, loaded_presets = pcall(function() return load("return " .. saved_presets)() end)
        if success and loaded_presets then
            presets = loaded_presets
            for _, preset_styles in pairs(presets) do
                if type(preset_styles) == "table" and preset_styles.colors then
                    EnsureAllColorsExist(preset_styles.colors)
                end
            end
        end
    end

    if not presets["default"] then
        presets["default"] = DeepCopy(styles)
        SavePreset("default")
    end
end

function SavePreset(name)
    if name == "" then return end
    EnsureAllColorsExist(styles.colors)
    presets[name] = DeepCopy(styles)
    SaveSettings()
end

function LoadPreset(name)
    if presets[name] then
        styles = DeepCopy(presets[name])
        EnsureAllColorsExist(styles.colors)
        config.current_preset = name
        state.font_update_pending = true
        SaveSettings()
    end
end

function DeletePreset(name)
    if presets[name] and name ~= "default" then
        presets[name] = nil
        if config.current_preset == name then
            config.current_preset = "default"
        end
        SaveSettings()
    end
end

function RenamePreset(old_name, new_name)
    if presets[old_name] and new_name ~= "" and old_name ~= new_name and old_name ~= "default" then
        presets[new_name] = presets[old_name]
        presets[old_name] = nil
        if config.current_preset == old_name then
            config.current_preset = new_name
        end
        SaveSettings()
    end
end

function ApplyTheme(theme_idx)
    if themes[theme_idx] and themes[theme_idx].styles then
        styles = DeepCopy(themes[theme_idx].styles)
        EnsureAllColorsExist(styles.colors)
        state.font_update_pending = true
        SaveSettings()
    end
end

function ExportColorsToFile()
    local export_text = "local default_colors = {\n"
    
    for key, value in pairs(styles.colors) do
        export_text = export_text .. "    " .. key .. " = 0x" .. string.format("%08X", value) .. ",\n"
    end
    
    export_text = export_text .. "}"
    
    local export_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/exported_colors.txt"
    local file = io.open(export_path, "w")
    if file then
        file:write(export_text)
        file:close()
        state.debug_info = "Colors exported to: " .. export_path
        return true
    else
        state.debug_info = "Error: Could not create export file"
        return false
    end
end

function Init()
    LoadSettings()
    UpdateFonts()
    state.initialized = true
end

function MainLoop()
    if state.font_update_pending then
        UpdateFonts()
    end

    if config.dock_id ~= 0 then
        pcall(function()
            r.ImGui_SetNextWindowDockID(ctx, config.dock_id)
        end)
    end

    if state.font_update_pending then
        r.ImGui_End(ctx)
        UpdateFonts()
        state.font_update_pending = false
        return
    end

    pushed_colors, pushed_vars = ApplyStyle()

    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    r.ImGui_SetNextWindowSize(ctx, 400, 800, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, 'ImGui Style Manager', true, window_flags)

    pcall(function()
        local new_dock_id = r.ImGui_GetWindowDockID(ctx)
        if new_dock_id ~= config.dock_id then
            config.dock_id = new_dock_id
            r.SetExtState(extstate_id, "dock", tostring(config.dock_id), true)
        end
    end)

    if visible then
        local header_font = GetFont("header")
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "ImGui Style Manager")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "ImGui Style Manager")
        end

        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 20)
        local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 8)
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local close_button_size = header_font_size + 6
        local save_button_width = 60
        local buttons_width = save_button_width + close_button_size + item_spacing_x
        local save_x = r.ImGui_GetWindowWidth(ctx) - buttons_width - window_padding_x
        r.ImGui_SetCursorPosX(ctx, save_x)
        
        if r.ImGui_Button(ctx, "Save", save_button_width, close_button_size) then
            SaveSettings()
            state.debug_info = "Settings saved successfully"
        end
        
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        r.ImGui_Separator(ctx)
        if r.ImGui_BeginChild(ctx, "ScrollableContent", -1, -1) then
            local main_font = GetFont("main")
            if style_loader and style_loader.PushFont(ctx, "main") then
            
            if state.debug_info ~= "" then
                r.ImGui_TextColored(ctx, 0x00FF00FF, state.debug_info)
                r.ImGui_Spacing(ctx)
            end

            local has_tab_bar = pcall(function() return r.ImGui_BeginTabBar(ctx, "StyleTabs") end)

            if has_tab_bar then
                if r.ImGui_BeginTabItem(ctx, "Themes") then
                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Choose a preset theme:")
                    r.ImGui_Spacing(ctx)

                    for i, theme in ipairs(themes) do
                        local clicked = false
                        local success = pcall(function()
                            clicked = r.ImGui_Button(ctx, theme.name, 200)
                        end)
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

                    r.ImGui_Text(ctx, "Current Preset: " .. config.current_preset)
                    r.ImGui_Spacing(ctx)

                    r.ImGui_Text(ctx, "Custom Presets:")

                    if r.ImGui_Button(ctx, "Save", 80) then
                        SavePreset(config.current_preset)
                        state.debug_info = "Preset '" .. config.current_preset .. "' saved"
                    end

                    r.ImGui_SameLine(ctx)
                    r.ImGui_SetNextItemWidth(ctx, 200)
                    local rv, new_name = r.ImGui_InputText(ctx, "Preset Name", config.theme_name_input)
                    if rv then config.theme_name_input = new_name end

                    r.ImGui_SameLine(ctx)
                    if r.ImGui_Button(ctx, "Save As", 80) then
                        if config.theme_name_input and config.theme_name_input ~= "" then
                            SavePreset(config.theme_name_input)
                            config.current_preset = config.theme_name_input
                            config.theme_name_input = ""
                            state.debug_info = "New preset '" .. config.current_preset .. "' created"
                        end
                    end

                    r.ImGui_Spacing(ctx)

                    local preset_count = 0
                    for _ in pairs(presets) do preset_count = preset_count + 1 end
                    local child_height = preset_count > 4 and 380 or preset_count * 60

                    if r.ImGui_BeginChild(ctx, "PresetList", -1, child_height) then
                        for name, _ in pairs(presets) do
                            r.ImGui_PushID(ctx, name)
                            if r.ImGui_Button(ctx, name, 150) then
                                LoadPreset(name)
                                state.selected_preset = name
                            end
                            r.ImGui_SameLine(ctx)
                            if name then
                                if r.ImGui_Button(ctx, "R") then
                                    state.show_preset_rename = true
                                    state.rename_preset_name = name
                                    state.selected_preset = name
                                end
                                r.ImGui_SameLine(ctx)
                                if r.ImGui_Button(ctx, "X") then
                                    DeletePreset(name)
                                end
                            end
                            r.ImGui_PopID(ctx)
                        end
                        r.ImGui_EndChild(ctx)
                    end

                    if state.show_preset_rename then
                        r.ImGui_OpenPopup(ctx, "Rename Preset")
                    end

                    if r.ImGui_BeginPopupModal(ctx, "Rename Preset", nil, r.ImGui_WindowFlags_AlwaysAutoResize()) then
                        local changed, new_name = r.ImGui_InputText(ctx, "New Name", state.rename_preset_name)
                        if changed then state.rename_preset_name = new_name end

                        if r.ImGui_Button(ctx, "OK", 120) then
                            RenamePreset(state.selected_preset, state.rename_preset_name)
                            state.show_preset_rename = false
                            r.ImGui_CloseCurrentPopup(ctx)
                        end
                        r.ImGui_SameLine(ctx)
                        if r.ImGui_Button(ctx, "Cancel", 120) then
                            state.show_preset_rename = false
                            r.ImGui_CloseCurrentPopup(ctx)
                        end
                        r.ImGui_EndPopup(ctx)
                    end

                    r.ImGui_EndTabItem(ctx)
                end

                if r.ImGui_BeginTabItem(ctx, "Colors") then
                    local window_width = r.ImGui_GetContentRegionAvail(ctx)

                    r.ImGui_Text(ctx, "Main Colors")
                    r.ImGui_Separator(ctx)

                    styles.colors.window_bg = ShowColorEditor("Window Background", styles.colors.window_bg, "colors.window_bg")
                    styles.colors.text = ShowColorEditor("Text", styles.colors.text, "colors.text")
                    styles.colors.text_disabled = ShowColorEditor("Text Disabled", styles.colors.text_disabled, "colors.text_disabled")
                    styles.colors.border = ShowColorEditor("Border", styles.colors.border, "colors.border")
                    styles.colors.border_shadow = ShowColorEditor("Border Shadow", styles.colors.border_shadow, "colors.border_shadow")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Button Colors")
                    r.ImGui_Separator(ctx)

                    styles.colors.button = ShowColorEditor("Button", styles.colors.button, "colors.button")
                    styles.colors.button_hovered = ShowColorEditor("Button Hovered", styles.colors.button_hovered, "colors.button_hovered")
                    styles.colors.button_active = ShowColorEditor("Button Active", styles.colors.button_active, "colors.button_active")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Headers")
                    r.ImGui_Separator(ctx)

                    styles.colors.header = ShowColorEditor("Header", styles.colors.header, "colors.header")
                    styles.colors.header_hovered = ShowColorEditor("Header Hovered", styles.colors.header_hovered, "colors.header_hovered")
                    styles.colors.header_active = ShowColorEditor("Header Active", styles.colors.header_active, "colors.header_active")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Frames")
                    r.ImGui_Separator(ctx)

                    styles.colors.frame_bg = ShowColorEditor("Frame Background", styles.colors.frame_bg, "colors.frame_bg")
                    styles.colors.frame_bg_hovered = ShowColorEditor("Frame BG Hovered", styles.colors.frame_bg_hovered, "colors.frame_bg_hovered")
                    styles.colors.frame_bg_active = ShowColorEditor("Frame BG Active", styles.colors.frame_bg_active, "colors.frame_bg_active")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Tabs")
                    r.ImGui_Separator(ctx)

                    styles.colors.tab = ShowColorEditor("Tab", styles.colors.tab, "colors.tab")
                    styles.colors.tab_hovered = ShowColorEditor("Tab Hovered", styles.colors.tab_hovered, "colors.tab_hovered")
                    styles.colors.tab_active = ShowColorEditor("Tab Active", styles.colors.tab_active, "colors.tab_active")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Tables")
                    r.ImGui_Separator(ctx)

                    styles.colors.table_header_bg = ShowColorEditor("Table Header BG", styles.colors.table_header_bg, "colors.table_header_bg")
                    styles.colors.table_row_bg = ShowColorEditor("Table Row BG", styles.colors.table_row_bg, "colors.table_row_bg")
                    styles.colors.table_row_bg_alt = ShowColorEditor("Table Row BG Alt", styles.colors.table_row_bg_alt, "colors.table_row_bg_alt")
                    styles.colors.table_border_strong = ShowColorEditor("Table Border Strong", styles.colors.table_border_strong, "colors.table_border_strong")
                    styles.colors.table_border_light = ShowColorEditor("Table Border Light", styles.colors.table_border_light, "colors.table_border_light")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Scrollbars")
                    r.ImGui_Separator(ctx)

                    styles.colors.scrollbar_bg = ShowColorEditor("Scrollbar BG", styles.colors.scrollbar_bg, "colors.scrollbar_bg")
                    styles.colors.scrollbar_grab = ShowColorEditor("Scrollbar Grab", styles.colors.scrollbar_grab, "colors.scrollbar_grab")
                    styles.colors.scrollbar_grab_hovered = ShowColorEditor("Scrollbar Grab Hovered", styles.colors.scrollbar_grab_hovered, "colors.scrollbar_grab_hovered")
                    styles.colors.scrollbar_grab_active = ShowColorEditor("Scrollbar Grab Active", styles.colors.scrollbar_grab_active, "colors.scrollbar_grab_active")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Sliders")
                    r.ImGui_Separator(ctx)

                    styles.colors.slider_grab = ShowColorEditor("Slider Grab", styles.colors.slider_grab, "colors.slider_grab")
                    styles.colors.slider_grab_active = ShowColorEditor("Slider Grab Active", styles.colors.slider_grab_active, "colors.slider_grab_active")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Checkboxes")
                    r.ImGui_Separator(ctx)

                    styles.colors.checkmark = ShowColorEditor("Check Mark", styles.colors.checkmark, "colors.checkmark")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Separators")
                    r.ImGui_Separator(ctx)

                    styles.colors.separator = ShowColorEditor("Separator", styles.colors.separator, "colors.separator")
                    styles.colors.separator_hovered = ShowColorEditor("Separator Hovered", styles.colors.separator_hovered, "colors.separator_hovered")
                    styles.colors.separator_active = ShowColorEditor("Separator Active", styles.colors.separator_active, "colors.separator_active")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Menu & Navigation")
                    r.ImGui_Separator(ctx)

                    styles.colors.menu_bar_bg = ShowColorEditor("Menu Bar Background", styles.colors.menu_bar_bg, "colors.menu_bar_bg")
                    styles.colors.text_selected_bg = ShowColorEditor("Text Selected BG", styles.colors.text_selected_bg, "colors.text_selected_bg")
                    styles.colors.nav_highlight = ShowColorEditor("Nav Highlight", styles.colors.nav_highlight, "colors.nav_highlight")
                    styles.colors.nav_windowing_highlight = ShowColorEditor("Nav Windowing Highlight", styles.colors.nav_windowing_highlight, "colors.nav_windowing_highlight")
                    styles.colors.nav_windowing_dim_bg = ShowColorEditor("Nav Windowing Dim BG", styles.colors.nav_windowing_dim_bg, "colors.nav_windowing_dim_bg")

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Special")
                    r.ImGui_Separator(ctx)

                    styles.colors.child_bg = ShowColorEditor("Child Window BG", styles.colors.child_bg, "colors.child_bg")
                    styles.colors.popup_bg = ShowColorEditor("Popup Background", styles.colors.popup_bg, "colors.popup_bg")
                    styles.colors.modal_window_dim_bg = ShowColorEditor("Modal Dim BG", styles.colors.modal_window_dim_bg, "colors.modal_window_dim_bg")
                    styles.colors.drag_drop_target = ShowColorEditor("Drag Drop Target", styles.colors.drag_drop_target, "colors.drag_drop_target")
                    styles.colors.resize_grip = ShowColorEditor("Resize Grip", styles.colors.resize_grip, "colors.resize_grip")
                    styles.colors.resize_grip_active = ShowColorEditor("Resize Grip Active", styles.colors.resize_grip_active, "colors.resize_grip_active")
                    styles.colors.resize_grip_hovered = ShowColorEditor("Resize Grip Hovered", styles.colors.resize_grip_hovered, "colors.resize_grip_hovered")
                    r.ImGui_EndTabItem(ctx)
                end

                if r.ImGui_BeginTabItem(ctx, "Fonts") then
                    r.ImGui_Spacing(ctx)

                    r.ImGui_Text(ctx, "Main Font")
                    if r.ImGui_BeginCombo(ctx, "Main Font Family", styles.fonts.main.name) then
                        for _, fontname in ipairs({ "Calibri", "sans-serif", "serif", "monospace", "Arial", "Verdana", "Times New Roman", "Courier New" }) do
                            if r.ImGui_Selectable(ctx, fontname, styles.fonts.main.name == fontname) then
                                styles.fonts.main.name = fontname
                                state.font_update_pending = true
                                SaveSettings()
                            end
                        end
                        r.ImGui_EndCombo(ctx)
                    end

                    local changed, new_size = r.ImGui_SliderInt(ctx, "Main Font Size", styles.fonts.main.size, 8, 32)
                    if changed then
                        styles.fonts.main.size = new_size
                        state.font_update_pending = true
                        SaveSettings()
                    end

                    r.ImGui_Spacing(ctx)

                    r.ImGui_Text(ctx, "Header Font")
                    if r.ImGui_BeginCombo(ctx, "Header Font Family", styles.fonts.header.name) then
                        for _, fontname in ipairs({ "Calibri", "sans-serif", "serif", "monospace", "Arial", "Verdana", "Times New Roman", "Courier New" }) do
                            if r.ImGui_Selectable(ctx, fontname, styles.fonts.header.name == fontname) then
                                styles.fonts.header.name = fontname
                                state.font_update_pending = true
                                SaveSettings()
                            end
                        end
                        r.ImGui_EndCombo(ctx)
                    end

                    changed, new_size = r.ImGui_SliderInt(ctx, "Header Font Size", styles.fonts.header.size, 8, 32)
                    if changed then
                        styles.fonts.header.size = new_size
                        state.font_update_pending = true
                        SaveSettings()
                    end

                    r.ImGui_Spacing(ctx)

                    r.ImGui_Text(ctx, "Monospace Font")
                    if r.ImGui_BeginCombo(ctx, "Mono Font Family", styles.fonts.mono.name) then
                        for _, fontname in ipairs({ "monospace", "Consolas", "Courier New", "Lucida Console" }) do
                            if r.ImGui_Selectable(ctx, fontname, styles.fonts.mono.name == fontname) then
                                styles.fonts.mono.name = fontname
                                state.font_update_pending = true
                                SaveSettings()
                            end
                        end
                        r.ImGui_EndCombo(ctx)
                    end

                    changed, new_size = r.ImGui_SliderInt(ctx, "Mono Font Size", styles.fonts.mono.size, 8, 32)
                    if changed then
                        styles.fonts.mono.size = new_size
                        state.font_update_pending = true
                        SaveSettings()
                    end

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Separator(ctx)
                    r.ImGui_Spacing(ctx)

                    if r.ImGui_Button(ctx, "Apply Font Changes Now") then
                        state.font_update_pending = true
                        SaveSettings()
                        state.debug_info = "Fonts will be updated on next frame"
                    end

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Separator(ctx)
                    r.ImGui_Text(ctx, "Font Samples:")
                    r.ImGui_Spacing(ctx)

                    if style_loader and style_loader.PushFont(ctx, "main") then
                        r.ImGui_Text(ctx, "Main font sample text - " .. styles.fonts.main.name)
                        style_loader.PopFont(ctx)
                    else
                        r.ImGui_Text(ctx, "Main font not available")
                    end

                    if style_loader and style_loader.PushFont(ctx, "header") then
                        r.ImGui_Text(ctx, "Header font sample - " .. styles.fonts.header.name)
                        style_loader.PopFont(ctx)
                    else
                        r.ImGui_Text(ctx, "Header font not available")
                    end

                    if style_loader and style_loader.PushFont(ctx, "mono") then
                        r.ImGui_Text(ctx, "Monospace font sample - " .. styles.fonts.mono.name)
                        style_loader.PopFont(ctx)
                    else
                        r.ImGui_Text(ctx, "Mono font not available")
                    end

                    r.ImGui_EndTabItem(ctx)
                end

                if r.ImGui_BeginTabItem(ctx, "Layout") then
                    local window_width = r.ImGui_GetContentRegionAvail(ctx)

                    r.ImGui_Text(ctx, "Spacing")
                    r.ImGui_Separator(ctx)

                    local chg, new_val

                    chg, new_val = r.ImGui_SliderInt(ctx, "Item Spacing X", styles.spacing.item_spacing_x, 0, 20)
                    if chg then styles.spacing.item_spacing_x = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Item Spacing Y", styles.spacing.item_spacing_y, 0, 20)
                    if chg then styles.spacing.item_spacing_y = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Frame Padding X", styles.spacing.frame_padding_x, 0, 20)
                    if chg then styles.spacing.frame_padding_x = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Frame Padding Y", styles.spacing.frame_padding_y, 0, 20)
                    if chg then styles.spacing.frame_padding_y = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Window Padding X", styles.spacing.window_padding_x, 0, 20)
                    if chg then styles.spacing.window_padding_x = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Window Padding Y", styles.spacing.window_padding_y, 0, 20)
                    if chg then styles.spacing.window_padding_y = new_val end

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Separator(ctx)
                    r.ImGui_Spacing(ctx)

                    r.ImGui_Text(ctx, "Borders")
                    r.ImGui_Separator(ctx)

                    chg, new_val = r.ImGui_SliderInt(ctx, "Window Border", styles.borders.window_border_size, 0, 3)
                    if chg then styles.borders.window_border_size = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Frame Border", styles.borders.frame_border_size, 0, 3)
                    if chg then styles.borders.frame_border_size = new_val end

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Separator(ctx)
                    r.ImGui_Spacing(ctx)

                    r.ImGui_Text(ctx, "Rounding")
                    r.ImGui_Separator(ctx)

                    chg, new_val = r.ImGui_SliderInt(ctx, "Window Rounding", styles.rounding.window_rounding, 0, 20)
                    if chg then styles.rounding.window_rounding = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Frame Rounding", styles.rounding.frame_rounding, 0, 20)
                    if chg then styles.rounding.frame_rounding = new_val end

                    chg, new_val = r.ImGui_SliderInt(ctx, "Grab Rounding", styles.rounding.grab_rounding, 0, 20)
                    if chg then styles.rounding.grab_rounding = new_val end

                    r.ImGui_Spacing(ctx)
                    r.ImGui_Separator(ctx)
                    r.ImGui_Spacing(ctx)

                    r.ImGui_Text(ctx, "Sliders")
                    r.ImGui_Separator(ctx)

                    chg, new_val = r.ImGui_SliderInt(ctx, "Grab Min Size", styles.sliders.grab_min_size, 14, 68)
                    if chg then styles.sliders.grab_min_size = new_val end

                    r.ImGui_EndTabItem(ctx)
                end

                if r.ImGui_BeginTabItem(ctx, "Preview") then
                    r.ImGui_Spacing(ctx)
                    ShowPreviewPanel()
                    r.ImGui_EndTabItem(ctx)
                end

                if r.ImGui_BeginTabItem(ctx, "Export") then
                    r.ImGui_Spacing(ctx)
                    r.ImGui_Text(ctx, "Export Current Colors")
                    r.ImGui_Separator(ctx)

                    if r.ImGui_Button(ctx, "Export Colors to File") then
                        ExportColorsToFile()
                    end

                    if state.debug_info:find("exported") then
                        r.ImGui_Spacing(ctx)
                        r.ImGui_TextWrapped(ctx, "Colors have been exported as Lua code. You can copy this code and replace the default_colors table in your script.")
                    end

                    r.ImGui_EndTabItem(ctx)
                end

                r.ImGui_EndTabBar(ctx)
            else
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

            style_loader.PopFont(ctx)
            end
            r.ImGui_EndChild(ctx)
        end
        r.ImGui_End(ctx)
    end

    ClearStyle()

    r.PreventUIRefresh(-1)

    if open then
        r.defer(MainLoop)
    else
        SaveSettings()
    end
end

function ToggleScript()
    local _, _, section_id, command_id = r.get_action_context()
    local script_state = r.GetToggleCommandState(command_id)
    
    if script_state == -1 or script_state == 0 then
        r.SetToggleCommandState(section_id, command_id, 1)
        r.RefreshToolbar2(section_id, command_id)
        Start()
    else
        r.SetToggleCommandState(section_id, command_id, 0)
        r.RefreshToolbar2(section_id, command_id)
        Stop()
    end
end

function Start()
    LoadSettings()
    Init()
    MainLoop()
end

function Stop()
    SaveSettings()
    Cleanup()
end

function Cleanup()
    local _, _, section_id, command_id = r.get_action_context()
    r.SetToggleCommandState(section_id, command_id, 0)
    r.RefreshToolbar2(section_id, command_id)
end

function Exit()
    SaveSettings()
    Cleanup()
end

r.atexit(Exit)
ToggleScript()