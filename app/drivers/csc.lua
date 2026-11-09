-- Cycling Speed and Cadence (0x1816), CSC Measurement 2A5B: sensors such as the Rockbros C3 or
-- Magene S3+. In cadence mode they report crank revolutions, in speed mode wheel revolutions
-- (some send both), each with the time of the last one in 1/1024 s, so a stop shows as
-- revolutions that stop counting. Speed = wheel revolutions x wheel circumference.
-- Also Heart Rate Measurement (2A37) for chest straps.
local bit = require("bit")
local band = bit.band

local M = {}

function M.new()
  return { revs = nil, t = nil, last_rev_at = nil, period = 1, cadence = 0, seen = nil,
           wrevs = nil, wt = nil, wheel_at = nil, wperiod = 1, wheel_rps = 0, has_wheel = false, has_crank = false }
end

local function u16(b, i) return (b[i] or 0) + (b[i + 1] or 0) * 256 end
local function u32(b, i) return u16(b, i) + u16(b, i + 2) * 65536 end

-- one notification; now = local time in seconds
function M.feed(s, b, now)
  s.seen = now
  local flags = b[1] or 0
  local i = 2
  if band(flags, 1) ~= 0 then -- wheel data: u32 revolutions + u16 event time (speed mode)
    s.has_wheel, s.wheel_seen = true, now
    local wr, wt = u32(b, i), u16(b, i + 4)
    if s.wrevs then
      local dr = (wr - s.wrevs) % 4294967296
      local dt = ((wt - s.wt) % 65536) / 1024
      if dr > 0 and dr < 100 and dt > 0 then
        local rps = dr / dt
        if rps < 40 then -- about 300 km/h on a road wheel: anything above is a glitch
          s.wheel_rps = s.wheel_rps > 0 and (s.wheel_rps * 0.3 + rps * 0.7) or rps
          s.wperiod = dt / dr
        end
        s.wheel_at = now
      end
    end
    s.wrevs, s.wt = wr, wt
    i = i + 6
  end
  if band(flags, 2) == 0 then return end    -- no crank data (sensor in speed mode)
  s.has_crank, s.crank_seen = true, now
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

-- fills m.cadence / m.speed_kmh / m.moving / m.fresh from the sensor state; circ = wheel circumference in m
function M.update(s, m, now, circ)
  m.fresh = s.seen ~= nil and now - s.seen < 3
  -- the mode can be switched on the sensor: a kind of data counts while it keeps coming
  s.has_wheel = s.wheel_seen ~= nil and now - s.wheel_seen < 5
  s.has_crank = s.crank_seen ~= nil and now - s.crank_seen < 5
  m.has_wheel, m.has_crank = s.has_wheel, s.has_crank
  -- stopped when no revolution came for clearly longer than the last one took
  local moving = false
  if s.has_crank then
    local since = s.last_rev_at and (now - s.last_rev_at) or math.huge
    local crank_moving = since < math.max(1.2, math.min(3, s.period * 2.2))
    if not crank_moving then s.cadence = 0 end
    m.cadence = math.floor(s.cadence + 0.5)
    moving = moving or crank_moving
  else
    m.cadence = nil
  end
  if s.has_wheel then
    local since = s.wheel_at and (now - s.wheel_at) or math.huge
    local wheel_moving = since < math.max(1.2, math.min(3, s.wperiod * 2.2))
    if not wheel_moving then s.wheel_rps = 0 end
    m.speed_kmh = math.floor(s.wheel_rps * (circ or 2.105) * 3.6 * 10 + 0.5) / 10
    moving = moving or wheel_moving
  else
    m.speed_kmh = nil
  end
  m.moving = moving
end

function M.heart_rate(b)
  local flags = b[1] or 0
  if band(flags, 1) ~= 0 then return u16(b, 2) end
  return b[2] or 0
end

return M
