local cjson = require("cjson")
local uuid = require("utils.uuid")

local ChatHandler = {}

-- This function will be called when the module is required
function ChatHandler:new()
    local self = {}
    setmetatable(self, { __index = ChatHandler })
    return self
end

-- ws, payload, state, shared, topic

-- Event handler for when a user joins a chat room
function ChatHandler:join( ws, payload, state, shared, topic, presence)
    local user_id = state.user_id
    if not user_id then
        shared.sockets:push_notification(ws, {
            id = uuid.v4(),
            topic = topic,
            event = "error",
            data = { message = "User ID not identified before joining chat." }
        })
        return
    end

    local nickname = payload.sender or "Anonymous_" .. user_id:sub(1, 5)

    -- shared.sockets:join_room(topic, ws, { nickname = nickname, user_id = user_id })

    presence:create_room(topic)
    presence:set_presence(topic, shared.sockets:safe_get_ws_id(ws), nickname, { nickname = nickname, user_id = user_id })

    shared.sockets:push_notification(ws, {
        id = uuid.v4(),
        topic = topic,
        event = "system_message",
        data = { message = "Welcome, " .. nickname .. " to " .. topic .. "!" }
    })
end

-- Event handler for when a user sends a message to a chat room
function ChatHandler:message(ws, payload, state, shared, topic, presence)
    local user_id = state.user_id
    if not user_id then
        shared.sockets:push_notification(ws, {
            id = uuid.v4(),
            topic = topic,
            event = "error",
            data = { message = "User ID not identified before sending message." }
        })
        return
    end

    local message_content = payload.body
    if message_content and #message_content > 0 then
        local sender_presence = presence:get_all_presence(topic)[state.ws_id]
        local sender_nickname = sender_presence and sender_presence.meta and sender_presence.meta.nickname or "Unknown"

        local message_to_broadcast = {
            type = "chat_message",
            topic = topic,
            event = "new_message",
            payload = {
                sender_id = user_id,
                sender_nickname = sender_nickname,
                body = message_content,
                sent_at = os.time()
            }
        }
        shared.sockets:broadcast_to_room(topic, message_to_broadcast)

        -- Example of sending an acknowledgement back to the sender
        if payload.client_message_id then
            shared.sockets:send_to_user(state.ws_id, {
                type = "ack",
                topic = topic,
                event = "message_sent",
                ack_id = payload.client_message_id,
                payload = { status = "ok", sent_at_server = os.time() }
            })
        end
    end
end

-- Event handler for when a user leaves a chat room
function ChatHandler:leave( ws, payload, state, shared, topic, presence)
    local user_id = state.user_id
    if user_id then
        local sender_presence = presence:get_all_presence(topic)[state.ws_id]
        local sender_nickname = sender_presence and sender_presence.meta and sender_presence.meta.nickname or "User"

        shared.sockets:leave_room(topic, ws)

        shared.sockets:broadcast_to_room(topic, {
            id = uuid.v4(),
            type = "system_message",
            topic = topic,
            event = "user_left",
            payload = { nickname = sender_nickname, user_id = user_id, left_at = os.time() }
        })
    end
end

-- Event handler for a custom 'typing' indicator
function ChatHandler:typing( ws, payload, state, shared, topic, presence)
    local user_id = state.user_id
    if not user_id then return end

    local sender_presence = presence:get_all_presence(topic)[state.ws_id]
    local sender_nickname = sender_presence and sender_presence.meta and sender_presence.meta.nickname or "User"

    shared.sockets:broadcast_to_room(topic, {
        type = "chat_presence",
        topic = topic,
        event = "user_typing",
        payload = { user_id = user_id, nickname = sender_nickname }
    })
end

-- Event handler for a custom 'stopped_typing' indicator
function ChatHandler:stopped_typing(dawn_sockets, ws, payload, state, shared, topic, presence)
    local user_id = state.user_id
    if not user_id then return end

    shared.sockets:broadcast_to_room(topic, {
        type = "chat_presence",
        topic = topic,
        event = "user_stopped_typing",
        payload = { user_id = user_id }
    })
end

