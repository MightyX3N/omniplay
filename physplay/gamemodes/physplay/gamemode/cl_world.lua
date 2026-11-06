-- PhysPlay client world: draws the island (terrain, sea, roads, trees, villages, arches) and the
-- riders. The GMod map is hidden; everything is drawn relative to the camera (floating origin),
-- so the world can be many kilometres across.
local U = PP.U
local W = {}
PP.W = W

W.VIEW = 5600            -- metres drawn
W.PROP_VIEW = 2600       -- trees and houses
W.RIDER_VIEW = 500
W.SKY = Color(169, 207, 233)
local CH = 16            -- terrain cells per chunk
local SUN = { 0.42, 0.33, 0.845 }

local mat = CreateMaterial("physplay_vc", "UnlitGeneric", {
  ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1 })
local mat_frame = CreateMaterial("physplay_frame", "UnlitGeneric", {
  ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1 })

-- ---------- small helpers ----------
local function smooth(a, b, x) local t = math.Clamp((x - a) / (b - a), 0, 1) return t * t * (3 - 2 * t) end
local function rng(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647 return (s - 1) / 2147483646 end
end
local function hash2(x, y)
  local n = math.sin(x * 127.1 + y * 311.7) * 43758.5453
  return n - math.floor(n)
end
local function vnoise(x, y)
  local xi, yi = math.floor(x), math.floor(y)
  local fx, fy = x - xi, y - yi
  fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
  local a, b = hash2(xi, yi), hash2(xi + 1, yi)
  local c, d = hash2(xi, yi + 1), hash2(xi + 1, yi + 1)
  return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
end
local function shade(nx, ny, nz)
  local l = math.sqrt(nx * nx + ny * ny + nz * nz)
  if l < 1e-9 then return 1 end
  local d = (nx * SUN[1] + ny * SUN[2] + nz * SUN[3]) / l
  return 0.58 + 0.48 * math.max(0, d)
end

-- triangle buffer: x,y,z (metres, local), r,g,b per vertex
local function tri(buf, ax, ay, az, bx, by, bz, cx, cy, cz, r, g, b, flat)
  local s = 1
  if not flat then
    local ux, uy, uz = bx - ax, by - ay, bz - az
    local vx, vy, vz = cx - ax, cy - ay, cz - az
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    if nz < 0 then nx, ny, nz = -nx, -ny, -nz end
    s = shade(nx, ny, nz)
  end
  r, g, b = math.min(255, r * s), math.min(255, g * s), math.min(255, b * s)
  local n = #buf
  buf[n + 1], buf[n + 2], buf[n + 3], buf[n + 4], buf[n + 5], buf[n + 6] = ax, ay, az, r, g, b
  buf[n + 7], buf[n + 8], buf[n + 9], buf[n + 10], buf[n + 11], buf[n + 12] = bx, by, bz, r, g, b
  buf[n + 13], buf[n + 14], buf[n + 15], buf[n + 16], buf[n + 17], buf[n + 18] = cx, cy, cz, r, g, b
end
local function quad(buf, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, r, g, b, flat)
  tri(buf, ax, ay, az, bx, by, bz, cx, cy, cz, r, g, b, flat)
  tri(buf, ax, ay, az, cx, cy, cz, dx, dy, dz, r, g, b, flat)
end

-- builds IMeshes from a buffer (split under the vertex limit); origin in metres
local MAX_TRIS = 10000
local function build_meshes(buf, ox, oy, oz)
  local out = {}
  local ntri = #buf / 18
  local start = 0
  while start < ntri do
    local count = math.min(MAX_TRIS, ntri - start)
    local m = Mesh(mat)
    mesh.Begin(m, MATERIAL_TRIANGLES, count)
    for i = start * 18, (start + count) * 18 - 1, 6 do
      mesh.Position(Vector((buf[i + 1] - ox) * U, (buf[i + 2] - oy) * U, (buf[i + 3] - oz) * U))
      mesh.Color(buf[i + 4], buf[i + 5], buf[i + 6], 255)
      mesh.AdvanceVertex()
    end
    mesh.End()
    out[#out + 1] = m
    start = start + count
  end
  return { meshes = out, ox = ox, oy = oy, oz = oz }
end

-- ---------- box / roof / cone emitters (world metres) ----------
local function box(buf, x, y, z, yaw, sx, sy, sz, r, g, b)
  local c, s = math.cos(yaw), math.sin(yaw)
  local function p(lx, ly) return x + lx * c - ly * s, y + lx * s + ly * c end
  local hx, hy = sx / 2, sy / 2
  local ax, ay = p(-hx, -hy)
  local bx, by = p(hx, -hy)
  local cx, cy = p(hx, hy)
  local dx, dy = p(-hx, hy)
  local top = z + sz
  local function side(x1, y1, x2, y2)
    local nx, ny = y2 - y1, -(x2 - x1)
    local sh = shade(nx, ny, 0.15)
    quad(buf, x1, y1, z, x2, y2, z, x2, y2, top, x1, y1, top, r * sh, g * sh, b * sh, true)
  end
  side(ax, ay, bx, by) side(bx, by, cx, cy) side(cx, cy, dx, dy) side(dx, dy, ax, ay)
  quad(buf, ax, ay, top, bx, by, top, cx, cy, top, dx, dy, top, r, g, b)
end

local function roof(buf, x, y, z, yaw, sx, sy, h, r, g, b)
  local c, s = math.cos(yaw), math.sin(yaw)
  local function p(lx, ly) return x + lx * c - ly * s, y + lx * s + ly * c end
  local hx, hy = sx / 2 + 0.4, sy / 2 + 0.4
  local ax, ay = p(-hx, -hy) local bx, by = p(hx, -hy)
  local cx, cy = p(hx, hy) local dx, dy = p(-hx, hy)
  local ex, ey = p(-hx, 0) local fx, fy = p(hx, 0)
  local top = z + h
  quad(buf, ax, ay, z, bx, by, z, fx, fy, top, ex, ey, top, r, g, b)
  quad(buf, dx, dy, z, cx, cy, z, fx, fy, top, ex, ey, top, r, g, b)
  tri(buf, ax, ay, z, dx, dy, z, ex, ey, top, r * 0.9, g * 0.9, b * 0.9)
  tri(buf, bx, by, z, cx, cy, z, fx, fy, top, r * 0.9, g * 0.9, b * 0.9)
end

local function cone(buf, x, y, z, rad, h, sides, r, g, b)
  for i = 0, sides - 1 do
    local a1, a2 = i / sides * math.pi * 2, (i + 1) / sides * math.pi * 2
    tri(buf, x + math.cos(a1) * rad, y + math.sin(a1) * rad, z, x + math.cos(a2) * rad, y + math.sin(a2) * rad, z,
      x, y, z + h, r, g, b)
  end
end

local function tree(buf, x, y, z, size, kind, rnd)
  local trunk_h = size * 0.28
  box(buf, x, y, z - 0.5, rnd * 3, size * 0.07, size * 0.07, trunk_h + 0.5, 92, 66, 44)
  local gr, gg, gb = 46 + rnd * 20, 104 + rnd * 30, 44 + rnd * 12
  if kind == 1 then -- conifer: two stacked cones
    cone(buf, x, y, z + trunk_h * 0.6, size * 0.3, size * 0.55, 7, gr * 0.8, gg * 0.85, gb)
    cone(buf, x, y, z + trunk_h * 0.6 + size * 0.35, size * 0.22, size * 0.45, 7, gr * 0.8, gg * 0.85, gb)
  else -- broadleaf: a diamond blob
    local mid = z + trunk_h + size * 0.3
    for i = 0, 6 do
      local a1, a2 = i / 7 * math.pi * 2, (i + 1) / 7 * math.pi * 2
      local rr = size * 0.34
      local x1, y1, x2, y2 = x + math.cos(a1) * rr, y + math.sin(a1) * rr, x + math.cos(a2) * rr, y + math.sin(a2) * rr
      tri(buf, x1, y1, mid, x2, y2, mid, x, y, mid + size * 0.42, gr, gg, gb)
      tri(buf, x1, y1, mid, x2, y2, mid, x, y, mid - size * 0.28, gr * 0.85, gg * 0.85, gb * 0.85)
    end
  end
end

-- ---------- terrain cut around the roads ----------
local road_hash, HASH = {}, 30
local function ckey(cx, cy) return (cx + 20000) * 100000 + (cy + 20000) end
local function hkey(x, y) return ckey(math.floor(x / HASH), math.floor(y / HASH)) end
local function add_road_point(x, y, z)
  local k = hkey(x, y)
  local t = road_hash[k]
  if not t then t = {} road_hash[k] = t end
  t[#t + 1] = x t[#t + 1] = y t[#t + 1] = z
end
-- nearest road point: distance, road height
local function nearest_road(x, y, radius)
  local best, bz = radius * radius, nil
  local cx, cy = math.floor(x / HASH), math.floor(y / HASH)
  local reach = math.ceil(radius / HASH)
  for i = -reach, reach do
    for j = -reach, reach do
      local t = road_hash[ckey(cx + i, cy + j)]
      if t then
        for k = 1, #t, 3 do
          local dx, dy = t[k] - x, t[k + 1] - y
          local d = dx * dx + dy * dy
          if d < best then best, bz = d, t[k + 2] end
        end
      end
    end
  end
  return math.sqrt(best), bz
end
W.nearest_road = nearest_road

local carved = {}
local function prepare_terrain()
  local m = PP.map
  for _, rd in ipairs(m.road_list) do
    local p = rd.p
    for i = 1, #p - 3, 3 do
      local x1, y1, z1, x2, y2, z2 = p[i], p[i + 1], p[i + 2], p[i + 3], p[i + 4], p[i + 5]
      local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
      local steps = math.max(1, math.ceil(len / 6))
      for s = 0, steps - 1 do
        local t = s / steps
        add_road_point(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, z1 + (z2 - z1) * t)
      end
    end
    add_road_point(p[#p - 2], p[#p - 1], p[#p])
  end
  for r = 0, m.rows - 1 do
    for c = 0, m.columns - 1 do
      local i = r * m.columns + c
      local h = m.h[i]
      local x, y = m.x0 + c * m.cell, m.y0 + r * m.cell
      local d, rz = nearest_road(x, y, 70)
      if rz then
        local base = rz - 0.45
        local cut = math.Clamp(h, base - 1.6, base)    -- under the road: just below it
        if d < 26 then h = cut else h = cut + (h - cut) * smooth(26, 70, d) end
      end
      carved[i] = h
    end
  end
end

local function CH_h(c, r)
  local m = PP.map
  c = math.Clamp(c, 0, m.columns - 1) r = math.Clamp(r, 0, m.rows - 1)
  return carved[r * m.columns + c]
end
function W.GroundAt(x, y)
  local m = PP.map
  local u = math.Clamp((x - m.x0) / m.cell, 0, m.columns - 1.0001)
  local v = math.Clamp((y - m.y0) / m.cell, 0, m.rows - 1.0001)
  local c, r = math.floor(u), math.floor(v)
  local fu, fv = u - c, v - r
  local a, b, d, e = CH_h(c, r), CH_h(c + 1, r), CH_h(c, r + 1), CH_h(c + 1, r + 1)
  return (a + (b - a) * fu) * (1 - fv) + (d + (e - d) * fu) * fv
end

local function ground_color(x, y, h, nx, ny, nz)
  local n = vnoise(x / 180, y / 180) * 0.6 + vnoise(x / 37, y / 37) * 0.4
  local r, g, b = 92 + n * 26, 142 + n * 30, 58 + n * 12
  local slope = 1 - nz
  if slope > 0.18 then local t = smooth(0.18, 0.38, slope) r, g, b = r + (126 - r) * t, g + (120 - g) * t, b + (106 - b) * t end
  if h > 230 then local t = smooth(230, 300, h) r, g, b = r + (150 - r) * t, g + (148 - g) * t, b + (138 - b) * t end
  if h < 2.2 then local t = smooth(2.2, 0.6, h) r, g, b = r + (216 - r) * t, g + (202 - g) * t, b + (152 - b) * t end
  return r, g, b
end

-- ---------- chunks ----------
W.chunks = {}
local function chunk_terrain(ch)
  local m = PP.map
  local buf = {}
  local c0, r0 = ch.c0, ch.r0
  local c1, r1 = math.min(m.columns - 1, c0 + CH), math.min(m.rows - 1, r0 + CH)
  local cell = m.cell
  local vx, vy, vz, vr, vg, vb = {}, {}, {}, {}, {}, {}
  for r = r0, r1 do
    for c = c0, c1 do
      local h = CH_h(c, r)
      local gx = (CH_h(c + 1, r) - CH_h(c - 1, r)) / (2 * cell)
      local gy = (CH_h(c, r + 1) - CH_h(c, r - 1)) / (2 * cell)
      local nl = math.sqrt(gx * gx + gy * gy + 1)
      local nx, ny, nz = -gx / nl, -gy / nl, 1 / nl
      local x, y = m.x0 + c * cell, m.y0 + r * cell
      local cr, cg, cb = ground_color(x, y, h, nx, ny, nz)
      local s = shade(nx, ny, nz)
      local k = r * 1000 + c
      vx[k], vy[k], vz[k] = x, y, h
      vr[k], vg[k], vb[k] = math.min(255, cr * s), math.min(255, cg * s), math.min(255, cb * s)
    end
  end
  local n = 0
  local function v(k)
    buf[n + 1], buf[n + 2], buf[n + 3], buf[n + 4], buf[n + 5], buf[n + 6] = vx[k], vy[k], vz[k], vr[k], vg[k], vb[k]
    n = n + 6
  end
  for r = r0, r1 - 1 do
    for c = c0, c1 - 1 do
      local a, b, cc, d = r * 1000 + c, r * 1000 + c + 1, (r + 1) * 1000 + c + 1, (r + 1) * 1000 + c
      v(a) v(b) v(cc) v(a) v(cc) v(d)
    end
  end
  return build_meshes(buf, m.x0 + c0 * cell, m.y0 + r0 * cell, 0)
end

local function chunk_props(ch)
  local m = PP.map
  local buf = {}
  local size = CH * m.cell
  local ox, oy = m.x0 + ch.c0 * m.cell, m.y0 + ch.r0 * m.cell
  local rnd = rng(ch.c0 * 7919 + ch.r0 * 104729 + 17)
  for _ = 1, 260 do
    local x, y = ox + rnd() * size, oy + rnd() * size
    local h = W.GroundAt(x, y)
    if h > 2.5 then
      local forest = vnoise(x / 700, y / 700) * 0.7 + vnoise(x / 160, y / 160) * 0.3
      local keep = 0.04 + 0.85 * smooth(0.5, 0.68, forest)
      if rnd() < keep then
        local d = nearest_road(x, y, 14)
        local slope = math.abs(W.GroundAt(x + 4, y) - h) + math.abs(W.GroundAt(x, y + 4) - h)
        if d >= 13 and slope < 3.2 then
          tree(buf, x, y, h, 8 + rnd() * 9, (h > 120 or rnd() < 0.35) and 1 or 2, rnd())
        end
      end
    end
  end
  if #buf == 0 then return nil end
  return build_meshes(buf, ox, oy, 0)
end

local function setup_chunks()
  local m = PP.map
  for r0 = 0, m.rows - 2, CH do
    for c0 = 0, m.columns - 2, CH do
      local cx = m.x0 + (c0 + CH / 2) * m.cell
      local cy = m.y0 + (r0 + CH / 2) * m.cell
      W.chunks[#W.chunks + 1] = { c0 = c0, r0 = r0, cx = cx, cy = cy }
    end
  end
end

-- ---------- roads ----------
-- walks a polyline: returns sampler(s) -> x, y, z, hx, hy and total length
local function polyline(p)
  local cum, n = { 0 }, #p / 3
  for i = 2, n do
    local j = (i - 1) * 3
    cum[i] = cum[i - 1] + math.sqrt((p[j + 1] - p[j - 2]) ^ 2 + (p[j + 2] - p[j - 1]) ^ 2)
  end
  local seg = 1
  local function at(s)
    if s < cum[seg] then seg = 1 end
    while seg < n - 1 and cum[seg + 1] < s do seg = seg + 1 end
    local j = (seg - 1) * 3
    local L = cum[seg + 1] - cum[seg]
    local t = L > 0 and math.Clamp((s - cum[seg]) / L, 0, 1) or 0
    local hx, hy = p[j + 4] - p[j + 1], p[j + 5] - p[j + 2]
    local hl = math.sqrt(hx * hx + hy * hy)
    if hl > 0 then hx, hy = hx / hl, hy / hl else hx, hy = 1, 0 end
    return p[j + 1] + (p[j + 4] - p[j + 1]) * t, p[j + 2] + (p[j + 5] - p[j + 2]) * t, p[j + 3] + (p[j + 6] - p[j + 3]) * t, hx, hy
  end
  return at, cum[n]
end

local function road_strip(buf, at, len, s0, s1, off_a, off_b, lift, r, g, b, step)
  step = step or 3
  local s = s0
  local px, py, pz, phx, phy = at(s)
  while s < s1 do
    local sn = math.min(s1, s + step)
    local x, y, z, hx, hy = at(sn)
    -- average heading at both ends for smooth corners
    local ax, ay = (phx + hx) / 2, (phy + hy) / 2
    local al = math.sqrt(ax * ax + ay * ay)
    if al > 0 then ax, ay = ax / al, ay / al end
    quad(buf,
      px + phy * off_a, py - phx * off_a, pz + lift,
      px + phy * off_b, py - phx * off_b, pz + lift,
      x + hy * off_b, y - hx * off_b, z + lift,
      x + hy * off_a, y - hx * off_a, z + lift, r, g, b, true)
    px, py, pz, phx, phy = x, y, z, hx, hy
    s = sn
  end
end

W.roads = {}
local function build_roads()
  local lanes = 4
  local hw = lanes * PP.LANE_W / 2 + PP.SHOULDER
  for _, rd in ipairs(PP.map.road_list) do
    local at, len = polyline(rd.p)
    -- split into pieces so far-away road isn't drawn
    local piece = 400
    for s0 = 0, len, piece do
      local s1 = math.min(len, s0 + piece)
      local buf, lines = {}, {}
      road_strip(buf, at, len, s0, s1, -hw, hw, 0.12, 74, 77, 82, 4)
      road_strip(buf, at, len, s0, s1, -hw - 1.2, -hw, 0.06, 150, 140, 112, 4) -- gravel shoulders
      road_strip(buf, at, len, s0, s1, hw, hw + 1.2, 0.06, 150, 140, 112, 4)
      -- edge lines and dashed lane lines
      road_strip(lines, at, len, s0, s1, -hw + 0.5, -hw + 0.68, 0.16, 236, 238, 240, 4)
      road_strip(lines, at, len, s0, s1, hw - 0.68, hw - 0.5, 0.16, 236, 238, 240, 4)
      for k = 1, lanes - 1 do
        local off = -lanes * PP.LANE_W / 2 + k * PP.LANE_W
        local w = k == lanes / 2 and 0.16 or 0.1
        for d = math.ceil(s0 / 9) * 9, s1 - 3, 9 do
          road_strip(lines, at, len, d, d + 3, off - w, off + w, 0.16, 236, 238, 240, 3)
        end
      end
      local x, y, z = at((s0 + s1) / 2)
      W.roads[#W.roads + 1] = { body = build_meshes(buf, x, y, 0), lines = build_meshes(lines, x, y, 0), cx = x, cy = y }
    end
  end
end

-- ---------- route decorations (villages, forests, arches) ----------
W.route_props = {}
local function arch(buf, r, d, cr, cg, cb)
  local x, y, z, hx, hy = r:At(d)
  local hw = r.half_width + 0.8
  local lx, ly = x - hy * hw, y + hx * hw
  local rx, ry = x + hy * hw, y - hx * hw
  local yaw = math.atan2(hy, hx)
  box(buf, lx, ly, z, yaw, 0.5, 0.5, 6.2, 40, 44, 50)
  box(buf, rx, ry, z, yaw, 0.5, 0.5, 6.2, 40, 44, 50)
  -- banner across the road
  local bx, by = x, y
  box(buf, bx, by, z + 5.0, yaw + math.pi / 2, hw * 2 + 0.5, 0.4, 1.4, cr, cg, cb)
end

local function build_route_props(r)
  for _, b in ipairs(W.route_props) do for _, m in ipairs(b.meshes) do m:Destroy() end end
  W.route_props = {}
  local buf = {}
  local rnd = rng(#r.id * 9973 + 5)
  local hw = r.half_width
  local function flush()
    if #buf > 0 then
      local x, y = buf[1], buf[2]
      local b = build_meshes(buf, x, y, 0)
      b.cx, b.cy = x, y
      W.route_props[#W.route_props + 1] = b
      buf = {}
    end
  end
  arch(buf, r, 0, 198, 244, 50)
  for _, mk in ipairs(r.markers) do
    if mk.type == "sprint" then arch(buf, r, mk.d, 64, 170, 90) arch(buf, r, mk.d + (mk.len or 0), 64, 170, 90)
    elseif mk.type == "climb" then arch(buf, r, mk.d, 216, 90, 48) arch(buf, r, mk.d + (mk.len or 0), 216, 90, 48) end
  end
  flush()
  for _, zn in ipairs(r.zones) do
    if zn.type == "village" then
      local side = 1
      for d = zn.from, zn.to, 21 do
        side = -side
        local x, y, _, hx, hy = r:At(d)
        local off = (hw + 7 + rnd() * 5) * side
        local px, py = x + hy * off, y - hx * off
        local gz = W.GroundAt(px, py)
        local yaw = math.atan2(hy, hx)
        local sx, sy, sz = 8 + rnd() * 4, 7 + rnd() * 3, 5 + rnd() * 2.5
        local wall = ({ { 236, 228, 214 }, { 222, 206, 178 }, { 214, 150, 112 }, { 200, 208, 214 } })[1 + math.floor(rnd() * 4)]
        local rf = ({ { 156, 64, 48 }, { 96, 96, 104 }, { 120, 70, 50 } })[1 + math.floor(rnd() * 3)]
        box(buf, px, py, gz - 1, yaw, sx, sy, sz + 1, wall[1], wall[2], wall[3])
        roof(buf, px, py, gz + sz, yaw, sx, sy, 3.2, rf[1], rf[2], rf[3])
        if #buf > 18 * 6000 then flush() end
      end
    elseif zn.type == "forest" then
      for d = zn.from, zn.to, 5 do
        for _, side in ipairs({ -1, 1 }) do
          if rnd() < 0.75 then
            local x, y, _, hx, hy = r:At(d + rnd() * 5)
            local off = (hw + 4 + rnd() * 34) * side
            local px, py = x + hy * off, y - hx * off
            if nearest_road(px, py, hw + 3) >= hw + 3 then
              tree(buf, px, py, W.GroundAt(px, py), 9 + rnd() * 9, rnd() < 0.5 and 1 or 2, rnd())
            end
          end
        end
        if #buf > 18 * 9000 then flush() end
      end
    end
    flush()
  end
  -- cafés at the start points of the island
  for _, cf in ipairs(PP.map.cafes) do
    local d, _ = nearest_road(cf.x, cf.y, 60)
    local gz = W.GroundAt(cf.x + 18, cf.y + 18)
    box(buf, cf.x + 18, cf.y + 18, gz - 1, 0.3, 16, 11, 7.5, 240, 232, 216)
    roof(buf, cf.x + 18, cf.y + 18, gz + 6.5, 0.3, 16, 11, 3.6, 70, 120, 90)
  end
  flush()
end

-- ---------- bike ----------
local bike_mesh, wheel_mesh
local function build_bike()
  local fb, wb = {}, {}
  -- frame (x forward, y left, z up), metres; drawn white and tinted per rider
  local function tube(x1, z1, x2, z2, w, y)
    y = y or 0
    quad(fb, x1, y - w, z1, x2, y - w, z2, x2, y + w, z2, x1, y + w, z1, 255, 255, 255, true)
    quad(fb, x1, y, z1 - w, x2, y, z2 - w, x2, y, z2 + w, x1, y, z1 + w, 230, 230, 230, true)
  end
  local R = 0.34
  tube(-0.5, R, 0.02, 0.38, 0.025)       -- chainstay to bottom bracket
  tube(0.02, 0.38, -0.12, 0.92, 0.025)   -- seat tube
  tube(-0.5, R, -0.12, 0.92, 0.02)       -- seat stays
  tube(0.02, 0.38, 0.42, 0.9, 0.03)      -- down tube
  tube(-0.12, 0.9, 0.42, 0.92, 0.025)    -- top tube
  tube(0.42, 0.92, 0.52, R, 0.022)       -- fork
  tube(0.42, 0.92, 0.46, 1.04, 0.02)     -- stem
  tube(-0.22, 0.98, -0.02, 0.98, 0.04)   -- saddle
  quad(fb, 0.45, -0.22, 1.04, 0.5, -0.22, 1.04, 0.5, 0.22, 1.04, 0.45, 0.22, 1.04, 60, 60, 60, true) -- bars
  -- wheels: rings
  for _, wx in ipairs({ -0.5, 0.52 }) do
    local seg = 18
    for i = 0, seg - 1 do
      local a1, a2 = i / seg * math.pi * 2, (i + 1) / seg * math.pi * 2
      local x1, z1 = wx + math.cos(a1) * R, R + math.sin(a1) * R
      local x2, z2 = wx + math.cos(a2) * R, R + math.sin(a2) * R
      local x3, z3 = wx + math.cos(a1) * (R - 0.04), R + math.sin(a1) * (R - 0.04)
      local x4, z4 = wx + math.cos(a2) * (R - 0.04), R + math.sin(a2) * (R - 0.04)
      quad(wb, x1, 0.012, z1, x2, 0.012, z2, x4, 0.012, z4, x3, 0.012, z3, 28, 28, 30, true)
      quad(wb, x1, -0.012, z1, x2, -0.012, z2, x4, -0.012, z4, x3, -0.012, z3, 28, 28, 30, true)
      quad(wb, x1, -0.012, z1, x2, -0.012, z2, x2, 0.012, z2, x1, 0.012, z1, 20, 20, 22, true)
    end
    for i = 0, 5 do -- spokes
      local a = i / 6 * math.pi
      quad(wb, wx - math.cos(a) * R, 0, R - math.sin(a) * R, wx + math.cos(a) * R, 0, R + math.sin(a) * R,
        wx + math.cos(a) * R, 0.004, R + math.sin(a) * R, wx - math.cos(a) * R, 0.004, R - math.sin(a) * R, 170, 170, 175, true)
    end
  end
  bike_mesh = build_meshes(fb, 0, 0, 0).meshes[1]
  wheel_mesh = build_meshes(wb, 0, 0, 0).meshes[1]
end

-- ---------- riders ----------
-- Rig numbers: tune live with these convars, then tell us the values that look right.
local rig_x = CreateClientConVar("physplay_rig_x", "-0.2", true, false, "rider forward offset on the bike (m)")
local rig_z = CreateClientConVar("physplay_rig_z", "0.42", true, false, "rider height offset on the bike (m)")
local rig_lean = CreateClientConVar("physplay_rig_lean", "28", true, false, "forward lean (degrees)")
local rig_leg = CreateClientConVar("physplay_rig_leg", "22", true, false, "pedalling leg swing (degrees)")
local rig_axis = CreateClientConVar("physplay_rig_axis", "2", true, false, "bone axis for pedalling: 1 pitch, 2 yaw, 3 roll")
local SIT_SEQS = { "sit_rollercoaster", "sit", "drive_pd", "drive_jeep" }

W.models = {}
local function rider_model(idx, ply)
  local e = W.models[idx]
  local mdl = IsValid(ply) and ply:GetModel() or "models/player/kleiner.mdl"
  if IsValid(e) and e.mdl ~= mdl then e:Remove() e = nil end
  if not IsValid(e) then
    e = ClientsideModel(mdl, RENDERGROUP_OPAQUE)
    if not IsValid(e) then return nil end
    e.mdl = mdl
    e:SetNoDraw(true)
    e.bones = {
      spine = e:LookupBone("ValveBiped.Bip01_Spine1"),
      lt = e:LookupBone("ValveBiped.Bip01_L_Thigh"), lc = e:LookupBone("ValveBiped.Bip01_L_Calf"),
      rt = e:LookupBone("ValveBiped.Bip01_R_Thigh"), rc = e:LookupBone("ValveBiped.Bip01_R_Calf"),
    }
    e.crank = 0
    W.models[idx] = e
  end
  e.GetPlayerColor = function() return IsValid(ply) and ply:GetPlayerColor() or Vector(1, 1, 1) end
  return e
end

local function axis_angle(deg)
  local a = rig_axis:GetInt()
  if a == 1 then return Angle(deg, 0, 0) elseif a == 3 then return Angle(0, 0, deg) end
  return Angle(0, deg, 0)
end

local function pose(e, mode, cadence, speed, dt)
  if mode == PP.MODE.RUN then
    local seq = e:LookupSequence("run_all_01")
    if seq and seq >= 0 and e:GetSequence() ~= seq then e:ResetSequence(seq) end
    e.cyc = ((e.cyc or 0) + dt * math.max(0.6, speed / 3.2)) % 1
    e:SetCycle(e.cyc)
    for _, b in pairs(e.bones) do if b then e:ManipulateBoneAngles(b, Angle(0, 0, 0)) end end
    return
  end
  if not e.sit then
    for _, s in ipairs(SIT_SEQS) do
      local id = e:LookupSequence(s)
      if id and id >= 0 then e.sit = id break end
    end
  end
  if e.sit and e:GetSequence() ~= e.sit then e:ResetSequence(e.sit) end
  e.crank = (e.crank + dt * (cadence or 0) / 60 * math.pi * 2) % (math.pi * 2)
  local amp = rig_leg:GetFloat()
  local b = e.bones
  if b.spine then e:ManipulateBoneAngles(b.spine, axis_angle(rig_lean:GetFloat() * 0.5)) end
  if b.lt then e:ManipulateBoneAngles(b.lt, axis_angle(math.sin(e.crank) * amp)) end
  if b.rt then e:ManipulateBoneAngles(b.rt, axis_angle(math.sin(e.crank + math.pi) * amp)) end
  if b.lc then e:ManipulateBoneAngles(b.lc, axis_angle(-math.sin(e.crank + 1.2) * amp * 1.3)) end
  if b.rc then e:ManipulateBoneAngles(b.rc, axis_angle(-math.sin(e.crank + math.pi + 1.2) * amp * 1.3)) end
end

-- ---------- drawing ----------
local origin_v, cam_x, cam_y, cam_z = Vector(), 0, 0, 0
local function to_render(x, y, z) return Vector(origin_v.x + (x - cam_x) * U, origin_v.y + (y - cam_y) * U, origin_v.z + (z - cam_z) * U) end
W.to_render = to_render

local mtx = Matrix()
local function draw_block(b)
  mtx:SetTranslation(to_render(b.ox, b.oy, b.oz))
  mtx:SetAngles(Angle(0, 0, 0))
  cam.PushModelMatrix(mtx)
  for _, m in ipairs(b.meshes) do m:Draw() end
  cam.PopModelMatrix()
end

local water
local function draw_water()
  if not water then
    local buf = {}
    local s = 30000
    quad(buf, -s, -s, 0, s, -s, 0, s, s, 0, -s, s, 0, 64, 132, 186, true)
    water = build_meshes(buf, 0, 0, 0)
  end
  water.ox, water.oy, water.oz = cam_x, cam_y, -0.25
  draw_block(water)
end

local build_queue_t = 0
local function build_some(fx, fy)
  local t0 = SysTime()
  -- nearest unbuilt chunks first, a few milliseconds per frame
  local best, bestd
  for _ = 1, 4 do
    best, bestd = nil, math.huge
    for _, ch in ipairs(W.chunks) do
      if not ch.terrain or (ch.props == nil) then
        local d = (ch.cx - cam_x) ^ 2 + (ch.cy - cam_y) ^ 2
        local need = (not ch.terrain and d < (W.VIEW + 600) ^ 2) or (ch.props == nil and d < (W.PROP_VIEW + 400) ^ 2)
        if need and d < bestd then best, bestd = ch, d end
      end
    end
    if not best then return end
    if not best.terrain then best.terrain = chunk_terrain(best) end
    if best.props == nil and bestd < (W.PROP_VIEW + 400) ^ 2 then best.props = chunk_props(best) or false end
    if SysTime() - t0 > 0.006 then return end
  end
end

function W.Ready() return W.ready end

function W.Init()
  local t0 = SysTime()
  prepare_terrain()
  setup_chunks()
  build_roads()
  build_bike()
  W.ready = true
  print(string.format("[PhysPlay] world ready in %.2f s (%d terrain chunks, %d road pieces)", SysTime() - t0, #W.chunks, #W.roads))
end

function W.SetRoute(r)
  if not W.ready then W.Init() end
  build_route_props(r)
end

-- riders: list of { idx, ply, x, y, z, hx, hy, grade, mode, cadence, speed }
function W.Draw(view_origin, cx, cy, cz, fwd, riders, dt)
  origin_v, cam_x, cam_y, cam_z = view_origin, cx, cy, cz
  render.Clear(W.SKY.r, W.SKY.g, W.SKY.b, 255, true, true)
  render.FogMode(MATERIAL_FOG_LINEAR)
  render.FogStart(1800 * U)
  render.FogEnd(W.VIEW * U)
  render.FogMaxDensity(0.85)
  render.FogColor(W.SKY.r, W.SKY.g, W.SKY.b)
  render.SetMaterial(mat)
  build_some()
  local fx, fy = fwd.x, fwd.y
  local function visible(x, y, range)
    local dx, dy = x - cx, y - cy
    local d2 = dx * dx + dy * dy
    if d2 > range * range then return false end
    return d2 < 700 * 700 or (dx * fx + dy * fy) > -350
  end
  for _, ch in ipairs(W.chunks) do
    if ch.terrain and visible(ch.cx, ch.cy, W.VIEW + 500) then draw_block(ch.terrain) end
  end
  draw_water()
  for _, rd in ipairs(W.roads) do
    if visible(rd.cx, rd.cy, W.VIEW) then
      draw_block(rd.body)
      if (rd.cx - cx) ^ 2 + (rd.cy - cy) ^ 2 < 700 * 700 then draw_block(rd.lines) end
    end
  end
  for _, ch in ipairs(W.chunks) do
    if ch.props and visible(ch.cx, ch.cy, W.PROP_VIEW + 400) then draw_block(ch.props) end
  end
  for _, b in ipairs(W.route_props) do
    if visible(b.cx, b.cy, W.PROP_VIEW + 600) then draw_block(b) end
  end

  -- riders
  render.SuppressEngineLighting(true)
  render.ResetModelLighting(0.55, 0.55, 0.6)
  render.SetModelLighting(BOX_TOP, 1, 1, 0.95)
  render.SetModelLighting(BOX_FRONT, 0.8, 0.8, 0.78)
  for _, r in ipairs(riders) do
    if (r.x - cx) ^ 2 + (r.y - cy) ^ 2 < W.RIDER_VIEW ^ 2 then
      local yaw = math.deg(math.atan2(r.hy, r.hx))
      local pitch = -math.deg(math.atan(r.grade / 100))
      local base = to_render(r.x, r.y, r.z + 0.12)
      local ang = Angle(pitch, yaw, 0)
      if r.mode ~= PP.MODE.RUN then
        mtx:SetTranslation(base) mtx:SetAngles(ang)
        cam.PushModelMatrix(mtx)
        render.SetMaterial(mat_frame)
        local col = IsValid(r.ply) and r.ply:GetPlayerColor() or Vector(0.78, 0.96, 0.2)
        mat_frame:SetVector("$color", col)
        bike_mesh:Draw()
        render.SetMaterial(mat)
        wheel_mesh:Draw()
        cam.PopModelMatrix()
      end
      local e = rider_model(r.idx, r.ply)
      if e then
        local pos = base
        if r.mode ~= PP.MODE.RUN then pos = base + ang:Forward() * rig_x:GetFloat() * U + ang:Up() * rig_z:GetFloat() * U end
        e:SetPos(pos)
        e:SetAngles(Angle(0, yaw, 0))
        pose(e, r.mode, r.cadence, r.speed, dt)
        e:InvalidateBoneCache()
        e:SetupBones()
        e:DrawModel()
      end
    end
  end
  render.SuppressEngineLighting(false)
  render.FogMode(MATERIAL_FOG_NONE)
end

function W.Cleanup(keep)
  for idx, e in pairs(W.models) do
    if not keep[idx] and IsValid(e) then e:Remove() W.models[idx] = nil end
  end
end
