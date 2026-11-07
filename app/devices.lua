-- Device manager: several devices connected at once (a bike, a cadence sensor, a heart-rate
-- strap...). Each one connects, decodes and reconnects on its own; their numbers are combined
-- into one set (M.m) for the rider, taking each value from the best source:
--   moving / cadence: cadence sensor > the movement device (the camera is merged in main)
--   speed, distance, power, steps: the movement device (bike, treadmill, pad, footpod)
--   heart rate: heart-rate strap > the movement device
-- Hill and belt-speed requests go to the machine that can take them, within the user's limits.
local ffi = require("ffi")
local sperax = require("drivers.sperax")
local ftms = require("drivers.ftms")
local rsc = require("drivers.rsc")
local csc = require("drivers.csc")

local M = {
  conns = {},              -- addr -> connection
  order = {},              -- addrs in connect order
  state = "idle",          -- state of the movement device: idle | connecting | connected | reconnecting
  dev = nil,               -- the movement device (saved device table)
  hint = nil,
  m = {},                  -- combined metrics
  detecting = nil,
  log = function() end,
}

local KINDS = {
  sperax = { svc = "fff0", notify = "fff1", write = "fff2", label = "Sperax pad", move = true },
  ftms_bike = { svc = "1826", notify = "2ad2,2ad9,2ada", write = "2ad9", label = "FTMS bike", move = true },
  ftms_treadmill = { svc = "1826", notify = "2acd,2ad9,2ada", write = "2ad9", label = "FTMS treadmill", move = true },
  rsc = { svc = "1814", notify = "2a53", write = "", label = "Footpod", move = true },
  csc = { svc = "1816", notify = "2a5b", write = "", label = "Cadence sensor" },
  hr = { svc = "180d", notify = "2a37", write = "", label = "Heart rate" },
}
M.KINDS = KINDS

local POLL_S, WATCHDOG_S, RETRY_S = 0.25, 6, 3
local BELT_RAMP = 0.5 -- km/h per second, whatever the machine itself allows

local ble
local rx = ffi.new("unsigned char[512]")
local which = ffi.new("int[1]")
local exbuf = ffi.new("char[65536]")
local now = function() return love.timer.getTime() end

local function fresh_metrics(kind)
  return { speed_kmh = 0, cadence = 0, power = nil, hr = nil, steps = nil, distance_m = nil, moving = false, kind = kind }
end

