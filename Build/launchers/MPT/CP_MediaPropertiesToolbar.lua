-- @description CP Media Properties Toolbar
-- @version 1.0
-- @author Cedric Pamalio
-- @about
--   Advanced media properties toolbar with inline editing,
--   customizable layout, and real-time item property display.
-- @provides
--   Data53/*.lua

local SEP = package.config:sub(1, 1)
local script_path = debug.getinfo(1, 'S').source:match('@(.+[/\\])')
local data_path = script_path .. "Data53" .. SEP

dofile(data_path .. "CP_MediaPropertiesToolbar.lua")
