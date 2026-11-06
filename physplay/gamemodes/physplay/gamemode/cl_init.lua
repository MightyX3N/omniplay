include("shared.lua")
include("cl_world.lua")
include("cl_hud.lua")

CreateClientConVar("physplay_difficulty", "50", true, true, "trainer difficulty in % (how much of each hill your trainer feels)", 0, 100)
CreateClientConVar("physplay_weight", "75", true, true, "your weight in kg (for the physics)", 30, 200)

local W = PP.W
PP.cl = { riders = {}, me = nil, route = nil, ride_t = 0, ride_m = 0 }
local C = PP.cl

-- ---------- network ----------
net.Receive("physplay_route", function()
  local id = net.ReadString()
  local r = PP.routes[id]
  if not r then return end
  PP.route = r
  C.route = r
  for _, rd in pairs(C.riders) do rd.sd = nil end
  W.SetRoute(r)
  chat.AddText(Color(198, 244, 50), "[PhysPlay] ", color_white, string.format("%s, %.1f km, %d m of climbing", r.name, r.length / 1000, r.climb))
end)

net.Receive("physplay_state", function()
  local n = net.ReadUInt(8)
  local now = CurTime()
  local seen = {}
  for _ = 1, n do
    local idx = net.ReadUInt(8)
    local rd = C.riders[idx] or {}
    rd.d, rd.lane, rd.v = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
    rd.watts, rd.cadence, rd.hr = net.ReadUInt(12), net.ReadUInt(8), net.ReadUInt(8)
    rd.mode, rd.laps = net.ReadUInt(2), net.ReadUInt(8)
    rd.t = now
    rd.ply = Entity(idx)
    C.riders[idx] = rd
    seen[idx] = true
  end
  for idx in pairs(C.riders) do if not seen[idx] then C.riders[idx] = nil end end
  W.Cleanup(seen)
end)

-- ---------- interpolation ----------
local function wrap_diff(r, a, b)
  local d = a - b
  if r.loop then
    local L = r.length
    if d > L / 2 then d = d - L elseif d < -L / 2 then d = d + L end
  end
  return d
end

local function update_riders(dt)
  local r = C.route
  if not r then return end
  local now = CurTime()
  for _, rd in pairs(C.riders) do
    local est = rd.d + rd.v * math.min(0.4, now - (rd.t or now))
    if not rd.sd then rd.sd, rd.slane = est, rd.lane end
    local before = rd.sd
    rd.sd = r:Wrap(rd.sd + rd.v * dt + wrap_diff(r, est, rd.sd) * math.min(1, dt * 6))
    rd.slane = rd.slane + (rd.lane - rd.slane) * math.min(1, dt * 5)
    rd.moved = wrap_diff(r, rd.sd, before)
  end
  local me = C.riders[LocalPlayer():EntIndex()]
  C.me = me
  if me and me.v > 0.2 then
    C.ride_t = C.ride_t + dt
    C.ride_m = C.ride_m + math.max(0, me.moved or 0)
  end
end

-- ---------- camera ----------
local cam_state = { x = 0, y = 0, z = 0, ready = false }
local fwd = Vector(1, 0, 0)
local view_origin = Vector()

function GM:CalcView(ply, origin, angles, fov)
  local r, me = C.route, C.me
  if not r or not W.Ready() then return end
  local d = me and me.sd or 0
  local lane = me and me.slane or (r.lanes - 1) / 2
  local x, y, z = r:RiderPos(d, lane)
  local hx, hy = r:Heading(d, 14)
  -- chase camera: behind and above the rider, looking down the road
  local tx, ty, tz = x - hx * 6.5, y - hy * 6.5, z + 2.6
  tz = math.max(tz, W.GroundAt(tx, ty) + 1.4)
  local k = cam_state.ready and math.min(1, FrameTime() * 5) or 1
  cam_state.x = cam_state.x + (tx - cam_state.x) * k
  cam_state.y = cam_state.y + (ty - cam_state.y) * k
  cam_state.z = cam_state.z + (tz - cam_state.z) * k
  cam_state.ready = true
  local lx, ly, lz = x + hx * 12, y + hy * 12, z + 1.0
  local dir = Vector(lx - cam_state.x, ly - cam_state.y, lz - cam_state.z)
  local ang = dir:Angle()
  fwd = ang:Forward()
  view_origin = origin
  return { origin = origin, angles = ang, fov = fov, znear = 16, zfar = (W.VIEW + 400) * PP.U, drawviewer = false }
end

-- ---------- drawing ----------
local last_draw = SysTime()
local function rider_list()
  local r = C.route
  local list = {}
  for idx, rd in pairs(C.riders) do
    if rd.sd then
      local x, y, z, hx, hy = r:RiderPos(rd.sd, rd.slane or rd.lane)
      list[#list + 1] = { idx = idx, ply = rd.ply, x = x, y = y, z = z, hx = hx, hy = hy, grade = r:Grade(rd.sd, 4),
        mode = rd.mode, cadence = rd.cadence, speed = rd.v }
    end
  end
  return list
end

hook.Add("PreDrawOpaqueRenderables", "PhysPlayWorld", function(depth, sky, sky3d)
  if depth or sky or sky3d then return end
  if not C.route or not W.Ready() then return end
  local now = SysTime()
  local dt = math.min(0.1, now - last_draw)
  last_draw = now
  W.Draw(view_origin, cam_state.x, cam_state.y, cam_state.z, fwd, rider_list(), dt)
  return true
end)
hook.Add("PreDrawTranslucentRenderables", "PhysPlayWorld", function(depth, sky)
  if C.route and W.Ready() and not sky then return true end
end)
hook.Add("PreDrawSkyBox", "PhysPlayWorld", function() if C.route then return true end end)
hook.Add("PreDrawViewModel", "PhysPlayWorld", function() return true end)
hook.Add("PrePlayerDraw", "PhysPlayWorld", function() return true end)

hook.Add("Think", "PhysPlayClient", function()
  update_riders(FrameTime())
end)

-- ---------- OmniPlay ----------
hook.Add("InitPostEntity", "PhysPlayOmni", function()
  OmniPlay.SetGame("PhysPlay")
  OmniPlay.TakeInput(true) -- PhysPlay reads your movement itself, so OmniPlay stops pressing W
  if not W.Ready() then W.Init() end
end)
