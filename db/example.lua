package.path = package.path .. ";./?.lua;./../?.lua;"
package.cpath = package.cpath .. ";./?.so;./../?.so;./../server/?.so;"

require("bootstrap")

-- local User = require("db.UserModel").User
-- local Profile = require("db.UserModel").Profile
-- local SchemaManager = require("db.orm.schema_manager")

-- db_schema_examples.lua

-- Require the SchemaManager and your Model definitions
local SchemaManager = require("orm.schema_manager")
local Model = require("orm.model") -- Assuming your Model base class is here

local user_model = require("models.user").User
local profile_model = require("models.user").Profile


-- Define the User and Profile Models (as discussed in previous turns)
-- Ensure 'profile_id' is present in the User model's fields for the FOREIGN KEY.

-- Profile Model Definition
-- local Profile = Model:extend("profiles", {
--     id = { type = "integer", primary_key = true }, -- Removed default = "SERIAL"
--     bio = "text",
--     phone = "string",
--     created_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
--     updated_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
-- }, {
--     _primary_key = "id",
--     _timestamps = true, -- Enables automatic handling of created_at and updated_at
-- })

-- -- User Model Definition
-- local User = Model:extend("users", {
--     id = { type = "integer", primary_key = true }, -- Removed default = "SERIAL"
--     name = "string",
--     email = { type = "string", unique = true },
--     profile_id = "integer", -- This was correctly added in a previous turn
--     created_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
--     updated_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
-- }, {
--     _primary_key = "id",
--     _foreign_keys = {
--         -- Define the foreign key constraint on the users table
--         { columns = "profile_id", references = "profiles(id)", on_delete = "SET NULL" }
--     },
--     _relations = {
--         -- Define the relationship for eager loading if needed
--         profile = { model_name = "Profile", local_key = "profile_id", foreign_key = "id", join_type = "LEFT" }
--     },
--     _timestamps = true, -- Enables automatic handling of created_at and updated_at
-- })


-- --- EXAMPLE USAGES ---

-- Function to run schema operations
local function run_schema_operations()
    print("--- Starting Schema Operations Examples ---")

    -- 1. Drop tables (optional, useful for clean slate during development)
    print("\n--- Dropping tables (if they exist) ---")
    -- Drop in reverse order of dependency (users depends on profiles)
    -- SchemaManager.drop_table("users")
    -- SchemaManager.drop_table("profiles")
    -- print("Tables dropped (if they existed).")

    -- 2. Create tables
    print("\n--- Creating tables ---")
    SchemaManager.create_table(profile_model)
    SchemaManager.create_table(user_model)
    print("Tables created.")

    -- 3. Apply Migrations
    -- This function will:
    -- - Create tables if they don't exist.
    -- - Apply ALTER TABLE statements if the schema has changed (e.g., new columns, changed types).
    --   Note: The SchemaManager's alter_table_sql is conceptual for complex diffing.
    print("\n--- Applying migrations (will ensure schema is up-to-date) ---")
    -- For demonstration, let's pretend we changed the Profile model later
    -- e.g., Profile.extend("profiles", { ..., new_field = "string" }, ...)
    -- Running apply_migrations will detect and add 'new_field'.

    SchemaManager.apply_migrations(profile_model)
    SchemaManager.apply_migrations(user_model)
    print("Migrations applied.")

    -- You can run apply_migrations multiple times. If no changes are detected,
    -- it will state "No ALTER statements needed."

    print("\n--- Schema Operations Examples Finished ---")
end

-- Execute the example operations
run_schema_operations()
