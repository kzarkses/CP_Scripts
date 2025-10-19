local r = reaper

local script_name = "Test_StyleLoader"
local style_loader = nil
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(style_loader_path) then 
    local loader_func = dofile(style_loader_path)
    if loader_func then 
        style_loader = loader_func() 
    end 
end

local ctx = r.ImGui_CreateContext('Test StyleLoader')
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

function GetFont(font_name)
    if style_loader then
        return style_loader.GetFont(ctx, font_name)
    end
    return nil
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

function MainLoop()
    ApplyStyle()
    
    -- TEST DEBUG - Vérifier ce que GetFont retourne
    local header_font = GetFont("header")
    local main_font = GetFont("main")
    
    r.ShowConsoleMsg("=== DEBUG STYLELOADER ===\n")
    r.ShowConsoleMsg("style_loader existe : " .. tostring(style_loader ~= nil) .. "\n")
    r.ShowConsoleMsg("header_font : " .. tostring(header_font) .. "\n")
    r.ShowConsoleMsg("type(header_font) : " .. tostring(type(header_font)) .. "\n")
    r.ShowConsoleMsg("main_font : " .. tostring(main_font) .. "\n")
    r.ShowConsoleMsg("type(main_font) : " .. tostring(type(main_font)) .. "\n")
    
    local visible, open = r.ImGui_Begin(ctx, 'Test StyleLoader', true)
    if visible then
        r.ImGui_Text(ctx, "Test StyleLoader")
        r.ImGui_Separator(ctx)
        
        r.ImGui_Text(ctx, "StyleLoader status:")
        if style_loader then
            r.ImGui_Text(ctx, "✓ StyleLoader chargé")
        else
            r.ImGui_Text(ctx, "✗ StyleLoader non trouvé")
        end
        
        r.ImGui_Text(ctx, "Font status:")
        r.ImGui_Text(ctx, "header_font: " .. tostring(header_font))
        r.ImGui_Text(ctx, "main_font: " .. tostring(main_font))
        
        r.ImGui_Separator(ctx)
        r.ImGui_Text(ctx, "Test avec header font:")
        
        -- CETTE LIGNE VA PROBABLEMENT PLANTER
        if header_font then 
            r.ShowConsoleMsg("Tentative PushFont avec header_font...\n")
            -- ANCIENNE SIGNATURE - VA PLANTER
            r.ImGui_PushFont(ctx, header_font)
            r.ImGui_Text(ctx, "Texte avec header font")
            r.ImGui_PopFont(ctx)
        else
            r.ImGui_Text(ctx, "header_font est nil")
        end
        
        r.ImGui_End(ctx)
    end
    
    ClearStyle()
    
    if open then
        r.defer(MainLoop)
    end
end

MainLoop()