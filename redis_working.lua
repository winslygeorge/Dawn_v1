local redis = require "redis"
local cjson = require "cjson"


-- Utility for validation
local function assert_type(value, expected_type, name)
    if type(value) ~= expected_type then
      error(("Expected '%s' to be a %s, got %s"):format(name, expected_type, type(value)))
    end
  end
local BackendStrategy = require("server.websockets.presence_interface")

--- @class RedisLuaBackend : BackendStrategy
local RedisLuaBackend = {}
setmetatable(RedisLuaBackend, { __index = BackendStrategy })

--- Creates a new instance of RedisBackendStrategy.
--- @param config table Configuration options for Redis.
--- @return RedisBackendStrategy
function RedisLuaBackend.new(config)
    local instance = setmetatable(BackendStrategy.new(config), RedisLuaBackend) -- Chain
    instance:init(config)
    return instance
end

--- Initializes the Redis backend strategy with the given configuration.
--- @param config table
function RedisLuaBackend:init(config)
    BackendStrategy.assert_implements(self)  -- Call this first to ensure compliance
    assert_type(config, "table", "config")
    self.redis = redis.connect(config) -- Use the redis-lua client
    --  Consider adding error handling here for the redis.connect
    if not self.redis then
       error("Failed to connect to Redis. Check your configuration.")
    end
    self.config = config
end
-------------------------------------------------
-- Utility Functions (Helper functions for Redis operations)
-------------------------------------------------

local function redis_key(key)
    --  Consider adding a namespace here, e.g., "my_app:" .. key
    return key
end

local function serialize(obj)
    return cjson.encode(obj)
end

local function deserialize(str)
    if not str then return nil end
    local decoded, err = cjson.decode(str)
    if err then
      -- Handle the error, for example, log it and return a default value or nil
      print("Error decoding JSON: " .. err)
      return {} -- Or return nil, depending on the desired behavior
    end
    return decoded
end

-------------------------------------------------
-- PUB/SUB (Redis, callback-based)
--  Important:  Redis Pub/Sub is used for message distribution,
--              *not* for subscription management in this backend.
--              The subscription management (registering callbacks)
--              remains in Lua.  This is a hybrid approach.
-------------------------------------------------

--- Subscribes a callback function to a specific topic.
--- @param topic string The topic to subscribe to.
--- @param callback function The function to call when a message is published to the topic.
function RedisLuaBackend:subscribe(topic, callback)
    self.callbacks = self.callbacks or {}
    self.callbacks[topic] = self.callbacks[topic] or {}
    table.insert(self.callbacks[topic], callback)

    --  In a full Redis implementation, you would *also* subscribe
    --  to the Redis channel here.  However, the original code
    --  doesn't do that, and instead relies on the caller to
    --  handle Redis subscription.  We maintain that behavior.
end

--- Publishes a message to a specific topic.
--- @param topic string The topic to publish to.
--- @param message table The message to publish.
function RedisLuaBackend:publish(topic, message)
    local serialized_message = serialize(message)
    local redis_topic = redis_key("pubsub:" .. topic)
    local status, err = self.redis:publish(redis_topic, serialized_message)
    if err then
        print("Error publishing to Redis: " .. err) --  Basic error handling
        return
    end

    --  Call local callbacks (this part is kept from the original).
    local subs = self.callbacks[topic] or {}
    for _, cb in ipairs(subs) do
        cb(message)
    end
end

--- Unsubscribes from a specific topic.
--- @param topic string The topic to unsubscribe from.
function RedisLuaBackend:unsubscribe(topic)
    self.callbacks[topic] = nil
    --  In a full Redis implementation, you would also unsubscribe
    --  from the Redis channel here.  But, as above, we maintain
    --  the original behavior.
end

-------------------------------------------------
-- STATE MANAGEMENT
-------------------------------------------------

--- Sets the status of a user.
--- @param user_id string The ID of the user.
--- @param status string The new status of the user (e.g., "online", "offline", "away").
function RedisLuaBackend:set_user_status(user_id, status)
    local key = redis_key("status:" .. user_id)
    local serialized_status = serialize(status)
    local ok, err = self.redis:set(key, serialized_status)
     if err then
        print("Error setting user status in Redis: " .. err)
    end
end

