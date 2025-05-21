local redis = require "redis"
local cjson = require "cjson"


-- Utility for validation
local function assert_type(value, expected_type, name)
    if type(value) ~= expected_type then
      error(("Expected '%s' to be a %s, got %s"):format(name, expected_type, type(value)))
    end
  end

--- @class RedisBackendStrategy
local RedisBackendStrategy = {}
RedisBackendStrategy.__index = RedisBackendStrategy

-- Inherit from BackendStrategy (optional, but good practice for ensuring interface compliance)
local BackendStrategy = require "server.websockets.presence_interface"  -- Assuming this is in a separate file

--- Creates a new instance of RedisBackendStrategy.
--- @param config table Configuration options for Redis.
--- @return RedisBackendStrategy
function RedisBackendStrategy.new(config)
    local instance = setmetatable(BackendStrategy.new(config), RedisBackendStrategy) -- Chain
    instance:init(config)
    return instance
end

--- Initializes the Redis backend strategy with the given configuration.
--- @param config table
function RedisBackendStrategy:init(config)
    BackendStrategy.assert_implements(self)  -- Call this first to ensure compliance
    assert_type(config, "table", "config")
    self.redis = redis.connect(config) -- Use the redis-lua client
    --  Consider adding error handling here for the redis.connect
    if not self.redis then
       error("Failed to connect to Redis. Check your configuration.")
    end
    self.config = config
end



-- Utility function to handle Redis errors
local function check_redis_error(reply)
  if type(reply) == "table" and reply.err then
    error("Redis error: " .. reply.err)
  end

  return false
end

-- =================================================================================================
--  PUB/SUB
-- =================================================================================================

function RedisBackendStrategy:subscribe(topic, callback)
    assert_type(topic, "string", "topic")
    assert_type(callback, "function", "callback")

    --  redis-lua's subscribe is blocking.  This is not ideal for a shared
    --  application.  In a real application, you'd want to use a separate
    --  thread or an async library like LuaSocket, or use the async functions
    --  provided by a redis-lua version supporting it.  This example uses
    --  a simple, blocking implementation for demonstration.

    local sub = redis.connect(self.config) -- Create a separate connection for subscribing
    if not sub then
        error("Failed to connect to Redis for subscription.")
    end
    local ok, err = sub:subscribe(topic)
    if not ok then
       error("Failed to subscribe to topic: " .. err)
    else
        print("Subscribed to topic: " .. topic)
    end

    while true do
        local msg = sub:read_reply()
        if not msg then
            error("Error reading from subscription") -- handle disconnects
        end
        if msg[1] == "message" then
            local received_topic = msg[2]
            local message_data = cjson.decode(msg[3])  --  Use cjson to decode
            callback(received_topic, message_data)
        elseif msg[1] == "subscribe" then
            --  Do nothing, just acknowledge subscribe.
        else
          -- Handle other reply types (e.g., pmessage, unsubscribe)
          --  Log unexpected messages.
          print("Unexpected message from Redis pubsub:", msg[1])
        end
    end
    sub:disconnect() -- this part will never be reached in this blocking implementation
end

function RedisBackendStrategy:publish(topic, message)
    assert_type(topic, "string", "topic")
    assert_type(message, "table", "message")
    local message_json = cjson.encode(message) -- Use cjson to encode the message
    local reply = self.redis:publish(topic, message_json)
    check_redis_error(reply)
    return reply
end

function RedisBackendStrategy:unsubscribe(topic)
    assert_type(topic, "string", "topic")
    local reply = self.redis:unsubscribe(topic)
    check_redis_error(reply)
    return reply
end

-- =================================================================================================
--  STATE MANAGEMENT
-- =================================================================================================

function RedisBackendStrategy:set_user_status(user_id, status)
    BackendStrategy.set_user_status(self, user_id, status) -- Validate status
    local reply = self.redis:hset("user_status", user_id, status)
    check_redis_error(reply)
end

function RedisBackendStrategy:get_user_status(user_id)
    assert_type(user_id, "string", "user_id")
    local reply = self.redis:hget("user_status", user_id)
    check_redis_error(reply)
    if not reply then
        return "offline" -- Default status
    end
    return reply
end

