local DawnServer = require("dawn_server")

-- Define your WebSocket message handler
local function on_message(ws, msg, conn_state, shared)
    conn_state.last_pong = os.time()

    if msg.type == "ping" then
        ws:send('{"type":"pong"}')
    elseif msg.type == "join_game" then
        local uid = msg.user_id or "guest_" .. tostring(ws)
        conn_state.user_id = uid
        shared.players[uid] = ws
        ws:send('{"type":"join_ack","user_id":"' .. uid .. '"}')
    else
        ws:send('{"error":"Unknown message type"}')
    end
end

-- Create and configure the server with ws handler injected
local server = DawnServer:new({
    port = 8080,
    ws_handlers = {
        on_message = on_message
    },

})

local function uuid_v4()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
      local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
      return string.format("%x", v)
  end)
end
server:use(function (req, res, next)
  if(server.shared_state.sessions) then
    print("Saving new user session")
    server.shared_state.sessions  = {
      username = uuid_v4()
     }
    end
 next()
end)

-- server:get("/info", function(req, res, query)
--   print("GET / - Query Parameters:")
--   res:writeHeader("Content-Type", "text/plain")
--      :writeHeader("Access-Control-Allow-Origin", "*")
--      :writeStatus(200)
--      :send("Hello, World!")
-- end)

-- server.game_sockets_handler:start_heartbeat(15000, 3)
server:ws("/game", function() end)
server:start()
