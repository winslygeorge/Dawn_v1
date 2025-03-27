package.path = package.path .. ";../?.lua;../utils/?.lua"

local Scheduler = require("scheduler")  -- Assuming saved as scheduler.lua
local luv = require("luv")


local my_scheduler = Scheduler:new()

my_scheduler:add_task("task1", function() print("Task 1 executed") end, 3, 4)
my_scheduler:add_task("task2", function() print("Task 2 executed") end, 2, 1)

luv.run()  -- Start event loop
