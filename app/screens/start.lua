-- Start: Play, Bridge for games (Windows), Play together; the device chip and settings on top.
local ui = require("ui")
local S = {}
local app, hills

function S.enter(a)
  app = a
  if not hills then
    hills = love.graphics.newImage("art/loopsnrings/hills.png")
    hills:setFilter("nearest", "nearest")
  end
end

-- the chip in the top bar: what's connected and how fast, or how to get started
local function chip_text()
  local v = app.op:values()
  local list = app.devices.list()
  local busy
  for _, c in ipairs(list) do
    if c.state == "connected" then
      local spd = v.speed_kmh and string.format("%.1f km/h", v.speed_kmh) or nil
      return c.name, spd, ui.c.green
    end
    if c.state == "connecting" or c.state == "exploring" or c.state == "reconnecting" then busy = c end
  end
  if busy then return busy.name, "connecting...", ui.c.sky end
  return "No device", "Pair", ui.c.muted
end

function S.draw_top(title)
  local c = ui.c
  -- logo: the player's runner + the name
  app.runner:draw(84, 92, 1.4)
  if title then ui.text(title, "pixel", 44, 120, 42, nil, nil, c.text)
  else
    ui.text("Omni", "pixel", 44, 120, 42, nil, nil, c.text)
    ui.text("Play", "pixel", 44, 120 + ui.text_w("Omni", "pixel", 44), 42, nil, nil, c.gold)
  end
  -- device chip
  local name, extra, dot = chip_text()
  local w = 52 + ui.text_w(name, "medium", 17) + (extra and 14 + ui.text_w(extra, "xbold", 17) or 0)
  local x = 1280 - 56 - 52 - 12 - w
  local hover, clicked = ui.region("chip", x, 44, w, 52)
  ui.rect(x, 44, w, 52, 26, hover and c.panel2 or c.panel, c.line, 2)
  ui.color(dot); love.graphics.circle("fill", x + 26, 70, 6)
  ui.text(name, "medium", 17, x + 44, 59)
  if extra then ui.text(extra, "xbold", 17, x + 58 + ui.text_w(name, "medium", 17), 59, nil, nil, dot == c.muted and c.gold or c.gold) end
  if clicked then app.go("pair") end
  if ui.round_button("settings", 1280 - 56 - 26, 70, 26, ui.icon.gear) then app.go("settings") end
end

local function card(id, x, y, w, h, gold)
  local hover, clicked = ui.region(id, x, y, w, h)
  local down = ui.pressed_id() == id
  local dy = down and 6 or 0
  if not down then ui.rect(x, y + 10, w, h, 28, gold and ui.c.gold_dark or ui.c.shade) end
  ui.rect(x, y + dy, w, h, 28, hover and ui.c.panel2 or ui.c.panel, gold and ui.c.gold or ui.c.line, gold and 4 or 3)
  return clicked, dy
end

function S.draw()
  local c = ui.c
  S.draw_top()
  local top, bottom = 132, 650
  local windows = app.platform.bridge
  -- Play
  local pw = windows and 704 or 1168
  local clicked, dy = card("play", 56, top, pw, bottom - top, true)
  do
    local x, y, w, h = 60, top + 4 + dy, pw - 8, bottom - top - 8
    love.graphics.stencil(function() love.graphics.rectangle("fill", x, y, w, h, 24, 24) end, "replace", 1)
    love.graphics.setStencilTest("greater", 0)
    local iw, ih = hills:getDimensions()
    local sc = math.max(w / (iw - 160), h / (ih - 90))
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(hills, x - 80 * sc, y - 60 * sc, 0, sc, sc)
    -- darken the bottom so the words read
    local mesh = love.graphics.newMesh({ { x, y + h * 0.45, 0, 0, 0.06, 0.09, 0.17, 0 }, { x + w, y + h * 0.45, 0, 0, 0.06, 0.09, 0.17, 0 },
      { x + w, y + h, 0, 0, 0.06, 0.09, 0.17, 0.95 }, { x, y + h, 0, 0, 0.06, 0.09, 0.17, 0.95 } }, "fan")
    love.graphics.draw(mesh)
    love.graphics.setStencilTest()
    ui.text("Play", "pixel", 72, x + 32, y + h - 128, nil, nil, c.text)
    ui.text("Run the hills at your real speed", "regular", 20, x + 32, y + h - 48, nil, nil, { 0.87, 0.89, 0.98 })
  end
  if clicked then app.go("soon", "play") end
  -- right column
  local rx, rw = 56 + pw + 28, 1168 - pw - 28
  if windows then
    local bh = 300
    local bc, bdy = card("bridge", rx, top, rw, bh)
    ui.text("Bridge for games", "pixel", 40, rx + 28, top + 26 + bdy, rw - 56)
    ui.text("Your bike becomes the controller in other games", "regular", 17, rx + 28, top + 76 + bdy, rw - 56, nil, c.muted)
    local cx = rx + 28
    for _, label in ipairs({ "Garry's Mod", "Tiny Atlas", "Any PC game" }) do
      local tw = ui.text_w(label, "medium", 15) + 28
      ui.rect(cx, top + bh - 66 + bdy, tw, 36, 18, c.panel2)
      ui.text(label, "medium", 15, cx, top + bh - 57 + bdy, tw, "center")
      cx = cx + tw + 8
    end
    if bc then app.go("soon", "bridge") end
    local ty = top + bh + 28
    local tc, tdy = card("together", rx, ty, rw, bottom - ty)
    ui.text("Play together", "bold", 24, rx + 28, ty + 34 + tdy)
    ui.text("Race friends with a code", "regular", 16, rx + 28, ty + 70 + tdy, nil, nil, c.muted)
    if tc then app.go("soon", "together") end
  end
  -- footer
  local v = app.op:values()
  local note = windows and "Android and the browser open straight into Play" or "Bridge for games is on Windows"
  ui.text(note, "regular", 15, 56, 676, nil, nil, c.muted)
  if v.distance_m and v.distance_m > 0 then
    ui.text(string.format("This session: %.2f km", v.distance_m / 1000), "regular", 15, 640, 676, 584, "right", c.muted)
  end
end

function S.back() love.event.quit() end

return S
