local License = {}

function License.init(reaper_api)
	License.r = reaper_api
	License.EXT_SECTION = "CP_FXConstellation"
end

function License.getKey()
	return License.r.GetExtState(License.EXT_SECTION, "license_key")
end

function License.setKey(key)
	License.r.SetExtState(License.EXT_SECTION, "license_key", key, true)
end

function License.validate(key)
	if not key or key == "" or #key < 20 then return false end
	local key_without_check = key:sub(1, #key - 1)
	local check_char = key:sub(#key, #key)
	local hash = 0
	for i = 1, #key_without_check do
		hash = (hash * 31 + string.byte(key_without_check, i)) % 1000000007
	end
	local expected_checksum = 12345 - (hash % 54321)
	if expected_checksum < 0 then expected_checksum = expected_checksum + 54321 end
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local expected_char = chars:sub((expected_checksum % #chars) + 1, (expected_checksum % #chars) + 1)
	return check_char == expected_char
end

function License.getStatus()
	local key = License.getKey()
	if key == "" then
		return "FREE"
	elseif License.validate(key) then
		return "FULL"
	else
		return "INVALID"
	end
end

function License.isFull()
	return License.getStatus() == "FULL"
end

function License.generateKey(seed)
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

return License
