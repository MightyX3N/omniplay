-- A little Green Hills strip for the live test: sky, the forest far away, ground scrolling at the
-- player's speed and the runner on it. Drawn at the art's own pixel size into a canvas, then
-- scaled up, so the pixels stay square.
local M = {}
local tiles, quads
local SKY_TOP, SKY_BOTTOM = { 0.0, 0.47, 0.80 }, { 0.30, 0.78, 0.98 }

local function load()
  if tiles then return end
  tiles = love.graphics.newImage("art/loopsnrings/tileset.png")
  tiles:setFilter("nearest", "nearest")
  local W, H = tiles:getDimensions()
  quads = {
    grass = love.graphics.newQuad(16, 0, 16, 16, W, H),
    dirt = love.graphics.newQuad(64, 0, 16, 16, W, H),
    dark_tips = love.graphics.newQuad(80, 240, 32, 16, W, H),  -- far treeline
    red_tips = love.graphics.newQuad(112, 240, 32, 16, W, H),  -- nearer red trees
    red_body = love.graphics.newQuad(144, 240, 32, 16, W, H),
  }
end
local DARK = { 28 / 255, 18 / 255, 28 / 255 }

-- w, h: size in art pixels. Returns an object with :update(dt, kmh) and :draw(x, y, scale, runner)
function M.new(w, h)
  load()
  local self = setmetatable({ w = w, h = h, ground = 0, far = 0 }, { __index = M })
  self.canvas = love.graphics.newCanvas(w, h)
  self.canvas:setFilter("nearest", "nearest")
  return self
end

function M:update(dt, kmh)
  local px = (kmh or 0) / 3.6 * 16 * dt * 1.2 -- ~1 tile per metre, a little livelier
  self.ground = (self.ground + px) % 32
  self.far = (self.far + px * 0.15) % 64
end

function M:draw(x, y, scale, runner)
  local w, h = self.w, self.h
  love.graphics.push("all")
  love.graphics.setCanvas(self.canvas)
  love.graphics.origin()
  love.graphics.clear(0, 0, 0, 0)
  -- sky in bands, like the pack's own background
  for i = 0, 5 do
    local t = i / 5
    love.graphics.setColor(SKY_TOP[1] + (SKY_BOTTOM[1] - SKY_TOP[1]) * t, SKY_TOP[2] + (SKY_BOTTOM[2] - SKY_TOP[2]) * t,
      SKY_TOP[3] + (SKY_BOTTOM[3] - SKY_TOP[3]) * t)
    love.graphics.rectangle("fill", 0, math.floor(i * (h - 40) / 6), w, math.ceil((h - 40) / 6) + 1)
  end
  -- far forest in two layers, slower than the ground
  local gy = h - 32
  local far, near = math.floor(self.far) % 32, math.floor(self.far * 2) % 32
  love.graphics.setColor(1, 1, 1)
  for fx = -32, w + 32, 32 do love.graphics.draw(tiles, quads.dark_tips, fx - far, gy - 34) end
  love.graphics.setColor(DARK)
  love.graphics.rectangle("fill", 0, gy - 20, w, 12)
  love.graphics.setColor(1, 1, 1)
  for fx = -32, w + 32, 32 do
    love.graphics.draw(tiles, quads.red_tips, fx - near, gy - 24)
    love.graphics.draw(tiles, quads.red_body, fx - near, gy - 8)
  end
  -- ground: one row of grass, dirt below
  local off = math.floor(self.ground)
  for gx = -32, w + 16, 16 do
    love.graphics.draw(tiles, quads.grass, gx - off % 16, gy)
    love.graphics.draw(tiles, quads.dirt, gx - off % 16, gy + 16)
  end
  if runner then runner:draw(math.floor(w * 0.42), gy + 4, 1) end
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(self.canvas, x, y, 0, scale, scale)
end

return M
