-- @description ProjectNoteEditor - Settings
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper

local sl = nil
local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp) then local lf = dofile(sp) if lf then sl = lf() end end

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

local ctx = r.ImGui_CreateContext('Project Notes Editor - Settings')
local pc, pv = 0, 0

if sl then sl.applyFontsToContext(ctx) end

local colors = {
    bg_color = 0x1a1a1a,
    text_color = 0xe6e6e6,
    button_color = 0x333333,
    button_hover_color = 0x4d4d4d,
    button_active_color = 0x666666,
    editor_bg_color = 0x1a1a1a,
    editor_border_color = 0x808080,
    selection_color = 0x3874cb,
}

local color_labels = {
    {key="bg_color", name="Background"},
    {key="text_color", name="Text"},
    {key="button_color", name="Button"},
    {key="button_hover_color", name="Button Hover"},
    {key="button_active_color", name="Button Active"},
    {key="editor_bg_color", name="Editor Background"},
    {key="editor_border_color", name="Editor Border"},
    {key="selection_color", name="Text Selection"},
}

local default_presets = {
    {
        name = "Dark",
        colors = {
            bg_color = 0x282828,
            text_color = 0xe6e6e6,
            button_color = 0x333333,
            button_hover_color = 0x4d4d4d,
            button_active_color = 0x666666,
            editor_bg_color = 0x282828,
            editor_border_color = 0x808080,
            selection_color = 0x3874cb
        }
    },
    {
        name = "Light",
        colors = {
            bg_color = 0xf0f0f0,
            text_color = 0x333333,
            button_color = 0xdddddd,
            button_hover_color = 0xcccccc,
            button_active_color = 0xbbbbbb,
            editor_bg_color = 0xffffff,
            editor_border_color = 0x999999,
            selection_color = 0x0078d4
        }
    },
    {
        name = "Blue",
        colors = {
            bg_color = 0x1e2428,
            text_color = 0xddeeff,
            button_color = 0x2d3e50,
            button_hover_color = 0x34495e,
            button_active_color = 0x3b526b,
            editor_bg_color = 0x1e2428,
            editor_border_color = 0x5a6c7d,
            selection_color = 0x3498db
        }
    },
    {
        name = "Green",
        colors = {
            bg_color = 0x1a2b1a,
            text_color = 0xddffdd,
            button_color = 0x2e4a2e,
            button_hover_color = 0x3a5a3a,
            button_active_color = 0x466a46,
            editor_bg_color = 0x1a2b1a,
            editor_border_color = 0x5a7a5a,
            selection_color = 0x27ae60
        }
    }
}

local presets = {}
local current_preset = "Dark"
local selected_preset = ""
local show_preset_rename = false
local rename_preset_name = ""
local preset_name_input = "My Custom Preset"

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

function LoadColors()
    for _, info in ipairs(color_labels) do
        local saved = tonumber(r.GetExtState("CP_ProjectNoteEditor", info.key))
        if saved then colors[info.key] = saved end
    end
    
    local saved_preset = r.GetExtState("CP_ProjectNoteEditor", "current_preset")
    if saved_preset ~= "" then current_preset = saved_preset end
    
    local saved_presets = r.GetExtState("CP_ProjectNoteEditor", "presets")
    if saved_presets ~= "" then
        local success, loaded_presets = pcall(function() return load("return " .. saved_presets)() end)
        if success and loaded_presets then
            presets = loaded_presets
        end
    end
    
    if not presets["Dark"] then
        for _, preset in ipairs(default_presets) do
            presets[preset.name] = deepcopy(preset.colors)
        end
    end
end

function SaveColors()
    for _, info in ipairs(color_labels) do
        r.SetExtState("CP_ProjectNoteEditor", info.key, tostring(colors[info.key]), true)
    end
    
    r.SetExtState("CP_ProjectNoteEditor", "current_preset", current_preset, true)
    
    local serialized_presets = r.serialize(presets)
    r.SetExtState("CP_ProjectNoteEditor", "presets", serialized_presets, true)
end

function SavePreset(name)
    if name == "" then return end
    presets[name] = deepcopy(colors)
    SaveColors()
end

function LoadPreset(name)
    if presets[name] then
        colors = deepcopy(presets[name])
        current_preset = name
        SaveColors()
    end
end

function DeletePreset(name)
    if presets[name] and name ~= "Dark" then
        presets[name] = nil
        if current_preset == name then
            current_preset = "Dark"
        end
        SaveColors()
    end
end

function RenamePreset(old_name, new_name)
    if presets[old_name] and new_name ~= "" and old_name ~= new_name and old_name ~= "Dark" then
        presets[new_name] = presets[old_name]
        presets[old_name] = nil
        if current_preset == old_name then
            current_preset = new_name
        end
        SaveColors()
    end
end

function ApplyPreset(name)
    if presets[name] then
        colors = deepcopy(presets[name])
        current_preset = name
        SaveColors()
    end
end

function ColorToImGui(color)
    local r = (color >> 16) & 0xFF
    local g = (color >> 8) & 0xFF
    local b = color & 0xFF
    return (r << 16) | (g << 8) | b
end

function ImGuiToColor(color)
    local r = (color >> 16) & 0xFF
    local g = (color >> 8) & 0xFF
    local b = color & 0xFF
    return (r << 16) | (g << 8) | b | 0xFF000000
