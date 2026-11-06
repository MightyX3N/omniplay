-- Device explorer report: turns the helper's raw lines (service/char/read/sub/notify)
-- into a readable report, naming standard UUIDs and decoding FTMS capabilities.
local bit = require("bit")
local band, lshift = bit.band, bit.lshift

local M = {}

local NAMES = {
  ["1800"] = "Generic Access", ["1801"] = "Generic Attribute", ["180A"] = "Device Information",
  ["180D"] = "Heart Rate", ["180F"] = "Battery", ["1814"] = "Running Speed and Cadence",
  ["1816"] = "Cycling Speed and Cadence", ["1818"] = "Cycling Power", ["1826"] = "Fitness Machine (FTMS)",
  ["2A00"] = "Device Name", ["2A01"] = "Appearance", ["2A19"] = "Battery Level",
  ["2A24"] = "Model Number", ["2A25"] = "Serial Number", ["2A26"] = "Firmware Revision",
  ["2A27"] = "Hardware Revision", ["2A28"] = "Software Revision", ["2A29"] = "Manufacturer Name",
  ["2A37"] = "Heart Rate Measurement", ["2A53"] = "RSC Measurement", ["2A5B"] = "CSC Measurement",
  ["2A63"] = "Cycling Power Measurement", ["2A65"] = "Cycling Power Feature",
  ["2ACC"] = "FTMS Feature", ["2ACD"] = "Treadmill Data", ["2ACE"] = "Cross Trainer Data",
  ["2AD1"] = "Rower Data", ["2AD2"] = "Indoor Bike Data", ["2AD3"] = "Training Status",
  ["2AD4"] = "Supported Speed Range", ["2AD5"] = "Supported Inclination Range",
  ["2AD6"] = "Supported Resistance Range", ["2AD8"] = "Supported Power Range",
  ["2AD9"] = "FTMS Control Point", ["2ADA"] = "Fitness Machine Status",
  ["FFF0"] = "Vendor service (FFF0)",
}
local TEXT = { ["2A00"] = true, ["2A24"] = true, ["2A25"] = true, ["2A26"] = true, ["2A27"] = true, ["2A28"] = true, ["2A29"] = true }

local MACHINE_FEATURES = { [0] = "average speed", "cadence", "total distance", "inclination", "elevation gain", "pace",
  "step count", "resistance level", "stride count", "expended energy", "heart rate", "metabolic equivalent",
  "elapsed time", "remaining time", "power", "force on belt", "user data retention" }
local TARGET_FEATURES = { [0] = "speed", "inclination", "resistance", "power", "heart rate", "expended energy",
  "step number", "stride number", "distance", "training time", "time in 2 HR zones", "time in 3 HR zones",
  "time in 5 HR zones", "indoor bike simulation (hills)", "wheel circumference", "spin down", "cadence" }

function M.short(uuid)
  local s = uuid:match("^0000(%x%x%x%x)%-0000%-1000%-8000%-00805f9b34fb$")
  return s and s:upper() or uuid
end

