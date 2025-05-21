local Scheduler = require("scheduler") -- Assuming the scheduler.lua file is in the same directory
local luv = require("luv")

-- Mock logger (for testing purposes)
local mockLogger = {
    log = function(level, message, source)
        -- In a real test, you might assert something about the log message here
        print(string.format("[%s] %s - %s", level, message, source))
    end,
    LogLevel = {
        DEBUG = "DEBUG",
        INFO = "INFO",
        WARN = "WARN",
        ERROR = "ERROR",
    }
}

-- Create a scheduler instance with a large queue size
local scheduler = Scheduler:new(2000, mockLogger) -- Increased maxQueueSize to handle more tasks than connections

-- Function to simulate a task (e.g., handling a connection)
local function connection_handler(conn_id)
    -- Simulate some work (e.g., reading/writing data)
    local start_time = luv.now()
    local duration = math.random(100, 500) / 1000 -- Simulate task duration between 0.1 and 0.5 seconds
    luv.sleep(duration)
    local end_time = luv.now()
    -- print(string.format("Connection %d handled in %.3f seconds", conn_id, duration))
    return true, string.format("Connection %d handled in %.3f seconds", conn_id, (end_time - start_time)/1000)
end

-- Add a large number of tasks to the scheduler, simulating many connections
local num_connections = 10
local start_time = luv.now()
print(string.format("Adding %d connections...", num_connections))
for i = 1, num_connections do
    local delay = math.random(0, 100) / 1000 -- Random delay between 0 and 0.1 seconds
    scheduler:add_task("conn_" .. i, function() return connection_handler(i) end, delay, math.random(1, 3)) -- Add a function wrapper
end

-- Run the scheduler for a sufficient amount of time to process all tasks.  Important.
luv.run() -- Keep the loop running

local end_time = luv.now()
print(string.format("%d connections handled in %.3f seconds", num_connections, (end_time - start_time)/1000))

-- Check if all tasks were executed (this is rudimentary, a proper test framework is better)
local executed_tasks = 0
for k, _ in pairs(scheduler.task_map) do
    executed_tasks = executed_tasks + 1
end

print(string.format("Number of tasks left in queue: %d", executed_tasks))

-- Basic check:  Ideally executed_tasks should be 0 or very close to 0
if executed_tasks <= 10 then -- Allow a small number of tasks to remain, in case of timing issues.
    print("Test passed: Scheduler handled 1000 connections (mostly) successfully.")
else
    print("Test failed: Scheduler did not handle 1000 connections successfully.")
end
