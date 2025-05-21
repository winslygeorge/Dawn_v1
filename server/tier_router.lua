local RouteTrie = {}
RouteTrie.__index = RouteTrie

function RouteTrie:new()
  return setmetatable({ root = {} }, RouteTrie)
end

function RouteTrie:insert(path, handler)
  local node = self.root
  for part in path:gmatch("[^/]+") do
    if part:sub(1, 1) == ":" then
      node.param = node.param or {}
      node = node.param
    elseif part == "*" then
      node.splat = node.splat or {}
      node = node.splat
    else
      node[part] = node[part] or {}
      node = node[part]
    end
  end
  node.handler = handler
end

function RouteTrie:match(path)
  local node = self.root
  local params = {}
  for part in path:gmatch("[^/]+") do
    if node[part] then
      node = node[part]
    elseif node.param then
      local paramKey = nil
      for k in pairs(node.param) do paramKey = k break end
      params[paramKey or "param"] = part
      node = node.param
    elseif node.splat then
      params.splat = table.concat({part}, "/")
      node = node.splat
      break
    else
      return nil
    end
  end
  return node.handler, params
end

return RouteTrie
