-- Runs the automatic bike test against a fake bike: hills work, and only the
-- "x10 byte" resistance encoding works. The report must say exactly that.
package.path = "app/?.lua;" .. package.path
local ffi = require("ffi")

love = {
  filesystem = { getSourceBaseDirectory = function() return "/tmp" end, write = function() end },
  system = { setClipboardText = function(t) CLIP = t end },
}

local state, queue, bike_res = 0, {}, 1
local function u16(v) return v % 256, math.floor(v / 256) % 256 end
local function bike_packet()
  -- flags 0x0064: speed, cadence, resistance, power present
  local power = 60 + bike_res * 8
  local s1, s2 = u16(2500); local c1, c2 = u16(170); local r1, r2 = u16(bike_res); local p1, p2 = u16(power)
  return { 0x64, 0x00, s1, s2, c1, c2, r1, r2, p1, p2 }
end
local fake = {
  sb_scan_stop = function() end,
  sb_open = function() state = 2; return 0 end,
  sb_state = function() return state end,
  sb_status_text = function() return "" end,
  sb_last_error = function() return "" end,
  sb_close = function() state = 0 end,
  sb_write = function(d, n)
    local op = d[0]
    if op == 0x11 then
      local g = d[3] + d[4] * 256; if g >= 32768 then g = g - 65536 end
      bike_res = g > 0 and 9 or 1
    elseif op == 0x04 and n == 2 and d[1] % 10 == 0 and d[1] >= 10 then
      bike_res = d[1] / 10 -- only the x10 byte encoding is understood
    end
    queue[#queue + 1] = { 1, { 0x80, op, 0x01 } }
    return 0
  end,
  sb_read_ex = function(buf, max, which)
    local c = table.remove(queue, 1)
    if not c then return 0 end
    which[0] = c[1]
    for i, v in ipairs(c[2]) do buf[i - 1] = v end
    return #c[2]
  end,
}

local logs = {}
local biketest = require("biketest")
biketest.start(fake, function(kind, text) logs[#logs + 1] = kind .. " " .. text end, { name = "FakeBike", addr = "AA" })
for _ = 1, 4 * 100 do -- 100 s at 4 updates per second
  queue[#queue + 1] = { 0, bike_packet() }
  biketest.update(0.25)
end
print(CLIP)
assert(CLIP, "no report written")
assert(CLIP:find("Hill simulation: WORKS"), "hill verdict wrong")
assert(CLIP:find("Resistance, x10 byte: WORKS"), "x10 byte verdict wrong")
assert(CLIP:find("Resistance, raw byte: no effect"), "raw byte verdict wrong")
assert(CLIP:find("Resistance, x10 int16: no effect"), "int16 verdict wrong")
assert(CLIP:find("Use for this bike: hill simulation"), "conclusion wrong")
local f = io.open("/tmp/bike-test-report.txt"); assert(f, "report file missing"); f:close()
print("biketest tests passed")
