local Model = require("db.orm.model")
local ConnectionManager = require("orm.connection_manager")
local config = require("orm.config")
local cjson = require("cjson.safe") -- Required for printing table contents

--- IMPORTANT: Initialize your database connection before using models.
--- This typically happens once in your application's startup file (e.g., 'main.lua').
--- Example (uncomment and adjust as per your setup):
-- ConnectionManager.setup_connection({
--  driver = "sqlite3",
--  database = "./my_app.db"
-- }, "sync")
-- config.default_mode = "sync" -- Set your default connection mode

---
--- Profile Model Definition
--- Represents the 'profiles' table in your database. This is a one-to-one relation with User.
---
local Profile = Model:extend(
    "profiles", -- Table name
    {
        id = { type = "integer", primary_key = true }, -- 'default = "SERIAL"' handled by DB, not schema
        bio = "text",
        phone = "string",
        created_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
        updated_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
    },
    {
        _primary_key = "id",
        _timestamps = true, -- Automatically manage created_at and updated_at
        _include_relations = true, -- Enables eager loading of related models (though Profile might not have direct outgoing relations)
        _connection_mode = "sync",
        _indexes = {},
        _unique_keys = { { } },
    }
)

---
--- User Model Definition
--- Represents the 'users' table with a foreign key to 'profiles'.
--- This model demonstrates a 'has-one' / 'belongs-to' relationship with Profile.
---
local User = Model:extend(
    "users", -- Table name
    {
        id = { type = "integer", primary_key = true }, -- 'default = "SERIAL"' handled by DB, not schema
        name = "string",
        email = { type = "string", unique = true },
        profile_id = { type = "integer", references = "profiles(id)", on_delete = "SET NULL" }, -- Foreign key with ON DELETE action
        created_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
        updated_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
    },
    {
        _primary_key = "id",
        _timestamps = true,
        _connection_mode = "sync",
        -- Define explicit relationships for eager loading
        _relations = {
            -- 'profile' is the name this relation will be accessed by on a User instance
            profile = { 
                model_name = "Profile", -- The name of the related model class (as found in db.init_models)
                local_key = "profile_id", -- The foreign key on *this* (User) table
                foreign_key = "id", -- The primary key on the *related* (Profile) table
                join_type = "LEFT" -- Type of SQL join to use (e.g., INNER, LEFT)
            }
        }
    }
)

--- IMPORTANT: For eager loading (_relations) to work, your application needs a way to map
--- relation_name (e.g., "Profile") to the actual Lua model object. 
--- A common pattern is to have a central module (e.g., 'db.init_models') that exposes your models.
--- For this example to run, ensure 'db.init_models' exists and returns a table like:
local M = {}
M.User = User
M.Profile = Profile
return M