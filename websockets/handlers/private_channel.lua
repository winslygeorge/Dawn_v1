-- Example of a private messaging channel handler
local cjson = require("cjson")
local log_levels = require('utils.logger').LogLevel -- Assuming you have log levels
local PrivateChannel = {}

function PrivateChannel:send_dm(ws, payload, state, shared, topic)
    local sender_id = state.user_id
    local recipient_id = payload.recipient_id
    local text = payload.text

    if not sender_id or not recipient_id or not text then
        ws:send('{"error":"Missing sender_id, recipient_id, or text for DM"}')
        return
    end


    local message = {
        type = "dm",
        sender_id = sender_id,
        text = text
    }

    local recipient_state = shared.players[recipient_id]
    if recipient_state and recipient_state.ws_id then
        if shared.sockets:send_to_user(recipient_state.ws_id, message) then
            -- Optionally send confirmation to sender
            ws:send('{"type":"dm_sent", "recipient_id": "' .. recipient_id .. '"}')
            shared.sockets.logger:log(log_levels.DEBUG, string.format("[DM] User %s -> %s: %s", sender_id, recipient_id, text))
        else
            ws:send('{"error":"Recipient not found or offline"}')
        end
    else
        ws:send('{"error":"Recipient not found or offline"}')
    end
end

return PrivateChannel