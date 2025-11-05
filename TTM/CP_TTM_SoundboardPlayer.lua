local r = reaper

local script_name = "CP_TTM_SoundboardPlayer"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('TTM Soundboard Player')
local pushed_colors = 0
local pushed_vars = 0

if style_loader then 
    style_loader.ApplyFontsToContext(ctx) 
end

local config = {
    window_width = 800,
    window_height = 600,
    grid_cols = 4,
    grid_rows = 4,
    pad_size = 120,
    current_page = 1,
    master_volume = 1.0,
    auto_stop_one_shots = true,
}

local state = {
    window_position_set = false,
    pages = {},
    playing_sources = {},
    textures = {},
    hovered_pad = nil,
    dragging_file = false,
    right_click_pad = nil,
}

local PlayMode = {
    ONE_SHOT = 1,
    LOOP = 2,
    TOGGLE = 3,
    FADE_IN = 4,
}

function GetStyleValue(path, default_value)
    if style_loader then
        return style_loader.GetValue(path, default_value)
    end
    return default_value
end

function ApplyStyle()
    if style_loader then
        local success, colors, vars = style_loader.ApplyToContext(ctx)
        if success then 
            pushed_colors = colors
            pushed_vars = vars
            return true
        end
    end
    return false
end

function ClearStyle()
    if style_loader then 
        style_loader.ClearStyles(ctx, pushed_colors, pushed_vars)
    end
end

