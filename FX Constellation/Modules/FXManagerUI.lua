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
	FXManagerUI.double_click_time = 0
	FXManagerUI.double_click_plugin = nil
end

function FXManagerUI.getStyleValue(path, default_value)
	if FXManagerUI.style_loader then
		return FXManagerUI.style_loader.GetValue(path, default_value)
	end
	return default_value
end

function FXManagerUI.getStyleFont(font_name, context)
	return FXManagerUI.style_loader and FXManagerUI.style_loader.getFont(context or FXManagerUI.ctx, font_name) or nil
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

	FXManagerUI.r.ImGui_SetNextWindowSize(FXManagerUI.ctx, 800, 600, FXManagerUI.r.ImGui_Cond_FirstUseEver())

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

		FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)

		local categories_width = content_width * 0.25

		if FXManagerUI.r.ImGui_BeginChild(FXManagerUI.ctx, "Categories", categories_width, 0) then
			FXManagerUI.drawCategories(header_font)
			FXManagerUI.r.ImGui_EndChild(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		FXManagerUI.r.ImGui_Dummy(FXManagerUI.ctx, 0, 0)
		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)

		if FXManagerUI.r.ImGui_BeginChild(FXManagerUI.ctx, "PluginsList", 0, 0) then
			FXManagerUI.drawPluginsList(header_font)
			FXManagerUI.r.ImGui_EndChild(FXManagerUI.ctx)
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

function FXManagerUI.drawCategories(header_font)
	local categories = FXManagerUI.fxdatabase.getCategories()

	for _, category in ipairs(categories) do
		local is_selected = FXManagerUI.core.state.fxdb_selected_category == category.name
		local flags = is_selected and FXManagerUI.r.ImGui_TreeNodeFlags_Selected() or 0
		flags = flags | FXManagerUI.r.ImGui_TreeNodeFlags_Leaf() | FXManagerUI.r.ImGui_TreeNodeFlags_NoTreePushOnOpen()

		FXManagerUI.r.ImGui_TreeNodeEx(FXManagerUI.ctx, category.name, flags, category.name)

		if FXManagerUI.r.ImGui_IsItemClicked(FXManagerUI.ctx) then
			FXManagerUI.core.state.fxdb_selected_category = category.name
		end
	end
end

function FXManagerUI.drawPluginsList(header_font)
	local selected_category = FXManagerUI.core.state.fxdb_selected_category
	local search_query = FXManagerUI.core.state.fxdb_search_query
	local plugins = FXManagerUI.fxdatabase.searchPlugins(search_query, selected_category)

	for _, plugin in ipairs(plugins) do
		local star_icon = plugin.favorite and "⭐" or "☆"

		if FXManagerUI.r.ImGui_SmallButton(FXManagerUI.ctx, star_icon .. "##fav_" .. plugin.name) then
			FXManagerUI.fxdatabase.toggleFavorite(plugin.name)
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)

		local is_hovered = FXManagerUI.core.state.fxdb_hovered_plugin == plugin.name

		if is_hovered then
			local draw_list = FXManagerUI.r.ImGui_GetWindowDrawList(FXManagerUI.ctx)
			local cursor_x, cursor_y = FXManagerUI.r.ImGui_GetCursorScreenPos(FXManagerUI.ctx)
			local text_width, text_height = FXManagerUI.r.ImGui_CalcTextSize(FXManagerUI.ctx, plugin.name)
			local highlight_color = FXManagerUI.getStyleValue("colors.button_hovered", 0x1AFFFFFF)
			FXManagerUI.r.ImGui_DrawList_AddRectFilled(draw_list, cursor_x, cursor_y, cursor_x + text_width, cursor_y + text_height, highlight_color)
		end

		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, plugin.name)

		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			FXManagerUI.core.state.fxdb_hovered_plugin = plugin.name

			if FXManagerUI.r.ImGui_IsMouseDoubleClicked(FXManagerUI.ctx, 0) then
				FXManagerUI.fxmanager.addFXByName(plugin.name)
				if FXManagerUI.core.state.fxmanager_auto_close then
					FXManagerUI.core.state.show_fxmanager_window = false
				end
			end
		else
			if FXManagerUI.core.state.fxdb_hovered_plugin == plugin.name then
				FXManagerUI.core.state.fxdb_hovered_plugin = nil
			end
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		local button_width = 50
		local cursor_x = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx) - button_width
		FXManagerUI.r.ImGui_SetCursorPosX(FXManagerUI.ctx, FXManagerUI.r.ImGui_GetCursorPosX(FXManagerUI.ctx) + cursor_x)
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Add##add_" .. plugin.name, button_width) then
			FXManagerUI.fxmanager.addFXByName(plugin.name)
			if FXManagerUI.core.state.fxmanager_auto_close then
				FXManagerUI.core.state.show_fxmanager_window = false
			end
		end
	end
end

return FXManagerUI
