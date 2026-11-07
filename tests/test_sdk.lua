-- Game SDK over shared memory, end to end:
--   the real api.lua publishes, a C game in another process reads and asks for a hill,
--   the GMod module (built for Linux, loaded into this LuaJIT) reads too, and the hill reaches the bike.
package.path = "app/?.lua;" .. package.path
local clock = 0
love = { timer = { getTime = function() return clock end } }
local function sh(cmd) assert(os.execute(cmd) == 0 or os.execute(cmd) == true, cmd) end
sh("gcc -O2 -Wall -Werror -o /tmp/op_client tests/sdk/client.c sdk/omniplay.c -lm")
sh("gcc -O2 -Wall -Werror -shared -fPIC -o /tmp/gmcl_omniplay_test.so sdk/gmod/gmcl_omniplay.c sdk/omniplay.c -lm")
os.execute("rm -f /dev/shm/OmniPlay_v1")

local api = require("api")
local shm = require("shm")
local json = require("json")
local logs = {}
api.init(function(_, s) logs[#logs + 1] = s end, { port = 21893 })
local dev = { name = "EM 8000", kind = "ftms_bike", allow_hills = true }
local grades = {}
local ctl = { set_grade = function(p) grades[#grades + 1] = p; return true end, set_belt_speed = function() return false end }
local m = { speed_kmh = 25.6, cadence = 61, power = 140, moving = true }
local function step(n)
  for _ = 1, n or 1 do
    clock = clock + 0.05
    api.update(0.05, m, dev, "connected", ctl, { gait = "run" })
  end
end
step(3)

-- 1. a C game in its own process
local ffi = require("ffi")
pcall(ffi.cdef, "int usleep(unsigned);")
local function realtime(sec) for _ = 1, math.floor(sec / 0.05) do step(1); ffi.C.usleep(50000) end end
os.execute("/tmp/op_client > /tmp/op_out.txt &")
realtime(1.2) -- it connects, reads, asks for a hill and keeps its heartbeat ~1.5 s
local out = { io.open("/tmp/op_out.txt"):read("*l") }
print(out[1])
assert(out[1] and out[1]:match("^values 25.6 61 140 1 2 1 json %d+ ok"), "C client should read the values: " .. tostring(out[1]))
local g = api.games.shm
assert(g and g.name == 'C test "game"' and g.via == "shared memory", "game should be connected over shared memory")
assert(g.grade == 4.5 and g.take_input == true, "hill and take_input from the C game")
assert(api.take_input(), "keys paused while the game reads directly")
step(40) -- the hill ramps to 4.5 on the bike
assert(math.abs(grades[#grades] - 4.5) < 0.01, "hill should reach the bike, got " .. tostring(grades[#grades]))
-- the game exited without release: 3 s after its last heartbeat it's gone
realtime(3.6)
assert(not api.games.shm, "game should time out after its heartbeat stops")
step(100)
assert(grades[#grades] == 0, "hill back to flat")
print("C game over shared memory: values ok, hill 4.5 % reached the bike, timed out cleanly")

-- 2. release: gone at once
os.execute("/tmp/op_client release > /dev/null &")
realtime(2.5)
assert(not api.games.shm, "released game should be gone right away")

-- 3. the GMod module, loaded like GMod would (gmod13_open on a Lua state)
local open = assert(package.loadlib("/tmp/gmcl_omniplay_test.so", "gmod13_open"))
open()
local N = assert(omniplay_native, "module should create omniplay_native")
assert(N.Version == 1)
step(2)
assert(N.Running() == true, "module sees OmniPlay running")
local js, seq = N.State()
local st = json.decode(js)
assert(st.speed_kmh == 25.6 and st.gait == "run" and st.device.name == "EM 8000", "state JSON through the module")
local sp, cad, pw, hr, gr, mov, gait = N.Values()
assert(math.abs(sp - 25.6) < 0.01 and cad == 61 and pw == 140 and hr == nil and mov == true and gait == 2, "values through the module")
N.SetGame("PhysPlay"); N.SetGrade(-3); N.TakeInput(true)
step(2)
g = api.games.shm
assert(g and g.name == "PhysPlay" and g.grade == -3 and g.take_input, "requests through the module")
N.SetGrade(nil)
step(2)
assert(api.games.shm.grade == nil, "nil grade = flat")
N.Release()
step(2)
assert(not api.games.shm, "Release() lets go")
-- 4. the LÖVE / LuaJIT drop-in file
local L = dofile("sdk/love/omniplay.lua")
assert(L.running(), "LÖVE client sees OmniPlay")
local v = L.values()
assert(math.abs(v.speed_kmh - 25.6) < 0.01 and v.cadence == 61 and v.power == 140 and v.hr == nil and v.gait == "run" and v.kind == "bike" and v.moving, "LÖVE values")
assert(json.decode((L.state_json())).device.name == "EM 8000", "LÖVE state json")
L.set_game('Löve "test"'); L.set_grade(7); L.take_input(true)
step(2)
g = api.games.shm
assert(g and g.name == 'Löve "test"' and g.grade == 7 and g.take_input, "LÖVE requests")
L.release()
step(2)
assert(not api.games.shm, "LÖVE release")
print("LÖVE file: values, state, requests and release ok")

-- 5. the GMod addon on top of the module (fake GMod client environment)
local timers, hooks = {}, {}
SERVER, CLIENT = false, true
util = { IsBinaryModuleInstalled = function(n) return n == "omniplay" end, JSONToTable = json.decode, TableToJSON = json.encode }
local real_require = require
require = function(n) if n == "omniplay" then return true end return real_require(n) end -- already loaded above
timer = { Create = function(n, _, _, f) timers[n] = f end }
hook = { Run = function(n, ...) hooks[n] = { ... } end }
file = { CreateDir = function() error("data folder must not be used with the module") end, Read = function() error("no files") end, Write = function() error("no files") end }
net = setmetatable({}, { __index = function() return function() end end })
concommand = { Add = function() end }
RealTime = function() return clock end
math.Clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
IsValid = function() return false end
LocalPlayer = function() end
OmniPlay = nil
dofile("gmod/omniplay_bridge/lua/autorun/omniplay_bridge.lua")
require = real_require
assert(OmniPlay.Native, "addon should pick the module")
local function gm(n) for _ = 1, n do step(1); timers.OmniPlay_Read() end end
gm(3)
assert(OmniPlay.IsConnected() and OmniPlay.Get().speed_kmh == 25.6, "addon reads through the module")
assert(hooks.OmniPlay_Data and hooks.OmniPlay_Data[1].gait == "run", "OmniPlay_Data hook")
OmniPlay.SetGame("Gamemode X"); OmniPlay.SetGrade(5); OmniPlay.TakeInput(true)
gm(3)
g = api.games.shm
assert(g and g.name == "Gamemode X" and g.grade == 5 and g.take_input, "addon requests through the module")
OmniPlay.SetGrade(nil)
gm(3)
assert(api.games.shm.grade == nil, "addon: flat")
print("GMod addon with the module: reads, hook, requests ok")

-- 6. installing into Garry's Mod: none -> installed -> update -> uninstall
os.execute("rm -rf /tmp/omni-inst && mkdir -p /tmp/omni-inst/app/gmod-module /tmp/omni-inst/app/gmod-addon /tmp/omni-inst/GarrysMod/garrysmod/data")
os.execute("echo a > /tmp/omni-inst/app/gmod-module/gmcl_omniplay_win32.dll; echo b > /tmp/omni-inst/app/gmod-module/gmcl_omniplay_win64.dll")
os.execute("cp -r gmod/omniplay_bridge /tmp/omni-inst/app/gmod-addon/")
api.app_dir, api.gmod_dir = "/tmp/omni-inst/app", "/tmp/omni-inst/GarrysMod/garrysmod/data"
assert(api.gmod_module_status() == "none")
assert(api.gmod_install())
assert(api.gmod_module_status() == "installed")
assert(io.open("/tmp/omni-inst/GarrysMod/garrysmod/lua/bin/gmcl_omniplay_win64.dll"), "module in lua/bin")
assert(io.open("/tmp/omni-inst/GarrysMod/garrysmod/addons/omniplay_bridge/lua/autorun/omniplay_bridge.lua"), "addon installed")
os.execute("echo c > /tmp/omni-inst/app/gmod-module/gmcl_omniplay_win64.dll")
assert(api.gmod_module_status() == "update")
assert(api.gmod_install() and api.gmod_module_status() == "installed")
assert(api.gmod_uninstall() and api.gmod_module_status() == "none")
print("GMod install / update / uninstall ok")

-- 7. app closes: games see it at once
api.shutdown()
assert(N.Running() == false and N.State() == nil, "after the app closes the module says not running")
print("GMod module: state, values, requests and release ok")
print("sdk tests passed")
