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
		local main_font = FXManagerUI.getStyleFont("main")
		local header_font = FXManagerUI.getStyleFont("header")

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
		local auto_open_button_size = close_button_size
		local auto_close_button_size = close_button_size
		local scan_button_width = 60
		local buttons_width = scan_button_width + auto_open_button_size + auto_close_button_size + close_button_size + item_spacing_x * 3
		local buttons_x = FXManagerUI.r.ImGui_GetWindowWidth(FXManagerUI.ctx) - buttons_width - window_padding_x

		FXManagerUI.r.ImGui_SetCursorPosX(FXManagerUI.ctx, buttons_x)
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Scan", scan_button_width, close_button_size) then
			local count = FXManagerUI.fxdatabase.scanPlugins()
			FXManagerUI.core.state.fxdb_scan_message = "Scanned " .. count .. " plugins"
			FXManagerUI.core.state.fxdb_scan_time = FXManagerUI.r.time_precise()
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		if not FXManagerUI.core.state.fxmanager_auto_open then
			FXManagerUI.core.state.fxmanager_auto_open = false
		end
		local auto_open_label = FXManagerUI.core.state.fxmanager_auto_open and "O*" or "O"
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, auto_open_label, auto_open_button_size, close_button_size) then
			FXManagerUI.core.state.fxmanager_auto_open = not FXManagerUI.core.state.fxmanager_auto_open
		end
		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			FXManagerUI.r.ImGui_SetTooltip(FXManagerUI.ctx, "Auto-open FX windows after adding")
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
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

		FXManagerUI.r.ImGui_SetNextItemWidth(FXManagerUI.ctx, content_width - 70 - item_spacing_x)
		local changed, new_search = FXManagerUI.r.ImGui_InputText(FXManagerUI.ctx, "##search", FXManagerUI.core.state.fxdb_search_query)
		if changed then
			FXManagerUI.core.state.fxdb_search_query = new_search
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		if not FXManagerUI.core.state.fxdb_sort_mode then
			FXManagerUI.core.state.fxdb_sort_mode = "none"
		end
		local sort_label = FXManagerUI.core.state.fxdb_sort_mode == "az" and "Z-A" or "A-Z"
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, sort_label, 70) then
			if FXManagerUI.core.state.fxdb_sort_mode == "none" or FXManagerUI.core.state.fxdb_sort_mode == "za" then
				FXManagerUI.core.state.fxdb_sort_mode = "az"
			else
				FXManagerUI.core.state.fxdb_sort_mode = "za"
			end
		end

		if FXManagerUI.core.state.fxdb_scan_message and (FXManagerUI.r.time_precise() - FXManagerUI.core.state.fxdb_scan_time) < 3.0 then
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, FXManagerUI.core.state.fxdb_scan_message)
		end

		FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)

		-- Initialize column widths if they don't exist
		if not FXManagerUI.core.state.fxmanager_categories_width then
			FXManagerUI.core.state.fxmanager_categories_width = 160
		end
		if not FXManagerUI.core.state.fxmanager_fxchain_width then
			FXManagerUI.core.state.fxmanager_fxchain_width = 200
		end

		local categories_width = FXManagerUI.core.state.fxmanager_categories_width
		local fxchain_width = FXManagerUI.core.state.fxmanager_fxchain_width
		local splitter_width = 4
		local plugins_width = content_width - categories_width - fxchain_width - splitter_width * 2 - item_spacing_x * 2
		local child_height = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx)

		if FXManagerUI.r.ImGui_BeginChild(FXManagerUI.ctx, "Categories", categories_width, child_height) then
			FXManagerUI.drawCategories(header_font)
			FXManagerUI.r.ImGui_EndChild(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx, 0, 0)

		-- Vertical splitter for categories/plugins
		FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "##splitter1", splitter_width, child_height)
		if FXManagerUI.r.ImGui_IsItemActive(FXManagerUI.ctx) then
			local delta_x, _ = FXManagerUI.r.ImGui_GetMouseDelta(FXManagerUI.ctx)
			FXManagerUI.core.state.fxmanager_categories_width = math.max(100, FXManagerUI.core.state.fxmanager_categories_width + delta_x)
		end
		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			FXManagerUI.r.ImGui_SetMouseCursor(FXManagerUI.ctx, FXManagerUI.r.ImGui_MouseCursor_ResizeEW())
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx, 0, 0)

		-- Recalculate plugins_width after potential resize
		plugins_width = content_width - FXManagerUI.core.state.fxmanager_categories_width - fxchain_width - splitter_width * 2 - item_spacing_x * 2

		if FXManagerUI.r.ImGui_BeginChild(FXManagerUI.ctx, "PluginsList", plugins_width, child_height) then
			FXManagerUI.drawPluginsList(header_font)
			FXManagerUI.r.ImGui_EndChild(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx, 0, 0)

		-- Vertical splitter for plugins/fxchain
		FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "##splitter2", splitter_width, child_height)
		if FXManagerUI.r.ImGui_IsItemActive(FXManagerUI.ctx) then
			local delta_x, _ = FXManagerUI.r.ImGui_GetMouseDelta(FXManagerUI.ctx)
			FXManagerUI.core.state.fxmanager_fxchain_width = math.max(150, FXManagerUI.core.state.fxmanager_fxchain_width - delta_x)
		end
		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			FXManagerUI.r.ImGui_SetMouseCursor(FXManagerUI.ctx, FXManagerUI.r.ImGui_MouseCursor_ResizeEW())
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx, 0, 0)

		if FXManagerUI.r.ImGui_BeginChild(FXManagerUI.ctx, "FXChain", FXManagerUI.core.state.fxmanager_fxchain_width, child_height) then
			FXManagerUI.drawFXChain(header_font)
			FXManagerUI.r.ImGui_EndChild(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)
		FXManagerUI.drawRandomFXInsertion(header_font)

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
	local all_categories = FXManagerUI.fxdatabase.getAllCategories()

	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Header(), 0x40404080)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_HeaderHovered(), 0x606060AA)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_HeaderActive(), 0x808080CC)

	for _, category in ipairs(all_categories) do
		local is_selected = FXManagerUI.core.state.fxdb_selected_category == category.name
		local flags = is_selected and FXManagerUI.r.ImGui_TreeNodeFlags_Selected() or 0
		flags = flags | FXManagerUI.r.ImGui_TreeNodeFlags_Leaf() | FXManagerUI.r.ImGui_TreeNodeFlags_NoTreePushOnOpen()

		FXManagerUI.r.ImGui_TreeNodeEx(FXManagerUI.ctx, category.name, category.name, flags)

		if FXManagerUI.r.ImGui_IsItemClicked(FXManagerUI.ctx) then
			FXManagerUI.core.state.fxdb_selected_category = category.name
		end

		if category.type == "custom" then
			if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) and FXManagerUI.r.ImGui_IsMouseReleased(FXManagerUI.ctx, 1) then
				FXManagerUI.r.ImGui_OpenPopup(FXManagerUI.ctx, "CategoryContextMenu##" .. category.name)
			end

			if FXManagerUI.r.ImGui_BeginPopup(FXManagerUI.ctx, "CategoryContextMenu##" .. category.name) then
				if FXManagerUI.r.ImGui_MenuItem(FXManagerUI.ctx, "Rename") then
					FXManagerUI.core.state.renaming_folder = category.name
					FXManagerUI.core.state.rename_folder_text = category.name
				end
				if FXManagerUI.r.ImGui_MenuItem(FXManagerUI.ctx, "Delete") then
					FXManagerUI.fxdatabase.deleteFolder(category.name)
					if FXManagerUI.core.state.fxdb_selected_category == category.name then
						FXManagerUI.core.state.fxdb_selected_category = "All"
					end
				end
				FXManagerUI.r.ImGui_EndPopup(FXManagerUI.ctx)
			end

			if FXManagerUI.r.ImGui_BeginDragDropTarget(FXManagerUI.ctx) then
				local ret, payload = FXManagerUI.r.ImGui_AcceptDragDropPayload(FXManagerUI.ctx, "FX_ADD")
				if ret then
					local plugins_data = {}
					for plugin_str in payload:gmatch("[^|]+") do
						local name, ptype, is_inst = plugin_str:match("^(.-)::(.-)::(.-)$")
						if name and ptype then
							FXManagerUI.fxdatabase.addPluginToFolder(category.name, name)
						end
					end
				end
				FXManagerUI.r.ImGui_EndDragDropTarget(FXManagerUI.ctx)
			end
		end
	end

	FXManagerUI.r.ImGui_Dummy(FXManagerUI.ctx, 0, 10)

	if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "+", 0) then
		FXManagerUI.core.state.creating_folder = true
		FXManagerUI.core.state.new_folder_name = "New Folder"
	end
	if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
		FXManagerUI.r.ImGui_SetTooltip(FXManagerUI.ctx, "Create New Folder")
	end

	if FXManagerUI.core.state.creating_folder then
		FXManagerUI.r.ImGui_OpenPopup(FXManagerUI.ctx, "CreateFolderPopup")
		FXManagerUI.core.state.creating_folder = false
	end

	if FXManagerUI.core.state.renaming_folder then
		FXManagerUI.r.ImGui_OpenPopup(FXManagerUI.ctx, "RenameFolderPopup")
		local old_name = FXManagerUI.core.state.renaming_folder
		FXManagerUI.core.state.renaming_folder = nil
		FXManagerUI.core.state.renaming_folder_old_name = old_name
	end

	if FXManagerUI.r.ImGui_BeginPopup(FXManagerUI.ctx, "CreateFolderPopup") then
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "New Folder Name:")
		local changed, new_text = FXManagerUI.r.ImGui_InputText(FXManagerUI.ctx, "##newfoldername", FXManagerUI.core.state.new_folder_name or "")
		if changed then
			FXManagerUI.core.state.new_folder_name = new_text
		end
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Create") then
			if FXManagerUI.core.state.new_folder_name and FXManagerUI.core.state.new_folder_name ~= "" then
				FXManagerUI.fxdatabase.createFolder(FXManagerUI.core.state.new_folder_name)
			end
			FXManagerUI.r.ImGui_CloseCurrentPopup(FXManagerUI.ctx)
		end
		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Cancel") then
			FXManagerUI.r.ImGui_CloseCurrentPopup(FXManagerUI.ctx)
		end
		FXManagerUI.r.ImGui_EndPopup(FXManagerUI.ctx)
	end

	if FXManagerUI.r.ImGui_BeginPopup(FXManagerUI.ctx, "RenameFolderPopup") then
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Rename Folder:")
		local changed, new_text = FXManagerUI.r.ImGui_InputText(FXManagerUI.ctx, "##renamefoldername", FXManagerUI.core.state.rename_folder_text or "")
		if changed then
			FXManagerUI.core.state.rename_folder_text = new_text
		end
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Rename") then
			if FXManagerUI.core.state.rename_folder_text and FXManagerUI.core.state.rename_folder_text ~= "" and FXManagerUI.core.state.renaming_folder_old_name then
				FXManagerUI.fxdatabase.renameFolder(FXManagerUI.core.state.renaming_folder_old_name, FXManagerUI.core.state.rename_folder_text)
				if FXManagerUI.core.state.fxdb_selected_category == FXManagerUI.core.state.renaming_folder_old_name then
					FXManagerUI.core.state.fxdb_selected_category = FXManagerUI.core.state.rename_folder_text
				end
			end
			FXManagerUI.r.ImGui_CloseCurrentPopup(FXManagerUI.ctx)
		end
		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
		if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Cancel") then
			FXManagerUI.r.ImGui_CloseCurrentPopup(FXManagerUI.ctx)
		end
		FXManagerUI.r.ImGui_EndPopup(FXManagerUI.ctx)
	end

	FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx, 3)
