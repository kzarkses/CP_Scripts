-- Waveform.lua — Spectral waveform rendering: full source view, stereo, gain-aware
local Waveform = {}
local r, C, ctx

function Waveform.init(reaper_api, constants, imgui_ctx)
    r = reaper_api
    C = constants
    ctx = imgui_ctx
end

-- ============================================================================
-- SPECTRAL COLOR — frequency to RGBA via HSL
-- ============================================================================
local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
end

local function hslToRGBA(h, s, l, a)
    local rv, g, b
    if s == 0 then
        rv, g, b = l, l, l
    else
        local q = (l < 0.5) and (l * (1 + s)) or (l + s - l * s)
        local p = 2 * l - q
        rv = hue2rgb(p, q, h + 1/3)
        g  = hue2rgb(p, q, h)
        b  = hue2rgb(p, q, h - 1/3)
    end
    return math.floor(rv * 255 + 0.5) * 0x1000000
         + math.floor(g * 255 + 0.5) * 0x10000
         + math.floor(b * 255 + 0.5) * 0x100
         + math.floor(a * 255 + 0.5)
end

local function freqToColor(freq, amplitude, dimmed)
    local alpha = dimmed and 0.30 or 0.85
    if freq <= 0 then
        return dimmed and C.COL_WAVEFORM_DIMMED or C.COL_WAVEFORM
    end
    local hue = (52.1153 * math.log(0.05 * math.max(freq, 20))) / 360
    hue = hue % 1.0
    local lum = C.SPECTRAL_LUM * math.min(1, math.abs(amplitude) * 2 + 0.3)
    return hslToRGBA(hue, C.SPECTRAL_SAT, lum, alpha)
end

-- ============================================================================
-- PEAK CACHE
-- ============================================================================
local peak_cache = {
    item_id = nil,
    width = 0,
    item_vol = 0,
    take_vol = 0,
    stereo = false,
    view_start = 0,
    view_len = 0,
    -- Per-channel peak data
    ch1_max = nil, ch1_min = nil,
    ch2_max = nil, ch2_min = nil,
    -- Spectral data per pixel
    freq = nil,
    n_chans = 0,
    spl_cnt = 0,
    has_spectral = false,
}

-- ============================================================================
-- GET PEAKS — extract peaks for a time range (source time coordinates)
-- ============================================================================
function Waveform.GetPeaks(item, take, draw_width, item_vol, take_vol, stereo, view_start_time, view_len_time)
    if not item or not take then return nil end
    if r.TakeIsMIDI(take) then return nil end

    local item_id = tostring(item)
    local vol = item_vol * take_vol

    -- Check cache
    if peak_cache.item_id == item_id
        and peak_cache.width == draw_width
        and peak_cache.item_vol == item_vol
        and peak_cache.take_vol == take_vol
        and peak_cache.stereo == stereo
        and peak_cache.view_start == view_start_time
        and peak_cache.view_len == view_len_time
        and peak_cache.ch1_max then
        return peak_cache
    end

    -- Source info
    local source = r.GetMediaItemTake_Source(take)
    if not source then return nil end
    local n_chans = r.GetMediaSourceNumChannels(source)
    if n_chans < 1 then return nil end

    if view_len_time <= 0 then return nil end

    local n_spls = math.floor(draw_width)
    if n_spls < 2 then return nil end
    local peakrate = n_spls / view_len_time

    -- Buffer: max + min + spectral (3 blocks)
    local buf_size = n_spls * n_chans * 3
    local buf = r.new_array(buf_size)
    buf.clear()

    -- GetMediaItemTake_Peaks uses source-time (starttime = offset into source)
    local retval = r.GetMediaItemTake_Peaks(
        take, peakrate, view_start_time, n_chans, n_spls, 115, buf
    )

    local spl_cnt = (retval & 0xfffff)
    if spl_cnt <= 0 then return nil end
    local has_spectral = ((retval >> 24) & 1) == 1

    -- Extract peaks per channel, apply gain
    local ch1_max, ch1_min = {}, {}
    local ch2_max, ch2_min = {}, {}
    local freq_data = {}

    for i = 0, spl_cnt - 1 do
        local idx_max_ch1 = i * n_chans + 1
        local idx_min_ch1 = spl_cnt * n_chans + i * n_chans + 1
        ch1_max[i + 1] = buf[idx_max_ch1] * vol
        ch1_min[i + 1] = buf[idx_min_ch1] * vol

        if n_chans >= 2 and stereo then
            local idx_max_ch2 = i * n_chans + 2
            local idx_min_ch2 = spl_cnt * n_chans + i * n_chans + 2
            ch2_max[i + 1] = buf[idx_max_ch2] * vol
            ch2_min[i + 1] = buf[idx_min_ch2] * vol
        end

        if has_spectral then
            local spec_offset = spl_cnt * n_chans * 2
            local spec_idx = spec_offset + i * n_chans + 1
            local raw = buf[spec_idx]
            if raw then
                freq_data[i + 1] = math.floor(raw) & 0x7FFF
            else
                freq_data[i + 1] = 0
            end
        end
    end

    if n_chans < 2 and stereo then
        ch2_max = ch1_max
        ch2_min = ch1_min
    end

    -- Update cache
    peak_cache.item_id = item_id
    peak_cache.width = draw_width
    peak_cache.item_vol = item_vol
    peak_cache.take_vol = take_vol
    peak_cache.stereo = stereo
    peak_cache.view_start = view_start_time
    peak_cache.view_len = view_len_time
    peak_cache.ch1_max = ch1_max
    peak_cache.ch1_min = ch1_min
    peak_cache.ch2_max = ch2_max
    peak_cache.ch2_min = ch2_min
    peak_cache.freq = freq_data
    peak_cache.n_chans = n_chans
    peak_cache.spl_cnt = spl_cnt
    peak_cache.has_spectral = has_spectral

    return peak_cache