function InitializePages()
    if #state.pages == 0 then
        for i = 1, 5 do
            local page = {
                name = "Page " .. i,
                pads = {}
            }
            for j = 1, config.grid_cols * config.grid_rows do
                table.insert(page.pads, {
                    file_path = "",
                    name = "",
                    color = 0x808080FF,
                    image_path = "",
                    mode = PlayMode.ONE_SHOT,
                    volume = 1.0,
                    playing = false,
                    source = nil,
                })
            end
            table.insert(state.pages, page)
        end
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
    
    r.SetExtState(script_name, "pages_count", tostring(#state.pages), true)
    for page_idx, page in ipairs(state.pages) do
        r.SetExtState(script_name, "page_" .. page_idx .. "_name", page.name, true)
        for pad_idx, pad in ipairs(page.pads) do
            local prefix = "page_" .. page_idx .. "_pad_" .. pad_idx .. "_"
            r.SetExtState(script_name, prefix .. "file", pad.file_path, true)
            r.SetExtState(script_name, prefix .. "name", pad.name, true)
            r.SetExtState(script_name, prefix .. "color", tostring(pad.color), true)
            r.SetExtState(script_name, prefix .. "image", pad.image_path, true)
            r.SetExtState(script_name, prefix .. "mode", tostring(pad.mode), true)
            r.SetExtState(script_name, prefix .. "volume", tostring(pad.volume), true)
        end
    end
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
    
    local pages_count_str = r.GetExtState(script_name, "pages_count")
    local pages_count = tonumber(pages_count_str) or 0
    
    if pages_count > 0 then
        state.pages = {}
        for page_idx = 1, pages_count do
            local page_name = r.GetExtState(script_name, "page_" .. page_idx .. "_name")
            if page_name == "" then
                page_name = "Page " .. page_idx
            end
            
            local page = {
                name = page_name,
                pads = {}
            }
            
            for pad_idx = 1, config.grid_cols * config.grid_rows do
                local prefix = "page_" .. page_idx .. "_pad_" .. pad_idx .. "_"
                local file_path = r.GetExtState(script_name, prefix .. "file")
                local name = r.GetExtState(script_name, prefix .. "name")
                local color = tonumber(r.GetExtState(script_name, prefix .. "color")) or 0x808080FF
                local image_path = r.GetExtState(script_name, prefix .. "image")
                local mode = tonumber(r.GetExtState(script_name, prefix .. "mode")) or PlayMode.ONE_SHOT
                local volume = tonumber(r.GetExtState(script_name, prefix .. "volume")) or 1.0
                
                table.insert(page.pads, {
                    file_path = file_path,
                    name = name,
                    color = color,
                    image_path = image_path,
                    mode = mode,
                    volume = volume,
                    playing = false,
                    source = nil,
                })
            end
            
            table.insert(state.pages, page)
        end
    else
        InitializePages()
    end
end

function LoadTexture(image_path)
    if image_path == "" or not r.file_exists(image_path) then
        return nil
    end
    
    if state.textures[image_path] then
        return state.textures[image_path]
    end
    
    local texture = r.ImGui_CreateImage(image_path)
    if texture then
        state.textures[image_path] = texture
    end
    return texture
end

function PlayPad(pad)
    if pad.file_path == "" or not r.file_exists(pad.file_path) then
        return
    end
    
    if pad.mode == PlayMode.TOGGLE and pad.playing then
        StopPad(pad)
        return
    end
    
    if pad.mode == PlayMode.ONE_SHOT and pad.playing then
        StopPad(pad)
    end
    
    local source = r.PCM_Source_CreateFromFile(pad.file_path)
    if source then
        local is_looping = (pad.mode == PlayMode.LOOP or pad.mode == PlayMode.TOGGLE)
        local preview = r.Preview_CreateEx(source, is_looping)
        
        if preview then
            r.Preview_SetValue(preview, "D_VOLUME", pad.volume * config.master_volume)
            r.Preview_SetValue(preview, "B_PPITCH", 0)
            
            pad.source = {preview = preview, pcm = source}
            pad.playing = true
            table.insert(state.playing_sources, pad)
        end
    end
end

function StopPad(pad)
    if pad.source then
        if pad.source.preview then
            r.Preview_Delete(pad.source.preview)
        end
        if pad.source.pcm then
            r.PCM_Source_Destroy(pad.source.pcm)
        end
        pad.source = nil
        pad.playing = false
        
        for i = #state.playing_sources, 1, -1 do
            if state.playing_sources[i] == pad then
                table.remove(state.playing_sources, i)
                break
            end
        end
    end
end

function StopAllPads()
    for _, page in ipairs(state.pages) do
        for _, pad in ipairs(page.pads) do
            if pad.playing then
                StopPad(pad)
            end
        end
    end
end

function UpdatePlayingPads()
    for i = #state.playing_sources, 1, -1 do
        local pad = state.playing_sources[i]
        if pad.source and pad.source.preview then
            local playstate = r.Preview_GetValue(pad.source.preview, "I_PLAYSTATE")
            if playstate == 0 and pad.mode == PlayMode.ONE_SHOT then
                if config.auto_stop_one_shots then
                    StopPad(pad)
                end
            end
        else
            if pad.source then
                StopPad(pad)
            else
                pad.playing = false
                pad.source = nil
                table.remove(state.playing_sources, i)
            end
        end
    end
end

function DrawPad(pad, index)
    local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
    local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
    
    local button_pressed = false
    local right_clicked = false
    local dropped_file = nil
    
    r.ImGui_PushID(ctx, index)
    
    local pad_color = pad.color
    if pad.playing then
        local time = r.time_precise()
        local pulse = math.abs(math.sin(time * 3))
        local base_r = ((pad_color >> 24) & 0xFF) / 255
        local base_g = ((pad_color >> 16) & 0xFF) / 255
        local base_b = ((pad_color >> 8) & 0xFF) / 255
        local bright = 0.3 + pulse * 0.7
        pad_color = (math.floor(base_r * bright * 255) << 24) | 
                    (math.floor(base_g * bright * 255) << 16) | 
                    (math.floor(base_b * bright * 255) << 8) | 
                    0xFF
    end
    
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), pad_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), pad_color | 0xFFFFFF33)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), pad_color | 0xFFFFFF66)
    
    local cursor_x, cursor_y = r.ImGui_GetCursorPos(ctx)
    
    if r.ImGui_Button(ctx, "##pad", config.pad_size, config.pad_size) then
        button_pressed = true
    end
    
    if r.ImGui_IsItemHovered(ctx) then
        state.hovered_pad = index
        if r.ImGui_IsMouseClicked(ctx, 1) then
            right_clicked = true
        end
    end
    
    if r.ImGui_BeginDragDropTarget(ctx) then
        local ret, payload = r.ImGui_AcceptDragDropPayload(ctx, "DND_FILE")
        if ret then
            dropped_file = payload
        end
        r.ImGui_EndDragDropTarget(ctx)
    end
    
    r.ImGui_PopStyleColor(ctx, 3)
    
    r.ImGui_SetCursorPos(ctx, cursor_x, cursor_y)
    
    if pad.image_path ~= "" then
        local texture = LoadTexture(pad.image_path)
        if texture then
            r.ImGui_Image(ctx, texture, config.pad_size, config.pad_size)
        end
    end
    
    if pad.name ~= "" then
        r.ImGui_SetCursorPos(ctx, cursor_x + 5, cursor_y + config.pad_size - 25)
        
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), 0x000000AA)
        
        if r.ImGui_BeginChild(ctx, "label_" .. index, config.pad_size - 10, 20, r.ImGui_ChildFlags_None()) then
            local text_width = r.ImGui_CalcTextSize(ctx, pad.name)
            r.ImGui_SetCursorPosX(ctx, (config.pad_size - 10 - text_width) / 2)
            r.ImGui_Text(ctx, pad.name)
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_PopStyleColor(ctx, 2)
    end
    
    r.ImGui_PopID(ctx)
    
    return button_pressed, right_clicked, dropped_file
