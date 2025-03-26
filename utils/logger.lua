local ffi = require("ffi")
local uv = require("luv")
local cjson = require("cjson.safe")

-- Load system LZ4 library
local lz4 = ffi.load("lz4")

ffi.cdef[[
int getpid();

// LZ4 function definitions
int LZ4_compress_default(const char* src, char* dst, int srcSize, int dstCapacity);
int LZ4_decompress_safe(const char* src, char* dst, int compressedSize, int dstCapacity);
int LZ4_compressBound(int inputSize);
]]

local LOG_FILE = "app.log.lz4"
local MAX_LOG_SIZE = 10 * 1024 * 1024  -- 10MB
local ROTATE_INTERVAL = 3600  -- 1 hour
local BUFFER_FLUSH_INTERVAL = 5  -- Flush every 5 seconds
local MAX_BUFFER_SIZE = 64 * 1024  -- 64KB before flushing
local LOG_LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, FATAL = 5 }
local MIN_LOG_LEVEL = LOG_LEVELS.INFO  -- Change this to filter logs

local Logger = {}
Logger.__index = Logger

function Logger:new()
    local obj = setmetatable({}, self)
    obj.log_fd = nil
    obj.pid = ffi.C.getpid()
    obj.buffer = {}
    obj.buffer_size = 0
    
    -- Open log file
    obj:openLogFile()

    -- Start time-based rotation
    obj.timer = uv.new_timer()
    obj.timer:start(ROTATE_INTERVAL * 1000, ROTATE_INTERVAL * 1000, function() obj:rotateLogFile() end)

    -- Start buffer flushing timer
    obj.flush_timer = uv.new_timer()
    obj.flush_timer:start(BUFFER_FLUSH_INTERVAL * 1000, BUFFER_FLUSH_INTERVAL * 1000, function() obj:flushBuffer() end)

    return obj
end

function Logger:openLogFile()
    self.log_fd = uv.fs_open(LOG_FILE, "a+", 0x1A4)  -- O_APPEND | O_CREAT, mode 0644
    if not self.log_fd then
        error("Failed to open log file: " .. LOG_FILE)
    end
end

function Logger:checkLogSize()
    local stat = uv.fs_stat(LOG_FILE)
    if stat and stat.size >= MAX_LOG_SIZE then
        self:rotateLogFile()
    end
end

function Logger:rotateLogFile()
    -- Close current log file
    if self.log_fd then
        uv.fs_close(self.log_fd)
        self.log_fd = nil
    end

    -- Rename old log file with timestamp
    local timestamp = os.date("%Y%m%d%H%M%S")
    local archive_file = "app.log." .. timestamp .. ".lz4"
    uv.fs_rename(LOG_FILE, archive_file)

    -- Open a new log file
    self:openLogFile()
end

function Logger:log(level, msg, source)
    -- Ignore logs below the minimum level
    if LOG_LEVELS[level] < MIN_LOG_LEVEL then return end

    local entry = {
        timestamp = uv.hrtime(),
        level = level,
        message = msg,
        source = source or "unknown",
        pid = self.pid
    }

    local json_log = cjson.encode(entry) .. "\n"
    table.insert(self.buffer, json_log)
    self.buffer_size = self.buffer_size + #json_log

    -- Flush if buffer reaches the limit
    if self.buffer_size >= MAX_BUFFER_SIZE then
        self:flushBuffer()
    end
end

-- LZ4 Compression Function
function Logger:compress(data)
    local input_size = #data
    local max_output_size = lz4.LZ4_compressBound(input_size)

    -- Allocate memory for compressed output
    local output = ffi.new("char[?]", max_output_size)

    -- Perform compression
    local compressed_size = lz4.LZ4_compress_default(data, output, input_size, max_output_size)
    if compressed_size <= 0 then
        error("LZ4 compression failed")
    end

    return ffi.string(output, compressed_size)
end

function Logger:flushBuffer()
    if #self.buffer == 0 then return end

    local batch_logs = table.concat(self.buffer)
    local compressed_logs = self:compress(batch_logs)

    -- Write compressed logs
    uv.fs_write(self.log_fd, compressed_logs, -1)

    self.buffer = {}
    self.buffer_size = 0

    self:checkLogSize()
end

function Logger:close()
    self:flushBuffer()  -- Ensure all logs are written before closing
    if self.log_fd then
        uv.fs_close(self.log_fd)
        self.log_fd = nil
    end
end

-- Initialize logger
local logger = Logger:new()

logger:log("DEBUG", "Buffered logging initialized.", "System")
logger:log("INFO", "Application started successfully.", "Main")
logger:log("WARN", "Low disk space detected.", "System")
logger:log("ERROR", "Database connection failed.", "DB")
logger:log("FATAL", "Critical failure, shutting down!", "Core")

uv.run()
