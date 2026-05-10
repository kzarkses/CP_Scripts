-- @description CP Floating Toolbar Manager — configure floating toolbars
-- @version 0.2
-- @author Cedric Pamalio

local r = reaper

local script_path  = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local toolkit_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua"

local UI          = dofile(toolkit_path)
local Persistence = dofile(script_path .. "Modules/Persistence.lua")
local Actions     = dofile(script_path .. "Modules/Actions.lua")
local IconPicker  = dofile(script_path .. "Modules/IconPicker.lua")

Persistence.Init(UI)
IconPicker.Init(UI)

local picker_state = IconPicker.NewState()

local data = Persistence.Load()
if #data.toolbars == 0 then
    table.insert(data.toolbars, Persistence.NewToolbar("Default"))
    data.active_toolbar_id = data.toolbars[1].id
    Persistence.Save(data)
end

UI.Init("CP Floating Toolbar Manager", 760, 520, {
    persist = "CP_FloatingToolbarManager",
})

-- ---------------------------------------------------------------------------
-- UI state
-- ---------------------------------------------------------------------------
local search_text   = ""
local search_results = {}
local search_dirty   = true

local builtin_icons = {}
do
    local skip = { Init = true, SetLog = true, Set = true }
    for k, v in pairs(UI.Icons) do
        if type(v) == "function" and not skip[k] then
            table.insert(builtin_icons, k)
        end
    end
    table.sort(builtin_icons)
end

local target_options = { "main", "mixer", "transport", "media_explorer", "arrange", "ruler" }
local direction_options = { "horizontal", "vertical" }
local snap_options = { "left", "right", "free" }

local function active_toolbar()
    return Persistence.GetActiveToolbar(data)
end

