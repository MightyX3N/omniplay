package.path = "app/?.lua;" .. package.path
local ffi = require("ffi")
local sperax = require("drivers.sperax")

love = { filesystem = { getSourceBaseDirectory = function() return "/tmp" end, write = function() end } }

-- fake Sperax pad: start -> countdown -> running; speed ramps 0.1 km/h per update toward target
local sent, target, speed, state, countdown = {}, 0, 0, "idle", 0
local acks = {}
local fake = {
  sb_last_error = function() return "" end,
  sb_write = function(d, n)
    local b = {}
    for i = 0, n - 1 do b[#b + 1] = d[i] end
    sent[#sent + 1] = sperax.hex(b)
    local p = sperax.feed(sperax.new_reader(), b)[1]
    assert(p and p.crc_ok and p.len_ok, "command frame invalid: " .. sperax.hex(b))
    local pl = { p.b[4], p.b[5], p.b[6], p.b[7] }
    if pl[1] == 0x15 then
      if pl[2] == 0x01 and pl[3] == 0x02 and state == "idle" then state, countdown = "countdown", 12
      elseif pl[2] == 0x01 then target = pl[3] / 10
      elseif pl[2] == 0x00 then state, target = "idle", 0 end
      acks[#acks + 1] = { b = { 0xF5, 0x09, 0x00, 0xD0, 0x15, 0x00, 0, 0, 0xFA }, cmd = 0xD0 }
    end
    return 0
  end,
}
local padtest = require("padtest")
local log = {}
local function lg(k, t) log[#log + 1] = k .. " " .. t end

padtest.arm(fake, lg)
assert(padtest.armed and #sent == 0, "arming must not move the belt")
padtest.start()
assert(sent[1] == sperax.hex(sperax.encode({ 0x15, 0x01, 0x02, 0x00 })), "start frame wrong")
for _ = 1, 4 * 60 do
  if state == "countdown" then countdown = countdown - 1; if countdown <= 0 then state = "running" end end
  if state == "running" then
    if speed < target then speed = math.min(target, speed + 0.1) elseif speed > target then speed = math.max(target, speed - 0.1) end
  else speed = 0 end
  for _, a in ipairs(acks) do padtest.on_frame(a, nil) end
  acks = {}
  local st = { state = state == "running" and "running" or state, speed_kmh = speed }
  padtest.on_frame({ cmd = 0x19, b = {} }, st)
  padtest.update(0.25, st)
end
local f = io.open("/tmp/pad-test-report.txt"); local rep = f:read("*a"); f:close()
print(rep)
assert(rep:find("Speed control: WORKS"), "verdict wrong")
assert(not padtest.active, "test should have finished")
assert(sent[#sent] == sperax.hex(sperax.encode({ 0x15, 0x00, 0x00, 0x00 })), "belt not stopped at the end")
for _, s in ipairs(sent) do
  local b = {}
  for h in s:gmatch("%x%x") do b[#b + 1] = tonumber(h, 16) end
  local p = sperax.feed(sperax.new_reader(), b)[1]
  if p.b[4] == 0x15 and p.b[5] == 0x01 and p.b[6] ~= 0x02 then assert(p.b[6] <= 30, "speed above 3 km/h sent") end
end

-- Space during a test stops the belt immediately
sent, state, speed = {}, "idle", 0
padtest.arm(fake, lg); padtest.start()
padtest.stop("Space pressed")
assert(sent[#sent] == sperax.hex(sperax.encode({ 0x15, 0x00, 0x00, 0x00 })), "stop not sent")
print("padtest tests passed")
