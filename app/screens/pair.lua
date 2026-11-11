-- Pair your gear: your devices and nearby ones on the left, the live test on the right.
local ui = require("ui")
local Scene = require("scene")
local S = {}
local app, scene, scroll = nil, nil, 0
local show_all = false

function S.enter(a)
  app = a
  scene = scene or Scene.new(200, 84)
  app.devices.scan(true)
  scroll = 0
end
function S.leave() app.devices.scan(false) end

local STATE_TEXT = {
  exploring = "Checking what it is...", connecting = "Connecting...", reconnecting = "Reconnecting...",
  connected = "Connected", unknown = "Not a device OmniPlay knows", failed = "Couldn't connect",
}

function S.update(dt)
  local v = app.op:values()
  scene:update(dt, v.moving and (v.speed_kmh or 12) or 0)
end

local LIST_TOP, LIST_BOTTOM = 128, 640
-- an icon guess from what a device advertises (the scan's service flags), before it's connected
local function kind_from_flags(d)
  local f = d.flags or 0
  if d.name:upper():find("SPERAX") or f % 64 >= 32 then return "sperax" end
  if f % 2 == 1 then return "ftms_bike" end
  if f % 32 >= 16 then return "hr" end
  if f % 8 >= 4 then return "csc" end
  if f % 4 >= 2 then return "rsc" end
  return nil
end
local function device_row(id, x, y, w, kind, name, sub, sub_color, state, button, button_style)
  local c = ui.c
  local h = 88
  if y + h < LIST_TOP or y > LIST_BOTTOM then return h, false end -- scrolled out of view
  local live = state == "connected"
  ui.rect(x, y, w, h, 22, c.panel, live and c.green or c.line, 3)
  ui.rect(x + 18, y + 16, 56, 56, 16, c.panel2)
  ui.color(live and c.green or c.muted)
  ui.icon.for_kind(kind)(x + 46, y + 44)
  ui.text(name, "bold", 20, x + 92, y + 18, w - 92 - 170)
  ui.text(sub, "regular", 15, x + 92, y + 48, w - 92 - 170, nil, sub_color or c.muted)
  local clicked = false
  if button then
    local bw = 132
    clicked = ui.button(id, button, x + w - bw - 18, y + 22, bw, 44, button_style or "gold", 16)
  end
  return h, clicked
end

function S.draw()
  local c = ui.c
  -- header
  if ui.round_button("back", 82, 70, 26, ui.icon.back) then app.back() end
  ui.text("Pair your gear", "pixel", 44, 124, 42)
  local status = app.devices.scanning and "Looking for devices... turn yours on" or "Bluetooth isn't on"
  if not app.platform.bt then status = app.platform.bt_error or "Bluetooth isn't available here" end
  ui.color(app.devices.scanning and c.sky or c.red); love.graphics.circle("fill", 1224 - ui.text_w(status, "regular", 16) - 16, 71, 5)
  ui.text(status, "regular", 16, 700, 61, 524, "right", c.muted)

  -- left: your devices, then nearby
  local x, w, y0, y1 = 56, 584, 128, 640
  love.graphics.setScissor(ui.ox + x * ui.s, ui.oy + y0 * ui.s, (w + 8) * ui.s, (y1 - y0) * ui.s)
  local y = y0 - scroll
  local mine = app.devices.list()
  local listed = {}
  if #mine > 0 then
    ui.text("YOUR DEVICES", "bold", 13, x, y, nil, nil, c.muted); y = y + 26
    for _, d in ipairs(mine) do
      listed[d.addr] = true
      local sub = (d.kind and app.devices.label(d.kind) .. " · " or "") .. (STATE_TEXT[d.state] or d.state)
      if d.hint and d.state ~= "connected" then sub = d.hint end
      local col = d.state == "connected" and c.green or (d.state == "unknown" or d.state == "failed") and c.red or c.sky
      local btn, style = "Disconnect", "dark"
      if d.state == "unknown" or d.state == "failed" then btn, style = "Remove", "dark" end
      local h, clicked = device_row("dev:" .. d.addr, x, y, w, d.kind, d.name, sub, col, d.state, btn, style)
      if clicked then
        app.devices.disconnect(d.addr)
        app.settings.forget(d.addr)
      end
      y = y + h + 12
    end
    y = y + 10
  end
  local near = {}
  for _, d in ipairs(app.devices.nearby(show_all)) do if not listed[d.addr] then near[#near + 1] = d end end
  ui.text("NEARBY", "bold", 13, x, y, nil, nil, c.muted); y = y + 26
  if #near == 0 then
    ui.rect(x, y, w, 88, 22, nil, c.line, 2)
    ui.text(app.platform.bt and "Nothing yet. Turn your bike, walking pad or sensor on and start moving." or
      "OmniPlay can't use Bluetooth on this computer.", "regular", 16, x + 24, y + 22, w - 48, nil, c.muted)
    y = y + 100
  end
  for _, d in ipairs(near) do
    local known = (d.flags or 0) ~= 0 or d.name:upper():find("SPERAX")
    local h, clicked = device_row("near:" .. d.addr, x, y, w, kind_from_flags(d), d.name,
      known and "Fitness device" or "Other Bluetooth device", nil,
      nil, "Connect", "gold")
    if clicked then app.devices.connect(d) end
    y = y + h + 12
  end
  if app.platform.bt then
    local lh, lc = ui.region("showall", x, y, w, 30)
    ui.text(show_all and "Hide other Bluetooth devices" or "My device isn't listed", "medium", 15, x, y + 6, nil, nil, lh and c.text or c.gold)
    if lc then show_all = not show_all end
    y = y + 40
  end
  love.graphics.setScissor()
  local content = y + scroll - y0
  S.max_scroll = math.max(0, content - (y1 - y0))
  scroll = math.min(scroll, S.max_scroll)

  -- right: live test
  local rx, ry, rw, rh = 668, 128, 556, 512
  ui.rect(rx, ry, rw, rh, 28, c.panel, c.line, 3)
  ui.text("Live test", "bold", 22, rx + 28, ry + 24)
  local v = app.op:values()
  local hint = not app.devices.any_connected() and "Connect a device first" or
    (v.moving and "That's you!" or (v.kind == "sperax" or v.kind == "ftms_treadmill") and "Start walking and watch" or "Pedal and watch")
  ui.text(hint, "regular", 15, rx + 28, ry + 30, rw - 56, "right", c.muted)
  app.runner:set_gait(v.gait or "stopped")
  local sw, sh = rw - 56, 208
  local sc = sw / 200
  love.graphics.stencil(function() love.graphics.rectangle("fill", rx + 28, ry + 68, sw, sh, 18, 18) end, "replace", 1)
  love.graphics.setStencilTest("greater", 0)
  scene:draw(rx + 28, ry + 68, sc, app.runner)
  love.graphics.setStencilTest()
  -- gait
  local gaits = { { "stopped", "Stopped" }, { "walk", "Walk" }, { "run", "Run" }, { "sprint", "Sprint" } }
  local gw = (sw - 24) / 4
  for i, g in ipairs(gaits) do
    local on = (v.gait or "stopped") == g[1]
    local gx = rx + 28 + (i - 1) * (gw + 8)
    ui.rect(gx, ry + 292, gw, 40, 12, on and c.gold or c.panel2)
    ui.text(g[2], on and "xbold" or "bold", 15, gx, ry + 303, gw, "center", on and c.ink or c.muted)
  end
  -- numbers
  local function name_of(id)
    local d = id and app.devices.conns[id]
    return d and d.name or nil
  end
  local nums = {
    { v.speed_kmh and string.format("%.1f", v.speed_kmh), "km/h", v.sources.speed },
    { v.cadence and string.format("%d", math.floor(v.cadence + 0.5)), (v.kind == "sperax" or v.kind == "ftms_treadmill" or v.kind == "rsc") and "steps/min" or "rpm", v.sources.cadence },
    { v.power and string.format("%d", v.power), "watts", v.sources.power },
    { v.hr and v.hr > 0 and string.format("%d", v.hr), "heart rate", v.sources.hr },
  }
  local nw = sw / 4
  for i, n in ipairs(nums) do
    local nx = rx + 28 + (i - 1) * nw
    ui.text(n[1] or "–", "xbold", 28, nx, ry + 352, nw - 8, nil, n[1] and c.text or { 0.42, 0.46, 0.6 })
    ui.text(n[2], "regular", 14, nx, ry + 390, nw - 8, nil, c.muted)
    local src = name_of(n[3])
    if src and n[1] then ui.text("from " .. src, "regular", 13, nx, ry + 410, nw - 8, nil, { 0.52, 0.57, 0.74 }) end
  end
  if app.platform.fake then
    ui.text("Pretend devices: keys 0-3 set how hard the pretend rider goes", "regular", 13, rx + 28, ry + rh - 34, sw, nil, c.muted)
  end

  if ui.button("done", "Done", 1224 - 180, 652, 180, 52, "gold", 20) then app.back() end
end

function S.wheelmoved(_, dy) scroll = math.max(0, math.min(S.max_scroll or 0, scroll - dy * 40)) end
function S.back() app.back() end

return S
