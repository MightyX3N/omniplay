-- CSC sensors (Rockbros C3, Magene S3+): cadence mode, speed mode, both
package.path = "app/?.lua;" .. package.path
local csc = require("drivers.csc")

local function wheel_pkt(revs, t) return { 0x01, revs % 256, math.floor(revs / 256) % 256, math.floor(revs / 65536) % 256, math.floor(revs / 16777216) % 256, t % 256, math.floor(t / 256) % 256 } end
local function crank_pkt(revs, t) return { 0x02, revs % 256, math.floor(revs / 256) % 256, t % 256, math.floor(t / 256) % 256 } end

-- speed mode: 3 revolutions a second on a 2105 mm wheel = 22.7 km/h
local s, m = csc.new(), {}
local revs, et = 1000, 0
for i = 1, 20 do
  revs, et = revs + 3, (et + 1024) % 65536
  csc.feed(s, wheel_pkt(revs, et), i)
  csc.update(s, m, i, 2.105)
end
assert(m.has_wheel and not m.has_crank, "speed mode detected")
assert(math.abs(m.speed_kmh - 22.7) < 0.2, "speed from the wheel: " .. m.speed_kmh)
assert(m.cadence == nil, "no cadence in speed mode")
assert(m.moving, "moving")
-- wheel size matters
csc.update(s, m, 20, 2.290)
assert(m.speed_kmh > 23.5, "bigger wheel, faster: " .. m.speed_kmh)
-- stop: packets keep coming with the same count
for i = 21, 25 do csc.feed(s, wheel_pkt(revs, et), i); csc.update(s, m, i, 2.105) end
assert(not m.moving and m.speed_kmh == 0, "stopped wheel: 0 km/h")
-- counter wrap at 2^32
local s2, m2 = csc.new(), {}
csc.feed(s2, wheel_pkt(4294967295, 65000), 1)
csc.feed(s2, wheel_pkt(2, (65000 + 1024) % 65536), 2) -- 3 revolutions in 1 s
csc.update(s2, m2, 2, 2.105)
assert(math.abs(m2.speed_kmh - 3 * 2.105 * 3.6) < 0.2, "wrap: " .. m2.speed_kmh)

-- cadence mode still works: 90 rpm
local s3, m3 = csc.new(), {}
local cr, ct = 0, 0
for i = 1, 20 do cr = cr + 1; ct = (ct + 683) % 65536; csc.feed(s3, crank_pkt(cr, ct), i * 0.667); csc.update(s3, m3, i * 0.667) end
assert(m3.has_crank and not m3.has_wheel and math.abs(m3.cadence - 90) <= 1 and m3.speed_kmh == nil, "cadence mode")

-- both in one packet
local s4, m4 = csc.new(), {}
for i = 1, 10 do
  local w = wheel_pkt(i * 3, (i * 1024) % 65536)
  local c = crank_pkt(i, (i * 1024) % 65536)
  local b = { 0x03 }
  for k = 2, 7 do b[#b + 1] = w[k] end
  for k = 2, 5 do b[#b + 1] = c[k] end
  csc.feed(s4, b, i); csc.update(s4, m4, i, 2.105)
end
assert(m4.has_wheel and m4.has_crank and m4.cadence == 60 and math.abs(m4.speed_kmh - 22.7) < 0.2, "both: " .. m4.cadence .. " rpm " .. m4.speed_kmh .. " km/h")
-- switched from speed to cadence mode on the sensor: after a few seconds it's a cadence sensor
for i = 11, 20 do csc.feed(s4, crank_pkt(i, (i * 1024) % 65536), i); csc.update(s4, m4, i, 2.105) end
assert(m4.has_crank and not m4.has_wheel and m4.speed_kmh == nil, "mode switch on the sensor is followed")
print("csc tests passed")
