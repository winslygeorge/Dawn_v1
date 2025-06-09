local Model = require("orm.model")

-- Define the TestUser model
local TestUser = Model:extend("test_users", {
    id = "integer",
    name = "string",
    email = "string",
    created_at = "timestamp",
    updated_at = "timestamp",
    deleted_at  = "timestamp" -- optional, for soft deletes
}, {
    _connection_mode = "sync",  -- Use async connection mode
    _connection_info = "host=localhost port=5432 user=game_player password=1234 dbname=game",  -- Replace with your actual connection info
    _table_name = "test_users",
    _primary_key = "id",
    _indexes = { "email" },
    _unique_keys = { { "email" } },
})

return TestUser
