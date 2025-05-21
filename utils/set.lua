---@class Set<K>
local Set = {}
Set.__index = Set

Set.__add = function(a, b) return Set.union(a, b) end
Set.__mul = function(a, b) return Set.intersection(a, b) end
Set.__sub = function(a, b) return Set.difference(a, b) end
Set.__eq = function(a, b)
  for k in pairs(a._data) do if not b._data[k] then return false end end
  for k in pairs(b._data) do if not a._data[k] then return false end end
  return true
end

---@generic K
---@param list? K[]
---@param opts? {immutable?: boolean, weak?: boolean}
---@return Set<K>
function Set:new(list, opts)
  local self = setmetatable({}, Set)
  opts = opts or {
    immutable = false,
    weak = false,
  }
  local data = opts.weak and setmetatable({}, { __mode = "k" }) or {}
  if list then for _, v in ipairs(list) do data[v] = true end end
  self._data = data
  self._immutable = opts.immutable or false
  return self
end

---@generic K
---@param tbl table
---@param use_keys? boolean
---@return Set<K>
function Set:from_table(tbl, use_keys)
  local list = {}
  if use_keys then
    for k in pairs(tbl) do table.insert(list, k) end
  else
    for _, v in pairs(tbl) do table.insert(list, v) end
  end
  return Set:new(list)
end

---@generic K
---@param self Set<K>
---@param value K
---@return boolean
function Set:has(value)
  return self._data[value] == true
end

---@generic K
---@param self Set<K>
---@param value K
function Set:add(value)
  if self._immutable then
    print("Attempting to add value to immutable set: " .. self:serialize())
    error("Cannot modify immutable set") 
    end
  self._data[value] = true
  print("Added value to set: " .. self:serialize())
end

---@generic K
---@param self Set<K>
---@param value K
function Set:remove(value)
  if self._immutable then error("Cannot modify immutable set") end
  self._data[value] = nil
end

---@generic K
---@param self Set<K>
---@return Set<K>
function Set:clone()
  local new_set = Set.new()
  for k in pairs(self._data) do new_set._data[k] = true end
  return new_set
end

---@generic K
---@param self Set<K>
---@param fn fun(value: K)
function Set:each(fn)
  for k in pairs(self._data) do fn(k) end
end

---@generic K
---@param a Set<K>
---@param b Set<K>
---@return Set<K>
function Set.union(a, b)
  local result = Set.new()
  for k in pairs(a._data) do result._data[k] = true end
  for k in pairs(b._data) do result._data[k] = true end
  return result
end

---@generic K
---@param a Set<K>
---@param b Set<K>
---@return Set<K>
function Set.intersection(a, b)
  local result = Set.new()
  for k in pairs(a._data) do if b._data[k] then result._data[k] = true end end
  return result
end

---@generic K
---@param a Set<K>
---@param b Set<K>
---@return Set<K>
function Set.difference(a, b)
  local result = Set.new()
  for k in pairs(a._data) do if not b._data[k] then result._data[k] = true end end
  return result
end

---@generic K
---@param self Set<K>
---@return K[]
function Set:to_list()
  local list = {}
  for k in pairs(self._data) do table.insert(list, k) end
  return list
end

---@generic K
---@param self Set<K>
---@return number
function Set:size()
  local n = 0
  for _ in pairs(self._data) do n = n + 1 end
  return n
end

---@generic K
---@param self Set<K>
---@return boolean
function Set:is_empty()
  return next(self._data) == nil
end

---@generic K, V
---@param self Set<K>
---@param fn fun(value: K): V
---@return Set<V>
function Set:map(fn)
  if self:is_empty() then return Set:new() end
  local result = Set:new()
  for k in pairs(self._data) do
    local mapped_value = fn(k)
    if not result:has(mapped_value) then
      result._data[mapped_value] = true
    end
  end
  return result
  -- for k in pairs(self._data) do
  --   print("Mapping value: " .. tostring(k))
  --   result._data[fn(k)] = true
  -- end
  -- return result
end

---@generic K
---@param self Set<K>
---@param fn fun(value: K): boolean
---@return Set<K>
function Set:filter(fn)
  local result = Set.new()
  for k in pairs(self._data) do
    if fn(k) then result._data[k] = true end
  end
  return result
end

---@generic K
---@param self Set<K>
---@return string
function Set:serialize()
  local values = self:to_list()
  table.sort(values, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local str = {}
  for _, v in ipairs(values) do table.insert(str, tostring(v)) end
  return "{" .. table.concat(str, ", ") .. "}"
end

---@generic K
---@param self Set<K>
---@return any[]
function Set:as_json()
  return self:to_list()
end

---@param self Set<any>
---@return string
function Set:__tostring()
  return self:serialize()
end

return Set
