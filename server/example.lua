-- main.lua
package.path = package.path .. ";./?.lua;./../?.lua;"
require("bootstrap")
local DawnServer = require("dawn_server") -- Assuming dawn_server.lua is in the same directory or accessible via package.path
local Logger = require("utils.logger").Logger -- Assuming you have this logger utility
local log_level = require("utils.logger").LogLevel
local uuid = require("utils.uuid") -- Assuming you have a uuid utility
local json = require("cjson") -- For JSON encoding/decoding

-- Initialize a logger
local myLogger = Logger:new()

-- Define server configuration
local server_config = {
    port = 3000,
    logger = myLogger,
    -- Configure static file serving
    -- Each entry is a table with 'route_prefix' and 'directory_path'
    static_configs = {
        { route_prefix = "/static", directory_path = "./public" },
        -- You can add more static directories if needed:
        -- { route_prefix = "/assets", directory_path = "./assets" },
    },
    token_store = {
        store = {}, -- A simple Lua table for demonstration. In a real app, this would be a persistent store.
        cleanup_interval = 60 -- Clean up every 60 seconds (for TokenCleaner example)
    },
    state_management_options = {
        session_timeout = 3600, -- Session timeout in seconds
        cleanup_interval = 60   -- How often to clean up expired sessions
    }
}

-- Create a new DawnServer instance
local server = DawnServer:new(server_config)

-- Define some middleware (optional)
server:use(function(req, res, next)
    myLogger:log(log_level.INFO, "Middleware: Request received for: " .. req._raw:getUrl(), "Middleware")
    -- Example: Add a custom header to all responses
    res:writeHeader("X-Powered-By", "DawnServer/Lua")
    next() -- Crucial to call next to continue processing the request
end)

-- Define a route-specific middleware
server:use(function(req, res, next)
    myLogger:log(log_level.INFO, "Specific Middleware for /api/*", "SpecificMiddleware")
    next()
end, "/api") -- This middleware will only run for routes starting with /api


-- Define API routes
server:get("/api/hello", function(req, res)
    myLogger:log(log_level.INFO, "GET /api/hello hit", "Routes")
    res:writeHeader("Content-Type", "application/json")
    res:send(json.encode({ message = "Hello from DawnServer!", query = req.query }))
end)

server:post("/api/echo", function(req, res, body)
    myLogger:log(log_level.INFO, "POST /api/echo hit with body: " .. tostring(body), "Routes")
    res:writeHeader("Content-Type", "application/json")
    res:send(json.encode({ received = body, status = "success" }))
end)

server:get("/api/user/:id", function(req, res)
    myLogger:log(log_level.INFO, "GET /api/user/:id hit with id: " .. req.params.id, "Routes")
    local user_id = req.params.id
    res:writeHeader("Content-Type", "application/json")
    if user_id == "123" then
        res:send(json.encode({ id = user_id, name = "Alice", email = "alice@example.com" }))
    else
        res:writeStatus(404):send(json.encode({ error = "User not found" }))
    end
end)

-- Define a root route (for serving index.html directly from a dynamic handler)
server:get("/home", function(req, res)
    myLogger:log(log_level.INFO, "GET / hit, serving index.html", "Routes")
    local file = io.open("./public/index.html", "rb")
    if file then
        local content = file:read("*a")
        file:close()
        res:writeHeader("Content-Type", "text/html")
        res:send(content)
    else
        res:writeStatus(404):send("<h1>404 - index.html not found</h1><p>Please ensure public/index.html exists.</p>")
    end
end)


-- Define WebSocket route
server:ws("/ws", function(ws_obj, event, message, code, reason)
    if event == "open" then
        myLogger:log(log_level.INFO, "WebSocket connected! ID: " .. ws_obj:get_id(), "WebSocket")
        ws_obj:send("Welcome to the WebSocket server! Your ID is: " .. ws_obj:get_id())
    elseif event == "message" then
        myLogger:log(log_level.INFO, "WebSocket message from " .. ws_obj:get_id() .. ": " .. message, "WebSocket")
        ws_obj:send("Echo: " .. message)
    elseif event == "close" then
        myLogger:log(log_level.INFO, "WebSocket disconnected! ID: " .. ws_obj:get_id() .. ", Code: " .. code .. ", Reason: " .. reason, "WebSocket")
    end
end)


-- Start the server
server:start()

-- Keep the Lua event loop running (if using luv directly, otherwise uWS.run() handles it)
uv.run()