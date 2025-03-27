-- runner.lua
package.path = package.path .. ";../?.lua;../utils/?.lua"
--if luv is installed in /path/to/luv/lib
-- package.path = package.path .. ";/path/to/luv/lib/?.lua;/path/to/luv/lib/?/init.lua"

local luv = require("luv")

--rest of your code.

local luv = require("luv")
local Scheduler = require("runtime.runner") -- Assuming your scheduler is in runtime/scheduler.lua
local Supervisor = require("runtime.loop") -- Assuming your supervisor is in runtime/supervisor.lua
local logger = require("utils.logger") -- Assuming you have a logger module

local Runner = {}
Runner.__index = Runner

function Runner:new()
    local self = setmetatable({}, Runner)
    self.loop = luv.new_loop()
    self.supervisor = Supervisor:new("MainSupervisor")
    self.scheduler = Scheduler:new(1000, logger) -- Initialize scheduler with max queue size and logger
    return self
end

function Runner:addTask(taskId, taskFunc, delay, priority, retries, maxExecTime)
    self.scheduler:add_task(taskId, taskFunc, delay, priority, retries, maxExecTime)
end

function Runner:addSupervisorChild(child)
  table.insert(self.supervisor.children,child);
  self.supervisor.runningChildren[child] = true;
end

function Runner:run()
    local function schedulerTask()
        self.scheduler:run_tasks()
    end

    local schedulerTimer = luv.new_timer()
    luv.timer_init(self.loop, schedulerTimer)
    luv.timer_start(schedulerTimer, 10, 10, schedulerTask) -- Run scheduler every 10ms

    logger:log("INFO", "Runner started", "Runner")

    luv.run(self.loop)

    logger:log("INFO", "Runner stopped", "Runner")
end

function Runner:stop()
  self.supervisor:stop();
  luv.stop(self.loop);
end

-- Example child process for supervisor
local ChildProcess = {}
ChildProcess.__index = ChildProcess

function ChildProcess:new(name, startFunc, stopFunc, restartFunc)
    local self = setmetatable({}, ChildProcess)
    self.name = name
    self.start = startFunc
    self.stop = stopFunc
    self.restart = restartFunc
    self.restart_count = 0;
    self.backoff = 1000;
    return self
end

-- Example Usage:
local runner = Runner:new()

-- Add scheduler tasks
runner:addTask("task1", function() logger:log("INFO", "Async task 1 running...", "Task1") end, 1000, 1)
runner:addTask("task2", function() logger:log("INFO", "Async task 2 running...", "Task2") end, 2000, 2)

-- Example child processes for supervisor
local child1 = ChildProcess:new("Child1",
    function() logger:log("INFO", "Child1 started", "Child1") return true; end,
    function() logger:log("INFO", "Child1 stopped", "Child1") return true; end,
    function() logger:log("INFO", "Child1 restarted", "Child1") return true; end
)

local child2 = ChildProcess:new("Child2",
    function() logger:log("INFO", "Child2 started", "Child2") return true; end,
    function() logger:log("INFO", "Child2 stopped", "Child2") return true; end,
    function() logger:log("INFO", "Child2 restarted", "Child2") return true; end
)

runner:addSupervisorChild(child1);
runner:addSupervisorChild(child2);

-- Run the runner
runner:run()

-- If you want to stop the runner later:
-- runner:stop()