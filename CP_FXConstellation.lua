local r=reaper
local sl=nil
local sp=r.GetResourcePath().."/Scripts/CP_Scripts/CP_ImGuiStyleLoader.lua"
if r.file_exists(sp)then local lf=dofile(sp)if lf then sl=lf()end

-- Granular system functions
function initializeGranularGrid()
local grid_size = state.granular_grid_size
state.granular_grains = {}

-- Create grains positioned at center of each grid square
for y = 0, grid_size - 1 do
for x = 0, grid_size - 1 do
-- Position grain at center of grid square (0 to 1 space)
local grain_x = (x + 0.5) / grid_size
local grain_y = (y + 0.5) / grid_size

table.insert(state.granular_grains, {
x = grain_x,
y = grain_y,
fx_states = {}, -- Will store wet/dry states for each FX
param_values = {} -- Will store parameter values for each selected param
})
end
end

randomizeGranularGrid()
end

function randomizeGranularGrid()
if not isTrackValid() then return end

for _, grain in ipairs(state.granular_grains) do
grain.fx_states = {}
grain.param_values = {}

-- Randomize wet/dry states for each FX based on density
for fx_id, fx_data in pairs(state.fx_data) do
-- Random chance based on FX density
grain.fx_states[fx_id] = math.random() < state.granular_fx_density
end

-- Randomize parameter values for selected parameters
for fx_id, fx_data in pairs(state.fx_data) do
grain.param_values[fx_id] = {}
for param_id, param_data in pairs(fx_data.params) do
if param_data.selected then
-- Use existing min/max ranges for randomization
local min_val = state.gesture_min
local max_val = state.gesture_max
local random_value = min_val + math.random() * (max_val - min_val)
grain.param_values[fx_id][param_id] = random_value
end
end
end
end
end

function getGrainInfluence(grain_x, grain_y, pos_x, pos_y)
-- Calculate distance from position to grain center
local dx = pos_x - grain_x
local dy = pos_y - grain_y
local distance = math.sqrt(dx * dx + dy * dy)

-- Grain radius is equivalent to one grid square width
local grain_radius = 1.0 / state.granular_grid_size

-- Linear falloff from center to edge of grain
local influence = math.max(0, 1.0 - (distance / grain_radius))
return influence
end

function applyGranularGesture(gx, gy)
if not isTrackValid() then return end
if #state.granular_grains == 0 then
initializeGranularGrid()
return
end

-- Calculate weighted average of all grain influences
local total_weights = {}
local weighted_fx_states = {}
local weighted_param_values = {}

-- Initialize accumulators
for fx_id, fx_data in pairs(state.fx_data) do
total_weights[fx_id] = 0
weighted_fx_states[fx_id] = 0
weighted_param_values[fx_id] = {}
for param_id, param_data in pairs(fx_data.params) do
if param_data.selected then
weighted_param_values[fx_id][param_id] = 0
end
end
end

-- Accumulate weighted values from all grains
for _, grain in ipairs(state.granular_grains) do
local influence = getGrainInfluence(grain.x, grain.y, gx, gy)
if influence > 0 then
for fx_id, fx_data in pairs(state.fx_data) do
total_weights[fx_id] = total_weights[fx_id] + influence

-- Weight the wet/dry state (0 or 1 becomes weighted average)
local fx_wet = grain.fx_states[fx_id] and 1 or 0
weighted_fx_states[fx_id] = weighted_fx_states[fx_id] + (fx_wet * influence)

-- Weight the parameter values
if grain.param_values[fx_id] then
for param_id, value in pairs(grain.param_values[fx_id]) do
weighted_param_values[fx_id][param_id] = weighted_param_values[fx_id][param_id] + (value * influence)
end
end
end
end
end

-- Apply the weighted results
for fx_id, fx_data in pairs(state.fx_data) do
if total_weights[fx_id] > 0 then
-- Calculate final wet/dry ratio (0 to 1)
local final_wet_ratio = weighted_fx_states[fx_id] / total_weights[fx_id]

-- Set FX wet/dry parameter (assuming this exists in REAPER)
-- Note: This might need adjustment based on how REAPER handles wet/dry
if r.TrackFX_SetParam then
-- Try to set wet parameter (usually the last parameter for many plugins)
local param_count = r.TrackFX_GetNumParams(state.track, fx_id)
if param_count > 0 then
-- Many plugins use the last parameter as wet/dry, but this varies
-- For now, we'll store this and let users map it manually if needed
-- r.TrackFX_SetParam(state.track, fx_id, param_count - 1, final_wet_ratio)
end
end

-- Set parameter values for selected params
for param_id, param_data in pairs(fx_data.params) do
if param_data.selected and weighted_param_values[fx_id][param_id] then
local final_value = weighted_param_values[fx_id][param_id] / total_weights[fx_id]
r.TrackFX_SetParam(state.track, fx_id, param_id, final_value)
param_data.current_value = final_value
end
end
end
end
end

function saveGranularSet(name)
if name == "" or #state.granular_grains == 0 then return end
state.granular_sets[name] = {
grid_size = state.granular_grid_size,
fx_density = state.granular_fx_density,
grains = {}
}

-- Deep copy grains data
for i, grain in ipairs(state.granular_grains) do
state.granular_sets[name].grains[i] = {
x = grain.x,
y = grain.y,
fx_states = {},
param_values = {}
}

-- Copy fx_states
for fx_id, state_val in pairs(grain.fx_states) do
state.granular_sets[name].grains[i].fx_states[fx_id] = state_val
end

-- Copy param_values
for fx_id, params in pairs(grain.param_values) do
state.granular_sets[name].grains[i].param_values[fx_id] = {}
for param_id, value in pairs(params) do
state.granular_sets[name].grains[i].param_values[fx_id][param_id] = value
end
end
end
scheduleSave()
end

function loadGranularSet(name)
local set_data = state.granular_sets[name]
if not set_data then return end

state.granular_grid_size = set_data.grid_size
state.granular_fx_density = set_data.fx_density
state.granular_grains = {}

-- Restore grains data
for i, grain_data in ipairs(set_data.grains) do
state.granular_grains[i] = {
x = grain_data.x,
y = grain_data.y,
fx_states = {},
param_values = {}
}

-- Restore fx_states
for fx_id, state_val in pairs(grain_data.fx_states) do
state.granular_grains[i].fx_states[fx_id] = state_val
end

-- Restore param_values
for fx_id, params in pairs(grain_data.param_values) do
state.granular_grains[i].param_values[fx_id] = {}
for param_id, value in pairs(params) do
state.granular_grains[i].param_values[fx_id][param_id] = value
end
end
end
end

function deleteGranularSet(name)
if state.granular_sets[name] then
state.granular_sets[name] = nil
scheduleSave()
end
end end
local ctx=r.ImGui_CreateContext('FX Constellation')
local pc,pv=0,0

