function love.conf(t)
  t.identity = "omniplay"
  t.window.title = "OmniPlay probe"
  t.window.width = 900
  t.window.height = 640
  t.window.resizable = true
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.audio = false
  t.modules.sound = false
end
