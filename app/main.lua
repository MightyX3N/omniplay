-- OmniPlay: fitness devices as game input, with workout recording.
local ffi = require("ffi")
local bleload = require("ble")
local ui = require("ui")
local store = require("store")
local devices = require("devices")
local session = require("session")
local output = require("output")
local explore = require("explore")
local api = require("api")
local C = ui.C

local ble, load_err
local tab = "Session"
local log = {}
local saved = { devices = {}, last = nil }
local nearby, scan_t, scanning = {}, 0, false
local scan_buf = ffi.new("char[8192]")
local ex = { running = false, lines = nil, raw = "", name = nil, t = 0 }
local exbuf = ffi.new("char[65536]")
local sel_profile, sel_hist, capture = 1, 1, nil
local hist_cache = {}
local build = "dev"

local log_file
local function add_log(kind, text)
  log[#log + 1] = { t = os.date("%H:%M:%S"), kind = kind, text = text }
  if log_file == nil then log_file = io.open(store.exe_dir() .. "/omniplay-log.txt", "w") or false end
  if log_file then log_file:write(os.date("%H:%M:%S"), " ", kind, " ", text, "\n"); log_file:flush() end
  if #log > 500 then table.remove(log, 1) end
end

local saved_ser
local function save_devices()
  local ser = store.serialize(saved)
  if ser ~= saved_ser then saved_ser = ser; store.save("devices.lua", saved) end
end

-- ---------- scanning ----------
local SVC_TAGS = { { 1, "FTMS" }, { 2, "footpod" }, { 4, "speed/cadence" }, { 8, "power" }, { 16, "heart rate" }, { 32, "FFF0" } }
local function refresh_nearby()
  ble.sb_scan_list(scan_buf, 8192)
  local list = {}
  for line in ffi.string(scan_buf):gmatch("[^\n]+") do
    local name, addr, rssi, age, svc = line:match("^([^\t]*)\t(%x+)\t(-?%d+)\t(%d+)\t?(%d*)")
    svc = tonumber(svc) or 0
    if name and tonumber(age) < 10000 and (name ~= "" or bit.band(svc, 31) ~= 0) then
      local tags = {}
      for _, p in ipairs(SVC_TAGS) do if bit.band(svc, p[1]) ~= 0 then tags[#tags + 1] = p[2] end end
      local fit = name:upper():find("SPERAX") ~= nil or bit.band(svc, 31) ~= 0
      list[#list + 1] = { name = name ~= "" and name or "(no name)", addr = addr, rssi = tonumber(rssi),
        tags = table.concat(tags, ", "), fitness = fit }
    end
  end
  table.sort(list, function(a, b) if a.fitness ~= b.fitness then return a.fitness end return a.rssi > b.rssi end)
  nearby = list
end

local function set_scanning(on)
  if on == scanning or not ble then return end
  scanning = on
  if on then if ble.sb_scan_start() ~= 0 then add_log("err", ffi.string(ble.sb_last_error())); scanning = false end
  else ble.sb_scan_stop() end
end

local function find_saved(addr) for i, d in ipairs(saved.devices) do if d.addr == addr then return d, i end end end

local function connect_saved(d)
  set_scanning(false)
  saved.last = d.addr
  save_devices()
  devices.connect(d)
end

local function add_device(n)
  devices.add(n, function(kind, err)
    if not kind then add_log("err", n.name .. ": " .. err); return end
    local d = find_saved(n.addr)
    if not d then
      d = { name = n.name, addr = n.addr, kind = kind, allow_hills = true, allow_speed = false, max_speed = 4,
        stop_when_steps_stop = true }
      saved.devices[#saved.devices + 1] = d
    end
    d.kind = kind
    add_log("info", "added " .. n.name .. " as " .. devices.KINDS[kind].label)
    connect_saved(d)
  end)
end

local function start_explore(n)
  set_scanning(false)
  if devices.state ~= "idle" then devices.disconnect() end
  if ble.sb_explore(n.addr, 10000) ~= 0 then add_log("err", "couldn't start the explorer"); return end
  ex = { running = true, lines = nil, raw = "", name = n.name, t = 0 }
  add_log("info", "exploring " .. n.name)
end

-- hooks for the headless smoke test
love._omniplay = {
  add_device = function(n) add_device(n) end,
  nearby = function() return nearby end,
  saved = function() return saved end,
  set_tab = function(t) tab = t end,
  log = function() return log end,
}

-- ---------- LÖVE callbacks ----------
function love.load()
  local okv, v = pcall(require, "version")
  build = okv and v or "dev"
  love.window.setTitle("OmniPlay  (build " .. build .. ")")
  ui.load()
  ble, load_err = bleload.load()
  saved = store.load("devices.lua", saved)
  saved.devices = saved.devices or {}
  output.init(add_log)
  session.init(add_log)
  add_log("info", "OmniPlay build " .. build)
  api.init(add_log, store.load("api.lua", {}))
  if not ble then return end
  devices.init(ble, add_log)
  local last = saved.last and find_saved(saved.last)
  if last then add_log("info", "connecting to " .. last.name); connect_saved(last) else set_scanning(true) end
end

function love.update(dt)
  if not ble then return end
  devices.update(dt)
  local d = devices.dev
  session.game = api.game_name() or (output.profile and output.profile.name)
  session.update(dt, devices.m, d)
  output.suppressed = api.take_input()
  output.update(dt, devices.m, d and d.kind)
  local s = session.cur
  api.update(dt, devices.m, d, devices.state, devices,
    { gait = output.gait, recording = session.state, distance_m = s and math.floor(s.distance), elapsed_s = s and math.floor(s.elapsed) })
  if ex.running then
    ex.t = ex.t + dt
    local st = ble.sb_explore_state()
    if ex.t > 0.5 or st ~= 1 then
      ex.t = 0
      ble.sb_explore_text(exbuf, 65536)
      ex.raw = ffi.string(exbuf)
      ex.lines, ex.summary = explore.report(ex.raw, ex.name)
    end
    if st == 2 or st == -1 then ex.running = false; add_log("info", "explorer done: " .. explore.summary_text(ex.summary or {})) end
  end
  local want_scan = tab == "Devices" and devices.state ~= "detecting" and not ex.running
    or (devices.state == "idle" and not ex.running)
  set_scanning(want_scan)
  if scanning then scan_t = scan_t + dt; if scan_t > 0.5 then scan_t = 0; refresh_nearby() end end
end

function love.mousepressed(_, _, b) ui.mousepressed(b) end
function love.mousereleased(_, _, b) ui.mousereleased(b) end
function love.wheelmoved(_, y) ui.wheelmoved(y) end

function love.keypressed(k)
  if capture then
    if k == "escape" or k == "return" then capture = nil
    elseif output.SCAN[k] then
      local keys = capture.keys
      local dup = false
      for _, x in ipairs(keys) do if x == k then dup = true end end
      if not dup and #keys < 3 then keys[#keys + 1] = k; output.save() end
      if #keys >= 3 then capture = nil end
    end
    return
  end
  if k == "f8" then output.toggle() end
end

function love.quit()
  api.shutdown()
  output.release_all()
  if session.cur then session.finish() end
  if devices.state ~= "idle" then devices.disconnect() end
  if ble then ble.sb_scan_stop() end
  save_devices()
end

-- ---------- screens ----------
local function fmt_time(s) s = math.floor(s or 0); return string.format("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) end

local function device_line(x, y, w)
  local d = devices.dev
  ui.rect(x, y, w, 46, C.panel)
  if not d then
    ui.text("No device connected. Add one on the Devices tab.", x + 14, y + 14, C.muted)
    return
  end
  local st = devices.state
  local col = st == "connected" and C.accent or (st == "idle" and C.muted or C.warn)
  love.graphics.setColor(col); love.graphics.circle("fill", x + 18, y + 23, 5)
  ui.text(d.name .. "  ·  " .. devices.KINDS[d.kind].label, x + 32, y + 6, C.text)
  local sub = st == "connected" and (devices.hint or "connected") or (devices.hint or st)
  ui.text(sub, x + 32, y + 25, devices.hint and C.warn or C.muted, "small")
  if st == "idle" then
    if ui.button("Connect", x + w - 110, y + 6, 98, 34, "secondary") then connect_saved(d) end
  else
    if ui.button("Disconnect", x + w - 110, y + 6, 98, 34, "secondary") then devices.disconnect() end
  end
end

local function draw_session(x, y, w, h)
  local m, kind = devices.m, devices.dev and devices.dev.kind
  -- recording line
  local rec = session.state
  local col = rec == "recording" and C.bad or (rec == "paused" and C.warn or C.muted)
  love.graphics.setColor(col); love.graphics.circle("fill", x + 6, y + 12, 6)
  ui.text(rec == "recording" and "Recording" or (rec == "paused" and "Paused" or "Not recording (starts when you move)"),
    x + 20, y + 3, C.text, "mid")
  if session.cur then ui.text(fmt_time(session.cur.elapsed), x + w - 140, y + 1, C.text, "mid", 140, "right") end
  y = y + 40
  -- metrics
  local cw = (w - 36) / 4
  local walking = kind == "sperax" or kind == "ftms_treadmill" or kind == "rsc"
  ui.metric("Speed", string.format("%.1f", m.speed_kmh or 0), "km/h", x, y, cw)
  if walking then
    ui.metric("Steps", m.steps and tostring(m.steps) or "-", nil, x + cw + 12, y, cw)
    ui.metric("Cadence", string.format("%.0f", m.cadence or 0), "spm", x + 2 * (cw + 12), y, cw)
  else
    ui.metric("Power", m.power and tostring(m.power) or "-", "W", x + cw + 12, y, cw)
    ui.metric("Cadence", string.format("%.0f", m.cadence or 0), "rpm", x + 2 * (cw + 12), y, cw)
  end
  ui.metric("Heart rate", (m.hr and m.hr > 0) and tostring(m.hr) or "-", "bpm", x + 3 * (cw + 12), y, cw, C.hr)
  y = y + 92
  local s = session.cur
  ui.text(string.format("Distance  %.2f km        Energy  %d kcal        Hill  %s", s and s.distance / 1000 or 0,
    s and math.floor(s.kcal or 0) or 0, m.grade and string.format("%+.1f%%", m.grade) or "-"), x + 4, y, C.soft)
  y = y + 30
  device_line(x, y, w)
  y = y + 58
  -- game output
  ui.rect(x, y, w, 64, C.panel)
  local p = output.profile
  ui.text("Game output: " .. (output.enabled and "ON" or "OFF") .. "   (F8 toggles, even inside a game)", x + 14, y + 8,
    output.enabled and C.accent or C.text)
  local held = output.held_keys()
  local keys = {}
  for _, k in ipairs(held) do keys[#keys + 1] = output.key_label(k) end
  ui.text(string.format("Profile: %s    Movement: %s    Holding: %s", p and p.name or "-", output.gait,
    #keys > 0 and table.concat(keys, " + ") or "nothing"), x + 14, y + 34, C.muted, "small")
  if ui.button(output.enabled and "Turn off" or "Turn on", x + w - 110, y + 14, 98, 34,
    output.enabled and "secondary" or "primary") then output.toggle() end
  y = y + 78
  -- connected games (mod API)
  ui.rect(x, y, w, 40, C.panel)
  local g = api.active()
  local gl
  if g and g.name then
    gl = "Connected game: " .. g.name
    if api.grade_target then gl = gl .. string.format("    Hill: %+.1f%%", api.grade_target)
      if devices.dev and devices.dev.kind == "ftms_bike" and devices.dev.allow_hills == false then gl = gl .. " (hills are off for this bike)" end
    end
    if api.take_input() then gl = gl .. "    Reads your movement directly, keys paused" end
  else
    gl = "No game connected through the mod API" .. (api.gmod_dir and "  ·  Garry's Mod bridge ready" or "")
  end
  ui.text(gl, x + 14, y + 12, g and g.name and C.accent or C.muted, "small", w - 28)
  y = y + 52
  -- recording buttons
  if session.cur then
    if ui.button(session.user_paused and "Resume" or "Pause", x, y, (w - 12) / 2, 40, "secondary") then session.toggle_pause() end
    if ui.button("Finish and save", x + (w - 12) / 2 + 12, y, (w - 12) / 2, 40, "primary") then session.finish(); hist_cache = {} end
  end
end

local function draw_devices(x, y, w, h)
  ui.text("Your devices", x, y, C.muted, "small")
  y = y + 20
  if #saved.devices == 0 then ui.text("None yet. Add one from the list below.", x, y + 4, C.soft); y = y + 34 end
  local remove
  for i, d in ipairs(saved.devices) do
    local active = devices.dev == d
    local bh = (d.kind == "ftms_bike" or d.kind == "sperax" or d.kind == "ftms_treadmill") and 132 or 90
    ui.rect(x, y, w, bh, C.panel)
    ui.text(d.name, x + 14, y + 10, C.text, "mid")
    ui.text(devices.KINDS[d.kind].label .. "  ·  " .. d.addr .. (active and ("  ·  " .. devices.state) or ""),
      x + 14, y + 34, C.muted, "small")
    if active and devices.state ~= "idle" then
      if ui.button("Disconnect", x + w - 220, y + 10, 100, 32, "secondary") then devices.disconnect() end
    else
      if ui.button("Connect", x + w - 220, y + 10, 100, 32, "primary") then connect_saved(d) end
    end
    if ui.button("Remove", x + w - 110, y + 10, 96, 32, "danger") then remove = i end
    local ty = y + 56
    if d.kind == "ftms_bike" then
      d.allow_hills = ui.toggle("Games may set hills (resistance follows the gradient)", d.allow_hills ~= false, x + 10, ty, w - 20)
    elseif d.kind == "sperax" or d.kind == "ftms_treadmill" then
      d.allow_speed = ui.toggle("Games may change belt speed (off by default)", d.allow_speed == true, x + 10, ty, (w - 30) / 2)
      d.max_speed = ui.stepper("Max speed games may set", d.max_speed or 4, 0.5, 1, 12, "%.1f km/h", x + 20 + (w - 30) / 2, ty, (w - 30) / 2)
      if d.kind == "sperax" then
        d.stop_when_steps_stop = ui.toggle("Stop moving in game when your steps stop", d.stop_when_steps_stop ~= false, x + 10, ty + 40, w - 20)
      end
    end
    if bh == 90 then ui.text("Auto-reconnects after dropouts.", x + 14, ty + 4, C.muted, "small") end
    y = y + bh + 10
  end
  if remove then
    if devices.dev == saved.devices[remove] then devices.disconnect(); devices.dev = nil end
    table.remove(saved.devices, remove); save_devices()
  end
  save_devices()
  y = y + 8
  ui.text(ex.lines and not ex.running and "Explorer report" or "Nearby (fitness devices first)", x, y, C.muted, "small")
  if ex.lines then
    if ui.button("Copy report", x + w - 230, y - 6, 110, 28, "secondary") then
      love.system.setClipboardText(table.concat(ex.lines, "\n") .. "\n\n--- raw ---\n" .. ex.raw)
      add_log("info", "report copied")
    end
    if ui.button("Close", x + w - 110, y - 6, 100, 28, "secondary") then ex.lines = nil end
  end
  y = y + 24
  if ex.lines then
    ui.rect(x, y, w, h - (y - 70), C.panel)
    if ex.summary and not ex.running then ui.text(explore.summary_text(ex.summary), x + 12, y + 8, C.accent) end
    local lh, maxl = 16, math.floor((h - (y - 70) - 40) / 16)
    local from = math.max(1, #ex.lines - maxl + 1)
    for i = from, #ex.lines do ui.text(ex.lines[i], x + 12, y + 30 + (i - from) * lh, C.soft, "mono") end
    return
  end
  for i, n in ipairs(nearby) do
    if y > h + 40 then break end
    local known = find_saved(n.addr)
    ui.rect(x, y, w, 40, C.panel)
    ui.text(n.name, x + 14, y + 11, n.fitness and C.text or C.muted)
    ui.text(string.format("%s   %d dBm", n.tags ~= "" and n.tags or "no fitness services", n.rssi), x + 260, y + 13, C.muted, "small")
    if not known and n.fitness and devices.state ~= "detecting" then
      if ui.button("Add", x + w - 200, y + 4, 90, 32, "primary") then add_device(n) end
    end
    if ui.button("Explore", x + w - 100, y + 4, 90, 32, "secondary") then start_explore(n) end
    y = y + 46
  end
  if #nearby == 0 then ui.text(scanning and "Scanning... turn the device on (pedal to wake a bike)." or "", x, y + 4, C.soft) end
end

local function draw_profiles(x, y, w, h)
  local profs = output.profiles
  sel_profile = math.min(sel_profile, #profs)
  local lw = 220
  for i, p in ipairs(profs) do
    local on = i == sel_profile
    ui.rect(x, y + (i - 1) * 42, lw, 36, on and C.acc_bg or C.panel)
    if ui.inside(x, y + (i - 1) * 42, lw, 36) and ui.button("", x, y + (i - 1) * 42, lw, 36, "ghost") then sel_profile = i end
    ui.text(p.name, x + 12, y + (i - 1) * 42 + 9, on and C.accent or C.text)
  end
  if ui.button("+ New profile", x, y + #profs * 42 + 4, lw, 34, "secondary") then
    local np = output.default_profile()
    np.name, np.exe = "New profile", output.foreground ~= "omniplay" and output.foreground or ""
    profs[#profs + 1] = np; sel_profile = #profs; output.save()
  end
  local p = profs[sel_profile]
  local ex_ = x + lw + 20
  local ew = w - lw - 20
  ui.text(p.name, ex_, y, C.text, "mid")
  ui.text(p.exe ~= "" and ("Used when " .. p.exe .. " is in front") or "Used when no other profile matches",
    ex_, y + 26, C.muted, "small")
  if sel_profile > 1 then
    local fg = output.foreground
    if fg ~= "" and fg ~= "omniplay" and ui.button("Use for " .. fg, ex_ + ew - 330, y, 220, 30, "secondary") then
      p.exe, p.name = fg, fg:gsub("%.exe$", ""); output.save()
    end
    if ui.button("Delete", ex_ + ew - 100, y, 100, 30, "danger") then table.remove(profs, sel_profile); sel_profile = 1; output.save(); return end
  end
  local yy = y + 56
  local function state_row(label, st, key_hint)
    ui.rect(ex_, yy, ew, 92, C.panel)
    ui.text(label, ex_ + 14, yy + 10, C.text, "mid")
    -- keys
    local kx = ex_ + 120
    for i, k in ipairs(st.keys) do
      local lbl = output.key_label(k)
      local kw = ui.width(lbl) + 22
      if ui.button(lbl .. " x", kx, yy + 6, kw + 14, 30, "secondary") then table.remove(st.keys, i); output.save(); break end
      kx = kx + kw + 22
    end
    local cap = capture and capture.keys == st.keys
    if ui.button(cap and "press a key... (Enter = done)" or "+ key", kx, yy + 6, cap and 230 or 70, 30, cap and "primary" or "secondary") then
      capture = cap and nil or { keys = st.keys }
    end
    local half = (ew - 40) / 2
    st.pad_kmh = ui.stepper("Pad / treadmill from", st.pad_kmh or 1, 0.5, 0.5, 20, "%.1f km/h", ex_ + 10, yy + 48, half)
    if key_hint == "watts" then
      st.watts = ui.stepper("Bike from", st.watts or 200, 10, 50, 1000, "%d W", ex_ + 30 + half, yy + 48, half)
    else
      st.rpm = ui.stepper("Bike from", st.rpm or 30, 5, 10, 150, "%d rpm", ex_ + 30 + half, yy + 48, half)
    end
    yy = yy + 104
  end
  state_row("Walk", p.walk)
  state_row("Run", p.run)
  state_row("Sprint", p.sprint, "watts")
  p.hold_s = ui.stepper("Keep moving through dropouts", p.hold_s or 2, 0.5, 0, 6, "%.1f s", ex_, yy, ew)
  if ui.button("Save profile", ex_, yy + 46, ew, 38, "primary") then output.save(); add_log("info", "profile saved") end
end

local function draw_history(x, y, w, h)
  local list = session.history
  if #list == 0 then ui.text("No sessions yet. Recording starts by itself when you move.", x, y, C.soft); return end
  sel_hist = math.min(sel_hist, #list)
  local lw = 330
  for i, s in ipairs(list) do
    local yy = y + (i - 1) * 48
    if yy > h + 20 then break end
    local on = i == sel_hist
    ui.rect(x, yy, lw, 42, on and C.acc_bg or C.panel)
    if ui.button("", x, yy, lw, 42, "ghost") then sel_hist = i end
    local what = (s.sport == "cycling" and "Ride" or (s.sport == "running" and "Run" or "Walk"))
    ui.text(what .. "  ·  " .. (s.game or s.device or ""), x + 12, yy + 5, on and C.accent or C.text)
    ui.text(os.date("%a %d %b %H:%M", s.start) .. string.format("  ·  %.1f km  ·  %d min", s.distance / 1000, s.elapsed / 60),
      x + 12, yy + 23, C.muted, "small")
  end
  local s = list[sel_hist]
  local dx, dw = x + lw + 20, w - lw - 20
  ui.text((s.sport == "cycling" and "Ride" or (s.sport == "running" and "Run" or "Walk")) .. "  ·  " .. (s.device or ""), dx, y, C.text, "mid")
  ui.text(os.date("%A %d %B %Y, %H:%M", s.start), dx, y + 26, C.muted, "small")
  local rows = {
    { "Time", fmt_time(s.elapsed) }, { "Distance", string.format("%.2f km", s.distance / 1000) },
    { "Avg speed", string.format("%.1f km/h", s.avg_kmh or 0) }, { "Energy", (s.kcal or 0) .. " kcal" },
    { "Avg power", s.avg_power and (s.avg_power .. " W") or "-" }, { "Avg heart rate", s.avg_hr and (s.avg_hr .. " bpm") or "-" },
    { "Climbed", (s.climb or 0) .. " m" }, { "Game", s.game or "-" },
  }
  for i, r in ipairs(rows) do
    local cx = dx + ((i - 1) % 2) * (dw / 2)
    local cy = y + 56 + math.floor((i - 1) / 2) * 26
    ui.text(r[1], cx, cy, C.muted)
    ui.text(r[2], cx + 120, cy, C.text)
  end
  -- chart: speed (and power if present) over time
  local full = hist_cache[s.id]
  if full == nil then full = session.load_session(s.id) or false; hist_cache[s.id] = full end
  local cy = y + 172
  ui.rect(dx, cy, dw, 140, C.panel)
  if full and full.samples and #full.samples > 1 then
    local n, vmax = #full.samples, 1
    local key = (s.avg_power and "p") or "v"
    for _, smp in ipairs(full.samples) do vmax = math.max(vmax, smp[key] or 0) end
    local pts = {}
    local stride = math.max(1, math.floor(n / dw))
    for i = 1, n, stride do
      local smp = full.samples[i]
      pts[#pts + 1] = dx + 10 + (i - 1) / (n - 1) * (dw - 20)
      pts[#pts + 1] = cy + 130 - (smp[key] or 0) / vmax * 110
    end
    love.graphics.setColor(C.accent); love.graphics.setLineWidth(1.5)
    if #pts >= 4 then love.graphics.line(pts) end
    ui.text(key == "p" and "Power" or "Speed", dx + 10, cy + 6, C.muted, "small")
  end
  local by = cy + 154
  local dir = store.exe_dir("activities")
  if ui.button("Open activities folder", dx, by, 220, 38, "primary") then
    love.system.openURL("file:///" .. dir:gsub("\\", "/"))
  end
  if full and ui.button("Export again (FIT + TCX)", dx + 232, by, 220, 38, "secondary") then
    local f = session.export_files(full, s.id)
    add_log("info", f and ("exported " .. f) or "export failed")
  end
  ui.text("Upload the .fit file to Strava, Garmin Connect, TrainingPeaks or intervals.icu. Saved as an indoor activity.",
    dx, by + 50, C.muted, "small", dw)
end

function love.draw()
  ui.begin_frame()
  local W, H = love.graphics.getDimensions()
  love.graphics.clear(C.bg)
  -- top bar
  ui.text("●", 18, 14, C.accent, "mid")
  ui.text("OmniPlay", 38, 15, C.text, "mid")
  tab = ui.tabs({ "Session", "Devices", "Profiles", "History" }, tab, 150, 12)
  love.graphics.setColor(C.line); love.graphics.rectangle("fill", 0, 50, W, 1)
  if not ble then
    ui.text(load_err or "Bluetooth helper not loaded", 20, 70, C.bad, "ui", W - 40)
    ui.end_frame()
    return
  end
  local x, y, w, h = 20, 66, W - 40, H - 66 - 34
  if tab == "Session" then draw_session(x, y, w, h)
  elseif tab == "Devices" then draw_devices(x, y, w, h)
  elseif tab == "Profiles" then draw_profiles(x, y, w, h)
  else draw_history(x, y, w, h) end
  -- status line: last log message, click to copy the log
  love.graphics.setColor(C.line); love.graphics.rectangle("fill", 0, H - 30, W, 1)
  local last = log[#log]
  if last then ui.text(last.t .. "  " .. last.text, 16, H - 23, last.kind == "err" and C.warn or C.muted, "small", W - 180) end
  if ui.button("Copy log", W - 110, H - 28, 96, 26, "ghost") then
    local t = { "OmniPlay build " .. build }
    for _, e in ipairs(log) do t[#t + 1] = e.t .. " " .. e.kind .. " " .. e.text end
    love.system.setClipboardText(table.concat(t, "\n"))
    add_log("info", "log copied to clipboard")
  end
  ui.end_frame()
end
