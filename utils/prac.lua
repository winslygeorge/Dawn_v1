local Set = require("set")
local logger = require('logger').Logger:new()

-- for k, v in pairs(uv) do
--     print(k, type(v))
-- end
-- from_table
local s1 = Set.from_table({ a = 1, b = 2 }, true) -- uses keys
local s2 = Set.from_table({ "a", "b" })          -- uses values

-- clone
local cloned = s1:clone()
print(cloned == s1) --> true

-- each
cloned:each(print)

cloned:to_list()



-- as_json
local json = require("cjson") -- or your preferred lib
print(json.encode(s1:as_json()))