--- Sets the presence information for a user on a specific topic.
--- @param topic string The topic the user is present on.
--- @param ws_id string The ID of the user's websocket identifier.
--- @param user_id string The ID of the user.
--- @param meta table Additional metadata associated with the user's presence.
function RedisLuaBackend:set_presence(topic, ws_id, user_id, meta)
    if not ws_id then return end
    if not meta then meta = {} end

    local presence_key = redis_key("presence:" .. topic)

    if user_id then
        if self:exist_in_presence(ws_id, topic) then
          self:remove_presence(topic, ws_id)
        end
        local serialized_meta = serialize(meta)
        local ok, err = self.redis:hset(presence_key, user_id, serialized_meta)
         if err then
            print("Error setting user presence in Redis: " .. err)
        end
    else
        local serialized_meta = serialize(meta)
        local ok, err = self.redis:hset(presence_key, ws_id, serialized_meta)
         if err then
            print("Error setting ws presence in Redis: " .. err)
        end
    end
end

function RedisLuaBackend:exist_in_presence(ws_id, topic)
    local presence_key = redis_key("presence:" .. topic)
    local exists, err = self.redis:hexists(presence_key, ws_id)
     if err then
        print("Error checking presence in Redis: " .. err)
        return false  -- Handle error appropriately
    end
    return exists == 1
end

--- Removes the presence information for a user from a specific topic.
--- @param topic string The topic to remove the user's presence from.
--- @param ws_id string The ID of the user's websocket identifier.
function RedisLuaBackend:remove_presence(topic, ws_id)
    local presence_key = redis_key("presence:" .. topic)
    local user_id = self:get_ws_id_binded_user_id(ws_id)
    local ok, err = self.redis:hdel(presence_key, ws_id)
     if err then
        print("Error removing ws presence in Redis: " .. err)
    end
    if user_id then
        local ok, err = self.redis:hdel(presence_key, user_id)
         if err then
            print("Error removing user presence in Redis: " .. err)
        end
    end
end

--- Gets the presence information for all users on a specific topic.
--- @param topic string The topic to retrieve presence information for.
--- @return table A table where keys are user IDs and values are their metadata.
function RedisLuaBackend:get_all_presence(topic)
    local presence_key = redis_key("presence:" .. topic)
    local result, err = self.redis:hgetall(presence_key)
    if err then
        print("Error getting all presence from Redis: " .. err)
        return {}
    end

    local presence = {}
    if result then
        for k, v in pairs(result) do
            presence[k] = deserialize(v)
        end
    end
    return presence
end

--- Computes the difference between two presence states for a topic.
--- @param topic string The topic to compare presence states for.
--- @param old_state table The previous presence state (user ID to metadata).
--- @param new_state table The current presence state (user ID to metadata).
--- @return table A table containing two lists: `joins` (user IDs who joined) and `leaves` (user IDs who left).
function RedisLuaBackend:diff_presence(topic, old_state, new_state)
    local joins, leaves = {}, {}

    for uid, meta in pairs(new_state) do
        if not old_state[uid] then
            joins[uid] = meta
        end
    end
    for uid, meta in pairs(old_state) do
        if not new_state[uid] then
            leaves[uid] = meta
        end
    end
    return { joins = joins, leaves = leaves }
end

-------------------------------------------------
-- PRIVATE MESSAGING
-------------------------------------------------

--- Stores a private message between two users.
--- @param from_id string The ID of the sender.
--- @param to_id string The ID of the recipient.
--- @param message table The message content.
function RedisLuaBackend:store_private_message(from_id, to_id, message)
    local key = redis_key("private_messages:" .. to_id)
    local serialized_message = serialize({ from = from_id, message = message })
    local ok, err = self.redis:rpush(key, serialized_message)
     if err then
        print("Error storing private message in Redis: " .. err)
    end
end

--- Fetches the history of private messages for a specific user.
--- @param user1 string The ID of the first user.
--- @param user2 string The ID of the second user whose received messages are fetched.
--- @param opts? table Optional parameters for fetching history.
--- @return table A table containing the history of messages received by `user2`. Each entry is `{ from = sender_id, message = message_content }`.
function RedisLuaBackend:fetch_private_history(user1, user2, opts)
    local key = redis_key("private_messages:" .. user2)
    local messages, err = self.redis:lrange(key, 0, -1)
    if err then
        print("Error fetching private message history from Redis: " .. err)
        return {}
    end

    local history = {}
    if messages then
        for _, msg_str in ipairs(messages) do
            local msg = deserialize(msg_str)
            if msg then
              table.insert(history, msg)
            end
        end
    end
    return history
end