function RedisBackendStrategy:set_presence(topic, ws_id, user_id, meta)
    assert_type(topic, "string", "topic")
    assert_type(meta, "table", "meta")
      if not ws_id then return end
  if not meta then meta = {} end
  if user_id then
    local ws_id_exits = self:exist_in_presence(ws_id, topic)
    self:remove_presence(topic, ws_id)

    if not (self:exist_in_presence(user_id, topic)) then
     local meta_json = cjson.encode(meta)
    local reply = self.redis:hset("presence:" .. topic, user_id, meta_json)
    check_redis_error(reply)
    end
  else
    if not (self:exist_in_presence(ws_id, topic)) then
    local meta_json = cjson.encode(meta)
    local reply = self.redis:hset("presence:" .. topic, user_id, meta_json)
    check_redis_error(reply)
    end
  end  
end


--- Removes the presence information for a user from a specific topic.
--- @param topic string The topic to remove the user's presence from.
--- @param ws_id string The ID of the user\'s websocket identifier'.
function RedisBackendStrategy:remove_presence(topic, ws_id, is_delete_old)
    if not ws_id then return end
        assert_type(ws_id, "string", "ws_id")
    -- local user_id = self:get_ws_id_binded_user_id(ws_id)
     local user_id = self:get_ws_id_binded_user_id(ws_id)

     if self:exist_in_presence(ws_id, topic) then
        local reply = self.redis:hdel("presence:" .. topic, ws_id)
        check_redis_error(reply)
     end
        if self:exist_in_presence(user_id, topic) then
            local reply = self.redis:hdel("presence:" .. topic, user_id)
            check_redis_error(reply)
        end

        if(is_delete_old) then
            self:delete_from_socket_users(ws_id)
        end
end

function RedisBackendStrategy:delete_from_socket_users(ws_id)
    assert_type(ws_id, "string", "ws_id")
    local reply = self.redis:hdel("socket_users", ws_id)
    check_redis_error(reply)
end

--- Helper function to check if a websocket ID exists in a topic's presence.
--- @param ws_id string The websocket ID to check.
--- @param topic string The topic to check presence in.
--- @return boolean True if the websocket ID is present, false otherwise.
function RedisBackendStrategy:exist_in_presence(ws_id, topic)
    assert_type(ws_id, "string", "ws_id")
    assert_type(topic, "string", "topic")

    local presence_data = self:get_all_presence(topic)
    if not presence_data then
        return false -- No presence data found
    end
    for id, _ in pairs(presence_data) do
        if id == ws_id then
            return true
        end
    end
    return false
end

function RedisBackendStrategy:get_all_presence(topic)
    assert_type(topic, "string", "topic")
    local reply = self.redis:hgetall("presence:" .. topic)
    check_redis_error(reply)
    local presence = {}
     if reply then
        for k, v in pairs(reply) do
            presence[k] = cjson.decode(v)
        end
     end
    return presence
end

function RedisBackendStrategy:diff_presence(topic, old_state, new_state)
    assert_type(topic, "string", "topic")
    assert_type(old_state, "table", "old_state")
    assert_type(new_state, "table", "new_state")

    local joins = {}
    local leaves = {}

    for user_id, _ in pairs(new_state) do
        if not old_state[user_id] then
            table.insert(joins, user_id)
        end
    end

    for user_id, _ in pairs(old_state) do
        if not new_state[user_id] then
            table.insert(leaves, user_id)
        end
    end

    return {
        joins = joins,
        leaves = leaves,
    }
end

function RedisBackendStrategy:get_user_binded_socket_id(user_id)
    assert_type(user_id, "string", "user_id")
    local reply = self.redis:hget("user_sockets", user_id)
    check_redis_error(reply)
    return reply or nil
end

function RedisBackendStrategy:get_ws_id_binded_user_id(ws_id)
    assert_type(ws_id, "string", "ws_id")
    --  Check if the socket ID exists in the socket_users hash
    local reply = self.redis:hget("socket_users", ws_id)
    check_redis_error(reply)
    return reply or nil
end

-- =================================================================================================
--  PRIVATE / DIRECT MESSAGES
-- =================================================================================================

function RedisBackendStrategy:store_private_message(from_id, to_id, message)
    assert_type(from_id, "string", "from_id")
    assert_type(to_id, "string", "to_id")
    assert_type(message, "table", "message")
    local message_json = cjson.encode(message)
    local key = "private_messages:" .. from_id .. ":" .. to_id
    local reply = self.redis:rpush(key, message_json)
    check_redis_error(reply)
    local key_reverse = "private_messages:" .. to_id .. ":" .. from_id
    local reply_reverse = self.redis:rpush(key_reverse, message_json)
    check_redis_error(reply_reverse)
