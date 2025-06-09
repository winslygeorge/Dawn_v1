
-- orm/connection_manager.lua

--- This module acts as an abstraction layer for managing database connections.

--- It provides a unified interface for acquiring and releasing connections,

--- delegating to the appropriate synchronous or asynchronous driver based on the mode.

local config = require("db.orm.config") -- Load ORM configuration

local Promise = require("utils.promise") -- Load Promise utility for async operations

local async = Promise.async

local await = Promise.await



local ConnectionManager = {}



--- Acquires a database connection based on the specified mode and connection info.

-- @param mode string The desired connection mode ("sync" or "async").

-- @param conninfo string (Optional) The connection string to use. Defaults to config.default_conninfo.

-- @return mixed A connection object (for sync) or a future/promise (for async).

-- @raise error If the specified mode is not supported or connection fails.

function ConnectionManager.get_connection(mode, conninfo)

  mode = mode or config.default_mode

  config = config or {} -- Ensure config is loaded
  config.drivers = {
    [mode] = mode == "sync" and require("db.postgres") or require("db.async_postgres")
  }

  conninfo = conninfo or config.default_conninfo



  local driver = config.drivers[mode]

  if not driver then

    error(string.format("Unsupported connection mode: '%s'. Check orm/config.lua drivers.", mode))

  end



  -- Delegate connection acquisition to the specific driver.

  -- For 'sync' mode, this will call sync_postgres.get_connection.

  -- For 'async' mode, this would call a corresponding function on the async driver.

  if mode == "sync" then

    -- Assuming sync_postgres.get_connection directly returns the connection or errors

    return driver.get_connection(conninfo)

  elseif mode == "async" then

    -- For async, driver.connect directly returns the connection object

    return driver.connect(conninfo)

  else

    error(string.format("Unsupported connection mode: '%s'. Check orm/config.lua drivers.", mode))

  end

end



--- Releases a database connection back to its respective driver's pool.

-- @param mode string The mode under which the connection was acquired ("sync" or "async").

-- @param conn mixed The connection object to release.

-- @raise error If the specified mode is not supported.

function ConnectionManager.release_connection(mode, conn)

  mode = mode or config.default_mode

  local driver = config.drivers[mode]

  if not driver then

    error(string.format("Unsupported connection mode: '%s'. Check orm/config.lua drivers.", mode))

  end



  -- Delegate connection release to the specific driver.

  if mode == "async" then

    -- For async, you use pg.close directly

    if(conn) then
      -- Assuming async_postgres.close returns a Promise
      return driver.close(conn)
    else
      error("Invalid connection object for async mode.")
    end

    -- driver.close(conn)

  elseif mode == "sync" then

    -- In sync mode, we assume the connection is released back to a pool.

    -- This is a placeholder; actual implementation may vary based on the driver.
    if(conn ) then
      -- Assuming sync_postgres.release_connection directly releases the connection
      return driver.release_connection(conn)
    else
      error("Invalid connection object for sync mode.")
    end

    -- driver.release_connection(conn)

  else

    error(string.format("Unsupported connection mode: '%s'. Check orm/config.lua drivers.", mode))

  end

end





--- Executes a SQL query using the appropriate driver for the given mode.

-- For async mode, returns a Promise that resolves or rejects.

-- @param mode string The connection mode ("sync" or "async").

-- @param conn mixed The database connection object.

-- @param sql string The SQL query string to execute.

-- @param args table (Optional) Arguments for prepared statements or driver-specific options.

-- @return table|Promise The result in sync mode, or a Promise in async mode.

-- @raise error If the specified mode is not supported or query execution fails.

function ConnectionManager.execute_query(mode, conn, sql, args)

  mode = mode or config.default_mode

  local driver = config.drivers[mode]



  if not driver then

    error(string.format("Unsupported connection mode: '%s'. Check orm/config.lua drivers.", mode))

  end



  if mode == "async" then

    -- Your async_postgres.query_async returns a Promise directly

    return driver.query_async(conn, sql, args)

  elseif mode == "sync" then
    local ok, result_or_err = pcall(function()

      -- Assuming sync_postgres.query handles optional args.

      -- Your async_postgres implementation doesn't use args in query_async.

      -- If sync_postgres.query expects args, keep it as `driver.query(conn, sql, args)`

      -- If it doesn't, or if you need to adjust for nil args, handle it here.

      return driver.query(conn, sql, 1)

    end)

    if ok == true then

      return result_or_err

    end

      error("Sync query failed: " .. tostring(result_or_err))

    -- end

  else

    error("Invalid mode: " .. tostring(mode))

  end

end



return ConnectionManager