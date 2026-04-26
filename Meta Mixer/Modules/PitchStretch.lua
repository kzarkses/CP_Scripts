-- PitchStretch.lua — Pitch/stretch algorithm management + reverse/loop/warp
local PitchStretch = {}
local r, C, W, ctx

function PitchStretch.init(reaper_api, constants, widgets, imgui_ctx)
    r = reaper_api
    C = constants
    W = widgets
    ctx = imgui_ctx
end

-- ============================================================================
-- ALGORITHM DATABASE
-- ============================================================================
PitchStretch.ALGORITHMS = {
    { name = "Project Default", index = -1 },
    { name = "SoundTouch", index = 0 },
    { name = "Simple Windowed", index = 2 },
    { name = "Elastique 2 Pro", index = 6 },
    { name = "Elastique 2 Efficient", index = 7 },
    { name = "Elastique 2 Soloist", index = 8 },
    { name = "Elastique 3 Pro", index = 9 },
    { name = "Elastique 3 Efficient", index = 10 },
    { name = "Elastique 3 Soloist", index = 11 },
    { name = "Rubber Band Library", index = 13 },
    { name = "Rrreeeaaa", index = 14 },
    { name = "ReaReaRea", index = 15 },
}

local algo_by_index = {}
for _, algo in ipairs(PitchStretch.ALGORITHMS) do
    algo_by_index[algo.index] = algo
end

-- ============================================================================
-- DECODE / ENCODE PITCH MODE
-- ============================================================================
function PitchStretch.DecodePitchMode(pitch_value)
    local mode_idx = math.floor(pitch_value / 65536)
    local submode = math.floor(pitch_value % 65536)
    return mode_idx, submode
end

function PitchStretch.EncodePitchMode(mode_idx, submode)
    return mode_idx * 65536 + submode
end

function PitchStretch.GetAlgoName(mode_idx)
    local algo = algo_by_index[mode_idx]
    return algo and algo.name or ("Mode " .. mode_idx)
end

-- ============================================================================
-- READ CURRENT MODE FROM TAKE
-- ============================================================================
function PitchStretch.GetCurrentMode(take)
    if not take then return -1, 0 end
    local pitch_value = r.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
    return PitchStretch.DecodePitchMode(pitch_value)
end

function PitchStretch.HasFormants(mode_idx)
    return mode_idx == 6 or mode_idx == 9
end

function PitchStretch.GetFormants(submode, mode_idx)
    if not PitchStretch.HasFormants(mode_idx) then return false, 0 end
    local base = submode % 8
    return base > 0, base
end

-- ============================================================================
-- APPLY ALGORITHM
-- ============================================================================
function PitchStretch.ApplyToItems(mode_idx, submode)
    local item_count = r.CountSelectedMediaItems(0)
    if item_count == 0 then return end

    local pitch_value = PitchStretch.EncodePitchMode(mode_idx, submode)

    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    for i = 0, item_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take and not r.TakeIsMIDI(take) then
            r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", pitch_value)
        end
    end
    r.Undo_EndBlock("Change pitch algorithm", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

-- ============================================================================
-- STRETCH MARKER OPERATIONS
-- ============================================================================
function PitchStretch.AddStretchMarker(take, item, pos_in_item)
    if not take or not item then return end
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    r.SetTakeStretchMarker(take, -1, pos_in_item)
    r.Undo_EndBlock("Add stretch marker", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

function PitchStretch.MoveStretchMarker(take, idx, new_pos)
    if not take or idx < 0 then return end
    r.SetTakeStretchMarker(take, idx, new_pos)
    r.UpdateArrange()
end

function PitchStretch.DeleteStretchMarker(take, idx)
    if not take or idx < 0 then return end
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    r.DeleteTakeStretchMarkers(take, idx, 1)
    r.Undo_EndBlock("Delete stretch marker", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

function PitchStretch.ClearStretchMarkers(take)
    if not take then return end
    local count = r.GetTakeNumStretchMarkers(take)
    if count == 0 then return end
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    r.DeleteTakeStretchMarkers(take, 0, count)
    r.Undo_EndBlock("Clear stretch markers", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

-- ============================================================================
-- REVERSE ITEM — toggles reverse via REAPER action
-- ============================================================================
function PitchStretch.ReverseItem(item)
    if not item then return end
    r.SetMediaItemSelected(item, true)
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    r.Main_OnCommand(41051, 0)  -- Item: Toggle items reverse
    r.Undo_EndBlock("Reverse item", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

-- ============================================================================
-- LOOP TOGGLE
-- ============================================================================
function PitchStretch.IsLooped(item)
    if not item then return false end
    return r.GetMediaItemInfo_Value(item, "B_LOOPSRC") == 1
end

function PitchStretch.ToggleLoop(item)
    if not item then return end
    local current = r.GetMediaItemInfo_Value(item, "B_LOOPSRC")
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock()
    r.SetMediaItemInfo_Value(item, "B_LOOPSRC", current == 1 and 0 or 1)
    r.Undo_EndBlock("Toggle loop source", -1)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
end

-- ============================================================================
-- COMPACT UI — inline algorithm bar for Item Editor
-- ============================================================================
function PitchStretch.DrawInline(take, info)
    if not take or not info then return end

    local mode_idx, submode = PitchStretch.GetCurrentMode(take)
    local algo_name = PitchStretch.GetAlgoName(mode_idx)

    r.ImGui_Text(ctx, "Algo:")
    r.ImGui_SameLine(ctx)

    r.ImGui_SetNextItemWidth(ctx, 160)
    if r.ImGui_BeginCombo(ctx, "##algo_combo", algo_name) then
        for _, algo in ipairs(PitchStretch.ALGORITHMS) do
            local is_selected = (algo.index == mode_idx)
            if r.ImGui_Selectable(ctx, algo.name .. "##algo_" .. algo.index, is_selected) then
                PitchStretch.ApplyToItems(algo.index, 0)
            end
        end
        r.ImGui_EndCombo(ctx)
    end

    if PitchStretch.HasFormants(mode_idx) then
        r.ImGui_SameLine(ctx, 0, 15)
        local has_formants = PitchStretch.GetFormants(submode, mode_idx)
        local formant_changed
        formant_changed, has_formants = r.ImGui_Checkbox(ctx, "Formants##formants", has_formants)
        if formant_changed then
            local flags = math.floor(submode / 8) * 8
            local new_submode = has_formants and (flags + 1) or (flags + 0)
            PitchStretch.ApplyToItems(mode_idx, new_submode)
        end
    end

    if info.stretch_markers and #info.stretch_markers > 0 then
        r.ImGui_SameLine(ctx, 0, 15)
        r.ImGui_TextDisabled(ctx, string.format("SM: %d", #info.stretch_markers))
        r.ImGui_SameLine(ctx)
        if r.ImGui_SmallButton(ctx, "Clear SM##clear_sm") then
            PitchStretch.ClearStretchMarkers(take)
        end
    end
end

return PitchStretch