local state={
track=nil,
fx_data={},
presets={},
track_selections={},
gesture_x=0.5,
gesture_y=0.5,
gesture_base_x=0.5,
gesture_base_y=0.5,
param_base_values={},
x_curve=1.0,
y_curve=1.0,
mapping_mode=0,
randomize_intensity=0.3,
randomize_min=0.0,
randomize_max=1.0,
gesture_min=0.0,
gesture_max=1.0,
morph_amount=0.5,
morph_preset_a=nil,
morph_preset_b=nil,
preset_name="Preset1",
selected_count=0,
last_fx_count=0,
last_fx_signature="",
random_min=3,
random_max=8,
fx_random_max={},
filter_keywords={},
param_filter="",
new_filter_word="",
show_filters=false,
param_ranges={},
param_xy_assign={},
gesture_active=false,
gesture_range=0.5,
exclusive_xy=false,
last_random_seed=os.time(),
needs_save=false,
save_timer=0,
scroll_offset=0,
selected_preset="",
preset_scroll=0,
show_preset_rename=false,
rename_preset_name="",
fx_panel_scroll_x=0,
fx_panel_scroll_y=0,
-- Performance optimization
last_update_time=0,
update_interval=0.05, -- Update every 50ms instead of every frame
dirty_params=false,
save_cooldown=0,
min_save_interval=1.0, -- Minimum 1 second between saves
-- Smooth motion and Random Walk
target_gesture_x=0.5,
target_gesture_y=0.5,
smooth_speed=0.15, -- Speed of smooth interpolation for all modes except random walk
max_gesture_speed=2.0, -- Maximum speed for gesture movement
-- Random Walk specific
random_walk_active=false,
random_walk_speed=2.0, -- Frequency of new target points (per second)
random_walk_smooth=0.8, -- How smooth the interpolation is (0=instant, 1=very smooth)
random_walk_jitter=0.2, -- Randomness in timing (0=regular, 1=very random)
random_walk_next_time=0,
random_walk_last_time=0,
-- Cached calculations for performance
param_cache={},
cache_dirty=true,
param_update_interval=0.02, -- Update FX params every 20ms max
-- Granular system
granular_grid_size=3, -- 2x2, 3x3, or 4x4
granular_fx_density=0.5, -- 0-1, percentage of FX that will be wet
granular_grains={}, -- Array of grain configurations
granular_sets={}, -- Saved grain sets
granular_set_name="GrainSet1"
}

local mapping_modes={"Linear","Exponential","Sine","Random Walk","Granular"}

function serialize(t)
local function ser(v)
local t=type(v)
if t=="string"then return string.format("%q",v)
elseif t=="number"or t=="boolean"then return tostring(v)
elseif t=="table"then
local s="{"
local first=true
for k,val in pairs(v)do
if not first then s=s..","end
first=false
if type(k)=="string"then
s=s.."["..ser(k).."]="..ser(val)
else
s=s..ser(val)
end
end
return s.."}"
else return"nil"end
end
return ser(t)
end

function deserialize(s)
if s==""then return{}end
local f,err=load("return "..s)
if f then
local ok,res=pcall(f)
if ok then return res end
end
return{}
end

function loadSettings()
local filters_str=r.GetExtState("CP_FXConstellation","filter_keywords")
if filters_str~=""then
state.filter_keywords={}
for word in filters_str:gmatch("[^,]+")do
table.insert(state.filter_keywords,word)
end
else
state.filter_keywords={"MIDI","CC","midi","Program","Bank","Channel","Wet","Dry"}
end

local saved_state=r.GetExtState("CP_FXConstellation","state")
if saved_state~=""then
local loaded=deserialize(saved_state)
if loaded then
state.track_selections=loaded.track_selections or{}
state.gesture_x=loaded.gesture_x or 0.5
state.gesture_y=loaded.gesture_y or 0.5
state.randomize_intensity=loaded.randomize_intensity or 0.3
state.randomize_min=loaded.randomize_min or 0.0
state.randomize_max=loaded.randomize_max or 1.0
state.gesture_min=loaded.gesture_min or 0.0
state.gesture_max=loaded.gesture_max or 1.0
state.gesture_range=loaded.gesture_range or 0.5
state.mapping_mode=loaded.mapping_mode or 0
state.x_curve=loaded.x_curve or 1.0
state.random_min=loaded.random_min or 3
state.random_max=loaded.random_max or 8
state.exclusive_xy=loaded.exclusive_xy or false
-- Load new motion settings
state.smooth_speed=loaded.smooth_speed or 0.15
state.max_gesture_speed=loaded.max_gesture_speed or 2.0
state.random_walk_speed=loaded.random_walk_speed or 2.0
state.random_walk_smooth=loaded.random_walk_smooth or 0.8
state.random_walk_jitter=loaded.random_walk_jitter or 0.2
state.target_gesture_x=loaded.target_gesture_x or state.gesture_x
state.target_gesture_y=loaded.target_gesture_y or state.gesture_y
-- Load granular settings
state.granular_grid_size=loaded.granular_grid_size or 3
state.granular_fx_density=loaded.granular_fx_density or 0.5
end
end

local saved_granular_sets=r.GetExtState("CP_FXConstellation","granular_sets")
if saved_granular_sets~=""then
state.granular_sets=deserialize(saved_granular_sets)or{}
else
state.granular_sets={}
end

local saved_presets=r.GetExtState("CP_FXConstellation","presets")
if saved_presets~=""then
state.presets=deserialize(saved_presets)or{}
end
end

-- Optimized save function with cooldown
function scheduleSave()
local current_time = r.time_precise()
if current_time - state.save_cooldown > state.min_save_interval then
state.needs_save=true
state.save_timer=current_time + 0.2 -- Small delay before saving
end
end

-- Smooth motion and random walk functions
function updateGestureMotion()
local current_time = r.time_precise()

if state.mapping_mode == 3 then -- Random Walk mode
if state.random_walk_active then
-- Check if it's time for a new target
if current_time >= state.random_walk_next_time then
-- Generate new random target
state.target_gesture_x = math.random()
state.target_gesture_y = math.random()

-- Calculate next time with jitter
local base_interval = 1.0 / state.random_walk_speed
local jitter_amount = base_interval * state.random_walk_jitter
local jitter = (math.random() * 2 - 1) * jitter_amount
state.random_walk_next_time = current_time + base_interval + jitter
state.random_walk_last_time = current_time
end

-- Smooth interpolation towards target
local progress = 1.0
if state.random_walk_next_time > state.random_walk_last_time then
progress = (current_time - state.random_walk_last_time) / (state.random_walk_next_time - state.random_walk_last_time)
progress = math.min(1.0, progress)
end

-- Apply smoothing curve
local smooth_progress = progress
if state.random_walk_smooth > 0 then
-- Ease in-out curve
smooth_progress = progress * progress * (3.0 - 2.0 * progress)
-- Apply smoothing intensity
smooth_progress = progress + (smooth_progress - progress) * state.random_walk_smooth
end

-- Interpolate position
state.gesture_x = state.gesture_x + (state.target_gesture_x - state.gesture_x) * smooth_progress * 0.1
state.gesture_y = state.gesture_y + (state.target_gesture_y - state.gesture_y) * smooth_progress * 0.1

-- Apply gesture
if state.mapping_mode == 4 then -- Granular mode
-- Initialize grains if needed
if not state.granular_grains or #state.granular_grains == 0 then
initializeGranularGrid()
end
applyGranularGesture(state.gesture_x, state.gesture_y)
else
applyGestureToSelection(state.gesture_x, state.gesture_y)
end
end
else
-- Smooth motion for other modes (when not actively dragging)
if not state.gesture_active and state.smooth_speed > 0 then
local dx = state.target_gesture_x - state.gesture_x
local dy = state.target_gesture_y - state.gesture_y
local distance = math.sqrt(dx*dx + dy*dy)

if distance > 0.001 then
-- Limit maximum speed
local max_distance = state.max_gesture_speed * (current_time - (state.last_smooth_update or current_time))
if distance > max_distance then
dx = dx / distance * max_distance
dy = dy / distance * max_distance
end

