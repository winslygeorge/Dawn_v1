-- sync_postgres.lua
local ffi = require("ffi") -- Keep ffi to use ffi.string, ffi.C, etc.
local uv = require("luv") -- Assuming you have luvit or similar for async I/O
local os_clock = os.clock

-- Require the dedicated FFI module to get libpq and the enums
local pg_ffi = require("db.pg_ffi")
local libpq = pg_ffi.libpq

-- Assign common enums to local variables for convenience
local CONNECTION_OK = pg_ffi.CONNECTION_OK
local PGRES_COMMAND_OK = pg_ffi.PGRES_COMMAND_OK
local PGRES_TUPLES_OK = pg_ffi.PGRES_TUPLES_OK
local PGRES_FATAL_ERROR = pg_ffi.PGRES_FATAL_ERROR -- Potentially useful for specific error checks

local pg = {}
local pool = {
    max = 10,
    connections = {},
    in_use = {},
    statement_cache = setmetatable({}, { __mode = "k" }),
    idle_times = {},
}
local IDLE_TIMEOUT = 60
local MAX_RETRIES = 3
local BACKOFF_BASE = 0.2
local metrics = { queries = 0, failures = 0, total_time = 0 }

local function log(msg)
    print("[pg] " .. msg)
end

local function log_metrics()
    print(string.format("[pg] Metrics: %d queries, %d failures, avg time %.2fms",
        metrics.queries, metrics.failures,
        metrics.queries > 0 and (metrics.total_time / metrics.queries * 1000) or 0))
end

function pg.connect(conninfo)
    local conn = libpq.PQconnectdb(conninfo)
    if libpq.PQstatus(conn) ~= CONNECTION_OK then -- Use the exported enum
        error(ffi.string(libpq.PQerrorMessage(conn)))
    end
    return conn
end

function pg.get_connection(conninfo)
    for i, conn in ipairs(pool.connections) do
        table.remove(pool.connections, i)
        pool.in_use[conn] = { conninfo = conninfo, last_used = os.time() }
        return conn
    end
    log("Creating new connection")
    local conn = pg.connect(conninfo)
    pool.in_use[conn] = { conninfo = conninfo, last_used = os.time() }
    return conn
end
function pg.check_idle_connections()
    local now = os.time()
    for conn, info in pairs(pool.in_use) do
        if now - info.last_used > IDLE_TIMEOUT then
            log("Closing idle connection")
            libpq.PQfinish(conn)
            pool.in_use[conn] = nil
            pool.statement_cache[conn] = nil
        end
    end
end


function pg.release_connection(conn)
    if libpq.PQstatus(conn) == CONNECTION_OK then
        if #pool.connections < pool.max then
            pool.in_use[conn] = nil
            table.insert(pool.connections, conn)
        else
            libpq.PQfinish(conn)
            pool.statement_cache[conn] = nil
        end
    else
        -- If connection is already bad, always close and clean it up
        libpq.PQfinish(conn)
        pool.in_use[conn] = nil
        pool.statement_cache[conn] = nil
    end
end

function pg.query(conn, sql, retry_count)
    retry_count = retry_count or 0
    local start_time = os_clock()
    local res = libpq.PQexec(conn, sql)

    -- Check if the query was successful (either command executed or tuples returned)
    local status = libpq.PQresultStatus(res)
    if res == nil or (status ~= PGRES_COMMAND_OK and status ~= PGRES_TUPLES_OK) then -- Use exported enums
        local err = res and ffi.string(libpq.PQresultErrorMessage(res)) or "nil result or unknown error"
        if res then libpq.PQclear(res) end -- Always clear result even on error if it exists
        metrics.failures = metrics.failures + 1
        if retry_count < MAX_RETRIES then
            local backoff = BACKOFF_BASE * (2 ^ retry_count)
            log("Retrying after backoff " .. backoff .. "s. Error: " .. err)
            -- Ensure uv.sleep is available or mocked in your environment
            if uv and uv.sleep then
                uv.sleep(backoff * 1000)
            else
                -- Fallback blocking sleep if uv is not present, for demonstration
                local start = os.clock()
                while os.clock() - start < backoff do end
            end
            return pg.query(conn, sql, retry_count + 1)
        end
        error("Postgres query error: " .. err)
    end

    local rows = {}
    -- Only attempt to read tuples if the status is PGRES_TUPLES_OK
    if status == PGRES_TUPLES_OK then -- Use exported enum
        local nrows, ncols = libpq.PQntuples(res), libpq.PQnfields(res)
        for i = 0, nrows - 1 do
            local row = {}
            for j = 0, ncols - 1 do
                local name = ffi.string(libpq.PQfname(res, j))
                local value = ffi.string(libpq.PQgetvalue(res, i, j))
                row[name] = value
            end
            table.insert(rows, row)
        end
    end

    libpq.PQclear(res)
    local duration = os_clock() - start_time
    metrics.queries = metrics.queries + 1
    metrics.total_time = metrics.total_time + duration
    return rows
end

function pg.prepare(conn, name, sql)
    if not pool.statement_cache[conn] then pool.statement_cache[conn] = {} end
    -- We no longer need to check if it's in cache here, as PQexec will handle "already exists" without retries.
    local prep = string.format("PREPARE %s AS %s", name, sql)
    pg.query(conn, prep) -- This call already has retry logic
    pool.statement_cache[conn][name] = true -- Cache it after successful preparation
end

function pg.query_prepared(conn, name, args)
    local formatted_args = {}
    for _, v in ipairs(args) do
        if type(v) == "number" then
            table.insert(formatted_args, tostring(v))
        else
            -- Basic escaping for single quotes
            table.insert(formatted_args, string.format("'%s'", tostring(v):gsub("'", "''")))
        end
    end
    local sql = string.format("EXECUTE %s (%s)", name, table.concat(formatted_args, ", "))
    return pg.query(conn, sql)
end

function pg.close(conn)
    libpq.PQfinish(conn)
end

pg.log_metrics = log_metrics
pg.metrics = metrics

return pg