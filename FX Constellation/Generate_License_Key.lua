-- @description CP Scripts License Key Generator
-- @author Cedric Pamalio
-- @version 2.0

local r = reaper

-- Load LicenseManager
local lm_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_LicenseManager.lua"
local license_manager = nil
if r.file_exists(lm_path) then
	local lm_func = dofile(lm_path)
	if lm_func then
		license_manager = lm_func()
		license_manager.init(r)
	end
end

if not license_manager then
	r.ShowMessageBox("CP_LicenseManager.lua not found in Various/", "Error", 0)
	return
end

-- Product choices
local products = {
	{ id = "BUNDLE", label = "Bundle (All Scripts)" },
	{ id = "FX_CONSTELLATION", label = "FX Constellation" },
	{ id = "CUSTOM_TOOLBARS", label = "Custom Toolbars" },
	{ id = "MEDIA_PROPERTIES", label = "Media Properties Toolbar" },
}

-- Build menu string
local menu = ""
for i, p in ipairs(products) do
	if i > 1 then menu = menu .. "|" end
	menu = menu .. p.label
end

-- Show menu
gfx.init("", 0, 0, 0, 0, 0)
local choice = gfx.showmenu(menu)
gfx.quit()

if choice < 1 then return end

local product = products[choice]
local seed = os.time() + math.random(1, 99999)
local key = license_manager.generateKey(product.id, seed)

if key then
	r.CF_SetClipboard(key)
	r.ShowMessageBox(
		product.label .. " License Key:\n\n" .. key ..
		"\n\nKey copied to clipboard.\n\n" ..
		"Product: " .. product.label .. "\n" ..
		"Type: " .. (product.id == "BUNDLE" and "Unlocks ALL paid scripts" or "Unlocks " .. product.label .. " only"),
		"CP Scripts - Key Generator", 0
	)
else
	r.ShowMessageBox("Failed to generate key.", "Error", 0)
end
