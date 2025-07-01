--[[
	Noindex: true
]]  
local r=reaper
local id=r.NamedCommandLookup("_RS9671f2190669ed9aa441b684eb8254e93dbf9e4e")
if id>0 and r.GetToggleCommandStateEx(0,id)==1 then
  r.Main_OnCommand(id,0)
end