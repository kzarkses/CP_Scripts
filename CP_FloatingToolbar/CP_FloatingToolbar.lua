-- @description CP Floating Toolbar — frameless icon strip anchored to a REAPER window
-- @version 0.1
-- @author Cedric Pamalio
--
-- Renders the active toolbar (from CP_Config/CP_FloatingToolbar.lua) as a
-- frameless, topmost overlay anchored to a target REAPER window. Uses
-- CP_Toolkit (native gfx) — no ReaImGui dependency.
--
-- Right-click anywhere on the toolbar → opens the manager.

local r = reaper

local script_path  = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local toolkit_path = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Toolkit/CP_Toolkit.lua"

local UI          = dofile(toolkit_path)
local Persistence = dofile(script_path .. "Modules/Persistence.lua")
local Actions     = dofile(script_path .. "Modules/Actions.lua")

Persistence.Init(UI)

local data    = Persistence.Load()
local toolbar = Persistence.GetActiveToolbar(data)

if not toolbar or #toolbar.actions == 0 then
    r.MB(
        "No floating toolbar configured yet.\n\nRun CP_FloatingToolbarManager to create one and add actions.",
        "CP Floating Toolbar",
        0
    )
    return
end

-- ---------------------------------------------------------------------------
-- Layout helpers
-- ---------------------------------------------------------------------------
-- The icon's box. `icon_size_mode = "theme"` ties it to the toolkit's own
-- control height, so the floating strip grows and shrinks with the rest of the
-- suite when the size is changed in the Theme Tweaker — which is the point:
-- a toolbar that stays 30 px while every window moves to 28 stops belonging.
local function icon_size_of(tb)
    if tb.layout.icon_size_mode == "theme" then
        local t = UI.GetTheme and UI.GetTheme()
        if t and t.button_height then return t.button_height end
        return 24
    end
    return tb.layout.icon_size or 24
end

local function compute_window_size(tb)
    local n = #tb.actions
    local s = icon_size_of(tb)
    local g = tb.layout.spacing
    local p = tb.layout.padding
    if tb.layout.direction == "vertical" then
        return s + p * 2, n * s + (n - 1) * g + p * 2
    else
        return n * s + (n - 1) * g + p * 2, s + p * 2
    end
end

local function action_rect(tb, idx)
    local s = icon_size_of(tb)
    local g = tb.layout.spacing
    local p = tb.layout.padding
    if tb.layout.direction == "vertical" then
        return p, p + (idx - 1) * (s + g), s, s
    else
        return p + (idx - 1) * (s + g), p, s, s
    end
end

-- Resolve the image source for an action, preferring (in order):
--   1. action.icon         — absolute PNG path picked by the user
--   2. action.native_icon   — filename relative to <resource>/Data/toolbar_icons/
-- Returns the loaded image (or nil if none/load failed). Cached on the action
-- table so we don't re-resolve every frame.
local function get_image_for_action(action)
    if action._cached_image == false then return nil end
    if action._cached_image then return action._cached_image end

    local path = nil
    if action.icon and action.icon ~= "" and r.file_exists(action.icon) then
        path = action.icon
    elseif action.native_icon and action.native_icon ~= "" then
        local p = r.GetResourcePath() .. "/Data/toolbar_icons/" .. action.native_icon
        if r.file_exists(p) then path = p end
    end

    if path then
        local img = UI.LoadImage(path)
        action._cached_image = img or false
        return img
    end
    action._cached_image = false
    return nil
end

-- ---------------------------------------------------------------------------
-- Init the gfx window — sized to the icon strip
-- ---------------------------------------------------------------------------
local win_w, win_h = compute_window_size(toolbar)

UI.Init("CP Floating Toolbar", win_w, win_h, {
    frameless    = true,
    -- topmost = false: the toolbar sits at REAPER's normal Z-order so
    -- VST UIs, dialogs and other windows can naturally appear in front
    -- of it. Combined with hide-when-target-unfocused, this means the
    -- toolbar only shows over REAPER's own UI surface.
    topmost      = false,
    scrollable   = false,
    padding      = 0,
    x            = 100,
    y            = 100,
})

