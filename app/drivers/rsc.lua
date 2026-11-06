-- Running Speed and Cadence (0x1814), RSC Measurement 2A53: footpods like the Zwift RunPod.
local bit = require("bit")
local band, lshift = bit.band, bit.lshift

local M = {}

function M.measurement(b)
  local flags = b[1] or 0
  local d = {
    speed_kmh = ((b[2] or 0) + lshift(b[3] or 0, 8)) / 256 * 3.6, -- 1/256 m/s
    cadence = b[4] or 0,                                          -- steps per minute
    running = band(flags, 4) ~= 0,
  }
  local i = 5
  if band(flags, 1) ~= 0 then d.stride_cm = (b[i] or 0) + lshift(b[i + 1] or 0, 8); i = i + 2 end
  if band(flags, 2) ~= 0 then
    d.distance_m = ((b[i] or 0) + lshift(b[i + 1] or 0, 8) + (b[i + 2] or 0) * 65536 + (b[i + 3] or 0) * 16777216) / 10
  end
  return d
end

return M
