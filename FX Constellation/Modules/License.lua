local License = {}

local license_manager = nil

function License.init(reaper_api, lm)
	License.r = reaper_api
	License.EXT_SECTION = "CP_FXConstellation"
	license_manager = lm
end

function License.getKey()
	return License.r.GetExtState(License.EXT_SECTION, "license_key")
end

function License.setKey(key)
	License.r.SetExtState(License.EXT_SECTION, "license_key", key, true)
end

-- Legacy validation (old keys without salt)
local function validateLegacy(key)
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

function License.validate(key)
	-- Try new system first (LicenseManager: bundle + per-script)
	if license_manager then
		if license_manager.validate(key, license_manager.PRODUCTS.BUNDLE) then
			return true
		end
		if license_manager.validate(key, license_manager.PRODUCTS.FX_CONSTELLATION) then
			return true
		end
	end
	-- Fallback to legacy validation (old keys)
	return validateLegacy(key)
end

function License.getStatus()
	-- Check via LicenseManager first (bundle key)
	if license_manager then
		local bundle_key = license_manager.getKey("BUNDLE")
		if bundle_key ~= "" and license_manager.validate(bundle_key, license_manager.PRODUCTS.BUNDLE) then
			return "FULL"
		end
	end

	-- Check per-script key (new or legacy)
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

-- Store a key, auto-detecting if it's a bundle or per-script key
function License.enterKey(key)
	if license_manager then
		if license_manager.validate(key, license_manager.PRODUCTS.BUNDLE) then
			license_manager.setKey("BUNDLE", key)
			return "FULL"
		end
		if license_manager.validate(key, license_manager.PRODUCTS.FX_CONSTELLATION) then
			License.setKey(key)
			return "FULL"
		end
	end
	-- Try legacy
	if validateLegacy(key) then
		License.setKey(key)
		return "FULL"
	end
	return "INVALID"
end

return License
