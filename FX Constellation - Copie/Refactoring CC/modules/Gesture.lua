-- FX Constellation - Gesture Control Module
-- Gesture and motion control system for parameter automation

local Gesture = {}

-- Note: This module will need the following modules:
-- - Utilities: for helper functions (isTrackValid, getParamKey, bezierCurve, etc.)
-- - GranularGrid: for applyGranularGesture

-- Generate random walk control points for smooth Bezier curve motion
-- Creates a curved path from current position to a new random target
function Gesture.generateRandomWalkControlPoints(state, r, Utilities)
  local current = { x = state.gesture_x, y = state.gesture_y }
  local target = { x = math.random(), y = math.random() }

  local dx = target.x - current.x
  local dy = target.y - current.y
  local distance = math.sqrt(dx * dx + dy * dy)

  -- Create two control points for the Bezier curve with some randomness
  local control1 = {
    x = current.x + dx * 0.3 + (math.random() - 0.5) * 0.2,
    y = current.y + dy * 0.3 + (math.random() - 0.5) * 0.2
  }

  local control2 = {
    x = current.x + dx * 0.7 + (math.random() - 0.5) * 0.2,
    y = current.y + dy * 0.7 + (math.random() - 0.5) * 0.2
  }

  -- Clamp control points to valid range [0, 1]
  control1.x = math.max(0, math.min(1, control1.x))
  control1.y = math.max(0, math.min(1, control1.y))
  control2.x = math.max(0, math.min(1, control2.x))
  control2.y = math.max(0, math.min(1, control2.y))

  state.random_walk_control_points = {
    p0 = current,
    p1 = control1,
    p2 = control2,
    p3 = target
  }
  state.random_walk_bezier_progress = 0
  state.target_gesture_x = target.x
  state.target_gesture_y = target.y
end

-- Create JSFX plugin for gesture automation
-- This creates a simple JSFX effect that can be automated in REAPER's automation lanes
function Gesture.createAutomationJSFX(state, r, Utilities)
  if not Utilities.isTrackValid(state, r) then return false end

  local jsfx_code = [[
desc: FX Constellation Bridge
slider1:x_pos=0.5<0,1,0.001>X Position
slider2:y_pos=0.5<0,1,0.001>Y Position

@sample
// Pass audio through unchanged
spl0 = spl0;
spl1 = spl1;
]]

  local jsfx_path = r.GetResourcePath() .. "/Effects/FX Constellation Bridge.jsfx"
  local file = io.open(jsfx_path, "w")
  if file then
    file:write(jsfx_code)
    file:close()
    local fx_index = r.TrackFX_AddByName(state.track, "FX Constellation Bridge", false, -1)
    if fx_index >= 0 then
      state.jsfx_automation_index = fx_index
      state.jsfx_automation_enabled = true
      return true
    end
  end
  return false
end

-- Update gesture state from JSFX automation parameters
-- Reads X and Y position from the automation JSFX and applies to gesture system
function Gesture.updateAutomationFromJSFX(state, r, Utilities, GranularGrid)
  if not state.jsfx_automation_enabled or state.jsfx_automation_index < 0 then return end
  if not Utilities.isTrackValid(state, r) then return end

  local jsfx_x = r.TrackFX_GetParam(state.track, state.jsfx_automation_index, 0)
  local jsfx_y = r.TrackFX_GetParam(state.track, state.jsfx_automation_index, 1)

  -- Apply gesture based on current pad mode (granular vs standard)
  if state.pad_mode == 1 then
    if not state.granular_grains or #state.granular_grains == 0 then
      GranularGrid.initializeGranularGrid(state, r, Utilities)
    end
    GranularGrid.applyGranularGesture(state, r, Utilities, jsfx_x, jsfx_y)
  else
    Gesture.applyGestureToSelection(state, r, Utilities, jsfx_x, jsfx_y)
  end
end

-- Update JSFX parameters from current gesture position
-- Writes current gesture X/Y to the automation JSFX sliders
function Gesture.updateJSFXFromGesture(state, r, Utilities)
  if not state.jsfx_automation_enabled or state.jsfx_automation_index < 0 then return end
  if not Utilities.isTrackValid(state, r) then return end

  r.TrackFX_SetParam(state.track, state.jsfx_automation_index, 0, state.gesture_x)
  r.TrackFX_SetParam(state.track, state.jsfx_automation_index, 1, state.gesture_y)
end