end

function Waveform.InvalidateCache()
    peak_cache.item_id = nil
    peak_cache.ch1_max = nil
end

-- ============================================================================
-- PIXEL <-> TIME CONVERSION (source time)
-- ============================================================================
function Waveform.TimeToPixel(time, wx, wf_w, view_start, view_len)
    if view_len <= 0 then return wx end
    return wx + (time - view_start) / view_len * wf_w
end

function Waveform.PixelToTime(px, wx, wf_w, view_start, view_len)
    if wf_w <= 0 then return view_start end
    return view_start + (px - wx) / wf_w * view_len
end

-- ============================================================================
-- FADE CURVE — compute fade shape value at normalized position (0..1)
-- ============================================================================
local function fadeCurve(t, shape)
    if shape == 0 then return t end
    if shape == 1 then return t * t end
    if shape == 2 then return 1 - (1 - t) * (1 - t) end
    if shape == 3 then
        if t < 0.5 then return 2 * t * t
        else return 1 - 2 * (1 - t) * (1 - t) end
    end
    if shape == 4 then return t * t * (3 - 2 * t) end
    if shape == 5 then return t * t * (3 - 2 * t) end
    if shape == 6 then return t * t * t * (t * (t * 6 - 15) + 10) end
    return t
end

-- ============================================================================
-- DRAW WAVEFORM — full source view with item region highlighted
-- ============================================================================
function Waveform.Draw(draw_x, draw_y, draw_w, draw_h, peaks, stereo, info, view_start, view_len)
    if not peaks or not peaks.ch1_max then return end

    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local count = math.min(peaks.spl_cnt, math.floor(draw_w))

    -- Background
    r.ImGui_DrawList_AddRectFilled(draw_list, draw_x, draw_y,
        draw_x + draw_w, draw_y + draw_h, C.COL_WAVEFORM_BG)

    -- Item region in source time
    local item_src_start = (info and info.source_offset) or view_start
    local item_rate = (info and info.playrate) or 1
    local item_src_end = item_src_start + ((info and info.len) or view_len) * item_rate

    -- Pixel positions of item edges
    local item_px_start = Waveform.TimeToPixel(item_src_start, draw_x, draw_w, view_start, view_len)
    local item_px_end   = Waveform.TimeToPixel(item_src_end, draw_x, draw_w, view_start, view_len)
    item_px_start = math.max(draw_x, math.min(draw_x + draw_w, item_px_start))
    item_px_end   = math.max(draw_x, math.min(draw_x + draw_w, item_px_end))

    -- Fade lengths in source time
    local fade_in_src = (info and info.fade_in or 0) * item_rate
    local fade_out_src = (info and info.fade_out or 0) * item_rate
    local fade_in_shape = (info and info.fade_in_shape) or 0
    local fade_out_shape = (info and info.fade_out_shape) or 0

    -- Helper: is pixel inside item?
    local function pixelInside(x)
        return x >= item_px_start and x <= item_px_end
    end

    -- Helper: compute fade alpha for a source-time position
    local function getFadeAlpha(src_t)
        local alpha = 1.0
        if fade_in_src > 0 then
            local d = src_t - item_src_start
            if d < fade_in_src then
                alpha = fadeCurve(math.max(0, d / fade_in_src), fade_in_shape)
            end
        end
        if fade_out_src > 0 then
            local d = item_src_end - src_t
            if d < fade_out_src then
                alpha = alpha * fadeCurve(math.max(0, d / fade_out_src), fade_out_shape)
            end
        end
        return alpha
    end

    if stereo and peaks.ch2_max and peaks.ch2_max ~= peaks.ch1_max then
        -- === STEREO MODE ===
        local half_h = draw_h / 2
        local axis_l = draw_y + half_h * 0.5
        local axis_r = draw_y + half_h + half_h * 0.5
        local qh = half_h * 0.5

        r.ImGui_DrawList_AddLine(draw_list, draw_x, draw_y + half_h,
            draw_x + draw_w, draw_y + half_h, 0x444444FF, 1.0)
        r.ImGui_DrawList_AddLine(draw_list, draw_x, axis_l,
            draw_x + draw_w, axis_l, 0x333333FF, 1.0)
        r.ImGui_DrawList_AddLine(draw_list, draw_x, axis_r,
            draw_x + draw_w, axis_r, 0x333333FF, 1.0)

        for i = 1, count do
            local freq = peaks.has_spectral and peaks.freq[i] or 0
            local max_l = math.max(-1, math.min(1, peaks.ch1_max[i] or 0))
            local min_l = math.max(-1, math.min(1, peaks.ch1_min[i] or 0))
            local max_r = math.max(-1, math.min(1, peaks.ch2_max[i] or 0))
            local min_r = math.max(-1, math.min(1, peaks.ch2_min[i] or 0))

            local x = draw_x + (i - 1)
            local inside = pixelInside(x)
            local dimmed = not inside
            local col = freq > 0 and freqToColor(freq, max_l, dimmed) or
                        (dimmed and C.COL_WAVEFORM_DIMMED or C.COL_WAVEFORM)

            -- Apply fade attenuation inside item
            if inside then
                local src_t = Waveform.PixelToTime(x, draw_x, draw_w, view_start, view_len)
                local fa = getFadeAlpha(src_t)
                if fa < 0.99 then
                    max_l = max_l * fa; min_l = min_l * fa
                    max_r = max_r * fa; min_r = min_r * fa
                end
            end

            local y1l = axis_l - max_l * qh
            local y2l = axis_l - min_l * qh
            if math.abs(y2l - y1l) < 1 then y1l = axis_l - 0.5; y2l = axis_l + 0.5 end
            r.ImGui_DrawList_AddLine(draw_list, x, y1l, x, y2l, col, 1.0)

            local y1r = axis_r - max_r * qh
            local y2r = axis_r - min_r * qh
            if math.abs(y2r - y1r) < 1 then y1r = axis_r - 0.5; y2r = axis_r + 0.5 end
            r.ImGui_DrawList_AddLine(draw_list, x, y1r, x, y2r, col, 1.0)
        end

        r.ImGui_DrawList_AddText(draw_list, draw_x + 2, draw_y + 1, 0x666666AA, "L")
        r.ImGui_DrawList_AddText(draw_list, draw_x + 2, draw_y + half_h + 1, 0x666666AA, "R")
    else
        -- === MONO MODE ===
        local axis_y = draw_y + draw_h * 0.5
        local half_h = draw_h * 0.5

        r.ImGui_DrawList_AddLine(draw_list, draw_x, axis_y,
            draw_x + draw_w, axis_y, 0x333333FF, 1.0)

        for i = 1, count do
            local freq = peaks.has_spectral and peaks.freq[i] or 0
            local max_val = math.max(-1, math.min(1, peaks.ch1_max[i] or 0))
            local min_val = math.max(-1, math.min(1, peaks.ch1_min[i] or 0))

            local x = draw_x + (i - 1)
            local inside = pixelInside(x)
            local dimmed = not inside
            local col = freq > 0 and freqToColor(freq, max_val, dimmed) or
                        (dimmed and C.COL_WAVEFORM_DIMMED or C.COL_WAVEFORM)

            if inside then
                local src_t = Waveform.PixelToTime(x, draw_x, draw_w, view_start, view_len)
                local fa = getFadeAlpha(src_t)
                if fa < 0.99 then
                    max_val = max_val * fa
                    min_val = min_val * fa
                end
            end

            local y1 = axis_y - max_val * half_h
            local y2 = axis_y - min_val * half_h
            if math.abs(y2 - y1) < 1 then y1 = axis_y - 0.5; y2 = axis_y + 0.5 end
            r.ImGui_DrawList_AddLine(draw_list, x, y1, x, y2, col, 1.0)
        end
    end

    -- Item edge lines
    if item_px_start > draw_x + 1 then
        r.ImGui_DrawList_AddLine(draw_list, item_px_start, draw_y,
            item_px_start, draw_y + draw_h, C.COL_ITEM_EDGE, 1.5)
    end
    if item_px_end < draw_x + draw_w - 1 then
        r.ImGui_DrawList_AddLine(draw_list, item_px_end, draw_y,
            item_px_end, draw_y + draw_h, C.COL_ITEM_EDGE, 1.5)
    end

    -- Fade curve visual overlay
    if info and fade_in_src > 0 and item_px_start < item_px_end then
        local fi_px_end = Waveform.TimeToPixel(item_src_start + fade_in_src,
            draw_x, draw_w, view_start, view_len)
        fi_px_end = math.min(fi_px_end, item_px_end)
        local span = math.max(1, fi_px_end - item_px_start)
        local step = math.max(2, math.floor(span / 25))
        local prev_x, prev_y = item_px_start, draw_y + draw_h
        for px = item_px_start, fi_px_end, step do
            local t = (px - item_px_start) / span
            local y = draw_y + draw_h * (1 - fadeCurve(t, fade_in_shape))
            r.ImGui_DrawList_AddLine(draw_list, prev_x, prev_y, px, y, C.COL_FADE_CURVE, 1.5)
            prev_x, prev_y = px, y
        end
        -- Final segment to exact end
        local y_end = draw_y
        r.ImGui_DrawList_AddLine(draw_list, prev_x, prev_y, fi_px_end, y_end, C.COL_FADE_CURVE, 1.5)
    end

    if info and fade_out_src > 0 and item_px_start < item_px_end then
        local fo_px_start = Waveform.TimeToPixel(item_src_end - fade_out_src,
            draw_x, draw_w, view_start, view_len)
        fo_px_start = math.max(fo_px_start, item_px_start)
        local span = math.max(1, item_px_end - fo_px_start)
        local step = math.max(2, math.floor(span / 25))
        local prev_x, prev_y = fo_px_start, draw_y
        for px = fo_px_start, item_px_end, step do
            local t = (px - fo_px_start) / span
            local y = draw_y + draw_h * t  -- fade out: top → bottom
            local shape_t = 1 - t
            y = draw_y + draw_h * (1 - fadeCurve(shape_t, fade_out_shape))
            r.ImGui_DrawList_AddLine(draw_list, prev_x, prev_y, px, y, C.COL_FADE_CURVE, 1.5)
            prev_x, prev_y = px, y
        end
        local y_end = draw_y + draw_h
        r.ImGui_DrawList_AddLine(draw_list, prev_x, prev_y, item_px_end, y_end, C.COL_FADE_CURVE, 1.5)
    end

    -- Border
    r.ImGui_DrawList_AddRect(draw_list, draw_x, draw_y,
        draw_x + draw_w, draw_y + draw_h, 0x555555FF, 0, 0, 1.0)
end

return Waveform
