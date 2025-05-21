-- dawn_sockets.lua (Enhanced with Phoenix-style Presence + Lifecycle + Timeout + Modular Events)
local Supervisor = require("runtime.loop")
local uv = require("luv")
local cjson = require("cjson")
local Set = require('utils.set')
local state_management = require('websockets.state_management._index')
local handlers = require('websockets.handlers._index')
local WS_OPCODE_PONG = 0xA

local DawnSockets = {}
DawnSockets.__index = DawnSockets

-- Helper function to safely get WebSocket ID
local function get_ws_id(ws)
    local wsget_id = nil
    if ws then
      local get_id_func = getmetatable(ws).get_id
      wsget_id = get_id_func(ws)
    else
      print("Error: WebSocket object is nil or does not have get_id method.")
    end
  
    return wsget_id
end

function DawnSockets:new(parent_supervisor, shared_state, options)
    local self = setmetatable({}, DawnSockets)
    self.supervisor = parent_supervisor 
    self.shared = shared_state or {
        sessions = {},
        players = {},
        metrics = {},
        sockets = self
    }
    self.logger = self.supervisor.logger
    self.handlers = handlers or {}
    self.connections = {}
    self.rooms = {}
    self.presence = {}
    self.state_management =  state_management["__active__"] and state_management["__active__"] or state_management["__default__"]
    self.state_management:init(options.state_management)
    self.private_sockets_connections = {}
    self.shared.sockets = self
    return self
end

function DawnSockets:syncPrivateChat(user_id, ws)
    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end
    self.private_sockets_connections[user_id] = ws_id
end

function DawnSockets:syncPrivateChatLeave(user_id)
    self.private_sockets_connections[user_id] = nil
end

function DawnSockets:getSyncPrivateChatId(user_id)
    return self.private_sockets_connections[user_id]
end

function DawnSockets:getAllsyncPrivateChat()
    return self.private_sockets_connections
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
            local presence = self.presence[topic] and self.presence[topic][ws_id]
            if presence and presence.joined_at and now - presence.joined_at > room_timeout_seconds then
                self:leave_room(topic, conn.ws)
                print("[AUTO-LEAVE] Removing idle", ws_id, "from", topic)
            end
        end
    end
end

function DawnSockets:broadcast_to_room(topic, message_table)
    local encoded = cjson.encode(message_table)
    local room = self.state_management:get_all_presence(topic) or {}
    if not room then return end

    for _, ws_id in ipairs(room) do
        if ws_id and self.connections[ws_id] then
            -- self.connections[ws_id].ws:send(encoded)
            self:send_to_user(ws_id, message_table)
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
    local old_presence = {}
    old_presence = shallow_copy(self.state_management:get_all_presence(topic)) or {}

    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end


    -- self.rooms[topic] = self.rooms[topic] or {}
    -- local room = self.rooms[topic]

    -- for _, sock in ipairs(room) do if sock == ws then already = true break end end
    -- if not already then table.insert(room, ws) end

    local existing = self.state_management:exist_in_presence(topic, ws_id)
    self.state_management:set_presence(topic, ws_id, {
        joined_at = os.time(),
        meta = payload or {},
    }) -- Set presence for the user in the topic
    if self.connections[ws_id] then
        table.insert(self.connections[ws_id].state.rooms, topic)
    end

    local new_presence = shallow_copy(self.state_management:get_all_presence(topic)) or {}
    local diff = self.state_management:diff_presence(topic, old_presence, new_presence)

    if not existing then
        self:broadcast_presence_diff(topic, diff)
    end

    old_presence = nil
    new_presence = nil
    diff = nil
    -- -- Notify the 'join' event handler if it exists
    -- local handler = self.handlers.channels and (self.handlers.channels[topic] or self.handlers.channels["__default__"])
    -- if handler and type(handler["join"]) == "function" then
    --     local conn = self.connections[ws_id]
    --     pcall(handler["join"], self, ws, payload, conn.state, self.shared, topic)
    -- end
end

function DawnSockets:leave_room(topic, ws)
    
    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end
    -- local room = self.rooms[topic]
    -- if room then
    --     for i = #room, 1, -1 do if room[i] == ws then table.remove(room, i) break end end
    --     if #room == 0 then self.rooms[topic] = nil end
    -- end

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
    if not self.state_management:exist_in_presence(topic, ws_id) then
        self:broadcast_presence_diff(topic, diff)
    end
    -- Notify the 'leave' event handler if it exists
    local handler = self.handlers.channels and (self.handlers.channels[topic] or self.handlers.channels["__default__"])
    if handler and type(handler["leave"]) == "function" then
        local conn = self.connections[ws_id]
        pcall(handler["leave"], self, ws, {}, conn.state, self.shared, topic, self.state_management)
    end
