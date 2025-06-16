-- dawn_sockets.lua (Enhanced with Phoenix-style Presence + Lifecycle + Timeout + Modular Events + Ack + Binary + Dynamic Rooms + Message Queuing)
local uv = require("luv")
local cjson = require("dkjson")
local uuid = require('utils.uuid')
local log_level = require('utils.logger').LogLevel

local WS_OPCODE_PONG = 0xA
local WS_OPCODE_BINARY = 2 -- Custom opcode for binary messages

local DawnSockets = {}
DawnSockets.__index = DawnSockets

-- Helper function to safely get WebSocket ID
local function get_ws_id(ws)
    if ws then
        local get_id_func = getmetatable(ws).get_id
        return get_id_func(ws)
    else
        print("Error: WebSocket object is nil or does not have get_id method.")
        return nil
    end
end

function DawnSockets:new(parent_supervisor, shared_state, options)
    local self = setmetatable({}, DawnSockets)
    self.supervisor = parent_supervisor
    self.shared = shared_state or {
        sessions = {},
        players = {},
        metrics = {},
        sockets = self,
        pending_acknowledgements = {} -- Store pending acknowledgements (ws_id -> message_id -> callback)
    }
    self.logger = self.supervisor.logger
    self.handlers = options.handlers or {}
    self.connections = {}

    -- Use the provided state_management or default to InMemoryBackend
    self.state_management =  options.state.state_management["__active__"] and options.state.state_management["__active__"] or options.state.state_management["__default__"]
    self.state_management = self.state_management or options.state.state_management["__default__"]:new()
    self.state_management:init(options.state_management or {})

    self.shared.sockets = self

    -- Initialize pubsub (using InMemoryBackend's methods)
    self.pubsub = {}
    self.pubsub.subscribe = function(topic, callback)
        self.state_management:subscribe(topic, callback)
    end
    self.pubsub.publish = function(topic, message)
        self.state_management:publish(topic, message)
    end
    self.pubsub.unsubscribe = function(topic)
        self.state_management:unsubscribe(topic)
    end
    return self
end

function DawnSockets:safe_get_ws_id(ws)
    return get_ws_id(ws)
end

function DawnSockets:syncPrivateChat(user_id, ws)
    print("Setting sync private chat")
    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end

--- if payload.sender not nil or '' then close the old connection 
    --- and set the new connection
    --- if payload.sender ~= conn.state.user_id then
    local old_ws_id = self:getSyncPrivateChatId(user_id)

    if old_ws_id and old_ws_id ~= ws_id then
        self.state_management:remove_presence("", old_ws_id, true)
        self.connections[old_ws_id] = nil
    end

    self.state_management:mark_socket_active(ws_id, user_id)
end

function DawnSockets:reloadPersistedRoomMembers()
    self.state_management:reloadPersistedRoomMembers()
end

function DawnSockets:syncPrivateChatLeave(user_id)
    -- No need to clear user_socket binding here.  State management handles this.
end

function DawnSockets:getSyncPrivateChatId(user_id)
    return self.state_management:get_user_binded_socket_id(user_id) or nil
end

function DawnSockets:getSyncPrivateUserID(ws_id)
    if not ws_id then
        return nil
    end
    return self.state_management:get_ws_id_binded_user_id(ws_id) or nil
end

function DawnSockets:getAllsyncPrivateChat()
    return self.state_management:get_connected_users() or {}
end

local function shallow_copy(orig)
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = v
    end
    return copy
end

function DawnSockets:start_heartbeat(interval, timeout)
    interval = interval or 15000
    timeout = timeout or 30
    local hb_timer = uv.new_timer()
    uv.timer_start(hb_timer, 0, interval, function()
        self:send_heartbeats()
        self:cleanup_stale_clients(timeout)
        self:auto_leave_idle_clients(300) -- 5 min idle leave
    end)
    print(string.format("[HEARTBEAT] Started: every %dms, timeout: %ds", interval, timeout))
end

function DawnSockets:send_heartbeats()
    for ws_id, conn in pairs(self.connections) do
        if conn and conn.ws then
            conn.ws:send('{"type":"ping"}')
        end
    end
end

function DawnSockets:cleanup_stale_clients(timeout_seconds)
    local now = os.time()
    local stale_ws_ids = {}
    for ws_id, conn in pairs(self.connections) do
        local last = conn.state.last_pong or conn.state.last_message or 0
        if now - last > timeout_seconds then
            print("[HEARTBEAT] Stale connection closing:", tostring(conn.ws), "(ID:", ws_id, ")")
            table.insert(stale_ws_ids, ws_id)
            if conn.ws then
                self:safe_close(ws_id)
            end
        end
    end
    for _, id in ipairs(stale_ws_ids) do
        self.connections[id] = nil
    end
end

function DawnSockets:auto_leave_idle_clients(room_timeout_seconds)
    local now = os.time()
    for ws_id, conn in pairs(self.connections) do
        for _, topic in ipairs(conn.state.rooms or {}) do
            -- Use state_management for presence check
            if self.state_management:exist_in_presence(ws_id, topic) then
                local presence_data = self.state_management:get_all_presence(topic)[ws_id]
                if presence_data and presence_data.joined_at and now - presence_data.joined_at > room_timeout_seconds then
                    self:leave_room(topic, conn.ws)
                    print("[AUTO-LEAVE] Removing idle", ws_id, "from", topic)
                end
            end
        end
    end
end

-- function DawnSockets:broadcast_to_room(topic, message_table)
--     print("Broadcasting to room:", topic, "message:", message_table)
--     local room = self.state_management:get_all_presence(topic) or {}
--     if not room then return end

--     if message_table then
--         message_table.id = message_table.id or uuid.v4() -- Generate a unique ID for the message
--     end

--     for ws_id, _ in pairs(room) do
--         if not message_table.receiver then
--            message_table.receiver = self:getSyncPrivateUserID(ws_id)
--         end
--         self:send_to_user(ws_id, message_table)
--     end
-- end

function DawnSockets:broadcast_to_room(topic, message_table)
    local room = self.state_management:get_all_presence(topic) or {}
    if not room then return end

    if message_table then
        message_table.id = message_table.id or uuid.v4()
    end

    for ws_id, _ in pairs(room) do
        local existing_user_id = self:getSyncPrivateChatId(ws_id) or ws_id
        local receiver_user_id = self:getSyncPrivateUserID(ws_id) or ws_id -- Get the user_id *inside* the loop
        if receiver_user_id then
            message_table.receiver = receiver_user_id
            self:send_to_user(existing_user_id, message_table)
        end
    end
end

function DawnSockets:broadcast_presence_diff(topic, diff)
    local message = {
        type = "presence_diff",
        topic = topic,
        joins = diff.joins,
        leaves = diff.leaves,
    }
    self:broadcast_to_room(topic, message)
end

function DawnSockets:join_room(topic, ws, payload)
    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end

    if self.state_management:room_exists(topic) == false then
        self.logger:log(log_level.WARN, string.format("[ROOM] Room %s does not exist when %s tried to join.", topic, ws_id), "DawnSockets")
        -- Room does not exist, create it
        local success, err = self.state_management:create_room(topic)
        if not success then
            self.logger:log(log_level.ERROR, string.format("[ROOM] Error creating room %s: %s", topic, err), "DawnSockets")
            return
        end
        if self.connections[ws_id] then
            self.connections[ws_id].state.rooms = self.connections[ws_id].state.rooms or {}
            if not self.connections[ws_id].state.rooms[topic] then
                table.insert(self.connections[ws_id].state.rooms, topic)
            end
        end
        self.logger:log(log_level.INFO, string.format("[ROOM] Room %s created successfully.", topic), "DawnSockets")
        self:send_to_user(ws_id, {
            type = "dawn_error",
            topic = topic,
            event = "join_error",
            payload = { reason = "room_not_found but its been created instead - "..topic },
        })

        return
    end

    local old_presence = shallow_copy(self.state_management:get_all_presence(topic)) or {}
        local user_id = self:getSyncPrivateUserID(ws_id) or nil

    local existing = self.state_management:exist_in_presence(ws_id, topic)
    local user_existing = self.state_management:exist_in_presence(user_id, topic)


    self.state_management:set_presence(topic, ws_id, user_id, {
        joined_at = os.time(),
        meta = payload or {},
    }) -- Set presence

    if self.connections[ws_id] then
        self.connections[ws_id].state.rooms = self.connections[ws_id].state.rooms or {}
        if not self.connections[ws_id].state.rooms[topic] then
            table.insert(self.connections[ws_id].state.rooms, topic)
        end
    end

    local new_presence = shallow_copy(self.state_management:get_all_presence(topic)) or {}
    local diff = self.state_management:diff_presence(topic, old_presence, new_presence)

    if (not existing or existing == false) and (not user_existing or user_existing == false) then
        self:broadcast_presence_diff(topic, diff)
        local receiver = payload and payload.receiver or self:getSyncPrivateUserID(ws_id)
        self:send_to_user(ws_id, {
            id = uuid.v4(),
            receiver = receiver,
            type = "presence_state",
            topic = topic,
            payload = self.state_management:get_all_presence(topic),
        })
    end
    -- Notify the 'join' event handler
    local handler =
        self.handlers.channels and (self.handlers.channels[topic] or self.handlers.channels["__default__"])
    if handler and type(handler["join"]) == "function" then
        local conn = self.connections[ws_id]
        pcall(handler["join"], self, ws, payload, conn.state, self.shared, topic, self.state_management)
    end
end

function DawnSockets:leave_room(topic, ws)
    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end

    local old_presence = shallow_copy(self.state_management:get_all_presence(topic)) or {}
    self.state_management:remove_presence(topic, ws_id)

    if self.connections[ws_id] and self.connections[ws_id].state then
        for i = #self.connections[ws_id].state.rooms, 1, -1 do
            if self.connections[ws_id].state.rooms[i] == topic then
                table.remove(self.connections[ws_id].state.rooms, i)
                break
            end
        end
    end

    local new_presence = shallow_copy(self.state_management:get_all_presence(topic)) or {}
    local diff = self.state_management:diff_presence(topic, old_presence, new_presence)

    if not self.state_management:exist_in_presence(ws_id, topic) then
        self:broadcast_presence_diff(topic, diff)
    end

    -- Notify the 'leave' event handler
    local handler =
        self.handlers.channels and (self.handlers.channels[topic] or self.handlers.channels["__default__"])
    if handler and type(handler["leave"]) == "function" then
        local conn = self.connections[ws_id]
        pcall(handler["leave"], self, ws, {}, conn.state, self.shared, topic, self.state_management)
    end
end

function DawnSockets:safe_close(ws_id)
    local conn = self.connections[ws_id]
    if conn and not conn.state.closed then
        conn.state.closed = true

        -- === [NEW] Call before_close hooks for each room the user was in ===
        local rooms = conn.state.rooms or {}

        for _, topic in ipairs(rooms) do

            local handler =
                self.handlers.channels and (self.handlers.channels[topic] or self.handlers.channels["__default__"])
            if handler and type(handler["before_close"]) == "function" then
                pcall(handler["before_close"], self, conn.ws, conn.state, self.shared, topic, self.state_management)
            end
        end
        if conn.ws and conn.ws.close then
            self.shared.metrics.total_connections = (self.shared.metrics.total_connections or 0) - 1
            conn.ws:close()
            print("[WS] Closing connection:", ws_id, "ws:", tostring(conn.ws))
        end

        self.connections[ws_id] = nil
    end
end

-- This function is used to handle the opening of a WebSocket connection.
function DawnSockets:handle_open(ws)
    local ws_id = get_ws_id(ws)
    if not ws_id then
        print("Error: Unable to get WebSocket ID.")
        return
    end

    if self.connections[ws_id] then
        self:safe_close(ws_id)
        self.connections[ws_id].ws = ws;
        return
    end

    if not ws or not ws.send then
        print("[WS] Invalid WebSocket object:", tostring(ws))
        return
    end

    self:setupWsChildProcess(ws_id, ws)
end

function DawnSockets:setupWsChildProcess(ws_id, ws)
    local child = {
        name = ws_id,
        restart_policy = "transient",
        restart_count = 5,
        backoff = 1000,
        start = function()
            self.connections[ws_id] = {
                ws = ws,
                ws_id = ws_id,
                state = {
                    connected_at = os.time(),
                    last_message = os.time(),
                    last_pong = nil,
                    rooms = {},
                    user_id = nil, -- Initially nil, set upon identification
                    pending_acks = {}
                }
            }
            self.shared.metrics.total_connections = (self.shared.metrics.total_connections or 0) + 1
            return true
        end,
        stop = function()
            print("[WS STOP]", ws_id, "ws:", tostring(ws))
            if (ws and ws.close) then
                self:safe_close(ws_id)
                print("[User socket closed] ", "ws:", tostring(ws))
            end
            self.connections[ws_id] = nil
            return true
        end,
        restart = function()
            print("[WS RESTART]", ws_id, "ws:", tostring(ws))
            return true
        end,
    }
    self.supervisor:startChild(child)
end

function DawnSockets:handle_message(ws, message, opcode)
    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end
    local conn = self.connections[ws_id]
    if not conn then
        error("Error: Connection not found for ID: " .. ws_id)
        return
    elseif not conn.ws then
        error("Error: WebSocket object not found for ID: " .. ws_id)
        return
    else
        conn.state.last_message = os.time()
        if opcode == WS_OPCODE_PONG then
            conn.state.last_pong = os.time()
            return
        elseif opcode == WS_OPCODE_BINARY then
            -- Handle binary message
            local handler_group =
                self.handlers.channels and self.handlers.channels["binary"] and
                (self.handlers.channels["binary"] or self.handlers.channels["__default__"])
            if handler_group and type(handler_group["message"]) == "function" then
                local success, err = pcall(handler_group["message"], self, ws, message, conn.state, self.shared)
                if not success then
                    print("[BINARY ERROR]", err)
                end
            else
                print("[BINARY] No handler for binary message")
            end
            return
        else -- Assume text message (JSON)
            local ok, decoded = pcall(function()
                return cjson.decode(message)
            end)
            if not ok then
                ws:send('{"error":"Invalid JSON"}')
                return
            end
            local topic = (decoded.topic or ""):match("^%s*(.-)%s*$")
            local event = decoded.event
            local payload = decoded.payload or {}
            local ack_id = decoded.ack_id
            decoded.message_id = decoded.message_id or uuid.v4()

            if event == "ack" and ack_id then
                -- Handle acknowledgement from client
                local pending_callbacks = self.shared.pending_acknowledgements[ws_id]
                if pending_callbacks and pending_callbacks[ack_id] then
                    local callback = table.remove(pending_callbacks, ack_id)
                    if callback then
                        pcall(callback, payload)
                    end
                    if next(pending_callbacks) == nil then
                        self.shared.pending_acknowledgements[ws_id] = nil
                    end
                end
                return
            end

            if not topic or not event then
                ws:send('{"error":"Missing topic or event"}')
                return
            end

            if event == "join" and payload.sender then

                conn.state.user_id = payload.sender or conn.state.user_id
                conn.state.status = "online"
                self.state_management:set_user_status(payload.sender, conn.state.status)
                -- Retrieve queued messages and send them upon successful join.
                local queued_messages = self.state_management:fetch_queued_messages(conn.state.user_id)
                if queued_messages and #queued_messages > 0 then
                    for _, msg in ipairs(queued_messages) do
                        msg.receiver = conn.state.user_id;
                        msg.id = uuid.v4();
                        self:send_to_user(ws_id, msg)
                    end
                    self.state_management:clear_queued_messages(conn.state.user_id)
                end
                self:syncPrivateChat(payload.sender, ws)
            end

            local handler_group =
                self.handlers.channels and (self.handlers.channels[topic] or self.handlers.channels["__default__"])

            if not self.handlers.channels[topic] and self.handlers.channels then
                for key, handler in pairs(self.handlers.channels) do
                    local pattern = "^" .. key:gsub(":", "%%:"):gsub("%*", ".*") .. "$"
                    if topic:match(pattern) then
                        handler_group = handler
                        break
                    end
                end
            end

            if handler_group and type(handler_group[event]) == "function" then
                local success, err =
                    pcall(handler_group[event], self, ws, payload, conn.state, self.shared, topic, self.state_management)
                if not success then
                    ws:send(cjson.encode({
                        type = "dawn_error",
                        topic = topic,
                        event = event,
                        payload = { reason = err },
                    }))
                    print("[WS ERROR]", err)
                end
            else
                ws:send(cjson.encode({
                    type = "dawn_reply",
                    topic = topic,
                    event = event,
                    payload = { status = "error", reason = "unhandled_event" },
                }))
            end
        end
    end
end

function DawnSockets:send_to_user(ws_unique_identifier, message_table, ack_callback)
    local encoded = cjson.encode(message_table)
    print("Sending message to user:", ws_unique_identifier, "message:", encoded)
    local ws = self.connections[ws_unique_identifier] and self.connections[ws_unique_identifier].ws
    print("WebSocket object:", tostring(ws))
    local receiver = message_table and message_table.receiver or nil
    local sender = message_table and message_table.sender or nil
    local message_id = message_table.id
    print("Message ID:", message_id, "Receiver:", receiver, "Sender:", sender, ws_unique_identifier)
    if receiver and sender then
        local user_status = self.state_management:get_user_status(receiver) or nil
        print("User status:", user_status, "Receiver:", receiver, "Sender:", sender)
        if user_status and user_status == "offline" then
            self.state_management:queue_private_message(receiver, message_table)
            print(string.format("[WS] User %s is offline. Message (ID: %s) queued.", receiver, message_id))
            return false
        elseif user_status and user_status == "away" then
            local sender_ws_id = self:getSyncPrivateChatId(sender)
            local sender_ws = self.connections[sender_ws_id] and self.connections[sender_ws_id].ws
            if sender_ws and sender_ws.send then
                sender_ws:send(cjson.encode({
                    type = "dawn_reply",
                    topic = "system",
                    event = "away",
                    payload = { status = "error", reason = sender .. " is user_away" },
                }))
            end
        end
    end

    if ws and ws.send then
        ws:send(encoded)
        if ack_callback and message_id then
            self.shared.pending_acknowledgements[ws_unique_identifier] =
                self.shared.pending_acknowledgements[ws_unique_identifier] or {}
            self.shared.pending_acknowledgements[ws_unique_identifier][message_id] = ack_callback
            uv.timer_start(uv.new_timer(), 5000, 0, function()
                if self.shared.pending_acknowledgements[ws_unique_identifier] and
                    self.shared.pending_acknowledgements[ws_unique_identifier][message_id] then
                    local callback =
                        table.remove(self.shared.pending_acknowledgements[ws_unique_identifier], message_id)
                    if callback then
                        pcall(callback, { error = "acknowledgement_timeout" })
                    end
                    if next(self.shared.pending_acknowledgements[ws_unique_identifier]) == nil then
                        self.shared.pending_acknowledgements[ws_unique_identifier] = nil
                    end
                end
            end)
        end
        return true
    else
        if (receiver) then
            print("Receiver user ID:", receiver, "Sender user ID:", sender)
            self.state_management:queue_private_message(receiver, message_table)
            print(string.format("[WS]No Receiver User %s is offline. Message (ID: %s) queued.", receiver, message_id))
            return false
        else
           print("[WS] Invalid WebSocket object:", tostring(ws), "Message (ID: %s) not sent.", message_id)
        end
        return false
    end
end

function DawnSockets:send_binary_to_user(ws_unique_identifier, binary_data)
    local ws = self.connections[ws_unique_identifier] and self.connections[ws_unique_identifier].ws
    if ws and ws.send then
        ws:send(binary_data, "binary")
        return true
    else
        print("[WS] Invalid WebSocket object:", tostring(ws), "Binary message not sent.")
        return false
    end
end

function DawnSockets:push_notification(ws, payload)
    local ws_id = get_ws_id(ws)
    if not ws_id then return false end
    local receiver = payload.receiver or self:getSyncPrivateUserID(ws_id)
    return self:send_to_user(ws_id, {
        id = payload.id or uuid.v4(),
        receiver = receiver,
        type = "notification",
        topic = payload.topic or "system",
        event = payload.event or "push",
        payload = payload.data or {}
    })
end

function DawnSockets:handle_close(ws, code, reason)
    local ws_id = get_ws_id(ws)
    if ws_id then
        local user_id = self:getSyncPrivateUserID(ws_id) or nil
        if user_id then
            self.state_management:set_user_status(user_id, "offline")
        end
        if (self.shared.pending_acknowledgements and self.shared.pending_acknowledgements[ws_id]) then
          self.shared.pending_acknowledgements[ws_id] = nil
        end
        self.supervisor:stopChild({ name = ws_id })
        print("[User socket closed] ", "ws:", tostring(ws), "code:", code, "reason:", reason)
    end
end

-- Helper function
function DawnSockets:room_exists(room_id)
    return self.state_management:room_exists(room_id)
end

-- Helper function
function DawnSockets:create_room(room_id, options)
    local success, err = self.state_management:create_room(room_id, options)
    if success then
        self.logger:log(log_level.INFO, string.format("[ROOM] Created room: %s", room_id), "DawnSockets")
        return true
    else
        self.logger:log(log_level.ERROR, string.format("[ROOM] Error creating room %s: %s", room_id, err), "DawnSockets")
        return false
    end
end

return DawnSockets
