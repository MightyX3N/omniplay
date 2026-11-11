-- Placeholder for the parts built in later steps.
local ui = require("ui")
local S = {}
local app, what

local TEXT = {
  play = { "Play", "The side-scroller comes next: run Green Hills at your real speed, with hills you feel on your bike." },
  bridge = { "Bridge for games", "Key profiles for any PC game and the mod API for Garry's Mod and Tiny Atlas come in a later step." },
  together = { "Play together", "Hosting with a code and the open games list come in a later step." },
}

function S.enter(a, which) app, what = a, which end

function S.draw()
  local c = ui.c
  local t = TEXT[what] or TEXT.play
  if ui.round_button("back", 82, 70, 26, ui.icon.back) then app.back() end
  ui.text(t[1], "pixel", 44, 124, 42)
  ui.rect(240, 220, 800, 260, 28, c.panel, c.line, 3)
  app.runner:draw(640, 330, 3)
  ui.text("Coming soon", "bold", 26, 280, 350, 720, "center", c.gold)
  ui.text(t[2], "regular", 18, 300, 392, 680, "center", c.muted)
  if ui.button("ok", "Back", 640 - 90, 520, 180, 52, "dark", 20) then app.back() end
end

function S.back() app.back() end

return S
