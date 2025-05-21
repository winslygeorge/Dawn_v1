-- Example of a "game" channel handler with presence tracking
local cjson = require("cjson")
local log_levels = require('utils.logger').LogLevel -- Assuming you have log levels
local GameChannel = {}

function GameChannel:join(ws, payload, state, shared, topic)
    local game_id = topic -- Assuming topic is the game ID
    local user_id = payload.user_id
    if not user_id then
        ws:send('{"error":"Missing user_id to enter game"}')
        return
    end
    state.user_id = user_id
    shared.sockets:join_room(state.ws_id, topic, ws)
    shared.players[user_id] = state -- Store player state

    local presence_update = {
        type = "event",
        event = "player_entered",
        payload = { user_id = user_id }
    }
    shared.sockets:broadcast_to_room(topic, presence_update)
    shared.sockets.logger:log(log_levels.INFO, string.format("[GAME:%s] Player %s entered", game_id, user_id))

    -- Optionally send current player list
    local players_in_room = {}
    for uid, s in pairs(shared.players) do
        if s and s.rooms and table.find(s.rooms, topic) then
            table.insert(players_in_room, uid)
        end
    end
    ws:send(cjson.encode({ type = "event", event = "current_players", payload = { players = players_in_room } }))
end

function GameChannel:message(ws, payload, state, shared, topic)
    local user_id = state.user_id
    local action_type = payload.action_type
    local action_data = payload.action_data

    if not user_id or not action_type then
        ws:send('{"error":"Missing user_id or action_type"}')
        return
    end

    local action_message = {
        type = "event",
        event = "player_action",
        payload = { user_id = user_id, action_type = action_type, action_data = action_data }
    }
    shared.sockets:broadcast_to_room(topic, action_message)
    shared.sockets.logger:log(log_levels.DEBUG, string.format("[GAME:%s] Player %s action: %s", topic, user_id, action_type))
end

function GameChannel:leave(ws, payload, state, shared, topic)
    local user_id = state.user_id
    if not user_id then return end

    shared.sockets:leave_room(state.ws_id, topic, ws)
    shared.players[user_id] = nil

    local presence_update = {
        type = "event",
        event = "player_exited",
        payload = { user_id = user_id }
    }
    shared.sockets:broadcast_to_room(topic, presence_update)
    shared.sockets.logger:log(log_levels.INFO, string.format("[GAME:%s] Player %s exited", topic, user_id))
end

return GameChannel