-- Build the anchor opts table from a toolbar config — used at init, on
-- reload, and during drag. Keeps all anchor params in one place.
local function anchor_opts(tb)
    return {
        target               = tb.anchor.target,
        snap                 = tb.anchor.snap or "free",
        x                    = tb.anchor.x,
        y                    = tb.anchor.y,
        offset_x             = tb.anchor.offset_x,
        offset_y             = tb.anchor.offset_y,
        hide_when_target_hidden = tb.anchor.hide_when_target_hidden,
        auto_hide_min_width  = tb.anchor.auto_hide_min_width or 0,
        auto_hide_min_height = tb.anchor.auto_hide_min_height or 0,
    }
end

-- The theme is only loaded by UI.Init, so an icon size that FOLLOWS the theme
-- could not be known when the window was created. Re-assert it now that it can
-- be; the size loop in Core converges it either way.
win_w, win_h = compute_window_size(toolbar)
UI.SetSize(win_w, win_h)

UI.SetAnchor(anchor_opts(toolbar))

-- A colour that no icon and no theme will ever contain, so keying it out
-- cannot eat part of a glyph. Magenta is the convention for exactly this.
local KEY_COLOR = { 1, 0, 1 }

-- Three grounds, and the difference between them is the whole look:
--   "panel"  one rounded slab behind everything      (a toolbar)
--   "chips"  one rounded chip PER ICON               (detached buttons)
--   "none"   nothing at all, just the glyphs         (floating icons)
--
-- All three need the window to disappear where nothing is painted, which is a
-- COLOUR KEY: Windows makes every pixel of one exact colour transparent and
-- click-through. It is the only mechanism that does — a gfx window has no
-- per-pixel alpha — and it has a second effect worth as much: the window's
-- SIZE stops mattering. Whatever is not painted is keyed out, so a window that
-- opened larger than its content shows nothing extra.
--
-- `transparent = false` goes back to a plain opaque window for anyone who
-- wants the strip to read as a solid panel.
local function apply_look(tb)
    local L = tb.layout
    -- Absent means OFF. An existing config predates the key and must not
    -- suddenly start clearing to a colour that may not be removed.
    if not L.transparent then
        UI.SetColorKey(nil)
        UI.SetClearColor(L.bg_color)
        local o = L.opacity
        if o == nil then o = 1 end
        if o < 0.2 then o = 0.2 end   -- one you cannot see is one you cannot click
        UI.SetWindowOpacity(o)
    else
        UI.SetWindowOpacity(1)
        -- The clear stays the strip's own colour as a fallback. The key is
        -- applied as soon as the window exists to take it; until then (and if
        -- JS_ReaScriptAPI is missing, forever) the strip simply reads as an
        -- opaque panel instead of a magenta rectangle.
        UI.SetClearColor(L.bg_color)
        UI.SetColorKey(KEY_COLOR)
    end
end

apply_look(toolbar)

-- Periodic config reload — pick up edits from the manager without restart.
-- 0.25s feels responsive without burning CPU on dofile/disk reads.
local last_reload = 0
local RELOAD_INTERVAL = 0.25
local last_signature = ""

