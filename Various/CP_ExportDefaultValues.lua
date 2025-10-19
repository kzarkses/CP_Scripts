-- @description ExportDefaultValues
-- @version 1.0.0
-- @author Cedric Pamalio

local r = reaper
local script_name = "CP_ExportDefaultValues"
local extstate_id = "CP_ImGuiStyles"

function ExportAsDefaults()
    local saved = r.GetExtState(extstate_id, "styles")
    if saved == "" then
        r.ShowMessageBox("No style data found in StyleManager.\nPlease configure your styles first.", "Export Error", 0)
        return false
    end

    local success, styles = pcall(function() return load("return " .. saved)() end)
    if not success or not styles then
        r.ShowMessageBox("Could not parse style data", "Export Error", 0)
        return false
    end

    local export_text = "-- Default values extracted from CP_ImGuiStyleManager\n"
    export_text = export_text .. "-- Copy these values to replace defaults in your scripts\n"
    export_text = export_text .. "-- Generated on: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n"

    if styles.fonts then
        export_text = export_text .. "-- FONTS (replace in GetStyleValue calls)\n"
        for font_type, font_data in pairs(styles.fonts) do
            export_text = export_text .. "-- fonts." .. font_type .. ".name = \"" .. (font_data.name or "verdana") .. "\"\n"
            export_text = export_text .. "-- fonts." .. font_type .. ".size = " .. (font_data.size or 16) .. "\n"
        end
        export_text = export_text .. "\n"
    end

    if styles.spacing then
        export_text = export_text .. "-- SPACING VALUES (use as default_value in GetStyleValue)\n"
        for key, value in pairs(styles.spacing) do
            export_text = export_text .. "-- spacing." .. key .. " = " .. value .. "\n"
        end
        export_text = export_text .. "\n"
    end

    if styles.borders then
        export_text = export_text .. "-- BORDER VALUES\n"
        for key, value in pairs(styles.borders) do
            export_text = export_text .. "-- borders." .. key .. " = " .. value .. "\n"
        end
        export_text = export_text .. "\n"
    end

    if styles.rounding then
        export_text = export_text .. "-- ROUNDING VALUES\n"
        for key, value in pairs(styles.rounding) do
            export_text = export_text .. "-- rounding." .. key .. " = " .. value .. "\n"
        end
        export_text = export_text .. "\n"
    end

    export_text = export_text .. "-- USAGE EXAMPLES:\n"
    export_text = export_text .. "-- Replace this:\n"
    export_text = export_text .. "--   local spacing_x = GetStyleValue(\"spacing.item_spacing_x\", 8)\n"
    export_text = export_text .. "-- With this:\n"
    if styles.spacing and styles.spacing.item_spacing_x then
        export_text = export_text .. "--   local spacing_x = GetStyleValue(\"spacing.item_spacing_x\", " .. styles.spacing.item_spacing_x .. ")\n"
    end
    export_text = export_text .. "\n"

    if styles.colors then
        export_text = export_text .. "-- COLORS (hex format for copy-paste)\n"
        for key, value in pairs(styles.colors) do
            export_text = export_text .. "-- " .. key .. " = 0x" .. string.format("%08X", value) .. "\n"
        end
    end

    local export_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_DefaultValues_Export.txt"
    local file = io.open(export_path, "w")
    if file then
        file:write(export_text)
        file:close()
        r.ShowMessageBox("Default values exported successfully!\n\nFile: " .. export_path .. "\n\nYou can now copy these values to use as defaults in your scripts.", "Export Complete", 0)
        return true
    else
        r.ShowMessageBox("Could not create export file", "Export Error", 0)
        return false
    end
end

ExportAsDefaults()
