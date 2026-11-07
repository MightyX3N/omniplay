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
    getDirectoryItems = function(dir)
      local out = {}
      for k in pairs(mem) do local f = k:match("^" .. dir:gsub("%-", "%%-") .. "/([^/]+)$"); if f then out[#out + 1] = f end end
      return out
    end,
    getSource = function() return "/tmp/omni-main" end,
    getSourceBaseDirectory = function() return "/tmp/omni-main" end,
    getSaveDirectory = function() return "/tmp/omni-main/save" end,
  },
  graphics = graphics,
  mouse = { isDown = function() return false end, getPosition = function() return 0, 0 end, setCursor = noop, getSystemCursor = noop },
  timer = { getTime = function() return clock end },
  window = { setTitle = noop },
  system = { setClipboardText = noop, openURL = noop },
}

-- ---------- fake helper DLL ----------
local function put(buf, max, s) local n = math.min(#s, max - 1); ffi.copy(buf, s, n); buf[n] = 0; return n end
local function hexb(h) local t = {} for x in h:gmatch("%x%x") do t[#t + 1] = tonumber(x, 16) end return t end
local PEDAL = hexb("FE 1F 00 0A 00 00 AA 00 00 00 00 00 00 0C 00 8C 00 00 00 00 00 00 00 00 82 00 3D 00 00 00")
local fake = { explore = 0, writes = {}, pedalling = true, crank = true, conns = {} }
local U = function(id) return "0000" .. id .. "-0000-1000-8000-00805f9b34fb" end
local EXPLORE = {
  AABBCCDDEEFF = { "service " .. U("1826"), "char " .. U("2acc") .. " props 2", "char " .. U("2ad2") .. " props 10",
    "char " .. U("2ad9") .. " props 28", "listening 500" },
  ["778899AABBCC"] = { "service " .. U("1816"), "char " .. U("2a5b") .. " props 16", "listening 500" },
  ["5A5A5A5A5A5A"] = { "service " .. U("fff0"), "char " .. U("fff1") .. " props 16", "char " .. U("fff2") .. " props 12", "listening 500" },
  ["CCDDEEFF0011"] = { "service " .. U("1826"), "char " .. U("2acd") .. " props 16", "char " .. U("2ad9") .. " props 28", "listening 500" },
}
local lib = {
  sb_last_error = function() return "fake error" end,
  sb_status_text = function() return "" end,
  sb_scan_start = function() return 0 end,
  sb_scan_stop = noop,
  sb_scan_list = function(buf, max) return put(buf, max,
    "HT2405118\tAABBCCDDEEFF\t-60\t100\t1\nROCKBROS C\t778899AABBCC\t-55\t100\t4\nTV\t112233445566\t-80\t100\t0\n" ..
    (fake.treadmill and "Treadmill\tCCDDEEFF0011\t-50\t100\t1\n" or "") ..
    (fake.sperax and "SPERAX_RM01\t5A5A5A5A5A5A\t-50\t100\t1\n" or "")) end,
  sb_open_h = function(addr) local h = #fake.conns fake.conns[h + 1] = { addr = ffi.string(addr), state = 1, open_t = clock, q = {} } return h end,
  sb_state_h = function(h) local c = fake.conns[h + 1] return c and c.state or 0 end,
  sb_error_h = function() return "fake error" end,
  sb_status_h = function() return "" end,
  sb_dropped_h = function() return 0 end,
  sb_write_h = function(h, buf, n)
    local t = {} for i = 0, n - 1 do t[#t + 1] = buf[i] end
    t.addr = fake.conns[h + 1] and fake.conns[h + 1].addr
    fake.writes[#fake.writes + 1] = t
    -- the fake treadmill follows speed commands like a real one
    if t.addr == "CCDDEEFF0011" and t[1] == 0x02 then fake.belt = (t[2] + t[3] * 256) / 100 end
    -- Sperax speed command F5 .. 15 01 <kmh*10> ..: the pad's belt moves toward it at its own pace
    if t.addr == "5A5A5A5A5A5A" and t[4] == 0x15 and t[5] == 0x01 then fake.sp_cmd = t[6] / 10 end
    if t.addr == "CCDDEEFF0011" and t[1] == 0x03 then fake.incline_set = (t[2] + t[3] * 256) / 10 end
    return 0
  end,
  sb_read_h = function(h, buf, max, which)
    local c = fake.conns[h + 1]
    local p = c and table.remove(c.q, 1)
    if not p then return 0 end
    for i = 1, #p do buf[i - 1] = p[i] end
    which[0] = 0
    return #p
  end,
  sb_close_h = function(h) local c = fake.conns[h + 1] if c then c.state = 0 end end,
  sb_explore = function(addr) fake.explore, fake.ex_t, fake.ex_addr = 1, clock, ffi.string(addr); return 0 end,
  sb_explore_state = function() if fake.explore == 1 and clock - fake.ex_t > 0.6 then fake.explore = 2 end return fake.explore end,
  sb_explore_text = function(buf, max) return put(buf, max, table.concat(EXPLORE[fake.ex_addr], "\n") .. "\n") end,
}
package.loaded["ble"] = { load = function() return lib end }

require("main")
local T = love._omniplay
love.load()
assert(require("output").profiles[1].name == "Old profile", "old saved profiles should be migrated")
assert(not io.open("/tmp/omni-main/save/profiles.lua"), "old file should be gone")

local tabs = { "Ride", "Routes", "Devices", "Games", "History", "Settings" }
local frame = 0
local function step(dt)
  clock = clock + dt
  frame = frame + 1
  for _, c in ipairs(fake.conns) do
    if c.state == 1 and clock - c.open_t > 0.5 then c.state = 2 end
    if c.state == 2 and c.addr == "AABBCCDDEEFF" and fake.pedalling and frame % 4 == 0 then c.q[#c.q + 1] = PEDAL end
    -- cadence sensor: 90 rpm while the crank turns; a packet every second either way
    if c.state == 2 and c.addr == "778899AABBCC" and frame % 20 == 0 then
      if fake.crank then fake.revs = (fake.revs or 0) + 1.5 fake.ctime = (fake.ctime or 0) + 1024 end
      local r, t = math.floor(fake.revs or 0) % 65536, math.floor((fake.ctime or 0) * (math.floor(fake.revs or 0) / math.max(1, fake.revs or 1))) % 65536
      c.q[#c.q + 1] = { 2, r % 256, math.floor(r / 256), t % 256, math.floor(t / 256) }
    end
    if c.state == 2 and c.addr == "5A5A5A5A5A5A" and frame % 5 == 0 then
      local sp = require("drivers.sperax")
      if fake.sp_cmd and fake.sp_on then
        local v = fake.sp_speed
        fake.sp_speed = v < fake.sp_cmd and math.min(fake.sp_cmd, v + 0.12) or math.max(fake.sp_cmd, v - 0.12)
      end
      local v10 = math.floor(fake.sp_speed * 10 + 0.5)
      c.q[#c.q + 1] = sp.encode({ 0x19, 0, 0, fake.sp_on and 0x10 or 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, v10, 0, 0, 0 })
    end
    if c.state == 2 and c.addr == "CCDDEEFF0011" and frame % 5 == 0 then
      local v = math.floor((fake.belt or 0) * 100 + 0.5)
      if fake.tilts then c.q[#c.q + 1] = { 0x08, 0, v % 256, math.floor(v / 256), 0, 0, 0, 0 }
      else c.q[#c.q + 1] = { 0, 0, v % 256, math.floor(v / 256) } end
    end
  end
  T.set_tab(tabs[frame % 6 + 1])
  love.update(dt)
  love.draw()
end
local function run(s) for _ = 1, s * 20 do step(0.05) end end

run(1)
local list = T.nearby()
assert(#list == 3 and list[1].fitness and list[2].fitness and not list[3].fitness, "fitness devices should be listed first")
table.sort(list, function(a, b) return a.name < b.name end)
local bike_entry, sensor_entry = list[1], list[2]
assert(bike_entry.name == "HT2405118" and sensor_entry.name == "ROCKBROS C")
list = { bike_entry }
T.add_device(list[1])
run(3)
local saved = T.saved()
assert(#saved.devices == 1 and saved.devices[1].kind == "ftms_bike", "bike should be added as an FTMS bike")
local devices = require("devices")
assert(devices.state == "connected", "should be connected, is " .. devices.state)
assert(devices.m.cadence and devices.m.cadence > 0, "should decode cadence")

-- add the cadence sensor too: both stay connected, the sensor decides moving / cadence
T.add_device(sensor_entry)
run(5)
saved = T.saved()
assert(#saved.devices == 2 and saved.devices[2].kind == "csc", "sensor should be added as a cadence sensor")
assert(devices.state_of(saved.devices[1]) == "connected" and devices.state_of(saved.devices[2]) == "connected", "both connected")
assert(devices.m.sources.moving == "sensor" and devices.m.moving, "moving should come from the sensor")
print(string.format("bike + sensor: %.1f km/h from the bike, %d rpm from the sensor", devices.m.speed_kmh, devices.m.cadence))
assert(math.abs(devices.m.cadence - 90) < 3, "sensor cadence ~90 rpm, got " .. devices.m.cadence)
fake.crank = false
run(2.5)
assert(not devices.m.moving and devices.m.cadence == 0, "crank stopped -> still within ~2 s, though the bike still sends")
fake.crank = true
run(2)
assert(devices.m.moving, "pedalling again")

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

-- routes: drop a GPX on the window, ride it; with the game gone, the route's hill reaches the bike
ws:close()
run(5)
assert(not api.game_name(), "game should have left")
local g = { '<gpx><trk><name>Hill test</name><trkseg>' }
for i = 0, 200 do -- 2 km flat, then a steady 6 % climb
  local dm = i * 20
  g[#g + 1] = string.format('<trkpt lat="45.0" lon="%.6f"><ele>%.1f</ele></trkpt>', dm / 78710, dm > 2000 and (dm - 2000) * 0.06 or 0)
end
g[#g + 1] = '</trkseg></trk></gpx>'
local gpx = table.concat(g)
love.filedropped({ getFilename = function() return "C:\\Users\\x\\hill test.gpx" end, open = noop, close = noop, read = function() return gpx end })
local rt = T.rt()
local function route_factor(g) return require("route").walk_factor(g, 1) end
assert(rt.sel == "hill test.gpx" and mem["data/routes/hill test.gpx"], "dropped GPX should be imported")
local r = require("route").load(rt.sel)
assert(math.abs(r.length - 4000) < 30 and math.abs(r.climb - 120) < 8, "route stats: " .. r.length .. " m, climb " .. r.climb)
rt.ride = { r = r, pos = 2600, climbed = 0 }
run(4)
local last
for _, w in ipairs(fake.writes) do if w[1] == 0x11 then last = w end end
local sent = (last[4] + last[5] * 256) / 100
assert(math.abs(sent - 6) < 0.3, "route hill should reach the bike, sent " .. sent)
assert(rt.ride.pos > 2600, "position should move with speed")
rt.strength = 0.5
run(4)
for _, w in ipairs(fake.writes) do if w[1] == 0x11 then last = w end end
sent = (last[4] + last[5] * 256) / 100
assert(math.abs(sent - 3) < 0.3, "half hills should send half, sent " .. sent)
print(string.format("route: %.1f km, climb %d m, hill sent %.1f %% at half strength", r.length / 1000, r.climb, sent))
rt.ride = nil
run(3)
-- camera only: no Bluetooth device, the camera page drives speed (cycling 90 rpm ~ 29 km/h)
devices.disconnect()
run(0.1)
local api2 = require("api")
for _ = 1, 40 do api2.camera = { moving = true, cadence = 90, fps = 30, activity = "cycling", t = api2.now() } run(0.05) end
local st = require("json").decode(api2.last_state)
assert(st.camera and st.device.name == "Camera" and math.abs(st.speed_kmh - 28.8) < 0.5 and st.moving, "camera-only state")
for _ = 1, 10 do api2.camera = { moving = false, cadence = 0, fps = 30, activity = "cycling", t = api2.now() } run(0.05) end
st = require("json").decode(api2.last_state)
assert(st.speed_kmh == 0 and not st.moving, "camera says still -> stopped at once")
-- walking pad on a route: slower uphill, faster gently downhill, the remote sets a new pace
fake.treadmill, fake.belt = true, 4.0
run(1.5)
local tm
for _, n in ipairs(T.nearby()) do if n.name == "Treadmill" then tm = n end end
assert(tm, "treadmill should be listed")
T.add_device(tm)
run(3)
local tdev = T.saved().devices[#T.saved().devices]
assert(tdev.kind == "ftms_treadmill" and devices.state_of(tdev) == "connected", "treadmill connected")
tdev.allow_speed, tdev.max_speed = true, 6
rt.strength, rt.walk = 1, 4
rt.ride = { r = r, pos = 2400, climbed = 0 } -- on the 6 % climb
run(20)
local want = 4 * route_factor(6)
assert(math.abs(fake.belt - want) < 0.15, string.format("uphill belt %.2f, want %.2f", fake.belt, want))
print(string.format("walking: 6 %% climb -> belt %.1f km/h (flat pace 4.0)", fake.belt))
-- remote: the walker speeds up to 3.8; after a few seconds that becomes the new pace
fake.belt = 3.8
run(4)
assert(math.abs(rt.walk - 3.8 / route_factor(6)) < 0.15, "remote change should set a new flat pace, got " .. rt.walk)
assert(math.abs(fake.belt - 3.8) < 0.15, "and the belt stays where the walker put it, " .. fake.belt)
-- stopped: the app never starts the belt again
fake.belt = 0
local nw = #fake.writes
run(4)
for i = nw + 1, #fake.writes do assert(not (fake.writes[i].addr == "CCDDEEFF0011" and fake.writes[i][1] == 0x02), "must not start a stopped belt") end
fake.belt = 3.8
-- a treadmill that tilts gets the hill as incline and keeps its speed
fake.tilts, fake.incline_set = true, nil
local before = fake.belt
run(3)
assert(fake.incline_set and math.abs(fake.incline_set - 6) < 0.3, "tilting treadmill should get the incline, got " .. tostring(fake.incline_set))
assert(math.abs(fake.belt - before) < 0.05, "and its speed is left alone")
rt.ride = nil
-- Sperax: started with its remote, the belt crawls at 0.3 km/h. The route must take it up to
-- the walking pace by itself, and that slow start must not count as "you changed the speed".
devices.disconnect(tdev)
fake.sperax, fake.sp_on, fake.sp_speed, fake.sp_cmd = true, false, 0, nil
run(1.5)
local spx
for _, n in ipairs(T.nearby()) do if n.name == "SPERAX_RM01" then spx = n end end
assert(spx, "sperax should be listed")
T.add_device(spx)
run(3)
local sdev = T.saved().devices[#T.saved().devices]
assert(sdev.kind == "sperax" and devices.state_of(sdev) == "connected", "sperax connected")
sdev.allow_speed, sdev.max_speed = true, 6
rt.walk = 4
rt.ride = { r = r, pos = 100, climbed = 0 } -- flat part
run(3)
assert(not fake.sp_cmd, "stopped pad: no speed commands")
fake.sp_on, fake.sp_speed = true, 0.3
run(40)
assert(math.abs(fake.sp_speed - 4) < 0.15, string.format("pad should reach 4 km/h by itself, at %.2f", fake.sp_speed))
assert(math.abs(rt.walk - 4) < 0.05, "slow start must not change the pace, got " .. rt.walk)
print(string.format("sperax: started at 0.3, route took it to %.1f km/h", fake.sp_speed))
rt.ride = nil
love.keypressed("f8")
local output = require("output")
assert(output.enabled, "F8 should enable output")
love.quit()
assert(mem["data/devices.lua"] and mem["data/devices.lua"]:find("HT2405118"), "devices should be saved")
for _, e in ipairs(T.log()) do print("  " .. e.kind .. " " .. e.text) end
print("main smoke test ok")
