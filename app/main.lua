-- OmniPlay probe: connects to a Sperax walking pad, polls status, shows raw and decoded frames.
-- Read-only: the only thing it ever sends is the status request (0x19).
-- This is the first building block of OmniPlay; the full app grows out of it.
local ffi = require("ffi")
local bit = require("bit")
local sperax = require("drivers.sperax")
local explore = require("explore")
local biketest = require("biketest")

ffi.cdef [[
  const char *sb_last_error(void);
  const char *sb_status_text(void);
  int  sb_state(void);
  int  sb_scan_start(void);
  void sb_scan_stop(void);
  int  sb_scan_list(char *out, int outlen);
  int  sb_open(const char *addr_hex, const char *service, const char *notify_uuid, const char *write_uuid);
  int  sb_write(const unsigned char *data, int len);
  int  sb_read(unsigned char *buf, int maxlen);
  int  sb_dropped(void);
  void sb_close(void);
  int  sb_read_ex(unsigned char *buf, int maxlen, int *which);
  int  sb_explore(const char *addr_hex, int listen_ms);
  int  sb_explore_state(void);
  int  sb_explore_text(char *out, int outlen);
]]

local SERVICE, NOTIFY, WRITE = "fff0", "fff1", "fff2"
local POLL_EVERY = 0.25

local ble, load_err
local devices, connected, conn_name = {}, false, nil
local reader = sperax.new_reader()
local log, status, last_frame = {}, nil, nil
local poll_t, write_fails, polls, frames_ok, frames_bad = 0, 0, 0, 0, 0
local step_hist = {}
local paused = false
local fonts = {}

local function now() return love.timer.getTime() end