-- Main gesture motion update loop
-- Handles all three navigation modes: Manual, Random Walk, and Figures
function Gesture.updateGestureMotion(state, r, Utilities, GranularGrid)
  local current_time = r.time_precise()

  -- First check for JSFX automation input
  Gesture.updateAutomationFromJSFX(state, r, Utilities, GranularGrid)

  -- Navigation Mode 1: Random Walk - autonomous movement with Bezier curves
  if state.navigation_mode == 1 then
    if state.random_walk_active then
      -- Generate new control points when it's time for next segment
      if current_time >= state.random_walk_next_time then
        Gesture.generateRandomWalkControlPoints(state, r, Utilities)
        local base_interval = 1.0 / state.random_walk_speed
        local jitter_amount = base_interval * state.random_walk_jitter
        local jitter = (math.random() * 2 - 1) * jitter_amount
        state.random_walk_next_time = current_time + base_interval + jitter
        state.random_walk_last_time = current_time
      end

      -- Calculate current position along Bezier curve
      if state.random_walk_control_points and state.random_walk_control_points.p0 then
        local duration = state.random_walk_next_time - state.random_walk_last_time
        local elapsed = current_time - state.random_walk_last_time
        local progress = math.min(1.0, elapsed / duration)

        state.random_walk_bezier_progress = progress
        local x, y = Utilities.bezierCurve(progress,
          state.random_walk_control_points.p0,
          state.random_walk_control_points.p1,
          state.random_walk_control_points.p2,
          state.random_walk_control_points.p3)

        state.gesture_x = x
        state.gesture_y = y
        Gesture.updateJSFXFromGesture(state, r, Utilities)

        -- Apply gesture based on pad mode
        if state.pad_mode == 1 then
          if not state.granular_grains or #state.granular_grains == 0 then
            GranularGrid.initializeGranularGrid(state, r, Utilities)
          end
          GranularGrid.applyGranularGesture(state, r, Utilities, state.gesture_x, state.gesture_y)
        else
          Gesture.applyGestureToSelection(state, r, Utilities, state.gesture_x, state.gesture_y)
        end
      end
    end

  -- Navigation Mode 2: Figures - geometric patterns (circle, square, triangle, etc.)
  elseif state.navigation_mode == 2 then
    if state.figures_active then
      state.figures_time = state.figures_time + (current_time - (state.last_figures_update or current_time))
      local x, y = Utilities.calculateFiguresPosition(state, state.figures_time)
      state.gesture_x = x
      state.gesture_y = y
      Gesture.updateJSFXFromGesture(state, r, Utilities)

      -- Apply gesture based on pad mode
      if state.pad_mode == 1 then
        if not state.granular_grains or #state.granular_grains == 0 then
          GranularGrid.initializeGranularGrid(state, r, Utilities)
        end
        GranularGrid.applyGranularGesture(state, r, Utilities, state.gesture_x, state.gesture_y)
      else
        Gesture.applyGestureToSelection(state, r, Utilities, state.gesture_x, state.gesture_y)
      end
    end
    state.last_figures_update = current_time

  -- Navigation Mode 0: Manual - user controlled with optional smoothing
  else
    if not state.gesture_active and state.smooth_speed > 0 then
      local dx = state.target_gesture_x - state.gesture_x
      local dy = state.target_gesture_y - state.gesture_y
      local distance = math.sqrt(dx * dx + dy * dy)

      if distance > 0.001 then
        -- Limit movement speed based on max_gesture_speed
        local max_distance = state.max_gesture_speed *
        (current_time - (state.last_smooth_update or current_time))

        if distance > max_distance then
          dx = dx / distance * max_distance
          dy = dy / distance * max_distance
        end

        state.gesture_x = state.gesture_x + dx * state.smooth_speed
        state.gesture_y = state.gesture_y + dy * state.smooth_speed

        -- Apply gesture based on pad mode
        if state.pad_mode == 1 then
          if not state.granular_grains or #state.granular_grains == 0 then
            GranularGrid.initializeGranularGrid(state, r, Utilities)
          end
          GranularGrid.applyGranularGesture(state, r, Utilities, state.gesture_x, state.gesture_y)
        else
          Gesture.applyGestureToSelection(state, r, Utilities, state.gesture_x, state.gesture_y)
        end
      end
    end
  end

  state.last_smooth_update = current_time
end

-- Capture base values for all selected parameters
-- These base values are used as reference points for gesture-based modulation
function Gesture.captureBaseValues(state, r, Utilities)
  state.param_base_values = {}
  state.gesture_base_x = state.gesture_x
  state.gesture_base_y = state.gesture_y

  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        param_data.base_value = param_data.current_value
        local key = Utilities.getParamKey(state, fx_id, param_id)
        if key then
          state.param_base_values[key] = param_data.current_value
        end
      end
    end
  end
end

