-- @description CP ChordLab — fretboard canvas (custom draw)
-- @author Cedric Pamalio

-- Guitar fretboard input surface. Layout (ARCHITECTURE.md):
--   6 strings drawn HORIZONTALLY, LOW string (E) at the BOTTOM (tab-view);
--   frets 0..FRETS run left→right; nut zone left of fret 1 cycles the string
--   between open (○) and mute (✕); clicking a fret cell toggles the finger dot;
--   low strings drawn slightly thicker (gauge); capo drawn as a bar when > 0;
--   inlays at 3/5/7/9/12/15 (double dot at 12).
-- Under the board: detected chord name (H1) + top-3 alternate reading chips,
-- and buttons Ecouter / Effacer / Ecrire au curseur.
--
-- Signature: Draw(state, deps, theme).
-- state.fret is a Fretboard.New(...) model; string index 1 = LOW string.
-- fingers[s]: -1 muted, 0 open, n≥1 absolute fret. Capo lives in state.fret.capo.

local M = {}

local NUM_STRINGS = 6
local FRETS = 15               -- fret 0 (open zone) .. FRETS
local INLAYS = { [3] = true, [5] = true, [7] = true, [9] = true, [15] = true }
local DOUBLE_INLAY = 12

-- Scratch reused every frame (no per-frame table alloc for the string y coords).
local string_y = {}

