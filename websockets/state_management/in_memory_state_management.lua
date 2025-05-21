local cjson = require("cjson")
local BackendStrategy = require("server.websockets.presence_interface")
--- @class InMemoryBackend : BackendStrategy
local InMemoryBackend = {}
setmetatable(InMemoryBackend, { __index = BackendStrategy })

--- Creates a new instance of InMemoryBackend.
--- @return InMemoryBackend The new instance.
function InMemoryBackend:new()
  local instance = setmetatable({}, self)
  instance:init({}) -- InMemoryBackend doesn't need specific config in init

  return instance
end

local pubsub = {}
local presence = {}
local statuses = {}
local private_messages = {}
local queued_messages = {}
local room_queues = {}
local persistent_state = {}
local socket_activity = {}

--- Initializes the in-memory backend.
--- @param config table An empty configuration table (not used by InMemoryBackend).
function InMemoryBackend:init(config)
  -- No specific initialization needed for in-memory
end

-------------------------------------------------
-- PUB/SUB (in-memory, callback-based)
-------------------------------------------------

--- Subscribes a callback function to a specific topic.
--- @param topic string The topic to subscribe to.
--- @param callback function The function to call when a message is published to the topic.
function InMemoryBackend:subscribe(topic, callback)
  pubsub[topic] = pubsub[topic] or {}
  table.insert(pubsub[topic], callback)
end

--- Publishes a message to a specific topic.
--- @param topic string The topic to publish to.
--- @param message table The message to publish.
function InMemoryBackend:publish(topic, message)
  local subs = pubsub[topic] or {}
  for _, cb in ipairs(subs) do
    cb(message)
  end
end

--- Unsubscribes from a specific topic.
--- @param topic string The topic to unsubscribe from.
function InMemoryBackend:unsubscribe(topic)
  pubsub[topic] = nil
end

-------------------------------------------------
-- STATE MANAGEMENT
-------------------------------------------------

--- Sets the status of a user.
--- @param user_id string The ID of the user.
--- @param status string The new status of the user (e.g., "online", "offline", "away").
function InMemoryBackend:set_user_status(user_id, status)
  statuses[user_id] = status
end

--- Sets the presence information for a user on a specific topic.
--- @param topic string The topic the user is present on.
--- @param ws_id string The ID of the user's websocket identifier.
--- @param meta table Additional metadata associated with the user's presence.
--- @param user_id string The ID of the user (not used in this in-memory implementation).
function InMemoryBackend:set_presence(topic, ws_id, user_id, meta)
  if not ws_id then return end
  if not meta then meta = {} end
  if user_id then
    if self:exist_in_presence(ws_id, topic) then
      self:remove_presence(topic, ws_id)
    end
   
  presence[topic] = presence[topic] or {}
   if not (presence[topic][user_id]) then
    presence[topic][user_id] = meta
    end
  else
    presence[topic] = presence[topic] or {}
    if not (presence[topic][ws_id]) then
    presence[topic][ws_id] = meta
    end
  end
end

function InMemoryBackend:exist_in_presence(ws_id, topic)
  return presence[topic] and presence[topic][ws_id] ~= nil
end

--- Removes the presence information for a user from a specific topic.
--- @param topic string The topic to remove the user's presence from.
--- @param ws_id string The ID of the user\'s websocket identifier'.
function InMemoryBackend:remove_presence(topic, ws_id)
  local user_id = self:get_ws_id_binded_user_id(ws_id)
  if presence[topic] and presence[topic][ws_id] then
    presence[topic][ws_id] = nil
    if not next(presence[topic]) then presence[topic] = nil end 
  end
  if user_id and presence[topic] and presence[topic][user_id] then
    presence[topic][user_id] = nil
    if not next(presence[topic]) then presence[topic] = nil end 
  end
end

--- Gets the presence information for all users on a specific topic.
--- @param topic string The topic to retrieve presence information for.
--- @return table A table where keys are user IDs and values are their metadata.
function InMemoryBackend:get_all_presence(topic)
  return presence[topic] or {}
end

--- Computes the difference between two presence states for a topic.
--- @param topic string The topic to compare presence states for.
--- @param old_state table The previous presence state (user ID to metadata).
--- @param new_state table The current presence state (user ID to metadata).
--- @return table A table containing two lists: `joins` (user IDs who joined) and `leaves` (user IDs who left).
function InMemoryBackend:diff_presence(topic, old_state, new_state)
  local joins, leaves = {}, {}

  for uid, meta in pairs(new_state) do
    if not old_state[uid] then joins[uid] = meta end
  end
  for uid, meta in pairs(old_state) do
    if not new_state[uid] then leaves[uid] = meta end
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
function InMemoryBackend:store_private_message(from_id, to_id, message)
  private_messages[to_id] = private_messages[to_id] or {}
  table.insert(private_messages[to_id], { from = from_id, message = message })
end

