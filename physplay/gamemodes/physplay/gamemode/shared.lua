-- PhysPlay: ride and run through a real-scale world with your bike, walking pad or footpod
-- (through OmniPlay), or with the keyboard. Based on OpenRadlr (AGPL-3.0).
GM.Name = "PhysPlay"
GM.Author = "PhysPlay contributors"
GM.TeamBased = false
DeriveGamemode("base")

if SERVER then AddCSLuaFile("omniplay_bridge.lua") AddCSLuaFile("sh_world.lua") end
include("omniplay_bridge.lua")
include("sh_world.lua")

-- route and map data
local index = include("data/index.lua")
if SERVER then for _, f in ipairs(index.files) do AddCSLuaFile("data/" .. f) end end
local t0 = SysTime()
PP.LoadData(function(name) return include("data/" .. name) end)
print(string.format("[PhysPlay] %s loaded with %d routes in %.2f s", PP.map.name, #PP.route_ids, SysTime() - t0))

PP.MODE = { BIKE = 0, RUN = 1, KEYS = 2 }
