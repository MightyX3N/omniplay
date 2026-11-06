-- Sperax pad control test: starts the belt, steps through a few low speeds, stops,
-- and writes pad-test-report.txt next to the exe. Never goes above MAX_KMH.
-- Space stops the belt at any time; so do disconnecting and closing the app.
local ffi = require("ffi")
local sperax = require("drivers.sperax")

local M = { active = false, armed = false }
local MAX_KMH = 3.0
local STEPS = { 1.0, 2.0, 3.0, 1.5 }
local STEP_S, MEASURE_FROM, START_TIMEOUT = 10, 6, 15

local ble, add_log
local phase, t, i, acc, results, acks, report_path = nil, 0, 0, nil, {}, {}, nil

local function hex(b) local s = {} for k, v in ipairs(b) do s[k] = string.format("%02X", v) end return table.concat(s, " ") end

local function send(payload, label)
  local f = sperax.encode(payload)
  local buf = ffi.new("unsigned char[?]", #f, f)
  local ok = ble.sb_write(buf, #f) == 0
  add_log(ok and "tx" or "err", label .. ": " .. hex(f) .. (ok and "" or ("  FAILED " .. ffi.string(ble.sb_last_error()))))
  return ok
end

local function set_speed(kmh)
  kmh = math.min(MAX_KMH, math.max(1.0, kmh))
  return send({ 0x15, 0x01, math.floor(kmh * 10 + 0.5), 0x00 }, string.format("set speed %.1f km/h", kmh))
end

local function write_report(final)
  local out = { "OmniPlay pad test report", os.date("%Y-%m-%d %H:%M") .. (final and "" or "   (incomplete)"), "" }
  out[#out + 1] = string.format("%-14s %14s %12s", "target km/h", "pad reports", "state")
  for k, sp in ipairs(STEPS) do
    local r = results[k]
    if r then out[#out + 1] = string.format("%-14.1f %14.2f %12s", sp, r.n > 0 and r.speed / r.n or 0, r.state or "-") end
  end
  out[#out + 1] = ""
  out[#out + 1] = "Acknowledged commands: " .. (#acks > 0 and table.concat(acks, ", ") or "none seen")
  local works = 0
  for k, sp in ipairs(STEPS) do
    local r = results[k]
    if r and r.n > 0 and math.abs(r.speed / r.n - sp) <= 0.3 then works = works + 1 end
  end
  out[#out + 1] = "Speed control: " .. (works == #STEPS and "WORKS" or works > 0 and ("partly (" .. works .. " of " .. #STEPS .. " speeds reached)") or "no effect")
  local text = table.concat(out, "\n")
  report_path = love.filesystem.getSourceBaseDirectory() .. "/pad-test-report.txt"
  local f = io.open(report_path, "w")
  if f then f:write(text, "\n"); f:close() else report_path = nil end
  love.filesystem.write("pad-test-report.txt", text)
  if final then for _, l in ipairs(out) do add_log("info", l) end end
end

function M.arm(lib, log_fn)
  ble, add_log = lib, log_fn
  M.armed = true
  add_log("err", "PAD TEST: the belt will start moving (max 3 km/h). Stand on the pad, keep the remote in hand. Press T again to start, Space to stop at any time.")
end

function M.start()
  M.armed, M.active = false, true
  phase, t, i, results, acks, report_path = "starting", 0, 0, {}, {}, nil
  send({ 0x15, 0x01, 0x02, 0x00 }, "start belt (3-2-1)")
end

function M.stop(reason)
  if not M.active and not M.armed then return end
  if M.active then
    send({ 0x15, 0x00, 0x00, 0x00 }, "STOP belt")
    if next(results) then write_report(phase == "done") end
  end
  M.active, M.armed = false, false
  add_log("info", "pad test stopped" .. (reason and (": " .. reason) or ""))
end

-- Called for every decoded frame while connected.
function M.on_frame(f, status)
  if not M.active then return end
  if f.cmd == 0xD0 then
    local c = string.format("%02X", f.b[5] or 0)
    acks[#acks + 1] = c
    add_log("info", "pad acknowledged command " .. c .. "  (" .. hex(f.b) .. ")")
  end
  if status and phase == "step" and t >= MEASURE_FROM then
    acc.n = acc.n + 1
    acc.speed = acc.speed + status.speed_kmh
    acc.state = status.state
  end
end

function M.update(dt, status)
  if not M.active then return end
  t = t + dt
  if phase == "starting" then
    if status and status.state == "running" then
      add_log("info", "belt running, stepping through speeds")
      phase, t, i = "step", 0, 1
      acc = { n = 0, speed = 0 }
      set_speed(STEPS[i])
    elseif t > START_TIMEOUT then
      add_log("err", "belt did not report running within " .. START_TIMEOUT .. " s")
      phase = "done"
      M.stop("start not confirmed")
    end
  elseif phase == "step" and t >= STEP_S then
    results[i] = acc
    write_report(false)
    i = i + 1
    if i > #STEPS then
      phase = "done"
      M.stop("test complete")
    else
      t, acc = 0, { n = 0, speed = 0 }
      set_speed(STEPS[i])
    end
  end
end

function M.hint()
  if M.armed then return "Press T again to START THE BELT (max 3 km/h). Space cancels." end
  if not M.active then return nil end
  if phase == "starting" then return "Pad test: starting belt (3-2-1)...  SPACE = STOP" end
  if phase == "step" then
    return string.format("Pad test: step %d of %d, target %.1f km/h (%d s left).  SPACE = STOP", i, #STEPS, STEPS[i], math.max(0, math.ceil(STEP_S - t)))
  end
  return nil
end

function M.report_path() return report_path end

return M
