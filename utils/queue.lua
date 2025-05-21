-- utils/queue.lua

local Queue = {}
Queue.__index = Queue

function Queue:new()
    local self = setmetatable({}, Queue)
    self.items = {}
    self.head = 1
    self.tail = 1
    return self
end

function Queue:enqueue(item)
    self.items[self.tail] = item
    self.tail = self.tail + 1
end

function Queue:dequeue()
    if self.head == self.tail then
        return nil
    end
    local item = self.items[self.head]
    self.items[self.head] = nil -- Allow for garbage collection
    self.head = self.head + 1
    return item
end

function Queue:peek()
    if self:is_empty() then
        return nil
    end
    return self.items[self.head]
end

function Queue:is_empty()
    return self.head == self.tail
end

function Queue:size()
    return self.tail - self.head
end

return Queue