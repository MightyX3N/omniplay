package.path = "app/?.lua;" .. package.path
local ftms = require("drivers.ftms")
local function bytes(h) local t = {} for x in h:gmatch("%x%x") do t[#t + 1] = tonumber(x, 16) end return t end
local function hex(b) local t = {} for i, v in ipairs(b) do t[i] = string.format("%02X", v) end return table.concat(t, " ") end

-- packet captured from Patrick's EM 8000 (LixenTec F-9833), not pedalling
local d = ftms.indoor_bike(bytes("FE 1F 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))
assert(d.speed_kmh == 0 and d.cadence == 0 and d.resistance == 1 and d.power == 0 and d.seconds == 0, ftms.bike_text(d))

-- same layout with values: 25.6 km/h, 85 rpm, resistance 12, 140 W, HR 130, 61 s
d = ftms.indoor_bike(bytes("FE 1F 00 0A 00 00 AA 00 00 00 00 00 00 0C 00 8C 00 00 00 00 00 00 00 00 82 00 3D 00 00 00"))
assert(d.speed_kmh == 25.6 and d.cadence == 85 and d.resistance == 12 and d.power == 140 and d.hr == 130 and d.seconds == 61, ftms.bike_text(d))

assert(hex(ftms.simulation(5)) == "11 00 00 F4 01 28 33", hex(ftms.simulation(5)))
assert(hex(ftms.simulation(-2)) == "11 00 00 38 FF 28 33", hex(ftms.simulation(-2)))
assert(hex(ftms.resistance(10, "x10 byte")) == "04 64")
assert(hex(ftms.resistance(10, "raw byte")) == "04 0A")
assert(hex(ftms.resistance(32, "x10 int16")) == "04 40 01")
assert(hex(ftms.resistance(32, "x10 byte")) == "04 FF") -- clamped: why the other encodings exist

local r = ftms.response(bytes("80 00 01")); assert(r.ok and r.text == "request control: success")
r = ftms.response(bytes("80 11 02")); assert(not r.ok and r.text == "set simulation: not supported")
assert(ftms.machine_status(bytes("12 00")) == "simulation changed")
print("ftms tests passed")
