-- @description ProjectNoteEditor
-- @version 1.0
-- @author Cedric Pamalio

local r = reaper
local config = {
	current_font = "Verdana",
	current_size = 16,
	bg_color = 0x1a1a1a,
	text_color = 0xe6e6e6,
	button_color = 0x333333,
	button_hover_color = 0x4d4d4d,
	button_active_color = 0x666666,
	editor_bg_color = 0x1a1a1a,
	editor_border_color = 0x808080,
	selection_color = 0x3874cb,
	window_x = 100,
	window_y = 100,
	window_w = 600,
	window_h = 400,
}

local tracked_project = nil
local tracked_project_name = ""
local last_notes_content = ""
local scroll_y = 0
local line_height = 20
local last_mouse_cap = 0
local text_cursor_pos = 0
local text_focus = false
local total_text_height = 0
local blink_time = 0
local need_save = false
local selection_start = nil
local selection_end = nil
local context_menu_open = false
local context_menu_x = 0
local context_menu_y = 0
local context_menu_clicked = false
local dragging = false
local wrapped_lines = {}
local char_to_line = {}
local static_last_check = 0

local undo_stack = {}
local redo_stack = {}
local max_undo_levels = 50

local last_click_time = 0
local click_count = 0
local last_click_x = 0
local last_click_y = 0

local search_active = false
local search_text = ""
local search_cursor = 0

function LoadSettings()
	local saved_bg = tonumber(r.GetExtState("CP_ProjectNoteEditor", "bg_color"))
	local saved_text = tonumber(r.GetExtState("CP_ProjectNoteEditor", "text_color"))
	local saved_button = tonumber(r.GetExtState("CP_ProjectNoteEditor", "button_color"))
	local saved_button_hover = tonumber(r.GetExtState("CP_ProjectNoteEditor", "button_hover_color"))
	local saved_button_active = tonumber(r.GetExtState("CP_ProjectNoteEditor", "button_active_color"))
	local saved_editor_bg = tonumber(r.GetExtState("CP_ProjectNoteEditor", "editor_bg_color"))
	local saved_editor_border = tonumber(r.GetExtState("CP_ProjectNoteEditor", "editor_border_color"))
	local saved_selection = tonumber(r.GetExtState("CP_ProjectNoteEditor", "selection_color"))
	if saved_bg then config.bg_color = saved_bg end
	if saved_text then config.text_color = saved_text end
	if saved_button then config.button_color = saved_button end
	if saved_button_hover then config.button_hover_color = saved_button_hover end
	if saved_button_active then config.button_active_color = saved_button_active end
	if saved_editor_bg then config.editor_bg_color = saved_editor_bg end
	if saved_editor_border then config.editor_border_color = saved_editor_border end
	if saved_selection then config.selection_color = saved_selection end
	local saved_x = tonumber(r.GetExtState("CP_ProjectNoteEditor", "window_x"))
	local saved_y = tonumber(r.GetExtState("CP_ProjectNoteEditor", "window_y"))
	local saved_w = tonumber(r.GetExtState("CP_ProjectNoteEditor", "window_w"))
	local saved_h = tonumber(r.GetExtState("CP_ProjectNoteEditor", "window_h"))
	if saved_x and saved_x > 0 then config.window_x = saved_x end
	if saved_y and saved_y > 0 then config.window_y = saved_y end
	if saved_w and saved_w > 100 then config.window_w = saved_w end
	if saved_h and saved_h > 100 then config.window_h = saved_h end
end

function CheckColorUpdate()
	local current_time = r.time_precise()
	if current_time - static_last_check > 0.2 then
		LoadSettings()
		static_last_check = current_time
	end
end

