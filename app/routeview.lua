-- Drawing a route: top-down line, a simple 3D view, and the elevation profile. Offline only for now:
-- map tiles and terrain need the HTTPS client that comes with a later update.
local ui = require("ui")
local route = require("route")
local C = ui.C
local M = {}

-- every 10 m is too many points to draw each frame; keep ~600 per route
local function pts(r)
  if r._draw then return r._draw end
  local rs = r.rs
  local n = #rs.d
  local step = math.max(1, math.floor(n / 600))
  local out = {}
  for k = 1, n, step do out[#out + 1] = k end
  if out[#out] ~= n then out[#out + 1] = n end
  local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
  for k = 1, n do
    minx, maxx = math.min(minx, rs.x[k]), math.max(maxx, rs.x[k])
    miny, maxy = math.min(miny, rs.y[k]), math.max(maxy, rs.y[k])
  end
  r._draw = { idx = out, minx = minx, maxx = maxx, miny = miny, maxy = maxy }
  return r._draw
end

local function fit(r, x, y, w, h, pad)
  local p = pts(r)
  local sw, sh = math.max(1, p.maxx - p.minx), math.max(1, p.maxy - p.miny)
  local s = math.min((w - 2 * pad) / sw, (h - 2 * pad) / sh)
  local ox = x + (w - sw * s) / 2
  local oy = y + (h - sh * s) / 2
  return function(px, py) return ox + (px - p.minx) * s, oy + (p.maxy - py) * s end
end

local function marker(x, y, col)
  love.graphics.setColor(C.bg)
  love.graphics.circle("fill", x, y, 9)
  love.graphics.setColor(col or C.yellow)
  love.graphics.circle("fill", x, y, 6)
end

function M.map(r, x, y, w, h, pos)
  ui.rect(x, y, w, h, C.inner, 16)
  local p = pts(r)
  local rs = r.rs
  local T = fit(r, x, y, w, h, 18)
  love.graphics.setLineJoin("bevel")
  -- dark casing, then coloured by grade
  love.graphics.setLineWidth(7)
  love.graphics.setColor(C.bg)
  local line = {}
  for _, k in ipairs(p.idx) do local a, b = T(rs.x[k], rs.y[k]); line[#line + 1] = a; line[#line + 1] = b end
  if #line >= 4 then love.graphics.line(line) end
  love.graphics.setLineWidth(3.5)
  for i = 2, #p.idx do
    local k0, k1 = p.idx[i - 1], p.idx[i]
    local a, b = T(rs.x[k0], rs.y[k0])
    local c, d = T(rs.x[k1], rs.y[k1])
    love.graphics.setColor(route.color(rs.g[k1], C))
    love.graphics.line(a, b, c, d)
  end
  love.graphics.setLineWidth(1)
  local sx, sy = T(rs.x[1], rs.y[1])
  love.graphics.setColor(1, 1, 1)
  love.graphics.circle("fill", sx, sy, 5)
  if pos then local h0 = route.at(r, pos); marker(T(h0.x, h0.y)) end
end

-- isometric ribbon: the route drawn as a wall standing on a flat base, height = elevation
function M.view3d(r, x, y, w, h, pos)
  ui.rect(x, y, w, h, C.inner, 16)
  local p = pts(r)
  local rs = r.rs
  local sw, sh = math.max(1, p.maxx - p.minx), math.max(1, p.maxy - p.miny)
  local cx, cy = (p.minx + p.maxx) / 2, (p.miny + p.maxy) / 2
  -- rotate 45° and squash for the iso look
  local function iso(px, py) local u, v = (px - cx) - (py - cy), (px - cx) + (py - cy); return u, -v * 0.5 end
  local span = (sw + sh)
  local s = math.min((w - 40) / span, (h - 70) / (span * 0.5))
  local erange = math.max(30, r.emax - r.emin)
  local zs = (h * 0.28) / erange
  local ox, oy = x + w / 2, y + h / 2 + 18
  local function P(k)
    local u, v = iso(rs.x[k], rs.y[k])
    return ox + u * s, oy + v * s, (rs.e[k] - r.emin) * zs + 4
  end
  -- base plate
  local corners = { { p.minx, p.miny }, { p.maxx, p.miny }, { p.maxx, p.maxy }, { p.minx, p.maxy } }
  local poly = {}
  for _, c in ipairs(corners) do
    local u, v = iso(c[1], c[2]); poly[#poly + 1] = ox + u * s; poly[#poly + 1] = oy + v * s
  end
  love.graphics.setColor(C.card)
  love.graphics.polygon("fill", poly)
  -- walls, back to front (sort by screen y)
  local segs = {}
  for i = 2, #p.idx do segs[#segs + 1] = i end
  local sy = {}
  for _, i in ipairs(segs) do local _, b = P(p.idx[i]); sy[i] = b end
  table.sort(segs, function(a, b) return sy[a] < sy[b] end)
  for _, i in ipairs(segs) do
    local k0, k1 = p.idx[i - 1], p.idx[i]
    local ax, ay, az = P(k0)
    local bx, by, bz = P(k1)
    local col = route.color(rs.g[k1], C)
    love.graphics.setColor(col[1] * 0.45, col[2] * 0.45, col[3] * 0.55, 0.9)
    love.graphics.polygon("fill", ax, ay, bx, by, bx, by - bz, ax, ay - az)
    love.graphics.setColor(col)
    love.graphics.setLineWidth(2.5)
    love.graphics.line(ax, ay - az, bx, by - bz)
  end
  love.graphics.setLineWidth(1)
  if pos then
    local h0 = route.at(r, pos)
    local u, v = iso(h0.x, h0.y)
    marker(ox + u * s, oy + v * s - ((h0.e - r.emin) * zs + 4))
  end
end

-- elevation profile as coloured columns; returns nothing
function M.profile(r, x, y, w, h, pos)
  local rs = r.rs
  local n = #rs.d
  local cols = math.max(2, math.floor(w / 3))
  local erange = math.max(20, r.emax - r.emin)
  local lo = r.emin - erange * 0.08
  local hi = r.emax + erange * 0.05
  for c = 0, cols - 1 do
    local s = r.length * (c + 0.5) / cols
    local a = route.at(r, s)
    local ch = (a.e - lo) / (hi - lo) * h
    love.graphics.setColor(route.color(a.g, C))
    love.graphics.rectangle("fill", x + c * w / cols, y + h - ch, w / cols - 0.6, ch)
  end
  if pos then
    local px = x + w * pos / math.max(1, r.length)
    local a = route.at(r, pos)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setLineWidth(3)
    love.graphics.line(px, y - 6, px, y + h)
    love.graphics.setLineWidth(1)
    marker(px, y + h - (a.e - lo) / (hi - lo) * h)
  end
end

function M.legend(x, y)
  local items = { { "down", C.blue }, { "flat", C.green }, { "2-5%", C.yellow }, { "5-8%", C.orange }, { "8%+", C.red } }
  local w = 0
  for _, it in ipairs(items) do w = w + ui.width(it[1], "s") + 34 end
  local lx = x - w
  for _, it in ipairs(items) do
    ui.rect(lx, y + 3, 12, 12, it[2], 4)
    ui.text(it[1], lx + 18, y, C.soft, "s")
    lx = lx + ui.width(it[1], "s") + 34
  end
end

return M