--- Queues a private message to be delivered to a user.
--- @param receiver string The ID of the recipient.
--- @param message table The message to queue.
function RedisLuaBackend:queue_private_message(receiver, message)
    local key = redis_key("queued_messages:" .. receiver)
    local serialized_message = serialize(message)
    local ok, err = self.redis:rpush(key, serialized_message)
     if err then
        print("Error queueing private message in Redis: " .. err)
    end
end

--- Fetches all queued private messages for a user.
--- @param user_id string The ID of the user.
--- @return table A table containing the queued messages for the user.
function RedisLuaBackend:fetch_queued_messages(user_id)
    local key = redis_key("queued_messages:" .. user_id)
    local messages, err = self.redis:lrange(key, 0, -1)
    if err then
       print("Error fetching queued messages from Redis: " .. err)
       return {}
    end
    local result = {}
    if messages then
      for _, msg_str in ipairs(messages) do
        table.insert(result, deserialize(msg_str))
      end
    end
    return result
end

--- Clears all queued private messages for a user.
--- @param user_id string The ID of the user.
function RedisLuaBackend:clear_queued_messages(user_id)
    local key = redis_key("queued_messages:" .. user_id)
    local ok, err = self.redis:del(key)
     if err then
        print("Error clearing queued messages in Redis: " .. err)
    end
end

-------------------------------------------------
-- ROOM MESSAGES
-------------------------------------------------

--- Queues a message to be distributed to all participants in a room or channel.
--- @param topic string The topic of the room or channel.
--- @param message table The message to queue.
function RedisLuaBackend:queue_room_message(topic, message)
    local key = redis_key("room_queues:" .. topic)
    local serialized_message = serialize(message)
    local ok, err = self.redis:rpush(key, serialized_message)
     if err then
        print("Error queueing room message in Redis: " .. err)
    end
end

--- Drains all queued messages for a specific room or channel.
--- @param topic string The topic of the room or channel.
--- @return table A table containing the drained messages. This table is emptied after retrieval.
function RedisLuaBackend:drain_room_messages(topic)
    local key = redis_key("room_queues:" .. topic)
    local messages, err = self.redis:lrange(key, 0, -1)
    if err then
        print("Error draining room messages from Redis: " .. err)
        return {}
    end

    local ok, err = self.redis:del(key)
     if err then
        print("Error deleting room queue in Redis: " .. err)
    end

    local result = {}
     if messages then
      for _, msg_str in ipairs(messages) do
        table.insert(result, deserialize(msg_str))
      end
    end
    return result
end

-------------------------------------------------
-- SCALABILITY
-------------------------------------------------

--- Gets a list of all currently connected user IDs.
--- @return table A table containing the IDs of connected users.
function RedisLuaBackend:get_connected_users()
    local pattern = redis_key("socket_activity:*")
    local keys, err = self.redis:keys(pattern)
     if err then
        print("Error getting connected users from Redis: " .. err)
        return {}
    end

    local users = {}
    if keys then
        for _, key in ipairs(keys) do
            -- Extract user ID from the key (assuming key format is "socket_activity:user_id")
            local user_id = string.match(key, "socket_activity:(.+)")
            if user_id then
                table.insert(users, user_id)
            end
        end
    end
    return users
end

--- Marks a socket as active and associates it with a user ID.
--- @param ws_id string The ID of the web socket.
--- @param user_id string The ID of the user associated with the socket.
function RedisLuaBackend:mark_socket_active(ws_id, user_id)
    local key = redis_key("socket_activity:" .. user_id)
    local value = serialize({ ws_id = ws_id, last_active = os.time() })
    local ok, err = self.redis:set(key, value)
    if err then
        print("Error marking socket active in Redis: " .. err)
    end
    local ok, err = self.redis:expire(key, 86400) -- Expire after 24 hours (or adjust as needed)
     if err then
        print("Error setting expiry for socket activity in Redis: " .. err)
    end
    self:set_user_status(user_id, "online")
end

---return marked sockets
function RedisLuaBackend:get_user_binded_socket_id(user_id)
    local key = redis_key("socket_activity:" .. user_id)
    local value, err = self.redis:get(key)
     if err then
        print("Error getting user binded socket from Redis: " .. err)
        return nil
    end
    if value then
      local data = deserialize(value)
      return data.ws_id
    end
    return nil
end

