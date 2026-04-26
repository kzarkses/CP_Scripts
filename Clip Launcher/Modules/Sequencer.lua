local Sequencer = {}

local r, Core, Engine, Transport, ClipManager

function Sequencer.init(reaper_api, core, engine, transport, clip_manager)
    r = reaper_api
    Core = core
    Engine = engine
    Transport = transport
    ClipManager = clip_manager
end

-- Pick a random clip from a column based on probabilities
function Sequencer.pickRandomClip(column_index)
    local column = Core.state.columns[column_index]
    if not column then return -1 end

    local loaded = ClipManager.getLoadedClips(column_index)
    if #loaded == 0 then return -1 end

    -- Build weighted probability list
    local total_weight = 0
    local weights = {}
    for _, clip_idx in ipairs(loaded) do
        local prob = column.probabilities[clip_idx] or 1.0
        weights[#weights + 1] = { index = clip_idx, weight = prob }
        total_weight = total_weight + prob
    end

    if total_weight <= 0 then return loaded[1] end

    -- Weighted random selection
    local roll = math.random() * total_weight
    local cumulative = 0
    for _, w in ipairs(weights) do
        cumulative = cumulative + w.weight
        if roll <= cumulative then
            return w.index
        end
    end

    return weights[#weights].index
end

-- Generate a random interval in beats
function Sequencer.generateInterval(column)
    local min_beats = column.sequencer_interval_min or 1
    local max_beats = column.sequencer_interval_max or 4

    if min_beats >= max_beats then
        return min_beats
    end

    return min_beats + math.random() * (max_beats - min_beats)
end

-- Resolve follow action for a clip
local function resolveFollowAction(col_idx, clip_idx, action)
    local loaded = ClipManager.getLoadedClips(col_idx)
    if #loaded == 0 then return -1 end

    -- Sort loaded clips
    table.sort(loaded)

    if action == Core.FOLLOW_NEXT then
        for i, idx in ipairs(loaded) do
            if idx == clip_idx then
                return loaded[i + 1] or loaded[1]  -- wrap to first
            end
        end
        return loaded[1]

    elseif action == Core.FOLLOW_PREV then
        for i, idx in ipairs(loaded) do
            if idx == clip_idx then
                return loaded[i - 1] or loaded[#loaded]  -- wrap to last
            end
        end
        return loaded[#loaded]

    elseif action == Core.FOLLOW_FIRST then
        return loaded[1]

    elseif action == Core.FOLLOW_LAST then
        return loaded[#loaded]

    elseif action == Core.FOLLOW_RANDOM then
        return Sequencer.pickRandomClip(col_idx)

    elseif action == Core.FOLLOW_STOP then
        return 0  -- special: stop

    end
    return -1
end

-- Update sequencer and follow actions for all columns
function Sequencer.update()
    if not Transport.state.is_playing then return end

    local current_beat = Transport.state.beat_position

    for col_idx, column in ipairs(Core.state.columns) do
        -- Sequencer (random interval triggers)
        if column.sequencer_enabled and column.is_active then
            if column.sequencer_next_trigger <= 0 then
                local interval = Sequencer.generateInterval(column)
                column.sequencer_next_trigger = current_beat + interval
            end

            if current_beat >= column.sequencer_next_trigger then
                local clip_idx = Sequencer.pickRandomClip(col_idx)
                if clip_idx >= 0 then
                    Engine.playClip(col_idx, clip_idx, column.play_mode, Core.QUANTIZE_IMMEDIATE)
                end

                local interval = Sequencer.generateInterval(column)
                column.sequencer_next_trigger = current_beat + interval
            end
        end

        -- Follow actions (per-clip, triggered by loop count)
        if column.playing_clip >= 1 then
            local clip = column.clips[column.playing_clip]
            if clip and clip.follow_action ~= Core.FOLLOW_NONE then
                local loops = column.loop_count or 0
                if loops >= clip.follow_count then
                    local target = resolveFollowAction(col_idx, column.playing_clip, clip.follow_action)
                    if target == 0 then
                        Engine.stopColumn(col_idx)
                    elseif target > 0 and target ~= column.playing_clip then
                        Engine.playClip(col_idx, target, column.play_mode)
                    end
                end
            end
        end
    end
end

-- Toggle sequencer for a column
function Sequencer.toggle(column_index)
    local column = Core.state.columns[column_index]
    if not column then return end

    column.sequencer_enabled = not column.sequencer_enabled
    if column.sequencer_enabled then
        column.sequencer_next_trigger = Transport.state.beat_position
    end
end

-- Set probability for a specific clip
function Sequencer.setProbability(column_index, clip_index, probability)
    local column = Core.state.columns[column_index]
    if not column then return end
    column.probabilities[clip_index] = math.max(0, math.min(1, probability))
end

-- Set interval range for a column
function Sequencer.setInterval(column_index, min_beats, max_beats)
    local column = Core.state.columns[column_index]
    if not column then return end
    column.sequencer_interval_min = math.max(0.25, min_beats)
    column.sequencer_interval_max = math.max(column.sequencer_interval_min, max_beats)
end

return Sequencer
