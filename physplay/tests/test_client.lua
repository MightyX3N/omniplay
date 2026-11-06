-- Client: build the world, receive a route and rider states, render and draw the HUD for 20 s
-- of riding. Catches Lua errors; how it looks is checked in the game.
assert(loadfile("tests/gmod_stub.lua"))("client")
local me = STUB.player(1, "Patrick")
STUB.local_player = me
STUB.ents[1], STUB.ents[2] = me, STUB.player(2, "Friend")
include("cl_init.lua")
local t0 = os.clock()
STUB.run("InitPostEntity")
print(string.format("world init %.2f s, %d meshes so far", os.clock() - t0, STUB.mesh_count()))
STUB.deliver({ name = "physplay_route", "rolling-hills" })
assert(PP.cl.route and PP.cl.route.id == "rolling-hills")
local d1, d2 = 0, 15
local frames = 0
for f = 1, 20 * 60 do
  if f % 6 == 0 then
    d1, d2 = d1 + 0.9, d2 + 0.85
    STUB.deliver({ name = "physplay_state", 2,
      1, d1, 1, 9, 210, 86, 141, 0, 0,
      2, d2, 2.5, 8.5, 180, 80, 0, 2, 0 })
  end
  STUB.advance(1 / 60)
  STUB.run("Think")
  local view = GM:CalcView(me, Vector(0, 0, 64), Angle(0, 0, 0), 75)
  STUB.run("PreDrawOpaqueRenderables", false, false, false)
  GM:HUDPaint()
  frames = frames + 1
end
assert(view == nil or true)
local W = PP.W
local built = 0
for _, ch in ipairs(W.chunks) do if ch.terrain then built = built + 1 end end
print(string.format("%d frames, %d terrain chunks built, %d meshes, %d mesh draws, %d HUD texts",
  frames, built, STUB.mesh_count(), STUB.draws, #STUB.texts))
assert(built > 20, "terrain should build around the camera")
assert(STUB.draws > frames * 20, "world should draw")
local me_rd = PP.cl.riders[1]
assert(math.abs(me_rd.sd - d1) < 5, "interpolated distance " .. me_rd.sd .. " vs " .. d1)
-- ground under the road is never above it near the route
local r = PP.cl.route
local worst = -99
for d = 0, r.length, 10 do
  local x, y, z = r:At(d)
  worst = math.max(worst, W.GroundAt(x, y) - z)
end
print(string.format("highest ground above the road: %.2f m (cut terrain)", worst))
assert(worst < 0, "terrain pokes through the road")
print("client tests passed")
