-- @description Generate white noise in time selection
-- @author Assistant
-- @version 1.0

dofile(reaper.GetResourcePath() .. "/Scripts/CP_Scripts/CP_NoiseGenerators_Common.lua")

function main()
  reaper.Undo_BeginBlock()
  generateNoise(generateBrownNoise)
  reaper.Undo_EndBlock("Generate Brown Noise", -1)
end

main()
