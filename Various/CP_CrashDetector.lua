-- @description CrashDetector - Détecte les problèmes potentiels
-- @version 1.0.0
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_CrashDetector"
local ctx = nil
local issues_found = {}
local tests_completed = 0
local total_tests = 12
local tests_running = false

function InitializeContext()
    if not ctx or not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then
        ctx = r.ImGui_CreateContext('Crash Detector')
    end
end

function AddIssue(severity, title, description, fix)
    table.insert(issues_found, {
        severity = severity,
        title = title,
        description = description,
        fix = fix
    })
end

function TestImGuiContexts()
    tests_completed = tests_completed + 1
    
    local test_contexts = {}
    for i = 1, 10 do
        local test_ctx = r.ImGui_CreateContext('Test_' .. i)
        if test_ctx and r.ImGui_ValidatePtr(test_ctx, "ImGui_Context*") then
            table.insert(test_contexts, test_ctx)
        else
            AddIssue("HIGH", "Context Creation Failed", 
                "Failed to create ImGui context #" .. i, 
                "Reduce number of simultaneous contexts")
            break
        end
    end
    
    if #test_contexts > 5 then
        AddIssue("MEDIUM", "Too Many Contexts", 
            "Script creates many ImGui contexts (" .. #test_contexts .. " tested)", 
            "Reuse contexts instead of creating new ones")
    end
end

function TestMemoryLeaks()
    tests_completed = tests_completed + 1
    
    local start_mem = r.GetMemoryUsage and r.GetMemoryUsage() or 0
    
    local textures = {}
    for i = 1, 50 do
        local test_path = r.GetResourcePath() .. "/Data/toolbar_icons/play.png"
        if r.file_exists(test_path) then
            local texture = r.ImGui_CreateImage(test_path)
            if texture then
                table.insert(textures, texture)
            end
        end
    end
    
    textures = nil
    collectgarbage("collect")
    
    local end_mem = r.GetMemoryUsage and r.GetMemoryUsage() or 0
    if end_mem > start_mem + 10000 then
        AddIssue("HIGH", "Potential Memory Leak", 
            string.format("Memory increased by %d bytes during texture test", end_mem - start_mem),
            "Ensure proper cleanup of ImGui textures")
    end
end

function TestAPIAvailability()
    tests_completed = tests_completed + 1
    
    local required_apis = {
        "JS_Window_Find",
        "JS_Window_GetRect", 
        "JS_Window_IsVisible",
        "JS_Window_FindChildByID",
        "ImGui_ValidatePtr",
        "ImGui_CreateContext",
        "ImGui_CreateImage"
    }
    
    for _, api in ipairs(required_apis) do
        if not r.APIExists(api) then
            AddIssue("CRITICAL", "Missing API", 
                "Required API not available: " .. api,
                "Install js_ReaScriptAPI extension")
        end
    end
end

function TestFileSystem()
    tests_completed = tests_completed + 1
    
    local toolbar_icons_path = r.GetResourcePath() .. "/Data/toolbar_icons"
    if not r.EnumerateFiles(toolbar_icons_path, 0) then
        AddIssue("MEDIUM", "Icons Directory Missing", 
            "Toolbar icons directory not found: " .. toolbar_icons_path,
            "Create icons directory or adjust icon paths")
    end
end

function TestRapidContextSwitching()
    tests_completed = tests_completed + 1
    
    local switch_count = 0
    local start_time = r.time_precise()
    
    for i = 1, 100 do
        local temp_ctx = r.ImGui_CreateContext('Temp_' .. i)
        if temp_ctx then
            switch_count = switch_count + 1
        end
    end
    
    local duration = r.time_precise() - start_time
    if duration > 1.0 then
        AddIssue("HIGH", "Slow Context Creation", 
            string.format("Created %d contexts in %.3fs (too slow)", switch_count, duration),
            "Cache and reuse contexts")
    end
end

function TestImageLoading()
    tests_completed = tests_completed + 1
    
    local test_files = {"play.png", "stop.png", "record.png", "nonexistent.png"}
    local load_failures = 0
    
    for _, filename in ipairs(test_files) do
        local path = r.GetResourcePath() .. "/Data/toolbar_icons/" .. filename
        if r.file_exists(path) then
            local texture = r.ImGui_CreateImage(path)
            if not texture or not r.ImGui_ValidatePtr(texture, "ImGui_Image*") then
                load_failures = load_failures + 1
            end
        end
    end
    
    if load_failures > 0 then
        AddIssue("MEDIUM", "Image Loading Issues", 
            string.format("%d image files failed to load", load_failures),
            "Check image file formats and paths")
    end
