-- Session recording: starts by itself when you move, pauses when you stop, finishes after
-- a long stop or when asked, then saves to history and exports FIT + TCX next to the exe.
local store = require("store")
local export = require("export")

local M = {
  state = "idle",          -- idle | recording | paused
  cur = nil,               -- the session being recorded
  history = {},            -- summaries, newest first
  log = function() end,
}

local START_AFTER, PAUSE_AFTER, FINISH_AFTER, MIN_KEEP = 2, 5, 120, 30
local moving_t, idle_t, sample_t, autosave_t = 0, 0, 0, 0

function M.init(log_fn)
  M.log = log_fn or M.log
  M.history = store.load("history.lua", {})
  -- finish a session that was still open when the app closed or crashed
  local open = store.load("current.lua", nil)
  if open and open.samples and #open.samples > 0 then
    M.cur = open
    M.log("info", "recovered an unfinished session from " .. os.date("%Y-%m-%d %H:%M", open.start))
    M.finish()
  end
end

local function sport_for(kind, avg_kmh)
  if kind == "ftms_bike" then return "cycling" end
  return (avg_kmh or 0) >= 7 and "running" or "walking"
end

local function begin(dev)
  M.cur = { start = os.time(), device = dev and dev.name or "?", kind = dev and dev.kind,
    samples = {}, elapsed = 0, distance = 0, kcal = 0, work_j = 0, climb = 0, game = M.game }
  M.state, idle_t, sample_t = "recording", 0, 0
  M.log("info", "recording started")
end

-- m = devices.m (live metrics), dev = the active device
function M.update(dt, m, dev)
  local moving = m and m.moving
  if M.state == "idle" then
    moving_t = moving and moving_t + dt or 0
    if moving_t >= START_AFTER then begin(dev) end
    return
  end
  local s = M.cur
  if M.user_paused then M.state = "paused"; return end
  if moving then
    idle_t = 0
    if M.state == "paused" then M.state = "recording"; M.log("info", "recording resumed") end
  else
    idle_t = idle_t + dt
    if M.state == "recording" and idle_t >= PAUSE_AFTER then M.state = "paused"; M.log("info", "recording paused (not moving)") end
    if idle_t >= FINISH_AFTER then M.finish(); return end
  end
  if M.state ~= "recording" then return end

  s.elapsed = s.elapsed + dt
  s.distance = s.distance + (m.speed_kmh or 0) / 3.6 * dt
  if m.power then s.work_j = s.work_j + m.power * dt end
  if m.grade and m.grade > 0 then s.climb = s.climb + (m.speed_kmh or 0) / 3.6 * dt * m.grade / 100 end
  -- energy: device value if it has one, else from power (1 kJ of work ~ 1 kcal burned)
  if m.kcal and m.kcal > 0 and not s.kcal_offset then s.kcal_offset = m.kcal end
  local dev_kcal = (m.kcal and s.kcal_offset) and math.max(0, m.kcal - s.kcal_offset) or 0
  s.kcal = math.max(dev_kcal, s.work_j / 1000)
  sample_t = sample_t + dt
  if sample_t >= 1 then
    sample_t = sample_t - 1
    s.samples[#s.samples + 1] = { t = os.time(), e = math.floor(s.elapsed), d = s.distance, v = m.speed_kmh or 0,
      c = m.cadence, p = m.power, hr = m.hr, g = m.grade }
  end
  autosave_t = autosave_t + dt
  if autosave_t >= 60 then autosave_t = 0; store.save("current.lua", s) end
end

local function summarize(s)
  local hr_sum, hr_n, p_sum, p_n = 0, 0, 0, 0
  for _, x in ipairs(s.samples) do
    if x.hr and x.hr > 0 then hr_sum, hr_n = hr_sum + x.hr, hr_n + 1 end
    if x.p then p_sum, p_n = p_sum + x.p, p_n + 1 end
  end
  return { id = os.date("%Y%m%d-%H%M%S", s.start), start = s.start, sport = s.sport, device = s.device, game = s.game,
    elapsed = math.floor(s.elapsed), distance = math.floor(s.distance), kcal = math.floor(s.kcal or 0),
    climb = math.floor(s.climb or 0), avg_hr = hr_n > 0 and math.floor(hr_sum / hr_n + 0.5) or nil,
    avg_power = p_n > 0 and math.floor(p_sum / p_n + 0.5) or nil,
    avg_kmh = s.elapsed > 0 and s.distance / s.elapsed * 3.6 or 0 }
end

-- Export one session's files next to the exe. Returns the FIT path (or nil).
function M.export_files(s, id)
  local dir = store.exe_dir("activities")
  local base = dir .. "/OmniPlay-" .. id .. "-" .. s.sport
  local ok1 = store.write_file(base .. ".fit", export.fit(s))
  local ok2 = store.write_file(base .. ".tcx", export.tcx(s))
  return ok1 and (base .. ".fit") or nil, ok2 and (base .. ".tcx") or nil
end

function M.finish()
  local s = M.cur
  M.state, M.cur, moving_t, idle_t, M.user_paused = "idle", nil, 0, 0, false
  store.remove("current.lua")
  if not s or s.elapsed < MIN_KEEP then
    if s then M.log("info", "session under " .. MIN_KEEP .. " s, not saved") end
    return nil
  end
  s.sport = sport_for(s.kind, s.elapsed > 0 and s.distance / s.elapsed * 3.6 or 0)
  local sum = summarize(s)
  store.save("sessions/" .. sum.id .. ".lua", s)
  local fit = M.export_files(s, sum.id)
  sum.fit = fit
  table.insert(M.history, 1, sum)
  store.save("history.lua", M.history)
  M.log("info", string.format("saved %s: %.2f km in %d:%02d%s", sum.sport, sum.distance / 1000, math.floor(sum.elapsed / 60),
    sum.elapsed % 60, fit and (", files in " .. store.exe_dir() .. "/activities") or ""))
  return sum
end

function M.toggle_pause()
  if not M.cur then return end
  M.user_paused = not M.user_paused
  if not M.user_paused then M.state = "recording"; idle_t = 0 end
  M.log("info", M.user_paused and "recording paused" or "recording resumed")
end

function M.load_session(id) return store.load("sessions/" .. id .. ".lua", nil) end

return M