-- Event handler for sending private messages to another user
function ChatHandler:private_message( ws, payload, state, shared, topic, presence)
    local sender_id = state.user_id
    local receiver_id = payload.receiver_id
    local body = payload.body

    if not sender_id then
        shared.sockets:push_notification(ws, {
            topic = "private_chat",
            event = "error",
            data = { message = "Sender ID not identified." }
        })
        return
    end

    if not receiver_id or not body then
        shared.sockets:push_notification(ws, {
            topic = "private_chat",
            event = "error",
            data = { message = "Missing receiver ID or message body." }
        })
        return
    end

    local receiver_ws_id =  shared.sockets:getSyncPrivateChatId(receiver_id)
    local sender_presence = presence:get_all_presence(topic)[state.ws_id]
    local sender_nickname = sender_presence and sender_presence.meta and sender_presence.meta.nickname or "User"

    if receiver_ws_id then
        shared.sockets:send_to_user(receiver_ws_id, {
            type = "chat_message",
            topic = "private_chat",
            event = "new_private_message",
            payload = {
                sender_id = sender_id,
                sender_nickname = sender_nickname,
                body = body,
                sent_at = os.time()
            }
        })
        -- Optionally send confirmation to the sender
        if payload.client_message_id then
            shared.sockets:send_to_user(state.ws_id, {
                type = "ack",
                topic = "private_chat",
                event = "private_message_sent",
                ack_id = payload.client_message_id,
                payload = { status = "ok", receiver = receiver_id, sent_at_server = os.time() }
            })
        end
    else
        -- Handle offline private messages (using the queuing mechanism in DawnSockets)
        shared.sockets:send_to_user(receiver_id, { -- Sending to user_id will trigger queuing if offline
            type = "chat_message",
            topic = "private_chat",
            event = "new_private_message",
            sender = sender_id,
            payload = {
                sender_id = sender_id,
                sender_nickname = sender_nickname,
                body = body,
                sent_at = os.time()
            }
        })
        shared.sockets:push_notification(ws, {
            topic = "private_chat",
            event = "system_message",
            data = { message = "User " .. receiver_id .. " is offline. Message will be delivered when they are online." }
        })
    end
end

-- Event handler for a user setting their nickname in the chat room
function ChatHandler:set_nickname(dawn_sockets, ws, payload, state, shared, topic, presence)
    local user_id = state.user_id
    local new_nickname = payload.nickname

    if not user_id or not new_nickname or #new_nickname == 0 then
        dawn_sockets:push_notification(ws, {
            topic = topic,
            event = "error",
            data = { message = "Invalid nickname provided." }
        })
        return
    end

    local old_presence = presence:get_all_presence(topic)[state.ws_id]
    local old_nickname = old_presence and old_presence.meta and old_presence.meta.nickname or "User"

    presence:set_presence(topic, state.ws_id, { nickname = new_nickname, user_id = user_id })

    dawn_sockets:broadcast_to_room(topic, {
        type = "chat_presence",
        topic = topic,
        event = "nickname_updated",
        payload = { user_id = user_id, old_nickname = old_nickname, new_nickname = new_nickname }
    })

    dawn_sockets:push_notification(ws, {
        topic = topic,
        event = "system_message",
        data = { message = "Your nickname has been updated to: " .. new_nickname }
    })
end

-- Event handler for requesting the list of users in the current chat room
function ChatHandler:get_user_list( ws, payload, state, shared, topic, presence)
    local users = {}
    local room_presence = presence:get_all_presence(topic)
    if room_presence then
        for ws_id, presence_data in pairs(room_presence) do
            table.insert(users, presence_data.meta)
        end
    end

    shared.sockets:send_to_user(state.ws_id, {
        id = payload.id,
        type = "dawn_reply",
        topic = topic,
        event = "user_list",
        payload = { users = users }
    })
end

-- Event handler that runs before a WebSocket connection is closed for this channel
function ChatHandler:before_close(dawn_sockets, ws, state, shared, topic, presence)
    local user_id = state.user_id
    if user_id then
        local sender_presence = presence:get_all_presence(topic)[state.ws_id]
        local sender_nickname = sender_presence and sender_presence.meta and sender_presence.meta.nickname or "User"
        dawn_sockets:broadcast_to_room(topic, {
            type = "system_message",
            topic = topic,
            event = "user_disconnected",
            payload = { nickname = sender_nickname, user_id = user_id, disconnected_at = os.time() }
        })
    end
end

return ChatHandler