end

function TestWindowOperations()
    tests_completed = tests_completed + 1
    
    if not r.APIExists("JS_Window_Find") then return end
    
    local windows_to_test = {"main", "transport", "mixer"}
    local failed_windows = {}
    
    for _, window_name in ipairs(windows_to_test) do
        local success, hwnd = pcall(function() 
            return r.JS_Window_Find(window_name, true) 
        end)
        
        if not success or not hwnd then
            table.insert(failed_windows, window_name)
        else
            local rect_success, retval = pcall(function()
                return r.JS_Window_GetRect(hwnd)
            end)
            if not rect_success or not retval then
                table.insert(failed_windows, window_name .. "_rect")
            end
        end
    end
    
    if #failed_windows > 0 then
        AddIssue("MEDIUM", "Window Operation Failures", 
            "Failed operations on: " .. table.concat(failed_windows, ", "),
            "Check js_ReaScriptAPI installation and window states")
    end
end

function TestConcurrentOperations()
    tests_completed = tests_completed + 1
    
    local success_count = 0
    local total_ops = 20
    
    for i = 1, total_ops do
        local success = pcall(function()
            local temp_ctx = r.ImGui_CreateContext('Concurrent_' .. i)
            if temp_ctx then
                r.ImGui_SetNextWindowSize(temp_ctx, 100, 100)
                local visible, open = r.ImGui_Begin(temp_ctx, 'Test_' .. i, true)
                if visible then
                    r.ImGui_Text(temp_ctx, "Test")
                    r.ImGui_End(temp_ctx)
                end
            end
        end)
        
        if success then success_count = success_count + 1 end
        
        if i % 5 == 0 then
            r.defer(function() end)
        end
    end
    
    if success_count < total_ops * 0.8 then
        AddIssue("HIGH", "Concurrent Operations Failing", 
            string.format("Only %d/%d concurrent operations succeeded", success_count, total_ops),
            "Reduce concurrent ImGui operations")
    end
end

function TestExtStateOperations()
    tests_completed = tests_completed + 1
    
    local test_key = "crash_detector_test"
    local test_value = "test_data_" .. os.time()
    
    r.SetExtState(script_name, test_key, test_value, false)
    local retrieved = r.GetExtState(script_name, test_key)
    
    if retrieved ~= test_value then
        AddIssue("MEDIUM", "ExtState Operations Failing", 
            "ExtState read/write test failed",
            "Check REAPER configuration storage")
    end
    
    r.DeleteExtState(script_name, test_key, false)
end

function TestFontOperations()
    tests_completed = tests_completed + 1
    
    local fonts_to_test = {"Verdana", "Arial", "NonExistentFont"}
    local font_failures = 0
    
    local font_ctx = r.ImGui_CreateContext('FontTest')
    
    for _, font_name in ipairs(fonts_to_test) do
        local success, font = pcall(function()
            return r.ImGui_CreateFont(font_name, 16)
        end)
        
        if success and font and r.ImGui_ValidatePtr(font, "ImGui_Font*") then
            local attach_success = pcall(function()
                r.ImGui_Attach(font_ctx, font)
            end)
            if not attach_success then
                font_failures = font_failures + 1
            end
        else
            if font_name ~= "NonExistentFont" then
                font_failures = font_failures + 1
            end
        end
    end
    
    if font_failures > 1 then
        AddIssue("MEDIUM", "Font Operations Issues", 
            string.format("%d font operations failed", font_failures),
            "Check font availability and ImGui font handling")
    end
end

function TestLongRunningOperations()
    tests_completed = tests_completed + 1
    
    local start_time = r.time_precise()
    local operations = 0
    
    while r.time_precise() - start_time < 0.1 do
        operations = operations + 1
        local temp_ctx = r.ImGui_CreateContext('LongRun_' .. operations)
        if temp_ctx then
            r.ImGui_SetNextWindowSize(temp_ctx, 50, 50)
        end
    end
    
    if operations < 50 then
        AddIssue("HIGH", "Performance Degradation", 
            string.format("Only %d operations in 100ms (expected 50+)", operations),
            "Optimize context creation and window operations")
    end
end

