-- PhysPlay shared world: data loads, routes match OpenRadlr, terrain fits the roads, physics is sane.
local G = "gamemodes/physplay/gamemode/"
dofile(G .. "sh_world.lua")
local t0 = os.clock()
PP.LoadData(function(name) return assert(loadfile(G .. "data/" .. name))() end)
print(string.format("data loaded in %.2f s", os.clock() - t0))
local r = PP.routes["rolling-hills"]
assert(r and math.abs(r.length - 7800) < 200, "rolling hills length " .. tostring(r and r.length))
print("routes:")
for _, id in ipairs(PP.route_ids) do local x = PP.routes[id]; print(string.format("  %-16s %5.1f km %4d m up", id, x.length / 1000, x.climb)) end
-- terrain should sit near the road (it's built around the roads)
local worst, sum, n = 0, 0, 0
for d = 0, r.length, 50 do
  local x, y, z = r:At(d)
  local diff = PP.HeightAt(x, y) - z
  worst = math.max(worst, diff); sum = sum + math.abs(diff); n = n + 1
end
print(string.format("terrain vs road: mean |diff| %.1f m, highest terrain above road %.1f m", sum / n, worst))
assert(sum / n < 15, "terrain doesn't match the roads; heights decoded wrong?")
-- physics: 200 W on the flat ~ 30-36 km/h, 200 W on 6% ~ 12-16 km/h
local function settle(w, g) local v = 0 for _ = 1, 6000 do v = PP.Step(v, w, g, 75, 1, 0.05) end return v * 3.6 end
local flat, climb = settle(200, 0), settle(200, 6)
print(string.format("200 W: flat %.1f km/h, 6%% %.1f km/h", flat, climb))
assert(flat > 28 and flat < 38 and climb > 10 and climb < 17)
-- grade + heading are finite everywhere
for d = 0, r.length, 25 do
  local g = r:Grade(d); local hx, hy = r:Heading(d)
  assert(g == g and math.abs(g) < 30 and math.abs(hx * hx + hy * hy - 1) < 1e-6)
end
print("world tests passed")