local function bytes(hex)
  local t = {}
  for h in (hex or ""):gmatch("%x%x") do t[#t + 1] = tonumber(h, 16) end
  return t
end
local function u16(b, i) return (b[i] or 0) + lshift(b[i + 1] or 0, 8) end
local function s16(b, i) local v = u16(b, i); return v >= 0x8000 and v - 0x10000 or v end
local function u32(b, i) return u16(b, i) + (b[i + 2] or 0) * 65536 + (b[i + 3] or 0) * 16777216 end

local function bits(v, names)
  local out = {}
  for i = 0, 31 do
    if band(v, lshift(1, i)) ~= 0 and names[i] then out[#out + 1] = names[i] end
  end
  return #out > 0 and table.concat(out, ", ") or "none"
end

local function props_str(p)
  local t = {}
  if band(p, 0x02) ~= 0 then t[#t + 1] = "read" end
  if band(p, 0x04) ~= 0 then t[#t + 1] = "write-no-response" end
  if band(p, 0x08) ~= 0 then t[#t + 1] = "write" end
  if band(p, 0x10) ~= 0 then t[#t + 1] = "notify" end
  if band(p, 0x20) ~= 0 then t[#t + 1] = "indicate" end
  return table.concat(t, ", ")
end

-- Decode the most useful fields of an FTMS Indoor Bike Data notification.
function M.indoor_bike(b)
  local flags, i, out = u16(b, 1), 3, {}
  local function has(n) return band(flags, lshift(1, n)) ~= 0 end
  if not has(0) then out[#out + 1] = string.format("speed %.2f km/h", u16(b, i) / 100); i = i + 2 end
  if has(1) then i = i + 2 end
  if has(2) then out[#out + 1] = string.format("cadence %.1f rpm", u16(b, i) / 2); i = i + 2 end
  if has(3) then i = i + 2 end
  if has(4) then i = i + 3 end
  if has(5) then out[#out + 1] = "resistance " .. s16(b, i); i = i + 2 end
  if has(6) then out[#out + 1] = "power " .. s16(b, i) .. " W"; i = i + 2 end
  return table.concat(out, ", ")
end

local function decode_read(id, b, hex)
  if TEXT[id] then
    local s = {}
    for _, v in ipairs(b) do if v >= 32 and v < 127 then s[#s + 1] = string.char(v) end end
    return '"' .. table.concat(s) .. '"'
  elseif id == "2A19" then return (b[1] or 0) .. " %"
  elseif id == "2ACC" then
    return "machine: " .. bits(u32(b, 1), MACHINE_FEATURES) .. " | can set: " .. bits(u32(b, 5), TARGET_FEATURES)
  elseif id == "2AD6" then return string.format("%.1f to %.1f, step %.1f", s16(b, 1) / 10, s16(b, 3) / 10, u16(b, 5) / 10)
  elseif id == "2AD8" then return string.format("%d to %d W, step %d", s16(b, 1), s16(b, 3), u16(b, 5))
  elseif id == "2AD4" then return string.format("%.2f to %.2f km/h", u16(b, 1) / 100, u16(b, 3) / 100)
  elseif id == "2AD5" then return string.format("%.1f to %.1f %%", s16(b, 1) / 10, s16(b, 3) / 10)
  end
  return hex
end

-- Build the report. Returns a list of lines and a summary table.
function M.report(raw, device_name)
  local lines, summary = {}, { ftms = false, kind = nil, hills = false, resistance = false, power = false }
  local function add(s) lines[#lines + 1] = s end
  add("Device: " .. tostring(device_name))
  for line in raw:gmatch("[^\n]+") do
    local kind, rest = line:match("^(%S+)%s*(.*)$")
    if kind == "service" then
      local id = M.short(rest)
      if id == "1826" then summary.ftms = true end
      add("")
      add("[" .. id .. "] " .. (NAMES[id] or "Unknown service"))
    elseif kind == "char" then
      local uuid, p = rest:match("^(%S+) props (%x+)")
      local id = M.short(uuid)
      if id == "2AD2" then summary.kind = "bike" elseif id == "2ACD" then summary.kind = "treadmill"
      elseif id == "2ACE" then summary.kind = "cross trainer" elseif id == "2AD1" then summary.kind = "rower" end
      add("  " .. id .. "  " .. (NAMES[id] or "Unknown") .. "  (" .. props_str(tonumber(p, 16)) .. ")")
    elseif kind == "read" then
      local uuid, val = rest:match("^(%S+) (.*)$")
      local id = M.short(uuid)
      if val:match("^failed") then add("      read " .. val)
      else
        local b = bytes(val)
        if id == "2ACC" then
          local t = u32(b, 5)
          summary.hills = band(t, lshift(1, 13)) ~= 0
          summary.resistance = band(t, lshift(1, 2)) ~= 0
          summary.power = band(t, lshift(1, 3)) ~= 0
        end
        add("      = " .. decode_read(id, b, val))
      end
    elseif kind == "sub" then
      local uuid, ok = rest:match("^(%S+) (%S+)")
      if ok ~= "ok" then add("  subscribe to " .. M.short(uuid) .. " failed") end
    elseif kind == "notify" then
      local uuid, val = rest:match("^(%S+) (.*)$")
      local id = M.short(uuid)
      local dec = id == "2AD2" and ("  ->  " .. M.indoor_bike(bytes(val))) or ""
      add("  live " .. id .. ": " .. val .. dec)
    elseif kind == "listening" then
      add("")
      add("Listening for live data for " .. math.floor(tonumber(rest) / 1000) .. " s. Pedal, walk or run now.")
    elseif kind == "error" then
      add("ERROR: " .. rest)
    end
  end
  return lines, summary
end

function M.summary_text(s)
  if not s.ftms then return "No FTMS service: this device uses its own protocol, so it needs a dedicated driver." end
  local t = "FTMS " .. (s.kind or "machine") .. ". "
  if s.hills then t = t .. "Supports hill simulation."
  elseif s.resistance then t = t .. "No hill simulation, but resistance can be set (hills via resistance level)."
  elseif s.power then t = t .. "No hill simulation; power target (ERG) only."
  else t = t .. "No resistance control reported: data only." end
  return t
end

return M
