AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_world.lua")
AddCSLuaFile("cl_hud.lua")
include("shared.lua")

util.AddNetworkString("physplay_route")
util.AddNetworkString("physplay_state")

local route_cv = CreateConVar("physplay_route", "rolling-hills", FCVAR_ARCHIVE + FCVAR_NOTIFY, "PhysPlay route id")
local SIM_DT, SEND_DT, GRADE_DT = 0.05, 0.1, 0.25
local KEY_WATTS, KEY_WATTS_HARD = 200, 350
local BIKE_FOLLOW_S = 0.6 -- how quickly the rider eases to each new bike reading

PP.riders = PP.riders or {}
local function route() return PP.route end

local function set_route(id)
  local r = PP.routes[id] or PP.routes["rolling-hills"] or PP.routes[PP.route_ids[1]]
  PP.route = r
  local lane = 0
  for _, rd in pairs(PP.riders) do
    rd.d, rd.v, rd.laps, rd.lane = 0, 0, 0, lane % r.lanes
    lane = lane + 1
  end
  net.Start("physplay_route") net.WriteString(r.id) net.Broadcast()
  print("[PhysPlay] route: " .. r.name .. string.format(" (%.1f km)", r.length / 1000))
end
set_route(route_cv:GetString())
cvars.AddChangeCallback("physplay_route", function(_, _, new) set_route(new) end, "physplay")

function GM:PlayerInitialSpawn(ply)
  local n = table.Count(PP.riders)
  PP.riders[ply] = { d = 0, v = 0, lane = n % route().lanes, watts = 0, key_watts = 0, cadence = 0, hr = 0,
    mode = PP.MODE.KEYS, laps = 0, grade_t = 0 }
  net.Start("physplay_route") net.WriteString(route().id) net.Send(ply)
end

function GM:PlayerDisconnected(ply) PP.riders[ply] = nil end

function GM:PlayerSpawn(ply)
  local mdl = player_manager.TranslatePlayerModel(ply:GetInfo("cl_playermodel"))
  util.PrecacheModel(mdl)
  ply:SetModel(mdl)
  ply:SetPlayerColor(Vector(ply:GetInfo("cl_playercolor")))
  ply:StripWeapons()
  ply:SetNoDraw(true)
  ply:SetMoveType(MOVETYPE_NONE)
  ply:GodEnable()
end
function GM:PlayerLoadout() return true end
function GM:Move() return true end
function GM:PlayerShouldTakeDamage() return false end
function GM:PlayerSwitchFlashlight() return false end
function GM:PlayerNoClip() return false end

-- riding simulation, 20 times a second
local function sim(dt)
  local r = route()
  for ply, rd in pairs(PP.riders) do
    if not IsValid(ply) then PP.riders[ply] = nil else
    local data = ply.OmniPlayData and ply:OmniPlayData()
    local grade = r:Grade(rd.d)
    -- which input is this rider using?
    if data and data.kind == "bike" then rd.mode = PP.MODE.BIKE
    elseif data and (data.kind == "treadmill" or data.kind == "footpod") then rd.mode = PP.MODE.RUN
    else rd.mode = PP.MODE.KEYS end

    if rd.mode == PP.MODE.BIKE and data.speed_kmh then
      -- follow the bike's own speed directly (no physics delay on top of the console's):
      -- hills reach you as resistance on the trainer, which slows the flywheel itself
      local target = data.speed_kmh / 3.6
      if (data.cadence or 0) < 1 and (data.power or 0) < 1 and target < 1 then target = 0 end
      rd.v = rd.v + (target - rd.v) * math.min(1, dt / BIKE_FOLLOW_S)
      rd.watts, rd.cadence = data.power or 0, data.cadence or 0
    elseif rd.mode == PP.MODE.RUN then
      -- runners move at their real belt / footpod speed
      local target = (data.speed_kmh or 0) / 3.6
      rd.v = rd.v + (target - rd.v) * math.min(1, dt * 3)
      rd.watts, rd.cadence = 0, data.cadence or 0
    else
      if rd.mode == PP.MODE.BIKE then
        rd.watts, rd.cadence = data.power or 0, data.cadence or 0
      else
        local target = ply:KeyDown(IN_FORWARD) and (ply:KeyDown(IN_SPEED) and KEY_WATTS_HARD or KEY_WATTS) or 0
        rd.key_watts = math.Approach(rd.key_watts, target, 400 * dt)
        rd.watts, rd.cadence = rd.key_watts, rd.key_watts > 20 and 85 or 0
      end
      local kg = math.Clamp(ply:GetInfoNum("physplay_weight", 75), 30, 200)
      rd.v = PP.Step(rd.v, rd.watts, grade, kg, 1, dt)
    end
    rd.hr = data and data.hr or 0

    local before = rd.d
    rd.d = rd.d + rd.v * dt
    if r.loop then
      if rd.d >= r.length then rd.d = rd.d - r.length; rd.laps = rd.laps + 1 end
    elseif rd.d >= r.length then
      rd.d, rd.v = r.length, 0
    end

    -- lanes: A / D
    local steer = (ply:KeyDown(IN_MOVERIGHT) and 1 or 0) - (ply:KeyDown(IN_MOVELEFT) and 1 or 0)
    rd.lane = math.Clamp(rd.lane + steer * 1.5 * dt, 0, r.lanes - 1)

    -- hills to the trainer, scaled by the rider's difficulty setting
    rd.grade_t = rd.grade_t + dt
    if rd.mode == PP.MODE.BIKE and rd.grade_t >= GRADE_DT and ply.OmniPlaySetGrade then
      rd.grade_t = 0
      local diff = math.Clamp(ply:GetInfoNum("physplay_difficulty", 50), 0, 100) / 100
      ply:OmniPlaySetGrade(math.Round(grade * diff, 1))
    end
    end
  end
end

local function send()
  local list = {}
  for ply, rd in pairs(PP.riders) do if IsValid(ply) then list[#list + 1] = { ply, rd } end end
  net.Start("physplay_state", true)
  net.WriteUInt(#list, 8)
  for _, e in ipairs(list) do
    local ply, rd = e[1], e[2]
    net.WriteUInt(ply:EntIndex(), 8)
    net.WriteFloat(rd.d)
    net.WriteFloat(rd.lane)
    net.WriteFloat(rd.v)
    net.WriteUInt(math.Clamp(math.floor(rd.watts + 0.5), 0, 4095), 12)
    net.WriteUInt(math.Clamp(math.floor((rd.cadence or 0) + 0.5), 0, 255), 8)
    net.WriteUInt(math.Clamp(math.floor((rd.hr or 0) + 0.5), 0, 255), 8)
    net.WriteUInt(rd.mode, 2)
    net.WriteUInt(math.min(rd.laps, 255), 8)
  end
  net.Broadcast()
end

local sim_acc, send_acc = 0, 0
local last = SysTime()
hook.Add("Think", "PhysPlaySim", function()
  local now = SysTime()
  local dt = math.min(0.25, now - last)
  last = now
  sim_acc, send_acc = sim_acc + dt, send_acc + dt
  while sim_acc >= SIM_DT do sim(SIM_DT); sim_acc = sim_acc - SIM_DT end
  if send_acc >= SEND_DT then send_acc = 0; send() end
end)

concommand.Add("physplay_restart", function(ply)
  local rd = IsValid(ply) and PP.riders[ply]
  if rd then rd.d, rd.v, rd.laps = 0, 0, 0 end
end)
