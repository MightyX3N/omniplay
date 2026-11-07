-- Real-LÖVE screenshot run: the whole app with simulated devices (bike, cadence sensor, HR strap),
-- a phone camera and a connected game; saves one PNG per tab. Run with tests/shots/run.sh
local ffi = require("ffi")
local clock = 0
love.timer.getTime = function() return clock end
local function put(buf, max, s) local n = math.min(#s, max - 1); ffi.copy(buf, s, n); buf[n] = 0; return n end
local function hexb(h) local t = {} for x in h:gmatch("%x%x") do t[#t + 1] = tonumber(x, 16) end return t end
local PEDAL = hexb("FE 1F 00 0A 00 00 AA 00 00 00 00 00 00 0C 00 8C 00 00 00 00 00 00 00 00 82 00 3D 00 00 00")
local fake = { explore = 0, writes = {}, conns = {} }
local U = function(id) return "0000" .. id .. "-0000-1000-8000-00805f9b34fb" end
local EXPLORE = {
  AABBCCDDEEFF = { "service " .. U("1826"), "char " .. U("2acc") .. " props 2", "char " .. U("2ad2") .. " props 10", "char " .. U("2ad9") .. " props 28", "listening 500" },
  ["778899AABBCC"] = { "service " .. U("1816"), "char " .. U("2a5b") .. " props 16", "listening 500" },
  ["A1B2C3D4E5F6"] = { "service " .. U("180d"), "char " .. U("2a37") .. " props 16", "listening 500" },
}
local noop = function() end
local lib = setmetatable({
  sb_last_error = function() return "fake" end, sb_status_text = function() return "" end,
  sb_scan_start = function() return 0 end, sb_scan_stop = noop,
  sb_scan_list = function(buf, max) return put(buf, max,
    "HT2405118\tAABBCCDDEEFF\t-60\t100\t1\nROCKBROS C3\t778899AABBCC\t-55\t100\t4\nPolar H10\tA1B2C3D4E5F6\t-58\t100\t16\nLE-TV\t112233445566\t-80\t100\t0\n") end,
  sb_open_h = function(addr) local h = #fake.conns fake.conns[h + 1] = { addr = ffi.string(addr), state = 1, open_t = clock, q = {} } return h end,
  sb_state_h = function(h) local c = fake.conns[h + 1] return c and c.state or 0 end,
  sb_error_h = function() return "fake" end, sb_status_h = function() return "" end, sb_dropped_h = function() return 0 end,
  sb_write_h = function() return 0 end,
  sb_tls_start = function() return 0 end, sb_tls_status = function() return "fake tls" end,
  sb_read_h = function(h, buf, max, which)
    local c = fake.conns[h + 1]; local p = c and table.remove(c.q, 1)
    if not p then return 0 end
    for i = 1, #p do buf[i - 1] = p[i] end; which[0] = 0; return #p
  end,
  sb_close_h = function(h) local c = fake.conns[h + 1] if c then c.state = 0 end end,
  sb_explore = function(addr) fake.explore, fake.ex_t, fake.ex_addr = 1, clock, ffi.string(addr); return 0 end,
  sb_explore_state = function() if fake.explore == 1 and clock - fake.ex_t > 0.6 then fake.explore = 2 end return fake.explore end,
  sb_explore_text = function(buf, max) return put(buf, max, table.concat(EXPLORE[fake.ex_addr], "\n") .. "\n") end,
}, { __index = function() return function() return 0 end end })
package.loaded["ble"] = { load = function() return lib end }
function love.errorhandler(msg) print("ERROR: " .. tostring(msg) .. "\n" .. debug.traceback()) end
require("app_main")
local app = { load = love.load, update = love.update, draw = love.draw }
local T = love._omniplay
local frame = 0
local function sim(seconds)
  for _ = 1, seconds * 20 do
    clock = clock + 0.05; frame = frame + 1
    for _, c in ipairs(fake.conns) do
      if c.state == 1 and clock - c.open_t > 0.5 then c.state = 2 end
      if c.state == 2 and c.addr == "AABBCCDDEEFF" and frame % 4 == 0 then c.q[#c.q + 1] = PEDAL end
      if c.state == 2 and c.addr == "778899AABBCC" and frame % 20 == 0 then
        fake.revs = (fake.revs or 0) + 1.3; fake.ctime = (fake.ctime or 0) + 1024
        local r, t = math.floor(fake.revs) % 65536, math.floor(fake.ctime * (math.floor(fake.revs) / fake.revs)) % 65536
        c.q[#c.q + 1] = { 2, r % 256, math.floor(r / 256), t % 256, math.floor(t / 256) }
      end
      if c.state == 2 and c.addr == "A1B2C3D4E5F6" and frame % 20 == 0 then c.q[#c.q + 1] = { 0, 152 + frame % 7 } end
    end
    local api = require("api")
    if fake.camera then api.camera = { moving = true, cadence = 76, fps = 30, activity = "cycling", phone = true, energy = 0.17,
      box = { x = 0.32, y = 0.45, w = 0.3, h = 0.35 }, t = api.now() } end
    if fake.game then
      api.games.gmod = api.games.gmod or { id = "gmod", via = "file bridge", seen = api.now() }
      local g = api.games.gmod; g.name, g.seen, g.grade, g.take_input = "Looktest", api.now(), 3.5, true
    end
    app.update(0.05)
  end
end
local shots, step = {}, 0
function love.load()
  app.load()
  sim(1)
  local by = {}
  T.set_tab("Devices"); sim(1)
  for _, n in ipairs(T.nearby()) do by[n.name] = n end
  print("nearby", #T.nearby())
  T.add_device(by["HT2405118"]); sim(3)
  T.add_device(by["ROCKBROS C3"]); sim(3)
  T.add_device(by["Polar H10"]); sim(3)
  sim(45); require("session").finish(); sim(3)
  fake.camera, fake.game = true, true
  sim(130)
  -- routes: a made-up hilly loop, plus any real GPX files handed in through OMNI_GPX (kept out of the repo)
  local route = require("route")
  local g = { '<gpx><trk><name>Test loop</name><trkseg>' }
  for i = 0, 400 do
    local a = i / 400 * 2 * math.pi
    local lat, lon = 45.78 + 0.05 * math.sin(a), 4.86 + 0.07 * math.cos(a) + 0.01 * math.sin(3 * a)
    local ele = 200 + 90 * math.max(0, math.sin(a * 2)) + 25 * math.sin(a * 7)
    g[#g + 1] = string.format('<trkpt lat="%.6f" lon="%.6f"><ele>%.1f</ele></trkpt>', lat, lon, ele)
  end
  g[#g + 1] = '</trkseg></trk></gpx>'
  assert(route.import("test-loop.gpx", table.concat(g)))
  local dir = os.getenv("OMNI_GPX")
  if dir then
    for f in io.popen('ls "' .. dir .. '"'):lines() do
      if f:match("%.gpx$") then local h = io.open(dir .. "/" .. f); route.import(f:gsub("^%x+%-", ""), h:read("*a")); h:close() end
    end
  end
  local rt = T.rt()
  local files = route.list()
  for _, f in ipairs(files) do assert(route.load(f), "route did not load: " .. f) end
  print("routes", table.concat(files, ", "))
  rt.sel = files[#files]
  for _, f in ipairs(files) do if f:match("road") then rt.sel = f end end
  shots = { "Ride", "Devices", "Games", "History", "Settings", "Routes", "RideRoute" }
end
function love.update() end
function love.draw()
  step = step + 1
  local name = shots[math.floor((step - 1) / 3) + 1]
  if not name then love.event.quit(); return end
  if name == "RideRoute" and step % 3 == 1 then
    local rt = T.rt()
    rt.ride = { r = require("route").load(rt.sel), pos = 0, climbed = 0 }
    fake.game = false; require("api").games.gmod = nil
    sim(60)
    rt.ride.pos = rt.ride.r.length * 0.38
    sim(2)
    print("route grade", rt.ride.grade, "api grade", require("api").grade)
  end
  T.set_tab(name == "RideRoute" and "Ride" or name)
  app.draw()
  if (step - 1) % 3 == 2 then love.graphics.captureScreenshot("shot_" .. name .. ".png") end
end
