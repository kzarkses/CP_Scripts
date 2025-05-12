local r = reaper

local ctx = r.ImGui_CreateContext('Take Envelope LFO')
local WINDOW_FLAGS = r.ImGui_WindowFlags_NoCollapse()

local clipboard = { points = nil }
local current_take = nil
local current_envelopes = {}

local config = {
    cycles = 4,
    amplitude = 0.5,
    phase = 0.0,
    waveform = "sine",
    offset = 0.5,
    debug_info = ""
}

local function getTakeEnvelopes(take)
    local envelopes = {}
    if not take then return envelopes end
    
    for i = 0, r.CountTakeEnvelopes(take) - 1 do
        local env = r.GetTakeEnvelope(take, i)
        local retval, name = r.GetEnvelopeName(env)
        table.insert(envelopes, {name = name, env = env})
    end
    
    return envelopes
end

local function updateCurrentTake()
    local selected_items = {}
    local item_count = r.CountSelectedMediaItems(0)
    if item_count > 0 then
        local item = r.GetSelectedMediaItem(0, 0)
        if item then
            current_take = r.GetActiveTake(item)
            current_envelopes = getTakeEnvelopes(current_take)
        end
    else
        local env = r.GetSelectedEnvelope(0)
        if env then
            local take, _, _ = r.Envelope_GetParentTake(env)
            if take ~= current_take then
                current_take = take
                current_envelopes = getTakeEnvelopes(take)
            end
        end
    end
end

