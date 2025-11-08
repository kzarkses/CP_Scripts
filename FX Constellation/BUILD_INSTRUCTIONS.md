# FX Constellation - Build Instructions

## Development vs Distribution

### Development Mode (Current)
The script currently loads `.lua` files directly from `Modules/` directory:
```lua
local Core = dofile(script_path .. "Modules/Core.lua")
local License = dofile(script_path .. "Modules/License.lua")
-- etc...
```

This allows you to:
- Edit code and see changes immediately
- Debug easily
- Use version control (Git) effectively

### Distribution Mode (Protected)
For public distribution, compile modules to bytecode (`.dat` files):
```lua
local Core = dofile(script_path .. "Data/Core.dat")
local License = dofile(script_path .. "Data/License.dat")
-- etc...
```

This provides:
- Source code protection (bytecode is not human-readable)
- Files show as "binary or unsupported encoding" in editors like VS Code
- Professional distribution package

## Build Process

### Step 1: Compile Modules
Run the build script from REAPER's ReaScript console:
```lua
dofile(reaper.GetResourcePath() .. "/Scripts/CP_Scripts/FX Constellation/build.lua")
```

Or from command line (if you have Lua installed):
```bash
cd "FX Constellation"
lua build.lua
```

This will:
1. Read all `.lua` files from `Modules/`
2. Compile each to Lua bytecode
3. Save bytecode as `.dat` files in `Data/`

### Step 2: Switch to Distribution Mode
Edit `CP_FXConstellation.lua` and change the dofile paths:

**From (Development):**
```lua
local Core = dofile(script_path .. "Modules/Core.lua")
local License = dofile(script_path .. "Modules/License.lua")
local Persistence = dofile(script_path .. "Modules/Persistence.lua")
local FXManager = dofile(script_path .. "Modules/FXManager.lua")
local GestureSystem = dofile(script_path .. "Modules/GestureSystem.lua")
local PresetSystem = dofile(script_path .. "Modules/PresetSystem.lua")
local SoundGenerator = dofile(script_path .. "Modules/SoundGenerator.lua")
local UI = dofile(script_path .. "Modules/UI.lua")
```

**To (Distribution):**
```lua
local Core = dofile(data_path .. "Core.dat")
local License = dofile(data_path .. "License.dat")
local Persistence = dofile(data_path .. "Persistence.dat")
local FXManager = dofile(data_path .. "FXManager.dat")
local GestureSystem = dofile(data_path .. "GestureSystem.dat")
local PresetSystem = dofile(data_path .. "PresetSystem.dat")
local SoundGenerator = dofile(data_path .. "SoundGenerator.dat")
local UI = dofile(data_path .. "UI.dat")
```

### Step 3: Test
1. Reload the script in REAPER
2. Verify all functionality works correctly
3. Check that `.dat` files cannot be read in VS Code (should show as binary)

### Step 4: Prepare Distribution Package
For public release, you can:
1. Remove or exclude the `Modules/` directory (keep it only in your private repo)
2. Include only `Data/*.dat` files
3. Include the main script `CP_FXConstellation.lua`
4. Include `JSFX/` directory
5. **Do not** include `build.lua` or this instructions file

## Two-Repository Strategy (Optional)

### Option A: Simple Approach
1. **Development**: Work in your current private repository with `.lua` files
2. **Distribution**: When ready to release:
   - Run `build.lua` to compile to `.dat`
   - Switch main script to load from `.dat`
   - Commit and push
   - Users can access the script but not read the source

### Option B: Two Separate Repositories
1. **Private Repository** (Development):
   - Contains `Modules/*.lua` (source code)
   - Contains `build.lua`
   - Contains development documentation
   - **Keep this repository private**

2. **Public Repository** (Distribution):
   - Contains `Data/*.dat` (compiled bytecode only)
   - Contains `CP_FXConstellation.lua` (configured for `.dat` loading)
   - Contains `JSFX/` directory
   - Contains user documentation only
   - **This repository is public**

#### Workflow for Two-Repo Strategy:
1. Develop and test in private repo
2. When ready to release:
   - Run `build.lua` to create `.dat` files
   - Copy distribution files to public repo:
     - `CP_FXConstellation.lua` (with `.dat` loading)
     - `Data/*.dat`
     - `JSFX/*`
     - User documentation
   - Commit to public repo
3. Users clone/download from public repo only

## Git History Concerns

**Important**: If you've already committed `.lua` source files to a public repository, they are accessible in Git history even after deletion!

Solutions:
1. **Create new repository**: Start fresh with only `.dat` files (recommended)
2. **Rewrite history**: Use `git filter-branch` or BFG Repo-Cleaner (advanced, risky)
3. **Accept it**: Some open-source projects choose to be transparent

If you choose option 1 (recommended):
```bash
# In a new directory
git init
# Copy only distribution files (.dat, main script, JSFX)
git add .
git commit -m "Initial public release"
git remote add origin <your-new-public-repo-url>
git push -u origin main
```

## Reverting to Development Mode

To switch back to development mode at any time:
1. Edit `CP_FXConstellation.lua`
2. Change dofile paths back from `data_path .. "*.dat"` to `script_path .. "Modules/*.lua"`
3. Continue editing `.lua` files in `Modules/`

## Notes

- Bytecode compilation is platform-specific (but Lua bytecode is generally portable)
- Always keep original `.lua` files for development
- Test thoroughly after compiling to bytecode
- Consider keeping a backup of source code in a secure location
