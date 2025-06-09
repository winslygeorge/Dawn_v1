package.path = package.path .. ";./?.lua;./../?.lua;"
package.cpath = package.cpath .. ";./?.so;./../?.so;./../server/?.so;"

require("bootstrap")
-- app.lua

-- This file demonstrates how to use the LuaJIT ORM to interact with a PostgreSQL database.

-- 1. Require the main ORM module
local ORM = require("orm.init")
local DawnServer = require("dawn_server") -- Assuming dawn_server.lua is in the same directory or accessible via package.path
local DawnModelRouter = require("db.orm.DawnModelRoute") -- Assuming dawn_model_router.lua is in the same directory or accessible via package.path
local Logger = require("utils.logger").Logger
local uv = require("luv") -- Assuming you have the 'uv' library available for async operations
local async = require("utils.promise").async
local await = require("utils.promise").await
local cjson = require("cjson") -- For pretty printing tables
local pgconn = require("db.orm.connection_manager") -- Assuming the provided code is saved as 'async_postgres.lua'
local TestUser = require("db.TestUserModel") -- Assuming you have a model defined for testing
local Users = require("UserModel").User -- Assuming you have a Users model defined
local Profiles = require("UserModel").Profile -- Assuming you have a Profiles model defined
Logger:setLogMode("prod") -- Set the desired log level
local Supervisor = require("runtime.loop") -- Assuming your supervisor is in 'loop.lua'
local app = DawnServer:new({
    port = 3000, -- Set your desired port
    host = "localhost", -- Set your desired host
    logger = Logger:new()})



    DawnModelRouter:new("users", Users, app):initialize() -- Register the TestUser model with the router
    DawnModelRouter:new("profiles", Profiles , app):initialize() -- Register the TestUser model with the router




-- -- In some module that uses ConnectionManager
-- local ConnectionManager = require("orm.connection_manager")
-- local log_level = require('utils.logger').LogLevel -- Assuming you have a logger

-- local supervisor = Supervisor:new("WebServerSupervisor", "one_for_one", Logger:new())

-- ConnectionManager.init(app.supervisor) -- Initialize ConnectionManager with the supervisor instance

-- local my_conn = ConnectionManager.get_connection("async", "host=localhost dbname=game user=game_player password=1234 port=5432")

-- Define a callback to handle the query result
local function my_query_callback(result, err)
    if err then
        print("Query failed:", err)
        -- Log this error with your application's logger, not the supervisor's internal one
        -- app_logger:log(log_level.ERROR, "Application query error: " .. tostring(err))
    else
        print("Query succeeded with result:", require("cjson").encode(result))
        -- Process result
    end
end

-- Execute the async query
-- ConnectionManager.execute_query("async", my_conn, "SELECT * FROM test_users;", my_query_callback)
    app:start()


-- The above call will return immediately. The supervisor will manage the query execution
-- and any retries, eventually invoking my_query_callback.


-- example_usage.lua

-- Require the pg module
-- local pg = require("db.async_postgres") -- Assuming the provided code is saved as 'pg.lua'

-- Define PostgreSQL connection information
-- IMPORTANT: Replace with your actual database credentials and host
-- local CONN_INFO = "host=localhost port=5432 user=game_player password=1234 dbname=game"

-- Main asynchronous function to demonstrate usage

-- local SchemaManager = require("db.orm.schema_manager")
-- local User = require("models.user")

-- SchemaManager.create_table(TestUser)
-- Create a new user


--  TestUser:create({
--     name = "Brian Muthuri",
--     email = "brian@example.com",
--     created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
-- }, function(err, instance)
--     if err then
--         print("Failed to create:", err)
--     else
--         print("Successfully created:", instance)
--     end
-- end)

--  TestUser:create({
--     name = "Dennis Njogu",
--     email = "dennis@example.com",
--     created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
-- }, function(err, instance)
--     if err then
--         print("Failed to create:", err)
--     else
--         print("Successfully created:", instance)
--     end
-- end)


--  TestUser:create({
--     name = "George Mwangi",
--     email = "george@example.com",
--     created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
-- }, function(err, instance)
--     if err then
--         print("Failed to create:", err)
--     else
--         print("Successfully created:", instance)
--     end
-- end)


--  TestUser:create({
--     name = "Nathan Koech",
--     email = "nathan@example.com",
--     created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
-- }, function(err, instance)
--     if err then
--         print("Failed to create:", err)
--     else
--         print("Successfully created:", instance)
--     end
-- end)

--  TestUser:create({
--     name = "john Doe",
--     email = "john@example.com",
--     created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
-- }, function(err, instance)
--     if err then
--         print("Failed to create:", err)
--     else
--         print("Successfully created:", instance)
--     end
-- end)
-- find TestUser by email

-- TestUser:find(2, function(err, instance)
--     if err then
--         print("Failed to find user:", err)
--     else
--         if instance then
--             print("Found user:", cjson.encode(instance))
--         else
--             print("User not found")
--         end
--     end
-- end)

-- TestUser:find_by({
--   email= "dennis@example.com"
-- }, function(err, users)
--     if err then
--         print("Error:", err)
--     else
--         print("Matching users:", require("cjson").encode(users))
--     end
-- end)

-- -- search by orm.Model.paginate
-- TestUser:paginate(1, 3, function(err, users)
--     if err then
--         print("Error:", err)
--     else
--         print("Paginated users:", require("cjson").encode(users))
--     end
-- end)

-- search by orm.Model.paginate_with 
-- TestUser:paginate_with({
--     where = { email = "george@example.com" },  -- Example condition"
--     -- order_by = { "created_at DESC" },  -- Example ordering
--     limit = 3,  -- Example limit
-- }, function(err, users)
--     if err then
--         print("Error:", err)
--     else
--         print("Paginated users with conditions:", require("cjson").encode(users))
--     end
-- end)

-- -- serach by orm.Model.paginate_with_advanced

-- TestUser:paginate_with_advanced{
--     page = 1,
--     use_async = true,
--     on_result = function(result)
--         print("Got async result:", result, require("cjson").encode(result))
--     end
-- }



-- print("New user created with ID:", require("cjson").encode (new_user))

-- Find a user by ID
-- local existing_user = TestUser:find(new_user.id)

-- if existing_user then
--     print("Found user:", existing_user.name, existing_user.email)
-- else
--     print("User not found")
-- end

    require("luv").run() -- Start the event loop for async operations

-- Keep the libuv event loop running until all async operations are done
-- This is crucial for luv-based asynchronous operations to complete.