function TestResourceCleanup()
    tests_completed = tests_completed + 1
    
    local created_resources = {}
    
    for i = 1, 20 do
        local test_ctx = r.ImGui_CreateContext('Cleanup_' .. i)
        if test_ctx then
            table.insert(created_resources, {type = "context", resource = test_ctx})
        end
        
        local test_path = r.GetResourcePath() .. "/Data/toolbar_icons/play.png"
        if r.file_exists(test_path) then
            local texture = r.ImGui_CreateImage(test_path)
            if texture then
                table.insert(created_resources, {type = "texture", resource = texture})
            end
        end
    end
    
    local cleanup_failures = 0
    for _, res in ipairs(created_resources) do
        if res.type == "context" and not r.ImGui_ValidatePtr(res.resource, "ImGui_Context*") then
            cleanup_failures = cleanup_failures + 1
        elseif res.type == "texture" and not r.ImGui_ValidatePtr(res.resource, "ImGui_Image*") then
            cleanup_failures = cleanup_failures + 1
        end
    end
    
    if cleanup_failures > 0 then
        AddIssue("HIGH", "Resource Cleanup Issues", 
            string.format("%d resources became invalid during test", cleanup_failures),
            "Implement proper resource lifecycle management")
    end
end

function RunAllTests()
    if tests_running then
        AddIssue("INFO", "Tests Already Running", "Tests are currently in progress", "Wait for completion")
        return
    end
    
    tests_running = true
    issues_found = {}
    tests_completed = 0
    
    r.defer(function()
        TestAPIAvailability()
        r.defer(function()
            TestImGuiContexts()
            r.defer(function()
                TestMemoryLeaks()
                r.defer(function()
                    TestFileSystem()
                    r.defer(function()
                        TestRapidContextSwitching()
                        r.defer(function()
                            TestImageLoading()
                            r.defer(function()
                                TestWindowOperations()
                                r.defer(function()
                                    TestConcurrentOperations()
                                    r.defer(function()
                                        TestExtStateOperations()
                                        r.defer(function()
                                            TestFontOperations()
                                            r.defer(function()
                                                TestLongRunningOperations()
                                                r.defer(function()
                                                    TestResourceCleanup()
                                                    tests_running = false
                                                end)
                                            end)
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

function ShowResults()
    InitializeContext()
    
    if not ctx or not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then
        return false
    end
    
    r.ImGui_SetNextWindowSize(ctx, 900, 700, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, 'Crash Detector Results', true)
    
    if visible then
        local status_text = tests_running and "Tests Running..." or "Tests Ready"
        local status_color = tests_running and 0xFFAA00FF or 0x00FF00FF
        
        r.ImGui_TextColored(ctx, status_color, status_text)
        r.ImGui_Text(ctx, string.format("Tests Completed: %d/%d", tests_completed, total_tests))
        r.ImGui_Text(ctx, string.format("Issues Found: %d", #issues_found))
        
        local button_disabled = tests_running
        if button_disabled then r.ImGui_BeginDisabled(ctx) end
        
        if r.ImGui_Button(ctx, "Run Tests") then
            RunAllTests()
        end
        
        if button_disabled then r.ImGui_EndDisabled(ctx) end
        
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Export Report") then
            local report = "Crash Detector Report\n"
            report = report .. string.format("Generated: %s\n", os.date())
            report = report .. string.format("Tests: %d/%d\n", tests_completed, total_tests)
            report = report .. string.format("Issues: %d\n\n", #issues_found)
            
            for i, issue in ipairs(issues_found) do
                report = report .. string.format("%d. [%s] %s\n", i, issue.severity, issue.title)
                report = report .. string.format("   %s\n", issue.description)
                report = report .. string.format("   Fix: %s\n\n", issue.fix)
            end
            
            r.ShowConsoleMsg(report)
        end
        
        r.ImGui_Separator(ctx)
        
        if r.ImGui_BeginChild(ctx, "IssuesList", -1, -1) then
            if #issues_found == 0 and not tests_running then
                r.ImGui_TextColored(ctx, 0x888888FF, "No tests run yet. Click 'Run Tests' to start diagnosis.")
            else
                for i, issue in ipairs(issues_found) do
                    local color = 0xFFFFFFFF
                    if issue.severity == "CRITICAL" then
                        color = 0xFF0000FF
                    elseif issue.severity == "HIGH" then
                        color = 0xFF4444FF
                    elseif issue.severity == "MEDIUM" then
                        color = 0xFFAA00FF
                    elseif issue.severity == "INFO" then
                        color = 0x00AAFFFF
                    end
                    
                    r.ImGui_TextColored(ctx, color, string.format("[%s] %s", issue.severity, issue.title))
                    r.ImGui_Text(ctx, "  " .. issue.description)
                    r.ImGui_TextColored(ctx, 0x88FF88FF, "  Fix: " .. issue.fix)
                    r.ImGui_Separator(ctx)
                end
            end
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    return open
end

function MainLoop()
    if ShowResults() then
        r.defer(MainLoop)
    end
end

function Start()
    InitializeContext()
    MainLoop()
end

Start()