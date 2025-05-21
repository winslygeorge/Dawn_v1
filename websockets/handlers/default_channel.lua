-- Default handler for ping
local cjson = require("cjson")
local DefaultHandlers = {}

 DefaultHandlers = {
    ping = function(ws, payload, state, shared, topic)
        ws:send('{"type":"pong"}')
        state.last_pong = os.time() -- Update last pong time
        shared.sockets.logger:debug(string.format("[DEFAULT] Received ping from %s", state.ws_id))
    end,
    -- Example of handling an unknown event
    unknown = function(ws, payload, state, shared, topic)
        ws:send(cjson.encode({ error = "Unknown event for this topic", event = payload.event }))
        print(string.format("[DEFAULT] Unknown event '%s' on topic '%s' from %s", payload.event, topic, state.ws_id))
    end,
}

return DefaultHandlers