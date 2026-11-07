-- OmniPlay: fitness devices as game input, with workout recording.
local ffi = require("ffi")
local bleload = require("ble")
local ui = require("ui")
local store = require("store")
local devices = require("devices")
local session = require("session")
local output = require("output")
local explore = require("explore")
local api = require("api")
local route = require("route")
local routeview = require("routeview")
local C = ui.C

local ble, load_err
local tab = "Ride"
local log = {}
local saved = { devices = {}, last = nil }
local nearby, scan_t, scanning = {}, 0, false
local scan_buf = ffi.new("char[8192]")
local ex = { running = false, lines = nil, raw = "", name = nil, t = 0 }
local exbuf = ffi.new("char[65536]")
local sel_profile, sel_hist, capture = 1, 1, nil
local hist_cache = {}
local live_m, live_dev
-- routes: the selected file, the ride in progress, and the hill strength (1, 0.5 or 0)
local rt = { sel = nil, ride = nil, strength = 1, walk = 4, msg = nil, msg_t = 0 }
local function save_rt() store.save("routes.lua", { strength = rt.strength, walk = rt.walk }) end
local build = "dev"

local log_file
local function add_log(kind, text)
  log[#log + 1] = { t = os.date("%H:%M:%S"), kind = kind, text = text }
  if log_file == nil then log_file = io.open(store.exe_dir() .. "/omniplay-log.txt", "w") or false end
  if log_file then log_file:write(os.date("%H:%M:%S"), " ", kind, " ", text, "\n"); log_file:flush() end
  if #log > 500 then table.remove(log, 1) end
end

local saved_ser
local function save_devices()
  local ser = store.serialize(saved)
  if ser ~= saved_ser then saved_ser = ser; store.save("devices.lua", saved) end
end

-- ---------- scanning ----------
local SVC_TAGS = { { 1, "FTMS" }, { 2, "footpod" }, { 4, "speed/cadence" }, { 8, "power" }, { 16, "heart rate" }, { 32, "FFF0" } }
local function refresh_nearby()
  ble.sb_scan_list(scan_buf, 8192)
  local list = {}
  for line in ffi.string(scan_buf):gmatch("[^\n]+") do
    local name, addr, rssi, age, svc = line:match("^([^\t]*)\t(%x+)\t(-?%d+)\t(%d+)\t?(%d*)")
    svc = tonumber(svc) or 0
    if name and tonumber(age) < 10000 and (name ~= "" or bit.band(svc, 31) ~= 0) then
      local tags = {}
      for _, p in ipairs(SVC_TAGS) do if bit.band(svc, p[1]) ~= 0 then tags[#tags + 1] = p[2] end end
      local fit = name:upper():find("SPERAX") ~= nil or bit.band(svc, 31) ~= 0
      list[#list + 1] = { name = name ~= "" and name or "(no name)", addr = addr, rssi = tonumber(rssi),
        tags = table.concat(tags, ", "), fitness = fit }
    end
  end
  table.sort(list, function(a, b) if a.fitness ~= b.fitness then return a.fitness end return a.rssi > b.rssi end)
  nearby = list
end

local function set_scanning(on)
  if on == scanning or not ble then return end
  scanning = on
  if on then if ble.sb_scan_start() ~= 0 then add_log("err", ffi.string(ble.sb_last_error())); scanning = false end
  else ble.sb_scan_stop() end
end

local function find_saved(addr) for i, d in ipairs(saved.devices) do if d.addr == addr then return d, i end end end

local function connect_saved(d)
  d.auto = true -- connect again next time OmniPlay starts
  save_devices()
  devices.connect(d)
end
local function disconnect_saved(d)
  d.auto = false
  save_devices()
  devices.disconnect(d)
end

local function add_device(n)
  devices.add(n, function(kind, err)
    if not kind then add_log("err", n.name .. ": " .. err); return end
    local d = find_saved(n.addr)
    if not d then
      d = { name = n.name, addr = n.addr, kind = kind, allow_hills = true, allow_speed = false, max_speed = 4,
        stop_when_steps_stop = true }
      saved.devices[#saved.devices + 1] = d
    end
    d.kind = kind
    add_log("info", "added " .. n.name .. " as " .. devices.KINDS[kind].label)
    connect_saved(d)
  end)
end

local function start_explore(n)
  set_scanning(false)
  local known = find_saved(n.addr)
  if known then devices.disconnect(known) end
  if ble.sb_explore(n.addr, 10000) ~= 0 then add_log("err", "couldn't start the explorer"); return end
  ex = { running = true, lines = nil, raw = "", name = n.name, t = 0 }
  add_log("info", "exploring " .. n.name)
end

-- hooks for the headless smoke test
love._omniplay = {
  add_device = function(n) add_device(n) end,
  nearby = function() return nearby end,
  saved = function() return saved end,
  set_tab = function(t) tab = t end,
  log = function() return log end,
  rt = function() return rt end,
}

-- ---------- LÖVE callbacks ----------
function love.load()
  local okv, v = pcall(require, "version")
  build = okv and v or "dev"
  love.window.setTitle("OmniPlay  (build " .. build .. ")")
  store.migrate()
  local rs_ = store.load("routes.lua", {})
  rt.strength, rt.walk = rs_.strength or 1, rs_.walk or 4
  ui.load()
  ble, load_err = bleload.load()
  saved = store.load("devices.lua", saved)
  saved.devices = saved.devices or {}
  output.init(add_log)
  session.init(add_log)
  add_log("info", "OmniPlay build " .. build)
  local api_opts = store.load("api.lua", {})
  -- pairing code for the phone camera page (in the QR code), kept between runs
  local phone = store.load("phone.lua", {})
  if not phone.token then
    local chars, t = "abcdefghjkmnpqrstuvwxyz23456789", {}
    math.randomseed(os.time() + math.floor(love.timer.getTime() * 1e6))
    for i = 1, 10 do local n = math.random(#chars) t[i] = chars:sub(n, n) end
    phone.token = table.concat(t)
    store.save("phone.lua", phone)
  end
  api_opts.token, api_opts.ble = phone.token, ble
  store.mkdir()
  api_opts.cert_dir = love.filesystem.getSaveDirectory() .. "/data"
  api.init(add_log, api_opts)
  if not ble then return end
  devices.init(ble, add_log)
  -- connect every device you had connected last time; they all run side by side
  local any = false
  for _, d in ipairs(saved.devices) do
    if d.auto or (d.auto == nil and saved.last == d.addr) then
      add_log("info", "connecting to " .. d.name)
      devices.connect(d)
      any = true
    end
  end
  if not any then set_scanning(true) end
end

function love.update(dt)
  if not ble then return end
  devices.update(dt)
  -- combine the camera with the device: with a bike or pad, the camera says instantly whether
  -- you're moving (and your cadence); on its own it is the device
  local d, m = devices.dev, devices.m
  local cam = api.camera_live()
  local extra_cam, dev_cad
  if cam then
    local real = devices.state == "connected" and d
    dev_cad = real and m.cadence or nil
    local mm = {}
    if real then for k, v in pairs(m) do mm[k] = v end end
    -- a cadence sensor beats the camera; the camera beats the bike's console
    if not (mm.sources and mm.sources.cadence == "sensor") then
      mm.moving = cam.moving
      if cam.moving and cam.cadence > 0 then mm.cadence = cam.cadence elseif not cam.moving then mm.cadence = 0 end
    end
    if not real then
      local c = cam.moving and cam.cadence or 0
      mm.speed_kmh = cam.activity == "cycling" and c * 0.32 or (cam.activity == "walking" and c * 0.045 or c * 0.066)
      d = { name = "Camera", kind = cam.activity == "cycling" and "ftms_bike" or "ftms_treadmill", allow_hills = false }
    end
    m, extra_cam = mm, true
  end
  -- a cadence sensor also makes start / stop instant, like the camera
  if m.sources and m.sources.moving == "sensor" then extra_cam = true end
  live_m, live_dev = m, d
  session.game = api.game_name() or (output.enabled and output.profile and output.profile.name) or nil
  session.update(dt, m, d)
  output.suppressed = api.take_input()
  output.update(dt, m, d and d.kind)
  local s = session.cur
  local rr = rt.ride
  if rr then
    if not session.user_paused then rr.pos = math.min(rr.r.length, rr.pos + (m.speed_kmh or 0) / 3.6 * dt) end
    local here = route.at(rr.r, rr.pos)
    if here.e > (rr.last_e or here.e) then rr.climbed = rr.climbed + (here.e - rr.last_e) end
    rr.last_e = here.e
    rr.grade = here.g
    api.route_grade = rt.strength > 0 and here.g * rt.strength or nil
    -- walking pad / treadmill: tilt if it can, else the belt speed follows the hill
    local pad = devices.belt()
    rr.pad = nil
    local game = api.active()
    if pad and not (game and (game.belt or game.grade)) and rt.strength > 0 then
      if devices.can_tilt(pad) then
        devices.set_incline(here.g * rt.strength)
        rr.pad = { tilt = true, name = pad.dev.name }
      elseif pad.dev.allow_speed then
        local lo, hi = devices.min_belt(pad.dev.kind), pad.dev.max_speed or 4
        local function speed_at(g) return math.max(lo, math.min(hi, rt.walk * route.walk_factor(g, rt.strength))) end
        local want = speed_at(here.g)
        -- a Sperax says when its belt runs (it starts slow, 0.3 km/h and up); FTMS treadmills only give the speed
        local moving
        if pad.m.state ~= nil then moving = pad.m.state == "running" else moving = (pad.m.speed_kmh or 0) > 0.2 end
        -- you changed the speed on the remote: that is your new normal pace. Only once the belt had
        -- actually reached our last command and then left it, so a slow start or a lagging pad isn't mistaken for you.
        local cmd = pad.belt_cmd
        local v_now = pad.m.speed_kmh or 0
        if moving and cmd and pad.cmd_reached and pad.belt_target and math.abs(cmd - pad.belt_target) < 0.15 and math.abs(v_now - cmd) > 0.25 then
          rr.manual_t = (rr.manual_t or 0) + dt
          if rr.manual_t > 2.5 then
            rt.walk = math.max(lo, math.min(hi, pad.m.speed_kmh / route.walk_factor(here.g, rt.strength)))
            rt.walk = math.floor(rt.walk * 10 + 0.5) / 10
            save_rt(); rr.manual_t = 0
            want = speed_at(here.g)
            pad.belt_cmd, pad.belt_target, pad.cmd_reached = pad.m.speed_kmh, pad.m.speed_kmh, true
            devices.trace_line(pad, string.format("remote change: new flat pace %.1f", rt.walk))
            add_log("info", string.format("new walking pace from the remote: %.1f km/h on the flat", rt.walk))
          end
        else rr.manual_t = 0 end
        if moving then devices.set_belt_speed(want, 0.2) end
        -- heads-up for what the belt will do in ~10 s
        local v = math.max(1, pad.m.speed_kmh or rt.walk)
        local later = speed_at(route.at(rr.r, rr.pos + v / 3.6 * 10).g)
        local notice
        if moving and math.abs(later - want) >= 0.3 then
          notice = string.format("%s ahead, %s to %.1f", later < want and "Climb" or "Downhill",
            later < want and "slowing" or "speeding up", later)
        end
        rr.pad = { speed = pad.belt_target or want, name = pad.dev.name, notice = notice, moving = moving }
      else
        rr.pad = { off = true, name = pad.dev.name }
      end
    end
    if rr.pos >= rr.r.length and not rr.done then
      rr.done = true
      add_log("info", "route finished: " .. rr.r.name)
    end
  else
    api.route_grade = nil
  end
  if rt.msg then rt.msg_t = rt.msg_t + dt; if rt.msg_t > 6 then rt.msg = nil end end
  api.update(dt, m, d, (cam and not (devices.state == "connected")) and "connected" or devices.state, devices,
    { gait = output.gait, recording = session.state, distance_m = s and math.floor(s.distance), elapsed_s = s and math.floor(s.elapsed),
      camera = extra_cam, device_cadence = dev_cad })
  if ex.running then
    ex.t = ex.t + dt
    local st = ble.sb_explore_state()
    if ex.t > 0.5 or st ~= 1 then
      ex.t = 0
      ble.sb_explore_text(exbuf, 65536)
      ex.raw = ffi.string(exbuf)
      ex.lines, ex.summary = explore.report(ex.raw, ex.name)
    end
    if st == 2 or st == -1 then ex.running = false; add_log("info", "explorer done: " .. explore.summary_text(ex.summary or {})) end
  end
  local want_scan = tab == "Devices" and not devices.detecting and not ex.running
    or (not devices.any_connected() and not ex.running)
  set_scanning(want_scan)
  if scanning then scan_t = scan_t + dt; if scan_t > 0.5 then scan_t = 0; refresh_nearby() end end
end

function love.filedropped(file)
  local name = file:getFilename()
  if not name:lower():match("%.gpx$") then rt.msg = "Only GPX files can be imported"; rt.msg_t = 0; return end
  file:open("r")
  local text = file:read()
  file:close()
  local f, err = route.import(name, text)
  if f then rt.sel = f; tab = "Routes"; rt.msg = "Imported " .. f; add_log("info", "route imported: " .. f)
  else rt.msg = "Could not read that file: " .. tostring(err); add_log("err", "route import failed: " .. tostring(err)) end
  rt.msg_t = 0
end

function love.mousepressed(_, _, b) ui.mousepressed(b) end
function love.mousereleased(_, _, b) ui.mousereleased(b) end
function love.wheelmoved(_, y) ui.wheelmoved(y) end

function love.keypressed(k)
  if capture then
    if k == "escape" or k == "return" then capture = nil
    elseif output.SCAN[k] then
      local keys = capture.keys
      local dup = false
      for _, x in ipairs(keys) do if x == k then dup = true end end
      if not dup and #keys < 3 then keys[#keys + 1] = k; output.save() end
      if #keys >= 3 then capture = nil end
    end
    return
  end
  if k == "f8" then output.toggle() end
end

function love.quit()
  api.shutdown()
  output.release_all()
  if session.cur then session.finish() end
  devices.disconnect()
  if ble then ble.sb_scan_stop() end
  save_devices()
end

-- ---------- screens ----------
local function fmt_time(s) s = math.floor(s or 0); return string.format("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) end
local PAD = 24
local KIND_ICON = { ftms_bike = { "B", C.green }, sperax = { "W", C.green }, ftms_treadmill = { "T", C.green },
  rsc = { "F", C.green }, csc = { "C", C.blue }, hr = { "H", C.pink } }
local KIND_NAME = { ftms_bike = "Bike", sperax = "Walking pad", ftms_treadmill = "Treadmill", rsc = "Footpod",
  csc = "Cadence sensor", hr = "Heart-rate strap" }

local function first_connected(kind)
  for _, d in ipairs(saved.devices) do
    if d.kind == kind and devices.state_of(d) == "connected" then return d end
  end
end

-- who provides each value right now (names as the user sees them)
local function sources()
  local m = live_m or devices.m
  local s = m.sources or {}
  local cam = api.camera_live()
  local mv = devices.dev and devices.dev.kind ~= "csc" and devices.state == "connected" and devices.dev or nil
  local mv_name = mv and mv.name or (cam and not mv and (cam.phone and "phone camera" or "webcam")) or nil
  local sensor, strap = first_connected("csc"), first_connected("hr")
  local cam_name = cam and (cam.phone and "phone camera" or "webcam")
  local r = { speed = mv_name, power = mv and m.power and mv.name or nil }
  if s.cadence == "sensor" and sensor then r.cadence = sensor.name
  elseif cam_name then r.cadence = cam_name else r.cadence = mv_name end
  if s.moving == "sensor" and sensor then r.moving = sensor.name elseif cam_name then r.moving = cam_name else r.moving = mv_name end
  if s.hr == "strap" and strap then r.hr = strap.name elseif (m.hr or 0) > 0 then r.hr = mv_name end
  return r
end

-- top bar: logo, tabs, a status pill on the right
local TABS = { "Ride", "Routes", "Devices", "Games", "History", "Settings" }
local function top_bar(W)
  ui.text("Omni", PAD, 22, C.text, "logo")
  ui.text("Play", PAD + ui.width("Omni", "logo"), 22, C.yellow, "logo")
  tab = ui.tabs(TABS, tab, PAD + 150, 18)
  local rec = session.state
  local label, dot
  if rec == "recording" then label, dot = "Recording " .. fmt_time(session.cur and session.cur.elapsed), C.red
  elseif rec == "paused" then label, dot = "Paused " .. fmt_time(session.cur and session.cur.elapsed), C.yellow
  else
    local n = 0
    for _, d in ipairs(saved.devices) do if devices.state_of(d) == "connected" then n = n + 1 end end
    if api.camera_live() then n = n + 1 end
    label, dot = n > 0 and (n .. (n == 1 and " source ready" or " sources ready")) or "No devices", n > 0 and C.green or C.dim
  end
  local w = ui.width(label, "b") + 48
  if W - PAD - w > PAD + 150 + 560 then
    ui.rect(W - PAD - w, 18, w, 36, C.card, 18)
    ui.dot(W - PAD - w + 20, 36, 5, dot)
    ui.text(label, W - PAD - w + 32, 18 + (36 - ui.height("b")) / 2, C.text, "b")
  end
end

-- ===== Ride: on a route =====
local function hill_bike()
  for _, dv in ipairs(saved.devices) do
    if dv.kind == "ftms_bike" and devices.state_of(dv) == "connected" then return dv end
  end
end

local function draw_ride_route(x, y, w, h)
  local rr = rt.ride
  local r = rr.r
  local s = session.cur
  local bar = 64
  local ch = h - bar - 14
  local mw = math.min(math.floor(w * 0.3), ch)
  local cw = w - mw - 14
  ui.rect(x, y, cw, ch, C.card, 24)
  ui.text(r.name, x + 22, y + 20, C.text, "h", cw * 0.5)
  local nw = math.min(ui.width(r.name, "h"), cw * 0.5)
  ui.text(string.format("km %.1f of %.1f", rr.pos / 1000, r.length / 1000), x + 34 + nw, y + 26, C.muted, "b")
  -- the hill right now, and who decides it
  local g = rr.grade or 0
  local bike = hill_bike()
  local note
  local pd = rr.pad
  if pd and not api.grade_target and rt.strength > 0 then
    if pd.tilt then note = "hill now · tilting " .. pd.name
    elseif pd.off then note = "belt speed control is off for " .. pd.name
    else note = pd.notice or string.format("belt %.1f km/h%s", pd.speed, pd.moving and "" or " · waiting for you to start") end
  elseif api.grade_target then note = "the game sets the hill"
  elseif rt.strength == 0 then note = "hills off for routes"
  elseif not bike then note = "no smart bike connected"
  elseif bike.allow_hills == false then note = "hills off for this bike"
  else note = "hill now · sent to " .. bike.name .. (rt.strength < 1 and " at half" or "") end
  local nwid = ui.width(note, "s")
  ui.text(note, x + cw - 22 - nwid, y + 30, C.soft, "s")
  local gs = string.format("%+.1f %%", g)
  ui.text(gs, x + cw - 30 - nwid - ui.width(gs, "big"), y + 16, route.color(g, C), "big")
  -- profile with the marker
  local py, ph = y + 76, ch - 76 - 108
  routeview.profile(r, x + 22, py, cw - 44, ph, rr.pos)
  -- what's next
  local bw = (cw - 44 - 28) / 3
  local by = y + ch - 96
  local label, dist = route.ahead(r, rr.pos)
  ui.rect(x + 22, by, bw, 74, C.inner, 16)
  ui.text(label, x + 38, by + 12, C.muted, "s")
  ui.text(dist < 1000 and string.format("in %d m", math.floor(dist)) or string.format("in %.1f km", dist / 1000), x + 38, by + 34, C.text, "num")
  ui.rect(x + 22 + bw + 14, by, bw, 74, C.inner, 16)
  ui.text("Climbed so far", x + 38 + bw + 14, by + 12, C.muted, "s")
  ui.text(string.format("%d of %d m", math.floor(rr.climbed), math.floor(r.climb)), x + 38 + bw + 14, by + 34, C.text, "num")
  local left = r.length - rr.pos
  local v = (live_m and live_m.speed_kmh or 0)
  ui.rect(x + 22 + 2 * (bw + 14), by, bw, 74, C.inner, 16)
  ui.text(rr.done and "Route done" or "To the finish", x + 38 + 2 * (bw + 14), by + 12, C.muted, "s")
  ui.text(rr.done and "Well ridden!" or (v > 1 and fmt_time(left / (v / 3.6)) or "-"), x + 38 + 2 * (bw + 14), by + 34, rr.done and C.green or C.text, "num")
  -- map
  ui.rect(x + cw + 14, y, mw, ch, C.card, 24)
  routeview.map(r, x + cw + 24, y + 10, mw - 20, ch - 20, rr.pos)
  -- progress and buttons
  local yb = y + ch + 14
  local btn = s and 2 or 1
  local pw = w - btn * 140 - btn * 14
  ui.rect(x, yb, pw, bar, C.card, 22)
  local a = string.format("%.1f km", rr.pos / 1000)
  local b = string.format("%.1f km to go", left / 1000)
  ui.text(a, x + 22, yb + (bar - ui.height("b")) / 2, C.soft, "b")
  local bx0 = x + 34 + ui.width(a, "b")
  local bx1 = x + pw - 34 - ui.width(b, "b")
  ui.rect(bx0, yb + bar / 2 - 9, bx1 - bx0, 18, C.inner, 9)
  ui.rect(bx0, yb + bar / 2 - 9, math.max(18, (bx1 - bx0) * rr.pos / math.max(1, r.length)), 18, C.green, 9)
  ui.text(b, bx1 + 12, yb + (bar - ui.height("b")) / 2, C.soft, "b")
  local bx = x + pw + 14
  if s then
    if ui.button(session.user_paused and "Resume" or "Pause", bx, yb, 140, bar, "dark", "h") then session.toggle_pause() end
    bx = bx + 154
    if ui.button("Finish", bx, yb, 140, bar, "green", "h") then session.finish(); hist_cache = {}; rt.ride = nil end
  else
    if ui.button("Leave route", bx, yb, 140, bar, "dark", "b") then rt.ride = nil end
  end
end

-- ===== Ride =====
local function draw_ride(x, y, w, h)
  local y0 = y
  local m = live_m or devices.m
  local d = live_dev or devices.dev
  local kind = d and d.kind
  local src = sources()
  local walking = kind == "sperax" or kind == "ftms_treadmill" or kind == "rsc"
  local cw = (w - 3 * 14) / 4
  local th = 150
  local function from(n) return n and ("from " .. n) or "no source" end
  ui.tile("Speed", string.format("%.1f", m.speed_kmh or 0), "km/h", from(src.speed), x, y, cw, th, C.green)
  ui.tile("Cadence", string.format("%.0f", m.cadence or 0), walking and "spm" or "rpm", from(src.cadence), x + cw + 14, y, cw, th, C.blue)
  if walking then ui.tile("Steps", m.steps and tostring(m.steps) or "-", nil, from(src.speed), x + 2 * (cw + 14), y, cw, th, C.yellow)
  else ui.tile("Power", m.power and tostring(m.power) or "-", "W", from(src.power), x + 2 * (cw + 14), y, cw, th, C.yellow) end
  ui.tile("Heart rate", (m.hr and m.hr > 0) and tostring(m.hr) or "-", "bpm", from(src.hr), x + 3 * (cw + 14), y, cw, th, C.pink)
  y = y + th + 14
  if rt.ride then return draw_ride_route(x, y, w, h - (y - y0)) end
  -- this ride + sources
  local hw = (w - 14) / 2
  local ch = 150
  local s = session.cur
  local rec = session.state
  local cy = ui.card(x, y, hw, ch, "This ride", rec == "recording" and "pauses by itself when you stop" or
    (rec == "paused" and "paused" or "starts by itself when you move"))
  local stats = { { "Distance", string.format("%.2f km", s and s.distance / 1000 or 0) }, { "Time", fmt_time(s and s.elapsed) },
    { "Energy", string.format("%d kcal", s and math.floor(s.kcal or 0) or 0) }, { "Hill", m.grade and string.format("%+.1f %%", m.grade) or "-" } }
  local sw = (hw - 36) / 4
  for i, st in ipairs(stats) do
    ui.text(st[1], x + 18 + (i - 1) * sw, cy, C.muted, "s")
    ui.text(st[2], x + 18 + (i - 1) * sw, cy + 18, C.text, "num")
  end
  -- speed over the ride so far
  if s and s.samples and #s.samples > 1 then
    local vals = {}
    for i = math.max(1, #s.samples - 120), #s.samples do vals[#vals + 1] = s.samples[i].v or 0 end
    ui.rect(x + 18, cy + 58, hw - 36, 30, C.inner, 10)
    ui.spark(vals, x + 26, cy + 62, hw - 52, 22, C.green)
  else
    ui.rect(x + 18, cy + 64, hw - 36, 14, C.inner, 7)
  end
  -- sources
  local sx = x + hw + 14
  local sy = ui.card(sx, y, hw, ch, "Sources") - 6
  local list = {}
  for _, dv in ipairs(saved.devices) do if devices.conn(dv) then list[#list + 1] = dv end end
  local cam = api.camera_live()
  local px, py = sx + 18, sy
  local function chip(label, sub, col)
    local cwid = ui.width(label, "b") + (sub and (ui.width(sub, "xs") + 10) or 0) + 44
    if px + cwid > sx + hw - 18 then px, py = sx + 18, py + 36 end
    if py > y + ch - 40 then return end
    ui.rect(px, py, cwid, 30, C.inner, 15)
    ui.dot(px + 16, py + 15, 5, col)
    ui.text(label, px + 28, py + (30 - ui.height("b")) / 2, col == C.dim and C.dim or C.text, "b")
    if sub then ui.text(sub, px + 34 + ui.width(label, "b"), py + (30 - ui.height("xs")) / 2 + 1, C.muted, "xs") end
    px = px + cwid + 8
  end
  for _, dv in ipairs(list) do
    local st = devices.state_of(dv)
    local role = KIND_NAME[dv.kind] and KIND_NAME[dv.kind]:lower() or ""
    chip(dv.name, st == "connected" and role or (devices.hint_of(dv) or st), st == "connected" and C.green or C.yellow)
  end
  if cam then chip(cam.phone and "Phone camera" or "Webcam", cam.moving and "sees you moving" or "sees you still", C.green) end
  if #list == 0 and not cam then
    ui.text("Nothing connected yet.", sx + 18, sy + 2, C.soft, "b")
    if ui.button("Open Devices", sx + 18, sy + 30, 150, 36, "yellow") then tab = "Devices" end
  end
  y = y + ch + 14
  -- game + recording buttons
  local bw = s and 140 or 0
  local gw = w - (s and (2 * bw + 28) or 0)
  ui.rect(x, y, gw, 96, C.card, 24)
  local g = api.active()
  ui.rect(x + 18, y + 22, 52, 52, g and g.name and C.yellow or C.btn, 16)
  ui.text("G", x + 18, y + 22 + (52 - ui.height("h")) / 2, g and g.name and C.on_yellow or C.muted, "h", 52, "center")
  if g and g.name then
    ui.text(g.name, x + 84, y + 22, C.text, "b")
    local sub = (g.via == "file bridge" and "Garry's Mod data folder" or "OmniPlay mod API")
    if api.grade_target then
      sub = sub .. string.format(" · hill %+.1f %%", api.grade_target)
      if d and d.kind == "ftms_bike" and d.allow_hills == false then sub = sub .. " (hills off for this bike)" end
    end
    if api.take_input() then sub = sub .. " · reads your ride directly, keys paused" end
    ui.text(sub, x + 84, y + 44, C.muted, "s", gw - 200)
    ui.pill("Live", x + gw - 76, y + 22, C.green, C.ok_bg)
  else
    ui.text("No game connected", x + 84, y + 22, C.soft, "b")
    ui.text(api.gmod_dir and "Garry's Mod bridge ready · start an OmniPlay gamemode" or "Games that support OmniPlay connect by themselves",
      x + 84, y + 44, C.muted, "s", gw - 110)
  end
  local p = output.profile
  local held = {}
  for _, k in ipairs(output.held_keys()) do held[#held + 1] = output.key_label(k) end
  ui.text("Keys for other games: " .. (output.enabled and "on" or "off") .. " · F8" ..
    (output.enabled and (" · " .. (p and p.name or "-") .. (#held > 0 and (" · holding " .. table.concat(held, " + ")) or "")) or ""),
    x + 84, y + 66, output.enabled and C.yellow or C.dim, "xs", gw - 110)
  if s then
    if ui.button(session.user_paused and "Resume" or "Pause", x + gw + 14, y, bw, 96, "dark", "h") then session.toggle_pause() end
    if ui.button("Finish", x + gw + bw + 28, y, bw, 96, "green", "h") then session.finish(); hist_cache = {}; rt.ride = nil end
  end
  y = y + 110
  local gh = h - (y - 76) - 4
  if gh > 90 then
    local gy = ui.card(x, y, w, gh, "Last 10 minutes")
    local lx = x + w - 18
    for _, l in ipairs({ { "Heart rate", C.pink }, { walking and "Cadence" or "Power", C.yellow }, { "Speed", C.green } }) do
      local lw = ui.width(l[1], "s")
      ui.text(l[1], lx - lw, y + 15, C.muted, "s"); ui.dot(lx - lw - 10, y + 15 + ui.height("s") / 2, 5, l[2])
      lx = lx - lw - 30
    end
    local smp = s and s.samples or {}
    if #smp > 1 then
      local from = math.max(1, #smp - 600)
      local vs, ps, hs = {}, {}, {}
      for i = from, #smp do
        local p = smp[i]
        vs[#vs + 1] = p.v or 0; ps[#ps + 1] = (walking and p.c or p.p) or 0; hs[#hs + 1] = p.hr or 0
      end
      local cx, cw2, ch2 = x + 18, w - 36, gh - 64
      ui.spark(hs, cx, gy, cw2, ch2, C.pink, 200)
      ui.spark(ps, cx, gy, cw2, ch2, C.yellow, walking and 200 or 400)
      ui.spark(vs, cx, gy, cw2, ch2, C.green, 50)
    else
      ui.text("Starts drawing when you move.", x + 18, gy + 4, C.dim, "s")
    end
  end
end

-- ===== Routes =====
local function est_time(r) return (r.length / 1000) / 26 * 3600 + r.climb * 3 end

local function draw_routes(x, y, w, h)
  local files = route.list()
  if not rt.sel or not love.filesystem.getInfo(route.DIR .. "/" .. rt.sel) then rt.sel = files[1] end
  -- left: the list
  local lw = math.max(250, math.floor(w * 0.29))
  local ly = y
  local has_pad = false
  for _, dv in ipairs(saved.devices) do if dv.kind == "sperax" or dv.kind == "ftms_treadmill" then has_pad = true end end
  local listh = h - (has_pad and 340 or 250)
  ui.begin_scroll("routes", x, y, lw, listh)
  for _, f in ipairs(files) do
    local r = route.load(f)
    local on = f == rt.sel
    ui.rect(x, ly, lw, 76, on and C.yellow or C.card, 22)
    if on then ui.rect(x + 3, ly + 3, lw - 6, 70, C.card, 19) end
    local title = r and r.name or f
    ui.text(title, x + 22, ly + 14, C.text, "b", lw - 44)
    ui.text(r and string.format("%.1f km · climb %d m", r.length / 1000, math.floor(r.climb)) or "could not read this file",
      x + 22, ly + 42, r and C.soft or C.red, "s")
    if rt.ride and rt.ride.r.file == f then ui.pill("Riding", x + lw - 90, ly + 40, C.on_green, C.green) end
    if ui.hit(x, ly, lw, 76) then rt.sel = f end
    ly = ly + 88
  end
  ui.end_scroll("routes", ly)
  -- import
  local iy = y + listh + 12
  ui.rect(x, iy, lw, 110, C.line, 22, "line")
  ui.text("+ Import GPX file", x, iy + 16, C.text, "b", lw, "center")
  ui.text(rt.msg or "Drag a .gpx file onto this window", x + 10, iy + 42, rt.msg and C.yellow or C.muted, "s", lw - 20, "center")
  if ui.button("Open routes folder", x + (lw - 170) / 2, iy + 64, 170, 34, "dark", "s") then
    love.filesystem.createDirectory(route.DIR)
    love.system.openURL("file:///" .. (love.filesystem.getSaveDirectory() .. "/" .. route.DIR):gsub("\\", "/"))
  end
  -- hill strength
  local hy = iy + 124
  ui.rect(x, hy, lw, h - (hy - y), C.card, 22)
  ui.text("Hills on routes", x + 18, hy + 14, C.muted, "b")
  local nv = ui.seg({ { 1, "Full" }, { 0.5, "Half" }, { 0, "Off" } }, rt.strength, x + 18, hy + 42, "b")
  if nv ~= rt.strength then rt.strength = nv; save_rt() end
  local ty = hy + 82
  if has_pad then
    local nw_ = ui.stepper("Walk on flat", rt.walk, 0.1, 1, 12, "%.1f km/h", x + 18, ty, lw - 36)
    if nw_ ~= rt.walk then rt.walk = nw_; save_rt() end
    ty = ty + 48
    ui.text("Slower uphill, faster gently downhill. The remote sets a new pace.",
      x + 18, ty, C.dim, "xs", lw - 36)
    ty = ty + 32
  end
  ui.text("A connected game always sets the hill itself.", x + 18, ty, C.dim, "xs", lw - 36)
  -- right: the selected route
  local rx, rw = x + lw + 16, w - lw - 16
  ui.rect(rx, y, rw, h, C.card, 26)
  local r = rt.sel and route.load(rt.sel)
  if not r then
    ui.text("Ride real roads with real hills", rx + 28, y + 28, C.text, "h")
    ui.text("Drag a GPX file from Komoot, Strava, RideWithGPS or any route planner onto this window. " ..
      "You'll see it as a line, in 3D and as an elevation profile, and the hill is sent to your smart bike while you ride it.",
      rx + 28, y + 68, C.soft, "m", rw - 56)
    ui.text("Map pictures and filling in missing elevation from the internet come in a later update.", rx + 28, y + 150, C.dim, "s", rw - 56)
    return
  end
  local ip = 20
  local sh = 84
  local ph = math.max(150, math.floor(h * 0.3))
  local mh = h - 2 * ip - sh - ph - 28
  local mw = (rw - 2 * ip - 14) / 2
  local ix, iy2 = rx + ip, y + ip
  ui.rect(ix, iy2, mw, mh, C.bg, 20)
  ui.text("Map", ix + 16, iy2 + 12, C.muted, "b")
  ui.text("from your GPX file", ix + mw - 16 - ui.width("from your GPX file", "xs"), iy2 + 15, C.dim, "xs")
  routeview.map(r, ix + 10, iy2 + 38, mw - 20, mh - 48, rt.ride and rt.ride.r.file == r.file and rt.ride.pos or nil)
  ui.rect(ix + mw + 14, iy2, mw, mh, C.bg, 20)
  ui.text("3D", ix + mw + 30, iy2 + 12, C.muted, "b")
  routeview.view3d(r, ix + mw + 24, iy2 + 38, mw - 20, mh - 48, rt.ride and rt.ride.r.file == r.file and rt.ride.pos or nil)
  -- profile
  local py = iy2 + mh + 14
  ui.rect(ix, py, rw - 2 * ip, ph, C.bg, 20)
  ui.text(r.has_ele and string.format("Elevation · %d to %d m", math.floor(r.emin), math.floor(r.emax))
    or "No elevation in this file · it rides flat for now", ix + 16, py + 12, r.has_ele and C.muted or C.yellow, "b")
  routeview.legend(ix + rw - 2 * ip - 16, py + 13)
  routeview.profile(r, ix + 14, py + 44, rw - 2 * ip - 28, ph - 56)
  -- stats + ride
  local sy = py + ph + 14
  local bw = 190
  local vw = (rw - 2 * ip - bw - 4 * 14) / 4
  local h_, m_ = math.floor(est_time(r) / 3600), math.floor(est_time(r) % 3600 / 60)
  local st = { { "Distance", string.format("%.1f km", r.length / 1000) }, { "Climb", string.format("%d m", math.floor(r.climb)) },
    { "Steepest", string.format("%.1f %%", r.steepest) }, { "Est. time", string.format("%d:%02d", h_, m_) } }
  for i, v in ipairs(st) do
    local vx = ix + (i - 1) * (vw + 14)
    ui.rect(vx, sy, vw, sh, C.bg, 20)
    ui.text(v[1], vx + 16, sy + 14, C.muted, "s")
    ui.text(v[2], vx + 16, sy + 36, C.text, "num")
  end
  local bx = ix + 4 * (vw + 14)
  if rt.ride and rt.ride.r.file == r.file then
    if ui.button("Riding · open", bx, sy, bw, sh, "green", "b") then tab = "Ride" end
  elseif ui.button("Ride this route", bx, sy, bw, sh, "green", "h") then
    rt.ride = { r = r, pos = 0, climbed = 0 }
    add_log("info", "riding route: " .. r.name)
    tab = "Ride"
  end
end

-- ===== Devices =====
local show_qr, qr_cache = false, {}
local function draw_qr(url, x, y, size)
  if qr_cache.url ~= url then
    local ok, t = require("qrencode").qrcode(url)
    qr_cache = { url = url, tab = ok and t or nil }
  end
  local t = qr_cache.tab
  if not t then return end
  local n = #t
  local mod = math.floor(size / (n + 8))
  local total = mod * (n + 8)
  ui.rect(x, y, total, total, { 1, 1, 1 }, 10)
  love.graphics.setColor(0, 0, 0)
  for cx = 1, n do
    for cy = 1, n do
      if t[cx][cy] > 0 then love.graphics.rectangle("fill", x + (cx + 3) * mod, y + (cy + 3) * mod, mod, mod) end
    end
  end
  return total
end

local cam_img, cam_img_seq, cam_drag = nil, -1, nil
local function camera_image(cam)
  if cam.preview and cam.preview_seq ~= cam_img_seq then
    cam_img_seq = cam.preview_seq
    local ok, img = pcall(function()
      local bytes = love.data.decode("string", "base64", cam.preview)
      return love.graphics.newImage(love.filesystem.newFileData(bytes, "camera.jpg"))
    end)
    if ok then cam_img = img end
  end
  return cam_img
end

-- one device card; returns its height
local function device_card(d, x, y, w)
  local st = devices.state_of(d)
  local active = st ~= "idle"
  local dm = devices.metrics_of(d) or {}
  local src = sources()
  local ic = KIND_ICON[d.kind] or { "?", C.btn }
  local h = 0
  -- measure: header 70 + values 90 + facts 34 + settings
  local settings = (d.kind == "ftms_bike") and 1 or ((d.kind == "sperax" or d.kind == "ftms_treadmill") and 2 or 0)
  h = 70 + (st == "connected" and 90 or 0) + 54 + settings * 50 + (d.kind == "sperax" and 50 or 0)
  ui.rect(x, y, w, h, C.card, 22)
  ui.rect(x + 18, y + 16, 44, 44, ic[2], 14)
  ui.text(ic[1], x + 18, y + 16 + (44 - ui.height("b")) / 2, C.tile_text, "b", 44, "center")
  ui.text(d.name, x + 74, y + 17, C.text, "b")
  ui.text((KIND_NAME[d.kind] or devices.KINDS[d.kind].label) .. (d.auto and " · auto-connect" or ""), x + 74, y + 39, C.muted, "s")
  local pl, pf, pb
  if st == "connected" then pl, pf, pb = "● Connected", C.green, C.ok_bg
  elseif active then pl, pf, pb = devices.hint_of(d) or "Connecting", C.yellow, C.warn_bg
  else pl, pf, pb = "Not connected", C.soft, C.btn end
  local pw = ui.width(pl, "s") + 22
  ui.pill(pl, x + w - 18 - pw, y + 24, pf, pb)
  local yy = y + 70
  if st == "connected" then
    local boxes = {}
    local function use(key, v)
      if src[key] == d.name then return "used for " .. (key == "moving" and "start and stop" or (key == "hr" and "heart rate" or key)), C.green end
      return "backup", C.yellow
    end
    if d.kind == "csc" then
      local n1, c1 = use("cadence")
      local n2, c2 = use("moving")
      boxes = { { "Cadence", string.format("%d", dm.cadence or 0), "rpm", n1, c1 }, { "Moving", dm.moving and "yes" or "no", "", n2, c2 } }
    elseif d.kind == "hr" then
      local n1, c1 = use("hr")
      boxes = { { "Heart rate", tostring(dm.hr or 0), "bpm", n1, c1 } }
    else
      local n1, c1 = use("speed")
      boxes = { { "Speed", string.format("%.1f", dm.speed_kmh or 0), "km/h", n1, c1 } }
      if d.kind == "ftms_bike" then
        local n2, c2 = use("power")
        boxes[#boxes + 1] = { "Power", dm.power and tostring(dm.power) or "-", "W", dm.power and n2 or "not sent", dm.power and c2 or C.dim }
      end
      local n3, c3 = use("cadence")
      boxes[#boxes + 1] = { "Cadence", string.format("%d", dm.cadence or 0), d.kind == "ftms_bike" and "rpm" or "spm", n3, c3 }
    end
    local bw2 = (w - 36 - (#boxes - 1) * 8) / #boxes
    for i, b in ipairs(boxes) do ui.valbox(b[1], b[2], b[3], b[4], b[5], x + 18 + (i - 1) * (bw2 + 8), yy, bw2, 78) end
    yy = yy + 90
  end
  -- settings
  if d.kind == "ftms_bike" then
    d.allow_hills = ui.toggle("Games may set hills", "Resistance follows the gradient in games and routes", d.allow_hills ~= false, x + 18, yy, w - 36)
    yy = yy + 50
  elseif d.kind == "sperax" or d.kind == "ftms_treadmill" then
    d.allow_speed = ui.toggle("Games and routes may change belt speed", "Off by default · never above the max below", d.allow_speed == true, x + 18, yy, w - 36)
    yy = yy + 50
    d.max_speed = ui.stepper("Max speed", d.max_speed or 4, 0.5, 1, 12, "%.1f km/h", x + 18, yy, w - 36)
    yy = yy + 50
    if d.kind == "sperax" then
      d.stop_when_steps_stop = ui.toggle("Stop in game when your steps stop", nil, d.stop_when_steps_stop ~= false, x + 18, yy, w - 36)
      yy = yy + 50
    end
  end
  -- buttons
  if active then
    if ui.button("Disconnect", x + 18, yy, 120, 36, "dark") then disconnect_saved(d) end
  else
    if ui.button("Connect", x + 18, yy, 110, 36, "green") then connect_saved(d) end
  end
  local removed = ui.button("Remove", x + 18 + 130, yy, 100, 36, "danger")
  if d.kind == "ftms_bike" then ui.chip("Updates about every 2 s", x + 260, yy + 5) end
  if d.kind == "csc" then ui.chip("Stops within about 1 s", x + 260, yy + 5) end
  return h, removed
end

local function draw_camera_card(cam, x, y, w)
  if not cam then
    local h = show_qr and 300 or 130
    local cy = ui.card(x, y, w, h, "Camera", { "Not in use", C.soft, C.btn })
    ui.text("A webcam or your phone pointed at your feet. Works alone or as a backup for a sensor.", x + 18, cy, C.soft, "s", w - 36)
    if ui.button(show_qr and "Hide phone code" or "Use phone", x + 18, cy + 34, 150, 38, show_qr and "dark" or "yellow") then show_qr = not show_qr end
    if ui.button("Use this PC's webcam", x + 178, cy + 34, 190, 38, "dark") then
      love.system.openURL("http://127.0.0.1:" .. api.port .. "/camera")
    end
    if show_qr then
      local url = api.phone_url()
      local qy = cy + 86
      if url then
        local qs = draw_qr(url, x + 18, qy, 156) or 156
        local tx, tw = x + 18 + qs + 16, w - qs - 52
        local lines = { "Phone on the same Wi-Fi as this PC, then scan.",
          "First time: the phone warns the connection isn't private (OmniPlay made its own certificate). Choose Advanced, then continue.",
          "Allow the camera. You aim it and draw the box here on the PC." }
        local ly = qy
        for _, l in ipairs(lines) do
          local _, wrapped = ui.fonts.s:getWrap(l, tw)
          ui.text(l, tx, ly, C.soft, "s", tw)
          ly = ly + #wrapped * ui.height("s") + 8
        end
        ui.text(url, tx, qy + 140, C.dim, "xs", tw)
      else
        ui.text("The phone camera isn't available: " .. (api.lan_ip and tostring(api.phone_status) or "this PC has no local network address"),
          x + 18, qy, C.yellow, "s", w - 36)
      end
    end
    return h
  end
  -- live: picture with the box, readings, controls
  local h = 420
  local used = sources().cadence == (cam.phone and "phone camera" or "webcam")
  local cy = ui.card(x, y, w, h, cam.phone and "Phone camera" or "Webcam",
    used and { "● In use", C.green, C.ok_bg } or { "Backup", C.yellow, C.warn_bg })
  local pw = w - 36
  local phh = math.floor(pw * 0.62)
  local px, py = x + 18, cy
  ui.rect(px, py, pw, phh, ui.hex("0f1022"), 14)
  local img = camera_image(cam)
  local dw, dh, ox, oy2 = pw, phh, px, py
  if img then
    local s = math.min(pw / img:getWidth(), phh / img:getHeight())
    dw, dh = img:getWidth() * s, img:getHeight() * s
    ox, oy2 = px + (pw - dw) / 2, py + (phh - dh) / 2
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, ox, oy2, 0, s, s)
  else
    ui.text("Waiting for the picture...", px, py + phh / 2 - 8, C.muted, "s", pw, "center")
  end
  local mx, my = ui.mouse()
  local over = mx >= ox and mx <= ox + dw and my >= oy2 and my <= oy2 + dh
  if love.mouse.isDown(1) then
    if not cam_drag and over then cam_drag = { (mx - ox) / dw, (my - oy2) / dh } end
  elseif cam_drag then
    local fx, fy = math.max(0, math.min(1, (mx - ox) / dw)), math.max(0, math.min(1, (my - oy2) / dh))
    local bx = { x = math.min(cam_drag[1], fx), y = math.min(cam_drag[2], fy), w = math.abs(fx - cam_drag[1]), h = math.abs(fy - cam_drag[2]) }
    if bx.w > 0.05 and bx.h > 0.05 then api.camera_cmd({ box = bx }) cam.box = bx end
    cam_drag = nil
  end
  local b = cam.box
  if cam_drag then
    local fx, fy = math.max(0, math.min(1, (mx - ox) / dw)), math.max(0, math.min(1, (my - oy2) / dh))
    b = { x = math.min(cam_drag[1], fx), y = math.min(cam_drag[2], fy), w = math.abs(fx - cam_drag[1]), h = math.abs(fy - cam_drag[2]) }
  end
  if b then
    love.graphics.setLineWidth(3)
    love.graphics.setColor(C.yellow)
    love.graphics.rectangle("line", ox + b.x * dw, oy2 + b.y * dh, b.w * dw, b.h * dh, 6, 6)
    love.graphics.setLineWidth(1)
  end
  ui.pill(string.format("● live %d fps", cam.fps or 0), px + 10, py + 10, C.on_pink, C.red)
  local ry = py + phh + 12
  local vw = (pw - 16) / 3
  ui.valbox("Cadence", tostring(cam.cadence), cam.activity == "cycling" and "rpm" or "spm", used and "used now" or "backup",
    used and C.green or C.yellow, px, ry, vw, 72)
  ui.valbox("Moving", cam.moving and "yes" or "no", "", "seen in the box", C.muted, px + vw + 8, ry, vw, 72)
  ui.rect(px + 2 * (vw + 8), ry, vw, 72, C.inner, 14)
  ui.text("Motion in the box", px + 2 * (vw + 8) + 12, ry + 9, C.muted, "xs")
  ui.rect(px + 2 * (vw + 8) + 12, ry + 40, vw - 24, 10, C.btn, 5)
  ui.rect(px + 2 * (vw + 8) + 12, ry + 40, math.min(vw - 24, (vw - 24) * (cam.energy or 0) * 4), 10, cam.moving and C.green or C.yellow, 5)
  ry = ry + 84
  local bx = px
  for _, a in ipairs({ { "cycling", "Cycling" }, { "walking", "Walking" }, { "running", "Running" } }) do
    if ui.button(a[2], bx, ry, 96, 34, cam.activity == a[1] and "yellow" or "dark", "s") then
      api.camera_cmd({ activity = a[1], mult = a[1] == "cycling" and 1 or 2 })
    end
    bx = bx + 102
  end
  if cam.phone and ui.button("Flip camera", bx + 6, ry, 120, 34, "dark", "s") then api.camera_cmd({ flip = true }) end
  ui.text("Drag on the picture to draw the box around your foot and pedal.", px, ry + 44, C.muted, "xs", pw)
  return h
end

local function draw_sources_card(x, y, w)
  local src = sources()
  local h = 44 + 5 * 36 + 10
  local cy = ui.card(x, y, w, h, "What each value comes from", "sensor, then camera, then bike")
  local rows = { { "Speed", "speed" }, { "Cadence", "cadence" }, { "Power", "power" }, { "Heart rate", "hr" }, { "Moving", "moving" } }
  for i, r in ipairs(rows) do
    local ry = cy + (i - 1) * 36
    ui.text(r[1], x + 18, ry + 6, C.text, "b")
    if src[r[2]] then ui.pill(src[r[2]], x + 140, ry + 2, C.green, C.ok_bg, "b")
    else ui.pill("nothing yet", x + 140, ry + 2, C.dim, C.inner) end
  end
  return h
end

local function draw_nearby_card(x, y, w)
  local rows = math.min(#nearby, 8)
  local h = (ex.lines and 320) or (54 + math.max(1, rows) * 46 + 8)
  local cy = ui.card(x, y, w, h, ex.lines and "Explorer report" or "Find devices nearby", ex.lines and nil or (scanning and "scanning..." or nil))
  if ex.lines then
    if ui.button("Copy", x + w - 190, y + 8, 80, 30, "dark", "s") then
      love.system.setClipboardText(table.concat(ex.lines, "\n") .. "\n\n--- raw ---\n" .. ex.raw); add_log("info", "report copied")
    end
    if ui.button("Close", x + w - 100, y + 8, 80, 30, "dark", "s") then ex.lines = nil; return h end
    if ex.summary and not ex.running then ui.text(explore.summary_text(ex.summary), x + 18, cy, C.green, "s", w - 36) end
    local maxl = 14
    local from = math.max(1, #ex.lines - maxl + 1)
    for i = from, #ex.lines do ui.text(ex.lines[i], x + 18, cy + 22 + (i - from) * 17, C.soft, "mono", w - 36) end
    return h
  end
  if #nearby == 0 then
    ui.text(scanning and "Turn the device on. Pedal to wake a bike." or "Not scanning.", x + 18, cy + 8, C.soft, "s")
  end
  for i = 1, rows do
    local n = nearby[i]
    local ry = cy + (i - 1) * 46
    ui.rect(x + 18, ry, w - 36, 40, C.inner, 14)
    ui.text(n.name, x + 32, ry + 6, n.fitness and C.text or C.dim, "b")
    ui.text(string.format("%s · %d dBm", n.tags ~= "" and n.tags or "no fitness services", n.rssi), x + 32, ry + 24, C.muted, "xs")
    local known = find_saved(n.addr)
    if known then ui.chip("added", x + w - 200, ry + 7)
    elseif n.fitness and not devices.detecting then
      if ui.button("Add", x + w - 200, ry + 5, 80, 30, "green", "s") then add_device(n) end
    end
    if ui.button("Explore", x + w - 112, ry + 5, 80, 30, "dark", "s") then start_explore(n) end
  end
  return h
end

local function draw_devices(x, y, w, h)
  ui.begin_scroll("devices", x, y, w, h)
  local cw = (w - 14) / 2
  local ly, ry = y, y
  local remove
  if #saved.devices == 0 then
    local cy = ui.card(x, ly, cw, 120, "Your devices")
    ui.text("None yet. Turn a device on and add it from the list on the right.", x + 18, cy, C.soft, "s", cw - 36)
    ly = ly + 134
  end
  for i, d in ipairs(saved.devices) do
    local dh, rm = device_card(d, x, ly, cw)
    if rm then remove = i end
    ly = ly + dh + 14
  end
  if remove then
    devices.disconnect(saved.devices[remove])
    table.remove(saved.devices, remove)
  end
  save_devices()
  local rx = x + cw + 14
  ry = ry + draw_sources_card(rx, ry, cw) + 14
  ry = ry + draw_camera_card(api.camera_live(), rx, ry, cw) + 14
  ry = ry + draw_nearby_card(rx, ry, cw) + 14
  ui.end_scroll("devices", math.max(ly, ry))
end

-- ===== Games =====
local function draw_profile_editor(p, x, y, w)
  local yy = y
  local function state_row(label, st, key_hint)
    ui.rect(x, yy, w, 104, C.inner, 16)
    ui.text(label, x + 14, yy + 12, C.text, "b")
    local kx = x + 90
    for i, k in ipairs(st.keys) do
      local lbl = output.key_label(k) .. "  x"
      local kw = ui.width(lbl, "s") + 24
      if ui.button(lbl, kx, yy + 6, kw, 30, "dark", "s") then table.remove(st.keys, i); output.save(); break end
      kx = kx + kw + 6
    end
    local cap = capture and capture.keys == st.keys
    if ui.button(cap and "press a key (Enter = done)" or "+ key", kx, yy + 6, cap and 210 or 70, 30, cap and "yellow" or "dark", "s") then
      capture = cap and nil or { keys = st.keys }
    end
    local half = (w - 30) / 2
    st.pad_kmh = ui.stepper("Pad", st.pad_kmh or 1, 0.5, 0.5, 20, "%.1f km/h", x + 10, yy + 52, half)
    if key_hint == "watts" then
      st.watts = ui.stepper("Bike", st.watts or 200, 10, 50, 1000, "%d W", x + 20 + half, yy + 52, half)
    else
      st.rpm = ui.stepper("Bike", st.rpm or 30, 5, 10, 150, "%d rpm", x + 20 + half, yy + 52, half)
    end
    yy = yy + 112
  end
  state_row("Walk", p.walk)
  state_row("Run", p.run)
  state_row("Sprint", p.sprint, "watts")
  p.hold_s = ui.stepper("Keep moving through dropouts", p.hold_s or 2, 0.5, 0, 6, "%.1f s", x, yy, w)
  yy = yy + 50
  if ui.button("Save profile", x, yy, 150, 38, "yellow") then output.save(); add_log("info", "profile saved") end
  return yy + 38 - y
end

local function draw_games(x, y, w, h)
  ui.begin_scroll("games", x, y, w, h)
  local cw = (w - 14) / 2
  local ly = y
  -- connected now
  local g = api.active()
  local cy = ui.card(x, ly, cw, 190, "Connected now", g and g.name and { "● Live", C.green, C.ok_bg } or nil)
  if g and g.name then
    ui.text(g.name, x + 18, cy, C.text, "h")
    ui.text(g.via == "file bridge" and "Through the Garry's Mod data folder" or "Through the OmniPlay mod API", x + 18, cy + 30, C.muted, "s")
    local vw = (cw - 52) / 3
    local st = api.stats or {}
    ui.valbox("Hill sent", api.grade_target and string.format("%+.1f", api.grade_target) or "-", "%", api.grade_target and "to your bike" or "none", C.green, x + 18, cy + 56, vw, 72)
    ui.valbox("Your keys", api.take_input() and "paused" or "on", "", api.take_input() and "game reads you directly" or "", C.muted, x + 26 + vw, cy + 56, vw, 72)
    ui.valbox("Game", g.via == "file bridge" and "GMod" or "API", "", g.via or "", C.muted, x + 34 + 2 * vw, cy + 56, vw, 72)
  else
    ui.text("No game connected", x + 18, cy, C.soft, "h")
    ui.text("Games and gamemodes that support OmniPlay connect by themselves while OmniPlay runs.", x + 18, cy + 34, C.muted, "s", cw - 36)
  end
  ly = ly + 204
  -- garry's mod
  local gmh = api.gmod_dir and 170 or 100
  cy = ui.card(x, ly, cw, gmh, "Garry's Mod support", api.gmod_dir and { "Found", C.green, C.ok_bg } or { "Not found", C.soft, C.btn })
  if api.gmod_dir then
    ui.text(api.gmod_dir, x + 18, cy, C.soft, "s", cw - 36)
    ui.text("Gamemodes read your ride through the data folder. The faster OmniPlay module for GMod comes in a later update.",
      x + 18, cy + 24, C.muted, "xs", cw - 36)
    if ui.button("Open folder", x + 18, cy + 72, 130, 36, "dark", "s") then love.system.openURL("file:///" .. api.gmod_dir:gsub("\\", "/")) end
  else
    ui.text("Garry's Mod wasn't found in your Steam libraries.", x + 18, cy, C.soft, "s", cw - 36)
  end
  ly = ly + gmh + 14
  -- developers
  cy = ui.card(x, ly, cw, 160, "Make your game work with OmniPlay")
  ui.text("Free for any game, open-source or commercial. Don't sell OmniPlay support as a separate purchase.", x + 18, cy, C.soft, "s", cw - 36)
  if ui.button("Open developer docs", x + 18, cy + 58, 190, 38, "yellow", "s") then
    love.system.openURL("https://github.com/MightyX3N/omniplay/blob/main/docs/API.md")
  end
  ly = ly + 174
  -- other games: key / controller profiles
  local rx = x + cw + 14
  local profs = output.profiles
  sel_profile = math.min(sel_profile, #profs)
  local p = profs[sel_profile]
  local list_h = #profs * 52 + 50
  local ed_h = 3 * 112 + 100
  local ch = 44 + 50 + list_h + ed_h + 20
  cy = ui.card(rx, y, cw, ch, "Other games", { output.enabled and "Keys on · F8" or "Keys off · F8", output.enabled and C.green or C.soft, output.enabled and C.ok_bg or C.btn })
  ui.text("Without OmniPlay support, your ride presses keys. The profile switches by itself when that game is in front.", rx + 18, cy, C.soft, "xs", cw - 140)
  if ui.button(output.enabled and "Turn off" or "Turn on", rx + cw - 118, cy - 2, 100, 34, output.enabled and "dark" or "yellow", "s") then output.toggle() end
  local py = cy + 46
  for i, pr in ipairs(profs) do
    local on = i == sel_profile
    ui.rect(rx + 18, py, cw - 36, 44, C.inner, 14)
    if on then ui.rect(rx + 18, py, cw - 36, 44, C.yellow, 14, "line") end
    ui.text(pr.name, rx + 32, py + 6, C.text, "b")
    ui.text(pr.exe ~= "" and ("when " .. pr.exe .. " is in front") or "any game (default)", rx + 32, py + 24, C.muted, "xs")
    if ui.hit(rx + 18, py, cw - 36, 44) then sel_profile = i end
    py = py + 52
  end
  if ui.button("+ New profile", rx + 18, py, 150, 34, "dark", "s") then
    local np = output.default_profile()
    np.name, np.exe = "New profile", output.foreground ~= "omniplay" and output.foreground or ""
    profs[#profs + 1] = np; sel_profile = #profs; output.save()
  end
  if sel_profile > 1 then
    local fg = output.foreground
    if fg ~= "" and fg ~= "omniplay" and ui.button("Use for " .. fg, rx + 178, py, 200, 34, "dark", "s") then
      p.exe, p.name = fg, fg:gsub("%.exe$", ""); output.save()
    end
    if ui.button("Delete", rx + cw - 108, py, 90, 34, "danger", "s") then table.remove(profs, sel_profile); sel_profile = 1; output.save() end
  end
  p = profs[sel_profile]
  if p then draw_profile_editor(p, rx + 18, py + 50, cw - 36) end
  ui.end_scroll("games", math.max(ly, y + ch))
end

-- ===== History =====
local function draw_history(x, y, w, h)
  local list = session.history
  if #list == 0 then
    local cy = ui.card(x, y, w, 120, "History")
    ui.text("No rides yet. Recording starts by itself when you move.", x + 18, cy, C.soft, "b")
    return
  end
  sel_hist = math.min(sel_hist, #list)
  local lw = 340
  ui.begin_scroll("hist", x, y, lw, h)
  local yy = y
  for i, s in ipairs(list) do
    local on = i == sel_hist
    ui.rect(x, yy, lw, 62, C.card, 18)
    if on then ui.rect(x + 1, yy + 1, lw - 2, 60, C.yellow, 18, "line") end
    if ui.hit(x, yy, lw, 62) then sel_hist = i end
    local what = (s.sport == "cycling" and "Ride" or (s.sport == "running" and "Run" or "Walk"))
    ui.text(what .. " · " .. (s.game or s.device or ""), x + 16, yy + 10, C.text, "b", lw - 32)
    ui.text(os.date("%a %d %b %H:%M", s.start) .. string.format(" · %.1f km · %d min", s.distance / 1000, s.elapsed / 60),
      x + 16, yy + 34, C.muted, "s")
    yy = yy + 70
  end
  ui.end_scroll("hist", yy)
  local s = list[sel_hist]
  local dx, dw = x + lw + 14, w - lw - 14
  local cy = ui.card(dx, y, dw, h, (s.sport == "cycling" and "Ride" or (s.sport == "running" and "Run" or "Walk")) .. " · " .. (s.device or ""),
    os.date("%A %d %B %Y, %H:%M", s.start))
  local rows = { { "Time", fmt_time(s.elapsed), "" }, { "Distance", string.format("%.2f", s.distance / 1000), "km" },
    { "Avg speed", string.format("%.1f", s.avg_kmh or 0), "km/h" }, { "Energy", tostring(s.kcal or 0), "kcal" },
    { "Avg power", s.avg_power and tostring(s.avg_power) or "-", "W" }, { "Avg heart rate", s.avg_hr and tostring(s.avg_hr) or "-", "bpm" },
    { "Climbed", tostring(s.climb or 0), "m" }, { "Game", s.game or "-", "" } }
  local vw = (dw - 36 - 3 * 8) / 4
  for i, r in ipairs(rows) do
    local cx = dx + 18 + ((i - 1) % 4) * (vw + 8)
    local ry = cy + math.floor((i - 1) / 4) * 72
    ui.valbox(r[1], r[2], r[3], nil, nil, cx, ry, vw, 64)
  end
  local full = hist_cache[s.id]
  if full == nil then full = session.load_session(s.id) or false; hist_cache[s.id] = full end
  local gy = cy + 152
  ui.rect(dx + 18, gy, dw - 36, 160, C.inner, 16)
  if full and full.samples and #full.samples > 1 then
    local key = (s.avg_power and "p") or "v"
    local vals = {}
    local stride = math.max(1, math.floor(#full.samples / (dw - 60)))
    for i = 1, #full.samples, stride do vals[#vals + 1] = full.samples[i][key] or 0 end
    ui.text(key == "p" and "Power" or "Speed", dx + 32, gy + 10, C.muted, "s")
    ui.spark(vals, dx + 32, gy + 34, dw - 64, 112, key == "p" and C.yellow or C.green)
  end
  local by = gy + 176
  local dir = store.exe_dir("activities")
  if ui.button("Open activities folder", dx + 18, by, 210, 38, "yellow", "s") then love.system.openURL("file:///" .. dir:gsub("\\", "/")) end
  if full and ui.button("Export again (FIT + TCX)", dx + 238, by, 210, 38, "dark", "s") then
    local f = session.export_files(full, s.id)
    add_log("info", f and ("exported " .. f) or "export failed")
  end
  ui.text("Upload the .fit file to Strava, Garmin Connect, TrainingPeaks or intervals.icu. It's saved as an indoor activity.",
    dx + 18, by + 50, C.muted, "xs", dw - 36)
end

-- ===== Settings =====
local function draw_settings(x, y, w, h)
  local cw = (w - 14) / 2
  local cy = ui.card(x, y, cw, 220, "About")
  ui.text("OmniPlay", x + 18, cy, C.text, "h")
  ui.text("Build " .. build, x + 18, cy + 30, C.muted, "s")
  ui.text("Open source (GPL-3.0). Fonts: Inter (SIL Open Font License).", x + 18, cy + 52, C.muted, "xs", cw - 36)
  if ui.button("Open data folder", x + 18, cy + 86, 170, 38, "dark", "s") then
    love.system.openURL("file:///" .. (love.filesystem.getSaveDirectory() .. "/data"):gsub("\\", "/"))
  end
  if ui.button("Copy log", x + 198, cy + 86, 110, 38, "dark", "s") then
    local t = { "OmniPlay build " .. build }
    for _, e in ipairs(log) do t[#t + 1] = e.t .. " " .. e.kind .. " " .. e.text end
    love.system.setClipboardText(table.concat(t, "\n")); add_log("info", "log copied to clipboard")
  end
  local rx = x + cw + 14
  cy = ui.card(rx, y, cw, 220, "Ride with friends online", { "Coming soon", C.on_yellow, C.yellow })
  ui.text("Friends, group rides and invites through playit.gg. No port forwarding, and your home IP stays hidden.",
    rx + 18, cy, C.soft, "s", cw - 36)
  ui.text("Not set up yet.", rx + 18, cy + 60, C.dim, "b")
end

function love.draw()
  ui.begin_frame()
  local W, H = love.graphics.getDimensions()
  love.graphics.clear(C.bg)
  top_bar(W)
  if not ble then
    local cy = ui.card(PAD, 88, W - 2 * PAD, 140, "Bluetooth helper not loaded", { "Error", C.red, C.bad_bg })
    ui.text(load_err or "omniplay_ble.dll is missing", PAD + 18, cy, C.soft, "s", W - 2 * PAD - 36)
    ui.end_frame()
    return
  end
  local x, y, w, h = PAD, 76, W - 2 * PAD, H - 76 - 34
  if tab == "Ride" then draw_ride(x, y, w, h)
  elseif tab == "Routes" then draw_routes(x, y, w, h)
  elseif tab == "Devices" then draw_devices(x, y, w, h)
  elseif tab == "Games" then draw_games(x, y, w, h)
  elseif tab == "History" then draw_history(x, y, w, h)
  else draw_settings(x, y, w, h) end
  -- status line: last log message
  local last = log[#log]
  if last then
    local t = last.t .. "  " .. last.text
    while #t > 10 and ui.width(t, "xs") > W - 2 * PAD do t = t:sub(1, -8) .. "..." end
    ui.text(t, PAD, H - 24, last.kind == "err" and C.yellow or C.dim, "xs")
  end
  ui.end_frame()
end