end

function DrawPadGrid()
    local current_page = state.pages[config.current_page]
    if not current_page then return end
    
    local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
    local item_spacing_y = GetStyleValue("spacing.item_spacing_y", 6)
    
    for row = 0, config.grid_rows - 1 do
        for col = 0, config.grid_cols - 1 do
            local index = row * config.grid_cols + col + 1
            local pad = current_page.pads[index]
            
            if pad then
                local button_pressed, right_clicked, dropped_file = DrawPad(pad, index)
                
                if button_pressed then
                    PlayPad(pad)
                end
                
                if right_clicked then
                    state.right_click_pad = {page = config.current_page, index = index}
                    r.ImGui_OpenPopup(ctx, "PadContextMenu")
                end
                
                if dropped_file then
                    local ext = dropped_file:match("%.([^%.]+)$")
                    if ext then
                        ext = ext:lower()
                        if ext == "wav" or ext == "mp3" or ext == "flac" or ext == "ogg" or ext == "aiff" or ext == "aif" then
                            pad.file_path = dropped_file
                            if pad.name == "" then
                                pad.name = dropped_file:match("([^/\\]+)$"):match("(.+)%..+$") or ""
                            end
                        elseif ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "bmp" then
                            pad.image_path = dropped_file
                        end
                    end
                end
                
                if col < config.grid_cols - 1 then
                    r.ImGui_SameLine(ctx, 0, item_spacing_x)
                end
            end
        end
    end
end

function DrawPadContextMenu()
    if r.ImGui_BeginPopup(ctx, "PadContextMenu") then
        if state.right_click_pad then
            local page = state.pages[state.right_click_pad.page]
            local pad = page.pads[state.right_click_pad.index]
            
            if r.ImGui_MenuItem(ctx, "Assign Audio File...") then
                local retval, file_path = r.GetUserFileNameForRead("", "Select Audio File", "*.wav;*.mp3;*.flac;*.ogg;*.aiff;*.aif")
                if retval then
                    pad.file_path = file_path
                    if pad.name == "" then
                        pad.name = file_path:match("([^/\\]+)$"):match("(.+)%..+$") or ""
                    end
                end
            end
            
            if r.ImGui_MenuItem(ctx, "Assign Image...") then
                local retval, image_path = r.GetUserFileNameForRead("", "Select Image", "*.png;*.jpg;*.jpeg;*.bmp")
                if retval then
                    pad.image_path = image_path
                end
            end
            
            if r.ImGui_MenuItem(ctx, "Edit Name...") then
                r.ImGui_OpenPopup(ctx, "EditPadName")
            end
            
            if r.ImGui_BeginMenu(ctx, "Play Mode") then
                if r.ImGui_MenuItem(ctx, "One-Shot", nil, pad.mode == PlayMode.ONE_SHOT) then
                    pad.mode = PlayMode.ONE_SHOT
                end
                if r.ImGui_MenuItem(ctx, "Loop", nil, pad.mode == PlayMode.LOOP) then
                    pad.mode = PlayMode.LOOP
                end
                if r.ImGui_MenuItem(ctx, "Toggle", nil, pad.mode == PlayMode.TOGGLE) then
                    pad.mode = PlayMode.TOGGLE
                end
                r.ImGui_EndMenu(ctx)
            end
            
            if r.ImGui_MenuItem(ctx, "Clear Pad") then
                pad.file_path = ""
                pad.name = ""
                pad.image_path = ""
                pad.color = 0x808080FF
            end
        end
        
        r.ImGui_EndPopup(ctx)
    end
    
    if r.ImGui_BeginPopupModal(ctx, "EditPadName", nil, r.ImGui_WindowFlags_AlwaysAutoResize()) then
        if state.right_click_pad then
            local page = state.pages[state.right_click_pad.page]
            local pad = page.pads[state.right_click_pad.index]
            
            r.ImGui_Text(ctx, "Pad Name:")
            local retval, new_name = r.ImGui_InputText(ctx, "##name", pad.name, r.ImGui_InputTextFlags_EnterReturnsTrue())
            if retval then
                pad.name = new_name
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            if r.ImGui_Button(ctx, "OK", 80) then
                r.ImGui_CloseCurrentPopup(ctx)
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Cancel", 80) then
                r.ImGui_CloseCurrentPopup(ctx)
            end
        end
        
        r.ImGui_EndPopup(ctx)
    end