end

function FXManagerUI.drawPluginsList(header_font)
	local selected_category = FXManagerUI.core.state.fxdb_selected_category
	local search_query = FXManagerUI.core.state.fxdb_search_query
	local plugins = FXManagerUI.fxdatabase.searchPlugins(search_query, selected_category)

	if FXManagerUI.core.state.fxdb_sort_mode == "az" then
		table.sort(plugins, function(a, b)
			local name_a = (a.display_name or a.name):lower()
			local name_b = (b.display_name or b.name):lower()
			return name_a < name_b
		end)
	elseif FXManagerUI.core.state.fxdb_sort_mode == "za" then
		table.sort(plugins, function(a, b)
			local name_a = (a.display_name or a.name):lower()
			local name_b = (b.display_name or b.name):lower()
			return name_a > name_b
		end)
	end

	local slider_grab_color = FXManagerUI.getStyleValue("colors.slider_grab", 0x3F7FBFFF)
	local slider_grab_active_color = FXManagerUI.getStyleValue("colors.slider_grab_active", 0x5F9FDFFF)

	local r_val = ((slider_grab_color >> 24) & 0xFF)
	local g_val = ((slider_grab_color >> 16) & 0xFF)
	local b_val = ((slider_grab_color >> 8) & 0xFF)
	local selection_color = (r_val << 24) | (g_val << 16) | (b_val << 8) | 0x99

	local r_hover = ((slider_grab_active_color >> 24) & 0xFF)
	local g_hover = ((slider_grab_active_color >> 16) & 0xFF)
	local b_hover = ((slider_grab_active_color >> 8) & 0xFF)
	local hover_color = (r_hover << 24) | (g_hover << 16) | (b_hover << 8) | 0xCC

	local active_color = (r_hover << 24) | (g_hover << 16) | (b_hover << 8) | 0xFF

	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Header(), selection_color)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_HeaderHovered(), hover_color)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_HeaderActive(), active_color)

	for i, plugin in ipairs(plugins) do
		FXManagerUI.r.ImGui_PushID(FXManagerUI.ctx, i)

		local star_icon = "★"
		local star_color
		if plugin.favorite then
			star_color = 0xFFCC00FF
		else
			star_color = 0x888888FF
		end

		FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Text(), star_color)
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, star_icon)
		FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx)

		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			local hover_color = plugin.favorite and 0xFFDD44FF or 0xAAAA00FF
			local cursor_x, cursor_y = FXManagerUI.r.ImGui_GetCursorScreenPos(FXManagerUI.ctx)
			local item_x_min, item_y_min = FXManagerUI.r.ImGui_GetItemRectMin(FXManagerUI.ctx)
			local item_x_max, item_y_max = FXManagerUI.r.ImGui_GetItemRectMax(FXManagerUI.ctx)
			local draw_list = FXManagerUI.r.ImGui_GetWindowDrawList(FXManagerUI.ctx)
			FXManagerUI.r.ImGui_DrawList_AddRectFilled(draw_list, item_x_min, item_y_min, item_x_max, item_y_max, hover_color & 0xFFFFFF44)

			if FXManagerUI.r.ImGui_IsMouseClicked(FXManagerUI.ctx, 0) then
				FXManagerUI.fxdatabase.toggleFavorite(plugin.name)
			end
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)

		local is_selected = FXManagerUI.core.state.fxdb_selected_plugins[plugin.name] == true
		local flags = FXManagerUI.r.ImGui_SelectableFlags_SpanAllColumns()
		local display_text = plugin.display_name or plugin.name

		if FXManagerUI.r.ImGui_Selectable(FXManagerUI.ctx, display_text .. "##sel", is_selected, flags) then
			local ctrl_down = FXManagerUI.r.ImGui_IsKeyDown(FXManagerUI.ctx, FXManagerUI.r.ImGui_Mod_Ctrl())
			local shift_down = FXManagerUI.r.ImGui_IsKeyDown(FXManagerUI.ctx, FXManagerUI.r.ImGui_Mod_Shift())

			if shift_down and FXManagerUI.core.state.fxdb_last_clicked_plugin then
				local start_idx = nil
				local end_idx = nil

				for idx, p in ipairs(plugins) do
					if p.name == FXManagerUI.core.state.fxdb_last_clicked_plugin then
						start_idx = idx
					end
					if p.name == plugin.name then
						end_idx = idx
					end
				end

				if start_idx and end_idx then
					if start_idx > end_idx then
						start_idx, end_idx = end_idx, start_idx
					end

					for idx = start_idx, end_idx do
						FXManagerUI.core.state.fxdb_selected_plugins[plugins[idx].name] = true
					end
				end
			elseif ctrl_down then
				FXManagerUI.core.state.fxdb_selected_plugins[plugin.name] = not is_selected
			else
				FXManagerUI.core.state.fxdb_selected_plugins = {}
				FXManagerUI.core.state.fxdb_selected_plugins[plugin.name] = true
			end

			FXManagerUI.core.state.fxdb_last_clicked_plugin = plugin.name
		end

		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			if FXManagerUI.r.ImGui_IsMouseDoubleClicked(FXManagerUI.ctx, 0) then
				local fx_name = FXManagerUI.fxmanager.buildFXName(plugin)
				local should_open = FXManagerUI.core.state.fxmanager_auto_open == true
				FXManagerUI.fxmanager.addFXByName(fx_name, should_open, true)
				if FXManagerUI.core.state.fxmanager_auto_close then
					FXManagerUI.core.state.show_fxmanager_window = false
				end
			end
			if FXManagerUI.r.ImGui_IsMouseReleased(FXManagerUI.ctx, 1) then
				FXManagerUI.r.ImGui_OpenPopup(FXManagerUI.ctx, "PluginListContextMenu")
			end
		end

		if FXManagerUI.r.ImGui_BeginPopup(FXManagerUI.ctx, "PluginListContextMenu") then
			if FXManagerUI.r.ImGui_MenuItem(FXManagerUI.ctx, "Insert FX at End") then
				local selected_plugins = {}
				for _, p in ipairs(plugins) do
					if FXManagerUI.core.state.fxdb_selected_plugins[p.name] then
						table.insert(selected_plugins, p)
					end
				end
				if #selected_plugins == 0 then
					table.insert(selected_plugins, plugin)
				end
				for _, p in ipairs(selected_plugins) do
					local fx_name = FXManagerUI.fxmanager.buildFXName(p)
					local should_open = FXManagerUI.core.state.fxmanager_auto_open == true
					FXManagerUI.fxmanager.addFXByName(fx_name, should_open, true)
				end
				if FXManagerUI.core.state.fxmanager_auto_close then
					FXManagerUI.core.state.show_fxmanager_window = false
				end
			end
			if FXManagerUI.r.ImGui_MenuItem(FXManagerUI.ctx, "Add to Favorites") then
				local selected_plugins = {}
				for _, p in ipairs(plugins) do
					if FXManagerUI.core.state.fxdb_selected_plugins[p.name] then
						table.insert(selected_plugins, p)
					end
				end
				if #selected_plugins == 0 then
					table.insert(selected_plugins, plugin)
				end
				for _, p in ipairs(selected_plugins) do
					if not FXManagerUI.fxdatabase.isFavorite(p.name) then
						FXManagerUI.fxdatabase.toggleFavorite(p.name)
					end
				end
			end
			if FXManagerUI.r.ImGui_MenuItem(FXManagerUI.ctx, "Remove from Favorites") then
				local selected_plugins = {}
				for _, p in ipairs(plugins) do
					if FXManagerUI.core.state.fxdb_selected_plugins[p.name] then
						table.insert(selected_plugins, p)
					end
				end
				if #selected_plugins == 0 then
					table.insert(selected_plugins, plugin)
				end
				for _, p in ipairs(selected_plugins) do
					if FXManagerUI.fxdatabase.isFavorite(p.name) then
						FXManagerUI.fxdatabase.toggleFavorite(p.name)
					end
				end
			end

			-- Check if current category is a custom folder
			local is_custom_folder = false
			local all_categories = FXManagerUI.fxdatabase.getAllCategories()
			for _, cat in ipairs(all_categories) do
				if cat.type == "custom" and cat.name == selected_category then
					is_custom_folder = true
					break
				end
			end

			if is_custom_folder then
				if FXManagerUI.r.ImGui_MenuItem(FXManagerUI.ctx, "Remove from Folder") then
					local selected_plugins = {}
					for _, p in ipairs(plugins) do
						if FXManagerUI.core.state.fxdb_selected_plugins[p.name] then
							table.insert(selected_plugins, p)
						end
					end
					if #selected_plugins == 0 then
						table.insert(selected_plugins, plugin)
					end
					for _, p in ipairs(selected_plugins) do
						FXManagerUI.fxdatabase.removePluginFromFolder(selected_category, p.name)
					end
				end
			end
			FXManagerUI.r.ImGui_EndPopup(FXManagerUI.ctx)
		end

		if FXManagerUI.r.ImGui_BeginDragDropSource(FXManagerUI.ctx) then
			if not is_selected then
				FXManagerUI.core.state.fxdb_selected_plugins = {}
				FXManagerUI.core.state.fxdb_selected_plugins[plugin.name] = true
			end
			local selected_plugins = {}
			for _, p in ipairs(plugins) do
				if FXManagerUI.core.state.fxdb_selected_plugins[p.name] then
					table.insert(selected_plugins, p)
				end
			end
			
			if #selected_plugins == 0 then
				table.insert(selected_plugins, plugin)
			end
			
			local drag_text = #selected_plugins == 1 and selected_plugins[1].display_name or (#selected_plugins .. " plugins")
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, drag_text)
			
			local payload_data = ""
			for idx, p in ipairs(selected_plugins) do
				if idx > 1 then payload_data = payload_data .. "|" end
				payload_data = payload_data .. p.name .. "::" .. p.type .. "::" .. (p.instrument and "1" or "0")
			end
			
			FXManagerUI.r.ImGui_SetDragDropPayload(FXManagerUI.ctx, "FX_ADD", payload_data)
			FXManagerUI.r.ImGui_EndDragDropSource(FXManagerUI.ctx)
		end

		FXManagerUI.r.ImGui_PopID(FXManagerUI.ctx)
	end

	FXManagerUI.r.ImGui_Dummy(FXManagerUI.ctx, 0, 20)
	if FXManagerUI.r.ImGui_BeginDragDropTarget(FXManagerUI.ctx) then
		local ret_add, payload_add = FXManagerUI.r.ImGui_AcceptDragDropPayload(FXManagerUI.ctx, "FX_ADD")
		if ret_add then
			local plugins_data = {}
			for plugin_str in payload_add:gmatch("[^|]+") do
				local name, ptype, is_inst = plugin_str:match("^(.-)::(.-)::(.-)$")
				if name and ptype then
					local plugin_info = {
						name = name,
						type = ptype,
						instrument = is_inst == "1"
					}
					table.insert(plugins_data, plugin_info)
				end
			end
			
			for _, p_info in ipairs(plugins_data) do
				local fx_name = FXManagerUI.fxmanager.buildFXName(p_info)
				local should_open = FXManagerUI.core.state.fxmanager_auto_open == true
				FXManagerUI.fxmanager.addFXByName(fx_name, should_open, true)
			end
		end
		FXManagerUI.r.ImGui_EndDragDropTarget(FXManagerUI.ctx)
	end

	FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx, 3)
