-- @description Debug Media Explorer Structure
-- @version 1.0
-- @author Claude
-- @about
--   Debugging utility to understand Media Explorer window structure

local r = reaper

function FindMediaExplorerControls()
    r.ClearConsole()
    r.ShowConsoleMsg("Starting Media Explorer debug...\n")
    
    -- Find Media Explorer window
    local title = r.JS_Localize("Media Explorer", "common")
    local hwndMediaExplorer = r.JS_Window_Find(title, true)
    
    if not hwndMediaExplorer then 
        r.ShowConsoleMsg("Media Explorer window not found. Is it open?\n")
        return false
    end
    r.ShowConsoleMsg("✓ Found Media Explorer window\n")
    
    -- Enumerate all child windows
    local children = {}
    local i = 0
    while true do
        local child = r.JS_Window_FindChildByIndex(hwndMediaExplorer, i)
        if not child then break end
        
        local class = r.JS_Window_GetClassName(child)
        local id = r.JS_Window_GetID(child)
        local title = r.JS_Window_GetTitle(child, "", 100)
        
        table.insert(children, {
            hwnd = child,
            index = i,
            class = class,
            id = id,
            title = title
        })
        i = i + 1
    end
    
    r.ShowConsoleMsg(string.format("Found %d child windows\n\n", #children))
    
    -- Print all children
    for i, child in ipairs(children) do
        r.ShowConsoleMsg(string.format("Child %d: Class=%s, ID=%s, Title=%s\n", 
            i-1, child.class, child.id, child.title))
            
        -- Try to find SysListView32 controls specifically
        if child.class == "SysListView32" then
            r.ShowConsoleMsg("  ➤ This is a ListView control!\n")
            
            -- Try to get item count
            local count = r.JS_ListView_GetItemCount(child.hwnd)
            r.ShowConsoleMsg(string.format("  ➤ ListView has %d items\n", count))
            
            -- Get column count and names
            local col_count = r.JS_ListView_GetColumnCount(child.hwnd)
            r.ShowConsoleMsg(string.format("  ➤ ListView has %d columns\n", col_count))
            
            for col = 0, col_count-1 do
                local col_name = r.JS_ListView_GetColumnText(child.hwnd, col)
                r.ShowConsoleMsg(string.format("    Column %d: %s\n", col, col_name))
            end
            
            -- Try to read first item text
            if count > 0 then
                local item_text = r.JS_ListView_GetItemText(child.hwnd, 0, 0)
                r.ShowConsoleMsg(string.format("  ➤ First item text: %s\n", item_text))
            end
        end
        
        -- Also find any edit boxes, which might contain the path
        if child.class == "Edit" then
            r.ShowConsoleMsg("  ➤ This is an Edit control!\n")
            local text = r.JS_Window_GetTitle(child.hwnd, "", 1000)
            r.ShowConsoleMsg(string.format("  ➤ Edit text: %s\n", text))
        end
    end
    
    -- Try different approaches based on known IDs
    local known_ids = {0x3E9, 1001, 1002, 1003, 1004}
    r.ShowConsoleMsg("\nChecking known control IDs:\n")
    
    for _, id in ipairs(known_ids) do
        local control = r.JS_Window_FindChildByID(hwndMediaExplorer, id)
        if control then
            local class = r.JS_Window_GetClassName(control)
            local title = r.JS_Window_GetTitle(control, "", 100)
            r.ShowConsoleMsg(string.format("Found control with ID %X: Class=%s, Title=%s\n", 
                id, class, title))
                
            if class == "SysListView32" then
                r.ShowConsoleMsg("  ➤ This is our target ListView!\n")
                
                -- Get item count
                local count = r.JS_ListView_GetItemCount(control)
                r.ShowConsoleMsg(string.format("  ➤ ListView has %d items\n", count))
                
                -- Try to read metadata columns
                if count > 0 then
                    r.ShowConsoleMsg("First item metadata:\n")
                    for col = 0, 10 do  -- Try first 10 columns
                        local text = r.JS_ListView_GetItemText(control, 0, col)
                        if text and text ~= "" then
                            r.ShowConsoleMsg(string.format("  Column %d: %s\n", col, text))
                        end
                    end
                end
            end
        else
            r.ShowConsoleMsg(string.format("Control with ID %X not found\n", id))
        end
    end
    
    return true
end

function TestBWFCapabilities()
    r.ShowConsoleMsg("\nTesting BWF Metadata Capabilities:\n")
    
    -- Check if user has ReaRoute/BWF installed
    local has_rearoute = r.APIExists("CF_GetSWSVersion")
    r.ShowConsoleMsg(string.format("SWS Extension available: %s\n", has_rearoute and "Yes" or "No"))
    
    -- Check for other BWF-related APIs
    local bwf_apis = {
        "GetMediaFileMetadata",
        "SetMediaFileMetadata",
        "BR_GetMediaItemTakeMetadataValOut",
        "BR_SetMediaItemTakeMetadata"
    }
    
    for _, api in ipairs(bwf_apis) do
        local exists = r.APIExists(api)
        r.ShowConsoleMsg(string.format("API '%s' available: %s\n", api, exists and "Yes" or "No"))
    end
    
    -- Check if we can read metadata from a file
    local item = r.GetSelectedMediaItem(0, 0)
    if item then
        local take = r.GetActiveTake(item)
        if take then
            r.ShowConsoleMsg("\nTrying to read metadata from selected item:\n")
            
            local source = r.GetMediaItemTake_Source(take)
            local filename = r.GetMediaSourceFileName(source, "")
            r.ShowConsoleMsg(string.format("Filename: %s\n", filename))
            
            -- Try BR_GetMediaItemTakeMetadataValOut if available
            if r.APIExists("BR_GetMediaItemTakeMetadataValOut") then
                local retval, desc = r.BR_GetMediaItemTakeMetadataValOut(take, "DESC")
                r.ShowConsoleMsg(string.format("Description: %s\n", desc))
                
                local retval, comment = r.BR_GetMediaItemTakeMetadataValOut(take, "COMMENT")
                r.ShowConsoleMsg(string.format("Comment: %s\n", comment))
            end
        else
            r.ShowConsoleMsg("No active take in selected item\n")
        end
    else
        r.ShowConsoleMsg("No item selected\n")
    end
end

function Main()
    FindMediaExplorerControls()
    TestBWFCapabilities()
    
    r.ShowConsoleMsg("\n--- Debugging complete ---\n")
end

Main()