-- Apply smooth interpolation
state.gesture_x = state.gesture_x + dx * state.smooth_speed
state.gesture_y = state.gesture_y + dy * state.smooth_speed

-- Apply gesture
if state.mapping_mode == 4 then -- Granular mode
-- Initialize grains if needed
if not state.granular_grains or #state.granular_grains == 0 then
initializeGranularGrid()
end
applyGranularGesture(state.gesture_x, state.gesture_y)
else
applyGestureToSelection(state.gesture_x, state.gesture_y)
end
end
end
end

state.last_smooth_update = current_time
end

function checkSave()
if state.needs_save and r.time_precise()>state.save_timer then
saveSettings()
state.needs_save=false
state.save_cooldown = r.time_precise()
end
end

function saveSettings()
local filters_str=table.concat(state.filter_keywords,",")
r.SetExtState("CP_FXConstellation","filter_keywords",filters_str,true)

local save_data={
track_selections=state.track_selections,
gesture_x=state.gesture_x,
gesture_y=state.gesture_y,
randomize_intensity=state.randomize_intensity,
randomize_min=state.randomize_min,
randomize_max=state.randomize_max,
gesture_min=state.gesture_min,
gesture_max=state.gesture_max,
gesture_range=state.gesture_range,
mapping_mode=state.mapping_mode,
x_curve=state.x_curve,
random_min=state.random_min,
random_max=state.random_max,
exclusive_xy=state.exclusive_xy,
-- Save new motion settings
smooth_speed=state.smooth_speed,
max_gesture_speed=state.max_gesture_speed,
random_walk_speed=state.random_walk_speed,
random_walk_smooth=state.random_walk_smooth,
random_walk_jitter=state.random_walk_jitter,
target_gesture_x=state.target_gesture_x,
target_gesture_y=state.target_gesture_y,
-- Save granular settings
granular_grid_size=state.granular_grid_size,
granular_fx_density=state.granular_fx_density
}

r.SetExtState("CP_FXConstellation","state",serialize(save_data),true)
r.SetExtState("CP_FXConstellation","presets",serialize(state.presets),true)
r.SetExtState("CP_FXConstellation","granular_sets",serialize(state.granular_sets),true)
end

function isTrackValid()
if not state.track then return false end
return r.ValidatePtr(state.track,"MediaTrack*")
end

function getTrackGUID()
if not isTrackValid()then return nil end
local _,guid=r.GetSetMediaTrackInfo_String(state.track,"GUID","",false)
return guid
end

function saveTrackSelection()
local guid=getTrackGUID()
if not guid then return end
local selection={}
local ranges={}
local xy_assign={}
local fx_rand_max={}
local base_values={}

for fx_id,fx_data in pairs(state.fx_data)do
fx_rand_max[fx_id]=state.fx_random_max[fx_id]or 3
for param_id,param_data in pairs(fx_data.params)do
local key=fx_data.full_name.."||"..param_data.name
if param_data.selected then
selection[key]=true
end
ranges[key]=state.param_ranges[fx_id.."_"..param_id.."_range"]or 1.0
xy_assign[key]={
x=state.param_xy_assign[fx_id.."_"..param_id.."_x"]~=false,
y=state.param_xy_assign[fx_id.."_"..param_id.."_y"]~=false
}
base_values[key]=param_data.base_value
end
end

state.track_selections[guid]={
selection=selection,
ranges=ranges,
xy_assign=xy_assign,
fx_random_max=fx_rand_max,
base_values=base_values,
gesture_base_x=state.gesture_base_x,
gesture_base_y=state.gesture_base_y
}
scheduleSave()
end

function loadTrackSelection()
local guid=getTrackGUID()
if not guid then return end
local track_data=state.track_selections[guid]
if not track_data then 
captureBaseValues()
return 
end

local selection=track_data.selection or{}
local ranges=track_data.ranges or{}
local xy_assign=track_data.xy_assign or{}
local fx_rand_max=track_data.fx_random_max or{}
local base_values=track_data.base_values or{}

state.gesture_base_x=track_data.gesture_base_x or 0.5
state.gesture_base_y=track_data.gesture_base_y or 0.5

for fx_id,fx_data in pairs(state.fx_data)do
if fx_rand_max[fx_id]then
state.fx_random_max[fx_id]=fx_rand_max[fx_id]
end
for param_id,param_data in pairs(fx_data.params)do
local key=fx_data.full_name.."||"..param_data.name
param_data.selected=selection[key]or false
param_data.base_value=base_values[key]or param_data.current_value
state.param_ranges[fx_id.."_"..param_id.."_range"]=ranges[key]or 1.0
local xy=xy_assign[key]or{x=true,y=true}
state.param_xy_assign[fx_id.."_"..param_id.."_x"]=xy.x
state.param_xy_assign[fx_id.."_"..param_id.."_y"]=xy.y
end
end
updateSelectedCount()
end

function createFXSignature()
if not isTrackValid()then return ""end
local sig=""
local fx_count=r.TrackFX_GetCount(state.track)
for fx=0,fx_count-1 do
local _,fx_name=r.TrackFX_GetFXName(state.track,fx,"")
sig=sig..fx_name..":"..r.TrackFX_GetNumParams(state.track,fx)..";"
end
return sig
end

function shouldFilterParam(param_name)
local lower_name=param_name:lower()
for _,keyword in ipairs(state.filter_keywords)do
if lower_name:find(keyword:lower(),1,true)then
return true
end
end
if state.param_filter~=""then
return not lower_name:find(state.param_filter:lower(),1,true)
end
return false
end

function extractFXName(full_name)
local clean_name=full_name:match("^[^:]*:%s*(.+)")or full_name
clean_name=clean_name:gsub("%(.-%)","")
clean_name=clean_name:match("^%s*(.-)%s*$")
if clean_name:len()>25 then
clean_name=clean_name:sub(1,22).."..."
end
return clean_name
end

function scanTrackFX()
if not isTrackValid()then return end
state.fx_data={}
local fx_count=r.TrackFX_GetCount(state.track)

for fx=0,fx_count-1 do
local _,fx_name=r.TrackFX_GetFXName(state.track,fx,"")
local param_count=r.TrackFX_GetNumParams(state.track,fx)

state.fx_data[fx]={
name=extractFXName(fx_name),
full_name=fx_name,
enabled=r.TrackFX_GetEnabled(state.track,fx),
params={}
}

if state.fx_random_max[fx]==nil then
state.fx_random_max[fx]=3
end

for param=0,param_count-1 do
local _,param_name=r.TrackFX_GetParamName(state.track,fx,param,"")
if not shouldFilterParam(param_name)then
local value=r.TrackFX_GetParam(state.track,fx,param)
state.fx_data[fx].params[param]={
name=param_name,
current_value=value,
base_value=value,
min_val=0,
max_val=1,
selected=false,
fx_id=fx,
param_id=param
}
end
end
end

state.last_fx_count=fx_count
state.last_fx_signature=createFXSignature()
loadTrackSelection()
updateSelectedCount()
end

-- Optimized FX changes check - only check every update interval
function checkForFXChanges()
if not isTrackValid()then return false end
local current_time = r.time_precise()
if current_time - state.last_update_time < state.update_interval then
return false
end
state.last_update_time = current_time

local current_fx_count=r.TrackFX_GetCount(state.track)
local current_signature=createFXSignature()
if current_fx_count~=state.last_fx_count or current_signature~=state.last_fx_signature then
scanTrackFX()
return true
end
return false
end