end

function FXManagerUI.drawRandomFXInsertion(header_font)
	if not FXManagerUI.core.state.random_fx_count then
		FXManagerUI.core.state.random_fx_count = 3
	end
	if FXManagerUI.core.state.random_fx_favorites_only == nil then
		FXManagerUI.core.state.random_fx_favorites_only = false
	end
	if FXManagerUI.core.state.random_fx_from_displayed == nil then
		FXManagerUI.core.state.random_fx_from_displayed = false
	end

	if header_font and FXManagerUI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		FXManagerUI.r.ImGui_PushFont(FXManagerUI.ctx, header_font, 0)
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Random FX Insertion")
		FXManagerUI.r.ImGui_PopFont(FXManagerUI.ctx)
	else
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Random FX Insertion")
	end

	local content_width = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx)
	local item_spacing_x = FXManagerUI.getStyleValue("spacing.item_spacing_x", 6)
	local slider_width = content_width * 0.3
	local button_width = 120

	FXManagerUI.r.ImGui_SetNextItemWidth(FXManagerUI.ctx, slider_width)
	local changed, new_count = FXManagerUI.r.ImGui_SliderInt(FXManagerUI.ctx, "##randomfxcount", FXManagerUI.core.state.random_fx_count, 1, 10, "%d FX")
	if changed then
		FXManagerUI.core.state.random_fx_count = new_count
		if FXManagerUI.fxmanager.persistence then
			FXManagerUI.fxmanager.persistence.scheduleSave()
		end
	end

	FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx, 0, item_spacing_x)
	local checkbox_changed, checkbox_value = FXManagerUI.r.ImGui_Checkbox(FXManagerUI.ctx, "Favorites", FXManagerUI.core.state.random_fx_favorites_only)
	if checkbox_changed then
		FXManagerUI.core.state.random_fx_favorites_only = checkbox_value
		if FXManagerUI.fxmanager.persistence then
			FXManagerUI.fxmanager.persistence.scheduleSave()
		end
	end

	FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx, 0, item_spacing_x)
	local checkbox_changed2, checkbox_value2 = FXManagerUI.r.ImGui_Checkbox(FXManagerUI.ctx, "From Displayed", FXManagerUI.core.state.random_fx_from_displayed)
	if checkbox_changed2 then
		FXManagerUI.core.state.random_fx_from_displayed = checkbox_value2
		if FXManagerUI.fxmanager.persistence then
			FXManagerUI.fxmanager.persistence.scheduleSave()
		end
	end

	FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx, 0, item_spacing_x)
	if FXManagerUI.r.ImGui_Button(FXManagerUI.ctx, "Add Random FX", button_width) then
		local success
		if FXManagerUI.core.state.random_fx_from_displayed then
			local selected_category = FXManagerUI.core.state.fxdb_selected_category
			local search_query = FXManagerUI.core.state.fxdb_search_query
			local displayed_plugins = FXManagerUI.fxdatabase.searchPlugins(search_query, selected_category)

			if FXManagerUI.core.state.fxdb_sort_mode == "az" then
				table.sort(displayed_plugins, function(a, b)
					local name_a = (a.display_name or a.name):lower()
					local name_b = (b.display_name or b.name):lower()
					return name_a < name_b
				end)
			elseif FXManagerUI.core.state.fxdb_sort_mode == "za" then
				table.sort(displayed_plugins, function(a, b)
					local name_a = (a.display_name or a.name):lower()
					local name_b = (b.display_name or b.name):lower()
					return name_a > name_b
				end)
			end

			success = FXManagerUI.fxmanager.addRandomFXFromList(FXManagerUI.core.state.random_fx_count, displayed_plugins)
		else
			success = FXManagerUI.fxmanager.addRandomFX(FXManagerUI.core.state.random_fx_count, FXManagerUI.core.state.random_fx_favorites_only)
		end
		if success and FXManagerUI.core.state.fxmanager_auto_close then
			FXManagerUI.core.state.show_fxmanager_window = false
		end
	end
