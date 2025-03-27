package.path = package.path .. ";../?.lua;../utils/?.lua"

local luv = require("luv")
local Supervisor = require("loop")

math.randomseed(os.time()) -- Ensure randomness for each run

-- Define a mock child process with a randomized failure simulator
local ChildProcess = {
    name = "Worker1",
    restart_count = 0,
    backoff = 1000,
    restart = function(self)
        self.restart_count = self.restart_count + 1
        print(self.name .. " restarted! (Attempt " .. self.restart_count .. ")")

        -- Simulate different failure modes with probabilities
        local failureChance = math.random(1, 100)

        if failureChance <= 20 then
            print(self.name .. " failed due to a CRASH.")
            return false, "Simulated CRASH"
        elseif failureChance <= 40 then
            print(self.name .. " failed due to a TIMEOUT.")
            return false, "Simulated TIMEOUT"
        elseif failureChance <= 60 then
            print(self.name .. " failed due to RESOURCE EXHAUSTION.")
            return false, "Simulated RESOURCE EXHAUSTION"
        end

        return true  -- Simulate success
    end,
    stop = function(self)
        print(self.name .. " stopped.")
        return true
    end
}

-- Create a supervisor instance
local mySupervisor = Supervisor:new("MainSupervisor")

-- Add a child to the supervisor and track it
table.insert(mySupervisor.children, ChildProcess)
mySupervisor.runningChildren[ChildProcess] = true

-- Simulate restarts
print("Starting Supervisor...")
mySupervisor:restartChild(ChildProcess)

-- Keep the event loop alive
local timer = luv.new_timer()
luv.timer_start(timer, 5000, 5000, function()
    print("Supervisor monitoring...")
end)

-- Run the event loop
luv.run()