function updateSelectedCount()
state.selected_count=0
for fx_id,fx_data in pairs(state.fx_data)do
for param_id,param_data in pairs(fx_data.params)do
if param_data.selected then
state.selected_count=state.selected_count+1
end
end
end
end

function selectAllParams(params,selected)
for _,param in pairs(params)do
param.selected=selected
end
updateSelectedCount()
saveTrackSelection()
end

function getParamRange(fx_id,param_id)
local key=fx_id.."_"..param_id.."_range"
return state.param_ranges[key]or 1.0
end

function setParamRange(fx_id,param_id,range)
local key=fx_id.."_"..param_id.."_range"
state.param_ranges[key]=range
saveTrackSelection()
end

function getParamXYAssign(fx_id,param_id)
local x_key=fx_id.."_"..param_id.."_x"
local y_key=fx_id.."_"..param_id.."_y"
return state.param_xy_assign[x_key]~=false,state.param_xy_assign[y_key]~=false
end

function setParamXYAssign(fx_id,param_id,axis,value)
local key=fx_id.."_"..param_id.."_"..axis
state.param_xy_assign[key]=value
if state.exclusive_xy and value then
local other_axis=axis=="x"and"y"or"x"
local other_key=fx_id.."_"..param_id.."_"..other_axis
state.param_xy_assign[other_key]=false
end
saveTrackSelection()
end

function randomSelectParams(params,fx_id)
selectAllParams(params,false)
local param_list={}
for id,param in pairs(params)do
table.insert(param_list,param)
end
if #param_list==0 then return end