local function index_of(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return 1
end

local function dirty()
    Persistence.RequestSave()
end

local function refresh_search()
    search_results = Actions.Search(search_text, 200)
    search_dirty = false
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------
local function draw_toolbar_list_section()
    UI.SetFontH2()
    UI.Text("Toolbars")
    UI.SetFontBody()
    UI.Spacing(4)

    local items = {}
    for _, tb in ipairs(data.toolbars) do
        items[#items + 1] = { label = (tb.enabled and "[ON]  " or "[off] ") .. tb.name }
    end

    local actions_col = {
        { icon = "X", tooltip = "Delete" },
    }

    local selected_idx = 1
    for i, tb in ipairs(data.toolbars) do
        if tb.id == data.active_toolbar_id then selected_idx = i; break end
    end

    local clicked, action_idx = UI.ActionList("toolbar_list", items, actions_col, {
        selected = selected_idx,
        max_visible = 6,
    })

    if clicked then
        data.active_toolbar_id = data.toolbars[clicked].id
        dirty()
    end

    if action_idx == 1 and clicked then
        if #data.toolbars > 1 then
            table.remove(data.toolbars, clicked)
            data.active_toolbar_id = data.toolbars[1].id
            dirty()
        end
    end

    UI.Spacing(6)
    if UI.Button("add_toolbar", "+ New") then
        local tb = Persistence.NewToolbar("Toolbar " .. (#data.toolbars + 1))
        table.insert(data.toolbars, tb)
        data.active_toolbar_id = tb.id
        dirty()
    end
    UI.SameLine(8)
    local tb = active_toolbar()
    if tb then
        local toggled, on = UI.ToggleButton("tb_enabled", tb.enabled and "Enabled" or "Disabled", tb.enabled)
        if toggled then tb.enabled = on; dirty() end
    end
end

local function draw_anchor_section(tb)
    UI.SetFontH2(); UI.Text("Anchor"); UI.SetFontBody()
    UI.Spacing(4)

    local changed_name, new_name = UI.InputText("tb_name", "Name", tb.name, { width = 240 })
    if changed_name then tb.name = new_name; dirty() end

    local cur_target = index_of(target_options, tb.anchor.target or "main")
    local target_changed, new_target_idx = UI.Combo("tb_target", "Target window", cur_target, target_options, { width = 240 })
    if target_changed then tb.anchor.target = target_options[new_target_idx]; dirty() end

    -- Snap mode: simplifies positioning. left/right snap to the target's
    -- corresponding edge (offset_x is then a positive inward distance);
    -- free uses the proportional anchor.x.
    local cur_snap = index_of(snap_options, tb.anchor.snap or "left")
    local snap_changed, new_snap_idx = UI.Combo("tb_snap", "Snap to edge", cur_snap, snap_options, { width = 240 })
    if snap_changed then tb.anchor.snap = snap_options[new_snap_idx]; dirty() end

    -- Anchor X is only meaningful in "free" mode
    if (tb.anchor.snap or "left") == "free" then
        local cx, nx = UI.SliderDouble("tb_anchor_x", "Anchor X (0-1)", tb.anchor.x or 0, 0, 1)
        if cx then tb.anchor.x = nx; dirty() end
    end
    local cy, ny = UI.SliderDouble("tb_anchor_y", "Anchor Y (0-1)", tb.anchor.y or 0, 0, 1)
    if cy then tb.anchor.y = ny; dirty() end

    local cox, nox = UI.NumberInput("tb_offset_x", "Offset X (px)", tb.anchor.offset_x or 0, -4000, 4000, { step = 1, format = "%d" })
    if cox then tb.anchor.offset_x = nox; dirty() end
    local coy, noy = UI.NumberInput("tb_offset_y", "Offset Y (px)", tb.anchor.offset_y or 0, -4000, 4000, { step = 1, format = "%d" })
    if coy then tb.anchor.offset_y = noy; dirty() end

    local hide_changed, hide_on = UI.Checkbox("tb_hide", "Hide when target window is hidden",
        tb.anchor.hide_when_target_hidden ~= false)
    if hide_changed then tb.anchor.hide_when_target_hidden = hide_on; dirty() end

    -- Auto-hide thresholds (mirrors CP_CustomToolbars). 0 = disabled.
    local cmw, nmw = UI.NumberInput("tb_min_w", "Auto-hide if target W <",
        tb.anchor.auto_hide_min_width or 0, 0, 8000, { step = 50, format = "%d px" })
    if cmw then tb.anchor.auto_hide_min_width = nmw; dirty() end
    local cmh, nmh = UI.NumberInput("tb_min_h", "Auto-hide if target H <",
        tb.anchor.auto_hide_min_height or 0, 0, 8000, { step = 50, format = "%d px" })
    if cmh then tb.anchor.auto_hide_min_height = nmh; dirty() end
end

local function draw_layout_section(tb)
    UI.SetFontH2(); UI.Text("Layout"); UI.SetFontBody()
    UI.Spacing(4)

    local cur_dir = index_of(direction_options, tb.layout.direction or "horizontal")
    local dir_changed, new_dir = UI.Combo("tb_dir", "Direction", cur_dir, direction_options, { width = 200 })
    if dir_changed then tb.layout.direction = direction_options[new_dir]; dirty() end

    local cs, ns = UI.SliderInt("tb_icon_size", "Icon size", tb.layout.icon_size or 24, 12, 64)
    if cs then tb.layout.icon_size = ns; dirty() end

    local cg, ng = UI.SliderInt("tb_spacing", "Spacing", tb.layout.spacing or 4, 0, 32)
    if cg then tb.layout.spacing = ng; dirty() end

    local cp, np = UI.SliderInt("tb_padding", "Padding", tb.layout.padding or 0, 0, 32)
    if cp then tb.layout.padding = np; dirty() end

    local ca, na = UI.SliderDouble("tb_bg_alpha", "Background alpha (0 = invisible)",
        tb.layout.bg_alpha or 0, 0, 1)
    if ca then tb.layout.bg_alpha = na; dirty() end

    -- Background appearance — only visible when alpha > 0 (otherwise no point)
    if (tb.layout.bg_alpha or 0) > 0 then
        local color = tb.layout.bg_color or { 0.12, 0.12, 0.14 }
        local cc, nc = UI.ColorPicker("tb_bg_color", "Background color", color)
        if cc then
            tb.layout.bg_color = { nc[1], nc[2], nc[3] }
            dirty()
        end

        local cr, nr = UI.SliderInt("tb_bg_radius", "Corner radius", tb.layout.bg_radius or 0, 0, 24)
        if cr then tb.layout.bg_radius = nr; dirty() end

        local cb, nb = UI.Checkbox("tb_bg_border", "Border", tb.layout.bg_border == true)
        if cb then tb.layout.bg_border = nb; dirty() end
    end
end

local function draw_actions_section(tb)
    UI.SetFontH2(); UI.Text("Actions in this toolbar"); UI.SetFontBody()
    UI.Spacing(4)

    if #tb.actions == 0 then
        UI.TextColored("(none yet — add from the right panel)", 0.6, 0.6, 0.6, 1)
    else
        for i, act in ipairs(tb.actions) do
            UI.Text(string.format("%d.  %s", i, Actions.GetName(act.command_id)))

            UI.SameLine(8)
            if UI.Button("up_" .. i, "↑", { width = 26, height = 22 }) and i > 1 then
                tb.actions[i - 1], tb.actions[i] = tb.actions[i], tb.actions[i - 1]
                dirty()
            end
            UI.SameLine(2)
            if UI.Button("dn_" .. i, "↓", { width = 26, height = 22 }) and i < #tb.actions then
                tb.actions[i + 1], tb.actions[i] = tb.actions[i], tb.actions[i + 1]
                dirty()
            end
            UI.SameLine(2)
            if UI.Button("rm_" .. i, "✕", { width = 26, height = 22 }) then
                table.remove(tb.actions, i)
                dirty()
                break
            end

            -- Icon choice for this action
            UI.SameLine(12)
            local icons_list = { "(none)" }
            for _, name in ipairs(builtin_icons) do icons_list[#icons_list + 1] = name end
            local cur = 1
            if act.builtin_icon then cur = (index_of(icons_list, act.builtin_icon)) end
            local ic_changed, ic_idx = UI.Combo("ic_" .. i, "Icon", cur, icons_list, { width = 130 })
            if ic_changed then
                act.builtin_icon = (ic_idx > 1) and icons_list[ic_idx] or nil
                act._cached_image = nil
                dirty()
            end

            UI.SameLine(4)
            if UI.Button("img_" .. i, act.icon and "PNG ✓" or "PNG…", { width = 70, height = 22 }) then
                local ok, file = r.GetUserFileNameForRead("", "Pick PNG icon", ".png")
                if ok and file ~= "" then
                    act.icon = file
                    act._cached_image = nil
                    dirty()
                end
            end
            if act.icon then
                UI.SameLine(4)
                if UI.Button("imgrm_" .. i, "Clear PNG", { width = 80, height = 22 }) then
                    act.icon = nil
                    act._cached_image = nil
                    dirty()
                end
            end

            -- Native REAPER toolbar icon picker (opens visual grid below)
            UI.SameLine(4)
            local nat_label = act.native_icon
                and ("Native: " .. act.native_icon:sub(1, 18))
                or "Native…"
            if UI.Button("nat_" .. i, nat_label, { width = 150, height = 22 }) then
                local action_ref = act  -- capture in closure (loop var safety)
                IconPicker.Open(picker_state, {
                    target  = action_ref,
                    search  = action_ref.native_icon or "",
                    on_pick = function(fname)
                        action_ref.native_icon = fname
                        action_ref._cached_image = nil
                        dirty()
                    end,
                    on_clear = function()
                        action_ref.native_icon = nil
                        action_ref._cached_image = nil
                        dirty()
                    end,
                })
            end
        end
    end
end

local function draw_action_picker(tb)
    UI.SetFontH2(); UI.Text("Add an action"); UI.SetFontBody()
    UI.Spacing(4)

    local changed, new_text = UI.InputText("search", "Search", search_text, {
        hint = "Type to filter REAPER actions",
        width = -1,
    })
    if changed then
        search_text = new_text
        search_dirty = true
    end

    if search_dirty then refresh_search() end

    local items = {}
    for i = 1, math.min(#search_results, 200) do
        items[i] = { label = search_results[i].name }
    end

    local clicked = UI.ActionList("search_results", items, { { icon = "+", tooltip = "Add" } }, {
        max_visible = 12,
    })

    if clicked and search_results[clicked] then
        local a = search_results[clicked]
        table.insert(tb.actions, Persistence.NewAction(a.id))
        dirty()
    end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
UI.Run(function()
    UI.SetFontTitle()
    UI.Text("CP Floating Toolbar")
    UI.SetFontBody()
    UI.Spacing(2)
    UI.TextColored(
        "Run CP_FloatingToolbar.lua to display the active toolbar. " ..
        "Ctrl+drag to reposition, edits hot-reload within ~1s.",
        0.6, 0.6, 0.6, 1)
    UI.Separator()

    -- Icon picker takes over the whole content area when open. This avoids
    -- cramming a 600-thumbnail grid into a column.
    if picker_state.open then
        IconPicker.Draw(picker_state, {
            cell    = 32,
            gap     = 4,
            height  = 380,
            columns = 16,
        })
    else
        UI.BeginColumns("main_cols", { 0.42, 0.58 })

        -- LEFT: toolbar list + anchor + layout
        draw_toolbar_list_section()
        UI.Separator()

        local tb = active_toolbar()
        if tb then
            draw_anchor_section(tb)
            UI.Separator()
            draw_layout_section(tb)
        end

        UI.NextColumn()

        -- RIGHT: actions list + picker
        if tb then
            draw_actions_section(tb)
            UI.Separator()
            draw_action_picker(tb)
        end

        UI.EndColumns()
    end

    Persistence.ProcessSaveQueue(data)
end)

UI.OnClose(function()
    Persistence.FlushSave(data)
end)
