-- @description CP Media Properties Toolbar - Settings
-- @version 1.0.1
-- @author Cedric Pamalio
-- @about
--   Settings panel for the Media Properties Toolbar.

local SEP = package.config:sub(1, 1)
local script_path = debug.getinfo(1, 'S').source:match('@(.+[/\\])')
local data_path = script_path .. "Data53" .. SEP

dofile(data_path .. "CP_MediaPropertiesToolbar_Settings.lua")
