-- @description CP Source Manager
-- @version 1.1
-- @author Cedric Pamalio
-- @about
--   Manage and browse audio sources for selected items.

local SEP = package.config:sub(1, 1)
local script_path = debug.getinfo(1, 'S').source:match('@(.+[/\\])')
local data_path = script_path .. "Data53" .. SEP

dofile(data_path .. "CP_SourceManager.lua")