local function toolbar_signature(tb)
    if not tb then return "" end
    local parts = {
        tb.id, tb.layout.direction, tb.layout.icon_size, tb.layout.spacing,
        -- Every entry needs a value: a nil would punch a hole in the array and
        -- table.concat would stop there, so the signature would stop changing
        -- and the hot-reload would go quiet. `opacity` is new, so it is the
        -- one that would have been nil in every existing config.
        tb.layout.padding, tb.layout.opacity or 1,
        tb.layout.icon_size_mode or "custom",
        tb.layout.style or "panel", tb.layout.transparent and 1 or 0,
        tb.layout.bg_radius or 0, tb.layout.bg_border and 1 or 0,
        tb.layout.bg_color and table.concat(tb.layout.bg_color, ",") or "",
        tb.layout.chip_radius or -1, tb.layout.chip_border and 1 or 0,
        tb.layout.chip_color and table.concat(tb.layout.chip_color, ",") or "",
        tb.anchor.target,
        tb.anchor.snap or "free",
        tb.anchor.x, tb.anchor.y, tb.anchor.offset_x, tb.anchor.offset_y,
        tb.anchor.auto_hide_min_width or 0,
        tb.anchor.auto_hide_min_height or 0,
        tb.anchor.hide_when_target_hidden ~= false and 1 or 0,
        #tb.actions,
    }
    for _, a in ipairs(tb.actions) do
        -- native_icon belongs here too: picking a REAPER icon in the manager
        -- changed only that field, so the signature stayed identical and the
        -- running toolbar never noticed. The icon only appeared on restart.
        parts[#parts + 1] = tostring(a.command_id) .. "|" ..
                            tostring(a.icon or "") .. "|" ..
                            tostring(a.builtin_icon or "") .. "|" ..
                            tostring(a.native_icon or "")
    end
    return table.concat(parts, ":")
end
last_signature = toolbar_signature(toolbar)

local function maybe_reload()
    local now = r.time_precise()
    if (now - last_reload) < RELOAD_INTERVAL then return end
    last_reload = now

    local fresh = Persistence.Load()
    local fresh_tb = Persistence.GetActiveToolbar(fresh)
    if not fresh_tb then return end
    local sig = toolbar_signature(fresh_tb)
    if sig == last_signature then return end

    data = fresh
    toolbar = fresh_tb
    last_signature = sig

    -- Recompute window size in case action count, icon size, padding or
    -- direction changed — and resize the gfx window in place.
    win_w, win_h = compute_window_size(toolbar)
    UI.SetSize(win_w, win_h)

    UI.SetAnchor(anchor_opts(toolbar))
    apply_look(toolbar)
end

-- ---------------------------------------------------------------------------
-- Toggle-state polling — calling reaper.GetToggleCommandState for every
-- icon every frame is cheap individually but adds up on a 2005-era CPU
-- when the toolbar is idle (60Hz × N icons forever). We poll at ~5Hz
-- instead and cache the result. When any state changes we ask the toolkit
-- to redraw so the visual catches up immediately even under idle throttle.
-- ---------------------------------------------------------------------------
local STATE_POLL_INTERVAL = 0.2
local last_state_poll = 0
local state_cache = {}  -- command_id (string) → 0 / 1 / -1

local function poll_states_if_due(actions)
    local now = r.time_precise()
    if (now - last_state_poll) < STATE_POLL_INTERVAL then return end
    last_state_poll = now

    local any_changed = false
    for _, action in ipairs(actions) do
        local key = tostring(action.command_id)
        local fresh = Actions.GetState(action.command_id)
        if state_cache[key] ~= fresh then
            state_cache[key] = fresh
            any_changed = true
        end
    end
    if any_changed then UI.RequestRedraw() end
end

-- ---------------------------------------------------------------------------
-- Drag state — middle-click anywhere drags the whole toolbar by adjusting
-- the anchor offset. Saved on release.
-- ---------------------------------------------------------------------------
local drag = { active = false, start_mouse_x = 0, start_mouse_y = 0 }

local function dirty_save()
    -- Update the on-disk file with the latest offsets so the manager
    -- (and the next launch) reflects the dragged position.
    local fresh = Persistence.Load()
    local tb = Persistence.GetActiveToolbar(fresh)
    if not tb then return end
    tb.anchor.offset_x = toolbar.anchor.offset_x
    tb.anchor.offset_y = toolbar.anchor.offset_y
    Persistence.Save(fresh)
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
UI.Run(function(theme)
    maybe_reload()

    local tb = toolbar

    poll_states_if_due(tb.actions)

    -- The REAL window size, not the size we asked for: gfx does not always
    -- open at the requested dimensions (the geometry is remembered per window
    -- name) and the frameless resize lands a frame or two later.
    local L = tb.layout
    local style = L.style or "panel"
    local radius = L.bg_radius or 0
    local bg = L.bg_color or theme.colors.surface

    -- Under a key, everything starts transparent and we paint what should
    -- exist. Without one, the window is already the ground and we only add the
    -- border. Either way the STRIP's box is computed, never the window's — so
    -- an oversized window cannot show as an oversized panel.
    local strip_w, strip_h = compute_window_size(tb)

    -- No explicit fill of the keyed area: Core.SetColorKey made the key the
    -- window's CLEAR colour, so the toolkit has already painted every pixel we
    -- want gone. One less full-window fill per frame.

    if style == "panel" then
        -- Painted whether or not the key took: without it the clear is already
        -- this colour, so it costs one rect and it is what makes the corner
        -- rounding show up the moment the key does land.
        UI.Core.DrawRoundRectFilled(0, 0, strip_w, strip_h, radius,
                                    bg[1], bg[2], bg[3], 1)
        if L.bg_border then
            local bc = theme.colors.border
            if radius > 0 then
                UI.DrawRoundRect(0, 0, strip_w - 1, strip_h - 1, radius,
                                 bc[1], bc[2], bc[3], 0.6)
            else
                UI.Core.DrawRect(0, 0, strip_w, 1, bc[1], bc[2], bc[3], 0.6)
                UI.Core.DrawRect(0, strip_h - 1, strip_w, 1, bc[1], bc[2], bc[3], 0.6)
                UI.Core.DrawRect(0, 0, 1, strip_h, bc[1], bc[2], bc[3], 0.6)
                UI.Core.DrawRect(strip_w - 1, 0, 1, strip_h, bc[1], bc[2], bc[3], 0.6)
            end
        end
    end

    -- Drag handling: Ctrl+left-click anywhere on the toolbar starts a drag.
    -- We work in SCREEN coords (reaper.GetMousePosition) — using
    -- gfx.mouse_x/y here would feed back into itself, since the window
    -- moves under the cursor each frame and gfx coords are window-local.
    -- The drag zone is the STRIP, not the window: the window may be larger,
    -- and under a colour key its extra area is transparent and click-through,
    -- so a Ctrl-click out there never reaches us anyway.
    local screen_mx, screen_my = reaper.GetMousePosition()
    if not drag.active and UI.Core.MouseInRect(0, 0, strip_w, strip_h)
       and UI.Core.MouseClicked(1) and UI.Core.ModCtrl() then
        drag.active = true
        drag.start_mouse_x = screen_mx
        drag.start_mouse_y = screen_my
    end

    if drag.active then
        UI.SetCursor("size_all")
        local dx = screen_mx - drag.start_mouse_x
        local dy = screen_my - drag.start_mouse_y
        if dx ~= 0 or dy ~= 0 then
            -- For "right" snap, dragging right should move the window right,
            -- which means *decreasing* offset_x (since offset is measured
            -- from the right edge inward). Mirror the X delta in that case.
            local snap = tb.anchor.snap or "free"
            local sign_x = (snap == "right") and -1 or 1
            tb.anchor.offset_x = (tb.anchor.offset_x or 0) + dx * sign_x
            tb.anchor.offset_y = (tb.anchor.offset_y or 0) + dy
            UI.SetAnchor(anchor_opts(tb))
            drag.start_mouse_x = screen_mx
            drag.start_mouse_y = screen_my
        end
        if UI.Core.MouseReleased(1) then
            drag.active = false
            dirty_save()
        end
    end

    -- The chip's own corner, separate from the panel's: a slab and the buttons
    -- inside it are not the same shape and should not share a number.
    local rad = L.chip_radius or theme.rounding_small or 0
    local chips = (style == "chips")
    local C = theme.colors

    for i, action in ipairs(tb.actions) do
        local x, y, w, h = action_rect(tb, i)
        local hovered = UI.Core.MouseInRect(x, y, w, h)
        local down = hovered and UI.Core.MouseDown(1)
        local is_on = state_cache[tostring(action.command_id)] == 1

        -- The same four states as everywhere else in the suite. What differs
        -- is the REST state: on a panel or on nothing, rest is unpainted (a
        -- row of chips over the arrange would fight the track lanes for
        -- attention); in "chips" style rest IS the chip, because the whole
        -- point of that style is buttons that read as separate objects.
        local fill, alpha
        if is_on then
            fill = C.accent
            alpha = down and 0.95 or 0.85
        elseif down then
            fill = C.button_active
            alpha = chips and 1 or 0.55
        elseif hovered then
            fill = C.button_hovered or C.button
            alpha = chips and 1 or 0.35
        elseif chips then
            fill = L.chip_color or C.button
            alpha = 1
        end
        if fill then
            UI.Core.DrawRoundRectFilled(x, y, w, h, rad,
                                        fill[1], fill[2], fill[3], alpha)
        end
        if chips and L.chip_border then
            local bc = C.border
            UI.DrawRoundRect(x, y, w - 1, h - 1, rad, bc[1], bc[2], bc[3], 0.7)
        end

        -- Icon: PNG if provided, otherwise builtin Icons table, otherwise label initials
        local img = get_image_for_action(action)
        if img then
            -- REAPER toolbar convention: 3 horizontal states (normal/hover/
            -- active) when the image is roughly 3× wider than tall. Pick
            -- the slot that matches the current button state. For non-3:1
            -- images we just blit the whole thing.
            local sx, sy, sw, sh = 0, 0, img.w, img.h
            local ratio = img.h > 0 and (img.w / img.h) or 1
            if ratio > 2.5 and ratio < 3.5 then
                local cell_w = math.floor(img.w / 3)
                local state_idx = 0  -- normal
                if is_on then state_idx = 2          -- active
                elseif hovered then state_idx = 1    -- hover
                end
                sx, sw = state_idx * cell_w, cell_w
            elseif ratio > 1.6 and ratio < 2.4 then
                local cell_w = math.floor(img.w / 2)
                local state_idx = (hovered or is_on) and 1 or 0
                sx, sw = state_idx * cell_w, cell_w
            end
            -- gfx.blit modulates the source pixels by gfx.r/g/b/a. The
            -- previous DrawRect call left those at the hover-tint values
            -- (white * 0.25), which would dim every blit drawn after.
            -- Reset to opaque white so the icon shows at full intensity.
            gfx.set(1, 1, 1, 1)
            gfx.blit(img.buffer, 1, 0, sx, sy, sw, sh, x, y, w, h)
        elseif action.builtin_icon and UI.Icons[action.builtin_icon] then
            -- Le glyphe remplit sa case, sans marge, et il la tient de
            -- action_rect — pas de tb.layout.icon_size.
            --
            -- La marge de 15 % venait d'une convention de bouton, mais elle
            -- n'a pas de sens ici : un PNG REAPER a cote remplit toute la
            -- case, donc le glyphe paraissait plus petit ET plus flou que son
            -- voisin. A une case de 21 px elle laissait 15 px de glyphe, la
            -- moitie de ce que le selecteur montre — et un trait Lucide fait
            -- 2/24 de la case, donc perdre 30 % de la case perd 30 % du trait.
            -- Le dessin garde son propre retrait de toute facon : Lucide dessine
            -- dans 2..22 de son carre de 24.
            --
            -- La taille venait de tb.layout.icon_size, que `icon_size_mode =
            -- "theme"` rend faux : la case est calculee par icon_size_of, le
            -- glyphe l'etait par le champ brut, et les deux divergent des que
            -- la taille suit le theme.
            local ic = is_on and theme.colors.accent_hovered or theme.colors.text
            UI.Icons[action.builtin_icon](x, y, w, ic[1], ic[2], ic[3], ic[4] or 1)
        else
            -- Fallback: text glyph (first letter of action name)
            local name = Actions.GetName(action.command_id)
            local glyph = (name:gsub("^Custom: ", ""):gsub("^Script: ", "")):sub(1, 2)
            UI.Core.DrawText(glyph, x + 2, y + 2,
                theme.colors.text[1], theme.colors.text[2], theme.colors.text[3], 1)
        end

        -- Click handling — skip during drag (Ctrl held)
        if hovered and not drag.active then
            UI.SetCursor("hand")
            if UI.Core.MouseClicked(1) and not UI.Core.ModCtrl() then
                Actions.Execute(action.command_id)
            end
        end
    end

end)
