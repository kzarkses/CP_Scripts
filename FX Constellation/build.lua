-- FX Constellation Build Script
-- Compiles Lua modules to bytecode (.dat files) for distribution
--
-- Usage:
--   Run this script from REAPER's ReaScript console or via command line:
--   lua build.lua
--
-- This will compile all .lua files in Modules/ to bytecode .dat files in Data/

local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
if not script_path or script_path == "" then
	script_path = "./"
end

-- Ensure trailing slash
if not script_path:match("[/\\]$") then
	script_path = script_path .. "/"
end

local modules_path = script_path .. "Modules/"
local data_path = script_path .. "Data/"

print("FX Constellation Build Script")
print("=============================")
print("Script path: " .. script_path)
print("Modules path: " .. modules_path)
print("Data path: " .. data_path)
print("")

-- Create Data directory if it doesn't exist
local function ensure_directory(path)
	local test_file = io.open(path .. ".test", "w")
	if test_file then
		test_file:close()
		os.remove(path .. ".test")
		return true
	end
	-- Try to create directory
	os.execute("mkdir -p \"" .. path .. "\"")
	return true
end

ensure_directory(data_path)

-- List of modules to compile
local modules = {
	"Core.lua",
	"License.lua",
	"Persistence.lua",
	"FXManager.lua",
	"GestureSystem.lua",
	"PresetSystem.lua",
	"SoundGenerator.lua",
	"UI.lua"
}

local function compile_module(module_name)
	local source_path = modules_path .. module_name
	local target_path = data_path .. module_name:gsub("%.lua$", ".dat")

	print("Compiling: " .. module_name)

	-- Read source file
	local source_file = io.open(source_path, "rb")
	if not source_file then
		print("  ERROR: Cannot read " .. source_path)
		return false
	end
	local source_code = source_file:read("*all")
	source_file:close()

	-- Compile to bytecode
	local compiled, err = loadstring(source_code, "@" .. module_name)
	if not compiled then
		print("  ERROR: Compilation failed: " .. tostring(err))
		return false
	end

	-- Get bytecode using string.dump
	local bytecode = string.dump(compiled)

	-- Write bytecode to .dat file
	local target_file = io.open(target_path, "wb")
	if not target_file then
		print("  ERROR: Cannot write " .. target_path)
		return false
	end
	target_file:write(bytecode)
	target_file:close()

	print("  SUCCESS: " .. target_path .. " (" .. #bytecode .. " bytes)")
	return true
end

-- Compile all modules
local success_count = 0
local fail_count = 0

for _, module in ipairs(modules) do
	if compile_module(module) then
		success_count = success_count + 1
	else
		fail_count = fail_count + 1
	end
end

print("")
print("=============================")
print("Build completed!")
print("Success: " .. success_count .. " modules")
if fail_count > 0 then
	print("Failed: " .. fail_count .. " modules")
end
print("")
print("Next steps:")
print("1. Update CP_FXConstellation.lua to load .dat files instead of .lua files")
print("2. Test the script in REAPER to ensure everything works")
print("3. For distribution, include only .dat files in Data/, not .lua files in Modules/")
print("")
print("To revert to development mode (loading .lua files):")
print("   Simply edit CP_FXConstellation.lua to use dofile() with .lua files")
print("")
