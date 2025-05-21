local json = require("cjson.safe")  -- Use cjson.safe to avoid crashes on bad JSON

local M = {}

function M.load(env)
  env = env or os.getenv("APP_ENV") or "dev"
  local path = string.format("../config/%s.json", env)

  local file = io.open(path, "r")
  if not file then
    error("Missing config: " .. path)
  end

  local content = file:read("*a")
  file:close()

  local parsed, err = json.decode(content)
  if not parsed then
    error("JSON parse error in " .. path .. ": " .. err)
  end

  M.config = parsed
  return M.config
end

function M.get(key, fallback)
  local value = M.config and M.config[key]
  return value ~= nil and value or fallback
end

return M