--- Fetches the history of private messages for a specific user.
--- @param user1 string The ID of the first user (not directly used in this in-memory implementation).
--- @param user2 string The ID of the second user whose received messages are fetched.
--- @param opts? table Optional parameters for fetching history (not used in this in-memory implementation).
--- @return table A table containing the history of messages received by `user2`. Each entry is `{ from = sender_id, message = message_content }`.
function InMemoryBackend:fetch_private_history(user1, user2, opts)
  return private_messages[user2] or {}
end

--- Queues a private message to be delivered to a user.
--- @param receiver string The ID of the recipient.
--- @param message table The message to queue.
function InMemoryBackend:queue_private_message(receiver, message)
  queued_messages[receiver] = queued_messages[receiver] or {}
  table.insert(queued_messages[receiver], message)
end

--- Fetches all queued private messages for a user.
--- @param user_id string The ID of the user.
--- @return table A table containing the queued messages for the user.
function InMemoryBackend:fetch_queued_messages(user_id)
  return queued_messages[user_id] or {}
end

--- Clears all queued private messages for a user.
--- @param user_id string The ID of the user.
function InMemoryBackend:clear_queued_messages(user_id)
  queued_messages[user_id] = nil
end

-------------------------------------------------
-- ROOM MESSAGES
-------------------------------------------------

--- Queues a message to be distributed to all participants in a room or channel.
--- @param topic string The topic of the room or channel.
--- @param message table The message to queue.
function InMemoryBackend:queue_room_message(topic, message)
  room_queues[topic] = room_queues[topic] or {}
  table.insert(room_queues[topic], message)
end

--- Drains all queued messages for a specific room or channel.
--- @param topic string The topic of the room or channel.
--- @return table A table containing the drained messages. This table is emptied after retrieval.
function InMemoryBackend:drain_room_messages(topic)
  local messages = room_queues[topic] or {}
  room_queues[topic] = {}
  return messages
end

-------------------------------------------------
-- SCALABILITY
-------------------------------------------------

--- Gets a list of all currently connected user IDs.
--- @return table A table containing the IDs of connected users.
function InMemoryBackend:get_connected_users()
  local result = {}
  for k, v in pairs(socket_activity) do
    table.insert(result, k)
  end
  return result
end

--- Marks a socket as active and associates it with a user ID.
--- @param ws_id string The ID of the web socket.
--- @param user_id string The ID of the user associated with the socket.
function InMemoryBackend:mark_socket_active(ws_id, user_id)
  socket_activity[user_id] = { ws_id = ws_id, last_active = os.time() }
  self:set_user_status(user_id, "online")
end

---return marked sockets

function InMemoryBackend:get_user_binded_socket_id(user_id)
  local socket = socket_activity[user_id]
  if socket then
    return socket.ws_id
  end
  return nil
end

---return ws_id binded to a user_id from the user_id

function InMemoryBackend:get_ws_id_binded_user_id(ws_id)
  for user_id, socket in pairs(socket_activity) do
    if socket.ws_id == ws_id then
      return user_id
    end
  end
  return nil
end

--- Cleans up information about disconnected sockets that have been inactive for a certain duration.
--- @param ttl_seconds number The time-to-live in seconds for inactive sockets.
function InMemoryBackend:cleanup_disconnected_sockets(ttl_seconds)
  local now = os.time()
  for id, meta in pairs(socket_activity) do
    if now - meta.last_active > ttl_seconds then
      socket_activity[id] = nil
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
function InMemoryBackend:persist_state(key, value, ttl_seconds)
  persistent_state[key] = { value = value, expires = ttl_seconds and (os.time() + ttl_seconds) or nil }
end

--- Retrieves a persisted value based on its key.
--- @param key string The key of the value to retrieve.
--- @return table|nil The retrieved value, or nil if the key does not exist or has expired.
function InMemoryBackend:retrieve_state(key)
  local entry = persistent_state[key]
  if not entry then return nil end
  if entry.expires and os.time() > entry.expires then
    persistent_state[key] = nil
    return nil
  end
  return entry.value
end

--- Deletes a persisted value based on its key.
--- @param key string The key of the value to delete.
function InMemoryBackend:delete_state(key)
  persistent_state[key] = nil
end

-------------------------------------------------
-- EMBEDDED LOGIC (NOOP)
-------------------------------------------------

--- Runs a custom script with optional arguments (in-memory implementation does a no-op with a print).
--- @param name string The name of the script to run.
--- @param args? table Optional arguments to pass to the script.
function InMemoryBackend:run_script(name, args)
  print("Running script:", name, args)
end

-------------------------------------------------
-- Room Management (For Dynamic Rooms)
-------------------------------------------------

--- Checks if a room with the given ID exists.
--- @param room_id string The ID of the room to check.
--- @return boolean True if the room exists, false otherwise.
function InMemoryBackend:room_exists(room_id)
  return presence[room_id] ~= nil
end

--- Creates a new room with the given ID.
--- @param room_id string The ID of the room to create.
function InMemoryBackend:create_room(room_id)
    if not room_id then
    error("Room ID cannot be nil")
  end
  presence[room_id] = {}
  return true
end

-- You might also want to add functions to:
-- -  Get room details (e.g., creation time)
-- -  List rooms
-- -  Delete rooms (if you want room persistence with deletion)

return InMemoryBackend
