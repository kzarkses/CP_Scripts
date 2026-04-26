-- CP_Inspector UI — Horizontal property bar (MPT-style)
-- Clean transparent cells, mono values, intelligent zone-based time drag,
-- modified/negative coloring, double-click sub-panels, Pan dropdown menu.

local UI = {}
local Core  -- Inspector Core module
local TK    -- CP_Toolkit UI reference

-- Headers/cells which have an associated companion script. Only these are
-- interactive on hover/double-click in the header row.
local SUB_PANEL_SCRIPTS = {
    name           = "CP_Inspector/CP_Inspector_TakeRenamer.lua",
    source         = "CP_Inspector/CP_Inspector_SourceManager.lua",
    pitch          = "CP_Inspector/CP_Inspector_PitchStretch.lua",
    rate           = "CP_Inspector/CP_Inspector_PitchStretch.lua",
    preserve_pitch = "CP_Inspector/CP_Inspector_PitchStretch.lua",
}

-- Right-click on these headers toggles the take envelope (ported from MPT).
-- Values are REAPER action command IDs for "Take: Toggle X envelope".
local HEADER_ENVELOPE_CMDS = {
    takevol = 40693,  -- Take: Toggle take volume envelope
    pan     = 40694,  -- Take: Toggle take pan envelope
    pitch   = 41612,  -- Take: Toggle take pitch envelope
    mute    = 40695,  -- Take: Toggle take mute envelope
}

function UI.Init(inspector_core, toolkit_ui)
    Core = inspector_core
    TK = toolkit_ui
end

-- ============================================================================
-- MAIN RENDER
-- ============================================================================
function UI.Draw(theme)
    local values = Core.state.values
    local count = Core.state.item_count
    local prefs = Core.state.prefs

    if count == 0 then
        TK.Text("No items selected", { disabled = true })
        return
    end

    -- Build weighted row definition from visible properties
    local weights = {}
    for _, prop in ipairs(Core.PROPERTIES) do
        if Core.state.visible_props[prop.key] then
            weights[#weights + 1] = {
                key = prop.key,
                weight = prop.weight,
                min_w = prop.type == "bool" and 30 or 50,
            }
        end
    end

    local row_h = prefs.row_height

    -- Extra space above the header row (on top of window padding)
    if prefs.top_padding > 0 then
        TK.Spacing(prefs.top_padding)
    end

    -- Header row
    if prefs.show_header then
        TK.SetFontCaption()
        TK.BeginWeightedRow("insp_header", weights, { height = row_h, gap = prefs.col_gap })
        for _, w in ipairs(weights) do
            local cx, cy, cw, ch = TK.Layout.WeightedCell("insp_header", w.key)
            if cx then
                UI._DrawHeader(w.key, cx, cy, cw, ch)
            end
        end
        TK.EndWeightedRow("insp_header")
        TK.SetFontBody()

        -- Absolute gap: prefs.gap is the exact pixel distance between header
        -- and value rows, INDEPENDENT of the toolkit's item_spacing. gap=0
        -- means the rows literally touch.
        TK.Spacing(prefs.gap - theme.item_spacing)
    end

    -- Value row — same col_gap as header so columns align perfectly.
    if prefs.font_value == "mono" then TK.SetFontMono() else TK.SetFontBody() end
    TK.BeginWeightedRow("insp_values", weights, { height = row_h, gap = prefs.col_gap })
    for _, w in ipairs(weights) do
        local cx, cy, cw, ch = TK.Layout.WeightedCell("insp_values", w.key)
        if cx then
            UI._DrawValueCell(w.key, values[w.key], cx, cy, cw, ch, theme)
        end
    end
    TK.EndWeightedRow("insp_values")
    TK.SetFontBody()
end

-- ============================================================================
-- HEADER CELL — flat dimmed label (no background, no separator)
--   Only headers with a companion script react to hover/double-click.
--   Pan header gets a small ▼ dropdown for channel-mode preset menu.
-- ============================================================================
function UI._DrawHeader(key, x, y, w, h)
    local prop = Core.PROP_BY_KEY[key]
    if not prop then return end

    local label = prop.label
    local tw, th = TK.Core.MeasureText(label)

    -- Truncate label if needed
    if tw > w - 4 and #label > 2 then
        while tw > w - 4 and #label > 2 do
            label = label:sub(1, -2)
            tw = TK.Core.MeasureText(label)
        end
    end

    local has_sub_panel = SUB_PANEL_SCRIPTS[key] ~= nil
    local has_envelope  = HEADER_ENVELOPE_CMDS[key] ~= nil
    local interactive = has_sub_panel or has_envelope
    local hovered = interactive
        and TK.Core.MouseInClippedRect(x, y, w, h)
        and not TK.Core.HasPopup()

    local hc = Core.state.prefs.col_header
    local alpha = (hc[4] or 0.5) * (hovered and 1.7 or 1.0)
    if alpha > 1 then alpha = 1 end

    local tx = x + math.floor((w - tw) / 2)
    local ty = y + math.floor((h - th) / 2)
    TK.Core.DrawText(label, tx, ty, hc[1], hc[2], hc[3], alpha)

    if hovered then
        TK.Core.SetHot("hdr_" .. key)
        if has_sub_panel and TK.Core.MouseDoubleClicked() then
            UI._OpenSubPanel(key)
        end
        -- Right-click on takevol/pan/pitch/mute headers toggles the take envelope.
        if has_envelope and TK.Core.MouseClicked(2) then
            reaper.Main_OnCommand(HEADER_ENVELOPE_CMDS[key], 0)
        end
    end

    -- ---- Pan header → channel mode dropdown (▼ icon) ----
    if key == "pan" then
        local icon_size = math.min(10, h - 4)
        local ix = x + w - icon_size - 4
        local iy = y + math.floor((h - icon_size) / 2)
        local ihover = TK.Core.MouseInClippedRect(ix, iy, icon_size, icon_size)
            and not TK.Core.HasPopup()
        local ia = ihover and 1.0 or 0.7
        TK.Icons.TriangleDown(ix, iy, icon_size, hc[1], hc[2], hc[3], ia)
        if ihover then
            TK.Core.SetHot("hdr_pan_dd")
            if TK.Core.MouseClicked(1) then
                UI._ShowChannelModeMenu()
            end
        end
    end
