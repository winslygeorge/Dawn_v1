-- promise.lua
local uv = require("luv")

local Promise = {}
Promise.__index = Promise

local function is_callable(obj)
  return type(obj) == "function" or (getmetatable(obj) and getmetatable(obj).__call)
end

function Promise:new(executor)
  local obj = setmetatable({
    status = "pending",
    value = nil,
    reason = nil,
    on_fulfilled = {},
    on_rejected = {},
  }, self)

  local function resolve(value)
    if obj.status ~= "pending" then return end
    obj.status = "fulfilled"
    obj.value = value
    for _, cb in ipairs(obj.on_fulfilled) do cb(value) end
  end

  local function reject(reason)
    if obj.status ~= "pending" then return end
    obj.status = "rejected"
    obj.reason = reason
    for _, cb in ipairs(obj.on_rejected) do cb(reason) end
  end

  -- Protect executor
  local ok, err = pcall(function()
    executor(resolve, reject)
  end)
  if not ok then
    reject(err)
  end

  return obj
end

function Promise:then_(on_fulfilled, on_rejected)
  return Promise:new(function(resolve, reject)
    local function handle_fulfilled(value)
      if is_callable(on_fulfilled) then
        local ok, result = pcall(on_fulfilled, value)
        if ok then resolve(result) else reject(result) end
      else
        resolve(value)
      end
    end

    local function handle_rejected(reason)
      if is_callable(on_rejected) then
        local ok, result = pcall(on_rejected, reason)
        if ok then resolve(result) else reject(result) end
      else
        reject(reason)
      end
    end

    if self.status == "fulfilled" then
      handle_fulfilled(self.value)
    elseif self.status == "rejected" then
      handle_rejected(self.reason)
    else
      table.insert(self.on_fulfilled, handle_fulfilled)
      table.insert(self.on_rejected, handle_rejected)
    end
  end)
end

function Promise:catch_(on_rejected)
  return self:then_(nil, on_rejected)
end

-- await() blocks the current coroutine until a promise resolves
local function await(promise)
  local co = coroutine.running()
  assert(co, "await must be called inside an async function")

  promise:then_(function(value)
    coroutine.resume(co, true, value)
  end, function(reason)
    coroutine.resume(co, false, reason)
  end)

  local ok, result = coroutine.yield()
  if ok then
    return result
  else
    error(result)
  end
end

-- async wraps a function into a coroutine that supports await()
-- Replace the existing async with this:
local function async(fn)
  return function(...)
    local args = {...}
    return Promise:new(function(resolve, reject)
      local co = coroutine.create(fn)
      local function step(ok, ...)
        if not ok then
          reject(...)
          return
        end

        local stat, res_or_err = coroutine.resume(co, ...)
        if not stat then
          reject(res_or_err)
          return
        end

        if coroutine.status(co) == "dead" then
          resolve(res_or_err)
        end
        -- if not dead, it's waiting for a `coroutine.yield()` from await
        -- and the next resume will be handled by await's callback
      end
      step(true, unpack(args))
    end)
  end
end


-- settimeout.lua
local function setTimeout(ms, callback)
  local timer = uv.new_timer()
  uv.timer_start(timer, ms, 0, function()
    uv.timer_stop(timer)
    uv.close(timer)
    callback()
  end)
end


return {
  Promise = Promise,
  await = await,
  async = async,
    setTimeout = setTimeout,
}