function M.Draw(state, deps, theme)
    local UI = deps.UI
    local Core = UI.Core
    local Theory = deps.Theory
    local Fretboard = deps.Fretboard
    local App = deps.App
    local S = UI.Theme.S

    local fret = state.fret
    local capo = fret.capo or 0

    -- --- Board canvas ---
    local avail_w = UI.GetAvailableWidth()
    -- Reserve height for the board plus the readout + buttons below.
    local board_h = theme.row_h_large * NUM_STRINGS + theme.pad_large * 2
    local canvas = UI.Canvas("cl_fb_canvas", {
        width = avail_w,
        height = board_h,
        bg = theme.colors.frame_bg,
    })
    local ox, oy = canvas.x, canvas.y
    local cw, ch = canvas.w, canvas.h
    local hovered_canvas = canvas.hovered

    -- Geometry: a left nut zone, then FRETS columns.
    local nut_w = S(theme, 26)
    local board_x = ox + nut_w
    local board_w = cw - nut_w - theme.pad_small
    if board_w < S(theme, 60) then board_w = S(theme, 60) end
    local fret_w = board_w / FRETS
    local hair = S(theme, 1)        -- one scaled hairline for thickness offsets

    -- String rows: string 1 (LOW) at the BOTTOM. Row 1 top of board = HIGH.
    local top = oy + theme.pad_small
    local bottom = oy + ch - theme.pad_small
    local usable_h = bottom - top
    local row_step = usable_h / (NUM_STRINGS - 1)
    -- Visual string index sv (top→bottom, 1..6): map to model string s.
    -- Model s=1 is LOW → must be at bottom → sv = NUM_STRINGS. So:
    --   model s ↔ y = bottom - (s-1)*row_step.
    for s = 1, NUM_STRINGS do
        string_y[s] = bottom - (s - 1) * row_step
    end

    local col_line = theme.colors.separator
    local col_nut = theme.colors.border
    local col_inlay = theme.colors.text_mute
    local col_dot = theme.colors.accent
    local col_open = theme.colors.text
    local col_mute = theme.colors.danger
    local col_capo = theme.colors.bypass
    local col_lbl = theme.colors.text_mute

    -- --- Fret wires (vertical lines) ---
    for f = 0, FRETS do
        local fx = board_x + f * fret_w
        local a = (f == 0) and 1.0 or (col_line[4] or 0.5)
        local lc = (f == 0) and col_nut or col_line
        -- Nut (f==0) thicker: draw twice offset by 1px.
        Core.DrawLine(fx, top, fx, bottom, lc[1], lc[2], lc[3], a)
        if f == 0 then
            Core.DrawLine(fx + hair, top, fx + hair, bottom, lc[1], lc[2], lc[3], a)
        end
    end

    -- --- Inlays (fret-space dots between wires) ---
    local inlay_y = (top + bottom) / 2
    for f = 1, FRETS do
        local mid = board_x + (f - 0.5) * fret_w
        if f == DOUBLE_INLAY then
            local off = row_step * 0.7
            UI.DrawCircle(mid, inlay_y - off, S(theme, 3), col_inlay[1], col_inlay[2], col_inlay[3], col_inlay[4] or 1, true)
            UI.DrawCircle(mid, inlay_y + off, S(theme, 3), col_inlay[1], col_inlay[2], col_inlay[3], col_inlay[4] or 1, true)
        elseif INLAYS[f] then
            UI.DrawCircle(mid, inlay_y, S(theme, 3), col_inlay[1], col_inlay[2], col_inlay[3], col_inlay[4] or 1, true)
        end
    end

    -- --- Strings (horizontal lines, gauge-differentiated) ---
    -- String 1 (LOW) is thickest. Draw extra offset lines for thickness.
    for s = 1, NUM_STRINGS do
        local sy = string_y[s]
        -- Low strings (s small) thicker: 1..3 low get +1 line.
        local thickness = (s <= 3) and 2 or 1
        for t = 0, thickness - 1 do
            Core.DrawLine(board_x, sy + t, ox + cw - theme.pad_small, sy + t,
                col_line[1], col_line[2], col_line[3], col_line[4] or 1)
        end
    end

    -- --- Capo bar (vertical, at fret = capo) ---
    if capo > 0 and capo <= FRETS then
        local cxp = board_x + (capo - 0.5) * fret_w
        Core.DrawRect(cxp - S(theme, 2), top, S(theme, 4), usable_h,
            col_capo[1], col_capo[2], col_capo[3], col_capo[4] or 1, true)
    end

    -- --- Fret number labels (small, under fret 3/5/7/9/12/15) ---
    UI.SetFontCaption()
    for f = 1, FRETS do
        if INLAYS[f] or f == DOUBLE_INLAY then
            local mid = board_x + (f - 0.5) * fret_w
            local lbl = string.format("%d", f)  -- f is an integer literal loop var
            local lw = Core.MeasureText(lbl)
            Core.DrawText(lbl, mid - lw / 2, bottom + S(theme, 1),
                col_lbl[1], col_lbl[2], col_lbl[3], col_lbl[4] or 1)
        end
    end
    UI.SetFontBody()

    -- --- Finger dots + open/mute markers ---
    local dot_r = math.floor(row_step * 0.32)
    if dot_r < S(theme, 4) then dot_r = S(theme, 4) end
    for s = 1, NUM_STRINGS do
        local sy = string_y[s]
        local v = fret.fingers[s]
        -- Nut-zone marker (open / mute).
        local nut_cx = ox + nut_w / 2
        if v == -1 then
            -- Mute: an X.
            local a = S(theme, 4)
            Core.DrawLine(nut_cx - a, sy - a, nut_cx + a, sy + a, col_mute[1], col_mute[2], col_mute[3], 1)
            Core.DrawLine(nut_cx - a, sy + a, nut_cx + a, sy - a, col_mute[1], col_mute[2], col_mute[3], 1)
        elseif v == 0 then
            -- Open: a ring.
            UI.DrawCircle(nut_cx, sy, S(theme, 5), col_open[1], col_open[2], col_open[3], col_open[4] or 1, false)
        end
        -- Fretted dot.
        if v and v >= 1 and v <= FRETS then
            local dx = board_x + (v - 0.5) * fret_w
            UI.DrawCircle(dx, sy, dot_r, col_dot[1], col_dot[2], col_dot[3], 1, true)
        end
    end

    -- --- Hit testing ---
    -- Determine which string a click landed on (nearest row) and which fret.
    local changed = false
    if hovered_canvas and Core.MouseClicked(1) then
        local mx, my = Core.GetMousePos()
        -- Nearest string.
        local best_s, best_d = nil, nil
        for s = 1, NUM_STRINGS do
            local d = my - string_y[s]
            if d < 0 then d = -d end
            if not best_d or d < best_d then best_d = d; best_s = s end
        end
        if best_s and best_d <= row_step * 0.6 then
            if mx < board_x then
                -- Nut zone: cycle open ↔ mute.
                local cur = fret.fingers[best_s]
                Fretboard.SetFinger(fret, best_s, (cur == 0) and -1 or 0)
                changed = true
            else
                local f = math.floor((mx - board_x) / fret_w) + 1
                if f >= 1 and f <= FRETS then
                    -- Clamp fretted values above the capo.
                    if f <= capo then f = capo + 1 end
                    local cur = fret.fingers[best_s]
                    if cur == f then
                        -- Toggle off → open.
                        Fretboard.SetFinger(fret, best_s, 0)
                    else
                        Fretboard.SetFinger(fret, best_s, f)
                    end
                    changed = true
                end
            end
        end
    end

    -- --- Readout: detected name (H1) + top-3 alternate chips ---
    UI.Spacing(theme.gap)
    local cands, pitches = App.FretReadings()
    local main_name = "—"
    if cands and cands[1] then main_name = cands[1].name or "—" end

    UI.SetFontH1()
    UI.Text(main_name)
    UI.SetFontBody()

    -- Alternate readings (indices 2..4) as clickable chips.
    if cands and #cands > 1 then
        UI.SetFontCaption()
        UI.BeginWrap("cl_fb_alts", { gap = theme.gap })
        local shown = 0
        for i = 2, #cands do
            if shown >= 3 then break end
            local c = cands[i]
            local lbl = c.name or "?"
            if UI.Button("cl_fb_alt_" .. i, lbl) then
                -- Arm & preview this alternate reading's chord.
                if c.chord then
                    App.ArmChord(c.chord, "fret", pitches)
                end
            end
            shown = shown + 1
        end
        UI.EndWrap()
        UI.SetFontBody()
    end

    -- --- Buttons ---
    UI.Spacing(theme.gap)
    if UI.Button("cl_fb_play", "Ecouter") then
        if pitches and #pitches > 0 then App.PreviewPitches(pitches) end
    end
    UI.SameLine(theme.gap)
    if UI.Button("cl_fb_clear", "Effacer") then
        Fretboard.Clear(fret)
        state.armed = nil
        changed = true  -- route through OnFretChanged so the readings cache refreshes
    end
    UI.SameLine(theme.gap)
    if UI.Button("cl_fb_write", "Ecrire au curseur") then
        local chord = cands and cands[1] and cands[1].chord or nil
        if chord or (pitches and #pitches > 0) then
            App.WriteAtCursor(chord, pitches)
        end
    end

    -- Tuning combo (compact) under the buttons.
    UI.SameLine(theme.gap_large)
    local tunings = Fretboard.TUNINGS
    local titems = M._tuning_items(tunings)
    local tchg, tnew = UI.Combo("cl_fb_tuning", "", state.cfg.tuning, titems, { width = S(theme, 110) })
    if tchg then
        App.ApplyTuning(tnew)
    end

    -- Apply the finger change AFTER drawing so App can detect/arm/preview once.
    if changed then
        App.OnFretChanged()
    end
end

-- Build the tuning-name item list once (cached on the module).
M._tuning_cache = nil
function M._tuning_items(tunings)
    if M._tuning_cache and M._tuning_cache_n == #tunings then
        return M._tuning_cache
    end
    local out = {}
    for i = 1, #tunings do
        out[i] = tunings[i].name or ("Tuning " .. string.format("%d", i))
    end
    M._tuning_cache = out
    M._tuning_cache_n = #tunings
    return out
end

return M
