-- CP_VideoKit / Effects manifest
-- Each entry can be a plain "File.lua" string, or a category header table
-- { category = "Name" }. Categories are used to group entries in the
-- "Add module" menu of the Modules window.
return {
    { category = "Transform" },
    "CropZoom.lua",
    "PiP.lua",
    "Mirror.lua",

    { category = "Color" },
    "ColorAdjust.lua",
    "Invert.lua",

    { category = "Stylize" },
    "Pixelate.lua",
    "Vignette.lua",
    "Scanlines.lua",

    { category = "Time" },
    "FrameFreeze.lua",
    "FrameEcho.lua",
    "Strobe.lua",

    { category = "Glitch" },
    "RGBShift.lua",

    { category = "Audio reactive" },
    "AudioZoomPunch.lua",
    "AudioShake.lua",
    "AudioStrobe.lua",
    "SpectrumBars.lua",
}
