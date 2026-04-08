-- CP_KeyDetector — Press any key, see its gfx.getchar() code
-- Results are displayed on screen AND printed to REAPER console
-- Press ESC to quit and generate the final Lua table

gfx.init("CP Key Detector", 500, 400)
gfx.setfont(1, "Consolas", 14, 0)

local keys = {}       -- {code, label} pairs collected
local last_code = nil
local last_time = 0
local history = {}    -- display history (last 20)
local waiting = true

reaper.ShowConsoleMsg("\n=== CP Key Detector ===\n")
reaper.ShowConsoleMsg("Press keys one by one. Each keypress will be logged.\n")
reaper.ShowConsoleMsg("Press ESC when done to generate the Lua key table.\n\n")

local function frame()
    local char = gfx.getchar()

    -- ESC or window closed
    if char < 0 or char == 27 then
        -- Generate final table
        reaper.ShowConsoleMsg("\n=== KEY TABLE ===\n")
        reaper.ShowConsoleMsg("local Keys = {\n")
        for _, k in ipairs(keys) do
            reaper.ShowConsoleMsg(string.format("    [%d] = \"%s\",\n", k.code, k.label))
        end
        reaper.ShowConsoleMsg("}\n=== END ===\n")
        gfx.quit()
        return
    end

    -- Detect keypress (char > 0 means a key was pressed this frame)
    if char > 0 then
        local now = reaper.time_precise()
        -- Debounce: ignore same key within 200ms
        if char ~= last_code or (now - last_time) > 0.2 then
            last_code = char
            last_time = now

            -- Build label from code
            local label
            if char >= 32 and char <= 126 then
                label = string.char(char)
            else
                label = "code_" .. char
            end

            -- Log to console
            reaper.ShowConsoleMsg(string.format("Key: %-20s  Code: %d  (0x%04X)\n", label, char, char))

            -- Add to history (for screen display)
            table.insert(history, { code = char, label = label, time = now })
            if #history > 20 then table.remove(history, 1) end

            -- Add to collected keys
            table.insert(keys, { code = char, label = label })
        end
    end

    -- Draw
    gfx.set(0.13, 0.13, 0.14, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    -- Title
    gfx.set(0.9, 0.9, 0.9, 1)
    gfx.x, gfx.y = 10, 10
    gfx.drawstr("CP Key Detector — Press any key")

    gfx.set(0.5, 0.5, 0.5, 1)
    gfx.x, gfx.y = 10, 30
    gfx.drawstr("ESC to quit and generate table | Keys collected: " .. #keys)

    -- Current key (big)
    if last_code then
        gfx.setfont(1, "Consolas", 28, 0)
        gfx.set(0.35, 0.6, 0.85, 1)
        gfx.x, gfx.y = 10, 55
        local display = last_code >= 32 and last_code <= 126
            and string.format("\"%s\"  =  %d", string.char(last_code), last_code)
            or string.format("code  =  %d  (0x%04X)", last_code, last_code)
        gfx.drawstr(display)
        gfx.setfont(1, "Consolas", 14, 0)
    end

    -- History
    gfx.set(0.4, 0.4, 0.45, 1)
    gfx.x, gfx.y = 10, 95
    gfx.drawstr("--- History ---")

    for i, h in ipairs(history) do
        local y_pos = 110 + (i - 1) * 16
        -- Highlight the most recent
        if i == #history then
            gfx.set(0.85, 0.85, 0.85, 1)
        else
            gfx.set(0.6, 0.6, 0.6, 0.8)
        end
        gfx.x, gfx.y = 10, y_pos
        local line
        if h.code >= 32 and h.code <= 126 then
            line = string.format("%-4s  code=%d", "\"" .. string.char(h.code) .. "\"", h.code)
        else
            line = string.format("%-4s  code=%d  (0x%04X)", h.label, h.code, h.code)
        end
        gfx.drawstr(line)
    end

    gfx.update()
    reaper.defer(frame)
end

frame()
