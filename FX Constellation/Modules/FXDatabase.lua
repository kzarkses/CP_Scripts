local FXDatabase = {}

function FXDatabase.init(reaper, core, persistence, data_path)
	FXDatabase.r = reaper
	FXDatabase.core = core
	FXDatabase.persistence = persistence
	FXDatabase.data_path = data_path
	FXDatabase.database_file = data_path .. "fx_database.dat"
	FXDatabase.plugins = {}
	FXDatabase.favorites = {}
	FXDatabase.categories = {}
	FXDatabase.last_scan_time = 0
	FXDatabase.blacklist = {
		"waveshell",
		"<SHELL>",
		"!!!VSTi$"
	}
end

function FXDatabase.isBlacklisted(name)
	local lower_name = name:lower()
	for _, pattern in ipairs(FXDatabase.blacklist) do
		if lower_name:find(pattern:lower()) then
			return true
		end
	end
	return false
end

function FXDatabase.parsePluginsIni()
	local plugins = {}
	local plugin_map = {}
	local resource_path = FXDatabase.r.GetResourcePath()

	local ini_files = {
		{path = resource_path .. "/reaper-vst3plugins64.ini", type = "VST3", priority = 1},
		{path = resource_path .. "/reaper-vst3plugins.ini", type = "VST3", priority = 1},
		{path = resource_path .. "/reaper-vstplugins64.ini", type = "VST", priority = 2},
		{path = resource_path .. "/reaper-vstplugins.ini", type = "VST", priority = 2},
		{path = resource_path .. "/reaper-jsfx.ini", type = "JS", priority = 3}
	}

	for _, ini_info in ipairs(ini_files) do
		local file = io.open(ini_info.path, "r")
		if file then
			local current_section = ""

			for line in file:lines() do
				local section = line:match("%[(.+)%]")
				if section then
					current_section = section
				else
					local line_content = line:match("^([^=]+)=(.+)$")
					if line_content then
						local key_name, value_part = line:match("^([^=]+)=(.+)$")
						if key_name and value_part and current_section ~= "" then
							local clean_key = key_name:match("^%s*(.-)%s*$")
							if clean_key and clean_key ~= "" and not FXDatabase.isBlacklisted(clean_key) then
								local parts = {}
								for part in value_part:gmatch("[^,]+") do
									table.insert(parts, part)
								end
								
								if #parts >= 3 then
									local plugin_display_name = parts[3]:match("^%s*(.-)%s*$")
									if plugin_display_name and plugin_display_name ~= "" then
										local original_name = plugin_display_name
										local is_instrument = original_name:find("!!!VSTi")
										if is_instrument then
											original_name = original_name:gsub("!!!VSTi", "")
										end

										local display_name = original_name
										display_name = display_name:gsub("%.vst3%<%d+%>", "")
										display_name = display_name:gsub("%x%x%x%x%x%x%x%x%x%x+", "")
										display_name = display_name:gsub("%s+", " "):match("^%s*(.-)%s*$")

										local map_key = display_name:lower()
										if not plugin_map[map_key] or plugin_map[map_key].priority > ini_info.priority then
											local plugin_entry = {
												name = original_name,
												display_name = display_name,
												type = ini_info.type,
												instrument = is_instrument,
												favorite = false,
												priority = ini_info.priority
											}
											plugin_map[map_key] = plugin_entry
										end
									end
								end
							end
						end
					end
				end
			end

			file:close()
		end
	end

	for _, plugin in pairs(plugin_map) do
		plugin.priority = nil
		table.insert(plugins, plugin)
	end

	return plugins
end

function FXDatabase.parseFXFolders()
	local categories = {
		{name = "All", type = "builtin", collapsed = false},
		{name = "Favorites", type = "builtin", collapsed = false},
		{name = "VST", type = "builtin", collapsed = false},
		{name = "VST3", type = "builtin", collapsed = false},
		{name = "JS Effects", type = "builtin", collapsed = false}
	}

	return categories
end

function FXDatabase.scanPlugins()
	FXDatabase.plugins = FXDatabase.parsePluginsIni()
	FXDatabase.categories = FXDatabase.parseFXFolders()
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
		categories = FXDatabase.categories,
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
			FXDatabase.categories = data.categories or FXDatabase.parseFXFolders()
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
	local current_state = FXDatabase.favorites[plugin_name]
	if current_state then
		FXDatabase.favorites[plugin_name] = nil
	else
		FXDatabase.favorites[plugin_name] = true
	end

	for _, plugin in ipairs(FXDatabase.plugins) do
		if plugin.name == plugin_name then
			plugin.favorite = FXDatabase.favorites[plugin_name] == true
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

function FXDatabase.getPluginsByCategory(category_name)
	if category_name == "All" then
		return FXDatabase.plugins
	elseif category_name == "Favorites" then
		return FXDatabase.getFavorites()
	elseif category_name == "VST" then
		return FXDatabase.filterByType("VST")
	elseif category_name == "VST3" then
		return FXDatabase.filterByType("VST3")
	elseif category_name == "JS Effects" then
		return FXDatabase.filterByType("JS")
	else
		return FXDatabase.plugins
	end
end

function FXDatabase.searchPlugins(query, category_name)
	local base_plugins = FXDatabase.getPluginsByCategory(category_name or "All")

	if not query or query == "" then
		return base_plugins
	end

	local results = {}
	local lower_query = query:lower()

	for _, plugin in ipairs(base_plugins) do
		local search_text = plugin.display_name or plugin.name
		if search_text:lower():find(lower_query, 1, true) then
			table.insert(results, plugin)
		end
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

function FXDatabase.getCategories()
	if not FXDatabase.categories or #FXDatabase.categories == 0 then
		FXDatabase.categories = FXDatabase.parseFXFolders()
	end
	return FXDatabase.categories
end

function FXDatabase.toggleCategoryCollapsed(category_name)
	for _, category in ipairs(FXDatabase.categories) do
		if category.name == category_name then
			category.collapsed = not category.collapsed
			FXDatabase.saveDatabase()
			return
		end
	end
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