end

function DawnSockets:safe_close(ws_id)
    local conn = self.connections[ws_id]
    if conn and not conn.state.closed then
        conn.state.closed = true
        if conn.ws and conn.ws.close then
            if self.connections[ws_id] then
                local rooms = self.state_management:get_all_presence(ws_id) or {}
                for _, topic in ipairs(rooms) do
                    self:leave_room(topic, conn.ws)
                end
                self.shared.metrics.total_connections = (self.shared.metrics.total_connections or 0) - 1
            end
            conn.ws:close()
            print("[WS] Closing connection:", ws_id, "ws:", tostring(conn.ws))
        end
        self:syncPrivateChatLeave(ws_id)
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
        self.connections[ws_id].ws = ws
        return
    end
    if not ws or not ws.send then
        print("[WS] Invalid WebSocket object:", tostring(ws))
        return
    end
    self:setupWsChildProcess(ws_id, ws)

    print("[User socket opened] ", "ws:", tostring(ws), ws_id)
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
                    user_id = nil -- Initially nil, set upon identification
                }
            }


            self.shared.metrics.total_connections = (self.shared.metrics.total_connections or 0) + 1
            return true
        end,
        stop = function()
            print("[WS STOP]", ws_id, "ws:", tostring(ws))
            if(ws and ws.close) then
                self:safe_close(ws_id)
                print("[User socket closed] ", "ws:", tostring(ws))
            end
            self.connections[ws_id] = nil -- Use ws_id as the key
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
    local ok, decoded = pcall(function() return cjson.decode(message) end)
    if not ok then
        ws:send('{"error":"Invalid JSON"}')
        return
    end

    local topic = (decoded.topic or ""):match("^%s*(.-)%s*$")
    local event = decoded.event
    local payload = decoded.payload or {}

    local receiver = payload.receiver

    if not topic or not event then
        ws:send('{"error":"Missing topic or event"}')
        return
    end

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
        end
    end

    local handler_group = self.handlers.channels and (self.handlers.channels[topic] or self.handlers.channels["__default__"])

    -- Pattern match dynamic topics
    if not handler_group and self.handlers.channels then
        for key, handler in pairs(self.handlers.channels) do
            if key:find(":*") then
                local base = key:gsub(":*", ".*") -- Convert `notifications:user:*` to pattern
                if topic:match("^" .. base .. "$") then
                    handler_group = handler
                    break
                end
            end
        end
    end

    if handler_group and type(handler_group[event]) == "function" then
        local success, err = pcall(handler_group[event], self, ws, payload, conn.state, self.shared, topic, self.state_management)
        if not success then
            ws:send(cjson.encode({
                type = "dawn_error",
                topic = topic,
                event = event,
                payload = { reason = err }
            }))
            print("[WS ERROR]", err)
        end
    else
        ws:send(cjson.encode({
            type = "dawn_reply",
            topic = topic,
            event = event,
            payload = { status = "error", reason = "unhandled_event" }
        }))
    end
end

function DawnSockets:send_to_user(ws_unique_identifier, message_table)
    local encoded = cjson.encode(message_table)
    local ws = self.connections[ws_unique_identifier] and self.connections[ws_unique_identifier].ws
    if ws and ws.send then
        ws:send(encoded)
        return true
    else
        local receiver = message_table and message_table.receiver
        if receiver then
            self.state_management:queue_private_message(receiver, message_table)
        end
        print(string.format("[WS] User %s not found or connection lost.", ws_unique_identifier))
        return false
    end
end

function DawnSockets:push_notification(ws, payload)
    local ws_id = get_ws_id(ws)
    if not ws_id then
        error("Error: Unable to get WebSocket ID.")
        return
    end
    return self:send_to_user(ws_id, {
        type = "notification",
        payload = payload,
        timestamp = os.time()
    })
end

function DawnSockets:handle_close(ws, code, reason)
    local ws_id = get_ws_id(ws)
    if ws_id then
        self.supervisor:stopChild({name = ws_id})
        print("[User socket closed] ", "ws:", tostring(ws), "code:", code, "reason:", reason)
    end
end

return DawnSockets