end

function loop()
    LoadColors()
    
    if sl then
        local success, color_count, var_count = sl.applyToContext(ctx)
        if success then pc, pv = color_count, var_count end
    end
    
    local main_font = sl and sl.getFont(ctx, "main")
    local header_font = sl and sl.getFont(ctx, "header")
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    local visible, open = r.ImGui_Begin(ctx, 'Project Notes Editor - Settings', true, window_flags)
    
    if visible then
        if header_font then r.ImGui_PushFont(ctx, header_font) end
        r.ImGui_Text(ctx, "Project Notes Editor - Settings")
        if header_font then r.ImGui_PopFont(ctx) end
        if main_font then r.ImGui_PushFont(ctx, main_font) end
        
        r.ImGui_SameLine(ctx)
        local close_x = r.ImGui_GetWindowWidth(ctx) - 30
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", 22, 22) then
            open = false
        end
        
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        if r.ImGui_BeginTabBar(ctx, "SettingsTabs") then
            if r.ImGui_BeginTabItem(ctx, "Themes") then
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Choose a preset theme:")
                r.ImGui_Spacing(ctx)
                
                for name, preset_colors in pairs(presets) do
                    if r.ImGui_Button(ctx, name, 120, 25) then
                        ApplyPreset(name)
                        selected_preset = name
                    end
                    r.ImGui_SameLine(ctx)
                end
                r.ImGui_NewLine(ctx)
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                r.ImGui_Text(ctx, "Current Preset: " .. current_preset)
                r.ImGui_Spacing(ctx)
                
                r.ImGui_Text(ctx, "Custom Presets:")
                r.ImGui_Spacing(ctx)
                
                if r.ImGui_Button(ctx, "Save", 80) then
                    SavePreset(current_preset)
                end
                
                r.ImGui_SameLine(ctx)
                r.ImGui_SetNextItemWidth(ctx, 200)
                local rv, new_name = r.ImGui_InputText(ctx, "Preset Name", preset_name_input)
                if rv then preset_name_input = new_name end
                
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Save As", 80) then
                    if preset_name_input and preset_name_input ~= "" then
                        SavePreset(preset_name_input)
                        current_preset = preset_name_input
                        preset_name_input = ""
                    end
                end
                
                r.ImGui_Spacing(ctx)
                
                if r.ImGui_BeginChild(ctx, "PresetList", -1, 120) then
                    for name, _ in pairs(presets) do
                        r.ImGui_PushID(ctx, name)
                        if r.ImGui_Button(ctx, name, 150, 25) then
                            LoadPreset(name)
                            selected_preset = name
                        end
                        r.ImGui_SameLine(ctx)
                        if name ~= "Dark" then
                            if r.ImGui_Button(ctx, "R", 25, 25) then
                                show_preset_rename = true
                                rename_preset_name = name
                                selected_preset = name
                            end
                            r.ImGui_SameLine(ctx)
                            if r.ImGui_Button(ctx, "X", 25, 25) then
                                DeletePreset(name)
                            end
                        end
                        r.ImGui_PopID(ctx)
                    end
                    r.ImGui_EndChild(ctx)
                end
                
                if show_preset_rename then
                    r.ImGui_OpenPopup(ctx, "Rename Preset")
                end
                
                if r.ImGui_BeginPopupModal(ctx, "Rename Preset", nil, r.ImGui_WindowFlags_AlwaysAutoResize()) then
                    local changed, new_name = r.ImGui_InputText(ctx, "New Name", rename_preset_name)
                    if changed then rename_preset_name = new_name end
                    
                    if r.ImGui_Button(ctx, "OK", 120, 0) then
                        RenamePreset(selected_preset, rename_preset_name)
                        show_preset_rename = false
                        r.ImGui_CloseCurrentPopup(ctx)
                    end
                    r.ImGui_SameLine(ctx)
                    if r.ImGui_Button(ctx, "Cancel", 120, 0) then
                        show_preset_rename = false
                        r.ImGui_CloseCurrentPopup(ctx)
                    end
                    r.ImGui_EndPopup(ctx)
                end
                
                r.ImGui_EndTabItem(ctx)
            end
            
            if r.ImGui_BeginTabItem(ctx, "Colors") then
                r.ImGui_Spacing(ctx)
                
                for _, info in ipairs(color_labels) do
                    local imgui_color = ColorToImGui(colors[info.key])
                    local changed, new_color = r.ImGui_ColorEdit3(ctx, info.name, imgui_color)
                    if changed then
                        colors[info.key] = ImGuiToColor(new_color)
                        SaveColors()
                    end
                end
                
                r.ImGui_EndTabItem(ctx)
            end
            
            r.ImGui_EndTabBar(ctx)
        end
        
        if main_font then r.ImGui_PopFont(ctx) end
        r.ImGui_End(ctx)
    end
    
    if sl then sl.clearStyles(ctx, pc, pv) end
    
    if open then
        r.defer(loop)
    else
        SaveColors()
    end
end

function init()
    LoadColors()
    r.ImGui_SetNextWindowPos(ctx, 200, 200, r.ImGui_Cond_FirstUseEver())
    r.ImGui_SetNextWindowSize(ctx, 400, 500, r.ImGui_Cond_FirstUseEver())
    loop()
end

init()









