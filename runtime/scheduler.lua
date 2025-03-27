local Scheduler = {}
local luv = require("luv")

function Scheduler:new()
    local obj = {
        queue = {},
        queueSize = 0,
        task_map = {},
        dependencies = {},
        dependents = {},
        timer = luv.new_timer(),
        running = false
    }
    setmetatable(obj, self)
    self.__index = self
    return obj
end

-- Min Heap Helper Functions
local function heapify_up(queue, idx)
    while idx > 1 do
        local parent = math.floor(idx / 2)
        if queue[idx].exec_time >= queue[parent].exec_time then break end
        queue[idx], queue[parent] = queue[parent], queue[idx]
        idx = parent
    end
end

local function heapify_down(queue, idx, size)
    while true do
        local left, right, smallest = 2 * idx, 2 * idx + 1, idx
        if left <= size and queue[left].exec_time < queue[smallest].exec_time then smallest = left end
        if right <= size and queue[right].exec_time < queue[smallest].exec_time then smallest = right end
        if smallest == idx then break end
        queue[idx], queue[smallest] = queue[smallest], queue[idx]
        idx = smallest
    end
end

function Scheduler:add_task(id, func, delay, priority, retries, maxExecTime)
    local now = luv.now() / 1000
    if self.task_map[id] then return end -- Prevent duplicate tasks
    
    local task = {
        id = id,
        func = func,
        exec_time = now + (delay or 0),
        priority = priority or 1,
        retries = retries or 3,
        retry_attempts = 0,
        maxExecTime = maxExecTime or 5,
        weight = 1 / (priority + 1)
    }

    table.insert(self.queue, task)
    self.queueSize = self.queueSize + 1
    self.task_map[id] = task
    heapify_up(self.queue, self.queueSize)

    if not self.running then
        self.running = true
        luv.timer_start(self.timer, 10, 10, function() self:run_tasks() end)
    end
end

function Scheduler:extract_min()
    if self.queueSize == 0 then return nil end
    local minTask = self.queue[1]
    self.queue[1] = self.queue[self.queueSize]
    self.queue[self.queueSize] = nil
    self.queueSize = self.queueSize - 1
    heapify_down(self.queue, 1, self.queueSize)
    return minTask
end

function Scheduler:execute_task(task)
    local startTime = luv.now() / 1000
    local success, err = pcall(task.func)
    local execDuration = (luv.now() / 1000) - startTime

    if not success then
        print("[Error] Task failed:", task.id, "-", err)
        task.retry_attempts = task.retry_attempts + 1
        if task.retry_attempts < task.retries then
            self:retry_task(task)
        else
            print("[Fail] Task permanently failed:", task.id)
        end
    elseif execDuration > task.maxExecTime then
        print("[Warning] Task", task.id, "exceeded max execution time!")
    end
end

function Scheduler:retry_task(task)
    task.exec_time = luv.now() / 1000 + math.min(2 ^ task.retry_attempts, 60)
    table.insert(self.queue, task)
    self.queueSize = self.queueSize + 1
    heapify_up(self.queue, self.queueSize)
end

function Scheduler:run_tasks()
    local now = luv.now() / 1000

    while self.queueSize > 0 and self.queue[1].exec_time <= now do
        local task = self:extract_min()
        self.task_map[task.id] = nil

        -- Check dependencies before execution
        if self.dependencies[task.id] then
            local hasPendingDeps = false
            for dep in pairs(self.dependencies[task.id]) do
                if self.task_map[dep] then
                    hasPendingDeps = true
                    break
                end
            end
            if hasPendingDeps then
                self:add_task(task.id, task.func, task.exec_time - now, task.priority, task.retries, task.maxExecTime)
                return
            end
            self.dependencies[task.id] = nil
        end

        self:execute_task(task)
    end

    if self.queueSize == 0 then
        self.running = false
        luv.timer_stop(self.timer)
    end
end

function Scheduler:add_dependency(task_id, dep_id)
    if not self.dependencies[task_id] then self.dependencies[task_id] = {} end
    self.dependencies[task_id][dep_id] = true

    if not self.dependents[dep_id] then self.dependents[dep_id] = {} end
    self.dependents[dep_id][task_id] = true
end

function Scheduler:cancel_task(id)
    if not self.task_map[id] then return end

    self.task_map[id] = nil
    for i, task in ipairs(self.queue) do
        if task.id == id then
            table.remove(self.queue, i)
            self.queueSize = self.queueSize - 1
            heapify_down(self.queue, i, self.queueSize)
            break
        end
    end

    if self.dependencies[id] then self.dependencies[id] = nil end
    if self.dependents[id] then
        for dep in pairs(self.dependents[id]) do
            if self.dependencies[dep] then
                self.dependencies[dep][id] = nil
                if next(self.dependencies[dep]) == nil then
                    self.dependencies[dep] = nil
                end
            end
        end
        self.dependents[id] = nil
    end
end

return Scheduler
