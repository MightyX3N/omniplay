-- Immediate-mode UI in OmniPlay's arcade style: navy cards, bright tiles, chunky rounded type (Inter).
local M = {}

local function hex(s, a)
  return { tonumber(s:sub(1, 2), 16) / 255, tonumber(s:sub(3, 4), 16) / 255, tonumber(s:sub(5, 6), 16) / 255, a or 1 }
end
M.hex = hex
M.C = {
  bg = hex("1d1f3b"), card = hex("2b2e55"), inner = hex("1d1f3b"), line = hex("34386a"), btn = hex("3b3f73"),
  btn_hot = hex("4a4e8a"), text = hex("ffffff"), muted = hex("a9acd6"), dim = hex("6d70a0"), soft = hex("c5c7ea"),
  green = hex("5ee1a1"), blue = hex("6ec3ff"), yellow = hex("ffcf3f"), pink = hex("ff8fa3"), red = hex("ff5d73"),
  orange = hex("ff9f43"), on_green = hex("0e2a1d"), on_yellow = hex("2a2400"), on_blue = hex("0c2340"),
  on_pink = hex("3a0c16"), tile_text = hex("141428"), ok_bg = hex("1f4a3a"), warn_bg = hex("4a4220"), bad_bg = hex("4a2030"),
}
local C = M.C

-- fonts: name -> { file, size }
local FONT = {
  h = { "Inter-Black", 22 }, num = { "Inter-Black", 22 }, tile = { "InterDisplay-Black", 56 }, big = { "Inter-Black", 30 },
  b = { "Inter-ExtraBold", 15 }, m = { "Inter-Bold", 14 }, s = { "Inter-Bold", 12.5 }, xs = { "Inter-SemiBold", 11.5 },
  tab = { "Inter-Bold", 15 }, logo = { "Inter-Black", 22 }, unit = { "Inter-ExtraBold", 15 }, mono = { "Inter-SemiBold", 12 },
}
local fonts = {}
local mx, my, pressed, released, wheel = 0, 0, false, false, 0
local oy = 0 -- scroll offset of the current region (content drawn shifted up by oy)

function M.load()
  for name, f in pairs(FONT) do
    local ok, fnt = pcall(love.graphics.newFont, "fonts/" .. f[1] .. ".otf", f[2])
    fonts[name] = ok and fnt or love.graphics.newFont(math.floor(f[2]))
  end
end
M.fonts = fonts

function M.begin_frame()
  mx, my = love.mouse.getPosition()
  love.mouse.setCursor()
end
function M.end_frame() pressed, released, wheel = false, false, 0 end
function M.mousepressed(b) if b == 1 then pressed = true end end
function M.mousereleased(b) if b == 1 then released = true end end
function M.wheelmoved(y) wheel = y end
function M.wheel() return wheel end
function M.mouse() return mx, my + oy end
function M.clicked() return released end

local function inside(x, y, w, h)
  local py = my + oy
  return mx >= x and mx < x + w and py >= y and py < y + h
end
M.inside = inside

-- scrolling region: draw content in content coordinates between begin_scroll / end_scroll
local scroll = {}
function M.begin_scroll(key, x, y, w, h, content_h)
  local s = scroll[key] or { y = 0 }
  scroll[key] = s
  if mx >= x and mx < x + w and my >= y and my < y + h and wheel ~= 0 then s.y = s.y - wheel * 60 end
  s.y = math.max(0, math.min(s.y, math.max(0, (s.content or 0) - h)))
  love.graphics.setScissor(x, y, w, h)
  love.graphics.push()
  love.graphics.translate(0, -s.y)
  oy = s.y
  s.top, s.bottom = y, y + h
  return s
end
function M.end_scroll(key, content_bottom)
  local s = scroll[key]
  love.graphics.pop()
  love.graphics.setScissor()
  oy = 0
  if s then s.content = content_bottom - s.top end
end

function M.rect(x, y, w, h, col, r, mode)
  love.graphics.setColor(col)
  r = r or 18
  love.graphics.rectangle(mode or "fill", x, y, w, h, r, r)