local function write(c, bytes)
  if not c.h then return false end
  local buf = ffi.new("unsigned char[?]", #bytes, bytes)
  return ble.sb_write_h(c.h, buf, #bytes) == 0
end

function M.init(lib, log_fn)
  ble, M.log = lib, log_fn or M.log
  M.m = fresh_metrics(nil)
end

-- ---------- detection ----------
-- Decide the protocol from the explorer's raw output.
function M.detect(raw, name)
  local has = {}
  for uuid in raw:gmatch("[%s\n](%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x+)") do
    has[uuid:sub(5, 8):upper()] = true
  end
  if has["FFF1"] and has["FFF2"] and (name or ""):upper():find("SPERAX") then return "sperax" end
  if has["2AD2"] then return "ftms_bike" end
  if has["2ACD"] then return "ftms_treadmill" end
  if has["2A53"] then return "rsc" end
  if has["2A5B"] then return "csc" end
  if has["FFF1"] and has["FFF2"] then return "sperax" end
  if has["2A37"] then return "hr" end
  return nil
end

local detect_cb
function M.add(scan_entry, on_done)
  if ble.sb_explore(scan_entry.addr, 500) ~= 0 then on_done(nil, "couldn't start detection"); return end
  detect_cb, M.detecting = on_done, scan_entry
  M.hint = "Checking what " .. scan_entry.name .. " is..."
end

-- ---------- one connection ----------
local function open(c)
  local dev, k = c.dev, KINDS[c.dev.kind]
  local h = ble.sb_open_h(dev.addr, k.svc, k.notify, k.write, dev.seen_before and 0 or 1)
  if h < 0 then
    c.state, c.retry_t = "reconnecting", RETRY_S
    c.hint = "Couldn't connect: " .. ffi.string(ble.sb_last_error()) .. " (retrying)"
    return
  end
  c.h, c.state = h, "connecting"
  c.hint = (c.reconnecting and "Reconnecting to " or "Connecting to ") .. dev.name .. "..."
end

local function close(c)
  if c.h then ble.sb_close_h(c.h) end
  c.h = nil
end

local function on_connected(c)
  if c.reconnecting then M.log("info", "reconnected " .. c.dev.name) end
  c.state, c.hint, c.reconnecting = "connected", nil, false
  c.dev.seen_before = true
  c.reader, c.poll_t, c.last_packet, c.start_tries, c.start_t = sperax.new_reader(), 0, now(), 0, 0
  c.step_hist, c.last_sent_grade, c.grade_t = {}, nil, 0
  c.csc = csc.new()
  M.log("info", "connected to " .. c.dev.name .. " (" .. KINDS[c.dev.kind].label .. ")")
  if c.dev.kind == "ftms_bike" then
    write(c, ftms.REQUEST_CONTROL); write(c, ftms.RESET); write(c, ftms.START)
    c.start_tries = 1
  elseif c.dev.kind == "ftms_treadmill" and c.dev.allow_speed then
    write(c, ftms.REQUEST_CONTROL)
  end
end

local function reconnect(c, why)
  M.log("err", "lost " .. c.dev.name .. ": " .. why .. ". Reconnecting...")
  close(c)
  c.state, c.retry_t, c.reconnecting = "reconnecting", 0.5, true
  c.m.moving = false
  c.hint = "Reconnecting to " .. c.dev.name .. "..."
end

local function trace(c, d)
  local key = tostring(d.speed_kmh) .. " " .. tostring(d.cadence) .. " " .. tostring(d.power)
  if key == c.trace_key then return end
  c.trace_key = key
  if M.trace == nil then
    local ok, store = pcall(require, "store")
    M.trace = ok and io.open(store.exe_dir() .. "/device-trace.txt", "w") or false
    if M.trace then M.trace:write("seconds device speed_kmh cadence power\n") end
  end
  if M.trace then M.trace:write(string.format("%.2f %s %s\n", now(), c.dev.kind, key)) M.trace:flush() end
end

local function handle(c, which_char, b)
  local m, kind = c.m, c.dev.kind
  if kind == "sperax" then
    for _, f in ipairs(sperax.feed(c.reader, b)) do
      if f.cmd == 0x19 and f.crc_ok then
        local s = sperax.decode_status(f)
        if s then
          c.last_packet = now()
          m.speed_kmh, m.steps, m.state = s.speed_kmh, s.steps, s.state
          m.device_distance_m, m.device_seconds = s.distance_m, s.seconds
          local hist = c.step_hist
          hist[#hist + 1] = { t = now(), steps = s.steps }
          while #hist > 1 and now() - hist[1].t > 3 do table.remove(hist, 1) end
          local stepping = #hist >= 2 and hist[#hist].steps > hist[1].steps
          m.moving = s.state == "running" and (s.speed_kmh > 0) and (stepping or not c.dev.stop_when_steps_stop)
          m.cadence = 0
          if #hist >= 2 then
            local dt = hist[#hist].t - hist[1].t
            if dt > 0.5 then m.cadence = (hist[#hist].steps - hist[1].steps) / dt * 60 end
          end
        end
      end
    end
  elseif kind == "rsc" then
    c.last_packet = now()
    local d = rsc.measurement(b)
    m.speed_kmh, m.cadence = d.speed_kmh, d.cadence
    m.moving = d.speed_kmh > 0.3 or d.cadence > 20
  elseif kind == "csc" then
    c.last_packet = now()
    csc.feed(c.csc, b, now())
  elseif kind == "hr" then
    c.last_packet = now()
    m.hr = csc.heart_rate(b)
  else -- FTMS
    if which_char == 0 then
      c.last_packet = now()
      c.pkts = (c.pkts or 0) + 1
      local hex = {}
      for i = 1, #b do hex[i] = string.format("%02X", b[i]) end
      c.last_hex = table.concat(hex, " ")
      local d = kind == "ftms_bike" and ftms.indoor_bike(b) or ftms.treadmill(b)
      for k, v in pairs(d) do m[k] = v end
      trace(c, d)
      if kind == "ftms_bike" then m.moving = (m.cadence or 0) > 5 or (m.power or 0) > 0
      else m.moving = (m.speed_kmh or 0) > 0.3 end
      if m.moving then c.hint = nil; c.start_tries = 99 end
    elseif which_char == 1 then
      local r = ftms.response(b)
      if r and not r.ok then M.log("err", c.dev.name .. ": " .. r.text) end
    else
      local st = ftms.machine_status(b)
      if st == "control permission lost" then write(c, ftms.REQUEST_CONTROL) end
    end
  end
end

local function update_conn(c, dt)
  if c.state == "reconnecting" then
    c.retry_t = c.retry_t - dt
    if c.retry_t <= 0 then c.reconnecting = true; open(c) end
    return
  end
  if c.state == "connecting" then
    local st = ble.sb_state_h(c.h)
    if st == 2 then on_connected(c)
    elseif st == -1 then
      c.hint = ffi.string(ble.sb_error_h(c.h)) .. " (retrying)"
      close(c)
      c.state, c.retry_t = "reconnecting", RETRY_S
    end
    return
  end
  if c.state ~= "connected" then return end

  while true do
    local n = ble.sb_read_h(c.h, rx, 512, which)
    if n <= 0 then break end
    local b = {}
    for i = 0, n - 1 do b[#b + 1] = rx[i] end
    handle(c, which[0], b)
  end

  local kind = c.dev.kind
  if kind == "csc" then csc.update(c.csc, c.m, now()) end
  if kind == "sperax" then
    c.poll_t = c.poll_t + dt
    if c.poll_t >= POLL_S then
      c.poll_t = 0
      if not write(c, sperax.STATUS) then reconnect(c, "write failed") return end
    end
  end
  -- bikes that ignore the start command until the console is used
  if kind == "ftms_bike" and c.start_tries < 4 then
    c.start_t = c.start_t + dt
    if c.start_t > 5 then
      c.start_t = 0
      c.start_tries = c.start_tries + 1
      if c.start_tries < 4 then write(c, ftms.START)
      else c.hint = "No data yet. If the numbers stay at 0 while you pedal, press Start on the bike's console." end
    end
  end
  -- belt speed ramp
  if c.belt_target then
    c.belt_t = (c.belt_t or 0) + dt
    if c.belt_t >= 0.5 then
      local cur = c.belt_cmd or c.m.speed_kmh or 0
      local step = BELT_RAMP * c.belt_t
      local nxt = c.belt_target > cur and math.min(c.belt_target, cur + step) or math.max(c.belt_target, cur - step)
      c.belt_t = 0
      if not c.belt_cmd or math.abs(nxt - c.belt_cmd) >= 0.1 then
        c.belt_cmd = nxt
        if kind == "sperax" and c.m.state == "running" then
          write(c, sperax.encode({ 0x15, 0x01, math.floor(nxt * 10 + 0.5), 0x00 }))
        elseif kind == "ftms_treadmill" then
          write(c, ftms.target_speed(nxt))
        end
      end
    end
  end
  c.grade_t = (c.grade_t or 0) + dt
  -- sensors go quiet while you're still, so give them longer before calling it a dropout
  local limit = (kind == "rsc" or kind == "csc" or kind == "hr") and 30 or WATCHDOG_S
  if now() - c.last_packet > limit then reconnect(c, "no data for " .. limit .. " s") end
end

-- ---------- the device list ----------
function M.conn(dev) return dev and M.conns[dev.addr] end
function M.state_of(dev) local c = M.conn(dev) return c and c.state or "idle" end
function M.hint_of(dev) local c = M.conn(dev) return c and c.hint end
function M.metrics_of(dev) local c = M.conn(dev) return c and c.m end
function M.any_connected()
  for _, c in pairs(M.conns) do if c.state == "connected" then return true end end
  return false
end

function M.connect(dev)
  if M.conns[dev.addr] then return end
  local c = { dev = dev, state = "idle", m = fresh_metrics(dev.kind), reconnecting = false }
  M.conns[dev.addr] = c
  M.order[#M.order + 1] = dev.addr
  open(c)
end

-- without a device: disconnect everything
function M.disconnect(dev)
  if not dev then
    for _, addr in ipairs({ unpack(M.order) }) do M.disconnect(M.conns[addr].dev) end
    return
  end
  local c = M.conns[dev.addr]
  if not c then return end
  if c.state == "connected" then
    if dev.kind == "sperax" and c.belt_cmd then write(c, sperax.encode({ 0x15, 0x00, 0x00, 0x00 })) end
    if dev.kind:find("^ftms") then write(c, ftms.STOP) end
  end
  close(c)
  M.conns[dev.addr] = nil
  for i, a in ipairs(M.order) do if a == dev.addr then table.remove(M.order, i) break end end
end

-- the movement device: the first connected bike / treadmill / pad / footpod (else the first one trying)
local function movement()
  local best
  for _, addr in ipairs(M.order) do
    local c = M.conns[addr]
    if KINDS[c.dev.kind].move then
      if c.state == "connected" then return c end
      best = best or c
    end
  end
  return best
end
local function first_of(kind)
  for _, addr in ipairs(M.order) do
    local c = M.conns[addr]
    if c.dev.kind == kind and c.state == "connected" then return c end
  end
end

local function combine()
  local mv = movement()
  local m = {}
  if mv then for k, v in pairs(mv.m) do m[k] = v end end
  m.kind = mv and mv.dev.kind or nil
  m.sources = {}
  local sensor = first_of("csc")
  if sensor and sensor.m.fresh then
    m.cadence, m.moving = sensor.m.cadence, sensor.m.moving
    m.sources.cadence, m.sources.moving = "sensor", "sensor"
    if not mv then m.kind = "csc" end
  end
  local strap = first_of("hr")
  if strap and (strap.m.hr or 0) > 0 then m.hr, m.sources.hr = strap.m.hr, "strap" end
  M.m = m
  M.dev = mv and mv.dev or (sensor and sensor.dev) or nil
  local lead = mv or sensor
  M.state = lead and lead.state or (next(M.conns) and "connecting" or "idle")
  M.hint = lead and lead.hint or nil
  M.mv = mv
end

-- packet count of the movement device since the last call, and its last raw packet (latency report)
function M.take_pkts()
  local mv = M.mv
  if not mv or not mv.pkts then return nil end
  local n = mv.pkts
  mv.pkts = 0
  return n, mv.last_hex
end

-- ---------- control requests (from games, through the mod API) ----------
-- Hills: to the connected bike the user allowed, rate-limited.
function M.set_grade(pct)
  local c
  for _, addr in ipairs(M.order) do
    local x = M.conns[addr]
    if x.dev.kind == "ftms_bike" and x.state == "connected" then c = x break end
  end
  if not c or c.dev.allow_hills == false then return false end
  pct = math.max(-10, math.min(20, pct))
  c.m.grade = pct
  M.m.grade = pct
  if c.last_sent_grade and math.abs(pct - c.last_sent_grade) < 0.1 and c.grade_t < 2 then return true end
  if c.grade_t < 0.25 and c.last_sent_grade then return true end -- at most four times a second
  write(c, ftms.simulation(pct))
  c.last_sent_grade, c.grade_t = pct, 0
  return true
end

-- Belt speed: only if the user switched it on, never above their max, ramped.
function M.set_belt_speed(kmh)
  for _, addr in ipairs(M.order) do
    local c = M.conns[addr]
    local d = c.dev
    if c.state == "connected" and d.allow_speed and (d.kind == "sperax" or d.kind == "ftms_treadmill") then
      c.belt_target = math.max(d.kind == "sperax" and 1.0 or 0.5, math.min(d.max_speed or 4, kmh))
      return true
    end
  end
  return false
end

-- ---------- update ----------
function M.update(dt)
  if not ble then return end
  if M.detecting then
    local st = ble.sb_explore_state()
    if st == 2 or st == -1 then
      ble.sb_explore_text(exbuf, 65536)
      local raw = ffi.string(exbuf)
      local kind = st == 2 and M.detect(raw, M.detecting.name) or nil
      M.detecting, M.hint = nil, nil
      local cb = detect_cb; detect_cb = nil
      cb(kind, kind and nil or (st == -1 and "couldn't reach the device" or "unknown protocol, use Explore"), raw)
    end
  end
  for _, addr in ipairs({ unpack(M.order) }) do
    local c = M.conns[addr]
    if c then update_conn(c, dt) end
  end
  combine()
end

return M
