-- Pretend Bluetooth with four devices (an FTMS bike, a Sperax walking pad, a cadence sensor and
-- a heart-rate strap) that send real-format packets. For testing without hardware:
--   love app --fake        (keys 0-3 set how hard the pretend rider goes: stopped / easy / run / sprint)
-- Same functions as bt/win.lua.
local M = { name = "Pretend devices", effort = 0 }
local OmniPlay -- set by init (the SDK, for the Sperax frame encoder)

local function full(s) return "0000" .. s .. "-0000-1000-8000-00805f9b34fb" end
local DEVICES = {
  { name = "EM 8000", addr = "C0FFEE000001", flags = 1, rssi = -58, kind = "bike",
    services = { ["1826"] = { "2acc", "2ad2", "2ad9", "2ada" } } },
  { name = "SPERAX_RM01", addr = "C0FFEE000002", flags = 32, rssi = -64, kind = "pad",
    services = { fff0 = { "fff1", "fff2" } } },
  { name = "Rockbros C3", addr = "C0FFEE000003", flags = 4, rssi = -70, kind = "csc",
    services = { ["1816"] = { "2a5b", "2a5c" } } },
  { name = "Polar H10", addr = "C0FFEE000004", flags = 16, rssi = -61, kind = "hr",
    services = { ["180d"] = { "2a37" } } },
  { name = "Someone's headphones", addr = "C0FFEE000005", flags = 0, rssi = -80, kind = "other",
    services = { ["180f"] = { "2a19" } } },
}
local by_addr = {}
for _, d in ipairs(DEVICES) do by_addr[d.addr] = d end

-- how the pretend rider moves at each effort
local BIKE = { [0] = { cad = 0, pow = 0, kmh = 0 }, { cad = 50, pow = 90, kmh = 17 }, { cad = 82, pow = 165, kmh = 26 }, { cad = 100, pow = 250, kmh = 34 } }
local PAD = { [0] = 0, 2.0, 3.8, 5.2 }
local HR = { [0] = 72, 104, 138, 162 }

local t = 0
local scanning, scan_t = false, 0
local ex = { state = 0 }
local conns, next_h = {}, 1
M.drop = {} -- addr -> true: the next open of that device fails once (to test retries)