-- Apply gesture position to all selected parameters
-- Uses gesture offsets to modulate parameters based on their base values, ranges, and XY assignments
function Gesture.applyGestureToSelection(state, r, Utilities, gx, gy)
  if not Utilities.isTrackValid(state, r) then return end

  -- Calculate gesture offset from base position (scaled by 2 for full range)
  local offset_x = (gx - state.gesture_base_x) * 2
  local offset_y = (gy - state.gesture_base_y) * 2

  for fx_id, fx_data in pairs(state.fx_data) do
    for param_id, param_data in pairs(fx_data.params) do
      if param_data.selected then
        -- Get parameter configuration
        local param_range = Utilities.getParamRange(state, fx_id, param_id)
        local x_assign, y_assign = Utilities.getParamXYAssign(state, fx_id, param_id)
        local param_invert = Utilities.getParamInvert(state, fx_id, param_id)
        local base_key = Utilities.getParamKey(state, fx_id, param_id)
        local base_value = (base_key and state.param_base_values[base_key]) or param_data.base_value

        -- Calculate asymmetric range based on available space around base value
        local up_range, down_range = Utilities.calculateAsymmetricRange(
          base_value, param_range, state.gesture_range,
          state.gesture_min, state.gesture_max
        )

        local new_value = base_value
        local x_contribution = 0
        local y_contribution = 0

        -- Calculate X axis contribution
        if x_assign then
          local x_offset = offset_x
          if param_invert then x_offset = -x_offset end
          x_contribution = x_offset > 0 and x_offset * up_range or x_offset * down_range
        end

        -- Calculate Y axis contribution
        if y_assign then
          local y_offset = offset_y
          if param_invert then y_offset = -y_offset end
          y_contribution = y_offset > 0 and y_offset * up_range or y_offset * down_range
        end

        -- Combine X and Y contributions
        if x_assign and y_assign then
          new_value = base_value + (x_contribution + y_contribution) / 2
        elseif x_assign then
          new_value = base_value + x_contribution
        elseif y_assign then
          new_value = base_value + y_contribution
        end

        -- Clamp to gesture min/max limits
        new_value = math.max(state.gesture_min, math.min(state.gesture_max, new_value))

        -- Snap to discrete steps if parameter has stepped values
        if param_data.step_count and param_data.step_count > 0 then
          new_value = Utilities.snapToDiscreteValue(new_value, param_data.step_count)
        end

        -- Apply the new parameter value
        local actual_fx_id = fx_data.actual_fx_id or fx_id
        r.TrackFX_SetParam(state.track, actual_fx_id, param_id, new_value)
        param_data.current_value = new_value
        param_data.base_value = new_value
      end
    end
  end
end

-- Draw pattern icon for figure selection buttons
-- Renders visual representation of different geometric patterns
function Gesture.drawPatternIcon(r, draw_list, x, y, size, pattern_id, is_active)
  local center_x = x + size / 2
  local center_y = y + size / 2
  local radius = size * 0.35
  local color = is_active and 0xFFFFFFFF or 0x888888FF
  local thickness = is_active and 2 or 1

  -- Pattern 0: Circle
  if pattern_id == 0 then
    r.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, radius, color, 32, thickness)

  -- Pattern 1: Square
  elseif pattern_id == 1 then
    local offset = radius
    r.ImGui_DrawList_AddRect(draw_list, center_x - offset, center_y - offset, center_x + offset, center_y + offset,
      color, 0, 0, thickness)

  -- Pattern 2: Triangle
  elseif pattern_id == 2 then
    local h = radius * 1.2
    r.ImGui_DrawList_AddTriangle(draw_list,
      center_x, center_y - h * 0.7,
      center_x - h * 0.6, center_y + h * 0.5,
      center_x + h * 0.6, center_y + h * 0.5,
      color, thickness)

  -- Pattern 3: Diamond
  elseif pattern_id == 3 then
    local offset = radius * 0.8
    r.ImGui_DrawList_AddQuad(draw_list,
      center_x, center_y - offset,
      center_x + offset, center_y,
      center_x, center_y + offset,
      center_x - offset, center_y,
      color, thickness)

  -- Pattern 4: Z (X shape)
  elseif pattern_id == 4 then
    local offset = radius * 0.8
    r.ImGui_DrawList_AddLine(draw_list, center_x - offset, center_y + offset, center_x + offset, center_y - offset,
      color, thickness)
    r.ImGui_DrawList_AddLine(draw_list, center_x + offset, center_y + offset, center_x - offset, center_y - offset,
      color, thickness)

  -- Pattern 5: Infinity (lemniscate curve)
  elseif pattern_id == 5 then
    local segments = 64
    for i = 0, segments - 1 do
      local t1 = (i / segments) * 2 * math.pi
      local t2 = ((i + 1) / segments) * 2 * math.pi
      local scale = radius * 1.3
      -- Lemniscate of Bernoulli formula
      local x1 = center_x + scale * math.sin(t1) / (1 + math.cos(t1) * math.cos(t1))
      local y1 = center_y + scale * math.sin(t1) * math.cos(t1) / (1 + math.cos(t1) * math.cos(t1))
      local x2 = center_x + scale * math.sin(t2) / (1 + math.cos(t2) * math.cos(t2))
      local y2 = center_y + scale * math.sin(t2) * math.cos(t2) / (1 + math.cos(t2) * math.cos(t2))
      r.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, color, thickness)
    end
  end
end

return Gesture
