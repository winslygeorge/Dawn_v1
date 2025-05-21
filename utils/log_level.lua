---@alias LogLevelType
---| 1 # DEBUG
---| 2 # INFO
---| 3 # WARN
---| 4 # ERROR
---| 5 # FATAL

---@class LogLevel
---@field DEBUG LogLevelType
---@field INFO LogLevelType
---@field WARN LogLevelType
---@field ERROR LogLevelType
---@field FATAL LogLevelType
---@field toString fun(level: LogLevelType): string

local LogLevel = {
    DEBUG = 1,
    INFO  = 2,
    WARN  = 3,
    ERROR = 4,
    FATAL = 5,
}

---Converts a level number to its string representation.
---@param level LogLevelType
---@return string
function LogLevel.toString(level)
    for k, v in pairs(LogLevel) do
        if v == level then return k end
    end
    return "UNKNOWN"
end

return LogLevel
