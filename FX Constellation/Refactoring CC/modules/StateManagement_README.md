# StateManagement Module - Usage Guide

## Overview
The StateManagement module handles all persistent state operations for FX Constellation, including loading and saving settings, track selections, presets, granular sets, and snapshots.

## Module Location
`/home/user/CP_Scripts/FX Constellation/modules/StateManagement.lua`

## Extracted Functions

### Settings Management
1. **StateManagement.loadSettings(state, r, Utilities)**
   - Loads all settings from REAPER's ExtState
   - Loads: filter keywords, parameter filters, main state, track selections, granular sets, snapshots, and presets
   - Called during initialization

2. **StateManagement.saveSettings(state, r, Utilities, save_flags)**
   - Saves all settings to REAPER's ExtState based on save_flags
   - Saves: main settings, track selections, presets, granular sets, snapshots, filter keywords
   - Called when save timer triggers

### Track Selection Management
3. **StateManagement.saveTrackSelection(state, r, Utilities, scheduleTrackSaveFn)**
   - Saves current track's parameter selections, ranges, XY assignments, and invert settings
   - Stores per-track configuration including gesture positions
   - Parameters:
     - `scheduleTrackSaveFn`: Function to schedule the track save operation

4. **StateManagement.loadTrackSelection(state, r, Utilities, updateJSFXFromGestureFn, captureBaseValuesFn, updateSelectedCountFn)**
   - Loads track-specific parameter configuration
   - Restores selections, ranges, XY assignments, and gesture positions
   - Parameters:
     - `updateJSFXFromGestureFn`: Function to update JSFX automation from gesture
     - `captureBaseValuesFn`: Function to capture base parameter values
     - `updateSelectedCountFn`: Function to update selected parameter count

### Schedule Save Functions
5. **StateManagement.scheduleSave(state, r, save_flags)**
   - Schedules a general settings save with cooldown check
   - Prevents too frequent saves (respects min_save_interval)

6. **StateManagement.scheduleTrackSave(save_flags)**
   - Schedules track selection save

7. **StateManagement.schedulePresetSave(save_flags)**
   - Schedules preset data save

8. **StateManagement.scheduleGranularSave(save_flags)**
   - Schedules granular sets save

9. **StateManagement.scheduleSnapshotSave(save_flags)**
   - Schedules snapshot data save

## Usage Example

```lua
-- Load the module
local StateManagement = require("modules/StateManagement")
local Utilities = require("modules/Utilities")

-- Initialize
StateManagement.loadSettings(state, reaper, Utilities)

-- Save track selection
StateManagement.saveTrackSelection(
  state,
  reaper,
  Utilities,
  function() StateManagement.scheduleTrackSave(save_flags) end
)

-- Load track selection
StateManagement.loadTrackSelection(
  state,
  reaper,
  Utilities,
  updateJSFXFromGesture,
  captureBaseValues,
  function() Utilities.updateSelectedCount(state) end
)

-- Schedule saves
StateManagement.scheduleSave(state, reaper, save_flags)
StateManagement.schedulePresetSave(save_flags)

-- Execute saves
StateManagement.saveSettings(state, reaper, Utilities, save_flags)
```

## Dependencies

The StateManagement module requires:
- **Utilities module**: For serialize/deserialize, getTrackGUID, isTrackValid
- **state**: Global state table
- **r** or **reaper**: REAPER API object
- **save_flags**: Table tracking what needs to be saved

## Integration Notes

When integrating into the main file:
1. Load the module at the top with other modules
2. Replace direct function calls with `StateManagement.functionName()`
3. Pass required callback functions as parameters to `saveTrackSelection` and `loadTrackSelection`
4. Ensure `save_flags` table is accessible to schedule functions

## ExtState Keys Used

- `CP_FXConstellation.filter_keywords` - Filter keyword list
- `CP_FXConstellation.param_filter` - Parameter filter string
- `CP_FXConstellation.state` - Main application state
- `CP_FXConstellation.track_selections` - Per-track selections
- `CP_FXConstellation.granular_sets` - Granular synthesis sets
- `CP_FXConstellation.snapshots` - Saved snapshots
- `CP_FXConstellation.presets` - Saved presets
