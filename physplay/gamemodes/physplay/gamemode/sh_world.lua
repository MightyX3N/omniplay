-- PhysPlay world: terrain, roads, routes and riding physics. Pure Lua math (no engine types),
-- shared by server and client. Coordinates are metres: x east, y north, z up.
-- Physics and route data are ported from OpenRadlr (AGPL-3.0, github.com/Lethonium/OpenRadlr).
PP = PP or {}
PP.U = 39.37            -- Source units per metre
PP.LANE_W = 2.0         -- metres per lane (OpenRadlr uses 1.4; wider reads better at GMod's scale)
PP.SHOULDER = 0.8

-- ---------- base64 ----------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64decode(s)
  if util and util.Base64Decode then return util.Base64Decode(s) end
  local map = {}
  for i = 1, 64 do map[B64:byte(i)] = i - 1 end
  local out, n, bits = {}, 0, 0
  for i = 1, #s do
    local v = map[s:byte(i)]
    if v then
      n, bits = n * 64 + v, bits + 6
      if bits >= 8 then
        bits = bits - 8
        local b = math.floor(n / 2 ^ bits)
        out[#out + 1] = string.char(b)
        n = n - b * 2 ^ bits
      end
    end
  end
  return table.concat(out)
end
PP._b64decode = b64decode

-- ---------- loading ----------
-- load(name) returns what data/<name> returns (include on GMod, loadfile in tests)
function PP.LoadData(load)
  local index = load("index.lua")
  local meta = load(index.map .. ".lua")
  local parts = {}
  for i = 1, meta.heights do parts[i] = load(index.map .. "_heights_" .. i .. ".lua") end
  local raw = b64decode(table.concat(parts))
  local count = meta.columns * meta.rows
  local h = {}
  for i = 0, count - 1 do
    local lo, hi = raw:byte(i * 2 + 1, i * 2 + 2)
    local v = (hi or 0) * 256 + (lo or 0)
    if v >= 32768 then v = v - 65536 end
    h[i] = v * meta.scale
  end
  meta.h = h
  local roads = {}
  for i = 1, meta.roads do
    for _, r in ipairs(load(index.map .. "_roads_" .. i .. ".lua")) do roads[#roads + 1] = r end
  end
  meta.road_list = roads
  PP.map = meta
  PP.routes, PP.route_ids = {}, {}
  for _, id in ipairs(index.routes) do
    PP.routes[id] = PP.BuildRoute(load("route_" .. id:gsub("%-", "_") .. ".lua"))
    PP.route_ids[#PP.route_ids + 1] = id
  end
end

-- ---------- terrain ----------
function PP.GridHeight(c, r)
  local m = PP.map
  c = math.max(0, math.min(m.columns - 1, c))
  r = math.max(0, math.min(m.rows - 1, r))
  return m.h[r * m.columns + c]
end

-- bilinear height at (x, y), same as the drawn mesh before road cuts
function PP.HeightAt(x, y)
  local m = PP.map
  local u = math.max(0, math.min(m.columns - 1.0001, (x - m.x0) / m.cell))
  local v = math.max(0, math.min(m.rows - 1.0001, (y - m.y0) / m.cell))
  local c, r = math.floor(u), math.floor(v)
  local fu, fv = u - c, v - r
  local a, b = PP.GridHeight(c, r), PP.GridHeight(c + 1, r)
  local d, e = PP.GridHeight(c, r + 1), PP.GridHeight(c + 1, r + 1)
  return (a + (b - a) * fu) * (1 - fv) + (d + (e - d) * fu) * fv
end

-- ---------- routes ----------
local ROUTE = {}
ROUTE.__index = ROUTE

function PP.BuildRoute(data)
  local self = setmetatable({ id = data.id, name = data.name, description = data.description, loop = data.loop,
    lanes = data.lanes or 4, markers = data.markers or {}, zones = data.zones or {}, x = {}, y = {}, z = {}, cum = {} }, ROUTE)
  local p = data.p
  for i = 1, #p, 3 do
    local n = #self.x + 1
    self.x[n], self.y[n], self.z[n] = p[i], p[i + 1], p[i + 2]
  end
  -- a loop closes back to the first point
  if self.loop then
    local n = #self.x
    local dx, dy = self.x[1] - self.x[n], self.y[1] - self.y[n]
    if dx * dx + dy * dy > 0.25 then self.x[n + 1], self.y[n + 1], self.z[n + 1] = self.x[1], self.y[1], self.z[1] end
  end
  local d = 0
  self.cum[1] = 0
  for i = 2, #self.x do
    local dx, dy, dz = self.x[i] - self.x[i - 1], self.y[i] - self.y[i - 1], self.z[i] - self.z[i - 1]
    d = d + math.sqrt(dx * dx + dy * dy + dz * dz)
    self.cum[i] = d
  end
  self.length = d
  self.climb = 0
  for i = 2, #self.z do self.climb = self.climb + math.max(0, self.z[i] - self.z[i - 1]) end
  self.half_width = self.lanes * PP.LANE_W / 2 + PP.SHOULDER
  return self
end

function ROUTE:Wrap(d)
  if self.loop then return d % self.length end
  return math.max(0, math.min(self.length, d))
end

-- index of the segment containing distance d (binary search)
function ROUTE:Seg(d)
  local lo, hi = 1, #self.cum - 1
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if self.cum[mid] <= d then lo = mid else hi = mid - 1 end
  end
  return lo
end

-- position, unit heading (dx, dy) and grade (%) at distance d
function ROUTE:At(d)
  d = self:Wrap(d)
  local i = self:Seg(d)
  local seg = self.cum[i + 1] - self.cum[i]
  local t = seg > 0 and (d - self.cum[i]) / seg or 0
  local x = self.x[i] + (self.x[i + 1] - self.x[i]) * t
  local y = self.y[i] + (self.y[i + 1] - self.y[i]) * t
  local z = self.z[i] + (self.z[i + 1] - self.z[i]) * t
  local hx, hy = self.x[i + 1] - self.x[i], self.y[i + 1] - self.y[i]
  local hl = math.sqrt(hx * hx + hy * hy)
  if hl > 0 then hx, hy = hx / hl, hy / hl else hx, hy = 1, 0 end
  return x, y, z, hx, hy
end

-- smoothed heading (looks ahead and behind so turns don't snap)
function ROUTE:Heading(d, span)
  span = span or 6
  local x1, y1 = self:At(d - span)
  local x2, y2 = self:At(d + span)
  local hx, hy = x2 - x1, y2 - y1
  local hl = math.sqrt(hx * hx + hy * hy)
  if hl < 1e-6 then local _, _, _, a, b = self:At(d) return a, b end
  return hx / hl, hy / hl
end

-- grade in % over +-span metres (smooth enough for a trainer)
function ROUTE:Grade(d, span)
  span = span or 15
  local _, _, z1 = self:At(d - span)
  local _, _, z2 = self:At(d + span)
  return (z2 - z1) / (2 * span) * 100
end

-- world position of a rider: lane is 0..lanes-1 (fractions allowed), 0 = leftmost
function ROUTE:RiderPos(d, lane)
  local x, y, z = self:At(d)
  local hx, hy = self:Heading(d)
  local off = (lane - (self.lanes - 1) / 2) * PP.LANE_W
  -- right-hand vector of heading (hx, hy) is (hy, -hx)
  return x + hy * off, y - hx * off, z, hx, hy
end

function ROUTE:ZoneAt(d, kind)
  for _, z in ipairs(self.zones) do
    if z.type == kind and d >= z.from and d <= z.to then return true end
  end
  return false
end

-- ---------- physics (OpenRadlr sim/physics.rs) ----------
PP.PHYS = { crr = 0.005, cda = 0.40, cda_ref_kg = 75, rho = 1.225, bike_kg = 10, min_v = 1.0, max_v = 30, g = 9.80665 }

function PP.Cda(rider_kg)
  local p = PP.PHYS
  local m = math.max(30, math.min(200, rider_kg))
  return p.cda * (m / p.cda_ref_kg) ^ (2 / 3)
end

-- new speed (m/s) after dt seconds
function PP.Step(v, watts, grade, rider_kg, cda_factor, dt)
  local p = PP.PHYS
  local mass = rider_kg + p.bike_kg
  local th = math.atan(grade / 100)
  v = math.max(0, v)
  local prop = math.max(0, watts) / math.max(v, p.min_v)
  local grav = mass * p.g * math.sin(th)
  local roll = (v > 0 or prop > 0) and mass * p.g * p.crr * math.cos(th) or 0
  local drag = 0.5 * p.rho * PP.Cda(rider_kg) * (cda_factor or 1) * v * v
  local a = (prop - grav - roll - drag) / mass
  return math.max(0, math.min(p.max_v, v + a * dt))
end
