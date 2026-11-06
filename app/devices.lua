-- Device manager: one active movement device at a time. Detects the protocol when a
-- device is added, connects, decodes everything into one metrics table, reconnects
-- after dropouts, and applies hill / belt-speed requests within the user's limits.
local ffi = require("ffi")
local bit = require("bit")
local sperax = require("drivers.sperax")
local ftms = require("drivers.ftms")
local rsc = require("drivers.rsc")

local M = {
  state = "idle",          -- idle | detecting | connecting | connected | reconnecting
  dev = nil,               -- the saved device table being used
  hint = nil,              -- message shown to the user (e.g. "press Start on the console")
  m = {},                  -- live metrics, see reset_metrics
  log = function() end,
}

local KINDS = {
  sperax = { svc = "fff0", notify = "fff1", write = "fff2", label = "Sperax pad", icon = "walk" },
  ftms_bike = { svc = "1826", notify = "2ad2,2ad9,2ada", write = "2ad9", label = "FTMS bike", icon = "bike" },
  ftms_treadmill = { svc = "1826", notify = "2acd,2ad9,2ada", write = "2ad9", label = "FTMS treadmill", icon = "walk" },
  rsc = { svc = "1814", notify = "2a53", write = "", label = "Footpod", icon = "shoe" },
}
M.KINDS = KINDS

local POLL_S, WATCHDOG_S, RETRY_S = 0.25, 6, 3
local BELT_RAMP = 0.5 -- km/h per second, whatever the machine itself allows

local ble
local rx = ffi.new("unsigned char[512]")
local which = ffi.new("int[1]")
local exbuf = ffi.new("char[65536]")
local reader, poll_t, last_packet, retry_t, start_tries, start_t = nil, 0, 0, 0, 0, 0
local step_hist, last_sent_grade, grade_t = {}, nil, 0
local belt_target, belt_cmd, belt_t = nil, nil, 0
local now = function() return love.timer.getTime() end

local function reset_metrics()
  M.m = { speed_kmh = 0, cadence = 0, power = nil, hr = nil, steps = nil, distance_m = nil,
    moving = false, state = nil, resistance = nil, kind = M.dev and M.dev.kind }
end

