-- Game output: turns movement into held keys (scancodes, so DirectInput games see them),
-- with per-game profiles picked by the foreground program. F8 toggles output anywhere.
local ffi = require("ffi")
local store = require("store")
local bit = require("bit")

local M = { enabled = false, gait = "stopped", profile = nil, foreground = "", log = function() end }

local IS_WIN = ffi.os == "Windows"
if IS_WIN then
  ffi.cdef [[
    typedef struct { uint16_t wVk, wScan; uint32_t dwFlags, time; uintptr_t dwExtraInfo; } OP_KEYBDINPUT;
    typedef struct { uint32_t type; uint32_t _pad; OP_KEYBDINPUT ki; uint8_t _rest[8]; } OP_INPUT;
    unsigned int SendInput(unsigned int n, OP_INPUT *inputs, int size);
    short GetAsyncKeyState(int vk);
    void *GetForegroundWindow(void);
    unsigned long GetWindowThreadProcessId(void *hwnd, unsigned long *pid);
    void *OpenProcess(unsigned long access, int inherit, unsigned long pid);
    int QueryFullProcessImageNameA(void *proc, unsigned long flags, char *name, unsigned long *size);
    int CloseHandle(void *h);
    unsigned long GetCurrentProcessId(void);
  ]]
end

-- LÖVE key names -> set-1 scancodes (0xE0xx = extended)
M.SCAN = {
  w = 0x11, a = 0x1E, s = 0x1F, d = 0x20, e = 0x12, q = 0x10, r = 0x13, f = 0x21, c = 0x2E, x = 0x2D, z = 0x2C,
  space = 0x39, lshift = 0x2A, rshift = 0x36, lctrl = 0x1D, rctrl = 0xE01D, lalt = 0x38, ralt = 0xE038,
  tab = 0x0F, capslock = 0x3A, up = 0xE048, down = 0xE050, left = 0xE04B, right = 0xE04D,
  ["1"] = 0x02, ["2"] = 0x03, ["3"] = 0x04, ["4"] = 0x05,
}
M.LABEL = { lshift = "Shift", rshift = "RShift", lctrl = "Ctrl", rctrl = "RCtrl", lalt = "Alt", ralt = "RAlt",
  space = "Space", capslock = "Caps", up = "Up", down = "Down", left = "Left", right = "Right", tab = "Tab" }
function M.key_label(k) return M.LABEL[k] or k:upper() end

-- Default profile works for most first/third-person games (W walks forward, Shift sprints).
local function default_profile()
  return {
    name = "Any game", exe = "",
    walk = { keys = { "w", "lalt" }, pad_kmh = 1.0, rpm = 30 },
    run = { keys = { "w" }, pad_kmh = 3.5, rpm = 70 },
    sprint = { keys = { "w", "lshift" }, pad_kmh = 5.0, watts = 200 },
    hold_s = 2.0,
  }
end
M.default_profile = default_profile

M.profiles = {}
function M.init(log_fn)
  M.log = log_fn or M.log
  M.profiles = store.load("profiles.lua", nil) or { default_profile(),
    { name = "Garry's Mod", exe = "gmod.exe",
      walk = { keys = { "w", "lalt" }, pad_kmh = 1.0, rpm = 30 }, run = { keys = { "w" }, pad_kmh = 3.5, rpm = 70 },
      sprint = { keys = { "w", "lshift" }, pad_kmh = 5.0, watts = 200 }, hold_s = 2.0 } }
  M.profile = M.profiles[1]
end
function M.save() store.save("profiles.lua", M.profiles) end

-- ---------- key injection ----------
local held = {}
local function send_key(name, down)
  if not IS_WIN then return end
  local sc = M.SCAN[name]
  if not sc then return end
  local inp = ffi.new("OP_INPUT[1]")
  inp[0].type = 1 -- INPUT_KEYBOARD
  inp[0].ki.wScan = bit.band(sc, 0xFF)
  local flags = 0x0008 -- KEYEVENTF_SCANCODE
  if sc > 0xFF then flags = flags + 0x0001 end -- KEYEVENTF_EXTENDEDKEY
  if not down then flags = flags + 0x0002 end  -- KEYEVENTF_KEYUP
  inp[0].ki.dwFlags = flags
  ffi.C.SendInput(1, inp, ffi.sizeof("OP_INPUT"))
