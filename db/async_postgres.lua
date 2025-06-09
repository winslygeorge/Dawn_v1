local ffi = require("ffi")
local uv = require("luv")

ffi.cdef[[
typedef struct PGconn PGconn;
typedef struct PGresult PGresult;

PGconn *PQconnectdb(const char *conninfo);
void PQfinish(PGconn *conn);
char *PQerrorMessage(const PGconn *conn);
int PQstatus(const PGconn *conn);
enum ConnStatusType { CONNECTION_OK, CONNECTION_BAD };

int PQsendQuery(PGconn *conn, const char *query);
int PQconsumeInput(PGconn *conn);
int PQisBusy(PGconn *conn);
PGresult *PQgetResult(PGconn *conn);

int PQresultStatus(const PGresult *res);
char *PQresultErrorMessage(const PGresult *res);
void PQclear(PGresult *res);

int PQntuples(const PGresult *res);
int PQnfields(const PGresult *res);
char *PQfname(const PGresult *res, int column_number);
char *PQgetvalue(const PGresult *res, int row_number, int column_number);

int PQsocket(const PGconn *conn);

enum ExecStatusType {
    PGRES_EMPTY_QUERY = 0,
    PGRES_COMMAND_OK = 1,
    PGRES_TUPLES_OK = 2,
    PGRES_COPY_OUT = 3,
    PGRES_COPY_IN = 4,
    PGRES_BAD_RESPONSE = 5,
    PGRES_NONFATAL_ERROR = 6,
    PGRES_FATAL_ERROR = 7,
    PGRES_COPY_BOTH = 8,
    PGRES_SINGLE_TUPLE = 9,
    PGRES_PIPELINE_SYNC = 10,
    PGRES_PIPELINE_ABORTED = 11
};
]]

-- Load the libpq C library
local libpq = ffi.load("libpq")
local pg = {}
-- Initialize metrics for tracking query performance and failures
local metrics = { queries = 0, failures = 0, total_time = 0 }

-- Simple logging function
local function log(msg)
    print("[pg/async] " .. msg)
end
--- Connects to a PostgreSQL database.
-- @param conninfo A connection string (e.g., "host=localhost port=5432 user=dbuser password=dbpass dbname=mydb")
-- @return PGconn* A pointer to the connection object.
-- @raise error If connection fails.
function pg.connect(conninfo)
    local conn = libpq.PQconnectdb(conninfo)
    -- Check if connection was successful and status is OK
    if not conn or libpq.PQstatus(conn) ~= ffi.C.CONNECTION_OK then
        local err_msg = "Unknown connection error"
        if conn then
            err_msg = ffi.string(libpq.PQerrorMessage(conn))
            libpq.PQfinish(conn) -- Clean up the bad connection handle
        end
        error("Failed to connect to PostgreSQL: " .. err_msg)
    end
    log("Successfully connected to PostgreSQL.")
    return conn
end

-- --- Closes a PostgreSQL connection.
-- -- @param conn The PGconn* connection object to close.
-- function pg.close(conn)
--     if conn then
--         print("Closing connection with socket:", libpq.PQsocket(conn))
--         libpq.PQfinish(conn)
--         log("PostgreSQL connection closed.")
--     end
-- end

local CONNECTION_OK = libpq.CONNECTION_OK -- Make sure this is defined via FFI

--- Closes a PostgreSQL connection if it's active.
-- @param conn The PGconn* connection object to close.
function pg.close(conn)
    if conn then
        local status = libpq.PQstatus(conn)
        local socket = libpq.PQsocket(conn)
        print("Closing connection with socket:", socket, " status ok : ",  CONNECTION_OK, " status: ", status)

        if status == CONNECTION_OK  then
            libpq.PQfinish(conn)
        else
            -- Still attempt to finish just in case, even if status isn't OK
            -- libpq.PQfinish(conn)
        end
        log("PostgreSQL connection closed.")
    end
end



--- Executes an SQL query asynchronously.
-- This function uses libuv (via luv) to poll the PostgreSQL socket for readiness,
-- allowing non-blocking database operations. It includes retry logic for transient errors.
-- @param conn The PGconn* connection object.
-- @param sql The SQL query string to execute.
-- @param cb The callback function to call when the query completes.
--           It will be called as cb(err, data), where err is an error string (or nil on success)
--           and data is a table of rows (or nil on error).
-- @param retry_count (optional) Internal counter for retries, defaults to 0.
function pg.query_async(conn, sql, cb, retry_count)
    retry_count = retry_count or 0
    local start_time = uv.now() -- Record start time for metrics

    -- Check connection status before sending the query
    if libpq.PQstatus(conn) ~= ffi.C.CONNECTION_OK then
        local err = ffi.string(libpq.PQerrorMessage(conn))
        metrics.failures = metrics.failures + 1
        return cb("Connection is bad before sending query: " .. err)
    end

    -- Send the query to the PostgreSQL server
    if libpq.PQsendQuery(conn, sql) == 0 then
        local err = ffi.string(libpq.PQerrorMessage(conn))
        metrics.failures = metrics.failures + 1
        return cb("PQsendQuery failed: " .. err)
    end

    -- Get the socket file descriptor for polling
    local sock_fd = libpq.PQsocket(conn)
    if sock_fd < 0 then
        local err = ffi.string(libpq.PQerrorMessage(conn))
        metrics.failures = metrics.failures + 1
        return cb("Failed to get socket descriptor for polling: " .. err)
    end

    print("Socket fd: ", sock_fd)

    local poll, err_code = uv.new_poll(sock_fd) -- Correctly capture the error code from uv.new_poll

