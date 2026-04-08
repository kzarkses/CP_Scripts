-- @description CP_Toolkit Overlay Test — Frameless play button anchored to REAPER
-- @version 0.2
-- @author Cedric Pamalio

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local UI = dofile(script_path .. "CP_Toolkit.lua")

UI.Init("CP Overlay", 50, 50, {
    frameless = true,
    topmost = true,
    x = 100,
    y = 100,
    scale = 1.0,
})

-- Anchor: top-center of REAPER window, 30px below title bar
UI.SetAnchor({
    x = 0.5,       -- 50% from left (centered)
    y = 0.0,       -- top
    offset_x = -25, -- center the 50px button
    offset_y = 30,   -- below title bar
})

UI.Run(function(theme)
    local play_state = reaper.GetPlayState()
    local is_playing = (play_state & 1) ~= 0

    -- Background
    local bg = is_playing and theme.colors.accent or theme.colors.button
    UI.Core.DrawRect(0, 0, 50, 50, bg[1], bg[2], bg[3], 0.9)

    -- Icon
    if is_playing then
        UI.Icons.Stop(5, 5, 40, 1, 1, 1, 0.9)
    else
        UI.Icons.Play(5, 5, 40, 1, 1, 1, 0.9)
    end

    -- Click to play/stop
    if UI.Core.MouseClicked(1) then
        reaper.Main_OnCommand(40044, 0)  -- Transport: Play/stop
    end

    -- Right-click to close
    if UI.Core.MouseClicked(2) then
        gfx.quit()
    end
end)
