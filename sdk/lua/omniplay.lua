-- OmniPlay SDK (Lua): talk to fitness devices from any game. Pure Lua 5.1 - 5.4 / LuaJIT, no
-- libraries, no OS code, so it runs in LÖVE on desktop and Android, love.js, GMod, anywhere.
--
-- It doesn't do Bluetooth itself: your platform's Bluetooth hands it the bytes it receives and
-- sends the bytes it asks for (the "adapter", a few lines; see docs/SDK.md). Everything about
-- the devices is in here: which services to use, decoding, commands, combining several devices,
-- hills, belt speed, gait and start/stop events.
--
--   local OmniPlay = require("omniplay")
--   local op = OmniPlay.new{ send = function(id, char, bytes) ble_write(id, char, bytes) end }
--   -- Bluetooth connected a device and found its services / characteristics:
--   local kind = op:add(id, name, uuids)          -- nil = not a supported device
--   for _, c in ipairs(op:notify_chars(id)) do ble_subscribe(id, c) end
--   op:connected(id)
--   -- every notification:                       op:receive(id, char, bytes)
--   -- every frame:                              op:update(dt);  local v = op:values()
--   -- hills / walking pad speed:                op:set_grade(4.5);  op:set_belt_speed(3.2)
--
-- License: OmniPlay SDK License (MIT + don't sell OmniPlay support separately).
local M = { VERSION = 1 }

-- ---------- small helpers (no bit library, so it runs everywhere) ----------
local floor = math.floor
local function bit(v, n) return floor(v / 2 ^ n) % 2 == 1 end
local function bxor(a, b)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    if a % 2 ~= b % 2 then r = r + p end
    a, b, p = floor(a / 2), floor(b / 2), p * 2
  end
  return r
end
local function u16(b, i) return (b[i] or 0) + (b[i + 1] or 0) * 256 end
local function s16(b, i) local v = u16(b, i); return v >= 0x8000 and v - 0x10000 or v end
local function u32(b, i) return u16(b, i) + u16(b, i + 2) * 65536 end
local function le16(v) v = floor(v) % 65536; return v % 256, floor(v / 256) end
local function clamp(v, a, b) return v < a and a or v > b and b or v end

-- bytes in: a string or an array of numbers. bytes out: a string (M.bytes_out = "table" for arrays)
local function to_array(bytes)
  if type(bytes) == "table" then return bytes end
  local t = {}
  for i = 1, #bytes do t[i] = bytes:byte(i) end
  return t
end
local function out(self, t)
  if self.bytes_out == "table" then return t end
  local s = {}
  for i = 1, #t do s[i] = string.char(t[i]) end
  return table.concat(s)
end

-- 16-bit short form of a Bluetooth UUID ("2AD2", "00002ad2-0000-1000-8000-00805f9b34fb" -> "2ad2")
local function short(uuid)
  uuid = tostring(uuid):lower()
  local s = uuid:match("^0000(%x%x%x%x)%-0000%-1000%-8000%-00805f9b34fb$") or uuid:match("^(%x%x%x%x)$")
  return s or uuid
end
local function full(s) return #s == 4 and ("0000" .. s .. "-0000-1000-8000-00805f9b34fb") or s end
M.short_uuid, M.full_uuid = short, full

-- ---------- the devices ----------
-- service to look for, characteristics to subscribe to, and where commands go
local KINDS = {
  ftms_bike = { service = "1826", notify = { "2ad2", "2ad9", "2ada" }, write = "2ad9", label = "Bike (FTMS)", move = true },
  ftms_treadmill = { service = "1826", notify = { "2acd", "2ad9", "2ada" }, write = "2ad9", label = "Treadmill (FTMS)", move = true },
  sperax = { service = "fff0", notify = { "fff1" }, write = "fff2", label = "Sperax walking pad", move = true },
  rsc = { service = "1814", notify = { "2a53" }, label = "Footpod", move = true },
  csc = { service = "1816", notify = { "2a5b" }, label = "Speed / cadence sensor" },
  hr = { service = "180d", notify = { "2a37" }, label = "Heart-rate strap" },
}
M.KINDS = KINDS
-- services to scan for / ask the browser for (full UUIDs)
M.SERVICES = { full("1826"), full("1816"), full("1814"), full("180d"), full("fff0") }

-- which kind a device is, from its service and characteristic UUIDs (any form) and its name
function M.detect(uuids, name)
  local has = {}
  for _, u in ipairs(uuids or {}) do has[short(u)] = true end
  local sperax_name = tostring(name or ""):upper():find("SPERAX") ~= nil
  if has["fff0"] and sperax_name then return "sperax" end
  if has["2ad2"] then return "ftms_bike" end
  if has["2acd"] then return "ftms_treadmill" end
  if has["1826"] and not has["2acd"] then return "ftms_bike" end -- services only: FTMS is a bike unless it says treadmill
  if has["2a53"] or has["1814"] then return "rsc" end
  if has["2a5b"] or has["1816"] then return "csc" end
  if has["fff1"] and has["fff2"] then return "sperax" end
  if has["2a37"] or has["180d"] then return "hr" end
  return nil
end

-- ---------- FTMS (bikes, treadmills) ----------
local FTMS = {}
FTMS.REQUEST_CONTROL, FTMS.RESET, FTMS.START, FTMS.STOP = { 0x00 }, { 0x01 }, { 0x07 }, { 0x08, 0x01 }
-- The machine answers each control point command (0x80, opcode, result). Commands go one at a time:
-- the next is sent when the answer comes, or after this long without one (as qdomyos-zwift does).
FTMS.ANSWER_WAIT = 0.3
function FTMS.simulation(grade) -- grade %, wind 0, Crr 0.004, Cw 0.51
  local lo, hi = le16(floor(grade * 100 + 0.5))
  return { 0x11, 0x00, 0x00, lo, hi, 40, 51 }
end
function FTMS.target_speed(kmh) local lo, hi = le16(floor(kmh * 100 + 0.5)); return { 0x02, lo, hi } end
function FTMS.target_incline(pct) local lo, hi = le16(floor(pct * 10 + 0.5)); return { 0x03, lo, hi } end
function FTMS.bike(b)
  local f, i, d = u16(b, 1), 3, {}
  if not bit(f, 0) then d.speed_kmh = u16(b, i) / 100; i = i + 2 end
  if bit(f, 1) then d.avg_speed_kmh = u16(b, i) / 100; i = i + 2 end
  if bit(f, 2) then d.cadence = u16(b, i) / 2; i = i + 2 end
  if bit(f, 3) then d.avg_cadence = u16(b, i) / 2; i = i + 2 end
  if bit(f, 4) then d.distance_m = u16(b, i) + (b[i + 2] or 0) * 65536; i = i + 3 end
  if bit(f, 5) then d.resistance = s16(b, i); i = i + 2 end
  if bit(f, 6) then d.power = s16(b, i); i = i + 2 end
  if bit(f, 7) then i = i + 2 end
  if bit(f, 8) then d.kcal = u16(b, i); i = i + 5 end
  if bit(f, 9) then d.hr = b[i]; i = i + 1 end
  return d
end
function FTMS.treadmill(b)
  local f, i, d = u16(b, 1), 3, {}
  if not bit(f, 0) then d.speed_kmh = u16(b, i) / 100; i = i + 2 end
  if bit(f, 1) then d.avg_speed_kmh = u16(b, i) / 100; i = i + 2 end
  if bit(f, 2) then d.distance_m = u16(b, i) + (b[i + 2] or 0) * 65536; i = i + 3 end
  if bit(f, 3) then d.incline = s16(b, i) / 10; i = i + 4 end
  if bit(f, 4) then i = i + 4 end
  if bit(f, 5) then i = i + 1 end
  if bit(f, 6) then i = i + 1 end
  if bit(f, 7) then d.kcal = u16(b, i); i = i + 5 end
  if bit(f, 8) then d.hr = b[i]; i = i + 1 end
  return d
end
M.FTMS = FTMS

-- ---------- Sperax walking pads (UART over BLE, framed: F5 len 00 payload crcLo crcHi FA) ----------
-- Protocol from github.com/Guhan-SenSam/sperax-walkpad (MIT), checked on a SPERAX_RM01.
local SPX = {}
function SPX.crc(b, i, j)
  local crc = 0xFFFF
  for k = i, j do
    crc = bxor(crc, b[k])
    for _ = 1, 8 do
      if crc % 2 == 1 then crc = bxor(floor(crc / 2), 0xA327) else crc = floor(crc / 2) end
    end
  end
  return crc % 256, floor(crc / 256)
end
function SPX.encode(payload)
  local f = { 0xF5, #payload + 6, 0x00 }
  for _, v in ipairs(payload) do f[#f + 1] = v end
  local lo, hi = SPX.crc(f, 1, #f)
  f[#f + 1], f[#f + 2], f[#f + 3] = lo, hi, 0xFA
  local e = { f[1], 0, f[3] } -- escape inner 0xFn as F0 0n; the length counts escaped bytes
  for i = 4, #f - 1 do
    if f[i] >= 0xF0 then e[#e + 1] = 0xF0; e[#e + 1] = f[i] - 0xF0 else e[#e + 1] = f[i] end
  end
  e[#e + 1] = 0xFA
  e[2] = #e
  return e
end
SPX.STATUS = SPX.encode({ 0x19 })
function SPX.speed(kmh) return SPX.encode({ 0x15, 0x01, floor(kmh * 10 + 0.5), 0x00 }) end
SPX.BELT_STOP = SPX.encode({ 0x15, 0x00, 0x00, 0x00 })
SPX.STATES = { [0x00] = "idle", [0x13] = "countdown", [0x12] = "countdown", [0x11] = "countdown", [0x10] = "running",
  [0x0F] = "slowing", [0x01] = "paused", [0x02] = "stopped", [0x50] = "vibrating" }
-- reassemble frames from notifications (a frame can be split, or several in one)
function SPX.feed(r, chunk)
  for _, v in ipairs(chunk) do r[#r + 1] = v end
  local frames = {}
  while true do
    local s
    for i = 1, #r do if r[i] == 0xF5 then s = i break end end
    if not s then for i = #r, 1, -1 do r[i] = nil end break end
    local e
    for i = s + 1, #r do if r[i] == 0xFA then e = i break end end
    if not e then
      if #r > 1024 then for i = #r, 1, -1 do r[i] = nil end end
      break
    end
    local raw = {}
    for i = s, e do raw[#raw + 1] = r[i] end
    local rest = {}
    for i = e + 1, #r do rest[#rest + 1] = r[i] end
    for i = #r, 1, -1 do r[i] = nil end
    for i = 1, #rest do r[i] = rest[i] end
    -- some pads put 1-3 junk bytes after F5: find the byte that matches the length
    if raw[2] ~= #raw then
      for j = 3, math.min(5, #raw - 5) do
        if raw[j] == #raw - (j - 2) then
          local fixed = { 0xF5 }
          for i = j, #raw do fixed[#fixed + 1] = raw[i] end
          raw = fixed
          break
        end
      end
    end
    local b, i = {}, 1
    while i <= #raw do
      if raw[i] == 0xF0 and i < #raw and raw[i + 1] <= 0x0F then b[#b + 1] = 0xF0 + raw[i + 1]; i = i + 2
      else b[#b + 1] = raw[i]; i = i + 1 end
    end
    if #b >= 7 then
      local len = b[2]
      b[2] = #b
      local lo, hi = SPX.crc(b, 1, #b - 3)
      b[2] = len
      frames[#frames + 1] = { b = b, cmd = b[4], ok = lo == b[#b - 2] and hi == b[#b - 1] }
    end
  end
  return frames
end
function SPX.status(b)
  if b[4] ~= 0x19 or #b < 21 then return nil end
  local function be(i) return (b[i] or 0) * 256 + (b[i + 1] or 0) end
  return { state = SPX.STATES[b[7]] or "unknown", seconds = be(10), distance_m = be(12) * 10, kcal = be(14),
           steps = be(16), speed_kmh = b[18] / 10 }
end
M.SPERAX = SPX

-- ---------- RSC footpods, CSC speed / cadence sensors, heart rate ----------
local function rsc(b)
  local f = b[1] or 0
  local d = { speed_kmh = u16(b, 2) / 256 * 3.6, cadence = b[4] or 0 }
  local i = 5
  if bit(f, 0) then i = i + 2 end
  if bit(f, 1) then d.distance_m = u32(b, i) / 10 end
  return d
end
local function heart_rate(b) if bit(b[1] or 0, 0) then return u16(b, 2) end return b[2] or 0 end

-- CSC: cumulative wheel / crank revolutions with the time of the last one (1/1024 s)
local function csc_feed(s, b, now)
  local f, i = b[1] or 0, 2
  if bit(f, 0) then
    s.wheel_seen = now
    local wr, wt = u32(b, i), u16(b, i + 4)
    if s.wr then
      local dr, dt = (wr - s.wr) % 4294967296, ((wt - s.wt) % 65536) / 1024
      if dr > 0 and dr < 100 and dt > 0 then
        local rps = dr / dt
        if rps < 40 then s.rps = (s.rps or 0) > 0 and (s.rps * 0.3 + rps * 0.7) or rps; s.wperiod = dt / dr end
        s.wheel_at = now
      end
    end
    s.wr, s.wt, i = wr, wt, i + 6
  end
  if bit(f, 1) then
    s.crank_seen = now
    local cr, ct = u16(b, i), u16(b, i + 2)
    if s.cr then
      local dr, dt = (cr - s.cr) % 65536, ((ct - s.ct) % 65536) / 1024
      if dr > 0 and dr < 20 and dt > 0 then
        local rpm = dr / dt * 60
        if rpm < 250 then s.rpm = (s.rpm or 0) > 0 and (s.rpm * 0.3 + rpm * 0.7) or rpm; s.cperiod = dt / dr end
        s.crank_at = now
      end
    end
    s.cr, s.ct = cr, ct
  end
end
local function csc_values(s, now, wheel_m)
  local d = {}
  local function going(at, period) return at ~= nil and now - at < math.max(1.2, math.min(3, (period or 1) * 2.2)) end
  if s.crank_seen and now - s.crank_seen < 5 then
    if not going(s.crank_at, s.cperiod) then s.rpm = 0 end
    d.cadence, d.moving = floor((s.rpm or 0) + 0.5), going(s.crank_at, s.cperiod)
  end
  if s.wheel_seen and now - s.wheel_seen < 5 then
    if not going(s.wheel_at, s.wperiod) then s.rps = 0 end
    d.speed_kmh = floor((s.rps or 0) * wheel_m * 3.6 * 10 + 0.5) / 10
    d.moving = d.moving or going(s.wheel_at, s.wperiod)
  end
  return d
end

-- walking speed on a slope, relative to the flat (Tobler's hiking function): fastest at -5 %
function M.walk_factor(grade_pct) return math.exp(-3.5 * (math.abs(grade_pct / 100 + 0.05) - 0.05)) end

-- ---------- a session: all the player's devices together ----------
local Session = {}
Session.__index = Session

local DEFAULTS = {
  wheel_mm = 2105,          -- speed sensor wheel circumference
  allow_hills = true,       -- send hills to bikes / tilting treadmills
  allow_belt = false,       -- let the game change a treadmill / walking pad's speed (off unless the player says so)
  max_belt_kmh = 4,         -- never above this
  belt_ramp = 0.5,          -- km/h per second
  gait = { walk = { pad_kmh = 1.0, rpm = 30 }, run = { pad_kmh = 3.5, rpm = 70 }, sprint = { pad_kmh = 5.0, watts = 200, rpm = 85 } },
}

-- opts: send(id, char_uuid, bytes) [required], on_event(name, value) and any DEFAULTS
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({ devices = {}, order = {}, t = 0, distance_m = 0, elapsed_s = 0,
    grade = nil, belt_target = nil, gait_now = "stopped", moving = false, bytes_out = opts.bytes_out }, Session)
  for k, v in pairs(DEFAULTS) do self[k] = v end
  for k, v in pairs(opts) do self[k] = v end
  assert(type(self.send) == "function", "OmniPlay.new needs send(id, char, bytes)")
  return self
end

local function write(self, d, bytes)
  local k = KINDS[d.kind]
  if not k.write then return end
  self.send(d.id, full(k.write), out(self, bytes))
end

-- FTMS control point: one command at a time (see FTMS.ANSWER_WAIT). A newer hill or speed
-- replaces one still waiting, so a busy machine always gets the latest, never a backlog.
local function pump(self, d)
  if d.busy or #d.q == 0 then return end
  local c = table.remove(d.q, 1)
  d.busy = 0
  write(self, d, c)
end
local function command(self, d, bytes)
  for i, c in ipairs(d.q) do
    if c[1] == bytes[1] and (bytes[1] == 0x11 or bytes[1] == 0x02 or bytes[1] == 0x03) then d.q[i] = bytes; return end
  end
  d.q[#d.q + 1] = bytes
  pump(self, d)
end

-- A device was connected and its services found. uuids: its service and/or characteristic UUIDs.
-- kind can be given to skip detection. Returns the kind, or nil if OmniPlay doesn't know it.
function Session:add(id, name, uuids, kind)
  kind = kind or M.detect(uuids, name)
  if not kind then return nil end
  if not self.devices[id] then self.order[#self.order + 1] = id end
  self.devices[id] = { id = id, name = name or kind, kind = kind, m = {}, seen = nil, rx = {}, csc = {}, steps = {},
    poll = 0, grade_t = 99, q = {} }
  return kind
end
-- characteristics to subscribe to (full UUIDs), and the service they are in
function Session:notify_chars(id)
  local d = self.devices[id]
  if not d then return {} end
  local t = {}
  for _, c in ipairs(KINDS[d.kind].notify) do t[#t + 1] = full(c) end
  return t, full(KINDS[d.kind].service)
end
function Session:write_char(id) local d = self.devices[id]; return d and KINDS[d.kind].write and full(KINDS[d.kind].write) end

-- subscriptions are on: start the machine
function Session:connected(id)
  local d = self.devices[id]
  if not d then return end
  d.connected, d.seen = true, self.t
  d.q, d.busy = {}, nil
  if d.kind == "ftms_bike" then
    -- take control, then start. No reset: on most machines it clears the console's workout
    -- (qdomyos-zwift only resets the few models that need it)
    command(self, d, FTMS.REQUEST_CONTROL); command(self, d, FTMS.START)
  elseif d.kind == "ftms_treadmill" then
    command(self, d, FTMS.REQUEST_CONTROL)
  end
  d.sent_grade, d.belt_cmd = nil, nil
end

-- the device is gone (disconnected, out of range). Your adapter reconnects and calls add/connected again.
function Session:remove(id)
  local d = self.devices[id]
  if not d then return end
  if d.connected and d.kind == "sperax" and d.belt_cmd then write(self, d, SPX.BELT_STOP) end
  if d.connected and d.kind:find("^ftms") then write(self, d, FTMS.STOP) end
  self.devices[id] = nil
  for i, x in ipairs(self.order) do if x == id then table.remove(self.order, i) break end end
end

-- a notification arrived
function Session:receive(id, char, bytes)
  local d = self.devices[id]
  if not d then return end
  local b, c, m, now = to_array(bytes), short(char), d.m, self.t
  if d.kind == "ftms_bike" or d.kind == "ftms_treadmill" then
    if c == "2ad2" or c == "2acd" then
      d.seen = now
      local x = d.kind == "ftms_bike" and FTMS.bike(b) or FTMS.treadmill(b)
      for k, v in pairs(x) do m[k] = v end
      -- machines that only send averages: use those
      if x.speed_kmh == nil and x.avg_speed_kmh ~= nil and not m.has_speed then m.speed_kmh = x.avg_speed_kmh end
      if x.cadence == nil and x.avg_cadence ~= nil and not m.has_cadence then m.cadence = x.avg_cadence end
      if x.speed_kmh ~= nil then m.has_speed = true end
      if x.cadence ~= nil then m.has_cadence = true end
      if d.kind == "ftms_bike" then m.moving = (m.cadence or 0) > 5 or (m.power or 0) > 0 else m.moving = (m.speed_kmh or 0) > 0.3 end
      if d.belt_cmd and x.speed_kmh and math.abs(x.speed_kmh - d.belt_cmd) < 0.15 then d.reached = true end
    elseif c == "2ad9" and b[1] == 0x80 then
      d.busy = nil; pump(self, d) -- the answer to our last command: send the next
    elseif c == "2ada" and b[1] == 0xFF then
      command(self, d, FTMS.REQUEST_CONTROL) -- control permission lost
    end
  elseif d.kind == "sperax" then
    for _, f in ipairs(SPX.feed(d.rx, b)) do
      local s = f.ok and SPX.status(f.b)
      if s then
        d.seen = now
        m.speed_kmh, m.steps, m.state = s.speed_kmh, s.steps, s.state
        if d.belt_cmd and math.abs(s.speed_kmh - d.belt_cmd) < 0.15 then d.reached = true end
        local h = d.steps
        h[#h + 1] = { t = now, n = s.steps }
        while #h > 1 and now - h[1].t > 3 do table.remove(h, 1) end
        m.cadence = (#h >= 2 and h[#h].t - h[1].t > 0.5) and (h[#h].n - h[1].n) / (h[#h].t - h[1].t) * 60 or 0
        m.moving = s.state == "running" and s.speed_kmh > 0
      end
    end
  elseif d.kind == "rsc" then
    d.seen = now
    local x = rsc(b)
    m.speed_kmh, m.cadence, m.distance_m = x.speed_kmh, x.cadence, x.distance_m
    m.moving = x.speed_kmh > 0.3 or x.cadence > 20
  elseif d.kind == "csc" then
    d.seen = now
    csc_feed(d.csc, b, now)
  elseif d.kind == "hr" then
    d.seen = now
    m.hr = heart_rate(b)
  end
end

local function first(self, pred)
  for _, id in ipairs(self.order) do
    local d = self.devices[id]
    if d.connected and pred(d) then return d end
  end
end
local function fresh(self, d) return d and d.seen and self.t - d.seen < ((d.kind == "csc" or d.kind == "hr" or d.kind == "rsc") and 30 or 6) end

local function gait_for(self, v)
  if not v.moving then return "stopped" end
  local walking = v.kind == "sperax" or v.kind == "ftms_treadmill" or v.kind == "rsc"
  local function reached(st)
    if not st then return false end
    if walking then return st.pad_kmh ~= nil and (v.speed_kmh or 0) >= st.pad_kmh end
    if st.watts and v.power and v.power >= st.watts then return true end
    local cad = v.cadence or ((v.speed_kmh or 0) * 3) -- speed sensor only: ~3 km/h per rpm
    return st.rpm ~= nil and cad >= st.rpm
  end
  local g = self.gait
  return reached(g.sprint) and "sprint" or reached(g.run) and "run" or "walk"
end

-- call every frame (or at least 10 times a second) with the seconds since the last call
function Session:update(dt)
  self.t = self.t + dt
  local now = self.t
  for _, id in ipairs(self.order) do
    local d = self.devices[id]
    if d.connected then
      d.grade_t = d.grade_t + dt
      if d.kind == "sperax" then
        d.poll = d.poll + dt
        if d.poll >= 0.25 then d.poll = 0; write(self, d, SPX.STATUS) end -- the pad only answers when asked
      elseif d.busy then
        d.busy = d.busy + dt
        if d.busy >= FTMS.ANSWER_WAIT then d.busy = nil; pump(self, d) end
      elseif d.kind == "csc" then
        local x = csc_values(d.csc, now, self.wheel_mm / 1000)
        d.m = x
      end
    end
  end
  -- hills
  local bike = first(self, function(d) return d.kind == "ftms_bike" end)
  local tread = first(self, function(d) return d.kind == "ftms_treadmill" and d.m.incline ~= nil end)
  local g = self.allow_hills and self.grade or 0
  if bike and (bike.sent_grade == nil or math.abs(g - bike.sent_grade) >= 0.1) and bike.grade_t >= 0.25 then
    command(self, bike, FTMS.simulation(g)); bike.sent_grade, bike.grade_t = g, 0
  end
  if tread and (tread.sent_grade == nil or math.abs(g - tread.sent_grade) >= 0.5) and tread.grade_t >= 2 then
    command(self, tread, FTMS.target_incline(clamp(g, -6, 15))); tread.sent_grade, tread.grade_t = g, 0
  end
  -- belt speed, ramped, one command a second, waits for the belt and resends if it was ignored
  local pad = first(self, function(d) return d.kind == "sperax" or d.kind == "ftms_treadmill" end)
  if pad and self.allow_belt and self.belt_target then
    pad.belt_t = (pad.belt_t or 0) + dt
    local ready = pad.kind == "ftms_treadmill" or pad.m.state == "running" -- a Sperax ignores commands unless running
    if not ready then pad.belt_cmd, pad.belt_t = nil, 0
    elseif pad.belt_t >= 1 then
      local lo = pad.kind == "sperax" and 1.0 or 0.5
      local target = clamp(self.belt_target, lo, self.max_belt_kmh)
      local cur = pad.belt_cmd or math.max(lo, pad.m.speed_kmh or 0)
      local step = self.belt_ramp * pad.belt_t
      local nxt = target > cur and math.min(target, cur + step) or math.max(target, cur - step)
      pad.belt_t = 0
      local behind = pad.belt_cmd and not pad.reached and math.abs((pad.m.speed_kmh or 0) - pad.belt_cmd) > 0.3
      if behind then nxt = pad.belt_cmd end
      local resend = behind and now - (pad.cmd_t or 0) > 3
      if resend and (pad.resends or 0) >= 3 then -- ignored three times: carry on from the real speed
        pad.belt_cmd, pad.reached, pad.resends, resend = math.max(lo, pad.m.speed_kmh or 0), true, 0, false
      end
      if not pad.belt_cmd or math.abs(nxt - pad.belt_cmd) >= 0.1 or resend then
        pad.resends = resend and (pad.resends or 0) + 1 or 0
        if pad.belt_cmd ~= nxt then pad.reached = false end
        if pad.kind == "sperax" then write(self, pad, SPX.speed(nxt)) else command(self, pad, FTMS.target_speed(nxt)) end
        pad.belt_cmd, pad.cmd_t = nxt, now
        if math.abs((pad.m.speed_kmh or 0) - nxt) < 0.15 then pad.reached = true end
      end
    end
  end
  -- combine and track
  local v = self:values()
  if v.moving then self.distance_m = self.distance_m + (v.speed_kmh or 0) / 3.6 * dt; self.elapsed_s = self.elapsed_s + dt end
  if v.moving ~= self.moving then self.moving = v.moving; if self.on_event then self.on_event(v.moving and "start" or "stop") end end
  if v.gait ~= self.gait_now then self.gait_now = v.gait; if self.on_event then self.on_event("gait", v.gait) end end
end

-- The player's numbers, combined from all devices. Unknown values are nil.
--   speed_kmh, cadence (rpm on a bike, steps/min walking), power (W), hr (bpm), steps, moving,
--   gait ("stopped"/"walk"/"run"/"sprint"), kind (movement device kind), grade (hill sent),
--   distance_m, elapsed_s (while moving), devices = { {id, name, kind, fresh} }, sources = {speed=..., ...}
function Session:values()
  local mv = first(self, function(d) return KINDS[d.kind].move and fresh(self, d) end)
  local v, src = { sources = {} }, nil
  src = v.sources
  if mv then
    v.kind = mv.kind
    v.speed_kmh, v.cadence, v.power, v.hr, v.steps, v.moving = mv.m.speed_kmh, mv.m.cadence, mv.m.power, mv.m.hr, mv.m.steps, mv.m.moving
    src.speed, src.cadence, src.power, src.moving = mv.id, mv.id, mv.m.power and mv.id or nil, mv.id
    if v.hr then src.hr = mv.id end
  end
  local s = first(self, function(d) return d.kind == "csc" and fresh(self, d) end)
  if s then -- a sensor is quicker than any console: it decides speed / cadence / moving
    if s.m.cadence then v.cadence, src.cadence = s.m.cadence, s.id end
    if s.m.speed_kmh then v.speed_kmh, src.speed = s.m.speed_kmh, s.id end
    if s.m.moving ~= nil then v.moving, src.moving = s.m.moving, s.id end
    v.kind = v.kind or "csc"
  end
  local h = first(self, function(d) return d.kind == "hr" and fresh(self, d) and (d.m.hr or 0) > 0 end)
  if h then v.hr, src.hr = h.m.hr, h.id end
  v.moving = v.moving or false
  v.gait = gait_for(self, v)
  v.grade = self.allow_hills and self.grade or nil
  v.distance_m, v.elapsed_s = self.distance_m, self.elapsed_s
  v.devices = {}
  for _, id in ipairs(self.order) do
    local d = self.devices[id]
    v.devices[#v.devices + 1] = { id = id, name = d.name, kind = d.kind, label = KINDS[d.kind].label, fresh = fresh(self, d) or false }
  end
  return v
end

-- hill in % (-10..20), nil = flat. Goes to a bike as resistance, to a treadmill as incline.
function Session:set_grade(pct) self.grade = pct and clamp(pct, -10, 20) or nil end
-- treadmill / walking pad speed in km/h, nil = leave it. Needs allow_belt, never above max_belt_kmh.
function Session:set_belt_speed(kmh) self.belt_target = kmh end

return M
