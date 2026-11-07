-- OmniPlay simulator for game developers: pretends to be the OmniPlay app with a rider on a bike
-- (or a walking pad), so you can test your game without the app or any hardware.
--
--   luajit omniplay_sim.lua            bike, pedalling 20-30 km/h in waves
--   luajit omniplay_sim.lua walk       walking pad, 4 km/h
--   luajit omniplay_sim.lua stop       connected but standing still
--   luajit omniplay_sim.lua bike 10    run for 10 seconds, then exit (for automatic tests)
--
-- Prints every request your game sends (name, hill, take_input). Windows and Linux.
-- License: OmniPlay SDK License.
local ffi = require("ffi")
local mode, secs = arg[1] or "bike", tonumber(arg[2])
local IS_WIN = ffi.os == "Windows"
local SIZE = 16384
local function decl(list) for _, d in ipairs(list) do pcall(ffi.cdef, d) end end
decl { "typedef struct { float speed_kmh, cadence, power, hr, grade, distance_m, elapsed_s, steps; int32_t moving, gait, kind, connected; } op_values;" }
if IS_WIN then
  decl {
    "void *CreateFileMappingA(void *file, void *sec, uint32_t prot, uint32_t hi, uint32_t lo, const char *name);",
    "void *MapViewOfFile(void *h, uint32_t access, uint32_t hi, uint32_t lo, size_t n);",
    "uint64_t GetTickCount64(void);", "uint32_t GetCurrentProcessId(void);", "void Sleep(uint32_t ms);",
  }
else
  decl {
    "int shm_open(const char *name, int oflag, int mode);", "int ftruncate(int fd, long len);",
    "void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off);", "int close(int fd);",
    "int getpid(void);", "struct op_timespec { long sec, nsec; };", "int clock_gettime(int clk, struct op_timespec *t);",
    "int usleep(unsigned us);",
  }
end
local C = ffi.C
local ts = not IS_WIN and ffi.new("struct op_timespec")
local function now()
  if IS_WIN then return tonumber(C.GetTickCount64()) / 1000 end
  C.clock_gettime(1, ts); return tonumber(ts.sec) + tonumber(ts.nsec) / 1e9
end
local function sleep(s) if IS_WIN then C.Sleep(s * 1000) else C.usleep(s * 1e6) end end

local p
if IS_WIN then
  p = C.MapViewOfFile(C.CreateFileMappingA(ffi.cast("void *", -1), nil, 0x04, 0, SIZE, "Local\\OmniPlay_v1"), 0xF001F, 0, 0, SIZE)
else
  local fd = C.shm_open("/OmniPlay_v1", 66, 384); C.ftruncate(fd, SIZE)
  p = C.mmap(nil, SIZE, 3, 1, fd, 0); C.close(fd)
end
local mem = ffi.cast("uint8_t *", p)
ffi.copy(mem, "OMNIPLAY", 8)
ffi.cast("uint32_t *", mem + 8)[0] = 1
ffi.cast("uint32_t *", mem + 12)[0] = IS_WIN and C.GetCurrentProcessId() or C.getpid()
local seq = ffi.cast("volatile uint32_t *", mem + 16)
local v = ffi.cast("op_values *", mem + 32)

print(("OmniPlay simulator: %s. Ctrl+C to stop."):format(mode))
local t0, dist, last_req, grade, steps = now(), 0, nil, 0, 0
while true do
  local t = now() - t0
  local kind, speed, cad, power, gait, devname
  if mode == "walk" then
    kind, speed, cad, power, gait, devname = "treadmill", 4.0, 108, nil, "walk", "SPERAX_RM01"
    steps = steps + cad / 60 * 0.05
  elseif mode == "stop" then
    kind, speed, cad, power, gait, devname = "bike", 0, 0, 0, "stopped", "Simulated bike"
  else
    speed = 25 + 5 * math.sin(t / 6)
    kind, cad, power, gait, devname = "bike", speed * 3.4, math.floor(140 + 40 * math.sin(t / 6) + grade * 15), speed > 22 and "run" or "walk", "Simulated bike"
  end
  dist = dist + speed / 3.6 * 0.05
  local js = string.format(
    '{"type":"state","v":1,"seq":%d,"app":"OmniPlay (simulator)","connected":true,"device":{"name":"%s","kind":"%s","hills":%s,"belt_speed":%s},' ..
    '"speed_kmh":%.2f,"cadence":%.1f%s,"hr":%d%s,"moving":%s,"gait":"%s","grade":%.2f,"recording":"recording","distance_m":%.1f,"elapsed_s":%.1f}',
    math.floor(t * 20), devname, kind, tostring(kind == "bike"), tostring(kind == "treadmill"), speed, cad,
    power and (',"power":' .. power) or "", 120 + math.floor(10 * math.sin(t / 9)), kind == "treadmill" and (',"steps":' .. math.floor(steps)) or "",
    tostring(speed > 0), gait, grade, dist, t)
  local s = seq[0]; if s % 2 == 1 then s = s + 1 end
  seq[0] = s + 1
  v.speed_kmh, v.cadence, v.power, v.hr, v.grade = speed, cad, power or 0 / 0, 120 + math.floor(10 * math.sin(t / 9)), grade
  v.distance_m, v.elapsed_s, v.steps = dist, t, kind == "treadmill" and math.floor(steps) or 0 / 0
  v.moving, v.gait = speed > 0 and 1 or 0, ({ stopped = 0, walk = 1, run = 2, sprint = 3 })[gait]
  v.kind, v.connected = ({ bike = 1, treadmill = 2, footpod = 3 })[kind], 1
  ffi.copy(mem + 96, js, #js); mem[96 + #js] = 0
  ffi.cast("uint32_t *", mem + 20)[0] = #js
  ffi.cast("double *", mem + 24)[0] = now()
  seq[0] = s + 2
  -- the game's request
  local rs = ffi.cast("volatile uint32_t *", mem + 8192)[0]
  if rs ~= 0 and rs % 2 == 0 and rs ~= last_req then
    last_req = rs
    local req = ffi.string(mem + 8216, ffi.cast("uint32_t *", mem + 8196)[0])
    local g = tonumber(req:match('"grade":(%-?[%d%.]+)'))
    grade = g and math.max(-10, math.min(20, g)) or 0
    print(("%6.1f s  game says: %s"):format(t, req))
  end
  local age = now() - ffi.cast("double *", mem + 8208)[0]
  if last_req and age > 3 and grade ~= 0 then print(("%6.1f s  game stopped calling (heartbeat %.1f s old): hill back to flat"):format(t, age)); grade = 0 end
  if secs and t >= secs then break end
  sleep(0.05)
end
ffi.cast("uint32_t *", mem + 12)[0] = 0
