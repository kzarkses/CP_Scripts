-- @description CP ChordLab — timeline chord-block strip (custom draw)
-- @author Cedric Pamalio

-- Renders analysis.segments as a horizontal strip of blocks whose width is
-- proportional to segment duration. Interactions (per ARCHITECTURE.md):
--   click block        → select
--   double-click block → preview its actual sounding pitches
--   click empty slot   → place the armed chord (voice-led) if one is armed
--   Del key            → delete the selected segment
-- Playhead line drawn at GetPlayPosition() while transport is playing.
--
-- Signature: Draw(state, deps, theme). `deps` holds Theory/Voicing/.../App/UI.
-- No table/closure allocation in the per-block loop.

local M = {}

-- Draw the "+" glyph centered in a rect (two strokes; cheaper than a font draw
-- and always crisp).
local function draw_plus(Core, cx, cy, arm, col)
    Core.DrawLine(cx - arm, cy, cx + arm, cy, col[1], col[2], col[3], col[4] or 1)
    Core.DrawLine(cx, cy - arm, cx, cy + arm, col[1], col[2], col[3], col[4] or 1)
end

-- Dashed rectangle outline (empty-slot look). Manual dashes on all four edges.
local function draw_dashed_rect(Core, x, y, w, h, dash, gap, col)
    local r, g, b, a = col[1], col[2], col[3], col[4] or 1
    local x2, y2 = x + w, y + h
    -- Horizontal edges.
    local px = x
    while px < x2 do
        local ex = px + dash
        if ex > x2 then ex = x2 end
        Core.DrawLine(px, y, ex, y, r, g, b, a)
        Core.DrawLine(px, y2, ex, y2, r, g, b, a)
        px = px + dash + gap
    end
    -- Vertical edges.
    local py = y
    while py < y2 do
        local ey = py + dash
        if ey > y2 then ey = y2 end
        Core.DrawLine(x, py, x, ey, r, g, b, a)
        Core.DrawLine(x2, py, x2, ey, r, g, b, a)
        py = py + dash + gap
    end
end

