local FibHeap = {}

function FibHeap:new()
    local obj = {
        min = nil,
        size = 0,
        roots = {},
        nodes = {}
    }
    setmetatable(obj, { __index = self })
    return obj
end


function FibHeap:insert(key, value)
    local node = {key = key, value = value, degree = 0, marked = false, parent = nil, children = {}}
    table.insert(self.roots, node)
    self.nodes[value.id] = node
    if not self.min or key < self.min.key then
        self.min = node
    end
    self.size = self.size + 1
end

function FibHeap:find_min()
    return self.min and self.min.value or nil
end

function FibHeap:is_empty()
    return self.size == 0
end

function FibHeap:extract_min()
    if not self.min then return nil end
    local minNode = self.min
    
    -- Move children to root list
    for _, child in ipairs(minNode.children) do
        table.insert(self.roots, child)
        child.parent = nil
    end
    
    -- Remove min from root list
    for i, node in ipairs(self.roots) do
        if node == minNode then
            table.remove(self.roots, i)
            break
        end
    end
    
    self.nodes[minNode.value.id] = nil
    self.size = self.size - 1
    
    if #self.roots == 0 then
        self.min = nil
    else
        self.min = self.roots[1]
        self:consolidate()
    end
    
    return minNode.value
end

function FibHeap:consolidate()
    local degreeTable = {}
    for _, node in ipairs(self.roots) do
        while degreeTable[node.degree] do
            local other = degreeTable[node.degree]
            if other.key < node.key then
                node, other = other, node
            end
            self:link(other, node)
            degreeTable[node.degree] = nil
            node.degree = node.degree + 1
        end
        degreeTable[node.degree] = node
    end
    
    -- Rebuild root list and find new min
    self.min = nil
    self.roots = {}
    for _, node in pairs(degreeTable) do
        table.insert(self.roots, node)
        if not self.min or node.key < self.min.key then
            self.min = node
        end
    end
end

function FibHeap:link(child, parent)
    for i, node in ipairs(self.roots) do
        if node == child then
            table.remove(self.roots, i)
            break
        end
    end
    child.parent = parent
    table.insert(parent.children, child)
    child.marked = false
end

function FibHeap:get_size()
    return self.size
end

return FibHeap
