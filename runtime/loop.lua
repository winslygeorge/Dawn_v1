package.path = package.path .. ";../?.lua;../utils/?.lua"

local ffi = require("ffi")
local luv = require("luv")
local Scheduler = require("runtime.scheduler")
local log_level = require('utils.logger').LogLevel

ffi.cdef[[
typedef struct { /* opaque */ } uv_loop_t;
typedef struct { /* opaque */ } uv_timer_t;
typedef struct { /* opaque */ } uv_async_t;
]]

-- Constants
local MAX_RESTARTS = 1000  -- Increased to handle more failures before giving up
local INITIAL_BACKOFF = 500  -- Reduced to accelerate restart attempts
local MAX_BACKOFF = 1000  -- Reduced to prevent excessive delays
local CIRCUIT_BREAKER_THRESHOLD = 1000  -- Increased to tolerate more failures before triggering
local CIRCUIT_BREAKER_TIMEOUT = 5000  -- Reduced cooldown to recover faster
local FAILURE_EXPIRATION_TIME = 300  -- Reduced to quickly discard old failures
local BATCH_RESTART_LIMIT = 1000  -- Increased to allow more parallel restarts for better performance

local Supervisor = {}
Supervisor.__index = Supervisor

function Supervisor:new(name, strategy, logger)
    local self = setmetatable({}, Supervisor)
    self.name = name or "DefaultSupervisor"
    self.strategy = strategy or "one_for_one"
    self.children = {}
    self.runningChildren = {}
    self.failedProcesses = {}
    self.circuitBreaker = {}
    self.state = "running"
    self.logger = logger
    self.pendingRestarts = {}
    
    -- Initialize the scheduler
    self.scheduler = Scheduler:new(1000, self.logger)  -- Max 1000 tasks in queue
    return self
end

-- Enhanced Panic Recovery Wrapper
function Supervisor:safeCall(func, ...)
    local function errorHandler(err)
        self.logger:log(log_level.ERROR, "Unhandled error: " .. tostring(err) .. "\n" .. debug.traceback(), "Supervisor")
        return err
    end
    return xpcall(func, errorHandler, ...)
end

-- function Supervisor:safeCall(fn)
--     local ok, result = pcall(fn)
--     if not ok then
--         self.logger:log("ERROR", "safeCall failed: " .. tostring(result), "Supervisor")
--         return false, result
--     end
--     return true, result
-- end


function Supervisor:addChild(child)
    assert(type(child.stop) == "function", "Child " .. child.name .. " must implement a stop() method")

    self.children[child.name] = child
    -- self.runningChildren[child.name] = true
end


function Supervisor:logFailure(child)
    print("logFailure called for:", child.name) -- Add this line
    local now = os.time() * 1000
    self.failedProcesses[child.name] = self.failedProcesses[child.name] or {}
    
    table.insert(self.failedProcesses[child.name], now)

    -- Expire old failures
    for i = #self.failedProcesses[child.name], 1, -1 do
        if now - self.failedProcesses[child.name][i] > FAILURE_EXPIRATION_TIME then
            table.remove(self.failedProcesses[child.name], i)
        end
    end

    -- Circuit breaker activation
    if #self.failedProcesses[child.name] >= CIRCUIT_BREAKER_THRESHOLD then
        self.circuitBreaker[child.name] = true
        self.logger:log(log_level.WARN, "Circuit breaker activated for " .. child.name, "Supervisor")
        
        local timer = luv.new_timer()
        luv.timer_start(timer, CIRCUIT_BREAKER_TIMEOUT, 0, function()
            self.circuitBreaker[child.name] = false
            self.logger:log(log_level.INFO, "Circuit breaker reset for " .. child.name, "Supervisor")
        end)
    end
end

function Supervisor:startChild(child)
    
    local ok, err = self:safeCall(function()
        if self.runningChildren[child.name] then
            self.logger:log(log_level.WARN, "Child " .. child.name .. " is already running", "Supervisor")
            return false
        end

        -- Set default restart_policy if not defined
        child.restart_policy = child.restart_policy or "permanent"
        child.backoff = child.backoff or INITIAL_BACKOFF
        child.restart_count = child.restart_count or 0

        self.logger:log(log_level.INFO, "Starting child: " .. child.name .. " [policy: " .. child.restart_policy .. "]", "Supervisor")
        local success = child:start()

        if success then
            self:addChild(child)
            self.logger:log(log_level.INFO, "Child " .. child.name .. " started successfully", "Supervisor")
            return true
        else
            self:logFailure(child)

            if child.restart_policy == "permanent" or child.restart_policy == "transient" then
                self.logger:log(log_level.ERROR, "Failed to start child " .. child.name .. ". Scheduling retry.", "Supervisor")
                self:scheduleRestart(child)
            else
                self.logger:log(log_level.WARN, "Child " .. child.name .. " is marked 'temporary' and will not be restarted after failure", "Supervisor")
            end

            return false
        end
    end)

    if not ok then
        self.logger:log(log_level.FATAL, "Unexpected error while starting " .. child.name .. ": " .. tostring(err), "Supervisor")
    end