end

function DrawControlPanel()
    local item_spacing_x = GetStyleValue("spacing.item_spacing_x", 6)
    
    r.ImGui_Text(ctx, "Page:")
    r.ImGui_SameLine(ctx)
    
    r.ImGui_PushItemWidth(ctx, 150)
    local page_names = {}
    for i, page in ipairs(state.pages) do
        table.insert(page_names, page.name)
    end
    local items_string = table.concat(page_names, "\0") .. "\0"
    local changed, new_page = r.ImGui_Combo(ctx, "##page", config.current_page - 1, items_string)
    r.ImGui_PopItemWidth(ctx)
    
    if changed then
        config.current_page = new_page + 1
    end
    
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Rename Page") then
        r.ImGui_OpenPopup(ctx, "RenamePageModal")
    end
    
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, "Master Vol:")
    r.ImGui_SameLine(ctx)
    r.ImGui_PushItemWidth(ctx, 100)
    local vol_changed, new_vol = r.ImGui_SliderDouble(ctx, "##master_vol", config.master_volume, 0.0, 2.0, "%.2f")
    r.ImGui_PopItemWidth(ctx)
    if vol_changed then
        config.master_volume = new_vol
    end
    
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Stop All") then
        StopAllPads()
    end
    
    if r.ImGui_BeginPopupModal(ctx, "RenamePageModal", nil, r.ImGui_WindowFlags_AlwaysAutoResize()) then
        local current_page = state.pages[config.current_page]
        if current_page then
            r.ImGui_Text(ctx, "Page Name:")
            local retval, new_name = r.ImGui_InputText(ctx, "##pagename", current_page.name, r.ImGui_InputTextFlags_EnterReturnsTrue())
            if retval then
                current_page.name = new_name
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            if r.ImGui_Button(ctx, "OK", 80) then
                r.ImGui_CloseCurrentPopup(ctx)
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Cancel", 80) then
                r.ImGui_CloseCurrentPopup(ctx)
            end
        end
        
        r.ImGui_EndPopup(ctx)
    end
end

function MainLoop()
    ApplyStyle()
    
    local window_flags = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoCollapse()
    r.ImGui_SetNextWindowSize(ctx, config.window_width, config.window_height, r.ImGui_Cond_FirstUseEver())
    
    local visible, open = r.ImGui_Begin(ctx, 'TTM Soundboard Player', true, window_flags)
    if visible then
        if style_loader and style_loader.PushFont(ctx, "header") then
            r.ImGui_Text(ctx, "TTM Soundboard Player")
            style_loader.PopFont(ctx)
        else
            r.ImGui_Text(ctx, "TTM Soundboard Player")
        end

        r.ImGui_SameLine(ctx)
        local header_font_size = GetStyleValue("fonts.header.size", 16)
        local window_padding_x = GetStyleValue("spacing.window_padding_x", 8)
        local close_button_size = header_font_size + 6
        local close_x = r.ImGui_GetWindowWidth(ctx) - close_button_size - window_padding_x
        r.ImGui_SetCursorPosX(ctx, close_x)
        if r.ImGui_Button(ctx, "X", close_button_size, close_button_size) then
            open = false
        end

        if style_loader and style_loader.PushFont(ctx, "main") then
            
            r.ImGui_Separator(ctx)
            
            DrawControlPanel()
            
            r.ImGui_Separator(ctx)
            
            DrawPadGrid()
            
            DrawPadContextMenu()
            
            UpdatePlayingPads()
            
            style_loader.PopFont(ctx)
        else
            
            r.ImGui_Separator(ctx)
            
            DrawControlPanel()
            
            r.ImGui_Separator(ctx)
            
            DrawPadGrid()
            
            DrawPadContextMenu()
            
            UpdatePlayingPads()
            
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
    InitializePages()
    MainLoop()
end

function Stop()
    StopAllPads()
    SaveSettings()
    Cleanup()
end

function Cleanup()
    for _, texture in pairs(state.textures) do
        if texture then
            r.ImGui_DestroyImage(ctx, texture)
        end
    end
    state.textures = {}
    
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