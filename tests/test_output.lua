-- Game output: gait thresholds, held keys, dropout hold, profile switching, focus safety.
package.path = "app/?.lua;" .. package.path
local mem = {}
love = { filesystem = { write = function(n, d) mem[n] = d; return true end, read = function(n) return mem[n] end,
  getInfo = function(n) return mem[n] and {} or nil end } }
local out = require("output")
out.init(function() end)
local events, fg, self = {}, "skyrimse.exe", false
out._send_key = function(k, down) events[#events + 1] = (down and "+" or "-") .. k end
out._foreground = function() return fg, self end
local function step(m, kind, secs) for _ = 1, math.floor((secs or 0.5) * 10) do out.update(0.1, m, kind) end end
local function held() return table.concat(out.held_keys(), ",") end

step({ moving = true, speed_kmh = 2 }, "sperax")
assert(out.gait == "walk" and held() == "", "output off: nothing pressed")
out.toggle()
step({ moving = true, speed_kmh = 2 }, "sperax")
assert(held() == "lalt,w", "walk keys: " .. held())
step({ moving = true, speed_kmh = 4 }, "sperax")
assert(out.gait == "run" and held() == "w", "run keys: " .. held())
step({ moving = true, speed_kmh = 5.5 }, "sperax")
assert(out.gait == "sprint" and held() == "lshift,w", "sprint keys: " .. held())
-- bike thresholds: cadence for walk/run, watts for sprint
step({ moving = true, cadence = 75, power = 120 }, "ftms_bike")
assert(out.gait == "run", "bike run")
step({ moving = true, cadence = 95, power = 260 }, "ftms_bike")
assert(out.gait == "sprint", "bike sprint")
-- a 1 s dropout keeps moving, a 3 s stop releases everything
step({ moving = false }, "ftms_bike", 1)
assert(held() == "lshift,w", "dropout should hold keys")
step({ moving = false }, "ftms_bike", 2.5)
assert(held() == "", "stop should release keys: " .. held())
-- profile switches with the foreground game; focusing OmniPlay releases keys
fg = "gmod.exe"
step({ moving = true, speed_kmh = 2 }, "sperax")
assert(out.profile.name == "Garry's Mod", "profile switch")
self = true
step({ moving = true, speed_kmh = 2 }, "sperax")
assert(held() == "", "no keys into OmniPlay's own window")
self = false
step({ moving = true, speed_kmh = 2 }, "sperax")
out.toggle()
assert(held() == "", "turning output off releases keys")
-- every press has a matching release
local bal = {}
for _, e in ipairs(events) do local k = e:sub(2); bal[k] = (bal[k] or 0) + (e:sub(1, 1) == "+" and 1 or -1) end
for k, v in pairs(bal) do assert(v == 0, "unbalanced key " .. k) end
print("output tests passed")
