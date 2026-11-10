-- The SDK's Lua core against tests/sdk/vectors.json (the JS core runs the same file: tests/sdk/test_sdk.mjs)
package.path = "sdk/lua/?.lua;app/?.lua;" .. package.path
local OmniPlay = require("omniplay")
local json = require("json")
local f = assert(io.open("tests/sdk/vectors.json")); local scenarios = json.decode(f:read("*a")); f:close()

local function hexs(s) local t = {} for i = 1, #s do t[i] = string.format("%02X", s:byte(i)) end return table.concat(t, " ") end
local function bytes(h) local t = {} for x in h:gmatch("%x%x") do t[#t + 1] = string.char(tonumber(x, 16)) end return table.concat(t) end
local STATUS = hexs(table.concat((function() local t = {} for _, v in ipairs(OmniPlay.SPERAX.STATUS) do t[#t + 1] = string.char(v) end return t end)()))
local NULL = json.null

local function same(want, got, path)
  if want == NULL or want == nil then assert(got == nil, path .. ": want nil, got " .. tostring(got)) return end
  if type(want) == "number" then assert(type(got) == "number" and math.abs(got - want) < 0.15, path .. ": want " .. want .. ", got " .. tostring(got)) return end
  if type(want) == "table" then for k, v in pairs(want) do same(v, got and got[k], path .. "." .. k) end return end
  assert(want == got, path .. ": want " .. tostring(want) .. ", got " .. tostring(got))
end

for _, sc in ipairs(scenarios) do
  local writes, events = {}, {}
  local opts = { send = function(id, char, b) writes[#writes + 1] = id .. " " .. OmniPlay.short_uuid(char) .. " " .. hexs(b) end,
                 on_event = function(n, v) events[#events + 1] = { n, v } end }
  for k, v in pairs(sc.opts or {}) do opts[k] = v end
  local op = OmniPlay.new(opts)
  for i, st in ipairs(sc.steps) do
    local where = sc.name .. " step " .. i
    if st.detect then same(st.kind, OmniPlay.detect(st.detect, st.name), where .. " detect " .. st.name)
    elseif st.add then local k = op:add(st.add, st.name, st.uuids); if st.kind then same(st.kind, k, where) end
    elseif st.notify then local c = op:notify_chars(st.notify); assert(table.concat(c, ",") == table.concat(st.chars, ","), where .. " notify")
    elseif st.connected then op:connected(st.connected)
    elseif st.remove then op:remove(st.remove)
    elseif st.rx then op:receive(st.rx, st.char, bytes(st.hex))
    elseif st.update then op:update(st.update)
    elseif st.grade then op:set_grade(st.grade)
    elseif st.belt then op:set_belt_speed(st.belt)
    elseif st.expect then same(st.expect, op:values(), where)
    elseif st.writes or st.writes_without_status then
      local got = {}
      for _, w in ipairs(writes) do if st.writes or not w:find(STATUS, 1, true) then got[#got + 1] = w end end
      local want = st.writes or st.writes_without_status
      assert(table.concat(got, " | ") == table.concat(want, " | "), where .. " writes:\n  want " .. table.concat(want, " | ") .. "\n  got  " .. table.concat(got, " | "))
      writes = {}
    elseif st.events then
      local got, want = {}, {}
      for _, e in ipairs(events) do got[#got + 1] = table.concat(e, ":") end
      for _, e in ipairs(st.events) do want[#want + 1] = table.concat(e, ":") end
      assert(table.concat(got, ",") == table.concat(want, ","), where .. " events: want " .. table.concat(want, ",") .. " got " .. table.concat(got, ","))
      events = {}
    end
  end
  print("ok  " .. sc.name)
end
print("sdk lua tests passed")
