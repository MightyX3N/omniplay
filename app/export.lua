-- Activity export: FIT (binary, Garmin) and TCX (XML). Indoor activities, no GPS.
-- A session is { start = unix seconds, sport = "cycling"|"running"|"walking", device = name,
--   samples = { { t = unix, e = timer seconds, d = metres, v = km/h, c = cadence, p = watts, hr = bpm }, ... },
--   elapsed, distance, kcal }
local bit = require("bit")
local band, bor, rshift, bxor, lshift = bit.band, bit.bor, bit.rshift, bit.bxor, bit.lshift

local M = {}
local FIT_EPOCH = 631065600 -- 1989-12-31 00:00:00 UTC in unix time

-- ---------- FIT ----------
local CRC_TABLE = { 0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
  0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400 }

local function fit_crc(bytes, crc)
  crc = crc or 0
  for i = 1, #bytes do
    local b = bytes:byte(i)
    local tmp = CRC_TABLE[band(crc, 0xF) + 1]
    crc = bxor(band(rshift(crc, 4), 0x0FFF), tmp, CRC_TABLE[band(b, 0xF) + 1])
    tmp = CRC_TABLE[band(crc, 0xF) + 1]
    crc = bxor(band(rshift(crc, 4), 0x0FFF), tmp, CRC_TABLE[band(rshift(b, 4), 0xF) + 1])
  end
  return crc
end
M.fit_crc = fit_crc

local function le(v, n)
  local t = {}
  v = math.floor(v)
  for i = 1, n do t[i] = string.char(band(v, 0xFF)); v = math.floor(v / 256) end
  return table.concat(t)
end

-- base types: code, size, invalid value
local T = {
  enum = { 0x00, 1, 0xFF }, u8 = { 0x02, 1, 0xFF }, u16 = { 0x84, 2, 0xFFFF },
  u32 = { 0x86, 4, 0xFFFFFFFF }, u32z = { 0x8C, 4, 0 },
}

-- messages: global number and fields { field number, type }
local MSG = {
  file_id = { 0, { { 0, "enum" }, { 1, "u16" }, { 2, "u16" }, { 3, "u32z" }, { 4, "u32" } } },
  event = { 21, { { 253, "u32" }, { 0, "enum" }, { 1, "enum" } } },
  record = { 20, { { 253, "u32" }, { 5, "u32" }, { 6, "u16" }, { 3, "u8" }, { 4, "u8" }, { 7, "u16" } } },
  lap = { 19, { { 253, "u32" }, { 2, "u32" }, { 7, "u32" }, { 8, "u32" }, { 9, "u32" }, { 0, "enum" }, { 1, "enum" }, { 25, "enum" } } },
  session = { 18, { { 253, "u32" }, { 2, "u32" }, { 7, "u32" }, { 8, "u32" }, { 9, "u32" }, { 5, "enum" }, { 6, "enum" },
    { 16, "u8" }, { 17, "u8" }, { 18, "u8" }, { 20, "u16" }, { 21, "u16" }, { 11, "u16" }, { 25, "u16" }, { 26, "u16" },
    { 0, "enum" }, { 1, "enum" } } },
  activity = { 34, { { 253, "u32" }, { 0, "u32" }, { 1, "u16" }, { 2, "enum" }, { 3, "enum" }, { 4, "enum" }, { 5, "u32" } } },
}
local ORDER = { "file_id", "event", "record", "lap", "session", "activity" }

local SPORT = { cycling = 2, running = 1, walking = 11 }
local SUB_SPORT = { cycling = 6, running = 1, walking = 27 } -- indoor_cycling, treadmill, indoor_walking

