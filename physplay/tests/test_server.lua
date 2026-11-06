-- Server: a keyboard rider and a bike rider (power from OmniPlay) ride Rolling Hills for 10 minutes.
assert(loadfile("tests/gmod_stub.lua"))("server")
include("init.lua")
local kb, bike = STUB.player(1, "Keys"), STUB.player(2, "Patrick")
kb.keys[IN_FORWARD] = true
local grades = {}
bike.OmniPlayData = function() return { kind = "bike", power = 200, cadence = 85, hr = 140, speed_kmh = 30 } end
bike.OmniPlaySetGrade = function(_, g) grades[#grades + 1] = g end
bike.info.physplay_difficulty = "50"
for _, p in ipairs({ kb, bike }) do GM:PlayerInitialSpawn(p) GM:PlayerSpawn(p) end
-- run the Think hook with a fake clock
local t = 0
local real = SysTime
local now = 0
SysTime = function() return now end
for _ = 1, 600 * 20 do now = now + 0.05 STUB.hooks.Think.PhysPlaySim() end
local rk, rb = PP.riders[kb], PP.riders[bike]
local function total(rd) return rd.laps * PP.route.length + rd.d end
print(string.format("keyboard: %.2f km, %.1f km/h now; bike: %.2f km, lap %d", total(rk) / 1000, rk.v * 3.6, total(rb) / 1000, rb.laps + 1))
assert(total(rk) > 3500 and total(rk) < 7000, "keyboard rider distance off")
assert(math.abs(rb.v * 3.6 - 30) < 0.5, "bike rider should follow the bike's speed (30 km/h), is " .. rb.v * 3.6)
assert(#grades > 100, "grades should be sent to the trainer")
local gmax = -99 for _, g in ipairs(grades) do gmax = math.max(gmax, g) end
print(string.format("trainer got %d grade updates, steepest %.1f %% (50%% difficulty)", #grades, gmax))
assert(gmax > 1 and gmax < 8)
-- state messages go out
local last = STUB.sent[#STUB.sent]
assert(last.name == "physplay_state" and last[1] == 2, "state broadcast")
-- you stop pedalling: the console shows 0 W but its flywheel still says 27 km/h
PP.route = PP.routes["riverside-flats"] -- flat
rb.d = 1000
bike.OmniPlayData = function() return { kind = "bike", power = 0, cadence = 0, speed_kmh = 27 } end
for _ = 1, 40 do now = now + 0.05 STUB.hooks.Think.PhysPlaySim() end
print(string.format("2 s after power drops to 0 (flywheel still 27 km/h): %.1f km/h", rb.v * 3.6))
assert(rb.v * 3.6 < 8, "should stop without waiting for the flywheel")
-- the real EM 8000: numbers freeze at the last value when you stop, then drop to 0 seconds later
bike.OmniPlayData = function() return { kind = "bike", power = 28, cadence = 68, speed_kmh = 25.4 } end
for _ = 1, 40 do now = now + 0.05 STUB.advance(0.05) STUB.hooks.Think.PhysPlaySim() end
local v_riding = rb.v * 3.6
for _ = 1, 80 do now = now + 0.05 STUB.advance(0.05) STUB.hooks.Think.PhysPlaySim() end
print(string.format("frozen reading: %.1f km/h while fresh, %.1f km/h after 6 s frozen", v_riding, rb.v * 3.6))
assert(v_riding > 20 and rb.v * 3.6 < 5, "frozen numbers should count as stopped")
-- lane change
bike.keys[IN_MOVERIGHT] = true
local l0 = rb.lane
for _ = 1, 20 do now = now + 0.05 STUB.hooks.Think.PhysPlaySim() end
assert(rb.lane > l0 or rb.lane == PP.route.lanes - 1, "lane should move right")
print("server tests passed")
