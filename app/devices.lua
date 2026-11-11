-- Connects devices and feeds their bytes to the OmniPlay SDK. Works on top of a Bluetooth
-- backend (bt/win.lua or bt/fake.lua), which only scans, opens, reads and writes.
--   new device: explore it -> SDK decides what it is -> open its service -> subscribe -> SDK
--   known device (remembered): open straight away with the kind we saved
-- Every connection reconnects on its own when it drops.
local M = { conns = {}, order = {}, scanning = false }

local RETRY_S = 3          -- wait before reconnecting
local WATCHDOG_S = 8       -- no data this long from a bike / pad / strap = dropped (sensors go quiet when idle)
local WATCHED = { ftms_bike = true, ftms_treadmill = true, sperax = true, hr = true }

local bt, op, sdk, settings
local now = function() return love.timer.getTime() end
local explore_queue, exploring = {}, nil

function M.init(backend, session, sdk_module, settings_module)
  bt, op, sdk, settings = backend, session, sdk_module, settings_module
end
function M.backend() return bt end

-- the SDK writes through here
function M.send(id, _, bytes)
  local c = M.conns[id]
  if c and c.h and c.state == "connected" then
    if not bt.write(c.h, bytes) then c.hint = "A command didn't go through" end
  end
end

function M.scan(on)
  if not bt then return end
  if on and not M.scanning then M.scanning = bt.scan_start() ~= false
  elseif not on and M.scanning then bt.scan_stop(); M.scanning = false end
end

-- devices seen nearby that look like fitness gear (or everything with all = true)
function M.nearby(all)
  if not bt then return {} end
  local t = {}
  for _, d in ipairs(bt.scan_list()) do
    local fitness = (d.flags or 0) ~= 0 or d.name:upper():find("SPERAX")
    if (fitness or all) and d.name ~= "" then t[#t + 1] = d end
  end
  table.sort(t, function(a, b) return (a.rssi or -200) > (b.rssi or -200) end)
  return t
end

local function open(c)
  local notify, service = op:notify_chars(c.addr)
  c.notify = notify
  local h, err = bt.open(c.addr, service, table.concat(notify, ","), op:write_char(c.addr), not c.seen_before)
  if not h then
    c.state, c.retry_t, c.hint = "reconnecting", RETRY_S, "Couldn't connect: " .. tostring(err)
    return
  end
  c.h, c.state, c.t0 = h, "connecting", now()
  c.hint = nil
end

local function close(c)
  if c.h then bt.close(c.h) end
  c.h = nil
end

local function lost(c, why)
  close(c)
  op:remove(c.addr)
  c.state, c.retry_t, c.hint = "reconnecting", RETRY_S, why
end

-- connect a device. entry: {addr, name} from the scan, or a remembered {addr, name, kind}
function M.connect(entry)
  local c = M.conns[entry.addr]
  if c and c.state ~= "unknown" and c.state ~= "failed" then return c end
  c = { addr = entry.addr, name = entry.name, kind = entry.kind, state = "exploring", seen_before = entry.kind ~= nil }
  if not M.conns[entry.addr] then M.order[#M.order + 1] = entry.addr end
  M.conns[entry.addr] = c
  if c.kind then
    op:add(c.addr, c.name, nil, c.kind)
    open(c)
  else
    explore_queue[#explore_queue + 1] = c
  end
  return c
end

function M.disconnect(addr)
  local c = M.conns[addr]
  if not c then return end
  close(c)
  op:remove(addr)
  M.conns[addr] = nil
  for i, a in ipairs(M.order) do if a == addr then table.remove(M.order, i) break end end
  for i, e in ipairs(explore_queue) do if e == c then table.remove(explore_queue, i) break end end
  if exploring == c then exploring = nil end
end

-- connect everything the player connected before
function M.reconnect_remembered()
  for addr, d in pairs(settings.data.devices) do
    if not M.conns[addr] then M.connect({ addr = addr, name = d.name, kind = d.kind }) end
  end
end

local function step_explore()
  if exploring then
    local st = bt.explore_state()
    if st == 2 or st == -1 then
      local c = exploring
      exploring = nil
      if M.conns[c.addr] ~= c then return end
      local uuids = {}
      for u in bt.explore_text():gmatch("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)") do uuids[#uuids + 1] = u end
      local kind = #uuids > 0 and op:add(c.addr, c.name, uuids) or nil
      if not kind then
        c.state = st == -1 and "failed" or "unknown"
        c.hint = st == -1 and "Couldn't look inside it. Is it on and close by?" or "OmniPlay doesn't know this device"
        return
      end
      c.kind = kind
      open(c)
    end
    return
  end
  local c = table.remove(explore_queue, 1)
  if c then
    if bt.explore(c.addr) then exploring = c
    else table.insert(explore_queue, 1, c) end -- busy: try next frame
  end
end

function M.update(dt)
  if not bt then return end
  if bt.update then bt.update(dt) end
  step_explore()
  for _, addr in ipairs(M.order) do
    local c = M.conns[addr]
    if c.state == "reconnecting" then
      c.retry_t = c.retry_t - dt
      if c.retry_t <= 0 then op:add(c.addr, c.name, nil, c.kind); open(c) end
    elseif c.state == "connecting" then
      local st = bt.state(c.h)
      if st == 2 then
        c.state, c.last_data, c.seen_before = "connected", now(), true
        op:connected(c.addr)
        settings.remember(c.addr, c.name, c.kind)
      elseif st == -1 then
        local err = bt.error(c.h)
        lost(c, err ~= "" and err or "Couldn't connect")
      end
    elseif c.state == "connected" then
      if bt.state(c.h) ~= 2 then lost(c, "Lost the connection. Reconnecting...")
      else
        while true do
          local bytes, which = bt.read(c.h)
          if not bytes then break end
          c.last_data = now()
          local char = c.notify[which + 1]
          if char then op:receive(c.addr, char, bytes) end
        end
        if WATCHED[c.kind] and now() - c.last_data > WATCHDOG_S then lost(c, "No data for a while. Reconnecting...") end
      end
    end
  end
  op:update(dt)
end

-- for the UI: every connection, in the order they were added
function M.list()
  local t = {}
  for _, addr in ipairs(M.order) do t[#t + 1] = M.conns[addr] end
  return t
end
function M.any_connected()
  for _, c in pairs(M.conns) do if c.state == "connected" then return true end end
  return false
end
function M.label(kind) return kind and sdk.KINDS[kind] and sdk.KINDS[kind].label or "Unknown device" end

return M
