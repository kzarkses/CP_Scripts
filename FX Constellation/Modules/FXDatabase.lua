local FXDatabase = {}

function FXDatabase.init(reaper, core, persistence, data_path)
	FXDatabase.r = reaper
	FXDatabase.core = core
	FXDatabase.persistence = persistence
	FXDatabase.data_path = data_path
	FXDatabase.database_file = data_path .. "fx_database.dat"
	FXDatabase.plugins = {}
	FXDatabase.favorites = {}
	FXDatabase.last_scan_time = 0
end

function FXDatabase.parsePluginsIni()
	local plugins = {}
	local resource_path = FXDatabase.r.GetResourcePath()

	local ini_files = {
		resource_path .. "/reaper-vstplugins64.ini",
		resource_path .. "/reaper-vstplugins.ini",
		resource_path .. "/reaper-vst3plugins64.ini",
		resource_path .. "/reaper-vst3plugins.ini",
		resource_path .. "/reaper-jsfx.ini"
	}

	for _, ini_path in ipairs(ini_files) do
		local file = io.open(ini_path, "r")
		if file then
			local current_type = ""

			for line in file:lines() do
				local section = line:match("%[(.+)%]")
				if section then
					current_type = section
				else
					local plugin_name = line:match("^([^=]+)=")
					if plugin_name and plugin_name ~= "" and current_type ~= "" then
						local clean_name = plugin_name:match("^%s*(.-)%s*$")
						if clean_name and clean_name ~= "" then
							table.insert(plugins, {
								name = clean_name,
								type = current_type,
								favorite = false
							})
						end
					end
				end
			end

			file:close()
		end
	end

	return plugins
end

function FXDatabase.scanPlugins()
	FXDatabase.plugins = FXDatabase.parsePluginsIni()
	FXDatabase.last_scan_time = FXDatabase.r.time_precise()
	FXDatabase.saveDatabase()
	return #FXDatabase.plugins
end

function FXDatabase.saveDatabase()
	local file = io.open(FXDatabase.database_file, "w")
	if not file then return false end

	local data = {
		plugins = FXDatabase.plugins,
		favorites = FXDatabase.favorites,
		last_scan_time = FXDatabase.last_scan_time
	}

	file:write("return " .. FXDatabase.serializeTable(data))
	file:close()
	return true
end

function FXDatabase.loadDatabase()
	local file = io.open(FXDatabase.database_file, "r")
	if not file then
		FXDatabase.scanPlugins()
		return
	end

	local content = file:read("*all")
	file:close()

	local chunk, err = load(content)
	if chunk then
		local data = chunk()
		if data then
			FXDatabase.plugins = data.plugins or {}
			FXDatabase.favorites = data.favorites or {}
			FXDatabase.last_scan_time = data.last_scan_time or 0

			for _, plugin in ipairs(FXDatabase.plugins) do
				if FXDatabase.favorites[plugin.name] then
					plugin.favorite = true
				end
			end
		end
	else
		FXDatabase.scanPlugins()
	end
end

function FXDatabase.toggleFavorite(plugin_name)
	FXDatabase.favorites[plugin_name] = not FXDatabase.favorites[plugin_name] or nil

	for _, plugin in ipairs(FXDatabase.plugins) do
		if plugin.name == plugin_name then
			plugin.favorite = FXDatabase.favorites[plugin_name] or false
			break
		end
	end

	FXDatabase.saveDatabase()
end

function FXDatabase.isFavorite(plugin_name)
	return FXDatabase.favorites[plugin_name] == true
end

function FXDatabase.getFavorites()
	local favs = {}
	for _, plugin in ipairs(FXDatabase.plugins) do
		if plugin.favorite then
			table.insert(favs, plugin)
		end
	end
	return favs
end

function FXDatabase.searchPlugins(query, type_filter)
	if not query or query == "" then
		if type_filter and type_filter ~= "" then
			return FXDatabase.filterByType(type_filter)
		end
		return FXDatabase.plugins
	end

	local results = {}
	local lower_query = query:lower()

	for _, plugin in ipairs(FXDatabase.plugins) do
		if type_filter and type_filter ~= "" and plugin.type ~= type_filter then
			goto continue
		end

		if plugin.name:lower():find(lower_query, 1, true) then
			table.insert(results, plugin)
		end

		::continue::
	end

	return results
end

function FXDatabase.filterByType(plugin_type)
	local results = {}
	for _, plugin in ipairs(FXDatabase.plugins) do
		if plugin.type == plugin_type then
			table.insert(results, plugin)
		end
	end
	return results
end

function FXDatabase.getRandomPlugin(favorites_only)
	local pool = favorites_only and FXDatabase.getFavorites() or FXDatabase.plugins
	if #pool == 0 then return nil end

	local index = math.random(1, #pool)
	return pool[index]
end

function FXDatabase.getRandomPlugins(count, favorites_only)
	local plugins = {}
	for i = 1, count do
		local plugin = FXDatabase.getRandomPlugin(favorites_only)
		if plugin then
			table.insert(plugins, plugin)
		end
	end
	return plugins
end

function FXDatabase.getPluginTypes()
	local types = {}
	local types_set = {}

	for _, plugin in ipairs(FXDatabase.plugins) do
		if not types_set[plugin.type] then
			types_set[plugin.type] = true
			table.insert(types, plugin.type)
		end
	end

	table.sort(types)
	return types
end

function FXDatabase.serializeTable(tbl, indent)
	indent = indent or 0
	local spacing = string.rep("  ", indent)
	local result = "{\n"

	for k, v in pairs(tbl) do
		local key_str = type(k) == "string" and '["' .. k .. '"]' or "[" .. k .. "]"

		if type(v) == "table" then
			result = result .. spacing .. "  " .. key_str .. " = " .. FXDatabase.serializeTable(v, indent + 1) .. ",\n"
		elseif type(v) == "string" then
			local escaped = v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
			result = result .. spacing .. "  " .. key_str .. ' = "' .. escaped .. '",\n'
		elseif type(v) == "number" or type(v) == "boolean" then
			result = result .. spacing .. "  " .. key_str .. " = " .. tostring(v) .. ",\n"
		end
	end

	result = result .. spacing .. "}"
	return result
end

return FXDatabase
