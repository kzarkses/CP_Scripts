-- @description Project Notes Editor with Project Sync
-- @version 1.5
-- @author Claude

local r = reaper

-- Create context at script start
local ctx = r.ImGui_CreateContext('Project Notes Editor')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

-- Load the style loader module
local style_loader_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
local style_loader = nil
local pushed_colors = 0
local pushed_vars = 0

local file = io.open(style_loader_path, "r")
if file then
  file:close()
  local loader_func = dofile(style_loader_path)
  if loader_func then
    style_loader = loader_func()
  end
end

-- Configuration variables with persistence
local config = {
    fonts = {"Arial", "Times New Roman", "FiraSans-Regular", "Verdana", "Georgia"},
    sizes = {8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 32, 36, 40},
    current_font = "Arial",
    current_size = 12,
}

-- Variables pour le suivi du projet
local tracked_project = nil
local tracked_project_name = ""
local last_notes_content = ""

-- Load saved settings
function LoadSettings()
    local saved_font = r.GetExtState("ProjectNotesEditor", "font")
    local saved_size = tonumber(r.GetExtState("ProjectNotesEditor", "size"))
    
    if saved_font ~= "" then config.current_font = saved_font end
    if saved_size then config.current_size = saved_size end
end

-- Save settings
function SaveSettings()
    r.SetExtState("ProjectNotesEditor", "font", config.current_font, true)
    r.SetExtState("ProjectNotesEditor", "size", tostring(config.current_size), true)
end

-- Global variables for font management
local font = nil
local need_font_update = false

-- Initialize font
function InitFont()
    font = r.ImGui_CreateFont(config.current_font, config.current_size)
    r.ImGui_Attach(ctx, font)
end

-- Function to get project name
function GetProjectName(proj)
    local project_index = -1
    if proj then
        -- Find the index of the project
        local i = 0
        while true do
            local p = r.EnumProjects(i)
            if not p then break end
            if p == proj then
                project_index = i
                break
            end
            i = i + 1
        end
    end
    
    local _, project_path = r.EnumProjects(project_index)
    if not project_path or project_path == "" then
        return "Untitled Project"
    end
    return project_path:match("([^\\/]+)%.RPP$") or project_path:match("([^\\/]+)%.rpp$") or "Untitled Project"
end

-- Function to load project notes
function LoadProjectNotes(proj)
    if not proj then return "" end
    local retval, notes = r.GetProjExtState(proj, "REAPER_PROJECT_NOTES", "notes")
    if retval == 0 then
        retval, notes = r.GetSetProjectNotes(proj, false, "")
    end
    return notes or ""
end

-- Function to save project notes
function SaveProjectNotes(proj, notes)
    if not proj then return end
    r.GetSetProjectNotes(proj, true, notes)
    r.SetProjExtState(proj, "REAPER_PROJECT_NOTES", "notes", notes)
end

function Loop()
    if need_font_update then
        InitFont()
        need_font_update = false
    end

    -- Apply the global styles if available
    if style_loader then
        local success, colors, vars = style_loader.applyToContext(ctx)
        if success then
            pushed_colors, pushed_vars = colors, vars
        end
    end

    -- Vérifier si nous devons initialiser ou mettre à jour le projet suivi
    local current_proj = r.EnumProjects(-1)
    if not tracked_project then
        tracked_project = current_proj
        tracked_project_name = GetProjectName(tracked_project)
        last_notes_content = LoadProjectNotes(tracked_project)
    end

    local visible, open = r.ImGui_Begin(ctx, 'Project Notes Editor', true, WINDOW_FLAGS)
    
    if visible then
        -- Zone de l'indicateur de projet
        r.ImGui_Text(ctx, "Project: " .. tracked_project_name)
        r.ImGui_SameLine(ctx)
        
        -- Bouton pour réinitialiser le suivi
        if r.ImGui_Button(ctx, "Reset Tracking") then
            tracked_project = current_proj
            tracked_project_name = GetProjectName(tracked_project)
            last_notes_content = LoadProjectNotes(tracked_project)
        end
        
        -- Toolbar
        r.ImGui_PushItemWidth(ctx, 150)
        if r.ImGui_BeginCombo(ctx, 'Font', config.current_font) then
            for _, font_name in ipairs(config.fonts) do
                local is_selected = font_name == config.current_font
                if r.ImGui_Selectable(ctx, font_name, is_selected) and not is_selected then
                    config.current_font = font_name
                    need_font_update = true
                    SaveSettings()
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        r.ImGui_SameLine(ctx)
        if r.ImGui_BeginCombo(ctx, 'Size', tostring(config.current_size)) then
            for _, size in ipairs(config.sizes) do
                local is_selected = size == config.current_size
                if r.ImGui_Selectable(ctx, tostring(size), is_selected) and not is_selected then
                    config.current_size = size
                    need_font_update = true
                    SaveSettings()
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        r.ImGui_PopItemWidth(ctx)
        
        -- Calculer l'espace disponible pour l'éditeur
        local window_height = r.ImGui_GetWindowHeight(ctx)
        local cursor_y = r.ImGui_GetCursorPosY(ctx)
        local available_height = window_height - cursor_y - 10
        
        -- Notes editor avec word wrap
        if font then r.ImGui_PushFont(ctx, font) end
        
        -- Configurer le word wrap
        local window_width = r.ImGui_GetWindowWidth(ctx) - 16  -- 16 pixels pour le padding
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), 8, 8)
        r.ImGui_PushTextWrapPos(ctx, window_width)
        
        local changed
        changed, last_notes_content = r.ImGui_InputTextMultiline(
            ctx, 
            '##notes', 
            last_notes_content,
            window_width,
            available_height,
            r.ImGui_InputTextFlags_AllowTabInput() | 
            r.ImGui_InputTextFlags_AutoSelectAll()
        )
        
        r.ImGui_PopTextWrapPos(ctx)
        r.ImGui_PopStyleVar(ctx)
            
        if changed then 
            SaveProjectNotes(tracked_project, last_notes_content)
        end
        
        if font then r.ImGui_PopFont(ctx) end
        
        r.ImGui_End(ctx)
    end
    
    -- Clean up the styles we applied
    if style_loader then
        style_loader.clearStyles(ctx, pushed_colors, pushed_vars)
    end
    
    if open then
        r.defer(Loop)
    else
        SaveSettings()
    end
end

function Start()
    LoadSettings()
    InitFont()
    Loop()
end

function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        Start()
    else
        r.SetToggleCommandState(sectionID, cmdID, 0)
        r.RefreshToolbar2(sectionID, cmdID)
    end
end

function Exit()
    local _, _, sectionID, cmdID = r.get_action_context()
    r.SetToggleCommandState(sectionID, cmdID, 0)
    r.RefreshToolbar2(sectionID, cmdID)
end

r.atexit(Exit)
ToggleScript()