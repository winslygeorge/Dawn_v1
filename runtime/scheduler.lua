package.path = package.path .. ";../?.lua;../utils/?.lua"

local Scheduler = {}
local luv = require("luv")
local FibHeap = require("utils.fibheap") -- Fibonacci heap module (to be implemented separately)
local log_level = require('utils.logger').LogLevel

function Scheduler:new(maxQueueSize, logger)
    local obj = {
        queue = FibHeap:new(), -- Fibonacci heap instead of array-based heap
        logger = logger,
        task_map = {},
        dependencies = {},
        dependents = {},
        timer = luv.new_timer(),
        running = false,
        maxQueueSize = maxQueueSize or 1000 -- Limit task queue size
    }
    setmetatable(obj, self)
    self.__index = self
    return obj
end

function Scheduler:add_task(id, func, delay, priority, retries, maxExecTime)
    local now = luv.now() / 1000
    if self.task_map[id] then return end -- Prevent duplicate tasks
    if self.queue:get_size() >= self.maxQueueSize then
        print("[Warning] Task queue is full! Dropping task:", id)
        self.logger:log(log_level.WARN, "Task queue is full! Dropping task: ".. id, "Scheduler")

        return
    end
    
    local task = {
        id = id,
        func = func,
        exec_time = now + (delay or 0),
        priority = priority or 1,
        retries = retries or 3,
        retry_attempts = 10,
        maxExecTime = maxExecTime or 5,
        weight = 1 / (priority + 1)
    }

    self.queue:insert(task.exec_time, task)
    self.task_map[id] = task

    if not self.running then
        self.running = true
        luv.timer_start(self.timer, 10, 10, function() self:run_tasks() end)
    end
end

function Scheduler:execute_task(task)
    local startTime = luv.now() / 1000
    local success, err = pcall(task.func)
    local execDuration = (luv.now() / 1000) - startTime

    if not success then
        -- print("[Error] Task failed:", task.id, "-", err)
        self.logger:log(log_level.ERROR, "Task failed: ".. task.id, "Scheduler")

        task.retry_attempts = task.retry_attempts + 1
        if task.retry_attempts < task.retries then
            self:retry_task(task)
        else
            -- print("[Fail] Task permanently failed:", task.id)
            self.logger:log(log_level.ERROR, "Task permanently failed: ".. task.id, "Scheduler")

        end
    elseif execDuration > task.maxExecTime then
        -- print("[Warning] Task", task.id, "exceeded max execution time!")
        self.logger:log(log_level.WARN, "Task ".. task.id.." exceeded max execution time! ", "Scheduler")

    end
end


function Scheduler:extract_min()
    if self.queue:is_empty() then return nil end
    local minTask = self.queue:extract_min()
    self.task_map[minTask.id] = nil
    return minTask
end

function Scheduler:run_tasks()
    local now = luv.now() / 1000    while not self.queue:is_empty() and 
    self.queue:find_min().exec_time <= now do
        local task = self:extract_min()
        -- Check if task has dependencies
        if self.dependencies[task.id] then
            local hasPendingDeps = false
            for dep in pairs(self.dependencies[task.id]) do
                if self.task_map[dep] then
                    hasPendingDeps = true
                    break
                end
            end
            if hasPendingDeps then
                -- Instead of reinserting, push to pending queue
                self.dependents[task.id] = task
                return
            end
            self.dependencies[task.id] = nil
        end

        self:execute_task(task)
    end

    if self.queue:is_empty() then
        self.running = false
        luv.timer_stop(self.timer)
    end
end


return Scheduler