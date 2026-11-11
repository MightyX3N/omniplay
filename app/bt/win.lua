-- Windows Bluetooth: LuaJIT binding to native/omniplay_ble.c (omniplay_ble.dll next to the exe).
-- Same functions as bt/fake.lua; devices.lua drives either one.
local ffi = require("ffi")

ffi.cdef [[
  const char *sb_last_error(void);
  int  sb_scan_start(void);
  void sb_scan_stop(void);
  int  sb_scan_list(char *out, int outlen);
  int  sb_open_h(const char *addr_hex, const char *service, const char *notify_uuids, const char *write_uuid, int uncached);
  int  sb_state_h(int h);
  const char *sb_error_h(int h);
  int  sb_write_h(int h, const unsigned char *data, int len);
  int  sb_read_h(int h, unsigned char *buf, int maxlen, int *which);
  void sb_close_h(int h);
  int  sb_explore(const char *addr_hex, int listen_ms);
  int  sb_explore_state(void);
  int  sb_explore_text(char *out, int outlen);
]]

local M = { name = "Windows Bluetooth" }
local lib
local listbuf = ffi.new("char[16384]")
local exbuf = ffi.new("char[65536]")
local rx = ffi.new("unsigned char[512]")
local which = ffi.new("int[1]")

function M.load()
  if love.system.getOS() ~= "Windows" then return nil, "not Windows" end
  local tried = {}
  for _, dir in ipairs({ love.filesystem.getSourceBaseDirectory(), love.filesystem.getSource() }) do
    local p = dir .. "/omniplay_ble.dll"
    tried[#tried + 1] = p
    local ok, l = pcall(ffi.load, p)
    if ok then lib = l; return M end
  end
  local ok, l = pcall(ffi.load, "omniplay_ble")
  if ok then lib = l; return M end
  return nil, "Couldn't load omniplay_ble.dll (tried " .. table.concat(tried, ", ") .. ")"
end

function M.last_error() return ffi.string(lib.sb_last_error()) end
function M.scan_start() return lib.sb_scan_start() == 0 end
function M.scan_stop() lib.sb_scan_stop() end

-- {name, addr, rssi, age_ms, flags}
function M.scan_list()
  lib.sb_scan_list(listbuf, 16384)
  local t = {}
  for line in ffi.string(listbuf):gmatch("[^\n]+") do
    local name, addr, rssi, age, flags = line:match("^(.-)\t(%x+)\t(%-?%d+)\t(%d+)\t(%d+)$")
    if addr then t[#t + 1] = { name = name, addr = addr, rssi = tonumber(rssi), age_ms = tonumber(age), flags = tonumber(flags) } end
  end
  return t
end

function M.explore(addr) return lib.sb_explore(addr, 400) == 0 end
function M.explore_state() return lib.sb_explore_state() end -- 1 busy, 2 done, -1 failed
function M.explore_text() lib.sb_explore_text(exbuf, 65536); return ffi.string(exbuf) end

function M.open(addr, service, notify_csv, write_uuid, uncached)
  local h = lib.sb_open_h(addr, service, notify_csv, write_uuid or "", uncached and 1 or 0)
  if h < 0 then return nil, M.last_error() end
  return h
end
function M.state(h) return lib.sb_state_h(h) end -- 1 connecting, 2 connected, -1 failed
function M.error(h) return ffi.string(lib.sb_error_h(h)) end
function M.close(h) lib.sb_close_h(h) end
-- one queued notification: bytes (array), index into the notify list (0-based); nil when empty
function M.read(h)
  local n = lib.sb_read_h(h, rx, 512, which)
  if n <= 0 then return nil end
  local b = {}
  for i = 0, n - 1 do b[i + 1] = rx[i] end
  return b, which[0]
end
function M.write(h, bytes)
  local buf = ffi.new("unsigned char[?]", #bytes, bytes)
  return lib.sb_write_h(h, buf, #bytes) == 0
end

return M