end

function RedisBackendStrategy:fetch_private_history(user1, user2, opts)
    assert_type(user1, "string", "user1")
    assert_type(user2, "string", "user2")
    if opts ~= nil then assert_type(opts, "table", "opts") end

    local key = "private_messages:" .. user1 .. ":" .. user2
    local start_index = 0
    local end_index = -1 -- Get all messages
    if opts and opts.offset then
        start_index = opts.offset
    end
    if opts and opts.limit then
        end_index = start_index + opts.limit - 1
    end

    local reply = self.redis:lrange(key, start_index, end_index)
    check_redis_error(reply)

    local messages = {}
    if reply and #reply > 0 then
      for i, message_json in ipairs(reply) do
        table.insert(messages, cjson.decode(message_json))
      end
    end
    return messages
end

function RedisBackendStrategy:queue_private_message(to_id, message)
    assert_type(to_id, "string", "to_id")
    assert_type(message, "table", "message")
    local message_json = cjson.encode(message)
    local reply = self.redis:rpush("queued_messages:" .. to_id, message_json)
    check_redis_error(reply)
end

function RedisBackendStrategy:fetch_queued_messages(user_id)
    assert_type(user_id, "string", "user_id")
    local reply = self.redis:lrange("queued_messages:" .. user_id, 0, -1)
    check_redis_error(reply)
    local messages = {}
    if reply and #reply > 0 then
        for i, message_json in ipairs(reply) do
            table.insert(messages, cjson.decode(message_json))
        end
    end
    return messages
end

function RedisBackendStrategy:clear_queued_messages(user_id)
    assert_type(user_id, "string", "user_id")
    local reply = self.redis:del("queued_messages:" .. user_id)
    check_redis_error(reply)
end

-- =================================================================================================
--  ROOM / CHANNEL MESSAGE DISTRIBUTION
-- =================================================================================================

function RedisBackendStrategy:queue_room_message(topic, message)
    assert_type(topic, "string", "topic")
    assert_type(message, "table", "message")
    local message_json = cjson.encode(message)
    local reply = self.redis:rpush("room_messages:" .. topic, message_json)
    check_redis_error(reply)
end

function RedisBackendStrategy:drain_room_messages(topic)
    assert_type(topic, "string", "topic")
    local reply = self.redis:lrange("room_messages:" .. topic, 0, -1)
    check_redis_error(reply)
    local messages = {}
      if reply and #reply > 0 then
        for i, message_json in ipairs(reply) do
          table.insert(messages, cjson.decode(message_json))
        end
      end
    self.redis:del("room_messages:" .. topic) -- Clear the queue after draining.
    return messages
end

-- =================================================================================================
--  SCALABILITY FEATURES
-- =================================================================================================

function RedisBackendStrategy:get_connected_users()
    local reply = self.redis:smembers("connected_users")
    check_redis_error(reply)
    return reply or {}
end

function RedisBackendStrategy:mark_socket_active(socket_id, user_id)
    assert_type(socket_id, "string", "socket_id")
    assert_type(user_id, "string", "user_id")
    local reply1 = self.redis:hset("socket_users", socket_id, user_id)
    local reply2 = self.redis:hset("user_sockets", user_id, socket_id)
    local reply3 = self.redis:sadd("connected_users", user_id)
    self:set_user_status(user_id, "online")
    check_redis_error(reply1)
    check_redis_error(reply2)
    check_redis_error(reply3)
end

