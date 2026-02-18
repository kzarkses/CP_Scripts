-- @description CP License Manager
-- @version 1.0
-- @author Cedric Pamalio
-- @about Shared license validation for CP Scripts paid products

return function()

local LicenseManager = {}

-- Product salts (used in key generation/validation)
LicenseManager.PRODUCTS = {
	BUNDLE = "CP_BUNDLE",
	FX_CONSTELLATION = "CP_FXCON",
	CUSTOM_TOOLBARS = "CP_CTOOL",
	MEDIA_PROPERTIES = "CP_MPTBR",
}

-- ExtState sections for storing keys
LicenseManager.EXT_SECTIONS = {
	BUNDLE = "CP_Scripts",
	FX_CONSTELLATION = "CP_FXConstellation",
	CUSTOM_TOOLBARS = "CP_CustomToolbars",
	MEDIA_PROPERTIES = "CP_MediaPropertiesToolbar",
}

local r = nil

function LicenseManager.init(reaper_api)
	r = reaper_api
end

function LicenseManager.validate(key, salt)
	if not key or key == "" or #key < 20 then return false end

	local key_body = key:sub(1, #key - 1)
	local check_char = key:sub(#key, #key)

	local data = salt .. key_body
	local hash = 0
	for i = 1, #data do
		hash = (hash * 31 + string.byte(data, i)) % 1000000007
	end

	local checksum = 12345 - (hash % 54321)
	if checksum < 0 then checksum = checksum + 54321 end

	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local expected = chars:sub((checksum % #chars) + 1, (checksum % #chars) + 1)

	return check_char == expected
end

function LicenseManager.getKey(product)
	local section = LicenseManager.EXT_SECTIONS[product]
	if not section then return "" end
	return r.GetExtState(section, "license_key")
end

function LicenseManager.setKey(product, key)
	local section = LicenseManager.EXT_SECTIONS[product]
	if not section then return end
	r.SetExtState(section, "license_key", key, true)
end

function LicenseManager.isLicensed(product)
	-- Check bundle key first
	local bundle_key = LicenseManager.getKey("BUNDLE")
	if bundle_key ~= "" and LicenseManager.validate(bundle_key, LicenseManager.PRODUCTS.BUNDLE) then
		return true
	end

	-- Check per-script key
	local script_key = LicenseManager.getKey(product)
	if script_key ~= "" and LicenseManager.validate(script_key, LicenseManager.PRODUCTS[product]) then
		return true
	end

	return false
end

function LicenseManager.getStatus(product)
	local bundle_key = LicenseManager.getKey("BUNDLE")
	local script_key = LicenseManager.getKey(product)

	if bundle_key == "" and script_key == "" then
		return "FREE"
	end

	if LicenseManager.isLicensed(product) then
		return "FULL"
	end

	return "INVALID"
end

function LicenseManager.generateKey(product, seed)
	local salt = LicenseManager.PRODUCTS[product]
	if not salt then return nil end

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

	local data = salt .. key
	local hash = 0
	for i = 1, #data do
		hash = (hash * 31 + string.byte(data, i)) % 1000000007
	end

	local checksum = 12345 - (hash % 54321)
	if checksum < 0 then checksum = checksum + 54321 end
	local check_char = chars:sub((checksum % #chars) + 1, (checksum % #chars) + 1)

	return key .. check_char
end

return LicenseManager

end