local function write(bytes)
  local buf = ffi.new("unsigned char[?]", #bytes, bytes)
  return ble.sb_write(buf, #bytes) == 0
end

function M.init(lib, log_fn)
  ble, M.log = lib, log_fn or M.log
  reset_metrics()
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
  if has["FFF1"] and has["FFF2"] then return "sperax" end
  return nil
end

local detect_cb
function M.add(scan_entry, on_done)
  ble.sb_scan_stop()
  if ble.sb_explore(scan_entry.addr, 500) ~= 0 then on_done(nil, "couldn't start detection"); return end
  M.state, detect_cb, M.detecting = "detecting", on_done, scan_entry
  M.hint = "Checking what " .. scan_entry.name .. " is..."
end

-- ---------- connecting ----------
local function open()
  local dev, k = M.dev, KINDS[M.dev.kind]
  ble.sb_set_cache_mode(dev.seen_before and 0 or 1)
  if ble.sb_open(dev.addr, k.svc, k.notify, k.write) ~= 0 then
    M.state, retry_t = "reconnecting", RETRY_S
    M.hint = "Couldn't connect: " .. ffi.string(ble.sb_last_error()) .. " (retrying)"
    return
  end
  M.state = "connecting"
  M.hint = (M.reconnecting and "Reconnecting to " or "Connecting to ") .. dev.name .. "..."
end

function M.connect(dev)
  M.disconnect()
  M.dev, M.want, M.reconnecting = dev, true, false
  reset_metrics()
  ble.sb_scan_stop()
  open()
end

function M.disconnect()
  if M.state == "connected" and M.dev then
    if M.dev.kind == "sperax" and belt_cmd then write(sperax.encode({ 0x15, 0x00, 0x00, 0x00 })) end
    if M.dev.kind:find("^ftms") then write(ftms.STOP) end
  end
  if M.state ~= "idle" and M.state ~= "detecting" then ble.sb_close() end
  M.state, M.want, M.hint = "idle", false, nil
  belt_target, belt_cmd = nil, nil
  reset_metrics()
end

local function on_connected()
  if M.reconnecting then M.log("info", "reconnected") end
  M.state, M.hint, M.reconnecting = "connected", nil, false
  M.dev.seen_before = true
  reader, poll_t, last_packet, start_tries, start_t = sperax.new_reader(), 0, now(), 0, 0
  step_hist, last_sent_grade = {}, nil
  M.log("info", "connected to " .. M.dev.name .. " (" .. KINDS[M.dev.kind].label .. ")")
  if M.dev.kind == "ftms_bike" then
    write(ftms.REQUEST_CONTROL); write(ftms.RESET); write(ftms.START)
    start_tries = 1
  elseif M.dev.kind == "ftms_treadmill" and M.dev.allow_speed then
    write(ftms.REQUEST_CONTROL)
  end
end

local function reconnect(why)
  M.log("err", "lost " .. (M.dev and M.dev.name or "device") .. ": " .. why .. ". Reconnecting...")
  ble.sb_close()
  M.state, retry_t, M.reconnecting = "reconnecting", 0.5, true
  M.m.moving = false
  M.hint = "Reconnecting to " .. M.dev.name .. "..."
end

-- ---------- data ----------
local function moving_from_steps()
  if #step_hist < 2 then return false end
  return step_hist[#step_hist].steps > step_hist[1].steps
end

local function handle(which_char, b)
  local m, kind = M.m, M.dev.kind
  if kind == "sperax" then
    for _, f in ipairs(sperax.feed(reader, b)) do
      if f.cmd == 0x19 and f.crc_ok then
        local s = sperax.decode_status(f)
        if s then
          last_packet = now()
          m.speed_kmh, m.steps, m.state = s.speed_kmh, s.steps, s.state
          m.device_distance_m, m.device_seconds = s.distance_m, s.seconds
          step_hist[#step_hist + 1] = { t = now(), steps = s.steps }
          while #step_hist > 1 and now() - step_hist[1].t > 3 do table.remove(step_hist, 1) end
          m.moving = s.state == "running" and (s.speed_kmh > 0) and (moving_from_steps() or not M.dev.stop_when_steps_stop)
          m.cadence = 0
          if #step_hist >= 2 then
            local dt = step_hist[#step_hist].t - step_hist[1].t
            if dt > 0.5 then m.cadence = (step_hist[#step_hist].steps - step_hist[1].steps) / dt * 60 end
          end
        end
      end
    end
  elseif kind == "rsc" then
    last_packet = now()
    local d = rsc.measurement(b)
    m.speed_kmh, m.cadence = d.speed_kmh, d.cadence
    m.moving = d.speed_kmh > 0.3 or d.cadence > 20
  else -- FTMS
    if which_char == 0 then
      last_packet = now()
      M.pkts = (M.pkts or 0) + 1
      local hex = {}
      for i = 1, #b do hex[i] = string.format("%02X", b[i]) end
      M.last_hex = table.concat(hex, " ")
      local d = kind == "ftms_bike" and ftms.indoor_bike(b) or ftms.treadmill(b)
      for k, v in pairs(d) do m[k] = v end
      -- trace of every new reading, so the timing of a real stop / start can be checked
      local key = tostring(d.speed_kmh) .. " " .. tostring(d.cadence) .. " " .. tostring(d.power)
      if key ~= M.trace_key then
        M.trace_key = key
        if M.trace == nil then
          local ok, store = pcall(require, "store")
          M.trace = ok and io.open(store.exe_dir() .. "/device-trace.txt", "w") or false
          if M.trace then M.trace:write("seconds speed_kmh cadence power\n") end
        end
        if M.trace then M.trace:write(string.format("%.2f %s\n", now(), key)) M.trace:flush() end
      end
      if kind == "ftms_bike" then
        m.moving = (m.cadence or 0) > 5 or (m.power or 0) > 0
      else
        m.moving = (m.speed_kmh or 0) > 0.3
      end
      if m.moving then M.hint = nil; start_tries = 99 end
    elseif which_char == 1 then
      local r = ftms.response(b)
      if r and not r.ok then M.log("err", M.dev.name .. ": " .. r.text) end
    else
      local st = ftms.machine_status(b)
      if st == "control permission lost" then write(ftms.REQUEST_CONTROL) end
    end
  end
end

-- ---------- control requests (from games, through the mod API) ----------
-- Hills: only on bikes the user allowed, rate-limited.
function M.set_grade(pct)
  if M.state ~= "connected" or M.dev.kind ~= "ftms_bike" or M.dev.allow_hills == false then return false end
  pct = math.max(-10, math.min(20, pct))
  M.m.grade = pct
  if last_sent_grade and math.abs(pct - last_sent_grade) < 0.1 and grade_t < 2 then return true end
  if grade_t < 0.25 and last_sent_grade then return true end -- at most four times a second
  write(ftms.simulation(pct))
  last_sent_grade, grade_t = pct, 0
  return true
end

-- Belt speed: only if the user switched it on, never above their max, ramped.
function M.set_belt_speed(kmh)
  local d = M.dev
  if M.state ~= "connected" or not d or not d.allow_speed then return false end
  if d.kind ~= "sperax" and d.kind ~= "ftms_treadmill" then return false end
  belt_target = math.max(d.kind == "sperax" and 1.0 or 0.5, math.min(d.max_speed or 4, kmh))
  return true
end

-- ---------- update ----------
function M.update(dt)
  if not ble then return end
  if M.state == "detecting" then
    local st = ble.sb_explore_state()
    if st == 2 or st == -1 then
      ble.sb_explore_text(exbuf, 65536)
      local raw = ffi.string(exbuf)
      local kind = st == 2 and M.detect(raw, M.detecting.name) or nil
      M.state, M.hint = "idle", nil
      local cb = detect_cb; detect_cb = nil
      cb(kind, kind and nil or (st == -1 and "couldn't reach the device" or "unknown protocol, use Explore"), raw)
    end
    return
  end
  if M.state == "reconnecting" then
    retry_t = retry_t - dt
    if retry_t <= 0 and M.want then M.reconnecting = true; open() end
    return
  end
  if M.state == "connecting" then
    local st = ble.sb_state()
    if st == 2 then on_connected()
    elseif st == -1 then
      M.state, retry_t = "reconnecting", RETRY_S
      M.hint = ffi.string(ble.sb_last_error()) .. " (retrying)"
    end
    return
  end
  if M.state ~= "connected" then return end

  while true do
    local n = ble.sb_read_ex(rx, 512, which)
    if n <= 0 then break end
    local b = {}
    for i = 0, n - 1 do b[#b + 1] = rx[i] end
    handle(which[0], b)
  end

  local kind = M.dev.kind
  if kind == "sperax" then
    poll_t = poll_t + dt
    if poll_t >= POLL_S then
      poll_t = 0
      if not write(sperax.STATUS) then reconnect("write failed") return end
    end
  end

  -- bikes that ignore the start command until the console is used
  if kind == "ftms_bike" and start_tries < 4 then
    start_t = start_t + dt
    if start_t > 5 then
      start_t = 0
      start_tries = start_tries + 1
      if start_tries < 4 then write(ftms.START)
      else M.hint = "No data yet. If the numbers stay at 0 while you pedal, press Start on the bike's console." end
    end
  end

  -- belt speed ramp
  if belt_target then
    belt_t = belt_t + dt
    if belt_t >= 0.5 then
      local cur = belt_cmd or M.m.speed_kmh or 0
      local step = BELT_RAMP * belt_t
      local nxt = belt_target > cur and math.min(belt_target, cur + step) or math.max(belt_target, cur - step)
      belt_t = 0
      if not belt_cmd or math.abs(nxt - belt_cmd) >= 0.1 then
        belt_cmd = nxt
        if kind == "sperax" and M.m.state == "running" then
          write(sperax.encode({ 0x15, 0x01, math.floor(nxt * 10 + 0.5), 0x00 }))
        elseif kind == "ftms_treadmill" then
          write(ftms.target_speed(nxt))
        end
      end
    end
  end
  grade_t = grade_t + dt

  -- footpods often go quiet while you stand still, so give them longer
  local limit = kind == "rsc" and 30 or WATCHDOG_S
  if now() - last_packet > limit then reconnect("no data for " .. limit .. " s") end
end

return M
