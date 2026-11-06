-- OmniPlay bridge for Garry's Mod: live data from your bike, walking pad or footpod,
-- and hills / belt speed back to the machine. Needs OmniPlay running on the same PC.
--
-- CLIENT
--   OmniPlay.IsConnected()          -> true while OmniPlay is sending
--   OmniPlay.Get()                  -> table or nil: speed_kmh, cadence, power, hr, steps, moving,
--                                      gait ("stopped"/"walk"/"run"/"sprint"), grade, connected,
--                                      device = { name, kind = "bike"/"treadmill"/"footpod", hills, belt_speed, max_speed },
--                                      recording, distance_m, elapsed_s
--   OmniPlay.SetGame(name)          -> shown in OmniPlay and saved with the workout
--   OmniPlay.SetGrade(pct)          -> hill in %, nil = flat / release
--   OmniPlay.SetBeltSpeed(kmh)      -> treadmill speed (only if the user allowed it, capped at their max)
--   OmniPlay.TakeInput(bool)        -> true = OmniPlay stops pressing keys, you read Get() yourself
--   hook "OmniPlay_Data" (data)     -> new data arrived (about 10 times a second)
-- SERVER
--   ply:OmniPlayData()              -> that player's last data (sent by their client 4x a second; trust it like any client input)
--   ply:OmniPlaySetGrade(pct)       -> set that player's hill
--   ply:OmniPlayTakeInput(bool)
--   hook "OmniPlay_PlayerData" (ply, data)

OmniPlay = OmniPlay or {}
OmniPlay.Version = 1

if SERVER then
  AddCSLuaFile()
  util.AddNetworkString("omniplay_data")
  util.AddNetworkString("omniplay_cmd")

  local PLAYER = FindMetaTable("Player")
  function PLAYER:OmniPlayData() return self.OmniPlay end

  local function cmd(ply, kind, value)
    net.Start("omniplay_cmd")
    net.WriteString(kind)
    net.WriteBool(value ~= nil)
    if kind == "grade" then net.WriteFloat(value or 0) elseif kind == "take_input" then net.WriteBool(value == true) end
    net.Send(ply)
  end
  function PLAYER:OmniPlaySetGrade(pct) cmd(self, "grade", pct) end
  function PLAYER:OmniPlayTakeInput(on) cmd(self, "take_input", on and true or false) end

  net.Receive("omniplay_data", function(_, ply)
    local now = CurTime()
    if ply.OmniPlayNext and now < ply.OmniPlayNext then return end
    ply.OmniPlayNext = now + 0.15
    if not net.ReadBool() then
      ply.OmniPlay = nil
      hook.Run("OmniPlay_PlayerData", ply, nil)
      return
    end
    local d = {
      speed_kmh = math.Clamp(net.ReadFloat(), 0, 120), cadence = math.Clamp(net.ReadFloat(), 0, 300),
      power = net.ReadUInt(12), hr = net.ReadUInt(8), moving = net.ReadBool(), gait = net.ReadString():sub(1, 8),
      grade = net.ReadFloat(), kind = net.ReadString():sub(1, 10),
    }
    if d.power == 0 then d.power = nil end
    if d.hr == 0 then d.hr = nil end
    ply.OmniPlay = d
    hook.Run("OmniPlay_PlayerData", ply, d)
  end)
  return
end

-- ---------------- client ----------------
local data, last_seq, last_change = nil, nil, 0
local want = { game = nil, grade = nil, belt_speed = nil, take_input = nil, used = false }
local beat = 0

file.CreateDir("omniplay")

function OmniPlay.IsConnected() return data ~= nil and RealTime() - last_change < 2 end
function OmniPlay.Get() if OmniPlay.IsConnected() then return data end end
function OmniPlay.SetGame(name) want.game, want.used = tostring(name), true end
function OmniPlay.SetGrade(pct) want.grade, want.used = pct and math.Clamp(tonumber(pct) or 0, -10, 20) or nil, true end
function OmniPlay.SetBeltSpeed(kmh) want.belt_speed, want.used = tonumber(kmh), true end
function OmniPlay.TakeInput(on) want.take_input, want.used = on and true or false, true end

timer.Create("OmniPlay_Read", 0.1, 0, function()
  local raw = file.Read("omniplay/live.txt", "DATA")
  if not raw then return end
  local t = util.JSONToTable(raw)
  if not t or t.seq == last_seq then return end
  last_seq, last_change = t.seq, RealTime()
  if t.closed then data = nil return end
  data = t
  hook.Run("OmniPlay_Data", t)
end)

-- heartbeat + requests, only once something actually uses the API
timer.Create("OmniPlay_Write", 0.5, 0, function()
  if not want.used then return end
  beat = beat + 1
  file.Write("omniplay/cmd.txt", util.TableToJSON({
    beat = beat, game = want.game or "Garry's Mod",
    grade = want.grade == nil and false or want.grade,
    belt_speed = want.belt_speed, take_input = want.take_input == true,
  }))
end)

-- send our data to the server for multiplayer gamemodes
local was_connected = false
timer.Create("OmniPlay_Send", 0.25, 0, function()
  local d = OmniPlay.Get()
  if not d and not was_connected then return end
  if not IsValid(LocalPlayer()) then return end
  was_connected = d ~= nil
  net.Start("omniplay_data")
  net.WriteBool(d ~= nil)
  if d then
    net.WriteFloat(d.speed_kmh or 0); net.WriteFloat(d.cadence or 0)
    net.WriteUInt(math.Clamp(math.floor(d.power or 0), 0, 4095), 12)
    net.WriteUInt(math.Clamp(math.floor(d.hr or 0), 0, 255), 8)
    net.WriteBool(d.moving == true); net.WriteString(d.gait or "stopped")
    net.WriteFloat(d.grade or 0); net.WriteString(d.device and d.device.kind or "")
  end
  net.SendToServer()
end)

net.Receive("omniplay_cmd", function()
  local kind, has = net.ReadString(), net.ReadBool()
  if kind == "grade" then local v = net.ReadFloat(); OmniPlay.SetGrade(has and v or nil)
  elseif kind == "take_input" then OmniPlay.TakeInput(net.ReadBool()) end
end)

-- quick check from the console: omniplay_status
concommand.Add("omniplay_status", function()
  local d = OmniPlay.Get()
  if not d then print("[OmniPlay] not connected. Is OmniPlay running?") return end
  print(string.format("[OmniPlay] %s (%s)  %.1f km/h  cadence %.0f  power %s  hr %s  %s  hill %s",
    d.device and d.device.name or "no device", d.device and d.device.kind or "-", d.speed_kmh or 0, d.cadence or 0,
    tostring(d.power or "-"), tostring(d.hr or "-"), d.gait or "-", d.grade and (d.grade .. "%") or "-"))
end)

-- omniplay_hill <pct>: try hills by hand (0 = flat)
concommand.Add("omniplay_hill", function(_, _, args)
  local p = tonumber(args[1])
  OmniPlay.SetGame("Garry's Mod (console)")
  OmniPlay.SetGrade(p ~= 0 and p or nil)
  print("[OmniPlay] hill " .. (p or 0) .. "%")
end)
