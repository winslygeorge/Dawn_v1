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

-- In fibheap.lua
function FibHeap:extract_min()
    print("[FIBHEAP EXTRACT_MIN] Starting. Min:", self.min and self.min.key, "Size:", self.size, "Roots:", #self.roots)
    if not self.min then
        print("[FIBHEAP EXTRACT_MIN] No min, returning nil.")
        return nil
    end
    local minNode = self.min

    -- Log before moving children
    print("[FIBHEAP EXTRACT_MIN] Min Node Key:", minNode.key, "Children:", #minNode.children)

    -- Move children to root list
    for _, child in ipairs(minNode.children) do
        print("[FIBHEAP EXTRACT_MIN] Moving child to root:", child.key)
        table.insert(self.roots, child)
        child.parent = nil
    end

    -- Log before removing min from root list
    print("[FIBHEAP EXTRACT_MIN] Roots before remove:", #self.roots)
    for i = #self.roots, 1, -1 do
        if node == minNode then
            print("[FIBHEAP EXTRACT_MIN] Removing min from roots at index:", i)
            table.remove(self.roots, i)
            break
        end
    end
    print("[FIBHEAP EXTRACT_MIN] Roots after remove:", #self.roots)

    self.nodes[minNode.value.id] = nil
    self.size = self.size - 1

    if #self.roots == 0 then
        self.min = nil
        print("[FIBHEAP EXTRACT_MIN] Roots empty, min is nil.")
    else
        self.min = self.roots[1]
        print("[FIBHEAP EXTRACT_MIN] Roots not empty, new potential min:", self.min.key)
        self:consolidate()
        print("[FIBHEAP EXTRACT_MIN] After consolidate, min:", self.min and self.min.key, "Roots:", #self.roots)
    end

    print("[FIBHEAP EXTRACT_MIN] Returning:", minNode.value)
    return minNode.value
end

function FibHeap:consolidate()
    print("[FIBHEAP CONSOLIDATE] Starting. Roots:", #self.roots)
    local degreeTable = {}
    for _, node in ipairs(self.roots) do
        print("[FIBHEAP CONSOLIDATE] Processing root:", node.key, "Degree:", node.degree)
        while degreeTable[node.degree] do
            local other = degreeTable[node.degree]
            print("[FIBHEAP CONSOLIDATE] Collision at degree:", node.degree, "Other:", other.key)
            if other.key < node.key then
                node, other = other, node
                print("[FIBHEAP CONSOLIDATE] Swapped:", node.key, other.key)
            end
            self:link(other, node)
            degreeTable[node.degree] = nil
            node.degree = node.degree + 1
            print("[FIBHEAP CONSOLIDATE] Linked, new degree:", node.degree)
        end
        degreeTable[node.degree] = node
        print("[FIBHEAP CONSOLIDATE] Stored at degree:", node.degree, "Node:", node.key)
    end

    self.min = nil
    self.roots = {}
    print("[FIBHEAP CONSOLIDATE] Rebuilding roots.")
    for degree, node in pairs(degreeTable) do
        print("[FIBHEAP CONSOLIDATE] Adding to roots:", node.key)
        table.insert(self.roots, node)
        if not self.min or node.key < self.min.key then
            self.min = node
            print("[FIBHEAP CONSOLIDATE] New min:", self.min.key)
        end
    end
    print("[FIBHEAP CONSOLIDATE] Finished. Min:", self.min and self.min.key, "Roots:", #self.roots)
end

function FibHeap:link(child, parent)
    print("[FIBHEAP LINK] Linking child:", child.key, "to parent:", parent.key)
    for i, node in ipairs(self.roots) do
        if node == child then
            print("[FIBHEAP LINK] Removing child from roots at index:", i)
            table.remove(self.roots, i)
            break
        end
    end
    child.parent = parent
    table.insert(parent.children, child)
    child.marked = false
    print("[FIBHEAP LINK] Finished.")
end

-- function FibHeap:link(child, parent)
--     for i, node in ipairs(self.roots) do
--         if node == child then
--             table.remove(self.roots, i)
--             break
--         end
--     end
--     child.parent = parent
--     table.insert(parent.children, child)
--     child.marked = false
-- end

function FibHeap:get_size()
    return self.size
end

return FibHeap
