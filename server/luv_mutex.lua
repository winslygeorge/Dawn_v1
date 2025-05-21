-- mutex.lua
local Mutex = {}
Mutex.__index = Mutex

function Mutex:new()
    local self = setmetatable({}, Mutex)
    self._locked = false
    self._owner = nil
    self._queue = {}
    return self
end

function Mutex:lock()
    local current_thread = coroutine.running()
    if not current_thread then
        error("Mutex:lock() can only be called from within a coroutine.")
    end

    if not self._locked then
        self._locked = true
        self._owner = current_thread
        return
    end

    if self._owner == current_thread then
        -- Re-entrant lock, though generally discouraged for simplicity in this context
        return
    end

    -- Suspend the current coroutine until the mutex is free
    table.insert(self._queue, current_thread)
    coroutine.yield()
end

function Mutex:unlock()
    local current_thread = coroutine.running()
    if not current_thread then
        error("Mutex:unlock() can only be called from within a coroutine.")
    end

    -- if self._owner ~= current_thread then
    --     error("Mutex:unlock() called by a non-owner coroutine.")
    --     return
    -- end

    if #self._queue > 0 then
        self._owner = table.remove(self._queue, 1)
        uv.async_send(uv.new_async(), function() -- Wake up the next in queue
            coroutine.resume(self._owner)
        end)
    else
        self._locked = false
        self._owner = nil
    end
end

return Mutex