local max_count=state.fx_random_max[fx_id]or 3
local count=math.random(1,math.min(max_count,#param_list))

for i=1,count do
local idx=math.random(1,#param_list)
param_list[idx].selected=true
table.remove(param_list,idx)
end

updateSelectedCount()
captureBaseValues()
saveTrackSelection()
end

-- New function: Randomize base values for selected params in an FX
function randomizeBaseValues(params,fx_id)
if not isTrackValid()then return end

for param_id,param_data in pairs(params)do
if param_data.selected then
local new_base = math.random()
param_data.base_value = new_base
state.param_base_values[fx_id.."_"..param_id] = new_base
r.TrackFX_SetParam(state.track, fx_id, param_id, new_base)
param_data.current_value = new_base
end
end
saveTrackSelection()
end

function randomizeXYAssign(params,fx_id)
for param_id,param_data in pairs(params)do
if param_data.selected then
local rand=math.random()
if state.exclusive_xy then
setParamXYAssign(fx_id,param_id,"x",rand<0.5)
setParamXYAssign(fx_id,param_id,"y",rand>=0.5)
else
if rand<0.33 then
setParamXYAssign(fx_id,param_id,"x",true)
setParamXYAssign(fx_id,param_id,"y",false)
elseif rand<0.66 then
setParamXYAssign(fx_id,param_id,"x",false)
setParamXYAssign(fx_id,param_id,"y",true)
else
setParamXYAssign(fx_id,param_id,"x",true)
setParamXYAssign(fx_id,param_id,"y",true)
end
end
end
end
end

function globalRandomXYAssign()
for fx_id,fx_data in pairs(state.fx_data)do
randomizeXYAssign(fx_data.params,fx_id)
end
end

function randomizeRanges(params,fx_id)
for param_id,param_data in pairs(params)do
if param_data.selected then
local new_range=0.1+math.random()*0.9
setParamRange(fx_id,param_id,new_range)
end
end
end

function globalRandomRanges()
for fx_id,fx_data in pairs(state.fx_data)do
randomizeRanges(fx_data.params,fx_id)
end
end

function globalRandomSelect()
for fx_id,fx_data in pairs(state.fx_data)do
selectAllParams(fx_data.params,false)
end

local all_params={}
for fx_id,fx_data in pairs(state.fx_data)do
for param_id,param_data in pairs(fx_data.params)do
table.insert(all_params,param_data)
end
end

if #all_params==0 then return end
local count=math.random(state.random_min,math.min(state.random_max,#all_params))

for i=1,count do
local idx=math.random(1,#all_params)
all_params[idx].selected=true
table.remove(all_params,idx)
end

updateSelectedCount()
captureBaseValues()
saveTrackSelection()
end

function randomizeFXOrder()
if not isTrackValid()then return end
local fx_count=r.TrackFX_GetCount(state.track)
if fx_count<2 then return end

r.Undo_BeginBlock()
for i=fx_count-1,1,-1 do
local j=math.random(0,i)
if i~=j then
local temp_pos=fx_count
r.TrackFX_CopyToTrack(state.track,i,state.track,temp_pos,true)
r.TrackFX_CopyToTrack(state.track,j,state.track,i,true)
r.TrackFX_CopyToTrack(state.track,temp_pos,state.track,j,true)
end
end
r.Undo_EndBlock("Randomize FX order",-1)
scanTrackFX()
end

function captureBaseValues()
state.param_base_values={}
state.gesture_base_x=state.gesture_x
state.gesture_base_y=state.gesture_y

for fx_id,fx_data in pairs(state.fx_data)do
for param_id,param_data in pairs(fx_data.params)do
if param_data.selected then
param_data.base_value=param_data.current_value
state.param_base_values[fx_id.."_"..param_id]=param_data.current_value
end
end
end
end

function updateParamBaseValue(fx_id,param_id,new_value)
if not isTrackValid()then return end
local param_data=state.fx_data[fx_id].params[param_id]
if param_data then
param_data.base_value=new_value
state.param_base_values[fx_id.."_"..param_id]=new_value
r.TrackFX_SetParam(state.track,fx_id,param_id,new_value)
param_data.current_value=new_value
saveTrackSelection()
end
end

function calculateAsymmetricRange(base,range,intensity,min_limit,max_limit)
local max_range=range*intensity*0.5
local up_space=max_limit-base
local down_space=base-min_limit
local up_range=math.min(max_range,up_space)
local down_range=math.min(max_range,down_space)

if up_range<max_range then
local excess=max_range-up_range
down_range=math.min(down_range+excess,down_space)
elseif down_range<max_range then
local excess=max_range-down_range
up_range=math.min(up_range+excess,up_space)
end

return up_range,down_range
end

function applyGestureToSelection(gx,gy)
if not isTrackValid()then return end
local offset_x=(gx-state.gesture_base_x)*2
local offset_y=(gy-state.gesture_base_y)*2

for fx_id,fx_data in pairs(state.fx_data)do
for param_id,param_data in pairs(fx_data.params)do
if param_data.selected then
local param_range=getParamRange(fx_id,param_id)
local x_assign,y_assign=getParamXYAssign(fx_id,param_id)
local base_key=fx_id.."_"..param_id
local base_value=state.param_base_values[base_key]or param_data.base_value
local up_range,down_range=calculateAsymmetricRange(base_value,param_range,state.gesture_range,state.gesture_min,state.gesture_max)

local new_value=base_value
local x_contribution=0
local y_contribution=0

if x_assign then
local x_offset=offset_x
if state.mapping_mode==0 then
x_contribution=x_offset>0 and x_offset*up_range or x_offset*down_range
elseif state.mapping_mode==1 then
local exp_offset=(math.abs(x_offset)^state.x_curve)*(x_offset<0 and -1 or 1)
x_contribution=exp_offset>0 and exp_offset*up_range or exp_offset*down_range
elseif state.mapping_mode==2 then
x_contribution=0.5*math.sin(x_offset*math.pi*2)*param_range*state.gesture_range
elseif state.mapping_mode==3 then
x_contribution=x_offset*0.2*param_range*state.gesture_range
end
end

if y_assign then
local y_offset=offset_y
if state.mapping_mode==0 then
y_contribution=y_offset>0 and y_offset*up_range or y_offset*down_range
elseif state.mapping_mode==1 then
local exp_offset=(math.abs(y_offset)^state.x_curve)*(y_offset<0 and -1 or 1)
y_contribution=exp_offset>0 and exp_offset*up_range or exp_offset*down_range
elseif state.mapping_mode==2 then
y_contribution=0.5*math.sin(y_offset*math.pi*2)*param_range*state.gesture_range
elseif state.mapping_mode==3 then
y_contribution=y_offset*0.2*param_range*state.gesture_range
end
end

if x_assign and y_assign then
new_value=base_value+(x_contribution+y_contribution)/2
elseif x_assign then
new_value=base_value+x_contribution
elseif y_assign then
new_value=base_value+y_contribution
end

new_value=math.max(state.gesture_min,math.min(state.gesture_max,new_value))
r.TrackFX_SetParam(state.track,fx_id,param_id,new_value)
param_data.current_value=new_value
end
end
end
end

function randomizeSelection()
if not isTrackValid()then return end
state.last_random_seed=os.time()+math.random(1000)
math.randomseed(state.last_random_seed)

for fx_id,fx_data in pairs(state.fx_data)do
for param_id,param_data in pairs(fx_data.params)do
if param_data.selected then
local param_range=getParamRange(fx_id,param_id)
local up_range,down_range=calculateAsymmetricRange(param_data.base_value,param_range,state.randomize_intensity,state.randomize_min,state.randomize_max)
local rand=math.random()*2-1
local variation=rand>0 and rand*up_range or rand*down_range
local new_value=param_data.base_value+variation
new_value=math.max(state.randomize_min,math.min(state.randomize_max,new_value))
r.TrackFX_SetParam(state.track,fx_id,param_id,new_value)
param_data.current_value=new_value
param_data.base_value=new_value
end
end
end

captureBaseValues()
saveTrackSelection()
end

function savePreset(name)
if name==""then return end
local preset={}
for fx_id,fx_data in pairs(state.fx_data)do
preset[fx_data.full_name]={}
for param_id,param_data in pairs(fx_data.params)do
if param_data.selected then
preset[fx_data.full_name][param_data.name]=param_data.current_value
end
end
end
state.presets[name]=preset
scheduleSave()
end

function loadPreset(name)
if not isTrackValid()then return end
local preset=state.presets[name]
if not preset then return end

for fx_id,fx_data in pairs(state.fx_data)do
local fx_preset=preset[fx_data.full_name]
if fx_preset then
for param_id,param_data in pairs(fx_data.params)do
local value=fx_preset[param_data.name]
if value then
r.TrackFX_SetParam(state.track,fx_id,param_id,value)
param_data.current_value=value
param_data.base_value=value
end
end
end
end
captureBaseValues()
end

function deletePreset(name)
if state.presets[name]then
state.presets[name]=nil
if state.selected_preset==name then
state.selected_preset=""
end
scheduleSave()
end
end

function renamePreset(old_name,new_name)
if state.presets[old_name]and new_name~=""and old_name~=new_name then
state.presets[new_name]=state.presets[old_name]
state.presets[old_name]=nil
if state.selected_preset==old_name then
state.selected_preset=new_name
end
scheduleSave()
end
end

function captureToMorph(slot)
local preset={}
for fx_id,fx_data in pairs(state.fx_data)do
preset[fx_data.full_name]={}
for param_id,param_data in pairs(fx_data.params)do
if param_data.selected then
preset[fx_data.full_name][param_data.name]=param_data.current_value
end
end
end

if slot==1 then
state.morph_preset_a=preset
else
state.morph_preset_b=preset
end
end

function morphBetweenPresets(amount)
if not state.morph_preset_a or not state.morph_preset_b or not isTrackValid()then return end

for fx_id,fx_data in pairs(state.fx_data)do
local preset_a=state.morph_preset_a[fx_data.full_name]
local preset_b=state.morph_preset_b[fx_data.full_name]
if preset_a and preset_b then
for param_id,param_data in pairs(fx_data.params)do
local value_a=preset_a[param_data.name]
local value_b=preset_b[param_data.name]
if value_a and value_b then
local morphed_value=value_a*(1-amount)+value_b*amount
r.TrackFX_SetParam(state.track,fx_id,param_id,morphed_value)
param_data.current_value=morphed_value
end
end
end
end
end

function drawInterface()
if sl then
local success,colors,vars=sl.applyToContext(ctx)
if success then pc,pv=colors,vars end
end

r.ImGui_SetNextWindowSize(ctx,1400,800,r.ImGui_Cond_FirstUseEver())
local visible,open=r.ImGui_Begin(ctx,'FX Constellation',true)

if visible then
checkSave()
-- Update gesture motion (smooth motion and random walk)
updateGestureMotion()

local new_track=r.GetSelectedTrack(0,0)
if new_track~=state.track then
if state.track then saveTrackSelection()end
state.track=new_track
if state.track then scanTrackFX()end
end

if isTrackValid()then
checkForFXChanges()
end

if not isTrackValid()then
r.ImGui_Text(ctx,"No track selected")
r.ImGui_End(ctx)
if sl then sl.clearStyles(ctx,pc,pv)end
return open
end

-- Top controls
if r.ImGui_Button(ctx,state.show_filters and"Hide Filters"or"Show Filters")then
state.show_filters=not state.show_filters
end

if state.show_filters then
r.ImGui_Text(ctx,"Filter Keywords:")
local changed,new_word=r.ImGui_InputText(ctx,"Add Filter",state.new_filter_word)
if changed then state.new_filter_word=new_word end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"Add")and state.new_filter_word~=""then
table.insert(state.filter_keywords,state.new_filter_word)
state.new_filter_word=""
scheduleSave()
scanTrackFX()
end

for i,keyword in ipairs(state.filter_keywords)do
r.ImGui_Text(ctx,keyword)
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"X##"..i)then
table.remove(state.filter_keywords,i)
scheduleSave()
scanTrackFX()
break
end
end
r.ImGui_Separator(ctx)
end

r.ImGui_Text(ctx,"Param Filter:")
r.ImGui_SameLine(ctx)
r.ImGui_SetNextItemWidth(ctx,200)
local changed,new_filter=r.ImGui_InputText(ctx,"##paramfilter",state.param_filter)
if changed then
state.param_filter=new_filter
scanTrackFX()
end

r.ImGui_Text(ctx,"Selected: "..state.selected_count)
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"All")then
for fx_id,fx_data in pairs(state.fx_data)do
selectAllParams(fx_data.params,true)
end
saveTrackSelection()
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"Clear")then
for fx_id,fx_data in pairs(state.fx_data)do
selectAllParams(fx_data.params,false)
end
saveTrackSelection()
end

r.ImGui_SameLine(ctx)
r.ImGui_Text(ctx,"Random:")
r.ImGui_SameLine(ctx)
r.ImGui_SetNextItemWidth(ctx,50)
local changed,new_min=r.ImGui_SliderInt(ctx,"##min",state.random_min,1,20)
if changed then state.random_min=new_min end
r.ImGui_SameLine(ctx)
r.ImGui_Text(ctx,"-")
r.ImGui_SameLine(ctx)
r.ImGui_SetNextItemWidth(ctx,50)
local changed,new_max=r.ImGui_SliderInt(ctx,"##max",state.random_max,1,30)
if changed then 
state.random_max=math.max(new_max,state.random_min)
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"Go")then
globalRandomSelect()
saveTrackSelection()
end

r.ImGui_SameLine(ctx)
r.ImGui_Text(ctx," ")
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"RandXY")then
globalRandomXYAssign()
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"RandRng")then
globalRandomRanges()
end
r.ImGui_SameLine(ctx)
local changed,exclusive=r.ImGui_Checkbox(ctx,"Exclusive XY",state.exclusive_xy)
if changed then
state.exclusive_xy=exclusive
scheduleSave()
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"RandFX")then
randomizeFXOrder()
end

