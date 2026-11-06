-- Minimal immediate-mode UI in OmniPlay's dark + lime style.
local M = {}

M.C = {
  bg = { 0.051, 0.063, 0.082 }, panel = { 0.082, 0.102, 0.129 }, line = { 0.114, 0.137, 0.173 },
  line2 = { 0.165, 0.2, 0.251 }, text = { 0.91, 0.925, 0.945 }, soft = { 0.655, 0.69, 0.737 },
  muted = { 0.545, 0.584, 0.639 }, accent = { 0.776, 0.957, 0.196 }, on_accent = { 0.063, 0.078, 0.039 },
  warn = { 0.949, 0.722, 0.294 }, bad = { 1, 0.42, 0.42 }, hr = { 1, 0.478, 0.478 }, acc_bg = { 0.12, 0.165, 0.063 },
}
local C = M.C
local fonts = {}
local mx, my, pressed, released, wheel = 0, 0, false, false, 0

function M.load()
  fonts.small = love.graphics.newFont(12)
  fonts.ui = love.graphics.newFont(14)
  fonts.mid = love.graphics.newFont(17)
  fonts.big = love.graphics.newFont(30)
  fonts.mono = love.graphics.newFont(12)
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

local function inside(x, y, w, h) return mx >= x and mx < x + w and my >= y and my < y + h end
M.inside = inside

function M.rect(x, y, w, h, col, r, mode)
  love.graphics.setColor(col)
  love.graphics.rectangle(mode or "fill", x, y, w, h, r or 8, r or 8)
end

function M.text(s, x, y, col, font, w, align)
  love.graphics.setFont(fonts[font or "ui"])
  love.graphics.setColor(col or C.text)
  if w then love.graphics.printf(s, x, y, w, align or "left") else love.graphics.print(s, x, y) end
end

function M.width(s, font) return fonts[font or "ui"]:getWidth(s) end

-- style: "primary" | "secondary" | "danger" | "ghost"; returns true when clicked
function M.button(label, x, y, w, h, style, disabled)
  w = w or (M.width(label) + 28)
  h = h or 34
  local hot = inside(x, y, w, h) and not disabled
  if style == "primary" then M.rect(x, y, w, h, disabled and C.line2 or C.accent)
  elseif style == "danger" then M.rect(x, y, w, h, hot and { 0.35, 0.12, 0.12 } or { 0.25, 0.09, 0.09 })
  elseif style ~= "ghost" then
    M.rect(x, y, w, h, hot and C.line or C.panel)
    M.rect(x + 0.5, y + 0.5, w - 1, h - 1, C.line2, 8, "line")
  end
  local col = style == "primary" and C.on_accent or (style == "danger" and C.bad or (disabled and C.muted or C.text))
  if style == "ghost" then col = hot and C.accent or C.soft end
  M.text(label, x, y + (h - fonts.ui:getHeight()) / 2, col, "ui", w, "center")
  if hot then love.mouse.setCursor(love.mouse.getSystemCursor("hand")) end
  return hot and released
end

-- small rounded tag
function M.pill(label, x, y, on, col)
  local w = M.width(label, "small") + 16
  M.rect(x, y, w, 22, on and C.acc_bg or C.panel, 11)
  if not on then M.rect(x + 0.5, y + 0.5, w - 1, 21, C.line2, 11, "line") end
  M.text(label, x, y + 4, col or (on and C.accent or C.muted), "small", w, "center")
  return w
end

-- clickable toggle with label; returns new value
function M.toggle(label, value, x, y, w)
  local h = 34
  local hot = inside(x, y, w, h)
  M.rect(x, y, w, h, hot and C.line or C.panel)
  M.text(label, x + 12, y + 9, C.text)
  local tx = x + w - 46
  M.rect(tx, y + 8, 34, 18, value and C.accent or C.line2, 9)
  love.graphics.setColor(value and C.on_accent or C.muted)
  love.graphics.circle("fill", value and tx + 25 or tx + 9, y + 17, 7)
  if hot and released then return not value end
  return value
end

-- value with - and + buttons; returns new value
function M.stepper(label, value, step, lo, hi, fmt, x, y, w)
  M.rect(x, y, w, 34, C.panel)
  M.text(label, x + 12, y + 9, C.text)
  local bx = x + w - 150
  if M.button("-", bx, y + 3, 28, 28, "secondary") then value = math.max(lo, value - step) end
  M.text(string.format(fmt, value), bx + 30, y + 9, C.text, "ui", 90, "center")
  if M.button("+", bx + 120, y + 3, 28, 28, "secondary") then value = math.min(hi, value + step) end
  return math.floor(value / step + 0.5) * step
end

function M.metric(label, value, unit, x, y, w, col)
  M.rect(x, y, w, 78, C.panel)
  M.text(label, x + 14, y + 10, C.muted, "small")
  M.text(value, x + 14, y + 28, col or C.text, "big")
  if unit then M.text(unit, x + 18 + M.width(value, "big"), y + 44, C.muted, "small") end
end

function M.tabs(items, current, x, y)
  for _, it in ipairs(items) do
    local w = M.width(it) + 24
    local on = it == current
    if inside(x, y, w, 30) and released then current = it end
    M.text(it, x, y + 6, on and C.text or C.muted, "ui", w, "center")
    if on then M.rect(x + 8, y + 28, w - 16, 2, C.accent, 1) end
    x = x + w
  end
  return current
end

return M
