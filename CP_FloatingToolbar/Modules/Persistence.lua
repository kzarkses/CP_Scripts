-- CP_FloatingToolbar / Persistence
-- Stores all floating toolbars in CP_Config/CP_FloatingToolbar.lua
-- (one Lua file, much faster than ExtState).

local Persistence = {}

local SCRIPT_ID = "CP_FloatingToolbar"

local UI = nil
local pending_save_at = nil
local SAVE_DEBOUNCE = 0.15  -- short enough that hot-reload feels live

function Persistence.Init(ui)
    UI = ui
end

local function default_data()
    return {
        version = 1,
        active_toolbar_id = nil,
        toolbars = {},
    }
end

function Persistence.NewToolbar(name)
    return {
        id = tostring(reaper.time_precise()):gsub("%.", ""),
        name = name or "New Toolbar",
        enabled = true,
        anchor = {
            target = "main",        -- main | mixer | transport | media_explorer | arrange
            -- Snap mode (preferred way to position):
            --   "left"  → align to target.left  + offset_x
            --   "right" → align to target.right - toolbar_width - offset_x
            --   "free"  → use proportional x (0..1) + offset_x (legacy)
            snap = "left",
            x = 0.0,                -- proportional 0-1 (only used when snap == "free")
            y = 0.0,
            offset_x = 100,
            offset_y = 30,
            hide_when_target_hidden = true,
            -- Auto-hide thresholds: when the target window's width/height
            -- drops below these, the toolbar is hidden until it grows back.
            -- Set to 0 (or nil) to disable.
            auto_hide_min_width  = 0,
            auto_hide_min_height = 0,
        },
        layout = {
            direction = "horizontal", -- horizontal | vertical
            -- "custom" uses icon_size; "theme" ties it to the toolkit's own
            -- control height, so the strip follows the Theme Tweaker along
            -- with every other CP window.
            icon_size_mode = "custom",
            icon_size = 24,
            -- La couleur des glyphes du toolkit, quand ils cotoient des PNG de
            -- REAPER dans la meme barre. "reaper" prend l'encre mesuree sur ces
            -- PNG, "theme" prend la couleur de texte de la suite. Le defaut est
            -- "reaper" parce que le voisinage immediat est ce qui se voit : une
            -- icone plus claire que ses onze voisines se lit comme une erreur
            -- avant de se lire comme une icone.
            builtin_ink = "reaper",   -- reaper | theme
            spacing  = 4,
            padding  = 6,             -- inner padding around icon block
            -- The ground under the icons:
            --   "panel"  one rounded slab behind everything (a toolbar)
            --   "chips"  one rounded chip PER icon (detached buttons)
            --   "none"   nothing but the glyphs
            style = "panel",
            -- Colour keying: makes the window's unpainted pixels genuinely
            -- transparent and click-through, so the strip floats instead of
            -- sitting on a slab. OFF by default, and that is deliberate: when
            -- it does not take (it depends on the window manager honouring a
            -- layered colour key) the key colour shows on screen instead of
            -- disappearing, which is a much worse failure than an opaque
            -- background. Turn it on to try it; the strip is coherent either
            -- way, because "chips" on an opaque ground is exactly what the
            -- command bars in the rest of the suite look like.
            transparent = false,
            bg_color  = { 0.12, 0.12, 0.14 },  -- the panel's colour
            bg_radius = 6,            -- panel corner (0 = sharp)
            bg_border = false,        -- thin border around the panel
            -- Chips have their own colour and corner: a slab and the buttons
            -- inside it are not the same shape and should not share a number.
            chip_color  = nil,        -- nil = the theme's button colour
            chip_radius = nil,        -- nil = the theme's small rounding
            chip_border = false,
            -- Only used when transparent = false: the whole window's opacity.
            -- `bg_alpha` was the old name for a panel fade that could never
            -- fade anything; it is left unread so an existing config does not
            -- suddenly turn near-invisible.
            opacity   = 1.0,
        },
        actions = {},                 -- {{command_id=..., ...}, ...}
    }
end

function Persistence.NewAction(command_id)
    return {
        command_id   = command_id,
        icon         = nil,           -- absolute path to PNG (custom file picker)
        builtin_icon = nil,           -- name from UI.Icons (e.g. "Play", "Stop")
        native_icon  = nil,           -- filename in <resource>/Data/toolbar_icons/
        tooltip      = nil,           -- nil = use action name
    }
end

function Persistence.Load()
    local data = UI.LoadConfig(SCRIPT_ID)
    if type(data) ~= "table" or type(data.toolbars) ~= "table" then
        return default_data()
    end
    return data
end

function Persistence.Save(data)
    UI.SaveConfig(SCRIPT_ID, data)
end

function Persistence.RequestSave()
    pending_save_at = reaper.time_precise() + SAVE_DEBOUNCE
end

function Persistence.ProcessSaveQueue(data)
    if not pending_save_at then return end
    if reaper.time_precise() < pending_save_at then return end
    Persistence.Save(data)
    pending_save_at = nil
end

function Persistence.FlushSave(data)
    if pending_save_at then
        Persistence.Save(data)
        pending_save_at = nil
    end
end

function Persistence.GetToolbarById(data, id)
    if not data or not id then return nil end
    for _, tb in ipairs(data.toolbars) do
        if tb.id == id then return tb end
    end
    return nil
end

function Persistence.GetActiveToolbar(data)
    if not data then return nil end
    if data.active_toolbar_id then
        local tb = Persistence.GetToolbarById(data, data.active_toolbar_id)
        if tb then return tb end
    end
    return data.toolbars[1]
end

return Persistence
