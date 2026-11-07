-- GPX routes: read a track, smooth its elevation, and answer "where am I, how steep is it" by distance.
-- Routes live in the save folder under data/routes/ as the original .gpx files.
local M = {}

local DIR = "data/routes"

-- parse GPX text into { name, pts = { {lat, lon, ele} } }; works for tracks and routes
function M.parse(text)
  local name = text:match("<trk>.-<name>%s*(.-)%s*</name>") or text:match("<rte>.-<name>%s*(.-)%s*</name>")
    or text:match("<metadata>.-<name>%s*(.-)%s*</name>")
  local pts = {}
  for tag, attrs, body in text:gmatch("<(%a+pt)(%s[^>]-)(/?>)") do
    if tag == "trkpt" or tag == "rtept" then
      local lat = tonumber(attrs:match('lat%s*=%s*"([-%d%.eE]+)"'))
      local lon = tonumber(attrs:match('lon%s*=%s*"([-%d%.eE]+)"'))
      if lat and lon then pts[#pts + 1] = { lat, lon } end
    end
  end
  -- elevation: second pass, in the same order as the points
  local i = 0
  for tag, inner in text:gmatch("<(%a+pt)%s[^>]->(.-)</%1>") do
    if tag == "trkpt" or tag == "rtept" then
      i = i + 1
      local e = tonumber(inner:match("<ele>%s*([-%d%.eE]+)%s*</ele>"))
      if pts[i] then pts[i][3] = e end
    end
  end
  if #pts < 2 then return nil, "no track points in this file" end
  return { name = name, pts = pts }
end

-- build everything the app needs from parsed points: metres, distances, smoothed elevation, grades
function M.build(r)
  local pts = r.pts
  local lat0 = pts[1][1]
  local kx = 111320 * math.cos(math.rad(lat0))
  local x, y, d, e = {}, {}, { 0 }, {}
  local has_ele = false
  for i, p in ipairs(pts) do
    x[i], y[i] = (p[2] - pts[1][2]) * kx, (p[1] - lat0) * 110540
    if p[3] then has_ele = true end
    e[i] = p[3]
    if i > 1 then d[i] = d[i - 1] + math.sqrt((x[i] - x[i - 1]) ^ 2 + (y[i] - y[i - 1]) ^ 2) end
  end
  -- fill missing elevations from neighbours (or flat 0)
  local last
  for i = 1, #e do if e[i] then last = e[i] elseif last then e[i] = last end end
  last = nil
  for i = #e, 1, -1 do if e[i] then last = e[i] elseif last then e[i] = last else e[i] = 0 end end
  -- resample every 10 m and smooth over ~100 m, so the bike doesn't jump between grades
  local STEP = 10
  local n = math.max(2, math.floor(d[#d] / STEP) + 1)
  local rs = { x = {}, y = {}, e = {}, d = {} }
  local j = 1
  for k = 1, n do
    local s = math.min(d[#d], (k - 1) * STEP)
    while j < #d - 1 and d[j + 1] < s do j = j + 1 end
    local t = (d[j + 1] > d[j]) and (s - d[j]) / (d[j + 1] - d[j]) or 0
    rs.x[k] = x[j] + (x[j + 1] - x[j]) * t
    rs.y[k] = y[j] + (y[j + 1] - y[j]) * t
    rs.e[k] = e[j] + (e[j + 1] - e[j]) * t
    rs.d[k] = s
  end
  local W = 5
  local sm = {}
  for k = 1, n do
    local sum, c = 0, 0
    for q = math.max(1, k - W), math.min(n, k + W) do sum = sum + rs.e[q]; c = c + 1 end
    sm[k] = sum / c
  end
  rs.e = sm
  rs.g = {}
  for k = 1, n do
    local a, b = math.max(1, k - 3), math.min(n, k + 3)
    rs.g[k] = (rs.d[b] > rs.d[a]) and math.max(-25, math.min(25, 100 * (rs.e[b] - rs.e[a]) / (rs.d[b] - rs.d[a]))) or 0
  end
  local climb, emin, emax, steep = 0, math.huge, -math.huge, 0
  for k = 1, n do
    if k > 1 and rs.e[k] > rs.e[k - 1] then climb = climb + rs.e[k] - rs.e[k - 1] end
    emin, emax = math.min(emin, rs.e[k]), math.max(emax, rs.e[k])
    -- steepest stretch over ~200 m
    local b = math.min(n, k + 20)
    if b > k then steep = math.max(steep, 100 * (rs.e[b] - rs.e[k]) / (rs.d[b] - rs.d[k])) end
  end
  r.rs, r.length, r.climb, r.emin, r.emax, r.steepest, r.has_ele = rs, d[#d], climb, emin, emax, steep, has_ele
  return r
end

-- values at a distance along the route (metres)
function M.at(r, s)
  local rs = r.rs
  local n = #rs.d
  s = math.max(0, math.min(r.length, s))
  local k = math.min(n - 1, math.floor(s / 10) + 1)
  local t = (s - rs.d[k]) / math.max(1e-6, rs.d[k + 1] - rs.d[k])
  local function L(a) return a[k] + (a[k + 1] - a[k]) * t end
  return { x = L(rs.x), y = L(rs.y), e = L(rs.e), g = L(rs.g), k = k }
end

-- what comes next: the top of the current climb, or the length of the next descent
function M.ahead(r, s)
  local rs = r.rs
  local here = M.at(r, s)
  local k = here.k
  local n = #rs.d
  if here.g > 1.5 then
    local q = k
    while q < n and rs.g[q] > 0.5 do q = q + 1 end
    return "Top of this climb", rs.d[q] - s
  end
  local q = k
  while q < n and rs.g[q] <= 1.5 do q = q + 1 end
  if q >= n then return "Flat to the finish", r.length - s end
  return "Next climb", rs.d[q] - s
end

function M.color(g, C)
  if g < -1.5 then return C.blue elseif g < 2.5 then return C.green elseif g < 5 then return C.yellow
  elseif g < 8 then return C.orange end
  return C.red
end

-- ---------- files ----------
function M.list()
  love.filesystem.createDirectory(DIR)
  local out = {}
  for _, f in ipairs(love.filesystem.getDirectoryItems(DIR)) do
    if f:lower():match("%.gpx$") then out[#out + 1] = f end
  end
  table.sort(out)
  return out
end

local cache = {}
function M.load(file)
  if cache[file] ~= nil then return cache[file] or nil end
  local text = love.filesystem.read(DIR .. "/" .. file)
  local r = text and M.parse(text)
  if r then
    r = M.build(r)
    r.file = file
    r.name = r.name or file:gsub("%.[gG][pP][xX]$", "")
  end
  cache[file] = r or false
  return r
end

-- copy a dropped GPX into the routes folder; returns the file name or nil, error
function M.import(name, text)
  local r, err = M.parse(text)
  if not r then return nil, err end
  love.filesystem.createDirectory(DIR)
  local base = name:gsub("^.*[/\\]", ""):gsub("[^%w%-_%. ]", "_")
  if not base:lower():match("%.gpx$") then base = base .. ".gpx" end
  love.filesystem.write(DIR .. "/" .. base, text)
  cache[base] = nil
  return base
end

function M.remove(file)
  love.filesystem.remove(DIR .. "/" .. file)
  cache[file] = nil
end

M.DIR = DIR
return M