end

function M.text(s, x, y, col, font, w, align)
  love.graphics.setFont(fonts[font or "m"])
  love.graphics.setColor(col or C.text)
  if w then love.graphics.printf(tostring(s), math.floor(x), math.floor(y), w, align or "left")
  else love.graphics.print(tostring(s), math.floor(x), math.floor(y)) end
end
function M.width(s, font) return fonts[font or "m"]:getWidth(tostring(s)) end
function M.height(font) return fonts[font or "m"]:getHeight() end
function M.dot(x, y, r, col) love.graphics.setColor(col); love.graphics.circle("fill", x, y, r) end

local STYLE = {
  yellow = { "yellow", "on_yellow" }, green = { "green", "on_green" }, blue = { "blue", "on_blue" },
  pink = { "pink", "on_pink" }, dark = { "btn", "text" }, danger = { "bad_bg", "red" }, ghost = { nil, "muted" },
}
-- style: yellow | green | blue | pink | dark | danger | ghost; returns true when clicked
function M.button(label, x, y, w, h, style, font)
  font = font or "b"
  w = w or (M.width(label, font) + 28)
  h = h or 38
  local st = STYLE[style or "dark"]
  local hot = inside(x, y, w, h)
  if st[1] then
    local bg = C[st[1]]
    if hot then bg = { math.min(1, bg[1] * 1.12 + 0.03), math.min(1, bg[2] * 1.12 + 0.03), math.min(1, bg[3] * 1.12 + 0.03), 1 } end
    M.rect(x, y, w, h, bg, math.min(14, h / 2))
  end
  local col = C[st[2]]
  if style == "ghost" and hot then col = C.text end
  M.text(label, x, y + (h - M.height(font)) / 2, col, font, w, "center")
  if hot then love.mouse.setCursor(love.mouse.getSystemCursor("hand")) end
  return hot and released
end

-- invisible click area
function M.hit(x, y, w, h)
  local hot = inside(x, y, w, h)
  if hot then love.mouse.setCursor(love.mouse.getSystemCursor("hand")) end
  return hot and released, hot
end

-- rounded tag; returns its width
function M.pill(label, x, y, fg, bg, font)
  font = font or "s"
  local w = M.width(label, font) + 22
  M.rect(x, y, w, 26, bg or C.btn, 13)
  M.text(label, x, y + (26 - M.height(font)) / 2, fg or C.soft, font, w, "center")
  return w
end
function M.chip(label, x, y) return M.pill(label, x, y, C.muted, C.inner, "xs") end

-- on/off switch; returns the new value
function M.switch(x, y, on)
  M.rect(x, y, 40, 24, on and C.green or C.btn, 12)
  M.dot(on and x + 28 or x + 12, y + 12, 8, on and C.on_green or hex("8d90c2"))
  local click = M.hit(x - 4, y - 4, 48, 32)
  if click then return not on end
  return on
end

-- label + sub text + switch on the right; returns new value and the row height
function M.toggle(label, sub, value, x, y, w)
  M.text(label, x, y, C.text, "b")
  if sub then M.text(sub, x, y + 20, C.muted, "xs", w - 60) end
  local nv = M.switch(x + w - 40, y + 4, value)
  return nv, sub and 44 or 30
end

-- choose one of a few short options; returns the chosen one
function M.seg(items, current, x, y, font)
  font = font or "s"
  local w = 8
  for _, it in ipairs(items) do w = w + M.width(it[2] or it, font) + 24 end
  M.rect(x, y, w, 32, C.inner, 16)
  local cx = x + 4
  for _, it in ipairs(items) do
    local key, label = it[1] or it, it[2] or it
    local iw = M.width(label, font) + 24
    local on = key == current
    if on then M.rect(cx, y + 4, iw, 24, C.yellow, 12) end
    M.text(label, cx, y + 4 + (24 - M.height(font)) / 2, on and C.on_yellow or C.soft, font, iw, "center")
    if M.hit(cx, y, iw, 32) then current = key end
    cx = cx + iw
  end
  return current, w