local function detectLFOPattern(env)
    if not env then return false end
    
    local take = r.Envelope_GetParentTake(env)
    if not take then return false end
    
    local item = r.GetMediaItemTake_Item(take)
    local item_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    
    local points = {}
    local count = r.CountEnvelopePoints(env)
    if count < 4 then return false end
    
    for i = 0, count - 1 do
        local retval, time, value, shape, tension, selected = r.GetEnvelopePoint(env, i)
        table.insert(points, {time = time, value = value})
    end
    
    if #points < 4 then return false end
    
    local cycles
    if waveform == "saw" then
        cycles = (#points / 2)
    else
        cycles = (#points / 4)
    end
    
    local min_value = math.huge
    local max_value = -math.huge
    
    for _, point in ipairs(points) do
        min_value = math.min(min_value, point.value)
        max_value = math.max(max_value, point.value)
    end
    
    local detected_amplitude = (max_value - min_value) / 2
    local detected_offset = (max_value + min_value) / 2
    
    local _, _, _, shape1 = r.GetEnvelopePoint(env, 0)
    local detected_waveform = "sine"
    if shape1 == 0 then
        if math.abs(points[2].value - points[1].value) < 0.001 then
            detected_waveform = "square"
        else
            detected_waveform = math.abs(points[3].value - points[2].value) < 0.001 and "triangle" or "saw"
        end
    end
    
    config.cycles = cycles
    config.amplitude = detected_amplitude
    config.offset = detected_offset
    config.waveform = detected_waveform
    return true
end

local function copyEnvelopePoints(env)
    if not env then return end
    clipboard.points = {}
    
    local count = r.CountEnvelopePoints(env)
    for i = 0, count - 1 do
        local retval, time, value, shape, tension, selected = r.GetEnvelopePoint(env, i)
        table.insert(clipboard.points, {
            time = time,
            value = value,
            shape = shape,
            tension = tension
        })
    end
end

local function pasteEnvelopePoints(env)
    if not env or not clipboard.points then return end
    
    r.DeleteEnvelopePointRange(env, -math.huge, math.huge)
    
    for _, point in ipairs(clipboard.points) do
        r.InsertEnvelopePoint(env, point.time, point.value, point.shape, point.tension, false, true)
    end
    
    r.Envelope_SortPoints(env)
    r.UpdateArrange()
end

local function generateWaveformPoints(length, cycles, amplitude, phase, waveform)   
    local points = {}
    local period = length / cycles
    
    for cycle = 0, cycles - 1 do
        local cycle_start = cycle * period
        
        if waveform == "sine" then
            local p1_time = math.floor((cycle_start) * 1000) / 1000
            local p2_time = math.floor((cycle_start + period/4) * 1000) / 1000
            local p3_time = math.floor((cycle_start + period/2) * 1000) / 1000
            local p4_time = math.floor((cycle_start + period*3/4) * 1000) / 1000
            
            table.insert(points, {time = p1_time, value = config.offset, shape = 3})
            table.insert(points, {time = p2_time, value = config.offset + amplitude, shape = 4})
            table.insert(points, {time = p3_time, value = config.offset, shape = 3})
            table.insert(points, {time = p4_time, value = config.offset - amplitude, shape = 4})
            
        elseif waveform == "triangle" then
            local p1_time = math.floor((cycle_start) * 1000) / 1000
            local p2_time = math.floor((cycle_start + period/4) * 1000) / 1000
            local p3_time = math.floor((cycle_start + period/2) * 1000) / 1000
            local p4_time = math.floor((cycle_start + period*3/4) * 1000) / 1000
            
            table.insert(points, {time = p1_time, value = config.offset, shape = 0})
            table.insert(points, {time = p2_time, value = config.offset + amplitude, shape = 0})
            table.insert(points, {time = p3_time, value = config.offset, shape = 0})
            table.insert(points, {time = p4_time, value = config.offset - amplitude, shape = 0})
            
        elseif waveform == "square" then
            local p1_time = math.floor((cycle_start) * 1000) / 1000
            local p2_time = math.floor((cycle_start + period/2 - 0.001) * 1000) / 1000
            local p3_time = math.floor((cycle_start + period/2) * 1000) / 1000
            local p4_time = math.floor((cycle_start + period - 0.001) * 1000) / 1000
            
            table.insert(points, {time = p1_time, value = config.offset + amplitude, shape = 0})
            table.insert(points, {time = p2_time, value = config.offset + amplitude, shape = 0})
            table.insert(points, {time = p3_time, value = config.offset - amplitude, shape = 0})
            table.insert(points, {time = p4_time, value = config.offset - amplitude, shape = 0})
            
        elseif waveform == "saw" then
            local p1_time = math.floor((cycle_start) * 1000) / 1000
            local p2_time = math.floor((cycle_start + period - 0.001) * 1000) / 1000
            
            table.insert(points, {time = p1_time, value = config.offset - amplitude, shape = 0})
            table.insert(points, {time = p2_time, value = config.offset + amplitude, shape = 0})
        end
    end
    
    -- Add final points to complete the cycle
    if waveform == "sine" or waveform == "triangle" then
        table.insert(points, {time = length, value = config.offset, shape = points[1].shape})
    elseif #points > 0 and points[#points].time < length then
        local last_point = points[#points]
        table.insert(points, {time = length, value = last_point.value, shape = last_point.shape})
    end
    
    return points
end

function applyLFOToEnvelope()
    config.debug_info = ""
    
    local env = r.GetSelectedEnvelope(0)
    if not env then 
        config.debug_info = "No envelope selected"
        return 
    end
    
    local take, _, _ = r.Envelope_GetParentTake(env)
    if not take then 
        config.debug_info = "Not a take envelope"
        return 
    end
    
    local item = r.GetMediaItemTake_Item(take)
    local item_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take_rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local adjusted_length = item_length * take_rate
    
    r.Envelope_SortPoints(env)
    r.DeleteEnvelopePointRange(env, -math.huge, math.huge)
    
    local points = generateWaveformPoints(adjusted_length, config.cycles, config.amplitude, config.phase, 
                                   config.waveform)
    
    r.PreventUIRefresh(1)
    
    for i, point in ipairs(points) do
        r.InsertEnvelopePoint(env, point.time / take_rate, point.value, point.shape, 0, false, true)
    end
    
    r.Envelope_SortPoints(env)
    
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    config.debug_info = "Applied LFO to envelope"
end

local last_env = nil
function loop()
    local visible, open = r.ImGui_Begin(ctx, 'Take Envelope LFO', true, WINDOW_FLAGS)
    
    if visible then
        updateCurrentTake()
        
        -- Show take envelope buttons
        if current_take and #current_envelopes > 0 then
            r.ImGui_Text(ctx, "Take Envelopes:")
            local buttonWidth = (r.ImGui_GetWindowWidth(ctx) - 20) / 3
            local col = 0
            for i, env_data in ipairs(current_envelopes) do
                if col > 0 then r.ImGui_SameLine(ctx) end
                if r.ImGui_Button(ctx, env_data.name, buttonWidth) then
                    r.Main_OnCommand(40331, 0) -- Unselect all envelopes
                    r.SetCursorContext(2, env_data.env)
                end
                col = (col + 1) % 3
                if col == 0 then r.ImGui_Spacing(ctx) end
            end
            r.ImGui_Separator(ctx)
        end
        
        -- Detect LFO when envelope selection changes
        local current_env = r.GetSelectedEnvelope(0)
        if current_env ~= last_env then
            detectLFOPattern(current_env)
            last_env = current_env
        end
        
        -- Copy/Paste buttons
        if r.ImGui_Button(ctx, "Copy") then
            copyEnvelopePoints(r.GetSelectedEnvelope(0))
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Paste") and clipboard.points then
            pasteEnvelopePoints(r.GetSelectedEnvelope(0))
        end
        
        r.ImGui_Separator(ctx)
        
        local waveforms = {"sine", "square", "triangle", "saw"}
        if r.ImGui_BeginCombo(ctx, 'Waveform', config.waveform) then
            for _, waveform in ipairs(waveforms) do
                if r.ImGui_Selectable(ctx, waveform, waveform == config.waveform) then
                    config.waveform = waveform
                end
            end
            r.ImGui_EndCombo(ctx)
        end
        
        local value_changed = false
        
        local cycles_changed
        cycles_changed, config.cycles = r.ImGui_SliderInt(ctx, 'Cycles', math.floor(config.cycles), 1, 32)
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 1) then 
            config.cycles = 4 
            applyLFOToEnvelope()
        end

        local amp_changed
        amp_changed, config.amplitude = r.ImGui_SliderDouble(ctx, 'Amplitude', config.amplitude, 0.0, 0.5, "%.2f")
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 1) then 
            config.amplitude = 0.5 
            applyLFOToEnvelope()
        end
        
        local phase_changed
        phase_changed, config.phase = r.ImGui_SliderDouble(ctx, 'Phase', config.phase, 0.0, 2*math.pi, "%.3f")
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 1) then 
            config.phase = 0 
            applyLFOToEnvelope()
        end
        
        local offset_changed
        offset_changed, config.offset = r.ImGui_SliderDouble(ctx, 'Offset', config.offset, 0.0, 1.0, "%.2f")
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 1) then 
            config.offset = 0.5 
            applyLFOToEnvelope()
        end
        
        if cycles_changed or amp_changed or phase_changed or offset_changed then
            applyLFOToEnvelope()
        end
        
        if config.debug_info ~= "" then
            r.ImGui_TextWrapped(ctx, "Debug: " .. config.debug_info)
        end
        
        r.ImGui_End(ctx)
    end
    
    if open then
        r.defer(loop)
    end
end

function Start()
    loop()
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