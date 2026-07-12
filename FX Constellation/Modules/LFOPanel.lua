-- ============================================================================
-- CP_Scripts — LFOPanel
--
-- Shared CP_Toolkit UI for a CP_Mod bank (8 LFO slots): slot selector grid,
-- per-slot controls, one-cycle waveform preview with the dot riding the
-- curve at the REAL phase (exported by the JSFX as a hidden slider — the
-- out value alone cannot be mapped back to a curve position).
--
-- Used embedded (FX Constellation's LFO section) and standalone
-- (CP_ModLFO.lua popup). The caller provides a ctx:
--   ctx.present  bool           bank instance exists
--   ctx.get(i)   -> slot table  {on, shape, rate, sync, phase, out, ph|nil}
--   ctx.set(i, patch)
--   ctx.add()                   create the bank
--   ctx.sel      int            selected slot (1..8)
--   ctx.onSelect(i)
--   ctx.hint     string|nil     caption shown when the bank is absent
-- ============================================================================

local LFOPanel = {}

LFOPanel.SHAPES = { "Sine", "Triangle", "Saw Up", "Saw Down", "Square", "Random" }
LFOPanel.SYNCS = { "Free", "1/16", "1/8", "1/4", "1/2", "1 bar", "2 bars" }

function LFOPanel.init(toolkit)
	LFOPanel.tk = toolkit
end

-- Same defaults as FX Constellation's widget helpers: fill width, uniform
-- button-height rows.
local function opts(theme, o)
	o = o or {}
	if o.width == nil then o.width = -1 end
	if o.height == nil then o.height = theme.button_height end
	return o
end

-- Mirror of the JSFX slot shapes for the preview curve.
local function shapeValue(shape, p)
	if shape == 5 then
		local c = math.floor(p)
		local x = math.sin(c * 78.233 + 12.9898) * 43758.5453
		return x - math.floor(x)
	end
	p = p % 1
	if shape == 0 then return 0.5 + 0.5 * math.sin(p * 2 * math.pi)
	elseif shape == 1 then return p < 0.5 and 2 * p or 2 - 2 * p
	elseif shape == 2 then return p
	elseif shape == 3 then return 1 - p
	else return p < 0.5 and 1 or 0 end
end

function LFOPanel.draw(theme, ctx)
	local UItk = LFOPanel.tk

	if not ctx.present then
		UItk.SetFontCaption()
		UItk.TextWrapped(ctx.hint or
			"CP_Mod bank not on this track yet.")
		UItk.SetFontBody()
		if UItk.Button("lfopanel_add", "Add LFO Bank", opts(theme)) then
			ctx.add()
		end
		return
	end

	-- Slot selector: 8 square cells — click to select; the number is bright
	-- when the slot is enabled.
	local sel = ctx.sel or 1
	local cell = math.floor(theme.button_height * 1.1)
	UItk.BeginGrid("lfopanel_slots", { cell_w = cell, cell_h = cell, gap = theme.item_spacing })
	for i = 1, 8 do
		local x, y, w, h = UItk.GridCell("lfopanel_slots")
		local slot_i = ctx.get(i)
		local active = sel == i
		local hovered = UItk.Core.MouseInRect(x, y, w, h) and not UItk.Core.HasPopup()
		local bg = active and theme.colors.accent
			or (hovered and theme.colors.button_hovered or theme.colors.frame_bg)
		UItk.Core.DrawRect(x, y, w, h, bg[1], bg[2], bg[3], bg[4] or 1)
		local bc = theme.colors.border
		UItk.Core.DrawRect(x, y, w, h, bc[1], bc[2], bc[3], bc[4] or 0.4, false)
		local tc = (slot_i and slot_i.on) and theme.colors.text or theme.colors.text_disabled
		local label = tostring(i)
		local tw, th = UItk.Core.MeasureText(label)
		UItk.Core.DrawText(label, x + math.floor((w - tw) / 2), y + math.floor((h - th) / 2),
			tc[1], tc[2], tc[3], 1)
		if hovered and UItk.Core.MouseClicked(1) then
			ctx.onSelect(i)
		end
	end
	UItk.EndGrid("lfopanel_slots")

	local slot = ctx.get(sel)
	if not slot then return end

	local tc2, on2 = UItk.ToggleButton("lfopanel_on",
		slot.on and "● ON" or "○ OFF", slot.on, opts(theme))
	if tc2 then ctx.set(sel, { on = on2 }) end

	local sc, si = UItk.Combo("lfopanel_shape", "Shape", slot.shape + 1,
		LFOPanel.SHAPES, opts(theme))
	if sc then ctx.set(sel, { shape = si - 1 }) end

	local yc, yi = UItk.Combo("lfopanel_sync", "Sync", slot.sync + 1,
		LFOPanel.SYNCS, opts(theme))
	if yc then ctx.set(sel, { sync = yi - 1 }) end

	if slot.sync == 0 then
		local rmin, rmax = math.log(0.01), math.log(20)
		local norm = (math.log(math.max(0.01, slot.rate)) - rmin) / (rmax - rmin)
		local rc, rv = UItk.SliderDouble("lfopanel_rate", "Rate", norm, 0, 1,
			opts(theme, { format = string.format("%.2f Hz", slot.rate) }))
		if rc then
			ctx.set(sel, { rate = math.exp(rmin + rv * (rmax - rmin)) })
		end
	end

	local pc, pv = UItk.SliderDouble("lfopanel_phase", "Phase", slot.phase, 0, 1,
		opts(theme, { format = string.format("%.2f", slot.phase) }))
	if pc then ctx.set(sel, { phase = pv }) end

	-- One-cycle preview. X axis = raw slot phase; the curve is drawn with
	-- the phase offset applied (same math as the JSFX), so the dot placed
	-- at (raw phase, live out) rides the drawn curve exactly.
	local w = UItk.GetAvailableWidth()
	local hgt = math.floor(theme.button_height * 2.5)
	if w > 40 then
		local canvas = UItk.Canvas("lfopanel_prev", { width = w, height = hgt })
		local segs = 48
		local col = theme.colors.accent
		local alpha = slot.on and 1 or 0.35
		local px, py
		for i2 = 0, segs do
			local p = i2 / segs
			local v = shapeValue(slot.shape, p + slot.phase)
			local x = canvas.x + p * canvas.w
			local y = canvas.y + (1 - v) * (canvas.h - 4) + 2
			if px then
				UItk.Core.DrawLine(px, py, x, y, col[1], col[2], col[3], alpha)
			end
			px, py = x, y
		end
		local tcol = theme.colors.text
		if slot.ph then
			local dx = canvas.x + (slot.ph % 1) * canvas.w
			local dy = canvas.y + (1 - (slot.out or 0.5)) * (canvas.h - 4) + 2
			UItk.DrawCircle(dx, dy, 4, tcol[1], tcol[2], tcol[3], 1, true)
		else
			-- Old bank instance without the phase-display slider (recompiles
			-- on project reload): fall back to a level marker on the edge.
			local oy = canvas.y + (1 - (slot.out or 0.5)) * (canvas.h - 4) + 2
			UItk.DrawCircle(canvas.x + canvas.w - 6, oy, 4, tcol[1], tcol[2], tcol[3], 1, true)
		end
	end

	-- The dot moves on its own — keep the loop alive while an enabled slot
	-- is displayed.
	if slot.on then
		UItk.RequestRedrawAt(reaper.time_precise() + 1 / 30)
	end
end

return LFOPanel
