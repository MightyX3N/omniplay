-- Small JSON encoder/decoder (objects, arrays, strings, numbers, booleans, null).
local M = {}
M.null = setmetatable({}, { __tostring = function() return "null" end })

local esc = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function enc_str(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return esc[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = math.max(n, k)
  end
  return n == #t, n
end

local function enc(v, out)
  local t = type(v)
  if v == nil or v == M.null then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif v % 1 == 0 and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "") end
  elseif t == "string" then out[#out + 1] = enc_str(v)
  elseif t == "table" then
    local arr = is_array(v)
    if arr and next(v) ~= nil then
      out[#out + 1] = "["
      for i = 1, #v do if i > 1 then out[#out + 1] = "," end enc(v[i], out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = enc_str(k) .. ":"
        local val = v[k]; if val == nil then val = v[tonumber(k)] end
        enc(val, out)
      end
      out[#out + 1] = "}"
    end
  else error("can't encode " .. t) end
end

function M.encode(v) local out = {} enc(v, out) return table.concat(out) end

-- ---------- decode ----------
local function err(s, i, msg) error(string.format("json: %s at %d", msg, i), 0) end
local function ws(s, i) return s:find("[^ \t\r\n]", i) or #s + 1 end

local dec
local function dec_str(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then err(s, j, "unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local n = s:sub(j + 1, j + 1)
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      if map[n] then out[#out + 1] = map[n]; j = j + 2
      elseif n == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16) or err(s, j, "bad \\u")
        if cp < 0x80 then out[#out + 1] = string.char(cp)
        elseif cp < 0x800 then out[#out + 1] = string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
        else out[#out + 1] = string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64) end
        j = j + 6
      else err(s, j, "bad escape") end
    else
      local k = s:find('["\\]', j) or #s + 1
      out[#out + 1] = s:sub(j, k - 1); j = k
    end
  end
end

dec = function(s, i)
  i = ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = ws(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then err(s, i, "expected key") end
      local k; k, i = dec_str(s, i)
      i = ws(s, i)
      if s:sub(i, i) ~= ":" then err(s, i, "expected :") end
      local v; v, i = dec(s, i + 1)
      t[k] = v
      i = ws(s, i)
      local d = s:sub(i, i)
      if d == "}" then return t, i + 1 end
      if d ~= "," then err(s, i, "expected , or }") end
      i = ws(s, i + 1)
    end
  elseif c == "[" then
    local t = {}
    i = ws(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      local v; v, i = dec(s, i)
      t[#t + 1] = v
      i = ws(s, i)
      local d = s:sub(i, i)
      if d == "]" then return t, i + 1 end
      if d ~= "," then err(s, i, "expected , or ]") end
      i = i + 1
    end
  elseif c == '"' then return dec_str(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then err(s, i, "unexpected character") end
    return tonumber(num), i + #num
  end
end

-- returns value, or nil + error message
function M.decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local ok, v, i = pcall(dec, s, 1)
  if not ok then return nil, v end
  if ws(s, i) <= #s then return nil, "trailing data" end
  return v
end

return M
