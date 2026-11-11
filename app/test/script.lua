-- Plays OmniPlay like a person would, from a script, for testing:
--   OMNIPLAY_FAKE=1 OMNIPLAY_SCRIPT=/path/steps.lua love app
-- steps.lua returns a list of steps:
--   { wait = seconds }            { press = "widget id" }      { key = "escape" }
--   { effort = 0..3 }             { shot = "name" }            { resize = { w, h } }
--   { check = function(app) return ok, message end, name = "..." }
-- Screenshots go to <save folder>/shots/. Prints PASS / FAIL lines and quits with 1 on any failure.
local ui = require("ui")
local M = {}

function M.start(app, path)
  local steps = assert(dofile(path))
  local i, wait, fails, checks = 1, 0.3, 0, 0 -- let the first frames draw
  love.filesystem.createDirectory("shots")
  local self = {}
  local function log(s) io.write(s, "\n"); io.flush() end
  log("save folder: " .. love.filesystem.getSaveDirectory())

  function self.update(dt)
    if wait > 0 then wait = wait - dt; return end
    local s = steps[i]
    if not s then
      log(string.format("DONE %d checks, %d failed", checks, fails))
      love.event.quit(fails > 0 and 1 or 0)
      self.update = function() end
      return
    end
    i = i + 1
    if s.wait then wait = s.wait
    elseif s.press then
      local x, y = ui.center_of(s.press)
      if not x then fails = fails + 1; log("FAIL press: no widget '" .. s.press .. "' on screen"); return end
      love.mouse.setPosition(x, y)
      ui.mousepressed(x, y, 1)
      ui.mousereleased(x, y, 1)
      wait = 0.15
      log("press " .. s.press)
    elseif s.key then love.keypressed(s.key); wait = 0.1
    elseif s.effort then app.bt.effort = s.effort; log("effort " .. s.effort)
    elseif s.resize then love.window.setMode(s.resize[1], s.resize[2], { resizable = true }); ui.resize(s.resize[1], s.resize[2]); wait = 0.3
    elseif s.shot then
      local name = s.shot
      love.graphics.captureScreenshot(function(img) img:encode("png", "shots/" .. name .. ".png") end)
      log("shot " .. name)
      wait = 0.1
    elseif s.check then
      checks = checks + 1
      local ok, msg = s.check(app)
      if ok then log("PASS " .. (s.name or "check")) else fails = fails + 1; log("FAIL " .. (s.name or "check") .. ": " .. tostring(msg)) end
    end
  end
  return self
end

return M