function M.fit(s)
  local out, local_of = {}, {}
  for i, name in ipairs(ORDER) do local_of[name] = i - 1 end

  local function define(name)
    local gnum, fields = MSG[name][1], MSG[name][2]
    local d = { string.char(bor(0x40, local_of[name]), 0, 0), le(gnum, 2), string.char(#fields) }
    for _, f in ipairs(fields) do d[#d + 1] = string.char(f[1], T[f[2]][2], T[f[2]][1]) end
    out[#out + 1] = table.concat(d)
  end
  local function data(name, values)
    local d = { string.char(local_of[name]) }
    for _, f in ipairs(MSG[name][2]) do
      local tp, v = T[f[2]], values[f[1]]
      if v == nil then v = tp[3] end
      d[#d + 1] = le(v, tp[2])
    end
    out[#out + 1] = table.concat(d)
  end

  local samples = s.samples or {}
  local t0 = s.start - FIT_EPOCH
  local t_end = (samples[#samples] and samples[#samples].t or s.start) - FIT_EPOCH
  local elapsed_ms = math.floor((t_end - t0) * 1000)
  local timer_ms = math.floor((s.elapsed or (t_end - t0)) * 1000)
  local dist_cm = math.floor((s.distance or 0) * 100)
  local function u8(v) return v and math.max(0, math.min(254, math.floor(v + 0.5))) or nil end
  local function u16(v) return v and math.max(0, math.min(65534, math.floor(v + 0.5))) or nil end

  for _, n in ipairs(ORDER) do define(n) end
  data("file_id", { [0] = 4, [1] = 255, [2] = 1, [3] = 1, [4] = t0 }) -- activity file, manufacturer "development"
  data("event", { [253] = t0, [0] = 0, [1] = 0 })                       -- timer start
  local hr_sum, hr_n, hr_max, cad_sum, cad_n, p_sum, p_n, p_max = 0, 0, 0, 0, 0, 0, 0, 0
  local cad_div = s.sport == "cycling" and 1 or 2 -- running/walking cadence is strides per minute in FIT
  for _, x in ipairs(samples) do
    data("record", { [253] = x.t - FIT_EPOCH, [5] = math.floor((x.d or 0) * 100), [6] = u16((x.v or 0) / 3.6 * 1000),
      [3] = (x.hr and x.hr > 0) and u8(x.hr) or nil, [4] = x.c and u8(x.c / cad_div) or nil, [7] = x.p and u16(x.p) or nil })
    if x.hr and x.hr > 0 then hr_sum, hr_n, hr_max = hr_sum + x.hr, hr_n + 1, math.max(hr_max, x.hr) end
    if x.c and x.c > 0 then cad_sum, cad_n = cad_sum + x.c, cad_n + 1 end
    if x.p then p_sum, p_n, p_max = p_sum + x.p, p_n + 1, math.max(p_max, x.p) end
  end
  data("event", { [253] = t_end, [0] = 0, [1] = 4 })                    -- timer stop all
  data("lap", { [253] = t_end, [2] = t0, [7] = elapsed_ms, [8] = timer_ms, [9] = dist_cm, [0] = 9, [1] = 1,
    [25] = SPORT[s.sport] or 0 })
  data("session", { [253] = t_end, [2] = t0, [7] = elapsed_ms, [8] = timer_ms, [9] = dist_cm,
    [5] = SPORT[s.sport] or 0, [6] = SUB_SPORT[s.sport] or 0,
    [16] = hr_n > 0 and u8(hr_sum / hr_n) or nil, [17] = hr_n > 0 and u8(hr_max) or nil,
    [18] = cad_n > 0 and u8(cad_sum / cad_n / cad_div) or nil,
    [20] = p_n > 0 and u16(p_sum / p_n) or nil, [21] = p_n > 0 and u16(p_max) or nil,
    [11] = s.kcal and u16(s.kcal) or nil, [25] = 0, [26] = 1, [0] = 8, [1] = 1 })
  local tz = os.time() - os.time(os.date("!*t"))
  data("activity", { [253] = t_end, [0] = timer_ms, [1] = 1, [2] = 0, [3] = 26, [4] = 1, [5] = t_end + tz })

  local body = table.concat(out)
  local header = string.char(14, 0x20) .. le(2132, 2) .. le(#body, 4) .. ".FIT"
  header = header .. le(fit_crc(header), 2)
  local file = header .. body
  return file .. le(fit_crc(file), 2) -- file CRC covers header and records
end

-- ---------- TCX ----------
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end

function M.tcx(s)
  local sport = s.sport == "cycling" and "Biking" or (s.sport == "running" and "Running" or "Other")
  local samples = s.samples or {}
  local o = {}
  local function a(x) o[#o + 1] = x end
  a('<?xml version="1.0" encoding="UTF-8"?>')
  a('<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"'
    .. ' xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">')
  a('<Activities><Activity Sport="' .. sport .. '">')
  a('<Id>' .. iso(s.start) .. '</Id>')
  a('<Lap StartTime="' .. iso(s.start) .. '">')
  a(string.format('<TotalTimeSeconds>%.1f</TotalTimeSeconds><DistanceMeters>%.1f</DistanceMeters><Calories>%d</Calories>',
    s.elapsed or 0, s.distance or 0, math.floor(s.kcal or 0)))
  a('<Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>')
  for _, x in ipairs(samples) do
    local p = { '<Trackpoint><Time>' .. iso(x.t) .. '</Time>', string.format('<DistanceMeters>%.1f</DistanceMeters>', x.d or 0) }
    if x.hr and x.hr > 0 then p[#p + 1] = string.format('<HeartRateBpm><Value>%d</Value></HeartRateBpm>', math.floor(x.hr + 0.5)) end
    if s.sport == "cycling" and x.c then p[#p + 1] = string.format('<Cadence>%d</Cadence>', math.floor(x.c + 0.5)) end
    local ext = { string.format('<ns3:Speed>%.3f</ns3:Speed>', (x.v or 0) / 3.6) }
    if x.p then ext[#ext + 1] = string.format('<ns3:Watts>%d</ns3:Watts>', math.floor(x.p + 0.5)) end
    if s.sport ~= "cycling" and x.c then ext[#ext + 1] = string.format('<ns3:RunCadence>%d</ns3:RunCadence>', math.floor(x.c / 2 + 0.5)) end
    p[#p + 1] = '<Extensions><ns3:TPX>' .. table.concat(ext) .. '</ns3:TPX></Extensions></Trackpoint>'
    a(table.concat(p))
  end
  a('</Track></Lap>')
  a('<Notes>Recorded with OmniPlay' .. (s.device and (' on ' .. s.device:gsub("[<>&]", "")) or "") .. ' (indoor)</Notes>')
  a('</Activity></Activities></TrainingCenterDatabase>')
  return table.concat(o, "\n")
end

return M
