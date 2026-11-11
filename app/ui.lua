-- Look and widgets. Everything is laid out on a 1280x720 virtual screen that is scaled to the
-- window (letterboxed); fonts are rebuilt at the real pixel size so text stays sharp.
-- Widgets are immediate-mode: call them every frame from draw(); they return true when clicked.
local M = { W = 1280, H = 720, s = 1, ox = 0, oy = 0, rects = {}, prev_rects = {} }

M.c = {
  bg = { 0.063, 0.086, 0.169 },        -- #10162B
  panel = { 0.102, 0.133, 0.251 },     -- #1A2240
  panel2 = { 0.137, 0.176, 0.322 },    -- #232D52
  line = { 0.204, 0.251, 0.420 },      -- #34406B
  text = { 0.957, 0.965, 1.0 },        -- #F4F6FF
  muted = { 0.663, 0.702, 0.839 },     -- #A9B3D6
  soft = { 0.784, 0.816, 0.933 },      -- #C8D0EE
  gold = { 1.0, 0.773, 0.192 },        -- #FFC531
  gold_dark = { 0.722, 0.525, 0.043 }, -- #B8860B
  green = { 0.357, 0.831, 0.416 },     -- #5BD46A
  sky = { 0.204, 0.714, 0.941 },       -- #34B6F0
  red = { 1.0, 0.42, 0.42 },           -- #FF6B6B
  shade = { 0.039, 0.059, 0.122 },     -- #0A0F1F
  ink = { 0.063, 0.086, 0.169 },
}

local FONT_FILES = {
  regular = "art/fonts/Rubik-Regular.ttf", medium = "art/fonts/Rubik-Medium.ttf", bold = "art/fonts/Rubik-Bold.ttf",
  xbold = "art/fonts/Rubik-ExtraBold.ttf", pixel = "art/fonts/PixelifySans-Bold.ttf",
}
local fonts = {}

function M.resize(w, h)
  M.s = math.min(w / M.W, h / M.H)
  M.ox, M.oy = math.floor((w - M.W * M.s) / 2), math.floor((h - M.H * M.s) / 2)
  fonts = {}
end

-- a font at a virtual size; it is created at the real pixel size and drawn scaled back down
function M.font(kind, size)
  local key = kind .. size
  if not fonts[key] then
    local px = math.max(6, math.floor(size * M.s + 0.5))
    local f = love.graphics.newFont(FONT_FILES[kind], px)
    f:setFilter("linear", "linear")
    fonts[key] = { f = f, k = size / px }
  end
  return fonts[key]
end

function M.to_virtual(x, y) return (x - M.ox) / M.s, (y - M.oy) / M.s end
function M.mouse() return M.to_virtual(love.mouse.getPosition()) end

function M.begin()
  M.prev_rects, M.rects = M.rects, {}
  love.graphics.push()
  love.graphics.translate(M.ox, M.oy)
  love.graphics.scale(M.s)
end
function M.finish() love.graphics.pop() end

function M.color(c, a) love.graphics.setColor(c[1], c[2], c[3], a or c[4] or 1) end

function M.rect(x, y, w, h, r, fill, line, lw)
  if fill then M.color(fill); love.graphics.rectangle("fill", x, y, w, h, r, r) end
  if line then
    M.color(line); love.graphics.setLineWidth(lw or 2)
    local i = (lw or 2) / 2
    love.graphics.rectangle("line", x + i, y + i, w - 2 * i, h - 2 * i, math.max(0, r - i), math.max(0, r - i))
  end
end

-- text in a box: align left / center / right; returns the height it used
function M.text(str, kind, size, x, y, w, align, color, alpha)
  local F = M.font(kind, size)
  M.color(color or M.c.text, alpha)
  love.graphics.setFont(F.f)
  if w then
    love.graphics.printf(str, x, y, w / F.k, align or "left", 0, F.k, F.k)
    local _, lines = F.f:getWrap(str, w / F.k)
    return #lines * F.f:getHeight() * F.k
  end
  love.graphics.print(str, x, y, 0, F.k, F.k)
  return F.f:getHeight() * F.k
end
function M.text_w(str, kind, size) local F = M.font(kind, size); return F.f:getWidth(str) * F.k end
function M.text_h(kind, size) local F = M.font(kind, size); return F.f:getHeight() * F.k end

-- ---------- input ----------
local press = { down = false, id = nil }
function M.hit(x, y, w, h)
  local mx, my = M.mouse()
  return mx >= x and mx < x + w and my >= y and my < y + h
end
-- register a clickable rect; returns hovered, clicked
local clicked_id
function M.region(id, x, y, w, h)
  M.rects[id] = { x = x, y = y, w = w, h = h }
  local hover = M.hit(x, y, w, h)
  local c = clicked_id == id
  if c then clicked_id = nil end
  return hover, c
end
function M.mousepressed(x, y, b)
  if b ~= 1 then return end
  local vx, vy = M.to_virtual(x, y)
  press.down, press.id = true, nil
  for id, r in pairs(M.rects) do
    if vx >= r.x and vx < r.x + r.w and vy >= r.y and vy < r.y + r.h then press.id = id end
  end
end
function M.mousereleased(x, y, b)
  if b ~= 1 or not press.down then return end
  press.down = false
  local vx, vy = M.to_virtual(x, y)
  local r = press.id and M.rects[press.id]
  if r and vx >= r.x and vx < r.x + r.w and vy >= r.y and vy < r.y + r.h then clicked_id = press.id end
  press.id = nil
end
function M.pressed_id() return press.down and press.id or nil end
-- the centre of a widget drawn last frame, in window pixels (for the test script)
function M.center_of(id)
  local r = M.rects[id] or M.prev_rects[id]
  if not r then return nil end
  return M.ox + (r.x + r.w / 2) * M.s, M.oy + (r.y + r.h / 2) * M.s
