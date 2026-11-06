-- Headless smoke test of the whole app: fake LÖVE, fake Bluetooth helper with a simulated
-- FTMS bike. Adds the bike, connects, pedals 2 minutes, finishes, checks history + files,
-- and draws every tab each step so UI code paths run.
package.path = "app/?.lua;" .. package.path
local ffi = require("ffi")
os.execute("rm -rf /tmp/omni-main && mkdir -p /tmp/omni-main/activities /tmp/omni-main/save")
-- a profiles file from an older build sits at the top of the save folder: it must move to data/
local old = io.open("/tmp/omni-main/save/profiles.lua", "w")
old:write('return { { name = "Old profile", exe = "", walk = { keys = { "w" }, pad_kmh = 1, rpm = 30 }, run = { keys = { "w" }, pad_kmh = 3.5, rpm = 70 }, sprint = { keys = { "w", "lshift" }, pad_kmh = 5, watts = 200 }, hold_s = 2 } }\n')
old:close()

local mem, clock = {}, 0
local noop = function() end
local font = { getWidth = function(_, s) return #tostring(s) * 7 end, getHeight = function() return 14 end }
local graphics = setmetatable({
  newFont = function() return font end,
  getDimensions = function() return 1100, 720 end,
}, { __index = function() return noop end })
love = {
  filesystem = {
    write = function(n, d) mem[n] = d; return true end,
    read = function(n) return mem[n] end,
    getInfo = function(n) return mem[n] and {} or nil end,
    remove = function(n) mem[n] = nil end,
    createDirectory = noop,
    getSource = function() return "/tmp/omni-main" end,
    getSourceBaseDirectory = function() return "/tmp/omni-main" end,
    getSaveDirectory = function() return "/tmp/omni-main/save" end,
  },
  graphics = graphics,
  mouse = { getPosition = function() return 0, 0 end, setCursor = noop, getSystemCursor = noop },
  timer = { getTime = function() return clock end },
  window = { setTitle = noop },
  system = { setClipboardText = noop, openURL = noop },
}

-- ---------- fake helper DLL ----------
local function put(buf, max, s) local n = math.min(#s, max - 1); ffi.copy(buf, s, n); buf[n] = 0; return n end
local function hexb(h) local t = {} for x in h:gmatch("%x%x") do t[#t + 1] = tonumber(x, 16) end return t end
local PEDAL = hexb("FE 1F 00 0A 00 00 AA 00 00 00 00 00 00 0C 00 8C 00 00 00 00 00 00 00 00 82 00 3D 00 00 00")
local fake = { state = 0, explore = 0, writes = {}, pedalling = true, drop_at = nil }
local U = function(id) return "0000" .. id .. "-0000-1000-8000-00805f9b34fb" end
local EXPLORE = table.concat({ "service " .. U("1826"), "char " .. U("2acc") .. " props 2", "char " .. U("2ad2") .. " props 10",
  "char " .. U("2ad9") .. " props 28", "listening 500" }, "\n") .. "\n"
local queue = {}
local lib = {
  sb_last_error = function() return "fake error" end,
  sb_status_text = function() return "" end,
  sb_state = function() return fake.state end,
  sb_scan_start = function() return 0 end,
  sb_scan_stop = noop,
  sb_scan_list = function(buf, max) return put(buf, max, "HT2405118\tAABBCCDDEEFF\t-60\t100\t1\nTV\t112233445566\t-80\t100\t0\n") end,
  sb_open = function() fake.state, fake.open_t = 1, clock; return 0 end,
  sb_write = function(buf, n) local t = {} for i = 0, n - 1 do t[#t + 1] = buf[i] end fake.writes[#fake.writes + 1] = t; return 0 end,
  sb_read_ex = function(buf, max, which)
    local p = table.remove(queue, 1)
    if not p then return 0 end
    for i = 1, #p do buf[i - 1] = p[i] end
    which[0] = 0
    return #p
  end,
  sb_dropped = function() return 0 end,
  sb_close = function() fake.state = 0 end,
  sb_set_cache_mode = noop,
  sb_explore = function() fake.explore, fake.ex_t = 1, clock; return 0 end,
  sb_explore_state = function() if fake.explore == 1 and clock - fake.ex_t > 0.6 then fake.explore = 2 end return fake.explore end,
  sb_explore_text = function(buf, max) return put(buf, max, EXPLORE) end,
}
package.loaded["ble"] = { load = function() return lib end }

require("main")
local T = love._omniplay
love.load()
assert(require("output").profiles[1].name == "Old profile", "old saved profiles should be migrated")
assert(not io.open("/tmp/omni-main/save/profiles.lua"), "old file should be gone")

local tabs = { "Session", "Devices", "Profiles", "History" }
local frame = 0
local function step(dt)
  clock = clock + dt
  frame = frame + 1
  if fake.state == 1 and clock - fake.open_t > 0.5 then fake.state = 2 end
  if fake.state == 2 and fake.pedalling and frame % 4 == 0 then queue[#queue + 1] = PEDAL end
  T.set_tab(tabs[frame % 4 + 1])
  love.update(dt)
  love.draw()
end
local function run(s) for _ = 1, s * 20 do step(0.05) end end

run(1)
local list = T.nearby()
assert(#list == 2 and list[1].name == "HT2405118" and list[1].fitness, "bike should be listed first")
T.add_device(list[1])
run(3)
local saved = T.saved()
assert(#saved.devices == 1 and saved.devices[1].kind == "ftms_bike", "bike should be added as an FTMS bike")
local devices = require("devices")
assert(devices.state == "connected", "should be connected, is " .. devices.state)
assert(devices.m.cadence and devices.m.cadence > 0, "should decode cadence")

-- a game connects over the mod API and asks for a hill; it must reach the bike as FTMS simulation (0x11)
local socket = require("socket")
local bit = require("bit")
local ws = assert(socket.connect("127.0.0.1", 21890)); ws:settimeout(0)
ws:send("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
run(0.5)
local msg = '{"game":"PhysPlay","grade":5,"take_input":true}'
local t = {}
for i = 1, #msg do t[i] = string.char(bit.bxor(msg:byte(i), 7)) end
ws:send(string.char(0x81, 0x80 + #msg, 7, 7, 7, 7) .. table.concat(t))
run(3)
local api = require("api")
assert(api.game_name() == "PhysPlay", "game should show up")
local sim
for _, w in ipairs(fake.writes) do if w[1] == 0x11 then sim = w end end
assert(sim and sim[4] + sim[5] * 256 == 500, "5% hill should reach the bike")
assert(require("output").suppressed, "keys should pause while the game reads input")

run(120)
local session = require("session")
assert(session.state == "recording", "should be recording, is " .. session.state)

-- dropout: no data for 8 s -> watchdog reconnects, then data resumes
fake.pedalling = false
run(8)
fake.pedalling = true
run(5)
assert(devices.state == "connected", "should have reconnected, is " .. devices.state)

session.finish()
assert(#session.history == 1, "session should be in history")
local h = session.history[1]
assert(h.sport == "cycling" and h.elapsed > 100, "bad summary")
local f = io.open("/tmp/omni-main/activities/OmniPlay-" .. h.id .. "-cycling.fit", "rb")
assert(f, "FIT file should exist"); f:close()
run(1) -- draw history with the saved session
love.keypressed("f8")
local output = require("output")
assert(output.enabled, "F8 should enable output")
love.quit()
assert(mem["data/devices.lua"] and mem["data/devices.lua"]:find("HT2405118"), "devices should be saved")
for _, e in ipairs(T.log()) do print("  " .. e.kind .. " " .. e.text) end
print("main smoke test ok")
