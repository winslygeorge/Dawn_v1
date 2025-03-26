local ffi = require("ffi")
local libuv = require("uv")
local logger = require("logger") -- Placeholder for a proper logging library
local monitoring = require("monitoring") -- Placeholder for a monitoring/alerting system

-- Define C function signatures for libuv
ffi.cdef[[
typedef void (*uv_walk_cb)(void* handle, void* arg);
typedef struct { /* opaque */ } uv_loop_t;
typedef struct { /* opaque */ } uv_timer_t;
typedef struct { /* opaque */ } uv_async_t;
typedef struct { const char* name; } timer_meta_t;

int uv_loop_init(uv_loop_t* loop);
int uv_run(uv_loop_t* loop, int mode);
void uv_stop(uv_loop_t* loop);
void uv_loop_close(uv_loop_t* loop);

int uv_timer_init(uv_loop_t* loop, uv_timer_t* handle);
int uv_timer_start(uv_timer_t* handle, void* cb, uint64_t delay, uint64_t repeat);
int uv_timer_stop(uv_timer_t* handle);
void uv_close(void* handle, void* close_cb);

int uv_async_init(uv_loop_t* loop, uv_async_t* handle, void* async_cb);
int uv_async_send(uv_async_t* handle);
]]

-- Supervisor restart and failure thresholds
local MAX_RESTARTS = 5 -- Max restart attempts per child process
local INITIAL_RESTART_BACKOFF = 1000 -- Initial delay before restarting a failed process (ms)
local MAX_RESTART_BACKOFF = 60000 -- Maximum delay before restarting a failed process (ms)
local SUPERVISOR_FAIL_THRESHOLD = 10 -- Max failures within a window before supervisor degrades
local SUPERVISOR_FAIL_WINDOW = 60000 -- Time window for failure tracking (ms)
local SUPERVISOR_RECOVERY_TIME = 300000 -- Time before supervisor attempts recovery (ms)

-- Utility function to check libuv function return values and log errors
local function uv_check(err, func_name, context)
    if err < 0 then
        local error_msg = string.format("%s failed in %s: %d", func_name, context or "unknown context", err)
        logger.error(error_msg)
        monitoring.alert("Critical", error_msg)
        error(error_msg)
    end
end

-- Cleanup function to ensure proper memory management
local function close_callback(handle)
    ffi.gc(handle, nil)
end

-- Handles child process failures by logging errors and updating process state
local function handle_child_failure(child, err)
    local error_msg = string.format("Child process '%s' failed | Error: %s | State: %s | Restart Count: %d", child.name, err or "unknown", child.state, child.restart_count)
    logger.error(error_msg)
    monitoring.notify("warning", error_msg)
    child.error = err
    child.state = "failed"
end

local Supervisor = {}
Supervisor.__index = Supervisor

-- Function to restart a child process based on the supervisor's strategy
function Supervisor:restartChild(child)
    if self.degraded then return end
    local restart_msg = string.format("Restarting child process: %s (Strategy: %s, Restart Count: %d)", child.name, self.strategy, child.restart_count)
    logger.info(restart_msg)
    monitoring.track("restart", restart_msg)
    
    -- Restart strategies:
    -- 1. one_for_one: Restart only the failed child
    -- 2. one_for_all: Restart all children when one fails
    -- 3. rest_for_one: Restart the failed child and all subsequent children
    if self.strategy == "one_for_all" then
        logger.warn("[Supervisor]: Restarting all children due to failure in %s", child.name)
        for _, c in ipairs(self.children) do
            self:restartChildWithBackoff(c)
        end
    elseif self.strategy == "rest_for_one" then
        logger.warn("[Supervisor]: Restarting failed child and all after it due to %s", child.name)
        local found = false
        for _, c in ipairs(self.children) do
            if found or c == child then
                self:restartChildWithBackoff(c)
                found = true
            end
        end
    else -- Default "one_for_one"
        self:restartChildWithBackoff(child)
    end
end

-- Function to restart a child process with an increasing backoff time
function Supervisor:restartChildWithBackoff(child)
    if self.degraded then return end
    local restart_msg = string.format("Restarting child with backoff: %s (Current Backoff: %dms, Max: %dms)", child.name, child.backoff, child.maxBackoff)
    logger.debug(restart_msg)
    monitoring.track("restart_backoff", restart_msg)
    
    local timer = ffi.new("uv_timer_t")
    ffi.gc(timer, function(handle)
        libuv.uv_close(handle, ffi.cast("void (*)(void*)", close_callback))
    end)
    uv_check(libuv.uv_timer_init(self.loop, timer), "uv_timer_init", "Supervisor:restartChildWithBackoff")

    local function timer_cb_c(handle)
        local ok, err = child:restart()
        if ok then
            self.runningChildren[child] = true
            child.backoff = INITIAL_RESTART_BACKOFF
            logger.info(string.format("Child '%s' restarted successfully", child.name))
        else
            handle_child_failure(child, err)
            self:logFailure()
            monitoring.notify("critical", string.format("Child '%s' restart failed: %s", child.name, err))
            if err == "Max restart limit reached" then
                self:onFatalError(string.format("Child '%s' exceeded restart limit", child.name))
            else
                self:queueRestart(child)
                child.backoff = math.min(child.backoff * 2, child.maxBackoff)
            end
        end
        libuv.uv_timer_stop(handle)
    end

    uv_check(libuv.uv_timer_start(timer, ffi.cast("void (*)(uv_timer_t*)", timer_cb_c), child.backoff, 0), "uv_timer_start", "Supervisor:restartChildWithBackoff")
end

-- Handles critical supervisor failures and stops execution
function Supervisor:onFatalError(err)
    local error_msg = string.format("[Supervisor Fatal]: %s (Supervisor: %s, Running Children: %d)", err, self.name, #self.runningChildren)
    logger.fatal(error_msg)
    monitoring.alert("critical", error_msg)
    self:stop()
end

-- Stops the supervisor and all running child processes
function Supervisor:stop()
    if self.state ~= "running" then return end
    local stop_msg = string.format("Stopping supervisor: %s (Running Children: %d)", self.name, #self.runningChildren)
    logger.warn(stop_msg)
    monitoring.notify("info", stop_msg)
    self.state = "stopped"
    for _, child in ipairs(self.children) do
        self:stopChild(child)
    end
    if self.asyncHandle then
        libuv.uv_close(ffi.cast("void*", self.asyncHandle), ffi.cast("void (*)(void*)", close_callback))
        self.asyncHandle = nil
    end
end

return Supervisor
