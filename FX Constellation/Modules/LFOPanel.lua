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

-- ---------------------------------------------------------------------------
-- MATRIX VIEW — every CP-linked param in the project, whatever the source
-- (pad / track LFO / global). One ModKnob per row: base (drag), excursion
-- arc, live dot; the label under the knob is the signed depth.
-- ctx: { tag, targets_all(), inspect(tr,fx,parm), set_base, set_depth, unlink }
-- ---------------------------------------------------------------------------
function LFOPanel.drawMatrix(theme, ctx)
	local UItk = LFOPanel.tk

	local cache = LFOPanel._matrix
	local key = ctx.tag or "matrix"
	if not cache or cache.key ~= key then
		cache = { key = key, list = ctx.targets_all() }
		LFOPanel._matrix = cache
	end
	local list = cache.list

	UItk.BeginColumns("lfopanel_mx_hd", { 0, theme.button_height * 2.2 },
		{ gap = theme.item_spacing })
	UItk.SetFontH2Bold()
	UItk.Text("MODULATION (" .. #list .. ")")
	UItk.SetFontBody()
	UItk.NextColumn()
	if UItk.Button("lfopanel_mx_scan", "Scan", opts(theme, { width = -1 })) then
		cache.list = ctx.targets_all()
		list = cache.list
	end
	UItk.EndColumns()

	if #list == 0 then
		UItk.SetFontCaption()
		UItk.TextWrapped("No linked parameters. Map targets from the Global tab, or assign LFOs from FX Constellation.")
		UItk.SetFontBody()
		return
	end

	local size = math.floor(theme.button_height * 2)
	local row_h = size + 14
	local step = row_h + theme.item_spacing
	local child_h = math.min(#list, 5) * step + theme.frame_padding_y
	UItk.BeginChild("lfopanel_mx_list", 0, child_h,
		{ scrollable = true, border = false, padding = 0 })
	for i, t in ipairs(list) do
		local info = ctx.inspect and ctx.inspect(t.tr, t.fx, t.parm)
		if info then
			UItk.BeginColumns("lfopanel_mx" .. i,
				{ 0, size, theme.button_height }, { gap = theme.item_spacing })

			UItk.Text(t.pname or "?")
			if UItk.IsItemHovered() then UItk.Tooltip(t.fxname or "") end
			UItk.SetFontCaption()
			local src_tag = t.kind == "pad" and "Pad"
				or ((t.kind == "global" and "G" or "L") .. tostring(t.slot or "?"))
			local sub = src_tag
			if t.track_name and t.track_name ~= "" then
				sub = sub .. " — " .. t.track_name
			end
			local dcol = theme.colors.text_disabled
			UItk.TextColored(sub, dcol[1], dcol[2], dcol[3], 1)
			UItk.SetFontBody()
			UItk.NextColumn()

			local bc, bv, dc, dv = UItk.ModKnob("lfopanel_mxk" .. i,
				string.format("%+.0f%%", info.scale * 100),
				info.baseline, info.scale, info.live, { size = size })
			if bc and ctx.set_base then ctx.set_base(t.tr, t.fx, t.parm, bv) end
			if dc and ctx.set_depth then ctx.set_depth(t.tr, t.fx, t.parm, dv) end
			UItk.NextColumn()

			if UItk.Button("lfopanel_mxx" .. i, "X",
					opts(theme, { width = -1 })) and ctx.unlink then
				ctx.unlink(t.tr, t.fx, t.parm)
				LFOPanel._matrix = nil
				LFOPanel._targets = nil
			end
			UItk.EndColumns()
		else
			-- Link vanished (removed externally): rebuild next frame.
			LFOPanel._matrix = nil
		end
	end
	UItk.EndChild()

	-- Live dots ride the knobs — keep the loop alive while visible.
	UItk.RequestRedrawAt(reaper.time_precise() + 1 / 30)
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

	-- Mapping flows (provided by the host for banks that can target any
	-- param — the global MIDI bank). Bitwig/Ableton pattern:
	--   • Map: arm, then touch the target parameter anywhere in REAPER
	--   • Link last touched: one-shot on the parameter you just tweaked
	if ctx.link and ctx.touched then
		local armed = LFOPanel._armed
		local now = reaper.time_precise()

		local function sigOf(tr, fx, parm)
			if not tr then return "" end
			return tostring(tr) .. ":" .. tostring(fx) .. ":" .. tostring(parm)
		end

		local map_label = armed and "… touch a param (click to cancel)"
			or "Map: touch target"
		if armed then UItk.PushStyleColor("button", theme.colors.accent[1],
			theme.colors.accent[2], theme.colors.accent[3]) end
		local mc = UItk.Button("lfopanel_map", map_label, opts(theme))
		if armed then UItk.PopStyleColor() end
		if mc then
			if armed then
				LFOPanel._armed = nil
			else
				local tr, fx, parm = ctx.touched()
				LFOPanel._armed = { sig = sigOf(tr, fx, parm) }
			end
		end

		if LFOPanel._armed then
			local tr, fx, parm, name = ctx.touched()
			if tr and sigOf(tr, fx, parm) ~= LFOPanel._armed.sig then
				ctx.link(tr, fx, parm, sel)
				LFOPanel._armed = nil
				LFOPanel._targets = nil
				LFOPanel._matrix = nil
				LFOPanel._flash = { msg = "Linked: " .. (name or "?"), t = now }
			else
				-- Poll the touched param while armed.
				UItk.RequestRedrawAt(now + 1 / 15)
			end
		end

		if UItk.Button("lfopanel_lastlink", "Link last touched", opts(theme)) then
			local tr, fx, parm, name = ctx.touched()
			if tr then
				ctx.link(tr, fx, parm, sel)
				LFOPanel._targets = nil
				LFOPanel._matrix = nil
				LFOPanel._flash = { msg = "Linked: " .. (name or "?"), t = now }
			else
				LFOPanel._flash = { msg = "No parameter touched yet", t = now }
			end
		end

		if LFOPanel._flash and now - LFOPanel._flash.t < 2.5 then
			UItk.SetFontCaption()
			UItk.TextColored(LFOPanel._flash.msg,
				theme.colors.accent[1], theme.colors.accent[2],
				theme.colors.accent[3], 1)
			UItk.SetFontBody()
		elseif LFOPanel._flash then
			LFOPanel._flash = nil
		end
	end

	-- Per-slot target registry (Bitwig routing-list pattern): every param
	-- linked to the selected slot, with inline depth and removal. Rebuilt
	-- from the ACTUAL project links (scan) — never goes stale, whatever
	-- created or deleted the links.
	if ctx.targets then
		local cache_key = (ctx.tag or "?") .. ":" .. sel
		local cache = LFOPanel._targets
		if not cache or cache.key ~= cache_key then
			cache = { key = cache_key, list = ctx.targets(sel) }
			LFOPanel._targets = cache
		end
		local list = cache.list

		UItk.Separator()
		UItk.BeginColumns("lfopanel_tgt_hd", { 0, theme.button_height * 2.2 },
			{ gap = theme.item_spacing })
		UItk.SetFontH2Bold()
		UItk.Text("TARGETS (" .. #list .. ")")
		UItk.SetFontBody()
		UItk.NextColumn()
		if UItk.Button("lfopanel_tgt_scan", "Scan",
				opts(theme, { width = -1 })) then
			cache.list = ctx.targets(sel)
			list = cache.list
		end
		UItk.EndColumns()

		if #list > 0 then
			local row_h = theme.button_height
			local step = row_h + theme.item_spacing
			local child_h = math.min(#list, 6) * step + theme.frame_padding_y
			UItk.BeginChild("lfopanel_tgt_list", 0, child_h,
				{ scrollable = true, border = false, padding = 0 })
			for i, t in ipairs(list) do
				UItk.BeginColumns("lfopanel_tgt_" .. i,
					{ 0.4, 0, theme.button_height },
					{ gap = theme.item_spacing })
				UItk.Text(t.pname or "?")
				if UItk.IsItemHovered() then UItk.Tooltip(t.fxname or "") end
				UItk.NextColumn()
				local dc2, dv2 = UItk.SliderDouble("lfopanel_tgtd_" .. i, "",
					t.scale, -1, 1,
					opts(theme, { format = string.format("%+.0f%%", t.scale * 100) }))
				if dc2 and ctx.set_depth then
					t.scale = dv2
					ctx.set_depth(t.tr, t.fx, t.parm, dv2)
				end
				UItk.NextColumn()
				if UItk.Button("lfopanel_tgtx_" .. i, "X",
						opts(theme, { width = -1 })) and ctx.unlink then
					ctx.unlink(t.tr, t.fx, t.parm)
					LFOPanel._targets = nil
					LFOPanel._matrix = nil
				end
				UItk.EndColumns()
			end
			UItk.EndChild()
		end
	end

	-- Target inspector: locks onto the last touched CP-linked param and
	-- exposes its Base (link baseline) and Depth (signed link scale) —
	-- the Bitwig "per-target amount" pattern.
	if ctx.touched and ctx.inspect then
		local tr, fx, parm = ctx.touched()
		if tr and ctx.inspect(tr, fx, parm) then
			local t = LFOPanel._target
			if not (t and t.tr == tr and t.fx == fx and t.parm == parm) then
				LFOPanel._target = { tr = tr, fx = fx, parm = parm }
			end
		end
		local tgt = LFOPanel._target
		if tgt and not reaper.ValidatePtr(tgt.tr, "MediaTrack*") then
			LFOPanel._target = nil
			tgt = nil
		end
		if tgt then
			local info = ctx.inspect(tgt.tr, tgt.fx, tgt.parm)
			if not info then
				LFOPanel._target = nil
			else
				UItk.Separator()
				UItk.SetFontCaption()
				local src_tag = info.kind == "pad" and "Pad"
					or (info.kind == "global" and ("Global LFO " .. (info.slot or "?")))
					or ("CP LFO " .. (info.slot or "?"))
				UItk.Text((info.pname or "?") .. "  ←  " .. src_tag)
				if UItk.IsItemHovered() then UItk.Tooltip(info.fxname or "") end
				UItk.SetFontBody()

				-- One ModKnob fuses base + depth + live excursion.
				local ksize = math.floor(theme.button_height * 2.5)
				UItk.BeginColumns("lfopanel_ti_row", { ksize, 0 },
					{ gap = theme.item_spacing })
				local bc, bv, dc, dv = UItk.ModKnob("lfopanel_ti_knob", nil,
					info.baseline, info.scale, info.live, { size = ksize })
				if bc and ctx.set_base then
					ctx.set_base(tgt.tr, tgt.fx, tgt.parm, bv)
				end
				if dc and ctx.set_depth then
					ctx.set_depth(tgt.tr, tgt.fx, tgt.parm, dv)
				end
				UItk.NextColumn()
				UItk.SetFontCaption()
				UItk.Text(string.format("Base  %.2f", info.baseline))
				UItk.Text(string.format("Depth %+.0f%%", info.scale * 100))
				local dcol = theme.colors.text_disabled
				UItk.TextColored("Alt+drag: depth", dcol[1], dcol[2], dcol[3], 1)
				UItk.SetFontBody()
				UItk.EndColumns()
			end
		end
	end

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