end

-- ============================================================================
-- VALUE CELL (display + interaction)
-- ============================================================================
function UI._DrawValueCell(key, value, x, y, w, h, theme)
    local prop = Core.PROP_BY_KEY[key]
    if not prop then return end

    local prefs = Core.state.prefs
    local cell_id = "cell_" .. key
    local hovered = TK.Core.MouseInClippedRect(x, y, w, h) and not TK.Core.HasPopup()
    local active  = TK.Core.IsActive(cell_id)

    -- (hover highlight intentionally removed — cells stay visually flat)
    if hovered then TK.Core.SetHot(cell_id) end

    -- Format value + pick color
    local display = Core.FormatValue(key, value)
    local color_key = Core.GetValueColorKey(key, value)
    local tc
    if color_key == "value_modified" then
        tc = prefs.col_modified
    elseif color_key == "value_negative" then
        tc = prefs.col_negative
    else
        tc = prefs.col_normal
    end

    -- Truncate if needed (text fields)
    local pad = prefs.cell_padding_x
    local max_text_w = w - pad * 2
    local tw, th = TK.Core.MeasureText(display)
    if tw > max_text_w and #display > 3 then
        while tw > max_text_w and #display > 3 do
            display = display:sub(1, -2)
            tw = TK.Core.MeasureText(display)
        end
        display = display .. ".."
        tw = TK.Core.MeasureText(display)
    end

    -- Alignment
    local tx
    if prefs.text_align == "left" then
        tx = x + pad
    elseif prefs.text_align == "right" then
        tx = x + w - pad - tw
    else
        tx = x + math.floor((w - tw) / 2)
    end
    local ty = y + math.floor((h - th) / 2)
    TK.Core.DrawText(display, tx, ty, tc[1], tc[2], tc[3], tc[4] or 1)

    -- ---- INTERACTIONS ----

    -- Bool toggle on click
    if prop.type == "bool" then
        if hovered and TK.Core.MouseClicked(1) then
            reaper.Undo_BeginBlock()
            Core.UpdateProperty(key, not value)
            reaper.Undo_EndBlock("CP Inspector: Toggle " .. prop.label, -1)
            Core.RefreshSelection()
        end
        return
    end

    -- Numeric / time params: drag, wheel, double-click, right-click reset
    if prop.type ~= "text" then
        if hovered and TK.Core.MouseClicked(1) then
            TK.Core.SetActive(cell_id)
            -- Capture which time-zone the click landed in (for the whole drag)
            if prop.type == "time" then
                local zones = Core.GetTimeZones(display, tx, TK.Core.MeasureText)
                local mx, _ = TK.Core.GetMousePos()
                local data = TK.Core.GetWidgetData(cell_id, {})
                data.zone = Core.PickTimeZone(zones, mx)
                TK.Core.SetWidgetData(cell_id, data)
            end
        end

        if active then
            if TK.Core.MouseDown(1) then
                local dx, _ = TK.Core.MouseDelta()
                if dx ~= 0 then
                    local sensitivity
                    if prop.type == "time" then
                        local data = TK.Core.GetWidgetData(cell_id, {})
                        sensitivity = Core.GetTimeZoneDragSensitivity(data.zone or "mid")
                    else
                        sensitivity = prop.sensitivity or 0.01
                    end
                    Core.UpdatePropertyOffset(key, dx * sensitivity)
                    Core.RefreshSelection()
                end
            else
                TK.Core.ClearActive()
            end
        end

        -- Mouse wheel: zone-based for time, fixed step for others
        if hovered and not TK.Core.HasPopup() then
            local wheel = TK.Core.GetState().mouse_wheel
            if wheel ~= 0 then
                local step
                if prop.type == "time" then
                    local zones = Core.GetTimeZones(display, tx, TK.Core.MeasureText)
                    local mx, _ = TK.Core.GetMousePos()
                    local zone = Core.PickTimeZone(zones, mx)
                    step = Core.GetTimeZoneStep(zone)
                elseif prop.type == "db" then
                    step = 0.5
                elseif prop.type == "semi" then
                    step = 1
                elseif prop.type == "pan" then
                    step = 0.05
                elseif prop.type == "rate" then
                    step = 0.01
                else
                    step = 0.01
                end
                local dir = wheel > 0 and 1 or -1
                Core.UpdatePropertyOffset(key, dir * step)
                Core.RefreshSelection()
                TK.Core.GetState().mouse_wheel = 0
            end
        end

        -- Right-click to reset
        if hovered and TK.Core.MouseClicked(2) then
            local reset_value
            if key == "snap" or key == "fadein" or key == "fadeout" then
                reset_value = 0
            elseif key == "itemvol" or key == "takevol" then
                reset_value = 1
            elseif key == "pitch" or key == "pan" then
                reset_value = 0
            elseif key == "rate" then
                reset_value = 1
            elseif key == "length" then
                -- Reset length to original (unmodified) source length
                reset_value = Core.state.values._source_length
            end
            -- position has no sensible reset
            if reset_value ~= nil then
                reaper.Undo_BeginBlock()
                Core.UpdateProperty(key, reset_value)
                reaper.Undo_EndBlock("CP Inspector: Reset " .. prop.label, -1)
                Core.RefreshSelection()
            end
        end

        -- Double-click → precise input dialog (matches MPT)
        if hovered and TK.Core.MouseDoubleClicked() then
            TK.Core.ClearActive()  -- cancel pending drag
            local new_val = Core.HandleValueInput(key, value)
            if new_val ~= nil then
                reaper.Undo_BeginBlock()
                Core.UpdateProperty(key, new_val)
                reaper.Undo_EndBlock("CP Inspector: Set " .. prop.label, -1)
                Core.RefreshSelection()
            end
        end
    end

    -- Text fields → double-click opens companion script
    if prop.type == "text" and hovered and TK.Core.MouseDoubleClicked() then
        UI._OpenSubPanel(key)
    end

    -- Only "source" shows a tooltip (full file path on hover — the cell
    -- truncates the filename and the path info would otherwise be hidden).
    if hovered and key == "source" then UI._SetTooltip(key, prop) end
