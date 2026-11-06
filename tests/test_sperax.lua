package.path = "app/?.lua;" .. package.path
local s = require("drivers.sperax")
local function bytes(h) local t = {} for x in h:gmatch("%x%x") do t[#t + 1] = tonumber(x, 16) end return t end

-- the request the real pad accepted
assert(s.hex(s.STATUS) == "F5 08 00 19 F0 0A 59 FA", s.hex(s.STATUS))
assert(s.hex(s.TOTALS) == "F5 07 00 1A E6 EA FA", s.hex(s.TOTALS))

-- frames captured from Patrick's SPERAX_RM01 (raw notifications)
local real = {
  { "F5 18 00 19 00 00 10 00 00 00 3E 00 01 00 01 00 05 14 00 00 00 AC 4E FA", "running", 5, 2.0, 62 },
  { "F5 19 00 19 00 00 10 00 00 00 3E 00 01 00 01 00 05 15 00 00 00 D1 F0 03 FA", "running", 5, 2.1, 62 },
  { "F5 18 00 19 00 00 10 00 00 00 41 00 02 00 01 00 0A 1C 00 00 00 63 83 FA", "running", 10, 2.8, 65 },
  { "F5 1A 00 19 00 00 0F 00 00 00 43 00 02 00 01 00 0E 11 00 00 00 F0 0C F0 01 FA", "slowing", 14, 1.7, 67 },
  { "F5 19 00 19 00 00 02 00 00 00 43 00 02 00 01 00 0E 00 00 00 00 F0 08 DF FA", "stopped", 14, 0.0, 67 },
}
for _, r in ipairs(real) do
  local fr = s.feed(s.new_reader(), bytes(r[1]))[1]
  assert(fr and fr.len_ok and fr.crc_ok, "bad: " .. r[1])
  local st = s.decode_status(fr)
  assert(st.state == r[2] and st.steps == r[3] and math.abs(st.speed_kmh - r[4]) < 1e-9 and st.seconds == r[5],
    string.format("decode mismatch %s: %s %d %.1f %d", r[1], st.state, st.steps, st.speed_kmh, st.seconds))
end
print("real status frames ok")

-- rejects with junk bytes after F5
for _, h in ipairs({ "F5 58 08 00 0E 02 14 47 FA", "F5 18 80 08 00 0E 02 14 47 FA", "F5 08 40 08 00 0E 02 14 47 FA" }) do
  local fr = s.feed(s.new_reader(), bytes(h))[1]
  assert(fr and fr.len_ok and fr.crc_ok and fr.cmd == 0x0E, "reject failed " .. h)
end
print("junk-byte rejects ok")

-- split across notifications, two frames in one buffer
local r = s.new_reader()
local a = bytes(real[2][1] .. " " .. real[4][1])
local got = {}
for i = 1, #a, 20 do
  local c = {}
  for k = i, math.min(i + 19, #a) do c[#c + 1] = a[k] end
  for _, f in ipairs(s.feed(r, c)) do got[#got + 1] = f end
end
assert(#got == 2 and got[1].crc_ok and got[2].crc_ok, "split failed")
print("all tests passed")
