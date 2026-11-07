-- LÖVE: a rider on a hill. Copy sdk/love/omniplay.lua next to this file and run `love .`
-- Works without OmniPlay too: hold the up arrow.
local omniplay = require("omniplay")
local x, speed = 0, 0

function love.load() omniplay.set_game("LÖVE example") end

local function ground(px) return 300 + 60 * math.sin(px / 300) end

function love.update(dt)
  local v = omniplay.values() -- nil when OmniPlay isn't running
  if v then speed = v.speed_kmh / 3.6 * 40 -- 40 pixels per metre
  else speed = love.keyboard.isDown("up") and 200 or speed * 0.95 end
  x = x + speed * dt
  -- the slope under the rider, in %, goes to the bike / walking pad
  local grade = -(ground(x + 20) - ground(x - 20)) / 40 * 100 -- screen y points down
  omniplay.set_grade(math.floor(grade * 2 + 0.5) / 2)
end

function love.draw()
  love.graphics.translate(200 - x, 0)
  for px = x - 200, x + 800, 8 do love.graphics.line(px, ground(px), px + 8, ground(px + 8)) end
  love.graphics.circle("fill", x, ground(x) - 12, 12)
  love.graphics.origin()
  local v = omniplay.values()
  love.graphics.print(v and string.format("%.1f km/h  %d rpm  hill sent", v.speed_kmh, v.cadence) or "OmniPlay not running: hold up", 10, 10)
end

function love.quit() omniplay.release() end
