local TokenCleaner = {}
TokenCleaner.__index = TokenCleaner

function TokenCleaner:new(name, interval, scheduler)
    local self = setmetatable({}, TokenCleaner)
    self.name = name or "TokenCleaner"
    self.interval = interval or 3600
    self.scheduler = scheduler  -- pass the scheduler instance!
    return self
end

function TokenCleaner:start()
    self.scheduler:add_task(
        "token_cleanup",
        function()
            local count = require("auth.token_store").cleanup_all()
            if count > 0 then
                print("[TokenCleaner] Removed " .. count .. " expired token(s).")
            end
        end,
        self.interval,
        1, 1, 1
    )
    return true
end

function TokenCleaner:restart()
    return self:start()
end

function TokenCleaner:stop()
    self.scheduler.task_map["token_cleanup"] = nil
    return true
end

return TokenCleaner