end
M._send_key = send_key -- tests replace this

local function set_held(keys)
  local want = {}
  for _, k in ipairs(keys or {}) do want[k] = true end
  for k in pairs(held) do if not want[k] then M._send_key(k, false); held[k] = nil end end
  for k in pairs(want) do if not held[k] then M._send_key(k, true); held[k] = true end end
end
function M.release_all() set_held({}) end

-- ---------- foreground program ----------
local my_pid = IS_WIN and tonumber(ffi.C.GetCurrentProcessId()) or 0
local fg_buf = IS_WIN and ffi.new("char[520]") or nil
local function foreground_exe()
  if not IS_WIN then return "", false end
  local hwnd = ffi.C.GetForegroundWindow()
  if hwnd == nil then return "", false end
  local pid = ffi.new("unsigned long[1]")
  ffi.C.GetWindowThreadProcessId(hwnd, pid)
  if tonumber(pid[0]) == my_pid then return "omniplay", true end
  local h = ffi.C.OpenProcess(0x1000, 0, pid[0]) -- PROCESS_QUERY_LIMITED_INFORMATION
  if h == nil then return "", false end
  local size = ffi.new("unsigned long[1]", 520)
  local ok = ffi.C.QueryFullProcessImageNameA(h, 0, fg_buf, size)
  ffi.C.CloseHandle(h)
  if ok == 0 then return "", false end
  return (ffi.string(fg_buf):match("[^\\/]+$") or ""):lower(), false
end
M._foreground = foreground_exe

-- ---------- movement state ----------
local function gait_for(p, m, kind)
  if not m.moving then return "stopped" end
  local walking_device = kind == "sperax" or kind == "ftms_treadmill" or kind == "rsc"
  local function reached(st)
    if not st then return false end
    if walking_device then return st.pad_kmh and (m.speed_kmh or 0) >= st.pad_kmh end
    if st.watts and m.power and m.power >= st.watts then return true end
    -- a speed sensor without cadence: about 3 km/h per rpm (70 rpm ~ 23 km/h on a road bike)
    local cad = m.cadence
    if not cad and m.speed_kmh then cad = m.speed_kmh * 3 end
    return st.rpm and (cad or 0) >= st.rpm or false
  end
  if reached(p.sprint) then return "sprint" end
  if reached(p.run) then return "run" end
  if reached(p.walk) then return "walk" end
  return "walk" -- moving but below every threshold still counts as walking
end
M.gait_for = gait_for

local f8_was, fg_t, last_move_t = false, 1, 0
function M.update(dt, m, kind)
  -- F8 anywhere toggles output
  if IS_WIN then
    local f8 = bit.band(ffi.C.GetAsyncKeyState(0x77), 0x8000) ~= 0
    if f8 and not f8_was then M.toggle() end
    f8_was = f8
  end
  fg_t = fg_t + dt
  local is_self = false
  if fg_t >= 0.5 then
    fg_t = 0
    local exe
    exe, is_self = M._foreground()
    M.foreground, M.self_focused = exe, is_self
    local pick = M.profiles[1]
    for _, p in ipairs(M.profiles) do if p.exe ~= "" and p.exe:lower() == exe then pick = p end end
    if pick ~= M.profile then M.profile = pick; M.log("info", "profile: " .. pick.name) end
  end
  local p = M.profile or M.profiles[1]
  local g = gait_for(p, m, kind)
  -- ride through short dropouts instead of stopping dead
  if g ~= "stopped" then last_move_t = 0 else last_move_t = last_move_t + dt end
  if g == "stopped" and last_move_t < (p.hold_s or 2) and M.gait ~= "stopped" then g = M.gait end
  M.gait = g
  if not M.enabled or M.self_focused or M.suppressed then set_held({}) return end
  set_held(g ~= "stopped" and p[g] and p[g].keys or {})
end

function M.toggle()
  M.enabled = not M.enabled
  if not M.enabled then M.release_all() end
  M.log("info", "game output " .. (M.enabled and "ON" or "OFF") .. " (F8)")
end

function M.held_keys()
  local t = {}
  for k in pairs(held) do t[#t + 1] = k end
  table.sort(t)
  return t
end

return M