function RedisBackendStrategy:cleanup_disconnected_sockets(ttl_seconds)
    assert_type(ttl_seconds, "number", "ttl_seconds")
    --  Redis does not have a built-in way to expire hash fields.
    --  This requires a more complex approach:
    --  1.  Use a sorted set ("socket_activity") where the score is the last activity time.
    --  2.  In this function, find sockets with activity time older than ttl_seconds.
    --  3.  Remove those sockets from "socket_users", "user_sockets", and "connected_users".
    --  This implementation is more complex, so I'll provide a simplified version
    --  that doesn't actually expire sockets, but sets them with an expiry.
    --  A separate process would be needed to remove the expired keys.

    local now = redis.time().sec
    local cutoff = now - ttl_seconds

    -- Get sockets that are expired
    local expired_sockets = self.redis:zrangebyscore("socket_activity", "-inf", cutoff)

    if expired_sockets and #expired_sockets > 0 then
        for _, socket_id in ipairs(expired_sockets) do
            local user_id = self.redis:hget("socket_users", socket_id)
            if user_id then
                self.redis:hdel("user_sockets", user_id)
            end
            self.redis:hdel("socket_users", socket_id)
            self.redis:srem("connected_users", user_id)
            self.redis:zrem("socket_activity", socket_id)
        end
    end

    --  Instead of expiring fields, expire the whole hashes.  This is simpler,
    --  but means we lose all socket/user mappings after ttl_seconds of inactivity.
    --  This is NOT ideal, and a proper implementation requires the sorted set.
    self.redis:expire("socket_users", ttl_seconds)
    self.redis:expire("user_sockets", ttl_seconds)
    self.redis:expire("connected_users", ttl_seconds)
    self.redis:expire("socket_activity", ttl_seconds)
end

-- =================================================================================================
--   DATA PERSISTENCE
-- =================================================================================================

function RedisBackendStrategy:persist_state(key, value, ttl_seconds)
    assert_type(key, "string", "key")
    assert_type(value, "table", "value")
    local value_json = cjson.encode(value)
    if ttl_seconds then
        assert_type(ttl_seconds, "number", "ttl_seconds")
        local reply = self.redis:setex(key, ttl_seconds, value_json)
        check_redis_error(reply)
    else
        local reply = self.redis:set(key, value_json)
         check_redis_error(reply)
    end
end

function RedisBackendStrategy:retrieve_state(key)
    assert_type(key, "string", "key")
    local reply = self.redis:get(key)
    check_redis_error(reply)
    if reply then
        return cjson.decode(reply)
    else
        return nil
    end
end

function RedisBackendStrategy:delete_state(key)
    assert_type(key, "string", "key")
    local reply = self.redis:del(key)
    check_redis_error(reply)
end

-- =================================================================================================
--  ROOM / CHANNEL MANAGEMENT
-- =================================================================================================

function RedisBackendStrategy:room_exists(topic)
    assert_type(topic, "string", "topic")
    local reply = self.redis:sismember("rooms", topic)
    check_redis_error(reply)
    return reply == true
end

function RedisBackendStrategy:create_room(room_id)
       if not room_id then
    error("Room ID cannot be nil")
    return;
  end
    assert_type(room_id, "string", "room_id")
    --  Check if the room already exists
    if self:room_exists(room_id) then
        -- error("Room already exists: " .. room_id)+
        return ;
    end
    local reply = self.redis:sadd("rooms", room_id)
    check_redis_error(reply)
end


--- Clears the user ID to socket ID binding.
--- @param user_id string The ID of the user to clear the binding for.
function RedisBackendStrategy:clear_user_socket_binding(ws_id, user_id)
    assert_type(user_id, "string", "user_id")

    local socket_id = self:get_user_binded_socket_id(user_id)
    if socket_id then
        local reply1 = self.redis:hdel("user_sockets", user_id)
        local reply2 = self.redis:hdel("socket_users", socket_id)
        check_redis_error(reply1)
        check_redis_error(reply2)
    end
end

function RedisBackendStrategy:delete_room(room_id)
    assert_type(room_id, "string", "room_id")
    local reply = self.redis:srem("rooms", room_id)
    check_redis_error(reply)
end

function RedisBackendStrategy:get_all_rooms()
    local reply = self.redis:smembers("rooms")
    check_redis_error(reply)
    return reply or {}
end



-- =================================================================================================
--  EMBED LOGIC (optional)
-- =================================================================================================

function RedisBackendStrategy:run_script(name, args)
    assert_type(name, "string", "name")
    if args ~= nil then assert_type(args, "table", "args") end
    --  Redis does not have the ability to run arbitrary lua scripts by name.
    --  You would have to load the script into Redis using SCRIPT LOAD,
    --  and then execute it by its SHA1 hash.  This is non-trivial.
    --  This is a placeholder.
    error("run_script is not implemented in this Redis implementation.  Use EVALSHA.")
end

return RedisBackendStrategy
