-- utils/token_store_file.lua

local json = require("dkjson")
local jwt = require("auth.purejwt")
local path = "refresh_tokens.json"

local store = {}
local M = {}

local config = {
    allow_multiple = false,
    cleanup_expired = true,
    max_session_age = 7 * 86400,     -- 7 days max session (absolute cap), nil to disable
    cleanup_interval = 3600,         -- run auto-cleanup every 1 hour (in seconds)
    secrete = "dawn_sever_key"
}

local function load_store()
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local data = json.decode(content)
        if type(data) == "table" then
            store = data
        end
    end
    -- auto-cleanup expired tokens at startup
    M.cleanup_all()
end


local function save_store()
    if(json.encode(store)) then
    local file = io.open(path, "w+")
    if file then
        file:write(json.encode(store))
        file:close()
    end
else 
    print("Store is empty")
end
end

local function is_expired(token, issued)
    local payload = jwt.decode(token, config.secrete, false)
    local now = os.time()

    local soft_expired = payload and payload.exp and now >= payload.exp
    local hard_expired = config.max_session_age and issued and (now - issued >= config.max_session_age)

    return soft_expired or hard_expired
end


local function cleanup_user_tokens(user_id)
    local entries = store[user_id]
    if not entries then return end

    local filtered = {}
    for _, entry in ipairs(entries) do
        if not is_expired(entry.token, entry.issued) then
            table.insert(filtered, entry)
        end
    end

    store[user_id] = #filtered > 0 and filtered or nil
end


-- Initialize config
function M.init(options)
    for k, v in pairs(options or {}) do
        config[k] = v
    end
end

--- Save a refresh token with device metadata
-- @param user_id string
-- @param refresh_token string
-- @param metadata table: { device_id, ip, agent }
function M.save_refresh_token(user_id, refresh_token, metadata)
    local entry = {
        token = refresh_token,
        device_id = metadata.device_id or "unknown",
        ip = metadata.ip or "unknown",
        agent = metadata.agent or "unknown",
        issued = os.time()
    }
    if config.allow_multiple then
        store[user_id] = store[user_id] or {}
        table.insert(store[user_id], entry)
    else
        store[user_id] = { entry }
    end

    save_store()
end

--- Verify a refresh token is valid for a user
function M.verify(user_id, refresh_token)
    if config.cleanup_expired then cleanup_user_tokens(user_id) end
    local entries = store[user_id]
    if not entries then return false end

    for _, entry in ipairs(entries) do
        if entry.token == refresh_token then
            return true
        end
    end
    return false
end

--- Revoke a specific refresh token
function M.revoke_refresh_token(user_id, refresh_token)
    local entries = store[user_id]
    if not entries then return end

    local kept = {}
    for _, entry in ipairs(entries) do
        if entry.token ~= refresh_token then
            table.insert(kept, entry)
        end
    end
    store[user_id] = #kept > 0 and kept or nil
    save_store()
end

--- Revoke a refresh token by device_id
function M.revoke_by_device_id(user_id, device_id)
    local entries = store[user_id]
    if not entries then return end

    local kept = {}
    for _, entry in ipairs(entries) do
        if entry.device_id ~= device_id then
            table.insert(kept, entry)
        end
    end

    store[user_id] = #kept > 0 and kept or nil
    save_store()
end


--- List a user's active devices
function M.list_sessions(user_id)
    if config.cleanup_expired then cleanup_user_tokens(user_id) end
    local entries = store[user_id]
    if not entries then return {} end

    local now = os.time()
    local sessions = {}

    for _, entry in ipairs(entries) do
        local payload = jwt.decode(entry.token, config.secrete, false)
        local exp = payload and payload.exp
        local delta = exp and (exp - now)

        local function format_time_left(seconds)
            if not seconds then return "unknown" end
            if seconds <= 0 then return "expired" end
            if seconds < 60 then return seconds .. " sec" end
            if seconds < 3600 then return math.floor(seconds / 60) .. " min" end
            if seconds < 86400 then return math.floor(seconds / 3600) .. " hr" end
            return math.floor(seconds / 86400) .. " day"
        end

        table.insert(sessions, {
            device_id = entry.device_id,
            ip = entry.ip,
            agent = entry.agent,
            issued = entry.issued,
            expires = exp,
            is_expired = exp and (now >= exp) or true,
            expires_in = format_time_left(delta)
        })
    end

    table.sort(sessions, function(a, b)
        return (a.expires or math.huge) < (b.expires or math.huge)
    end)

    return sessions
end


function M.cleanup_all()
    local removed_total = 0

    for user_id, entries in pairs(store) do
        local before = type(entries) == "table" and #entries or 0
        cleanup_user_tokens(user_id)
        local after = store[user_id] and #store[user_id] or 0
        removed_total = removed_total + (before - after)
    end

    if removed_total > 0 then
        save_store()
        print("[TokenStore] Cleaned up " .. removed_total .. " expired refresh tokens.")
    end

    return removed_total
end



load_store()

return M
