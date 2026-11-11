-- OmniPlay: connects bikes, walking pads, sensors and heart-rate straps (through the OmniPlay SDK)
-- and lets you play with them. Screens live in screens/, devices in devices.lua.
--   love app            real Bluetooth (Windows)
--   love app --fake     pretend devices, for testing without hardware
local ui = require("ui")

-- the SDK: copied into lib/ by the build, read straight from the repo when running from source
local function load_sdk()
  local ok, sdk = pcall(require, "lib.omniplay")
  if ok then return sdk end
  local path = love.filesystem.getSource() .. "/../sdk/lua/omniplay.lua"
  local f = io.open(path, "rb")
  if not f then error("The OmniPlay SDK is missing (lib/omniplay.lua or " .. path .. ")") end
  local src = f:read("*a")
  f:close()
  return assert(loadstring(src, "@sdk/lua/omniplay.lua"))()
end

local app = { stack = {}, platform = {} }
local screens = {}
local script

local function current() return app.stack[#app.stack] end

function app.go(name, arg)
  local cur = current()
  if cur and cur.screen.leave then cur.screen.leave() end
  local s = screens[name]
  app.stack[#app.stack + 1] = { name = name, screen = s }
  if s.enter then s.enter(app, arg) end
end

function app.back()
  if #app.stack <= 1 then love.event.quit() return end
  local cur = table.remove(app.stack)
  if cur.screen.leave then cur.screen.leave() end
  local prev = current()
  if prev.screen.enter then prev.screen.enter(app) end
end

function love.load(args)
  love.graphics.setDefaultFilter("nearest", "nearest")
  ui.resize(love.graphics.getDimensions())
  local fake = os.getenv("OMNIPLAY_FAKE") == "1"
  for _, a in ipairs(args or {}) do if a == "--fake" then fake = true end end

  app.sdk = load_sdk()
  app.settings = require("settings")
  app.settings.load()
  app.devices = require("devices")
  local ok, v = pcall(require, "version")
  app.version = ok and v or "dev"

  -- Bluetooth backend
  local bt, err
  if fake then bt = require("bt.fake").load(app.sdk)
  else bt, err = require("bt.win").load() end
  app.platform = {
    fake = fake, bt = bt ~= nil, bt_error = err and "Bluetooth isn't available here" or nil,
    bridge = love.system.getOS() == "Windows" or fake or os.getenv("OMNIPLAY_BRIDGE") == "1",
  }
  app.bt = bt

  app.op = app.sdk.new({
    bytes_out = "table",
    send = function(id, char, bytes) app.devices.send(id, char, bytes) end,
  })
  app.settings.apply(app.op)
  app.devices.init(bt, app.op, app.sdk, app.settings)

  local Runner = require("runner")
  local g, ch, o = app.settings.look()
  app.runner = Runner.new(g, ch, o, app.settings.data.shirt)

  for _, n in ipairs({ "start", "pair", "settings", "soon" }) do screens[n] = require("screens." .. n) end
  app.go("start")
  if bt then app.devices.reconnect_remembered() end

  local sp = os.getenv("OMNIPLAY_SCRIPT")
  if sp then
    -- in a test run an error prints and quits instead of showing LÖVE's error screen
    love.errorhandler = function(msg)
      io.write("ERROR ", tostring(msg), "\n", debug.traceback(), "\n"); io.flush()
      os.exit(2)
    end
    script = require("test.script").start(app, sp)
  end
end

function love.update(dt)
  dt = math.min(dt, 0.1)
  app.devices.update(dt)
  local v = app.op:values()
  app.runner:set_gait(v.gait or "stopped")
  app.runner:update(dt)
  local s = current().screen
  if s.update then s.update(dt) end
  if script then script.update(dt) end
end

function love.draw()
  love.graphics.clear(ui.c.bg)
  ui.begin()
  current().screen.draw()
  ui.finish()
end

function love.resize(w, h) ui.resize(w, h) end
function love.mousepressed(x, y, b) ui.mousepressed(x, y, b) end
function love.mousereleased(x, y, b) ui.mousereleased(x, y, b) end
function love.wheelmoved(x, y)
  local s = current().screen
  if s.wheelmoved then s.wheelmoved(x, y) end
end
function love.keypressed(key)
  if key == "escape" then
    local s = current().screen
    if s.back then s.back() else app.back() end
  elseif app.platform.fake and key:match("^[0-3]$") then
    app.bt.effort = tonumber(key)
  end
end
function love.quit()
  for _, c in ipairs(app.devices.list()) do app.devices.disconnect(c.addr) end
  app.devices.scan(false)
end

return app