end

function FXManagerUI.drawFXChain(header_font)
	if header_font and FXManagerUI.r.ImGui_ValidatePtr(header_font, "ImGui_Font*") then
		FXManagerUI.r.ImGui_PushFont(FXManagerUI.ctx, header_font, 0)
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Track FX Chain")
		FXManagerUI.r.ImGui_PopFont(FXManagerUI.ctx)
	else
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Track FX Chain")
	end

	FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)
	local item_spacing_x = FXManagerUI.getStyleValue("spacing.item_spacing_x", 6)
	local window_width = FXManagerUI.r.ImGui_GetWindowWidth(FXManagerUI.ctx)
	local bypass_text_width = FXManagerUI.r.ImGui_CalcTextSize(FXManagerUI.ctx, "Bypass All")
	local clear_text_width = FXManagerUI.r.ImGui_CalcTextSize(FXManagerUI.ctx, "Clear")
	local cursor_x = window_width - bypass_text_width - clear_text_width - item_spacing_x * 4
	FXManagerUI.r.ImGui_SetCursorPosX(FXManagerUI.ctx, cursor_x)

	local text_color = 0xAAAAAAFF

	-- Bypass All button
	local bypass_text_pos_x, bypass_text_pos_y = FXManagerUI.r.ImGui_GetCursorScreenPos(FXManagerUI.ctx)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Text(), text_color)
	FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Bypass All")
	FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx)

	if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
		local item_x_min, item_y_min = FXManagerUI.r.ImGui_GetItemRectMin(FXManagerUI.ctx)
		local item_x_max, item_y_max = FXManagerUI.r.ImGui_GetItemRectMax(FXManagerUI.ctx)
		FXManagerUI.r.ImGui_SetCursorScreenPos(FXManagerUI.ctx, bypass_text_pos_x, bypass_text_pos_y)
		FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Text(), 0xFFFFFFFF)
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Bypass All")
		FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx)

		if FXManagerUI.r.ImGui_IsMouseClicked(FXManagerUI.ctx, 0) then
			if FXManagerUI.core.isTrackValid() then
				local track = FXManagerUI.core.state.track
				local fx_count = FXManagerUI.r.TrackFX_GetCount(track)
				FXManagerUI.r.Undo_BeginBlock()
				for fx_idx = 0, fx_count - 1 do
					local _, fx_name = FXManagerUI.r.TrackFX_GetFXName(track, fx_idx, "")
					local display_name = FXManagerUI.core.extractFXName(fx_name)
					if not (display_name:find("Sound Generator") or display_name:find("FX Constellation Bridge")) then
						FXManagerUI.r.TrackFX_SetEnabled(track, fx_idx, false)
					end
				end
				FXManagerUI.r.Undo_EndBlock("Bypass All FX", -1)
			end
		end
	end

	FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)

	-- Clear button
	local clear_text_pos_x, clear_text_pos_y = FXManagerUI.r.ImGui_GetCursorScreenPos(FXManagerUI.ctx)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Text(), text_color)
	FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Clear")
	FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx)

	if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
		local item_x_min, item_y_min = FXManagerUI.r.ImGui_GetItemRectMin(FXManagerUI.ctx)
		local item_x_max, item_y_max = FXManagerUI.r.ImGui_GetItemRectMax(FXManagerUI.ctx)
		FXManagerUI.r.ImGui_SetCursorScreenPos(FXManagerUI.ctx, clear_text_pos_x, clear_text_pos_y)
		FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Text(), 0xFFFFFFFF)
		FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, "Clear")
		FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx)

		if FXManagerUI.r.ImGui_IsMouseClicked(FXManagerUI.ctx, 0) then
			if FXManagerUI.core.isTrackValid() then
				local track = FXManagerUI.core.state.track
				local fx_count = FXManagerUI.r.TrackFX_GetCount(track)
				FXManagerUI.r.Undo_BeginBlock()
				for fx_idx = fx_count - 1, 0, -1 do
					local _, fx_name = FXManagerUI.r.TrackFX_GetFXName(track, fx_idx, "")
					local display_name = FXManagerUI.core.extractFXName(fx_name)
					if not (display_name:find("Sound Generator") or display_name:find("FX Constellation Bridge")) then
						FXManagerUI.r.TrackFX_Delete(track, fx_idx)
					end
				end
				FXManagerUI.r.Undo_EndBlock("Clear FX Chain", -1)
				FXManagerUI.core.state.fxchain_selected_fx = {}
			end
		end
	end

	FXManagerUI.r.ImGui_Separator(FXManagerUI.ctx)

	if not FXManagerUI.core.isTrackValid() then
		FXManagerUI.r.ImGui_TextDisabled(FXManagerUI.ctx, "No track selected")
		return
	end

	local track = FXManagerUI.core.state.track
	local fx_count = FXManagerUI.r.TrackFX_GetCount(track)

	if fx_count == 0 then
		FXManagerUI.r.ImGui_TextDisabled(FXManagerUI.ctx, "No FX on track")

		local available_width, available_height = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx)
		local drop_height = math.max(100, available_height)

		FXManagerUI.r.ImGui_Dummy(FXManagerUI.ctx, available_width, drop_height)

		if FXManagerUI.r.ImGui_BeginDragDropTarget(FXManagerUI.ctx) then
			local item_x_min, item_y_min = FXManagerUI.r.ImGui_GetItemRectMin(FXManagerUI.ctx)
			local item_x_max, item_y_max = FXManagerUI.r.ImGui_GetItemRectMax(FXManagerUI.ctx)

			FXManagerUI.core.state.fxchain_drag_target = 0
			FXManagerUI.core.state.fxchain_drag_y = item_y_min
			FXManagerUI.core.state.fxchain_drag_x_min = item_x_min
			FXManagerUI.core.state.fxchain_drag_x_max = item_x_max

			local ret_add, payload_add = FXManagerUI.r.ImGui_AcceptDragDropPayload(FXManagerUI.ctx, "FX_ADD")
			if ret_add then
				local plugins_data = {}
				for plugin_str in payload_add:gmatch("[^|]+") do
					local name, ptype, is_inst = plugin_str:match("^(.-)::(.-)::(.-)$")
					if name and ptype then
						local plugin_info = {
							name = name,
							type = ptype,
							instrument = is_inst == "1"
						}
						table.insert(plugins_data, plugin_info)
					end
				end

				for idx, p_info in ipairs(plugins_data) do
					local fx_name = FXManagerUI.fxmanager.buildFXName(p_info)
					local should_open = FXManagerUI.core.state.fxmanager_auto_open == true
					FXManagerUI.fxmanager.addFXByName(fx_name, should_open, true)
				end
				FXManagerUI.core.state.fxchain_drag_target = -1
			end
			FXManagerUI.r.ImGui_EndDragDropTarget(FXManagerUI.ctx)
		else
			FXManagerUI.core.state.fxchain_drag_target = -1
		end

		if FXManagerUI.core.state.fxchain_drag_target and FXManagerUI.core.state.fxchain_drag_target >= 0 then
			if FXManagerUI.core.state.fxchain_drag_y and FXManagerUI.core.state.fxchain_drag_x_min and FXManagerUI.core.state.fxchain_drag_x_max then
				local draw_list = FXManagerUI.r.ImGui_GetWindowDrawList(FXManagerUI.ctx)
				local y = FXManagerUI.core.state.fxchain_drag_y
				local x1 = FXManagerUI.core.state.fxchain_drag_x_min
				local x2 = FXManagerUI.core.state.fxchain_drag_x_max
				FXManagerUI.r.ImGui_DrawList_AddLine(draw_list, x1, y, x2, y, 0xFFFFFFFF, 2)
			end
		end

		return
	end

	local slider_grab_color = FXManagerUI.getStyleValue("colors.slider_grab", 0x3F7FBFFF)
	local slider_grab_active_color = FXManagerUI.getStyleValue("colors.slider_grab_active", 0x5F9FDFFF)

	local r_val = ((slider_grab_color >> 24) & 0xFF)
	local g_val = ((slider_grab_color >> 16) & 0xFF)
	local b_val = ((slider_grab_color >> 8) & 0xFF)
	local selection_color = (r_val << 24) | (g_val << 16) | (b_val << 8) | 0x99

	local r_hover = ((slider_grab_active_color >> 24) & 0xFF)
	local g_hover = ((slider_grab_active_color >> 16) & 0xFF)
	local b_hover = ((slider_grab_active_color >> 8) & 0xFF)
	local hover_color = (r_hover << 24) | (g_hover << 16) | (b_hover << 8) | 0xCC

	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Header(), selection_color)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_HeaderHovered(), hover_color)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_HeaderActive(), hover_color)
	FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_DragDropTarget(), 0x00000000)

	if not FXManagerUI.core.state.fxchain_drag_target then
		FXManagerUI.core.state.fxchain_drag_target = -1
	end

	for fx_idx = 0, fx_count - 1 do
		local _, fx_name = FXManagerUI.r.TrackFX_GetFXName(track, fx_idx, "")
		local display_name = FXManagerUI.core.extractFXName(fx_name)

		if display_name:find("Sound Generator") or display_name:find("FX Constellation Bridge") then
			goto continue
		end

		local is_enabled = FXManagerUI.r.TrackFX_GetEnabled(track, fx_idx)

		FXManagerUI.r.ImGui_PushID(FXManagerUI.ctx, fx_idx)

		local checkbox_changed, checkbox_value = FXManagerUI.r.ImGui_Checkbox(FXManagerUI.ctx, "##bypass", is_enabled)
		if checkbox_changed then
			FXManagerUI.r.TrackFX_SetEnabled(track, fx_idx, checkbox_value)
		end

		FXManagerUI.r.ImGui_SameLine(FXManagerUI.ctx)

		local item_text = (fx_idx + 1) .. ". " .. display_name

		if not FXManagerUI.core.state.fxchain_selected_fx then
			FXManagerUI.core.state.fxchain_selected_fx = {}
		end

		if not is_enabled then
			FXManagerUI.r.ImGui_PushStyleColor(FXManagerUI.ctx, FXManagerUI.r.ImGui_Col_Text(), 0xFF8855FF)
		end

		local is_selected = FXManagerUI.core.state.fxchain_selected_fx[fx_idx] == true
		local flags = FXManagerUI.r.ImGui_SelectableFlags_AllowDoubleClick()
		if FXManagerUI.r.ImGui_Selectable(FXManagerUI.ctx, item_text, is_selected, flags) then
			local ctrl_down = FXManagerUI.r.ImGui_IsKeyDown(FXManagerUI.ctx, FXManagerUI.r.ImGui_Mod_Ctrl())
			local shift_down = FXManagerUI.r.ImGui_IsKeyDown(FXManagerUI.ctx, FXManagerUI.r.ImGui_Mod_Shift())

			if FXManagerUI.r.ImGui_IsMouseDoubleClicked(FXManagerUI.ctx, 0) then
				FXManagerUI.r.TrackFX_Show(track, fx_idx, 3)
			elseif shift_down and FXManagerUI.core.state.fxchain_last_clicked_fx then
				local start_idx = FXManagerUI.core.state.fxchain_last_clicked_fx
				local end_idx = fx_idx
				if start_idx > end_idx then
					start_idx, end_idx = end_idx, start_idx
				end
				for idx = start_idx, end_idx do
					FXManagerUI.core.state.fxchain_selected_fx[idx] = true
				end
			elseif ctrl_down then
				FXManagerUI.core.state.fxchain_selected_fx[fx_idx] = not is_selected
			else
				FXManagerUI.core.state.fxchain_selected_fx = {}
				FXManagerUI.core.state.fxchain_selected_fx[fx_idx] = true
			end

			FXManagerUI.core.state.fxchain_last_clicked_fx = fx_idx
		end

		if not is_enabled then
			FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx)
		end

		if FXManagerUI.r.ImGui_IsItemHovered(FXManagerUI.ctx) then
			local alt_down = FXManagerUI.r.ImGui_IsKeyDown(FXManagerUI.ctx, FXManagerUI.r.ImGui_Mod_Alt())
			if alt_down and FXManagerUI.r.ImGui_IsMouseClicked(FXManagerUI.ctx, 0) then
				FXManagerUI.r.TrackFX_Delete(track, fx_idx)
				FXManagerUI.core.state.fxchain_selected_fx = {}
			elseif FXManagerUI.r.ImGui_IsMouseDown(FXManagerUI.ctx, 1) and not is_selected then
				FXManagerUI.core.state.fxchain_selected_fx = {}
				FXManagerUI.core.state.fxchain_selected_fx[fx_idx] = true
			end
			if FXManagerUI.r.ImGui_IsMouseReleased(FXManagerUI.ctx, 1) then
				FXManagerUI.r.ImGui_OpenPopup(FXManagerUI.ctx, "FXChainContextMenu")
			end
		end

		if FXManagerUI.r.ImGui_BeginPopup(FXManagerUI.ctx, "FXChainContextMenu") then
			if FXManagerUI.r.ImGui_MenuItem(FXManagerUI.ctx, "Delete Selected FX") then
				local indices_to_delete = {}
				for idx, selected in pairs(FXManagerUI.core.state.fxchain_selected_fx) do
					if selected then
						table.insert(indices_to_delete, idx)
					end
				end
				table.sort(indices_to_delete, function(a, b) return a > b end)
				for _, idx in ipairs(indices_to_delete) do
					FXManagerUI.r.TrackFX_Delete(track, idx)
				end
				FXManagerUI.core.state.fxchain_selected_fx = {}
			end
			FXManagerUI.r.ImGui_EndPopup(FXManagerUI.ctx)
		end

		if FXManagerUI.r.ImGui_BeginDragDropSource(FXManagerUI.ctx) then
			if not is_selected then
				FXManagerUI.core.state.fxchain_selected_fx = {}
				FXManagerUI.core.state.fxchain_selected_fx[fx_idx] = true
			end
			FXManagerUI.r.ImGui_SetDragDropPayload(FXManagerUI.ctx, "FX_REORDER", tostring(fx_idx))
			FXManagerUI.r.ImGui_Text(FXManagerUI.ctx, display_name)
			FXManagerUI.r.ImGui_EndDragDropSource(FXManagerUI.ctx)
		end

		local item_x_min, item_y_min = FXManagerUI.r.ImGui_GetItemRectMin(FXManagerUI.ctx)
		local item_x_max, item_y_max = FXManagerUI.r.ImGui_GetItemRectMax(FXManagerUI.ctx)
		local item_y_mid = item_y_min + (item_y_max - item_y_min) / 2

		if FXManagerUI.r.ImGui_BeginDragDropTarget(FXManagerUI.ctx) then
			local mouse_x, mouse_y = FXManagerUI.r.ImGui_GetMousePos(FXManagerUI.ctx)
			local insert_before = mouse_y < item_y_mid
			local target_pos = insert_before and fx_idx or (fx_idx + 1)

			FXManagerUI.core.state.fxchain_drag_target = target_pos
			FXManagerUI.core.state.fxchain_drag_y = insert_before and item_y_min or item_y_max
			FXManagerUI.core.state.fxchain_drag_x_min = item_x_min
			FXManagerUI.core.state.fxchain_drag_x_max = item_x_max

			local ret_add, payload_add = FXManagerUI.r.ImGui_AcceptDragDropPayload(FXManagerUI.ctx, "FX_ADD")
			if ret_add then
				local plugins_data = {}
				for plugin_str in payload_add:gmatch("[^|]+") do
					local name, ptype, is_inst = plugin_str:match("^(.-)::(.-)::(.-)$")
					if name and ptype then
						local plugin_info = {
							name = name,
							type = ptype,
							instrument = is_inst == "1"
						}
						table.insert(plugins_data, plugin_info)
					end
				end

				for _, p_info in ipairs(plugins_data) do
					local fx_name = FXManagerUI.fxmanager.buildFXName(p_info)
					local should_open = FXManagerUI.core.state.fxmanager_auto_open == true
					local recFX = false
					local insert_pos = -1000 - target_pos
					local fx_id = FXManagerUI.r.TrackFX_AddByName(track, fx_name, recFX, insert_pos)
					if fx_id >= 0 then
						if should_open then
							FXManagerUI.r.TrackFX_Show(track, fx_id, 3)
						else
							FXManagerUI.r.TrackFX_Show(track, fx_id, 2)
						end
					end
				end
				FXManagerUI.core.state.fxchain_drag_target = -1
			end

			local ret_reorder, payload_reorder = FXManagerUI.r.ImGui_AcceptDragDropPayload(FXManagerUI.ctx, "FX_REORDER")
			if ret_reorder then
				local source_fx = tonumber(payload_reorder)
				if source_fx and source_fx ~= target_pos then
					FXManagerUI.r.TrackFX_CopyToTrack(track, source_fx, track, target_pos, true)
				end
				FXManagerUI.core.state.fxchain_drag_target = -1
			end

			FXManagerUI.r.ImGui_EndDragDropTarget(FXManagerUI.ctx)
		else
			FXManagerUI.core.state.fxchain_drag_target = -1
		end


		FXManagerUI.r.ImGui_PopID(FXManagerUI.ctx)
		::continue::
	end

	local available_width, available_height = FXManagerUI.r.ImGui_GetContentRegionAvail(FXManagerUI.ctx)
	local drop_height = math.max(100, available_height)

	FXManagerUI.r.ImGui_Dummy(FXManagerUI.ctx, available_width, drop_height)

	if FXManagerUI.r.ImGui_BeginDragDropTarget(FXManagerUI.ctx) then
		local item_x_min, item_y_min = FXManagerUI.r.ImGui_GetItemRectMin(FXManagerUI.ctx)
		local item_x_max, item_y_max = FXManagerUI.r.ImGui_GetItemRectMax(FXManagerUI.ctx)

		FXManagerUI.core.state.fxchain_drag_target = fx_count
		FXManagerUI.core.state.fxchain_drag_y = item_y_min
		FXManagerUI.core.state.fxchain_drag_x_min = item_x_min
		FXManagerUI.core.state.fxchain_drag_x_max = item_x_max
		local ret_add, payload_add = FXManagerUI.r.ImGui_AcceptDragDropPayload(FXManagerUI.ctx, "FX_ADD")
		if ret_add then
			local plugins_data = {}
			for plugin_str in payload_add:gmatch("[^|]+") do
				local name, ptype, is_inst = plugin_str:match("^(.-)::(.-)::(.-)$")
				if name and ptype then
					local plugin_info = {
						name = name,
						type = ptype,
						instrument = is_inst == "1"
					}
					table.insert(plugins_data, plugin_info)
				end
			end

			for _, p_info in ipairs(plugins_data) do
				local fx_name = FXManagerUI.fxmanager.buildFXName(p_info)
				local should_open = FXManagerUI.core.state.fxmanager_auto_open == true
				local recFX = false
				local insert_pos = -1000 - fx_count
				local fx_id = FXManagerUI.r.TrackFX_AddByName(track, fx_name, recFX, insert_pos)
				if fx_id >= 0 then
					if should_open then
						FXManagerUI.r.TrackFX_Show(track, fx_id, 3)
					else
						FXManagerUI.r.TrackFX_Show(track, fx_id, 2)
					end
				end
			end
			FXManagerUI.core.state.fxchain_drag_target = -1
		end
		FXManagerUI.r.ImGui_EndDragDropTarget(FXManagerUI.ctx)
	else
		FXManagerUI.core.state.fxchain_drag_target = -1
	end

	if FXManagerUI.core.state.fxchain_drag_target and FXManagerUI.core.state.fxchain_drag_target >= 0 then
		if FXManagerUI.core.state.fxchain_drag_y and FXManagerUI.core.state.fxchain_drag_x_min and FXManagerUI.core.state.fxchain_drag_x_max then
			local draw_list = FXManagerUI.r.ImGui_GetWindowDrawList(FXManagerUI.ctx)
			local y = FXManagerUI.core.state.fxchain_drag_y
			local x1 = FXManagerUI.core.state.fxchain_drag_x_min
			local x2 = FXManagerUI.core.state.fxchain_drag_x_max
			FXManagerUI.r.ImGui_DrawList_AddLine(draw_list, x1, y, x2, y, 0xFFFFFFFF, 2)
		end
	end

	FXManagerUI.r.ImGui_PopStyleColor(FXManagerUI.ctx, 4)
end

return FXManagerUI
