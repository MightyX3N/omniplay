-- OmniPlay for LÖVE / LuaJIT games: one file, no DLL. Drop it next to main.lua.
--
--   local omniplay = require("omniplay")
--   omniplay.set_game("My Game")
--   function love.update(dt)
--     local v = omniplay.values()          -- nil while OmniPlay isn't running
--     if v then player.speed = v.speed_kmh end
--     omniplay.set_grade(hill_here)        -- nil = flat
--   end
--
-- values(): speed_kmh, cadence, power, hr, grade, distance_m, elapsed_s, steps (nil if unknown),
--           moving (bool), gait ("stopped"/"walk"/"run"/"sprint"), kind ("bike"/"treadmill"/"footpod"/nil),
--           connected (a device is connected in OmniPlay)
-- state_json(): the full state as JSON text (device name, camera, recording... see docs/API.md), and a seq
-- set_game(name)  set_grade(pct|nil)  set_belt_speed(kmh|nil)  take_input(bool)  set_info(text)  release()
--
-- Your game counts as connected while it keeps calling values() or state_json().
-- License: OmniPlay SDK License (MIT + don't sell OmniPlay support as a separate purchase).
local ffi = require("ffi")
local M = { version = 1 }

local IS_WIN = ffi.os == "Windows"
local SIZE = 16384
local function decl(list) for _, d in ipairs(list) do pcall(ffi.cdef, d) end end
decl {
  "typedef struct { float speed_kmh, cadence, power, hr, grade, distance_m, elapsed_s, steps; int32_t moving, gait, kind, connected; } op_values;",
}
if IS_WIN then
  decl {
    "void *CreateFileMappingA(void *file, void *sec, uint32_t prot, uint32_t hi, uint32_t lo, const char *name);",
    "void *MapViewOfFile(void *h, uint32_t access, uint32_t hi, uint32_t lo, size_t n);",
    "uint64_t GetTickCount64(void);",
    "uint32_t GetCurrentProcessId(void);",
  }
else
  decl {
    "int shm_open(const char *name, int oflag, int mode);",
    "int ftruncate(int fd, long len);",
    "void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off);",
    "int close(int fd);",
    "int getpid(void);",
    "struct op_timespec { long sec, nsec; };",
    "int clock_gettime(int clk, struct op_timespec *t);",
  }
end
local C = ffi.C
local ts = not IS_WIN and ffi.new("struct op_timespec")
local function now()
  if IS_WIN then return tonumber(C.GetTickCount64()) / 1000 end
  C.clock_gettime(1, ts)
  return tonumber(ts.sec) + tonumber(ts.nsec) / 1e9
end

local mem, last_try = nil, -10
local function shm()
  if mem then return mem end
  if now() - last_try < 1 then return nil end
  last_try = now()
  local p
  if IS_WIN then
    local h = C.CreateFileMappingA(ffi.cast("void *", -1), nil, 0x04, 0, SIZE, "Local\\OmniPlay_v1")
    if h == nil then return nil end
    p = C.MapViewOfFile(h, 0xF001F, 0, 0, SIZE)
    if p == nil then return nil end
  else
    local fd = C.shm_open("/OmniPlay_v1", 2 + 64, 384)
    if fd < 0 then return nil end
    C.ftruncate(fd, SIZE)
    p = C.mmap(nil, SIZE, 3, 1, fd, 0)
    C.close(fd)
    if ffi.cast("intptr_t", p) == -1 then return nil end
  end
  mem = ffi.cast("uint8_t *", p)
  return mem
end
local function u32(o) return ffi.cast("volatile uint32_t *", mem + o) end
local function f64(o) return ffi.cast("volatile double *", mem + o) end

function M.running()
  if not shm() then return false end
  if ffi.string(mem, 8) ~= "OMNIPLAY" or u32(8)[0] ~= 1 or u32(12)[0] == 0 then return false end
  return math.abs(now() - f64(24)[0]) < 2
end

local req = { used = false }
local function beat()
  if not mem or not req.used then return end
  u32(8200)[0] = IS_WIN and C.GetCurrentProcessId() or C.getpid()
  f64(8208)[0] = now()
end

local GAIT = { [0] = "stopped", "walk", "run", "sprint" }
local KIND = { "bike", "treadmill", "footpod" }
local function n(v) if v == v then return v end end
local vbuf = ffi.new("op_values")
function M.values()
  if not M.running() then return nil end
  beat()
  for _ = 1, 50 do
    local s = u32(16)[0]
    if s % 2 == 0 then
      ffi.copy(vbuf, mem + 32, ffi.sizeof(vbuf))
      if u32(16)[0] == s then break end
    end
  end
  local v = vbuf
  return {
    speed_kmh = v.speed_kmh, cadence = v.cadence, power = n(v.power), hr = n(v.hr), grade = v.grade,
    distance_m = v.distance_m, elapsed_s = v.elapsed_s, steps = n(v.steps),
    moving = v.moving ~= 0, gait = GAIT[v.gait] or "stopped", kind = KIND[v.kind], connected = v.connected ~= 0,
  }
end

function M.state_json()
  if not M.running() then return nil end
  beat()
  for _ = 1, 50 do
    local s = u32(16)[0]
    if s % 2 == 0 then
      local len = math.min(u32(20)[0], 8192 - 96 - 1)
      local js = ffi.string(mem + 96, len)
      if u32(16)[0] == s then return js, s end
    end
  end
end

-- requests: the whole request is rewritten on every change
local function q(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
local function send()
  if not shm() then return end
  req.used = true
  local parts = { '"game":' .. q(req.game or "LÖVE game") }
  parts[#parts + 1] = req.grade and string.format('"grade":%.2f', req.grade) or '"grade":false'
  if req.belt then parts[#parts + 1] = string.format('"belt_speed":%.2f', req.belt) end
  if req.take ~= nil then parts[#parts + 1] = '"take_input":' .. tostring(req.take) end
  if req.info then parts[#parts + 1] = '"info":' .. q(req.info) end
  if req.release then parts[#parts + 1] = '"release":true' end
  local js = "{" .. table.concat(parts, ",") .. "}"
  local s = u32(8192)[0]
  if s % 2 == 1 then s = s + 1 end
  u32(8192)[0] = s + 1
  ffi.copy(mem + 8216, js, math.min(#js, 4095))
  mem[8216 + math.min(#js, 4095)] = 0
  u32(8196)[0] = math.min(#js, 4095)
  beat()
  u32(8192)[0] = s + 2
end

function M.set_game(name) req.game, req.release = tostring(name), nil; send() end
function M.set_grade(pct)
  if pct then pct = math.max(-10, math.min(20, pct)) end
  if pct == req.grade then beat() return end
  req.grade, req.release = pct, nil; send()
end
function M.set_belt_speed(kmh) req.belt, req.release = kmh, nil; send() end
function M.take_input(on) req.take, req.release = on and true or false, nil; send() end
function M.set_info(text) req.info, req.release = text and tostring(text):sub(1, 300), nil; send() end
function M.release()
  req.grade, req.belt, req.take, req.release = nil, nil, false, true
  send()
  req.used = false
end

return M
