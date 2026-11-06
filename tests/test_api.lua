-- Mod API: WebSocket handshake + framing, HTTP /state, browser refusal, GMod file bridge,
-- hill ramping and the user's permission switch.
package.path = "app/?.lua;" .. package.path
local socket = require("socket")
local bit = require("bit")
local clock = 0
love = { timer = { getTime = function() return clock end } }
local api = require("api")
local json = require("json")

-- known vectors
assert(api._base64(api._sha1("abc")) == "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=", api._base64(api._sha1("abc")))
assert(api._accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 example")
local t = json.decode('{"a":[1,2.5,"x\\n"],"b":true,"c":null}')
assert(t.a[2] == 2.5 and t.a[3] == "x\n" and t.b == true and t.c == nil)
assert(json.decode(json.encode({ grade = 4.25, name = "PhysPlay" })).grade == 4.25)

os.execute("rm -rf /tmp/omni-api && mkdir -p /tmp/omni-api/omniplay")
local logs = {}
api.init(function(k, s) logs[#logs + 1] = s end, { port = 21891, gmod_dir = "/tmp/omni-api" })
assert(api.listening, api.status)

-- fake device control
local dev = { name = "EM 8000", kind = "ftms_bike", allow_hills = true }
local sent_grades = {}
local ctl = {
  set_grade = function(p) if dev.allow_hills == false then return false end sent_grades[#sent_grades + 1] = p; return true end,
  set_belt_speed = function() return false end,
}
local m = { speed_kmh = 25.6, cadence = 61, power = 140, hr = 130, moving = true }
local function tick(s) for _ = 1, math.floor(s / 0.05) do clock = clock + 0.05; api.update(0.05, m, dev, "connected", ctl, { gait = "run" }) end end

local function connect(origin)
  local c = assert(socket.connect("127.0.0.1", 21891))
  c:settimeout(0)
  c:send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    .. (origin and ("Origin: " .. origin .. "\r\n") or "") .. "Sec-WebSocket-Version: 13\r\n\r\n")
  return c
end
local function recv_all(c)
  local out = ""
  for _ = 1, 20 do
    tick(0.05)
    local d, e, p = c:receive(65536)
    out = out .. (d or p or "")
  end
  return out
end
local function masked(text)
  local mask = { 1, 2, 3, 4 }
  local t = {}
  for i = 1, #text do t[i] = string.char(bit.bxor(text:byte(i), mask[(i - 1) % 4 + 1])) end
  return string.char(0x81, 0x80 + #text) .. string.char(1, 2, 3, 4) .. table.concat(t)
end

-- browsers are refused
local evil = connect("https://example.com")
local r = recv_all(evil)
assert(r:find("403"), "browser origin should get 403: " .. r)

-- a real client
local c = connect(nil)
r = recv_all(c)
assert(r:find("101 Switching Protocols") and r:find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", 1, true), "handshake failed: " .. r)
local body = r:match("\r\n\r\n(.*)$")
local b2 = body:byte(2)
local n = bit.band(b2, 0x7F)
local off = 3
if n == 126 then n = body:byte(3) * 256 + body:byte(4); off = 5 end
local st = json.decode(body:sub(off, off + n - 1))
assert(st and st.type == "state" and st.speed_kmh == 25.6 and st.power == 140 and st.gait == "run" and st.device.kind == "bike",
  "bad state frame")

-- game says hello and asks for a hill
c:send(masked('{"game":"PhysPlay","grade":6,"take_input":true}'))
tick(1)
assert(api.game_name() == "PhysPlay" and api.take_input(), "game should be registered")
assert(math.abs(api.grade - 6) < 0.31, "grade should ramp at 6 %/s, is " .. tostring(api.grade))
tick(1)
assert(api.grade == 6 and sent_grades[#sent_grades] == 6, "grade should reach 6")

-- HTTP /state
local h = assert(socket.connect("127.0.0.1", 21891)); h:settimeout(0)
h:send("GET /state HTTP/1.1\r\nHost: x\r\n\r\n")
r = recv_all(h)
assert(r:find("200 OK") and r:find('"speed_kmh":25.6'), "http /state: " .. r)

-- camera page: served by OmniPlay, its own origin may open a WebSocket, readings arrive
local hc = assert(socket.connect("127.0.0.1", 21891)); hc:settimeout(0)
hc:send("GET /camera HTTP/1.1\r\nHost: x\r\n\r\n")
r = recv_all(hc)
assert(r:find("200 OK") and r:find("text/html") and r:find("OmniPlay camera"), "camera page should be served")
local cw = connect("http://127.0.0.1:21891")
r = recv_all(cw)
assert(r:find("101 Switching Protocols"), "the camera page's own origin should be allowed")
cw:send(masked('{"camera":{"moving":true,"cadence":84,"fps":30,"activity":"cycling"}}'))
tick(0.3)
local cam = api.camera_live()
assert(cam and cam.moving and cam.cadence == 84, "camera reading should arrive")
assert(api.game_name() == "PhysPlay", "the camera page must not count as a game")
cw:close()

-- game leaves: grade ramps back to flat, keys come back
c:close()
tick(3)
assert(not api.take_input() and api.grade == nil and sent_grades[#sent_grades] == 0, "should return to flat")

-- GMod file bridge
local live = io.open("/tmp/omni-api/omniplay/live.txt"):read("*a")
assert(json.decode(live).cadence == 61, "live.txt should hold state")
local function gmod_write(beat, grade)
  local f = io.open("/tmp/omni-api/omniplay/cmd.txt", "wb")
  f:write(json.encode({ beat = beat, game = "Garry's Mod", grade = grade, take_input = false })); f:close()
end
gmod_write(1, 8)    -- first file seen counts as left over from an old run
tick(0.5)
assert(api.game_name() == nil, "stale cmd.txt should be ignored")
gmod_write(2, 8)
tick(0.5)
assert(api.game_name() == "Garry's Mod", "gmod should be connected")
-- latency: the game acks the state it saw
local seen = json.decode(io.open("/tmp/omni-api/omniplay/live.txt"):read("*a")).seq
local f = io.open("/tmp/omni-api/omniplay/cmd.txt", "wb"); f:write(json.encode({ beat = 99, game = "Garry's Mod", ack = seen })); f:close()
tick(0.1)
assert(#api.stats.rtt == 1 and api.stats.rtt[1] < 0.3, "round trip should be measured")
-- the user turned hills off: requests are ignored
dev.allow_hills = false
local before = #sent_grades
tick(2)
assert(#sent_grades == before, "hills off: nothing may reach the bike")
dev.allow_hills = true
for b = 3, 6 do gmod_write(b, 8); tick(0.5) end
assert(sent_grades[#sent_grades] == 8, "gmod hill should reach the bike")
-- gmod stops writing -> disconnected after 3 s
tick(4)
assert(api.game_name() == nil, "gmod should time out")
api.shutdown()
assert(json.decode(io.open("/tmp/omni-api/omniplay/live.txt"):read("*a")).closed == true)
for _, l in ipairs(logs) do print("  " .. l) end
print("api tests passed")
