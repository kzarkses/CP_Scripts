local FXManagerUI = {}

function FXManagerUI.init(reaper, core, fxmanager, fxdatabase, style_loader)
	FXManagerUI.r = reaper
	FXManagerUI.core = core
	FXManagerUI.fxmanager = fxmanager
	FXManagerUI.fxdatabase = fxdatabase
	FXManagerUI.style_loader = style_loader
	FXManagerUI.ctx = nil
	FXManagerUI.pushed_colors = 0
	FXManagerUI.pushed_vars = 0
end

function FXManagerUI.getStyleValue(path, default_value)
	if FXManagerUI.style_loader then
		return FXManagerUI.style_loader.GetValue(path, default_value)
	end
	return default_value
end

function FXManagerUI.getStyleFont(font_name, context)
	if not FXManagerUI.style_loader then return nil end
	local ctx = context or FXManagerUI.ctx
	local font_config = FXManagerUI.style_loader.GetValue("fonts." .. font_name, nil)
	if not font_config then return nil end
	local font = FXManagerUI.r.ImGui_CreateFont(font_config.family or "sans-serif", font_config.size or 14)
	return font
end

function FXManagerUI.drawWindow()
	if not FXManagerUI.core.state.show_fxmanager_window then return end

	if not FXManagerUI.ctx or not FXManagerUI.r.ImGui_ValidatePtr(FXManagerUI.ctx, "ImGui_Context*") then
		FXManagerUI.ctx = FXManagerUI.r.ImGui_CreateContext('FX Constellation - FX Manager')
		if FXManagerUI.style_loader then
			FXManagerUI.style_loader.ApplyFontsToContext(FXManagerUI.ctx)
		end
	end

	if FXManagerUI.style_loader then
		local success, colors, vars = FXManagerUI.style_loader.applyToContext(FXManagerUI.ctx)
		if success then
			FXManagerUI.pushed_colors = colors
			FXManagerUI.pushed_vars = vars
		end
	end

	FXManagerUI.r.ImGui_SetNextWindowSize(FXManagerUI.ctx, 600, 700, FXManagerUI.r.ImGui_Cond_FirstUseEver())

	local window_flags = FXManagerUI.r.ImGui_WindowFlags_NoTitleBar() | FXManagerUI.r.ImGui_WindowFlags_NoCollapse()
	local visible, open = FXManagerUI.r.ImGui_Begin(FXManagerUI.ctx, 'FX Manager', true, window_flags)

	if visible then
		local main_font = FXManagerUI.getStyleFont("main", FXManagerUI.ctx)
		local header_font = FXManagerUI.getStyleFont("header", FXManagerUI.ctx)

		if header_font and FXManagerUI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
			FXManagerUI.r.ImGui_PushFont(FXManagerUI.ctx, header_font, 0)
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "FX MANAGER")
			FXManagerUI.r.ImGui_PopFont(FXManagerUI.ctx)
		else
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "FX MANAGER")
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		local header_font_size = FXManagerUI.getStyleValue("fonts.header.size", 16)
		local item_spacing_x = FXManagerUI.getStyleValue("spacing.item_spacing_x", 6)
		local window_padding_x = FXManagerUI.getStyleValue("spacing.window_padding_x", 8)
		local close_button_size = header_font_size + 6
		local auto_close_button_size = close_button_size
		local buttons_width = auto_close_button_size + close_button_size + item_spacing_x
		local buttons_x = FXManagerUI.r.ImGui_GetWindowWidth(FXManagerUI.ctx) - buttons_width - window_padding_x

		FXManagerUI.r.ImGui_SetCursorPosX(FXManagerUI.ctx, buttons_x)
		local auto_close_label = FXManagerUI.core.state.fxmanager_auto_close and "A*" or "A"
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, auto_close_label, auto_close_button_size, close_button_size) then
			FXManagerUI.core.state.fxmanager_auto_close = not FXManagerUI.core.state.fxmanager_auto_close
		end
		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			FXManagerUI.r.ImGui_SetTooltip(FXManagerUI.ctx, "Auto-close window after adding FX")
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "X", close_button_size, close_button_size) then
			open = false
		end

		if main_font and FXManagerUI.r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
			FXManagerUI.r.ImGui_PushFont(FXManagerUI.ctx, main_font, 0)
		end

		FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)

		local content_width = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx)

		FXManagerUI.r.ImGui_SetNextItemWidth(FXManagerUI.ctx, content_width - 60 - item_spacing_x)
		local changed, new_search = FXManagerUI.r.ImGui_InputText(FXManagerUI.ctx, "##search", FXManagerUI.core.state.fxdb_search_query)
		if changed then
			FXManagerUI.core.state.fxdb_search_query = new_search
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Scan", 60) then
			local count = FXManagerUI.fxdatabase.scanPlugins()
			FXManagerUI.core.state.fxdb_scan_message = "Scanned " .. count .. " plugins"
			FXManagerUI.core.state.fxdb_scan_time = FXManagerUI.r.time_precise()
		end

		if FXManagerUI.core.state.fxdb_scan_message and (FXManagerUI.r.time_precise() - FXManagerUI.core.state.fxdb_scan_time) < 3.0 then
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, FXManagerUI.core.state.fxdb_scan_message)
		end

		local plugin_types = FXManagerUI.fxdatabase.getPluginTypes()
		table.insert(plugin_types, 1, "All")
		local type_filter = FXManagerUI.core.state.fxdb_type_filter or "All"
		local current_type_index = 1
		for i, ptype in ipairs(plugin_types) do
			if ptype == type_filter then
				current_type_index = i - 1
				break
			end
		end

		FXManagerUI.r.ImGui_SetNextItemWidth(FXManagerUI.ctx, content_width)
		local changed, new_index = FXManagerUI.r.ImGui_Combo(FXManagerUI.ctx, "##typefilter", current_type_index, table.concat(plugin_types, "\0") .. "\0")
		if changed then
			FXManagerUI.core.state.fxdb_type_filter = plugin_types[new_index + 1]
		end

		FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)

		local favorites = FXManagerUI.fxdatabase.getFavorites()
		if header_font and FXManagerUI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
			FXManagerUI.r.ImGui_PushFont(FXManagerUI.ctx, header_font, 0)
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "⭐ FAVORITES")
			FXManagerUI.r.ImGui_PopFont(FXManagerUI.ctx)
		else
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "FAVORITES")
		end

		local window_height = FXManagerUI.r.ImGui_GetWindowHeight(FXManagerUI.ctx)
		local favorites_height = window_height * 0.25

		if FXManagerUI.r.ImGui_BeginChild(FXManagerUI.ctx, "Favorites", 0, favorites_height, FXManagerUI.r.ImGui_ChildFlags_Border()) then
			for _, plugin in ipairs(favorites) do
				local display_name = plugin.name
				if FXManagerUI.core.state.fxdb_search_query ~= "" then
					if not display_name:lower():find(FXManagerUI.core.state.fxdb_search_query:lower(), 1, true) then
						goto continue_fav
					end
				end
				if FXManagerUI.core.state.fxdb_type_filter and FXManagerUI.core.state.fxdb_type_filter ~= "All" then
					if plugin.type ~= FXManagerUI.core.state.fxdb_type_filter then
						goto continue_fav
					end
				end

				local star_icon = "⭐"
				if FXManagerUI.r.ImGui_SmallButton(FXManagerUI.ctx, star_icon .. "##fav_" .. plugin.name) then
					FXManagerUI.fxdatabase.toggleFavorite(plugin.name)
				end

				FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
				FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, display_name)

				FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
				local button_width = 50
				local cursor_x = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx) - button_width
				FXManagerUI.r.ImGui_SetCursorPosX(FXManagerUI.ctx, FXManagerUI.r.ImGui_GetCursorPosX(FXManagerUI.ctx) + cursor_x)
				if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Add##fav_add_" .. plugin.name, button_width) then
					FXManagerUI.fxmanager.addFXByName(plugin.name)
					if FXManagerUI.core.state.fxmanager_auto_close then
						open = false
					end
				end

				::continue_fav::
			end
			FXManagerUI.r.ImGui_EndChild(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)

		if header_font and FXManagerUI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
			FXManagerUI.r.ImGui_PushFont(FXManagerUI.ctx, header_font, 0)
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "📦 ALL PLUGINS")
			FXManagerUI.r.ImGui_PopFont(FXManagerUI.ctx)
		else
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "ALL PLUGINS")
		end

		local all_height = window_height * 0.35
		if FXManagerUI.r.ImGui_BeginChild(FXManagerUI.ctx, "AllPlugins", 0, all_height, FXManagerUI.r.ImGui_ChildFlags_Border()) then
			local type_filter_value = (FXManagerUI.core.state.fxdb_type_filter == "All") and "" or FXManagerUI.core.state.fxdb_type_filter
			local plugins = FXManagerUI.fxdatabase.searchPlugins(FXManagerUI.core.state.fxdb_search_query, type_filter_value)

			for _, plugin in ipairs(plugins) do
				local star_icon = plugin.favorite and "⭐" or "☆"
				if FXManagerUI.r.ImGui_SmallButton(FXManagerUI.ctx, star_icon .. "##all_" .. plugin.name) then
					FXManagerUI.fxdatabase.toggleFavorite(plugin.name)
				end

				FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
				FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, plugin.name)

				FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
				local button_width = 50
				local cursor_x = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx) - button_width
				FXManagerUI.r.ImGui_SetCursorPosX(FXManagerUI.ctx, FXManagerUI.r.ImGui_GetCursorPosX(FXManagerUI.ctx) + cursor_x)
				if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Add##all_add_" .. plugin.name, button_width) then
					FXManagerUI.fxmanager.addFXByName(plugin.name)
					if FXManagerUI.core.state.fxmanager_auto_close then
						open = false
					end
				end
			end
			FXManagerUI.r.ImGui_EndChild(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)

		if header_font and FXManagerUI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
			FXManagerUI.r.ImGui_PushFont(FXManagerUI.ctx, header_font, 0)
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "RANDOM")
			FXManagerUI.r.ImGui_PopFont(FXManagerUI.ctx)
		else
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "RANDOM")
		end

		local changed, favorites_only = FXManagerUI.r.ImGui_Checkbox(FXManagerUI.ctx, "Favorites only", FXManagerUI.core.state.fxdb_random_favorites_only)
		if changed then
			FXManagerUI.core.state.fxdb_random_favorites_only = favorites_only
		end

		FXManagerUI.r.ImGui_SetNextItemWidth(FXManagerUI.ctx, content_width)
		local changed, new_count = FXManagerUI.r.ImGui_SliderInt(FXManagerUI.ctx, "Count", FXManagerUI.core.state.fxdb_random_count, 1, 20)
		if changed then
			FXManagerUI.core.state.fxdb_random_count = new_count
		end

		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Add Random FX", content_width) then
			FXManagerUI.fxmanager.addRandomFX(FXManagerUI.core.state.fxdb_random_count, FXManagerUI.core.state.fxdb_random_favorites_only)
			if FXManagerUI.core.state.fxmanager_auto_close then
				open = false
			end
		end

		if main_font and FXManagerUI.r.ImGui_ValidatePtr(main_font, "ImGui_Font*") then
			FXManagerUI.r.ImGui_PopFont(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_End(FXManagerUI.ctx)
	end

	if not open then
		FXManagerUI.core.state.show_fxmanager_window = false
	end

	if FXManagerUI.style_loader then
		FXManagerUI.style_loader.clearStyles(FXManagerUI.ctx, FXManagerUI.pushed_colors, FXManagerUI.pushed_vars)
	end
end

return FXManagerUI
