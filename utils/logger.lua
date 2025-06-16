local ffi = require("ffi")
local uv = require("luv")
local cjson = require("dkjson")

ffi.cdef[[
    int getpid();
]]

local ENV = os.getenv("ENV") or "development"
local is_dev = ENV == "development"

local LOG_FILE = "app.log"
local MAX_LOG_SIZE = 10 * 1024 * 1024 -- 10MB
local MAX_QUEUE_SIZE = 10000
local AUTO_FLUSH_INTERVAL = 5000 -- Auto-flush every 5 seconds (5000 ms)

-- LogLevel Enum-like Table
local LogLevel = {
    DEBUG = 1,
    INFO  = 2,
    WARN  = 3,
    ERROR = 4,
    FATAL = 5
}

-- Reverse mapping for level -> name
local levelNames = {
    [1] = "DEBUG",
    [2] = "INFO",
    [3] = "WARN",
    [4] = "ERROR",
    [5] = "FATAL"
}

-- Adds a method to convert level number to string
function LogLevel.toString(level)
    return levelNames[level] or "UNKNOWN"
end


local COLORS = {
    DEBUG = "\27[38;5;244m",
    INFO  = "\27[38;5;34m",
    WARN  = "\27[38;5;214m",
    ERROR = "\27[38;5;196m",
    FATAL = "\27[48;5;88;38;5;231m",
    RESET = "\27[0m"
}

local ICONS = {
    DEBUG = "🐞",
    INFO  = "ℹ️ ",
    WARN  = "⚠️ ",
    ERROR = "❌",
    FATAL = "💀"
}

local Logger = {}
Logger.__index = Logger

function Logger:new()
    local obj = setmetatable({}, self)
    obj.pid = ffi.C.getpid()
    obj.thread_id = uv.hrtime()
    obj.log_fd = nil
    obj.log_queue = {}
    obj.log_worker_active = false
    obj.shutdown_signal = false
    obj.log_mode = "dev"
    obj.min_level = LogLevel.INFO
    obj.last_request_id = nil

    obj.log_async = uv.new_async(function()
        obj:processLogQueue()
    end)

    obj.auto_flush_timer = uv.new_timer()
    obj:openLogFile()
    obj:startAutoFlush()
    return obj
end

function Logger:setLogMode(mode)
    self.log_mode = mode or "dev"
end

function Logger:openLogFile()
    local fd, err = uv.fs_open(LOG_FILE, "a+", 420)
    if not fd then
        print("[Logger] Failed to open log file:", uv.strerror(err))
        return
    end
    self.log_fd = fd
    print("[Logger] Log file opened.")
end

function Logger:log(level, msg, source, request_id)
    if level < self.min_level then return end

    local level_name = LogLevel.toString(level)
    source = source or "unknown"

    local entry = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        level = level_name,
        message = msg,
        source = source,
        pid = self.pid,
        thread_id = self.thread_id,
        request_id = request_id or "N/A",
        memory_usage = collectgarbage("count")
    }

    local json_log, json_err = cjson.encode(entry)
    if not json_log then
        print("[Logger] JSON encode failed:", json_err)
        return
    end

    table.insert(self.log_queue, json_log .. "\n")

    if self.log_mode == "dev" then
        local color = COLORS[level_name] or ""
        local icon = ICONS[level_name] or ""
        print(string.format("%s[%s] [%s] %s %s%s", color, entry.timestamp, level_name, icon, msg, COLORS.RESET))
    end

    if #self.log_queue >= MAX_QUEUE_SIZE then
        self:flushBuffer()
    elseif #self.log_queue >= 10 then
        self:flushBuffer()
    end

    if not self.log_worker_active then
        self.log_worker_active = true
        self.log_async:send()
    end
end

function Logger:processLogQueue()
    if self.shutdown_signal or #self.log_queue == 0 then
        self.log_worker_active = false
        return
    end

    local batch_logs = table.concat(self.log_queue)
    self.log_queue = {}

    if self.log_fd then
        uv.fs_write(self.log_fd, batch_logs, -1, function(write_err)
            if write_err then
                print("[Logger] Log write failed:", uv.strerror(write_err))
            end
        end)
    else
        print("[Logger] Log file descriptor is nil, cannot write logs.")
    end
end

function Logger:flushBuffer()
    if #self.log_queue == 0 or not self.log_fd then return end

    local batch_logs = table.concat(self.log_queue)
    self.log_queue = {}

    uv.fs_write(self.log_fd, batch_logs, -1, function(err)
        if err then
            print("[Logger] Final log flush failed:", uv.strerror(err))
        end
    end)
end

function Logger:startAutoFlush()
    self.auto_flush_timer:start(AUTO_FLUSH_INTERVAL, AUTO_FLUSH_INTERVAL, function()
        self:flushBuffer()
    end)
end

function Logger:shutdown()
    self.shutdown_signal = true
    self:flushBuffer()

    if self.log_fd then
        local fd = self.log_fd
        self.log_fd = nil
        uv.fs_close(fd, function()
            print("[Logger] Shutdown complete. Logs flushed.")
        end)
    end

    if self.auto_flush_timer then
        self.auto_flush_timer:stop()
        self.auto_flush_timer:close()
        self.auto_flush_timer = nil
    end
end

return {
    Logger = Logger,
    LogLevel = LogLevel
}