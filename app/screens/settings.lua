-- Settings: what games may change on your device, and how your runner looks.
local ui = require("ui")
local S = {}
local app

function S.enter(a) app = a end

local function changed()
  app.settings.save()
  app.settings.apply(app.op)
  local g, ch, o = app.settings.look()
  app.runner:set_look(g, ch, o, app.settings.data.shirt)
end

function S.update(dt) app.runner:update(dt) end

function S.draw()
  local c, d = ui.c, app.settings.data
  if ui.round_button("back", 82, 70, 26, ui.icon.back) then app.back() end
  ui.text("Settings", "pixel", 44, 124, 42)

  -- what games may do
  local x, y, w = 56, 128, 640
  ui.rect(x, y, w, 520, 28, c.panel, c.line, 3)
  ui.text("What games may do", "bold", 22, x + 28, y + 26)
  ui.text("These apply to OmniPlay's own game and to every game using the Bridge.", "regular", 15, x + 28, y + 60, w - 56, nil, c.muted)

  ui.text("Set hills on my bike or treadmill", "medium", 18, x + 28, y + 118, w - 140)
  ui.text("Climbs feel heavier, downhills lighter.", "regular", 14, x + 28, y + 144, w - 140, nil, c.muted)
  if ui.toggle("hills", d.allow_hills, x + w - 92, y + 120) then d.allow_hills = not d.allow_hills; changed() end

  ui.text("Change my walking pad's speed", "medium", 18, x + 28, y + 206, w - 140)
  ui.text("Off unless you turn it on: you're the one standing on the belt.", "regular", 14, x + 28, y + 232, w - 140, nil, c.muted)
  if ui.toggle("belt", d.allow_belt, x + w - 92, y + 208) then d.allow_belt = not d.allow_belt; changed() end

  local dim = not d.allow_belt
  ui.text("Fastest it may set", "medium", 18, x + 28, y + 296, nil, nil, dim and c.muted or c.text)
  ui.text(string.format("%.1f km/h", d.max_belt_kmh), "xbold", 22, x + w - 236, y + 294, 120, "center", dim and c.muted or c.gold)
  if ui.step("belt-", "-", x + w - 284, y + 288) then d.max_belt_kmh = math.max(1, d.max_belt_kmh - 0.5); changed() end
  if ui.step("belt+", "+", x + w - 108, y + 288) then d.max_belt_kmh = math.min(8, d.max_belt_kmh + 0.5); changed() end

  ui.text("Devices you connect are remembered and connect again when OmniPlay starts. Disconnect one on the Pair screen to forget it.",
    "regular", 14, x + 28, y + 400, w - 56, nil, c.muted)

  -- your runner
  local rx, rw = 724, 500
  ui.rect(rx, y, rw, 520, 28, c.panel, c.line, 3)
  ui.text("Your runner", "bold", 22, rx + 28, y + 26)
  ui.rect(rx + 28, y + 70, rw - 56, 190, 20, c.panel2)
  app.runner:set_gait("stopped")
  app.runner:draw(rx + rw / 2, y + 248, 4)

  local looks = app.settings.LOOKS
  ui.text("Character", "medium", 17, rx + 28, y + 290)
  if ui.step("look-", "<", rx + rw - 216, y + 282) then d.look = (d.look - 2) % #looks + 1; changed() end
  ui.text(d.look .. " / " .. #looks, "bold", 18, rx + rw - 168, y + 291, 104, "center")
  if ui.step("look+", ">", rx + rw - 68, y + 282) then d.look = d.look % #looks + 1; changed() end

  ui.text("Outfit", "medium", 17, rx + 28, y + 344)
  if ui.step("outfit-", "<", rx + rw - 216, y + 336) then d.outfit = (d.outfit - 2) % 3 + 1; changed() end
  ui.text(d.outfit .. " / 3", "bold", 18, rx + rw - 168, y + 345, 104, "center")
  if ui.step("outfit+", ">", rx + rw - 68, y + 336) then d.outfit = d.outfit % 3 + 1; changed() end

  ui.text("Shirt colour", "medium", 17, rx + 28, y + 400)
  local sx = rx + 28
  for i, col in ipairs(app.settings.SHIRTS) do
    local bx = sx + (i - 1) * 54
    local hover, clicked = ui.region("shirt" .. i, bx, y + 432, 44, 44)
    local on = math.abs(d.shirt[1] - col[1]) + math.abs(d.shirt[2] - col[2]) + math.abs(d.shirt[3] - col[3]) < 0.01
    if on then ui.rect(bx - 5, y + 427, 54, 54, 16, nil, c.gold, 3) end
    ui.rect(bx, y + 432, 44, 44, 12, col, hover and c.text or nil, 2)
    if clicked then d.shirt = { col[1], col[2], col[3] }; changed() end
  end

  if ui.button("done", "Done", 1224 - 180, 652, 180, 52, "gold", 20) then app.back() end
end

function S.back() app.back() end

return S
