-- websockets/handlers/_index.lua
local cjson = require("cjson")
local uuid = require("utils.uuid")

local room_management = {}

--- Handles the "create_room" event.
function room_management:create_room( ws, payload, state, shared, topic, state_management)
    local ws_id = shared.sockets:safe_get_ws_id(ws)
    if not ws_id then return end

    local room_id = payload.room_id
    if not room_id or room_id == "" then
        shared.sockets:send_to_user(ws_id, {
            type = "dawn_reply",
            topic = "room_management",
            event = "create_room",
            payload = { status = "error", reason = "Room ID cannot be empty." }
        })
        return
    end

    -- Validate room ID (basic example: check for uniqueness)
    if state_management:room_exists(room_id) then
        shared.sockets:send_to_user(ws_id, {
            type = "dawn_reply",
            topic = "room_management",
            event = "create_room",
            payload = { status = "error", reason = "Room ID already exists." }
        })
        return
    end

    -- Create the room
    state_management:create_room(room_id)
    shared.sockets:send_to_user(ws_id, {
        type = "dawn_reply",
        topic = "room_management",
        event = "create_room",
        payload = { status = "ok", room_id = room_id }
    })

    -- Optionally, have the creator automatically join the room
    shared.sockets:join_room(room_id, ws, { creator_id = state.user_id, creator_name = state.user_id or "Anonymous" })
end

local room_handler = {}

--- Handles the "join" event for a room.
function room_handler:join( ws, payload, state, shared, topic, state_management)
    local ws_id = shared.sockets:safe_get_ws_id(ws)
    if not ws_id then return end

    -- Get the user ID (you might have this in your session or authentication)
    local user_id = state.user_id
    local user_name = state.user_id or "Anonymous" -- Get user name

    if not user_id then
        shared.sockets:send_to_user(ws_id, {
            type = "dawn_reply",
            topic = topic, -- The room topic
            event = "join",
            payload = { status = "error", reason = "User not identified." }
        })
        return
    end

    shared.sockets:join_room(topic, ws, { user_id = user_id, user_name = user_name, joined_at = os.time() }) -- Include user name in metadata
    shared.sockets:send_to_user(ws_id, {
        type = "dawn_reply",
        topic = topic,
        event = "join",
        payload = { status = "ok", room_id = topic, message = "Joined room successfully." }
    })
end

--- Handles the "leave" event for a room.
function room_handler:leave( ws, payload, state, shared, topic, state_management)
    local ws_id = shared.sockets:safe_get_ws_id(ws)
    if not ws_id then return end

    shared.sockets:leave_room(topic, ws)
    shared.sockets:send_to_user(ws_id, {
        type = "dawn_reply",
        topic = topic,
        event = "leave",
        payload = { status = "ok", room_id = topic, message = "Left room." }
    })
end

--- Handles the "message" event within a room.
function room_handler:message( ws, payload, state, shared, topic, state_management)
    local sender_id = state.user_id
    local sender_name = state.user_id or "Anonymous"
    if not sender_id then return end

    if not payload or not payload.content then
        shared.sockets:send_to_user(ws, {
            type = "dawn_reply",
            topic = topic,
            event = "message",
            payload = { status = "error", reason = "Message content is required." }
        })
        return
    end

    local message_to_broadcast = {
        id = uuid.v4(),
        type = "room_message",
        topic = topic,
        event = "new_message",
        payload = {
            sender = sender_id,
            sender_id = sender_id,
            sender_name = sender_name, -- Include sender name
            content = payload.content,
            timestamp = os.time(),
        }
    }
    shared.sockets:broadcast_to_room(topic, message_to_broadcast)
end

--- Handles user typing notifications.
function room_handler:typing( ws, payload, state, shared, topic, state_management)
    local sender_id = state.user_id
    if not sender_id then return end

    local typing_message = {
        type = "room_event",
        topic = topic,
        event = "typing",
        payload = {
            sender = sender_id,
            sender_id = sender_id,
            is_typing = payload.is_typing,
        }
    }
    shared.sockets:broadcast_to_room(topic, typing_message)
end

return {room_management, room_handler}