if not poll then
    -- local err_code = uv.last_error() -- This may not return a code or be deprecated
    -- local error_description =  tostring(err_code)
    metrics.failures = metrics.failures + 1
    return cb(string.format("Failed to create poll handle for socket %d: (libuv error), poll error_code : %s", sock_fd, err_code))
end


    -- Helper function to ensure poll handle is closed and callback is called
    local function cleanup_and_callback(err, data)
        --  uv.stop()-- Stop polling before calling the callback
        if poll then
            poll:stop() -- Stop polling
            poll:close() -- Close the poll handle
            poll = nil -- Nullify to prevent double-closing
        end
        cb(err, data) -- Invoke the user's callback
    end

    -- Function to check if the query result is ready
    local function check_ready()
        -- Guard against poll being nil if cleanup_and_callback was already called
        if not poll then return end

        -- Consume input from the socket
        if libpq.PQconsumeInput(conn) == 0 then
            local err = ffi.string(libpq.PQerrorMessage(conn))
            metrics.failures = metrics.failures + 1
            return cleanup_and_callback("PQconsumeInput error: " .. err)
        end

        -- Check if the connection is still busy (waiting for more data)
        if libpq.PQisBusy(conn) == 1 then
            return -- Still busy, continue polling
        end

        local all_rows = {}
        local query_successful = true
        local final_error_message = nil

        -- Retrieve all results from the query (a single PQsendQuery can yield multiple results)
        while true do
            local res = libpq.PQgetResult(conn)
            if res == nil then break end -- No more results available

            local status = libpq.PQresultStatus(res)
            log("Received result with status: " .. status)

            -- Check for error statuses
            if status ~= ffi.C.PGRES_TUPLES_OK and status ~= ffi.C.PGRES_COMMAND_OK then
                query_successful = false
                final_error_message = ffi.string(libpq.PQresultErrorMessage(res))
                libpq.PQclear(res) -- Clear the result handle
                break -- Stop processing results on the first error
            end

            -- If tuples (rows) are returned, process them
            if status == ffi.C.PGRES_TUPLES_OK then
                local nrows, ncols = libpq.PQntuples(res), libpq.PQnfields(res)
                for i = 0, nrows - 1 do -- Iterate through rows
                    local row = {}
                    for j = 0, ncols - 1 do -- Iterate through columns
                        local name = ffi.string(libpq.PQfname(res, j)) -- Get column name
                        local c_value = libpq.PQgetvalue(res, i, j) -- Get raw C string value

                        -- Handle NULL values: PQgetvalue returns a NULL pointer for SQL NULL
                        local value = ffi.cast("char*", c_value) ~= nil and ffi.string(c_value) or nil
                        row[name] = value
                    end
                    table.insert(all_rows, row) -- Add the row to the results table
                end
            end

            libpq.PQclear(res) -- Clear the result handle after processing
        end

        -- Handle query success or failure
        if not query_successful then
            metrics.failures = metrics.failures + 1
            -- Implement retry logic for transient errors
            if retry_count < 3 then -- Max 3 retries
                local delay = 200 * (2 ^ retry_count) -- Exponential backoff
                log("Query failed: " .. final_error_message .. ". Retrying in " .. delay .. "ms (attempt " .. (retry_count + 1) .. ")")
                local timer = uv.new_timer() -- Create a new timer handle
                uv.timer_start(timer, delay, 0, function()
                    timer:close() -- Close the timer handle after it fires
                    pg.query_async(conn, sql, cb, retry_count + 1) -- Retry the query
                end)
            else
                log("Max retries reached for query: " .. sql)
                cleanup_and_callback("Postgres query error after " .. (retry_count + 1) .. " attempts: " .. final_error_message)
            end
        else
            metrics.queries = metrics.queries + 1
            metrics.total_time = metrics.total_time + (uv.now() - start_time) -- Update total time
            log("Query successful. Rows returned: " .. #all_rows)
            -- print("rows: ", #all_rows, require('cjson').encode(all_rows)) -- Uncomment if 'cjson' is available and desired for debugging
            log(string.format("Metrics: %d queries, %d failures, avg %.2f ms",
                metrics.queries, metrics.failures, metrics.total_time / metrics.queries))

            cleanup_and_callback(nil, all_rows) -- Call callback with success and data
        end
    end

poll:start("rw", function(status, events)

    -- if type(status) ~= "number" then
    --     metrics.failures = metrics.failures + 1
    --     return cleanup_and_callback("Poll error: status is not a number (" .. tostring(status) .. ")")
    -- end
    -- if status ~= 0 then
    --     metrics.failures = metrics.failures + 1
    --     return cleanup_and_callback("Poll error: status=" .. tostring(status))
    -- end
    check_ready()
end)


end

--- Logs current performance metrics.
function pg.log_metrics()
    local avg = metrics.queries > 0 and (metrics.total_time / metrics.queries) or 0
    print(string.format("[pg] %d queries, %d failures, avg %.2f ms",
        metrics.queries, metrics.failures, avg))
end

pg.metrics = metrics -- Expose metrics table
return pg