function M.Draw(state, deps, theme)
    local UI = deps.UI
    local Core = UI.Core
    local App = deps.App
    local S = UI.Theme.S

    local strip_h = theme.row_h_large * 2 + theme.pad_small * 2
    local min_block_w = theme.row_h_large

    UI.BeginChild("cl_timeline", 0, strip_h, {
        scrollable = false, scrollable_x = true,
        border = true, padding = theme.pad_small,
        bg = theme.colors.surface,
    })

    local analysis = state.analysis
    local segs = analysis and analysis.segments

    if not segs or #segs == 0 then
        UI.SetFontCaption()
        UI.Text(state.take and "Aucun accord detecte." or "Aucun item MIDI selectionne.",
            { disabled = true })
        UI.SetFontBody()
        UI.EndChild()
        return
    end

    -- Time span of the item (seconds). Fall back to segment extents.
    local t0 = analysis.item_start_time
    local t1 = analysis.item_end_time
    if not t0 or not t1 or t1 <= t0 then
        t0 = segs[1].start_time
        t1 = segs[#segs].end_time
    end
    local span = t1 - t0
    if span <= 0 then span = 1.0 end

    -- Available drawing width inside the child (after padding).
    local avail_w = UI.GetAvailableWidth()
    -- Total natural pixel width if we used px-per-second to fit the item into
    -- avail_w, but never below min_block_w per block. Compute total content
    -- width by summing clamped block widths, then reserve a canvas that wide so
    -- horizontal scroll engages when blocks are numerous.
    local px_per_sec = avail_w / span

    -- First pass: total content width (clamped mins) → reserve canvas.
    local total_w = 0.0
    for i = 1, #segs do
        local seg = segs[i]
        local bw = (seg.end_time - seg.start_time) * px_per_sec
        if bw < min_block_w then bw = min_block_w end
        total_w = total_w + bw
    end

    local canvas = UI.Canvas("cl_tl_canvas", {
        width = math.floor(total_w + 0.5),
        height = strip_h - theme.pad_small * 2,
        bg = theme.colors.surface,
    })
    -- Copy fields (Canvas result is reused next frame).
    local ox, oy = canvas.x, canvas.y
    local ch = canvas.h
    local hovered_canvas = canvas.hovered

    local col_accent = theme.colors.accent
    local col_accent_a = theme.colors.accent_active
    local col_border = theme.colors.border
    local col_soft = theme.colors.border_soft
    local col_frame = theme.colors.frame_bg
    local col_text = theme.colors.text
    local col_mute = theme.colors.text_mute
    local rad = S(theme, 3)
    local pad = theme.pad_small
    local ins = S(theme, 1)         -- hairline inset so adjacent block borders don't merge
    local ins2 = ins * 2

    local clicked_seg = nil
    local dbl_seg = nil

    -- Second pass: draw + hit-test.
    local cx = ox
    for i = 1, #segs do
        local seg = segs[i]
        local bw = (seg.end_time - seg.start_time) * px_per_sec
        if bw < min_block_w then bw = min_block_w end

        local bx = cx
        local by = oy
        local bh = ch
        local selected = (state.selected_seg == i)

        -- Hit test this block (clipped to the child).
        local hit = Core.MouseInClippedRect(bx, by, bw, bh)

        if seg.empty then
            -- Empty placement slot: dashed dim outline + "+".
            local oc = selected and col_accent or col_soft
            draw_dashed_rect(Core, bx + ins, by + ins, bw - ins2, bh - ins2,
                S(theme, 4), S(theme, 3), oc)
            local pcol = selected and col_accent or col_mute
            draw_plus(Core, bx + bw / 2, by + bh / 2, S(theme, 5), pcol)
        else
            -- Filled block.
            local bg_r, bg_g, bg_b, bg_a
            if selected then
                bg_r, bg_g, bg_b, bg_a = col_accent_a[1], col_accent_a[2], col_accent_a[3], col_accent_a[4] or 1
            elseif hit then
                bg_r, bg_g, bg_b, bg_a = col_frame[1], col_frame[2], col_frame[3], (col_frame[4] or 1)
            else
                local sf = theme.colors.surface2
                bg_r, bg_g, bg_b, bg_a = sf[1], sf[2], sf[3], sf[4] or 1
            end
            UI.DrawRoundRect(bx + ins, by + ins, bw - ins2, bh - ins2, rad, bg_r, bg_g, bg_b, bg_a)

            -- Border (accent when selected).
            local brc = selected and col_accent or col_border
            Core.DrawRect(bx + ins, by + ins, bw - ins2, bh - ins2, brc[1], brc[2], brc[3], brc[4] or 1, false)

            -- Chord name (H2 bold) centered horizontally, upper portion.
            -- Read the label cached by App.decorate_segments — never score or
            -- allocate a name string in this per-frame draw loop.
            local nm = seg.display_name or "—"
            UI.SetFontH2Bold()
            local nw, nh = Core.MeasureText(nm)
            -- Truncate to block width.
            if nw > bw - pad * 2 and #nm > 1 then
                nm = Core.TruncateText(nm, bw - pad * 2)
                nw = Core.MeasureText(nm)
            end
            local tx = bx + math.floor((bw - nw) / 2)
            local ty = by + pad
            local tcol = selected and theme.colors.list_selected_text or col_text
            Core.DrawText(nm, tx, ty, tcol[1], tcol[2], tcol[3], tcol[4] or 1)

            -- Roman numeral (caption) below — also read from the segment cache.
            UI.SetFontCaption()
            local rn = seg.roman or ""
            if rn and rn ~= "" then
                local rw, rh = Core.MeasureText(rn)
                if rw <= bw - pad then
                    local rx = bx + math.floor((bw - rw) / 2)
                    local ry = by + bh - pad - rh
                    Core.DrawText(rn, rx, ry, col_mute[1], col_mute[2], col_mute[3], col_mute[4] or 1)
                end
            end
            UI.SetFontBody()
        end

        -- Interaction (only when the canvas itself is hovered so scrollbar drags
        -- don't misfire).
        if hit and hovered_canvas then
            Core.SetHot("cl_tl_" .. i)
            if Core.MouseDoubleClicked() then
                dbl_seg = i
            elseif Core.MouseClicked(1) then
                clicked_seg = i
            end
        end

        cx = cx + bw
    end

    -- Playhead (only while playing) — single line draw.
    local ps = reaper.GetPlayState()
    if ps & 1 == 1 then
        local pp = reaper.GetPlayPosition()
        if pp >= t0 and pp <= t1 then
            local phx = ox + (pp - t0) * px_per_sec
            local pc = theme.colors.value_negative
            Core.DrawLine(phx, oy, phx, oy + ch, pc[1], pc[2], pc[3], pc[4] or 1)
        end
        UI.RequestRedraw()  -- keep animating the playhead while transport runs
    end

    UI.EndChild()

    -- Apply interactions after the child so writes/re-analysis happen outside
    -- the clipped draw region.
    if dbl_seg then
        local seg = segs[dbl_seg]
        App.SelectSegment(dbl_seg)
        if seg and not seg.empty and seg.pitches then
            App.PreviewPitches(seg.pitches)
        end
    elseif clicked_seg then
        local seg = segs[clicked_seg]
        if seg and seg.empty and state.armed and state.armed.chord then
            App.PlaceInSlot(clicked_seg, state.armed.chord)
        else
            App.SelectSegment(clicked_seg)
        end
    end

    -- Del key deletes the selected non-empty segment.
    if state.selected_seg then
        local chcode = Core.GetChar()
        if chcode == UI.Keys.DELETE or chcode == UI.Keys.BACKSPACE then
            App.DeleteSelected()
            UI.ConsumeChar()
        end
    end
end

return M