r.ImGui_Separator(ctx)

-- Main horizontal layout
local window_width=r.ImGui_GetContentRegionAvail(ctx)
local left_width=window_width*0.65
local right_width=window_width*0.35

-- Left panel with horizontal scrolling
if r.ImGui_BeginChild(ctx,"LeftPanel",left_width,-1,0,r.ImGui_WindowFlags_HorizontalScrollbar())then
local fx_count=0
for _ in pairs(state.fx_data)do fx_count=fx_count+1 end

if fx_count>0 then
local fx_width=320 -- Increased width for better layout
local total_width = fx_width * fx_count + 20 * (fx_count - 1) -- Include separators

-- Set cursor to enable horizontal scrolling
r.ImGui_SetCursorPosX(ctx, 0)

for fx_id=0,fx_count-1 do
if fx_id>0 then 
-- Add spacing between FX
r.ImGui_SameLine(ctx)
r.ImGui_Dummy(ctx, 20, 0) -- Add spacing between FX
r.ImGui_SameLine(ctx)
end

local fx_data=state.fx_data[fx_id]
if fx_data then
r.ImGui_BeginGroup(ctx)
r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_ChildBorderSize(),1)

if r.ImGui_BeginChild(ctx,"FX"..fx_id,fx_width,-1)then
-- FX Header
r.ImGui_Text(ctx,fx_data.name)
r.ImGui_SameLine(ctx)
local enabled=fx_data.enabled
if r.ImGui_Checkbox(ctx,"##enabled"..fx_id,enabled)then
r.TrackFX_SetEnabled(state.track,fx_id,not enabled)
fx_data.enabled=not enabled
end

r.ImGui_Separator(ctx)

-- Control buttons row 1
if r.ImGui_Button(ctx,"All##"..fx_id,50)then
selectAllParams(fx_data.params,true)
saveTrackSelection()
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"None##"..fx_id,50)then
selectAllParams(fx_data.params,false)
saveTrackSelection()
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"Rnd##"..fx_id,40)then
randomSelectParams(fx_data.params,fx_id)
saveTrackSelection()
end
r.ImGui_SameLine(ctx)
r.ImGui_SetNextItemWidth(ctx,50)
local changed,new_max=r.ImGui_SliderInt(ctx,"##max"..fx_id,state.fx_random_max[fx_id]or 3,1,10)
if changed then
state.fx_random_max[fx_id]=new_max
saveTrackSelection()
end

-- Control buttons row 2  
if r.ImGui_Button(ctx,"RandXY##"..fx_id,65)then
randomizeXYAssign(fx_data.params,fx_id)
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"RandRng##"..fx_id,70)then
randomizeRanges(fx_data.params,fx_id)
end
r.ImGui_SameLine(ctx)
-- New Random Base button
if r.ImGui_Button(ctx,"RndBase##"..fx_id,75)then
randomizeBaseValues(fx_data.params,fx_id)
end

r.ImGui_Separator(ctx)

-- Parameters table
if r.ImGui_BeginTable(ctx,"params"..fx_id,5,r.ImGui_TableFlags_SizingFixedFit())then
r.ImGui_TableSetupColumn(ctx,"Name",0,100) -- Increased width
r.ImGui_TableSetupColumn(ctx,"X",0,25)
r.ImGui_TableSetupColumn(ctx,"Y",0,25)
r.ImGui_TableSetupColumn(ctx,"Range",0,60) -- Increased width
r.ImGui_TableSetupColumn(ctx,"Base",0,80) -- Increased width

for param_id,param_data in pairs(fx_data.params)do
r.ImGui_TableNextRow(ctx)
r.ImGui_TableNextColumn(ctx)

local param_name = param_data.name
if #param_name > 12 then
param_name = param_name:sub(1,9) .. "..."
end

local changed,selected=r.ImGui_Checkbox(ctx,param_name.."##"..fx_id.."_"..param_id,param_data.selected)
if changed then
param_data.selected=selected
updateSelectedCount()
if selected then
param_data.base_value=param_data.current_value
end
saveTrackSelection()
end

r.ImGui_TableNextColumn(ctx)
local x_assign,y_assign=getParamXYAssign(fx_id,param_id)
if r.ImGui_Button(ctx,x_assign and"X"or"-".."##x"..fx_id.."_"..param_id,22,22)then
setParamXYAssign(fx_id,param_id,"x",not x_assign)
end

r.ImGui_TableNextColumn(ctx)
if r.ImGui_Button(ctx,y_assign and"Y"or"-".."##y"..fx_id.."_"..param_id,22,22)then
setParamXYAssign(fx_id,param_id,"y",not y_assign)
end

r.ImGui_TableNextColumn(ctx)
r.ImGui_SetNextItemWidth(ctx,55)
local range=getParamRange(fx_id,param_id)
local changed,new_range=r.ImGui_SliderDouble(ctx,"##r"..fx_id.."_"..param_id,range,0.1,1.0,"%.1f")
if changed then
setParamRange(fx_id,param_id,new_range)
end

r.ImGui_TableNextColumn(ctx)
if param_data.selected then
r.ImGui_SetNextItemWidth(ctx,75) -- Increased width to fix truncation
local changed,new_base=r.ImGui_SliderDouble(ctx,"##b"..fx_id.."_"..param_id,param_data.base_value,0.0,1.0,"%.2f")
if changed then
updateParamBaseValue(fx_id,param_id,new_base)
end
else
r.ImGui_Text(ctx,string.format("%.2f",param_data.current_value))
end

if r.ImGui_IsItemHovered(ctx)then
local xy_text=""
if x_assign and y_assign then xy_text=" [XY]"
elseif x_assign then xy_text=" [X]"
elseif y_assign then xy_text=" [Y]"
end
r.ImGui_SetTooltip(ctx,param_data.name..": "..string.format("%.3f (Base: %.3f, Range: %.1f)",param_data.current_value,param_data.base_value,range)..xy_text)
end
end
r.ImGui_EndTable(ctx)
end

r.ImGui_EndChild(ctx)
end
r.ImGui_PopStyleVar(ctx)
r.ImGui_EndGroup(ctx)
end
end
else
r.ImGui_Text(ctx,"No FX found")
end
r.ImGui_EndChild(ctx)
end

r.ImGui_SameLine(ctx)

-- Right panel
if r.ImGui_BeginChild(ctx,"RightPanel",right_width,0)then
if state.selected_count>0 then
r.ImGui_Text(ctx,"Gesture Control")
r.ImGui_Separator(ctx)

