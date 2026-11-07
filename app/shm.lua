-- The app side of the shared-memory link (layout in sdk/omniplay.h). OmniPlay writes the state
-- here every 50 ms; a game using the SDK, the GMod module or the LÖVE file writes its requests.
local ffi = require("ffi")
local M = {}

local IS_WIN = ffi.os == "Windows"
local SIZE = 16384
local mem

pcall(ffi.cdef, [[
typedef struct { float speed_kmh, cadence, power, hr, grade, distance_m, elapsed_s, steps; int32_t moving, gait, kind, connected; } op_values;
]])
-- one declaration at a time: another module may have declared some of these already
local function decl(list) for _, d in ipairs(list) do pcall(ffi.cdef, d) end end
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

local ts = not IS_WIN and ffi.new("struct op_timespec")
function M.now()
  if IS_WIN then return tonumber(ffi.C.GetTickCount64()) / 1000 end
  ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC
  return tonumber(ts.sec) + tonumber(ts.nsec) / 1e9
end

function M.open()
  if mem then return true end
  local p
  if IS_WIN then
    local h = ffi.C.CreateFileMappingA(ffi.cast("void *", -1), nil, 0x04, 0, SIZE, "Local\\OmniPlay_v1")
    if h == nil then return false end
    p = ffi.C.MapViewOfFile(h, 0xF001F, 0, 0, SIZE)
    if p == nil then return false end
  else
    local fd = ffi.C.shm_open("/OmniPlay_v1", 2 + 64, 384) -- O_RDWR | O_CREAT, 0600
    if fd < 0 then return false end
    ffi.C.ftruncate(fd, SIZE)
    p = ffi.C.mmap(nil, SIZE, 3, 1, fd, 0) -- PROT_READ|WRITE, MAP_SHARED
    ffi.C.close(fd)
    if ffi.cast("intptr_t", p) == -1 then return false end
  end
  mem = ffi.cast("uint8_t *", p)
  ffi.copy(mem, "OMNIPLAY", 8)
  ffi.cast("uint32_t *", mem + 8)[0] = 1
  ffi.cast("uint32_t *", mem + 12)[0] = IS_WIN and ffi.C.GetCurrentProcessId() or ffi.C.getpid()
  return true
end

local GAIT = { stopped = 0, walk = 1, run = 2, sprint = 3 }
local KIND = { bike = 1, treadmill = 2, footpod = 3 }
local function f(v) return type(v) == "number" and v or 0 / 0 end

-- st: the state table (as sent over the WebSocket), js: its JSON
function M.publish(st, js)
  if not mem then return end
  local seq = ffi.cast("volatile uint32_t *", mem + 16)
  local s = seq[0]
  if s % 2 == 1 then s = s + 1 end
  seq[0] = s + 1
  local v = ffi.cast("op_values *", mem + 32)
  v.speed_kmh, v.cadence, v.power, v.hr = st.speed_kmh or 0, st.cadence or 0, f(st.power), f(st.hr)
  v.grade, v.distance_m, v.elapsed_s, v.steps = st.grade or 0, st.distance_m or 0, st.elapsed_s or 0, f(st.steps)
  v.moving, v.gait = st.moving and 1 or 0, GAIT[st.gait] or 0
  v.kind, v.connected = st.device and KIND[st.device.kind] or 0, st.connected and 1 or 0
  local n = math.min(#js, 8192 - 96 - 1)
  ffi.copy(mem + 96, js, n)
  mem[96 + n] = 0
  ffi.cast("uint32_t *", mem + 20)[0] = n
  ffi.cast("double *", mem + 24)[0] = M.now()
  seq[0] = s + 2
end

-- the game's request: json, its beat time and process id. nil while it's being written.
local last_req_seq
function M.request()
  if not mem then return end
  local seq = ffi.cast("volatile uint32_t *", mem + 8192)[0]
  if seq == 0 or seq % 2 == 1 then return end
  local n = math.min(ffi.cast("uint32_t *", mem + 8196)[0], 4095)
  local js = ffi.string(mem + 8216, n)
  if ffi.cast("volatile uint32_t *", mem + 8192)[0] ~= seq then return end
  local changed = seq ~= last_req_seq
  last_req_seq = seq
  return js, ffi.cast("double *", mem + 8208)[0], changed
end

function M.close()
  if not mem then return end
  ffi.cast("uint32_t *", mem + 12)[0] = 0 -- app gone: games see "not running" at once
  ffi.cast("double *", mem + 24)[0] = 0
end

return M
