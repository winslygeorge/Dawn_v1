
package.path = package.path .. ";../?.env;../utils/?.env"

local ffi = require("ffi")
ffi.cdef[[
  int setenv(const char *name, const char *value, int overwrite);
]]

local M = {}

-- Reads and loads env vars from a file
function M.load_env_file(filename)
  local file = io.open('../'..filename, "r")
  if not file then return false, "Could not open " .. filename end

  for line in file:lines() do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key and value then
      ffi.C.setenv(key, value, 1)
    end
  end

  file:close()
  return true
end

-- Main load function with environment support
function M.load(env_name)
  env_name = env_name or os.getenv("APP_ENV") or "dev"
  local filename = env_name .. ".env" -- e.g. dev.env or prod.env

  local ok, err = M.load_env_file(filename)
  if not ok then
    print("Warning: Failed to load " .. filename .. ": " .. err)
  end

  return ok
end

return M
