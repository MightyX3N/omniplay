-- Tiny persistence helpers: Lua-table files in LÖVE's save folder, plain files next to the exe.
local M = {}

local function ser(v, ind)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t ~= "table" then return "nil" end
  ind = ind or ""
  local out, keys = { "{" }, {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. ser(k) .. "]")
    out[#out + 1] = ind .. "  " .. key .. " = " .. ser(v[k], ind .. "  ") .. ","
  end
  out[#out + 1] = ind .. "}"
  return table.concat(out, "\n")
end
M.serialize = ser

function M.save(name, value)
  return love.filesystem.write(name, "return " .. ser(value) .. "\n")
end

function M.load(name, default)
  if not love.filesystem.getInfo(name) then return default end
  local chunk = loadstring(love.filesystem.read(name) or "", name)
  if not chunk then return default end
  setfenv(chunk, {})
  local ok, v = pcall(chunk)
  if ok and type(v) == "table" then return v end
  return default
end

-- Folder next to OmniPlay.exe (created if missing), for files the user takes elsewhere.
function M.exe_dir(sub)
  local base = love.filesystem.getSourceBaseDirectory()
  if not sub then return base end
  local dir = base .. "/" .. sub
  local ok, ffi = pcall(require, "ffi")
  if ok and ffi.os == "Windows" then
    pcall(ffi.cdef, "int CreateDirectoryA(const char *path, void *sa);")
    pcall(function() ffi.C.CreateDirectoryA(dir, nil) end)
  end
  return dir
end

function M.write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data); f:close()
  return true
end

return M
