local url = require("net.url")

local URLParamExtractor = {}
URLParamExtractor.__index = URLParamExtractor

--- Creates a new instance of the URLParamExtractor class.
---
--- @return table A new URLParamExtractor instance.
function URLParamExtractor:new()
  local instance = setmetatable({}, URLParamExtractor)
  return instance
end

--- Extracts query parameters from a URL-like string, stopping at the first HTTP/1.1.
---
--- @param url_like_string string A string that might contain a URL with query
---                        parameters followed by HTTP headers.
--- @return table A Lua table where keys are parameter names and values
---               are parameter values (or tables of values). Returns an empty
---               table if no query parameters are found.
function URLParamExtractor:extract_from_url_like_string(url_like_string)
    if not url_like_string then
        print("Error: Input url_like_string is nil.")
        return {} -- Or return nil, depending on your error handling strategy
      end
      -- The rest of your function logic
local query_end = string.find(url_like_string, " HTTP/1.1")
    
  local url_part = url_like_string
  if query_end then
    url_part = string.sub(url_like_string, 1, query_end - 1)
  end

  local query_start = string.find(url_part, "?")
  if query_start then
    local path_and_query = string.sub(url_part, query_start)
    local parsed_url = url.parse(path_and_query)
    return parsed_url.query or {}
  end

  return {}
end

return URLParamExtractor