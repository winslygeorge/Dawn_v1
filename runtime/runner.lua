package.path = package.path .. ";../?.lua;../utils/?.lua"

local Scheduler = require("runtime.scheduler")
local uv = require("luv")



-- Core Runtime Runner
local Runner = {}
Runner.__index = Runner

function Runner:new(logger)
    local obj = setmetatable({}, self)
    obj.loop = uv.loop() -- Use default loop, or create a new one if necessary
    obj.logger = logger or require("utils.logger").new() -- Ensure logger is created if not passed
    obj.scheduler = Scheduler:new(obj.logger)  -- Inject logger into scheduler
    return obj
end

-- Add essential tasks to scheduler
function Runner:initialize()
    self.logger:log("INFO", "Initializing Core Runtime", "Runner")

    -- Example async task with error handling
    self.scheduler:add_task(function()
        local success, err = pcall(function()
            self.logger:log("DEBUG", "Running async task", "Runner")
            -- Simulated task workload here
            -- Example: uv.sleep(1)
        end)
        if not success then
            self.logger:log("ERROR", "Task failed: " .. tostring(err), "Runner")
        end
    end)

    -- Start system monitoring
    self.scheduler:monitorSystem()
end

-- Main execution loop with fault tolerance
function Runner:run()
    self:initialize()
    self.scheduler:run()  -- Run the scheduler's coroutine tasks
    self.logger:log("INFO", "Starting Event Loop", "Runner")

    local success, err = pcall(function()
        uv.run(self.loop) -- Use the loop from the object
    end)
    if not success then
        self.logger:log("ERROR", "Event Loop Error: " .. tostring(err), "Runner")
    end
end

-- Graceful shutdown with resource cleanup
function Runner:shutdown()
    self.logger:log("WARN", "Shutting down system", "Runner")
    self.scheduler:shutdown()

    -- Ensure all handles are closed to prevent leaks
    uv.walk(self.loop, function(handle)
        if not uv.is_closing(handle) then
            uv.close(handle)
        end
    end)

    -- Run the loop until all handles are closed and it's empty
    while uv.run(self.loop, uv.RUN_NOWAIT) ~= 0 do
        -- Continue running the loop until it's empty.
    end

    uv.loop_close(self.loop) -- close the loop.
    self.logger:shutdown()
end

return Runner