end

-- ---------- widgets ----------
-- style: "gold" (main action), "dark" (secondary), "ghost" (outline only)
function M.button(id, label, x, y, w, h, style, size)
  style = style or "gold"
  local hover, clicked = M.region(id, x, y, w, h)
  local down = M.pressed_id() == id
  local dy = down and 4 or 0
  if style == "gold" then
    if not down then M.rect(x, y + 5, w, h, 14, M.c.gold_dark) end
    M.rect(x, y + dy, w, h, 14, hover and { 1, 0.85, 0.4 } or M.c.gold)
    M.text(label, "xbold", size or 18, x, y + dy + (h - M.text_h("xbold", size or 18)) / 2, w, "center", M.c.ink)
  elseif style == "dark" then
    M.rect(x, y + dy, w, h, 14, hover and M.c.panel2 or M.c.panel, M.c.line, 3)
    M.text(label, "bold", size or 18, x, y + dy + (h - M.text_h("bold", size or 18)) / 2, w, "center", M.c.text)
  else
    M.rect(x, y, w, h, 14, nil, hover and M.c.soft or M.c.line, 3)
    M.text(label, "bold", size or 18, x, y + (h - M.text_h("bold", size or 18)) / 2, w, "center", hover and M.c.text or M.c.soft)
  end
  return clicked
end

function M.round_button(id, x, y, r, draw_icon)
  local hover, clicked = M.region(id, x - r, y - r, 2 * r, 2 * r)
  M.color(hover and M.c.panel2 or M.c.panel); love.graphics.circle("fill", x, y, r)
  M.color(M.c.line); love.graphics.setLineWidth(2); love.graphics.circle("line", x, y, r - 1)
  M.color(hover and M.c.text or M.c.muted)
  draw_icon(x, y)
  return clicked
end

function M.toggle(id, on, x, y)
  local w, h = 64, 36
  local _, clicked = M.region(id, x, y, w, h)
  M.rect(x, y, w, h, h / 2, on and M.c.gold or M.c.panel2, not on and M.c.line or nil, 2)
  M.color(on and M.c.ink or M.c.muted)
  love.graphics.circle("fill", on and x + w - h / 2 or x + h / 2, y + h / 2, h / 2 - 6)
  return clicked
end

-- small round +/- button
function M.step(id, label, x, y)
  local hover, clicked = M.region(id, x, y, 40, 40)
  M.rect(x, y, 40, 40, 12, hover and M.c.line or M.c.panel2)
  M.text(label, "xbold", 22, x, y + 6, 40, "center", M.c.text)
  return clicked
end

-- ---------- icons (simple strokes, drawn around a centre) ----------
M.icon = {}
function M.icon.back(x, y)
  love.graphics.setLineWidth(3)
  love.graphics.line(x + 4, y - 8, x - 4, y, x + 4, y + 8)
end
function M.icon.gear(x, y)
  love.graphics.setLineWidth(3)
  love.graphics.circle("line", x, y, 5)
  for i = 0, 7 do
    local a = i * math.pi / 4
    love.graphics.line(x + math.cos(a) * 8, y + math.sin(a) * 8, x + math.cos(a) * 11, y + math.sin(a) * 11)
  end
end
function M.icon.bike(x, y)
  love.graphics.setLineWidth(2.5)
  love.graphics.circle("line", x - 8, y + 5, 6); love.graphics.circle("line", x + 8, y + 5, 6)
  love.graphics.line(x - 8, y + 5, x - 2, y - 5, x + 5, y - 5, x + 8, y + 5)
  love.graphics.line(x - 2, y - 5, x + 1, y + 5, x + 5, y - 5)
  love.graphics.line(x - 4, y - 8, x, y - 8)
end
function M.icon.pad(x, y)
  love.graphics.setLineWidth(2.5)
  love.graphics.line(x - 13, y + 7, x + 13, y + 7)
  love.graphics.line(x - 10, y + 7, x - 7, y - 1, x + 9, y - 1, x + 11, y + 7)
  love.graphics.line(x + 5, y - 1, x + 7, y - 9)
end
function M.icon.sensor(x, y)
  love.graphics.setLineWidth(2.5)
  love.graphics.circle("line", x, y, 10)
  love.graphics.line(x, y, x, y - 6); love.graphics.line(x, y, x + 5, y + 3)
end
function M.icon.heart(x, y)
  love.graphics.setLineWidth(2.5)
  love.graphics.line(x, y + 9, x - 10, y - 1, x - 9, y - 7, x - 4, y - 9, x, y - 4, x + 4, y - 9, x + 9, y - 7, x + 10, y - 1, x, y + 9)
end
function M.icon.foot(x, y)
  love.graphics.setLineWidth(2.5)
  love.graphics.ellipse("line", x, y + 2, 6, 9)
  love.graphics.circle("fill", x - 3, y - 10, 2); love.graphics.circle("fill", x + 3, y - 10, 2)
end
function M.icon.unknown(x, y)
  love.graphics.setLineWidth(2.5)
  love.graphics.circle("line", x, y, 10)
  love.graphics.circle("fill", x, y + 6, 1.5)
  love.graphics.arc("line", "open", x, y - 3, 4, math.pi, math.pi * 2.3)
end
function M.icon.for_kind(kind)
  if kind == "ftms_bike" then return M.icon.bike end
  if kind == "sperax" or kind == "ftms_treadmill" then return M.icon.pad end
  if kind == "csc" then return M.icon.sensor end
  if kind == "hr" then return M.icon.heart end
  if kind == "rsc" then return M.icon.foot end
  return M.icon.unknown
end

return M