-- XY Pad
local pad_size=200
local draw_list=r.ImGui_GetWindowDrawList(ctx)
local cursor_pos_x,cursor_pos_y=r.ImGui_GetCursorScreenPos(ctx)
r.ImGui_InvisibleButton(ctx,"xy_pad",pad_size,pad_size)

if r.ImGui_IsItemActive(ctx)then
local mouse_x,mouse_y=r.ImGui_GetMousePos(ctx)
local click_x=(mouse_x-cursor_pos_x)/pad_size
local click_y=1.0-(mouse_y-cursor_pos_y)/pad_size
if not state.gesture_active then
state.gesture_active=true
captureBaseValues()
end

if state.mapping_mode == 3 then -- Random Walk mode
-- Stop automatic movement when user interacts
state.random_walk_active = false
end

-- Set target position for smooth motion or direct position for immediate modes
if state.mapping_mode == 3 or state.smooth_speed == 0 then
-- Direct control for Random Walk or when smoothing is disabled
state.gesture_x=click_x
state.gesture_y=click_y
if state.mapping_mode == 4 then -- Granular mode
-- Initialize grains if needed
if not state.granular_grains or #state.granular_grains == 0 then
initializeGranularGrid()
end
applyGranularGesture(state.gesture_x, state.gesture_y)
else
applyGestureToSelection(state.gesture_x,state.gesture_y)
end
else
-- Smooth motion for other modes
state.target_gesture_x=click_x
state.target_gesture_y=click_y
end
else
if state.gesture_active then
state.gesture_active=false
end
end

-- Draw XY pad
r.ImGui_DrawList_AddRectFilled(draw_list,cursor_pos_x,cursor_pos_y,cursor_pos_x+pad_size,cursor_pos_y+pad_size,0x222222FF)
r.ImGui_DrawList_AddRect(draw_list,cursor_pos_x,cursor_pos_y,cursor_pos_x+pad_size,cursor_pos_y+pad_size,0x666666FF)
r.ImGui_DrawList_AddLine(draw_list,cursor_pos_x+pad_size/2,cursor_pos_y,cursor_pos_x+pad_size/2,cursor_pos_y+pad_size,0x444444FF)
r.ImGui_DrawList_AddLine(draw_list,cursor_pos_x,cursor_pos_y+pad_size/2,cursor_pos_x+pad_size,cursor_pos_y+pad_size/2,0x444444FF)

-- Draw granular grid overlay if in granular mode
if state.mapping_mode == 4 and state.granular_grains and #state.granular_grains > 0 then
local grid_size = state.granular_grid_size
-- Draw grid lines (only internal lines, not borders)
for i = 1, grid_size - 1 do
local line_x = cursor_pos_x + (i / grid_size) * pad_size
local line_y = cursor_pos_y + (i / grid_size) * pad_size
r.ImGui_DrawList_AddLine(draw_list, line_x, cursor_pos_y, line_x, cursor_pos_y + pad_size, 0x444444AA)
r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, line_y, cursor_pos_x + pad_size, line_y, 0x444444AA)
end

-- Draw grain centers and influence circles
for _, grain in ipairs(state.granular_grains) do
local grain_screen_x = cursor_pos_x + grain.x * pad_size
local grain_screen_y = cursor_pos_y + (1.0 - grain.y) * pad_size
-- Grain radius is one grid square width
local grain_radius = (pad_size / grid_size)

-- Draw influence circle (semi-transparent)
r.ImGui_DrawList_AddCircle(draw_list, grain_screen_x, grain_screen_y, grain_radius, 0x66666644, 0, 1)
-- Draw grain center dot
r.ImGui_DrawList_AddCircleFilled(draw_list, grain_screen_x, grain_screen_y, 4, 0xFFFFFFFF)
end
elseif state.mapping_mode == 4 then
-- Show grid without grains if grains not initialized yet
local grid_size = state.granular_grid_size
for i = 1, grid_size - 1 do
local line_x = cursor_pos_x + (i / grid_size) * pad_size
local line_y = cursor_pos_y + (i / grid_size) * pad_size
r.ImGui_DrawList_AddLine(draw_list, line_x, cursor_pos_y, line_x, cursor_pos_y + pad_size, 0x444444AA)
r.ImGui_DrawList_AddLine(draw_list, cursor_pos_x, line_y, cursor_pos_x + pad_size, line_y, 0x444444AA)
end
end

local dot_x=cursor_pos_x+state.gesture_x*pad_size
local dot_y=cursor_pos_y+(1.0-state.gesture_y)*pad_size
r.ImGui_DrawList_AddCircleFilled(draw_list,dot_x,dot_y,6,0xFFFFFFFF)

-- Show target position for smooth motion modes (except Random Walk and Granular)
if state.mapping_mode ~= 3 and state.mapping_mode ~= 4 and state.smooth_speed > 0 then
local target_dot_x=cursor_pos_x+state.target_gesture_x*pad_size
local target_dot_y=cursor_pos_y+(1.0-state.target_gesture_y)*pad_size
r.ImGui_DrawList_AddCircle(draw_list,target_dot_x,target_dot_y,4,0x888888FF,0,2)
end

r.ImGui_Text(ctx,string.format("%.2f, %.2f",state.gesture_x,state.gesture_y))

-- Gesture controls
local mapping_items=table.concat(mapping_modes,"\0").."\0"
local changed,new_mode=r.ImGui_Combo(ctx,"Map",state.mapping_mode,mapping_items)
if changed then 
state.mapping_mode=new_mode
if new_mode == 3 then
-- Initialize Random Walk
state.random_walk_next_time = r.time_precise() + 1.0 / state.random_walk_speed
state.target_gesture_x = state.gesture_x
state.target_gesture_y = state.gesture_y
elseif new_mode == 4 then
-- Initialize Granular mode (defer initialization to avoid scope issues)
-- Will be initialized in updateGestureMotion when needed
state.granular_grains = state.granular_grains or {}
end
end

-- Mode-specific controls
if state.mapping_mode==1 then
local changed,new_curve=r.ImGui_SliderDouble(ctx,"Curve",state.x_curve,0.1,3.0)
if changed then state.x_curve=new_curve end
elseif state.mapping_mode==3 then
-- Random Walk controls
r.ImGui_Text(ctx,"Random Walk Controls:")
local changed,new_speed=r.ImGui_SliderDouble(ctx,"Speed",state.random_walk_speed,0.1,10.0,"%.1f Hz")
if changed then state.random_walk_speed=new_speed end

local changed,new_smooth=r.ImGui_SliderDouble(ctx,"Smooth",state.random_walk_smooth,0.0,1.0)
if changed then state.random_walk_smooth=new_smooth end

local changed,new_jitter=r.ImGui_SliderDouble(ctx,"Jitter",state.random_walk_jitter,0.0,1.0)
if changed then state.random_walk_jitter=new_jitter end

if r.ImGui_Button(ctx,state.random_walk_active and "Stop Auto" or "Start Auto",100)then
state.random_walk_active = not state.random_walk_active
if state.random_walk_active then
state.random_walk_next_time = r.time_precise() + 1.0 / state.random_walk_speed
captureBaseValues()
end
end
elseif state.mapping_mode==4 then
-- Granular controls
r.ImGui_Text(ctx,"Granular Controls:")

-- Grid size control
local grid_sizes = {"2x2", "3x3", "4x4"}
local grid_values = {2, 3, 4}
local current_grid_idx = 1
for i, val in ipairs(grid_values) do
if val == state.granular_grid_size then
current_grid_idx = i - 1
break
end
end

