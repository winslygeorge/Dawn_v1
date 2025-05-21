local Supervisor = require("loop")
local luv = require("luv")
local logger = {
    log = function(level, message, component)
        print(string.format("[%s] [%s] %s", level, component or "Benchmark", message))
    end
}

local function mock_child(name)
    return {
        name = name,
        restart_count = 0,
        backoff = 1000,
        restart = function(self)
            self.restart_count = self.restart_count + 1
            return true  -- Simulating successful restart
        end,
        stop = function(self)
            return true  -- Simulating successful stop
        end
    }
end

local supervisor = Supervisor:new("BenchmarkSupervisor", "one_for_one", logger)

-- Add mock children
local NUM_CHILDREN = 0
for i = 1, NUM_CHILDREN do
    supervisor:addChild(mock_child("child_" .. i))
end

local start_time, end_time

-- Benchmark Restart Time
start_time = luv.hrtime()
supervisor:restartChildrenBatch(supervisor.children)
luv.run("default")
end_time = luv.hrtime()
logger:log("BENCHMARK", string.format("Restart Time: %.6f seconds", (end_time - start_time) / 1e9))

-- Benchmark Scheduler Overhead
start_time = luv.hrtime()
supervisor.scheduler:add_task("test_task", function() end, 100, 1, 1, 5)
luv.run("default")
end_time = luv.hrtime()
logger:log("BENCHMARK", string.format("Scheduler Task Execution Time: %.6f seconds", (end_time - start_time) / 1e9))

-- Benchmark Memory Usage
collectgarbage()
local before_mem = collectgarbage("count")
supervisor:restartChildrenBatch(supervisor.children)
luv.run("default")
collectgarbage()
local after_mem = collectgarbage("count")
logger:log("BENCHMARK", string.format("Memory Usage Before: %.3f KB", before_mem))
logger:log("BENCHMARK", string.format("Memory Usage After: %.3f KB", after_mem))
logger:log("BENCHMARK", string.format("Memory Increased By: %.2f KB", after_mem - before_mem))

-- Benchmark Circuit Breaker Activation
local test_child = mock_child("test_child")
supervisor:addChild(test_child)
for _ = 1, 3 do
    supervisor:logFailure(test_child)
end
logger:log("BENCHMARK", string.format("Circuit Breaker State: %s", supervisor.circuitBreaker[test_child.name] and "ACTIVE" or "INACTIVE"))

-- Benchmark Stress Test
start_time = luv.hrtime()
supervisor:restartChildrenBatch(supervisor.children)
luv.run("default")
end_time = luv.hrtime()
logger:log("BENCHMARK", string.format("Stress Test Completed in: %.6f seconds", (end_time - start_time) / 1e9))

logger:log("BENCHMARK", "All Tests Completed ✅")
