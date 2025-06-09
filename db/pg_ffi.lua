-- pg_ffi.lua
local ffi = require("ffi")

ffi.cdef[[
typedef struct PGconn PGconn;
typedef struct PGresult PGresult;

PGconn *PQconnectdb(const char *conninfo);
void PQfinish(PGconn *conn);
char *PQerrorMessage(const PGconn *conn);
int PQstatus(const PGconn *conn);

// Define the PostgreSQL connection status types
enum ConnStatusType { CONNECTION_OK, CONNECTION_BAD };

// Define the PostgreSQL execution status types for correct error checking
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

PGresult *PQexec(PGconn *conn, const char *query);
int PQresultStatus(const PGresult *res);
char *PQresultErrorMessage(const PGresult *res);
void PQclear(PGresult *res);

int PQntuples(const PGresult *res);
int PQnfields(const PGresult *res);
char *PQfname(const PGresult *res, int column_number);
char *PQgetvalue(const PGresult *res, int row_number, int column_number);
]]

local libpq = ffi.load("libpq")

return {
    libpq = libpq,
    -- Expose the enums for easy access
    CONNECTION_OK = ffi.C.CONNECTION_OK,
    CONNECTION_BAD = ffi.C.CONNECTION_BAD,
    PGRES_EMPTY_QUERY = ffi.C.PGRES_EMPTY_QUERY,
    PGRES_COMMAND_OK = ffi.C.PGRES_COMMAND_OK,
    PGRES_TUPLES_OK = ffi.C.PGRES_TUPLES_OK,
    PGRES_COPY_OUT = ffi.C.PGRES_COPY_OUT,
    PGRES_COPY_IN = ffi.C.PGRES_COPY_IN,
    PGRES_BAD_RESPONSE = ffi.C.PGRES_BAD_RESPONSE,
    PGRES_NONFATAL_ERROR = ffi.C.PGRES_NONFATAL_ERROR,
    PGRES_FATAL_ERROR = ffi.C.PGRES_FATAL_ERROR,
    PGRES_COPY_BOTH = ffi.C.PGRES_COPY_BOTH,
    PGRES_SINGLE_TUPLE = ffi.C.PGRES_SINGLE_TUPLE,
    PGRES_PIPELINE_SYNC = ffi.C.PGRES_PIPELINE_SYNC,
    PGRES_PIPELINE_ABORTED = ffi.C.PGRES_PIPELINE_ABORTED,
}