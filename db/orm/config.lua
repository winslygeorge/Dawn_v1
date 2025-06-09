-- orm/config.lua
--- This module holds the global configuration settings for the ORM.
--- Developers can modify these settings to change the ORM's behavior,
--- such as the default connection string and the default execution mode.
local config = {
    --- default_conninfo: The default PostgreSQL connection string.
    --- IMPORTANT: Replace this with your actual PostgreSQL connection details.
    --- Example: "host=localhost port=5432 dbname=mydatabase user=myuser password=mypassword"
    --- @type string
    default_conninfo = "host=localhost port=5432 dbname=game user=game_player password=1234",

    --- default_mode: The default execution mode for database operations.
    --- Can be "sync" for synchronous operations (blocking) or "async" for asynchronous operations.
    --- Note: True "async" mode requires a separate non-blocking PostgreSQL driver (e.g., async_postgres.lua)
    --- and an event loop integration (like uv from luvit).
    --- @type "sync" | "async"
    default_mode = "sync", -- Default to synchronous mode for now

    --- drivers: A table mapping modes to their respective database driver modules.
    --- The ORM will use these drivers to interact with the database based on the selected mode.
    --- @type table<string, table>
    drivers = {
        --- 'sync' driver: Uses the provided sync_postgres.lua module for blocking operations.
        --- @type table
        -- sync = postgres,
        --- 'async' driver: Placeholder for a hypothetical non-blocking driver.
        --- @type table | nil
        -- ["async"] =  async_postgres, -- Uncomment and implement if you have an async driver
    },

    -- Other potential configuration settings can be added here, e.g.,
    -- logging_level = "info",
    -- max_pool_size = 10,
}

return config
