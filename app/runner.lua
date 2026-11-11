-- The player's character: Mucho Pixels sprite sheets (art/muchopixels, built by
-- tools/pack_characters.py) with the shirt recoloured per player by a small shader.
local anim8 = require("lib.anim8")
local M = {}

local ROWS = { idle = 1, walk = 2, run = 3, jump = 4, fall = 5, land = 6, damage = 7 }
local COUNT = { idle = 8, walk = 8, run = 8, jump = 2, fall = 2, land = 2, damage = 2 }
local FOOT_X, FOOT_Y = 34, 45 -- where the feet are in a 64x64 frame
-- seconds per frame for each gait; sprint is the run played faster
local GAIT = { stopped = { "idle", 0.14 }, walk = { "walk", 0.11 }, run = { "run", 0.085 }, sprint = { "run", 0.055 } }

local sheets = {}
local shader

local function sheet(gender, char, outfit)
  local key = gender .. "_" .. char .. "_" .. outfit
  if not sheets[key] then
    local img = love.graphics.newImage("art/muchopixels/" .. key .. ".png")
    img:setFilter("nearest", "nearest")
    sheets[key] = img
  end
  return sheets[key]
end

function M.shader()
  if not shader then
    shader = love.graphics.newShader([[
      extern vec3 tint;
      vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
        vec4 p = Texel(tex, uv);
        if (p.a > 0.5 && p.g < 0.02 && abs(p.r - p.b) < 0.02) {
          if (p.r > 0.9) p.rgb = tint * 0.95;
          else if (p.r > 0.45 && p.r < 0.55) p.rgb = tint * 0.70;
        }
        return p * color;
      }
    ]])
  end
  return shader
end

-- look: gender ("male"/"female"), char (1-3), outfit (1-3), shirt {r,g,b}
function M.new(gender, char, outfit, shirt)
  local self = setmetatable({}, { __index = M })
  self:set_look(gender, char, outfit, shirt)
  self.gait, self.anim_name = "stopped", "idle"
  self.anim = self.anims.idle
  return self
end

function M:set_look(gender, char, outfit, shirt)
  self.img = sheet(gender, char, outfit)
  self.shirt = shirt
  local g = anim8.newGrid(64, 64, self.img:getWidth(), self.img:getHeight())
  self.anims = {}
  for name, row in pairs(ROWS) do self.anims[name] = anim8.newAnimation(g("1-" .. COUNT[name], row), 0.1) end
  if self.anim_name then self.anim = self.anims[self.anim_name] end
end

function M:set_gait(gait)
  if gait == self.gait then return end
  self.gait = gait
  local a = GAIT[gait] or GAIT.stopped
  if a[1] ~= self.anim_name then
    self.anim_name = a[1]
    self.anim = self.anims[a[1]]
    self.anim:gotoFrame(1)
  end
end

function M:update(dt)
  local a = GAIT[self.gait] or GAIT.stopped
  self.anim:update(dt * 0.1 / a[2])
end

-- draw with the feet at (x, y); scale in screen pixels per sprite pixel; angle in radians
function M:draw(x, y, scale, angle, flip)
  love.graphics.setShader(M.shader())
  M.shader():send("tint", self.shirt)
  love.graphics.setColor(1, 1, 1)
  self.anim:draw(self.img, x, y, angle or 0, (flip and -1 or 1) * scale, scale, FOOT_X, FOOT_Y)
  love.graphics.setShader()
end

return M