end

-- ============================================================================
-- TOOLTIPS
-- ============================================================================
function UI._SetTooltip(key, prop)
    local tip
    if key == "source" then
        -- Show full filesystem path on hover (truncated cell hides it)
        tip = Core.state.values._source_path or Core.state.values.source or "Source"
    elseif key == "name" then
        tip = "Take name — Double-click to rename"
    elseif prop.type == "time" then
        tip = prop.label .. " — Drag (zone), Wheel, Dbl-click edit, R-click reset"
    elseif prop.type == "bool" then
        tip = prop.label .. " — Click to toggle"
    elseif prop.type == "text" then
        tip = prop.label
    else
        tip = prop.label .. " — Drag/Wheel, Dbl-click edit, R-click reset"
        if key == "pitch" then tip = tip .. " (header: algorithm)" end
        if key == "rate"  then tip = tip .. " (header: stretch markers)" end
    end
    TK.Tooltip(tip)
end

-- ============================================================================
-- SUB-PANEL ROUTING (opens companion scripts)
-- ============================================================================
function UI._OpenSubPanel(key)
    local rel = SUB_PANEL_SCRIPTS[key]
    if not rel then return end
    local r = reaper
    local script_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/" .. rel

    if r.file_exists(script_path) then
        local cmd = r.NamedCommandLookup("_RS" .. script_path)
        if cmd == 0 then
            cmd = r.AddRemoveReaScript(true, 0, script_path, true)
        end
        if cmd ~= 0 then
            r.Main_OnCommand(cmd, 0)
        end
    end
end

-- ============================================================================
-- PAN HEADER DROPDOWN — channel-mode preset menu (matches MPT)
-- ============================================================================
function UI._ShowChannelModeMenu()
    local r = reaper
    local current_chanmode = 0
    local item = r.GetSelectedMediaItem(0, 0)
    if item then
        local take = r.GetActiveTake(item)
        if take then
            current_chanmode = r.GetMediaItemTakeInfo_Value(take, "I_CHANMODE")
        end
    end

    local items = {
        "Normal",
        "Reverse Stereo",
        "Mono (Mix L+R)",
        "Mono (Left)",
        "Mono (Right)",
    }
    -- Mark currently active mode with "!"
    for i = 1, #items do
        if i - 1 == current_chanmode then
            items[i] = "!" .. items[i]
        end
    end

    local menu_str = table.concat(items, "|")
    -- Position the menu under the mouse
    gfx.x, gfx.y = TK.Core.GetMousePos()
    local sel = gfx.showmenu(menu_str)
    if sel > 0 then
        -- REAPER actions for channel mode toggles
        local cmds = { 40176, 40177, 40178, 40179, 40180 }
        r.Main_OnCommand(cmds[sel], 0)
    end
end

return UI
