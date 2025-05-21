--- @class BackendStrategy
local BackendStrategy = {}

BackendStrategy.__index = BackendStrategy

--- List of required methods to be implemented by any subclass.
local required_methods = {
  "subscribe",
  "publish",
  "unsubscribe",
  "get_user_status",
  "set_presence",
  "remove_presence",
  "get_all_presence",
  "diff_presence",
  "get_user_binded_socket_id",
  "get_ws_id_binded_user_id",
  "queue_private_message",
  "fetch_queued_messages",
  "clear_queued_messages",
  "get_connected_users",
  "mark_socket_active",
  "cleanup_disconnected_sockets",
  "room_exists",
  "create_room",
}

-- Utility for validation
local function assert_type(value, expected_type, name)
  if type(value) ~= expected_type then
    error(("Expected '%s' to be a %s, got %s"):format(name, expected_type, type(value)))
  end
end

--- Asserts that all required interface methods are implemented.
--- Should be called in subclasses after extending.
--- @param self table The instance to check.
function BackendStrategy.assert_implements(self)
  for _, method_name in ipairs(required_methods) do
    if type(self[method_name]) ~= "function" or self[method_name] == BackendStrategy[method_name] then
      error(("Class does not implement required method '%s'"):format(method_name))
    end
  end
end

--- Creates a new instance of BackendStrategy.
--- @param config? table Configuration options.
--- @return BackendStrategy
function BackendStrategy.new(config)
  local instance = setmetatable({}, BackendStrategy)
  if config then
    instance:init(config)
  end
  return instance
end

--- Initializes the backend strategy with the given configuration.
--- Subclasses must override this and call assert_implements(self).
--- @param config table
function BackendStrategy:init(config)
  assert_type(config, "table", "config")
  BackendStrategy.assert_implements(self)
end


-- Utility for validation
local function assert_type(value, expected_type, name)
  if type(value) ~= expected_type then
    error(("Expected '%s' to be a %s, got %s"):format(name, expected_type, type(value)))
  end
end

-------------------------------------------------
-- PUB/SUB
-------------------------------------------------

--- Subscribes a callback function to a specific topic.
--- @param topic string The topic to subscribe to.
--- @param callback function The function to call when a message is published to the topic.
function BackendStrategy:subscribe(topic, callback)
  assert_type(topic, "string", "topic")
  assert_type(callback, "function", "callback")
  error("subscribe is not implemented")
end

--- Publishes a message to a specific topic.
--- @param topic string The topic to publish to.
--- @param message table The message to publish (assumed to be JSON-encodable).
function BackendStrategy:publish(topic, message)
  assert_type(topic, "string", "topic")
  assert_type(message, "table", "message") -- Assume JSON-encodable
  error("publish is not implemented")
end

--- Unsubscribes from a specific topic.
--- @param topic string The topic to unsubscribe from.
function BackendStrategy:unsubscribe(topic)
  assert_type(topic, "string", "topic")
  error("unsubscribe is not implemented")
end

-------------------------------------------------
-- STATE MANAGEMENT
-------------------------------------------------

--- Sets the status of a user.
--- @param user_id string The ID of the user.
--- @param status string The new status of the user (must be one of: online, offline, away, typing).
function BackendStrategy:set_user_status(user_id, status)
  assert_type(user_id, "string", "user_id")
  assert_type(status, "string", "status")
  local valid_statuses = { online = true, offline = true, away = true, typing = true }
  if not valid_statuses[status] then
    error("Invalid status value. Must be one of: online, offline, away, typing.")
  end
end

--- Gets the current status of a user.
--- @param user_id string The ID of the user.
--- @return string The current status of the user.
function BackendStrategy:get_user_status(user_id)
  assert_type(user_id, "string", "user_id")
  error("get_user_status is not implemented")
  return "offline"
end

--- Sets the presence information for a user on a specific topic.
--- @param topic string The topic the user is present on.
--- @param user_id string The ID of the user.
--- @param meta table Additional metadata associated with the user's presence.
function BackendStrategy:set_presence(topic, user_id, meta)
  assert_type(topic, "string", "topic")
  assert_type(user_id, "string", "user_id")
  assert_type(meta, "table", "meta")
  error("set_presence is not implemented")
end

--- Removes the presence information for a user from a specific topic.
--- @param topic string The topic to remove the user's presence from.
--- @param user_id string The ID of the user.
function BackendStrategy:remove_presence(topic, user_id)
  assert_type(topic, "string", "topic")
  assert_type(user_id, "string", "user_id")
  error("remove_presence is not implemented")
end

--- Gets the presence information for all users on a specific topic.
--- @param topic string The topic to retrieve presence information for.
--- @return table A table containing the presence information for each user.
function BackendStrategy:get_all_presence(topic)
  assert_type(topic, "string", "topic")
  error("get_all_presence is not implemented")
  return {}
end

--- Computes the difference between two presence states for a topic.
--- @param topic string The topic to compare presence states for.
--- @param old_state table The previous presence state.
--- @param new_state table The current presence state.
--- @return table A table containing two lists: `joins` (users who joined) and `leaves` (users who left).
function BackendStrategy:diff_presence(topic, old_state, new_state)
  assert_type(topic, "string", "topic")
  assert_type(old_state, "table", "old_state")
  assert_type(new_state, "table", "new_state")
  error("diff_presence is not implemented")

  return {
    joins = {},
    leaves = {},
  }
end


---return marked sockets

function BackendStrategy:get_user_binded_socket_id(user_id)
  assert_type(user_id, "string", "user_id")
  error("get_user_binded_socket_id is not implemented")
  return ""
end

---return ws_id binded to a user_id from the user_id