local function add_log(kind, text)
  log[#log + 1] = { t = now(), kind = kind, text = text }
  if #log > 300 then table.remove(log, 1) end
end

local function load_dll()
  local tried = {}
  for _, dir in ipairs({ love.filesystem.getSource(), love.filesystem.getSourceBaseDirectory() }) do
    local p = dir .. "/omniplay_ble.dll"
    tried[#tried + 1] = p
    local ok, lib = pcall(ffi.load, p)
    if ok then return lib end
  end
  local ok, lib = pcall(ffi.load, "omniplay_ble")
  if ok then return lib end
  return nil, "Couldn't load omniplay_ble.dll. Tried:\n" .. table.concat(tried, "\n")
end

local connecting = false
local scan_buf = ffi.new("char[8192]")
local scan_t = 0

local function start_scan()
  if ble.sb_scan_start() ~= 0 then add_log("err", ffi.string(ble.sb_last_error()))
  else add_log("info", "scanning for Bluetooth devices...") end
end

-- Advertised service flags from the helper (see SV_* in omniplay_ble.c)
local SVC_TAGS = { { 1, "FTMS" }, { 2, "footpod" }, { 4, "speed/cadence" }, { 8, "power" }, { 16, "heart rate" }, { 32, "FFF0" } }

local function svc_tags(flags)
  local t = {}
  for _, p in ipairs(SVC_TAGS) do if bit.band(flags, p[1]) ~= 0 then t[#t + 1] = p[2] end end
  return table.concat(t, ", ")
end

-- Refresh the list of nearby devices: fitness gear first (Sperax pads and anything
-- advertising a fitness service), then by signal. Unnamed devices only if they
-- advertise a fitness service.
local function refresh_devices()
  ble.sb_scan_list(scan_buf, 8192)
  local list = {}
  for line in ffi.string(scan_buf):gmatch("[^\n]+") do
    local name, addr, rssi, age, svc = line:match("^([^\t]*)\t(%x+)\t(-?%d+)\t(%d+)\t?(%d*)")
    svc = tonumber(svc) or 0
    if name and tonumber(age) < 10000 and (name ~= "" or bit.band(svc, 31) ~= 0) then
      local sperax = name:upper():find("SPERAX") ~= nil
      list[#list + 1] = { name = name ~= "" and name or "(no name)", addr = addr, rssi = tonumber(rssi),
        sperax = sperax, fitness = sperax or bit.band(svc, 31) ~= 0, tags = svc_tags(svc) }
    end
  end
  table.sort(list, function(a, b)
    if a.fitness ~= b.fitness then return a.fitness end
    return a.rssi > b.rssi
  end)
  devices = {}
  for i = 1, math.min(9, #list) do devices[i] = list[i] end
end

local function connect(i)
  local d = devices[i]
  ble.sb_scan_stop()
  add_log("info", "connecting to " .. d.name .. " (" .. d.addr .. ")")
  if ble.sb_open(d.addr, SERVICE, NOTIFY, WRITE) ~= 0 then
    add_log("err", "connect failed: " .. ffi.string(ble.sb_last_error()))
    start_scan()
    return
  end
  connecting, conn_name = true, d.name
end

local function on_connected()
  connecting, connected = false, true
  reader, status, last_frame, write_fails = sperax.new_reader(), nil, nil, 0
  step_hist = {}
  add_log("info", "connected, subscribed to FFF1, polling every " .. POLL_EVERY .. " s")
end

local function disconnect(why)
  if ble then ble.sb_close() end
  if connected or connecting then add_log("info", "disconnected" .. (why and (": " .. why) or "")) end
  connected, connecting = false, false
  if ble then start_scan() end
end

local poll_buf = ffi.new("unsigned char[?]", #sperax.STATUS, sperax.STATUS)

local function poll()
  polls = polls + 1
  if ble.sb_write(poll_buf, #sperax.STATUS) ~= 0 then
    write_fails = write_fails + 1
    add_log("err", "write failed: " .. ffi.string(ble.sb_last_error()))
    if write_fails >= 3 then disconnect("3 failed writes in a row (pad off or out of range?)") end
  else
    write_fails = 0
    if polls <= 2 then add_log("tx", sperax.hex(sperax.STATUS)) end
  end
end

local rx = ffi.new("unsigned char[512]")

local function pump()
  while true do
    local n = ble.sb_read(rx, 512)
    if n <= 0 then break end
    local chunk = {}
    for i = 0, n - 1 do chunk[#chunk + 1] = rx[i] end
    add_log("rx", sperax.hex(chunk))
    for _, f in ipairs(sperax.feed(reader, chunk)) do
      if f.crc_ok and f.len_ok then frames_ok = frames_ok + 1 else frames_bad = frames_bad + 1 end
      local tag = string.format("frame cmd %02X  len %s  crc %s", f.cmd or 0,
        f.len_ok and "ok" or "BAD", f.crc_ok == nil and "?" or (f.crc_ok and "ok" or "BAD"))
      if f.junk > 0 then tag = tag .. "  (dropped " .. f.junk .. " junk byte" .. (f.junk > 1 and "s" or "") .. ")" end
      add_log("frame", tag .. "  |  " .. sperax.hex(f.b))
      if f.cmd == 0x19 then
        last_frame = f
        local s = sperax.decode_status(f)
        if s then
          status = s
          step_hist[#step_hist + 1] = { t = now(), steps = s.steps }
          while #step_hist > 0 and now() - step_hist[1].t > 3 do table.remove(step_hist, 1) end
        end
      end
    end
  end
end

local function moving()
  if #step_hist < 2 then return false end
  return step_hist[#step_hist].steps > step_hist[1].steps
end

-- ---------- device explorer ----------
local list_mode, exploring = "connect", false -- connect | explore | bike
local ex_name, ex_raw, ex_lines, ex_summary, ex_t = nil, "", nil, nil, 0
local ex_buf = ffi.new("char[65536]")

local function refresh_explore()
  ble.sb_explore_text(ex_buf, 65536)
  ex_raw = ffi.string(ex_buf)
  ex_lines, ex_summary = explore.report(ex_raw, ex_name)
end

local function start_explore(i)
  local d = devices[i]
  ble.sb_scan_stop()
  if ble.sb_explore(d.addr, 10000) ~= 0 then add_log("err", "couldn't start the explorer"); start_scan(); return end
  exploring, ex_name, ex_lines, ex_summary = true, d.name, nil, nil
  add_log("info", "exploring " .. d.name .. " (" .. d.addr .. ")")
end

local function copy_log()
  if ex_lines and not connected and not biketest.active then
    local text = table.concat(ex_lines, "\n") .. "\n\nSummary: " .. explore.summary_text(ex_summary or {}) ..
      "\n\n--- raw ---\n" .. ex_raw
    love.system.setClipboardText(text)
    love.filesystem.write("explore-report.txt", text)
    add_log("info", "report copied to clipboard, also saved to " .. love.filesystem.getSaveDirectory() .. "/explore-report.txt")
    return
  end

  local out = { "OmniPlay probe log", "device: " .. tostring(conn_name), "polls: " .. polls ..
    "  frames ok: " .. frames_ok .. "  bad: " .. frames_bad .. "  dropped: " .. (ble and ble.sb_dropped() or 0), "" }
  if biketest.active then for _, l in ipairs(biketest.summary()) do out[#out + 1] = l end; out[#out + 1] = "" end
  local from = math.max(1, #log - 80)
  for i = from, #log do
    local e = log[i]
    out[#out + 1] = string.format("%8.2f %-5s %s", e.t, e.kind, e.text)
  end
  local text = table.concat(out, "\n")
  love.system.setClipboardText(text)
  love.filesystem.write("probe-log.txt", text)
  add_log("info", "copied to clipboard, also saved to " .. love.filesystem.getSaveDirectory() .. "/probe-log.txt")
end

function love.load()
  fonts.ui = love.graphics.newFont(14)
  fonts.big = love.graphics.newFont(28)
  fonts.mono = love.graphics.newFont(13)
  ble, load_err = load_dll()
  if ble then start_scan() end
end

function love.update(dt)
  if not ble then return end
  if biketest.active then
    biketest.update()
    if not biketest.active then start_scan() end
    return
  end
  if connecting then
    local st = ble.sb_state()
    if st == 2 then on_connected()
    elseif st == -1 then
      add_log("err", "connect failed: " .. ffi.string(ble.sb_last_error()))
      disconnect()
    end
  elseif exploring then
    ex_t = ex_t + dt
    local st = ble.sb_explore_state()
    if ex_t > 0.5 or st ~= 1 then ex_t = 0; refresh_explore() end
    if st == 2 or st == -1 then
      exploring = false
      add_log(st == 2 and "info" or "err", st == 2 and ("explorer done: " .. explore.summary_text(ex_summary)) or "explorer failed, see report")
      start_scan()
    end
  elseif not connected then
    scan_t = scan_t + dt
    if scan_t > 0.5 then scan_t = 0; refresh_devices() end
  end
  if connected then
    pump()
    poll_t = poll_t + dt
    if poll_t >= POLL_EVERY and not paused then poll_t = 0; poll() end
  end
end

function love.keypressed(k)
  if k == "escape" then love.event.quit() end
  if not ble then return end
  if biketest.active then
    if biketest.keypressed(k) then return end
    if k == "d" then biketest.stop(); add_log("info", "bike test ended"); start_scan()
    elseif k == "c" then copy_log() end
    return
  end
  if k == "d" then disconnect()
  elseif k == "p" then paused = not paused; add_log("info", paused and "polling paused" or "polling resumed")
  elseif k == "c" then copy_log()
  elseif (k == "e" or k == "b") and not connected and not connecting and not exploring then
    local want = k == "e" and "explore" or "bike"
    list_mode = list_mode == want and "connect" or want
    add_log("info", list_mode == "explore" and "explore mode: press a number to list everything that device exposes"
      or list_mode == "bike" and "bike test mode: press a number to take control of that FTMS bike" or "connect mode")
  elseif tonumber(k) and devices[tonumber(k)] and not connected and not connecting and not exploring then
    local d = devices[tonumber(k)]
    if list_mode == "explore" then start_explore(tonumber(k))
    elseif list_mode == "bike" then ex_lines = nil; biketest.start(ble, add_log, d)
    else connect(tonumber(k)) end
  end
end

function love.quit() if ble then ble.sb_close(); ble.sb_scan_stop() end end

-- ---------- drawing ----------
local C = {
  text = { 0.92, 0.92, 0.9 }, dim = { 0.6, 0.6, 0.58 }, ok = { 0.45, 0.8, 0.5 },
  bad = { 0.95, 0.45, 0.4 }, acc = { 0.5, 0.7, 1.0 }, panel = { 0.16, 0.16, 0.17 }, bg = { 0.1, 0.1, 0.11 },
}
local KIND = { rx = C.dim, frame = C.text, tx = C.acc, err = C.bad, info = C.ok }
-- 0-based offsets worth highlighting in the hex grid
local MARK = { [6] = "state", [15] = "steps", [16] = "steps", [17] = "speed", [9] = "time", [10] = "time" }

local function panel(x, y, w, h)
  love.graphics.setColor(C.panel)
  love.graphics.rectangle("fill", x, y, w, h, 8, 8)
end

local function txt(s, x, y, col, font)
  love.graphics.setFont(font or fonts.ui)
  love.graphics.setColor(col or C.text)
  love.graphics.print(s, x, y)
end

local function metric(label, value, x, y)
  txt(label, x, y, C.dim)
  txt(value, x, y + 18, C.text, fonts.big)
end

function love.draw()
  local W, H = love.graphics.getDimensions()
  love.graphics.clear(C.bg)

  if not ble then
    txt(load_err or "DLL not loaded", 20, 20, C.bad)
    return
  end

  -- header
  panel(12, 12, W - 24, 56)
  local dot = connected and C.ok or (connecting and C.acc or C.bad)
  love.graphics.setColor(dot); love.graphics.circle("fill", 32, 40, 6)
  local head = connected and ("Connected: " .. tostring(conn_name))
    or connecting and ("Connecting to " .. tostring(conn_name) .. ": " .. ffi.string(ble.sb_status_text()))
    or exploring and ("Exploring " .. tostring(ex_name) .. "...")
    or biketest.active and "Bike test"
    or (list_mode == "explore" and "Explore mode" or list_mode == "bike" and "Bike test mode" or "Not connected")
  txt(head, 48, 22)
  txt(string.format("polls %d   frames ok %d   bad %d   dropped %d%s", polls, frames_ok, frames_bad,
    ble.sb_dropped(), paused and "   (paused)" or ""), 48, 42, C.dim)

  -- device list / decoded values
  local y = 80
  if biketest.active then
    y = biketest.draw(y, W, txt, panel, metric, C, fonts)
  elseif not connected then
    panel(12, y, W - 24, 40 + math.max(1, #devices) * 22)
    txt(connecting and "Connecting... (this can take up to 30 seconds)"
      or exploring and "Exploring: reading services, then 10 s of live data. Use the machine now."
      or list_mode == "explore" and "Explore mode: press a number to list everything that device exposes (E to go back)"
      or list_mode == "bike" and "Bike test mode: press the number of your FTMS bike (B to go back)"
      or "Nearby devices: number = connect Sperax pad, E = explore mode, B = bike test mode. No pairing needed.", 28, y + 10, C.dim)
    if #devices == 0 and not connecting then
      txt("Nothing yet. Turn the device on (pedal a few strokes to wake a bike) and turn your phone's Bluetooth off.", 28, y + 34, C.dim)
    end
    for i, d in ipairs(devices) do
      txt(string.format("%d.  %-24s %s   %4d dBm   %s", i, d.name, d.addr, d.rssi, d.tags), 28, y + 12 + i * 22,
        d.fitness and C.acc or C.text, fonts.mono)
    end
    y = y + 52 + math.max(1, #devices) * 22
  else
    panel(12, y, W - 24, 96)
    if status then
      metric("State", status.state, 28, y + 12)
      metric("Speed", string.format("%.1f km/h", status.speed_kmh), 220, y + 12)
      metric("Steps", tostring(status.steps), 400, y + 12)
      metric("Moving", moving() and "yes" or "no", 560, y + 12)
      txt(string.format("time %ds  dist %dm  kcal %d  vib %d", status.seconds, status.distance_m,
        status.kcal, status.vibration or 0), 700, y + 30, C.dim)
    else
      txt("Waiting for a status frame (0x19)...", 28, y + 34, C.dim)
    end
    y = y + 108

    -- hex grid of last status frame
    if last_frame then
      local b = last_frame.b
      local rows = math.ceil(#b / 16)
      panel(12, y, W - 24, 34 + rows * 40)
      txt("Last status frame (unescaped). Highlighted: state 6, time 9-10, steps 15-16, speed 17", 28, y + 8, C.dim)
      for i = 0, #b - 1 do
        local cx = 28 + (i % 16) * 52
        local cy = y + 30 + math.floor(i / 16) * 40
        txt(tostring(i), cx, cy, C.dim, fonts.mono)
        txt(string.format("%02X", b[i + 1]), cx, cy + 16, MARK[i] and C.acc or C.text, fonts.mono)
      end
      y = y + 46 + rows * 40
    end
  end

  -- explorer report (when there is one and no pad is connected)
  if ex_lines and not connected and not biketest.active then
    panel(12, y, W - 24, H - y - 44)
    local lh = 17
    local maxl = math.floor((H - y - 80) / lh)
    if ex_summary and not exploring then txt(explore.summary_text(ex_summary), 24, y + 8, C.acc) end
    local from = math.max(1, #ex_lines - maxl + 1)
    for i = from, #ex_lines do
      local l = ex_lines[i]
      txt(l, 24, y + 30 + (i - from) * lh, l:match("^ERROR") and C.bad or (l:match("^%[") and C.acc or C.text), fonts.mono)
    end
    txt("1-9 connect/explore   E explore   B bike test   C copy report   Esc quit", 16, H - 28, C.dim)
    return
  end

  -- log
  panel(12, y, W - 24, H - y - 44)
  local lh = 17
  local maxl = math.floor((H - y - 60) / lh)
  local from = math.max(1, #log - maxl + 1)
  for i = from, #log do
    local e = log[i]
    local line = string.format("%-5s %s", e.kind, e.text)
    txt(line, 24, y + 8 + (i - from) * lh, KIND[e.kind] or C.text, fonts.mono)
  end

  txt(biketest.active and "Up/Down hill   Left/Right resistance   M encoding   S start   X stop   D disconnect   C copy log   Esc quit"
    or "1-9 connect   E explore   B bike test   D disconnect   P pause polling   C copy log   Esc quit", 16, H - 28, C.dim)
end
