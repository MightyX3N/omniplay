-- Sperax walking pad UART-over-BLE protocol (service FFF0, notify FFF1, write FFF2).
-- Frame: F5 <len> 00 <payload...> <crcLo> <crcHi> FA
-- Inside a frame the pad escapes any 0xFn byte as F0 0n; <len> counts escaped bytes.
-- Based on docs/PROTOCOL.md from github.com/Guhan-SenSam/sperax-walkpad (MIT).
local bit = require("bit")
local band, bxor, rshift, bor = bit.band, bit.bxor, bit.rshift, bit.bor

local M = {}

function M.crc16(b, i, j)
  local crc = 0xFFFF
  for k = i, j do
    crc = bxor(crc, b[k])
    for _ = 1, 8 do
      if band(crc, 1) == 1 then crc = bxor(rshift(crc, 1), 0xA327) else crc = rshift(crc, 1) end
    end
  end
  return band(crc, 0xFF), band(rshift(crc, 8), 0xFF)
end

-- Frame rule (verified on a SPERAX_RM01): build the frame with <len> = its
-- unescaped length, compute the CRC over that, then escape inner 0xFn bytes as
-- F0 0n and set <len> to the escaped length. Same rule both directions.
local function escape(f)
  local out = { f[1], 0, f[3] }
  for i = 4, #f - 1 do
    local v = f[i]
    if v >= 0xF0 then out[#out + 1] = 0xF0; out[#out + 1] = v - 0xF0 else out[#out + 1] = v end
  end
  out[#out + 1] = f[#f]
  out[2] = #out
  return out
end

function M.encode(payload)
  local f = { 0xF5, #payload + 6, 0x00 }
  for _, v in ipairs(payload) do f[#f + 1] = v end
  local lo, hi = M.crc16(f, 1, #f)
  f[#f + 1], f[#f + 2], f[#f + 3] = lo, hi, 0xFA
  return escape(f)
end

M.STATUS = M.encode({ 0x19 })   -- F5 08 00 19 F0 0A 59 FA
M.TOTALS = M.encode({ 0x1A })   -- F5 07 00 1A E6 EA FA

local function unescape(raw)
  local out, i = {}, 1
  while i <= #raw do
    local v = raw[i]
    if v == 0xF0 and i < #raw and raw[i + 1] <= 0x0F then
      out[#out + 1] = bor(0xF0, raw[i + 1]); i = i + 2
    else
      out[#out + 1] = v; i = i + 1
    end
  end
  return out
end

-- Stream reassembler: notifications can split a frame (or hold several).
function M.new_reader()
  return { buf = {}, junk = 0 }
end

-- Feed a chunk (byte array). Returns a list of frames:
-- { raw = escaped bytes, b = unescaped bytes, len_ok, crc_ok, cmd }
function M.feed(r, chunk)
  for _, v in ipairs(chunk) do r.buf[#r.buf + 1] = v end
  local frames = {}
  while true do
    local s
    for i = 1, #r.buf do if r.buf[i] == 0xF5 then s = i break end end
    if not s then r.junk = r.junk + #r.buf; r.buf = {}; break end
    if s > 1 then
      r.junk = r.junk + s - 1
      local nb = {}
      for i = s, #r.buf do nb[#nb + 1] = r.buf[i] end
      r.buf = nb
    end
    local e
    for i = 2, #r.buf do if r.buf[i] == 0xFA then e = i break end end
    if not e then
      if #r.buf > 1024 then r.junk = r.junk + #r.buf; r.buf = {} end
      break
    end
    local raw = {}
    for i = 1, e do raw[i] = r.buf[i] end
    local nb = {}
    for i = e + 1, #r.buf do nb[#nb + 1] = r.buf[i] end
    r.buf = nb

    -- Some pads insert 1-3 junk bytes right after F5. If the length byte doesn't
    -- match, look for a later byte that does and drop what's in between.
    local junk = 0
    if raw[2] ~= #raw then
      for j = 3, math.min(5, #raw - 5) do
        if raw[j] == #raw - (j - 2) then
          local fixed = { 0xF5 }
          for i = j, #raw do fixed[#fixed + 1] = raw[i] end
          junk, raw = j - 2, fixed
          break
        end
      end
    end

    local b = unescape(raw)
    local f = { raw = raw, b = b, len_ok = raw[2] == #raw, cmd = b[4], junk = junk }
    if #b >= 7 then
      local len = b[2]
      b[2] = #b -- CRC covers the frame with its unescaped length
      local lo, hi = M.crc16(b, 1, #b - 3)
      b[2] = len
      f.crc_ok = lo == b[#b - 2] and hi == b[#b - 1]
    end
    frames[#frames + 1] = f
  end
  return frames
end

M.STATES = {
  [0x00] = "idle", [0x13] = "countdown 3", [0x12] = "countdown 2", [0x11] = "countdown 1",
  [0x10] = "running", [0x0F] = "slowing", [0x01] = "paused", [0x02] = "stopped", [0x50] = "vibrating",
}

local function u16(b, i) return (b[i] or 0) * 256 + (b[i + 1] or 0) end

-- Decode a status (0x19) frame. Offsets are 0-based in the docs; Lua arrays are 1-based.
function M.decode_status(f)
  local b = f.b
  if f.cmd ~= 0x19 or #b < 21 then return nil end
  return {
    state_raw = b[7],
    state = M.STATES[b[7]] or string.format("unknown 0x%02X", b[7]),
    metric = b[9] == 0x01,
    seconds = u16(b, 10),
    distance_m = u16(b, 12) * 10,
    kcal = u16(b, 14),
    steps = u16(b, 16),
    speed_kmh = b[18] / 10,
    vibration = b[21],
  }
end

function M.hex(b)
  local t = {}
  for i, v in ipairs(b) do t[i] = string.format("%02X", v) end
  return table.concat(t, " ")
end

return M
