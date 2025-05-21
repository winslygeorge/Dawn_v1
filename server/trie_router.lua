local TrieRouter = {}
TrieRouter.__index = TrieRouter

function TrieRouter:new()
    return setmetatable({ root = {} }, TrieRouter)
end

function TrieRouter:add(method, path, handler)
    local node = self.root
    method = method:upper()
    node[method] = node[method] or {}
    node = node[method]

    for segment in path:gmatch("[^/]+") do
        local key = segment:match("^:(.+)$") and ":param" or segment
        node.children = node.children or {}
        node.children[key] = node.children[key] or {}
        node = node.children[key]
    end

    node.handler = handler
    node.original_path = path
end

function TrieRouter:match(method, path)
    local node = self.root[method:upper()]
    if not node then return nil end

    local params = {}
    for segment in path:gmatch("[^/]+") do
        node.children = node.children or {}

        if node.children[segment] then
            node = node.children[segment]
        elseif node.children[":param"] then
            node = node.children[":param"]
            table.insert(params, segment)
        else
            return nil
        end
    end

    if node and node.handler then
        return node.handler, params, node.original_path
    end
end

return TrieRouter