function SaveSettings()
	r.SetExtState("CP_ProjectNoteEditor", "bg_color", tostring(config.bg_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "text_color", tostring(config.text_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "button_color", tostring(config.button_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "button_hover_color", tostring(config.button_hover_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "button_active_color", tostring(config.button_active_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "editor_bg_color", tostring(config.editor_bg_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "editor_border_color", tostring(config.editor_border_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "selection_color", tostring(config.selection_color), true)
	r.SetExtState("CP_ProjectNoteEditor", "window_x", tostring(config.window_x), true)
	r.SetExtState("CP_ProjectNoteEditor", "window_y", tostring(config.window_y), true)
	r.SetExtState("CP_ProjectNoteEditor", "window_w", tostring(config.window_w), true)
	r.SetExtState("CP_ProjectNoteEditor", "window_h", tostring(config.window_h), true)
	local dock = gfx.dock(-1)
	r.SetExtState("CP_ProjectNoteEditor", "dock_state", tostring(dock), true)
end

function GetProjectName(proj)
	local project_index = -1
	if proj then
		local i = 0
		while true do
			local p = r.EnumProjects(i)
			if not p then break end
			if p == proj then
				project_index = i
				break
			end
			i = i + 1
		end
	end
	local _, project_path = r.EnumProjects(project_index)
	if not project_path or project_path == "" then
		return "Untitled Project"
	end
	local name = project_path:match("([^\\/]+)%.RPP$") or project_path:match("([^\\/]+)%.rpp$")
	return name or "Untitled Project"
end

function LoadProjectNotes(proj)
	if not proj then return "" end
	local retval, notes = r.GetProjExtState(proj, "REAPER_PROJECT_NOTES", "notes")
	if retval == 0 then
		retval, notes = r.GetSetProjectNotes(proj, false, "")
	end
	return notes or ""
end

function SaveProjectNotes(proj, notes)
	if not proj then return end
	r.GetSetProjectNotes(proj, true, notes)
	r.SetProjExtState(proj, "REAPER_PROJECT_NOTES", "notes", notes)
end

function CheckProjectChange()
	local current_proj = r.EnumProjects(-1)
	if current_proj ~= tracked_project then
		if tracked_project and last_notes_content ~= "" and need_save then
			SaveProjectNotes(tracked_project, last_notes_content)
			need_save = false
		end
		tracked_project = current_proj
		tracked_project_name = GetProjectName(tracked_project)
		last_notes_content = LoadProjectNotes(tracked_project)
		scroll_y = 0
		text_cursor_pos = 0
		selection_start = nil
		selection_end = nil
		undo_stack = {}
		redo_stack = {}
		return true
	end
	return false
end

function ColorToGfx(color)
	local red = ((color >> 16) & 0xFF) / 255
	local green = ((color >> 8) & 0xFF) / 255
	local blue = (color & 0xFF) / 255
	return red, green, blue
end

function SaveUndoState()
	table.insert(undo_stack, {
		content = last_notes_content,
		cursor = text_cursor_pos,
		sel_start = selection_start,
		sel_end = selection_end
	})
	if #undo_stack > max_undo_levels then
		table.remove(undo_stack, 1)
	end
	redo_stack = {}
end

function Undo()
	if #undo_stack > 0 then
		table.insert(redo_stack, {
			content = last_notes_content,
			cursor = text_cursor_pos,
			sel_start = selection_start,
			sel_end = selection_end
		})
		local state = table.remove(undo_stack)
		last_notes_content = state.content
		text_cursor_pos = state.cursor
		selection_start = state.sel_start
		selection_end = state.sel_end
		need_save = true
	end
end

function Redo()
	if #redo_stack > 0 then
		table.insert(undo_stack, {
			content = last_notes_content,
			cursor = text_cursor_pos,
			sel_start = selection_start,
			sel_end = selection_end
		})
		local state = table.remove(redo_stack)
		last_notes_content = state.content
		text_cursor_pos = state.cursor
		selection_start = state.sel_start
		selection_end = state.sel_end
		need_save = true
	end
end

function IsWordBoundary(char)
	return char:match("%s") or char:match("[%p%c]")
end

function WrapText(text, max_width)
	wrapped_lines = {}
	char_to_line = {}
	if not text or text == "" then
		table.insert(wrapped_lines, "")
		char_to_line[1] = 1
		return wrapped_lines
	end

	local current_line = ""
	local current_line_start = 1
	local line_num = 1
	local i = 1

	while i <= #text do
		local char = text:sub(i, i)
		char_to_line[i] = line_num

		if char == "\n" then
			table.insert(wrapped_lines, current_line)
			current_line = ""
			current_line_start = i + 1
			line_num = line_num + 1
			i = i + 1
		else
			local test_line = current_line .. char
			local w = gfx.measurestr(test_line)
			if w > max_width and current_line ~= "" then
				local break_point = nil
				local j = #current_line
				while j > 0 do
					local test_char = current_line:sub(j, j)
					if IsWordBoundary(test_char) then
						break_point = j
						break
					end
					j = j - 1
				end
				if break_point and break_point > 1 then
					local line_part = current_line:sub(1, break_point)
					table.insert(wrapped_lines, line_part)
					for k = current_line_start, current_line_start + break_point - 1 do
						char_to_line[k] = line_num
					end
					current_line = current_line:sub(break_point + 1) .. char
					current_line_start = current_line_start + break_point
					line_num = line_num + 1
					char_to_line[i] = line_num
				else
					table.insert(wrapped_lines, current_line)
					for k = current_line_start, i - 1 do
						char_to_line[k] = line_num
					end
					current_line = char
					current_line_start = i
					line_num = line_num + 1
					char_to_line[i] = line_num
				end
			else
				current_line = test_line
			end
			i = i + 1
		end
	end

	if current_line ~= "" then
		table.insert(wrapped_lines, current_line)
		for j = current_line_start, #text do
			char_to_line[j] = line_num
		end
	end

	char_to_line[#text + 1] = line_num
	return wrapped_lines
end

function GetCharFromClick(click_x, click_y, editor_x, editor_y, margin)
	local line_idx = math.floor((click_y - editor_y - margin + scroll_y) / line_height) + 1
	line_idx = math.max(1, math.min(line_idx, #wrapped_lines))
	if #wrapped_lines == 0 then return 0 end

	for char_pos = 1, #last_notes_content + 1 do
		if char_to_line[char_pos] == line_idx then
			local line_start_char = char_pos
			local line_end_char = char_pos
			for j = char_pos, #last_notes_content + 1 do
				if char_to_line[j] == line_idx then
					line_end_char = j
				else
					break
				end
			end
			local line_text = wrapped_lines[line_idx] or ""
			local click_offset = click_x - editor_x - margin
			local best_char = line_start_char - 1
			for i = 1, #line_text do
				local w = gfx.measurestr(line_text:sub(1, i))
				if w > click_offset then break end
				best_char = line_start_char + i - 1
			end
			return math.min(best_char, #last_notes_content)
		end
	end
	return #last_notes_content
end

function GetCursorScreenPos(char_pos, editor_x, editor_y, margin)
	char_pos = math.max(0, math.min(char_pos, #last_notes_content))
	local line_idx = char_to_line[char_pos + 1] or 1
	if line_idx == 0 then line_idx = 1 end

	local line_start_char = 1
	for i = 1, #last_notes_content + 1 do
		if char_to_line[i] == line_idx then
			line_start_char = i
			break
		end
	end

	local char_in_line = char_pos - line_start_char + 1
	local line_text = wrapped_lines[line_idx] or ""
	char_in_line = math.max(0, math.min(char_in_line, #line_text))

	local cursor_text = line_text:sub(1, char_in_line)
	local cursor_w = gfx.measurestr(cursor_text)
	local cursor_x = editor_x + margin + cursor_w
	local cursor_y = editor_y + margin + (line_idx - 1) * line_height - scroll_y
	return cursor_x, cursor_y
end

function MoveCursorLeft(extend_selection)
	if text_cursor_pos > 0 then
		text_cursor_pos = text_cursor_pos - 1
		if extend_selection then
			if not selection_start then selection_start = text_cursor_pos + 1 end
			selection_end = text_cursor_pos
		else
			selection_start = nil
			selection_end = nil
		end
		EnsureCursorVisible()
	end
end

function MoveCursorRight(extend_selection)
	if text_cursor_pos < #last_notes_content then
		text_cursor_pos = text_cursor_pos + 1
		if extend_selection then
			if not selection_start then selection_start = text_cursor_pos - 1 end
			selection_end = text_cursor_pos
		else
			selection_start = nil
			selection_end = nil
		end
		EnsureCursorVisible()
	end
end

function MoveCursorUp(extend_selection)
	local current_line = char_to_line[text_cursor_pos + 1] or 1
	if current_line > 1 then
		local cursor_x, _ = GetCursorScreenPos(text_cursor_pos, 0, 0, 0)
		local new_line = current_line - 1
		local new_pos = GetCharFromClick(cursor_x, 0 + (new_line - 1) * line_height, 0, 0, 0)
		text_cursor_pos = new_pos
		if extend_selection then
			if not selection_start then selection_start = text_cursor_pos end
			selection_end = text_cursor_pos
		else
			selection_start = nil
			selection_end = nil
		end
		EnsureCursorVisible()
	end
end

function MoveCursorDown(extend_selection)
	local current_line = char_to_line[text_cursor_pos + 1] or 1
	if current_line < #wrapped_lines then
		local cursor_x, _ = GetCursorScreenPos(text_cursor_pos, 0, 0, 0)
		local new_line = current_line + 1
		local new_pos = GetCharFromClick(cursor_x, 0 + (new_line - 1) * line_height, 0, 0, 0)
		text_cursor_pos = new_pos
		if extend_selection then
			if not selection_start then selection_start = text_cursor_pos end
			selection_end = text_cursor_pos
		else
			selection_start = nil
			selection_end = nil
		end
		EnsureCursorVisible()
	end
end

function MoveCursorHome(extend_selection)
	local current_line = char_to_line[text_cursor_pos + 1] or 1
	for i = 0, #last_notes_content do
		if char_to_line[i + 1] == current_line then
			text_cursor_pos = i
			if extend_selection then
				if not selection_start then selection_start = text_cursor_pos end
				selection_end = text_cursor_pos
			else
				selection_start = nil
				selection_end = nil
			end
			EnsureCursorVisible()
			break
		end
	end
end

function MoveCursorEnd(extend_selection)
	local current_line = char_to_line[text_cursor_pos + 1] or 1
	for i = #last_notes_content, 0, -1 do
		if char_to_line[i + 1] == current_line then
			text_cursor_pos = i
			if extend_selection then
				if not selection_start then selection_start = text_cursor_pos end
				selection_end = text_cursor_pos
			else
				selection_start = nil
				selection_end = nil
			end
			EnsureCursorVisible()
			break
		end
	end
end

function MoveCursorPageUp(extend_selection)
	local visible_lines = math.floor((gfx.h - 80) / line_height)
	local current_line = char_to_line[text_cursor_pos + 1] or 1
	local new_line = math.max(1, current_line - visible_lines)
	local cursor_x, _ = GetCursorScreenPos(text_cursor_pos, 0, 0, 0)
	local new_pos = GetCharFromClick(cursor_x, 0 + (new_line - 1) * line_height, 0, 0, 0)
	text_cursor_pos = new_pos
	if extend_selection then
		if not selection_start then selection_start = text_cursor_pos end
		selection_end = text_cursor_pos
	else
		selection_start = nil
		selection_end = nil
	end
	EnsureCursorVisible()
end

function MoveCursorPageDown(extend_selection)
	local visible_lines = math.floor((gfx.h - 80) / line_height)
	local current_line = char_to_line[text_cursor_pos + 1] or 1
	local new_line = math.min(#wrapped_lines, current_line + visible_lines)
	local cursor_x, _ = GetCursorScreenPos(text_cursor_pos, 0, 0, 0)
	local new_pos = GetCharFromClick(cursor_x, 0 + (new_line - 1) * line_height, 0, 0, 0)
	text_cursor_pos = new_pos
	if extend_selection then
		if not selection_start then selection_start = text_cursor_pos end
		selection_end = text_cursor_pos
	else
		selection_start = nil
		selection_end = nil
	end
	EnsureCursorVisible()
end

function MoveCursorWordLeft(extend_selection)
	local pos = text_cursor_pos
	while pos > 0 and last_notes_content:sub(pos, pos):match("%s") do
		pos = pos - 1
	end
	while pos > 0 and not last_notes_content:sub(pos, pos):match("%s") do
		pos = pos - 1
	end
	text_cursor_pos = pos
	if extend_selection then
		if not selection_start then selection_start = text_cursor_pos end
		selection_end = text_cursor_pos
	else
		selection_start = nil
		selection_end = nil
	end
	EnsureCursorVisible()
end

function MoveCursorWordRight(extend_selection)
	local pos = text_cursor_pos + 1
	while pos <= #last_notes_content and not last_notes_content:sub(pos, pos):match("%s") do
		pos = pos + 1
	end
	while pos <= #last_notes_content and last_notes_content:sub(pos, pos):match("%s") do
		pos = pos + 1
	end
	text_cursor_pos = math.min(pos - 1, #last_notes_content)
	if extend_selection then
		if not selection_start then selection_start = text_cursor_pos end
		selection_end = text_cursor_pos
	else
		selection_start = nil
		selection_end = nil
	end
	EnsureCursorVisible()
end

function EnsureCursorVisible()
	local editor_h = gfx.h - 80
	local margin = 10
	local cursor_line = char_to_line[text_cursor_pos + 1] or 1
	local cursor_y = (cursor_line - 1) * line_height
	local visible_top = scroll_y
	local visible_bottom = scroll_y + editor_h - margin * 2
	if cursor_y < visible_top then
		scroll_y = cursor_y - line_height
	elseif cursor_y + line_height > visible_bottom then
		scroll_y = cursor_y + line_height - (editor_h - margin * 2)
	end
	scroll_y = math.max(0, scroll_y)
end

function SelectWord()
	local pos = text_cursor_pos
	local start_pos = pos
	local end_pos = pos
	while start_pos > 0 and not last_notes_content:sub(start_pos, start_pos):match("%s") do
		start_pos = start_pos - 1
	end
	while end_pos < #last_notes_content and not last_notes_content:sub(end_pos + 1, end_pos + 1):match("%s") do
		end_pos = end_pos + 1
	end
	if start_pos < end_pos then
		selection_start = start_pos
		selection_end = end_pos
		text_cursor_pos = end_pos
	end
end

function SelectLine()
	local current_line = char_to_line[text_cursor_pos + 1] or 1
	local start_pos = 0
	local end_pos = #last_notes_content
	for i = 0, #last_notes_content do
		if char_to_line[i + 1] == current_line then
			start_pos = i
			break
		end
	end
	for i = #last_notes_content, 0, -1 do
		if char_to_line[i + 1] == current_line then
			end_pos = i
			break
		end
	end
	selection_start = start_pos
	selection_end = end_pos
	text_cursor_pos = end_pos
end

function DrawButton(x, y, w, h, text, active)
	local mx, my = gfx.mouse_x, gfx.mouse_y
	local hover = mx >= x and mx <= x + w and my >= y and my <= y + h
	local clicked = hover and (gfx.mouse_cap & 1) == 1 and (last_mouse_cap & 1) == 0
	local red, green, blue
	if active then
		red, green, blue = ColorToGfx(config.button_active_color)
	elseif hover then
		red, green, blue = ColorToGfx(config.button_hover_color)
	else
		red, green, blue = ColorToGfx(config.button_color)
	end
	gfx.set(red, green, blue)
	gfx.rect(x, y, w, h, 1)
	red, green, blue = ColorToGfx(config.editor_border_color)
	gfx.set(red, green, blue)
	gfx.rect(x, y, w, h, 0)
	local tw, th = gfx.measurestr(text)
	red, green, blue = ColorToGfx(config.text_color)
	gfx.set(red, green, blue)
	gfx.x = x + (w - tw) / 2
	gfx.y = y + (h - th) / 2
	gfx.drawstr(text)
	return clicked
end

function CopyToClipboard()
	if selection_start and selection_end and selection_start ~= selection_end then
		local start_pos = math.min(selection_start, selection_end)
		local end_pos = math.max(selection_start, selection_end)
		local selected_text = last_notes_content:sub(start_pos + 1, end_pos)
		if r.CF_SetClipboard then
			r.CF_SetClipboard(selected_text)
		else
			r.ShowMessageBox("CF_SetClipboard not available - install js_ReaScriptAPI", "Error", 0)
		end
	end
end

function CutToClipboard()
	if selection_start and selection_end and selection_start ~= selection_end then
		SaveUndoState()
		CopyToClipboard()
		local start_pos = math.min(selection_start, selection_end)
		local end_pos = math.max(selection_start, selection_end)
		last_notes_content = last_notes_content:sub(1, start_pos) .. last_notes_content:sub(end_pos + 1)
		text_cursor_pos = start_pos
		selection_start = nil
		selection_end = nil
		need_save = true
	end
end

function PasteFromClipboard()
	local clipboard = ""
	if r.CF_GetClipboard then
		clipboard = r.CF_GetClipboard("")
	else
		r.ShowMessageBox("CF_GetClipboard not available - install js_ReaScriptAPI", "Error", 0)
		return
	end
	if clipboard and clipboard ~= "" then
		SaveUndoState()
		if selection_start and selection_end and selection_start ~= selection_end then
			local start_pos = math.min(selection_start, selection_end)
			local end_pos = math.max(selection_start, selection_end)
			last_notes_content = last_notes_content:sub(1, start_pos) .. clipboard .. last_notes_content:sub(end_pos + 1)
			text_cursor_pos = start_pos + #clipboard
			selection_start = nil
			selection_end = nil
		else
			last_notes_content = last_notes_content:sub(1, text_cursor_pos) ..
			clipboard .. last_notes_content:sub(text_cursor_pos + 1)
			text_cursor_pos = text_cursor_pos + #clipboard
		end
		need_save = true
	end
end

function SelectAll()
	if #last_notes_content > 0 then
		selection_start = 0
		selection_end = #last_notes_content
	end
end

function FindText()
	local retval, input = r.GetUserInputs("Find", 1, "Search for:", search_text)
	if retval then
		search_text = input
		if search_text ~= "" then
			local lower_text = last_notes_content:lower()
			local lower_search = search_text:lower()
			local found_pos = lower_text:find(lower_search, text_cursor_pos + 2, true)
			if not found_pos then
				found_pos = lower_text:find(lower_search, 1, true)
			end
			if found_pos then
				text_cursor_pos = found_pos - 1
				selection_start = found_pos - 1
				selection_end = found_pos + #search_text - 1
				EnsureCursorVisible()
			else
				r.ShowMessageBox("Text not found", "Find", 0)
			end
		end
	end
end

function DrawContextMenu(x, y)
	local menu_items = { "Copy", "Cut", "Paste", "", "Select All" }
	local item_h = 20
	local menu_w = 100
	local menu_h = #menu_items * item_h
	local red, green, blue = ColorToGfx(config.editor_bg_color)
	gfx.set(red, green, blue)
	gfx.rect(x, y, menu_w, menu_h, 1)
	red, green, blue = ColorToGfx(config.editor_border_color)
	gfx.set(red, green, blue)
	gfx.rect(x, y, menu_w, menu_h, 0)
	gfx.set(0.1, 0.1, 0.1, 0.5)
	gfx.rect(x + 2, y + 2, menu_w, menu_h, 1)
	local mx, my = gfx.mouse_x, gfx.mouse_y
	local clicked_item = nil

	for i, item in ipairs(menu_items) do
		local item_y = y + (i - 1) * item_h
		if item ~= "" then
			local hover = mx >= x and mx <= x + menu_w and my >= item_y and my <= item_y + item_h
			if hover then
				gfx.set(0.3, 0.3, 0.7)
				gfx.rect(x + 1, item_y + 1, menu_w - 2, item_h - 1, 1)
			end
			red, green, blue = ColorToGfx(config.text_color)
			gfx.set(red, green, blue)
			gfx.x = x + 10
			gfx.y = item_y + (item_h - 12) / 2
			gfx.drawstr(item)
			if hover and (gfx.mouse_cap & 1) == 1 and (last_mouse_cap & 1) == 0 then
				clicked_item = item
			end
		else
			red, green, blue = ColorToGfx(config.editor_border_color)
			gfx.set(red, green, blue)
			gfx.line(x + 8, item_y + item_h / 2, x + menu_w - 8, item_y + item_h / 2)
		end
	end

	local in_menu = mx >= x and mx <= x + menu_w and my >= y and my <= y + menu_h
	if (gfx.mouse_cap & 1) == 1 and not in_menu then
		context_menu_open = false
	end

	if clicked_item then
		context_menu_open = false
		if clicked_item == "Copy" then
			CopyToClipboard()
		elseif clicked_item == "Cut" then
			CutToClipboard()
		elseif clicked_item == "Paste" then
			PasteFromClipboard()
		elseif clicked_item == "Select All" then
			SelectAll()
		end
	end
end

function DrawTextEditor(x, y, w, h, text)
	local red, green, blue = ColorToGfx(config.editor_bg_color)
	gfx.set(red, green, blue)
	gfx.rect(x, y, w, h, 1)
	red, green, blue = ColorToGfx(config.editor_border_color)
	gfx.set(red, green, blue)
	gfx.rect(x, y, w, h, 0)
	local margin = 10
	local scrollbar_width = 16
	local text_width = w - margin * 2 - scrollbar_width - 5
	local lines = WrapText(text, text_width)
	total_text_height = #lines * line_height
	local max_scroll = math.max(0, total_text_height - (h - margin * 2))
	local mx, my = gfx.mouse_x, gfx.mouse_y
	local in_editor = mx >= x and mx <= x + w - scrollbar_width and my >= y and my <= y + h
	local in_scrollbar = mx >= x + w - scrollbar_width and mx <= x + w and my >= y and my <= y + h
	local extended_area = mx >= x - 50 and mx <= x + w + 50 and my >= y - 50 and my <= y + h + 50

	if in_editor then
		if (gfx.mouse_cap & 2) == 2 and (last_mouse_cap & 2) == 0 then
			context_menu_open = true
			context_menu_x = mx
			context_menu_y = my
		elseif (gfx.mouse_cap & 1) == 1 and (last_mouse_cap & 1) == 0 then
			context_menu_open = false
			text_focus = true
			local current_time = r.time_precise()
			local dx = math.abs(mx - last_click_x)
			local dy = math.abs(my - last_click_y)
			if current_time - last_click_time < 0.5 and dx < 5 and dy < 5 then
				click_count = click_count + 1
			else
				click_count = 1
			end
			last_click_time = current_time
			last_click_x = mx
			last_click_y = my
			if click_count == 1 then
				dragging = true
				local new_pos = GetCharFromClick(mx, my, x, y, margin)
				text_cursor_pos = math.max(0, math.min(new_pos, #text))
				selection_start = text_cursor_pos
				selection_end = text_cursor_pos
			elseif click_count == 2 then
				SelectWord()
				dragging = false
			elseif click_count >= 3 then
				SelectLine()
				dragging = false
				click_count = 0
			end
		end
	elseif extended_area and dragging and (gfx.mouse_cap & 1) == 1 then
		local clamped_x = math.max(x + margin, math.min(mx, x + w - scrollbar_width - margin))
		local clamped_y = math.max(y + margin, math.min(my, y + h - margin))
		local new_pos = GetCharFromClick(clamped_x, clamped_y, x, y, margin)
		new_pos = math.max(0, math.min(new_pos, #text))
		selection_end = new_pos
		text_cursor_pos = new_pos
	end

	if in_editor and dragging and (gfx.mouse_cap & 1) == 1 then
		local new_pos = GetCharFromClick(mx, my, x, y, margin)
		new_pos = math.max(0, math.min(new_pos, #text))
		selection_end = new_pos
		text_cursor_pos = new_pos
	elseif (gfx.mouse_cap & 1) == 0 then
		dragging = false
	end

	if in_editor and gfx.mouse_wheel ~= 0 then
		local scroll_amount = line_height * 2
		scroll_y = scroll_y - gfx.mouse_wheel * scroll_amount
		scroll_y = math.max(0, math.min(scroll_y, max_scroll))
		gfx.mouse_wheel = 0
	end

	if not in_editor and not in_scrollbar and not context_menu_open and (gfx.mouse_cap & 1) == 1 and (last_mouse_cap & 1) == 0 then
		text_focus = false
		context_menu_open = false
		dragging = false
	end

	if in_scrollbar and (gfx.mouse_cap & 1) == 1 then
		local scroll_ratio = (my - y) / h
		scroll_y = scroll_ratio * max_scroll
		scroll_y = math.max(0, math.min(scroll_y, max_scroll))
	end

	local clip_top = y + margin
	local clip_bottom = y + h - margin - 10
	local clip_left = x + margin
	local clip_right = x + w - scrollbar_width - margin

	if selection_start and selection_end and selection_start ~= selection_end then
		local start_pos = math.min(selection_start, selection_end)
		local end_pos = math.max(selection_start, selection_end)
		red, green, blue = ColorToGfx(config.selection_color)
		gfx.set(red, green, blue, 0.5)

		for line_idx = 1, #lines do
			local line_y = y + margin + (line_idx - 1) * line_height - scroll_y
			if line_y >= clip_top - line_height and line_y <= clip_bottom then
				local line_start_char = nil
				local line_end_char = nil
				for i = 0, #text do
					if char_to_line[i + 1] == line_idx then
						if not line_start_char then line_start_char = i end
						line_end_char = i
					end
				end

				if line_start_char and line_end_char then
					local sel_start_in_line = math.max(line_start_char, start_pos)
					local sel_end_in_line = math.min(line_end_char, end_pos)

					if sel_start_in_line <= sel_end_in_line then
						local line_text = lines[line_idx] or ""
						local char_offset_start = sel_start_in_line - line_start_char
						local char_offset_end = sel_end_in_line - line_start_char

						local x_start = 0
						if char_offset_start > 0 then
							x_start = gfx.measurestr(line_text:sub(1, char_offset_start))
						end
						local x_end = gfx.measurestr(line_text:sub(1, math.min(char_offset_end + 1, #line_text)))
						if x_end == x_start and char_offset_end < #line_text then
							x_end = x_start + gfx.measurestr(" ")
						end

						local sel_x = x + margin + x_start
						local sel_w = x_end - x_start
						local sel_y = math.max(line_y, clip_top)
						local sel_h = math.min(line_height, clip_bottom - sel_y)
						if sel_h > 0 and sel_x < clip_right and sel_x + sel_w > clip_left then
							local final_x = math.max(sel_x, clip_left)
							local final_w = math.min(sel_x + sel_w, clip_right) - final_x
							if final_w > 0 then
								gfx.rect(final_x, sel_y, final_w, sel_h, 1)
							end
						end
					end
				end
			end
		end
	end

	red, green, blue = ColorToGfx(config.text_color)
	gfx.set(red, green, blue)
	for i, line in ipairs(lines) do
		local line_y = y + margin + (i - 1) * line_height - scroll_y
		if line_y >= clip_top - line_height and line_y <= clip_bottom then
			local text_x = x + margin
			local text_w = gfx.measurestr(line)
			if text_x < clip_right and text_x + text_w > clip_left then
				gfx.x = text_x
				gfx.y = line_y
				gfx.drawstr(line)
			end
		end
	end

	if text_focus then
		blink_time = blink_time + 0.05
		if blink_time >= 1 then blink_time = 0 end
		if blink_time < 0.5 then
			local cursor_x, cursor_y = GetCursorScreenPos(text_cursor_pos, x, y, margin)
			if cursor_y >= clip_top and cursor_y <= clip_bottom - line_height and cursor_x >= clip_left and cursor_x <= clip_right then
				gfx.set(1, 1, 1)
				gfx.line(cursor_x, cursor_y, cursor_x, cursor_y + line_height - 2)
			end
		end
	end

	if max_scroll > 0 then
		local scrollbar_x = x + w - scrollbar_width
		gfx.set(0.15, 0.15, 0.15)
		gfx.rect(scrollbar_x, y, scrollbar_width, h, 1)
		local thumb_height = math.max(20, (h * h) / total_text_height)
		local thumb_y = y + (scroll_y / max_scroll) * (h - thumb_height)
		gfx.set(0.4, 0.4, 0.4)
		gfx.rect(scrollbar_x + 2, thumb_y + 2, scrollbar_width - 4, thumb_height - 4, 1)
		gfx.set(0.6, 0.6, 0.6)
		gfx.rect(scrollbar_x + 2, thumb_y + 2, scrollbar_width - 4, thumb_height - 4, 0)
	end

	if context_menu_open then
		DrawContextMenu(context_menu_x, context_menu_y)
	end

	return text
end

function Loop()
	CheckProjectChange()
	CheckColorUpdate()
	local red, green, blue = ColorToGfx(config.bg_color)
	gfx.set(red, green, blue)
	gfx.rect(0, 0, gfx.w, gfx.h)
	gfx.setfont(1, config.current_font, config.current_size)
	line_height = config.current_size + 4
	local w, h = gfx.w, gfx.h
	local y_pos = 10

	red, green, blue = ColorToGfx(config.text_color)
	gfx.set(red, green, blue)
	gfx.x = 10
	gfx.y = y_pos
	gfx.drawstr("Project: " .. tracked_project_name)
	local text_width = gfx.measurestr("Project: " .. tracked_project_name)

	if DrawButton(20 + text_width, y_pos - 2, 80, 20, "Reset", false) then
		tracked_project = r.EnumProjects(-1)
		tracked_project_name = GetProjectName(tracked_project)
		last_notes_content = LoadProjectNotes(tracked_project)
		text_cursor_pos = 0
		scroll_y = 0
		selection_start = nil
		selection_end = nil
		undo_stack = {}
		redo_stack = {}
	end

	if DrawButton(110 + text_width, y_pos - 2, 80, 20, "Settings", false) then
		r.SetExtState("CP_ProjectNoteEditor", "open_settings", "1", false)
		local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/Various/CP_ProjectNoteEditor_Settings.lua"
		if r.file_exists(script_path) then
			r.Main_OnCommand(r.AddRemoveReaScript(true, 0, script_path, true), 0)
		else
			r.ShowMessageBox("Settings script not found at: " .. script_path, "Error", 0)
		end
	end

	y_pos = y_pos + 30
	local editor_h = h - y_pos - 10
	DrawTextEditor(10, y_pos, w - 20, editor_h, last_notes_content)

	local char = gfx.getchar()

	if text_focus and char >= 0 then
		local ctrl = (gfx.mouse_cap & 4) == 4
		local shift = (gfx.mouse_cap & 8) == 8
		if ctrl then
			if char == 26 then
				Undo()
			elseif char == 25 then
				Redo()
			elseif char == 22 then
				PasteFromClipboard()
			elseif char == 3 then
				CopyToClipboard()
			elseif char == 24 then
				CutToClipboard()
			elseif char == 1 then
				SelectAll()
			elseif char == 6 then
				FindText()
			elseif char == 1752132965 then
				text_cursor_pos = 0
				if shift then
					if not selection_start then selection_start = #last_notes_content end
					selection_end = 0
				else
					selection_start = nil
					selection_end = nil
				end
				EnsureCursorVisible()
			elseif char == 6647396 then
				text_cursor_pos = #last_notes_content
				if shift then
					if not selection_start then selection_start = 0 end
					selection_end = #last_notes_content
				else
					selection_start = nil
					selection_end = nil
				end
				EnsureCursorVisible()
			end
		elseif char >= 32 and char <= 255 and char ~= 127 then
			local char_str = string.char(char)
			SaveUndoState()
			if selection_start and selection_end and selection_start ~= selection_end then
				local start_pos = math.min(selection_start, selection_end)
				local end_pos = math.max(selection_start, selection_end)
				last_notes_content = last_notes_content:sub(1, start_pos) .. char_str ..
				last_notes_content:sub(end_pos + 1)
				text_cursor_pos = start_pos + 1
				selection_start = nil
				selection_end = nil
			else
				last_notes_content = last_notes_content:sub(1, text_cursor_pos) ..
				char_str .. last_notes_content:sub(text_cursor_pos + 1)
				text_cursor_pos = text_cursor_pos + 1
			end
			need_save = true
		elseif char == 8 then
			if selection_start and selection_end and selection_start ~= selection_end then
				SaveUndoState()
				local start_pos = math.min(selection_start, selection_end)
				local end_pos = math.max(selection_start, selection_end)
				last_notes_content = last_notes_content:sub(1, start_pos) .. last_notes_content:sub(end_pos + 1)
				text_cursor_pos = start_pos
				selection_start = nil
				selection_end = nil
				need_save = true
			elseif text_cursor_pos > 0 then
				SaveUndoState()
				last_notes_content = last_notes_content:sub(1, text_cursor_pos - 1) ..
				last_notes_content:sub(text_cursor_pos + 1)
				text_cursor_pos = text_cursor_pos - 1
				need_save = true
			end
		elseif char == 13 then
			SaveUndoState()
			if selection_start and selection_end and selection_start ~= selection_end then
				local start_pos = math.min(selection_start, selection_end)
				local end_pos = math.max(selection_start, selection_end)
				last_notes_content = last_notes_content:sub(1, start_pos) .. "\n" .. last_notes_content:sub(end_pos + 1)
				text_cursor_pos = start_pos + 1
				selection_start = nil
				selection_end = nil
			else
				last_notes_content = last_notes_content:sub(1, text_cursor_pos) ..
				"\n" .. last_notes_content:sub(text_cursor_pos + 1)
				text_cursor_pos = text_cursor_pos + 1
			end
			need_save = true
		elseif char == 9 then
			SaveUndoState()
			if selection_start and selection_end and selection_start ~= selection_end then
				local start_pos = math.min(selection_start, selection_end)
				local end_pos = math.max(selection_start, selection_end)
				last_notes_content = last_notes_content:sub(1, start_pos) .. "    " .. last_notes_content:sub(end_pos + 1)
				text_cursor_pos = start_pos + 4
				selection_start = nil
				selection_end = nil
			else
				last_notes_content = last_notes_content:sub(1, text_cursor_pos) ..
				"    " .. last_notes_content:sub(text_cursor_pos + 1)
				text_cursor_pos = text_cursor_pos + 4
			end
			need_save = true
		elseif char == 127 then
			if selection_start and selection_end and selection_start ~= selection_end then
				SaveUndoState()
				local start_pos = math.min(selection_start, selection_end)
				local end_pos = math.max(selection_start, selection_end)
				last_notes_content = last_notes_content:sub(1, start_pos) .. last_notes_content:sub(end_pos + 1)
				text_cursor_pos = start_pos
				selection_start = nil
				selection_end = nil
				need_save = true
			elseif text_cursor_pos < #last_notes_content then
				SaveUndoState()
				last_notes_content = last_notes_content:sub(1, text_cursor_pos) ..
				last_notes_content:sub(text_cursor_pos + 2)
				need_save = true
			end
		elseif char == 1818584692 then
			if ctrl then
				MoveCursorWordLeft(shift)
			else
				MoveCursorLeft(shift)
			end
		elseif char == 1919379572 then
			if ctrl then
				MoveCursorWordRight(shift)
			else
				MoveCursorRight(shift)
			end
		elseif char == 30064 then
			MoveCursorUp(shift)
		elseif char == 1685026670 then
			MoveCursorDown(shift)
		elseif char == 1752132965 then
			MoveCursorHome(shift)
		elseif char == 6647396 then
			MoveCursorEnd(shift)
		elseif char == 1885824110 then
			MoveCursorPageUp(shift)
		elseif char == 1885824111 then
			MoveCursorPageDown(shift)
		end

		if need_save then
			SaveProjectNotes(tracked_project, last_notes_content)
			need_save = false
		end
	end

	last_mouse_cap = gfx.mouse_cap
	if char >= 0 then
		r.defer(Loop)
	else
		SaveSettings()
		gfx.quit()
	end
end

function Start()
	LoadSettings()
	CheckProjectChange()
	local dock_state = tonumber(r.GetExtState("CP_ProjectNoteEditor", "dock_state")) or 0
	gfx.init("Project Notes Editor", config.window_w, config.window_h, dock_state, config.window_x, config.window_y)
	if dock_state > 0 then
		gfx.dock(dock_state)
	end
	Loop()
end

function ToggleScript()
	local _, _, sectionID, cmdID = r.get_action_context()
	local state = r.GetToggleCommandState(cmdID)
	if state == -1 or state == 0 then
		r.SetToggleCommandState(sectionID, cmdID, 1)
		r.RefreshToolbar2(sectionID, cmdID)
		Start()
	else
		r.SetToggleCommandState(sectionID, cmdID, 0)
		r.RefreshToolbar2(sectionID, cmdID)
		gfx.quit()
	end
end

function Exit()
	local x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
	if x and x > 0 then
		config.window_x = x
		config.window_y = y
		config.window_w = w
		config.window_h = h
	end
	SaveSettings()
	local _, _, sectionID, cmdID = r.get_action_context()
	r.SetToggleCommandState(sectionID, cmdID, 0)
	r.RefreshToolbar2(sectionID, cmdID)
	gfx.quit()
end

r.atexit(Exit)
ToggleScript()










