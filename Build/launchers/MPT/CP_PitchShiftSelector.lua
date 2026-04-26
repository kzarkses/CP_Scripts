-- @description CP Pitch Shift Selector
-- @version 1.1
-- @author Cedric Pamalio
-- @about
--   Visual pitch shift algorithm selector for REAPER items.

local SEP = package.config:sub(1, 1)
local script_path = debug.getinfo(1, 'S').source:match('@(.+[/\\])')
local data_path = script_path .. "Data53" .. SEP

dofile(data_path .. "CP_PitchShiftSelector.lua")