---return ws_id binded to a user_id from the user_id
function RedisLuaBackend:get_ws_id_binded_user_id(ws_id)
    local pattern = redis_key("socket_activity:*")
    local keys, err = self.redis:keys(pattern)
     if err then
        print("Error getting socket activity keys from Redis: " .. err)
        return nil
    end

    if keys then
        for _, key in ipairs(keys) do
            local value, err = self.redis:get(key)
             if err then
                print("Error getting socket activity value from Redis: " .. err)
                return nil
            end
            if value then
              local data = deserialize(value)
              if data.ws_id == ws_id then
                local user_id = string.match(key, "socket_activity:(.+)")
                return user_id
              end
            end
        end
    end
    return nil
end

--- Cleans up information about disconnected sockets that have been inactive for a certain duration.
--- @param ttl_seconds number The time-to-live in seconds for inactive sockets.
function RedisLuaBackend:cleanup_disconnected_sockets(ttl_seconds)
    local pattern = redis_key("socket_activity:*")
    local keys, err = self.redis:keys(pattern)
     if err then
        print("Error getting socket activity keys for cleanup from Redis: " .. err)
        return
    end

    local now = os.time()
    if keys then
        for _, key in ipairs(keys) do
            local value, err = self.redis:get(key)
             if err then
                print("Error getting socket activity value for cleanup from Redis: " .. err)
                return
            end
            if value then
              local data = deserialize(value)
              if now - data.last_active > ttl_seconds then
                local ok, err = self.redis:del(key)
                 if err then
                    print("Error deleting inactive socket activity from Redis: " .. err)
                end
              end
            end
        end
    end
end

-------------------------------------------------
-- STATE PERSISTENCE
-------------------------------------------------

--- Persists a key-value pair with an optional time-to-live.
--- @param key string The key to store the value under.
--- @param value table The value to persist.
--- @param ttl_seconds? number Optional time-to-live in seconds for the stored value.
function RedisLuaBackend:persist_state(key, value, ttl_seconds)
    local serialized_value = serialize(value)
    if ttl_seconds then
        local ok, err = self.redis:setex(redis_key(key), ttl_seconds, serialized_value)
         if err then
            print("Error persisting state with TTL in Redis: " .. err)
        end
    else
        local ok, err = self.redis:set(redis_key(key), serialized_value)
         if err then
            print("Error persisting state in Redis: " .. err)
        end
    end
end

--- Retrieves a persisted value based on its key.
--- @param key string The key of the value to retrieve.
--- @return table|nil The retrieved value, or nil if the key does not exist or has expired.
function RedisLuaBackend:retrieve_state(key)
    local value, err = self.redis:get(redis_key(key))
     if err then
        print("Error retrieving state from Redis: " .. err)
        return nil
    end
    if value then
      return deserialize(value)
    else
      return nil
    end
end

--- Deletes a persisted value based on its key.
--- @param key string The key of the value to delete.
function RedisLuaBackend:delete_state(key)
    local ok, err = self.redis:del(redis_key(key))
     if err then
        print("Error deleting state from Redis: " .. err)
    end
end

-------------------------------------------------
-- EMBEDDED LOGIC
-------------------------------------------------

--- Runs a custom script with optional arguments.
--- @param name string The name of the script to run.
--- @param args? table Optional arguments to pass to the script.
function RedisLuaBackend:run_script(name, args)
    --  In a real implementation, you would load and execute a Lua script
    --  in Redis using EVAL or EVALSHA.  This is a placeholder.
    local script = "return {1,2,3}" -- Placeholder
    local serialized_args = {}
    if args then
      for _, arg in ipairs(args) do
        table.insert(serialized_args, serialize(arg))
      end
    end
    local result, err = self.redis:eval(script, 0, unpack(serialized_args))
    if err then
      print("Error running script in redis", err)
      return
    end
    return result
end

-------------------------------------------------
-- Room Management (For Dynamic Rooms)
-------------------------------------------------

--- Checks if a room with the given ID exists.
--- @param room_id string The ID of the room to check.
--- @return boolean True if the room exists, false otherwise.
function RedisLuaBackend:room_exists(room_id)
    local key = redis_key("presence:" .. room_id)
    local exists, err = self.redis:exists(key)
     if err then
        print("Error checking if room exists in Redis: " .. err)
        return false  -- Handle error appropriately
    end
    return exists == 1
end

--- Creates a new room with the given ID.
--- @param room_id string The ID of the room to create.
function RedisLuaBackend:create_room(room_id)
    if not room_id then
        error("Room ID cannot be nil")
    end
    local key = redis_key("presence:" .. room_id)
    local ok, err = self.redis:hset(key, "room_created", serialize(os.time())) --using a hash to store room creation
     if err then
        print("Error creating room in Redis: " .. err)
        return false
    end
    return true
end

return RedisLuaBackend
