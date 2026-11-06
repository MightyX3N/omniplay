-- FTMS bike control test: takes control of an FTMS bike, starts a session, and lets
-- you send hill grades and resistance levels while watching what the bike reports.
local ffi = require("ffi")
local ftms = require("drivers.ftms")

local M = { active = false }
local ble, add_log
local name, connecting, connected = nil, false, false
local data, last_reply, status_text = nil, "none yet", "none yet"
local grade, level, enc_i = 0, 10, 1
local history = {}
local log_t, peak = 0, { speed_kmh = 0, cadence = 0, power = 0 }
local rx = ffi.new("unsigned char[512]")
local which = ffi.new("int[1]")

local function hex(b) local t = {} for i, v in ipairs(b) do t[i] = string.format("%02X", v) end return table.concat(t, " ") end

local function send(cmd, label)
  local buf = ffi.new("unsigned char[?]", #cmd, cmd)
  if ble.sb_write(buf, #cmd) ~= 0 then
    add_log("err", label .. " failed to send: " .. ffi.string(ble.sb_last_error()))
    return false
  end
  add_log("tx", label .. ": " .. hex(cmd))
  return true
end

function M.start(lib, log_fn, dev)
  ble, add_log, M.active = lib, log_fn, true
  name, connecting, connected, data = dev.name, true, false, nil
  log_t, peak = 0, { speed_kmh = 0, cadence = 0, power = 0 }
  last_reply, status_text, grade, level = "none yet", "none yet", 0, 10
  ble.sb_scan_stop()
  -- notify list order matters: 0 = indoor bike data, 1 = control point, 2 = machine status
  if ble.sb_open(dev.addr, "1826", "2ad2,2ad9,2ada", "2ad9") ~= 0 then
    add_log("err", "connect failed: " .. ffi.string(ble.sb_last_error()))
    M.active = false
    return false
  end
  add_log("info", "bike test: connecting to " .. dev.name)
  return true
end

function M.stop()
  if auto and not auto.done and next(auto.results) then write_report(false) end
  if connected then send(ftms.STOP, "stop") end
  ble.sb_close()
  M.active, connected, connecting = false, false, false
end

-- ---------- automatic test ----------
-- Steps through hills and resistance levels while you pedal, measures what the bike
-- reports in the second half of each step, and writes a report next to the exe.
local STEP_S, MEASURE_FROM = 8, 4
local STEPS = {
  { kind = "hill", v = 0, label = "flat 0%" },
  { kind = "hill", v = 8, label = "hill +8%" },
  { kind = "hill", v = 0, label = "flat again" },
  { kind = "res", v = 5, enc = 1 }, { kind = "res", v = 20, enc = 1 },
  { kind = "res", v = 5, enc = 2 }, { kind = "res", v = 20, enc = 2 },
  { kind = "res", v = 5, enc = 3 }, { kind = "res", v = 20, enc = 3 },
}
for _, st in ipairs(STEPS) do
  if st.kind == "res" then st.label = "resistance " .. st.v .. " (" .. ftms.RESISTANCE_ENCODINGS[st.enc] .. ")" end
end
local auto = nil -- { i, t, waiting, idle, results, done }
local report_path

local function pedalling() return data and (data.cadence or 0) > 20 end

local function send_step(st)
  if st.kind == "hill" then
    grade = st.v
    send(ftms.simulation(grade), "auto: " .. st.label)
  else
    level, enc_i = st.v, st.enc
    send(ftms.resistance(level, ftms.RESISTANCE_ENCODINGS[enc_i]), "auto: " .. st.label)
  end
end

local function begin_step()
  auto.t, auto.sum = 0, { n = 0, res = 0, power = 0, cadence = 0, speed = 0 }
  auto.reply = nil
  send_step(STEPS[auto.i])
end

local function avg(r, k) return r.n > 0 and r[k] / r.n or 0 end
local function load(r) local c = avg(r, "cadence"); return c > 0 and avg(r, "power") / c or 0 end

local function changed(a, b)
  if not (a and b) or a.n == 0 or b.n == 0 then return nil end
  local dr = math.abs(avg(b, "res") - avg(a, "res"))
  local la, lb = load(a), load(b)
  local dl = la > 0 and (lb - la) / la or 0
  return dr >= 1 or dl > 0.25, dr, dl
end

local function write_report(final)
  local r, out = auto.results, {}
  local nres = 0
  for i = 1, #STEPS do if r[i] then nres = i end end
  local function add(x) out[#out + 1] = x end
  add("OmniPlay bike test report: " .. tostring(name))
  add(os.date("%Y-%m-%d %H:%M") .. (final and "" or string.format("   (incomplete: %d of %d steps)", nres, #STEPS)))
  add("")
  add(string.format("%-28s %10s %9s %8s %8s  %s", "step", "bike res", "power W", "rpm", "km/h", "bike reply"))
  for i, st in ipairs(STEPS) do
    local x = r[i]
    if x then
      add(string.format("%-28s %10.1f %9.0f %8.0f %8.1f  %s", st.label, avg(x, "res"), avg(x, "power"),
        avg(x, "cadence"), avg(x, "speed"), x.reply or "-"))
    end
  end
  add("")
  local hills = changed(r[1], r[2])
  add("Hill simulation: " .. (hills == nil and "not measured" or hills and "WORKS (resistance or load went up on +8%)" or "no effect"))
  local works = {}
  for e = 1, 3 do
    local lo, hi = r[2 + e * 2], r[3 + e * 2]
    local ok = changed(lo, hi)
    -- if the bike reports its resistance, it must match what was asked, not just change
    if ok ~= nil and (avg(lo, "res") > 0 or avg(hi, "res") > 0) then
      ok = math.abs(avg(lo, "res") - STEPS[2 + e * 2].v) <= 1.5 and math.abs(avg(hi, "res") - STEPS[3 + e * 2].v) <= 1.5
    end
    add("Resistance, " .. ftms.RESISTANCE_ENCODINGS[e] .. ": " .. (ok == nil and "not measured" or ok and "WORKS" or "no effect"))
    if ok then works[#works + 1] = ftms.RESISTANCE_ENCODINGS[e] end
  end
  add("")
  add("Use for this bike: " .. (hills and "hill simulation" or (#works > 0 and ("resistance level, " .. works[1]) or "no control, data only")))
  local text = table.concat(out, "\n")
  report_path = love.filesystem.getSourceBaseDirectory() .. "/bike-test-report.txt"
  local f = io.open(report_path, "w")
  if f then f:write(text, "\n"); f:close() else report_path = nil end
  love.filesystem.write("bike-test-report.txt", text)
  if not final then return end
  love.system.setClipboardText(text)
  for _, l in ipairs(out) do add_log("info", l) end
  add_log("info", report_path and ("report saved to " .. report_path) or "report copied to clipboard")
end

local function auto_update(dt)
  if not auto or auto.done then return end
  if auto.waiting then
    if pedalling() then auto.waiting = false; add_log("info", "pedalling detected, test started"); begin_step() end
    return
  end
  if not pedalling() then
    auto.idle = auto.idle + dt
    if auto.idle > 3 then
      auto.idle, auto.waiting = 0, true
      add_log("err", "pedalling stopped, waiting to restart step " .. auto.i)
    end
    return
  end
  auto.idle = 0
  auto.t = auto.t + dt
  if auto.t >= MEASURE_FROM and data then
    local m = auto.sum
    m.n = m.n + 1
    m.res = m.res + (data.resistance or 0); m.power = m.power + (data.power or 0)
    m.cadence = m.cadence + (data.cadence or 0); m.speed = m.speed + (data.speed_kmh or 0)
  end
  if auto.t >= STEP_S then
    auto.sum.reply = auto.reply
    auto.results[auto.i] = auto.sum
    auto.i = auto.i + 1
    if auto.i > #STEPS then
      auto.done = true
      send(ftms.simulation(0), "auto: back to flat")
      write_report(true)
    else
      write_report(false)
      begin_step()
    end
  end
end

local function on_connected()
  connecting, connected = false, true
  add_log("info", "connected. Taking control and starting a session.")
  send(ftms.REQUEST_CONTROL, "request control")
  send(ftms.START, "start")
  send(ftms.simulation(grade), string.format("hill %+d%%", grade))
  auto = { i = 1, t = 0, waiting = true, idle = 0, results = {}, done = false }
  add_log("info", "automatic test: start pedalling and keep a steady pace for about 75 seconds")
end

function M.update(dt)
  if connecting then
    local st = ble.sb_state()
    if st == 2 then on_connected()
    elseif st == -1 then
      add_log("err", "connect failed: " .. ffi.string(ble.sb_last_error()))
      M.active, connecting = false, false
    end
    return
  end
  if not connected then return end
  dt = dt or 0
  auto_update(dt)
  log_t = log_t + dt
  if log_t >= 1 and data then
    log_t = 0
    add_log("frame", string.format("bike: %s   [sent hill %+d%%, resistance %d]", ftms.bike_text(data), grade, level))
  end
  while true do
    local n = ble.sb_read_ex(rx, 512, which)
    if n <= 0 then break end
    local b = {}
    for i = 0, n - 1 do b[#b + 1] = rx[i] end
    if which[0] == 0 then
      -- merge: some bikes split the data over several packets, so keep the last value of each field
      local d = ftms.indoor_bike(b)
      data = data or {}
      for k2, v in pairs(d) do data[k2] = v end
      for k2 in pairs(peak) do if d[k2] and d[k2] > peak[k2] then peak[k2] = d[k2] end end
      history[#history + 1] = data
      if #history > 600 then table.remove(history, 1) end
    elseif which[0] == 1 then
      local r = ftms.response(b)
      last_reply = r and r.text or hex(b)
      if auto and not auto.done then auto.reply = last_reply end
      add_log(r and r.ok and "info" or "err", "bike replied: " .. last_reply)
    else
      status_text = ftms.machine_status(b)
      add_log("info", "bike status: " .. status_text .. "  (" .. hex(b) .. ")")
    end
  end
end

function M.keypressed(k)
  if not connected then return false end
  if auto and not auto.done and (k == "up" or k == "down" or k == "left" or k == "right") then return true end
  if k == "up" or k == "down" then
    grade = math.max(-5, math.min(15, grade + (k == "up" and 1 or -1)))
    send(ftms.simulation(grade), string.format("hill %+d%%", grade))
  elseif k == "right" or k == "left" then
    level = math.max(1, math.min(32, level + (k == "right" and 1 or -1)))
    local enc = ftms.RESISTANCE_ENCODINGS[enc_i]
    send(ftms.resistance(level, enc), "resistance " .. level .. " (" .. enc .. ")")
  elseif k == "m" then
    enc_i = enc_i % #ftms.RESISTANCE_ENCODINGS + 1
    add_log("info", "resistance encoding: " .. ftms.RESISTANCE_ENCODINGS[enc_i])
  elseif k == "s" then send(ftms.REQUEST_CONTROL, "request control"); send(ftms.START, "start")
  elseif k == "x" then send(ftms.STOP, "stop")
  else return false end
  return true
end

function M.summary()
  return {
    "bike test: " .. tostring(name),
    "sent hill: " .. string.format("%+d%%", grade) .. "   sent resistance: " .. level .. " (" .. ftms.RESISTANCE_ENCODINGS[enc_i] .. ")",
    "last reply: " .. last_reply .. "   last status: " .. status_text,
    "bike reports: " .. (data and ftms.bike_text(data) or "no data yet"),
    string.format("peaks this test: speed %.1f km/h, cadence %.0f rpm, power %d W", peak.speed_kmh, peak.cadence, peak.power),
  }
end

-- Draw the test panel; returns the y below it.
function M.draw(y, W, txt, panel, metric, C, fonts)
  panel(12, y, W - 24, 150)
  if connecting then
    txt("Connecting to " .. tostring(name) .. ": " .. ffi.string(ble.sb_status_text()), 28, y + 14, C.dim)
    return y + 162
  end
  metric("Speed", data and data.speed_kmh and string.format("%.1f km/h", data.speed_kmh) or "-", 28, y + 12)
  metric("Cadence", data and data.cadence and string.format("%.0f rpm", data.cadence) or "-", 200, y + 12)
  metric("Power", data and data.power and (data.power .. " W") or "-", 370, y + 12)
  metric("Bike resistance", data and data.resistance and tostring(data.resistance) or "-", 520, y + 12)
  txt(string.format("Sent hill %+d%%  (Up/Down)     Sent resistance %d, %s  (Left/Right, M changes encoding)",
    grade, level, ftms.RESISTANCE_ENCODINGS[enc_i]), 28, y + 76, C.text)
  txt("Last bike reply: " .. last_reply .. "     Bike status: " .. status_text, 28, y + 98, C.acc)
  if auto and not auto.done then
    local st = STEPS[auto.i]
    txt(auto.waiting and "Automatic test: start pedalling at a steady pace."
      or string.format("Automatic test, step %d of %d: %s  (%d s left). Keep pedalling steadily.", auto.i, #STEPS, st.label,
        math.max(0, math.ceil(STEP_S - auto.t))), 28, y + 120, C.ok)
  elseif auto and auto.done then
    txt("Automatic test done. " .. (report_path and "Report saved next to OmniPlay.exe." or "Report copied to clipboard."), 28, y + 120, C.ok)
  else
    txt("Pedal, then try a hill and a resistance change. S = take control + start again, X = stop.", 28, y + 120, C.dim)
  end
  return y + 162
end

return M
