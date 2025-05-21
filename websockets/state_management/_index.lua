
local tarantool_state_management = require('websockets/state_management/redis_state_management')
local state_management_index = {
    -- ["__active__"] =  tarantool_state_management,
    ["__default__"] = require('websockets/state_management/in_memory_state_management')
}

return state_management_index