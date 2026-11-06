function love.conf(t)
  t.identity = "omniplay"
  t.appendidentity = true -- the app's own files win over anything in the save folder
  local ok, v = pcall(require, "version")
  t.window.title = "OmniPlay  (build " .. (ok and v or "dev") .. ")"
  t.window.width = 1060
  t.window.height = 720
  t.window.minwidth = 900
  t.window.minheight = 600
  t.window.resizable = true
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.audio = false
  t.modules.sound = false
end
