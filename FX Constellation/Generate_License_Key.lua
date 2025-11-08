-- @description Generate FX Constellation License Key
-- @author Cedric Pamalio
-- @version 1.0

local r = reaper

function generateKey(seed)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local key = ""
	math.randomseed(seed)
	for i = 1, 16 do
		local idx = math.random(1, #chars)
		key = key .. chars:sub(idx, idx)
		if i % 4 == 0 and i < 16 then
			key = key .. "-"
		end
	end
	local hash = 0
	for i = 1, #key do
		hash = (hash * 31 + string.byte(key, i)) % 1000000007
	end
	local checksum = 12345 - (hash % 54321)
	if checksum < 0 then checksum = checksum + 54321 end
	local check_char = chars:sub((checksum % #chars) + 1, (checksum % #chars) + 1)
	return key .. check_char
end

local seed = os.time() + math.random(1, 10000)
local key = generateKey(seed)

r.ShowMessageBox("FX Constellation License Key:\n\n" .. key .. "\n\nCopy this key and use it in FX Constellation\nto activate the full version.", "License Key Generator", 0)
r.CF_SetClipboard(key)
