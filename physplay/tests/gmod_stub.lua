-- Minimal Garry's Mod API stand-in, enough to run PhysPlay's Lua headless and catch errors
-- (nil calls, typos, bad arithmetic). It can't check how things look; that's for the real game.
local REALM = ...
local G = "gamemodes/physplay/gamemode/"
STUB = { hooks = {}, nets = {}, sent = {}, draws = 0, texts = {} }

-- a permissive object: any field is a function returning another permissive object
local magic_mt = {}
local function magic() return setmetatable({}, magic_mt) end
magic_mt.__index = function() return function() return magic() end end
magic_mt.__call = function() return magic() end
STUB.magic = magic

local function lib() return setmetatable({}, { __index = function(t, k) local f = function() return magic() end rawset(t, k, f) return f end }) end

SERVER, CLIENT = REALM == "server", REALM == "client"
color_white = { r = 255, g = 255, b = 255, a = 255 }
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end

-- vectors / angles
local V = {}
V.__index = V
function Vector(x, y, z)
  if type(x) == "string" then local a, b, c = x:match("(%S+)%s+(%S+)%s+(%S+)") x, y, z = tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 end
  return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V)
end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, b) if type(a) == "number" then a, b = b, a end return Vector(a.x * b, a.y * b, a.z * b) end
function V:Angle() return Angle(math.deg(math.atan2(-self.z, math.sqrt(self.x ^ 2 + self.y ^ 2))), math.deg(math.atan2(self.y, self.x)), 0) end
function V:ToScreen() return { x = 100, y = 100, visible = true } end
local A = {}
A.__index = A
function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, A) end
function A:Forward() local p, y = math.rad(self.p), math.rad(self.y) return Vector(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p)) end
function A:Up() return Vector(0, 0, 1) end
function Matrix() return setmetatable({}, { __index = function() return function() end end }) end

-- math / string extensions
function math.Clamp(v, a, b) return math.max(a, math.min(b, v)) end
function math.Approach(c, t, s) if c < t then return math.min(t, c + s) end return math.max(t, c - s) end
function math.Round(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
function table.Count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local clock = 0
function CurTime() return clock end
function RealTime() return clock end
function SysTime() return os.clock() end
function FrameTime() return 1 / 60 end
function STUB.advance(dt) clock = clock + dt end
function ScrW() return 1920 end
function ScrH() return 1080 end
function IsValid(e) return e ~= nil and e ~= false and (type(e) ~= "table" or e.valid ~= false) end

-- convars
local cvars_store = {}
local function cvar(name, def)
  local c = cvars_store[name] or { v = def }
  cvars_store[name] = c
  return { GetString = function() return tostring(c.v) end, GetFloat = function() return tonumber(c.v) or 0 end,
    GetInt = function() return math.floor(tonumber(c.v) or 0) end, GetBool = function() return tonumber(c.v) ~= 0 end }
end
function CreateConVar(n, d) return cvar(n, d) end
function CreateClientConVar(n, d) return cvar(n, d) end
function GetConVar(n) return cvar(n, 0) end
cvars = { AddChangeCallback = function() end }

-- hooks and gamemode
hook = { Add = function(ev, id, fn) STUB.hooks[ev] = STUB.hooks[ev] or {} STUB.hooks[ev][id] = fn end }
function STUB.run(ev, ...)
  for _, fn in pairs(STUB.hooks[ev] or {}) do fn(...) end
  if GM[ev] then return GM[ev](GM, ...) end
end
hook.Run = function(ev, ...) return STUB.run(ev, ...) end
GM = {}
function DeriveGamemode() end
timer = { Create = function(name, delay, reps, fn) STUB.hooks["timer:" .. name] = { x = fn } end, Simple = function(_, fn) end }
concommand = { Add = function() end }

-- files
function AddCSLuaFile() end
function include(path)
  local f = assert(loadfile(G .. path))
  return f()
end
file = { CreateDir = function() end, Read = function() return nil end, Write = function() end }
util = { AddNetworkString = function() end, PrecacheModel = function() end,
  JSONToTable = function() return nil end, TableToJSON = function() return "{}" end }

-- net: a queue of written values, read back in order
local wq = {}
net = {}
function net.Start(name) wq = { name = name } end
for _, k in ipairs({ "String", "Float", "UInt", "Bool", "Entity" }) do
  net["Write" .. k] = function(v) wq[#wq + 1] = v end
end
function net.Broadcast() STUB.sent[#STUB.sent + 1] = wq end
function net.Send() STUB.sent[#STUB.sent + 1] = wq end
function net.SendToServer() end
local rq, ri = {}, 0
for _, k in ipairs({ "String", "Float", "UInt", "Bool" }) do net["Read" .. k] = function() ri = ri + 1 return rq[ri] end end
function net.Receive(name, fn) STUB.nets[name] = fn end
function STUB.deliver(msg) rq, ri = msg, 0 STUB.nets[msg.name](0) end

-- players
local PLAYER = {}
PLAYER.__index = PLAYER
function FindMetaTable(n) if n == "Player" then return PLAYER end return {} end
function STUB.player(idx, name)
  local p = setmetatable({ idx = idx, name = name, keys = {}, info = {}, valid = true }, PLAYER)
  return p
end
function PLAYER:EntIndex() return self.idx end
function PLAYER:Nick() return self.name end
function PLAYER:GetModel() return "models/player/kleiner.mdl" end
function PLAYER:GetPlayerColor() return Vector(0.3, 0.6, 1) end
function PLAYER:KeyDown(k) return self.keys[k] == true end
function PLAYER:GetInfo(k) return self.info[k] or "" end
function PLAYER:GetInfoNum(k, d) return tonumber(self.info[k]) or d end
for _, m in ipairs({ "SetModel", "SetPlayerColor", "StripWeapons", "SetNoDraw", "SetMoveType", "GodEnable" }) do PLAYER[m] = function() end end
IN_FORWARD, IN_SPEED, IN_MOVELEFT, IN_MOVERIGHT = 8, 131072, 512, 1024
MOVETYPE_NONE = 0
FCVAR_ARCHIVE, FCVAR_NOTIFY = 128, 256
player_manager = { TranslatePlayerModel = function() return "models/player/kleiner.mdl" end }
STUB.ents = {}
function Entity(i) return STUB.ents[i] end
function LocalPlayer() return STUB.local_player end

-- client rendering stand-ins
render, cam, surface, draw, mesh, chat = lib(), lib(), lib(), lib(), lib(), lib()
function surface.GetTextSize(s) return #tostring(s) * 10, 20 end
function draw.SimpleText(t) STUB.texts[#STUB.texts + 1] = tostring(t) end
function CreateMaterial() return lib() end
local meshes = 0
function Mesh() meshes = meshes + 1 return { Draw = function() STUB.draws = STUB.draws + 1 end, Destroy = function() end } end
function STUB.mesh_count() return meshes end
function ClientsideModel()
  local e = setmetatable({ valid = true }, { __index = function(t, k) return function() return nil end end })
  e.LookupSequence = function(_, s) return s == "sit_rollercoaster" and 5 or -1 end
  e.LookupBone = function() return 1 end
  e.GetSequence = function() return 0 end
  return e
end
MATERIAL_TRIANGLES, MATERIAL_FOG_LINEAR, MATERIAL_FOG_NONE, RENDERGROUP_OPAQUE = 2, 1, 0, 7
BOX_TOP, BOX_FRONT = 0, 1
TEXT_ALIGN_CENTER, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM = 1, 2, 4