function BackendStrategy:get_ws_id_binded_user_id(ws_id)
  assert_type(ws_id, "string", "ws_id")
  error("get_ws_id_binded_user_id is not implemented")
  return ""
end

-------------------------------------------------
-- PRIVATE / DIRECT MESSAGES
-------------------------------------------------

--- Stores a private message between two users.
--- @param from_id string The ID of the sender.
--- @param to_id string The ID of the recipient.
--- @param message table The message content.
function BackendStrategy:store_private_message(from_id, to_id, message)
  assert_type(from_id, "string", "from_id")
  assert_type(to_id, "string", "to_id")
  assert_type(message, "table", "message")
end

--- Fetches the history of private messages between two users.
--- @param user1 string The ID of the first user.
--- @param user2 string The ID of the second user.
--- @param opts? table Optional parameters for fetching history (e.g., pagination).
--- @return table A table containing the message history.
function BackendStrategy:fetch_private_history(user1, user2, opts)
  assert_type(user1, "string", "user1")
  assert_type(user2, "string", "user2")
  if opts ~= nil then assert_type(opts, "table", "opts") end
  return {}
end

--- Queues a private message to be delivered to a user.
--- @param to_id string The ID of the recipient.
--- @param message table The message to queue.
function BackendStrategy:queue_private_message(to_id, message)
  assert_type(to_id, "string", "to_id")
  assert_type(message, "table", "message")
  error("queue_private_message is not implemented")
end

--- Fetches all queued private messages for a user.
--- @param user_id string The ID of the user.
--- @return table A table containing the queued messages.
function BackendStrategy:fetch_queued_messages(user_id)
  assert_type(user_id, "string", "user_id")
  error("fetch_queued_messages is not implemented")
  -- This should return a table of messages, but for now, we return an empty table.
  return {}
end

--- Clears all queued private messages for a user.
--- @param user_id string The ID of the user.
function BackendStrategy:clear_queued_messages(user_id)
  assert_type(user_id, "string", "user_id") 
  error("clear_queued_messages is not implemented")
  -- This function should clear the queued messages for the user.
end

-------------------------------------------------
-- ROOM / CHANNEL MESSAGE DISTRIBUTION
-------------------------------------------------

--- Queues a message to be distributed to all participants in a room or channel.
--- @param topic string The topic of the room or channel.
--- @param message table The message to queue.
function BackendStrategy:queue_room_message(topic, message)
  assert_type(topic, "string", "topic")
  assert_type(message, "table", "message")
end

--- Drains all queued messages for a specific room or channel.
--- @param topic string The topic of the room or channel.
--- @return table A table containing the drained messages.
function BackendStrategy:drain_room_messages(topic)
  assert_type(topic, "string", "topic")
  return {}
end

-------------------------------------------------
-- SCALABILITY FEATURES
-------------------------------------------------

--- Gets a list of all currently connected users.
--- @return table A table containing the IDs of connected users.
function BackendStrategy:get_connected_users()
  error("get_connected_users is not implemented")
  return {}
end

--- Marks a socket as active and associates it with a user ID.
--- @param socket_id string The ID of the socket.
--- @param user_id string The ID of the user associated with the socket.
function BackendStrategy:mark_socket_active(socket_id, user_id)
  assert_type(socket_id, "string", "socket_id")
  assert_type(user_id, "string", "user_id")
  error("mark_socket_active is not implemented")
end

--- Cleans up information about disconnected sockets that have been inactive for a certain duration.
--- @param ttl_seconds number The time-to-live in seconds for inactive sockets.
function BackendStrategy:cleanup_disconnected_sockets(ttl_seconds)
  assert_type(ttl_seconds, "number", "ttl_seconds")
  error("cleanup_disconnected_sockets is not implemented")
end

-------------------------------------------------
-- DATA PERSISTENCE
-------------------------------------------------

--- Persists a key-value pair with an optional time-to-live.
--- @param key string The key to store the value under.
--- @param value table The value to persist.
--- @param ttl_seconds? number Optional time-to-live in seconds for the stored value.
function BackendStrategy:persist_state(key, value, ttl_seconds)
  assert_type(key, "string", "key")
  assert_type(value, "table", "value")
  if ttl_seconds then assert_type(ttl_seconds, "number", "ttl_seconds") end
end

--- Retrieves a persisted value based on its key.
--- @param key string The key of the value to retrieve.
--- @return table|nil The retrieved value, or nil if the key does not exist.
function BackendStrategy:retrieve_state(key)
  assert_type(key, "string", "key")
  return nil
end

--- Deletes a persisted value based on its key.
--- @param key string The key of the value to delete.
function BackendStrategy:delete_state(key)
  assert_type(key, "string", "key")
end

--- Checks if a room with the given ID exists.
--- @param room_id string The ID of the room to check.
--- @return boolean True if the room exists, false otherwise.
function BackendStrategy:room_exists(topic)
  assert_type(topic, "string", "topic")
  error("room_exists is not implemented")
  return false or true -- This should return true if the room exists, false otherwise.
end

--- Creates a new room with the given ID.
--- @param room_id string The ID of the room to create.
function BackendStrategy:create_room(room_id)
  assert_type(room_id, "string", "room_id")
  error("create_room is not implemented")
end

-------------------------------------------------
-- EMBED LOGIC (optional)
-------------------------------------------------

--- Runs a custom script with optional arguments.
--- @param name string The name of the script to run.
--- @param args? table Optional arguments to pass to the script.
function BackendStrategy:run_script(name, args)
  assert_type(name, "string", "name")
  if args ~= nil then assert_type(args, "table", "args") end
end

return BackendStrategy