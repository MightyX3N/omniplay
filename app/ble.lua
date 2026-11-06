-- LuaJIT binding to native/omniplay_ble.c (omniplay_ble.dll next to the exe).
local ffi = require("ffi")

ffi.cdef [[
  const char *sb_last_error(void);
  const char *sb_status_text(void);
  int  sb_state(void);
  int  sb_scan_start(void);
  void sb_scan_stop(void);
  int  sb_scan_list(char *out, int outlen);
  int  sb_open(const char *addr_hex, const char *service, const char *notify_uuids, const char *write_uuid);
  int  sb_write(const unsigned char *data, int len);
  int  sb_read(unsigned char *buf, int maxlen);
  int  sb_read_ex(unsigned char *buf, int maxlen, int *which);
  int  sb_dropped(void);
  void sb_close(void);
  void sb_set_cache_mode(int uncached);
  int  sb_explore(const char *addr_hex, int listen_ms);
  int  sb_explore_state(void);
  int  sb_explore_text(char *out, int outlen);
  int  sb_tls_start(const char *dir, int listen_port, int target_port);
  const char *sb_tls_status(void);
]]

local M = {}

function M.load()
  local tried = {}
  for _, dir in ipairs({ love.filesystem.getSource(), love.filesystem.getSourceBaseDirectory() }) do
    local p = dir .. "/omniplay_ble.dll"
    tried[#tried + 1] = p
    local ok, lib = pcall(ffi.load, p)
    if ok then return lib end
  end
  local ok, lib = pcall(ffi.load, "omniplay_ble")
  if ok then return lib end
  return nil, "Couldn't load omniplay_ble.dll. Tried:\n" .. table.concat(tried, "\n")
end

return M
