-- @description MediaPropertiesToolbar - ON
-- @version 1.0
-- @author Cedric Pamalio

local r=reaper
local id=r.NamedCommandLookup("_RS3daea83c1000c138b40c9dfe94366a194fc4163f")
if id>0 and r.GetToggleCommandStateEx(0,id)==0 then
  r.Main_OnCommand(id,0)
end









