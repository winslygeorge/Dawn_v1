package.path = package.path .. ";../?.lua;../utils/?.lua"

local ffi = require("ffi")
local luv = require("luv")
local logger = require("utils.logger")

ffi.cdef[[
typedef void (*uv_walk_cb)(void* handle, void* arg);
typedef struct { /* opaque */ } uv_loop_t;
typedef struct { /* opaque */ } uv_timer_t;
typedef struct { /* opaque */ } uv_async_t;
]]

-- Constants
local MAX_RESTARTS = 5
local INITIAL_RESTART_BACKOFF = 1000
local MAX_RESTART_BACKOFF = 60000
local CIRCUIT_BREAKER_THRESHOLD = 3
local CIRCUIT_BREAKER_TIMEOUT = 120000  -- 2 minutes cooldown
local FAILURE_EXPIRATION_TIME = 60000  -- 1 minute

local function luv_check(err, func_name, context)
    if err then
        local message = func_name .. " failed in " .. (context or "unknown") .. ": " .. err
        logger:log("ERROR", message, "Supervisor")
        return false
    end
    return true
end

local Supervisor = {}
Supervisor.__index = Supervisor

function Supervisor:new(name, strategy)
    local self = setmetatable({}, Supervisor)
    self.name = name or "DefaultSupervisor"
    self.strategy = strategy or "one_for_one"
    self.children = {}
    self.runningChildren = {}
    self.failedProcesses = {}
    self.degraded = false
    self.circuitBreaker = false
    self.state = "running"  -- Ensure state is initialized
    return self
end

function Supervisor:logFailure(child)
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
        self.circuitBreaker = true
        logger:log("WARN", "Circuit breaker activated for " .. child.name .. ". Cooldown: " .. CIRCUIT_BREAKER_TIMEOUT .. " ms", "Supervisor")

        local timer = luv.new_timer()
        if timer then
            luv.timer_start(timer, CIRCUIT_BREAKER_TIMEOUT, 0, function()
                self.circuitBreaker = false
                logger:log("INFO", "Circuit breaker reset for " .. child.name, "Supervisor")
            end)
        else
            logger:log("ERROR", "Failed to create circuit breaker timer", "Supervisor")
        end
    end
end

function Supervisor:restartChild(child)
    if self.degraded or self.circuitBreaker then return end

    local timer = luv.new_timer()
    if not timer then
        logger:log("ERROR", "Failed to create restart timer for " .. child.name, "Supervisor")
        return
    end

    logger:log("DEBUG", "Restart timer created for " .. child.name, "Supervisor")

    luv.timer_start(timer, child.backoff, 0, function()
        if child.restart_count >= MAX_RESTARTS then
            self:logFailure(child)
            logger:log("ERROR", "Max restart attempts reached for " .. child.name, "Supervisor")
            return
        end

        local ok, err = child:restart()
        if ok then
            self.runningChildren[child] = true
            child.backoff = INITIAL_RESTART_BACKOFF
            logger:log("INFO", "Child " .. child.name .. " restarted successfully", "Supervisor")
        else
            child.backoff = math.min(child.backoff * 2, MAX_RESTART_BACKOFF)
            self:logFailure(child)
            logger:log("ERROR", "Restart failed for " .. child.name .. ". Retrying in " .. child.backoff .. " ms", "Supervisor")

            -- Schedule next retry using a new timer
            local retryTimer = luv.new_timer()
            if retryTimer then
                logger:log("DEBUG", "Retry timer created for " .. child.name, "Supervisor")
                luv.timer_start(retryTimer, child.backoff, 0, function()
                    self:restartChild(child)
                end)
            else
                logger:log("ERROR", "Failed to create retry timer for " .. child.name, "Supervisor")
            end
        end

        -- Debugging: Check if timer is valid before stopping
        if timer then
            if luv.is_active(timer) then
                logger:log("DEBUG", "Stopping timer for " .. child.name, "Supervisor")
                luv.timer_stop(timer)
            else
                logger:log("WARN", "Timer for " .. child.name .. " was not active when trying to stop", "Supervisor")
            end
        else
            logger:log("ERROR", "Timer was nil when trying to stop it for " .. child.name, "Supervisor")
        end
    end)
end



function Supervisor:stopChild(child)
    if self.runningChildren[child] then
        local success, err = child:stop()
        if success then
            self.runningChildren[child] = nil
            logger:log("INFO", "Child " .. child.name .. " stopped", "Supervisor")
        else
            logger:log("ERROR", "Failed to stop child " .. child.name .. ": " .. tostring(err), "Supervisor")
        end
    end
end

function Supervisor:stop()
    if self.state ~= "running" then return end
    self.state = "stopped"

    for _, child in ipairs(self.children) do
        self:stopChild(child)
    end

    logger:log("INFO", "Supervisor " .. self.name .. " stopped", "Supervisor")
end

return Supervisor
