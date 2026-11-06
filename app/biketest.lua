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
  if connected then send(ftms.STOP, "stop") end
  ble.sb_close()
  M.active, connected, connecting = false, false, false
end

local function on_connected()
  connecting, connected = false, true
  add_log("info", "connected. Taking control and starting a session.")
  send(ftms.REQUEST_CONTROL, "request control")
  send(ftms.START, "start")
  send(ftms.simulation(grade), string.format("hill %+d%%", grade))
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
  log_t = log_t + (dt or 0)
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
      add_log(r and r.ok and "info" or "err", "bike replied: " .. last_reply)
    else
      status_text = ftms.machine_status(b)
      add_log("info", "bike status: " .. status_text .. "  (" .. hex(b) .. ")")
    end
  end
end

function M.keypressed(k)
  if not connected then return false end
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
  txt("Pedal, then try a hill and a resistance change. Say what you feel. S = take control + start again, X = stop.", 28, y + 120, C.dim)
  return y + 162
end

return M
