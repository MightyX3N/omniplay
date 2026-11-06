-- Headless smoke test of main.lua: fake LÖVE and a fake omniplay_ble.dll that behaves like a Sperax pad.
package.path = "app/?.lua;" .. package.path
local ffi = require("ffi")
local sperax = require("drivers.sperax")

local noop = function() end
local fontobj = setmetatable({}, { __index = function() return noop end })
love = {
  graphics = setmetatable({ getDimensions = function() return 900, 640 end, newFont = function() return fontobj end },
    { __index = function() return noop end }),
  filesystem = { getSource = function() return "/x" end, getSourceBaseDirectory = function() return "/x" end,
    write = noop, getSaveDirectory = function() return "/save" end },
  timer = { getTime = os.clock },
  system = { setClipboardText = function(t) CLIP = t end },
  event = { quit = noop },
}

-- fake pad
local state, queue, writes = 0, {}, 0
local function status_frame(steps)
  local payload = { 0x19, 0, 0, 0x10, 0, 1, 0, 30, 0, 5, 0, 2, math.floor(steps / 256), steps % 256, 32, 0, 0, 0 }
  local f = sperax.encode(payload)
  return f
end
local steps = 100
local fake = {
  sb_last_error = function() return "fake error" end,
  sb_status_text = function() return "Connecting..." end,
  sb_state = function() return state end,
  sb_scan_start = function() return 0 end,
  sb_scan_stop = noop,
  sb_scan_list = function(buf, n)
    local s = "Phone\t112233445566\t-80\t100\t0\nSPERAX_RM01\tAABBCCDDEEFF\t-55\t50\t32\n\tDEADBEEF0000\t-90\t10\t1\n\tCAFE00000000\t-40\t10\t0\n"
    ffi.copy(buf, s)
    return 3
  end,
  sb_open = function(addr) assert(addr == "AABBCCDDEEFF", addr); state = 2; return 0 end,
  sb_write = function(data, len)
    writes = writes + 1
    local sent = {}
    for i = 0, len - 1 do sent[#sent + 1] = data[i] end
    local hex = sperax.hex(sent)
    local f
    if hex == "F5 08 00 19 F0 0A 59 FA" then f = status_frame(steps); steps = steps + 2
    elseif hex == "F5 07 00 1A E6 EA FA" then f = sperax.encode({ 0x1A, 0, 0, 1, 2 })
    else f = { 0xF5, 0x58, 0x08, 0x00, 0x0E, 0x02, 0x14, 0x47, 0xFA } end -- real reject with junk byte
    local chunk = {}
    for i, v in ipairs(f) do chunk[#chunk + 1] = v; if #chunk == 20 or i == #f then queue[#queue + 1] = chunk; chunk = {} end end
    return 0
  end,
  sb_read = function(buf, max)
    local c = table.remove(queue, 1)
    if not c then return 0 end
    for i, v in ipairs(c) do buf[i - 1] = v end
    return #c
  end,
  sb_dropped = function() return 0 end,
  sb_close = function() state = 0 end,
  sb_explore = function(addr, ms) EXPLORED = addr; return 0 end,
  sb_explore_state = function() return 2 end,
  sb_explore_text = function(buf, n)
    local b = "0000%s-0000-1000-8000-00805f9b34fb"
    local t = table.concat({
      "service " .. b:format("180a"), "char " .. b:format("2a29") .. " props 02", "read " .. b:format("2a29") .. " 43 48 52 49 53",
      "service " .. b:format("1826"), "char " .. b:format("2acc") .. " props 02", "read " .. b:format("2acc") .. " 86 40 00 00 0C 00 00 00",
      "char " .. b:format("2ad2") .. " props 10", "sub " .. b:format("2ad2") .. " ok", "listening 10000",
      "notify " .. b:format("2ad2") .. " 64 00 28 0A B4 00 0A 00 96 00", "done" }, "\n")
    ffi.copy(buf, t); return #t
  end,
}
ffi.load = function() return fake end

dofile("app/main.lua")
love.load()
for _ = 1, 5 do love.update(0.2); love.draw() end
love.keypressed("1")
for _ = 1, 80 do love.update(0.1); love.draw() end
love.keypressed("c")
print(CLIP:sub(1, 900))

assert(writes > 5, "writes " .. writes)
assert(CLIP:find("frame cmd 19"), "no status frames decoded")
love.keypressed("d")
for _ = 1, 3 do love.update(0.2); love.draw() end
-- explorer flow
love.keypressed("e"); love.keypressed("2")
for _ = 1, 3 do love.update(0.6); love.draw() end
assert(EXPLORED == "DEADBEEF0000", "device 2 should be the unnamed FTMS device, got " .. tostring(EXPLORED))
love.keypressed("c")
print(CLIP:sub(1, 1200))
assert(CLIP:find("resistance can be set"), "summary wrong")
assert(CLIP:find("cadence 90.0 rpm") and CLIP:find("power 150 W") and CLIP:find("speed 26.00"), "bike data decode wrong")
assert(CLIP:find('"CHRIS"'), "text decode wrong")
print("main smoke test passed")
