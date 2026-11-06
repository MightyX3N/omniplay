function love.conf(t)
  t.identity = "omniplay"
  local ok, v = pcall(require, "version")
  t.window.title = "OmniPlay probe  (build " .. (ok and v or "dev") .. ")"
  t.window.width = 900
  t.window.height = 640
  t.window.resizable = true
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.audio = false
  t.modules.sound = false
end
