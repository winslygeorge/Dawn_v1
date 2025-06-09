local redis = require("redis") -- Make sure you have a Lua Redis client installed (e.g. lua-redis)

local CacheManager = {}
CacheManager.__index = CacheManager

-- Configurable Redis connection params
CacheManager.config = {
    host = "127.0.0.1",
    port = 6379,
    timeout = 1000, -- milliseconds
    db = 0,
}

-- Create a Redis client connection
function CacheManager:new()
    local client = redis.connect(self.config.host, self.config.port)
    client:set_timeout(self.config.timeout)
    if self.config.db then
        client:select(self.config.db)
    end
    local obj = setmetatable({}, self)
    obj.client = client
    return obj
end

-- Set a cache key with value and TTL in seconds
function CacheManager:set(key, value, ttl)
    local ok, err = self.client:set(key, value)
    if not ok then
        return nil, err
    end
    if ttl and ttl > 0 then
        self.client:expire(key, ttl)
    end
    return true
end

-- Get a cache value by key
function CacheManager:get(key)
    local value, err = self.client:get(key)
    if err then
        return nil, err
    end
    return value
end

-- Delete a cache key
function CacheManager:del(key)
    return self.client:del(key)
end

-- Flush all keys in the current DB (use with care!)
function CacheManager:flushdb()
    return self.client:flushdb()
end

return CacheManager
