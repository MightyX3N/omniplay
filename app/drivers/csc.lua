-- Cycling Speed and Cadence (0x1816), CSC Measurement 2A5B: crank cadence sensors such as the
-- Rockbros C3 or Magene S3+ in cadence mode. They report cumulative crank revolutions and the time
-- of the last one (1/1024 s), so a stop shows as revolutions that stop counting.
-- Also Heart Rate Measurement (2A37) for chest straps.
local bit = require("bit")
local band = bit.band

local M = {}

function M.new() return { revs = nil, t = nil, last_rev_at = nil, period = 1, cadence = 0, seen = nil } end

local function u16(b, i) return (b[i] or 0) + (b[i + 1] or 0) * 256 end

-- one notification; now = local time in seconds
function M.feed(s, b, now)
  s.seen = now
  local flags = b[1] or 0
  local i = 2
  if band(flags, 1) ~= 0 then i = i + 6 end -- wheel data: u32 revolutions + u16 event time
  if band(flags, 2) == 0 then return end    -- no crank data (sensor in speed mode)
  local revs, t = u16(b, i), u16(b, i + 2)
  if s.revs then
    local dr = (revs - s.revs) % 65536
    local dt = ((t - s.t) % 65536) / 1024
    if dr > 0 and dt > 0 then
      local cad = dr / dt * 60
      if cad < 250 then
        s.cadence = s.cadence > 0 and (s.cadence * 0.3 + cad * 0.7) or cad
        s.period = dt / dr
      end
      s.last_rev_at = now
    end
  end
  s.revs, s.t = revs, t
end

-- fills m.cadence / m.moving / m.fresh from the sensor state
function M.update(s, m, now)
  m.fresh = s.seen ~= nil and now - s.seen < 3
  local since = s.last_rev_at and (now - s.last_rev_at) or math.huge
  -- stopped when no revolution came for clearly longer than the last pedal stroke took
  local limit = math.max(1.2, math.min(3, s.period * 2.2))
  m.moving = since < limit
  if not m.moving then s.cadence = 0 end
  m.cadence = math.floor(s.cadence + 0.5)
end

function M.heart_rate(b)
  local flags = b[1] or 0
  if band(flags, 1) ~= 0 then return u16(b, 2) end
  return b[2] or 0
end

return M
