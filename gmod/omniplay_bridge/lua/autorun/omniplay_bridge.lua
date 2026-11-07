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
--   OmniPlay.SetInfo(text)          -> a status line written to OmniPlay's log (for debugging)
--   hook "OmniPlay_Data" (data)     -> new data arrived (about 20 times a second)
--   OmniPlay.Native                 -> true when the fast OmniPlay module is installed (garrysmod/lua/bin,
--                                      OmniPlay installs it from its Games tab); otherwise the data folder is used
-- SERVER
--   ply:OmniPlayData()              -> that player's last data (camera = true when OmniPlay's camera sees the feet) (sent by their client up to 10x a second; trust it like any client input)
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
    ply.OmniPlayNext = now + 0.07
    if not net.ReadBool() then
      ply.OmniPlay = nil
      hook.Run("OmniPlay_PlayerData", ply, nil)
      return
    end
    local d = {
      speed_kmh = math.Clamp(net.ReadFloat(), 0, 120), cadence = math.Clamp(net.ReadFloat(), 0, 300),
      power = net.ReadUInt(12), hr = net.ReadUInt(8), moving = net.ReadBool(), gait = net.ReadString():sub(1, 8),
      grade = net.ReadFloat(), kind = net.ReadString():sub(1, 10), camera = net.ReadBool(),
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

-- the OmniPlay module (shared memory, no files) if it's installed; the data folder otherwise
local native
if util.IsBinaryModuleInstalled and util.IsBinaryModuleInstalled("omniplay") then
  local ok, err = pcall(require, "omniplay")
  if ok and omniplay_native then native = omniplay_native else print("[OmniPlay] module failed to load: " .. tostring(err)) end
end
OmniPlay.Native = native ~= nil

if not native then file.CreateDir("omniplay") end

function OmniPlay.IsConnected()
  if native then return data ~= nil and native.Running() end
  return data ~= nil and RealTime() - last_change < 2
end
function OmniPlay.Get() if OmniPlay.IsConnected() then return data end end
function OmniPlay.SetGame(name) want.game, want.used, want.dirty = tostring(name), true, true end
function OmniPlay.SetGrade(pct)
  local g = pct and math.Clamp(tonumber(pct) or 0, -10, 20) or nil
  if g ~= want.grade then want.dirty = true end
  want.grade, want.used = g, true
end
function OmniPlay.SetBeltSpeed(kmh) want.belt_speed, want.used, want.dirty = tonumber(kmh), true, true end
function OmniPlay.TakeInput(on) want.take_input, want.used, want.dirty = on and true or false, true, true end
function OmniPlay.SetInfo(text) want.info, want.used, want.dirty = text and tostring(text):sub(1, 300) or nil, true, true end -- shown in OmniPlay's log

-- read OmniPlay's file often (it's tiny and in the OS cache) and answer quickly, so hills
-- and numbers don't wait on slow timers
local last_write, ack_dirty = 0, false
local function write_native()
  native.SetGame(want.game or "Garry's Mod")
  native.SetGrade(want.grade)
  if want.belt_speed then native.SetBeltSpeed(want.belt_speed) end
  if want.take_input ~= nil then native.TakeInput(want.take_input) end
  if want.info then native.SetInfo(want.info) end
end
local function write_cmd()
  if native then return write_native() end
  beat = beat + 1
  last_write = RealTime()
  ack_dirty = false
  file.Write("omniplay/cmd.txt", util.TableToJSON({
    beat = beat, game = want.game or "Garry's Mod", ack = last_seq,
    grade = want.grade == nil and false or want.grade,
    belt_speed = want.belt_speed, take_input = want.take_input == true, info = want.info,
  }))
end
OmniPlay._write = write_cmd

local function read_native()
  local js, seq = native.State() -- also tells OmniPlay we're still here
  if not js then
    if data then data = nil end
  elseif seq ~= last_seq then
    local t = util.JSONToTable(js)
    if t then
      last_seq, last_change = seq, RealTime()
      data = t
      OmniPlay.fresh = true
      hook.Run("OmniPlay_Data", t)
    end
  end
  if want.dirty then want.dirty = false; write_native() end
end

timer.Create("OmniPlay_Read", 0.02, 0, function()
  if native then return read_native() end
  local raw = file.Read("omniplay/live.txt", "DATA")
  if raw then
    local t = util.JSONToTable(raw)
    if t and t.seq ~= last_seq then
      last_seq, last_change = t.seq, RealTime()
      ack_dirty = true
      if t.closed then data = nil else
        data = t
        OmniPlay.fresh = true
        hook.Run("OmniPlay_Data", t)
      end
    end
  end
  if want.used then
    local since = RealTime() - last_write
    if (want.dirty and since >= 0.05) or (ack_dirty and since >= 0.1) or since >= 0.5 then
      want.dirty = false
      write_cmd()
    end
  end
end)

-- send our data to the server for multiplayer gamemodes
local was_connected = false
local last_send = 0
timer.Create("OmniPlay_Send", 0.02, 0, function()
  local d = OmniPlay.Get()
  if not d and not was_connected then return end
  local now = RealTime()
  if d and not OmniPlay.fresh and now - last_send < 0.5 then return end
  if now - last_send < 0.1 then return end
  OmniPlay.fresh, last_send = false, now
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
    net.WriteBool(d.camera == true)
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
  print("[OmniPlay] via " .. (native and "the OmniPlay module" or "the data folder"))
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