function M.load(sdk) OmniPlay = sdk; return M end
function M.last_error() return "pretend error" end
function M.scan_start() scanning, scan_t = true, 0; return true end
function M.scan_stop() scanning = false end
function M.scan_list()
  local list = {}
  if not scanning and scan_t == 0 then return list end
  for i, d in ipairs(DEVICES) do
    if scan_t > 0.3 * i then list[#list + 1] = { name = d.name, addr = d.addr, rssi = d.rssi, age_ms = 200, flags = d.flags } end
  end
  return list
end

function M.explore(addr)
  if ex.state == 1 or not by_addr[addr] then return false end
  ex = { state = 1, addr = addr, t = 0 }
  return true
end
function M.explore_state() return ex.state end
function M.explore_text()
  local d = ex.addr and by_addr[ex.addr]
  if not d then return "" end
  local lines = { "device " .. d.name }
  for svc, chars in pairs(d.services) do
    lines[#lines + 1] = "service " .. full(svc)
    for _, c in ipairs(chars) do lines[#lines + 1] = "  char " .. full(c) end
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.open(addr, service, notify_csv, write_uuid)
  local d = by_addr[addr]
  if not d then return nil, "no such device" end
  local h = next_h
  next_h = next_h + 1
  local notify = {}
  for u in notify_csv:gmatch("[^,]+") do notify[#notify + 1] = u:lower():sub(5, 8) end
  conns[h] = { d = d, state = 1, t = 0, notify = notify, q = {}, send_t = 0, crank = 0, crank_time = 0, steps = 0,
    secs = 0, dist = 0, pad_kmh = 0, fail = M.drop[addr] }
  M.drop[addr] = nil
  return h
end
function M.state(h) return conns[h] and conns[h].state or 0 end
function M.error(h) return conns[h] and conns[h].err or "closed" end
function M.close(h) conns[h] = nil end
function M.read(h)
  local c = conns[h]
  if not c or #c.q == 0 then return nil end
  local p = table.remove(c.q, 1)
  return p[1], p[2]
end

local function push(c, char, bytes)
  for i, u in ipairs(c.notify) do if u == char then c.q[#c.q + 1] = { bytes, i - 1 } return end end
end

function M.write(h, bytes)
  local c = conns[h]
  if not c or c.state ~= 2 then return false end
  c.writes = (c.writes or 0) + 1
  if c.d.kind == "bike" then
    push(c, "2ad9", { 0x80, bytes[1], 0x01 }) -- control point: success
    if bytes[1] == 0x11 then c.grade = ((bytes[4] or 0) + (bytes[5] or 0) * 256) / 100 end
  elseif c.d.kind == "pad" then
    -- decode the frame enough to answer a status request and follow a speed command
    local cmd = bytes[4]
    if cmd == 0x19 then
      local st = c.pad_kmh > 0 and 0x10 or 0x02
      local function be(v) v = math.floor(v) % 65536; return math.floor(v / 256), v % 256 end
      local s1, s2 = be(c.secs); local d1, d2 = be(c.dist / 10); local k1, k2 = be(c.secs / 20); local p1, p2 = be(c.steps)
      local frame = OmniPlay.SPERAX.encode({ 0x19, 0, 0, st, 0, 0, s1, s2, d1, d2, k1, k2, p1, p2, math.floor(c.pad_kmh * 10 + 0.5), 0, 0, 0 })
      push(c, "fff1", frame)
    elseif cmd == 0x15 and bytes[5] == 0x01 then
      c.cmd_kmh = (bytes[6] or 0) / 10
    end
  end
  return true
end

local function le16(v) v = math.floor(v + 0.5) % 65536; return v % 256, math.floor(v / 256) end

function M.update(dt)
  t = t + dt
  if scanning then scan_t = scan_t + dt end
  if ex.state == 1 then
    ex.t = ex.t + dt
    if ex.t > 0.8 then ex.state = 2 end
  end
  for _, c in pairs(conns) do
    c.t = c.t + dt
    if c.state == 1 and c.t > 0.6 then
      if c.fail then c.state, c.err = -1, "The device didn't answer" else c.state = 2 end
    end
    if c.state == 2 then
      local e = M.effort
      if c.d.kind == "pad" then
        local target = c.cmd_kmh or PAD[e]
        if e == 0 then target = 0 end
        c.pad_kmh = c.pad_kmh + math.max(-dt, math.min(dt, target - c.pad_kmh)) * 1.5
        if target == 0 and c.pad_kmh < 0.05 then c.pad_kmh = 0 end
        if c.pad_kmh > 0 then
          c.secs, c.dist = c.secs + dt, c.dist + c.pad_kmh / 3.6 * dt
          c.steps = c.steps + c.pad_kmh * 0.4 * dt -- ~110 steps a minute at 4.5 km/h
        end
      end
      c.send_t = c.send_t + dt
      if c.send_t >= 0.5 then
        c.send_t = 0
        if c.d.kind == "bike" then
          local b = BIKE[e]
          local s1, s2 = le16(b.kmh * 100); local c1, c2 = le16(b.cad * 2); local p1, p2 = le16(b.pow)
          push(c, "2ad2", { 0x44, 0x00, s1, s2, c1, c2, p1, p2 })
        elseif c.d.kind == "csc" then
          local rpm = BIKE[e].cad
          if rpm > 0 then
            c.crank = c.crank + rpm / 60 * 0.5
            c.crank_time = c.crank_time + 0.5 * 1024
          end
          local r1, r2 = le16(math.floor(c.crank)); local t1, t2 = le16(c.crank_time)
          push(c, "2a5b", { 0x02, r1, r2, t1, t2 })
        elseif c.d.kind == "hr" then
          push(c, "2a37", { 0x00, HR[e] })
        end
      end
    end
  end
end

-- for the test script: what the pretend devices received
function M.debug()
  local t2 = {}
  for _, c in pairs(conns) do t2[c.d.addr] = { writes = c.writes or 0, grade = c.grade, cmd_kmh = c.cmd_kmh, state = c.state, pad_kmh = c.pad_kmh, effort = M.effort } end
  return t2
end

return M
