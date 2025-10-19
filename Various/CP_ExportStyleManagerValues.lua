-- @description ExportStyleManagerValues
-- @version 1.0.0
-- @author Cedric Pamalio

local r = reaper
local script_name = "CP_ExportStyleManagerValues"
local extstate_id = "CP_ImGuiStyles"

function ExportStyleValues()
    local saved = r.GetExtState(extstate_id, "styles")
    if saved == "" then
        r.ShowMessageBox("No style data found in StyleManager", "Export Error", 0)
        return false
    end

    local success, styles = pcall(function() return load("return " .. saved)() end)
    if not success or not styles then
        r.ShowMessageBox("Could not parse style data", "Export Error", 0)
        return false
    end

    local export_text = "-- CP_ImGuiStyleManager Export\n"
    export_text = export_text .. "-- Generated on: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n"

    export_text = export_text .. "local styles = {\n"

    if styles.fonts then
        export_text = export_text .. "    fonts = {\n"
        for font_type, font_data in pairs(styles.fonts) do
            export_text = export_text .. "        " .. font_type .. " = {\n"
            export_text = export_text .. "            name = \"" .. (font_data.name or "verdana") .. "\",\n"
            export_text = export_text .. "            size = " .. (font_data.size or 16) .. "\n"
            export_text = export_text .. "        },\n"
        end
        export_text = export_text .. "    },\n"
    end

    if styles.colors then
        export_text = export_text .. "    colors = {\n"
        for color_name, color_value in pairs(styles.colors) do
            export_text = export_text .. "        " .. color_name .. " = 0x" .. string.format("%08X", color_value) .. ",\n"
        end
        export_text = export_text .. "    },\n"
    end

    if styles.spacing then
        export_text = export_text .. "    spacing = {\n"
        for spacing_name, spacing_value in pairs(styles.spacing) do
            export_text = export_text .. "        " .. spacing_name .. " = " .. spacing_value .. ",\n"
        end
        export_text = export_text .. "    },\n"
    end

    if styles.borders then
        export_text = export_text .. "    borders = {\n"
        for border_name, border_value in pairs(styles.borders) do
            export_text = export_text .. "        " .. border_name .. " = " .. border_value .. ",\n"
        end
        export_text = export_text .. "    },\n"
    end

    if styles.rounding then
        export_text = export_text .. "    rounding = {\n"
        for rounding_name, rounding_value in pairs(styles.rounding) do
            export_text = export_text .. "        " .. rounding_name .. " = " .. rounding_value .. ",\n"
        end
        export_text = export_text .. "    },\n"
    end

    if styles.sliders then
        export_text = export_text .. "    sliders = {\n"
        for slider_name, slider_value in pairs(styles.sliders) do
            export_text = export_text .. "        " .. slider_name .. " = " .. slider_value .. ",\n"
        end
        export_text = export_text .. "    },\n"
    end

    if styles.extras then
        export_text = export_text .. "    extras = {\n"
        for extra_name, extra_value in pairs(styles.extras) do
            local value_str = tostring(extra_value)
            if type(extra_value) == "string" then
                value_str = "\"" .. extra_value .. "\""
            end
            export_text = export_text .. "        " .. extra_name .. " = " .. value_str .. ",\n"
        end
        export_text = export_text .. "    },\n"
    end

    export_text = export_text .. "}\n\n"

    export_text = export_text .. "-- Usage example:\n"
    export_text = export_text .. "-- Replace the default values in your scripts with these values\n"
    export_text = export_text .. "-- for consistent styling across all CP scripts\n"

    local export_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_StyleManager_Export.txt"
    local file = io.open(export_path, "w")
    if file then
        file:write(export_text)
        file:close()
        r.ShowMessageBox("Style values exported successfully to:\n" .. export_path, "Export Complete", 0)
        return true
    else
        r.ShowMessageBox("Could not create export file at:\n" .. export_path, "Export Error", 0)
        return false
    end
end

ExportStyleValues()
