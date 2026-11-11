function love.conf(t)
  t.identity = "OmniPlay"
  t.version = "11.5"
  t.window.title = "OmniPlay"
  t.window.width, t.window.height = 1280, 720
  t.window.minwidth, t.window.minheight = 960, 540
  t.window.resizable = true
  t.window.vsync = 1
  t.window.highdpi = false
  t.modules.physics = false
  t.modules.video = false
end
