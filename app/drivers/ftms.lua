-- Bluetooth FTMS (Fitness Machine Service, 0x1826): command encoding and data decoding.
-- Control point 2AD9 (write + indicate), Indoor Bike Data 2AD2, Machine Status 2ADA.
local bit = require("bit")
local band, rshift, lshift = bit.band, bit.rshift, bit.lshift

local M = {}

local function u16(b, i) return (b[i] or 0) + lshift(b[i + 1] or 0, 8) end
local function s16(b, i) local v = u16(b, i); return v >= 0x8000 and v - 0x10000 or v end
local function le16(v) v = band(v, 0xFFFF); return band(v, 0xFF), rshift(v, 8) end

M.REQUEST_CONTROL = { 0x00 }
M.RESET = { 0x01 }
M.START = { 0x07 }
M.STOP = { 0x08, 0x01 }
M.PAUSE = { 0x08, 0x02 }

-- Indoor bike simulation: grade in percent; wind 0, Crr 0.004, Cw 0.51 kg/m.
function M.simulation(grade_pct, crr, cw)
  local glo, ghi = le16(math.floor(grade_pct * 100 + 0.5))
  return { 0x11, 0x00, 0x00, glo, ghi, math.floor((crr or 0.004) * 10000 + 0.5), math.floor((cw or 0.51) * 100 + 0.5) }
end

-- Target resistance level. The spec says uint8 in steps of 0.1, but machines with a
-- 1-32 range can't fit that, so devices disagree; the test tries several encodings.
M.RESISTANCE_ENCODINGS = { "x10 byte", "raw byte", "x10 int16" }
function M.resistance(level, enc)
  if enc == "raw byte" then return { 0x04, math.max(0, math.min(255, level)) } end
  if enc == "x10 int16" then local lo, hi = le16(level * 10); return { 0x04, lo, hi } end
  return { 0x04, math.max(0, math.min(255, level * 10)) }
end

local OPS = { [0x00] = "request control", [0x01] = "reset", [0x04] = "set resistance", [0x05] = "set power",
  [0x07] = "start/resume", [0x08] = "stop/pause", [0x11] = "set simulation" }
local RESULTS = { [0x01] = "success", [0x02] = "not supported", [0x03] = "invalid parameter",
  [0x04] = "failed", [0x05] = "control not permitted" }

-- Control point response: 80 <op> <result>
function M.response(b)
  if b[1] ~= 0x80 then return nil end
  return { op = b[2], result = b[3], text = (OPS[b[2]] or string.format("op %02X", b[2] or 0)) .. ": " ..
    (RESULTS[b[3]] or string.format("result %02X", b[3] or 0)), ok = b[3] == 0x01 }
end

local STATUS = { [0x01] = "reset", [0x02] = "stopped or paused", [0x03] = "stopped by safety key",
  [0x04] = "started or resumed", [0x05] = "target speed changed", [0x06] = "target incline changed",
  [0x07] = "target resistance changed", [0x08] = "target power changed", [0x12] = "simulation changed",
  [0xFF] = "control permission lost" }
function M.machine_status(b) return STATUS[b[1]] or string.format("status %02X", b[1] or 0) end

-- Indoor Bike Data. Returns a table of the fields present.
function M.indoor_bike(b)
  local flags, i, d = u16(b, 1), 3, {}
  local function has(n) return band(flags, lshift(1, n)) ~= 0 end
  if not has(0) then d.speed_kmh = u16(b, i) / 100; i = i + 2 end
  if has(1) then i = i + 2 end
  if has(2) then d.cadence = u16(b, i) / 2; i = i + 2 end
  if has(3) then i = i + 2 end
  if has(4) then d.distance_m = u16(b, i) + (b[i + 2] or 0) * 65536; i = i + 3 end
  if has(5) then d.resistance = s16(b, i); i = i + 2 end
  if has(6) then d.power = s16(b, i); i = i + 2 end
  if has(7) then i = i + 2 end
  if has(8) then d.kcal = u16(b, i); i = i + 5 end
  if has(9) then d.hr = b[i]; i = i + 1 end
  if has(10) then i = i + 1 end
  if has(11) then d.seconds = u16(b, i); i = i + 2 end
  return d
end

-- Treadmill Data (2ACD).
function M.treadmill(b)
  local flags, i, d = u16(b, 1), 3, {}
  local function has(n) return band(flags, lshift(1, n)) ~= 0 end
  if not has(0) then d.speed_kmh = u16(b, i) / 100; i = i + 2 end
  if has(1) then i = i + 2 end
  if has(2) then d.distance_m = u16(b, i) + (b[i + 2] or 0) * 65536; i = i + 3 end
  if has(3) then d.incline = s16(b, i) / 10; i = i + 4 end
  if has(4) then i = i + 4 end
  if has(5) then i = i + 1 end
  if has(6) then i = i + 1 end
  if has(7) then d.kcal = u16(b, i); i = i + 5 end
  if has(8) then d.hr = b[i]; i = i + 1 end
  if has(9) then i = i + 1 end
  if has(10) then d.seconds = u16(b, i); i = i + 2 end
  return d
end

-- Treadmill targets: speed in km/h (0.01 resolution), incline in percent (0.1).
function M.target_speed(kmh) local lo, hi = le16(math.floor(kmh * 100 + 0.5)); return { 0x02, lo, hi } end
function M.target_incline(pct) local lo, hi = le16(math.floor(pct * 10 + 0.5)); return { 0x03, lo, hi } end

function M.bike_text(d)
  local t = {}
  if d.speed_kmh then t[#t + 1] = string.format("speed %.2f km/h", d.speed_kmh) end
  if d.cadence then t[#t + 1] = string.format("cadence %.1f rpm", d.cadence) end
  if d.resistance then t[#t + 1] = "resistance " .. d.resistance end
  if d.power then t[#t + 1] = "power " .. d.power .. " W" end
  return table.concat(t, ", ")
end

return M
