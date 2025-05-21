local LinkedList = {}

-- Node structure for a doubly linked list
local Node = {
  value = nil,
  prev = nil,
  next = nil,
}

-- Function to create a new node
local function createNode(value)
  local node = {
    value = value,
    prev = nil,
    next = nil,
  }
  return node
end

-- Function to create a new linked list
function LinkedList.new(circled)
  local list = {
    head = nil,
    tail = nil,
    size = 0,
    circled = circled or false,
  }
  setmetatable(list, { __index = LinkedList })
  return list
end

-- Function to append a node to the end of the list
function LinkedList:append(value)
  if value == nil then return false end; -- nil check
  local newNode = createNode(value)

  if self.head == nil then
    self.head = newNode
    self.tail = newNode
    if self.circled then
      newNode.next = newNode
      newNode.prev = newNode
    end
  else
    newNode.prev = self.tail
    self.tail.next = newNode
    self.tail = newNode
    if self.circled then
      self.tail.next = self.head
      self.head.prev = self.tail
    end
  end

  self.size = self.size + 1
  return true;
end

-- Function to prepend a node to the beginning of the list
function LinkedList:prepend(value)
  if value == nil then return false end; -- nil check
  local newNode = createNode(value)

  if self.head == nil then
    self.head = newNode
    self.tail = newNode
    if self.circled then
      newNode.next = newNode
      newNode.prev = newNode
    end
  else
    newNode.next = self.head
    self.head.prev = newNode
    self.head = newNode
    if self.circled then
      self.tail.next = self.head
      self.head.prev = self.tail
    end
  end

  self.size = self.size + 1
  return true;
end

-- Function to insert a node at a specific index
function LinkedList:insert(value, index)
  if value == nil then return false end; -- nil check
  if index < 0 or index > self.size then
    return false -- Invalid index
  end

  if index == 0 then
    return self:prepend(value)
  elseif index == self.size then
    return self:append(value)
  end

  local newNode = createNode(value)
  local current = self.head
  for i = 1, index - 1 do
    current = current.next
  end

  newNode.next = current.next
  newNode.prev = current
  current.next.prev = newNode
  current.next = newNode

  self.size = self.size + 1
  return true
end

-- Function to remove a node at a specific index
function LinkedList:remove(index)
  if index < 0 or index >= self.size or self.size == 0 then
    return nil -- Invalid index or empty list
  end

  local removedNode = nil

  if index == 0 then
    removedNode = self.head
    if self.size == 1 then
      self.head = nil
      self.tail = nil
    else
      self.head = self.head.next
      self.head.prev = self.circled and self.tail or nil
      if self.circled then
        self.tail.next = self.head
      end
    end
  elseif index == self.size - 1 then
    removedNode = self.tail
    self.tail = self.tail.prev
    if self.tail then
      self.tail.next = self.circled and self.head or nil
    else
      self.head = nil
    end
    if self.circled then
      self.head.prev = self.tail
    end
  else
    local current = self.head
    for i = 1, index - 1 do
      current = current.next
    end

    removedNode = current.next
    current.next = removedNode.next
    current.next.prev = current
  end

  self.size = self.size - 1
  return removedNode and removedNode.value or nil;
end

-- Function to get the value at a specific index
function LinkedList:get(index)
  if index < 0 or index >= self.size then
    return nil -- Invalid index
  end

  local current = self.head
  for i = 1, index do
    current = current.next
  end

  return current.value
end

-- Function to print the linked list
function LinkedList:printList()
  local current = self.head
  if current == nil then
    print("Empty list")
    return
  end

  local str = "List: "
  local count = 0

  repeat
    str = str .. current.value .. " "
    current = current.next
    count = count + 1
  until current == nil or (self.circled and current == self.head)

  print(str)
end

return LinkedList