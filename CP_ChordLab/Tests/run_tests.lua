-- @description CP ChordLab — standalone test runner (plain Lua 5.3, no REAPER)
-- Run: lua53.exe Tests/run_tests.lua   (from any cwd — paths resolved via arg[0])

local sep = package.config:sub(1, 1)
local self_path = arg[0]:match("(.*[\\/])") or ("." .. sep)
local root = self_path .. ".." .. sep
local mod_path = root .. "Modules" .. sep

-- Assertion helpers passed to every test file -------------------------------

local T = {}

local function fail(msg)
    error(msg, 3)
end

function T.assert_true(cond, msg)
    if not cond then fail(msg or "expected true, got " .. tostring(cond)) end
end

function T.assert_eq(got, expected, msg)
    if got ~= expected then
        fail((msg and msg .. ": " or "")
            .. "expected " .. tostring(expected) .. ", got " .. tostring(got))
    end
end

function T.assert_near(got, expected, eps, msg)
    eps = eps or 1e-9
    if type(got) ~= "number" or math.abs(got - expected) > eps then
        fail((msg and msg .. ": " or "")
            .. "expected ~" .. tostring(expected) .. ", got " .. tostring(got))
    end
end

local function deep_eq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function dump(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return tostring(v) end
    if depth > 3 then return "{...}" end
    local parts = {}
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

function T.assert_deep_eq(got, expected, msg)
    if not deep_eq(got, expected) then
        fail((msg and msg .. ": " or "")
            .. "expected " .. dump(expected) .. ", got " .. dump(got))
    end
end

-- Modules under test (wired exactly like App.lua does). Modules not written
-- yet are skipped so the suite stays runnable during incremental authoring.

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local Modules = {}
if exists(mod_path .. "Theory.lua") then
    Modules.Theory = dofile(mod_path .. "Theory.lua")
end
if Modules.Theory and exists(mod_path .. "Voicing.lua") then
    Modules.Voicing = dofile(mod_path .. "Voicing.lua")
    Modules.Voicing.Init(Modules.Theory)
end
if Modules.Theory and exists(mod_path .. "Suggest.lua") then
    -- Voicing may legitimately be nil (Suggest only needs Theory to build
    -- abstract chords; the Voicing arg is reserved for future voiced previews).
    Modules.Suggest = dofile(mod_path .. "Suggest.lua")
    Modules.Suggest.Init(Modules.Theory, Modules.Voicing)
end
if Modules.Theory and exists(mod_path .. "Fretboard.lua") then
    Modules.Fretboard = dofile(mod_path .. "Fretboard.lua")
    Modules.Fretboard.Init(Modules.Theory)
end

-- Runner ----------------------------------------------------------------------

local suites = {
    { file = "test_theory",    needs = "Theory" },
    { file = "test_voicing",   needs = "Voicing" },
    { file = "test_fretboard", needs = "Fretboard" },
    { file = "test_suggest",   needs = "Suggest" },
}
local total, failed, skipped = 0, 0, 0

for _, entry in ipairs(suites) do
    local suite = entry.file
    if not Modules[entry.needs] or not exists(self_path .. suite .. ".lua") then
        skipped = skipped + 1
        print("[SKIP] " .. suite .. " (module or test file not present yet)")
        goto continue
    end
    local chunk, load_err = loadfile(self_path .. suite .. ".lua")
    if not chunk then
        print("[LOAD FAIL] " .. suite .. ": " .. tostring(load_err))
        failed = failed + 1
    else
        local ok, tests = pcall(chunk, T, Modules)
        if not ok or type(tests) ~= "table" then
            print("[INIT FAIL] " .. suite .. ": " .. tostring(tests))
            failed = failed + 1
        else
            for _, test in ipairs(tests) do
                total = total + 1
                local pass, err = pcall(test.fn)
                if not pass then
                    failed = failed + 1
                    print("[FAIL] " .. suite .. " / " .. test.name)
                    print("       " .. tostring(err))
                end
            end
        end
    end
    ::continue::
end

if failed > 0 then
    print(string.format("FAILED: %d of %d tests (%d suites skipped)", failed, total, skipped))
    os.exit(1)
else
    print(string.format("OK: %d tests passed (%d suites skipped)", total, skipped))
end
