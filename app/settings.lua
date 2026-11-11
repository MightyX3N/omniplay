-- The player's settings, saved as JSON in OmniPlay's save folder.
local json = require("lib.json")
local M = { file = "settings.json" }

local LOOKS = {}
for _, g in ipairs({ "male", "female" }) do for c = 1, 3 do LOOKS[#LOOKS + 1] = { gender = g, char = c } end end
M.LOOKS = LOOKS

-- shirt colours to pick from (bright, easy to tell apart in a race)
M.SHIRTS = {
  { 0.16, 0.78, 0.75 }, { 1.0, 0.59, 0.16 }, { 0.59, 0.35, 0.90 }, { 0.35, 0.78, 0.31 },
  { 0.92, 0.25, 0.30 }, { 0.20, 0.55, 0.95 }, { 1.0, 0.85, 0.20 }, { 0.95, 0.45, 0.75 },
}

local function defaults()
  return {
    allow_hills = true,
    allow_belt = false,
    max_belt_kmh = 4,
    look = 1,       -- index into LOOKS
    outfit = 1,     -- 1..3
    shirt = M.SHIRTS[love.math.random(#M.SHIRTS)],
    devices = {},   -- addr -> {name, kind}: reconnected at start
  }
end

function M.load()
  M.data = defaults()
  local s = love.filesystem.read(M.file)
  if s then
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then for k, v in pairs(t) do M.data[k] = v end end
  end
  if type(M.data.devices) ~= "table" then M.data.devices = {} end
  return M.data
end

function M.save() love.filesystem.write(M.file, json.encode(M.data)) end

function M.remember(addr, name, kind)
  local d = M.data.devices[addr]
  if d and d.name == name and d.kind == kind then return end
  M.data.devices[addr] = { name = name, kind = kind }
  M.save()
end
function M.forget(addr) M.data.devices[addr] = nil; M.save() end

function M.look()
  local l = LOOKS[M.data.look] or LOOKS[1]
  return l.gender, l.char, M.data.outfit
end

-- push the limits the player chose into the SDK session
function M.apply(op)
  op.allow_hills = M.data.allow_hills
  op.allow_belt = M.data.allow_belt
  op.max_belt_kmh = M.data.max_belt_kmh
end

return M
