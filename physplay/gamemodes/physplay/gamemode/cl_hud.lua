-- PhysPlay HUD: power / cadence / heart rate, speed and distance, minimap, gradient,
-- elevation profile and the riders around you.
local C_BG = Color(13, 16, 21, 205)
local C_TEXT = Color(232, 236, 241)
local C_MUTED = Color(139, 149, 163)
local C_ACCENT = Color(198, 244, 50)
local C_HR = Color(255, 122, 122)
local C_UP = Color(242, 184, 75)
local C_DOWN = Color(120, 200, 140)

surface.CreateFont("PP_Big", { font = "Roboto", size = 46, weight = 700 })
surface.CreateFont("PP_Mid", { font = "Roboto", size = 26, weight = 600 })
surface.CreateFont("PP_Small", { font = "Roboto", size = 18, weight = 500 })
surface.CreateFont("PP_Tiny", { font = "Roboto", size = 15, weight = 500 })

local HIDE = { CHudHealth = true, CHudBattery = true, CHudAmmo = true, CHudSecondaryAmmo = true, CHudCrosshair = true,
  CHudDamageIndicator = true, CHudWeaponSelection = true }
function GM:HUDShouldDraw(name) return not HIDE[name] end
function GM:HUDDrawTargetID() end

local function panel(x, y, w, h) draw.RoundedBox(8, x, y, w, h, C_BG) end
local function fmt_time(s) s = math.floor(s) return string.format("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) end

-- elevation profile cache per route
local prof = {}
local function profile(r)
  if prof.id == r.id then return prof end
  prof = { id = r.id, z = {}, min = math.huge, max = -math.huge }
  for i = 0, 240 do
    local _, _, z = r:At(r.length * i / 240)
    prof.z[i] = z
    prof.min, prof.max = math.min(prof.min, z), math.max(prof.max, z)
  end
  -- minimap bounds
  prof.x0, prof.y0, prof.x1, prof.y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #r.x do
    prof.x0, prof.x1 = math.min(prof.x0, r.x[i]), math.max(prof.x1, r.x[i])
    prof.y0, prof.y1 = math.min(prof.y0, r.y[i]), math.max(prof.y1, r.y[i])
  end
  return prof
end

local MODE_LABEL = { [0] = "Bike via OmniPlay", [1] = "Running via OmniPlay", [2] = "Keyboard: W to ride, Shift harder" }

function GM:HUDPaint()
  local C = PP.cl
  local r, me = C.route, C.me
  local sw, sh = ScrW(), ScrH()
  if not r or not PP.W.Ready() then
    draw.SimpleText("Building the island...", "PP_Mid", sw / 2, sh / 2, C_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    return
  end
  if not me then return end
  local p = profile(r)
  local pad = 16

  -- power panel (top left)
  panel(pad, pad, 250, 128)
  if me.mode == PP.MODE.RUN then
    draw.SimpleText("Pace", "PP_Small", pad + 16, pad + 10, C_MUTED)
    local pace = me.v > 0.3 and (1000 / me.v) or 0
    draw.SimpleText(pace > 0 and string.format("%d:%02d", pace / 60, pace % 60) or "-", "PP_Big", pad + 16, pad + 30, C_ACCENT)
    draw.SimpleText("/km", "PP_Small", pad + 140, pad + 52, C_MUTED)
    draw.SimpleText(me.cadence .. " spm", "PP_Small", pad + 16, pad + 96, C_TEXT)
  else
    draw.SimpleText("Power", "PP_Small", pad + 16, pad + 10, C_MUTED)
    draw.SimpleText(tostring(me.watts), "PP_Big", pad + 16, pad + 30, C_ACCENT)
    surface.SetFont("PP_Big")
    local tw = surface.GetTextSize(tostring(me.watts))
    draw.SimpleText("W", "PP_Small", pad + 24 + tw, pad + 52, C_MUTED)
    draw.SimpleText(me.cadence .. " rpm", "PP_Small", pad + 16, pad + 96, C_TEXT)
  end
  draw.SimpleText(me.hr > 0 and (me.hr .. " bpm") or "- bpm", "PP_Small", pad + 130, pad + 96, C_HR)

  -- speed / distance (top centre)
  local cw = 360
  local cx = sw / 2 - cw / 2
  panel(cx, pad, cw, 84)
  draw.SimpleText(string.format("%.1f km/h", me.v * 3.6), "PP_Mid", cx + 18, pad + 10, C_TEXT)
  draw.SimpleText(r.name, "PP_Small", cx + cw - 18, pad + 14, C_MUTED, TEXT_ALIGN_RIGHT)
  local lap = r.loop and string.format("  ·  lap %d", (me.laps or 0) + 1) or ""
  draw.SimpleText(string.format("%.2f of %.1f km%s  ·  ride %s, %.1f km", (me.sd or 0) / 1000, r.length / 1000, lap,
    fmt_time(C.ride_t), C.ride_m / 1000), "PP_Tiny", cx + 18, pad + 52, C_MUTED)

  -- minimap (top right)
  local mw, mh = 220, 170
  local mx = sw - pad - mw
  panel(mx, pad, mw, mh)
  local span = math.max(p.x1 - p.x0, p.y1 - p.y0)
  local sc = (mw - 30) / span
  local ox = mx + 15 + ((mw - 30) - (p.x1 - p.x0) * sc) / 2
  local oy = pad + 15 + ((mh - 30) + (p.y1 - p.y0) * sc) / 2
  local function mp(x, y) return ox + (x - p.x0) * sc, oy - (y - p.y0) * sc end
  surface.SetDrawColor(C_ACCENT)
  local step = math.max(1, math.floor(#r.x / 200))
  local lx, ly = mp(r.x[1], r.y[1])
  for i = 1 + step, #r.x, step do
    local nx, ny = mp(r.x[i], r.y[i])
    surface.DrawLine(lx, ly, nx, ny)
    lx, ly = nx, ny
  end
  for idx, rd in pairs(C.riders) do
    if rd.sd then
      local x, y = r:At(rd.sd)
      local px, py = mp(x, y)
      local mine = idx == LocalPlayer():EntIndex()
      draw.RoundedBox(4, px - 4, py - 4, 8, 8, mine and color_white or C_HR)
    end
  end

  -- gradient
  local grade = r:Grade(me.sd or 0)
  local gcol = grade > 1.5 and C_UP or (grade < -1.5 and C_DOWN or C_TEXT)
  panel(sw - pad - 130, sh - 180, 130, 50)
  draw.SimpleText(string.format("%+.1f %%", grade), "PP_Mid", sw - pad - 65, sh - 155, gcol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

  -- elevation profile (bottom)
  local px0, pw, ph = pad, sw - pad * 2, 90
  local py0 = sh - pad - ph
  panel(px0, py0, pw, ph)
  local zr = math.max(20, p.max - p.min)
  local function ep(i) return px0 + 14 + (pw - 28) * i / 240, py0 + ph - 14 - (p.z[i] - p.min) / zr * (ph - 34) end
  local frac = (me.sd or 0) / r.length
  local px, py = ep(0)
  for i = 1, 240 do
    local nx, ny = ep(i)
    surface.SetDrawColor(i / 240 <= frac and C_ACCENT or C_MUTED)
    surface.DrawLine(px, py, nx, ny)
    surface.DrawLine(px, py + 1, nx, ny + 1)
    px, py = nx, ny
  end
  for _, mk in ipairs(r.markers) do
    if mk.type ~= "start_finish" then
      local a = px0 + 14 + (pw - 28) * mk.d / r.length
      local b = px0 + 14 + (pw - 28) * (mk.d + (mk.len or 0)) / r.length
      surface.SetDrawColor(mk.type == "climb" and Color(216, 90, 48, 120) or Color(64, 170, 90, 120))
      surface.DrawRect(a, py0 + 6, math.max(2, b - a), 8)
    end
  end
  local mxp = px0 + 14 + (pw - 28) * frac
  draw.RoundedBox(5, mxp - 5, select(2, ep(math.floor(frac * 240))) - 5, 10, 10, color_white)
  draw.SimpleText(string.format("%d m", math.floor((select(3, r:At(me.sd or 0))))), "PP_Tiny", px0 + 14, py0 + 6, C_MUTED)

  -- riders nearby (right side)
  local list = {}
  for idx, rd in pairs(C.riders) do
    if idx ~= LocalPlayer():EntIndex() and rd.sd and IsValid(rd.ply) then
      local gap = rd.sd - me.sd
      if r.loop then
        if gap > r.length / 2 then gap = gap - r.length elseif gap < -r.length / 2 then gap = gap + r.length end
      end
      list[#list + 1] = { name = rd.ply:Nick(), gap = gap, w = rd.watts }
    end
  end
  table.sort(list, function(a, b) return a.gap > b.gap end)
  local ly2 = pad + mh + 12
  for i = 1, math.min(8, #list) do
    local e = list[i]
    panel(sw - pad - mw, ly2, mw, 30)
    draw.SimpleText(e.name, "PP_Tiny", sw - pad - mw + 12, ly2 + 7, C_TEXT)
    local secs = me.v > 1 and e.gap / me.v or 0
    draw.SimpleText(string.format("%+.0f m", e.gap), "PP_Tiny", sw - pad - 12, ly2 + 7, e.gap >= 0 and C_UP or C_DOWN, TEXT_ALIGN_RIGHT)
    ly2 = ly2 + 34
  end

  -- input line
  local omni = OmniPlay.IsConnected()
  local hint = MODE_LABEL[me.mode] or ""
  if me.mode == PP.MODE.KEYS and not omni then hint = hint .. "  ·  OmniPlay not running" end
  if me.mode == PP.MODE.BIKE then
    hint = hint .. string.format("  ·  trainer difficulty %d%%", GetConVar("physplay_difficulty"):GetInt())
  end
  draw.SimpleText(hint .. "  ·  A / D change lane", "PP_Tiny", sw / 2, sh - pad - ph - 14, C_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)

  -- names over riders
  for idx, rd in pairs(C.riders) do
    if idx ~= LocalPlayer():EntIndex() and rd.sd and IsValid(rd.ply) then
      local x, y, z = r:RiderPos(rd.sd, rd.slane or rd.lane)
      local sp = PP.W.to_render(x, y, z + 2.2):ToScreen()
      if sp.visible then draw.SimpleText(rd.ply:Nick(), "PP_Tiny", sp.x, sp.y, C_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM) end
    end
  end
end
