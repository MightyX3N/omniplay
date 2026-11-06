-- Session recording with a fake clock and filesystem: auto start, pause, finish, export.
package.path = "app/?.lua;" .. package.path
local mem = {}
os.execute("mkdir -p /tmp/omni-test/activities")
love = {
  filesystem = {
    write = function(n, d) mem[n] = d; return true end,
    read = function(n) return mem[n] end,
    getInfo = function(n) return mem[n] and {} or nil end,
    remove = function(n) mem[n] = nil end,
    createDirectory = function() end,
    getSourceBaseDirectory = function() return "/tmp/omni-test" end,
  },
}
local session = require("session")
local export = require("export")
local logs = {}
session.init(function(k, t) logs[#logs + 1] = t end)

local dev = { name = "Christopeit EM 8000", kind = "ftms_bike" }
local m = { moving = false, speed_kmh = 0 }
local function run(seconds, moving, kmh, watts)
  m.moving, m.speed_kmh, m.power, m.cadence, m.hr = moving, kmh, watts, moving and 80 or 0, 130
  for _ = 1, seconds * 4 do session.update(0.25, m, dev) end
end

run(5, false, 0)
assert(session.state == "idle", "should not record while still")
run(600, true, 27, 150)        -- 10 minutes riding
assert(session.state == "recording")
run(10, false, 0)
assert(session.state == "paused", "should pause after 5 s still")
run(60, true, 27, 150)
assert(session.state == "recording", "should resume")
run(125, false, 0)             -- long stop: finishes and saves
assert(session.state == "idle" and #session.history == 1, "should finish after 2 min still")
local h = session.history[1]
print(string.format("saved: %s %.2f km %d s %d kcal avg %s W", h.sport, h.distance / 1000, h.elapsed, h.kcal, tostring(h.avg_power)))
assert(h.sport == "cycling" and math.abs(h.elapsed - 667) <= 3, "elapsed " .. h.elapsed)
assert(math.abs(h.distance - 27 / 3.6 * h.elapsed) < 120, "distance " .. h.distance) -- idle seconds before a pause count at 0 km/h
assert(h.avg_power == 150 and h.kcal >= 95 and h.kcal <= 101, "power/kcal " .. h.kcal)
local f = io.open(h.fit, "rb"); assert(f, "FIT file missing: " .. tostring(h.fit))
local fit = f:read("*a"); f:close()
assert(fit:sub(9, 12) == ".FIT", "bad FIT header")
local crc = fit:byte(#fit - 1) + fit:byte(#fit) * 256
assert(crc == export.fit_crc(fit:sub(1, #fit - 2)), "bad FIT CRC")
assert(io.open((h.fit:gsub("%.fit$", ".tcx"))), "TCX missing")

-- short sessions are dropped
run(3, true, 3, nil); run(10, false, 0); run(125, false, 0)
assert(#session.history == 1, "a few seconds should not be saved")

-- crash recovery: an open current.lua is finished on startup
for _ = 1, 4 * 70 do session.update(0.25, { moving = true, speed_kmh = 4, cadence = 100 }, { name = "Sperax P1", kind = "sperax" }) end
package.loaded.session = nil
local s2 = require("session")
s2.init(function() end)
assert(#s2.history == 2 and s2.history[1].sport == "walking", "recovery failed")
print("FIT for checking: " .. h.fit)
print("session tests passed")
