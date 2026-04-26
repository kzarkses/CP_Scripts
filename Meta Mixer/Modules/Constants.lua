-- Constants.lua — Shared constants for CP Studio
local Constants = {}

-- Layout
Constants.STRIP_W = 80
Constants.KNOB_SIZE = 28
Constants.KNOB_SIZE_SM = 22
Constants.METER_W = 10
Constants.METER_H_TRACK = 60
Constants.REFRESH_INTERVAL = 0.033

-- Knob angle range (radians) — 270 degree sweep
Constants.KNOB_ANGLE_MIN = math.pi * 0.75   -- 135 degrees (lower-left)
Constants.KNOB_ANGLE_MAX = math.pi * 2.25   -- 405 degrees (lower-right)

-- Colors (RGBA u32)
Constants.COL_KNOB_BG      = 0x333333FF
Constants.COL_KNOB_TRACK   = 0x555555FF
Constants.COL_KNOB_VALUE   = 0x4CAF50FF
Constants.COL_KNOB_LINE    = 0xDDDDDDFF
Constants.COL_METER_GREEN  = 0x4CAF50FF
Constants.COL_METER_YELLOW = 0xFFEB3BFF
Constants.COL_METER_RED    = 0xF44336FF
Constants.COL_METER_BG     = 0x333333FF
Constants.COL_MUTE         = 0xF44336FF
Constants.COL_SOLO         = 0xFFEB3BFF
Constants.COL_PLAY         = 0x4CAF50FF
Constants.COL_ACTIVE_BG    = 0x3A5A3AFF
Constants.COL_FX_ENABLED   = 0xAAAAAAFF
Constants.COL_FX_BYPASSED  = 0x666666FF
Constants.COL_WAVEFORM     = 0x5CAF5CCC
Constants.COL_WAVEFORM_BG  = 0x1A1A1AFF
Constants.COL_ITEM_BG      = 0x2A2A2AFF
Constants.COL_DIVE         = 0x4488CCFF

-- Bar grid colors
Constants.COL_BAR_LINE     = 0xCCCCCC88
Constants.COL_BEAT_LINE    = 0x66666666
Constants.COL_SUBDIV_LINE  = 0x44444444
Constants.COL_BAR_LABEL    = 0xAAAAAACC
Constants.COL_CURSOR_LINE  = 0xFFFFFFCC
Constants.COL_STRETCH_MK   = 0xFF8844CC
Constants.COL_SM_DRAG      = 0xFFAA66AA

-- Item Editor — source view colors
Constants.COL_WAVEFORM_DIMMED = 0x5CAF5C44
Constants.COL_ITEM_EDGE       = 0xFFFFFFAA
Constants.COL_FADE_CURVE      = 0xFFFFFF88
Constants.COL_FADE_HANDLE     = 0xFFFFFFCC
Constants.COL_SELECTION       = 0x4488CC44
Constants.COL_SELECTION_EDGE  = 0x4488CCAA
Constants.COL_SNAP_ACTIVE     = 0x4CAF50FF
Constants.COL_SNAP_INACTIVE   = 0x888888FF
Constants.COL_TOGGLE_ON       = 0x4CAF50FF
Constants.COL_TOGGLE_OFF      = 0x666666FF

-- Item Editor dimensions
Constants.ITEM_EDITOR_H    = 180
Constants.WAVEFORM_H       = 100
Constants.CTRL_PANEL_W     = 200
Constants.EDGE_HIT_PX      = 5
Constants.SM_HIT_PX        = 5
Constants.FADE_HIT_H       = 15
Constants.ZOOM_MIN          = 0.3
Constants.ZOOM_MAX          = 16.0
Constants.ZOOM_WHEEL_SPEED  = 0.15

-- Spectral coloring (HSL params)
Constants.SPECTRAL_HUE_LOW  = 1.585
Constants.SPECTRAL_HUE_HIGH = 0.513
Constants.SPECTRAL_SAT      = 0.75
Constants.SPECTRAL_LUM      = 0.55

return Constants