local changed, new_grid_idx = r.ImGui_Combo(ctx, "Grid Size", current_grid_idx, table.concat(grid_sizes, "\0") .. "\0")
if changed then
state.granular_grid_size = grid_values[new_grid_idx + 1]
initializeGranularGrid()
end

-- FX Density control
local changed, new_density = r.ImGui_SliderDouble(ctx, "FX Density", state.granular_fx_density, 0.0, 1.0, "%.2f")
if changed then
state.granular_fx_density = new_density
end

-- Randomize grains button
if r.ImGui_Button(ctx, "Randomize Grains", 120) then
if not state.granular_grains or #state.granular_grains == 0 then
initializeGranularGrid()
else
randomizeGranularGrid()
end
end

-- Grain set management
r.ImGui_Separator(ctx)
r.ImGui_Text(ctx, "Grain Sets:")

local changed, new_name = r.ImGui_InputText(ctx, "Set Name", state.granular_set_name)
if changed then state.granular_set_name = new_name end

if r.ImGui_Button(ctx, "Save Set", 80) then
if state.granular_set_name and state.granular_set_name ~= "" then
saveGranularSet(state.granular_set_name)
end
end

r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx, "Load Set", 80) then
if state.granular_set_name and state.granular_set_name ~= "" then
loadGranularSet(state.granular_set_name)
end
end

-- List existing grain sets
if r.ImGui_BeginChild(ctx, "GrainSetList", 0, 60) then
for name, _ in pairs(state.granular_sets or {}) do
r.ImGui_PushID(ctx, name)

if r.ImGui_Button(ctx, name, 120, 20) then
loadGranularSet(name)
state.granular_set_name = name
end

r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx, "X", 20, 20) then
deleteGranularSet(name)
end

r.ImGui_PopID(ctx)
end
r.ImGui_EndChild(ctx)
end
else
-- Smooth motion controls for other modes
r.ImGui_Text(ctx,"Smooth Motion:")
local changed,new_smooth=r.ImGui_SliderDouble(ctx,"Smoothness",state.smooth_speed,0.0,1.0,"%.2f")
if changed then state.smooth_speed=new_smooth end

local changed,new_max_speed=r.ImGui_SliderDouble(ctx,"Max Speed",state.max_gesture_speed,0.1,10.0,"%.1f")
if changed then state.max_gesture_speed=new_max_speed end
end

local changed,new_range=r.ImGui_SliderDouble(ctx,"Range",state.gesture_range,0.1,1.0)
if changed then state.gesture_range=new_range end

local changed,new_min=r.ImGui_SliderDouble(ctx,"Min",state.gesture_min,0.0,1.0)
if changed then 
state.gesture_min=new_min
if state.gesture_max<new_min then state.gesture_max=new_min end
scheduleSave()
end

local changed,new_max=r.ImGui_SliderDouble(ctx,"Max",state.gesture_max,0.0,1.0)
if changed then
state.gesture_max=new_max
if state.gesture_min>new_max then state.gesture_min=new_max end
scheduleSave()
end

r.ImGui_Separator(ctx)

-- Randomize section
r.ImGui_Text(ctx,"Randomize")
local changed,new_intensity=r.ImGui_SliderDouble(ctx,"Intensity",state.randomize_intensity,0.0,1.0)
if changed then state.randomize_intensity=new_intensity end

local changed,new_min=r.ImGui_SliderDouble(ctx,"Min##rand",state.randomize_min,0.0,1.0)
if changed then
state.randomize_min=new_min
if state.randomize_max<new_min then state.randomize_max=new_min end
scheduleSave()
end

local changed,new_max=r.ImGui_SliderDouble(ctx,"Max##rand",state.randomize_max,0.0,1.0)
if changed then
state.randomize_max=new_max
if state.randomize_min>new_max then state.randomize_min=new_max end
scheduleSave()
end

if r.ImGui_Button(ctx,"Randomize",100)then
randomizeSelection()
end

if r.ImGui_Button(ctx,"Reset Gesture",100)then
state.gesture_x=0.5
state.gesture_y=0.5
captureBaseValues()
applyGestureToSelection(state.gesture_x,state.gesture_y)
end

if r.ImGui_Button(ctx,"Set Base",100)then
captureBaseValues()
saveTrackSelection()
end

r.ImGui_Separator(ctx)

-- Morph section
r.ImGui_Text(ctx,"Morph")
if r.ImGui_Button(ctx,"Morph 1",50)then
captureToMorph(1)
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"Morph 2",50)then
captureToMorph(2)
end
r.ImGui_SameLine(ctx)
if state.morph_preset_a and state.morph_preset_b then
r.ImGui_Text(ctx,"Ready")
else
r.ImGui_Text(ctx,"Set both")
end

local changed,new_amount=r.ImGui_SliderDouble(ctx,"Morph",state.morph_amount,0.0,1.0)
if changed then
state.morph_amount=new_amount
morphBetweenPresets(state.morph_amount)
end

r.ImGui_Separator(ctx)

-- Presets section - improved layout
r.ImGui_Text(ctx,"Presets")
local changed,new_name=r.ImGui_InputText(ctx,"Name",state.preset_name)
if changed then state.preset_name=new_name end

if r.ImGui_Button(ctx,"Save",100)then
savePreset(state.preset_name)
end

r.ImGui_Separator(ctx)

-- Preset list with direct load/rename/delete buttons
if r.ImGui_BeginChild(ctx,"PresetList",0,0)then
for name,_ in pairs(state.presets)do
r.ImGui_PushID(ctx, name)

-- Load button (bigger, main action)
if r.ImGui_Button(ctx,name,150,25)then
loadPreset(name)
state.selected_preset=name
end

r.ImGui_SameLine(ctx)
-- Rename button
if r.ImGui_Button(ctx,"R",25,25)then
state.show_preset_rename=true
state.rename_preset_name=name
state.selected_preset=name
end

r.ImGui_SameLine(ctx)
-- Delete button
if r.ImGui_Button(ctx,"X",25,25)then
deletePreset(name)
end

r.ImGui_PopID(ctx)
end
r.ImGui_EndChild(ctx)
end

-- Rename popup
if state.show_preset_rename then
r.ImGui_OpenPopup(ctx,"Rename Preset")
end

if r.ImGui_BeginPopupModal(ctx,"Rename Preset",nil,r.ImGui_WindowFlags_AlwaysAutoResize())then
local changed,new_name=r.ImGui_InputText(ctx,"New Name",state.rename_preset_name)
if changed then state.rename_preset_name=new_name end

if r.ImGui_Button(ctx,"OK",120,0)then
renamePreset(state.selected_preset,state.rename_preset_name)
state.show_preset_rename=false
r.ImGui_CloseCurrentPopup(ctx)
end
r.ImGui_SameLine(ctx)
if r.ImGui_Button(ctx,"Cancel",120,0)then
state.show_preset_rename=false
r.ImGui_CloseCurrentPopup(ctx)
end
r.ImGui_EndPopup(ctx)
end

else
r.ImGui_Text(ctx,"Select parameters")
end
r.ImGui_EndChild(ctx)
end

r.ImGui_End(ctx)
end

if sl then sl.clearStyles(ctx,pc,pv)end
return open
end

-- Load settings on startup
loadSettings()

local function loop()
local open=drawInterface()
if open then r.defer(loop)else saveSettings()end
end

r.atexit(saveSettings)
loop()