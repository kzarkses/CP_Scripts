--[[
	Noindex: true
]]  
local r = reaper

local sl = nil
local sp = r.GetResourcePath() .. "/Scripts/CP_Scripts/Scripts/Various/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp) then local lf = dofile(sp) if lf then sl = lf() end end

local ctx = r.ImGui_CreateContext('Stretch Markers Control')
local pc, pv = 0, 0

function getFont(font_name)
    if sl then
        return sl.getFont(ctx, font_name)
    end
    return nil
end

if sl then sl.applyFontsToContext(ctx) end

local WINDOW_FLAGS = r.ImGui_WindowFlags_NoTitleBar() | r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoCollapse()

local WINDOW_X_OFFSET = -235  
local WINDOW_Y_OFFSET = 35  
local WINDOW_WIDTH = 200    
local WINDOW_HEIGHT = 76   

local window_position_set = false
local settings = {
    slope = 0,
    last_slope = 0  
}


local file = io.open(sp, "r")
if file then
  file:close()
  local loader_func = dofile(sp)
  if loader_func then
    sl = loader_func()
  end
end


function SaveSelectedItems()
    local items = {}
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
        table.insert(items, r.GetSelectedMediaItem(0, i))
    end
    return items
end


function ApplyStretchMarkers(slopeIn)
    local items = SaveSelectedItems()
    if #items == 0 then return end  
    
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    
    for i, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local itemLength = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
            local playrate = r.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
            
            
            r.DeleteTakeStretchMarkers(take, 0, r.GetTakeNumStretchMarkers(take))
            
            
            local idx = r.SetTakeStretchMarker(take, -1, 0)
            r.SetTakeStretchMarker(take, -1, itemLength * playrate)
            
            
            local slope = slopeIn
            if slope > 4 then
                slope = math.random() * math.min(4, (slope - 4)) / 4
                if math.random() > 0.5 then slope = slope * -1 end
            else
                slope = slope * 0.2499
            end
            r.SetTakeStretchMarkerSlope(take, idx, slope)
        end
    end
    
    r.Undo_EndBlock("Add Stretch Markers", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

function Loop()
    if not window_position_set then
        if WINDOW_FOLLOW_MOUSE then
            local mouse_x, mouse_y = r.GetMousePosition()
            r.ImGui_SetNextWindowPos(ctx, mouse_x + WINDOW_X_OFFSET, mouse_y + WINDOW_Y_OFFSET)
        end
        r.ImGui_SetNextWindowSize(ctx, WINDOW_WIDTH, WINDOW_HEIGHT)
        window_position_set = true
    end

    if sl then
        local success, colors, vars = sl.applyToContext(ctx)
        if success then pc, pv = colors, vars end
    end

    local header_font = getFont("header")
    local main_font = getFont("main")

    local visible, open = r.ImGui_Begin(ctx, 'Stretch Marker', true, WINDOW_FLAGS)
    if visible then
        if header_font then r.ImGui_PushFont(ctx, header_font) end
        r.ImGui_Text(ctx, "Stretch Marker")
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

        
        local slope_changed
        slope_changed, settings.slope = r.ImGui_SliderDouble(ctx, 'Slope', settings.slope, -4, 4, '%.2f')
        r.ImGui_Spacing(ctx)
        
        
        -- r.ImGui_Text(ctx, "Presets:")
        
        
        -- if r.ImGui_Button(ctx, "-2") then
        --     settings.slope = -4
        --     slope_changed = true
        -- end
        -- r.ImGui_SameLine(ctx)
        -- if r.ImGui_Button(ctx, "-1.75") then
        --     settings.slope = -3
        --     slope_changed = true
        -- end
        -- r.ImGui_SameLine(ctx)
        -- if r.ImGui_Button(ctx, "-1.50") then
        --     settings.slope = -2
        --     slope_changed = true
        -- end
        -- r.ImGui_SameLine(ctx)
        -- if r.ImGui_Button(ctx, "-1.25") then
        --     settings.slope = -1
        --     slope_changed = true
        -- end
        
        
        -- if r.ImGui_Button(ctx, "0") then
        --     settings.slope = 0
        --     slope_changed = true
        -- end
        -- r.ImGui_SameLine(ctx)
        -- if r.ImGui_Button(ctx, "1.25") then
        --     settings.slope = 1
        --     slope_changed = true
        -- end
        -- r.ImGui_SameLine(ctx)
        -- if r.ImGui_Button(ctx, "1.50") then
        --     settings.slope = 2
        --     slope_changed = true
        -- end
        -- r.ImGui_SameLine(ctx)
        -- if r.ImGui_Button(ctx, "1.75") then
        --     settings.slope = 3
        --     slope_changed = true
        -- end
        -- r.ImGui_SameLine(ctx)
        -- if r.ImGui_Button(ctx, "2") then
        --     settings.slope = 4
        --     slope_changed = true
        -- end
        
        
        if slope_changed or settings.slope ~= settings.last_slope then
            ApplyStretchMarkers(settings.slope)
            settings.last_slope = settings.slope
        end

        if main_font then r.ImGui_PopFont(ctx) end
        
        r.ImGui_End(ctx)
    end
    
    
    if sl then sl.clearStyles(ctx, pc, pv) end

    if open then
        r.defer(Loop)
    end
end


function ToggleScript()
    local _, _, sectionID, cmdID = r.get_action_context()
    local state = r.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        r.SetToggleCommandState(sectionID, cmdID, 1)
        r.RefreshToolbar2(sectionID, cmdID)
        Loop()
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