end


-- function Supervisor:scheduleRestart(child)
--     if self.circuitBreaker[child.name] or self.pendingRestarts[child.name] then return end
--     self.logger:log("DEBUG", "Scheduling restart for " .. child.name, "Supervisor")
--     self.pendingRestarts[child.name] = true

--     print("self.failedProcesses[child.name]:", self.failedProcesses[child.name]) -- Add this line

--     self.scheduler:add_task(
--         "restart_" .. child.name,
--         function() self:restartChildBatch() end,
--         child.backoff,
--         math.max(1, 5 - #self.failedProcesses[child.name]),
--         3,
--         5
--     )
-- end

function Supervisor:scheduleRestart(child)
    if self.circuitBreaker[child.name] or self.pendingRestarts[child.name] then return end
    self.logger:log(log_level.DEBUG, "Scheduling restart for " .. child.name, "Supervisor")
    self.pendingRestarts[child.name] = true

    print("self.failedProcesses[child.name]:", self.failedProcesses[child.name])

    self.scheduler:add_task(
        "restart_" .. child.name,
        function() self:restartChildBatch() end,
        child.backoff,
        1, -- Changed to a constant value
        3,
        5
    )
end

function Supervisor:restartChildBatch()
    local restartCount = 0
    for childName, _ in pairs(self.pendingRestarts) do
        if restartCount >= BATCH_RESTART_LIMIT then break end
        local child = self.children[childName]
        if child then
            self.pendingRestarts[childName] = nil
            self:restartChild(child)
            restartCount = restartCount + 1
        end
    end
end

function Supervisor:restartChild(child)
    if self.circuitBreaker[child.name] then return end

    child.restart_policy = child.restart_policy or "permanent"

    if child.restart_policy == "temporary" then
        self.logger:log(log_level.DEBUG, "Child " .. child.name .. " is temporary and will not be restarted", "Supervisor")
        return
    end
    
    local ok, err = self:safeCall(function()
        if child.restart_count >= MAX_RESTARTS then
            self:logFailure(child)
            self.logger:log(log_level.ERROR, "Max restart attempts reached for " .. child.name, "Supervisor")
            return false
        end

        self.logger:log(log_level.INFO, "Restarting child: " .. child.name, "Supervisor")
        local success = child:restart()
        if success then
            self.runningChildren[child.name] = true
            child.backoff = INITIAL_BACKOFF
            self.logger:log(log_level.INFO, "Child " .. child.name .. " restarted successfully", "Supervisor")
            return true
        else
            child.backoff = math.min(child.backoff * 2, MAX_BACKOFF)
            self:logFailure(child)
            self.logger:log(log_level.ERROR, "Restart failed for " .. child.name .. ". Retrying in " .. child.backoff .. " ms", "Supervisor")
            self:scheduleRestart(child)
            return false
        end
    end)
    
    if not ok then
        self.logger:log(log_level.FATAL, "Unexpected error while restarting " .. child.name .. ": " .. tostring(err), "Supervisor")
    end
end

function Supervisor:sleep(ms, callback)
    local timer = luv.new_timer()
    luv.timer_start(timer, ms, 0, function()
        luv.timer_stop(timer)
        luv.close(timer)
        if callback then
            self:safeCall(callback)
        end
    end)
end

function Supervisor:stopChild(child)
    child = self.children[child.name]
    assert(type(child.stop) == "function", "Child " .. child.name .. " must implement a stop() method")
    local ok, err = self:safeCall(function()
        if self.runningChildren[child.name] then
            if type(child.stop) == "function" then
                local success, err = child:stop()
                if success then
                    self.runningChildren[child.name] = nil
                    self.logger:log(log_level.INFO, "Child " .. child.name .. " stopped", "Supervisor")
                else
                    self.logger:log(log_level.ERROR, "Failed to stop child " .. child.name .. ": " .. tostring(err), "Supervisor")
                end
            else
                self.logger:log(log_level.WARN, "Child " .. child.name .. " has no stop() method", "Supervisor")
            end
        end
        
    end)
    
    if not ok then
        self.logger:log(log_level.FATAL, "Unexpected error while stopping " .. child.name .. ": " .. tostring(err), "Supervisor")
    end
end

function Supervisor:stop()
    if self.state ~= "running" then return end
    self.state = "stopped"
    
    for _, child in pairs(self.children) do
        self:stopChild(child)
    end
    
    -- Clear all pending restart tasks
    for task_id in pairs(self.pendingRestarts) do
        self.scheduler.task_map[task_id] = nil
    end
    self.pendingRestarts = {}

    self.logger:log(log_level.INFO, "Supervisor " .. self.name .. " stopped", "Supervisor")
end

return Supervisor