end

-- value with - and + buttons; returns the new value
function M.stepper(label, value, step, lo, hi, fmt, x, y, w)
  M.rect(x, y, w, 40, C.inner, 14)
  M.text(label, x + 14, y + 12, C.soft, "s")
  local bx = x + w - 156
  if M.button("-", bx, y + 5, 30, 30, "dark") then value = math.max(lo, value - step) end
  M.text(string.format(fmt, value), bx + 32, y + 12, C.text, "b", 92, "center")
  if M.button("+", bx + 122, y + 5, 30, 30, "dark") then value = math.min(hi, value + step) end
  return math.floor(value / step + 0.5) * step
end

-- card with an optional header line; returns the y where content starts
function M.card(x, y, w, h, title, right, right_col)
  M.rect(x, y, w, h, C.card, 22)
  if title then
    M.text(title, x + 18, y + 14, C.muted, "b")
    if right then
      if type(right) == "table" then
        M.pill(right[1], x + w - 18 - M.width(right[1], "s") - 22, y + 10, right[2], right[3])
      else M.text(right, x + 18, y + 15, right_col or C.muted, "s", w - 36, "right") end
    end
    return y + 44
  end
  return y + 16
end

-- big coloured value tile
function M.tile(label, value, unit, src, x, y, w, h, bg)
  M.rect(x, y, w, h, bg, 24)
  local tc = C.tile_text
  M.text(label, x + 20, y + 16, { tc[1], tc[2], tc[3], 0.8 }, "b")
  local vf = h < 120 and "big" or "tile"
  M.text(value, x + 18, y + (h < 120 and 34 or 38), tc, vf)
  if unit then M.text(unit, x + 24 + M.width(value, vf), y + (h < 120 and 46 or 66), { tc[1], tc[2], tc[3], 0.72 }, "unit") end
  if src then
    local sw = M.width(src, "s") + 22
    M.rect(x + 18, y + h - 42, sw, 28, { 0, 0, 0, 0.12 }, 14)
    M.text(src, x + 18, y + h - 42 + (28 - M.height("s")) / 2, tc, "s", sw, "center")
  end
end

-- small dark value box: label, big value + unit, coloured note
function M.valbox(label, value, unit, note, note_col, x, y, w, h)
  h = h or 78
  M.rect(x, y, w, h, C.inner, 14)
  M.text(label, x + 12, y + 9, C.muted, "xs")
  M.text(value, x + 12, y + 25, C.text, "num")
  if unit and unit ~= "" then M.text(unit, x + 16 + M.width(value, "num"), y + 33, C.muted, "xs") end
  if note then M.text(note, x + 12, y + h - 22, note_col or C.muted, "xs", w - 20) end
end

-- pill tabs along the top bar; returns the selected tab
function M.tabs(items, current, x, y)
  for _, it in ipairs(items) do
    local w = M.width(it, "tab") + 32
    local on = it == current
    if on then M.rect(x, y, w, 36, C.yellow, 18) end
    local click, hot = M.hit(x, y, w, 36)
    M.text(it, x, y + (36 - M.height("tab")) / 2, on and C.on_yellow or (hot and C.text or C.muted), "tab", w, "center")
    if click then current = it end
    x = x + w + 4
  end
  return current
end

-- a sparkline of numbers inside a box
function M.spark(vals, x, y, w, h, col, vmax)
  if #vals < 2 then return end
  vmax = vmax or 1
  for _, v in ipairs(vals) do vmax = math.max(vmax, v) end
  local pts = {}
  for i, v in ipairs(vals) do
    pts[#pts + 1] = x + (i - 1) / (#vals - 1) * w
    pts[#pts + 1] = y + h - v / vmax * h
  end
  love.graphics.setColor(col)
  love.graphics.setLineWidth(2.5)
  love.graphics.setLineJoin("bevel")
  love.graphics.line(pts)
  love.graphics.setLineWidth(1)
end

return M
