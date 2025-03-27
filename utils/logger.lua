local ffi = require("ffi")
local uv = require("luv")
local cjson = require("cjson.safe")

ffi.cdef[[
    int getpid();
]]

local LOG_FILE = "app.log"
local MAX_LOG_SIZE = tonumber(os.getenv("MAX_LOG_SIZE") or "10485760") -- 10MB
local BUFFER_FLUSH_INTERVAL = 5
local MAX_QUEUE_SIZE = 10000
local LOG_LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, FATAL = 5 }
local MIN_LOG_LEVEL = LOG_LEVELS.INFO

local Logger = {}
Logger.__index = Logger

local log_queue = {}
local log_worker_active = false
local shutdown_signal = false

local log_async = uv.new_async(function()
    Logger.processLogQueue()
end)

function Logger:new()
    local obj = setmetatable({}, self)
    obj.pid = ffi.C.getpid()
    obj.thread_id = tostring(uv.thread_self())
    obj.log_fd = nil
    obj:openLogFile()
    obj:startAutoCleanup()
    return obj
end

function Logger:openLogFile()
    uv.fs_open(LOG_FILE, "a+", 0x1A4, function(err, fd)
        if err then
            print("Failed to open log file:", uv.strerror(err))
            return
        end
        self.log_fd = fd
        if #log_queue > 0 then
            log_async:send()
        end
    end)
end

function Logger:log(level, msg, source, request_id)
    if not LOG_LEVELS[level] or LOG_LEVELS[level] < MIN_LOG_LEVEL then return end
    if not self.log_fd then
        self:openLogFile()
        return
    end

    if #log_queue >= MAX_QUEUE_SIZE then
        print("Log queue overflow! Dropping logs.")
        return
    end

    local entry = {
        timestamp = uv.hrtime(),
        level = level,
        message = msg,
        source = source or "unknown",
        pid = self.pid,
        thread_id = self.thread_id,
        request_id = request_id or "N/A",
        memory_usage = collectgarbage("count")
    }

    local json_log, json_err = cjson.encode(entry)
    if not json_log then
        print("JSON encode failed:", json_err)
        return
    end

    table.insert(log_queue, json_log .. "\n")
    log_async:send()
end

function Logger.processLogQueue()
    if #log_queue == 0 or shutdown_signal then
        log_worker_active = false
        return
    end

    log_worker_active = true
    local batch_logs = table.concat(log_queue)
    log_queue = {}

    uv.fs_stat(LOG_FILE, function(err, stat)
        if not err and stat.size >= MAX_LOG_SIZE then
            Logger:rotateLogs()
        end

        if Logger.log_fd then
            uv.fs_write(Logger.log_fd, batch_logs, -1, function(write_err)
                if write_err then
                    print("Log write failed:", uv.strerror(write_err))
                end
            end)
        else
            print("Log file descriptor is nil, cannot write logs.")
        end
    end)
end

function Logger:rotateLogs()
    if self.log_fd then
        local fd = self.log_fd
        self.log_fd = nil  -- Prevent new logs from writing

        self:flushBuffer() -- Flush before rotation

        uv.fs_close(fd, function()
            os.rename(LOG_FILE, LOG_FILE .. ".old")
            self:openLogFile()
        end)
    else
        os.rename(LOG_FILE, LOG_FILE .. ".old")
        self:openLogFile()
    end
end


function Logger:flushBuffer()
    if #log_queue == 0 or not self.log_fd then return end

    local batch_logs = table.concat(log_queue)
    log_queue = {}

    uv.fs_write(self.log_fd, batch_logs, -1, function(err)
        if err then
            print("Final log flush failed:", uv.strerror(err))
        end
    end)
end

function Logger:shutdown()
    shutdown_signal = true
    self:flushBuffer()
    
    if self.log_fd then
        local fd = self.log_fd
        self.log_fd = nil -- Prevent further writes
        uv.fs_close(fd, function()
            print("[Logger] Shutdown complete. Logs flushed.")
        end)
    end
end


function Logger:startAutoCleanup()
    uv.new_timer():start(60000, 60000, function()
        uv.fs_stat(LOG_FILE, function(err, stat)
            if not err and stat.size >= MAX_LOG_SIZE then
                self:rotateLogs()
            end
        end)
    end)
end

return Logger
