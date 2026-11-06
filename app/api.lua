-- Mod API: lets games read live data and send hills / belt speed back.
--   * WebSocket + plain HTTP on 127.0.0.1:21890 (browsers are refused: no Origin header allowed)
--   * File bridge for Garry's Mod: OmniPlay writes garrysmod/data/omniplay/live.txt,
--     the game writes garrysmod/data/omniplay/cmd.txt
-- Every message from a game is a JSON object with any of these fields:
--   game (name), grade (%), belt_speed (km/h), take_input (true = OmniPlay stops pressing keys)
local ffi = require("ffi")
local bit = require("bit")
local json = require("json")

local M = {
  port = 21890, games = {}, gmod_dir = nil, listening = false, status = "off",
  grade_target = nil, grade = nil, log = function() end,
}
M.now = function() return love.timer.getTime() end

local IS_WIN = ffi.os == "Windows"
if IS_WIN then
  pcall(ffi.cdef, [[
    long RegGetValueA(void *hkey, const char *sub, const char *val, unsigned long flags, unsigned long *type, void *data, unsigned long *size);
    int MoveFileExA(const char *from, const char *to, unsigned long flags);
    int CreateDirectoryA(const char *path, void *sa);
  ]])
end

-- ---------- sha1 + base64 (for the WebSocket handshake) ----------
local function sha1(msg)
  local band, bor, bxor, bnot, rol = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local ml = #msg * 8
  msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64)
  for i = 7, 0, -1 do msg = msg .. string.char(math.floor(ml / 2 ^ (i * 8)) % 256) end
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
    end
    for i = 16, 79 do w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1) end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else f, k = bxor(b, c, d), 0xCA62C1D6 end
      local t = rol(a, 5) + f + e + k + w[i]
      e, d, c, b, a = d, c, rol(b, 30), a, bit.tobit(t)
    end
    h0, h1, h2, h3, h4 = bit.tobit(h0 + a), bit.tobit(h1 + b), bit.tobit(h2 + c), bit.tobit(h3 + d), bit.tobit(h4 + e)
  end
  local out = {}
  for _, h in ipairs({ h0, h1, h2, h3, h4 }) do
    for i = 3, 0, -1 do out[#out + 1] = string.char(band(bit.rshift(h, i * 8), 0xFF)) end
  end
  return table.concat(out)
end
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
    out[#out + 1] = B64:sub(q[1] + 1, q[1] + 1) .. B64:sub(q[2] + 1, q[2] + 1)
      .. (b and B64:sub(q[3] + 1, q[3] + 1) or "=") .. (c and B64:sub(q[4] + 1, q[4] + 1) or "=")
  end
  return table.concat(out)
end
M._sha1, M._base64 = sha1, base64
local function accept_key(key) return base64(sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")) end
M._accept_key = accept_key

-- ---------- finding Garry's Mod ----------
local function read_file(p) local f = io.open(p, "rb"); if not f then return nil end local d = f:read("*a"); f:close(); return d end

function M.find_gmod()
  if not IS_WIN then return nil end
  local buf, size = ffi.new("char[1024]"), ffi.new("unsigned long[1]", 1024)
  local HKCU = ffi.cast("void *", ffi.cast("intptr_t", 0x80000001))
  if ffi.C.RegGetValueA(HKCU, "Software\\Valve\\Steam", "SteamPath", 2, nil, buf, size) ~= 0 then return nil end
  local steam = ffi.string(buf):gsub("/", "\\")
  local libs = { steam }
  local vdf = read_file(steam .. "\\steamapps\\libraryfolders.vdf") or ""
  for p in vdf:gmatch('"path"%s+"([^"]+)"') do libs[#libs + 1] = (p:gsub("\\\\", "\\")) end
  for _, lib in ipairs(libs) do
    local gm = lib .. "\\steamapps\\common\\GarrysMod\\garrysmod"
    if read_file(lib .. "\\steamapps\\appmanifest_4000.acf") or read_file(gm .. "\\steam.inf") then
      return gm .. "\\data"
    end
  end
  return nil
end

local function mkdir(p) if IS_WIN then ffi.C.CreateDirectoryA(p, nil) end end

local function write_atomic(path, data)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(data); f:close()
  if IS_WIN then return ffi.C.MoveFileExA(tmp, path, 1) ~= 0 end
  return os.rename(tmp, path)
end

-- ---------- games ----------
local function game(id, via)
  local g = M.games[id]
  if not g then
    g = { id = id, via = via, name = nil, seen = M.now() }
    M.games[id] = g
  end
  return g
end

local function apply(g, msg)
  if type(msg) ~= "table" then return end
  g.seen = M.now()
  local name = msg.game or msg.name
  if type(name) == "string" and name ~= "" and name ~= g.name then
    g.name = name:sub(1, 60)
    M.log("info", "game connected: " .. g.name)
  end
  if type(msg.info) == "string" and msg.info ~= g.info then
    g.info = msg.info:sub(1, 300)
    M.log("info", (g.name or "game") .. ": " .. g.info)
  end
  local grade = msg.grade
  if msg.type == "grade" then grade = msg.pct or msg.grade end
  if type(grade) == "number" and grade == grade then g.grade, g.grade_t = grade, M.now() end
  if grade == false then g.grade = nil end
  local belt = msg.belt_speed
  if msg.type == "belt_speed" then belt = msg.kmh or msg.belt_speed end
  if type(belt) == "number" and belt == belt then g.belt = belt end
  local ti = msg.take_input
  if msg.type == "take_input" then ti = msg.on end
  if type(ti) == "boolean" and ti ~= (g.take_input or false) then
    g.take_input = ti
    M.log("info", (g.name or "a game") .. (ti and " reads your movement directly (keys paused)" or " gave input back to the keys"))
  end
end

local function drop(id, why)
  local g = M.games[id]
  if not g then return end
  M.games[id] = nil
  if g.name then M.log("info", "game disconnected: " .. g.name .. (why and (" (" .. why .. ")") or "")) end
end

-- The game that controls the machine: newest grade / belt request wins.
function M.active()
  local best
  for _, g in pairs(M.games) do
    if g.name or g.grade or g.take_input then
      if not best or (g.grade_t or g.seen) > (best.grade_t or best.seen) then best = g end
    end
  end
  return best
end
function M.take_input() for _, g in pairs(M.games) do if g.take_input then return true end end return false end
function M.game_name() local g = M.active(); return g and g.name end

-- ---------- WebSocket / HTTP server ----------
local socket, server
local clients = {}
local next_id = 0

local function ws_frame(op, payload)
  local n, hdr = #payload, string.char(0x80 + op)
  if n < 126 then hdr = hdr .. string.char(n)
  elseif n < 65536 then hdr = hdr .. string.char(126, math.floor(n / 256), n % 256)
  else
    hdr = hdr .. string.char(127, 0, 0, 0, 0, math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  return hdr .. payload
end
M._ws_frame = ws_frame

local function csend(c, data) c.out = c.out .. data end

local function close_client(c, why)
  c.dead = true
  pcall(function() c.sock:close() end)
  drop(c.id, why)
end

local function handle_http(c)
  local head = c.buf:match("^(.-)\r\n\r\n")
  if not head then
    if #c.buf > 8192 then close_client(c, "bad request") end
    return
  end
  c.buf = c.buf:sub(#head + 5)
  local method, path = head:match("^(%u+) (%S+)")
  local h = {}
  for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do h[k:lower()] = v end
  -- web pages: never let websites talk to your machine. Garry's Mod's own menu browser
  -- (asset://garrysmod) is the only page origin allowed.
  if h.origin and not h.origin:lower():match("^asset://garrysmod") then
    M.log("err", "refused a connection from a web page (" .. h.origin:sub(1, 80) .. ")")
    csend(c, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    c.close_after = true
    return
  end
  c.origin = h.origin
  if method == "GET" and (h.upgrade or ""):lower() == "websocket" and h["sec-websocket-key"] then
    csend(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
      .. accept_key(h["sec-websocket-key"]) .. "\r\n\r\n")
    c.ws = true
    game(c.id, "websocket")
    M.log("info", "WebSocket client connected" .. (c.origin and (" from " .. c.origin) or ""))
    if M.last_state then csend(c, ws_frame(1, M.last_state)) end
    return
  end
  local body, code = nil, "404 Not Found"
  if method == "GET" and path == "/state" then body, code = M.last_state or "{}", "200 OK" end
  body = body or ""
  csend(c, "HTTP/1.1 " .. code .. "\r\nContent-Type: application/json\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
  c.close_after = true
end

local function handle_ws(c)
  while #c.buf >= 2 do
    local b1, b2 = c.buf:byte(1, 2)
    local fin, op = bit.band(b1, 0x80) ~= 0, bit.band(b1, 0x0F)
    local masked, n, i = bit.band(b2, 0x80) ~= 0, bit.band(b2, 0x7F), 3
    if n == 126 then
      if #c.buf < 4 then return end
      n, i = c.buf:byte(3) * 256 + c.buf:byte(4), 5
    elseif n == 127 then
      if #c.buf < 10 then return end
      n = 0
      for k = 3, 10 do n = n * 256 + c.buf:byte(k) end
      i = 11
    end
    if n > 65536 then close_client(c, "message too big") return end
    local mask
    if masked then
      if #c.buf < i + 3 then return end
      mask = { c.buf:byte(i, i + 3) }
      i = i + 4
    end
    if #c.buf < i + n - 1 then return end
    local payload = c.buf:sub(i, i + n - 1)
    c.buf = c.buf:sub(i + n)
    if mask then
      local t = {}
      for k = 1, n do t[k] = string.char(bit.bxor(payload:byte(k), mask[(k - 1) % 4 + 1])) end
      payload = table.concat(t)
    end
    if op == 8 then csend(c, ws_frame(8, "")); c.close_after = true; drop(c.id, "closed") return
    elseif op == 9 then csend(c, ws_frame(10, payload))
    elseif op == 1 or op == 0 then
      c.frag = (c.frag or "") .. payload
      if fin then
        local msg = json.decode(c.frag)
        c.frag = nil
        if msg then apply(game(c.id, "websocket"), msg) end
      end
    end
  end
end

local function serve()
  if not server then return end
  while true do
    local s = server:accept()
    if not s then break end
    s:settimeout(0)
    next_id = next_id + 1
    clients[#clients + 1] = { sock = s, buf = "", out = "", id = "ws" .. next_id }
    if #clients > 16 then close_client(table.remove(clients, 1), "too many clients") end
  end
  for _, c in ipairs(clients) do
    if not c.dead then
      local d, e, p = c.sock:receive(8192)
      local chunk = d or p
      if chunk and #chunk > 0 then c.buf = c.buf .. chunk end
      if e == "closed" then close_client(c, "closed")
      else
        if c.ws then handle_ws(c) else handle_http(c) end
      end
    end
    if not c.dead and #c.out > 0 then
      local i, e, j = c.sock:send(c.out)
      local sent = i or j or 0
      c.out = c.out:sub(sent + 1)
      if e == "closed" then close_client(c, "closed") end
    end
    if not c.dead and c.close_after and #c.out == 0 then close_client(c) end
  end
  for i = #clients, 1, -1 do if clients[i].dead then table.remove(clients, i) end end
end

-- ---------- file bridge ----------
local file_t, last_beat = 0, nil
-- latency measurement: when each state was written, and when the game says it saw it
local sent_at, rtt, data_gaps = {}, {}, {}
M.stats = { rtt = rtt, gaps = data_gaps }
local function file_bridge(state_json, seq_now)
  local dir = M.gmod_dir and (M.gmod_dir .. "/omniplay")
  if not dir then return end
  if not M.dir_made then mkdir(M.gmod_dir); mkdir(dir); M.dir_made = true end
  write_atomic(dir .. "/live.txt", state_json)
  sent_at[seq_now] = M.now()
  sent_at[seq_now - 400] = nil
  local raw = read_file(dir .. "/cmd.txt")
  local msg = raw and json.decode(raw)
  if msg and type(msg.ack) == "number" and msg.ack ~= M.last_ack then
    M.last_ack = msg.ack
    if sent_at[msg.ack] then rtt[#rtt + 1] = M.now() - sent_at[msg.ack] end
  end
  if msg and msg.beat ~= nil and msg.beat ~= last_beat then
    local first = last_beat == nil
    last_beat = msg.beat
    if first then return end -- left over from an earlier run; wait for the next heartbeat
    apply(game("gmod", "file bridge"), msg)
  end
end

-- ---------- lifecycle ----------
function M.init(log_fn, opts)
  opts = opts or {}
  M.log = log_fn or M.log
  M.port = opts.port or M.port
  M.gmod_dir = opts.gmod_dir or M.find_gmod()
  if M.gmod_dir then M.log("info", "Garry's Mod bridge: " .. M.gmod_dir .. (IS_WIN and "\\omniplay" or "/omniplay")) end
  local ok, s = pcall(require, "socket")
  if not ok then M.status = "no socket library"; return end
  socket = s
  local srv, err = socket.bind("127.0.0.1", M.port)
  if not srv then
    M.status = "port " .. M.port .. " busy (" .. tostring(err) .. ")"
    M.log("err", "mod API: " .. M.status)
    return
  end
  srv:settimeout(0)
  server, M.listening, M.status = srv, true, "ws://127.0.0.1:" .. M.port
end

local seq, tick_t = 0, 0
local GAITS = { stopped = "stopped", walk = "walk", run = "run", sprint = "sprint" }
local TYPES = { ftms_bike = "bike", ftms_treadmill = "treadmill", sperax = "treadmill", rsc = "footpod" }

-- m: live metrics; dev: active device; devstate: devices.state; ctl: devices module (set_grade, set_belt_speed)
function M.update(dt, m, dev, devstate, ctl, extra)
  serve()
  extra = extra or {}
  -- expire file-bridge games that stopped writing
  local g = M.games.gmod
  if g and M.now() - g.seen > 3 then drop("gmod", "stopped") end

  -- hills: ramp toward the active game's grade (4 %/s), back to 0 when games leave
  local a = M.active()
  local target = a and a.grade
  if target then target = math.max(-10, math.min(20, target)) end
  M.grade_target = target
  if target or (M.grade and M.grade ~= 0) then
    local want = target or 0
    local cur = M.grade or 0
    local step = 6 * dt
    cur = want > cur and math.min(want, cur + step) or math.max(want, cur - step)
    M.grade = cur
    if ctl and ctl.set_grade then ctl.set_grade(cur) end
    if not target and cur == 0 then M.grade = nil end
  end
  if a and a.belt and a.belt ~= M.belt_sent and ctl and ctl.set_belt_speed then
    if ctl.set_belt_speed(a.belt) then M.belt_sent = a.belt end
  end

  -- how often the device itself sends new numbers
  m = m or {}
  local key = tostring(m.power) .. ":" .. tostring(m.cadence) .. ":" .. tostring(m.speed_kmh)
  if key ~= M.last_key then
    if M.last_key_t then data_gaps[#data_gaps + 1] = M.now() - M.last_key_t end
    M.last_key, M.last_key_t = key, M.now()
  end
  M.report_t = (M.report_t or 0) + dt
  M.frames = (M.frames or 0) + 1
  if M.report_t >= 15 and (#rtt > 0 or #data_gaps > 2) then
    M.report_t = 0
    local function stat(t) local s, mx = 0, 0 for _, v in ipairs(t) do s = s + v; mx = math.max(mx, v) end return s / #t * 1000, mx * 1000 end
    local parts = {}
    if #rtt > 0 then local a, mx = stat(rtt) parts[#parts + 1] = string.format("game bridge round trip avg %d ms, max %d ms", a, mx) end
    if #data_gaps > 2 then local a, mx = stat(data_gaps) parts[#parts + 1] = string.format("device sends new numbers every %d ms (max %d)", a, mx) end
    local dv = package.loaded.devices
    if dv and dv.pkts then
      parts[#parts + 1] = string.format("%d data packets in 15 s, last: %s", dv.pkts, dv.last_hex or "-")
      dv.pkts = 0
    end
    parts[#parts + 1] = string.format("OmniPlay running at %d fps", M.frames / 15)
    M.frames = 0
    M.log("info", "latency: " .. table.concat(parts, "; "))
    for i = #rtt, 1, -1 do rtt[i] = nil end
    for i = #data_gaps, 1, -1 do data_gaps[i] = nil end
  end

  tick_t = tick_t + dt
  if tick_t < 0.05 then return end
  tick_t = 0
  seq = seq + 1
  local st = {
    type = "state", v = 1, seq = seq, app = "OmniPlay",
    connected = devstate == "connected",
    device = dev and { name = dev.name, kind = TYPES[dev.kind] or dev.kind, hills = dev.allow_hills ~= false and dev.kind == "ftms_bike",
      belt_speed = dev.allow_speed == true, max_speed = dev.allow_speed and dev.max_speed or nil } or nil,
    speed_kmh = m.speed_kmh or 0, cadence = m.cadence or 0, power = m.power, hr = (m.hr and m.hr > 0) and m.hr or nil,
    steps = m.steps, moving = m.moving == true, gait = GAITS[extra.gait] or "stopped",
    grade = m.grade, recording = extra.recording, distance_m = extra.distance_m, elapsed_s = extra.elapsed_s,
  }
  M.last_state = json.encode(st)
  local frame = ws_frame(1, M.last_state)
  for _, c in ipairs(clients) do if c.ws and not c.dead then csend(c, frame) end end
  file_bridge(M.last_state, seq)
end

function M.count()
  local n = 0
  for _, g in pairs(M.games) do if g.name then n = n + 1 end end
  return n
end

function M.shutdown()
  if M.gmod_dir then write_atomic(M.gmod_dir .. "/omniplay/live.txt", json.encode({ type = "state", v = 1, app = "OmniPlay", closed = true, seq = seq + 1 })) end
  for _, c in ipairs(clients) do pcall(function() c.sock:close() end) end
  clients = {}
  if server then server:close(); server = nil end
  M.listening = false
end

return M
