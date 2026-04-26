-- CP Scripts License Key Generator
-- Usage: lua keygen.lua [product] [count]
-- Products: BUNDLE, FX_CONSTELLATION, CUSTOM_TOOLBARS, MEDIA_PROPERTIES, CP_STUDIO
-- Example: lua keygen.lua BUNDLE 5

-- Product salts (must match CP_LicenseManager.lua)
local PRODUCTS = {
    BUNDLE = "CP_BUNDLE",
    FX_CONSTELLATION = "CP_FXCON",
    CUSTOM_TOOLBARS = "CP_CTOOL",
    MEDIA_PROPERTIES = "CP_MPTBR",
    CP_STUDIO = "CP_STUD",
}

local function generateKey(salt, seed)
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

local function validate(key, salt)
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

-- Parse args
local product = arg and arg[1] or nil
local count = arg and tonumber(arg[2]) or 1

if not product then
    print("CP Scripts License Key Generator")
    print("================================")
    print("")
    print("Usage: lua keygen.lua <product> [count]")
    print("")
    print("Products:")
    for name, salt in pairs(PRODUCTS) do
        print("  " .. name .. "  (salt: " .. salt .. ")")
    end
    print("")
    print("Examples:")
    print("  lua keygen.lua BUNDLE")
    print("  lua keygen.lua FX_CONSTELLATION 5")
    print("  lua keygen.lua ALL")
    os.exit(0)
end

if product == "ALL" then
    print("CP Scripts — License Keys (all products)")
    print("=========================================")
    print("")
    local base_seed = os.time()
    for name, salt in pairs(PRODUCTS) do
        local key = generateKey(salt, base_seed + #name)
        local valid = validate(key, salt)
        print(string.format("%-20s %s  [%s]", name, key, valid and "OK" or "FAIL"))
    end
else
    local salt = PRODUCTS[product]
    if not salt then
        print("ERROR: Unknown product '" .. product .. "'")
        print("Valid products: BUNDLE, FX_CONSTELLATION, CUSTOM_TOOLBARS, MEDIA_PROPERTIES, CP_STUDIO")
        os.exit(1)
    end

    print("CP Scripts — " .. product .. " License Keys")
    print(string.rep("=", 40))
    print("")
    local base_seed = os.time()
    for i = 1, count do
        local key = generateKey(salt, base_seed + i)
        local valid = validate(key, salt)
        print(string.format("%s  [%s]", key, valid and "OK" or "FAIL"))
    end
end
