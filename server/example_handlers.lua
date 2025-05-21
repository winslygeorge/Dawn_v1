-- ws_handlers.lua

local function handle_chat_message(ws, payload, state, shared, topic)
    local user_id = state.user_id
    if user_id and payload.text then
        local message_data = {
            type = "new_message",
            user = user_id,
            text = payload.text
        }
        shared.sockets:broadcast_to_room(topic, message_data)
    end
end

local function handle_chat_join(ws, payload, state, shared, topic)
    local user_id = payload.user_id
    if user_id then
        shared.sockets:identify_user(ws, user_id)
        shared.sockets:join_room(topic, ws, user_id)
        shared.sockets:broadcast_to_room(topic, {
            type = "user_joined",
            user = user_id
        })
    end
end

local function handle_chat_leave(ws, payload, state, shared, topic)
    local user_id = state.user_id
    if user_id then
        shared.sockets:leave_room(topic, ws, user_id)
        shared.sockets:broadcast_to_room(topic, {
            type = "user_left",
            user = user_id
        })
    end
end

local function handle_game_move(ws, payload, state, shared, topic)
    local user_id = state.user_id
    if user_id and payload.move then
        -- Process the game move based on the payload and game state
        -- Example:
        local game = shared.game_state[topic]
        if game then
            -- Update game state
            game[user_id] = payload.move
            -- Broadcast the move to other players in the room
            shared.sockets:broadcast_to_room(topic, {
                type = "player_moved",
                user = user_id,
                move = payload.move
            })
        else
            ws:send('{"error":"Game not found for this room"}')
        end
    end
end

local function handle_game_join(ws, payload, state, shared, topic)
    local user_id = payload.user_id
    if user_id then
        shared.sockets:identify_user(ws, user_id)
        shared.sockets:join_room(topic, ws, user_id)
        -- Initialize game state if it doesn't exist
        shared.game_state[topic] = shared.game_state[topic] or {}
        -- Notify other players about the new joiner
        shared.sockets:broadcast_to_room(topic, {
            type = "player_joined",
            user = user_id
        })
        -- Optionally send the current game state to the new player
        ws:send(cjson.encode({ type = "game_state", state = shared.game_state[topic] }))
    end
end

local function default_handler(ws, payload, state, shared, topic, event)
    print(string.format("[WS] No specific handler for %s/%s", topic, event))
    ws:send('{"error":"No handler for this event"}')
end

return {
    channels = {
        chat = {
            message = handle_chat_message,
            join = handle_chat_join,
            leave = handle_chat_leave,
        },
        game = {
            move = handle_game_move,
            join = handle_game_join,
        },
        __default__ = default_handler,
    }
}